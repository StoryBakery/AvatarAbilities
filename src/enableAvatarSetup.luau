local Players = game:GetService("Players")

local createAndConfigureControllerManager = require("./createAndConfigureControllerManager")
local createInputActions = require("./createInputActions")

local function onCharacterAdded(character: Model)
	createAndConfigureControllerManager(character)
	createInputActions(character)
end

local function onPlayerAdded(player: Player)
	player.CharacterAdded:Connect(onCharacterAdded)

	if player.Character then
		onCharacterAdded(player.Character)
	end
end

local function enableAvatarSetup()
	Players.PlayerAdded:Connect(onPlayerAdded)

	for _, player in Players:GetPlayers() do
		onPlayerAdded(player)
	end
end

return enableAvatarSetup
