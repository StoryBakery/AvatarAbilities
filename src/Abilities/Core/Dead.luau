--!native

--[[ 
  Dead Ability for Avatars
  A terminal state that triggers on Humanoid death, immediately canceling 
  all other Abilities and establishing final collision rules.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local AbilityManager = require("../../AbilityManager")
local AvatarBodyParts = require("../../Utility/AvatarBodyParts")
local DeathUtil = require("../../Utility/DeathUtil")

local Not = AbilityManager.Not

-- Forward declaration (defined at bottom of file)
local DeadSensor

-- Data shared by Dead's sensor methods
type DeadSensorData = {
	isDead: Boolean,
	humanoid: Humanoid,
	character: Instance,
	-- Body parts involved in neck detection
	head: Instance?,
	torso: Instance?,
	-- True if the character had a neck when last checked
	hadNeck: boolean,
	-- To be evoked upon the character dying
	diedCallback: NotifyCallback?,

	-- Listener for when an instance is childed to the character
	addChildEvent: RBXScriptConnection?,
	healthChangeListener: RBXScriptConnection,
	maxHealthChangeListener: RBXScriptConnection,
	-- Listener for when the character's PrimaryPart property changes
	primaryPartChangeListener: RBXScriptConnection?,
	-- Listener for when the neck's "enabled" property changes
	neckEnabledChangedListener: RBXScriptConnection,
	-- Listeners for detecting if the structure of the neck changes
	neckPart0Changed: RBXScriptConnection?,
	neckPart1Changed: RBXScriptConnection?,
	neckParentChanged: RBXScriptConnection?,
}

local DeadAbility: AbilityManager.AbilityDefinition = {
	Name = "Dead",
	Labels = { "dead" },

	RequiresToActivate = { "DeadSensor" }, -- activates the instant Humanoid.Died fires
	RequiresToContinue = {},
	BlocksWhileActive = { Not("dead") }, -- block all future Abilities from running while dead
	CancelsOnActivation = { Not("dead") }, -- cancel everything currently active that isn't "dead"

	DefaultConfig = {
		MaxHealth = 100,
		Health = 100,
	},
}

---------- Sensor Helpers ----------

-- Sets the character as dead
local function setAsDead(deadData: DeadSensorData)
	if deadData.isDead then
		return
	end
	deadData.isDead = true
	if deadData.diedCallback then
		deadData.diedCallback()
	end
end

-- Function forward declaration
local neckCheck

-- Locate the character's neck, if it has one. This only works for R15
-- characters
local function initNeck(deadData: DeadSensorData)
	local character: Instance = deadData.character

	deadData.head = character:FindFirstChild("Head")
	deadData.torso = character:FindFirstChild("UpperTorso") or character:FindFirstChild("Torso")
	local head: Instance = deadData.head
	local torso: Instance = deadData.torso
	if not torso or not head then
		if deadData.hadNeck then
			setAsDead(deadData)
		end
		return
	end

	-- This logic is designed to cover a few specific cases
	-- * A standard avatar with a Motor6D or AnimationConstraint neck should
	--  live.
	-- * A standard avatar whose neck has been removed should die even if a
	--  BallSocketConstraint neck joint exists.
	-- * A ragdolling avatar whose neck Motor6D or AnimationConstraint exists
	--  but has been set Enabled = false should live
	local foundNeck: boolean = false
	for _, descendant in deadData.head:GetDescendants() do
		if neckCheck(deadData, descendant) then
			foundNeck = true
			break
		end
	end
	if not foundNeck and deadData.hadNeck then
		setAsDead(deadData)
	elseif not foundNeck and not deadData.addChildEvent then
		-- Check for a neck connection getting defined whenever an instance is
		-- added to the character
		deadData.addChildEvent = character.ChildAdded:Connect(function(child)
			neckCheck(deadData, child)
		end)
	end
	deadData.hadNeck = foundNeck
end

-- Returns true if checkPart forms a connection between head and torso.
neckCheck = function(deadData: DeadSensorData, checkPart: Instance): boolean
	local head: Instance = deadData.head
	local torso: Instance = deadData.torso
	local part0: Instance?, part1: Instance?
	local connection0: Instance?, connection1: Instance?
	if checkPart:IsA("JointInstance") then
		connection0 = checkPart
		connection1 = checkPart
		part0 = checkPart.Part0
		part1 = checkPart.Part1
	elseif checkPart:IsA("AnimationConstraint") then
		connection0 = checkPart.Attachment0
		connection1 = checkPart.Attachment1
		if connection0 then
			part0 = connection0.Parent
		end
		if connection1 then
			part1 = connection1.Parent
		end
	else
		return false
	end
	local neckIsConnected: boolean = checkPart.Enabled
		and ((part0 == head and part1 == torso) or (part0 == torso and part1 == head))
	if neckIsConnected then
		-- React if the connection breaks
		assert(connection0, "")
		assert(connection1, "")
		local function neckChangedCallback()
			if deadData.neckPart0Changed then
				deadData.neckPart0Changed:Disconnect()
			end
			if deadData.neckPart1Changed then
				deadData.neckPart1Changed:Disconnect()
			end
			if deadData.neckParentChanged then
				deadData.neckParentChanged:Disconnect()
			end
			-- Check to see if a new neck connection exists
			initNeck(deadData)
		end
		deadData.neckEnabledChangedListener = checkPart:GetPropertyChangedSignal("Enabled"):Connect(function()
			neckChangedCallback()
		end)
		if checkPart:IsA("JointInstance") then
			deadData.neckPart0Changed = checkPart:GetPropertyChangedSignal("Part0"):Connect(function()
				neckChangedCallback()
			end)
			deadData.neckPart1Changed = checkPart:GetPropertyChangedSignal("Part1"):Connect(function()
				neckChangedCallback()
			end)
		elseif checkPart:IsA("AnimationConstraint") then
			deadData.neckPart0Changed = checkPart:GetPropertyChangedSignal("Attachment0"):Connect(function()
				neckChangedCallback()
			end)
			deadData.neckPart1Changed = checkPart:GetPropertyChangedSignal("Attachment1"):Connect(function()
				neckChangedCallback()
			end)
		end
		connection0.Destroying:Connect(neckChangedCallback)
		connection1.Destroying:Connect(neckChangedCallback)
		deadData.neckParentChanged = checkPart:GetPropertyChangedSignal("Parent"):Connect(function()
			neckChangedCallback()
		end)
	end
	return neckIsConnected
end

local function checkHealth(deadData: DeadSensorData, state: AbilityManager.AbilityState)
	if (not deadData.isDead) and (state.Config.Health <= 0) then
		setAsDead(deadData)
	end
end

---------- Lifecycle Methods ----------

function DeadAbility.OnSetup(baseCtx: AbilityManager.BaseContext, state: AbilityManager.AbilityState)
	local manager = baseCtx.abilityManager

	-- Register Ability-specific sensors
	manager:AddSensor(DeadSensor(manager, state))
end

function DeadAbility.OnActivate(
	baseCtx: AbilityManager.BaseContext,
	_frameCtx: AbilityManager.FrameContext,
	state: AbilityManager.AbilityState
)
	local character: Instance = baseCtx.abilityOwner
	if RunService:IsServer() then
		-- NPC
		state.NpcDeadDoneCleanup = DeathUtil.maintainCharacterAsDeadOnServer(character)
	else
		-- Player
		local deadEvent: RemoteEvent = ReplicatedStorage:FindFirstChild(DeathUtil.CONSTS.DEAD_EVENT_INSTANCE_NAME)
		assert(deadEvent, "DeadRemoteEvent is missing from the Dead ability package.")
		deadEvent:FireServer(character)
	end

	-- The client does not start the BreakJointsOnDeath process. Because doing
	-- so would cause the broken bodyparts to freeze mid physics due to the
	-- server taking ownership. Instead, BreakJointsOnDeath will initiate on
	-- the server.
	--	DeathUtil.setCharacterModelAsDead(character)

	AvatarBodyParts.SetLimbsCollide(character, true)
	AvatarBodyParts.SetTorsoCollide(character, true)
end

function DeadAbility.OnDeactivate(
	_baseCtx: AbilityManager.BaseContext,
	_frameCtx: AbilityManager.FrameContext,
	state: AbilityManager.AbilityState
)
	-- Players: Dead does not deactivate unless the character is destroyed.
	-- NPCs: It is possible that an NPC Dead might deactivate if the
	-- active ability were disabled.
	if state.NpcDeadDoneCleanup then
		state.NpcDeadDoneCleanup()
	end
end

function DeadAbility.OnTeardown(_baseCtx: AbilityManager.BaseContext, state: AbilityManager.AbilityState)
	-- Prevent listener memory leaks
	if state.NpcDeadDoneCleanup then
		state.NpcDeadDoneCleanup()
	end
end

---------- Sensors ----------

-- DeadSensor: Event-based, fires when humanoid dies
function DeadSensor(manager: AbilityManager.AbilityManager, state: AbilityManager.AbilityState)
	local character: Instance = manager.Owner
	local humanoid = manager._baseContext.humanoid
	local abilities = character:FindFirstChild("AbilityManagerActor").Abilities
	local deadAbility = abilities:FindFirstChild(DeadAbility.Name)

	-- Initialize sensor data
	local deadData: DeadSensorData
	deadData = {
		isDead = false,
		humanoid = humanoid,
		character = character,
		head = nil,
		torso = nil,
		hadNeck = false,
		addChildEvent = nil,
		diedCallback = nil,
		healthChangeListener = deadAbility:GetAttributeChangedSignal("Health"):Connect(function()
			if state.Config.Health > deadAbility:GetAttribute("MaxHealth") then
				deadAbility:SetAttribute("Health", deadAbility:GetAttribute("MaxHealth"))
			end
			checkHealth(deadData, state)
		end),
		maxHealthChangeListener = deadAbility:GetAttributeChangedSignal("MaxHealth"):Connect(function()
			if state.Config.Health > deadAbility:GetAttribute("MaxHealth") then
				deadAbility:SetAttribute("Health", deadAbility:GetAttribute("MaxHealth"))
			end
		end),
		primaryPartChangeListener = if character:IsA("Model")
			then character:GetPropertyChangedSignal("PrimaryPart"):Connect(function()
				if not character.PrimaryPart then
					-- This condition can be reached if a character fell
					-- out-of-bounds
					setAsDead(deadData)
				end
			end)
			else nil,
		neckPart0Changed = nil,
		neckPart1Changed = nil,
		neckParentChanged = nil,
	}
	-- This will properly initialize deadData.hadNeck
	initNeck(deadData)
	checkHealth(deadData, state)

	return "DeadSensor",
		function()
			return deadData.isDead
		end,
		{
			mode = "Reactive",
			subscribe = function(wake)
				if not humanoid or deadData.isDead then
					-- No humanoid or already dead, nothing to subscribe to
					return function() end
				end
				deadData.diedCallback = wake

				local connection = humanoid.Died:Connect(function()
					setAsDead(deadData)
				end)

				return function()
					connection:Disconnect()
					if deadData.healthChangeListener then
						deadData.healthChangeListener:Destroy()
					end
					if deadData.maxHealthChangeListener then
						deadData.maxHealthChangeListener:Destroy()
					end
					if deadData.addChildEvent then
						deadData.addChildEvent:Disconnect()
					end
					if deadData.primaryPartChangeListener then
						deadData.primaryPartChangeListener:Disconnect()
					end
					if deadData.neckEnabledChangedListener then
						deadData.neckEnabledChangedListener:Disconnect()
					end
					if deadData.neckPart0Changed then
						deadData.neckPart0Changed:Disconnect()
					end
					if deadData.neckPart1Changed then
						deadData.neckPart1Changed:Disconnect()
					end
					if deadData.neckParentChanged then
						deadData.neckParentChanged:Disconnect()
					end
				end
			end,
		}
end

return DeadAbility
