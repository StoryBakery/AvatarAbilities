--!native
--!strict
--[[
	SurfaceRaycast
	--------------
	Shared utility for raycasting to find surface points on assemblies.
	Uses BasePart:GetClosestPointOnSurface() on the raycast hit position
	for more accurate grip positioning.

	Original problem: Multiple files (ProximitySensor, GrabAbilityInputBinder)
	had duplicated raycast-to-surface logic. This consolidates that logic
	into one place.
]]

export type SurfaceHit = {
	part: BasePart,
	position: Vector3,
	localCFrame: CFrame,
}

-- Core raycast logic with surface refinement
local function doRaycast(assemblyParts: { BasePart }, origin: Vector3, direction: Vector3): SurfaceHit?
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = assemblyParts :: { Instance }

	local rayResult = workspace:Raycast(origin, direction, params)
	if rayResult and rayResult.Instance and rayResult.Instance:IsA("BasePart") then
		local hitPart = rayResult.Instance :: BasePart
		-- Refine the hit position to the closest point on the part's surface
		local hitPos = hitPart:GetClosestPointOnSurface(rayResult.Position)

		local localCF = hitPart.CFrame:ToObjectSpace(CFrame.new(hitPos))
		return {
			part = hitPart,
			position = hitPos,
			localCFrame = localCF,
		}
	end

	return nil
end

-- Raycast from origin toward target, filtering to only hit assembly parts.
-- Returns nil if no hit, otherwise returns the hit part, refined position, and local CFrame.
local function raycastToSurface(assemblyParts: { BasePart }, origin: Vector3, targetPos: Vector3): SurfaceHit?
	local direction = targetPos - origin
	if direction.Magnitude < 0.001 then
		return nil
	end
	return doRaycast(assemblyParts, origin, direction.Unit * (direction.Magnitude + 8))
end

-- Raycast from origin in a specific direction, filtering to only hit assembly parts.
-- Use this when you have a direction vector rather than a target position.
local function raycastToSurfaceWithDirection(
	assemblyParts: { BasePart },
	origin: Vector3,
	direction: Vector3
): SurfaceHit?
	if direction.Magnitude < 0.001 then
		return nil
	end
	return doRaycast(assemblyParts, origin, direction)
end

return {
	raycastToSurface = raycastToSurface,
	raycastToSurfaceWithDirection = raycastToSurfaceWithDirection,
}
