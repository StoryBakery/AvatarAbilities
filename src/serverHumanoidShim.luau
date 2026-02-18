--[[
		Simple legacy shim to keep C++ Humanoid state machine
		state in sync with client, even though it's not evaluating.
		This is required to support some functionality like sitting
		and death respawn.
--]]
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local DeathUtil = require("./Utility/DeathUtil")

local function findOrCreateRemoteEvent(parent: Instance, name: string)
	local remoteEvent = parent:FindFirstChild(name) :: RemoteEvent
	if not remoteEvent then
		remoteEvent = Instance.new("RemoteEvent")
		remoteEvent.Name = name
		remoteEvent.Parent = parent
	end
	return remoteEvent
end

function initialize()
	local humanoidShimEvent = findOrCreateRemoteEvent(ReplicatedStorage, "HumanoidShimRemoteEvent")
	local deadEvent = findOrCreateRemoteEvent(ReplicatedStorage, DeathUtil.CONSTS.DEAD_EVENT_INSTANCE_NAME)

	humanoidShimEvent.OnServerEvent:Connect(function(player, humanoidState)
		local char = player.Character
		local humanoid = char and char:FindFirstChild("Humanoid") -- By name, not class for legacy reasons
		if humanoid then
			--print("serverHumanoidShim setting", player.Name .. "'s", "humanoid to state:", humanoidState.Name)
			humanoid:ChangeState(humanoidState)
		end
	end)

	-- Callback for when a client player is determined to be dead.
	-- Server-side NPCs should instead call DeathUtil.maintainCharacterAsDeadOnServer
	-- directly.
	deadEvent.OnServerEvent:Connect(function(_sentByPlayer: Player, character: Instance)
		local characterGoneListener: RBXScriptConnection
		local cleanup: (() -> ())? = DeathUtil.maintainCharacterAsDeadOnServer(character)
		characterGoneListener = character.AncestryChanged:Connect(function(_, parent)
			if not parent then
				if cleanup then
					cleanup()
				end
				characterGoneListener:Disconnect()
			end
		end)
	end)

	-- Track character removals to make sure SeatWelds are cleaned up if
	-- player respawns or disconnects while seated
	Players.PlayerAdded:Connect(function(player)
		player.CharacterRemoving:Connect(function(char)
			local humanoid = char:FindFirstChildOfClass("Humanoid")
			local hrp = humanoid and humanoid.RootPart
			if hrp and humanoid.SeatPart then
				local seatWeld = humanoid.SeatPart:FindFirstChild("SeatWeld")
				if seatWeld and seatWeld:IsA("Weld") then
					if seatWeld.Part1 == hrp then
						seatWeld:Destroy()
					end
				end
			end
		end)
	end)
end

return {
	initialize = initialize,
}
