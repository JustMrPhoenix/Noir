--[[============================================================================
	EXAMPLE -- a custom Noir editor tab type. NOT loaded by Noir.

	This file is intentionally left out of noir_init.lua's loadModule() list, so it
	never runs on its own. It's a copy-paste template for adding a brand-new tab kind
	to the Noir editor (the "regular vgui panel" case; a 50/50 split would follow the
	same shape with two child panels).

	To try it live, paste the body below into the REPL (Run on self) once the editor
	is open, or add `loadModule("examples/tab_type_vgui.lua")` after the editor modules
	in Noir.Load(). Then run:  Noir.Editor.OpenExampleTab()

	The three built-in tab types (editor / console / sql) are themselves registered
	exactly like this -- see client/editor/sessions.lua, console.lua, database.lua.
==============================================================================]]--

local Editor = Noir.Editor

-- 1) Give the type a stable id. It's stored on the session as `sessionType` and in
--    sessions.json, so keep it constant once shipped. Bespoke types like this one are
--    transient by default (nothing here opts them into persistence), which is fine for
--    a scratch panel.
local TAB_TYPE = "example_vgui"

-- 2) Register the type. `caps` are all-or-nothing booleans; anything omitted defaults
--    to false. A plain vgui panel isn't a Monaco document, so it opts out of every
--    editor capability -- which is what makes the tab strip, run path, save/rename
--    menus, entity-type menu, and modified-dot all skip it automatically.
Editor.TabTypes.Register(TAB_TYPE, {
	-- Left-hand tab icon. Return a value per-session if it should vary.
	Icon = function(_session) return "icon16/bug.png" end,

	caps = {
		monaco   = false, -- not the shared Monaco document -> owns a per-session panel
		file     = false, -- no Save / Save As / Copy Path / Autorun
		run      = false, -- Ctrl+E / the Run menu are a no-op on this tab
		rename   = false, -- double-click doesn't rename
		entType  = false, -- no SWEP/SENT entity-type menu
		modified = false  -- close button shows a plain X, never the unsaved dot
	},

	-- OPTIONAL: restrict which realms a run-capable tab may run on. Only consulted when
	-- caps.run is true; omit it entirely to allow every realm (what the editor type
	-- does). `target` is a realm string ("self"/"server"/"shared"/"clients") or a
	-- specific-client Player. The run path rejects disallowed targets and the Run menu
	-- greys them out. A server-only tab would set caps.run = true and:
	--   CanRunOn = function(target) return target == "server" end,

	-- Build the per-session content panel, parented to the editor frame and hidden
	-- until the tab is activated. Called by Editor.Tab.Open (live create) and by the
	-- restore loop in frame.lua. Stash the panel on the session so the other hooks can
	-- find it; Noir strips it (and any *Panel/runChannels field) from the saved JSON.
	Build = function(session, parent)
		if not IsValid(parent) then return end
		local panel = vgui.Create("DPanel", parent)
		panel:DockMargin(0, 0, -5, -5)
		panel:Dock(FILL)
		panel:SetVisible(false)
		panel.Paint = function(_, w, h)
			surface.SetDrawColor(36, 36, 36)
			surface.DrawRect(0, 0, w, h)
			draw.SimpleText("Hello from " .. session.name, "DermaLarge", w / 2, h / 2, color_white, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
		end

		session.ExamplePanel = panel
		return panel
	end,

	-- Show the panel and give it focus when the tab becomes active.
	Activate = function(session)
		if IsValid(session.ExamplePanel) then
			session.ExamplePanel:SetVisible(true)
			session.ExamplePanel:RequestFocus()
		end
	end,

	-- Hide the panel when another tab is activated. Called on every non-active session,
	-- so guard with IsValid.
	Deactivate = function(session)
		if IsValid(session.ExamplePanel) then session.ExamplePanel:SetVisible(false) end
	end,

	-- Tear down on close.
	Destroy = function(session)
		if IsValid(session.ExamplePanel) then session.ExamplePanel:Remove() end
		session.ExamplePanel = nil
	end,

	-- OPTIONAL hooks below -- omit any you don't need.

	-- Fade the panel with the frame when it loses focus (only needed for DHTML panels
	-- that don't inherit the frame's alpha; a plain DPanel does, so this is illustrative).
	SetAlpha = function(session, alpha)
		if IsValid(session.ExamplePanel) then session.ExamplePanel:SetAlpha(alpha) end
	end,

	-- Gate the editor's loading overlay on this panel being ready. Return true when
	-- there's nothing to wait for.
	IsReady = function(_session) return true end,

	-- Contribute extra items to the tab's right-click menu. Items are removed and
	-- re-added on each open, so just add unconditionally.
	ContextMenu = function(menu, session)
		Noir.Utils.AddMenuOption(menu, "Say hi", function()
			Noir.Msg("Hi from ", session.name, "\n")
		end, "icon16/emoticon_smile.png")
	end
})

-- 3) Open a tab of this type. Build the session table (must have a unique `name` and
--    `sessionType = TAB_TYPE`) and hand it to Editor.Tab.Open -- the single creation
--    path that registers the session, builds its panel via the type's Build, and adds
--    the tab-strip button. Then activate it.
function Editor.OpenExampleTab()
	Editor.Show()
	local name = "Example"
	local i = 1
	while Editor.SessionsByName[name] do
		i = i + 1
		name = "Example-" .. i
	end

	local session = Editor.Tab.Open({
		name = name,
		code = "",
		sessionType = TAB_TYPE,
		SavedCode = ""
	})

	Editor.Tab.SetActive(session.name)
	return session
end
