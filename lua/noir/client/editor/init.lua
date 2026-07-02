local Editor = Noir.Editor or {}
Noir.Editor = Editor
Editor.IsReady = false
Editor.Sessions = Editor.Sessions or {}
Editor.SessionsByName = Editor.SessionsByName or {}
Editor.PendingOnReady = {} -- Actions queued until editor is ready

function Editor.RegisterActions(panel)
	panel:AddAction("fileNew", "File: New File", function() Editor.Session.Create() end, "Mod.CtrlCmd | Key.KeyN")
	panel:AddAction("fileOpen", "File: Open File...", function() Noir.FileBrowser.Open(true) end, "Mod.CtrlCmd | Key.KeyO")
	panel:AddAction("fileReopenClosed", "File: Reopen Closed Editor", function() Editor.Session.ReopenClosed() end, "Mod.CtrlCmd | Mod.Shift | Key.KeyT")
	panel:AddAction("fileSave", "File: Save", function() Editor.Session.Save() end, "Mod.CtrlCmd | Key.KeyS")
	panel:AddAction("fileSaveAs", "File: Save As...", function() Editor.Session.SaveAs() end, "Mod.CtrlCmd | Mod.Shift | Key.KeyS")
	panel:AddAction("sessionClose", "Close tab", function()
		if not Editor.ActiveSession then return end
		if Editor.ActiveSession.sessionType == "console" then
			Editor.Console.Close(Editor.ActiveSession.name)
		else
			Editor.Session.CloseTab(Editor.ActiveSession.name)
		end
	end, "Mod.CtrlCmd | Key.KeyW")

	panel:AddAction("runOnSelf", "Lua: Run on self", function() Editor.Run.Code("self") end)
	panel:AddAction("runOnServer", "Lua: Run on server", function() Editor.Run.Code("server") end)
	panel:AddAction("runOnShared", "Lua: Run on shared", function() Editor.Run.Code("shared") end)
	panel:AddAction("runOnClients", "Lua: Run on clients", function() Editor.Run.Code("clients") end)
	panel:AddAction("quickRun", "Lua: Run on last target", function() Editor.Run.Code(Editor.Run.LastTarget or "self") end, "Mod.CtrlCmd | Key.KeyE")
	panel:AddAction("cycleTabs", "Cycle tabs", function() Editor.Tab.Cycle(1) end, "Mod.CtrlCmd | Key.Tab")
	panel:AddAction("cycleTabsBack", "Cycle tabs (reverse)", function() Editor.Tab.Cycle(-1) end, "Mod.CtrlCmd | Mod.Shift | Key.Tab")
	for i = 1, 9 do
		panel:AddAction("switchToTab" .. i, "Switch to tab " .. i, function() Editor.Tab.SwitchTo(i) end, "Mod.Alt | Key.Digit" .. i)
	end

	-- Only meaningful on REPL/console panels (guarded by capability so it's a no-op
	-- on the Monaco editor panel, which shares this action registration).
	panel:AddAction("replSwitchJS", "Console: Switch to JavaScript", function(p)
		if p.SwitchLanguage then p:SwitchLanguage("javascript") end
	end, "Mod.CtrlCmd | Mod.Alt | Key.KeyJ")
	panel:AddAction("newConsole", "Noir: New Console Tab", function()
		local session = Editor.Console.CreateTab()
		Editor.Tab.SetActive(session.name)
	end, "Mod.CtrlCmd | Mod.Shift | Key.Backquote")
	panel:AddAction("toggleConsole", "Noir: Toggle Console Tab", function() Editor.Console.Toggle() end, "Mod.CtrlCmd | Mod.Shift | Key.KeyC")
	panel:AddAction("toggleSidebar", "View: Toggle Sidebar", function() Editor.Sidebar.Toggle() end, "Mod.CtrlCmd | Key.KeyB")
	panel:AddAction("runAutorun", "Noir: Run Autorun Scripts", function() if Noir.Autorun then Noir.Autorun.RunAll() end end)
	panel:AddAction("openEntitySelector", "Noir: Open Entity Selector", function() Noir.EntitySelector.Open() end, "Mod.CtrlCmd | Mod.Shift | Key.KeyE")
	panel:AddAction("openDashboard", "Noir: Open Dashboard", function() Noir.Dashboard.Show() end, "Mod.CtrlCmd | Mod.Shift | Key.KeyD")
	panel:AddAction("openFindInFiles", "Noir: Find in Files", function() Noir.FileSearch.UI.Show() end, "Mod.CtrlCmd | Mod.Shift | Key.KeyF")
end

function Editor.Show()
	if coh then coh.StartChat() end
	if IsValid(Editor.Frame) then
		Editor.Frame:Show()
		Editor.Frame:MakePopup()
		return
	end

	Editor.UI.CreateFrame()
end

-- Register the Editor's settings in the Dashboard. Called from Noir.Load() after the
-- dashboard module is available (editor.lua itself loads before dashboard.lua).
function Editor.RegisterDashboard()
	if not Noir.Dashboard then return end
	-- Unregister first so a reload doesn't stack duplicate OnChange callbacks.
	if Editor.DashboardRegistered then Noir.Dashboard.Unregister("Editor") end
	Noir.Dashboard.Register("Editor", {
		{
			key = "sidebarFollowFile",
			type = "bool",
			label = "Sidebar follows active file",
			description = "Switch the explorer root to where the active file lives (DATA / LUA / GAME) and scroll to it. When off, the explorer always shows the default root below.",
			category = "Explorer",
			default = true
		},
		{
			key = "sidebarDefaultPath",
			type = "dropdown",
			label = "Default root folder",
			description = "Root folder shown when no file is open, or when 'follows active file' is off.",
			category = "Explorer",
			default = "DATA",
			options = {
				{
					label = "Data (garrysmod/data)",
					value = "DATA"
				},
				{
					label = "Lua",
					value = "LUA"
				},
				{
					label = "Game (garrysmod)",
					value = "GAME"
				}
			}
		},
		{
			key = "replHistoryPersist",
			type = "bool",
			label = "Remember REPL history",
			description = "Save console/REPL command history between sessions. Lua and JavaScript keep separate histories.",
			category = "REPL",
			default = true
		},
		{
			key = "replHistoryLimit",
			type = "number",
			label = "Max history entries",
			description = "How many past commands to keep per language. Oldest entries are dropped once the limit is reached.",
			category = "REPL",
			default = 100,
			min = 1,
			max = 10000
		}
	}, {
		icon = "icon16/application_side_tree.png",
		description = "Editor and file explorer settings"
	})

	-- Re-navigate the sidebar immediately when either setting changes.
	local function refresh() Editor.Sidebar.NavigateToActive(true) end
	Noir.Dashboard.OnChange("Editor", "sidebarFollowFile", refresh)
	Noir.Dashboard.OnChange("Editor", "sidebarDefaultPath", refresh)
	-- Trim stored history right away when the cap is lowered.
	Noir.Dashboard.OnChange("Editor", "replHistoryLimit", function() Editor.Storage.TrimReplHistory() end)
	Editor.DashboardRegistered = true
end

concommand.Add("noir_clearconfig", function()
	file.Delete(Noir.STORAGE_PATH .. "config.json")
	file.Delete(Noir.STORAGE_PATH .. "sessions.json")
	file.Delete(Noir.STORAGE_PATH .. "dashboard.json")
	file.Delete(Noir.STORAGE_PATH .. "autorun.json")
	Editor.Config = nil
	Editor.Sessions = {}
	Editor.SessionsByName = {}
	Noir.Reload()
end)

-- if Noir.DEBUG then
--     if IsValid(Editor.Frame) then
--         Editor.Frame:Remove()
--     end
--     Editor.Show()
-- end
concommand.Add("noir_showeditor", function(ply, cmd, args) Editor.Show() end)
hook.Add("Think", "NoirEditorClose", function(self)
	if not input.IsKeyDown(KEY_ESCAPE) then return end
	if Noir.Editor.Frame and Noir.Editor.Frame:IsVisible() then
		Noir.Editor.Frame:Hide()
		if coh then coh.FinishChat() end
		gui.HideGameUI()
	end
end)
