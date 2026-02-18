--!native
--[[ 
  Swimming Ability for Avatars
  Handles aquatic locomotion, orienting the character for swimming
  and managing transitions to/from water.
]]

local AbilityManager = require("../../AbilityManager")
local AvatarBodyParts = require("../../Utility/AvatarBodyParts")
local GettingUpAbility = require("./GettingUp")
local MathUtil = require("../../Utility/MathUtil")
local inputSensors = require("../../Sensors/InputSensors")

local All = AbilityManager.All
local Any = AbilityManager.Any
local Not = AbilityManager.Not

local CONSTS = {
	-- Min fraction of controllerManager.BaseMoveSpeed above which the character
	-- is to have a swimming orientation, and below which they are to be
	-- oriented upright
	MIN_SWIM_SPEED_PERCENT = 0.00625, -- 0.1/16 where 16 is standard base speed
	-- Cosine of the angle (in radians) beyond the horizontal plane under which
	-- a character's movement is to still be treated as horizontal.
	MAX_HORIZONTAL_DEVIATION = math.cos(math.rad(26.5)),
	-- This is the maximum torque that the swim controller will apply to the
	-- character's pitch joint. We set this to a high value to ensure when the
	-- character is swimming into the floor, the character will not flip.
	SWIM_PITCH_MAX_TORQUE = 25000,
}
-- If the movement vector is of unit length (rather than being less than unit),
-- then for performance we can use a simplified check-if-near-horizontal
-- against MAX_SQUARED_DEVIATION_FOR_UNIT_VECTOR.
-- Here is the math:
--  For mag(moveDir) == M, let's draw out the triangle:
--  ..|\M
--  Y.|__\
--  ....L
--  cos = L/M; Thus cos^2 = L^2/M^2
--  and M^2 = Y^2 + L^2
--    Thus cos^2 = (M^2 - Y^2)/M^2
--    And if M = 1 (unit vector), that simplifies to cos^2 = 1 - Y^2.
--  Therefore, for unit M, we can check if
--   (1-moveDir.Y^2) < CONSTS.MAX_SQUARED_DEVIATION_FOR_UNIT_VECTOR
CONSTS.MAX_SQUARED_DEVIATION_FOR_UNIT_VECTOR = math.pow(CONSTS.MAX_HORIZONTAL_DEVIATION, 2)
table.freeze(CONSTS)

local SwimmingAbility: AbilityManager.AbilityDefinition = {
	Name = "Swimming",
	ExclusiveGroup = { name = "Locomotion", priority = 50 },
	Labels = { "armL", "handL", "armR", "handR" },
	StepSensors = { "MoveInputSensor", "LookSensor", "WaterSensor", "WaterSurfaceSensor" },

	RequiresToActivate = { Any(All("WaterSensor", Not("WaterSurfaceSensor")), All("WaterSurfaceSensor", Not("jump"))) },
	RequiresToContinue = { Any(All("WaterSensor", Not("WaterSurfaceSensor")), All("WaterSurfaceSensor", Not("jump"))) },
	-- Swimming handles character facing direction on its own
	BlocksWhileActive = { "locomotionModifier", "armL", "handL", "armR", "handR" },
	CancelsOnActivation = { "locomotionModifier", "armL", "handL", "armR", "handR", "fallingdown" },

	DefaultConfig = {
		MoveSpeedFactor = 1.0,
		EnableFastRise = true,
	},
}

---------- Lifecycle Methods ----------

function SwimmingAbility.OnSetup(baseCtx: AbilityManager.BaseContext, state: AbilityManager.AbilityState)
	local cm = baseCtx.controllerManager

	if cm then
		state.swimController = cm:FindFirstChildWhichIsA("SwimController")
	end
	if baseCtx.inputActions and baseCtx.inputActions.Jump then
		baseCtx.abilityManager:AddSensor("FastRiseInputSensor", inputSensors.makeHoldSensor(baseCtx.inputActions.Jump)) -- prob should clean this up on destroy
	end
end

function SwimmingAbility.OnActivate(
	baseCtx: AbilityManager.BaseContext,
	_frameCtx: AbilityManager.FrameContext,
	state: AbilityManager.AbilityState
)
	local cm = baseCtx.controllerManager

	if cm and state.swimController then
		state.swimController.PitchMaxTorque = CONSTS.SWIM_PITCH_MAX_TORQUE
		state.swimController.PitchSpeedFactor = 1.0
		state.swimController.RollSpeedFactor = 1.0

		-- Initialize speed-change management
		state.appliedSpeedFactor = state.Config.MoveSpeedFactor
		state.swimController.MoveSpeedFactor *= state.appliedSpeedFactor

		cm.ActiveController = state.swimController
	end

	AvatarBodyParts.SetLimbsCollide(baseCtx.abilityOwner, true)
	AvatarBodyParts.SetTorsoCollide(baseCtx.abilityOwner, true)
end

function SwimmingAbility.OnDeactivate(
	baseCtx: AbilityManager.BaseContext,
	_frameCtx: AbilityManager.FrameContext,
	state: AbilityManager.AbilityState
)
	local manager = baseCtx.abilityManager

	-- Remove this ability's influence on character speed
	state.swimController.MoveSpeedFactor /= state.appliedSpeedFactor

	if manager:GetSensor("GroundSensor") then
		-- GettingUp is used as a transition from swim to walk
		manager:ActivateAbility(GettingUpAbility.Name)
	end
end

function SwimmingAbility.OnStep(
	baseCtx: AbilityManager.BaseContext,
	frameCtx: AbilityManager.FrameContext,
	state: AbilityManager.AbilityState
)
	local manager = baseCtx.abilityManager
	local cm = baseCtx.controllerManager

	if not cm then
		return
	end

	-- Adjust speed-change management if necessary
	local newFactor = state.Config.MoveSpeedFactor
	if newFactor ~= state.appliedSpeedFactor then
		state.swimController.MoveSpeedFactor *= newFactor / state.appliedSpeedFactor
		state.appliedSpeedFactor = newFactor
	end

	local intendedMoveDirection = frameCtx.move3d

	if intendedMoveDirection.Magnitude >= CONSTS.MIN_SWIM_SPEED_PERCENT then
		-- clamp the move direction to the horizontal plane while swimming within some
		-- angle limits of horizontal, to be closer to legacy swimming behavior
		local horizontalDirection = intendedMoveDirection * Vector3.new(1, 0, 1)
		local horizDirMag: number = horizontalDirection.Magnitude
		if horizDirMag > 0 then
			if MathUtil.fuzzyEquals(horizDirMag, 1.0) then
				-- More performant math for the common case where the movement
				-- vector is of unit length
				if (1 - math.pow(intendedMoveDirection.Y, 2)) > CONSTS.MAX_SQUARED_DEVIATION_FOR_UNIT_VECTOR then
					intendedMoveDirection = horizontalDirection
				end
			else
				local cosAngle = horizontalDirection.Unit:Dot(intendedMoveDirection.Unit)
				if cosAngle >= CONSTS.MAX_HORIZONTAL_DEVIATION then
					intendedMoveDirection = horizontalDirection
				end
			end
		end
		cm.FacingDirection = intendedMoveDirection.Unit
	else
		-- When not locomoting, the character is oriented upright
		cm.FacingDirection = Vector3.yAxis
		intendedMoveDirection = Vector3.new(0, 0, 0)
	end

	-- Handle input which causes the swimmer to rise faster
	if
		not manager:GetSensor("WaterSurfaceSensor")
		and state.Config.EnableFastRise
		and manager:GetSensor("FastRiseInputSensor")
	then
		-- The character can rise by only an amount which brings their
		-- intendedMoveDirection to unit length, thereby enforcing
		-- controllerManager.BaseMoveSpeed as a max speed.
		local unusedVelPercent: number = 1.0 - intendedMoveDirection.Magnitude
		if unusedVelPercent > 0 then
			local magXZ = math.pow(intendedMoveDirection.X, 2) + math.pow(intendedMoveDirection.Z, 2)
			local desiredY = math.sqrt(1 - magXZ)
			intendedMoveDirection = Vector3.new(intendedMoveDirection.X, desiredY, intendedMoveDirection.Z)
		end
	end
	cm.MovingDirection = intendedMoveDirection
end

return SwimmingAbility
