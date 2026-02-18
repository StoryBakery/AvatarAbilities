--!native
--[[
  Util methods for setting up a character as mortal.
  Publicly available methods are listed in the return value at the end of this
  file.
]]

local RunService = game:GetService("RunService")

local CONSTS = {
	-- Name of the RemoteEvent (player) or BindableEvent (npc) placed under
	-- the character, which will fire when the character becomes dead.
	DEAD_EVENT_INSTANCE_NAME = "DeadRemoteEvent",
	-- The target mass to assign to a bodypart when the joints are broken upon
	-- death, up to the max allowable density.
	PART_MASS_WHEN_DEAD = 10.0,
}
table.freeze(CONSTS)

-- Destroys the joints childed to obj or to any models nested within obj
local function destroyJoints(obj: Instance)
	if obj:IsA("BasePart") then
		for _, joint in obj:GetJoints() do
			if joint:IsA("JointInstance") or joint:IsA("AnimationConstraint") then
				joint:Destroy()
			elseif joint:IsA("BallSocketConstraint") then
				joint.Enabled = false
			end
		end
	elseif obj:IsA("Model") then
		for _, childObj in obj:GetDescendants() do
			destroyJoints(childObj)
		end
	end
end

-- Make the character fall apart
local function dismemberCharacter(character: Instance)
	destroyJoints(character)
	for _, descendant in character:GetDescendants() do
		if descendant:IsA("BasePart") then
			-- Assign a new mass to the body parts
			local oldPhysicsProperties = PhysicalProperties.new(descendant.Material)
			local oldMass = descendant:GetMass()
			local volume = oldMass / oldPhysicsProperties.Density
			local newDensity = CONSTS.PART_MASS_WHEN_DEAD / volume
			newDensity = math.clamp(newDensity, 0.0001, 100.0)
			local newPhysicsProperties =
				PhysicalProperties.new(newDensity, oldPhysicsProperties.Friction, oldPhysicsProperties.Elasticity)
			descendant.CustomPhysicalProperties = newPhysicsProperties

			descendant.CanCollide = true
			-- SetNetworkOwner can only be run server-side.
			if RunService:IsServer() then
				-- Assign control of the character's parts to the server.
				descendant:SetNetworkOwner(nil)
			end
		end
	end
end

local function setCharacterModelAsDead(character: Instance)
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid and humanoid.BreakJointsOnDeath then
		dismemberCharacter(character)
	else
		for _, descendant in character:GetDescendants() do
			if descendant:IsA("AnimationConstraint") then
				descendant.Enabled = false
			end
		end
	end
end

-- Keeps a dead character's health at 0 on the server.
-- Returns a callback which should be envoked as cleanup when the character is
-- no longer to be maintained as dead, or returns nil if no cleanup is needed.
local function maintainCharacterAsDeadOnServer(character: Instance): (() -> ())?
	if RunService:IsServer() and character:IsA("Model") then
		-- Reflect the bodypart settings, and give ownership of them to the
		-- server
		setCharacterModelAsDead(character)

		local humanoid = character:FindFirstChildOfClass("Humanoid")
		if humanoid then
			local healthHeartbeat: RBXScriptConnection
			local ancestryChanged: RBXScriptConnection
			local function cleanup()
				healthHeartbeat:Disconnect()
				ancestryChanged:Disconnect()
			end
			healthHeartbeat = RunService.Heartbeat:Connect(function(_dt)
				-- Override any healing effects
				humanoid.Health = 0
			end)
			ancestryChanged = humanoid.AncestryChanged:Connect(function()
				if not humanoid:IsDescendantOf(game) then
					cleanup()
				end
			end)
			return cleanup
		end
	end
	return nil
end

return {
	CONSTS = CONSTS,
	setCharacterModelAsDead = setCharacterModelAsDead,
	maintainCharacterAsDeadOnServer = maintainCharacterAsDeadOnServer,
}
