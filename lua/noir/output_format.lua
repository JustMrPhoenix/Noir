local Format = Noir.Format or {}
Noir.Format = Format
local fmt = _G.Format
require("jit_decompiler2")
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

-- Format a number for a vector/angle component: keep up to 3 decimals but strip
-- trailing zeros so whole numbers stay clean and fractional values aren't lost.
local function fmtNum(n)
	if n == math.floor(n) then return fmt("%i", n) end
	local s = fmt("%.3f", n)
	s = s:gsub("0+$", ""):gsub("%.$", "")
	return s
end

-- A comparator that never errors on non-comparable operands. GMod's SortedPairs /
-- SortedPairsByValue do a raw `a < b`, which throws ("attempt to compare two
-- userdata values" / "compare number with string") the moment a table is keyed by
-- (or holds) entities, or mixes key/value types -- both common for run results. We
-- order by type name first, then `<` for the comparable primitives, else by string
-- form, so any value set sorts deterministically without blowing up the whole run.
local function safeLess(a, b)
	local ta, tb = type(a), type(b)
	if ta ~= tb then return ta < tb end
	if ta == "number" or ta == "string" then return a < b end
	return tostring(a) < tostring(b)
end

local function safeSortedPairs(tbl)
	local keys = {}
	for k in pairs(tbl) do keys[#keys + 1] = k end
	table.sort(keys, safeLess)
	local i = 0
	return function()
		i = i + 1
		local k = keys[i]
		if k == nil then return nil end
		return k, tbl[k]
	end
end

local function safeSortedPairsByValue(tbl)
	local kv = {}
	for k, v in pairs(tbl) do kv[#kv + 1] = {k = k, v = v} end
	table.sort(kv, function(a, b) return safeLess(a.v, b.v) end)
	local i = 0
	return function()
		i = i + 1
		local e = kv[i]
		if e == nil then return nil end
		return e.k, e.v
	end
end

function Format.GetIterator(opts)
	local mode = istable(opts) and opts.sortMode
	if mode == "SortedPairs" then
		return safeSortedPairs
	elseif mode == "SortedPairsByValue" then
		return safeSortedPairsByValue
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
	local levelIndent = string.rep("    ", level)
	local debugInfo = debug.getinfo(func)
	-- Reconstruct readable pseudo-Lua; falls back internally to an annotated
	-- listing per function when structuring is not possible.
	local src, decErr = jit.decompiler2.decompile(func, {indent = levelIndent, indentUnit = "    ", formatValue = Format.FormatShort})
	if not src then
		src = fmt("%sfunction() --[[ cannot decompile: %s ]] end", levelIndent, tostring(decErr))
	elseif doFull then
		local listing = jit.decompiler2.disassemble(func, {indent = levelIndent .. "    ", formatValue = Format.FormatShort})
		if listing then
			src = fmt("%s\n%s--[[ bytecode:\n%s\n%s]]", src, levelIndent, listing, levelIndent)
		end
	end

	return src, formatSource(debugInfo.short_src, debugInfo.linedefined, debugInfo.lastlinedefined)
end

-- maxLen (optional): cap on how many characters of a string value are escaped/shown.
-- Escaping runs a per-character gsub, so without a cap a huge string (e.g. an embedded
-- HTML/JS blob) makes this O(size) and can hang the caller. Callers that walk arbitrary
-- values (deep find) pass a small cap; normal callers omit it for the full string.
function Format.FormatShort(val, maxLen)
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
			local s, extra = val, ""
			if maxLen and #s > maxLen then
				s, extra = string.sub(s, 1, maxLen), fmt("..(+%d chars)", #s - maxLen)
			end

			return fmt("\"%s\"%s", s:gsub(".", stringEscape), extra)
		elseif isvector(val) then
			return fmt("Vector(%s,%s,%s)", fmtNum(val.x), fmtNum(val.y), fmtNum(val.z))
		elseif isangle(val) then
			return fmt("Angle(%s,%s,%s)", fmtNum(val.pitch), fmtNum(val.yaw), fmtNum(val.roll))
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

-- Builds the per-node matcher for a deep find. Returns `record, funcReason`:
-- record(keyStr, k, v) -> {line, ...}|nil produces 0..2 result lines for one key/value
-- pair (a key/value match line and/or a function-body match line -- both can fire for the
-- same pair when a matching key holds a function whose body also matches). funcReason(fn)
-- searches a Lua function's bytecode string constants plus upvalue names/values and
-- parameter names (no full decompilation) and returns a short description, or nil.
-- opts.findKeys / opts.findValues / opts.findFuncs select what to match; opts.findInsensitive
-- lowercases both the term and the candidate. opts.findPattern treats the term as a Lua
-- pattern instead of a plain substring (case-insensitive here just lowercases both, so
-- uppercase pattern classes like %u/%A keep their meaning against the lowered subject).
-- Callers validate the pattern up front (Format.DeepFind / DeepFindAsync).
function Format.MakeFindMatcher(opts)
	local insensitive = opts.findInsensitive
	local searchKeys = opts.findKeys
	local searchValues = opts.findValues
	local searchFuncs = opts.findFuncs
	local plain = not opts.findPattern
	local scanLimit = Format.FIND_SCAN_LIMIT
	local term = insensitive and string.lower(opts.find) or opts.find
	-- Only strings and numbers are matched. We deliberately do NOT tostring arbitrary
	-- objects: a value in _G can be a multi-MB string, or an entity/userdata whose
	-- __tostring is slow or non-terminating -- either would hang the whole walk (this is
	-- what could freeze the game). Strings are also capped to scanLimit chars.
	local function matches(x)
		local s
		if isstring(x) then
			s = x
		elseif isnumber(x) then
			s = tostring(x)
		else
			return false
		end

		if #s > scanLimit then s = string.sub(s, 1, scanLimit) end
		if insensitive then s = string.lower(s) end
		return string.find(s, term, 1, plain) ~= nil
	end

	local function funcReason(fn)
		if debug.getinfo(fn, "S").what == "C" then return end
		local ok, data = pcall(jit.decompiler2.metadata, fn)
		if not ok or not data then return end
		local hits = {}
		for _, v in ipairs(data.stringConsts) do
			if matches(v) then hits[#hits + 1] = fmt("const \"%s\"", v) end
		end
		for _, name in pairs(data.upvalueNames) do
			if matches(name) then hits[#hits + 1] = "upval " .. name end
		end
		for idx, v in pairs(data.upvalueValues) do
			if not istable(v) and matches(v) then
				hits[#hits + 1] = fmt("upval %s = %s", data.upvalueNames[idx] or idx, Format.FormatShort(v))
			end
		end
		for _, name in pairs(data.paramNames) do
			if matches(name) then hits[#hits + 1] = "param " .. name end
		end

		return #hits > 0 and table.concat(hits, ", ") or nil
	end

	-- Cheap per-pair match test -- NO access-path string is built here. Returns a small
	-- descriptor (or nil) so the walk can build the (relatively expensive) keyStr only when
	-- there is actually something to report. Tables are recursed into, not value-matched;
	-- functions go through funcReason.
	local function test(k, v)
		local key = searchKeys and matches(k) or false
		local val = searchValues and not istable(v) and not isfunction(v) and matches(v) or false
		local reason
		if searchFuncs and isfunction(v) then reason = funcReason(v) end
		if key or val or reason then return {key = key, val = val, reason = reason} end
	end

	-- Build the result line(s) for a confirmed match (this is where FormatShort runs).
	-- The preview cap keeps escaping a matched multi-MB string from hanging here.
	local preview = Format.FIND_PREVIEW_LEN
	local function render(keyStr, v, desc)
		local lines
		if desc.key or desc.val then
			local valStr, cmt = Format.FormatShort(v, preview)
			local tag = desc.key and desc.val and "key+value" or desc.key and "key" or "value"
			lines = {fmt("%s = %s, -- [%s]%s", keyStr, valStr, tag, cmt and (" " .. cmt) or "")}
		end

		if desc.reason then
			local valStr, cmt = Format.FormatShort(v, preview)
			local line = fmt("%s = %s, -- [func: %s]%s", keyStr, valStr, desc.reason, cmt and (" " .. cmt) or "")
			if lines then lines[#lines + 1] = line else lines = {line} end
		end

		return lines
	end

	return test, render, funcReason
end

-- Assembles the "-- N matches for ..." header describing a find's scope/result count.
function Format.FindHeader(opts, count, truncated, max)
	local scopes = {}
	if opts.findKeys then scopes[#scopes + 1] = "keys" end
	if opts.findValues then scopes[#scopes + 1] = "values" end
	if opts.findFuncs then scopes[#scopes + 1] = "functions" end
	local flags = {}
	if opts.findPattern then flags[#flags + 1] = "pattern" end
	if opts.findInsensitive then flags[#flags + 1] = "case-insensitive" end
	local suffix = #flags > 0 and (" (" .. table.concat(flags, ", ") .. ")") or ""
	local header = fmt(
		"-- %d match%s for \"%s\" in %s%s",
		count, count == 1 and "" or "es", opts.find, table.concat(scopes, "+"), suffix
	)
	if truncated then header = header .. fmt(", showing first %d", max) end
	return header
end

-- Assembles the final find output string (header + one line per match). `elapsed`
-- (seconds), when given, is appended to the header so completed async walks report timing.
local function findText(opts, results, truncated, max, elapsed)
	local header = Format.FindHeader(opts, #results, truncated, max)
	if elapsed then header = header .. fmt(" (took %.2fs)", elapsed) end
	if #results == 0 then return header end
	return header .. "\n" .. table.concat(results, "\n")
end

-- Keys we match but don't recurse into: self-referential / duplicate-heavy globals and
-- metatable __index chains (mirrors Facepunch's developer_functions lua_find). Skipping
-- descent cuts both walk time and noise; the key itself is still matched. FIND_MAX_DEPTH
-- caps recursion so an adversarial deep chain can't overflow the Lua call stack.
Format.FIND_SKIP_KEYS = {_G = true, _R = true, _M = true, _E = true, _LOADED = true, __index = true}
Format.FIND_MAX_DEPTH = 100
-- Bounds so a single pathological value can't hang the walk: _G holds multi-MB strings
-- (embedded HTML/JS, caches). SCAN_LIMIT caps how much of a candidate string we match
-- against; PREVIEW_LEN caps how much of a matched string we escape+show.
Format.FIND_SCAN_LIMIT = 8192
Format.FIND_PREVIEW_LEN = 160
local function findSkip(k) return Format.FIND_SKIP_KEYS[k] == true end

-- Builds a value's access path: a dotted path for safe string keys, else a bracketed
-- FormatShort of the key. Shared by the sync + async walks; only called on a match or a
-- recurse (never per non-matching leaf), so its cost stays off the hot path.
function Format.FindKeyStr(path, k)
	if isstring(k) and Noir.Utils.IsSafeKey(k) then
		return path == "" and k or (path .. "." .. k)
	end

	-- Cap: a key can itself be a huge string, whose escaping would otherwise hang here.
	return path .. fmt("[%s]", Format.FormatShort(k, Format.FIND_PREVIEW_LEN))
end

-- For a pattern find, returns an error header if the Lua pattern is malformed (so we fail
-- with a clear message instead of erroring on every candidate mid-walk), else nil.
local function findPatternError(opts)
	if not opts.findPattern then return end
	local term = opts.findInsensitive and string.lower(opts.find) or opts.find
	if pcall(string.find, "", term) then return end
	return fmt("-- invalid Lua pattern: \"%s\"", opts.find)
end

-- Synchronous deep find over a value tree matching opts.find. Kept for EvalCode /
-- direct FormatLong callers; the REPL run path uses Format.DeepFindAsync so a large
-- walk doesn't freeze the realm it runs on. Returns a comment header plus one line
-- per match, each showing the access path.
function Format.DeepFind(root, opts)
	local patternErr = findPatternError(opts)
	if patternErr then return patternErr end
	local test, render, funcReason = Format.MakeFindMatcher(opts)
	local results = {}
	local seen = {}
	local max = opts.findMaxResults or 500
	local maxDepth = opts.findMaxDepth or Format.FIND_MAX_DEPTH
	local truncated = false

	-- Breadth-first (see Noir.TableSearch): the first time a table is reached is via a
	-- shortest path, so matches/paths under it use the fewest-hops access path.
	if istable(root) and not IsColor(root) then
		local queue = {{root, "", 0}}
		seen[root] = true
		local head = 1
		while head <= #queue and not truncated do
			local node = queue[head]
			queue[head] = false
			head = head + 1
			local tbl, path, depth = node[1], node[2], node[3]
			for k, v in pairs(tbl) do
				if #results >= max then truncated = true break end
				local desc = test(k, v)
				local enqueue = depth < maxDepth and istable(v) and not IsColor(v)
					and not seen[v] and not findSkip(k)
				if desc or enqueue then
					local keyStr = Format.FindKeyStr(path, k)
					if desc then
						local lines = render(keyStr, v, desc)
						for i = 1, #lines do
							results[#results + 1] = lines[i]
							if #results >= max then
								truncated = true
								break
							end
						end
					end

					if enqueue then
						seen[v] = true
						queue[#queue + 1] = {v, keyStr, depth + 1}
					end
				end
			end
		end
	elseif opts.findFuncs and isfunction(root) then
		local reason = funcReason(root)
		if reason then results[#results + 1] = fmt("%s -- [func: %s]", Format.FormatShort(root), reason) end
	end

	return findText(opts, results, truncated, max)
end

-- Asynchronous deep find: walks a table root off Noir.TableSearch's time-budgeted
-- driver (so it never freezes the realm), then calls onDone(finalString). A non-table
-- (or bare-function) root is cheap and handled synchronously. Returns the running job
-- (or nil for the synchronous path) so callers can cancel it.
function Format.DeepFindAsync(root, opts, onDone)
	local patternErr = findPatternError(opts)
	if patternErr then
		onDone(patternErr)
		return
	end

	local max = opts.findMaxResults or 500
	if not istable(root) or IsColor(root) then
		local results = {}
		if opts.findFuncs and isfunction(root) then
			local _, _, funcReason = Format.MakeFindMatcher(opts)
			local reason = funcReason(root)
			if reason then results[1] = fmt("%s -- [func: %s]", Format.FormatShort(root), reason) end
		end

		onDone(findText(opts, results, false, max))
		return
	end

	local test, render = Format.MakeFindMatcher(opts)
	return Noir.TableSearch.Start({
		root = root,
		test = test,
		render = render,
		skipDescend = findSkip,
		frameBudget = opts.findBudgetMs and (opts.findBudgetMs / 1000) or nil,
		maxResults = max,
		maxDepth = opts.findMaxDepth,
		onDone = function(job) onDone(findText(opts, job.results, job.truncated, max, job.elapsed)) end
	})
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
	-- Pre-formatted passthrough: an already-assembled string (e.g. an async find result)
	-- is delivered verbatim rather than re-quoted or re-searched.
	if opts.preformatted and level == 0 and isstring(val) then return val end
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
		if done >= 100 and not doFull and not opts.depth and not opts.shallow then
			result = fmt("%s\n%s-- %s more...", result, string.rep(" ", (level + 1) * 4), total - done)
			break
		end

		done = done + 1

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

	-- Async table-search (--find*) performance knobs, carried in the run data and
	-- applied on whichever realm runs the walk (see Noir.SendCode / Format.DeepFindAsync).
	if Format.SearchDashboardRegistered then Noir.Dashboard.Unregister("Search") end
	Noir.Dashboard.Register("Search", {
		{
			key = "frameBudgetMs",
			type = "slider",
			label = "Frame budget (ms)",
			description = "How long a --find table walk may work per frame. Higher = faster searches, lower = smoother framerate.",
			default = 16,
			min = 1,
			max = 33,
			decimals = 0,
			category = "Performance"
		},
		{
			key = "maxResults",
			type = "number",
			label = "Max results",
			description = "Cap on the number of matches a --find search collects before stopping.",
			default = 500,
			min = 1,
			category = "Performance"
		},
		{
			key = "maxDepth",
			type = "number",
			label = "Max depth",
			description = "How deep a --find search recurses into nested tables before stopping (guards against pathological trees).",
			default = 100,
			min = 1,
			category = "Performance"
		}
	}, {
		icon = "icon16/magnifier.png",
		description = "Deep-find (--find) search settings"
	})
	Format.SearchDashboardRegistered = true
end
