-- Entity / weapon creation helpers, reimplemented from the easylua library (the
-- create/StartWeapon/EndWeapon/StartEntity/EndEntity surface). These are "create"
-- helpers, not "search" -- they live on the top-level Noir table so user code can
-- author a SWEP/SENT live. Credit to the easylua authors:
--   CapsAdmin's original:
--     https://github.com/CapsAdmin/fast_addons/blob/master/lua/notagain/essential/libraries/easylua.lua
--   Metastruct/luadev's newer version:
--     https://github.com/Metastruct/luadev/blob/master/lua/autorun/easylua.lua
--
-- StartWeapon/EndWeapon (and the Entity pair) build a SWEP/ENT table the run body
-- fills in, then register it with the engine. The in-progress table is stored on the
-- run context's upvalues (`vars.SWEP`/`vars.ENT`), NOT the real `_G` -- the sandbox
-- env resolves the bare `SWEP`/`ENT` name against those upvalues (see
-- Environment.MakeEnvTable), so the body sees it without us touching the global table.
-- This keeps authoring contained and per-run isolated. (The body mutates the table's
-- fields, the easylua pattern; a wholesale `SWEP = {}` reassignment wouldn't land back
-- on the upvalue and isn't supported.) Registration must run on whichever realm
-- executes the code, so a SWEP/SENT is authored with a "shared" run (Noir runs the
-- source on both client and server, each registering its copy).

-- Trace vars (me/there/...) are the per run-context upvalue table -- also where the
-- in-progress SWEP/ENT lives. When a caller doesn't have one (e.g. a standalone
-- Noir.StartWeapon("weapon_x") outside a run), fall back to a fresh set on the client /
-- an empty table on the server -- spawn/give is simply skipped without `me`.
local function resolveVars(vars)
	if istable(vars) then return vars end
	if CLIENT and Noir.Environment then return Noir.Environment.MakeVars() end
	return {}
end

-- Re-Initialize live instances of `class` so re-running updated code refreshes them.
local function reinitInstances(class)
	for _, ent in ipairs(ents.FindByClass(class)) do
		if IsValid(ent) and isfunction(ent.Initialize) then ent:Initialize() end
	end
end

----------------------------------------------------------------------
-- create: spawn an entity (or a prop from a model path) at where the runner is
-- looking, wired into undo/cleanup. Server-only -- entities are authoritative there.
----------------------------------------------------------------------
function Noir.CreateEntity(class, vars, callback)
	vars = resolveVars(vars)
	if CLIENT then
		Noir.Error("create() can only spawn entities on the server\n")
		return NULL
	end

	if not isstring(class) then return NULL end
	local ent
	if string.GetExtensionFromFilename(class) == "mdl" then
		ent = ents.Create("prop_physics")
		if IsValid(ent) then ent:SetModel(class) end
	else
		ent = ents.Create(class)
	end

	if not IsValid(ent) then return NULL end

	-- Let the caller configure the entity (model, keyvalues, ...) before spawn.
	if isfunction(callback) then callback(ent) end

	ent:Spawn()
	ent:Activate()

	-- Drop it in just above where the runner is aiming and settle it onto the
	-- ground (mirrors easylua's BoundingRadius lift + DropToFloor).
	local pos = vars.there or (IsValid(vars.me) and vars.me:GetPos()) or vector_origin
	ent:SetPos(pos + Vector(0, 0, ent:BoundingRadius() * 2))
	ent:DropToFloor()
	local phys = ent:GetPhysicsObject()
	if IsValid(phys) then phys:Wake() end

	local owner = IsValid(vars.me) and vars.me or nil
	if owner then
		undo.Create("Noir: " .. class)
			undo.AddEntity(ent)
			undo.SetPlayer(owner)
		undo.Finish()
		cleanup.Add(owner, "noir_entities", ent)
	end

	return ent
end

----------------------------------------------------------------------
-- SWEP authoring
----------------------------------------------------------------------
function Noir.StartWeapon(class, vars)
	vars = resolveVars(vars)
	vars.SWEP = {
		Primary = {},
		Secondary = {},
		ViewModelFlip = false,
		Base = "weapon_base",
		ClassName = class,
		Spawnable = true
	}

	return vars.SWEP
end

-- opts.reinit (default true) re-Initializes live instances; opts.spawn gives the
-- weapon to vars.me (server only). Always clears vars.SWEP, including on error.
function Noir.EndWeapon(vars, opts)
	vars = resolveVars(vars)
	opts = opts or {}
	local swep = vars.SWEP
	if not istable(swep) then
		Noir.Error("EndWeapon: no SWEP in progress (call StartWeapon/startswep first)\n")
		return
	end

	local class = swep.ClassName
	if not isstring(class) or class == "" then
		vars.SWEP = nil
		Noir.Error("EndWeapon: SWEP has no ClassName\n")
		return
	end

	weapons.Register(swep, class)
	if opts.reinit ~= false then reinitInstances(class) end
	if SERVER and opts.spawn then
		local me = vars.me
		if IsValid(me) and me:IsPlayer() then
			SafeRemoveEntity(me:GetWeapon(class))
			timer.Simple(0.2, function()
				if IsValid(me) and me:IsPlayer() then me:Give(class) end
			end)
		end
	end

	vars.SWEP = nil
	return class
end

----------------------------------------------------------------------
-- SENT authoring
----------------------------------------------------------------------
function Noir.StartEntity(class, vars)
	vars = resolveVars(vars)
	if not isstring(class) or class == "" then
		local me = vars.me
		class = "noir_ent_" .. (IsValid(me) and me:SteamID64() or "0")
	end

	vars.ENT = {ClassName = class}
	return vars.ENT
end

-- opts.reinit (default true) / opts.spawn (server only, spawns at vars.there via
-- Noir.CreateEntity). Always clears vars.ENT, including on error.
function Noir.EndEntity(vars, opts)
	vars = resolveVars(vars)
	opts = opts or {}
	local ent = vars.ENT
	if not istable(ent) then
		Noir.Error("EndEntity: no ENT in progress (call StartEntity/startsent first)\n")
		return
	end

	local class = ent.ClassName
	if not isstring(class) or class == "" then
		vars.ENT = nil
		Noir.Error("EndEntity: ENT has no ClassName\n")
		return
	end

	ent.Model = ent.Model or "models/props_borealis/bluebarrel001.mdl"
	if not ent.Base then
		ent.Base = "base_anim"
		ent.Type = ent.Type or "anim"
	end

	ent.Spawnable = ent.Spawnable ~= false
	scripted_ents.Register(ent, class)
	if opts.reinit ~= false then reinitInstances(class) end
	if SERVER and opts.spawn then Noir.CreateEntity(class, vars) end
	vars.ENT = nil
	return class
end

-- Clear any half-built SWEP/ENT off the run context (used by the auto-wrap after a
-- failed run so a broken authoring run doesn't leave a stray build behind).
function Noir.ClearEntityBuild(vars)
	vars = resolveVars(vars)
	vars.SWEP = nil
	vars.ENT = nil
end
