--[[ 
  Sitting Ability for Avatars
  Locks the character into a seat, disabling movement controllers.
  Priority 1000 ensures it overrides all other locomotion.
]]

local AbilityManager = require("../../AbilityManager")

-- Forward declaration (defined at bottom of file)
local SitSensor

local SittingAbility: AbilityManager.AbilityDefinition = {
	Name = "Sitting",
	ExclusiveGroup = { name = "Locomotion", priority = 1000 }, -- overrides all other locomotion
	Labels = { "detachable" },

	RequiresToActivate = { "SitSensor" },
	RequiresToContinue = {},
	BlocksWhileActive = {},
	CancelsOnActivation = {},

	DefaultConfig = {},
}

---------- Lifecycle Methods ----------

function SittingAbility.OnSetup(baseCtx: AbilityManager.BaseContext, _state: AbilityManager.AbilityState)
	local manager = baseCtx.abilityManager

	-- Register Ability-specific sensors
	manager:AddSensor(SitSensor(baseCtx.humanoid))
end

function SittingAbility.OnActivate(
	baseCtx: AbilityManager.BaseContext,
	_frameCtx: AbilityManager.FrameContext,
	_state: AbilityManager.AbilityState
)
	local cm = baseCtx.controllerManager
	if cm then
		cm.ActiveController = nil
	end
end

function SittingAbility.OnDeactivate(
	_baseCtx: AbilityManager.BaseContext,
	_frameCtx: AbilityManager.FrameContext,
	_state: AbilityManager.AbilityState
)
end

function SittingAbility.OnStep(baseCtx: AbilityManager.BaseContext, _frameCtx: AbilityManager.FrameContext, _state)
	local manager = baseCtx.abilityManager
	local isSit = baseCtx.humanoid and baseCtx.humanoid.Sit
	if not isSit then
		manager:DeactivateAbility(SittingAbility.Name)
	end
end

---------- Sensors ----------

-- SitSensor: Simple humanoid.Sit check
function SitSensor(humanoid)
	return "SitSensor", function()
		return humanoid.Sit
	end
end

return SittingAbility
