local Environment = Noir.Environment or {}
Noir.Environment = Environment

function Environment.MakeVars()
    -- Totally did not steal most of this code from easylua
    local ply = LocalPlayer()
    if SERVER or not IsValid(ply) then return {} end
    local vars = {}
    vars.me = ply
    local trace = util.QuickTrace(ply:EyePos(), ply:GetAimVector() * 100000, {ply, ply:GetVehicle()})
    vars.trace = trace
    vars.this = trace.Entity
    vars.there = trace.HitPos
    vars.here = trace.StartPos
    vars.normal = trace.HitNormal
    vars.length = trace.StartPos:Distance(trace.HitPos)

    vars.we = {}
    for _, v in pairs(ents.FindInSphere(ply:GetPos(), 512)) do
        if v:IsPlayer() then
            table.insert(vars.we, v)
        end
    end

    vars.dir = ply:GetAimVector()

    return vars
end

function Environment.SendMessage(target, transferId, message, messageData)
    Noir.Debug("Env.SendMessage", target, transferId, message, messageData)
    local messageBody = Noir.Format.FormatMessage(message, messageData, messageData.full)
    Noir.Debug("Env.SendMessageBODY", messageBody)
    if target == ( SERVER and Entity(0) or LocalPlayer() ) then
        Environment.OnMessage(target, transferId, message, messageBody)
        return
    end
    Noir.Network.SendTransfer(nil, {message = message, origTransferId = transferId}, "scriptMessage", messageBody, target)
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

if SERVER then
    table.insert(Environment.MessageFuncs, "PrintMessage")
end

local function traceback()
    -- First 2 and last 5 are environment and execution stuff
    local lvls, level = {}, 3
    while true do
        local info = debug.getinfo( level, "Sln" )
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

local function compare(a, b)

	if a == b then return true end
	if a:find(b, nil, true) then return true end
	if a:lower() == b:lower() then return true end
	if a:lower():find(b:lower(), nil, true) then return true end

	return false
end

local function comparenick(a, b)
	if not GLib then return compare (a, b) end
	
	if a == b then return true end
	if a:lower() == b:lower() then return true end
	if GLib.UTF8.MatchTransliteration(a, b) then return true end

	return false
end

local function compareentity(ent, str)
	if ent.GetName and compare(ent:GetName(), str) then
		return true
	end

	if ent:GetModel() and compare(ent:GetModel(), str) then
		return true
	end

	return false
end

-- this function was stolen from easylua
-- whoever made easylua takes credit, i cant find the original now
function Environment.FindEntity(str)
	if not str then return NULL end

	str = tostring(str)

	if str == "#this" and IsEntity(this) and this:IsValid() then
		return this
	end

	if str == "#me" and IsEntity(me) and me:IsPlayer() then
		return me
	end

	if str == "#all" then
		return all
	end

	if str:sub(1,1) == "#" then
		local str = str:sub(2)

		if #str > 0 then
			str = str:lower()
			local found
			for key, data in pairs(team.GetAllTeams()) do
				if data.Name:lower() == str then
					found = data.Name:lower()
					break
				end
			end

			if not found then
				local classes = {}

				for key, ent in pairs(ents.GetAll()) do
					classes[ent:GetClass():lower()] = true
				end

				for class in pairs(classes) do
					if class:lower() == str then
						print("found", class)
						found = class
					end
				end
			end

			if found then
				local func = CreateAllFuncton(function(v) return v:GetClass():lower() == class end)
				print(func:GetName())
				return func
			end
		end
	end

	-- unique id
	local ply = player.GetByUniqueID(str)
	if ply and ply:IsPlayer() then
		return ply
	end

	-- steam id
	if str:find("STEAM") then
		for key, _ply in pairs(player.GetAll()) do
			if _ply:SteamID() == str then
				return _ply
			end
		end
	end

	if str:sub(1,1) == "_" and tonumber(str:sub(2)) then
		str = str:sub(2)
	end

	if tonumber(str) then
		ply = Entity(tonumber(str))
		if ply:IsValid() then
			return ply
		end
	end

	-- ip
	if SERVER then
		if str:find("%d+%.%d+%.%d+%.%d+") then
			for key, _ply in pairs(player.GetAll()) do
				if _ply:IPAddress():find(str) then
					return _ply
				end
			end
		end
	end
	-- search in sensible order
	
	-- search exact
	for _,ply in pairs(player.GetAll()) do
		if ply:Nick()==str then
			return ply
		end
	end
	
	-- Search bots so we target those first
	for key, ply in pairs(player.GetBots()) do
		if comparenick(ply:Nick(), str) then
			return ply
		end
	end
	
	-- search from beginning of nick
	for _,ply in pairs(player.GetHumans()) do
		if ply:Nick():lower():find(str,1,true)==1 then
			return ply
		end
	end
	
	-- Search normally and search with colorcode stripped
	for key, ply in pairs(player.GetAll()) do
		if comparenick(ply:Nick(), str) then
			return ply
		end
		if comparenick(ply:Nick():gsub("%^%d", ""), str) then
			return ply
		end
	end

	for key, ent in pairs(ents.GetAll()) do
		if compareentity(ent, str) then
			return ent
		end
	end

	do -- class

		local _str, idx = str:match("(.-)(%d+)")
		if idx then
			idx = tonumber(idx)
			str = _str
		else
			str = str
			idx = (me and me.easylua_iterator) or 0
		end

		local found = {}

		for key, ent in pairs(ents.GetAll()) do
			if compare(ent:GetClass(), str) then
				table.insert(found, ent)
			end
		end

		return found[math.Clamp(idx%#found, 1, #found)] or NULL
	end
end

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
    vars.E = Environment.FindEntity
    vars.__ENV = vars
    vars.__CONTEXT = context
end

-- Update upvalues on server for stuff that is not avalible clientside
function Environment.UpdateVarsSV(data)
    local vars = data.vars
    vars.these = constraint.GetAllConstrainedEntities(vars.this)
end

function Environment.CreateContext(runner, transferId, vars)
    local ContextTable = {}
    ContextTable.ID = transferId
    ContextTable.Runner = runner
    ContextTable.RunnerSteamID = runner:SteamID()
    ContextTable.IsloateGlobal = vars.__ISOLATE_GLOBALS or false
    ContextTable.Upvalues = vars or {}
    local nils={
		["CLIENT"]=true,
		["SERVER"]=true,
	}
    ContextTable.META = {
        __index = function(self, key)
            local var = rawget(self, key)
            if var ~= nil then return var end
            local upval = ContextTable.Upvalues[key]
            if upval ~= nil then return upval end
            local gvar = _G[key]
            if gvar ~= nil then return gvar end
            if not nils [key] and easylua ~= nil then -- uh oh
                var = easylua.FindEntity(key)
                if var:IsValid() then
                    return var
                end
            end

            return nil
        end,
        __newindex = function(self, key, value)
            if ContextTable.IsloateGlobal then
                rawset(self, key, value)
                return
            end
            _G[key] = value
        end
    }
    ContextTable.EnvTable = setmetatable({},ContextTable.META)
    Environment.Contexts[runner] = Environment.Contexts[runner] or {}
    Environment.Contexts[runner][transferId] = ContextTable
    Environment.UsedContexts[runner] = Environment.UsedContexts[runner] or {}
    Environment.UpdateUpvals(ContextTable)

    table.insert(Environment.UsedContexts[runner], ContextTable)


    if vars.__NO_CAPTURE then
        return ContextTable
    end

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
    Noir.Msg("Cleared ", Color(0,150, 0), tostring(cleared), Color(255,255,255), " envs.")
end, nil, "Clears unused Noir environments")

concommand.Add("noir_clearenvs_all", function(ply)
    if SERVER and IsValid(ply) and not ply:IsSuperAdmin() then return end
    local cleared = 0
    for k, v in pairs(Environment.Contexts) do
        Environment.Contexts[k] = {}
    end
    Noir.Msg("Cleared ", Color(0,150, 0), tostring(cleared), Color(255,255,255), " envs.")
end, nil, "Clears unused Noir environments")