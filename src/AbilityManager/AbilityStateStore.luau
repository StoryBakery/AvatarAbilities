--!native
--[[
	AbilityStateStore
	-----------------
	Authoritative state container for the Ability System.
	Handles records, bitmasks, transaction logging, and internal signals.

	ActiveMask is stored as two plain numbers (Lo/Hi) for zero-allocation hot paths.
	On activate the mask is updated incrementally (O(1)).
	On deactivate the mask is fully recalculated (O(n)) since a bit cannot be
	safely cleared without knowing whether another active ability shares it.
]]

local AbilityStateStore = {}
AbilityStateStore.__index = AbilityStateStore

local AbilityUtils = require("./AbilityUtils")

function AbilityStateStore.new()
	local self = setmetatable({}, AbilityStateStore)

	self.RecordsByName = {}
	self.Settings = {}

	self.Cache = {
		Version = 0,
		ActiveAbilities = {},
		InactiveAbilities = {},
		GroupWinners = {},
		ActiveMaskLo = 0,
		ActiveMaskHi = 0,
		ContinuousCandidates = {},
		NonSleepableCount = 0,
	}

	self.DirtyList = {}
	self.InitialStateMap = {}

	self.AbilityActiveChanged = AbilityUtils.createSignal()
	self.AbilityEnabledChanged = AbilityUtils.createSignal()
	self.AbilityConfigChanged = AbilityUtils.createSignal()

	return self
end

function AbilityStateStore:_RecalculateCandidates()
	local candidates = self.Cache.ContinuousCandidates
	table.clear(candidates)

	local maskLo = self.Cache.ActiveMaskLo
	local maskHi = self.Cache.ActiveMaskHi
	local inactive = self.Cache.InactiveAbilities

	for i = 1, #inactive do
		local record = inactive[i]
		-- Filter: Must be Automatic AND satisfy current labels
		if record._isAutomatic and AbilityUtils.checkLabels(record._compiledActivation, maskLo, maskHi) then
			table.insert(candidates, record)
		end
	end
end

-- Full recalculation from the active list. Only called on deactivate.
function AbilityStateStore:_RecalculateActiveMask()
	local lo: number = 0
	local hi: number = 0
	local active = self.Cache.ActiveAbilities
	for i = 1, #active do
		local rec = active[i]
		lo = bit32.bor(lo, rec._maskSelfLo)
		hi = bit32.bor(hi, rec._maskSelfHi)
	end
	self.Cache.ActiveMaskLo = lo
	self.Cache.ActiveMaskHi = hi
end

function AbilityStateStore:SetAbilityActive(name: string, active: boolean)
	local record = self.RecordsByName[name]
	if not record or record.IsActive == active then
		return
	end

	if self.InitialStateMap[record] == nil then
		self.InitialStateMap[record] = record.IsActive
		table.insert(self.DirtyList, record)
	end

	record.IsActive = active

	if active then
		record.TimeLastActive = time()

		local inserted = false
		for i = 1, #self.Cache.ActiveAbilities do
			if AbilityUtils.shouldPrioritize(record, self.Cache.ActiveAbilities[i]) then
				table.insert(self.Cache.ActiveAbilities, i, record)
				inserted = true
				break
			end
		end
		if not inserted then
			table.insert(self.Cache.ActiveAbilities, record)
		end

		local idx = table.find(self.Cache.InactiveAbilities, record)
		if idx then
			table.remove(self.Cache.InactiveAbilities, idx)
		end

		if record.GroupID then
			self.Cache.GroupWinners[record.GroupID] = record
		end
		if record._canSleep == false then
			self.Cache.NonSleepableCount += 1
		end

		-- O(1): bor in the new record's bits
		self.Cache.ActiveMaskLo = bit32.bor(self.Cache.ActiveMaskLo, record._maskSelfLo)
		self.Cache.ActiveMaskHi = bit32.bor(self.Cache.ActiveMaskHi, record._maskSelfHi)
	else
		record.TimeLastInactive = time()

		if record._canSleep == false and self.Cache.NonSleepableCount > 0 then
			self.Cache.NonSleepableCount -= 1
		end

		local idx = table.find(self.Cache.ActiveAbilities, record)
		if idx then
			table.remove(self.Cache.ActiveAbilities, idx)
		end

		if record.IsEnabled and not table.find(self.Cache.InactiveAbilities, record) then
			table.insert(self.Cache.InactiveAbilities, record)
			table.sort(self.Cache.InactiveAbilities, AbilityUtils.sortByPriorityDesc)
		end

		if record.GroupID and self.Cache.GroupWinners[record.GroupID] == record then
			self.Cache.GroupWinners[record.GroupID] = nil
		end

		-- O(n): must recalculate because another active ability may share the same bits
		self:_RecalculateActiveMask()
	end

	self:_RecalculateCandidates()

	self.Cache.Version += 1
	self.AbilityActiveChanged:Fire(name, active)
end

function AbilityStateStore:SetAbilityEnabled(name: string, enabled: boolean)
	local record = self.RecordsByName[name]
	if not record or record.IsEnabled == enabled then
		return
	end

	record.IsEnabled = enabled

	if enabled then
		if not record.IsActive and not table.find(self.Cache.InactiveAbilities, record) then
			table.insert(self.Cache.InactiveAbilities, record)
			table.sort(self.Cache.InactiveAbilities, AbilityUtils.sortByPriorityDesc)
		end
	else
		local idx = table.find(self.Cache.InactiveAbilities, record)
		if idx then
			table.remove(self.Cache.InactiveAbilities, idx)
		end
	end

	self:_RecalculateCandidates()
	self.Cache.Version += 1
	self.AbilityEnabledChanged:Fire(name, enabled)
end

function AbilityStateStore:NotifyConfigChanged(name: string)
	self.AbilityConfigChanged:Fire(name)
end

function AbilityStateStore:AddAbility(record)
	if self.RecordsByName[record.Name] then
		return
	end
	self.RecordsByName[record.Name] = record

	if record.IsEnabled and not record.IsActive and record._isAutomatic then
		if AbilityUtils.checkLabels(record._compiledActivation, self.Cache.ActiveMaskLo, self.Cache.ActiveMaskHi) then
			table.insert(self.Cache.ContinuousCandidates, record)
			table.sort(self.Cache.ContinuousCandidates, AbilityUtils.sortByPriorityDesc)
		end
	end

	self.Cache.Version += 1
end

function AbilityStateStore:RemoveAbility(name: string)
	local record = self.RecordsByName[name]
	if not record then
		return
	end

	if record.IsActive then
		self:SetAbilityActive(name, false)
	end

	self.RecordsByName[name] = nil
	self.InitialStateMap[record] = nil
	self.Settings[name] = nil

	local idx = table.find(self.Cache.InactiveAbilities, record)
	if idx then
		table.remove(self.Cache.InactiveAbilities, idx)
	end

	local cIdx = table.find(self.Cache.ContinuousCandidates, record)
	if cIdx then
		table.remove(self.Cache.ContinuousCandidates, cIdx)
	end

	self.Cache.Version += 1
end

function AbilityStateStore:EndFrame(signals)
	local dirtyList = self.DirtyList
	local n = #dirtyList
	if n == 0 then
		return
	end

	local initialStateMap = self.InitialStateMap
	local deactivated = signals.AbilityDeactivated
	local activated = signals.AbilityActivated

	for i = 1, n do
		local record = dirtyList[i]
		if initialStateMap[record] ~= record.IsActive and not record.IsActive then
			deactivated:Fire(record.Definition)
		end
	end
	for i = 1, n do
		local record = dirtyList[i]
		if initialStateMap[record] ~= record.IsActive and record.IsActive then
			activated:Fire(record.Definition)
		end
	end

	table.clear(dirtyList)
	table.clear(initialStateMap)
end

-- Getters
function AbilityStateStore:GetActiveDefinitions()
	local out = {}
	for i = 1, #self.Cache.ActiveAbilities do
		out[i] = self.Cache.ActiveAbilities[i].Definition
	end
	return out
end

function AbilityStateStore:GetSetting(name, setting)
	local s = self.Settings[name]
	if s and s[setting] ~= nil then
		return s[setting]
	end
	local record = self.RecordsByName[name]
	return record and record.Definition.DefaultSettings and record.Definition.DefaultSettings[setting]
end

function AbilityStateStore:SetSetting(name, setting, value)
	if not self.Settings[name] then
		self.Settings[name] = {}
	end
	self.Settings[name][setting] = value
end

function AbilityStateStore:Destroy()
	self.AbilityActiveChanged:Destroy()
	self.AbilityEnabledChanged:Destroy()
	self.AbilityConfigChanged:Destroy()
	table.clear(self.RecordsByName)
	table.clear(self.Cache.ActiveAbilities)
	table.clear(self.Cache.InactiveAbilities)
	table.clear(self.Cache.ContinuousCandidates)
	table.clear(self.Cache.GroupWinners)
	table.clear(self.DirtyList)
	table.clear(self.InitialStateMap)
end

return AbilityStateStore
