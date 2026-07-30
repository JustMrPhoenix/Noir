Noir.JSRuntime = [[window.__noir = window.__noir || {};
window.__noir.fmt = function(a){ try { return (a !== null && typeof a === "object") ? JSON.stringify(a) : String(a); } catch(e){ return String(a); } };
window.__noir.eval = function(id, code, captureLog){
	var orig;
	if (captureLog) {
		orig = { log: console.log, warn: console.warn, debug: console.debug, error: console.error };
		var send = function(kind){ return function(){ noirjs.OnResult(id, kind, Array.prototype.map.call(arguments, window.__noir.fmt).join(" ")); }; };
		console.log = send("log"); console.warn = send("warn"); console.debug = send("debug"); console.error = send("error");
	}
	try {
		noirjs.OnResult(id, "return", window.__noir.fmt((0, eval)(code)));
	} catch(err) {
		noirjs.OnResult(id, "ERROR", (err && err.stack) ? String(err.stack) : String(err));
	} finally {
		if (orig) { console.log = orig.log; console.warn = orig.warn; console.debug = orig.debug; console.error = orig.error; }
	}
};
window.__noir.run = function(code){
	var ours = { log: console.log, warn: console.warn, debug: console.debug, error: console.error };
	var orig = window.__noirOrigConsole || ours;
	try {
		console.log = orig.log; console.warn = orig.warn; console.debug = orig.debug; console.error = orig.error;
		(0, eval)(code);
	} catch(err) {
		orig.error((err && err.stack) ? String(err.stack) : String(err));
	} finally {
		console.log = ours.log; console.warn = ours.warn; console.debug = ours.debug; console.error = ours.error;
	}
};]]

-- Emit a call to the REPL eval harness. RunJavascript this directly (not via PANEL:RunJS)
-- since user JS routinely contains % -- the code is passed as a Format argument, not part
-- of the template, so its % survive.
function Noir.BuildJSEval(identifier, code, captureLog)
	return Format([[window.__noir.eval("%s", "%s", %s);]],
		identifier:JavascriptSafe(), code:JavascriptSafe(), captureLog and "true" or "false")
end

-- Emit a call to the editor-run harness.
function Noir.BuildJSEditorRun(code)
	return Format([[window.__noir.run("%s");]], code:JavascriptSafe())
end

function Noir.RunCode(code, identifier, environment, quiet)
	identifier = identifier or "Noir.RunCode"
	local compileResults = CompileString(code, identifier, false)
	if not isfunction(compileResults) then
		if not quiet then Noir.Error("[", identifier, "] Error compiling code: " .. compileResults, "\n") end
		return false, compileResults
	end

	if environment then debug.setfenv(compileResults, environment) end
	local call_results = {pcall(compileResults)}
	Noir.Debug("RunCode", identifier, call_results)
	if not table.remove(call_results, 1) then
		local msg = call_results[1]
		if not quiet then Noir.Error("[", identifier, "] Error pcalling code: " .. tostring(msg), "\n") end
		return false, msg
	end
	return true, call_results
end

function Noir.EvalCode(code, identifier, runner)
	identifier = identifier or "Noir.EvalCode"
	-- Prefer expression form so `Entity(5)` returns a value; fall back to a block.
	if isfunction(CompileString("return " .. code, identifier, false)) then
		code = "return " .. code
	end

	runner = runner or (SERVER and Entity(0) or LocalPlayer())
	local vars = Noir.Environment.MakeVars()
	Noir.Search.PopulateVars(vars, runner)
	return Noir.RunCode(code, identifier, Noir.Environment.MakeEnvTable(vars, true), true)
end

-- Log a code relay/run as "<verb> code(id): identifier [from => to]".
local function logRun(verb, sender, channelId, data)
	Noir.Msg(verb .. " code(", Color(0, 120, 205), channelId, Color(255, 255, 255), "): ", -- ):
		Color(230, 220, 115), data.identifier,
		Color(255, 255, 255), " [",
		Color(0, 150, 0), sender == Entity(0) and "(SERVER)" or sender:Nick() .. "(" .. sender:SteamID() .. ")",
		Color(255, 255, 255), " => ",
		Color(0, 150, 0), isentity(data.target) and data.target:Nick() .. "(" .. data.target:SteamID() .. ")" or data.target:upper(),
		Color(255, 255, 255), "]\n")
end

-- In-flight async --find jobs, keyed by run channel id, so a channel close (teardown
-- or disconnect) can cancel the walk mid-search. See Format.DeepFindAsync.
local FindJobs = {}

-- Run `code` in a fresh context for `runner` and reply with the formatted result
-- on `channelId` (`data` carries the output-format opts). Shared by the local
-- "self" path and the channel receive handler.
local function runAndReply(runner, channelId, code, identifier, vars, data)
	local context = Noir.Environment.CreateContext(runner, channelId, vars)

	-- SWEP/SENT auto-mode: the client flags the run's ent type (data.entType), so we
	-- wrap the body in the easylua-style Start/End and the user only writes the
	-- SWEP/ENT body. Registration runs in whichever realm executes the code, so a
	-- "shared" run registers on both client and server.
	local entType = data.entType
	if entType == "SWEP" then
		Noir.StartWeapon(data.entClass, context.Upvalues)
	elseif entType == "SENT" then
		Noir.StartEntity(data.entClass, context.Upvalues)
	end

	local done, returns = Noir.RunCode(code, identifier, context.EnvTable)

	if entType == "SWEP" or entType == "SENT" then
		-- Only auto-finish if the build is still open -- a body that called endswep/
		-- endsent itself already cleared it, so we don't double-register.
		local building = entType == "SWEP" and context.Upvalues.SWEP or context.Upvalues.ENT
		if done and istable(building) then
			local finish = entType == "SWEP" and Noir.EndWeapon or Noir.EndEntity
			local ok, err = pcall(finish, context.Upvalues, {spawn = data.spawn, reinit = true})
			if not ok then done, returns = false, err end
		else
			-- Broken run, or a stray half-built build: drop it so it can't leak.
			Noir.ClearEntityBuild(context.Upvalues)
		end
	end

	context.RunResults = {done, returns}

	-- --find* deep search: walk the returned value asynchronously (off Noir.TableSearch's
	-- time-budgeted driver) so a large tree like _G doesn't freeze this realm. The result
	-- comes back on the same channel once complete, pre-formatted so the console shows it
	-- verbatim (opts.preformatted short-circuits FormatLong).
	if done and data.find then
		local job = Noir.Format.DeepFindAsync(returns[1], data, function(text)
			FindJobs[channelId] = nil
			Noir.Environment.SendMessage(runner, channelId, "run", {true, {text}, opts = {preformatted = true}})
		end)

		-- A job means the walk is running in the background (a non-table root replies
		-- instantly, so no indicator is needed there). Emit an immediate "searching"
		-- status as plain output -- it shows the search is ongoing without consuming the
		-- run's answer, so the real result still lands as the answer when it completes.
		if job then
			FindJobs[channelId] = job
			Noir.Environment.SendMessage(runner, channelId, "searching", {
				Format("-- searching for %q ...", data.find),
				opts = {preformatted = true}
			})
		end

		return
	end

	if not done and not isstring(returns) then returns = Noir.Format.FormatLong(returns, 0, data) end
	Noir.Environment.SendMessage(runner, channelId, "run", {
		done,
		returns,
		opts = data
	})

	if not done then
		ErrorNoHalt(Format("[%s] %s", identifier, returns))
		print()
	end
end

-- Deep-find flag table (see parseOutputFlags). The base --find is a case-insensitive
-- Lua-pattern search over keys+values (the intuitive default); --findre is an explicit
-- alias and --findfre does the same over function bodies (string constants, upvalue
-- names/values, parameter names). The literal (plain-substring) variants are
-- --findi/--find[k|v|f] and their "i" (case-insensitive) forms. More specific flags
-- first so prefixes (e.g. --find) don't shadow them.
local FIND_SPECS = {
	{flag = "findfre", keys = false, values = false, funcs = true, insensitive = true, pattern = true},
	{flag = "findre", keys = true, values = true, funcs = false, insensitive = true, pattern = true},
	{flag = "findki", keys = true, values = false, funcs = false, insensitive = true},
	{flag = "findvi", keys = false, values = true, funcs = false, insensitive = true},
	{flag = "findfi", keys = false, values = false, funcs = true, insensitive = true},
	{flag = "findk", keys = true, values = false, funcs = false, insensitive = false},
	{flag = "findv", keys = false, values = true, funcs = false, insensitive = false},
	{flag = "findf", keys = false, values = false, funcs = true, insensitive = false},
	{flag = "findi", keys = true, values = true, funcs = false, insensitive = true},
	-- Default find is pattern + case-insensitive; use the literal variants for plain substrings.
	{flag = "find", keys = true, values = true, funcs = false, insensitive = true, pattern = true},
}

-- Parse the REPL output-format directives (--full/--shallow/--keys/--values/--depth)
-- and the deep-find flags out of the code string, writing them onto the run `data`
-- table. Kept separate from SendCode's channel dispatch so the directive grammar
-- lives in one place. The find term is the next whitespace-delimited token, matched
-- against the case-preserved code.
local function parseOutputFlags(code, data)
	local lowerCode = string.lower(code)
	if string.find(lowerCode, "%-%-full") then data.full = true end
	if string.find(lowerCode, "%-%-shallow") then data.shallow = true end
	if string.find(lowerCode, "%-%-keys") then data.keys = true end
	if string.find(lowerCode, "%-%-values") then data.values = true end
	local depthMatch = string.match(lowerCode, "%-%-depth%s+(%d+)")
	if depthMatch then data.depth = tonumber(depthMatch) end

	for _, spec in ipairs(FIND_SPECS) do
		local term = string.match(code, "%-%-" .. spec.flag .. "%s+(%S+)")
		if term then
			data.find = term
			data.findKeys = spec.keys
			data.findValues = spec.values
			data.findFuncs = spec.funcs
			data.findInsensitive = spec.insensitive
			data.findPattern = spec.pattern
			break
		end
	end
end

function Noir.SendCode(code, target, identifier, channelId, opts)
	if util.NetworkStringToID(Noir.Network.Tag) == 0 and target ~= "self" then
		Noir.ErrorT("This server does not seem to run Noir")
	end

	-- Ensure a run channel exists for this id (callers normally OpenChannel first to
	-- register handlers; this covers direct/self callers). Output flows back on it.
	channelId = channelId or Noir.Network.OpenChannel("runCode", target)
	local ch = Noir.Network.EnsureRecord(channelId, {
		type = "runCode",
		target = target,
		opener = SERVER and Entity(0) or LocalPlayer(),
	})

	-- Friendly label for `noir_unsubscribe` listing/auto-suggestion.
	ch.label = identifier

	local data = {
		target = target,
		identifier = identifier,
		vars = Noir.Environment.MakeVars()
	}

	data.sortMode = Noir.Format.GetOutputSettings().sortMode

	-- SWEP/SENT auto-mode: an explicit flag set by the caller (the editor knows a tab's
	-- type). Rides to the target realm, where runAndReply wraps the body in Start/End.
	if istable(opts) and (opts.entType == "SWEP" or opts.entType == "SENT") then
		data.entType = opts.entType
		data.entClass = opts.entClass
		data.spawn = opts.spawn and true or false
	end

	-- Parse the --full/--shallow/--keys/--values/--depth and deep-find directives.
	parseOutputFlags(code, data)

	-- Ship the client's async-search perf settings with the run so the target realm
	-- (which runs the walk) uses them; falls back to Format.DeepFindAsync defaults otherwise.
	if data.find then
		local searchSettings = Noir.Format.GetSearchSettings()
		data.findBudgetMs = searchSettings.frameBudgetMs
		data.findMaxResults = searchSettings.maxResults
		data.findMaxDepth = searchSettings.maxDepth
	end

	-- Track the find so the HUD can surface a long-running one (the walk may run on
	-- the server, so there's no local job to poll).
	if data.find and CLIENT and Noir.SearchHUD then
		Noir.SearchHUD.TrackFind(channelId, identifier)
	end

	if target == "self" then
		local me = SERVER and Entity(0) or LocalPlayer()
		runAndReply(me, channelId, code, identifier, Noir.Environment.MakeVars(), data)
		return channelId
	end

	-- Send the code as the opening message of the run channel. The channel then
	-- carries the run's output back on the same id, for as long as the run keeps
	-- replying (hooks/timers), until teardown or disconnect.
	Noir.Debug("SendCode", data, code)
	Noir.Network.OpenSend(channelId, code, data)
	return channelId
end

----------------------------------------------------------------------
-- Public run API. Run an arbitrary code string on a target and stream results
-- back through `onResult`. This wraps the OpenChannel + RegisterHandler + SendCode
-- boilerplate so callers don't have to touch the network layer directly.
--
-- `target` is one of "self", "server", "shared", "clients", or a specific Player.
-- Returns the run channel id (nil on failure). The channel stays open -- a run's
-- hooks/timers may keep replying long after the first result -- so tear it down
-- with Noir.Network.CloseChannel(id) once you're done listening.
--
-- onResult(result) is called for each reply, where result = {
--   sender    = the Player (or Entity(0) = the server) that produced this reply,
--   done      = false if the code errored, true otherwise,
--   returns   = the formatted result / error string,
--   channelId = the run channel id,
-- }
--
-- Running is superadmin-gated server-side (Network.CheckAccess), the same whether
-- called from a client or the server. For a synchronous LOCAL eval that returns
-- real Lua values (not formatted strings) use Noir.EvalCode instead.
----------------------------------------------------------------------
function Noir.Run(code, target, onResult, identifier, opts)
	identifier = identifier or "Noir.Run"
	local id = Noir.Network.OpenChannel("runCode", target)
	if not id then return end
	if onResult then
		Noir.Environment.RegisterHandler(function(sender, channelId, _, data)
			local done, returns, ok = Noir.Environment.DecodeRunResult(data)
			-- A run frame is always JSON; a decode failure is a corrupt/hostile frame,
			-- so surface it as an error result rather than delivering nil silently.
			if not ok then done, returns = false, "-- malformed run result" end
			onResult({
				sender = sender,
				done = done,
				returns = returns,
				channelId = channelId
			})
		end, id, "run")
	end

	Noir.SendCode(code, target, identifier, id, opts)
	return id
end

-- Named target wrappers over Noir.Run.
function Noir.RunOnSelf(code, onResult, identifier) return Noir.Run(code, "self", onResult, identifier) end
function Noir.RunOnServer(code, onResult, identifier) return Noir.Run(code, "server", onResult, identifier) end
function Noir.RunShared(code, onResult, identifier) return Noir.Run(code, "shared", onResult, identifier) end
function Noir.RunOnClients(code, onResult, identifier) return Noir.Run(code, "clients", onResult, identifier) end
-- `ply` is the specific client (a Player) to run on.
function Noir.RunOnClient(code, ply, onResult, identifier) return Noir.Run(code, ply, onResult, identifier) end

Noir.Network.ChannelHandlers["runCode"] = {
	-- Server-side hook when a runCode open is received/relayed: inject server-only
	-- vars into the (about-to-be-forwarded) data and log the relay.
	serverOpen = function(sender, channelId, data)
		Noir.Environment.UpdateVarsSV(data)
		if data.target == "server" then return end
		logRun("Sending", sender, channelId, data)
	end,
	-- Any endpoint (target client, or the server for shared/server runs) runs the
	-- code and replies on the SAME channel. `sender` is the run's initiator (opener),
	-- so output flows back to whoever started the run.
	open = function(sender, channelId, data)
		logRun("Running", sender, channelId, data)
		runAndReply(sender, channelId, data.string, data.identifier, data.vars, data)
	end,
	-- Teardown: cancel any in-flight --find walk and free the run context this
	-- endpoint created (keyed by initiator).
	close = function(channelId, ch)
		if FindJobs[channelId] then
			Noir.TableSearch.CancelJob(FindJobs[channelId])
			FindJobs[channelId] = nil
		end

		local contexts = Noir.Environment.Contexts[ch.opener]
		if contexts then contexts[channelId] = nil end
	end
}
