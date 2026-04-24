local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local RunService = game:GetService("RunService")

local Events = ReplicatedStorage:FindFirstChild("Events") or Instance.new("Folder")
Events.Name = "Events"
Events.Parent = ReplicatedStorage

local SPILL_FOLDER = Workspace:FindFirstChild("Spills") or Instance.new("Folder")
SPILL_FOLDER.Name = "Spills"
SPILL_FOLDER.Parent = Workspace

local MOP_CLEAN_DURATION = 1.05
local SPILL_RECONCILE_INTERVAL = 12
local JANITOR_CLEAN_INTERVAL = 1.0
local MAX_SPILLS_PER_BUILDING = 3
local TRASH_BIN_RADIUS = 34
local PLAYER_CLEAN_BONUS = 22
local JANITOR_CLEAN_BONUS = 10
local JANITOR_SEARCH_RADIUS = 420
local JANITOR_GLOBAL_SEARCH_RADIUS = 1400
local JANITOR_CLEAN_REACH = 6.5
local JANITOR_WALK_TIMEOUT = 16
local JANITOR_STALL_REPOSITION_SECONDS = 4
local JANITOR_MAX_REPOSITIONS = 2
local SPILL_CLUSTER_RADIUS = 4.25
local RECENT_CLEAN_SUPPRESSION_SECONDS = 45
local SPILL_BUSY_STALE_SECONDS = 20

local TRASH_BIN_NAMES = {
	["Trash Bin"] = true,
	["Double Trash Bin"] = true,
}

local CLEANABLE_TYPES = {
	food = true,
	rental = true,
	house = true,
	restaurant = true,
	cafe = true,
	hotel = true,
	lodging = true,
}

local PREFERRED_SPILL_MARKERS = {
	"Window", "Counter", "Desk", "Pickup", "Register", "Queue", "GuestSpawn", "Entry", "Entrance", "Door",
}

local equippedMops = {}
local mopAnimations = {}
local janitorBusy = {}

local function getPlacedObjects()
	return Workspace:FindFirstChild("PlacedObjects")
end

local function getEmployeesFolder()
	return Workspace:FindFirstChild("Employees")
end

local function getOwnerId(instance)
	if not instance then
		return nil
	end
	local owner = instance:GetAttribute("Owner")
	local ownerId = instance:GetAttribute("OwnerId")
	local ownerUserId = instance:GetAttribute("OwnerUserId")
	local employeeOwnerId = instance:GetAttribute("EmployeeOwnerId")
	return tonumber(owner) or tonumber(ownerId) or tonumber(ownerUserId) or tonumber(employeeOwnerId)
end

local function isPlacedObjectRootModel(obj, placed)
	if not (obj and obj:IsA("Model") and placed) then
		return false
	end
	local current = obj.Parent
	while current and current ~= placed do
		if current:IsA("Model") then
			local currentType = current:GetAttribute("Type")
			local currentCategory = current:GetAttribute("Category")
			local currentUuid = current:GetAttribute("UUID")
			if currentType ~= nil or currentCategory ~= nil or currentUuid ~= nil then
				return false
			end
		end
		current = current.Parent
	end
	return current == placed
end

local function getPlacedRootModels()
	local placed = getPlacedObjects()
	local results = {}
	if not placed then
		return results
	end
	for _, obj in ipairs(placed:GetDescendants()) do
		if isPlacedObjectRootModel(obj, placed) then
			table.insert(results, obj)
		end
	end
	return results
end

local function lowerMatch(value, patterns)
	local lowered = string.lower(tostring(value or ""))
	for _, pattern in ipairs(patterns) do
		if string.find(lowered, pattern, 1, true) then
			return true
		end
	end
	return false
end

local function stableHash(text)
	local hash = 5381
	for i = 1, #text do
		hash = (hash * 33 + string.byte(text, i)) % 2147483647
	end
	return hash
end

local function isCleanableAmenityModel(obj)
	if not obj or not obj:IsA("Model") then
		return false
	end
	local objType = string.lower(tostring(obj:GetAttribute("Type") or ""))
	local objCategory = string.lower(tostring(obj:GetAttribute("Category") or ""))
	local lowerName = string.lower(obj.Name)
	if CLEANABLE_TYPES[objType] or CLEANABLE_TYPES[objCategory] then
		return true
	end
	return lowerMatch(lowerName, {"restaurant", "food", "cafe", "rental", "cabin", "lodge", "hotel", "house", "snack", "shop"})
end

local function isTrashBinModel(obj)
	return obj and obj:IsA("Model") and TRASH_BIN_NAMES[obj.Name] == true
end

local function getBuildingAnchor(building)
	for _, markerName in ipairs(PREFERRED_SPILL_MARKERS) do
		local found = building:FindFirstChild(markerName, true)
		if found and found:IsA("BasePart") then
			return found.Position
		end
	end
	local primary = building.PrimaryPart or building:FindFirstChildWhichIsA("BasePart")
	if primary then
		return primary.Position
	end
	local cf = building:GetPivot()
	return cf.Position
end

local function getSpillAnchorCandidates(building)
	local candidates = {}
	for _, markerName in ipairs(PREFERRED_SPILL_MARKERS) do
		for _, desc in ipairs(building:GetDescendants()) do
			if desc:IsA("BasePart") and desc.Name == markerName then
				table.insert(candidates, {
					position = desc.Position,
					right = desc.CFrame.RightVector,
					look = desc.CFrame.LookVector,
					kind = string.lower(markerName),
				})
			end
		end
	end
	if #candidates == 0 then
		local primary = building.PrimaryPart or building:FindFirstChildWhichIsA("BasePart")
		local pivot = primary and primary.CFrame or building:GetPivot()
		table.insert(candidates, {
			position = pivot.Position,
			right = pivot.RightVector,
			look = pivot.LookVector,
			kind = "fallback",
		})
	end
	return candidates
end

local function getNearbyTrashBins(ownerId, center)
	local bins = {}
	for _, model in ipairs(getPlacedRootModels()) do
		if getOwnerId(model) == ownerId and isTrashBinModel(model) then
			local pos = getBuildingAnchor(model)
			if (pos - center).Magnitude <= TRASH_BIN_RADIUS then
				table.insert(bins, model)
			end
		end
	end
	return bins
end

local function raycastGround(origin, blacklist)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = blacklist
	params.IgnoreWater = true
	return Workspace:Raycast(origin, Vector3.new(0, -48, 0), params)
end

local function getSpillGroundPosition(building, ownerId, index)
	local pivot, size = building:GetBoundingBox()
	local center = getBuildingAnchor(building)
	local bins = getNearbyTrashBins(ownerId, center)
	local blacklist = {building, SPILL_FOLDER}
	for _, bin in ipairs(bins) do
		table.insert(blacklist, bin)
	end

	local uuidSeed = tostring(building:GetAttribute("UUID") or building.Name)
	local rng = Random.new(stableHash(uuidSeed) + index * 101)
	local anchors = getSpillAnchorCandidates(building)
	local anchor = anchors[((index - 1) % #anchors) + 1]
	local lateralLimit = math.max(2.2, math.min(size.X * 0.34, SPILL_CLUSTER_RADIUS + 0.9))
	local minimumSafeY = center.Y - (size.Y * 0.28)
	local outward = Vector3.new(anchor.position.X - center.X, 0, anchor.position.Z - center.Z)
	if outward.Magnitude < 0.2 then
		outward = Vector3.new(anchor.look.X, 0, anchor.look.Z)
	end
	if outward.Magnitude < 0.05 then
		outward = Vector3.new(0, 0, -1)
	else
		outward = outward.Unit
	end
	local sideAxis = Vector3.new(anchor.right.X, 0, anchor.right.Z)
	if sideAxis.Magnitude < 0.05 then
		sideAxis = outward:Cross(Vector3.yAxis)
	else
		sideAxis = sideAxis.Unit
	end
	local footprintRadius = math.max(size.X, size.Z) * 0.5
	local baseOutsideDistance = footprintRadius + ((anchor.kind == "window" or anchor.kind == "counter" or anchor.kind == "register" or anchor.kind == "pickup") and 3.4 or 2.8)
	local baseOutside = center + outward * baseOutsideDistance

	for attempt = 1, 10 do
		local sideBias = (((index + attempt) % 2 == 0) and 1 or -1)
		local lateral = math.clamp(sideBias * (1.1 + ((index - 1) % 3) * 0.7) + rng:NextNumber(-0.65, 0.65), -lateralLimit, lateralLimit)
		local forward = rng:NextNumber(0.3, 1.7)
		local samplePos = baseOutside + sideAxis * lateral + outward * forward
		local localPos = pivot:PointToObjectSpace(samplePos)
		local outsideMargin = 1.6
		local clearlyOutside = math.abs(localPos.X) >= (size.X * 0.5 + outsideMargin) or math.abs(localPos.Z) >= (size.Z * 0.5 + outsideMargin)
		if clearlyOutside then
			local sample = samplePos + Vector3.new(rng:NextNumber(-0.22, 0.22), 8, rng:NextNumber(-0.22, 0.22))
			local tooCloseToBin = false
			for _, bin in ipairs(bins) do
				if (getBuildingAnchor(bin) - sample).Magnitude < 12 then
					tooCloseToBin = true
					break
				end
			end
			if not tooCloseToBin then
				local hit = raycastGround(sample, blacklist)
				if hit and hit.Position.Y >= minimumSafeY then
					return hit.Position, hit.Normal
				end
			end
		end
	end

	local fallbackSample = baseOutside + outward * 2.5 + Vector3.new(0, 10, 0)
	local hit = raycastGround(fallbackSample, blacklist)
	if hit and hit.Position.Y >= minimumSafeY then
		local fallbackLocal = pivot:PointToObjectSpace(hit.Position)
		local outsideMargin = 1.8
		local clearlyOutside = math.abs(fallbackLocal.X) >= (size.X * 0.5 + outsideMargin) or math.abs(fallbackLocal.Z) >= (size.Z * 0.5 + outsideMargin)
		if clearlyOutside then
			return hit.Position, hit.Normal
		end
	end
	return nil, nil
end

local function findBuildingByUUID(uuid)
	if not uuid then
		return nil
	end
	for _, model in ipairs(getPlacedRootModels()) do
		if tostring(model:GetAttribute("UUID") or "") == uuid then
			return model
		end
	end
	return nil
end

local function adjustBuildingCleanliness(building, amount)
	if not building then
		return
	end
	local current = math.clamp(tonumber(building:GetAttribute("Cleanliness")) or 55, 0, 100)
	local updated = math.clamp(current + amount, 0, 100)
	building:SetAttribute("Cleanliness", updated)
	building:SetAttribute("Dirtiness", 100 - updated)
	building:SetAttribute("NeedsCleaning", updated < 62)
end

local function isPlayerCloseToSpill(player, root)
	local character = player and player.Character
	if not (character and root and root:IsA("BasePart")) then
		return false
	end
	local hrp = character:FindFirstChild("HumanoidRootPart") or character.PrimaryPart
	if not hrp or not hrp:IsA("BasePart") then
		return false
	end
	return (hrp.Position - root.Position).Magnitude <= 12
end

local function getDesiredSpillCount(building)
	local ownerId = getOwnerId(building)
	if not ownerId then
		return 0
	end
	local cleanliness = math.clamp(tonumber(building:GetAttribute("Cleanliness")) or 55, 0, 100)
	local dirtiness = math.max(0, tonumber(building:GetAttribute("Dirtiness")) or (100 - cleanliness))
	local traffic = math.max(0, tonumber(building:GetAttribute("CleanAreaTraffic")) or 0)
	local hasJanitor = building:GetAttribute("HasJanitor") == true or (tonumber(building:GetAttribute("JanitorLevel")) or 0) > 0
	local needsCleaning = building:GetAttribute("NeedsCleaning") == true
	local bins = #getNearbyTrashBins(ownerId, getBuildingAnchor(building))

	local desired = 0
	if cleanliness < 92 then desired += 1 end
	if cleanliness < 80 then desired += 1 end
	if cleanliness < 66 then desired += 1 end
	if dirtiness >= 48 then desired += 1 end
	if traffic >= 10 then desired += 1 end
	if needsCleaning then
		desired += 1
	end
	if hasJanitor then
		desired -= 1
	end
	local lastSpillCleanAt = tonumber(building:GetAttribute("LastSpillCleanAt")) or 0
	if lastSpillCleanAt > 0 and (os.clock() - lastSpillCleanAt) < RECENT_CLEAN_SUPPRESSION_SECONDS then
		desired -= 2
	end
	desired -= math.min(bins, 2)
	return math.clamp(math.ceil(desired * 0.5), 0, MAX_SPILLS_PER_BUILDING)
end

local function makeBlob(parent, pos, yaw, scaleX, scaleZ, color)
	local blob = Instance.new("Part")
	blob.Name = "SpillBlob"
	blob.Anchored = true
	blob.CanCollide = false
	blob.CanQuery = false
	blob.CanTouch = false
	blob.Material = Enum.Material.SmoothPlastic
	blob.Color = color
	blob.Transparency = 0.06
	blob.Size = Vector3.new(0.7, 0.08, 0.7)
	blob.CastShadow = false
	blob.CFrame = CFrame.new(pos) * CFrame.Angles(0, math.rad(yaw), 0)
	local mesh = Instance.new("SpecialMesh")
	mesh.MeshType = Enum.MeshType.Sphere
	mesh.Scale = Vector3.new(scaleX, 0.18, scaleZ)
	mesh.Parent = blob
	blob.Parent = parent
	return blob
end

local function createCleanBurst(root)
	local attachment = Instance.new("Attachment")
	attachment.Name = "BurstAttachment"
	attachment.Parent = root

	local emitter = Instance.new("ParticleEmitter")
	emitter.Name = "CleanBurst"
	emitter.Texture = "rbxasset://textures/particles/sparkles_main.dds"
	emitter.Rate = 0
	emitter.Speed = NumberRange.new(1.5, 3)
	emitter.Lifetime = NumberRange.new(0.35, 0.7)
	emitter.SpreadAngle = Vector2.new(25, 25)
	emitter.Rotation = NumberRange.new(0, 360)
	emitter.RotSpeed = NumberRange.new(-90, 90)
	emitter.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.35),
		NumberSequenceKeypoint.new(1, 0.05),
	})
	emitter.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.05),
		NumberSequenceKeypoint.new(1, 1),
	})
	emitter.Color = ColorSequence.new(Color3.fromRGB(220, 244, 255), Color3.fromRGB(176, 220, 255))
	emitter.Parent = attachment
	emitter:Emit(14)
	game:GetService("Debris"):AddItem(attachment, 1.5)
end

local function destroySpill(spill)
	if spill and spill.Parent then
		local root = spill:FindFirstChild("Root")
		if root and root:IsA("BasePart") then
			createCleanBurst(root)
		end
		task.delay(0.05, function()
			if spill and spill.Parent then
				spill:Destroy()
			end
		end)
	end
end

local function getMopTemplate()
	local assets = ReplicatedStorage:FindFirstChild("Assets")
	local gear = assets and assets:FindFirstChild("Gear")
	local mop = gear and gear:FindFirstChild("Mop")
	if mop and mop:IsA("Model") then
		return mop
	end
	return nil
end

local function getRightGripPart(character)
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return nil
	end
	if humanoid.RigType == Enum.HumanoidRigType.R15 then
		return character:FindFirstChild("RightHand") or character:FindFirstChild("RightLowerArm") or character:FindFirstChild("RightUpperArm")
	end
	return character:FindFirstChild("Right Arm")
end

local function getRightShoulderJoint(character)
	if not character then
		return nil
	end
	for _, desc in ipairs(character:GetDescendants()) do
		if desc:IsA("Motor6D") and (desc.Name == "RightShoulder" or desc.Name == "Right Shoulder") then
			return desc
		end
	end
	return nil
end

local function cleanupMop(character)
	local entry = equippedMops[character]
	if not entry then
		return
	end
	equippedMops[character] = nil
	mopAnimations[character] = nil
	if entry.Shoulder then
		entry.Shoulder.Transform = CFrame.new()
	end
	if entry.Joint then
		entry.Joint.Transform = CFrame.new()
	end
	if entry.Model and entry.Model.Parent then
		entry.Model:Destroy()
	end
end

local function rigidizeMop(mop)
	local handle = mop:FindFirstChild("WoodenHandle(stick)", true) or mop:FindFirstChildWhichIsA("BasePart")
	if not handle or not handle:IsA("BasePart") then
		return nil, nil, {}
	end
	local bottomBase = mop:FindFirstChild("MopBottomBase", true) or handle
	local hairContainer = mop:FindFirstChild("MopHairs", true)
	local hairs = {}
	for _, desc in ipairs(mop:GetDescendants()) do
		if desc:IsA("JointInstance") or desc:IsA("WeldConstraint") then
			desc:Destroy()
		end
	end
	for _, desc in ipairs(mop:GetDescendants()) do
		if desc:IsA("BasePart") then
			local isHair = string.lower(desc.Name) == "mophairs"
			if not isHair and hairContainer then
				isHair = desc:IsDescendantOf(hairContainer)
			end
			desc.CanCollide = false
			desc.CanQuery = false
			desc.CanTouch = false
			desc.Massless = true
			if isHair then
				desc.Anchored = true
				desc.CastShadow = false
				table.insert(hairs, desc)
			else
				desc.Anchored = false
				if desc ~= handle then
					local weld = Instance.new("WeldConstraint")
					weld.Name = "SpillRigidWeld"
					weld.Part0 = handle
					weld.Part1 = desc
					weld.Parent = desc
				end
			end
		end
	end
	return handle, (bottomBase and bottomBase:IsA("BasePart") and bottomBase or handle), hairs
end

local function equipMop(character, persistent)
	if not character then
		return nil
	end
	local existing = equippedMops[character]
	if existing then
		if existing.Model and existing.Model.Parent and existing.Base and existing.Base.Parent then
			return existing
		end
		cleanupMop(character)
	end
	local limb = getRightGripPart(character)
	if not limb or not limb:IsA("BasePart") then
		return nil
	end
	local template = getMopTemplate()
	if not template then
		return nil
	end
	local mop = template:Clone()
	mop.Name = persistent and "JanitorMop" or "SpillMop"

	local grip = mop:FindFirstChild("Grip", true)
	if grip and grip:IsA("Attachment") then
		local gripOffset = mop:GetPivot():ToObjectSpace(grip.WorldCFrame)
		mop:PivotTo(limb.CFrame * gripOffset:Inverse())
	end

	local handle, base, hairs = rigidizeMop(mop)
	if not handle then
		mop:Destroy()
		return nil
	end
	mop.Parent = character
	mop.PrimaryPart = handle

	local joint = Instance.new("Motor6D")
	joint.Name = "SpillMopJoint"
	joint.Part0 = limb
	joint.Part1 = handle
	joint.C0 = limb.CFrame:ToObjectSpace(handle.CFrame)
	joint.Parent = limb

	local brush = handle:FindFirstChild("Brush")
	local shoulder = getRightShoulderJoint(character)
	local entry = {
		Model = mop,
		Joint = joint,
		Base = base,
		Shoulder = shoulder,
		Brush = brush,
		Hairs = {},
		PreviousBasePosition = base.Position,
		Persistent = persistent == true,
	}
	for _, hair in ipairs(hairs) do
		table.insert(entry.Hairs, {
			Part = hair,
			LocalOffset = base.CFrame:ToObjectSpace(hair.CFrame),
			WorldPosition = hair.Position,
		})
	end
	for _, hairState in ipairs(entry.Hairs) do
		local desiredCF = base.CFrame * hairState.LocalOffset
		hairState.WorldPosition = desiredCF.Position
		hairState.Part.CFrame = desiredCF
	end
	equippedMops[character] = entry
	return entry
end

local function animateMop(character, duration)
	local entry = equippedMops[character]
	if not entry or mopAnimations[character] then
		return
	end
	duration = duration or MOP_CLEAN_DURATION
	mopAnimations[character] = true
	task.spawn(function()
		local start = os.clock()
		if entry.Brush and entry.Brush:IsA("Sound") then
			entry.Brush.RollOffMode = Enum.RollOffMode.Linear
			entry.Brush.RollOffMaxDistance = 22
			entry.Brush.RollOffMinDistance = 6
			entry.Brush.EmitterSize = 4
			entry.Brush.Volume = 0.28
			entry.Brush.PlaybackSpeed = 0.94 + math.random() * 0.12
			entry.Brush.TimePosition = 0
			entry.Brush:Play()
		end
		while character.Parent and equippedMops[character] == entry do
			local alpha = (os.clock() - start) / duration
			if alpha >= 1 then
				break
			end
			local wave = math.sin(alpha * math.pi * 4)
			entry.Joint.Transform = CFrame.new(0, -0.03 * wave, -0.03 * math.abs(wave)) * CFrame.Angles(math.rad(-8 - (wave * 14)), 0, math.rad(6 + (wave * 5)))
			if entry.Shoulder then
				entry.Shoulder.Transform = CFrame.Angles(math.rad(-10 - (wave * 18)), 0, math.rad(-4 + (wave * 8)))
			end
			RunService.Heartbeat:Wait()
		end
		if equippedMops[character] == entry then
			entry.Joint.Transform = CFrame.new()
			if entry.Shoulder then
				entry.Shoulder.Transform = CFrame.new()
			end
		end
		mopAnimations[character] = nil
	end)
end

local function updateMopHair(dt)
	for character, entry in pairs(equippedMops) do
		if not character.Parent or not entry.Model.Parent or not entry.Base.Parent then
			cleanupMop(character)
		else
			local base = entry.Base
			local velocity = (base.Position - entry.PreviousBasePosition) / math.max(dt, 1 / 120)
			entry.PreviousBasePosition = base.Position
			for index, hairState in ipairs(entry.Hairs) do
				local hair = hairState.Part
				if hair and hair.Parent then
					local desiredCF = base.CFrame * hairState.LocalOffset
					local dragOffset = Vector3.new(-velocity.X, 0, -velocity.Z)
					if dragOffset.Magnitude > 1.75 then
						dragOffset = dragOffset.Unit * math.min(dragOffset.Magnitude * 0.018, 0.7)
					else
						dragOffset = dragOffset * 0.01
					end
					local targetPos = desiredCF.Position + dragOffset + Vector3.new(0, -0.18, 0)
					local hit = raycastGround(targetPos + Vector3.new(0, 2.2, 0), {character, SPILL_FOLDER})
					if hit then
						targetPos = Vector3.new(targetPos.X, hit.Position.Y + (hair.Size.Y * 0.35), targetPos.Z)
					end
					hairState.WorldPosition = hairState.WorldPosition:Lerp(targetPos, math.clamp(dt * 10, 0, 1))
					local flatLook = Vector3.new(base.CFrame.LookVector.X, 0, base.CFrame.LookVector.Z)
					if flatLook.Magnitude < 0.01 then
						flatLook = Vector3.new(0, 0, -1)
					else
						flatLook = flatLook.Unit
					end
					hair.CFrame = CFrame.lookAt(hairState.WorldPosition, hairState.WorldPosition + flatLook, Vector3.yAxis) * CFrame.Angles(0, 0, math.rad((index % 2 == 0) and 10 or -10))
				end
			end
		end
	end
end

local function getBuildingSpills(uuid)
	local spills = {}
	for _, spill in ipairs(SPILL_FOLDER:GetChildren()) do
		if spill:IsA("Model") and spill:GetAttribute("BuildingUUID") == uuid then
			table.insert(spills, spill)
		end
	end
	return spills
end

local function createSpill(building, ownerId, index)
	local uuid = tostring(building:GetAttribute("UUID") or "")
	if uuid == "" then
		return nil
	end
	local position = getSpillGroundPosition(building, ownerId, index)
	if not position then
		return nil
	end
	local spill = Instance.new("Model")
	spill.Name = "Spill_" .. uuid .. "_" .. tostring(index)
	spill:SetAttribute("BuildingUUID", uuid)
	spill:SetAttribute("OwnerId", ownerId)
	spill.Parent = SPILL_FOLDER

	local root = Instance.new("Part")
	root.Name = "Root"
	root.Size = Vector3.new(2.6, 0.24, 2.6)
	root.Transparency = 1
	root.Anchored = true
	root.CanCollide = false
	root.CanQuery = false
	root.CanTouch = false
	root.Position = position + Vector3.new(0, 0.05, 0)
	root.Parent = spill

	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "CleanPrompt"
	prompt.ActionText = "Clean Spill"
	prompt.ObjectText = "Spill"
	prompt.HoldDuration = 1
	prompt.MaxActivationDistance = 8
	prompt.RequiresLineOfSight = false
	prompt.KeyboardKeyCode = Enum.KeyCode.E
	prompt.GamepadKeyCode = Enum.KeyCode.ButtonX
	prompt.ClickablePrompt = true
	prompt.Style = Enum.ProximityPromptStyle.Custom
	prompt:SetAttribute("IsSpillPrompt", true)
	prompt.Parent = root

	local rng = Random.new(stableHash(uuid) + index * 37)
	makeBlob(spill, root.Position + Vector3.new(rng:NextNumber(-0.2, 0.2), 0, rng:NextNumber(-0.2, 0.2)), rng:NextNumber(0, 360), rng:NextNumber(4.8, 6.8), rng:NextNumber(4.2, 6.2), Color3.fromRGB(52, 44, 40))
	local blobCount = rng:NextInteger(1, 3)
	for blobIndex = 1, blobCount do
		local offset = Vector3.new(rng:NextNumber(-1.35, 1.35), 0, rng:NextNumber(-1.35, 1.35))
		local color = (blobIndex % 2 == 0) and Color3.fromRGB(96, 72, 54) or Color3.fromRGB(55, 46, 42)
		makeBlob(spill, root.Position + offset, rng:NextNumber(0, 360), rng:NextNumber(1.6, 2.8), rng:NextNumber(1.4, 2.6), color)
	end
	if rng:NextNumber() > 0.68 then
		local litter = Instance.new("Part")
		litter.Name = "Litter"
		litter.Anchored = true
		litter.CanCollide = false
		litter.CanQuery = false
		litter.CanTouch = false
		litter.Material = Enum.Material.SmoothPlastic
		litter.Color = Color3.fromRGB(224, 220, 198)
		litter.CastShadow = false
		litter.Size = Vector3.new(rng:NextNumber(0.18, 0.34), 0.03, rng:NextNumber(0.25, 0.44))
		litter.CFrame = CFrame.new(root.Position + Vector3.new(rng:NextNumber(-0.6, 0.6), 0.03, rng:NextNumber(-0.6, 0.6))) * CFrame.Angles(0, math.rad(rng:NextNumber(0, 360)), math.rad(rng:NextNumber(-12, 12)))
		litter.Parent = spill
	end

	prompt.Triggered:Connect(function(player)
		if spill:GetAttribute("Busy") == true then
			return
		end
		if not isPlayerCloseToSpill(player, root) then
			return
		end
		spill:SetAttribute("Busy", true)
		spill:SetAttribute("BusySince", os.clock())
		prompt.Enabled = false
		local character = player.Character
		local entry = character and equipMop(character, false)
		if entry then
			animateMop(character, MOP_CLEAN_DURATION)
		end
		task.delay(MOP_CLEAN_DURATION, function()
			local currentBuilding = findBuildingByUUID(uuid)
			if currentBuilding then
				currentBuilding:SetAttribute("LastSpillCleanAt", os.clock())
			end
			adjustBuildingCleanliness(currentBuilding, PLAYER_CLEAN_BONUS)
			destroySpill(spill)
			if character and equippedMops[character] and not equippedMops[character].Persistent then
				cleanupMop(character)
			end
		end)
	end)

	return spill
end

local function reconcileSpills()
	local seen = {}
	for _, building in ipairs(getPlacedRootModels()) do
		if isCleanableAmenityModel(building) then
			local uuid = tostring(building:GetAttribute("UUID") or "")
			local ownerId = getOwnerId(building)
			if uuid ~= "" and ownerId then
				seen[uuid] = true
				local desired = getDesiredSpillCount(building)
				local existing = getBuildingSpills(uuid)
				if #existing < desired then
					for index = #existing + 1, desired do
						createSpill(building, ownerId, index)
					end
				elseif #existing > desired then
					for index = desired + 1, #existing do
						if existing[index] then
							existing[index]:Destroy()
						end
					end
				end
			end
		end
	end
	for _, spill in ipairs(SPILL_FOLDER:GetChildren()) do
		if spill:IsA("Model") then
			local buildingUuid = tostring(spill:GetAttribute("BuildingUUID") or "")
			if buildingUuid == "" or not seen[buildingUuid] then
				spill:Destroy()
			end
		end
	end
end

local function getModelRoot(model)
	return model and (model:FindFirstChild("HumanoidRootPart") or model.PrimaryPart)
end

local function computeJanitorApproachPosition(janitorModel, spill)
	local spillRoot = spill and spill:FindFirstChild("Root")
	if not (spillRoot and spillRoot:IsA("BasePart")) then
		return nil
	end
	local janitorRoot = getModelRoot(janitorModel)
	local flatDelta = janitorRoot and Vector3.new(spillRoot.Position.X - janitorRoot.Position.X, 0, spillRoot.Position.Z - janitorRoot.Position.Z) or Vector3.zero
	local direction = flatDelta.Magnitude > 0.05 and flatDelta.Unit or Vector3.new(0, 0, -1)
	local blacklist = {janitorModel, SPILL_FOLDER}
	local buildingUuid = tostring(spill:GetAttribute("BuildingUUID") or "")
	local building = buildingUuid ~= "" and findBuildingByUUID(buildingUuid) or nil
	local buildingCenter, buildingSize = nil, nil
	if building then
		table.insert(blacklist, building)
		buildingCenter, buildingSize = building:GetBoundingBox()
	end
	local outward = direction
	local sideways = Vector3.new(-direction.Z, 0, direction.X)
	if sideways.Magnitude < 0.05 then
		sideways = Vector3.new(1, 0, 0)
	else
		sideways = sideways.Unit
	end
	for step = 1, 10 do
		local forwardDist = 2.2 + (step * 0.9)
		local sideDist = (step % 2 == 0 and 1 or -1) * (0.65 + ((step - 1) % 3) * 0.45)
		local sample = spillRoot.Position - outward * forwardDist + sideways * sideDist + Vector3.new(0, 8, 0)
		local hit = raycastGround(sample, blacklist)
		if hit then
			if not buildingCenter or not buildingSize then
				return hit.Position
			end
			local localPos = buildingCenter:PointToObjectSpace(hit.Position)
			local margin = 1.5
			if math.abs(localPos.X) >= (buildingSize.X * 0.5 + margin) or math.abs(localPos.Z) >= (buildingSize.Z * 0.5 + margin) then
				return hit.Position
			end
		end
	end
	local fallbackSample = spillRoot.Position - outward * 5 + Vector3.new(0, 5, 0)
	local fallbackHit = raycastGround(fallbackSample, blacklist)
	if fallbackHit then
		return fallbackHit.Position
	end
	return fallbackSample + Vector3.new(0, 1.5, 0)
end

local function setSpillPromptEnabled(spill, enabled)
	local prompt = spill and spill:FindFirstChild("CleanPrompt", true)
	if prompt and prompt:IsA("ProximityPrompt") then
		prompt.Enabled = enabled
	end
end

local function releaseJanitorTask(janitorModel, releaseSpill)
	local taskData = janitorBusy[janitorModel]
	janitorBusy[janitorModel] = nil
	if janitorModel and janitorModel.Parent then
		janitorModel:SetAttribute("TargetPosition", nil)
		janitorModel:SetAttribute("SpillTaskActive", false)
		janitorModel:SetAttribute("SpillTaskState", nil)
	end
	if taskData and taskData.Spill and taskData.Spill.Parent then
		taskData.Spill:SetAttribute("ClaimedByEmployeeUUID", nil)
		taskData.Spill:SetAttribute("ClaimedByEmployeeName", nil)
		if releaseSpill then
			taskData.Spill:SetAttribute("Busy", false)
			taskData.Spill:SetAttribute("BusySince", nil)
			setSpillPromptEnabled(taskData.Spill, true)
		end
	end
end

local function getNearestSpillForJanitor(janitorModel)
	local hrp = getModelRoot(janitorModel)
	if not hrp then
		return nil
	end
	local ownerId = getOwnerId(janitorModel)
	if not ownerId then
		return nil
	end
	local best, bestDistance = nil, math.huge
	for _, spill in ipairs(SPILL_FOLDER:GetChildren()) do
		if spill:IsA("Model") and spill:GetAttribute("Busy") ~= true then
			local spillOwnerId = spill:GetAttribute("OwnerId")
			local sameOwner = spillOwnerId == ownerId
			if not sameOwner and spillOwnerId ~= nil then
				sameOwner = tostring(spillOwnerId) == tostring(ownerId)
			end
			if sameOwner then
				local root = spill:FindFirstChild("Root")
				if root and root:IsA("BasePart") then
					local dist = (root.Position - hrp.Position).Magnitude
					if dist < bestDistance then
						best = spill
						bestDistance = dist
					end
				end
			end
		end
	end
	if not best then
		return nil
	end
	if bestDistance <= JANITOR_SEARCH_RADIUS then
		return best
	end
	if bestDistance <= JANITOR_GLOBAL_SEARCH_RADIUS then
		return best
	end
	return nil
end

local function beginJanitorTask(janitorModel, spill)
	local root = spill and spill:FindFirstChild("Root")
	if not (root and root:IsA("BasePart")) then
		return
	end
	spill:SetAttribute("Busy", true)
	spill:SetAttribute("BusySince", os.clock())
	spill:SetAttribute("ClaimedByEmployeeUUID", tostring(janitorModel:GetAttribute("EmployeeUUID") or janitorModel:GetAttribute("UUID") or janitorModel.Name))
	spill:SetAttribute("ClaimedByEmployeeName", janitorModel.Name)
	setSpillPromptEnabled(spill, false)
	cleanupMop(janitorModel)
	equipMop(janitorModel, true)
	local janitorRoot = getModelRoot(janitorModel)
	local targetPosition = computeJanitorApproachPosition(janitorModel, spill) or root.Position
	janitorBusy[janitorModel] = {
		Spill = spill,
		Phase = "Walking",
		TargetPosition = targetPosition,
		StartedAt = os.clock(),
		LastCommandAt = 0,
		LastProgressAt = os.clock(),
		LastPosition = janitorRoot and janitorRoot.Position or targetPosition,
		RepositionCount = 0,
	}
	janitorModel:SetAttribute("SpillTaskActive", true)
	janitorModel:SetAttribute("SpillTaskState", "Walking")
	janitorModel:SetAttribute("TargetPosition", targetPosition)
	local hum = janitorModel:FindFirstChildOfClass("Humanoid")
	if hum then
		hum.PlatformStand = false
		hum:MoveTo(targetPosition)
	end
	if janitorRoot then
		janitorRoot.Anchored = false
	end
end

local function reconcileStaleBusySpills()
	local now = os.clock()
	local activeSpills = {}
	for _, taskData in pairs(janitorBusy) do
		if taskData and taskData.Spill and taskData.Spill.Parent then
			activeSpills[taskData.Spill] = true
			if taskData.Spill:GetAttribute("Busy") ~= true then
				taskData.Spill:SetAttribute("Busy", true)
			end
			taskData.Spill:SetAttribute("BusySince", now)
		end
	end

	for _, spill in ipairs(SPILL_FOLDER:GetChildren()) do
		if spill:IsA("Model") then
			if spill:GetAttribute("Busy") == true then
				if activeSpills[spill] then
					spill:SetAttribute("BusySince", now)
				else
					local busySince = tonumber(spill:GetAttribute("BusySince")) or 0
					if busySince <= 0 then
						spill:SetAttribute("BusySince", now)
					elseif (now - busySince) >= SPILL_BUSY_STALE_SECONDS then
						spill:SetAttribute("Busy", false)
						spill:SetAttribute("BusySince", nil)
						spill:SetAttribute("ClaimedByEmployeeUUID", nil)
						spill:SetAttribute("ClaimedByEmployeeName", nil)
						setSpillPromptEnabled(spill, true)
					end
				end
			elseif spill:GetAttribute("BusySince") ~= nil then
				spill:SetAttribute("BusySince", nil)
			end
		end
	end
end

local function updateJanitors()
	reconcileStaleBusySpills()
	local folder = getEmployeesFolder()
	if not folder then
		return
	end
	for _, model in ipairs(folder:GetChildren()) do
		if model:IsA("Model") and model:GetAttribute("IsEmployee") == true and model:GetAttribute("EmployeeType") == "Janitor" then
			equipMop(model, true)
			local taskData = janitorBusy[model]
			if taskData then
				local spill = taskData.Spill
				local root = spill and spill:FindFirstChild("Root")
				local janitorRoot = getModelRoot(model)
				if not (model.Parent and spill and spill.Parent and root and root:IsA("BasePart") and janitorRoot) then
					releaseJanitorTask(model, true)
				elseif taskData.Phase == "Walking" then
					local now = os.clock()
					if now - (taskData.StartedAt or now) > JANITOR_WALK_TIMEOUT then
						releaseJanitorTask(model, true)
					else
						local distance = (root.Position - janitorRoot.Position).Magnitude
						local movedDistance = taskData.LastPosition and (janitorRoot.Position - taskData.LastPosition).Magnitude or 0
						if movedDistance >= 1 then
							taskData.LastProgressAt = now
							taskData.LastPosition = janitorRoot.Position
						end
						if distance <= JANITOR_CLEAN_REACH then
							taskData.Phase = "Cleaning"
							model:SetAttribute("TargetPosition", nil)
							model:SetAttribute("SpillTaskState", "Cleaning")
							cleanupMop(model)
							equipMop(model, true)
							animateMop(model, 1.2)
							task.delay(1.2, function()
								if janitorBusy[model] ~= taskData then
									return
								end
								local currentBuilding = findBuildingByUUID(spill:GetAttribute("BuildingUUID"))
								if currentBuilding then
									currentBuilding:SetAttribute("LastSpillCleanAt", os.clock())
								end
								adjustBuildingCleanliness(currentBuilding, JANITOR_CLEAN_BONUS)
								destroySpill(spill)
								releaseJanitorTask(model, false)
							end)
						else
							if not model:GetAttribute("TargetPosition") then
								model:SetAttribute("TargetPosition", taskData.TargetPosition)
							end
							if now - (taskData.LastCommandAt or 0) > 1.25 then
								taskData.TargetPosition = computeJanitorApproachPosition(model, spill) or root.Position
								model:SetAttribute("TargetPosition", taskData.TargetPosition)
								local hum = model:FindFirstChildOfClass("Humanoid")
								if hum then
									hum.PlatformStand = false
									hum:MoveTo(taskData.TargetPosition)
								end
								taskData.LastCommandAt = now
							end
							if now - (taskData.LastProgressAt or taskData.StartedAt or now) > JANITOR_STALL_REPOSITION_SECONDS then
								taskData.TargetPosition = computeJanitorApproachPosition(model, spill) or root.Position
								model:SetAttribute("TargetPosition", taskData.TargetPosition)
								local hum = model:FindFirstChildOfClass("Humanoid")
								if hum then
									hum:MoveTo(taskData.TargetPosition)
								end
								taskData.RepositionCount = (taskData.RepositionCount or 0) + 1
								if taskData.RepositionCount >= JANITOR_MAX_REPOSITIONS then
									local safeTarget = taskData.TargetPosition + Vector3.new(0, 3, 0)
									model:PivotTo(CFrame.new(safeTarget, safeTarget + Vector3.new(root.Position.X - safeTarget.X, 0, root.Position.Z - safeTarget.Z)))
									hum.PlatformStand = false
									taskData.RepositionCount = 0
								end
								taskData.LastProgressAt = now
								taskData.LastPosition = janitorRoot.Position
							end
						end
					end
				end
			else
				local spill = getNearestSpillForJanitor(model)
				if spill then
					beginJanitorTask(model, spill)
				end
			end
		end
	end
	for model, _ in pairs(janitorBusy) do
		if not model or not model.Parent then
			releaseJanitorTask(model, true)
		end
	end
end

RunService.Heartbeat:Connect(function(dt)
	updateMopHair(dt)
end)

task.spawn(function()
	while true do
		reconcileSpills()
		task.wait(SPILL_RECONCILE_INTERVAL)
	end
end)

task.spawn(function()
	while true do
		updateJanitors()
		task.wait(math.max(0.35, JANITOR_CLEAN_INTERVAL * 0.6))
	end
end)

Players.PlayerRemoving:Connect(function(player)
	local character = player.Character
	if character then
		cleanupMop(character)
	end
end)

reconcileSpills()
