--!native
--!strict
--[[
	DataModelBinding
	================
	Manages the DataModel representation of abilities (Abilities folder).
	Handles:
	1. Ability Lifecycle (Configuration added/removed)
	2. Active State Sync (Folder attributes <-> StateStore)
	3. Augmented State Construction (state.Config + state.Synced)
	4. SAuth Loop (Reconcile -> Step -> Flush)

	DataModel Layout
	----------------
	AbilityManagerActor/
	  Abilities/                          -- Folder (active state as boolean attributes)
	    Running                           -- Configuration: Config keys + Enabled
	      SyncedState                     -- Configuration: Synced state keys
	    Jumping
	      SyncedState

	Augmented State Architecture
	----------------------------
	Each ability receives a single `state` table injected by the engine:
	  state.Config  - Read-only frozen table. All attributes on the ability's Configuration
	                   (excluding Enabled). Tunable in the Explorer.
	  state.Synced  - Read-write StateProxy backed by the child SyncedState Configuration.
	                   Dirty-tracked, flushed to attributes each frame.
	  state.*       - Ephemeral user fields (anything the ability stores directly, in-memory only).

	Config and Synced keys live on separate instances so there are no naming
	conventions or casing rules - any valid attribute name works in either namespace.
]]

local StateProxy = require("./StateProxy")
local Types = require("./Types")

local SYNCED_CHILD_NAME = "SyncedState"

export type AuthorityMode = "Server" | "Client" | "Shared"

local DataModelBinding = {}
DataModelBinding.__index = DataModelBinding

type AbilityRecord = any -- InternalTypes.AbilityRecord

function DataModelBinding.new(owner: Instance, actor: Actor, stateStore: any, authorityMode: AuthorityMode?)
	local self = setmetatable({}, DataModelBinding)

	self._owner = owner
	self._actor = actor
	self._store = stateStore
	self._authorityMode = authorityMode or "Client"

	-- StateProxy instances keyed by ability name (for Reconcile/Flush)
	self._proxies = {} :: { [string]: any }

	-- Config binding data keyed by ability name (for live Config reconciliation)
	-- Each entry: { state: AbilityState, defaultConfig: {}, configInstance: Configuration }
	self._configBindings = {} :: { [string]: { state: any, defaultConfig: {}, configInstance: Configuration } }

	-- Connections per ability for cleanup on unbind
	self._connections = {} :: { [string]: { RBXScriptConnection } }

	-- Dirty flags for reconciliation; avoids reading GetAttributes() every frame
	self._needsActiveReconcile = false
	self._proxyReconcileDirty = {} :: { [string]: boolean }

	-- Find or create Abilities folder
	local folder = actor:FindFirstChild("Abilities")
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = "Abilities"
		folder.Parent = actor
	end
	self._folder = folder

	-- Outbound Sync: StateStore -> Folder Attributes (Active State)
	self._outboundConn = self._store.AbilityActiveChanged:Connect(function(name, active)
		-- Only write if different to avoid signal noise
		if self._folder:GetAttribute(name) ~= active then
			self._folder:SetAttribute(name, active)
		end
	end)

	-- Inbound Sync: Folder Attributes -> StateStore (Server rollback)
	self._inboundConn = self._folder.AttributeChanged:Connect(function(attr)
		local val = self._folder:GetAttribute(attr)
		if type(val) == "boolean" then
			--[=[ 
				Defer State Updates
				Replication signals fire sequentially. Even if data arrives in the same packet, 
				processing updates immediately causes transient illegal states (e.g. A=true, B=old).
				
				We flag for ReconcileAll() to batch these updates, ensuring the engine 
				processes the final, consistent state for this frame.
			]=]
			self._needsActiveReconcile = true
		end
	end)

	return self
end

--[=[
	Rebuilds a frozen Config table from defaults + current DataModel attributes.
	Skips the "Enabled" attribute which is managed separately.
]=]
function DataModelBinding:_rebuildConfig(configInstance: Configuration, defaultConfig: {}): {}
	local configData = table.clone(defaultConfig)
	for k, v in pairs(configInstance:GetAttributes()) do
		if k ~= "Enabled" then
			configData[k] = v
		end
	end
	return table.freeze(configData)
end

--[=[
	Called when an ability is compiled and added to the store.
	Builds the Augmented State table and returns it with the initial enabled value.

	Creates two Configuration instances:
	  - The ability Configuration itself holds Config keys + Enabled.
	  - A child "SyncedState" Configuration holds Synced state keys.

	@return state   The augmented state table with .Config and .Synced injected.
	@return enabled The initial enabled state from the DataModel.
]=]
function DataModelBinding:BindAbility(
	record: AbilityRecord,
	defaultConfig: {},
	defaultState: {}
): (Types.AbilityState, boolean)
	local name = record.Name

	-- Find or create the ability's Configuration (holds Config + Enabled)
	local configInstance = self._folder:FindFirstChild(name)
	if not configInstance then
		configInstance = Instance.new("Configuration")
		configInstance.Name = name
		configInstance.Parent = self._folder
	end
	record.ConfigInstance = configInstance

	-- Find or create the child SyncedState Configuration
	local syncedInstance = configInstance:FindFirstChild(SYNCED_CHILD_NAME)
	if not syncedInstance then
		syncedInstance = Instance.new("Configuration")
		syncedInstance.Name = SYNCED_CHILD_NAME
		syncedInstance.Parent = configInstance
	end

	-- Build Config (Read-Only, Merged from defaults + DataModel attributes)
	local safeDefaults = defaultConfig or {}
	-- Write defaults back if missing (for inspector visibility)
	for k, v in pairs(safeDefaults) do
		if configInstance:GetAttribute(k) == nil then
			configInstance:SetAttribute(k, v)
		end
	end
	local frozenConfig = self:_rebuildConfig(configInstance, safeDefaults)

	-- Build Synced (Read-Write StateProxy backed by the child Configuration)
	local proxy = StateProxy.new(syncedInstance, defaultState)
	self._proxies[name] = proxy

	-- Build Augmented State (plain table, no metatables)
	local state: Types.AbilityState = {
		Config = frozenConfig,
		Synced = proxy,
	}

	-- Store config binding so we can rebuild Config on attribute changes
	self._configBindings[name] = {
		state = state,
		defaultConfig = safeDefaults,
		configInstance = configInstance,
	}

	-- Listen for Config attribute changes on the ability's Configuration.
	-- Every attribute here is a Config key except Enabled.
	local configConn = configInstance.AttributeChanged:Connect(function(attr)
		if attr == "Enabled" then
			return -- Handled by the dedicated Enabled signal below
		end

		local binding = self._configBindings[name]
		if binding then
			binding.state.Config = self:_rebuildConfig(binding.configInstance, binding.defaultConfig)
			record._needsStep = true
			self._store:NotifyConfigChanged(name)
		end
	end)

	-- Listen for Synced attribute changes on the child Configuration.
	-- Every attribute here is a Synced state key.
	-- Compare against the proxy cache to distinguish our own flushes from
	-- server rollbacks. If the value differs, mark for reconcile.
	local syncedConn = syncedInstance.AttributeChanged:Connect(function(attr)
		local currentProxy = self._proxies[name]
		if currentProxy then
			local newVal = syncedInstance:GetAttribute(attr)
			if rawget(currentProxy, "_cache")[attr] ~= newVal then
				self._proxyReconcileDirty[name] = true
			end
		end
	end)

	-- Initial Enabled State
	local enabled = configInstance:GetAttribute("Enabled")
	if enabled == nil then
		enabled = true
		configInstance:SetAttribute("Enabled", true)
	end

	-- Listen for Enabled changes (Runtime toggle)
	local enabledConn = configInstance:GetAttributeChangedSignal("Enabled"):Connect(function()
		self._store:SetAbilityEnabled(name, configInstance:GetAttribute("Enabled") == true)
	end)

	-- Track all connections for cleanup
	self._connections[name] = { configConn, syncedConn, enabledConn }

	return state, enabled
end

-- Cleanup when an ability is removed
function DataModelBinding:UnbindAbility(name: string)
	-- Disconnect all listeners for this ability
	local conns = self._connections[name]
	if conns then
		for _, conn in conns do
			conn:Disconnect()
		end
	end

	self._connections[name] = nil
	self._proxies[name] = nil
	self._configBindings[name] = nil
	self._proxyReconcileDirty[name] = nil
end

--[=[
	SAuth: Read authoritative state from the DataModel before logic runs.
	Only performs work when external changes have been detected via AttributeChanged.
	When nothing changed since last frame, this is a no-op.
]=]
function DataModelBinding:ReconcileAll()
	-- 1. Reconcile Active State (only if folder attributes changed externally)
	if self._needsActiveReconcile then
		self._needsActiveReconcile = false
		for name, val in pairs(self._folder:GetAttributes()) do
			local record = self._store.RecordsByName[name]
			if record then
				local isActive = val == true
				if record.IsActive ~= isActive then
					self._store:SetAbilityActive(name, isActive)
				end
			end
		end
	end

	-- 2. Reconcile Synced State (only proxies with external changes)
	local dirty = self._proxyReconcileDirty
	if next(dirty) then
		for name in pairs(dirty) do
			local proxy = self._proxies[name]
			if proxy then
				proxy:_reconcile()
			end
		end
		table.clear(dirty)
	end
end

-- SAuth: Write predicted/authoritative attributes after logic runs.
-- Only proxies with dirty keys will call SetAttribute; clean proxies are a no-op.
function DataModelBinding:FlushAll()
	for _, proxy in pairs(self._proxies) do
		proxy:_flush()
	end
end

-- Cleanup
function DataModelBinding:Destroy()
	-- Disconnect constructor-level connections
	if self._outboundConn then
		self._outboundConn:Disconnect()
		self._outboundConn = nil
	end
	if self._inboundConn then
		self._inboundConn:Disconnect()
		self._inboundConn = nil
	end

	-- Disconnect all per-ability connections
	for _, conns in self._connections do
		for _, conn in conns do
			conn:Disconnect()
		end
	end

	table.clear(self._connections)
	table.clear(self._proxies)
	table.clear(self._configBindings)
	table.clear(self._proxyReconcileDirty)
	self._store = nil
end

return DataModelBinding
