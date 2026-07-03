local Network = Noir.Network or {}
Noir.Network = Network
local tag = "noir_networking"
local UIntSize = 3
-- Max bytes per string part. Each net message carries one chunk; this keeps a
-- single message comfortably under the net buffer limit.
local MAX_CHUNK_SIZE = 61440
Network.Tag = tag
Network.Transfers = {}
Network.UIntSize = UIntSize
-- Since the net.Receivers string table only has 2048 slots im going to use one string
-- One string to rule them all
if SERVER then util.AddNetworkString(tag) end
-- A table for callbacks
Network.StringHandlers = {}
local function callHandler(handlerName, eventName, ...)
	if not Network.StringHandlers[handlerName] then return end
	local handlers = Network.StringHandlers[handlerName]
	if not handlers[eventName] then return end
	handlers[eventName](...)
end

-- Access gate for incoming code transfers. The NoirSendCode hook gets the first
-- say (receiving the sender and the run target): if any listener returns a
-- non-nil value we honor it, otherwise script replies (a run's output going back
-- to its runner) are validated against the original transfer and everything else
-- falls back to the superadmin check.
-- Only consulted on the server (the authority for CL -> SV and CL -> SH/CLS
-- runs) — clients trust transfers relayed by the server, and local "self" runs
-- never reach the network so they skip this entirely.
function Network.CheckAccess(sender, target, data)
	local allowed = hook.Run("NoirSendCode", sender, target)
	if allowed ~= nil then return allowed == true end
	if data and data.type == "scriptMessage" then
		return Network.IsReplyAllowed(sender, target, data.origTransferId)
	end

	return sender:IsSuperAdmin()
end

-- A scriptMessage is a reply: output flowing back to whoever initiated a run.
-- The replying player doesn't need superadmin — they were targeted, not acting —
-- but the reply must reference a transfer we actually relayed: it has to exist,
-- belong to the runner it's addressed to, and have included the replier in its
-- targets.
function Network.IsReplyAllowed(sender, target, origTransferId)
	if not origTransferId then return false end
	if target == "server" then
		-- Reply to a server-initiated run: the server reserved the ID locally
		-- in GenerateTransferId.
		return Network.Transfers[origTransferId] ~= nil
	end

	if not (isentity(target) and IsValid(target) and target:IsPlayer()) then return false end
	local transfers = Network.Transfers[target:SteamID()]
	local orig = transfers and transfers[origTransferId]
	if not istable(orig) then return false end
	if orig.target == "clients" or orig.target == "shared" then return true end
	return orig.target == sender
end

Network.Receivers = {
	[0] = function(sender)
		-- TrasnferID setup
		local transferId = net.ReadString()
		local data = net.ReadTable()
		local target = data.target
		local senderID = sender ~= Entity(0) and sender:SteamID() or "SERVER"
		local tbl = Network.Transfers[senderID] or {}
		Network.Transfers[senderID] = tbl
		if SERVER and not Network.CheckAccess(sender, target, data) then
			-- The string parts are already on the wire (staggered timers sender-side);
			-- mark the transfer so they get dropped silently instead of erroring as
			-- "non existing transfer".
			tbl[transferId] = "DENIED"
			return
		end

		tbl[transferId] = data
		Noir.Debug("TransferStart", transferId, data)
		callHandler(data.type, "start", sender, transferId, data)
		if SERVER and target ~= "server" then
			local sendTo = target
			if target == "shared" or target == "clients" then sendTo = player.GetHumans() end
			if not sendTo or (isentity(sendTo) and not (IsValid(sendTo) and sendTo:IsPlayer())) then
				tbl[transferId] = "DENIED"
				Noir.Error("Dropping transfer to invalid target! ID: ", transferId, "\n")
				return
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
	[1] = function(sender)
		-- string part
		local transferId = net.ReadString()
		-- Length-prefixed binary read so chunks containing \x00 survive (net.ReadString
		-- truncates at the first null byte).
		local part = net.ReadData(net.ReadUInt(17))
		local transfers = Network.Transfers[sender ~= Entity(0) and sender:SteamID() or "SERVER"]
		local info = transfers and transfers[transferId]
		-- Parts of a denied/dropped transfer keep arriving on their own timers
		if info == "DENIED" then return end
		if not istable(info) then
			Noir.ErrorT("Received string part for non existing transfer! ID: ", transferId)
			return
		end

		local target = info.target
		if SERVER and not Network.CheckAccess(sender, target, info) then return end
		if SERVER and target ~= "server" then
			local sendTo = target
			if target == "shared" or target == "clients" then sendTo = player.GetHumans() end
			if not sendTo or (isentity(sendTo) and not (IsValid(sendTo) and sendTo:IsPlayer())) then
				transfers[transferId] = "DENIED"
				Noir.Error("Dropping transfer to invalid target! ID: ", transferId, "\n")
				return
			end

			net.Start(tag)
			net.WriteEntity(sender)
			net.WriteUInt(1, UIntSize)
			net.WriteString(transferId)
			net.WriteUInt(#part, 17)
			net.WriteData(part, #part)
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
				Noir.ErrorT("String CRC mismatch!")
				return
			end

			if #info.string ~= info.stringLength then
				Noir.ErrorT("String length mismatch!")
				return
			end

			callHandler(info.type, "received", sender, transferId, info)
		end
	end,
}

function Network.StartTransfer(transferId, data, target)
	net.Start(tag)
	if SERVER then net.WriteEntity(Entity(0)) end
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
		-- Genuine pacing: stagger chunks 0.2s apart so a large transfer doesn't
		-- flood the net channel (and trip the reliable-channel overflow) in one tick.
		timer.Simple(k * 0.2, function()
			net.Start(tag)
			if SERVER then net.WriteEntity(Entity(0)) end
			net.WriteUInt(1, UIntSize)
			net.WriteString(transferId)
			net.WriteUInt(#v, 17)
			net.WriteData(v, #v)
			if SERVER then
				net.Send(target)
			else
				net.SendToServer()
			end
		end)
	end
end

function Network.SendTransfer(transferId, data, stringType, string, target)
	if not transferId then transferId = Network.GenerateTransferId() end
	data.type = data.type or stringType
	if not data.type then Noir.ErrorT("Cant start transfer without data type!") end
	local parts
	data.stringLength = #string
	data.stringCRC = util.CRC(string)
	if data.stringLength <= MAX_CHUNK_SIZE then
		parts = {string}
	else
		parts = {}
		local stringLeft = string
		while #stringLeft > MAX_CHUNK_SIZE do
			table.insert(parts, string.sub(stringLeft, 1, MAX_CHUNK_SIZE))
			stringLeft = string.sub(stringLeft, MAX_CHUNK_SIZE + 1)
		end

		table.insert(parts, stringLeft)
	end

	data.stringParts = #parts
	Network.StartTransfer(transferId, data, target)
	-- TODO: Send string with data if we can
	--      Maybe do a mannual WriteTable and check if space left at the end
	Network.SendParts(transferId, parts, target)
end

function Network.GenerateTransferId()
	local transferId = Format("%x", math.random(0x1000000000000, 0xfffffffffffff))
	while Network.Transfers[transferId] do
		-- Imagine this happening
		transferId = Format("%x", math.random(0x1000000000000, 0xfffffffffffff))
	end

	Network.Transfers[transferId] = "RESERVED_" .. os.time()
	return transferId
end

net.Receive(tag, function(len, ply)
	local sender = SERVER and ply or net.ReadEntity()
	Network.Receivers[net.ReadUInt(UIntSize)](sender)
end)
