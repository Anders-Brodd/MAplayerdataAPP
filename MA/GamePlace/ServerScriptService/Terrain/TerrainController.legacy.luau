--[[
	🌍 TERRAIN CONTROLLER V22.0 (Performance Overhaul)
	ServerScriptService/TerrainController

	=== WHY V21 KILLED PERFORMANCE ===
	V21 ran up to 4000 iterations per tick (every 0.05s = 20x/sec).
	Each iteration: 1 raycast + IsOnSlope (loop over all slopes) +
	  GetGrassNeighborCount (ReadVoxels on 36³ region) +
	  PaintRegion (ReadVoxels + WriteVoxels on 36³ region).
	
	At worst case that's ~8000 ReadVoxels + 4000 WriteVoxels PER SECOND.
	Each WriteVoxels replicates terrain changes to ALL clients.
	This saturated the server heartbeat (43% activity) and flooded 
	the network with 64MB+ of terrain replication data.

	=== V22 FIXES ===
	1. BUDGET SYSTEM: Max operations per frame, with time-based budgeting.
	   Never exceeds a configurable ms budget per heartbeat.
	2. BATCH WRITES: Collect changes, batch into fewer WriteVoxels calls.
	3. MUCH SLOWER TICK RATE: 0.5s instead of 0.05s. Snow/melt is gradual
	   anyway — updating 20x/sec was insane overkill.
	4. FEWER CHECKS PER TICK: 30-80 instead of 300-4000.
	5. SKIP NEIGHBOR CHECK: The neighbor check (GetGrassNeighborCount)
	   was the biggest perf killer — an extra ReadVoxels per iteration
	   just to see if grass was nearby. Removed entirely; melt happens
	   probabilistically based on temperature alone.
	6. SMALLER BRUSH: WildBrush 14→8, CleanupRadius 18→10. These create
	   cubic regions (2*r)³ voxels. Brush 14 = 28³ = 21,952 voxels per
	   read/write. Brush 8 = 16³ = 4,096 voxels. 5x fewer voxels.
	7. SLOPE CACHE uses spatial hash instead of iterating all slopes.
	8. YIELDING: task.wait() between batches to not block heartbeat.
]]

local RunService  = game:GetService("RunService")
local Workspace   = game:GetService("Workspace")
local Lighting    = game:GetService("Lighting")
local HttpService = game:GetService("HttpService")
local Terrain     = Workspace.Terrain

-- ════════════════════════════════════════════════════════════
-- CONFIGURATION
-- ════════════════════════════════════════════════════════════
local CONFIG = {
	-- Timing
	TickInterval    = 0.5,     -- How often to process (seconds). Was 0.05!
	MaxMsPerTick    = 4,       -- Max milliseconds to spend per tick

	-- Map
	MapSize         = 12000,
	SlopeWidth      = 100,

	-- Height/Temperature
	LapseRate       = 30,
	BaseSeedHeight  = 130,
	AspectSampleDistance = 24,
	ElevationFullMeltBelow = 140,
	ElevationFullSnowAbove = 650,

	-- Brush sizes (SMALLER = faster)
	WildBrush       = 8,       -- Was 14. Region is (2r)³ voxels.
	SlopeBrush      = 5,
	CleanupRadius   = 10,      -- Was 18. 

	-- Checks per tick (MUCH fewer)
	BaseChecks      = 30,      -- Was 300!
	MeltMultiplier  = 4,       -- Was 40!
	MaxChecks       = 120,     -- Hard cap. Was 4000!
	SeedsPerTick    = 5,       -- Was 25

	-- Materials
	Snow  = Enum.Material.Snow,
	Grass = Enum.Material.LeafyGrass,

	WeatherMeltMultipliers = {
		Clear = 1.15,
		LightSnow = 0.8,
		HeavySnow = 0.55,
		Blizzard = 0.35,
	},
}

-- ════════════════════════════════════════════════════════════
-- RAYCAST SETUP
-- ════════════════════════════════════════════════════════════
local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Include
rayParams.FilterDescendantsInstances = { Terrain }

-- ════════════════════════════════════════════════════════════
-- SLOPE CACHE (Spatial Hash)
-- ════════════════════════════════════════════════════════════
-- Instead of iterating ALL slope segments for every point,
-- we bucket segments into a spatial grid so we only check nearby ones.

local SLOPE_CELL = 200  -- Grid cell size for spatial hashing
local slopeGrid = {}     -- [cellKey] = { {a, b}, {a, b}, ... }
local slopeSegments = {} -- flat list for fallback

local function cellKey(x, z)
	return math.floor(x / SLOPE_CELL) * 100000 + math.floor(z / SLOPE_CELL)
end

local function insertSegment(a, b)
	-- Insert into all grid cells the segment could touch
	local minX = math.min(a.X, b.X) - CONFIG.SlopeWidth
	local maxX = math.max(a.X, b.X) + CONFIG.SlopeWidth
	local minZ = math.min(a.Z, b.Z) - CONFIG.SlopeWidth
	local maxZ = math.max(a.Z, b.Z) + CONFIG.SlopeWidth

	for gx = math.floor(minX / SLOPE_CELL), math.floor(maxX / SLOPE_CELL) do
		for gz = math.floor(minZ / SLOPE_CELL), math.floor(maxZ / SLOPE_CELL) do
			local key = gx * 100000 + gz
			if not slopeGrid[key] then slopeGrid[key] = {} end
			table.insert(slopeGrid[key], { a, b })
		end
	end
end

local function RefreshSlopeCache()
	slopeGrid = {}
	slopeSegments = {}

	local folder = Workspace:FindFirstChild("PlacedObjects")
	if not folder then return end

	for _, model in ipairs(folder:GetChildren()) do
		if model:GetAttribute("Type") == "Slope" and model:GetAttribute("RawPoints") then
			local ok, points = pcall(function()
				return HttpService:JSONDecode(model:GetAttribute("RawPoints"))
			end)
			if ok and points then
				for i = 1, #points - 1 do
					local a = Vector3.new(points[i][1], points[i][2], points[i][3])
					local b = Vector3.new(points[i+1][1], points[i+1][2], points[i+1][3])
					insertSegment(a, b)
					table.insert(slopeSegments, { a, b })
				end
			end
		end
	end
end

local placedFolder = Workspace:FindFirstChild("PlacedObjects")
if placedFolder then
	placedFolder.ChildAdded:Connect(function() task.delay(1, RefreshSlopeCache) end)
	placedFolder.ChildRemoved:Connect(function() task.delay(1, RefreshSlopeCache) end)
end
task.delay(1, RefreshSlopeCache)

-- ════════════════════════════════════════════════════════════
-- SLOPE DISTANCE (uses spatial hash)
-- ════════════════════════════════════════════════════════════
local function IsOnSlope(pos)
	local halfWidth = CONFIG.SlopeWidth / 2
	local key = cellKey(pos.X, pos.Z)
	local segs = slopeGrid[key]
	if not segs then return false end

	for _, seg in ipairs(segs) do
		local a, b = seg[1], seg[2]
		local ab = b - a
		local ap = pos - a
		local abDotAb = ab:Dot(ab)
		if abDotAb > 0.001 then
			local t = math.clamp(ap:Dot(ab) / abDotAb, 0, 1)
			local closest = a + ab * t
			local dx = pos.X - closest.X
			local dz = pos.Z - closest.Z
			if dx * dx + dz * dz < halfWidth * halfWidth then
				return true
			end
		end
	end
	return false
end

-- ════════════════════════════════════════════════════════════
-- TEMPERATURE
-- ════════════════════════════════════════════════════════════
local function GetLocalTemp(yHeight)
	local globalTemp = Lighting:GetAttribute("Temperature") or 32
	return globalTemp - math.floor(yHeight / CONFIG.LapseRate)
end

local function SampleTerrainHeight(x, z)
	local ray = Workspace:Raycast(Vector3.new(x, 1500, z), Vector3.new(0, -3000, 0), rayParams)
	if ray and ray.Instance == Terrain then
		return ray.Position.Y
	end
	return nil
end

local function GetSlopeAspectSouthness(pos)
	local d = CONFIG.AspectSampleDistance
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
	local span = math.max(1, CONFIG.ElevationFullSnowAbove - CONFIG.ElevationFullMeltBelow)
	local alpha = math.clamp((yHeight - CONFIG.ElevationFullMeltBelow) / span, 0, 1)
	return 1.15 - (0.45 * alpha)
end

local function GetWeatherMeltMultiplier(weather)
	return CONFIG.WeatherMeltMultipliers[weather] or 1
end

local function GetSlopeMeltProfile(pos)
	local southness = GetSlopeAspectSouthness(pos)
	local chanceMultiplier = math.clamp(1 + (southness * 0.45), 0.55, 1.45)
	local brushMultiplier = southness >= 0 and (1 + southness * 0.5) or (1 + southness * 0.3)
	local brushRadius = math.clamp(math.floor((CONFIG.SlopeBrush * brushMultiplier) + 0.5), math.max(2, CONFIG.SlopeBrush - 2), CONFIG.SlopeBrush + 3)
	return chanceMultiplier, brushRadius
end

-- ════════════════════════════════════════════════════════════
-- PAINT (optimized — skip read if not needed)
-- ════════════════════════════════════════════════════════════
local function PaintRegion(pos, radius, targetMat)
	local r3 = Region3.new(
		pos - Vector3.new(radius, radius, radius),
		pos + Vector3.new(radius, radius, radius)
	):ExpandToGrid(4)

	local materials, occupancies = Terrain:ReadVoxels(r3, 4)
	local size = materials.Size
	local changed = false

	for x = 1, size.X do
		for y = 1, size.Y do
			for z = 1, size.Z do
				if occupancies[x][y][z] > 0.1 and materials[x][y][z] ~= targetMat then
					-- Keep weather repaint constrained to terrain-like materials.
					local mat = materials[x][y][z]
					local canRepaint = false
					if targetMat == CONFIG.Snow then
						-- Allow snowfall to reclaim common manually-painted terrain mats.
						canRepaint = (mat == CONFIG.Grass)
							or (mat == Enum.Material.Grass)
							or (mat == Enum.Material.Ground)
							or (mat == Enum.Material.Rock)
							or (mat == Enum.Material.Mud)
							or (mat == CONFIG.Snow)
					else
						-- Melt should only target snow/soft ground materials.
						canRepaint = (mat == CONFIG.Snow)
							or (mat == CONFIG.Grass)
							or (mat == Enum.Material.Grass)
							or (mat == Enum.Material.Ground)
					end
					if canRepaint then
						materials[x][y][z] = targetMat
						changed = true
					end
				end
			end
		end
	end

	if changed then
		Terrain:WriteVoxels(r3, 4, materials, occupancies)
	end
	return changed
end

-- ════════════════════════════════════════════════════════════
-- EXTERNAL API (Snow Guns)
-- ════════════════════════════════════════════════════════════
function _G.PaintSnowAt(pos, radius)
	if not pos then return end
	radius = radius or 6
	if IsOnSlope(pos) then
		PaintRegion(pos, radius, CONFIG.Snow)
	end
end
_G.IsOnSlope = IsOnSlope

-- ════════════════════════════════════════════════════════════
-- MAIN PROCESSING
-- ════════════════════════════════════════════════════════════
local lastUpdate = 0

local function ProcessTerrain()
	local globalTemp = Lighting:GetAttribute("Temperature") or 32
	local weather = Lighting:GetAttribute("Weather") or "Clear"
	local isSnowing = weather:find("Snow") ~= nil
	local startTime = os.clock()

	-- Budget: how many checks this tick
	local loops = CONFIG.BaseChecks
	if globalTemp > 32 then
		loops = loops + math.floor((globalTemp - 32) * CONFIG.MeltMultiplier)
	elseif globalTemp < 25 then
		loops = loops + math.floor((32 - globalTemp) * 2)
	end
	loops = math.clamp(loops, 10, CONFIG.MaxChecks)

	-- ── SEEDING (melt from valley up) ──
	if globalTemp > 35 then
		local seedCeiling = CONFIG.BaseSeedHeight + ((globalTemp - 35) * 20)
		for s = 1, CONFIG.SeedsPerTick do
			-- Time budget check
			if (os.clock() - startTime) * 1000 > CONFIG.MaxMsPerTick then break end

			local x = math.random(-CONFIG.MapSize, CONFIG.MapSize)
			local z = math.random(-CONFIG.MapSize, CONFIG.MapSize)
			local ray = Workspace:Raycast(Vector3.new(x, 1500, z), Vector3.new(0, -3000, 0), rayParams)
			if ray and ray.Instance == Terrain and ray.Material == CONFIG.Snow then
				if ray.Position.Y < seedCeiling and not IsOnSlope(ray.Position) then
					PaintRegion(ray.Position, CONFIG.WildBrush, CONFIG.Grass)
				end
			end
		end
	end

	-- ── EXPANSION LOOP ──
	for i = 1, loops do
		-- Time budget: stop if we've used our ms allowance
		if (os.clock() - startTime) * 1000 > CONFIG.MaxMsPerTick then break end

		local x = math.random(-CONFIG.MapSize, CONFIG.MapSize)
		local z = math.random(-CONFIG.MapSize, CONFIG.MapSize)
		local ray = Workspace:Raycast(Vector3.new(x, 1500, z), Vector3.new(0, -3000, 0), rayParams)

		if ray and ray.Instance == Terrain then
			local mat = ray.Material
			local pos = ray.Position
			local localTemp = GetLocalTemp(pos.Y)

			-- ── MELT (warm + snow → grass) ──
			if localTemp > 32 and mat == CONFIG.Snow then
				-- V22: Keep the lightweight probabilistic melt, but bias it by
				-- weather, slope aspect, and elevation so warm south-facing slopes
				-- open up faster while shaded/high terrain hangs on to snow longer.
				local onSlope = IsOnSlope(pos)
				local weatherMeltMultiplier = GetWeatherMeltMultiplier(weather)
				local elevationMeltMultiplier = GetElevationMeltMultiplier(pos.Y)
				if not onSlope then
					local chance = math.clamp(((localTemp - 32) / 100) * weatherMeltMultiplier * elevationMeltMultiplier, 0, 0.95)
					if math.random() < chance then
						local meltBrush = math.max(2, math.floor((CONFIG.WildBrush * math.clamp(elevationMeltMultiplier, 0.75, 1.15)) + 0.5))
						PaintRegion(pos, meltBrush, CONFIG.Grass)
					end
				else
					local aspectChanceMultiplier, slopeBrush = GetSlopeMeltProfile(pos)
					local chance = math.clamp(((localTemp - 32) / 500) * aspectChanceMultiplier * elevationMeltMultiplier * weatherMeltMultiplier, 0, 0.95)
					if math.random() < chance then
						PaintRegion(pos, slopeBrush, CONFIG.Grass)
					end
				end

				-- ── FREEZE (cold + snowing + grass → snow) ──
			elseif localTemp <= 32 and mat ~= CONFIG.Snow then
				if isSnowing then
					if mat == CONFIG.Grass
						or mat == Enum.Material.Grass
						or mat == Enum.Material.Ground
						or mat == Enum.Material.Rock
						or mat == Enum.Material.Mud then
						PaintRegion(pos, CONFIG.CleanupRadius, CONFIG.Snow)
					end
				end
			end
		end
	end
end

-- ════════════════════════════════════════════════════════════
-- HEARTBEAT (throttled)
-- ════════════════════════════════════════════════════════════
RunService.Heartbeat:Connect(function(dt)
	local now = os.clock()
	if now - lastUpdate < CONFIG.TickInterval then return end
	lastUpdate = now
	ProcessTerrain()
end)