local PANEL = {}
PANEL.Base = "EditablePanel"

-- Ordered fixed targets that Tab cycles through in the REPL input (specific
-- players remain reachable only via the dropdown).
local CYCLE_TARGETS = {
	{ label = "Run on self", target = "self", icon = "icon16/user.png" },
	{ label = "Run on server", target = "server", icon = "icon16/server.png" },
	{ label = "Run on clients", target = "clients", icon = "icon16/group.png" },
	{ label = "Run on shared", target = "shared", icon = "icon16/world.png" },
}

-- The REPL only evaluates Lua or JavaScript (unlike the editor's richer set).
local LANGUAGE_CHOICES = {
	{ "Lua", "glua" },
	{ "JS", "javascript" },
}
local LANGUAGE_LABELS = {}
for _, choice in ipairs(LANGUAGE_CHOICES) do
	LANGUAGE_LABELS[choice[2]] = choice[1]
end
local LANGUAGE_COMBO_WIDTH = 70

-- In JS mode code runs locally in this console; the run target selector collapses
-- to a single entry (more JS targets may be added later).
local JS_TARGET_LABEL = "This console"
local JS_TARGET_ICON = "icon16/application_xp_terminal.png"

PANEL.URL = Noir.DEBUG and "http://loopback.bestboy.moe:8080/repl.html" or "https://metastruct.github.io/gmod-monaco/repl.html"
function PANEL:Init()
	local html = self:Add("DHTML")
	html:Dock(FILL)
	html:DockMargin(0, 0, 0, 0)
	self.HTMLPanel = html
	self:SetupHTML()
	self:SetPaintBackgroundEnabled(true)
	local statusButton = self:Add("DButton")
	statusButton:SetSkin("Noir")
	-- Leave room on the left for the target combobox and on the right for the
	-- language combobox (both floated in OnSizeChanged).
	statusButton:DockMargin(150, 0, LANGUAGE_COMBO_WIDTH + 15, 0)
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
	comboBox:SetTextInset(32, 0)
	comboBox:SetText("Run on self")
	comboBox:SetIcon("icon16/user.png")
	comboBox:SetSize(150, 20)
	comboBox.m_Image:SetPos(4, 2)
	self.TargetCombobox = comboBox
	comboBox.OpenMenu = function(_, pControlOpener)
		if IsValid(comboBox.Menu) then
			comboBox.Menu:Remove()
			comboBox.Menu = nil
		end

		self:FillMenu()
		local x, y = comboBox:LocalToScreen(0, comboBox:GetTall())
		comboBox.Menu:SetMinimumWidth(comboBox:GetWide())
		comboBox.Menu:Open(x, y, false, comboBox)
	end

	-- Bottom-right language selector, mirroring the editor's (monaco_panel.lua).
	local langCombo = self:Add("DComboBox")
	langCombo:SetSkin("Noir")
	langCombo:SetTextColor(Color(200, 200, 200))
	langCombo:SetSortItems(false)
	for _, choice in ipairs(LANGUAGE_CHOICES) do
		langCombo:AddChoice(choice[1], choice[2])
	end

	langCombo:SetValue("Lua")
	self.LanguageCombo = langCombo
	langCombo.OnSelect = function(_, _, _, langId)
		if self.SuppressLangSelect then return end
		self:SwitchLanguage(langId)
	end

	self:RequestFocus()
	self.Target = "self"
	self.TargetLabel = "Run on self"
	self.TargetIcon = "icon16/user.png"
	self.ReplCounter = 0
	self.Actions = {}
	self.Language = "glua"
	self.HasOutput = false
	-- id -> target for every run this panel started. Each run channel may keep
	-- replying (hooks/timers), so we hold them all until the panel is removed, then
	-- tear them down together.
	self.ActiveTransfers = {}
end

function PANEL:OnRemove()
	for id, target in pairs(self.ActiveTransfers or {}) do
		Noir.Environment.CloseRun(id, target)
	end

	self.ActiveTransfers = {}
end

function PANEL:OnSizeChanged(newWidth, newHeight)
	self.TargetCombobox:SetPos(0, newHeight - 20)
	if IsValid(self.LanguageCombo) then
		self.LanguageCombo:SetSize(LANGUAGE_COMBO_WIDTH, 20)
		self.LanguageCombo:SetPos(newWidth - LANGUAGE_COMBO_WIDTH, newHeight - 20)
	end
end

function PANEL:Paint(w, h)
	surface.SetDrawColor(42, 42, 42, self.PanelAlpha or 255)
	surface.DrawRect(0, 0, w, h)
end

function PANEL:FillMenu()
	local runMenu = DermaMenu(false, self.TargetCombobox)
	runMenu:SetSkin("Noir")
	runMenu:SetDeleteSelf(false)
	runMenu:SetDrawColumn(true)
	runMenu:Hide()
	self.RunMenu = runMenu
	self.TargetCombobox.Menu = runMenu
	if self.Language == "javascript" then
		-- JS runs in this console only; one target for now.
		local option = runMenu:AddOption(JS_TARGET_LABEL, function() end)
		option:SetIcon(JS_TARGET_ICON)
		option:SetTextColor(Color(200, 200, 200))
		return
	end

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

-- Reflect the active language in the selector without triggering OnSelect.
function PANEL:UpdateLanguageCombo(langId)
	if not IsValid(self.LanguageCombo) then return end
	self.SuppressLangSelect = true
	self.LanguageCombo:SetValue(LANGUAGE_LABELS[langId] or langId or "Lua")
	self.SuppressLangSelect = false
end

-- Show the current target (or "This console" in JS mode) in the combobox.
function PANEL:UpdateTargetCombo()
	if self.Language == "javascript" then
		self.TargetCombobox:SetIcon(JS_TARGET_ICON)
		self.TargetCombobox:SetText(JS_TARGET_LABEL)
	else
		self.TargetCombobox:SetIcon(self.TargetIcon or "icon16/user.png")
		self.TargetCombobox:SetText(self.TargetLabel or "Run on self")
	end
end

-- Switch the run target and refresh the combobox + autocomplete state. Shared
-- by the dropdown options and the Tab cycling.
function PANEL:SetTarget(label, target, icon)
	self.Target = target
	self.TargetLabel = label
	self.TargetIcon = icon
	self:UpdateTargetCombo()
	self:RunJS("replinterface.ResetAutocompletion()")
	if target == "server" then
		self:RunJS("replinterface.LoadAutocompleteState(\"Server\")")
	elseif target == "shared" then
		self:RunJS(Noir.Autocomplete.GetJSWithState("Shared", "replinterface"))
	else
		self:RunJS(Noir.Autocomplete.GetJSWithState("Client", "replinterface"))
	end

	-- Persist the fixed string targets (self/server/shared/clients) so the choice
	-- survives restarts. Specific players (Entity targets) are intentionally not
	-- persisted.
	if self.Session and isstring(target) then
		self.Session.target = target
		Noir.Editor.Storage.QueueSave()
	end
end

-- Restore a persisted fixed run target onto this panel. Unknown/absent values
-- (e.g. a previously selected player) are ignored.
function PANEL:ApplyTarget(target)
	if not target then return end
	for _, t in ipairs(CYCLE_TARGETS) do
		if t.target == target then
			self:SetTarget(t.label, t.target, t.icon)
			return
		end
	end
end

-- Advance the run target by `dir` (+1 / -1) through CYCLE_TARGETS, wrapping. A
-- non-cycle target (a specific player) is treated as index 0 so Tab lands on
-- the first fixed target.
function PANEL:CycleTarget(dir)
	if self.Language == "javascript" then return end
	local idx = 0
	for i, t in ipairs(CYCLE_TARGETS) do
		if t.target == self.Target then
			idx = i
			break
		end
	end

	local nextIdx = ((idx - 1 + dir) % #CYCLE_TARGETS) + 1
	local t = CYCLE_TARGETS[nextIdx]
	self:SetTarget(t.label, t.target, t.icon)
end

function PANEL:AddRunOption(label, target, icon, menu)
	menu = menu or self.RunMenu
	local option = menu:AddOption(label, function()
		self:SetTarget(label, target, icon)
	end)

	-- replinterface.LoadAutocompleteState("client")
	option:SetIcon(icon)
	option:SetTextColor(Color(200, 200, 200))
end

function PANEL:UpdateRunOnSubmenu()
	self.RunOnSubmenu:Clear()
	for _, v in pairs(player.GetHumans()) do
		self:AddRunOption(v:Nick(), v, v:IsSuperAdmin() and "icon16/user_suit.png" or "icon16/user.png", self.RunOnSubmenu)
	end
end

function PANEL:SwitchLanguage(langId)
	if self.Language == langId then return end
	if self.IsMainConsole and langId ~= "glua" then
		Derma_Message(
			"The Main Console stays in Lua so it can display script output.\nOpen a new console (Ctrl+Shift+`) to use JavaScript.",
			"Main Console", "Ok"
		):SetSkin("Noir")
		self:UpdateLanguageCombo(self.Language)
		return
	end

	local function apply()
		self:RunJS("replinterface.Reset()")
		self.Language = langId
		self.HasOutput = false
		self:RunJS("replinterface.SetLanguage(%q)", langId)
		-- Each language keeps its own history; swap to the new language's entries.
		self:LoadHistory(langId)
		-- Autocomplete data is GLua-specific; drop it for JS and restore it for Lua.
		self:RunJS("replinterface.ResetAutocompletion()")
		if langId == "glua" then
			if self.Target == "server" then
				self:RunJS("replinterface.LoadAutocompleteState(\"Server\")")
			elseif self.Target == "shared" then
				self:RunJS(Noir.Autocomplete.GetJSWithState("Shared", "replinterface"))
			else
				self:RunJS(Noir.Autocomplete.GetJSWithState("Client", "replinterface"))
			end
		end

		self:UpdateLanguageCombo(langId)
		-- Collapse the target selector to "This console" for JS, or restore the
		-- Lua run target when switching back.
		self:UpdateTargetCombo()
		if self.Session then
			self.Session.language = langId
			Noir.Editor.Storage.QueueSave()
		end
	end

	if self.HasOutput then
		Derma_Query(
			"Switching language clears this console. Continue?", "Switch language?",
			"Switch", apply, "Cancel", function() self:UpdateLanguageCombo(self.Language) end
		):SetSkin("Noir")
	else
		apply()
	end
end

function PANEL:RunJSCode(code)
	local identifier = "Noir.repl" .. self.ReplCounter
	self.ReplCounter = self.ReplCounter + 1
	self.HTMLPanel:RunJavascript(Noir.BuildJSEval(identifier, code, true))
	self:UpdateCOH()
end

-- Mirror the Lua REPL's `--[[identifier: type]] value` output format so JS runs read
-- the same way, including which run produced each console.log/warn/error line.
function PANEL:JS_OnJSResult(identifier, kind, text)
	-- A JS eval emits exactly one terminal result ("return" on success, uppercase
	-- "ERROR" on throw); console.log/warn/error ("error" lowercase) are interim
	-- output. Only the terminal result is the answer that closes the input's fold.
	local isRunResult = kind == "return" or kind == "ERROR"
	if kind == "return" then
		self:SetStatus("Ran (JS)", Color(0, 150, 0), true)
		self:UpdateCOH()
		-- Nothing to display for an undefined result, but still close the fold once.
		if text == "undefined" then return self:AppendAnswer("") end
	elseif kind == "ERROR" or kind == "error" then
		self:SetStatus("Error (JS)", Color(150, 0, 0), true)
	end

	if string.find(text, "\n") then text = "\n" .. text end
	-- JS console pane -- use a JS block comment for the label, not Lua's --[[ ]].
	local formatted = Format("/* %-13s: %s */ %s", identifier, kind, text)
	if isRunResult then
		self:AppendAnswer(formatted)
	else
		self:AppendText(formatted)
	end
end

-- Push the persisted, per-language command history into the frontend so Up/Arrow
-- and reverse-search see prior sessions' commands. Guarded so it's a no-op on
-- older frontend builds that lack SetHistory.
function PANEL:LoadHistory(language)
	if not self.Ready then return end
	local history = Noir.Editor.Storage.GetReplHistory(language or self.Language)
	-- util.TableToJSON encodes an empty table as `{}` (an object); force `[]` so the
	-- frontend's array indexing stays valid when there's no history yet.
	local json = #history > 0 and util.TableToJSON(history) or "[]"
	self:RunJS("if (window.replinterface && replinterface.SetHistory) replinterface.SetHistory(%s)", json)
end

function PANEL:RequestFocus()
	self.HTMLPanel:RequestFocus()
	if self.Ready then self:RunJS("if (window.replinterface && replinterface.line) replinterface.line.focus();") end
end

function PANEL:SetStatus(text, color, prependTime)
	self.status = text
	PANEL:UpdateCOH()
	self.StatusButton:SetText((prependTime and Format("[%s] ", os.date("%H:%M:%S")) or "") .. text)
	self.StatusButton.BackgroundColor = color or self.StatusButton.BackgroundColor
end

function PANEL:SetAlpha(alpha)
	self.PanelAlpha = alpha
	if not self.Ready then return end
	self:RunJS([[document.getElementsByTagName("body")[0].style.opacity = %f]], alpha / 255)
end

function PANEL:RunJS(code, ...)
	local js = Format(code, ...)
	Noir.Debug("RunJS", js)
	self.HTMLPanel:RunJavascript(js)
end

function PANEL:AddJSCallback(name)
	self.HTMLPanel:AddFunction("replinterface", name, function(...) self["JS_" .. name](self, ...) end)
end

function PANEL:OnLog(...)
	Noir.Msg("[", Color(0, 0, 150), "Editor", Color(255, 255, 255), "] ", ..., "\n")
end

function PANEL:JS_OnCode(code)
	self.Code = code
	self.LastEdit = CurTime()
	if self.OnCode then self:OnCode(code) end
end

function PANEL:AddAction(id, label, callback, keyBindings, precondition)
	self.Actions[id] = callback
	if isstring(keyBindings) then keyBindings = {keyBindings} end
	self:RunJS([[replinterface.AddAction(%s)]], util.TableToJSON({
		id = id,
		label = label,
		keyBindings = keyBindings,
		precondition = precondition
	}))
end

function PANEL:JS_OnAction(id)
	if self.OnAction then self:OnAction(id) end
	if self.Actions[id] then self.Actions[id](self, id) end
end

function PANEL:JS_OnReady()
	self:RunJS(Noir.Autocomplete.GetJSWithState("Client", "replinterface"))
	-- Turn `@path/to/file.lua` references in REPL output into clickable links, but
	-- only once we confirm each file exists (OnFileExistsRequest, cached JS-side).
	self:RunJS("replinterface.EnableLinkValidation()")
	Noir.Editor.RegisterActions(self)
	self:SetStatus("Ready", Color(0, 150, 0))
	self.Ready = true
	self:LoadHistory()
	-- SetAlpha may have run before the page was ready (JS skipped); apply it now.
	if self.PanelAlpha then self:SetAlpha(self.PanelAlpha) end
	-- Flush any text that was buffered before the HTML was ready
	if self.TextBuffer then
		for _, entry in ipairs(self.TextBuffer) do
			self:RunJS("replinterface.AddText(\"%s\", %s)", entry.text:JavascriptSafe(), entry.isReplAnswer and "true" or "false")
		end

		self.TextBuffer = nil
	end

	self.StatusButton.DoClick = function() end
	-- Request focus now that the HTML panel is ready
	if self:IsVisible() then self:RequestFocus() end
	if self.OnReady then self:OnReady() end
end

function PANEL:OnCode(code)
	-- Each submission opens one fold on the frontend; its result closes it.
	self.AnswerPending = true
	-- Persist the raw submission (before any `return` rewrite) so it can be
	-- restored into the history of the matching language next session.
	Noir.Editor.Storage.AddReplHistory(self.Language, code)
	if self.Language == "javascript" then return self:RunJSCode(code) end
	local returnCode = "return " .. code
	local returnCompile = CompileString(returnCode, "Noir.replValidation", false)
	if isfunction(returnCompile) then code = returnCode end
	if self.Target == "clients" then
		self.targets = #player.GetHumans()
	elseif self.Target == "shared" then
		self.targets = #player.GetHumans() + 1
	else
		self.targets = 1
	end

	local identifier = "Noir.repl" .. self.ReplCounter
	local id = Noir.Network.OpenChannel("runCode", self.Target)
	self.ReplCounter = self.ReplCounter + 1
	if not id then
		Noir.Editor.MonacoPanel:SetStatus("Could not send code! See console for details", Color(150, 0, 0))
		return
	end

	self.totalRan = 0
	self.hasError = false
	self.lastTransfer = id
	self.ActiveTransfers[id] = self.Target
	Noir.Environment.RegisterHandler(function(...)
		local succ, err = pcall(self.OnMessage, self, self.Target, identifier, ...)
		if not succ then self:AppendText(Format("--[[%s: Could not display output]] %s", identifier, err)) end
	end, id)

	local succ, err = pcall(Noir.SendCode, code, identifier, self.Target, id)
	if not succ then
		self:SetStatus(Format("Error: %s", err), Color(150, 0, 0), true)
		-- No run result will arrive; this failure is the command's answer.
		self:AppendAnswer(Format("--[[Could not run code: %s]]", err))
	end

	self:UpdateCOH()
end

function PANEL:OnRunResult(identifier, sender, transferId, results)
	if transferId ~= self.lastTransfer then return end
	self.totalRan = self.totalRan + 1
	local done, returns = unpack(results)
	local senderName = sender == Entity(0) and "SERVER" or tostring(sender)
	if not done then
		self.hasError = true
		local msg = Noir.Utils.ParseLuaError(returns, identifier)
		Noir.Debug("Repl.Error", msg, returns)
		if CLIENT and sender == LocalPlayer() then
			self:SetStatus(Format("Error:%s", msg or returns), Color(150, 0, 0), true)
		else
			Noir.Editor.MonacoPanel:SetStatus(Format("[%s] Error:%s", senderName, msg), Color(150, 0, 0), true)
		end
	elseif not self.hasError then
		if self.targets ~= 1 then
			self:SetStatus(Format("[%i/%i] Ran on %s successfully", self.totalRan, self.targets, senderName), Color(0, 150, 0), true)
		else
			self:SetStatus(Format("Ran on %s successfully", senderName), Color(0, 150, 0), true)
		end
	end

	self:UpdateCOH()
end

function PANEL:OnMessage(target, replName, sender, transferId, message, messageBody)
	local isRunResult = message == "run"
	if isRunResult then
		local runResults = util.JSONToTable(messageBody)
		self:OnRunResult(replName, sender, transferId, runResults)
		message = runResults[1] == false and "ERROR" or "return"
		messageBody = runResults[2]
	end

	if string.find(messageBody, "\n") then messageBody = "\n" .. messageBody end
	local text
	if target == "shared" or target == "clients" then
		local senderName = sender == Entity(0) and "SERVER" or tostring(sender)
		text = Format("--[[%-13s: %s : %s]] %s", replName, senderName, message, messageBody)
	else
		text = Format("--[[%-13s: %s]] %s", replName, message, messageBody)
	end

	-- The run result of a command typed into this panel is its answer; script
	-- output (print/Msg) and results relayed from editor runs are plain output.
	if isRunResult and transferId == self.lastTransfer then
		self:AppendAnswer(text)
	else
		self:AppendText(text)
	end
end

-- isReplAnswer marks `text` as the result of a submitted REPL command so the
-- frontend closes that input's collapsible fold. Leave it nil/false for all other
-- console output (print/Msg capture, editor-run output, diagnostics).
function PANEL:AppendText(text, isReplAnswer)
	self.HasOutput = true
	if not self.Ready then
		self.TextBuffer = self.TextBuffer or {}
		table.insert(self.TextBuffer, {text = text, isReplAnswer = isReplAnswer})
		return
	end

	self:RunJS("replinterface.AddText(\"%s\", %s)", text:JavascriptSafe(), isReplAnswer and "true" or "false")
end

-- Emit `text` as the current command's answer (closing its REPL fold) if one is
-- still pending, otherwise as plain output. Guarantees exactly one answer per
-- submitted command even when several results (or none) come back.
function PANEL:AppendAnswer(text)
	local isReplAnswer = self.AnswerPending or false
	self.AnswerPending = false
	self:AppendText(text, isReplAnswer)
end

function PANEL:SetupHTML()
	self.HTMLPanel:OpenURL(self.URL)
	self.HTMLPanel:RunJavascript(Noir.JSRuntime)
	self:AddJSCallback("OnReady")
	self.HTMLPanel:AddFunction("console", "log", function(...)
		Noir.Debug("console.log", ...)
		self:OnLog(...)
	end)

	self.HTMLPanel:AddFunction("console", "warn", function(...)
		Noir.Debug("console.warn", ...)
		self:OnLog(...)
	end)

	self.HTMLPanel:AddFunction("console", "debug", function(...) Noir.Debug("console.debug", ...) end)
	self.HTMLPanel:AddFunction("console", "error", function(...)
		Noir.Error("[", Color(0, 0, 150), "Editor", Color(255, 255, 255), "] ", ..., "\n")
	end)
	self.HTMLPanel:AddFunction("replinterface", "OpenURL", function(url)
		Noir.Debug("OpenURL", url)
		if self.OnOpenURL then
			self:OnOpenURL(url)
		elseif not (Noir.Editor and Noir.Editor.OpenFileURL(url)) then
			gui.OpenURL(url)
		end
	end)

	self.HTMLPanel:AddFunction("noirjs", "OnResult", function(identifier, kind, text) self:JS_OnJSResult(identifier, kind, text) end)
	self:AddJSCallback("OnCode")
	self:AddJSCallback("OnAction")
	self:AddJSCallback("OnFileExistsRequest")
end

-- Monaco asks whether a file reference points at a real file; answer async so it
-- can decide whether to make the reference clickable.
function PANEL:JS_OnFileExistsRequest(path, requestId)
	self:RunJS("replinterface.ProvideFileExists(%d, %s)", requestId, Noir.Utils.FileReadable("GAME", path) and "true" or "false")
end

function PANEL:UpdateCOH()
	if not coh then return end
	local cohText = Format("%d repls so far\n%s", self.ReplCounter or 0, self.status or "Status uknown")
	local maxLineLen = 0
	for _, line in pairs(string.Split(cohText, "\n")) do
		maxLineLen = math.max(maxLineLen, string.len(line))
	end

	local indentSize = math.ceil(maxLineLen / 2)
	cohText = string.rep(" ", indentSize) .. "[Noir Console]" .. string.rep(" ", indentSize) .. "\n" .. cohText
	coh.SendTypedMessage(cohText)
end

-- Register as VGUI component for use in editor tabs
vgui.Register("NoirReplPanel", PANEL, "EditablePanel")
-- Show the main console tab in the editor (replaces separate REPL window)
function Noir.ShowRepl()
	if coh then coh.StartChat() end
	-- Open the editor if not already open, then show main console
	Noir.Editor.Show()
	Noir.Editor.ShowMainConsole()
end

concommand.Add("noir_showrepl", function(ply, cmd, args) Noir.ShowRepl() end)
