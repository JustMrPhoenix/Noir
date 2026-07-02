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

function Noir.RunCode(code, identifier, environment)
	identifier = identifier or "Noir.RunCode"
	local compileResults = CompileString(code, identifier, false)
	if not isfunction(compileResults) then
		Noir.Error("[", identifier, "] Error compiling code: " .. compileResults, "\n")
		return false, compileResults
	end

	if environment then debug.setfenv(compileResults, environment) end
	local call_results = {pcall(compileResults)}
	Noir.Debug("RunCode", identifier, call_results)
	if not table.remove(call_results, 1) then
		local msg = call_results[1]
		Noir.Error("[", identifier, "] Error pcalling code: " .. tostring(msg), "\n")
		return false, msg
	end
	return true, call_results
end

function Noir.SendCode(code, identifier, target, transferId)
	if util.NetworkStringToID(Noir.Network.Tag) == 0 and target ~= "self" then
		Noir.ErrorT("This server does not seem to run Noir")
		return
	end

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
		local context = Noir.Environment.CreateContext(me, transferId, Noir.Environment.MakeVars())
		local done, returns = Noir.RunCode(code, identifier, context.EnvTable)
		context.RunResults = {done, returns}
		if not done and not isstring(returns) then returns = Noir.Format.FormatLong(returns, 0, data) end
		Noir.Environment.SendMessage(me, transferId, "run", {
			done,
			returns,
			opts = data
		})

		if not done then
			ErrorNoHalt(Format("[%s] %s", identifier, returns))
			print()
		end
		return transferId
	end

	Noir.Debug("SendCode", data, code, data.parts)
	Noir.Network.SendTransfer(transferId, data, "runCode", code, target)
	return transferId
end

Noir.Network.StringHandlers["runCode"] = {
	start = function(sender, transferId, data)
		if SERVER then
			Noir.Environment.UpdateVarsSV(data)
			if data.target == "server" then return end
			Noir.Msg("Sending code(", Color(0, 120, 205), transferId, Color(255, 255, 255), "): ", -- ):
				Color(230, 220, 115), data.identifier,
				Color(255, 255, 255), " [",
				Color(0, 150, 0), sender == Entity(0) and "(SERVER)" or sender:Nick() .. "(" .. sender:SteamID() .. ")",
				Color(255, 255, 255), " => ",
				Color(0, 150, 0), isentity(data.target) and data.target:Nick() .. "(" .. data.target:SteamID() .. ")" or data.target:upper(),
				Color(255, 255, 255), "]\n")
		end
	end,
	received = function(sender, transferId, data)
		Noir.Msg("Running code(", Color(0, 120, 205), transferId, Color(255, 255, 255), "): ", -- ):
			Color(230, 220, 115), data.identifier,
			Color(255, 255, 255), " [",
			Color(0, 150, 0), sender == Entity(0) and "(SERVER)" or sender:Nick() .. "(" .. sender:SteamID() .. ")",
			Color(255, 255, 255), " => ",
			Color(0, 150, 0), isentity(data.target) and data.target:Nick() .. "(" .. data.target:SteamID() .. ")" or data.target:upper(),
			Color(255, 255, 255), "]\n")

		local context = Noir.Environment.CreateContext(sender, transferId, data.vars)
		local done, returns = Noir.RunCode(data.string, data.identifier, context.EnvTable)
		context.RunResults = {done, returns}
		if not done and not isstring(returns) then returns = Noir.Format.FormatLong(returns, 0, data) end
		Noir.Environment.SendMessage(sender, transferId, "run", {
			done,
			returns,
			opts = data
		})

		if not done then
			ErrorNoHalt(Format("[%s] %s", data.identifier, returns))
			print()
		end
	end
}
