--!native
--[[ 
  Freefall Ability for Avatars
  This is the default airborne locomotion Ability.
  It manages the AirController state and handles mid-air movement.
]]

local AbilityManager = require("../../AbilityManager")
local AvatarBodyParts = require("../../Utility/AvatarBodyParts")

local Not = AbilityManager.Not

local CONSTS = table.freeze({
	-- Flags the Humanoid translation layer to determine if
	-- the Humanoid State should be set to Landed.
	SETTING_PROCESS_LANDED_STATE = "processLandedState",
})

local FreefallAbility: AbilityManager.AbilityDefinition = {
	Name = "Freefall",
	ExclusiveGroup = { name = "Locomotion", priority = 0 },
	Labels = {},
	StepSensors = { "MoveInputSensor", "LookSensor", "GroundSensor" }, -- polled every frame while active

	RequiresToActivate = { Not("detachable"), Not("fallingdown"), Not("GroundSensor") }, -- activates when ground raycast fails and not climbing/tripping
	RequiresToContinue = { Not("GroundSensor") }, -- deactivates the frame we touch ground
	BlocksWhileActive = {},
	CancelsOnActivation = {},

	DefaultConfig = {},

	CONSTS = CONSTS,
}

---------- Lifecycle Methods ----------

function FreefallAbility.OnSetup(baseCtx: AbilityManager.BaseContext, state: AbilityManager.AbilityState)
	local cm = baseCtx.controllerManager
	if cm then
		state.airController = cm:FindFirstChildWhichIsA("AirController")
	end
end

function FreefallAbility.OnActivate(
	baseCtx: AbilityManager.BaseContext,
	_frameCtx: AbilityManager.FrameContext,
	state: AbilityManager.AbilityState
)
	local cm = baseCtx.controllerManager

	if cm and state.airController then
		cm.ActiveController = state.airController
	else
		warn("FreefallAbility: Missing AirController")
	end

	AvatarBodyParts.SetLimbsCollide(baseCtx.abilityOwner, false)
	AvatarBodyParts.SetTorsoCollide(baseCtx.abilityOwner, true)
end

function FreefallAbility.OnStep(
	baseCtx: AbilityManager.BaseContext,
	frameCtx: AbilityManager.FrameContext,
	_state: AbilityManager.AbilityState
)
	local cm = baseCtx.controllerManager
	if not cm then
		return
	end

	-- Pass the 3D input vector to the AirController for air-strafing
	cm.MovingDirection = frameCtx.move3d
end

function FreefallAbility.OnDeactivate(
	baseCtx: AbilityManager.BaseContext,
	_frameCtx: AbilityManager.FrameContext,
	_state: AbilityManager.AbilityState
)
	local manager = baseCtx.abilityManager
	manager:SetSetting(FreefallAbility.Name, CONSTS.SETTING_PROCESS_LANDED_STATE, true)
end

return FreefallAbility
