local Environment = Noir.Environment or {}
Noir.Environment = Environment

function Environment.MakeVars()
    -- Totally did not steal most of this code from easylua
    local ply = LocalPlayer()
    if SERVER or not IsValid(ply) then return {} end
    local vars = {}
    vars.me = ply
    local trace = util.QuickTrace(ply:EyePos(), ply:GetAimVector() * 10000, {ply, ply:GetVehicle()})
    vars.trace = trace
    vars.this = trace.Entity
    vars.there = trace.HitPos
    vars.here = trace.StartPos
    vars.normal = trace.HitNormal
    vars.length = trace.StartPos:Distance(trace.HitPos)

    if vars.this:IsValid() then
        vars.phys = vars.this:GetPhysicsObject()
        vars.model = vars.this:GetModel()
    end

    vars.we = {}
    for _, v in pairs(ents.FindInSphere(ply:GetPos(), 512)) do
        if v:IsPlayer() then
            table.insert(vars.we, v)
        end
    end

    vars.dir = ply:GetAimVector()

    return vars
end

function Environment.SendMessage(target, transferId, message, data)
    Noir.Debug("Env.SendMessage", target, transferId, message, data)
    if target == SERVER and Entity(0) or LocalPlayer() then
        Environment.OnMessage(target, transferId, message, data)
        return
    end
    net.Start(Noir.NetworkTag)
    if SERVER then net.WriteEntity(Entity(0)) end
    net.WriteUInt(2, Noir.NetworkUIntSize)
    net.WriteEntity(target)
    net.WriteString(transferId)
    net.WriteString(message)
    net.WriteTable(data)
    if SERVER then
        net.Send(target)
    else
        net.SendToServer()
    end
end

Noir.NetReceivers[2] = function (sender)
    local destination = net.ReadEntity()
    local transferId = net.ReadString()
    local message = net.ReadString()
    local data = net.ReadTable()
    if SERVER and destination ~= Entity(0) then
        net.Start(tag)
        net.WriteEntity(sender)
        net.WriteUInt(2, UIntSize)
        net.WriteEntity(destination)
        net.WriteString(transferId)
        net.WriteString(message)
        net.WriteTable(data)
        net.Send(destination)
    elseif destination == SERVER and Entity(0) or LocalPlayer() then
        Noir.Environment.OnMessage(sender, transferId, message, data)
    else
        Noir.Error("Got unexptected scipt message from ", Color(0,200,0), sender)
    end
end

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

function Environment.CreateContext(runner, transferId, vars)
    local ContextTable = {}
    ContextTable.Runner = runner
    ContextTable.RunnerSteamID = runner:SteamID()
    ContextTable.IsloateGlobal = vars.__ISOLATE_GLOBALS or false
    ContextTable.Upvalues = vars or {}
    ContextTable.META = {
        __index = function(self, key)
            local var = rawget(self, key)
            if var ~= nil then return var end
            local upval = ContextTable.Upvalues[key]
            if upval ~= nil then return upval end
            local gvar = _G[key]
            if gvar ~= nil then return gvar end
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
    if SERVER and not IsValid(ply) and not ply:IsSuperAdmin() then return end
    for k, v in pairs(Environment.Contexts) do
        if not IsValid(k) then
            Environment.Contexts[k] = nil
        end
    end
end, nil, "Clears unused Noir environments")