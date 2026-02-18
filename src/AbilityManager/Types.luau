--# selene: allow(unused_variable)

--[=[
	Types
	-----
	Public-facing type annotations for the AbilityManager system.
	These types define the contract for defining Abilities, interacting with the Manager,
	and handling state transitions.
]=]

--[=[
    The base context provided to all ability callbacks.
    Contains stable references to the Character and its core components.
    This remains consistent throughout the character's life.
]=]
export type BaseContext = {
	-- The instance (usually a Model) that owns this AbilityManager.
	abilityOwner: Instance,
	-- The AbilityManager instance controlling this character.
	abilityManager: AbilityManager,
	-- The ControllerManager instance for physics control (if present).
	controllerManager: ControllerManager?,
	-- The Humanoid instance (if present).
	humanoid: Humanoid?,
	-- The PrimaryPart or HumanoidRootPart of the character.
	rootPart: BasePart?,
	-- Additional user-defined data injected during creation.
	[any]: any,
}

--[=[
    The frame-specific context provided to Step and Test callbacks.
    Contains volatile data that changes every frame, such as delta time,
    input vectors, and world-space physics data.
]=]
export type FrameContext = {
	-- The time elapsed since the last frame (in seconds).
	deltaTime: number,
	-- Calculated 2D input from the input action (e.g. Thumbstick or WASD).
	move2d: Vector2,
	-- Calculated 3D world-space movement vector.
	move3d: Vector3,
	-- Current look direction vector (e.g. Camera LookVector).
	look: Vector3,
	-- Current World CFrame of the character's RootPart.
	rootCFrame: CFrame,
	-- Current World Position of the character's RootPart.
	rootPos: Vector3,
	-- Current LookVector of the character's RootPart.
	rootLook: Vector3,
	-- Current UpVector of the character's RootPart.
	rootUp: Vector3,
	-- Additional user-defined per-frame data.
	[any]: any,
}

--[=[
	Augmented State
	---------------
	The single state table passed to every ability callback.
	The engine injects `Config` and `Synced` at bind time.
	All other keys are ephemeral (local to this ability instance, never replicated).

	- Config:  Read-only. PascalCase keys merged from DefaultConfig + DataModel attributes.
	           Frozen at bind time. Tunable via the Explorer without code changes.
	- Synced:  Read-write. camelCase keys backed by a dirty-tracking proxy.
	           Flushed to DataModel attributes at the end of each Step (replicated).
	- *:       Anything else you write (e.g. `state.myTimer = 0`) lives only in memory.
	           Use for scratch data, cached references, or frame-local bookkeeping.
]=]
export type AbilityState = {
	Config: { [string]: any }?,
	Synced: { [string]: any }?,
	[any]: any,
}

-- A teardown function returned by a subscribe callback. Called when the sensor is removed.
export type Cleanup = () -> ()

--[=[
	Sensor Mode
	-----------
	Determines how the engine polls and reads a sensor.
	
	- "Polled": Read every frame. Use for sensors that change silently
	  without events (e.g., GroundSensor, TippedSensor).
	
	- "Reactive": Wakes the engine via subscribe, read on demand.
	  Use for input sensors with signals (e.g., JumpInput, MoveInput).
	
	- "Lazy": Only read when the logic tree reaches it.
	  Use for expensive calculations that are rarely needed (e.g., CoyoteTime).
]=]
export type SensorMode = "Polled" | "Reactive" | "Lazy"

--[=[
	Options for registering a sensor.
]=]
export type SensorOptions = {
	-- The evaluation mode. Defaults to "Reactive" if subscribe is provided, "Lazy" otherwise.
	mode: SensorMode?,
	-- Subscribe function that wakes the engine when the sensor might have changed.
	subscribe: ((wake: () -> ()) -> Cleanup)?,
	threshold: number?,
	defaultConfig: { [string]: any }?,
}

--[=[
	Logic system
	------------
	Defines the shape of logic expressions used for rule fields
	(RequiresToActivate, RequiresToContinue, BlocksWhileActive, CancelsOnActivation).
    
    Construct these using the API on the main AbilityManager module:
    - AbilityManager.Any(...)
    - AbilityManager.All(...)
    - AbilityManager.Not(...)

    Examples:
    1. Simple (Implicit ALL):
       RequiresToActivate = { "Walking", "Grounded" } 
       -- Must have BOTH Walking and Grounded.

    2. Alternatives (ANY / OR):
       RequiresToActivate = Any("Walking", "Running", "Sprinting")
       -- Succeeds if the character has ANY of these labels.

    3. Composite (ALL / AND):
       RequiresToActivate = All("Grounded", "StaminaAvailable")
       -- Succeeds only if the character has ALL of these labels.

    4. Exclusion (NOT):
       RequiresToActivate = Not("Stunned")
       -- Succeeds only if "Stunned" is NOT present.

    Constraints:
    - `Not` logic only supports simple Labels (Strings). You cannot wrap a Group (Any/All) inside a Not.
      Use De Morgan's laws manually: Not(A or B) -> All(Not(A), Not(B)).
]=]

export type Label = string

-- Logic Group (Any / All)
-- Holds a list of children rules to check.
export type RuleGroup = {
	type: "Any" | "All",
	children: { Rule }, -- A list of rules
}

-- Logic Invert (Not)
-- Wraps a single rule and inverts it.
export type RuleInvert = {
	type: "Not",
	child: Rule, -- A single rule
}

-- LogicExpr is a Union of those two shapes
export type LogicExpr = RuleGroup | RuleInvert

--[=[ 
	The recursive base unit for all Ability logic.
	
	It is a Union of:
	1. string: A simple label or the name of a registered sensor
	2. { Rule }: An Array of Rules (Implicit ALL / AND)
	3. RuleGroup: Explicit Any/All tree node
	4. RuleInvert: Explicit Not tree node
]=]
export type Rule = Label | { Rule } | LogicExpr

--[=[
    The blueprint for an Ability.
    This table defines the identity, rules, behavior, and lifecycle callbacks of an ability.
]=]
export type AbilityDefinition = {
	-- The unique identifier for this ability (e.g. "Sprinting", "Jumping").
	Name: string,

	-- Defines mutual exclusion with other abilities.
	-- Only one ability in a group (e.g. "Locomotion") can be active at a time.
	-- If a new ability tries to start, the one with higher priority wins.
	-- EXCEPTION: If the new ability explicitly targets the current holder via
	-- CancelsOnActivation, it will win regardless of priority.
	ExclusiveGroup: { name: string, priority: number }?,

	-- Labels applied to the character while this ability is active (e.g. "Walking", "Grounded").
	-- Simple list: An ability "Possesses" labels, it does not evaluate them.
	Labels: { string }?,

	--[=[
        Prerequisite labels required to START (Global/Ability Level).
        The engine checks this when the ability attempts to activate.
        
        Logic supported
        Supports `Any`, `All`, and `Not` logic.
    ]=]
	RequiresToActivate: Rule?,

	--[=[
        Conditions required to keep the ability running (Global/Ability Level).
        If these fail while active, the ability is automatically deactivated.
        Checked every frame while the ability is active.
        
        Logic supported
        Supports `Any`, `All`, and `Not` logic.
        
        Example:
        RequiresToContinue = { "Grounded" }
        -- Ability will deactivate if the character leaves the ground.
    ]=]
	RequiresToContinue: Rule?,

	--[=[
		Labels that this ability actively prevents from starting.
		While this ability is active, no ability possessing these labels can start.
		
		Logic supported
		Supports `Not` logic (e.g., Not("Airborne")) and implicit OR lists.
		Does NOT support complex logic (Any/All) for performance reasons.
	]=]
	BlocksWhileActive: Rule?,

	-- Labels that this ability will aggressively cancel on start
	-- If a currently active ability has one of these labels it will be forced to stop
	CancelsOnActivation: Rule?,

	-- OnStep will ONLY run if one of these sensors has changed this frame.
	StepSensors: { string }?,

	-- Determines if the ability can sleep when its StepSensors haven't changed.
	-- If false, the ability's OnStep will run every frame while active (for timers, continuous physics).
	-- If true or nil (default), the ability can sleep when StepSensors are unchanged.
	CanSleep: boolean?,

	--[=[
		Default config values (PascalCase keys).
		Read-only to ability callbacks via state.Config.
	]=]
	DefaultConfig: { [string]: any }?,

	--[=[
		Default state values (camelCase keys).
		Read-write to callbacks via state.Synced.
	]=]
	DefaultState: { [string]: any }?,

	-- @deprecated Use DefaultConfig / DefaultState instead.
	DefaultSettings: { [string]: any }?,

	--[[
		Lifecycle Callbacks
		-------------------
		These functions define the behavior of the ability during its life cycle.
		
		Rules:
		1. DO NOT YIELD: These callbacks run synchronously within the AbilityManager's 
		   update loop or signal handlers. Yielding (e.g. `task.wait`, `WaitForChild`) 
		   will block the entire manager, break frame synchronization, and potentially 
		   cause recursion guard errors.
		   
		2. `OnStep` runs every single frame for every active ability.
		   Keep logic lightweight (O(1)). Avoid creating new instances or complex table 
		   allocations here.
		   
		3. The `frameCtx` table is pooled and reused by the engine every frame to prevent GC churn. 
		   Do not store a reference to `frameCtx` or pass it to an asynchronous thread. 
		   If you need to save data from it, copy the specific values into `state`.
		   
		4. Do not store data on the ModuleScript table itself. 
		   Always use the provided `state` table to ensure your ability works correctly 
		   if multiple characters use it simultaneously.
	]]

	-- Called once when the ability is added to the manager.
	-- Use this for initialization, state, connect events, or fetch dependencies.
	OnSetup: ((baseCtx: BaseContext, state: AbilityState) -> ())?,

	-- Called when the ability successfully starts.
	-- `frameCtx` contains per-frame data (dt, inputs, physics).
	OnActivate: ((baseCtx: BaseContext, frameCtx: FrameContext, state: AbilityState) -> ())?,

	-- Called when the ability stops (either voluntarily or forced by another ability).
	OnDeactivate: ((baseCtx: BaseContext, frameCtx: FrameContext, state: AbilityState) -> ())?,

	-- Called every frame while the ability is active.
	-- Use this for continuous logic (e.g. applying movement, updating meters).
	OnStep: ((baseCtx: BaseContext, frameCtx: FrameContext, state: AbilityState) -> ())?,

	-- Called when the ability is removed or the manager is destroyed.
	-- Cleanup all connections and instances here.
	OnTeardown: ((baseCtx: BaseContext, state: AbilityState) -> ())?,
}

-- Handle returned by Signal:Connect. Used to disconnect the listener.
export type SignalConnection = {
	Disconnect: (self: SignalConnection) -> (),
	Connected: boolean,
}

--[=[
    The main interface for the Ability System.
    Manages the registration, execution, and query of abilities on a target.
]=]
export type AbilityManager = {
	-- Exposed BaseContext (Used by initializeClient)
	_baseContext: BaseContext,

	Owner: Instance,

	-- Adds the new ability `definition` to the manager.
	AddAbility: (self: AbilityManager, definition: AbilityDefinition) -> (),

	-- Removes an ability by `name`, stopping it if active and triggering OnTeardown.
	RemoveAbility: (self: AbilityManager, name: string) -> (),

	-- The main heartbeat of the system. MUST be called every frame (e.g. PreSimulation).
	-- `frameCtx` is a table of per-frame data passed to OnStep/Test callbacks.
	Step: (self: AbilityManager, frameCtx: FrameContext) -> (),

	-- Cleans up the manager, stopping all abilities and clearing references.
	Destroy: (self: AbilityManager) -> (),

	-- Attempts to start the ability `name`.
	-- Forces evaluation of the ability's activation requirements.
	-- If requirements pass and conflicts resolve, the ability activates.
	-- NOTE: Uses the FrameContext from the most recent Step(). Sensor getters
	-- that read per-frame data may receive stale/nil context when called outside Step.
	ActivateAbility: (self: AbilityManager, name: string) -> (),

	-- Stops the active ability `name`.
	DeactivateAbility: (self: AbilityManager, name: string) -> (),

	-- Enables or disables ability `name` completely.
	-- Disabled abilities cannot be activated.
	SetAbilityEnabled: (self: AbilityManager, name: string, enabled: boolean) -> (),

	-- Retrieves the definition of ability `name`, or `nil` if not found.
	GetAbility: (self: AbilityManager, name: string) -> AbilityDefinition?,

	-- Checks if ability `name` is currently running.
	IsAbilityActive: (self: AbilityManager, name: string) -> boolean,

	-- Checks if ability `name` is enabled (allowed to run).
	IsAbilityEnabled: (self: AbilityManager, name: string) -> boolean,

	-- Checks if the ability could potentially activate right now (Prereqs met, not blocked).
	-- NOTE: Uses the FrameContext from the most recent Step(). Sensor-dependent checks
	-- may be inaccurate outside Step; label-only checks are always accurate.
	CanActivateAbility: (self: AbilityManager, name: string) -> boolean,

	-- Returns a list of all registered abilities.
	GetAbilities: (self: AbilityManager) -> { AbilityDefinition },

	-- Returns a list of all currently active abilities.
	GetActiveAbilities: (self: AbilityManager) -> { AbilityDefinition },

	-- Returns the timestamp (from `time()`) when `abilityName` last successfully started.
	GetTimeWhenAbilityLastActivated: (self: AbilityManager, abilityName: string) -> number?,

	-- Returns the timestamp (from `time()`) when `abilityName` last stopped.
	GetTimeWhenAbilityLastDeactivated: (self: AbilityManager, abilityName: string) -> number?,

	--[=[
		Registers a sensor with the manager.
		
		Three patterns:
		
		-- Lazy (default, safest)
		AddSensor("CoyoteTime", getter)
		
		-- Polled (explicit opt-in)
		AddSensor("GroundSensor", getter, { mode = "Polled" })
		
		-- Reactive (has subscribe)
		AddSensor("JumpInput", getter, { mode = "Reactive", subscribe = fn })
		
		-- Event only (discrete)
		AddSensor("JumpPressed", Event(function(fire)
			local conn = jumpAction.Pressed:Connect(fire)
			return function() conn:Disconnect() end
		end))
	]=]
	AddSensor: (self: AbilityManager, name: string, getterOrEvent: any, options: SensorOptions?) -> (),

	-- Removes the registered sensor by name.
	RemoveSensor: (self: AbilityManager, name: string) -> (),

	-- Retrieves the current value of the sensor `name`.
	-- The result is cached for the current frame.
	-- NOTE: Outside Step(), the sensor getter receives stale or nil FrameContext.
	-- Getters that read per-frame fields (deltaTime, move vectors) may return incorrect values.
	GetSensor: (self: AbilityManager, name: string) -> any,

	GetState: (self: AbilityManager, abilityName: string) -> AbilityState?,

	-- @deprecated Use state proxy (the `state` callback parameter) instead.
	-- Gets a runtime setting value `settingName` for `abilityName`.
	GetSetting: (self: AbilityManager, abilityName: string, settingName: string) -> any,

	-- @deprecated Use state proxy (the `state` callback parameter) instead.
	-- Updates a runtime setting `settingName` for `abilityName` to `value`.
	SetSetting: (self: AbilityManager, abilityName: string, settingName: string, value: any) -> (),

	-- Event fired when an ability starts. Passes the `AbilityDefinition`.
	AbilityActivated: { Connect: (any, (AbilityDefinition) -> ()) -> SignalConnection },

	-- Event fired when an ability stops. Passes the `AbilityDefinition`.
	AbilityDeactivated: { Connect: (any, (AbilityDefinition) -> ()) -> SignalConnection },

	-- Event fired when an ability is added to the manager. Passes the `AbilityDefinition`.
	AbilityAdded: { Connect: (any, (AbilityDefinition) -> ()) -> SignalConnection },

	-- Event fired when an ability is removed from the manager. Passes the `AbilityDefinition`.
	AbilityRemoved: { Connect: (any, (AbilityDefinition) -> ()) -> SignalConnection },

	-- Event fired when the manager enters or exits the sleep state. Passes a boolean (isSleeping).
	SleepStateChanged: { Connect: (any, (boolean) -> ()) -> SignalConnection },
}

return {}
