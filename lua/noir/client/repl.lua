local PANEL = {}

PANEL.Base = "EditablePanel"

PANEL.URL = "https://justmrphoenix.github.io/gmod-monaco/repl"

function PANEL:Init()
    local html = self:Add("DHTML")
    html:Dock(FILL)
    html:DockMargin(0, 0, 0, 0)
    self.HTMLPanel = html
    self:SetupHTML()
    local statusButton = self:Add("DButton")
    statusButton:SetSkin("Noir")
    statusButton:DockMargin(150, 0, 15, 0)
    statusButton:Dock(BOTTOM)
    statusButton:SetHeight(20)
    statusButton:SetColor(Color(255, 255, 255))
    self.StatusButton = statusButton
    self:SetStatus("Loading (Press here to reload)")
    statusButton.DoClick = function()
        self.HTMLPanel:StopLoading()
        self:SetStatus("Loading (Press here to reload)")
        self:SetupHTML()
    end

    local comboBox = self:Add("DComboBox")
    comboBox:SetSkin("Noir")
    comboBox:SetTextInset( 32, 0 )
    comboBox:SetText("Run on self")
    comboBox:SetIcon("icon16/user.png")
    comboBox:SetSize(150, 20)
    comboBox.m_Image:SetPos(4, 2)

    self.TargetCombobox = comboBox
    comboBox.OpenMenu = function(_, pControlOpener)
        if IsValid( comboBox.Menu ) then
            comboBox.Menu:Remove()
            comboBox.Menu = nil
        end
        self:FillMenu()
        local x, y = comboBox:LocalToScreen( 0, comboBox:GetTall() )
        comboBox.Menu:SetMinimumWidth( comboBox:GetWide() )
        comboBox.Menu:Open( x, y, false, comboBox )
    end

    self:RequestFocus()
    self.Target = "self"
    self.ReplCounter = 0
end

function PANEL:OnSizeChanged(newWidth, newHeight)
    self.TargetCombobox:SetPos(0, newHeight - 20)
end

function PANEL:FillMenu()
    local runMenu = DermaMenu(false, self.TargetCombobox)
    runMenu:SetSkin("Noir")
    runMenu:SetDeleteSelf(false)
    runMenu:SetDrawColumn(true)
    runMenu:Hide()
    self.RunMenu = runMenu
    self.TargetCombobox.Menu = runMenu

    self:AddRunOption("Run on self", "self", "icon16/user.png")
    self:AddRunOption("Run on server", "server", "icon16/server.png")

    local runOnSubmenu, runOnMenu = runMenu:AddSubMenu("Run on client")
    runOnMenu:SetIcon("icon16/user_go.png")
    runOnMenu:SetTextColor(Color(200, 200, 200))
    runOnSubmenu:SetDeleteSelf(false)
    runOnSubmenu:SetSkin("Noir")
    self.RunOnSubmenu = runOnSubmenu

    for _, v in pairs(player.GetHumans()) do
        self:AddRunOption(v:Nick(), v, v:IsSuperAdmin() and "icon16/user_suit.png" or "icon16/user.png", runOnSubmenu)
    end

    self:AddRunOption("Run on clients", "clients", "icon16/group.png")
    self:AddRunOption("Run on shared", "shared", "icon16/world.png")
end

function PANEL:AddRunOption(label, target, icon, menu)
    menu = menu or self.RunMenu
    local option = menu:AddOption(label, function()
        self.TargetCombobox:SetIcon(icon)
        self.TargetCombobox:SetText(label)
        self.Target = target
    end)

    -- gmodinterface.LoadAutocompleteState("client")

    option:SetIcon(icon)
    option:SetTextColor(Color(200, 200, 200))
end

function PANEL:UpdateRunOnSubmenu()
    self.RunOnSubmenu:Clear()
    for _, v in pairs(player.GetHumans()) do
        self:AddRunOption(v:Nick(), v, v:IsSuperAdmin() and "icon16/user_suit.png" or "icon16/user.png", runOnSubmenu)
    end
end

function PANEL:RequestFocus()
    self.HTMLPanel:RequestFocus()
end

function PANEL:SetStatus(text, color, prependTime)
    self.StatusButton:SetText((prependTime and string.format("[%s] ", os.date("%H:%M:%S")) or "") .. text)
    self.StatusButton.BackgroundColor = color or self.StatusButton.BackgroundColor
end

function PANEL:SetAlpha(alpha)
    if not self.Ready then return end
    alpha = alpha / 255
    self:RunJS([[document.getElementsByTagName("body")[0].style.opacity = %f]], alpha)
end

function PANEL:RunJS(code, ...)
    local js = string.format(code, ...)
    Noir.Debug("RunJS", js)
    self.HTMLPanel:RunJavascript(js)
end

function PANEL:AddJSCallback(name)
    self.HTMLPanel:AddFunction("gmodinterface", name, function(...)
        self["JS_" .. name](self, ...)
    end)
end

function PANEL:OnLog(...)
    Noir.Msg("[", Color(0, 0, 150), "Editor", Color(255, 255, 255), "] ", ..., "\n")
end

function PANEL:JS_OnCode(code)
    self.Code = code
    self.LastEdit = CurTime()

    if self.OnCode then
        self:OnCode(code)
    end
end

function PANEL:JS_OnReady(avaliableLaungages)
    self:RunJS(Noir.Autocomplete.GetJS())
    self:RunJS("gmodinterface.LoadAutocompleteState(\"client\")")
    self:SetStatus("Ready", Color(0, 150, 0))
    self.avaliableLaungages = avaliableLaungages
    self.Ready = true

    self.StatusButton.DoClick = function() end

    if self.OnReady then
        self:OnReady()
    end
end

function PANEL:OnCode(code)
    local returnCode = "return " .. code
    local returnCompile = CompileString(returnCode, "Noir.replValidation", false)
    if isfunction(returnCompile) then
        code = returnCode
    end

    local targets
    if self.Target == "clients" then
        targets = #player.GetHumans()
    elseif self.Target == "shared" then
        targets = #player.GetHumans() + 1
    else
        targets = 1
    end
    local identifier = "Noir.repl" .. self.ReplCounter
    local id = Noir.GenerateTransferId()
    self.ReplCounter = self.ReplCounter + 1
    if not id then
        Editor.MonacoPanel:SetStatus("Could not send code! See console for details", Color(150, 0, 0))
        return
    end
    local totalRan = 0
    local hasError = false
    Noir.Environment.RegisterHandler(function(sender, transferId, _, data)
        totalRan = totalRan + 1
        local done, returns = unpack(data)
        local senderName = sender == Entity(0) and "SERVER" or tostring(sender)
        if not done then
            hasError = true
            local msg = Noir.Utils.ParseLuaError(returns, identifier)
            if CLIENT and sender == LocalPlayer() then
                self:SetStatus(string.format("Error:%s", msg), Color(150, 0, 0), true)
            else
                Editor.MonacoPanel:SetStatus(string.format("[%s] Error:%s", senderName, msg), Color(150, 0, 0), true)
            end
        elseif not hasError then
            if targets ~= 1 then
                self:SetStatus(string.format("[%i/%i] Ran on %s successfully",  totalRan, targets, senderName), Color(0, 150, 0), true)
            else
                self:SetStatus(string.format("Ran on %s successfully", senderName), Color(0, 150, 0), true)
            end
        end
    end, id, "run")
    Noir.Environment.RegisterHandler(function(...)
        local succ, err = pcall( self.OnMessage, self, self.Target, identifier, ...)
        if not succ then
            self:AddText(string.format("--[[%s: Could not display output]] %s", identifier, err))
        end
    end , id)
    Noir.SendCode(code, identifier, self.Target, id)
end

function PANEL:OnMessage(target, replName, sender, transferId, message, data)
    if message == "run" then
        if data[1] ~= true then
            message = "ERROR"
            data = {data[2]}
        else
            message = "return"
            data = data[2]
            if #data == 0 then return end
        end
    end
    if data.args then
        data = data.args
    end
    local text = ""
    if #data == 1 then
        local str = istable(data[1]) and table.ToString(data[1], nil, true) or tostring(data[1])
        if string.find(str, "\n") then
            str = "\n" .. str
        end
        text = str
    else
        for k, v in pairs(data) do
            text = text .. "\n"
            local str = istable(v) and table.ToString(v, tostring(v), true) or tostring(v)
            if string.find(str, "\n") then
                str = "\n" .. str
            end
            text = text .. string.format("-- %s : %s", k, str)
        end
    end
    if message == "run" and data[1] == true then
        self:AddText(text)
    elseif target == "shared" or target == "clients" then
        local senderName = sender == Entity(0) and "SERVER" or tostring(sender)
        self:AddText(string.format("--[[%-13s: %s : %s]] %s", replName, senderName, message, text))
    else
        self:AddText(string.format("--[[%-13s: %s]] %s", replName, message, text))
    end
end

function PANEL:AddText(text)
    self:RunJS("gmodinterface.AddText(\"%s\")", text:JavascriptSafe())
end

function PANEL:SetupHTML()
    self.HTMLPanel:OpenURL(self.URL)
    self:AddJSCallback("OnReady")

    self.HTMLPanel:AddFunction("console", "log", function(...)
        Noir.Debug("console.log", ...)
        self:OnLog(...)
    end)

    self.HTMLPanel:AddFunction("console", "warn", function(...)
        Noir.Debug("console.warn", ...)
        self:OnLog(...)
    end)

    self.HTMLPanel:AddFunction("console", "debug", function(...)
        Noir.Debug("console.debug", ...)
    end)

    self.HTMLPanel:AddFunction("console", "error", function(...)
        Noir.Error("[", Color(0, 0, 150), "Editor", Color(255, 255, 255), "] ", ..., "\n")
    end)

    self.HTMLPanel:AddFunction("gmodinterface","OpenURL", function(url)
        Noir.Debug("OpenURL", url)
        gui.OpenURL(url)
    end)

    self:AddJSCallback("OnCode")
end

function Noir.CreateRepl()
    local frame = vgui.Create("DFrame")
    Noir.ReplFrame = frame
    frame:SetSkin("Noir")
    frame:SetSize(700, 700)
    frame:SetTitle("[Noir console]")
    frame:Center()
    frame:MakePopup()
    frame:SetDraggable( true )
    frame:ShowCloseButton( true )
    frame:SetSizable( true )
    frame.btnMinim:SetVisible(false)
    frame.btnMaxim:SetVisible(false)
    frame:SetDeleteOnClose(false)

    local repl = vgui.CreateFromTable(PANEL, frame)
    frame.Repl = repl
    repl:DockMargin(-4, -4, -4, -4)
    repl:Dock(FILL)
    repl:SetCursor("sizenwse")

    repl.OnMousePressed = function(_, ...)
        if frame.Maximized then return end
        frame:OnMousePressed(...)
    end

    repl.OnMouseReleased = function(_, ...)
        if frame.Maximized then return end
        frame:OnMouseReleased(...)
    end
end

function Noir.ShowRepl()
    if IsValid(Noir.ReplFrame) then
        Noir.ReplFrame:Show()

        return
    end

    Noir.CreateRepl()
end

concommand.Add("noir_showrepl", function(ply, cmd, args)
    Noir.ShowRepl()
end)
