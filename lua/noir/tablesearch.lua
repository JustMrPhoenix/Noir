local TableSearch = Noir.TableSearch or {}
Noir.TableSearch = TableSearch

-- Reload-safety: tear down any jobs + driver hook left over from a previous load
-- before we redefine the functions below (the hook name is constant, so removal
-- works across reloads; see StopDriver). Mirrors filesearch.lua.
if TableSearch.CancelAll then TableSearch.CancelAll() end

----------------------------------------------------------------------
-- Async deep table walk. Backs the REPL --find* flags (see output_format.lua's
-- Format.DeepFindAsync, which supplies the per-node `record` matcher). The walk
-- used to be a synchronous recursion that would freeze the realm it ran on
-- (server or a specific client) for the whole traversal.
--
-- This engine is a generic, format-agnostic value-tree walker driven off one
-- Think hook on a per-job per-frame time budget, exactly like FileSearch: it
-- recurses over reachable tables inside a coroutine, calls `record(keyStr, k, v)`
-- for every pair (which returns 0..N result lines) and yields every `yieldEvery`
-- pairs so the driver can stop once the frame budget is spent. Cycles are guarded
-- with a `seen` set; Colors are treated as leaves (not recursed).
--
-- We recurse (LuaJIT can yield across nested Lua calls) rather than manage an
-- explicit stack: walking _G reaches 100k+ tables, and a heap table per node would
-- flood the GC and stutter the walk. Recursion uses the Lua call stack -- no
-- per-node allocation, matching the old synchronous walk's footprint.
----------------------------------------------------------------------

TableSearch.DEFAULTS = {
	frameBudget = 0.016, -- seconds of work per frame, per job (a --find is a deliberate
	                     -- one-off the user waits on, so budget more than a background grep)
	maxResults = 500, -- cap on matched result lines
	yieldEvery = 512, -- pairs processed between coroutine yields
	maxDepth = 100 -- recursion cap so an adversarial deep chain can't overflow the stack
}

TableSearch.Jobs = TableSearch.Jobs or {} -- array of live jobs
TableSearch.JobCounter = TableSearch.JobCounter or 0

local HOOK_ID = "NoirTableSearchDriver"

----------------------------------------------------------------------
-- The coroutine body: breadth-first walk over reachable tables.
--
-- BFS (not DFS) so the first time a table is reached is always via a fewest-hops path:
-- we mark it `seen` and record its keyStr on ENQUEUE, so a table reachable by several
-- paths is reported/descended via its SHORTEST path. `queue` holds {tbl, path, depth};
-- processed entries are cleared to false so their path strings can be GC'd.
--
-- The per-pair hot path is deliberately lean: test(k, v) is a cheap match probe that
-- builds NO access-path string. The (relatively expensive) keyStr -- and the render()
-- that formats a result line -- are computed only when there's a match or we're about
-- to enqueue a child table, never for the millions of non-matching leaves.
----------------------------------------------------------------------
local function searchCoroutine(job)
	local seen = job.seen
	local test = job.test
	local render = job.render
	local keyStrOf = Noir.Format.FindKeyStr
	local results = job.results
	local yieldEvery = job.yieldEvery
	local skipDescend = job.skipDescend
	local maxDepth = job.maxDepth
	local since = 0

	local queue = {{job.root, "", 0}}
	seen[job.root] = true
	local head = 1

	while head <= #queue do
		local node = queue[head]
		queue[head] = false -- release the node (and its path string) for GC
		head = head + 1
		local tbl, path, depth = node[1], node[2], node[3]

		for k, v in pairs(tbl) do
			if job.cancelled or job.stopped then return end
			job.nodesVisited = job.nodesVisited + 1

			local desc = test(k, v)
			-- `not seen[v]` here is the shortest-path guard: a table already enqueued was
			-- reached via an equal-or-shorter path, so we don't enqueue it again.
			local enqueue = depth < maxDepth and istable(v) and not IsColor(v)
				and not seen[v] and not (skipDescend and skipDescend(k))
			if desc or enqueue then
				local keyStr = keyStrOf(path, k)
				if desc then
					local lines = render(keyStr, v, desc)
					for i = 1, #lines do
						results[#results + 1] = lines[i]
						job.matched = job.matched + 1
						if job.matched >= job.maxResults then
							job.truncated = true
							job.stopped = true
							return
						end
					end
				end

				if enqueue then
					seen[v] = true
					queue[#queue + 1] = {v, keyStr, depth + 1}
				end
			end

			since = since + 1
			if since >= yieldEvery then
				since = 0
				coroutine.yield()
			end
		end
	end
end

----------------------------------------------------------------------
-- Driver: resume each job's coroutine until its frame budget is spent.
----------------------------------------------------------------------
function TableSearch.DriveJob(job)
	local start = SysTime()
	while job.running and coroutine.status(job.co) ~= "dead" do
		local ok, err = coroutine.resume(job.co)
		if not ok then
			Noir.Error("TableSearch worker error: ", tostring(err), "\n")
			TableSearch.Finish(job, false)
			return
		end

		if SysTime() - start > job.frameBudget then break end
	end

	if coroutine.status(job.co) == "dead" then TableSearch.Finish(job, true) end
end

local function driveAll()
	local jobs = TableSearch.Jobs
	-- Reverse so Finish() removing the current job doesn't skip its neighbour.
	for i = #jobs, 1, -1 do
		local job = jobs[i]
		if job and job.running then TableSearch.DriveJob(job) end
	end
end

function TableSearch.StartDriver()
	hook.Add("Think", HOOK_ID, driveAll)
end

function TableSearch.StopDriver()
	hook.Remove("Think", HOOK_ID)
end

local function removeJob(job)
	for i = #TableSearch.Jobs, 1, -1 do
		if TableSearch.Jobs[i] == job then
			table.remove(TableSearch.Jobs, i)
			break
		end
	end

	if #TableSearch.Jobs == 0 then TableSearch.StopDriver() end
end

----------------------------------------------------------------------
-- Lifecycle. opts: root (the table to walk), test(k, v) -> desc|nil (cheap match probe),
-- render(keyStr, v, desc) -> {lines}, skipDescend(k) -> bool, frameBudget, maxResults,
-- yieldEvery, maxDepth, onDone(job, completed).
-- Returns the job (use job.results / job.truncated / TableSearch.CancelJob).
----------------------------------------------------------------------
function TableSearch.Start(opts)
	if not opts.test or not opts.render then
		Noir.Error("TableSearch: test/render matcher not supplied\n")
		return
	end

	local d = TableSearch.DEFAULTS
	TableSearch.JobCounter = TableSearch.JobCounter + 1
	local job = {
		id = TableSearch.JobCounter,
		test = opts.test,
		render = opts.render,
		skipDescend = opts.skipDescend,
		frameBudget = opts.frameBudget or d.frameBudget,
		maxResults = opts.maxResults or d.maxResults,
		yieldEvery = opts.yieldEvery or d.yieldEvery,
		maxDepth = opts.maxDepth or d.maxDepth,
		onDone = opts.onDone,
		root = opts.root,
		seen = {},
		results = {},
		nodesVisited = 0,
		matched = 0,
		truncated = false,
		stopped = false,
		running = true,
		cancelled = false,
		startTime = SysTime()
	}

	-- Never walk into our own live bookkeeping. The root is often _G, which reaches
	-- Noir.TableSearch.Jobs -> this job -> its `seen`/`results`. Descending into those
	-- iterates a table we are concurrently mutating (undefined in Lua; LuaJIT's next
	-- loops forever), and `results` is self-feeding -- every result line contains the
	-- search term, so matching it appends another matching line, without end. Marking
	-- them (and the Jobs list / this job) as already-seen makes the walk skip them.
	job.seen[job.seen] = true
	job.seen[job.results] = true
	job.seen[job] = true
	job.seen[TableSearch.Jobs] = true

	job.co = coroutine.create(function() searchCoroutine(job) end)
	TableSearch.Jobs[#TableSearch.Jobs + 1] = job
	if #TableSearch.Jobs == 1 then TableSearch.StartDriver() end
	return job
end

-- Free a finished job's heavy per-search state. `seen` alone can hold hundreds of
-- thousands of tables after a full _G walk, and the coroutine keeps its whole stack
-- alive -- don't wait for GC to notice the job went unreferenced. Lightweight metadata
-- (id, matched, nodesVisited, elapsed, truncated) is kept for post-hoc inspection.
local function clearJobData(job)
	job.seen = nil
	job.co = nil
	job.root = nil
	job.test = nil
	job.render = nil
end

function TableSearch.Finish(job, completed)
	if job.finished then return end
	job.finished = true
	job.running = false
	job.elapsed = SysTime() - job.startTime
	removeJob(job)
	if job.onDone then job.onDone(job, completed) end
	clearJobData(job) -- after onDone, which consumes job.results
end

-- Cancel one job. Does NOT fire onDone (the caller initiated it).
function TableSearch.CancelJob(job)
	if not job then return end
	job.cancelled = true
	job.running = false
	job.finished = true
	removeJob(job)
	clearJobData(job)
end

-- Cancel everything (reload cleanup).
function TableSearch.CancelAll()
	for _, job in ipairs(TableSearch.Jobs) do
		job.cancelled = true
		job.running = false
		job.finished = true
		clearJobData(job)
	end

	TableSearch.Jobs = {}
	TableSearch.StopDriver()
end
