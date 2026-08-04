local GCompute_ = Noir.GCompute or {}
Noir.GCompute = GCompute_

-- GCompute fallback (client-only sender).
--
-- When a Noir CLIENT connects to a server that does NOT run Noir but DOES run
-- GCompute, Noir.SendCode routes here instead of erroring (preferred over the
-- luadev fallback -- see Noir.RemoteFallback in execution.lua). We drive
-- GCompute's public execution API (GCompute.Execution.ExecutionService) which
-- does the compression, framing and server-side auth itself.
--
-- Unlike luadev, GCompute exposes real output streams, so we send the run's
-- actual stdout/stderr/compiler output back to the runner instead of a synthetic
-- "no output" note. GCompute's streams are colored (GLib.Colors), so we forward
-- them as colored segment messages and reuse the console's existing colored render.
--
-- Output shape is chosen from the FIRST chunk of the run:
--  * code mode (first line is a "--" comment): GCompute is printing a Lua
--    result/code block -- its "-- 0x..." header, a decompiled function, a table
--    dump. We buffer the whole block (TEXT ONLY -- GCompute's stream coloring is
--    dropped) and emit it once as a "code" message, which the console renders with
--    no realm prefix, so it reads as clean code with Noir's own Lua tokenizer
--    highlighting rather than GCompute's colors.
--  * console mode (anything else, e.g. print output): we stream LIVE, coalesced
--    per line -- a line's color runs accumulate until its "\n", then go out as one
--    prefixed MsgC message. Live matters because such output can span several
--    execution slices.
--
-- Completion: GCompute does NOT deliver a Terminated StateChanged to the initiating
-- client for an immediate remote run (verified against a live server: stdout events
-- fire, StateChanged never does). So completion is status-only: the output has
-- already been streamed/buffered, so we just mark the run green/red. We settle a
-- short quiet period after the last write (a bounded fallback covers a run that
-- writes nothing), emit the buffered code block (or flush the trailing console
-- line), send the terminal "run" reply, and dispose the reusable context.
--
-- Note: unlike Noir, GCompute only detours _G.print/Msg WHILE the top-level code runs
-- and restores them when it returns (gluaexecutioninstance Start), so late output from
-- timers/hooks/net callbacks is NOT streamed back -- it goes to the remote console.
-- Hence there's nothing to keep the channel open for after the run settles.
--
-- Delivery: output/results are synthesised locally, so their natural sender would be
-- LocalPlayer() and the console would mislabel a server run as CLIENT. We dispatch
-- them via Network.DispatchChannel with a sender chosen from the target (senderFor)
-- so the realm prefix reads SERVER / a player's nick correctly.
--
-- Caveats:
--  * SWEP/SENT auto-mode (opts.entType) is NOT wrapped through GCompute -- Noir's
--    StartWeapon/StartEntity wrappers run target-side and aren't present on a
--    non-Noir server, so the raw body just runs.
--  * Aggregate targets ("clients"/"shared") come back as one combined stream, but
--    GCompute still attributes each host: its AggregateExecutionInstance injects an
--    orange "[steamid (name)] " header into the stream whenever the writing host
--    changes, so per-client output stays distinguishable (we forward it with color).
--    This is GCompute's inline attribution, not Noir's own per-message realm prefix.

-- Usable only when BOTH hold: this client has GCompute loaded, and the server
-- answered GCompute's remote-service handshake (IsAvailable == the service
-- channel is open). This is *real* GCompute only -- GCompute internally bridges
-- to luadev, but we detect strictly so Noir's own luadev_compat owns that step.
function GCompute_.IsAvailable()
	return CLIENT
		and istable(GCompute)
		and istable(GCompute.Execution)
		and GCompute.Execution.GComputeRemoteExecutionService
		and GCompute.Execution.GComputeRemoteExecutionService:IsAvailable()
end

-- Map a Noir run target to a GCompute hostId. "self" never reaches the fallback
-- (Noir.SendCode handles it before the net-string check).
local function hostIdFor(target)
	if target == "server" then return "Server" end
	if target == "clients" then return "Clients" end
	if target == "shared" then return "Shared" end
	if isentity(target) and IsValid(target) and target:IsPlayer() then
		return GLib.GetPlayerId(target)
	end
	return nil
end

-- The realm to attribute this run's synthesised output to (see the Delivery note).
-- Aggregate targets have no single origin entity, so tag "clients" as CLIENT and
-- "shared" as SERVER; GCompute's inline per-host headers disambiguate within the block.
local function senderFor(target)
	if isentity(target) and IsValid(target) and target:IsPlayer() then return target end
	if target == "clients" then return LocalPlayer() end
	return Entity(0) -- "server" and "shared"
end

-- Dispatch a run message (output / result) to this channel's handlers with a chosen
-- sender. Local-only (the fallback always delivers to the initiator itself), so this
-- mirrors Environment.SendMessage's local path but lets us pick the sender and skips
-- the network. DispatchChannel is a no-op if the channel is already gone.
local function deliver(channelId, sender, message, messageData)
	local body = Noir.Format.FormatMessage(message, messageData, messageData.opts)
	Noir.Network.DispatchChannel(channelId, sender, message, {string = body})
end

-- Dispatch a run through GCompute. Signature mirrors Noir.SendCode so the fallback
-- branch there is a drop-in. Returns the run channel id.
function GCompute_.SendCode(code, target, identifier, channelId, opts)
	channelId = channelId or Noir.Network.OpenChannel("runCode", target)
	Noir.Network.EnsureRecord(channelId, {
		type = "runCode",
		target = target,
		opener = LocalPlayer(),
	})

	local runSender = senderFor(target)

	-- "run" is terminal (it closes the channel in console/eval contexts) and is sent
	-- once completion settles; guard to a single reply.
	local finished = false
	local function finish(done, payload)
		if finished then return end
		finished = true
		deliver(channelId, runSender, "run", {
			done,
			payload,
			opts = done and {preformatted = true} or {}
		})
	end

	local hostId = hostIdFor(target)
	if not hostId then
		Noir.Error("GCompute fallback: unsupported target ", tostring(target), "\n")
		finish(false, "-- GCompute fallback: unsupported target: " .. tostring(target))
		return channelId
	end

	local ES = GCompute.Execution.ExecutionService
	local ECO = GCompute.Execution.ExecutionContextOptions
	local EIO = GCompute.Execution.ExecutionInstanceOptions
	local State = GCompute.Execution.ExecutionInstanceState

	local function rcName(rc) return GCompute.ReturnCode[rc] or tostring(rc) end

	ES:CreateExecutionContext(GLib.GetLocalId(), hostId, "GLua",
		ECO.EasyContext + ECO.Repl,
		function(context, rc)
			if not context then
				finish(false, "-- GCompute context error: " .. rcName(rc))
				return
			end

			context:CreateExecutionInstance(code, nil,
				EIO.CaptureOutput + EIO.ExecuteImmediately,
				function(instance, rc2)
					-- Reusable context; dispose it once the run settles (or fails).
					if not instance then
						finish(false, "-- GCompute instance error: " .. rcName(rc2))
						context:Dispose()
						return
					end

					local flushTimer = "NoirGComputeFlush_" .. channelId
					local waitTimer = "NoirGComputeWait_" .. channelId

					-- Output buffers. GCompute's Text event carries (text, color); we
					-- accumulate segments as an arg list (alternating Color / string). The
					-- shape (code vs console) is decided from the first chunk -- see header.
					local hadError = false
					local codeMode -- nil until the first chunk decides it
					local codeSegs = {} -- whole-block buffer (code mode)
					local lineSegs, lineHasText = {}, false -- current line (console mode)
					local complete -- forward declaration (onOutput arms a timer that calls it)
					local function flushLine()
						if lineHasText then
							deliver(channelId, runSender, "MsgC", {args = lineSegs, n = #lineSegs})
						end
						lineSegs, lineHasText = {}, false
					end

					local function onOutput(text, color, isErr)
						if isErr then hadError = true end
						text = text or ""
						if codeMode == nil then codeMode = string.sub(text, 1, 2) == "--" end
						if codeMode then
							-- Buffer TEXT ONLY (verbatim, embedded newlines and all): drop
							-- GCompute's own stream coloring so Noir's Lua tokenizer highlights
							-- the block itself. Emitted as one "code" message at complete.
							if text ~= "" then codeSegs[#codeSegs + 1] = text end
						else
							-- Stream per line, coalescing a line's color runs; hold the
							-- trailing partial line for more output.
							local col = istable(color) and Color(color.r or 255, color.g or 255, color.b or 255) or nil
							local parts = string.Explode("\n", text)
							for i, part in ipairs(parts) do
								if part ~= "" then
									if col then lineSegs[#lineSegs + 1] = col end
									lineSegs[#lineSegs + 1] = part
									lineHasText = true
								end
								if i < #parts then flushLine() end
							end
						end
						-- Re-arm completion: settle a quiet period after the last write.
						timer.Remove(waitTimer)
						timer.Create(flushTimer, 0.25, 1, complete)
					end

					-- Settle the run: emit the buffered code block (or flush the trailing
					-- console line), mark status, dispose. Status-only -- output already
					-- streamed/buffered above -- so it can't strand output even though
					-- GCompute never tells the client the run terminated.
					complete = function()
						if finished then return end
						timer.Remove(flushTimer)
						timer.Remove(waitTimer)
						if codeMode then
							if #codeSegs > 0 then
								deliver(channelId, runSender, "code", {args = codeSegs, n = #codeSegs})
							end
						else
							flushLine()
						end
						finish(not hadError, hadError and "" or {""})
						context:Dispose()
					end

					-- Attaching after ExecuteImmediately is safe: pipes buffer until the
					-- first listener attaches, then flush (see the Pipe buffering note).
					instance:GetStdOut():AddEventListener("Text", function(_, text, color) onOutput(text, color, false) end)
					instance:GetStdErr():AddEventListener("Text", function(_, text, color) onOutput(text, color, true) end)
					instance:GetCompilerStdErr():AddEventListener("Text", function(_, text, color) onOutput(text, color, true) end)

					-- Terminated does NOT arrive for an immediate remote run (see header).
					-- Keep the listener anyway: if it ever fires (local hosts, immediate
					-- compile rejects) settle at once instead of waiting out the timer.
					instance:AddEventListener("StateChanged", function(_, state)
						if state == State.Terminated then complete() end
					end)

					-- A run with no output writes nothing and (for remote) never terminates
					-- client-side, so nothing above fires. Bound the wait so it still settles.
					timer.Create(waitTimer, 1.5, 1, complete)
				end)
		end)

	return channelId
end
