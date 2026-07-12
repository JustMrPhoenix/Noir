local EntitySearch = Noir.EntitySearch or {}
Noir.EntitySearch = EntitySearch

----------------------------------------------------------------------
-- Entity search backend, shared across realms so the Entity Selector can query
-- both the local (client) entity list and the authoritative server one. A remote
-- search is a Noir channel (no new net string): the client opens an "entitySearch"
-- channel to the server; the server gathers matching entities and ships back a
-- serialisable descriptor list on the same channel. Opening the channel is
-- superadmin-gated by Network.CheckAccess, so the access check comes for free.
--
-- Unlike file search this is a bounded one-shot query, not a streaming job -- the
-- server replies once and the channel is closed.
----------------------------------------------------------------------

EntitySearch.DEFAULTS = {
	maxResults = 4000 -- cap so a busy server can't flood a reply
}

----------------------------------------------------------------------
-- Glob-ish matcher: `*` is a wildcard, matched case-insensitively as a substring
-- (mirrors the old entity_selector behaviour). Empty pattern matches everything.
----------------------------------------------------------------------
local function matchesPattern(text, pattern)
	if not pattern or pattern == "" then return true end
	local luaPattern = string.gsub(pattern, "%*", ".*")
	return string.match(string.lower(text or ""), string.lower(luaPattern)) ~= nil
end

----------------------------------------------------------------------
-- A networkable descriptor for one entity. Positions ride along as plain numbers
-- (util.TableToJSON can't serialise a Vector) so the client can compute distances
-- relative to its own player, keeping the two realms' distance columns consistent.
----------------------------------------------------------------------
function EntitySearch.Describe(ent)
	local pos = ent:GetPos()
	return {
		index = ent:EntIndex(),
		class = ent:GetClass(),
		model = ent:GetModel() or "",
		x = pos.x,
		y = pos.y,
		z = pos.z
	}
end

----------------------------------------------------------------------
-- Lua-snippet selector. Run `code` in THIS realm via Noir.EvalCode (a full Noir
-- run environment: `E("bob")`, `props()`, `this`, bare-name entity lookup, ...) and
-- expect it to evaluate to an entity (or a table/collection of entities). Returns
-- (descriptors, nil) on success or (nil, errorMessage) on any failure -- compile
-- error, runtime error, or a result that isn't an entity. Running arbitrary Lua is
-- the same trust level as the REPL; the remote path is superadmin-gated by the
-- channel open, so only trusted callers reach the server-side eval.
----------------------------------------------------------------------
function EntitySearch.RunSnippet(code, maxResults, runner)
	if not code or string.Trim(code) == "" then return nil, "empty Lua snippet" end
	maxResults = maxResults or EntitySearch.DEFAULTS.maxResults

	local ok, returns = Noir.EvalCode(code, "NoirEntitySearch", runner)
	if not ok then return nil, tostring(returns) end

	-- returns is the list of the snippet's return values. Flatten entities out of
	-- each (an entity directly, or a table/collection like props() that holds them).
	local descriptors = {}
	for _, value in ipairs(returns) do
		if isentity(value) and IsValid(value) then
			descriptors[#descriptors + 1] = EntitySearch.Describe(value)
		elseif istable(value) then
			for _, ent in pairs(value) do
				if isentity(ent) and IsValid(ent) then descriptors[#descriptors + 1] = EntitySearch.Describe(ent) end
				if #descriptors >= maxResults then break end
			end
		end

		if #descriptors >= maxResults then break end
	end

	if #descriptors == 0 then
		local first = returns[1]
		if isentity(first) then return nil, "snippet returned a NULL entity" end
		return nil, "snippet did not evaluate to an entity (got " .. type(first) .. ")"
	end

	return descriptors
end

----------------------------------------------------------------------
-- Gather entities in THIS realm matching `opts`, skipping `ignore` and the world.
-- opts:
--   mode        "filter" (class/model patterns), "nearby" (radius around origin),
--               or "lua" (evaluate opts.code to an entity/entities)
--   classFilter / modelFilter  glob patterns (filter mode)
--   radius / origin (Vector)   sphere query (nearby mode)
--   code / runner              snippet + environment owner (lua mode)
--   maxResults
-- Returns (descriptors, err). `err` is only ever set for "lua" mode.
----------------------------------------------------------------------
function EntitySearch.Gather(opts, ignore)
	opts = opts or {}
	if opts.mode == "lua" then
		return EntitySearch.RunSnippet(opts.code, opts.maxResults, opts.runner)
	end

	local maxResults = opts.maxResults or EntitySearch.DEFAULTS.maxResults
	local nearby = opts.mode == "nearby"
	local list = nearby and ents.FindInSphere(opts.origin or vector_origin, opts.radius or 1000) or ents.GetAll()
	local results = {}
	for _, ent in ipairs(list) do
		if not IsValid(ent) then continue end
		if ent == ignore or ent:IsWorld() then continue end
		if not nearby then
			if not matchesPattern(ent:GetClass(), opts.classFilter) then continue end
			if not matchesPattern(ent:GetModel() or "", opts.modelFilter) then continue end
		end

		results[#results + 1] = EntitySearch.Describe(ent)
		if #results >= maxResults then break end
	end

	return results
end

----------------------------------------------------------------------
-- Networking. Server endpoint: gather with the requesting client's parameters and
-- reply on the same channel. For "nearby" the origin is the requesting player's
-- server-side position, and the sender is skipped so players don't see themselves.
----------------------------------------------------------------------
Noir.Network.ChannelHandlers["entitySearch"] = {
	open = function(sender, channelId, data)
		if not SERVER then return end
		local req = util.JSONToTable(data.string) or {}
		local ply = IsValid(sender) and sender or nil
		local origin = req.mode == "nearby" and ply and ply:GetPos() or nil
		local results, err = EntitySearch.Gather({
			mode = req.mode,
			classFilter = req.classFilter,
			modelFilter = req.modelFilter,
			radius = req.radius,
			code = req.code,
			maxResults = req.maxResults,
			origin = origin,
			runner = ply
		}, ply)

		-- Defaults to addressing the opener (the requesting client).
		Noir.Network.SendOnChannel(channelId, "result", util.TableToJSON({
			results = results or {},
			error = err,
			realm = "server"
		}))
	end
}

----------------------------------------------------------------------
-- Send a search request to the server. `ctx.OnRemoteResults(decoded)` is called
-- with {results, error, realm} when the server replies. Returns the request
-- (channel) id (pass it to EntitySearch.SendCancel to abort / stop waiting;
-- Noir.Network.IsRequestPending(id) reports whether it's still in flight).
----------------------------------------------------------------------
function EntitySearch.SendRemote(opts, ctx)
	local payload = util.TableToJSON({
		mode = opts.mode,
		classFilter = opts.classFilter,
		modelFilter = opts.modelFilter,
		radius = opts.radius,
		code = opts.code,
		maxResults = opts.maxResults
	})

	return Noir.Network.Request("entitySearch", "server", payload, function(reply)
		if ctx.OnRemoteResults then ctx.OnRemoteResults(util.JSONToTable(reply) or {}) end
	end)
end

-- Stop waiting on a server search. Closing the channel relays to the server too.
function EntitySearch.SendCancel(requestId)
	Noir.Network.CancelRequest(requestId)
end
