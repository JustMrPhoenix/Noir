-- jit_decompiler2 — LuaJIT 2.1 bytecode decompiler.
--
-- Reconstructs readable pseudo-Lua from a function's bytecode; used by Noir
-- when a function's source is unavailable (RunString'd chunks, stripped code).
-- Everything is read from string.dump(fn): bytecode, constants (including
-- table templates and child prototypes) and, when present, the debug section
-- with real local-variable names. No jit.util dependency — GMod disables
-- jit.util.funck, and the dump has strictly more information anyway.
--
-- Public API (all function-taking entry points return nil, err on failure):
--   parse(fn) / parseDump(str)  -> proto-tree IR (see parseDump for shape)
--   disassemble(fn, opts)       -> annotated listing string
--   decompile(fn, opts)         -> pseudo-Lua string (falls back to listing)
--   metadata(fn)                -> {stringConsts, upvalueNames, upvalueValues, paramNames}
--   getFunctionDeclarations / getFunctionCalls / files.*  -> symbol scanning
--
-- Supports both FR2 (GC64, GMod x86-64) and non-FR2 dumps; the frame layout
-- is read from the dump header flags.

local bit = _G.bit or require("bit")
local band = bit.band
local strbyte, strsub, strfmt = string.byte, string.sub, string.format
local concat = table.concat
local floor, huge = math.floor, math.huge

local M = {}

--------------------------------------------------------------------------------
-- Opcode tables (LuaJIT 2.1: includes ISTYPE/ISNUM and TGETR/TSETR)
--------------------------------------------------------------------------------

local BCNAMES = "ISLT  ISGE  ISLE  ISGT  ISEQV ISNEV ISEQS ISNES ISEQN ISNEN ISEQP ISNEP ISTC  ISFC  IST   ISF   ISTYPEISNUM MOV   NOT   UNM   LEN   ADDVN SUBVN MULVN DIVVN MODVN ADDNV SUBNV MULNV DIVNV MODNV ADDVV SUBVV MULVV DIVVV MODVV POW   CAT   KSTR  KCDATAKSHORTKNUM  KPRI  KNIL  UGET  USETV USETS USETN USETP UCLO  FNEW  TNEW  TDUP  GGET  GSET  TGETV TGETS TGETB TGETR TSETV TSETS TSETB TSETM TSETR CALLM CALL  CALLMTCALLT ITERC ITERN VARG  ISNEXTRETM  RET   RET0  RET1  FORI  JFORI FORL  IFORL JFORL ITERL IITERLJITERLLOOP  ILOOP JLOOP JMP   FUNCF IFUNCFJFUNCFFUNCV IFUNCVJFUNCVFUNCC FUNCCW"

local OPNAMES, INST = {}, {}
do
	local i = 0
	for name in BCNAMES:gmatch("......") do
		name = name:gsub("%s+$", "")
		OPNAMES[i] = name
		INST[name] = i
		i = i + 1
	end
end

-- Operand layout per opcode: "a,d" entries are AD-format, "a,b,c" are ABC.
-- Mode names follow lj_bc.h: dst/var/base/rbase (slots), uv, lit/lits, pri,
-- num/str/tab/func/cdata (constant indices), jump, none.
local OPMODE_SPEC = {
	ISLT = "var,var", ISGE = "var,var", ISLE = "var,var", ISGT = "var,var",
	ISEQV = "var,var", ISNEV = "var,var", ISEQS = "var,str", ISNES = "var,str",
	ISEQN = "var,num", ISNEN = "var,num", ISEQP = "var,pri", ISNEP = "var,pri",
	ISTC = "dst,var", ISFC = "dst,var", IST = "none,var", ISF = "none,var",
	ISTYPE = "var,lit", ISNUM = "var,lit",
	MOV = "dst,var", NOT = "dst,var", UNM = "dst,var", LEN = "dst,var",
	ADDVN = "dst,var,num", SUBVN = "dst,var,num", MULVN = "dst,var,num", DIVVN = "dst,var,num", MODVN = "dst,var,num",
	ADDNV = "dst,var,num", SUBNV = "dst,var,num", MULNV = "dst,var,num", DIVNV = "dst,var,num", MODNV = "dst,var,num",
	ADDVV = "dst,var,var", SUBVV = "dst,var,var", MULVV = "dst,var,var", DIVVV = "dst,var,var", MODVV = "dst,var,var",
	POW = "dst,var,var", CAT = "dst,rbase,rbase",
	KSTR = "dst,str", KCDATA = "dst,cdata", KSHORT = "dst,lits", KNUM = "dst,num", KPRI = "dst,pri", KNIL = "base,base",
	UGET = "dst,uv", USETV = "uv,var", USETS = "uv,str", USETN = "uv,num", USETP = "uv,pri",
	UCLO = "rbase,jump", FNEW = "dst,func",
	TNEW = "dst,lit", TDUP = "dst,tab", GGET = "dst,str", GSET = "var,str",
	TGETV = "dst,var,var", TGETS = "dst,var,str", TGETB = "dst,var,lit", TGETR = "dst,var,var",
	TSETV = "var,var,var", TSETS = "var,var,str", TSETB = "var,var,lit", TSETR = "var,var,var",
	TSETM = "base,num",
	CALLM = "base,lit,lit", CALL = "base,lit,lit", CALLMT = "base,lit", CALLT = "base,lit",
	ITERC = "base,lit,lit", ITERN = "base,lit,lit", VARG = "base,lit,lit", ISNEXT = "base,jump",
	RETM = "base,lit", RET = "rbase,lit", RET0 = "rbase,lit", RET1 = "rbase,lit",
	FORI = "base,jump", JFORI = "base,jump", FORL = "base,jump", IFORL = "base,jump", JFORL = "base,lit",
	ITERL = "base,jump", IITERL = "base,jump", JITERL = "base,lit",
	LOOP = "rbase,jump", ILOOP = "rbase,jump", JLOOP = "rbase,lit", JMP = "rbase,jump",
	FUNCF = "rbase", IFUNCF = "rbase", JFUNCF = "rbase,lit",
	FUNCV = "rbase", IFUNCV = "rbase", JFUNCV = "rbase,lit",
	FUNCC = "rbase", FUNCCW = "rbase",
}

-- OPMODE[op] = {a=, b=, c=, d=} (b/c nil for AD-format ops).
local OPMODE = {}
for i = 0, #OPNAMES do
	local spec = OPMODE_SPEC[OPNAMES[i]]
	assert(spec, "missing operand spec for " .. OPNAMES[i])
	local parts = {}
	for part in spec:gmatch("[^,]+") do parts[#parts + 1] = part end
	if #parts == 3 then
		OPMODE[i] = { a = parts[1], b = parts[2], c = parts[3] }
	else
		OPMODE[i] = { a = parts[1], d = parts[2] }
	end
end

--------------------------------------------------------------------------------
-- Dump format constants (lj_bcdump.h)
--------------------------------------------------------------------------------

local BCDUMP_VERSION = 2
local BCDUMP_F_BE = 0x01
local BCDUMP_F_STRIP = 0x02
local BCDUMP_F_FR2 = 0x08

local BCDUMP_KGC_CHILD = 0
local BCDUMP_KGC_TAB = 1
local BCDUMP_KGC_I64 = 2
local BCDUMP_KGC_U64 = 3
local BCDUMP_KGC_COMPLEX = 4
local BCDUMP_KGC_STR = 5

local BCDUMP_KTAB_FALSE = 1
local BCDUMP_KTAB_TRUE = 2
local BCDUMP_KTAB_INT = 3
local BCDUMP_KTAB_NUM = 4
local BCDUMP_KTAB_STR = 5

local PROTO_VARARG = 0x02

-- Internal variable names in the debug varinfo stream (lj_debug.h VARNAME_*).
local VARNAME_BUILTIN = {
	[1] = "(for index)", [2] = "(for limit)", [3] = "(for step)",
	[4] = "(for generator)", [5] = "(for state)", [6] = "(for control)",
}
local VARNAME_MAX = 7

--------------------------------------------------------------------------------
-- Byte reader: bounds-checked cursor over the dump string
--------------------------------------------------------------------------------

local function rdError(rd, msg)
	error(strfmt("%s at byte %d/%d", msg, rd.pos, #rd.data), 0)
end

local function rdByte(rd)
	local pos = rd.pos
	if pos > #rd.data then rdError(rd, "dump truncated") end
	rd.pos = pos + 1
	return strbyte(rd.data, pos)
end

local function rdBytes(rd, n)
	local pos = rd.pos
	if pos + n - 1 > #rd.data then rdError(rd, "dump truncated") end
	rd.pos = pos + n
	return strsub(rd.data, pos, pos + n - 1)
end

-- ULEB128 up to a full unsigned 32-bit value. Plain float math keeps values
-- past 31 bits exact (doubles hold 53 mantissa bits), where bit.* would wrap.
local function rdUleb(rd)
	local result, mul = 0, 1
	repeat
		local b = rdByte(rd)
		result = result + (b % 128) * mul
		mul = mul * 128
	until b < 128
	return result
end

-- LuaJIT's 33-bit ULEB128 for number constants: the LSB of the first byte is
-- an is-number flag, so the first byte contributes only 6 value bits.
-- Returns value, isnum.
local function rdUleb33(rd)
	local b = rdByte(rd)
	local isnum = b % 2
	local v = floor(b / 2)
	if v >= 0x40 then
		v = v % 0x40
		local mul = 0x40
		repeat
			b = rdByte(rd)
			v = v + (b % 128) * mul
			mul = mul * 128
		until b < 128
	end
	return v, isnum
end

-- NUL-terminated string starting at the current position.
local function rdZString(rd)
	local data, pos = rd.data, rd.pos
	local zero = data:find("\0", pos, true)
	if not zero then rdError(rd, "unterminated string") end
	rd.pos = zero + 1
	return strsub(data, pos, zero - 1)
end

-- Reconstruct an IEEE-754 double from its two 32-bit halves.
local function doubleFromWords(lo, hi)
	local sign = 1
	if hi >= 0x80000000 then
		sign = -1
		hi = hi - 0x80000000
	end
	local exponent = floor(hi / 0x100000)
	local mantissa = (hi % 0x100000) * 4294967296 + lo
	if exponent == 0 then
		if mantissa == 0 then return sign * 0 end
		return sign * mantissa * 2 ^ -1074 -- subnormal
	elseif exponent == 2047 then
		if mantissa == 0 then return sign * huge end
		return 0 / 0
	end
	return sign * (1 + mantissa / 4503599627370496) * 2 ^ (exponent - 1023)
end

local function rdKnumValue(rd)
	local lo, isnum = rdUleb33(rd)
	if isnum == 1 then
		return doubleFromWords(lo, rdUleb(rd))
	end
	-- 32-bit signed integer
	if lo >= 0x80000000 then lo = lo - 4294967296 end
	return lo
end

--------------------------------------------------------------------------------
-- Dump parser: string.dump blob -> proto tree
--------------------------------------------------------------------------------

-- Template-table constant (TDUP): array part then hash part.
local function rdKtabk(rd)
	local t = rdUleb(rd)
	if t >= BCDUMP_KTAB_STR then
		return rdBytes(rd, t - BCDUMP_KTAB_STR)
	elseif t == BCDUMP_KTAB_INT then
		local v = rdUleb(rd)
		if v >= 0x80000000 then v = v - 4294967296 end
		return v
	elseif t == BCDUMP_KTAB_NUM then
		return doubleFromWords(rdUleb(rd), rdUleb(rd))
	elseif t == BCDUMP_KTAB_TRUE then
		return true
	elseif t == BCDUMP_KTAB_FALSE then
		return false
	end
	return nil -- BCDUMP_KTAB_NIL
end

local function rdKtab(rd)
	local narray, nhash = rdUleb(rd), rdUleb(rd)
	local tab = {}
	for i = 0, narray - 1 do
		tab[i] = rdKtabk(rd) -- array part is 0-based in the dump; [0] is normally nil
	end
	for _ = 1, nhash do
		local k = rdKtabk(rd)
		tab[k] = rdKtabk(rd)
	end
	return tab
end

-- Debug varinfo stream -> list of {name, startpc, endpc} in declaration order.
-- pc values here use the same base as instruction indices (1-based, pc 0 would
-- be the omitted FUNC* header), matching lj_debug.c's BCPos.
local function rdVarinfo(rd, endPos)
	local vars = {}
	local lastpc = 0
	while rd.pos < endPos do
		local b = strbyte(rd.data, rd.pos)
		local name
		if b < VARNAME_MAX then
			rd.pos = rd.pos + 1
			if b == 0 then break end -- VARNAME_END
			name = VARNAME_BUILTIN[b]
		else
			name = rdZString(rd)
		end
		local startpc = lastpc + rdUleb(rd)
		lastpc = startpc
		vars[#vars + 1] = { name = name, startpc = startpc, endpc = startpc + rdUleb(rd) }
	end
	return vars
end

-- Look up the name of `slot` (0-based) at instruction `pc` (1-based), the same
-- walk lj_debug.c's debug_varname does: active variables at a pc occupy slots
-- 0..n in declaration order.
local function varnameAt(proto, pc, slot)
	local vars = proto.varinfo
	if not vars then return nil end
	-- Memoize per proto, keyed by (pc, slot). varnameAt is called per-slot ×
	-- per-instruction × per-recognizer-attempt, and each call linear-scans the WHOLE
	-- varinfo -- the dominant decompile cost on large functions (PAC3 text.OnDraw: 1028
	-- instructions, dozens of active locals, took >60s and tripped the corpus watchdog).
	-- Protos are immutable after parse, so the cache is sound; `false` marks a cached miss.
	local cache = proto._varnameCache
	if not cache then cache = {} proto._varnameCache = cache end
	local row = cache[pc]
	if row then
		local hit = row[slot]
		if hit ~= nil then
			if hit == false then return nil end
			return hit.name, hit
		end
	else
		row = {} cache[pc] = row
	end
	local origSlot = slot
	for i = 1, #vars do
		local v = vars[i]
		if v.startpc > pc then break end
		if pc < v.endpc then
			if slot == 0 then row[origSlot] = v return v.name, v end
			slot = slot - 1
		end
	end
	row[origSlot] = false
	return nil
end

-- One prototype block. `children` is the stack of already-parsed protos
-- (LuaJIT dumps protos depth-first, parents referencing children by popping).
local function rdProto(rd, hdr, plen, children)
	local endPos = rd.pos + plen
	local proto = {
		flags = rdByte(rd),
		numparams = rdByte(rd),
		framesize = rdByte(rd),
	}
	proto.isvararg = band(proto.flags, PROTO_VARARG) ~= 0
	local numuv = rdByte(rd)
	local numkgc = rdUleb(rd)
	local numkn = rdUleb(rd)
	local numbc = rdUleb(rd)
	proto.numuv = numuv

	local debuglen = 0
	if not hdr.stripped then
		debuglen = rdUleb(rd)
		if debuglen > 0 then
			proto.firstline = rdUleb(rd)
			proto.numline = rdUleb(rd)
		end
	end

	-- Bytecode: numbc 32-bit little-endian words; the FUNC* header is omitted
	-- from dumps, so ins[i] corresponds to jit.util.funcbc pc == i.
	local ins = {}
	local data, pos = rd.data, rd.pos
	if pos + numbc * 4 - 1 > #data then rdError(rd, "dump truncated (bytecode)") end
	for i = 1, numbc do
		local op, a, cLo, bHi = strbyte(data, pos, pos + 3)
		local d = cLo + bHi * 256
		local rec = { op = op, a = a, b = bHi, c = cLo, d = d }
		local mode = OPMODE[op]
		if not mode then rdError(rd, "unknown opcode " .. op) end
		if mode.d == "jump" then
			rec.j = i + 1 + (d - 0x8000)
		end
		ins[i] = rec
		pos = pos + 4
	end
	rd.pos = pos
	proto.ins = ins

	-- Upvalue references: u16 each. High bit set = parent *local* slot
	-- (bit 0x4000 = immutable); otherwise an index into the parent's upvalues.
	local uv = {}
	for i = 0, numuv - 1 do
		local lo, hi = strbyte(data, rd.pos, rd.pos + 1)
		if not hi then rdError(rd, "dump truncated (upvalues)") end
		rd.pos = rd.pos + 2
		local v = lo + hi * 256
		if v >= 0x8000 then
			uv[i] = { inParent = false, slot = v % 0x4000, immutable = band(v, 0x4000) ~= 0 }
		else
			uv[i] = { inParent = true, uvIndex = v }
		end
	end
	proto.uv = uv

	-- GC constants are written low-slot-first, but bytecode indexes them from
	-- the top: operand index N -> the (numkgc-N)-th entry read here.
	local gcList = {}
	for i = 1, numkgc do
		local t = rdUleb(rd)
		if t >= BCDUMP_KGC_STR then
			gcList[i] = { type = "str", value = rdBytes(rd, t - BCDUMP_KGC_STR) }
		elseif t == BCDUMP_KGC_TAB then
			gcList[i] = { type = "tab", value = rdKtab(rd) }
		elseif t == BCDUMP_KGC_CHILD then
			local child = children[#children]
			if not child then rdError(rd, "child proto underflow") end
			children[#children] = nil
			child.parent = proto
			gcList[i] = { type = "child", proto = child }
		elseif t == BCDUMP_KGC_I64 or t == BCDUMP_KGC_U64 then
			local lo, hi = rdUleb(rd), rdUleb(rd)
			gcList[i] = { type = t == BCDUMP_KGC_I64 and "i64" or "u64", lo = lo, hi = hi }
		elseif t == BCDUMP_KGC_COMPLEX then
			gcList[i] = { type = "complex", rlo = rdUleb(rd), rhi = rdUleb(rd), ilo = rdUleb(rd), ihi = rdUleb(rd) }
		else
			rdError(rd, "unknown kgc type " .. t)
		end
	end
	local kgc = {}
	for i = 1, numkgc do
		kgc[i - 1] = gcList[numkgc - i + 1]
	end
	proto.kgc = kgc
	proto.numkgc = numkgc

	local knum = {}
	for i = 0, numkn - 1 do
		knum[i] = rdKnumValue(rd)
	end
	proto.knum = knum

	-- Debug section: line map, upvalue names, varinfo.
	if debuglen > 0 then
		local dbgEnd = rd.pos + debuglen
		local numline = proto.numline
		local width = numline < 256 and 1 or numline < 65536 and 2 or 4
		local lines = {}
		local first = proto.firstline
		for i = 1, numbc do
			local v
			if width == 1 then
				v = rdByte(rd)
			elseif width == 2 then
				local lo, hi = strbyte(data, rd.pos, rd.pos + 1)
				rd.pos = rd.pos + 2
				v = lo + hi * 256
			else
				local b1, b2, b3, b4 = strbyte(data, rd.pos, rd.pos + 3)
				rd.pos = rd.pos + 4
				v = b1 + b2 * 0x100 + b3 * 0x10000 + b4 * 0x1000000
			end
			lines[i] = first + v
		end
		proto.lines = lines

		local uvnames = {}
		for i = 0, numuv - 1 do
			uvnames[i] = rdZString(rd)
		end
		proto.uvnames = uvnames

		proto.varinfo = rdVarinfo(rd, dbgEnd)
		if rd.pos ~= dbgEnd then rd.pos = dbgEnd end
	end

	if rd.pos ~= endPos then
		rdError(rd, strfmt("proto length mismatch (expected end %d)", endPos))
	end
	return proto
end

-- Parse a raw string.dump blob. Returns:
--   {
--     version, fr2 = 0|1, stripped = bool, chunkname = string|nil,
--     root = proto, protos = { all protos, root last },
--   }
-- proto = {
--   numparams, framesize, numuv, flags, isvararg,
--   ins = { {op,a,b,c,d, j=jumpTarget?} ... },          -- 1-based pc
--   uv = { [0]={inParent=, slot=/uvIndex=, immutable=} },
--   kgc = { [0]={type="str"/"tab"/"child"/"i64"/"u64"/"complex", ...} },
--   knum = { [0]=number },
--   -- only when the dump has debug info:
--   firstline, numline, lines = {[pc]=line},
--   uvnames = {[0]=name}, varinfo = { {name,startpc,endpc} declaration-order },
-- }
function M.parseDump(dump)
	local rd = { data = dump, pos = 1 }
	if rdBytes(rd, 3) ~= "\27LJ" then
		error("not a LuaJIT bytecode dump", 0)
	end
	local hdr = { version = rdByte(rd) }
	if hdr.version ~= BCDUMP_VERSION then
		error("unsupported bytecode dump version " .. hdr.version, 0)
	end
	local flags = rdUleb(rd)
	if band(flags, BCDUMP_F_BE) ~= 0 then
		error("big-endian dumps are not supported", 0)
	end
	hdr.flags = flags
	hdr.fr2 = band(flags, BCDUMP_F_FR2) ~= 0 and 1 or 0
	hdr.stripped = band(flags, BCDUMP_F_STRIP) ~= 0
	if not hdr.stripped then
		local namelen = rdUleb(rd)
		if namelen > 0 then hdr.chunkname = rdBytes(rd, namelen) end
	end

	-- Protos come depth-first, root last, terminated by a zero length.
	local stack = {}
	local all = {}
	while true do
		if rd.pos > #dump then break end
		local plen = rdUleb(rd)
		if plen == 0 then break end
		local proto = rdProto(rd, hdr, plen, stack)
		stack[#stack + 1] = proto
		all[#all + 1] = proto
	end
	if #stack ~= 1 then
		error(strfmt("malformed dump: %d unconsumed prototypes", #stack), 0)
	end
	hdr.root = stack[1]
	hdr.protos = all
	return hdr
end

--------------------------------------------------------------------------------
-- Caches and function-level entry points
--------------------------------------------------------------------------------

local parseCache = setmetatable({}, { __mode = "k" })
local metadataCache = setmetatable({}, { __mode = "k" })

local function dumpOf(fn)
	if type(fn) ~= "function" then return nil, "expected a function" end
	local ok, dump = pcall(string.dump, fn)
	if not ok then return nil, "cannot dump: " .. tostring(dump) end
	return dump
end

-- Parse a live function (cached). Augments the root proto with what only the
-- live closure knows: upvalue values and debug.* fallbacks for stripped dumps.
function M.parse(fn)
	local cached = parseCache[fn]
	if cached then return cached end
	local dump, err = dumpOf(fn)
	if not dump then return nil, err end
	local ok, parsed = pcall(M.parseDump, dump)
	if not ok then return nil, tostring(parsed) end

	local root = parsed.root
	local upvalueValues, uvnames = {}, root.uvnames
	local needNames = uvnames == nil
	if needNames then uvnames = {} end
	for i = 1, root.numuv do
		local name, value = debug.getupvalue(fn, i)
		if name == nil then break end
		upvalueValues[i - 1] = value
		if needNames then uvnames[i - 1] = name ~= "" and name or nil end
	end
	root.uvnames = uvnames
	root.upvalueValues = upvalueValues

	local info = debug.getinfo(fn, "S")
	parsed.source = info.source
	parsed.linedefined = info.linedefined
	parseCache[fn] = parsed
	return parsed
end

-- Parameter names for a proto: prefer the varinfo debug stream, fall back to
-- argN placeholders. `fn` (optional, root only) enables the debug.getlocal path.
local function paramNames(proto, fn)
	local names = {}
	for slot = 0, proto.numparams - 1 do
		local name
		if fn then
			name = debug.getlocal(fn, slot + 1)
		end
		if not name and proto.varinfo then
			name = varnameAt(proto, 1, slot)
		end
		if not name or name == "" or name:sub(1, 1) == "(" then
			name = "arg" .. slot
		end
		names[slot] = name
	end
	return names
end

--------------------------------------------------------------------------------
-- Fast metadata path (DeepFind): string constants + names, no bytecode decode
--------------------------------------------------------------------------------

-- Walk a proto block collecting only kgc strings and (for the root) debug
-- names. Bytecode and line maps are skipped by length; knums are consumed
-- with the cheapest possible walk.
local function metadataProto(rd, hdr, plen, out)
	local endPos = rd.pos + plen
	rd.pos = rd.pos + 3 -- flags, numparams, framesize
	local numuv = rdByte(rd)
	local numkgc = rdUleb(rd)
	local numkn = rdUleb(rd)
	local numbc = rdUleb(rd)
	local debuglen = 0
	if not hdr.stripped then
		debuglen = rdUleb(rd)
		if debuglen > 0 then
			rdUleb(rd) -- firstline
			rdUleb(rd) -- numline
		end
	end
	rd.pos = rd.pos + numbc * 4 + numuv * 2
	local consts = out.stringConsts
	for _ = 1, numkgc do
		local t = rdUleb(rd)
		if t >= BCDUMP_KGC_STR then
			consts[#consts + 1] = rdBytes(rd, t - BCDUMP_KGC_STR)
		elseif t == BCDUMP_KGC_TAB then
			local narray, nhash = rdUleb(rd), rdUleb(rd)
			for _ = 1, narray + nhash * 2 do
				local v = rdKtabk(rd)
				if type(v) == "string" then consts[#consts + 1] = v end
			end
		elseif t == BCDUMP_KGC_I64 or t == BCDUMP_KGC_U64 then
			rdUleb(rd)
			rdUleb(rd)
		elseif t == BCDUMP_KGC_COMPLEX then
			rdUleb(rd)
			rdUleb(rd)
			rdUleb(rd)
			rdUleb(rd)
		end
	end
	for _ = 1, numkn do
		local _, isnum = rdUleb33(rd)
		if isnum == 1 then rdUleb(rd) end -- high word of a double
	end
	rd.pos = endPos -- skip debug section (names re-read for root only, below)
	return debuglen, endPos
end

-- metadata(fn) -> { stringConsts = {list, all protos}, upvalueNames = {[0]=..},
--                   upvalueValues = {[0]=..}, paramNames = {[0]=..} } | nil, err
function M.metadata(fn)
	local cached = metadataCache[fn]
	if cached then return cached end
	local dump, err = dumpOf(fn)
	if not dump then return nil, err end

	local okParse, result = pcall(function()
		local rd = { data = dump, pos = 1 }
		if rdBytes(rd, 3) ~= "\27LJ" then error("not a LuaJIT bytecode dump", 0) end
		local hdr = { version = rdByte(rd) }
		if hdr.version ~= BCDUMP_VERSION then error("unsupported dump version", 0) end
		local flags = rdUleb(rd)
		if band(flags, BCDUMP_F_BE) ~= 0 then error("big-endian dump", 0) end
		hdr.stripped = band(flags, BCDUMP_F_STRIP) ~= 0
		if not hdr.stripped then
			local namelen = rdUleb(rd)
			if namelen > 0 then rd.pos = rd.pos + namelen end
		end

		local out = { stringConsts = {} }
		local lastDbg -- debug-section info of the last (= root) proto
		while true do
			if rd.pos > #dump then break end
			local plen = rdUleb(rd)
			if plen == 0 then break end
			local startPos = rd.pos
			local debuglen, endPos = metadataProto(rd, hdr, plen, out)
			lastDbg = { start = startPos, debuglen = debuglen, endPos = endPos }
		end

		-- Root's upvalue names from its debug section (uvnames follow the line map).
		local upvalueNames = {}
		if lastDbg and lastDbg.debuglen > 0 then
			-- Re-derive: line-entry width needs numline, so re-read the root header.
			local rd2 = { data = dump, pos = lastDbg.start }
			rd2.pos = rd2.pos + 3
			local numuv = rdByte(rd2)
			rdUleb(rd2) -- numkgc
			rdUleb(rd2) -- numkn
			local numbc = rdUleb(rd2)
			rdUleb(rd2) -- debuglen
			rdUleb(rd2) -- firstline
			local numline = rdUleb(rd2)
			local width = numline < 256 and 1 or numline < 65536 and 2 or 4
			rd2.pos = lastDbg.endPos - lastDbg.debuglen + numbc * width
			for i = 0, numuv - 1 do
				upvalueNames[i] = rdZString(rd2)
			end
		end
		out.upvalueNames = upvalueNames
		return out
	end)
	if not okParse then return nil, tostring(result) end

	-- Live-closure facts.
	local upvalueValues = {}
	for i = 1, math.huge do
		local name, value = debug.getupvalue(fn, i)
		if name == nil then break end
		upvalueValues[i - 1] = value
		if result.upvalueNames[i - 1] == nil and name ~= "" then
			result.upvalueNames[i - 1] = name
		end
	end
	result.upvalueValues = upvalueValues

	-- debug.getlocal on a function object yields exactly the parameter names.
	local pnames = {}
	for i = 1, 255 do
		local name = debug.getlocal(fn, i)
		if name == nil then break end
		pnames[i - 1] = name
	end
	result.paramNames = pnames

	metadataCache[fn] = result
	return result
end

--------------------------------------------------------------------------------
-- Listing renderer (annotated disassembly)
--------------------------------------------------------------------------------

local function shortString(s, maxLen)
	local q = strfmt("%q", s):gsub("\\\n", "\\n")
	if #q > maxLen then
		q = q:sub(1, maxLen - 3) .. "..."
	end
	return q
end

-- Collapse newlines so a value can go safely inside a single-line `--` comment.
-- We can't trust a caller-supplied formatValue to be newline-free (a raw %q of a
-- multi-line string yields backslash-newline), and a stray newline would push
-- the rest of the comment onto an uncommented line that then parses as code.
local function commentSafe(s)
	return (tostring(s):gsub("[\r\n]+", " "))
end

-- KPRI/pri operand values, used both as listing text and as prim-node `v`.
local PRI = { [0] = "nil", [1] = "false", [2] = "true" }

-- Render one operand for the listing. `slotName(slot)` resolves a register's
-- active variable name at the instruction being rendered (see listProto).
local function operandText(proto, pc, mode, value, slotName)
	if mode == "dst" or mode == "var" or mode == "base" or mode == "rbase" then
		local name = slotName(value)
		if name and name:sub(1, 1) ~= "(" then
			return strfmt("r%d(%s)", value, name)
		end
		return "r" .. value
	elseif mode == "uv" then
		local name = proto.uvnames and proto.uvnames[value]
		return name and strfmt("uv%d(%s)", value, name) or ("uv" .. value)
	elseif mode == "str" then
		local k = proto.kgc[value]
		return k and k.type == "str" and shortString(k.value, 32) or ("kgc" .. value)
	elseif mode == "num" then
		local n = proto.knum[value]
		return n ~= nil and tostring(n) or ("knum" .. value)
	elseif mode == "pri" then
		return PRI[value] or tostring(value)
	elseif mode == "lit" or mode == "lits" then
		if mode == "lits" and value >= 0x8000 then value = value - 0x10000 end
		return "#" .. value
	elseif mode == "jump" then
		return "=> " .. strfmt("%04d", pc + 1 + (value - 0x8000))
	elseif mode == "func" then
		local k = proto.kgc[value]
		return k and k.type == "child" and strfmt("proto:%d", value) or ("kgc" .. value)
	elseif mode == "tab" then
		return "ktab:" .. value
	elseif mode == "cdata" then
		return "kcdata:" .. value
	end
	return nil -- "none"
end

local function listProto(proto, out, opts, label)
	local indent = opts.indent or ""
	local pnames = paramNames(proto, opts.fn)
	local plist = {}
	for i = 0, proto.numparams - 1 do plist[#plist + 1] = pnames[i] end
	if proto.isvararg then plist[#plist + 1] = "..." end
	out[#out + 1] = strfmt("%s-- %s(%s)  [%d slots, %d ins]",
		indent, label, concat(plist, ", "), proto.framesize, #proto.ins)

	-- Upvalue header, with live values when we have them (root only).
	for i = 0, proto.numuv - 1 do
		local name = proto.uvnames and proto.uvnames[i] or ("uv" .. i)
		local vtext = ""
		if proto.upvalueValues and proto.upvalueValues[i] ~= nil then
			local v = proto.upvalueValues[i]
			vtext = " = " .. commentSafe(opts.formatValue and opts.formatValue(v)
				or type(v) == "string" and shortString(v, 40) or tostring(v))
		end
		out[#out + 1] = strfmt("%s-- upvalue %d: %s%s", indent, i, name, vtext)
	end

	-- Slot names via ONE incremental walk of the (declaration-ordered, startpc-
	-- non-decreasing) varinfo, instead of a varnameAt per operand: the listing
	-- looks up a name for every slot operand of every instruction, so each
	-- lookup is a guaranteed cache miss with a linear varinfo scan -- the
	-- dominant cost of listing large functions. `active` holds the variables
	-- live at the current pc in declaration order (removals compact in place;
	-- additions always have a later declaration index), so slot N's name is
	-- active[N+1] -- exactly varnameAt's walk. Compaction is lazy: `minEnd`
	-- tracks the earliest active endpc, so pcs where nothing expires (the vast
	-- majority) skip the scan entirely.
	local vars = proto.varinfo
	local active, nextVar, minEnd = {}, 1, huge
	local function advanceVars(pc)
		if pc >= minEnd then
			local w = 1
			minEnd = huge
			for i = 1, #active do
				local v = active[i]
				if pc < v.endpc then
					active[w] = v
					w = w + 1
					if v.endpc < minEnd then minEnd = v.endpc end
				end
			end
			for i = #active, w, -1 do active[i] = nil end
		end
		while nextVar <= #vars and vars[nextVar].startpc <= pc do
			local v = vars[nextVar]
			if pc < v.endpc then
				active[#active + 1] = v
				if v.endpc < minEnd then minEnd = v.endpc end
			end
			nextVar = nextVar + 1
		end
	end
	local function slotName(slot)
		local v = active[slot + 1]
		return v and v.name or nil
	end
	if not vars then slotName = function() return nil end end

	local lastLine
	for pc = 1, #proto.ins do
		if vars then advanceVars(pc) end
		local ins = proto.ins[pc]
		local mode = OPMODE[ins.op]
		local parts = {}
		local aText = operandText(proto, pc, mode.a, ins.a, slotName)
		if aText then parts[#parts + 1] = aText end
		if mode.b then
			local bText = operandText(proto, pc, mode.b, ins.b, slotName)
			if bText then parts[#parts + 1] = bText end
			local cText = operandText(proto, pc, mode.c, ins.c, slotName)
			if cText then parts[#parts + 1] = cText end
		elseif mode.d then
			local dText = operandText(proto, pc, mode.d, ins.d, slotName)
			if dText then parts[#parts + 1] = dText end
		end
		local lineNote = ""
		if proto.lines and proto.lines[pc] ~= lastLine then
			lastLine = proto.lines[pc]
			lineNote = "  -- line " .. lastLine
		end
		out[#out + 1] = strfmt("%s%04d  %-6s %s%s", indent, pc, OPNAMES[ins.op], concat(parts, ", "), lineNote)
	end

	-- Child prototypes, depth-first, matching FNEW operand indices.
	for idx = 0, proto.numkgc - 1 do
		local k = proto.kgc[idx]
		if k and k.type == "child" then
			out[#out + 1] = ""
			listProto(k.proto, out, { indent = indent .. "  ", formatValue = opts.formatValue },
				strfmt("proto:%d = function", idx))
		end
	end
end

-- disassemble(fn, opts) -> annotated listing.
-- opts: { indent = str, formatValue = function(v) -> str }
function M.disassemble(fn, opts)
	local parsed, err = M.parse(fn)
	if not parsed then return nil, err end
	opts = opts or {}
	local out = {}
	listProto(parsed.root, out, { indent = opts.indent, formatValue = opts.formatValue, fn = fn }, "function")
	return concat(out, "\n")
end

--------------------------------------------------------------------------------
-- Expression nodes and rendering
--------------------------------------------------------------------------------

-- Node kinds: const, prim(nil/true/false), localref, upref, global, index,
-- call (method=bool, multi=bool), vararg, binop, unop, concat, table, func,
-- raw (pre-rendered text). Rendering is precedence-aware with minimal parens.

local PREC = {
	["or"] = 1, ["and"] = 2,
	["<"] = 3, [">"] = 3, ["<="] = 3, [">="] = 3, ["~="] = 3, ["=="] = 3,
	[".."] = 4,
	["+"] = 5, ["-"] = 5,
	["*"] = 6, ["/"] = 6, ["%"] = 6,
	["^"] = 8,
}
local PREC_UNARY = 7
local PREC_ATOM = 9
local RIGHT_ASSOC = { [".."] = true, ["^"] = true }
-- Fully associative: `a op (b op c)` == `(a op b) op c`, so a same-precedence
-- right operand needs no parens (keeps or/and chains flat and readable).
local ASSOC = { ["and"] = true, ["or"] = true }

local RESERVED = {
	["and"] = true, ["break"] = true, ["do"] = true, ["else"] = true, ["elseif"] = true,
	["end"] = true, ["false"] = true, ["for"] = true, ["function"] = true, ["goto"] = true,
	["if"] = true, ["in"] = true, ["local"] = true, ["nil"] = true, ["not"] = true,
	["or"] = true, ["repeat"] = true, ["return"] = true, ["then"] = true, ["true"] = true,
	["until"] = true, ["while"] = true,
	-- GLua-only keyword: output is re-parsed by GMod, so `continue` must be
	-- bracketed as ["continue"] rather than emitted as a bare identifier/key.
	["continue"] = true,
}

local function isSafeIdent(s)
	return type(s) == "string" and s:match("^[%a_][%w_]*$") ~= nil and not RESERVED[s]
end

local function renderNumber(n)
	if n ~= n then return "(0/0)" end
	if n == huge then return "math.huge" end
	if n == -huge then return "-math.huge" end
	local s = tostring(n)
	if tonumber(s) ~= n then s = strfmt("%.17g", n) end
	return s
end

local function renderString(s)
	return (strfmt("%q", s):gsub("\\\n", "\\n"))
end

local function renderConst(v)
	local t = type(v)
	if t == "string" then return renderString(v) end
	if t == "number" then return renderNumber(v) end
	return tostring(v)
end

-- A prefix expression (name/index/call) needs no parens before an index/call/method
-- suffix; anything else (literal, constructor, operator result) must be wrapped.
local function isPrefixExpr(kind)
	return kind == "localref" or kind == "global" or kind == "upref"
		or kind == "index" or kind == "call"
end

local renderExpr -- forward (mutually recursive with function bodies)
local renderFunctionExpr -- forward

-- Render `node`; wrap in parens when its precedence is below `minPrec`
-- (or equal with wrong associativity, signalled by callers via minPrec+eps
-- convention: pass childMin = myPrec for the associative side, myPrec+1 for
-- the other side).
renderExpr = function(node, minPrec, rctx)
	local kind = node.kind
	local text, prec

	if kind == "const" then
		text, prec = renderConst(node.v), PREC_ATOM
		if type(node.v) == "number" and node.v < 0 then prec = PREC_UNARY end
	elseif kind == "prim" then
		text, prec = node.v, PREC_ATOM
	elseif kind == "localref" or kind == "global" then
		text, prec = node.name, PREC_ATOM
	elseif kind == "upref" then
		text, prec = node.name, PREC_ATOM
	elseif kind == "vararg" then
		text, prec = "...", PREC_ATOM
	elseif kind == "raw" then
		text, prec = node.text, node.prec or 0
	elseif kind == "index" then
		local objText = renderExpr(node.obj, PREC_ATOM, rctx)
		-- prefix-expression position: literals/constructors need parens
		if not isPrefixExpr(node.obj.kind) then
			objText = "(" .. objText .. ")"
		end
		if node.key.kind == "const" and isSafeIdent(node.key.v) then
			text = objText .. "." .. node.key.v
		else
			text = objText .. "[" .. renderExpr(node.key, 0, rctx) .. "]"
		end
		prec = PREC_ATOM
	elseif kind == "call" then
		local funcNode = node.func
		local args = {}
		local funcText
		if node.method then
			local objText = renderExpr(funcNode.obj, PREC_ATOM, rctx)
			if not isPrefixExpr(funcNode.obj.kind) then
				objText = "(" .. objText .. ")"
			end
			funcText = objText .. ":" .. funcNode.key.v
		else
			funcText = renderExpr(funcNode, PREC_ATOM, rctx)
			if not isPrefixExpr(funcNode.kind) then
				funcText = "(" .. funcText .. ")"
			end
		end
		for i = 1, #node.args do
			args[i] = renderExpr(node.args[i], 0, rctx)
		end
		text, prec = funcText .. "(" .. concat(args, ", ") .. ")", PREC_ATOM
	elseif kind == "binop" then
		local myPrec = PREC[node.op]
		local lMin, rMin
		if RIGHT_ASSOC[node.op] then
			lMin, rMin = myPrec + 1, myPrec
		elseif ASSOC[node.op] then
			lMin, rMin = myPrec, myPrec
		else
			lMin, rMin = myPrec, myPrec + 1
		end
		text = renderExpr(node.lhs, lMin, rctx) .. " " .. node.op .. " " .. renderExpr(node.rhs, rMin, rctx)
		prec = myPrec
	elseif kind == "unop" then
		local inner = renderExpr(node.expr, PREC_UNARY, rctx)
		local sep = (node.op == "not" or (node.op == "-" and inner:sub(1, 1) == "-")) and " " or ""
		text, prec = node.op .. sep .. inner, PREC_UNARY
	elseif kind == "concat" then
		local parts = {}
		for i = 1, #node.parts do
			parts[i] = renderExpr(node.parts[i], PREC[".."] + 1, rctx)
		end
		text, prec = concat(parts, " .. "), PREC[".."]
	elseif kind == "table" then
		local parts = {}
		for i = 1, #node.fields do
			local f = node.fields[i]
			if f.key == nil then
				parts[#parts + 1] = renderExpr(f.value, 0, rctx)
			elseif isSafeIdent(f.key) then
				parts[#parts + 1] = f.key .. " = " .. renderExpr(f.value, 0, rctx)
			else
				parts[#parts + 1] = "[" .. renderConst(f.key) .. "] = " .. renderExpr(f.value, 0, rctx)
			end
		end
		text = #parts == 0 and "{}" or ("{ " .. concat(parts, ", ") .. " }")
		prec = PREC_ATOM
	elseif kind == "func" then
		text, prec = renderFunctionExpr(node.proto, rctx), PREC_ATOM
	else
		text, prec = "--[[?" .. tostring(kind) .. "]]", 0
	end

	if prec < minPrec then
		return "(" .. text .. ")"
	end
	return text
end

--------------------------------------------------------------------------------
-- Statement builder: bytecode -> statement list with slot tracking
--------------------------------------------------------------------------------

-- Loop back-edge opcodes (FORL/ITERL families): pure iteration machinery whose
-- slot reads/writes are not source-level uses, so forEachSlot skips them entirely.
local BACKEDGE_OPS = {
	[INST.FORL] = true, [INST.IFORL] = true, [INST.JFORL] = true,
	[INST.ITERL] = true, [INST.IITERL] = true, [INST.JITERL] = true,
}

-- Shared no-op callback: passed to forEachSlot when a caller only cares about
-- reads or only about writes, so the unused side doesn't allocate a fresh closure.
local function NOP() end

local function shallowCopy(t)
	local c = {}
	for k, v in pairs(t) do c[k] = v end
	return c
end

-- Read/write slot sets per instruction, shared by the use-count pre-pass.
-- cbRead/cbWrite are called with each slot number.
local function forEachSlot(ins, fr2, cbRead, cbWrite)
	local op, a, b, c, d = ins.op, ins.a, ins.b, ins.c, ins.d
	if BACKEDGE_OPS[op] then return end

	if op >= INST.CALLM and op <= INST.CALLT then -- CALLM CALL CALLMT CALLT
		cbRead(a)
		local nargs = (op == INST.CALLM or op == INST.CALL) and c - 1 or d - 1
		if op == INST.CALLM or op == INST.CALLMT then nargs = nargs + 1 end -- C is fixed-arg count
		for i = 1, nargs do cbRead(a + fr2 + i) end
		if op == INST.CALL or op == INST.CALLM then
			for i = 0, b - 2 do cbWrite(a + i) end
		end
	elseif op == INST.ITERC or op == INST.ITERN then
		cbRead(a - 3)
		cbRead(a - 2)
		cbRead(a - 1)
		for i = 0, b - 2 do cbWrite(a + i) end
	elseif op == INST.CAT then
		for i = b, c do cbRead(i) end
		cbWrite(a)
	elseif op == INST.KNIL then
		for i = a, d do cbWrite(i) end
	elseif op == INST.VARG then
		for i = 0, b - 2 do cbWrite(a + i) end
	elseif op == INST.RET or op == INST.RETM then
		for i = 0, d - 2 do cbRead(a + i) end
	elseif op == INST.RET1 then
		cbRead(a)
	elseif op == INST.FORI or op == INST.JFORI then
		cbRead(a)
		cbRead(a + 1)
		cbRead(a + 2)
		cbWrite(a + 3)
	elseif op == INST.TSETM then
		cbRead(a - 1)
	elseif op == INST.TSETV or op == INST.TSETR then
		cbRead(a)
		cbRead(b)
		cbRead(c)
	elseif op == INST.TSETS or op == INST.TSETB then
		cbRead(a)
		cbRead(b)
	else
		-- Mode-driven default for the simple ops. Reads must be registered
		-- before the write: `sum = sum + x` reads the previous definition.
		local mode = OPMODE[op]
		if mode.a == "var" then cbRead(a) end
		if mode.b == "var" then cbRead(b) end
		if mode.c == "var" then cbRead(c) end
		if mode.d == "var" then cbRead(d) end
		if mode.a == "dst" then cbWrite(a) end
	end
end

-- The name of `slot` right after instruction `pc` executes, plus whether that
-- name's scope starts exactly there (=> a fresh `local` declaration) and, for a
-- multi-local group, the shared group start pc so storeSlot can coalesce members.
--
-- A multi-local `local a, b, c = e1, e2, e3` evaluates every RHS into consecutive
-- ascending slots FIRST, so all names activate together at the group start pc (just
-- after the last store), not at each store's pc+1. `varnameAt(pc+1)` therefore
-- names only the LAST member; the earlier ones look nameless and later code that
-- references their real names goes out of scope -> fallback. So when the immediate
-- lookup misses, scan forward (bounded) for the pc where the slot's name freshly
-- activates, accepting it only if the slot isn't rewritten in between (so the stored
-- value is exactly what the name binds).
local MULTILOCAL_WINDOW = 16
local function declNameAt(proto, pc, slot, fr2)
	local name, entry = varnameAt(proto, pc + 1, slot)
	if name and name:sub(1, 1) ~= "(" then
		return name, entry.startpc == pc + 1, entry.startpc
	end
	if not fr2 then return nil end
	local limit = pc + 1 + MULTILOCAL_WINDOW
	if limit > #proto.ins then limit = #proto.ins end
	for g = pc + 2, limit do
		local n2, e2 = varnameAt(proto, g, slot)
		if n2 then
			if n2:sub(1, 1) ~= "(" and e2.startpc == g then
				-- The stored value must survive UNTOUCHED to g: a genuine multi-local
				-- member isn't read or overwritten before its name activates. If the
				-- slot is read (consumed as a call arg) or rewritten in between, it's a
				-- temp whose slot a later local reuses (`local w = f(s, "%a+")` where
				-- the loop var reuses the const's slot) -- naming it would be wrong.
				for p = pc + 1, g - 1 do
					local touched = false
					local function cb(x) if x == slot then touched = true end end
					forEachSlot(proto.ins[p], fr2, cb, cb)
					if touched then return nil end
				end
				return n2, true, g -- deferred multi-local member; fresh at group pc g
			end
			return nil -- slot occupied by a different (non-fresh) name here
		end
	end
	return nil
end

local function emit(ctx, stmt)
	ctx.stmts[#ctx.stmts + 1] = stmt
	return stmt
end

-- Collect the register slots an expression node reads, so a later write to any
-- of them can invalidate this node if it is still pending (see the swap case:
-- a pending `y` must be materialized before `y` is reassigned).
local function collectReadSlots(node, set)
	local kind = node.kind
	if kind == "localref" then
		if node.slot then set[node.slot] = true end
	elseif kind == "index" then
		collectReadSlots(node.obj, set)
		collectReadSlots(node.key, set)
	elseif kind == "call" then
		collectReadSlots(node.func, set)
		for i = 1, #node.args do collectReadSlots(node.args[i], set) end
	elseif kind == "binop" then
		collectReadSlots(node.lhs, set)
		collectReadSlots(node.rhs, set)
	elseif kind == "unop" then
		collectReadSlots(node.expr, set)
	elseif kind == "concat" then
		for i = 1, #node.parts do collectReadSlots(node.parts[i], set) end
	elseif kind == "table" then
		for i = 1, #node.fields do collectReadSlots(node.fields[i].value, set) end
	end
	return set
end

-- Allocate a fresh synthetic name for an unnamed register and record it as the
-- register's current name. Synthetic names MUST be unique per materialization,
-- not per register: a reused register that holds two distinct values within one
-- block would otherwise emit two `local slotN` that shadow each other (wrong,
-- yet still re-parses). `curName[slot]` is what slotRef returns until the
-- register is materialized again.
local function freshSynth(ctx, slot)
	ctx.synthN = (ctx.synthN or 0) + 1
	local name = "tmp" .. ctx.synthN
	ctx.curName = ctx.curName or {}
	ctx.curName[slot] = name
	return name
end

-- The synthetic name a register currently carries (for references).
local function synthName(ctx, slot)
	return (ctx.curName and ctx.curName[slot]) or ("slot" .. slot)
end

-- Materialize a still-pending expression in `slot` as a statement (used when
-- the pending value is about to be overwritten or read more than once).
-- A table constructor split across statements -- a field value needed a temp (a value
-- short-circuit/diamond, a nested table), so the base is flushed to a slot and the rest
-- of the fields become `base.k = v` assignments. The local's varinfo name only activates
-- AFTER the last field set, so both declNameAt(defPc) and varnameAt(flushPc) miss it and
-- the base binds `tmpN` while the reads after the constructor resolve to the real name ->
-- scope-escape/none (Arcana RegisterEnchantment). Scan forward for the pc where the
-- slot's name freshly activates, tolerating intervening READS of the slot (field writes
-- read the base) but stopping at any WRITE (the slot was reused for a new value).
local TABLE_NAME_WINDOW = 128
local function tableNameForward(proto, fromPc, slot, fr2)
	if not fr2 then return nil end
	local limit = fromPc + TABLE_NAME_WINDOW
	if limit > #proto.ins then limit = #proto.ins end
	for g = fromPc + 1, limit do
		local written = false
		forEachSlot(proto.ins[g], fr2, NOP,
			function(x) if x == slot then written = true end end)
		if written then return nil end
		local n, e = varnameAt(proto, g, slot)
		if n and n:sub(1, 1) ~= "(" and e and e.startpc == g then return n end
	end
	return nil
end

-- Is `slot` loop-carried by a while/repeat loop whose body contains `pc`? A
-- loop-carried slot's value flows across the back-edge (it is read before it is
-- written within the loop), so it needs ONE stable home -- declared once, assigned
-- on each in-loop update -- rather than per-def inlining, which would drop the
-- update or stale it to the pre-loop value. Only meaningful for unnamed (stripped)
-- slots; with varinfo the real name already forces a home (see storeSlot). Ranges
-- are precomputed in findLoopCarried.
local function carriedHere(ctx, slot, pc)
	local ranges = ctx.carriedRanges
	if not ranges then return false end
	for i = 1, #ranges do
		local r = ranges[i]
		if pc >= r.lo and pc <= r.hi and r.slots[slot] then return true end
	end
	return false
end

local function flushSlot(ctx, slot, pc)
	local pending = ctx.slots[slot]
	if not pending then return end
	ctx.slots[slot] = nil
	if ctx.pendingReads then ctx.pendingReads[slot] = nil end
	local defPc = ctx.slotDefPc[slot] or pc
	-- Pass fr2 so a deferred multi-local member (`local a, b = A ~= 0, B ~= 0`, where
	-- a's varinfo activates only at the group pc, not at its own def) resolves to its
	-- real name instead of a dead synthetic that gets stripped, leaving it undeclared.
	local name, fresh = declNameAt(ctx.proto, defPc, slot, ctx.fr2)
	if not name then
		-- declNameAt looks at the DEF pc, but some values' varinfo name only activates
		-- LATER: a table local's after the constructor is fully built, a value
		-- short-circuit's (`local Legacy = a and b`) after the branch merge. At the def
		-- pc the slot looks nameless, so the flush emits `local tmpN` while later reads
		-- resolve the slot to its real varinfo name -- the mismatched tmpN then gets
		-- dead-stripped, leaving the real name undeclared (scope-escape). Reads take the
		-- name live at the USE pc, so bind to the name live at the flush pc instead. It's
		-- a fresh `local` when that name's scope opens after the def (always so here:
		-- declNameAt already confirmed no name at defPc+1, so any name found now is newer).
		local vname, ventry = varnameAt(ctx.proto, pc, slot)
		if vname and vname:sub(1, 1) ~= "(" then
			name = vname
			fresh = (not ventry) or (not ventry.startpc) or (ventry.startpc > defPc)
		elseif pending.kind == "table" then
			-- A split table constructor whose name activates only after the last field
			-- set (later than this early base flush). Bind that name AND record it as the
			-- slot's current name, so the intervening `base.k = v` field writes (which
			-- resolve before activation, via synthName) agree with it instead of emitting
			-- `tmpN.k` against a `local <realname>` base.
			local tname = tableNameForward(ctx.proto, defPc, slot, ctx.fr2)
			if tname then
				name, fresh = tname, true
				ctx.curName = ctx.curName or {}
				ctx.curName[slot] = tname
			end
		end
	end
	if name then
		emit(ctx, { kind = fresh and "local" or "assign", names = { name }, exprs = { pending }, pc = defPc })
	else
		emit(ctx, { kind = "local", names = { freshSynth(ctx, slot) }, exprs = { pending }, pc = defPc })
	end
end

-- Before writing `slot`, materialize any pending expression that reads it, so
-- the emitted statement order preserves the value it had before the write.
local function invalidateReaders(ctx, slot, pc)
	local readers = ctx.pendingReads
	if not readers then return end
	for other, reads in pairs(readers) do
		if other ~= slot and reads[slot] and ctx.slots[other] ~= nil then
			flushSlot(ctx, other, pc)
		end
	end
end

-- Record what a pending expression in `slot` reads (nil clears it).
local function setPending(ctx, slot, node)
	ctx.slots[slot] = node
	ctx.pendingReads = ctx.pendingReads or {}
	if node == nil then
		ctx.pendingReads[slot] = nil
	else
		ctx.pendingReads[slot] = collectReadSlots(node, {})
	end
end

-- Reference to `slot` as an expression at instruction `pc`.
local function slotRef(ctx, slot, pc)
	local pending = ctx.slots[slot]
	if pending then
		local defPc = ctx.slotDefPc[slot]
		if defPc and ctx.useCount[defPc] == 1 then
			ctx.slots[slot] = nil -- consumed inline
			if ctx.pendingReads then ctx.pendingReads[slot] = nil end
			return pending
		end
		-- Multi-use pending value (a deferred table constructor): give it a
		-- home first, then reference it by name.
		flushSlot(ctx, slot, pc)
	end
	-- Prefer a real (varinfo) name; else the register's current synthetic name.
	local name = varnameAt(ctx.proto, pc, slot)
	if name and name:sub(1, 1) ~= "(" then
		return { kind = "localref", name = name, slot = slot }
	end
	return { kind = "localref", name = synthName(ctx, slot), slot = slot }
end

-- Store `expr` produced by instruction `pc` into `slot`. Named slots become
-- statements; unnamed single-use temporaries stay pending for inlining.
local function storeSlot(ctx, slot, pc, expr)
	invalidateReaders(ctx, slot, pc)
	flushSlot(ctx, slot, pc)
	ctx.slotDefPc[slot] = pc
	-- Method-call detection metadata is invalidated by any write to the slot;
	-- MOV/TGESS handlers re-set it right after this call when appropriate.
	if ctx.movSrc then ctx.movSrc[slot] = nil end
	if ctx.tgetsBase then ctx.tgetsBase[slot] = nil end
	local name, fresh, groupStart = declNameAt(ctx.proto, pc, slot, ctx.fr2)
	if name then
		-- Coalesce multi-local members (`local a, b, c = e1, e2, e3`) into ONE
		-- statement: members share a groupStart and land in consecutive slots. A
		-- single statement also gives correct eval order for referential groups
		-- (`local a, b = b, a`) -- all RHS evaluate before any name binds, matching
		-- the bytecode -- which sequential `local`s would get wrong.
		if fresh and groupStart then
			local prev = ctx.stmts[#ctx.stmts]
			if prev and prev.kind == "local" and prev.mlGroup == groupStart
				and prev.mlLastSlot == slot - 1 then
				prev.names[#prev.names + 1] = name
				prev.exprs[#prev.exprs + 1] = expr
				prev.mlLastSlot = slot
				setPending(ctx, slot, nil)
				return
			end
			local st = emit(ctx, { kind = "local", names = { name }, exprs = { expr }, pc = pc })
			st.mlGroup = groupStart
			st.mlLastSlot = slot
			setPending(ctx, slot, nil)
			return
		end
		emit(ctx, { kind = fresh and "local" or "assign", names = { name }, exprs = { expr }, pc = pc })
		setPending(ctx, slot, nil)
		return
	end
	-- A loop-carried slot (unnamed; the named path above already homed it) must
	-- materialize to the one home established at loop entry, never inline: an inlined
	-- in-loop update is dropped (the back-edge read isn't in the linear use count) or
	-- staled to the pre-loop value -- reparse-clean but semantically wrong. Assign to
	-- the home once declared; declare it fresh if entry-flush hasn't (defensive).
	if carriedHere(ctx, slot, pc) then
		ctx.homeDeclared = ctx.homeDeclared or {}
		if ctx.homeDeclared[slot] then
			emit(ctx, { kind = "assign", names = { synthName(ctx, slot) }, exprs = { expr }, pc = pc })
		else
			emit(ctx, { kind = "local", names = { freshSynth(ctx, slot) }, exprs = { expr }, pc = pc })
			ctx.homeDeclared[slot] = true
		end
		setPending(ctx, slot, nil)
		return
	end
	local uses = ctx.useCount[pc] or 0
	if uses == 1 then
		setPending(ctx, slot, expr)
	else
		-- Zero or multiple uses: materialize as a temp so side effects happen
		-- exactly once, in order.
		emit(ctx, { kind = "local", names = { freshSynth(ctx, slot) }, exprs = { expr }, pc = pc })
		setPending(ctx, slot, nil)
	end
end

-- Store a table-constructor node: kept pending even when multi-use, so that
-- following TSETS/TSETB writes fold into the literal. Materialized on first
-- non-constructor use (slotRef) or overwrite (flushSlot).
local function storeConstructor(ctx, slot, pc, node)
	invalidateReaders(ctx, slot, pc)
	flushSlot(ctx, slot, pc)
	ctx.slotDefPc[slot] = pc
	if (ctx.useCount[pc] or 0) == 0 then
		-- Dead store: keep it visible.
		local name, fresh = declNameAt(ctx.proto, pc, slot)
		emit(ctx, { kind = (not name or fresh) and "local" or "assign",
			names = { name or freshSynth(ctx, slot) }, exprs = { node }, pc = pc })
	else
		setPending(ctx, slot, node)
	end
end

-- Multi-value stores (CALL with nret>1, VARG): one statement, several names.
local function storeMulti(ctx, baseSlot, count, pc, expr)
	local names, allFresh = {}, true
	for i = 0, count - 1 do
		invalidateReaders(ctx, baseSlot + i, pc)
		flushSlot(ctx, baseSlot + i, pc)
		local name, fresh = declNameAt(ctx.proto, pc, baseSlot + i)
		if not name then
			name = freshSynth(ctx, baseSlot + i)
		elseif not fresh then
			allFresh = false
		end
		names[#names + 1] = name
	end
	emit(ctx, { kind = allFresh and "local" or "assign", names = names, exprs = { expr }, pc = pc })
	ctx.lastMulti = { base = baseSlot, count = count, expr = expr, stmtIndex = #ctx.stmts }
end

local function kgcString(ctx, idx)
	local k = ctx.proto.kgc[idx]
	if k and k.type == "str" then return k.value end
	return nil
end

local function constNode(v)
	if v == nil then return { kind = "prim", v = "nil" } end
	if v == true then return { kind = "prim", v = "true" } end
	if v == false then return { kind = "prim", v = "false" } end
	return { kind = "const", v = v }
end

-- Template table constant -> table node fields (array part, then sorted keys).
local function templateFields(tab)
	local fields = {}
	local n = 1
	while tab[n] ~= nil do
		fields[#fields + 1] = { value = constNode(tab[n]) }
		n = n + 1
	end
	local keys = {}
	for k in pairs(tab) do
		if not (type(k) == "number" and k >= 1 and k < n and k == floor(k)) and k ~= 0 then
			keys[#keys + 1] = k
		end
	end
	table.sort(keys, function(x, y)
		if type(x) == type(y) then
			if type(x) == "number" then return x < y end
			return tostring(x) < tostring(y)
		end
		return type(x) == "number"
	end)
	for _, k in ipairs(keys) do
		fields[#fields + 1] = { key = k, value = constNode(tab[k]) }
	end
	return fields
end

-- Build a `return` statement from a RET* instruction, evaluated at `pc` (which
-- may be a jump site that targets this return, not the RET's own pc).
local function buildReturnStmt(ctx, ins, pc)
	local op, a, d = ins.op, ins.a, ins.d
	if op == INST.RET0 then
		return { kind = "return", exprs = {}, pc = pc }
	elseif op == INST.RET1 then
		return { kind = "return", exprs = { slotRef(ctx, a, pc) }, pc = pc }
	elseif op == INST.RETM then
		-- RETM's operand is the fixed-result count directly (R(A)..R(A+D-1)),
		-- followed by MULTRES; unlike RET, where D = nresults+1. So `return ...`
		-- is RETM #0 (no fixed values), `return true, f()` is RETM #1 (one fixed).
		local exprs = {}
		for i = 0, d - 1 do exprs[#exprs + 1] = slotRef(ctx, a + i, pc) end
		exprs[#exprs + 1] = ctx.multres or { kind = "vararg" }
		ctx.multres = nil
		return { kind = "return", exprs = exprs, pc = pc }
	end
	-- RET
	local exprs = {}
	for i = 0, d - 2 do exprs[#exprs + 1] = slotRef(ctx, a + i, pc) end
	return { kind = "return", exprs = exprs, pc = pc }
end

local ARITH_OPS = {
	[INST.ADDVN] = "+", [INST.SUBVN] = "-", [INST.MULVN] = "*", [INST.DIVVN] = "/", [INST.MODVN] = "%",
	[INST.ADDNV] = "+", [INST.SUBNV] = "-", [INST.MULNV] = "*", [INST.DIVNV] = "/", [INST.MODNV] = "%",
	[INST.ADDVV] = "+", [INST.SUBVV] = "-", [INST.MULVV] = "*", [INST.DIVVV] = "/", [INST.MODVV] = "%",
	[INST.POW] = "^",
}

local COMPARE_OPS = {
	-- Rendered as the *source* condition: the branch is taken when the named
	-- condition is false, so ISLT A,D corresponds to source `A < D` guarding
	-- the fallthrough block. The structurer decides which side to show.
	[INST.ISLT] = "<", [INST.ISGE] = ">=", [INST.ISLE] = "<=", [INST.ISGT] = ">",
	[INST.ISEQV] = "==", [INST.ISNEV] = "~=", [INST.ISEQS] = "==", [INST.ISNES] = "~=",
	[INST.ISEQN] = "==", [INST.ISNEN] = "~=", [INST.ISEQP] = "==", [INST.ISNEP] = "~=",
}

-- Block-terminating ops, grouped so recognizers test set membership, not op chains:
-- RETURN_OPS end the frame; TAILCALL_OPS are out-of-line tail calls (`return f(...)`).
local RETURN_OPS = { [INST.RET0] = true, [INST.RET1] = true, [INST.RET] = true, [INST.RETM] = true }
local TAILCALL_OPS = { [INST.CALLT] = true, [INST.CALLMT] = true }

-- Build the boolean expression tested by a comparison/test instruction.
local function condExpr(ctx, ins, pc)
	local op = ins.op
	local cmp = COMPARE_OPS[op]
	if cmp then
		local lhs = slotRef(ctx, ins.a, pc)
		local rhs
		if op == INST.ISEQS or op == INST.ISNES then
			rhs = constNode(kgcString(ctx, ins.d) or "?")
		elseif op == INST.ISEQN or op == INST.ISNEN then
			rhs = constNode(ctx.proto.knum[ins.d])
		elseif op == INST.ISEQP or op == INST.ISNEP then
			rhs = { kind = "prim", v = PRI[ins.d] }
		else
			rhs = slotRef(ctx, ins.d, pc)
		end
		return { kind = "binop", op = cmp, lhs = lhs, rhs = rhs }
	elseif op == INST.IST or op == INST.ISTC then
		return slotRef(ctx, ins.d, pc)
	elseif op == INST.ISF or op == INST.ISFC then
		return { kind = "unop", op = "not", expr = slotRef(ctx, ins.d, pc) }
	end
	return { kind = "raw", text = "--[[cond?]]" }
end

-- Resolve the display name of upvalue `idx` for a proto, walking to the parent
-- when this proto's dump had no debug names.
local function upvalName(proto, idx)
	local name = proto.uvnames and proto.uvnames[idx]
	if name and name ~= "" and name:sub(1, 1) ~= "(" then return name end
	local ref = proto.uv[idx]
	if ref and ref.inParent and proto.parent then
		return upvalName(proto.parent, ref.uvIndex)
	end
	return "uv" .. idx
end

-- Method-call sugar, detected structurally at a CALL* with func slot `a`: the func
-- came from TGETS `obj.name` and the first arg is a MOV self-copy of that obj slot.
-- On a match, drop the explicit self arg and return true (renders `obj:name(...)`).
-- Structural (not expression compare, which breaks on chained `a:b():c()`).
local function detectMethodCall(ctx, a, fr2, funcNode, args)
	local baseInfo = ctx.tgetsBase and ctx.tgetsBase[a]
	local selfSrc = ctx.movSrc and ctx.movSrc[a + fr2 + 1]
	if baseInfo and selfSrc == baseInfo.base and isSafeIdent(baseInfo.key)
		and funcNode.kind == "index" and #args >= 1 then
		table.remove(args, 1)
		return true
	end
	return false
end

-- One instruction of the statement builder. Returns nothing; appends to
-- ctx.stmts / updates ctx.slots. Control-flow ops are left to the structurer;
-- here (straight-line mode) they surface as honest comments.
local function buildIns(ctx, pc)
	local proto = ctx.proto
	local ins = proto.ins[pc]
	local op, a, b, c, d = ins.op, ins.a, ins.b, ins.c, ins.d
	local fr2 = ctx.fr2

	if op == INST.MOV then
		if ctx.methodSelfMov and ctx.methodSelfMov[pc] then
			-- Method self-copy: keep the object pending in `d` for the method-lookup
			-- TGETS that follows to consume (so it renders as the `:m()` receiver);
			-- this copy is dropped by method sugar at the CALL, so we stash a
			-- non-consuming reference to the object without stealing it from `d`.
			invalidateReaders(ctx, a, pc)
			flushSlot(ctx, a, pc)
			ctx.slotDefPc[a] = pc
			if ctx.tgetsBase then ctx.tgetsBase[a] = nil end
			setPending(ctx, a, ctx.slots[d] or slotRef(ctx, d, pc))
			ctx.movSrc = ctx.movSrc or {}
			ctx.movSrc[a] = d
			return
		end
		storeSlot(ctx, a, pc, slotRef(ctx, d, pc))
		ctx.movSrc = ctx.movSrc or {}
		ctx.movSrc[a] = d -- remember self-copy source for method detection
	elseif op == INST.NOT then
		storeSlot(ctx, a, pc, { kind = "unop", op = "not", expr = slotRef(ctx, d, pc) })
	elseif op == INST.UNM then
		storeSlot(ctx, a, pc, { kind = "unop", op = "-", expr = slotRef(ctx, d, pc) })
	elseif op == INST.LEN then
		storeSlot(ctx, a, pc, { kind = "unop", op = "#", expr = slotRef(ctx, d, pc) })
	elseif ARITH_OPS[op] then
		local isNV = op >= INST.ADDNV and op <= INST.MODNV
		local isVN = op >= INST.ADDVN and op <= INST.MODVN
		local lhs, rhs
		if isVN then
			lhs, rhs = slotRef(ctx, b, pc), constNode(proto.knum[c])
		elseif isNV then
			lhs, rhs = constNode(proto.knum[c]), slotRef(ctx, b, pc)
		else
			lhs, rhs = slotRef(ctx, b, pc), slotRef(ctx, c, pc)
		end
		storeSlot(ctx, a, pc, { kind = "binop", op = ARITH_OPS[op], lhs = lhs, rhs = rhs })
	elseif op == INST.CAT then
		local parts = {}
		for i = b, c do
			parts[#parts + 1] = slotRef(ctx, i, pc)
		end
		storeSlot(ctx, a, pc, { kind = "concat", parts = parts })
	elseif op == INST.KSTR then
		storeSlot(ctx, a, pc, constNode(kgcString(ctx, d) or "?"))
	elseif op == INST.KCDATA then
		storeSlot(ctx, a, pc, { kind = "raw", text = "--[[cdata]] nil", prec = 0 })
	elseif op == INST.KSHORT then
		local v = d
		if v >= 0x8000 then v = v - 0x10000 end
		storeSlot(ctx, a, pc, constNode(v))
	elseif op == INST.KNUM then
		storeSlot(ctx, a, pc, constNode(proto.knum[d]))
	elseif op == INST.KPRI then
		storeSlot(ctx, a, pc, { kind = "prim", v = PRI[d] })
	elseif op == INST.KNIL then
		local names, exprs = {}, {}
		for slot = a, d do
			flushSlot(ctx, slot, pc)
			local name = declNameAt(proto, pc, slot)
			names[#names + 1] = name or freshSynth(ctx, slot)
			exprs[#exprs + 1] = { kind = "prim", v = "nil" }
		end
		emit(ctx, { kind = "local", names = names, exprs = exprs, pc = pc })
	elseif op == INST.UGET then
		storeSlot(ctx, a, pc, { kind = "upref", name = upvalName(proto, d) })
	elseif op == INST.USETV then
		emit(ctx, { kind = "assign", names = { upvalName(proto, a) }, exprs = { slotRef(ctx, d, pc) }, pc = pc })
	elseif op == INST.USETS then
		emit(ctx, { kind = "assign", names = { upvalName(proto, a) }, exprs = { constNode(kgcString(ctx, d) or "?") }, pc = pc })
	elseif op == INST.USETN then
		emit(ctx, { kind = "assign", names = { upvalName(proto, a) }, exprs = { constNode(proto.knum[d]) }, pc = pc })
	elseif op == INST.USETP then
		emit(ctx, { kind = "assign", names = { upvalName(proto, a) }, exprs = { { kind = "prim", v = PRI[d] } }, pc = pc })
	elseif op == INST.FNEW then
		local k = proto.kgc[d]
		local node
		if k and k.type == "child" then
			node = { kind = "func", proto = k.proto }
			-- The closure captures parent local slots by reference (uv entries with a
			-- `slot`). Those must be live NAMED locals when the closure is created --
			-- so materialize any still pending (e.g. a table constructor kept pending
			-- for field-folding, `local t = {...}; local f = function() ... t ... end`).
			-- Otherwise the constructor stays pending and inlines at its later read,
			-- leaving the closure's upvalue bound to nothing (an undeclared global).
			if k.proto.uv then
				for _, ref in pairs(k.proto.uv) do
					if ref.slot ~= nil then flushSlot(ctx, ref.slot, pc) end
				end
			end
		else
			node = { kind = "raw", text = "--[[proto?]] nil", prec = 0 }
		end
		storeSlot(ctx, a, pc, node)
	elseif op == INST.TNEW then
		storeConstructor(ctx, a, pc, { kind = "table", fields = {} })
	elseif op == INST.TDUP then
		local k = proto.kgc[d]
		local fields = k and k.type == "tab" and templateFields(k.value) or {}
		storeConstructor(ctx, a, pc, { kind = "table", fields = fields })
	elseif op == INST.GGET then
		storeSlot(ctx, a, pc, { kind = "global", name = kgcString(ctx, d) or "_G" })
	elseif op == INST.GSET then
		emit(ctx, { kind = "assign", names = { kgcString(ctx, d) or "?" }, exprs = { slotRef(ctx, a, pc) }, pc = pc })
	elseif op == INST.TGETV or op == INST.TGETR then
		storeSlot(ctx, a, pc, { kind = "index", obj = slotRef(ctx, b, pc), key = slotRef(ctx, c, pc) })
	elseif op == INST.TGETS then
		local key = kgcString(ctx, c) or "?"
		storeSlot(ctx, a, pc, { kind = "index", obj = slotRef(ctx, b, pc), key = constNode(key) })
		ctx.tgetsBase = ctx.tgetsBase or {}
		ctx.tgetsBase[a] = { base = b, key = key } -- remember method-func base
	elseif op == INST.TGETB then
		storeSlot(ctx, a, pc, { kind = "index", obj = slotRef(ctx, b, pc), key = constNode(c) })
	elseif op == INST.TSETV or op == INST.TSETR then
		-- Self-reference (`t[k] = t` / `t[t] = v`): materialize the table to a named
		-- local first, else reading it as the value/key consumes the pending
		-- constructor inline and leaves `t` undeclared.
		if a == b or c == b then flushSlot(ctx, b, pc) end
		local value = slotRef(ctx, a, pc)
		local key = slotRef(ctx, c, pc)
		local obj = slotRef(ctx, b, pc)
		emit(ctx, { kind = "setindex", obj = obj, key = key, value = value, pc = pc })
	elseif op == INST.TSETS or op == INST.TSETB then
		local key = op == INST.TSETS and (kgcString(ctx, c) or "?") or c
		-- Self-reference (`t.k = t`, the metatable `__index = self` idiom): the
		-- table must be a materialized local before it's read as the value, else
		-- slotRef consumes the pending constructor inline and `t` is left
		-- undeclared. Lua constructors can't self-reference, so never fold this.
		if a == b then flushSlot(ctx, b, pc) end
		-- Fold `t.x = v` into a pending constructor. The value is evaluated
		-- first (source order); it may itself flush the constructor (t.x = t),
		-- hence the re-check.
		local pendingTable = ctx.slots[b]
		local value = slotRef(ctx, a, pc)
		if pendingTable ~= nil and pendingTable.kind == "table" and ctx.slots[b] == pendingTable then
			-- This fold consumes one of the constructor's counted reads.
			local defPc = ctx.slotDefPc[b]
			if defPc then ctx.useCount[defPc] = (ctx.useCount[defPc] or 1) - 1 end
			local fields = pendingTable.fields
			if op == INST.TSETB then
				-- next array index -> positional element
				local positional = 0
				for i = 1, #fields do
					if fields[i].key == nil then positional = positional + 1 end
				end
				if key == positional + 1 then
					fields[#fields + 1] = { value = value }
					return
				end
			end
			-- replace an existing template field with the same key
			for i = 1, #fields do
				if fields[i].key == key then
					fields[i].value = value
					return
				end
			end
			fields[#fields + 1] = { key = key, value = value }
			return
		end
		emit(ctx, { kind = "setindex", obj = slotRef(ctx, b, pc), key = constNode(key), value = value, pc = pc })
	elseif op == INST.TSETM then
		local multi = ctx.multres or { kind = "vararg" }
		ctx.multres = nil
		local pendingTable = ctx.slots[a - 1]
		if pendingTable ~= nil and pendingTable.kind == "table" then
			local defPc = ctx.slotDefPc[a - 1]
			if defPc then ctx.useCount[defPc] = (ctx.useCount[defPc] or 1) - 1 end
			pendingTable.fields[#pendingTable.fields + 1] = { value = multi }
		else
			emit(ctx, {
				kind = "comment", pc = pc,
				text = "append multiple values to " .. renderExpr(slotRef(ctx, a - 1, pc), 0, ctx.rctx),
			})
		end
	elseif op == INST.CALL or op == INST.CALLM then
		local funcNode = slotRef(ctx, a, pc)
		local nargs = c - 1
		if op == INST.CALLM then nargs = c end
		local args = {}
		for i = 1, nargs do
			args[#args + 1] = slotRef(ctx, a + fr2 + i, pc)
		end
		if op == INST.CALLM then
			args[#args + 1] = ctx.multres or { kind = "vararg" }
			ctx.multres = nil
		end
		local method = detectMethodCall(ctx, a, fr2, funcNode, args)
		local callNode = { kind = "call", func = funcNode, args = args, method = method }
		local nrets = b - 1
		if b == 0 then
			callNode.multi = true
			ctx.multres = callNode
		elseif nrets == 0 then
			emit(ctx, { kind = "callstat", expr = callNode, pc = pc })
		elseif nrets == 1 then
			storeSlot(ctx, a, pc, callNode)
		else
			storeMulti(ctx, a, nrets, pc, callNode)
		end
	elseif op == INST.CALLT or op == INST.CALLMT then
		local funcNode = slotRef(ctx, a, pc)
		local nargs = d - 1
		if op == INST.CALLMT then nargs = d end
		local args = {}
		for i = 1, nargs do
			args[#args + 1] = slotRef(ctx, a + fr2 + i, pc)
		end
		if op == INST.CALLMT then
			args[#args + 1] = ctx.multres or { kind = "vararg" }
			ctx.multres = nil
		end
		local method = detectMethodCall(ctx, a, fr2, funcNode, args)
		emit(ctx, {
			kind = "return", pc = pc,
			exprs = { { kind = "call", func = funcNode, args = args, method = method } },
		})
	elseif op == INST.VARG then
		local nrets = b - 1
		if b == 0 then
			ctx.multres = { kind = "vararg", multi = true }
		elseif nrets > 0 then
			storeMulti(ctx, a, nrets, pc, { kind = "vararg" })
		end
		-- nrets == 0 (b == 1): vararg with all results discarded -- nothing to emit.
	elseif RETURN_OPS[op] then
		emit(ctx, buildReturnStmt(ctx, ins, pc))
	elseif op == INST.ISTYPE or op == INST.ISNUM then
		-- compiler-inserted type guards: no source equivalent
		return
	elseif COMPARE_OPS[op] or op == INST.IST or op == INST.ISF or op == INST.ISTC or op == INST.ISFC then
		-- Straight-line placeholder; the structurer consumes these.
		local cond = condExpr(ctx, ins, pc)
		local target = proto.ins[pc + 1] and proto.ins[pc + 1].j or "?"
		if op == INST.ISTC or op == INST.ISFC then
			flushSlot(ctx, a, pc)
		end
		emit(ctx, {
			kind = "comment", pc = pc,
			text = strfmt("if not (%s) then goto %s end", renderExpr(cond, 0, ctx.rctx), tostring(target)),
		})
	elseif op == INST.JMP or op == INST.UCLO then
		if ins.j and ins.j ~= pc + 1 then
			emit(ctx, { kind = "comment", text = "goto " .. strfmt("%04d", ins.j), pc = pc })
		end
	elseif op == INST.LOOP or op == INST.ILOOP or op == INST.JLOOP then
		emit(ctx, { kind = "comment", text = "loop", pc = pc })
	elseif op == INST.FORI or op == INST.JFORI then
		emit(ctx, { kind = "comment", text = "numeric for start", pc = pc })
	elseif op == INST.FORL or op == INST.IFORL or op == INST.JFORL then
		emit(ctx, { kind = "comment", text = "numeric for end", pc = pc })
	elseif op == INST.ITERC or op == INST.ITERN then
		emit(ctx, { kind = "comment", text = "iterator call", pc = pc })
	elseif op == INST.ITERL or op == INST.IITERL or op == INST.JITERL then
		emit(ctx, { kind = "comment", text = "iterator loop end", pc = pc })
	elseif op == INST.ISNEXT then
		emit(ctx, { kind = "comment", text = "iterator setup", pc = pc })
	else
		emit(ctx, { kind = "comment", text = "?" .. (OPNAMES[op] or op), pc = pc })
	end
end

-- LuaJIT lowers `obj:m(...)` to a self-copy MOV plus a method-lookup TGETS that
-- BOTH read the object slot:  <obj into rB>; MOV rSelf, rB; TGETS rF, rB, "m"; CALL.
-- Method sugar reprints the object once (as the `:m()` receiver), so the MOV's read
-- of the object is dropped from the output. Counting it would make the object look
-- used twice and force it into a temp (`local t = obj; t:m()`), which also blocks
-- folding into value-context expressions (`x and obj:m()` -> fallback). This finds
-- those self-copy MOV pcs so countUses can skip their (object) read and the MOV
-- handler can leave the object pending for the method-lookup TGETS to consume.
-- Mirrors the CALL-time detection in buildIns exactly (same movSrc/tgetsBase/key/
-- nargs gates) and requires the same object def to feed both reads, so we only skip
-- a read the renderer really drops.
-- Generic-for loops emit their body BEFORE the ITERC/ITERN header that (re)defines
-- the loop variables (the loop entry is a forward JMP/ISNEXT to that header). A
-- purely linear slot scan therefore misattributes a loop-var read in the body to
-- whatever last wrote that slot number *before* the loop -- inflating the pre-loop
-- def's use count and breaking single-use inlining. Precompute, per loop-entry pc,
-- the loop-var slots so the linear pre-passes can treat them as (re)defined at entry.
local function findLoopVarDefs(proto)
	local map = {}
	for pc = 1, #proto.ins do
		local ins = proto.ins[pc]
		local op = ins.op
		local iterPc
		if op == INST.ISNEXT then
			iterPc = ins.j
		elseif op == INST.JMP and ins.j and ins.j > pc then
			local t = proto.ins[ins.j]
			if t and (t.op == INST.ITERC or t.op == INST.ITERN) then iterPc = ins.j end
		end
		if iterPc and proto.ins[iterPc] then
			local iterIns = proto.ins[iterPc]
			local a = iterIns.a
			local count = iterIns.b - 1
			if count < 1 then count = 2 end
			local slots = {}
			for k = 0, count - 1 do slots[#slots + 1] = a + k end
			map[pc] = slots
		end
	end
	return map
end

-- An early `return obj:m(...)` in a function that has upvalues to close is compiled
-- as `UCLO => CALLT`: the tail call is emitted OUT OF LINE (usually at the very end,
-- after the body's RET0) and reached by a UCLO that first closes upvalues. The tail
-- call's operand slots are set up right before the UCLO but are reused by the body in
-- between, so a linear use-count scan credits the CALLT's operand reads to the body's
-- defs (leaving the real operands use-count 0 -> materialized as temps, method sugar
-- lost). Returns { targets = {[calltPc]=true}, uclos = {[ucloPc]=calltPc} } so
-- countUses can instead count those reads at the UCLO point and skip them at the CALLT.
local function findUcloTailCalls(proto)
	local targets, uclos = nil, nil
	for pc = 1, #proto.ins do
		local ins = proto.ins[pc]
		if ins.op == INST.UCLO and ins.j and ins.j ~= pc + 1 then
			local t = proto.ins[ins.j]
			if t and TAILCALL_OPS[t.op] then
				targets = targets or {}
				uclos = uclos or {}
				targets[ins.j] = true
				uclos[pc] = ins.j
			end
		end
	end
	if not targets then return nil end
	return { targets = targets, uclos = uclos }
end

local function findMethodSelfCopies(proto, fr2, fromPc, toPc, loopVarDefs)
	local elided = {}
	local movInfo, tgets, lastDef = {}, {}, {}
	for pc = fromPc, toPc do
		local ins = proto.ins[pc]
		local op = ins.op
		if op == INST.CALL or op == INST.CALLM or op == INST.CALLT or op == INST.CALLMT then
			local a = ins.a
			local mv = movInfo[a + fr2 + 1]
			local tg = tgets[a]
			-- CALL/CALLM take the fixed-arg count in C; CALLT/CALLMT (tail calls) in D.
			local fixed = (op == INST.CALL or op == INST.CALLM) and ins.c or ins.d
			local nargs = (op == INST.CALL or op == INST.CALLT) and fixed - 1 or fixed
			if mv and tg and mv.src == tg.base and mv.srcDef ~= nil
				and mv.srcDef == tg.baseDef and nargs >= 1 then
				elided[mv.pc] = true
			end
		end
		-- Capture read-defs BEFORE the write updates lastDef (a TGETS may reuse its
		-- own base slot as the destination: `TGETS rB, rB, "m"`).
		local newMov, newTgets
		if op == INST.MOV then
			newMov = { pc = pc, src = ins.d, srcDef = lastDef[ins.d] }
		elseif op == INST.TGETS then
			local k = proto.kgc[ins.c]
			if k and k.type == "str" and isSafeIdent(k.value) then
				newTgets = { base = ins.b, baseDef = lastDef[ins.b] }
			end
		end
		forEachSlot(ins, fr2,
			function(slot)
				movInfo[slot] = nil
				tgets[slot] = nil
			end,
			function(slot)
				lastDef[slot] = pc
				movInfo[slot] = nil
				tgets[slot] = nil
			end)
		if newMov then movInfo[ins.a] = newMov end
		if newTgets then tgets[ins.a] = newTgets end
		-- Loop vars are logically (re)defined at loop entry; record that here so
		-- body reads of them don't chain back to a pre-loop def of the same slot.
		local lv = loopVarDefs and loopVarDefs[pc]
		if lv then
			for i = 1, #lv do
				local s = lv[i]
				lastDef[s] = pc
				movInfo[s] = nil
				tgets[s] = nil
			end
		end
	end
	return elided
end

-- Use-count pre-pass over [fromPc, toPc]: for each defining pc, how many times
-- is that specific value read before being overwritten? Reads by method self-copy
-- MOVs (`skipReads[pc]`) don't count -- method sugar drops them (see above).
local function countUses(proto, fr2, fromPc, toPc, skipReads, loopVarDefs, ucloTail)
	local useCount, lastDef = {}, {}
	for pc = fromPc, toPc do
		local ins = proto.ins[pc]
		-- An out-of-line CALLT reached only via `UCLO => CALLT`: its operand reads
		-- belong at the UCLO, not here (its slots are reused by the body in between).
		local skip = (skipReads and skipReads[pc]) or (ucloTail and ucloTail.targets[pc])
		forEachSlot(ins, fr2,
			function(slot)
				if skip then return end
				local def = lastDef[slot]
				if def then useCount[def] = (useCount[def] or 0) + 1 end
			end,
			function(slot)
				lastDef[slot] = pc
				useCount[pc] = useCount[pc] or 0
			end)
		-- Count the tail call's operand reads here (against the operands' live defs),
		-- since we skipped them at the out-of-line CALLT above.
		local calltPc = ucloTail and ucloTail.uclos[pc]
		if calltPc then
			forEachSlot(proto.ins[calltPc], fr2,
				function(slot)
					local def = lastDef[slot]
					if def then useCount[def] = (useCount[def] or 0) + 1 end
				end,
				NOP)
		end
		-- Loop vars are logically (re)defined at loop entry (the ITERC header comes
		-- after the body linearly); attribute body reads of them here, not to a
		-- pre-loop def of the same slot.
		local lv = loopVarDefs and loopVarDefs[pc]
		if lv then
			for i = 1, #lv do lastDef[lv[i]] = pc end
		end
	end
	return useCount
end

--------------------------------------------------------------------------------
-- Statement rendering
--------------------------------------------------------------------------------

local function renderExprList(exprs, rctx)
	local parts = {}
	for i = 1, #exprs do
		parts[i] = renderExpr(exprs[i], 0, rctx)
	end
	return concat(parts, ", ")
end

local renderStatements -- forward

local function childRctx(rctx)
	return {
		indent = rctx.indent .. rctx.unit,
		unit = rctx.unit,
		hdr = rctx.hdr,
		depth = rctx.depth,
		formatValue = rctx.formatValue,
		fn = rctx.fn,
	}
end

-- Render an if, collapsing `else { if ... }` into `elseif`.
local function renderIf(stmt, out, rctx, lead)
	local indent = rctx.indent
	out[#out + 1] = indent .. lead .. renderExpr(stmt.cond, 0, rctx) .. " then"
	renderStatements(stmt.thenBody, out, childRctx(rctx))
	local elseBody = stmt.elseBody
	if elseBody and #elseBody == 1 and elseBody[1].kind == "if" then
		renderIf(elseBody[1], out, rctx, "elseif ")
	elseif elseBody and #elseBody > 0 then
		out[#out + 1] = indent .. "else"
		renderStatements(elseBody, out, childRctx(rctx))
		out[#out + 1] = indent .. "end"
	else
		out[#out + 1] = indent .. "end"
	end
end

local function renderStatement(stmt, out, rctx)
	local indent = rctx.indent
	local kind = stmt.kind
	if kind == "local" then
		local init = ""
		-- `local a, b, c` without "= nil, nil, nil" noise
		local allNil = true
		for i = 1, #stmt.exprs do
			local e = stmt.exprs[i]
			if not (e.kind == "prim" and e.v == "nil") then allNil = false break end
		end
		if #stmt.exprs > 0 and not allNil then
			init = " = " .. renderExprList(stmt.exprs, rctx)
		end
		out[#out + 1] = indent .. "local " .. concat(stmt.names, ", ") .. init
	elseif kind == "assign" then
		out[#out + 1] = indent .. concat(stmt.names, ", ") .. " = " .. renderExprList(stmt.exprs, rctx)
	elseif kind == "setindex" then
		local objText = renderExpr(stmt.obj, PREC_ATOM, rctx)
		if not isPrefixExpr(stmt.obj.kind) then
			objText = "(" .. objText .. ")"
		end
		local keyText
		if stmt.key.kind == "const" and isSafeIdent(stmt.key.v) then
			keyText = "." .. stmt.key.v
		else
			keyText = "[" .. renderExpr(stmt.key, 0, rctx) .. "]"
		end
		out[#out + 1] = indent .. objText .. keyText .. " = " .. renderExpr(stmt.value, 0, rctx)
	elseif kind == "callstat" then
		out[#out + 1] = indent .. renderExpr(stmt.expr, 0, rctx)
	elseif kind == "return" then
		if #stmt.exprs == 0 then
			out[#out + 1] = indent .. "return"
		else
			out[#out + 1] = indent .. "return " .. renderExprList(stmt.exprs, rctx)
		end
	elseif kind == "break" then
		out[#out + 1] = indent .. "break"
	elseif kind == "numfor" then
		local header = indent .. "for " .. stmt.var .. " = "
			.. renderExpr(stmt.startE, 0, rctx) .. ", " .. renderExpr(stmt.stopE, 0, rctx)
		if stmt.stepE then header = header .. ", " .. renderExpr(stmt.stepE, 0, rctx) end
		out[#out + 1] = header .. " do"
		renderStatements(stmt.body, out, childRctx(rctx))
		out[#out + 1] = indent .. "end"
	elseif kind == "genfor" then
		local iterText
		if stmt.iter.single then
			iterText = renderExpr(stmt.iter.single, 0, rctx)
		else
			local parts = {}
			for i = 1, #stmt.iter.triple do parts[i] = renderExpr(stmt.iter.triple[i], 0, rctx) end
			iterText = concat(parts, ", ")
		end
		out[#out + 1] = indent .. "for " .. concat(stmt.vars, ", ") .. " in " .. iterText .. " do"
		renderStatements(stmt.body, out, childRctx(rctx))
		out[#out + 1] = indent .. "end"
	elseif kind == "while" then
		out[#out + 1] = indent .. "while " .. renderExpr(stmt.cond, 0, rctx) .. " do"
		renderStatements(stmt.body, out, childRctx(rctx))
		out[#out + 1] = indent .. "end"
	elseif kind == "repeat" then
		out[#out + 1] = indent .. "repeat"
		renderStatements(stmt.body, out, childRctx(rctx))
		out[#out + 1] = indent .. "until " .. renderExpr(stmt.untilCond, 0, rctx)
	elseif kind == "if" then
		renderIf(stmt, out, rctx, "if ")
	elseif kind == "comment" then
		out[#out + 1] = indent .. "-- " .. commentSafe(stmt.text)
	else
		out[#out + 1] = indent .. "-- ?stmt:" .. tostring(kind)
	end
end

renderStatements = function(stmts, out, rctx)
	for i = 1, #stmts do
		renderStatement(stmts[i], out, rctx)
	end
end

--------------------------------------------------------------------------------
-- Control-flow structuring
--------------------------------------------------------------------------------

-- Logical negation of a boolean-valued node (for if-conditions and until).
local NEG_COMPARE = {
	["<"] = ">=", [">="] = "<", ["<="] = ">", [">"] = "<=", ["=="] = "~=", ["~="] = "==",
}
local function negate(node)
	if node.kind == "binop" and NEG_COMPARE[node.op] then
		return { kind = "binop", op = NEG_COMPARE[node.op], lhs = node.lhs, rhs = node.rhs }
	elseif node.kind == "binop" and node.op == "and" then
		return { kind = "binop", op = "or", lhs = negate(node.lhs), rhs = negate(node.rhs) } -- De Morgan
	elseif node.kind == "binop" and node.op == "or" then
		return { kind = "binop", op = "and", lhs = negate(node.lhs), rhs = negate(node.rhs) } -- De Morgan
	elseif node.kind == "unop" and node.op == "not" then
		return node.expr
	end
	return { kind = "unop", op = "not", expr = node }
end

local function isCmpOrTest(op)
	-- Tests usable as if-conditions: comparisons + IST/ISF (not the copying
	-- ISTC/ISFC, which are value-context short-circuits).
	return (op >= INST.ISLT and op <= INST.ISNEP) or op == INST.IST or op == INST.ISF
end
local function isLoopMark(op)
	return op == INST.LOOP or op == INST.ILOOP or op == INST.JLOOP
end

-- A test pair at `pc`: a comparison/test followed by its JMP -- the entry
-- precondition of every value-context recognizer.
local function isTestPairAt(proto, pc)
	local t, j = proto.ins[pc], proto.ins[pc + 1]
	return t ~= nil and j ~= nil and isCmpOrTest(t.op) and j.op == INST.JMP
end

-- Collect the run of (test; JMP) pairs at `pc` that form ONE short-circuit
-- condition. A single condition's tests all jump to exactly two sinks: the
-- fall-through past the run (TT, the then-block) for or-links, and one common
-- else/false target (FT) for and-links. A greedy maximal run can span two
-- unrelated conditions (e.g. an outer `if A then` whose test jumps past an
-- inner guard, followed by that guard) -- merging them yields a bogus
-- `A and B` and drops the nesting. So we take the longest PREFIX whose targets
-- fit the two-sink shape. Returns the test list and the pc after the run.
-- `noExpr` builds the shape (targets/pcs) without calling condExpr, so it has no
-- side effects on slot state -- required for speculative diamond detection, which
-- must be able to bail without having consumed any pending values.
local function collectTests(ctx, pc, noExpr)
	local proto = ctx.proto
	local raw = {}
	local p = pc
	while true do
		local t = proto.ins[p]
		local j = proto.ins[p + 1]
		if not (t and j and isCmpOrTest(t.op) and j.op == INST.JMP) then break end
		raw[#raw + 1] = { e = not noExpr and condExpr(ctx, t, p) or nil, target = j.j, pc = p }
		p = p + 2
	end
	if #raw <= 1 then
		return raw, pc + #raw * 2
	end
	-- Find the longest valid prefix (length n): with TT = pc after n tests and
	-- FT = the last test's target, every test must jump to TT or FT.
	for n = #raw, 1, -1 do
		local tt = pc + n * 2
		local ft = raw[n].target
		local ok = true
		for i = 1, n do
			if raw[i].target ~= tt and raw[i].target ~= ft then ok = false break end
		end
		if ok then
			local tests = {}
			for i = 1, n do tests[i] = raw[i] end
			return tests, pc + n * 2
		end
	end
	-- Shouldn't happen (n==1 always validates), but be safe.
	return { raw[1] }, pc + 2
end

-- Build an and/or expression tree from a test run, given the pc reached when
-- the whole condition is TRUE (thenTarget) and FALSE (elseTarget).
local function buildCondTree(tests, i, thenTarget)
	local t = tests[i]
	if i == #tests then
		if t.target == thenTarget then return t.e end
		return negate(t.e)
	end
	if t.target == thenTarget then
		return { kind = "binop", op = "or", lhs = t.e, rhs = buildCondTree(tests, i + 1, thenTarget) }
	end
	return { kind = "binop", op = "and", lhs = negate(t.e), rhs = buildCondTree(tests, i + 1, thenTarget) }
end

local structRegion, structAt -- forward
local collectGappedTests, gappedTestExpr -- forward (defined with the value-ladder)

-- Drive structAt over [lo, hi] into the CURRENT statement buffer, guarding
-- against non-progress. structRegion wraps this with a fresh buffer and a
-- trailing flush; the arm/guard builders call it directly so pending values
-- stay pending for their consumers.
local function structRange(ctx, lo, hi, loopExit)
	local pc = lo
	while pc <= hi do
		local nextPc = structAt(ctx, pc, hi, loopExit)
		pc = nextPc > pc and nextPc or pc + 1
	end
end

-- Bind a folded value-context result for slot `rs`. Named using the scope
-- active where the value is USED (the join), not the fold's own pc where the
-- local may not yet be declared: emit `local name = node` (an assignment when
-- the name's scope opened earlier). Unnamed results stay pending so their
-- single reader inlines them.
local function bindFoldedResult(ctx, rs, node, joinPc, pc)
	local name, entry = varnameAt(ctx.proto, joinPc, rs)
	if name and name:sub(1, 1) ~= "(" then
		emit(ctx, {
			kind = entry.startpc == joinPc and "local" or "assign",
			names = { name }, exprs = { node }, pc = pc,
		})
		setPending(ctx, rs, nil)
	else
		setPending(ctx, rs, node)
	end
end

local function flushAll(ctx, pc)
	for slot = 0, ctx.proto.framesize do
		if ctx.slots[slot] ~= nil then flushSlot(ctx, slot, pc) end
	end
	ctx.multres = nil
end

-- At the entry of the loop headed at `lo`, give each of its loop-carried slots a
-- stable home BEFORE the body: flush any pending incoming value (materializing e.g.
-- `local x = <init>` or a pre-loop table constructor into the enclosing block), and
-- mark the home declared so in-loop updates render as assignments (storeSlot). Slots
-- whose incoming value is already a statement (named locals, params) flush to nothing
-- but are still declared. Must be called while ctx.stmts is the ENCLOSING block, so
-- the declarations land outside the loop body.
local function declareCarriedHomes(ctx, lo, pc)
	local ranges = ctx.carriedRanges
	if not ranges then return end
	ctx.homeDeclared = ctx.homeDeclared or {}
	for i = 1, #ranges do
		local r = ranges[i]
		if r.lo == lo then
			for slot in pairs(r.slots) do
				if ctx.slots[slot] ~= nil then flushSlot(ctx, slot, pc) end
				ctx.homeDeclared[slot] = true
			end
		end
	end
end

-- Numeric for: FORI at `pc`, matching FORL at ins.j-1. Returns next pc.
-- (No loopExit param: the body's breaks target THIS loop's own exit.)
local function structNumericFor(ctx, pc)
	local proto = ctx.proto
	local ins = proto.ins[pc]
	local a = ins.a
	local exit = ins.j
	local forlPc = exit - 1
	local bodyLo, bodyHi = pc + 1, forlPc - 1
	local startE = slotRef(ctx, a, pc)
	local stopE = slotRef(ctx, a + 1, pc)
	local stepE = slotRef(ctx, a + 2, pc)
	flushAll(ctx, pc)
	local varName = varnameAt(proto, bodyLo, a + 3) or ("slot" .. (a + 3))
	if varName:sub(1, 1) == "(" then varName = "slot" .. (a + 3) end
	-- Inside the loop the region exit is the back-edge/loopExit, not any enclosing if's
	-- join; clear regionExit so a body JMP can't be mis-read against a stale outer join.
	local savedExit = ctx.regionExit
	ctx.regionExit = nil
	local body = structRegion(ctx, bodyLo, bodyHi, exit)
	ctx.regionExit = savedExit
	-- Omit an explicit `, 1` step. (Note: `cond and nil or x` can't express
	-- this — `and nil` is always falsy — so branch explicitly.)
	if stepE.kind == "const" and stepE.v == 1 then stepE = nil end
	emit(ctx, {
		kind = "numfor", var = varName, startE = startE, stopE = stopE,
		stepE = stepE, body = body, pc = pc,
	})
	return exit
end

-- Generic for: ISNEXT/JMP guard at `pc` pointing to ITERC/ITERN. Returns next pc.
-- (No loopExit param: the body's breaks target THIS loop's own exit.)
local function structGenericFor(ctx, pc)
	local proto = ctx.proto
	local ins = proto.ins[pc]
	local iterPc = ins.j
	local exit = iterPc + 2
	local iterIns = proto.ins[iterPc]
	local a = iterIns.a
	local count = iterIns.b - 1
	if count < 1 then count = 2 end
	local bodyLo = pc + 1
	local bodyHi = iterPc - 1

	-- Iterator source: prefer the call that produced the (gen, state, ctl)
	-- triple in slots a-3..a-1, popping that statement so it isn't duplicated.
	local iterExpr
	local lm = ctx.lastMulti
	if lm and lm.base == a - 3 and lm.stmtIndex == #ctx.stmts then
		iterExpr = { single = lm.expr }
		ctx.stmts[#ctx.stmts] = nil
	else
		iterExpr = { triple = { slotRef(ctx, a - 3, pc), slotRef(ctx, a - 2, pc), slotRef(ctx, a - 1, pc) } }
	end
	flushAll(ctx, pc)

	local vars = {}
	for k = 0, count - 1 do
		local name = varnameAt(proto, bodyLo, a + k)
		if not name or name:sub(1, 1) == "(" then name = "slot" .. (a + k) end
		vars[#vars + 1] = name
		ctx.slotDefPc[a + k] = pc
	end
	local savedExit = ctx.regionExit
	ctx.regionExit = nil
	local body = structRegion(ctx, bodyLo, bodyHi, exit)
	ctx.regionExit = savedExit
	emit(ctx, { kind = "genfor", vars = vars, iter = iterExpr, body = body, pc = pc })
	return exit
end

-- while/repeat starting at back-edge target `s`; `e` is the back-edge JMP pc.
-- (No loopExit param: the body's breaks target THIS loop's own exit.)
local function structLoop(ctx, s, e)
	local proto = ctx.proto
	-- Root this loop's carried variables to a home in the enclosing block before the
	-- body is built, so their in-loop updates become assignments to it rather than
	-- inlined-away temporaries.
	declareCarriedHomes(ctx, s, s)
	local exit = e + 1
	if isLoopMark(proto.ins[s].op) then
		-- repeat: LOOP at start, condition run ends at the back-edge JMP `e`.
		exit = proto.ins[s].j
		-- Find the condition run ending at e (JMP) working backwards.
		local runStart = e
		while true do
			local testPc = runStart - 1
			if testPc >= s + 1 and isCmpOrTest(proto.ins[testPc].op) and proto.ins[runStart] and proto.ins[runStart].op == INST.JMP then
				runStart = testPc
				local prevJmp = testPc - 1
				if prevJmp >= s + 1 and proto.ins[prevJmp] and proto.ins[prevJmp].op == INST.JMP
					and isCmpOrTest(proto.ins[prevJmp - 1].op) then
					runStart = prevJmp
				else
					break
				end
			else
				break
			end
		end
		-- Build the body first (without the trailing flush) so any constant
		-- loads feeding the until-condition stay pending for condExpr to consume.
		local savedStmts = ctx.stmts
		local body = {}
		ctx.stmts = body
		structRange(ctx, s + 1, runStart - 1, exit)
		ctx.stmts = savedStmts

		local tests = {}
		local p = runStart
		while p < e do
			tests[#tests + 1] = { e = condExpr(ctx, proto.ins[p], p), target = proto.ins[p + 1].j, pc = p }
			p = p + 2
		end
		flushAll(ctx, e)
		if #tests == 0 then
			-- No exit condition on the back-edge: this is `while true do ... end`
			-- (breaks live inside the body). repeat/until true would run once.
			emit(ctx, { kind = "while", cond = { kind = "prim", v = "true" }, body = body, pc = s })
		else
			-- back-edge fires (target s) when the loop should continue.
			local untilCond = negate(buildCondTree(tests, 1, s))
			emit(ctx, { kind = "repeat", body = body, untilCond = untilCond, pc = s })
		end
		return exit
	end

	-- while: condition run at [s, loopPc-1], LOOP at loopPc, body after.
	local loopPc
	for p = s, e do
		if isLoopMark(proto.ins[p].op) then loopPc = p break end
	end
	if not loopPc then
		error("while loop without LOOP marker", 0)
	end
	exit = proto.ins[loopPc].j
	-- The condition spans [s, loopPc-1]: comparison/test setup (constant loads)
	-- interleaved with the guard test+JMP pairs. Build setup instructions so
	-- their values become pending for the tests to consume; collect the tests.
	local tests = {}
	local p = s
	while p < loopPc do
		if isCmpOrTest(proto.ins[p].op) and proto.ins[p + 1] and proto.ins[p + 1].op == INST.JMP then
			tests[#tests + 1] = { e = condExpr(ctx, proto.ins[p], p), target = proto.ins[p + 1].j, pc = p }
			p = p + 2
		else
			buildIns(ctx, p)
			p = p + 1
		end
	end
	local cond
	if #tests > 0 then
		cond = buildCondTree(tests, 1, loopPc) -- TRUE => fall to LOOP => body
	else
		cond = { kind = "prim", v = "true" }
	end
	flushAll(ctx, s)
	-- A jump back to the header `s` from inside the body is a continue (re-check the
	-- condition), not a goto; structIf turns `if x then <continue> end; REST` into
	-- `if x then <then> else REST end`. Thread the continue target through the body.
	local savedCont = ctx.loopCont
	local savedExit = ctx.regionExit
	ctx.loopCont = s
	ctx.regionExit = nil
	local body = structRegion(ctx, loopPc + 1, e - 1, exit)
	ctx.loopCont = savedCont
	ctx.regionExit = savedExit
	emit(ctx, { kind = "while", cond = cond, body = body, pc = s })
	return exit
end

-- if / if-else / elseif starting at a test at `pc`. Returns next pc.
-- A forward jump is a `break` when it lands on the loop exit -- OR on wherever the
-- exit itself forwards to via a chain of unconditional JMPs. LuaJIT frequently
-- shortcuts a break straight past the loop's immediate exit to a shared join (the
-- exit is itself the skip-JMP of an enclosing if/else), so `target == loopExit` alone
-- misses it. BigNum.change: a `for..do if x then break end .. end`'s break jumps to
-- the join after the surrounding if/else, not to the loop's own exit instruction.
local function isBreakTo(proto, target, loopExit)
	if not (target and loopExit) then return false end
	if target == loopExit then return true end
	local p, seen = loopExit, {}
	while proto.ins[p] and proto.ins[p].op == INST.JMP and proto.ins[p].j and not seen[p] do
		seen[p] = true
		p = proto.ins[p].j
		if p == target then return true end
	end
	return false
end

local function structIf(ctx, pc, regionHi, loopExit)
	local proto = ctx.proto
	local tests, thenStart = collectTests(ctx, pc)
	-- collectTests only chains ADJACENT tests, so a compound condition whose later
	-- operands are computed by calls (`f(x) and g(y)`, `isentity(o) and IsValid(o)`)
	-- yields just the first test -- the rest then mis-structure as nested ifs, which
	-- turns the then-body's skip JMP into a `goto` (fallback) OR silently drops the
	-- first-true/second-false path (wrong output). Extend across the operand gaps so
	-- the whole condition folds into one and/or tree. tests[1].e is already built from
	-- the pending operands; build the rest with their operand regions isolated.
	local gtests, gThenStart = collectGappedTests(ctx, pc)
	if gtests and #gtests > #tests then
		local ext, okExt = { tests[1] }, true
		for i = 2, #gtests do
			local t = gtests[i]
			local gt = t.opLo and gappedTestExpr(ctx, t.cmpPc, t.opLo, t.opHi, t.target, loopExit)
			if not gt then okExt = false break end
			ext[i] = { e = gt.e, target = t.target, pc = t.cmpPc }
		end
		if okExt then tests, thenStart = ext, gThenStart end
	end
	local ft = tests[#tests].target
	local cond = buildCondTree(tests, 1, thenStart)
	flushAll(ctx, pc)

	-- if-else? The then-block ends with a JMP that either skips forward past the
	-- else region, or jumps back to the loop header (a continue that skips the rest
	-- of the body): `if x then <then> continue end; REST` == `if x then <then> else
	-- REST end` per iteration, since the continue re-checks the loop condition and
	-- REST is everything left in the body.
	local jmpPc = ft - 1
	local elseBody, next
	local thenHi
	local jmpIns = proto.ins[jmpPc]
	-- The then-arm's skip is a JMP, or a JUMPING UCLO when the arm exits a scope with
	-- captured locals -- GMod's `continue` compiles to `UCLO => back-edge` (the loop's
	-- continue point), so a bare `if not x then continue end` lands a UCLO here, not a
	-- JMP. Treat both alike (their `.j` is the target).
	local jmpTgt
	if jmpIns then
		if jmpIns.op == INST.JMP then
			jmpTgt = jmpIns.j
		elseif jmpIns.op == INST.UCLO and jmpIns.j and jmpIns.j ~= jmpPc + 1 then
			-- A jumping UCLO is only a skip/continue when it lands on a normal
			-- instruction (the loop back-edge / join). `UCLO => RET*/CALLT*` is an early
			-- return or out-of-line tail call -- structAt owns those; don't steal them.
			local tOp = proto.ins[jmpIns.j] and proto.ins[jmpIns.j].op
			if not (RETURN_OPS[tOp] or TAILCALL_OPS[tOp]) then
				jmpTgt = jmpIns.j
			end
		end
	end
	-- The skip may target a join BEYOND this region when we are ourselves an arm of an
	-- enclosing if: an if/elseif ladder that is the whole then-body of an outer if has
	-- every arm jump to the OUTER join (elseif-ladder-with-shared-tail). ctx.regionExit
	-- carries that enclosing join down, so such a jump is still recognised as an if/else
	-- skip rather than an unstructured goto.
	local forwardSkip = jmpTgt and jmpTgt > ft
		and jmpPc >= thenStart and (jmpTgt <= regionHi + 1 or jmpTgt == ctx.regionExit)
		and jmpTgt ~= loopExit
	local continueSkip = jmpTgt and jmpPc >= thenStart
		and ctx.loopCont and jmpTgt == ctx.loopCont
	if forwardSkip or continueSkip then
		thenHi = jmpPc - 1
		-- Publish the shared join so nested ladders inside either arm resolve their own
		-- skip-JMPs to it. Clamp the else region + returned continuation to this region:
		-- when the join is beyond it (inherited via regionExit), the instructions between
		-- regionHi and the join belong to the enclosing structure, not our else.
		local join = forwardSkip and jmpTgt or (regionHi + 1)
		local savedExit = ctx.regionExit
		ctx.regionExit = join
		local thenBody = structRegion(ctx, thenStart, thenHi, loopExit)
		local elseHi = forwardSkip and (jmpTgt - 1) or regionHi
		if elseHi > regionHi then elseHi = regionHi end
		elseBody = structRegion(ctx, ft, elseHi, loopExit)
		ctx.regionExit = savedExit
		next = join <= regionHi + 1 and join or (regionHi + 1)
		emit(ctx, { kind = "if", cond = cond, thenBody = thenBody, elseBody = elseBody, pc = pc })
		return next
	end

	-- plain if (then falls through to ft). `ft` can point PAST this region: a nested
	-- if whose false path jumps to a shared exit beyond the current body (e.g. the loop
	-- back-edge / end of an enclosing then-arm, as in `for..do if a then if b then ...`).
	-- Clamp the then-body to regionHi so it doesn't swallow instructions that belong to
	-- the enclosing structure, and hand control back at the region boundary.
	thenHi = ft - 1
	if thenHi > regionHi then thenHi = regionHi end
	local savedExit = ctx.regionExit
	ctx.regionExit = ft -- nested arms may skip to this if's join
	local thenBody = structRegion(ctx, thenStart, thenHi, loopExit)
	ctx.regionExit = savedExit
	emit(ctx, { kind = "if", cond = cond, thenBody = thenBody, pc = pc })
	return ft <= regionHi + 1 and ft or (regionHi + 1)
end

-- Is `slot` read at/after `fromPc` before being overwritten (linear scan)? A
-- value's result is often consumed several instructions past its join, not by
-- the join instruction itself (chained booleans `local p = a==b ... return p`, or
-- `x = x or 0` where `x` is used later). Both the diamond recogniser and the
-- value short-circuit key on this rather than "the join instruction reads it".
-- Scans to the first read (live) or write (dead) of the slot. No fixed window: a
-- fixed cap wrongly reported "dead" for a result whose read is far away -- e.g. the
-- first of N parallel value-diamonds all consumed by one trailing RET (`return
-- A == 0, B == 0, ...`, Wire logic gates), where the first result's read is ~5N
-- instructions past its join. Cost is bounded by the distance to that read, which is
-- small in practice; worst case O(n) per call is fine for realistic proto sizes.
local function slotLiveAt(proto, fr2, fromPc, slot)
	local n = #proto.ins
	-- Callbacks hoisted out of the scan loop (they escape into forEachSlot, so LuaJIT
	-- can't sink them): allocate once, reset the flags each instruction via upvalues.
	local reads, writes
	local function rd(s) if s == slot then reads = true end end
	local function wr(s) if s == slot then writes = true end end
	local p = fromPc
	while p <= n do
		reads, writes = false, false
		forEachSlot(proto.ins[p], fr2, rd, wr)
		if reads then return true end
		if writes then
			-- A write only KILLS the slot if it's unconditional. A (re)assignment inside
			-- a conditional block (`local d = a or 2; if c then d = f() end; use(d)`) is
			-- skipped on the fall-through path, where the earlier value still reaches a
			-- later read -- so the slot is live. Detect the guard: some branch since
			-- `fromPc` jumps PAST this write; if so, skip the conditional block and keep
			-- scanning at its join. Without this the linear scan reported the value dead
			-- and its `x or y` short-circuit mis-structured into a scope-escaping if.
			local skipTo
			for q = fromPc, p - 1 do
				local qi = proto.ins[q]
				if qi.op == INST.JMP and qi.j and qi.j > p then skipTo = qi.j break end
			end
			if not skipTo then return false end
			p = skipTo
		else
			p = p + 1
		end
	end
	return false
end

-- Recognize a value-context short-circuit led by a plain IST/ISF: the tested
-- slot is also the result (`x = x or <rest>` / `x = x and <rest>`), the rest
-- region is straight-line (no returns/jumps), and the slot is live at the join.
local function isValueShortCircuit(ctx, pc, regionHi)
	local proto = ctx.proto
	local ins = proto.ins[pc]
	if not (ins.op == INST.IST or ins.op == INST.ISF) then return false end
	local jmp = proto.ins[pc + 1]
	if not (jmp and jmp.op == INST.JMP and jmp.j and jmp.j > pc + 1) then return false end
	local target = jmp.j
	local d = ins.d
	-- Inside a diamond arm the short-circuit's kept-value path jumps to the OUTER
	-- join (> regionHi), skipping the other arms; the rest is only [pc+2, regionHi].
	-- Clip the scan to the arm so we validate the nested short-circuit against the
	-- arm's own instructions (structShortCircuit clips the rest identically).
	local scanHi = target - 1
	if regionHi and pc + 2 <= regionHi and scanHi > regionHi then scanHi = regionHi end
	for p = pc + 2, scanHi do
		local rp = proto.ins[p]
		local op = rp.op
		if RETURN_OPS[op] or TAILCALL_OPS[op]
			or op == INST.FORI or op == INST.FORL or isLoopMark(op) then
			return false
		end
		-- A JMP that stays within the region (<= target) is a nested value diamond's
		-- bridge -- the rest computation may itself be `a == b` / `c and d`. A jump
		-- OUT (break/goto/return) means this isn't a clean value short-circuit.
		if op == INST.JMP and (not rp.j or rp.j <= pc or rp.j > target) then return false end
	end
	return proto.ins[target] ~= nil and slotLiveAt(proto, ctx.fr2, target, d)
end

-- Value-context short-circuit. ISTC/ISFC A,D give `A = D or/and <rest>`; plain
-- IST/ISF D give `D = D or/and <rest>` (result slot is the tested slot). The
-- <rest> is computed in [pc+2, target-1]. Returns next pc.
local function structShortCircuit(ctx, pc, loopExit, regionHi)
	local proto = ctx.proto
	local ins = proto.ins[pc]
	local op = ins.op
	local a, d = ins.a, ins.d
	local deferrable = op == INST.IST or op == INST.ISF
	if deferrable then
		a = d -- result and tested slot coincide
	end
	local target = proto.ins[pc + 1].j
	-- Inside a diamond arm (`cond and (v1 and v2)`) the kept-value path jumps to the
	-- outer join beyond this arm; the rest is only the arm's remaining instructions.
	-- Clip and let the folded `first <op> rest` stay pending so structArmValue picks
	-- it up as the arm's value. `endPc` is where control resumes after the fold.
	-- Clip only when the rest STARTS inside the arm but converges beyond it. If it
	-- starts beyond regionHi, the rest is the outer diamond's shared else arm (the
	-- `a and b or c` idiom, where `c` is both the `or` tail and the else) -- leave it
	-- to the full-target path so that shared value isn't lost.
	local restHi = target - 1
	local clipped = false
	if regionHi and pc + 2 <= regionHi and restHi > regionHi then
		restHi = regionHi
		clipped = true
	end
	local endPc = clipped and (regionHi + 1) or target

	-- Snapshot slots/pendingReads/stmts-length so a deferrable (IST/ISF)
	-- short-circuit can bail cleanly. `first` (the tested value) is captured before
	-- the rest overwrites slot A -- against the LIVE slot state, so it and the rest
	-- can read values pending from before `pc` (`return p and q`). The rest is
	-- structured into a separate buffer; if it doesn't reduce to a single value we
	-- roll back everything and let the caller fall through to structIf.
	local savedStmts = ctx.stmts
	local savedLen = #savedStmts
	local snapSlots = shallowCopy(ctx.slots)
	local snapReads = ctx.pendingReads and shallowCopy(ctx.pendingReads) or nil
	local savedMulti = ctx.multres
	local first = slotRef(ctx, d, pc)

	local restStmts = {}
	ctx.stmts = restStmts
	structRange(ctx, pc + 2, restHi, loopExit)
	ctx.stmts = savedStmts
	-- A flushAll deep in the rest arm (e.g. a nested value diamond as the rest,
	-- `x = a and (b == c)`) spills whatever was pending BEFORE this short-circuit --
	-- a preceding `local t = {...}`, a call being assembled -- into the arm buffer.
	-- Those statements aren't part of the conditional rest arm; their def pc precedes
	-- the short-circuit, so they belong in the enclosing scope, before the binding.
	-- Keeping them in the arm buffer would defeat the clean-value check below and
	-- drop the short-circuit binding entirely. Separate the pre-existing spills
	-- (hoist before the binding) from any genuine in-arm statements (`leaked`).
	local hoisted, leaked = {}, {}
	for _, st in ipairs(restStmts) do
		if st.pc and st.pc < pc then hoisted[#hoisted + 1] = st else leaked[#leaked + 1] = st end
	end
	local restExpr = ctx.slots[a]
	if restExpr ~= nil then
		setPending(ctx, a, nil)
	elseif #leaked == 1 then
		-- The alternative branch assigned slot A as a named statement; recover
		-- its value so we can fold it into the short-circuit expression.
		local st = leaked[1]
		if (st.kind == "local" or st.kind == "assign") and #st.exprs == 1 and #st.names == 1 then
			restExpr = st.exprs[1]
			leaked = {}
		end
	end
	local clean = restExpr ~= nil and #leaked == 0

	if not clean then
		-- The rest may reduce to a value PLUS helper statements -- e.g. a nested value
		-- diamond whose arithmetic operand spilled a temp
		-- (`x = A or (i%2==0 and 1 or -1)` -> `local tmp=i%2; local x=tmp==0 and 1 or -1`),
		-- or an and/or-chain rest whose CALL operand was flushed by structValueAndOrChain
		-- (`ring.dir = rd or (math_random()>0.5 and 1 or -1)`, Ring.new). Flushing that call
		-- ahead of the short-circuit would reorder its side effect, and structIf would
		-- scope-escape the result -- so emit a hoisted short-circuit instead:
		--   local x = A ; if <not x (or) / x (and)> then <helpers> ; x = REST end
		-- which runs the helpers only on the short-circuit path (never reordering the call)
		-- and is always scope-sound. The guard references the RESULT by name (it never
		-- re-evaluates `first`). Works for all four ops; the result is named from varinfo
		-- where available, else a synthetic. Skip inside a clipped arm (the outer diamond
		-- owns the result there).
		local resName, resEntry = varnameAt(proto, target, a)
		if not (resName and resName:sub(1, 1) ~= "(") then resName, resEntry = nil, nil end
		local restValue, helpers = nil, {}
		if not clipped then
			for _, st in ipairs(leaked) do
				if resName and (st.kind == "local" or st.kind == "assign") and #st.names == 1
					and #st.exprs == 1 and st.names[1] == resName then
					restValue = st.exprs[1] -- the result binding; last such wins
				else
					helpers[#helpers + 1] = st
				end
			end
			if restValue == nil and restExpr ~= nil then restValue = restExpr end
		end
		if restValue ~= nil then
			for _, st in ipairs(hoisted) do ctx.stmts[#ctx.stmts + 1] = st end
			local name = resName or freshSynth(ctx, a)
			local preexisting = resName and resEntry and resEntry.startpc and resEntry.startpc < pc
			emit(ctx, { kind = preexisting and "assign" or "local",
				names = { name }, exprs = { first }, pc = pc })
			local ref = { kind = "localref", name = name, slot = a }
			local isOr = op == INST.IST or op == INST.ISTC
			local body = {}
			for _, st in ipairs(helpers) do body[#body + 1] = st end
			body[#body + 1] = { kind = "assign", names = { name }, exprs = { restValue }, pc = pc }
			emit(ctx, { kind = "if", cond = isOr and negate(ref) or ref, thenBody = body, pc = pc })
			setPending(ctx, a, nil)
			ctx.curName = ctx.curName or {}
			ctx.curName[a] = name
			ctx.slotDefPc[a] = pc
			return target
		end
		if deferrable then
			-- Roll back slots/reads/multres and drop any statement `first` flushed,
			-- so the caller can retry with structIf on a pristine context.
			ctx.slots = snapSlots
			ctx.pendingReads = snapReads
			ctx.multres = savedMulti
			for i = #savedStmts, savedLen + 1, -1 do savedStmts[i] = nil end
			return nil
		end
		-- ISTC/ISFC with genuine non-value statements: emit the rest honestly.
		for _, st in ipairs(restStmts) do ctx.stmts[#ctx.stmts + 1] = st end
		flushAll(ctx, endPc)
		return endPc
	end
	-- Emit the hoisted pre-existing spills into the enclosing scope, in order,
	-- before the short-circuit binding lands.
	for _, st in ipairs(hoisted) do ctx.stmts[#ctx.stmts + 1] = st end
	local isOr = op == INST.ISTC or op == INST.IST
	local node = { kind = "binop", op = isOr and "or" or "and", lhs = first, rhs = restExpr }
	invalidateReaders(ctx, a, endPc)
	-- The folded result's use-count must reflect the join's real reads. Pointing
	-- slotDefPc at `pc` (the ISTC) is wrong: the rest arm overwrites slot `a` before
	-- the join reads it, so countUses attributes that read to the rest's LAST write,
	-- leaving useCount[pc] == 0 -- slotRef then treats the pending value as dead and
	-- spills it to `local tmp = origin or V(); foo(tmp)` instead of inlining
	-- `foo(origin or V())`. Worse, that stray statement makes structArmValue reject
	-- the arm (it must reduce to exactly one value), forcing a fallback when the
	-- short-circuit is a call argument inside an `or` chain. Point slotDefPc at the
	-- rest's last write so the use-count is right and the value inlines.
	local defPc = pc
	local curP
	local function wr(s) if s == a then defPc = curP end end
	for p = pc + 2, restHi do
		curP = p
		forEachSlot(proto.ins[p], ctx.fr2, NOP, wr)
	end
	ctx.slotDefPc[a] = defPc
	-- Clipped (inside an arm): keep the folded value pending so structArmValue takes
	-- it as the arm's single value; the outer diamond names/reads it at the join.
	if clipped then
		setPending(ctx, a, node)
		return endPc
	end
	bindFoldedResult(ctx, a, node, target, pc)
	return target
end

--------------------------------------------------------------------------------
-- Value-context conditional (diamond) reconstruction
--------------------------------------------------------------------------------
-- A boolean/value produced by a two-armed conditional that rejoins and is read
-- afterwards, e.g. `x = a == b` (both arms KPRI true/false), `x = c and 5 or 10`,
-- or `x = c and f() or g()`. LuaJIT emits this as a diamond:
--     <test>; JMP=>ELSE
--     <then arm: writes RS>; JMP=>JOIN
--   ELSE:
--     <else arm: writes RS>
--   JOIN: <reads RS>
-- structIf would reconstruct it as an `if` whose arms each declare a branch-local
-- RS that is read after the block -- a scope escape the validator rejects,
-- forcing a fallback to the raw listing. Here we fold the diamond into a value:
-- boolean collapse (`x = cond` / `x = not cond`), a short-circuit ternary when
-- the then-value is provably truthy (`cond and A or B`), or, failing those, a
-- hoisted `local RS; if cond then RS = A else RS = B end` (always sound).

-- Hard control flow that a value arm can never contain: early exits, tailcalls,
-- loops and iterators. Plain JMP/UCLO are deliberately NOT here -- an arm may be
-- (or contain) a nested value diamond, whose bridging JMPs are fine; structArmValue
-- is the real gate (it refuses any arm that doesn't reduce to exactly one value,
-- so a stray break/goto/return inside an arm still bails cleanly).
local DIAMOND_STOP = {
	[INST.RET0] = true, [INST.RET1] = true, [INST.RET] = true, [INST.RETM] = true,
	[INST.CALLT] = true, [INST.CALLMT] = true,
	[INST.FORI] = true, [INST.JFORI] = true,
	[INST.FORL] = true, [INST.IFORL] = true, [INST.JFORL] = true,
	[INST.LOOP] = true, [INST.ILOOP] = true, [INST.JLOOP] = true,
	[INST.ITERC] = true, [INST.ITERN] = true, [INST.ISNEXT] = true,
	[INST.ITERL] = true, [INST.IITERL] = true, [INST.JITERL] = true,
}

local ARITH_STR = { ["+"] = true, ["-"] = true, ["*"] = true, ["/"] = true, ["%"] = true, ["^"] = true }

-- An expression whose value is guaranteed truthy (never false/nil), so it can be
-- the middle term of `cond and A or B` without the classic and/or footgun.
local function isTruthyExpr(node)
	local k = node.kind
	if k == "const" or k == "table" or k == "func" or k == "concat" then
		return true -- numbers/strings (incl. 0 and "") and tables/functions are truthy
	elseif k == "prim" then
		return node.v == "true"
	elseif k == "unop" then
		return node.op == "#" or node.op == "-" -- length/negation yield numbers
	elseif k == "binop" then
		return ARITH_STR[node.op] == true -- arithmetic yields a number
	end
	return false
end

-- Does `node` always evaluate to a boolean (true/false)? Used to license the
-- `cond and true or Y` -> `cond or Y` / `cond and X or false` -> `cond and X`
-- simplifications, which only hold when `cond` can't be an arbitrary truthy value.
local function isBooleanExpr(node)
	local k = node.kind
	if k == "unop" and node.op == "not" then return true end
	if k == "prim" then return node.v == "true" or node.v == "false" end
	if k == "binop" then
		if NEG_COMPARE[node.op] then return true end
		if node.op == "and" or node.op == "or" then
			return isBooleanExpr(node.lhs) and isBooleanExpr(node.rhs)
		end
	end
	return false
end

local function regionWrites(proto, fr2, lo, hi, set)
	local function wr(s) set[s] = true end
	for p = lo, hi do
		forEachSlot(proto.ins[p], fr2, NOP, wr)
	end
end

local function lastWriteOf(proto, fr2, lo, hi, slot)
	local last, cur
	local function wr(s) if s == slot then last = cur end end
	for p = lo, hi do
		cur = p
		forEachSlot(proto.ins[p], fr2, NOP, wr)
	end
	return last
end

local function regionStraightLine(proto, lo, hi)
	for p = lo, hi do
		if DIAMOND_STOP[proto.ins[p].op] then return false end
	end
	return true
end

-- The diamond/ladder result slot: written by BOTH arms and still live at the
-- join. Must be unique -- more than one shared live slot means this isn't a
-- value diamond. Returns the slot, or nil (none, or ambiguous).
local function sharedLiveResult(ctx, thenLo, thenHi, elseLo, elseHi, join)
	local proto = ctx.proto
	local tw, ew = {}, {}
	regionWrites(proto, ctx.fr2, thenLo, thenHi, tw)
	regionWrites(proto, ctx.fr2, elseLo, elseHi, ew)
	local rs
	for slot in pairs(tw) do
		if ew[slot] and slotLiveAt(proto, ctx.fr2, join, slot) then
			if rs ~= nil then return nil end
			rs = slot
		end
	end
	return rs
end

-- Is [lo, hi] an unreachable tail of constant-materialization writes to `rs`? This
-- is LuaJIT's `cond and VALUE` template: the comparison's true-arm is redirected to
-- compute VALUE, orphaning the `KPRI rs, true` it would otherwise have emitted after
-- the else arm's `KPRI rs, false; JMP=>join`. Safe to drop only if nothing jumps in.
local CONST_LOAD = {
	[INST.KPRI] = true, [INST.KSHORT] = true, [INST.KNUM] = true,
	[INST.KSTR] = true, [INST.KNIL] = true,
}
local function isDeadConstTail(proto, lo, hi, rs)
	if hi < lo then return false end
	for p = lo, hi do
		local pi = proto.ins[p]
		if not CONST_LOAD[pi.op] or pi.a ~= rs then return false end
	end
	for p = 1, #proto.ins do
		if (p < lo or p > hi) then
			local t = proto.ins[p].j
			if t and t >= lo and t <= hi then return false end
		end
	end
	return true
end

-- Detect the diamond at `pc`. Returns an info table or nil.
local function valueDiamondInfo(ctx, pc)
	local proto = ctx.proto
	if not isTestPairAt(proto, pc) then return nil end
	local tests, thenStart = collectTests(ctx, pc, true) -- shape only: no slot mutation
	local ft = tests[#tests].target
	if not (ft and ft > thenStart) then return nil end
	local jmpPc = ft - 1
	local jmpIns = proto.ins[jmpPc]
	if not (jmpIns and jmpIns.op == INST.JMP and jmpIns.j and jmpIns.j > ft) then return nil end
	local join = jmpIns.j
	local thenLo, thenHi = thenStart, jmpPc - 1
	local elseLo, elseHi = ft, join - 1
	if thenHi < thenLo or elseHi < elseLo then return nil end
	if not (regionStraightLine(proto, thenLo, thenHi) and regionStraightLine(proto, elseLo, elseHi)) then
		return nil
	end
	if not proto.ins[join] then return nil end
	local rs = sharedLiveResult(ctx, thenLo, thenHi, elseLo, elseHi, join)
	if rs == nil then return nil end
	-- Trim a dead `cond and VALUE` materialization tail: the else arm ends with its
	-- own JMP=>join, and the region between that JMP and join is an orphaned
	-- `KPRI rs, true` (LuaJIT redirected the comparison's true-arm to compute VALUE).
	-- Without this the else region carries the JMP (misread as an inlined return,
	-- since join is a RET) and the dead KPRI, and structArmValue rejects the arm.
	-- Trim the orphaned const arm after an arm's LAST exit JMP=>join. `(cmp) or VALUE`
	-- lays the fall-through arm as `VALUE...; JMP=>join` then the comparison's dead
	-- `KPRI rs, <bool>` before the else target; use the LAST JMP=>join so a nested
	-- short-circuit in the arm (`... or E[k] or false`, whose own arms each JMP=>join)
	-- isn't cut short. Without this structArmValue sees the JMP (misread as a return)
	-- plus the dead const and rejects the arm.
	local function trimDeadArm(lo, hi)
		local lastJmp
		for p = lo, hi do
			local pi = proto.ins[p]
			if pi.op == INST.JMP and pi.j == join then lastJmp = p end
		end
		if lastJmp and isDeadConstTail(proto, lastJmp + 1, hi, rs) then return lastJmp - 1 end
		return hi
	end
	elseHi = trimDeadArm(elseLo, elseHi)
	thenHi = trimDeadArm(thenLo, thenHi)
	if elseHi < elseLo or thenHi < thenLo then return nil end
	return {
		thenStart = thenStart, thenLo = thenLo, thenHi = thenHi,
		elseLo = elseLo, elseHi = elseHi, join = join, rs = rs,
		elseDefPc = lastWriteOf(proto, ctx.fr2, elseLo, elseHi, rs),
	}
end

-- Swap in a fresh, isolated build state (statement buffer, slot/pending state,
-- multres, method-detection metadata) so a speculative sub-build can't disturb
-- the main flow. Returns the saved state for leaveIsolated. ctx.curName and
-- ctx.slotDefPc are intentionally NOT swapped -- isolated builders share the
-- main context's naming; callers that need those pristine snapshot them
-- separately (see structValueBoolTree).
local function enterIsolated(ctx)
	local saved = {
		stmts = ctx.stmts, slots = ctx.slots, pendingReads = ctx.pendingReads,
		multres = ctx.multres, movSrc = ctx.movSrc, tgetsBase = ctx.tgetsBase,
	}
	ctx.stmts, ctx.slots, ctx.pendingReads = {}, {}, {}
	ctx.multres, ctx.movSrc, ctx.tgetsBase = nil, {}, {}
	return saved
end

local function leaveIsolated(ctx, saved)
	ctx.stmts, ctx.slots, ctx.pendingReads = saved.stmts, saved.slots, saved.pendingReads
	ctx.multres, ctx.movSrc, ctx.tgetsBase = saved.multres, saved.movSrc, saved.tgetsBase
end

-- Snapshot the structurer's mutable state so a speculative fold can bail and
-- leave ctx PRISTINE for the caller's fallback path (the fold consumes pending
-- operands and emits statements before it knows it will succeed; without
-- rollback the follow-up structIf would run on corrupted state).
local function snapshotCtx(ctx)
	return {
		stmts = ctx.stmts, len = #ctx.stmts,
		slots = shallowCopy(ctx.slots),
		pendingReads = ctx.pendingReads and shallowCopy(ctx.pendingReads) or nil,
		slotDefPc = shallowCopy(ctx.slotDefPc),
		movSrc = ctx.movSrc and shallowCopy(ctx.movSrc) or nil,
		tgetsBase = ctx.tgetsBase and shallowCopy(ctx.tgetsBase) or nil,
		multres = ctx.multres,
	}
end

local function restoreCtx(ctx, snap)
	ctx.slots, ctx.pendingReads, ctx.slotDefPc = snap.slots, snap.pendingReads, snap.slotDefPc
	ctx.movSrc, ctx.tgetsBase, ctx.multres = snap.movSrc, snap.tgetsBase, snap.multres
	for i = #snap.stmts, snap.len + 1, -1 do snap.stmts[i] = nil end
end

-- Structure one arm of a diamond into a single value expression for slot `rs`.
-- Returns the expression, or nil if the arm produces anything more than exactly
-- that one pending value (extra pending slots or emitted statements => reject,
-- so we never silently drop a second live result).
local function structArmValue(ctx, lo, hi, rs, loopExit)
	local saved = enterIsolated(ctx)
	local sub = ctx.stmts
	structRange(ctx, lo, hi, loopExit)
	local expr = ctx.slots[rs]
	local otherPending = false
	for slot, node in pairs(ctx.slots) do
		if slot ~= rs and node ~= nil then otherPending = true break end
	end
	local leftMulti = ctx.multres
	-- The arm's value often lands as a single emitted statement rather than a
	-- pending value: countUses attributes the post-join read to the OTHER arm's
	-- store, so this arm's store has use-count 0 and gets materialized. When the
	-- arm reduced to exactly that one `local/assign = <value>`, recover its value.
	if expr == nil and #sub == 1 and not otherPending and leftMulti == nil then
		local st = sub[1]
		if (st.kind == "local" or st.kind == "assign") and #st.names == 1 and #st.exprs == 1 then
			expr = st.exprs[1]
			sub[1] = nil
		end
	end
	leaveIsolated(ctx, saved)
	if expr ~= nil and #sub == 0 and not otherPending and leftMulti == nil then
		return expr
	end
	-- Loose bundle: the arm produced a single live value but ALSO some helper statements
	-- (materialised temps a perfectly clean fold would have inlined -- e.g. a method call
	-- whose diamond receiver spilled). Not usable where a bare expression is required, but
	-- a hoisted `if` arm can emit the statements then assign the value, which is always
	-- scope-sound. Only offered when nothing else escapes (no other pending slot, no
	-- multres), so we never silently drop a second live result.
	if expr ~= nil and not otherPending and leftMulti == nil then
		local stmts = {}
		for _, st in ipairs(sub) do stmts[#stmts + 1] = st end
		return nil, { expr = expr, stmts = stmts }
	end
	return nil
end

-- Given a pre-built condition (TRUE on the fall-through/then arm) and the arm
-- regions in `info`, fold a value-context conditional into an expression pending in
-- `info.rs`. Shared by the adjacent-test diamond and the gapped-test ladder. Returns
-- the join pc, or nil to defer (an arm didn't reduce to exactly one value).
local function foldConditionalValue(ctx, pc, cond, info, loopExit)
	local proto = ctx.proto
	local rs = info.rs
	local thenExpr, thenLoose = structArmValue(ctx, info.thenLo, info.thenHi, rs, loopExit)
	local elseExpr, elseLoose = structArmValue(ctx, info.elseLo, info.elseHi, rs, loopExit)
	-- Bundles for the general hoisted case: a clean expr has no statements; a loose
	-- bundle carries the value plus helper statements. Either lets us build a sound arm.
	local thenB = thenExpr and { expr = thenExpr, stmts = {} } or thenLoose
	local elseB = elseExpr and { expr = elseExpr, stmts = {} } or elseLoose

	local tp = thenExpr and thenExpr.kind == "prim" and thenExpr.v or nil
	local ep = elseExpr and elseExpr.kind == "prim" and elseExpr.v or nil
	local node
	if not (thenExpr and elseExpr) then node = nil else
	if (tp == "true" and ep == "false") or (tp == "false" and ep == "true") then
		-- Boolean materialization: `rs = cond` or `rs = not cond`.
		node = (tp == "true") and cond or negate(cond)
	elseif tp == "true" and isBooleanExpr(cond) then
		-- `cond and true or Y` collapses to `cond or Y` when cond is boolean
		-- (OR-chain of comparisons: `a == x or a == y`).
		node = { kind = "binop", op = "or", lhs = cond, rhs = elseExpr }
	elseif ep == "false" and isBooleanExpr(cond) then
		-- 2-arm `if cond then X else false` is exactly `cond and X` when cond is
		-- boolean: cond false -> false (the else), cond true -> X (the then). X need
		-- not be boolean -- there is no `or` here, so no falsy-X footgun (that only
		-- bites `cond and X or Y`). Covers `type(v)=="table" and f(v)` and friends.
		node = { kind = "binop", op = "and", lhs = cond, rhs = thenExpr }
	elseif ep == "true" and isBooleanExpr(cond) then
		-- 2-arm `if cond then X else true` is `not cond or X` when cond is boolean:
		-- cond false -> true (the else), cond true -> X. This is the value-context
		-- `(a == b) or X`: LuaJIT computes X in the comparison's fall-through arm and
		-- yields the literal `true` in its true-arm. Plain `or`, so no falsy-X footgun.
		node = { kind = "binop", op = "or", lhs = negate(cond), rhs = thenExpr }
	elseif isTruthyExpr(thenExpr) then
		-- Short-circuit ternary: safe because the then-value is always truthy.
		node = {
			kind = "binop", op = "or",
			lhs = { kind = "binop", op = "and", lhs = cond, rhs = thenExpr },
			rhs = elseExpr,
		}
	end
	end
	if node then
		invalidateReaders(ctx, rs, info.join)
		ctx.slotDefPc[rs] = info.elseDefPc or pc
		setPending(ctx, rs, node)
		return info.join
	end

	-- General case: hoist the declaration so the assignment is scope-sound. Each arm may
	-- carry helper statements (from a loose bundle) that must run before the assignment.
	if not (thenB and elseB) then return nil end
	invalidateReaders(ctx, rs, info.join)
	local name, entry = varnameAt(proto, info.join, rs)
	local preexisting = false
	if name and name:sub(1, 1) ~= "(" then
		preexisting = entry.startpc < info.thenLo
	else
		name = freshSynth(ctx, rs)
	end
	if not preexisting then
		emit(ctx, { kind = "local", names = { name }, exprs = {}, pc = pc })
	end
	local function armBody(b)
		local body = {}
		for _, st in ipairs(b.stmts) do body[#body + 1] = st end
		body[#body + 1] = { kind = "assign", names = { name }, exprs = { b.expr }, pc = pc }
		return body
	end
	emit(ctx, {
		kind = "if", cond = cond, pc = pc,
		thenBody = armBody(thenB), elseBody = armBody(elseB),
	})
	setPending(ctx, rs, nil)
	ctx.curName = ctx.curName or {}
	ctx.curName[rs] = name
	ctx.slotDefPc[rs] = pc
	return info.join
end

-- Fold the diamond into a value. Returns the next pc, or nil to defer to structIf.
local function structValueDiamond(ctx, pc, info, loopExit)
	-- Snapshot so a failed fold leaves ctx PRISTINE for the caller's structIf.
	-- collectTests + flushAll below consume the condition's pending operands and emit
	-- statements, but foldConditionalValue can still bail (a side-effecting arm won't
	-- reduce to one value). Without rollback, structIf would then run on corrupted
	-- state -- e.g. an indexed condition (`if self.map[k]`) already consumed -- and
	-- mis-structure into a fallback. Mirrors structShortCircuit's deferrable rollback.
	local snap = snapshotCtx(ctx)

	-- Build the tests for real now (with condExpr); detection used shape-only.
	-- cond is TRUE on the fall-through (then) arm.
	local tests = collectTests(ctx, pc)
	local cond = buildCondTree(tests, 1, info.thenStart)
	flushAll(ctx, pc)
	local nx = foldConditionalValue(ctx, pc, cond, info, loopExit)
	if nx then return nx end

	restoreCtx(ctx, snap)
	return nil
end

--------------------------------------------------------------------------------
-- General value-context and/or chain: `(g1 and v1) or (g2 and v2) or ... or vn`
--------------------------------------------------------------------------------
-- The generalisation of the diamond to N terms with intervening computation
-- (arithmetic, method calls) that the diamond recogniser can't fold. LuaJIT lays
-- it out as a chain of clauses all writing one result slot RS and joining at END:
--   term i = [optional guard tests jumping to term i+1] [value -> RS]
--            [or-link: IST/ISF RS; JMP=>END, or a bare JMP=>END if v is statically
--             truthy]         (the last term has no or-link; it falls to END)
-- Expression: (guard1 and v1) or (guard2 and v2) or ... or vN. The or-link's
-- IST/unconditional distinction is a codegen detail and doesn't change the source
-- expression -- a term is exactly `guard and value`, or-ed into the chain.

local MAX_CHAIN_TERMS = 48

-- A value is statically truthy iff the compiler can prove it (numbers, strings,
-- tables, functions, arithmetic results, `true`). This is exactly when LuaJIT
-- omits the `IST` before an or-link's `JMP=>END`: an unconditional jump after a
-- *non*-truthy value is an if-else else-skip, NOT an or-short-circuit -- so we
-- bail there and let the diamond recogniser take it (`x = a == b`, `if c then
-- x=f() else x=g()`). `true` value -> `x and true or y`, handled by the diamond.
local STATIC_TRUTHY = {
	[INST.KSHORT] = true, [INST.KNUM] = true, [INST.KSTR] = true,
	[INST.TDUP] = true, [INST.TNEW] = true, [INST.FNEW] = true,
	[INST.CAT] = true, [INST.POW] = true, [INST.LEN] = true, [INST.UNM] = true,
}
for op in pairs(ARITH_OPS) do STATIC_TRUTHY[op] = true end
local function valueStaticTruthy(ins)
	if ins.op == INST.KPRI then return ins.d == 2 end -- 2 = true
	return STATIC_TRUTHY[ins.op] == true
end

local function lastWrittenSlot(proto, fr2, lo, hi)
	local slot
	local function wr(s) slot = s end
	for p = lo, hi do
		forEachSlot(proto.ins[p], fr2, NOP, wr)
	end
	return slot
end

-- Shape-only scan for END: the pc where every forward jump from `pc` has
-- converged (the shared join of the chain / mixed or-chain / bool-tree
-- recognizers). Returns nil on a backward jump, hard control flow
-- (DIAMOND_STOP), a region whose jumps never converge, or a >4096-ins scan.
local function findChainEnd(proto, pc)
	local n = #proto.ins
	local p, maxT = pc, 0
	while true do
		if p > n then return nil end
		local ins = proto.ins[p]
		local op = ins.op
		if isCmpOrTest(op) and proto.ins[p + 1] and proto.ins[p + 1].op == INST.JMP then
			local t = proto.ins[p + 1].j
			if not t or t <= p then return nil end
			if t > maxT then maxT = t end
			p = p + 2
		elseif op == INST.JMP then
			local t = ins.j
			if not t or t <= p then return nil end
			if t > maxT then maxT = t end
			p = p + 1
		elseif DIAMOND_STOP[op] then
			return nil -- RET/loop/tailcall inside the region
		else
			p = p + 1
		end
		if maxT > 0 and p == maxT then return maxT end
		if maxT > 0 and p > maxT then return nil end
		if p - pc > 4096 then return nil end
	end
end

-- Memoized findChainEnd: the recognizer cascade (chain -> ladder -> diamond ->
-- or-chain -> bool-tree) re-scans the same region up to three times when the
-- earlier recognizers bail. Sound to cache per ctx: protos are immutable and
-- the scan is shape-only. `false` marks a cached miss.
local function chainEndAt(ctx, pc)
	local cache = ctx.chainEnd
	if not cache then cache = {} ctx.chainEnd = cache end
	local v = cache[pc]
	if v == nil then
		v = findChainEnd(ctx.proto, pc) or false
		cache[pc] = v
	end
	return v or nil
end

-- Shape-only parse (no condExpr/slotRef side effects). Two passes: find END (the
-- jump-convergence point) then split into terms and their guards.
-- Returns { terms = {{guards={{loadLo,cmpPc,target}...}, valueLo, valueHi}...},
--           END, RS, defPc } or nil.
local function valueAndOrChainInfo(ctx, pc)
	local proto = ctx.proto
	local fr2 = ctx.fr2
	if not isTestPairAt(proto, pc) then return nil end

	-- Pass 1: END = the position where every forward jump has converged.
	local END = chainEndAt(ctx, pc)
	if not END then return nil end

	-- Pass 2: or-links are the JMP=>END instructions; they delimit the terms.
	local orLinks = {}
	for p = pc, END - 1 do
		if proto.ins[p].op == INST.JMP and proto.ins[p].j == END then orLinks[#orLinks + 1] = p end
	end
	if #orLinks < 1 or #orLinks + 1 > MAX_CHAIN_TERMS then return nil end

	-- A chain of `(guard and value)` terms whose LAST term's value is a plain
	-- computation (a call, index, ...) rather than a comparison terminates in a false
	-- sink: when the last guard fails and every prior term was falsy, the result is
	-- false. LuaJIT lays the tail as
	--   F:     KPRI rs,false     (jumped to by the last guard's short-circuit)
	--   F+1:   JMP => END        (the sink's exit; the last or-link)
	--   END-1: KPRI rs,true      (DEAD -- nothing jumps to it)
	-- The DEAD true-sink is the tell that isolates this from a literal `... or false`
	-- (its false is fallen-into, and its true-sink is live), a pure boolean and-chain
	-- (live true-sink), and a two-sink or-chain (live true-sink -- valueOrChainInfo's).
	-- Here EVERY term has its own or-link and the tail is the sink, not a value term, so
	-- drop the sink's or-link and run exactly #orLinks terms; the last term's value flows
	-- unconditionally (allowed -- the guard + false terminator make it sound, whatever it
	-- evaluates to). Very common: ctp GetVar, PAC event callbacks (type-dispatch returns).
	local falseTerminated = false
	do
		local ti = proto.ins[END - 1]
		local jp = proto.ins[END - 2]
		local fp = proto.ins[END - 3]
		if ti and ti.op == INST.KPRI and ti.d == 2 -- KPRI rs,true at END-1
			and jp and jp.op == INST.JMP and jp.j == END
			and fp and fp.op == INST.KPRI and fp.d == 1 and fp.a == ti.a then -- KPRI rs,false at END-3
			local F = END - 3
			local trueDead, falseJumped = true, false
			for p = pc, END - 1 do
				local j = proto.ins[p].j
				if j == END - 1 then trueDead = false end
				if j == F then falseJumped = true end
			end
			-- Confirm OR-chain, not AND-chain: an OR term short-circuits on TRUTHY
			-- (`IST value; JMP=>END`). An `ISF value; JMP=>END` or-link is AND semantics
			-- (`a<b and f() and g()`), which shares this exact false/dead-true tail but is
			-- NOT a `(g and v) or ...` chain -- leave it to the diamond/bool-tree.
			local anyIsf = false
			for _, oj in ipairs(orLinks) do
				if proto.ins[oj - 1] and proto.ins[oj - 1].op == INST.ISF then anyIsf = true break end
			end
			if trueDead and falseJumped and not anyIsf then
				falseTerminated = true
				for idx = #orLinks, 1, -1 do
					if orLinks[idx] == END - 2 then table.remove(orLinks, idx) break end
				end
			end
		end
	end

	local terms = {}
	local RS
	local tStart = pc
	local nTerms = falseTerminated and #orLinks or (#orLinks + 1)
	for i = 1, nTerms do
		local isLast = not falseTerminated and i == #orLinks + 1
		local tEnd, orRS
		if isLast then
			tEnd = END - 1
		else
			local jp = orLinks[i]
			local prev = proto.ins[jp - 1]
			if prev and (prev.op == INST.IST or prev.op == INST.ISF) and jp - 1 >= tStart then
				orRS = prev.d
				tEnd = jp - 2
			else
				tEnd = jp - 1
			end
		end
		if tEnd < tStart then return nil end

		-- Guards: leading (pure loads; cmp; JMP=>skip) runs, skip target ~= END.
		local guards = {}
		local gp = tStart
		while gp <= tEnd do
			local cp
			local q = gp
			while q <= tEnd do
				local qop = proto.ins[q].op
				if isCmpOrTest(qop) and proto.ins[q + 1] and proto.ins[q + 1].op == INST.JMP then cp = q break end
				if qop == INST.JMP or DIAMOND_STOP[qop] then break end
				q = q + 1
			end
			if not cp then break end
			local target = proto.ins[cp + 1].j
			if target == END then break end
			-- [gp, cp-1] is already control-flow-free (the inner scan broke at the first
			-- test/JMP/loop). A CALL here is a guard operand (`... and #Trim(x) > 0`) that
			-- chainGuardTest reconstructs inline -- evaluated exactly when the short-circuit
			-- reaches the guard, matching the bytecode, so no double-eval. Let chainGuardTest
			-- be the gate (it returns nil if the region won't reduce to one clean expression)
			-- rather than pre-rejecting every side-effecting operand. (ACF DumpStack.)
			guards[#guards + 1] = { loadLo = gp, cmpPc = cp, target = target }
			gp = cp + 2
		end
		-- In a false-terminated chain every term must be `guard AND value`: a guardless
		-- term means it isn't a multi-term OR of guarded values but a single `g and (inner
		-- or)` (`a>0 and (b or c)`), whose OR lives INSIDE the value -- the bool-tree owns
		-- that. Bail so we don't mis-parse it as `(g and b) or c`.
		if falseTerminated and #guards == 0 then return nil end
		local valueLo, valueHi = gp, tEnd
		if valueHi < valueLo or not regionStraightLine(proto, valueLo, valueHi) then return nil end

		-- Guard targets must be either the value start (or-links inside the guard)
		-- or one common skip target (and-links) -- else buildCondTree would mis-shape.
		local skip
		for _, g in ipairs(guards) do
			if g.target ~= valueLo then
				if skip == nil then skip = g.target elseif skip ~= g.target then return nil end
			end
		end

		if orRS then
			if RS == nil then RS = orRS elseif RS ~= orRS then return nil end
		elseif not isLast and not falseTerminated then
			-- unconditional or-link: the value must be statically truthy (else it's an
			-- if-else else-skip, not an or-short-circuit). A false-terminated chain is
			-- exempt: the guard gates each term and the false sink terminates the chain, so
			-- the last term's non-truthy (call/index) value is a genuine `guard and value`.
			if not valueStaticTruthy(proto.ins[valueHi]) then return nil end
		end
		terms[#terms + 1] = { guards = guards, valueLo = valueLo, valueHi = valueHi }
		if not isLast then tStart = orLinks[i] + 1 end
	end

	if #terms < 2 then return nil end
	if RS == nil then RS = lastWrittenSlot(proto, fr2, terms[1].valueLo, terms[1].valueHi) end
	if RS == nil then return nil end
	for _, t in ipairs(terms) do
		local w = {}
		regionWrites(proto, fr2, t.valueLo, t.valueHi, w)
		if not w[RS] then return nil end
	end
	if not slotLiveAt(proto, fr2, END, RS) then return nil end
	local lastT = terms[#terms]
	return { terms = terms, END = END, RS = RS,
		defPc = lastWriteOf(proto, fr2, lastT.valueLo, lastT.valueHi, RS) }
end

-- Build one guard test: structure its (pure) operand loads in isolation so
-- condExpr can read them, without emitting into or reordering the main flow.
-- Returns { e, target } or nil (if the loads didn't reduce cleanly).
local function chainGuardTest(ctx, g, loopExit)
	local saved = enterIsolated(ctx)
	structRange(ctx, g.loadLo, g.cmpPc - 1, loopExit)
	local e
	if #ctx.stmts == 0 then e = condExpr(ctx, ctx.proto.ins[g.cmpPc], g.cmpPc) end
	leaveIsolated(ctx, saved)
	if not e then return nil end
	return { e = e, target = g.target }
end

-- Build the chain expression and leave it pending in RS. Returns END, or nil to
-- defer to the diamond/structIf (if any term won't reduce cleanly).
local function structValueAndOrChain(ctx, pc, info, loopExit)
	local RS = info.RS
	flushAll(ctx, pc)
	local termExprs = {}
	for _, t in ipairs(info.terms) do
		local guardCond
		if #t.guards > 0 then
			local tests = {}
			for _, g in ipairs(t.guards) do
				local test = chainGuardTest(ctx, g, loopExit)
				if not test then return nil end
				tests[#tests + 1] = test
			end
			guardCond = buildCondTree(tests, 1, t.valueLo)
		end
		local valueExpr = structArmValue(ctx, t.valueLo, t.valueHi, RS, loopExit)
		if not valueExpr then return nil end
		if guardCond then
			termExprs[#termExprs + 1] = { kind = "binop", op = "and", lhs = guardCond, rhs = valueExpr }
		else
			termExprs[#termExprs + 1] = valueExpr
		end
	end
	local chain = termExprs[1]
	for i = 2, #termExprs do
		chain = { kind = "binop", op = "or", lhs = chain, rhs = termExprs[i] }
	end
	invalidateReaders(ctx, RS, info.END)
	ctx.slotDefPc[RS] = info.defPc or pc
	-- If the result is read more than once downstream, name it as its declared
	-- local now -- otherwise the pending value is consumed by the first reader and
	-- the later reads dangle (`M = a or {..}; M[#M+1]=..; return M`). A single-use
	-- result stays pending so the sole reader inlines it, keeping direct forms like
	-- `return c and 5 or 10` clean (the compiler already elided that local).
	local uses = info.defPc and ctx.useCount and ctx.useCount[info.defPc]
	local name, entry = varnameAt(ctx.proto, info.END, RS)
	if uses and uses > 1 and name and name:sub(1, 1) ~= "(" then
		emit(ctx, {
			kind = entry.startpc == info.END and "local" or "assign",
			names = { name }, exprs = { chain }, pc = pc,
		})
		setPending(ctx, RS, nil)
	else
		setPending(ctx, RS, chain)
	end
	return info.END
end

--------------------------------------------------------------------------------
-- Value-context MIXED or-chain (two sinks): `x = a=="s" or b or c or (d>0)`
--------------------------------------------------------------------------------
-- A source `T1 or T2 or ... or Tn` whose terms mix bare VALUES and boolean
-- COMPARISONS. LuaJIT lays it with TWO convergence points:
--   * a value term  `Ti`         -> [loads->RS]; IST/ISF RS; JMP=>END   (keeps RS)
--   * a compare term `a==s`       -> [loads]; CMP; JMP=>TRUE_SINK        (yields true)
--   * TRUE_SINK (== END-1)        -> KPRI RS, true                       (falls to END)
--   * the last compare's false    -> KPRI RS, false; JMP=>END
-- valueAndOrChainInfo only splits on JMP=>END, so it folds a following value's load
-- into the compare term and bails. Here we split on BOTH END and the true-sink: a
-- compare term contributes its comparison (true when it holds), a value term its
-- value, OR-ed together. Only fires when a genuine true-sink and >=1 compare term are
-- present (pure value or-chains stay with valueAndOrChainInfo). Arcana StartCasting
-- `forwardLike = cast_anim=="forward" or is_projectile or has_target or (range or 0)>0`.
local function valueOrChainInfo(ctx, pc)
	local proto, fr2 = ctx.proto, ctx.fr2
	if not isTestPairAt(proto, pc) then return nil end

	-- END = the point every forward jump has converged on.
	local END = chainEndAt(ctx, pc)
	if not END then return nil end

	-- The true-sink is the `KPRI RS, true` immediately before END (compare terms jump
	-- here). Its RS is the chain result; require it live at the join.
	local ts = END - 1
	local tsIns = proto.ins[ts]
	if not (tsIns and tsIns.op == INST.KPRI and tsIns.d == 2) then return nil end -- d==2 => true
	local rs = tsIns.a
	if not slotLiveAt(proto, fr2, END, rs) then return nil end

	-- Split into terms on JMP=>END (value) and JMP=>true-sink (compare).
	local terms, tStart, sawCmp = {}, pc, false
	local p = pc
	while p <= ts - 1 do
		local ip = proto.ins[p]
		if ip.op == INST.JMP and ip.j and (ip.j == END or ip.j == ts) then
			local prev = proto.ins[p - 1]
			-- The JMP that opened this term (its short-circuit branch). A compare term's
			-- false result is materialised as `KPRI RS,false; JMP=>END` immediately after
			-- the compare's JMP=>true-sink -- distinct from a literal `or false` term,
			-- which follows a VALUE term's JMP=>END. This tells them apart.
			local opener = proto.ins[tStart - 1]
			local afterTrueSink = opener and opener.op == INST.JMP and opener.j == ts
			if ip.j == ts then
				if not (prev and COMPARE_OPS[prev.op]) then return nil end
				terms[#terms + 1] = { kind = "cmp", lo = tStart, cmpPc = p - 1 }
				sawCmp, tStart = true, p + 1
			elseif prev and prev.op == INST.KPRI and prev.a == rs and prev.d == 1 and afterTrueSink then
				break -- the final compare's false tail; the compare term already captured it
			elseif prev and (prev.op == INST.IST or prev.op == INST.ISF) and prev.d == rs then
				terms[#terms + 1] = { kind = "val", lo = tStart, valueHi = p - 2 }
				tStart = p + 1
			else
				-- A trailing value with no short-circuit test (`... or false`, `... or f()`):
				-- it falls through with its own value; nothing meaningful follows it.
				terms[#terms + 1] = { kind = "val", lo = tStart, valueHi = p - 1 }
				break
			end
		end
		p = p + 1
	end
	if #terms < 2 or not sawCmp then return nil end
	return { END = END, ts = ts, rs = rs, terms = terms }
end

-- Build the mixed or-chain expression pending in RS. Returns END, or nil to defer.
local function structValueOrChain(ctx, pc, info, loopExit)
	local rs = info.rs
	-- Flush pending operands (the first term's loads precede `pc`) so isolated term
	-- building reads them by their materialised names, mirroring structValueAndOrChain.
	flushAll(ctx, pc)
	local exprs = {}
	for i, t in ipairs(info.terms) do
		local e
		if t.kind == "cmp" then
			local test = chainGuardTest(ctx, { loadLo = t.lo, cmpPc = t.cmpPc, target = info.ts }, loopExit)
			if not test then return nil end
			e = test.e
		else
			if t.valueHi < t.lo then return nil end
			e = structArmValue(ctx, t.lo, t.valueHi, rs, loopExit)
			if e == nil then return nil end
		end
		exprs[i] = e
	end
	local node = exprs[1]
	for i = 2, #exprs do node = { kind = "binop", op = "or", lhs = node, rhs = exprs[i] } end
	invalidateReaders(ctx, rs, info.END)
	ctx.slotDefPc[rs] = pc
	bindFoldedResult(ctx, rs, node, info.END, pc)
	return info.END
end

--------------------------------------------------------------------------------
-- Value-context boolean/value ladder (diamond with gapped tests)
--------------------------------------------------------------------------------
-- The diamond, generalised so the comparisons need not be adjacent: real code
-- computes each comparison's operands (often via method CALLs) right before it, so
-- `return a == self:GetOwner() or b == self:OwnerID()` lays out as
--   [loads]; cmp1; JMP=>SINK; [loads]; cmp2; JMP=>SINK; KPRI false; JMP=>JOIN;
--   SINK: KPRI true; JOIN:
-- i.e. a test ladder converging on the diamond's two sinks, with operand-load
-- regions between tests. collectTests only chains adjacent tests, so these fall to
-- structIf and leak a branch-local -> fallback. Here we collect the gapped tests,
-- build each test's condition with its operand region isolated (side effects fold
-- into the guard expression, matching short-circuit evaluation), and reuse the
-- diamond's arm/collapse machinery.

-- Build one gapped test: process its operand region [opLo,opHi] in isolation, then
-- read the comparison. Stricter than chainGuardTest: the region must reduce to
-- exactly the operands the comparison consumes (no emitted statements, nothing left
-- pending, no MULTRES), so we never silently drop an escaping side effect.
function gappedTestExpr(ctx, cmpPc, opLo, opHi, target, loopExit)
	local saved = enterIsolated(ctx)
	structRange(ctx, opLo, opHi, loopExit)
	local e, otherPending = nil, false
	if #ctx.stmts == 0 and ctx.multres == nil then
		e = condExpr(ctx, ctx.proto.ins[cmpPc], cmpPc)
		for _, node in pairs(ctx.slots) do
			if node ~= nil then otherPending = true break end
		end
		if ctx.multres ~= nil then otherPending = true end
	end
	leaveIsolated(ctx, saved)
	if not e or otherPending then return nil end
	return { e = e, target = target }
end

-- Collect a run of tests separated by straight-line operand regions, converging on
-- the diamond's two sinks. Returns { tests, thenStart } or nil. Each test =
-- { cmpPc, target, opLo, opHi }; opLo=nil means the operands are already pending
-- from before `pc` (the first test). Requires >=2 tests and >=1 real gap (adjacent
-- runs are left to the plain diamond).
function collectGappedTests(ctx, pc)
	local proto = ctx.proto
	local n = #proto.ins
	local function isTestPair(p)
		local t, j = proto.ins[p], proto.ins[p + 1]
		return t and j and isCmpOrTest(t.op) and j.op == INST.JMP and j.j and j.j > p
	end
	local raw, opLo, p = {}, nil, pc
	while isTestPair(p) do
		raw[#raw + 1] = { cmpPc = p, target = proto.ins[p + 1].j, opLo = opLo, opHi = opLo and (p - 1) or nil }
		p = p + 2
		local scanStart = p
		while p <= n and not isTestPair(p)
			and proto.ins[p].op ~= INST.JMP and not DIAMOND_STOP[proto.ins[p].op] do
			p = p + 1
		end
		-- Only a REAL gap (instructions actually lay between the two tests) marks this a
		-- ladder; adjacent tests leave opLo nil so `gapped` stays false and the plain
		-- diamond handles them. Without this, `p == scanStart` still set opLo, producing a
		-- phantom empty gap (opLo > opHi) that mis-routed AND-chains-to-boolean like
		-- `x = not a and not b and not c` into the ladder path -> failed fold -> fallback.
		if isTestPair(p) then opLo = (p > scanStart) and scanStart or nil else break end
	end
	if #raw < 2 then return nil end
	-- Longest valid prefix: with TT = pc after the prefix (raw[n].cmpPc+2) and
	-- FT = raw[n].target, every test in the prefix targets TT or FT.
	for cnt = #raw, 2, -1 do
		local tt, ft, ok = raw[cnt].cmpPc + 2, raw[cnt].target, true
		for i = 1, cnt do
			if raw[i].target ~= tt and raw[i].target ~= ft then ok = false break end
		end
		if ok then
			local gapped = false
			for i = 1, cnt do if raw[i].opLo then gapped = true break end end
			if not gapped then return nil end -- adjacent -> plain diamond handles it
			local tests = {}
			for i = 1, cnt do tests[i] = raw[i] end
			return tests, tt
		end
	end
	return nil
end

-- Detect the gapped ladder at `pc`; same info shape as valueDiamondInfo (+tests).
local function valueLadderInfo(ctx, pc)
	local proto = ctx.proto
	if not isTestPairAt(proto, pc) then return nil end
	local tests, thenStart = collectGappedTests(ctx, pc)
	if not tests then return nil end
	local ft = tests[#tests].target
	if not (ft and ft > thenStart) then return nil end
	local jmpPc = ft - 1
	local jmpIns = proto.ins[jmpPc]
	if not (jmpIns and jmpIns.op == INST.JMP and jmpIns.j and jmpIns.j > ft) then return nil end
	local join = jmpIns.j
	local thenLo, thenHi = thenStart, jmpPc - 1
	local elseLo, elseHi = ft, join - 1
	if thenHi < thenLo or elseHi < elseLo then return nil end
	if not (regionStraightLine(proto, thenLo, thenHi) and regionStraightLine(proto, elseLo, elseHi)) then return nil end
	if not proto.ins[join] then return nil end
	local rs = sharedLiveResult(ctx, thenLo, thenHi, elseLo, elseHi, join)
	if rs == nil then return nil end
	return {
		tests = tests, thenStart = thenStart,
		thenLo = thenLo, thenHi = thenHi, elseLo = elseLo, elseHi = elseHi,
		join = join, rs = rs,
		elseDefPc = lastWriteOf(proto, ctx.fr2, elseLo, elseHi, rs),
	}
end

-- Fold the gapped ladder into a value. Returns the next pc, or nil to defer.
-- Snapshots ctx so a failed fold leaves it PRISTINE for the caller (which may then
-- try the general bool-tree before structIf) -- flushAll below mutates state.
local function structValueLadder(ctx, pc, info, loopExit)
	local snap = snapshotCtx(ctx)

	local built = {}
	for i, t in ipairs(info.tests) do
		local test
		if t.opLo == nil then
			-- First test: operands are already pending in the main context.
			local e = condExpr(ctx, ctx.proto.ins[t.cmpPc], t.cmpPc)
			test = e and { e = e, target = t.target } or nil
		else
			test = gappedTestExpr(ctx, t.cmpPc, t.opLo, t.opHi, t.target, loopExit)
		end
		if not test then built = nil break end
		built[i] = test
	end
	if built then
		local cond = buildCondTree(built, 1, info.thenStart)
		flushAll(ctx, pc)
		local nx = foldConditionalValue(ctx, pc, cond, info, loopExit)
		if nx then return nx end
	end

	restoreCtx(ctx, snap)
	return nil
end

--------------------------------------------------------------------------------
-- Value-context boolean/value TREE (arbitrary and/or with two constant sinks)
--------------------------------------------------------------------------------
-- The general shape the diamond / ladder / or-chain recognizers can't reach: a
-- value built from an and/or tree whose comparisons short-circuit to a shared
-- `KPRI rs,false` and/or `KPRI rs,true` sink, optionally with a trailing bare value.
-- e.g. `x = A and B and (C or D)`. Region-based recognizers fail because the layout
-- interleaves -- the inner `or`'s true-sink sits AFTER the outer `and`'s false-sink,
-- so no contiguous then/else regions exist. This recognizer instead follows JUMPS
-- symbolically: it classifies the region into nodes (comparison / bare value / KPRI
-- sink) and evaluates the decision tree recursively into one expression. Each fold
-- goes through condValueNode, which returns nil on any shape it can't prove sound, so
-- a partial match defers to structIf rather than emitting a guess.
-- Real code: DHorizontalList.Rebuild `breakLine`.

-- Fold `if cond then thenExpr else elseExpr` (cond selects thenExpr when its test's
-- JMP fires, i.e. when cond is truthy) into one value expression, or nil when it
-- can't be expressed soundly as and/or. `cond` is the raw comparison/test expression.
local function condValueNode(cond, thenExpr, elseExpr)
	local tp = thenExpr.kind == "prim" and thenExpr.v or nil
	local ep = elseExpr.kind == "prim" and elseExpr.v or nil
	if tp and ep then
		-- Both arms constant: a boolean (or its negation), or a degenerate constant.
		if tp == ep then return { kind = "prim", v = tp } end -- cond is dead
		if tp == "true" and ep == "false" then return isBooleanExpr(cond) and cond or nil end
		if tp == "false" and ep == "true" then return isBooleanExpr(cond) and negate(cond) or nil end
		return nil -- true/nil, nil/false, ...: not a clean boolean
	end
	-- then == false: `not cond and elseExpr` -- sound for ANY cond (`not cond` is boolean:
	-- cond truthy -> false [matches the false then-arm], else -> elseExpr).
	if tp == "false" then
		return { kind = "binop", op = "and", lhs = negate(cond), rhs = elseExpr }
	end
	-- then == true: `cond or elseExpr` -- only when cond is boolean, else `cond or X`
	-- yields cond's truthy value instead of the literal `true`.
	if tp == "true" then
		if not isBooleanExpr(cond) then return nil end
		return { kind = "binop", op = "or", lhs = cond, rhs = elseExpr }
	end
	-- else == false: `cond and thenExpr` (cond boolean, so its false path is exactly false).
	if ep == "false" then
		if not isBooleanExpr(cond) then return nil end
		return { kind = "binop", op = "and", lhs = cond, rhs = thenExpr }
	end
	-- else == true: `not cond or thenExpr`.
	if ep == "true" then
		if not isBooleanExpr(cond) then return nil end
		return { kind = "binop", op = "or", lhs = negate(cond), rhs = thenExpr }
	end
	-- Neither arm constant: a genuine ternary `cond and thenExpr or elseExpr`, sound only
	-- when thenExpr is always truthy (otherwise the `or` would swallow a falsy then-value).
	if isTruthyExpr(thenExpr) then
		return { kind = "binop", op = "or",
			lhs = { kind = "binop", op = "and", lhs = cond, rhs = thenExpr },
			rhs = elseExpr }
	end
	return nil
end

-- Detect the boolean/value tree at `pc`. Classifies [pc, END) into nodes keyed by
-- their entry pc: comparison (`{kind="cmp", loadLo, cmpPc, target, fall}`), bare value
-- (`{kind="val", lo, hi}`, writes rs then JMP=>END), or a `KPRI rs,{true|false}` sink.
-- Returns { END, rs, nodes } or nil. Requires at least one KPRI true/false sink (a pure
-- value or-chain has none and belongs to valueOrChainInfo).
local function boolTreeInfo(ctx, pc)
	local proto, fr2 = ctx.proto, ctx.fr2
	if not isTestPairAt(proto, pc) then return nil end

	-- END = the convergence point of every forward jump (same scan as the or-chain).
	local END = chainEndAt(ctx, pc)
	if not END then return nil end

	-- Result slot RS: the unique slot written by the KPRI true/false sinks. Require >=1.
	local rs, sinks = nil, 0
	for p = pc, END - 1 do
		local ip = proto.ins[p]
		if ip.op == INST.KPRI and (ip.d == 1 or ip.d == 2) then
			if rs == nil then rs = ip.a elseif rs ~= ip.a then return nil end
			sinks = sinks + 1
		end
	end
	if not rs or sinks == 0 then return nil end
	if not slotLiveAt(proto, fr2, END, rs) then return nil end

	-- Classify the region into nodes keyed by entry pc.
	local nodes, segStart, p = {}, pc, pc
	while p < END do
		local ip = proto.ins[p]
		if ip.op == INST.KPRI and ip.a == rs and (ip.d == 1 or ip.d == 2) then
			if segStart ~= p then return nil end -- loads before a sink: unexpected
			nodes[p] = { kind = ip.d == 2 and "true" or "false" }
			p = p + 1
			if proto.ins[p] and proto.ins[p].op == INST.JMP and proto.ins[p].j == END then p = p + 1 end
			segStart = p
		elseif isCmpOrTest(ip.op) and proto.ins[p + 1] and proto.ins[p + 1].op == INST.JMP then
			nodes[segStart] = { kind = "cmp", loadLo = segStart, cmpPc = p,
				target = proto.ins[p + 1].j, fall = p + 2 }
			p = p + 2
			segStart = p
		elseif ip.op == INST.JMP then
			if ip.j ~= END then return nil end -- a bare value writes rs then jumps to END
			nodes[segStart] = { kind = "val", lo = segStart, hi = p - 1 }
			p = p + 1
			segStart = p
		elseif DIAMOND_STOP[ip.op] then
			return nil
		else
			p = p + 1 -- operand load belonging to the following node
		end
	end
	return { END = END, rs = rs, nodes = nodes }
end

-- Build the boolean/value tree expression and leave it in RS. Returns END, or nil to
-- defer (a node's operands didn't reduce cleanly, or a fold wasn't provably sound).
local function structValueBoolTree(ctx, pc, info, loopExit)
	local rs = info.rs
	-- Snapshot for a clean deferral (mirrors structValueDiamond): flushAll below and the
	-- per-node isolated builds must leave ctx pristine if we bail to structIf.
	local snap = snapshotCtx(ctx)
	local function rollback() restoreCtx(ctx, snap) end

	-- Materialize pending operands so each node's isolated build resolves cross-node
	-- references (x, w, ...) by their names, mirroring structValueAndOrChain/OrChain.
	flushAll(ctx, pc)

	-- Build each node's expression in isolation (operands live in [loadLo, cmpPc-1] for a
	-- comparison, [lo, hi] for a bare value; both may reference already-flushed locals).
	-- The isolated helpers don't restore ctx.curName, and a single register is often
	-- REUSED for several nodes' operands here (the test slot holds A, then B, then C+D),
	-- so a later build's freshSynth would otherwise clobber the synthetic name an earlier
	-- reference already resolved -- `local tmp7 = A` emitted but `not tmp8` used. Reset
	-- curName to the stable post-flush snapshot before each build so naming is consistent
	-- and independent of the (unordered) iteration.
	local baseName = ctx.curName and shallowCopy(ctx.curName) or nil
	local exprByEntry = {}
	for entry, node in pairs(info.nodes) do
		if node.kind == "cmp" then
			ctx.curName = baseName and shallowCopy(baseName) or nil
			local test = gappedTestExpr(ctx, node.cmpPc, node.loadLo, node.cmpPc - 1, node.target, loopExit)
			if not test then rollback() return nil end
			exprByEntry[entry] = test.e
		elseif node.kind == "val" then
			ctx.curName = baseName and shallowCopy(baseName) or nil
			local e = structArmValue(ctx, node.lo, node.hi, rs, loopExit)
			if e == nil then rollback() return nil end
			exprByEntry[entry] = e
		end
	end
	ctx.curName = baseName

	-- Assemble the tree by symbolic evaluation from the root. Memoize (with a sentinel
	-- for a computed nil) so shared sink leaves don't re-fold and cycles can't loop.
	local NILV, memo = {}, {}
	local visiting = {}
	local function assemble(entry)
		local m = memo[entry]
		if m ~= nil then return m ~= NILV and m or nil end
		if visiting[entry] then return nil end -- defensive: not a DAG we can express
		visiting[entry] = true
		local node = info.nodes[entry]
		local r
		if node then
			if node.kind == "true" or node.kind == "false" then
				r = { kind = "prim", v = node.kind }
			elseif node.kind == "val" then
				r = exprByEntry[entry]
			elseif node.kind == "cmp" then
				local cond = exprByEntry[entry]
				local tVal = assemble(node.target)
				local fVal = assemble(node.fall)
				if cond and tVal and fVal then r = condValueNode(cond, tVal, fVal) end
			end
		end
		visiting[entry] = false
		memo[entry] = r or NILV
		return r
	end

	local chain = assemble(pc)
	if not chain then rollback() return nil end

	invalidateReaders(ctx, rs, info.END)
	ctx.slotDefPc[rs] = pc
	bindFoldedResult(ctx, rs, chain, info.END, pc)
	return info.END
end

-- Structure a single instruction at `pc`. Returns the next pc.
structAt = function(ctx, pc, regionHi, loopExit)
	-- Work budget (see buildProtoStatements): structAt drives all structuring recursion,
	-- so its call count bounds total work. Overflow => raise; decompile's inner pcall
	-- turns it into the safe fallback listing rather than a multi-minute hang.
	ctx.work = ctx.work + 1
	if ctx.work > ctx.workBudget then
		error("decompile work budget exceeded (pathological control flow)", 0)
	end
	local proto = ctx.proto
	local ins = proto.ins[pc]
	local op = ins.op

	-- Loop headers detected by opcode.
	if op == INST.FORI or op == INST.JFORI then
		return structNumericFor(ctx, pc)
	elseif op == INST.ISNEXT then
		return structGenericFor(ctx, pc)
	elseif op == INST.JMP and proto.ins[ins.j] and
		(proto.ins[ins.j].op == INST.ITERC or proto.ins[ins.j].op == INST.ITERN) and ins.j > pc then
		return structGenericFor(ctx, pc)
	end

	-- while/repeat: pc is the target of a backward JMP back-edge.
	local backEnd = ctx.loopHeaders[pc]
	if backEnd then
		return structLoop(ctx, pc, backEnd)
	end

	-- Value-context short-circuit led by a plain test (x = x or/and ...), possibly
	-- with a nested value diamond as the rest (`a and (b == c)`). Defers (nil) if
	-- the rest doesn't reduce cleanly, in which case we fall through to structIf.
	if (op == INST.IST or op == INST.ISF) and isValueShortCircuit(ctx, pc, regionHi) then
		local nx = structShortCircuit(ctx, pc, loopExit, regionHi)
		if nx then return nx end
	end

	-- Conditionals.
	if isCmpOrTest(op) and proto.ins[pc + 1] and proto.ins[pc + 1].op == INST.JMP then
		local jt = proto.ins[pc + 1].j
		if jt and jt <= pc then
			-- Backward-jumping test = a loop continue-guard: the test fires
			-- (jumps back to the loop top) to skip the rest of the body, so the
			-- remainder runs only when the test does NOT fire.
			local e = condExpr(ctx, ins, pc)
			flushAll(ctx, pc)
			local thenBody = structRegion(ctx, pc + 2, regionHi, loopExit)
			emit(ctx, { kind = "if", cond = negate(e), thenBody = thenBody, pc = pc })
			return regionHi + 1
		end
		-- Forward guard-break: `test; JMP=>loopExit` fires the JMP (exits the loop) when
		-- the test holds, so it's `if <test> then break end` with the fall-through as the
		-- rest of the body -- NOT a forward if-skip (that would keep looping). Only a
		-- genuine break qualifies (isBreakTo: the jump lands on the loop exit or where it
		-- forwards to); a skip within the body targets the if's own join, so isBreakTo is
		-- false and structIf handles it. Real code: BigNum.change's trailing-zeros loop.
		if jt and isBreakTo(proto, jt, loopExit) then
			local e = condExpr(ctx, ins, pc)
			flushAll(ctx, pc)
			emit(ctx, { kind = "if", cond = e, thenBody = { { kind = "break", pc = pc } }, pc = pc })
			return pc + 2
		end
		-- General value-context and/or chain (`(g1 and v1) or ... or vn`). Tried
		-- before the diamond: it produces the natural short-circuit expression and
		-- correctly bails (statically-truthy check) on the boolean/if-else shapes
		-- the diamond handles.
		local chain = valueAndOrChainInfo(ctx, pc)
		if chain and chain.END <= regionHi + 1 then
			local nx = structValueAndOrChain(ctx, pc, chain, loopExit)
			if nx then return nx end
		end
		-- Gapped ladder: a diamond with operand computation (method calls) between
		-- the comparisons (`return a == self:GetOwner() or c == d`). Tried before the
		-- plain diamond because valueDiamondInfo also matches this shape (folding the
		-- gap into its then-arm) but then fails in structArmValue *after* mutating ctx
		-- state -- so the ladder must get first refusal. It only matches genuine
		-- gapped multi-test shapes (adjacent runs return nil and fall to the diamond).
		local ladder = valueLadderInfo(ctx, pc)
		if ladder and ladder.join <= regionHi + 1 then
			local nx = structValueLadder(ctx, pc, ladder, loopExit)
			if nx then return nx end
			-- Couldn't fold as a ladder (structValueLadder rolled ctx back). The greedy
			-- ladder often matches only a prefix of an and/or tree whose tail arm carries
			-- its own sink (`A and B and (C or D)`); give the general bool-tree a shot
			-- before falling to structIf. It's never a plain diamond.
			local bt = boolTreeInfo(ctx, pc)
			if bt and bt.END <= regionHi + 1 then
				local nx2 = structValueBoolTree(ctx, pc, bt, loopExit)
				if nx2 then return nx2 end
			end
			return structIf(ctx, pc, regionHi, loopExit)
		end
		-- Value-context conditional diamond (`x = a == b`, `x = c and A or B`).
		local diamond = valueDiamondInfo(ctx, pc)
		if diamond and diamond.join <= regionHi + 1 then
			local nx = structValueDiamond(ctx, pc, diamond, loopExit)
			if nx then return nx end
		end
		-- Last resort before structIf: a mixed two-sink or-chain (value terms + comparison
		-- terms sharing a KPRI-true sink) that none of the above split. Placed last so it
		-- never intercepts a shape the diamond/chain already fold more cleanly.
		local orChain = valueOrChainInfo(ctx, pc)
		if orChain and orChain.END <= regionHi + 1 then
			local nx = structValueOrChain(ctx, pc, orChain, loopExit)
			if nx then return nx end
		end
		-- Truly last resort: an arbitrary and/or boolean tree with two constant sinks
		-- (`x = A and B and (C or D)`) that none of the region-based recognizers could
		-- split. Evaluated symbolically; defers cleanly when a node won't fold.
		local boolTree = boolTreeInfo(ctx, pc)
		if boolTree and boolTree.END <= regionHi + 1 then
			local nx = structValueBoolTree(ctx, pc, boolTree, loopExit)
			if nx then return nx end
		end
		return structIf(ctx, pc, regionHi, loopExit)
	elseif (op == INST.ISTC or op == INST.ISFC) and proto.ins[pc + 1] and proto.ins[pc + 1].op == INST.JMP then
		return structShortCircuit(ctx, pc, loopExit, regionHi)
	end

	-- UCLO closes upvalues; with an adjacent target it's a no-op before the next
	-- instruction, otherwise it's a control transfer (treat like JMP).
	local isUcloJump = op == INST.UCLO and ins.j and ins.j ~= pc + 1

	-- Plain JMP / jumping UCLO: a jump to a RET is an (upvalue-close-merged)
	-- return; otherwise break, or an unstructured goto.
	if op == INST.JMP or isUcloJump then
		local target = ins.j
		local tIns = target and proto.ins[target]
		if tIns and RETURN_OPS[tIns.op] then
			-- Build the return BEFORE flushing: buildReturnStmt consumes ctx.multres
			-- (the pending multi-value tail, e.g. `return true, f()`), but flushAll
			-- clears it. Flush any remaining side effects after, then emit the return
			-- so it still lands last.
			local retStmt = buildReturnStmt(ctx, tIns, pc)
			flushAll(ctx, pc)
			emit(ctx, retStmt)
		elseif tIns and TAILCALL_OPS[tIns.op] then
			-- Early `return obj:m(...)` in a function with upvalues: the tail call is
			-- emitted out-of-line at the end and reached via `UCLO => CALLT` (close
			-- upvalues, then tail-call). Its operands are pending here, so build the
			-- `return <call>` at this point (buildIns turns CALLT/CALLMT into a return).
			-- The out-of-line CALLT is left unreachable (it follows the body's RET0) and
			-- dropUnreachable prunes it. countUses attributes the CALLT's operand reads
			-- to this UCLO point (findUcloTailCalls), so they inline cleanly here.
			buildIns(ctx, target)
		elseif isBreakTo(proto, target, loopExit) then
			flushAll(ctx, pc)
			emit(ctx, { kind = "break", pc = pc })
		elseif loopExit and target == regionHi + 1 then
			-- Jump to the region's own exit (inside a loop body, that's the back-edge /
			-- end-of-iteration). Emit nothing and end the region; this also drops any
			-- unreachable tail the compiler left after it -- e.g. the redundant else-break
			-- JMP that follows a then-arm's jump-over-the-else (BigNum.change).
			flushAll(ctx, pc)
			return regionHi + 1
		elseif target and target ~= pc + 1 then
			flushAll(ctx, pc)
			emit(ctx, { kind = "comment", text = "goto " .. strfmt("%04d", target), pc = pc })
		end
		return pc + 1
	end

	-- Skip structural no-ops that the loop handlers consume elsewhere (includes
	-- non-jumping UCLO -- upvalues closed in place before the next instruction).
	if isLoopMark(op) or op == INST.FORL or op == INST.IFORL or op == INST.JFORL
		or op == INST.ITERC or op == INST.ITERN
		or op == INST.ITERL or op == INST.IITERL or op == INST.JITERL
		or op == INST.ISTYPE or op == INST.ISNUM or op == INST.UCLO then
		return pc + 1
	end

	-- Everything else is a data statement.
	buildIns(ctx, pc)
	return pc + 1
end

structRegion = function(ctx, lo, hi, loopExit)
	local saved = ctx.stmts
	local list = {}
	ctx.stmts = list
	structRange(ctx, lo, hi, loopExit)
	flushAll(ctx, hi + 1)
	ctx.stmts = saved
	return list
end

-- Precompute while/repeat loop headers: target -> back-edge pc, for backward
-- plain JMPs (numeric/generic loops use FORL/ITERL and are handled separately).
local function findLoopHeaders(proto)
	local headers = {}
	for pc = 1, #proto.ins do
		local ins = proto.ins[pc]
		-- Backward JMP = loop back-edge; prefer the latest for a shared header.
		if ins.op == INST.JMP and ins.j and ins.j <= pc and (not headers[ins.j] or headers[ins.j] < pc) then
			headers[ins.j] = pc
		end
	end
	return headers
end

-- Precompute loop-carried slots for the while/repeat loops in `headers` (plain-JMP
-- back-edges; numeric/generic fors run FORL/ITERL and manage their loop var
-- explicitly, so they are excluded). A slot is carried by a loop when the FIRST
-- access to it while scanning the body linearly is a READ -- its value entering the
-- iteration comes from the previous one (or before the loop), so it must live in one
-- stable home. Returns a list of { lo, hi, slots } ranges (see carriedHere). This
-- over-approximates safely: materializing a slot that could have been inlined only
-- costs verbosity, never correctness.
local function findLoopCarried(proto, fr2, headers)
	local ranges = {}
	for lo, hi in pairs(headers) do
		local first, slots = {}, {}
		for pc = lo, hi do
			forEachSlot(proto.ins[pc], fr2,
				function(x)
					if first[x] == nil then first[x] = "r"; slots[x] = true end
				end,
				function(x)
					if first[x] == nil then first[x] = "w" end
				end)
		end
		ranges[#ranges + 1] = { lo = lo, hi = hi, slots = slots }
	end
	return ranges
end

--------------------------------------------------------------------------------
-- Statement-tree helpers (shared by dead-local elimination and scope checks)
--------------------------------------------------------------------------------

-- Collect the local names an expression references.
local function exprLocals(node, out)
	local kind = node.kind
	if kind == "localref" then
		out[node.name] = true
	elseif kind == "index" then
		exprLocals(node.obj, out)
		exprLocals(node.key, out)
	elseif kind == "call" then
		exprLocals(node.func, out)
		for i = 1, #node.args do exprLocals(node.args[i], out) end
	elseif kind == "binop" then
		exprLocals(node.lhs, out)
		exprLocals(node.rhs, out)
	elseif kind == "unop" then
		exprLocals(node.expr, out)
	elseif kind == "concat" then
		for i = 1, #node.parts do exprLocals(node.parts[i], out) end
	elseif kind == "table" then
		for i = 1, #node.fields do exprLocals(node.fields[i].value, out) end
	end
	-- func nodes are separate protos with their own scope; skip.
	return out
end

--------------------------------------------------------------------------------
-- Dead synthetic-local elimination
--------------------------------------------------------------------------------
-- Drops `local slotN = <pure expr>` bindings that are never read. These arise
-- from compiler temporaries (e.g. a method self-copy that method sugar elides).
-- Only synthetic `slotN` names are touched, so real variables are never removed.

local SYNTH = "^tmp%d+$"

local function isPureExpr(node)
	local k = node.kind
	if k == "const" or k == "prim" or k == "localref" or k == "upref"
		or k == "global" or k == "vararg" or k == "func" then
		return true
	elseif k == "binop" then
		return isPureExpr(node.lhs) and isPureExpr(node.rhs)
	elseif k == "unop" then
		return isPureExpr(node.expr)
	elseif k == "concat" then
		for i = 1, #node.parts do if not isPureExpr(node.parts[i]) then return false end end
		return true
	elseif k == "table" then
		for i = 1, #node.fields do if not isPureExpr(node.fields[i].value) then return false end end
		return true
	end
	return false -- call, index (possible metamethods), raw
end

local function countRefsExpr(node, counts)
	for name in pairs(exprLocals(node, {})) do
		counts[name] = (counts[name] or 0) + 1
	end
end

local function countRefsStmts(stmts, counts)
	for _, st in ipairs(stmts) do
		local k = st.kind
		if k == "local" or k == "assign" then
			for _, e in ipairs(st.exprs) do countRefsExpr(e, counts) end
			if k == "assign" then
				-- an assignment target that is a bare local counts as a use of it
				for _, n in ipairs(st.names) do counts[n] = (counts[n] or 0) + 1 end
			end
		elseif k == "setindex" then
			countRefsExpr(st.obj, counts)
			countRefsExpr(st.key, counts)
			countRefsExpr(st.value, counts)
		elseif k == "callstat" then
			countRefsExpr(st.expr, counts)
		elseif k == "return" then
			for _, e in ipairs(st.exprs) do countRefsExpr(e, counts) end
		elseif k == "numfor" then
			countRefsExpr(st.startE, counts)
			countRefsExpr(st.stopE, counts)
			if st.stepE then countRefsExpr(st.stepE, counts) end
			countRefsStmts(st.body, counts)
		elseif k == "genfor" then
			if st.iter.single then countRefsExpr(st.iter.single, counts) end
			if st.iter.triple then for _, e in ipairs(st.iter.triple) do countRefsExpr(e, counts) end end
			countRefsStmts(st.body, counts)
		elseif k == "while" then
			countRefsExpr(st.cond, counts)
			countRefsStmts(st.body, counts)
		elseif k == "repeat" then
			countRefsStmts(st.body, counts)
			countRefsExpr(st.untilCond, counts)
		elseif k == "if" then
			countRefsExpr(st.cond, counts)
			countRefsStmts(st.thenBody, counts)
			if st.elseBody then countRefsStmts(st.elseBody, counts) end
		end
	end
end

local function stripDeadStmts(stmts, counts)
	local kept = {}
	for _, st in ipairs(stmts) do
		if st.kind == "numfor" or st.kind == "genfor" or st.kind == "while" or st.kind == "repeat" then
			stripDeadStmts(st.body, counts)
		elseif st.kind == "if" then
			stripDeadStmts(st.thenBody, counts)
			if st.elseBody then stripDeadStmts(st.elseBody, counts) end
		end
		local drop = false
		if st.kind == "local" and #st.names == 1 and st.names[1]:match(SYNTH)
			and #st.exprs == 1 and (counts[st.names[1]] or 0) == 0 and isPureExpr(st.exprs[1]) then
			drop = true
		end
		if not drop then kept[#kept + 1] = st end
	end
	-- rewrite in place
	for i = 1, #stmts do stmts[i] = kept[i] end
	for i = #kept + 1, #stmts do stmts[i] = nil end
end

local function eliminateDeadLocals(stmts)
	local counts = {}
	countRefsStmts(stmts, counts)
	stripDeadStmts(stmts, counts)
end

-- Drop statements that follow a block-terminating `return`/`break` in the same
-- list -- they are unreachable. This removes the duplicate trailing `return`s
-- left when LuaJIT merges several early returns to a shared trailing RET whose
-- jumps we already inlined as their own `return` (otherwise the linear walk
-- emits `return; return`, which is not valid Lua). Recurses into nested blocks.
local function dropUnreachable(stmts)
	local cut
	for i = 1, #stmts do
		local st = stmts[i]
		local k = st.kind
		if k == "numfor" or k == "genfor" or k == "while" or k == "repeat" then
			dropUnreachable(st.body)
		elseif k == "if" then
			dropUnreachable(st.thenBody)
			if st.elseBody then dropUnreachable(st.elseBody) end
		end
		if not cut and (k == "return" or k == "break") then
			cut = i -- everything after this in THIS list is unreachable
		end
	end
	if cut then
		for i = #stmts, cut + 1, -1 do stmts[i] = nil end
	end
end

-- Any leftover `goto NNNN` comment means the structurer hit a jump it could not
-- resolve to a break/return/if -- the reconstruction has dropped a control
-- transfer and is unfaithful (and often pathologically mis-nested, e.g. a
-- goto-to-common-exit switch). Treat the whole function as unstructured and fall
-- back to the honest listing rather than shipping wrong (or unparseably deep) code.
local function blockHasGoto(stmts)
	for _, st in ipairs(stmts) do
		local k = st.kind
		if k == "comment" and type(st.text) == "string" and st.text:sub(1, 5) == "goto " then
			return true
		elseif k == "numfor" or k == "genfor" or k == "while" or k == "repeat" then
			if blockHasGoto(st.body) then return true end
		elseif k == "if" then
			if blockHasGoto(st.thenBody) then return true end
			if st.elseBody and blockHasGoto(st.elseBody) then return true end
		end
	end
	return false
end

-- A child closure captures parent slots by upvalue; each is referenced in the
-- child body by name. With debug info those names are known and both sides agree.
-- STRIPPED, a parent-local capture has no name to share: upvalName resolves it to a
-- bare `uvN` sentinel that (a) doesn't match the synthetic `tmpN`/`slotN` the parent
-- gave that slot and (b) is an undeclared global at runtime -- wrong-but-parseable.
-- The validator can't see it (it doesn't descend into `func` node bodies), so scan
-- the proto tree here: any upvalue that renders as `uvN` means we can't faithfully
-- reconstruct the closure, so fall back to the listing. Never fires on named
-- upvalues (real Lua source, and GMod ships unstripped), only the stripped path.
local function protoHasUnresolvedUpval(proto)
	if proto.numuv and proto.numuv > 0 then
		for idx = 0, proto.numuv - 1 do
			if upvalName(proto, idx):match("^uv%d+$") then return true end
		end
	end
	if proto.kgc then
		for _, k in pairs(proto.kgc) do
			if type(k) == "table" and k.type == "child" and k.proto
				and protoHasUnresolvedUpval(k.proto) then
				return true
			end
		end
	end
	return false
end

-- Lua's one-pass parser rejects source that nests control structures too deeply
-- (~200) or declares too many locals in one function (LUAI_MAXVARS = 200). A
-- structurer bug (e.g. a goto-switch mis-nested into a staircase) or a genuinely
-- huge function can blow past these, producing output that is valid-looking yet
-- won't `loadstring`. We cap well under both limits and fall back to the honest
-- listing instead of shipping unparseable code. Returns depth, localCount.
local MAX_NEST_DEPTH = 100
local MAX_LOCALS = 190
local function blockStats(stmts, depth)
	local maxDepth, locals = depth, 0
	for _, st in ipairs(stmts) do
		local k = st.kind
		if k == "local" then
			locals = locals + #st.names
		elseif k == "numfor" or k == "genfor" or k == "while" or k == "repeat" then
			local d, n = blockStats(st.body, depth + 1)
			if d > maxDepth then maxDepth = d end
			locals = locals + n
		elseif k == "if" then
			local d, n = blockStats(st.thenBody, depth + 1)
			if d > maxDepth then maxDepth = d end
			locals = locals + n
			if st.elseBody then
				local d2, n2 = blockStats(st.elseBody, depth + 1)
				if d2 > maxDepth then maxDepth = d2 end
				locals = locals + n2
			end
		end
	end
	return maxDepth, locals
end

--------------------------------------------------------------------------------
-- Scope soundness check
--------------------------------------------------------------------------------
-- Verifies every local reference resolves to a variable in scope. Value-context
-- short-circuits built from plain IST/ISF tests can produce a variable that is
-- only assigned inside branch blocks but read after them (a scope escape); such
-- output re-parses but is semantically wrong, so we detect it and fall back to
-- the annotated listing instead.

-- Returns true if in scope; on failure returns false + the first offending name,
-- so the caller can record what leaked (used to sub-classify the fallback reason).
local function refsInScope(node, scope)
	for name in pairs(exprLocals(node, {})) do
		if not scope[name] then return false, name end
	end
	return true
end

local validateBlock
local copyScope = shallowCopy -- scope sets hold only `true` values

-- Validation threads an optional `info` table so the FIRST scope failure records
-- {name, kind} for triage; `chk` centralises the record-once-then-fail dance.
local function chk(node, scope, info, kind)
	local ok, name = refsInScope(node, scope)
	if not ok and info and not info.name then
		info.name, info.kind = name, kind
	end
	return ok
end

-- Returns true if `stmts` is scope-sound under `scope` (name set, mutated for
-- declarations that persist in this block). `info` (optional) captures the first
-- out-of-scope reference for diagnostics.
validateBlock = function(stmts, scope, info)
	for _, st in ipairs(stmts) do
		local k = st.kind
		if k == "local" or k == "assign" then
			for _, e in ipairs(st.exprs) do
				if not chk(e, scope, info, k) then return false end
			end
			for _, name in ipairs(st.names) do scope[name] = true end
		elseif k == "setindex" then
			if not (chk(st.obj, scope, info, k) and chk(st.key, scope, info, k) and chk(st.value, scope, info, k)) then
				return false
			end
		elseif k == "callstat" then
			if not chk(st.expr, scope, info, k) then return false end
		elseif k == "return" then
			for _, e in ipairs(st.exprs) do
				if not chk(e, scope, info, k) then return false end
			end
		elseif k == "numfor" then
			if not (chk(st.startE, scope, info, k) and chk(st.stopE, scope, info, k)
				and (not st.stepE or chk(st.stepE, scope, info, k))) then return false end
			local inner = copyScope(scope)
			inner[st.var] = true
			if not validateBlock(st.body, inner, info) then return false end
		elseif k == "genfor" then
			local iterOk = st.iter.single and chk(st.iter.single, scope, info, k) or true
			if st.iter.triple then
				for _, e in ipairs(st.iter.triple) do
					if not chk(e, scope, info, k) then iterOk = false end
				end
			end
			if not iterOk then return false end
			local inner = copyScope(scope)
			for _, v in ipairs(st.vars) do inner[v] = true end
			if not validateBlock(st.body, inner, info) then return false end
		elseif k == "while" then
			if not chk(st.cond, scope, info, k) then return false end
			if not validateBlock(st.body, copyScope(scope), info) then return false end
		elseif k == "repeat" then
			-- until sees the body's locals, so validate in the body scope.
			local inner = copyScope(scope)
			if not validateBlock(st.body, inner, info) then return false end
			if not chk(st.untilCond, inner, info, "until") then return false end
		elseif k == "if" then
			if not chk(st.cond, scope, info, "ifcond") then return false end
			if not validateBlock(st.thenBody, copyScope(scope), info) then return false end
			if st.elseBody and not validateBlock(st.elseBody, copyScope(scope), info) then return false end
		end
	end
	return true
end

-- Where is `name` defined across the whole statement tree? Distinguishes the escape
-- shapes: "branch" = only ever declared inside if/else (or loop) bodies, never at a
-- level that dominates its later use (the classic conditional-value-not-lifted bug --
-- value diamonds / and-or chains / ladders the recognizers missed); "none" = never
-- declared at all (a store the builder silently dropped); "toplevel" = declared at the
-- outer level too (a subtler ordering/liveness issue). Purely for triage buckets.
local function classifyScopeEscape(stmts, name)
	local atTop, inBranch = false, false
	local function scan(list, nested)
		for _, st in ipairs(list) do
			local k = st.kind
			if k == "local" or k == "assign" then
				for _, nm in ipairs(st.names) do
					if nm == name then
						if nested then inBranch = true else atTop = true end
					end
				end
			elseif k == "numfor" then
				if st.var == name and not nested then atTop = true elseif st.var == name then inBranch = true end
				scan(st.body, true)
			elseif k == "genfor" then
				for _, v in ipairs(st.vars) do
					if v == name then if nested then inBranch = true else atTop = true end end
				end
				scan(st.body, true)
			elseif k == "while" or k == "repeat" then
				scan(st.body, true)
			elseif k == "if" then
				scan(st.thenBody, true)
				if st.elseBody then scan(st.elseBody, true) end
			end
		end
	end
	scan(stmts, false)
	if atTop then return "toplevel" end
	if inBranch then return "branch" end
	return "none"
end

-- Classify a leftover goto by jump direction: a backward target (< its own pc) is a
-- loop-back / `continue`-style edge; a forward target is a break/switch-style exit the
-- structurer couldn't fold. Returns "back", "fwd", or "mixed".
local function gotoDirection(stmts)
	local back, fwd = false, false
	local function scan(list)
		for _, st in ipairs(list) do
			local k = st.kind
			if k == "comment" and type(st.text) == "string" and st.text:sub(1, 5) == "goto " then
				local target = tonumber(st.text:match("goto%s+(%d+)"))
				if target and st.pc then
					if target <= st.pc then back = true else fwd = true end
				else
					fwd = true
				end
			elseif k == "numfor" or k == "genfor" or k == "while" or k == "repeat" then
				scan(st.body)
			elseif k == "if" then
				scan(st.thenBody)
				if st.elseBody then scan(st.elseBody) end
			end
		end
	end
	scan(stmts)
	if back and fwd then return "mixed" end
	if back then return "back" end
	return "fwd"
end

--------------------------------------------------------------------------------
-- Function-level decompilation
--------------------------------------------------------------------------------

local MAX_DEPTH = 10

local function buildProtoStatements(proto, hdr, depth)
	local ctx = {
		proto = proto,
		hdr = hdr,
		fr2 = hdr.fr2,
		slots = {},
		slotDefPc = {},
		stmts = {},
		multres = nil,
		depth = depth,
		-- Work budget: the speculative recognizer cascade re-structures overlapping
		-- sub-regions with no memoization, so a function whose control flow makes the
		-- recognizers repeatedly match-then-fail can blow up super-linearly (PAC3
		-- text.OnDraw: 1028 ins, a ~40-branch if/elseif ladder + a forward goto, took
		-- >180s). structAt is the recursion driver, so capping its call count bounds the
		-- work; on overflow we raise, decompile's inner pcall catches it, and we emit the
		-- safe fallback listing -- never wrong output. The cap scales with function size
		-- so normal (even large) functions never reach it; only pathological blowup does.
		work = 0,
		workBudget = 60000 + #proto.ins * 800,
	}
	-- Seed synthetic names for the parameter slots so body references match the rendered
	-- signature. Only matters when debug info is stripped: varnameAt then returns nil and
	-- synthName would otherwise yield `slotN` while the signature renders `argN`, so the
	-- scope validator sees an out-of-scope reference and forces a spurious fallback. With
	-- varinfo present, varnameAt supplies the real name first and this seed is never read.
	ctx.curName = {}
	local pnames = paramNames(proto)
	for slot = 0, proto.numparams - 1 do
		ctx.curName[slot] = pnames[slot]
	end
	ctx.loopVarDefs = findLoopVarDefs(proto)
	ctx.ucloTail = findUcloTailCalls(proto)
	ctx.methodSelfMov = findMethodSelfCopies(proto, hdr.fr2, 1, #proto.ins, ctx.loopVarDefs)
	ctx.useCount = countUses(proto, hdr.fr2, 1, #proto.ins, ctx.methodSelfMov, ctx.loopVarDefs, ctx.ucloTail)
	ctx.rctx = { indent = "", hdr = hdr, depth = depth }
	ctx.loopHeaders = findLoopHeaders(proto)
	ctx.carriedRanges = findLoopCarried(proto, hdr.fr2, ctx.loopHeaders)
	local stmts = structRegion(ctx, 1, #proto.ins, nil)
	dropUnreachable(stmts)
	-- Drop the compiler's implicit trailing `return`.
	local last = stmts[#stmts]
	if last and last.kind == "return" and #last.exprs == 0 then
		local ins = proto.ins[#proto.ins]
		-- An out-of-line early-tail-call CALLT sits AFTER the body's RET0, so the
		-- redundant trailing empty return is that RET0's (the CALLT itself is pruned as
		-- unreachable). Treat it like a trailing RET0.
		if ins.op == INST.RET0 or (ctx.ucloTail and ctx.ucloTail.targets[#proto.ins]) then
			stmts[#stmts] = nil
		end
	end
	eliminateDeadLocals(stmts)
	return stmts
end

local function protoParamList(proto, fn)
	local pnames = paramNames(proto, fn)
	local plist = {}
	for i = 0, proto.numparams - 1 do
		plist[#plist + 1] = pnames[i]
	end
	if proto.isvararg then plist[#plist + 1] = "..." end
	return concat(plist, ", ")
end

-- Render one proto as an anonymous function expression (multi-line).
renderFunctionExpr = function(proto, rctx)
	local depth = (rctx.depth or 0) + 1
	local baseIndent = rctx.indent or ""
	if depth > MAX_DEPTH then
		return "function(" .. protoParamList(proto) .. ") --[[ nesting too deep ]] end"
	end

	local unit = rctx.unit or "\t"
	-- The live closure (rctx.fn) only describes the ROOT proto. Child protos
	-- have no live object, so debug.getlocal/getupvalue on the root would return
	-- the wrong names for them — use varinfo only (liveFn = nil) for children.
	local liveFn = (proto == rctx.hdr.root) and rctx.fn or nil
	local out = {}
	out[#out + 1] = "function(" .. protoParamList(proto, liveFn) .. ")"
	local bodyIndent = baseIndent .. unit

	-- Upvalue commentary (values only known for the root live closure).
	if proto.numuv > 0 then
		local parts = {}
		for i = 0, proto.numuv - 1 do
			local name = upvalName(proto, i)
			if proto.upvalueValues and proto.upvalueValues[i] ~= nil then
				local v = proto.upvalueValues[i]
				local vtext = commentSafe(rctx.formatValue and rctx.formatValue(v)
					or (type(v) == "string" and shortString(v, 40) or tostring(v)))
				parts[#parts + 1] = name .. " = " .. vtext
			else
				parts[#parts + 1] = name
			end
		end
		out[#out + 1] = bodyIndent .. "-- upvalues: " .. concat(parts, ", ")
	end

	local ok, stmts = pcall(buildProtoStatements, proto, rctx.hdr, depth)
	local failReason
	if not ok then
		failReason = "build: " .. tostring(stmts)
	else
		-- Reject scope-unsound reconstructions (e.g. value-context short-circuits
		-- that leak a branch-local); fall back to the honest listing instead.
		local scope = {}
		local pnames = paramNames(proto, liveFn)
		for i = 0, proto.numparams - 1 do
			if pnames[i] then scope[pnames[i]] = true end
		end
		local escInfo = {}
		local okScope, sound = pcall(validateBlock, stmts, scope, escInfo)
		if not okScope or not sound then
			-- Sub-classify the scope escape by where the leaked name is defined
			-- (branch-only / never / toplevel) so triage buckets by real construct
			-- instead of one opaque "unstructured control flow" catch-all.
			local shape = "?"
			if okScope and escInfo.name then
				local okC, s = pcall(classifyScopeEscape, stmts, escInfo.name)
				shape = okC and s or "?"
			end
			if rawget(_G, "NOIR_DEC_DEBUG") then
				rawset(_G, "NOIR_LAST_ESC", (escInfo.name or "?") .. " (" .. (escInfo.kind or "?") .. ")")
			end
			failReason = "unstructured control flow [scope-escape/" .. shape .. "]"
		elseif blockHasGoto(stmts) then
			local okD, dir = pcall(gotoDirection, stmts)
			failReason = "unstructured control flow (goto/" .. (okD and dir or "?") .. ")"
		elseif protoHasUnresolvedUpval(proto) then
			failReason = "unresolvable upvalue (stripped closure capture)"
		else
			local nestDepth, locals = blockStats(stmts, 1)
			if nestDepth > MAX_NEST_DEPTH then
				failReason = "nesting too deep (" .. nestDepth .. ")"
			elseif locals > MAX_LOCALS then
				failReason = "too many locals (" .. locals .. ")"
			end
		end
	end

	if not failReason then
		local innerRctx = {
			indent = bodyIndent, unit = unit, hdr = rctx.hdr, depth = depth,
			formatValue = rctx.formatValue, fn = liveFn,
		}
		local okRender, renderErr = pcall(renderStatements, stmts, out, innerRctx)
		if okRender then
			out[#out + 1] = baseIndent .. "end"
			return concat(out, "\n")
		end
		failReason = "render: " .. tostring(renderErr)
		-- discard any partial statements rendered into `out`
		while #out > (proto.numuv > 0 and 2 or 1) do out[#out] = nil end
	end

	-- DEBUG: with _G.NOIR_DEC_DEBUG set, render the partial (possibly goto-containing)
	-- structure instead of the raw listing, so the failure point is visible. Dev-only.
	if rawget(_G, "NOIR_DEC_DEBUG") and ok and type(stmts) == "table" then
		local dbg = { bodyIndent .. "-- DEBUG partial structure (" .. tostring(failReason) .. "):" }
		local dbgRctx = {
			indent = bodyIndent, unit = unit, hdr = rctx.hdr, depth = depth,
			formatValue = rctx.formatValue, fn = liveFn,
		}
		if pcall(renderStatements, stmts, dbg, dbgRctx) then
			dbg[#dbg + 1] = baseIndent .. "end"
			return concat(dbg, "\n")
		end
	end

	-- Fallback: annotated listing, line-commented so the output still parses.
	out[#out + 1] = bodyIndent .. "-- decompilation failed (" .. failReason .. "); disassembly follows"
	local listing = {}
	listProto(proto, listing, {}, "function")
	for i = 1, #listing do
		out[#out + 1] = bodyIndent .. "-- " .. listing[i]
	end
	out[#out + 1] = baseIndent .. "end"
	return concat(out, "\n")
end

-- decompile(fn, opts) -> pseudo-Lua source for the function.
-- opts: { indent = base indent string, indentUnit = per-level indent (default
--   "\t"), formatValue = function(v) -> string }
function M.decompile(fn, opts)
	local parsed, err = M.parse(fn)
	if not parsed then return nil, err end
	opts = opts or {}
	local rctx = {
		indent = opts.indent or "",
		unit = opts.indentUnit or "\t",
		hdr = parsed,
		depth = 0,
		formatValue = opts.formatValue,
		fn = fn,
	}
	local ok, out = pcall(renderFunctionExpr, parsed.root, rctx)
	if not ok then
		-- Total failure: banner + fully commented listing.
		local listing = { (opts.indent or "") .. "-- decompilation failed (" .. tostring(out) .. "); disassembly follows" }
		local body = {}
		listProto(parsed.root, body, { formatValue = opts.formatValue, fn = fn }, "function")
		for i = 1, #body do
			listing[#listing + 1] = (opts.indent or "") .. "-- " .. body[i]
		end
		return concat(listing, "\n")
	end
	return out
end

-- decompileDump(dumpString, opts): same, for a raw dump blob.
function M.decompileDump(dump, opts)
	local ok, parsed = pcall(M.parseDump, dump)
	if not ok then return nil, tostring(parsed) end
	opts = opts or {}
	local rctx = {
		indent = opts.indent or "", unit = opts.indentUnit or "\t",
		hdr = parsed, depth = 0, formatValue = opts.formatValue,
	}
	local ok2, out = pcall(renderFunctionExpr, parsed.root, rctx)
	if not ok2 then return nil, tostring(out) end
	return out
end

--------------------------------------------------------------------------------
-- Symbol scanning (global function declarations / calls)
--------------------------------------------------------------------------------
-- Reimplemented on the proto IR (the old module operated on live bytecode).
-- These find non-local function *declarations* (`function foo()` /
-- `function a.b.c()`) and *calls* to globals, for tooling that wants to locate
-- or localize globals. Nothing in Noir depends on these; they are exposed for
-- REPL/tooling use, matching the old public surface.

local function strConst(proto, idx)
	local k = proto.kgc[idx]
	return k and k.type == "str" and k.value or nil
end

local function protoLines(child)
	local first = child.firstline or 0
	return first, first + (child.numline or 0)
end

-- Resolve the dotted target name of an FNEW at `pc` whose closure is assigned
-- to a global or a global table field. Returns the name or nil.
local function declaredName(proto, pc)
	local ins = proto.ins
	local nxt = ins[pc + 1]
	if not nxt then return nil end
	if nxt.op == INST.GSET then
		return strConst(proto, nxt.d)
	elseif nxt.op == INST.TSETS then
		local name = strConst(proto, nxt.c)
		if not name then return nil end
		local m = pc - 1
		while ins[m] do
			local prev = ins[m]
			if prev.op == INST.TGETS then
				local seg = strConst(proto, prev.c)
				if not seg then return nil end
				name = seg .. "." .. name
			elseif prev.op == INST.GGET then
				local seg = strConst(proto, prev.d)
				if not seg then return nil end
				return seg .. "." .. name
			else
				return nil
			end
			m = m - 1
		end
	end
	return nil
end

local function declarationsFromProto(proto, recursive, acc)
	local ins = proto.ins
	for pc = 1, #ins do
		if ins[pc].op == INST.FNEW then
			local k = proto.kgc[ins[pc].d]
			local child = k and k.type == "child" and k.proto
			local name = declaredName(proto, pc)
			if name and child then
				local s, e = protoLines(child)
				acc[#acc + 1] = { name = name, _start = s, _end = e }
			end
			if recursive and child then
				declarationsFromProto(child, true, acc)
			end
		end
	end
	return acc
end

-- Find the instruction index at or before `pc` that last wrote register `slot`.
local function lastWriterOf(proto, pc, slot)
	for m = pc - 1, 1, -1 do
		local ins = proto.ins[m]
		local mode = OPMODE[ins.op]
		if (mode.a == "dst" and ins.a == slot)
			or ((mode.a == "base" or mode.a == "rbase") and ins.a == slot) then
			return m
		end
	end
	return nil
end

-- Resolve the dotted name of a global function called by a CALL at `pc`. The
-- function is in the call's base slot; trace the GGET/TGETS chain that built it.
local function calledName(proto, pc)
	local funcSlot = proto.ins[pc].a
	local w = lastWriterOf(proto, pc, funcSlot)
	if not w then return nil end
	local ins = proto.ins[w]
	if ins.op == INST.GGET then
		return strConst(proto, ins.d)
	elseif ins.op == INST.TGETS then
		local name = strConst(proto, ins.c)
		if not name then return nil end
		local baseSlot = ins.b
		local m = lastWriterOf(proto, w, baseSlot)
		while m do
			local p = proto.ins[m]
			if p.op == INST.TGETS then
				local seg = strConst(proto, p.c)
				if not seg then return nil end
				name = seg .. "." .. name
				m = lastWriterOf(proto, m, p.b)
			elseif p.op == INST.GGET then
				local seg = strConst(proto, p.d)
				if not seg then return nil end
				return seg .. "." .. name
			else
				return nil
			end
		end
	end
	return nil
end

local function callsFromProto(proto, file, recursive, acc)
	local ins = proto.ins
	for pc = 1, #ins do
		if ins[pc].op == INST.CALL then
			local name = calledName(proto, pc)
			if name then
				local s, e = protoLines(proto)
				acc[#acc + 1] = { name = name, _start = s, _end = e, file = file }
			end
		end
		if ins[pc].op == INST.FNEW and recursive then
			local k = proto.kgc[ins[pc].d]
			if k and k.type == "child" then
				callsFromProto(k.proto, file, true, acc)
			end
		end
	end
	return acc
end

function M.getFunctionDeclarations(fn, recursive)
	local parsed, err = M.parse(fn)
	if not parsed then return nil, err end
	return declarationsFromProto(parsed.root, recursive, {})
end

function M.getFunctionCalls(fn, recursive)
	local parsed, err = M.parse(fn)
	if not parsed then return nil, err end
	local src = parsed.source
	if src and src:sub(1, 1) == "@" then src = src:sub(2) end
	return callsFromProto(parsed.root, src, recursive, {})
end

-- Pluggable loader so file helpers work both in plain LuaJIT (loadfile) and in
-- the GMod sandbox (CompileFile), where loadfile is unavailable.
M.loadFile = _G.loadfile or _G.CompileFile

M.files = {}

function M.files.getSymbols(path, recursive)
	if not M.loadFile then return {} end
	local fn = M.loadFile(path)
	if type(fn) ~= "function" then return {} end
	local decls = M.getFunctionDeclarations(fn, recursive) or {}
	return decls, path
end

function M.files.getGlobalCalls(path, recursive)
	if not M.loadFile then return {} end
	local fn = M.loadFile(path)
	if type(fn) ~= "function" then return {} end
	return M.getFunctionCalls(fn, recursive) or {}
end

-- Find global functions declared in exactly one file and never called from a
-- different file (candidates for localizing). Mirrors the old heuristic.
function M.files.findLocalizableFunctions(files)
	local declarations = {}
	for _, file in ipairs(files) do
		local decls, location = M.files.getSymbols(file, true)
		for _, d in ipairs(decls) do
			if not declarations[d.name] then
				declarations[d.name] = { file = location, _start = d._start, _end = d._end }
			end
		end
	end
	for _, file in ipairs(files) do
		for _, c in ipairs(M.files.getGlobalCalls(file, true)) do
			local decl = declarations[c.name]
			if decl and decl.file ~= c.file then
				declarations[c.name] = nil
			elseif decl then
				decl.localCalled = true
			end
		end
	end
	for name, d in pairs(declarations) do
		if not d.localCalled then
			declarations[name] = nil
		else
			d.localCalled = nil
		end
	end
	return declarations
end

--------------------------------------------------------------------------------
-- Exports
--------------------------------------------------------------------------------

M.INST = INST
M.OPNAMES = OPNAMES
M.OPMODE = OPMODE
M.BCNAMES = BCNAMES
M.varnameAt = varnameAt

jit.decompiler2 = M
return M
