--!native
local AbilityManager = require("../AbilityManager")
local Event = AbilityManager.Event

-- Hold sensor: returns action state, wakes on change
local function makeHoldSensor(action)
	if not action then
		return function()
			return false
		end
	end
	return function()
		return action:GetState()
	end, {
		mode = "Reactive",
		subscribe = function(wake)
			local conn = action.StateChanged:Connect(wake)
			return function()
				conn:Disconnect()
			end
		end,
	}
end

-- Toggle sensor: flips state on press
local function makeToggleSensor(action)
	if not action then
		return function()
			return false
		end
	end
	local toggled = false
	return function()
		return toggled
	end, {
		mode = "Reactive",
		subscribe = function(wake)
			local conn = action.Pressed:Connect(function()
				toggled = not toggled
				wake()
			end)
			return function()
				conn:Disconnect()
			end
		end,
	}
end

-- Press sensor: discrete event, fires once per press
local function makePressSensor(action)
	if not action then
		return Event(function()
			return function() end
		end)
	end
	return Event(function(fire)
		local conn = action.Pressed:Connect(fire)
		return function()
			conn:Disconnect()
		end
	end)
end

-- Move sensor: Vector2 with deadzone, wakes on change
local function makeMoveSensor(action, deadzone, threshold)
	if not action then
		return function()
			return Vector2.zero
		end
	end
	return function()
		local value = action:GetState() or Vector2.zero
		if value.Magnitude < deadzone then
			return Vector2.zero
		end
		return value
	end, {
		mode = "Reactive",
		subscribe = function(wake)
			local conn = action.StateChanged:Connect(wake)
			return function()
				conn:Disconnect()
			end
		end,
		threshold = threshold,
	}
end

-- Look sensor: Vector3 with threshold filtering in subscribe
local function makeLookSensor(action, threshold)
	if not action then
		return function()
			return Vector3.zAxis
		end
	end
	return function()
		return action:GetState() or Vector3.zAxis
	end, {
		mode = "Reactive",
		subscribe = function(wake)
			local lastValue = Vector3.zAxis
			local conn = action.StateChanged:Connect(function()
				local current = action:GetState() or Vector3.zAxis
				if (current - lastValue).Magnitude > threshold then
					lastValue = current
					wake()
				end
			end)
			return function()
				conn:Disconnect()
			end
		end,
		threshold = threshold,
	}
end

return {
	makeHoldSensor = makeHoldSensor,
	makeToggleSensor = makeToggleSensor,
	makePressSensor = makePressSensor,
	makeMoveSensor = makeMoveSensor,
	makeLookSensor = makeLookSensor,
}
