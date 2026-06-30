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
	lbl:SetWide(60)
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

local function matchesPattern(text, pattern)
	if pattern == "" then return true end
	local luaPattern = string.gsub(pattern, "%*", ".*")
	return string.match(string.lower(text), string.lower(luaPattern)) ~= nil
end

local function truncateModel(model, maxLen)
	if not model or #model <= maxLen then return model or "" end
	return "..." .. string.sub(model, -(maxLen - 3))
end

--------------------------------------------------------------------------------
-- List Population
--------------------------------------------------------------------------------
local function populateList(listView, entities, filter)
	listView:Clear()
	local plyPos = LocalPlayer():GetPos()
	for _, ent in ipairs(entities) do
		if not IsValid(ent) then continue end
		if filter and not filter(ent) then continue end
		local dist = math.floor(ent:GetPos():Distance(plyPos))
		local model = truncateModel(ent:GetModel(), 40)
		local line = listView:AddLine(ent:EntIndex(), ent:GetClass(), model, dist)
		line.Entity = ent
	end

	listView:SortByColumn(4)
end

local function searchEntities(classFilter, modelFilter)
	local results = {}
	local ply = LocalPlayer()
	for _, ent in ipairs(ents.GetAll()) do
		if not IsValid(ent) or ent == ply or ent:IsWorld() then continue end
		local class = ent:GetClass()
		local model = ent:GetModel() or ""
		if not matchesPattern(class, classFilter) then continue end
		if not matchesPattern(model, modelFilter) then continue end
		table.insert(results, ent)
	end
	return results
end

local function getNearbyEntities(radius)
	local results = {}
	local ply = LocalPlayer()
	local plyPos = ply:GetPos()
	for _, ent in ipairs(ents.FindInSphere(plyPos, radius)) do
		if not IsValid(ent) or ent == ply or ent:IsWorld() then continue end
		table.insert(results, ent)
	end
	return results
end

--------------------------------------------------------------------------------
-- Pick Mode (select entity from 3D view)
--------------------------------------------------------------------------------
local function drawPickModeHUD()
	if not EntitySelector.PickMode then return end
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
end

function EntitySelector.IsPickMode()
	return EntitySelector.PickMode == true
end

--------------------------------------------------------------------------------
-- Main UI
--------------------------------------------------------------------------------
function EntitySelector.Open(options)
	options = options or {}
	if IsValid(EntitySelector.Frame) then EntitySelector.Frame:Remove() end
	-- Main frame
	local frame = vgui.Create("DFrame")
	frame:SetSkin("Noir")
	frame:SetTitle(options.title or "Entity Selector")
	frame:SetSize(500, 450)
	frame:Center()
	frame:SetDraggable(true)
	frame:SetSizable(true)
	frame:SetDeleteOnClose(true)
	frame:MakePopup()
	frame.btnMinim:SetVisible(false)
	frame.btnMaxim:SetVisible(false)
	frame.OnRemove = function()
		Highlight.Stop()
		EntitySelector.Frame = nil
		if options.onCancel and not frame.Selected then options.onCancel() end
	end

	EntitySelector.Frame = frame
	-- Search filters
	local searchPanel = vgui.Create("DPanel", frame)
	searchPanel:Dock(TOP)
	searchPanel:SetTall(70)
	searchPanel:SetPaintBackground(false)
	local classEntry = createFilterRow(searchPanel, "Class:", "e.g. prop_physics, npc_*")
	local modelEntry = createFilterRow(searchPanel, "Model:", "e.g. *barrel*, models/props/*")
	-- Action buttons
	local btnRow = vgui.Create("DPanel", frame)
	btnRow:Dock(TOP)
	btnRow:SetTall(30)
	btnRow:DockMargin(5, 5, 5, 5)
	btnRow:SetPaintBackground(false)
	local searchBtn = createButton(btnRow, "Search", true)
	searchBtn:Dock(LEFT)
	searchBtn:SetWide(80)
	local viewBtn = createButton(btnRow, "Pick from View", false)
	viewBtn:Dock(LEFT)
	viewBtn:DockMargin(5, 0, 0, 0)
	viewBtn:SetWide(100)
	local nearbyBtn = createButton(btnRow, "Nearby", false)
	nearbyBtn:Dock(LEFT)
	nearbyBtn:DockMargin(5, 0, 0, 0)
	nearbyBtn:SetWide(70)
	local radiusSlider = vgui.Create("DNumSlider", btnRow)
	radiusSlider:SetSkin("Noir")
	radiusSlider:Dock(FILL)
	radiusSlider:DockMargin(10, 0, 0, 0)
	radiusSlider:SetMin(100)
	radiusSlider:SetMax(5000)
	radiusSlider:SetDecimals(0)
	radiusSlider:SetValue(1000)
	radiusSlider:SetText("Radius")
	radiusSlider.Label:SetTextColor(COLORS.text)
	-- Results list
	local listView = vgui.Create("DListView", frame)
	listView:SetSkin("Noir")
	listView:Dock(FILL)
	listView:DockMargin(5, 0, 5, 5)
	listView:SetMultiSelect(false)
	listView:AddColumn("ID"):SetFixedWidth(50)
	listView:AddColumn("Class"):SetFixedWidth(150)
	listView:AddColumn("Model")
	listView:AddColumn("Distance"):SetFixedWidth(70)
	-- Bottom buttons
	local selectPanel = vgui.Create("DPanel", frame)
	selectPanel:Dock(BOTTOM)
	selectPanel:SetTall(35)
	selectPanel:DockMargin(5, 5, 5, 5)
	selectPanel:SetPaintBackground(false)
	local selectBtn = createButton(selectPanel, "Select", true)
	selectBtn:Dock(RIGHT)
	selectBtn:SetWide(100)
	local cancelBtn = createButton(selectPanel, "Cancel", false)
	cancelBtn:Dock(RIGHT)
	cancelBtn:DockMargin(0, 0, 5, 0)
	cancelBtn:SetWide(80)
	-- Selection callback
	local function selectEntity(ent)
		if not IsValid(ent) then return end
		if options.filter and not options.filter(ent) then return end
		frame.Selected = true
		Highlight.Stop()
		frame:Remove()
		if options.onSelect then options.onSelect(ent) end
	end

	-- Button actions
	searchBtn.DoClick = function()
		local results = searchEntities(classEntry:GetText():Trim(), modelEntry:GetText():Trim())
		populateList(listView, results, options.filter)
	end

	nearbyBtn.DoClick = function()
		local results = getNearbyEntities(radiusSlider:GetValue())
		populateList(listView, results, options.filter)
	end

	viewBtn.DoClick = function()
		EntitySelector.StartPickMode({
			filter = options.filter,
			onSelect = function(ent) selectEntity(ent) end,
			onCancel = function()
				frame:SetVisible(true)
				frame:MakePopup()
			end
		})

		frame:SetVisible(false)
	end

	classEntry.OnEnter = searchBtn.DoClick
	modelEntry.OnEnter = searchBtn.DoClick
	listView.OnRowSelected = function(_, idx, row) if IsValid(row.Entity) then Highlight.Set(row.Entity) end end
	listView.DoDoubleClick = function(_, idx, row) selectEntity(row.Entity) end
	listView.OnCursorExited = function() Highlight.Stop() end
	selectBtn.DoClick = function()
		local _, row = listView:GetSelectedLine()
		if row then selectEntity(row.Entity) end
	end

	cancelBtn.DoClick = function()
		Highlight.Stop()
		frame:Remove()
	end

	-- Initial population
	nearbyBtn.DoClick()
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
concommand.Add("noir_entityselector", function() EntitySelector.Open() end, nil, "Open the Noir Entity Selector")
return EntitySelector
