--[[ Uitlity library of math functions.
]]

local CONSTS = {
	-- Buffer to use in floating-point comparisons
	EPSILON = 1e-3,
}
table.freeze(CONSTS)

local MathUtil = {}

-- Returns true if two numbers are very close in value.
-- Necessary because floating-point numbers are not always exact.
function MathUtil.fuzzyEquals(val1: number, val2: number): boolean
	return math.abs(val1 - val2) < CONSTS.EPSILON
end

return MathUtil
