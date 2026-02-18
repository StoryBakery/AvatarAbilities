--[[ 
  Legacy PlatformStand Ability for Avatars
  Support is provided because there exists a legacy Humanoid.PlatformStand
  in the data model.
  Its behavior is simply to cancel any locomotion ability (i.e. abilities which
  would set ControllerManager.ActiveController), and to set ActiveController to
  nil.
]]

local AbilityManager = require("../../AbilityManager")
local AvatarBodyParts = require("../../Utility/AvatarBodyParts")

-- Forward declaration (defined at bottom of file)
local LegacyPlatformStandSensor

local LegacyPlatformStandAbility: AbilityManager.AbilityDefinition = {
	Name = "LegacyPlatformStand",
	ExclusiveGroup = { name = "Locomotion", priority = 1010 },
	Labels = {},
	StepSensors = { "LegacyPlatformStandSensor" },

	RequiresToActivate = { "LegacyPlatformStandSensor" },
	RequiresToContinue = { "LegacyPlatformStandSensor" },
	BlocksWhileActive = {},
	CancelsOnActivation = {},

	DefaultConfig = {},
}

---------- Lifecycle Methods ----------

-- Called once when the ability is first registered
function LegacyPlatformStandAbility.OnSetup(baseCtx: AbilityManager.BaseContext, _state: AbilityManager.AbilityState)
	-- Register Ability-specific sensors
	local manager = baseCtx.abilityManager
	manager:AddSensor(LegacyPlatformStandSensor(manager))
end

-- Called on the frame this ability becomes active
function LegacyPlatformStandAbility.OnActivate(
	baseCtx: AbilityManager.BaseContext,
	_frameCtx: AbilityManager.FrameContext,
	_state: AbilityManager.AbilityState
)
	local controllerManager = baseCtx.controllerManager
	AvatarBodyParts.SetLimbsCollide(baseCtx.abilityOwner, false)
	AvatarBodyParts.SetTorsoCollide(baseCtx.abilityOwner, true)

	-- Legacy Humanoid state are not to use modern physics controllers
	if controllerManager then
		controllerManager.ActiveController = nil
	end
end

-- Called every frame while active
function LegacyPlatformStandAbility.OnStep(
	_baseCtx: AbilityManager.BaseContext,
	_frameCtx: AbilityManager.FrameContext,
	_state: AbilityManager.AbilityState
)
end

---------- Sensors ----------

-- LegacyPlatformStandSensor: Event-based, fires when PlatformStand changes
function LegacyPlatformStandSensor(manager: AbilityManager.AbilityManager)
	local humanoid = manager._baseContext.humanoid

	-- Initialize sensor data
	local isPlatformStanding: boolean = if humanoid then humanoid.PlatformStand else false

	return "LegacyPlatformStandSensor",
		function()
			return isPlatformStanding
		end,
		{
			mode = "Reactive",
			subscribe = function(wake)
				if not humanoid then
					-- Nothing to subscribe to
					return function() end
				end

				local PlatformstandingChangedListener: RBXScriptConnection = humanoid
					:GetPropertyChangedSignal("PlatformStand")
					:Connect(function()
						isPlatformStanding = humanoid.PlatformStand
						wake()
					end)

				return function()
					if PlatformstandingChangedListener then
						PlatformstandingChangedListener:Disconnect()
					end
				end
			end,
		}
end

return LegacyPlatformStandAbility
