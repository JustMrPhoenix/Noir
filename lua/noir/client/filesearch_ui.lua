local FileSearch = Noir.FileSearch or {}
Noir.FileSearch = FileSearch
local UI = FileSearch.UI or {}
FileSearch.UI = UI

-- "Find in Files" window. Each invocation of Search starts a new search; running
-- searches are listed (with their parameters and a live progress bar drawn as the
-- row background) and can be switched between, cancelled or cleared. Searches run
-- locally and/or on the remote server via Noir.FileSearch.

UI.Searches = UI.Searches or {} -- in-memory; cleared on reload (newest first)
UI.MaxSearches = 50
UI.Selected = UI.Selected or nil -- the search whose results are shown

local PATH_CHOICES = {
	{label = "Game (garrysmod)", value = "GAME"},
	{label = "Lua", value = "LUA"},
	{label = "Data (garrysmod/data)", value = "DATA"}
}

local TARGET_CHOICES = {
	{label = "Local", value = "local"},
	{label = "Server", value = "server"},
	{label = "Both", value = "both"}
}

----------------------------------------------------------------------
-- Persisted settings (last-used inputs + performance tuning survive restarts).
-- Performance settings are read here and sent with each search request so the
-- server uses the same tuning as the client.
----------------------------------------------------------------------
function UI.RegisterDashboard()
	if not Noir.Dashboard then return end
	if UI.DashboardRegistered then Noir.Dashboard.Unregister("FileSearch") end
	Noir.Dashboard.Register("FileSearch", {
		{key = "rootDir", type = "string", label = "Default subfolder", default = "lua", category = "Search"},
		{key = "glob", type = "string", label = "Default glob pattern", default = "*.lua", category = "Search"},
		{
			key = "pathID",
			type = "dropdown",
			label = "Default search path",
			default = "GAME",
			category = "Search",
			options = PATH_CHOICES
		},
		{key = "caseInsensitive", type = "bool", label = "Case insensitive by default", default = true, category = "Search"},
		{
			key = "target",
			type = "dropdown",
			label = "Default target",
			default = "local",
			category = "Search",
			options = TARGET_CHOICES
		},
		{
			key = "frameBudgetMs",
			type = "slider",
			label = "Frame budget (ms)",
			description = "How long each search may work per frame. Higher = faster searches, lower = smoother framerate.",
			default = 8,
			min = 1,
			max = 33,
			decimals = 0,
			category = "Performance"
		},
		{
			key = "maxResults",
			type = "number",
			label = "Max results",
			description = "Stop a search after this many matched lines.",
			default = 5000,
			min = 1,
			category = "Performance"
		},
		{
			key = "maxDepth",
			type = "number",
			label = "Max folder depth",
			default = 32,
			min = 1,
			category = "Performance"
		},
		{
			key = "maxFileSizeMiB",
			type = "number",
			label = "Max file size (MiB)",
			description = "Skip files larger than this.",
			default = 2,
			min = 1,
			category = "Performance"
		},
		{
			key = "maxPreviewLen",
			type = "number",
			label = "Max preview length",
			default = 400,
			min = 1,
			category = "Performance"
		}
	}, {
		icon = "icon16/page_white_magnify.png",
		description = "Find in Files defaults & performance"
	})

	UI.DashboardRegistered = true
end

local function getSetting(key, fallback)
	if not Noir.Dashboard then return fallback end
	local v = Noir.Dashboard.Get("FileSearch", key)
	if v == nil then return fallback end
	return v
end

local function setSetting(key, value)
	if not Noir.Dashboard then return end
	Noir.Dashboard.Set("FileSearch", key, value)
end

local function gatherPerf()
	return {
		frameBudget = getSetting("frameBudgetMs", 8) / 1000,
		maxDepth = getSetting("maxDepth", 32),
		maxResults = getSetting("maxResults", 5000),
		maxFileSize = getSetting("maxFileSizeMiB", 2) * 1024 * 1024,
		maxPreviewLen = getSetting("maxPreviewLen", 400)
	}
end

----------------------------------------------------------------------
-- Per-search progress for rendering. Returns (fraction 0..1, indeterminate,
-- running, cancelled).
----------------------------------------------------------------------
local function searchState(s)
	local running = s.pendingLocal or s.pendingRemote
	local fracs, indet = {}, false
	if s.target == "local" or s.target == "both" then
		if s.pendingLocal then
			if s.localIndeterminate then
				indet = true
				fracs[#fracs + 1] = 0
			else
				fracs[#fracs + 1] = s.localFrac or 0
			end
		else
			fracs[#fracs + 1] = 1
		end
	end

	if s.target == "server" or s.target == "both" then
		if s.pendingRemote then
			indet = true
			fracs[#fracs + 1] = 0
		else
			fracs[#fracs + 1] = 1
		end
	end

	local sum = 0
	for _, f in ipairs(fracs) do sum = sum + f end
	local frac = #fracs > 0 and sum / #fracs or 1
	return frac, (running and indet), running, s.cancelled
end

-- Draw a progress fill for a search. Shared by the list rows and the top bar.
local function drawProgress(s, w, h, withTrack)
	local frac, indet, running, cancelled = searchState(s)
	if withTrack then
		surface.SetDrawColor(28, 28, 28)
		surface.DrawRect(0, 0, w, h)
	end

	if running then
		if indet then
			local bw = w * 0.25
			local x = (math.sin(RealTime() * 2) * 0.5 + 0.5) * (w - bw)
			surface.SetDrawColor(60, 120, 205, 150)
			surface.DrawRect(x, 0, bw, h)
		else
			surface.SetDrawColor(60, 120, 205, 150)
			surface.DrawRect(0, 0, w * frac, h)
		end
	elseif cancelled then
		surface.SetDrawColor(110, 110, 110, 90)
		surface.DrawRect(0, 0, w, h)
	else
		surface.SetDrawColor(50, 150, 85, 90)
		surface.DrawRect(0, 0, w * frac, h)
	end
end

local function scopeText(s)
	return Format("[%s] %s:%s %s", s.target, s.opts.pathID, s.opts.rootDir, s.opts.glob)
end

----------------------------------------------------------------------
-- Combo / column helpers
----------------------------------------------------------------------
local function makeCombo(parent, choices, current)
	local combo = parent:Add("DComboBox")
	combo:SetSkin("Noir")
	combo.NoirValue = current
	for _, c in ipairs(choices) do
		combo:AddChoice(c.label, c.value, c.value == current)
	end

	combo.OnSelect = function(_, _, _, data) combo.NoirValue = data end
	return combo
end

local function addColumn(listView, name, width)
	local column = listView:AddColumn(name)
	if width then column:SetWidth(width) end
	return column
end

----------------------------------------------------------------------
-- The window content panel.
----------------------------------------------------------------------
local PANEL = {}

function PANEL:Init()
	-- Control bar -------------------------------------------------------
	local bar = self:Add("DPanel")
	bar:Dock(TOP)
	bar:SetTall(58)
	bar:DockPadding(4, 4, 4, 4)
	bar:SetPaintBackground(false)

	local row1 = bar:Add("DPanel")
	row1:Dock(TOP)
	row1:SetTall(24)
	row1:SetPaintBackground(false)

	local searchBtn = row1:Add("DButton")
	searchBtn:SetSkin("Noir")
	searchBtn:Dock(RIGHT)
	searchBtn:SetWide(80)
	searchBtn:DockMargin(4, 0, 0, 0)
	searchBtn:SetText("Search")
	searchBtn.DoClick = function() self:StartSearch() end

	self.CancelBtn = row1:Add("DButton")
	self.CancelBtn:SetSkin("Noir")
	self.CancelBtn:Dock(RIGHT)
	self.CancelBtn:SetWide(80)
	self.CancelBtn:DockMargin(4, 0, 0, 0)
	self.CancelBtn:SetText("Cancel")
	self.CancelBtn:SetEnabled(false)
	self.CancelBtn.DoClick = function() self:CancelSearch() end

	self.QueryEntry = row1:Add("DTextEntry")
	self.QueryEntry:SetSkin("Noir")
	self.QueryEntry:Dock(FILL)
	self.QueryEntry:SetPlaceholderText("Search string...")
	self.QueryEntry.OnEnter = function() self:StartSearch() end

	local row2 = bar:Add("DPanel")
	row2:Dock(TOP)
	row2:SetTall(24)
	row2:DockMargin(0, 4, 0, 0)
	row2:SetPaintBackground(false)

	self.PathCombo = makeCombo(row2, PATH_CHOICES, getSetting("pathID", "GAME"))
	self.PathCombo:Dock(LEFT)
	self.PathCombo:SetWide(150)
	self.PathCombo:SetTooltip("Search path (the file.Find mount: GAME / LUA / DATA)")

	self.RootEntry = row2:Add("DTextEntry")
	self.RootEntry:SetSkin("Noir")
	self.RootEntry:Dock(LEFT)
	self.RootEntry:SetWide(140)
	self.RootEntry:DockMargin(4, 0, 0, 0)
	self.RootEntry:SetValue(getSetting("rootDir", "lua"))
	self.RootEntry:SetPlaceholderText("subfolder (blank = root)")
	self.RootEntry:SetTooltip("Subfolder within the selected path to start searching in (blank = its root)")

	self.GlobEntry = row2:Add("DTextEntry")
	self.GlobEntry:SetSkin("Noir")
	self.GlobEntry:Dock(LEFT)
	self.GlobEntry:SetWide(110)
	self.GlobEntry:DockMargin(4, 0, 0, 0)
	self.GlobEntry:SetValue(getSetting("glob", "*.lua"))
	self.GlobEntry:SetPlaceholderText("*.lua")
	self.GlobEntry:SetTooltip("Glob pattern, e.g. *.lua")

	self.TargetCombo = makeCombo(row2, TARGET_CHOICES, getSetting("target", "local"))
	self.TargetCombo:Dock(LEFT)
	self.TargetCombo:SetWide(90)
	self.TargetCombo:DockMargin(4, 0, 0, 0)

	self.CaseCheck = row2:Add("DCheckBoxLabel")
	self.CaseCheck:SetSkin("Noir")
	self.CaseCheck:Dock(LEFT)
	self.CaseCheck:DockMargin(8, 4, 0, 0)
	self.CaseCheck:SetText("Case insensitive")
	self.CaseCheck:SetChecked(getSetting("caseInsensitive", true))

	-- Progress bar (selected search) ------------------------------------
	self.Progress = self:Add("DPanel")
	self.Progress:Dock(TOP)
	self.Progress:SetTall(20)
	self.Progress:DockMargin(4, 0, 4, 4)
	self.Progress.Text = ""
	self.Progress.Paint = function(pnl, w, h)
		surface.SetDrawColor(20, 20, 20)
		surface.DrawRect(0, 0, w, h)
		if UI.Selected then drawProgress(UI.Selected, w, h, false) end
		draw.SimpleText(pnl.Text or "", "DermaDefault", 6, h / 2, color_white, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
	end

	-- Searches list (right) ---------------------------------------------
	local searchesPanel = self:Add("DPanel")
	searchesPanel:Dock(RIGHT)
	searchesPanel:SetWide(320)
	searchesPanel:DockMargin(4, 0, 0, 0)
	searchesPanel:SetPaintBackground(false)

	local header = searchesPanel:Add("DPanel")
	header:Dock(TOP)
	header:SetTall(20)
	header:SetPaintBackground(false)

	local clearBtn = header:Add("DButton")
	clearBtn:SetSkin("Noir")
	clearBtn:Dock(RIGHT)
	clearBtn:SetWide(60)
	clearBtn:SetText("Clear")
	clearBtn.DoClick = function() self:ClearSearches() end

	local headerLabel = header:Add("DLabel")
	headerLabel:Dock(FILL)
	headerLabel:SetText("Searches")

	self.SearchesList = searchesPanel:Add("DListView")
	self.SearchesList:SetSkin("Noir")
	self.SearchesList:Dock(FILL)
	self.SearchesList:SetMultiSelect(false)
	addColumn(self.SearchesList, "Query", 90)
	addColumn(self.SearchesList, "Scope")
	addColumn(self.SearchesList, "Hits", 40)
	self.SearchesList.OnRowSelected = function(_, _, line)
		if self.SuppressSelect then return end
		if line.search then self:SelectSearch(line.search) end
	end

	-- Results (fill) ----------------------------------------------------
	self.Results = self:Add("DListView")
	self.Results:SetSkin("Noir")
	self.Results:Dock(FILL)
	self.Results:SetMultiSelect(false)
	addColumn(self.Results, "Realm", 60)
	addColumn(self.Results, "File")
	addColumn(self.Results, "Line", 50)
	addColumn(self.Results, "Match")
	self.Results.DoDoubleClick = function(_, _, line) self:OpenResult(line.result) end

	self:RefreshSearchesList()
	self:UpdateProgress()
end

function PANEL:GetOpts()
	return {
		query = self.QueryEntry:GetValue(),
		caseInsensitive = self.CaseCheck:GetChecked(),
		rootDir = self.RootEntry:GetValue(),
		glob = self.GlobEntry:GetValue(),
		pathID = self.PathCombo.NoirValue or "GAME"
	}
end

----------------------------------------------------------------------
-- Results list (shows the selected search)
----------------------------------------------------------------------
function PANEL:AppendResultLine(result)
	local line = self.Results:AddLine(
		result.realm == "server" and "Server" or "Local",
		result.fileName,
		result.line,
		result.preview
	)

	line.result = result
end

function PANEL:RebuildResults(s)
	self.Results:Clear()
	if not s or not s.results then return end
	for _, result in ipairs(s.results) do self:AppendResultLine(result) end
end

function PANEL:OpenResult(result)
	if not result then return end
	if result.realm ~= "local" then
		Noir.Msg("Opening server-side results is not implemented yet\n")
		return
	end

	if not Noir.Editor or not Noir.Editor.IsReady then return end
	Noir.Editor.Show()
	Noir.Editor.OpenFile(result.pathID, result.fileName)
	-- OpenFile creates or re-activates the tab synchronously; RunJS is FIFO, so the
	-- goto is queued after the session swap and lands on the right model.
	Noir.Editor.MonacoPanel:GotoLine(result.line)
end

----------------------------------------------------------------------
-- Searches list
----------------------------------------------------------------------
function PANEL:RefreshSearchesList()
	self.SuppressSelect = true
	self.SearchesList:Clear()
	for _, s in ipairs(UI.Searches) do
		local line = self.SearchesList:AddLine(s.query, scopeText(s), tostring(#(s.results or {})))
		line.search = s
		s.listLine = line
		line.Paint = function(pnl, w, h)
			drawProgress(s, w, h, true)
			if pnl:IsSelected() then
				surface.SetDrawColor(255, 255, 255, 25)
				surface.DrawRect(0, 0, w, h)
			end
		end

		if UI.Selected == s then self.SearchesList:SelectItem(line) end
	end

	self.SuppressSelect = false
end

function PANEL:UpdateSearchRow(s)
	if IsValid(s.listLine) then s.listLine:SetColumnText(3, tostring(#(s.results or {}))) end
end

function PANEL:SelectSearch(s)
	UI.Selected = s
	self:RebuildResults(s)
	self:UpdateProgress()
end

----------------------------------------------------------------------
-- Progress text for the selected search
----------------------------------------------------------------------
function PANEL:UpdateProgress()
	local s = UI.Selected
	local running = s and (s.pendingLocal or s.pendingRemote) or false
	if IsValid(self.CancelBtn) then self.CancelBtn:SetEnabled(running) end
	if not s then
		self.Progress.Text = ""
		return
	end

	local parts = {}
	if s.pendingLocal then
		if s.localPhase == "scanning" then
			parts[#parts + 1] = Format(
				"scanning %d/%d files, %d matches",
				s.localScanned or 0, s.localTotal or 0, s.localMatched or 0
			)
		else
			parts[#parts + 1] = Format("discovering: %d dirs, %d files found", s.localDirs or 0, s.localDiscovered or 0)
		end
	end

	if s.pendingRemote then parts[#parts + 1] = "server: waiting..." end
	if #parts == 0 then
		self.Progress.Text = Format("%s%d results", s.cancelled and "Cancelled. " or "Done. ", #(s.results or {}))
	else
		local text = table.concat(parts, ", ")
		if s.pendingLocal and s.localPhase ~= "scanning" and s.localCurrentDir and s.localCurrentDir ~= "" then
			text = text .. "  -  " .. s.localCurrentDir
		end

		self.Progress.Text = text
	end
end

----------------------------------------------------------------------
-- Start / cancel / clear
----------------------------------------------------------------------
function PANEL:StartSearch()
	local opts = self:GetOpts()
	if opts.query == "" then return end
	local target = self.TargetCombo.NoirValue or "local"
	local perf = gatherPerf()

	-- Persist current settings.
	setSetting("rootDir", opts.rootDir)
	setSetting("glob", opts.glob)
	setSetting("pathID", opts.pathID)
	setSetting("caseInsensitive", opts.caseInsensitive)
	setSetting("target", target)

	-- Perf tuning travels with the opts (used locally and networked to server).
	opts.frameBudget = perf.frameBudget
	opts.maxDepth = perf.maxDepth
	opts.maxResults = perf.maxResults
	opts.maxFileSize = perf.maxFileSize
	opts.maxPreviewLen = perf.maxPreviewLen

	local search = {
		query = opts.query,
		opts = opts,
		target = target,
		results = {},
		pendingLocal = false,
		pendingRemote = false,
		cancelled = false,
		localPhase = "discovering"
	}

	table.insert(UI.Searches, 1, search)
	while #UI.Searches > UI.MaxSearches do table.remove(UI.Searches) end
	self:RefreshSearchesList()
	self:SelectSearch(search)

	if target == "local" or target == "both" then
		search.pendingLocal = true
		search.localJob = Noir.FileSearch.Start({
			query = opts.query,
			caseInsensitive = opts.caseInsensitive,
			rootDir = opts.rootDir,
			glob = opts.glob,
			pathID = opts.pathID,
			frameBudget = opts.frameBudget,
			maxDepth = opts.maxDepth,
			maxResults = opts.maxResults,
			maxFileSize = opts.maxFileSize,
			maxPreviewLen = opts.maxPreviewLen,
			realm = "local",
			onResult = function(_, result)
				search.results[#search.results + 1] = result
				if UI.Selected == search and IsValid(self) then self:AppendResultLine(result) end
			end,
			onProgress = function(job)
				search.localPhase = job.phase
				search.localDirs = job.dirsVisited
				search.localScanned = job.scanned
				search.localMatched = job.matched
				search.localTotal = job.total
				search.localDiscovered = #job.fileQueue
				search.localCurrentDir = job.currentDir
				search.localFrac, search.localIndeterminate = Noir.FileSearch.JobProgress(job)
				if not IsValid(self) then return end
				self:UpdateSearchRow(search)
				if UI.Selected == search then self:UpdateProgress() end
			end,
			onDone = function()
				search.pendingLocal = false
				search.localJob = nil
				if not IsValid(self) then return end
				self:UpdateSearchRow(search)
				if UI.Selected == search then self:UpdateProgress() end
			end
		})
	end

	if target == "server" or target == "both" then
		search.pendingRemote = true
		local requestId = Noir.FileSearch.SendRemote(opts, {
			OnRemoteResults = function(decoded)
				search.pendingRemote = false
				search.remoteRequestId = nil
				for _, result in ipairs(decoded.results or {}) do
					search.results[#search.results + 1] = result
					if UI.Selected == search and IsValid(self) then self:AppendResultLine(result) end
				end

				if not IsValid(self) then return end
				self:UpdateSearchRow(search)
				if UI.Selected == search then self:UpdateProgress() end
			end
		})

		search.remoteRequestId = requestId
		-- Server silently drops unauthorized requests; time out the spinner.
		timer.Simple(15, function()
			if not Noir.FileSearch.PendingRemote[requestId] then return end
			Noir.FileSearch.PendingRemote[requestId] = nil
			search.pendingRemote = false
			search.remoteRequestId = nil
			if IsValid(self) then
				self:UpdateSearchRow(search)
				if UI.Selected == search then self:UpdateProgress() end
			end

			Noir.Msg("Server search denied or timed out (needs superadmin)\n")
		end)
	end

	self:UpdateProgress()
end

function PANEL:CancelSearch()
	local s = UI.Selected
	if not s then return end
	if s.pendingLocal and s.localJob then
		Noir.FileSearch.CancelJob(s.localJob)
		s.localJob = nil
		s.pendingLocal = false
	end

	if s.pendingRemote then
		Noir.FileSearch.SendCancel(s.remoteRequestId)
		s.remoteRequestId = nil
		s.pendingRemote = false
	end

	s.cancelled = true
	self:UpdateSearchRow(s)
	self:UpdateProgress()
end

function PANEL:ClearSearches()
	for _, s in ipairs(UI.Searches) do
		if s.localJob then
			Noir.FileSearch.CancelJob(s.localJob)
			s.localJob = nil
		end

		if s.remoteRequestId then
			Noir.FileSearch.SendCancel(s.remoteRequestId)
			s.remoteRequestId = nil
		end

		s.results = nil -- free memory
	end

	UI.Searches = {}
	UI.Selected = nil
	self:RefreshSearchesList()
	self.Results:Clear()
	self:UpdateProgress()
end

vgui.Register("NoirFileSearch", PANEL, "EditablePanel")

----------------------------------------------------------------------
-- Window frame (mirrors Noir.FileBrowser.Show).
----------------------------------------------------------------------
function UI.Show()
	if IsValid(UI.Frame) then
		if Noir.DEBUG then
			UI.Frame:Remove()
		else
			UI.Frame:Show()
			UI.Frame:MakePopup()
			return UI.Frame
		end
	end

	local frame = vgui.Create("DFrame")
	frame:SetSkin("Noir")
	frame:SetMinHeight(300)
	frame:SetMinWidth(400)
	frame.lblTitle:SetVisible(false)
	frame:SetDeleteOnClose(false)
	frame:SetDraggable(true)
	frame:SetSizable(true)
	frame:MakePopup()
	frame.btnMaxim:SetVisible(false)
	frame.btnMinim:SetVisible(false)
	frame.PerformLayout = function()
		frame.btnClose:SetPos(frame:GetWide() - 31, 0)
		frame.btnClose:SetSize(31, 24)
	end

	frame:SetSize(1000, 560)
	frame:Center()
	frame:SetTitle("Find in Files")
	local content = frame:Add("NoirFileSearch")
	content:Dock(FILL)
	content:DockMargin(4, 26, 4, 4)
	frame.Content = content
	UI.Frame = frame
	return frame
end

concommand.Add("noir_showsearch", function() UI.Show() end, nil, "Open the Noir Find in Files window")

-- Dashboard registration is deferred to Noir.Load() so all native tabs
-- register in a deterministic order before autorun scripts run.
