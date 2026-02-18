--[[
	InternalTypes - Private type definitions for the AbilityManager engine.

	Bitmask convention: all label masks are stored as two plain numbers (Lo, Hi)
	covering bits 0-31 and 32-63 respectively. This supports up to 64 labels
	with zero table allocations on the hot path.
]]

local Types = require("./Types")

export type BaseContext = Types.BaseContext
export type FrameContext = Types.FrameContext
export type AbilityDefinition = Types.AbilityDefinition
export type Cleanup = Types.Cleanup

-- One AND scenario in disjunctive normal form
export type LogicVariant = {
	requiredLo: number,
	requiredHi: number,
	forbiddenLo: number,
	forbiddenHi: number,
	sensorNames: { string },
	invertedSensorNames: { string }?,
}

-- Compiled logic structure with flattened variants
export type CompiledLogic = {
	variants: { CompiledVariant },
	variantCount: number,
}

export type CompiledVariant = {
	mustHaveLo: number,
	mustHaveHi: number,
	mustNotLo: number,
	mustNotHi: number,
	sensorNames: { string },
	sensorCount: number,
	invertedNames: { string },
	invertedCount: number,
}

-- Signal connection handle returned by Signal:Connect
export type SignalConnection = {
	Disconnect: (self: SignalConnection) -> (),
	Connected: boolean,
}

-- Simple signal type
export type Signal<T...> = {
	Connect: (any, (T...) -> ()) -> SignalConnection,
	Fire: (any, T...) -> (),
	Destroy: (any) -> (),
}

-- Runtime wrapper for an ability
export type AbilityRecord = {
	Definition: AbilityDefinition,
	Name: string,
	NameLower: string,
	Priority: number,
	GroupName: string?,
	GroupID: number?,
	IsEnabled: boolean,
	IsActive: boolean,
	State: { [any]: any },
	TimeLastActive: number,
	TimeLastInactive: number,

	-- Cached callbacks
	_onStepFunc: ((Types.BaseContext, Types.FrameContext, Types.AbilityState) -> ())?,

	-- Augmented State (injected by DataModelBinding or fallback)
	_state: Types.AbilityState?,

	-- Server authority
	ConfigInstance: Configuration?,

	-- Sleep/step control
	_canSleep: boolean,
	_isAutomatic: boolean,

	-- Engine stepper index (set/cleared by AbilityEngine._addStepper/_removeStepper)
	_stepIndex: number?,

	-- Cached stepper closure (created by AbilityEngine._createStepper, cleared on deactivation)
	_stepClosure: ((any, boolean, boolean, any?) -> ())?,

	-- Flag set by DataModelBinding when config changes at runtime;
	-- read and cleared by the Engine stepper to force an OnStep run.
	_needsStep: boolean?,

	-- Labels this ability applies while active (flat lo/hi)
	_maskSelfLo: number,
	_maskSelfHi: number,

	-- Blocking masks (flat lo/hi)
	_maskBlocksLo: number,
	_maskBlocksHi: number,
	_maskBlocksNotLo: number,
	_maskBlocksNotHi: number,

	-- Pre-DNF variant lists (used by Compiler for sensor analysis and RefreshLogic)
	_activationVariants: { LogicVariant }?,
	_continuationVariants: { LogicVariant }?,

	-- Compiled logic (DNF variants, used by Engine for fast checking)
	_compiledActivation: CompiledLogic?,
	_compiledContinuation: CompiledLogic?,

	-- Cancellation masks (flat lo/hi)
	_cancelsMaskLo: number,
	_cancelsMaskHi: number,
	_cancelsNotMaskLo: number,
	_cancelsNotMaskHi: number,

	-- Step sensor names
	_stepSensors: { string }?,
}

-- State store type
export type AbilityStateStore = {
	RecordsByName: { [string]: AbilityRecord },
	Settings: { [string]: { [string]: any } },

	Cache: {
		Version: number,
		ActiveAbilities: { AbilityRecord },
		InactiveAbilities: { AbilityRecord },
		GroupWinners: { [number]: AbilityRecord },
		ActiveMaskLo: number,
		ActiveMaskHi: number,
		ContinuousCandidates: { AbilityRecord },
		NonSleepableCount: number,
	},

	DirtyList: { AbilityRecord },
	InitialStateMap: { [AbilityRecord]: boolean },

	AddAbility: (self: AbilityStateStore, record: AbilityRecord) -> (),
	RemoveAbility: (self: AbilityStateStore, name: string) -> (),
	SetAbilityActive: (self: AbilityStateStore, name: string, active: boolean) -> (),
	SetAbilityEnabled: (self: AbilityStateStore, name: string, enabled: boolean) -> (),
	NotifyConfigChanged: (self: AbilityStateStore, name: string) -> (),
	GetSetting: (self: AbilityStateStore, name: string, setting: string) -> any,
	SetSetting: (self: AbilityStateStore, name: string, setting: string, value: any) -> (),
	GetActiveDefinitions: (self: AbilityStateStore) -> { AbilityDefinition },
	EndFrame: (self: AbilityStateStore, signals: any) -> (),
	Destroy: (self: AbilityStateStore) -> (),

	AbilityActiveChanged: Signal<string, boolean>,
	AbilityEnabledChanged: Signal<string, boolean>,
	AbilityConfigChanged: Signal<string>,
}

return nil
