Noir = Noir or {}
Noir.DebugConvar = CreateConVar("noir_debug", "0", FCVAR_ARCHIVE, "Set debug mode of Noir lua editor", 0, 1)
Noir.DEBUG = Noir.DebugConvar:GetBool()
Noir.STORAGE_PATH = "noir/"

cvars.AddChangeCallback("noir_debug", function(cvar, old, new)
	Noir.DEBUG = Noir.DebugConvar:GetBool()
end, "noirDebugToggle")

local reload = function(fullReload)
	if CLIENT then
		if IsValid(Noir.Editor.Frame) then
			Noir.Editor.Frame:Remove()
		end

		if IsValid(Noir.FileBrowser.Frame) then
			Noir.FileBrowser.Frame:Remove()
		end

		if IsValid(Noir.ReplFrame) then
			Noir.ReplFrame:Remove()
		end

		if IsValid(Noir.Dashboard) and IsValid(Noir.Dashboard.Frame) then
			Noir.Dashboard.Frame:Remove()
		end

		if Noir.EntitySelector then
			Noir.EntitySelector.StopPickMode()
			Noir.EntitySelector.Close()
		end
		if fullReload then
			print("[Noir] Performing full reload, this may cause some issues if you have made changes to the environment or output format modules.")
			Noir = nil
		end
	end

	include("noir/noir_init.lua")
end

Noir.Reload = reload

if CLIENT then
	concommand.Add("noir_reload_cl", function(ply,cmd,args,argStr)
		if argStr ~= "full" then
			reload()
		else
			reload(true)
		end
	end, function()
		return {"noir_reload_cl full"}
	end, "Reload Noir lua editor")

	concommand.Add("noir_reload_skin", function()
		include("noir/client/skin.lua")
	end, nil, "Reload Noir skin")
else
	concommand.Add("noir_reload_sv", function(ply,cmd,args,argStr)
		if IsValid(ply) and not ply:IsSuperAdmin() then return end
		if argStr ~= "full" then
			reload()
		else
			reload(true)
		end
	end, function()
		return {"noir_reload_sv full"}
	end, "Reload Noir lua editor")
end

local function loadModule(path)
	local namesplit = path:Split("/")
	local name = table.remove(namesplit):Split(".")[1]
	local folder = namesplit[#namesplit]
	local state

	if folder == "client" then
		state = "CL"
	elseif folder == "server" then
		if CLIENT then return end -- Do not try to load server modules on client
		state = "SV"
	else
		state = "SH"
	end

	if SERVER and state ~= "SV" then
		AddCSLuaFile(path)
	end

	if string.len(name) > 17 then
		name = string.Left(name, 13) .. "..."
	end

	local str = Format("| [%s] MODULE: %-17s |", state, name)
	print(str)
	if state == "CL" and SERVER then return end
	include(path)
end

function Noir.Load()
	if CLIENT and not (BRANCH ~= "dev" and BRANCH ~= "unknown") then
		print("[Noir] Please install chromium to use Noir lua editor")

		return
	end

	-- Create storage folder if it doesn't exist
	if CLIENT and not file.Exists(Noir.STORAGE_PATH, "DATA") then
		file.CreateDir(Noir.STORAGE_PATH)
	end

	require("luacheck")

	print("+--------------------------------+")
	print("|             -Noir-             |")
	print("+--------------------------------+")
	print("|                                |")
	loadModule("logging.lua")
	loadModule("utils.lua")
	loadModule("network.lua")
	loadModule("execution.lua")
	loadModule("output_format.lua")
	loadModule("environment.lua")
	loadModule("client/autocomplete.lua")
	loadModule("client/skin.lua")
	loadModule("client/file_browser.lua")
	loadModule("client/monaco_panel.lua")
	loadModule("client/editor.lua")
	loadModule("client/repl.lua")
	loadModule("client/entity_selector.lua")
	loadModule("client/dashboard.lua")
	loadModule("client/autorun.lua")
	loadModule("ndl/load.lua")
	NDL.load()
	print("|                                |")
	print("+--------Loading complete--------+")
	Noir.Msg("Loaded!\n")

	-- Trigger autorun scripts after Noir is fully loaded
	if CLIENT and Noir.Autorun then
		Noir.Autorun.Initialize()
	end
end

if SERVER then
	AddCSLuaFile()
	for _,filename in ipairs(file.Find("lua/includes/modules/luacheck*", "GAME")) do
		AddCSLuaFile("includes/modules/" .. filename)
	end
	AddCSLuaFile("includes/modules/jit_decompiler.lua")
end

Noir.Load()