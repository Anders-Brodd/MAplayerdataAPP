--[=[ PATH: ServerScriptService/PlacementServer | TYPE: Script ]=]--
--[[
	PLACEMENT SERVER V91 (POLE EDGE-OFFSET FIX)
	
	CHANGES:
	- FIXED: Pole Generation. The first pole now mathematically calculates the bounds of the start station and spawns 20 studs from the *edge* of the station, rather than the center.
	- FIXED: End Pole bounds. The last pole is now mathematically barred from spawning inside the end station, and will distribute safely outside its edge.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local ServerStorage = game:GetService("ServerStorage")
local HttpService = game:GetService("HttpService")
local Terrain = workspace.Terrain

local Events = ReplicatedStorage:WaitForChild("Events")
local RequestPlaceItem = Events:WaitForChild("RequestPlaceItem")
local Config = require(ReplicatedStorage:WaitForChild("Config"))
local CustomBuildingConfig = require(ReplicatedStorage:WaitForChild("CustomBuildingConfig"))
local EntitlementManager = require(ReplicatedStorage:WaitForChild("EntitlementManager"))
local MultiplayerPermissions = require(ServerScriptService.Server:WaitForChild("MultiplayerPermissions"))
local Assets = ReplicatedStorage:WaitForChild("Assets")
local NotificationEvent = Events:FindFirstChild("NotificationEvent")
local RequestBuildingSave = Events:FindFirstChild("RequestBuildingSave")
if RequestBuildingSave and not RequestBuildingSave:IsA("BindableEvent") then
	RequestBuildingSave:Destroy()
	RequestBuildingSave = nil
end
if not RequestBuildingSave then
	RequestBuildingSave = Instance.new("BindableEvent")
	RequestBuildingSave.Name = "RequestBuildingSave"
	RequestBuildingSave.Parent = Events
end

local EmployeeMoveTo = Events:FindFirstChild("EmployeeMoveTo")
if not EmployeeMoveTo then
	EmployeeMoveTo = Instance.new("RemoteEvent")
	EmployeeMoveTo.Name = "EmployeeMoveTo"
	EmployeeMoveTo.Parent = Events
end

local RestoreItem = script:FindFirstChild("RestoreItem") or Instance.new("BindableEvent", script)
RestoreItem.Name = "RestoreItem"

-- ── BUILDING CAP ────────────────────────────────────────────────────────────
-- Players are limited to MAX_OBJECTS placed items. Purchasing the
-- "Slot Data Limit Bypass" pass (1792834210) or subscribing to Resort Pass
-- removes this cap entirely.
local MAX_OBJECTS          = 300
local SLOT_BYPASS_PASS_ID = 1792834210

local function hasSlotBypass(player: Player): boolean
	-- Check game pass ownership
	if EntitlementManager.HasAccess(player, SLOT_BYPASS_PASS_ID) then return true end
	-- Check Resort Pass subscription (attribute set by SubscriptionManager)
	if player:GetAttribute("Sub_ResortPass") == true then return true end
	-- Check per-pass resort-pass grant attribute
	if player:GetAttribute("ResortPassGrant_" .. tostring(SLOT_BYPASS_PASS_ID)) == true then return true end
	return false
end

local function getPlacedObjectCount(): number
	local placedFolder = workspace:FindFirstChild("PlacedObjects")
	if not placedFolder then return 0 end
	local count = 0
	for _, obj in ipairs(placedFolder:GetChildren()) do
		if obj:IsA("Model") then count += 1 end
	end
	return count
end
-- ────────────────────────────────────────────────────────────────────────────

local PlacementDebounces = {}

local function FindPlacedObjectByUUID(uuid)
	if type(uuid) ~= "string" or uuid == "" then return nil end
	local placedFolder = workspace:FindFirstChild("PlacedObjects")
	if not placedFolder then return nil end
	for _, child in ipairs(placedFolder:GetDescendants()) do
		if child:IsA("Model") and child:GetAttribute("UUID") == uuid then
			return child
		end
	end
	return nil
end

local function ShouldReplaceRestoredObject(existing)
	return existing and existing:IsA("Model") and #existing:GetDescendants() == 0
end

local function CleanName(n) return n:lower():gsub("^%s+", ""):gsub("%s+$", "") end

local function GetS1Pos(model)
	if not model then return nil end
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("Attachment") and CleanName(d.Name):sub(-2) == "s1" then return d.WorldPosition end
	end
	return model:GetPivot().Position
end

local function getPlacementUnlockState(player, itemName)
	local proxyPlayer = MultiplayerPermissions.GetResearchProxyPlayer(player)
	local decorChecker = ServerStorage:FindFirstChild("DecorMilestone_CheckUnlock")
	if decorChecker and decorChecker:IsA("BindableFunction") then
		local ok, result = pcall(function()
			return decorChecker:Invoke(player, itemName)
		end)
		if ok and type(result) == "table" and result.managed then
			if result.allowed == true then
				return true, nil
			end
			if proxyPlayer then
				local proxyOk, proxyResult = pcall(function()
					return decorChecker:Invoke(proxyPlayer, itemName)
				end)
				if proxyOk and type(proxyResult) == "table" and proxyResult.managed and proxyResult.allowed == true then
					return true, nil
				end
			end
			return false, result
		end
	end

	local checker = ServerStorage:FindFirstChild("Research_CheckUnlock")
	if not checker or not checker:IsA("BindableFunction") then
		return true, nil
	end
	local ok, allowed = pcall(function()
		return checker:Invoke(player, itemName)
	end)
	if ok and allowed == true then
		return true, nil
	end
	if not ok then
		warn("[PlacementServer] Research_CheckUnlock error for", itemName, "— allowing placement (fail-open):", allowed)
		return true, nil
	end
	if proxyPlayer then
		local proxyOk, proxyAllowed = pcall(function()
			return checker:Invoke(proxyPlayer, itemName)
		end)
		if proxyOk and proxyAllowed == true then
			return true, nil
		end
		if not proxyOk then
			warn("[PlacementServer] Research_CheckUnlock owner-proxy error for", itemName, "— allowing placement (fail-open):", proxyAllowed)
			return true, nil
		end
	end
	return false, { managed = true, lockType = "Research", title = "RESEARCH REQUIRED", subtitle = proxyPlayer and "This item is not unlocked for you or the resort owner yet." or "Unlock this item in Research first." }
end

-- =============================================================================
-- CONFIG
-- =============================================================================
local TERRAIN_MAT       = Enum.Material.Snow
local FOUNDATION_MAT    = Enum.Material.Snow
local VOXEL             = 4
local CHUNK             = 60
local BLEND_RADIUS      = 10      
local CORNER_RADIUS     = 6       
local FOOTPRINT_PAD     = 2       
local CLEAR_HEIGHT      = 42      
local CLEAR_ENVELOPE    = 4       
local MAX_FILL_DEPTH    = 24      
local MAX_FILL_RISE     = 6       
local FILL_COLUMN_STEP  = 4       
local TREE_PAD_XZ       = 8
local TREE_PAD_Y        = 40
local CABLE_TREE_WIDTH  = 36   
local CHAIR_CLEARANCE   = 25
local MAX_REGION_AXIS   = 480
local RAY_START_Y       = 4000
local RAY_LENGTH        = 8000
local MAX_FOOTPRINT     = 120

local MoneySystem, TransactionFunc
task.spawn(function()
	while not MoneySystem do
		MoneySystem = ServerScriptService.Server:FindFirstChild("MoneyServer", true)
		if not MoneySystem then
			local serverFolder = ServerScriptService:FindFirstChild("Server")
			if serverFolder then MoneySystem = serverFolder:FindFirstChild("MoneyServer") end
		end
		task.wait(1)
	end
	TransactionFunc = MoneySystem:WaitForChild("RequestTransaction")
end)

-- =============================================================================
-- HELPERS
-- =============================================================================
local AssetServerCache = {}
local AssetIdCache = {}

local function EnsureVehicleAssetReplicas()
	local buildingsFolder = Assets:FindFirstChild("Buildings")
	if not buildingsFolder then
		return
	end

	for itemName, itemConfig in pairs(Config.Items) do
		if itemConfig and itemConfig.Type == "Vehicle" then
			local existing = buildingsFolder:FindFirstChild(itemName)
			if existing and (existing:IsA("Model") or existing:IsA("Folder")) then
				if itemConfig.ID and existing:GetAttribute("ID") == nil then
					existing:SetAttribute("ID", itemConfig.ID)
				end
				continue
			end

			local serverAsset = ServerStorage:FindFirstChild(itemName)
			if serverAsset and serverAsset:IsA("Model") then
				local clone = serverAsset:Clone()
				clone.Name = itemName
				if itemConfig.ID then
					clone:SetAttribute("ID", itemConfig.ID)
				end
				clone.Parent = buildingsFolder
			end
		end
	end
end

local function IndexAssets()
	EnsureVehicleAssetReplicas()
	local start = os.clock()
	for i, obj in ipairs(Assets:GetDescendants()) do
		if obj:IsA("Model") or obj:IsA("Folder") then
			local id = obj:GetAttribute("ID")
			if id then AssetIdCache[tostring(id)] = obj end
		end
		if i % 500 == 0 and (os.clock() - start) > 0.02 then
			task.wait()
			start = os.clock()
		end
	end
end
task.spawn(IndexAssets)

-- B-023: Config may list decor before a mesh exists under ReplicatedStorage.Assets; build a minimal template so placement + saves work.
local function CreateMetalFenceFallbackTemplate(itemName, itemConfig)
	if itemName ~= "Metal Fence" then
		return nil
	end
	local model = Instance.new("Model")
	model.Name = "Metal Fence"

	local fenceColor = Color3.fromRGB(158, 158, 162)
	local postH = 3.5
	local postW = 0.4
	local span = 8
	local railH = 0.2
	local railD = 0.14
	local half = span * 0.5

	local function addPost(sign)
		local p = Instance.new("Part")
		p.Name = (sign < 0) and "Post_L" or "Post_R"
		p.Anchored = true
		p.CanCollide = true
		p.Material = Enum.Material.Metal
		p.Color = fenceColor
		p.Size = Vector3.new(postW, postH, postW)
		p.CFrame = CFrame.new(sign * half, postH * 0.5, 0)
		p.Parent = model
		return p
	end

	addPost(-1)
	addPost(1)

	local rail = Instance.new("Part")
	rail.Name = "Rail"
	rail.Anchored = true
	rail.CanCollide = true
	rail.Material = Enum.Material.Metal
	rail.Color = fenceColor
	rail.Size = Vector3.new(span - postW, railH, railD)
	rail.CFrame = CFrame.new(0, postH - 0.35, 0)
	rail.Parent = model

	model.PrimaryPart = rail
	if itemConfig and itemConfig.ID then
		model:SetAttribute("ID", itemConfig.ID)
	end
	return model
end

-- B-024/B-040: decor Net may be missing under Assets; minimal span so client snap + server place work.
local function CreateNetFallbackTemplate(itemName, itemConfig)
	if CleanName(itemName) ~= "net" then
		return nil
	end
	local model = Instance.new("Model")
	model.Name = "Net"
	local base = Instance.new("Part")
	base.Name = "Base"
	base.Anchored = true
	base.CanCollide = true
	base.Material = Enum.Material.SmoothPlastic
	base.Color = Color3.fromRGB(255, 130, 55)
	base.Size = Vector3.new(16, 0.4, 0.3)
	base.CFrame = CFrame.new()
	base.Parent = model
	model.PrimaryPart = base
	if itemConfig and itemConfig.ID then
		model:SetAttribute("ID", itemConfig.ID)
	end
	return model
end

local function FindAssetTemplate(itemName)
	if AssetServerCache[itemName] then return AssetServerCache[itemName] end

	local itemConfig = Config.Items[itemName]
	if itemConfig and itemConfig.Type == CustomBuildingConfig.TYPE_NAME then
		return CustomBuildingConfig.CreateModel(itemName)
	end

	local byName = Assets:FindFirstChild(itemName, true)
	if byName and (byName:IsA("Model") or byName:IsA("Folder")) then
		AssetServerCache[itemName] = byName
		return byName
	end

	if itemConfig and itemConfig.ID then
		local asset = AssetIdCache[tostring(itemConfig.ID)]
		if asset then
			AssetServerCache[itemName] = asset
			return asset
		end
	end

	local procedural = CreateMetalFenceFallbackTemplate(itemName, itemConfig) or CreateNetFallbackTemplate(itemName, itemConfig)
	if procedural then
		AssetServerCache[itemName] = procedural
		return procedural
	end

	return nil
end

local function ApplyTerrainSnapshotAttributes(model, terrainLog, treeMoveLog)
	if not model then
		return
	end

	if type(terrainLog) == "table" and #terrainLog > 0 then
		local ENTRIES_PER_CHUNK = 2000
		if #terrainLog <= ENTRIES_PER_CHUNK then
			model:SetAttribute("TerrainSnapshot", HttpService:JSONEncode(terrainLog))
			model:SetAttribute("TerrainSnapshotChunkCount", nil)
		else
			local chunkIndex = 0
			for i = 1, #terrainLog, ENTRIES_PER_CHUNK do
				chunkIndex += 1
				local chunk = {}
				for j = i, math.min(i + ENTRIES_PER_CHUNK - 1, #terrainLog) do
					table.insert(chunk, terrainLog[j])
				end
				local attrName = (chunkIndex == 1) and "TerrainSnapshot" or ("TerrainSnapshot_" .. chunkIndex)
				model:SetAttribute(attrName, HttpService:JSONEncode(chunk))
			end
			model:SetAttribute("TerrainSnapshotChunkCount", chunkIndex)
		end
	end

	if type(treeMoveLog) == "table" and #treeMoveLog > 0 then
		model:SetAttribute("TreeMoveSnapshot", HttpService:JSONEncode(treeMoveLog))
	end
end

local function GetCableCenter(model)
	if not model then return Vector3.zero end
	local pivotPos = model:GetPivot().Position

	local function FindSuffix(m, s)
		local t = s:lower()
		for _, d in ipairs(m:GetDescendants()) do
			if d:IsA("Attachment") and CleanName(d.Name):sub(-#t) == t then return d end
		end
		return nil
	end

	local function Validate(pos)
		if (pos - pivotPos).Magnitude > 200 then return false end
		return true
	end

	local r1, l1 = FindSuffix(model, "R1"), FindSuffix(model, "L1")
	if r1 and l1 then
		local mid = (r1.WorldPosition + l1.WorldPosition) / 2
		if Validate(mid) then return mid end
	end
	if r1 and Validate(r1.WorldPosition) then return r1.WorldPosition end

	local f1, f2 = FindSuffix(model, "F1"), FindSuffix(model, "F2")
	if f1 and f2 then
		local mid = (f1.WorldPosition + f2.WorldPosition) / 2
		if Validate(mid) then return mid end
	end

	return pivotPos
end

local function FlattenCFrame(cf)
	local pos, look = cf.Position, cf.LookVector
	local flatLook = Vector3.new(look.X, 0, look.Z)
	if flatLook.Magnitude > 0.001 then
		return CFrame.lookAt(pos, pos + flatLook.Unit)
	end
	-- LookVector is near-vertical (upright correction tilted it); recover yaw from RightVector
	local right = cf.RightVector
	local flatRight = Vector3.new(right.X, 0, right.Z)
	if flatRight.Magnitude > 0.001 then
		flatRight = flatRight.Unit
		local recoveredLook = Vector3.new(-flatRight.Z, 0, flatRight.X)
		return CFrame.lookAt(pos, pos + recoveredLook)
	end
	return CFrame.new(pos)
end

local function ResolveBasePart(baseObj)
	if not baseObj then return nil end
	if baseObj:IsA("BasePart") then return baseObj end
	if (baseObj:IsA("Model") or baseObj:IsA("Folder")) then
		if baseObj:IsA("Model") and baseObj.PrimaryPart then return baseObj.PrimaryPart end
		local named = baseObj:FindFirstChild("Base", true)
		if named and named:IsA("BasePart") then return named end
		return nil 
	end
	return nil
end

local TERRAIN_RAY_PARAMS = RaycastParams.new()
TERRAIN_RAY_PARAMS.FilterType = Enum.RaycastFilterType.Include
TERRAIN_RAY_PARAMS.FilterDescendantsInstances = {workspace.Terrain}

local function GetTerrainY(x, z, fromY)
	fromY = fromY or RAY_START_Y
	local res = workspace:Raycast(Vector3.new(x, fromY, z), Vector3.new(0, -RAY_LENGTH, 0), TERRAIN_RAY_PARAMS)
	return res and res.Position.Y or nil
end

local function ProjectOntoPlane(direction, normal)
	local up = normal.Magnitude > 0.001 and normal.Unit or Vector3.yAxis
	local projected = direction - up * direction:Dot(up)
	if projected.Magnitude > 0.001 then
		return projected.Unit
	end
	return nil
end

local function GetFallbackPlanarDirection(normal)
	return ProjectOntoPlane(Vector3.new(0, 0, -1), normal)
		or ProjectOntoPlane(Vector3.new(1, 0, 0), normal)
		or Vector3.new(0, 0, -1)
end

local function GetModelBottomOffset(model)
	if not model then return 0 end
	local baseObj = model:FindFirstChild("Base", true)
	local basePart = ResolveBasePart(baseObj)
	if basePart and basePart:IsA("BasePart") then
		local baseCF = basePart.CFrame
		local baseSize = basePart.Size
		local offset = model:GetPivot().Position.Y - (baseCF.Position.Y - (baseSize.Y * 0.5))
		if offset == offset and offset > -10 and offset < 50 then
			return offset
		end
	end
	local bbCF, bbSize = model:GetBoundingBox()
	local offset = model:GetPivot().Position.Y - (bbCF.Position.Y - (bbSize.Y * 0.5))
	if offset == offset and offset > -10 and offset < 50 then
		return offset
	end
	return 0
end

local function GetRotatedModelBottomOffset(model, rotationCF)
	if not model then return 0 end
	local originalPivot = model:GetPivot()
	model:PivotTo(CFrame.new(0, 10000, 0) * rotationCF.Rotation)
	local offset = GetModelBottomOffset(model)
	model:PivotTo(originalPivot)
	return offset
end

local function MaybeForceUprightBase(model, itemConfig)
	if not model or not itemConfig or itemConfig.ForceUprightBase ~= true then
		return
	end
	local basePart = ResolveBasePart(model:FindFirstChild("Base", true))
	if not basePart and model.PrimaryPart then
		basePart = model.PrimaryPart
	end
	if not basePart or not basePart:IsA("BasePart") then
		return
	end
	local baseUp = basePart.CFrame.UpVector
	local dotVal = baseUp:Dot(Vector3.yAxis)
	if dotVal >= 0.98 then
		return
	end
	local axis = baseUp:Cross(Vector3.yAxis)
	if axis.Magnitude <= 0.001 then
		return
	end
	local angle = math.acos(math.clamp(dotVal, -1, 1))
	local pivot = model:GetPivot()
	model:PivotTo(CFrame.new(pivot.Position) * CFrame.fromAxisAngle(axis.Unit, angle) * pivot.Rotation)
end

local function BuildSlopeAlignedStaticCFrame(model, sourceCF)
	if typeof(sourceCF) ~= "CFrame" then
		return sourceCF
	end

	local rayOrigin = sourceCF.Position + Vector3.new(0, 256, 0)
	local rayResult = workspace:Raycast(rayOrigin, Vector3.new(0, -1024, 0), TERRAIN_RAY_PARAMS)
	if not rayResult then
		return sourceCF
	end

	local up = rayResult.Normal.Magnitude > 0.001 and rayResult.Normal.Unit or Vector3.yAxis
	local forward = ProjectOntoPlane(sourceCF.LookVector, up) or GetFallbackPlanarDirection(up)
	local rotationCF = CFrame.lookAt(Vector3.zero, forward, up)
	local bottomOffset = GetRotatedModelBottomOffset(model, rotationCF)
	local finalPos = rayResult.Position + Vector3.new(0, bottomOffset, 0)
	return CFrame.lookAt(finalPos, finalPos + forward, up)
end

local function ApplyWorldHeightOffset(cf, heightOffset)
	if typeof(cf) ~= "CFrame" then
		return cf
	end
	if math.abs(heightOffset or 0) <= 0.01 then
		return cf
	end
	return CFrame.new(cf.Position + Vector3.new(0, heightOffset, 0)) * cf.Rotation
end

local function GetSafePlanarDirection(inDir, outDir)
	local flat = Vector3.new(inDir.X + outDir.X, 0, inDir.Z + outDir.Z)
	if flat.Magnitude < 0.01 then
		flat = Vector3.new(outDir.X, 0, outDir.Z)
	end
	if flat.Magnitude < 0.01 then
		flat = Vector3.new(inDir.X, 0, inDir.Z)
	end
	if flat.Magnitude < 0.01 then
		return Vector3.zAxis
	end
	return flat.Unit
end

local function BuildCarpetSectionCFrame(sectionModel, position, forward, itemConfig)
	local rotX = math.rad(itemConfig.ChairRotationX or 0)
	local rotY = math.rad(itemConfig.ChairRotationY or 0)
	local rotZ = math.rad(itemConfig.ChairRotationZ or 0)
	local configRot = CFrame.Angles(rotX, rotY, rotZ)

	local alignedRotation = (CFrame.lookAt(position, position + forward) * configRot).Rotation
	-- position already comes from S1 attachments at path level; no extra offset needed
	return CFrame.new(position) * alignedRotation
end

local function SampleCarpetTerrainPoint(flatPos, fallbackY)
	local terrainY = GetTerrainY(flatPos.X, flatPos.Z, math.max(flatPos.Y, fallbackY or flatPos.Y) + 256)
	if terrainY then
		return Vector3.new(flatPos.X, terrainY, flatPos.Z)
	end
	return Vector3.new(flatPos.X, fallbackY or flatPos.Y, flatPos.Z)
end

local function BuildCarpetTerrainSamples(startPos, endPos, numSamples)
	numSamples = math.max(2, numSamples or 2)
	local samples = table.create(numSamples)
	for i = 1, numSamples do
		local t = (i - 1) / (numSamples - 1)
		local flatPos = startPos:Lerp(endPos, t)
		samples[i] = SampleCarpetTerrainPoint(flatPos, flatPos.Y)
	end
	for _ = 1, 2 do
		for i = 2, numSamples - 1 do
			local prevY = samples[i - 1].Y
			local curr = samples[i]
			local nextY = samples[i + 1].Y
			samples[i] = Vector3.new(curr.X, (prevY + curr.Y + nextY) / 3, curr.Z)
		end
	end
	return samples
end

local function ApplySavedSnapshotAttributes(model, data)
	if not model or type(data) ~= "table" then
		return
	end

	local treeSnapshot = data.TreeSnapshot
	if type(treeSnapshot) == "string" and treeSnapshot ~= "" then
		model:SetAttribute("TreeSnapshot", treeSnapshot)
	end

	local treeMoveSnapshot = data.TreeMoveSnapshot
	if type(treeMoveSnapshot) == "string" and treeMoveSnapshot ~= "" then
		model:SetAttribute("TreeMoveSnapshot", treeMoveSnapshot)
	end

	local chunkCount = math.max(0, math.floor(tonumber(data.TerrainSnapshotChunkCount) or 0))
	if chunkCount <= 1 then
		local terrainSnapshot = data.TerrainSnapshot
		if type(terrainSnapshot) == "string" and terrainSnapshot ~= "" then
			model:SetAttribute("TerrainSnapshot", terrainSnapshot)
		end
		return
	end

	model:SetAttribute("TerrainSnapshotChunkCount", chunkCount)
	for i = 1, chunkCount do
		local attrName = (i == 1) and "TerrainSnapshot" or ("TerrainSnapshot_" .. i)
		local rawValue = data[attrName]
		if type(rawValue) == "string" and rawValue ~= "" then
			model:SetAttribute(attrName, rawValue)
		end
	end
end

-- =============================================================================
-- AUTO SEAT FLAT
-- =============================================================================
local function AutoSeatFlat(cf, footprintSize, ignoreList, model, yawDegreesOverride)
	-- Preserve the incoming rotation (may include upright correction from client)
	local incomingRotation = cf.Rotation
	local pos = cf.Position
	local halfX = math.max((footprintSize.X or 10) / 2, 5)
	local halfZ = math.max((footprintSize.Z or 10) / 2, 5)

	local centerY = GetTerrainY(pos.X, pos.Z)
	if not centerY then
		return CFrame.new(pos) * incomingRotation
	end

	local sampleOffsets = {
		Vector3.new(halfX, 0, 0), Vector3.new(-halfX, 0, 0),
		Vector3.new(0, 0, halfZ), Vector3.new(0, 0, -halfZ),
		Vector3.new(halfX, 0, halfZ), Vector3.new(-halfX, 0, halfZ),
		Vector3.new(halfX, 0, -halfZ), Vector3.new(-halfX, 0, -halfZ),
	}

	local highestY = centerY
	local sumEdgeY, edgeCount = 0, 0

	for _, offset in ipairs(sampleOffsets) do
		local worldPos = (CFrame.new(pos) * incomingRotation * CFrame.new(offset)).Position
		local terrY = GetTerrainY(worldPos.X, worldPos.Z)
		if terrY then
			sumEdgeY += terrY
			edgeCount += 1
			if terrY > highestY then highestY = terrY end
		end
	end

	local targetY = centerY

	if highestY > centerY then
		local uphillBias = math.min((highestY - centerY) * 0.15, 3)
		targetY = centerY + uphillBias
	end

	if math.abs(targetY - pos.Y) > 200 then
		targetY = centerY
	end

	-- Compute upright correction from Base part if needed
	local uprightCorrection = CFrame.new()
	if model then
		local basePart = ResolveBasePart(model:FindFirstChild("Base", true))
		if not basePart and model.PrimaryPart then basePart = model.PrimaryPart end
		if basePart and basePart:IsA("BasePart") then
			local pivotCF = model:GetPivot()
			local baseCF = basePart.CFrame
			local relRot = pivotCF.Rotation:Inverse() * baseCF.Rotation
			local currentUp = relRot.UpVector
			local dotVal = currentUp:Dot(Vector3.yAxis)
			if dotVal < 0.99 then
				local axis = currentUp:Cross(Vector3.yAxis)
				if axis.Magnitude > 0.001 then
					local angle = math.acos(math.clamp(dotVal, -1, 1))
					uprightCorrection = CFrame.fromAxisAngle(axis.Unit, angle)
				end
			end
		end
	end

	local bottomOffset = 0
	if model then
		-- Temporarily apply the correction to get the correct world-space bounds
		local tempCF = CFrame.new(0, 500, 0) * FlattenCFrame(cf).Rotation * uprightCorrection
		model:PivotTo(tempCF)

		local basePart = ResolveBasePart(model:FindFirstChild("Base", true))
		if not basePart and model.PrimaryPart then basePart = model.PrimaryPart end

		if basePart and basePart:IsA("BasePart") then
			local bCF = basePart.CFrame
			local bSize = basePart.Size
			bottomOffset = model:GetPivot().Position.Y - (bCF.Position.Y - bSize.Y/2)
		else
			local bbCF, bbSize = model:GetBoundingBox()
			local pivotPos = model:GetPivot().Position
			bottomOffset = pivotPos.Y - (bbCF.Position.Y - bbSize.Y/2)
		end
	end

	pos = Vector3.new(pos.X, targetY + bottomOffset, pos.Z)
	-- Use explicit yaw from client when available (avoids FlattenCFrame extraction issues)
	local yawRotation
	if yawDegreesOverride then
		yawRotation = CFrame.Angles(0, math.rad(yawDegreesOverride), 0)
	else
		yawRotation = FlattenCFrame(cf).Rotation
	end
	return CFrame.new(pos) * yawRotation * uprightCorrection
end

-- =============================================================================
-- VOXEL PROCESSOR & TERRAIN
-- =============================================================================
local terrain = workspace.Terrain
local function IsRegionSafe(region)
	local size = region.Size
	return size.X > 0 and size.Y > 0 and size.Z > 0 and size.X <= MAX_REGION_AXIS and size.Y <= MAX_REGION_AXIS and size.Z <= MAX_REGION_AXIS
end

local function ProcessVoxelRegion(minPos, maxPos, callback)
	local alignedMin = Vector3.new(math.floor(minPos.X/VOXEL)*VOXEL, math.floor(minPos.Y/VOXEL)*VOXEL, math.floor(minPos.Z/VOXEL)*VOXEL)
	local alignedMax = Vector3.new(math.ceil(maxPos.X/VOXEL)*VOXEL, math.ceil(maxPos.Y/VOXEL)*VOXEL, math.ceil(maxPos.Z/VOXEL)*VOXEL)
	if alignedMax.X <= alignedMin.X or alignedMax.Y <= alignedMin.Y or alignedMax.Z <= alignedMin.Z then return end
	if (alignedMax.X-alignedMin.X)>500 or (alignedMax.Y-alignedMin.Y)>500 then return end

	local chunkCount = 0
	for cx = alignedMin.X, alignedMax.X - 1, CHUNK do
		for cy = alignedMin.Y, alignedMax.Y - 1, CHUNK do
			for cz = alignedMin.Z, alignedMax.Z - 1, CHUNK do
				local cMin = Vector3.new(cx, cy, cz)
				local cMax = Vector3.new(math.min(cx+CHUNK, alignedMax.X), math.min(cy+CHUNK, alignedMax.Y), math.min(cz+CHUNK, alignedMax.Z))
				if cMax.X>cMin.X and cMax.Y>cMin.Y and cMax.Z>cMin.Z then
					local region = Region3.new(cMin, cMax):ExpandToGrid(VOXEL)
					if IsRegionSafe(region) then
						pcall(function()
							local mats, occs = terrain:ReadVoxels(region, VOXEL)
							local sX, sY, sZ = mats.Size.X, mats.Size.Y, mats.Size.Z
							local chg = false
							local bx, by, bz = region.CFrame.Position.X - region.Size.X/2, region.CFrame.Position.Y - region.Size.Y/2, region.CFrame.Position.Z - region.Size.Z/2
							for xi=1, sX do
								local wx = bx + (xi-0.5)*VOXEL
								for yi=1, sY do
									local wy = by + (yi-0.5)*VOXEL
									for zi=1, sZ do
										local wz = bz + (zi-0.5)*VOXEL
										local nm, no = callback(wx, wy, wz, mats[xi][yi][zi], occs[xi][yi][zi])
										if nm ~= nil then mats[xi][yi][zi] = nm; occs[xi][yi][zi] = no; chg = true end
									end
								end
							end
							if chg then terrain:WriteVoxels(region, VOXEL, mats, occs) end
						end)
					end
				end
				chunkCount += 1
			end
		end
		if chunkCount > 0 and chunkCount % 2 == 0 then task.wait() end
	end
end

local function SmartPlatformTerrain(model, isStartStation)
	if not model then return {}, {} end
	local terrainLog = {}
	local treeMoveLog = {}

	-- PATCHED: Vehicles (snowcats) sit ON terrain — don't dig foundations for them
	local modelType = model:GetAttribute("Type")
	local context = model
	local liftContext = false
	while context do
		local contextType = context:GetAttribute("Type")
		if contextType == "TwoPoint" or contextType == "Carpet" then
			liftContext = true
			break
		end
		context = context.Parent
	end
	if modelType == "Vehicle" then return terrainLog, treeMoveLog end
	local disableInteriorClear = liftContext or (isStartStation == true)
	local suppressTerrainClear = liftContext
	local modelName = model.Name or ""
	if modelName:find("Prinoth") or modelName:find("Snowcat") or modelName:find("Bison") or modelName:find("Leitwolf") then
		return terrainLog, treeMoveLog
	end

	local _, bbSize = model:GetBoundingBox()
	if bbSize.X < 12 and bbSize.Z < 12 and bbSize.Y < 15 then return terrainLog, treeMoveLog end

	local floorY, halfX, halfZ, cf
	local baseObj = model:FindFirstChild("Base", true)
	local basePart = ResolveBasePart(baseObj)

	if basePart then
		local bCF = basePart.CFrame
		local bSize = basePart.Size
		cf = FlattenCFrame(bCF)
		floorY = bCF.Position.Y - (bSize.Y / 2)
		halfX = (bSize.X / 2) + FOOTPRINT_PAD
		halfZ = (bSize.Z / 2) + FOOTPRINT_PAD
	else
		local pivot = model:GetPivot().Position
		local bbCF
		bbCF, bbSize = model:GetBoundingBox()
		if bbSize.X > MAX_FOOTPRINT or bbSize.Z > MAX_FOOTPRINT then
			bbCF = CFrame.new(pivot); bbSize = Vector3.new(40, 10, 40)
		end
		cf = FlattenCFrame(bbCF)
		floorY = cf.Position.Y - (bbSize.Y / 2) + 0.5
		halfX, halfZ = bbSize.X / 2, bbSize.Z / 2
	end

	local cfInverse = cf:Inverse()
	local centerX, centerZ = cf.Position.X, cf.Position.Z

	local function ClassifyColumn(wx, wz)
		local localPos = cfInverse * Vector3.new(wx, 0, wz)
		local lx, lz = math.abs(localPos.X), math.abs(localPos.Z)
		local bx, bz = halfX - CORNER_RADIUS, halfZ - CORNER_RADIUS
		local qx, qz = lx - bx, lz - bz
		local outsideDist = math.sqrt(math.max(0, qx)^2 + math.max(0, qz)^2)
		local insideDist = math.min(0, math.max(qx, qz))
		local signedDist = outsideDist + insideDist - CORNER_RADIUS
		if signedDist <= 0 then return signedDist, 0, true
		elseif signedDist >= BLEND_RADIUS then return signedDist, 1, false
		else return signedDist, signedDist / BLEND_RADIUS, false end
	end

	local groundCache = {}
	local function GetCachedGround(wx, wz)
		local key = math.floor(wx/VOXEL)*100000 + math.floor(wz/VOXEL)
		if groundCache[key] then return groundCache[key] end
		groundCache[key] = GetTerrainY(wx, wz) or (floorY - MAX_FILL_DEPTH - 50)
		return groundCache[key]
	end

	local totalHalfX, totalHalfZ = halfX + BLEND_RADIUS + VOXEL, halfZ + BLEND_RADIUS + VOXEL
	local columnCount = 0

	for colX = centerX - totalHalfX, centerX + totalHalfX, FILL_COLUMN_STEP do
		for colZ = centerZ - totalHalfZ, centerZ + totalHalfZ, FILL_COLUMN_STEP do
			local signedDist, blendT, isInterior = ClassifyColumn(colX, colZ)
			if signedDist < BLEND_RADIUS then
				local groundY = GetCachedGround(colX, colZ)
				local smoothBlend = blendT * blendT * (3 - 2 * blendT)
				local targetY = floorY
				if not isInterior and groundY < floorY then
					targetY = floorY + (groundY - floorY) * smoothBlend
				end

				-- FILL
				if groundY < targetY - VOXEL * 0.5 then
					local fillBottom, fillTop = groundY, targetY
					local fillHeight = fillTop - fillBottom
					local maxRise = isInterior and 500 or 250
					if fillHeight > maxRise then fillBottom = fillTop - maxRise; fillHeight = maxRise end

					if fillHeight >= VOXEL * 0.5 then
						pcall(function() terrain:FillBlock(CFrame.new(colX, (fillBottom + fillTop)/2, colZ), Vector3.new(FILL_COLUMN_STEP, fillHeight, FILL_COLUMN_STEP), TERRAIN_MAT) end)
						table.insert(terrainLog, {type = "fill", x = colX, z = colZ, bottom = fillBottom, top = fillTop})
					end
				end

				-- CLEAR
				if (not suppressTerrainClear) and groundY > targetY + VOXEL * 0.5 then
					local clearBottom, clearTop = targetY, groundY + VOXEL
					if isInterior then
						if not disableInteriorClear then
							clearTop = math.max(clearTop, floorY + CLEAR_HEIGHT)
						else
							clearTop = nil
						end
					else
						clearTop = math.max(clearTop, targetY + (CLEAR_ENVELOPE * (1 - blendT)))
					end

					if clearTop and (clearTop - clearBottom) > VOXEL and (clearTop - clearBottom) < MAX_REGION_AXIS then
						pcall(function() terrain:FillBlock(CFrame.new(colX, (clearBottom+clearTop)/2, colZ), Vector3.new(FILL_COLUMN_STEP, clearTop-clearBottom, FILL_COLUMN_STEP), Enum.Material.Air) end)
					end
				elseif (not suppressTerrainClear) and isInterior and not disableInteriorClear then
					local intClearBottom, intClearTop = floorY + VOXEL * 0.5, floorY + CLEAR_HEIGHT
					pcall(function() terrain:FillBlock(CFrame.new(colX, (intClearBottom+intClearTop)/2, colZ), Vector3.new(FILL_COLUMN_STEP, intClearTop-intClearBottom, FILL_COLUMN_STEP), Enum.Material.Air) end)
				end
				columnCount += 1
				if columnCount % 8 == 0 then task.wait() end
			end
		end
	end

	if suppressTerrainClear then
		return terrainLog, treeMoveLog
	end

	-- Smoothing Pass
	local smoothMin = Vector3.new(centerX - totalHalfX, floorY - MAX_FILL_DEPTH, centerZ - totalHalfZ)
	local smoothMax = Vector3.new(centerX + totalHalfX, floorY + VOXEL*2, centerZ + totalHalfZ)
	ProcessVoxelRegion(smoothMin, smoothMax, function(wx, wy, wz, cMat, cOcc)
		local _, bT, isInt = ClassifyColumn(wx, wz)
		if isInt or bT >= 1 then return nil end
		local gY = GetCachedGround(wx, wz)
		local smoothBlend = bT * bT * (3 - 2 * bT)
		local tY = floorY
		if gY < floorY then
			tY = floorY + (gY - floorY) * smoothBlend
		end
		local diff = wy - tY
		if diff > -VOXEL and diff < VOXEL * 2 then
			if diff > VOXEL * 0.5 then
				if cMat ~= Enum.Material.Air and cOcc > 0 then
					local fOcc = math.clamp(1 - (diff - VOXEL*0.5)/VOXEL, 0, cOcc)
					return (fOcc < 0.05) and Enum.Material.Air or cMat, (fOcc < 0.05) and 0 or fOcc
				end
			elseif diff < -VOXEL * 0.3 then
				if cMat == Enum.Material.Air and gY < tY - VOXEL then
					return TERRAIN_MAT, math.clamp((-diff)/VOXEL, 0.3, 1.0)
				end
			end
		end
		return nil
	end)

	return terrainLog, treeMoveLog
end

-- =============================================================================
-- POLE & TREE HELPERS
-- =============================================================================
local function EnsureTreeFolderQueryable(treeFolder)
	if not treeFolder then return end
	for _, desc in ipairs(treeFolder:GetDescendants()) do
		if desc:IsA("BasePart") and desc.CanQuery == false then
			desc.CanQuery = true
		end
	end
end

local function ClearTreesBox(cframe, size, currentSnapshot)
	local treeFolder = workspace:FindFirstChild("TreeFolder") or workspace
	EnsureTreeFolderQueryable(treeFolder)
	local op = OverlapParams.new(); op.FilterType = Enum.RaycastFilterType.Include; op.FilterDescendantsInstances = {treeFolder}
	local parts = workspace:GetPartBoundsInBox(cframe, size, op)
	local checked = {}
	for _, part in ipairs(parts) do
		local model = part:FindFirstAncestorOfClass("Model")
		if model and not checked[model] and (model.Name:match("Tree") or model.Name:match("Snow") or model:GetAttribute("Type") == "Tree") then
			checked[model] = true
			if currentSnapshot then table.insert(currentSnapshot, {Name = model.Name, CF = {model:GetPivot():GetComponents()}, Height = model:GetExtentsSize().Y}) end
			model:Destroy()
		end
	end
end

local function ClearTreesPath(startPos, endPos, width)
	local dist = (startPos - endPos).Magnitude
	if dist < 1 then return {} end
	local mid = (startPos + endPos) / 2
	local snap = {}
	ClearTreesBox(CFrame.lookAt(mid, endPos), Vector3.new(width, 2000, dist), snap)
	return snap
end

local function ClearTreesBuilding(model)
	local cf, size = model:GetBoundingBox()
	if size.X > MAX_FOOTPRINT or size.Z > MAX_FOOTPRINT then cf = CFrame.new(model:GetPivot().Position); size = Vector3.new(40, 40, 40) end
	local snap = {}
	ClearTreesBox(cf, size + Vector3.new(TREE_PAD_XZ, TREE_PAD_Y, TREE_PAD_XZ), snap)
	return snap
end

local function CarveCablePath(startPos, endPos)
	local voxelLog = {}
	local dist = (endPos - startPos).Magnitude
	local steps = math.max(1, math.ceil(dist / 8))
	local cutHalfSize = Vector3.new(6, 0, 3)
	for i = 0, steps do
		local pt = startPos:Lerp(endPos, i / steps)
		local gy = GetTerrainY(pt.X, pt.Z) or 0
		if (pt.Y - CHAIR_CLEARANCE) > gy + 5 then
			local clearBottom = math.max(gy + 2, pt.Y - 2)
			local clearTop = pt.Y + math.max(CHAIR_CLEARANCE, 10)
			if clearTop > clearBottom + VOXEL then
				local minPos = Vector3.new(pt.X - cutHalfSize.X, clearBottom, pt.Z - cutHalfSize.Z)
				local maxPos = Vector3.new(pt.X + cutHalfSize.X, clearTop, pt.Z + cutHalfSize.Z)
				ProcessVoxelRegion(minPos, maxPos, function(wx, wy, wz, mat, occ)
					if mat ~= Enum.Material.Air then
						table.insert(voxelLog, {wx, wy, wz, mat.Value, occ})
						return Enum.Material.Air, 0
					end
					return nil
				end)
			end
		end
	end
	return voxelLog
end

local function ValidateCarpetTerrainRoughness(startPos, endPos, itemConfig)
	local maxRoughness = (itemConfig and itemConfig.MaxTerrainRoughness) or 8
	local dist = (endPos - startPos).Magnitude
	local numSamples = math.clamp(math.ceil(dist / 6), 4, 60)

	local samples = table.create(numSamples)
	for i = 1, numSamples do
		local t = (i - 1) / (numSamples - 1)
		local pt = startPos:Lerp(endPos, t)
		samples[i] = GetTerrainY(pt.X, pt.Z) or pt.Y
	end

	-- Check adjacent height jumps
	for i = 2, numSamples do
		local jump = math.abs(samples[i] - samples[i - 1])
		if jump > maxRoughness then
			return false, "Terrain is too rough for a Magic Carpet."
		end
	end

	-- Check deviation from straight line (catches mountainous terrain)
	local startY = samples[1]
	local endY = samples[numSamples]
	for i = 2, numSamples - 1 do
		local expectedY = startY + (endY - startY) * ((i - 1) / (numSamples - 1))
		local deviation = math.abs(samples[i] - expectedY)
		if deviation > maxRoughness * 1.5 then
			return false, "Terrain is too uneven for a Magic Carpet."
		end
	end

	return true, nil
end

local function CarveCarpetTrench(startPos, endPos)
	local voxelLog = {}
	local dist = (endPos - startPos).Magnitude
	local steps = math.ceil(dist / 3)
	local width = 10
	local carpetHover = 3.2 -- Keep more clearance so carpets do not get reburied by auto-terrain shaping.

	-- First pass: build a smoothed height profile so small bumps get flattened
	local profileCount = math.max(2, math.ceil(dist / 4))
	local profile = table.create(profileCount)
	for i = 1, profileCount do
		local t = (i - 1) / (profileCount - 1)
		local pt = startPos:Lerp(endPos, t)
		profile[i] = GetTerrainY(pt.X, pt.Z) or pt.Y
	end
	-- Smooth the height profile to remove small bumps (3 averaging passes)
	for _ = 1, 3 do
		for i = 2, profileCount - 1 do
			profile[i] = (profile[i - 1] + profile[i] + profile[i + 1]) / 3
		end
	end

	-- Second pass: flatten bumps by writing terrain to match the smoothed profile
	local smoothWidth = width + 2
	for i = 1, profileCount do
		local t = (i - 1) / (profileCount - 1)
		local pt = startPos:Lerp(endPos, t)
		local smoothedY = profile[i]
		local rawY = GetTerrainY(pt.X, pt.Z) or pt.Y
		local bumpSize = math.abs(rawY - smoothedY)

		-- Only flatten bumps that are noticeable but not too huge (those are rejected by roughness check)
		if bumpSize > 0.5 then
			local regionMin = Vector3.new(pt.X - smoothWidth / 2, math.min(rawY, smoothedY) - VOXEL, pt.Z - smoothWidth / 2)
			local regionMax = Vector3.new(pt.X + smoothWidth / 2, math.max(rawY, smoothedY) + VOXEL * 2, pt.Z + smoothWidth / 2)

			ProcessVoxelRegion(regionMin, regionMax, function(wx, wy, wz, mat, occ)
				local diff = smoothedY - wy
				if rawY > smoothedY then
					-- Bump sticking up: carve down to smoothed level
					if wy > smoothedY - VOXEL * 0.5 and wy < rawY + VOXEL then
						local desiredOcc = math.clamp(diff / VOXEL + 0.5, 0, 1)
						if desiredOcc < 0.05 then
							if mat ~= Enum.Material.Air then
								table.insert(voxelLog, {wx, wy, wz, mat.Value, occ})
								return Enum.Material.Air, 0
							end
						elseif math.abs(occ - desiredOcc) > 0.1 then
							local oldVal = (mat == Enum.Material.Air) and Enum.Material.Air.Value or mat.Value
							table.insert(voxelLog, {wx, wy, wz, oldVal, occ})
							return TERRAIN_MAT, desiredOcc
						end
					end
				else
					-- Dip: fill up to smoothed level
					if wy > rawY - VOXEL and wy < smoothedY + VOXEL * 0.5 then
						local desiredOcc = math.clamp(diff / VOXEL + 0.5, 0, 1)
						if desiredOcc >= 0.95 then
							if mat == Enum.Material.Air or occ < 0.95 then
								local oldVal = (mat == Enum.Material.Air) and Enum.Material.Air.Value or mat.Value
								table.insert(voxelLog, {wx, wy, wz, oldVal, occ})
								return TERRAIN_MAT, 1
							end
						elseif desiredOcc > 0.05 and (mat == Enum.Material.Air or math.abs(occ - desiredOcc) > 0.1) then
							local oldVal = (mat == Enum.Material.Air) and Enum.Material.Air.Value or mat.Value
							table.insert(voxelLog, {wx, wy, wz, oldVal, occ})
							return TERRAIN_MAT, desiredOcc
						end
					end
				end
				return nil
			end)
		end
		if i % 6 == 0 then task.wait() end
	end

	-- Third pass: standard carpet trench carve (using smoothed profile for target heights)
	for i = 0, steps do
		local pt = startPos:Lerp(endPos, i/steps)
		-- Interpolate smoothed height from profile
		local profileT = (i / steps) * (profileCount - 1) + 1
		local pIdx = math.clamp(math.floor(profileT), 1, profileCount - 1)
		local pFrac = profileT - pIdx
		local smoothedTerrainY = profile[pIdx] * (1 - pFrac) + profile[math.min(pIdx + 1, profileCount)] * pFrac
		local targetY = smoothedTerrainY - carpetHover

		local regionMin = pt - Vector3.new(width/2, 14, width/2)
		local regionMax = pt + Vector3.new(width/2, 8, width/2)

		ProcessVoxelRegion(regionMin, regionMax, function(wx, wy, wz, mat, occ)
			local diff = targetY - wy
			local desiredOcc = math.clamp((diff + 2) / 4, 0, 1)

			if desiredOcc <= 0.05 then
				if mat ~= Enum.Material.Air then
					table.insert(voxelLog, {wx, wy, wz, mat.Value, occ})
					return Enum.Material.Air, 0
				end
			elseif desiredOcc >= 0.95 then
				if mat ~= TERRAIN_MAT or occ < 0.95 then
					local oldVal = (mat == Enum.Material.Air) and Enum.Material.Air.Value or mat.Value
					table.insert(voxelLog, {wx, wy, wz, oldVal, occ})
					return TERRAIN_MAT, 1
				end
			else
				if mat ~= TERRAIN_MAT or math.abs(occ - desiredOcc) > 0.1 then
					local oldVal = (mat == Enum.Material.Air) and Enum.Material.Air.Value or mat.Value
					table.insert(voxelLog, {wx, wy, wz, oldVal, occ})
					return TERRAIN_MAT, desiredOcc
				end
			end
			return nil
		end)
	end
	return voxelLog
end

local function AlignPoleSheaths(startStation, endStation, poleList, itemConfig)
	local nodes = {{Pos = GetCableCenter(startStation)}}
	for _, pole in ipairs(poleList) do table.insert(nodes, {Pos = GetCableCenter(pole), Model = pole}) end
	table.insert(nodes, {Pos = GetCableCenter(endStation)})
	local sheaveRotY = math.rad(itemConfig.SheaveRotationY or 0)
	for i = 2, #nodes - 1 do
		local prev, curr, next_ = nodes[i-1].Pos, nodes[i].Pos, nodes[i+1].Pos
		local pole = nodes[i].Model
		local inDir, outDir = (curr - prev).Unit, (next_ - curr).Unit
		local flatDir = GetSafePlanarDirection(inDir, outDir)

		local dInH = Vector3.new(curr.X - prev.X, 0, curr.Z - prev.Z).Magnitude
		local dInV = curr.Y - prev.Y
		local pitchIn = math.atan2(dInV, dInH)

		local dOutH = Vector3.new(next_.X - curr.X, 0, next_.Z - curr.Z).Magnitude
		local dOutV = next_.Y - curr.Y
		local pitchOut = math.atan2(dOutV, dOutH)

		local pitch = (pitchIn + pitchOut) / 2

		local sheavesToRotate = {}
		local function getSheaves()
			for _, n in ipairs({"Sheath", "Sheave", "Sheaves", "Head", "Assembly", "Train", "Crossarm", "Wheel", "Guide", "Top"}) do
				local matched = false
				for _, desc in ipairs(pole:GetDescendants()) do
					if string.lower(desc.Name):find(string.lower(n)) then
						local isChild = false
						for _, s in ipairs(sheavesToRotate) do
							if desc:IsDescendantOf(s) then isChild = true; break end
						end
						if not isChild then
							table.insert(sheavesToRotate, desc)
							matched = true
						end
					end
				end
				if matched then return end
			end
		end
		getSheaves()

		for _, s in ipairs(sheavesToRotate) do
			local currentCF = s:GetPivot()
			local _, _, currentRoll = currentCF:ToOrientation()

			local cablePitchedCF = CFrame.lookAt(currentCF.Position, currentCF.Position + flatDir) * CFrame.Angles(pitch, 0, 0)

			local newCF = cablePitchedCF * CFrame.Angles(0, sheaveRotY, currentRoll)
			s:PivotTo(newCF)
		end
	end
end

local function CreatePoleMound(pos)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = {Terrain}
	params.IgnoreWater = true

	local result = workspace:Raycast(pos, Vector3.new(0, -500, 0), params)
	if result then
		local groundY = result.Position.Y
		local height = pos.Y - groundY
		if height > 3 then
			local topRadius = 4
			local bottomRadius = math.min(math.max(topRadius + 1.5, height * 0.9), 16)
			local steps = math.max(1, math.ceil(height / 2))
			for i = 0, steps do
				local alpha = i / steps
				local y = groundY + (height * alpha)
				local r = bottomRadius + (topRadius - bottomRadius) * alpha
				Terrain:FillBall(Vector3.new(pos.X, y, pos.Z), r, Enum.Material.Snow)
			end
		end
	end
end

-- Add PathfindingModifier to all BaseParts in a model so NPCs path around lifts
local function AddPathfindingBlockers(model)
	local restoreThrottle = (_G.BuildingRestoreInProgress == true)
	local visitedCount = 0
	for _, part in ipairs(model:GetDescendants()) do
		if part:IsA("BasePart") and not part:FindFirstChildOfClass("PathfindingModifier") then
			local mod = Instance.new("PathfindingModifier")
			mod.PassThrough = false
			mod.Parent = part
		end
		visitedCount += 1
		if visitedCount % 50 == 0 then
			task.wait()
		end
	end
end

local function ShouldBlockStaticPathing(itemName, itemConfig)
	if not itemConfig or itemConfig.Type ~= "Static" then
		return false
	end
	if itemConfig.PlacementMode ~= "SlopeDownhill" then
		return false
	end
	return itemName == "Ramp" or itemName == "Ski Rail"
end

local function StabilizeLiftVisualModel(model)
	if not model or not model:IsA("Model") then
		return
	end
	pcall(function()
		model.ModelStreamingMode = Enum.ModelStreamingMode.Atomic
	end)
	pcall(function()
		model.LevelOfDetail = Enum.ModelLevelOfDetail.Disabled
	end)
end

local function GeneratePoles(liftModel, startStation, endStation, assetTemplate, itemConfig, savedPoles)
	local poleTemplate = assetTemplate:FindFirstChild("Pole")
	if not poleTemplate then return {}, {} end
	
	local polePivot = poleTemplate:GetPivot()
	local poleCablePos = GetCableCenter(poleTemplate)
	local defaultPoleHeight = (poleCablePos - polePivot.Position).Y
	if defaultPoleHeight < 5 then defaultPoleHeight = 22 end
	
	local _, poleBBSize = poleTemplate:GetBoundingBox()
	local poleModelHeight = poleBBSize.Y

	local function getBaseHeight(model)
		if not model then return 0 end
		local b = model:FindFirstChild("Base", true)
		if b and b:IsA("BasePart") then return b.Size.Y end
		return 0
	end
	local poleBaseH = getBaseHeight(poleTemplate)
	local treeSnap, terrainSnap, createdPoles = {}, {}, {}
	local restoreThrottle = (_G.BuildingRestoreInProgress == true)
	local adPoleTemplate = assetTemplate:FindFirstChild("ADPole")
	local adPoleBaseH = getBaseHeight(adPoleTemplate)
	local startPos = GetCableCenter(startStation)
	local endPos = GetCableCenter(endStation)
	local span = endPos - startPos
	local dist = span.Magnitude
	local dir = dist > 0.001 and span.Unit or Vector3.zAxis
	local pSpacing = itemConfig.PoleSpacing or 80

	-- // FIX: STATION EDGE OFFSETS FOR FIRST AND LAST POLES
	local _, startSize = startStation:GetBoundingBox()
	local _, endSize = endStation:GetBoundingBox()

	local startEdge = math.max(startSize.X, startSize.Z) / 2
	local endEdge = math.max(endSize.X, endSize.Z) / 2

	local firstPoleDist = startEdge + 20
	local maxPoleDist = dist - endEdge - 15 -- Prevents spawning inside the end station bounds

	-- Saved poles store the pole pivot, not the cable contact point. Validate them in X/Z
	-- so tall or steep lifts do not get falsely rejected and regenerated on restore.
	local flatStartPos = Vector3.new(startPos.X, 0, startPos.Z)
	local flatEndPos = Vector3.new(endPos.X, 0, endPos.Z)
	local flatSpan = flatEndPos - flatStartPos
	local flatDist = flatSpan.Magnitude
	local flatDir = flatDist > 0.001 and flatSpan.Unit or Vector3.new(dir.X, 0, dir.Z)
	if flatDir.Magnitude < 0.001 then
		flatDir = Vector3.zAxis
	else
		flatDir = flatDir.Unit
	end

	local function validateSavedPoleData(pData)
		if type(pData) ~= "table" or typeof(pData.CF) ~= "CFrame" then
			return nil
		end
		local pos = pData.CF.Position
		local flatPos = Vector3.new(pos.X, 0, pos.Z)
		local progress = (flatPos - flatStartPos):Dot(flatDir)
		if progress < (firstPoleDist - 80) or progress > (maxPoleDist + 80) then
			return nil
		end
		local projected = flatStartPos + flatDir * math.clamp(progress, 0, math.max(flatDist, 0.001))
		local lateral = (flatPos - projected).Magnitude
		if lateral > math.max(70, pSpacing * 0.9) then
			return nil
		end
		return {
			Name = pData.Name,
			CF = pData.CF,
			Progress = progress,
		}
	end

	if savedPoles and #savedPoles > 0 then
		local validatedSavedPoles = {}
		for _, pData in ipairs(savedPoles) do
			local validated = validateSavedPoleData(pData)
			if validated then
				table.insert(validatedSavedPoles, validated)
			end
		end
		table.sort(validatedSavedPoles, function(a, b)
			return a.Progress < b.Progress
		end)

		local canUseSavedPoles = #validatedSavedPoles > 0
		if #savedPoles >= 2 and #validatedSavedPoles < math.max(1, math.ceil(#savedPoles * 0.6)) then
			canUseSavedPoles = false
		end
		if dist > (pSpacing * 1.5) and #validatedSavedPoles == 0 then
			canUseSavedPoles = false
		end

		if canUseSavedPoles then
			for poleIndex, pData in ipairs(validatedSavedPoles) do
				local pole = poleTemplate:Clone()
				pole.Name = pData.Name or ("Pole_" .. poleIndex)
				StabilizeLiftVisualModel(pole)
				pole.Parent = liftModel
				pole:PivotTo(pData.CF)

				local groundRay = workspace:Raycast(pole:GetPivot().Position + Vector3.new(0, 200, 0), Vector3.new(0, -500, 0), TERRAIN_RAY_PARAMS)
				if groundRay then pole:SetAttribute("OriginalY", groundRay.Position.Y) else pole:SetAttribute("OriginalY", pole:GetPivot().Position.Y) end

				for _, t in ipairs(ClearTreesBuilding(pole)) do table.insert(treeSnap, t) end

				table.insert(createdPoles, pole)
				if restoreThrottle and poleIndex % 4 == 0 then
					task.wait()
				end
			end
			if #createdPoles > 0 then AlignPoleSheaths(startStation, endStation, createdPoles, itemConfig) end
			return treeSnap, terrainSnap
		else
			warn(string.format("[PlacementServer] Ignoring suspicious saved poles for %s and regenerating them.", tostring(liftModel.Name)))
		end
	end

	local polePoints = {}
	local currentDist = firstPoleDist
	
	while currentDist <= maxPoleDist do
		local idealPos = startPos + (dir * currentDist)
		local gy = GetTerrainY(idealPos.X, idealPos.Z)
		
		if gy then
			-- Adaptive Spacing: Measure local slope to decide next spacing
			local lookAheadDist = 10
			local nextPos = startPos + (dir * math.min(currentDist + lookAheadDist, maxPoleDist))
			local ngy = GetTerrainY(nextPos.X, nextPos.Z) or gy
			
			local rise = math.abs(ngy - gy)
			local run = (nextPos - idealPos).Magnitude
			local angle = math.deg(math.atan(rise / math.max(1, run)))
			
			local spacingMult = 1.0
			if angle > 30 then spacingMult = 0.55 -- Steep: Closer poles
			elseif angle > 18 then spacingMult = 0.8
			elseif angle < 6 then spacingMult = 1.25 -- Flat: Further apart
			end
			
			table.insert(polePoints, {
				Pos = idealPos,
				GroundY = gy,
				Dist = currentDist,
				IsAD = false
			})
			
			currentDist = currentDist + (pSpacing * spacingMult)
		else
			currentDist = currentDist + pSpacing -- Safety advance if terrain missing
		end
	end
	
	local adIndices = {}
	if adPoleTemplate and #polePoints >= 3 then
		for i=1, 3 do adIndices[math.random(1, #polePoints)] = true end
	end
	
	for i, pt in ipairs(polePoints) do
		local tpl = (adIndices[i] and adPoleTemplate) and adPoleTemplate or poleTemplate
		local pole = tpl:Clone(); pole.Name = "Pole_" .. i; StabilizeLiftVisualModel(pole); pole.Parent = liftModel
		
		-- Calculate straight-line target height
		local ratio = pt.Dist / dist
		local straightY = startPos.Y + (endPos.Y - startPos.Y) * ratio
		local idealPivotY = straightY - defaultPoleHeight
		
		-- Apply limits: Max float = top of base (prevent gap), Max bury 10 studs
		local currentBaseH = (adIndices[i] and adPoleBaseH or poleBaseH)
		local minPivotY = pt.GroundY - 10
		local maxPivotY = pt.GroundY + currentBaseH
		
		local targetY = math.clamp(idealPivotY, minPivotY, maxPivotY)
		
		local x, z = pt.Pos.X, pt.Pos.Z
		local yaw = CFrame.lookAt(Vector3.new(x, targetY, z), Vector3.new(x + dir.X, targetY, z + dir.Z)) * CFrame.Angles(0, math.rad(itemConfig.PoleBodyRotationY or 0), 0)
		
		pole:PivotTo(yaw)
		pole:SetAttribute("OriginalY", pt.GroundY)
		
		local basePart = pole:FindFirstChild("Base", true)
		if basePart and basePart:IsA("BasePart") then
			local bCF = basePart.CFrame
			basePart.CFrame = CFrame.new(bCF.Position.X, pt.GroundY + (basePart.Size.Y * 0.5), bCF.Position.Z) * bCF.Rotation
		end
		
		for _, t in ipairs(ClearTreesBuilding(pole)) do table.insert(treeSnap, t) end
		if itemConfig.SurfaceTow ~= true then
			CreatePoleMound(Vector3.new(x, targetY, z))
		end
		table.insert(createdPoles, pole)
		if i % 4 == 0 then
			task.wait()
		end
	end

	if #createdPoles > 0 then AlignPoleSheaths(startStation, endStation, createdPoles, itemConfig) end
	return treeSnap, terrainSnap
end

-- =============================================================================
-- POST-LOAD RE-CLEARING SYSTEM
-- =============================================================================
local function ReapplyAllClearings()
	local placedFolder = workspace:FindFirstChild("PlacedObjects")
	if not placedFolder then return end
	local treeFolder = workspace:FindFirstChild("TreeFolder")
	if not treeFolder then return end

	local objectCount, treesCleared = 0, 0
	for _, obj in ipairs(placedFolder:GetChildren()) do
		if not obj:IsA("Model") then continue end
		objectCount += 1
		local itemType = obj:GetAttribute("Type")

		if itemType == "TwoPoint" or itemType == "Carpet" then
			for _, child in ipairs(obj:GetChildren()) do
				if child:IsA("Model") then
					local cf, size = child:GetBoundingBox()
					if size.X > MAX_FOOTPRINT or size.Z > MAX_FOOTPRINT then cf = CFrame.new(child:GetPivot().Position); size = Vector3.new(40, 40, 40) end
					local beforeCount = #treeFolder:GetChildren()
					ClearTreesBox(cf, size + Vector3.new(TREE_PAD_XZ, TREE_PAD_Y, TREE_PAD_XZ), nil)
					treesCleared += (beforeCount - #treeFolder:GetChildren())
					-- Retrofit pathfinding blockers on existing lift parts
					if itemType == "TwoPoint" then
						AddPathfindingBlockers(child)
					end
				end
			end
			local sS, eS = obj:FindFirstChild("StartStation"), obj:FindFirstChild("EndStation")
			if sS and eS then
				local beforeCount = #treeFolder:GetChildren()
				ClearTreesPath(GetCableCenter(sS), GetCableCenter(eS), CABLE_TREE_WIDTH)

				if itemType == "TwoPoint" then
					CarveCablePath(GetCableCenter(sS), GetCableCenter(eS))
				end

				treesCleared += (beforeCount - #treeFolder:GetChildren())
			end
		else
			local cf, size = obj:GetBoundingBox()
			if size.X > MAX_FOOTPRINT or size.Z > MAX_FOOTPRINT then cf = CFrame.new(obj:GetPivot().Position); size = Vector3.new(40, 40, 40) end
			local beforeCount = #treeFolder:GetChildren()
			ClearTreesBox(cf, size + Vector3.new(TREE_PAD_XZ, TREE_PAD_Y, TREE_PAD_XZ), nil)
			treesCleared += (beforeCount - #treeFolder:GetChildren())
		end
		if objectCount % 3 == 0 then task.wait() end
	end
end

task.spawn(function()
	local TerrainReady = Events:WaitForChild("TerrainReady", 30)
	if TerrainReady then
		TerrainReady.Event:Connect(function()
			task.wait(2)
			ReapplyAllClearings()
		end)
	end
end)

-- =============================================================================
-- PLACE ITEM
-- =============================================================================
local function PlaceItem(player, data)
	local lastReq = PlacementDebounces[player.UserId] or 0
	if os.clock() - lastReq < 0.5 then
		return false
	end
	PlacementDebounces[player.UserId] = os.clock()

	if not TransactionFunc then return false end
	if not MultiplayerPermissions.CanBuild(player) then
		if NotificationEvent then
			NotificationEvent:FireClient(player, "Negative", "BUILD LOCKED", "The resort owner has not given you build permission here.", 4)
		end
		return false
	end

	-- B-062: decor catalog uses "Metal Fence"; accept legacy/short name "Fence" for placement payloads.
	if type(data.ItemName) == "string" and data.ItemName == "Fence" and not Config.Items["Fence"] and Config.Items["Metal Fence"] then
		data.ItemName = "Metal Fence"
	end

	local itemConfig = Config.Items[data.ItemName]
	if not itemConfig then return false end

	if typeof(data.CFrame) ~= "CFrame" then
		if NotificationEvent then
			NotificationEvent:FireClient(player, "Negative", "PLACE FAILED", "That item placement request was invalid. Please try again.", 4)
		end
		return false
	end
	if (itemConfig.Type == "TwoPoint" or itemConfig.Type == "Carpet") and typeof(data.EndCFrame) ~= "CFrame" then
		if NotificationEvent then
			NotificationEvent:FireClient(player, "Negative", "PLACE FAILED", "That lift placement request was invalid. Please try again.", 4)
		end
		return false
	end

	-- Carpet-specific: validate terrain roughness before charging money
	if itemConfig.Type == "Carpet" and typeof(data.CFrame) == "CFrame" and typeof(data.EndCFrame) == "CFrame" then
		-- Angle check (server-side enforcement)
		local dH = Vector3.new(data.EndCFrame.Position.X - data.CFrame.Position.X, 0, data.EndCFrame.Position.Z - data.CFrame.Position.Z).Magnitude
		local dV = data.EndCFrame.Position.Y - data.CFrame.Position.Y
		local pitchAngle = math.abs(math.deg(math.atan2(dV, math.max(1, dH))))
		if itemConfig.MaxAngle and pitchAngle > itemConfig.MaxAngle then
			if NotificationEvent then
				NotificationEvent:FireClient(player, "Negative", "TOO STEEP", "Magic Carpets can only be placed on flat or gently sloped terrain (max " .. itemConfig.MaxAngle .. "°).", 4)
			end
			return false
		end

		-- Roughness check
		if itemConfig.MaxTerrainRoughness then
			local roughOk, roughMsg = ValidateCarpetTerrainRoughness(data.CFrame.Position, data.EndCFrame.Position, itemConfig)
			if not roughOk then
				if NotificationEvent then
					NotificationEvent:FireClient(player, "Negative", "TERRAIN TOO ROUGH", roughMsg or "Magic Carpets need smooth, flat ground.", 4)
				end
				return false
			end
		end
	end

	local isUnlocked, lockInfo = getPlacementUnlockState(player, data.ItemName)
	if not isUnlocked then
		if NotificationEvent then
			local subtitle = (type(lockInfo) == "table" and lockInfo.subtitle) or "Unlock required before placing."
			NotificationEvent:FireClient(player, "Negative", "LOCKED", subtitle, 4)
		end
		return false
	end

	local assetTemplate = FindAssetTemplate(data.ItemName)
	if not assetTemplate then
		if NotificationEvent then
			NotificationEvent:FireClient(player, "Negative", "PLACE FAILED", "Missing build template for " .. tostring(data.ItemName) .. ".", 4)
		end
		return false
	end

	-- Calculate full cost including research discounts and per-stud pricing.
	local distanceStuds = nil
	if (itemConfig.Type == "TwoPoint" or itemConfig.Type == "Carpet") and data.EndCFrame then
		distanceStuds = (data.CFrame.Position - data.EndCFrame.Position).Magnitude
	end
	local finalCost = Config.GetPlacementCost(data.ItemName, player, distanceStuds)

	local transactionType = Enum.AnalyticsEconomyTransactionType.Shop
	local ok, paid = pcall(function() return TransactionFunc:Invoke(player, finalCost, data.ItemName, transactionType) end)

	if not ok then return false end
	if not paid then return false end

	-- ── BUILDING CAP CHECK ──────────────────────────────────────────────────
	-- Checked AFTER payment is committed so money is already deducted.
	-- Cap is 300 placed objects; Slot Data Limit Bypass pass or Resort Pass sub removes it.
	-- NOTE: If the check fails here the payment is already deducted — in practice the
	--       client should show the cap warning before payment via the attribute below,
	--       but server is authoritative so we double-check and refund via RemovalServer.
	if not hasSlotBypass(player) and getPlacedObjectCount() >= MAX_OBJECTS then
		if NotificationEvent then
			NotificationEvent:FireClient(player, "Negative", "OBJECT LIMIT REACHED",
				string.format("Your resort has reached the %d-object limit. Purchase the Slot Data Limit Bypass pass to remove this cap.", MAX_OBJECTS), 6)
		end
		-- Refund the player
		pcall(function() TransactionFunc:Invoke(player, -finalCost, data.ItemName, Enum.AnalyticsEconomyTransactionType.Shop) end)
		return false
	end
	-- ────────────────────────────────────────────────────────────────────────

	local placementResult = nil
	local placementOk, placementErr = pcall(function()
		local placedFolder = workspace:FindFirstChild("PlacedObjects") or Instance.new("Folder", workspace)
		placedFolder.Name = "PlacedObjects"
		local newObject = Instance.new("Model"); newObject.Name = data.ItemName
		local uuid = HttpService:GenerateGUID(false)
		local ignoreList = {newObject, workspace.CurrentCamera, player.Character}

		local liftStartStation, liftEndStation = nil, nil
		local shouldFinalizePlacement = false
		local function runPlacementFinalization()
		local treeSnap, terrainSnap, treeMoveSnap = {}, {}, {}
		local function merge(t, s)
			for _, v in ipairs(s) do
				table.insert(t, v)
			end
		end

		if itemConfig.Type == "TwoPoint" or itemConfig.Type == "Carpet" then
			local sS, eS = liftStartStation, liftEndStation
			if not sS or not eS or not sS.Parent or not eS.Parent then
				return
			end

			local shouldBlendLiftStations = Config.ShouldTerrainBlend(data.ItemName, itemConfig) and itemConfig.Type ~= "Carpet" and itemConfig.SurfaceTow ~= true
			if shouldBlendLiftStations then
				local t1, tm1 = SmartPlatformTerrain(sS, true)
				local t2, tm2 = SmartPlatformTerrain(eS, false)
				merge(terrainSnap, t1)
				merge(terrainSnap, t2)
				merge(treeMoveSnap, tm1)
				merge(treeMoveSnap, tm2)
			end
			merge(treeSnap, ClearTreesBuilding(sS))
			merge(treeSnap, ClearTreesBuilding(eS))
			merge(treeSnap, ClearTreesPath(GetCableCenter(sS), GetCableCenter(eS), CABLE_TREE_WIDTH))

			if itemConfig.Type == "TwoPoint" then
				local poleTrees, poleTerrain = GeneratePoles(newObject, sS, eS, assetTemplate, itemConfig)
				merge(treeSnap, poleTrees)
				merge(terrainSnap, poleTerrain)
				task.wait()
				merge(terrainSnap, CarveCablePath(GetCableCenter(sS), GetCableCenter(eS)))
				AddPathfindingBlockers(sS)
				AddPathfindingBlockers(eS)
				for _, child in ipairs(newObject:GetChildren()) do
					if child:IsA("Model") and child.Name:match("^Pole_") then
						AddPathfindingBlockers(child)
					end
				end
			end
		else
			if itemConfig.Type ~= CustomBuildingConfig.TYPE_NAME and Config.ShouldTerrainBlend(data.ItemName, itemConfig) then
				local t1, tm1 = SmartPlatformTerrain(newObject, true)
				merge(terrainSnap, t1)
				merge(treeMoveSnap, tm1)
			end
			merge(treeSnap, ClearTreesBuilding(newObject))
			if ShouldBlockStaticPathing(data.ItemName, itemConfig) then
				AddPathfindingBlockers(newObject)
			end
		end

		if #treeSnap > 0 then newObject:SetAttribute("TreeSnapshot", HttpService:JSONEncode(treeSnap)) end
		if #terrainSnap > 0 then
			-- Chunk terrain snapshot to stay under Roblox's 200KB attribute limit
			-- RemovalServer expects each chunk to be a valid JSON array
			local ENTRIES_PER_CHUNK = 2000
			if #terrainSnap <= ENTRIES_PER_CHUNK then
				newObject:SetAttribute("TerrainSnapshot", HttpService:JSONEncode(terrainSnap))
			else
				local chunkIndex = 0
				for i = 1, #terrainSnap, ENTRIES_PER_CHUNK do
					chunkIndex += 1
					local chunk = {}
					for j = i, math.min(i + ENTRIES_PER_CHUNK - 1, #terrainSnap) do
						table.insert(chunk, terrainSnap[j])
					end
					local attrName = (chunkIndex == 1) and "TerrainSnapshot" or ("TerrainSnapshot_" .. chunkIndex)
					newObject:SetAttribute(attrName, HttpService:JSONEncode(chunk))
				end
				newObject:SetAttribute("TerrainSnapshotChunkCount", chunkIndex)
			end
		end
		if #treeMoveSnap > 0 then newObject:SetAttribute("TreeMoveSnapshot", HttpService:JSONEncode(treeMoveSnap)) end
		-- Safety: rescue player if they fell through terrain during placement
		if player and player.Character then
			local root = player.Character:FindFirstChild("HumanoidRootPart")
			if root and root.Position.Y < -50 then
				local spawnPos = workspace:FindFirstChild("SpawnLocation")
				if spawnPos then
					root.CFrame = spawnPos.CFrame + Vector3.new(0, 5, 0)
				end
			end
		end
		if itemConfig.Type == "TwoPoint" or itemConfig.Type == "Carpet" then
			local refreshId = tonumber(newObject:GetAttribute("RefreshID")) or 0
			newObject:SetAttribute("RefreshID", refreshId + 1)
		end
	end

	if itemConfig.Type == CustomBuildingConfig.TYPE_NAME then
		newObject = CustomBuildingConfig.CreateModel(data.ItemName)
		local initialCFrame = typeof(data.CFrame) == "CFrame" and data.CFrame or CFrame.new()
		CustomBuildingConfig.ApplyState(newObject, {
			Position = initialCFrame.Position,
			Yaw = CustomBuildingConfig.GetYawDegrees(initialCFrame),
			Size = typeof(data.Size) == "Vector3" and data.Size or CustomBuildingConfig.DEFAULT_SIZE,
			Color = typeof(data.Color) == "Color3" and data.Color or CustomBuildingConfig.DEFAULT_COLOR,
			Material = data.Material or CustomBuildingConfig.DEFAULT_MATERIAL,
			Shape = type(data.Shape) == "string" and data.Shape or nil,
		})
		shouldFinalizePlacement = true
		newObject:SetAttribute("Type", itemConfig.Type)
	elseif itemConfig.Type == "TwoPoint" or itemConfig.Type == "Carpet" then
		local sT, eT = assetTemplate:FindFirstChild("StartStation"), assetTemplate:FindFirstChild("EndStation")
		local rotCF = CFrame.Angles(0, math.rad(itemConfig.StationRotation or 0), 0)
		StabilizeLiftVisualModel(newObject)
		local sS = sT:Clone(); StabilizeLiftVisualModel(sS); sS.Parent = newObject
		local eS = eT:Clone(); StabilizeLiftVisualModel(eS); eS.Parent = newObject
		if itemConfig.Type == "Carpet" then
			-- Carpet stays exactly where the player placed it; terrain is smoothed to fit
			sS:PivotTo(data.CFrame * rotCF)
			eS:PivotTo(data.EndCFrame * rotCF)
		else
			sS:PivotTo(AutoSeatFlat(data.CFrame, select(2, sT:GetBoundingBox()), ignoreList, sT) * rotCF)
			eS:PivotTo(AutoSeatFlat(data.EndCFrame, select(2, eT:GetBoundingBox()), ignoreList, eT) * rotCF)
		end
		liftStartStation = sS
		liftEndStation = eS
		shouldFinalizePlacement = true

		if itemConfig.Type == "Carpet" then
			local secTpl = assetTemplate:FindFirstChild("Section")
			if secTpl then
				local p1 = GetS1Pos(sS)
				local p2 = GetS1Pos(eS)
				local dist = (p2 - p1).Magnitude

				if dist > 0.1 then
					local dir = (p2 - p1).Unit
					local rotX = math.rad(itemConfig.ChairRotationX or 0)
					local rotY = math.rad(itemConfig.ChairRotationY or 0)
					local rotZ = math.rad(itemConfig.ChairRotationZ or 0)
					local configRot = CFrame.Angles(rotX, rotY, rotZ)

					local basePart = secTpl:IsA("Model") and (secTpl:FindFirstChild("Base") or secTpl.PrimaryPart or secTpl:FindFirstChildWhichIsA("BasePart")) or secTpl
					local rawSize = basePart:IsA("BasePart") and basePart.Size or Vector3.new(10, 10, 10)

					local rotatedSize = configRot * rawSize
					local secStep = math.abs(rotatedSize.Z)
					if secStep < 0.1 then secStep = math.abs(rotatedSize.X) end
					secStep = math.max(1, secStep)

					local numSections = math.max(1, math.ceil(dist / secStep))
					local terrainSamples = Config.ShouldTerrainBlend(data.ItemName, itemConfig)
						and BuildCarpetTerrainSamples(p1, p2, numSections + 1)
						or nil

					local secFolder = Instance.new("Folder")
					secFolder.Name = "Sections"
					secFolder.Parent = newObject

					for i = 0, numSections - 1 do
						local sec = secTpl:Clone()
						sec.Name = "Section_" .. (i + 1)
						local sampleA = terrainSamples and terrainSamples[i + 1] or (p1 + dir * (i * secStep))
						local sampleB = terrainSamples and terrainSamples[i + 2] or (p1 + dir * ((i + 1) * secStep))
						local pos = sampleA:Lerp(sampleB, 0.5)
						local secDir = sampleB - sampleA
						if secDir.Magnitude < 0.1 then
							secDir = dir
						end
						secDir = secDir.Unit
						local cf = BuildCarpetSectionCFrame(sec, pos, secDir, itemConfig)

						if sec:IsA("BasePart") then
							sec.CFrame = cf
						elseif sec:IsA("Model") then
							local secBase = sec:FindFirstChild("Base") or sec.PrimaryPart or sec:FindFirstChildWhichIsA("BasePart")
							if secBase then
								local offset = secBase.CFrame:Inverse() * sec:GetPivot()
								sec:PivotTo(cf * offset)
							else
								sec:PivotTo(cf)
							end
						end
						sec.Parent = secFolder
					end

			end
		end
		end

		newObject:SetAttribute("Type", itemConfig.Type)
		newObject:SetAttribute("P1", sS:GetPivot().Position)
		newObject:SetAttribute("P2", eS:GetPivot().Position)
		ApplySavedSnapshotAttributes(newObject, data)
	else
		if assetTemplate:IsA("Model") then
			newObject = assetTemplate:Clone()
			local requestedHeightOffset = tonumber(data.HeightOffset) or 0
			local placedCFrame
			if itemConfig.PlacementMode == "SlopeDownhill" then
				placedCFrame = BuildSlopeAlignedStaticCFrame(newObject, data.CFrame)
			else
				local clientYaw = type(data.YawDegrees) == "number" and data.YawDegrees or nil
			placedCFrame = AutoSeatFlat(data.CFrame, select(2, newObject:GetBoundingBox()), ignoreList, newObject, clientYaw)
			end
			placedCFrame = ApplyWorldHeightOffset(placedCFrame, requestedHeightOffset)
			if math.abs(requestedHeightOffset) > 0.01 then
				newObject:SetAttribute("PlacementHeightOffset", requestedHeightOffset)
			else
				newObject:SetAttribute("PlacementHeightOffset", nil)
			end
			newObject:PivotTo(placedCFrame)
			MaybeForceUprightBase(newObject, itemConfig)
		end
		shouldFinalizePlacement = true
		newObject:SetAttribute("Type", itemConfig.Type)
	end

	local resortOwnerId = MultiplayerPermissions.GetOwnerUserId()
	local effectiveOwnerId = (resortOwnerId and resortOwnerId > 0) and resortOwnerId or player.UserId
	newObject:SetAttribute("UUID", uuid)
	newObject:SetAttribute("Owner", effectiveOwnerId)
	newObject:SetAttribute("OwnerId", effectiveOwnerId)
	newObject:SetAttribute("PlacedByUserId", player.UserId)
	newObject:SetAttribute("Price", finalCost)
	newObject:SetAttribute("PaidPrice", finalCost)
	newObject:SetAttribute("PlacementTime", os.time())
	newObject:SetAttribute("BasePrice", itemConfig.Price or 0)
	local canonicalPlacedName = tostring(data.ItemName or newObject.Name or "")
	if canonicalPlacedName ~= "" then
		newObject:SetAttribute("DefaultPlacedName", canonicalPlacedName)
	end
	if type(data.CustomName) == "string" and data.CustomName ~= "" then
		newObject:SetAttribute("CustomName", data.CustomName)
	end
	local placedItemId = Config.GetSaveId(data.ItemName, itemConfig) or itemConfig.ID
	if placedItemId then newObject:SetAttribute("ID", tostring(placedItemId)) end
	newObject.Parent = placedFolder
	if shouldFinalizePlacement then
		task.defer(function()
			runPlacementFinalization()
			if RequestBuildingSave then
				RequestBuildingSave:Fire()
			end
		end)
	elseif RequestBuildingSave then
		RequestBuildingSave:Fire()
	end

		placementResult = { success = true, uuid = uuid, itemName = newObject.Name, type = itemConfig.Type }
	end)

	if not placementOk then
		warn("[PlacementServer] PlaceItem failed for " .. tostring(data.ItemName) .. ": " .. tostring(placementErr))
		pcall(function()
			TransactionFunc:Invoke(player, -finalCost, tostring(data.ItemName) .. "_Refund", Enum.AnalyticsEconomyTransactionType.Gameplay)
		end)
		if NotificationEvent then
			NotificationEvent:FireClient(player, "Negative", "PLACE FAILED", "The item could not be placed, so your money was refunded.", 4)
		end
		return false
	end

	return placementResult
end

RestoreItem.Event:Connect(function(player, data)
	local isRestore = (player == nil)
	if isRestore then
		script:SetAttribute("RestoreItemName", tostring(data and data.Item or "?"))
		script:SetAttribute("RestoreItemUUID", tostring(data and data.UUID or "?"))
	end
	local itemConfig = Config.Items[data.Item]; if not itemConfig then return end
	local assetTemplate = FindAssetTemplate(data.Item); if not assetTemplate then return end
	local placedFolder = workspace:FindFirstChild("PlacedObjects") or Instance.new("Folder", workspace)
	placedFolder.Name = "PlacedObjects"
	local newObject = Instance.new("Model"); newObject.Name = data.Item
	local uuid = data.UUID or HttpService:GenerateGUID(false)
	local existing = FindPlacedObjectByUUID(uuid)
	if existing then
		if ShouldReplaceRestoredObject(existing) then
			existing:Destroy()
		else
			return
		end
	end

	if itemConfig.Type == CustomBuildingConfig.TYPE_NAME then
		newObject = CustomBuildingConfig.CreateModel(data.Item)
		local restoredCFrame = typeof(data.CF) == "CFrame" and data.CF or CFrame.new()
		CustomBuildingConfig.ApplyState(newObject, {
			Position = restoredCFrame.Position,
			Yaw = CustomBuildingConfig.GetYawDegrees(restoredCFrame),
			Size = typeof(data.Size) == "Vector3" and data.Size or CustomBuildingConfig.DEFAULT_SIZE,
			Color = typeof(data.Color) == "Color3" and data.Color or CustomBuildingConfig.DEFAULT_COLOR,
			Material = data.Material or CustomBuildingConfig.DEFAULT_MATERIAL,
			Shape = type(data.Shape) == "string" and data.Shape or nil,
		})
	elseif itemConfig.Type == "TwoPoint" or itemConfig.Type == "Carpet" then
		local sT, eT = assetTemplate:FindFirstChild("StartStation"), assetTemplate:FindFirstChild("EndStation")
		local sS = sT:Clone(); sS.Parent = newObject
		local eS = eT:Clone(); eS.Parent = newObject
		if data.HasRotation and data.StartCF and data.EndCF then
			sS:PivotTo(data.StartCF); eS:PivotTo(data.EndCF)
		elseif typeof(data.Start) == "Vector3" and typeof(data.End) == "Vector3" and (data.End - data.Start).Magnitude > 0.05 then
			local dir = (data.End - data.Start).Unit
			local r = itemConfig.StationRotation or 0
			sS:PivotTo(CFrame.lookAt(data.Start, data.Start+dir) * CFrame.Angles(0, math.rad(r), 0))
			eS:PivotTo(CFrame.lookAt(data.End, data.End-dir) * CFrame.Angles(0, math.rad(r), 0))
		elseif typeof(data.StartCF) == "CFrame" and typeof(data.EndCF) == "CFrame" then
			sS:PivotTo(data.StartCF); eS:PivotTo(data.EndCF)
		else
			if isRestore then
				warn(string.format("[PlacementServer] Lift restore missing usable endpoints item=%s uuid=%s", tostring(data.Item), tostring(data.UUID)))
			end
			return
		end

		if itemConfig.Type == "Carpet" then
			local secTpl = assetTemplate:FindFirstChild("Section")
			if secTpl then
				local p1 = GetS1Pos(sS)
				local p2 = GetS1Pos(eS)
				local dist = (p2 - p1).Magnitude

				if dist > 0.1 then
					local dir = (p2 - p1).Unit
					local rotX = math.rad(itemConfig.ChairRotationX or 0)
					local rotY = math.rad(itemConfig.ChairRotationY or 0)
					local rotZ = math.rad(itemConfig.ChairRotationZ or 0)
					local configRot = CFrame.Angles(rotX, rotY, rotZ)

					local basePart = secTpl:IsA("Model") and (secTpl:FindFirstChild("Base") or secTpl.PrimaryPart or secTpl:FindFirstChildWhichIsA("BasePart")) or secTpl
					local rawSize = basePart:IsA("BasePart") and basePart.Size or Vector3.new(10, 10, 10)

					local rotatedSize = configRot * rawSize
					local secStep = math.abs(rotatedSize.Z)
					if secStep < 0.1 then secStep = math.abs(rotatedSize.X) end
					secStep = math.max(1, secStep)

					local numSections = math.max(1, math.ceil(dist / secStep))
					local step = dist / numSections

					local secFolder = Instance.new("Folder")
					secFolder.Name = "Sections"
					secFolder.Parent = newObject

					for i = 0, numSections - 1 do
						local sec = secTpl:Clone()
						sec.Name = "Section_" .. (i + 1)
						local pos = p1 + dir * (i * step + step / 2)
						local cf = BuildCarpetSectionCFrame(sec, pos, dir, itemConfig)

						if sec:IsA("BasePart") then
							sec.CFrame = cf
						elseif sec:IsA("Model") then
							local secBase = sec:FindFirstChild("Base") or sec.PrimaryPart or sec:FindFirstChildWhichIsA("BasePart")
							if secBase then
								local offset = secBase.CFrame:Inverse() * sec:GetPivot()
								sec:PivotTo(cf * offset)
							else
								sec:PivotTo(cf)
							end
						end
						sec.Parent = secFolder
						if isRestore and ((i + 1) % 10) == 0 then
							task.wait()
						end
					end


				end
			end
		end

		if Config.ShouldTerrainBlend(data.Item, itemConfig) and itemConfig.Type ~= "Carpet" then
			SmartPlatformTerrain(sS, true); SmartPlatformTerrain(eS, false)
			if isRestore then
				task.wait()
			end
		end
		ClearTreesBuilding(sS); ClearTreesBuilding(eS)
		ClearTreesPath(GetCableCenter(sS), GetCableCenter(eS), CABLE_TREE_WIDTH)

		if itemConfig.Type == "TwoPoint" then
			CarveCablePath(GetCableCenter(sS), GetCableCenter(eS))
			GeneratePoles(newObject, sS, eS, assetTemplate, itemConfig, data.Poles)
			if isRestore then
				task.wait()
			end
			-- Mark restored lift parts as pathfinding obstacles
			AddPathfindingBlockers(sS)
			AddPathfindingBlockers(eS)
			for _, child in ipairs(newObject:GetChildren()) do
				if child:IsA("Model") and child.Name:match("^Pole_") then
					AddPathfindingBlockers(child)
				end
			end
		end

		newObject:SetAttribute("P1", sS:GetPivot().Position)
		newObject:SetAttribute("P2", eS:GetPivot().Position)
	else
		local restoredCFrame = typeof(data.CF) == "CFrame" and data.CF or CFrame.new()
		local savedHeightOffset = tonumber(data.HeightOffset) or 0
		if assetTemplate:IsA("Model") then
			newObject = assetTemplate:Clone()
		else
			for _, c in ipairs(assetTemplate:GetChildren()) do
				c:Clone().Parent = newObject
			end
		end
		-- Restore the exact saved transform for static items instead of re-solving
		-- against current terrain. This keeps downhill props and sculpted placements
		-- stable across rejoins once the world seed/terrain actions are restored.
		newObject:PivotTo(restoredCFrame)
		MaybeForceUprightBase(newObject, itemConfig)
		if math.abs(savedHeightOffset) > 0.01 then
			newObject:SetAttribute("PlacementHeightOffset", savedHeightOffset)
		else
			newObject:SetAttribute("PlacementHeightOffset", nil)
		end
		if Config.ShouldTerrainBlend(data.Item, itemConfig) then
			local terrainLog, treeMoveLog = SmartPlatformTerrain(newObject, true)
			if isRestore then
				task.wait()
			end
			ApplySavedSnapshotAttributes(newObject, data)
			ApplyTerrainSnapshotAttributes(newObject, terrainLog, treeMoveLog)
		else
			ApplySavedSnapshotAttributes(newObject, data)
		end
		ClearTreesBuilding(newObject)
		if ShouldBlockStaticPathing(data.Item, itemConfig) then
			AddPathfindingBlockers(newObject)
		end
	end
	newObject:SetAttribute("Type", itemConfig.Type)
	newObject:SetAttribute("UUID", uuid)
	local restoredResortOwnerId = MultiplayerPermissions.GetOwnerUserId()
	local restoredEffectiveOwnerId = (restoredResortOwnerId and restoredResortOwnerId > 0) and restoredResortOwnerId or (data.OwnerId or 0)
	newObject:SetAttribute("Owner", restoredEffectiveOwnerId)
	newObject:SetAttribute("OwnerId", restoredEffectiveOwnerId)
	if data.PlacedByUserId ~= nil then
		newObject:SetAttribute("PlacedByUserId", data.PlacedByUserId)
	end
	local canonicalRestoredName = tostring(data.Item or newObject.Name or "")
	if canonicalRestoredName ~= "" then
		newObject:SetAttribute("DefaultPlacedName", canonicalRestoredName)
	end
	if type(data.CustomName) == "string" and data.CustomName ~= "" then
		newObject:SetAttribute("CustomName", data.CustomName)
	end
	local restoredCleanliness = tonumber(data.Cleanliness)
	if restoredCleanliness ~= nil then
		newObject:SetAttribute("Cleanliness", math.clamp(restoredCleanliness, 0, 100))
	end
	local restoredDirtiness = tonumber(data.Dirtiness)
	if restoredDirtiness ~= nil then
		newObject:SetAttribute("Dirtiness", math.clamp(restoredDirtiness, 0, 100))
	end
	if data.NeedsCleaning ~= nil then
		newObject:SetAttribute("NeedsCleaning", data.NeedsCleaning == true)
	end
	if data.HasJanitor ~= nil then
		newObject:SetAttribute("HasJanitor", data.HasJanitor == true)
	end
	local restoredJanitorLevel = tonumber(data.JanitorLevel)
	if restoredJanitorLevel ~= nil then
		newObject:SetAttribute("JanitorLevel", math.max(0, restoredJanitorLevel))
	end
	if data.JanitorCoverage ~= nil then
		newObject:SetAttribute("JanitorCoverage", data.JanitorCoverage == true)
	end
	local restoredCleanAreaTraffic = tonumber(data.CleanAreaTraffic)
	if restoredCleanAreaTraffic ~= nil then
		newObject:SetAttribute("CleanAreaTraffic", math.max(0, restoredCleanAreaTraffic))
	end
	local paid = tonumber(data.Price)
	if not paid then paid = Config.GetPlacementCost(data.Item) end
	if paid then newObject:SetAttribute("PaidPrice", paid) end
	local ptime = tonumber(data.PlacementTime)
	if not ptime then ptime = os.time() end
	newObject:SetAttribute("PlacementTime", ptime)
	local restoredItemId = Config.GetSaveId(data.Item, itemConfig) or itemConfig.ID
	if restoredItemId then newObject:SetAttribute("ID", tostring(restoredItemId)) end
	newObject.Parent = placedFolder
end)

RequestPlaceItem.OnServerInvoke = PlaceItem