local DB = Noir.DB or {}
Noir.DB = DB

----------------------------------------------------------------------
-- Database backend, shared across realms so the DB browser can query GMod's
-- built-in SQLite database (`sql.Query`) on the local (client) realm or the
-- authoritative server one -- or a specific player's client. A remote query is a
-- Noir channel (no new net string): the client opens a "dbQuery" channel to the
-- target; the target runs the SQL / reads the schema and ships back a serialisable
-- result on the same channel. Opening the channel is superadmin-gated by
-- Network.CheckAccess, so the access check comes for free.
--
-- Like entity search this is a bounded one-shot query, not a streaming job -- the
-- target replies once and the channel is closed (via Network.Request).
----------------------------------------------------------------------

----------------------------------------------------------------------
-- Run one SQL statement in THIS realm and normalise GMod's `sql.Query` return
-- (table of rows / false on error / nil on success-with-no-rows) into a single
-- serialisable shape:
--   { ok, error, rows = {...}, columns = {...}, rowCount, message }
-- Row values are strings (GMod always returns text). `sql.Query` returns each row
-- as a plain key->value dict and DOES NOT preserve column order, so `columns` is
-- derived from the keys and ordered deterministically (id-ish keys first, then
-- alphabetical) rather than reflecting the SELECT's column order.
----------------------------------------------------------------------
function DB.RunQuery(query)
	if not isstring(query) or string.Trim(query) == "" then
		return {ok = false, error = "empty query", rows = {}, columns = {}, rowCount = 0}
	end

	local res = sql.Query(query)
	if res == false then
		return {ok = false, error = sql.LastError() or "unknown SQL error", rows = {}, columns = {}, rowCount = 0}
	end

	-- nil = success with no result set (a non-SELECT statement, or a SELECT that
	-- matched nothing).
	if res == nil then
		return {ok = true, rows = {}, columns = {}, rowCount = 0, message = "OK (no rows)"}
	end

	-- Union the keys across every row (later rows can't add columns in practice, but
	-- be defensive), then order them: rowid/id hoisted to the front, rest alphabetical.
	local columns, seen = {}, {}
	for _, row in ipairs(res) do
		for k in pairs(row) do
			if not seen[k] then
				seen[k] = true
				columns[#columns + 1] = k
			end
		end
	end

	table.sort(columns)
	local function hoist(name)
		for i, c in ipairs(columns) do
			if string.lower(c) == name then
				table.remove(columns, i)
				table.insert(columns, 1, c)
				return
			end
		end
	end

	hoist("rowid")
	hoist("id")

	return {
		ok = true,
		rows = res,
		columns = columns,
		rowCount = #res,
		message = Format("%d row%s", #res, #res == 1 and "" or "s")
	}
end

----------------------------------------------------------------------
-- Read the schema of THIS realm's SQLite database: every user table with its
-- columns (name / declared type / primary-key flag). Returns { tables = { {name,
-- columns = { {name, type, pk}, ... } }, ... } }.
----------------------------------------------------------------------
function DB.GetSchema()
	local tableRows = sql.Query("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name") or {}
	local tables = {}
	for _, row in ipairs(tableRows) do
		local name = row.name
		local info = sql.Query("PRAGMA table_info(" .. sql.SQLStr(name) .. ")") or {}
		local columns = {}
		for _, col in ipairs(info) do
			columns[#columns + 1] = {
				name = col.name,
				type = col.type ~= "" and col.type or nil,
				pk = tonumber(col.pk) or 0
			}
		end

		tables[#tables + 1] = {name = name, columns = columns}
	end

	return {tables = tables}
end

----------------------------------------------------------------------
-- Networking. The target endpoint (server, or a specific player's client) runs the
-- request against its own database and replies on the same channel. No SERVER guard
-- -- a query can legitimately target a specific client -- access is gated by the
-- superadmin check on the channel open.
----------------------------------------------------------------------
Noir.Network.ChannelHandlers["dbQuery"] = {
	open = function(sender, channelId, data)
		local req = util.JSONToTable(data.string) or {}
		local result = req.mode == "schema" and DB.GetSchema() or DB.RunQuery(req.sql)
		-- Defaults to addressing the opener (the requesting client).
		Noir.Network.SendOnChannel(channelId, "result", util.TableToJSON(result))
	end
}

if CLIENT then
	-- Cached schema per target, keyed by TargetKey, so SQL autocomplete can answer
	-- Monaco synchronously (it has a short deadline and a remote schema fetch is a
	-- network round-trip). Populated whenever a schema is fetched (the DB browser
	-- refresh, an autocomplete warm-up, or an explicit prefetch).
	DB.SchemaCache = DB.SchemaCache or {}
	DB.SchemaPending = DB.SchemaPending or {}

	-- Stable string key for a query target ("self" / "server" / a Player).
	local function TargetKey(target)
		if isstring(target) then return target end
		if IsValid(target) and target.EntIndex then return "ply:" .. target:EntIndex() end
		return "self"
	end

	----------------------------------------------------------------------
	-- Run `query` against `target` ("self" / "server" / a Player) and hand the
	-- normalised result table to `onResult`. "self" runs locally and synchronously;
	-- anything else is a one-shot channel request. Returns the request id for remote
	-- targets (nil for "self").
	----------------------------------------------------------------------
	function DB.SendQuery(target, query, onResult)
		if target == "self" then
			onResult(DB.RunQuery(query))
			return
		end

		local payload = util.TableToJSON({mode = "query", sql = query})
		return Noir.Network.Request("dbQuery", target, payload, function(reply)
			onResult(util.JSONToTable(reply) or {ok = false, error = "no reply from target", rows = {}, columns = {}, rowCount = 0})
		end)
	end

	-- Fetch the schema of `target`'s database and cache it. Same self/remote split as
	-- SendQuery. `onResult` is optional (a prefetch just warms the cache).
	function DB.SendSchema(target, onResult)
		local key = TargetKey(target)
		local function deliver(schema)
			DB.SchemaCache[key] = schema
			if onResult then onResult(schema) end
		end

		if target == "self" then
			deliver(DB.GetSchema())
			return
		end

		local payload = util.TableToJSON({mode = "schema"})
		return Noir.Network.Request("dbQuery", target, payload, function(reply)
			deliver(util.JSONToTable(reply) or {tables = {}})
		end)
	end

	-- The most recently fetched schema for `target`, or nil if never fetched.
	function DB.GetCachedSchema(target)
		return DB.SchemaCache[TargetKey(target)]
	end

	-- Warm the schema cache for `target` without a caller. A no-op if the schema is
	-- cached or a fetch is already in flight, so it's safe to call on every keystroke.
	function DB.PrefetchSchema(target)
		local key = TargetKey(target)
		if DB.SchemaCache[key] or DB.SchemaPending[key] then return end
		DB.SchemaPending[key] = true
		DB.SendSchema(target, function() DB.SchemaPending[key] = nil end)
	end

	-- Build a Monaco completion item (see completionProvider.ts DynamicAutocompleteItem)
	-- for a schema column. `tableName` is included in the detail when the column isn't
	-- already scoped to a table by the request.
	local function columnItem(col, tableName)
		-- A completion item MUST have a string label: the Monaco frontend calls
		-- label.toLowerCase() on it, so a nil/empty name would crash the suggest
		-- widget. Skip nameless columns rather than emit a labelless item.
		if not isstring(col.name) or col.name == "" then return nil end
		local detail = col.type or "column"
		if tableName then detail = detail .. " · " .. tableName end
		if (tonumber(col.pk) or 0) > 0 then detail = detail .. " · PK" end
		return {label = col.name, kind = "Field", detail = detail}
	end

	----------------------------------------------------------------------
	-- Turn `target`'s cached schema into Monaco SQL completion items for the given
	-- request `context` (from the frontend's SQLCompletionProvider):
	--   * after `table.` (context.lastChar == "." and fullIdentifier names a table) ->
	--     that table's columns;
	--   * otherwise -> every table name plus each distinct column name.
	-- Returns {} (and kicks off a prefetch) when the schema isn't cached yet.
	----------------------------------------------------------------------
	function DB.BuildCompletions(target, context)
		local schema = DB.GetCachedSchema(target)
		if not schema then
			DB.PrefetchSchema(target)
			schema = DB.GetCachedSchema(target) -- populated synchronously for "self"
			if not schema then return {} end
		end

		local tables = schema.tables or {}
		local items = {}
		local ident = isstring(context.fullIdentifier) and context.fullIdentifier or ""
		if context.lastChar == "." and ident ~= "" then
			local want = string.lower(ident)
			for _, tbl in ipairs(tables) do
				if isstring(tbl.name) and string.lower(tbl.name) == want then
					for _, col in ipairs(tbl.columns or {}) do
						local item = columnItem(col, nil)
						if item then items[#items + 1] = item end
					end

					break
				end
			end

			return items
		end

		local seenCols = {}
		for _, tbl in ipairs(tables) do
			-- Skip a nameless table for the same reason columnItem does (labelless
			-- items crash the Monaco suggest widget).
			if isstring(tbl.name) and tbl.name ~= "" then
				local colCount = #(tbl.columns or {})
				items[#items + 1] = {
					label = tbl.name,
					kind = "Class",
					detail = Format("table · %d column%s", colCount, colCount == 1 and "" or "s")
				}
				for _, col in ipairs(tbl.columns or {}) do
					local item = columnItem(col, tbl.name)
					if item and not seenCols[col.name] then
						seenCols[col.name] = true
						items[#items + 1] = item
					end
				end
			end
		end

		return items
	end
end

return DB
