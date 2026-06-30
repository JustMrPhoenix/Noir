local Editor = Noir.Editor or {}
Noir.Editor = Editor
Editor.IsReady = false
Editor.Sessions = Editor.Sessions or {}
Editor.SessionsByName = Editor.SessionsByName or {}
Editor.ConsoleSessions = {} -- Track all console sessions
Editor.MainConsole = nil -- The main console that receives all script output
Editor.ConsoleCounter = 0 -- Counter for naming new consoles
Editor.PendingOnReady = {} -- Actions queued until editor is ready
-- Toggle between Monaco editor and REPL panel based on session type
function Editor.SetContentPanel(sessionType)
	local isConsole = sessionType == "console"
	-- Hide all console panels first
	for _, console in pairs(Editor.ConsoleSessions) do
		if console.ReplPanel then console.ReplPanel:SetVisible(false) end
	end

	if isConsole then
		-- Show the appropriate console's REPL panel
		Editor.MonacoPanel:SetVisible(false)
		if Editor.ActiveSession and Editor.ActiveSession.ReplPanel then
			Editor.ActiveSession.ReplPanel:SetVisible(true)
			Editor.ActiveSession.ReplPanel:RequestFocus()
		end
	else
		-- Show Monaco editor
		Editor.MonacoPanel:SetVisible(true)
		Editor.MonacoPanel:RequestFocus()
	end
end

-- Create a new console tab
function Editor.CreateConsoleTab(consoleName, isMain)
	if not consoleName then
		if isMain then
			consoleName = "Main Console"
		else
			Editor.ConsoleCounter = Editor.ConsoleCounter + 1
			consoleName = "Console " .. Editor.ConsoleCounter
		end
	end

	-- Check if console with this name already exists
	if Editor.SessionsByName[consoleName] then
		Editor.SetActiveTab(consoleName)
		return Editor.SessionsByName[consoleName]
	end

	local session = {
		name = consoleName,
		code = "",
		sessionType = "console",
		SavedCode = "",
		isMainConsole = isMain or false
	}

	table.insert(Editor.Sessions, session)
	Editor.SessionsByName[consoleName] = session
	Editor.ConsoleSessions[consoleName] = session
	Editor.AddTab(session)
	-- Create REPL panel for this console
	if Editor.Frame then
		local replPanel = vgui.Create("NoirReplPanel", Editor.Frame)
		replPanel:DockMargin(0, 0, -5, -5)
		replPanel:Dock(FILL)
		replPanel:SetVisible(false)
		replPanel:SetCursor("sizenwse")
		session.ReplPanel = replPanel
		replPanel.OnMousePressed = function(_, ...)
			if Editor.Frame.Maximized then return end
			Editor.Frame:OnMousePressed(...)
		end

		replPanel.OnMouseReleased = function(_, ...)
			if Editor.Frame.Maximized then return end
			Editor.Frame:OnMouseReleased(...)
		end

		replPanel.HTMLPanel.OnFocusChanged = function(_, hasFocus)
			Editor.Frame:SetAlpha(hasFocus and 255 or 190)
			replPanel:SetAlpha(hasFocus and 255 or 190)
		end
	end

	if isMain then Editor.MainConsole = session end
	return session
end

-- Show the main console tab (create if needed)
function Editor.ShowMainConsole()
	-- Queue if editor isn't ready yet (takes a moment to initialize)
	if not Editor.IsReady then
		table.insert(Editor.PendingOnReady, Editor.ShowMainConsole)
		return
	end

	if not Editor.MainConsole then Editor.CreateConsoleTab("Main Console", true) end
	Editor.SetActiveTab("Main Console")
end

-- Show a console tab by name, or show main console
function Editor.ShowConsoleTab(consoleName)
	if consoleName and Editor.SessionsByName[consoleName] then
		Editor.SetActiveTab(consoleName)
	else
		Editor.ShowMainConsole()
	end
end

-- Close a console tab
function Editor.CloseConsoleTab(consoleName)
	local session = Editor.SessionsByName[consoleName]
	if not session or session.sessionType ~= "console" then return end
	-- Remove REPL panel
	if session.ReplPanel then
		session.ReplPanel:Remove()
		session.ReplPanel = nil
	end

	-- Remove from console sessions tracking
	Editor.ConsoleSessions[consoleName] = nil
	-- If this was the main console, clear the reference
	if Editor.MainConsole == session then Editor.MainConsole = nil end
	-- Close the session
	Editor.CloseSession(consoleName)
end

function Editor.RegisterActions(panel)
	panel:AddAction("fileNew", "File: New File", function() Editor.CreateSession() end, "Mod.CtrlCmd | Key.KeyN")
	panel:AddAction("fileOpen", "File: Open File...", function() Noir.FileBrowser.Open(true) end, "Mod.CtrlCmd | Key.KeyO")
	panel:AddAction("fileReopenClosed", "File: Reopen Closed Editor", function() Editor.ReopenClosedTab() end, "Mod.CtrlCmd | Mod.Shift | Key.KeyT")
	panel:AddAction("fileSave", "File: Save", function() Editor.Save() end, "Mod.CtrlCmd | Key.KeyS")
	panel:AddAction("fileSaveAs", "File: Save As...", function() Editor.SaveAs() end, "Mod.CtrlCmd | Mod.Shift | Key.KeyS")
	panel:AddAction("sessionClose", "Close tab", function()
		if not Editor.ActiveSession then return end
		if Editor.ActiveSession.sessionType == "console" then
			Editor.CloseConsoleTab(Editor.ActiveSession.name)
		else
			Editor.CloseTab(Editor.ActiveSession.name)
		end
	end, "Mod.CtrlCmd | Key.KeyW")

	panel:AddAction("runOnSelf", "Lua: Run on self", function() Editor.RunCode("self") end)
	panel:AddAction("runOnServer", "Lua: Run on server", function() Editor.RunCode("server") end)
	panel:AddAction("runOnShared", "Lua: Run on shared", function() Editor.RunCode("shared") end)
	panel:AddAction("runOnClients", "Lua: Run on clients", function() Editor.RunCode("clients") end)
	panel:AddAction("quickRun", "Lua: Run on last target", function() Editor.RunCode(Editor.LastRunTarget or "self") end, "Mod.CtrlCmd | Key.KeyE")
	panel:AddAction("cycleTabs", "Cycle tabs", function() Editor.CycleTabs(1) end, "Mod.CtrlCmd | Key.Tab")
	panel:AddAction("cycleTabsBack", "Cycle tabs (reverse)", function() Editor.CycleTabs(-1) end, "Mod.CtrlCmd | Mod.Shift | Key.Tab")
	for i = 1, 9 do
		panel:AddAction("switchToTab" .. i, "Switch to tab " .. i, function() Editor.SwitchToTab(i) end, "Mod.Alt | Key.Digit" .. i)
	end

	panel:AddAction("newConsole", "Noir: New Console Tab", function()
		local session = Editor.CreateConsoleTab()
		Editor.SetActiveTab(session.name)
	end, "Mod.CtrlCmd | Mod.Shift | Key.Backquote")
	panel:AddAction("toggleConsole", "Noir: Toggle Console Tab", function() Editor.ToggleConsoleTab() end, "Mod.CtrlCmd | Mod.Shift | Key.KeyC")
	panel:AddAction("toggleSidebar", "View: Toggle Sidebar", function() Editor.ToggleSidebar() end, "Mod.CtrlCmd | Key.KeyB")
	panel:AddAction("runAutorun", "Noir: Run Autorun Scripts", function() if Noir.Autorun then Noir.Autorun.RunAll() end end)
	panel:AddAction("openEntitySelector", "Noir: Open Entity Selector", function() Noir.EntitySelector.Open() end, "Mod.CtrlCmd | Mod.Shift | Key.KeyE")
	panel:AddAction("openDashboard", "Noir: Open Dashboard", function() Noir.Dashboard.Show() end, "Mod.CtrlCmd | Mod.Shift | Key.KeyD")
end

function Editor.CycleTabs(direction)
	direction = direction or 1
	if #Editor.Sessions == 0 then return end
	local current
	for k, v in ipairs(Editor.Sessions) do
		if v.name == Editor.Config.activeSession then
			current = k
			break
		end
	end

	if not current then current = 1 end
	local nextTab = ((current - 1 + direction) % #Editor.Sessions) + 1
	Editor.SetActiveTab(Editor.Sessions[nextTab].name)
end

function Editor.SwitchToTab(index)
	if Editor.Sessions[index] then Editor.SetActiveTab(Editor.Sessions[index].name) end
end

-- Toggle main console tab visibility
function Editor.ToggleConsoleTab()
	if Editor.ActiveSession and Editor.ActiveSession.sessionType == "console" then
		-- Switch to first non-console tab
		for _, s in ipairs(Editor.Sessions) do
			if s.sessionType ~= "console" then
				Editor.SetActiveTab(s.name)
				return
			end
		end
	else
		Editor.ShowMainConsole()
	end
end

-- Get the main console's REPL panel for output
function Editor.GetMainConsolePanel()
	if not Editor.MainConsole then Editor.CreateConsoleTab("Main Console", true) end
	return Editor.MainConsole and Editor.MainConsole.ReplPanel
end

-- Focus the main console (used after script output)
function Editor.FocusMainConsole()
	if Editor.MainConsole then Editor.SetActiveTab(Editor.MainConsole.name) end
end

function Editor.Show()
	if coh then coh.StartChat() end
	if IsValid(Editor.Frame) then
		Editor.Frame:Show()
		Editor.Frame:MakePopup()
		return
	end

	Editor.CreateFrame()
end

function Editor.CreateFrame()
	-- There is alot of hacky vgui stuff here
	-- im just trying to get as close to vs-code look as possible
	if not Editor.Config or Noir.DEBUG then Editor.LoadConfig() end
	local frame = vgui.Create("DFrame")
	frame:SetSkin("Noir")
	frame:SetMinHeight(300)
	frame:SetMinWidth(300)
	frame.lblTitle:SetVisible(false)
	frame:SetDeleteOnClose(false)
	frame:SetDraggable(true)
	frame:SetSizable(true)
	frame:MakePopup()
	frame.btnMinim:SetVisible(false)
	frame.PerformLayout = function()
		frame.btnClose:SetPos(frame:GetWide() - 31, 0)
		frame.btnClose:SetSize(31, 24)
		frame.btnMaxim:SetPos(frame:GetWide() - 31 * 2, 0)
		frame.btnMaxim:SetSize(31, 24)
	end

	frame.Maximized = false
	frame.btnMaxim:SetDisabled(false)
	frame.btnMaxim.DoClick = function()
		if frame.Maximized then
			frame.Maximized = false
			frame:SetPos(unpack(Editor.Config.editorPosition))
			frame:SetSize(unpack(Editor.Config.editorSize))
		else
			frame.Maximized = true
			Editor.Config.editorSize = {frame:GetSize()}
			Editor.Config.editorPosition = {frame:GetPos()}
			frame:SetPos(0, 0)
			frame:SetSize(ScrW(), ScrH())
		end

		frame:SetDraggable(not frame.Maximized)
		frame:SetSizable(not frame.Maximized)
	end

	frame:SetPos(unpack(Editor.Config.editorPosition))
	frame:SetSize(unpack(Editor.Config.editorSize))
	frame:SetTitle("[Noir Lua Editor]")
	frame.OnSizeChanged = function(_, w, h)
		if frame.Maximized then return end
		Editor.Config.editorSize = {w, h}
		Editor.Config.editorPosition = {frame:GetPos()}
		Editor.SaveConfig()
	end

	frame.OnClose = function()
		Editor.Config.editorSize = {frame:GetSize()}
		Editor.Config.editorPosition = {frame:GetPos()}
		Editor.SaveConfig()
		Editor.QueueSessionsSave()
		CloseDermaMenus()
		if coh then coh.FinishChat() end
	end

	local oMousePressed = frame.OnMousePressed
	-- A hack to enable double clicking on frame header
	frame.OnMousePressed = function(_, mousecode)
		local _, screenY = frame:LocalToScreen(0, 0)
		if mousecode == MOUSE_LEFT then
			if frame.LastClickTime and SysTime() - frame.LastClickTime < 0.2 and screenY - gui.MouseY() < 24 then
				frame.btnMaxim:DoClick()
				return
			end

			frame.LastClickTime = SysTime()
		end

		oMousePressed(frame, mousecode)
	end

	Editor.Frame = frame
	local menuX = 5
	local fileMenuButton = frame:Add("DButton")
	fileMenuButton:SetTall(24)
	fileMenuButton:SetPos(menuX, 0)
	fileMenuButton:SetText("File")
	fileMenuButton:SizeToContentsX(16)
	fileMenuButton:SetIsMenu(true)
	menuX = menuX + fileMenuButton:GetWide()
	local fileMenu = DermaMenu()
	fileMenu:SetSkin("Noir")
	-- fileMenu:SetDark(true)
	fileMenu:SetDeleteSelf(false)
	fileMenu:SetDrawColumn(true)
	fileMenu:Hide()
	Noir.Utils.AddMenuOption(fileMenu, "New", function() Editor.CreateSession() end, "icon16/page_add.png", "Ctrl+N")
	fileMenu:AddSpacer():SetTall(10)
	Noir.Utils.AddMenuOption(fileMenu, "Open", function() Noir.FileBrowser.Open(true) end, "icon16/folder.png", "Ctrl+O")
	local recentSubmenu, recentMenu = fileMenu:AddSubMenu("Open Recent")
	-- recentMenu:SetIcon("icon16/table_multiple.png")
	recentMenu:SetTextColor(Color(200, 200, 200))
	recentSubmenu:SetDeleteSelf(false)
	Editor.RecentSubmenu = recentSubmenu
	Editor.ReloadRecents()
	Noir.Utils.AddMenuOption(fileMenu, "Reopen Closed", function() Editor.ReopenClosedTab() end, "icon16/page_white_get.png", "Ctrl+Shift+T")
	fileMenu:AddSpacer():SetTall(10)
	Noir.Utils.AddMenuOption(fileMenu, "Save", function() Editor.Save() end, "icon16/disk.png", "Ctrl+S")
	Noir.Utils.AddMenuOption(fileMenu, "Save as", function() Editor.SaveAs() end, "icon16/page_save.png", "Ctrl+Shift+S")
	Noir.Utils.AddMenuOption(fileMenu, "Save all", function()
		local i = 0
		local callback, session
		callback = function()
			i = i + 1
			session = Editor.Sessions[i]
			Noir.Debug("SaveAll", session)
			if not session then return end
			if not session.Modified then return callback() end
			Editor.SetActiveTab(session.name)
			Editor.Save(session.name, callback)
		end

		callback()
	end, "icon16/disk_multiple.png")

	fileMenu:AddSpacer():SetTall(5)
	Noir.Utils.AddMenuOption(fileMenu, "Close", function() frame:Close() end, nil, "Ctrl+W")
	fileMenuButton.DoClick = function()
		if not Editor.IsReady then return end
		if fileMenu:IsVisible() then
			fileMenu:Hide()
			return
		end

		CloseDermaMenus()
		local x, y = fileMenuButton:LocalToScreen(0, 0)
		fileMenu:Open(x, y + fileMenuButton:GetTall(), false, fileMenuButton)
	end

	local runMenuButton = frame:Add("DButton")
	runMenuButton:SetTall(24)
	runMenuButton:SetPos(menuX, 0)
	runMenuButton:SetText("Run")
	runMenuButton:SizeToContentsX(16)
	runMenuButton:SetIsMenu(true)
	menuX = menuX + runMenuButton:GetWide()
	local runMenu = DermaMenu()
	runMenu:SetSkin("Noir")
	runMenu:SetDeleteSelf(false)
	runMenu:SetDrawColumn(true)
	runMenu:Hide()
	Noir.Utils.AddMenuOption(runMenu, "Run last target", function() Editor.RunCode(Editor.LastRunTarget or "self") end, "icon16/lightning.png", "Ctrl+E")
	runMenu:AddSpacer():SetTall(5)
	Noir.Utils.AddMenuOption(runMenu, "Run on self", function() Editor.RunCode("self") end, "icon16/user.png")
	Noir.Utils.AddMenuOption(runMenu, "Run on server", function() Editor.RunCode("server") end, "icon16/server.png")
	local runOnSubmenu, runOnMenu = runMenu:AddSubMenu("Run on client")
	runOnMenu:SetIcon("icon16/user_go.png")
	runOnMenu:SetTextColor(Color(200, 200, 200))
	runOnSubmenu:SetDeleteSelf(false)
	Editor.RunOnSubmenu = runOnSubmenu
	Noir.Utils.AddMenuOption(runMenu, "Run on clients", function() Editor.RunCode("clients") end, "icon16/group.png")
	Noir.Utils.AddMenuOption(runMenu, "Run on shared", function() Editor.RunCode("shared") end, "icon16/world.png")
	runMenu:AddSpacer():SetTall(10)
	local autorunSubmenu, autorunMenu = runMenu:AddSubMenu("Autorun")
	autorunMenu:SetIcon("icon16/control_play_blue.png")
	autorunMenu:SetTextColor(Color(200, 200, 200))
	autorunSubmenu:SetDeleteSelf(false)
	Editor.AutorunSubmenu = autorunSubmenu
	runMenuButton.DoClick = function()
		if not Editor.IsReady then return end
		if runMenu:IsVisible() then
			runMenu:Hide()
			return
		end

		CloseDermaMenus()
		for i = 1, runOnSubmenu:ChildCount() do
			runOnSubmenu:GetChild(i):Remove()
		end

		for _, v in pairs(player.GetHumans()) do
			Noir.Utils.AddMenuOption(
				runOnSubmenu, v:Nick(),
				function() Editor.RunCode(v) end,
				v:IsSuperAdmin() and "icon16/user_suit.png" or "icon16/user.png"
			)
		end

		-- Populate autorun submenu
		for i = 1, autorunSubmenu:ChildCount() do
			autorunSubmenu:GetChild(i):Remove()
		end

		Noir.Utils.AddMenuOption(autorunSubmenu, "Run All Now", function() Noir.Autorun.RunAll() end, "icon16/control_play.png")
		autorunSubmenu:AddSpacer():SetTall(5)
		local scripts = Noir.Autorun.Scripts or {}
		if #scripts > 0 then
			for i, script in ipairs(scripts) do
				local displayName = Noir.Autorun.GetDisplayName(script)
				Noir.Utils.AddMenuOption(autorunSubmenu, displayName, function() Noir.Autorun.RunScript(script) end, "icon16/script.png")
			end
		else
			local emptyOpt = autorunSubmenu:AddOption("No autorun scripts")
			emptyOpt:SetTextColor(Color(120, 120, 120))
			emptyOpt:SetDisabled(true)
		end

		autorunSubmenu:AddSpacer():SetTall(5)
		Noir.Utils.AddMenuOption(autorunSubmenu, "Manage Autorun...", function()
			Noir.Dashboard.Show()
			timer.Simple(0.1, function() Noir.Dashboard.SetActiveTab("Autorun") end)
		end, "icon16/cog.png")

		local x, y = runMenuButton:LocalToScreen(0, 0)
		runMenu:Open(x, y + runMenuButton:GetTall(), false, runMenuButton)
	end

	-- View menu
	local viewMenuButton = frame:Add("DButton")
	viewMenuButton:SetTall(24)
	viewMenuButton:SetPos(menuX, 0)
	viewMenuButton:SetText("View")
	viewMenuButton:SizeToContentsX(16)
	viewMenuButton:SetIsMenu(true)
	local viewMenu = DermaMenu()
	viewMenu:SetSkin("Noir")
	viewMenu:SetDeleteSelf(false)
	viewMenu:SetDrawColumn(true)
	viewMenu:Hide()
	Noir.Utils.AddMenuOption(viewMenu, "Main Console", function() Editor.ShowMainConsole() end, "icon16/application_xp_terminal.png")
	Noir.Utils.AddMenuOption(viewMenu, "New Console", function()
		local session = Editor.CreateConsoleTab()
		Editor.SetActiveTab(session.name)
	end, "icon16/application_add.png", "Ctrl+Shift+`")

	viewMenu:AddSpacer():SetTall(5)
	Noir.Utils.AddMenuOption(viewMenu, "Toggle Console", function() Editor.ToggleConsoleTab() end, "icon16/application_xp_terminal.png", "Ctrl+Shift+C")
	viewMenu:AddSpacer():SetTall(5)
	Noir.Utils.AddMenuOption(viewMenu, "Toggle Sidebar", function() Editor.ToggleSidebar() end, "icon16/application_side_tree.png", "Ctrl+B")
	Noir.Utils.AddMenuOption(viewMenu, "Entity Selector", function() Noir.EntitySelector.Open() end, "icon16/brick.png", "Ctrl+Shift+E")
	Noir.Utils.AddMenuOption(viewMenu, "Dashboard", function() Noir.Dashboard.Show() end, "icon16/cog.png", "Ctrl+Shift+D")
	Noir.Utils.AddMenuOption(viewMenu, "Editor Settings", function()
		Noir.Dashboard.Show()
		Noir.Dashboard.SetActiveTab("Editor")
	end, "icon16/application_side_tree.png")
	viewMenuButton.DoClick = function()
		if not Editor.IsReady then return end
		if viewMenu:IsVisible() then
			viewMenu:Hide()
			return
		end

		CloseDermaMenus()
		local x, y = viewMenuButton:LocalToScreen(0, 0)
		viewMenu:Open(x, y + viewMenuButton:GetTall(), false, viewMenuButton)
	end

	local tabMenu = DermaMenu()
	tabMenu:SetSkin("Noir")
	tabMenu:SetDeleteSelf(false)
	tabMenu:SetDrawColumn(true)
	tabMenu:Hide()
	Editor.tabMenu = tabMenu
	Noir.Utils.AddMenuOption(tabMenu, "Close", function()
		if tabMenu.session.sessionType == "console" then
			Editor.CloseConsoleTab(tabMenu.session.name)
		else
			Editor.CloseTab(tabMenu.session.name)
		end
	end, "icon16/tab_delete.png")

	Noir.Utils.AddMenuOption(tabMenu, "Close Others", function()
		for name, v in pairs(Editor.SessionsByName) do
			-- Skip console tab and current session
			if v ~= tabMenu.session and v.sessionType ~= "console" then Editor.CloseTab(name, tabMenu.session.name, true) end
		end

		Editor.QueueSessionsSave()
	end, "icon16/tab_delete.png")

	Noir.Utils.AddMenuOption(tabMenu, "Close to the right", function()
		local idx = table.KeyFromValue(Editor.Sessions, tabMenu.session)
		for i = #Editor.Sessions, idx + 1, -1 do
			-- Skip console tab
			if Editor.Sessions[i].sessionType ~= "console" then Editor.CloseTab(Editor.Sessions[i].name, tabMenu.session.name, true) end
		end

		Editor.QueueSessionsSave()
	end, "icon16/tab_delete.png")

	Noir.Utils.AddMenuOption(tabMenu, "Close Saved", function()
		for _, v in pairs(Editor.Sessions) do
			-- Skip console tab
			if not v.Modified and v.sessionType ~= "console" then Editor.CloseSession(v.name, tabMenu.session.name, true) end
		end

		Editor.QueueSessionsSave()
	end, "icon16/tab_delete.png")

	Noir.Utils.AddMenuOption(tabMenu, "Close All", function()
		local sessions = table.Copy(Editor.Sessions)
		for _, v in pairs(sessions) do
			-- Skip console tab
			if v.sessionType ~= "console" then Editor.CloseTab(v.name, nil, true) end
		end

		Editor.QueueSessionsSave()
	end, "icon16/tab_delete.png")

	tabMenu:AddSpacer():SetTall(10)
	tabMenu.copyPathOption = Noir.Utils.AddMenuOption(tabMenu, "Copy Path", function()
		if not tabMenu.session.file then return end
		SetClipboardText(util.RelativePathToFull(Noir.Utils.GetFilePath(unpack(tabMenu.session.file))))
	end, "icon16/page_white_copy.png")

	tabMenu.copyRelPathOption = Noir.Utils.AddMenuOption(tabMenu, "Copy Relative Path", function()
		if not tabMenu.session.file then return end
		SetClipboardText(Noir.Utils.GetFilePath(unpack(tabMenu.session.file)))
	end, "icon16/page_white_copy.png")

	tabMenu:AddSpacer():SetTall(10)
	Noir.Utils.AddMenuOption(tabMenu, "Save", function() Editor.Save(tabMenu.session.name) end, "icon16/disk.png")
	Noir.Utils.AddMenuOption(tabMenu, "Save as", function() Editor.SaveAs(tabMenu.session.name) end, "icon16/disk.png")
	tabMenu:AddSpacer():SetTall(10)
	Noir.Utils.AddMenuOption(tabMenu, "Rename", function()
		Derma_StringRequest("Rename", "Enter a new name", tabMenu.session.name, function(newName)
			if Editor.SessionsByName[newName] then
				Derma_Message("Error", "Cant rename to `" .. newName .. "`, name already taken", "Ok"):SetSkin("Noir")
				return
			end

			Editor.RenameSession(tabMenu.session.name, newName)
		end):SetSkin("Noir")
	end, "icon16/tag_blue.png")

	tabMenu:AddSpacer():SetTall(10)
	tabMenu.autorunOption = Noir.Utils.AddMenuOption(tabMenu, "Add to Autorun", function()
		if not tabMenu.session.file then return end
		local path, fileName = tabMenu.session.file[1], tabMenu.session.file[2]
		local _, isNowAutorun = Noir.Autorun.Toggle(path, fileName)
		if isNowAutorun then
			Noir.Msg("Added to autorun: ", fileName, "\n")
		else
			Noir.Msg("Removed from autorun: ", fileName, "\n")
		end
	end, "icon16/control_play_blue.png")

	-- VSCode-style activity bar + sidebar. The activity bar is a thin strip of icon
	-- buttons (one per registered view); the sidebar hosts the active view's content.
	-- Views register through Editor.RegisterSidebarView (Explorer is registered at the
	-- bottom of this file). Both dock LEFT, activity bar first so it sits furthest left.
	-- They are docked before the tab scroller so they span the full content height (up
	-- to the menu bar) and the tab strip only covers the editor area to their right.
	local activityBar = frame:Add("DPanel")
	activityBar:SetSkin("Noir")
	activityBar:SetWide(44)
	activityBar:Dock(LEFT)
	-- Negative left/bottom margins pull the bar flush against the frame's border, the
	-- same compensation the Monaco/scroller panels use (the frame insets content ~5px).
	activityBar:DockMargin(-5, 0, 0, -5)
	activityBar:SetBackgroundColor(Color(45, 45, 45))
	Editor.ActivityBar = activityBar
	local sidebar = frame:Add("DPanel")
	sidebar:SetSkin("Noir")
	sidebar:SetWide(Editor.Config.sidebarWidth or 320)
	sidebar:Dock(LEFT)
	sidebar:DockMargin(0, 0, 0, -5)
	sidebar:SetBackgroundColor(Color(37, 37, 38))
	Editor.Sidebar = sidebar
	local sidebarHeader = sidebar:Add("DPanel")
	sidebarHeader:Dock(TOP)
	sidebarHeader:SetTall(24)
	sidebarHeader:SetBackgroundColor(Color(30, 30, 30))
	-- Header layout (docked RIGHT first so the label takes the remaining FILL space):
	-- a persistent hide button, then a per-view action holder, then the title label.
	local hideBtn = sidebarHeader:Add("DButton")
	hideBtn:Dock(RIGHT)
	hideBtn:SetText("")
	hideBtn:SetWide(24)
	hideBtn:SetTooltip("Hide sidebar")
	local hideIcon = Material("icon16/application_side_contract.png")
	hideBtn.Paint = function(_, w, h)
		surface.SetDrawColor(255, 255, 255)
		surface.SetMaterial(hideIcon)
		surface.DrawTexturedRect((w - 16) / 2, (h - 16) / 2, 16, 16)
	end

	hideBtn.DoClick = function() Editor.ToggleSidebar() end
	local headerActions = sidebarHeader:Add("DPanel")
	headerActions:Dock(RIGHT)
	headerActions:SetWide(0)
	headerActions:SetPaintBackground(false)
	Editor.SidebarActions = headerActions
	local sidebarLabel = sidebarHeader:Add("DLabel")
	sidebarLabel:Dock(FILL)
	sidebarLabel:DockMargin(8, 0, 0, 0)
	sidebarLabel:SetTextColor(Color(200, 200, 200))
	sidebarLabel:SetText("")
	Editor.SidebarHeaderLabel = sidebarLabel
	-- View content lives here; each registered view docks FILL and is shown/hidden.
	local sidebarContent = sidebar:Add("DPanel")
	sidebarContent:Dock(FILL)
	sidebarContent:SetPaintBackground(false)
	Editor.SidebarContent = sidebarContent
	sidebar:SetVisible(Editor.Config.sidebarVisible ~= false)
	-- Drag handle for resizing the sidebar. Docked LEFT right after the sidebar so it
	-- sits on its right edge; dragging sets sidebarWidth (clamped between a sane minimum
	-- and the available frame width) and re-lays out the frame so the editor reflows.
	local resizer = frame:Add("DPanel")
	resizer:SetWide(4)
	resizer:Dock(LEFT)
	resizer:DockMargin(0, 0, 0, -5)
	resizer:SetPaintBackground(false)
	resizer:SetCursor("sizewe")
	resizer:SetVisible(Editor.Config.sidebarVisible ~= false)
	Editor.SidebarResizer = resizer
	resizer.Paint = function(self, w, h)
		if not (self.Dragging or self:IsHovered()) then return end
		surface.SetDrawColor(0, 122, 204, self.Dragging and 255 or 160)
		surface.DrawRect(w / 2 - 1, 0, 2, h)
	end

	resizer.OnMousePressed = function(self)
		self.Dragging = true
		self:MouseCapture(true)
	end

	resizer.OnMouseReleased = function(self)
		if not self.Dragging then return end
		self.Dragging = false
		self:MouseCapture(false)
		Editor.SaveConfig()
	end

	resizer.Think = function(self)
		if not self.Dragging then return end
		local minW, maxW = 180, math.max(180, frame:GetWide() - activityBar:GetWide() - 200)
		local sidebarX = sidebar:LocalToScreen(0, 0)
		local mouseX = gui.MouseX()
		local newW = math.Clamp(mouseX - sidebarX, minW, maxW)
		Editor.Config.sidebarWidth = newW
		sidebar:SetWide(newW)
		frame:InvalidateLayout()
	end

	Editor.RebuildActivityBar()
	Editor.ActivateSidebarView(Editor.Config.activeSidebarView or "explorer", true)
	-- Tab strip: docked TOP after the sidebar, so it only spans the editor area.
	local scroller = frame:Add("DHorizontalScroller")
	scroller:Dock(TOP)
	scroller:DockMargin(0, -5, -5, 0)
	scroller:SetTall(36)
	scroller:SetUseLiveDrag(true)
	scroller:SetOverlap(-2)
	scroller:MakeDroppable("TabsDrop")
	scroller.Paint = function(_, w, h)
		surface.SetDrawColor(42, 42, 42)
		surface.DrawRect(0, 0, w, h)
	end

	-- VSCode-style scroll indicator: a thin bar at the bottom edge of the tab
	-- strip showing the scroll position. Only drawn while the strip overflows.
	-- It's bumped to full opacity by Editor.BumpTabScrollIndicator (on tab
	-- add/close/activate), held visible while the strip is hovered, and fades
	-- out otherwise. Drawn in PaintOver so it sits on top of the tab panels.
	scroller.ScrollIndicatorAlpha = 0
	scroller.PaintOver = function(self, w, h)
		local canvas = self.pnlCanvas
		if not IsValid(canvas) then return end
		local content = canvas:GetWide()
		if content <= w then
			self.ScrollIndicatorAlpha = 0
			return
		end

		if self:IsHovered() or self:IsChildHovered() then
			self.ScrollIndicatorAlpha = 255
			self.ScrollIndicatorHold = CurTime() + 0.5
		elseif (self.ScrollIndicatorHold or 0) < CurTime() then
			self.ScrollIndicatorAlpha = math.max(0, (self.ScrollIndicatorAlpha or 0) - FrameTime() * 600)
		end

		local alpha = self.ScrollIndicatorAlpha or 0
		if alpha <= 0 then return end
		local maxOffset = content - w
		local offset = math.Clamp(self.OffsetX or 0, 0, maxOffset)
		local barW = math.max(24, w * (w / content))
		local barX = (w - barW) * (offset / maxOffset)
		surface.SetDrawColor(168, 168, 168, alpha)
		surface.DrawRect(barX, h - 3, barW, 3)
	end

	scroller.OnDragModified = function()
		Editor.Sessions = {}
		for _, v in pairs(scroller.Panels) do
			table.insert(Editor.Sessions, v.Session)
		end

		Editor.QueueSessionsSave()
	end

	Editor.TabsScroller = scroller
	Editor.Tabs = {}
	local monaco = frame:Add("NoirMonacoEditor")
	monaco:DockMargin(0, 0, -5, -5)
	monaco:Dock(FILL)
	Editor.MonacoPanel = monaco
	-- A hack to make space for resizing
	monaco.StatusButton:DockMargin(0, 0, 14, 0)
	monaco.ErrorList:DockMargin(0, 0, 14, 0)
	monaco:SetCursor("sizenwse")
	-- REPL panels are now created per-console in Editor.CreateConsoleTab()
	monaco.OnMousePressed = function(_, ...)
		if frame.Maximized then return end
		frame:OnMousePressed(...)
	end

	monaco.OnMouseReleased = function(_, ...)
		if frame.Maximized then return end
		frame:OnMouseReleased(...)
	end

	monaco.OnReady = function()
		-- Clear existing tabs and console panels (handles script reload case)
		for _, tab in ipairs(Editor.Tabs or {}) do
			if IsValid(tab) then tab:Remove() end
		end

		Editor.Tabs = {}
		-- Clear console REPL panels
		for _, console in pairs(Editor.ConsoleSessions or {}) do
			if console.ReplPanel and IsValid(console.ReplPanel) then console.ReplPanel:Remove() end
		end

		Editor.ConsoleSessions = {}
		Editor.MainConsole = nil
		-- Always load sessions fresh from file
		Editor.LoadSessions()
		for _, session in ipairs(Editor.Sessions) do
			Editor.AddTab(session)
			-- Create REPL panels for restored console sessions
			if session.sessionType == "console" then
				local replPanel = vgui.Create("NoirReplPanel", frame)
				replPanel:DockMargin(0, 0, -5, -5)
				replPanel:Dock(FILL)
				replPanel:SetVisible(false)
				replPanel:SetCursor("sizenwse")
				session.ReplPanel = replPanel
				replPanel.OnMousePressed = function(_, ...)
					if frame.Maximized then return end
					frame:OnMousePressed(...)
				end

				replPanel.OnMouseReleased = function(_, ...)
					if frame.Maximized then return end
					frame:OnMouseReleased(...)
				end

				replPanel.HTMLPanel.OnFocusChanged = function(_, hasFocus)
					frame:SetAlpha(hasFocus and 255 or 190)
					replPanel:SetAlpha(hasFocus and 255 or 190)
				end

				Editor.ConsoleSessions[session.name] = session
				if session.isMainConsole then Editor.MainConsole = session end
			end
		end

		Editor.IsReady = true
		-- Execute any actions that were queued while waiting for ready
		for _, fn in ipairs(Editor.PendingOnReady) do
			fn()
		end

		Editor.PendingOnReady = {}
		-- Validate activeSession exists
		local activeSession = Editor.Config.activeSession
		if not activeSession or not Editor.SessionsByName[activeSession] then
			activeSession = Editor.Sessions[1] and Editor.Sessions[1].name or "Welcome"
			Editor.Config.activeSession = activeSession
		end

		-- Filter out console sessions for Monaco (it only handles editor sessions)
		local editorSessions = {}
		for _, session in ipairs(Editor.Sessions) do
			if session.sessionType ~= "console" then table.insert(editorSessions, session) end
		end

		monaco:LoadSessions(editorSessions, activeSession)
		-- Set the active tab (noJS=true since Monaco already has the session from LoadSessions)
		Editor.SetActiveTab(activeSession, true)
		-- monaco:CloseSession("Unnamed")
		Editor.RegisterActions(monaco)
		-- TODO: SpiralP asked for "Search in lua files" feature
		--      Not sure how im going to implement
		--      Maybe create a separte window with the results?
		--      But what about serverside files?
		-- TODO: Look at find usage code on meta
		monaco:RequestFocus()
	end

	monaco.OnSessionSet = function(_, session)
		if not monaco.Ready then return end
		if session.name == "Unnamed" then
			Noir.Error("Something went wrong, creating an empty session\n")
			Editor.CreateSession()
			monaco:CloseSession("Unnamed")
		else
			Editor.SetActiveTab(session.name, true)
		end
	end

	monaco.OnCode = function(_, code)
		if not Editor.ActiveSession then return end
		local modified = Editor.ActiveSession.SavedCode ~= code
		Editor.ActiveSession.code = code
		Editor.ActiveSession.Modified = modified
		Editor.UpdateSession(Editor.ActiveSession.name, true)
		Editor.UpdateCOH()
	end

	monaco.HTMLPanel.OnFocusChanged = function(_, hasFocus)
		frame:SetAlpha(hasFocus and 255 or 190)
		monaco:SetAlpha(hasFocus and 255 or 190)
	end

	monaco.OnOpenURL = function(_, url) gui.OpenURL(url) end
	monaco.OnValidation = function() Editor.UpdateCOH() end
	frame.OnFocusChanged = function(_, hasFocus)
		Editor.Config.editorSize = {frame:GetSize()}
		frame:SetAlpha(hasFocus and 255 or 190)
		monaco:SetAlpha(hasFocus and 255 or 190)
	end
end

-- Move a file to the front of the recent-files history (dedup, cap at 10) and
-- refresh the "Open Recent" menu. Called on both open and close.
function Editor.AddRecentFile(path, fileName)
	for k, v in pairs(Editor.Config.recentFiles) do
		if v[1] == path and v[2] == fileName then table.remove(Editor.Config.recentFiles, k) end
	end

	table.insert(Editor.Config.recentFiles, 1, {path, fileName})
	if #Editor.Config.recentFiles > 10 then table.remove(Editor.Config.recentFiles) end
	Editor.ReloadRecents()
end

function Editor.ReloadRecents()
	for i = 1, Noir.Editor.RecentSubmenu:ChildCount() do
		Noir.Editor.RecentSubmenu:GetChild(i):Remove()
	end

	if #Editor.Config.recentFiles == 0 then
		Noir.Editor.RecentSubmenu:GetParent():SetDisabled(true)
		return
	else
		Noir.Editor.RecentSubmenu:GetParent():SetDisabled(false)
	end

	for _, v in pairs(Editor.Config.recentFiles) do
		Noir.Utils.AddMenuOption(Editor.RecentSubmenu, Format("[%s] %s", unpack(v)), function() Editor.OpenFile(unpack(v)) end, "icon16/page.png")
	end

	Editor.RecentSubmenu:AddSpacer()
	Noir.Utils.AddMenuOption(Editor.RecentSubmenu, "Clear", function()
		Editor.Config.recentFiles = {}
		Editor.SaveConfig()
		Editor.ReloadRecents()
	end, "icon16/cross.png")
end

-- Flash the tab strip's scroll indicator back to full opacity. Called on tab
-- add/close/activate so the user gets a brief cue of where they are in an
-- overflowing strip; it then decays on its own (see scroller.PaintOver).
function Editor.BumpTabScrollIndicator()
	local scroller = Editor.TabsScroller
	if not IsValid(scroller) then return end
	scroller.ScrollIndicatorAlpha = 255
	scroller.ScrollIndicatorHold = CurTime() + 0.5
end

function Editor.AddTab(session)
	local isConsole = session.sessionType == "console"
	local pnl = vgui.Create("DPanel")
	pnl:SetSkin("Noir")
	pnl:SetSize(135, 36)
	pnl:SetTooltip(session.file and Noir.Utils.GetFilePath(unpack(session.file)) or session.name)
	pnl.Session = session
	session.TabPanel = pnl
	table.insert(Editor.Tabs, pnl)
	local image = vgui.Create("DImage", pnl)
	-- Use terminal icon for console tab
	if isConsole then
		image:SetImage("icon16/application_xp_terminal.png")
	else
		image:SetImage(((session.file and not session.Modified) or session.code == "") and "icon16/page.png" or "icon16/page_red.png")
	end

	image:SizeToContents()
	image:DockMargin(10, 10, -10, 10)
	image:Dock(LEFT)
	pnl.image = image
	local label = pnl:Add("DLabel")
	label:SetText(session.name)
	label:Dock(LEFT)
	label:SetSize(85, 30)
	label:DockMargin(15, 0, 0, 0)
	pnl.label = label
	local closeButton = pnl:Add("DButton")
	pnl.closeButton = closeButton
	closeButton:Dock(RIGHT)
	closeButton:SetText("")
	closeButton:SetTooltip(isConsole and "Hide" or "Close")
	closeButton:SetSize(14, 14)
	closeButton:DockMargin(0, 10, 5, 10)
	closeButton.BackgroundColor = Color(0, 0, 0, 0)
	if isConsole then
		-- Console tab: no modified indicator, always show X on hover
		closeButton.Paint = function(_, w, h)
			if not pnl.IsActive and not pnl:IsHovered() and not closeButton:IsHovered() then return end
			if closeButton:IsHovered() then draw.RoundedBox(3, 0, 0, w, h, Color(90, 90, 90, closeButton:GetAlpha())) end
			draw.DrawText("r", "Marlett", w / 2, 2, Color(255, 255, 255, closeButton:GetAlpha()), TEXT_ALIGN_CENTER)
			return true
		end
	else
		closeButton.Paint = function(_, w, h)
			if not pnl.IsActive and not pnl:IsHovered() and not closeButton:IsHovered() and not session.Modified then return end
			if closeButton:IsHovered() then draw.RoundedBox(3, 0, 0, w, h, Color(90, 90, 90, closeButton:GetAlpha())) end
			draw.DrawText(
				closeButton:IsHovered() and "r" or (session.Modified and "n" or "r"),
				"Marlett", w / 2, 2, Color(255, 255, 255, closeButton:GetAlpha()), TEXT_ALIGN_CENTER
			)
			return true
		end
	end

	closeButton.DoClick = function()
		if isConsole then
			Editor.CloseConsoleTab(session.name)
		else
			Editor.CloseTab(session.name)
		end
	end

	local oOnMousePressed = pnl.OnMousePressed
	pnl.OnMousePressed = function(_, keyCode)
		if keyCode == MOUSE_LEFT then
			Editor.SetActiveTab(session.name)
			-- Disable double-click rename for console tab
			if not isConsole and pnl.LastLeftClick and (CurTime() - pnl.LastLeftClick) < 0.5 then
				Derma_StringRequest("Rename", "Enter a new name", session.name, function(newName)
					if Editor.SessionsByName[newName] then
						Derma_Message("Error", "Cant rename to `" .. newName .. "`, name already taken", "Ok"):SetSkin("Noir")
						return
					end

					Editor.RenameSession(session.name, newName)
				end):SetSkin("Noir")
				return
			end

			pnl.LastLeftClick = CurTime()
		elseif keyCode == MOUSE_RIGHT then
			if Editor.tabMenu:IsVisible() then
				Editor.tabMenu:Hide()
				if Editor.tabMenu.session ~= session then return end
			end

			Editor.tabMenu.session = session
			Editor.tabMenu.copyPathOption:SetDisabled(session.file == nil or isConsole)
			Editor.tabMenu.copyRelPathOption:SetDisabled(session.file == nil or isConsole)
			-- Update autorun option
			if session.file and not isConsole then
				Editor.tabMenu.autorunOption:SetDisabled(false)
				local isAutorun = Noir.Autorun.IsAutorun(session.file[1], session.file[2])
				Editor.tabMenu.autorunOption:SetText(isAutorun and "Remove from Autorun" or "Add to Autorun")
				Editor.tabMenu.autorunOption:SetIcon(isAutorun and "icon16/control_stop_blue.png" or "icon16/control_play_blue.png")
			else
				Editor.tabMenu.autorunOption:SetDisabled(true)
				Editor.tabMenu.autorunOption:SetText("Add to Autorun")
			end

			Editor.tabMenu:Open(gui.MouseX(), gui.MouseY(), false, pnl)
		elseif keyCode == MOUSE_MIDDLE then
			if isConsole then
				Editor.CloseConsoleTab(session.name)
			else
				Editor.CloseTab(session.name)
			end
		end

		oOnMousePressed(pnl, keyCode)
	end

	pnl.Paint = function(_, w, h)
		if pnl.IsActive then
			surface.SetDrawColor(36, 36, 36)
		else
			surface.SetDrawColor(49, 49, 49)
		end

		surface.DrawRect(0, 0, w, h)
	end

	Editor.TabsScroller:AddPanel(pnl)
	Editor.BumpTabScrollIndicator()
	return pnl
end

-- Sidebar view registry (VSCode-style). Each view contributes an activity-bar icon
-- and lazily builds its content into the shared sidebar container. Modules register
-- through Editor.RegisterSidebarView; the Explorer is registered at the bottom of
-- this file. A view def has these fields:
--   title    string  - shown in the sidebar header
--   icon     string  - activity-bar icon (Material path)
--   tooltip  string  - activity-bar button tooltip (defaults to title)
--   build    function(container) -> Panel  - called once, the first time it is shown
--   actions  table   - optional header buttons, each {icon, tooltip, onClick}
--   onShow   function(panel)  - optional, called whenever the view is revealed
Editor.SidebarViews = Editor.SidebarViews or {}
Editor.SidebarViewOrder = Editor.SidebarViewOrder or {}
function Editor.RegisterSidebarView(id, def)
	def.id = id
	local existing = Editor.SidebarViews[id]
	if existing then
		-- Re-registration (script reload): drop the stale panel so it gets rebuilt.
		if IsValid(existing.panel) then existing.panel:Remove() end
	else
		table.insert(Editor.SidebarViewOrder, id)
	end

	Editor.SidebarViews[id] = def
	-- If the frame already exists, refresh the activity bar and rebuild the content
	-- of this view when it happens to be the active one (again, reload case).
	if IsValid(Editor.ActivityBar) then
		Editor.RebuildActivityBar()
		if Editor.ActiveSidebarView == id then Editor.ActivateSidebarView(id, true) end
	end
end

-- Rebuild the activity-bar buttons from the registered views.
function Editor.RebuildActivityBar()
	local bar = Editor.ActivityBar
	if not IsValid(bar) then return end
	bar:Clear()
	Editor.ActivityButtons = {}
	for _, id in ipairs(Editor.SidebarViewOrder) do
		local def = Editor.SidebarViews[id]
		local btn = bar:Add("DButton")
		btn:Dock(TOP)
		btn:SetTall(44)
		btn:SetText("")
		btn:SetTooltip(def.tooltip or def.title or id)
		local icon = Material(def.icon or "icon16/bullet_white.png")
		btn.Paint = function(self, w, h)
			local active = Editor.ActiveSidebarView == id and Editor.Config.sidebarVisible
			if active then
				surface.SetDrawColor(0, 127, 212)
				surface.DrawRect(0, 0, 2, h)
			end

			if active or self:IsHovered() then
				surface.SetDrawColor(255, 255, 255, 18)
				surface.DrawRect(0, 0, w, h)
			end

			surface.SetDrawColor(255, 255, 255, (active or self:IsHovered()) and 255 or 150)
			surface.SetMaterial(icon)
			surface.DrawTexturedRect((w - 16) / 2, (h - 16) / 2, 16, 16)
		end

		btn.DoClick = function() Editor.ActivateSidebarView(id) end
		Editor.ActivityButtons[id] = btn
	end
end

-- Populate the sidebar header's per-view action buttons.
function Editor.RebuildSidebarActions(def)
	local holder = Editor.SidebarActions
	if not IsValid(holder) then return end
	holder:Clear()
	local list = def and def.actions or {}
	holder:SetWide(#list * 24)
	for _, action in ipairs(list) do
		local btn = holder:Add("DButton")
		btn:Dock(RIGHT)
		btn:SetWide(24)
		btn:SetText("")
		btn:SetTooltip(action.tooltip)
		local icon = Material(action.icon)
		btn.Paint = function(self, w, h)
			surface.SetDrawColor(255, 255, 255, self:IsHovered() and 255 or 200)
			surface.SetMaterial(icon)
			surface.DrawTexturedRect((w - 16) / 2, (h - 16) / 2, 16, 16)
		end

		btn.DoClick = action.onClick
	end
end

-- Switch the sidebar to a registered view (building its content on first use) and
-- reveal the sidebar. `initial` is used during frame setup: it suppresses the
-- click-to-collapse toggle and respects the saved visibility instead of forcing it.
function Editor.ActivateSidebarView(id, initial)
	local def = Editor.SidebarViews[id]
	if not def then return end
	-- Clicking the already-active icon collapses the sidebar (VSCode behaviour).
	if not initial and Editor.ActiveSidebarView == id and Editor.Config.sidebarVisible then
		Editor.ToggleSidebar()
		return
	end

	-- Build the view's content lazily the first time it is shown.
	if not IsValid(def.panel) then
		def.panel = def.build(Editor.SidebarContent)
		if IsValid(def.panel) then def.panel:Dock(FILL) end
	end

	-- Swap the visible view.
	local prev = Editor.SidebarViews[Editor.ActiveSidebarView]
	if prev and prev ~= def and IsValid(prev.panel) then prev.panel:SetVisible(false) end
	Editor.ActiveSidebarView = id
	if IsValid(def.panel) then def.panel:SetVisible(true) end
	if IsValid(Editor.SidebarHeaderLabel) then Editor.SidebarHeaderLabel:SetText(def.title or id) end
	Editor.RebuildSidebarActions(def)
	Editor.Config.activeSidebarView = id
	-- Reveal the sidebar when switching views interactively.
	if not initial and not Editor.Config.sidebarVisible then
		Editor.Config.sidebarVisible = true
		Editor.Sidebar:SetVisible(true)
		if IsValid(Editor.SidebarResizer) then Editor.SidebarResizer:SetVisible(true) end
		Editor.Frame:InvalidateLayout()
	end

	Editor.SaveConfig()
	if def.onShow and Editor.Config.sidebarVisible then def.onShow(def.panel) end
end

function Editor.ToggleSidebar()
	if not IsValid(Editor.Sidebar) then return end
	Editor.Config.sidebarVisible = Editor.Config.sidebarVisible == false
	Editor.Sidebar:SetVisible(Editor.Config.sidebarVisible)
	if IsValid(Editor.SidebarResizer) then Editor.SidebarResizer:SetVisible(Editor.Config.sidebarVisible) end
	Editor.SaveConfig()
	if Editor.Config.sidebarVisible then
		local def = Editor.SidebarViews[Editor.ActiveSidebarView]
		if def and def.onShow then def.onShow(def.panel) end
	end

	Editor.Frame:InvalidateLayout()
end

-- Decide which root folder (DATA / LUA / GAME) the sidebar should show for a session.
-- Files are already normalised to DATA/LUA/GAME by Noir.Utils.FixFilePath when opened,
-- so a session's stored path is exactly "in data -> DATA, in lua -> LUA, otherwise GAME".
-- When there is no file (console/unsaved tab) or following is disabled, fall back to the
-- configurable default root. Both behaviours are exposed in the Dashboard ("Editor" tab).
function Editor.GetSidebarRootPath(session)
	local follow, default = true, "DATA"
	if Noir.Dashboard then
		local configured = Noir.Dashboard.Get("Editor", "sidebarFollowFile")
		if configured ~= nil then follow = configured end
		default = Noir.Dashboard.Get("Editor", "sidebarDefaultPath") or default
	end

	if follow and session and session.file and session.file[1] then return session.file[1] end
	return default
end

-- Expand every parent folder down to the active file, select it, and queue it to be
-- scrolled into view (the actual scroll happens in tree.Think once layout has settled).
function Editor.RevealSidebarFile(folder, fileName)
	local node = Editor.SidebarRoot
	if not IsValid(node) then return end
	node:FilePopulate(false, false)
	node:SetExpanded(true)
	if folder and folder ~= "" then
		for _, part in ipairs(string.Split(folder, "/")) do
			local found
			for _, child in ipairs(node.ChildNodes and node.ChildNodes:GetChildren() or {}) do
				if child:GetText() == part then
					found = child
					break
				end
			end

			if not IsValid(found) then return end
			found:FilePopulate(false, false)
			found:SetExpanded(true)
			node = found
		end
	end

	local target = node
	if fileName and fileName ~= "" then
		local baseName = string.GetFileFromFilename(fileName)
		for _, child in ipairs(node.ChildNodes and node.ChildNodes:GetChildren() or {}) do
			if child:GetText() == baseName then
				target = child
				Editor.SidebarTree:SetSelectedItem(child)
				break
			end
		end
	end

	Editor.SidebarTree.PendingScroll = target
end

-- Collapse every folder in the explorer, leaving only the top-level entries visible.
function Editor.CollapseSidebar()
	local root = Editor.SidebarRoot
	if not IsValid(root) then return end
	local function collapse(node)
		for _, child in ipairs(node.ChildNodes and node.ChildNodes:GetChildren() or {}) do
			collapse(child)
			child:SetExpanded(false)
		end
	end

	collapse(root)
	root:SetExpanded(true)
	if IsValid(Editor.SidebarTree.VBar) then Editor.SidebarTree.VBar:SetScroll(0) end
end

function Editor.NavigateSidebarToActive(force)
	if not IsValid(Editor.SidebarTree) then return end
	if not Editor.Sidebar:IsVisible() and not force then return end
	local session = Editor.ActiveSession
	local path = Editor.GetSidebarRootPath(session)
	local folder, fileName = "", nil
	if session and session.file and session.file[1] == path then
		fileName = session.file[2]
		folder = string.Trim(string.GetPathFromFilename(fileName) or "", "/")
	end

	-- Rebuild the tree only when the root path changes (or when forced) so switching
	-- between files in the same root preserves the user's manually expanded folders.
	if force or Editor.SidebarPath ~= path or not IsValid(Editor.SidebarRoot) then
		Editor.SidebarPath = path
		local tree = Editor.SidebarTree
		tree:Clear()
		local root = tree:AddNode(path)
		root:MakeFolder("", path, true)
		root:SetExpanded(true)
		Editor.SidebarRoot = root
		if IsValid(Editor.SidebarHeaderLabel) then Editor.SidebarHeaderLabel:SetText(path) end
	end

	Editor.SidebarFolder = folder
	Editor.RevealSidebarFile(folder, fileName)
end

function Editor.SetActiveTab(sessionName, noJS)
	if not Editor.SessionsByName[sessionName] then return end
	local session = Editor.SessionsByName[sessionName]
	local sessionType = session.sessionType or "editor"
	-- Mark old tab as inactive
	if Editor.ActiveSession and IsValid(Editor.ActiveSession.TabPanel) then Editor.ActiveSession.TabPanel.IsActive = false end
	-- Update active session
	Editor.ActiveSession = session
	-- Switch between Monaco and REPL panels
	Editor.SetContentPanel(sessionType)
	-- Only interact with Monaco for editor sessions
	if sessionType == "editor" and not noJS then Editor.MonacoPanel:SetSession(sessionName) end
	-- Mark new tab as active and scroll to it
	if Editor.ActiveSession.TabPanel then
		Editor.ActiveSession.TabPanel.IsActive = true
		Editor.TabsScroller:ScrollToChild(Editor.ActiveSession.TabPanel)
		Editor.BumpTabScrollIndicator()
	end

	Editor.Frame:SetTitle(sessionName .. " - [Noir Lua Editor]")
	Editor.Config.activeSession = sessionName
	Editor.UpdateSession(sessionName)
	Editor.SaveConfig()
	Editor.QueueSessionsSave()
	Editor.NavigateSidebarToActive()
end

function Editor.CreateSession(sessionName, code, fileData, sessionData)
	if sessionName == "Unnamed" then
		Derma_Message("Cant create session named 'Unnamed'", "Sorry ~~", "Ok then :c"):SetSkin("Noir")
		return
	end

	if not sessionName then
		sessionName = "Untitled-1"
		local i = 1
		while Editor.SessionsByName[sessionName] do
			i = i + 1
			sessionName = "Untitled-" .. i
		end
	end

	if Editor.SessionsByName[sessionName] then error("Cant create session, name already taken") end
	code = code or ""
	Noir.Debug("CreateSession", sessionName, code)
	local session = {
		name = sessionName,
		code = code,
		file = fileData,
		SavedCode = fileData and code or ""
	}

	session = table.Merge(sessionData or {}, session)
	Editor.MonacoPanel:CreateSession(session)
	table.insert(Editor.Sessions, session)
	Editor.SessionsByName[sessionName] = session
	Editor.AddTab(session)
	Editor.QueueSessionsSave()
	return session
end

-- Reopen the most recently closed file (VS Code's Ctrl+Shift+T). Reuses the
-- recent-files history: pick the most recent entry that isn't already open.
-- Scratch/unsaved tabs have no file, so they aren't restored -- same model as
-- "Open Recent".
function Editor.ReopenClosedTab()
	for _, entry in ipairs(Editor.Config.recentFiles) do
		local path, fileName = entry[1], entry[2]
		local alreadyOpen = false
		for _, v in ipairs(Editor.Sessions) do
			if v.file and v.file[1] == path and v.file[2] == fileName then
				alreadyOpen = true
				break
			end
		end

		if not alreadyOpen then
			Editor.OpenFile(path, fileName)
			return
		end
	end
end

function Editor.CloseSession(sessionName, nextActive, noSave)
	local session = Editor.SessionsByName[sessionName]
	-- Closing a file is an interaction too: bump it to the front of recents so
	-- "Reopen Closed Tab" / "Open Recent" reflect close order.
	if session and session.file then Editor.AddRecentFile(unpack(session.file)) end
	local idx = table.KeyFromValue(Editor.Sessions, session)
	if #Editor.Sessions == 1 then nextActive = Editor.CreateSession().name end
	session.TabPanel:Remove()
	Editor.TabsScroller:PerformLayout()
	Editor.BumpTabScrollIndicator()
	table.remove(Editor.Sessions, idx)
	Editor.SessionsByName[sessionName] = nil
	if nextActive and Editor.SessionsByName[nextActive] then
		Editor.SetActiveTab(nextActive)
	else
		Editor.SetActiveTab(Editor.Sessions[#Editor.Sessions < idx and #Editor.Sessions or idx].name)
	end

	if not session or session.sessionType ~= "console" then Editor.MonacoPanel:CloseSession(sessionName) end
	if noSave then return end
	Editor.QueueSessionsSave()
end

function Editor.RenameSession(sessionName, newName)
	if sessionName == newName then return end
	if Editor.SessionsByName[newName] then
		error("Cant rename to '" .. sessionName .. "' name already taken")
		return
	end

	if not Editor.SessionsByName[sessionName] then return end
	local session = Editor.SessionsByName[sessionName]
	session.name = newName
	Editor.SessionsByName[sessionName] = nil
	Editor.SessionsByName[newName] = session
	if session.TabPanel then
		session.TabPanel:SetTooltip(session.file and Format("[%s] %s", unpack(session.file)) or session.name)
		session.TabPanel.label:SetText(newName)
	end

	if Editor.ActiveSession == session then
		Editor.Config.activeSession = newName
		Editor.SaveConfig()
	end

	Editor.MonacoPanel:RenameSession(newName, sessionName)
	Editor.QueueSessionsSave()
end

function Editor.UpdateSession(sessionName)
	local session = Editor.SessionsByName[sessionName]
	-- Skip icon updates for console tab (always uses terminal icon)
	if session.sessionType == "console" then return end
	-- Used to update code here with latest in file but it breaks if switching tabs fast
	if IsValid(session.TabPanel) then
		session.TabPanel:SetTooltip(session.file and Format("[%s] %s", unpack(session.file)) or session.name)
		session.TabPanel.label:SetText(sessionName)
		session.TabPanel.image:SetImage(session.Modified and "icon16/page_red.png" or "icon16/page.png")
	end
end

function Editor.CloseTab(sessionName, nextActive, noSave)
	local session = Editor.SessionsByName[sessionName]
	if not session then return end
	if session.Modified then
		Derma_Query("Dou you want to save changes to " .. sessionName .. "?", "Save?", "Save", function()
			Editor.Save(sessionName, function(saved, name)
				if saved then Editor.CloseSession(name, nextActive, noSave) end
			end)
		end, "Dont save", function()
			Editor.CloseSession(sessionName, nextActive, noSave)
		end, "Cancel"):SetSkin("Noir")
	else
		Editor.CloseSession(sessionName, nextActive, noSave)
	end
end

function Editor.GetLanguageFromFilename(fileName)
	if not Editor.MonacoPanel.Ready then return "plaintext" end
	if fileName:EndsWith(".lua.txt") then return "glua" end
	local file_ext = string.GetExtensionFromFilename(fileName)
	if file_ext then
		file_ext = "." .. file_ext
	else
		return "plaintext"
	end

	if file_ext == ".lua" then return "glua" end
	-- Noir.Editor.MonacoPanel.avaliableLaungages[1].extensions
	for _, v in pairs(Editor.MonacoPanel.avaliableLaungages or {}) do
		for _, ext in pairs(v.extensions or {}) do
			if file_ext == ext then return v.id end
		end
	end
	return "plaintext"
end

function Editor.RunCode(target)
	if Editor.ActiveSession and Editor.ActiveSession.sessionType == "console" then return end
	Editor.LastRunTarget = target
	Editor.QueueSessionsSave()
	local targets
	if target == "clients" then
		targets = #player.GetHumans()
	elseif target == "shared" then
		targets = #player.GetHumans() + 1
	else
		targets = 1
	end

	local id = Noir.Network.GenerateTransferId()
	if not id then
		Editor.MonacoPanel:SetStatus("Could not send code! See console for details", Color(150, 0, 0))
		return
	end

	local totalRan = 0
	local hasError = false
	Noir.Environment.RegisterHandler(function(sender, transferId, _, data)
		totalRan = totalRan + 1
		local tbl = util.JSONToTable(data)
		if not tbl then
			hasError = true
			Noir.Error("Received invalid response from ", sender == Entity(0) and "SERVER" or tostring(sender), "\nData: ", data, "\n")
			return
		end

		local done, returns = unpack(util.JSONToTable(data))
		local senderName = sender == Entity(0) and "SERVER" or tostring(sender)
		if not done then
			hasError = true
			local msg, line = Noir.Utils.ParseLuaError(returns, Editor.ActiveSession.name)
			if CLIENT and sender == LocalPlayer() then
				Editor.MonacoPanel:AddLuaError(msg, line)
				Editor.MonacoPanel:SetStatus(Format("Error: %s at line %s", msg, line), Color(150, 0, 0), true)
			else
				Editor.MonacoPanel:AddLuaError(Format("[%s] %s", senderName, msg), line)
				Editor.MonacoPanel:SetStatus(Format("[%s] Error: %s at line %s", senderName, msg, line), Color(150, 0, 0), true)
			end
		elseif not hasError then
			if targets ~= 1 then
				Editor.MonacoPanel:SetStatus(Format("[%i/%i] Ran on %s successfully", totalRan, targets, senderName), Color(0, 150, 0), true)
			else
				Editor.MonacoPanel:SetStatus(Format("Ran on %s successfully", senderName), Color(0, 150, 0), true)
			end
		end
	end, id, "run")

	-- Get the main console panel for output (creates it if needed)
	local replPanel = Editor.GetMainConsolePanel()
	if replPanel then
		local sessionName = Editor.ActiveSession.name
		local runStartTime = SysTime()
		local hasFocused = false
		Noir.Environment.RegisterHandler(function(sender, transferId, message, data)
			local done, returns = unpack(util.JSONToTable(data) or {})
			if message == "run" and done and returns == "nil" then return end
			local displayname = Format("%s[%s]", sessionName, table.concat({string.match(id, "(%x%x)%x+(%x%x)$")}, ".."))
			if targets ~= 1 then displayname = displayname .. "-" .. (sender == Entity(0) and "SERVER" or tostring(sender)) end
			local succ, err = pcall(replPanel.OnMessage, replPanel, target, displayname, sender, transferId, message, data)
			if not succ then replPanel:AppendText(Format("--[[%s: Could not display output]] %s", displayname, err)) end
			-- Only focus main console if output arrives immediately after running (within 1 second)
			if not hasFocused and (SysTime() - runStartTime) < 1 then
				hasFocused = true
				Editor.FocusMainConsole()
			end
		end, id)
	end

	Noir.SendCode(Editor.ActiveSession.code, Editor.ActiveSession.name, target, id)
end

function Editor.OpenFile(path, fileName)
	path, fileName = Noir.Utils.FixFilePath(path, fileName)
	for _, v in pairs(Editor.Sessions) do
		if v.file and v.file[1] == path and v.file[2] == fileName then
			Editor.SetActiveTab(v.name)
			return
		end
	end

	local f = file.Open(fileName, "rb", path)
	if not f then
		Noir.Error("Cant open file ", Color(0, 200, 0), Noir.Utils.GetFilePath(path, fileName), "\n")
		return
	end

	local code = f:Read(f:Size())
	f:Close()
	local name = string.GetFileFromFilename(fileName)
	if Editor.SessionsByName[name] then name = Format("[%s] %s", path, name) end
	if Editor.SessionsByName[name] then name = Format(Noir.Utils.GetFilePath(path, fileName)) end
	Editor.AddRecentFile(path, fileName)
	local lang = Editor.GetLanguageFromFilename(fileName)
	Noir.Debug("OpenFile", path, fileName, name)
	return Editor.CreateSession(name, code or "", {path, fileName}, {
		language = lang
	})
end

function Editor.SaveAs(sessionName, callback)
	local session
	if not sessionName then
		session = Editor.ActiveSession
		sessionName = session.name
	else
		session = Editor.SessionsByName[sessionName]
	end

	if not session then return end
	if session.sessionType == "console" then return end
	local fileName = sessionName
	local extension = string.GetExtensionFromFilename(fileName)
	if not extension then
		fileName = fileName .. ".lua.txt"
	elseif extension ~= "txt" and extension ~= "json" then
		fileName = fileName .. ".txt"
	end

	Noir.FileBrowser.SaveDialog(fileName, function(fullname)
		fullname = fullname:lower()
		Noir.Debug("SaveAs", fullname, session)
		file.Write(fullname, session.code)
		session.file = {"DATA", fullname}
		session.SavedCode = session.code
		session.Modified = false
		local name = string.GetFileFromFilename(fullname)
		if Editor.SessionsByName[name] and Editor.SessionsByName[name] ~= session then name = Format("[%s] %s", "DATA", name) end
		if Editor.SessionsByName[name] and Editor.SessionsByName[name] ~= session then
			name = Format(Noir.Utils.GetFilePath("DATA", fullname))
		end
		-- Editor.RenameSession(sessionName, name)
		Editor.UpdateSession(sessionName, true)
		Editor.QueueSessionsSave()
		if callback then callback(true, name, fullname) end
	end, function() if callback then callback(false) end end)
end

function Editor.Save(sessionName, callback)
	local session
	if not sessionName then
		session = Editor.ActiveSession
	else
		session = Editor.SessionsByName[sessionName]
	end

	if not session then return end
	if session.sessionType == "console" then return end
	if session.file and session.file[1] == "DATA" then
		file.Write(session.file[2], session.code)
		session.SavedCode = session.code
		session.Modified = false
		Editor.UpdateSession(session.name)
		if callback then callback(true, sessionName, session.file[2]) end
	else
		Editor.SaveAs(sessionName, callback)
	end
end

function Editor.QueueSessionsSave()
	Editor.MonacoPanel.OnSessions = function(_, sessions)
		Editor.UpdateCOH()
		Editor.SaveJSSessions(sessions)
	end

	Editor.MonacoPanel:GetSessions()
end

function Editor.SaveJSSessions(jsSessionsData)
	local sessions = table.Copy(Editor.Sessions)
	local sessionsByName = {}
	for _, v in pairs(sessions) do
		sessionsByName[v.name] = v
	end

	for _, v in pairs(jsSessionsData) do
		if sessionsByName[v.name] then
			local session = sessionsByName[v.name]
			table.Merge(session, v)
			table.Merge(Editor.SessionsByName[v.name], v)
			session.SavedCode = nil
			if session.file and not session.Modified then session.code = nil end
		end
	end

	file.Write(Noir.STORAGE_PATH .. "sessions.json", util.TableToJSON(sessions, Noir.DEBUG))
end

function Editor.LoadConfig()
	if file.Exists(Noir.STORAGE_PATH .. "config.json", "DATA") then
		Editor.Config = util.JSONToTable(file.Read(Noir.STORAGE_PATH .. "config.json"))
	else
		Noir.Debug("config.json does not exist, creating new one")
		Editor.Config = {
			recentFiles = {},
			editorPosition = {100, 100},
			editorSize = {700, 700},
			activeSession = "Welcome",
			sidebarVisible = true,
			sidebarWidth = 320,
			activeSidebarView = "explorer"
		}

		if Noir.DEBUG then
			Editor.Config.recentFiles = {{"GAME", "gameinfo.txt"}, {"LUA", "includes/init.lua"}, {"DATA", Noir.STORAGE_PATH .. "config.json"}}
		end
		Editor.SaveConfig()
	end
end

function Editor.SaveConfig()
	file.Write(Noir.STORAGE_PATH .. "config.json", util.TableToJSON(Editor.Config, Noir.DEBUG))
end

function Editor.LoadSessions()
	if file.Exists(Noir.STORAGE_PATH .. "sessions.json", "DATA") then
		Editor.Sessions = util.JSONToTable(file.Read(Noir.STORAGE_PATH .. "sessions.json"))
	else
		Noir.Debug("sessions.json does not exist, creating new one")
		Editor.Sessions = {
			{
				code = "-- Welcome to Noir lua editor!\n-- I hope you like my shitcode ~~",
				name = "Welcome"
			}
		}

		Editor.SaveSessions()
	end

	Editor.SessionsByName = {}
	for _, v in pairs(Editor.Sessions) do
		Editor.SessionsByName[v.name] = v
		if v.file then
			if file.Exists(v.file[2], v.file[1]) then
				v.SavedCode = file.Read(v.file[2], v.file[1])
				if not v.Modified then v.code = v.SavedCode end
			else
				v.file = nil
				v.code = "-- File does not exists anymore :c"
			end
		else
			v.SavedCode = ""
		end
	end
end

function Editor.SaveSessions()
	file.Write(Noir.STORAGE_PATH .. "sessions.json", util.TableToJSON(Editor.Sessions, Noir.DEBUG))
end

function Editor.UpdateCOH()
	if not coh or not Editor.ActiveSession then return end
	local cohText = Format(
		"%d Tab(s) - Current: %s\n%d line(s)",
		#Editor.Sessions, Editor.ActiveSession.name, #string.Split(Editor.ActiveSession.code, "\n")
	)
	if Editor.MonacoPanel and Editor.MonacoPanel.LastReport then
		if Editor.MonacoPanel.LastReport.errors ~= 0 then
			cohText = cohText .. "; Contains errors :c"
		else
			cohText = cohText .. Format("; %d warning(s)", Editor.MonacoPanel.LastReport.warnings)
		end
	end

	local maxLineLen = 0
	for _, line in pairs(string.Split(cohText, "\n")) do
		maxLineLen = math.max(maxLineLen, string.len(line))
	end

	local indentSize = math.ceil(maxLineLen / 2)
	cohText = string.rep(" ", indentSize) .. "[Noir Editor]" .. string.rep(" ", indentSize) .. "\n" .. cohText
	coh.SendTypedMessage(cohText)
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
		}
	}, {
		icon = "icon16/application_side_tree.png",
		description = "Editor and file explorer settings"
	})

	-- Re-navigate the sidebar immediately when either setting changes.
	local function refresh() Editor.NavigateSidebarToActive(true) end
	Noir.Dashboard.OnChange("Editor", "sidebarFollowFile", refresh)
	Noir.Dashboard.OnChange("Editor", "sidebarDefaultPath", refresh)
	Editor.DashboardRegistered = true
end

-- Built-in Explorer view (the file tree). This is the first/default sidebar view;
-- other modules can contribute their own via Editor.RegisterSidebarView.
Editor.RegisterSidebarView("explorer", {
	title = "Explorer",
	icon = "icon16/folder_explore.png",
	tooltip = "Explorer",
	actions = {
		{
			icon = "icon16/arrow_refresh.png",
			tooltip = "Refresh",
			onClick = function() Editor.NavigateSidebarToActive(true) end
		},
		{
			icon = "icon16/arrow_in.png",
			tooltip = "Collapse all folders",
			onClick = function() Editor.CollapseSidebar() end
		}
	},
	onShow = function() Editor.NavigateSidebarToActive() end,
	build = function(container)
		local tree = container:Add("DTree")
		tree:Dock(FILL)
		tree:SetPaintBackground(false)
		Editor.SidebarTree = tree
		-- Reveal-into-view is deferred to Think because node positions are only valid after
		-- the layout pass that follows the frame in which we expand the parent folders.
		tree.Think = function(self)
			local target = self.PendingScroll
			if not IsValid(target) or not IsValid(self.VBar) then return end
			self.PendingScroll = nil
			local _, ty = target:LocalToScreen(0, 0)
			local _, treeY = self:LocalToScreen(0, 0)
			self.VBar:SetScroll(self.VBar:GetScroll() + (ty - treeY) - self:GetTall() * 0.5)
		end

		tree.DoClick = function(_, node)
			local fileName = node.GetFileName and node:GetFileName()
			if fileName and fileName ~= "" then
				Editor.OpenFile(Editor.SidebarPath, fileName)
				return
			end
		end

		tree.DoRightClick = function(_, node)
			local fileName = node.GetFileName and node:GetFileName()
			if not fileName or fileName == "" then return end
			local menu = DermaMenu()
			menu:SetSkin("Noir")
			Noir.Utils.AddMenuOption(menu, "Open", function() Editor.OpenFile(Editor.SidebarPath, fileName) end, "icon16/page.png")
			Noir.Utils.AddMenuOption(menu, "Copy Path", function()
				SetClipboardText(Noir.Utils.GetFilePath(Editor.SidebarPath, fileName))
			end, "icon16/page_white_copy.png")
			menu:Open()
		end

		return tree
	end
})

concommand.Add("noir_clearconfig", function()
	Editor.Config = {}
	Editor.Sessions = {}
	file.Delete(Noir.STORAGE_PATH .. "config.json")
	file.Delete(Noir.STORAGE_PATH .. "sessions.json")
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
