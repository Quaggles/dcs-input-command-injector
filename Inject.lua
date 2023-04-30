--[[
	Insert this code into "DCSWorld\Scripts\Input\Data.lua" above the function "loadDeviceProfileFromFile"
	Then add the line:
		QuagglesInputCommandInjector(deviceGenericName, filename, folder, env, result)
	into the "loadDeviceProfileFromFile" function below the line:
		status, result = pcall(f)
]]--
local quagglesLogName = 'Quaggles.InputCommandInjector'
local quagglesLoggingEnabled = false
local function QuagglesInputCommandInjector(deviceGenericName, filename, folder, env, result)
	-- Returns true if string starts with supplied string
	local function StartsWith(String,Start)
		return string.sub(String,1,string.len(Start))==Start
	end

	if quagglesLoggingEnabled then log.write(quagglesLogName, log.INFO, 'Detected loading of: '..filename) end
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
		if quagglesLoggingEnabled then log.write(quagglesLogName, log.INFO, '--Translated path: '..newFileName) end

		-- If the user has put a file there continue
		if lfs.attributes(newFileName) then
			if quagglesLoggingEnabled then log.write(quagglesLogName, log.INFO, '----Found merge at: '..newFileName) end
			--Configure file to run in same environment as the default command entry file
			local f, err = loadfile(newFileName)
			if err ~= nil then
				log.write(quagglesLogName, log.ERROR, '------Failure loading: '..tostring(newFileName).." Error: "..tostring(err))
				return
			else
				setfenv(f, env)
				local statusInj, resultInj
				statusInj, resultInj = pcall(f)

				-- Merge resulting tables
				if statusInj then
					if result.axisCommands and resultInj.keyCommands then -- If both exist then join
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
					if quagglesLoggingEnabled then log.write(quagglesLogName, log.INFO, '------Merge failed: '..tostring(statusInj)) end
				end
			end
		end
	end
end
