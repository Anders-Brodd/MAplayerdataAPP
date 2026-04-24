--[[
	SkiServer V3.0 — Server-side ski attachment + Avatar Joint Upgrade
	ServerScript in ServerScriptService
	
	=== WHAT THIS DOES ===
	• Handles ski model cloning and welding to feet
	• Cleans up physics on ski parts (massless, no collide)
	• Sets up Avatar Joint Upgrade ragdoll on death
	• Proper R6/R15 support
	• Cleanup on player leave / character death
	
	=== CHANGES FROM V2 ===
	• Cleaner weld system (uses WeldConstraint, more stable)
	• Better ski part discovery (handles any model structure)
	• Proper massless setup prevents skis from affecting physics
	• Death ragdoll uses correct AnimationConstraint API
	• Added ski scale/offset config at top for easy tuning
]]

-- ============================================================================
-- SERVICES
-- ============================================================================
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage     = game:GetService("ServerStorage")
local Players           = game:GetService("Players")


-- ============================================================================
-- CONFIGURATION
-- ============================================================================
local SETTINGS = {
	-- Position offset from foot part
	-- X = left/right, Y = up/down, Z = forward/back
	-- Adjust these if skis float or clip through ground
	-- Y now works as a trim offset on top of automatic per-avatar fitting.
	PositionOffset = Vector3.new(0, 0.58, -0.45),
	FootClearance = 0.04,
	UseBootFrontAttachment = false,
	EnableDynamicFootGapCorrection = false,

	-- Rotation offset in DEGREES
	-- X = pitch (nose up/down), Y = yaw (twist), Z = roll (tilt)
	RotationOffset = Vector3.new(90, 0, 0),

	-- Scale multiplier (1 = original model size)
	Scale = 1.0,

	-- Death ragdoll settings
	DeathRagdoll = {
		Enabled = true,          -- Enable ragdoll on death
		MaxForce = 100,          -- How floppy (lower = more floppy)
		MaxTorque = 100,
	},

	-- Extra collision contacts at ski nose/tail prevent terrain clipping while
	-- keeping center section non-collidable for smooth glide.
	SkiTipCollision = {
		Enabled = true,
		Length = 0.26,
		Inset = 0.04,
		Thickness = 0.06,
		Friction = 0.0,
	},
}

local APPEARANCE_CACHE_TTL = 120
local AppearanceCache = {}
local WEARABLE_DESCRIPTION_PROPERTIES = {
	"BackAccessory",
	"FaceAccessory",
	"FrontAccessory",
	"HairAccessory",
	"HatAccessory",
	"NeckAccessory",
	"ShouldersAccessory",
	"WaistAccessory",
	"Shirt",
	"Pants",
	"GraphicTShirt",
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
local FORCED_JACKET_ACCESSORY_ID = "18219453675"
local FORCED_PANTS_ACCESSORY_ID = "121256411923504"
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
local FOOTWEAR_ATTACHMENT_NAMES = {
	LeftFootAttachment = true,
	RightFootAttachment = true,
}

local function isClothingAccessoryType(accessoryType)
	return (typeof(accessoryType) == "EnumItem") and (CLOTHING_ACCESSORY_TYPE_NAMES[accessoryType.Name] == true)
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
		desc.PantsAccessory = FORCED_PANTS_ACCESSORY_ID
		desc.JacketAccessory = FORCED_JACKET_ACCESSORY_ID
		desc.SweaterAccessory = ""
		desc.ShortsAccessory = ""
		desc.DressSkirtAccessory = ""
	end)

	local accessorySource = sourceDesc or desc
	local okAccessories, accessories = pcall(function()
		return accessorySource:GetAccessories(true)
	end)
	if not (okAccessories and type(accessories) == "table") then
		return
	end

	local filtered = {}
	for _, entry in ipairs(accessories) do
		if not isClothingAccessoryType(entry.AccessoryType) then
			table.insert(filtered, entry)
		end
	end

	table.insert(filtered, {
		AssetId = tonumber(FORCED_JACKET_ACCESSORY_ID),
		AccessoryType = Enum.AccessoryType.Jacket,
		Order = 1,
	})
	table.insert(filtered, {
		AssetId = tonumber(FORCED_PANTS_ACCESSORY_ID),
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

local function isFootwearAccessory(accessory)
	if not accessory or not accessory:IsA("Accessory") then
		return false
	end
	if accessory:GetAttribute("SkiPoleAccessory") == true then
		return false
	end
	if accessory.Name == "LeftPole" or accessory.Name == "RightPole" then
		return false
	end
	for _, desc in ipairs(accessory:GetDescendants()) do
		if desc:IsA("Attachment") and FOOTWEAR_ATTACHMENT_NAMES[desc.Name] then
			return true
		end
	end
	return false
end

local function snapshotFootwearAccessories(character)
	local clones = {}
	if not character then
		return clones
	end
	for _, child in ipairs(character:GetChildren()) do
		if isFootwearAccessory(child) then
			table.insert(clones, child:Clone())
		end
	end
	return clones
end

local function restoreFootwearAccessories(character, humanoid, clones)
	if not character or not humanoid then
		for _, clone in ipairs(clones or {}) do
			if clone and clone.Parent == nil then
				clone:Destroy()
			end
		end
		return
	end

	for _, clone in ipairs(clones or {}) do
		if clone and clone:IsA("Accessory") then
			local exists = character:FindFirstChild(clone.Name)
			if not (exists and exists:IsA("Accessory")) then
				pcall(function()
					humanoid:AddAccessory(clone)
				end)
			end
			if clone.Parent == nil then
				clone:Destroy()
			end
		end
	end
end

local function getHalfExtentAlong(partCF, size, axis)
	local right = partCF.RightVector
	local up = partCF.UpVector
	local look = partCF.LookVector
	return (math.abs(axis:Dot(right)) * size.X * 0.5)
		+ (math.abs(axis:Dot(up)) * size.Y * 0.5)
		+ (math.abs(axis:Dot(look)) * size.Z * 0.5)
end

-- ============================================================================
-- SETUP REMOTE EVENT
-- ============================================================================
local SkiEvent = ReplicatedStorage:FindFirstChild("SkiEvent")
if not SkiEvent then
	SkiEvent = Instance.new("RemoteEvent")
	SkiEvent.Name = "SkiEvent"
	SkiEvent.Parent = ReplicatedStorage
end

-- ============================================================================
-- FIND SKI ASSET
-- ============================================================================
local function findSkiAsset()
	local searchPaths = {
		{ReplicatedStorage, "Assets", "Gear", "Skis"},
		{ServerStorage, "Assets", "Gear", "Skis"},
		{ReplicatedStorage, "Skis"},
		{ServerStorage, "Skis"},
	}

	-- Try each path with retries
	for attempt = 1, 15 do
		for _, path in ipairs(searchPaths) do
			local current = path[1]
			local found = true

			for i = 2, #path do
				local child = current:FindFirstChild(path[i])
				if child then
					current = child
				else
					found = false
					break
				end
			end

			if found then
				return current
			end
		end

		if attempt < 15 then
			task.wait(0.5)
		end
	end

	return nil
end

local SkiAsset = findSkiAsset()
if not SkiAsset then
end

local function findPoleAsset()
	local directParents = {}
	if SkiAsset and SkiAsset.Parent then
		table.insert(directParents, SkiAsset.Parent)
	end

	for _, parent in ipairs(directParents) do
		for _, name in ipairs({"Pole", "SkiPole", "SkiPoles", "Poles"}) do
			local candidate = parent:FindFirstChild(name)
			if candidate then
				return candidate
			end
		end
	end

	local searchPaths = {
		{ReplicatedStorage, "Assets", "Gear", "Pole"},
		{ReplicatedStorage, "Assets", "Gear", "SkiPole"},
		{ReplicatedStorage, "Assets", "Gear", "SkiPoles"},
		{ServerStorage, "Assets", "Gear", "Pole"},
		{ServerStorage, "Assets", "Gear", "SkiPole"},
		{ServerStorage, "Assets", "Gear", "SkiPoles"},
	}

	for _, path in ipairs(searchPaths) do
		local current = path[1]
		local found = true
		for i = 2, #path do
			local child = current and current:FindFirstChild(path[i])
			if child then
				current = child
			else
				found = false
				break
			end
		end
		if found and current then
			return current
		end
	end

	return nil
end

local PoleAsset = findPoleAsset()

local function findPoleAccessoryTemplate(name)
	local direct = ReplicatedStorage:FindFirstChild(name)
	if direct and direct:IsA("Accessory") then
		return direct
	end
	local deep = ReplicatedStorage:FindFirstChild(name, true)
	if deep and deep:IsA("Accessory") then
		return deep
	end
	return nil
end

local function getPoleAccessoryTemplates()
	local leftTemplate = findPoleAccessoryTemplate("LeftPole")
	local rightTemplate = findPoleAccessoryTemplate("RightPole")
	return leftTemplate, rightTemplate
end

local function getPlayerDescriptionClone(player)
	if not player then
		return nil
	end

	local now = tick()
	local entry = AppearanceCache[player.UserId]
	if entry and entry.desc and (now - entry.at) <= APPEARANCE_CACHE_TTL then
		return entry.desc:Clone()
	end

	local ok, desc = pcall(function()
		return Players:GetHumanoidDescriptionFromUserId(player.UserId)
	end)
	if ok and desc then
		AppearanceCache[player.UserId] = {desc = desc, at = now}
		return desc:Clone()
	end

	return nil
end

local function applyPlayerAppearanceToCharacter(player, humanoid)
	if not player or not humanoid then
		return
	end
	local character = humanoid.Parent
	if not character then
		return
	end

	local preservedFootwear = snapshotFootwearAccessories(character)

	local playerDesc = getPlayerDescriptionClone(player)
	if not playerDesc then
		restoreFootwearAccessories(character, humanoid, preservedFootwear)
		return
	end

	local currentDesc = nil
	pcall(function()
		currentDesc = humanoid:GetAppliedDescription()
	end)
	if not currentDesc then
		restoreFootwearAccessories(character, humanoid, preservedFootwear)
		return
	end

	local mergedDesc = currentDesc:Clone()
	for _, propertyName in ipairs(WEARABLE_DESCRIPTION_PROPERTIES) do
		local okRead, value = pcall(function()
			return playerDesc[propertyName]
		end)
		if okRead then
			pcall(function()
				mergedDesc[propertyName] = value
			end)
		end
	end
	copySkinColorFields(playerDesc, mergedDesc)

	enforceForcedOutfit(mergedDesc, playerDesc)

	local applied = pcall(function()
		humanoid:ApplyDescriptionReset(mergedDesc)
	end)
	if not applied then
		restoreFootwearAccessories(character, humanoid, preservedFootwear)
		return
	end

	stripDisallowedClothingFromCharacter(character)

	restoreFootwearAccessories(character, humanoid, preservedFootwear)
end

-- ============================================================================
-- HELPER FUNCTIONS
-- ============================================================================

-- Clean up a part for attachment (no physics interference)
local function setPartNonPhysical(part)
	part.Anchored = false
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Massless = true

end

local function preparePartForWeld(part)
	setPartNonPhysical(part)

	-- Remove any existing welds/constraints that might conflict
	for _, child in ipairs(part:GetChildren()) do
		if child:IsA("Weld") or child:IsA("WeldConstraint") or child:IsA("Motor6D") then
			child:Destroy()
		end
	end
end

local function getLongestAndThinnestAxes(size)
	local longAxis, longLen = Vector3.xAxis, size.X
	if size.Y > longLen then
		longAxis, longLen = Vector3.yAxis, size.Y
	end
	if size.Z > longLen then
		longAxis, longLen = Vector3.zAxis, size.Z
	end

	local thinAxis, thinLen = Vector3.xAxis, size.X
	if size.Y < thinLen then
		thinAxis, thinLen = Vector3.yAxis, size.Y
	end
	if size.Z < thinLen then
		thinAxis, thinLen = Vector3.zAxis, size.Z
	end

	return longAxis, longLen, thinAxis, thinLen
end

local function addSkiTipColliders(skiPart, footPart)
	if not skiPart or not skiPart:IsA("BasePart") then
		return
	end
	local cfg = SETTINGS.SkiTipCollision
	if not cfg or cfg.Enabled ~= true then
		return
	end

	for _, child in ipairs(skiPart:GetChildren()) do
		if child:IsA("BasePart") and (child.Name == "SkiTipColliderFront" or child.Name == "SkiTipColliderBack") then
			child:Destroy()
		end
	end

	local axis, skiLength, thinAxis, thinLen = getLongestAndThinnestAxes(skiPart.Size)
	local tipLen = math.clamp(cfg.Length or 0.26, 0.12, math.max(0.12, skiLength * 0.22))
	local inset = math.clamp(cfg.Inset or 0.06, 0, skiLength * 0.2)
	local halfTravel = math.max((skiLength * 0.5) - (tipLen * 0.5) - inset, 0.05)
	local radius = math.clamp(cfg.Thickness or 0.06, 0.035, math.max(0.04, thinLen * 0.45))

	local refUp = (footPart and footPart:IsA("BasePart")) and footPart.CFrame.UpVector or Vector3.yAxis
	local thinWorld = skiPart.CFrame:VectorToWorldSpace(thinAxis)
	local downSign = (thinWorld:Dot(refUp) > 0) and -1 or 1
	local downOffset = thinAxis * (downSign * math.max((thinLen * 0.5) - (radius * 0.45), 0))

	local function makeTip(name, sign)
		local tip = Instance.new("Part")
		tip.Name = name
		tip.Shape = Enum.PartType.Ball
		tip.Size = Vector3.new(radius * 2, radius * 2, radius * 2)
		tip.Transparency = 1
		tip.CastShadow = false
		tip.Material = Enum.Material.Ice
		tip.Anchored = false
		tip.CanCollide = true
		tip.CanQuery = false
		tip.CanTouch = false
		tip.Massless = true
		tip.CustomPhysicalProperties = PhysicalProperties.new(0.2, math.clamp(cfg.Friction or 0.0, 0, 0.03), 0, 0, 0)
		tip.CFrame = skiPart.CFrame * CFrame.new((axis * (halfTravel * sign)) + downOffset)
		tip.Parent = skiPart

		local weld = Instance.new("WeldConstraint")
		weld.Name = "SkiTipColliderWeld"
		weld.Part0 = skiPart
		weld.Part1 = tip
		weld.Parent = tip
	end

	makeTip("SkiTipColliderFront", 1)
	makeTip("SkiTipColliderBack", -1)
end

local function findAttachmentByName(root, name)
	if not root then
		return nil
	end
	local found = root:FindFirstChild(name, true)
	if found and found:IsA("Attachment") then
		return found
	end
	return nil
end

local function isSkiPoleAccessory(inst)
	if not inst or not inst:IsA("Accessory") then
		return false
	end
	if inst:GetAttribute("SkiPoleAccessory") == true then
		return true
	end
	if inst.Name == "LeftPole" or inst.Name == "RightPole" then
		local hand = findAttachmentByName(inst, "Hand")
		local point = findAttachmentByName(inst, "Point")
		return hand ~= nil or point ~= nil
	end
	return false
end

local function clearPoleAttachments(character)
	if not character then
		return
	end

	for _, child in ipairs(character:GetChildren()) do
		if isSkiPoleAccessory(child) then
			child:Destroy()
		end
	end

	-- Clean up any legacy welded pole model from older runtime.
	local legacyPoles = character:FindFirstChild("SkiPoles")
	if legacyPoles then
		legacyPoles:Destroy()
	end
end

local function addPoleAccessories(character, humanoid)
	if not character or not humanoid then
		return
	end

	clearPoleAttachments(character)

	local leftTemplate, rightTemplate = getPoleAccessoryTemplates()
	if not leftTemplate or not rightTemplate then
		return
	end

	local leftClone = leftTemplate:Clone()
	leftClone.Name = "LeftPole"
	leftClone:SetAttribute("SkiPoleAccessory", true)
	humanoid:AddAccessory(leftClone)

	local rightClone = rightTemplate:Clone()
	rightClone.Name = "RightPole"
	rightClone:SetAttribute("SkiPoleAccessory", true)
	humanoid:AddAccessory(rightClone)
end

local function findNearestBootFrontAttachment(character, footPart)
	if not character or not footPart then
		return nil
	end
	local footNameLower = string.lower(footPart.Name)
	local wantsLeft = string.find(footNameLower, "left", 1, true) ~= nil
	local wantsRight = string.find(footNameLower, "right", 1, true) ~= nil

	local nearest = nil
	local nearestScore = math.huge
	for _, desc in ipairs(character:GetDescendants()) do
		if desc:IsA("Attachment") and desc.Name == "Front" then
			local accessory = desc:FindFirstAncestorWhichIsA("Accessory")
			if accessory and isFootwearAccessory(accessory) and desc.Parent and desc.Parent:IsA("BasePart") then
				local accessoryNameLower = string.lower(accessory.Name)
				local hasLeftFootAtt = (findAttachmentByName(accessory, "LeftFootAttachment") ~= nil)
				local hasRightFootAtt = (findAttachmentByName(accessory, "RightFootAttachment") ~= nil)
				if wantsLeft and string.find(accessoryNameLower, "right", 1, true) then
					continue
				end
				if wantsRight and string.find(accessoryNameLower, "left", 1, true) then
					continue
				end
				if wantsLeft and hasRightFootAtt and (not hasLeftFootAtt) then
					continue
				end
				if wantsRight and hasLeftFootAtt and (not hasRightFootAtt) then
					continue
				end
				local dist = (desc.WorldPosition - footPart.Position).Magnitude
				local sidePenalty = 0
				if wantsLeft and (not hasLeftFootAtt) then
					sidePenalty += 0.35
				end
				if wantsRight and (not hasRightFootAtt) then
					sidePenalty += 0.35
				end
				local score = dist + sidePenalty
				if score < nearestScore then
					nearestScore = score
					nearest = desc
				end
			end
		end
	end

	if nearest and nearestScore <= 5.5 then
		return nearest
	end

	return nil
end

local function waitForBootFrontAttachment(character, footPart, timeoutSec)
	local timeout = math.max(timeoutSec or 0.24, 0)
	local deadline = tick() + timeout
	local found = findNearestBootFrontAttachment(character, footPart)
	while (not found) and tick() < deadline do
		task.wait(0.03)
		found = findNearestBootFrontAttachment(character, footPart)
	end
	return found
end

local function isValidFrontAttachmentMount(ski, footPart, candidateOffset)
	if not ski or not footPart or not candidateOffset then
		return false
	end

	if candidateOffset.Position.Magnitude > 6 then
		return false
	end

	local candidateSkiCF = footPart.CFrame * candidateOffset
	local footUp = footPart.CFrame.UpVector
	local footRight = footPart.CFrame.RightVector
	local footForward = footPart.CFrame.LookVector
	if footForward.Magnitude < 1e-4 then
		footForward = Vector3.new(0, 0, -1)
	else
		footForward = footForward.Unit
	end

	local relative = candidateSkiCF.Position - footPart.Position
	local localVertical = relative:Dot(footUp)
	local localLateral = math.abs(relative:Dot(footRight))
	if localVertical > 0.4 or localVertical < -3.2 then
		return false
	end
	if localLateral > 1.4 then
		return false
	end

	local skiTop = candidateSkiCF.Position:Dot(footUp) + getHalfExtentAlong(candidateSkiCF, ski.Size, footUp)
	local footBottom = footPart.Position:Dot(footUp) - getHalfExtentAlong(footPart.CFrame, footPart.Size, footUp)
	if (footBottom - skiTop) < -0.08 then
		return false
	end

	local longAxis = select(1, getLongestAndThinnestAxes(ski.Size))
	local skiForward = candidateSkiCF:VectorToWorldSpace(longAxis)
	if skiForward.Magnitude < 1e-4 then
		return false
	end
	local forwardAlignment = math.abs(skiForward.Unit:Dot(footForward))
	if forwardAlignment < 0.45 then
		return false
	end

	return true
end

local function solveSkiMountOffset(ski, footPart, offsetVector, rotationOffset, allowFootGapCorrection)
	if not allowFootGapCorrection then
		return offsetVector
	end

	local minClearance = math.max(SETTINGS.FootClearance or 0.04, 0.035)
	local maxLocalYCorrection = 0.22
	local skiCF = footPart.CFrame * (CFrame.new(offsetVector) * rotationOffset)
	local footBottom = footPart.Position.Y - getHalfExtentAlong(footPart.CFrame, footPart.Size, Vector3.yAxis)
	local skiTop = skiCF.Position.Y + getHalfExtentAlong(skiCF, ski.Size, Vector3.yAxis)
	local gap = footBottom - skiTop

	if gap < minClearance then
		local downDelta = math.clamp(minClearance - gap, 0, maxLocalYCorrection)
		offsetVector = offsetVector + Vector3.new(0, -downDelta, 0)
	end

	return offsetVector
end

-- Weld a ski part to a leg/foot part with configured offset.
-- Use a direct foot-space weld because the imported ski pivots are inconsistent.
local function weldSki(ski, footPart)
	if not ski or not footPart then return end

	local rotationOffset = CFrame.Angles(
			math.rad(SETTINGS.RotationOffset.X),
			math.rad(SETTINGS.RotationOffset.Y),
			math.rad(SETTINGS.RotationOffset.Z)
		)

	local character = footPart.Parent
	local useBootFrontAttach = SETTINGS.UseBootFrontAttachment == true
	local skiFrontAttachment = useBootFrontAttach and findAttachmentByName(ski, "Front") or nil
	local bootFrontAttachment = useBootFrontAttach and findNearestBootFrontAttachment(character, footPart) or nil

	local usedFrontAttachmentAlignment = false
	local autoYOffset = 0
	local offsetVector
	local offset

	if skiFrontAttachment and bootFrontAttachment then
		-- Point-authoritative mount: match both position and orientation of Front attachments.
		-- Use ski-part local transform so this remains correct even if Front lives on a nested part.
		local skiFrontLocalCF = ski.CFrame:ToObjectSpace(skiFrontAttachment.WorldCFrame)
		local desiredSkiCFrame = bootFrontAttachment.WorldCFrame * skiFrontLocalCF:Inverse()
		local candidateOffset = footPart.CFrame:ToObjectSpace(desiredSkiCFrame)
		if isValidFrontAttachmentMount(ski, footPart, candidateOffset) then
			offset = candidateOffset
			offsetVector = offset.Position
			usedFrontAttachmentAlignment = true
		else
			-- Invalid attachment pairing can produce bad offsets/orientation; fallback to auto mount.
			skiFrontAttachment = nil
			bootFrontAttachment = nil
		end
	end

	if not usedFrontAttachmentAlignment then
		local footHalf = footPart.Size.Y * 0.5
		local skiHalf = math.min(ski.Size.X, ski.Size.Y, ski.Size.Z) * 0.5

		-- Place ski top flush to foot bottom for any avatar scale, then apply trim.
		autoYOffset = -footHalf - skiHalf + (SETTINGS.FootClearance or 0)
		autoYOffset = math.clamp(autoYOffset, -1.75, -0.15)
		offsetVector = Vector3.new(
			SETTINGS.PositionOffset.X,
			autoYOffset + SETTINGS.PositionOffset.Y,
			SETTINGS.PositionOffset.Z
		)
		offset = CFrame.new(offsetVector) * rotationOffset
	end

	if not usedFrontAttachmentAlignment then
		offsetVector = solveSkiMountOffset(
			ski,
			footPart,
			offsetVector,
			rotationOffset,
			SETTINGS.EnableDynamicFootGapCorrection == true
		)
		offset = CFrame.new(offsetVector) * rotationOffset
	end
	offset = offset or (CFrame.new(offsetVector) * rotationOffset)

	ski.CFrame = footPart.CFrame * offset
	if (ski.Position - footPart.Position).Magnitude > 10 then
		local safeOffset = CFrame.new(SETTINGS.PositionOffset) * rotationOffset
		offset = safeOffset
		ski.CFrame = footPart.CFrame * offset
	end

	local weld = Instance.new("Weld")
	weld.Name = "SkiWeld"
	weld.Part0 = footPart
	weld.Part1 = ski
	weld.C0 = offset
	weld.C1 = CFrame.identity
	weld.Parent = ski

	addSkiTipColliders(ski, footPart)

	ski:SetAttribute("AutoMountYOffset", autoYOffset)
	ski:SetAttribute("MountYOffset", offsetVector.Y)
	ski:SetAttribute("UsedFrontAttachmentAlignment", usedFrontAttachmentAlignment)
	if usedFrontAttachmentAlignment and skiFrontAttachment and bootFrontAttachment then
		ski:SetAttribute("FrontAttachError", (skiFrontAttachment.WorldPosition - bootFrontAttachment.WorldPosition).Magnitude)
	end
end

local function collectBaseParts(inst)
	local parts = {}
	if not inst then
		return parts
	end
	if inst:IsA("BasePart") then
		table.insert(parts, inst)
		return parts
	end
	for _, desc in ipairs(inst:GetDescendants()) do
		if desc:IsA("BasePart") then
			table.insert(parts, desc)
		end
	end
	return parts
end

local function safeUnit(vector, fallback)
	if typeof(vector) == "Vector3" and vector.Magnitude > 1e-4 then
		return vector.Unit
	end
	return fallback or Vector3.new(0, 0, -1)
end

local function rotationFromTo(fromDir, toDir)
	local from = safeUnit(fromDir, Vector3.new(0, 0, -1))
	local to = safeUnit(toDir, Vector3.new(0, 0, -1))
	local dot = math.clamp(from:Dot(to), -1, 1)
	if dot > 0.9999 then
		return CFrame.identity
	end
	if dot < -0.9999 then
		local axis = safeUnit(from:Cross(Vector3.yAxis), nil)
		if axis.Magnitude < 1e-4 then
			axis = safeUnit(from:Cross(Vector3.xAxis), Vector3.xAxis)
		end
		return CFrame.fromAxisAngle(axis, math.pi)
	end
	local axis = safeUnit(from:Cross(to), Vector3.yAxis)
	local angle = math.acos(dot)
	return CFrame.fromAxisAngle(axis, angle)
end

local function findPoleGripPartAndAttachment(poleInstance)
	if not poleInstance then
		return nil, nil, nil
	end

	local pointAttachment = nil
	for _, desc in ipairs(poleInstance:GetDescendants()) do
		if desc:IsA("Attachment") and desc.Name == "Point" then
			pointAttachment = desc
			break
		end
	end

	if poleInstance:IsA("BasePart") then
		local att = poleInstance:FindFirstChild("Hand")
		if att and att:IsA("Attachment") then
			return poleInstance, att, pointAttachment
		end
		return poleInstance, nil, pointAttachment
	end

	for _, desc in ipairs(poleInstance:GetDescendants()) do
		if desc:IsA("Attachment") and desc.Name == "Hand" then
			local parentPart = desc.Parent
			if parentPart and parentPart:IsA("BasePart") then
				return parentPart, desc, pointAttachment
			end
		end
	end

	for _, desc in ipairs(poleInstance:GetDescendants()) do
		if desc:IsA("BasePart") then
			return desc, nil, pointAttachment
		end
	end

	return nil, nil, pointAttachment
end

local function weldPole(poleGripPart, handPart, poleHandAttachment, polePointAttachment)
	if not poleGripPart or not handPart then
		return
	end

	local function findPalmAttachment(part)
		if not part then
			return nil
		end
		for _, name in ipairs({"Hand", "GripAttachment", "LeftGripAttachment", "RightGripAttachment"}) do
			local att = part:FindFirstChild(name)
			if att and att:IsA("Attachment") then
				return att
			end
		end
		for _, child in ipairs(part:GetChildren()) do
			if child:IsA("Attachment") then
				return child
			end
		end
		return nil
	end

	local handPalmAttachment = findPalmAttachment(handPart)
	local desiredPalmPos = handPalmAttachment and handPalmAttachment.Position or Vector3.zero
	-- Keep the pole seated under the palm so it exits below the forearm.
	desiredPalmPos = desiredPalmPos + Vector3.new(0, -0.14, 0.05)
	local poleGripPos = poleHandAttachment and poleHandAttachment.Position or Vector3.zero

	local poleRotation = CFrame.identity
	if poleHandAttachment and polePointAttachment then
		local handToPointWorld = polePointAttachment.WorldPosition - poleHandAttachment.WorldPosition
		if handToPointWorld.Magnitude > 1e-4 then
			local handToPointLocal = poleGripPart.CFrame:VectorToObjectSpace(handToPointWorld.Unit)
			local desiredPoleAxisInHand = safeUnit(Vector3.new(0, -0.12, 1), Vector3.zAxis)
			local baseRotation = rotationFromTo(handToPointLocal, desiredPoleAxisInHand)
			local flippedRotation = CFrame.fromAxisAngle(desiredPoleAxisInHand, math.pi) * baseRotation

			-- Resolve roll ambiguity so pole exits from the underside of the palm.
			local desiredPoleUpInHand = Vector3.new(0, -1, 0)
			local baseUpDot = baseRotation:VectorToWorldSpace(Vector3.yAxis):Dot(desiredPoleUpInHand)
			local flippedUpDot = flippedRotation:VectorToWorldSpace(Vector3.yAxis):Dot(desiredPoleUpInHand)
			poleRotation = (flippedUpDot > baseUpDot) and flippedRotation or baseRotation
		end
	end

	local rotatedPoleGripPos = poleRotation:VectorToWorldSpace(poleGripPos)
	local offset = CFrame.new(desiredPalmPos - rotatedPoleGripPos) * poleRotation

	poleGripPart.CFrame = handPart.CFrame * offset

	local weld = Instance.new("Weld")
	weld.Name = "PoleWeld"
	weld.Part0 = handPart
	weld.Part1 = poleGripPart
	weld.C0 = offset
	weld.C1 = CFrame.identity
	weld.Parent = poleGripPart
end

-- Get the appropriate foot/leg parts based on rig type
local function getFootParts(character, humanoid)
	local left, right

	if humanoid.RigType == Enum.HumanoidRigType.R15 then
		left  = character:FindFirstChild("LeftFoot")
		right = character:FindFirstChild("RightFoot")

		-- Fallback to lower leg if feet not found
		if not left then left = character:FindFirstChild("LeftLowerLeg") end
		if not right then right = character:FindFirstChild("RightLowerLeg") end
	else
		-- R6
		left  = character:FindFirstChild("Left Leg")
		right = character:FindFirstChild("Right Leg")
	end

	return left, right
end

local function getHandParts(character, humanoid)
	local left, right

	if humanoid.RigType == Enum.HumanoidRigType.R15 then
		left = character:FindFirstChild("LeftHand") or character:FindFirstChild("LeftLowerArm")
		right = character:FindFirstChild("RightHand") or character:FindFirstChild("RightLowerArm")
	else
		left = character:FindFirstChild("Left Arm")
		right = character:FindFirstChild("Right Arm")
	end

	return left, right
end

-- Find left and right ski parts from any model structure
local function findSkiParts(model)
	-- Try explicit names first
	local left = model:FindFirstChild("LeftSki")
	local right = model:FindFirstChild("RightSki")

	if left and right then
		return left, right
	end

	-- Try other common naming conventions
	local namePatterns = {
		left  = {"LeftSki", "Left_Ski", "Left", "Ski_L", "SkiLeft", "ski_left"},
		right = {"RightSki", "Right_Ski", "Right", "Ski_R", "SkiRight", "ski_right"},
	}

	for _, name in ipairs(namePatterns.left) do
		left = left or model:FindFirstChild(name)
	end
	for _, name in ipairs(namePatterns.right) do
		right = right or model:FindFirstChild(name)
	end

	if left and right then
		return left, right
	end

	-- Fallback: grab any two BaseParts
	local parts = {}
	for _, desc in ipairs(model:GetDescendants()) do
		if desc:IsA("BasePart") then
			table.insert(parts, desc)
		end
	end

	if #parts >= 2 then
		return parts[1], parts[2]
	elseif #parts == 1 then
		-- Only one part — duplicate it
		local clone = parts[1]:Clone()
		clone.Name = "RightSki"
		clone.Parent = model
		return parts[1], clone
	end

	return nil, nil
end

-- ============================================================================
-- SKI EQUIP / UNEQUIP
-- ============================================================================

local function equipSkis(player)
	local character = player.Character
	if not character then return false end

	local humanoid = character:FindFirstChild("Humanoid")
	if not humanoid then return false end

	-- AvatarAppearanceServer already owns description/shoe application.
	-- Reapplying descriptions here can rebuild character internals and strip ski attachments.
	character = player.Character
	if not character then return false end
	humanoid = character:FindFirstChild("Humanoid")
	if not humanoid then return false end

	-- Already equipped?
	if character:FindFirstChild("Skis") then
		return true
	end

	-- Need ski asset (retry in case asset loaded after script init)
	if (not SkiAsset) or (not SkiAsset.Parent) then
		SkiAsset = findSkiAsset()
	end
	if not SkiAsset then
		warn("⚠️ No ski asset for", player.Name)
		return false
	end

	-- Get foot parts
	local leftFoot, rightFoot = getFootParts(character, humanoid)
	if not leftFoot or not rightFoot then
		return false
	end

	-- Clone the ski model
	local skiModel = SkiAsset:Clone()
	skiModel.Name = "Skis"

	-- Find the two ski parts
	local leftSki, rightSki = findSkiParts(skiModel)
	if not leftSki or not rightSki then
		skiModel:Destroy()
		return false
	end

	-- Prepare all parts in the model
	for _, part in ipairs(skiModel:GetDescendants()) do
		if part:IsA("BasePart") then
			preparePartForWeld(part)

			-- Apply scale if configured
			if SETTINGS.Scale ~= 1.0 then
				part.Size = part.Size * SETTINGS.Scale
			end
		end
	end

	-- Parent model first (must be in workspace for welding to work)
	skiModel.Parent = character

	-- Weld each ski to the corresponding foot
	weldSki(leftSki, leftFoot)
	weldSki(rightSki, rightFoot)

	-- Add pole accessories from ReplicatedStorage (LeftPole/RightPole).
	addPoleAccessories(character, humanoid)

	-- Keep movement simulation with the owning player for responsive local ski physics.
	local rootPart = character:FindFirstChild("HumanoidRootPart")
	if rootPart then
		local canSetOwnership = false
		pcall(function()
			canSetOwnership = rootPart:CanSetNetworkOwnership()
		end)
		if canSetOwnership then
			pcall(function()
				rootPart:SetNetworkOwner(player)
			end)
		end
	end

	return true
end

local function unequipSkis(player)
	local character = player.Character
	if not character then return end

	local skis = character:FindFirstChild("Skis")
	if skis then
		skis:Destroy()
	end

	local poles = character:FindFirstChild("SkiPoles")
	if poles then
		poles:Destroy()
	end

	clearPoleAttachments(character)
end

-- ============================================================================
-- AVATAR JOINT UPGRADE — DEATH RAGDOLL
-- ============================================================================

local function setupDeathRagdoll(character)
	if not SETTINGS.DeathRagdoll.Enabled then return end

	local humanoid = character:FindFirstChild("Humanoid")
	if not humanoid then return end

	-- Prevent joints from breaking on death (required for ragdoll)
	humanoid.BreakJointsOnDeath = false

	humanoid.Died:Connect(function()
		-- Find all AnimationConstraints and make them weak → ragdoll
		local constraintCount = 0
		for _, desc in pairs(character:GetDescendants()) do
			if desc:IsA("AnimationConstraint") then
				pcall(function()
					desc.IsKinematic = false
					desc.MaxForce = SETTINGS.DeathRagdoll.MaxForce
					desc.MaxTorque = SETTINGS.DeathRagdoll.MaxTorque
				end)
				constraintCount = constraintCount + 1
			end
		end

		if constraintCount > 0 then
			-- Enable collision on body parts for ragdoll
			for _, part in pairs(character:GetDescendants()) do
				if part:IsA("BasePart") then
					part.CanCollide = true
				end
			end
		end
	end)
end

-- ============================================================================
-- EVENT CONNECTIONS
-- ============================================================================

-- Handle equip/unequip requests from clients
SkiEvent.OnServerEvent:Connect(function(player, shouldEquip)
	if shouldEquip then
		equipSkis(player)
	else
		unequipSkis(player)
	end
end)

-- Setup each new character
Players.PlayerAdded:Connect(function(player)
	player.CharacterAdded:Connect(function(character)
		-- Wait for humanoid to load
		local humanoid = character:WaitForChild("Humanoid", 10)
		if not humanoid then return end

		-- Setup death ragdoll
		setupDeathRagdoll(character)
	end)
end)

-- Setup existing players (in case script loads late)
for _, player in ipairs(Players:GetPlayers()) do
	if player.Character then
		setupDeathRagdoll(player.Character)
	end

	player.CharacterAdded:Connect(function(character)
		local humanoid = character:WaitForChild("Humanoid", 10)
		if not humanoid then return end
		setupDeathRagdoll(character)
	end)
end

-- Cleanup on leave (character auto-destroys, but be safe)
Players.PlayerRemoving:Connect(function(player)
	AppearanceCache[player.UserId] = nil
	if player.Character then
		local skis = player.Character:FindFirstChild("Skis")
		if skis then skis:Destroy() end
	end
end)
