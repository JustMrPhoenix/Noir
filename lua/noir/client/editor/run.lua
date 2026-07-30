local Editor = Noir.Editor or {}
Noir.Editor = Editor
Editor.Run = Editor.Run or {}

function Editor.Run.Code(target)
	-- Only tab types that opt into running (the editor type) use the Monaco run path;
	-- console / SQL tabs have their own input handling.
	if not Editor.ActiveSession or not Editor.TabTypes.Get(Editor.ActiveSession).caps.run then return end
	-- A tab type may restrict which realms it can run on (e.g. a server-only tab).
	if not Editor.TabTypes.CanRunOn(Editor.ActiveSession, target) then
		Editor.MonacoPanel:SetStatus(Format("This tab can't run on '%s'", tostring(target)), Color(200, 150, 0), true)
		return
	end
	Editor.Run.LastTarget = target
	Editor.Storage.QueueSave()
	-- JS tabs run in the editor's own DHTML (JS is local-only, so `target` is
	-- ignored); nothing is networked. Noir.BuildJSEditorRun swaps in the original
	-- console for the run so output prints plainly to the game console instead of
	-- going through the Editor's "[Editor]"-prefixed console overrides.
	-- Call RunJavascript directly since PANEL:RunJS would Format() the snippet.
	if Editor.ActiveSession.language == "javascript" then
		Editor.MonacoPanel.HTMLPanel:RunJavascript(Noir.BuildJSEditorRun(Editor.ActiveSession.code))
		Editor.MonacoPanel:SetStatus("Ran as JavaScript (output in game console)", Color(0, 150, 0), true)
		return
	end
	local targets
	if target == "clients" then
		targets = #player.GetHumans()
	elseif target == "shared" then
		targets = #player.GetHumans() + 1
	else
		targets = 1
	end

	local id = Noir.Network.OpenChannel("runCode", target)
	if not id then
		Editor.MonacoPanel:SetStatus("Could not send code! See console for details", Color(150, 0, 0))
		return
	end

	-- Track every run this session starts (id -> target). Each run channel may keep
	-- replying, so we hold them until the session is closed (Editor.Session.Close)
	-- and tear them down together.
	Editor.ActiveSession.runChannels = Editor.ActiveSession.runChannels or {}
	Editor.ActiveSession.runChannels[id] = target

	local totalRan = 0
	local hasError = false
	Noir.Environment.RegisterHandler(function(sender, channelId, _, data)
		totalRan = totalRan + 1
		local done, returns, ok = Noir.Environment.DecodeRunResult(data)
		if not ok then
			hasError = true
			Noir.Error("Received invalid response from ", sender == Entity(0) and "SERVER" or tostring(sender), "\nData: ", data, "\n")
			return
		end

		local senderName = sender == Entity(0) and "SERVER" or tostring(sender)
		if not done then
			hasError = true
			local msg, line = Noir.Utils.ParseLuaError(returns, Editor.ActiveSession.name)
			if CLIENT and sender == LocalPlayer() then
				Editor.MonacoPanel:AddLuaError(msg, line)
				Editor.MonacoPanel:SetStatus(Format("Error: %s at line %s", msg, line), Color(150, 0, 0), true)
			else
				Editor.MonacoPanel:AddLuaError(Format("[%s] %s", senderName, msg), line)
				Editor.MonacoPanel:SetStatus(Format("[%s] Error: %s at line %s", senderName, msg, line), Color(150, 0, 0), true)
			end
		elseif not hasError then
			if targets ~= 1 then
				Editor.MonacoPanel:SetStatus(Format("[%i/%i] Ran on %s successfully", totalRan, targets, senderName), Color(0, 150, 0), true)
			else
				Editor.MonacoPanel:SetStatus(Format("Ran on %s successfully", senderName), Color(0, 150, 0), true)
			end
		end
	end, id, "run")

	-- Get the main console panel for output (creates it if needed)
	local replPanel = Editor.Console.EnsureMainPanel()
	if replPanel then
		local sessionName = Editor.ActiveSession.name
		local runStartTime = SysTime()
		local hasFocused = false
		Noir.Environment.RegisterHandler(function(sender, channelId, message, data)
			local done, returns = Noir.Environment.DecodeRunResult(data)
			if message == "run" and done and returns == "nil" then return end
			local displayname = Format("%s[%s]", sessionName, table.concat({string.match(id, "(%x%x)%x+(%x%x)$")}, ".."))
			if targets ~= 1 then displayname = displayname .. "-" .. (sender == Entity(0) and "SERVER" or tostring(sender)) end
			Noir.Utils.ForwardPanelMessage(replPanel, target, displayname, sender, channelId, message, data)
			-- Only focus main console if output arrives immediately after running (within 1 second)
			if not hasFocused and (SysTime() - runStartTime) < 1 then
				hasFocused = true
				Editor.Console.FocusMain()
			end
		end, id)
	end

	-- SWEP/SENT: flag the run with the tab's effective entity type so the target realm
	-- wraps the body in Start/End. Registering needs both realms, so nudge toward Shared.
	local entType = Editor.Session.GetEntType(Editor.ActiveSession)
	local runOpts
	if entType then
		runOpts = {
			entType = entType,
			entClass = Editor.Session.GetEntClass(Editor.ActiveSession),
			spawn = false
		}

		if target ~= "shared" then
			Editor.MonacoPanel:SetStatus(
				Format("%s tab: run on Shared to register on client + server", entType),
				Color(200, 150, 0), true
			)
		end
	end

	Noir.SendCode(Editor.ActiveSession.code, target, Editor.ActiveSession.name, id, runOpts)
end

function Editor.Run.UpdateCOH()
	if not coh or not Editor.ActiveSession then return end
	local cohText = Format(
		"%d Tab(s) - Current: %s\n%d line(s)",
		#Editor.Sessions, Editor.ActiveSession.name, #string.Split(Editor.ActiveSession.code, "\n")
	)
	if Editor.MonacoPanel and Editor.MonacoPanel.LastReport then
		if Editor.MonacoPanel.LastReport.errors ~= 0 then
			cohText = cohText .. "; Contains errors :c"
		else
			cohText = cohText .. Format("; %d warning(s)", Editor.MonacoPanel.LastReport.warnings)
		end
	end

	coh.SendTypedMessage(Noir.Utils.CenterCOHTitle(cohText, "[Noir Editor]"))
end
