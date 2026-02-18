--[[
	AuthorityConfig
	===============
	Single source of truth for the authority mode of the experience.

	Maps to Workspace.AuthorityMode (Enum.AuthorityMode):
	  "Automatic" — Default. Today's distributed authority. Clients have
	                network ownership of their characters. When SAuth Beta
	                (NextGenerationReplication) is enabled, uses
	                BindToSimulation for fixed timestep.
	  "Server"    — Server is authoritative for everything. GetNetworkOwner()
	                returns nil, only inputs are sent client→server.
	                BindToSimulation + prediction/rollback on client.

	Legacy (no SAuth Beta):
	  "None"      — NextGenerationReplication not enabled. Legacy PreAnimation
	                stepping. Incompatible with Server Authority.

	Detection:
	  We read a custom attribute:
	    workspace:GetAttribute("AuthorityMode") → "Automatic" | "Server" | nil

	  If the attribute is absent or nil, mode defaults to "None" (legacy).
	  When using SAuth Beta (NextGenerationReplication = Enabled), the
	  attribute MUST be set to "Automatic" or "Server" — "None"
	  (PreAnimation stepping) is incompatible with the rollback pipeline.
]]

local RunService = game:GetService("RunService")

export type AuthorityMode = "None" | "Automatic" | "Server"

local AuthorityConfig = {}

local function detect(): AuthorityMode
	local attr = workspace:GetAttribute("AuthorityMode")

	if attr == "Server" then
		return "Server"
	elseif attr == "Automatic" then
		return "Automatic"
	end

	return "None"
end

local mode: AuthorityMode = detect()

AuthorityConfig.mode = mode
AuthorityConfig.sAuthBetaEnabled = (mode ~= "None")
AuthorityConfig.isServerAuth = (mode == "Server")
AuthorityConfig.isAutoAuth = (mode == "Automatic")
AuthorityConfig.isServer = RunService:IsServer()
AuthorityConfig.isClient = RunService:IsClient()

-- Should this context create and step a runner?
-- SAuth Beta enabled: both sides.  No SAuth Beta: client only.
function AuthorityConfig.shouldSimulate(): boolean
	if AuthorityConfig.sAuthBetaEnabled then
		return true
	end
	return AuthorityConfig.isClient
end

-- Which RunService event drives Step()?
-- SAuth Beta enabled -> BindToSimulation.  No SAuth Beta → PreAnimation.
function AuthorityConfig.getStepMode(): string
	if AuthorityConfig.sAuthBetaEnabled then
		return "BindToSimulation"
	end
	return "PreAnimation"
end

return AuthorityConfig
