local LuaDev = Noir.LuaDev or {}
Noir.LuaDev = LuaDev

-- luadev fallback (client-only sender).
--
-- When a Noir CLIENT connects to a server that does NOT run Noir but DOES run
-- luadev, Noir.SendCode routes here instead of erroring. We don't reimplement
-- luadev's wire protocol -- if the client also has the luadev library loaded we
-- just call its public client API (luadev.RunOnServer / RunOnClients / RunOnShared
-- / RunOnClient), which does the compression, framing and server-side auth itself.
--
-- Caveat: luadev has no return channel -- it never sends run output or return
-- values back to the sender. So after dispatching we deliver a single synthetic
-- reply on the run channel so the editor/REPL shows completion (with a note) rather
-- than hanging forever waiting for replies that never arrive.

LuaDev.Tag = "luadev1"

-- The fallback is usable only when BOTH hold: the server registered luadev's net
-- string (so it runs luadev -- calling luadev.Run* against a server without it
-- would error in net.Start), and this client has the luadev library loaded.
function LuaDev.IsAvailable()
	return CLIENT
		and util.NetworkStringToID(LuaDev.Tag) ~= 0
		and istable(luadev)
		and isfunction(luadev.RunOnServer)
end

-- The realm to attribute a run's synthesised output to, so the console's realm
-- prefix reads SERVER / a player's nick rather than CLIENT (the reply is delivered
-- locally, so its natural sender would be us). "clients" has no single origin.
local function senderFor(target)
	if isentity(target) and IsValid(target) and target:IsPlayer() then return target end
	if target == "clients" then return LocalPlayer() end
	return Entity(0) -- "server" and "shared"
end

-- Deliver a synthetic run result to the channel's handlers without networking.
-- Local-only, so we dispatch straight to the channel handlers with a sender chosen
-- from the target (see senderFor); DispatchChannel is a no-op if the channel is gone.
local function synthReply(channelId, target, done, note)
	local body = Noir.Format.FormatMessage("run", {done, note, opts = {}}, nil)
	Noir.Network.DispatchChannel(channelId, senderFor(target), "run", {string = body})
end

-- Dispatch a run through luadev. Signature mirrors Noir.SendCode so the fallback
-- branch there is a drop-in. Returns the run channel id.
function LuaDev.SendCode(code, target, identifier, channelId, opts)
	channelId = channelId or Noir.Network.OpenChannel("runCode", target)
	Noir.Network.EnsureRecord(channelId, {
		type = "runCode",
		target = target,
		opener = LocalPlayer(),
	})

	-- SWEP/SENT parity: luadev auto-registers from extra.swep / extra.sent.
	local extra
	if istable(opts) and opts.entType and opts.entClass then
		if opts.entType == "SWEP" then
			extra = {swep = opts.entClass}
		elseif opts.entType == "SENT" then
			extra = {sent = opts.entClass}
		end
	end

	local ok, err
	if target == "server" then
		ok, err = luadev.RunOnServer(code, identifier, extra)
	elseif target == "clients" then
		ok, err = luadev.RunOnClients(code, identifier, extra)
	elseif target == "shared" then
		ok, err = luadev.RunOnShared(code, identifier, extra)
	elseif isentity(target) and IsValid(target) and target:IsPlayer() then
		ok, err = luadev.RunOnClient(code, target, identifier, extra)
	else
		ok, err = nil, "unsupported luadev target: " .. tostring(target)
	end

	-- luadev returns true, or (nil, err) -- e.g. code too big for its net cap.
	if ok == nil then
		Noir.Error("luadev fallback failed: ", tostring(err), "\n")
		synthReply(channelId, target, false, "-- luadev fallback failed: " .. tostring(err))
		return channelId
	end

	synthReply(channelId, target, true,
		"sent via luadev fallback -- this server has no Noir, so run output and return values are not sent back")
	return channelId
end
