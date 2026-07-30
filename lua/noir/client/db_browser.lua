local DBBrowser = Noir.DBBrowser or {}
Noir.DBBrowser = DBBrowser

--------------------------------------------------------------------------------
-- Database schema browser: a tree of tables -> columns for a chosen realm
-- (Local / Server / a specific player). Hosted two ways, like the Entity Search:
-- as the "database" sidebar view and, via its right-click "Open in Window", as a
-- standalone DFrame. Double-clicking a table opens an SQL tab and runs a SELECT.
--------------------------------------------------------------------------------
local PANEL = {}

function PANEL:Init()
	self.Realm = "self"

	local combo = vgui.Create("DComboBox", self)
	combo:Dock(TOP)
	combo:DockMargin(4, 4, 4, 0)
	combo:SetSkin("Noir")
	combo:SetSortItems(false)
	combo.OnSelect = function(_, _, _, data)
		self.Realm = data
		self:Refresh()
	end

	self.RealmCombo = combo
	self:PopulateRealms()
	-- The tree is owned by Populate() (built on each Refresh); Init only kicks off
	-- the first fetch. (Creating a tree here too would leave an orphan behind the
	-- one Populate makes -- that was the "double text".)
	self:Refresh()
end

-- Fill the realm selector: Local, Server, then one entry per human player. Player
-- entries store the Player as the choice data (the query target). Set the shown
-- value directly (not via AddChoice's select flag) so this doesn't fire OnSelect
-- and re-enter Refresh while building.
function PANEL:PopulateRealms()
	local combo = self.RealmCombo
	combo:Clear()
	combo:AddChoice("Local", "self")
	combo:AddChoice("Server", "server")
	for _, ply in ipairs(player.GetHumans()) do
		combo:AddChoice(ply:Nick(), ply)
	end

	if self.Realm == "self" then
		combo:SetValue("Local")
	elseif self.Realm == "server" then
		combo:SetValue("Server")
	elseif IsValid(self.Realm) and self.Realm:IsPlayer() then
		combo:SetValue(self.Realm:Nick())
	end
end

function PANEL:GetRealm()
	return self.Realm or "self"
end

function PANEL:Refresh()
	if self.PendingSchema then
		Noir.Network.CancelRequest(self.PendingSchema)
		self.PendingSchema = nil
	end

	self.PendingSchema = Noir.DB.SendSchema(self:GetRealm(), function(schema)
		self.PendingSchema = nil
		if IsValid(self) then self:Populate(schema) end
	end)
end

-- Rebuild the tree from a schema { tables = { {name, columns}, ... } }. DTree has
-- no reliable clear, so recreate the whole tree each refresh.
function PANEL:Populate(schema)
	if IsValid(self.Tree) then self.Tree:Remove() end
	local tree = vgui.Create("DTree", self)
	tree:Dock(FILL)
	tree:DockMargin(4, 4, 4, 4)
	tree:SetSkin("Noir")
	self.Tree = tree

	local tables = (schema or {}).tables or {}
	if #tables == 0 then
		tree:AddNode("(no tables)", "icon16/database.png")
		return
	end

	for _, tbl in ipairs(tables) do
		local node = tree:AddNode(tbl.name, "icon16/database_table.png")
		-- Stashed for the tree-level double-click handler below (node-level
		-- DoDoubleClick doesn't fire on DTree -- the root dispatches it).
		node.TableName = tbl.name
		for _, col in ipairs(tbl.columns or {}) do
			local pk = (tonumber(col.pk) or 0) > 0
			local label = col.name .. (col.type and (" : " .. col.type) or "")
			node:AddNode(label, pk and "icon16/key.png" or "icon16/bullet_black.png")
		end
	end

	tree.DoDoubleClick = function(_, node)
		if not node or not node.TableName then return end
		Noir.Editor.Database.OpenQueryTab(self:GetRealm(), Format("SELECT * FROM %s LIMIT 50", node.TableName), true)
	end

	-- Right-click a table node -> context menu. Like DoDoubleClick, DTree dispatches
	-- the right-click at the root (node-level handlers don't fire); `node` is the
	-- clicked DTree_Node.
	tree.DoRightClick = function(_, node)
		if not node or not node.TableName then return end
		self:OpenNodeMenu(node)
	end
end

-- Row-limit choices for the "Select from <table>" submenu. `false` means no LIMIT
-- clause (every row).
local SELECT_LIMITS = {10, 25, 50, 100, 500, 1000, false}

-- Build and open the right-click menu for a table node. Currently one entry: a
-- "Select from <table>" submenu whose choices each open an SQL tab on this realm
-- and run `SELECT * FROM <table> [LIMIT n]`.
function PANEL:OpenNodeMenu(node)
	local tableName = node.TableName
	local menu = DermaMenu()
	menu:SetSkin("Noir")

	local submenu, option = menu:AddSubMenu("Select from " .. tableName)
	option:SetIcon("icon16/database_go.png")
	option:SetTextColor(Color(200, 200, 200))
	submenu:SetSkin("Noir")
	for _, limit in ipairs(SELECT_LIMITS) do
		local label = limit and ("LIMIT " .. limit) or "All rows"
		local query = limit and Format("SELECT * FROM %s LIMIT %d", tableName, limit) or Format("SELECT * FROM %s", tableName)
		Noir.Utils.AddMenuOption(submenu, label, function()
			Noir.Editor.Database.OpenQueryTab(self:GetRealm(), query, true)
		end, "icon16/table.png")
	end

	menu:Open()
end

function PANEL:OnRemove()
	if self.PendingSchema then Noir.Network.CancelRequest(self.PendingSchema) end
end

vgui.Register("NoirDBTree", PANEL, "DPanel")

--------------------------------------------------------------------------------
-- Standalone window (the sidebar view's pop-out).
--------------------------------------------------------------------------------
function DBBrowser.Open()
	if IsValid(DBBrowser.Frame) then DBBrowser.Frame:Remove() end
	local frame = Noir.Utils.CreateNoirWindow("Database Browser", 360, 520)

	local content = vgui.Create("NoirDBTree", frame)
	content:Dock(FILL)
	content:DockMargin(4, 26, 4, 4)
	frame.Content = content

	frame.OnRemove = function() DBBrowser.Frame = nil end
	DBBrowser.Frame = frame
	return frame
end

--------------------------------------------------------------------------------
-- Sidebar view, registered like the Explorer / Entity Search.
--------------------------------------------------------------------------------
if Noir.Editor and Noir.Editor.Sidebar then
	Noir.Editor.Sidebar.RegisterView("database", {
		title = "Database",
		icon = "icon16/database.png",
		tooltip = "Database Browser",
		popout = function() DBBrowser.Open() end,
		actions = {
			{
				icon = "icon16/arrow_refresh.png",
				tooltip = "Refresh",
				onClick = function()
					local def = Noir.Editor.Sidebar.Views["database"]
					if def and IsValid(def.panel) then def.panel:Refresh() end
				end
			},
			{
				icon = "icon16/database_add.png",
				tooltip = "New SQL tab on this realm",
				onClick = function()
					local def = Noir.Editor.Sidebar.Views["database"]
					local realm = (def and IsValid(def.panel)) and def.panel:GetRealm() or "self"
					Noir.Editor.Database.NewTab(realm)
				end
			}
		},
		build = function(container)
			local panel = vgui.Create("NoirDBTree", container)
			return panel
		end
	})
end

return DBBrowser
