--!native
--[[
	ClimbSensor
	-----------
	Throttled raycast for ladder/climbable surface detection.
	
	Returns the ClimbSensor instance if a climbable surface is detected, false otherwise.
	Uses phase-offset throttling to distribute raycast cost across multiple characters.
]]

-- Global counter for phase offset (distributes raycast load across NPCs)
local globalInstanceCounter = 0

local function makeClimbSensor(
	controllerManager: ControllerManager,
	runner -- AbilityManager, but avoiding require cycle
)
	local climbSensorInstance = controllerManager.ClimbSensor

	if not climbSensorInstance then
		return function()
			return false
		end
	end

	local THROTTLE_RATE = 3
	local phaseOffset = globalInstanceCounter % THROTTLE_RATE
	globalInstanceCounter += 1

	local lastResult = false
	local frameCount = 0

	return function()
		frameCount += 1

		-- High priority: update every frame if climbing or falling
		local highPriority = runner:IsAbilityActive("Climbing") or runner:IsAbilityActive("Freefall")

		-- Low priority: update only on "our turn" based on phase offset
		local isMyTurn = (frameCount + phaseOffset) % THROTTLE_RATE == 0

		if highPriority or isMyTurn then
			local sensedPart = climbSensorInstance.SensedPart
			lastResult = sensedPart and climbSensorInstance or false
		end

		return lastResult
	end
end

return makeClimbSensor
