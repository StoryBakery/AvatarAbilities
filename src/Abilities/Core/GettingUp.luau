--!native
--[[ 
  GettingUp Ability for Avatars
  Brings the avatar up to a standing position after tipping over.
  Transitions physics controllers and handles collision states during recovery.
]]

local AbilityManager = require("../../AbilityManager")
local AvatarBodyParts = require("../../Utility/AvatarBodyParts")

local Not = AbilityManager.Not

local GettingUpAbility: AbilityManager.AbilityDefinition = {
	Name = "GettingUp",
	ExclusiveGroup = { name = "Locomotion", priority = 55 }, -- high priority; overrides swimming and walking when tipped
	Labels = { "fallingdown" },
	StepSensors = {}, -- explicitly prevent sleeping so physics recovery runs at full framerate

	-- The Manager activates this the instant the character's up-vector tips too far.
	RequiresToActivate = { "TippedSensor", "GroundSensor", Not("WaterSensor") },
	-- The Manager kills this Ability the exact frame the character achieves an upright position.
	RequiresToContinue = { "TippedSensor", "GroundSensor", Not("WaterSensor") },
	BlocksWhileActive = { "jump" },
	CancelsOnActivation = {},

	DefaultConfig = {},
}

---------- Lifecycle Methods ----------

function GettingUpAbility.OnSetup(baseCtx: AbilityManager.BaseContext, state: AbilityManager.AbilityState)
	local cm = baseCtx.controllerManager
	if cm then
		state.groundController = cm:FindFirstChildWhichIsA("GroundController")
	end
end

function GettingUpAbility.OnActivate(
	baseCtx: AbilityManager.BaseContext,
	_frameCtx: AbilityManager.FrameContext,
	state: AbilityManager.AbilityState
)
	local cm = baseCtx.controllerManager

	-- Only enable the ground controller if we actually sense ground.
	if cm and state.groundController then
		cm.ActiveController = state.groundController
	end

	-- Disable limb collisions so the character doesn't get stuck on debris while standing up.
	AvatarBodyParts.SetLimbsCollide(baseCtx.abilityOwner, false)
	AvatarBodyParts.SetTorsoCollide(baseCtx.abilityOwner, true)
end

function GettingUpAbility.OnTeardown(_baseCtx: AbilityManager.BaseContext) end

return GettingUpAbility
