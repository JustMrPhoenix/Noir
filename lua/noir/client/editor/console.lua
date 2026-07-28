local Editor = Noir.Editor or {}
Noir.Editor = Editor
Editor.Console = Editor.Console or {}
Editor.Console.Sessions = {} -- Track all console sessions
Editor.Console.Main = nil -- The main console that receives all script output
Editor.Console.Counter = 0 -- Counter for naming new consoles

-- Build (and track) the NoirReplPanel for `session`, parented to the frame and hidden
-- until activated. Shared by CreateTab and the session-restore path (via the console
-- tab type's Build), so both apply the persisted language + run target identically.
function Editor.Console.BuildPanel(session, parent)
	parent = parent or Editor.Frame
	if not IsValid(parent) then return end
	local replPanel = vgui.Create("NoirReplPanel", parent)
	replPanel:DockMargin(0, 0, -5, -5)
	replPanel:Dock(FILL)
	replPanel:SetVisible(false)
	replPanel:SetCursor("sizenwse")
	session.ReplPanel = replPanel
	replPanel.IsMainConsole = session.isMainConsole or false
	replPanel.Session = session
	Editor.Console.ApplySessionLanguage(replPanel, session)
	Editor.Console.ApplySessionTarget(replPanel, session)
	Editor.WireFrameDrag(replPanel)
	Editor.WireFocusAlpha(replPanel.HTMLPanel)
	Editor.Console.Sessions[session.name] = session
	if session.isMainConsole then Editor.Console.Main = session end
	return replPanel
end

-- Create a new console tab
function Editor.Console.CreateTab(consoleName, isMain)
	if not consoleName then
		if isMain then
			consoleName = "Main Console"
		else
			Editor.Console.Counter = Editor.Console.Counter + 1
			consoleName = "Console " .. Editor.Console.Counter
		end
	end

	-- Check if console with this name already exists
	if Editor.SessionsByName[consoleName] then
		Editor.Tab.SetActive(consoleName)
		return Editor.SessionsByName[consoleName]
	end

	local session = {
		name = consoleName,
		code = "",
		sessionType = Editor.SessionType.Console,
		SavedCode = "",
		isMainConsole = isMain or false
	}

	-- Tab.Open builds the REPL panel via the console type's Build (Console.BuildPanel).
	return Editor.Tab.Open(session)
end

-- Restore a console's persisted (non-Lua) language onto its REPL panel. Deferred
-- until the panel's HTML is ready, since replinterface.SetLanguage is a JS call.
-- Sets replPanel.Language up front so the JS run path is active before the frontend
-- language is applied.
function Editor.Console.ApplySessionLanguage(replPanel, session)
	local langId = session.language
	if not langId or langId == "glua" then return end
	replPanel.Language = langId
	replPanel:UpdateLanguageCombo(langId)
	-- JS collapses the target selector to "This console".
	replPanel:UpdateTargetCombo()
	local function apply()
		replPanel:RunJS("replinterface.SetLanguage(%q)", langId)
		replPanel:RunJS("replinterface.ResetAutocompletion()")
	end

	if replPanel.Ready then
		apply()
	else
		local prevOnReady = replPanel.OnReady
		replPanel.OnReady = function(pnl)
			if prevOnReady then prevOnReady(pnl) end
			apply()
		end
	end
end

-- Restore a console's persisted run target onto its REPL panel. Deferred until
-- the panel is ready (SetTarget issues JS autocomplete calls), and only for Lua
-- consoles -- the run target is a Lua concept and would otherwise clobber a JS
-- console's autocomplete state.
function Editor.Console.ApplySessionTarget(replPanel, session)
	local target = session.target
	if not target or target == "self" then return end
	if session.language and session.language ~= "glua" then return end
	local function apply()
		replPanel:ApplyTarget(target)
	end

	if replPanel.Ready then
		apply()
	else
		local prevOnReady = replPanel.OnReady
		replPanel.OnReady = function(pnl)
			if prevOnReady then prevOnReady(pnl) end
			apply()
		end
	end
end

-- Show the main console tab (create if needed)
function Editor.Console.ShowMain()
	-- Queue if editor isn't ready yet (takes a moment to initialize)
	if not Editor.IsReady then
		table.insert(Editor.PendingOnReady, Editor.Console.ShowMain)
		return
	end

	if not Editor.Console.Main then Editor.Console.CreateTab("Main Console", true) end
	Editor.Tab.SetActive("Main Console")
end

-- Show a console tab by name, or show main console
function Editor.Console.Show(consoleName)
	if consoleName and Editor.SessionsByName[consoleName] then
		Editor.Tab.SetActive(consoleName)
	else
		Editor.Console.ShowMain()
	end
end

-- Toggle main console tab visibility
function Editor.Console.Toggle()
	if Editor.ActiveSession and Editor.ActiveSession.sessionType == Editor.SessionType.Console then
		-- Switch to the first editor (non-panel) tab
		for _, s in ipairs(Editor.Sessions) do
			if not Editor.Session.IsPanel(s) then
				Editor.Tab.SetActive(s.name)
				return
			end
		end
	else
		Editor.Console.ShowMain()
	end
end

-- Get the main console's REPL panel for output
function Editor.Console.GetMainPanel()
	if not Editor.Console.Main then Editor.Console.CreateTab("Main Console", true) end
	return Editor.Console.Main and Editor.Console.Main.ReplPanel
end

-- Focus the main console (used after script output)
function Editor.Console.FocusMain()
	if Editor.Console.Main then Editor.Tab.SetActive(Editor.Console.Main.name) end
end

-- Evaluate a one-shot `code` expression on `target` ("self"/"server") and echo its
-- result into the Main Console, exactly like an editor run (same OnMessage routing).
-- Used e.g. by the entity-search sidebar to drop a selected entity into the REPL
-- output. The channel is torn down once the result arrives -- this is for bounded
-- expressions (no hooks/timers) sent to a single realm; use the editor Run path for
-- streaming/multi-target runs. Returns the run channel id.
function Editor.Console.Evaluate(code, target, label)
	local panel = Editor.Console.GetMainPanel()
	if not panel then return end
	target = target or "self"
	label = label or "Noir.eval"
	-- Prefer expression form so a bare value (e.g. Entity(5)) is returned and shown,
	-- not run as a statement that yields nothing (mirrors the REPL's OnCode / EvalCode).
	if isfunction(CompileString("return " .. code, label, false)) then code = "return " .. code end
	local id = Noir.Network.OpenChannel("runCode", target)
	if not id then return end
	Noir.Environment.RegisterHandler(function(sender, transferId, message, data)
		local succ, err = pcall(panel.OnMessage, panel, target, label, sender, transferId, message, data)
		if not succ then panel:AppendText(Format("--[[%s: Could not display output]] %s", label, err)) end
		-- Bounded single-target expression: drop the channel once its result is in.
		if message == "run" then Noir.Network.CloseChannel(transferId) end
	end, id)

	Noir.SendCode(code, label, target, id)
	Editor.Console.FocusMain()
	return id
end

-- Public wrapper: external callers (repl.lua) use Noir.Editor.ShowMainConsole.
function Editor.ShowMainConsole() return Editor.Console.ShowMain() end

-- The console (REPL) tab type: a bespoke per-session NoirReplPanel, none of the
-- editor capabilities. Its close button reads "Hide" for parity with the old UI.
Editor.TabTypes.Register(Editor.SessionType.Console, {
	closeTooltip = "Hide",
	caps = {},
	Icon = function() return "icon16/application_xp_terminal.png" end,
	Build = function(session, parent) Editor.Console.BuildPanel(session, parent) end,
	Activate = function(session)
		if IsValid(session.ReplPanel) then
			session.ReplPanel:SetVisible(true)
			session.ReplPanel:RequestFocus()
		end
	end,
	Deactivate = function(session)
		if IsValid(session.ReplPanel) then session.ReplPanel:SetVisible(false) end
	end,
	Destroy = function(session)
		if IsValid(session.ReplPanel) then session.ReplPanel:Remove() end
		session.ReplPanel = nil
		Editor.Console.Sessions[session.name] = nil
		if Editor.Console.Main == session then Editor.Console.Main = nil end
	end,
	SetAlpha = function(session, alpha)
		if IsValid(session.ReplPanel) then session.ReplPanel:SetAlpha(alpha) end
	end,
	IsReady = function(session)
		return not IsValid(session.ReplPanel) or session.ReplPanel.Ready
	end
})
