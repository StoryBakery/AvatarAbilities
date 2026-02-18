--!strict
--[[
	StateProxy
	==========
	A cached, dirty-tracking proxy for a dedicated Configuration instance.
	Used by abilities to read/write synced state efficiently during the frame.

	All attributes on the backing Configuration belong to this proxy.
	Config keys live on a separate parent Configuration — no casing conventions needed.
]]

local StateProxy = {}

export type StateProxy = typeof(setmetatable(
	{} :: {
		_config: Configuration,
		_cache: { [string]: any },
		_dirty: { [string]: boolean },
	},
	StateProxy
))

function StateProxy.new(config: Configuration, defaults: { [string]: any }?): StateProxy
	local self = setmetatable({
		_config = config,
		_cache = {},
		_dirty = {},
	}, StateProxy)

	-- 1. Load defaults
	if defaults then
		for k, v in pairs(defaults) do
			self._cache[k] = v
		end
	end

	-- 2. Override with existing attributes from DataModel
	-- (Server might have replicated state before we initialized)
	for k, v in pairs(config:GetAttributes()) do
		self._cache[k] = v
	end

	return self
end

-- Read: method lookup first, then cache
function StateProxy:__index(key: string): any
	if StateProxy[key] then
		return StateProxy[key]
	end
	return rawget(self, "_cache")[key]
end

-- Write: cache + mark dirty
function StateProxy:__newindex(key: string, value: any)
	local cache = rawget(self, "_cache")
	if cache[key] == value then
		return
	end

	cache[key] = value
	rawget(self, "_dirty")[key] = true
end

-- Flush dirty values to DataModel (called at end of Step)
function StateProxy:_flush()
	local config = rawget(self, "_config")
	local dirty = rawget(self, "_dirty")
	local cache = rawget(self, "_cache")

	for key in pairs(dirty) do
		config:SetAttribute(key, cache[key])
	end
	table.clear(dirty)
end

-- Re-read from DataModel (called when server rollback detected)
function StateProxy:_reconcile()
	local config = rawget(self, "_config")
	local cache = rawget(self, "_cache")

	for k, v in pairs(config:GetAttributes()) do
		cache[k] = v
	end

	table.clear(rawget(self, "_dirty"))
end

return StateProxy
