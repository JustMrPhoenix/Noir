local Format = Noir.Format or {}
Noir.Format = Format
local fmt = _G.Format
require("jit_decompiler")
local stringEscape = {
	["\\"] = "\\\\",
	["\0"] = "\\x00",
	["\b"] = "\\b",
	["\t"] = "\\t",
	["\n"] = "\\n",
	["\v"] = "\\v",
	["\f"] = "\\f",
	["\r"] = "\\r",
	["\""] = "\\\"",
}

-- ["\'"] = "\\\'"
local blacklistedTypes = {
	["proto"] = true
}

function Format.GetIterator(opts)
	local mode = istable(opts) and opts.sortMode
	if mode == "SortedPairs" then
		return SortedPairs
	elseif mode == "SortedPairsByValue" then
		return SortedPairsByValue
	end
	return pairs
end

local function formatSource(shortSrc, lineStart, lineEnd)
	return fmt("@%s:%d-%d", shortSrc, lineStart, lineEnd)
end

local function getlocals(func)
	local locals = {}
	local names_only = {}
	local i = 1
	while true do
		local name, value = debug.getlocal(func, i)
		if name == nil then break end
		locals[name] = value == nil and NIL or value
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
	local instructionLines = {}
	for _, entry in ipairs(namedOutput) do
		local line_str = fmt("\n%s    %-3d: %-6s  %s", levelIndent, entry.index, entry.op or "?", entry.code)
		if entry.line and entry.line > 0 then line_str = line_str .. fmt("  -- line %d", entry.line) end
		instructionLines[#instructionLines + 1] = line_str
	end

	local insruction_string = table.concat(instructionLines)

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
		args_str, func, levelIndent .. "    ", upvalStr, insruction_string, levelIndent
	), formatSource(debugInfo.short_src, debugInfo.linedefined, debugInfo.lastlinedefined)
end

function Format.FormatShort(val)
	local valType = type(val)
	if blacklistedTypes[valType] then return tostring(val) end
	if val == nil then
		return "nil"
	elseif valType == "thread" then
		return tostring(val), coroutine.status(val)
	elseif istable(val) then
		if IsColor(val) then
			return fmt("Color(%i,%i,%i,%i)", val.r, val.g, val.b, val.a)
		else
			return fmt("{ tbl:%p#%i }", val, table.Count(val))
		end
	else
		if isstring(val) then
			return fmt("\"%s\"", val:gsub(".", stringEscape))
		elseif isvector(val) then
			return fmt("Vector(%i,%i,%i)", val.x, val.y, val.z)
		elseif isangle(val) then
			return fmt("Angle(%i,%i,%i)", val.pitch, val.yaw, val.roll)
		elseif isentity(val) then
			if val == game.GetWorld() then
				return fmt("game.GetWorld()")
			elseif not IsValid(val) then
				return fmt("NULL"), "INVALID"
			elseif val:IsPlayer() then
				return fmt("player.GetByID(%i)", val:EntIndex()), fmt("%s : %s", val:SteamID(), val:Nick())
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
				return fmt("func:%p(%s)", val, args_str),
					formatSource(debugInfo.short_src, debugInfo.linedefined, debugInfo.lastlinedefined)
			end
		else
			return tostring(val)
		end
	end
end

-- Recursively walks a value tree collecting things that match opts.find.
-- opts.findKeys / opts.findValues / opts.findFuncs select what to match; opts.findInsensitive
-- lowercases both the term and the candidate before a plain (non-pattern) substring match.
-- Function matching (findFuncs) searches the raw bytecode dump's string constants plus upvalue
-- names/values and parameter names -- no full decompilation needed. Returns a comment header
-- plus one line per match, each showing the access path.
function Format.DeepFind(root, opts)
	local rawTerm = opts.find
	local insensitive = opts.findInsensitive
	local searchKeys = opts.findKeys
	local searchValues = opts.findValues
	local searchFuncs = opts.findFuncs
	local term = insensitive and string.lower(rawTerm) or rawTerm
	local function matches(x)
		local s = isstring(x) and x or tostring(x)
		if insensitive then s = string.lower(s) end
		return string.find(s, term, 1, true) ~= nil
	end

	-- Searches a Lua function's string constants, upvalue names/values and parameter names.
	-- Returns a short description of what matched, or nil.
	local function funcReason(fn)
		if debug.getinfo(fn, "S").what == "C" then return end
		local ok, data = pcall(jit.decompiler.disassemble, fn)
		if not ok then return end
		local hits = {}
		for _, v in pairs(data.consts) do
			if isstring(v) and matches(v) then hits[#hits + 1] = fmt("const \"%s\"", v) end
		end
		for _, name in pairs(data.upvalues) do
			if matches(name) then hits[#hits + 1] = "upval " .. name end
		end
		for idx, v in pairs(data.upvalueValues) do
			if not istable(v) and matches(v) then
				hits[#hits + 1] = fmt("upval %s = %s", data.upvalues[idx] or idx, Format.FormatShort(v))
			end
		end
		for _, name in pairs(data.paramNames) do
			if matches(name) then hits[#hits + 1] = "param " .. name end
		end

		return #hits > 0 and table.concat(hits, ", ") or nil
	end

	local results = {}
	local seen = {}
	local MAX = 500
	local truncated = false
	-- Records any match for a single key/value pair under keyStr.
	local function record(keyStr, k, v)
		local matchedKey = searchKeys and matches(k)
		-- Tables are recursed into rather than matched as values; functions go through funcReason.
		local matchedVal = searchValues and not istable(v) and not isfunction(v) and matches(v)
		if matchedKey or matchedVal then
			local valStr, cmt = Format.FormatShort(v)
			local tag = matchedKey and matchedVal and "key+value" or matchedKey and "key" or "value"
			results[#results + 1] = fmt("%s = %s, -- [%s]%s", keyStr, valStr, tag, cmt and (" " .. cmt) or "")
		end

		if searchFuncs and isfunction(v) then
			local reason = funcReason(v)
			if reason then
				local valStr, cmt = Format.FormatShort(v)
				results[#results + 1] = fmt("%s = %s, -- [func: %s]%s", keyStr, valStr, reason, cmt and (" " .. cmt) or "")
			end
		end
	end

	local function recurse(tbl, path)
		if seen[tbl] then return end
		seen[tbl] = true
		for k, v in pairs(tbl) do
			if #results >= MAX then
				truncated = true
				return
			end

			local keyStr
			if isstring(k) and Noir.Utils.IsSafeKey(k) then
				keyStr = path == "" and k or (path .. "." .. k)
			else
				keyStr = path .. fmt("[%s]", Format.FormatShort(k))
			end

			record(keyStr, k, v)
			if istable(v) and not IsColor(v) then recurse(v, keyStr) end
		end
	end

	if istable(root) and not IsColor(root) then
		recurse(root, "")
	elseif searchFuncs and isfunction(root) then
		local reason = funcReason(root)
		if reason then results[#results + 1] = fmt("%s -- [func: %s]", Format.FormatShort(root), reason) end
	end

	local scopes = {}
	if searchKeys then scopes[#scopes + 1] = "keys" end
	if searchValues then scopes[#scopes + 1] = "values" end
	if searchFuncs then scopes[#scopes + 1] = "functions" end
	local header = fmt(
		"-- %d match%s for \"%s\" in %s%s",
		#results, #results == 1 and "" or "es", rawTerm, table.concat(scopes, "+"), insensitive and " (case-insensitive)" or ""
	)
	if truncated then header = header .. fmt(", showing first %d", MAX) end
	if #results == 0 then return header end
	return header .. "\n" .. table.concat(results, "\n")
end

function Format.FormatLong(val, level, opts, doneTbls)
	-- opts can be a table {full, shallow, keys, values, depth} or boolean for backwards compat
	if opts == true then
		opts = {
			full = true
		}
	end

	opts = opts or {}
	local doFull = opts.full
	local valType = type(val)
	if blacklistedTypes[valType] then return tostring(val) end
	level = level or 0
	doneTbls = doneTbls or {}
	-- Deep-find modes search the whole value tree (incl. functions) and produce their own output
	if opts.find and level == 0 then return Format.DeepFind(val, opts) end
	local levelIndent = string.rep("    ", level)
	-- Check if we've hit the depth limit
	local maxDepth = opts.depth
	if maxDepth and level >= maxDepth then return Format.FormatShort(val) end
	if isstring(val) then
		if string.find(val, "\n") then
			val = string.Replace(val, "\\", "\\\\")
			val = string.Replace(val, "]", "\\]")
			return fmt("[[%s]]", val)
		else
			return Format.FormatShort(val)
		end
	elseif valType == "thread" then
		return tostring(val), coroutine.status(val)
	elseif isbool(val) or isnumber(val) then
		return Format.FormatShort(val)
	elseif isentity(val) then
		if IsValid(val) then
			if val:IsPlayer() then
				return fmt(
					"-- %s : %s\n%s-- %s\n%s-- %s\n%s-- http://steamcommunity.com/profiles/%s \n%s%s",
					Format.FormatShort(val), val:Nick(), levelIndent, val:SteamID(), levelIndent,
					val:GetModel(), levelIndent, val:SteamID64(), levelIndent,
					Format.FormatLong(val:GetTable(), level, opts, doneTbls)
				)
			else
				return fmt(
					"-- %s\n%s-- %s\n%s-- %s\n%s%s",
					Format.FormatShort(val), levelIndent, val:GetClass(), levelIndent, val:GetModel(), levelIndent,
					Format.FormatLong(val:GetTable(), level, opts, doneTbls)
				)
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
			local sourceRef = formatSource(debugInfo.short_src, debugInfo.linedefined, debugInfo.lastlinedefined)
			local info
			if debugInfo.source ~= "@" .. debugInfo.short_src then
				info = fmt("%s\n%s-- %s", debugInfo.source, levelIndent, sourceRef)
			else
				info = sourceRef
			end

			if file.Exists(fullpath, "GAME") then
				local fileContent = file.Read(fullpath, "GAME")
				local lines = string.Split(fileContent, "\n")
				if debugInfo.lastlinedefined > #lines then return Format.DecompileFunc(val, level, opts.full) end
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
				return Format.DecompileFunc(val, level, opts.full)
			end
		end
	elseif val and not istable(val) and isfunction(val.GetTable) then
		return fmt("-- %s\n%s", Format.FormatShort(val), Format.FormatLong(val:GetTable(), level, opts, doneTbls))
	elseif not istable(val) or IsColor(val) then
		return Format.FormatShort(val)
	elseif val == nil or (not istable(val) and not IsValid(val)) then
		return Format.FormatShort(val)
	end

	local total = table.Count(val)
	if total == 0 then return "{ }" end
	-- Handle --keys option: output only keys
	if opts.keys and level == 0 then
		local keys = {}
		for k, _ in Format.GetIterator(opts)(val) do
			local str = Format.FormatShort(k)
			table.insert(keys, str)
		end
		return "{\n  " .. table.concat(keys, ",\n  ") .. "\n}"
	end

	-- Handle --values option: output only values
	if opts.values and level == 0 then
		local values = {}
		for _, v in Format.GetIterator(opts)(val) do
			local str = Format.FormatShort(v)
			table.insert(values, str)
		end
		return "{\n  " .. table.concat(values, ",\n  ") .. "\n}"
	end

	local sequential = table.IsSequential(val)
	local result = "{"
	local done = 0
	-- For --shallow, we expand the top level but use short format for nested tables
	-- For --depth, we expand like --full but limited to the specified depth
	local shouldExpand = doFull or opts.shallow or opts.depth
	for k, v in Format.GetIterator(opts)(val) do
		done = done + 1
		if done > 100 and not doFull and not opts.depth and not opts.shallow then
			result = fmt("%s\n%s-- %s more...", result, string.rep(" ", (level + 1) * 4), total - done)
			break
		end

		if sequential then
			local str, cmt
			-- With --shallow, only expand at level 0
			local expandNested = (shouldExpand and not opts.shallow) or (opts.shallow and level == 0)
			if (expandNested or (level == 0 and istable(v) and table.Count(v) < 6)) and not doneTbls[v] then
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
			if (expandNested or (level == 0 and istable(v) and table.Count(v) < 6)) and not doneTbls[v] then
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
			return util.TableToJSON({true, Format.FormatMessage("return", messageData[2], displayFull)})
		end
	end

	Noir.Debug("FormatMessage", messageData)
	if messageData.args then messageData = messageData.args end
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
		for k, v in Format.GetIterator(displayFull)(messageData) do
			local formated, cmt = Format.FormatLong(v, 0, displayFull)
			if string.find(formated, "\n") then formated = "\n" .. formated .. "-- " .. (cmt or "") end
			table.insert(lines, fmt("-- %s : %s", k, formated))
		end

		text = table.concat(lines, "\n")
	end
	return text == "" and "nil" or text
end

function Format.RegisterDashboard()
	if not Noir.Dashboard then return end
	if Format.DashboardRegistered then Noir.Dashboard.Unregister("Output") end
	Noir.Dashboard.Register("Output", {
		{
			key = "tableSort",
			type = "dropdown",
			label = "Table sort order",
			description = "How table contents are ordered when formatting output.",
			category = "Formatting",
			default = "pairs",
			options = {
				{label = "Unsorted (pairs)", value = "pairs"},
				{label = "Sorted by key (SortedPairs)", value = "SortedPairs"},
				{label = "Sorted by value (SortedPairsByValue)", value = "SortedPairsByValue"}
			}
		}
	}, {
		icon = "icon16/text_align_left.png",
		description = "Output formatting settings"
	})
	Format.DashboardRegistered = true
end
