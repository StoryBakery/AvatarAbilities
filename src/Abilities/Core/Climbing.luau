--!native
--[[ 
  Climbing Ability for Avatars
  Handles ladder/wall climbing locomotion.
  Manages the ClimbController, input projection onto the climb surface,
  and dismount logic when the player moves away at the base.
]]

local AbilityManager = require("../../AbilityManager")
local AvatarBodyParts = require("../../Utility/AvatarBodyParts")

local Not = AbilityManager.Not

-- Sensor factory functions
local makeClimbIntentSensor = require("../../Sensors/ClimbIntentSensor")
local makeClimbSensor = require("../../Sensors/ClimbSensor")

local MOVE_THRESHOLD = 0.1

local ClimbingAbility: AbilityManager.AbilityDefinition = {
	Name = "Climbing",
	ExclusiveGroup = { name = "Locomotion", priority = 40 },
	Labels = { "detachable", "canFallDown", "armL", "handL", "armR", "handR" },
	StepSensors = { "MoveInputSensor", "LookSensor", "ClimbSensor", "GroundSensor" }, -- polled every frame while active

	-- Sensor order determines evaluation sequence.
	RequiresToActivate = { Not("jump"), "MoveInputSensor", "ClimbSensor", "ClimbIntentSensor" },
	RequiresToContinue = { "ClimbSensor" }, -- once attached, only needs to maintain physical contact with the ladder
	BlocksWhileActive = { "locomotionModifier", "armL", "handL", "armR", "handR" },
	CancelsOnActivation = { "locomotionModifier", "armL", "handL", "armR", "handR" },

	DefaultConfig = {},
}

---------- Lifecycle Methods ----------

function ClimbingAbility.OnSetup(baseCtx: AbilityManager.BaseContext, state: AbilityManager.AbilityState)
	local cm = baseCtx.controllerManager
	local manager = baseCtx.abilityManager

	-- Register Ability-specific sensors
	manager:AddSensor("ClimbSensor", makeClimbSensor(cm, manager), { mode = "Polled" })
	manager:AddSensor("ClimbIntentSensor", makeClimbIntentSensor(baseCtx.rootPart, manager), { mode = "Lazy" })

	-- Store controller in state for OnActivate
	state.climbController = cm and cm:FindFirstChildWhichIsA("ClimbController")
end

function ClimbingAbility.OnActivate(
	baseCtx: AbilityManager.BaseContext,
	_frameCtx: AbilityManager.FrameContext,
	state: AbilityManager.AbilityState
)
	local cm = baseCtx.controllerManager

	if cm and state.climbController then
		cm.ActiveController = state.climbController
	end

	AvatarBodyParts.SetLimbsCollide(baseCtx.abilityOwner, false)
	AvatarBodyParts.SetTorsoCollide(baseCtx.abilityOwner, true)
end

function ClimbingAbility.OnStep(
	baseCtx: AbilityManager.BaseContext,
	frameCtx: AbilityManager.FrameContext,
	_state: AbilityManager.AbilityState
)
	local cm = baseCtx.controllerManager
	if not cm then
		return
	end

	local manager = baseCtx.abilityManager
	local move2d = frameCtx.move2d
	local cameraLook = frameCtx.look
	local rootPart = baseCtx.rootPart

	local worldUp = Vector3.yAxis
	local cameraRight = cameraLook:Cross(worldUp)
	assert(cameraRight.Magnitude > 0, "Error: Camera Look aligned with World Up")
	cameraRight = cameraRight.Unit

	-- This first projection of the camera look vector is onto the ground established by World Up
	local cameraLookProj = cameraLook - cameraLook:Dot(worldUp) * worldUp
	assert(cameraLookProj.Magnitude > 0, "Error: Camera Look aligned with World Up")
	cameraLookProj = cameraLookProj.Unit

	-- Note: moveIntent3d in this function is a projection onto the ground plane,
	-- which is the plane orthogonal to World Up
	local moveIntent3d = move2d.X * cameraRight + move2d.Y * cameraLookProj
	local moveMag = moveIntent3d.Magnitude

	-- Projection of HRP LookVector onto ground plane established by World Up
	local hrpLookProjXZ = rootPart.CFrame.LookVector - rootPart.CFrame.LookVector:Dot(worldUp) * worldUp

	if moveMag < MOVE_THRESHOLD then
		moveIntent3d = Vector3.zero
	else
		-- Dismount at base of ladder
		local relativeForwardMovement = moveMag * math.sign(moveIntent3d:Dot(hrpLookProjXZ))
		if relativeForwardMovement < -MOVE_THRESHOLD then
			-- We query the cached sensor value directly from the Manager for O(1) performance
			if manager:GetSensor("GroundSensor") then
				manager:DeactivateAbility(ClimbingAbility.Name, "Moving Away on Floor")
				return
			end
		end
	end

	if hrpLookProjXZ.Magnitude > 0 then
		moveIntent3d = moveMag * math.sign(moveIntent3d:Dot(hrpLookProjXZ)) * hrpLookProjXZ
	end

	cm.MovingDirection = moveIntent3d
end

function ClimbingAbility.OnDeactivate(
	_baseCtx: AbilityManager.BaseContext,
	_frameCtx: AbilityManager.FrameContext,
	_state: AbilityManager.AbilityState
)
	-- Cleanup if necessary
end

return ClimbingAbility
