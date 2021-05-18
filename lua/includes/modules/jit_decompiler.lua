local DEBUG = false -- debug mode

local tmp_documentation = {{op="ISLT",d="var",a="var",description="Jump if A < D",},{op="ISGE",d="var",a="var",description="Jump if A ≥ D",},{op="ISLE",d="var",a="var",description="Jump if A ≤ D",},{op="ISGT",d="var",a="var",description="Jump if A > D",},{op="ISEQV",d="var",a="var",description="Jump if A = D",},{op="ISNEV",d="var",a="var",description="Jump if A ≠ D",},{op="ISEQS",d="str",a="var",description="Jump if A = D",},{op="ISNES",d="str",a="var",description="Jump if A ≠ D",},{op="ISEQN",d="num",a="var",description="Jump if A = D",},{op="ISNEN",d="num",a="var",description="Jump if A ≠ D",},{op="ISEQP",d="pri",a="var",description="Jump if A = D",},{op="ISNEP",d="pri",a="var",description="Jump if A ≠ D",},{op="ISTC",d="var",a="dst",description="Copy D to A and jump",},{op="ISFC",d="var",a="dst",description="Copy D to A and jump",},{op="IST",d="var",a=" ",description="Jump if D is true",},{op="ISF",d="var",a=" ",description="Jump if D is false",},{op="MOV",d="var",a="dst",description="Copy D to A",},{op="NOT",d="var",a="dst",description="Set A to boolean not of D",},{op="UNM",d="var",a="dst",description="Set A to -D (unary minus)",},{op="LEN",d="var",a="dst",description="Set A to #D (object length)",},{op="ADDVN",a="dst",b="var",c="num",description="A = B + C",},{op="SUBVN",a="dst",b="var",c="num",description="A = B - C",},{op="MULVN",a="dst",b="var",c="num",description="A = B * C",},{op="DIVVN",a="dst",b="var",c="num",description="A = B / C",},{op="MODVN",a="dst",b="var",c="num",description="A = B % C",},{op="ADDNV",a="dst",b="var",c="num",description="A = C + B",},{op="SUBNV",a="dst",b="var",c="num",description="A = C - B",},{op="MULNV",a="dst",b="var",c="num",description="A = C * B",},{op="DIVNV",a="dst",b="var",c="num",description="A = C / B",},{op="MODNV",a="dst",b="var",c="num",description="A = C % B",},{op="ADDVV",a="dst",b="var",c="var",description="A = B + C",},{op="SUBVV",a="dst",b="var",c="var",description="A = B - C",},{op="MULVV",a="dst",b="var",c="var",description="A = B * C",},{op="DIVVV",a="dst",b="var",c="var",description="A = B / C",},{op="MODVV",a="dst",b="var",c="var",description="A = B % C",},{op="POW",a="dst",b="var",c="var",description="A = B ^ C",},{op="CAT",a="dst",b="rbase",c="rbase",description="A = B .. ~ .. C",},{op="KSTR",d="str",a="dst",description="Set A to string constant D",},{op="KCDATA",d="cdata",a="dst",description="Set A to cdata constant D",},{op="KSHORT",d="lits",a="dst",description="Set A to 16 bit signed integer D",},{op="KNUM",d="num",a="dst",description="Set A to number constant D",},{op="KPRI",d="pri",a="dst",description="Set A to primitive D",},{op="KNIL",d="base",a="base",description="Set slots A to D to nil",},{op="UGET",d="uv",a="dst",description="Set A to upvalue D",},{op="USETV",d="var",a="uv",description="Set upvalue A to D",},{op="USETS",d="str",a="uv",description="Set upvalue A to string constant D",},{op="USETN",d="num",a="uv",description="Set upvalue A to number constant D",},{op="USETP",d="pri",a="uv",description="Set upvalue A to primitive D",},{op="UCLO",d="jump",a="rbase",description="Close upvalues for slots ≥ rbase and jump to target D",},{op="FNEW",d="func",a="dst",description="Create new closure from prototype D and store it in A",},{op="TNEW",b="",["c/d"]="lit",a="dst",description="Set A to new table with size D (see below)",},{op="TDUP",b="",["c/d"]="tab",a="dst",description="Set A to duplicated template table D",},{op="GGET",b="",["c/d"]="str",a="dst",description="A = _G[D]",},{op="GSET",b="",["c/d"]="str",a="var",description="_G[D] = A",},{op="TGETV",b="var",["c/d"]="var",a="dst",description="A = B[C]",},{op="TGETS",b="var",["c/d"]="str",a="dst",description="A = B[C]",},{op="TGETB",b="var",["c/d"]="lit",a="dst",description="A = B[C]",},{op="TSETV",b="var",["c/d"]="var",a="var",description="B[C] = A",},{op="TSETS",b="var",["c/d"]="str",a="var",description="B[C] = A",},{op="TSETB",b="var",["c/d"]="lit",a="var",description="B[C] = A",},{op="TSETM",b="",["c/d"]="num*",a="base",description="(A-1)[D]",},{op="CALLM",b="lit",["c/d"]="lit",a="base",description="Call: A",},{op="CALL",b="lit",["c/d"]="lit",a="base",description="Call: A",},{op="CALLMT",b="",["c/d"]="lit",a="base",description="Tailcall: return A(A+1",},{op="CALLT",b="",["c/d"]="lit",a="base",description="Tailcall: return A(A+1",},{op="ITERC",b="lit",["c/d"]="lit",a="base",description="Call iterator: A",},{op="ITERN",b="lit",["c/d"]="lit",a="base",description="Specialized ITERC",},{op="VARG",b="lit",["c/d"]="lit",a="base",description="Vararg: A",},{op="ISNEXT",b="",["c/d"]="jump",a="base",description="Verify ITERN specialization and jump",},{op="RETM",d="lit",a="base",description="return A",},{op="RET",d="lit",a="rbase",description="return A",},{op="RET0",d="lit",a="rbase",description="return",},{op="RET1",d="lit",a="rbase",description="return A",},{op="FORI",d="jump",a="base",description="Numeric 'for' loop init",},{op="JFORI",d="jump",a="base",description="Numeric 'for' loop init",},{op="FORL",d="jump",a="base",description="Numeric 'for' loop",},{op="IFORL",d="jump",a="base",description="Numeric 'for' loop",},{op="JFORL",d="lit",a="base",description="Numeric 'for' loop",},{op="ITERL",d="jump",a="base",description="Iterator 'for' loop",},{op="IITERL",d="jump",a="base",description="Iterator 'for' loop",},{op="JITERL",d="lit",a="base",description="Iterator 'for' loop",},{op="LOOP",d="jump",a="rbase",description="Generic loop",},{op="ILOOP",d="jump",a="rbase",description="Generic loop",},{op="JLOOP",d="lit",a="rbase",description="Generic loop",},{op="JMP",d="jump",a="rbase",description="Jump",},{op="FUNCF",d="",a="rbase",description="Fixed-arg Lua function",},{op="IFUNCF",d="",a="rbase",description="Fixed-arg Lua function",},{op="JFUNCF",d="lit",a="rbase",description="Fixed-arg Lua function",},{op="FUNCV",d="",a="rbase",description="Vararg Lua function",},{op="IFUNCV",d="",a="rbase",description="Vararg Lua function",},{op="JFUNCV",d="lit",a="rbase",description="Vararg Lua function",},{op="FUNCC",d="",a="rbase",description="Pseudo-header for C functions",},{op="FUNCCW",d="",a="rbase",description="Pseudo-header for wrapped C functions",},}

local documentation = {}


for k, v in ipairs(tmp_documentation) do
	documentation[v.op] = v
end


local OPNAMES = {}

-- for gmod, check your luajit version and import it manually
-- hardcoding it because of reasons

local bcnames = "ISLT  ISGE  ISLE  ISGT  ISEQV ISNEV ISEQS ISNES ISEQN ISNEN ISEQP ISNEP ISTC  ISFC  IST   ISF   ISTYPEISNUM MOV   NOT   UNM   LEN   ADDVN SUBVN MULVN DIVVN MODVN ADDNV SUBNV MULNV DIVNV MODNV ADDVV SUBVV MULVV DIVVV MODVV POW   CAT   KSTR  KCDATAKSHORTKNUM  KPRI  KNIL  UGET  USETV USETS USETN USETP UCLO  FNEW  TNEW  TDUP  GGET  GSET  TGETV TGETS TGETB TGETR TSETV TSETS TSETB TSETM TSETR CALLM CALL  CALLMTCALLT ITERC ITERN VARG  ISNEXTRETM  RET   RET0  RET1  FORI  JFORI FORL  IFORL JFORL ITERL IITERLJITERLLOOP  ILOOP JLOOP JMP   FUNCF IFUNCFJFUNCFFUNCV IFUNCVJFUNCVFUNCC FUNCCW"


local INST = {}

do
	local i = 0

	for str in bcnames:gmatch"......" do
		str = str:gsub("%s", "")
		OPNAMES[i] = str
		INST[str] = i
		i = i + 1
	end
end


assert(INST.ISLT == 0)
local BCMode = {
	-- for the robots
	BCMnone = 0,
	BCMdst = 1,
	BCMbase = 2,
	BCMvar = 3,
	BCMrbase = 4,
	BCMuv = 5,
	BCMlit = 6,
	BCMlits = 7,
	BCMpri = 8,
	BCMnum = 9,
	BCMstr = 10,
	BCMtab = 11,
	BCMfunc = 12,
	BCMjump = 13,
	BCMcdata = 14,
	BCM_max = 15,
	-- for the human
	[0] = "BCMnone",
	[1] = "BCMdst",
	[2] = "BCMbase",
	[3] = "BCMvar",
	[4] = "BCMrbase",
	[5] = "BCMuv",
	[6] = "BCMlit",
	[7] = "BCMlits",
	[8] = "BCMpri",
	[9] = "BCMnum",
	[10] = "BCMstr",
	[11] = "BCMtab",
	[12] = "BCMfunc",
	[13] = "BCMjump",
	[14] = "BCMcdata",
	[15] = "BCM_max"
}



if DEBUG then
	for k, v in pairs(documentation) do
		assert(INST[k], "Documentation for unknown instructions : " .. k)
	end

	for k, v in pairs(OPNAMES) do
		if not documentation[v] then
			print("Instruction : " .. v .. " isn't documented")
		end
	end
end

local JIT_INST = {
	[INST.JFORI] = true,
	[INST.JFORL] = true,
	[INST.JITERL] = true,
	[INST.JLOOP] = true,
	[INST.JFUNCF] = true,
	[INST.JFUNCV] = true
}

local JIT_INCOMPATIBLE_INS = {
	-- syntax : I[name of instruction];
	-- I stands for INTERPRETER force mode
	[INST.IFORL] = true,
	[INST.IITERL] = true,
	[INST.ILOOP] = true,
	[INST.IFUNCF] = true,
	[INST.IFUNCV] = true,
	[INST.ITERN] = true,
	[INST.ISNEXT] = true, -- implies intern
	[INST.UCLO] = true,
	[INST.FNEW] = true -- created a new closure (like a function) on the fly, clearly cannot be jit compiled
}

local JIT_STICH_INS = {
	[INST.FUNCC] = true,
	[INST.FUNCCW] = true
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

local registersDocumentation = {
	[INST.GGET] = function(instruction, consts)
		instruction.A_value = consts[-instruction.D - 1]
	end,
	[INST.UGET] = function(instruction, _, upvalues)
		instruction.A_value = upvalues[instruction.D]
	end,
	[INST.TGETS] = function(instruction, consts)
		instruction.A_value = "curTable[\"" .. consts[-instruction.C - 1] .. "\"]"
	end,
	[INST.FNEW] = function(instruction, consts)
		instruction.A_value = tostring(consts[-instruction.D - 1])
	end,
	[INST.TSETS] = function(instruction, consts)
		instruction["curTable[\"" .. consts[-instruction.C - 1] .. "\"]"] = "A"
	end,
	[INST.GSET] = function(instruction, consts)
		instruction.DO = "_G[\"" .. tostring(consts[-instruction.C - 1]) .. "\"] = A"
	end,
	[INST.UCLO] = function(instruction)
		instruction.DO = string.format("Close upvalies for slots >= %i and jump to instruction %i", instruction.A, instruction.D)
	end,
	[INST.KSTR] = function(instruction, consts)
		instruction.DO = string.format("stack[%i] = \"%s\"", instruction.A, tostring(consts[-instruction.D - 1]))
	end,
	[INST.KCDATA] = function(instruction, consts)
		instruction.DO = string.format("stack[%i] = %s", instruction.A, tostring(consts[-instruction.D - 1]))
	end,
	[INST.KSHORT] = function(instruction)
		instruction.DO = string.format("stack[%i] = %s", instruction.A, instruction.D)
	end,
	[INST.KNUM] = function(instruction, consts)
		instruction.DO = string.format("stack[%i] = %s", instruction.A, tostring(consts[instruction.D]))
	end,
	[INST.KPRI] = function(instruction)
		instruction.DO = string.format("stack[%i] = nil (?)", instruction.A)
	end,
	[INST.KNIL] = function(instruction)
		local outTable = {}
		local start = instruction.A

		while start <= instruction.D do
			table.insert(outTable, string.format("stack[%i] = nil", start))
			start = start + 1
		end

		instruction.DO = table.concat(outTable, "\n")
	end,
	[INST.TNEW] = function(instruction)
		instruction.DO = string.format("stack[%i] = {} -- size custom", instruction.A)
	end
}

local instructionsModesActions = {
	A = {

	},
	B = {

	},
	C = {
		[BCMode.BCMjump] = function(instruction, n)
			-- the position to jump is relative to the current instruction
			-- I should probably refactor this into a conditional table
			instruction.D = instruction.D - 0x7fff + n
		end,
	}
}

local function getRegistersDocumentation(instruction, consts, upvalues)
	if registersDocumentation[instruction.OP_CODE] then
		registersDocumentation[instruction.OP_CODE](instruction, consts, upvalues)
	end
end


-- ghetto loop unrolling, i should probably find a better function name for this
local function doSpecialModeOperations(instruction, n)
	local fn;
	fn = instructionsModesActions.A[instruction.OP_MODES.CODE.A]
	if fn then fn(instruction, n) end
	fn = instructionsModesActions.B[instruction.OP_MODES.CODE.B]
	if fn then fn(instruction, n) end
	fn = instructionsModesActions.C[instruction.OP_MODES.CODE.C]
	if fn then fn(instruction, n) end
end


local disassembly_cache = {}


--fn is the function
--fast to true if you don't want any documentation and register filtering gives about 20-50% perf boost
local function disassemble_function(fn, fast, kill_cache)
	if disassembly_cache[fn] and not kill_cache then return disassembly_cache[fn] end
	assert(fn, "function expected")
	local fnTableData = jit.util.funcinfo(fn)
	assert(fnTableData.loc, "expected a Lua function, not a C one")

	local nUpValues = jit.util.funcinfo(fn).upvalues
	local upvalues = {}
	local nFoundUpvalues = 0
	local n = 0

	while (nFoundUpvalues ~= nUpValues) do
		local upvalue = jit.util.funcuvname(fn, n)

		if (upvalue ~= nil) then
			upvalues[nFoundUpvalues] = upvalue
			nFoundUpvalues = nFoundUpvalues + 1
		end
		n = n + 1
	end

	--[[
		Mike Pall is a cheeky boy, nConst are stored from zero (included)
		while all others const variables like strings, protos (functions) and
		tables prototypes (things like `local tbl = {tata = 4, toto = true}`)
		are stored from zero to -n, n being the number of non-nConst consts
		Yes, it's a mess but LuaJIT is faster se we can't really complain.
		 
	]]
	local nConsts = jit.util.funcinfo(fn).nconsts
	local consts = {}
	n = nConsts-1

	--[[]] -- fixing a luajit bug, -1 address returns const nil but 0 addres returns a correct const
	local value = jit.util.funck(fn, n)

	while (value ~= nil) do
		consts[n] = value
		n = n - 1
		value = jit.util.funck(fn, n)
	end

	n = 0
	local countBC = jit.util.funcinfo(fn).bytecodes
	local instructions = {}


	local header = bit.band(select(1, jit.util.funcbc(fn, 0)), 0xFF)
	assert(functions_headers[header], "Function header is unknown, found : " ..  OPNAMES[header] .. " with value : " .. header)

	--[[
		00010000 01001000 00100100 01001001
		|||||||| |||||||| |||||||| ||||||||
		B DATA   C DATA   A DATA   OP DATA
		|||||||||||||||||
		   D   D A T A
	]]

	while (n < countBC) do
		local ins, mode = jit.util.funcbc(fn, n)

		local modeA, modeB, modeC = bit.band(mode, 7), bit.rshift(bit.band(mode, 15 * 8),3),bit.rshift(bit.band(mode, 15 * 128),7)


		local instruction = {}
		instruction.OP_CODE = bit.band(ins, 0xFF)
		instruction.line = jit.util.funcinfo(fn, n+1).currentline
		instruction.OP_MODES = {}
		instruction.OP_MODES.CODE = {
				A = modeA,
				B = modeB,
				C = modeC
			}
		if not fast then
			instruction.OP_ENGLISH = OPNAMES[instruction.OP_CODE]
			local _documentation = documentation[instruction.OP_ENGLISH]
			instruction.OP_DOCUMENTATION = _documentation.description


			instruction.OP_MODES.ENGLISH = {
				A = BCMode[modeA],
				B = BCMode[modeB],
				C = BCMode[modeC]
			}

			if (_documentation.c and _documentation.c:len() > 0) or (_documentation["c/d"] and _documentation["c/d"]:len() > 0) then
				instruction.C = bit.rshift(bit.band(ins, 0x00ff0000), 16)
			end

			if _documentation.b and _documentation.b:len() > 0 then
				instruction.B = bit.rshift(ins, 24)
			end

			if _documentation.a and _documentation.a:len() > 0 then
				instruction.A = bit.rshift(bit.band(ins, 0x0000ff00), 8)
			end

			if (_documentation.d and _documentation.d:len() > 0) or (_documentation["c/d"] and _documentation["c/d"]:len() > 0) then
				instruction.D = bit.rshift(ins, 16)
			end

			doSpecialModeOperations(instruction, n)
			getRegistersDocumentation(instruction, consts, upvalues)
		else
			instruction.C = bit.rshift(bit.band(ins, 0x00ff0000), 16)
			instruction.B = bit.rshift(ins, 24)
			instruction.A = bit.rshift(bit.band(ins, 0x0000ff00), 8)
			instruction.D = bit.rshift(ins, 16)
			doSpecialModeOperations(instruction, n)
		end

		instructions[n] = instruction
		n = n + 1
	end

	local ret = {
		consts = consts,
		instructions = instructions,
		upvalues = upvalues
	}

	disassembly_cache[fn] = ret
	return ret
end

-- checks is there is ANY jit instruction
local function hasJITInstruction(fn)
	local countBC = jit.util.funcinfo(fn).bytecodes
	local n = 1
	while (n < countBC) do
		local ins = bit.band( jit.util.funcbc(fn, n), 0xFF)
		if JIT_INST[ins] then
			return true
		end
		n = n + 1
	end

	return false
end

-- basically counting the number of JIT bytecode instructions
local function JITLevel(fn)
	local countBC = jit.util.funcinfo(fn).bytecodes
	local countNonJITable = 0
	local n = 1

	while (n < countBC) do
		local ins = bit.band(jit.util.funcbc(fn, n), 0xFF)

		if JIT_INCOMPATIBLE_INS[ins] then
			countNonJITable = countNonJITable + 1
		end

		n = n + 1
	end

	return (countBC - countNonJITable) / countBC * 100
end

-- returns a table of all declared non-local functions, enable recursive to check inside functions
local function get_non_local_function_declarations(fn, recursive)
	assert(fn, "function expected")
	local symbols = {}
	local data = disassemble_function(fn, not DEBUG)
	local pos = 1
	local count = #data.instructions

	while (pos <= count) do
		local curIns = data.instructions[pos]

		-- new closure (function ?)
		-- function(...) <unreachable bytecode (from here)> end <-- we're here
		if curIns.OP_CODE == INST.FNEW then
			--consts also contains protos which are functions
			local _proto = jit.util.funcinfo(data.consts[-curIns.D - 1])

			local location = {
				_start = _proto.linedefined,
				_end = _proto.lastlinedefined
			}

			local fName

			-- if we're not at the end of the function
			if pos + 1 ~= count then
				local nextIns = data.instructions[pos + 1]

				-- We got a Global Set instruction which mean there nothing of value before the FNEW instruction
				--
				--                 vvvvvvvvvvvvv <-- previous instruction
				--  _G[variable] = function(...) <unreachable bytecode (from here)> end
				--     ^^^^^^^^ <-- we're here
				if nextIns.OP_CODE == INST.GSET then
					fName = data.consts[-nextIns.D - 1]
					-- found instruction creating a function in a table TSETS = Table
					--[[ 	We got a Table Set instruction which mean we're already in a table
						and we need to find which one(s) by browsing the instructions before the FNEW instruction
						We should meet one or zero TGETS because we're doing potentiable table lookups

						Ex : 
						    Global Lookup [GGET]
						            ^
						            |
						            |   Table lookup [TGET] 
						            |    ^
						            |    |			FNEW
						            |    |           | 
						function potato.tata.yolo() .... end
						                        |
						                        v
						                       And now we're doing a table set since we're creating
						                       a new variable (a function) in an existing table [TSETS]

						--]]
				elseif nextIns.OP_CODE == INST.TSETS then
					fName = data.consts[-nextIns.C - 1]
					-- starting to loop back to fetch the parent table(s)
					local modifier = -1
					local previousIns = data.instructions[pos + modifier]
					local endOfFunctionDeclaration = false

					while (previousIns ~= nil) do
						if previousIns.OP_CODE == INST.TGETS then
							fName = data.consts[-previousIns.C - 1] .. "." .. fName
						elseif previousIns.OP_CODE == INST.GGET then
							fName = data.consts[-previousIns.D - 1] .. "." .. fName
							endOfFunctionDeclaration = true
							break
						else
							if DEBUG then
								print("Unexpected instruction : " .. OPNAMES[previousIns.OP_CODE])
							end

							fName = nil
							break
						end

						modifier = modifier - 1
						previousIns = data.instructions[pos + modifier]
					end

					if not endOfFunctionDeclaration then
						if DEBUG then
							print("Missing instruction GGET for getting global table")
						end

						fName = nil
					end
				else
					if DEBUG then
						print("WTF#1 ", nextIns.OP_ENGLISH, location._start, location._end)
					end
				end
			else
				if DEBUG then
					print("break")
				end

				break
			end

			-- local functions use FNEW but doesn't report any name
			if fName then
				location.name = fName
				table.insert(symbols, location)
				--symbols[fName] = location
			end

			if recursive then
				local func = data.consts[-curIns.D - 1]

				if jit.util.funcinfo(func).children == true then
					for _, subFunctionDeclaration in ipairs(get_non_local_function_declarations(func, true)) do
						table.insert(symbols, subFunctionDeclaration)
					end
				end
			end
		end

		pos = pos + 1
	end

	return symbols
end



--[[ find all the global calls in a function
	for more documentation, read the function above, i stripped most of the tech
	explainations from this one as it's pretty much a copy/paste from the function above
]]
local function get_non_local_function_call(fn, recursive)
	assert(fn, "function expected")
	local calls = {}
	local debugData = jit.util.funcinfo(fn)
	local data = data or disassemble_function(fn, not DEBUG)
	local pos = 1
	local count = #data.instructions

	while (pos <= count) do
		local curIns = data.instructions[pos]

		if curIns.OP_CODE == INST.CALL then
			--consts also contains protos which are functions
			local fName

			-- if we're not at the start of a function
			if pos ~= 1 then
				local prevIns = data.instructions[pos - 1]

				if prevIns.OP_CODE == INST.GGET then
					fName = data.consts[-prevIns.D - 1]
				elseif prevIns.OP_CODE == INST.TGETS then
					fName = data.consts[-prevIns.C - 1]
					-- starting to loop back to fetch the parent table(s)
					local modifier = -2 -- we're already looking behind the current instruction being CALL
					local previousIns = data.instructions[pos + modifier]
					local endOfFunctionDeclaration = false

					while (previousIns ~= nil) do
						if previousIns.OP_CODE == INST.TGETS then
							fName = data.consts[-previousIns.C - 1] .. "." .. fName
						elseif previousIns.OP_CODE == INST.GGET then
							fName = data.consts[-previousIns.D - 1] .. "." .. fName
							endOfFunctionDeclaration = true
							break
						else
							fName = nil
							break
						end

						modifier = modifier - 1
						previousIns = data.instructions[pos + modifier]
					end

					if not endOfFunctionDeclaration then
						fName = nil
					end
				end
			else
				break
			end

			-- local functions use FNEW but doesn't report any name
			if fName then
				local twoDot = debugData.loc:find(":")

				if (twoDot) then
					debugData.loc = debugData.loc:sub(1, twoDot - 1)
				end

				local location = {
					_start = debugData.linedefined,
					_end = debugData.lastlinedefined,
					file = debugData.loc
				}

				location.name = fName
				table.insert(calls, location)
			end

			if recursive and jit.util.funcinfo(fn).children == true then
				for k, v in pairs(data.consts) do
					if type(v) == "proto" then
						for _, subFunctionDeclaration in ipairs(get_non_local_function_call(v, true)) do
							table.insert(calls, subFunctionDeclaration)
						end
					end
				end
			end
		end

		pos = pos + 1
	end

	return calls
end


local function fileGetSymbols(path, recursive, skip_issues)
	assert(path, "path expected")
	local func = loadfile(path)
	if not func then
		print("ERROR READING" .. path)
		return {}
	end

	if not jit.util.funcinfo(func).children then return {} end
	local ret = get_non_local_function_declarations(func, recursive)
	local loc = jit.util.funcinfo(func).loc
	local twoDot = loc:find(":")
	if (twoDot) then loc = loc:sub(1, twoDot-1) end
	return ret, loc
end


local function fileGetGlobalCalls(path, recursive)
	assert(path, "path expected")
	local func = loadfile(path)

	if not func then
		print("ERROR READING " .. path)
		return {}
	end

	local ret = get_non_local_function_call(func, recursive)

	return ret
end


local function findLocalizableFunctions(files)
	local declarations = {}

	for _, file in ipairs(files) do
		local reportDeclarations, location = fileGetSymbols(file, true)

		for _, functionsData in ipairs(reportDeclarations) do
			-- prevent table re-creation if multiple global funcs with same name
			if not declarations[functionsData.name] then
				declarations[functionsData.name] = {
					file = location,
					_start = functionsData._start,
					_end = functionsData._end
				}
			end
		end
	end

	for _, file in ipairs(files) do
		local reportCalls = fileGetGlobalCalls(file, true)

		for _, functionsData in ipairs(reportCalls) do
			if declarations[functionsData.name] then
				if declarations[functionsData.name].file ~= functionsData.file then
					declarations[functionsData.name] = nil
				else
					declarations[functionsData.name].localCalled = true
				end
			end
		end
	end

	-- some lua function that are not called at all may be called from c++ so remove them from the list
	for k, v in pairs(declarations) do
		if v.localCalled == nil then
			declarations[k] = nil
		else
			v.localCalled = nil
		end
	end

	return declarations
end

local a = debug.getmetatable(disassemble_function) or {}
a.__index = a.__index or a -- assuming __index is not a function
local meta = a -- a.__index -- when doing func.disassemble it's calling __index



debug.setmetatable(disassemble_function, a)

function meta.disassemble(...)
	return disassemble_function(...)
end

debug.setmetatable(hasJITInstruction, a)

function meta.isJITed(...)
	return hasJITInstruction(...)
end


debug.setmetatable(JITLevel, a)

function meta.getJITLevel(...)
	return JITLevel(...)
end

jit.decompiler = {
    functions = {
        disassemble_function = disassemble_function,
        has_JIT_Instruction = hasJITInstruction,
        get_JIT_Level = JITLevel,
        get_non_local_function_declarations = get_non_local_function_declarations,
        get_non_local_function_call = get_non_local_function_call
    },
    files = {
        fileGetSymbols = fileGetSymbols,
        fileGetGlobalCalls = fileGetGlobalCalls,
        findLocalizableFunctions = findLocalizableFunctions
    }
}


