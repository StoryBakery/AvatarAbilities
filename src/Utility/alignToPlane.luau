--!native
-- Align a vector "toAlign" along a plane defined by a normal vector,
-- where the return value maintains the length of toAlign
local function alignToPlane(toAlign: Vector3, planeNormal: Vector3): Vector3
	if toAlign.Magnitude == 0 then
		return toAlign
	end

	local facing = toAlign:Dot(planeNormal)
	return (toAlign - planeNormal * facing).Unit * toAlign.Magnitude
end

return alignToPlane
