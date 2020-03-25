local PANEL = {}
-- Since gmod does not allow you to open localhost urls im using totallynotme.hack that points to 127.0.0.1
PANEL.URL = Noir.DEBUG and "http://totallynotme.hacks:8080" or "https://justmrphoenix.github.io/gmod-monaco"
PANEL.SHOULD_VALIDATE = true
PANEL.VALIDATION_COMPILE = "NoirEditorValidation"
PANEL.VALIDATE_COOLDOWN = 0.5
-- Totally hacky way to rebind command palette to Ctrl+Shift+P like in vs-code
PANEL.CUSTOM_JS = [[console.debug("Commiting keybind HACKS")
let keybind = editor._standaloneKeybindingService._getResolver()._lookupMap.get("editor.action.quickCommand")[0].resolvedKeybinding._parts[0]
keybind.ctrlKey = true;
keybind.shiftKey = true;
keybind.keyCode = monaco.KeyCode.KEY_P;
editor._standaloneKeybindingService.updateResolver();]]

function PANEL:Init()
    self:SetCookieName("NoirLuaEditor")
    self.HTMLPanel = self:Add("DHTML")
    self.HTMLPanel:Dock(FILL)
    self:SetupHTML()
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
    self.Ready = false
end

function PANEL:RequestFocus()
    self.HTMLPanel:RequestFocus()
end

function PANEL:SetStatus(text, color, prependTime)
    self.StatusButton:SetText((prependTime and string.format("[%s] ", os.date("%H:%M:%S")) or "") .. text)
    self.StatusButton.BackgroundColor = color or self.StatusButton.BackgroundColor
end

function PANEL:RunJS(code, ...)
    local js = string.format(code, ...)
    -- Noir.Debug("RunJS", js)
    self.HTMLPanel:RunJavascript(js)
end

function PANEL:ValidateCode()
    self.LastValidated = CurTime()

    if self.Code == "" then
        self:RunJS("gmodinterface.ClearError()")
        self:SetStatus("Validated", Color(0, 150, 0))

        self.StatusButton.DoClick = function()
            self:ValidateCode()
        end

        return
    end

    if self.Language ~= "glua" then
        self:RunJS("gmodinterface.ClearError()")
        local langName = self.Language

        if self.LanguageData.aliases and #self.LanguageData.aliases then
            langName = self.LanguageData.aliases[1]
        end

        self:SetStatus(("No validation (%s)"):format(langName), Color(0, 150, 0))

        self.StatusButton.DoClick = function()
            self:ValidateCode()
        end

        return
    end

    local start_time = os.clock()
    local compile = CompileString(self.Code, self.VALIDATION_COMPILE, false)
    local delta = os.clock() - start_time

    if compile and isstring(compile) then
        local msg, line = Noir.Utils.ParseLuaError(compile, self.VALIDATION_COMPILE)
        self:SetLuaError(msg, line)
        self:SetStatus(string.format("Error: %s at line %s", msg, line), Color(150, 0, 0), true)
    elseif delta > 0.05 then
        self:SetStatus(string.format("Error: Compilation took too long (%sms)", delta), Color(150, 0, 0), true)
        self:RunJS("gmodinterface.ClearError()")
        self.StatusButton.DoClick = function() end
    else
        self:RunJS("gmodinterface.ClearError()")
        self:SetStatus("Validated", Color(0, 150, 0), true)

        self.StatusButton.DoClick = function()
            self:ValidateCode()
        end
    end
end

function PANEL:SetLuaError(message, line)
    self:RunJS([[gmodinterface.SetError(%s, "%s")]], line, message:JavascriptSafe())

    self.StatusButton.DoClick = function()
        self:RunJS("gmodinterface.GotoLine(%s)", line)
    end
end

function PANEL:JS_OnReady(avaliableLaungages)
    self:RunJS(Noir.Autocomplete.GetJS())
    self:RunJS(self.CUSTOM_JS)
    self:SetStatus("Ready", Color(0, 150, 0))
    self.avaliableLaungages = avaliableLaungages
    self.Ready = true

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
        -- Noir.Debug("JS Callback: " .. name, ...)
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
        gui.OpenURL(url)
    end)

    self:AddJSCallback("OnCode")
    self:AddJSCallback("OnAction")
    self:AddJSCallback("OnSessions")
    self:AddJSCallback("OnSessionSet")
end

vgui.Register("NoirMonacoEditor", PANEL, "EditablePanel")