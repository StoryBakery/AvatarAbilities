-- WaterSurfaceSensor: This is a more limited version of WaterSensor, only
-- Firing if the character is at the surface of water.

function MakeWaterSurfaceSensor(rootPart: BasePart?)
	-- Resolve once at creation, not every frame
	local buoyancySensor = rootPart and rootPart:FindFirstChild("BuoyancySensor")

	return function()
		if not buoyancySensor or not buoyancySensor:IsA("BuoyancySensor") then
			-- Retry once if it wasn't ready at creation time
			buoyancySensor = rootPart and rootPart:FindFirstChild("BuoyancySensor")
			if not buoyancySensor then
				return false
			end
		end
		return buoyancySensor.TouchingSurface and not buoyancySensor.FullySubmerged
	end
end

return MakeWaterSurfaceSensor
