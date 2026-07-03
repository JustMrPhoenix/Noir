local Environment = Noir.Environment or {}
Noir.Environment = Environment
-- The easylua-derived entity search (the "all"/"us"/... magic tables, FindEntity
-- and the copy/create helpers) lives in search.lua under Noir.Search. This file
-- keeps the run context, messaging and per-run variable plumbing.

function Environment.MakeVars()
	-- Builds the per-run variable table on the SENDER. This table is networked
	-- to the target, so it may only contain plain/networkable values (numbers,
	-- vectors, entities) -- the magic search tables are functions/metatables and
	-- cannot survive the transfer, so they are created target-side in
	-- Environment.UpdateUpvals via Noir.Search.PopulateVars instead.
	local ply = LocalPlayer()
	if SERVER or not IsValid(ply) then return {} end
	local vars = {}
	vars.me = ply
	local trace = util.QuickTrace(ply:EyePos(), ply:GetAimVector() * 100000, {ply, ply:GetVehicle()})
	if trace.Entity:IsWorld() then trace.Entity = NULL end
	vars.trace = trace
	vars.this = trace.Entity
	vars.there = trace.HitPos
	vars.here = trace.StartPos
	vars.normal = trace.HitNormal
	vars.length = trace.StartPos:Distance(trace.HitPos)
	vars.wep = ply:GetActiveWeapon()
	vars.veh = ply:GetVehicle()
	vars.we = {}
	for _, v in pairs(ents.FindInSphere(ply:GetPos(), 512)) do
		if v:IsPlayer() then table.insert(vars.we, v) end
	end

	vars.dir = ply:GetAimVector()
	return vars
end

function Environment.SendMessage(target, transferId, message, messageData)
	Noir.Debug("Env.SendMessage", target, transferId, message, messageData)
	local messageBody = Noir.Format.FormatMessage(message, messageData, messageData.opts)
	Noir.Debug("Env.SendMessageBODY", messageBody)
	if target == (SERVER and Entity(0) or LocalPlayer()) then
		Environment.OnMessage(target, transferId, message, messageBody)
		return
	end

	-- Client -> server transfers route by data.target (the target argument only
	-- steers server-side net.Send), so the reply's destination has to travel in
	-- the data. The runner shows up as Entity(0)/worldspawn when it's the server.
	Noir.Network.SendTransfer(nil, {
		message = message,
		origTransferId = transferId,
		target = (isentity(target) and target:EntIndex() == 0) and "server" or target
	}, "scriptMessage", messageBody, target)
end

Noir.Network.StringHandlers["scriptMessage"] = {
	received = function(sender, transferId, data)
		Noir.Environment.OnMessage(sender, data.origTransferId, data.message, data.string)
	end
}

Environment.MessageHandlers = {}
function Environment.OnMessage(sender, transferId, message, data)
	Noir.Debug("OnMessage", sender, transferId, message, data)
	if not Environment.MessageHandlers[transferId] then return end
	local handlers = Environment.MessageHandlers[transferId]
	-- This will iterate through numeric keys
	Noir.Debug("OnMessageI", handlers)
	for _, callback in ipairs(handlers) do
		callback(sender, transferId, message, data)
	end

	local messageHandlers = Environment.MessageHandlers[transferId][message]
	Noir.Debug("OnMessageM", messageHandlers)
	if not messageHandlers then return end
	for _, callback in pairs(messageHandlers) do
		callback(sender, transferId, message, data)
	end
end

function Environment.RegisterHandler(callback, transferId, message)
	local handlersTbl = Environment.MessageHandlers[transferId] or {}
	Environment.MessageHandlers[transferId] = handlersTbl
	if message then
		handlersTbl[message] = handlersTbl[message] or {}
		table.insert(handlersTbl[message], callback)
	else
		table.insert(handlersTbl, callback)
	end
end

Environment.MessageFuncs = {"print", "Msg", "MsgC", "MsgN", "MsgAll", "ErrorNoHalt"}
if SERVER then table.insert(Environment.MessageFuncs, "PrintMessage") end
local function traceback()
	-- First 2 and last 5 are environment and execution stuff
	local lvls, level = {}, 3
	while true do
		local info = debug.getinfo(level, "Sln")
		if not info then break end
		if info.source == "@addons/noir/lua/noir/execution.lua" then
			table.remove(lvls)
			break
		end

		info.lvl = level
		table.insert(lvls, info)
		level = level + 1
	end
	return lvls
end

Environment.Contexts = {}
Environment.UsedContexts = {}

-- Update upvalues on receiving end
function Environment.UpdateUpvals(context)
	local vars = context.Upvalues
	if IsValid(vars.this) then
		vars.phys = vars.this:GetPhysicsObject()
		vars.model = vars.this:GetModel()
	end

	local contextsTbl = Environment.UsedContexts[context.Runner]
	if contextsTbl and contextsTbl[#contextsTbl] then
		local lastRun = contextsTbl[#contextsTbl].RunResults
		if lastRun and lastRun[1] == true then
			local lastReturn = lastRun[2]
			if #lastReturn == 1 then
				vars.last = lastReturn[1]
			else
				vars.last = lastReturn
			end
		end
	end

	-- Magic search tables + copy/create/E helpers. Built here, target-side,
	-- because they hold closures/metatables that can't be networked from MakeVars.
	Noir.Search.PopulateVars(vars, context.Runner)
	vars.__ENV = vars
	vars.__CONTEXT = context
end

-- Update upvalues on server for stuff that is not avalible clientside
function Environment.UpdateVarsSV(data)
	local vars = data.vars
	-- Precompute the constrained-entity list server-side (authoritative) and ship
	-- it along so the magic `these` table is accurate even on a client target.
	if IsValid(vars.this) then vars.__constrained = constraint.GetAllConstrainedEntities(vars.this) end
end

function Environment.CreateContext(runner, transferId, vars)
	local ContextTable = {}
	ContextTable.ID = transferId
	ContextTable.Runner = runner
	ContextTable.RunnerSteamID = runner:SteamID()
	ContextTable.IsolateGlobal = vars.__ISOLATE_GLOBALS or false
	ContextTable.Upvalues = vars or {}
	local nils = {
		["CLIENT"] = true,
		["SERVER"] = true,
	}

	ContextTable.META = {
		__index = function(self, key)
			local var = rawget(self, key)
			if var ~= nil then return var end
			local upval = ContextTable.Upvalues[key]
			if upval ~= nil then return upval end
			local gvar = _G[key]
			if gvar ~= nil then return gvar end
			if not nils[key] then
				var = Noir.Search.FindEntity(key, ContextTable.Upvalues)
				if isentity(var) and var:IsValid() then return var end
				-- magic search tables / lists aren't entities; return as-is
				if var ~= nil and not isentity(var) then return var end
			end
			return nil
		end,
		__newindex = function(self, key, value)
			if ContextTable.IsolateGlobal then
				rawset(self, key, value)
				return
			end

			_G[key] = value
		end
	}

	ContextTable.EnvTable = setmetatable({}, ContextTable.META)
	Environment.Contexts[runner] = Environment.Contexts[runner] or {}
	Environment.Contexts[runner][transferId] = ContextTable
	Environment.UsedContexts[runner] = Environment.UsedContexts[runner] or {}
	Environment.UpdateUpvals(ContextTable)
	table.insert(Environment.UsedContexts[runner], ContextTable)
	if vars.__NO_CAPTURE then return ContextTable end
	for _, v in pairs(Environment.MessageFuncs) do
		local original = _G[v]
		ContextTable.Upvalues[v] = function(...)
			Environment.SendMessage(runner, transferId, v, {
				trace = traceback(),
				args = {...},
			})

			original(...)
		end
	end
	return ContextTable
end

concommand.Add("noir_clearenvs", function(ply)
	if SERVER and IsValid(ply) and not ply:IsSuperAdmin() then return end
	local cleared = 0
	for k, v in pairs(Environment.Contexts) do
		if not IsValid(k) then
			cleared = cleared + #Environment.Contexts[k]
			Environment.Contexts[k] = nil
		end
	end

	Noir.Msg("Cleared ", Color(0, 150, 0), tostring(cleared), Color(255, 255, 255), " envs.")
end, nil, "Clears unused Noir environments")

concommand.Add("noir_clearenvs_all", function(ply)
	if SERVER and IsValid(ply) and not ply:IsSuperAdmin() then return end
	local cleared = #Environment.Contexts
	for k, v in pairs(Environment.Contexts) do
		Environment.Contexts[k] = {}
	end

	Noir.Msg("Cleared ", Color(0, 150, 0), tostring(cleared), Color(255, 255, 255), " envs.")
end, nil, "Clears all Noir environments")
