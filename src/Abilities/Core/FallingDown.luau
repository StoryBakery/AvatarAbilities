--!native
--[[ 
  FallingDown Ability for Avatars
  Ragdolls the character for a set duration when tipped over, 
  disabling movement controllers and enabling full physics collisions.
]]

local AbilityManager = require("../../AbilityManager")
local AvatarBodyParts = require("../../Utility/AvatarBodyParts")

local Not = AbilityManager.Not

local CONSTS = table.freeze({
	-- Amount of seconds which this Ability is to remain active
	MAX_ACTIVE_DURATION = 3.0,
	-- Setting key used by AnimateShimClient to process the "Landed" state transition
	SETTING_PROCESS_LANDED_STATE = "ProcessLandedState",
})

local FallingDownAbility: AbilityManager.AbilityDefinition = {
	Name = "FallingDown",
	ExclusiveGroup = { name = "Locomotion", priority = 60 }, -- priority 60 ensures it runs BEFORE GettingUp (55) when TippedSensor triggers
	Labels = { "fallingdown" },

	RequiresToActivate = { "canFallDown", "TippedSensor", Not("WaterSensor") },
	RequiresToContinue = { Not("WaterSensor") },
	BlocksWhileActive = { "jump", "locomotionModifier" },
	CancelsOnActivation = { "canFallDown", "jump", "detachable" },

	-- Explicitly prevent sleeping so the 3-second recovery timer ticks accurately
	CanSleep = false,

	DefaultConfig = {},

	DefaultState = {
		[CONSTS.SETTING_PROCESS_LANDED_STATE] = false,
	},
}

---------- Lifecycle Methods ----------

function FallingDownAbility.OnSetup(_baseCtx: AbilityManager.BaseContext, _state: AbilityManager.AbilityState)
	-- No setup required (TippedSensor registered in initializeLocalCharacter)
end

function FallingDownAbility.OnActivate(
	baseCtx: AbilityManager.BaseContext,
	_frameCtx: AbilityManager.FrameContext,
	_state: AbilityManager.AbilityState
)
	local cm = baseCtx.controllerManager

	-- Disable all movement controllers to induce a true ragdoll/physics state
	if cm then
		cm.ActiveController = nil
	end

	-- Enable full collision for realism while tumbling
	AvatarBodyParts.SetLimbsCollide(baseCtx.abilityOwner, true)
	AvatarBodyParts.SetTorsoCollide(baseCtx.abilityOwner, true)
end

function FallingDownAbility.OnStep(
	baseCtx: AbilityManager.BaseContext,
	_frameCtx: AbilityManager.FrameContext,
	_state: AbilityManager.AbilityState
)
	local manager = baseCtx.abilityManager
	local name = FallingDownAbility.Name

	local timeActive: number? = manager:GetTimeWhenAbilityLastActivated(name)
	if not timeActive then
		manager:DeactivateAbility(name)
		return
	end

	-- Time-based deactivation.
	-- Once MAX_ACTIVE_DURATION passes, FallingDown ends, and GettingUp takes over naturally.
	if (time() - timeActive) > CONSTS.MAX_ACTIVE_DURATION then
		manager:DeactivateAbility(name)
	end
end

function FallingDownAbility.OnDeactivate(
	_baseCtx: AbilityManager.BaseContext,
	_frameCtx: AbilityManager.FrameContext,
	_state: AbilityManager.AbilityState
)
	-- No manual transition logic needed.
	-- If the character is still tipped, GettingUp will automatically activate next frame.
end

return FallingDownAbility
