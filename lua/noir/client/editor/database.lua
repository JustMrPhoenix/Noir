local Editor = Noir.Editor or {}
Noir.Editor = Editor
Editor.Database = Editor.Database or {}
Editor.Database.Sessions = Editor.Database.Sessions or {} -- name -> sql session
Editor.Database.Counter = Editor.Database.Counter or 0

--------------------------------------------------------------------------------
-- NoirSqlReplPanel: a NoirReplPanel locked to SQLite. It inherits the whole REPL
-- (input line, output pane, target selector, history) and only layers on the
-- SQL-specific behaviour, so the base REPL stays language-agnostic:
--   * forces the Monaco "sql" model + prompt and hides the Lua/JS selector,
--   * restricts the target selector to a single realm (SingleRealm),
--   * feeds live table/column completions from the target realm's cached DB
--     schema over Monaco's dynamic-completion channel (JS_OnAutocompleteRequest).
--------------------------------------------------------------------------------
local SQLREPL = {}
SQLREPL.Base = "NoirReplPanel"

function SQLREPL:Init()
	self.BaseClass.Init(self)
	self.SingleRealm = true -- FillMenu drops clients/shared: a query hits one DB
	-- The language is fixed to SQL, so hide the Lua/JS language selector.
	if IsValid(self.LanguageCombo) then self.LanguageCombo:SetVisible(false) end

	-- Force the SQL model + prompt and enable dynamic completions once the frontend
	-- is ready. SwitchLanguage from the default glua resets output/history/autocomplete
	-- and swaps the prompt to "sql>".
	local function applySQL()
		if not IsValid(self) then return end
		self:SwitchLanguage("sql")
		self:RunJS("if (replinterface.EnableDynamicAutocomplete) replinterface.EnableDynamicAutocomplete(500)")
	end

	if self.Ready then
		applySQL()
	else
		local prev = self.OnReady
		self.OnReady = function(p)
			if prev then prev(p) end
			applySQL()
		end
	end
end

-- Register the dynamic-completion callback on top of the base REPL's JS callbacks.
function SQLREPL:SetupHTML()
	self.BaseClass.SetupHTML(self)
	self:AddJSCallback("OnAutocompleteRequest")
end

-- Monaco asks for dynamic completions (SQL mode). Answer with table/column names
-- from the target realm's cached DB schema; BuildCompletions warms the cache and
-- returns {} until it's ready, so the frontend falls back to its static list.
function SQLREPL:JS_OnAutocompleteRequest(context, requestId)
	context = context or {}
	local items = context.language == "sql" and Noir.DB.BuildCompletions(self.Target or "self", context) or {}
	local json = #items > 0 and util.TableToJSON(items) or "[]"
	self:RunJS("if (window.replinterface && replinterface.ProvideAutocompleteItems) replinterface.ProvideAutocompleteItems(%d, %s)", requestId, json)
end

vgui.Register("NoirSqlReplPanel", SQLREPL, "NoirReplPanel")

--------------------------------------------------------------------------------
-- The SQL tab: a bespoke per-session panel (like a console) rather than a Monaco
-- document. It hosts a NoirSqlReplPanel for SQL input -- with its OnCode re-pointed
-- at DB queries -- above a DListView that renders the returned rows. A run targets
-- exactly one realm (self / server / a specific player); clients/shared are omitted.
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

	-- SQL-locked REPL, driven as the SQL console. Parented to the divider (SetTop
	-- only positions the child, it doesn't reparent).
	local repl = vgui.Create("NoirSqlReplPanel", divider)
	-- Route a submitted line to our query runner instead of the Lua run channel.
	-- Setting the instance field shadows PANEL:OnCode; JS_OnCode calls self:OnCode.
	repl.OnCode = function(_, code) self:RunSQL(code, true) end
	-- Restore the frame's focus opacity when the REPL DHTML takes focus (otherwise
	-- clicking into it leaves the whole editor dimmed -- the DHTML doesn't inherit
	-- the frame's alpha). Mirrors the console wiring.
	Editor.WireFocusAlpha(repl.HTMLPanel)
	self.ReplPanel = repl
	divider:SetTop(repl)

	self:BuildResults({columns = {}, rows = {}})
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
	-- Warm this realm's schema cache so SQL autocomplete can answer synchronously.
	Noir.DB.PrefetchSchema(target)
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

-- Build (and track) the NoirDatabaseTab panel for `session`, parented to `parent`
-- (defaults to the editor frame) and hidden until activated. Driven by the sql tab
-- type's Build (both live create and session restore). `target` overrides the panel's
-- run realm (defaults to session.target).
function Editor.Database.BuildPanel(session, parent, target)
	parent = parent or Editor.Frame
	if not IsValid(parent) then return end
	local panel = vgui.Create("NoirDatabaseTab", parent)
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

	-- Tab.Open builds the panel via the sql type's Build (Database.BuildPanel), which
	-- targets the persisted session.target string.
	Editor.Tab.Open(session)
	-- A live Player target can't be persisted (session.target stays "self"), so apply
	-- it to the freshly built panel directly.
	if not isstring(target) and IsValid(session.DBPanel) then
		Editor.Database.SetPanelTarget(session.DBPanel, target)
	end

	return session
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

-- The SQL tab type: a bespoke per-session NoirDatabaseTab (REPL + results table),
-- none of the editor capabilities. SQL tabs are transient (see persistence.lua).
Editor.TabTypes.Register(Editor.SessionType.SQL, {
	caps = {},
	Icon = function() return "icon16/database.png" end,
	Build = function(session, parent) Editor.Database.BuildPanel(session, parent, session.target) end,
	Activate = function(session)
		if IsValid(session.DBPanel) then
			session.DBPanel:SetVisible(true)
			session.DBPanel:RequestFocus()
		end
	end,
	Deactivate = function(session)
		if IsValid(session.DBPanel) then session.DBPanel:SetVisible(false) end
	end,
	Destroy = function(session)
		if IsValid(session.DBPanel) then session.DBPanel:Remove() end
		session.DBPanel = nil
		Editor.Database.Sessions[session.name] = nil
	end,
	SetAlpha = function(session, alpha)
		if IsValid(session.DBPanel) and IsValid(session.DBPanel.ReplPanel) then
			session.DBPanel.ReplPanel:SetAlpha(alpha)
		end
	end,
	IsReady = function(session)
		local panel = session.DBPanel
		return not IsValid(panel) or not IsValid(panel.ReplPanel) or panel.ReplPanel.Ready
	end
})

return Editor.Database
