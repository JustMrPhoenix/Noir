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

	-- Fetch the schema of `target`'s database. Same self/remote split as SendQuery.
	function DB.SendSchema(target, onResult)
		if target == "self" then
			onResult(DB.GetSchema())
			return
		end

		local payload = util.TableToJSON({mode = "schema"})
		return Noir.Network.Request("dbQuery", target, payload, function(reply)
			onResult(util.JSONToTable(reply) or {tables = {}})
		end)
	end
end

return DB
