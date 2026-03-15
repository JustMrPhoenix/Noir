-- LuaJIT Bytecode Decompiler
-- Disassembles LuaJIT bytecode into human-readable format
local OPNAMES = {}
local INST = {}
-- Bytecode names from LuaJIT (6 chars each, padded with spaces)
local bcnames = "ISLT  ISGE  ISLE  ISGT  ISEQV ISNEV ISEQS ISNES ISEQN ISNEN ISEQP ISNEP ISTC  ISFC  IST   ISF   ISTYPEISNUM MOV   NOT   UNM   LEN   ADDVN SUBVN MULVN DIVVN MODVN ADDNV SUBNV MULNV DIVNV MODNV ADDVV SUBVV MULVV DIVVV MODVV POW   CAT   KSTR  KCDATAKSHORTKNUM  KPRI  KNIL  UGET  USETV USETS USETN USETP UCLO  FNEW  TNEW  TDUP  GGET  GSET  TGETV TGETS TGETB TGETR TSETV TSETS TSETB TSETM TSETR CALLM CALL  CALLMTCALLT ITERC ITERN VARG  ISNEXTRETM  RET   RET0  RET1  FORI  JFORI FORL  IFORL JFORL ITERL IITERLJITERLLOOP  ILOOP JLOOP JMP   FUNCF IFUNCFJFUNCFFUNCV IFUNCVJFUNCVFUNCC FUNCCW"
do
	local i = 0
	for str in bcnames:gmatch"......" do
		str = str:gsub("%s", "")
		OPNAMES[i] = str
		INST[str] = i
		i = i + 1
	end
end

-- Build BCMode table with bidirectional mappings
local BCMode = {}
do
	local modes = {"BCMnone", "BCMdst", "BCMbase", "BCMvar", "BCMrbase", "BCMuv", "BCMlit", "BCMlits", "BCMpri", "BCMnum", "BCMstr", "BCMtab", "BCMfunc", "BCMjump", "BCMcdata"}
	for i, name in ipairs(modes) do
		BCMode[name] = i - 1
		BCMode[i - 1] = name
	end
end

-- Convert primitive index to string (0=nil, 1=false, 2=true)
local function priToString(d)
	return d == 0 and "nil" or (d == 1 and "false" or "true")
end

-- Instruction categories
local JIT_INST = {
	[INST.JFORI] = true,
	[INST.JFORL] = true,
	[INST.JITERL] = true,
	[INST.JLOOP] = true,
	[INST.JFUNCF] = true,
	[INST.JFUNCV] = true
}

local JIT_INCOMPATIBLE_INS = {
	[INST.IFORL] = true,
	[INST.IITERL] = true,
	[INST.ILOOP] = true,
	[INST.IFUNCF] = true,
	[INST.IFUNCV] = true,
	[INST.ITERN] = true,
	[INST.ISNEXT] = true,
	[INST.UCLO] = true,
	[INST.FNEW] = true
}

local functions_headers = {
	[INST.FUNCF] = true,
	[INST.IFUNCF] = true,
	[INST.JFUNCF] = true,
	[INST.FUNCV] = true,
	[INST.IFUNCV] = true,
	[INST.JFUNCV] = true,
	[INST.FUNCC] = true,
	[INST.FUNCCW] = true
}

-- Instruction documentation generators
local registersDocumentation = {
	[INST.GGET] = function(ins, consts)
		local name = tostring(consts[-ins.D - 1] or "?")
		ins.A_value = name
		ins.DO = string.format("stack[%i] = _G[\"%s\"]", ins.A, name)
	end,
	[INST.UGET] = function(ins, _, upvalues)
		local uvname = upvalues[ins.D] or ("upvalue_" .. ins.D)
		ins.A_value = uvname
		ins.DO = string.format("stack[%i] = %s -- upvalue", ins.A, uvname)
	end,
	[INST.USETV] = function(ins, _, upvalues)
		local uvname = upvalues[ins.A] or ("upvalue_" .. ins.A)
		ins.DO = string.format("%s = stack[%i] -- set upvalue", uvname, ins.D)
	end,
	[INST.USETS] = function(ins, consts, upvalues)
		local uvname = upvalues[ins.A] or ("upvalue_" .. ins.A)
		ins.DO = string.format("%s = \"%s\" -- set upvalue", uvname, tostring(consts[-ins.D - 1] or "?"))
	end,
	[INST.USETN] = function(ins, consts, upvalues)
		local uvname = upvalues[ins.A] or ("upvalue_" .. ins.A)
		ins.DO = string.format("%s = %s -- set upvalue", uvname, tostring(consts[ins.D] or "?"))
	end,
	[INST.USETP] = function(ins, _, upvalues)
		local uvname = upvalues[ins.A] or ("upvalue_" .. ins.A)
		ins.DO = string.format("%s = %s -- set upvalue", uvname, priToString(ins.D))
	end,
	[INST.TGETS] = function(ins, consts)
		local key = tostring(consts[-ins.C - 1] or "?")
		ins.A_value = "stack[" .. ins.B .. "][\"" .. key .. "\"]"
		ins.DO = string.format("stack[%i] = stack[%i][\"%s\"]", ins.A, ins.B, key)
	end,
	[INST.TSETS] = function(ins, consts)
		local key = tostring(consts[-ins.C - 1] or "?")
		ins.DO = string.format("stack[%i][\"%s\"] = stack[%i]", ins.B, key, ins.A)
	end,
	[INST.FNEW] = function(ins, consts)
		local proto = consts[-ins.D - 1]
		ins.A_value = tostring(proto)
		ins.DO = string.format("stack[%i] = function() -- %s", ins.A, tostring(proto))
	end,
	[INST.GSET] = function(ins, consts)
		local name = tostring(consts[-ins.D - 1] or "?")
		ins.DO = string.format("_G[\"%s\"] = stack[%i]", name, ins.A)
	end,
	[INST.UCLO] = function(ins) ins.DO = string.format("Close upvalues >= %i, jump to %i", ins.A, ins.D) end,
	[INST.KSTR] = function(ins, consts) ins.DO = string.format("stack[%i] = \"%s\"", ins.A, tostring(consts[-ins.D - 1])) end,
	[INST.KCDATA] = function(ins, consts) ins.DO = string.format("stack[%i] = %s", ins.A, tostring(consts[-ins.D - 1])) end,
	[INST.KSHORT] = function(ins) ins.DO = string.format("stack[%i] = %s", ins.A, ins.D) end,
	[INST.KNUM] = function(ins, consts) ins.DO = string.format("stack[%i] = %s", ins.A, tostring(consts[ins.D])) end,
	[INST.KPRI] = function(ins) ins.DO = string.format("stack[%i] = %s", ins.A, priToString(ins.D)) end,
	[INST.KNIL] = function(ins)
		local parts = {}
		for slot = ins.A, ins.D do
			table.insert(parts, string.format("stack[%i] = nil", slot))
		end

		ins.DO = table.concat(parts, "\n")
	end,
	[INST.TNEW] = function(ins) ins.DO = string.format("stack[%i] = {}", ins.A) end,
	[INST.TDUP] = function(ins, consts)
		local tbl = consts[-ins.D - 1]
		if tbl and type(tbl) == "table" then
			local parts = {}
			for k, v in pairs(tbl) do
				local key = type(k) == "string" and string.format("[%q]", k) or string.format("[%s]", tostring(k))
				local val = type(v) == "string" and string.format("%q", v) or tostring(v)
				table.insert(parts, key .. " = " .. val)
			end

			ins.DO = string.format("stack[%i] = {%s}", ins.A, table.concat(parts, ", "))
		else
			ins.DO = string.format("stack[%i] = {--[[template]]}", ins.A)
		end
	end,
	[INST.ISEQS] = function(ins, consts) ins.DO = string.format("if stack[%i] == \"%s\" then jump", ins.A, tostring(consts[-ins.D - 1] or "?")) end,
	[INST.ISNES] = function(ins, consts) ins.DO = string.format("if stack[%i] ~= \"%s\" then jump", ins.A, tostring(consts[-ins.D - 1] or "?")) end,
	[INST.ISEQN] = function(ins, consts) ins.DO = string.format("if stack[%i] == %s then jump", ins.A, tostring(consts[ins.D] or "?")) end,
	[INST.ISNEN] = function(ins, consts) ins.DO = string.format("if stack[%i] ~= %s then jump", ins.A, tostring(consts[ins.D] or "?")) end,
	[INST.ISEQP] = function(ins) ins.DO = string.format("if stack[%i] == %s then jump", ins.A, priToString(ins.D)) end,
	[INST.ISNEP] = function(ins) ins.DO = string.format("if stack[%i] ~= %s then jump", ins.A, priToString(ins.D)) end,
	[INST.ADDVN] = function(ins, consts) ins.DO = string.format("stack[%i] = stack[%i] + %s", ins.A, ins.B, tostring(consts[ins.C] or "?")) end,
	[INST.SUBVN] = function(ins, consts) ins.DO = string.format("stack[%i] = stack[%i] - %s", ins.A, ins.B, tostring(consts[ins.C] or "?")) end,
	[INST.MULVN] = function(ins, consts) ins.DO = string.format("stack[%i] = stack[%i] * %s", ins.A, ins.B, tostring(consts[ins.C] or "?")) end,
	[INST.DIVVN] = function(ins, consts) ins.DO = string.format("stack[%i] = stack[%i] / %s", ins.A, ins.B, tostring(consts[ins.C] or "?")) end,
	[INST.MODVN] = function(ins, consts) ins.DO = string.format("stack[%i] = stack[%i] %% %s", ins.A, ins.B, tostring(consts[ins.C] or "?")) end,
	[INST.ADDNV] = function(ins, consts) ins.DO = string.format("stack[%i] = %s + stack[%i]", ins.A, tostring(consts[ins.C] or "?"), ins.B) end,
	[INST.SUBNV] = function(ins, consts) ins.DO = string.format("stack[%i] = %s - stack[%i]", ins.A, tostring(consts[ins.C] or "?"), ins.B) end,
	[INST.MULNV] = function(ins, consts) ins.DO = string.format("stack[%i] = %s * stack[%i]", ins.A, tostring(consts[ins.C] or "?"), ins.B) end,
	[INST.DIVNV] = function(ins, consts) ins.DO = string.format("stack[%i] = %s / stack[%i]", ins.A, tostring(consts[ins.C] or "?"), ins.B) end,
	[INST.MODNV] = function(ins, consts) ins.DO = string.format("stack[%i] = %s %% stack[%i]", ins.A, tostring(consts[ins.C] or "?"), ins.B) end,
	[INST.ADDVV] = function(ins) ins.DO = string.format("stack[%i] = stack[%i] + stack[%i]", ins.A, ins.B, ins.C) end,
	[INST.SUBVV] = function(ins) ins.DO = string.format("stack[%i] = stack[%i] - stack[%i]", ins.A, ins.B, ins.C) end,
	[INST.MULVV] = function(ins) ins.DO = string.format("stack[%i] = stack[%i] * stack[%i]", ins.A, ins.B, ins.C) end,
	[INST.DIVVV] = function(ins) ins.DO = string.format("stack[%i] = stack[%i] / stack[%i]", ins.A, ins.B, ins.C) end,
	[INST.MODVV] = function(ins) ins.DO = string.format("stack[%i] = stack[%i] %% stack[%i]", ins.A, ins.B, ins.C) end,
	[INST.POW] = function(ins) ins.DO = string.format("stack[%i] = stack[%i] ^ stack[%i]", ins.A, ins.B, ins.C) end,
	[INST.MOV] = function(ins) ins.DO = string.format("stack[%i] = stack[%i]", ins.A, ins.D) end,
	[INST.NOT] = function(ins) ins.DO = string.format("stack[%i] = not stack[%i]", ins.A, ins.D) end,
	[INST.UNM] = function(ins) ins.DO = string.format("stack[%i] = -stack[%i]", ins.A, ins.D) end,
	[INST.LEN] = function(ins) ins.DO = string.format("stack[%i] = #stack[%i]", ins.A, ins.D) end,
	[INST.TGETV] = function(ins) ins.DO = string.format("stack[%i] = stack[%i][stack[%i]]", ins.A, ins.B, ins.C) end,
	[INST.TGETB] = function(ins) ins.DO = string.format("stack[%i] = stack[%i][%i]", ins.A, ins.B, ins.C) end,
	[INST.TSETV] = function(ins) ins.DO = string.format("stack[%i][stack[%i]] = stack[%i]", ins.B, ins.C, ins.A) end,
	[INST.TSETB] = function(ins) ins.DO = string.format("stack[%i][%i] = stack[%i]", ins.B, ins.C, ins.A) end,
	[INST.CALL] = function(ins)
		local nargs, nrets = ins.C - 1, ins.B - 1
		local args = {}
		for j = 1, nargs do
			table.insert(args, string.format("stack[%i]", ins.A + j))
		end

		local argsStr = table.concat(args, ", ")
		if nrets == 0 then
			ins.DO = string.format("stack[%i](%s)", ins.A, argsStr)
		elseif nrets == 1 then
			ins.DO = string.format("stack[%i] = stack[%i](%s)", ins.A, ins.A, argsStr)
		else
			ins.DO = string.format("stack[%i..%i] = stack[%i](%s)", ins.A, ins.A + nrets - 1, ins.A, argsStr)
		end
	end,
	[INST.CALLM] = function(ins)
		local nrets = ins.B - 1
		local args = {}
		for j = 1, ins.C do
			table.insert(args, string.format("stack[%i]", ins.A + j))
		end

		table.insert(args, "...")
		local argsStr = table.concat(args, ", ")
		if nrets == 0 then
			ins.DO = string.format("stack[%i](%s)", ins.A, argsStr)
		else
			ins.DO = string.format("stack[%i..%i] = stack[%i](%s)", ins.A, ins.A + nrets - 1, ins.A, argsStr)
		end
	end,
	[INST.CALLT] = function(ins)
		local nargs = ins.D - 1
		local args = {}
		for j = 1, nargs do
			table.insert(args, string.format("stack[%i]", ins.A + j))
		end

		ins.DO = string.format("return stack[%i](%s)", ins.A, table.concat(args, ", "))
	end,
	[INST.CALLMT] = function(ins) ins.DO = string.format("return stack[%i](...)", ins.A) end,
	[INST.RET] = function(ins)
		local nrets = ins.D - 1
		if nrets == 0 then
			ins.DO = "return"
		else
			ins.DO = string.format("return stack[%i..%i]", ins.A, ins.A + nrets - 1)
		end
	end,
	[INST.RET0] = function(ins) ins.DO = "return" end,
	[INST.RET1] = function(ins) ins.DO = string.format("return stack[%i]", ins.A) end,
	[INST.CAT] = function(ins) ins.DO = string.format("stack[%i] = stack[%i] .. ... .. stack[%i]", ins.A, ins.B, ins.C) end
}

-- Handle jump target calculation
local function doSpecialModeOperations(ins, n)
	local modeC = ins.OP_MODES.CODE.C
	if modeC == BCMode.BCMjump then ins.D = ins.D - 0x7fff + n end
end

local function getRegistersDocumentation(ins, consts, upvalues)
	local handler = registersDocumentation[ins.OP_CODE]
	if handler then handler(ins, consts, upvalues) end
end

-- Parse constants from string.dump (fallback for GMod where funck is disabled)
local function parse_constants_from_dump(fn)
	local ok, dump = pcall(string.dump, fn)
	if not ok or not dump then return nil end
	local pos = 1
	local len = #dump
	local function read_byte()
		if pos > len then return nil end
		local b = string.byte(dump, pos)
		pos = pos + 1
		return b
	end

	local function read_uleb128()
		local result, shift = 0, 0
		repeat
			local b = read_byte()
			if not b then return nil end
			result = result + bit.lshift(bit.band(b, 0x7F), shift)
			shift = shift + 7
		until bit.band(b, 0x80) == 0
		return result
	end

	local function read_string(length)
		if length == 0 then return "" end
		if pos + length - 1 > len then return nil end
		local s = string.sub(dump, pos, pos + length - 1)
		pos = pos + length
		return s
	end

	-- Skip header: ESC 'L' 'J' version flags [name]
	if read_byte() ~= 0x1b or read_byte() ~= 0x4c or read_byte() ~= 0x4a then return nil end
	read_byte() -- version
	local flags = read_uleb128()
	if not flags then return nil end
	local BCDUMP_F_STRIP = 2
	if bit.band(flags, BCDUMP_F_STRIP) == 0 then
		local namelen = read_uleb128()
		if namelen and namelen > 0 then read_string(namelen) end
	end

	local function read_proto()
		local proto_consts = {}
		local plen = read_uleb128()
		if not plen or plen == 0 then return nil end
		local proto_start = pos
		read_byte() -- pflags
		read_byte() -- numparams
		read_byte() -- framesize
		local numuv = read_byte()
		local numkgc = read_uleb128()
		local numkn = read_uleb128()
		local numbc = read_uleb128()
		if bit.band(flags, BCDUMP_F_STRIP) == 0 then
			local dbglen = read_uleb128()
			if dbglen and dbglen > 0 then
				read_uleb128() -- firstline
				read_uleb128() -- numline
			end
		end

		-- Skip bytecode (4 bytes each)
		for _ = 1, numbc do
			read_byte()
			read_byte()
			read_byte()
			read_byte()
		end

		-- Skip upvalues (2 bytes each)
		for _ = 1, numuv do
			read_byte()
			read_byte()
		end

		-- Read GC constants
		local BCDUMP_KGC_CHILD, BCDUMP_KGC_TAB, BCDUMP_KGC_STR = 0, 1, 5
		local gc_consts_array = {}
		for _ = 1, numkgc do
			local ktype = read_uleb128()
			if not ktype then break end
			if ktype >= BCDUMP_KGC_STR then
				local str = read_string(ktype - BCDUMP_KGC_STR)
				table.insert(gc_consts_array, str or "")
			elseif ktype == BCDUMP_KGC_TAB then
				local narray = read_uleb128() or 0
				local nhash = read_uleb128() or 0
				for _ = 1, narray do
					local vtype = read_uleb128()
					if vtype and vtype >= BCDUMP_KGC_STR then read_string(vtype - BCDUMP_KGC_STR) end
				end

				for _ = 1, nhash do
					local kt = read_uleb128()
					if kt and kt >= BCDUMP_KGC_STR then read_string(kt - BCDUMP_KGC_STR) end
					local vt = read_uleb128()
					if vt and vt >= BCDUMP_KGC_STR then read_string(vt - BCDUMP_KGC_STR) end
				end

				table.insert(gc_consts_array, {})
			elseif ktype == BCDUMP_KGC_CHILD then
				table.insert(gc_consts_array, "proto")
			else
				table.insert(gc_consts_array, "unknown_" .. ktype)
			end
		end

		-- GC constants stored in reverse order
		for i = 1, #gc_consts_array do
			proto_consts[-i] = gc_consts_array[#gc_consts_array - i + 1]
		end

		-- Read numeric constants
		for i = 0, numkn - 1 do
			local isnum = read_uleb128()
			if isnum then
				if bit.band(isnum, 1) == 0 then
					proto_consts[i] = bit.rshift(isnum, 1)
				else
					proto_consts[i] = read_uleb128()
				end
			end
		end

		pos = proto_start + plen
		return proto_consts
	end

	local last_consts
	while true do
		local proto_consts = read_proto()
		if not proto_consts then break end
		last_consts = proto_consts
	end
	return last_consts
end

local disassembly_cache = {}
-- Main disassembly function
local function disassemble_function(fn, fast, kill_cache)
	if disassembly_cache[fn] and not kill_cache then return disassembly_cache[fn] end
	assert(fn, "function expected")
	local fnInfo = jit.util.funcinfo(fn)
	assert(fnInfo.loc, "expected a Lua function, not a C one")
	-- Collect upvalues using debug.getupvalue (1-based, convert to 0-based)
	local upvalues = {}
	local upvalueValues = {}
	for i = 1, fnInfo.upvalues do
		local name, value = debug.getupvalue(fn, i)
		if name then
			upvalues[i - 1] = name
			upvalueValues[i - 1] = value
		end
	end

	-- Collect parameter names using debug.getlocal (1-based, convert to 0-based)
	local paramNames = {}
	for i = 1, fnInfo.params do
		local name = debug.getlocal(fn, i)
		if name then paramNames[i - 1] = name end
	end

	-- Collect constants
	local consts = {}
	-- Numeric constants (positive indices)
	for i = 0, fnInfo.nconsts - 1 do
		local value = jit.util.funck(fn, i)
		if value ~= nil then consts[i] = value end
	end

	-- GC constants (negative indices) - try funck first, fallback to dump parsing
	local funck_works = false
	local nGCConsts = fnInfo.gcconsts or 0
	for i = 1, nGCConsts do
		local value = jit.util.funck(fn, -i)
		if value ~= nil then
			consts[-i] = value
			funck_works = true
		end
	end

	if not funck_works and nGCConsts > 0 then
		local dump_consts = parse_constants_from_dump(fn)
		if dump_consts then
			for k, v in pairs(dump_consts) do
				consts[k] = v
			end
		end
	end

	-- Verify function header
	local header = bit.band(select(1, jit.util.funcbc(fn, 0)), 0xFF)
	assert(functions_headers[header], "Unknown function header: " .. (OPNAMES[header] or header))
	-- Disassemble bytecode
	local instructions = {}
	local countBC = fnInfo.bytecodes
	for n = 0, countBC - 1 do
		local ins_raw, mode = jit.util.funcbc(fn, n)
		local modeA = bit.band(mode, 7)
		local modeB = bit.rshift(bit.band(mode, 15 * 8), 3)
		local modeC = bit.rshift(bit.band(mode, 15 * 128), 7)
		local ins = {
			OP_CODE = bit.band(ins_raw, 0xFF),
			line = jit.util.funcinfo(fn, n + 1).currentline,
			OP_MODES = {
				CODE = {
					A = modeA,
					B = modeB,
					C = modeC
				}
			},
			A = bit.rshift(bit.band(ins_raw, 0x0000ff00), 8),
			B = bit.rshift(ins_raw, 24),
			C = bit.rshift(bit.band(ins_raw, 0x00ff0000), 16),
			D = bit.rshift(ins_raw, 16)
		}

		if not fast then
			ins.OP_ENGLISH = OPNAMES[ins.OP_CODE]
			ins.OP_MODES.ENGLISH = {
				A = BCMode[modeA],
				B = BCMode[modeB],
				C = BCMode[modeC]
			}
		end

		doSpecialModeOperations(ins, n)
		if not fast then getRegistersDocumentation(ins, consts, upvalues) end
		instructions[n] = ins
	end

	local result = {
		consts = consts,
		instructions = instructions,
		upvalues = upvalues,
		upvalueValues = upvalueValues,
		paramNames = paramNames,
		info = fnInfo
	}

	disassembly_cache[fn] = result
	return result
end

-- Format a value for display
local function formatValue(val)
	local t = type(val)
	if t == "string" then
		return string.format("%q", val)
	elseif t == "number" or t == "boolean" then
		return tostring(val)
	elseif val == nil then
		return "nil"
	else
		return tostring(val)
	end
end

-- Dispatch table for named output generation
-- Each handler receives (ins, ctx) where ctx = {getSlot, setSlot, consts, upvalues, info, i}
-- Returns the output line string
local namedOutputHandlers = {}
-- Function headers
local function handleFuncHeader(ins, ctx)
	local paramList = {}
	for j = 0, (ctx.info.params or 1) - 1 do
		table.insert(paramList, ctx.getSlot(j))
	end
	return string.format("-- function(%s)", table.concat(paramList, ", "))
end

local function handleFuncVHeader(ins, ctx)
	local paramList = {}
	for j = 0, (ctx.info.params or 0) - 1 do
		table.insert(paramList, ctx.getSlot(j))
	end

	table.insert(paramList, "...")
	return string.format("-- function(%s)", table.concat(paramList, ", "))
end

namedOutputHandlers[INST.FUNCF] = handleFuncHeader
namedOutputHandlers[INST.IFUNCF] = handleFuncHeader
namedOutputHandlers[INST.JFUNCF] = handleFuncHeader
namedOutputHandlers[INST.FUNCV] = handleFuncVHeader
namedOutputHandlers[INST.IFUNCV] = handleFuncVHeader
namedOutputHandlers[INST.JFUNCV] = handleFuncVHeader
-- Global get/set
namedOutputHandlers[INST.GGET] = function(ins, ctx)
	local name = tostring(ctx.consts[-ins.D - 1] or "?")
	ctx.setSlot(ins.A, name)
	return string.format("%s = _G[\"%s\"]", name, name)
end

namedOutputHandlers[INST.GSET] = function(ins, ctx)
	local name = tostring(ctx.consts[-ins.D - 1] or "?")
	return string.format("_G[\"%s\"] = %s", name, ctx.getSlot(ins.A))
end

-- Upvalue get/set
namedOutputHandlers[INST.UGET] = function(ins, ctx)
	local uvname = ctx.upvalues[ins.D] or ("uv" .. ins.D)
	ctx.setSlot(ins.A, uvname)
	return string.format("%s = upvalue[%d]  -- %s", ctx.getSlot(ins.A), ins.D, uvname)
end

namedOutputHandlers[INST.USETV] = function(ins, ctx)
	local uvname = ctx.upvalues[ins.A] or ("uv" .. ins.A)
	return string.format("upvalue[%d] = %s  -- set %s", ins.A, ctx.getSlot(ins.D), uvname)
end

namedOutputHandlers[INST.USETS] = function(ins, ctx)
	local uvname = ctx.upvalues[ins.A] or ("uv" .. ins.A)
	local str = tostring(ctx.consts[-ins.D - 1] or "?")
	return string.format("upvalue[%d] = %q  -- set %s", ins.A, str, uvname)
end

namedOutputHandlers[INST.USETN] = function(ins, ctx)
	local uvname = ctx.upvalues[ins.A] or ("uv" .. ins.A)
	local num = tostring(ctx.consts[ins.D] or "?")
	return string.format("upvalue[%d] = %s  -- set %s", ins.A, num, uvname)
end

namedOutputHandlers[INST.USETP] = function(ins, ctx)
	local uvname = ctx.upvalues[ins.A] or ("uv" .. ins.A)
	return string.format("upvalue[%d] = %s  -- set %s", ins.A, priToString(ins.D), uvname)
end

-- Constants
namedOutputHandlers[INST.KSTR] = function(ins, ctx)
	local str = tostring(ctx.consts[-ins.D - 1] or "?")
	ctx.setSlot(ins.A, string.format("%q", str))
	return string.format("local_%d = %q", ins.A, str)
end

namedOutputHandlers[INST.KNUM] = function(ins, ctx)
	local num = ctx.consts[ins.D]
	ctx.setSlot(ins.A, tostring(num))
	return string.format("local_%d = %s", ins.A, tostring(num))
end

namedOutputHandlers[INST.KSHORT] = function(ins, ctx)
	ctx.setSlot(ins.A, tostring(ins.D))
	return string.format("local_%d = %d", ins.A, ins.D)
end

namedOutputHandlers[INST.KPRI] = function(ins, ctx)
	local pri = priToString(ins.D)
	ctx.setSlot(ins.A, pri)
	return string.format("local_%d = %s", ins.A, pri)
end

namedOutputHandlers[INST.KNIL] = function(ins, ctx)
	for slot = ins.A, ins.D do
		ctx.setSlot(slot, "nil")
	end
	return string.format("local_%d..local_%d = nil", ins.A, ins.D)
end

namedOutputHandlers[INST.KCDATA] = function(ins, ctx)
	local val = tostring(ctx.consts[-ins.D - 1] or "cdata")
	ctx.setSlot(ins.A, val)
	return string.format("local_%d = %s  -- cdata", ins.A, val)
end

-- Table operations
namedOutputHandlers[INST.TNEW] = function(ins, ctx)
	ctx.setSlot(ins.A, string.format("tbl_%d", ins.A))
	return string.format("tbl_%d = {}", ins.A)
end

namedOutputHandlers[INST.TDUP] = function(ins, ctx)
	local tbl = ctx.consts[-ins.D - 1]
	ctx.setSlot(ins.A, string.format("tbl_%d", ins.A))
	if tbl and type(tbl) == "table" then
		local parts = {}
		for k, v in pairs(tbl) do
			local key = type(k) == "string" and k or string.format("[%s]", tostring(k))
			table.insert(parts, string.format("%s = %s", key, formatValue(v)))
		end
		return string.format("tbl_%d = {%s}", ins.A, table.concat(parts, ", "))
	else
		return string.format("tbl_%d = {...}", ins.A)
	end
end

namedOutputHandlers[INST.TGETS] = function(ins, ctx)
	local key = tostring(ctx.consts[-ins.C - 1] or "?")
	local base = ctx.getSlot(ins.B)
	ctx.setSlot(ins.A, string.format("%s.%s", base, key))
	return string.format("local_%d = %s.%s", ins.A, base, key)
end

namedOutputHandlers[INST.TSETS] = function(ins, ctx)
	local key = tostring(ctx.consts[-ins.C - 1] or "?")
	return string.format("%s.%s = %s", ctx.getSlot(ins.B), key, ctx.getSlot(ins.A))
end

namedOutputHandlers[INST.TGETV] = function(ins, ctx)
	local base = ctx.getSlot(ins.B)
	local index = ctx.getSlot(ins.C)
	ctx.setSlot(ins.A, string.format("%s[%s]", base, index))
	return string.format("local_%d = %s[%s]", ins.A, base, index)
end

namedOutputHandlers[INST.TSETV] = function(ins, ctx) return string.format("%s[%s] = %s", ctx.getSlot(ins.B), ctx.getSlot(ins.C), ctx.getSlot(ins.A)) end
namedOutputHandlers[INST.TGETB] = function(ins, ctx)
	local base = ctx.getSlot(ins.B)
	ctx.setSlot(ins.A, string.format("%s[%d]", base, ins.C))
	return string.format("local_%d = %s[%d]", ins.A, base, ins.C)
end

namedOutputHandlers[INST.TSETB] = function(ins, ctx) return string.format("%s[%d] = %s", ctx.getSlot(ins.B), ins.C, ctx.getSlot(ins.A)) end
-- Arithmetic VN (var op num)
local function makeArithVN(op)
	return function(ins, ctx)
		local num = tostring(ctx.consts[ins.C] or "?")
		return string.format("local_%d = %s %s %s", ins.A, ctx.getSlot(ins.B), op, num)
	end
end

namedOutputHandlers[INST.ADDVN] = makeArithVN("+")
namedOutputHandlers[INST.SUBVN] = makeArithVN("-")
namedOutputHandlers[INST.MULVN] = makeArithVN("*")
namedOutputHandlers[INST.DIVVN] = makeArithVN("/")
namedOutputHandlers[INST.MODVN] = makeArithVN("%")
-- Arithmetic NV (num op var)
local function makeArithNV(op)
	return function(ins, ctx)
		local num = tostring(ctx.consts[ins.C] or "?")
		return string.format("local_%d = %s %s %s", ins.A, num, op, ctx.getSlot(ins.B))
	end
end

namedOutputHandlers[INST.ADDNV] = makeArithNV("+")
namedOutputHandlers[INST.SUBNV] = makeArithNV("-")
namedOutputHandlers[INST.MULNV] = makeArithNV("*")
namedOutputHandlers[INST.DIVNV] = makeArithNV("/")
namedOutputHandlers[INST.MODNV] = makeArithNV("%")
-- Arithmetic VV (var op var)
local function makeArithVV(op)
	return function(ins, ctx) return string.format("local_%d = %s %s %s", ins.A, ctx.getSlot(ins.B), op, ctx.getSlot(ins.C)) end
end

namedOutputHandlers[INST.ADDVV] = makeArithVV("+")
namedOutputHandlers[INST.SUBVV] = makeArithVV("-")
namedOutputHandlers[INST.MULVV] = makeArithVV("*")
namedOutputHandlers[INST.DIVVV] = makeArithVV("/")
namedOutputHandlers[INST.MODVV] = makeArithVV("%")
namedOutputHandlers[INST.POW] = makeArithVV("^")
-- Basic operations
namedOutputHandlers[INST.MOV] = function(ins, ctx)
	local srcName = ctx.getSlot(ins.D)
	ctx.setSlot(ins.A, srcName)
	return string.format("r%d = %s", ins.A, srcName)
end

namedOutputHandlers[INST.NOT] = function(ins, ctx) return string.format("local_%d = not %s", ins.A, ctx.getSlot(ins.D)) end
namedOutputHandlers[INST.UNM] = function(ins, ctx) return string.format("local_%d = -%s", ins.A, ctx.getSlot(ins.D)) end
namedOutputHandlers[INST.LEN] = function(ins, ctx) return string.format("local_%d = #%s", ins.A, ctx.getSlot(ins.D)) end
namedOutputHandlers[INST.CAT] = function(ins, ctx)
	local parts = {}
	for j = ins.B, ins.C do
		table.insert(parts, ctx.getSlot(j))
	end

	local concatExpr = table.concat(parts, " .. ")
	local resultName = string.format("concat_r%d", ins.A)
	ctx.setSlot(ins.A, resultName)
	return string.format("%s = %s", resultName, concatExpr)
end

-- Comparisons
namedOutputHandlers[INST.ISEQS] = function(ins, ctx)
	local str = tostring(ctx.consts[-ins.D - 1] or "?")
	return string.format("if %s == %q then jump", ctx.getSlot(ins.A), str)
end

namedOutputHandlers[INST.ISNES] = function(ins, ctx)
	local str = tostring(ctx.consts[-ins.D - 1] or "?")
	return string.format("if %s ~= %q then jump", ctx.getSlot(ins.A), str)
end

namedOutputHandlers[INST.ISEQN] = function(ins, ctx)
	local num = tostring(ctx.consts[ins.D] or "?")
	return string.format("if %s == %s then jump", ctx.getSlot(ins.A), num)
end

namedOutputHandlers[INST.ISNEN] = function(ins, ctx)
	local num = tostring(ctx.consts[ins.D] or "?")
	return string.format("if %s ~= %s then jump", ctx.getSlot(ins.A), num)
end

namedOutputHandlers[INST.ISEQP] = function(ins, ctx) return string.format("if %s == %s then jump", ctx.getSlot(ins.A), priToString(ins.D)) end
namedOutputHandlers[INST.ISNEP] = function(ins, ctx) return string.format("if %s ~= %s then jump", ctx.getSlot(ins.A), priToString(ins.D)) end
local function makeCompareVV(op)
	return function(ins, ctx) return string.format("if %s %s %s then jump", ctx.getSlot(ins.A), op, ctx.getSlot(ins.D)) end
end

namedOutputHandlers[INST.ISLT] = makeCompareVV("<")
namedOutputHandlers[INST.ISGE] = makeCompareVV(">=")
namedOutputHandlers[INST.ISLE] = makeCompareVV("<=")
namedOutputHandlers[INST.ISGT] = makeCompareVV(">")
namedOutputHandlers[INST.ISEQV] = makeCompareVV("==")
namedOutputHandlers[INST.ISNEV] = makeCompareVV("~=")
-- Conditional copy/test
namedOutputHandlers[INST.ISTC] = function(ins, ctx) return string.format("if %s then local_%d = %s; jump", ctx.getSlot(ins.D), ins.A, ctx.getSlot(ins.D)) end
namedOutputHandlers[INST.ISFC] = function(ins, ctx) return string.format("if not %s then local_%d = %s; jump", ctx.getSlot(ins.D), ins.A, ctx.getSlot(ins.D)) end
namedOutputHandlers[INST.IST] = function(ins, ctx) return string.format("if %s then jump", ctx.getSlot(ins.D)) end
namedOutputHandlers[INST.ISF] = function(ins, ctx) return string.format("if not %s then jump", ctx.getSlot(ins.D)) end
-- Helper to find the correct argument start offset by looking at where args are actually placed
-- Returns the slot offset where real arguments start relative to function slot A
local function getCallArgOffset(ins, ctx)
	-- Walk backwards to find the first MOV/KSHORT/etc that sets up an argument
	-- The slot it writes to tells us where args actually start
	local checkIdx = ctx.i - 1
	local firstArgSlot = nil
	while checkIdx >= 0 do
		local checkIns = ctx.instructions and ctx.instructions[checkIdx]
		if not checkIns then break end
		-- These instructions set up arguments
		if checkIns.OP_CODE == INST.MOV or checkIns.OP_CODE == INST.KSHORT or checkIns.OP_CODE == INST.KNUM or checkIns.OP_CODE == INST.KSTR or checkIns.OP_CODE == INST.KPRI or checkIns.OP_CODE == INST.CAT then
			-- Track the lowest slot used for args (they should be contiguous)
			if not firstArgSlot or checkIns.A < firstArgSlot then firstArgSlot = checkIns.A end
		elseif checkIns.OP_CODE == INST.TGETS or checkIns.OP_CODE == INST.GGET or checkIns.OP_CODE == INST.UGET then
			-- Hit the function/table load, stop looking
			break
		else
			-- Hit something else, stop
			break
		end

		checkIdx = checkIdx - 1
	end

	-- Calculate offset based on where args actually are
	if firstArgSlot then
		local offset = firstArgSlot - ins.A
		if offset >= 1 then return offset end
	end
	return 1 -- Default: args start at A+1
end

-- Calls
namedOutputHandlers[INST.CALL] = function(ins, ctx)
	local nargs, nrets = ins.C - 1, ins.B - 1
	local funcName = ctx.getSlot(ins.A)
	local args = {}
	local argOffset = getCallArgOffset(ins, ctx)
	-- Read nargs slots starting from A + argOffset
	for j = 0, nargs - 1 do
		table.insert(args, ctx.getSlot(ins.A + argOffset + j))
	end

	local argsStr = table.concat(args, ", ")
	if nrets == 0 then
		return string.format("%s(%s)", funcName, argsStr)
	elseif nrets == 1 then
		local resultName = string.format("result_%d", ctx.i)
		ctx.setSlot(ins.A, resultName)
		return string.format("%s = %s(%s)", resultName, funcName, argsStr)
	else
		for j = 0, nrets - 1 do
			ctx.setSlot(ins.A + j, string.format("result_%d_%d", ctx.i, j))
		end
		return string.format("result_%d_0..result_%d_%d = %s(%s)", ctx.i, ctx.i, nrets - 1, funcName, argsStr)
	end
end

namedOutputHandlers[INST.CALLM] = function(ins, ctx)
	local funcName = ctx.getSlot(ins.A)
	local args = {}
	local argOffset = getCallArgOffset(ins, ctx)
	for j = 0, ins.C - 1 do
		table.insert(args, ctx.getSlot(ins.A + argOffset + j))
	end

	table.insert(args, "...")
	ctx.setSlot(ins.A, string.format("result_%d", ctx.i))
	return string.format("result_%d = %s(%s)", ctx.i, funcName, table.concat(args, ", "))
end

namedOutputHandlers[INST.CALLT] = function(ins, ctx)
	local funcName = ctx.getSlot(ins.A)
	local args = {}
	local nargs = ins.D - 1
	local argOffset = getCallArgOffset(ins, ctx)
	-- Read nargs slots starting from A + argOffset
	for j = 0, nargs - 1 do
		table.insert(args, ctx.getSlot(ins.A + argOffset + j))
	end
	return string.format("return %s(%s)", funcName, table.concat(args, ", "))
end

namedOutputHandlers[INST.CALLMT] = function(ins, ctx) return string.format("return %s(...)", ctx.getSlot(ins.A)) end
-- Returns
namedOutputHandlers[INST.RET0] = function() return "return" end
namedOutputHandlers[INST.RET1] = function(ins, ctx) return string.format("return %s", ctx.getSlot(ins.A)) end
namedOutputHandlers[INST.RET] = function(ins, ctx)
	local nrets = ins.D - 1
	if nrets == 0 then
		return "return"
	else
		local rets = {}
		for j = 0, nrets - 1 do
			table.insert(rets, ctx.getSlot(ins.A + j))
		end
		return string.format("return %s", table.concat(rets, ", "))
	end
end

namedOutputHandlers[INST.RETM] = function(ins, ctx) return string.format("return %s, ...", ctx.getSlot(ins.A)) end
-- Loops
local function handleForInit(ins, ctx)
	return string.format("for local_%d = %s, %s, %s do", ins.A + 3, ctx.getSlot(ins.A), ctx.getSlot(ins.A + 1), ctx.getSlot(ins.A + 2))
end

namedOutputHandlers[INST.FORI] = handleForInit
namedOutputHandlers[INST.JFORI] = handleForInit
local function handleForEnd()
	return "end  -- for"
end

namedOutputHandlers[INST.FORL] = handleForEnd
namedOutputHandlers[INST.IFORL] = handleForEnd
namedOutputHandlers[INST.JFORL] = handleForEnd
local function handleIterEnd()
	return "end  -- iterator"
end

namedOutputHandlers[INST.ITERL] = handleIterEnd
namedOutputHandlers[INST.IITERL] = handleIterEnd
namedOutputHandlers[INST.JITERL] = handleIterEnd
local function handleIterCall(ins, ctx)
	return string.format("local_%d, ... = %s(%s, %s)", ins.A, ctx.getSlot(ins.A - 3), ctx.getSlot(ins.A - 2), ctx.getSlot(ins.A - 1))
end

namedOutputHandlers[INST.ITERC] = handleIterCall
namedOutputHandlers[INST.ITERN] = handleIterCall
local function handleLoop()
	return "-- loop"
end

namedOutputHandlers[INST.LOOP] = handleLoop
namedOutputHandlers[INST.ILOOP] = handleLoop
namedOutputHandlers[INST.JLOOP] = handleLoop
namedOutputHandlers[INST.ISNEXT] = function() return "-- verify ITERN" end
-- Jump
namedOutputHandlers[INST.JMP] = function(ins) return string.format("goto %d", ins.D) end
-- Closure
namedOutputHandlers[INST.FNEW] = function(ins, ctx)
	local proto = ctx.consts[-ins.D - 1]
	ctx.setSlot(ins.A, string.format("func_%d", ins.A))
	return string.format("func_%d = function(...)  -- %s", ins.A, tostring(proto))
end

-- Upvalue close
namedOutputHandlers[INST.UCLO] = function(ins) return string.format("-- close upvalues >= %d, goto %d", ins.A, ins.D) end
-- Vararg
namedOutputHandlers[INST.VARG] = function(ins)
	local nrets = ins.B - 1
	if nrets < 0 then
		return string.format("local_%d... = ...", ins.A)
	else
		return string.format("local_%d..local_%d = ...", ins.A, ins.A + nrets - 1)
	end
end

-- Generate human-readable decompiled output with upvalues visible
local function generate_named_output(data, formatter)
	local slotNames = {}
	local output = {}
	local consts = data.consts
	local upvalues = data.upvalues
	local upvalueValues = data.upvalueValues or {}
	local paramNames = data.paramNames or {}
	local instructions = data.instructions
	local info = data.info or {}
	local function getSlot(idx)
		return slotNames[idx] or string.format("r%d", idx)
	end

	local function setSlot(idx, name)
		slotNames[idx] = name
	end

	-- Initialize parameter names immediately (before processing any instructions)
	local numParams = info.params or 0
	for i = 0, numParams - 1 do
		local name = paramNames[i] or string.format("arg%d", i)
		setSlot(i, name)
	end

	-- Build upvalue output entries (to be inserted after function header)
	local upvalueEntries = {}
	local upvalueCount = 0
	for _ in pairs(upvalues) do
		upvalueCount = upvalueCount + 1
	end

	if upvalueCount > 0 then
		local sortedUvIndices = {}
		for idx in pairs(upvalues) do
			table.insert(sortedUvIndices, idx)
		end

		table.sort(sortedUvIndices)
		for _, idx in ipairs(sortedUvIndices) do
			local value = upvalueValues[idx]
			local formattedValue
			if formatter then
				formattedValue = formatter(value)
			else
				formattedValue = tostring(value)
			end

			table.insert(upvalueEntries, {
				line = 0,
				code = string.format("    -- upvalue[%d] = %s = %s", idx, upvalues[idx], formattedValue),
				op = "UPVALUE"
			})
		end
	end

	-- Sort instruction indices to process in order (important for slot tracking)
	local sortedIndices = {}
	for i in pairs(instructions) do
		if type(i) == "number" then table.insert(sortedIndices, i) end
	end

	table.sort(sortedIndices)
	-- Context object passed to handlers
	local ctx = {
		getSlot = getSlot,
		setSlot = setSlot,
		consts = consts,
		upvalues = upvalues,
		info = info,
		instructions = instructions,
		i = 0
	}

	for _, i in ipairs(sortedIndices) do
		local ins = instructions[i]
		if ins then
			local op = ins.OP_CODE
			ctx.i = i
			-- Use dispatch table, fall back to ins.DO or unknown
			local handler = namedOutputHandlers[op]
			local line
			if handler then
				line = handler(ins, ctx)
			else
				line = ins.DO or string.format("-- %s (unhandled)", OPNAMES[op] or "UNKNOWN")
			end

			ins.DO_NAMED = line
			table.insert(output, {
				index = i,
				line = ins.line,
				code = line,
				op = OPNAMES[op]
			})

			-- Insert upvalue entries right after function header (index 0)
			if i == 0 and #upvalueEntries > 0 then
				for _, uvEntry in ipairs(upvalueEntries) do
					uvEntry.index = i
					table.insert(output, uvEntry)
				end
			end
		end
	end
	return output, slotNames, upvalues
end

-- Check if function has any JIT instructions
local function hasJITInstruction(fn)
	local countBC = jit.util.funcinfo(fn).bytecodes
	for n = 1, countBC - 1 do
		local ins = bit.band(jit.util.funcbc(fn, n), 0xFF)
		if JIT_INST[ins] then return true end
	end
	return false
end

-- Calculate JIT compatibility level (percentage)
local function JITLevel(fn)
	local countBC = jit.util.funcinfo(fn).bytecodes
	local countNonJITable = 0
	for n = 1, countBC - 1 do
		local ins = bit.band(jit.util.funcbc(fn, n), 0xFF)
		if JIT_INCOMPATIBLE_INS[ins] then countNonJITable = countNonJITable + 1 end
	end
	return (countBC - countNonJITable) / countBC * 100
end

-- Find all global function declarations in a function
local function get_non_local_function_declarations(fn, recursive)
	assert(fn, "function expected")
	local symbols = {}
	local data = disassemble_function(fn, true)
	local count = 0
	for _ in pairs(data.instructions) do
		count = count + 1
	end

	for pos = 1, count - 1 do
		local curIns = data.instructions[pos]
		if curIns and curIns.OP_CODE == INST.FNEW then
			local _proto = jit.util.funcinfo(data.consts[-curIns.D - 1])
			local location = {
				_start = _proto.linedefined,
				_end = _proto.lastlinedefined
			}

			local fName
			local nextIns = data.instructions[pos + 1]
			if nextIns then
				if nextIns.OP_CODE == INST.GSET then
					fName = data.consts[-nextIns.D - 1]
				elseif nextIns.OP_CODE == INST.TSETS then
					fName = data.consts[-nextIns.C - 1]
					local modifier = -1
					local previousIns = data.instructions[pos + modifier]
					local endOfDecl = false
					while previousIns do
						if previousIns.OP_CODE == INST.TGETS then
							fName = data.consts[-previousIns.C - 1] .. "." .. fName
						elseif previousIns.OP_CODE == INST.GGET then
							fName = data.consts[-previousIns.D - 1] .. "." .. fName
							endOfDecl = true
							break
						else
							fName = nil
							break
						end

						modifier = modifier - 1
						previousIns = data.instructions[pos + modifier]
					end

					if not endOfDecl then fName = nil end
				end
			end

			if fName then
				location.name = fName
				table.insert(symbols, location)
			end

			if recursive then
				local func = data.consts[-curIns.D - 1]
				if jit.util.funcinfo(func).children then
					for _, sub in ipairs(get_non_local_function_declarations(func, true)) do
						table.insert(symbols, sub)
					end
				end
			end
		end
	end
	return symbols
end

-- Find all global function calls in a function
local function get_non_local_function_call(fn, recursive)
	assert(fn, "function expected")
	local calls = {}
	local debugData = jit.util.funcinfo(fn)
	local data = disassemble_function(fn, true)
	local count = 0
	for _ in pairs(data.instructions) do
		count = count + 1
	end

	for pos = 1, count - 1 do
		local curIns = data.instructions[pos]
		if curIns and curIns.OP_CODE == INST.CALL then
			local fName
			local prevIns = data.instructions[pos - 1]
			if prevIns then
				if prevIns.OP_CODE == INST.GGET then
					fName = data.consts[-prevIns.D - 1]
				elseif prevIns.OP_CODE == INST.TGETS then
					fName = data.consts[-prevIns.C - 1]
					local modifier = -2
					local previousIns = data.instructions[pos + modifier]
					local endOfDecl = false
					while previousIns do
						if previousIns.OP_CODE == INST.TGETS then
							fName = data.consts[-previousIns.C - 1] .. "." .. fName
						elseif previousIns.OP_CODE == INST.GGET then
							fName = data.consts[-previousIns.D - 1] .. "." .. fName
							endOfDecl = true
							break
						else
							fName = nil
							break
						end

						modifier = modifier - 1
						previousIns = data.instructions[pos + modifier]
					end

					if not endOfDecl then fName = nil end
				end
			end

			if fName then
				local twoDot = debugData.loc:find(":")
				local loc = twoDot and debugData.loc:sub(1, twoDot - 1) or debugData.loc
				table.insert(calls, {
					name = fName,
					_start = debugData.linedefined,
					_end = debugData.lastlinedefined,
					file = loc
				})
			end

			if recursive and jit.util.funcinfo(fn).children then
				for _, v in pairs(data.consts) do
					if type(v) == "proto" then
						for _, sub in ipairs(get_non_local_function_call(v, true)) do
							table.insert(calls, sub)
						end
					end
				end
			end
		end
	end
	return calls
end

-- File-level helpers
local function fileGetSymbols(path, recursive)
	assert(path, "path expected")
	local func = loadfile(path)
	if not func then return {} end
	if not jit.util.funcinfo(func).children then return {} end
	local ret = get_non_local_function_declarations(func, recursive)
	local loc = jit.util.funcinfo(func).loc
	local twoDot = loc:find(":")
	if twoDot then loc = loc:sub(1, twoDot - 1) end
	return ret, loc
end

local function fileGetGlobalCalls(path, recursive)
	assert(path, "path expected")
	local func = loadfile(path)
	if not func then return {} end
	return get_non_local_function_call(func, recursive)
end

local function findLocalizableFunctions(files)
	local declarations = {}
	for _, file in ipairs(files) do
		local reportDeclarations, location = fileGetSymbols(file, true)
		for _, funcData in ipairs(reportDeclarations) do
			if not declarations[funcData.name] then
				declarations[funcData.name] = {
					file = location,
					_start = funcData._start,
					_end = funcData._end
				}
			end
		end
	end

	for _, file in ipairs(files) do
		local reportCalls = fileGetGlobalCalls(file, true)
		for _, funcData in ipairs(reportCalls) do
			if declarations[funcData.name] and declarations[funcData.name].file ~= funcData.file then
				declarations[funcData.name] = nil
			elseif declarations[funcData.name] then
				declarations[funcData.name].localCalled = true
			end
		end
	end

	for k, v in pairs(declarations) do
		if not v.localCalled then
			declarations[k] = nil
		else
			v.localCalled = nil
		end
	end
	return declarations
end

-- Export module
jit.decompiler = {
	disassemble = disassemble_function,
	generate_named_output = generate_named_output,
	has_JIT_instruction = hasJITInstruction,
	get_JIT_level = JITLevel,
	get_function_declarations = get_non_local_function_declarations,
	get_function_calls = get_non_local_function_call,
	files = {
		getSymbols = fileGetSymbols,
		getGlobalCalls = fileGetGlobalCalls,
		findLocalizableFunctions = findLocalizableFunctions
	},
	-- Internal constants for advanced use
	INST = INST,
	OPNAMES = OPNAMES,
	BCMode = BCMode
}