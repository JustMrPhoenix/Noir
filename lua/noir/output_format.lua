local Format = Noir.Format or {}
Noir.Format = Format
local fmt = _G.Format

require("jit_decompiler")

local stringEscape = {
	["\\"] = "\\\\",
	["\0"] = "\\x00" ,
	["\b"] = "\\b" ,
	["\t"] = "\\t" ,
	["\n"] = "\\n" ,
	["\v"] = "\\v" ,
	["\f"] = "\\f" ,
	["\r"] = "\\r" ,
	["\""] = "\\\"",
	-- ["\'"] = "\\\'"
}

local blacklistedTypes = {
	["proto"] = true
}

local function getlocals(func)
	local locals = {}
	local names_only = {}
	local i = 1

	while true do
		local name, value = debug.getlocal( func, i )
		if ( name == nil ) then break end
		locals[ name ] = value == nil and NIL or value
		names_only[i] = name
		i = i + 1
	end

	return locals, names_only
end

function Format.DecompileFunc(func, level, doFull)
	level = level or 0
	local data = jit.decompiler.disassemble(func)
	local debugInfo = debug.getinfo(func)
	local levelIndent = string.rep("    ", level)

	-- Generate named output with resolved constants and upvalues
	local namedOutput = jit.decompiler.generate_named_output(data, Format.FormatShort)

	-- Build the instruction string with named references
	local insruction_string = ""
	for _, entry in ipairs(namedOutput) do
		local line_str = fmt("\n%s    %-3d: %-6s  %s", levelIndent, entry.index, entry.op or "?", entry.code)
		if entry.line and entry.line > 0 then
			line_str = line_str .. fmt("  -- line %d", entry.line)
		end
		insruction_string = insruction_string .. line_str
	end

	local args_str
	if debugInfo.isvararg then
		args_str = "..."
	else
		local _, args = getlocals(func)
		args_str = table.concat(args, ",")
	end

	-- Show upvalue names
	local upvalNames = {}
	for idx, name in pairs(data.upvalues) do
		table.insert(upvalNames, fmt("%d: %s", idx, name))
	end
	local upvalStr = #upvalNames > 0 and table.concat(upvalNames, ", ") or "none"

	return fmt(
		"function(%s) -- %p\n%s-- upvalues: %s%s\n%send",
		args_str, func,
		levelIndent .. "    ",
		upvalStr,
		insruction_string, levelIndent
	), fmt("%s[%d-%d]", debugInfo.short_src, debugInfo.linedefined, debugInfo.lastlinedefined)
end

function Format.FormatShort( val )
	local type = type(val)
	if blacklistedTypes[type] then return tostring(val) end
	if val == nil then
		return "nil"
	elseif type == "thread" then
		return tostring(val), coroutine.status(val)
	elseif istable( val ) then
		if IsColor( val ) then
			return fmt("Color(%i,%i,%i,%i)", val.r, val.g, val.b, val.a)
		else
			return fmt("{ tbl:%p#%i }", val, table.Count(val))
		end
	else
		if isstring( val ) then
			return fmt("\"%s\"", val:gsub( ".", stringEscape ))
		elseif isvector( val ) then
			return fmt("Vector(%i,%i,%i)", val.x, val.y, val.z)
		elseif isangle( val ) then
			return fmt("Angle(%i,%i,%i)", val.pitch, val.yaw, val.roll)
		elseif isentity(val) then
			if val == game.GetWorld() then
				return fmt("game.GetWorld()")
			elseif not IsValid(val) then
				return fmt("NULL"), "INVALID"
			elseif val:IsPlayer() then
				return fmt("player.GetByID(%i)", val:EntIndex()), fmt("%s : %s",val:SteamID(), val:Nick())
			else
				return fmt("Entity(%i)", val:EntIndex()), fmt("%s : %s", val:GetClass(), val:GetModel() or "NO_MODEL")
			end
		elseif isfunction(val) then
			local debugInfo = debug.getinfo(val)
			if debugInfo.what == "C" then
				return fmt("cfunc:%p", val)
			else
				local args_str
				if debugInfo.isvararg then
					args_str = "..."
				else
					local _, args = getlocals(val)
					args_str = table.concat(args, ",")
				end
				return fmt("func:%p(%s)", val, args_str), fmt("%s[%d-%d]", debugInfo.short_src, debugInfo.linedefined, debugInfo.lastlinedefined)
			end
		else
			return tostring( val )
		end
	end
end

function Format.FormatLong( val, level, opts, doneTbls )
	-- opts can be a table {full, shallow, keys, values, depth} or boolean for backwards compat
	if opts == true then opts = {full = true} end
	opts = opts or {}
	local doFull = opts.full
	local type = type(val)
	if blacklistedTypes[type] then return tostring(val) end
	level = level or 0
	doneTbls = doneTbls or {}
	local levelIndent = string.rep("    ", level)

	-- Check if we've hit the depth limit
	local maxDepth = opts.depth
	if maxDepth and level >= maxDepth then
		return Format.FormatShort(val)
	end
	if isstring(val) then
		if string.find(val, "\n") then
			val = string.Replace(val, "\\", "\\\\")
			val = string.Replace(val, "]", "\\]")
			return fmt("[[%s]]", val)
		else
			return Format.FormatShort(val)
		end
	elseif type == "thread" then
		return tostring(val), coroutine.status(val)
	elseif isbool(val) or isnumber(val) then
		return Format.FormatShort(val)
	elseif isentity(val) then
		if IsValid(val) then
			if val:IsPlayer() then
				return fmt("-- %s : %s\n%s-- %s\n%s-- %s\n%s-- http://steamcommunity.com/profiles/%s \n%s%s", Format.FormatShort(val), val:Nick(), levelIndent, val:SteamID(), levelIndent, val:GetModel(), levelIndent, val:SteamID64(), levelIndent, Format.FormatLong( val:GetTable(), level, opts, doneTbls))
			else
				return fmt("-- %s\n%s-- %s\n%s-- %s\n%s%s", Format.FormatShort(val), levelIndent, val:GetClass(), levelIndent, val:GetModel(), levelIndent, Format.FormatLong( val:GetTable(), level, opts, doneTbls))
			end
		else
			return Format.FormatShort(val)
		end

	elseif isfunction(val) then
		local debugInfo = debug.getinfo(val)
		if debugInfo.what == "C" then
			return fmt("cfunc:%p", val)
		else
			local fullpath = debugInfo.short_src
			local info
			if debugInfo.source ~= "@" .. debugInfo.short_src then
				info = fmt("%s\n%s-- %s\n%s-- %d-%d", debugInfo.source, levelIndent,  debugInfo.short_src, levelIndent, debugInfo.linedefined, debugInfo.lastlinedefined)
			else
				info = fmt("%s:%d-%d", debugInfo.source, debugInfo.linedefined, debugInfo.lastlinedefined)
			end
			if file.Exists(fullpath, "GAME") then
				local fileContent = file.Read(fullpath, "GAME")
				local lines = string.Split(fileContent, "\n")
				if debugInfo.lastlinedefined > #lines then
					return Format.DecompileFunc( val, level, opts.full )
				end
				local indent = "^" .. string.match(lines[debugInfo.linedefined], "^%s*")
				local result = string.gsub(lines[debugInfo.linedefined], indent, "")
				if debugInfo.linedefined == debugInfo.lastlinedefined then
					return string.Trim(result), info
				else
					for i = debugInfo.linedefined + 1, debugInfo.lastlinedefined do
						result = result .. "\n" .. levelIndent .. string.gsub(lines[i], indent, "")
					end
					return string.Trim(result), info
				end
			else
				return Format.DecompileFunc( val, level, opts.full )
			end
		end
	elseif val and not istable(val) and isfunction(val.GetTable) then
		return fmt("-- %s\n%s", Format.FormatShort(val), Format.FormatLong( val:GetTable(), level, opts, doneTbls))
	elseif not istable( val ) or IsColor( val ) then
		return Format.FormatShort( val )
	elseif val == nil or ( not istable(val) and not IsValid(val) ) then
		return Format.FormatShort( val )
	end
	local total = table.Count(val)
	if total == 0 then return "{ }" end

	-- Handle --keys option: output only keys
	if opts.keys and level == 0 then
		local keys = {}
		for k, _ in pairs(val) do
			table.insert(keys, Format.FormatShort(k))
		end
		return "{\n  " .. table.concat(keys, ",\n  ") .. "\n}"
	end

	-- Handle --values option: output only values
	if opts.values and level == 0 then
		local values = {}
		for _, v in pairs(val) do
			table.insert(values, Format.FormatShort(v))
		end
		return "{\n  " .. table.concat(values, ",\n  ") .. "\n}"
	end

	local sequential = table.IsSequential( val )
	local result = "{"
	local done = 0

	-- For --shallow, we expand the top level but use short format for nested tables
	-- For --depth, we expand like --full but limited to the specified depth
	local shouldExpand = doFull or opts.shallow or opts.depth

	for k, v in pairs( val ) do
		done = done + 1
		if done > 100 and not doFull and not opts.depth and not opts.shallow then
			result = fmt("%s\n%s-- %s more...", result, string.rep(" ", (level + 1) * 4), total - done)
			break;
		end
		if sequential then
			local str, cmt
			-- With --shallow, only expand at level 0
			local expandNested = (shouldExpand and not opts.shallow) or (opts.shallow and level == 0)
			if ( expandNested or (level == 0 and istable(v) and table.Count(v) < 6) ) and not doneTbls[v] then
				doneTbls[v] = true
				-- For shallow mode, don't pass shallow to nested calls (they'll use short format)
				local nestedOpts = opts.shallow and {} or opts
				str, cmt = Format.FormatLong(v, level + 1, nestedOpts, doneTbls)
			else
				str, cmt = Format.FormatShort(v)
			end
			if cmt and string.find(cmt, "\n") then
				cmt = fmt(" --[[ %s ]]", cmt)
			elseif cmt then
				cmt = fmt(" -- %s", cmt)
			end
			result = fmt("%s\n%s%s,%s", result, string.rep(" ", (level + 1) * 4), str, cmt or "")
		else
			if not isstring(k) then
				k = fmt("[%s]", Format.FormatShort(k))
			elseif not Noir.Utils.IsSafeKey(k) then
				k = fmt("[\"%s\"]", string.Replace(k, "\"", "\\\""))
			end
			local str, cmt
			-- With --shallow, only expand at level 0
			local expandNested = (shouldExpand and not opts.shallow) or (opts.shallow and level == 0)
			if ( expandNested or (level == 0 and istable(v) and table.Count(v) < 6) ) and not doneTbls[v] then
				doneTbls[v] = true
				-- For shallow mode, don't pass shallow to nested calls (they'll use short format)
				local nestedOpts = opts.shallow and {} or opts
				str, cmt = Format.FormatLong(v, level + 1, nestedOpts, doneTbls)
			else
				str, cmt = Format.FormatShort(v)
			end
			if cmt and string.find(cmt, "\n") then
				cmt = fmt(" --[[ %s ]]", cmt)
			elseif cmt then
				cmt = fmt(" -- %s", cmt)
			end
			result = fmt("%s\n%s%s = %s,%s", result, string.rep(" ", (level + 1) * 4), k, str, cmt or "")
		end
	end
	result = result .. "\n" .. string.rep(" ", level * 4) .. "}"
	return result
end

function Format.FormatMessage(message, messageData, displayFull)
	if message == "run" then
		if messageData[1] ~= true then
			return util.TableToJSON({false, messageData[2]})
		else
			return util.TableToJSON({true, Format.FormatMessage("return",messageData[2], displayFull)})
		end
	end
	Noir.Debug("FormatMessage", messageData)
	if messageData.args then
		messageData = messageData.args
	end
	local text = ""
	if #messageData == 1 then
		local formated, cmt = Format.FormatLong(messageData[1], 0, displayFull)
		if cmt then
			text = fmt("-- %s\n%s", cmt, formated)
		else
			text = formated
		end
	else
		local lines = {}
		for k, v in pairs(messageData) do
			local formated, cmt = Format.FormatLong(v, 0, displayFull)
			if string.find(formated, "\n") then
				formated = "\n" .. formated .. "-- " .. (cmt or "")
			end
			table.insert(lines, fmt("-- %s : %s", k, formated))
		end
		text = table.concat(lines, "\n")
	end
	return text == "" and "nil" or text
end