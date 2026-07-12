local Highlight = include("entity_highlight.lua")
local EntitySelector = Noir.EntitySelector or {}
Noir.EntitySelector = EntitySelector
-- Constants
local HOOK_ID = "NoirEntitySelector"
local COLORS = {
	buttonPrimary = Color(17, 73, 113),
	buttonPrimaryHover = Color(25, 100, 150),
	buttonSecondary = Color(60, 60, 60),
	buttonSecondaryHover = Color(80, 80, 80),
	text = Color(200, 200, 200),
	overlay = Color(0, 0, 0, 50),
	crosshair = Color(255, 255, 255, 200),
}

-- State
EntitySelector.Frame = nil
EntitySelector.PickMode = false
EntitySelector.PickOptions = nil
EntitySelector.HiddenPanels = nil
--------------------------------------------------------------------------------
-- UI Helpers
--------------------------------------------------------------------------------
local function createFilterRow(parent, label, placeholder)
	local row = vgui.Create("DPanel", parent)
	row:Dock(TOP)
	row:SetTall(24)
	row:DockMargin(5, 5, 5, 0)
	row:SetPaintBackground(false)
	local lbl = vgui.Create("DLabel", row)
	lbl:SetText(label)
	lbl:SetTextColor(COLORS.text)
	lbl:Dock(LEFT)
	lbl:SetWide(46)
	local entry = vgui.Create("DTextEntry", row)
	entry:SetSkin("Noir")
	entry:Dock(FILL)
	entry:SetPlaceholderText(placeholder)
	return entry
end

local function createButton(parent, text, primary)
	local btn = vgui.Create("DButton", parent)
	btn:SetSkin("Noir")
	btn:SetText(text)
	btn.BackgroundColor = primary and COLORS.buttonPrimary or COLORS.buttonSecondary
	btn.HoveredColor = primary and COLORS.buttonPrimaryHover or COLORS.buttonSecondaryHover
	return btn
end

local REALM_CHOICES = {
	{label = "Local", value = "local"},
	{label = "Server", value = "server"},
	{label = "Both", value = "both"}
}

local function truncateModel(model, maxLen)
	if not model or #model <= maxLen then return model or "" end
	return "..." .. string.sub(model, -(maxLen - 3))
end

local function makeCombo(parent, choices, current)
	local combo = vgui.Create("DComboBox", parent)
	combo:SetSkin("Noir")
	combo.NoirValue = current
	for _, c in ipairs(choices) do
		combo:AddChoice(c.label, c.value, c.value == current)
	end

	combo.OnSelect = function(_, _, _, data) combo.NoirValue = data end
	return combo
end

--------------------------------------------------------------------------------
-- Pick Mode (select entity from 3D view)
--------------------------------------------------------------------------------
local function drawPickModeHUD()
	if not EntitySelector.PickMode then return end
	-- Self-heal: if the owning panel was removed while picking, tear pick mode down
	-- (restoring hidden panels and removing the hooks) instead of running forever.
	if EntitySelector.PickOwner and not IsValid(EntitySelector.PickOwner) then
		EntitySelector.StopPickMode()
		return
	end

	local w, h = ScrW(), ScrH()
	local cx, cy = w / 2, h / 2
	-- Header overlay
	surface.SetDrawColor(COLORS.overlay)
	surface.DrawRect(0, 0, w, 60)
	draw.SimpleText(
		"Click on an entity to select it | Press ESC to cancel", "DermaDefault",
		cx, 30, color_white, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER
	)
	-- Crosshair
	surface.SetDrawColor(COLORS.crosshair)
	surface.DrawRect(cx - 1, cy - 12, 2, 10)
	surface.DrawRect(cx - 1, cy + 2, 2, 10)
	surface.DrawRect(cx - 12, cy - 1, 10, 2)
	surface.DrawRect(cx + 2, cy - 1, 10, 2)
	-- Entity info
	local tr = LocalPlayer():GetEyeTrace()
	if IsValid(tr.Entity) and not tr.Entity:IsWorld() then
		local ent = tr.Entity
		Highlight.Set(ent)
		local info = string.format("%s [%d]", ent:GetClass(), ent:EntIndex())
		if ent:GetModel() then info = info .. "\n" .. ent:GetModel() end
		draw.SimpleText(info, "DermaDefault", cx, h - 80, color_white, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
	else
		Highlight.Stop()
	end
end

local function onPickModeClick(ply, bind, pressed)
	if not EntitySelector.PickMode then return end
	if bind ~= "+attack" or not pressed then return end
	local tr = LocalPlayer():GetEyeTrace()
	if not IsValid(tr.Entity) or tr.Entity:IsWorld() then return end
	local ent = tr.Entity
	local opts = EntitySelector.PickOptions
	if opts.filter and not opts.filter(ent) then return end
	EntitySelector.StopPickMode()
	if opts.onSelect then opts.onSelect(ent) end
	return true
end

local function onPickModeKey(ply, button)
	if not EntitySelector.PickMode or button ~= KEY_ESCAPE then return end
	local opts = EntitySelector.PickOptions
	EntitySelector.StopPickMode()
	if opts and opts.onCancel then opts.onCancel() end
end

function EntitySelector.StartPickMode(options)
	options = options or {}
	if EntitySelector.PickMode then EntitySelector.StopPickMode() end
	EntitySelector.PickMode = true
	EntitySelector.PickOptions = options
	-- Optional owning panel. If it goes invalid while picking (e.g. the caller's
	-- frame is removed by another path), the per-frame HUD hook self-heals by
	-- stopping pick mode, so the hooks and hidden-panel refs don't linger.
	EntitySelector.PickOwner = options.owner
	EntitySelector.HiddenPanels = {}
	-- Hide all top-level panels
	for _, panel in ipairs(vgui.GetWorldPanel():GetChildren()) do
		if IsValid(panel) and panel:IsVisible() and panel:GetClassName() ~= "CGModBase" then
			table.insert(EntitySelector.HiddenPanels, panel)
			panel:SetVisible(false)
		end
	end

	gui.EnableScreenClicker(false)
	hook.Add("HUDPaint", HOOK_ID .. "_Pick", drawPickModeHUD)
	hook.Add("PlayerBindPress", HOOK_ID .. "_Bind", onPickModeClick)
	hook.Add("PlayerButtonDown", HOOK_ID .. "_Key", onPickModeKey)
end

function EntitySelector.StopPickMode()
	if not EntitySelector.PickMode then return end
	EntitySelector.PickMode = false
	Highlight.Stop()
	hook.Remove("HUDPaint", HOOK_ID .. "_Pick")
	hook.Remove("PlayerBindPress", HOOK_ID .. "_Bind")
	hook.Remove("PlayerButtonDown", HOOK_ID .. "_Key")
	if EntitySelector.HiddenPanels then
		for _, panel in ipairs(EntitySelector.HiddenPanels) do
			if IsValid(panel) then panel:SetVisible(true) end
		end

		EntitySelector.HiddenPanels = nil
	end

	EntitySelector.PickOptions = nil
	EntitySelector.PickOwner = nil
end

function EntitySelector.IsPickMode()
	return EntitySelector.PickMode == true
end

--------------------------------------------------------------------------------
-- Search content panel. Reused in three hosts: embedded in the editor sidebar
-- (browse mode), popped out into a standalone window (browse mode), and as a modal
-- entity picker (picker mode -- when a caller passes options.onSelect, the
-- Select/Cancel buttons appear and choosing a row fires onSelect + closes the host).
-- The layout docks top-down so it reflows to a narrow sidebar or a wide window.
--------------------------------------------------------------------------------
local PANEL = {}

function PANEL:Init()
	self:SetPaintBackground(false)
	self.Options = {}

	-- Filters
	local filters = vgui.Create("DPanel", self)
	filters:Dock(TOP)
	filters:SetTall(99)
	filters:SetPaintBackground(false)
	self.ClassEntry = createFilterRow(filters, "Class:", "e.g. prop_physics, npc_*")
	self.ModelEntry = createFilterRow(filters, "Model:", "e.g. *barrel*, models/props/*")
	self.LuaEntry = createFilterRow(filters, "Lua:", "expr -> entity, e.g. E(\"bob\") or props()")

	-- Realm + radius
	local optRow = vgui.Create("DPanel", self)
	optRow:Dock(TOP)
	optRow:SetTall(24)
	optRow:DockMargin(5, 5, 5, 0)
	optRow:SetPaintBackground(false)
	self.RealmCombo = makeCombo(optRow, REALM_CHOICES, "local")
	self.RealmCombo:Dock(LEFT)
	self.RealmCombo:SetWide(70)
	self.RealmCombo:SetTooltip("Which realm to search: your client, the server (superadmin), or both")
	self.RadiusSlider = vgui.Create("DNumSlider", optRow)
	self.RadiusSlider:SetSkin("Noir")
	self.RadiusSlider:Dock(FILL)
	self.RadiusSlider:DockMargin(8, 0, 0, 0)
	self.RadiusSlider:SetMin(100)
	self.RadiusSlider:SetMax(5000)
	self.RadiusSlider:SetDecimals(0)
	self.RadiusSlider:SetValue(1000)
	self.RadiusSlider:SetText("Radius")
	self.RadiusSlider.Label:SetTextColor(COLORS.text)

	-- Action buttons. Manually laid out (not docked) so they distribute evenly across
	-- whatever width the host gives us -- fits a narrow sidebar and a wide window alike.
	local btnRow = vgui.Create("DPanel", self)
	btnRow:Dock(TOP)
	btnRow:SetTall(26)
	btnRow:DockMargin(5, 5, 5, 0)
	btnRow:SetPaintBackground(false)
	local searchBtn = createButton(btnRow, "Search", true)
	local nearbyBtn = createButton(btnRow, "Nearby", false)
	local evalBtn = createButton(btnRow, "Eval", false)
	local pickBtn = createButton(btnRow, "Pick", false)
	pickBtn:SetTooltip("Pick an entity from your 3D view")
	local rowButtons = {searchBtn, nearbyBtn, evalBtn, pickBtn}
	btnRow.PerformLayout = function(_, w, h)
		local gap, n = 4, #rowButtons
		local bw = (w - gap * (n - 1)) / n
		for i, b in ipairs(rowButtons) do
			b:SetPos((i - 1) * (bw + gap), 0)
			b:SetSize(bw, h)
		end
	end

	-- Bottom row: status label (always) + Select/Cancel (picker mode only).
	local bottom = vgui.Create("DPanel", self)
	bottom:Dock(BOTTOM)
	bottom:SetTall(28)
	bottom:DockMargin(5, 5, 5, 5)
	bottom:SetPaintBackground(false)
	self.SelectBtn = createButton(bottom, "Select", true)
	self.SelectBtn:Dock(RIGHT)
	self.SelectBtn:SetWide(90)
	self.SelectBtn:SetVisible(false)
	self.CancelBtn = createButton(bottom, "Cancel", false)
	self.CancelBtn:Dock(RIGHT)
	self.CancelBtn:DockMargin(0, 0, 5, 0)
	self.CancelBtn:SetWide(70)
	self.CancelBtn:SetVisible(false)
	self.StatusLabel = vgui.Create("DLabel", bottom)
	self.StatusLabel:Dock(FILL)
	self.StatusLabel:SetTextColor(COLORS.text)
	self.StatusLabel:SetText("")

	-- Results
	self.ListView = vgui.Create("DListView", self)
	self.ListView:SetSkin("Noir")
	self.ListView:Dock(FILL)
	self.ListView:DockMargin(5, 5, 5, 0)
	self.ListView:SetMultiSelect(false)
	self.ListView:AddColumn("Realm"):SetFixedWidth(50)
	self.ListView:AddColumn("ID"):SetFixedWidth(44)
	self.ListView:AddColumn("Class")
	self.ListView:AddColumn("Model")
	self.ListView:AddColumn("Dist"):SetFixedWidth(52)

	-- Wiring
	searchBtn.DoClick = function()
		self:RunQuery("filter", {classFilter = self.ClassEntry:GetText():Trim(), modelFilter = self.ModelEntry:GetText():Trim()})
	end

	nearbyBtn.DoClick = function() self:RunQuery("nearby", {radius = self.RadiusSlider:GetValue()}) end
	evalBtn.DoClick = function() self:RunQuery("lua", {code = self.LuaEntry:GetText()}) end
	pickBtn.DoClick = function() self:StartPick() end
	self.LuaEntry.OnEnter = evalBtn.DoClick
	self.ClassEntry.OnEnter = searchBtn.DoClick
	self.ModelEntry.OnEnter = searchBtn.DoClick
	self.ListView.OnRowSelected = function(_, _, row) if IsValid(row.Entity) then Highlight.Set(row.Entity) end end
	self.ListView.DoDoubleClick = function(_, _, row) self:SelectEntity(row.Entity, row) end
	self.ListView.OnCursorExited = function() Highlight.Stop() end
	self.SelectBtn.DoClick = function()
		local _, row = self.ListView:GetSelectedLine()
		if row then self:SelectEntity(row.Entity, row) end
	end

	self.CancelBtn.DoClick = function() if IsValid(self.HostFrame) then self.HostFrame:Remove() end end
end

-- Apply host options and run the initial (nearby) query. options: filter, onSelect,
-- onCancel. Passing onSelect switches the panel into modal-picker mode.
function PANEL:SetSearchOptions(options)
	self.Options = options or {}
	local picker = self.Options.onSelect ~= nil
	self.SelectBtn:SetVisible(picker)
	self.CancelBtn:SetVisible(picker)
	self:RunQuery("nearby", {radius = self.RadiusSlider:GetValue()})
end

-- Re-run the last query (sidebar Refresh action).
function PANEL:Refresh()
	local last = self.LastQuery
	if last then
		self:RunQuery(last.mode, last.params)
	else
		self:RunQuery("nearby", {radius = self.RadiusSlider:GetValue()})
	end
end

-- Add descriptor rows for one realm. Entity handles are resolved from the shared
-- EntIndex (networked entities exist on both realms); distance is computed against
-- the local player so both realms' columns are comparable. Rows for entities not
-- present locally still show, but carry a NULL handle.
function PANEL:AddResults(descriptors, realm)
	local plyPos = LocalPlayer():GetPos()
	local filter = self.Options.filter
	for _, d in ipairs(descriptors) do
		local ent = Entity(d.index)
		-- The filter runs on a live handle; skip rows we can't verify against it.
		if not filter or (IsValid(ent) and filter(ent)) then
			local pos = IsValid(ent) and ent:GetPos() or Vector(d.x or 0, d.y or 0, d.z or 0)
			local line = self.ListView:AddLine(
				realm == "server" and "Server" or "Local",
				d.index, d.class, truncateModel(d.model, 40), math.floor(pos:Distance(plyPos))
			)

			line.Entity = ent
			line.Descriptor = d
			line.Realm = realm
		end
	end

	self.ListView:SortByColumn(5)
end

-- Run a query (mode "filter" / "nearby" / "lua") across the selected realm(s).
-- Clear the in-world highlight and drop the list selection (de-select).
function PANEL:ClearHighlight()
	Highlight.Stop()
	if IsValid(self.ListView) then self.ListView:ClearSelection() end
end

function PANEL:RunQuery(mode, params)
	self.LastQuery = {mode = mode, params = params}
	-- A fresh search de-selects: the previously highlighted row is about to vanish.
	Highlight.Stop()
	self.ListView:Clear()
	-- Drop any in-flight server request so its late reply can't append to a list
	-- we've just cleared (e.g. after switching to Local-only or re-searching).
	if self.PendingRemote then
		Noir.EntitySearch.SendCancel(self.PendingRemote)
		self.PendingRemote = nil
	end

	local target = self.RealmCombo.NoirValue or "local"
	local wantServer = target == "server" or target == "both"
	if target == "local" or target == "both" then
		local descriptors, err = Noir.EntitySearch.Gather({
			mode = mode,
			classFilter = params.classFilter,
			modelFilter = params.modelFilter,
			radius = params.radius,
			code = params.code,
			origin = LocalPlayer():GetPos(),
			runner = LocalPlayer()
		}, LocalPlayer())

		if err then
			self.StatusLabel:SetText("Local: " .. err)
			Noir.Error("Entity Search (local): ", err, "\n")
		else
			self:AddResults(descriptors, "local")
			if not wantServer then self.StatusLabel:SetText(Format("%d entities", #descriptors)) end
		end
	end

	if not wantServer then return end

	-- Server search: fire a request, merge results in when the reply lands. The
	-- server silently drops unauthorized requests, so time out the spinner.
	self.StatusLabel:SetText("Searching server...")
	local reqId
	reqId = Noir.EntitySearch.SendRemote({
		mode = mode,
		classFilter = params.classFilter,
		modelFilter = params.modelFilter,
		radius = params.radius,
		code = params.code
	}, {
		OnRemoteResults = function(decoded)
			if not IsValid(self) then return end
			self.PendingRemote = nil
			if decoded.error then
				self.StatusLabel:SetText("Server: " .. decoded.error)
				Noir.Error("Entity Search (server): ", decoded.error, "\n")
				return
			end

			local results = decoded.results or {}
			self:AddResults(results, "server")
			self.StatusLabel:SetText(Format("Server: %d entities", #results))
		end
	})

	self.PendingRemote = reqId
	timer.Simple(5, function()
		if not IsValid(self) then return end
		if self.PendingRemote ~= reqId or not Noir.Network.IsRequestPending(reqId) then return end
		Noir.EntitySearch.SendCancel(reqId)
		self.PendingRemote = nil
		self.StatusLabel:SetText("Server search denied or timed out (needs superadmin)")
		Noir.Msg("Server entity search denied or timed out (needs superadmin)\n")
	end)
end

function PANEL:StartPick()
	-- StartPickMode hides every top-level panel (incl. the editor frame) for the pick
	-- and restores them on stop, so we don't manage host visibility ourselves.
	EntitySelector.StartPickMode({
		owner = self,
		filter = self.Options.filter,
		onSelect = function(ent) self:SelectEntity(ent) end
	})
end

-- Act on a chosen entity. In picker mode this fires onSelect and closes the host
-- (which needs a live client handle). In browse mode it highlights the entity (when
-- present locally) and echoes it into the Main Console's REPL output. `row` carries
-- the descriptor/realm so a server-only entity (no client handle) can still be
-- evaluated on the server.
function PANEL:SelectEntity(ent, row)
	local opts = self.Options
	if opts.onSelect then
		if not IsValid(ent) then
			Noir.Msg("That entity isn't available on this client (server-only)\n")
			return
		end

		if opts.filter and not opts.filter(ent) then return end
		Highlight.Stop()
		self.Selecting = true
		opts.onSelect(ent)
		if IsValid(self.HostFrame) then self.HostFrame:Remove() end
		return
	end

	if IsValid(ent) then Highlight.Set(ent) end
	self:SendToConsole(ent, row)
end

-- Echo the selected entity into the Main Console by evaluating Entity(index) on its
-- realm (server rows run on the server, everything else on the client).
function PANEL:SendToConsole(ent, row)
	local index = (row and row.Descriptor and row.Descriptor.index) or (IsValid(ent) and ent:EntIndex())
	if not index then return end
	if not (Noir.Editor and Noir.Editor.Console and Noir.Editor.Console.Evaluate) then return end
	local target = (row and row.Realm == "server") and "server" or "self"
	Noir.Editor.Console.Evaluate(Format("Entity(%d)", index), target, "Entity")
end

function PANEL:OnRemove()
	Highlight.Stop()
	if self.PendingRemote then
		Noir.EntitySearch.SendCancel(self.PendingRemote)
		self.PendingRemote = nil
	end

	if EntitySelector.PickOwner == self then EntitySelector.StopPickMode() end
end

vgui.Register("NoirEntitySearch", PANEL, "DPanel")

--------------------------------------------------------------------------------
-- Standalone window. Hosts the search panel in a DFrame -- used as the modal entity
-- picker (dashboard: pass options.onSelect/filter) and as the sidebar's pop-out.
--------------------------------------------------------------------------------
function EntitySelector.Open(options)
	options = options or {}
	if IsValid(EntitySelector.Frame) then EntitySelector.Frame:Remove() end
	local frame = vgui.Create("DFrame")
	frame:SetSkin("Noir")
	frame:SetTitle(options.title or "Entity Search")
	frame:SetSize(640, 460)
	frame:Center()
	frame:SetDraggable(true)
	frame:SetSizable(true)
	frame:SetDeleteOnClose(true)
	frame:MakePopup()
	frame.btnMinim:SetVisible(false)
	frame.btnMaxim:SetVisible(false)

	local content = vgui.Create("NoirEntitySearch", frame)
	content:Dock(FILL)
	content:DockMargin(4, 26, 4, 4)
	content.HostFrame = frame
	content:SetSearchOptions(options)
	frame.Content = content

	frame.OnRemove = function()
		EntitySelector.Frame = nil
		if options.onCancel and not content.Selecting then options.onCancel() end
	end

	EntitySelector.Frame = frame
	return frame
end

function EntitySelector.Close()
	EntitySelector.StopPickMode()
	Highlight.Stop()
	if IsValid(EntitySelector.Frame) then EntitySelector.Frame:Remove() end
end

-- Re-export highlight functions for backwards compatibility
EntitySelector.SetHighlight = Highlight.Set
EntitySelector.AddHighlight = Highlight.Add
EntitySelector.RemoveHighlight = Highlight.Remove
EntitySelector.ToggleHighlight = Highlight.Toggle
EntitySelector.IsHighlighted = Highlight.IsHighlighted
EntitySelector.StopHighlight = Highlight.Stop
EntitySelector.ClearHighlight = Highlight.Clear
EntitySelector.GetHighlightedEntities = Highlight.GetEntities

--------------------------------------------------------------------------------
-- Sidebar view. Registered like the Explorer; `popout` makes the activity-bar
-- right-click menu offer "Open in Window".
--------------------------------------------------------------------------------
if Noir.Editor and Noir.Editor.Sidebar then
	Noir.Editor.Sidebar.RegisterView("entitysearch", {
		title = "Entities",
		icon = "icon16/brick.png",
		tooltip = "Entity Search",
		popout = function() EntitySelector.Open() end,
		-- De-select (drop the in-world highlight) when the view is hidden -- switched
		-- away from or the sidebar collapsed. Window close is handled by PANEL:OnRemove.
		onHide = function(panel) if IsValid(panel) then panel:ClearHighlight() end end,
		actions = {
			{
				icon = "icon16/arrow_refresh.png",
				tooltip = "Refresh",
				onClick = function()
					local def = Noir.Editor.Sidebar.Views["entitysearch"]
					if def and IsValid(def.panel) then def.panel:Refresh() end
				end
			}
		},
		build = function(container)
			local panel = vgui.Create("NoirEntitySearch", container)
			panel:SetSearchOptions({})
			return panel
		end
	})
end

return EntitySelector
