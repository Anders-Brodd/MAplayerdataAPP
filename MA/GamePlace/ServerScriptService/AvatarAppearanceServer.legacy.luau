local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local TEMPLATE_NAME = "RealisticAvatarTemplate"
local APPLY_GUARD_ATTR = "AvatarTemplateApplyInProgress"
local CHARACTER_APPLIED_ATTR = "AvatarTemplateApplied"
local RIG_NAME_CANDIDATES = { "RealisticAvatarTemplate", "AvatarRig", "AnimationRig", "PlayerRig" }

local SHOE_ALIASES = {
	Left = { "LeftShoe", "Left Shoe", "LeftBoot", "Left Boot" },
	Right = { "RightShoe", "Right Shoe", "RightBoot", "Right Boot" },
}

local ACCESSORY_FIELDS = {
	"HatAccessory",
	"HairAccessory",
	"FaceAccessory",
	"NeckAccessory",
	"ShouldersAccessory",
	"FrontAccessory",
	"BackAccessory",
	"WaistAccessory",
	"ShirtAccessory",
	"PantsAccessory",
	"JacketAccessory",
	"SweaterAccessory",
	"ShortsAccessory",
	"DressSkirtAccessory",
}
local SKIN_COLOR_FIELDS = {
	"HeadColor",
	"TorsoColor",
	"LeftArmColor",
	"RightArmColor",
	"LeftLegColor",
	"RightLegColor",
}

local FORCED_JACKET_ACCESSORY_ID = 18219453675
local FORCED_PANTS_ACCESSORY_ID = 121256411923504
local HEAD_SCALE_TUNE = 0.94
local CLOTHING_ACCESSORY_TYPE_NAMES = {
	Shirt = true,
	TShirt = true,
	Pants = true,
	Jacket = true,
	Sweater = true,
	Shorts = true,
	DressSkirt = true,
}

local function isClothingAccessoryType(accessoryType)
	return (typeof(accessoryType) == "EnumItem") and (CLOTHING_ACCESSORY_TYPE_NAMES[accessoryType.Name] == true)
end

local FALLBACK_BODY = {
	HeadScale = 0.95,
	HeightScale = 1.05,
	WidthScale = 0.78,
	DepthScale = 0.72,
	BodyTypeScale = 1,
	ProportionScale = 1,
}

local FALLBACK_PART_IDS = {
	Head = 0,
	Torso = 0,
	LeftArm = 0,
	RightArm = 0,
	LeftLeg = 0,
	RightLeg = 0,
}

local warnedMissingTemplate = false

local function cloneTemplateDescription()
	local template = ReplicatedStorage:FindFirstChild(TEMPLATE_NAME, true)
	if not template then
		return nil
	end

	if template:IsA("HumanoidDescription") then
		return template:Clone()
	end

	if template:IsA("Model") then
		local hum = template:FindFirstChildWhichIsA("Humanoid", true)
		if hum then
			local ok, desc = pcall(function()
				return hum:GetAppliedDescription()
			end)
			if ok and desc then
				return desc
			end
		end
	end

	return nil
end

local function applyFallbackBody(desc)
	for key, value in pairs(FALLBACK_BODY) do
		pcall(function()
			desc[key] = value
		end)
	end

	for key, value in pairs(FALLBACK_PART_IDS) do
		if type(value) == "number" and value > 0 then
			pcall(function()
				desc[key] = value
			end)
		end
	end
end

local function copyAccessoryFields(fromDesc, toDesc)
	for _, field in ipairs(ACCESSORY_FIELDS) do
		pcall(function()
			toDesc[field] = fromDesc[field]
		end)
	end
end

local function copySkinColorFields(fromDesc, toDesc)
	for _, field in ipairs(SKIN_COLOR_FIELDS) do
		pcall(function()
			toDesc[field] = fromDesc[field]
		end)
	end
end

local function computeFittedHeadScale(targetDesc, sourceDesc)
	local sourceHeadScale = tonumber(sourceDesc.HeadScale) or 1
	local sourceWidth = tonumber(sourceDesc.WidthScale) or 1
	local sourceDepth = tonumber(sourceDesc.DepthScale) or 1
	local targetWidth = tonumber(targetDesc.WidthScale) or 1
	local targetDepth = tonumber(targetDesc.DepthScale) or 1
	local sourceBodySize = math.max((sourceWidth + sourceDepth) * 0.5, 0.01)
	local targetBodySize = math.max((targetWidth + targetDepth) * 0.5, 0.01)
	return math.clamp(sourceHeadScale * (targetBodySize / sourceBodySize) * HEAD_SCALE_TUNE, 0.72, 1.08)
end

local function enforceForcedOutfit(desc, sourceDesc)
	if sourceDesc then
		pcall(function()
			desc.HairAccessory = sourceDesc.HairAccessory
			desc.FaceAccessory = sourceDesc.FaceAccessory
			desc.Face = sourceDesc.Face
			desc.Head = sourceDesc.Head
			desc.HeadScale = computeFittedHeadScale(desc, sourceDesc)
		end)
		copySkinColorFields(sourceDesc, desc)
	end

	pcall(function()
		desc.Shirt = 0
		desc.Pants = 0
		desc.GraphicTShirt = 0
		desc.ShirtAccessory = ""
		desc.PantsAccessory = tostring(FORCED_PANTS_ACCESSORY_ID)
		desc.JacketAccessory = tostring(FORCED_JACKET_ACCESSORY_ID)
		desc.SweaterAccessory = ""
		desc.ShortsAccessory = ""
		desc.DressSkirtAccessory = ""
	end)

	local accessorySource = sourceDesc or desc
	local ok, accessories = pcall(function()
		return accessorySource:GetAccessories(true)
	end)
	if not (ok and type(accessories) == "table") then
		return
	end

	local filtered = {}
	for _, entry in ipairs(accessories) do
		if not isClothingAccessoryType(entry.AccessoryType) then
			table.insert(filtered, entry)
		end
	end

	table.insert(filtered, {
		AssetId = FORCED_JACKET_ACCESSORY_ID,
		AccessoryType = Enum.AccessoryType.Jacket,
		Order = 1,
	})
	table.insert(filtered, {
		AssetId = FORCED_PANTS_ACCESSORY_ID,
		AccessoryType = Enum.AccessoryType.Pants,
		Order = 2,
	})

	pcall(function()
		desc:SetAccessories(filtered, true)
	end)
end

local function stripDisallowedClothingFromCharacter(character)
	if not character then
		return
	end

	for _, child in ipairs(character:GetChildren()) do
		if child:IsA("Shirt") or child:IsA("Pants") or child:IsA("ShirtGraphic") then
			child:Destroy()
		elseif child:IsA("Accessory") then
			local accessoryType = nil
			pcall(function()
				accessoryType = child.AccessoryType
			end)
			if isClothingAccessoryType(accessoryType) then
				if accessoryType ~= Enum.AccessoryType.Jacket and accessoryType ~= Enum.AccessoryType.Pants then
					child:Destroy()
				end
			end
		end
	end
end

local function getPlayerDescription(player)
	local ok, result = pcall(function()
		return Players:GetHumanoidDescriptionFromUserId(player.UserId)
	end)
	if ok and result then
		return result
	end
	warn("[AvatarAppearanceServer] Failed to get player description:", result)
	return nil
end

local function buildFinalDescription(player)
	local baseDesc = cloneTemplateDescription()
	if not baseDesc then
		if not warnedMissingTemplate then
			warnedMissingTemplate = true
			warn("[AvatarAppearanceServer] Missing RealisticAvatarTemplate in ReplicatedStorage. Using fallback realistic body.")
		end
		baseDesc = Instance.new("HumanoidDescription")
		applyFallbackBody(baseDesc)
	end

	local playerDesc = getPlayerDescription(player)
	if playerDesc then
		copyAccessoryFields(playerDesc, baseDesc)
		copySkinColorFields(playerDesc, baseDesc)
	end

	enforceForcedOutfit(baseDesc, playerDesc)

	return baseDesc
end

local function findAnimationSourceRig()
	for _, name in ipairs(RIG_NAME_CANDIDATES) do
		local candidate = ReplicatedStorage:FindFirstChild(name, true)
		if candidate and candidate:IsA("Model") and candidate:FindFirstChild("Animate", true) then
			return candidate
		end
	end

	for _, inst in ipairs(ReplicatedStorage:GetDescendants()) do
		if inst:IsA("Model") and inst:FindFirstChild("Animate", true) then
			return inst
		end
	end

	return nil
end

local function resolvePath(root, pathParts)
	local node = root
	for _, part in ipairs(pathParts) do
		node = node:FindFirstChild(part)
		if not node then
			return nil
		end
	end
	return node
end

local function getRelativePathParts(rootNode, leaf)
	local parts = {}
	local cursor = leaf.Parent
	while cursor and cursor ~= rootNode do
		table.insert(parts, 1, cursor.Name)
		cursor = cursor.Parent
	end
	return parts
end

local function applyRigAnimations(character)
	local sourceRig = findAnimationSourceRig()
	if not sourceRig then
		warn("[AvatarAppearanceServer] No rig with Animate found in ReplicatedStorage")
		return
	end

	local sourceAnimate = sourceRig:FindFirstChild("Animate", true)
	local targetAnimate = character:FindFirstChild("Animate") or character:WaitForChild("Animate", 5)
	if not sourceAnimate or not targetAnimate then
		warn("[AvatarAppearanceServer] Missing source or target Animate")
		return
	end

	local appliedCount = 0
	for _, sourceAnim in ipairs(sourceAnimate:GetDescendants()) do
		if sourceAnim:IsA("Animation") then
			local pathParts = getRelativePathParts(sourceAnimate, sourceAnim)
			local targetParent = resolvePath(targetAnimate, pathParts)
			if targetParent then
				local targetAnim = targetParent:FindFirstChild(sourceAnim.Name)
				if targetAnim and targetAnim:IsA("Animation") then
					targetAnim.AnimationId = sourceAnim.AnimationId
					appliedCount += 1
				end
			end
		end
	end

	if appliedCount == 0 then
		warn("[AvatarAppearanceServer] Found rig Animate, but no matching Animation nodes were updated")
	end
end

local function findAccessoryTemplateByName(name)
	local inst = ReplicatedStorage:FindFirstChild(name, true)
	if not inst then
		return nil
	end
	if inst:IsA("Accessory") then
		return inst
	end
	if inst:IsA("Model") then
		return inst:FindFirstChildWhichIsA("Accessory", true)
	end
	return nil
end

local function findAccessoryTemplateByPattern(side)
	local sideLower = string.lower(side)
	for _, inst in ipairs(ReplicatedStorage:GetDescendants()) do
		local nameLower = string.lower(inst.Name)
		if nameLower:find("shoe", 1, true) and nameLower:find(sideLower, 1, true) then
			if inst:IsA("Accessory") then
				return inst
			end
			if inst:IsA("Model") then
				local accessory = inst:FindFirstChildWhichIsA("Accessory", true)
				if accessory then
					return accessory
				end
			end
		end
	end
	return nil
end

local function retargetLeftAttachmentsToRight(accessory)
	for _, desc in ipairs(accessory:GetDescendants()) do
		if desc:IsA("Attachment") then
			desc.Name = string.gsub(desc.Name, "Left", "Right")
			desc.Name = string.gsub(desc.Name, "left", "right")
		end
	end
end

local function resolveShoeTemplate(side)
	for _, alias in ipairs(SHOE_ALIASES[side]) do
		local found = findAccessoryTemplateByName(alias)
		if found then
			return found
		end
	end

	local patternMatch = findAccessoryTemplateByPattern(side)
	if patternMatch then
		return patternMatch
	end

	if side == "Right" then
		local leftTemplate = resolveShoeTemplate("Left")
		if leftTemplate then
			local generated = leftTemplate:Clone()
			generated.Name = "RightShoe"
			retargetLeftAttachmentsToRight(generated)
			return generated
		end
	end

	return nil
end

local function equipCustomShoes(character)
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return
	end

	local function sanitizeAccessoryPhysics(accessory)
		for _, desc in ipairs(accessory:GetDescendants()) do
			if desc:IsA("BasePart") then
				desc.Anchored = false
				desc.CanCollide = false
				desc.CanTouch = false
				desc.CanQuery = false
				desc.Massless = true
			end
		end
	end

	if not character:FindFirstChild("LeftShoe") then
		local leftTemplate = resolveShoeTemplate("Left")
		if leftTemplate then
			local left = leftTemplate:IsA("Accessory") and leftTemplate:Clone() or leftTemplate
			left.Name = "LeftShoe"
			sanitizeAccessoryPhysics(left)
			humanoid:AddAccessory(left)
		else
			warn("[AvatarAppearanceServer] Missing left shoe accessory template")
		end
	end

	if not character:FindFirstChild("RightShoe") then
		local rightTemplate = resolveShoeTemplate("Right")
		if rightTemplate then
			local right = rightTemplate:IsA("Accessory") and rightTemplate:Clone() or rightTemplate
			right.Name = "RightShoe"
			sanitizeAccessoryPhysics(right)
			humanoid:AddAccessory(right)
		else
			warn("[AvatarAppearanceServer] Missing right shoe accessory template")
		end
	end
end

local function applyAvatarToCharacter(player, character)
	if not player or not character or not character.Parent then
		return
	end
	if player:GetAttribute(APPLY_GUARD_ATTR) == true then
		return
	end
	if character:GetAttribute(CHARACTER_APPLIED_ATTR) == true then
		return
	end
	character:SetAttribute(CHARACTER_APPLIED_ATTR, true)

	local humanoid = character:FindFirstChildOfClass("Humanoid") or character:WaitForChild("Humanoid", 10)
	if not humanoid then
		character:SetAttribute(CHARACTER_APPLIED_ATTR, false)
		return
	end

	local finalDesc = buildFinalDescription(player)
	player:SetAttribute(APPLY_GUARD_ATTR, true)

	local ok, err = pcall(function()
		humanoid:ApplyDescriptionReset(finalDesc)
	end)

	player:SetAttribute(APPLY_GUARD_ATTR, false)
	if not ok then
		warn("[AvatarAppearanceServer] Failed to apply avatar description:", err)
		character:SetAttribute(CHARACTER_APPLIED_ATTR, false)
		return
	end

	stripDisallowedClothingFromCharacter(character)

	task.wait(0.1)
	equipCustomShoes(character)
	applyRigAnimations(character)
end

local function hookPlayer(player)
	player.CharacterAppearanceLoaded:Connect(function(character)
		task.defer(applyAvatarToCharacter, player, character)
	end)

	if player.Character then
		task.defer(applyAvatarToCharacter, player, player.Character)
	end
end

for _, player in ipairs(Players:GetPlayers()) do
	task.defer(hookPlayer, player)
end

Players.PlayerAdded:Connect(hookPlayer)
