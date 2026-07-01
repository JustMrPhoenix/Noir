local Editor = Noir.Editor or {}
Noir.Editor = Editor
Editor.Console = Editor.Console or {}
Editor.Console.Sessions = {} -- Track all console sessions
Editor.Console.Main = nil -- The main console that receives all script output
Editor.Console.Counter = 0 -- Counter for naming new consoles

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
		sessionType = "console",
		SavedCode = "",
		isMainConsole = isMain or false
	}

	table.insert(Editor.Sessions, session)
	Editor.SessionsByName[consoleName] = session
	Editor.Console.Sessions[consoleName] = session
	Editor.Tab.Add(session)
	-- Create REPL panel for this console
	if Editor.Frame then
		local replPanel = vgui.Create("NoirReplPanel", Editor.Frame)
		replPanel:DockMargin(0, 0, -5, -5)
		replPanel:Dock(FILL)
		replPanel:SetVisible(false)
		replPanel:SetCursor("sizenwse")
		session.ReplPanel = replPanel
		replPanel.OnMousePressed = function(_, ...)
			if Editor.Frame.Maximized then return end
			Editor.Frame:OnMousePressed(...)
		end

		replPanel.OnMouseReleased = function(_, ...)
			if Editor.Frame.Maximized then return end
			Editor.Frame:OnMouseReleased(...)
		end

		replPanel.HTMLPanel.OnFocusChanged = function(_, hasFocus) Editor.SetFocusAlpha(hasFocus) end
	end

	if isMain then Editor.Console.Main = session end
	return session
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

-- Close a console tab
function Editor.Console.Close(consoleName)
	local session = Editor.SessionsByName[consoleName]
	if not session or session.sessionType ~= "console" then return end
	-- Remove REPL panel
	if session.ReplPanel then
		session.ReplPanel:Remove()
		session.ReplPanel = nil
	end

	-- Remove from console sessions tracking
	Editor.Console.Sessions[consoleName] = nil
	-- If this was the main console, clear the reference
	if Editor.Console.Main == session then Editor.Console.Main = nil end
	-- Close the session
	Editor.Session.Close(consoleName)
end

-- Toggle main console tab visibility
function Editor.Console.Toggle()
	if Editor.ActiveSession and Editor.ActiveSession.sessionType == "console" then
		-- Switch to first non-console tab
		for _, s in ipairs(Editor.Sessions) do
			if s.sessionType ~= "console" then
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

-- Public wrapper: external callers (repl.lua) use Noir.Editor.ShowMainConsole.
function Editor.ShowMainConsole() return Editor.Console.ShowMain() end
