local Editor = Noir.Editor or {}
Noir.Editor = Editor
Editor.IsReady = false
Editor.Sessions = Editor.Sessions or {}
Editor.SessionsByName = Editor.SessionsByName or {}
Editor.ConsoleSessions = {}  -- Track all console sessions
Editor.MainConsole = nil     -- The main console that receives all script output
Editor.ConsoleCounter = 0    -- Counter for naming new consoles
Editor.PendingOnReady = {}   -- Actions queued until editor is ready

-- Toggle between Monaco editor and REPL panel based on session type
function Editor.SetContentPanel(sessionType)
	local isConsole = sessionType == "console"

	-- Hide all console panels first
	for _, console in pairs(Editor.ConsoleSessions) do
		if console.ReplPanel then
			console.ReplPanel:SetVisible(false)
		end
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
		replPanel:DockMargin(-5, 0, -5, -5)
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

	if isMain then
		Editor.MainConsole = session
	end

	return session
end

-- Show the main console tab (create if needed)
function Editor.ShowMainConsole()
	-- Queue if editor isn't ready yet (takes a moment to initialize)
	if not Editor.IsReady then
		table.insert(Editor.PendingOnReady, Editor.ShowMainConsole)
		return
	end
	if not Editor.MainConsole then
		Editor.CreateConsoleTab("Main Console", true)
	end
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
	if Editor.MainConsole == session then
		Editor.MainConsole = nil
	end

	-- Close the session
	Editor.CloseSession(consoleName)
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
	if not Editor.MainConsole then
		Editor.CreateConsoleTab("Main Console", true)
	end
	return Editor.MainConsole and Editor.MainConsole.ReplPanel
end

-- Focus the main console (used after script output)
function Editor.FocusMainConsole()
	if Editor.MainConsole then
		Editor.SetActiveTab(Editor.MainConsole.name)
	end
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
	if not Editor.Config or Noir.DEBUG then
		Editor.LoadConfig()
	end

	-- TODO: Add a file borwser and session list to the left of the editor like in vscode
	-- TODO: Make a re-open feature?
	--      In vs-code re-open only works for files so I can probably use the recent history to do it

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

	Noir.Utils.AddMenuOption(fileMenu, "New", function()
		Editor.CreateSession()
	end, "icon16/page_add.png")

	fileMenu:AddSpacer():SetTall(10)

	Noir.Utils.AddMenuOption(fileMenu, "Open", function()
		Noir.FileBrowser.Open(true)
	end, "icon16/folder.png")

	local recentSubmenu, recentMenu = fileMenu:AddSubMenu("Open Recent")
	-- recentMenu:SetIcon("icon16/table_multiple.png")
	recentMenu:SetTextColor(Color(200, 200, 200))
	recentSubmenu:SetDeleteSelf(false)
	Editor.RecentSubmenu = recentSubmenu
	Editor.ReloadRecents()
	fileMenu:AddSpacer():SetTall(10)

	Noir.Utils.AddMenuOption(fileMenu, "Save", function()
		Editor.Save()
	end, "icon16/disk.png")

	Noir.Utils.AddMenuOption(fileMenu, "Save as", function()
		Editor.SaveAs()
	end, "icon16/page_save.png")

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

	Noir.Utils.AddMenuOption(fileMenu, "Close", function()
		frame:Close()
	end)

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
			Noir.Utils.AddMenuOption(runOnSubmenu, v:Nick(), function()
				Editor.RunCode(v)
			end, v:IsSuperAdmin() and "icon16/user_suit.png" or "icon16/user.png")
		end

		-- Populate autorun submenu
		for i = 1, autorunSubmenu:ChildCount() do
			autorunSubmenu:GetChild(i):Remove()
		end

		Noir.Utils.AddMenuOption(autorunSubmenu, "Run All Now", function()
			Noir.Autorun.RunAll()
		end, "icon16/control_play.png")

		autorunSubmenu:AddSpacer():SetTall(5)

		local scripts = Noir.Autorun.Scripts or {}
		if #scripts > 0 then
			for i, script in ipairs(scripts) do
				local displayName = Noir.Autorun.GetDisplayName(script)
				Noir.Utils.AddMenuOption(autorunSubmenu, displayName, function()
					Noir.Autorun.RunScript(script)
				end, "icon16/script.png")
			end
		else
			local emptyOpt = autorunSubmenu:AddOption("No autorun scripts")
			emptyOpt:SetTextColor(Color(120, 120, 120))
			emptyOpt:SetDisabled(true)
		end

		autorunSubmenu:AddSpacer():SetTall(5)

		Noir.Utils.AddMenuOption(autorunSubmenu, "Manage Autorun...", function()
			Noir.Dashboard.Show()
			timer.Simple(0.1, function()
				Noir.Dashboard.SetActiveTab("Autorun")
			end)
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

	Noir.Utils.AddMenuOption(viewMenu, "Main Console", function()
		Editor.ShowMainConsole()
	end, "icon16/application_xp_terminal.png")

	Noir.Utils.AddMenuOption(viewMenu, "New Console", function()
		local session = Editor.CreateConsoleTab()
		Editor.SetActiveTab(session.name)
	end, "icon16/application_add.png")

	viewMenu:AddSpacer():SetTall(5)

	Noir.Utils.AddMenuOption(viewMenu, "Toggle Console", function()
		Editor.ToggleConsoleTab()
	end, "icon16/application_xp_terminal.png")

	viewMenu:AddSpacer():SetTall(5)

	Noir.Utils.AddMenuOption(viewMenu, "Entity Selector", function()
		Noir.EntitySelector.Open()
	end, "icon16/brick.png")

	Noir.Utils.AddMenuOption(viewMenu, "Dashboard", function()
		Noir.Dashboard.Show()
	end, "icon16/cog.png")

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
			if v ~= tabMenu.session and v.sessionType ~= "console" then
				Editor.CloseTab(name, tabMenu.session.name, true)
			end
		end

		Editor.QueueSessionsSave()
	end, "icon16/tab_delete.png")

	Noir.Utils.AddMenuOption(tabMenu, "Close to the right", function()
		local idx = table.KeyFromValue(Editor.Sessions, tabMenu.session)

		for i = #Editor.Sessions, idx + 1, -1 do
			-- Skip console tab
			if Editor.Sessions[i].sessionType ~= "console" then
				Editor.CloseTab(Editor.Sessions[i].name, tabMenu.session.name, true)
			end
		end

		Editor.QueueSessionsSave()
	end, "icon16/tab_delete.png")

	Noir.Utils.AddMenuOption(tabMenu, "Close Saved", function()
		for _, v in pairs(Editor.Sessions) do
			-- Skip console tab
			if not v.Modified and v.sessionType ~= "console" then
				Editor.CloseSession(v.name, tabMenu.session.name, true)
			end
		end

		Editor.QueueSessionsSave()
	end, "icon16/tab_delete.png")

	Noir.Utils.AddMenuOption(tabMenu, "Close All", function()
		local sessions = table.Copy(Editor.Sessions)

		for _, v in pairs(sessions) do
			-- Skip console tab
			if v.sessionType ~= "console" then
				Editor.CloseTab(v.name, nil, true)
			end
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

	Noir.Utils.AddMenuOption(tabMenu, "Save", function()
		Editor.Save(tabMenu.session.name)
	end, "icon16/disk.png")

	Noir.Utils.AddMenuOption(tabMenu, "Save as", function()
		Editor.SaveAs(tabMenu.session.name)
	end, "icon16/disk.png")

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

	local scroller = frame:Add("DHorizontalScroller")
	scroller:Dock(TOP)
	scroller:DockMargin(-5, -5, -5, 0)
	scroller:SetTall(36)
	scroller:SetUseLiveDrag(true)
	scroller:SetOverlap(-2)
	scroller:MakeDroppable("TabsDrop")

	scroller.Paint = function(_, w, h)
		surface.SetDrawColor(42, 42, 42)
		surface.DrawRect(0, 0, w, h)
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
	monaco:DockMargin(-5, 0, -5, -5)
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
			if console.ReplPanel and IsValid(console.ReplPanel) then
				console.ReplPanel:Remove()
			end
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
				replPanel:DockMargin(-5, 0, -5, -5)
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
				if session.isMainConsole then
					Editor.MainConsole = session
				end
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
			if session.sessionType ~= "console" then
				table.insert(editorSessions, session)
			end
		end

		monaco:LoadSessions(editorSessions, activeSession)
		-- Set the active tab (noJS=true since Monaco already has the session from LoadSessions)
		Editor.SetActiveTab(activeSession, true)
		-- monaco:CloseSession("Unnamed")

		-- monaco:AddAction(id, label, callback, keyBindings)
		monaco:AddAction("fileNew", "File: New File", function() Editor.CreateSession() end, "Mod.CtrlCmd | Key.KeyN")
		monaco:AddAction("fileOpen", "File: Open File...", function() Noir.FileBrowser.Open(true) end, "Mod.CtrlCmd | Key.KeyO")
		monaco:AddAction("fileSave", "File: Save", function() Editor.Save() end, "Mod.CtrlCmd | Key.KeyS")
		monaco:AddAction("fileSaveAs", "File: Save As...", function() Editor.SaveAs() end, "Mod.CtrlCmd | Mod.Shift | Key.KeyS")

		monaco:AddAction("sessionClose", "Close tab", function() Editor.CloseTab(Editor.ActiveSession.name) end, "Mod.CtrlCmd | Key.KeyW")

		monaco:AddAction("runOnSelf", "Lua: Run on self", function() Editor.RunCode("self") end)
		monaco:AddAction("runOnServer", "Lua: Run on server", function() Editor.RunCode("server") end)
		monaco:AddAction("runOnShared", "Lua: Run on shared", function() Editor.RunCode("shared") end)
		monaco:AddAction("runOnClients", "Lua: Run on clients", function() Editor.RunCode("clients") end)

		monaco:AddAction("quickRun", "Lua: Run on last target", function() Editor.RunCode(Editor.LastRunTarget or "self") end, "Mod.CtrlCmd | Key.KeyE")

		monaco:AddAction("cycleTabs", "Cycle tabs", function()
			local currentTab
			for k, v in ipairs(Editor.Sessions) do
				if v.name == Editor.Config.activeSession then
					currentTab = k
					break
				end
			end
			if not currentTab then currentTab = 1 end
			local nextTab = currentTab + 1
			if nextTab > #Editor.Sessions then
				nextTab = 1
			end
			Editor.SetActiveTab(Editor.Sessions[nextTab].name)
		end, "Mod.CtrlCmd | Key.Tab")
		for i = 1, 9 do
			monaco:AddAction("switchToTab" .. i, "Switch to tab " .. i, function()
				if Editor.Sessions[i] then
					Editor.SetActiveTab(Editor.Sessions[i].name)
				end
			end, "Mod.Alt | Key.Digit" .. i)
		end

		monaco:AddAction("toggleConsole", "Noir: Toggle Console Tab", function() Editor.ToggleConsoleTab() end, "Mod.CtrlCmd | Mod.Shift | Key.KeyC")
		monaco:AddAction("runAutorun", "Noir: Run Autorun Scripts", function()
			if Noir.Autorun then
				Noir.Autorun.RunAll()
			end
		end)
		monaco:AddAction("openEntitySelector", "Noir: Open Entity Selector", function()
			Noir.EntitySelector.Open()
		end)
		monaco:AddAction("openDashboard", "Noir: Open Dashboard", function()
			Noir.Dashboard.Show()
		end, "Mod.CtrlCmd | Mod.Shift | Key.KeyD")
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

	monaco.OnOpenURL = function(_, url)
		gui.OpenURL(url)
	end

	monaco.OnValidation = function ()
		Editor.UpdateCOH()
	end

	frame.OnFocusChanged = function(_, hasFocus)
		Editor.Config.editorSize = {frame:GetSize()}
		frame:SetAlpha(hasFocus and 255 or 190)
		monaco:SetAlpha(hasFocus and 255 or 190)
	end
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
		Noir.Utils.AddMenuOption(Editor.RecentSubmenu, Format("[%s] %s", unpack(v)), function()
			Editor.OpenFile(unpack(v))
		end, "icon16/page.png")
	end

	Editor.RecentSubmenu:AddSpacer()

	Noir.Utils.AddMenuOption(Editor.RecentSubmenu, "Clear", function()
		Editor.Config.recentFiles = {}
		Editor.SaveConfig()
		Editor.ReloadRecents()
	end, "icon16/cross.png")
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
			draw.DrawText("r", "Marlett", w / 2, 2, Color(255, 255, 255, closeButton:GetAlpha()), TEXT_ALIGN_CENTER)
			return true
		end
	else
		closeButton.Paint = function(_, w, h)
			if not pnl.IsActive and not pnl:IsHovered() and not closeButton:IsHovered() and not session.Modified then return end
			draw.DrawText(closeButton:IsHovered() and "r" or (session.Modified and "n" or "r"), "Marlett", w / 2, 2, Color(255, 255, 255, closeButton:GetAlpha()), TEXT_ALIGN_CENTER)
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

	return pnl
end

function Editor.SetActiveTab(sessionName, noJS)
	if not Editor.SessionsByName[sessionName] then return end

	local session = Editor.SessionsByName[sessionName]
	local sessionType = session.sessionType or "editor"

	-- Mark old tab as inactive
	if Editor.ActiveSession and IsValid(Editor.ActiveSession.TabPanel) then
		Editor.ActiveSession.TabPanel.IsActive = false
	end

	-- Update active session
	Editor.ActiveSession = session

	-- Switch between Monaco and REPL panels
	Editor.SetContentPanel(sessionType)

	-- Only interact with Monaco for editor sessions
	if sessionType == "editor" and not noJS then
		Editor.MonacoPanel:SetSession(sessionName)
	end

	-- Mark new tab as active and scroll to it
	if Editor.ActiveSession.TabPanel then
		Editor.ActiveSession.TabPanel.IsActive = true
		Editor.TabsScroller:ScrollToChild(Editor.ActiveSession.TabPanel)
	end

	Editor.Frame:SetTitle(sessionName .. " - [Noir Lua Editor]")
	Editor.Config.activeSession = sessionName
	Editor.UpdateSession(sessionName)
	Editor.SaveConfig()
	Editor.QueueSessionsSave()
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

	if Editor.SessionsByName[sessionName] then
		error("Cant create session, name already taken")
	end

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

function Editor.CloseSession(sessionName, nextActive, noSave)
	local session = Editor.SessionsByName[sessionName]
	local idx = table.KeyFromValue(Editor.Sessions, session)

	if #Editor.Sessions == 1 then
		nextActive = Editor.CreateSession().name
	end

	session.TabPanel:Remove()
	Editor.TabsScroller:PerformLayout()
	table.remove(Editor.Sessions, idx)
	Editor.SessionsByName[sessionName] = nil

	if nextActive and Editor.SessionsByName[nextActive] then
		Editor.SetActiveTab(nextActive)
	else
		Editor.SetActiveTab(Editor.Sessions[#Editor.Sessions < idx and #Editor.Sessions or idx].name)
	end

	Editor.MonacoPanel:CloseSession(sessionName)
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
				if saved then
					Editor.CloseSession(name, nextActive, noSave)
				end
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
		local extensions = v.extensions

		for _, ext in pairs(extensions) do
			if file_ext == ext then return v.id end
		end
	end

	return "plaintext"
end

function Editor.RunCode(target)
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
				Editor.MonacoPanel:SetStatus(Format("[%i/%i] Ran on %s successfully",  totalRan, targets, senderName), Color(0, 150, 0), true)
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
			if targets ~= 1 then
				displayname = displayname .. "-" .. (sender == Entity(0) and "SERVER" or tostring(sender))
			end
			local succ, err = pcall(
				replPanel.OnMessage,
				replPanel,
				target,
				displayname,
				sender,
				transferId,
				message,
				data
			)
			if not succ then
				replPanel:AddText(Format("--[[%s: Could not display output]] %s", displayname, err))
			end
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

	local code = f:Read( f:Size() )

	f:Close()
	local name = string.GetFileFromFilename(fileName)

	if Editor.SessionsByName[name] then
		name = Format("[%s] %s", path, name)
	end

	if Editor.SessionsByName[name] then
		name = Format(Noir.Utils.GetFilePath(path, fileName))
	end

	for k, v in pairs(Editor.Config.recentFiles) do
		if v[1] == path and v[2] == fileName then
			table.remove(Editor.Config.recentFiles, k)
		end
	end

	if #Editor.Config.recentFiles > 10 then
		table.remove(Editor.Config.recentFiles)
	end

	table.insert(Editor.Config.recentFiles, 1, {path, fileName})
	Editor.ReloadRecents()
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

		if Editor.SessionsByName[name] and Editor.SessionsByName[name] ~= session then
			name = Format("[%s] %s", "DATA", name)
		end

		if Editor.SessionsByName[name] and Editor.SessionsByName[name] ~= session then
			name = Format(Noir.Utils.GetFilePath("DATA", fullname))
		end

		-- Editor.RenameSession(sessionName, name)
		Editor.UpdateSession(sessionName, true)
		Editor.QueueSessionsSave()

		if callback then
			callback(true, name, fullname)
		end
	end, function()
		if callback then
			callback(false)
		end
	end)
end

function Editor.Save(sessionName, callback)
	local session

	if not sessionName then
		session = Editor.ActiveSession
	else
		session = Editor.SessionsByName[sessionName]
	end

	if not session then return end

	if session.file and session.file[1] == "DATA" then
		file.Write(session.file[2], session.code)
		session.SavedCode = session.code
		session.Modified = false
		Editor.UpdateSession(session.name)

		if callback then
			callback(true, sessionName, session.file[2])
		end
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

			if session.file and not session.Modified then
				session.code = nil
			end
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
			activeSession = "Welcome"
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

				if not v.Modified then
					v.code = v.SavedCode
				end
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
	if not coh  or not Editor.ActiveSession then return end
	local cohText = Format(
		"%d Tab(s) - Current: %s\n%d line(s)",
		#Editor.Sessions,
		Editor.ActiveSession.name,
		#string.Split(Editor.ActiveSession.code, "\n")
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

concommand.Add("noir_showeditor", function(ply, cmd, args)
	Editor.Show()
end)

hook.Add("Think", "NoirEditorClose", function(self)
	if not input.IsKeyDown(KEY_ESCAPE) then return end
	if Noir.Editor.Frame and Noir.Editor.Frame:IsVisible() then
		Noir.Editor.Frame:Hide()
		if coh then coh.FinishChat() end
		gui.HideGameUI()
	end
end)