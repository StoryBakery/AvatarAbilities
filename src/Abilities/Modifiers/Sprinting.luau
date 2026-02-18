--!native
--[[ 
  Sprinting Ability for Avatars
  A locomotion modifier that increases move speed while the sprint input is held.
  Cancels other modifiers like Crouching on activation.
]]

local AbilityManager = require("../../AbilityManager")

local All = AbilityManager.All

local MOVE_SPEED_FACTOR = 1.5
local HEIGHT_FACTOR = 1

local SprintAbility: AbilityManager.AbilityDefinition = {
	Name = "Sprinting",
	ExclusiveGroup = { name = "LocomotionModifier", priority = 20 },
	Labels = { "locomotionModifier" },
	StepSensors = {},

	RequiresToActivate = All("SprintInputSensor", "GroundSensor"),
	RequiresToContinue = All("SprintInputSensor", "GroundSensor"), -- need continue to get the press and hold behavior from input
	BlocksWhileActive = { "locomotionModifier" }, -- Sprint does not blend with Crouch
	CancelsOnActivation = { "locomotionModifier" },

	CanSleep = true,

	DefaultConfig = {},
}

---------- Lifecycle Methods ----------

function SprintAbility.OnSetup(baseCtx: AbilityManager.BaseContext, state: AbilityManager.AbilityState)
	local controllerManager = baseCtx.controllerManager

	-- Cache references directly in state (faster than SetSetting)
	if controllerManager then
		state.groundController = controllerManager:FindFirstChildWhichIsA("GroundController")
		state.airController = controllerManager:FindFirstChildWhichIsA("AirController")
		state.hipHeight = state.groundController.GroundOffset
	end
end

function SprintAbility.OnActivate(
	_baseCtx: AbilityManager.BaseContext,
	_frameCtx: AbilityManager.FrameContext,
	state: AbilityManager.AbilityState
)
	local groundController = state.groundController
	local airController = state.airController
	state.hipHeight = groundController.GroundOffset

	-- Initialize speed-change management
	state.appliedSpeedFactor = MOVE_SPEED_FACTOR
	if groundController then
		groundController.GroundOffset = state.hipHeight * HEIGHT_FACTOR
		groundController.MoveSpeedFactor *= state.appliedSpeedFactor
	end
	if airController then
		airController.MoveSpeedFactor *= state.appliedSpeedFactor
	end
end

-- Called every frame while active
function SprintAbility.OnStep(
	_baseCtx: AbilityManager.BaseContext,
	_frameCtx: AbilityManager.FrameContext,
	state: AbilityManager.AbilityState
)
	-- Adjust speed-change management if necessary.
	local newFactor = MOVE_SPEED_FACTOR
	if newFactor ~= state.appliedSpeedFactor then
		local groundController = state.groundController
		local airController = state.airController
		if groundController then
			state.groundController.MoveSpeedFactor *= newFactor / state.appliedSpeedFactor
		end
		if airController then
			state.airController.MoveSpeedFactor *= newFactor / state.appliedSpeedFactor
		end
		state.appliedSpeedFactor = newFactor
	end
end

function SprintAbility.OnDeactivate(
	_baseCtx: AbilityManager.BaseContext,
	_frameCtx: AbilityManager.FrameContext,
	state: AbilityManager.AbilityState
)
	local groundController = state.groundController
	local airController = state.airController

	-- Remove this ability's influence on character speed
	if groundController then
		groundController.MoveSpeedFactor /= state.appliedSpeedFactor
		groundController.GroundOffset = state.hipHeight
	end
	if airController then
		airController.MoveSpeedFactor /= state.appliedSpeedFactor
	end
end

function SprintAbility.OnTeardown(_baseCtx: AbilityManager.BaseContext, _state: AbilityManager.AbilityState) end

return SprintAbility
