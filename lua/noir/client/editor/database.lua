local Editor = Noir.Editor or {}
Noir.Editor = Editor
Editor.Database = Editor.Database or {}
Editor.Database.Sessions = Editor.Database.Sessions or {} -- name -> sql session
Editor.Database.Counter = Editor.Database.Counter or 0

--------------------------------------------------------------------------------
-- The SQL tab: a bespoke per-session panel (like a console) rather than a Monaco
-- document. It reuses the Monaco REPL for SQL input -- forced to the "sql"
-- language and with its OnCode re-pointed at DB queries -- above a DListView that
-- renders the returned rows. A run targets exactly one realm (self / server / a
-- specific player); clients/shared are omitted (see repl.lua SingleRealm).
--------------------------------------------------------------------------------
local PANEL = {}

function PANEL:Paint(w, h)
	-- Opaque background so the divider bar / margins don't show through to the game.
	surface.SetDrawColor(36, 36, 36)
	surface.DrawRect(0, 0, w, h)
end

function PANEL:Init()
	local divider = vgui.Create("DVerticalDivider", self)
	divider:Dock(FILL)
	divider:SetTopHeight(220)
	divider:SetTopMin(80)
	divider:SetBottomMin(80)
	divider:SetDividerHeight(6)
	self.Divider = divider

	-- Reused REPL, driven as the SQL console. Parented to the divider (SetTop only
	-- positions the child, it doesn't reparent).
	local repl = vgui.Create("NoirReplPanel", divider)
	repl.SingleRealm = true -- FillMenu drops clients/shared for this panel
	-- The language is fixed to SQL, so hide the Lua/JS language selector.
	if IsValid(repl.LanguageCombo) then repl.LanguageCombo:SetVisible(false) end
	-- Route a submitted line to our query runner instead of the Lua run channel.
	-- Setting the instance field shadows PANEL:OnCode; JS_OnCode calls self:OnCode.
	repl.OnCode = function(_, code) self:RunSQL(code, true) end
	-- Restore the frame's focus opacity when the REPL DHTML takes focus (otherwise
	-- clicking into it leaves the whole editor dimmed -- the DHTML doesn't inherit
	-- the frame's alpha, so SetFocusAlpha has to be told). Mirrors the console wiring.
	repl.HTMLPanel.OnFocusChanged = function(_, hasFocus) Editor.SetFocusAlpha(hasFocus) end
	self.ReplPanel = repl
	divider:SetTop(repl)

	self:BuildResults({columns = {}, rows = {}})

	-- Force the SQL model + prompt once the frontend is ready. SwitchLanguage from
	-- the default glua resets output/history/autocomplete and swaps the prompt to
	-- "sql>" (frontend falls back to "<lang>>" for languages without an entry).
	local function applySQL()
		if IsValid(repl) then repl:SwitchLanguage("sql") end
	end

	if repl.Ready then
		applySQL()
	else
		local prev = repl.OnReady
		repl.OnReady = function(p)
			if prev then prev(p) end
			applySQL()
		end
	end
end

function PANEL:RequestFocus()
	if IsValid(self.ReplPanel) then self.ReplPanel:RequestFocus() end
end

-- (Re)build the results DListView with a fresh column set. DListView has no clean
-- "drop all columns" call, so rebuild the whole list each query.
function PANEL:BuildResults(res)
	if IsValid(self.ResultsTable) then self.ResultsTable:Remove() end
	local list = vgui.Create("DListView", self.Divider)
	list:SetSkin("Noir")
	list:SetMultiSelect(false)
	local columns = res.columns or {}
	if #columns == 0 then
		list:AddColumn("result")
	else
		for _, col in ipairs(columns) do
			list:AddColumn(col)
		end
	end

	for _, row in ipairs(res.rows or {}) do
		local cells = {}
		for i, col in ipairs(columns) do
			local v = row[col]
			cells[i] = v == nil and "" or tostring(v)
		end

		list:AddLine(unpack(cells))
	end

	self.ResultsTable = list
	self.Divider:SetBottom(list)
end

-- Run `code` on this tab's target. `asAnswer` closes the REPL's input fold (true
-- when the user typed and submitted the line; false for a programmatic run, where
-- the query is echoed as plain output instead).
function PANEL:RunSQL(code, asAnswer)
	local repl = self.ReplPanel
	code = isstring(code) and code or ""
	if string.Trim(code) == "" then
		if asAnswer then
			repl.AnswerPending = true
			repl:AppendAnswer("")
		end

		return
	end

	-- Record typed submissions in the per-language REPL history (like the Lua/JS
	-- REPL), so Up-arrow recalls them. Programmatic runs (e.g. a tree double-click)
	-- aren't user input, so they're not recorded.
	if asAnswer then
		repl.AnswerPending = true
		Editor.Storage.AddReplHistory(repl.Language or "sql", code)
	end

	local target = repl.Target or "self"
	Noir.DB.SendQuery(target, code, function(res) self:ShowResult(res, asAnswer) end)
end

function PANEL:ShowResult(res, asAnswer)
	res = res or {}
	local repl = self.ReplPanel
	if not IsValid(repl) then return end
	if not res.ok then
		repl:SetStatus("SQL error", Color(150, 0, 0), true)
		local segs = {"--[[sql]] ", Color(230, 120, 120), tostring(res.error or "error"), false}
		if asAnswer then repl:AppendColoredAnswer(segs) else repl:AppendColored(segs) end
		self:BuildResults({columns = {}, rows = {}})
		return
	end

	local count = res.rowCount or 0
	local summary = res.message or Format("%d row%s", count, count == 1 and "" or "s")
	repl:SetStatus(summary, Color(0, 150, 0), true)
	local line = "--[[sql]] " .. summary
	if asAnswer then repl:AppendAnswer(line) else repl:AppendText(line) end
	self:BuildResults(res)
end

vgui.Register("NoirDatabaseTab", PANEL, "DPanel")

--------------------------------------------------------------------------------
-- Session/tab lifecycle. Mirrors Editor.Console: a "sql" session owns a
-- NoirDatabaseTab panel parented to the frame, shown/hidden by Tab.SetContentPanel.
-- SQL tabs are transient (not persisted -- see persistence.lua).
--------------------------------------------------------------------------------

-- Set this tab's run target ("self" / "server" / a Player). Applied to the REPL's
-- Target immediately (so a query fires on the right realm even before the frontend
-- is ready) and reflected in the target combobox once ready.
function Editor.Database.SetPanelTarget(panel, target)
	local repl = panel.ReplPanel
	if not IsValid(repl) then return end
	repl.Target = target -- source of truth for RunSQL, set eagerly
	local function apply()
		if not IsValid(repl) then return end
		if isstring(target) then
			repl:ApplyTarget(target)
		elseif IsValid(target) and target:IsPlayer() then
			repl:SetTarget(target:Nick(), target, target:IsSuperAdmin() and "icon16/user_suit.png" or "icon16/user.png")
		end
	end

	if repl.Ready then
		apply()
	else
		local prev = repl.OnReady
		repl.OnReady = function(p)
			if prev then prev(p) end
			apply()
		end
	end
end

-- Build (and track) the NoirDatabaseTab panel for `session`, parented to the frame
-- and hidden until activated. Shared by CreateTab and the session-restore path in
-- frame.lua. `target` overrides the panel's run realm (defaults to session.target).
function Editor.Database.BuildPanel(session, target)
	if not Editor.Frame then return end
	local panel = vgui.Create("NoirDatabaseTab", Editor.Frame)
	panel:DockMargin(0, 0, -5, -5)
	panel:Dock(FILL)
	panel:SetVisible(false)
	panel.Session = session
	panel.ReplPanel.Session = session
	session.DBPanel = panel
	Editor.Database.Sessions[session.name] = session
	Editor.Database.SetPanelTarget(panel, target or session.target or "self")
	return panel
end

function Editor.Database.CreateTab(name, target)
	target = target or "self"
	if not name then
		Editor.Database.Counter = Editor.Database.Counter + 1
		name = "SQL " .. Editor.Database.Counter
	end

	if Editor.SessionsByName[name] then
		Editor.Tab.SetActive(name)
		return Editor.SessionsByName[name]
	end

	local session = {
		name = name,
		code = "",
		sessionType = Editor.SessionType.SQL,
		SavedCode = "",
		target = isstring(target) and target or "self"
	}

	table.insert(Editor.Sessions, session)
	Editor.SessionsByName[name] = session
	Editor.Database.Sessions[name] = session
	Editor.Tab.Add(session)
	Editor.Database.BuildPanel(session, target)
	return session
end

-- Close an SQL tab: remove its panel, drop tracking, then close the session.
function Editor.Database.Close(sessionName)
	local session = Editor.SessionsByName[sessionName]
	if not session or session.sessionType ~= Editor.SessionType.SQL then return end
	if IsValid(session.DBPanel) then session.DBPanel:Remove() end
	session.DBPanel = nil
	Editor.Database.Sessions[sessionName] = nil
	Editor.Session.Close(sessionName)
end

-- Create and focus a brand-new SQL tab on `target`. Used by the menu / sidebar
-- "New SQL Tab" entries.
function Editor.Database.NewTab(target)
	Editor.Show()
	local session = Editor.Database.CreateTab(nil, target)
	Editor.Tab.SetActive(session.name)
	return session
end

-- The SQL tab to reuse for a query: the active one if it's an SQL tab, else the
-- first open SQL tab, else nil (caller creates one).
function Editor.Database.GetReuseSession()
	if Editor.ActiveSession and Editor.ActiveSession.sessionType == Editor.SessionType.SQL then
		return Editor.ActiveSession
	end

	for _, s in ipairs(Editor.Sessions) do
		if s.sessionType == Editor.SessionType.SQL then return s end
	end
end

-- Run `query` for `target` in an SQL tab, reusing an existing one (opening one only
-- if none is open) and pointing it at `target`, then echoing + running the query.
-- Used by the schema tree's double-click-a-table action.
function Editor.Database.OpenQueryTab(target, query, runNow)
	Editor.Show()
	local session = Editor.Database.GetReuseSession() or Editor.Database.CreateTab(nil, target)
	Editor.Tab.SetActive(session.name)
	local panel = session.DBPanel
	if IsValid(panel) and target then Editor.Database.SetPanelTarget(panel, target) end
	if runNow and IsValid(panel) and isstring(query) then
		panel.ReplPanel:AppendText("-- " .. query)
		panel:RunSQL(query, false)
	end

	return session
end

return Editor.Database
