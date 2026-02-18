--!native
--[[ 
  Jumping ability for avatars
  Applies an instantaneous vertical impulse to the character when triggered.
]]

local AbilityManager = require("../../AbilityManager")
local AvatarBodyParts = require("../../Utility/AvatarBodyParts")
local ClimbingAbility = require("./Climbing")
local applyBalancedImpulseToCharacter = require("../../Utility/applyBalancedImpulseToCharacter")

local Any = AbilityManager.Any
local All = AbilityManager.All
local Not = AbilityManager.Not

local FreefallAbility = require("./Freefall")
local RunningAbility = require("./Running")

-- Forward declarations for sensors (defined at bottom of file)
local CoyoteTimeSensor
local CeilingSensor

local CONSTS = table.freeze({
	-- Amount of seconds which the jump ability is to remain active
	MAX_ACTIVE_DURATION = 0.5,
	MIN_ACTIVE_DURATION_BEFORE_GROUND_CANCEL = 0.125,
	-- in studs per second
	MIN_JUMP_SPEED = 0.0,
	MAX_JUMP_SPEED = 1000.0,
	-- Amount of seconds which cyote-time is in effect while no ground is
	-- underfoot
	COYOTE_TIME = 0.125,
})

local JumpingAbility: AbilityManager.AbilityDefinition = {
	Name = "Jumping",
	Labels = { "jump" },

	-- Disable the sleep system so the jump timer can count frames
	CanSleep = false,
	StepSensors = {},
	RequiresToActivate = All(
		"JumpInputSensor",
		Any(
			"WaterSurfaceSensor",
			"detachable",
			All("GroundSensor", "GroundTraversableSensor", Not("WaterSensor")),
			All("CoyoteTimeSensor", Not("WaterSensor"))
		)
	),
	RequiresToContinue = {},
	-- Note: We cancel Climbing in the activation so we can jump differently if on a ladder.
	CancelsOnActivation = { "locomotionModifier" },
	BlocksWhileActive = { "locomotionModifier" },

	DefaultConfig = {
		JumpHeight = 7.2,
		UseJumpPower = false,
		JumpPower = 50,
	},
}

local function isCoyoteTimeActive(manager: AbilityManager.AbilityManager): boolean
	-- FreefallAbility must be explicitly checked for being actice, as opposed to
	-- just relying on Running no longer being active, in order to account for
	-- situations like Running ending due to walking into water.
	if not manager:IsAbilityActive(FreefallAbility.Name) then
		return false
	end
	local runningDeactivateTime: number? = manager:GetTimeWhenAbilityLastDeactivated(RunningAbility.Name)
	if not runningDeactivateTime then
		return false
	end
	local timeSinceRunningEnded: number = time() - runningDeactivateTime
	local jumpDeactivateTime: number? = manager:GetTimeWhenAbilityLastDeactivated(JumpingAbility.Name)
	if jumpDeactivateTime and jumpDeactivateTime > runningDeactivateTime then
		return false
	end
	return CONSTS.COYOTE_TIME > timeSinceRunningEnded
end

---------- Helper Functions ----------

-- Returns the desired jump speed based on humanoid properties, in studs per second
local function GetTargetJumpSpeed(state: AbilityManager.AbilityState): number
	local jumpSpeed: number
	if state.Config.UseJumpPower then
		-- "power" is treated here as speed
		jumpSpeed = state.Config.JumpPower
	else
		-- Note workspace.Gravity is an acceleration, not a force
		jumpSpeed = math.sqrt(2.0 * workspace.Gravity * state.Config.JumpHeight)
		jumpSpeed = math.clamp(jumpSpeed, CONSTS.MIN_JUMP_SPEED, CONSTS.MAX_JUMP_SPEED)
	end
	return jumpSpeed
end

-- Calculates the jump impulse based on Humanoid properties.
-- Impulse here is momentum, (mass * vel).
local function GetImpulseForJump(jumpDir: Vector3, rootPart: BasePart, state: AbilityManager.AbilityState): Vector3
	local jumpSpeed: number = GetTargetJumpSpeed(state)
	jumpSpeed = jumpSpeed - rootPart.AssemblyLinearVelocity:Dot(jumpDir)
	local characterMass = rootPart.AssemblyMass
	return jumpDir * jumpSpeed * characterMass
end

-- Impulse here is momentum, (mass * vel).
local function ApplyJumpImpulse(
	baseCtx: AbilityManager.BaseContext,
	jumpDir: Vector3,
	state: AbilityManager.AbilityState
)
	local humanoid = baseCtx.humanoid
	local rootPart = baseCtx.rootPart
	local controllerManager = baseCtx.controllerManager

	if not humanoid then
		warn("Jumping: humanoid is nil")
		return
	end
	if not controllerManager or not rootPart then
		warn("ApplyJumpImpulse: context.controllerManager or RootPart is nil")
		return
	end

	local impulse: Vector3 = GetImpulseForJump(jumpDir, rootPart, state)

	-- false is passed as the mustConserve parameter when jumping off of air or
	-- water.
	local am = baseCtx.abilityManager
	local mustConserve = not (isCoyoteTimeActive(am) or am:GetSensor("WaterSurfaceSensor"))
	applyBalancedImpulseToCharacter(impulse, rootPart, controllerManager, mustConserve)
end

---------- Lifecycle Methods ----------

-- Called once when the ability is first registered
function JumpingAbility.OnSetup(baseCtx: AbilityManager.BaseContext, state: AbilityManager.AbilityState)
	local runner = baseCtx.abilityManager

	-- Register ability-specific sensors
	runner:AddSensor(CoyoteTimeSensor(runner))
	runner:AddSensor(CeilingSensor(baseCtx.humanoid))

	state.isFirstStep = false
	state.activatedWhileClimbing = false
end

-- Called on the frame this ability becomes active
function JumpingAbility.OnActivate(
	baseCtx: AbilityManager.BaseContext,
	frameCtx: AbilityManager.FrameContext,
	state: AbilityManager.AbilityState
)
	state.isFirstStep = true

	AvatarBodyParts.SetLimbsCollide(baseCtx.abilityOwner, false)
	AvatarBodyParts.SetTorsoCollide(baseCtx.abilityOwner, false)

	local jumpDir = Vector3.yAxis

	-- Determine activation context to handle directional jumps
	local manager = baseCtx.abilityManager
	local activatedWhileClimbing = manager:IsAbilityActive(ClimbingAbility.Name)

	-- If jumping out of a climb, change the direction of the jump
	if activatedWhileClimbing then
		local lookDir: Vector3 = frameCtx.rootLook
		lookDir = Vector3.new(lookDir.X, 0.0, lookDir.Z)
		lookDir = lookDir.Unit
		jumpDir = jumpDir - lookDir
		jumpDir = jumpDir.Unit
		manager:DeactivateAbility(ClimbingAbility.Name)
	end

	ApplyJumpImpulse(baseCtx, jumpDir, state)
end

-- Called every frame while active
function JumpingAbility.OnStep(
	baseCtx: AbilityManager.BaseContext,
	_frameCtx: AbilityManager.FrameContext,
	state: AbilityManager.AbilityState
)
	local manager = baseCtx.abilityManager

	-- The first step is ignored because ApplyJumpImpulse will not have
	-- affected the character's velocity yet
	if state.isFirstStep then
		state.isFirstStep = false
		return
	end

	local name = JumpingAbility.Name

	-- It may be tempting to end the jump when the character's vertical speed
	-- nears zero. However, that would not take in account situations where
	-- other factors contribute to speed (such as being in an elevator.)
	-- Instead, a timeout is used. And special ending conditions are also
	-- checked.
	local timeActive: number? = manager:GetTimeWhenAbilityLastActivated(name)
	if not timeActive then
		manager:DeactivateAbility(name)
		return
	end

	local timeSinceActive: number = time() - timeActive

	-- Jumping is not blocked by Running, because of the need to execute at least one
	-- step of Jumping. Instead, ground/water is checked here.
	-- We query the cached sensor value directly from the Manager for O(1) performance.
	if
		CONSTS.MAX_ACTIVE_DURATION < timeSinceActive
		or (manager:GetSensor("GroundSensor") and CONSTS.MIN_ACTIVE_DURATION_BEFORE_GROUND_CANCEL < timeSinceActive)
		or manager:GetSensor("CeilingSensor")
	then
		manager:DeactivateAbility(name)
	end
end

---------- Sensors ----------

-- CoyoteTimeSensor: Grace period after leaving ground (0.15s)
function CoyoteTimeSensor(runner)
	return "CoyoteTimeSensor",
		function()
			if not runner:IsAbilityActive("Freefall") then
				return false
			end
			local runningDeactivatedAt = runner:GetTimeWhenAbilityLastDeactivated("Running")
			if not runningDeactivatedAt then
				return false
			end

			local jumpActivatedAt = runner:GetTimeWhenAbilityLastActivated("Jumping")

			if jumpActivatedAt and jumpActivatedAt > runningDeactivatedAt then
				return false
			end
			return (time() - runningDeactivatedAt) <= CONSTS.COYOTE_TIME
		end
end

--[=[
	CeilingSensor
	-------------
	Factory function that creates a ceiling detection sensor.
	Uses multiple raycasts to detect overhead obstructions.
]=]

function CeilingSensor(humanoid: Humanoid)
	local character = humanoid.Parent
	if not character then
		return "CeilingSensor", function()
			return false
		end
	end

	local raycastParams = RaycastParams.new()
	raycastParams.FilterType = Enum.RaycastFilterType.Exclude
	raycastParams.FilterDescendantsInstances = { character }

	return "CeilingSensor",
		function()
			local torsoPrim = character:FindFirstChild("UpperTorso") :: MeshPart
			local headPrim = character:FindFirstChild("Head") :: MeshPart

			if not torsoPrim then
				return false
			end

			local rayLength: number = 1.5 * torsoPrim.Size.Y
			local rayOrigin: Vector3 = torsoPrim.Position
			local rayDirection: Vector3 = Vector3.new(0, rayLength, 0)

			if headPrim then
				rayLength += headPrim.Size.Y
				rayDirection = Vector3.new(0, rayLength, 0)
			end

			-- Center ray
			local result = workspace:Raycast(rayOrigin, rayDirection, raycastParams)
			if result then
				return true
			end

			-- Corner rays
			local torsoFraction: Vector3 = 0.4 * torsoPrim.Size
			for x = -1, 1, 2 do
				for z = -1, 1, 2 do
					local offset = Vector3.new(x * torsoFraction.X, -torsoFraction.Y, z * torsoFraction.Z)
					local pointOnTorso = torsoPrim.Position + offset
					result = workspace:Raycast(pointOnTorso, rayDirection, raycastParams)
					if result then
						return true
					end
				end
			end

			return false
		end
end

return JumpingAbility
