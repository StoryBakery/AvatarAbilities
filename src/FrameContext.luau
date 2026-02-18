-- src/packages/AvatarAbilities/FrameContext.luau

local FrameContext = {}

function FrameContext.new()
	return {
		-- Calculated Inputs
		deltaTime = 0,
		move2d = Vector2.zero,
		look = Vector3.zAxis,
		move3d = Vector3.zero,

		-- Cached Physics Data
		rootCFrame = CFrame.identity,
		rootPos = Vector3.zero,
		rootLook = Vector3.zAxis,
		rootUp = Vector3.yAxis,
	}
end

return FrameContext
