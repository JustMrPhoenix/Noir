local PANEL = {}
-- Since gmod does not allow you to open localhost urls im using totallynotme.hack that points to 127.0.0.1
PANEL.URL = Noir.DEBUG and "http://totallynotme.hacks:8080" or "https://metastruct.github.io/gmod-monaco/"
PANEL.SHOULD_VALIDATE = true
PANEL.VALIDATE_COOLDOWN = 0.5
-- Totally hacky way to rebind command palette to Ctrl+Shift+P like in vs-code
PANEL.CUSTOM_JS = [[console.debug("Commiting keybind HACKS")
let keybind = editor._standaloneKeybindingService._getResolver()._lookupMap.get("editor.action.quickCommand")[0].resolvedKeybinding._parts[0]
keybind.ctrlKey = true;
keybind.shiftKey = true;
keybind.keyCode = monaco.KeyCode.KEY_P;
editor._standaloneKeybindingService.updateResolver();
gmodinterface.OnLanguages(monaco.languages.getLanguages());]]

local function addColumn(listView, name)
    local column = listView:AddColumn(name)
    column.Header.BackgroundColor = Color(40, 40, 40)
    column.Header.HoveredColor = Color(70, 70, 70)

    return column
end

function PANEL:Init()
    self:SetCookieName("NoirLuaEditor")
    self.HTMLPanel = self:Add("DHTML")
    self.HTMLPanel:Dock(FILL)
    self:SetupHTML()

    self.ErrorList = self:Add("DListView")
    self.ErrorList:Dock(BOTTOM)
    self.ErrorList:SetPaintBackground(false)
    self.ErrorList:SetMultiSelect(false)
    self.ErrorList:SetVisible(false)
    self.ErrorList:SetTall(0)
    local icon_column = addColumn(self.ErrorList, "")
    icon_column:SetMinWidth(16)
    icon_column:SetWidth(16)
    icon_column:SetMaxWidth(16)
    addColumn(self.ErrorList, "Message")
    addColumn(self.ErrorList, "Code"):SetMaxWidth(40)
    addColumn(self.ErrorList, "Line"):SetMaxWidth(25)

    self.ErrorList.DoDoubleClick = function(_, _, line)
        if not line.event then return end
        self:RunJS("gmodinterface.GotoLine(%s)", line.event.line)
    end

    self.StatusButton = self:Add("DButton")
    self.StatusButton:SetSkin("Noir")
    self.StatusButton:Dock(BOTTOM)
    self.StatusButton:SetHeight(20)
    self.StatusButton:SetColor(Color(255, 255, 255))
    self:SetStatus("Loading (Press here to reload)")

    self.StatusButton.DoClick = function()
        self.HTMLPanel:StopLoading()
        self:SetStatus("Loading (Press here to reload)")
        self:SetupHTML()
    end

    self.Language = "glua"
    self.LanguageData = {}
    self.Code = ""
    self.LastEdit = CurTime()
    self.LastValidated = CurTime()
    self.Actions = {}
    self.LastReportEvents = {}
    self.Ready = false
end

function PANEL:RequestFocus()
    self.HTMLPanel:RequestFocus()
end

function PANEL:SetStatus(text, color, prependTime)
    self.StatusButton:SetText((prependTime and Format("[%s] ", os.date("%H:%M:%S")) or "") .. text)
    self.StatusButton.BackgroundColor = color or self.StatusButton.BackgroundColor
end

function PANEL:RunJS(code, ...)
    local js = Format(code, ...)
    -- Noir.Debug("RunJS", js)
    self.HTMLPanel:RunJavascript(js)
end

function PANEL:ValidateCode()
    self.LastValidated = CurTime()
    if self.Code == "" then
        self:SubmitLuaReport({})
        self:SetStatus("Validated", Color(0, 150, 0))
        return
    end

    if self.Language ~= "glua" then
        self:SubmitLuaReport({})
        local langName = self.Language

        if self.LanguageData.aliases and #self.LanguageData.aliases then
            langName = self.LanguageData.aliases[1]
        end

        self:SetStatus(("No validation (%s)"):format(langName), Color(0, 150, 0), true)
        return
    end

    if not luacheck then
        self:SetStatus("No validation: luacheck not found", Color(0, 150, 0), true)
        return
    end

    local succ, ret = pcall(function()
        local report = luacheck.get_report(self.Code)
        return luacheck.filter.filter({ report })
    end)
    local events = succ and ret[1] or {}
    if self.OnValidation then
        self:OnValidation(succ, events)
    end
    Noir.Debug("Validation", succ, events)
    if succ and #events > 0 then
        if #events == 1 and tostring(events[1].code)[1] == "0" then
            self:SetStatus(Format("Error: %s at line %s", events[1].msg, events[1].line), Color(150, 0, 0), true)
        elseif #events > 0 then
            self:SetStatus(Format("Has %i issue(s)", #events), Color(204, 167, 0), true)
        end
    elseif succ and #events == 0 then
        self:SetStatus("Validated. No issues", Color(0, 150, 0), true)
    end
    if succ then
        local luaReportEvents = {}
        self.ErrorList:Clear()
        self.ErrorList:ClearSelection()
        for _, event in pairs(events) do
            local code = tostring(event.code)
            local isError = code[1] == "0"
            local message = luacheck.get_message(event)
            local reportEvent =  {
                message = message,
                isError = isError,
                line = event.line,
                startColumn = event.column,
                endColumn = event.end_column,
                luacheckCode = code,
            }
            table.insert(luaReportEvents, reportEvent)
            -- icon16/cancel.png or icon16/error.png
            local icon = vgui.Create("DImage", self.ErrorList)
            icon:SetImage(isError and "icon16/cancel.png" or "icon16/error.png")
            local line = self.ErrorList:AddLine(icon, message, code, event.line)
            line.event = reportEvent
        end
        self:SubmitLuaReport(luaReportEvents)
    else
        self:SubmitLuaReport({})
    end
end

function PANEL:SubmitLuaReport(events)
    self.LastReportEvents = events
    self:RunJS([[gmodinterface.SubmitLuaReport(%s)]], util.TableToJSON({events = events}))
end

function PANEL:AddLuaError(msg, errorLine)
    local icon = vgui.Create("DImage", self.ErrorList)
    icon:SetImage("icon16/cancel.png")
    local line = self.ErrorList:AddLine(icon, msg, "", errorLine)
    local reportEvent = {
        message = msg,
        isError = true,
        line = tonumber(errorLine),
        startColumn = 0,
        endColumn = 100,
        luacheckCode = "000"
    }
    line.event = reportEvent
    Noir.Debug("AddLuaError", reportEvent, line, msg)
    table.insert(self.LastReportEvents, reportEvent)
    self:SubmitLuaReport(self.LastReportEvents)
end

function PANEL:ToggleErrorList()
    local isVisible = not self.ErrorList:IsVisible()
    self.ErrorList:SetVisible(isVisible)
    self.ErrorList:SetTall(isVisible and 100 or 0)
    self:InvalidateLayout()
end

function PANEL:JS_OnReady()
    self:RunJS(Noir.Autocomplete.GetJS())
    self:RunJS(self.CUSTOM_JS)
    self:SetStatus("Ready", Color(0, 150, 0))
    self.Ready = true
    self.StatusButton.DoClick = function()
        self:ToggleErrorList()
    end

    if self.OnReady then
        self:OnReady()
    end
end

function PANEL:JS_OnCode(code)
    self.Code = code
    self.LastEdit = CurTime()

    if self.OnCode then
        self:OnCode(code)
    end
end

function PANEL:Think()
    -- Wait for user to stop editing and then validate
    if self.SHOULD_VALIDATE and self.LastEdit + self.VALIDATE_COOLDOWN < CurTime() and self.LastValidated < self.LastEdit then
        self:ValidateCode()
    end
end

function PANEL:OnLog(...)
    Noir.Msg("[", Color(0, 0, 150), "Editor", Color(255, 255, 255), "] ", ..., "\n")
end

function PANEL:AddJSCallback(name)
    self.HTMLPanel:AddFunction("gmodinterface", name, function(...)
        Noir.Debug("JS Callback: " .. name, ...)
        self["JS_" .. name](self, ...)
    end)
end

function PANEL:AddAction(id, label, callback, keyBindings)
    self.Actions[id] = callback

    if isstring(keyBindings) then
        keyBindings = {keyBindings}
    end

    self:RunJS([[gmodinterface.AddAction(%s)]], util.TableToJSON({
        id = id,
        label = label,
        keyBindings = keyBindings
    }))
end

function PANEL:JS_OnAction(id)
    if self.OnAction then
        self:OnAction(id)
    end

    self.Actions[id](self, id)
end

function PANEL:SetCode(code, keepViewState)
    keepViewState = keepViewState or false
    self:RunJS([[gmodinterface.SetCode("%s", %s)]], code:JavascriptSafe(), keepViewState)
end

function PANEL:SetSessionCode(sessionName, code)
    self:RunJS([[gmodinterface.SetSessionCode("%s", "%s")]], sessionName:JavascriptSafe(), code)
end

function PANEL:AddSnippet(name, code)
    self:RunJS([[gmodinterface.AddSnippet("%s","%s")]], name:JavascriptSafe(), code:JavascriptSafe())
end

function PANEL:RenameSession(newName, oldName)
    oldName = oldName or ""
    self:RunJS([[gmodinterface.RenameSession("%s","%s")]], newName:JavascriptSafe(), oldName:JavascriptSafe())
end

function PANEL:SetSession(sessionName)
    self:RunJS([[gmodinterface.SetSession("%s")]], sessionName:JavascriptSafe())
end

function PANEL:CreateSession(session)
    self:RunJS([[gmodinterface.CreateSession(%s)]], util.TableToJSON(session))
end

function PANEL:CloseSession(sessionName, switchTo)
    switchTo = switchTo or ""
    self:RunJS([[gmodinterface.CloseSession("%s","%s")]], sessionName:JavascriptSafe(), switchTo:JavascriptSafe())
end

function PANEL:LoadSessions(sessions, newActive)
    newActive = newActive or ""
    self:RunJS([[gmodinterface.LoadSessions(%s,"%s")]], util.TableToJSON(sessions), newActive:JavascriptSafe())
end

-- PLEASE NOTE: This function DOES NOT return sessions
function PANEL:GetSessions()
    self:RunJS([[gmodinterface.GetSessions()]])
end

function PANEL:JS_OnSessions(sessions)
    if self.OnSessions then
        self:OnSessions(sessions)
    end
end

function PANEL:JS_OnSessionSet(session)
    self.Language = session.language

    if self.avaliableLaungages then
        for _, v in pairs(self.avaliableLaungages) do
            if v.id == session.language then
                self.LanguageData = v
            end
        end
    end

    if self.OnSessionSet then
        self:OnSessionSet(session)
    end

    self:JS_OnCode(session.code)
end

function PANEL:JS_OnLanguages(languages)
    self.avaliableLaungages = languages
end

function PANEL:SetAlpha(alpha)
    if not self.Ready then return end
    alpha = alpha / 255
    self:RunJS([[document.getElementsByTagName("body")[0].style.opacity = %f]], alpha)
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
        if self.OnOpenURL then
            self:OnOpenURL(url)
        else
            gui.OpenURL(url)
        end
    end)

    self:AddJSCallback("OnCode")
    self:AddJSCallback("OnAction")
    self:AddJSCallback("OnSessions")
    self:AddJSCallback("OnSessionSet")
    self:AddJSCallback("OnLanguages")
end

vgui.Register("NoirMonacoEditor", PANEL, "EditablePanel")