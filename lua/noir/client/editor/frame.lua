local Editor = Noir.Editor or {}
Noir.Editor = Editor
Editor.UI = Editor.UI or {}

-- Fade the frame together with its currently visible content panel when focus is
-- lost. Monaco and the REPL panels are DHTML (chromium) and don't inherit the
-- frame's alpha, so each has to be set explicitly. Dimming Monaco plus the active
-- session's REPL panel covers both tab types -- the inactive one is hidden, so
-- setting its alpha is harmless.
function Editor.SetFocusAlpha(hasFocus)
	local a = hasFocus and 255 or 190
	if IsValid(Editor.Frame) then Editor.Frame:SetAlpha(a) end
	if IsValid(Editor.MonacoPanel) then Editor.MonacoPanel:SetAlpha(a) end
	if Editor.ActiveSession and IsValid(Editor.ActiveSession.ReplPanel) then Editor.ActiveSession.ReplPanel:SetAlpha(a) end
end

function Editor.UI.CreateFrame()
	-- There is alot of hacky vgui stuff here
	-- im just trying to get as close to vs-code look as possible
	if not Editor.Config or Noir.DEBUG then Editor.Storage.LoadConfig() end
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
		Editor.Storage.SaveConfig()
	end

	frame.OnClose = function()
		Editor.Config.editorSize = {frame:GetSize()}
		Editor.Config.editorPosition = {frame:GetPos()}
		Editor.Storage.SaveConfig()
		Editor.Storage.QueueSave()
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
	Editor.UI.BuildMenuBar(frame)

	-- VSCode-style activity bar + sidebar. The activity bar is a thin strip of icon
	-- buttons (one per registered view); the sidebar hosts the active view's content.
	-- Views register through Editor.Sidebar.RegisterView (the Explorer is registered in
	-- sidebar.lua). Both dock LEFT, activity bar first so it sits furthest left.
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
	Editor.Sidebar.ActivityBar = activityBar
	local sidebar = frame:Add("DPanel")
	sidebar:SetSkin("Noir")
	sidebar:SetWide(Editor.Config.sidebarWidth or 320)
	sidebar:Dock(LEFT)
	sidebar:DockMargin(0, 0, 0, -5)
	sidebar:SetBackgroundColor(Color(37, 37, 38))
	Editor.Sidebar.Panel = sidebar
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

	hideBtn.DoClick = function() Editor.Sidebar.Toggle() end
	local headerActions = sidebarHeader:Add("DPanel")
	headerActions:Dock(RIGHT)
	headerActions:SetWide(0)
	headerActions:SetPaintBackground(false)
	Editor.Sidebar.Actions = headerActions
	local sidebarLabel = sidebarHeader:Add("DLabel")
	sidebarLabel:Dock(FILL)
	sidebarLabel:DockMargin(8, 0, 0, 0)
	sidebarLabel:SetTextColor(Color(200, 200, 200))
	sidebarLabel:SetText("")
	Editor.Sidebar.HeaderLabel = sidebarLabel
	-- View content lives here; each registered view docks FILL and is shown/hidden.
	local sidebarContent = sidebar:Add("DPanel")
	sidebarContent:Dock(FILL)
	sidebarContent:SetPaintBackground(false)
	Editor.Sidebar.Content = sidebarContent
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
	Editor.Sidebar.Resizer = resizer
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
		Editor.Storage.SaveConfig()
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

	Editor.Sidebar.RebuildActivityBar()
	Editor.Sidebar.ActivateView(Editor.Config.activeSidebarView or "explorer", true)
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
	-- It's bumped to full opacity by Editor.Tab.BumpScrollIndicator (on tab
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

		Editor.Storage.QueueSave()
	end

	Editor.Tab.Scroller = scroller
	Editor.Tab.Panels = {}
	local monaco = frame:Add("NoirMonacoEditor")
	monaco:DockMargin(0, 0, -5, -5)
	monaco:Dock(FILL)
	Editor.MonacoPanel = monaco
	-- A hack to make space for resizing
	monaco.StatusButton:DockMargin(0, 0, 14, 0)
	monaco.ErrorList:DockMargin(0, 0, 14, 0)
	monaco:SetCursor("sizenwse")
	-- REPL panels are now created per-console in Editor.Console.CreateTab()
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
		for _, tab in ipairs(Editor.Tab.Panels or {}) do
			if IsValid(tab) then tab:Remove() end
		end

		Editor.Tab.Panels = {}
		-- Clear console REPL panels
		for _, console in pairs(Editor.Console.Sessions or {}) do
			if console.ReplPanel and IsValid(console.ReplPanel) then console.ReplPanel:Remove() end
		end

		Editor.Console.Sessions = {}
		Editor.Console.Main = nil
		-- Always load sessions fresh from file
		Editor.Storage.LoadSessions()
		for _, session in ipairs(Editor.Sessions) do
			Editor.Tab.Add(session)
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

				replPanel.HTMLPanel.OnFocusChanged = function(_, hasFocus) Editor.SetFocusAlpha(hasFocus) end
				Editor.Console.Sessions[session.name] = session
				if session.isMainConsole then Editor.Console.Main = session end
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
		Editor.Tab.SetActive(activeSession, true)
		-- monaco:CloseSession("Unnamed")
		Editor.RegisterActions(monaco)
		monaco:RequestFocus()
	end

	monaco.OnSessionSet = function(_, session)
		if not monaco.Ready then return end
		if session.name == "Unnamed" then
			Noir.Error("Something went wrong, creating an empty session\n")
			Editor.Session.Create()
			monaco:CloseSession("Unnamed")
		else
			Editor.Tab.SetActive(session.name, true)
		end
	end

	monaco.OnCode = function(_, code)
		if not Editor.ActiveSession then return end
		local modified = Editor.ActiveSession.SavedCode ~= code
		Editor.ActiveSession.code = code
		Editor.ActiveSession.Modified = modified
		Editor.Session.Update(Editor.ActiveSession.name, true)
		Editor.Run.UpdateCOH()
	end

	monaco.HTMLPanel.OnFocusChanged = function(_, hasFocus) Editor.SetFocusAlpha(hasFocus) end
	monaco.OnOpenURL = function(_, url) gui.OpenURL(url) end
	monaco.OnValidation = function() Editor.Run.UpdateCOH() end
	frame.OnFocusChanged = function(_, hasFocus)
		Editor.Config.editorSize = {frame:GetSize()}
		Editor.SetFocusAlpha(hasFocus)
	end
end
