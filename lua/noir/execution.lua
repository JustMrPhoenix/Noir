function Noir.RunCode(code, identifier)
    identifier = identifier or "Noir.RunCode"
    local func, compile_err = CompileString(code, identifier, true)

    if not func then
        Noir.Error("Error compiling code: " .. compile_err, "\n")

        return nil, compile_err
    end

    local call_results = {pcall(func)}
    Noir.Debug("RunCode", identifier, call_results)

    if not table.remove(call_results, 1) then
        local msg = call_results[1]
        Noir.Error("Error pcalling code: " .. msg, "\n")

        return nil, msg
    end

    return true, call_results
end

-- Since the net.Receivers string table only has 2048 slots im going to use one string
-- One string to rule them all
local tag = "noir_networking"
local UIntSize = 3
Noir.NetworkTag = tag
Noir.CodeTransfers = {}

if SERVER then
    util.AddNetworkString(tag)
end

function Noir.SendCode(code, identifier, target)
    if util.NetworkStringToID( tag ) == 0 then
        Noir.Error("This server does not seem to run Noir")
        return
    end
    local transferId = string.format("%x", math.random(0x1000000000000, 0xfffffffffffff))
    while Noir.CodeTransfers[transferId] do -- Imagine this happening
        transferId = string.format("%x", math.random(0x1000000000000, 0xfffffffffffff))
    end
    local parts = {}

    if #code <= 61440 then
        parts = {code}
    else
        local codeLeft = code

        while #codeLeft > 61440 do
            table.insert(parts, string.sub(codeLeft, 1, 61440))
            codeLeft = string.sub(codeLeft, 61441)
        end

        table.insert(parts, codeLeft)
    end

    local data = {
        target = target,
        identifier = identifier,
        codeLength = #code,
        codeParts = #parts,
        codeCRC = util.CRC(code)
    }
    Noir.CodeTransfers[transferId] = data

    Noir.Debug("SendCode", data, code, parts)
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
end

-- UInt is zero based
Noir.NetReceivers = {
    [0] = function(ply) -- code transfer start
        local data = net.ReadTable()
        local transferId = net.ReadString()
        local target = data.target
        local tbl = Noir.CodeTransfers[ply] or {}
        Noir.CodeTransfers[ply] = tbl
        tbl[transferId] = data
        Noir.Debug("TransferStart", transferId, data)

        if SERVER and target ~= "server" then
            if target == "shared" or target == "clients" then
                target = player.GetHumans()
            end

            net.Start(tag)
            net.WriteEntity(ply)
            net.WriteUInt(0, UIntSize)
            net.WriteTable(data)
            net.WriteString(transferId)
            net.Send(target)
            if data.target ~= "shared" and data.target ~= "server" then return end
        end

        data.code = ""
        data.receivedParts = 0
    end,
    [1] = function(ply) -- code part
        local transferId = net.ReadString()
        local part = net.ReadString()
        local info = Noir.CodeTransfers[ply][transferId]
        local target = info.target

        if SERVER and target ~= "server" then
            if target == "shared" or target == "clients" then
                target = player.GetHumans()
            end

            net.Start(tag)
            net.WriteEntity(ply)
            net.WriteUInt(1, UIntSize)
            net.WriteString(transferId)
            net.WriteString(part)
            net.Send(target)
            if info.target ~= "shared" and info.target ~= "server" then return end
        end

        info.code = info.code .. part
        info.receivedParts = info.receivedParts + 1
        Noir.Debug("CodePart", transferId, info.receivedParts, info.codeParts)

        if info.receivedParts == info.codeParts then
            Noir.Debug("ReceivedAllCode", transferId, code, info.code)

            if util.CRC(info.code) ~= info.codeCRC then
                Noir.Error("Code CRC missmatch!")

                return
            end

            if #info.code ~= info.codeLength then
                Noir.Error("Code length missmatch!")

                return
            end

            local done, returns = Noir.RunCode(info.code, info.identifier)
            if not done then ErrorNoHalt(returns) end
        end
    end
}

net.Receive(tag, function(len, ply)
    local sender = SERVER and ply or net.ReadEntity()
    if SERVER and not sender:IsSuperAdmin() then return end
    if CLIENT and sender ~= Entity(0) and (sender:IsPlayer() and not sender:IsSuperAdmin()) then return end
    Noir.NetReceivers[net.ReadUInt(UIntSize)](sender)
end)