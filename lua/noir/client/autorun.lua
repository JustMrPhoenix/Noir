local Autorun = Noir.Autorun or {}
Noir.Autorun = Autorun
Autorun.Scripts = {}
Autorun.Running = false
Autorun.Initialized = false
Autorun.CrashDetected = false
Autorun.DashboardRegistered = false
local SAVE_FILE = Noir.STORAGE_PATH .. "autorun.json"
-- Available execution realms for a script. Each script carries its own `target`;
-- there is no global run target. We deliberately don't offer "all clients"/networked
-- shared targets — those would require running on every joining player, which autorun
-- doesn't manage. "shared" here just means local + server.
--   self   -> local only (Noir.RunCode)
--   server -> server only (Noir.SendCode "server")
--   shared -> local AND server
Autorun.Realms = {
	{
		value = "self",
		label = "Local",
		icon = "icon16/user.png"
	},
	{
		value = "server",
		label = "Server",
		icon = "icon16/server.png"
	},
	{
		value = "shared",
		label = "Local + Server",
		icon = "icon16/world.png"
	}
}
Autorun.DefaultRealm = "self"
-- Human-readable label for a script's realm
function Autorun.RealmLabel(target)
	for _, realm in ipairs(Autorun.Realms) do
		if realm.value == target then return realm.label end
	end
	return target or Autorun.RealmLabel(Autorun.DefaultRealm)
end

-- Load autorun configuration
function Autorun.Load()
	if not file.Exists(SAVE_FILE, "DATA") then
		Autorun.Scripts = {}
		Autorun.Enabled = true
		Autorun.CrashDetected = false
		return
	end

	local content = file.Read(SAVE_FILE, "DATA")
	local data = util.JSONToTable(content)
	if not data then
		Noir.Warn("Autorun: Failed to parse ", SAVE_FILE, "\n")
		Autorun.Scripts = {}
		Autorun.Enabled = true
		Autorun.CrashDetected = false
		return
	end

	Autorun.Scripts = data.scripts or {}
	Autorun.Enabled = data.enabled ~= false
	-- Crash detection: if wasRunning is true, it means we crashed during autorun
	if data.wasRunning then
		Autorun.CrashDetected = true
		Autorun.Enabled = false
		Noir.Error("Autorun: Crash detected! Autorun has been disabled.\n")
		Noir.Error("Autorun: Re-enable it in the Dashboard if it's safe to do so.\n")
	end
end

-- Save autorun configuration
function Autorun.Save()
	local data = {
		scripts = Autorun.Scripts,
		enabled = Autorun.Enabled,
		wasRunning = Autorun.Running
	}

	file.Write(SAVE_FILE, util.TableToJSON(data, Noir.DEBUG))
end

-- Mark autorun as started (for crash detection)
function Autorun.MarkRunning()
	Autorun.Running = true
	Autorun.Save()
end

-- Mark autorun as completed (clears crash detection flag)
function Autorun.MarkCompleted()
	Autorun.Running = false
	Autorun.Save()
end

-- Check if a file is in the autorun list
function Autorun.IsAutorun(path, fileName)
	for _, script in ipairs(Autorun.Scripts) do
		if script.path == path and script.file == fileName then return true end
	end
	return false
end

-- Add a script to autorun (with an optional execution realm, defaults to "self")
function Autorun.Add(path, fileName, target)
	if Autorun.IsAutorun(path, fileName) then return false end
	table.insert(Autorun.Scripts, {
		path = path,
		file = fileName,
		target = target or Autorun.DefaultRealm
	})

	Autorun.Save()
	return true
end

-- Remove a script from autorun
function Autorun.Remove(path, fileName)
	for i, script in ipairs(Autorun.Scripts) do
		if script.path == path and script.file == fileName then
			table.remove(Autorun.Scripts, i)
			Autorun.Save()
			return true
		end
	end
	return false
end

-- Toggle a script's autorun status
function Autorun.Toggle(path, fileName, target)
	if Autorun.IsAutorun(path, fileName) then
		return Autorun.Remove(path, fileName), false
	else
		return Autorun.Add(path, fileName, target), true
	end
end

-- Read file content
function Autorun.ReadFile(path, fileName)
	local content = file.Read(fileName, path)
	if not content then return nil, Format("Could not read file [%s] %s", path, fileName) end
	return content
end

-- Run a single autorun script. Realm decides where it runs:
--   self -> local, server -> server, shared -> both.
function Autorun.RunScript(script, callback)
	local identifier = string.GetFileFromFilename(script.file) or script.file
	local target = script.target or Autorun.DefaultRealm
	local runLocal = target == "self" or target == "shared"
	local runServer = target == "server" or target == "shared"
	-- Read file content if any part needs it. Files in the game's lua folder
	-- (workshop addons, gamemodes, etc.) often aren't readable via file.Read, so
	-- the local part compiles them with CompileFile instead and skips the read.
	local content
	if runServer or (runLocal and script.path ~= "LUA") then
		local err
		content, err = Autorun.ReadFile(script.path, script.file)
		if not content then
			Noir.Error("Autorun: ", err, "\n")
			if callback then callback(false, err) end
			return false
		end
	end

	-- Local execution
	if runLocal then
		local success, result
		if script.path == "LUA" then
			local func = CompileFile(script.file)
			if not isfunction(func) then
				local err = "Could not compile Lua file: " .. script.file
				Noir.Error("Autorun: ", err, "\n")
				if callback then callback(false, err) end
				return false
			end

			success, result = pcall(func)
		else
			success, result = Noir.RunCode(content, identifier)
		end

		if not success then
			Noir.Error("Autorun error in ", identifier, ": ", tostring(result), "\n")
			if callback then callback(false, result) end
			return false
		end
	end

	-- Server execution
	if runServer then Noir.SendCode(content, identifier, "server") end
	if callback then callback(true) end
	return true
end

-- Run all autorun scripts
function Autorun.RunAll(callback)
	if #Autorun.Scripts == 0 then
		Noir.Msg("Autorun: No scripts to run\n")
		if callback then callback(true, 0) end
		return
	end

	-- Mark as running for crash detection
	Autorun.MarkRunning()
	local total = #Autorun.Scripts
	local completed = 0
	local errors = 0
	Noir.Msg("Autorun: Running ", total, " script(s)...\n")
	local function runNext(index)
		if index > total then
			-- Mark as completed (clears crash detection flag)
			Autorun.MarkCompleted()
			Noir.Msg("Autorun: Completed ", completed, "/", total, " scripts")
			if errors > 0 then Noir.Msg(" (", errors, " errors)") end
			Noir.Msg("\n")
			if callback then callback(errors == 0, completed) end
			return
		end

		local script = Autorun.Scripts[index]
		Noir.Debug("Autorun: Running ", script.file)
		Autorun.RunScript(script, function(success, err)
			if success then
				completed = completed + 1
			else
				errors = errors + 1
			end

			-- Small delay between scripts to avoid overwhelming
			timer.Simple(0.1, function() runNext(index + 1) end)
		end)
	end

	runNext(1)
end

-- Called when Noir is fully loaded
function Autorun.Initialize()
	if Autorun.Initialized then return end
	Autorun.Initialized = true
	-- Ensure dashboard is registered first (safety check)
	if not Autorun.DashboardRegistered then Autorun.RegisterDashboard() end
	-- Skip autorun if crash was detected (warning already shown on load)
	if Autorun.CrashDetected then return end
	if not Autorun.Enabled then
		Noir.Debug("Autorun: Disabled, skipping\n")
		return
	end

	if #Autorun.Scripts == 0 then
		Noir.Debug("Autorun: No scripts configured\n")
		return
	end

	-- Delay autorun slightly to let everything initialize
	timer.Simple(0.5, function() Autorun.RunAll() end)
end

-- Get display name for a script
function Autorun.GetDisplayName(script)
	local name = string.GetFileFromFilename(script.file) or script.file
	return Format("[%s] [%s] %s", Autorun.RealmLabel(script.target), script.path, name)
end

-- Register Dashboard settings
function Autorun.RegisterDashboard()
	-- Unregister first if already registered (for re-registration after crash warning)
	if Autorun.DashboardRegistered then Noir.Dashboard.Unregister("Autorun") end
	local scriptSuggestions = function()
		local suggestions = {}
		-- Add recent files from editor config
		if Noir.Editor and Noir.Editor.Config and Noir.Editor.Config.recentFiles then
			for _, recent in ipairs(Noir.Editor.Config.recentFiles) do
				table.insert(suggestions, {
					label = Format("[%s] %s", recent[1], string.GetFileFromFilename(recent[2]) or recent[2]),
					value = {
						path = recent[1],
						file = recent[2],
						target = Autorun.DefaultRealm
					}
				})
			end
		end
		return suggestions
	end

	local settings = {}
	-- Show crash warning if detected
	if Autorun.CrashDetected then
		table.insert(settings, {
			key = "crashWarning",
			type = "button",
			label = "Crash Detected - Click to Acknowledge",
			description = "A crash was detected during the last autorun. Click to clear this warning and re-enable autorun.",
			category = "Warning",
			callback = function()
				Autorun.CrashDetected = false
				Autorun.Enabled = true
				Autorun.Save()
				Noir.Msg("Autorun: Crash warning acknowledged. Autorun re-enabled.\n")
				-- Refresh dashboard to remove warning
				timer.Simple(0.1, function() Autorun.RegisterDashboard() end)
			end
		})
	end

	table.insert(settings, {
		key = "enabled",
		type = "bool",
		label = "Enable Autorun",
		description = "Run scripts automatically when Noir starts",
		default = true,
		category = "General"
	})

	table.insert(settings, {
		key = "runNow",
		type = "button",
		label = "Run Autorun Scripts Now",
		description = "Manually trigger all autorun scripts",
		category = "General",
		callback = function() Autorun.RunAll() end
	})

	table.insert(settings, {
		key = "scripts",
		type = "list",
		label = "Autorun Scripts",
		description = "Scripts to run on startup. Right-click a script to set the realm it runs in.",
		category = "Scripts",
		default = {},
		suggestOptions = scriptSuggestions,
		itemValidator = function(text)
			-- Accept format like "[PATH] filename" or just filename (assumes DATA)
			local path, filename = string.match(text, "^%[([^%]]+)%]%s*(.+)$")
			if path and filename then
				return {
					path = path,
					file = filename,
					target = Autorun.DefaultRealm
				}
			end
			-- Assume DATA path if not specified
			return {
				path = "DATA",
				file = text,
				target = Autorun.DefaultRealm
			}
		end,
		displayFormatter = function(item)
			if istable(item) and item.path and item.file then
				local name = string.GetFileFromFilename(item.file) or item.file
				return Format("[%s] [%s] %s", Autorun.RealmLabel(item.target), item.path, name)
			end
			return tostring(item)
		end,
		-- Per-script realm picker (right-click menu submenu). The callback mutates the
		-- item in place; the dashboard re-saves the list and refreshes afterwards.
		itemActions = function(item)
			if not istable(item) then return end
			local submenu = {}
			local current = item.target or Autorun.DefaultRealm
			for _, realm in ipairs(Autorun.Realms) do
				table.insert(submenu, {
					label = realm.label .. (current == realm.value and "  (current)" or ""),
					icon = realm.icon,
					callback = function(it) it.target = realm.value end
				})
			end
			return {
				{
					label = "Set Realm",
					icon = "icon16/server_go.png",
					submenu = submenu
				}
			}
		end
	})

	Noir.Dashboard.Register("Autorun", settings, {
		icon = "icon16/control_play_blue.png",
		description = "Configure scripts to run automatically when Noir starts"
	})

	-- Sync Dashboard values with Autorun state
	Noir.Dashboard.OnChange("Autorun", "enabled", function(value)
		Autorun.Enabled = value
		Autorun.Save()
	end)

	Noir.Dashboard.OnChange("Autorun", "scripts", function(value)
		Autorun.Scripts = value or {}
		Autorun.Save()
	end)

	-- Initialize Dashboard values from saved config
	if Autorun.Enabled ~= nil then Noir.Dashboard.Set("Autorun", "enabled", Autorun.Enabled, true) end
	if #Autorun.Scripts > 0 then Noir.Dashboard.Set("Autorun", "scripts", Autorun.Scripts, true) end
	Autorun.DashboardRegistered = true
end

-- Initialize
Autorun.Load()
-- Register dashboard immediately (Dashboard.Load() is already called by dashboard.lua)
Autorun.RegisterDashboard()
-- Clear running flag on clean shutdown
hook.Add("ShutDown", "NoirAutorunShutdown", function() if Autorun.Running then Autorun.MarkCompleted() end end)
