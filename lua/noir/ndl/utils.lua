-- Walk a function's locals or upvalues via the given debug getter, returning a
-- {name = value} map and a positional {index = name} list. `getter` is
-- debug.getlocal or debug.getupvalue; both share this indexed-scan shape.
local function collect(getter, func)
	local values = {}
	local namesOnly = {}
	local i = 1
	while true do
		local name, value = getter(func, i)
		if name == nil then break end
		values[name] = value == nil and NIL or value
		namesOnly[i] = name
		i = i + 1
	end
	return values, namesOnly
end

function NDL.GetLocals(func)
	return collect(debug.getlocal, func)
end

function NDL.GetUpvalues(func)
	return collect(debug.getupvalue, func)
end

function NDL.AllInfo(func)
	return {
		func = func,
		info = debug.getinfo(func),
		locals = NDL.GetLocals(func),
		upvals = NDL.GetUpvalues(func)
	}
end
