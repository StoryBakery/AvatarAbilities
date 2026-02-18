--!native
--[=[
	AbilityManagerInstance
	===========================================================================
	The runtime engine for the Ability System.

	This module manages the lifecycle, state, and conflict resolution for all 
	abilities on a specific Character. It provides a deterministic, callback-safe 
	environment where abilities interact via a shared World Label Set.

	Activation Model
	---------------------------------------------------------------------------
	   Abilities with sensor requirements (RequiresToActivate) are evaluated continuously
	   by the engine if their labels are valid. Abilities without sensor requirements
	   are triggered only by external code (ActivateAbility).

	Key Concepts
	---------------------------------------------------------------------------
	World Label Set
	   A bitmask representing the aggregate state of all currently active abilities.
	   - On Activate: Adds ability Labels to the set
	   - On Stop: Rebuilds the set to ensure consistency

	Active Rules vs. Entry Rules
	   Active Rules:
	     Apply while the ability is active. These act as gatekeepers, affecting 
	     other abilities attempting to run.
	   Entry Rules:
	     Apply only when the ability attempts to start.

	---------------------------------------------------------------------------
	Exclusionary Logic (AbilityManager.Not)
	---------------------------------------------------------------------------
	The `AbilityManager.Not(...)` helper allows for exclusionary logic.
	
	Syntax:  `Not("A")`
	Meaning: "The world must NOT contain A" or 
	         "This ability must possess A to avoid being blocked."

	Examples:
	Prerequisite (RequiresToActivate)
	   Rule:        RequiresToActivate = Not("Stunned")
	   World State: { "Walking" } -> Success (Stunned is absent)
	   World State: { "Stunned" } -> Fail (Stunned is present)

	Gatekeeping (BlocksWhileActive)
	   Active Ability X: BlocksWhileActive = Not("Ghost")
	   Candidate Y:      Labels = { "Physical", "Ghost" } -> Success
	                     (Y has Ghost, satisfying the requirement)
	   Candidate Z:      Labels = { "Physical" } -> Blocked
	                     (Z missing Ghost, triggering the block)

	Sweeping (CancelsOnActivation)
	   Candidate X:      CancelsOnActivation = Not("Friendly")
	   Active Ability Y: Labels = { "Friendly" } -> Survives
	   Active Ability Z: Labels = { "Neutral" } -> Canceled

	Strict Gatekeeping (Multiple Not rules)
	   Rule:  BlocksWhileActive is an OR list. Any match blocks the candidate.
	   Setup: BlocksWhileActive = { Not("KeyCard"), Not("Biometrics") }
	   Logic: "Block if missing KeyCard OR if missing Biometrics" (Must have both).

	---------------------------------------------------------------------------
	Policies & Logic
	---------------------------------------------------------------------------

	Active Rules (apply while the ability is running)

	BlocksWhileActive (Gatekeeping)
	   Context:  Active Ability vs. Candidate
	   Logic:    Implicit OR List (Any match blocks the candidate)
	   Behavior: If Active X has `BlocksWhileActive: { A, B }`:
	             It blocks any Candidate Y if Y has label A or label B.
	   Use Case: "While I am 'Stunned', I block anything labeled 'Movement'."

	Entry Rules (apply when the ability attempts to start)

	RequiresToActivate (Prerequisite)
	   Context:  Candidate vs. World State
	   Logic:    Logic Rule (Supports Any / All / Not)
	   Behavior: Satisfied only if World State matches the logic requirements.

	CancelsOnActivation (Sweeping / Breakout)
	   Context:  Active Ability
	   Logic:    Implicit OR List
	   Behavior: If Candidate X activates, it forces the deactivation of any
	             Active Ability Y that matches any label in X's cancel list.
	   Note:     Defining this marks the ability as "Aggressive" (see below).
	   Use Case: "When I 'Dive', I cancel anything labeled 'Walking'."

	Aggressive Evaluation (Cancel Bypass)
	Standard candidates are rejected if they conflict with the Global Blocked Mask.
	However, candidates with `CancelsOnActivation` are marked as Aggressive.

	Behavior: Aggressive candidates bypass the initial Global Block check.
	Logic:    They proceed to detailed Conflict Resolution to verify if they 
	          specifically cancel the ability that is blocking them.
	Outcome:  
	  - If Candidate X cancels Blocker Y -> X wins (Y stops, X starts)
	  - If Candidate X does not cancel Blocker Y -> X is blocked

	---------------------------------------------------------------------------
	Exclusive Groups (Channels)
	---------------------------------------------------------------------------
	Behavior: Only one ability in a named group (e.g., "Locomotion") can be active.
	Policy:   If a Candidate enters an occupied group:
	          - Candidate Priority > Holder Priority -> Candidate Wins
	          - Candidate Priority <= Holder Priority -> Candidate Blocked
	Exception: If Candidate explicitly cancels the Holder via `CancelsOnActivation`,
	           it wins regardless of priority.

	---------------------------------------------------------------------------
	Execution Invariants
	---------------------------------------------------------------------------
	Determinism
	   Given the same state and inputs, the outcome is always identical.
	   Logic is executed instantly to resolve chains within a single frame.

	Signal Stability (Transactional Diff)
	   To prevent signal noise (flickering):
	   - Modification: First change creates a snapshot in a Dirty List
	   - Resolution: End of frame compares Final State vs Snapshot
	   - Result: Signals fire only if the net change is non-zero

	Hot Loop Safety (Cached Length)
	   The Step loop caches the number of active abilities at the start of the frame.
	   If an ability is activated during the loop, it is added to the list but
	   will not execute its OnStep logic until the next frame.

	State & Signal Timing
	   - State Updates: Immediate. When an ability starts, `IsAbilityActive` returns true
	     instantly. Conflicting abilities are deactivated BEFORE the new one starts.
	   - Signals: Deferred. All `Activated` and `Deactivated` events fire at the end
	     of the frame. Deactivation signals always fire before Activation signals.
]=]

local AbilityManagerInstance = {}

local AbilityCompiler = require("./AbilityCompiler")
local AbilityEngine = require("./AbilityEngine")
local AbilityLifecycle = require("./AbilityLifecycle")
local AbilityStateStore = require("./AbilityStateStore")
local AbilityUtils = require("./AbilityUtils")
local AbilityValidator = require("./AbilityValidator")
local DataModelBinding = require("./DataModelBinding")
local SensorManager = require("./SensorManager")
local Types = require("./Types")

-- Use numeric constants for pending actions to avoid string comparison overhead
local ACTION_ADD = 1
local ACTION_REMOVE = 2

-- Action types for the pending definitions queue
type AddAction = {
	type: number,
	def: Types.AbilityDefinition,
}

type RemoveAction = {
	type: number,
	name: string,
}

type PendingAction = AddAction | RemoveAction

function AbilityManagerInstance.new(
	owner: Instance,
	baseContext: Types.BaseContext,
	authorityMode: DataModelBinding.AuthorityMode?
)
	local publicInterface = {} :: Types.AbilityManager

	-- The physical instance (Character) this manager is controlling
	publicInterface.Owner = owner
	publicInterface._baseContext = baseContext

	-- Signals
	publicInterface.AbilityActivated = AbilityUtils.createSignal()
	publicInterface.AbilityDeactivated = AbilityUtils.createSignal()
	publicInterface.AbilityAdded = AbilityUtils.createSignal()
	publicInterface.AbilityRemoved = AbilityUtils.createSignal()
	publicInterface.SleepStateChanged = AbilityUtils.createSignal()

	-- Group internal signals to inject into the engine
	local engineSignals = {
		AbilityActivated = publicInterface.AbilityActivated,
		AbilityDeactivated = publicInterface.AbilityDeactivated,
		SleepStateChanged = publicInterface.SleepStateChanged,
	}

	-- Sub-system initialization
	local stateStore = AbilityStateStore.new()
	local sensorManager = SensorManager.new()

	-- Find Actor
	local actor = owner:FindFirstChild("AbilityManagerActor")
	-- Actor may not exist (AbilityManagerActor)

	-- Initialize DataModel Bindings
	if actor then
		sensorManager:BindToDataModel(actor)
	end

	local binding
	if actor then
		binding = DataModelBinding.new(owner, actor, stateStore, authorityMode)
	end

	local compiler = AbilityCompiler.new(sensorManager)
	local engine = AbilityEngine.new(stateStore, sensorManager, baseContext, engineSignals)

	local currentFrameContext = nil
	local inStep = false
	local isShuttingDown = false

	-- Queue for structural changes (Add/Remove) using Command Pattern
	local pendingDefinitions: { PendingAction } = {}

	local lifecycle = AbilityLifecycle.new(stateStore, baseContext, function()
		return currentFrameContext
	end)

	stateStore.AbilityEnabledChanged:Connect(function(name, enabled)
		local record = stateStore.RecordsByName[name]
		if record then
			-- If disabled while active, force stop
			if not enabled and record.IsActive then
				stateStore:SetAbilityActive(name, false)
			end
		end
	end)

	function publicInterface:Step(frameCtx: Types.FrameContext)
		-- Shutdown safety: Do not run step if we are destroying
		if isShuttingDown then
			return
		end

		-- Store the current frame context for sensor access
		currentFrameContext = frameCtx

		-- Crash recovery
		if inStep then
			warn("[AbilityManager] Recovered from a crash in previous frame.")
		end

		inStep = true

		-- SAuth: Reconcile from DataModel (Rollback handling)
		if binding then
			binding:ReconcileAll()
		end

		-- Process any pending structural changes from the previous frame.
		-- We must temporarily clear inStep so that AddAbility/RemoveAbility
		-- execute immediately rather than re-queuing into pendingDefinitions.
		if #pendingDefinitions > 0 then
			local pending = pendingDefinitions
			pendingDefinitions = {}

			inStep = false
			for i = 1, #pending do
				local action = pending[i]
				if action.type == ACTION_ADD then
					publicInterface:AddAbility((action :: AddAction).def)
				elseif action.type == ACTION_REMOVE then
					publicInterface:RemoveAbility((action :: RemoveAction).name)
				end
			end
			inStep = true
		end

		-- Run the engine step
		engine:Step(frameCtx)

		-- SAuth: Flush changes to DataModel
		if binding then
			binding:FlushAll()
		end

		inStep = false
	end

	function publicInterface:AddAbility(abilityDefinition: Types.AbilityDefinition)
		if isShuttingDown then
			return
		end

		-- If we are currently inside the Step loop, we cannot modify the ability list immediately.
		-- Queue this action to be processed at the start of the next Step.
		if inStep then
			local addAction: AddAction = {
				type = ACTION_ADD,
				def = abilityDefinition,
			}
			table.insert(pendingDefinitions, addAction)
			return
		end

		if stateStore.RecordsByName[abilityDefinition.Name] then
			warn(string.format("[AbilityManager] Ability '%s' already exists.", abilityDefinition.Name))
			return
		end

		local success, abilityRecord, errorMsg = compiler:Compile(owner, abilityDefinition, stateStore.RecordsByName)

		if not success then
			warn(string.format("[AbilityManager] Failed to compile '%s': %s", abilityDefinition.Name, errorMsg or ""))
			return
		end

		stateStore:AddAbility(abilityRecord)

		-- Bind to DataModel and build Augmented State
		local enabled
		if binding then
			local state
			state, enabled =
				binding:BindAbility(abilityRecord, abilityDefinition.DefaultConfig, abilityDefinition.DefaultState)
			-- Inject augmented state into record for Engine/Lifecycle
			abilityRecord._state = state
		else
			-- Fallback for tests/no-actor: build a minimal augmented state
			enabled = true
			local config = abilityDefinition.DefaultConfig or {}
			abilityRecord._state = {
				Config = if table.isfrozen(config) then config else table.freeze(config),
				Synced = abilityRecord.State,
			}
		end

		stateStore:SetAbilityEnabled(abilityDefinition.Name, enabled)

		if abilityDefinition.OnSetup then
			abilityDefinition.OnSetup(baseContext, abilityRecord._state)
		end

		-- Validate StepSensors after OnSetup
		local knownSensors = {}
		for name, sensor in sensorManager:GetSensors() do
			if not sensor.getter then
				knownSensors[name] = "Discrete"
			else
				knownSensors[name] = sensor.mode or "Lazy"
			end
		end
		local stepValid, stepErr = AbilityValidator.validateStepSensors(abilityDefinition, knownSensors)
		if not stepValid then
			warn(string.format("[AbilityManager] Failed to compile '%s': %s", abilityDefinition.Name, stepErr or ""))
			if abilityDefinition.OnTeardown then
				abilityDefinition.OnTeardown(baseContext, abilityRecord._state)
			end
			if binding then
				binding:UnbindAbility(abilityDefinition.Name)
			end
			stateStore:RemoveAbility(abilityDefinition.Name)
			return
		end

		publicInterface.AbilityAdded:Fire(abilityRecord.Definition)
	end

	function publicInterface:RemoveAbility(name: string)
		if isShuttingDown then
			return
		end

		if inStep then
			local removeAction: RemoveAction = {
				type = ACTION_REMOVE,
				name = name,
			}
			table.insert(pendingDefinitions, removeAction)
			return
		end

		local record = stateStore.RecordsByName[name]
		if not record then
			return
		end

		if record.IsActive then
			stateStore:SetAbilityActive(name, false)
		end

		stateStore:SetAbilityEnabled(name, false)

		if record.Definition.OnTeardown then
			local state = record._state or record.State
			local ok, err = pcall(record.Definition.OnTeardown, baseContext, state)
			if not ok then
				warn(string.format("[AbilityManager] Error in OnTeardown for '%s': %s", name, tostring(err)))
			end
		end

		if binding then
			binding:UnbindAbility(name)
		end
		stateStore:RemoveAbility(name)

		publicInterface.AbilityRemoved:Fire(record.Definition)
	end

	--[=[
		Attempts to start the ability `name`.
		Forces evaluation of the ability's activation requirements.
		If requirements pass and conflicts resolve, the ability activates.
		
		WARNING: This method uses the FrameContext from the most recent Step() call.
		Sensor getters that depend on per-frame data (deltaTime, move vectors, etc.)
		may receive stale or nil FrameContext when called outside the Step loop
		(e.g. from input event handlers). Label-only prerequisites are unaffected.
	]=]
	function publicInterface:ActivateAbility(name: string)
		if isShuttingDown then
			return
		end

		local record = stateStore.RecordsByName[name]
		if not record or record.IsActive then
			return
		end

		local passed = AbilityUtils.checkCompiled(
			record._compiledActivation,
			stateStore.Cache.ActiveMaskLo,
			stateStore.Cache.ActiveMaskHi,
			sensorManager,
			currentFrameContext
		)
		if passed then
			engine:_attemptResolutionAndStart(record)
		end
	end

	function publicInterface:DeactivateAbility(name: string)
		if isShuttingDown then
			return
		end

		local record = stateStore.RecordsByName[name]
		if record and record.IsActive then
			stateStore:SetAbilityActive(name, false)
		end
	end

	-- --------------------------------------------------------------------------------
	-- Sensor API
	-- --------------------------------------------------------------------------------

	--[=[ 
		Registers a new sensor.
		
		PERFORMANCE WARNING: 
		Calling this forces a recompilation of logic for ALL registered abilities. 
		This is necessary to resolve if string requirements in abilities refer to this new Sensor 
		or a standard Label.
	]=]
	function publicInterface:AddSensor(
		name: string,
		getterOrEvent: any,
		options: {
			mode: ("Polled" | "Reactive" | "Lazy")?,
			subscribe: ((wake: () -> ()) -> () -> ())?,
			threshold: number?,
			defaultConfig: { [string]: any }?,
		}?
	)
		if isShuttingDown then
			return
		end
		sensorManager:AddSensor(name, getterOrEvent, options)

		-- Recompile abilities when sensors are added (they might reference new sensors)
		for _, record in stateStore.RecordsByName do
			compiler:RefreshLogic(record)
		end

		-- Force engine to rebuild sensor lists next frame
		stateStore.Cache.Version += 1
	end

	function publicInterface:RemoveSensor(sensorName: string)
		sensorManager:RemoveSensor(sensorName)
		stateStore.Cache.Version += 1
	end

	--[=[
		Retrieves the current value of sensor `name`.
		The result is cached for the current frame.
		
		WARNING: Outside of the Step loop, the FrameContext passed to the sensor
		getter will be stale (from the previous Step) or nil (if Step has never
		run). Sensor getters that read per-frame fields (deltaTime, move vectors,
		rootCFrame, etc.) may return incorrect values in this case.
	]=]
	function publicInterface:GetSensor(name: string): any
		return sensorManager:GetSensor(name, currentFrameContext)
	end

	-- --------------------------------------------------------------------------------
	-- State Access API
	-- --------------------------------------------------------------------------------

	function publicInterface:GetState(abilityName: string): Types.AbilityState?
		local record = stateStore.RecordsByName[abilityName]
		return record and record._state
	end

	-- --------------------------------------------------------------------------------
	-- Delegation API
	-- --------------------------------------------------------------------------------

	function publicInterface:IsAbilityActive(name: string): boolean
		return stateStore.RecordsByName[name] and stateStore.RecordsByName[name].IsActive or false
	end

	function publicInterface:IsAbilityEnabled(name: string): boolean
		return stateStore.RecordsByName[name] and stateStore.RecordsByName[name].IsEnabled or false
	end

	function publicInterface:SetAbilityEnabled(name: string, enabled: boolean)
		if isShuttingDown then
			return
		end
		stateStore:SetAbilityEnabled(name, enabled)

		-- Sync to attribute if bound
		local record = stateStore.RecordsByName[name]
		if record and record.ConfigInstance then
			record.ConfigInstance:SetAttribute("Enabled", enabled)
		end
	end

	function publicInterface:GetAbility(name: string): Types.AbilityDefinition?
		return stateStore.RecordsByName[name] and stateStore.RecordsByName[name].Definition
	end

	function publicInterface:GetAbilities(): { Types.AbilityDefinition }
		local output = {}
		for _, abilityRecord in stateStore.RecordsByName do
			table.insert(output, abilityRecord.Definition)
		end
		return output
	end

	function publicInterface:GetActiveAbilities(): { Types.AbilityDefinition }
		return stateStore:GetActiveDefinitions()
	end

	function publicInterface:GetTimeWhenAbilityLastActivated(name: string): number?
		return stateStore.RecordsByName[name] and stateStore.RecordsByName[name].TimeLastActive
	end

	function publicInterface:GetTimeWhenAbilityLastDeactivated(name: string): number?
		return stateStore.RecordsByName[name] and stateStore.RecordsByName[name].TimeLastInactive
	end

	-- @deprecated Use state proxy (the `state` callback parameter) instead.
	function publicInterface:GetSetting(name: string, setting: string): any
		return stateStore:GetSetting(name, setting)
	end

	-- @deprecated Use state proxy (the `state` callback parameter) instead.
	function publicInterface:SetSetting(name: string, setting: string, value: any)
		stateStore:SetSetting(name, setting, value)
	end

	--[=[
		Returns true if the ability could activate right now (prerequisites met,
		not blocked, conflicts resolvable). Does not trigger side effects.
		
		WARNING: Sensor evaluation uses the FrameContext from the most recent
		Step() call. If called outside the Step loop (e.g. for UI queries),
		sensor getters that depend on per-frame data may receive stale or nil
		FrameContext. Label-only checks are always accurate.
	]=]
	function publicInterface:CanActivateAbility(name: string): boolean
		local record = stateStore.RecordsByName[name]
		if not record then
			return false
		end
		if not record.IsEnabled then
			return false
		end
		if record.IsActive then
			return false
		end

		-- Check prerequisites (fast mask check)
		if
			not AbilityUtils.checkCompiled(
				record._compiledActivation,
				stateStore.Cache.ActiveMaskLo,
				stateStore.Cache.ActiveMaskHi,
				sensorManager,
				currentFrameContext
			)
		then
			return false
		end

		local dryRunBuffer = {}
		local canResolve = AbilityUtils.resolveConflicts(
			record,
			stateStore.Cache.ActiveAbilities,
			stateStore.Cache.GroupWinners,
			dryRunBuffer
		)

		return canResolve
	end

	-- --------------------------------------------------------------------------------
	-- Cleanup
	-- --------------------------------------------------------------------------------

	function publicInterface:Destroy()
		isShuttingDown = true

		-- Teardown all abilities to prevent memory leaks in user code
		for name, record in stateStore.RecordsByName do
			if record.IsActive then
				stateStore:SetAbilityActive(name, false)
			end
			if record.Definition.OnTeardown then
				local state = record._state or record.State
				local ok, err = pcall(record.Definition.OnTeardown, baseContext, state)
				if not ok then
					warn(string.format("[AbilityManager] Error in OnTeardown for '%s': %s", name, tostring(err)))
				end
			end
		end

		engine:Destroy()
		lifecycle:Destroy()
		sensorManager:Destroy()
		stateStore:Destroy()
		if binding then
			binding:Destroy()
		end

		publicInterface.AbilityActivated:Destroy()
		publicInterface.AbilityDeactivated:Destroy()
		publicInterface.AbilityAdded:Destroy()
		publicInterface.AbilityRemoved:Destroy()
		publicInterface.SleepStateChanged:Destroy()

		table.clear(pendingDefinitions)

		-- Nil out core references to break strong links to Instances
		publicInterface.Owner = nil
		publicInterface._baseContext = nil
	end

	return publicInterface
end

return AbilityManagerInstance
