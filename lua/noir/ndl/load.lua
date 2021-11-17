local NDL =  Noir.DebugLib or {}
Noir.DebugLib = NDL
_G.NDL = NDL


local function printModule(path)
    local str = Format("| [SH] MODULE: %-17s |", path)
    print(str)
end

function NDL.load()
    print("+-----Loading debug library------+")
    include("noir/ndl/logging.lua")
    printModule("ndl/".. "logging")
    include("ndl/execution.lua")
    printModule("ndl/".. "execution")
    include("noir/ndl/injection.lua")
    printModule("ndl/".. "injection")
    include("noir/ndl/utils.lua")
    printModule("ndl/".. "utils")
    if SERVER then
        AddCSLuaFile("noir/ndl/logging.lua")
        AddCSLuaFile("noir/ndl/execution.lua")
        AddCSLuaFile("noir/ndl/injection.lua")
        AddCSLuaFile("noir/ndl/utils.lua")
    end
end
