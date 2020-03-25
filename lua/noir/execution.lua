function Noir.RunCode(code, identifier, environment)
    identifier = identifier or "Noir.RunCode"
    local compileResults = CompileString(code, identifier, false)

    if not isfunction(compileResults) then
        Noir.Error("[", identifier, "] Error compiling code: " .. compileResults, "\n")

        return false, compileResults
    end

    if environment then
        debug.setfenv(compileResults, environment)
    end

    local call_results = {pcall(compileResults)}
    Noir.Debug("RunCode", identifier, call_results)

    if not table.remove(call_results, 1) then
        local msg = call_results[1]
        Noir.Error("[", identifier, "] Error pcalling code: " .. msg, "\n")
        return false, msg
    end

    return true, call_results
end

-- Since the net.Receivers string table only has 2048 slots im going to use one string
-- One string to rule them all
local tag = "noir_networking"
local UIntSize = 3
Noir.NetworkTag = tag
Noir.CodeTransfers = {}
Noir.NetworkUIntSize = UIntSize

if SERVER then
    util.AddNetworkString(tag)
end

function Noir.GenerateTransferId()
    local transferId = string.format("%x", math.random(0x1000000000000, 0xfffffffffffff))
    while Noir.CodeTransfers[transferId] do -- Imagine this happening
        transferId = string.format("%x", math.random(0x1000000000000, 0xfffffffffffff))
    end
    Noir.CodeTransfers[transferId] = "RESERVED_" .. os.time()
    return transferId
end

function Noir.SendCode(code, identifier, target, transferId)
    if util.NetworkStringToID( tag ) == 0  and target ~= "self" then
        Noir.Error("This server does not seem to run Noir")
        return
    end
    if not transferId then
        transferId = Noir.GenerateTransferId()
    end
    local parts = {}

    local data = {
        target = target,
        identifier = identifier,
        codeLength = #code,
        codeCRC = util.CRC(code),
        vars = Noir.Environment.MakeVars()
    }
    Noir.CodeTransfers[transferId] = data

    if target == "self" then
        -- Give time to register handlers and stuff
        local me = SERVER and Entity(0) or LocalPlayer()
        local context = Noir.Environment.CreateContext(me, transferId, Noir.Environment.MakeVars())
        local done, returns = Noir.RunCode(code, identifier, context.EnvTable)
        Noir.Environment.SendMessage(me, transferId, "run", {done, returns})
        if not done then
            ErrorNoHalt(returns .. "\n")
        end
        return transferId
    end

    if data.codeLength <= 61440 then
        parts = {code}
    else
        local codeLeft = code

        while #codeLeft > 61440 do
            table.insert(parts, string.sub(codeLeft, 1, 61440))
            codeLeft = string.sub(codeLeft, 61441)
        end

        table.insert(parts, codeLeft)
    end
    data.codeParts = #parts

    Noir.Debug("SendCode", data, code, data.parts)
    net.Start(tag)

    if SERVER then
        net.WriteEntity(Entity(0))
    end

    net.WriteUInt(0, UIntSize)
    net.WriteTable(data)
    net.WriteString(transferId)

    if SERVER then
        net.Send(target)
    else
        net.SendToServer()
    end

    for k, v in pairs(parts) do
        timer.Simple(k * 0.1, function()
            net.Start(tag)

            if SERVER then
                net.WriteEntity(Entity(0))
            end

            net.WriteUInt(1, UIntSize)
            net.WriteString(transferId)
            net.WriteString(v)

            if SERVER then
                net.Send(target)
            else
                net.SendToServer()
            end
        end)
    end
    return transferId
end

-- UInt is zero based
Noir.NetReceivers = {
    [0] = function(sender) -- code transfer start
        if SERVER and not sender:IsSuperAdmin() then return end
        if CLIENT and sender ~= Entity(0) and (sender:IsPlayer() and not sender:IsSuperAdmin()) then return end
        local data = net.ReadTable()
        local transferId = net.ReadString()
        local target = data.target
        local senderID = sender ~= Entity(0) and sender:SteamID() or "SERVER"
        local tbl = Noir.CodeTransfers[senderID] or {}
        Noir.CodeTransfers[senderID] = tbl
        tbl[transferId] = data
        Noir.Debug("TransferStart", transferId, data)
        Noir.Msg( "Sending code(", Color(0, 120, 205), transferId, Color(255,255,255), "): ", -- ):
            Color(230, 220, 115), data.identifier, Color(255,255,255), " [",
            Color(0,150,0), sender == Entity(0) and "(SERVER)" or sender:Nick() .. "(" .. sender:SteamID() .. ")",
            Color(255,255,255), " => ",
            Color(0,150,0), isentity(target) and target:Nick() .. "(" .. target:SteamID() .. ")" or target:upper(),
            Color(255,255,255), "]\n"
        )
        if SERVER and target ~= "server" then
            local sendTo = target
            if target == "shared" or target == "clients" then
                sendTo = player.GetHumans()
            end

            net.Start(tag)
            net.WriteEntity(sender)
            net.WriteUInt(0, UIntSize)
            net.WriteTable(data)
            net.WriteString(transferId)
            net.Send(sendTo)
            if data.target ~= "shared" and data.target ~= "server" then return end
        end

        data.code = ""
        data.receivedParts = 0
    end,
    [1] = function(sender) -- code part
        if SERVER and not sender:IsSuperAdmin() then return end
        if CLIENT and sender ~= Entity(0) and (sender:IsPlayer() and not sender:IsSuperAdmin()) then return end
        local transferId = net.ReadString()
        local part = net.ReadString()
        local info = Noir.CodeTransfers[sender ~= Entity(0) and sender:SteamID() or "SERVER"][transferId]
        local target = info.target

        if SERVER and target ~= "server" then
            local sendTo = target
            if target == "shared" or target == "clients" then
                sendTo = player.GetHumans()
            end

            net.Start(tag)
            net.WriteEntity(sender)
            net.WriteUInt(1, UIntSize)
            net.WriteString(transferId)
            net.WriteString(part)
            net.Send(sendTo)
            if info.target ~= "shared" and info.target ~= "server" then return end
        end

        info.code = info.code .. part
        info.receivedParts = info.receivedParts + 1
        Noir.Debug("CodePart", transferId, info.receivedParts, info.codeParts)

        if info.receivedParts == info.codeParts then
            Noir.Debug("ReceivedAllCode", transferId, info.code)

            if util.CRC(info.code) ~= info.codeCRC then
                Noir.Error("Code CRC missmatch!")

                return
            end

            if #info.code ~= info.codeLength then
                Noir.Error("Code length missmatch!")

                return
            end
            local context = Noir.Environment.CreateContext(sender, transferId, info.vars)
            local done, returns = Noir.RunCode(info.code, info.identifier, context.EnvTable)
            Noir.Environment.SendMessage(sender, transferId, "run", {done, returns})
            if not done then
                ErrorNoHalt(returns .. "\n")
            end
        end
    end,
    [2] = nil, -- RunCode results and additional output. see environment.lua
}

net.Receive(tag, function(len, ply)
    local sender = SERVER and ply or net.ReadEntity()
    Noir.NetReceivers[net.ReadUInt(UIntSize)](sender)
end)