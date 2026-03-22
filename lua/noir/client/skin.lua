local SKIN = {}
SKIN.PrintName = "Noir editor skin"
SKIN.Author = "Mr.Phoenix"
SKIN.Colours = {}
SKIN.Colours.Button = {}
SKIN.Colours.Button.Normal = Color(204, 204, 204)
SKIN.Colours.Button.Disabled = Color(128, 128, 128)
SKIN.Colours.Button.Hover = SKIN.Colours.Button.Normal
SKIN.Colours.Button.Down = SKIN.Colours.Button.Normal
SKIN.Colours.Label = {}
SKIN.Colours.Label.Default = Color(187, 187, 187)
SKIN.Colours.Label.Bright = Color(30, 30, 30) -- Bright and dark are inverted here
SKIN.Colours.Label.Dark = Color(204, 204, 204)
SKIN.Colours.Label.Highlight = Color(244, 71, 71)
SKIN.Colours.Window = {}
SKIN.Colours.Window.TitleActive = Color(51, 51, 51)
SKIN.Colours.Window.TitleInactive = Color(51, 51, 51)
SKIN.Colours.Tree = {}
SKIN.Colours.Tree.Lines = Color(204, 204, 204)
SKIN.Colours.Tree.Normal = SKIN.Colours.Tree.Lines
SKIN.Colours.Tree.Hover = SKIN.Colours.Tree.Lines
SKIN.Colours.Tree.Selected = SKIN.Colours.Tree.Lines
SKIN.colTextEntryText = Color(240, 240, 240)
SKIN.colTextEntryTextPlaceholder = Color(153, 153, 153)

function SKIN:PaintFrame(panel, w, h)
	DisableClipping(true)
	surface.SetDrawColor(0, 0, 0, 90)
	surface.DrawRect(3, 3, w, h)
	DisableClipping(false)
	surface.SetDrawColor(30, 30, 30)
	surface.DrawRect(0, 0, w, h)
	surface.SetDrawColor(51, 51, 51)
	surface.DrawRect(0, 0, w, 24)

	if panel:GetSizable() then
		draw.DrawText("o", "Marlett", w - 15, h - 15, Color(121, 121, 121), TEXT_ALIGN_RIGHT)
	end

	draw.DrawText(panel:GetTitle(), "Trebuchet18", w / 2, 3, Color(204, 204, 204), TEXT_ALIGN_CENTER)
end

function SKIN:PaintButton(panel, w, h)
	if panel.Hovered then
		surface.SetDrawColor(panel.HoveredColor or panel.BackgroundColor or Color(100, 100, 100, 100))
	else
		surface.SetDrawColor(panel.BackgroundColor or Color(0, 0, 0, 0))
	end

	surface.DrawRect(0, 0, w, h)
end

function SKIN:PaintWindowCloseButton(panel, w, h)
	if panel.Hovered then
		surface.SetDrawColor(232, 17, 35)
	else
		surface.SetDrawColor(51, 51, 51)
	end

	surface.DrawRect(0, 0, w, h)
	draw.DrawText("r", "Marlett", w / 2, 5, Color(255, 255, 255), TEXT_ALIGN_CENTER)
end

function SKIN:PaintWindowMaximizeButton(panel, w, h)
	if panel.Hovered then
		surface.SetDrawColor(62, 62, 62)
	else
		surface.SetDrawColor(0, 0, 0, 0)
	end

	surface.DrawRect(0, 0, w, h)
	draw.DrawText(panel:GetParent().Maximized and "2" or "1", "Marlett", w / 2, 5, Color(255, 255, 255, panel:GetAlpha()), TEXT_ALIGN_CENTER)
end

function SKIN:PaintMenu(panel, w, h)
	DisableClipping(true)
	surface.SetDrawColor(0, 0, 0, 90)
	surface.DrawRect(0, 0, w + 2, h + 2)
	DisableClipping(false)
	surface.SetDrawColor(60, 60, 60)
	surface.DrawRect(0, 0, w, h)
end

function SKIN:PaintMenuOption(panel, w, h)
	if panel:GetDisabled() then
		surface.SetDrawColor(Color(0, 0, 0, 100))
		surface.DrawRect(0, 0, w, h)

		return
	end

	if panel.Hovered or panel.Highlight then
		surface.SetDrawColor(4, 57, 94)
		surface.DrawRect(0, 0, w, h)
	end
end

function SKIN:PaintMenuSpacer(panel, w, h)
	surface.SetDrawColor(96, 96, 96)
	surface.DrawLine(4, h / 2, w - 8, h / 2)
end

function SKIN:PaintButtonLeft(panel, w, h)
	local alpha

	if panel.Depressed then
		alpha = 200
	elseif panel.Hovered then
		alpha = 160
	else
		alpha = 100
	end

	surface.SetDrawColor(121, 121, 121, alpha)
	surface.DrawRect(0, 0, w, h)
	draw.DrawText("3", "Marlett", w / 2, 2, Color(100, 100, 100, panel:GetAlpha()), TEXT_ALIGN_CENTER)
end

function SKIN:PaintButtonRight(panel, w, h)
	local alpha

	if panel.Depressed then
		alpha = 200
	elseif panel.Hovered then
		alpha = 160
	else
		alpha = 100
	end

	surface.SetDrawColor(121, 121, 121, alpha)
	surface.DrawRect(0, 0, w, h)
	draw.DrawText("4", "Marlett", w / 2, 1, Color(100, 100, 100, panel:GetAlpha()), TEXT_ALIGN_CENTER)
end

function SKIN:PaintScrollBarGrip(panel, w, h)
	local alpha

	if panel.Depressed then
		alpha = 102
	elseif panel.Hovered then
		alpha = 179
	else
		alpha = 102
	end

	surface.SetDrawColor(121, 121, 121, alpha)
	surface.DrawRect(0, 0, w, h)
end

function SKIN:PaintButtonDown(panel, w, h)
	if not panel.m_bBackground then return end
	local alpha

	if panel.Depressed or panel:IsSelected() then
		alpha = 200
	elseif panel:GetDisabled() then
		alpha = 80
	elseif panel.Hovered then
		alpha = 160
	end

	surface.SetDrawColor(121, 121, 121, alpha)
	surface.DrawRect(0, 0, w, h)
	draw.DrawText("u", "Marlett", w / 2, 2, Color(100, 100, 100, panel:GetAlpha()), TEXT_ALIGN_CENTER)
end

function SKIN:PaintButtonUp(panel, w, h)
	if not panel.m_bBackground then return end
	local alpha

	if panel.Depressed or panel:IsSelected() then
		alpha = 200
	elseif panel:GetDisabled() then
		alpha = 80
	elseif panel.Hovered then
		alpha = 160
	end

	surface.SetDrawColor(121, 121, 121, alpha)
	surface.DrawRect(0, 0, w, h)
	draw.DrawText("t", "Marlett", w / 2, 2, Color(100, 100, 100, panel:GetAlpha()), TEXT_ALIGN_CENTER)
end

function SKIN:PaintExpandButton(panel, w, h)
	if panel:GetExpanded() then
		draw.DrawText("6", "Marlett", w / 2, 2, Color(100, 100, 100, panel:GetAlpha()), TEXT_ALIGN_CENTER)
	else
		draw.DrawText("4", "Marlett", w / 2, 2, Color(100, 100, 100, panel:GetAlpha()), TEXT_ALIGN_CENTER)
	end
end

function SKIN:PaintTreeNode()
end

function SKIN:PaintTextEntry(panel, w, h)
	if panel.m_bBackground then
		surface.SetDrawColor(60, 60, 60)
		surface.DrawRect(0, 0, w, h)
	end

	if panel.GetPlaceholderText and panel.GetPlaceholderColor and panel:GetPlaceholderText() and panel:GetPlaceholderText():Trim() ~= "" and panel:GetPlaceholderColor() and (not panel:GetText() or panel:GetText() == "") then
		local oldText = panel:GetText()
		local str = panel:GetPlaceholderText()

		if (str:StartWith("#")) then
			str = str:sub(2)
		end

		str = language.GetPhrase(str)
		panel:SetText(str)
		panel:DrawTextEntryText(panel:GetPlaceholderColor(), panel:GetHighlightColor(), panel:GetCursorColor())
		panel:SetText(oldText)

		return
	end

	panel:DrawTextEntryText(panel:GetTextColor(), panel:GetHighlightColor(), panel:GetCursorColor())
end

function SKIN:PaintComboBox(panel, w, h)
	if (panel:GetDisabled()) then return self.tex.Input.ComboBox.Disabled(0, 0, w, h) end

	if panel.Depressed or panel:IsMenuOpen() then
		DisableClipping(true)
		surface.SetDrawColor(0, 127, 212)
		surface.DrawRect(-1, -1, w + 2, h + 2)
		DisableClipping(false)
	end

	surface.SetDrawColor(60, 60, 60)
	surface.DrawRect(0, 0, w, h)
end

function SKIN:PaintTooltip(panel, w, h)
	surface.SetDrawColor(37, 37, 38)
	surface.DrawRect(0, 0, w, h)
end

function SKIN:PaintPanel(panel, w, h)
	if panel.m_bBackground then
		surface.SetDrawColor(30, 30, 30)
		surface.DrawRect(0, 0, w, h)
	end
end

function SKIN:PaintShadow(panel, w, h)
	surface.SetDrawColor(0, 0, 0, 90)
	surface.DrawRect(0, 0, w, h)
end

function SKIN:PaintWindowMinimizeButton(panel, w, h)
	if panel.Hovered then
		surface.SetDrawColor(62, 62, 62)
	else
		surface.SetDrawColor(0, 0, 0, 0)
	end

	surface.DrawRect(0, 0, w, h)
	draw.DrawText("0", "Marlett", w / 2, 5, Color(255, 255, 255, panel:GetAlpha()), TEXT_ALIGN_CENTER)
end

function SKIN:PaintTree(panel, w, h)
	surface.SetDrawColor(30, 30, 30)
	surface.DrawRect(0, 0, w, h)
end

function SKIN:PaintTreeNodeButton(panel, w, h)
	local node = panel:GetParent()
	local expanded = node and node.GetExpanded and node:GetExpanded()
	if expanded then
		draw.DrawText("6", "Marlett", w / 2, h / 2 - 4, Color(187, 187, 187, panel:GetAlpha()), TEXT_ALIGN_CENTER)
	else
		draw.DrawText("4", "Marlett", w / 2, h / 2 - 4, Color(187, 187, 187, panel:GetAlpha()), TEXT_ALIGN_CENTER)
	end
end

function SKIN:PaintCheckBox(panel, w, h)
	surface.SetDrawColor(60, 60, 60)
	surface.DrawRect(0, 0, w, h)

	if panel:GetChecked() then
		draw.DrawText("a", "Marlett", w / 2, 1, Color(204, 204, 204), TEXT_ALIGN_CENTER)
	end
end

function SKIN:PaintRadioButton(panel, w, h)
	surface.SetDrawColor(60, 60, 60)
	surface.DrawRect(0, 0, w, h)

	if panel:GetChecked() then
		draw.DrawText("i", "Marlett", w / 2, 1, Color(204, 204, 204), TEXT_ALIGN_CENTER)
	end
end

function SKIN:PaintVScrollBar(panel, w, h)
	surface.SetDrawColor(30, 30, 30)
	surface.DrawRect(0, 0, w, h)
end

function SKIN:PaintHScrollBar(panel, w, h)
	surface.SetDrawColor(30, 30, 30)
	surface.DrawRect(0, 0, w, h)
end

function SKIN:PaintComboDownArrow(panel, w, h)
	draw.DrawText("u", "Marlett", w / 2, h / 2 - 4, Color(204, 204, 204, panel:GetAlpha()), TEXT_ALIGN_CENTER)
end

function SKIN:PaintMenuRightArrow(panel, w, h)
	draw.DrawText("4", "Marlett", w / 2, h / 2 - 4, Color(204, 204, 204, panel:GetAlpha()), TEXT_ALIGN_CENTER)
end

function SKIN:PaintListBox(panel, w, h)
	surface.SetDrawColor(30, 30, 30)
	surface.DrawRect(0, 0, w, h)
	surface.SetDrawColor(55, 55, 61)
	surface.DrawOutlinedRect(0, 0, w, h)
end

function SKIN:PaintListView(panel, w, h)
	surface.SetDrawColor(30, 30, 30)
	surface.DrawRect(0, 0, w, h)
	surface.SetDrawColor(55, 55, 61)
	surface.DrawOutlinedRect(0, 0, w, h)
end

function SKIN:PaintListViewLine(panel, w, h)
	if panel:IsSelected() then
		surface.SetDrawColor(4, 57, 94)
		surface.DrawRect(0, 0, w, h)
	elseif panel.Hovered then
		surface.SetDrawColor(42, 45, 46)
		surface.DrawRect(0, 0, w, h)
	elseif panel:GetAltLine() then
		surface.SetDrawColor(35, 35, 35)
		surface.DrawRect(0, 0, w, h)
	else
		surface.SetDrawColor(30, 30, 30)
		surface.DrawRect(0, 0, w, h)
	end
end

function SKIN:PaintSelection(panel, w, h)
	surface.SetDrawColor(4, 57, 94)
	surface.DrawRect(0, 0, w, h)
end

function SKIN:PaintPropertySheet(panel, w, h)
	surface.SetDrawColor(30, 30, 30)
	surface.DrawRect(0, 0, w, h)
end

function SKIN:PaintTab(panel, w, h)
	if panel.Hovered then
		surface.SetDrawColor(42, 45, 46)
	else
		surface.SetDrawColor(37, 37, 38)
	end

	surface.DrawRect(0, 0, w, h)
end

function SKIN:PaintActiveTab(panel, w, h)
	surface.SetDrawColor(30, 30, 30)
	surface.DrawRect(0, 0, w, h)
	surface.SetDrawColor(0, 127, 212)
	surface.DrawRect(0, h - 2, w, 2)
end

function SKIN:PaintProgress(panel, w, h)
	surface.SetDrawColor(37, 37, 38)
	surface.DrawRect(0, 0, w, h)
	surface.SetDrawColor(14, 112, 192)
	surface.DrawRect(1, 1, (w - 2) * panel:GetFraction(), h - 2)
end

function SKIN:PaintNumSlider(panel, w, h)
end

function SKIN:PaintSliderKnob(panel, w, h)
	local alpha

	if panel.Depressed then
		alpha = 200
	elseif panel.Hovered then
		alpha = 160
	else
		alpha = 100
	end

	surface.SetDrawColor(121, 121, 121, alpha)
	surface.DrawRect(0, 0, w, h)
end

function SKIN:PaintNumberUp(panel, w, h)
	local alpha

	if panel.Depressed then
		alpha = 200
	elseif panel.Hovered then
		alpha = 160
	else
		alpha = 100
	end

	surface.SetDrawColor(121, 121, 121, alpha)
	surface.DrawRect(0, 0, w, h)
	draw.DrawText("5", "Marlett", w / 2, 2, Color(100, 100, 100, panel:GetAlpha()), TEXT_ALIGN_CENTER)
end

function SKIN:PaintNumberDown(panel, w, h)
	local alpha

	if panel.Depressed then
		alpha = 200
	elseif panel.Hovered then
		alpha = 160
	else
		alpha = 100
	end

	surface.SetDrawColor(121, 121, 121, alpha)
	surface.DrawRect(0, 0, w, h)
	draw.DrawText("6", "Marlett", w / 2, 2, Color(100, 100, 100, panel:GetAlpha()), TEXT_ALIGN_CENTER)
end

function SKIN:PaintCollapsibleCategory(panel, w, h)
	surface.SetDrawColor(37, 37, 38)
	surface.DrawRect(0, 0, w, h)
end

function SKIN:PaintCategoryList(panel, w, h)
	surface.SetDrawColor(30, 30, 30)
	surface.DrawRect(0, 0, w, h)
end

function SKIN:PaintCategoryButton(panel, w, h)
	if panel.AltLine then
		surface.SetDrawColor(35, 35, 35)
		surface.DrawRect(0, 0, w, h)
	end

	if panel.Hovered then
		surface.SetDrawColor(42, 45, 46)
		surface.DrawRect(0, 0, w, h)
	end
end

function SKIN:PaintMenuBar(panel, w, h)
	surface.SetDrawColor(51, 51, 51)
	surface.DrawRect(0, 0, w, h)
end

derma.DefineSkin("Noir", "Noir editor skin", SKIN)