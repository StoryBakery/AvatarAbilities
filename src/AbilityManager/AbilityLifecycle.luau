--!native
--[=[
	AbilityLifecycle
	===========================================================================
	Manages the execution of user-defined callbacks when abilities 
	change state.
	Handles recursion guards and error safety to ensure the engine 
	remains stable even when user code throws errors.
]=]

local AbilityLifecycle = {}
local AbilityLifecycle_MT = { __index = AbilityLifecycle }

local MAX_RECURSION_DEPTH = 10

--[=[
	@param stateStore        The AbilityStateStore.
	@param baseContext       The BaseContext passed as the first argument to all callbacks.
	@param getFrameContext   Returns the current FrameContext (may be nil outside Step).
]=]
function AbilityLifecycle.new(stateStore: any, baseContext: any, getFrameContext: () -> any)
	local self = setmetatable({}, AbilityLifecycle_MT)

	self._store = stateStore
	self._baseContext = baseContext
	self._getFrameContext = getFrameContext
	self._recursionDepth = 0

	self._connections = {}

	self:_initialize()

	return self
end

function AbilityLifecycle:_initialize()
	-- Reacts to active state changes
	table.insert(
		self._connections,
		self._store.AbilityActiveChanged:Connect(function(name, active)
			-- Prevent stack overflows from infinite activation loops
			if self._recursionDepth > MAX_RECURSION_DEPTH then
				warn(
					string.format(
						"[AbilityManager] CRITICAL: Recursive state change detected for '%s'. Cycle broken.",
						name
					)
				)
				return
			end

			local record = self._store.RecordsByName[name]
			if not record then
				return
			end

			-- Resolve augmented state, falling back to legacy record.State
			local state = record._state or record.State

			-- Execute user-defined callbacks
			self._recursionDepth += 1
			local ok, err
			if active then
				if record.Definition.OnActivate then
					ok, err = pcall(record.Definition.OnActivate, self._baseContext, self._getFrameContext(), state)
				end
			else
				if record.Definition.OnDeactivate then
					ok, err = pcall(record.Definition.OnDeactivate, self._baseContext, self._getFrameContext(), state)
				end
			end
			self._recursionDepth -= 1

			if not ok and err then
				warn(
					string.format(
						"[AbilityManager] Error in %s for '%s': %s",
						if active then "OnActivate" else "OnDeactivate",
						name,
						tostring(err)
					)
				)
			end
		end)
	)
end

function AbilityLifecycle:Destroy()
	for _, connection in self._connections do
		connection:Disconnect()
	end
	table.clear(self._connections)

	self._store = nil
	self._baseContext = nil
	self._getFrameContext = nil
end

return AbilityLifecycle
