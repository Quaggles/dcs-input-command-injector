local lfs = require('lfs')
local log = require('log')
local Serializer = require('Serializer')
local quagglesLogName = 'Quaggles.InputCommandInjector'
-- Release packaging replaces this placeholder in the staged copy; source checkouts remain unversioned.
local quagglesVersion = '__QUAGGLES_VERSION__'
local updateUrl = 'https://api.github.com/repos/Quaggles/dcs-input-command-injector/releases/latest'
local updateInterval = 7 * 24 * 60 * 60
local testedDataLuaHashes = {
	['efb180c5feca96373c3f03bc4661be9a'] = true, -- DCS 2.9.28.26385
}
local openErrorDialogs = {}
local suppressedErrorDialogs = {}
local suppressAllErrorDialogs = false

local settingsDirectory = lfs.writedir()..'InputCommands'
local settingsPath = settingsDirectory..'\\settings.lua'
local statePath = settingsDirectory..'\\state.lua'

-- Parse a dotted numeric version, optionally prefixed with "v", for both mod and DCS versions.
local function versionParts(version)
	if type(version) ~= 'string' then
		return nil
	end
	if version:sub(1, 1) == 'v' then
		version = version:sub(2)
	end
	if version == '' or version:find('[^%d%.]') or version:find('..', 1, true) or
		version:sub(1, 1) == '.' or version:sub(-1) == '.' then
		return nil
	end

	local parts = {}
	for part in version:gmatch('[^.]+') do
		parts[#parts + 1] = tonumber(part)
	end
	return parts
end

-- Compare dotted versions numerically, returning -1, 0, 1, or nil for invalid input.
local function compareVersions(left, right)
	local leftParts = versionParts(left)
	local rightParts = versionParts(right)
	if not leftParts or not rightParts then
		return nil
	end
	for index = 1, math.max(#leftParts, #rightParts) do
		local leftPart = leftParts[index] or 0
		local rightPart = rightParts[index] or 0
		if leftPart ~= rightPart then
			return leftPart < rightPart and -1 or 1
		end
	end
	return 0
end

-- Check weekly, after clock rollback, or when DCS advances beyond the highest version already seen.
local function shouldCheckForUpdate(settings, state, now, dcsVersion)
	if settings.disableUpdateCheck then
		return false
	end
	local lastCheck = state.lastUpdateCheck
	if type(lastCheck) ~= 'number' or now < lastCheck or now - lastCheck >= updateInterval then
		return true
	end
	if not versionParts(dcsVersion) then
		return false
	end
	local dcsComparison = compareVersions(dcsVersion, state.lastDcsVersion)
	return dcsComparison == nil or dcsComparison > 0
end
local function reportError(message, showRepoLink)
	message = tostring(message)
	log.write(quagglesLogName, log.ERROR, message)

	local lines = {}
	local truncated = false
	for line in (message..'\n'):gmatch('(.-)\n') do
		if #lines == 12 then
			truncated = true
			break
		end
		lines[#lines + 1] = line
	end
	local dialogMessage = table.concat(lines, '\n')
	if #dialogMessage > 1000 then
		dialogMessage = dialogMessage:sub(1, 1000)
		truncated = true
	end
	if truncated then
		dialogMessage = dialogMessage..'\n\n[Error truncated; see dcs.log for full details.]'
	end

	local loaded, MsgWindow = pcall(require, 'MsgWindow')
	if not loaded then
		log.write(quagglesLogName, log.ERROR, 'Unable to display error message: '..tostring(MsgWindow))
		return
	end
	local repoLink = showRepoLink == false and '' or '\n\nCheck for a newer version of the mod. Current: v'..quagglesVersion..', new versions can be found at:\nhttps://github.com/Quaggles/dcs-input-command-injector/releases'
	local dialogText = 'Input Command Injector Mod error:\n\n'..dialogMessage..repoLink
	if suppressAllErrorDialogs or openErrorDialogs[dialogText] or suppressedErrorDialogs[dialogText] then
		return
	end
	openErrorDialogs[dialogText] = true

	local shown, showError = pcall(function()
		local okToAll = 'OK to All'
		local ok = 'OK'
		local handler = MsgWindow.error(dialogText, 'Input Command Injector Mod Error', okToAll, ok)
		function handler:onChange(buttonText)
			openErrorDialogs[dialogText] = nil
			if buttonText == okToAll then
				suppressAllErrorDialogs = true
			elseif buttonText == ok then
				suppressedErrorDialogs[dialogText] = true
			end
		end
		function handler:onClose()
			openErrorDialogs[dialogText] = nil
			return false
		end
		handler:setDefaultButton(ok)
		handler:show()
	end)
	if not shown then
		openErrorDialogs[dialogText] = nil
		log.write(quagglesLogName, log.ERROR, 'Unable to display error message: '..tostring(showError))
	end
end

-- Display update availability separately from injector errors so network failures remain silent to users.
local function reportUpdate(latestVersion, releaseUrl)
	local loaded, MsgWindow = pcall(require, 'MsgWindow')
	if not loaded then
		log.write(quagglesLogName, log.WARNING, 'Unable to display update message: '..tostring(MsgWindow))
		return
	end

	local shown, showError = pcall(function()
		local ok = 'OK'
		local message = 'A new Quaggles Input Command Injector version is available!\n\n'..
			'Current: v'..quagglesVersion..'\nNew: v'..latestVersion..'\n\nDownload from:\n'..releaseUrl..'\n\nTo disable update checks, set ["disableUpdateCheck"] = true in:\n'..settingsPath
		local handler = MsgWindow.info(message, 'Input Command Injector Mod Update', ok)
		handler:setDefaultButton(ok)
		handler:show()
	end)
	if not shown then
		log.write(quagglesLogName, log.WARNING, 'Unable to display update message: '..tostring(showError))
	end
end

-- Persist a small sandboxed Lua table directly.
local function saveTable(path, name, value)
	local file, openError = io.open(path, 'w')
	if not file then
		return false, openError
	end

	local written, writeError = pcall(function()
		Serializer.new(file):serialize_sorted(name, value)
	end)
	local closed, closeError = pcall(function() file:close() end)
	if not written or not closed then
		return false, writeError or closeError
	end
	return true
end

local function loadTable(path, name)
	local chunk, loadError = loadfile(path)
	if not chunk then
		error(loadError)
	end
	local environment = {}
	setfenv(chunk, environment)
	local loaded, loadError = pcall(chunk)
	local value = environment[name]
	if not loaded or type(value) ~= 'table' then
		error(loadError or 'expected a '..name..' table')
	end
	return value
end

-- Create defaults when absent and sandbox/validate an existing Lua settings file before using it.
local function loadSettings()
	local fallback = {verboseLogging = false, disableUpdateCheck = false, disableDataLuaHashWarning = false}
	local directoryAttributes = lfs.attributes(settingsDirectory)
	if directoryAttributes and directoryAttributes.mode ~= 'directory' then
		log.write(quagglesLogName, log.WARNING, 'Settings path is not a directory: '..settingsDirectory)
		return fallback
	elseif not directoryAttributes then
		local created, createError = lfs.mkdir(settingsDirectory)
		if not created then
			log.write(quagglesLogName, log.WARNING, 'Unable to create settings directory: '..tostring(createError))
			return fallback
		end
	end

	if not lfs.attributes(settingsPath) then
		local settings = fallback
		local saved, saveError = saveTable(settingsPath, 'settings', settings)
		if not saved then
			log.write(quagglesLogName, log.WARNING, 'Unable to create settings: '..tostring(saveError))
		end
		return settings
	end

	local settings = loadTable(settingsPath, 'settings')
	local valid = (settings.verboseLogging == nil or type(settings.verboseLogging) == 'boolean') and
		(settings.disableUpdateCheck == nil or type(settings.disableUpdateCheck) == 'boolean') and
		(settings.disableDataLuaHashWarning == nil or type(settings.disableDataLuaHashWarning) == 'boolean')
	if not valid then
		error('Invalid values in settings; file left unchanged')
	end
	settings.verboseLogging = settings.verboseLogging == true
	settings.disableUpdateCheck = settings.disableUpdateCheck == true
	settings.disableDataLuaHashWarning = settings.disableDataLuaHashWarning == true
	return settings
end

-- State is mod-owned and disposable, so replace unreadable or invalid state with fresh defaults.
local function loadState()
	local fallback = {warnedDataLuaHashes = {}}
	if not lfs.attributes(statePath) then
		local saved, saveError = saveTable(statePath, 'state', fallback)
		if not saved then
			log.write(quagglesLogName, log.WARNING, 'Unable to create state: '..tostring(saveError))
		end
		return fallback
	end

	local loaded, state = pcall(loadTable, statePath, 'state')
	local hashesValid = loaded and (state.warnedDataLuaHashes == nil or type(state.warnedDataLuaHashes) == 'table')
	if hashesValid and state.warnedDataLuaHashes then
		for hash, warned in pairs(state.warnedDataLuaHashes) do
			if type(hash) ~= 'string' or #hash ~= 32 or not hash:match('^[0-9a-f]+$') or warned ~= true then
				hashesValid = false
				break
			end
		end
	end
	local valid = hashesValid and
		(state.lastUpdateCheck == nil or
			(type(state.lastUpdateCheck) == 'number' and state.lastUpdateCheck >= 0 and state.lastUpdateCheck == math.floor(state.lastUpdateCheck))) and
		(state.lastDcsVersion == nil or versionParts(state.lastDcsVersion) ~= nil)
	if valid then
		state.warnedDataLuaHashes = state.warnedDataLuaHashes or {}
		return state
	end

	log.write(quagglesLogName, log.WARNING, 'Unable to read state; resetting it: '..tostring(loaded and 'invalid values' or state))
	local saved, saveError = saveTable(statePath, 'state', fallback)
	if not saved then
		log.write(quagglesLogName, log.WARNING, 'Unable to reset state: '..tostring(saveError))
	end
	return fallback
end

-- Hash a file with DCS's bundled native MD5 implementation.
local function md5(path)
	local hashed, digest = pcall(function()
		local file = assert(io.open(path, 'rb'))
		local contents, readError = file:read('*a')
		file:close()
		assert(contents, readError)
		local loadMd5 = assert(package.loadlib(lfs.currentdir()..'/bin/lua-md5.dll', 'luaopen_md5_core'))
		return loadMd5().sum(contents)
	end)
	if not hashed or type(digest) ~= 'string' or #digest ~= 16 then
		return nil, 'Unable to hash "'..path..'": '..tostring(digest)
	end
	return (digest:gsub('.', function(character)
		return string.format('%02x', string.byte(character))
	end))
end

-- Warn without blocking installation when the input loader has not been tested with this hook.
local function checkDataLuaCompatibility(settings, state)
	if settings.disableDataLuaHashWarning then
		return
	end

	local hash, hashError = md5(lfs.currentdir()..'/Scripts/Input/Data.lua')
	local message
	local onDismiss
	if not hash then
		log.write(quagglesLogName, log.WARNING, hashError)
		message = 'Quaggles Input Command Injector could not verify compatibility with DCS Input Data.lua.\n\n'..
			'The injector will continue loading. See dcs.log for details.'
	elseif testedDataLuaHashes[hash] or state.warnedDataLuaHashes[hash] then
		return
	else
		local dcsVersion = rawget(_G, '__DCS_VERSION__') or rawget(_G, '_APP_VERSION') or 'unknown'
		message = 'Your DCS version ('..tostring(dcsVersion)..') is not tested for compatibility with Input Command Injector v'..quagglesVersion..',\nit changed a file the mod uses:\n\n'..
			'"DCS World/Scripts/Input/Data.lua" hash: '..string.sub(hash, 1, 7)..'\n\n'..
			'The injector will still run and could still work but if you encounter issues or errors,\n'..
			'remove the mod first to see if that fixes the issue before reporting bugs to Eagle Dynamics.\n\n'..
			'This warning will not show again for this version of DCS World.\n\n'..
			'To disable these warnings completely, set ["disableDataLuaHashWarning"] = true in:\n'..settingsPath
		onDismiss = function()
			state.warnedDataLuaHashes[hash] = true
			local saved, saveError = saveTable(statePath, 'state', state)
			if not saved then
				log.write(quagglesLogName, log.WARNING, 'Unable to save dismissed Data.lua warning: '..tostring(saveError))
			end
		end
	end

	log.write(quagglesLogName, log.WARNING, message)
	local ok = 'OK'
	local handler = require('MsgWindow').warning(message, 'Input Command Injector Mod Compatibility', ok)
	function handler:onChange(buttonText)
		if buttonText == ok and onDismiss then
			onDismiss()
		end
	end
	handler:setDefaultButton(ok)
	handler:show()
end

-- Start a best-effort HTTPS check using DCS's native asynchronous web and GUI update APIs.
local function startUpdateCheck(settings, state)
	if settings.disableUpdateCheck then
		return
	end
	if not versionParts(quagglesVersion) then
		log.write(quagglesLogName, log.INFO, 'Update check skipped for an unversioned development copy')
		return
	end

	local dcsVersion = rawget(_G, '__DCS_VERSION__') or rawget(_G, '_APP_VERSION')
	local now = os.time()
	if not shouldCheckForUpdate(settings, state, now, dcsVersion) then
		return
	end

	local UpdateManager = require('UpdateManager')
	if type(DcsWeb) ~= 'table' or type(DcsWeb.send_request) ~= 'function' or
		type(DcsWeb.get_status) ~= 'function' or type(DcsWeb.get_data) ~= 'function' or
		type(DcsWeb.drop_result) ~= 'function' or type(UpdateManager.add) ~= 'function' or
		type(net) ~= 'table' or type(net.json2lua) ~= 'function' then
		error('DCS web API is unavailable')
	end

	-- Record completed attempts even on HTTP failure so an offline startup does not retry every launch.
	local function recordAttempt()
		state.lastUpdateCheck = os.time()
		local comparison = compareVersions(dcsVersion, state.lastDcsVersion)
		if versionParts(dcsVersion) and (comparison == nil or comparison > 0) then
			state.lastDcsVersion = dcsVersion
		end
		local saved, saveError = saveTable(statePath, 'state', state)
		if not saved then
			log.write(quagglesLogName, log.WARNING, 'Unable to save update state: '..tostring(saveError))
		end
	end

	local requested, requestError = pcall(DcsWeb.send_request, updateUrl)
	if not requested then
		recordAttempt()
		error('Unable to start update request: '..tostring(requestError))
	end

	local startedAt = type(DCS) == 'table' and type(DCS.getRealTime) == 'function' and DCS.getRealTime() or os.time()
	-- UpdateManager runs this once per GUI frame; returning true unregisters it, false keeps polling.
	UpdateManager.add(function()
		local completed, completionError = pcall(function()
			local status = DcsWeb.get_status(updateUrl)
			local currentTime = type(DCS) == 'table' and type(DCS.getRealTime) == 'function' and DCS.getRealTime() or os.time()
			if status == 102 and currentTime - startedAt < 15 then
				return false
			end

			local response = status == 200 and DcsWeb.get_data(updateUrl) or nil
			DcsWeb.drop_result(updateUrl)
			recordAttempt()
			if status ~= 200 then
				log.write(quagglesLogName, log.WARNING, 'Update check failed with status '..tostring(status))
				return true
			end

			local parsed, release = pcall(net.json2lua, response)
			if not parsed or type(release) ~= 'table' or type(release.tag_name) ~= 'string' then
				log.write(quagglesLogName, log.WARNING, 'Unable to parse GitHub release response')
				return true
			end
			if compareVersions(release.tag_name, quagglesVersion) == 1 then
				reportUpdate(release.tag_name, release.html_url or 'https://github.com/Quaggles/dcs-input-command-injector/releases/latest')
			end
			return true
		end)
		if not completed then
			pcall(DcsWeb.drop_result, updateUrl)
			recordAttempt()
			log.write(quagglesLogName, log.WARNING, 'Update check failed: '..tostring(completionError))
			return true
		end
		return completionError
	end)
end

local function QuagglesInputCommandInjector(deviceGenericName, filename, folder, env, result, verboseLogging)
	-- Returns true if string starts with supplied string
	local function StartsWith(String,Start)
		return string.sub(String,1,string.len(Start))==Start
	end

	if verboseLogging then log.write(quagglesLogName, log.INFO, 'Detected loading of type: "'..deviceGenericName..'", filename: "'..filename..'"') end
	-- Only operate on files that are in this folder
	local targetPrefixForAircrafts = "./Mods/aircraft/"
	local targetPrefixForDotConfig = "./Config/Input/"
	local targetPrefixForConfig    = "Config/Input/"
	local targetPrefix = nil
	if StartsWith(filename, targetPrefixForAircrafts) and StartsWith(folder, targetPrefixForAircrafts) then
		targetPrefix = targetPrefixForAircrafts
	elseif StartsWith(filename, targetPrefixForDotConfig) and StartsWith(folder, targetPrefixForDotConfig) then
		targetPrefix = targetPrefixForDotConfig
	elseif StartsWith(filename, targetPrefixForConfig) then
		targetPrefix = targetPrefixForConfig
	end
	if targetPrefix then
		-- Transform path to user folder
		local newFileName = filename:gsub(targetPrefix, lfs.writedir():gsub('\\','/').."InputCommands/")
		if verboseLogging then log.write(quagglesLogName, log.INFO, '--Translated path: "'..newFileName..'"') end

		-- If the user has put a file there continue
		if lfs.attributes(newFileName) then
			if verboseLogging then log.write(quagglesLogName, log.INFO, '----Found merge at: "'..newFileName..'"') end
			--Configure file to run in same environment as the default command entry file
			local f, err = loadfile(newFileName)
			if err ~= nil then
				reportError('Failed to load custom input commands from:\n'..tostring(newFileName)..':\n\nError:\n'..tostring(err), false)
				return
			else
				setfenv(f, env)
				local statusInj, resultInj
				statusInj, resultInj = pcall(f)

				-- Merge resulting tables
				if statusInj then
					if result.keyCommands and resultInj.keyCommands then -- If both exist then join
						env.join(result.keyCommands, resultInj.keyCommands)
					elseif resultInj.keyCommands then -- If just the injected one exists then use it
						result.keyCommands = resultInj.keyCommands
					end
					if deviceGenericName ~= "Keyboard" then -- Don't add axisCommands for keyboard
						if result.axisCommands and resultInj.axisCommands then -- If both exist then join
							env.join(result.axisCommands, resultInj.axisCommands)
						elseif resultInj.axisCommands then  -- If just the injected one exists then use it
							result.axisCommands = resultInj.axisCommands
						end
					end
					if verboseLogging then log.write(quagglesLogName, log.INFO, '------Merge successful') end
				else
					if verboseLogging then log.write(quagglesLogName, log.INFO, '------Merge failed: "'..tostring(statusInj)..'"') end
					reportError('Failed to execute custom input commands from "'..tostring(newFileName)..'": '..tostring(resultInj), false)
				end
			end
		end
	end
end

local function install(settings)
	local InputData = require('Input.Data')
	local InputUtils = require('Input.Utils')
	if type(getfenv) ~= 'function' or type(setfenv) ~= 'function' then
		error('DCS input loader does not expose function environments')
	end
	if type(InputData.loadDeviceProfileFromFile) ~= 'function' or
		type(InputData.getUiProfileName) ~= 'function' or
		type(InputUtils.getDeviceTemplateName) ~= 'function' then
		error('DCS input loader API is incompatible')
	end

	local loader = InputData.loadDeviceProfileFromFile
	local loaderEnvironment = getfenv(loader)
	if type(loaderEnvironment) ~= 'table' then
		error('DCS input loader environment is incompatible')
	end

	-- The marker is stored in the replacement environment to avoid wrapping the loader twice.
	if not loaderEnvironment.__quagglesInputCommandInjector then
		local originalLoadfile = loaderEnvironment.loadfile or loadfile
		if type(originalLoadfile) ~= 'function' then
			error('DCS input loader does not expose loadfile')
		end

		local loadfileIntercepted = false -- DCS resolved loadfile through our replacement environment.
		local profileWrapperExecuted = false -- DCS executed a chunk returned by the intercepted loadfile.
		local profileContractVerified = false -- The chunk received the profile environment and returned a command table.
		local compatibilityErrorLogged = false -- Prevent repeated errors after an incompatible DCS input-loader contract disables the injector.

		-- Override only loadfile while leaving every other loader global unchanged.
		local interceptedEnvironment = setmetatable({__quagglesInputCommandInjector = true}, {__index = loaderEnvironment})

		interceptedEnvironment.loadfile = function(filename)
			loadfileIntercepted = true
			local f, err = originalLoadfile(filename)
			if not f then
				return nil, err
			end

			-- DCS sets the input command environment on this returned function before running it.
			return function(...)
				profileWrapperExecuted = true
				local env = getfenv()
				-- Run the original profile in that environment, then apply the original injector to its result.
				setfenv(f, env)
				local result = f(...)
				-- Other loadfile calls made by the loader are not input profiles and have no profile environment.
				if type(env) ~= 'table' or env.filename ~= filename then
					return result
				end
				if type(env.folder) ~= 'string' or type(env.join) ~= 'function' or type(result) ~= 'table' then
					local restored, restoreError = pcall(setfenv, loader, loaderEnvironment)
					if not compatibilityErrorLogged then
						compatibilityErrorLogged = true
						local message = 'DCS input profile environment is incompatible; injector disabled'
						if not restored then
							message = message..'. Failed to restore DCS input loader: '..tostring(restoreError)
						end
						reportError(message)
					end
					return result
				end
				profileContractVerified = true
				local deviceGenericName
				if env.deviceName ~= nil then
					deviceGenericName = InputUtils.getDeviceTemplateName(env.deviceName)
				end
				local injected, injectionError = pcall(QuagglesInputCommandInjector, deviceGenericName, filename, env.folder, env, result, settings.verboseLogging)
				if not injected then
					reportError('Failed to inject custom input commands from "'..tostring(filename)..'": '..tostring(injectionError))
				end
				return result
			end
		end

		local installed, installError = pcall(function()
			-- Make the loader resolve loadfile through the intercepted environment.
			setfenv(loader, interceptedEnvironment)
			if getfenv(loader) ~= interceptedEnvironment then
				error('DCS input loader environment could not be replaced')
			end

			-- Hooks load after the UI profile, while aircraft profiles load later.
			if InputData.getUiProfileName() then
				local InputLoader = require('Input.Loader')
				if type(InputLoader.loadUiLayer) ~= 'function' then
					error('DCS UI input loader API is incompatible')
				end
				InputLoader.loadUiLayer('./Config/Input/')
				if not loadfileIntercepted or not profileWrapperExecuted or not profileContractVerified then
					error('DCS input loader interception could not be verified')
				end
			end
		end)
		if not installed then
			local restored, restoreError = pcall(setfenv, loader, loaderEnvironment)
			if not restored then
				error(tostring(installError)..'; failed to restore DCS input loader: '..tostring(restoreError))
			end
			error(installError)
		end
	end
end

-- Warn the user if they install the hook into Saved Games as Data.lua injection won't work when run from there
local scriptPath = debug.getinfo(1, 'S').source:gsub('^@', ''):gsub('/', '\\')
local scriptDirectory = scriptPath:lower():match('^(.*)\\[^\\]+$')
local writeHooksDirectory = (lfs.writedir()..'Scripts/Hooks'):gsub('/', '\\'):lower()
if scriptDirectory == writeHooksDirectory then
	reportError('The Input Command Injector Mod is erroneously installed at:\n'..scriptPath..'\n\nThe mod only works when installed in:\n'..lfs.currentdir()..'Scripts\\Hooks', false)
	return
end

local settingsLoaded, settings = pcall(loadSettings)
if not settingsLoaded then
	reportError('Unable to read settings:\n'..tostring(settings), false)
	return
end

local stateLoaded, state = pcall(loadState)
if not stateLoaded then
	log.write(quagglesLogName, log.WARNING, 'Unable to load state; using fresh state in memory: '..tostring(state))
	state = {warnedDataLuaHashes = {}}
end

local compatibilityOk, compatibilityError = pcall(checkDataLuaCompatibility, settings, state)
if not compatibilityOk then
	log.write(quagglesLogName, log.WARNING, 'Unable to check Data.lua compatibility: '..tostring(compatibilityError))
end

local ok, err = pcall(install, settings)
if not ok then
	reportError('Unable to inject:\n'..tostring(err))
end

-- Update failures must never prevent the injector or other DCS hooks from loading.
local updateOk, updateError = pcall(startUpdateCheck, settings, state)
if not updateOk then
	log.write(quagglesLogName, log.WARNING, 'Unable to start update check: '..tostring(updateError))
end
