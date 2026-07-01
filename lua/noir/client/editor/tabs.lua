local Editor = Noir.Editor or {}
Noir.Editor = Editor
Editor.Tab = Editor.Tab or {}

-- Toggle between Monaco editor and REPL panel based on session type
function Editor.Tab.SetContentPanel(sessionType)
	local isConsole = sessionType == "console"
	-- Hide all console panels first
	for _, console in pairs(Editor.Console.Sessions) do
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

function Editor.Tab.Cycle(direction)
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
	Editor.Tab.SetActive(Editor.Sessions[nextTab].name)
end

function Editor.Tab.SwitchTo(index)
	if Editor.Sessions[index] then Editor.Tab.SetActive(Editor.Sessions[index].name) end
end

-- Flash the tab strip's scroll indicator back to full opacity. Called on tab
-- add/close/activate so the user gets a brief cue of where they are in an
-- overflowing strip; it then decays on its own (see scroller.PaintOver).
function Editor.Tab.BumpScrollIndicator()
	local scroller = Editor.Tab.Scroller
	if not IsValid(scroller) then return end
	scroller.ScrollIndicatorAlpha = 255
	scroller.ScrollIndicatorHold = CurTime() + 0.5
end

function Editor.Tab.Add(session)
	local isConsole = session.sessionType == "console"
	local pnl = vgui.Create("DPanel")
	pnl:SetSkin("Noir")
	pnl:SetSize(135, 36)
	pnl:SetTooltip(session.file and Noir.Utils.GetFilePath(unpack(session.file)) or session.name)
	pnl.Session = session
	session.TabPanel = pnl
	table.insert(Editor.Tab.Panels, pnl)
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
			Editor.Console.Close(session.name)
		else
			Editor.Session.CloseTab(session.name)
		end
	end

	local oOnMousePressed = pnl.OnMousePressed
	pnl.OnMousePressed = function(_, keyCode)
		if keyCode == MOUSE_LEFT then
			Editor.Tab.SetActive(session.name)
			-- Disable double-click rename for console tab
			if not isConsole and pnl.LastLeftClick and (CurTime() - pnl.LastLeftClick) < 0.5 then
				Derma_StringRequest("Rename", "Enter a new name", session.name, function(newName)
					if Editor.SessionsByName[newName] then
						Derma_Message("Error", "Cant rename to `" .. newName .. "`, name already taken", "Ok"):SetSkin("Noir")
						return
					end

					Editor.Session.Rename(session.name, newName)
				end):SetSkin("Noir")
				return
			end

			pnl.LastLeftClick = CurTime()
		elseif keyCode == MOUSE_RIGHT then
			if Editor.Tab.Menu:IsVisible() then
				Editor.Tab.Menu:Hide()
				if Editor.Tab.Menu.session ~= session then return end
			end

			Editor.Tab.Menu.session = session
			Editor.Tab.Menu.copyPathOption:SetDisabled(session.file == nil or isConsole)
			Editor.Tab.Menu.copyRelPathOption:SetDisabled(session.file == nil or isConsole)
			-- Update autorun option
			if session.file and not isConsole then
				Editor.Tab.Menu.autorunOption:SetDisabled(false)
				local isAutorun = Noir.Autorun.IsAutorun(session.file[1], session.file[2])
				Editor.Tab.Menu.autorunOption:SetText(isAutorun and "Remove from Autorun" or "Add to Autorun")
				Editor.Tab.Menu.autorunOption:SetIcon(isAutorun and "icon16/control_stop_blue.png" or "icon16/control_play_blue.png")
			else
				Editor.Tab.Menu.autorunOption:SetDisabled(true)
				Editor.Tab.Menu.autorunOption:SetText("Add to Autorun")
			end

			Editor.Tab.Menu:Open(gui.MouseX(), gui.MouseY(), false, pnl)
		elseif keyCode == MOUSE_MIDDLE then
			if isConsole then
				Editor.Console.Close(session.name)
			else
				Editor.Session.CloseTab(session.name)
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

	Editor.Tab.Scroller:AddPanel(pnl)
	Editor.Tab.BumpScrollIndicator()
	return pnl
end

function Editor.Tab.SetActive(sessionName, noJS)
	if not Editor.SessionsByName[sessionName] then return end
	local session = Editor.SessionsByName[sessionName]
	local sessionType = session.sessionType or "editor"
	-- Mark old tab as inactive
	if Editor.ActiveSession and IsValid(Editor.ActiveSession.TabPanel) then Editor.ActiveSession.TabPanel.IsActive = false end
	-- Update active session
	Editor.ActiveSession = session
	-- Switch between Monaco and REPL panels
	Editor.Tab.SetContentPanel(sessionType)
	-- Only interact with Monaco for editor sessions
	if sessionType == "editor" and not noJS then Editor.MonacoPanel:SetSession(sessionName) end
	-- Mark new tab as active and scroll to it
	if Editor.ActiveSession.TabPanel then
		Editor.ActiveSession.TabPanel.IsActive = true
		Editor.Tab.Scroller:ScrollToChild(Editor.ActiveSession.TabPanel)
		Editor.Tab.BumpScrollIndicator()
	end

	Editor.Frame:SetTitle(sessionName .. " - [Noir Lua Editor]")
	Editor.Config.activeSession = sessionName
	Editor.Session.Update(sessionName)
	Editor.Storage.SaveConfig()
	Editor.Storage.QueueSave()
	Editor.Sidebar.NavigateToActive()
end
