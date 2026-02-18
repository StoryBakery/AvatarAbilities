local R15_LADDER_DEPTH = 1.2 * 1.5

-- TODO: Move search distance updating to Humanoid shim
local HIP_HEIGHT_MULTIPLIER_WITH_FLOOR = 1.8
-- local HIP_HEIGHT_MULTIPLIER_WITHOUT_FLOOR = 1.4

local function findOrCreate(parent: Instance, name: string, className: string?)
	if not parent:FindFirstChild(name) then
		local newInst = Instance.new(className or name)
		newInst.Parent = parent
	end
end

local function createAndConfigureControllerManager(character: Model)
	-- Ensure all children of the character are loaded
	character.ModelStreamingMode = Enum.ModelStreamingMode.Atomic

	local hipHeight = 4

	-- Safety check in case a respawn causes Actor threads to not update in
	-- time
	while not character.PrimaryPart do
		character:GetPropertyChangedSignal("PrimaryPart"):Wait()
	end

	local rootPart = character.PrimaryPart
	local humanoid = character:FindFirstChildWhichIsA("Humanoid")
	if humanoid then
		hipHeight = humanoid.HipHeight
		rootPart = humanoid.RootPart

		-- Ensure humanoid is properly setup for control
		humanoid.EvaluateStateMachine = false
	end

	if not rootPart then
		warn(`{character:GetFullName()} does not have a root part!`)
		return
	end

	local controllerManager = character:FindFirstChildWhichIsA("ControllerManager") or Instance.new("ControllerManager")

	-- Ground Sensor
	local floorSensor = controllerManager.GroundSensor
	if not floorSensor then
		floorSensor = Instance.new("ControllerPartSensor")
		floorSensor.Name = "FloorSensor"
		floorSensor.SensorMode = Enum.SensorMode.Floor
		floorSensor.UpdateType = Enum.SensorUpdateType.OnRead
	end
	if humanoid then
		floorSensor.SearchDistance = hipHeight * HIP_HEIGHT_MULTIPLIER_WITH_FLOOR
	end
	floorSensor.Parent = rootPart

	-- Ladder Sensor
	local ladderSensor = controllerManager.ClimbSensor
	if not ladderSensor then
		ladderSensor = Instance.new("ControllerPartSensor")
		ladderSensor.Name = "LadderSensor"
		ladderSensor.SensorMode = Enum.SensorMode.Ladder
	end
	if humanoid then
		ladderSensor.SearchDistance = R15_LADDER_DEPTH * character:GetScale()
	end
	ladderSensor.Parent = rootPart

	-- Ground Controller
	local groundController = controllerManager:FindFirstChild("GroundController") :: GroundController
	if not groundController then
		groundController = Instance.new("GroundController")
	end
	if humanoid then
		groundController.GroundOffset = hipHeight
	end
	groundController.Parent = controllerManager

	-- Buoyancy Sensor
	findOrCreate(rootPart, "BuoyancySensor")

	-- Other controllers
	findOrCreate(controllerManager, "AirController")
	findOrCreate(controllerManager, "SwimController")
	findOrCreate(controllerManager, "ClimbController")

	-- Put RootPart into collision group
	rootPart.CollisionGroup = "CharacterRootParts"

	controllerManager.RootPart = rootPart
	controllerManager.GroundSensor = floorSensor
	controllerManager.ClimbSensor = ladderSensor
	controllerManager.ActiveController = groundController

	controllerManager.Parent = character
end

return createAndConfigureControllerManager
