--------------------------------------------------------------------------------
-- Input Creation
--------------------------------------------------------------------------------
local function createInputActions(character: Model)
	local inputContext = character:FindFirstChild("AbilityManagerInput")
	if not inputContext then
		inputContext = Instance.new("InputContext")
		inputContext.Name = "AbilityManagerInput"
		inputContext.Parent = character
	end

	local returnActions = {}

	local moveAction = inputContext:FindFirstChild("Move")
	if not moveAction then
		moveAction = Instance.new("InputAction")
		moveAction.Name = "Move"
		moveAction.Parent = inputContext
		moveAction.Type = Enum.InputActionType.Direction2D
	end
	local moveKeyBind = moveAction:FindFirstChild("KeyboardBinding")
	if not moveKeyBind then
		moveKeyBind = Instance.new("InputBinding")
		moveKeyBind.Name = "KeyboardBinding"
		moveKeyBind.Parent = moveAction
		moveKeyBind.Up = Enum.KeyCode.W
		moveKeyBind.Down = Enum.KeyCode.S
		moveKeyBind.Left = Enum.KeyCode.A
		moveKeyBind.Right = Enum.KeyCode.D
	end

	local movePadBind = moveAction:FindFirstChild("GamepadBinding")
	if not movePadBind then
		movePadBind = Instance.new("InputBinding")
		movePadBind.Name = "GamepadBinding"
		movePadBind.Parent = moveAction
		movePadBind.KeyCode = Enum.KeyCode.Thumbstick1
	end
	returnActions["Move"] = moveAction

	local lookAction = inputContext:FindFirstChild("Look")
	if not lookAction then
		lookAction = Instance.new("InputAction")
		lookAction.Name = "Look"
		lookAction.Parent = inputContext
		lookAction.Type = Enum.InputActionType.Direction3D
	end
	returnActions["Look"] = lookAction

	local actions = {
		{ Name = "Jump", Key = Enum.KeyCode.Space, Pad = Enum.KeyCode.ButtonA },
		{ Name = "Sprint", Key = Enum.KeyCode.LeftShift, Pad = Enum.KeyCode.ButtonL3 },
		{ Name = "Crouch", Key = Enum.KeyCode.C, Pad = Enum.KeyCode.ButtonB },
		{ Name = "Strafe", Key = Enum.KeyCode.LeftAlt, Pad = Enum.KeyCode.ButtonR3 },
	}

	for _, config in ipairs(actions) do
		local action = inputContext:FindFirstChild(config.Name)
		if not action then
			action = Instance.new("InputAction")
			action.Name = config.Name
			action.Type = Enum.InputActionType.Bool
			action.Parent = inputContext
		end

		-- Keyboard
		if not action:FindFirstChild("KeyboardBinding") then
			local keyBind = Instance.new("InputBinding")
			keyBind.Name = "KeyboardBinding"
			keyBind.KeyCode = config.Key
			keyBind.Parent = action
		end

		-- Gamepad
		if not action:FindFirstChild("GamepadBinding") then
			local padBind = Instance.new("InputBinding")
			padBind.Name = "GamepadBinding"
			padBind.KeyCode = config.Pad
			padBind.Parent = action
		end

		returnActions[action.Name] = action
	end

	return returnActions
end

return createInputActions
