--[[
	SharedSimulation
	================
	All deterministic simulation logic for the AbilityManager system.
	Both client and server can share identical runner creation and step code.

	Mode behavior:
	  None:      Step on PreAnimation (client only, legacy)
	  Automatic: Step on BindToSimulation (both sides, fixed timestep)
	  Server:    Step on BindToSimulation (both sides, rollback-capable)
]]

local RunService = game:GetService("RunService")

local AbilityManager = require("./AbilityManager")
local AuthorityConfig = require("./AuthorityConfig")
local FrameContext = require("./FrameContext")

-- Sensor factories
local inputSensors = require("./Sensors/InputSensors")
local makeWaterSensor = require("./Sensors/WaterSensor")
local makeWaterSurfaceSensor = require("./Sensors/WaterSurfaceSensor")

local isTipped = require("./Utility/isTipped")

-- Abilities that are NOT compatible with Server Authority. When SA is enabled
-- these are disabled on BOTH client and server to keep simulation consistent.
-- TODO: Fix these abilities to work under SA so this list can be removed.
local SERVER_AUTHORITY_INCOMPATIBLE_ABILITIES: { AbilityManager.AbilityDefinition } = {}

local CORE_ABILITIES: { AbilityManager.AbilityDefinition } = {
	require("./Abilities/Core/Climbing"),
	require("./Abilities/Core/Dead"),
	require("./Abilities/Core/FallingDown"),
	require("./Abilities/Core/Freefall"),
	require("./Abilities/Core/GettingUp"),
	require("./Abilities/Core/Jumping"),
	require("./Abilities/Core/LegacyPlatformStand"),
	require("./Abilities/Core/Running"),
	require("./Abilities/Core/Sitting"),
	require("./Abilities/Core/Swimming"),
	require("./Abilities/Modifiers/Crouching"),
	require("./Abilities/Modifiers/FacingMoveDirection"),
	require("./Abilities/Modifiers/Sprinting"),
	require("./Abilities/Modifiers/Strafing"),
}

local SharedSimulation = {}

--------------------------------------------------------------------------------
-- Sensor Registration
--------------------------------------------------------------------------------

function SharedSimulation.registerInputSensors(
	runner: AbilityManager.AbilityManager,
	inputActions: { [string]: InputAction }
)
	runner:AddSensor("MoveInputSensor", inputSensors.makeMoveSensor(inputActions.Move, 0.05, 0.01))
	runner:AddSensor("LookSensor", inputSensors.makeLookSensor(inputActions.Look, 0.005))
	runner:AddSensor("JumpInputSensor", inputSensors.makeHoldSensor(inputActions.Jump))
	runner:AddSensor("FastRiseInputSensor", inputSensors.makeHoldSensor(inputActions.Jump))
	runner:AddSensor("SprintInputSensor", inputSensors.makeHoldSensor(inputActions.Sprint))
	runner:AddSensor("StrafeInputSensor", inputSensors.makeToggleSensor(inputActions.Strafe))
	runner:AddSensor("CrouchInputSensor", inputSensors.makeToggleSensor(inputActions.Crouch))
end

function SharedSimulation.registerPhysicsSensors(
	runner: AbilityManager.AbilityManager,
	controllerManager: ControllerManager,
	_character: Model
)
	local floorSensor = controllerManager.GroundSensor

	runner:AddSensor("GroundSensor", function()
		return floorSensor and floorSensor.SensedPart and floorSensor or false
	end, { mode = "Polled" })

	runner:AddSensor("TippedSensor", function(frame)
		return frame and frame.rootUp and isTipped(frame.rootUp) or false
	end, { mode = "Polled" })

	runner:AddSensor("WaterSensor", makeWaterSensor(runner._baseContext.rootPart), { mode = "Polled" })
	runner:AddSensor("WaterSurfaceSensor", makeWaterSurfaceSensor(runner._baseContext.rootPart), { mode = "Polled" })
end

--------------------------------------------------------------------------------
-- Ability Registration (filtered by SA compatibility)
--------------------------------------------------------------------------------

--[[
	Registers all platform abilities on the given runner.

	When Server Authority is enabled, SA-incompatible abilities are skipped
	on BOTH client and server to keep simulation consistent across peers.

	All other abilities are treated as network owner — they run on whatever peer
	has the runner. Server-only actions within abilities should be handled as
	special cases inside specific abilities, not via a general RunContext field.
]]
function SharedSimulation.registerAbilities(runner: AbilityManager.AbilityManager)
	for _, ability in CORE_ABILITIES do
		runner:AddAbility(ability)
	end

	if not AuthorityConfig.isServerAuth then
		for _, ability in SERVER_AUTHORITY_INCOMPATIBLE_ABILITIES do
			runner:AddAbility(ability)
		end
	end
end

--------------------------------------------------------------------------------
-- Runner Creation
--------------------------------------------------------------------------------

function SharedSimulation.createRunner(
	character: Model,
	controllerManager: ControllerManager,
	humanoid: Humanoid,
	inputActions: { [string]: InputAction }
): AbilityManager.AbilityManager
	local baseContext = {
		humanoid = humanoid,
		controllerManager = controllerManager,
		rootPart = controllerManager.RootPart,
		inputActions = inputActions,
	}

	local runner = AbilityManager.createRunner(character, baseContext)

	SharedSimulation.registerInputSensors(runner, inputActions)
	SharedSimulation.registerPhysicsSensors(runner, controllerManager, character)
	SharedSimulation.registerAbilities(runner)

	return runner
end

--------------------------------------------------------------------------------
-- Step Loop (mode-aware)
--------------------------------------------------------------------------------

--[[
	Builds the step function and binds it to the correct RunService event.
	  None:      PreAnimation (legacy, no fixed sim)
	  Automatic: BindToSimulation (fixed timestep, both sides)
	  Server:    BindToSimulation (fixed timestep + rollback on both sides)
]]
function SharedSimulation.createUpdateLoop(
	runner: AbilityManager.AbilityManager,
	inputActions: { [string]: InputAction }
): RBXScriptConnection?
	local frameContext = FrameContext.new()
	local runnerStep = runner.Step
	local vector3Z = -Vector3.zAxis
	local yAxis = Vector3.yAxis
	local moveAction = inputActions.Move
	local lookAction = inputActions.Look
	local cachedCM = runner._baseContext.controllerManager

	local stepConnection: RBXScriptConnection? = nil

	local function step(deltaTime: number)
		if not runner.Owner or not runner.Owner:IsDescendantOf(game) then
			if stepConnection then
				stepConnection:Disconnect()
			end
			return
		end

		if not cachedCM then
			return
		end

		local target = runner.Owner
		local rootCF: CFrame
		if target:IsA("Model") and target.PrimaryPart then
			rootCF = target.PrimaryPart.CFrame
		else
			rootCF = CFrame.new()
		end

		frameContext.deltaTime = deltaTime
		frameContext.rootCFrame = rootCF
		frameContext.rootPos = rootCF.Position
		frameContext.rootLook = rootCF.LookVector
		frameContext.rootUp = rootCF.UpVector

		local move2d = (moveAction and moveAction:GetState()) or Vector2.zero
		local look = (lookAction and lookAction:GetState()) or vector3Z

		if look == Vector2.zero or look == Vector3.zero then
			look = vector3Z
		end

		local right = look:Cross(yAxis).Unit
		frameContext.move2d = move2d
		frameContext.look = look
		frameContext.move3d = (move2d.X * right) + (move2d.Y * look)

		runnerStep(runner, frameContext)
	end

	if AuthorityConfig.sAuthBetaEnabled then
		-- Beta active (Automatic or Server): BindToSimulation for fixed timestep.
		-- In Server mode this also participates in rollback/resimulation.
		stepConnection = RunService:BindToSimulation(step)
	else
		-- No beta: legacy PreAnimation binding.
		stepConnection = RunService.PreAnimation:Connect(step)
	end

	return stepConnection
end

--------------------------------------------------------------------------------
-- InputAction Resolution (works on client and server)
--------------------------------------------------------------------------------

function SharedSimulation.resolveInputActions(character: Model): { [string]: InputAction }?
	local inputContext = character:WaitForChild("AbilityManagerInput", 10)
	if not inputContext then
		warn("[SharedSimulation] Timed out waiting for AbilityManagerInput on", character.Name)
		return nil
	end

	return {
		Move = inputContext:WaitForChild("Move"),
		Look = inputContext:WaitForChild("Look"),
		Jump = inputContext:WaitForChild("Jump"),
		Sprint = inputContext:WaitForChild("Sprint"),
		Crouch = inputContext:WaitForChild("Crouch"),
		Strafe = inputContext:WaitForChild("Strafe"),
	}
end

return SharedSimulation
