--!native
--[[ 
  Crouching Ability for Avatars
  A locomotion modifier that decreases move speed 
  and lowers collision when the crouch input is toggled.
  Cancels other modifiers like Sprinting on activation.
]]

local AbilityManager = require("../../AbilityManager")
local AvatarBodyParts = require("../../Utility/AvatarBodyParts")

local All = AbilityManager.All
local Not = AbilityManager.Not
local Any = AbilityManager.Any

local ANIMATION_NAME = "Crouch"
local ANIMATION_ID = "rbxassetid://85080797628716"
local ANIMATION_IDLE_NAME = "CrouchIdle"
local ANIMATION_IDLE_ID = "rbxassetid://116212301484963"
local MOVE_SPEED_FACTOR = 0.5

local CrouchingAbility: AbilityManager.AbilityDefinition = {
	Name = "Crouching",
	ExclusiveGroup = { name = "LocomotionModifier", priority = 10 },
	Labels = { "locomotionModifier" },

	RequiresToActivate = All(Not("submerged"), "CrouchInputSensor", Any("GroundSensor", "quadLocomotion")),
	RequiresToContinue = Any("CrouchInputSensor", "CeilingSensor"),
}

local function getCrouchAnim(animator: Animator, animName: string, animId: string): Animation
	local animation: Animation? = animator:FindFirstChild(animName) :: Animation
	if not animation then
		-- Add the crouch animation
		animation = Instance.new("Animation") :: Animation
		animation.Name = animName
		animation.Parent = animator
		animation.AnimationId = animId
	end

	return animation
end

---------- Lifecycle Methods ----------

function CrouchingAbility.OnSetup(baseCtx: AbilityManager.BaseContext, state: AbilityManager.AbilityState)
	local controllerManager = baseCtx.controllerManager
	local humanoid = baseCtx.humanoid
	assert(humanoid, "")

	local animator: Animator? = humanoid:WaitForChild("Animator") :: Animator
	assert(
		animator,
		'CrouchingAbility.OnSetup: The character "' .. baseCtx.abilityOwner.Name .. '" does not have an Animator.'
	)

	local animation: Animation = getCrouchAnim(animator, ANIMATION_NAME, ANIMATION_ID)
	assert(animation, "")
	local track = animator:LoadAnimation(animation)
	track.Priority = Enum.AnimationPriority.Movement
	state.animTrack = track

	local animationIdle: Animation = getCrouchAnim(animator, ANIMATION_IDLE_NAME, ANIMATION_IDLE_ID)
	assert(animationIdle, "")
	local idleTrack = animator:LoadAnimation(animationIdle)
	idleTrack.Priority = Enum.AnimationPriority.Idle
	state.animIdleTrack = idleTrack

	-- Cache references directly in state (faster than SetSetting)
	if controllerManager then
		state.groundController = controllerManager:FindFirstChildWhichIsA("GroundController")
		state.hipHeight = state.groundController.GroundOffset
	end
end

function CrouchingAbility.OnActivate(
	baseCtx: AbilityManager.BaseContext,
	_frameCtx: AbilityManager.FrameContext,
	state: AbilityManager.AbilityState
)
	local groundController = state.groundController
	state.hipHeight = groundController.GroundOffset

	if groundController then
		AvatarBodyParts.SetRootPartCollide(baseCtx.abilityOwner, false)

		-- Initialize speed-change management
		state.appliedSpeedFactor = MOVE_SPEED_FACTOR
		groundController.MoveSpeedFactor *= state.appliedSpeedFactor
	end
	state.animIdleTrack:Play()
end

function CrouchingAbility.OnStep(
	_baseCtx: AbilityManager.BaseContext,
	frameCtx: AbilityManager.FrameContext,
	state: AbilityManager.AbilityState
)
	local move3d: Vector3 = frameCtx.move3d

	if move3d.Magnitude > 0 then
		if state.animIdleTrack.IsPlaying then
			state.animIdleTrack:Stop()
		end
		if not state.animTrack.IsPlaying then
			state.animTrack:Play()
		end

		state.animTrack:AdjustSpeed(1)
	else
		if state.animTrack.IsPlaying then
			state.animTrack:Stop()
		end
		if not state.animIdleTrack.IsPlaying then
			state.animIdleTrack:Play()
		end
	end

	-- Adjust speed-change management if necessary.
	local newFactor = MOVE_SPEED_FACTOR
	if newFactor ~= state.appliedSpeedFactor then
		state.groundController.MoveSpeedFactor *= newFactor / state.appliedSpeedFactor
		state.appliedSpeedFactor = newFactor
	end
end

function CrouchingAbility.OnDeactivate(
	baseCtx: AbilityManager.BaseContext,
	_frameCtx: AbilityManager.FrameContext,
	state: AbilityManager.AbilityState
)
	local groundController = state.groundController

	if groundController then
		groundController.GroundOffset = state.hipHeight
		AvatarBodyParts.SetRootPartCollide(baseCtx.abilityOwner, true)

		-- Remove this ability's influence on character speed
		groundController.MoveSpeedFactor /= state.appliedSpeedFactor
	end
	state.animTrack:Stop()
	state.animIdleTrack:Stop()
end

return CrouchingAbility
