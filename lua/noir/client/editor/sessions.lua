local Editor = Noir.Editor or {}
Noir.Editor = Editor
Editor.Session = Editor.Session or {}

-- Sessions whose content is a bespoke per-session panel (console REPL / SQL tab),
-- not a Monaco document. They can't be saved or renamed as files, carry no entity
-- type, and their teardown removes the panel instead of a Monaco model.
Editor.Session.PanelTypes = {[Editor.SessionType.Console] = true, [Editor.SessionType.SQL] = true}
function Editor.Session.IsPanel(session)
	return session ~= nil and Editor.Session.PanelTypes[session.sessionType] ~= nil
end

-- Move a file to the front of the recent-files history (dedup, cap at 10) and
-- refresh the "Open Recent" menu. Called on both open and close.
function Editor.Session.AddRecent(path, fileName)
	for k, v in pairs(Editor.Config.recentFiles) do
		if v[1] == path and v[2] == fileName then table.remove(Editor.Config.recentFiles, k) end
	end

	table.insert(Editor.Config.recentFiles, 1, {path, fileName})
	if #Editor.Config.recentFiles > 10 then table.remove(Editor.Config.recentFiles) end
	Editor.Session.ReloadRecents()
end

function Editor.Session.ReloadRecents()
	for i = 1, Noir.Editor.UI.RecentSubmenu:ChildCount() do
		Noir.Editor.UI.RecentSubmenu:GetChild(i):Remove()
	end

	if #Editor.Config.recentFiles == 0 then
		Noir.Editor.UI.RecentSubmenu:GetParent():SetDisabled(true)
		return
	else
		Noir.Editor.UI.RecentSubmenu:GetParent():SetDisabled(false)
	end

	for _, v in pairs(Editor.Config.recentFiles) do
		Noir.Utils.AddMenuOption(Editor.UI.RecentSubmenu, Format("[%s] %s", unpack(v)), function() Editor.OpenFile(unpack(v)) end, "icon16/page.png")
	end

	Editor.UI.RecentSubmenu:AddSpacer()
	Noir.Utils.AddMenuOption(Editor.UI.RecentSubmenu, "Clear", function()
		Editor.Config.recentFiles = {}
		Editor.Storage.SaveConfig()
		Editor.Session.ReloadRecents()
	end, "icon16/cross.png")
end

function Editor.Session.Create(sessionName, code, fileData, sessionData)
	if sessionName == "Unnamed" then
		Derma_Message("Cant create session named 'Unnamed'", "Sorry ~~", "Ok then :c"):SetSkin("Noir")
		return
	end

	if not sessionName then
		sessionName = "Untitled-1"
		local i = 1
		while Editor.SessionsByName[sessionName] do
			i = i + 1
			sessionName = "Untitled-" .. i
		end
	end

	if Editor.SessionsByName[sessionName] then error("Cant create session, name already taken") end
	code = code or ""
	Noir.Debug("CreateSession", sessionName, code)
	local session = {
		name = sessionName,
		code = code,
		file = fileData,
		SavedCode = fileData and code or ""
	}

	session = table.Merge(sessionData or {}, session)
	Editor.MonacoPanel:CreateSession(session)
	table.insert(Editor.Sessions, session)
	Editor.SessionsByName[sessionName] = session
	Editor.Tab.Add(session)
	Editor.Storage.QueueSave()
	return session
end

-- Reopen the most recently closed file (VS Code's Ctrl+Shift+T). Reuses the
-- recent-files history: pick the most recent entry that isn't already open.
-- Scratch/unsaved tabs have no file, so they aren't restored -- same model as
-- "Open Recent".
function Editor.Session.ReopenClosed()
	for _, entry in ipairs(Editor.Config.recentFiles) do
		local path, fileName = entry[1], entry[2]
		local alreadyOpen = false
		for _, v in ipairs(Editor.Sessions) do
			if v.file and v.file[1] == path and v.file[2] == fileName then
				alreadyOpen = true
				break
			end
		end

		if not alreadyOpen then
			Editor.OpenFile(path, fileName)
			return
		end
	end
end

function Editor.Session.Close(sessionName, nextActive, noSave)
	local session = Editor.SessionsByName[sessionName]
	-- Tear down any run channels this session opened: closing the tab is the manual
	-- teardown point (a run's replies live on until then or until disconnect).
	if session and session.runTransfers then
		for id, target in pairs(session.runTransfers) do
			Noir.Environment.CloseRun(id, target)
		end

		session.runTransfers = nil
	end

	-- Closing a file is an interaction too: bump it to the front of recents so
	-- "Reopen Closed Tab" / "Open Recent" reflect close order.
	if session and session.file then Editor.Session.AddRecent(unpack(session.file)) end
	local idx = table.KeyFromValue(Editor.Sessions, session)
	if #Editor.Sessions == 1 then nextActive = Editor.Session.Create().name end
	session.TabPanel:Remove()
	Editor.Tab.Scroller:PerformLayout()
	Editor.Tab.BumpScrollIndicator()
	table.remove(Editor.Sessions, idx)
	Editor.SessionsByName[sessionName] = nil
	if nextActive and Editor.SessionsByName[nextActive] then
		Editor.Tab.SetActive(nextActive)
	else
		Editor.Tab.SetActive(Editor.Sessions[#Editor.Sessions < idx and #Editor.Sessions or idx].name)
	end

	if not Editor.Session.IsPanel(session) then
		-- When the newly active tab is a panel tab (console / SQL), SetActive left
		-- Monaco pointing at the session we're closing. Hand the frontend another
		-- editor session to switch to (it fabricates an "Unnamed" document otherwise)
		-- and flag the resulting OnSessionSet so it doesn't steal the active tab.
		local switchTo
		if Editor.Session.IsPanel(Editor.ActiveSession) then
			for _, v in ipairs(Editor.Sessions) do
				if not Editor.Session.IsPanel(v) then
					switchTo = v.name
					break
				end
			end

			Editor.Tab.SuppressActivate = switchTo
		end

		Editor.MonacoPanel:CloseSession(sessionName, switchTo)
	end
	if noSave then return end
	Editor.Storage.QueueSave()
end

function Editor.Session.Rename(sessionName, newName)
	if sessionName == newName then return end
	if Editor.SessionsByName[newName] then
		error("Cant rename to '" .. sessionName .. "' name already taken")
		return
	end

	if not Editor.SessionsByName[sessionName] then return end
	local session = Editor.SessionsByName[sessionName]
	session.name = newName
	Editor.SessionsByName[sessionName] = nil
	Editor.SessionsByName[newName] = session
	if session.TabPanel then
		session.TabPanel:SetTooltip(session.file and Format("[%s] %s", unpack(session.file)) or session.name)
		session.TabPanel.label:SetText(newName)
	end

	if Editor.ActiveSession == session then
		Editor.Config.activeSession = newName
		Editor.Storage.SaveConfig()
	end

	Editor.MonacoPanel:RenameSession(newName, sessionName)
	Editor.Storage.QueueSave()
end

-- Tab icon per effective ent type. Modified state is shown on the close button
-- (a VSCode-style dot), not the left icon -- so the icon always reflects file type.
Editor.Session.EntIcons = {
	SWEP = "icon16/gun.png",
	SENT = "icon16/brick.png"
}

-- Parse a "--swep [name]" / "--sent [name]" first-line comment. Returns entType,
-- className (className nil when the comment gives only the bare type).
function Editor.Session.ParseEntComment(line)
	if not isstring(line) then return nil end
	local kind, name = string.match(line, "^%s*%-%-%s*(%a+)%s*(%S*)")
	if not kind then return nil end
	kind = string.lower(kind)
	if kind == "swep" then return "SWEP", name ~= "" and name or nil end
	if kind == "sent" then return "SENT", name ~= "" and name or nil end
	return nil
end

-- Effective ent type for a session, in priority order: first-line comment ->
-- manual override (entTypeOverride, "none" = explicitly off) -> file path.
function Editor.Session.GetEntType(session)
	if not session or Editor.Session.IsPanel(session) then return nil end
	local firstLine = string.match(session.code or "", "^[^\n]*")
	local commentType = Editor.Session.ParseEntComment(firstLine)
	if commentType then return commentType end
	local override = session.entTypeOverride
	if override == "none" then return nil end
	if override == "SWEP" or override == "SENT" then return override end
	if session.file then
		local full = string.lower(Noir.Utils.GetFilePath(unpack(session.file)))
		if string.find(full, "weapons/", 1, true) then return "SWEP" end
		if string.find(full, "entities/", 1, true) then return "SENT" end
	end

	return nil
end

-- Class name to register under: comment name -> weapons/<x> or entities/<x> folder
-- -> file base name -> session name (all sans extension).
function Editor.Session.GetEntClass(session)
	if not session then return nil end
	local firstLine = string.match(session.code or "", "^[^\n]*")
	local _, commentName = Editor.Session.ParseEntComment(firstLine)
	if commentName then return commentName end
	if session.file then
		local full = string.lower(Noir.Utils.GetFilePath(unpack(session.file)))
		local seg = string.match(full, "weapons/([%w_]+)") or string.match(full, "entities/([%w_]+)")
		if seg then return seg end
		local base = string.StripExtension(string.GetFileFromFilename(session.file[2] or ""))
		if base ~= "" then return base end
	end

	return string.StripExtension(session.name or "")
end

-- Left-hand tab icon: terminal for the console, database for an SQL tab, gun/brick
-- for SWEP/SENT, else page.
function Editor.Session.IconFor(session)
	if session.sessionType == Editor.SessionType.Console then return "icon16/application_xp_terminal.png" end
	if session.sessionType == Editor.SessionType.SQL then return "icon16/database.png" end
	local entType = Editor.Session.GetEntType(session)
	return (entType and Editor.Session.EntIcons[entType]) or "icon16/page.png"
end

function Editor.Session.Update(sessionName)
	local session = Editor.SessionsByName[sessionName]
	-- Skip icon updates for console tab (always uses terminal icon)
	if session.sessionType == Editor.SessionType.Console then return end
	-- Used to update code here with latest in file but it breaks if switching tabs fast
	if IsValid(session.TabPanel) then
		session.TabPanel:SetTooltip(session.file and Format("[%s] %s", unpack(session.file)) or session.name)
		session.TabPanel.label:SetText(sessionName)
		session.TabPanel.image:SetImage(Editor.Session.IconFor(session))
	end
end

function Editor.Session.CloseTab(sessionName, nextActive, noSave)
	local session = Editor.SessionsByName[sessionName]
	if not session then return end
	if session.Modified then
		Derma_Query("Dou you want to save changes to " .. sessionName .. "?", "Save?", "Save", function()
			Editor.Session.Save(sessionName, function(saved, name)
				if saved then Editor.Session.Close(name, nextActive, noSave) end
			end)
		end, "Dont save", function()
			Editor.Session.Close(sessionName, nextActive, noSave)
		end, "Cancel"):SetSkin("Noir")
	else
		Editor.Session.Close(sessionName, nextActive, noSave)
	end
end

function Editor.Session.GetLanguage(fileName)
	if not Editor.MonacoPanel.Ready then return "plaintext" end
	if fileName:EndsWith(".lua.txt") then return "glua" end
	local file_ext = string.GetExtensionFromFilename(fileName)
	if file_ext then
		file_ext = "." .. file_ext
	else
		return "plaintext"
	end

	if file_ext == ".lua" then return "glua" end
	-- Noir.Editor.MonacoPanel.avaliableLaungages[1].extensions
	for _, v in pairs(Editor.MonacoPanel.avaliableLaungages or {}) do
		for _, ext in pairs(v.extensions or {}) do
			if file_ext == ext then return v.id end
		end
	end
	return "plaintext"
end

function Editor.OpenFile(path, fileName)
	path, fileName = Noir.Utils.FixFilePath(path, fileName)
	for _, v in pairs(Editor.Sessions) do
		if v.file and v.file[1] == path and v.file[2] == fileName then
			Editor.Tab.SetActive(v.name)
			return
		end
	end

	local f = file.Open(fileName, "rb", path)
	if not f then
		Noir.Error("Cant open file ", Color(0, 200, 0), Noir.Utils.GetFilePath(path, fileName), "\n")
		return
	end

	local code = f:Read(f:Size())
	f:Close()
	local name = string.GetFileFromFilename(fileName)
	if Editor.SessionsByName[name] then name = Format("[%s] %s", path, name) end
	if Editor.SessionsByName[name] then name = Format(Noir.Utils.GetFilePath(path, fileName)) end
	Editor.Session.AddRecent(path, fileName)
	local lang = Editor.Session.GetLanguage(fileName)
	Noir.Debug("OpenFile", path, fileName, name)
	return Editor.Session.Create(name, code or "", {path, fileName}, {
		language = lang
	})
end

-- Handle a gmod-file:// URL (e.g. from an OpenURL callback) by opening the
-- referenced file in the editor and jumping to the requested line. The path is
-- a game-root-relative path (leading lua/ or data/ is remapped to the right
-- search path by OpenFile -> FixFilePath). Returns true if the URL was ours.
--
-- Format: gmod-file://open?path=lua%2Farcana%2Fbloom.lua&start=88&end=111
function Editor.OpenFileURL(url)
	local parsed = Noir.Utils.ParseURL(url)
	if not parsed or parsed.scheme ~= "gmod-file" then return false end
	local path = parsed.query.path
	if not path or path == "" then
		Derma_Message("Malformed file link (missing path):\n" .. url, "Cant open file", "Ok"):SetSkin("Noir")
		return true
	end

	if not Noir.Utils.FileExists("GAME", path) then
		Derma_Message("File does not exist:\n" .. path, "Cant open file", "Ok"):SetSkin("Noir")
		return true
	end

	Editor.Show()
	-- Existence is confirmed above, so OpenFile either opens the file or re-activates
	-- an already-open tab (it returns nil in that case, so don't guard on its result).
	Editor.OpenFile("GAME", path)
	-- OpenFile creates or re-activates the tab synchronously; RunJS is FIFO, so the
	-- goto is queued after the session swap and lands on the right model. The
	-- frontend only supports jumping to a single line, so we use the range start.
	local startLine = tonumber(parsed.query.start)
	if startLine then Editor.MonacoPanel:GotoLine(startLine) end
	return true
end

function Editor.Session.SaveAs(sessionName, callback)
	local session
	if not sessionName then
		session = Editor.ActiveSession
		sessionName = session.name
	else
		session = Editor.SessionsByName[sessionName]
	end

	if not session then return end
	if Editor.Session.IsPanel(session) then return end
	local fileName = sessionName
	local extension = string.GetExtensionFromFilename(fileName)
	if not extension then
		fileName = fileName .. ".lua.txt"
	elseif extension ~= "txt" and extension ~= "json" then
		fileName = fileName .. ".txt"
	end

	Noir.FileBrowser.SaveDialog(fileName, function(fullname)
		fullname = fullname:lower()
		Noir.Debug("SaveAs", fullname, session)
		file.Write(fullname, session.code)
		session.file = {"DATA", fullname}
		session.SavedCode = session.code
		session.Modified = false
		local name = string.GetFileFromFilename(fullname)
		if Editor.SessionsByName[name] and Editor.SessionsByName[name] ~= session then name = Format("[%s] %s", "DATA", name) end
		if Editor.SessionsByName[name] and Editor.SessionsByName[name] ~= session then
			name = Format(Noir.Utils.GetFilePath("DATA", fullname))
		end
		-- Renaming the session to the saved file's name keeps the tab label in sync;
		-- Update() then refreshes the tooltip/icon for the (now saved) session.
		Editor.Session.Rename(session.name, name)
		Editor.Session.Update(name)
		Editor.Storage.QueueSave()
		if callback then callback(true, name, fullname) end
	end, function() if callback then callback(false) end end)
end

function Editor.Session.Save(sessionName, callback)
	local session
	if not sessionName then
		session = Editor.ActiveSession
	else
		session = Editor.SessionsByName[sessionName]
	end

	if not session then return end
	if Editor.Session.IsPanel(session) then return end
	if session.file and session.file[1] == "DATA" then
		file.Write(session.file[2], session.code)
		session.SavedCode = session.code
		session.Modified = false
		Editor.Session.Update(session.name)
		if callback then callback(true, sessionName, session.file[2]) end
	else
		Editor.Session.SaveAs(sessionName, callback)
	end
end
