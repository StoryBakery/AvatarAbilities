--!native
--[[
	SensorManager
	=============
	Manages data sources (sensors) for the Ability System.
	
	SENSOR MODES
	------------
	Each sensor has a mode that determines how/when it's evaluated:
	
	POLLED
		- Checked every frame by the engine
		- Use for: Physics state that changes silently (GroundSensor, TippedSensor)
		- Cost: Runs getter every frame
	
	REACTIVE
		- Wakes the engine via subscribe callback, then evaluated on demand
		- Use for: Input with signals (MoveInput, JumpInput, toggles)
		- Cost: Only runs getter when subscribe fires
	
	LAZY
		- Only evaluated when an ability's logic tree needs the value
		- Use for: Expensive calculations rarely needed (CoyoteTime, ProximitySensor)
		- Cost: Only runs getter when referenced in active rules
	
	NOTE: Sensors listed in an ability's StepSensors are force-polled regardless
	of their mode, so OnStep runs when those sensors change.
	
	API EXAMPLES
	------------
	-- Lazy (default when no options provided)
	runner:AddSensor("CoyoteTime", getter)
	
	-- Polled (explicit opt-in for silent-change sensors)
	runner:AddSensor("GroundSensor", getter, { mode = "Polled" })
	
	-- Reactive (inferred when subscribe provided, or explicit)
	runner:AddSensor("JumpInput", getter, { 
		mode = "Reactive", 
		subscribe = function(wake)
			local conn = action.StateChanged:Connect(wake)
			return function() conn:Disconnect() end
		end 
	})
	
	-- With threshold (for vector/number change detection)
	runner:AddSensor("MoveInput", getter, { 
		mode = "Reactive", 
		subscribe = fn, 
		threshold = 0.05 
	})
	
	-- Event-only (Discrete)
	-- Uses the 'Event' helper.
	-- No getter is required because the event *is* the value.
	-- The value exists only for the frame the event fires and is cleared automatically.
	runner:AddSensor("JumpPressed", Event(function(fire)
		local conn = action.Pressed:Connect(fire)
		-- Calling fire() wakes the engine and sets the sensor value to true (or payload).
		return function() conn:Disconnect() end
	end))
]]

local AbilityUtils = require("./AbilityUtils")
local AbilityValidator = require("./AbilityValidator")

local SensorManager = {}
local SensorManager_MT = { __index = SensorManager }

local mathAbs = math.abs
local EVENT_MARKER = newproxy(false)

local function Event(subscribe)
	return {
		_event = EVENT_MARKER,
		_subscribe = subscribe,
	}
end

local function compareNumber(a, b, threshold)
	return mathAbs(a - b) < threshold
end

local function compareVector(a, b, threshold)
	return (a - b).Magnitude < threshold
end

local COMPARATORS = {
	number = compareNumber,
	Vector2 = compareVector,
	Vector3 = compareVector,
}

local DEFAULT_THRESHOLDS = {
	number = 0.001,
	Vector2 = 0.01,
	Vector3 = 0.01,
}

function SensorManager.new()
	local self = setmetatable({}, SensorManager_MT)

	self._sensors = {}
	self._results = {}
	self._polled = {}
	self._configs = {} -- Stores frozen config tables

	self._dirty = false
	self._discreteActivity = false

	-- Track what changed this frame (for StepSensors)
	self._changedThisFrame = {} -- set of names

	-- Track discrete sensors for fast clear
	self._discreteNames = {}
	self._discreteCount = 0

	-- Track DataModel connections for cleanup
	self._connections = {}

	self.Triggered = AbilityUtils.createSignal()

	return self
end

function SensorManager:BindToDataModel(actor: Actor)
	local folder = actor:FindFirstChild("Sensors")
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = "Sensors"
		folder.Parent = actor
	end
	self._folder = folder

	-- Initial load of existing configurations
	for _, child in folder:GetChildren() do
		if child:IsA("Configuration") then
			self:_loadConfig(child)
		end
	end

	-- Watch for new configurations
	local childAddedConn = folder.ChildAdded:Connect(function(child)
		if child:IsA("Configuration") then
			self:_loadConfig(child)
		end
	end)
	table.insert(self._connections, childAddedConn)
end

function SensorManager:_loadConfig(configInstance: Configuration)
	local name = configInstance.Name
	local sensor = self._sensors[name]

	-- Get existing default or empty
	local defaults = (sensor and sensor.defaultConfig) or {}
	local data = table.clone(defaults)

	-- Override from Attributes
	for k, v in pairs(configInstance:GetAttributes()) do
		data[k] = v
	end

	-- Freeze and store
	self._configs[name] = table.freeze(data)

	-- Watch for runtime changes
	local attrConn = configInstance.AttributeChanged:Connect(function(_attr)
		-- Rebuild config from defaults + current attributes to handle both
		-- attribute updates and attribute deletions correctly.
		local currentSensor = self._sensors[name]
		local rebuildDefaults = (currentSensor and currentSensor.defaultConfig) or {}
		local newData = table.clone(rebuildDefaults)
		for k, v in pairs(configInstance:GetAttributes()) do
			newData[k] = v
		end
		self._configs[name] = table.freeze(newData)
		self.Triggered:Fire(name)
	end)
	table.insert(self._connections, attrConn)
end

-- Ensure a config entry exists for sensors added after BindToDataModel
function SensorManager:_ensureConfig(name: string, defaults: { [string]: any }?)
	if self._configs[name] then
		return
	end

	if self._folder then
		local conf = self._folder:FindFirstChild(name)
		if conf then
			-- Already handled by BindToDataModel logic via ChildAdded or init
			return
		end

		-- Create new config
		local newConf = Instance.new("Configuration")
		newConf.Name = name
		if defaults then
			for k, v in pairs(defaults) do
				newConf:SetAttribute(k, v)
			end
		end
		newConf.Parent = self._folder
		-- ChildAdded will trigger _loadConfig
	else
		-- No DataModel binding yet, just store defaults
		self._configs[name] = table.freeze(defaults or {})
	end
end

function SensorManager:BeginFrame()
	table.clear(self._polled)
end

function SensorManager:EndFrame()
	-- Clear discrete results
	local results = self._results
	local discreteNames = self._discreteNames
	for i = 1, self._discreteCount do
		results[discreteNames[i]] = nil
	end

	table.clear(self._changedThisFrame)
	self._dirty = false
	self._discreteActivity = false
end

function SensorManager:IsDirty(): boolean
	return self._dirty
end

function SensorManager:HasDiscreteActivity(): boolean
	return self._discreteActivity
end

function SensorManager:DidSensorChange(name: string): boolean
	return self._changedThisFrame[name] == true
end

-- Exposed as a method so AbilityEngine can drive state
-- Note: For optimization purposes this is a free function that is captured
-- as an upvalue as opposed to a method on the metatable.
local function _setResult(self, sensor, name: string, value: any): boolean
	local results = self._results
	local prev = results[name]

	-- If values are strictly equal, no change
	if prev == value then
		return false
	end

	-- If comparator exists, check threshold
	local threshold = sensor.threshold
	if threshold and prev ~= nil and type(prev) == type(value) then
		local cmp = sensor.comparator
		if cmp and cmp(prev, value, threshold) then
			return false
		end
	end

	-- Value changed
	results[name] = value
	self._dirty = true
	self._changedThisFrame[name] = true
	return true
end

function SensorManager:AddSensor(
	name: string,
	getterOrEvent: any,
	options: {
		mode: ("Polled" | "Reactive" | "Lazy")?,
		subscribe: ((wake: () -> ()) -> () -> ())?,
		threshold: number?,
		defaultConfig: { [string]: any }?,
	}?
)
	if self._sensors[name] then
		return
	end

	-- Detect if this is an Event sensor
	local isEvent = type(getterOrEvent) == "table" and getterOrEvent._event == EVENT_MARKER

	-- Validate sensor parameters
	local ok, err, warning = AbilityValidator.validateSensor(name, getterOrEvent, options, isEvent)
	if not ok then
		error(string.format("[AbilityManager] %s", err or "Unknown sensor error"))
	end
	if warning then
		warn(string.format("[AbilityManager] %s", warning))
	end

	options = options or {}
	self:_ensureConfig(name, options.defaultConfig)

	-- Event only (discrete)
	if type(getterOrEvent) == "table" and getterOrEvent._event == EVENT_MARKER then
		local sensor = {
			name = name,
			getter = nil,
			cleanup = nil,
			mode = "Reactive",
			poll = false,
			defaultConfig = options.defaultConfig,
			-- Keep the same field shape as continuous sensors for monomorphic access
			comparator = nil,
			threshold = nil,
		}

		sensor.cleanup = getterOrEvent._subscribe(function(payload)
			self._discreteActivity = true
			-- Discrete events force a result set, usually truthy
			_setResult(self, sensor, name, if payload == nil then true else payload)
			self.Triggered:Fire(name)
		end)

		self._sensors[name] = sensor

		self._discreteCount += 1
		self._discreteNames[self._discreteCount] = name
		return
	end

	-- Infer mode if not provided
	local mode = options.mode or (options.subscribe and "Reactive" or "Lazy")

	-- Validate
	if mode == "Reactive" and not options.subscribe then
		-- Validation warned about this already, but we must enforce safety fallback
		mode = "Lazy"
	end

	-- Continuous Sensor
	local sensor = {
		name = name,
		getter = getterOrEvent,
		cleanup = nil,
		threshold = options.threshold,
		comparator = nil,
		mode = mode,
		poll = (mode == "Polled"),
		defaultConfig = options.defaultConfig,
	}

	if options.subscribe then
		sensor.cleanup = options.subscribe(function()
			-- Poll immediately on wake so _dirty is set before engine processes
			local getter = sensor.getter
			if getter then
				-- Pass config to getter
				local value = getter(nil, self._configs[name])
				_setResult(self, sensor, name, value)
			end
			self.Triggered:Fire(name)
		end)
	end

	self._sensors[name] = sensor
end

function SensorManager:RemoveSensor(name: string)
	local sensor = self._sensors[name]
	if not sensor then
		return
	end

	if sensor.cleanup then
		sensor.cleanup()
	end

	-- Clean up discrete tracking if this was a discrete (event-only) sensor
	if not sensor.getter then
		for i = 1, self._discreteCount do
			if self._discreteNames[i] == name then
				-- Swap-remove: move the last entry into this slot
				local last = self._discreteCount
				self._discreteNames[i] = self._discreteNames[last]
				self._discreteNames[last] = nil
				self._discreteCount -= 1
				break
			end
		end
	end

	self._sensors[name] = nil
	self._results[name] = nil
end

function SensorManager:GetSensor(name: string, frame: any): any
	local sensor = self._sensors[name]
	if not sensor then
		return nil
	end

	-- If result already cached this frame (by Engine or previous call), return it
	local results = self._results
	if self._polled[name] then
		return results[name]
	end

	-- Mark polled so we don't re-run getter
	self._polled[name] = true

	local getter = sensor.getter
	if not getter then
		-- Discrete sensors just return their current result
		return results[name]
	end

	-- Pass frame AND config to getter
	local config = self._configs[name]
	local value = getter(frame, config)

	-- Lazy initialization of comparator/threshold
	if sensor.comparator == nil and value ~= nil then
		local t = typeof(value)
		sensor.comparator = COMPARATORS[t] or false
		if sensor.threshold == nil then
			sensor.threshold = DEFAULT_THRESHOLDS[t]
		end
	end

	_setResult(self, sensor, name, value)
	return results[name]
end

function SensorManager:GetConfig(name: string)
	return self._configs[name]
end

function SensorManager:HasSensor(name: string): boolean
	return self._sensors[name] ~= nil
end

function SensorManager:IsDiscrete(name: string): boolean
	local sensor = self._sensors[name]
	return sensor and not sensor.getter
end

function SensorManager:GetSensors()
	return self._sensors
end

function SensorManager:Destroy()
	self.Triggered:Destroy()

	for _, conn in self._connections do
		conn:Disconnect()
	end
	table.clear(self._connections)

	for _, sensor in self._sensors do
		if sensor.cleanup then
			sensor.cleanup()
		end
	end

	table.clear(self._sensors)
	table.clear(self._results)
	table.clear(self._polled)
	table.clear(self._changedThisFrame)
	table.clear(self._discreteNames)
end

SensorManager.Event = Event

return SensorManager
