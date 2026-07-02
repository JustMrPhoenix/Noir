Noir = Noir or {}
Noir.DebugConvar = CreateConVar("noir_debug", "0", FCVAR_ARCHIVE, "Set debug mode of Noir lua editor", 0, 1)
Noir.DEBUG = Noir.DebugConvar:GetBool()
Noir.STORAGE_PATH = "noir/"
cvars.AddChangeCallback("noir_debug", function(cvar, old, new) Noir.DEBUG = Noir.DebugConvar:GetBool() end, "noirDebugToggle")
local reload = function(fullReload)
	if CLIENT then
		if IsValid(Noir.Editor.Frame) then Noir.Editor.Frame:Remove() end
		if IsValid(Noir.FileBrowser.Frame) then Noir.FileBrowser.Frame:Remove() end
		if IsValid(Noir.ReplFrame) then Noir.ReplFrame:Remove() end
		if IsValid(Noir.Dashboard) and IsValid(Noir.Dashboard.Frame) then Noir.Dashboard.Frame:Remove() end
		if Noir.FileSearch then
			Noir.FileSearch.CancelAll()
			if Noir.FileSearch.UI and IsValid(Noir.FileSearch.UI.Frame) then Noir.FileSearch.UI.Frame:Remove() end
		end

		if Noir.EntitySelector then
			Noir.EntitySelector.StopPickMode()
			Noir.EntitySelector.Close()
		end

		if fullReload then
			print("[Noir] Performing full reload, this may cause some issues " ..
				"if you have made changes to the environment or output format modules.")
			Noir = nil
		end
	end

	include("noir/noir_init.lua")
end

Noir.Reload = reload
if CLIENT then
	concommand.Add("noir_reload_cl", function(ply, cmd, args, argStr)
		if argStr ~= "full" then
			reload()
		else
			reload(true)
		end
	end, function() return {"noir_reload_cl full"} end, "Reload Noir lua editor")

	concommand.Add("noir_reload_skin", function() include("noir/client/skin.lua") end, nil, "Reload Noir skin")
else
	concommand.Add("noir_reload_sv", function(ply, cmd, args, argStr)
		if IsValid(ply) and not ply:IsSuperAdmin() then return end
		if argStr ~= "full" then
			reload()
		else
			reload(true)
		end
	end, function() return {"noir_reload_sv full"} end, "Reload Noir lua editor")
end

local function loadModule(path)
	local namesplit = path:Split("/")
	-- Realm is inferred from any "client"/"server" segment in the path, so nested
	-- folders (e.g. client/editor/frame.lua) resolve correctly, not just the immediate parent.
	local state = "SH"
	if table.HasValue(namesplit, "client") then
		state = "CL"
	elseif table.HasValue(namesplit, "server") then
		if CLIENT then -- Do not try to load server modules on client
			return
		end

		state = "SV"
	end

	-- Display name = path minus the realm folder, minus extension.
	-- e.g. "client/editor/sessions.lua" -> "editor/sessions"
	local nameparts = {}
	for _, seg in ipairs(namesplit) do
		if seg ~= "client" and seg ~= "server" then
			nameparts[#nameparts + 1] = seg
		end
	end
	local name = table.concat(nameparts, "/"):Split(".")[1]

	if SERVER and state ~= "SV" then AddCSLuaFile(path) end
	if string.len(name) > 22 then name = string.Left(name, 19) .. "..." end
	local str = Format("| [%s] MODULE: %-22s |", state, name)
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
	if CLIENT and not file.Exists(Noir.STORAGE_PATH, "DATA") then file.CreateDir(Noir.STORAGE_PATH) end
	require("luacheck")
	print("+-------------------------------------+")
	print("|               -Noir-                |")
	print("+-------------------------------------+")
	print("|                                     |")
	loadModule("logging.lua")
	loadModule("utils.lua")
	loadModule("network.lua")
	loadModule("execution.lua")
	loadModule("output_format.lua")
	loadModule("search.lua")
	loadModule("environment.lua")
	loadModule("filesearch.lua")
	loadModule("client/autocomplete.lua")
	loadModule("client/skin.lua")
	loadModule("client/file_browser.lua")
	loadModule("client/monaco_panel.lua")
	loadModule("client/editor/init.lua")
	loadModule("client/editor/persistence.lua")
	loadModule("client/editor/sessions.lua")
	loadModule("client/editor/console.lua")
	loadModule("client/editor/tabs.lua")
	loadModule("client/editor/menus.lua")
	loadModule("client/editor/sidebar.lua")
	loadModule("client/editor/run.lua")
	loadModule("client/editor/frame.lua")
	loadModule("client/repl.lua")
	loadModule("client/entity_selector.lua")
	loadModule("client/dashboard.lua")
	loadModule("client/filesearch_ui.lua")
	loadModule("client/autorun.lua")
	loadModule("ndl/load.lua")
	NDL.load()
	print("|                                     |")
	print("+----------Loading complete-----------+")
	Noir.Msg("Loaded!\n")
	-- Register native dashboard tabs in a deterministic order before any
	-- autorun script runs, so user-registered tabs always appear after ours.
	if CLIENT and Noir.FileSearch and Noir.FileSearch.UI then Noir.FileSearch.UI.RegisterDashboard() end
	if CLIENT and Noir.Editor then Noir.Editor.RegisterDashboard() end
	if CLIENT and Noir.Format then Noir.Format.RegisterDashboard() end
	if CLIENT and Noir.Autorun then Noir.Autorun.RegisterDashboard() end
	-- First-run greeting; also creates the default config so it only shows once
	if CLIENT and Noir.Editor then Noir.Editor.Storage.FirstRunCheck() end
	-- Trigger autorun scripts after Noir is fully loaded and all native tabs are registered
	if CLIENT and Noir.Autorun then Noir.Autorun.Initialize() end
end

if SERVER then
	AddCSLuaFile()
	for _, filename in ipairs(file.Find("lua/includes/modules/luacheck*", "GAME")) do
		AddCSLuaFile("includes/modules/" .. filename)
	end

	AddCSLuaFile("includes/modules/jit_decompiler.lua")
end

Noir.Load()
