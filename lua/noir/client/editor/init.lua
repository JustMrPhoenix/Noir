local Editor = Noir.Editor or {}
Noir.Editor = Editor
Editor.IsReady = false
Editor.Sessions = Editor.Sessions or {}
Editor.SessionsByName = Editor.SessionsByName or {}
Editor.PendingOnReady = {} -- Actions queued until editor is ready

-- Tab/session kinds. Editor = a Monaco document; Console = a REPL panel; SQL = a
-- database query tab. The string values are what's stored on a session and in
-- sessions.json, so they must stay stable. Console/SQL are "panel" sessions -- they
-- own a bespoke per-session panel rather than a Monaco model (Editor.Session.IsPanel).
Editor.SessionType = {
	Editor = "editor",
	Console = "console",
	SQL = "sql"
}

-- Tab-type registry. Each tab kind (editor / console / sql, plus any future type)
-- registers a def describing what it *is* -- its icon, its capabilities, and its
-- content-panel lifecycle -- so the rest of the editor never branches on
-- `sessionType ==`. Modelled on Editor.Sidebar.RegisterView. A def looks like:
--   Icon       function(session) -> string      -- left tab icon
--   caps       table   -- booleans (default false); replace every IsPanel/type check:
--                monaco   content is the shared Monaco panel (multiplexed via SetSession);
--                         false => a bespoke per-session panel
--                file     file-backed: Save / Save As / Copy Path / Autorun apply
--                run      participates in Editor.Run.Code
--                rename   double-click / menu rename allowed
--                entType  SWEP/SENT entity-type menu applies
--                modified close button shows the VSCode "unsaved" dot
--   Build      function(session, parent)         -- create the per-session panel (both
--                                                   incremental create and restore);
--                                                   no-op body for the shared Monaco type
--   Activate   function(session)                 -- show content + focus
--   Deactivate function(session)                 -- hide content
--   Destroy    function(session)                 -- teardown on close
--   SetAlpha   function(session, alpha)  optional -- fade the focused panel
--   IsReady    function(session) -> bool optional -- panel-ready gate for the loading overlay
--   ContextMenu function(menu, session) optional  -- contribute extra tab-context-menu items
--   CanRunOn   function(target) -> bool  optional -- restrict which run realms are allowed
--                (only meaningful when caps.run is set). `target` is a realm string
--                ("self"/"server"/"shared"/"clients") or a specific-client Player.
--                Absent => every realm is allowed. e.g. a server-only tab returns
--                `target == "server"`.
Editor.TabTypes = Editor.TabTypes or {}
Editor.TabTypes.Registry = Editor.TabTypes.Registry or {}
function Editor.TabTypes.Register(id, def)
	def.id = id
	def.caps = def.caps or {}
	Editor.TabTypes.Registry[id] = def
end

-- Can a session run its code on `target`? False for types that don't run at all
-- (caps.run unset) or that restrict realms via CanRunOn. Used by the run path and to
-- grey out disallowed realms in the Run menu.
function Editor.TabTypes.CanRunOn(session, target)
	local def = Editor.TabTypes.Get(session)
	if not def.caps.run then return false end
	if def.CanRunOn then return def.CanRunOn(target) end
	return true
end

-- Resolve a session (or a bare type id) to its def. Unknown types fall back to the
-- editor type, which is the safe legacy default (treat as a Monaco document).
function Editor.TabTypes.Get(session)
	local id = istable(session) and (session.sessionType or Editor.SessionType.Editor) or session
	return Editor.TabTypes.Registry[id] or Editor.TabTypes.Registry[Editor.SessionType.Editor]
end

function Editor.RegisterActions(panel)
	panel:AddAction("fileNew", "File: New File", function() Editor.Session.Create() end, "Mod.CtrlCmd | Key.KeyN")
	panel:AddAction("fileOpen", "File: Open File...", function() Noir.FileBrowser.Open(true) end, "Mod.CtrlCmd | Key.KeyO")
	panel:AddAction("fileReopenClosed", "File: Reopen Closed Editor", function() Editor.Session.ReopenClosed() end, "Mod.CtrlCmd | Mod.Shift | Key.KeyT")
	panel:AddAction("fileSave", "File: Save", function() Editor.Session.Save() end, "Mod.CtrlCmd | Key.KeyS")
	panel:AddAction("fileSaveAs", "File: Save As...", function() Editor.Session.SaveAs() end, "Mod.CtrlCmd | Mod.Shift | Key.KeyS")
	panel:AddAction("sessionClose", "Close tab", function()
		if not Editor.ActiveSession then return end
		Editor.Session.CloseTab(Editor.ActiveSession.name)
	end, "Mod.CtrlCmd | Key.KeyW")

	panel:AddAction("runOnSelf", "Lua: Run on self", function() Editor.Run.Code("self") end)
	panel:AddAction("runOnServer", "Lua: Run on server", function() Editor.Run.Code("server") end)
	panel:AddAction("runOnShared", "Lua: Run on shared", function() Editor.Run.Code("shared") end)
	panel:AddAction("runOnClients", "Lua: Run on clients", function() Editor.Run.Code("clients") end)
	panel:AddAction("quickRun", "Lua: Run on last target", function() Editor.Run.Code(Editor.Run.LastTarget or "self") end, "Mod.CtrlCmd | Key.KeyE")
	panel:AddAction("cycleTabs", "Cycle tabs", function() Editor.Tab.Cycle(1) end, "Mod.CtrlCmd | Key.Tab")
	panel:AddAction("cycleTabsBack", "Cycle tabs (reverse)", function() Editor.Tab.Cycle(-1) end, "Mod.CtrlCmd | Mod.Shift | Key.Tab")
	for i = 1, 9 do
		panel:AddAction("switchToTab" .. i, "Switch to tab " .. i, function() Editor.Tab.SwitchTo(i) end, "Mod.Alt | Key.Digit" .. i)
	end

	-- Only meaningful on REPL/console panels (guarded by capability so it's a no-op
	-- on the Monaco editor panel, which shares this action registration).
	panel:AddAction("replSwitchJS", "Console: Switch to JavaScript", function(p)
		if p.SwitchLanguage then p:SwitchLanguage("javascript") end
	end, "Mod.CtrlCmd | Mod.Alt | Key.KeyJ")

	-- REPL-only: wipe the persisted command history for this console's current
	-- language (Lua / JavaScript / SQL) and refresh the frontend so Up-arrow no
	-- longer offers the cleared entries. Gated on LoadHistory so it's a no-op on
	-- the Monaco editor panel.
	if panel.LoadHistory then
		panel:AddAction("replClearHistory", "Console: Clear command history", function(p)
			local removed = Editor.Storage.ClearReplHistory(p.Language)
			p:LoadHistory()
			if p.SetStatus then p:SetStatus("Cleared " .. removed .. " history entries", Color(150, 100, 0), true) end
		end)
	end

	-- REPL-only: Tab cycles the run target, but only on an empty input line (the
	-- `replInputEmpty` precondition falls through to Monaco's default Tab otherwise).
	-- Gated on CycleTarget so plain Tab is never bound on the Monaco editor panel.
	if panel.CycleTarget then
		panel:AddAction("cycleReplTarget", "Console: Cycle run target",
			function(p) p:CycleTarget(1) end, "Key.Tab", "replInputEmpty")
		panel:AddAction("cycleReplTargetBack", "Console: Cycle run target (reverse)",
			function(p) p:CycleTarget(-1) end, "Mod.Shift | Key.Tab", "replInputEmpty")
	end
	panel:AddAction("newConsole", "Noir: New Console Tab", function()
		local session = Editor.Console.CreateTab()
		Editor.Tab.SetActive(session.name)
	end, "Mod.CtrlCmd | Mod.Shift | Key.Backquote")
	panel:AddAction("toggleConsole", "Noir: Toggle Console Tab", function() Editor.Console.Toggle() end, "Mod.CtrlCmd | Mod.Shift | Key.KeyC")
	panel:AddAction("toggleSidebar", "View: Toggle Sidebar", function() Editor.Sidebar.Toggle() end, "Mod.CtrlCmd | Key.KeyB")
	panel:AddAction("runAutorun", "Noir: Run Autorun Scripts", function() if Noir.Autorun then Noir.Autorun.RunAll() end end)
	panel:AddAction("openEntitySelector", "Noir: Show Entity Search", function() Editor.Sidebar.ActivateView("entitysearch") end, "Mod.CtrlCmd | Mod.Shift | Key.KeyE")
	panel:AddAction("openDashboard", "Noir: Open Dashboard", function() Noir.Dashboard.Show() end, "Mod.CtrlCmd | Mod.Shift | Key.KeyD")
	panel:AddAction("openFindInFiles", "Noir: Find in Files", function() Noir.FileSearch.UI.Show() end, "Mod.CtrlCmd | Mod.Shift | Key.KeyF")
end

function Editor.Show()
	if coh then coh.StartChat() end
	if IsValid(Editor.Frame) then
		Editor.Frame:Show()
		Editor.Frame:MakePopup()
		return
	end

	Editor.UI.CreateFrame()
end

-- Persistent, off-by-default. When enabled, the editor frame is built hidden on load
-- (see Editor.Preload) so the Monaco DHTML page is warm before the first open.
Editor.PreloadConvar = CreateConVar("noir_preload", "0", FCVAR_ARCHIVE, "Silently preload the Noir editor in the background on load to warm the Monaco page", 0, 1)

-- Build the editor frame but keep it hidden, purely to preload the DHTML page. No-op
-- if a frame already exists (whether preloaded or shown).
function Editor.Preload()
	if IsValid(Editor.Frame) then return end
	Editor.UI.CreateFrame(true)
end

-- Preload immediately when the convar is flipped on at runtime, so users don't have to
-- reload to get a warm editor.
cvars.AddChangeCallback("noir_preload", function(_, _, new)
	if tobool(new) then Editor.Preload() end
end, "noirPreloadToggle")

-- Register the Editor's settings in the Dashboard. Called from Noir.Load() after the
-- dashboard module is available (editor.lua itself loads before dashboard.lua).
function Editor.RegisterDashboard()
	if not Noir.Dashboard then return end
	-- Unregister first so a reload doesn't stack duplicate OnChange callbacks.
	if Editor.DashboardRegistered then Noir.Dashboard.Unregister("Editor") end
	Noir.Dashboard.Register("Editor", {
		{
			key = "sidebarFollowFile",
			type = "bool",
			label = "Sidebar follows active file",
			description = "Switch the explorer root to where the active file lives (DATA / LUA / GAME) and scroll to it. When off, the explorer always shows the default root below.",
			category = "Explorer",
			default = true
		},
		{
			key = "sidebarDefaultPath",
			type = "dropdown",
			label = "Default root folder",
			description = "Root folder shown when no file is open, or when 'follows active file' is off.",
			category = "Explorer",
			default = "DATA",
			options = {
				{
					label = "Data (garrysmod/data)",
					value = "DATA"
				},
				{
					label = "Lua",
					value = "LUA"
				},
				{
					label = "Game (garrysmod)",
					value = "GAME"
				}
			}
		},
		{
			key = "replHistoryPersist",
			type = "bool",
			label = "Remember REPL history",
			description = "Save console/REPL command history between sessions. Lua and JavaScript keep separate histories.",
			category = "REPL",
			default = true
		},
		{
			key = "replHistoryLimit",
			type = "number",
			label = "Max history entries",
			description = "How many past commands to keep per language. Oldest entries are dropped once the limit is reached.",
			category = "REPL",
			default = 100,
			min = 1,
			max = 10000
		}
	}, {
		icon = "icon16/application_side_tree.png",
		description = "Editor and file explorer settings"
	})

	-- Re-navigate the sidebar immediately when either setting changes.
	local function refresh() Editor.Sidebar.NavigateToActive(true) end
	Noir.Dashboard.OnChange("Editor", "sidebarFollowFile", refresh)
	Noir.Dashboard.OnChange("Editor", "sidebarDefaultPath", refresh)
	-- Trim stored history right away when the cap is lowered.
	Noir.Dashboard.OnChange("Editor", "replHistoryLimit", function() Editor.Storage.TrimReplHistory() end)
	Editor.DashboardRegistered = true
end

concommand.Add("noir_clearconfig", function()
	file.Delete(Noir.STORAGE_PATH .. "config.json")
	file.Delete(Noir.STORAGE_PATH .. "sessions.json")
	file.Delete(Noir.STORAGE_PATH .. "dashboard.json")
	file.Delete(Noir.STORAGE_PATH .. "autorun.json")
	Editor.Config = nil
	Editor.Sessions = {}
	Editor.SessionsByName = {}
	Noir.Reload()
end)

-- if Noir.DEBUG then
--     if IsValid(Editor.Frame) then
--         Editor.Frame:Remove()
--     end
--     Editor.Show()
-- end
concommand.Add("noir_showeditor", function(ply, cmd, args) Editor.Show() end)
hook.Add("Think", "NoirEditorClose", function(self)
	if not input.IsKeyDown(KEY_ESCAPE) then return end
	if Noir.Editor.Frame and Noir.Editor.Frame:IsVisible() then
		Noir.Editor.Frame:Hide()
		if coh then coh.FinishChat() end
		gui.HideGameUI()
	end
end)
