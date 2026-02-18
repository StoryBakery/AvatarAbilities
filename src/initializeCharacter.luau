--[=[
	initializeCharacter
	--------------------
	Unified AbilityManager runner setup for the AvatarAbilities system.
	Called on BOTH client and server — branches internally where needed.

	Replaces the previous split between initializeLocalCharacter and
	initializeServerCharacter.

	The step event is chosen automatically by SharedSimulation:
	  None:      PreAnimation (legacy)
	  Automatic: BindToSimulation (fixed timestep)
	  Server:    BindToSimulation (fixed timestep + rollback prediction)

	Peer-specific branching is minimal:
	  - Client: GrabAbilityInputBinder setup (uses mouse/keyboard APIs)
	  - These branches should shrink over time.
]=]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local AbilityManager = require("./AbilityManager")
local AuthorityConfig = require("./AuthorityConfig")
local SharedSimulation = require("./SharedSimulation")
local connectHumanoidShim = require("./connectHumanoidShim")

local isClient = RunService:IsClient()

--------------------------------------------------------------------------------
-- Main Entry Point
--------------------------------------------------------------------------------

--[[
	Creates and initializes an AbilityManager runner for the given character.

	@param character   The player's character Model
	@return            The initialized AbilityManager runner
]]
local function initializeCharacter(character: Model)
	-- TODO: listen to Character changed and correctly handle input ownership changes
	local player = Players:GetPlayerFromCharacter(character)

	local controllerManager = character:WaitForChild("ControllerManager", 10) :: ControllerManager
	local humanoid = character:WaitForChild("Humanoid", 10) :: Humanoid

	if not controllerManager or not humanoid then
		error("Character added without ControllerManager or Humanoid")
	end

	-- Resolve InputActions from the character's AbilityManagerInput context
	local inputContext = character:WaitForChild("AbilityManagerInput", 10)
	if not inputContext then
		error(`Failed to resolve InputActions for {character.Name}: AbilityManagerInput not found`)
	end
	local inputActions = {
		Move = inputContext:WaitForChild("Move"),
		Look = inputContext:WaitForChild("Look"),
		Jump = inputContext:WaitForChild("Jump"),
		Sprint = inputContext:WaitForChild("Sprint"),
		Crouch = inputContext:WaitForChild("Crouch"),
		Strafe = inputContext:WaitForChild("Strafe"),
	}

	-- Create runner and bind step loop (shared code, mode-aware)
	local runner = SharedSimulation.createRunner(character, controllerManager, humanoid, inputActions)

	if AuthorityConfig.isServerAuth or not AuthorityConfig.isServer then
		SharedSimulation.createUpdateLoop(runner, inputActions)
	end

	-- Client-only setup
	local localPlayer = Players.LocalPlayer
	local isLocalPlayer = localPlayer and player == localPlayer
	if isClient then
		-- Feed camera LookVector into the Look InputAction each frame so
		-- abilities always have the current camera direction.
		if isLocalPlayer then
			local camera = workspace.CurrentCamera
			local lookAction = inputActions.Look
			RunService.RenderStepped:Connect(function()
				lookAction:Fire(camera.CFrame.LookVector)
			end)
		end
	end

	-- Automatically connect humanoid shim if there is a Humanoid
	if humanoid then
		if
			(AuthorityConfig.isClient and isLocalPlayer) or (AuthorityConfig.isServerAuth and AuthorityConfig.isServer)
		then
			connectHumanoidShim(character, runner)
		end
	end
end

return initializeCharacter
