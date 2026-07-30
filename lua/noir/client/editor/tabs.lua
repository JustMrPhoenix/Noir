local Editor = Noir.Editor or {}
Noir.Editor = Editor
Editor.Tab = Editor.Tab or {}

-- Paint the tab close button's "X" (Marlett "r"), with a hover highlight box behind
-- it. Shared by the two close-button Paint variants (with/without a modified dot).
local function paintCloseX(btn, w, h)
	if btn:IsHovered() then draw.RoundedBox(3, 0, 0, w, h, Color(90, 90, 90, btn:GetAlpha())) end
	draw.DrawText("r", "Marlett", w / 2, 2, Color(255, 255, 255, btn:GetAlpha()), TEXT_ALIGN_CENTER)
end

-- Register a session in the model, build its content panel via its tab type, and add
-- its tab-strip button. The single creation path shared by every tab kind's CreateTab
-- (Editor.Session.Create, Console.CreateTab, Database.CreateTab). The restore path in
-- frame.lua doesn't use this -- it rebuilds tabs/panels directly (editor sessions batch
-- through monaco:LoadSessions).
function Editor.Tab.Open(session)
	table.insert(Editor.Sessions, session)
	Editor.SessionsByName[session.name] = session
	local def = Editor.TabTypes.Get(session)
	if def.Build then def.Build(session, Editor.Frame) end
	Editor.Tab.Add(session)
	Editor.Storage.QueueSave()
	return session
end

-- Show the active session's content panel and hide every other session's. Dispatches
-- to each tab type's Activate/Deactivate, so any registered type slots in without a
-- special case here. Deactivating all non-active sessions (rather than tracking the
-- previous one) keeps things robust on the first activation and after a tab is closed.
-- `noJS` is passed through to Activate (the editor type skips a redundant Monaco
-- SetSession on restore).
function Editor.Tab.SetContentPanel(session, noJS)
	local def = Editor.TabTypes.Get(session)
	for _, s in ipairs(Editor.Sessions) do
		if s ~= session then
			local d = Editor.TabTypes.Get(s)
			if d.Deactivate then d.Deactivate(s) end
		end
	end

	-- The editor type's Monaco panel is a single shared instance, visible by default.
	-- When the active tab is a bespoke panel, hide Monaco explicitly -- the loop above
	-- only covers it if some editor session happens to still be open (it isn't, e.g.
	-- right after the last editor tab is closed next to a console/SQL tab).
	if not def.caps.monaco then
		local editorDef = Editor.TabTypes.Get(Editor.SessionType.Editor)
		if editorDef.Deactivate then editorDef.Deactivate() end
	end

	if def.Activate then def.Activate(session, noJS) end
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
	local def = Editor.TabTypes.Get(session)
	local caps = def.caps
	local pnl = vgui.Create("DPanel")
	pnl:SetSkin("Noir")
	pnl:SetSize(135, 36)
	pnl:SetTooltip(session.file and Noir.Utils.GetFilePath(unpack(session.file)) or session.name)
	pnl.Session = session
	session.TabPanel = pnl
	table.insert(Editor.Tab.Panels, pnl)
	local image = vgui.Create("DImage", pnl)
	-- File-type icon (terminal / gun / brick / page); modified state is shown on the
	-- close button as a VSCode-style dot, not here.
	image:SetImage(Editor.Session.IconFor(session))
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
	closeButton:SetTooltip(def.closeTooltip or "Close")
	closeButton:SetSize(14, 14)
	closeButton:DockMargin(0, 10, 5, 10)
	closeButton.BackgroundColor = Color(0, 0, 0, 0)
	if not caps.modified then
		-- No modified indicator (bespoke panel tabs): always show X on hover
		closeButton.Paint = function(_, w, h)
			if not pnl.IsActive and not pnl:IsHovered() and not closeButton:IsHovered() then return end
			paintCloseX(closeButton, w, h)
			return true
		end
	else
		closeButton.Paint = function(_, w, h)
			local hovered = pnl:IsHovered() or closeButton:IsHovered()
			if not pnl.IsActive and not hovered and not session.Modified then return end
			-- Unsaved and not hovered -> VSCode-style round dot; otherwise the X (with a
			-- highlight box when the button itself is hovered).
			if session.Modified and not hovered then
				local alpha = closeButton:GetAlpha()
				local r = 4
				surface.SetDrawColor(255, 255, 255, alpha)
				draw.NoTexture()
				local segments = 16
				local poly = {}
				for i = 0, segments do
					local a = math.rad((i / segments) * 360)
					poly[i + 1] = {x = w / 2 + math.cos(a) * r, y = h / 2 + math.sin(a) * r}
				end

				surface.DrawPoly(poly)
			else
				paintCloseX(closeButton, w, h)
			end

			return true
		end
	end

	closeButton.DoClick = function() Editor.Session.CloseTab(session.name) end
	local oOnMousePressed = pnl.OnMousePressed
	pnl.OnMousePressed = function(_, keyCode)
		if keyCode == MOUSE_LEFT then
			Editor.Tab.SetActive(session.name)
			-- Double-click rename, only for types that allow it (rename cap).
			if caps.rename and pnl.LastLeftClick and (CurTime() - pnl.LastLeftClick) < 0.5 then
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
			Editor.Tab.Menu.copyPathOption:SetDisabled(session.file == nil or not caps.file)
			Editor.Tab.Menu.copyRelPathOption:SetDisabled(session.file == nil or not caps.file)
			-- Reflect the current effective entity type on the submenu label.
			if Editor.Tab.Menu.entTypeParent then
				Editor.Tab.Menu.entTypeParent:SetDisabled(not caps.entType)
				Editor.Tab.Menu.entTypeParent:SetText("Entity Type: " .. (Editor.Session.GetEntType(session) or "None"))
			end
			-- Update autorun option
			if session.file and caps.file then
				Editor.Tab.Menu.autorunOption:SetDisabled(false)
				local isAutorun = Noir.Autorun.IsAutorun(session.file[1], session.file[2])
				Editor.Tab.Menu.autorunOption:SetText(isAutorun and "Remove from Autorun" or "Add to Autorun")
				Editor.Tab.Menu.autorunOption:SetIcon(isAutorun and "icon16/control_stop_blue.png" or "icon16/control_play_blue.png")
			else
				Editor.Tab.Menu.autorunOption:SetDisabled(true)
				Editor.Tab.Menu.autorunOption:SetText("Add to Autorun")
			end

			-- Let the session's tab type contribute extra items (optional). Drop any
			-- from a previous open so they don't stack on the shared menu; new options
			-- are appended, so they sit below the built-in ones.
			local menu = Editor.Tab.Menu
			for _, opt in ipairs(menu.TypeOptions or {}) do
				if IsValid(opt) then opt:Remove() end
			end

			menu.TypeOptions = {}
			if def.ContextMenu then
				local canvas = menu.GetCanvas and menu:GetCanvas() or menu
				local before = {}
				for _, c in ipairs(canvas:GetChildren()) do before[c] = true end
				def.ContextMenu(menu, session)
				for _, c in ipairs(canvas:GetChildren()) do
					if not before[c] then table.insert(menu.TypeOptions, c) end
				end
			end

			menu:Open(gui.MouseX(), gui.MouseY(), false, pnl)
		elseif keyCode == MOUSE_MIDDLE then
			Editor.Session.CloseTab(session.name)
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
	-- Mark old tab as inactive
	if Editor.ActiveSession and IsValid(Editor.ActiveSession.TabPanel) then Editor.ActiveSession.TabPanel.IsActive = false end
	-- Update active session
	Editor.ActiveSession = session
	-- Swap the visible content panel to this session's (per its tab type). For editor
	-- sessions this also drives Monaco's SetSession (skipped when noJS).
	Editor.Tab.SetContentPanel(session, noJS)
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
