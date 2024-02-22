local InputUtils		= require('Input.Utils'	)
local Input				= require('Input'		)
local lfs				= require('lfs'			)
local U					= require('me_utilities')
local Serializer		= require('Serializer'	)
local textutil			= require('textutil'	)
local i18n				= require('i18n'		)
local log 				= require('log')

local _ = i18n.ptranslate

--forward declaration 
local unloadProfile
local loadProfile
local createAxisFilter 
local applyDiffToDeviceProfile_
local wizard_assigments
local default_assignments

local userConfigPath_
local sysConfigPath_
local sysPath_

local profiles_				= {}
local aliases_				= {}
local controller_
local uiLayerComboHashes_
local uiLayerKeyHashes_
local uiProfileName_
local disabledDevices_ 		= {}
local disabledFilename_ 	= 'disabled.lua'
local printLogEnabled_		= true
local printFileLogEnabled_	= false

local turnLocalizationHintsOn_				= false
local insideLocalizationHintsFuncCounter_	= 0
local insideExternalProfileFuncCounter_		= 0

local function printLog(...)
	if printLogEnabled_ then
		print('Input:', ...)
	end	
end

local function printFileLog(...)
	if printFileLogEnabled_ then
		print('Input:', ...)
	end	
end

-- итератор по всем комбинациям устройства для команды
-- использование:
-- for combo in commandCombos(command, deviceName) do
-- end
local function commandCombos(command, deviceName)
	local pos = 0
	local combos
	local deviceCombos
	
	if command then
		combos = command.combos
		
		if combos then
			deviceCombos = combos[deviceName]
		end
	end
		
	return function()
		if deviceCombos then
			
			pos = pos + 1
			return deviceCombos[pos]
		end
	end
end

local function getUiProfileName()
	if not uiProfileName_ then
		local ProfileDatabase = require('Input.ProfileDatabase')
		
		uiProfileName_ = ProfileDatabase.getUiProfileName()
	end
	
	return uiProfileName_
end

local function setProfileModified_(profile, modified)
	profile.modified = modified
	
	local uiProfileName = getUiProfileName()
	
	if profile.name == uiProfileName and modified then
		-- после изменения слоя UiLayer в командах юнитов могут появиться/исчезнуть конфликты
		-- поэтому загруженные юниты нужно загрузить заново
		local profilesToUnload = {}
		
		for i, p in ipairs(profiles_) do
			if p.name ~= uiProfileName then
				table.insert(profilesToUnload, p.name)
			end
		end
		
		uiLayerComboHashes_	= nil
		uiLayerKeyHashes_	= nil
		
		for i, name in ipairs(profilesToUnload) do
			unloadProfile(name)
		end
	end
end

local function findProfile_(profileName)
	for i, profile in ipairs(profiles_) do
		if profile.name == profileName then
			return profile
		end
	end
end

local function getLoadedProfile_(profileName)	
	local profile = findProfile_(profileName)
	if profile and not profile.loaded then
		loadProfile(profile)
	end
	return profile
end

local function validateDeviceProfileCommand_(profileName, command, deviceName)
	local combos = command.combos
	
	if combos then
		local count = #combos
		
		for i = count, 1, -1 do
			local key = combos[i].key
			
			if key then
				if not InputUtils.getKeyBelongToDevice(key, deviceName) then
					printLog('Profile [' .. profileName .. '] command [' .. command.name .. '] contains combo key [' .. key .. '] not belong to device [' .. deviceName .. ']!')
					table.remove(combos, i)
				end
			end
		end
		
		if #combos == 0 then
			command.combos = nil
		end
	end
end

local function validateDeviceProfileCommands_(profileName, commands, deviceName)	
	if commands then
		for i, command in ipairs(commands) do
			validateDeviceProfileCommand_(profileName, command, deviceName)
		end
	end
end

local function validateDeviceProfile_(profileName, deviceProfile, deviceName)	
	validateDeviceProfileCommands_(profileName, deviceProfile.keyCommands,  deviceName)
	validateDeviceProfileCommands_(profileName, deviceProfile.axisCommands, deviceName)
end

local function getCommandBelongsToCategory(category, command)
	local result = true
	if category then
		result = command.category == category
		if not result then
			if 'table' == type(command.category) then
				for i, categoryName in ipairs(command.category) do
					if categoryName == category then
						result = true
						break
					end
				end
			end
		end
	end
	return result
end

local function getProfileKeyCommandsCopy(profileName, category)
	local result = {}
	local profile = getLoadedProfile_(profileName)
		
	if profile then
		for commandHash, command in pairs(profile.keyCommands) do		
			if getCommandBelongsToCategory(category, command) then
				table.insert(result, U.copyTable(nil, command))
			end	
		end
	end
	
	return result
end

local function getProfileAxisCommandsCopy(profileName)
	local result = {}
	local profile = getLoadedProfile_(profileName)
	
	if profile then
		for commandHash, command in pairs(profile.axisCommands) do
			table.insert(result, U.copyTable(nil, command))
		end
	end
	
	return result
end

local function loadDeviceProfileFromFile(filename, deviceName, folder,keep_G_untouched)
	--[[
		Insert this code into "DCSWorld\Scripts\Input\Data.lua" inside the function declaration for "loadDeviceProfileFromFile"
			search for the line 'local function loadDeviceProfileFromFile(filename, deviceName, folder,keep_G_untouched)' and paste this function below it
		Then add the line:
			QuagglesInputCommandInjector(deviceGenericName, filename, folder, env, result)
		into the "loadDeviceProfileFromFile" function below the line:
			status, result = pcall(f)
	]]--
	local function QuagglesInputCommandInjector(deviceGenericName, filename, folder, env, result)
		local quagglesLogName = 'Quaggles.InputCommandInjector'
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
					log.write(quagglesLogName, log.ERROR, '------Failure loading: "'..tostring(newFileName)..'"'..' Error: "'..tostring(err)..'"')
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
					end
				end
			end
		end
	end
	
	local f, err = loadfile(filename)
	local result
	local deviceGenericName
	if deviceName ~= nil then
		deviceGenericName = InputUtils.getDeviceTemplateName(deviceName)
	end

	if not f then
		-- если пытаются загрузить раскладку для мыши из папки юнита
		if	deviceGenericName == 'Mouse' and
			lfs.realpath(folder) ~= lfs.realpath('Config/Input/Aircrafts/Default/mouse/') and
			string.find(filename, 'default.lua') then
			
			-- то для мыши дефолтную раскладку объединяем с раскладкой для клавиатуры юнита	
			local mouse				= loadDeviceProfileFromFile('Config/Input/Aircrafts/Default/mouse/default.lua', 'Mouse', 'Config/Input/Aircrafts/Default/mouse/')
			local keyboard			= loadDeviceProfileFromFile(folder .. '../keyboard/default.lua', 'Keyboard', folder)
			
			if keyboard and keyboard.keyCommands then
				for i, command in ipairs(keyboard.keyCommands) do
					command.combos = nil
				end
				
				-- join mouse and keyboard keyCommands
				for i, value in ipairs(keyboard.keyCommands) do
					table.insert(mouse.keyCommands, value)
				end
			end
			
			return mouse
		end
	end
	
	-- deviceGenericName will be used for automatic combo selection 
	if f then
		
		-- cleanup cockpit devices variable [ACS-1111: FC3 kneeboard pages cannot be turned in some cases](https://jira.eagle.ru/browse/ACS-1111)
		local old_dev 			= _G.devices
		if not keep_G_untouched then
			_G.devices 				= nil
		end
	
		printFileLog('File[' .. filename .. '] opened successfully!')
		
		local noLocalize = function(s)
			return s
		end
		
		local setupEnv = function(env)
			env.devices  			= 	nil 
			env.folder			 	=	folder
			env.filename		 	=	filename
			env.deviceName		 	=	deviceName		
			env.external_profile 	=	function (filename, folder_new)
				insideExternalProfileFuncCounter_ = insideExternalProfileFuncCounter_ + 1

				local old_filename	= env.filename
				local old_folder	= env.folder 
				local fnew			= folder_new or old_folder
				local res			= loadDeviceProfileFromFile(filename,deviceName,fnew,true)
				
				env.filename		= old_filename
				env.folder			= old_folder
				
				insideExternalProfileFuncCounter_ = insideExternalProfileFuncCounter_ - 1
				
				return res
			end
											
			env.defaultDeviceAssignmentFor = function (assignment_name)

				if not wizard_assigments and userConfigPath_ ~= nil then
					local f, err = loadfile(userConfigPath_ .. 'wizard.lua')
					
					if f then
						wizard_assigments = f()
					else
						wizard_assigments = {}
					end
				end
				
				local assignments	= nil
				
				if deviceName ~= nil then
					local wizard_result = wizard_assigments[deviceName]
					if wizard_result then
						local assignment = wizard_result[assignment_name]
						if assignment and  assignment.key ~= nil then
							assignment.filter = createAxisFilter(assignment.filter)
							assignment.fromWizard = true
							return {assignment}
						end
					end
					assignments = default_assignments[deviceGenericName]
				end
				
				if assignments == nil then
				   assignments = default_assignments.default
				end
				
				local assigned = assignments[assignment_name]
				
				if assigned ~= nil then
					if type(assigned) == 'table' then			
						if assigned.key ~= nil then	
							return {assigned}
						end
					else
						return {{key = assigned}}
					end
				end
				
				return nil
			end

			env.join = function(to, from)
				for i, value in ipairs(from) do									
					table.insert(to, value)
				end
				
				return to
			end

			env.ignore_features  = function(commands, features)
				local featuresHashTable = {}
				
				for i, feature in ipairs(features) do
					featuresHashTable[feature] = true
				end
				
				for i = #commands, 1, -1 do
					local command = commands[i]
					
					if command.features then
						for j, commandfeature in ipairs(command.features) do
							if featuresHashTable[commandfeature] then
								table.remove(commands, i)
								
								break
							end
						end
					end
				end
			end
			
			env.bindKeyboardCommandsToMouse = function(unitInputFolder)
				local keyboard			= env.external_profile(unitInputFolder .. "keyboard/default.lua")
				local mouse				= env.external_profile("Config/Input/Aircrafts/Default/mouse/default.lua")

				for i, command in ipairs(keyboard.keyCommands) do
					command.combos = nil
				end

				env.join(mouse.keyCommands, keyboard.keyCommands)
				
				return mouse
			end
			
			setmetatable(env, {__index = _G})
			
			return env
		end
		
		local env = setupEnv(Input.getEnvTable().Actions)
		
		local status
		local nonLocalized
		
		-- для локализации у команд и категорий нужно сохранить английские названия
		if turnLocalizationHintsOn_ then
			local ff, err = loadfile(filename)
			
			if ff then
				local env2 = setupEnv({})
				
				env2._ = noLocalize
				
				setfenv(ff, env2)
				
				insideLocalizationHintsFuncCounter_ = insideLocalizationHintsFuncCounter_ + 1
				
				local status, res = pcall(ff)
				
				if status then
					nonLocalized = {
						keyCommands		= {},
						axisCommands	= {},
					}
					
					for i, keyCommand in ipairs(res.keyCommands or {}) do
						table.insert(nonLocalized.keyCommands,{nameHint = keyCommand.name, categoryHint = keyCommand.category})
					end
					
					for i, axisCommand in ipairs(res.axisCommands or {}) do
						table.insert(nonLocalized.axisCommands,{nameHint = axisCommand.name, categoryHint = axisCommand.category})
					end				
					
				else
					log.error(res);
				end
				
				insideLocalizationHintsFuncCounter_ = insideLocalizationHintsFuncCounter_ - 1
			end
		end
		
		if insideExternalProfileFuncCounter_ > 0 and insideLocalizationHintsFuncCounter_ > 0 then
			env._ = noLocalize
		else
			env._ = InputUtils.localizeInputString
		end
		
		setfenv(f, env)
		
		local status
		
		status, result = pcall(f)
		QuagglesInputCommandInjector(deviceGenericName, filename, folder, env, result)
		
		if status then
			if nonLocalized then
				for i, keyCommand in ipairs(result.keyCommands or {}) do
					keyCommand.nameHint			= nonLocalized.keyCommands[i].nameHint
					keyCommand.categoryHint		= nonLocalized.keyCommands[i].categoryHint
				end
				
				for i, axisCommand in ipairs(result.axisCommands or {}) do
					axisCommand.nameHint		= nonLocalized.axisCommands[i].nameHint
					axisCommand.categoryHint	= nonLocalized.axisCommands[i].categoryHint
				end
			end
		else -- это ошибка в скрипте! ее быть не должно!
			log.error(result);
		end

		if not keep_G_untouched then
			_G.devices = old_dev
		end
	else
		printFileLog(err)
	end
	
	return result, err
end

local function getProfileUserConfigPath_(profile)
	-- unitName может содержать недопустимые в имени файла символы (например / или * (F/A-18A))
	local unitName = string.gsub(profile.unitName, '([%*/%?<>%|%\\%:"])', '')
	
	return string.format('%s%s/', userConfigPath_, unitName)
end

local function loadDeviceProfileDiffFromFile_(filename)
	local func, err = loadfile(filename)
	
	if func then
		local env = {}
		setfenv(func, env)
		local ok, res = pcall(func)
		if ok then
			printFileLog('File[' .. filename .. '] opened successfully!')
			return res
		else
			log.error('Input Error:' ..res)
		end
	else
		printFileLog(err)
	end
end

local function loadTemplateDeviceProfile(planesPath, profileFolder, deviceName)
	local deviceTypeName	= InputUtils.getDeviceTypeName(deviceName)
	local templateName		= InputUtils.getDeviceTemplateName(deviceName)
	local folder			= planesPath .. profileFolder .. '/' .. deviceTypeName .. '/'
	local filename			= templateName .. '.lua'
	
	return loadDeviceProfileFromFile(folder .. filename, deviceName, folder)
end

local function loadDefaultDeviceProfile(planesPath, profileFolder, deviceName)
	local deviceTypeName	= InputUtils.getDeviceTypeName(deviceName)
	local folder			= planesPath .. profileFolder .. '/' .. deviceTypeName .. '/'
	local filename			= 'default.lua'
	
	return loadDeviceProfileFromFile(folder .. filename, deviceName, folder)
end

local function loadPluginDeviceProfile_(profileFolder, deviceName)
	local result
	local err1
	local err2

	result, err1 = loadTemplateDeviceProfile('', profileFolder, deviceName)

	if not result then
		result, err2 = loadDefaultDeviceProfile('', profileFolder, deviceName)
	end

	return result, err1, err2
end

local function collectErrors_(errors, result, ...)
	for i, err in ipairs({...}) do
		table.insert(errors, err)
	end
	
	return result
end

local function loadDeviceTemplateProfileDiff_(profile, deviceName)
	local diff
	local deviceTypeName	= InputUtils.getDeviceTypeName(deviceName)
	local folder			= profile.folder .. '/' .. deviceTypeName .. '/'
	local attributes		= lfs.attributes(folder)

	if attributes and attributes.mode == 'directory' then
		local templateName	= InputUtils.getDeviceTemplateName(deviceName)
		local filename		= templateName .. '.diff.lua'
		
		diff = loadDeviceProfileDiffFromFile_(folder .. filename)
	end

	return diff	
end

--!!!TEMPLATE DIFF IS  NOT PART OF DEFAULT , USER  DIFF  WILL BE COPY  OF TEMPLATE DIFF , SO TEMPLATE DIFF CAN BE USED  ONLY FOR RESET PROCEDURE
local function loadProfileDefaultDeviceProfile_(profile, deviceName , applyTemplateDiff)
	local folder = profile.folder
	local errors = {}
	
	local result = collectErrors_(errors, loadTemplateDeviceProfile('', folder, deviceName))

	if not result then
		result = collectErrors_(errors, loadDefaultDeviceProfile('', folder, deviceName))
	end
	
	if not result and profile.loadDefaultUnitProfile then
		result = collectErrors_(errors, loadTemplateDeviceProfile(sysPath_, 'Default', deviceName))
	end

	if not result and profile.loadDefaultUnitProfile then
		result = collectErrors_(errors, loadDefaultDeviceProfile(sysPath_, 'Default', deviceName))
	end
	
	if result and applyTemplateDiff then
		local templateDiff = loadDeviceTemplateProfileDiff_(profile, deviceName)
		applyDiffToDeviceProfile_(result, templateDiff)
	end
	
	if #errors > 0 then
		printFileLog('Profile [' .. profile.name .. '] errors in load process [' .. deviceName .. '] default profile!', table.concat(errors, '\n'))
	end

	return result
end

local function getComboReformersAreEqual_(reformers1, reformers2)
	if reformers1 then
		if reformers2 then
			local count = #reformers1
			
			if count == #reformers2 then
				for i, reformer1 in ipairs(reformers1) do
					local found = false
					
					for j, reformer2 in ipairs(reformers2) do
						if reformer1 == reformer2 then
							found = true
							break
						end
					end
					
					if not found then
						return false
					end
				end
				
				return true
			else
				return false
			end
		else
			return 0 == #reformers1
		end
	else
		if reformers2 then
			return 0 == #reformers2
		else
			return true
		end
	end
end

local function getCombosKeysAreEqual_(combo1, combo2)
	if combo1.key == combo2.key then		
		return getComboReformersAreEqual_(combo1.reformers, combo2.reformers)
	end
	
	return false
end

local function findCombo_(combos, comboToFind)
	if not  combos then
		return nil
	end
	for i, combo in ipairs(combos) do
		if getCombosKeysAreEqual_(combo, comboToFind) then
			return i
		end
	end
end

local function loadDeviceProfileDiff_(profile, deviceName)
	local diff
	local deviceTypeName 	= InputUtils.getDeviceTypeName(deviceName)
	local folder 			= string.format('%s%s/', getProfileUserConfigPath_(profile), deviceTypeName)
	local attributes 		= lfs.attributes(folder)
	
	if not attributes or attributes.mode ~= 'directory' then
		return nil
	end
	
	local filename = deviceName .. '.diff.lua'
	local diff = loadDeviceProfileDiffFromFile_(folder .. filename)
	if not diff then 
		return
	end
	-- replace Backspace to Back in user .diff file
	-- due to renaming Back to Backspace 05.04.2018 :(
	for commandHash, info in pairs(diff.keyDiffs or {}) do
		for i,  addInfo in ipairs(info.added or {}) do
			if  addInfo.key == 'Backspace' then
				addInfo.key = 'Back'
			end
		end
				
		for i, removeInfo in ipairs(info.removed or {}) do
			if  removeInfo.key == 'Backspace' then
				removeInfo.key = 'Back'
			end
		end
	end
	return diff	
end

local function removeFoundCombos(commandCombos, removed)
	if not removed then
		return
	end
	for i, combo in ipairs(removed) do
		local index = findCombo_(commandCombos, combo)
			
		if index then
			table.remove(commandCombos, index)
		end
	end
end

local function applyAddedCombos_(commandCombos, added)
	if not added then
		return 
	end
	for i, combo in ipairs(added) do
		local index = findCombo_(commandCombos, combo) -- avoid duplicates
		if not index then
			table.insert(commandCombos, combo)
		end
	end
end

local function getDiffComboInfos(diff)
	local diffInfos = {}
		
	for diffCommandHash, commandDiff in pairs(diff) do
		if commandDiff.added then
			for i, combo in ipairs(commandDiff.added) do
				local comboHash = InputUtils.getComboHash(combo.key, combo.reformers)
				
				diffInfos[comboHash] = diffInfos[comboHash] or {}
				diffInfos[comboHash].addedHash = diffCommandHash
			end
		end
		
		if commandDiff.removed then
			for i, combo in ipairs(commandDiff.removed) do
				local comboHash = InputUtils.getComboHash(combo.key, combo.reformers)
				
				diffInfos[comboHash] = diffInfos[comboHash] or {}
				diffInfos[comboHash].removedHash = diffCommandHash
			end
		end	
	end
	
	return diffInfos
end

local function getDefaultCommandUpdated(commandCombos, commandHash, diffInfos)
	for i, combo in ipairs(commandCombos) do
		local diffInfo = diffInfos[InputUtils.getComboHash(combo.key, combo.reformers)]
		
		if diffInfo then
			if 	commandHash ~= diffInfo.addedHash and
				commandHash ~= diffInfo.removedHash then
				
				return true
			end
		end
	end
	
	return false
end

local function applyDiffToCommands_(commands, diff, commandHashFunc)
	if diff and next(diff) and commands then
		local diffInfos = getDiffComboInfos(diff)
		
		for i, command in ipairs(commands) do
			local hash = commandHashFunc(command)
			local commandCombos = command.combos

			if commandCombos then			
				if getDefaultCommandUpdated(commandCombos, hash, diffInfos) then
					command.updated = true
				else
				
					local cleanupDefaultCommandCombos = removeFoundCombos

					-- Удаляем из дефолтной раскладки все комбинации,
					-- упомянутые в пользовательских данных.
					-- Сделано это для того, чтобы при добавлении дефолтного профиля устройства
					-- (например, при автоматическом обновлении программы)
					-- пользовательские настройки не конфликтовали с дефолтными настройками.	
					for diffCommandHash, commandDiff in pairs(diff) do
						cleanupDefaultCommandCombos(commandCombos, commandDiff.added)
						cleanupDefaultCommandCombos(commandCombos, commandDiff.removed)
						cleanupDefaultCommandCombos(commandCombos, commandDiff.changed)
					end
				end
			end
			
			local commandDiff 			= diff[hash]
			local applyRemovedCombos_   = removeFoundCombos

			if commandDiff then				
				if not commandCombos then
					commandCombos = {}
					command.combos = commandCombos
				end
				
				applyRemovedCombos_(commandCombos, commandDiff.removed)
				applyAddedCombos_(commandCombos, commandDiff.added)
				applyAddedCombos_(commandCombos, commandDiff.changed)
			end
		end
	end	
end

local function createForceFeedbackSettings(forceFeedback)
	forceFeedback = forceFeedback or {}
	
	return {
		trimmer		= forceFeedback.trimmer		or 1.0,
		shake		= forceFeedback.shake		or 0.5,
		swapAxes	= forceFeedback.swapAxes	or false,
		invertX		= forceFeedback.invertX		or false,
		invertY		= forceFeedback.invertY		or false,
		ignore		= forceFeedback.ignore		or false,
	}
end

local function applyDiffToForceFeedback_(deviceProfile, diff)
	if diff then
		local forceFeedback = createForceFeedbackSettings(deviceProfile.forceFeedback)
		
		for key, value in pairs(diff) do
			forceFeedback[key] = value
		end
		
		deviceProfile.forceFeedback = forceFeedback
	end
end

local function loadDeviceProfile_(profile, deviceName)
	local errors = {}

	local result = collectErrors_(errors, loadPluginDeviceProfile_(profile.folder, deviceName))

	if not result then
		result = loadProfileDefaultDeviceProfile_(profile, deviceName)
	end
		
	if not result and #errors > 0 then
		printFileLog('Profile [' .. profile.name .. '] cannot load device [' .. deviceName .. '] profile!', table.concat(errors, '\n'))
	end
	
	if not result then
		return nil
	end
	
	-- Remove combos intersections with wizard
	local validateIntersectionWithWizard = function(deviceName, commands)
		if commands == nil or type(commands) ~= 'table' then
			return
		end
		
		local commandHashToCombos = {}
		for i, command in ipairs(commands) do
			if command.combos then
				for j, combo in ipairs(command.combos) do
					local hash = deviceName.."["..InputUtils.createComboString(combo, deviceName).."]"
					commandHashToCombos[hash] = commandHashToCombos[hash] or {}
					table.insert(commandHashToCombos[hash], {combos = command.combos, name = command.name, index = j})
				end
			end
		end
		
		for name, sameAssignments in pairs(commandHashToCombos) do
			if #sameAssignments > 1 then
				local wizardComboIndex
				for j, assignment in ipairs(sameAssignments) do
					if assignment.combos[assignment.index].fromWizard then
						wizardComboIndex = j
						break
					end
				end
				
				if wizardComboIndex then
					for j, assignment in ipairs(sameAssignments) do
					
						if j ~= wizardComboIndex then
							table.remove(assignment.combos, assignment.index)
						end
					end
				end
			end
		end
	end
	
	if type(result) == "table" then
		for name, commands in pairs(result) do
			validateIntersectionWithWizard(deviceName, commands)
		end
	end

	return result
end

local function createProfileTable_(name, folder, unitName, default, visible, loadDefaultUnitProfile)
	return {
		name					= name, 
		folder					= folder,
		unitName				= unitName, 
		default					= default,
		visible					= visible,
		loadDefaultUnitProfile	= loadDefaultUnitProfile,
		deviceProfiles			= nil,
		forceFeedback			= {},
		loaded					= false,
		modified				= false,
		modifiers				= {},
	}
end

local function createProfileCategories(profile)
	local profileCategories = {}
	local categories = {}
	
	local addCategory = function(categoryName)
		if not categories[categoryName] then
			categories[categoryName] = true
			table.insert(profileCategories, categoryName)
		end	
	end

	for commandHash, command in pairs(profile.keyCommands) do
		local category = command.category

		if category then
			if 'table' == type(category) then
				for i, categoryName in ipairs(category) do
					addCategory(categoryName)		
				end
			else
				addCategory(category)
			end
		else
			printLog('Command ' .. command.name .. ' has no category in profile ' .. profile.name)
		end
	end
	
	profile.categories = profileCategories
end

local function getCommandDeviceNamesString(command)
	local result

	for deviceName, i in pairs(command.combos) do
		if result then
			result = result .. ', ' .. deviceName
		else
			result = deviceName
		end
	end

	return result
end

local function sortDeviceCombosReformers_(deviceCombos)
	for i, combo in ipairs(deviceCombos) do
		local reformers = combo.reformers
		
		if reformers then
			table.sort(reformers, textutil.Utf8Compare)
		end
	end
end

local function copyDeviceCommandToProfileCommand(deviceName, deviceCommand, profileCommand)
	for k, v in pairs(deviceCommand) do
		if 'combos' ~= k then
			profileCommand[k] = v
		end
	end
	
	local deviceCombos = U.copyTable(nil, deviceCommand.combos or {})

	sortDeviceCombosReformers_(deviceCombos)
	
	profileCommand.combos[deviceName] = deviceCombos
end

local function getReformerValid_(profileName, command, deviceName, reformer, modifiers, warnings)
	local result = true
	local modifier = modifiers[reformer]

	if modifier then
		result = (nil ~= modifier.event)

		if not result then
			printLog('Profile [' .. profileName.. '] command [' .. command.name .. '] contains unknown reformer key [' .. modifier.key .. '] in device [' .. deviceName .. '] profile!')
			table.insert(warnings, string.format(_('Unknown reformer %s'), modifier.key))
		end
	else
		printLog('Profile [' .. profileName.. '] command [' .. command.name .. '] contains unknown reformer[' .. reformer .. '] in device [' .. deviceName .. '] profile!')
		table.insert(warnings, string.format(_('Unknown reformer %s'), reformer))
		
		result = false
	end

	return result
end

local function createKeyHash_(deviceName, key)
	return string.format('%s[%s]', deviceName, key)
end

local function createModifierHash_(name, modifiers)
	local modifier = modifiers[name]
	
	if modifier then
		return createKeyHash_(modifier.deviceName, modifier.key)
	end	
end

local function createComboHash_(deviceName, combo, modifiers)
	local hash = createKeyHash_(deviceName, combo.key)
	
	if combo.reformers then
		local modifierHashes = {}
		
		for i, name in pairs(combo.reformers) do
			local modifierHash = createModifierHash_(name, modifiers)
			
			if modifierHash then
				table.insert(modifierHashes, modifierHash)
			end	
		end
		
		if #modifierHashes > 0 then
			table.sort(modifierHashes)
			
			hash = string.format('%s(%s)', hash, table.concat(modifierHashes, ';'))
		end
	end
	
	return hash
end

local function createUiLayerComboInfos_()
	local profile		= getLoadedProfile_(getUiProfileName())
	
	-- если симулятор запускается с миссией в командной строке, то слой для UI не заёгружается
	if profile then
		local commands		= profile.keyCommands
		local modifiers		= profile.modifiers
		
		uiLayerComboHashes_ = {}
		uiLayerKeyHashes_	= {}
		
		for commandHash, command in pairs(commands) do
			for deviceName, combos in pairs(command.combos) do
			
				for i, combo in ipairs(combos) do
					uiLayerComboHashes_	[createComboHash_(deviceName, combo, modifiers)	] = true
					uiLayerKeyHashes_	[createKeyHash_(deviceName, combo.key)			] = true
				end
			end
		end
	end
end

local function getComboValidUiLayer_(profileName, command, deviceName, combo, modifiers, warnings)
	local result = true
	
	if not uiLayerComboHashes_ then
		createUiLayerComboInfos_()
	end
	
	if uiLayerComboHashes_ then
		-- combo не должны совпадать с комбо для слоя UI
		if uiLayerComboHashes_[createComboHash_(deviceName, combo, modifiers)] then
			printLog('Profile [' .. profileName .. '] command [' .. command.name .. '] contains combo [' .. InputUtils.createComboString(combo, deviceName) .. '] equal to combo in [' .. getUiProfileName() .. ']')
			table.insert(warnings, string.format(_('Is equal to combo in %s'), getUiProfileName()))
			
			result = false			
		end
		
		if combo.reformers then
			-- модификаторы combo не должны содержать кнопки из комбо для слоя UI
			for i, name in pairs(combo.reformers) do
				local modifierHash = createModifierHash_(name, modifiers)
				
				if uiLayerKeyHashes_[modifierHash] then
					result = false

					printLog('Profile [' .. profileName .. '] command [' .. command.name .. '] combo [' .. InputUtils.createComboString(combo, deviceName) .. ' reformers contain key [' .. modifierHash .. '] presented as key in [' .. getUiProfileName() .. '] combos')
					
					table.insert(warnings, string.format(_('Reformers has key %s presented as key in %s'), modifierHash, getUiProfileName()))
				end
			end
		end	
	end
	
	return result
end

local function getComboValid_(profileName, command, deviceName, combo, modifiers, warnings)
	local result = true
	local key = combo.key
	
	if key then
		result = InputUtils.getKeyNameValid(key)

		if result then
			local modifier = modifiers[key]

			if modifier and modifier.deviceName == deviceName then
				printLog('Profile [' .. profileName.. '] command [' .. command.name .. '] contains combo key [' .. key .. '] registered as modifier in device [' .. deviceName .. '] profile!')
				table.insert(warnings, string.format(_('Key %s is registered as modifier in device %s'), key, deviceName))
				
				result = false
			end
		else
			printLog('Profile [' .. profileName.. '] command [' .. command.name .. '] contains unknown combo key [' .. key .. '] in device [' .. deviceName .. '] profile!')
			table.insert(warnings, string.format(_('Unknown кey %s'), key))
		end
	end

	if result then
		if combo.reformers then
			for i, reformer in ipairs(combo.reformers) do
				result = result and getReformerValid_(profileName, command, deviceName, reformer, modifiers, warnings)

				if not result then
					break
				end
			end
		end
	end

	return result
end

local function makeComboWarningString_(warnings)
	local result
	
	if #warnings > 0 then
		-- убираем повторяющиеся сообщения
		local t = {}
		local strings = {}
		
		for i, warning in ipairs(warnings) do
			if not t[warning] then
				table.insert(strings, warning)
				t[warning] = true
			end
		end
		
		result = table.concat(strings, '\n')
	end
	
	return result
end

local function validateProfileCommandCombos(profileName, command)
	local result  = not command.updated
	if result then
		local profile   = findProfile_(profileName)
	
		local modifiers = profile.modifiers
		
		for deviceName, combos in pairs(command.combos) do
			for i, combo in ipairs(combos) do
				local warnings	= {}
				
				combo.valid = getComboValid_(profileName, command, deviceName, combo, modifiers, warnings)

				-- проверим, что кнопки комбо не пересекаются с кнопками из UI Layer
				if profileName ~= getUiProfileName() then
					local uiValid = getComboValidUiLayer_(profileName, command, deviceName, combo, modifiers, warnings)
					
					combo.valid = combo.valid and uiValid
				end

				combo.warnings = makeComboWarningString_(warnings)
				result = result and combo.valid
			end
		end
	end

	return result
end

local function findCommandByHash_(commands, commandHash)
	if commands then
		return commands[commandHash]
	end
end

local function findKeyCommand_(profileName, commandHash)
	local profile = getLoadedProfile_(profileName)
	
	return findCommandByHash_(profile.keyCommands, commandHash)
end

local function findDefaultKeyCommand_(profileName, commandHash)
	local profile = getLoadedProfile_(profileName)
	
	return findCommandByHash_(profile.defaultKeyCommands, commandHash)
end

local function findAxisCommand_(profileName, commandHash)
	local profile = getLoadedProfile_(profileName)
	
	return findCommandByHash_(profile.axisCommands, commandHash)
end

local function findDefaultAxisCommand_(profileName, commandHash)
	local profile = getLoadedProfile_(profileName)
	
	return findCommandByHash_(profile.defaultAxisCommands, commandHash)
end

local function getCommandModifiedCombos_(command, deviceName)
	local modifiedCombos = command.modifiedCombos
	
	if modifiedCombos then
		return modifiedCombos[deviceName]
	end
	
	return false
end

local function addComboToCommand_(profileName, deviceName, command, combo)
	if command then
		local deviceCombos = command.combos[deviceName]
				
		if not findCombo_(deviceCombos, combo) then
			if not deviceCombos then
				deviceCombos = {}
				command.combos[deviceName] = deviceCombos
			end
			
			table.insert(deviceCombos, U.copyTable(nil, combo))
			command.valid = validateProfileCommandCombos(profileName, command)
		end
	end
end

local function removeComboFromCommand_(profileName, deviceName, command, combo)
	if command then
		local deviceCombos = command.combos[deviceName]
		local comboIndex = findCombo_(deviceCombos, combo)
		if comboIndex then
			table.remove(deviceCombos, comboIndex)
			
			command.valid = validateProfileCommandCombos(profileName, command)
		end
	end
end

local function removeCombosFromCommand_(profileName, command, deviceName)
	if command then
		local deviceCombos = command.combos[deviceName]
		
		if deviceCombos then
			while #deviceCombos > 0 do
				table.remove(deviceCombos)
			end
		end
	
		command.valid = validateProfileCommandCombos(profileName, command)
	end
end

local function removeComboFromCommands_(profileName, deviceName, commands, combo)
	for commandHash, command in pairs(commands) do
		removeComboFromCommand_(profileName, deviceName, command, combo)
	end
end

local function setDefaultCommandCombos_(profileName, deviceName, defaultCommand, command, commands)
	removeCombosFromCommand_(profileName, command, deviceName)

	for combo in commandCombos(defaultCommand, deviceName) do
		removeComboFromCommands_(profileName, deviceName, commands, combo)
		addComboToCommand_(profileName, deviceName, command, combo)
	end
end

local function setDefaultCommandsCategoryCombos_(profileName, commands, deviceName, category)
	for commandHash, command in pairs(commands) do
		if getCommandBelongsToCategory(category, command) then
			local defaultKeyCommand = findDefaultKeyCommand_(profileName, commandHash)
	
			if defaultKeyCommand then
				setDefaultCommandCombos_(profileName,deviceName, defaultKeyCommand, command, commands) 
			end
		end
	end
end

local function addProfileKeyCommand(profileName, deviceName, keyCommand, commandsHashTable, combosHashTable)
	local commandHash = InputUtils.getKeyCommandHash(keyCommand)
	local command = commandsHashTable[commandHash]
	
	if command then
		if command.name ~= keyCommand.name then
			printLog('Profile[' .. profileName .. '] key command[' .. 
								keyCommand.name .. '] for device[' .. 
								deviceName.. '] has different name from command[' .. 
								command.name .. '] for device[' .. 
								getCommandDeviceNamesString(command) .. ']')
		end

		command.combos[deviceName] = keyCommand.combos or {}
	else
		command = {combos = {}}

		copyDeviceCommandToProfileCommand(deviceName, keyCommand, command)

		command.name					= keyCommand.name
		command.disabled				= keyCommand.disabled
		command.hash					= commandHash
		commandsHashTable[commandHash]	= command		
	end

	command.valid = validateProfileCommandCombos(profileName, command)
end

local function addProfileKeyCommands(profileName, deviceName, deviceProfile, commandsHashTable)
	-- deviceProfile это таблица, загруженная из файла
	local keyCommands = deviceProfile.keyCommands
	
	if keyCommands then
		local combosHashTable = {}

		for i, keyCommand in ipairs(keyCommands) do
			addProfileKeyCommand(profileName, deviceName, keyCommand, commandsHashTable, combosHashTable)
		end
	end
end

local function addProfileAxisCommand(profileName, deviceName, axisCommand, commandsHashTable, combosHashTable)
	local commandHash = InputUtils.getAxisCommandHash(axisCommand)
	if not commandHash then
		return 
	end
	local command = commandsHashTable[commandHash]

	if command then
		if command.name ~= axisCommand.name then
			printLog('Profile[' .. profileName .. '] axis command[' .. 
								axisCommand.name .. '] for device[' .. 
								deviceName.. '] has different name from command[' .. command.name .. '] for device[' .. 
								getCommandDeviceNamesString(command) .. ']')
		end

		command.combos[deviceName] = axisCommand.combos or {}
	else
		command = {combos = {}}

		copyDeviceCommandToProfileCommand(deviceName, axisCommand, command)

		command.name = axisCommand.name
		command.hash = commandHash
		commandsHashTable[commandHash] = command
	end

	command.valid = validateProfileCommandCombos(profileName, command)
end

local function addProfileAxisCommands(profileName, deviceName, deviceProfile, commandsHashTable)
	if deviceProfile.axisCommands then
		local combosHashTable = {}

		for i, axisCommand in ipairs(deviceProfile.axisCommands) do 
			addProfileAxisCommand(profileName, deviceName, axisCommand, commandsHashTable, combosHashTable)
		end
	end
end

local function addProfileForceFeedbackSettings(profile, deviceName, deviceProfile)
	if deviceProfile.forceFeedback then
		profile.forceFeedback[deviceName] = U.copyTable(nil, deviceProfile.forceFeedback)
	end
end

local function getProfileForceFeedbackSettings(profileName, deviceName)
	local profile = getLoadedProfile_(profileName)
	local ffSettings = profile.forceFeedback[deviceName]
	
	if ffSettings then
		return createForceFeedbackSettings(ffSettings)
	end	
end

local function validateCommands_(profileName, commands)
	if commands then
		for commandHash, command in pairs(commands) do
			command.valid = validateProfileCommandCombos(profileName, command)
		end
	end
end

local function setAxisComboFilters(combos, filters)
	if combos then
		for i, combo in ipairs(combos) do
			local axis = combo.key
			
			if axis then
				local filter = filters[axis]
				
				if filter then
					combo.filter = createAxisFilter(filter)
				end
			end	
		end
	end
end

local function setProfileDeviceProfile_(profile, deviceName, deviceProfile)
	validateDeviceProfile_(profile.name, deviceProfile, deviceName)
	profile.deviceProfiles[deviceName] = deviceProfile
end

local function loadModifiersFromFolder_(folder)
	local result
	local filename	= folder .. '/modifiers.lua'
	local f, err	= loadfile(filename)

	if f then
		printFileLog('File[' .. filename .. '] opened successfully!')
		
		result = f()
	else
		printFileLog(err)
	end

	return result, err
end

-- загружаем измененные пользователем модификаторы
local function loadProfileUserModifiers_(profile, errors)
	errors = errors or {}
	
	local folder = getProfileUserConfigPath_(profile)
	local modifiers = collectErrors_(errors, loadModifiersFromFolder_(folder))
	
	if not modifiers and userConfigPath_ ~= nil then
		-- в предыдущей версии инпута измененные модификаторы 
		-- располагались в пользовательской папке с профилями
		folder = userConfigPath_
		modifiers = collectErrors_(errors, loadModifiersFromFolder_(folder))
	end
	
	return modifiers, folder, errors
end

-- загружаем дефолтные модификаторы
local function loadProfileDefaultModifiers_(profile, errors)	
	errors = errors or {}
	
	local folder 	= profile.folder
	local modifiers = collectErrors_(errors, loadModifiersFromFolder_(folder))
	
	if not modifiers then
		folder = sysPath_
		modifiers = collectErrors_(errors, loadModifiersFromFolder_(folder))
	end
	
	return modifiers, folder, errors	
end

local function loadProfileModifiers_(profile)
	local errors = {}	
	local modifiers, folder = loadProfileUserModifiers_(profile, errors)
	
	if not modifiers then
		modifiers, folder = loadProfileDefaultModifiers_(profile, errors)
	end
	
	if not modifiers and #errors > 0 then
		printLog('Profile [' .. profile.name .. '] cannot load modifiers!', table.concat(errors, '\n'))
	end
	
	return modifiers, folder
end

local function getDevicesHash_(folder)
	local result = {}
	local devices = InputUtils.getDevices()

	for i, deviceName in ipairs(devices) do
		if folder == sysPath_ then
			local deviceTemplateName = InputUtils.getDeviceTemplateName(deviceName)

			result[deviceTemplateName] = deviceName
		else
			result[deviceName] = deviceName
		end
	end

	return result
end

local function createModifier(key, deviceName, switch)
	local event 	= InputUtils.getInputEvent(key)
	local deviceId	= Input.getDeviceId(deviceName)
	return {key = key, event = event, deviceId = deviceId, deviceName = deviceName, switch = switch}
end

local function createProfileModifiers_(profile)
	local profileModifiers = {}
	local modifiers, folder = loadProfileModifiers_(profile)
	
	if modifiers then
		-- у модификаторов, загружаемых из дефолтной папки sysPath_
		-- имена устройств не содержат CLSID 
		local devicesHash = getDevicesHash_(folder)

		for name, modifier in pairs(modifiers) do
			local modifierDeviceName = modifier.device
			local deviceName = devicesHash[modifierDeviceName]
			
			if deviceName then
				local key = modifier.key
				local switch = modifier.switch

				profileModifiers[name] = createModifier(key, deviceName, switch)
			end
		end
	end
	
	profile.modifiers = profileModifiers
end

local function deleteDeviceCombos_(commands, deviceName)
	for commandHash, command in pairs(commands) do
		local combos = command.combos
		
		combos[deviceName] = nil
		
		if not next(combos) then
			-- комбинаций для других устройств в этой команде нет, ее можно удалить
			commands[commandHash] = nil
		end
	end
end

local function getDeviceProfile(profileName, deviceName)
	local profile = getLoadedProfile_(profileName)
	local deviceProfile = loadDeviceProfile_(profile, deviceName)
	
	return deviceProfile
end

local function getForceFeedbackSettingsDiff_(forceFeedbackSettings, defaultForceFeedbackSettings)
	local diff = {}
	
	for key, value in pairs(forceFeedbackSettings) do
		if value ~= defaultForceFeedbackSettings[key] then
			diff[key] = value
		end
	end	
	
	if next(diff) then
		return diff
	end	
end

local function getForceFeedbackDiff_(profile, deviceName)
	local forceFeedback = profile.forceFeedback[deviceName]
	if not forceFeedback then 
		return 
	end
	local forceFeedbackSettings 		= createForceFeedbackSettings(forceFeedback)
	local defaultDeviceProfile 			= loadProfileDefaultDeviceProfile_(profile, deviceName)
	local defaultForceFeedbackSettings 	= createForceFeedbackSettings(defaultDeviceProfile.forceFeedback)
		
	return getForceFeedbackSettingsDiff_(forceFeedbackSettings, defaultForceFeedbackSettings)	
end

local function compareFilters_(filter1, filter2)
	if	filter1.deadzone			== filter2.deadzone				and
		filter1.saturationX			== filter2.saturationX			and
		filter1.saturationY			== filter2.saturationY			and
		filter1.hardwareDetent		== filter2.hardwareDetent		and
		filter1.slider				== filter2.slider				and
		filter1.invert				== filter2.invert				and
		#filter1.curvature			== #filter2.curvature then
		
		for i, value in ipairs(filter1.curvature) do
			if value ~= filter2.curvature[i] then
				return false
			end
		end
		
		if filter1.hardwareDetent and filter2.hardwareDetent then
			if filter1.hardwareDetentMax ~= filter1.hardwareDetentMax then
				return false
			end
			
			if filter1.hardwareDetentAB ~= filter1.hardwareDetentAB then
				return false
			end			
		end
		
		return true
	end	
	
	return false	
end

local function getFiltersAreEqual_(filter1, filter2)
	if filter1 == filter2 then
		return true
	end
	
	return compareFilters_(createAxisFilter(filter1), createAxisFilter(filter2))
end

local function cleanupCombo_(combo, checkDefaultFilter)
	local reformers = combo.reformers
	
	if reformers then
		if not next(reformers) then
			reformers = nil
		end
	end
	
	local filter = combo.filter
	
	if checkDefaultFilter then
		if filter then
			if getFiltersAreEqual_(createAxisFilter(filter), createAxisFilter()) then
				filter = nil
			end
		end
	end
	
	return {
		key 		= combo.key,
		reformers 	= reformers,
		filter		= filter,
		column 		= combo.column,
	}
end

local function getCommandAddedCombos_(command, defaultCommand, deviceName)
	local combos = command.combos[deviceName]
	if not combos then 
		return
	end
	local defaultCombos = defaultCommand.combos[deviceName]
	local result	
	for i, combo in ipairs(combos) do
		if not findCombo_(defaultCombos, combo) then
			result = result or {}
			table.insert(result, cleanupCombo_(combo, true))
		end
	end
	return result
end

local function getCommandRemovedCombos_(command, defaultCommand, deviceName)
	local  defaultCombos = defaultCommand.combos[deviceName]
	if not defaultCombos then
		return nil
	end
	local combos 		= command.combos[deviceName]
	local result
	for i, combo in ipairs(defaultCombos) do
		if not findCombo_(combos, combo) then
			result = result or {}
			table.insert(result, cleanupCombo_(combo))
		end
	end
	return result
end

local function getCommandChangedFilterCombos_(command, defaultCommand, deviceName)
	local result
	local combos = command.combos[deviceName]
	local defaultCombos = defaultCommand.combos[deviceName]	
	
	if combos then
		for i, combo in ipairs(combos) do
			local index = findCombo_(defaultCombos, combo)
			
			if index then
				local defaultCombo = defaultCombos[index]
				
				if not getFiltersAreEqual_(combo.filter, defaultCombo.filter) then
					result = result or {}
					table.insert(result, cleanupCombo_(combo))
				end
			end
		end
	end
	return result	
end

local function getCommandDiffCommon_(command, defaultCommand, deviceName)
	local addedCombos 			= getCommandAddedCombos_  (command, defaultCommand, deviceName)
	local removedCombos 		= getCommandRemovedCombos_(command, defaultCommand, deviceName)
		
	if addedCombos or removedCombos then
		return {
			name    = command.name, 
			added   = addedCombos, 
			removed = removedCombos, 
		}
	end
	return nil
end

local function storeDeviceProfileDiffIntoFile_(filename, diff)
	local file, err = io.open(filename, 'w')
	if not file then
		log.error(string.format('Cannot save profile into file[%s]! Error %s', filename, err))
		return
	end
	
	local s = Serializer.new(file)
	s:serialize_sorted('local diff', diff)
	file:write('return diff')
	file:close()
end

local function saveDeviceProfile(profileName, deviceName, filename)
	local profile 		= getLoadedProfile_(profileName)
	local calcDiff		= function(commands,base,calculator)
		local diffs = {}
		for commandHash, command in pairs(commands) do
			local base_command = base[commandHash]
			if base_command then
				local commandDiff = calculator(command, base_command, deviceName)
				if commandDiff then
					diffs[commandHash] = commandDiff
				end
			else
				-- возможно команда сохранена в пользовательских настройках,
				-- но после обновления она исчезла из дефолтных настроек	
				print("Cannot find base command for hash", commandHash, command.name, profile.name, deviceName)
			end
		end
	
		if next(diffs) then
			return diffs
		end
	end
	
	local getCommandDiffAxis = function (command, defaultCommand, deviceName)
		local res 					= getCommandDiffCommon_			(command, defaultCommand, deviceName)
		local changedFilterCombos 	= getCommandChangedFilterCombos_(command, defaultCommand, deviceName)
		if changedFilterCombos then
			if not res then 
				res = {
					name    = command.name, 
				}
			end
			res.changed = changedFilterCombos
		end
		return res
	end
	
	local diff = {
		ffDiffs 	= getForceFeedbackDiff_(profile, deviceName),
		keyDiffs 	= calcDiff(profile.keyCommands ,profile.baseKeyCommands ,getCommandDiffCommon_),
		axisDiffs	= calcDiff(profile.axisCommands,profile.baseAxisCommands,getCommandDiffAxis),
	}
	
	if next(diff) then
		storeDeviceProfileDiffIntoFile_(filename, diff)
	else
		os.remove(filename)
	end
end

local function compareModifiers_(modifier1, modifier2)
	if modifier1 then
		if modifier2 then			
			return	modifier1.key == modifier2.key and
					modifier1.deviceName == modifier2.deviceName and
					(modifier1.switch or false) == (modifier2.switch or false)
		else
			return false
		end			
	elseif modifier2 then
		return false
	else
		return true
	end
end
	
local function getModifiersAreEqual_(modifiers1, modifiers2)
	if modifiers1 == modifiers2 then
		return true
	end
	
	local comparedNames = {}
	
	for name, modifier in pairs(modifiers1) do
		if compareModifiers_(modifier, modifiers2[name]) then
			comparedNames[name] = true
		else	
			return false
		end
	end
	
	for name, modifier in pairs(modifiers2) do
		if not comparedNames[name] then
			if not compareModifiers_(modifier, modifiers1[name]) then
				return false
			end		
		end
	end	
	
	return true
end

local function cleanupModifiers_(modifiers)
	local result = {}
	local cleanupModifier = function(modifier)
		return {
			key = modifier.key,
			device = modifier.deviceName,
			switch = modifier.switch or false,
		}
	end
	
	for name, modifier in pairs(modifiers) do
		result[name] = cleanupModifier(modifier)
	end
	
	return result
end

local function getProfileDefaultModifiers_(profile)
	local defaultModifiers = {}
	
	for name, modifier in pairs(loadProfileDefaultModifiers_(profile) or {}) do
		defaultModifiers[name] = createModifier(modifier.key, modifier.device, modifier.switch)
	end	
	
	return defaultModifiers
end

local function saveProfileModifiers_(profileName, folder)
	local filename = folder .. 'modifiers.lua'
	local profile 			= findProfile_(profileName)
	local modifiers 		= profile.modifiers
	local defaultModifiers 	= getProfileDefaultModifiers_(profile)
	
	if getModifiersAreEqual_(modifiers, defaultModifiers) then
		os.remove(filename)
	else
		local file, err = io.open(filename, 'w')
		
		if file then
			local s = Serializer.new(file)
			s:serialize_sorted('local modifiers', cleanupModifiers_(modifiers))
			file:write('return modifiers')
			file:close()
		else
			log.error(string.format('Cannot save modifiers into file[%s]! Error %s', filename, err))
		end
	end
end

local function saveDisabledDevices()	
	if userConfigPath_ == nil then
		return
	end
	local filename = userConfigPath_ .. disabledFilename_
	local file, err = io.open(filename, 'w')
		
	if file then
		local s = Serializer.new(file)
		local disabled = {
			devices = disabledDevices_,
			pnp = Input.getPnPDisabled(),
		}
		s:serialize_sorted('local disabled', disabled)
		file:write('return disabled')
		file:close()
	else
		log.error(string.format('Cannot save disabled devices into file[%s]! Error %s', filename, err))
	end
end

local function getCommandsInfo(profileCommands, commandActionHashInfos, deviceName)
	local result = {}
	
	for i, profileCommand in ipairs(profileCommands) do
		local commandInfo = {}
		
		commandInfo.category	= profileCommand.category
		commandInfo.name		= profileCommand.name
		commandInfo.features		= profileCommand.features
		commandInfo.actions = {}
		
		for i, actionHashInfo in ipairs(commandActionHashInfos) do
			local action = profileCommand[actionHashInfo.name]
			
			if action then
				local inputName
				
				if actionHashInfo.namedAction then
					inputName = InputUtils.getInputActionName(action) -- некоторые команды могут не иметь имени
				end
				
				if not inputName then
					inputName = tostring(action)
				end
				
				table.insert(commandInfo.actions, {name = actionHashInfo.name, inputName = inputName})
			end
		end

		local combos = profileCommand.combos[deviceName]
		
		if combos and next(combos) then
			commandInfo.combos = {}
			
			for i, combo in ipairs(combos) do
				table.insert(commandInfo.combos, {key = combo.key, reformers = combo.reformers, filter = combo.filter})
			end				
		end
		
		table.insert(result, commandInfo)
	end
	
	return result
end

local function formatFilter(filter)
		return string.format('curvature = {%s}, deadzone = %g, invert = %s, saturationX = %g, saturationY = %g, slider = %s', 
								table.concat(filter.curvature, ', '), 
								filter.deadzone,
								tostring(filter.invert),
								filter.saturationX,
								filter.saturationY,
								tostring(filter.slider))
end

local function formatCombo(combo)
	local result = string.format('{key = %q', combo.key) -- здесь могут быть кавычки, слеши и прочее
	
	if combo.reformers and #combo.reformers > 0 then
		result = string.format('%s, reformers = {"%s"}', result, table.concat(combo.reformers, '", "'))
	end
	
	if combo.filter then
		result = string.format('%s, filter = {%s},', result, formatFilter(combo.filter))
	end
	
	result = result .. '}, '
	
	return result
end

local function formatCommand(commandInfo)
	local result = '{'
	
	if commandInfo.combos then
		result = result .. 'combos = {'
		
		for i, combo in ipairs(commandInfo.combos) do
			result = result .. formatCombo(combo)
		end
		
		result = result .. '}, '
	end
	
	for i, action in ipairs(commandInfo.actions) do
		result = string.format('%s%s = %s, ', result, action.name, action.inputName)
	end

	result = string.format('%s name = _(%q), ', result, commandInfo.name)
	
	if commandInfo.category then
		if 'table' == type(commandInfo.category) then
			result = string.format('%s category = { ', result)
			
			for i, categoryName in ipairs(commandInfo.category) do
				result = result .. string.format('_(%q), ', categoryName)
			end
			
			result = result .. '}, '
		else
			result = string.format('%s category = _(%q), ', result, commandInfo.category)
		end
	end
	
	if commandInfo.features then
		result = string.format('%s features = {', result)
			
		for i, feature in ipairs(commandInfo.features) do
			result = result .. string.format('%q, ', feature)
		end
		
		result = result .. '}, '
	end
	
	result = result .. '},\n'
	
	return result
end

local function formatForceFeedback(forceFeedback)	
	return string.format(
[[	invertX		= %s,
	invertY		= %s,
	shake		= %g,
	swapAxes	= %s,
	trimmer		= %g,
	ignore		= %s,]],
	tostring(forceFeedback.invertX),
	tostring(forceFeedback.invertY),
	forceFeedback.shake,
	tostring(forceFeedback.swapAxes),
	forceFeedback.trimmer,
	tostring(forceFeedback.ignore))
end

local function writeForceFeedbackToFile(file, profileName, deviceName)
	local forceFeedback = getProfileForceFeedbackSettings(profileName, deviceName)
	
	if forceFeedback then
		file:write('forceFeedback = {\n')
		file:write(formatForceFeedback(forceFeedback))
		file:write('\n},\n')
	end
end

local function writeKeyCommandsToFile(file, profileName, deviceName)	
	local keyCommands			= getProfileKeyCommandsCopy(profileName)
	local keyActionHashInfos	= InputUtils.getKeyCommandActionHashInfos()
	local commandsInfo			= getCommandsInfo(keyCommands, keyActionHashInfos, deviceName)
	
	file:write('keyCommands = {\n')
	
	for i, commandInfo in ipairs(commandsInfo) do
		file:write(formatCommand(commandInfo))
	end
	
	file:write('},\n')
end

local function writeAxisCommandsToFile(file, profileName, deviceName)
	local axisCommands 			= getProfileAxisCommandsCopy(profileName)
	local axisActionHashInfos	= InputUtils.getAxisCommandActionHashInfos()
	local commandsInfo			= getCommandsInfo(axisCommands, axisActionHashInfos, deviceName)
	
	file:write('axisCommands = {\n')
	
	for i, commandInfo in ipairs(commandsInfo) do
		file:write(formatCommand(commandInfo))
	end
	
	file:write('},\n')	
end

applyDiffToDeviceProfile_	= function(profile, diff)
	if not diff then
		return 
	end
	applyDiffToCommands_		(profile.keyCommands , diff.keyDiffs , InputUtils.getKeyCommandHash)
	applyDiffToCommands_		(profile.axisCommands, diff.axisDiffs, InputUtils.getAxisCommandHash)
	applyDiffToForceFeedback_	(profile, diff.ffDiffs)
end

loadProfile					= function(profile)
	local profileName 	 = profile.name
	local devices 		 = InputUtils.getDevices()
		
	if not profile.deviceProfiles then
		profile.deviceProfiles = {}
		for i, deviceName in ipairs(devices) do
			local deviceProfile = loadDeviceProfile_(profile, deviceName)
			if deviceProfile then
				--!!! NOTE  USERS DIFF IS COMPLETELY REPLACE TEMPLATE DIFF !!!
				local diff = loadDeviceProfileDiff_(profile, deviceName) or loadDeviceTemplateProfileDiff_(profile, deviceName)
				applyDiffToDeviceProfile_(deviceProfile, diff)
				setProfileDeviceProfile_(profile, deviceName, deviceProfile)
			end
		end
	end
	
	local keyCommandsHashTable  = {}
	local axisCommandsHashTable = {}
	
	createProfileModifiers_(profile)
	
	for deviceName, deviceProfile in pairs(profile.deviceProfiles) do
		addProfileKeyCommands(profileName, deviceName, deviceProfile, keyCommandsHashTable)
		addProfileAxisCommands(profileName, deviceName, deviceProfile, axisCommandsHashTable)
		addProfileForceFeedbackSettings(profile, deviceName, deviceProfile)
	end
	
	profile.keyCommands  = keyCommandsHashTable
	profile.axisCommands = axisCommandsHashTable
	
	-- сразу сохраняем дефлтные команды, 
	-- поскольку при загрузке новых профилей может поменяться значение в таблице devices["KNEEBOARD"] 
	-- и хэши загруженных команд и дефолтных начнут отличаться 
	-- bug 0044809

	-----------------------------------------------------------------------------------------
	local loadDefaults = function (with_template_diff)
		local defaultDeviceProfiles = {}
		for i, deviceName in ipairs(devices) do
			defaultDeviceProfiles[deviceName] = loadProfileDefaultDeviceProfile_(profile, deviceName,with_template_diff)
		end		

		local defaultKeyCommandsHashTable 	= {}
		local defaultAxisCommandsHashTable  = {}

		for deviceName, deviceProfile in pairs(defaultDeviceProfiles) do
			validateDeviceProfile_(profileName, deviceProfile, deviceName)
			addProfileKeyCommands(profileName,  deviceName, deviceProfile, defaultKeyCommandsHashTable)
			addProfileAxisCommands(profileName, deviceName, deviceProfile, defaultAxisCommandsHashTable)
		end
		
		return defaultKeyCommandsHashTable,defaultAxisCommandsHashTable
	end
	
	local dk,da = loadDefaults(true)

	profile.defaultKeyCommands  = dk
	profile.defaultAxisCommands = da

	--making BASE for  DIFFS caclculation 
	local bk,ba = loadDefaults(false)

	profile.baseKeyCommands  	= bk
	profile.baseAxisCommands 	= ba
	
	-----------------------------------------------------------------------------------------
	createProfileCategories(profile)
	profile.loaded = true
end

unloadProfile				= function(profileName)
	for i, profile in ipairs(profiles_) do
		if profile.name == profileName then
			table.remove(profiles_, i)
			
			local newProfile = createProfileTable_(	profile.name,
													profile.folder,
													profile.unitName,
													profile.default,
													profile.visible,
													profile.loadDefaultUnitProfile)

			table.insert(profiles_, newProfile)
			
			break
		end
	end
end

createAxisFilter			= function(filter)
	filter = filter or {}

	local result = {}

	result.deadzone				= filter.deadzone			or 0
	result.saturationX			= filter.saturationX		or 1
	result.saturationY			= filter.saturationY		or 1
	result.hardwareDetentMax	= filter.hardwareDetentMax	or 0
	result.hardwareDetentAB		= filter.hardwareDetentAB	or 0
	result.hardwareDetent		= not (not filter.hardwareDetent)
	result.slider				= not (not filter.slider		)
	result.invert				= not (not filter.invert		)	
	result.curvature			= U.copyTable(nil, filter.curvature or {0})

	return result
end

------------------------------------------------------------------------------
local fdef, errfdef = loadfile('./Scripts/Input/DefaultAssignments.lua') 
if  fdef then
	setfenv(fdef, {})
	local ok, res = pcall(fdef)
	if ok then
		default_assignments = res
	else
		log.error('Cannot load default assignments '..res)
	end
else
	log.error('Cannot load default assignments '.. errfdef)
end
------------------------------------------------------------------------------

local module_interface = {
	commandCombos						= commandCombos,
	getProfileKeyCommands				= getProfileKeyCommandsCopy,
	getProfileAxisCommands				= getProfileAxisCommandsCopy,
	createForceFeedbackSettings			= createForceFeedbackSettings,
	getProfileForceFeedbackSettings		= getProfileForceFeedbackSettings,
	createAxisFilter					= createAxisFilter,
	setAxisComboFilters					= setAxisComboFilters,
	createModifier						= createModifier,
	getDeviceProfile					= getDeviceProfile,
	saveDeviceProfile					= saveDeviceProfile,
	loadDeviceProfileFromFile			= loadDeviceProfileFromFile,
	getUiProfileName					= getUiProfileName,
	unloadProfile						= unloadProfile,				-- подключено/отключено устройство - сбрасываем загруженный профиль
	--interface functions only
	setController 					= function(controller)
		controller_ = controller
	end,
	initialize 						= function(userConfigPath, sysConfigPath)
		userConfigPath_ = userConfigPath
		sysConfigPath_ 	= sysConfigPath
		sysPath_ 		= sysConfigPath .. 'Aircrafts/'
		
		if userConfigPath_ then
			local f, err = loadfile(userConfigPath_ .. disabledFilename_)
			if f then
				local ok, res = pcall(f)
				if ok then
					disabledDevices_ = res.devices
					for deviceName, disabled in pairs(disabledDevices_) do
						Input.setDeviceDisabled(deviceName, true)
					end
					Input.setPnPDisabled(res.pnp)
				else
					printLog('Unable to load disabled devices!', res)
				end
			end	
		end

		local f, err = loadfile(lfs.writedir() .. 'Config/autoexec.cfg')
		
		if f then
			local env = {}
			
			setmetatable(env, {__index = _G})
			setfenv(f, env)
			
			local ok, res = pcall(f)
			if ok then
				turnLocalizationHintsOn_ = env.input_localization_hints_on
			end
		end
	end,
	enablePrintToLog 				= function(enable)
		printLogEnabled_ = enable
	end,
	getUnitMarker 					= function()
		return 'Unit '
	end,
	getProfileNames 				= function()
		local result = {}
		for i, profile in ipairs(profiles_) do
			if profile.visible then
				table.insert(result, profile.name)
			end
		end
		return result
	end,
	getProfileNameByUnitName 		= function(unitName)
		local unitProfile
		
		for i, profile in ipairs(profiles_) do
			if profile.unitName == unitName then
				unitProfile = profile
				
				break
			end
		end
		
		if not unitProfile then
			unitProfile = aliases_[unitName]
		end
		
		if unitProfile then
			return unitProfile.name
		end
	end,
	getProfileUnitName				= function(profileName)
		local profile = findProfile_(profileName)
		if profile then
			return profile.unitName
		end
	end,
	getProfileModifiers				= function(profileName)
		local modifiers = {}
		local profile = getLoadedProfile_(profileName)
		
		if profile then
			U.copyTable(modifiers, profile.modifiers)
		end	
		
		return modifiers
	end,
	getProfileModified				= function(profileName)
		local  profile = findProfile_(profileName)
		return profile and profile.modified
	end,
	getProfileChanged 				= function(profileName)
		local profile = findProfile_(profileName)
		return profile and profile.loaded and profile.modified
	end,
	getProfileCategoryNames			= function(profileName)
		local result = {}
		local profile = getLoadedProfile_(profileName)
		
		if profile then
			if not profile.loaded then
				loadProfile(profile)
			end

			if profile.categories then
				U.copyTable(result, profile.categories)
			end
		end
		
		return result
	end,
	getProfileKeyCommand			= function(profileName, commandHash)
		local profile = getLoadedProfile_(profileName)
		
		if profile then
			local command = profile.keyCommands[commandHash]
			
			if command then
				return U.copyTable(nil, command)
			end
		end
	end,
	getProfileAxisCommand			= function(profileName, commandHash)
		local profile = getLoadedProfile_(profileName)
		
		if profile then
			local command = profile.axisCommands[commandHash]
			
			if command then
				return U.copyTable(nil, command)
			end
		end
	end,
	createProfile 					= function(profileInfo)
		local profile = findProfile_(profileInfo.name)
		
		if profile then
			-- некоторые профили используются разными юнитами
			-- например Spitfire
			-- InputProfiles = {
				-- ["SpitfireLFMkIX"]			= current_mod_path .. '/Input/SpitfireLFMkIX',
				-- ["SpitfireLFMkIXCW"]			= current_mod_path .. '/Input/SpitfireLFMkIX',
			 -- },
			if profile.unitName ~= profileInfo.unitName then
				aliases_[profileInfo.unitName] = profile
			end
		else
			profile = createProfileTable_(profileInfo.name,
										  profileInfo.folder,
										  profileInfo.unitName,
										  profileInfo.default,
										  profileInfo.visible,
										  profileInfo.loadDefaultUnitProfile)
										  
			table.insert(profiles_, profile)
		end
	end,
	getProfileRawKeyCommands		= function(profileName)
		local result = {}
		local profile = getLoadedProfile_(profileName)
		
		if profile then
			result = U.copyTable(nil, profile.keyCommands)
		end
		
		return result
	end,
	getProfileRawAxisCommands		= function(profileName)
		local result = {}
		local profile = getLoadedProfile_(profileName)
		if profile then
			result = U.copyTable(nil, profile.axisCommands)
		end	
		return result
	end,
	getDefaultKeyCommand 			= function(profileName, commandHash)
		local command = findDefaultKeyCommand_(profileName, commandHash)
		
		if command then
			return U.copyTable(nil, command)
		end	
	end,
	setDefaultKeyCommandCombos		= function(profileName, commandHash, deviceName)
		local defaultKeyCommand = findDefaultKeyCommand_(profileName, commandHash)
		if not defaultKeyCommand then
			return 
		end
		local keyCommand = findKeyCommand_(profileName, commandHash)
		if not keyCommand then
			return 
		end
		local profile = getLoadedProfile_(profileName)
		local keyCommands = profile.keyCommands	
		setDefaultCommandCombos_(profileName, deviceName, defaultKeyCommand, keyCommand, keyCommands)
		setProfileModified_(profile, true)
	end,
	addComboToKeyCommand			= function(profileName, commandHash, deviceName, combo)
		local command = findKeyCommand_(profileName, commandHash)
		
		if command then
			local profile = getLoadedProfile_(profileName)
			local commands = profile.keyCommands
			
			removeComboFromCommands_(profileName, deviceName, commands, combo)
			addComboToCommand_(profileName, deviceName, command, combo)
			setProfileModified_(profile, true)
		end	
	end,
	addComboToAxisCommand 			= function(profileName, commandHash, deviceName, combo)
		local command = findAxisCommand_(profileName, commandHash)
		
		if command then
			local profile = getLoadedProfile_(profileName)
			local commands = profile.axisCommands
			
			removeComboFromCommands_(profileName, deviceName, commands, combo)
			addComboToCommand_(profileName, deviceName, command, combo)
			setProfileModified_(profile, true)
		end
	end,
	removeKeyCommandCombos			= function(profileName, commandHash, deviceName)
		local command = findKeyCommand_(profileName, commandHash)
		
		removeCombosFromCommand_(profileName, command, deviceName)
		setProfileModified_(getLoadedProfile_(profileName), true)
	end,
	removeAxisCommandCombos 		= function(profileName, commandHash, deviceName)
		local command = findAxisCommand_(profileName, commandHash)
		
		removeCombosFromCommand_(profileName, command, deviceName)
		setProfileModified_(getLoadedProfile_(profileName), true)
	end,
	getDefaultAxisCommand 			= function(profileName, commandHash)
		local command = findDefaultAxisCommand_(profileName, commandHash)
		
		if command then
			return U.copyTable(nil, command)
		end
	end,
	setDefaultAxisCommandCombos 	= function(profileName, commandHash, deviceName)
		local defaultAxisCommand = findDefaultAxisCommand_(profileName, commandHash)
		if not defaultAxisCommand then
			return
		end
		local axisCommand = findAxisCommand_(profileName, commandHash)
		if not axisCommand then
			return
		end
		local profile = getLoadedProfile_(profileName)
		local axisCommands = profile.axisCommands	
				
		setDefaultCommandCombos_(profileName, deviceName, defaultAxisCommand, axisCommand, axisCommands)
		setProfileModified_(profile, true)
	end,
	setAxisCommandComboFilter		= function(profileName, commandHash, deviceName, filters)
		local command = findAxisCommand_(profileName, commandHash)
		local combos = command.combos
		
		if combos then
			setAxisComboFilters(combos[deviceName], filters)
			setProfileModified_(getLoadedProfile_(profileName), true)
		end	
	end,
	setProfileForceFeedbackSettings = function(profileName, deviceName, settings)
		local profile = getLoadedProfile_(profileName)
		
		profile.forceFeedback[deviceName] = U.copyTable(nil, settings)
		setProfileModified_(profile, true)
	end,
	setProfileModifiers 	= function(profileName, modifiers)		
		local profile = getLoadedProfile_(profileName)
		profile.modifiers = U.copyTable(nil, modifiers)
		for i, profile in ipairs(profiles_) do
			local profileName = profile.name

			validateCommands_(profileName, profile.keyCommands)
			validateCommands_(profileName, profile.axisCommands)		
		end
		setProfileModified_(profile, true)
	end,
	getDefaultProfileName	= function()
		for i, profile in ipairs(profiles_) do
			if profile.default then
				return profile.name
			end	
		end
	end,
	loadDeviceProfile		= function(profileName, deviceName, filename)
		local deviceProfile = getDeviceProfile(profileName, deviceName)
		if not deviceProfile then 
			return
		end
		local diff = loadDeviceProfileDiffFromFile_(filename)
		if not diff then
			return 
		end
		
		local profile = getLoadedProfile_(profileName)

		applyDiffToDeviceProfile_(deviceProfile, diff)
		setProfileDeviceProfile_(profile, deviceName, deviceProfile)

		deleteDeviceCombos_(profile.keyCommands, deviceName)
		deleteDeviceCombos_(profile.axisCommands, deviceName)
		
		addProfileKeyCommands(profileName, deviceName, deviceProfile, profile.keyCommands)
		addProfileAxisCommands(profileName, deviceName, deviceProfile, profile.axisCommands)
		addProfileForceFeedbackSettings(profile, deviceName, deviceProfile)

		setProfileModified_(profile, true)
	end,
	saveChanges 			= function()
		local devices = InputUtils.getDevices()

		for i, profile in ipairs(profiles_) do
			if profile.loaded and profile.modified then
				local profileName = profile.name
				local profileUserConfigPath = getProfileUserConfigPath_(profile)
				
				lfs.mkdir(profileUserConfigPath)
				
				saveProfileModifiers_(profileName, profileUserConfigPath)
		
				for j, deviceName in ipairs(devices) do
					local deviceTypeName = InputUtils.getDeviceTypeName(deviceName)
					local folder = string.format('%s%s', profileUserConfigPath, deviceTypeName)
					local filename = string.format('%s/%s.diff.lua', folder, deviceName)
					
					lfs.mkdir(folder)
					saveDeviceProfile(profileName, deviceName, filename)
				end
				
				setProfileModified_(profile, false)
			end	
		end
		
		saveDisabledDevices()
		
		if controller_ then
			controller_.inputDataSaved()
		end
	end,
	undoChanges 			= function()
		for i, profile in ipairs(profiles_) do
			if profile.loaded and profile.modified then
				profiles_[i] = createProfileTable_(	profile.name,
													profile.folder,
													profile.unitName,
													profile.default,
													profile.visible,
													profile.loadDefaultUnitProfile)
			end
		end	
		
		if controller_ then
			controller_.inputDataRestored()
		end
	end,
	getProfileFolder 		= function(profileName)
		local profile = findProfile_(profileName)
		if profile then
			return profile.folder
		end
	end,
	unloadProfiles			= function()								 -- подключено/отключено устройство - сбрасываем все загруженные профили
		wizard_assigments = nil
		local newProfiles = {}
		for i, profile in ipairs(profiles_) do
			local newProfile = createProfileTable_(	profile.name,
													profile.folder,
													profile.unitName,
													profile.default,
													profile.visible,
													profile.loadDefaultUnitProfile)
											  
			table.insert(newProfiles, newProfile)
		end
		profiles_ = newProfiles
	end,
	saveFullDeviceProfile	= function(profileName, deviceName, filename)-- используется в Utils/Input/CreateDefaultDeviceLayout.lua
		local file, err = io.open(filename, 'w')
		
		if file then
			file:write('return {\n')
			
			writeForceFeedbackToFile(file, profileName, deviceName)
			writeKeyCommandsToFile	(file, profileName, deviceName)	
			writeAxisCommandsToFile	(file, profileName, deviceName)
		
			file:write('}')
			file:close()
		else
			log.error(string.format('Cannot save profile into file[%s]! Error %s', filename, err))
		end
	end,
	getKeyIsInUseInUiLayer	= function(deviceName, key)					 -- кнопка назначена в слое для UI
		return uiLayerKeyHashes_[createKeyHash_(deviceName, key)]
	end,
	clearProfile			= function(profileName, deviceNames)
		local profile = getLoadedProfile_(profileName)
		if not profile then
			return
		end
		for i, deviceName in ipairs(deviceNames) do
			for commandHash, command in pairs(profile.axisCommands) do
				removeCombosFromCommand_(profileName, command, deviceName)
			end
			
			for commandHash, command in pairs(profile.keyCommands) do
				removeCombosFromCommand_(profileName, command, deviceName)
			end
		end
		setProfileModified_(profile, true)
	end,
	setDeviceDisabled 		= function(deviceName, disabled)
		if disabled then
			disabledDevices_[deviceName] = true
		else
			disabledDevices_[deviceName] = nil
		end
		Input.setDeviceDisabled(deviceName, disabled)
	end,
	getDeviceDisabled 		= function(deviceName)
		return disabledDevices_[deviceName] or false
	end,
	getWizardAssignments 	= function()
		if wizard_assigments then 
			return wizard_assigments 
		end
		--load  from user folder
		local f, err = loadfile(lfs.writedir() .. 'Config/Input/wizard.lua')
		if f then
			wizard_assigments = f()
		end
		return wizard_assigments
	end,
	getDefaultKeyCommands	= function(profileName)
		local profile = getLoadedProfile_(profileName)

		return U.copyTable(nil, profile.defaultKeyCommands)
	end,
	getDefaultAxisCommands	= function(profileName)
		local profile = getLoadedProfile_(profileName)
		return U.copyTable(nil, profile.defaultAxisCommands)
	end,
}
------------------------------------------------------------------------------
return  module_interface