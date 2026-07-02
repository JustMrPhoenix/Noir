local Editor = Noir.Editor or {}
Noir.Editor = Editor
Editor.Storage = Editor.Storage or {}

-- Seeded into a fresh install (no sessions.json) as the Welcome tab. Kept
-- standard-Lua-parseable: the in-editor luacheck can't lex GLua-only operators
-- (&&, ||, !=), so those are only mentioned in comments. The one lint warning
-- (unusedVariable) is deliberate -- it demos the squiggles.
local WELCOME_CODE = [=[-- Welcome to Noir!
-- This tab is a quick tour of the editor. Press Ctrl+E (or use the Run menu)
-- to run it on yourself -- the output lands in the Main Console tab.

----------------------------------------------------------------------
-- Syntax highlighting
----------------------------------------------------------------------
-- Full GLua highlighting: keywords, every kind of number and string,
-- and GMod's extra operators (&&, || and != highlight too).
local hexNumber = 0xC0FFEE
local exponent = 1.5e2
local escapes = "tabs\tnewlines\nquotes\""
local longString = [[Long-bracket strings
span multiple lines]]

----------------------------------------------------------------------
-- Hover documentation
----------------------------------------------------------------------
-- Hover over a GMod function to get its arguments, return values and
-- wiki documentation. Try hook.Add, timer.Simple, IsValid and :Nick().
hook.Add("Think", "noir_demo", function() end)
hook.Remove("Think", "noir_demo")

timer.Simple(0, function()
	local ply = player.GetAll()[1]
	if IsValid(ply) then
		print("Hello, " .. ply:Nick())
	end
end)

----------------------------------------------------------------------
-- Code folding
----------------------------------------------------------------------
-- Hover over the line numbers and click the arrows to collapse any
-- block -- functions, tables, ifs:
local demo = {
	settings = {
		enabled = true,
		limits = {
			min = 1,
			max = 10,
		},
	},
	describe = function(self)
		local state = self.settings.enabled and "enabled" or "disabled"
		local limits = self.settings.limits
		return string.format("demo %s (%d-%d)", state, limits.min, limits.max)
	end,
}

----------------------------------------------------------------------
-- Linting
----------------------------------------------------------------------
-- luacheck checks the code as you type: problems get squiggly underlines
-- and are listed at the bottom of the editor. The variable below is
-- unused on purpose -- hover its underline:
local unusedVariable = 42

print(demo:describe(), hexNumber + exponent, escapes, longString)]=]

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
		-- Default to a roomy window (up to 1600x900), centered and clamped so it
		-- still fits smaller resolutions with some breathing room.
		local defaultW = math.min(1600, ScrW() - 160)
		local defaultH = math.min(900, ScrH() - 160)
		Editor.Config = {
			recentFiles = {},
			editorPosition = {math.floor((ScrW() - defaultW) / 2), math.floor((ScrH() - defaultH) / 2)},
			editorSize = {defaultW, defaultH},
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

-- First-run check, called from Noir.Load(). A missing config.json means Noir has
-- never run for this user (or noir_clearconfig just wiped everything), so create
-- the default config right away -- that's what makes the greeting one-shot -- and
-- tell the player in chat how to open the editor.
function Editor.Storage.FirstRunCheck()
	if file.Exists(Noir.STORAGE_PATH .. "config.json", "DATA") then return end
	Editor.Storage.LoadConfig()
	local function greet()
		if not LocalPlayer():IsSuperAdmin() then return end
		Noir.PrintChat(
			"Looks like this is your first using Noir! Open the Lua editor with the ",
			Color(83, 187, 208), "noir_showeditor", color_white, " console command."
		)
	end

	if IsValid(LocalPlayer()) then
		-- Mid-session reset (noir_clearconfig): chat is usable right away.
		greet()
	else
		-- Initial load: Noir.Load runs before the player is in-game, so a chat
		-- message sent now would never be seen. Wait for the world, plus a beat
		-- for the HUD to appear.
		hook.Add("InitPostEntity", "NoirFirstRunGreeting", function()
			hook.Remove("InitPostEntity", "NoirFirstRunGreeting")
			timer.Simple(3, greet)
		end)
	end
end

function Editor.Storage.LoadSessions()
	if file.Exists(Noir.STORAGE_PATH .. "sessions.json", "DATA") then
		Editor.Sessions = util.JSONToTable(file.Read(Noir.STORAGE_PATH .. "sessions.json"))
	else
		Noir.Debug("sessions.json does not exist, creating new one")
		-- Fresh start: Main Console as the first tab, the Welcome demo document as
		-- the second. The console-restore path in frame.lua builds the REPL panel
		-- for the console session just like any session loaded from sessions.json.
		Editor.Sessions = {
			{
				name = "Main Console",
				code = "",
				sessionType = "console",
				isMainConsole = true
			},
			{
				code = WELCOME_CODE,
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

-- REPL command history, persisted per language so Lua and JS keep separate
-- histories that survive editor reloads and game restarts. Stored newest-first.
local REPL_HISTORY_FILE = Noir.STORAGE_PATH .. "repl_history.json"
-- The REPL only distinguishes "javascript" from Lua; everything else is glua.
local function NormalizeReplLang(language) return language == "javascript" and "javascript" or "glua" end
function Editor.Storage.LoadReplHistory()
	Editor.ReplHistory = {glua = {}, javascript = {}}
	if not file.Exists(REPL_HISTORY_FILE, "DATA") then return end
	local data = util.JSONToTable(file.Read(REPL_HISTORY_FILE) or "")
	if not istable(data) then return end
	if istable(data.glua) then Editor.ReplHistory.glua = data.glua end
	if istable(data.javascript) then Editor.ReplHistory.javascript = data.javascript end
end

function Editor.Storage.SaveReplHistory()
	file.Write(REPL_HISTORY_FILE, util.TableToJSON(Editor.ReplHistory, Noir.DEBUG))
end

-- Max entries kept per language; read live from the dashboard so limit changes
-- apply immediately.
function Editor.Storage.GetReplHistoryLimit()
	local limit = Noir.Dashboard and Noir.Dashboard.Get("Editor", "replHistoryLimit")
	return isnumber(limit) and limit or 100
end

function Editor.Storage.GetReplHistory(language)
	return Editor.ReplHistory[NormalizeReplLang(language)] or {}
end

function Editor.Storage.AddReplHistory(language, code)
	if Noir.Dashboard and Noir.Dashboard.Get("Editor", "replHistoryPersist") == false then return end
	code = string.Trim(code or "")
	if code == "" then return end
	language = NormalizeReplLang(language)
	local hist = Editor.ReplHistory[language] or {}
	Editor.ReplHistory[language] = hist
	-- Dedup: drop any prior identical entry so the newest use floats to the top.
	for i = #hist, 1, -1 do
		if hist[i] == code then table.remove(hist, i) end
	end

	table.insert(hist, 1, code)
	local limit = Editor.Storage.GetReplHistoryLimit()
	while #hist > limit do table.remove(hist) end
	Editor.Storage.SaveReplHistory()
end

-- Trim every stored history down to the current limit (called when the limit changes).
function Editor.Storage.TrimReplHistory()
	local limit = Editor.Storage.GetReplHistoryLimit()
	for _, hist in pairs(Editor.ReplHistory or {}) do
		while #hist > limit do table.remove(hist) end
	end

	Editor.Storage.SaveReplHistory()
end

Editor.Storage.LoadReplHistory()
