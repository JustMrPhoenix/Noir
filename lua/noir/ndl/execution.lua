local WHITE = Color(255,255,255)

function NDL.GetTraceInfo(startFrom)
    local tb = {}
    for i = startFrom or 2, 1 / 0, 1 do
        local dbg = debug.getinfo(i)
        if not dbg then break end
        table.insert( tb, dbg )
    end
    return tb
end

function NDL.PrintTrace(startLvl)
    local traceInfo = NDL.GetTraceInfo(startLvl or 3)
    NDL.Msg("Traceback:\n")
    for k,v in pairs(traceInfo) do
        NDL.Msg(string.rep("  ",k-1), k, ": ", Color(245, 255, 0), v.name or " unknown", WHITE, " - ",Color(0,200,0), v.short_src, WHITE, ":", Color(0,150,0),v.currentline,"\n")
    end
    return traceInfo
end

function NDL.PCall(func,...)
    local result = {pcall(func,...)}
    local succ = table.remove(result, 1)
    if succ then
        return succ, result
    else
        return succ, result[1]
    end
end

-- Same as NDL.PCall but prints an error and traceback
function NDL.Call(func,...)
    local succ, result = NDL.PCall(func,...)
    if succ then
        return succ, result
    else
        NDL.Error("Error calling func ",Color(0,150,0),tostring(func),WHITE,": ",Color(245, 255, 0),result,"\n")
        NDL.PrintTrace()
        return succ, result
    end
end