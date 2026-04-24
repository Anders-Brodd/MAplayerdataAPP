--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local Players = game:GetService("Players")
local Terrain = Workspace.Terrain

local Events = ReplicatedStorage:FindFirstChild("Events")
if not Events then
	Events = Instance.new("Folder")
	Events.Name = "Events"
	Events.Parent = ReplicatedStorage
end

local TerrainEvent = Events:FindFirstChild("TerrainEvent")
if not TerrainEvent then
	TerrainEvent = Instance.new("RemoteEvent")
	TerrainEvent.Name = "TerrainEvent"
	TerrainEvent.Parent = Events
end

local TerrainReady = Events:FindFirstChild("TerrainReady")
if TerrainReady and not TerrainReady:IsA("BindableEvent") then
	TerrainReady:Destroy()
	TerrainReady = nil
end
if TerrainReady then
	task.defer(function()
		TerrainReady:Fire()
	end)
end

local RestoreTerrain = script:FindFirstChild("RestoreTerrain")
if RestoreTerrain and not RestoreTerrain:IsA("BindableEvent") then
	RestoreTerrain:Destroy()
	RestoreTerrain = nil
end
if not RestoreTerrain then
	RestoreTerrain = Instance.new("BindableEvent")
	RestoreTerrain.Name = "RestoreTerrain"
	RestoreTerrain.Parent = script
end

local HISTORY = {} :: {[number]: {Undo: {any}, Redo: {any}}}
local MAX_HISTORY_STEPS = 15

local function getHistory(player)
	local bucket = HISTORY[player.UserId]
	if not bucket then
		bucket = {Undo = {}, Redo = {}}
		HISTORY[player.UserId] = bucket
	end
	return bucket
end

local function getBrushRadius(size)
	return math.max(2, (tonumber(size) or 4) * 0.5)
end

local function getRegionForBrush(pos, size)
	local radius = getBrushRadius(size)
	local padding = 4
	local halfSize = Vector3.new(radius + padding, radius + padding, radius + padding)
	local min = pos - halfSize
	local max = pos + halfSize
	local minV = Vector3int16.new(math.floor(min.X / 4), math.floor(min.Y / 4), math.floor(min.Z / 4))
	local maxV = Vector3int16.new(math.ceil(max.X / 4), math.ceil(max.Y / 4), math.ceil(max.Z / 4))
	return Region3int16.new(minV, maxV)
end

local function regionIntToRegion3(regionInt)
	local minV, maxV = regionInt.Min, regionInt.Max
	return Region3.new(
		Vector3.new(minV.X * 4, minV.Y * 4, minV.Z * 4),
		Vector3.new(maxV.X * 4, maxV.Y * 4, maxV.Z * 4)
	)
end

local function getBrushNormal(normal)
	if typeof(normal) == "Vector3" and normal.Magnitude > 0.001 then
		return normal.Unit
	end
	return Vector3.new(0, 1, 0)
end

local function getVoxelCenter(regionInt, x, y, z)
	local minV = regionInt.Min
	return Vector3.new(
		(minV.X + x - 0.5) * 4,
		(minV.Y + y - 0.5) * 4,
		(minV.Z + z - 0.5) * 4
	)
end

local function getDistanceStrengthSphere(voxelPos, centerPos, radius)
	local dist = (voxelPos - centerPos).Magnitude
	if dist >= radius then
		return 0
	end
	local x = 1 - (dist / radius)
	return x * x * (3 - 2 * x)
end

local function getDistanceStrengthCylinder(voxelPos, centerPos, radius)
	local dx = voxelPos.X - centerPos.X
	local dz = voxelPos.Z - centerPos.Z
	local dist = math.sqrt((dx * dx) + (dz * dz))
	if dist >= radius then
		return 0
	end
	local x = 1 - (dist / radius)
	return x * x * (3 - 2 * x)
end

local function convertMaterial(value)
	if typeof(value) == "EnumItem" and value.EnumType == Enum.Material then
		return value
	end
	if type(value) == "number" then
		for _, item in ipairs(Enum.Material:GetEnumItems()) do
			if item.Value == value then
				return item
			end
		end
	end
	return Enum.Material.Snow
end

local function ApplyModification(player, tool, pos, size, material, normal)
	if type(tool) ~= "string" or typeof(pos) ~= "Vector3" then
		return false, 0, 0
	end

	size = math.clamp(tonumber(size) or 4, 4, 60)
	local regionInt = getRegionForBrush(pos, size)
	local region3 = regionIntToRegion3(regionInt)
	local radius = getBrushRadius(size)
	local brushNormal = getBrushNormal(normal)
	local fillMaterial = convertMaterial(material)

	local ok, materials, occupancies = pcall(function()
		return Terrain:ReadVoxels(region3, 4)
	end)
	if not ok then
		warn("[TerrainServer] ReadVoxels failed: " .. tostring(materials))
		return false, 0, 0
	end

	local sizeX, sizeY, sizeZ = materials.Size.X, materials.Size.Y, materials.Size.Z
	local changed = false
	local changedCells = 0
	local changeAmount = 0

	if tool == "Raise" or tool == "Lower" then
		local isGrow = (tool == "Raise")
		local offsetDist = isGrow and (radius * 0.2) or (radius * 0.1)
		local centerPos = pos + (brushNormal * (isGrow and offsetDist or -offsetDist))

		for x = 1, sizeX do
			for y = 1, sizeY do
				for z = 1, sizeZ do
					local voxelPos = getVoxelCenter(regionInt, x, y, z)
					local strength = getDistanceStrengthSphere(voxelPos, centerPos, radius)
					if strength > 0 then
						local currentOcc = occupancies[x][y][z]
						local delta = strength * 0.4
						local newOcc = math.clamp(currentOcc + (isGrow and delta or -delta), 0, 1)
						if math.abs(newOcc - currentOcc) > 0.01 then
							occupancies[x][y][z] = newOcc
							if newOcc > 0.05 and currentOcc <= 0.05 then
								materials[x][y][z] = fillMaterial
							elseif newOcc <= 0.05 then
								materials[x][y][z] = Enum.Material.Air
							end
							changed = true
							changedCells += 1
							changeAmount += math.abs(newOcc - currentOcc)
						end
					end
				end
			end
		end
	elseif tool == "Paint" then
		for x = 1, sizeX do
			for y = 1, sizeY do
				for z = 1, sizeZ do
					local voxelPos = getVoxelCenter(regionInt, x, y, z)
					if (voxelPos - pos).Magnitude <= (radius + 2)
						and occupancies[x][y][z] > 0.05
						and materials[x][y][z] ~= Enum.Material.Air
						and materials[x][y][z] ~= fillMaterial then
						materials[x][y][z] = fillMaterial
						changed = true
						changedCells += 1
						changeAmount += 1
					end
				end
			end
		end
	elseif tool == "Flatten" then
		local targetY = pos.Y
		for x = 1, sizeX do
			for y = 1, sizeY do
				for z = 1, sizeZ do
					local voxelPos = getVoxelCenter(regionInt, x, y, z)
					local strength = getDistanceStrengthCylinder(voxelPos, pos, radius)
					if strength > 0 then
						local bottomY = voxelPos.Y - 2
						local topY = voxelPos.Y + 2
						local idealOcc = 0
						if topY <= targetY then
							idealOcc = 1
						elseif bottomY >= targetY then
							idealOcc = 0
						else
							idealOcc = math.clamp((targetY - bottomY) / 4, 0, 1)
						end

						local currentOcc = occupancies[x][y][z]
						local coreStrength = math.clamp((strength - 0.2) / 0.8, 0, 1)
						local blendAlpha = 0.22 + (coreStrength * 0.78)
						local newOcc = currentOcc + ((idealOcc - currentOcc) * blendAlpha)
						if strength >= 0.9 then
							newOcc = idealOcc
						end

						if math.abs(newOcc - currentOcc) > 0.015 then
							occupancies[x][y][z] = newOcc
							if newOcc > 0.02 and (currentOcc <= 0.02 or materials[x][y][z] == Enum.Material.Air) then
								materials[x][y][z] = fillMaterial
							elseif newOcc <= 0.02 then
								materials[x][y][z] = Enum.Material.Air
							end
							changed = true
							changedCells += 1
							changeAmount += math.abs(newOcc - currentOcc)
						end
					end
				end
			end
		end
	elseif tool == "Smooth" then
		local sourceOcc = table.create(sizeX)
		for x = 1, sizeX do
			sourceOcc[x] = table.create(sizeY)
			for y = 1, sizeY do
				sourceOcc[x][y] = table.create(sizeZ)
				for z = 1, sizeZ do
					sourceOcc[x][y][z] = occupancies[x][y][z]
				end
			end
		end

		for x = 1, sizeX do
			for y = 1, sizeY do
				for z = 1, sizeZ do
					local voxelPos = getVoxelCenter(regionInt, x, y, z)
					local strength = getDistanceStrengthSphere(voxelPos, pos, radius)
					if strength > 0.05 then
						local sum = 0
						local count = 0
						for dx = -1, 1 do
							for dy = -1, 1 do
								for dz = -1, 1 do
									local nx, ny, nz = x + dx, y + dy, z + dz
									if nx >= 1 and nx <= sizeX and ny >= 1 and ny <= sizeY and nz >= 1 and nz <= sizeZ then
										sum += sourceOcc[nx][ny][nz]
										count += 1
									end
								end
							end
						end

						local avgOcc = count > 0 and (sum / count) or sourceOcc[x][y][z]
						local currentOcc = sourceOcc[x][y][z]
						local newOcc = currentOcc + (avgOcc - currentOcc) * strength * 0.6

						if math.abs(newOcc - currentOcc) > 0.02 then
							occupancies[x][y][z] = newOcc
							if newOcc <= 0.02 then
								materials[x][y][z] = Enum.Material.Air
							elseif materials[x][y][z] == Enum.Material.Air and newOcc > 0.02 then
								materials[x][y][z] = fillMaterial
							end
							changed = true
							changedCells += 1
							changeAmount += math.abs(newOcc - currentOcc)
						end
					end
				end
			end
		end
	end

	if changed then
		local writeOk, writeErr = pcall(function()
			Terrain:WriteVoxels(region3, 4, materials, occupancies)
		end)
		if not writeOk then
			warn("[TerrainServer] WriteVoxels failed: " .. tostring(writeErr))
			return false, 0, 0
		end
	end

	return changed, changedCells, changeAmount
end

local function pushUndo(player, region, snapshot, toolInfo)
	local history = getHistory(player)
	table.insert(history.Undo, {
		Region = region,
		Data = snapshot,
		ToolInfo = toolInfo,
	})
	if #history.Undo > MAX_HISTORY_STEPS then
		table.remove(history.Undo, 1)
	end
	history.Redo = {}
end

local function undoLast(player)
	local history = getHistory(player)
	local lastAction = table.remove(history.Undo)
	if not lastAction then
		return
	end
	local currentRegionData = Terrain:CopyRegion(lastAction.Region)
	table.insert(history.Redo, {
		Region = lastAction.Region,
		Data = currentRegionData,
		ToolInfo = lastAction.ToolInfo,
	})
	Terrain:PasteRegion(lastAction.Data, lastAction.Region.Min, true)
end

local function redoLast(player)
	local history = getHistory(player)
	local nextAction = table.remove(history.Redo)
	if not nextAction then
		return
	end
	local currentRegionData = Terrain:CopyRegion(nextAction.Region)
	table.insert(history.Undo, {
		Region = nextAction.Region,
		Data = currentRegionData,
		ToolInfo = nextAction.ToolInfo,
	})
	Terrain:PasteRegion(nextAction.Data, nextAction.Region.Min, true)
end

TerrainEvent.OnServerEvent:Connect(function(player, data)
	if type(data) ~= "table" then
		return
	end

	local action = data.Action
	if action == "Undo" then
		undoLast(player)
		return
	elseif action == "Redo" then
		redoLast(player)
		return
	end

	local tool = data.Tool
	local pos = data.Position
	local size = math.clamp(tonumber(data.Size) or 4, 4, 60)
	local mat = convertMaterial(data.Material)
	local normal = data.Normal

	if type(tool) ~= "string" or typeof(pos) ~= "Vector3" then
		return
	end

	if tool ~= "Raise" and tool ~= "Lower" and tool ~= "Flatten" and tool ~= "Smooth" and tool ~= "Paint" then
		return
	end

	local affectedRegion = getRegionForBrush(pos, size)
	local snapshotOk, snapshot = pcall(function()
		return Terrain:CopyRegion(affectedRegion)
	end)
	if not snapshotOk then
		warn("[TerrainServer] CopyRegion failed: " .. tostring(snapshot))
		return
	end

	local changed = ApplyModification(player, tool, pos, size, mat, normal)
	if not changed then
		return
	end

	pushUndo(player, affectedRegion, snapshot, {
		Tool = tool,
		Position = pos,
		Size = size,
		Material = mat,
	})
end)

RestoreTerrain.Event:Connect(function(player, data)
	if type(data) ~= "table" then
		return
	end
	local tool = data.Tool
	local pos = data.Position
	if type(tool) ~= "string" or typeof(pos) ~= "Vector3" then
		return
	end
	local size = math.clamp(tonumber(data.Size) or 4, 4, 60)
	ApplyModification(player, tool, pos, size, convertMaterial(data.Material), nil)
end)

Players.PlayerRemoving:Connect(function(player)
	HISTORY[player.UserId] = nil
end)
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local RunService = game:GetService("RunService")
local Lighting = game:GetService("Lighting")
local HttpService = game:GetService("HttpService")
local Workspace = game:GetService("Workspace")
local Terrain = workspace.Terrain

-- // INIT EVENT //
local Events = ReplicatedStorage:FindFirstChild("Events")
if not Events then
	Events = Instance.new("Folder", ReplicatedStorage)
	Events.Name = "Events"
end

local TerrainEvent = Events:FindFirstChild("TerrainEvent")
if not TerrainEvent then
	TerrainEvent = Instance.new("RemoteEvent", Events)
	TerrainEvent.Name = "TerrainEvent"
end

-- // RESTORE HOOK (For Loading) //
local RestoreTerrain = Instance.new("BindableEvent")
RestoreTerrain.Name = "RestoreTerrain"
RestoreTerrain.Parent = script

local function FindMoneyServer()
	local ms = ServerScriptService:FindFirstChild("MoneyServer", true)
	if ms then return ms end
	local sFolder = ServerScriptService:FindFirstChild("Server")
	if sFolder then return sFolder:FindFirstChild("MoneyServer") end
	return nil
end

local MoneySystem = nil
local TransactionFunc = nil

task.spawn(function()
	local startTime = tick()
	while not MoneySystem do 
		MoneySystem = FindMoneyServer()
		if tick() - startTime > 30 then break end
		task.wait(1) 
	end

	if MoneySystem then
		TransactionFunc = MoneySystem:WaitForChild("RequestTransaction", 30)
	end

end)

-- // SAVE SYSTEM LINKS //
local TerrainStore = script.Parent:WaitForChild("TerrainStore", 10)
if not TerrainStore then
	-- Try finding it in ServerScriptService if not sibling
	TerrainStore = ServerScriptService:FindFirstChild("TerrainStore", true)
end

local TrackAction = TerrainStore and TerrainStore:WaitForChild("TrackTerrainAction", 10)
local PopAction = TerrainStore and TerrainStore:WaitForChild("PopTerrainAction", 10)
local PushAction = TerrainStore and TerrainStore:WaitForChild("PushTerrainAction", 10)

-- // CONFIG //
local COSTS = { Raise = 15, Lower = 15, Flatten = 20, Paint = 5 }
local MIN_BRUSH_STRENGTH = 0.25
local MAX_BRUSH_STRENGTH = 2
local SURFACE_SAMPLE_RAY_HEIGHT = 256
local SURFACE_CHANGE_EPSILON = 0.15
local HISTORY = {} -- [UserId] = { Undo = {}, Redo = {} }
local RecentTerrainCharges = {}
local MAX_HISTORY_STEPS = 15

local function getBrushRadius(size)
	return math.max(2, (tonumber(size) or 4) * 0.5)
end

local function computeTerrainCharge(player, tool, pos, size, changedCells, changeAmount)
	local baseCost = COSTS[tool] or 10
	local radius = getBrushRadius(size)
	local areaFactor = math.clamp((math.pi * radius * radius) / 120, 0.75, 4)
	local changeFactor = math.max((changedCells or 0) * 0.3, (changeAmount or 0) * 1.6)
	local finalCost = math.max(1, math.floor(((changeFactor / 10) * areaFactor * (baseCost / 10)) + 0.5))

	local now = os.clock()
	local recent = RecentTerrainCharges[player.UserId]
	if recent
		and recent.Tool == tool
		and (now - recent.At) <= 0.35
		and (recent.Position - pos).Magnitude <= math.max(10, radius * 1.2) then
		finalCost = math.max(1, math.floor((finalCost * 0.4) + 0.5))
	end

	RecentTerrainCharges[player.UserId] = {
		Tool = tool,
		At = now,
		Position = pos,
	}

	return finalCost
end

-- // HELPER: Calculate Voxel Region //
local function getRegionForBrush(pos, size)
	local radius = getBrushRadius(size)
	local padding = 4
	local halfSize = Vector3.new(radius + padding, radius + padding, radius + padding)
	local min = pos - halfSize
	local max = pos + halfSize
	local minV = Vector3int16.new(math.floor(min.X/4), math.floor(min.Y/4), math.floor(min.Z/4))
	local maxV = Vector3int16.new(math.ceil(max.X/4), math.ceil(max.Y/4), math.ceil(max.Z/4))
	return Region3int16.new(minV, maxV)
end

local function regionIntToRegion3(regionInt)
	local minV, maxV = regionInt.Min, regionInt.Max
	return Region3.new(
		Vector3.new(minV.X * 4, minV.Y * 4, minV.Z * 4),
		Vector3.new(maxV.X * 4, maxV.Y * 4, maxV.Z * 4)
	)
end

local function getBrushNormal(normal)
	if typeof(normal) == "Vector3" and normal.Magnitude > 0.001 then
		return normal.Unit
	end
	return Vector3.new(0, 1, 0)
end

local function getVoxelCenter(regionInt, x, y, z)
	local minV = regionInt.Min
	return Vector3.new(
		(minV.X + x - 0.5) * 4,
		(minV.Y + y - 0.5) * 4,
		(minV.Z + z - 0.5) * 4
	)
end

local SURFACE_SAMPLE_RAY_PARAMS = RaycastParams.new()
SURFACE_SAMPLE_RAY_PARAMS.FilterType = Enum.RaycastFilterType.Include
SURFACE_SAMPLE_RAY_PARAMS.FilterDescendantsInstances = {Terrain}
SURFACE_SAMPLE_RAY_PARAMS.IgnoreWater = true

local function sampleBrushSurface(centerPos, size)
	local radius = getBrushRadius(size)
	local ringRadius = math.max(2, radius * 0.6)
	local sampleOffsets = {
		Vector3.zero,
		Vector3.new(ringRadius, 0, 0),
		Vector3.new(-ringRadius, 0, 0),
		Vector3.new(0, 0, ringRadius),
		Vector3.new(0, 0, -ringRadius),
		Vector3.new(ringRadius * 0.7, 0, ringRadius * 0.7),
		Vector3.new(-ringRadius * 0.7, 0, ringRadius * 0.7),
		Vector3.new(ringRadius * 0.7, 0, -ringRadius * 0.7),
		Vector3.new(-ringRadius * 0.7, 0, -ringRadius * 0.7),
	}

	local samples = table.create(#sampleOffsets)
	for index, offset in ipairs(sampleOffsets) do
		local samplePos = centerPos + offset
		local result = Workspace:Raycast(
			samplePos + Vector3.new(0, SURFACE_SAMPLE_RAY_HEIGHT, 0),
			Vector3.new(0, -(SURFACE_SAMPLE_RAY_HEIGHT * 2), 0),
			SURFACE_SAMPLE_RAY_PARAMS
		)
		samples[index] = result and {
			Y = result.Position.Y,
			Material = result.Material,
		} or {
			Y = nil,
			Material = nil,
		}
	end
	return samples
end

local function hasMeaningfulSurfaceChange(beforeSamples, afterSamples)
	if type(beforeSamples) ~= "table" or type(afterSamples) ~= "table" then
		return true
	end

	local count = math.min(#beforeSamples, #afterSamples)
	if count == 0 then
		return true
	end

	for index = 1, count do
		local before = beforeSamples[index]
		local after = afterSamples[index]
		local beforeY = before and before.Y or nil
		local afterY = after and after.Y or nil
		if beforeY == nil or afterY == nil then
			if beforeY ~= afterY then
				return true
			end
		elseif math.abs(afterY - beforeY) >= SURFACE_CHANGE_EPSILON then
			return true
		end

		local beforeMaterial = before and before.Material or nil
		local afterMaterial = after and after.Material or nil
		if beforeMaterial ~= afterMaterial and (beforeMaterial ~= nil or afterMaterial ~= nil) then
			return true
		end
	end

	return false
end

local function isWithinSphere(worldPos, centerPos, radius)
	return (worldPos - centerPos).Magnitude <= radius
end

local function isWithinDisc(worldPos, centerPos, radius)
	local dx = worldPos.X - centerPos.X
	local dz = worldPos.Z - centerPos.Z
	return (dx * dx) + (dz * dz) <= (radius * radius)
end

local function IsTerrainEditTooCloseToPlayer(player, worldPos, size, tool)
	if tool ~= "Raise" then
		return false
	end
	local character = player and player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not root then
		return false
	end
	local flatOffset = Vector3.new(worldPos.X - root.Position.X, 0, worldPos.Z - root.Position.Z).Magnitude
	local verticalOffset = math.abs(worldPos.Y - root.Position.Y)
	local flatLimit = math.max(2.75, (size * 0.18) + 1.5)
	local verticalLimit = math.max(5.5, (size * 0.18) + 4)
	return flatOffset <= flatLimit and verticalOffset <= verticalLimit
end

local function getDistanceStrengthSphere(voxelPos, centerPos, radius)
	local dist = (voxelPos - centerPos).Magnitude
	if dist >= radius then return 0 end
	local x = 1 - (dist / radius)
	return x * x * (3 - 2 * x) -- Smoothstep
end

local function getDistanceStrengthCylinder(voxelPos, centerPos, radius)
	local dx = voxelPos.X - centerPos.X
	local dz = voxelPos.Z - centerPos.Z
	local dist = math.sqrt((dx * dx) + (dz * dz))
	if dist >= radius then return 0 end
	local x = 1 - (dist / radius)
	return x * x * (3 - 2 * x) -- Smoothstep
end

-- // CORE MODIFICATION FUNCTION //
local function ApplyModification(player, tool, pos, size, material, normal, strength, options, snapshot, affectedRegion)
	options = options or {}
	local skipCharge = options.SkipCharge == true
	local skipPlayerGuard = options.SkipPlayerGuard == true
	local regionInt = getRegionForBrush(pos, size)
	local region3 = regionIntToRegion3(regionInt)
	local radius = getBrushRadius(size)
	local brushNormal = getBrushNormal(normal)
	local brushStrength = math.clamp(tonumber(strength) or 1, MIN_BRUSH_STRENGTH, MAX_BRUSH_STRENGTH)
	local fillMaterial = (tool == "Paint" and material) or Enum.Material.Snow

	local materials, occupancies = Terrain:ReadVoxels(region3, 4)
	local sizeX, sizeY, sizeZ = materials.Size.X, materials.Size.Y, materials.Size.Z
	local changed = false
	local changedCells = 0
	local changeAmount = 0

	if tool == "Raise" or tool == "Lower" then
		local isGrow = (tool == "Raise")
		-- Push the center of the brush outward or inward along the surface normal
		-- so it builds "out" from the slope instead of just making a ball in space.
		local offsetDist = isGrow and (radius * 0.2) or (radius * 0.1)
		local centerPos = pos + (brushNormal * (isGrow and offsetDist or -offsetDist))

		for x = 1, sizeX do
			for y = 1, sizeY do
				for z = 1, sizeZ do
					local voxelPos = getVoxelCenter(regionInt, x, y, z)
					local strength = getDistanceStrengthSphere(voxelPos, centerPos, radius)
					
					if strength > 0 then
						local currentOcc = occupancies[x][y][z]
						local delta = strength * (isGrow and 0.24 or 0.2) * brushStrength
						local newOcc = math.clamp(currentOcc + (isGrow and delta or -delta), 0, 1)

						if math.abs(newOcc - currentOcc) > 0.01 then
							occupancies[x][y][z] = newOcc
							if newOcc > 0.05 and currentOcc <= 0.05 then
								materials[x][y][z] = fillMaterial
							elseif newOcc <= 0.05 then
								materials[x][y][z] = Enum.Material.Air
							end
							changed = true
							changedCells += 1
							changeAmount += math.abs(newOcc - currentOcc)
						end
					end
				end
			end
		end
	elseif tool == "Paint" then
		for x = 1, sizeX do
			for y = 1, sizeY do
				for z = 1, sizeZ do
					local voxelPos = getVoxelCenter(regionInt, x, y, z)
					if isWithinSphere(voxelPos, pos, radius + 2)
						and occupancies[x][y][z] > 0.05
						and materials[x][y][z] ~= Enum.Material.Air
						and materials[x][y][z] ~= fillMaterial then
						materials[x][y][z] = fillMaterial
						changed = true
						changedCells += 1
						changeAmount += 1
					end
				end
			end
		end
	elseif tool == "Flatten" then
		local targetY = pos.Y
		for x = 1, sizeX do
			for y = 1, sizeY do
				for z = 1, sizeZ do
					local voxelPos = getVoxelCenter(regionInt, x, y, z)
					local strength = getDistanceStrengthCylinder(voxelPos, pos, radius)
					if strength > 0 then
						local bottomY = voxelPos.Y - 2
						local topY = voxelPos.Y + 2
						
						local idealOcc = 0
						if topY <= targetY then
							idealOcc = 1
						elseif bottomY >= targetY then
							idealOcc = 0
						else
							idealOcc = math.clamp((targetY - bottomY) / 4, 0, 1)
						end

						local currentOcc = occupancies[x][y][z]
						local coreStrength = math.clamp((strength - 0.2) / 0.8, 0, 1)
						local blendAlpha = math.clamp((0.22 + (coreStrength * 0.78)) * brushStrength, 0.05, 1)
						local newOcc = currentOcc + ((idealOcc - currentOcc) * blendAlpha)
						if strength >= 0.9 then
							newOcc = idealOcc
						end
						
						if math.abs(newOcc - currentOcc) > 0.015 then
							occupancies[x][y][z] = newOcc
							if newOcc > 0.02 and (currentOcc <= 0.02 or materials[x][y][z] == Enum.Material.Air) then
								materials[x][y][z] = fillMaterial
							elseif newOcc <= 0.02 then
								materials[x][y][z] = Enum.Material.Air
							end
							changed = true
							changedCells += 1
							changeAmount += math.abs(newOcc - currentOcc)
						end
					end
				end
			end
		end
	elseif tool == "Smooth" then
		local sourceOcc = table.create(sizeX)
		for x = 1, sizeX do
			sourceOcc[x] = table.create(sizeY)
			for y = 1, sizeY do
				sourceOcc[x][y] = table.create(sizeZ)
				for z = 1, sizeZ do
					sourceOcc[x][y][z] = occupancies[x][y][z]
				end
			end
		end

		for x = 1, sizeX do
			for y = 1, sizeY do
				for z = 1, sizeZ do
					local voxelPos = getVoxelCenter(regionInt, x, y, z)
					local strength = getDistanceStrengthSphere(voxelPos, pos, radius)
					if strength > 0.05 then
						local sum = 0
						local count = 0
						for dx = -1, 1 do
							for dy = -1, 1 do
								for dz = -1, 1 do
									local nx, ny, nz = x + dx, y + dy, z + dz
									if nx >= 1 and nx <= sizeX and ny >= 1 and ny <= sizeY and nz >= 1 and nz <= sizeZ then
										sum += sourceOcc[nx][ny][nz]
										count += 1
									end
								end
							end
						end

						local avgOcc = count > 0 and (sum / count) or sourceOcc[x][y][z]
						local currentOcc = sourceOcc[x][y][z]
						local smoothBlend = math.clamp(strength * 0.6 * brushStrength, 0, 1)
						local newOcc = currentOcc + (avgOcc - currentOcc) * smoothBlend

						if math.abs(newOcc - currentOcc) > 0.02 then
							occupancies[x][y][z] = newOcc
							if newOcc <= 0.02 then
								materials[x][y][z] = Enum.Material.Air
							elseif materials[x][y][z] == Enum.Material.Air and newOcc > 0.02 then
								materials[x][y][z] = fillMaterial
							end
							changed = true
							changedCells += 1
							changeAmount += math.abs(newOcc - currentOcc)
						end
					end
				end
			end
		end
	end

	if not skipCharge then
		local finalCost = computeTerrainCharge(player, tool, pos, size, changedCells, changeAmount)
		if TransactionFunc and not TransactionFunc:Invoke(player, finalCost, "Terrain_"..tool, Enum.AnalyticsEconomyTransactionType.Gameplay) then
			if snapshot and affectedRegion then
				Terrain:PasteRegion(snapshot, affectedRegion.Min, true)
			end
			return false, changedCells, changeAmount
		end
	end

	if changed then
		Terrain:WriteVoxels(region3, 4, materials, occupancies)
	end
	return changed, changedCells, changeAmount
end

-- // PLAYER EDIT HANDLER //
TerrainEvent.OnServerEvent:Connect(function(player, data)
	if not HISTORY[player.UserId] then HISTORY[player.UserId] = { Undo = {}, Redo = {} } end
	local session = HISTORY[player.UserId]

	-- A. UNDO
	if data.Action == "Undo" then
		local lastAction = table.remove(session.Undo)
		if lastAction then
			local currentRegionData = Terrain:CopyRegion(lastAction.Region)
			table.insert(session.Redo, { 
				Region = lastAction.Region, 
				Data = currentRegionData,
				ToolInfo = lastAction.ToolInfo 
			})

			Terrain:PasteRegion(lastAction.Data, lastAction.Region.Min, true)
			if PopAction then PopAction:Fire(player) end
		end
		return

			-- B. REDO
	elseif data.Action == "Redo" then
		local nextAction = table.remove(session.Redo)
		if nextAction then
			local currentRegionData = Terrain:CopyRegion(nextAction.Region)
			table.insert(session.Undo, { 
				Region = nextAction.Region, 
				Data = currentRegionData,
				ToolInfo = nextAction.ToolInfo
			})

			Terrain:PasteRegion(nextAction.Data, nextAction.Region.Min, true)
			if PushAction and nextAction.ToolInfo then
				PushAction:Fire(player, nextAction.ToolInfo)
			end
		end
		return
	else
		-- C. NEW TOOL ACTION
		local tool = data.Tool
		local pos = data.Position
		local size = math.clamp(data.Size or 4, 4, 60)
		local strength = math.clamp(tonumber(data.Strength) or 1, MIN_BRUSH_STRENGTH, MAX_BRUSH_STRENGTH)
		local mat = data.Material
		local normal = data.Normal

		if typeof(pos) ~= "Vector3" or IsTerrainEditTooCloseToPlayer(player, pos, size, tool) then
			return
		end

		if tool == "Paint" then
			local regionInt = getRegionForBrush(pos, size)
			local r3 = Region3.new(
				Vector3.new(regionInt.Min.X*4, regionInt.Min.Y*4, regionInt.Min.Z*4),
				Vector3.new(regionInt.Max.X*4, regionInt.Max.Y*4, regionInt.Max.Z*4)
			)
			local mats, occs = Terrain:ReadVoxels(r3, 4)
			local willChange = false
			for x = 1, mats.Size.X do
				for y = 1, mats.Size.Y do
					for z = 1, mats.Size.Z do
						if mats[x][y][z] ~= Enum.Material.Air and mats[x][y][z] ~= mat then
							willChange = true; break
						end
					end
					if willChange then break end
				end
				if willChange then break end
			end
			if not willChange then return end
		end

		local affectedRegion = getRegionForBrush(pos, size)
		local snapshot = Terrain:CopyRegion(affectedRegion)
		local beforeSurface = tool ~= "Paint" and sampleBrushSurface(pos, size) or nil
		local ok, changed, changedCells, changeAmount = pcall(ApplyModification, player, tool, pos, size, mat, normal, strength, nil, snapshot, affectedRegion)
		if not ok then
			warn("[TerrainServer] ApplyModification error: " .. tostring(changed))
			return
		end
		if not changed then
			return
		end

		if tool ~= "Paint" then
			local afterSurface = sampleBrushSurface(pos, size)
			if not hasMeaningfulSurfaceChange(beforeSurface, afterSurface) then
				Terrain:PasteRegion(snapshot, affectedRegion.Min, true)
				return
			end
		end


		local toolInfo = { Tool = tool, Position = pos, Size = size, Strength = strength, Material = mat, Normal = normal }

		table.insert(session.Undo, { 
			Region = affectedRegion, 
			Data = snapshot,
			ToolInfo = toolInfo
		})

		if #session.Undo > MAX_HISTORY_STEPS then table.remove(session.Undo, 1) end
		session.Redo = {} 
		if TrackAction then TrackAction:Fire(player, toolInfo) end
	end
end)

RestoreTerrain.Event:Connect(function(player, data)
	local mat = data.Material
	if type(mat) == "number" then
		local enums = Enum.Material:GetEnumItems()
		for _, e in pairs(enums) do if e.Value == mat then mat = e break end end
	end
	ApplyModification(player, data.Tool, data.Position, data.Size, mat, data.Normal, data.Strength, {
		SkipCharge = true,
		SkipPlayerGuard = true,
	}, nil, nil)
end)

game.Players.PlayerRemoving:Connect(function(player)
	HISTORY[player.UserId] = nil
	RecentTerrainCharges[player.UserId] = nil
end)



-- =========================================================================
-- 🌍 OPTIMIZED WEATHER SYSTEM V2 (Formerly TerrainController)
-- =========================================================================
-- PERFORMANCE OVERHAUL:
--   • BaseChecks: 50 → 15 (70% fewer raycasts)
--   • SeedsPerTick: 10 → 3 (70% fewer seed raycasts)
--   • Interval: 1.0s → 3.0s (3x less frequent)
--   • Batched raycasts with task.wait() yields between chunks
--   • Slope cache only refreshes when children change
--   • Removed expensive GetGrassNeighborCount ReadVoxels call
-- =========================================================================

local WEATHER_CONFIG = {
	Interval = 3.0,        -- V2 OPTIMIZATION: 3.0s instead of 1.0s (weather is slow, no need for 1Hz)
	MapSize = 12000,
	SlopeWidth = 100,
	LapseRate = 30,
	BaseSeedHeight = 130,
	AspectSampleDistance = 24,
	ElevationFullMeltBelow = 140,
	ElevationFullSnowAbove = 650,
	SeedsPerTick = 3,      -- V2 OPTIMIZATION: Reduced from 10
	WildBrush = 14,
	SlopeBrush = 5,
	CleanupRadius = 18,
	BaseChecks = 15,        -- V2 OPTIMIZATION: Reduced from 50 (massive reduction)
	MeltMultiplier = 2,     -- V2 OPTIMIZATION: Reduced from 5 to match slower interval
	BatchSize = 8,          -- V2 NEW: Yield after this many raycasts to avoid frame spikes
	Materials = {
		Snow = Enum.Material.Snow,
		Ground = Enum.Material.Ground,
		Grass = Enum.Material.LeafyGrass
	},
	WeatherMeltMultipliers = {
		Clear = 1.15,
		LightSnow = 0.8,
		HeavySnow = 0.55,
		Blizzard = 0.35,
	}
}

local slopeCache = {} 
local slopeCacheDirty = true  -- V2: Only rebuild when changed

local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Include
rayParams.FilterDescendantsInstances = {Terrain} 

local function RefreshSlopeCache()
	slopeCache = {}
	local folder = Workspace:FindFirstChild("PlacedObjects")
	if not folder then return end

	for _, model in ipairs(folder:GetChildren()) do
		if model:IsA("Model") and model:GetAttribute("Type") == "Slope" and model:GetAttribute("RawPoints") then
			local success, points = pcall(function()
				return HttpService:JSONDecode(model:GetAttribute("RawPoints"))
			end)
			if success and points then
				local vecPoints = {}
				for _, p in ipairs(points) do
					table.insert(vecPoints, Vector3.new(p[1], p[2], p[3]))
				end
				table.insert(slopeCache, {Points = vecPoints, Name = model.Name})
			end
		end
	end
	slopeCacheDirty = false
end

local placedFolder = Workspace:FindFirstChild("PlacedObjects")
if placedFolder then
	placedFolder.ChildAdded:Connect(function() slopeCacheDirty = true end)   -- was DescendantAdded: fired N times per model
	placedFolder.ChildRemoved:Connect(function() slopeCacheDirty = true end) -- was DescendantRemoving: fired N times per model
end
task.delay(2, RefreshSlopeCache)

local function GetDistToSlope(pos)
	local minDist = 99999
	for _, slope in ipairs(slopeCache) do
		for i = 1, #slope.Points - 1 do
			local a, b = slope.Points[i], slope.Points[i+1]
			local ab = b - a
			local ap = pos - a
			local dot = ap:Dot(ab)
			local lenSq = ab:Dot(ab)
			local t = (lenSq > 0) and math.clamp(dot / lenSq, 0, 1) or 0
			local closest = a + ab * t
			local dist = Vector2.new(pos.X - closest.X, pos.Z - closest.Z).Magnitude
			if dist < minDist then minDist = dist end
		end
	end
	return minDist
end

local function IsOnSlope(pos)
	return GetDistToSlope(pos) < (WEATHER_CONFIG.SlopeWidth / 2)
end

local function GetLocalTemp(yHeight)
	local globalTemp = Lighting:GetAttribute("Temperature") or 32
	local drop = math.floor(yHeight / WEATHER_CONFIG.LapseRate)
	return globalTemp - drop
end

local function SampleTerrainHeight(x, z)
	local ray = Workspace:Raycast(Vector3.new(x, 1500, z), Vector3.new(0, -3000, 0), rayParams)
	if ray and ray.Instance == Terrain then
		return ray.Position.Y
	end
	return nil
end

local function GetSlopeAspectSouthness(pos)
	local d = WEATHER_CONFIG.AspectSampleDistance
	local northY = SampleTerrainHeight(pos.X, pos.Z - d)
	local southY = SampleTerrainHeight(pos.X, pos.Z + d)
	local eastY = SampleTerrainHeight(pos.X + d, pos.Z)
	local westY = SampleTerrainHeight(pos.X - d, pos.Z)
	if not (northY and southY and eastY and westY) then
		return 0
	end

	local downhill = Vector3.new(westY - eastY, 0, northY - southY)
	if downhill.Magnitude < 0.5 then
		return 0
	end
	return downhill.Unit.Z
end

local function GetElevationMeltMultiplier(yHeight)
	local span = math.max(1, WEATHER_CONFIG.ElevationFullSnowAbove - WEATHER_CONFIG.ElevationFullMeltBelow)
	local alpha = math.clamp((yHeight - WEATHER_CONFIG.ElevationFullMeltBelow) / span, 0, 1)
	return 1.15 - (0.45 * alpha)
end

local function GetWeatherMeltMultiplier(weather)
	return WEATHER_CONFIG.WeatherMeltMultipliers[weather] or 1
end

local function GetSlopeMeltProfile(pos)
	local southness = GetSlopeAspectSouthness(pos)
	local chanceMultiplier = math.clamp(1 + (southness * 0.45), 0.55, 1.45)
	local brushMultiplier = southness >= 0 and (1 + southness * 0.5) or (1 + southness * 0.3)
	local brushRadius = math.clamp(math.floor((WEATHER_CONFIG.SlopeBrush * brushMultiplier) + 0.5), math.max(2, WEATHER_CONFIG.SlopeBrush - 2), WEATHER_CONFIG.SlopeBrush + 3)
	return chanceMultiplier, brushRadius
end

local function PaintRegion(pos, radius, targetMat)
	local region = Region3.new(
		pos - Vector3.new(radius, radius, radius), 
		pos + Vector3.new(radius, radius, radius)
	):ExpandToGrid(4)

	local materials, occupancies = Terrain:ReadVoxels(region, 4)
	local size = materials.Size
	local writes = 0

	for x = 1, size.X do
		for y = 1, size.Y do
			for z = 1, size.Z do
				if occupancies[x][y][z] > 0.1 and materials[x][y][z] ~= targetMat then
					materials[x][y][z] = targetMat
					writes = writes + 1
				end
			end
		end
	end

	if writes > 0 then
		Terrain:WriteVoxels(region, 4, materials, occupancies)
		return true
	end
	return false
end

local function ProcessTerrain()
	-- Refresh slope cache only when dirty (was rebuilding every call implicitly)
	if slopeCacheDirty then
		RefreshSlopeCache()
	end

	local globalTemp = Lighting:GetAttribute("Temperature") or 32
	local weather = Lighting:GetAttribute("Weather") or "Clear"

	local loops = WEATHER_CONFIG.BaseChecks
	if globalTemp > 32 then
		loops = loops + math.floor((globalTemp - 32) * WEATHER_CONFIG.MeltMultiplier)
	elseif globalTemp < 25 then
		loops = loops + math.floor((32 - globalTemp) * 1)
	end
	-- V2: Tighter cap — 60 absolute max (was 150)
	loops = math.clamp(loops, 5, 60) 

	local opsThisTick = 0

	-- 1. SEEDING (Reduced from 10 to 3 raycasts)
	if globalTemp > 35 then
		local seedCeiling = WEATHER_CONFIG.BaseSeedHeight + ((globalTemp - 35) * 20)
		for s = 1, WEATHER_CONFIG.SeedsPerTick do
			local x = math.random(-WEATHER_CONFIG.MapSize, WEATHER_CONFIG.MapSize)
			local z = math.random(-WEATHER_CONFIG.MapSize, WEATHER_CONFIG.MapSize)
			local ray = Workspace:Raycast(Vector3.new(x, 1500, z), Vector3.new(0, -3000, 0), rayParams)
			opsThisTick += 1

			if ray and ray.Instance == Terrain and ray.Material == WEATHER_CONFIG.Materials.Snow then
				if ray.Position.Y < seedCeiling then
					if not IsOnSlope(ray.Position) then
						PaintRegion(ray.Position, WEATHER_CONFIG.WildBrush, WEATHER_CONFIG.Materials.Grass)
					end
				end
			end

			-- V2: Yield between seed batches to avoid frame spikes
			if opsThisTick % WEATHER_CONFIG.BatchSize == 0 then
				task.wait()
			end
		end
	end

	-- 2. EXPANSION (Batched with yields)
	for i = 1, loops do
		local x = math.random(-WEATHER_CONFIG.MapSize, WEATHER_CONFIG.MapSize)
		local z = math.random(-WEATHER_CONFIG.MapSize, WEATHER_CONFIG.MapSize)
		local ray = Workspace:Raycast(Vector3.new(x, 1500, z), Vector3.new(0, -3000, 0), rayParams)
		opsThisTick += 1

		if ray and ray.Instance == Terrain then
			local mat = ray.Material
			local pos = ray.Position
			local localTemp = GetLocalTemp(pos.Y)

			if localTemp > 32 and mat == WEATHER_CONFIG.Materials.Snow then
				-- Keep the optimized random melt, but bias it using the active weather,
				-- slope aspect, and elevation so southern/lower terrain opens faster
				-- while northern/higher terrain keeps snow longer.
				local onSlope = IsOnSlope(pos)
				local weatherMeltMultiplier = GetWeatherMeltMultiplier(weather)
				local elevationMeltMultiplier = GetElevationMeltMultiplier(pos.Y)
				if not onSlope then
					local chance = math.clamp(((localTemp - 32) / 100) * weatherMeltMultiplier * elevationMeltMultiplier, 0, 0.95)
					if math.random() < chance then
						local meltBrush = math.max(2, math.floor((WEATHER_CONFIG.WildBrush * math.clamp(elevationMeltMultiplier, 0.75, 1.15)) + 0.5))
						PaintRegion(pos, meltBrush, WEATHER_CONFIG.Materials.Grass)
					end
				else
					local aspectChanceMultiplier, slopeBrush = GetSlopeMeltProfile(pos)
					local chance = math.clamp(((localTemp - 32) / 500) * aspectChanceMultiplier * elevationMeltMultiplier * weatherMeltMultiplier, 0, 0.95)
					if math.random() < chance then
						PaintRegion(pos, slopeBrush, WEATHER_CONFIG.Materials.Grass)
					end
				end
			elseif localTemp <= 32 and mat ~= WEATHER_CONFIG.Materials.Snow then
				if weather:find("Snow") then
					PaintRegion(pos, WEATHER_CONFIG.CleanupRadius, WEATHER_CONFIG.Materials.Snow)
				end
			end
		end

		-- V2: Yield between batches to keep heartbeat responsive
		if opsThisTick % WEATHER_CONFIG.BatchSize == 0 then
			task.wait()
		end
	end
end

-- // RUN LOOP //
-- Legacy weather processor is disabled by default because TerrainController
-- already owns weather-driven terrain simulation in this place.
local ENABLE_LEGACY_WEATHER_SYSTEM = false
if ENABLE_LEGACY_WEATHER_SYSTEM then
	task.spawn(function()
		while true do
			-- Don't process weather until terrain is generated
			if _G.TerrainReady then
				ProcessTerrain()
				task.wait(WEATHER_CONFIG.Interval)
			else
				task.wait(2)
			end
		end
	end)
end

-- // SEASON CHANGE BULK REPAINT //
-- When the season changes, do an aggressive one-time sweep so the terrain
-- visually updates quickly instead of relying on the slow random sampling.
local function BulkSeasonRepaint()
	if not _G.TerrainReady then return end

	if slopeCacheDirty then
		RefreshSlopeCache()
	end

	local globalTemp = Lighting:GetAttribute("Temperature") or 32
	local weather = Lighting:GetAttribute("Weather") or "Clear"
	local isCold = globalTemp <= 32
	local isSnowing = weather:find("Snow") ~= nil

	-- Pick target material: cold + snowing → snow, warm → grass
	local targetMat
	if isCold and isSnowing then
		targetMat = WEATHER_CONFIG.Materials.Snow
	elseif not isCold then
		targetMat = WEATHER_CONFIG.Materials.Grass
	else
		-- Cold but not snowing — leave terrain as-is, normal loop will handle
		return
	end

	local enemyMat = (targetMat == WEATHER_CONFIG.Materials.Snow) and WEATHER_CONFIG.Materials.Grass or WEATHER_CONFIG.Materials.Snow

	-- Do an aggressive sweep: many random samples, convert mismatched terrain
	local sweepCount = 200 -- many more samples than the normal 15
	local opsThisTick = 0
	for i = 1, sweepCount do
		local x = math.random(-WEATHER_CONFIG.MapSize, WEATHER_CONFIG.MapSize)
		local z = math.random(-WEATHER_CONFIG.MapSize, WEATHER_CONFIG.MapSize)
		local ray = Workspace:Raycast(Vector3.new(x, 1500, z), Vector3.new(0, -3000, 0), rayParams)
		opsThisTick += 1

		if ray and ray.Instance == Terrain then
			-- Only convert the "enemy" material
			if ray.Material == enemyMat then
				local onSlope = IsOnSlope(ray.Position)
				local brush = onSlope and WEATHER_CONFIG.SlopeBrush or WEATHER_CONFIG.WildBrush
				PaintRegion(ray.Position, brush, targetMat)
			end
		end

		-- Yield between batches to avoid frame spikes
		if opsThisTick % WEATHER_CONFIG.BatchSize == 0 then
			task.wait()
		end
	end
end

-- Schedule multiple waves so the transition feels smooth over a few seconds
local function OnSeasonChanged()
	task.spawn(function()
		for wave = 1, 5 do
			BulkSeasonRepaint()
			task.wait(1.5)
		end
	end)
end

if ENABLE_LEGACY_WEATHER_SYSTEM then
	Lighting:GetAttributeChangedSignal("Season"):Connect(OnSeasonChanged)
	-- Also react to weather changes (e.g. blizzard starting/stopping)
	Lighting:GetAttributeChangedSignal("Weather"):Connect(function()
		task.delay(2, BulkSeasonRepaint)
	end)
end