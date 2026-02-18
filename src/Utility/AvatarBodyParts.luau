--[[ Helper methods relating to the body parts of avatars.
]]

local CONSTS = {
	PARTS = {
		ROOT = "HumanoidRootPart",
		HEAD = "Head",
		L_FOOT = "LeftFoot",
		L_LOWER_LEG = "LeftLowerLeg",
		L_UPPER_LEG = "LeftUpperLeg",
		L_HAND = "LeftHand",
		L_LOWER_ARM = "LeftLowerArm",
		L_UPPER_ARM = "LeftUpperArm",
		R_FOOT = "RightFoot",
		R_LOWER_LEG = "RightLowerLeg",
		R_UPPER_LEG = "RightUpperLeg",
		R_HAND = "RightHand",
		R_LOWER_ARM = "RightLowerArm",
		R_UPPER_ARM = "RightUpperArm",
		LOWER_TORSO = "LowerTorso",
		UPPER_TORSO = "UpperTorso",
	},
}
table.freeze(CONSTS)

local AvatarBodyParts = {}

function AvatarBodyParts.SetPartsCollide(character: Instance, collide: boolean, parts)
	for _, partName in pairs(parts) do
		local part: Part = character:FindFirstChild(partName) :: Part
		if part then
			part.CanCollide = collide
		end
	end
end

function AvatarBodyParts.SetArmsCollide(character: Instance, collide: boolean)
	local parts = {
		CONSTS.PARTS.L_UPPER_ARM,
		CONSTS.PARTS.L_LOWER_ARM,
		CONSTS.PARTS.L_HAND,
		CONSTS.PARTS.R_UPPER_ARM,
		CONSTS.PARTS.R_LOWER_ARM,
		CONSTS.PARTS.R_HAND,
	}
	AvatarBodyParts.SetPartsCollide(character, collide, parts)
end

function AvatarBodyParts.SetLegsCollide(character: Instance, collide: boolean)
	local parts = {
		CONSTS.PARTS.L_UPPER_LEG,
		CONSTS.PARTS.L_LOWER_LEG,
		CONSTS.PARTS.L_FOOT,
		CONSTS.PARTS.R_UPPER_LEG,
		CONSTS.PARTS.R_LOWER_LEG,
		CONSTS.PARTS.R_FOOT,
	}
	AvatarBodyParts.SetPartsCollide(character, collide, parts)
end

function AvatarBodyParts.SetLimbsCollide(character: Instance, collide: boolean)
	AvatarBodyParts.SetArmsCollide(character, collide)
	AvatarBodyParts.SetLegsCollide(character, collide)
end

function AvatarBodyParts.SetTorsoCollide(character: Instance, collide: boolean)
	local parts = { CONSTS.PARTS.UPPER_TORSO, CONSTS.PARTS.LOWER_TORSO }
	AvatarBodyParts.SetPartsCollide(character, collide, parts)
end

function AvatarBodyParts.SetHeadCollide(character: Instance, collide: boolean)
	local parts = { CONSTS.PARTS.HEAD }
	AvatarBodyParts.SetPartsCollide(character, collide, parts)
end

function AvatarBodyParts.SetRootPartCollide(character: Instance, collide: boolean)
	local parts = { CONSTS.PARTS.ROOT }
	AvatarBodyParts.SetPartsCollide(character, collide, parts)
end

return AvatarBodyParts
