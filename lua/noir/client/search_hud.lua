local SearchHUD = Noir.SearchHUD or {}
Noir.SearchHUD = SearchHUD

local fmt = string.format

----------------------------------------------------------------------
-- A small top-right stack of indicator pills, one per active search:
--   * a --find table walk, once it has been running longer than THRESHOLD seconds
--     (quick finds finish before it would ever show), or
--   * any file search ("Find in Files"), local or remote, for its whole duration.
--
-- Each pill shows the execution name (e.g. "repl0") so it is clear what is being
-- waited on, and lingers for DONE_LINGER seconds after completion with a green dot
-- and "Done" before disappearing.
--
-- Table-search finds are tracked here (SearchHUD.TrackFind, called from Noir.SendCode)
-- because the walk may run on the server -- there is no local job to poll. File
-- searches are synced from the FileSearch UI's list, which tracks running state.
----------------------------------------------------------------------

local THRESHOLD = 2 -- seconds a find must run before it appears
local DONE_LINGER = 5 -- seconds a finished search stays on screen

SearchHUD.Finds = SearchHUD.Finds or {} -- channelId -> item
SearchHUD.FileItems = SearchHUD.FileItems or {} -- fileSearch object -> item
-- item = {label, startTime, done, doneAt, elapsed}

local function shortName(identifier)
	if not identifier then return "run" end
	return (identifier:gsub("^Noir%.", ""))
end

-- Track a --find search initiated on `channelId`. Marked done (kept for the linger
-- window) when its result arrives or the run channel closes.
function SearchHUD.TrackFind(channelId, identifier)
	if not channelId then return end
	local item = {label = shortName(identifier), startTime = SysTime(), done = false}
	SearchHUD.Finds[channelId] = item
	local function finish()
		if item.done then return end
		item.done = true
		item.doneAt = SysTime()
		item.elapsed = item.doneAt - item.startTime
	end

	Noir.Network.OnChannel(channelId, "run", finish)
	Noir.Network.OnChannelClose(channelId, finish)
end

-- Walk the find + file-search state, advancing lifecycles and dropping expired
-- entries, and return the list of pills to draw: {label, running, elapsed}.
local function collect()
	local now = SysTime()
	local lines = {}

	for id, item in pairs(SearchHUD.Finds) do
		if item.done then
			if now - item.doneAt <= DONE_LINGER then
				if item.elapsed >= THRESHOLD then
					lines[#lines + 1] = {label = item.label, kind = "Find", running = false, elapsed = item.elapsed}
				end
			else
				SearchHUD.Finds[id] = nil
			end
		elseif not Noir.Network.Channels[id] then
			SearchHUD.Finds[id] = nil -- channel gone before a result (e.g. full reload)
		elseif now - item.startTime > THRESHOLD then
			lines[#lines + 1] = {label = item.label, kind = "Find", running = true, elapsed = now - item.startTime}
		end
	end

	-- Sync file-search items from the FileSearch UI's list (spot running -> done edges).
	local ui = Noir.FileSearch and Noir.FileSearch.UI
	local present = {}
	if ui and ui.Searches then
		for _, s in ipairs(ui.Searches) do
			present[s] = true
			local running = s.pendingLocal or s.pendingRemote
			local item = SearchHUD.FileItems[s]
			if running and not item then
				SearchHUD.FileItems[s] = {label = s.query or "files", startTime = now, done = false}
			elseif item and not item.done and not running then
				item.done = true
				item.doneAt = now
				item.elapsed = now - item.startTime
			end
		end
	end

	for s, item in pairs(SearchHUD.FileItems) do
		if item.done then
			if now - item.doneAt <= DONE_LINGER then
				lines[#lines + 1] = {label = item.label, kind = "Files", running = false, elapsed = item.elapsed}
			else
				SearchHUD.FileItems[s] = nil
			end
		elseif not present[s] then
			SearchHUD.FileItems[s] = nil -- search cleared while running
		else
			lines[#lines + 1] = {label = item.label, kind = "Files", running = true, elapsed = now - item.startTime}
		end
	end

	return lines
end

local BG = Color(30, 30, 30, 230)
local ACCENT = Color(60, 120, 205)
local GREEN = Color(70, 180, 90)
local TEXT = Color(235, 235, 235)
local FONT = "DermaDefaultBold"
local PAD_X, PAD_Y, GAP = 10, 5, 8

local function paint()
	local lines = collect()
	if #lines == 0 then return end

	surface.SetFont(FONT)
	local y = 16
	for _, ln in ipairs(lines) do
		-- e.g. "[Noir] repl0: Find (5s)" while running, "[Noir] repl0: Find Done (5.2s)" after.
		-- The pulsing dot is the live animation, so the text only changes once a second
		-- (no per-frame width jitter).
		local detail = ln.running and fmt("%s (%.1fs)", ln.kind, ln.elapsed)
			or fmt("%s Done (%.1fs)", ln.kind, ln.elapsed or 0)
		local text = fmt("[Noir] %s: %s", ln.label, detail)
		local tw, th = surface.GetTextSize(text)
		local dot = th
		local w = PAD_X * 2 + dot + GAP + tw
		local h = th + PAD_Y * 2
		local x = ScrW() - w - 16

		draw.RoundedBox(6, x, y, w, h, BG)
		local dy = y + (h - dot) / 2
		if ln.running then
			local pulse = math.abs(math.sin(RealTime() * 3))
			ACCENT.a = 90 + math.floor(pulse * 165)
			draw.RoundedBox(dot / 2, x + PAD_X, dy, dot, dot, ACCENT)
		else
			draw.RoundedBox(dot / 2, x + PAD_X, dy, dot, dot, GREEN)
		end

		draw.SimpleText(text, FONT, x + PAD_X + dot + GAP, y + h / 2, TEXT, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
		y = y + h + 6
	end
end

hook.Add("HUDPaint", "NoirSearchHUD", paint)
