local Search = Noir.Search or {}
Noir.Search = Search

-- Entity-search ergonomics reimplemented from the easylua library: the trace/
-- search vars, the "all"/"us"/... magic search tables, FindEntity, and the copy/
-- create helpers. We only want these parts, not the whole library, so they are
-- reproduced here. Credit to the easylua authors. Two upstreams:
--   CapsAdmin's original:
--     https://github.com/CapsAdmin/fast_addons/blob/master/lua/notagain/essential/libraries/easylua.lua
--   Metastruct/luadev's newer version (source of humans/npcs/those/them/friends,
--   allof, #owner, the SteamID64 lookup and the chained-collection idea):
--     https://github.com/Metastruct/luadev/blob/master/lua/autorun/easylua.lua

----------------------------------------------------------------------
-- Comparison helpers
----------------------------------------------------------------------
-- `lb` is the caller-supplied lowercase fold of `b`. It's loop-invariant across an
-- entity scan, so callers fold it once (Noir.Utils.UTF8Lower) and pass it in rather
-- than re-folding the search string for every entity. Utils.UTF8Lower folds ASCII
-- *and* the UTF8 letters in its table, so non-ASCII nicks match without needing GLib.
local function compare(a, b, lb)
	if a == b then return true end
	if a:find(b, nil, true) then return true end
	-- Case-insensitive pass.
	lb = lb or Noir.Utils.UTF8Lower(b)
	local la = Noir.Utils.UTF8Lower(a)
	if la == lb then return true end
	if la:find(lb, nil, true) then return true end
	return false
end

local function compareentity(ent, str, lstr)
	if ent.GetName and compare(ent:GetName(), str, lstr) then return true end
	if ent:GetModel() and compare(ent:GetModel(), str, lstr) then return true end
	return false
end

-- Of the entities in `list`, the one nearest `point` (nil if the list is empty).
local function nearest(list, point)
	local best, bestDist
	for _, ent in ipairs(list) do
		if IsValid(ent) then
			local d = ent:GetPos():DistToSqr(point)
			if not bestDist or d < bestDist then best, bestDist = ent, d end
		end
	end

	return best
end

----------------------------------------------------------------------
-- Chained collections (a lightweight take on luadev's tinylua)
--
-- Wrapping a list of entities returns a table keyed by entity. Indexing a method
-- name maps it over every entity and returns ANOTHER wrapped table, so calls
-- compose: `all:GetPos():Distance(here)`. Field assignment writes to every
-- entity; calling the wrapper invokes each stored function. Map/filter/set/get/
-- first/keys/errors take plain Lua functions -- we never compile strings. If the
-- real `tinylua` library is loaded we defer to it instead, which adds its string
-- lambda parser on top of the same surface.
----------------------------------------------------------------------
local ChainMeta = {}
local Helpers = {}
local errorsOf = setmetatable({}, {__mode = "k"}) -- wrapped result -> per-entity errors

-- Re-key a raw list so the entity becomes its own key (matching tinylua); tables
-- that are already entity-keyed (results of a previous step) pass through.
local function rekey(list)
	local out = {}
	for k, v in pairs(list) do
		if tonumber(k) ~= nil then out[v] = v else out[k] = v end
	end

	return out
end

-- Run `fn` for every (source, value) in the wrapped table, collecting into a
-- fresh wrapped table and stashing any per-entity error instead of aborting.
local function performCall(wrapped, fn)
	local results = {}
	local errors = {}
	for source, value in pairs(wrapped) do
		local ok, err = pcall(fn, results, source, value)
		if not ok then errors[source] = err end
	end

	local out = setmetatable(results, ChainMeta)
	errorsOf[out] = errors
	return out
end

local function assertfn(fn)
	if not isfunction(fn) then
		error("Noir chained map/filter needs a function (load the tinylua library for string lambdas)", 3)
	end
end

function ChainMeta:__index(key)
	local helper = Helpers[key]
	if helper then return function(_, ...) return helper(self, ...) end end

	return performCall(self, function(results, source, value)
		local target = value[key]
		if isfunction(target) then
			results[source] = function(_, ...) return target(value, ...) end
		else
			results[source] = target
		end
	end)
end

function ChainMeta:__newindex(key, value)
	performCall(self, function(_, _source, ent) ent[key] = value end)
end

function ChainMeta:__call(...)
	local n = select("#", ...)
	local packed = {...}
	return performCall(self, function(results, source, value)
		if isfunction(value) then
			results[source] = value(unpack(packed, 1, n))
		else
			results[source] = value
		end
	end)
end

-- Unwrap to a clean array of the values.
function Helpers.get(self)
	local out = {}
	for _, v in pairs(self) do out[#out + 1] = v end
	return out
end

function Helpers.first(self)
	for _, v in pairs(self) do return v end
	return nil
end

-- The source entities themselves, as a wrapped collection.
function Helpers.keys(self)
	return performCall(self, function(results, source) results[source] = source end)
end

function Helpers.map(self, fn)
	assertfn(fn)
	return performCall(self, function(results, source, value) results[source] = fn(value, source) end)
end

function Helpers.filter(self, fn)
	assertfn(fn)
	return performCall(self, function(results, source, value)
		if fn(value, source) then results[source] = value end
	end)
end

function Helpers.set(self, keys, val)
	keys = istable(keys) and keys or {keys}
	return performCall(self, function(results, source, ent)
		for _, k in ipairs(keys) do ent[k] = val end
		results[source] = ent
	end)
end

function Helpers.errors(self)
	return errorsOf[self] or {}
end

-- Wrap a collection for chaining. Prefers the real tinylua when present.
function Search.Wrap(collection)
	if tinylua then return tinylua(collection) end
	return setmetatable(rekey(collection), ChainMeta)
end

----------------------------------------------------------------------
-- Magic search tables ("all", "us", ...)
--
-- `func` is a predicate selecting which entities to gather (nil = every entity).
-- The result is a Search.Wrap'd collection, so it *is* a usable table by default
-- (iterate it, index it, assign to it) with the chain metatable already attached
-- -- method calls and field assignments fan out over the members, and calling it
-- (`all()`) returns the wrapped table too (ChainMeta:__call). The membership is a
-- snapshot taken when it's built (target-side, in Search.PopulateVars); entities
-- created/removed afterwards aren't reflected.
----------------------------------------------------------------------
function Search.CreateAllFunction(func)
	local results = {}
	for _, ent in pairs(ents.GetAll()) do
		if not func or func(ent) then results[#results + 1] = ent end
	end

	return Search.Wrap(results)
end

----------------------------------------------------------------------
-- copy / create
----------------------------------------------------------------------
-- `copy`: put a textual representation of a value on the runner's clipboard.
-- Clipboards are client-only, so when the code runs anywhere but the runner's
-- own client we ship the text to the runner over Noir's network and set it
-- there. The receive handler re-checks the source.
function Search.CopyToClipboard(value, runner)
	local text = isstring(value) and value or Noir.Format.FormatLong(value, 0, {full = true})
	if CLIENT and runner == LocalPlayer() then
		SetClipboardText(text)
	elseif IsValid(runner) and runner:IsPlayer() then
		Noir.Network.Fire("setClipboard", text, runner)
	end

	return value
end

-- A fire-and-forget one-shot channel: no reply, torn down right after the open.
Noir.Network.ChannelHandlers["setClipboard"] = {
	oneshot = true,
	open = function(sender, channelId, data)
		if not CLIENT then return end
		-- Same trust check as running Lua: only the server (Entity(0)) or a superadmin
		-- is allowed to drive our clipboard.
		local trusted = sender == Entity(0) or (IsValid(sender) and sender:IsPlayer() and sender:IsSuperAdmin())
		if not trusted then return end
		SetClipboardText(data.string)
	end
}

-- `create` (Noir.CreateEntity) and the SWEP/SENT authoring helpers live in
-- entity_create.lua now -- they are "create" helpers, not "search". PopulateVars
-- below still injects them into the run env as closures over `vars`.

----------------------------------------------------------------------
-- FindEntity
--
-- `vars` is the current run context's variable table -- easylua read these from
-- _G (it dumped vars into globals); Noir keeps them per-context, so we pass them
-- in instead. Defaults to an empty table so direct calls don't error.
----------------------------------------------------------------------
function Search.FindEntity(str, vars)
	vars = vars or {}
	if not str then return NULL end
	if #str:Trim() == 0 then return NULL end
	str = tostring(str)
	if str == "#this" and IsEntity(vars.this) and vars.this:IsValid() then return vars.this end
	if str == "#me" and IsEntity(vars.me) and vars.me:IsPlayer() then return vars.me end
	if str == "#owner" and IsValid(vars.this) then
		local owner = vars.this.CPPIGetOwner and vars.this:CPPIGetOwner() or vars.this:GetOwner()
		if IsValid(owner) then return owner end
	end
	if str == "#all" then return vars.all end
	if str == "#humans" then return vars.humans end
	if str == "#bots" then return vars.bots end
	if str == "#us" then return vars.us end
	if str == "#them" then return vars.them end
	if str == "#friends" then return vars.friends end
	if str == "#randply" then return table.Random(player.GetAll()) end
	if str:sub(1, 1) == "#" then
		local query = str:sub(2)
		if #query > 0 then
			query = query:lower()
			-- a team name -> all players on that team
			for teamID, data in pairs(team.GetAllTeams()) do
				if data.Name:lower() == query then
					return Search.CreateAllFunction(function(v) return v:IsPlayer() and v:Team() == teamID end)
				end
			end

			-- an entity class -> all entities of that class
			for _, ent in pairs(ents.GetAll()) do
				if ent:GetClass():lower() == query then
					return Search.CreateAllFunction(function(v) return v:GetClass():lower() == query end)
				end
			end
		end
	end

	-- unique id
	local match = player.GetByUniqueID(str)
	if match and match:IsPlayer() then return match end
	-- steam id
	if str:find("STEAM") then
		for key, _ply in pairs(player.GetAll()) do
			if _ply:SteamID() == str or string.Replace(_ply:SteamID(), ":", "_") == str then return _ply end
		end
	end

	-- steamid64 (17-digit community id, starts with 7)
	if #str == 17 and str:sub(1, 1) == "7" and tonumber(str) then
		for key, _ply in pairs(player.GetAll()) do
			if _ply:SteamID64() == str then return _ply end
		end
	end

	if str:sub(1, 1) == "_" and tonumber(str:sub(2)) then str = str:sub(2) end
	if tonumber(str) then
		match = Entity(tonumber(str))
		if match:IsValid() then return match end
	end

	-- ip
	if SERVER and str:find("%d+%.%d+%.%d+%.%d+") then
		for key, _ply in pairs(player.GetAll()) do
			if _ply:IPAddress():find(str) then return _ply end
		end
	end

	-- search in sensible order. The case-insensitive fold of the search string is
	-- loop-invariant across every scan below, so compute it once and pass it into
	-- compare/compareentity rather than re-folding per player/entity.
	local lstr = Noir.Utils.UTF8Lower(str)

	-- search exact
	for _, ply in pairs(player.GetAll()) do
		if ply:Nick() == str then return ply end
	end

	-- Search bots so we target those first
	for key, ply in pairs(player.GetBots()) do
		if compare(ply:Nick(), str, lstr) then return ply end
	end

	-- search from beginning of nick
	for _, ply in pairs(player.GetHumans()) do
		if ply:Nick():lower():find(str, 1, true) == 1 then return ply end
	end

	-- Search normally and search with colorcode stripped
	for key, ply in pairs(player.GetAll()) do
		if compare(ply:Nick(), str, lstr) then return ply end
		if compare(ply:Nick():gsub("%^%d", ""), str, lstr) then return ply end
	end

	-- entity by name/model -- prefer the match closest to where the runner aims
	local nameMatches = {}
	for _, ent in pairs(ents.GetAll()) do
		if compareentity(ent, str, lstr) then nameMatches[#nameMatches + 1] = ent end
	end

	if #nameMatches > 0 then
		if vars.there then return nearest(nameMatches, vars.there) or nameMatches[1] end
		return nameMatches[1]
	end

	do
		-- class -- a trailing number (e.g. `prop_physics2`) selects which match.
		-- Otherwise prefer the entity closest to where the runner aims, falling
		-- back to a random match when there's no aim point.
		local _str, idx = str:match("(.-)(%d+)$")
		if idx then
			idx = tonumber(idx)
			str = _str
		end

		-- Re-fold only if the trailing selector number changed the string; otherwise
		-- reuse the fold computed above.
		local lclass = idx and Noir.Utils.UTF8Lower(str) or lstr
		local found = {}
		for _, ent in pairs(ents.GetAll()) do
			if compare(ent:GetClass(), str, lclass) then table.insert(found, ent) end
		end

		if #found == 0 then return NULL end
		if idx then return found[math.Clamp(idx % #found, 1, #found)] end
		if vars.there then return nearest(found, vars.there) or table.Random(found) end
		return table.Random(found)
	end
end

----------------------------------------------------------------------
-- Populate a run context's vars with the magic search tables and helpers.
-- Called from Environment.UpdateUpvals (target-side) because these hold closures
-- /metatables that can't be networked. `runner` is the initiator (for `copy`).
----------------------------------------------------------------------
function Search.PopulateVars(vars, runner)
	-- Player groups close over the networked `we`/`me`; the rest filter ents.GetAll().
	vars.all = Search.CreateAllFunction(function(v) return v:IsPlayer() end)
	vars.humans = Search.CreateAllFunction(function(v) return v:IsPlayer() and not v:IsBot() end)
	vars.bots = Search.CreateAllFunction(function(v) return v:IsPlayer() and v:IsBot() end)
	vars.npcs = Search.CreateAllFunction(function(v) return v:IsNPC() end)
	vars.props = Search.CreateAllFunction(function(v) return v:GetClass() == "prop_physics" end)
	vars.us = Search.CreateAllFunction(function(v) return IsValid(v) and table.HasValue(vars.we or {}, v) end)
	vars.them = Search.CreateAllFunction(function(v) return IsValid(v) and v ~= vars.me and table.HasValue(vars.we or {}, v) end)
	vars.those = Search.CreateAllFunction(function(v) return vars.there ~= nil and IsValid(v) and v:GetPos():Distance(vars.there) <= 250 end)
	-- `friends` relies on the clientside-only Player:GetFriendStatus (relative to
	-- the local player). The nil-guard makes it a harmless empty set on the server.
	vars.friends = Search.CreateAllFunction(function(v)
		return v:IsPlayer() and v.GetFriendStatus ~= nil and v:GetFriendStatus() == "friend"
	end)
	-- `these` -> everything constrained to `this`. Prefer the server-computed list
	-- (vars.__constrained, set in Environment.UpdateVarsSV) so it stays accurate on
	-- client targets; fall back to a live query on whatever realm the code runs in.
	vars.these = Search.CreateAllFunction(function(v)
		local list = vars.__constrained
		-- constraint.GetAllConstrainedEntities is server-only; on a client target we
		-- rely on the server-computed vars.__constrained and otherwise fall back empty.
		if not list and IsValid(vars.this) and constraint.GetAllConstrainedEntities then
			list = constraint.GetAllConstrainedEntities(vars.this)
		end
		return list ~= nil and table.HasValue(list, v) or false
	end)
	-- allof("npc_zombie") / allof(someEnt) -> all entities sharing that class.
	vars.allof = function(class)
		if IsEntity(class) and IsValid(class) then class = class:GetClass() end
		return Search.CreateAllFunction(function(v) return v:GetClass() == class end)
	end

	vars.copy = function(value) return Search.CopyToClipboard(value, runner) end
	vars.E = function(str) return Search.FindEntity(str, vars) end
	-- create/SWEP/SENT authoring helpers (impl in entity_create.lua), bound to this
	-- context's `vars` so they position/give relative to the runner.
	vars.create = function(class, callback) return Noir.CreateEntity(class, vars, callback) end
	vars.startswep = function(class) return Noir.StartWeapon(class, vars) end
	vars.endswep = function(opts) return Noir.EndWeapon(vars, opts) end
	vars.startsent = function(class) return Noir.StartEntity(class, vars) end
	vars.endsent = function(opts) return Noir.EndEntity(vars, opts) end
end
