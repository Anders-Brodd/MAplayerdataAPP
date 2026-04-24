--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Events = ReplicatedStorage:WaitForChild("Events")

local REMOTE_NAME = "GetResortMapData"
local BOUNDS_PADDING = 90
local MIN_HALF_EXTENT = 140

type PackedPoint = {number}
type Bounds = {
	MinX: number,
	MinZ: number,
	MaxX: number,
	MaxZ: number,
}

local function ensureRemoteFunction(): RemoteFunction
	local existing = Events:FindFirstChild(REMOTE_NAME)
	if existing and existing:IsA("RemoteFunction") then
		return existing
	end
	if existing then
		existing:Destroy()
	end

	local remote = Instance.new("RemoteFunction")
	remote.Name = REMOTE_NAME
	remote.Parent = Events
	return remote
end

local function packVector3(value: Vector3): PackedPoint
	return {value.X, value.Y, value.Z}
end

local function parseVector3(raw: any): Vector3?
	if typeof(raw) == "Vector3" then
		return raw
	end

	if type(raw) == "table" then
		local x = tonumber(raw.X or raw.x or raw[1])
		local y = tonumber(raw.Y or raw.y or raw[2])
		local z = tonumber(raw.Z or raw.z or raw[3])
		if x and y and z then
			return Vector3.new(x, y, z)
		end
	end

	if type(raw) == "string" then
		local x, y, z = string.match(raw, "^%s*([%-%d%.eE]+)%s*,%s*([%-%d%.eE]+)%s*,%s*([%-%d%.eE]+)%s*$")
		if x and y and z then
			local nx = tonumber(x)
			local ny = tonumber(y)
			local nz = tonumber(z)
			if nx and ny and nz then
				return Vector3.new(nx, ny, nz)
			end
		end
	end

	return nil
end

local function getModelPosition(model: Model): Vector3?
	local ok, pivot = pcall(function()
		return model:GetPivot()
	end)
	if ok then
		return pivot.Position
	end

	local primary = model.PrimaryPart or model:FindFirstChildWhichIsA("BasePart", true)
	if primary then
		return primary.Position
	end

	return nil
end

local function pushBounds(bounds: Bounds?, point: Vector3): Bounds
	if bounds == nil then
		return {
			MinX = point.X,
			MinZ = point.Z,
			MaxX = point.X,
			MaxZ = point.Z,
		}
	end

	bounds.MinX = math.min(bounds.MinX, point.X)
	bounds.MinZ = math.min(bounds.MinZ, point.Z)
	bounds.MaxX = math.max(bounds.MaxX, point.X)
	bounds.MaxZ = math.max(bounds.MaxZ, point.Z)
	return bounds
end

local function classifyBuildingType(modelName: string): string
	local lower = string.lower(modelName)
	if string.find(lower, "restaurant", 1, true) or string.find(lower, "snack", 1, true) or string.find(lower, "food", 1, true) then
		return "Food"
	end
	if string.find(lower, "rental", 1, true) then
		return "Rental"
	end
	if string.find(lower, "shop", 1, true) then
		return "Shop"
	end
	if string.find(lower, "hotel", 1, true) or string.find(lower, "cabin", 1, true) or string.find(lower, "house", 1, true) or string.find(lower, "lodge", 1, true) then
		return "House"
	end
	return "Building"
end

local function buildFallbackBounds(player: Player, currentBounds: Bounds?): Bounds
	if currentBounds then
		local centerX = (currentBounds.MinX + currentBounds.MaxX) * 0.5
		local centerZ = (currentBounds.MinZ + currentBounds.MaxZ) * 0.5
		local halfWidth = math.max(MIN_HALF_EXTENT, (currentBounds.MaxX - currentBounds.MinX) * 0.5 + BOUNDS_PADDING)
		local halfHeight = math.max(MIN_HALF_EXTENT, (currentBounds.MaxZ - currentBounds.MinZ) * 0.5 + BOUNDS_PADDING)
		return {
			MinX = centerX - halfWidth,
			MinZ = centerZ - halfHeight,
			MaxX = centerX + halfWidth,
			MaxZ = centerZ + halfHeight,
		}
	end

	local center = Vector3.zero
	local character = player.Character
	local hrp = character and character:FindFirstChild("HumanoidRootPart")
	if hrp and hrp:IsA("BasePart") then
		center = hrp.Position
	end

	return {
		MinX = center.X - 300,
		MinZ = center.Z - 300,
		MaxX = center.X + 300,
		MaxZ = center.Z + 300,
	}
end

local function collectSlopeData(root: Instance, bounds: Bounds?): ({[string]: any}, Bounds?)
	local slopes = {}
	local slopeGetter = _G.GetSlopeData
	if type(slopeGetter) ~= "function" then
		return slopes, bounds
	end

	for _, child in ipairs(root:GetChildren()) do
		if not child:IsA("Model") then
			continue
		end

		local ok, slopeData = pcall(slopeGetter, child)
		if not ok or type(slopeData) ~= "table" then
			continue
		end
		if slopeData.IsPath or slopeData.IsQueue or type(slopeData.Path) ~= "table" or #slopeData.Path < 2 then
			continue
		end

		local packedPoints = {}
		for _, point in ipairs(slopeData.Path) do
			local vectorPoint = parseVector3(point)
			if vectorPoint then
				table.insert(packedPoints, packVector3(vectorPoint))
				bounds = pushBounds(bounds, vectorPoint)
			end
		end

		if #packedPoints >= 2 then
			table.insert(slopes, {
				Name = tostring(child:GetAttribute("CustomName") or child.Name),
				Difficulty = tostring(child:GetAttribute("Difficulty") or slopeData.Difficulty or "Green"),
				Points = packedPoints,
			})
		end
	end

	return slopes, bounds
end

local function collectPlacedObjects(player: Player)
	local placedObjects = Workspace:FindFirstChild("PlacedObjects")
	local lifts = {}
	local buildings = {}
	local bounds: Bounds? = nil

	if not placedObjects then
		return lifts, buildings, {}, buildFallbackBounds(player, nil)
	end

	for _, child in ipairs(placedObjects:GetChildren()) do
		if not child:IsA("Model") then
			continue
		end

		local p1 = parseVector3(child:GetAttribute("P1"))
		local p2 = parseVector3(child:GetAttribute("P2"))
		if p1 and p2 then
			bounds = pushBounds(bounds, p1)
			bounds = pushBounds(bounds, p2)
			table.insert(lifts, {
				Name = tostring(child:GetAttribute("CustomName") or child:GetAttribute("DefaultPlacedName") or child.Name),
				StartPos = packVector3(p1),
				EndPos = packVector3(p2),
			})
			continue
		end

		local pos = getModelPosition(child)
		if pos then
			bounds = pushBounds(bounds, pos)
			table.insert(buildings, {
				Name = tostring(child:GetAttribute("CustomName") or child.Name),
				Type = classifyBuildingType(child.Name),
				Position = packVector3(pos),
			})
		end
	end

	local slopes
	slopes, bounds = collectSlopeData(placedObjects, bounds)

	return lifts, buildings, slopes, buildFallbackBounds(player, bounds)
end

local MapRemote = ensureRemoteFunction()
MapRemote.OnServerInvoke = function(player: Player)
	local lifts, buildings, slopes, bounds = collectPlacedObjects(player)
	return {
		Bounds = bounds,
		Terrain = nil,
		Lifts = lifts,
		Buildings = buildings,
		Slopes = slopes,
	}
end

print("[ResortMapServer] Ready")
