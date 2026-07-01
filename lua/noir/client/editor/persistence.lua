local Editor = Noir.Editor or {}
Noir.Editor = Editor
Editor.Storage = Editor.Storage or {}

function Editor.Storage.QueueSave()
	Editor.MonacoPanel.OnSessions = function(_, sessions)
		Editor.Run.UpdateCOH()
		Editor.Storage.SaveJS(sessions)
	end

	Editor.MonacoPanel:GetSessions()
end

function Editor.Storage.SaveJS(jsSessionsData)
	local sessions = table.Copy(Editor.Sessions)
	local sessionsByName = {}
	for _, v in pairs(sessions) do
		sessionsByName[v.name] = v
	end

	for _, v in pairs(jsSessionsData) do
		if sessionsByName[v.name] then
			local session = sessionsByName[v.name]
			table.Merge(session, v)
			table.Merge(Editor.SessionsByName[v.name], v)
			session.SavedCode = nil
			if session.file and not session.Modified then session.code = nil end
		end
	end

	file.Write(Noir.STORAGE_PATH .. "sessions.json", util.TableToJSON(sessions, Noir.DEBUG))
end

function Editor.Storage.LoadConfig()
	if file.Exists(Noir.STORAGE_PATH .. "config.json", "DATA") then
		Editor.Config = util.JSONToTable(file.Read(Noir.STORAGE_PATH .. "config.json"))
	else
		Noir.Debug("config.json does not exist, creating new one")
		Editor.Config = {
			recentFiles = {},
			editorPosition = {100, 100},
			editorSize = {700, 700},
			activeSession = "Welcome",
			sidebarVisible = true,
			sidebarWidth = 320,
			activeSidebarView = "explorer"
		}

		if Noir.DEBUG then
			Editor.Config.recentFiles = {{"GAME", "gameinfo.txt"}, {"LUA", "includes/init.lua"}, {"DATA", Noir.STORAGE_PATH .. "config.json"}}
		end
		Editor.Storage.SaveConfig()
	end
end

function Editor.Storage.SaveConfig()
	file.Write(Noir.STORAGE_PATH .. "config.json", util.TableToJSON(Editor.Config, Noir.DEBUG))
end

function Editor.Storage.LoadSessions()
	if file.Exists(Noir.STORAGE_PATH .. "sessions.json", "DATA") then
		Editor.Sessions = util.JSONToTable(file.Read(Noir.STORAGE_PATH .. "sessions.json"))
	else
		Noir.Debug("sessions.json does not exist, creating new one")
		Editor.Sessions = {
			{
				code = "-- Welcome to Noir lua editor!\n-- I hope you like my shitcode ~~",
				name = "Welcome"
			}
		}

		Editor.Storage.SaveSessions()
	end

	Editor.SessionsByName = {}
	for _, v in pairs(Editor.Sessions) do
		Editor.SessionsByName[v.name] = v
		if v.file then
			if file.Exists(v.file[2], v.file[1]) then
				v.SavedCode = file.Read(v.file[2], v.file[1])
				if not v.Modified then v.code = v.SavedCode end
			else
				v.file = nil
				v.code = "-- File does not exists anymore :c"
			end
		else
			v.SavedCode = ""
		end
	end
end

function Editor.Storage.SaveSessions()
	file.Write(Noir.STORAGE_PATH .. "sessions.json", util.TableToJSON(Editor.Sessions, Noir.DEBUG))
end
