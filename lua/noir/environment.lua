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

-- Send a run message (output / result) back to the runner on the run's channel.
-- `target` is the runner (the channel's opener); a self run delivers locally. Thin
-- wrapper over the channel API so existing callers stay unchanged. Routing and the
-- local-delivery shortcut are handled inside Network.SendOnChannel.
function Environment.SendMessage(target, transferId, message, messageData)
	Noir.Debug("Env.SendMessage", target, transferId, message, messageData)
	local messageBody = Noir.Format.FormatMessage(message, messageData, messageData.opts)
	Noir.Debug("Env.SendMessageBODY", messageBody)
	local dst = (isentity(target) and target:EntIndex() == 0) and "server" or target
	Noir.Network.SendOnChannel(transferId, message, messageBody, dst)
end

-- Register a handler for messages on a run channel. Wrapper over Network.OnChannel;
-- preserves the (sender, id, message, body) callback shape (body = the message
-- string) that run.lua / repl.lua expect.
function Environment.RegisterHandler(callback, transferId, message)
	Noir.Network.OnChannel(transferId, message, function(sender, channelId, msg, data)
		callback(sender, channelId, msg, data.string)
	end)
end

-- Tear down a run channel. Call from session / panel teardown -- NEVER on a run's
-- `done`, since hooks/timers set up by the run may still be replying.
function Environment.CloseRun(transferId, target)
	if not transferId then return end
	Noir.Network.CloseChannel(transferId, target)
end

-- Format a run channel's target for display (a player nick, or the group name).
local function runTargetName(target)
	if isentity(target) and IsValid(target) and target:IsPlayer() then return target:Nick() end
	return tostring(target)
end

-- Run channels this node opened -- the script-output streams we're subscribed to.
-- Each entry: {id, label, target}. Excludes non-run channels (e.g. fileSearch).
function Environment.GetRunChannels()
	local me = SERVER and Entity(0) or LocalPlayer()
	local out = {}
	for id, ch in pairs(Noir.Network.Channels) do
		if ch.type == "runCode" and ch.opener == me then
			out[#out + 1] = {id = id, label = ch.label, target = ch.target}
		end
	end

	return out
end

-- Unsubscribe from (close) one run channel we opened: stop receiving its output and
-- tell the server to stop relaying it. Scoped to this channelId, so other runs still
-- streaming to the console are untouched. Returns true if a run channel was closed.
function Environment.UnsubscribeRun(channelId)
	local ch = Noir.Network.Channels[channelId]
	if not ch or ch.type ~= "runCode" then return false end
	if ch.opener ~= (SERVER and Entity(0) or LocalPlayer()) then return false end
	Environment.CloseRun(channelId, ch.target)
	return true
end

-- Unsubscribe from every run channel we opened (script output only). Returns count.
function Environment.UnsubscribeAllRuns()
	local n = 0
	for _, run in ipairs(Environment.GetRunChannels()) do
		Environment.CloseRun(run.id, run.target)
		n = n + 1
	end

	return n
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
-- Only the newest context per runner is ever read (to recover the previous run's
-- return value for `last`), so we keep a single slot per runner rather than an
-- ever-growing history array.
Environment.LastContext = Environment.LastContext or {}

-- Update upvalues on receiving end
function Environment.UpdateUpvals(context)
	local vars = context.Upvalues
	if IsValid(vars.this) then
		vars.phys = vars.this:GetPhysicsObject()
		vars.model = vars.this:GetModel()
	end

	local lastContext = Environment.LastContext[context.Runner]
	if lastContext then
		local lastRun = lastContext.RunResults
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
	-- UpdateUpvals reads LastContext[runner] to bind `last`, so populate this
	-- context's upvalues (against the previous run) *before* overwriting the slot.
	Environment.UpdateUpvals(ContextTable)
	Environment.LastContext[runner] = ContextTable
	if vars.__NO_CAPTURE then return ContextTable end
	for _, v in pairs(Environment.MessageFuncs) do
		local original = _G[v]
		ContextTable.Upvalues[v] = function(...)
			if Noir.Network.Channels[transferId] then
				Environment.SendMessage(runner, transferId, v, {
					trace = traceback(),
					args = {...},
				})
			end

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
			cleared = cleared + table.Count(v)
			Environment.Contexts[k] = nil
			Environment.LastContext[k] = nil
		end
	end

	Noir.Msg("Cleared ", Color(0, 150, 0), tostring(cleared), Color(255, 255, 255), " envs.\n")
end, nil, "Clears unused Noir environments")

concommand.Add("noir_clearenvs_all", function(ply)
	if SERVER and IsValid(ply) and not ply:IsSuperAdmin() then return end
	local cleared = 0
	for _, v in pairs(Environment.Contexts) do
		cleared = cleared + table.Count(v)
	end

	Environment.Contexts = {}
	Environment.LastContext = {}

	Noir.Msg("Cleared ", Color(0, 150, 0), tostring(cleared), Color(255, 255, 255), " envs.\n")
end, nil, "Clears all Noir environments")

if SERVER then
	-- Free a leaving player's run contexts. The network layer's PlayerDisconnected
	-- sweep drops their channels (firing runCode `close`, which clears individual
	-- Contexts[opener][transferId]) but never touches the per-runner outer table or
	-- the `last` slot, both keyed by the now-invalid player entity.
	hook.Add("PlayerDisconnected", "Noir.Environment.Cleanup", function(ply)
		if not IsValid(ply) then return end
		Environment.Contexts[ply] = nil
		Environment.LastContext[ply] = nil
	end)
end

-- Unsubscribe from a run's script-output channel so it stops spamming the console.
-- `all` closes every run channel we opened. Each close is scoped to its own
-- channelId, so other runs still streaming to the console are unaffected.
concommand.Add("noir_unsubscribe", function(ply, cmd, args)
	if SERVER and IsValid(ply) and not ply:IsSuperAdmin() then return end
	local id = args[1]
	if not id or id == "" then
		local runs = Environment.GetRunChannels()
		Noir.Msg("Usage: noir_unsubscribe <channelId|all>\n")
		if #runs == 0 then
			Noir.Msg("No active run channels.\n")
			return
		end

		Noir.Msg("Active run channels:\n")
		for _, run in ipairs(runs) do
			Noir.Msg("  ", Color(0, 120, 205), run.id, Color(255, 255, 255),
				Format("  %s -> %s\n", run.label or "?", runTargetName(run.target)))
		end

		return
	end

	if string.lower(id) == "all" then
		local n = Environment.UnsubscribeAllRuns()
		Noir.Msg("Unsubscribed from ", Color(0, 150, 0), tostring(n), Color(255, 255, 255), " run channel(s).\n")
	elseif Environment.UnsubscribeRun(id) then
		Noir.Msg("Unsubscribed from run channel ", Color(0, 120, 205), id, Color(255, 255, 255), ".\n")
	else
		Noir.Msg("No such run channel: ", Color(150, 0, 0), tostring(id), Color(255, 255, 255), "\n")
	end
end, function(cmd, argStr)
	-- Auto-suggest active run channel ids (+ "all"). The label/target after the id are
	-- display only -- the handler reads args[1] and ignores the rest.
	local partial = string.Trim(argStr or ""):lower()
	local out = {}
	if partial == "" or string.find("all", partial, 1, true) then out[#out + 1] = cmd .. " all" end
	for _, run in ipairs(Environment.GetRunChannels()) do
		if partial == "" or string.find(run.id:lower(), partial, 1, true) then
			out[#out + 1] = Format("%s %s  (%s -> %s)", cmd, run.id, run.label or "?", runTargetName(run.target))
		end
	end

	return out
end, "Unsubscribe from a run's script-output channel (channelId or 'all')")
