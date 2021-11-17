local WHITE = Color(255,255,255)

NDL.injections = NDL.injections or {}
NDL.originalFuncs = NDL.originalFuncs or {}
NDL.traces = NDL.traces or {}

-- Detour funcs sohuld return true to prevent the original function from running
function NDL.MakeDetour(originalFunc, detourFunc)
    return function(...)
        local succ, res = NDL.PCall(detourFunc,...)
        if succ then
            local toDetour = table.remove(res, 1)
            if toDetour == true then
                return unpack(res)
            else
                return originalFunc(...)
            end
        else
            NDL.Error("Error executing detour func: ", Color(200,0,0), res,"\n")
            return originalFunc(...)
        end
    end
end


-- FilterFuncs should return true, the table of arguments to pass to the origianl function
function NDL.MakeArgsFilter(originalFunc, filterFunc)
    return function(...)
        local succ, res = NDL.PCall(filterFunc,...)
        if succ then
            local toFillter = table.remove(res, 1)
            if toFillter == true then
                return originalFunc(unpack(res))
            else
                return originalFunc(...)
            end
        else
            NDL.Error("Error executing args filter func: ", Color(200,0,0), res,"\n")
            return originalFunc(...)
        end
    end
end

-- This one makes a call tracer with all kinds of metrics and calls additionalCallback with data after call
function NDL.MakeCallTracer(originalFunc,name,additionalCallback)
    name = name or tostring(originalFunc)
    NDL.traces[originalFunc] = NDL.traces[originalFunc] or {}
    return function(...)
        NDL.Msg("Traced function called ", Color(0,150,0),name,"\n")
        NDL.Msg("ArgList: ")
        local args = {...}
        for k, v in pairs(args) do
            MsgC("\t",Color(0,200,0),k,WHITE,": ",Color(0,150,0),Noir.Format.FormatShort(v))
        end
        MsgC(WHITE,"\t(Total:",Color(0,200,0),#args,WHITE,")\n")
        local trace = NDL.PrintTrace(4)
        local startCall = SysTime()
        local returns = {originalFunc(...)}
        local finishCall = SysTime()
        NDL.Msg("Took ",Color(0,200,0),math.Round((SysTime() - startCall) * 1000,4),WHITE,"ms to run\n")
        NDL.Msg("Returns: ")
        for k, v in pairs(returns) do
            MsgC("\t",Color(0,200,0),k,WHITE,": ",Color(0,150,0),Noir.Format.FormatShort(v))
        end
        MsgC(WHITE,"\t(Total:",Color(0,200,0),#returns,WHITE,")\n")
        local TraceData = {
            args = args,
            returns = returns,
            startCall = startCall,
            finishCall = finishCall,
            trace = trace
        }
        table.insert(NDL.traces[originalFunc], TraceData)
        if additionalCallback and isfunction(additionalCallback) then
            additionalCallback(TraceData)
        end
        return unpack(returns)
    end
end

function NDL.MakeErrorTracer(originalFunc,name,additionalCallback)
    name = name or tostring(originalFunc)
    NDL.traces[originalFunc] = NDL.traces[originalFunc] or {}
    return function(...)
        local startCall = SysTime()
        local results = {pcall(originalFunc, ...)}
        local finishCall = SysTime()
        local success = table.remove(results, 1);
        if success then
            return unpack(results)
        end
        NDL.Msg("Traced function had an error ", Color(0,150,0),name,"\n")
        NDL.Msg("ArgList: ")
        local args = {...}
        for k, v in pairs(args) do
            MsgC("\t",Color(0,200,0),k,WHITE,": ",Color(0,150,0),Noir.Format.FormatShort(v))
        end
        MsgC(WHITE,"\t(Total:",Color(0,200,0),#args,WHITE,")\n")
        local trace = NDL.PrintTrace(4)
        NDL.Msg("Took ",Color(0,200,0),math.Round((SysTime() - startCall) * 1000,4),WHITE,"ms to run\n")
        NDL.Msg("Error: ", Color(200,0,0), results[1])
        local TraceData = {
            args = args,
            returns = returns,
            startCall = startCall,
            finishCall = finishCall,
            trace = trace
        }
        table.insert(NDL.traces[originalFunc], TraceData)
        if additionalCallback and isfunction(additionalCallback) then
            additionalCallback(TraceData)
        end
        error(results[1])
    end
end

-- Basically replace the original with new func and store the original for future referance
function NDL.Inject(targetTbl,funcName,toInject)
    local original = rawget(targetTbl,funcName)
    if not original then return NDL.Error("Attempt to inject non-existent function") end
    NDL.injections[targetTbl] = NDL.injections[targetTbl] or {}
    NDL.injections[targetTbl][funcName] = toInject
    NDL.originalFuncs[toInject] = original
    rawset(targetTbl, funcName, toInject)
end

function NDL.RestoreInject(targetTbl, funcName)
    if not NDL.injections[targetTbl] then return end
    local currentFn = NDL.injections[targetTbl][funcName]
    if not currentFn then return end
    rawset(targetTbl,funcName,NDL.originalFuncs[currentFn])
end

function NDL.RestoreAllInjects()
    for key, val in pairs(NDL.injections) do
        for k, v in pairs(val) do
            rawset(key, k, NDL.originalFuncs[v])
        end
    end
end

function NDL.Detour(targetTbl,funcName,detourFunc)
    local original = rawget(targetTbl,funcName)
    NDL.Inject(targetTbl, funcName, NDL.MakeDetour(original, detourFunc))
end

function NDL.FilterArgs(targetTbl,funcName,filterFunc)
    local original = rawget(targetTbl,funcName)
    NDL.Inject(targetTbl, funcName, NDL.MakeArgsFilter(original, filterFunc))
end

function NDL.TraceCalls(targetTbl,funcName,name)
    local original = rawget(targetTbl,funcName)
    NDL.Inject(targetTbl, funcName, NDL.MakeCallTracer(original, name or funcName))
end

function NDL.TraceOneCall(targetTbl,funcName,name)
    local original = rawget(targetTbl,funcName)
    NDL.Inject(targetTbl, funcName, NDL.MakeCallTracer(original, name or funcName, function()
        NDL.RestoreInject(targetTbl,funcName)
    end ))
end

-- Condommand to restore all funcs if case of big bork
concommand.Add("ndl_restoreall", NDL.RestoreAllInjects)