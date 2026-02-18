--!native
--[[
  Applies a BALANCED impulse to a character. By "balanced", this means that an
equal and opposite impulse is applied to whatever the character is standing on.
If it is not possible to conserve energy, then no impulse is applied.
]]

-- mustConserve defaults to true, and means that the impulse shall not be
-- applied if there is nothing available to apply an equal-and-opposite
-- impulse to.
local function applyBalancedImpulseToCharacter(
	impulse: Vector3,
	rootPart: BasePart,
	controllerManager: ControllerManager,
	mustConserve: boolean
)
	if nil == mustConserve then
		mustConserve = true
	end
	local floor = controllerManager.GroundSensor and controllerManager.GroundSensor.SensedPart
	local ladder = controllerManager.ClimbSensor and controllerManager.ClimbSensor.SensedPart
	if mustConserve and not floor and not ladder then
		-- For conservation of energy, no impulse should be applied
		return
	end
	rootPart:ApplyImpulse(impulse)

	if floor then
		floor:ApplyImpulseAtPosition(-impulse, controllerManager.GroundSensor.HitFrame.Position)
	elseif ladder then
		ladder:ApplyImpulseAtPosition(-impulse, controllerManager.ClimbSensor.HitFrame.Position)
	end
end

return applyBalancedImpulseToCharacter
