--[[ Utility method for determining if a character is considered to be upright
or not.
]]

local CONSTS = {
	-- If the unit up vector's Y is less than this value, then the avatar is
	-- considered to not be upright
	UP_UNIT_VECTOR_Y_THRESHOLD = 0.7,
}
table.freeze(CONSTS)

local function isTipped(rootUp): boolean
	return rootUp.Y < CONSTS.UP_UNIT_VECTOR_Y_THRESHOLD
end

return isTipped
