local Network = Noir.Network or {}
Noir.Network = Network
local tag = "noir_networking"
local UIntSize = 3
-- Max bytes per chunk. Each net message carries one chunk; kept below GMod's ~65533
-- net-message cap with headroom for the metadata table (routing, a run's vars) that
-- travels alongside -- so a single-chunk payload plus its metadata fits in one
-- message. That's exactly what the "quick" frame relies on.
local MAX_CHUNK_SIZE = 61440
Network.Tag = tag
Network.UIntSize = UIntSize
-- The net.Receivers string table only has 2048 slots, so everything rides one
-- string; a UInt(3) sub-type selects quick (0) / chunked header (1) / chunked part
-- (2) / close (3).
if SERVER then util.AddNetworkString(tag) end

-- CHANNELS are the only networking abstraction. A channel is a long-lived,
-- server-mediated, bidirectional session identified by a channelId. The chunked
-- transfer machinery below is a private transport for channel frames; there is no
-- public "transfer" concept and no persistent per-transfer table.
--
--   Network.Channels[id]  = persistent session record {id,type,opener,target,handlers,onClose,nextSeq}
--   Network.Assembly[key] = ephemeral reassembly of a chunked message, freed on completion
--   Network.Routing[key]  = ephemeral server-side relay routing for an in-flight message
--   Network.ChannelHandlers[type] = {open=fn, close=fn, oneshot=bool} -- how to react to an opened channel
Network.Channels = Network.Channels or {}
Network.Assembly = Network.Assembly or {}
Network.Routing = Network.Routing or {}
Network.ChannelHandlers = Network.ChannelHandlers or {}

----------------------------------------------------------------------
-- helpers
----------------------------------------------------------------------
-- Endpoint values (a channel's target / a frame's dst) are one of: "self" (never
-- networked), "server", "clients", "shared", or a Player. The server endpoint is
-- Entity(0) as an entity but "server" as a destination string; normalize so the two
-- compare equal.
local function normDest(x)
	if x == Entity(0) then return "server" end
	return x
end

local function sameEndpoint(a, b)
	return normDest(a) == normDest(b)
end

-- Players a destination expands to for net.Send (nil = server-local only).
local function resolveRemote(dst)
	dst = normDest(dst)
	if dst == "server" then return nil end
	if dst == "shared" or dst == "clients" then return player.GetHumans() end
	if isentity(dst) and IsValid(dst) and dst:IsPlayer() then return {dst} end
	return nil
end

-- Does this destination include the local machine (server) as a recipient?
local function isLocalDest(dst)
	dst = normDest(dst)
	return dst == "server" or dst == "shared"
end

local function senderKey(sender)
	return sender ~= Entity(0) and sender:SteamID() or "SERVER"
end

local function assemblyKey(sender, channelId, seq)
	return senderKey(sender) .. "/" .. channelId .. "/" .. seq
end

local function chunkString(s)
	if #s <= MAX_CHUNK_SIZE then return {s} end
	local parts, left = {}, s
	while #left > MAX_CHUNK_SIZE do
		table.insert(parts, string.sub(left, 1, MAX_CHUNK_SIZE))
		left = string.sub(left, MAX_CHUNK_SIZE + 1)
	end

	table.insert(parts, left)
	return parts
end

----------------------------------------------------------------------
-- auth
----------------------------------------------------------------------
-- Gate for OPENING a channel (and thus for running code). The NoirSendCode hook
-- gets first say; otherwise superadmin only. Consulted on the server only — clients
-- trust relayed frames, and local "self" runs never touch the network.
function Network.CheckAccess(sender, target, data)
	local allowed = hook.Run("NoirSendCode", sender, target, data)
	if allowed ~= nil then return allowed == true end
	return sender:IsSuperAdmin()
end

-- A message/close on an EXISTING channel is authorized by membership, not
-- superadmin: the sender must be the opener (so an admin's follow-ups / refining are
-- allowed) or an authorized target (so a targeted client's replies are allowed).
function Network.IsChannelAllowed(sender, channelId)
	local ch = Network.Channels[channelId]
	if not ch then return false end
	if sameEndpoint(sender, ch.opener) then return true end
	local t = ch.target
	if t == "server" or t == "clients" or t == "shared" then return true end
	return isentity(t) and IsValid(t) and t:IsPlayer() and t == sender
end

-- Where a given sender is allowed to address on a channel: the opener may only reach
-- its target(s); a target may only reach the opener. Prevents a client redirecting
-- traffic to an arbitrary player.
local function validDest(ch, sender, dst)
	if sameEndpoint(sender, ch.opener) then return sameEndpoint(dst, ch.target) end
	return sameEndpoint(dst, ch.opener)
end

----------------------------------------------------------------------
-- channel records & dispatch
----------------------------------------------------------------------
function Network.GenerateChannelId()
	local id = Format("%x", math.random(0x1000000000000, 0xfffffffffffff))
	while Network.Channels[id] do
		id = Format("%x", math.random(0x1000000000000, 0xfffffffffffff))
	end

	return id
end

-- Fetch-or-create a channel record, merging fields (so an early OnChannel and a
-- later OpenChannel share one record).
function Network.ensureRecord(channelId, fields)
	local ch = Network.Channels[channelId]
	if not ch then
		ch = {id = channelId, handlers = {list = {}, byMsg = {}}, onClose = {}, nextSeq = 0}
		Network.Channels[channelId] = ch
	end

	ch.type = ch.type or fields.type
	if ch.target == nil then ch.target = fields.target end
	if ch.opener == nil then ch.opener = fields.opener end
	return ch
end

-- Initiator: create the LOCAL opener record (no send yet). Register handlers with
-- OnChannel, then OpenSend.
function Network.OpenChannel(chType, target)
	local id = Network.GenerateChannelId()
	Network.ensureRecord(id, {
		type = chType,
		target = target,
		opener = SERVER and Entity(0) or LocalPlayer(),
	})

	return id
end

-- Register an instance handler. Omit `message` for "any message on this channel".
function Network.OnChannel(channelId, message, callback)
	if callback == nil then
		callback = message
		message = nil
	end

	local ch = Network.Channels[channelId] or Network.ensureRecord(channelId, {})
	if message then
		ch.handlers.byMsg[message] = ch.handlers.byMsg[message] or {}
		table.insert(ch.handlers.byMsg[message], callback)
	else
		table.insert(ch.handlers.list, callback)
	end
end

function Network.OnChannelClose(channelId, callback)
	local ch = Network.Channels[channelId] or Network.ensureRecord(channelId, {})
	table.insert(ch.onClose, callback)
end

function Network.DispatchChannel(channelId, sender, message, data)
	local ch = Network.Channels[channelId]
	if not ch then return end
	for _, cb in ipairs(ch.handlers.list) do cb(sender, channelId, message, data) end
	local byName = ch.handlers.byMsg[message]
	if byName then
		for _, cb in ipairs(byName) do cb(sender, channelId, message, data) end
	end
end

-- Local teardown of a channel record; fires its onClose hooks.
-- Drop any in-flight reassembly / relay-routing buffers for a channel (e.g. a
-- message half-received when the channel closes), so nothing lingers.
local function purgeChannelBuffers(channelId)
	local needle = "/" .. channelId .. "/"
	for key in pairs(Network.Assembly) do
		if string.find(key, needle, 1, true) then Network.Assembly[key] = nil end
	end

	for key in pairs(Network.Routing) do
		if string.find(key, needle, 1, true) then Network.Routing[key] = nil end
	end
end

function Network.dropChannel(channelId)
	local ch = Network.Channels[channelId]
	if not ch then return end
	Network.Channels[channelId] = nil
	purgeChannelBuffers(channelId)
	local h = ch.type and Network.ChannelHandlers[ch.type]
	if h and h.close then h.close(channelId, ch) end
	for _, cb in ipairs(ch.onClose or {}) do cb(channelId, ch) end
end

-- Deliver a fully-reassembled message to the local endpoint: an "open" runs the
-- type's open handler (creating the record if needed); anything else dispatches to
-- the channel's instance handlers.
local function endpointDeliver(sender, channelId, op, message, data)
	if op == "open" then
		Network.ensureRecord(channelId, {type = data.type, target = data.target, opener = sender})
		local h = Network.ChannelHandlers[data.type]
		if h and h.open then h.open(sender, channelId, data) end
		-- Fire-and-forget: no replies expected, drop the record immediately.
		if h and h.oneshot then Network.dropChannel(channelId) end
	else
		Network.DispatchChannel(channelId, sender, message, data)
	end
end

----------------------------------------------------------------------
-- reassembly (endpoint side: clients always, server when it's a recipient)
----------------------------------------------------------------------
local function startAssembly(sender, channelId, op, message, seq, parts, crc, len, extra)
	Network.Assembly[assemblyKey(sender, channelId, seq)] = {
		sender = sender,
		channelId = channelId,
		op = op,
		message = message,
		parts = parts,
		crc = crc,
		len = len,
		extra = extra,
		buf = "",
		got = 0,
	}
end

local function assemblyPart(sender, channelId, seq, chunk)
	local key = assemblyKey(sender, channelId, seq)
	local asm = Network.Assembly[key]
	if not asm then return end
	asm.buf = asm.buf .. chunk
	asm.got = asm.got + 1
	if asm.got < asm.parts then return end
	Network.Assembly[key] = nil
	if util.CRC(asm.buf) ~= asm.crc then
		Noir.ErrorT("Channel CRC mismatch! ", channelId)
		return
	end

	if #asm.buf ~= asm.len then
		Noir.ErrorT("Channel length mismatch! ", channelId)
		return
	end

	local data = asm.extra or {}
	data.string = asm.buf
	endpointDeliver(sender, channelId, asm.op, asm.message, data)
end

----------------------------------------------------------------------
-- sending
----------------------------------------------------------------------
-- A quick frame (sub-type 0) carries a whole single-chunk message in one net
-- message: no seq/parts/crc/len, no reassembly. Used for the common small payloads.
local function emitQuick(fromEnt, dest, channelId, op, message, extra, payload)
	if SERVER and (not dest or #dest == 0) then return end
	net.Start(tag)
	if SERVER then net.WriteEntity(fromEnt or Entity(0)) end
	net.WriteUInt(0, UIntSize)
	net.WriteString(channelId)
	net.WriteString(op or "msg")
	net.WriteString(message or "")
	net.WriteTable(extra or {})
	net.WriteUInt(#payload, 17)
	net.WriteData(payload, #payload)
	if SERVER then net.Send(dest) else net.SendToServer() end
end

local function emitHeader(fromEnt, dest, channelId, op, message, seq, parts, crc, len, extra)
	if SERVER and (not dest or #dest == 0) then return end
	net.Start(tag)
	if SERVER then net.WriteEntity(fromEnt or Entity(0)) end
	net.WriteUInt(1, UIntSize)
	net.WriteString(channelId)
	net.WriteString(op or "msg")
	net.WriteString(message or "")
	net.WriteUInt(seq, 32)
	net.WriteUInt(parts, 32)
	net.WriteString(crc or "")
	net.WriteUInt(len or 0, 32)
	net.WriteTable(extra or {})
	if SERVER then net.Send(dest) else net.SendToServer() end
end

local function emitPart(fromEnt, dest, channelId, seq, chunk)
	if SERVER and (not dest or #dest == 0) then return end
	net.Start(tag)
	if SERVER then net.WriteEntity(fromEnt or Entity(0)) end
	net.WriteUInt(2, UIntSize)
	net.WriteString(channelId)
	net.WriteUInt(seq, 32)
	net.WriteUInt(#chunk, 17)
	net.WriteData(chunk, #chunk)
	if SERVER then net.Send(dest) else net.SendToServer() end
end

-- Originate a message on a channel from THIS node. `dst` is the final destination
-- (carried in extra.dst so the server can route). If the destination is us, deliver
-- locally without touching the network.
local function originate(ch, op, message, payload, extra, dst)
	payload = payload or ""
	extra = extra or {}
	extra.dst = dst
	if (CLIENT and dst == LocalPlayer()) or (SERVER and normDest(dst) == "server") then
		extra.string = payload
		endpointDeliver(SERVER and Entity(0) or LocalPlayer(), ch.id, op, message, extra)
		return
	end

	local cid = ch.id
	local fromEnt = SERVER and Entity(0) or nil
	local dest = SERVER and resolveRemote(dst) or nil
	-- Quick path: a single-chunk payload rides one net message (payload + metadata
	-- inline), no seq/parts/crc/len/reassembly. Chosen automatically by size --
	-- MAX_CHUNK_SIZE already reserves net-cap headroom for the metadata; larger
	-- payloads fall through to the chunked path below.
	if #payload <= MAX_CHUNK_SIZE then
		emitQuick(fromEnt, dest, cid, op, message, extra, payload)
		return
	end

	local seq = ch.nextSeq or 0
	ch.nextSeq = seq + 1
	local parts = chunkString(payload)
	local crc = util.CRC(payload)
	local len = #payload
	emitHeader(fromEnt, dest, cid, op, message, seq, #parts, crc, len, extra)
	for i, chunk in ipairs(parts) do
		local idx = i
		timer.Simple((idx - 1) * 0.2, function()
			emitPart(fromEnt, dest, cid, seq, chunk)
		end)
	end
end

-- Send the opening message of a channel (carries the initial payload + metadata).
function Network.OpenSend(channelId, payload, data)
	local ch = Network.Channels[channelId]
	if not ch then
		Noir.ErrorT("OpenSend: unknown channel ", channelId)
		return
	end

	data = data or {}
	data.type = ch.type
	data.target = ch.target
	originate(ch, "open", "", payload, data, ch.target)
end

-- Send a message on an open channel. Either side, any number of times, no timeout.
-- `target` overrides the destination; by default the opener addresses its target(s)
-- and a responder addresses the opener.
function Network.SendOnChannel(channelId, message, payload, target)
	local ch = Network.Channels[channelId]
	if not ch then
		Noir.ErrorT("SendOnChannel: unknown channel ", channelId)
		return
	end

	local dst = target
	if dst == nil then
		if sameEndpoint(SERVER and Entity(0) or LocalPlayer(), ch.opener) then
			dst = ch.target
		else
			dst = ch.opener
		end
	end

	originate(ch, "msg", message, payload, nil, dst)
end

-- Fire-and-forget: open a one-shot channel, send its payload, drop our record. No
-- replies; the responder drops its record right after the open handler.
function Network.Fire(chType, payload, target)
	local id = Network.OpenChannel(chType, target)
	Network.OpenSend(id, payload)
	Network.Channels[id] = nil
	return id
end

-- Explicit teardown. Drops our record (firing onClose) and tells the other end (and
-- relay targets, via the close frame / Receivers[3]) to drop theirs.
function Network.CloseChannel(channelId, target)
	local ch = Network.Channels[channelId]
	target = target or (ch and ch.target)
	-- Only network the close if the channel was actually networked: `self` runs are
	-- local-only, and when the server isn't running Noir the net string is
	-- unregistered (net.Start would error). Either way, just drop it locally so
	-- unsubscribing still works.
	if target ~= "self" and util.NetworkStringToID(tag) ~= 0 then
		if CLIENT then
			net.Start(tag)
			net.WriteUInt(3, UIntSize)
			net.WriteString(channelId)
			net.SendToServer()
		else
			local remote = resolveRemote(target)
			if remote and #remote > 0 then
				net.Start(tag)
				net.WriteEntity(Entity(0))
				net.WriteUInt(3, UIntSize)
				net.WriteString(channelId)
				net.Send(remote)
			end
		end
	end

	Network.dropChannel(channelId)
end

----------------------------------------------------------------------
-- server routing (relay + local delivery)
----------------------------------------------------------------------
-- Quick frame server handling: same auth/relay/local logic as serverHandleHeader
-- but for a whole single-message frame -- no Routing/Assembly bookkeeping.
local function serverHandleQuick(sender, channelId, op, message, extra, payload)
	local dst = extra.dst
	local ch = Network.Channels[channelId]
	if op == "open" then
		if not Network.CheckAccess(sender, extra.target, {channelOp = "open"}) then return end
		ch = Network.ensureRecord(channelId, {type = extra.type, target = extra.target, opener = sender})
		local h = Network.ChannelHandlers[extra.type]
		if h and h.serverOpen then h.serverOpen(sender, channelId, extra) end
	elseif not ch or not Network.IsChannelAllowed(sender, channelId) then
		return
	end

	if not validDest(ch, sender, dst) then return end
	local remote = resolveRemote(dst)
	if remote then emitQuick(sender, remote, channelId, op, message, extra, payload) end
	if isLocalDest(dst) then
		extra.string = payload
		endpointDeliver(sender, channelId, op, message, extra)
	end

	-- A relayed one-shot open needs no persistent record (no follow-up frames).
	if op == "open" and not isLocalDest(dst) then
		local h = Network.ChannelHandlers[extra.type]
		if h and h.oneshot then Network.Channels[channelId] = nil end
	end
end

local function serverHandleHeader(sender, channelId, op, message, seq, parts, crc, len, extra)
	local key = assemblyKey(sender, channelId, seq)
	local dst = extra.dst
	local ch = Network.Channels[channelId]
	if op == "open" then
		if not Network.CheckAccess(sender, extra.target, {channelOp = "open"}) then
			Network.Routing[key] = {drop = true, parts = parts, got = 0}
			return
		end

		ch = Network.ensureRecord(channelId, {type = extra.type, target = extra.target, opener = sender})
		-- Server-side hook when an open is received/relayed: lets a channel type
		-- augment `extra` before it's forwarded/reassembled (e.g. runCode injects
		-- server-only vars) and do relay-time logging. Runs before emitHeader below so
		-- both the relayed copy and the server's own endpoint copy see the mutation.
		local h = Network.ChannelHandlers[extra.type]
		if h and h.serverOpen then h.serverOpen(sender, channelId, extra) end
	elseif not ch or not Network.IsChannelAllowed(sender, channelId) then
		Network.Routing[key] = {drop = true, parts = parts, got = 0}
		return
	end

	if not validDest(ch, sender, dst) then
		Network.Routing[key] = {drop = true, parts = parts, got = 0}
		return
	end

	local remote = resolveRemote(dst)
	local toLocal = isLocalDest(dst)
	Network.Routing[key] = {remote = remote, isLocal = toLocal, parts = parts, got = 0}
	if remote then emitHeader(sender, remote, channelId, op, message, seq, parts, crc, len, extra) end
	if toLocal then startAssembly(sender, channelId, op, message, seq, parts, crc, len, extra) end
	-- A one-shot channel we only relay (not an endpoint of) needs no persistent
	-- record: there are no follow-up frames to authorize. Its parts still relay via
	-- Routing.
	if op == "open" and not toLocal then
		local h = Network.ChannelHandlers[extra.type]
		if h and h.oneshot then Network.Channels[channelId] = nil end
	end
end

local function serverHandlePart(sender, channelId, seq, chunk)
	local key = assemblyKey(sender, channelId, seq)
	local r = Network.Routing[key]
	if not r then return end
	r.got = r.got + 1
	if not r.drop then
		if r.remote then emitPart(sender, r.remote, channelId, seq, chunk) end
		if r.isLocal then assemblyPart(sender, channelId, seq, chunk) end
	end

	if r.got >= r.parts then Network.Routing[key] = nil end
end

----------------------------------------------------------------------
-- receive dispatch
----------------------------------------------------------------------
Network.Receivers = {
	-- 0 = quick: a whole single-chunk message in one net message.
	[0] = function(sender)
		local channelId = net.ReadString()
		local op = net.ReadString()
		local message = net.ReadString()
		local extra = net.ReadTable()
		local payload = net.ReadData(net.ReadUInt(17))
		if SERVER then
			serverHandleQuick(sender, channelId, op, message, extra, payload)
		else
			extra.string = payload
			endpointDeliver(sender, channelId, op, message, extra)
		end
	end,
	-- 1 = chunked message header.
	[1] = function(sender)
		local channelId = net.ReadString()
		local op = net.ReadString()
		local message = net.ReadString()
		local seq = net.ReadUInt(32)
		local parts = net.ReadUInt(32)
		local crc = net.ReadString()
		local len = net.ReadUInt(32)
		local extra = net.ReadTable()
		if SERVER then
			serverHandleHeader(sender, channelId, op, message, seq, parts, crc, len, extra)
		else
			startAssembly(sender, channelId, op, message, seq, parts, crc, len, extra)
		end
	end,
	-- 2 = chunked message part.
	[2] = function(sender)
		local channelId = net.ReadString()
		local seq = net.ReadUInt(32)
		-- Length-prefixed binary read so chunks containing \x00 survive.
		local chunk = net.ReadData(net.ReadUInt(17))
		if SERVER then
			serverHandlePart(sender, channelId, seq, chunk)
		else
			assemblyPart(sender, channelId, seq, chunk)
		end
	end,
	-- 3 = close.
	[3] = function(sender)
		local channelId = net.ReadString()
		local ch = Network.Channels[channelId]
		-- Relay the close to the channel's other participant(s) so they tear down too.
		if SERVER and ch then
			local dst = sameEndpoint(sender, ch.opener) and ch.target or ch.opener
			local remote = resolveRemote(dst)
			if remote and #remote > 0 then
				net.Start(tag)
				net.WriteEntity(sender)
				net.WriteUInt(3, UIntSize)
				net.WriteString(channelId)
				net.Send(remote)
			end
		end

		Network.dropChannel(channelId)
	end,
}

net.Receive(tag, function(len, ply)
	local sender = SERVER and ply or net.ReadEntity()
	Network.Receivers[net.ReadUInt(UIntSize)](sender)
end)

if SERVER then
	-- Backstop reaper: channels live until torn down or the participant leaves. Drop
	-- channels the leaver opened or was targeted by (firing onClose so contexts are
	-- freed), plus any in-flight reassembly/routing from them.
	hook.Add("PlayerDisconnected", "Noir.Network.Cleanup", function(ply)
		if not IsValid(ply) then return end
		for id, ch in pairs(Network.Channels) do
			if sameEndpoint(ch.opener, ply) or ch.target == ply then Network.dropChannel(id) end
		end

		local sid = ply:SteamID()
		for key in pairs(Network.Assembly) do
			if string.sub(key, 1, #sid) == sid then Network.Assembly[key] = nil end
		end

		for key in pairs(Network.Routing) do
			if string.sub(key, 1, #sid) == sid then Network.Routing[key] = nil end
		end
	end)
end
