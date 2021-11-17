function NDL.getlocals(func)
    local locals = {}
    local names_only = {}
    local i = 1

    while( true ) do
        local name, value = debug.getlocal( func, i )
        if ( name == nil ) then break end
        locals[ name ] = value == nil and NIL or value
        names_only[i] = name
        i = i + 1
    end

    return locals, names_only
end

function NDL.getupvalues(func)
    local upvals = {}
    local names_only = {}
    local i = 1

    while( true ) do
        local name, value = debug.getupvalue( func, i )
        if ( name == nil ) then break end
        upvals[ name ] = value == nil and NIL or value
        names_only[i] = name
        i = i + 1
    end

    return upvals, names_only
end

function NDL.AllInfo(func)
    return {
        func = func,
        info = debug.getinfo(func),
        locals = NDL.getlocals(func),
        upvals = NDL.getupvalues(func)
    }
end
