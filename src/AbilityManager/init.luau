--[[
    AbilityManager Root Module
    --------------------------
    Provides factory and lookup functions for AbilityManager instances.
    Each Instance that requires abilities will have a single associated manager.
]]

local AbilityManagerInstance = require("@self/AbilityManagerInstance")
local DataModelBinding = require("@self/DataModelBinding")
local SensorManager = require("@self/SensorManager")
local Types = require("@self/Types")

-- Export public-facing types
export type AbilityManager = Types.AbilityManager
export type AbilityDefinition = Types.AbilityDefinition
export type BaseContext = Types.BaseContext
export type FrameContext = Types.FrameContext
export type AbilityState = Types.AbilityState
export type Rule = Types.Rule
export type AuthorityMode = DataModelBinding.AuthorityMode

-- Stores all active AbilityManager instances, keyed by their target Instance
local allAbilitiesRunners: { [Instance]: Types.AbilityManager } = {}

-- Stores cleanup connections for runners to prevent memory leaks if destroyed manually
local runnerConnections: { [Types.AbilityManager]: RBXScriptConnection } = {}

-- Retrieves an AbilityManager for the given Instance, if it exists
local function getAbilitiesRunner(object: Instance): Types.AbilityManager?
	return allAbilitiesRunners[object]
end

-- Destroys and removes an existing AbilityManager for the given Instance
local function destroyRunner(object: Instance)
	local runner = allAbilitiesRunners[object]
	if runner then
		-- Disconnect the ancestry listener if it exists
		if runnerConnections[runner] then
			runnerConnections[runner]:Disconnect()
			runnerConnections[runner] = nil
		end

		runner:Destroy()
		allAbilitiesRunners[object] = nil
	end
end

local function createRunner(
	object: Instance,
	context: Types.BaseContext?,
	authorityMode: DataModelBinding.AuthorityMode?
): Types.AbilityManager
	if allAbilitiesRunners[object] then
		warn("AbilityManager: Runner already exists for", object)
		return allAbilitiesRunners[object]
	end

	local baseContext = context or {}

	-- Inject abilityOwner BEFORE construction so it's available during initialization.
	-- abilityManager must be injected after construction due to circular dependency.
	baseContext.abilityOwner = object

	local newRunner = AbilityManagerInstance.new(object, baseContext, authorityMode)
	allAbilitiesRunners[object] = newRunner

	-- Inject abilityManager reference (circular dependency resolved post-construction)
	baseContext.abilityManager = newRunner

	local function updateGroundRaycastDistance(controllerManager: ControllerManager)
		local rootPart = controllerManager.RootPart
		if not rootPart then
			return
		end

		local partSize = rootPart.Size.Y
		local groundControllerOffset = controllerManager.GroundController.GroundOffset

		-- TODO: hysteresis? As we fall faster we increase the ray length.
		-- This should likely be done by the Freefall ability.

		controllerManager.GroundSensor.SearchDistance = 1.0 * partSize + groundControllerOffset
	end

	object:WaitForChild("HumanoidRootPart")
	if baseContext.controllerManager then
		-- update ground sensor raycast search distance based on hip height
		updateGroundRaycastDistance(baseContext.controllerManager)
	end

	-- Automatically destroy the manager when the Instance is removed from the game
	-- Track this connection in 'runnerConnections' so destroyRunner can remove it
	local ancestryChangedConnection
	ancestryChangedConnection = object.AncestryChanged:Connect(function()
		if object:IsDescendantOf(game) then
			return
		end
		-- The connection disconnects itself here, so we remove the reference from our tracking table
		ancestryChangedConnection:Disconnect()
		if runnerConnections[newRunner] == ancestryChangedConnection then
			runnerConnections[newRunner] = nil
		end
		destroyRunner(object)
	end)

	runnerConnections[newRunner] = ancestryChangedConnection

	return newRunner
end

local function Initialize(
	object: Instance,
	context: Types.BaseContext?,
	authorityMode: DataModelBinding.AuthorityMode?
): Types.AbilityManager
	return createRunner(object, context, authorityMode)
end

-- Logic API helpers
-- These allow abilities to define rules like: RequiresToActivate = AbilityManager.Any("A", "B")
local function Any(...: Types.Rule): Types.LogicExpr
	return { type = "Any", children = { ... } }
end

local function All(...: Types.Rule): Types.LogicExpr
	return { type = "All", children = { ... } }
end

local function Not(rule: Types.Rule): Types.LogicExpr
	return { type = "Not", child = rule }
end

return {
	-- Primary entry point
	Initialize = Initialize,

	-- Legacy aliases
	createRunner = createRunner,
	destroyRunner = destroyRunner,
	getAbilitiesRunner = getAbilitiesRunner,

	-- Logic API
	Any = Any,
	All = All,
	Not = Not,

	-- Sensor API
	Event = SensorManager.Event,
}
