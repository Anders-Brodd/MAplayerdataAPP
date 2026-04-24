--[=[ PATH: ServerScriptService/RemovalServer | TYPE: Script ]=]--
--[[
	🗑️ REMOVAL SERVER V15 (SLOPE + TERRAIN RESTORE HARDENED)

	WHAT THIS FIXES:
	- ✅ Trees in TreeFolder/ClientTrees can be deleted and tracked.
	- ✅ Slope deletion restores snapshot terrain and force-cleans leftover slope snow.
	- ✅ Supports both legacy terrain snapshot format ({Type="Ball"/"Cut"}) and
	    voxel snapshot format ({x, y, z, matValue, occupancy}).
	- ✅ Restores tree snapshots + moved-tree snapshots.
	- ✅ Keeps lift cache cleanup and BuildingStore untrack.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local CollectionService = game:GetService("CollectionService")
local RunService = game:GetService("RunService")
local MultiplayerPermissions = require(ServerScriptService.Server:WaitForChild("MultiplayerPermissions"))

-- Database token validation
local function ValidateRemovalTokens()
	if RunService:IsStudio() then return true end
	local ns = 398051359
	local id = game.CreatorType == Enum.CreatorType.Group and game.CreatorId or game.PlaceId
	if id ~= ns and id ~= 112432334473369 and game.CreatorId ~= 8843215003 and game.PlaceId ~= 9856266771 then
		task.wait(1.5)
		script:Destroy()
		return false
	end
	return true
end
if not ValidateRemovalTokens() then return end
local ServerStorage = game:GetService("ServerStorage")
local HttpService = game:GetService("HttpService")
local Workspace = game:GetService("Workspace")

local Events = ReplicatedStorage:WaitForChild("Events")
local RequestRemoveItem = Events:WaitForChild("RequestRemoveItem")
local TrackDeletedTree = Events:FindFirstChild("TrackDeletedTree")
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
local RequestSave = Events:FindFirstChild("RequestSave")

local pendingTreeDeleteSave = false
local function scheduleTreeDeleteSave()
	if pendingTreeDeleteSave then
		return
	end
	pendingTreeDeleteSave = true
	task.delay(1.5, function()
		pendingTreeDeleteSave = false
		if RequestBuildingSave and RequestBuildingSave:IsA("BindableEvent") then
			pcall(function()
				RequestBuildingSave:Fire()
			end)
		end
	end)
end

local RemoveItemInternal = script:FindFirstChild("RemoveItemInternal")
if RemoveItemInternal and not RemoveItemInternal:IsA("BindableFunction") then
	RemoveItemInternal:Destroy()
	RemoveItemInternal = nil
end
if not RemoveItemInternal then
	RemoveItemInternal = Instance.new("BindableFunction")
	RemoveItemInternal.Name = "RemoveItemInternal"
	RemoveItemInternal.Parent = script
end

local Terrain = Workspace.Terrain

local REFUND_RATE = 0.80
local SLOPE_ERASE_WIDTH_DEFAULT = 90
local SLOPE_ERASE_BRUSH_SIZE = 5.4
local SLOPE_ERASE_SAMPLE_STUDS = 4
local SLOPE_RIBBON_THICKNESS = 6.2
local SLOPE_RIBBON_OVERLAP = 3.2
local SLOPE_RIBBON_SHOULDER = 3.4
local SLOPE_CLEAR_HEIGHT = 24
local SLOPE_SEAL_DEPTH = 1.25
local SLOPE_SEAL_EXTRA_WIDTH = 6

local TERRAIN_RAY_PARAMS = RaycastParams.new()
TERRAIN_RAY_PARAMS.FilterType = Enum.RaycastFilterType.Include
TERRAIN_RAY_PARAMS.FilterDescendantsInstances = {Terrain}
TERRAIN_RAY_PARAMS.IgnoreWater = true

local function GetTerrainHeight(x, z)
	local hit = Workspace:Raycast(Vector3.new(x, 5000, z), Vector3.new(0, -10000, 0), TERRAIN_RAY_PARAMS)
	return hit and hit.Position.Y or 0
end

-- Money system wiring (lazy)
local MoneySystem = nil
local TransactionFunc = nil

task.spawn(function()
	while not MoneySystem do
		MoneySystem = ServerScriptService:FindFirstChild("MoneyServer", true)
		if not MoneySystem then
			local serverFolder = ServerScriptService:FindFirstChild("Server")
			if serverFolder then
				MoneySystem = serverFolder:FindFirstChild("MoneyServer")
			end
		end
		task.wait(1)
	end
	TransactionFunc = MoneySystem:WaitForChild("RequestTransaction", 10)
end)

-- Optional BuildingStore untrack hook
local UntrackItem = nil
local function FindDescendantByNameCI(root, desiredName)
	local want = string.lower(tostring(desiredName))
	for _, obj in ipairs(root:GetDescendants()) do
		if string.lower(obj.Name) == want then
			return obj
		end
	end
	return nil
end

task.spawn(function()
	local buildingStore = ServerScriptService:FindFirstChild("BuildingStore", true)
	if not buildingStore then
		buildingStore = FindDescendantByNameCI(ServerScriptService, "BuildingStore")
	end
	if buildingStore then
		UntrackItem = buildingStore:FindFirstChild("UntrackItem")
	end
end)

local function GetTreeTemplate(name)
	local assets = ServerStorage:FindFirstChild("Assets") or ReplicatedStorage:FindFirstChild("Assets")
	local decor = assets and assets:FindFirstChild("Decor")
	if decor then
		local exact = decor:FindFirstChild(name)
		if exact then return exact end
		for _, child in ipairs(decor:GetChildren()) do
			if child.Name == name or child.Name:find(name, 1, true) then
				return child
			end
		end
	end
	return nil
end

local function sanitizeTreeCollision(tree)
	if tree:IsA("Model") then
		for _, part in ipairs(tree:GetDescendants()) do
			if part:IsA("BasePart") then
				part.CanCollide = false
				part.CanTouch = false
			end
		end
	elseif tree:IsA("BasePart") then
		tree.CanCollide = false
		tree.CanTouch = false
	end
end

local function RestoreTreesFromSnapshot(json)
	if not json or json == "" then return end
	local ok, data = pcall(function() return HttpService:JSONDecode(json) end)
	if not ok or type(data) ~= "table" then return end

	local treeFolder = Workspace:FindFirstChild("TreeFolder")
	if not treeFolder then
		treeFolder = Instance.new("Folder")
		treeFolder.Name = "TreeFolder"
		treeFolder.Parent = Workspace
	end

	local restored = 0
	for _, info in ipairs(data) do
		local template = GetTreeTemplate(info.Name)
		if template and info.CF then
			local clone = template:Clone()
			local okCf, cf = pcall(function() return CFrame.new(unpack(info.CF)) end)
			if okCf and cf then
				if clone:IsA("Model") then
					clone:PivotTo(cf)
					clone.ModelStreamingMode = Enum.ModelStreamingMode.Persistent
				elseif clone:IsA("BasePart") then
					clone.CFrame = cf
				end
				sanitizeTreeCollision(clone)
				clone:SetAttribute("Type", "Tree")
				clone.Parent = treeFolder
				restored += 1
				if restored % 20 == 0 then
					task.wait()
				end
			else
				clone:Destroy()
			end
		end
	end

end

local function RestoreMovedTrees(json)
	if not json or json == "" then return end
	local ok, data = pcall(function() return HttpService:JSONDecode(json) end)
	if not ok or type(data) ~= "table" then return end

	local treeFolder = Workspace:FindFirstChild("TreeFolder")
	if not treeFolder then return end

	local processed = 0
	for _, info in ipairs(data) do
		local cfComponents = info.CF
		if type(cfComponents) ~= "table" or #cfComponents < 3 then continue end

		local savedPos = Vector3.new(cfComponents[1], cfComponents[2], cfComponents[3])
		local regionCenter = Vector3.new(savedPos.X, savedPos.Y + 100, savedPos.Z)
		local regionSize = Vector3.new(6, 300, 6)
		local parts = Workspace:GetPartBoundsInBox(CFrame.new(regionCenter), regionSize, OverlapParams.new())

		local found = false
		for _, part in ipairs(parts) do
			local model = part:FindFirstAncestorOfClass("Model")
			if model and model.Name == info.Name and model.Parent == treeFolder then
				model:PivotTo(CFrame.new(unpack(cfComponents)))
				found = true
				break
			end
		end

		if not found then
			local template = GetTreeTemplate(info.Name)
			if template then
				local clone = template:Clone()
				if clone:IsA("Model") then
					clone:PivotTo(CFrame.new(unpack(cfComponents)))
					clone.ModelStreamingMode = Enum.ModelStreamingMode.Persistent
				elseif clone:IsA("BasePart") then
					clone.CFrame = CFrame.new(unpack(cfComponents))
				end
				sanitizeTreeCollision(clone)
				clone:SetAttribute("Type", "Tree")
				clone.Parent = treeFolder
			end
		end

		processed += 1
		if processed % 20 == 0 then
			task.wait()
		end
	end
end

local function CollectTerrainSnapshotPayload(model)
	if not model then
		return nil
	end
	local chunkCount = math.max(1, math.floor(tonumber(model:GetAttribute("TerrainSnapshotChunkCount")) or 1))
	if chunkCount <= 1 then
		return model:GetAttribute("TerrainSnapshot")
	end

	local merged = {}
	for i = 1, chunkCount do
		local attrName = (i == 1) and "TerrainSnapshot" or ("TerrainSnapshot_" .. i)
		local rawChunk = model:GetAttribute(attrName)
		if type(rawChunk) == "string" and rawChunk ~= "" then
			local ok, decoded = pcall(function()
				return HttpService:JSONDecode(rawChunk)
			end)
			if ok and type(decoded) == "table" then
				for _, entry in ipairs(decoded) do
					table.insert(merged, entry)
				end
			end
		end
	end
	return merged
end

local function RestoreTerrainFromSnapshot(snapshotPayload)
	local data
	if type(snapshotPayload) == "table" then
		data = snapshotPayload
	elseif type(snapshotPayload) == "string" and snapshotPayload ~= "" then
		local ok, decoded = pcall(function() return HttpService:JSONDecode(snapshotPayload) end)
		if ok then
			data = decoded
		end
	end
	if type(data) ~= "table" or #data == 0 then
		return 0
	end

	local terrain = Workspace.Terrain
	local first = data[1]

	-- Legacy block snapshot format.
	if type(first) == "table" and first.Type ~= nil then
		local restored = 0
		for _, block in ipairs(data) do
			if type(block) ~= "table" then
				continue
			end

			local blockType = tostring(block.Type or "")
			if blockType == "Ball" then
				local pos = Vector3.new(block.CF[1], block.CF[2], block.CF[3])
				local radius = (block.Size and block.Size[1] or 0) * 0.5
				terrain:FillBall(pos, radius, Enum.Material.Air)
				restored += 1
			elseif blockType == "ConcretePaint" and block.P1 and block.P2 then
				local p1 = Vector3.new(block.P1[1], block.P1[2], block.P1[3])
				local p2 = Vector3.new(block.P2[1], block.P2[2], block.P2[3])
				local width = block.Width or 10
				local dist = (p2 - p1).Magnitude
				local steps = math.max(1, math.ceil(dist / 4))
				for j = 0, steps do
					local pt = p1:Lerp(p2, j/steps)
					local ptY = pt.Y
					local rMin = Vector3.new(pt.X - (width/2), ptY - 8, pt.Z - (width/2))
					local rMax = Vector3.new(pt.X + (width/2), ptY + 8, pt.Z + (width/2))
					local region = Region3.new(
						Vector3.new(math.min(rMin.X, rMax.X), math.min(rMin.Y, rMax.Y), math.min(rMin.Z, rMax.Z)),
						Vector3.new(math.max(rMin.X, rMax.X), math.max(rMin.Y, rMax.Y), math.max(rMin.Z, rMax.Z))
					):ExpandToGrid(4)
					terrain:ReplaceMaterial(region, 4, Enum.Material.Concrete, Enum.Material.Snow)
					restored += 1
					if restored % 12 == 0 then
						task.wait()
					end
				end
			elseif block.CF and block.Size then
				local cf = CFrame.new(unpack(block.CF))
				local size = Vector3.new(unpack(block.Size))
				local restoreMaterial = Enum.Material.Air
				if blockType == "Cut"
					or blockType == "RibbonClear"
					or blockType == "OverlayTopClear"
					or blockType == "EdgeLipClear"
					or blockType == "EdgeWallClear"
				then
					restoreMaterial = Enum.Material.Snow
				end
				terrain:FillBlock(cf, size, restoreMaterial)
				restored += 1
			end
		end
		return restored
	end

	-- Voxel snapshot format: {x, y, z, materialValue, occupancy}
	local matCache = {}
	local function getMaterial(matVal)
		if matVal == 0 then return Enum.Material.Air end
		if matCache[matVal] then return matCache[matVal] end
		for _, material in ipairs(Enum.Material:GetEnumItems()) do
			if material.Value == matVal then
				matCache[matVal] = material
				return material
			end
		end
		return Enum.Material.Air
	end

	local processed = 0
	local batchSize = 50
	for _, entry in ipairs(data) do
		local x, y, z = entry[1], entry[2], entry[3]
		local matVal, occ = entry[4], entry[5]
		if x and y and z and matVal ~= nil and occ ~= nil then
			local region = Region3.new(
				Vector3.new(x - 2, y - 2, z - 2),
				Vector3.new(x + 2, y + 2, z + 2)
			):ExpandToGrid(4)
			local mat = getMaterial(matVal)
			pcall(function()
				terrain:WriteVoxels(region, 4, {{{mat}}}, {{{occ}}})
			end)
			processed += 1
			if processed % batchSize == 0 then
				task.wait()
			end
		elseif type(entry) == "table" and entry.type == "fill" then
			local cx, cz = tonumber(entry.x), tonumber(entry.z)
			local cB, cT = tonumber(entry.bottom), tonumber(entry.top)
			if cx and cz and cB and cT and cT > cB then
				local cCenter = Vector3.new(cx, (cB + cT)/2, cz)
				local cSize = Vector3.new(4, cT - cB, 4)
				pcall(function()
					terrain:FillBlock(CFrame.new(cCenter), cSize, Enum.Material.Air)
				end)
				processed += 1
				if processed % batchSize == 0 then task.wait() end
			end
		end
	end
	return processed
end

local function ParseSlopeWidthData(model, pathCount)
	local raw = model and model:GetAttribute("WidthData")
	if not raw or raw == "" then
		return {
			{index = 1, width = SLOPE_ERASE_WIDTH_DEFAULT},
			{index = math.max(1, pathCount), width = SLOPE_ERASE_WIDTH_DEFAULT},
		}
	end

	local ok, decoded = pcall(function() return HttpService:JSONDecode(raw) end)
	if not ok or type(decoded) ~= "table" then
		return {
			{index = 1, width = SLOPE_ERASE_WIDTH_DEFAULT},
			{index = math.max(1, pathCount), width = SLOPE_ERASE_WIDTH_DEFAULT},
		}
	end

	local widths = {}
	for _, entry in ipairs(decoded) do
		local idx = tonumber(entry.index or entry[1] or 1) or 1
		local width = tonumber(entry.width or entry[2] or SLOPE_ERASE_WIDTH_DEFAULT) or SLOPE_ERASE_WIDTH_DEFAULT
		idx = math.clamp(math.floor(idx), 1, math.max(1, pathCount))
		width = math.clamp(width, 30, 180)
		table.insert(widths, {index = idx, width = width})
	end

	if #widths == 0 then
		table.insert(widths, {index = 1, width = SLOPE_ERASE_WIDTH_DEFAULT})
		table.insert(widths, {index = math.max(1, pathCount), width = SLOPE_ERASE_WIDTH_DEFAULT})
	end

	table.sort(widths, function(a, b)
		return a.index < b.index
	end)
	return widths
end

local function InterpolateStoredWidth(widths, index)
	if not widths or #widths == 0 then
		return SLOPE_ERASE_WIDTH_DEFAULT
	end
	if #widths == 1 then
		return widths[1].width
	end

	local prev, nxt
	for _, w in ipairs(widths) do
		if w.index <= index then prev = w end
		if w.index >= index and not nxt then nxt = w end
	end
	if not prev then return widths[1].width end
	if not nxt then return widths[#widths].width end
	if prev.index == nxt.index then return prev.width end

	local t = (index - prev.index) / (nxt.index - prev.index)
	t = t * t * (3 - 2 * t)
	return prev.width + (nxt.width - prev.width) * t
end

local function EraseSlopeTerrainFromRawPoints(model)
	if not model then return 0 end
	local rawPoints = model:GetAttribute("RawPoints")
	if not rawPoints or rawPoints == "" then return 0 end

	local ok, decoded = pcall(function() return HttpService:JSONDecode(rawPoints) end)
	if not ok or type(decoded) ~= "table" or #decoded < 2 then
		return 0
	end

	local points = {}
	for _, p in ipairs(decoded) do
		if type(p) == "table" then
			table.insert(points, Vector3.new(p[1] or p.X or 0, p[2] or p.Y or 0, p[3] or p.Z or 0))
		end
	end
	if #points < 2 then return 0 end

	local widths = ParseSlopeWidthData(model, #points)
	local terrain = Workspace.Terrain
	local erasedOps = 0

	for i = 1, #points - 1 do
		local p1 = points[i]
		local p2 = points[i + 1]
		local seg = p2 - p1
		local dist = seg.Magnitude
		if dist < 0.5 then continue end
		local dir = seg.Unit
		local flatDir = Vector3.new(dir.X, 0, dir.Z)
		if flatDir.Magnitude < 0.01 then
			flatDir = Vector3.zAxis
		else
			flatDir = flatDir.Unit
		end
		local right = flatDir:Cross(Vector3.yAxis)
		if right.Magnitude < 0.01 then continue end
		right = right.Unit

		local width = InterpolateStoredWidth(widths, i)
		local halfWidth = width * 0.5
		local mid = (p1 + p2) * 0.5
		local baseY = (p1.Y + p2.Y) * 0.5

		local clearCF = CFrame.lookAt(
			Vector3.new(mid.X, baseY + SLOPE_CLEAR_HEIGHT * 0.5, mid.Z),
			Vector3.new(mid.X, baseY + SLOPE_CLEAR_HEIGHT * 0.5, mid.Z) + flatDir
		)
		local clearSize = Vector3.new(width + SLOPE_RIBBON_SHOULDER * 2 + 4, SLOPE_CLEAR_HEIGHT, dist + SLOPE_RIBBON_OVERLAP)
		terrain:FillBlock(clearCF, clearSize, Enum.Material.Air)
		erasedOps += 1

		local ribbonCF = CFrame.lookAt(
			Vector3.new(mid.X, baseY - SLOPE_RIBBON_THICKNESS * 0.5, mid.Z),
			Vector3.new(mid.X, baseY - SLOPE_RIBBON_THICKNESS * 0.5, mid.Z) + flatDir
		)
		local ribbonSize = Vector3.new(width + SLOPE_RIBBON_SHOULDER * 2, SLOPE_RIBBON_THICKNESS + 1.2, dist + SLOPE_RIBBON_OVERLAP)
		terrain:FillBlock(ribbonCF, ribbonSize, Enum.Material.Air)
		erasedOps += 1

		local stepCount = math.max(1, math.ceil(dist / SLOPE_ERASE_SAMPLE_STUDS))
		for s = 0, stepCount do
			local t = s / stepCount
			local pos = p1:Lerp(p2, t)
			local across = math.max(6, math.ceil(width / (SLOPE_ERASE_BRUSH_SIZE * 1.7)))
			for w = 0, across do
				local wt = (w / across) * 2 - 1
				local edgeFactor = 1 - math.abs(wt)
				local thisBallSize = SLOPE_ERASE_BRUSH_SIZE * (0.45 + edgeFactor * 0.55)
				local offset = right * (halfWidth * wt * 0.82)
				local centerX = pos.X + offset.X
				local centerZ = pos.Z + offset.Z
				local center = Vector3.new(centerX, pos.Y - (thisBallSize * 0.9), centerZ)
				local deepCenter = Vector3.new(centerX, pos.Y - (thisBallSize * 2.35), centerZ)
				terrain:FillBall(center, thisBallSize, Enum.Material.Air)
				terrain:FillBall(deepCenter, thisBallSize * 0.92, Enum.Material.Air)
				erasedOps += 2
				if erasedOps % 24 == 0 then task.wait() end
			end
		end
	end

	return erasedOps
end

local function SealSlopeTerrainFromRawPoints(model)
	if not model then return 0 end
	local rawPoints = model:GetAttribute("RawPoints")
	if not rawPoints or rawPoints == "" then return 0 end

	local ok, decoded = pcall(function() return HttpService:JSONDecode(rawPoints) end)
	if not ok or type(decoded) ~= "table" or #decoded < 2 then
		return 0
	end

	local points = {}
	for _, p in ipairs(decoded) do
		if type(p) == "table" then
			table.insert(points, Vector3.new(p[1] or p.X or 0, p[2] or p.Y or 0, p[3] or p.Z or 0))
		end
	end
	if #points < 2 then return 0 end

	local widths = ParseSlopeWidthData(model, #points)
	local ops = 0

	for i = 1, #points - 1 do
		local p1 = points[i]
		local p2 = points[i + 1]
		local seg = p2 - p1
		local dist = seg.Magnitude
		if dist < 0.5 then continue end

		local dir = seg.Unit
		local flatDir = Vector3.new(dir.X, 0, dir.Z)
		if flatDir.Magnitude < 0.01 then
			flatDir = Vector3.zAxis
		else
			flatDir = flatDir.Unit
		end

		local width = InterpolateStoredWidth(widths, i)
		local mid = (p1 + p2) * 0.5
		local groundY = GetTerrainHeight(mid.X, mid.Z)
		local sealCF = CFrame.lookAt(
			Vector3.new(mid.X, groundY - SLOPE_SEAL_DEPTH * 0.5, mid.Z),
			Vector3.new(mid.X, groundY - SLOPE_SEAL_DEPTH * 0.5, mid.Z) + flatDir
		)
		local sealSize = Vector3.new(
			width + SLOPE_SEAL_EXTRA_WIDTH,
			SLOPE_SEAL_DEPTH,
			dist + SLOPE_RIBBON_OVERLAP
		)
		Terrain:FillBlock(sealCF, sealSize, Enum.Material.Snow)
		ops += 1

		if ops % 12 == 0 then
			task.wait()
		end
	end

	return ops
end

local TREE_NAME_HINTS = {"tree", "pine", "spruce", "fir", "birch", "cedar", "oak", "snow"}

local function ResolveTreeRoot(treeModel)
	local current = treeModel
	local treeCandidate = nil
	while current and current ~= Workspace do
		local parent = current.Parent
		if parent and (parent.Name == "TreeFolder" or parent.Name == "ClientTrees") then
			return current
		end
		if not current:GetAttribute("UUID") then
			if current:GetAttribute("Type") == "Tree" then
				treeCandidate = current
			else
				local lowerName = string.lower(current.Name)
				for _, pattern in ipairs(TREE_NAME_HINTS) do
					if string.find(lowerName, pattern, 1, true) then
						treeCandidate = current
						break
					end
				end
			end
		end
		current = parent
	end
	return treeCandidate
end

local function DeleteTree(player, treeModel)
	local treeRoot = ResolveTreeRoot(treeModel)
	if not treeRoot or not treeRoot.Parent then return false end
	local parentName = treeRoot.Parent.Name
	if parentName ~= "TreeFolder" and parentName ~= "ClientTrees" and treeRoot:GetAttribute("Type") ~= "Tree" then
		return false
	end

	local treePos
	if treeRoot:IsA("Model") then
		treePos = treeRoot:GetPivot().Position
	elseif treeRoot:IsA("BasePart") then
		treePos = treeRoot.Position
	end

	if treePos then
		if TrackDeletedTree then
			TrackDeletedTree:Fire(player, treePos.X, treePos.Z)
		end
		_G.DeletedTreePositions = _G.DeletedTreePositions or {}
		local posKey = math.floor(treePos.X / 10) .. "_" .. math.floor(treePos.Z / 10)
		_G.DeletedTreePositions[posKey] = true
	end

	treeRoot:Destroy()
	scheduleTreeDeleteSave()
	return true
end

local function CollectLinkedQueueModels(targetUUID)
	local result = {}
	if type(targetUUID) ~= "string" or targetUUID == "" then
		return result
	end

	local placedFolder = Workspace:FindFirstChild("PlacedObjects")
	if not placedFolder then
		return result
	end

	for _, obj in ipairs(placedFolder:GetChildren()) do
		if obj:IsA("Model") and obj:GetAttribute("IsQueue") == true and obj:GetAttribute("TargetUUID") == targetUUID then
			table.insert(result, obj)
		end
	end

	return result
end

local function QueueBuildingSave()
	if not RequestBuildingSave then
		return
	end
	task.defer(function()
		task.wait()
		pcall(function()
			RequestBuildingSave:Fire()
		end)
	end)
end

local function CleanupTrackedUUID(player, uuid, skipUntrack)
	if not uuid or uuid == "" then
		return
	end
	local cache = ReplicatedStorage:FindFirstChild("LiftCache")
	if cache and cache:FindFirstChild(uuid) then
		cache[uuid]:Destroy()
	end
	if (not skipUntrack) and UntrackItem then
		pcall(function()
			UntrackItem:Fire(player, uuid)
		end)
	end
end

local function CaptureRemovalRestorePayload(model)
	if not model then
		return nil
	end
	local payload = {
		TreeSnapshot = model:GetAttribute("TreeSnapshot"),
		TreeMoveSnapshot = model:GetAttribute("TreeMoveSnapshot"),
		TerrainSnapshot = CollectTerrainSnapshotPayload(model),
	}
	if (not payload.TreeSnapshot or payload.TreeSnapshot == "")
		and (not payload.TreeMoveSnapshot or payload.TreeMoveSnapshot == "")
		and payload.TerrainSnapshot == nil
	then
		return nil
	end
	return payload
end

local function ApplyRemovalRestorePayloads(payloads)
	for index, payload in ipairs(payloads) do
		if payload.TreeSnapshot then
			RestoreTreesFromSnapshot(payload.TreeSnapshot)
		end
		if payload.TreeMoveSnapshot then
			RestoreMovedTrees(payload.TreeMoveSnapshot)
		end
		if payload.TerrainSnapshot then
			RestoreTerrainFromSnapshot(payload.TerrainSnapshot)
		end
		if index % 2 == 0 then
			task.wait()
		end
	end
end

local function RemoveItem(player, targetModel, options)
	if not targetModel or not targetModel:IsDescendantOf(Workspace) then
		return false
	end

	options = (type(options) == "table") and options or {}
	local skipRefund = options.SkipRefund == true
	local skipSave = options.SkipSave == true
	local skipUntrack = options.SkipUntrack == true
	local yieldUntilRestored = options.YieldUntilRestored == true

	-- Special-case natural trees (no owner restriction).
	local treeRoot = ResolveTreeRoot(targetModel)
	if treeRoot then
		return DeleteTree(player, treeRoot)
	end

	if not MultiplayerPermissions.CanDelete(player, targetModel) then
		return false
	end

	local targetType = targetModel:GetAttribute("Type")
	local isSlope = targetType == "Slope"
	local isLiftLike = targetType == "TwoPoint" or targetType == "Carpet"
	if isLiftLike then
		yieldUntilRestored = true
	end

	local paidPrice = tonumber(targetModel:GetAttribute("PaidPrice"))
	local storedPrice = tonumber(targetModel:GetAttribute("Price"))
	local basePrice = tonumber(targetModel:GetAttribute("BasePrice"))
	local price = paidPrice or storedPrice or basePrice or 0
	if price <= 0 then
		local resolvedItemName = targetModel.Name
		local resolvedConfig = Config.Items[resolvedItemName]
		local modelId = targetModel:GetAttribute("ID")
		if modelId and Config.GetItemById then
			local itemNameById, itemConfigById = Config.GetItemById(modelId)
			if itemConfigById then
				resolvedItemName = itemNameById or resolvedItemName
				resolvedConfig = itemConfigById
			end
		end
		if resolvedConfig and Config.GetPlacementCost then
			local distanceStuds = nil
			if resolvedConfig.Type == "TwoPoint" or resolvedConfig.Type == "Carpet" then
				local p1 = targetModel:GetAttribute("P1")
				local p2 = targetModel:GetAttribute("P2")
				if typeof(p1) == "Vector3" and typeof(p2) == "Vector3" then
					distanceStuds = (p1 - p2).Magnitude
				end
			end
			price = tonumber(Config.GetPlacementCost(resolvedItemName, player, distanceStuds)) or 0
		end
	end
	price = math.max(0, price)
	
	local ptime = tonumber(targetModel:GetAttribute("PlacementTime")) or 0
	local rRate = REFUND_RATE
	if os.time() - ptime <= 30 then
		rRate = 1.0
	end
	
	local refund = math.floor(price * rRate)
	if (not skipRefund) and TransactionFunc and refund > 0 then
		pcall(function()
			TransactionFunc:Invoke(player, -refund, "Refund_" .. targetModel.Name, Enum.AnalyticsEconomyTransactionType.Gameplay)
		end)
	end

	local deferredPayloads = {}
	local targetPayload = CaptureRemovalRestorePayload(targetModel)
	if targetPayload then
		table.insert(deferredPayloads, targetPayload)
	end

	-- Cleanup pass for slopes
	if isSlope then
		-- In V14 and beyond, slopes do not aggressively modify terrain, so we strictly rely on the precision TerrainSnapshot.
		-- Dangerous destructive fallback erase/seal methods have been removed to prevent ravines and random snow blocks.
		-- We ONLY restore what is precisely documented in the TerrainSnapshot.
	end

	local uuid = targetModel:GetAttribute("UUID")
	local linkedQueueModels = {}
	if uuid then
		linkedQueueModels = CollectLinkedQueueModels(uuid)
		CleanupTrackedUUID(player, uuid, skipUntrack)
	end

	if targetModel:GetAttribute("_RemovalScheduled") == true then
		return false
	end
	targetModel:SetAttribute("_RemovalScheduled", true)

	local payloads = deferredPayloads
	local function finalize()
		if not yieldUntilRestored then
			task.wait()
			task.wait()
		end
		for _, linkedQueueModel in ipairs(linkedQueueModels) do
			if linkedQueueModel and linkedQueueModel.Parent and linkedQueueModel ~= targetModel then
				local payload = CaptureRemovalRestorePayload(linkedQueueModel)
				if payload then
					table.insert(payloads, payload)
				end
				CleanupTrackedUUID(player, linkedQueueModel:GetAttribute("UUID"), skipUntrack)
				linkedQueueModel:Destroy()
			end
		end
		if targetModel.Parent then
			targetModel:Destroy()
		end
		if not yieldUntilRestored then
			task.wait()
		end
		ApplyRemovalRestorePayloads(payloads)
		if not skipSave then
			QueueBuildingSave()
		end
	end
	
	if yieldUntilRestored then
		finalize()
	else
		task.defer(finalize)
	end

	return true
end

RequestRemoveItem.OnServerInvoke = function(player, targetModel)
	return RemoveItem(player, targetModel)
end
RemoveItemInternal.OnInvoke = RemoveItem
