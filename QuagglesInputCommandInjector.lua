local lfs = require('lfs')
local log = require('log')
local quagglesLogName = 'Quaggles.InputCommandInjector'
local openErrorDialogs = {}
local suppressedErrorDialogs = {}
local suppressAllErrorDialogs = false

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

	local repoLink = showRepoLink == false and '' or '\n\nPlease check for a newer version:\nhttps://github.com/Quaggles/dcs-input-command-injector'
	local dialogText = 'Quaggles Input Command Injector failed:\n\n'..dialogMessage..repoLink
	if suppressAllErrorDialogs or openErrorDialogs[dialogText] or suppressedErrorDialogs[dialogText] then
		return
	end
	openErrorDialogs[dialogText] = true

	local shown, showError = pcall(function()
		local okToAll = 'OK to All'
		local ok = 'OK'
		local handler = MsgWindow.error(dialogText, 'Quaggles Input Command Injector', okToAll, ok)
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

local function QuagglesInputCommandInjector(deviceGenericName, filename, folder, env, result)
	local quagglesLoggingEnabled = false
	-- Returns true if string starts with supplied string
	local function StartsWith(String,Start)
		return string.sub(String,1,string.len(Start))==Start
	end

	if quagglesLoggingEnabled then log.write(quagglesLogName, log.INFO, 'Detected loading of type: "'..deviceGenericName..'", filename: "'..filename..'"') end
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
		if quagglesLoggingEnabled then log.write(quagglesLogName, log.INFO, '--Translated path: "'..newFileName..'"') end

		-- If the user has put a file there continue
		if lfs.attributes(newFileName) then
			if quagglesLoggingEnabled then log.write(quagglesLogName, log.INFO, '----Found merge at: "'..newFileName..'"') end
			--Configure file to run in same environment as the default command entry file
			local f, err = loadfile(newFileName)
			if err ~= nil then
				reportError('Failed to load custom input commands from "'..tostring(newFileName)..'": '..tostring(err), false)
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
					if quagglesLoggingEnabled then log.write(quagglesLogName, log.INFO, '------Merge successful') end
				else
					if quagglesLoggingEnabled then log.write(quagglesLogName, log.INFO, '------Merge failed: "'..tostring(statusInj)..'"') end
					reportError('Failed to execute custom input commands from "'..tostring(newFileName)..'": '..tostring(resultInj), false)
				end
			end
		end
	end
end

local function install()
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
				local injected, injectionError = pcall(QuagglesInputCommandInjector, deviceGenericName, filename, env.folder, env, result)
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

-- Keep a hook installation failure from preventing other DCS hooks from loading.
local ok, err = pcall(install)
if not ok then
	reportError('Unable to install: '..tostring(err))
end
