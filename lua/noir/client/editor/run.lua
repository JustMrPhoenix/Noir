local Editor = Noir.Editor or {}
Noir.Editor = Editor
Editor.Run = Editor.Run or {}

function Editor.Run.Code(target)
	if Editor.ActiveSession and Editor.ActiveSession.sessionType == "console" then return end
	Editor.Run.LastTarget = target
	Editor.Storage.QueueSave()
	-- JS tabs run in the editor's own DHTML (JS is local-only, so `target` is
	-- ignored); no network transfer. Noir.BuildJSEditorRun swaps in the original
	-- console for the run so output prints plainly to the game console instead of
	-- going through the Editor's "[Editor]"-prefixed console overrides.
	-- Call RunJavascript directly since PANEL:RunJS would Format() the snippet.
	if Editor.ActiveSession and Editor.ActiveSession.language == "javascript" then
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

	local id = Noir.Network.GenerateTransferId()
	if not id then
		Editor.MonacoPanel:SetStatus("Could not send code! See console for details", Color(150, 0, 0))
		return
	end

	local totalRan = 0
	local hasError = false
	Noir.Environment.RegisterHandler(function(sender, transferId, _, data)
		totalRan = totalRan + 1
		local tbl = util.JSONToTable(data)
		if not tbl then
			hasError = true
			Noir.Error("Received invalid response from ", sender == Entity(0) and "SERVER" or tostring(sender), "\nData: ", data, "\n")
			return
		end

		local done, returns = unpack(util.JSONToTable(data))
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
	local replPanel = Editor.Console.GetMainPanel()
	if replPanel then
		local sessionName = Editor.ActiveSession.name
		local runStartTime = SysTime()
		local hasFocused = false
		Noir.Environment.RegisterHandler(function(sender, transferId, message, data)
			local done, returns = unpack(util.JSONToTable(data) or {})
			if message == "run" and done and returns == "nil" then return end
			local displayname = Format("%s[%s]", sessionName, table.concat({string.match(id, "(%x%x)%x+(%x%x)$")}, ".."))
			if targets ~= 1 then displayname = displayname .. "-" .. (sender == Entity(0) and "SERVER" or tostring(sender)) end
			local succ, err = pcall(replPanel.OnMessage, replPanel, target, displayname, sender, transferId, message, data)
			if not succ then replPanel:AppendText(Format("--[[%s: Could not display output]] %s", displayname, err)) end
			-- Only focus main console if output arrives immediately after running (within 1 second)
			if not hasFocused and (SysTime() - runStartTime) < 1 then
				hasFocused = true
				Editor.Console.FocusMain()
			end
		end, id)
	end

	Noir.SendCode(Editor.ActiveSession.code, Editor.ActiveSession.name, target, id)
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

	local maxLineLen = 0
	for _, line in pairs(string.Split(cohText, "\n")) do
		maxLineLen = math.max(maxLineLen, string.len(line))
	end

	local indentSize = math.ceil(maxLineLen / 2)
	cohText = string.rep(" ", indentSize) .. "[Noir Editor]" .. string.rep(" ", indentSize) .. "\n" .. cohText
	coh.SendTypedMessage(cohText)
end
