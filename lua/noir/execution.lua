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
local function logRun(verb, sender, transferId, data)
	Noir.Msg(verb .. " code(", Color(0, 120, 205), transferId, Color(255, 255, 255), "): ", -- ):
		Color(230, 220, 115), data.identifier,
		Color(255, 255, 255), " [",
		Color(0, 150, 0), sender == Entity(0) and "(SERVER)" or sender:Nick() .. "(" .. sender:SteamID() .. ")",
		Color(255, 255, 255), " => ",
		Color(0, 150, 0), isentity(data.target) and data.target:Nick() .. "(" .. data.target:SteamID() .. ")" or data.target:upper(),
		Color(255, 255, 255), "]\n")
end

-- Run `code` in a fresh context for `runner` and reply with the formatted result
-- on `transferId` (`data` carries the output-format opts). Shared by the local
-- "self" path and the channel receive handler.
local function runAndReply(runner, transferId, code, identifier, vars, data)
	local context = Noir.Environment.CreateContext(runner, transferId, vars)
	local done, returns = Noir.RunCode(code, identifier, context.EnvTable)
	context.RunResults = {done, returns}
	if not done and not isstring(returns) then returns = Noir.Format.FormatLong(returns, 0, data) end
	Noir.Environment.SendMessage(runner, transferId, "run", {
		done,
		returns,
		opts = data
	})

	if not done then
		ErrorNoHalt(Format("[%s] %s", identifier, returns))
		print()
	end
end

function Noir.SendCode(code, identifier, target, transferId)
	if util.NetworkStringToID(Noir.Network.Tag) == 0 and target ~= "self" then
		Noir.ErrorT("This server does not seem to run Noir")
		return
	end

	-- Ensure a run channel exists for this id (callers normally OpenChannel first to
	-- register handlers; this covers direct/self callers). Output flows back on it.
	transferId = transferId or Noir.Network.OpenChannel("runCode", target)
	local ch = Noir.Network.ensureRecord(transferId, {
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

	if CLIENT and Noir.Dashboard then
		data.sortMode = Noir.Dashboard.Get("Output", "tableSort")
	end

	-- Parse output format flags
	local lowerCode = string.lower(code)
	if string.find(lowerCode, "%-%-full") then data.full = true end
	if string.find(lowerCode, "%-%-shallow") then data.shallow = true end
	if string.find(lowerCode, "%-%-keys") then data.keys = true end
	if string.find(lowerCode, "%-%-values") then data.values = true end
	local depthMatch = string.match(lowerCode, "%-%-depth%s+(%d+)")
	if depthMatch then data.depth = tonumber(depthMatch) end
	-- Parse deep-find flags: --find/--findi (keys+values), --findk/--findki (keys only),
	-- --findv/--findvi (values only), --findf/--findfi (function bodies: string constants,
	-- upvalue names/values and parameter names). The "i" suffix makes the search
	-- case-insensitive. The search term is the next whitespace-delimited token (matched
	-- against the original case-preserved code so case-sensitive searches work). More
	-- specific flags first so prefixes (e.g. --find) don't shadow them.
	local findSpecs = {
		{
			flag = "findki",
			keys = true,
			values = false,
			funcs = false,
			insensitive = true
		},
		{
			flag = "findvi",
			keys = false,
			values = true,
			funcs = false,
			insensitive = true
		},
		{
			flag = "findfi",
			keys = false,
			values = false,
			funcs = true,
			insensitive = true
		},
		{
			flag = "findk",
			keys = true,
			values = false,
			funcs = false,
			insensitive = false
		},
		{
			flag = "findv",
			keys = false,
			values = true,
			funcs = false,
			insensitive = false
		},
		{
			flag = "findf",
			keys = false,
			values = false,
			funcs = true,
			insensitive = false
		},
		{
			flag = "findi",
			keys = true,
			values = true,
			funcs = false,
			insensitive = true
		},
		{
			flag = "find",
			keys = true,
			values = true,
			funcs = false,
			insensitive = false
		},
	}

	for _, spec in ipairs(findSpecs) do
		local term = string.match(code, "%-%-" .. spec.flag .. "%s+(%S+)")
		if term then
			data.find = term
			data.findKeys = spec.keys
			data.findValues = spec.values
			data.findFuncs = spec.funcs
			data.findInsensitive = spec.insensitive
			break
		end
	end

	if target == "self" then
		local me = SERVER and Entity(0) or LocalPlayer()
		runAndReply(me, transferId, code, identifier, Noir.Environment.MakeVars(), data)
		return transferId
	end

	-- Send the code as the opening message of the run channel. The channel then
	-- carries the run's output back on the same id, for as long as the run keeps
	-- replying (hooks/timers), until teardown or disconnect.
	Noir.Debug("SendCode", data, code)
	Noir.Network.OpenSend(transferId, code, data)
	return transferId
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
function Noir.Run(code, target, onResult, identifier)
	identifier = identifier or "Noir.Run"
	local id = Noir.Network.OpenChannel("runCode", target)
	if not id then return end
	if onResult then
		Noir.Environment.RegisterHandler(function(sender, channelId, _, data)
			local decoded = util.JSONToTable(data) or {}
			onResult({
				sender = sender,
				done = decoded[1],
				returns = decoded[2],
				channelId = channelId
			})
		end, id, "run")
	end

	Noir.SendCode(code, identifier, target, id)
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
	serverOpen = function(sender, transferId, data)
		Noir.Environment.UpdateVarsSV(data)
		if data.target == "server" then return end
		logRun("Sending", sender, transferId, data)
	end,
	-- Any endpoint (target client, or the server for shared/server runs) runs the
	-- code and replies on the SAME channel. `sender` is the run's initiator (opener),
	-- so output flows back to whoever started the run.
	open = function(sender, transferId, data)
		logRun("Running", sender, transferId, data)
		runAndReply(sender, transferId, data.string, data.identifier, data.vars, data)
	end,
	-- Teardown: free the run context this endpoint created (keyed by initiator).
	close = function(transferId, ch)
		local contexts = Noir.Environment.Contexts[ch.opener]
		if contexts then contexts[transferId] = nil end
	end
}
