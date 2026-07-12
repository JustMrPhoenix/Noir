local Dashboard = Noir.Dashboard or {}
Noir.Dashboard = Dashboard
-- Internal state
Dashboard.Registrations = Dashboard.Registrations or {}
Dashboard.Values = Dashboard.Values or {}
Dashboard.Callbacks = Dashboard.Callbacks or {}
Dashboard.CollapsedCategories = Dashboard.CollapsedCategories or {}
Dashboard.RegistrationOrder = Dashboard.RegistrationOrder or 0
Dashboard.Frame = nil
Dashboard.PropertySheet = nil
-- Handle metatable for registered dashboards
local DashboardHandle = {}
DashboardHandle.__index = DashboardHandle
function DashboardHandle:Get(key)
	return Dashboard.Get(self._tabName, key)
end

function DashboardHandle:Set(key, value, skipCallback)
	return Dashboard.Set(self._tabName, key, value, skipCallback)
end

function DashboardHandle:OnChange(key, callback)
	return Dashboard.OnChange(self._tabName, key, callback)
end

function DashboardHandle:Reset(key)
	return Dashboard.ResetToDefault(self._tabName, key)
end

function DashboardHandle:ResetAll()
	return Dashboard.ResetTab(self._tabName)
end

function DashboardHandle:Unregister()
	return Dashboard.Unregister(self._tabName)
end

function DashboardHandle:GetName()
	return self._tabName
end

function DashboardHandle:GetRegistration()
	return Dashboard.Registrations[self._tabName]
end

local function CreateDashboardHandle(tabName)
	local handle = setmetatable({}, DashboardHandle)
	handle._tabName = tabName
	return handle
end

local SAVE_FILE = Noir.STORAGE_PATH .. "dashboard.json"
-- Type definitions with validators and renderers
Dashboard.Types = {
	bool = {
		validate = function(val) return isbool(val) end,
		default = false
	},
	number = {
		validate = function(val, def)
			if not isnumber(val) then return false end
			if def.min and val < def.min then return false end
			if def.max and val > def.max then return false end
			return true
		end,
		default = 0
	},
	string = {
		validate = function(val, def)
			if not isstring(val) then return false end
			if def.maxLength and #val > def.maxLength then return false end
			return true
		end,
		default = ""
	},
	text = {
		validate = function(val, def)
			if not isstring(val) then return false end
			return true
		end,
		default = ""
	},
	slider = {
		validate = function(val, def)
			if not isnumber(val) then return false end
			return val >= (def.min or 0) and val <= (def.max or 100)
		end,
		default = 0
	},
	color = {
		validate = function(val) return IsColor(val) or (istable(val) and val.r and val.g and val.b) end,
		default = Color(255, 255, 255)
	},
	dropdown = {
		validate = function(val, def)
			if not def.options then return false end
			for _, opt in ipairs(def.options) do
				if opt.value == val then return true end
			end
			return false
		end,
		default = nil
	},
	keybind = {
		validate = function(val) return isnumber(val) and val >= 0 end,
		default = 0
	},
	button = {
		validate = function() return true end,
		default = nil
	},
	entity = {
		validate = function(val) return val == nil or isentity(val) end,
		default = nil,
		persistent = false
	},
	list = {
		validate = function(val, def)
			if not istable(val) then return false end
			return true
		end,
		default = {}
	},
	vector = {
		validate = function(val) return isvector(val) or (istable(val) and val.x and val.y and val.z) end,
		default = Vector(0, 0, 0)
	}
}

-- Drop every OnChange callback registered under a tab. Used by both Unregister and
-- Register so one registration cycle always yields one set of callbacks -- callers
-- that re-register on reload can't silently stack duplicates.
function Dashboard.ClearCallbacks(tabName)
	for fullKey in pairs(Dashboard.Callbacks) do
		if string.StartWith(fullKey, tabName .. ".") then Dashboard.Callbacks[fullKey] = nil end
	end
end

--[[
	Register settings for a script tab

	@param tabName (string) - Display name for the tab
	@param settings (table) - Table of setting definitions
	@param options (table, optional) - Tab options like icon, description
]]
function Dashboard.Register(tabName, settings, options)
	if not isstring(tabName) or tabName == "" then
		Noir.Error("Dashboard.Register: tabName must be a non-empty string\n")
		return false
	end

	-- A re-register starts a fresh callback generation; drop any prior OnChange
	-- callbacks for this tab so the caller's follow-up OnChange calls don't stack.
	Dashboard.ClearCallbacks(tabName)
	options = options or {}
	-- Preserve original registration order if tab already exists (for hot-reload stability)
	local existingReg = Dashboard.Registrations[tabName]
	local preservedRegOrder = existingReg and existingReg.registrationOrder or nil
	local processedSettings = {}
	for i, setting in ipairs(settings) do
		if not setting.key or not setting.type then
			Noir.Error("Dashboard.Register: Setting ", i, " missing key or type\n")
			continue
		end

		local typeHandler = Dashboard.Types[setting.type]
		if not typeHandler then
			Noir.Error("Dashboard.Register: Unknown type '", setting.type, "' for key '", setting.key, "'\n")
			continue
		end

		local fullKey = tabName .. "." .. setting.key
		local defaultValue = setting.default
		if defaultValue == nil then
			if setting.type == "dropdown" and setting.options and #setting.options > 0 then
				defaultValue = setting.options[1].value
			else
				defaultValue = typeHandler.default
			end
		end

		table.insert(processedSettings, {
			key = setting.key,
			fullKey = fullKey,
			type = setting.type,
			label = setting.label or setting.key,
			description = setting.description,
			default = defaultValue,
			category = setting.category,
			min = setting.min,
			max = setting.max,
			decimals = setting.decimals,
			options = setting.options,
			maxLength = setting.maxLength,
			rows = setting.rows,
			callback = setting.callback,
			-- Entity selector options
			filter = setting.filter,
			-- List options
			suggestOptions = setting.suggestOptions,
			itemValidator = setting.itemValidator,
			displayFormatter = setting.displayFormatter,
			itemActions = setting.itemActions
		})
	end

	if not preservedRegOrder then Dashboard.RegistrationOrder = Dashboard.RegistrationOrder + 1 end
	Dashboard.Registrations[tabName] = {
		name = tabName,
		settings = processedSettings,
		icon = options.icon or "icon16/cog.png",
		description = options.description,
		order = options.order or 0,
		registrationOrder = preservedRegOrder or Dashboard.RegistrationOrder
	}

	Dashboard.InitializeDefaults(tabName)
	if IsValid(Dashboard.Frame) then Dashboard.RefreshTabs() end
	return CreateDashboardHandle(tabName)
end

function Dashboard.Unregister(tabName)
	Dashboard.Registrations[tabName] = nil
	Dashboard.ClearCallbacks(tabName)
	if IsValid(Dashboard.Frame) then Dashboard.RefreshTabs() end
end

function Dashboard.Get(tabName, key)
	local fullKey = tabName .. "." .. key
	if Dashboard.Values[fullKey] ~= nil then return Dashboard.Values[fullKey] end
	local reg = Dashboard.Registrations[tabName]
	if reg then
		for _, setting in ipairs(reg.settings) do
			if setting.key == key then return setting.default end
		end
	end
	return nil
end

function Dashboard.Set(tabName, key, value, skipCallback)
	local fullKey = tabName .. "." .. key
	local reg = Dashboard.Registrations[tabName]
	if not reg then
		Noir.Error("Dashboard.Set: Unknown tab '", tabName, "'\n")
		return false
	end

	local settingDef = nil
	for _, setting in ipairs(reg.settings) do
		if setting.key == key then
			settingDef = setting
			break
		end
	end

	if not settingDef then
		Noir.Error("Dashboard.Set: Unknown key '", key, "' in tab '", tabName, "'\n")
		return false
	end

	local typeHandler = Dashboard.Types[settingDef.type]
	if not typeHandler.validate(value, settingDef) then
		Noir.Error("Dashboard.Set: Invalid value for '", fullKey, "'\n")
		return false
	end

	local oldValue = Dashboard.Values[fullKey]
	Dashboard.Values[fullKey] = value
	if not skipCallback and Dashboard.Callbacks[fullKey] then
		for _, callback in ipairs(Dashboard.Callbacks[fullKey]) do
			local ok, err = pcall(callback, value, oldValue, key, tabName)
			if not ok then Noir.Error("Dashboard callback error: ", err, "\n") end
		end
	end

	Dashboard.Save()
	return true
end

function Dashboard.OnChange(tabName, key, callback)
	local fullKey = tabName .. "." .. key
	Dashboard.Callbacks[fullKey] = Dashboard.Callbacks[fullKey] or {}
	table.insert(Dashboard.Callbacks[fullKey], callback)
end

function Dashboard.ResetToDefault(tabName, key)
	local reg = Dashboard.Registrations[tabName]
	if not reg then return false end
	for _, setting in ipairs(reg.settings) do
		if setting.key == key then
			Dashboard.Set(tabName, key, setting.default)
			return true
		end
	end
	return false
end

function Dashboard.ResetTab(tabName)
	local reg = Dashboard.Registrations[tabName]
	if not reg then return false end
	for _, setting in ipairs(reg.settings) do
		if setting.type ~= "button" then Dashboard.Set(tabName, setting.key, setting.default) end
	end
	return true
end

-- Persistence
function Dashboard.Save()
	local saveData = {}
	for fullKey, value in pairs(Dashboard.Values) do
		-- Check if this type is persistent
		local tabName, key = string.match(fullKey, "^([^%.]+)%.(.+)$")
		local reg = Dashboard.Registrations[tabName]
		local isPersistent = true
		if reg then
			for _, setting in ipairs(reg.settings) do
				if setting.key == key then
					local typeHandler = Dashboard.Types[setting.type]
					if typeHandler and typeHandler.persistent == false then isPersistent = false end
					break
				end
			end
		end

		if not isPersistent then continue end
		if IsColor(value) then
			saveData[fullKey] = {
				_type = "color",
				r = value.r,
				g = value.g,
				b = value.b,
				a = value.a
			}
		elseif isvector(value) then
			saveData[fullKey] = {
				_type = "vector",
				x = value.x,
				y = value.y,
				z = value.z
			}
		else
			saveData[fullKey] = value
		end
	end

	-- Include collapsed categories state
	saveData._collapsedCategories = Dashboard.CollapsedCategories
	file.Write(SAVE_FILE, util.TableToJSON(saveData, Noir.DEBUG))
end

function Dashboard.Load()
	if not file.Exists(SAVE_FILE, "DATA") then
		Dashboard.Values = {}
		return
	end

	local content = file.Read(SAVE_FILE, "DATA")
	local data = util.JSONToTable(content)
	if not data then
		Noir.Warn("Dashboard: Failed to parse ", SAVE_FILE, "\n")
		Dashboard.Values = {}
		return
	end

	Dashboard.Values = {}
	Dashboard.CollapsedCategories = data._collapsedCategories or {}
	for fullKey, value in pairs(data) do
		if fullKey == "_collapsedCategories" then
			continue
		elseif istable(value) and value._type == "color" then
			Dashboard.Values[fullKey] = Color(value.r, value.g, value.b, value.a)
		elseif istable(value) and value._type == "vector" then
			Dashboard.Values[fullKey] = Vector(value.x, value.y, value.z)
		else
			Dashboard.Values[fullKey] = value
		end
	end
end

function Dashboard.InitializeDefaults(tabName)
	local reg = Dashboard.Registrations[tabName]
	if not reg then return end
	for _, setting in ipairs(reg.settings) do
		if Dashboard.Values[setting.fullKey] == nil and setting.type ~= "button" then
			Dashboard.Values[setting.fullKey] = setting.default
		end
	end
end

-- VGUI
function Dashboard.Show(tabName)
	if IsValid(Dashboard.Frame) then
		Dashboard.Frame:Show()
		Dashboard.Frame:MakePopup()
	else
		Dashboard.CreateFrame()
	end

	-- Tab setup is synchronous, so an optional starting tab can be applied directly.
	if tabName then Dashboard.SetActiveTab(tabName) end
end

function Dashboard.Hide()
	if IsValid(Dashboard.Frame) then Dashboard.Frame:Hide() end
end

function Dashboard.Toggle()
	if IsValid(Dashboard.Frame) and Dashboard.Frame:IsVisible() then
		Dashboard.Hide()
	else
		Dashboard.Show()
	end
end

function Dashboard.CreateFrame()
	local frame = vgui.Create("DFrame")
	frame:SetSkin("Noir")
	frame:SetTitle("Noir Dashboard")
	frame:SetSize(650, 550)
	frame:SetMinWidth(450)
	frame:SetMinHeight(350)
	frame:Center()
	frame:SetDraggable(true)
	frame:SetSizable(true)
	frame:SetDeleteOnClose(false)
	frame:MakePopup()
	frame.btnMinim:SetVisible(false)
	frame.btnMaxim:SetVisible(false)
	local oldLayout = frame.PerformLayout
	frame.PerformLayout = function(self, w, h)
		if oldLayout then oldLayout(self, w, h) end
		self.btnClose:SetPos(w - 31, 0)
		self.btnClose:SetSize(31, 24)
	end

	Dashboard.Frame = frame
	Dashboard.Tabs = {}
	Dashboard.TabPanels = {}
	Dashboard.ActiveTab = nil
	-- Tab bar
	local tabBar = vgui.Create("DPanel", frame)
	tabBar:Dock(TOP)
	tabBar:SetTall(30)
	tabBar.Paint = function(self, w, h)
		surface.SetDrawColor(52, 52, 52)
		surface.DrawRect(0, 0, w, h)
	end

	Dashboard.TabBar = tabBar
	-- Content area
	local contentArea = vgui.Create("DPanel", frame)
	contentArea:Dock(FILL)
	contentArea:DockMargin(5, 5, 5, 5)
	contentArea.Paint = function(self, w, h)
		surface.SetDrawColor(42, 42, 42)
		surface.DrawRect(0, 0, w, h)
	end

	Dashboard.ContentArea = contentArea
	Dashboard.RefreshTabs()
end

function Dashboard.SetActiveTab(tabName)
	Dashboard.ActiveTab = tabName
	-- Update tab button appearances
	for name, btn in pairs(Dashboard.Tabs) do
		if name == tabName then
			btn.IsActive = true
		else
			btn.IsActive = false
		end
	end

	-- Show/hide panels
	for name, panel in pairs(Dashboard.TabPanels) do
		if IsValid(panel) then panel:SetVisible(name == tabName) end
	end
end

function Dashboard.RefreshTabs()
	if not IsValid(Dashboard.Frame) then return end
	-- Clear old tabs
	for _, btn in pairs(Dashboard.Tabs or {}) do
		if IsValid(btn) then btn:Remove() end
	end

	Dashboard.Tabs = {}
	-- Clear old panels
	for _, panel in pairs(Dashboard.TabPanels or {}) do
		if IsValid(panel) then panel:Remove() end
	end

	Dashboard.TabPanels = {}
	local sorted = {}
	for name, reg in pairs(Dashboard.Registrations) do
		table.insert(sorted, reg)
	end

	table.sort(sorted, function(a, b) return a.registrationOrder < b.registrationOrder end)
	if #sorted == 0 then
		-- Empty state
		local emptyPanel = vgui.Create("DPanel", Dashboard.ContentArea)
		emptyPanel:Dock(FILL)
		emptyPanel:SetPaintBackground(false)
		local label = vgui.Create("DLabel", emptyPanel)
		label:SetText("No scripts have registered settings yet.")
		label:SetTextColor(Color(150, 150, 150))
		label:SetFont("Trebuchet18")
		label:SizeToContents()
		label:Center()
		emptyPanel.PerformLayout = function(self, w, h) label:Center() end
		Dashboard.TabPanels["__empty__"] = emptyPanel
		return
	end

	local xPos = 5
	for _, reg in ipairs(sorted) do
		-- Create tab button
		local btn = vgui.Create("DButton", Dashboard.TabBar)
		btn:SetText(reg.name)
		btn:SetTextColor(Color(200, 200, 200))
		btn:SetTall(26)
		btn:SetPos(xPos, 2)
		btn.IsActive = false
		btn.Icon = reg.icon
		-- Size to fit icon + text
		surface.SetFont(btn:GetFont())
		local textW = surface.GetTextSize(reg.name)
		btn:SetWide(textW + (reg.icon and 36 or 20))
		btn.Paint = function(self, w, h)
			if self.IsActive then
				surface.SetDrawColor(42, 42, 42)
				surface.DrawRect(0, 0, w, h)
				surface.SetDrawColor(17, 73, 113)
				surface.DrawRect(0, h - 2, w, 2)
			elseif self.Hovered then
				surface.SetDrawColor(62, 62, 62)
				surface.DrawRect(0, 0, w, h)
			end

			-- Draw icon
			if self.Icon then
				surface.SetDrawColor(255, 255, 255)
				surface.SetMaterial(Material(self.Icon))
				surface.DrawTexturedRect(6, (h - 16) / 2, 16, 16)
			end
		end

		-- Offset text for icon
		if reg.icon then btn:SetTextInset(20, 0) end
		btn.DoClick = function() Dashboard.SetActiveTab(reg.name) end
		Dashboard.Tabs[reg.name] = btn
		xPos = xPos + btn:GetWide() + 2
		-- Create content panel
		local panel = Dashboard.CreateTabPanel(reg)
		panel:SetParent(Dashboard.ContentArea)
		panel:Dock(FILL)
		panel:SetVisible(false)
		Dashboard.TabPanels[reg.name] = panel
	end

	-- Activate first tab
	if sorted[1] then Dashboard.SetActiveTab(sorted[1].name) end
end

function Dashboard.CreateTabPanel(registration)
	local scroll = vgui.Create("DScrollPanel")
	scroll:SetSkin("Noir")
	scroll:Dock(FILL)
	local content = vgui.Create("DPanel", scroll)
	content:SetPaintBackground(false)
	content:Dock(TOP)
	content:DockMargin(0, 0, 0, 0)
	if registration.description then
		local desc = vgui.Create("DLabel", content)
		desc:SetText(registration.description)
		desc:SetTextColor(Color(150, 150, 150))
		desc:Dock(TOP)
		desc:DockMargin(10, 10, 10, 5)
		desc:SetWrap(true)
		desc:SetAutoStretchVertical(true)
	end

	local categories = {}
	local categoryOrder = {}
	local uncategorized = {}
	for _, setting in ipairs(registration.settings) do
		if setting.category then
			if not categories[setting.category] then
				categories[setting.category] = {}
				table.insert(categoryOrder, setting.category)
			end

			table.insert(categories[setting.category], setting)
		else
			table.insert(uncategorized, setting)
		end
	end

	for _, setting in ipairs(uncategorized) do
		Dashboard.CreateSettingRow(content, setting, registration.name)
	end

	for _, catName in ipairs(categoryOrder) do
		local categoryKey = registration.name .. "." .. catName
		local isCollapsed = Dashboard.CollapsedCategories[categoryKey] or false
		-- Category header (clickable)
		local header = vgui.Create("DButton", content)
		header:Dock(TOP)
		header:DockMargin(5, 15, 5, 0)
		header:SetTall(26)
		header:SetText("")
		header:SetCursor("hand")
		header.IsCollapsed = isCollapsed
		header.Paint = function(self, w, h)
			-- Background
			local bgColor = self.Hovered and Color(62, 62, 62) or Color(52, 52, 52)
			surface.SetDrawColor(bgColor)
			surface.DrawRect(0, 0, w, h)
			-- Collapse indicator (arrow)
			local arrowX = 10
			local arrowY = h / 2
			surface.SetDrawColor(150, 150, 150)
			if self.IsCollapsed then
				-- Right-pointing arrow (collapsed)
				draw.NoTexture()
				surface.DrawPoly({
					{
						x = arrowX,
						y = arrowY - 4
					},
					{
						x = arrowX + 6,
						y = arrowY
					},
					{
						x = arrowX,
						y = arrowY + 4
					}
				})
			else
				-- Down-pointing arrow (expanded)
				draw.NoTexture()
				surface.DrawPoly({
					{
						x = arrowX - 2,
						y = arrowY - 2
					},
					{
						x = arrowX + 6,
						y = arrowY - 2
					},
					{
						x = arrowX + 2,
						y = arrowY + 4
					}
				})
			end

			-- Category name
			draw.SimpleText(catName, "DermaDefaultBold", 24, h / 2, Color(200, 200, 200), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
			-- Item count
			local itemCount = #categories[catName]
			draw.SimpleText("(" .. itemCount .. ")", "DermaDefault", w - 10, h / 2, Color(120, 120, 120), TEXT_ALIGN_RIGHT, TEXT_ALIGN_CENTER)
		end

		-- Container for category settings
		local categoryContainer = vgui.Create("DPanel", content)
		categoryContainer:Dock(TOP)
		categoryContainer:DockMargin(0, 0, 0, 0)
		categoryContainer:SetPaintBackground(false)
		categoryContainer:SetVisible(not isCollapsed)
		-- Add settings to the container
		local totalHeight = 0
		for _, setting in ipairs(categories[catName]) do
			local row = Dashboard.CreateSettingRow(categoryContainer, setting, registration.name)
			if IsValid(row) then totalHeight = totalHeight + row:GetTall() + 5 end
		end

		categoryContainer:SetTall(totalHeight)
		-- Toggle collapse on click
		header.DoClick = function(self)
			self.IsCollapsed = not self.IsCollapsed
			Dashboard.CollapsedCategories[categoryKey] = self.IsCollapsed
			categoryContainer:SetVisible(not self.IsCollapsed)
			-- Force layout update
			content:InvalidateLayout(true)
			content:SizeToChildren(false, true)
		end
	end

	-- Reset button at bottom
	local resetBtn = vgui.Create("DButton", content)
	resetBtn:SetSkin("Noir")
	resetBtn:SetText("Reset All to Defaults")
	resetBtn:Dock(TOP)
	resetBtn:DockMargin(10, 20, 10, 10)
	resetBtn:SetTall(30)
	resetBtn.BackgroundColor = Color(80, 40, 40)
	resetBtn.HoveredColor = Color(120, 50, 50)
	resetBtn.DoClick = function()
		Dashboard.ResetTab(registration.name)
		Dashboard.RefreshTabs()
	end

	content:InvalidateLayout(true)
	content:SizeToChildren(false, true)
	return scroll
end

function Dashboard.CreateSettingRow(parent, setting, tabName)
	local rowHeight = 30
	if setting.type == "color" then
		rowHeight = 140
	elseif setting.type == "text" then
		rowHeight = 24 + (setting.rows or 4) * 16
	elseif setting.type == "slider" then
		rowHeight = 40
	elseif setting.type == "entity" then
		rowHeight = 30
	elseif setting.type == "list" then
		rowHeight = 150
	elseif setting.type == "vector" then
		rowHeight = 30
	end

	local row = vgui.Create("DPanel", parent)
	row:SetSkin("Noir")
	row:Dock(TOP)
	row:DockMargin(10, 5, 10, 0)
	row:SetTall(rowHeight)
	row:SetPaintBackground(false)
	local topRow = vgui.Create("DPanel", row)
	topRow:Dock(TOP)
	topRow:SetTall(24)
	topRow:SetPaintBackground(false)
	local label = vgui.Create("DLabel", topRow)
	label:SetText(setting.label)
	label:SetTextColor(Color(200, 200, 200))
	label:Dock(LEFT)
	label:SetWide(180)
	if setting.description then label:SetTooltip(setting.description) end
	if setting.type ~= "button" then
		local resetBtn = vgui.Create("DButton", topRow)
		resetBtn:SetSkin("Noir")
		resetBtn:SetText("")
		resetBtn:SetIcon("icon16/arrow_refresh_small.png")
		resetBtn:Dock(RIGHT)
		resetBtn:SetWide(24)
		resetBtn:SetTooltip("Reset to default")
		resetBtn.BackgroundColor = Color(60, 60, 60, 0)
		resetBtn.HoveredColor = Color(80, 80, 80)
		resetBtn.DoClick = function()
			Dashboard.ResetToDefault(tabName, setting.key)
			Dashboard.RefreshTabs()
		end
	end

	local controlParent = row
	if setting.type ~= "color" and setting.type ~= "text" and setting.type ~= "list" then controlParent = topRow end
	local control = Dashboard.CreateControl(controlParent, setting, tabName)
	if control then
		if setting.type == "color" or setting.type == "text" or setting.type == "list" then
			control:Dock(FILL)
			control:DockMargin(0, 5, 0, 0)
		elseif setting.type == "bool" then
			control:Dock(LEFT)
			control:DockMargin(10, 4, 0, 4)
			control:SetWide(16)
		else
			control:Dock(FILL)
			control:DockMargin(10, 0, 30, 0)
		end
	end
	return row
end

function Dashboard.CreateControl(parent, setting, tabName)
	local currentValue = Dashboard.Values[setting.fullKey]
	if currentValue == nil then currentValue = setting.default end
	if setting.type == "bool" then
		local checkbox = vgui.Create("DCheckBox", parent)
		checkbox:SetSkin("Noir")
		checkbox:SetChecked(currentValue == true)
		checkbox.OnChange = function(_, val) Dashboard.Set(tabName, setting.key, val) end
		return checkbox
	elseif setting.type == "number" then
		local wang = vgui.Create("DNumberWang", parent)
		wang:SetSkin("Noir")
		wang:SetMin(setting.min or -999999)
		wang:SetMax(setting.max or 999999)
		wang:SetDecimals(setting.decimals or 0)
		wang:SetValue(currentValue or 0)
		wang.OnValueChanged = function(_, val) Dashboard.Set(tabName, setting.key, val) end
		return wang
	elseif setting.type == "string" then
		local entry = vgui.Create("DTextEntry", parent)
		entry:SetSkin("Noir")
		entry:SetText(currentValue or "")
		entry.OnChange = function() Dashboard.Set(tabName, setting.key, entry:GetText()) end
		return entry
	elseif setting.type == "text" then
		local entry = vgui.Create("DTextEntry", parent)
		entry:SetSkin("Noir")
		entry:SetMultiline(true)
		entry:SetText(currentValue or "")
		entry.OnChange = function() Dashboard.Set(tabName, setting.key, entry:GetText()) end
		return entry
	elseif setting.type == "slider" then
		local slider = vgui.Create("DNumSlider", parent)
		slider:SetSkin("Noir")
		slider:SetMin(setting.min or 0)
		slider:SetMax(setting.max or 100)
		slider:SetDecimals(setting.decimals or 0)
		slider:SetValue(currentValue or 0)
		slider:SetText("")
		slider.Label:SetVisible(false)
		-- Add track line to the slider
		if IsValid(slider.Slider) then
			local oldPaint = slider.Slider.Paint
			slider.Slider.Paint = function(self, w, h)
				-- Draw track line
				local trackY = h / 2
				surface.SetDrawColor(80, 80, 80)
				surface.DrawRect(0, trackY - 2, w, 4)
				surface.SetDrawColor(17, 73, 113)
				local knobX = self.Knob and self.Knob:GetX() or 0
				surface.DrawRect(0, trackY - 2, knobX, 4)
				if oldPaint then oldPaint(self, w, h) end
			end
		end

		slider.OnValueChanged = function(_, val) Dashboard.Set(tabName, setting.key, val) end
		return slider
	elseif setting.type == "color" then
		local mixer = vgui.Create("DColorMixer", parent)
		mixer:SetSkin("Noir")
		mixer:SetAlphaBar(true)
		mixer:SetPalette(false)
		mixer:SetWangs(true)
		if IsColor(currentValue) then
			mixer:SetColor(currentValue)
		else
			mixer:SetColor(Color(255, 255, 255))
		end

		mixer.ValueChanged = function(_, col) Dashboard.Set(tabName, setting.key, Color(col.r, col.g, col.b, col.a)) end
		return mixer
	elseif setting.type == "dropdown" then
		local combo = vgui.Create("DComboBox", parent)
		combo:SetSkin("Noir")
		combo:SetTextColor(Color(200, 200, 200))
		local selectedIdx = 1
		for i, opt in ipairs(setting.options or {}) do
			combo:AddChoice(opt.label, opt.value)
			if opt.value == currentValue then selectedIdx = i end
		end

		combo:ChooseOptionID(selectedIdx)
		combo.OnSelect = function(_, idx, text, data) Dashboard.Set(tabName, setting.key, data) end
		return combo
	elseif setting.type == "keybind" then
		local binder = vgui.Create("DBinder", parent)
		binder:SetSkin("Noir")
		binder:SetValue(currentValue or 0)
		binder.OnChange = function(_, key) Dashboard.Set(tabName, setting.key, key) end
		return binder
	elseif setting.type == "button" then
		local btn = vgui.Create("DButton", parent)
		btn:SetSkin("Noir")
		btn:SetText(setting.label)
		btn:SetTextColor(Color(200, 200, 200))
		btn.BackgroundColor = Color(60, 60, 60)
		btn.HoveredColor = Color(80, 80, 80)
		btn.DoClick = function()
			if setting.callback then
				local ok, err = pcall(setting.callback)
				if not ok then Noir.Error("Dashboard button callback error: ", err, "\n") end
			end
		end
		return btn
	elseif setting.type == "entity" then
		local container = vgui.Create("DPanel", parent)
		container:SetPaintBackground(false)
		local displayLabel = vgui.Create("DLabel", container)
		displayLabel:SetTextColor(Color(200, 200, 200))
		displayLabel:Dock(LEFT)
		displayLabel:SetWide(200)
		local function updateDisplay()
			local ent = Dashboard.Values[setting.fullKey]
			if IsValid(ent) then
				displayLabel:SetText(string.format("[%d] %s", ent:EntIndex(), ent:GetClass()))
			else
				displayLabel:SetText("None")
			end
		end

		updateDisplay()
		local clearBtn = vgui.Create("DButton", container)
		clearBtn:SetSkin("Noir")
		clearBtn:SetText("Clear")
		clearBtn:Dock(RIGHT)
		clearBtn:SetWide(50)
		clearBtn.BackgroundColor = Color(80, 40, 40)
		clearBtn.HoveredColor = Color(120, 50, 50)
		clearBtn.DoClick = function()
			Dashboard.Set(tabName, setting.key, nil)
			updateDisplay()
		end

		local viewBtn = vgui.Create("DButton", container)
		viewBtn:SetSkin("Noir")
		viewBtn:SetText("View")
		viewBtn:Dock(RIGHT)
		viewBtn:DockMargin(0, 0, 5, 0)
		viewBtn:SetWide(50)
		viewBtn.BackgroundColor = Color(60, 60, 60)
		viewBtn.HoveredColor = Color(80, 80, 80)
		viewBtn.DoClick = function()
			local ent = Dashboard.Values[setting.fullKey]
			if IsValid(ent) then
				Noir.EntitySelector.SetHighlight(ent)
				-- Genuine delay: flash the highlight for 2s as a preview, then clear it.
				timer.Simple(2, function() Noir.EntitySelector.StopHighlight() end)
			end
		end

		local searchBtn = vgui.Create("DButton", container)
		searchBtn:SetSkin("Noir")
		searchBtn:SetText("Search")
		searchBtn:Dock(RIGHT)
		searchBtn:DockMargin(0, 0, 5, 0)
		searchBtn:SetWide(60)
		searchBtn.BackgroundColor = Color(60, 60, 60)
		searchBtn.HoveredColor = Color(80, 80, 80)
		searchBtn.DoClick = function()
			Noir.EntitySelector.Open({
				title = "Select " .. setting.label,
				filter = setting.filter,
				onSelect = function(ent)
					Dashboard.Set(tabName, setting.key, ent)
					updateDisplay()
				end
			})
		end

		local pickBtn = vgui.Create("DButton", container)
		pickBtn:SetSkin("Noir")
		pickBtn:SetText("Pick")
		pickBtn:Dock(RIGHT)
		pickBtn:DockMargin(0, 0, 5, 0)
		pickBtn:SetWide(50)
		pickBtn.BackgroundColor = Color(17, 73, 113)
		pickBtn.HoveredColor = Color(25, 100, 150)
		pickBtn.DoClick = function()
			Noir.EntitySelector.StartPickMode({
				owner = Dashboard.Frame,
				filter = setting.filter,
				onSelect = function(ent)
					Dashboard.Set(tabName, setting.key, ent)
					updateDisplay()
					Dashboard.Show()
				end,
				onCancel = function() Dashboard.Show() end
			})
		end
		return container
	elseif setting.type == "list" then
		local container = vgui.Create("DPanel", parent)
		container:SetPaintBackground(false)
		local listView = vgui.Create("DListView", container)
		listView:SetSkin("Noir")
		listView:Dock(FILL)
		listView:SetMultiSelect(false)
		listView:AddColumn("Value")
		local function refreshList()
			listView:Clear()
			local items = Dashboard.Values[setting.fullKey] or {}
			for i, item in ipairs(items) do
				local displayText
				if setting.displayFormatter then
					displayText = setting.displayFormatter(item)
				else
					displayText = tostring(item)
				end

				local line = listView:AddLine(displayText)
				line.ItemIndex = i
				line.ItemValue = item
			end
		end

		refreshList()
		-- Right click menu
		listView.OnRowRightClick = function(_, idx, row)
			local menu = DermaMenu()
			menu:SetSkin("Noir")
			-- Custom per-item actions. Each action may carry a `submenu` of sub-actions.
			-- Action callbacks receive (item, index) and mutate the item in place; the
			-- list is re-saved and refreshed afterwards.
			local actions = setting.itemActions
			if isfunction(actions) then actions = actions(row.ItemValue, row.ItemIndex) end
			if istable(actions) and #actions > 0 then
				local function runAction(action)
					if action.callback then action.callback(row.ItemValue, row.ItemIndex) end
					Dashboard.Set(tabName, setting.key, Dashboard.Values[setting.fullKey] or {})
					refreshList()
				end

				for _, action in ipairs(actions) do
					if istable(action.submenu) then
						local sub, parentOpt = menu:AddSubMenu(action.label)
						sub:SetSkin("Noir")
						if action.icon then parentOpt:SetIcon(action.icon) end
						for _, subAction in ipairs(action.submenu) do
							local opt = sub:AddOption(subAction.label, function() runAction(subAction) end)
							opt:SetIcon(subAction.icon or "icon16/bullet_black.png")
						end
					else
						local opt = menu:AddOption(action.label, function() runAction(action) end)
						if action.icon then opt:SetIcon(action.icon) end
					end
				end

				menu:AddSpacer()
			end

			menu:AddOption("Remove", function()
				local items = Dashboard.Values[setting.fullKey] or {}
				table.remove(items, row.ItemIndex)
				Dashboard.Set(tabName, setting.key, items)
				refreshList()
			end):SetIcon("icon16/cross.png")

			menu:AddSpacer()
			menu:AddOption("Move Up", function()
				local items = Dashboard.Values[setting.fullKey] or {}
				local i = row.ItemIndex
				if i > 1 then
					items[i], items[i - 1] = items[i - 1], items[i]
					Dashboard.Set(tabName, setting.key, items)
					refreshList()
				end
			end):SetIcon("icon16/arrow_up.png")

			menu:AddOption("Move Down", function()
				local items = Dashboard.Values[setting.fullKey] or {}
				local i = row.ItemIndex
				if i < #items then
					items[i], items[i + 1] = items[i + 1], items[i]
					Dashboard.Set(tabName, setting.key, items)
					refreshList()
				end
			end):SetIcon("icon16/arrow_down.png")

			menu:Open()
		end

		-- Add button with suggest options
		local addBtn = vgui.Create("DButton", container)
		addBtn:SetSkin("Noir")
		addBtn:SetText("+")
		addBtn:Dock(BOTTOM)
		addBtn:SetTall(24)
		addBtn:DockMargin(0, 5, 0, 0)
		addBtn.BackgroundColor = Color(17, 73, 113)
		addBtn.HoveredColor = Color(25, 100, 150)
		addBtn.DoClick = function()
			local suggestions = setting.suggestOptions
			if isfunction(suggestions) then suggestions = suggestions() end
			if istable(suggestions) and #suggestions > 0 then
				-- Show menu with suggestions
				local menu = DermaMenu()
				menu:SetSkin("Noir")
				menu:AddOption("Custom...", function()
					Dashboard.ShowListAddDialog(tabName, setting, refreshList)
				end):SetIcon("icon16/textfield.png")
				menu:AddSpacer()
				for _, opt in ipairs(suggestions) do
					local label, value
					if istable(opt) then
						label = opt.label or tostring(opt.value)
						value = opt.value
					else
						label = tostring(opt)
						value = opt
					end

					menu:AddOption(label, function()
						local items = Dashboard.Values[setting.fullKey] or {}
						table.insert(items, value)
						Dashboard.Set(tabName, setting.key, items)
						refreshList()
					end)
				end

				menu:Open()
			else
				-- Direct input dialog
				Dashboard.ShowListAddDialog(tabName, setting, refreshList)
			end
		end
		return container
	elseif setting.type == "vector" then
		local container = vgui.Create("DPanel", parent)
		container:SetPaintBackground(false)
		local vec = isvector(currentValue) and currentValue or Vector(0, 0, 0)
		-- X input
		local xLabel = vgui.Create("DLabel", container)
		xLabel:SetText("X:")
		xLabel:SetTextColor(Color(200, 200, 200))
		xLabel:Dock(LEFT)
		xLabel:SetWide(15)
		local xEntry = vgui.Create("DNumberWang", container)
		xEntry:SetSkin("Noir")
		xEntry:SetMin(-999999)
		xEntry:SetMax(999999)
		xEntry:SetDecimals(setting.decimals or 2)
		xEntry:SetValue(vec.x)
		xEntry:Dock(LEFT)
		xEntry:SetWide(70)
		xEntry:DockMargin(0, 0, 5, 0)
		-- Y input
		local yLabel = vgui.Create("DLabel", container)
		yLabel:SetText("Y:")
		yLabel:SetTextColor(Color(200, 200, 200))
		yLabel:Dock(LEFT)
		yLabel:SetWide(15)
		local yEntry = vgui.Create("DNumberWang", container)
		yEntry:SetSkin("Noir")
		yEntry:SetMin(-999999)
		yEntry:SetMax(999999)
		yEntry:SetDecimals(setting.decimals or 2)
		yEntry:SetValue(vec.y)
		yEntry:Dock(LEFT)
		yEntry:SetWide(70)
		yEntry:DockMargin(0, 0, 5, 0)
		-- Z input
		local zLabel = vgui.Create("DLabel", container)
		zLabel:SetText("Z:")
		zLabel:SetTextColor(Color(200, 200, 200))
		zLabel:Dock(LEFT)
		zLabel:SetWide(15)
		local zEntry = vgui.Create("DNumberWang", container)
		zEntry:SetSkin("Noir")
		zEntry:SetMin(-999999)
		zEntry:SetMax(999999)
		zEntry:SetDecimals(setting.decimals or 2)
		zEntry:SetValue(vec.z)
		zEntry:Dock(LEFT)
		zEntry:SetWide(70)
		zEntry:DockMargin(0, 0, 10, 0)
		local function updateValue()
			local newVec = Vector(xEntry:GetValue(), yEntry:GetValue(), zEntry:GetValue())
			Dashboard.Set(tabName, setting.key, newVec)
		end

		xEntry.OnValueChanged = function() updateValue() end
		yEntry.OnValueChanged = function() updateValue() end
		zEntry.OnValueChanged = function() updateValue() end
		local function setVector(newVec)
			xEntry:SetValue(newVec.x)
			yEntry:SetValue(newVec.y)
			zEntry:SetValue(newVec.z)
			updateValue()
		end

		-- Get player position button
		local getPosBtn = vgui.Create("DButton", container)
		getPosBtn:SetSkin("Noir")
		getPosBtn:SetText("Get Pos")
		getPosBtn:SetTooltip("Set to your current position")
		getPosBtn:Dock(LEFT)
		getPosBtn:SetWide(55)
		getPosBtn:DockMargin(0, 3, 5, 3)
		getPosBtn.BackgroundColor = Color(60, 60, 60)
		getPosBtn.HoveredColor = Color(80, 80, 80)
		getPosBtn.DoClick = function()
			local ply = LocalPlayer()
			if IsValid(ply) then setVector(ply:GetPos()) end
		end

		-- Pick position from world button
		local pickBtn = vgui.Create("DButton", container)
		pickBtn:SetSkin("Noir")
		pickBtn:SetText("Pick")
		pickBtn:SetTooltip("Click a position in the world")
		pickBtn:Dock(LEFT)
		pickBtn:SetWide(40)
		pickBtn:DockMargin(0, 3, 0, 3)
		pickBtn.BackgroundColor = Color(17, 73, 113)
		pickBtn.HoveredColor = Color(25, 100, 150)
		pickBtn.DoClick = function()
			Dashboard.Hide()
			Dashboard.StartVectorPick(function(pos)
				setVector(pos)
				Dashboard.Show()
			end, function() Dashboard.Show() end)
		end
		return container
	end
	return nil
end

-- Helper for list add dialog
function Dashboard.ShowListAddDialog(tabName, setting, refreshCallback)
	local frame = vgui.Create("DFrame")
	frame:SetSkin("Noir")
	frame:SetTitle("Add Item")
	frame:SetSize(300, 120)
	frame:Center()
	frame:SetDraggable(true)
	frame:MakePopup()
	frame.btnMinim:SetVisible(false)
	frame.btnMaxim:SetVisible(false)
	local entry = vgui.Create("DTextEntry", frame)
	entry:SetSkin("Noir")
	entry:Dock(TOP)
	entry:DockMargin(10, 10, 10, 10)
	entry:SetTall(28)
	entry:RequestFocus()
	local btnPanel = vgui.Create("DPanel", frame)
	btnPanel:Dock(BOTTOM)
	btnPanel:DockMargin(10, 0, 10, 10)
	btnPanel:SetTall(30)
	btnPanel:SetPaintBackground(false)
	local addBtn = vgui.Create("DButton", btnPanel)
	addBtn:SetSkin("Noir")
	addBtn:SetText("Add")
	addBtn:Dock(RIGHT)
	addBtn:SetWide(80)
	addBtn.BackgroundColor = Color(17, 73, 113)
	addBtn.HoveredColor = Color(25, 100, 150)
	local cancelBtn = vgui.Create("DButton", btnPanel)
	cancelBtn:SetSkin("Noir")
	cancelBtn:SetText("Cancel")
	cancelBtn:Dock(RIGHT)
	cancelBtn:DockMargin(0, 0, 5, 0)
	cancelBtn:SetWide(80)
	cancelBtn.BackgroundColor = Color(60, 60, 60)
	cancelBtn.HoveredColor = Color(80, 80, 80)
	cancelBtn.DoClick = function() frame:Remove() end
	local doAdd = function()
		local text = entry:GetText():Trim()
		if text == "" then return end
		local value = text
		if setting.itemValidator then
			local validated = setting.itemValidator(text)
			if validated == nil or validated == false then return end
			if validated ~= true then value = validated end
		end

		local items = Dashboard.Values[setting.fullKey] or {}
		table.insert(items, value)
		Dashboard.Set(tabName, setting.key, items)
		refreshCallback()
		frame:Remove()
	end

	addBtn.DoClick = doAdd
	entry.OnEnter = doAdd
end

-- Vector pick mode
Dashboard.VectorPickActive = false
Dashboard.VectorPickCallback = nil
Dashboard.VectorPickCancelCallback = nil
function Dashboard.StartVectorPick(onSelect, onCancel)
	Dashboard.VectorPickActive = true
	Dashboard.VectorPickCallback = onSelect
	Dashboard.VectorPickCancelCallback = onCancel
	hook.Add("HUDPaint", "Noir.Dashboard.VectorPick", function()
		if not Dashboard.VectorPickActive then return end
		-- Draw crosshair hint
		local scrW, scrH = ScrW(), ScrH()
		draw.SimpleText(
			"Attack to select position (Secondary attack or ESC to cancel)", "DermaDefaultBold",
			scrW / 2, scrH - 100, Color(255, 255, 255), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER
		)
		-- Draw target position
		local tr = LocalPlayer():GetEyeTrace()
		if tr.Hit then
			local pos = tr.HitPos:ToScreen()
			if pos.visible then
				surface.SetDrawColor(17, 73, 113, 200)
				surface.DrawRect(pos.x - 10, pos.y - 1, 21, 3)
				surface.DrawRect(pos.x - 1, pos.y - 10, 3, 21)
				local posText = string.format("%.1f, %.1f, %.1f", tr.HitPos.x, tr.HitPos.y, tr.HitPos.z)
				draw.SimpleText(posText, "DermaDefault", pos.x, pos.y + 20, Color(200, 200, 200), TEXT_ALIGN_CENTER)
			end
		end
	end)

	hook.Add("PlayerButtonDown", "Noir.Dashboard.VectorPick", function(ply, button)
		if not Dashboard.VectorPickActive then return end
		if ply ~= LocalPlayer() then return end
		if button == KEY_ESCAPE then
			if Dashboard.VectorPickCancelCallback then Dashboard.VectorPickCancelCallback() end
			Dashboard.StopVectorPick()
			return true
		end
	end)

	hook.Add("KeyPress", "Noir.Dashboard.VectorPick", function(ply, key)
		if not Dashboard.VectorPickActive then return end
		if ply ~= LocalPlayer() then return end
		if key == IN_ATTACK then
			local tr = ply:GetEyeTrace()
			if tr.Hit and Dashboard.VectorPickCallback then Dashboard.VectorPickCallback(tr.HitPos) end
			Dashboard.StopVectorPick()
		elseif key == IN_ATTACK2 then
			if Dashboard.VectorPickCancelCallback then Dashboard.VectorPickCancelCallback() end
			Dashboard.StopVectorPick()
		end
	end)
end

function Dashboard.StopVectorPick()
	Dashboard.VectorPickActive = false
	Dashboard.VectorPickCallback = nil
	Dashboard.VectorPickCancelCallback = nil
	hook.Remove("HUDPaint", "Noir.Dashboard.VectorPick")
	hook.Remove("PlayerButtonDown", "Noir.Dashboard.VectorPick")
	hook.Remove("KeyPress", "Noir.Dashboard.VectorPick")
end

-- Console command
concommand.Add("noir_dashboard", function() Dashboard.Show() end, nil, "Open Noir Dashboard")
-- Load saved values on init
Dashboard.Load()
