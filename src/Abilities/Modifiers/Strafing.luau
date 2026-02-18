--!native
--[[ 
  Strafing Ability for Avatars
  Used for shift-lock and first-person behavior where the character 
  faces the direction of the camera.
]]

local AbilityManager = require("../../AbilityManager")
local alignToPlane = require("../../Utility/alignToPlane")

local StrafingAbility: AbilityManager.AbilityDefinition = {
	Name = "Strafing",
	ExclusiveGroup = { name = "DirectionModifier", priority = 10 },
	Labels = {},
	StepSensors = { "MoveInputSensor", "LookSensor" },

	RequiresToActivate = { "StrafeInputSensor", "GroundSensor" },
	RequiresToContinue = { "StrafeInputSensor", "GroundSensor" },
	BlocksWhileActive = {},
	CancelsOnActivation = {},

	DefaultConfig = {},
}

---------- Lifecycle Methods ----------

function StrafingAbility.OnStep(
	baseCtx: AbilityManager.BaseContext,
	frameCtx: AbilityManager.FrameContext,
	_state: AbilityManager.AbilityState
)
	local cm = baseCtx.controllerManager

	-- We use the frameCtx look direction (Camera look vector)
	local look: Vector3 = frameCtx.look
	local up = cm and cm.UpDirection

	if not cm or not up then
		return
	end

	local flatDirection = alignToPlane(look, up)

	-- Ignore if we get 0, 0, 0 or nan, nan, nan somehow
	if flatDirection == Vector3.zero or flatDirection ~= flatDirection then
		return
	end

	cm.FacingDirection = flatDirection
end

return StrafingAbility
