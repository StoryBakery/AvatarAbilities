--[[
	connectHumanoidShim
	===================
	Bridges AbilityManager ability state to Humanoid animation state.
	Works on BOTH client and server. Single source of truth for AbilityStateMap.

	Mode behavior:
	  None:      Client sets humanoid state + fires RemoteEvent to sync server.
	  Automatic: Client sets humanoid state + fires RemoteEvent to sync server.
	             (Same as None — client still owns character.)
	  Server:    Both sides set humanoid state directly.
	             Client does so for animation prediction.
	             Server does so authoritatively (replaces the RemoteEvent path).
	             RemoteEvent is NOT fired.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local StarterPlayer = game:GetService("StarterPlayer")

local AbilityManager = require("./AbilityManager")
local AuthorityConfig = require("./AuthorityConfig")
local FreefallAbility = require("./Abilities/Core/Freefall")
local RunningAbility = require("./Abilities/Core/Running")

local isClient = RunService:IsClient()

local CONSTS = {
	-- Number of seconds which the LANDED humanoid state is to be active.
	LANDED_TIMER = 0.05,
}
table.freeze(CONSTS)

-- Single source of truth for ability-name → Humanoid state mapping.
-- Used on both client and server (eliminates duplicate in initializeServerCharacter).
local AbilityStateMap = {
	["Climbing"] = Enum.HumanoidStateType.Climbing,
	["Dead"] = Enum.HumanoidStateType.Dead,
	["Freefall"] = Enum.HumanoidStateType.Freefall,
	["GettingUp"] = Enum.HumanoidStateType.GettingUp,
	["Jumping"] = Enum.HumanoidStateType.Jumping,
	["Swimming"] = Enum.HumanoidStateType.Swimming,
	["FallingDown"] = Enum.HumanoidStateType.FallingDown,
	["Running"] = Enum.HumanoidStateType.Running,
	["Sitting"] = Enum.HumanoidStateType.Seated,
	["LegacyPlatformStand"] = Enum.HumanoidStateType.PlatformStanding,
}

-- TODO: Pull in HumanoidReadyUtil from ragdoll CoreScripts; better edge case handling
local function waitForHumanoid(character: Model): Humanoid
	local humanoid: Humanoid? = character:FindFirstChildWhichIsA("Humanoid")
	while not humanoid do
		character.ChildAdded:Wait()
		humanoid = character:FindFirstChildWhichIsA("Humanoid")
	end
	return humanoid :: Humanoid
end

-- Transitions from Landed to Running, if able
local function endLanded(abilitiesRunner: AbilityManager.AbilityManager, humanoid: Humanoid)
	if
		humanoid:GetState() == Enum.HumanoidStateType.Landed and abilitiesRunner:IsAbilityActive(RunningAbility.Name)
	then
		humanoid:ChangeState(Enum.HumanoidStateType.Running)
	end
end

-- Client-only: For Click to Move support, relays Humanoid.MoveDirection to the Move InputAction
local clickToMoveConn = nil
local function updateClickToMoveAction(character: Model)
	local UserGameSettings = UserSettings():GetService("UserGameSettings")
	local humanoid = waitForHumanoid(character)
	local inputContext = character:WaitForChild("AbilityManagerInput", 10)
	local moveAction = inputContext and inputContext:WaitForChild("Move")

	if UserGameSettings.ComputerMovementMode == Enum.ComputerMovementMode.ClickToMove then
		clickToMoveConn = humanoid:GetPropertyChangedSignal("MoveDirection"):Connect(function()
			local moveDir = humanoid.MoveDirection
			local cf = game.Workspace.CurrentCamera.CFrame.Rotation:Inverse()
			local moveLocal = cf * moveDir * humanoid.WalkSpeed
			moveAction:Fire(Vector2.new(moveLocal.X, -moveLocal.Z))
		end)
	else
		if clickToMoveConn then
			clickToMoveConn:Disconnect()
			clickToMoveConn = nil
		end
	end
end

local function connectHumanoidShim(character: Model, abilitiesRunner: AbilityManager.AbilityManager)
	local humanoid = waitForHumanoid(character)

	-- Only resolve the RemoteEvent on the client in None/Automatic modes.
	-- In Server mode or on the server, no RemoteEvent is needed.
	local humanoidShimEvent = nil
	if isClient and not AuthorityConfig.isServerAuth then
		humanoidShimEvent = ReplicatedStorage:WaitForChild("HumanoidShimRemoteEvent", 10)
		if not humanoidShimEvent then
			warn("connectHumanoidShim timed out waiting for HumanoidShimRemoteEvent")
		end
	end

	-- Shim updates for Humanoid properties → AbilityManagerActor.Abilities attributes.
	local abilityManagerActor = character:FindFirstChild("AbilityManagerActor")
	if abilityManagerActor then
		local abilities = abilityManagerActor:FindFirstChild("Abilities")
		if abilities then
			-- Jumping properties
			local jumpingAbility = abilities:FindFirstChild("Jumping")
			if jumpingAbility then
				jumpingAbility:SetAttribute("JumpHeight", StarterPlayer.CharacterJumpHeight)
				jumpingAbility:SetAttribute("UseJumpPower", StarterPlayer.CharacterUseJumpPower)
				jumpingAbility:SetAttribute("JumpPower", StarterPlayer.CharacterJumpPower)
				humanoid:GetPropertyChangedSignal("JumpHeight"):Connect(function()
					jumpingAbility:SetAttribute("JumpHeight", humanoid.JumpHeight)
				end)
				humanoid:GetPropertyChangedSignal("UseJumpPower"):Connect(function()
					jumpingAbility:SetAttribute("UseJumpPower", humanoid.UseJumpPower)
				end)
				humanoid:GetPropertyChangedSignal("JumpPower"):Connect(function()
					jumpingAbility:SetAttribute("JumpPower", humanoid.JumpPower)
				end)
			end

			-- Running properties
			local runningAbilityInst = abilities:FindFirstChild("Running")
			if runningAbilityInst then
				humanoid:GetPropertyChangedSignal("MaxSlopeAngle"):Connect(function()
					runningAbilityInst:SetAttribute("MaxSlopeAngle", humanoid.MaxSlopeAngle)
				end)
			end

			-- RigType
			abilities:SetAttribute("RigType", humanoid.RigType)
			humanoid:GetPropertyChangedSignal("RigType"):Connect(function()
				abilities:SetAttribute("RigType", humanoid.RigType)
			end)

			-- Dead properties (Health)
			local deadAbility = abilities:FindFirstChild("Dead")
			if deadAbility then
				deadAbility:SetAttribute("MaxHealth", humanoid.MaxHealth)
				deadAbility:SetAttribute("Health", humanoid.Health)
				humanoid:GetPropertyChangedSignal("MaxHealth"):Connect(function()
					deadAbility:SetAttribute("MaxHealth", humanoid.MaxHealth)
				end)
				humanoid:GetPropertyChangedSignal("Health"):Connect(function()
					deadAbility:SetAttribute("Health", humanoid.Health)
				end)
			end
		end
	end

	-- Client-only: Track ComputerMovementMode for Click to Move support
	if isClient then
		local UserGameSettings = UserSettings():GetService("UserGameSettings")
		UserGameSettings:GetPropertyChangedSignal("ComputerMovementMode"):Connect(function()
			updateClickToMoveAction(character)
		end)
	end

	abilitiesRunner.AbilityActivated:Connect(function(ability: AbilityManager.AbilityDefinition)
		assert(abilitiesRunner, "")

		local humanoidState: Enum.HumanoidStateType = AbilityStateMap[ability.Name]

		-- Client-only: Landed state handling for Freefall → Running transitions.
		-- NOTE: task.delay is non-deterministic and won't replay on rollback.
		-- Acceptable because Landed is purely visual/animation state.
		if isClient then
			if
				abilitiesRunner:GetSetting(FreefallAbility.Name, FreefallAbility.CONSTS.SETTING_PROCESS_LANDED_STATE)
			then
				abilitiesRunner:SetSetting(
					FreefallAbility.Name,
					FreefallAbility.CONSTS.SETTING_PROCESS_LANDED_STATE,
					false
				)
				if RunningAbility.Name == ability.Name then
					humanoidState = Enum.HumanoidStateType.Landed

					local fallTimeEnded: number? =
						abilitiesRunner:GetTimeWhenAbilityLastDeactivated(FreefallAbility.Name)
					assert(fallTimeEnded, "")
					local timeSinceFreefallEnded: number = time() - fallTimeEnded
					if CONSTS.LANDED_TIMER < timeSinceFreefallEnded then
						timeSinceFreefallEnded = CONSTS.LANDED_TIMER
					end

					task.delay(CONSTS.LANDED_TIMER - timeSinceFreefallEnded, endLanded, abilitiesRunner, humanoid)
				end
			end
		end

		if humanoidState then
			-- Client-only: Workaround for seat weld clearing
			if isClient then
				local currentState = humanoid:GetState()
				if currentState == Enum.HumanoidStateType.Seated then
					local seat = humanoid.SeatPart
					if seat then
						for _, child in ipairs(seat:GetChildren()) do
							if child:IsA("Weld") and child.Part1 == humanoid.RootPart then
								child:Destroy()
								break
							end
						end
					end
				end
			end

			-- Both sides: set humanoid state.
			-- On client this drives animation. On server (SA) this is authoritative.
			humanoid:ChangeState(humanoidState)

			-- Client + None/Automatic: fire RemoteEvent to sync server humanoid state.
			-- Client + Server: skip — server runner handles this authoritatively.
			-- Server: never fires (humanoidShimEvent is nil).
			if humanoidShimEvent then
				humanoidShimEvent:FireServer(humanoidState)
			end
		end
	end)
end

return connectHumanoidShim
