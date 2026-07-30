local WHITE = Color(255, 255, 255)
NDL.injections = NDL.injections or {}
NDL.originalFuncs = NDL.originalFuncs or {}
NDL.traces = NDL.traces or {}
-- Cap on retained trace records per traced function. Tracers keep every call's
-- args/returns/traceback; without a bound this grows forever on a hot function
-- (and pins any captured entities/tables). Oldest records are dropped past this.
NDL.MaxTraceRecords = NDL.MaxTraceRecords or 1000

-- Append a trace record for a traced function, dropping the oldest once the
-- per-function cap is exceeded so the history stays bounded.
local function pushTrace(originalFunc, TraceData)
	local records = NDL.traces[originalFunc]
	records[#records + 1] = TraceData
	if #records > NDL.MaxTraceRecords then table.remove(records, 1) end
end

-- FilterFuncs should return true, the table of arguments to pass to the original function
function NDL.MakeArgsFilter(originalFunc, filterFunc)
	return function(...)
		local succ, res = NDL.PCall(filterFunc, ...)
		if succ then
			local toFilter = table.remove(res, 1)
			if toFilter == true then
				return originalFunc(unpack(res))
			else
				return originalFunc(...)
			end
		else
			NDL.Error("Error executing args filter func: ", Color(200, 0, 0), res, "\n")
			return originalFunc(...)
		end
	end
end

-- This one makes a call tracer with all kinds of metrics and calls additionalCallback with data after call.
-- Passing a number as the last argument (in place of, or after, additionalCallback) limits how many
-- calls are traced; once the limit is reached the original function is called directly without tracing.
function NDL.MakeCallTracer(originalFunc, name, additionalCallback, limit)
	if isnumber(additionalCallback) then
		limit = additionalCallback
		additionalCallback = nil
	end

	name = name or tostring(originalFunc)
	NDL.traces[originalFunc] = NDL.traces[originalFunc] or {}
	local count = 0
	return function(...)
		if limit and count >= limit then return originalFunc(...) end
		count = count + 1
		NDL.Msg("Traced function called ", Color(0, 150, 0), name, "\n")
		NDL.Msg("ArgList: ")
		local args = {...}
		for k, v in pairs(args) do
			MsgC("\t", Color(0, 200, 0), k, WHITE, ": ", Color(0, 150, 0), Noir.Format.FormatShort(v))
		end

		MsgC(WHITE, "\t(Total:", Color(0, 200, 0), #args, WHITE, ")\n")
		local trace = NDL.PrintTrace(4)
		local startCall = SysTime()
		local returns = {originalFunc(...)}
		local finishCall = SysTime()
		NDL.Msg("Took ", Color(0, 200, 0), math.Round((SysTime() - startCall) * 1000, 4), WHITE, "ms to run\n")
		NDL.Msg("Returns: ")
		for k, v in pairs(returns) do
			MsgC("\t", Color(0, 200, 0), k, WHITE, ": ", Color(0, 150, 0), Noir.Format.FormatShort(v))
		end

		MsgC(WHITE, "\t(Total:", Color(0, 200, 0), #returns, WHITE, ")\n")
		local TraceData = {
			args = args,
			returns = returns,
			startCall = startCall,
			finishCall = finishCall,
			trace = trace
		}

		pushTrace(originalFunc, TraceData)
		if additionalCallback and isfunction(additionalCallback) then additionalCallback(TraceData) end
		return unpack(returns)
	end
end

-- Passing a number as the last argument (in place of, or after, additionalCallback) limits how many
-- errors are traced; once the limit is reached the original function is called directly.
function NDL.MakeErrorTracer(originalFunc, name, additionalCallback, limit)
	if isnumber(additionalCallback) then
		limit = additionalCallback
		additionalCallback = nil
	end

	name = name or tostring(originalFunc)
	NDL.traces[originalFunc] = NDL.traces[originalFunc] or {}
	local count = 0
	return function(...)
		if limit and count >= limit then return originalFunc(...) end
		local startCall = SysTime()
		local results = {pcall(originalFunc, ...)}
		local finishCall = SysTime()
		local success = table.remove(results, 1)
		if success then return unpack(results) end
		count = count + 1
		NDL.Msg("Traced function had an error ", Color(0, 150, 0), name, "\n")
		NDL.Msg("ArgList: ")
		local args = {...}
		for k, v in pairs(args) do
			MsgC("\t", Color(0, 200, 0), k, WHITE, ": ", Color(0, 150, 0), Noir.Format.FormatShort(v))
		end

		MsgC(WHITE, "\t(Total:", Color(0, 200, 0), #args, WHITE, ")\n")
		local trace = NDL.PrintTrace(4)
		NDL.Msg("Took ", Color(0, 200, 0), math.Round((SysTime() - startCall) * 1000, 4), WHITE, "ms to run\n")
		NDL.Msg("Error: ", Color(200, 0, 0), results[1])
		local TraceData = {
			args = args,
			returns = results,
			startCall = startCall,
			finishCall = finishCall,
			trace = trace
		}

		pushTrace(originalFunc, TraceData)
		if additionalCallback and isfunction(additionalCallback) then additionalCallback(TraceData) end
		error(results[1])
	end
end

-- Basically replace the original with new func and store the original for future referance.
-- Injects stack: injecting over an existing inject pushes onto a per-(table, func) stack so overlapping
-- injects can be unwound one layer at a time. NDL.originalFuncs[toInject] remembers whatever was in place
-- (an original or a previous inject) so restoring returns exactly the layer below.
function NDL.Inject(targetTbl, funcName, toInject)
	local original = rawget(targetTbl, funcName)
	if not original then return NDL.Error("Attempt to inject non-existent function") end
	NDL.injections[targetTbl] = NDL.injections[targetTbl] or {}
	local stack = NDL.injections[targetTbl][funcName] or {}
	NDL.injections[targetTbl][funcName] = stack
	stack[#stack + 1] = toInject
	NDL.originalFuncs[toInject] = original
	rawset(targetTbl, funcName, toInject)
end

-- Pops the top inject layer, restoring the table entry to whatever was underneath it.
-- Trace history is retained by design: restoring an inject leaves NDL.traces alone so
-- captured calls survive teardown for later inspection. Call NDL.WipeTraces to free it.
function NDL.RestoreInject(targetTbl, funcName)
	local tblInjects = NDL.injections[targetTbl]
	if not tblInjects then return end
	local stack = tblInjects[funcName]
	if not stack or #stack == 0 then return end
	local top = table.remove(stack)
	rawset(targetTbl, funcName, NDL.originalFuncs[top])
	NDL.originalFuncs[top] = nil
	if #stack == 0 then tblInjects[funcName] = nil end
end

-- Trace history is retained by design here too; use NDL.WipeTraces to free it.
function NDL.RestoreAllInjects()
	for targetTbl, funcs in pairs(NDL.injections) do
		for funcName, stack in pairs(funcs) do
			-- Restore straight to the bottom-most original and drop every layer's bookkeeping.
			if stack[1] then rawset(targetTbl, funcName, NDL.originalFuncs[stack[1]]) end
			for _, injected in ipairs(stack) do
				NDL.originalFuncs[injected] = nil
			end
		end
	end

	NDL.injections = {}
end

-- Drop all retained trace history, freeing anything (entities/tables) it pinned.
-- Traces are kept across inject restores by default, so this is the explicit way to reclaim them.
function NDL.WipeTraces()
	NDL.traces = {}
end

-- C++-detour style: the detour receives the original (the trampoline) as its first argument and
-- returns whatever the caller should get. Pass through with `return original(...)`; replace by
-- returning your own values; suppress by returning nothing. An error in the detour propagates to
-- the caller, so a broken detour fails the call rather than silently falling back to the original.
function NDL.Detour(targetTbl, funcName, detourFunc)
	local original = rawget(targetTbl, funcName)
	NDL.Inject(targetTbl, funcName, function(...)
		return detourFunc(original, ...)
	end)
end

function NDL.FilterArgs(targetTbl, funcName, filterFunc)
	local original = rawget(targetTbl, funcName)
	NDL.Inject(targetTbl, funcName, NDL.MakeArgsFilter(original, filterFunc))
end

function NDL.TraceCalls(targetTbl, funcName, name)
	local original = rawget(targetTbl, funcName)
	NDL.Inject(targetTbl, funcName, NDL.MakeCallTracer(original, name or funcName))
end

function NDL.TraceOneCall(targetTbl, funcName, name)
	local original = rawget(targetTbl, funcName)
	NDL.Inject(targetTbl, funcName, NDL.MakeCallTracer(original, name or funcName, function()
		NDL.RestoreInject(targetTbl, funcName)
	end))
end

-- Concommand to restore all funcs in case of big bork. Superadmin-gated on the
-- server like every other state-mutating concommand (these mutate shared server
-- injection/trace state); client-side invocation only touches the local realm.
concommand.Add("ndl_restoreall", function(ply)
	if SERVER and IsValid(ply) and not ply:IsSuperAdmin() then return end
	NDL.RestoreAllInjects()
end)
-- Concommand to drop all retained trace history from memory.
concommand.Add("ndl_wipetraces", function(ply)
	if SERVER and IsValid(ply) and not ply:IsSuperAdmin() then return end
	NDL.WipeTraces()
end)
