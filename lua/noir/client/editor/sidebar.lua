local Editor = Noir.Editor or {}
Noir.Editor = Editor
Editor.Sidebar = Editor.Sidebar or {}

-- Sidebar view registry (VSCode-style). Each view contributes an activity-bar icon
-- and lazily builds its content into the shared sidebar container. Modules register
-- through Editor.Sidebar.RegisterView; the Explorer is registered at the bottom of
-- this file. A view def has these fields:
--   title    string  - shown in the sidebar header
--   icon     string  - activity-bar icon (Material path)
--   tooltip  string  - activity-bar button tooltip (defaults to title)
--   build    function(container) -> Panel  - called once, the first time it is shown
--   actions  table   - optional header buttons, each {icon, tooltip, onClick}
--   onShow   function(panel)  - optional, called whenever the view is revealed
Editor.Sidebar.Views = Editor.Sidebar.Views or {}
Editor.Sidebar.ViewOrder = Editor.Sidebar.ViewOrder or {}
function Editor.Sidebar.RegisterView(id, def)
	def.id = id
	local existing = Editor.Sidebar.Views[id]
	if existing then
		-- Re-registration (script reload): drop the stale panel so it gets rebuilt.
		if IsValid(existing.panel) then existing.panel:Remove() end
	else
		table.insert(Editor.Sidebar.ViewOrder, id)
	end

	Editor.Sidebar.Views[id] = def
	-- If the frame already exists, refresh the activity bar and rebuild the content
	-- of this view when it happens to be the active one (again, reload case).
	if IsValid(Editor.Sidebar.ActivityBar) then
		Editor.Sidebar.RebuildActivityBar()
		if Editor.Sidebar.ActiveView == id then Editor.Sidebar.ActivateView(id, true) end
	end
end

-- Rebuild the activity-bar buttons from the registered views.
function Editor.Sidebar.RebuildActivityBar()
	local bar = Editor.Sidebar.ActivityBar
	if not IsValid(bar) then return end
	bar:Clear()
	Editor.Sidebar.ActivityButtons = {}
	for _, id in ipairs(Editor.Sidebar.ViewOrder) do
		local def = Editor.Sidebar.Views[id]
		local btn = bar:Add("DButton")
		btn:Dock(TOP)
		btn:SetTall(44)
		btn:SetText("")
		btn:SetTooltip(def.tooltip or def.title or id)
		local icon = Material(def.icon or "icon16/bullet_white.png")
		btn.Paint = function(self, w, h)
			local active = Editor.Sidebar.ActiveView == id and Editor.Config.sidebarVisible
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

		btn.DoClick = function() Editor.Sidebar.ActivateView(id) end
		Editor.Sidebar.ActivityButtons[id] = btn
	end
end

-- Populate the sidebar header's per-view action buttons.
function Editor.Sidebar.RebuildActions(def)
	local holder = Editor.Sidebar.Actions
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
function Editor.Sidebar.ActivateView(id, initial)
	local def = Editor.Sidebar.Views[id]
	if not def then return end
	-- Clicking the already-active icon collapses the sidebar (VSCode behaviour).
	if not initial and Editor.Sidebar.ActiveView == id and Editor.Config.sidebarVisible then
		Editor.Sidebar.Toggle()
		return
	end

	-- Build the view's content lazily the first time it is shown.
	if not IsValid(def.panel) then
		def.panel = def.build(Editor.Sidebar.Content)
		if IsValid(def.panel) then def.panel:Dock(FILL) end
	end

	-- Swap the visible view.
	local prev = Editor.Sidebar.Views[Editor.Sidebar.ActiveView]
	if prev and prev ~= def and IsValid(prev.panel) then prev.panel:SetVisible(false) end
	Editor.Sidebar.ActiveView = id
	if IsValid(def.panel) then def.panel:SetVisible(true) end
	if IsValid(Editor.Sidebar.HeaderLabel) then Editor.Sidebar.HeaderLabel:SetText(def.title or id) end
	Editor.Sidebar.RebuildActions(def)
	Editor.Config.activeSidebarView = id
	-- Reveal the sidebar when switching views interactively.
	if not initial and not Editor.Config.sidebarVisible then
		Editor.Config.sidebarVisible = true
		Editor.Sidebar.Panel:SetVisible(true)
		if IsValid(Editor.Sidebar.Resizer) then Editor.Sidebar.Resizer:SetVisible(true) end
		Editor.Frame:InvalidateLayout()
	end

	Editor.Storage.SaveConfig()
	if def.onShow and Editor.Config.sidebarVisible then def.onShow(def.panel) end
end

function Editor.Sidebar.Toggle()
	if not IsValid(Editor.Sidebar.Panel) then return end
	Editor.Config.sidebarVisible = Editor.Config.sidebarVisible == false
	Editor.Sidebar.Panel:SetVisible(Editor.Config.sidebarVisible)
	if IsValid(Editor.Sidebar.Resizer) then Editor.Sidebar.Resizer:SetVisible(Editor.Config.sidebarVisible) end
	Editor.Storage.SaveConfig()
	if Editor.Config.sidebarVisible then
		local def = Editor.Sidebar.Views[Editor.Sidebar.ActiveView]
		if def and def.onShow then def.onShow(def.panel) end
	end

	Editor.Frame:InvalidateLayout()
end

-- Decide which root folder (DATA / LUA / GAME) the sidebar should show for a session.
-- Files are already normalised to DATA/LUA/GAME by Noir.Utils.FixFilePath when opened,
-- so a session's stored path is exactly "in data -> DATA, in lua -> LUA, otherwise GAME".
-- When there is no file (console/unsaved tab) or following is disabled, fall back to the
-- configurable default root. Both behaviours are exposed in the Dashboard ("Editor" tab).
function Editor.Sidebar.GetRootPath(session)
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
function Editor.Sidebar.RevealFile(folder, fileName)
	local node = Editor.Sidebar.Root
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
				Editor.Sidebar.Tree:SetSelectedItem(child)
				break
			end
		end
	end

	Editor.Sidebar.Tree.PendingScroll = target
end

-- Collapse every folder in the explorer, leaving only the top-level entries visible.
function Editor.Sidebar.Collapse()
	local root = Editor.Sidebar.Root
	if not IsValid(root) then return end
	local function collapse(node)
		for _, child in ipairs(node.ChildNodes and node.ChildNodes:GetChildren() or {}) do
			collapse(child)
			child:SetExpanded(false)
		end
	end

	collapse(root)
	root:SetExpanded(true)
	if IsValid(Editor.Sidebar.Tree.VBar) then Editor.Sidebar.Tree.VBar:SetScroll(0) end
end

function Editor.Sidebar.NavigateToActive(force)
	if not IsValid(Editor.Sidebar.Tree) then return end
	if not Editor.Sidebar.Panel:IsVisible() and not force then return end
	local session = Editor.ActiveSession
	local path = Editor.Sidebar.GetRootPath(session)
	local folder, fileName = "", nil
	if session and session.file and session.file[1] == path then
		fileName = session.file[2]
		folder = string.Trim(string.GetPathFromFilename(fileName) or "", "/")
	end

	-- Rebuild the tree only when the root path changes (or when forced) so switching
	-- between files in the same root preserves the user's manually expanded folders.
	if force or Editor.Sidebar.Path ~= path or not IsValid(Editor.Sidebar.Root) then
		Editor.Sidebar.Path = path
		local tree = Editor.Sidebar.Tree
		tree:Clear()
		local root = tree:AddNode(path)
		root:MakeFolder("", path, true)
		root:SetExpanded(true)
		Editor.Sidebar.Root = root
		if IsValid(Editor.Sidebar.HeaderLabel) then Editor.Sidebar.HeaderLabel:SetText(path) end
	end

	Editor.Sidebar.Folder = folder
	Editor.Sidebar.RevealFile(folder, fileName)
end

-- Built-in Explorer view (the file tree). This is the first/default sidebar view;
-- other modules can contribute their own via Editor.Sidebar.RegisterView.
Editor.Sidebar.RegisterView("explorer", {
	title = "Explorer",
	icon = "icon16/folder_explore.png",
	tooltip = "Explorer",
	actions = {
		{
			icon = "icon16/arrow_refresh.png",
			tooltip = "Refresh",
			onClick = function() Editor.Sidebar.NavigateToActive(true) end
		},
		{
			icon = "icon16/arrow_in.png",
			tooltip = "Collapse all folders",
			onClick = function() Editor.Sidebar.Collapse() end
		}
	},
	onShow = function() Editor.Sidebar.NavigateToActive() end,
	build = function(container)
		local tree = container:Add("DTree")
		tree:Dock(FILL)
		tree:SetPaintBackground(false)
		Editor.Sidebar.Tree = tree
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
				Editor.OpenFile(Editor.Sidebar.Path, fileName)
				return
			end
		end

		tree.DoRightClick = function(_, node)
			local fileName = node.GetFileName and node:GetFileName()
			if not fileName or fileName == "" then return end
			local menu = DermaMenu()
			menu:SetSkin("Noir")
			Noir.Utils.AddMenuOption(menu, "Open", function() Editor.OpenFile(Editor.Sidebar.Path, fileName) end, "icon16/page.png")
			Noir.Utils.AddMenuOption(menu, "Copy Path", function()
				SetClipboardText(Noir.Utils.GetFilePath(Editor.Sidebar.Path, fileName))
			end, "icon16/page_white_copy.png")
			menu:Open()
		end

		return tree
	end
})
