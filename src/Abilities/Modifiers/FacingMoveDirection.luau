--!native
--[[ 
  FacingMoveDirection Ability for Avatars
  A direction modifier that rotates the character to face their movement vector,
  projected onto the ground plane. Sleeps when aligned within ~11 degrees.
]]

local AbilityManager = require("../../AbilityManager")
local alignToPlane = require("../../Utility/alignToPlane")

-- Forward declaration (defined at bottom of file)
local makeLocomotionAlignmentSensor

local CONSTS = {
	-- 0.98 is roughly 11 degrees of variance allowed before sleeping
	ALIGNMENT_THRESHOLD = 0.98,
	MOVEMENT_THRESHOLD = 0.1,
}
table.freeze(CONSTS)

local Not = AbilityManager.Not

local FacingMoveDirectionAbility: AbilityManager.AbilityDefinition = {
	Name = "FacingMoveDirection",
	ExclusiveGroup = { name = "DirectionModifier", priority = 0 },
	Labels = {},
	StepSensors = { "MoveInputSensor", "LookSensor", "GroundSensor", "LocomotionAlignmentSensor" },

	RequiresToActivate = { Not("WaterSensor") },
	RequiresToContinue = { Not("WaterSensor") },
	BlocksWhileActive = {},
	CancelsOnActivation = {},

	DefaultConfig = {},
}

---------- Lifecycle Methods ----------

function FacingMoveDirectionAbility.OnSetup(baseCtx)
	local manager = baseCtx.abilityManager
	local name, getter = makeLocomotionAlignmentSensor(baseCtx.controllerManager)
	manager:AddSensor(name, getter, { mode = "Polled" })
end

function FacingMoveDirectionAbility.OnStep(baseCtx, frameCtx, _state)
	local cm = baseCtx.controllerManager
	if not cm or (baseCtx.humanoid and not baseCtx.humanoid.AutoRotate) then
		return
	end

	local move = cm.MovingDirection

	if move.Magnitude >= CONSTS.MOVEMENT_THRESHOLD then
		local flatDirection = alignToPlane(move, cm.UpDirection)
		if flatDirection.Magnitude > 0 then
			cm.FacingDirection = flatDirection
		end
	else
		-- Safety Sync
		cm.FacingDirection = frameCtx.rootLook
	end
end

---------- Sensors ----------

-- LocomotionAlignmentSensor: Checks if character facing matches move direction.
-- Returns true when aligned, time() when misaligned (to prevent sleep).
function makeLocomotionAlignmentSensor(cm: ControllerManager)
	return "LocomotionAlignmentSensor",
		function(frame)
			if not frame then
				return true
			end
			local move3d = frame.move3d
			-- If we aren't trying to move, we are technically "aligned" (no need to turn)
			if not move3d or move3d.Magnitude < 0.01 then
				local floorPart = cm.GroundSensor.SensedPart
				if
					floorPart
					and (
						floorPart.AssemblyLinearVelocity.Magnitude > 0.001
						or floorPart.AssemblyAngularVelocity.Magnitude > 0.001
					)
				then
					return time() -- dont sleep on moving platforms
				end
				return true
			end

			local rootLook = frame.rootLook
			local rootUp = frame.rootUp

			-- Calculate the desired facing direction (flattened to ground plane)
			local desiredLook = alignToPlane(move3d, rootUp)

			-- If desired look is invalid, we can't align
			if desiredLook.Magnitude == 0 then
				return true
			end
			desiredLook = desiredLook.Unit

			-- Check alignment
			local dot = rootLook:Dot(desiredLook)
			if dot > CONSTS.ALIGNMENT_THRESHOLD then
				return true
			end

			-- We are MISALIGNED — ensure we don't sleep
			return time()
		end
end

return FacingMoveDirectionAbility
