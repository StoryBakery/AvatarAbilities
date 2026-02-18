--!native
--[=[
	AbilityCompiler
	===============
	Transforms ability definitions into engine records.

	Responsibilities:
	1. Validation: Ensures definitions are well-formed
	2. Bitmask Compilation: Converts labels to lo/hi integer pairs (64-bit max)
	3. DNF Compilation: Converts logic rules to disjunctive normal form
	4. Sensor Analysis: Determines if ability is automatic vs manual
]=]

local AbilityCompiler = {}
local AbilityCompiler_MT = { __index = AbilityCompiler }

local AbilityUtils = require("./AbilityUtils")
local AbilityValidator = require("./AbilityValidator")
local Types = require("./Types")

-- ---------------------------------------------------------------------------
-- Constructor
-- ---------------------------------------------------------------------------

function AbilityCompiler.new(sensorManager: any)
	local self = setmetatable({}, AbilityCompiler_MT)

	self._sensorManager = sensorManager

	-- Label registry (string → bit index)
	self._labelToBit = {}
	self._nextBit = 0

	-- Group registry (name → numeric ID)
	self._groupIDs = {}
	self._nextGroupID = 1

	return self
end

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

function AbilityCompiler:_getKnownSensorNames(): { [string]: string }
	local known = {}
	for name, sensor in self._sensorManager:GetSensors() do
		if not sensor.getter then
			known[name] = "Discrete"
		else
			known[name] = sensor.mode or "Lazy"
		end
	end
	return known
end

--[=[
	Compiles a logic variant into the format expected by the engine.
	Reads flat lo/hi fields from the variant.
]=]
local function compileVariant(variant)
	local compiled = {
		-- Flattened bitmask values for fast checking
		mustHaveLo = variant.requiredLo or 0,
		mustHaveHi = variant.requiredHi or 0,
		mustNotLo = variant.forbiddenLo or 0,
		mustNotHi = variant.forbiddenHi or 0,

		-- Sensor names
		sensorNames = {},
		sensorCount = 0,
		invertedNames = {},
		invertedCount = 0,
	}

	-- Copy positive sensors
	if variant.sensorNames then
		for _, name in variant.sensorNames do
			compiled.sensorCount += 1
			compiled.sensorNames[compiled.sensorCount] = name
		end
	end

	-- Copy inverted sensors
	if variant.invertedSensorNames then
		for _, name in variant.invertedSensorNames do
			compiled.invertedCount += 1
			compiled.invertedNames[compiled.invertedCount] = name
		end
	end

	return compiled
end

--[=[
	Compiles a list of variants into engine format.
]=]
local function compileVariants(variants)
	if not variants then
		return nil
	end

	local compiled = {
		variants = {},
		variantCount = 0,
	}

	for _, variant in variants do
		compiled.variantCount += 1
		compiled.variants[compiled.variantCount] = compileVariant(variant)
	end

	return compiled
end

-- ---------------------------------------------------------------------------
-- Logic Compilation
-- ---------------------------------------------------------------------------

--[=[
	Compiles all logic rules for an ability record.
	Called on initial compile and when sensors are added.
]=]
function AbilityCompiler:RefreshLogic(record)
	local def = record.Definition
	local knownSensors = self:_getKnownSensorNames()

	-- Compile RequiresToActivate
	local actVars, newBit =
		AbilityUtils.compileToVariants(def.RequiresToActivate, self._labelToBit, self._nextBit, knownSensors)
	self._nextBit = newBit
	record._activationVariants = actVars
	record._compiledActivation = compileVariants(actVars)

	-- Compile RequiresToContinue
	if def.RequiresToContinue then
		local contVars, nb =
			AbilityUtils.compileToVariants(def.RequiresToContinue, self._labelToBit, self._nextBit, knownSensors)
		self._nextBit = nb
		record._continuationVariants = contVars
		record._compiledContinuation = compileVariants(contVars)
	else
		record._continuationVariants = nil
		record._compiledContinuation = nil
	end

	-- Compile CancelsOnActivation (returns flat lo/hi)
	local cLo, cHi, cNotLo, cNotHi, nb2 =
		AbilityUtils.convertLabelsToMask(def.CancelsOnActivation, self._labelToBit, self._nextBit)
	self._nextBit = nb2
	record._cancelsMaskLo = cLo
	record._cancelsMaskHi = cHi
	record._cancelsNotMaskLo = cNotLo
	record._cancelsNotMaskHi = cNotHi

	-- Analyze sensor dependencies to determine if automatic
	self:_analyzeSensorDependencies(record)
end

--[=[
	Determines if an ability should auto-activate based on its sensor usage.
	- Automatic: Uses labels or continuous sensors (polled every frame)
	- Manual: Uses only discrete sensors (triggered by events)
]=]
function AbilityCompiler:_analyzeSensorDependencies(record)
	local hasDiscreteSensors = false
	local hasContinuousSensors = false
	local hasLabelRequirements = false

	-- Check ALL variants for label requirements.
	-- Variant fields are always numbers (never nil) after compilation.
	if record._activationVariants then
		for _, v in record._activationVariants do
			if v.requiredLo ~= 0 or v.requiredHi ~= 0 or v.forbiddenLo ~= 0 or v.forbiddenHi ~= 0 then
				hasLabelRequirements = true
				break
			end
		end
	end

	-- Scan all variants for sensor types
	local function scanVariants(variants)
		if not variants then
			return
		end
		for _, v in variants do
			if v.sensorNames then
				for _, name in v.sensorNames do
					if self._sensorManager:IsDiscrete(name) then
						hasDiscreteSensors = true
					else
						hasContinuousSensors = true
					end
				end
			end
			if v.invertedSensorNames then
				for _, name in v.invertedSensorNames do
					if self._sensorManager:IsDiscrete(name) then
						hasDiscreteSensors = true
					else
						hasContinuousSensors = true
					end
				end
			end
		end
	end

	scanVariants(record._activationVariants)

	-- Automatic if:
	-- - Has label requirements, OR
	-- - Has continuous sensors
	-- NOT automatic if:
	-- - Only has discrete sensors, OR
	-- - Has no requirements at all
	local hasOnlyDiscrete = hasDiscreteSensors and not hasContinuousSensors
	local hasNoRequirements = not hasLabelRequirements and not hasDiscreteSensors and not hasContinuousSensors

	record._isAutomatic = not hasOnlyDiscrete and not hasNoRequirements
end

-- ---------------------------------------------------------------------------
-- Main Compile
-- ---------------------------------------------------------------------------

function AbilityCompiler:Compile(
	_owner: Instance,
	definition: Types.AbilityDefinition,
	recordsByName: { [string]: any }
): (boolean, any?, string?)
	local knownSensors = self:_getKnownSensorNames()

	-- Build existing names set for validation
	local existingNames = {}
	for name in recordsByName do
		existingNames[name] = true
	end

	-- Validate
	local isValid, errorMsg =
		AbilityValidator.validateDefinition(definition, existingNames, self._labelToBit, self._nextBit, knownSensors)

	if not isValid then
		return false, nil, errorMsg
	end

	-- Assign group ID
	local groupID = nil
	if definition.ExclusiveGroup then
		local groupName = definition.ExclusiveGroup.name
		groupID = self._groupIDs[groupName]
		if not groupID then
			groupID = self._nextGroupID
			self._groupIDs[groupName] = groupID
			self._nextGroupID += 1
		end
	end

	-- Create record
	-- NOTE: ConfigInstance, _stateProxy, _stateHandle, _temp, _ctx, _configTable
	-- are set later by DataModelBinding:BindAbility.
	local record = {
		Definition = definition,
		Name = definition.Name,
		NameLower = string.lower(definition.Name),
		Priority = (definition.ExclusiveGroup and definition.ExclusiveGroup.priority) or 0,
		GroupName = (definition.ExclusiveGroup and definition.ExclusiveGroup.name) or nil,
		GroupID = groupID,

		-- Must start false so that SetAbilityEnabled(name, true) passes
		-- the equality guard and adds the record to InactiveAbilities.
		IsEnabled = false,
		IsActive = false,
		State = {},
		TimeLastActive = 0,
		TimeLastInactive = 0,
		ConfigInstance = nil, -- Set by DataModelBinding:BindAbility

		-- Flags for engine
		_canSleep = definition.CanSleep ~= false,
		_onStepFunc = definition.OnStep,
		_stepSensors = definition.StepSensors,
	}

	-- Compile identity labels (flat lo/hi)
	local selfLo, selfHi, _, _, nb1 =
		AbilityUtils.convertLabelsToMask(definition.Labels, self._labelToBit, self._nextBit)
	self._nextBit = nb1
	record._maskSelfLo = selfLo
	record._maskSelfHi = selfHi

	-- Compile blocking labels (flat lo/hi)
	local bLo, bHi, bNotLo, bNotHi, nb2 =
		AbilityUtils.convertLabelsToMask(definition.BlocksWhileActive, self._labelToBit, self._nextBit)
	self._nextBit = nb2
	record._maskBlocksLo = bLo
	record._maskBlocksHi = bHi
	record._maskBlocksNotLo = bNotLo
	record._maskBlocksNotHi = bNotHi

	-- Compile logic rules
	self:RefreshLogic(record)

	return true, record, nil
end

return AbilityCompiler
