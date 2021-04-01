--[[
	Insert this code into "DCSWorld\Scripts\Input\Data.lua" above the function "loadDeviceProfileFromFile"
	Then add the line:
		QuagglesInputCommandInjector(filename, folder, env, result)
	into the "loadDeviceProfileFromFile" function below the line:
		status, result = pcall(f)
]]--
local quagglesLogName = 'Quaggles.InputCommandInjector'
local quagglesLoggingEnabled = false
local function QuagglesInputCommandInjector(filename, folder, env, result)
	-- Returns true if string starts with supplied string
	local function StartsWith(String,Start)
		return string.sub(String,1,string.len(Start))==Start
	end

	if quagglesLoggingEnabled then log.write(quagglesLogName, log.INFO, 'Detected loading of: '..filename) end
	-- Only operate on files that are in this folder
	local targetPrefix = "./Mods/aircraft/"
	if StartsWith(filename, targetPrefix) and StartsWith(folder, targetPrefix) then
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
					if resultInj.keyCommands then env.join(result.keyCommands, resultInj.keyCommands) end
					if resultInj.axisCommands then env.join(result.axisCommands, resultInj.axisCommands) end
					if quagglesLoggingEnabled then log.write(quagglesLogName, log.INFO, '------Merge successful') end
				else
					if quagglesLoggingEnabled then log.write(quagglesLogName, log.INFO, '------Merge failed: '..tostring(statusInj)) end
				end
			end
		end
	end
end