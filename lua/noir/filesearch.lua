local FileSearch = Noir.FileSearch or {}
Noir.FileSearch = FileSearch

-- Reload-safety: tear down any jobs + driver hook left over from a previous load
-- before we redefine the functions below (the hook name is constant, so removal
-- works across reloads; see StopDriver).
if FileSearch.CancelAll then FileSearch.CancelAll() end

----------------------------------------------------------------------
-- "Find in Files": grep a string across every Lua file, locally and on the
-- remote server. file.Find does NOT recurse, so directories are walked manually
-- with an explicit stack inside a coroutine.
--
-- Each search runs in two phases so we can show a real (determinate) progress
-- bar: (1) DISCOVERY walks the tree and collects every file matching the glob;
-- (2) SCANNING greps each collected file -- progress = fileIndex / total.
-- Multiple searches can run at once; they are all driven off one Think hook on a
-- per-job per-frame time budget so the game stays responsive.
----------------------------------------------------------------------

FileSearch.DEFAULTS = {
	frameBudget = 0.008, -- seconds of work per frame, per job
	maxDepth = 32, -- guard against symlink loops / pathological trees
	maxResults = 5000, -- cap on matched lines
	maxFileSize = 2 * 1024 * 1024, -- skip files larger than this
	maxPreviewLen = 400
}

FileSearch.Jobs = FileSearch.Jobs or {} -- array of live jobs (this realm)
FileSearch.JobCounter = FileSearch.JobCounter or 0
FileSearch.PendingRemote = FileSearch.PendingRemote or {} -- client: requestId -> ctx
FileSearch.ServerJobs = FileSearch.ServerJobs or {} -- server: requestId -> job

local HOOK_ID = "NoirFileSearchDriver"

----------------------------------------------------------------------
-- Result entry. `fileName` is relative to the pathID root (it includes the
-- "lua/" prefix when pathID == "GAME") so Noir.Editor.OpenFile resolves it via
-- Noir.Utils.FixFilePath (which remaps a leading lua/ -> LUA, data/ -> DATA).
----------------------------------------------------------------------
function FileSearch.MakeResult(pathID, fileName, line, lineText, realm, previewLen)
	return {
		pathID = pathID,
		fileName = fileName,
		line = line,
		preview = string.sub((lineText or ""):gsub("\r$", ""), 1, previewLen or FileSearch.DEFAULTS.maxPreviewLen),
		realm = realm
	}
end

local function joinPath(dir, sub)
	if dir == "" then return sub end
	return dir .. "/" .. sub
end

----------------------------------------------------------------------
-- Read one file and push a result for every matching line.
----------------------------------------------------------------------
local function grepFile(job, fileName)
	job.scanned = job.scanned + 1
	local f = file.Open(fileName, "rb", job.pathID)
	if not f then return end
	local size = f:Size()
	if size > job.maxFileSize then
		f:Close()
		return
	end

	local content = f:Read(size) or ""
	f:Close()
	if content == "" then return end
	-- Skip binaries: a NUL byte is a reliable enough heuristic.
	if string.find(content, "\0", 1, true) then return end

	local needle = job.caseInsensitive and job.queryLower or job.query
	local lines = string.Explode("\n", content)
	for i = 1, #lines do
		local line = lines[i]
		local hay = job.caseInsensitive and line:lower() or line
		if string.find(hay, needle, 1, true) then
			local result = FileSearch.MakeResult(job.pathID, fileName, i, line, job.realm, job.maxPreviewLen)
			job.results[#job.results + 1] = result
			job.matched = job.matched + 1
			if job.onResult then job.onResult(job, result) end
			if job.matched >= job.maxResults then return end
		end
	end
end

----------------------------------------------------------------------
-- The coroutine body: phase 1 discovery, then phase 2 scanning.
----------------------------------------------------------------------
local function searchCoroutine(job)
	-- Phase 1: discover every matching file (no grepping yet).
	job.phase = "discovering"
	while #job.stack > 0 do
		if job.cancelled then return end
		local node = table.remove(job.stack) -- DFS (last-in first-out)
		job.dirsVisited = job.dirsVisited + 1
		job.currentDir = node.dir
		if node.depth <= job.maxDepth then
			local files = file.Find(joinPath(node.dir, job.glob), job.pathID) or {}
			local _, dirs = file.Find(joinPath(node.dir, "*"), job.pathID)
			for _, d in ipairs(dirs or {}) do
				job.stack[#job.stack + 1] = {dir = joinPath(node.dir, d), depth = node.depth + 1}
			end

			for _, fn in ipairs(files) do
				job.fileQueue[#job.fileQueue + 1] = joinPath(node.dir, fn)
			end
		end

		coroutine.yield()
	end

	-- Phase 2: scan the discovered files; total is now known -> real progress.
	job.total = #job.fileQueue
	job.phase = "scanning"
	for i = 1, job.total do
		if job.cancelled then return end
		job.fileIndex = i
		grepFile(job, job.fileQueue[i])
		if job.matched >= job.maxResults then return end
		coroutine.yield()
	end
end

----------------------------------------------------------------------
-- Progress fraction for the bar: determinate only during scanning.
-- Returns (fraction 0..1, indeterminate bool).
----------------------------------------------------------------------
function FileSearch.JobProgress(job)
	if job.phase == "scanning" and job.total and job.total > 0 then
		return job.fileIndex / job.total, false
	end

	if job.phase == "done" then return 1, false end
	return 0, true
end

----------------------------------------------------------------------
-- Driver: resume each job's coroutine until its frame budget is spent.
----------------------------------------------------------------------
function FileSearch.DriveJob(job)
	local start = SysTime()
	while job.running and coroutine.status(job.co) ~= "dead" do
		local ok, err = coroutine.resume(job.co)
		if not ok then
			Noir.Error("FileSearch worker error: ", tostring(err), "\n")
			FileSearch.Finish(job, false)
			return
		end

		if SysTime() - start > job.frameBudget then break end
	end

	if job.onProgress then job.onProgress(job) end
	if coroutine.status(job.co) == "dead" then FileSearch.Finish(job, true) end
end

local function driveAll()
	local jobs = FileSearch.Jobs
	-- Reverse so Finish() removing the current job doesn't skip its neighbour.
	for i = #jobs, 1, -1 do
		local job = jobs[i]
		if job and job.running then FileSearch.DriveJob(job) end
	end
end

function FileSearch.StartDriver()
	hook.Add("Think", HOOK_ID, driveAll)
end

function FileSearch.StopDriver()
	hook.Remove("Think", HOOK_ID)
end

local function removeJob(job)
	for i = #FileSearch.Jobs, 1, -1 do
		if FileSearch.Jobs[i] == job then
			table.remove(FileSearch.Jobs, i)
			break
		end
	end

	if #FileSearch.Jobs == 0 then FileSearch.StopDriver() end
end

----------------------------------------------------------------------
-- Lifecycle. opts: query, caseInsensitive, rootDir, glob, pathID, realm,
-- frameBudget, maxDepth, maxResults, maxFileSize, maxPreviewLen,
-- onProgress(job), onResult(job, result), onDone(job, completed).
-- Returns the job (use job.id / FileSearch.JobProgress / FileSearch.CancelJob).
----------------------------------------------------------------------
function FileSearch.Start(opts)
	if not opts.query or opts.query == "" then
		Noir.Error("FileSearch: empty query\n")
		return
	end

	local d = FileSearch.DEFAULTS
	FileSearch.JobCounter = FileSearch.JobCounter + 1
	local job = {
		id = FileSearch.JobCounter,
		query = opts.query,
		queryLower = string.lower(opts.query),
		caseInsensitive = opts.caseInsensitive ~= false,
		rootDir = opts.rootDir or "",
		glob = opts.glob or "*.lua",
		pathID = opts.pathID or "GAME",
		realm = opts.realm or "local",
		frameBudget = opts.frameBudget or d.frameBudget,
		maxDepth = opts.maxDepth or d.maxDepth,
		maxResults = opts.maxResults or d.maxResults,
		maxFileSize = opts.maxFileSize or d.maxFileSize,
		maxPreviewLen = opts.maxPreviewLen or d.maxPreviewLen,
		onProgress = opts.onProgress,
		onResult = opts.onResult,
		onDone = opts.onDone,
		phase = "discovering",
		stack = {{dir = opts.rootDir or "", depth = 0}},
		fileQueue = {},
		fileIndex = 0,
		total = 0,
		results = {},
		scanned = 0,
		matched = 0,
		dirsVisited = 0,
		currentDir = "",
		running = true,
		cancelled = false
	}

	job.co = coroutine.create(function() searchCoroutine(job) end)
	FileSearch.Jobs[#FileSearch.Jobs + 1] = job
	if #FileSearch.Jobs == 1 then FileSearch.StartDriver() end
	return job
end

function FileSearch.Finish(job, completed)
	if job.finished then return end
	job.finished = true
	job.running = false
	job.phase = "done"
	removeJob(job)
	if job.onDone then job.onDone(job, completed) end
end

-- Cancel one job. Does NOT fire onDone (the caller initiated it).
function FileSearch.CancelJob(job)
	if not job then return end
	job.cancelled = true
	job.running = false
	job.finished = true
	removeJob(job)
end

-- Cancel everything (reload cleanup).
function FileSearch.CancelAll()
	for _, job in ipairs(FileSearch.Jobs) do
		job.cancelled = true
		job.running = false
		job.finished = true
	end

	FileSearch.Jobs = {}
	FileSearch.ServerJobs = {}
	FileSearch.StopDriver()
end

----------------------------------------------------------------------
-- Networking. A remote search is a Noir channel (no new net string). The client
-- opens a "fileSearch" channel to the server; the server runs the worker with the
-- CLIENT's performance settings and ships results back as JSON on the same channel.
-- Opening the channel is superadmin-gated by Network.CheckAccess.
----------------------------------------------------------------------
Noir.Network.ChannelHandlers["fileSearch"] = {
	-- Server endpoint: run the worker with the requesting client's performance
	-- settings and reply on the same channel. Streaming is possible -- SendOnChannel
	-- can be called repeatedly (e.g. progress + final result).
	open = function(sender, channelId, data)
		if not SERVER then return end
		local req = util.JSONToTable(data.string) or {}
		local job = FileSearch.Start({
			query = req.query,
			caseInsensitive = req.caseInsensitive,
			rootDir = req.rootDir,
			glob = req.glob,
			pathID = req.pathID,
			frameBudget = req.frameBudget,
			maxDepth = req.maxDepth,
			maxResults = req.maxResults,
			maxFileSize = req.maxFileSize,
			maxPreviewLen = req.maxPreviewLen,
			realm = "server",
			onDone = function(doneJob, completed)
				FileSearch.ServerJobs[channelId] = nil
				local payload = util.TableToJSON({
					results = doneJob.results,
					completed = completed,
					scanned = doneJob.scanned,
					matched = doneJob.matched
				})

				-- Defaults to addressing the opener (the requesting client).
				Noir.Network.SendOnChannel(channelId, "result", payload)
			end
		})

		if job then FileSearch.ServerJobs[channelId] = job end
	end,
	-- Client closed the channel (results delivered) or disconnected: abort any job.
	close = function(channelId)
		if not SERVER then return end
		local job = FileSearch.ServerJobs[channelId]
		if job then
			FileSearch.CancelJob(job)
			FileSearch.ServerJobs[channelId] = nil
		end
	end
}

-- Send a search request to the server. `ctx.OnRemoteResults(decoded)` is called
-- with {results, completed, scanned, matched} when the server replies. Returns
-- the request (channel) id (pass it to FileSearch.SendCancel to abort).
function FileSearch.SendRemote(opts, ctx)
	local requestId = Noir.Network.OpenChannel("fileSearch", "server")
	FileSearch.PendingRemote[requestId] = ctx
	Noir.Network.OnChannel(requestId, "result", function(sender, channelId, message, data)
		if not FileSearch.PendingRemote[channelId] then return end
		FileSearch.PendingRemote[channelId] = nil
		local decoded = util.JSONToTable(data.string) or {}
		if ctx.OnRemoteResults then ctx.OnRemoteResults(decoded) end
		-- Bounded op done: close the channel (drops both records; the job already
		-- finished so nothing is aborted).
		Noir.Network.CloseChannel(channelId)
	end)

	local payload = util.TableToJSON({
		query = opts.query,
		caseInsensitive = opts.caseInsensitive,
		rootDir = opts.rootDir,
		glob = opts.glob,
		pathID = opts.pathID,
		frameBudget = opts.frameBudget,
		maxDepth = opts.maxDepth,
		maxResults = opts.maxResults,
		maxFileSize = opts.maxFileSize,
		maxPreviewLen = opts.maxPreviewLen
	})

	Noir.Network.OpenSend(requestId, payload)
	return requestId
end

-- Stop waiting on a server search and tell the server to abort it. Closing the
-- channel relays to the server, whose close handler cancels the running job.
function FileSearch.SendCancel(requestId)
	if not requestId then return end
	FileSearch.PendingRemote[requestId] = nil
	Noir.Network.CloseChannel(requestId)
end
