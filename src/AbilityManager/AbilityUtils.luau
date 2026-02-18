--!native
--[[
	AbilityUtils
	============
	Shared utilities for bitmask operations, logic compilation, and signal creation.

	All bitmask operations use two plain numbers (Lo = bits 0-31, Hi = bits 32-63).
	Maximum 64 labels supported. Zero table allocations on hot paths.
]]

local AbilityUtils = {}

local InternalTypes = require("./InternalTypes")
local Types = require("./Types")

type AbilityRecord = InternalTypes.AbilityRecord
type LogicVariant = InternalTypes.LogicVariant

AbilityUtils.DEBUG_SENSORS = false

-- [Low-Level Helpers]

function AbilityUtils.createSignal()
	local listeners = {}

	return {
		-- NOTE: Listeners must not disconnect themselves during Fire.
		-- Doing so shifts the array and may skip the next listener.
		Fire = function(_, ...)
			for _, callback in listeners do
				local ok, err = pcall(callback, ...)
				if not ok then
					warn(string.format("[AbilityManager] Signal listener error: %s", tostring(err)))
				end
			end
		end,

		Connect = function(_, callback)
			table.insert(listeners, callback)
			return {
				Disconnect = function(self)
					if not self.Connected then
						return
					end
					self.Connected = false
					local index = table.find(listeners, callback)
					if index then
						table.remove(listeners, index)
					end
				end,
				Connected = true,
			}
		end,

		Destroy = function(_)
			table.clear(listeners)
		end,
	}
end

-- [Bitmask Operations]
-- All masks are two plain numbers: Lo (bits 0-31) and Hi (bits 32-63).
-- Local functions for inlining by the native compiler.

-- Returns true if (mask AND required) == required AND (mask AND notRequired) == 0
local function masksMatch(
	maskLo: number,
	maskHi: number,
	reqLo: number,
	reqHi: number,
	notLo: number,
	notHi: number
): boolean
	return bit32.band(maskLo, reqLo) == reqLo
		and bit32.band(maskLo, notLo) == 0
		and bit32.band(maskHi, reqHi) == reqHi
		and bit32.band(maskHi, notHi) == 0
end

-- Returns true if intersection > 0
local function btest(aLo: number, aHi: number, bLo: number, bHi: number): boolean
	return bit32.band(aLo, bLo) ~= 0 or bit32.band(aHi, bHi) ~= 0
end

-- Returns true if a compiled variant's label requirements are satisfied by the active mask.
local function variantLabelsPass(v, maskLo: number, maskHi: number): boolean
	return bit32.band(maskLo, v.mustHaveLo) == v.mustHaveLo
		and bit32.band(maskLo, v.mustNotLo) == 0
		and bit32.band(maskHi, v.mustHaveHi) == v.mustHaveHi
		and bit32.band(maskHi, v.mustNotHi) == 0
end

-- [Logic Checking]

-- Fast check for Label validity ONLY.
-- Used by AbilityStateStore to pre-filter the Candidate List.
-- Returns true if ANY variant in the logic tree satisfies its bitmask requirements.
function AbilityUtils.checkLabels(compiled: InternalTypes.CompiledLogic?, maskLo: number, maskHi: number): boolean
	if not compiled then
		return true
	end

	for i = 1, compiled.variantCount do
		if variantLabelsPass(compiled.variants[i], maskLo, maskHi) then
			return true
		end
	end

	return false
end

-- Checks if the combined (label + sensor) requirements for a compiled rule are met.
-- Each variant must pass BOTH its label bitmask AND its sensor conditions.
-- This prevents a bug where OR rules with mixed label/sensor children could pass
-- by matching labels on one variant and sensors on a different variant.
function AbilityUtils.checkCompiled(compiled, maskLo: number, maskHi: number, sensorManager, frameCtx, debugLazyList)
	-- If the rule is nil, there are no requirements, so it passes by default.
	if not compiled then
		return true
	end

	-- Iterate through every variant in the compiled logic.
	-- Since this is Disjunctive Normal Form, if ANY variant passes, the whole rule passes.
	for i = 1, compiled.variantCount do
		local v = compiled.variants[i]

		-- Check label bitmask requirements for this variant.
		local pass = variantLabelsPass(v, maskLo, maskHi)

		-- Check positive sensors: these must return a truthy value.
		if pass then
			for s = 1, v.sensorCount do
				local name = v.sensorNames[s]
				if AbilityUtils.DEBUG_SENSORS and debugLazyList then
					debugLazyList[name] = true
				end

				-- If a required sensor is missing, this specific variant fails immediately.
				if not sensorManager:GetSensor(name, frameCtx) then
					pass = false
					break
				end
			end
		end

		-- Check inverted sensors: these must return a falsy value.
		if pass and v.invertedCount > 0 then
			for s = 1, v.invertedCount do
				local name = v.invertedNames[s]
				if AbilityUtils.DEBUG_SENSORS and debugLazyList then
					debugLazyList[name] = true
				end

				-- If a forbidden sensor is present, this variant fails.
				if sensorManager:GetSensor(name, frameCtx) then
					pass = false
					break
				end
			end
		end

		-- If we found a valid variant, the entire requirement is met.
		if pass then
			return true
		end
	end

	-- If no variants were satisfied, the check fails.
	return false
end

-- [Logic Compilation]

local function mergeVariants(v1: LogicVariant, v2: LogicVariant): LogicVariant
	local combinedSensors = {}
	local seenSensors = {}

	for _, name in v1.sensorNames do
		if not seenSensors[name] then
			table.insert(combinedSensors, name)
			seenSensors[name] = true
		end
	end
	for _, name in v2.sensorNames do
		if not seenSensors[name] then
			table.insert(combinedSensors, name)
			seenSensors[name] = true
		end
	end

	local combinedInverted = {}
	local seenInverted = {}

	if v1.invertedSensorNames then
		for _, name in v1.invertedSensorNames do
			if not seenInverted[name] then
				table.insert(combinedInverted, name)
				seenInverted[name] = true
			end
		end
	end
	if v2.invertedSensorNames then
		for _, name in v2.invertedSensorNames do
			if not seenInverted[name] then
				table.insert(combinedInverted, name)
				seenInverted[name] = true
			end
		end
	end

	return {
		requiredLo = bit32.bor(v1.requiredLo, v2.requiredLo),
		requiredHi = bit32.bor(v1.requiredHi, v2.requiredHi),
		forbiddenLo = bit32.bor(v1.forbiddenLo, v2.forbiddenLo),
		forbiddenHi = bit32.bor(v1.forbiddenHi, v2.forbiddenHi),
		sensorNames = combinedSensors,
		invertedSensorNames = #combinedInverted > 0 and combinedInverted or nil,
	}
end

local MAX_VARIANTS = 32

function AbilityUtils.compileToVariants(
	rule: Types.Rule?,
	labelToBit: { [string]: number },
	nextBit: number,
	knownSensorNames: { [string]: boolean }?
): ({ LogicVariant }, number)
	if rule == nil then
		return {
			{
				requiredLo = 0,
				requiredHi = 0,
				forbiddenLo = 0,
				forbiddenHi = 0,
				sensorNames = {},
				invertedSensorNames = nil,
			},
		},
			nextBit
	end

	if type(rule) == "string" then
		if knownSensorNames and knownSensorNames[rule] then
			return {
				{
					requiredLo = 0,
					requiredHi = 0,
					forbiddenLo = 0,
					forbiddenHi = 0,
					sensorNames = { rule },
					invertedSensorNames = nil,
				},
			},
				nextBit
		else
			local mLo, mHi, _, _, nb = AbilityUtils.convertLabelsToMask({ rule }, labelToBit, nextBit)
			return {
				{
					requiredLo = mLo,
					requiredHi = mHi,
					forbiddenLo = 0,
					forbiddenHi = 0,
					sensorNames = {},
					invertedSensorNames = nil,
				},
			},
				nb
		end
	end

	local expr = rule :: Types.LogicExpr
	local typeName = expr.type

	if typeName == nil then
		typeName = "All"
		expr = { type = "All", children = rule :: { Types.Rule } }
	end

	if typeName == "Not" then
		local child = (expr :: Types.RuleInvert).child
		if type(child) == "string" then
			if knownSensorNames and knownSensorNames[child] then
				return {
					{
						requiredLo = 0,
						requiredHi = 0,
						forbiddenLo = 0,
						forbiddenHi = 0,
						sensorNames = {},
						invertedSensorNames = { child },
					},
				},
					nextBit
			else
				local mLo, mHi, _, _, nb = AbilityUtils.convertLabelsToMask({ child :: string }, labelToBit, nextBit)
				return {
					{
						requiredLo = 0,
						requiredHi = 0,
						forbiddenLo = mLo,
						forbiddenHi = mHi,
						sensorNames = {},
						invertedSensorNames = nil,
					},
				},
					nb
			end
		end
		error("[AbilityManager] 'Not' only supports simple strings.")
	elseif typeName == "Any" then
		local combined = {}
		for _, child in (expr :: Types.RuleGroup).children do
			local vars, nb = AbilityUtils.compileToVariants(child, labelToBit, nextBit, knownSensorNames)
			nextBit = nb
			for _, v in vars do
				table.insert(combined, v)
			end
		end
		if #combined > MAX_VARIANTS then
			error("[AbilityManager] Logic too complex (Any)")
		end
		return combined, nextBit
	elseif typeName == "All" then
		local current = {
			{
				requiredLo = 0,
				requiredHi = 0,
				forbiddenLo = 0,
				forbiddenHi = 0,
				sensorNames = {},
			},
		}
		for _, child in (expr :: Types.RuleGroup).children do
			local vars, nb = AbilityUtils.compileToVariants(child, labelToBit, nextBit, knownSensorNames)
			nextBit = nb
			local newVars = {}
			for _, existing in current do
				for _, incoming in vars do
					table.insert(newVars, mergeVariants(existing, incoming))
				end
			end
			if #newVars > MAX_VARIANTS then
				error("[AbilityManager] Logic too complex (All)")
			end
			current = newVars
		end
		return current, nextBit
	end

	error("[AbilityManager] Unknown Rule Type")
end

-- [Utility]

local function shouldPrioritize(abilityA: AbilityRecord, abilityB: AbilityRecord): boolean
	local priorityA = abilityA.Priority or 0
	local priorityB = abilityB.Priority or 0

	if priorityA ~= priorityB then
		return priorityA > priorityB
	end
	return abilityA.NameLower < abilityB.NameLower
end
AbilityUtils.shouldPrioritize = shouldPrioritize

function AbilityUtils.sortByPriorityDesc(recordA: AbilityRecord, recordB: AbilityRecord): boolean
	return shouldPrioritize(recordA, recordB)
end

--[[
	Converts a label list into flat lo/hi bitmask pairs.
	Returns: (maskLo, maskHi, notMaskLo, notMaskHi, nextBit)
	Errors if any label would exceed bit index 63.
]]
function AbilityUtils.convertLabelsToMask(
	rule: Types.Rule?,
	labelToBit: { [string]: number },
	nextBit: number
): (number, number, number, number, number)
	local maskLo: number = 0
	local maskHi: number = 0
	local notMaskLo: number = 0
	local notMaskHi: number = 0

	if not rule then
		return maskLo, maskHi, notMaskLo, notMaskHi, nextBit
	end

	local list: { Types.Rule }
	if type(rule) == "table" then
		local ruleTable = rule :: { [any]: any }
		if ruleTable.type == nil then
			list = rule :: { Types.Rule }
		else
			list = { rule }
		end
	else
		list = { rule }
	end

	for i = 1, #list do
		local item = list[i]
		local label = ""
		local isNot = false

		if type(item) == "string" then
			label = item
			isNot = false
		elseif type(item) == "table" then
			local expr = item :: Types.RuleInvert
			if expr.type == "Not" then
				if type(expr.child) ~= "string" then
					error("[AbilityManager] Blocks/Cancels 'Not' only supports simple strings.")
				end
				label = expr.child :: string
				isNot = true
			else
				error("[AbilityManager] Blocks/Cancels does not support complex logic (Any/All).")
			end
		else
			error("[AbilityManager] Invalid label type.")
		end

		local index = labelToBit[label]
		if index == nil then
			if nextBit >= 64 then
				error("[AbilityManager] Maximum of 64 labels exceeded. Cannot allocate label '" .. label .. "'.")
			end
			index = nextBit
			labelToBit[label] = index
			nextBit += 1
		end

		local bitValue: number
		if index < 32 then
			bitValue = bit32.lshift(1, index)
			if isNot then
				notMaskLo = bit32.bor(notMaskLo, bitValue)
			else
				maskLo = bit32.bor(maskLo, bitValue)
			end
		else
			bitValue = bit32.lshift(1, index - 32)
			if isNot then
				notMaskHi = bit32.bor(notMaskHi, bitValue)
			else
				maskHi = bit32.bor(maskHi, bitValue)
			end
		end
	end

	return maskLo, maskHi, notMaskLo, notMaskHi, nextBit
end

-- [Conflict Resolution]

function AbilityUtils.resolveConflicts(
	abilityRecord: AbilityRecord,
	activeRecords: { AbilityRecord },
	groupWinners: { [number]: AbilityRecord },
	outConflicts: { AbilityRecord }
): boolean
	local holderRecord = nil

	-- A. Channel Check (Exclusive Groups)
	if abilityRecord.GroupID then
		holderRecord = groupWinners[abilityRecord.GroupID]
		if holderRecord and holderRecord ~= abilityRecord and holderRecord.IsActive then
			local wins = shouldPrioritize(abilityRecord, holderRecord)

			if not wins then
				-- Check for explicit Cancels override
				local direct = btest(
					abilityRecord._cancelsMaskLo,
					abilityRecord._cancelsMaskHi,
					holderRecord._maskSelfLo,
					holderRecord._maskSelfHi
				)
				local inverse = false

				if abilityRecord._cancelsNotMaskLo ~= 0 or abilityRecord._cancelsNotMaskHi ~= 0 then
					inverse = masksMatch(
						holderRecord._maskSelfLo,
						holderRecord._maskSelfHi,
						0,
						0,
						abilityRecord._cancelsNotMaskLo,
						abilityRecord._cancelsNotMaskHi
					)
				end

				wins = direct or inverse
			end

			if wins then
				table.insert(outConflicts, holderRecord)
			else
				return false
			end
		end
	end

	-- B. Label Blocking/Canceling Check
	for i = 1, #activeRecords do
		local activeRecord = activeRecords[i]

		if not activeRecord.IsActive or activeRecord == abilityRecord then
			continue
		end

		-- Skip: already resolved in Group Check above
		if activeRecord == holderRecord then
			continue
		end

		-- Aggressive: Check if we cancel them (Bypass Blocks)
		local cancelsTarget = btest(
			abilityRecord._cancelsMaskLo,
			abilityRecord._cancelsMaskHi,
			activeRecord._maskSelfLo,
			activeRecord._maskSelfHi
		)
		if not cancelsTarget and (abilityRecord._cancelsNotMaskLo ~= 0 or abilityRecord._cancelsNotMaskHi ~= 0) then
			cancelsTarget = masksMatch(
				activeRecord._maskSelfLo,
				activeRecord._maskSelfHi,
				0,
				0,
				abilityRecord._cancelsNotMaskLo,
				abilityRecord._cancelsNotMaskHi
			)
		end

		if cancelsTarget then
			table.insert(outConflicts, activeRecord)
			continue
		end

		-- Gatekeeping: Check if they block us
		local isBlocked = btest(
			abilityRecord._maskSelfLo,
			abilityRecord._maskSelfHi,
			activeRecord._maskBlocksLo,
			activeRecord._maskBlocksHi
		)
		if not isBlocked and (activeRecord._maskBlocksNotLo ~= 0 or activeRecord._maskBlocksNotHi ~= 0) then
			isBlocked = masksMatch(
				abilityRecord._maskSelfLo,
				abilityRecord._maskSelfHi,
				0,
				0,
				activeRecord._maskBlocksNotLo,
				activeRecord._maskBlocksNotHi
			)
		end

		if isBlocked then
			return false
		end
	end
	return true
end

return AbilityUtils
