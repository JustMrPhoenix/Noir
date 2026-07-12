local Editor = Noir.Editor or {}
Noir.Editor = Editor
Editor.UI = Editor.UI or {}

-- Builds the editor's menu bar (File / Run / View buttons + the tab context menu)
-- onto the given frame. Extracted from Editor.UI.CreateFrame; all the DermaMenu
-- locals stay scoped here and shared handles are stored on Editor.UI / Editor.Tab.
-- The menu-bar DermaMenus are top-level panels parented to the world panel (not the
-- frame) with SetDeleteSelf(false), so frame:Remove() doesn't take them with it.
-- Track them and remove them explicitly on rebuild / reload teardown.
function Editor.UI.RemoveMenus()
	for _, menu in ipairs(Editor.UI.Menus or {}) do
		if IsValid(menu) then menu:Remove() end
	end

	Editor.UI.Menus = {}
end

function Editor.UI.BuildMenuBar(frame)
	-- Drop any menus from a previous frame build before creating new ones.
	Editor.UI.RemoveMenus()
	local menuX = 5
	local fileMenuButton = frame:Add("DButton")
	fileMenuButton:SetTall(24)
	fileMenuButton:SetPos(menuX, 0)
	fileMenuButton:SetText("File")
	fileMenuButton:SizeToContentsX(16)
	fileMenuButton:SetIsMenu(true)
	menuX = menuX + fileMenuButton:GetWide()
	local fileMenu = DermaMenu()
	Editor.UI.Menus[#Editor.UI.Menus + 1] = fileMenu
	fileMenu:SetSkin("Noir")
	-- fileMenu:SetDark(true)
	fileMenu:SetDeleteSelf(false)
	fileMenu:SetDrawColumn(true)
	fileMenu:Hide()
	Noir.Utils.AddMenuOption(fileMenu, "New", function() Editor.Session.Create() end, "icon16/page_add.png", "Ctrl+N")
	fileMenu:AddSpacer():SetTall(10)
	Noir.Utils.AddMenuOption(fileMenu, "Open", function() Noir.FileBrowser.Open(true) end, "icon16/folder.png", "Ctrl+O")
	local recentSubmenu, recentMenu = fileMenu:AddSubMenu("Open Recent")
	-- recentMenu:SetIcon("icon16/table_multiple.png")
	recentMenu:SetTextColor(Color(200, 200, 200))
	recentSubmenu:SetDeleteSelf(false)
	Editor.UI.RecentSubmenu = recentSubmenu
	Editor.Session.ReloadRecents()
	Noir.Utils.AddMenuOption(fileMenu, "Reopen Closed", function() Editor.Session.ReopenClosed() end, "icon16/page_white_get.png", "Ctrl+Shift+T")
	fileMenu:AddSpacer():SetTall(10)
	Noir.Utils.AddMenuOption(fileMenu, "Save", function() Editor.Session.Save() end, "icon16/disk.png", "Ctrl+S")
	Noir.Utils.AddMenuOption(fileMenu, "Save as", function() Editor.Session.SaveAs() end, "icon16/page_save.png", "Ctrl+Shift+S")
	Noir.Utils.AddMenuOption(fileMenu, "Save all", function()
		local i = 0
		local callback, session
		callback = function()
			i = i + 1
			session = Editor.Sessions[i]
			Noir.Debug("SaveAll", session)
			if not session then return end
			if not session.Modified then return callback() end
			Editor.Tab.SetActive(session.name)
			Editor.Session.Save(session.name, callback)
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
	Editor.UI.Menus[#Editor.UI.Menus + 1] = runMenu
	runMenu:SetSkin("Noir")
	runMenu:SetDeleteSelf(false)
	runMenu:SetDrawColumn(true)
	runMenu:Hide()
	Noir.Utils.AddMenuOption(runMenu, "Run last target", function() Editor.Run.Code(Editor.Run.LastTarget or "self") end, "icon16/lightning.png", "Ctrl+E")
	runMenu:AddSpacer():SetTall(5)
	Noir.Utils.AddMenuOption(runMenu, "Run on self", function() Editor.Run.Code("self") end, "icon16/user.png")
	Noir.Utils.AddMenuOption(runMenu, "Run on server", function() Editor.Run.Code("server") end, "icon16/server.png")
	local runOnSubmenu, runOnMenu = runMenu:AddSubMenu("Run on client")
	runOnMenu:SetIcon("icon16/user_go.png")
	runOnMenu:SetTextColor(Color(200, 200, 200))
	runOnSubmenu:SetDeleteSelf(false)
	Editor.UI.RunOnSubmenu = runOnSubmenu
	Noir.Utils.AddMenuOption(runMenu, "Run on clients", function() Editor.Run.Code("clients") end, "icon16/group.png")
	Noir.Utils.AddMenuOption(runMenu, "Run on shared", function() Editor.Run.Code("shared") end, "icon16/world.png")
	runMenu:AddSpacer():SetTall(10)
	local autorunSubmenu, autorunMenu = runMenu:AddSubMenu("Autorun")
	autorunMenu:SetIcon("icon16/control_play_blue.png")
	autorunMenu:SetTextColor(Color(200, 200, 200))
	autorunSubmenu:SetDeleteSelf(false)
	Editor.UI.AutorunSubmenu = autorunSubmenu
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
				function() Editor.Run.Code(v) end,
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
			Noir.Dashboard.Show("Autorun")
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
	Editor.UI.Menus[#Editor.UI.Menus + 1] = viewMenu
	viewMenu:SetSkin("Noir")
	viewMenu:SetDeleteSelf(false)
	viewMenu:SetDrawColumn(true)
	viewMenu:Hide()
	Noir.Utils.AddMenuOption(viewMenu, "Main Console", function() Editor.Console.ShowMain() end, "icon16/application_xp_terminal.png")
	Noir.Utils.AddMenuOption(viewMenu, "New Console", function()
		local session = Editor.Console.CreateTab()
		Editor.Tab.SetActive(session.name)
	end, "icon16/application_add.png", "Ctrl+Shift+`")

	viewMenu:AddSpacer():SetTall(5)
	Noir.Utils.AddMenuOption(viewMenu, "Toggle Console", function() Editor.Console.Toggle() end, "icon16/application_xp_terminal.png", "Ctrl+Shift+C")
	viewMenu:AddSpacer():SetTall(5)
	Noir.Utils.AddMenuOption(viewMenu, "Toggle Sidebar", function() Editor.Sidebar.Toggle() end, "icon16/application_side_tree.png", "Ctrl+B")
	Noir.Utils.AddMenuOption(viewMenu, "Entity Selector", function() Noir.EntitySelector.Open() end, "icon16/brick.png", "Ctrl+Shift+E")
	Noir.Utils.AddMenuOption(viewMenu, "Find in Files", function() Noir.FileSearch.UI.Show() end, "icon16/page_white_magnify.png", "Ctrl+Shift+F")
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
	Editor.UI.Menus[#Editor.UI.Menus + 1] = tabMenu
	tabMenu:SetSkin("Noir")
	tabMenu:SetDeleteSelf(false)
	tabMenu:SetDrawColumn(true)
	tabMenu:Hide()
	Editor.Tab.Menu = tabMenu
	Noir.Utils.AddMenuOption(tabMenu, "Close", function()
		if tabMenu.session.sessionType == "console" then
			Editor.Console.Close(tabMenu.session.name)
		else
			Editor.Session.CloseTab(tabMenu.session.name)
		end
	end, "icon16/tab_delete.png")

	Noir.Utils.AddMenuOption(tabMenu, "Close Others", function()
		for name, v in pairs(Editor.SessionsByName) do
			-- Skip console tab and current session
			if v ~= tabMenu.session and v.sessionType ~= "console" then Editor.Session.CloseTab(name, tabMenu.session.name, true) end
		end

		Editor.Storage.QueueSave()
	end, "icon16/tab_delete.png")

	Noir.Utils.AddMenuOption(tabMenu, "Close to the right", function()
		local idx = table.KeyFromValue(Editor.Sessions, tabMenu.session)
		for i = #Editor.Sessions, idx + 1, -1 do
			-- Skip console tab
			if Editor.Sessions[i].sessionType ~= "console" then Editor.Session.CloseTab(Editor.Sessions[i].name, tabMenu.session.name, true) end
		end

		Editor.Storage.QueueSave()
	end, "icon16/tab_delete.png")

	Noir.Utils.AddMenuOption(tabMenu, "Close Saved", function()
		for _, v in pairs(Editor.Sessions) do
			-- Skip console tab
			if not v.Modified and v.sessionType ~= "console" then Editor.Session.Close(v.name, tabMenu.session.name, true) end
		end

		Editor.Storage.QueueSave()
	end, "icon16/tab_delete.png")

	Noir.Utils.AddMenuOption(tabMenu, "Close All", function()
		local sessions = table.Copy(Editor.Sessions)
		for _, v in pairs(sessions) do
			-- Skip console tab
			if v.sessionType ~= "console" then Editor.Session.CloseTab(v.name, nil, true) end
		end

		Editor.Storage.QueueSave()
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
	Noir.Utils.AddMenuOption(tabMenu, "Save", function() Editor.Session.Save(tabMenu.session.name) end, "icon16/disk.png")
	Noir.Utils.AddMenuOption(tabMenu, "Save as", function() Editor.Session.SaveAs(tabMenu.session.name) end, "icon16/disk.png")
	tabMenu:AddSpacer():SetTall(10)
	Noir.Utils.AddMenuOption(tabMenu, "Rename", function()
		Derma_StringRequest("Rename", "Enter a new name", tabMenu.session.name, function(newName)
			if Editor.SessionsByName[newName] then
				Derma_Message("Error", "Cant rename to `" .. newName .. "`, name already taken", "Ok"):SetSkin("Noir")
				return
			end

			Editor.Session.Rename(tabMenu.session.name, newName)
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
end
