local NDL = Noir.DebugLib or {}
Noir.DebugLib = NDL
_G.NDL = NDL

function NDL.Load()
	include("noir/ndl/logging.lua")
	include("noir/ndl/execution.lua")
	include("noir/ndl/injection.lua")
	include("noir/ndl/utils.lua")
	if SERVER then
		AddCSLuaFile("noir/ndl/logging.lua")
		AddCSLuaFile("noir/ndl/execution.lua")
		AddCSLuaFile("noir/ndl/injection.lua")
		AddCSLuaFile("noir/ndl/utils.lua")
	end
end
