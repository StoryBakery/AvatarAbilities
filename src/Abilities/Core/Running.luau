--!native
--[[ 
  Running Ability for Avatars
  This is the default locomotion Ability for a character traversing ground.
  It manages ControllerManager state and aligns movement vectors to the surface.
]]

local AbilityManager = require("../../AbilityManager")
local AvatarBodyParts = require("../../Utility/AvatarBodyParts")
local alignToPlane = require("../../Utility/alignToPlane")

local RunningAbility: AbilityManager.AbilityDefinition = {
	Name = "Running",
	ExclusiveGroup = { name = "Locomotion", priority = 20 }, -- only one Ability in this group active at a time
	Labels = { "canFallDown" }, -- tags other Abilities can query via rules
	StepSensors = { "MoveInputSensor", "LookSensor", "GroundSensor", "GroundTraversableSensor" }, -- polled every frame while active

	RequiresToActivate = { "GroundSensor" }, -- must be true to start
	RequiresToContinue = { "GroundSensor" }, -- must stay true or we deactivate
	BlocksWhileActive = {}, -- prevent these from activating
	CancelsOnActivation = {}, -- force-stop these when we start

	DefaultConfig = {
		-- Fraction of ControllerManager.BaseMoveSpeed to apply for this
		-- ability's locomotion
		MoveSpeedFactor = 1.0,
		-- The maximum slope angle that a humanoid can walk on without slipping
		MaxSlopeAngle = 89.0,
	},
}

-- Forward declarations
local makeGroundTraversableSensor

---------- Lifecycle  Methods ----------

-- Called once when the ability is first registered
function RunningAbility.OnSetup(baseCtx: AbilityManager.BaseContext, state: AbilityManager.AbilityState)
	local cm = baseCtx.controllerManager
	assert(cm, "")
	state.groundController = cm:FindFirstChildWhichIsA("GroundController")

	state.initialGroundFriction = state.groundController.Friction
	state.initialGroundFrictionWeight = state.groundController.FrictionWeight

	local am: AbilityManager.AbilityManager = baseCtx.abilityManager
	am:AddSensor("GroundTraversableSensor", makeGroundTraversableSensor(cm, am), { mode = "Polled" })
end

-- Called on the frame this ability becomes active
function RunningAbility.OnActivate(
	baseCtx: AbilityManager.BaseContext,
	_frameCtx: AbilityManager.FrameContext,
	state: AbilityManager.AbilityState
)
	local cm = baseCtx.controllerManager
	AvatarBodyParts.SetLimbsCollide(baseCtx.abilityOwner, false)
	AvatarBodyParts.SetTorsoCollide(baseCtx.abilityOwner, true)

	if cm and state.groundController then
		-- Initialize speed-change management
		cm.ActiveController = state.groundController
		state.appliedSpeedFactor = state.Config.MoveSpeedFactor
		cm.ActiveController.MoveSpeedFactor *= state.appliedSpeedFactor
	end
end

-- Called every frame while active
function RunningAbility.OnStep(
	baseCtx: AbilityManager.BaseContext,
	frameCtx: AbilityManager.FrameContext,
	state: AbilityManager.AbilityState
)
	local cm = baseCtx.controllerManager
	assert(cm, "")
	local move3d: Vector3 = frameCtx.move3d
	local groundDirection = alignToPlane(move3d, cm.UpDirection)

	if baseCtx.abilityManager:GetSensor("GroundTraversableSensor") then
		state.groundController.Friction = state.initialGroundFriction
		state.groundController.FrictionWeight = state.initialGroundFrictionWeight
	else
		-- On a slope which is too steep to traverse. Remove friction in order
		-- to slide down the slope.
		state.groundController.Friction = 0
		state.groundController.FrictionWeight = 10
	end
	cm.MovingDirection = groundDirection

	-- Adjust speed-change management if necessary
	local newFactor = state.Config.MoveSpeedFactor
	if newFactor ~= state.appliedSpeedFactor then
		cm.ActiveController.MoveSpeedFactor *= newFactor / state.appliedSpeedFactor
		state.appliedSpeedFactor = newFactor
	end
end

function RunningAbility.OnDeactivate(
	baseCtx: AbilityManager.BaseContext,
	_frameCtx: AbilityManager.FrameContext,
	state: AbilityManager.AbilityState
)
	-- Remove this ability's influence on character speed
	local cm = baseCtx.controllerManager
	cm.ActiveController.MoveSpeedFactor /= state.appliedSpeedFactor
end

---------- Sensors ----------
-- This sensor is defined locally, because it has a dependency on
-- RunningAbility. If it were defined in a separate file, that would create a
-- circular dependency.

-- Returns true if groundSensor senses ground that is traversable.
makeGroundTraversableSensor = function(controllerManager: ControllerManager, manager: AbilityManager.AbilityManager)
	return function()
		local groundSensor: ControllerPartSensor? = controllerManager.GroundSensor :: ControllerPartSensor
		assert(groundSensor, "")
		if not groundSensor.SensedPart then
			return false
		end
		local groundNormal = groundSensor.HitNormal
		-- Dot product of "up" with the ground normal
		local dot: number = groundNormal.y
		local maxSlopeCos: number = math.cos(manager:GetState(RunningAbility.Name).Config.MaxSlopeAngle * math.pi / 180)
		return (dot >= maxSlopeCos)
	end
end

return RunningAbility
