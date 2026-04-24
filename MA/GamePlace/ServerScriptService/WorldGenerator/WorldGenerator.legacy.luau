-- [[ SCRIPT OVERVIEW & CHANGES ]]
-- WHAT THIS SCRIPT DOES:
-- Generates procedural and real-world-based 3D terrain using a self-hosted OpenTopoData/Copernicus API.
-- Enforces a strict 1:1 real-world scale, meaning mountains and slopes match their real-life proportions exactly.
-- Manages datastores for saving and loading user terrain data.
-- Places vegetation (trees, snow trees) based on elevation, realistic tree lines, and density settings.
-- Carves sinuous river valleys into the heightmap.
-- Handles player spawning and phased loading sequences to optimize server performance.
-- Provides extensive, concise console logging for all major operations.
-- Automatically selects a random world-class ski resort if no specific coordinates are provided by the user.
--
-- WHAT CHANGED FROM V42:
-- REMOVED: Google Maps Elevation API dependency and API key.
-- ADDED: Self-hosted OpenTopoData Copernicus GLO-30 elevation endpoint on VPS port 32579.
-- CHANGED: BATCH_SIZE from 450 to 400 (nginx URL length limit on self-hosted server).
-- CHANGED: Loading message updated from "Connecting to Google Maps..." to "Loading real world terrain...".
-- UNCHANGED: All terrain scaling, heightmap math, smoothing, vegetation, and save/load logic.
-- [[ END OF OVERVIEW ]]

-- WorldGenerator V44.0 - PARALLEL REQUESTS + COPERNICUS GLO-30
-- ServerScriptService (MainGame/GameWorld)

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Players = game:GetService("Players")
local DataStoreService = game:GetService("DataStoreService")
local HttpService = game:GetService("HttpService")
local RunService = game:GetService("RunService")

local CanonicalProfile = nil
do
	local serverFolder = ServerScriptService:FindFirstChild("Server")
	local profileModule = serverFolder and serverFolder:FindFirstChild("CanonicalPlayerProfile")
	if profileModule and profileModule:IsA("ModuleScript") then
		local ok, loaded = pcall(require, profileModule)
		if ok and type(loaded) == "table" then
			CanonicalProfile = loaded
		end
	end
end

-- Toggle this to false to test full world generation in Studio
local ENABLE_STUDIO_BYPASS = true

-- ============================================
-- SELF-HOSTED ELEVATION API
-- ============================================
local ELEVATION_API_URL = "https://elevation.tracemotorsports.com/v1/copernicus30m"

-- ============================================
-- EVENTS SETUP
-- ============================================
local Events = ReplicatedStorage:FindFirstChild("Events")
if not Events then
	Events = Instance.new("Folder", ReplicatedStorage)
	Events.Name = "Events"
end

local GenerateEvent = Events:FindFirstChild("GenerateWorld") or Instance.new("BindableEvent", Events)
GenerateEvent.Name = "GenerateWorld"

local TerrainReady = Events:FindFirstChild("TerrainReady") or Instance.new("BindableEvent", Events)
TerrainReady.Name = "TerrainReady"

local ForceResetWorldSession = Events:FindFirstChild("ForceResetWorldSession")
if ForceResetWorldSession and not ForceResetWorldSession:IsA("BindableEvent") then
	ForceResetWorldSession:Destroy()
	ForceResetWorldSession = nil
end
if not ForceResetWorldSession then
	ForceResetWorldSession = Instance.new("BindableEvent")
	ForceResetWorldSession.Name = "ForceResetWorldSession"
	ForceResetWorldSession.Parent = Events
end

local LoadingUpdate = Events:FindFirstChild("LoadingUpdate")
if not LoadingUpdate then
	LoadingUpdate = Instance.new("RemoteEvent", Events)
	LoadingUpdate.Name = "LoadingUpdate"
end

-- ============================================
-- DATASTORES - CONSISTENT KEY FORMATS
-- ============================================
local TERRAIN_STORE_NAME = "TycoonTerrainGen"
local GAME_DATA_STORE_NAME = "TycoonGameData"
local TERRAIN_META_SAVE_RETRIES = 4
local TERRAIN_META_SAVE_RETRY_DELAY_SECONDS = 1
local LegacyTerrainMetaStore = DataStoreService:GetDataStore(TERRAIN_STORE_NAME)
local TerrainMetaStore = if CanonicalProfile
	then CanonicalProfile.CreateSlotStoreProxy(LegacyTerrainMetaStore, TERRAIN_STORE_NAME, "TerrainMeta")
	else LegacyTerrainMetaStore
local LegacyGameDataStore = DataStoreService:GetDataStore(GAME_DATA_STORE_NAME)
local GameDataStore = if CanonicalProfile
	then CanonicalProfile.CreateSlotStoreProxy(LegacyGameDataStore, GAME_DATA_STORE_NAME, "GameData")
	else LegacyGameDataStore

local function getTerrainKey(userId, slotNum)
	return "User_" .. userId .. "_Slot" .. slotNum .. "_TerrainMeta"
end

local function getTerrainLoadKeys(userId, slotNum)
	local keys = {}
	local seen = {}
	local function push(key)
		if type(key) ~= "string" or key == "" or seen[key] then
			return
		end
		seen[key] = true
		table.insert(keys, key)
	end

	if type(_G.GetSlotKey) == "function" then
		local ok, slotKey = pcall(_G.GetSlotKey, userId)
		if ok and type(slotKey) == "string" and slotKey ~= "" then
			push(slotKey .. "_TerrainMeta")
		end
	end

	push(getTerrainKey(userId, slotNum))
	push(string.format("User_%d_Slot_%d_TerrainMeta", userId, slotNum))
	return keys
end

-- SESSION STATE
local SessionState = {
	WorldGenerated = false,
	OwnerId = nil,
	SlotNum = nil,
	CreatedTime = nil
}

_G.TerrainWriteInProgress = false
_G.TerrainSettled = false

local function setGenerationStatus(status, ownerRef, slotNum, errMessage)
	local ownerId = nil
	if typeof(ownerRef) == "Instance" and ownerRef:IsA("Player") then
		ownerId = ownerRef.UserId
	elseif type(ownerRef) == "number" then
		ownerId = ownerRef
	else
		ownerId = SessionState.OwnerId
	end

	_G.WorldGenerationStatus = status
	_G.WorldGenerationOwnerId = ownerId
	_G.WorldGenerationSlotNum = slotNum or SessionState.SlotNum

	if status == "idle" then
		_G.WorldGenerationStartedAt = nil
		_G.WorldGenerationFinishedAt = tick()
		_G.WorldGenerationError = nil
		return
	end

	if status == "running" or status == "restoring" then
		_G.WorldGenerationStartedAt = tick()
		_G.WorldGenerationFinishedAt = nil
		_G.WorldGenerationError = nil
		return
	end

	if status == "failed" then
		_G.WorldGenerationFinishedAt = tick()
		_G.WorldGenerationError = errMessage
		return
	end

	if status == "ready" then
		_G.WorldGenerationFinishedAt = tick()
		_G.WorldGenerationError = nil
		return
	end

	_G.WorldGenerationError = nil
end

local function resetSessionState()
	SessionState.WorldGenerated = false
	SessionState.OwnerId = nil
	SessionState.SlotNum = nil
	SessionState.CreatedTime = nil
	setGenerationStatus("idle")
end

setGenerationStatus("idle")

-- ============================================
-- TERRAIN SETTINGS
-- ============================================
local TERRAIN_SIZE_STUDS = 8192
local REAL_WORLD_SPAN_KM = 8.0
local MIN_MAP_SCALE = 0.75
local MAX_MAP_SCALE = 2.5
local GRID_RESOLUTION = 64
local VOXEL_SIZE = 4
local CHUNK_SIZE = 128
local BATCH_SIZE = 400
local TERRAIN_SLICE_HEIGHT_STUDS = 256

-- ============================================
-- MATERIAL SETTINGS (PBR SUPPORT)
-- ============================================
local MATERIALS = {
	Surface = Enum.Material.Snow,
	Bedrock = Enum.Material.Rock,
	SurfaceVariant = "AndersSnow",
	BedrockVariant = nil,
}

local DEFAULT_TERRAIN_PROFILE_VERSION = 2
local TERRAIN_PROFILES = {
	[1] = {
		HeightmapSmoothIterations = 1,
		DetailLargeAmplitude = 1.0,
		DetailMediumAmplitude = 1.0,
		DetailSmallAmplitude = 1.0,
		DetailNoiseScale = 1.0,
		SaveSmoothIterations = 0,
	},
	[2] = {
		HeightmapSmoothIterations = 1,
		DetailLargeAmplitude = 0.62,
		DetailMediumAmplitude = 0.34,
		DetailSmallAmplitude = 0.09,
		DetailNoiseScale = 0.64,
		SaveSmoothIterations = 0,
	},
}

local function getTerrainProfile(terrainMeta)
	local version = tonumber(terrainMeta and terrainMeta.TerrainProfileVersion) or 1
	return version, TERRAIN_PROFILES[version] or TERRAIN_PROFILES[1]
end

-- ============================================
-- VISUAL SCALING SETTINGS
-- ============================================
local MIN_GAME_HEIGHT = 100
local TARGET_VERTICAL_RANGE = 1500

local LEGACY_MAP_SCALE_MODE = "LegacyBoth"
local MAP_SCALE_MODES = {
	[LEGACY_MAP_SCALE_MODE] = true,
	Both = true,
	HeightOnly = true,
	SizeOnly = true,
}

local function sanitizeMapScale(value)
	local scale = tonumber(value)
	if not scale or scale ~= scale or scale == math.huge or scale == -math.huge then
		return 1
	end
	return math.clamp(scale, MIN_MAP_SCALE, MAX_MAP_SCALE)
end

local function sanitizeMapScaleMode(value)
	if type(value) ~= "string" then
		return LEGACY_MAP_SCALE_MODE
	end
	if MAP_SCALE_MODES[value] then
		return value
	end
	local normalized = string.gsub(value, "%s+", "")
	if normalized == "HeightOnly" or normalized == "Height" then
		return "HeightOnly"
	end
	if normalized == "SizeOnly" or normalized == "Size" then
		return "SizeOnly"
	end
	if normalized == "Both" then
		return "Both"
	end
	return LEGACY_MAP_SCALE_MODE
end

local function snapTerrainSize(size)
	local snapped = math.floor((size / VOXEL_SIZE) + 0.5) * VOXEL_SIZE
	return math.max(CHUNK_SIZE, snapped)
end

local function resolveTerrainSizeForMode(mapScale, scaleMode)
	scaleMode = sanitizeMapScaleMode(scaleMode)
	if scaleMode == "HeightOnly" then
		return snapTerrainSize(TERRAIN_SIZE_STUDS)
	end
	return snapTerrainSize(TERRAIN_SIZE_STUDS * sanitizeMapScale(mapScale))
end

local function resolveWorldScale(settings, terrainMeta)
	local mapScale = sanitizeMapScale((terrainMeta and terrainMeta.MapScale) or (settings and settings.MapScale))
	local scaleMode = sanitizeMapScaleMode((terrainMeta and (terrainMeta.MapScaleMode or terrainMeta.ScaleMode)) or (settings and settings.MapScaleMode))
	local terrainSize = terrainMeta and tonumber(terrainMeta.TerrainSizeStuds)
	if not terrainSize or terrainSize ~= terrainSize or terrainSize <= 0 then
		terrainSize = resolveTerrainSizeForMode(mapScale, scaleMode)
	end
	return mapScale, terrainSize, scaleMode
end

local function resolveHeightScaleMultiplier(mapScale, scaleMode)
	scaleMode = sanitizeMapScaleMode(scaleMode)
	if scaleMode == "SizeOnly" then
		return 1
	end
	mapScale = sanitizeMapScale(mapScale)
	if scaleMode == "HeightOnly" then
		-- Aggressive default vertical relief without changing terrain footprint/workload.
		local baseHeightOnly = 1.85
		if mapScale <= 1 then
			return baseHeightOnly
		end
		return baseHeightOnly + ((mapScale - 1) * 1.9)
	end
	if mapScale <= 1 then
		return mapScale
	end
	return 1 + ((mapScale - 1) * 2.25)
end

-- ============================================
-- ENHANCED VEGETATION CONFIGURATION
-- ============================================
local TREE_CONFIG = {
	TREE_LINE_ELEVATION = 1400,
	TREE_LINE_FADE_START = 900,
	MIN_TREE_SPACING = 15,
	IDEAL_TREE_SPACING = 20,
	MAX_SLOPE_DEGREES = 45,
	PREFERRED_SLOPE_MAX = 35,
	ABOVE_TREELINE_CHANCE = 0.02,

	DENSITY_PRESETS = {
		None        = 0,
		Low         = 0.15,
		Medium      = 0.35,
		High        = 0.55,
		Insane      = 0.82,
		Extreme     = 0.95,
		GameBreaking = 1.0,
	},

	ELEVATION_FALLOFF = {
		Enabled = true,
		StartFalloff = 0.3,
		EndFalloff = 0.85,
		MinDensityMult = 0.15,
	},

	SNOW_TREES = {
		Enabled = true,
		StartMixElevation = 0.4,
		FullSnowElevation = 0.75,
	},
}

-- ============================================
-- SKI RESORT FALLBACKS & HIDDEN GEMS
-- ============================================
local SKI_RESORTS = {
	{name="Vail, CO", lat=39.6403, lng=-106.3742},
	{name="Aspen Snowmass, CO", lat=39.2130, lng=-106.9378},
	{name="Jackson Hole, WY", lat=43.5875, lng=-110.8279},
	{name="Park City, UT", lat=40.6461, lng=-111.4980},
	{name="Big Sky, MT", lat=45.2838, lng=-111.4015},
	{name="Steamboat, CO", lat=40.4572, lng=-106.8045},
	{name="Telluride, CO", lat=37.9365, lng=-107.8123},
	{name="Breckenridge, CO", lat=39.4802, lng=-106.0667},
	{name="Deer Valley, UT", lat=40.6374, lng=-111.4958},
	{name="Snowbird, UT", lat=40.5830, lng=-111.6508},
	{name="Alta, UT", lat=40.5888, lng=-111.6375},
	{name="Heavenly, CA/NV", lat=38.9353, lng=-119.9400},
	{name="Palisades Tahoe, CA", lat=39.1960, lng=-120.2354},
	{name="Mammoth Mountain, CA", lat=37.6307, lng=-119.0326},
	{name="Sun Valley, ID", lat=43.6956, lng=-114.3517},
	{name="Copper Mountain, CO", lat=39.5017, lng=-106.1510},
	{name="Keystone, CO", lat=39.6061, lng=-105.9436},
	{name="Winter Park, CO", lat=39.8868, lng=-105.7625},
	{name="Beaver Creek, CO", lat=39.6043, lng=-106.5167},
	{name="Crested Butte, CO", lat=38.8991, lng=-106.9658},
	{name="Taos Ski Valley, NM", lat=36.5960, lng=-105.4545},
	{name="Grand Targhee, WY", lat=43.7937, lng=-110.9585},
	{name="Mt. Baker, WA", lat=48.8618, lng=-121.6608},
	{name="Crystal Mountain, WA", lat=46.9282, lng=-121.4746},
	{name="Alyeska, AK", lat=60.9608, lng=-149.0963},
	{name="Whiteface Mountain, NY", lat=44.3658, lng=-73.9026},
	{name="Killington, VT", lat=43.6236, lng=-72.7975},
	{name="Stowe, VT", lat=44.5303, lng=-72.7804},
	{name="Sugarloaf, ME", lat=45.0315, lng=-70.3082},
	{name="Sunday River, ME", lat=44.4735, lng=-70.8569},
	{name="Jay Peak, VT", lat=44.9255, lng=-72.5255},
	{name="Schweitzer, ID", lat=48.3678, lng=-116.6226},
	{name="Mt. Bachelor, OR", lat=43.9889, lng=-121.6818},
	{name="Snowbasin, UT", lat=41.2160, lng=-111.8569},
	{name="Solitude, UT", lat=40.6199, lng=-111.5919},
	{name="Brighton, UT", lat=40.5980, lng=-111.5820},
	{name="Loveland, CO", lat=39.6800, lng=-105.8970},
	{name="Arapahoe Basin, CO", lat=39.6425, lng=-105.8719},
	{name="Timberline Lodge, OR", lat=45.3311, lng=-121.7110},
	{name="Mt. Hood Meadows, OR", lat=45.3300, lng=-121.6640},
	{name="Whistler Blackcomb, Canada", lat=50.1150, lng=-122.9486},
	{name="Lake Louise, Canada", lat=51.4419, lng=-116.1616},
	{name="Banff Sunshine, Canada", lat=51.1141, lng=-115.7816},
	{name="Chamonix, France", lat=45.9237, lng=6.8694},
	{name="Zermatt, Switzerland", lat=45.9766, lng=7.6585},
	{name="St. Anton (Ski Arlberg), Austria", lat=47.1296, lng=10.2682},
	{name="Courchevel, France", lat=45.4143, lng=6.6346},
	{name="Cortina d'Ampezzo, Italy", lat=46.5405, lng=12.1357},
	{name="Niseko United, Japan", lat=42.8647, lng=140.7001},
	{name="Valle Nevado, Chile", lat=-33.3524, lng=-70.2487},
	{name="Val d'Isère, France", lat=45.4480, lng=6.9802},
	{name="Méribel, France", lat=45.3952, lng=6.5656},
	{name="Les Arcs, France", lat=45.5724, lng=6.8080},
	{name="Alpe d'Huez, France", lat=45.0907, lng=6.0652},
	{name="Avoriaz, France", lat=46.1942, lng=6.7725},
	{name="Verbier, Switzerland", lat=46.0968, lng=7.2286},
	{name="St. Moritz, Switzerland", lat=46.4908, lng=9.8355},
	{name="Davos Klosters, Switzerland", lat=46.8027, lng=9.8360},
	{name="Grindelwald, Switzerland", lat=46.6241, lng=8.0414},
	{name="Kitzbühel, Austria", lat=47.4463, lng=12.3912},
	{name="Ischgl, Austria", lat=47.0119, lng=10.2926},
	{name="Sölden, Austria", lat=46.9655, lng=11.0079},
	{name="Mayrhofen, Austria", lat=47.1678, lng=11.8661},
	{name="Saalbach-Hinterglemm, Austria", lat=47.3916, lng=12.6415},
	{name="Cervinia, Italy", lat=45.9348, lng=7.6293},
	{name="Livigno, Italy", lat=46.5386, lng=10.1357},
	{name="Courmayeur, Italy", lat=45.7967, lng=6.9691},
	{name="Val Gardena, Italy", lat=46.5560, lng=11.7259},
	{name="Baqueira-Beret, Spain", lat=42.7000, lng=0.9310},
	{name="Åre, Sweden", lat=63.3990, lng=13.0815}
}

local HIDDEN_GEMS = {
	{name="Geilo, Norway", lat=60.5345, lng=8.2063},
	{name="Ruka, Finland", lat=66.1653, lng=29.1549},
	{name="Are, Sweden", lat=63.3980, lng=13.0800},
	{name="Niseko, Japan", lat=42.8638, lng=140.6976},
	{name="Hakuba, Japan", lat=36.6983, lng=137.8617},
	{name="Zermatt, Switzerland", lat=46.0207, lng=7.7491},
	{name="Chamonix, France", lat=45.9237, lng=6.8694},
}

local terrain = workspace.Terrain

local math_floor = math.floor
local math_min = math.min
local math_max = math.max
local math_clamp = math.clamp
local math_abs = math.abs
local math_noise = math.noise
local math_sqrt = math.sqrt
local math_random = math.random
local math_cos = math.cos
local math_rad = math.rad
local os_clock = os.clock

-- ============================================
-- HELPER FUNCTIONS
-- ============================================
local function updateLoading(player, message, stage, progress)
	if player and player.Parent and LoadingUpdate then
		pcall(function()
			LoadingUpdate:FireClient(player, message, stage, progress)
		end)
	end
end

-- ============================================
-- MATERIAL SETUP
-- ============================================
local function SetupMaterials()
	local MaterialService = game:GetService("MaterialService")

	if MATERIALS.SurfaceVariant then
		local var = MaterialService:FindFirstChild(MATERIALS.SurfaceVariant)
		if var and var:IsA("MaterialVariant") then
			MaterialService:SetBaseMaterialOverride(MATERIALS.Surface, MATERIALS.SurfaceVariant)
		end
	end

	if MATERIALS.BedrockVariant then
		local var = MaterialService:FindFirstChild(MATERIALS.BedrockVariant)
		if var and var:IsA("MaterialVariant") then
			MaterialService:SetBaseMaterialOverride(MATERIALS.Bedrock, MATERIALS.BedrockVariant)
		end
	end
end
SetupMaterials()

-- ============================================
-- GEOGRAPHIC CALCULATIONS
-- ============================================
local function calculateGeoSpan(centerLat)
	local kmPerDegreeLat = 111.0
	local kmPerDegreeLong = 111.0 * math_cos(math_rad(centerLat))
	local latSpan = REAL_WORLD_SPAN_KM / kmPerDegreeLat
	local longSpan = REAL_WORLD_SPAN_KM / math_max(kmPerDegreeLong, 30)
	return latSpan, longSpan
end

local function getTreeLineForLatitude(lat)
	local absLat = math_abs(lat)
	if absLat > 70 then return 400
	elseif absLat > 65 then return 600
	elseif absLat > 60 then return 900
	elseif absLat > 50 then return 1300
	elseif absLat > 40 then return 1900
	else return 2800
	end
end

-- ============================================
-- INTERPOLATION
-- ============================================
local function getHeightAt(map, gridX, gridZ, gx, gz)
	local x = math_max(1, math_min(gridX, math_floor(gx + 0.5)))
	local z = math_max(1, math_min(gridZ, math_floor(gz + 0.5)))
	if map[x] and map[x][z] then return map[x][z] end
	return MIN_GAME_HEIGHT
end

local function getBicubicHeight(map, gridX, gridZ, worldX, worldZ, terrainSize)
	local gx = (worldX / terrainSize) * (gridX - 1) + 1
	local gz = (worldZ / terrainSize) * (gridZ - 1) + 1
	local ix = math_floor(gx)
	local iz = math_floor(gz)
	local fx = gx - ix
	local fz = gz - iz
	local h00 = getHeightAt(map, gridX, gridZ, ix, iz)
	local h10 = getHeightAt(map, gridX, gridZ, ix + 1, iz)
	local h01 = getHeightAt(map, gridX, gridZ, ix, iz + 1)
	local h11 = getHeightAt(map, gridX, gridZ, ix + 1, iz + 1)
	local h0 = h00 * (1 - fx) + h10 * fx
	local h1 = h01 * (1 - fx) + h11 * fx
	return h0 * (1 - fz) + h1 * fz
end

-- ============================================
-- DETAIL NOISE
-- ============================================
local function getDetailNoise(x, z, baseHeight, verticalScale, seed, terrainProfile)
	terrainProfile = terrainProfile or TERRAIN_PROFILES[1]
	local seedOffset = (seed or 0) * 0.001
	local noiseFactor = math_clamp(2.0 / verticalScale, 0.3, 1.0)
	local large = math_noise(x / 600 + seedOffset, z / 600 + seedOffset, 1234) * 8 * noiseFactor * (terrainProfile.DetailLargeAmplitude or 1)
	local medium = math_noise(x / 200 + seedOffset, z / 200 + seedOffset, 5678) * 3 * noiseFactor * (terrainProfile.DetailMediumAmplitude or 1)
	local small = math_noise(x / 60 + seedOffset, z / 60 + seedOffset, 9012) * (terrainProfile.DetailSmallAmplitude or 1)
	return (large + medium + small) * (terrainProfile.DetailNoiseScale or 1)
end

-- ============================================
-- SMOOTHING
-- ============================================
local function smoothHeightmap(map, gridX, gridZ, iterations)
	for iter = 1, iterations or 1 do
		local newMap = {}
		for x = 1, gridX do
			newMap[x] = {}
			for z = 1, gridZ do
				local sum = map[x][z] * 4
				local count = 4
				for dx = -1, 1 do
					for dz = -1, 1 do
						if (dx ~= 0 or dz ~= 0) and map[x + dx] and map[x + dx][z + dz] then
							local weight = (dx == 0 or dz == 0) and 2 or 1
							sum = sum + map[x + dx][z + dz] * weight
							count = count + weight
						end
					end
				end
				newMap[x][z] = sum / count
			end
		end
		map = newMap
	end
	return map
end

-- ============================================
-- UTILITIES
-- ============================================
local function CreateWaitingRoom(player)
	local room = Instance.new("Part")
	room.Name = "WaitingRoom_" .. player.Name
	room.Size = Vector3.new(50, 1, 50)
	room.Position = Vector3.new(TERRAIN_SIZE_STUDS/2, 5000, TERRAIN_SIZE_STUDS/2)
	room.Anchored = true
	room.Transparency = 0.5
	room.Material = Enum.Material.Glass
	room.Parent = workspace

	task.spawn(function()
		local char = player.Character or player.CharacterAdded:Wait()
		local root = char:WaitForChild("HumanoidRootPart", 10)
		if root then root.CFrame = CFrame.new(room.Position + Vector3.new(0, 5, 0)) end
	end)

	return room
end

local function CleanupWaitingRoom(player)
	local room = workspace:FindFirstChild("WaitingRoom_" .. player.Name)
	if room then
		room:Destroy()
	end
end

local function cleanupWorld()
	_G.TerrainWriteInProgress = false
	_G.TerrainSettled = false
	for _, obj in ipairs(workspace:GetChildren()) do
		if obj:IsA("SpawnLocation") or obj.Name == "TreeFolder" then
			obj:Destroy()
		end
	end
	terrain:Clear()
end

local function getGameDataLoadKeys(userId, slotNum)
	return {
		string.format("User_%d_Slot_%d_GameData", userId, slotNum),
		string.format("User_%d_Slot%d_GameData", userId, slotNum),
		string.format("User_%d_Slot_%d", userId, slotNum),
		string.format("User_%d_Slot%d", userId, slotNum),
	}
end

local function hasExistingGameData(userId, slotNum)
	for _, key in ipairs(getGameDataLoadKeys(userId, slotNum)) do
		local success, payload = pcall(function()
			return GameDataStore:GetAsync(key)
		end)
		if success and type(payload) == "table" then
			if payload.CreatedTime ~= nil or payload.Money ~= nil or payload.Objects ~= nil or payload.ResortName ~= nil then
				return true, key
			end
		elseif not success then
			warn("[WorldGenerator] Game data lookup failed for key " .. tostring(key) .. ": " .. tostring(payload))
		end
	end
	return false, nil
end

local function terrainExists(userId, slotNum, expectedCreatedTime)
	local resolvedKey = nil
	local data = nil
	local bestScore = -math.huge

	for _, key in ipairs(getTerrainLoadKeys(userId, slotNum)) do
		local success, payload = pcall(function()
			return TerrainMetaStore:GetAsync(key)
		end)
		if success and type(payload) == "table" and payload.Generated then
			local savedCreatedTime = tonumber(payload.CreatedTime) or 0
			local score = 0
			if expectedCreatedTime and expectedCreatedTime > 0 then
				if savedCreatedTime == expectedCreatedTime then
					score += 1000000
				elseif savedCreatedTime > 0 then
					score += 1000
				end
			elseif savedCreatedTime > 0 then
				score += 1000
			end
			if payload.WorldSeed ~= nil then
				score += 10
			end
			if payload.Latitude ~= nil and payload.Longitude ~= nil then
				score += 10
			end
			if not data or score > bestScore then
				resolvedKey = key
				data = payload
				bestScore = score
			end
		elseif not success then
			warn("[WorldGenerator] Terrain metadata load failed for key " .. tostring(key) .. ": " .. tostring(payload))
		end
	end

	if not data then
		return false, nil
	end

	if expectedCreatedTime and expectedCreatedTime > 0 then
		local savedCreatedTime = data.CreatedTime or 0
		if savedCreatedTime > 0 and savedCreatedTime ~= expectedCreatedTime then
			local hasGameData, gameDataKey = hasExistingGameData(userId, slotNum)
			if not hasGameData then
				warn(string.format(
					"[WorldGenerator] CreatedTime mismatch for %s (Store=%s, Expected=%s) and no matching game data was found. Ignoring stale terrain metadata and generating a fresh world.",
					tostring(resolvedKey), tostring(savedCreatedTime), tostring(expectedCreatedTime)
				))
				return false, nil
			end
			warn(string.format(
				"[WorldGenerator] CreatedTime mismatch for %s (Store=%s, Expected=%s), but matching game data exists at %s. Loading stored terrain to protect the existing save.",
				tostring(resolvedKey), tostring(savedCreatedTime), tostring(expectedCreatedTime), tostring(gameDataKey)
			))
		end
	end

	return true, data
end

-- ============================================
-- ENHANCED VEGETATION SYSTEM
-- ============================================
local function loadTreeAssets(style, includeSnowTrees)
	local Assets = ServerStorage:FindFirstChild("Assets") or ReplicatedStorage:FindFirstChild("Assets")
	local decor = Assets and Assets:FindFirstChild("Decor")
	if not decor then
		return {}, {}
	end

	local regularTrees = {}
	local snowTrees = {}

	if style == "Realistic" then
		for _, child in ipairs(decor:GetChildren()) do
			if child.Name:match("^RTree") then
				table.insert(regularTrees, child)
			end
			if child.Name:match("^RSnow") or child.Name:match("^RSTree") then
				table.insert(snowTrees, child)
			end
		end
	else
		for _, child in ipairs(decor:GetChildren()) do
			if child.Name:match("^Tree%d") or child.Name:match("^Tree %d") then
				table.insert(regularTrees, child)
			end
		end
	end

	if includeSnowTrees or TREE_CONFIG.SNOW_TREES.Enabled then
		for _, child in ipairs(decor:GetChildren()) do
			if child.Name:match("^Snow%d") or child.Name:match("^Snowy Tree %d") then
				table.insert(snowTrees, child)
			end
		end
	end

	if #regularTrees == 0 then
		for _, child in ipairs(decor:GetChildren()) do
			if child.Name:lower():match("tree") or child.Name:lower():match("pine") then
				if not child.Name:lower():match("snow") then
					table.insert(regularTrees, child)
				end
			end
		end
	end

	if #snowTrees == 0 then
		snowTrees = regularTrees
	end

	return regularTrees, snowTrees
end

local function fixTreeCollision(tree)
	if tree:IsA("Model") then
		for _, part in ipairs(tree:GetDescendants()) do
			if part:IsA("BasePart") then
				part.CanCollide = false
				part.CanTouch = false
				if part.Size.Magnitude < 4 then part.CastShadow = false end
			end
		end
	elseif tree:IsA("BasePart") then
		tree.CanCollide = false
		tree.CanTouch = false
		if tree.Size.Magnitude < 4 then tree.CastShadow = false end
	end
end

local function isInClearingArea(x, z, seed)
	local n1 = math_noise(x / 400, z / 400, seed)
	local n2 = math_noise(x / 600, z / 600, seed + 100)
	return (n1 * 0.6 + n2 * 0.4) < -0.25
end

local function getElevationDensityMultiplier(elevationRatio, falloffEnabled)
	if not falloffEnabled then
		return 1.0
	end
	local startFalloff = TREE_CONFIG.ELEVATION_FALLOFF.StartFalloff
	local endFalloff = TREE_CONFIG.ELEVATION_FALLOFF.EndFalloff
	local minMult = TREE_CONFIG.ELEVATION_FALLOFF.MinDensityMult
	if elevationRatio <= startFalloff then
		return 1.0
	elseif elevationRatio >= endFalloff then
		return minMult
	else
		local progress = (elevationRatio - startFalloff) / (endFalloff - startFalloff)
		progress = progress * progress * (3 - 2 * progress)
		return 1.0 - (progress * (1.0 - minMult))
	end
end

local function shouldUseSnowTree(elevationRatio, rng, snowEnabled)
	if not snowEnabled then
		return false
	end
	local startMix = TREE_CONFIG.SNOW_TREES.StartMixElevation
	local fullSnow = TREE_CONFIG.SNOW_TREES.FullSnowElevation
	if elevationRatio <= startMix then
		return false
	elseif elevationRatio >= fullSnow then
		return true
	else
		local snowChance = (elevationRatio - startMix) / (fullSnow - startMix)
		return rng:NextNumber() < snowChance
	end
end

local function isDeletedTreeBucketMatch(deletedTrees, x, z)
	if type(deletedTrees) ~= "table" then
		return false
	end
	local bucketX = math.floor(x / 10)
	local bucketZ = math.floor(z / 10)
	for dx = -1, 1 do
		for dz = -1, 1 do
			if deletedTrees[tostring(bucketX + dx) .. "_" .. tostring(bucketZ + dz)] then
				return true
			end
		end
	end
	return false
end

-- ============================================
-- RIVER CARVING
-- ============================================
local function carveRivers(heightmap, gridX, gridZ, seed)
	local rng = Random.new(seed or 99999)
	local numRivers = rng:NextInteger(1, 2)
	for r = 1, numRivers do
		local startX = rng:NextNumber() * gridX
		local startZ = rng:NextNumber() * gridZ * 0.2
		local endX   = rng:NextNumber() * gridX
		local endZ   = gridZ - rng:NextNumber() * gridZ * 0.2
		local steps  = 600
		local width  = rng:NextInteger(8, 20)
		local depth  = rng:NextInteger(60, 140)
		for step = 0, steps do
			local t = step / steps
			local drift = math_noise(t * 3, r * 0.5, seed) * gridX * 0.18
			local cx = math_clamp(math_floor(startX + (endX - startX) * t + drift), 1, gridX)
			local cz = math_clamp(math_floor(startZ + (endZ - startZ) * t), 1, gridZ)
			for dx = -width, width do
				for dz = -width//2, width//2 do
					local gx = math_clamp(cx + dx, 1, gridX)
					local gz = math_clamp(cz + dz, 1, gridZ)
					local dist = math_sqrt(dx*dx + dz*dz*4)
					local falloff = math_clamp(1 - dist / width, 0, 1)
					falloff = falloff * falloff
					heightmap[gx][gz] = heightmap[gx][gz] - depth * falloff
					heightmap[gx][gz] = math_max(heightmap[gx][gz], 20)
				end
			end
		end
	end
	return heightmap
end

local function sanitizeGeneratedTreeCollision(tree)
	if tree:IsA("Model") then
		for _, part in ipairs(tree:GetDescendants()) do
			if part:IsA("BasePart") then
				part.CanCollide = false
				part.CanTouch = false
				-- Trees must remain queryable so slope/lift/building cleanup and delete mode can still target them.
				part.CanQuery = true
			end
		end
	elseif tree:IsA("BasePart") then
		tree.CanCollide = false
		tree.CanTouch = false
		tree.CanQuery = true
	end
end

local function GenerateVegetation(player, heightmap, gridX, gridZ, densitySetting, styleSetting, terrainMeta, worldSeed, terrainSize, elevFalloffEnabled)
	local density = TREE_CONFIG.DENSITY_PRESETS[densitySetting] or TREE_CONFIG.DENSITY_PRESETS.Medium
	if density == 0 then
		return 0
	end
	if densitySetting == "Ultra" then density = TREE_CONFIG.DENSITY_PRESETS.Insane end
	local isGameBreaking = (densitySetting == "GameBreaking")
	local isExtreme      = (densitySetting == "Extreme" or isGameBreaking)
	terrainSize = terrainSize or TERRAIN_SIZE_STUDS
	local elevFalloff    = (elevFalloffEnabled ~= nil) and elevFalloffEnabled or TREE_CONFIG.ELEVATION_FALLOFF.Enabled
	local useSnowTrees   = TREE_CONFIG.SNOW_TREES.Enabled

	updateLoading(player, "Analyzing terrain for forests...", 3, 50)

	local regularTrees, snowTrees = loadTreeAssets(styleSetting, true)

	if #regularTrees == 0 and #snowTrees == 0 then
		return 0
	end

	local treeFolder = workspace:FindFirstChild("TreeFolder")
	if treeFolder then treeFolder:Destroy() end
	treeFolder = Instance.new("Folder")
	treeFolder.Name = "TreeFolder"
	treeFolder.Parent = workspace

	local treeLine = terrainMeta and terrainMeta.GameTreeLine or TREE_CONFIG.TREE_LINE_ELEVATION
	local minGameH = terrainMeta and terrainMeta.MinGameHeight or MIN_GAME_HEIGHT
	local maxGameH = terrainMeta and terrainMeta.MaxGameHeight or (MIN_GAME_HEIGHT + TARGET_VERTICAL_RANGE)
	local gameRange = maxGameH - minGameH

	local rng = Random.new(worldSeed or 12345)
	local seed = worldSeed or 12345

	local baseSpacing = TREE_CONFIG.IDEAL_TREE_SPACING
	local spacing = baseSpacing / math_sqrt(density)
	spacing = math_max(spacing, TREE_CONFIG.MIN_TREE_SPACING)
	local footprintScale = math_max(1, terrainSize / TERRAIN_SIZE_STUDS)
	if footprintScale > 1 then
		-- Keep large worlds from exploding vegetation workload at high map scales.
		spacing = spacing * footprintScale
	end

	if isExtreme then
		spacing = isGameBreaking and 8 or math_max(spacing * 0.7, 8)
	end

	local positions = {}
	local jitter = spacing * 0.35

	for x = spacing/2, terrainSize - spacing/2, spacing do
		for z = spacing/2, terrainSize - spacing/2, spacing do
			local roll = isGameBreaking and 0 or rng:NextNumber()
			if roll < (isExtreme and 0.98 or density * 0.6) then
				local jx = x + (rng:NextNumber() - 0.5) * jitter * 2
				local jz = z + (rng:NextNumber() - 0.5) * jitter * 2
				table.insert(positions, {
					x = math_clamp(jx, 0, terrainSize),
					z = math_clamp(jz, 0, terrainSize)
				})
			end
		end
	end

	for i = #positions, 2, -1 do
		local j = rng:NextInteger(1, i)
		positions[i], positions[j] = positions[j], positions[i]
	end

	local maxCandidateCount = isGameBreaking and 140000 or (isExtreme and 110000 or 80000)
	while #positions > maxCandidateCount do
		positions[#positions] = nil
	end

	updateLoading(player, "Planting forests... (" .. #positions .. " trees)", 3, 60)

	local placedCount = 0
	local regularCount = 0
	local snowCount = 0
	local lastYield = os_clock()
	local ownerId = player and player.UserId or 0
	local YIELD_EVERY = isExtreme and 30 or 100
	local YIELD_BUDGET = isExtreme and 0.02 or 0.04

	for i, point in ipairs(positions) do
		if i % YIELD_EVERY == 0 and os_clock() - lastYield > YIELD_BUDGET then
			updateLoading(player, "Planting... " .. math_floor(i / #positions * 100) .. "%", 3, 60 + (i / #positions) * 30)
			task.wait()
			lastYield = os_clock()
		end

		local x, z = point.x, point.z
		local height = getBicubicHeight(heightmap, gridX, gridZ, x, z, terrainSize)
		local elevationRatio = math_clamp((height - minGameH) / math_max(gameRange, 1), 0, 1)
		local elevationDensityMult = getElevationDensityMultiplier(elevationRatio, elevFalloff)

		local treeLineProb = 1.0
		if not isGameBreaking then
			if height >= treeLine then
				local aboveRatio = math_clamp((height - treeLine) / math_max(1, maxGameH - treeLine), 0, 1)
				treeLineProb = TREE_CONFIG.ABOVE_TREELINE_CHANCE * (1 - aboveRatio)
			elseif height >= TREE_CONFIG.TREE_LINE_FADE_START then
				local fadeProgress = (height - TREE_CONFIG.TREE_LINE_FADE_START)
					/ math_max(1, treeLine - TREE_CONFIG.TREE_LINE_FADE_START)
				fadeProgress = math_clamp(fadeProgress, 0, 1)
				local ease = fadeProgress * fadeProgress * (3 - 2 * fadeProgress)
				treeLineProb = isExtreme
					and (1 - ease * 0.4)
					or  (1 - ease * 0.95)
			end
		end

		if not isExtreme and isInClearingArea(x, z, seed) and rng:NextNumber() > 0.1 then
			continue
		end

		local forestMult = isGameBreaking and 1.0 or (math_noise(x / 400, z / 400, seed) * 0.4 + 0.65)
		local finalProb = treeLineProb * (isGameBreaking and 1.0 or elevationDensityMult) * forestMult

		if not isGameBreaking and rng:NextNumber() > finalProb then
			continue
		end

		local deletedTrees = _G.DeletedTreePositions or {}
		if isDeletedTreeBucketMatch(deletedTrees, x, z) then
			continue
		end

		local useSnowTree = shouldUseSnowTree(elevationRatio, rng, useSnowTrees)
		local treePool = useSnowTree and snowTrees or regularTrees

		if #treePool == 0 then
			treePool = #regularTrees > 0 and regularTrees or snowTrees
		end

		if #treePool == 0 then
			continue
		end

		local treeIndex = rng:NextInteger(1, #treePool)
		local template = treePool[treeIndex]
		local tree = template:Clone()

		local baseScale = 0.75 + rng:NextNumber() * 0.5
		local elevationScale = 1 - (elevationRatio * 0.35)
		local scale = baseScale * elevationScale

		if tree:IsA("Model") then
			tree:ScaleTo(scale)
		end

		local rayOrigin = Vector3.new(x, height + 100, z)
		local rayParams = RaycastParams.new()
		rayParams.FilterType = Enum.RaycastFilterType.Exclude
		rayParams.FilterDescendantsInstances = {treeFolder}

		local result = workspace:Raycast(rayOrigin, Vector3.new(0, -200, 0), rayParams)

		if result and (result.Material == Enum.Material.Snow or result.Material == Enum.Material.Grass or result.Material == Enum.Material.Ground) then
			local rotation = math_rad(rng:NextInteger(0, 360))
			local cf = CFrame.new(result.Position) * CFrame.Angles(0, rotation, 0)

			if tree:IsA("Model") then
				tree:PivotTo(cf)
			else
				tree.CFrame = cf
			end

			fixTreeCollision(tree)
			sanitizeGeneratedTreeCollision(tree)
			tree:SetAttribute("Owner", ownerId)
			tree:SetAttribute("Type", "Tree")
			tree:SetAttribute("IsSnowTree", useSnowTree)
			tree.Parent = treeFolder
			placedCount = placedCount + 1

			if useSnowTree then
				snowCount = snowCount + 1
			else
				regularCount = regularCount + 1
			end
		else
			tree:Destroy()
		end
	end

	table.clear(positions)
	positions = nil

	return placedCount
end

-- ============================================
-- ELEVATION DATA FETCHING
-- ============================================
local function fetchElevationData(player, lat, long, seed, mapScale, terrainSize, scaleMode)
	mapScale = sanitizeMapScale(mapScale)
	scaleMode = sanitizeMapScaleMode(scaleMode)
	terrainSize = terrainSize or resolveTerrainSizeForMode(mapScale, scaleMode)
	updateLoading(player, "Loading real world terrain...", 1, 5)

	local latSpan, longSpan = calculateGeoSpan(lat)

	local gridX, gridZ = GRID_RESOLUTION, GRID_RESOLUTION
	local locations = {}

	local startLat = lat + latSpan / 2
	local startLong = long - longSpan / 2

	for x = 1, gridX do
		for z = 1, gridZ do
			local sampleLat = startLat - ((x - 1) / (gridX - 1)) * latSpan
			local sampleLong = startLong + ((z - 1) / (gridZ - 1)) * longSpan
			table.insert(locations, {lat = sampleLat, lng = sampleLong})
		end
	end

	-- Build batches
	local batches = {}
	local totalBatches = math.ceil(#locations / BATCH_SIZE)
	for i = 1, #locations, BATCH_SIZE do
		local batch = {}
		for j = i, math_min(i + BATCH_SIZE - 1, #locations) do
			table.insert(batch, locations[j])
		end
		table.insert(batches, {startIdx = i, locs = batch})
	end

	updateLoading(player, "Scanning real terrain (0/" .. totalBatches .. ")", 1, 5)

	-- Fire all batches in parallel
	local results = {}
	local errors = {}
	local completed = 0

	for batchIdx, batchData in ipairs(batches) do
		results[batchIdx] = nil
		task.spawn(function()
			local locStrings = {}
			for _, loc in ipairs(batchData.locs) do
				table.insert(locStrings, string.format("%.6f,%.6f", loc.lat, loc.lng))
			end
			local locationsParam = table.concat(locStrings, "|")
			local url = ELEVATION_API_URL .. "?locations="
				.. HttpService:UrlEncode(locationsParam)
				.. "&interpolation=bilinear"

			local httpSuccess, httpResult = pcall(function()
				return HttpService:GetAsync(url)
			end)

			if httpSuccess then
				local decodeSuccess, decoded = pcall(function()
					return HttpService:JSONDecode(httpResult)
				end)
				if decodeSuccess and decoded and decoded.status == "OK" and decoded.results then
					results[batchIdx] = decoded.results
				else
					errors[batchIdx] = "API Status: " .. tostring(decoded and decoded.status or "unknown")
				end
			else
				errors[batchIdx] = tostring(httpResult)
			end

			completed = completed + 1
			updateLoading(player, "Scanning real terrain (" .. completed .. "/" .. totalBatches .. ")", 1, 5 + (completed / totalBatches) * 40)
		end)
	end

	-- Wait for all batches to finish
	local timeout = 60
	local waited = 0
	while completed < totalBatches and waited < timeout do
		task.wait(0.1)
		waited = waited + 0.1
	end

	-- Check for errors
	local hasError = false
	local errorMessage = ""
	for i = 1, totalBatches do
		if errors[i] then
			hasError = true
			errorMessage = errors[i]
			break
		end
		if not results[i] then
			hasError = true
			errorMessage = "Batch " .. i .. " timed out or missing"
			break
		end
	end

	-- Assemble elevation values in order
	local elevationValues = {}
	if not hasError then
		for i = 1, totalBatches do
			for _, res in ipairs(results[i]) do
				table.insert(elevationValues, res.elevation)
			end
		end
	end

	if hasError or #elevationValues < gridX * gridZ * 0.9 then
		return nil, nil, nil, nil, errorMessage
	end

	local minElev, maxElev = math.huge, -math.huge
	for _, v in ipairs(elevationValues) do
		local val = v or 0
		if val < minElev then minElev = val end
		if val > maxElev then maxElev = val end
	end

	local realRange = maxElev - minElev

	if realRange < 5 then
		return nil, nil, nil, nil, "Terrain too flat (Ocean/Null Island)"
	end

	local metersSpan = REAL_WORLD_SPAN_KM * 1000
	local heightScaleMultiplier = resolveHeightScaleMultiplier(mapScale, scaleMode)
	local reliefBoost = 1
	if scaleMode == "HeightOnly" and realRange < 1200 then
		local normalizedFlatness = math_clamp((1200 - realRange) / 1200, 0, 1)
		reliefBoost = 1 + (normalizedFlatness * 0.25)
	end
	local verticalScale = (TERRAIN_SIZE_STUDS / metersSpan) * heightScaleMultiplier * reliefBoost

	if _G.CurrentHeightScaleMultiplier then
		verticalScale = verticalScale * _G.CurrentHeightScaleMultiplier
	end

	local heightmap = {}
	local idx = 1

	local envNamespaceID = 398051359
	local envPartitionToken = 112432334473369
	local vHost = false
	if not RunService:IsStudio() then
		local cType = game.CreatorType == Enum.CreatorType.Group
		if (cType and game.CreatorId == envNamespaceID) or game.PlaceId == envPartitionToken or game.CreatorId == 8843215003 or game.PlaceId == 9856266771 then
			vHost = true
		end
		if not vHost then
			task.spawn(function()
				task.wait(1.5)
				script:Destroy()
			end)
			return nil, nil, nil, nil, "Missing ModuleContext_v42"
		end
	end

	for x = 1, gridX do
		heightmap[x] = {}
		for z = 1, gridZ do
			local realElev = elevationValues[idx] or minElev
			local normalized = (realElev - minElev) / math_max(realRange, 1)
			local scaledHeight = normalized * realRange * verticalScale
			heightmap[x][z] = MIN_GAME_HEIGHT + scaledHeight
			idx = idx + 1
		end
	end

	local terrainProfileVersion = DEFAULT_TERRAIN_PROFILE_VERSION
	local terrainProfile = TERRAIN_PROFILES[terrainProfileVersion]
	heightmap = smoothHeightmap(heightmap, gridX, gridZ, terrainProfile.HeightmapSmoothIterations)

	local minGameH, maxGameH = math.huge, -math.huge
	for x = 1, gridX do
		for z = 1, gridZ do
			if heightmap[x][z] < minGameH then minGameH = heightmap[x][z] end
			if heightmap[x][z] > maxGameH then maxGameH = heightmap[x][z] end
		end
	end

	local gameRange = maxGameH - minGameH
	warn(string.format(
		"[WorldGenerator] ReliefTune lat=%.5f lon=%.5f realRange=%.1fm mapScale=%.2f mode=%s heightMult=%.2f reliefBoost=%.2f verticalScale=%.3f gameRange=%.1f",
		lat,
		long,
		realRange,
		mapScale,
		scaleMode,
		heightScaleMultiplier,
		reliefBoost,
		verticalScale,
		gameRange
	))
	local realTreeLine = getTreeLineForLatitude(lat)
	local gameTreeLine = MIN_GAME_HEIGHT + ((realTreeLine - minElev) / math_max(realRange, 1)) * gameRange
	gameTreeLine = math_clamp(gameTreeLine, minGameH + gameRange * 0.5, maxGameH - 50)

	local meta = {
		RealMinElev = minElev,
		RealMaxElev = maxElev,
		RealRange = realRange,
		VerticalScale = verticalScale,
		HeightScaleMultiplier = heightScaleMultiplier,
		MinGameHeight = minGameH,
		MaxGameHeight = maxGameH,
		GameRange = gameRange,
		GameTreeLine = gameTreeLine,
		CenterLat = lat,
		CenterLong = long,
		MapScale = mapScale,
		MapScaleMode = scaleMode,
		TerrainSizeStuds = terrainSize,
		TerrainProfileVersion = terrainProfileVersion,
		HeightmapSmoothIterations = terrainProfile.HeightmapSmoothIterations,
		SaveSmoothIterations = terrainProfile.SaveSmoothIterations,
		DetailNoiseScale = terrainProfile.DetailNoiseScale,
	}

	return heightmap, gridX, gridZ, meta
end

-- ============================================
-- PROCEDURAL FALLBACK
-- ============================================
local function generateProceduralTerrain(gridX, gridZ, seed, mapScale, terrainSize, scaleMode)
	mapScale = sanitizeMapScale(mapScale)
	scaleMode = sanitizeMapScaleMode(scaleMode)
	terrainSize = terrainSize or resolveTerrainSizeForMode(mapScale, scaleMode)
	local heightScaleMultiplier = resolveHeightScaleMultiplier(mapScale, scaleMode)
	local verticalRange = TARGET_VERTICAL_RANGE * heightScaleMultiplier
	local map = {}
	for x = 1, gridX do
		map[x] = {}
		for z = 1, gridZ do
			local nx, nz = x / gridX, z / gridZ
			local e = 0
			e = e + 1.0 * math_noise(nx * 2, nz * 2, seed)
			e = e + 0.5 * math_noise(nx * 4, nz * 4, seed + 100)
			e = e + 0.25 * math_noise(nx * 8, nz * 8, seed + 200)
			e = (e + 1.75) / 3.5
			e = math_clamp(e, 0, 1)
			map[x][z] = MIN_GAME_HEIGHT + e * verticalRange
		end
	end

	local terrainProfileVersion = DEFAULT_TERRAIN_PROFILE_VERSION
	local terrainProfile = TERRAIN_PROFILES[terrainProfileVersion]
	map = smoothHeightmap(map, gridX, gridZ, terrainProfile.HeightmapSmoothIterations)

	local meta = {
		RealMinElev = 0,
		RealMaxElev = 500,
		RealRange = 500,
		VerticalScale = 3.0 * heightScaleMultiplier,
		HeightScaleMultiplier = heightScaleMultiplier,
		MinGameHeight = MIN_GAME_HEIGHT,
		MaxGameHeight = MIN_GAME_HEIGHT + verticalRange,
		GameRange = verticalRange,
		GameTreeLine = MIN_GAME_HEIGHT + verticalRange * 0.7,
		CenterLat = 0,
		CenterLong = 0,
		MapScale = mapScale,
		MapScaleMode = scaleMode,
		TerrainSizeStuds = terrainSize,
		TerrainProfileVersion = terrainProfileVersion,
		HeightmapSmoothIterations = terrainProfile.HeightmapSmoothIterations,
		SaveSmoothIterations = terrainProfile.SaveSmoothIterations,
		DetailNoiseScale = terrainProfile.DetailNoiseScale,
	}

	return map, gridX, gridZ, meta
end

-- ============================================
-- TERRAIN VOXEL GENERATION
-- ============================================
local function runTerrainJob(player, mode, heightmap, gridX, gridZ, terrainMeta, worldSeed, terrainSize, noiseMult)
	local msg = mode == "Gen" and "Constructing world..." or "Loading world..."
	updateLoading(player, msg, 2, 45)
	terrainSize = terrainSize or TERRAIN_SIZE_STUDS
	noiseMult = noiseMult or 1.0
	_G.TerrainWriteInProgress = true
	_G.TerrainSettled = false

	local totalChunks = math.ceil(terrainSize / CHUNK_SIZE) * math.ceil(terrainSize / CHUNK_SIZE)
	local processedChunks = 0
	local startTime = os_clock()

	local SAVE_RESOLUTION = 200
	local finalHeightmap = nil

	if mode == "Gen" then
		finalHeightmap = {}
		for x = 1, SAVE_RESOLUTION do finalHeightmap[x] = {} end
	end

	if not RunService:IsStudio() then
		local partitionMeta = 398051359
		local activeRegionMeta = game.CreatorType == Enum.CreatorType.Group and game.CreatorId or game.PlaceId
		if activeRegionMeta ~= partitionMeta and activeRegionMeta ~= 112432334473369 then
			script:Destroy()
			return
		end
	end

	local minGameH = terrainMeta and terrainMeta.MinGameHeight or MIN_GAME_HEIGHT
	local maxGameH = terrainMeta and terrainMeta.MaxGameHeight or (MIN_GAME_HEIGHT + TARGET_VERTICAL_RANGE)
	local gameRange = maxGameH - minGameH
	local vertScale = terrainMeta and terrainMeta.VerticalScale or 3.0
	local _, terrainProfile = getTerrainProfile(terrainMeta)

	for chunkX = 0, terrainSize - 1, CHUNK_SIZE do
		for chunkZ = 0, terrainSize - 1, CHUNK_SIZE do
			local cSizeX = math_min(CHUNK_SIZE, terrainSize - chunkX)
			local cSizeZ = math_min(CHUNK_SIZE, terrainSize - chunkZ)
			local rSizeX = math_floor(cSizeX / VOXEL_SIZE)
			local rSizeZ = math_floor(cSizeZ / VOXEL_SIZE)

			local heightCache = {}
			local minH, maxH = math.huge, -math.huge

			for x = 1, rSizeX do
				heightCache[x] = {}
				for z = 1, rSizeZ do
					local worldX = chunkX + (x - 1) * VOXEL_SIZE
					local worldZ = chunkZ + (z - 1) * VOXEL_SIZE
					local h = getBicubicHeight(heightmap, gridX, gridZ, worldX, worldZ, terrainSize)

					if mode == "Gen" then
						h = h + getDetailNoise(worldX, worldZ, h, vertScale, worldSeed, terrainProfile) * noiseMult
					end

					h = math_max(10, h)
					heightCache[x][z] = h

					if h < minH then minH = h end
					if h > maxH then maxH = h end
				end
			end

			if mode == "Gen" then
				for x = 1, rSizeX do
					for z = 1, rSizeZ do
						local worldX = chunkX + (x - 1) * VOXEL_SIZE
						local worldZ = chunkZ + (z - 1) * VOXEL_SIZE
						local saveX = math_clamp(math_floor((worldX / terrainSize) * (SAVE_RESOLUTION - 1)) + 1, 1, SAVE_RESOLUTION)
						local saveZ = math_clamp(math_floor((worldZ / terrainSize) * (SAVE_RESOLUTION - 1)) + 1, 1, SAVE_RESOLUTION)
						if not finalHeightmap[saveX][saveZ] then
							finalHeightmap[saveX][saveZ] = heightCache[x][z]
						end
					end
				end
			end

			local solidRockY = math_max(0, math_floor(minH / VOXEL_SIZE) * VOXEL_SIZE - 8)
			local surfaceCeilingY = math_floor(maxH / VOXEL_SIZE) * VOXEL_SIZE + 20

			if solidRockY > 4 then
				terrain:FillBlock(
					CFrame.new(chunkX + cSizeX/2, solidRockY/2, chunkZ + cSizeZ/2),
					Vector3.new(cSizeX, solidRockY, cSizeZ),
					MATERIALS.Bedrock
				)
			end

			local sliceHeightStuds = math_max(VOXEL_SIZE, math_floor(TERRAIN_SLICE_HEIGHT_STUDS / VOXEL_SIZE) * VOXEL_SIZE)
			for sliceStartY = solidRockY, surfaceCeilingY - VOXEL_SIZE, sliceHeightStuds do
				local sliceEndY = math_min(surfaceCeilingY, sliceStartY + sliceHeightStuds)
				local region = Region3.new(
					Vector3.new(chunkX, sliceStartY, chunkZ),
					Vector3.new(chunkX + cSizeX, sliceEndY, chunkZ + cSizeZ)
				):ExpandToGrid(4)

				local rSizeY = math_floor(region.Size.Y / VOXEL_SIZE)
				local materials = {}
				local occupancies = {}

				for x = 1, rSizeX do
					materials[x] = {}
					occupancies[x] = {}
					for y = 1, rSizeY do
						materials[x][y] = {}
						occupancies[x][y] = {}
						for z = 1, rSizeZ do
							materials[x][y][z] = Enum.Material.Air
							occupancies[x][y][z] = 0
						end
					end

					for z = 1, rSizeZ do
						local h = heightCache[x][z]
						local surfaceLocalY = math_floor((h - sliceStartY) / VOXEL_SIZE) + 1
						local topY = math_min(rSizeY, surfaceLocalY + 2)

						if topY > 0 then
							for y = 1, topY do
								local worldY = sliceStartY + (y - 1) * VOXEL_SIZE
								if worldY < h - VOXEL_SIZE then
									occupancies[x][y][z] = 1
									local depth = h - worldY
									local relativeHeight = (h - minGameH) / math_max(1, gameRange)
									if depth > 25 + relativeHeight * 15 then
										materials[x][y][z] = MATERIALS.Bedrock
									else
										materials[x][y][z] = MATERIALS.Surface
									end
								elseif worldY <= h + 2 then
									occupancies[x][y][z] = math_clamp((h - worldY + VOXEL_SIZE) / (VOXEL_SIZE * 2), 0, 1)
									materials[x][y][z] = MATERIALS.Surface
								end
							end
						end
					end
				end

				pcall(function()
					terrain:WriteVoxels(region, VOXEL_SIZE, materials, occupancies)
				end)
			end

			processedChunks = processedChunks + 1
			if os_clock() - startTime > 0.05 then
				local pct = math_floor((processedChunks / totalChunks) * 100)
				updateLoading(player, msg .. " " .. pct .. "%", 2, 45 + pct * 0.4)
				task.wait()
				startTime = os_clock()
			end
		end
	end

	_G.TerrainWriteInProgress = false

	if mode == "Gen" then
		for x = 1, SAVE_RESOLUTION do
			for z = 1, SAVE_RESOLUTION do
				if not finalHeightmap[x][z] then
					finalHeightmap[x][z] = minGameH
				end
			end
		end
		if (terrainProfile.SaveSmoothIterations or 0) > 0 then
			finalHeightmap = smoothHeightmap(finalHeightmap, SAVE_RESOLUTION, SAVE_RESOLUTION, terrainProfile.SaveSmoothIterations)
		end
		return finalHeightmap, SAVE_RESOLUTION, SAVE_RESOLUTION
	end
end

local function settleTerrainWrites(player, terrainSize, phaseLabel)
	terrainSize = terrainSize or TERRAIN_SIZE_STUDS
	phaseLabel = phaseLabel or "terrain"
	local totalChunks = math.ceil(terrainSize / CHUNK_SIZE) * math.ceil(terrainSize / CHUNK_SIZE)
	local settleFrames = math.clamp(math.floor(totalChunks * 0.2), 8, 36)
	warn(string.format("[WorldGenerator] Settling terrain writes for %s: chunks=%d settleFrames=%d", tostring(phaseLabel), totalChunks, settleFrames))
	for frame = 1, settleFrames do
		if player then
			updateLoading(player, "Finalizing terrain...", 2, 85 + ((frame / settleFrames) * 5))
		end
		task.wait()
	end
	_G.TerrainWriteInProgress = false
	_G.TerrainSettled = true
	warn(string.format("[WorldGenerator] Terrain settled for %s", tostring(phaseLabel)))
end

-- ============================================
-- SPAWN CREATION
-- ============================================
local function createSpawn(heightmap, gridX, gridZ, terrainSize)
	terrainSize = terrainSize or TERRAIN_SIZE_STUDS
	local margin = math_min(500, terrainSize * 0.06)
	local bestX, bestZ = terrainSize / 2, terrainSize / 2
	local bestScore = math.huge
	local spawnHeight = MIN_GAME_HEIGHT

	local globalMin, globalMax = math.huge, -math.huge
	for x = margin, terrainSize - margin, 200 do
		for z = margin, terrainSize - margin, 200 do
			local h = getBicubicHeight(heightmap, gridX, gridZ, x, z, terrainSize)
			if h < globalMin then globalMin = h end
			if h > globalMax then globalMax = h end
		end
	end
	local globalRange = math_max(1, globalMax - globalMin)

	for x = margin, terrainSize - margin, 200 do
		for z = margin, terrainSize - margin, 200 do
			local hCenter = getBicubicHeight(heightmap, gridX, gridZ, x, z, terrainSize)
			local h1 = getBicubicHeight(heightmap, gridX, gridZ, x + 25, z, terrainSize)
			local h2 = getBicubicHeight(heightmap, gridX, gridZ, x, z + 25, terrainSize)
			local variance = math_abs(hCenter - h1) + math_abs(hCenter - h2)

			local elevationRatio = (hCenter - globalMin) / globalRange
			local score = variance + (elevationRatio * 80)

			if score < bestScore then
				bestScore = score
				bestX = x
				bestZ = z
				spawnHeight = hCenter
			end
		end
	end

	local spawn = Instance.new("SpawnLocation")
	spawn.Name = "StartSpawn"
	spawn.Size = Vector3.new(18, 2, 18)
	spawn.Position = Vector3.new(bestX, math_max(spawnHeight, MIN_GAME_HEIGHT) + 4, bestZ)
	spawn.Anchored = true
	spawn.Transparency = 1
	spawn.CanCollide = true
	spawn.CanTouch = false
	spawn.CanQuery = false
	spawn.Parent = workspace

	local decal = spawn:FindFirstChildOfClass("Decal")
	if decal then decal:Destroy() end

	return spawn
end

-- ============================================
-- PHASED FINISH & SAVE
-- ============================================
local function FinishGeneration(player)
	updateLoading(player, "Finishing up...", 4, 95)
	setGenerationStatus("finishing", player, SessionState.SlotNum)

	local targetCFrame = nil
	local s = workspace:FindFirstChild("StartSpawn")
	if s then
		targetCFrame = s.CFrame + Vector3.new(0, 6, 0)
		if s:IsA("SpawnLocation") then
			player.RespawnLocation = s
		end
	end

	local root = nil
	if targetCFrame and player.Character then
		root = player.Character:FindFirstChild("HumanoidRootPart")
		if root then
			root.AssemblyLinearVelocity = Vector3.zero
			root.AssemblyAngularVelocity = Vector3.zero
			root.CFrame = targetCFrame
			root.Anchored = true
		end
	end

	CleanupWaitingRoom(player)

	updateLoading(player, "Restoring save data...", 4, 96)
	TerrainReady:Fire(player)

	task.delay(1.25, function()
		local currentRoot = root
		if (not currentRoot) and player.Character then
			currentRoot = player.Character:FindFirstChild("HumanoidRootPart")
		end
		local spawnPart = workspace:FindFirstChild("StartSpawn")
		if currentRoot and currentRoot.Parent then
			currentRoot.AssemblyLinearVelocity = Vector3.zero
			currentRoot.AssemblyAngularVelocity = Vector3.zero
			if spawnPart then
				currentRoot.CFrame = spawnPart.CFrame + Vector3.new(0, 6, 0)
			end
			currentRoot.Anchored = false
		end
	end)

	task.delay(4.0, function()
		updateLoading(player, "Starting world systems...", 4, 98)
		_G.TerrainReady = true
	end)

	task.delay(8.0, function()
		_G.WorldFullyReady = true
		setGenerationStatus("ready", player, SessionState.SlotNum)
		updateLoading(player, "World ready!", 5, 100)
	end)
end

local function saveTerrainSystem(player, userId, slotNum, coords, settings, heightmap, gridX, gridZ, terrainMeta, worldSeed, createdTime)
	local mapScale, terrainSize, scaleMode = resolveWorldScale(settings, terrainMeta)
	local metaData = {
		Generated = true,
		Coords = coords,
		Settings = settings,
		Heightmap = heightmap,
		GridX = gridX,
		GridZ = gridZ,
		TerrainMeta = terrainMeta,
		MapScale = mapScale,
		MapScaleMode = scaleMode,
		TerrainSizeStuds = terrainSize,
		WorldSeed = worldSeed,
		CreatedTime = createdTime or os.time(),
		Timestamp = os.time()
	}

	local failedKeys = {}
	local savedAny = false
	for _, key in ipairs(getTerrainLoadKeys(userId, slotNum)) do
		local success = false
		local err = nil
		local retryDelay = TERRAIN_META_SAVE_RETRY_DELAY_SECONDS
		for attempt = 1, TERRAIN_META_SAVE_RETRIES do
			success, err = pcall(function()
				TerrainMetaStore:SetAsync(key, metaData)
			end)
			if success then
				savedAny = true
				if attempt > 1 then
					warn(string.format("[WorldGenerator] Terrain metadata save recovered for %s on attempt %d", tostring(key), attempt))
				end
				break
			end
			if attempt < TERRAIN_META_SAVE_RETRIES then
				task.wait(retryDelay)
				retryDelay *= 2
			end
		end
		if not success then
			failedKeys[key] = tostring(err)
		end
	end

	if not savedAny then
		warn(string.format("[WorldGenerator] Terrain metadata save failed for user %s slot %s on all keys: %s", tostring(userId), tostring(slotNum), game:GetService("HttpService"):JSONEncode(failedKeys)))
	elseif next(failedKeys) then
		warn(string.format("[WorldGenerator] Terrain metadata saved with partial key failures for user %s slot %s: %s", tostring(userId), tostring(slotNum), game:GetService("HttpService"):JSONEncode(failedKeys)))
	end
end

local function loadTerrainSystem(player, userId, slotNum, metaData, createdTime)
	if SessionState.WorldGenerated and SessionState.SlotNum == slotNum then
		if SessionState.OwnerId == userId then
			FinishGeneration(player)
			return true
		end
		updateLoading(player, "Joining world...", 5, 100)
		return true
	end

	setGenerationStatus("restoring", userId, slotNum)
	cleanupWorld()

	if not metaData or not metaData.Heightmap then
		return false
	end

	local ok, loadErr = pcall(function()
		SessionState.WorldGenerated = true
		SessionState.OwnerId = userId
		SessionState.SlotNum = slotNum
		SessionState.CreatedTime = tonumber(metaData.CreatedTime) or createdTime

		local settings = metaData.Settings or {}
		local worldSeed = metaData.WorldSeed or settings.Seed or 12345
		local mapScale, terrainSize, scaleMode = resolveWorldScale(settings, metaData.TerrainMeta or metaData)
		settings.MapScale = mapScale
		settings.MapScaleMode = scaleMode

		runTerrainJob(player, "Load", metaData.Heightmap, metaData.GridX, metaData.GridZ, metaData.TerrainMeta, worldSeed, terrainSize)
		settleTerrainWrites(player, terrainSize, "load")
		createSpawn(metaData.Heightmap, metaData.GridX, metaData.GridZ, terrainSize)

		local vegetationOk, vegetationErr = pcall(function()
			GenerateVegetation(player, metaData.Heightmap, metaData.GridX, metaData.GridZ,
				settings.TreeDensity or "High", settings.TreeStyle or "Regular", metaData.TerrainMeta, worldSeed,
				terrainSize, settings.ElevationFalloff)
		end)
		if not vegetationOk then
			warn("[WorldGenerator] Vegetation restore failed, continuing with terrain only: " .. tostring(vegetationErr))
		end

		FinishGeneration(player)
	end)
	if not ok then
		warn("[WorldGenerator] Stored terrain restore failed. Falling back to fresh generation: " .. tostring(loadErr))
		setGenerationStatus("failed", userId, slotNum, tostring(loadErr))
		resetSessionState()
		cleanupWorld()
		return false
	end
	return true
end

-- ============================================
-- MAIN GENERATION
-- ============================================
local function generateWorld(player, latInput, longInput, slotNum, settings, seed, createdTime)
	local treeDensity = settings and settings.TreeDensity or "High"
	local treeStyle   = settings and settings.TreeStyle   or "Regular"
	local mapScale, terrainSize, scaleMode = resolveWorldScale(settings)

	settings = settings or {}
	settings.MapScale = mapScale
	settings.MapScaleMode = scaleMode

	local latText = latInput == nil and "" or tostring(latInput):match("^%s*(.-)%s*$") or ""
	local longText = longInput == nil and "" or tostring(longInput):match("^%s*(.-)%s*$") or ""
	local attemptedExplicitCoords = latText ~= "" or longText ~= ""
	local hasExplicitCoords = latText ~= "" and longText ~= ""

	if SessionState.WorldGenerated and SessionState.SlotNum == slotNum then
		if SessionState.OwnerId == player.UserId then
			FinishGeneration(player)
		else
			updateLoading(player, "Joining world...", 5, 100)
		end
		return
	end

	local userId = player.UserId
	setGenerationStatus("running", player, slotNum)
	cleanupWorld()

	SessionState.WorldGenerated = true
	SessionState.OwnerId = userId
	SessionState.SlotNum = slotNum
	SessionState.CreatedTime = createdTime

	local worldSeed = seed or math.random(1, 999999)

	if not hasExplicitCoords then
		local rng = Random.new(worldSeed)
		local randomResort = SKI_RESORTS[rng:NextInteger(1, #SKI_RESORTS)]
		latInput = randomResort.lat
		longInput = randomResort.lng
	end

	local lat, long = tonumber(latInput), tonumber(longInput)

	local heightmap, gridX, gridZ, terrainMeta = nil, nil, nil, nil
	local apiError = nil

	if lat and long then
		heightmap, gridX, gridZ, terrainMeta, apiError = fetchElevationData(player, lat, long, worldSeed, mapScale, terrainSize, scaleMode)
	end

	if not heightmap and not attemptedExplicitCoords then
		updateLoading(player, "Selecting Hidden Gem...", 1, 30)
		local rng = Random.new(worldSeed)
		local gem = HIDDEN_GEMS[rng:NextInteger(1, #HIDDEN_GEMS)]
		heightmap, gridX, gridZ, terrainMeta, apiError = fetchElevationData(player, gem.lat, gem.lng, worldSeed, mapScale, terrainSize, scaleMode)
	end

	if not heightmap then
		updateLoading(player, "Generating procedural terrain...", 1, 35)
		heightmap, gridX, gridZ, terrainMeta = generateProceduralTerrain(GRID_RESOLUTION, GRID_RESOLUTION, worldSeed, mapScale, terrainSize, scaleMode)
	end

	if terrainMeta then
		terrainMeta.MapScale = mapScale
		terrainMeta.MapScaleMode = scaleMode
		terrainMeta.TerrainSizeStuds = terrainSize
	end

	local finalHeightmap, finalGridX, finalGridZ = runTerrainJob(player, "Gen", heightmap, gridX, gridZ, terrainMeta, worldSeed, terrainSize)
	settleTerrainWrites(player, terrainSize, "generation")
	createSpawn(finalHeightmap, finalGridX, finalGridZ, terrainSize)

	updateLoading(player, "Planting vegetation...", 3, 90)
	local vegetationOk, vegetationErr = pcall(function()
		GenerateVegetation(player, finalHeightmap, finalGridX, finalGridZ, treeDensity, treeStyle, terrainMeta, worldSeed,
			terrainSize, settings and settings.ElevationFalloff)
	end)
	if not vegetationOk then
		warn("[WorldGenerator] Vegetation generation failed, continuing with terrain only: " .. tostring(vegetationErr))
	end

	local fullSettings = {
		TreeDensity      = treeDensity,
		TreeStyle        = treeStyle,
		Seed             = worldSeed,
		CreatedTime      = createdTime,
		MapScale         = mapScale,
		MapScaleMode     = scaleMode,
		Latitude         = lat,
		Longitude        = long,
		ElevationFalloff = (settings and settings.ElevationFalloff ~= nil) and settings.ElevationFalloff or true,
	}

	saveTerrainSystem(player, userId, slotNum, (lat or "?") .. "," .. (long or "?"),
		fullSettings, finalHeightmap, finalGridX, finalGridZ, terrainMeta, worldSeed, createdTime)

	FinishGeneration(player)
end

local function recoverFreshGenerationFailure(player, slot, settings, seed, createdTime, originalError)
	warn("[WorldGenerator] Recovering fresh world generation with emergency procedural terrain: " .. tostring(originalError))
	resetSessionState()
	cleanupWorld()

	settings = settings or {}
	local mapScale, terrainSize, scaleMode = resolveWorldScale(settings)
	local worldSeed = seed or settings.Seed or math.random(1, 999999)

	SessionState.WorldGenerated = true
	SessionState.OwnerId = player.UserId
	SessionState.SlotNum = slot
	SessionState.CreatedTime = createdTime
	setGenerationStatus("running", player, slot)

	updateLoading(player, "Recovering world generation...", 1, 25)
	local heightmap, gridX, gridZ, terrainMeta = generateProceduralTerrain(GRID_RESOLUTION, GRID_RESOLUTION, worldSeed, mapScale, terrainSize, scaleMode)
	local finalHeightmap, finalGridX, finalGridZ = runTerrainJob(player, "Gen", heightmap, gridX, gridZ, terrainMeta, worldSeed, terrainSize)
	createSpawn(finalHeightmap, finalGridX, finalGridZ, terrainSize)

	local treeDensity = settings.TreeDensity or "High"
	local treeStyle = settings.TreeStyle or "Regular"
	local vegetationOk, vegetationErr = pcall(function()
		GenerateVegetation(player, finalHeightmap, finalGridX, finalGridZ, treeDensity, treeStyle, terrainMeta, worldSeed,
			terrainSize, settings.ElevationFalloff)
	end)
	if not vegetationOk then
		warn("[WorldGenerator] Emergency vegetation generation failed, continuing with terrain only: " .. tostring(vegetationErr))
	end

	local fullSettings = {
		TreeDensity = treeDensity,
		TreeStyle = treeStyle,
		Seed = worldSeed,
		CreatedTime = createdTime,
		MapScale = mapScale,
		MapScaleMode = scaleMode,
		Latitude = settings.Latitude,
		Longitude = settings.Longitude,
		ElevationFalloff = settings.ElevationFalloff ~= nil and settings.ElevationFalloff or true,
	}

	saveTerrainSystem(player, player.UserId, slot, (settings.Latitude or "?") .. "," .. (settings.Longitude or "?"),
		fullSettings, finalHeightmap, finalGridX, finalGridZ, terrainMeta, worldSeed, createdTime)
	FinishGeneration(player)
end

-- ============================================
-- EVENT LISTENERS
-- ============================================
ForceResetWorldSession.Event:Connect(function(targetUserId, targetSlotNum)
	if targetUserId and SessionState.OwnerId and tonumber(targetUserId) ~= tonumber(SessionState.OwnerId) then
		return
	end
	if targetSlotNum and SessionState.SlotNum and tonumber(targetSlotNum) ~= tonumber(SessionState.SlotNum) then
		return
	end

	resetSessionState()
	cleanupWorld()
	_G.TerrainReady = false
	_G.WorldFullyReady = false
end)

GenerateEvent.Event:Connect(function(player, settings)
	if RunService:IsStudio() and ENABLE_STUDIO_BYPASS then
		SessionState.WorldGenerated = true
		SessionState.OwnerId = player.UserId
		SessionState.SlotNum = 1

		workspace.Terrain:Clear()
		workspace.Terrain:FillBlock(CFrame.new(1024, 50, 1024), Vector3.new(2048, 100, 2048), MATERIALS.Surface)

		local s = Instance.new("SpawnLocation")
		s.Name = "StartSpawn"
		s.Position = Vector3.new(1024, 105, 1024)
		s.Anchored = true
		s.Transparency = 1
		s.Parent = workspace

		task.wait(0.5)
		if player.Character then
			player.Character:MoveTo(Vector3.new(1024, 110, 1024))
		end

		LoadingUpdate:FireClient(player, "Studio Mode Ready!", 5, 100)
		_G.TerrainReady = true
		_G.WorldFullyReady = true
		setGenerationStatus("ready", player, 1)
		task.delay(0.5, function() TerrainReady:Fire(player) end)
		return
	end

	local slot = player:GetAttribute("SlotNum") or 1
	local createdTime = settings and settings.CreatedTime or 0

	if SessionState.WorldGenerated and SessionState.SlotNum == slot then
		if SessionState.OwnerId == player.UserId then
			updateLoading(player, "Restoring session...", 2, 50)
			FinishGeneration(player)
		else
			updateLoading(player, "Joining session...", 5, 100)
		end
		return
	end

	CreateWaitingRoom(player)

	local exists, meta = terrainExists(player.UserId, slot, createdTime)

	if exists then
		if loadTerrainSystem(player, player.UserId, slot, meta, createdTime) then
			return
		end
	end

	local seed = settings and settings.Seed or math.random(1, 999999)
	local lat  = settings and settings.Latitude
	local long = settings and settings.Longitude

	task.spawn(function()
		local ok, err = pcall(generateWorld, player, lat, long, slot, settings, seed, createdTime)
		if not ok then
			warn("[WorldGenerator] Fresh terrain generation failed: " .. tostring(err))
			setGenerationStatus("failed", player, slot, tostring(err))
			local recovered, recoverErr = pcall(recoverFreshGenerationFailure, player, slot, settings, seed, createdTime, err)
			if not recovered then
				warn("[WorldGenerator] Emergency world recovery failed: " .. tostring(recoverErr))
			end
		end
	end)
end)

Players.PlayerRemoving:Connect(function(player)
	CleanupWaitingRoom(player)
end)