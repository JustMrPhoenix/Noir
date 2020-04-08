local Network = Noir.Network or {}
Noir.Network = Network
local tag = "noir_networking"
local UIntSize = 3
Network.Tag = tag
Network.Transfers = {}
Network.UIntSize = UIntSize


-- Since the net.Receivers string table only has 2048 slots im going to use one string
-- One string to rule them all
if SERVER then
    util.AddNetworkString(tag)
end

-- A table for callbacks
Network.StringHandlers = {}

local function callHandler(handlerName, eventName, ...)
    if not Network.StringHandlers[handlerName] then return end
    local handlers = Network.StringHandlers[handlerName]
    if not handlers[eventName] then return end
    handlers[eventName](...)
end

Network.Receivers = {
    [0] = function(sender) -- TrasnferID setup
        if SERVER and not sender:IsSuperAdmin() then return end
        if CLIENT and sender ~= Entity(0) and (sender:IsPlayer() and not sender:IsSuperAdmin()) then return end
        local transferId = net.ReadString()
        local data = net.ReadTable()
        local target = data.target
        local senderID = sender ~= Entity(0) and sender:SteamID() or "SERVER"
        local tbl = Network.Transfers[senderID] or {}
        Network.Transfers[senderID] = tbl
        tbl[transferId] = data
        Noir.Debug("TransferStart", transferId, data)

        callHandler(data.type, "start", sender, transferId, data)

        if SERVER and target ~= "server" then
            local sendTo = target
            if target == "shared" or target == "clients" then
                sendTo = player.GetHumans()
            end

            net.Start(tag)
            net.WriteEntity(sender)
            net.WriteUInt(0, UIntSize)
            net.WriteString(transferId)
            net.WriteTable(data)
            net.Send(sendTo)
            if data.target ~= "shared" and data.target ~= "server" then return end
        end

        data.string = ""
        data.receivedParts = 0
    end,
    [1] = function(sender) -- string part
        if SERVER and not sender:IsSuperAdmin() then return end
        if CLIENT and sender ~= Entity(0) and (sender:IsPlayer() and not sender:IsSuperAdmin()) then return end
        local transferId = net.ReadString()
        local part = net.ReadString()
        -- TODO: Fix sending \x00
        -- Noir.Debug("BytesLeft", net.BytesLeft())
        -- while ({net.BytesLeft()})[2] ~= 3 do
        --     part = part .. "\x00" .. net.ReadString()
        --     Noir.Debug("BytesLeft", net.BytesLeft())
        -- end
        local info = Network.Transfers[sender ~= Entity(0) and sender:SteamID() or "SERVER"][transferId]
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

        info.string = info.string .. part
        info.receivedParts = info.receivedParts + 1
        callHandler(info.type, "part", sender, transferId, info)
        Noir.Debug("StringPart", transferId, info.receivedParts, info.stringParts)

        if info.receivedParts == info.stringParts then
            Noir.Debug("ReceivedAllParts", transferId, info.string)

            if util.CRC(info.string) ~= info.stringCRC then
                Noir.ErrorT("String CRC missmatch!")
                return
            end

            if #info.string ~= info.stringLength then
                Noir.ErrorT("String length missmatch!")
                return
            end

            callHandler(info.type, "received", sender, transferId, info)
        end
    end,
}

function Network.StartTransfer(transferId, data, target)
    net.Start(tag)

    if SERVER then
        net.WriteEntity(Entity(0))
    end

    net.WriteUInt(0, UIntSize)
    net.WriteString(transferId)
    net.WriteTable(data)

    if SERVER then
        net.Send(target)
    else
        net.SendToServer()
    end
end

function Network.SendParts(transferId, partsTable, target)
    for k, v in pairs(partsTable) do
        timer.Simple(k * 0.2, function()
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

function Network.SendTransfer(transferId, data, stringType, string, target)
    if not transferId then
        transferId = Network.GenerateTransferId()
    end
    data.type = data.type or stringType
    if not data.type then
        Noir.ErrorT("Cant start transfer without data type!")
    end
    local parts
    data.stringLength = #string
    data.stringCRC = util.CRC(string)
    if data.stringLength <= 61440 then
        parts = {string}
    else
        parts = {}
        local stringLeft = string
        while #stringLeft > 61440 do
            table.insert(parts, string.sub(stringLeft, 1, 61440))
            stringLeft = string.sub(stringLeft, 61441)
        end

        table.insert(parts, stringLeft)
    end
    data.stringParts = #parts
    Network.StartTransfer(transferId, data, target)
    Network.SendParts(transferId, parts, target)
end

function Network.GenerateTransferId()
    local transferId = Format("%x", math.random(0x1000000000000, 0xfffffffffffff))
    while Network.Transfers[transferId] do -- Imagine this happening
        transferId = Format("%x", math.random(0x1000000000000, 0xfffffffffffff))
    end
    Network.Transfers[transferId] = "RESERVED_" .. os.time()
    return transferId
end

net.Receive(tag, function(len, ply)
    local sender = SERVER and ply or net.ReadEntity()
    Network.Receivers[net.ReadUInt(UIntSize)](sender)
end)