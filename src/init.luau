--[[
	AvatarAbilities
	===============
	Top-level entry point. Mode-aware across all three configurations:

	None:
	  Server: enableAvatarSetup + GrabServer + AimServer + serverHumanoidShim
	  Client: initializeCharacter (PreAnimation step)

	Automatic (SAuth Beta, distributed authority):
	  Server: enableAvatarSetup + GrabServer + AimServer + server runners
	  Client: initializeCharacter (BindToSimulation step)

	Server (SAuth Beta, server authority):
	  Server: enableAvatarSetup + GrabServer + AimServer + server runners
	          (server runner drives humanoid state via shared shim, no RemoteEvent)
	  Client: initializeCharacter (BindToSimulation step + prediction)
]]

local RunService = game:GetService("RunService")

local AuthorityConfig = require("@self/AuthorityConfig")
local enableAvatarSetup = require("@self/enableAvatarSetup")
local initializeCharacter = require("@self/initializeCharacter")
local serverHumanoidShim = require("@self/serverHumanoidShim")

local isInitialized = false

local function initializeServer()
	if isInitialized then
		warn(`AvatarAbilities server was already initialized!`)
		return
	end
	isInitialized = true

	if RunService:IsServer() then
		-- Avatar setup runs in all modes (ControllerManager, sensors, etc.)
		enableAvatarSetup()

		if not AuthorityConfig.sAuthBetaEnabled then
			-- No SAuth Beta (None): legacy RemoteEvent shim.
			-- Humanoid state synced via RemoteEvent from client.
			serverHumanoidShim.initialize()
		end
	end
end

local AvatarAbilities = {
	initializeServer = initializeServer,
	initializeCharacter = initializeCharacter,

	-- Exposed for external queries
	mode = AuthorityConfig.mode,
	isServerAuth = AuthorityConfig.isServerAuth,
	isAutoAuth = AuthorityConfig.isAutoAuth,
	sAuthBetaEnabled = AuthorityConfig.sAuthBetaEnabled,
}

return AvatarAbilities
