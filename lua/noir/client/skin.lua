local SKIN = {}
SKIN.PrintName = "Noir editor skin"
SKIN.Author = "Uhh... me?"
SKIN.Colours = {}
SKIN.Colours.Button = {}
SKIN.Colours.Button.Normal = Color(200, 200, 200)
SKIN.Colours.Button.Disabled = Color(100, 100, 100)
SKIN.Colours.Button.Hover = SKIN.Colours.Button.Normal
SKIN.Colours.Button.Down = SKIN.Colours.Button.Normal
SKIN.Colours.Label = {}
SKIN.Colours.Label.Bright = Color(30, 30, 30) -- Bright and dark are inverted here
SKIN.Colours.Label.Dark = Color(200, 200, 200)
SKIN.Colours.Label.Highlight = Color(255, 0, 0)
SKIN.Colours.Window = {}
SKIN.Colours.Window.TitleActive = Color(62, 62, 62)
SKIN.Colours.Window.TitleInactive = Color(62, 62, 62)
SKIN.Colours.Tree = {}
SKIN.Colours.Tree.Lines = Color(255, 255, 255)
SKIN.Colours.Tree.Normal = SKIN.Colours.Tree.Lines
SKIN.Colours.Tree.Hover = SKIN.Colours.Tree.Lines
SKIN.Colours.Tree.Selected = SKIN.Colours.Tree.Lines
SKIN.colTextEntryText = Color(250, 250, 250)
SKIN.colTextEntryTextPlaceholder = Color(180, 180, 180)

function SKIN:PaintFrame(panel, w, h)
    DisableClipping(true)
    surface.SetDrawColor(10, 10, 10, 100)
    surface.DrawRect(3, 3, w, h)
    DisableClipping(false)
    surface.SetDrawColor(42, 42, 42)
    surface.DrawRect(0, 0, w, h)
    surface.SetDrawColor(62, 62, 62)
    surface.DrawRect(0, 0, w, 24)

    if panel:GetSizable() then
        draw.DrawText("o", "Marlett", w - 15, h - 15, Color(100, 100, 100), TEXTA_LIGN_RIGHT)
    end

    draw.DrawText(panel:GetTitle(), "Trebuchet18", w / 2, 3, Color(200, 200, 200), TEXT_ALIGN_CENTER)
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
        surface.SetDrawColor(215, 20, 40)
    else
        surface.SetDrawColor(62, 62, 62)
    end

    surface.DrawRect(0, 0, w, h)
    draw.DrawText("r", "Marlett", w / 2, 5, Color(255, 255, 255), TEXT_ALIGN_CENTER)
end

function SKIN:PaintWindowMaximizeButton(panel, w, h)
    if panel.Hovered then
        surface.SetDrawColor(100, 100, 100, 100)
    else
        surface.SetDrawColor(0, 0, 0, 0)
    end

    surface.DrawRect(0, 0, w, h)
    draw.DrawText(panel:GetParent().Maximized and "2" or "1", "Marlett", w / 2, 5, Color(255, 255, 255, panel:GetAlpha()), TEXT_ALIGN_CENTER)
end

function SKIN:PaintMenu(panel, w, h)
    DisableClipping(true)
    surface.SetDrawColor(10, 10, 10, 100)
    surface.DrawRect(0, 0, w + 2, h + 2)
    DisableClipping(false)
    surface.SetDrawColor(42, 42, 42)
    surface.DrawRect(0, 0, w, h)
end

function SKIN:PaintMenuOption(panel, w, h)
    if panel:GetDisabled() then
        surface.SetDrawColor(Color(0, 0, 0, 100))
        surface.DrawRect(0, 0, w, h)

        return
    end

    if panel.Hovered or panel.Highlight then
        surface.SetDrawColor(17, 73, 113)
        surface.DrawRect(0, 0, w, h)
    end
end

function SKIN:PaintMenuSpacer(panel, w, h)
    surface.SetDrawColor(97, 97, 98)
    surface.DrawLine(4, h / 2, w - 8, h / 2)
end

function SKIN:PaintButtonLeft(panel, w, h)
    local alpha

    if panel.Depressed then
        alpha = 250
    elseif panel.Hovered then
        alpha = 200
    else
        alpha = 150
    end

    surface.SetDrawColor(150, 150, 150, alpha)
    surface.DrawRect(0, 0, w, h)
    draw.DrawText("w", "Marlett", w / 2, 2, Color(80, 80, 80, panel:GetAlpha()), TEXT_ALIGN_CENTER)
end

function SKIN:PaintButtonRight(panel, w, h)
    local alpha

    if panel.Depressed then
        alpha = 250
    elseif panel.Hovered then
        alpha = 200
    else
        alpha = 150
    end

    surface.SetDrawColor(150, 150, 150, alpha)
    surface.DrawRect(0, 0, w, h)
    draw.DrawText("8", "Marlett", w / 2, 1, Color(80, 80, 80, panel:GetAlpha()), TEXT_ALIGN_CENTER)
end

function SKIN:PaintScrollBarGrip(panel, w, h)
    local alpha

    if panel.Depressed then
        alpha = 250
    elseif panel.Hovered then
        alpha = 200
    else
        alpha = 150
    end

    surface.SetDrawColor(150, 150, 150, alpha)
    surface.DrawRect(0, 0, w, h)
end

function SKIN:PaintButtonDown(panel, w, h)
    if not panel.m_bBackground then return end
    local alpha

    if panel.Depressed or panel:IsSelected() then
        alpha = 250
    elseif panel:GetDisabled() then
        alpha = 100
    elseif panel.Hovered then
        alpha = 180
    end

    surface.SetDrawColor(150, 150, 150, alpha)
    surface.DrawRect(0, 0, w, h)
    draw.DrawText("u", "Marlett", w / 2, 2, Color(80, 80, 80, panel:GetAlpha()), TEXT_ALIGN_CENTER)
end

function SKIN:PaintButtonUp(panel, w, h)
    if not panel.m_bBackground then return end
    local alpha

    if panel.Depressed or panel:IsSelected() then
        alpha = 250
    elseif panel:GetDisabled() then
        alpha = 100
    elseif panel.Hovered then
        alpha = 180
    end

    surface.SetDrawColor(150, 150, 150, alpha)
    surface.DrawRect(0, 0, w, h)
    draw.DrawText("t", "Marlett", w / 2, 2, Color(80, 80, 80, panel:GetAlpha()), TEXT_ALIGN_CENTER)
end

function SKIN:PaintExpandButton(panel, w, h)
    if panel:GetExpanded() then
        draw.DrawText("6", "Marlett", w / 2, 2, Color(80, 80, 80, panel:GetAlpha()), TEXT_ALIGN_CENTER)
    else
        draw.DrawText("8", "Marlett", w / 2, 2, Color(80, 80, 80, panel:GetAlpha()), TEXT_ALIGN_CENTER)
    end
end

function SKIN:PaintTreeNode()
end

function SKIN:PaintTextEntry(panel, w, h)
    if panel.m_bBackground then
        surface.SetDrawColor(63, 63, 63)
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
        surface.SetDrawColor(23, 91, 137)
        surface.DrawRect(-1, -1, w + 2, h + 2)
        DisableClipping(false)
    end

    surface.SetDrawColor(63, 63, 63)
    surface.DrawRect(0, 0, w, h)
end

function SKIN:PaintTooltip( panel, w, h )
    surface.SetDrawColor(63, 63, 63)
    surface.DrawRect(0, 0, w, h)
end

derma.DefineSkin("Noir", "Noir editor skin", SKIN)