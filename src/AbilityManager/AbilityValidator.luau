--!native
local Types = require("./Types")

local AbilityValidator = {}

local VALID_SENSOR_MODES = {
	Polled = true,
	Reactive = true,
	Lazy = true,
}

-- Reserved attribute keys that cannot be used in DefaultConfig or DefaultState.
-- "Enabled" is managed by the engine and DataModelBinding.
local RESERVED_KEYS = {
	Enabled = true,
}

-- Validates sensor registration parameters.
-- Returns (ok, errorMessage, warningMessage)
-- errorMessage is set if the sensor is invalid and should not be registered.
-- warningMessage is set for non-fatal issues (sensor will still work but may be suboptimal).
function AbilityValidator.validateSensor(
	name: string,
	getterOrEvent: any,
	options: {
		mode: string?,
		subscribe: ((wake: () -> ()) -> () -> ())?,
		threshold: number?,
	}?,
	isEvent: boolean -- true if getterOrEvent is an Event wrapper
): (boolean, string?, string?)
	-- Validate name
	if type(name) ~= "string" or name == "" then
		return false, "Sensor name must be a non-empty string", nil
	end

	-- Event sensors have different rules
	if isEvent then
		-- Event sensors are always valid (mode is forced to Reactive, no getter needed)
		return true, nil, nil
	end

	-- Non-Event sensors must have a getter function
	if type(getterOrEvent) ~= "function" then
		return false, string.format("Sensor '%s': getter must be a function, got %s", name, type(getterOrEvent)), nil
	end

	-- Validate options if provided
	if options then
		local warning = nil

		-- Validate mode
		if options.mode ~= nil then
			if type(options.mode) ~= "string" then
				return false, string.format("Sensor '%s': mode must be a string, got %s", name, type(options.mode)), nil
			end
			if not VALID_SENSOR_MODES[options.mode] then
				return false,
					string.format(
						"Sensor '%s': invalid mode '%s'. Must be 'Polled', 'Reactive', or 'Lazy'",
						name,
						options.mode
					),
					nil
			end
		end

		-- Validate subscribe
		if options.subscribe ~= nil and type(options.subscribe) ~= "function" then
			return false,
				string.format("Sensor '%s': subscribe must be a function, got %s", name, type(options.subscribe)),
				nil
		end

		-- Validate threshold
		if options.threshold ~= nil and type(options.threshold) ~= "number" then
			return false,
				string.format("Sensor '%s': threshold must be a number, got %s", name, type(options.threshold)),
				nil
		end

		-- Check mode + subscribe consistency
		local mode = options.mode
		local hasSubscribe = options.subscribe ~= nil

		if mode == "Reactive" and not hasSubscribe then
			warning =
				string.format("Sensor '%s': mode is 'Reactive' but no subscribe provided. Will behave as 'Lazy'.", name)
		elseif mode == "Polled" and hasSubscribe then
			warning = string.format(
				"Sensor '%s': mode is 'Polled' but has subscribe. The subscribe is redundant since Polled sensors are checked every frame.",
				name
			)
		end

		-- Validate Shared Config keys
		if options.defaultConfig then
			if type(options.defaultConfig) ~= "table" then
				return false, string.format("Sensor '%s': defaultConfig must be a table", name), nil
			end
			for k in pairs(options.defaultConfig) do
				if type(k) ~= "string" then
					return false, "Sensor config keys must be strings", nil
				end
			end
		end

		return true, nil, warning
	end

	return true, nil, nil
end

-- Validates that an ability definition conforms to the schema and logic rules.
-- Ensures that sensors are not used in contexts that would cause logic errors,
-- such as attempting to block or cancel a physics-driven sensor.
function AbilityValidator.validateDefinition(
	definition: Types.AbilityDefinition,
	existingAbilityNames: { [string]: boolean },
	_labelToBit: { [string]: number },
	_nextBit: number,
	knownSensorNames: { [string]: string } -- name → mode ("Polled" | "Reactive" | "Lazy" | "Discrete")
): (boolean, string?)
	if type(definition) ~= "table" then
		return false, "Definition must be a table"
	end

	if type(definition.Name) ~= "string" or definition.Name == "" then
		return false, "Ability must have a Name string"
	end

	if existingAbilityNames[definition.Name] then
		return false, string.format("Ability '%s' already exists.", definition.Name)
	end

	-- Validate ExclusiveGroup structure if present
	if definition.ExclusiveGroup then
		if type(definition.ExclusiveGroup) ~= "table" then
			return false,
				string.format(
					"Ability '%s': ExclusiveGroup must be a table with 'name' and 'priority' fields.",
					definition.Name
				)
		end
		if type(definition.ExclusiveGroup.name) ~= "string" or definition.ExclusiveGroup.name == "" then
			return false,
				string.format("Ability '%s': ExclusiveGroup.name must be a non-empty string.", definition.Name)
		end
		if type(definition.ExclusiveGroup.priority) ~= "number" then
			return false,
				string.format(
					"Ability '%s': ExclusiveGroup.priority must be a number, got %s.",
					definition.Name,
					type(definition.ExclusiveGroup.priority)
				)
		end
	end

	-- Check for collisions between ability labels and registered sensors
	if definition.Labels then
		for _, label in definition.Labels do
			if type(label) ~= "string" then
				return false, "Labels must be strings."
			end
			if string.match(label, "[^%w%-_]") then
				return false, string.format("Invalid label '%s'.", label)
			end
			if knownSensorNames[label] then
				return false,
					string.format("Ability cannot use label '%s' because a sensor with that name is registered.", label)
			end
		end
	end

	-- Scans a Rule tree to ensure all nodes are valid strings and respect sensor permissions
	local function validateRule(rule: Types.Rule?, category: string, allowSensors: boolean): (boolean, string?)
		if not rule then
			return true
		end

		if type(rule) == "string" then
			if string.match(rule, "[^%w%-_]") then
				return false, string.format("Invalid label '%s' in %s.", rule, category)
			end
			if not allowSensors and knownSensorNames[rule] then
				return false, string.format("Rule category '%s' cannot contain sensor '%s'.", category, rule)
			end
			return true
		end

		-- Verify the table is a valid Logic Group (has .type) or an Array (has [1]).
		-- Empty tables ({}) are permitted as implicit empty lists.
		if type(rule) == "table" then
			local ruleTable = rule :: { [any]: any }
			if not ruleTable.type and not ruleTable[1] then
				if next(ruleTable) ~= nil then
					return false,
						string.format("Invalid rule in %s. Expected string label, logic group, or array.", category)
				end
			end
		end

		-- Check Tables (List or Logic Group)
		local ruleAsTable = rule :: { [any]: any }
		local children = ruleAsTable.children or ruleAsTable -- Implicit list is its own children

		if ruleAsTable.type == "Not" then
			-- Not() only accepts strings.
			return validateRule(ruleAsTable.child, category, allowSensors)
		end

		-- Recursive Check
		for _, child in children do
			local ok, err = validateRule(child, category, allowSensors)
			if not ok then
				return false, err
			end
		end

		return true
	end

	-- Blocks and Cancels cannot target sensors because sensors are stateful data sources, not abilities.
	local categories = {
		{ rule = definition.BlocksWhileActive, name = "BlocksWhileActive", allowSensors = false },
		{ rule = definition.CancelsOnActivation, name = "CancelsOnActivation", allowSensors = false },
		{ rule = definition.RequiresToActivate, name = "RequiresToActivate", allowSensors = true },
		{ rule = definition.RequiresToContinue, name = "RequiresToContinue", allowSensors = true },
	}

	for i = 1, #categories do
		local ok, err = validateRule(categories[i].rule, categories[i].name, categories[i].allowSensors)
		if not ok then
			return false, err
		end
	end

	-- Validate that RequiresToActivate won't silently force lazy sensors to poll every frame.
	-- If activation depends ONLY on lazy sensors (no labels, no polled/reactive/discrete sensors),
	-- the ability becomes an automatic candidate and the lazy getters run every frame - defeating
	-- the purpose of "Lazy" mode. Reject the definition and tell the user how to fix it.
	if definition.RequiresToActivate then
		local hasLabels = false
		local hasDrivenSensors = false
		local hasLazySensors = false
		local lazySensorList = {}

		local function scanForDrivers(rule: Types.Rule?)
			if not rule then
				return
			end
			if type(rule) == "string" then
				local sensorMode = knownSensorNames[rule]
				if sensorMode then
					if sensorMode == "Lazy" then
						hasLazySensors = true
						table.insert(lazySensorList, rule)
					else
						-- Polled, Reactive, or Discrete - these actively drive evaluation
						hasDrivenSensors = true
					end
				else
					-- Not a sensor → it's a label, which is driven by the bitmask
					hasLabels = true
				end
				return
			end
			if type(rule) == "table" then
				local ruleTable = rule :: { [any]: any }
				if ruleTable.type == "Not" then
					scanForDrivers(ruleTable.child)
					return
				end
				local children = ruleTable.children or ruleTable
				for _, child in children do
					scanForDrivers(child)
				end
			end
		end

		scanForDrivers(definition.RequiresToActivate)

		if hasLazySensors and not hasDrivenSensors and not hasLabels then
			local quoted = {}
			for _, n in lazySensorList do
				table.insert(quoted, "'" .. n .. "'")
			end
			return false,
				string.format(
					"Ability '%s': RequiresToActivate uses only lazy sensor(s) %s "
						.. "with no labels or driven sensors to gate evaluation. "
						.. "This would force the lazy sensor to poll every frame, defeating 'Lazy' mode. "
						.. "Fix: set the sensor mode to 'Polled', add a 'subscribe' (Reactive), "
						.. "or activate this ability manually with ActivateAbility().",
					definition.Name,
					table.concat(quoted, ", ")
				)
		end
	end

	-- Validate CanSleep property
	if definition.CanSleep ~= nil and type(definition.CanSleep) ~= "boolean" then
		return false, "CanSleep must be a boolean (true or false)"
	end

	-- Validate CanSleep logic
	if definition.CanSleep == false and not definition.OnStep then
		return false,
			string.format(
				"Ability '%s' has CanSleep = false but no OnStep function. "
					.. "If an ability cannot sleep, it must have an OnStep function to run.",
				definition.Name
			)
	end

	-- Validate DefaultConfig
	if definition.DefaultConfig ~= nil then
		if type(definition.DefaultConfig) ~= "table" then
			return false,
				string.format(
					"Ability '%s': DefaultConfig must be a table, got %s.",
					definition.Name,
					type(definition.DefaultConfig)
				)
		end
		for key in definition.DefaultConfig do
			if type(key) ~= "string" then
				return false, string.format("Ability '%s': DefaultConfig keys must be strings.", definition.Name)
			end
			if RESERVED_KEYS[key] then
				return false,
					string.format(
						"Ability '%s': DefaultConfig cannot use reserved key '%s'. "
							.. "This key is managed by the engine.",
						definition.Name,
						key
					)
			end
		end
	end

	-- Validate DefaultState
	if definition.DefaultState ~= nil then
		if type(definition.DefaultState) ~= "table" then
			return false,
				string.format(
					"Ability '%s': DefaultState must be a table, got %s.",
					definition.Name,
					type(definition.DefaultState)
				)
		end
		for key in definition.DefaultState do
			if type(key) ~= "string" then
				return false, string.format("Ability '%s': DefaultState keys must be strings.", definition.Name)
			end
			if RESERVED_KEYS[key] then
				return false,
					string.format(
						"Ability '%s': DefaultState cannot use reserved key '%s'. "
							.. "This key is managed by the engine.",
						definition.Name,
						key
					)
			end
		end

		-- Check for key collisions between DefaultConfig and DefaultState
		if definition.DefaultConfig then
			for key in definition.DefaultState do
				if definition.DefaultConfig[key] ~= nil then
					return false,
						string.format(
							"Ability '%s': Key '%s' appears in both DefaultConfig and DefaultState. "
								.. "Each key must belong to exactly one namespace.",
							definition.Name,
							key
						)
				end
			end
		end
	end

	-- NOTE: StepSensors are validated after OnSetup via validateStepSensors,
	-- because abilities may register their own sensors during OnSetup.

	return true
end

-- Validates that all StepSensors reference registered sensors.
-- Called after OnSetup so abilities can register sensors during setup.
function AbilityValidator.validateStepSensors(
	definition: Types.AbilityDefinition,
	knownSensorNames: { [string]: string } -- name -> mode
): (boolean, string?)
	if not definition.StepSensors then
		return true
	end

	for _, sensorName in definition.StepSensors do
		if type(sensorName) ~= "string" then
			return false, string.format("Ability '%s': StepSensors must contain only strings.", definition.Name)
		end
		if not knownSensorNames[sensorName] then
			return false,
				string.format(
					"Ability '%s': StepSensor '%s' is not a registered sensor. "
						.. "Register the sensor before adding this ability or in OnSetup, or check for typos.",
					definition.Name,
					sensorName
				)
		end
	end

	return true
end

return AbilityValidator
