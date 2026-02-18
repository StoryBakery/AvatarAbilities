--!native
--[[
	ClimbIntentSensor
	-----------------
	Validates that the player intends to climb based on:
	1. A ladder surface is detected (ClimbSensor)
	2. Move input is directed toward the ladder
	3. Character is facing the ladder (within 60° cone)
]]

-- Character facing must be within ±60° of ladder normal
local INCIDENCE_HALF_ANGLE_LIMIT = math.cos(math.rad(60))

local function makeClimbIntentSensor(
	rootPart: BasePart,
	runner -- AbilityManager, but avoiding require cycle
)
	return function(frame)
		-- 1. Check if there's a ladder present
		local ladderSensor = runner:GetSensor("ClimbSensor")
		if not ladderSensor or not ladderSensor.SensedPart then
			return false
		end

		local ladderNormal = ladderSensor.HitNormal
		if ladderNormal.Magnitude < 0.99 then
			return false
		end

		if not frame then
			return false
		end

		local move2d = frame.move2d
		local cameraLook = frame.look

		-- 2. Validate move intent direction
		local worldUp = Vector3.yAxis
		local cameraRight = cameraLook:Cross(worldUp)
		if cameraRight.Magnitude == 0 then
			return false
		end
		cameraRight = cameraRight.Unit

		local cameraLookProj = cameraLook - cameraLook:Dot(worldUp) * worldUp
		if cameraLookProj.Magnitude == 0 then
			return false
		end
		cameraLookProj = cameraLookProj.Unit

		local moveIntent3d = move2d.X * cameraRight + move2d.Y * cameraLookProj
		if moveIntent3d:Dot(-ladderNormal) <= 0 then
			return false
		end

		-- 3. Validate avatar facing direction (3D cone check)
		local hrpFacingDir = rootPart.CFrame.LookVector
		local incidenceDP = -ladderNormal:Dot(hrpFacingDir)
		if incidenceDP < INCIDENCE_HALF_ANGLE_LIMIT then
			return false
		end

		return true
	end
end

return makeClimbIntentSensor
