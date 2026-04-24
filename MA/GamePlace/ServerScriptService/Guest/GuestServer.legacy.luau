--[=[ PATH: ServerScriptService/Guest/GuestServer | TYPE: Script ]=]--
--[[
	👥 GUEST SERVER V10.0 — COMPLETE REWRITE
	
	All guest AI runs on the SERVER for reliability. No more client-side physics hacks.
	
	=== ARCHITECTURE ===
	• Server-authoritative: All decisions, movement, and state on server
	• Client gets updates via attributes + RemoteEvents for UI/speech
	• Integrates with: Lifts, Slopes, Employees, Food, Rental, Rating, Money
	
	=== GUEST LIFECYCLE ===
	1. Spawn at hotel → Idle
	2. Decision engine picks activity based on needs
	3. Walk to destination (Humanoid:MoveTo with pathfinding fallback)
	4. Perform activity (rent gear, eat, ride lift, ski slope)
	5. Satisfaction/needs update continuously
	6. Loop until night or satisfaction drops below threshold
	7. Return to hotel or leave resort
	
	=== STATES ===
	Idle → Deciding → Walking → [Activity] → Idle (loop)
	Activities: RentingGear, Eating, Resting, WaitingForLift, BoardingLift,
	            RidingLift, UnloadingLift, SkiingToSlope, SkiingDown,
	            Crashed, Recovering, Leaving, GoingToHotel, Sleeping
	
	=== INTEGRATIONS ===
	• Config.Items: Building types, lift configs, slope difficulties
	• EmployeeServer: HasLifty/HasChef/HasTech/StaffLevel/StaffEfficiency attributes
	• SlopeRegistry (_G.SlopeRegistry): Slope paths for skiing
	• RatingSystem (_G.RatingSystem): Report guest events for resort rating
	• MoneyServer: AddIncome for guest spending
	• LiftSystem: Chair attachment via attributes
	• DayCycleEvent: Morning spawn, night return
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local PathfindingService = game:GetService("PathfindingService")
local HttpService = game:GetService("HttpService")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local Lighting = game:GetService("Lighting")
local PhysicsService = game:GetService("PhysicsService")
local MarketplaceService = game:GetService("MarketplaceService")
local CollectionService = game:GetService("CollectionService")

-- ============================================================================
-- SERVICES & REFERENCES
-- ============================================================================
local Events = ReplicatedStorage:FindFirstChild("Events") or Instance.new("Folder", ReplicatedStorage)
Events.Name = "Events"

function GetOrCreate(parent, name, className)
	local obj = parent:FindFirstChild(name)
	if not obj then obj = Instance.new(className, parent); obj.Name = name end
	return obj
end

local GuestSpeechEvent = GetOrCreate(Events, "GuestSpeech", "RemoteEvent")
local GuestUpdateEvent = GetOrCreate(Events, "GuestUpdate", "RemoteEvent")
local GuestCountUpdateEvent = GetOrCreate(Events, "GuestCountUpdate", "RemoteEvent")
local NotificationEvent = GetOrCreate(Events, "NotificationEvent", "RemoteEvent")
local TicketPriceEvent = GetOrCreate(Events, "SetTicketPrice", "RemoteEvent")
local TipFloatEvent = GetOrCreate(Events, "TipFloat", "RemoteEvent")
local SlotData = ReplicatedStorage:WaitForChild("SlotData")

function IsResortOpen()
	return SlotData:GetAttribute("ResortOpen") ~= false
end

local ApplySavedTicketPricingFn = Events:FindFirstChild("ApplySavedTicketPricing")
if ApplySavedTicketPricingFn and not ApplySavedTicketPricingFn:IsA("BindableFunction") then
	ApplySavedTicketPricingFn:Destroy()
	ApplySavedTicketPricingFn = nil
end
if not ApplySavedTicketPricingFn then
	ApplySavedTicketPricingFn = Instance.new("BindableFunction")
	ApplySavedTicketPricingFn.Name = "ApplySavedTicketPricing"
	ApplySavedTicketPricingFn.Parent = Events
end

local GetSavedTicketPricingFn = Events:FindFirstChild("GetSavedTicketPricing")
if GetSavedTicketPricingFn and not GetSavedTicketPricingFn:IsA("BindableFunction") then
	GetSavedTicketPricingFn:Destroy()
	GetSavedTicketPricingFn = nil
end
if not GetSavedTicketPricingFn then
	GetSavedTicketPricingFn = Instance.new("BindableFunction")
	GetSavedTicketPricingFn.Name = "GetSavedTicketPricing"
	GetSavedTicketPricingFn.Parent = Events
end

local GuestFolder = ReplicatedStorage:WaitForChild("Guest")
local GuestConfig = require(GuestFolder:WaitForChild("GuestConfig"))
local GuestPhysics = require(GuestFolder:WaitForChild("GuestPhysics"))
local GuestMovement = require(GuestFolder:WaitForChild("GuestMovement"))
local Config = require(ReplicatedStorage:WaitForChild("Config"))
local LiftAssets = ReplicatedStorage:WaitForChild("Assets"):WaitForChild("Lifts")
local EmployeeConfig = require(ReplicatedStorage:WaitForChild("EmployeeConfig"))
local QueueSystem = require(ReplicatedStorage:WaitForChild("QueueSystem"))
local EntitlementManager = require(ReplicatedStorage:WaitForChild("EntitlementManager"))
local SnowGunShared = require(ReplicatedStorage:WaitForChild("SnowGunShared"))

local DOUBLE_GUESTS_PASS_ID = 1708162428
local GUEST_MULTIPLIER_CACHE_TTL = 2

local GuestsFolder = Workspace:FindFirstChild("Guests") or Instance.new("Folder", Workspace)
GuestsFolder.Name = "Guests"

-- Lazy-loaded systems (they may not exist yet)
local MoneySystem, AddIncomeEvent, RatingSystem

function ConnectSystems()
	pcall(function()
		local ms = ServerScriptService:FindFirstChild("MoneyServer", true)
		if not ms then
			local sf = ServerScriptService:FindFirstChild("Server")
			if sf then ms = sf:FindFirstChild("MoneyServer") end
		end
		if ms then
			MoneySystem = ms
			AddIncomeEvent = ms:FindFirstChild("AddIncome")
		end
	end)

	-- Connect/Boot Rating System
	local rsModule = ServerScriptService:FindFirstChild("RatingSystem", true)
	if rsModule and rsModule:IsA("ModuleScript") then RatingSystem = require(rsModule) end

	-- Fallback
	if not RatingSystem then RatingSystem = _G.RatingSystem end
end

task.delay(5, ConnectSystems)
task.delay(15, ConnectSystems) -- Retry

-- PERF FIX: Build a one-time ID→(name, config) lookup so FindConfigItemById is O(1).
local _ConfigIdLookup = nil
function EnsureConfigIdLookup()
	if _ConfigIdLookup then return end
	_ConfigIdLookup = {}
	if Config and Config.Items then
		for itemName, itemConfig in pairs(Config.Items) do
			local id = tonumber(itemConfig.ID)
			if id then
				_ConfigIdLookup[id] = { name = itemName, config = itemConfig }
			end
		end
	end
end

function FindConfigItemById(rawId)
	local targetId = tonumber(rawId)
	if not targetId then
		return nil, nil
	end
	EnsureConfigIdLookup()
	local entry = _ConfigIdLookup[targetId]
	if entry then
		return entry.name, entry.config
	end
	return nil, nil
end

function GetConfigItemForModel(model)
	if not model then
		return nil, nil
	end

	local modelName = model.Name
	local rawId = model:GetAttribute("ID")

	-- Use the shared config resolver so guest logic recognizes both legacy numeric IDs
	-- and modern prefixed save IDs (for example BLDG-...) on restored/placed models.
	if Config and Config.ResolveItem then
		local resolvedName, resolvedConfig = Config.ResolveItem(modelName, rawId)
		if resolvedConfig then
			return resolvedName, resolvedConfig
		end
	end

	local resolvedName, resolvedConfig = FindConfigItemById(rawId)
	if resolvedConfig then
		return resolvedName, resolvedConfig
	end

	local direct = Config.Items[modelName]
	if direct then
		return modelName, direct
	end

	return modelName, nil
end

local SnowmakingSignalsCache = {}
local SNOWMAKING_SIGNAL_CACHE_TTL = 6

local function IsSnowmakingPlacedModel(model)
	return model and model:IsA("Model") and SnowGunShared.IsSnowGunName(model.Name)
end

local function GetSnowmakingSignalsForOwner(userId)
	userId = tonumber(userId) or 0
	if userId <= 0 then
		return { Total = 0, Active = 0, Coverage = 0 }
	end
	local now = os.clock()
	local cached = SnowmakingSignalsCache[userId]
	if cached and (now - (cached.At or 0)) < SNOWMAKING_SIGNAL_CACHE_TTL then
		return cached.Data
	end

	local total = 0
	local active = 0
	local placed = Workspace:FindFirstChild("PlacedObjects")
	if placed then
		for _, obj in ipairs(placed:GetChildren()) do
			if IsSnowmakingPlacedModel(obj) and tonumber(obj:GetAttribute("Owner")) == userId then
				total += 1
				if obj:GetAttribute("State") ~= "Off" or obj:GetAttribute("SnowmakerActive") == true then
					active += 1
				end
			end
		end
	end

	local data = {
		Total = total,
		Active = active,
		Coverage = math.clamp(active / math.max(1, total), 0, 1),
	}
	SnowmakingSignalsCache[userId] = { At = now, Data = data }
	return data
end

local function GetSnowmakingSkiRecoveryBonus(data)
	if not data or tostring(data.State) ~= "SkiingDown" then
		return 0
	end
	local signals = GetSnowmakingSignalsForOwner(data.OwnerId)
	if signals.Active <= 0 then
		return 0
	end
	return math.min(0.18, (signals.Active * 0.025) + (signals.Coverage * 0.08))
end

-- ============================================================================
-- CONSTANTS
-- ============================================================================
local STATE = {
	IDLE          = "Idle",
	DECIDING      = "Deciding",
	WALKING       = "Walking",
	RENTING_GEAR  = "RentingGear",
	EATING        = "Eating",
	RESTING       = "Resting",
	WALKING_TO_LIFT = "WalkingToLift",
	WAITING_LIFT  = "WaitingForLift",
	BOARDING_LIFT = "BoardingLift",
	RIDING_LIFT   = "RidingLift",
	UNLOADING_LIFT= "UnloadingLift",
	SKIING_TO_SLOPE = "SkiingToSlope",
	SKIING_DOWN   = "SkiingDown",
	CRASHED       = "Crashed",
	RECOVERING    = "Recovering",
	LEAVING       = "Leaving",
	GOING_TO_HOTEL= "GoingToHotel",
	SLEEPING      = "Sleeping",
	TAKING_LESSON = "TakingLesson",
	BUYING_TICKET = "BuyingTicket",
	HEALING_MED_CENTER = "HealingMedCenter",
}

local TERRAIN_RAY_PARAMS = RaycastParams.new()
TERRAIN_RAY_PARAMS.FilterType = Enum.RaycastFilterType.Include
TERRAIN_RAY_PARAMS.FilterDescendantsInstances = {Workspace.Terrain}

local PATHFINDING_MIN_DISTANCE = 140
local PATHFINDING_GUEST_LIMIT = 180
local DEBUG_LIFT_RIDE = false

local GetQueueGroundExtras
local ClearLiftCommitment
local IsLiftSelectableForGuest
local TryEnterLiftQueueFromProximity
local CommitGuestToLift
local GuestMatchesOwner
local CountNearbyGuests
local TryStartSkiingDown

-- ============================================================================
-- GUEST REGISTRY
-- ============================================================================
type GuestData = {[string]: any}
type GuestList = {GuestData}
type TicketPricingRecord = {basePrice: number, currentPrice: number, lastManualUpdate: number, dynamicEnabled: boolean}
type CachedSignals = {at: number, data: {[string]: any}}

local AllGuests: {[Model]: GuestData} = {}
local PlayerGuests: {[number]: GuestList} = {}
local FriendCache: {[number]: {number}} = {}
local FriendRotationQueue: {[number]: {number}} = {}
local FriendRecentUsed: {[number]: {number}} = {}
local AvatarDescriptionCache: {[number]: {desc: HumanoidDescription, at: number}} = {}
local AvatarNameCache: {[number]: string} = {}
local AvatarRequestTimestamps: {number} = {}
local AvatarPrefetchCursor: {[number]: number} = {}
local AvatarPrefetchInFlight: {[number]: boolean} = {}
local RuntimeHotelKeyByModel: {[Model]: string} = setmetatable({}, { __mode = "k" })
local TotalGuestCount = 0
local CrashNotifyState: {[number]: {[string]: number}} = {}
local LiftCrowdNotifyState: {[number]: {[string]: number}} = {}
local LiftRerouteStats: {[number]: {windowStart: number, count: number}} = {}
local LiftUnloadFallbackCount: {[string]: number} = {}
local TicketPricingState: {[number]: TicketPricingRecord} = {}
local TicketPricingSignalsCache: {[number]: CachedSignals} = {}
local RuntimeMovementPressure = 1
local RuntimeMovementBudgetPerTick = 0
local RuntimeMovingGuestCount = 0
local RuntimeMoveCommandAgeP95 = 0
local TotalHotelBedCapacitySnapshot = { at = 0, beds = 0 }
local LiftQueueStats = {}  -- { [liftUUID] = { walking, waiting, riding } }
local LiftQueueOrder = {} -- { [liftUUID] = {guestModel1, guestModel2, ...} ordered by queue join time }
local LiftQueueIndexByModel = {} -- { [guestModel] = queueIndex }
local GuestMultiplierCache = {} -- { [userId] = {Value = number, CheckedAt = number} }
local LIFT_QUEUE_SLOT_SPACING = 4.3
local LIFT_QUEUE_MOVE_REFRESH_SECONDS = 0.18
local LIFT_QUEUE_FRONT_HOLD_RADIUS = 6.5
local LIFT_QUEUE_MAX_TRACKED_SLOTS = 80
local LIFT_QUEUE_BOARD_DISTANCE = 13.5
local LIFT_QUEUE_BOARD_EXTENDED_DISTANCE = 18.0
local LIFT_QUEUE_BOARD_EXTENDED_DELAY_SECONDS = 1.0
local TICKET_OFFICE_IN_PERSON_SHARE = 0.60
local TICKET_QUEUE_SLOT_SPACING = 4.25
local POST_UNLOAD_TRANSFER_MIN_RISE = 12
local POST_UNLOAD_TRANSFER_MAX_START_DISTANCE = 260
local POST_UNLOAD_TRANSFER_MAX_ATTEMPTS = 2
local LIFT_QUEUE_MAX_LOADHERE_POINTS = 8
local LIFT_QUEUE_LOADHERE_CACHE_TTL = 2.5
local LiftQueueLoadHereCache = setmetatable({}, { __mode = "k" })

GuestMatchesOwner = function(guestModel, ownerId)
	if ownerId == nil then
		return true
	end
	if not guestModel then
		return false
	end
	local ownerNum = nil
	local guestData = AllGuests[guestModel]
	if guestData then
		ownerNum = tonumber(guestData.OwnerId)
	end
	if ownerNum == nil then
		ownerNum = tonumber(guestModel:GetAttribute("OwnerId"))
			or tonumber(guestModel:GetAttribute("Owner"))
	end
	if ownerNum == nil or ownerNum == 0 then
		return true
	end
	return ownerNum == ownerId
end

CountNearbyGuests = function(centerPos, radius, filterFn)
	if typeof(centerPos) ~= "Vector3" then
		return 0
	end
	local r = math.max(0, tonumber(radius) or 0)
	if r <= 0 then
		return 0
	end
	local cache = _G.__GuestNearbyCacheState
	if not cache then
		cache = {
			cellSize = 72,
			rebuildInterval = 0.22,
			buckets = {},
			lastBuildAt = 0,
			builtForCount = -1,
		}
		_G.__GuestNearbyCacheState = cache
	end
	local now = tick()
	local totalGuests = math.max(0, TotalGuestCount)
	if totalGuests ~= cache.builtForCount or (now - cache.lastBuildAt) >= cache.rebuildInterval then
		local buckets = {}
		local cellSize = math.max(16, tonumber(cache.cellSize) or 72)
		for model, data in pairs(AllGuests) do
			if model and model.Parent and data and data.Root then
				local pos = data.Root.Position
				local cellX = math.floor(pos.X / cellSize)
				local cellZ = math.floor(pos.Z / cellSize)
				local key = tostring(cellX) .. ":" .. tostring(cellZ)
				local bucket = buckets[key]
				if not bucket then
					bucket = {}
					buckets[key] = bucket
				end
				bucket[#bucket + 1] = model
			end
		end
		cache.buckets = buckets
		cache.lastBuildAt = now
		cache.builtForCount = totalGuests
	end
	local cellSize = math.max(16, tonumber(cache.cellSize) or 72)
	local minCellX = math.floor((centerPos.X - r) / cellSize)
	local maxCellX = math.floor((centerPos.X + r) / cellSize)
	local minCellZ = math.floor((centerPos.Z - r) / cellSize)
	local maxCellZ = math.floor((centerPos.Z + r) / cellSize)
	local rSquared = r * r
	local count = 0
	local buckets = cache.buckets or {}
	for cellX = minCellX, maxCellX do
		for cellZ = minCellZ, maxCellZ do
			local bucket = buckets[tostring(cellX) .. ":" .. tostring(cellZ)]
			if bucket then
				for i = 1, #bucket do
					local guestModel = bucket[i]
					local data = guestModel and AllGuests[guestModel] or nil
					local root = data and data.Root
					if root and guestModel.Parent then
						local dx = root.Position.X - centerPos.X
						local dz = root.Position.Z - centerPos.Z
						if (dx * dx + dz * dz) <= rSquared then
							if not filterFn or filterFn(guestModel) then
								count += 1
							end
						end
					end
				end
			end
		end
	end
	return count
end

local GUEST_COLLISION_GROUP = "GuestNPC"
pcall(function()
	PhysicsService:RegisterCollisionGroup(GUEST_COLLISION_GROUP)
	PhysicsService:RegisterCollisionGroup("SlopeNet")
end)
pcall(function()
	PhysicsService:CollisionGroupSetCollidable(GUEST_COLLISION_GROUP, GUEST_COLLISION_GROUP, false)
	PhysicsService:CollisionGroupSetCollidable(GUEST_COLLISION_GROUP, "SlopeNet", false)
	-- Player characters (and most world tools) use Default; nets are visual/safety for NPCs only.
	PhysicsService:CollisionGroupSetCollidable("Default", "SlopeNet", false)
end)

local REPUTATION_MULTIPLIER = 1.0

-- Validate core infrastructure metadata
function ValidateInfrastructure()
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
if not ValidateInfrastructure() then return end

-- ============================================================================
-- UTILITY FUNCTIONS
-- ============================================================================
function GetTerrainY(x, z)
	local res = Workspace:Raycast(Vector3.new(x, 5000, z), Vector3.new(0, -10000, 0), TERRAIN_RAY_PARAMS)
	return res and res.Position.Y or 100
end

function GetGroundPos(pos)
	local y = GetTerrainY(pos.X, pos.Z)
	return Vector3.new(pos.X, y + 3.5, pos.Z) -- PATCHED: was y+3, too low for R6 characters
end

local WalkableGroundIncludeCache = {
	at = 0,
	dirty = true,
	list = { Workspace.Terrain },
}

function MarkWalkableGroundCacheDirty()
	WalkableGroundIncludeCache.dirty = true
end

function AddUniqueGroundInstance(list, seen, inst)
	if not inst or not inst.Parent or seen[inst] then
		return
	end
	seen[inst] = true
	table.insert(list, inst)
end

function IsWalkableGroundTypeName(typeName)
	if type(typeName) ~= "string" then
		return false
	end
	local normalized = string.lower(typeName)
	return normalized == "path"
		or normalized == "walkway"
		or normalized == "queue"
		or normalized == "queue path"
		or normalized == "queuepath"
		or normalized == "plaza"
		or normalized == "platform"
		or normalized == "road"
		or normalized == "spawn"
		or normalized == "spawnpad"
		or normalized == "slope"
		or normalized == "trail"
end

function IsLiftGroundTypeName(typeName)
	return typeName == "TwoPoint" or typeName == "Carpet" or typeName == "Lift"
end

function RebuildWalkableGroundIncludeCache()
	local list = {}
	local seen = {}
	AddUniqueGroundInstance(list, seen, Workspace.Terrain)

	local placedObjects = Workspace:FindFirstChild("PlacedObjects")
	if placedObjects then
		for _, obj in ipairs(placedObjects:GetChildren()) do
			if not obj:IsA("Model") then
				continue
			end

			local objType = obj:GetAttribute("Type")
			local objCategory = obj:GetAttribute("Category")
			local _, itemCfg = GetConfigItemForModel(obj)
			local cfgType = itemCfg and itemCfg.Type
			local cfgCategory = itemCfg and itemCfg.Category

			if IsWalkableGroundTypeName(objType) or IsWalkableGroundTypeName(cfgType) or IsWalkableGroundTypeName(objCategory) or IsWalkableGroundTypeName(cfgCategory) then
				AddUniqueGroundInstance(list, seen, obj)
			elseif IsLiftGroundTypeName(objType) or IsLiftGroundTypeName(cfgType) or IsLiftGroundTypeName(objCategory) or IsLiftGroundTypeName(cfgCategory) then
				AddUniqueGroundInstance(list, seen, obj:FindFirstChild("StartStation"))
				AddUniqueGroundInstance(list, seen, obj:FindFirstChild("EndStation"))
			end
		end
	end

	WalkableGroundIncludeCache.at = tick()
	WalkableGroundIncludeCache.dirty = false
	WalkableGroundIncludeCache.list = list
end

function GetWalkableGroundIncludeList(extraInstances)
	if WalkableGroundIncludeCache.dirty or (tick() - (WalkableGroundIncludeCache.at or 0)) > 2 then
		RebuildWalkableGroundIncludeCache()
	end

	local list = {}
	local seen = {}
	for _, inst in ipairs(WalkableGroundIncludeCache.list) do
		AddUniqueGroundInstance(list, seen, inst)
	end

	local function addExtra(extraInst)
		AddUniqueGroundInstance(list, seen, extraInst)
	end

	if typeof(extraInstances) == "Instance" then
		addExtra(extraInstances)
	elseif type(extraInstances) == "table" then
		for _, extraInst in ipairs(extraInstances) do
			addExtra(extraInst)
		end
	end

	return list
end

function ResolveWalkableGroundPos(pos: Vector3, extraInstances, preserveHigherTargetY: boolean?): Vector3
	local fallbackPos = GetGroundPos(pos)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = GetWalkableGroundIncludeList(extraInstances)
	params.IgnoreWater = true

	local originY = math.max((pos.Y + 80), (fallbackPos.Y + 80))
	local ray = Workspace:Raycast(Vector3.new(pos.X, originY, pos.Z), Vector3.new(0, -420, 0), params)
	if ray then
		local resolved = Vector3.new(pos.X, ray.Position.Y + 3.5, pos.Z)
		local terrainDelta = resolved.Y - fallbackPos.Y
		local hasExtraGround = false
		if typeof(extraInstances) == "Instance" then
			hasExtraGround = extraInstances.Parent ~= nil
		elseif type(extraInstances) == "table" then
			hasExtraGround = #extraInstances > 0
		end
		local maxAboveTerrain = hasExtraGround and 22 or 10
		local minBelowTerrain = hasExtraGround and -6 or -1.5
		if terrainDelta <= maxAboveTerrain and terrainDelta >= minBelowTerrain then
			return resolved
		end
	end
	if preserveHigherTargetY and pos.Y > fallbackPos.Y and (pos.Y - fallbackPos.Y) <= 8 then
		return Vector3.new(pos.X, pos.Y, pos.Z)
	end
	return fallbackPos
end

function IsOutsideHotelBounds(boxCF, boxSize, worldPos, padding)
	local localPos = boxCF:PointToObjectSpace(worldPos)
	local pad = tonumber(padding) or 0
	local halfX = (boxSize.X * 0.5) + pad
	local halfZ = (boxSize.Z * 0.5) + pad
	return math.abs(localPos.X) > halfX or math.abs(localPos.Z) > halfZ
end

function ResolveHotelSpawnPos(hotel)
	local boxCF, boxSize = hotel:GetBoundingBox()
	local baseOutward = math.max(16, math.max(boxSize.X, boxSize.Z) * 0.35)
	local candidateDirs = {
		GetFlatLookVector(boxCF.LookVector, Vector3.new(0, 0, -1)),
		GetFlatLookVector(-boxCF.LookVector, Vector3.new(0, 0, 1)),
		GetFlatLookVector(boxCF.RightVector, Vector3.new(1, 0, 0)),
		GetFlatLookVector(-boxCF.RightVector, Vector3.new(-1, 0, 0)),
	}

	for _, dir in ipairs(candidateDirs) do
		local axisDotZ = math.abs(dir:Dot(GetFlatLookVector(boxCF.LookVector, Vector3.new(0, 0, -1))))
		local extent = axisDotZ >= 0.5 and (boxSize.Z * 0.5) or (boxSize.X * 0.5)
		local candidate = GetGroundPos(boxCF.Position + (dir * (extent + baseOutward)))
		if IsOutsideHotelBounds(boxCF, boxSize, candidate, 10) then
			return candidate
		end
	end

	local fallback = GetFlatLookVector(boxCF.LookVector, Vector3.new(0, 0, -1))
	return GetGroundPos(boxCF.Position + (fallback * ((boxSize.Z * 0.5) + baseOutward + 10)))
end

function ResolveGuestLeaveTarget(data)
	local root = data and data.Root
	local currentPos = root and root.Position or Vector3.new(0, 100, 0)
	local boxCF = CFrame.new(currentPos)
	local boxSize = Vector3.new(40, 20, 40)

	if data and data.HotelModel and data.HotelModel.Parent then
		boxCF, boxSize = data.HotelModel:GetBoundingBox()
	end

	local awayFromHotel = Vector3.new(currentPos.X - boxCF.Position.X, 0, currentPos.Z - boxCF.Position.Z)
	if awayFromHotel.Magnitude < 0.1 then
		awayFromHotel = GetFlatLookVector(boxCF.LookVector, Vector3.new(math.random() - 0.5, 0, math.random() - 0.5))
	end
	local leaveDir = GetFlatLookVector(awayFromHotel, Vector3.new(0, 0, -1))
	local leaveDistance = math.max(90, math.max(boxSize.X, boxSize.Z) + 55)
	return ResolveWalkableGroundPos(currentPos + (leaveDir * leaveDistance), nil, false)
end

function RescueGuestFromVoid(data)
	if not data or not data.Root or not data.Model or not data.Model.Parent then
		return false
	end

	local pos = data.Root.Position
	if pos.Y > -40 then
		return false
	end

	if data.State == STATE.LEAVING then
		RemoveGuest(data)
		return true
	end

	local rescuePos = nil
	if data.TargetLift and data.TargetLift.Parent then
		rescuePos = select(1, GetLiftQueueLinePose(data.TargetLift)) or GetLiftStartPos(data.TargetLift)
	elseif data.HotelModel and data.HotelModel.Parent then
		rescuePos = ResolveHotelSpawnPos(data.HotelModel)
	elseif data.TargetSlope and data.TargetSlope.Parent then
		local slopePath = GetSlopeData(data.TargetSlope)
		if slopePath and #slopePath > 1 then
			local entryIndex = tonumber(data.TargetSlopeEntryIndex) or 1
			rescuePos = GetSlopeEntryPosition(slopePath, entryIndex) or GetGroundPos(slopePath[entryIndex] or slopePath[1])
		end
	end
	if not rescuePos then
		rescuePos = GetGroundPos(Vector3.new(pos.X, 0, pos.Z))
	end

	data.TargetSlope = nil
	data.TargetSlopeEntryIndex = nil
	data.TargetBuilding = nil
	data.MoveTarget = nil
	data.Waypoints = nil
	data.MoveCallback = nil
	data.MoveResumeTarget = nil
	data.MoveResumeCallback = nil
	data.StuckTimer = 0
	NormalizeGuestUpright(data, rescuePos)
	data.State = STATE.DECIDING
	data.IdleTimer = -0.25
	return true
end

function IsGuestInsideHotelInterior(data)
	if not data or not data.Root then
		return false
	end
	local hotelModel = data.HotelModel
	if not hotelModel or not hotelModel.Parent then
		return false
	end
	local boxCF, boxSize = hotelModel:GetBoundingBox()
	local localPos = boxCF:PointToObjectSpace(data.Root.Position)
	local insetX = math.max(4, (boxSize.X * 0.5) - 4)
	local insetZ = math.max(4, (boxSize.Z * 0.5) - 4)
	return math.abs(localPos.X) <= insetX
		and math.abs(localPos.Z) <= insetZ
		and math.abs(localPos.Y) <= ((boxSize.Y * 0.5) + 10)
end

function SnapGuestOutsideHotelIfInside(data)
	if not data or not data.Root then
		return false
	end
	local state = data.State
	if state == STATE.SLEEPING or state == STATE.GOING_TO_HOTEL then
		return false
	end
	if not IsGuestInsideHotelInterior(data) then
		return false
	end

	local outsidePos = ResolveHotelSpawnPos(data.HotelModel)
	local forward = GetSafeFlatDirection(outsidePos - data.Root.Position, data.Root.CFrame.LookVector)
	data.Root.CFrame = CFrame.lookAt(outsidePos, outsidePos + forward)
	data.Root.AssemblyLinearVelocity = Vector3.zero
	data.Root.AssemblyAngularVelocity = Vector3.zero
	data.NextGroundSnapAt = 0
	data.LastMovePos = outsidePos
	data.LastMoveCommandTime = nil
	data.LastMoveCommandTarget = nil
	if state == STATE.WAITING_LIFT then
		data.LastQueueMoveIssuedAt = nil
	end
	return true
end

function GetFlatLookVector(vec, fallback)
	local v = vec or fallback or Vector3.new(0, 0, 1)
	v = Vector3.new(v.X, 0, v.Z)
	if v.Magnitude < 0.01 then
		return Vector3.new(0, 0, 1)
	end
	return v.Unit
end

function GetMovementExtraGroundInstances(data)
	if not data then
		return nil
	end

	local lift = data.TargetLift
	if not (lift and lift.Parent) then
		return nil
	end

	local stationName = nil
	if data.State == STATE.WALKING_TO_LIFT then
		stationName = "StartStation"
	elseif data.State == STATE.UNLOADING_LIFT then
		stationName = "EndStation"
	end
	if not stationName then
		return nil
	end

	local station = lift:FindFirstChild(stationName)
	if station then
		return { station }
	end
	return nil
end

function ResolveMovementTargetPos(data, targetPos: Vector3): Vector3
	return ResolveWalkableGroundPos(targetPos, GetMovementExtraGroundInstances(data), false)
end

function ShouldGroundSnapState(state)
	return state ~= STATE.SKIING_DOWN
		and state ~= STATE.RIDING_LIFT
		and state ~= STATE.CRASHED
		and state ~= STATE.RECOVERING
end

function SnapGuestToGroundIfFloating(data: GuestData, hoverThreshold: number?): boolean
	if true then return false end
	if not data or not data.Root or not data.Humanoid then return false end
	local root = data.Root
	local hum = data.Humanoid
	if root.Anchored or hum.PlatformStand then return false end
	if not ShouldGroundSnapState(data.State) then return false end

	-- PATCHED: Removed Freefall bail-out — that's exactly when flying guests need snapping.
	-- Only skip if actively jumping upward.
	local humState = hum:GetState()
	if humState == Enum.HumanoidStateType.Jumping then
		return false
	end

	local lv = root.AssemblyLinearVelocity
	if lv.Y > 12 then -- only skip if actively moving up fast (jumping)
		return false
	end

	local pos = root.Position
	local groundPos = ResolveWalkableGroundPos(pos, GetMovementExtraGroundInstances(data), false)

	local offsetFromGround = pos.Y - groundPos.Y
	-- CRITICAL FIX: Don't snap guests who are on lifts, skiing, or crashing
	local snapState = data.State
	if snapState == STATE.RIDING_LIFT or snapState == STATE.SKIING_DOWN
		or snapState == STATE.CRASHED or snapState == STATE.RECOVERING
		or snapState == STATE.BOARDING_LIFT then
		return false
	end
	local threshold = hoverThreshold or 3.5 -- PATCHED: was 1.75 which caused aggressive snapping/jitter. With HRP collision now enabled, Humanoid physics handles ground contact naturally.
	if math.abs(offsetFromGround) <= threshold then
		return false
	end

	local look = GetFlatLookVector(root.CFrame.LookVector, Vector3.new(0, 0, 1))
	local snappedPos = Vector3.new(pos.X, groundPos.Y, pos.Z)
	root.CFrame = CFrame.lookAt(snappedPos, snappedPos + look)
	root.AssemblyLinearVelocity = Vector3.new(lv.X * 0.35, 0, lv.Z * 0.35)
	root.AssemblyAngularVelocity = Vector3.zero
	return true
end

function FlatDist(a, b)
	return (Vector3.new(a.X, 0, a.Z) - Vector3.new(b.X, 0, b.Z)).Magnitude
end

function IsSummerSeason()
	-- PATCHED: Guests should ski year-round. Summer no longer blocks ski activity.
	return false
end

local _perf = {cache = nil, at = 0}
function GetPerformanceConfig()
	local now = tick()
	if _perf.cache and (now - _perf.at) < 2 then
		return _perf.cache
	end
	local cfg = GuestConfig.Performance or {}
	_perf.cache = {
		MovementCommandRefreshSeconds = math.max(0.06, tonumber(cfg.MovementCommandRefreshSeconds) or 0.12),
		MovementStuckCheckHz = math.max(2, tonumber(cfg.MovementStuckCheckHz) or 7),
		DecisionHzLowLoad = math.max(1.2, tonumber(cfg.DecisionHzLowLoad) or 8),
		DecisionHzHighLoad = math.max(1.2, tonumber(cfg.DecisionHzHighLoad) or 5),
		SkiServerHz = math.max(8, tonumber(cfg.SkiServerHz) or 30),
		MaxMovementGuestsPerTick = math.max(40, math.floor(tonumber(cfg.MaxMovementGuestsPerTick) or 200)),
		MinMovementGuestsPerTick = math.max(8, math.floor(tonumber(cfg.MinMovementGuestsPerTick) or 24)),
		MaxMovementGuestsPerTickDynamic = math.max(24, math.floor(tonumber(cfg.MaxMovementGuestsPerTickDynamic) or 120)),
		MaxSkiGuestsPerTick = math.max(16, math.floor(tonumber(cfg.MaxSkiGuestsPerTick) or 80)),
		MinDecisionGuestsPerTick = math.max(8, math.floor(tonumber(cfg.MinDecisionGuestsPerTick) or 28)),
		MaxDecisionGuestsPerTick = math.max(24, math.floor(tonumber(cfg.MaxDecisionGuestsPerTick) or 96)),
		MaxDecisionGuestsPerTickDynamic = math.max(48, math.floor(tonumber(cfg.MaxDecisionGuestsPerTickDynamic) or 200)),
		DecisionTargetRevisitSeconds = math.max(0.35, tonumber(cfg.DecisionTargetRevisitSeconds) or 2.0),
		RuntimeCandidateRefreshSeconds = math.max(0.25, tonumber(cfg.RuntimeCandidateRefreshSeconds) or 0.9),
		UseServerOwnedWalkers = cfg.UseServerOwnedWalkers ~= false,
		TargetMovementRevisitSeconds = math.max(0.12, tonumber(cfg.TargetMovementRevisitSeconds) or 0.22),
		MovementPressureSoftLimit = math.max(0.65, tonumber(cfg.MovementPressureSoftLimit) or 0.95),
		MovementPressureHardLimit = math.max(0.85, tonumber(cfg.MovementPressureHardLimit) or 1.35),
		PathfindingDirectMoveDistance = math.max(8, tonumber(cfg.PathfindingDirectMoveDistance) or 32),
		PathfindingFailureRepathLimit = math.max(1, math.floor(tonumber(cfg.PathfindingFailureRepathLimit) or 3)),
	}
	_perf.at = now
	return _perf.cache
end

function ApplyWalkerNetworkOwnership(root: BasePart?, perfOverride: {[string]: any}?)
	if not root then return end
	-- PATCHED: Force server ownership. Auto ownership assigns ALL NPCs to the
	-- solo player in Studio, overloading the client and causing slow-motion walking.
	-- Server-owned humanoids with MoveTo work correctly when the movement budget
	-- system refreshes commands frequently enough.
	pcall(function()
		root:SetNetworkOwner(nil) -- Server ownership (works with collision fix)
	end)
end

function GetAvatarCacheConfig()
	local spawnCfg = GuestConfig.Spawn or {}
	local cacheCfg = spawnCfg.AvatarCache or {}
	return {
		FriendFetchCap = math.max(20, math.floor(tonumber(cacheCfg.FriendFetchCap) or 200)),
		DescriptionCacheTTLSeconds = math.max(60, tonumber(cacheCfg.DescriptionCacheTTLSeconds) or 900),
		DescriptionPrefetchPerCycle = math.max(1, math.floor(tonumber(cacheCfg.DescriptionPrefetchPerCycle) or 16)),
		MaxAvatarRequestsPerSecond = math.max(1, tonumber(cacheCfg.MaxAvatarRequestsPerSecond) or 10),
		FallbackGenericChanceWhenBacklogged = math.clamp(tonumber(cacheCfg.FallbackGenericChanceWhenBacklogged) or 0.55, 0, 1),
		PreferGenericThreshold = math.max(0, math.floor(tonumber(cacheCfg.PreferGenericThreshold) or 450)),
		ForceGenericThreshold = math.max(0, math.floor(tonumber(cacheCfg.ForceGenericThreshold) or 900)),
	}
end

function GetDirectorConfig()
	local spawnCfg = GuestConfig.Spawn or {}
	local cfg = spawnCfg.Director or {}
	return {
		TargetFillAggressiveness = math.clamp(tonumber(cfg.TargetFillAggressiveness) or 0.22, 0.05, 0.8),
		MaxSpawnWorkers = math.max(1, math.floor(tonumber(cfg.MaxSpawnWorkers) or 8)),
		SpawnBacklogHardCap = math.max(500, math.floor(tonumber(cfg.SpawnBacklogHardCap) or 3000)),
	}
end

function PruneAvatarRequestTimestamps(now: number)
	local i = 1
	while i <= #AvatarRequestTimestamps do
		if now - AvatarRequestTimestamps[i] > 1 then
			table.remove(AvatarRequestTimestamps, i)
		else
			i += 1
		end
	end
end

function TryConsumeAvatarRequestSlot()
	local cfg = GetAvatarCacheConfig()
	local now = tick()
	PruneAvatarRequestTimestamps(now)
	if #AvatarRequestTimestamps >= cfg.MaxAvatarRequestsPerSecond then
		return false
	end
	table.insert(AvatarRequestTimestamps, now)
	return true
end

function HasFreshCachedDescription(userId: number): boolean
	local entry = AvatarDescriptionCache[userId]
	if not entry or not entry.desc then return false end
	local ttl = GetAvatarCacheConfig().DescriptionCacheTTLSeconds
	if (tick() - (entry.at or 0)) > ttl then
		AvatarDescriptionCache[userId] = nil
		return false
	end
	return true
end

function GetCachedDescription(userId: number)
	if not HasFreshCachedDescription(userId) then
		return nil
	end
	local entry = AvatarDescriptionCache[userId]
	if not entry or not entry.desc then
		return nil
	end
	return entry.desc:Clone()
end

function CacheDescription(userId: number, desc: HumanoidDescription)
	if not userId or not desc then return end
	AvatarDescriptionCache[userId] = {
		desc = desc:Clone(),
		at = tick(),
	}
end

function CacheAvatarName(userId: number, name: string)
	if not userId or userId <= 0 then return end
	if type(name) ~= "string" or name == "" then return end
	AvatarNameCache[userId] = name
end

function GetCachedAvatarName(userId: number): string?
	local cached = AvatarNameCache[userId]
	if cached and cached ~= "" then
		return cached
	end
	return nil
end

local FALLBACK_AVATAR_USER_IDS = { 261, 1, 156, 302, 8439, 200001863, 47662061 }
local FALLBACK_GUEST_PALETTES = {
	{ Head = "Light orange", Torso = "Institutional white", Arms = "Institutional white", Legs = "Dark stone grey" },
	{ Head = "Pastel brown", Torso = "Pastel yellow", Arms = "Pastel yellow", Legs = "Dark blue" },
	{ Head = "Nougat", Torso = "Cyan", Arms = "Cyan", Legs = "Navy blue" },
	{ Head = "Brick yellow", Torso = "Light stone grey", Arms = "Light stone grey", Legs = "Black" },
	{ Head = "Brown", Torso = "White", Arms = "White", Legs = "Reddish brown" },
}
local fallbackAvatarCursor = 0
local FallbackAvatarDescriptions = {}
local GenericGuestTemplate: Model? = nil
local EnsureAvatarNameAsync: ((number) -> ())?

local function GetFallbackPalette(seed: number)
	local index = ((math.abs(seed) % #FALLBACK_GUEST_PALETTES) + 1)
	return FALLBACK_GUEST_PALETTES[index]
end

local function ApplyFallbackPaletteToDescription(desc: HumanoidDescription, seed: number)
	local palette = GetFallbackPalette(seed)
	pcall(function() desc.HeadColor = BrickColor.new(palette.Head) end)
	pcall(function() desc.TorsoColor = BrickColor.new(palette.Torso) end)
	pcall(function() desc.LeftArmColor = BrickColor.new(palette.Arms) end)
	pcall(function() desc.RightArmColor = BrickColor.new(palette.Arms) end)
	pcall(function() desc.LeftLegColor = BrickColor.new(palette.Legs) end)
	pcall(function() desc.RightLegColor = BrickColor.new(palette.Legs) end)
end

function ApplyFallbackPaletteToModel(model: Model, seed: number)
	if not model then return end
	local palette = GetFallbackPalette(seed)
	local function paint(partName, colorName)
		local part = model:FindFirstChild(partName, true)
		if part and part:IsA("BasePart") then
			part.BrickColor = BrickColor.new(colorName)
		end
	end
	paint("Head", palette.Head)
	paint("Torso", palette.Torso)
	paint("UpperTorso", palette.Torso)
	paint("LowerTorso", palette.Torso)
	paint("Left Arm", palette.Arms)
	paint("Right Arm", palette.Arms)
	paint("LeftUpperArm", palette.Arms)
	paint("LeftLowerArm", palette.Arms)
	paint("RightUpperArm", palette.Arms)
	paint("RightLowerArm", palette.Arms)
	paint("Left Leg", palette.Legs)
	paint("Right Leg", palette.Legs)
	paint("LeftUpperLeg", palette.Legs)
	paint("LeftLowerLeg", palette.Legs)
	paint("RightUpperLeg", palette.Legs)
	paint("RightLowerLeg", palette.Legs)

	local bodyColors = model:FindFirstChildOfClass("BodyColors")
	if bodyColors then
		pcall(function() bodyColors.HeadColor = BrickColor.new(palette.Head) end)
		pcall(function() bodyColors.TorsoColor = BrickColor.new(palette.Torso) end)
		pcall(function() bodyColors.LeftArmColor = BrickColor.new(palette.Arms) end)
		pcall(function() bodyColors.RightArmColor = BrickColor.new(palette.Arms) end)
		pcall(function() bodyColors.LeftLegColor = BrickColor.new(palette.Legs) end)
		pcall(function() bodyColors.RightLegColor = BrickColor.new(palette.Legs) end)
	end
end

function GetFallbackAvatarDescription(): HumanoidDescription
	fallbackAvatarCursor = (fallbackAvatarCursor % #FALLBACK_AVATAR_USER_IDS) + 1
	local fallbackUserId = FALLBACK_AVATAR_USER_IDS[fallbackAvatarCursor]
	local cached = FallbackAvatarDescriptions[fallbackUserId]
	if cached then
		return cached:Clone()
	end

	local desc
	local okFetched, fetchedDesc = pcall(function()
		return Players:GetHumanoidDescriptionFromUserIdAsync(fallbackUserId)
	end)
	if okFetched and fetchedDesc then
		desc = fetchedDesc
	else
		desc = Instance.new("HumanoidDescription")
	end
	pcall(function() desc.HeightScale = 1 end)
	pcall(function() desc.WidthScale = 1 end)
	pcall(function() desc.DepthScale = 1 end)
	pcall(function() desc.HeadScale = 1 end)
	pcall(function() desc.BodyTypeScale = 0 end)
	pcall(function() desc.ProportionScale = 0 end)
	ApplyFallbackPaletteToDescription(desc, fallbackUserId)
	FallbackAvatarDescriptions[fallbackUserId] = desc
	return desc:Clone()
end

function GetGenericGuestTemplateClone(): Model?
	if GenericGuestTemplate and GenericGuestTemplate.Parent == nil then
		return GenericGuestTemplate:Clone()
	end
	local fallbackDesc = GetFallbackAvatarDescription()
	local ok, template = pcall(function()
		return Players:CreateHumanoidModelFromDescriptionAsync(fallbackDesc, Enum.HumanoidRigType.R6)
	end)
	if ok and template then
		template.Name = "GuestTemplate"
		template.Parent = nil
		GenericGuestTemplate = template
		return template:Clone()
	end
	return nil
end

function FetchAndCacheAvatarDescription(userId: number): HumanoidDescription?
	if not userId or userId <= 0 then return nil end
	if AvatarPrefetchInFlight[userId] then return nil end
	if not TryConsumeAvatarRequestSlot() then return nil end

	AvatarPrefetchInFlight[userId] = true
	local ok, descOrErr = pcall(function()
		return Players:GetHumanoidDescriptionFromUserIdAsync(userId)
	end)
	AvatarPrefetchInFlight[userId] = nil
	if not ok or not descOrErr then
		return nil
	end

	local desc = descOrErr :: HumanoidDescription
	pcall(function() desc.HeadScale = 1 end)
	pcall(function() desc.HeightScale = 1 end)
	pcall(function() desc.WidthScale = 1 end)
	pcall(function() desc.DepthScale = 1 end)
	pcall(function() desc.BodyTypeScale = 0 end)
	pcall(function() desc.ProportionScale = 0 end)
	CacheDescription(userId, desc)
	if EnsureAvatarNameAsync then
		EnsureAvatarNameAsync(userId)
	end
	return desc:Clone()
end

EnsureAvatarNameAsync = function(userId: number)
	if not userId or userId <= 0 then return end
	if AvatarNameCache[userId] then return end
	task.spawn(function()
		if AvatarNameCache[userId] then return end
		local ok, result = pcall(function()
			return Players:GetNameFromUserIdAsync(userId)
		end)
		if ok and type(result) == "string" and result ~= "" then
			CacheAvatarName(userId, result)
		end
	end)
end

function PrefetchAvatarDescriptionsForUser(userId: number)
	local friendIds = FriendCache[userId]
	if not friendIds or #friendIds == 0 then return end

	local cfg = GetAvatarCacheConfig()
	local cursor = AvatarPrefetchCursor[userId] or 1
	local fetched = 0
	local attempts = 0
	local maxAttempts = math.min(#friendIds, cfg.DescriptionPrefetchPerCycle * 3)

	while fetched < cfg.DescriptionPrefetchPerCycle and attempts < maxAttempts do
		if cursor > #friendIds then
			cursor = 1
		end
		local friendId = tonumber(friendIds[cursor]) or 0
		cursor += 1
		attempts += 1
		if friendId > 0 and not HasFreshCachedDescription(friendId) and not AvatarPrefetchInFlight[friendId] then
			local fetchedDesc = FetchAndCacheAvatarDescription(friendId)
			if fetchedDesc then
				fetched += 1
			end
		end
	end

	AvatarPrefetchCursor[userId] = cursor
end

function PickRandom(tbl)
	if not tbl or #tbl == 0 then return nil end
	return tbl[math.random(1, #tbl)]
end

function ShowSpeech(model, message, duration)
	if not model or not model.Parent then return end
	duration = duration or 4
	-- Set attribute so client can display bubble
	model:SetAttribute("Speech", message)
	model:SetAttribute("SpeechTime", tick())
	-- Also fire event for immediate display
	for _, player in ipairs(Players:GetPlayers()) do
		pcall(function() GuestSpeechEvent:FireClient(player, model, message, duration) end)
	end
	task.delay(duration + 0.5, function()
		if model and model.Parent then
			model:SetAttribute("Speech", "")
		end
	end)
end

function NotifyPlayer(player, notifType, title, message, duration, actionData)
	if not NotificationEvent or not NotificationEvent:IsA("RemoteEvent") then return end
	if not player or not player.Parent then return end
	pcall(function()
		NotificationEvent:FireClient(player, notifType or "Info", title or "Notice", message or "", duration or 4, actionData)
	end)
end

function NotifyAllPlayers(notifType, title, message, duration, actionData)
	if not NotificationEvent or not NotificationEvent:IsA("RemoteEvent") then return end
	for _, player in ipairs(Players:GetPlayers()) do
		NotifyPlayer(player, notifType, title, message, duration, actionData)
	end
end

local function BuildTeleportNotificationAction(label, target)
	if typeof(target) ~= "Vector3" and typeof(target) ~= "CFrame" then
		return nil
	end
	return {
		ActionType = "Teleport",
		Label = label or "Go To",
		TargetPosition = typeof(target) == "CFrame" and target.Position or target,
		HeightOffset = 4,
	}
end

function ClearLiftQueueState(data)
	if not data then return end
	data.QueueSlotIndex = nil
	data.QueueDepth = nil
	data.QueueLineIndex = nil
	data.QueueLineCount = nil
	data.QueueLaneOffset = nil
	data.LastQueueMoveIssuedAt = nil
	data.LastQueueSlotTarget = nil
	if data.Model then
		LiftQueueIndexByModel[data.Model] = nil
		if data.Model.Parent then
			data.Model:SetAttribute("LiftQueueIndex", nil)
			data.Model:SetAttribute("LiftQueueDepth", nil)
			data.Model:SetAttribute("LiftQueueLineIndex", nil)
			data.Model:SetAttribute("LiftQueueLineCount", nil)
		end
	end
end

function EnterLiftQueue(data)
	if IsSummerSeason() then
		ClearLiftQueueState(data)
		ClearLiftCommitment(data)
		data.TargetLift = nil
		data.WaitStartTime = nil
		data.WantsBreak = true
		data.State = STATE.DECIDING
		return false
	end
	if data.PostUnloadSkiRequired == true then
		ClearLiftQueueState(data)
		ClearLiftCommitment(data)
		data.TargetLift = nil
		data.WaitStartTime = nil
		data.WantsBreak = false
		data.State = STATE.DECIDING
		return false
	end
	ClearLiftQueueState(data)
	ClearLiftCommitment(data)
	data.LiftApproachFailureCount = 0
	data.State = STATE.WAITING_LIFT
	data.WaitStartTime = tick()
	data.LastQueueEvalAt = 0
	if data.Model and data.Model.Parent then
		data.Model:SetAttribute("DebugEnteredQueueAt", tick())
	end
	data.PredictedQueueWait = 0
	data.QueueLaneOffset = (math.random() - 0.5) * 0.8

	return true
end

-- ============================================================================
-- BUILDING FINDERS
-- ============================================================================
function GetPlacedObjects()
	return Workspace:FindFirstChild("PlacedObjects")
end

-- PERF FIX: Cache FindBuildingsByType results. This function was the #1 CPU hog
-- because it iterates ALL PlacedObjects children + calls GetConfigItemForModel for
-- each one, and it was called dozens of times per second (every guest decision
-- calls it multiple times for Lift, Food, Hotel, Rental, Slope).
local _BuildingTypeCache = {}  -- [buildingType] = { results = {model...}, at = tick() }
local _BuildingTypeOwnerCache = {} -- ["type:owner"] = { results = {model...}, at = tick(), gen = number }
local _BuildingTypeCacheTTL = 10  -- seconds; buildings rarely change mid-play
local _BuildingTypeCacheGeneration = 0

function InvalidateBuildingTypeCache()
	_BuildingTypeCacheGeneration += 1
	_BuildingTypeCache = {}
	_BuildingTypeOwnerCache = {}
end

-- Auto-invalidate when PlacedObjects contents change, including wrapped/nested restores.
task.spawn(function()
	local po = Workspace:WaitForChild("PlacedObjects", 30)
	if not po then return end
	po.ChildAdded:Connect(InvalidateBuildingTypeCache)
	po.ChildRemoved:Connect(InvalidateBuildingTypeCache)
end)

function IsPlacedObjectRootModel(obj, placed)
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

function GetPlacedObjectModels(placed)
	local models = {}
	if not placed then
		return models
	end

	local seen = {}
	local function addIfRootModel(obj)
		if IsPlacedObjectRootModel(obj, placed) and not seen[obj] then
			seen[obj] = true
			table.insert(models, obj)
		end
	end

	-- Direct children are the normal placed-object roots; descendants are only needed
	-- for wrapped/nested restore cases.
	for _, obj in ipairs(placed:GetChildren()) do
		addIfRootModel(obj)
	end
	for _, obj in ipairs(placed:GetDescendants()) do
		addIfRootModel(obj)
	end

	return models
end

function NormalizeLookupToken(value)
	if type(value) ~= "string" then
		return ""
	end
	local lowered = string.lower(value)
	lowered = lowered:gsub("[^%w]+", "")
	return lowered
end

function ModelMatchesLookupTokens(modelName, tokens)
	local normalizedName = NormalizeLookupToken(modelName)
	if normalizedName == "" then
		return false
	end
	for _, token in ipairs(tokens) do
		if normalizedName:find(token, 1, true) then
			return true
		end
	end
	return false
end

function MatchesSpecialBuildingType(buildingType, modelName, objType, objCategory, cfgType, cfgCategory)
	local targetType = NormalizeLookupToken(buildingType)
	if targetType == "ticketoffice" then
		if objType == "TicketOffice" or cfgType == "TicketOffice" then return true end
		if objCategory == "TicketOffice" or cfgCategory == "TicketOffice" then return true end
		return ModelMatchesLookupTokens(modelName, { "ticketoffice", "bigticketoffice", "ticketbooth" })
	elseif targetType == "medcenter" or targetType == "medicalcenter" then
		if objType == "MedCenter" or cfgType == "MedCenter" then return true end
		if objType == "Medical" or cfgType == "Medical" then return true end
		if objCategory == "MedCenter" or cfgCategory == "MedCenter" then return true end
		return ModelMatchesLookupTokens(modelName, { "medcenter", "medicalcenter", "firstaid" })
	elseif targetType == "patrolhut" or targetType == "skipatrolhut" then
		if objType == "PatrolHut" or cfgType == "PatrolHut" then return true end
		if objCategory == "PatrolHut" or cfgCategory == "PatrolHut" then return true end
		return ModelMatchesLookupTokens(modelName, { "skipatrolhut", "patrolhut", "patrolbase" })
	elseif targetType == "snowcatgarage" then
		if objType == "SnowcatGarage" or cfgType == "SnowcatGarage" then return true end
		if objCategory == "SnowcatGarage" or cfgCategory == "SnowcatGarage" then return true end
		return ModelMatchesLookupTokens(modelName, { "snowcatgarage", "snowcathangar", "snowcat" })
	end
	return false
end

function FindBuildingsByTypeUncached(buildingType)
	local results = {}
	local placed = GetPlacedObjects()
	if not placed then return results end

	for _, obj in ipairs(GetPlacedObjectModels(placed)) do
		local objType = obj:GetAttribute("Type")
		local objCategory = obj:GetAttribute("Category")
		local _, itemCfg = GetConfigItemForModel(obj)
		local cfgType = itemCfg and itemCfg.Type
		local cfgCategory = itemCfg and itemCfg.Category

		local matches = false
		if buildingType == "Lift" then
			matches = objType == "Lift" or cfgType == "Lift"
				or objType == "TwoPoint" or cfgType == "TwoPoint"
				or objType == "Carpet" or cfgType == "Carpet"
				or objCategory == "Lift" or cfgCategory == "Lift"
				or objCategory == "Lifts" or cfgCategory == "Lifts"
		elseif buildingType == "Food" then
			matches = objType == "Food" or cfgType == "Food" 
				or objCategory == "Food" or cfgCategory == "Food"
		elseif buildingType == "Rental" then
			matches = objType == "Rental" or cfgType == "Rental"
				or objCategory == "Rental" or cfgCategory == "Rental"
		elseif buildingType == "Hotel" or buildingType == "House" then
			matches = objType == "House" or cfgType == "House"
				or objType == "Hotel" or cfgType == "Hotel"
				or objCategory == "House" or cfgCategory == "House"
				or objCategory == "Hotel" or cfgCategory == "Hotel"
				or objCategory == "Housing" or cfgCategory == "Housing"
				or objCategory == "Accommodation" or cfgCategory == "Accommodation"
		elseif buildingType == "Slope" then
			matches = objType == "Slope" or cfgType == "Slope"
				or objCategory == "Slopes" or cfgCategory == "Slopes"
		elseif MatchesSpecialBuildingType(buildingType, obj.Name, objType, objCategory, cfgType, cfgCategory) then
			matches = true
		end

		if matches then
			table.insert(results, obj)
		end
	end

	local specialType = NormalizeLookupToken(buildingType)
	if #results == 0 and (specialType == "ticketoffice" or specialType == "medcenter" or specialType == "medicalcenter" or specialType == "patrolhut" or specialType == "skipatrolhut" or specialType == "snowcatgarage") then
		local seen = {}
		for _, obj in ipairs(Workspace:GetDescendants()) do
			if obj:IsA("Model") and obj.Parent and not seen[obj] then
				local objType = obj:GetAttribute("Type")
				local objCategory = obj:GetAttribute("Category")
				local _, itemCfg = GetConfigItemForModel(obj)
				local cfgType = itemCfg and itemCfg.Type
				local cfgCategory = itemCfg and itemCfg.Category
				if MatchesSpecialBuildingType(buildingType, obj.Name, objType, objCategory, cfgType, cfgCategory) then
					seen[obj] = true
					table.insert(results, obj)
				end
			end
		end
	end
	return results
end

function FindBuildingsByType(buildingType, ownerUserId)
	-- Check cache for the base (unfiltered) list
	local cached = _BuildingTypeCache[buildingType]
	local now = tick()
	if not cached or (now - cached.at) > _BuildingTypeCacheTTL then
		local fresh = FindBuildingsByTypeUncached(buildingType)
		cached = { results = fresh, at = now, gen = _BuildingTypeCacheGeneration }
		_BuildingTypeCache[buildingType] = cached
	end

	local baseResults = cached.results

	-- No owner filter → return cached list directly
	if ownerUserId == nil then
		return baseResults
	end

	local ownerKey = tostring(buildingType) .. ":" .. tostring(ownerUserId)
	local ownerCached = _BuildingTypeOwnerCache[ownerKey]
	if ownerCached and ownerCached.gen == _BuildingTypeCacheGeneration and (now - ownerCached.at) <= _BuildingTypeCacheTTL then
		return ownerCached.results
	end

	-- Apply owner filter on the cached list (cheap — just attribute reads)
	local filtered = {}
	for _, obj in ipairs(baseResults) do
		if obj.Parent then -- skip destroyed objects
			local ownerAttr = obj:GetAttribute("Owner")
			local ownerNum = tonumber(ownerAttr)
			local ok = false
			if ownerNum ~= nil then
				ok = ownerNum == 0 or ownerNum == ownerUserId
			elseif ownerAttr == nil or ownerAttr == "" then
				ok = true
			end
			if ok then
				table.insert(filtered, obj)
			end
		end
	end
	_BuildingTypeOwnerCache[ownerKey] = {
		results = filtered,
		at = now,
		gen = _BuildingTypeCacheGeneration,
	}
	return filtered
end

function GetTotalGuestCount()
	return math.max(0, TotalGuestCount)
end

function GetPlayerHotelModels(player)
	local hotels = FindBuildingsByTypeUncached("Hotel")
	local owned = {}
	for _, hotel in ipairs(hotels) do
		-- Respect ownership when available; fallback to include legacy owner-less hotels.
		local ownerNum = tonumber(hotel:GetAttribute("Owner"))
			or tonumber(hotel:GetAttribute("OwnerId"))
			or tonumber(hotel:GetAttribute("ResortOwner"))
			or tonumber(hotel:GetAttribute("PlayerUserId"))
			or tonumber(hotel:GetAttribute("PlacedByUserId"))
		if ownerNum == nil or ownerNum == 0 or ownerNum == player.UserId then
			table.insert(owned, hotel)
		end
	end
	return owned
end

function GetHotelUUID(hotel)
	if not hotel then
		return ""
	end
	return tostring(hotel:GetAttribute("UUID") or "")
end

function GetHotelKey(hotel)
	if not hotel then
		return ""
	end
	local hotelUUID = GetHotelUUID(hotel)
	if hotelUUID ~= "" then
		return "UUID:" .. hotelUUID
	end
	local cached = RuntimeHotelKeyByModel[hotel]
	if cached then
		return cached
	end
	local generated = "RUNTIME:" .. HttpService:GenerateGUID(false)
	RuntimeHotelKeyByModel[hotel] = generated
	return generated
end

function GetHotelGuestList(userId, hotelKey, hotelModel)
	local list = {}
	if not userId or not hotelKey or hotelKey == "" then return list end
	for _, guestData in ipairs(PlayerGuests[userId] or {}) do
		local sameHotel = (guestData.HotelKey == hotelKey)
		if not sameHotel and hotelModel and guestData.HotelModel then
			sameHotel = guestData.HotelModel == hotelModel
		end
		if sameHotel and guestData.Model and guestData.Model.Parent then
			table.insert(list, guestData)
		end
	end
	return list
end

function GetHourDemandMultiplier(hour)
	hour = (tonumber(hour) or 12) % 24
	local curve = GuestConfig.Spawn.HourlyDemandCurve
	if type(curve) ~= "table" or #curve < 2 then
		if hour >= 16 and hour < 21 then return 1.25 end
		if hour >= 6 and hour < 11 then return 0.85 end
		if hour >= 22 or hour < 5 then return 0.35 end
		return 1.0
	end

	local prev = curve[1]
	for i = 2, #curve do
		local point = curve[i]
		local prevHour = tonumber(prev.Hour) or 0
		local pointHour = tonumber(point.Hour) or prevHour
		if hour <= pointHour then
			local span = math.max(0.001, pointHour - prevHour)
			local alpha = math.clamp((hour - prevHour) / span, 0, 1)
			local prevMult = tonumber(prev.Mult) or 1
			local pointMult = tonumber(point.Mult) or prevMult
			return prevMult + ((pointMult - prevMult) * alpha)
		end
		prev = point
	end

	-- Wrap from last point to first+24
	local first = curve[1]
	local lastHour = tonumber(prev.Hour) or 24
	local firstHour = (tonumber(first.Hour) or 0) + 24
	local span = math.max(0.001, firstHour - lastHour)
	local alpha = math.clamp((hour + (hour < (tonumber(curve[1].Hour) or 0) and 24 or 0) - lastHour) / span, 0, 1)
	local prevMult = tonumber(prev.Mult) or 1
	local firstMult = tonumber(first.Mult) or prevMult
	return prevMult + ((firstMult - prevMult) * alpha)
end

function GetMinimumDemandFloorMultiplier(hour)
	hour = (tonumber(hour) or 12) % 24
	local curve = GuestConfig.Spawn.MinimumDemandFloorByHour
	if type(curve) ~= "table" or #curve < 2 then
		if hour >= 16 and hour < 21 then return 1.05 end
		if hour >= 9 and hour < 16 then return 0.9 end
		if hour >= 6 and hour < 9 then return 0.7 end
		return 0.35
	end

	local prev = curve[1]
	for i = 2, #curve do
		local point = curve[i]
		local prevHour = tonumber(prev.Hour) or 0
		local pointHour = tonumber(point.Hour) or prevHour
		if hour <= pointHour then
			local span = math.max(0.001, pointHour - prevHour)
			local alpha = math.clamp((hour - prevHour) / span, 0, 1)
			local prevMult = tonumber(prev.Mult) or 1
			local pointMult = tonumber(point.Mult) or prevMult
			return prevMult + ((pointMult - prevMult) * alpha)
		end
		prev = point
	end

	local first = curve[1]
	local lastHour = tonumber(prev.Hour) or 24
	local firstHour = (tonumber(first.Hour) or 0) + 24
	local span = math.max(0.001, firstHour - lastHour)
	local alpha = math.clamp((hour + (hour < (tonumber(curve[1].Hour) or 0) and 24 or 0) - lastHour) / span, 0, 1)
	local prevMult = tonumber(prev.Mult) or 1
	local firstMult = tonumber(first.Mult) or prevMult
	return prevMult + ((firstMult - prevMult) * alpha)
end

function GetSeasonDemandMultiplier()
	local map = GuestConfig.Spawn.SeasonDemandMultiplier or {}
	local season = tostring(Lighting:GetAttribute("Season") or "Winter")
	if map[season] ~= nil then
		return tonumber(map[season]) or 1
	end
	local lowerSeason = string.lower(season)
	for key, value in pairs(map) do
		if string.lower(tostring(key)) == lowerSeason then
			return tonumber(value) or 1
		end
	end
	return 1
end

function GetDynamicTicketPricingConfig()
	local economyCfg = GuestConfig.Economy or {}
	local pricingCfg = economyCfg.DynamicTicketPricing or {}
	local spendingCfg = economyCfg.Spending or {}
	local liftCfg = spendingCfg.LiftTicket or {}
	local fallbackBase = tonumber(liftCfg.BaseCost) or 30

	local minPrice = math.max(1, tonumber(pricingCfg.MinPrice) or 8)
	local maxPrice = math.max(minPrice, tonumber(pricingCfg.MaxPrice) or 120)
	local defaultBase = tonumber(pricingCfg.DefaultBasePrice) or fallbackBase
	defaultBase = math.clamp(defaultBase, minPrice, maxPrice)

	local minMult = math.max(0.1, tonumber(pricingCfg.MinDynamicMultiplier) or 0.55)
	local maxMult = math.max(0.1, tonumber(pricingCfg.MaxDynamicMultiplier) or 1.85)
	if maxMult < minMult then
		maxMult = minMult
	end

	local minDemand = math.max(0.05, tonumber(pricingCfg.MinDemandMultiplier) or 0.45)
	local maxDemand = math.max(0.05, tonumber(pricingCfg.MaxDemandMultiplier) or 1.75)
	if maxDemand < minDemand then
		maxDemand = minDemand
	end

	return {
		Enabled = pricingCfg.Enabled ~= false,
		DefaultBasePrice = defaultBase,
		MinPrice = minPrice,
		MaxPrice = maxPrice,
		UpdateInterval = math.max(3, tonumber(pricingCfg.UpdateInterval) or 12),
		Smoothing = math.clamp(tonumber(pricingCfg.Smoothing) or 0.35, 0.05, 1),
		TargetOccupancy = math.clamp(tonumber(pricingCfg.TargetOccupancy) or 0.78, 0.1, 1.2),
		QueueBaseline = math.max(0.1, tonumber(pricingCfg.QueueBaseline) or 1.1),
		TargetSatisfaction = math.clamp(tonumber(pricingCfg.TargetSatisfaction) or 70, 25, 95),
		ManualHoldSeconds = math.max(0, tonumber(pricingCfg.ManualHoldSeconds) or 20),
		OccupancyWeight = tonumber(pricingCfg.OccupancyWeight) or 0.65,
		QueueWeight = tonumber(pricingCfg.QueueWeight) or 0.30,
		SatisfactionWeight = tonumber(pricingCfg.SatisfactionWeight) or 0.20,
		TimeDemandWeight = tonumber(pricingCfg.TimeDemandWeight) or 0.25,
		MinDynamicMultiplier = minMult,
		MaxDynamicMultiplier = maxMult,
		NeutralPriceForDemand = math.max(1, tonumber(pricingCfg.NeutralPriceForDemand) or defaultBase),
		DemandElasticity = math.max(0, tonumber(pricingCfg.DemandElasticity) or 0.7),
		MinDemandMultiplier = minDemand,
		MaxDemandMultiplier = maxDemand,
	}
end

function GetTicketPricingState(ownerId)
	if not ownerId then return nil end
	local state = TicketPricingState[ownerId]
	if state then return state end

	local cfg = GetDynamicTicketPricingConfig()
	local defaultBase = cfg.DefaultBasePrice

	state = {
		basePrice = defaultBase,
		currentPrice = defaultBase,
		lastManualUpdate = 0,
		dynamicEnabled = cfg.Enabled,
	}
	TicketPricingState[ownerId] = state
	return state
end

function PushTicketPriceAttributes(player, state)
	if not player or not player.Parent or not state then return end
	player:SetAttribute("TicketPriceBase", math.floor((state.basePrice or 0) + 0.5))
	player:SetAttribute("TicketPrice", math.floor((state.currentPrice or 0) + 0.5))
	player:SetAttribute("TicketPricingEnabled", state.dynamicEnabled == true)
end

function InitTicketPricingForPlayer(player)
	if not player then return end
	local cfg = GetDynamicTicketPricingConfig()
	local state = GetTicketPricingState(player.UserId)
	if not state then return end

	local attrBase = tonumber(player:GetAttribute("TicketPriceBase"))
	local attrCurrent = tonumber(player:GetAttribute("TicketPrice"))

	local legacyDefaultBase = 145
	local resolvedBase = state.basePrice or cfg.DefaultBasePrice
	if attrBase and attrBase > 0 then
		local looksLegacyDefault = math.abs(attrBase - legacyDefaultBase) < 0.5
			and (not attrCurrent or math.abs(attrCurrent - legacyDefaultBase) < 0.5)
		if not looksLegacyDefault then
			resolvedBase = attrBase
		end
	end

	resolvedBase = math.clamp(math.floor(resolvedBase + 0.5), cfg.MinPrice, cfg.MaxPrice)
	state.basePrice = resolvedBase
	if player:GetAttribute("TicketPricingEnabled") == false then
		state.dynamicEnabled = false
	else
		state.dynamicEnabled = cfg.Enabled
	end

	if attrCurrent and attrCurrent > 0 then
		local looksLegacyCurrent = math.abs(attrCurrent - legacyDefaultBase) < 0.5 and math.abs(resolvedBase - cfg.DefaultBasePrice) < 0.5
		if looksLegacyCurrent then
			state.currentPrice = resolvedBase
		else
			state.currentPrice = math.clamp(math.floor(attrCurrent + 0.5), cfg.MinPrice, cfg.MaxPrice)
		end
	else
		state.currentPrice = resolvedBase
	end

	PushTicketPriceAttributes(player, state)
end

function GetTicketPriceForOwner(ownerId)
	local cfg = GetDynamicTicketPricingConfig()
	local state = GetTicketPricingState(ownerId)
	local price = (state and state.currentPrice) or cfg.DefaultBasePrice
	price = math.floor((tonumber(price) or cfg.DefaultBasePrice) + 0.5)
	return math.clamp(price, cfg.MinPrice, cfg.MaxPrice)
end

function GetTicketDemandMultiplierForOwner(ownerId)
	local cfg = GetDynamicTicketPricingConfig()
	if not cfg.Enabled then
		return 1
	end
	local price = GetTicketPriceForOwner(ownerId)
	local neutral = math.max(1, cfg.NeutralPriceForDemand)
	local ratio = math.max(0.05, price / neutral)
	local demandMult = ratio ^ (-cfg.DemandElasticity)
	return math.clamp(demandMult, cfg.MinDemandMultiplier, cfg.MaxDemandMultiplier)
end

function InvalidateGuestMultiplierCache(userId)
	if userId then
		GuestMultiplierCache[userId] = nil
	end
end

function GetGuestPopulationMultiplierForUserId(userId)
	local ownerId = tonumber(userId)
	if not ownerId or ownerId <= 0 then
		return 1
	end

	local now = tick()
	local cached = GuestMultiplierCache[ownerId]
	if cached and (now - cached.CheckedAt) < GUEST_MULTIPLIER_CACHE_TTL then
		return cached.Value
	end

	local multiplier = 1
	local success, hasPass = pcall(function()
		return EntitlementManager.HasAccess(ownerId, DOUBLE_GUESTS_PASS_ID)
	end)
	if success and hasPass then
		multiplier = 2
	end

	local ownerPlayer = Players:GetPlayerByUserId(ownerId)
	if ownerPlayer and ownerPlayer:GetAttribute("CodeGuestBoostActive") == true then
		local codeGuestMult = tonumber(ownerPlayer:GetAttribute("CodeGuestBoostMultiplier")) or 1.6
		multiplier = multiplier * math.max(1, codeGuestMult)
	end

	GuestMultiplierCache[ownerId] = {
		Value = multiplier,
		CheckedAt = now,
	}
	return multiplier
end

function GetHotelBaseCapacity(hotel)
	local _, itemCfg = GetConfigItemForModel(hotel)
	local capacity = (itemCfg and itemCfg.Capacity) or tonumber(hotel and hotel:GetAttribute("Capacity")) or 2
	local beds = math.floor(capacity * (GuestConfig.Spawn.MaxGuestsPerHotelBed or 3.5))
	return math.max(1, beds)
end

function GetMovementDemandGovernorMultiplier()
	-- Rollback: do not suppress resort demand based on runtime movement pressure.
	return 1
end

function GetTotalHotelBedCapacity()
	local now = tick()
	if (now - (TotalHotelBedCapacitySnapshot.at or 0)) < 2 then
		return TotalHotelBedCapacitySnapshot.beds or 0
	end
	local totalBeds = 0
	for _, hotel in ipairs(FindBuildingsByType("Hotel")) do
		if hotel and hotel.Parent then
			local ownerId = tonumber(hotel:GetAttribute("Owner"))
			local guestMultiplier = GetGuestPopulationMultiplierForUserId(ownerId)
			totalBeds += (GetHotelBaseCapacity(hotel) * guestMultiplier)
		end
	end
	TotalHotelBedCapacitySnapshot = {
		at = now,
		beds = math.max(0, math.floor(totalBeds + 0.5)),
	}
	return TotalHotelBedCapacitySnapshot.beds
end

function GetDynamicRunawayGuestCap()
	-- Rollback: disable the emergency global spawn gate.
	return 0
end

function GetHotelTargetGuests(hotel)
	local baseCap = GetHotelBaseCapacity(hotel)
	local baseDemand = GetHourDemandMultiplier(Lighting.ClockTime) * GetSeasonDemandMultiplier()
	local demandFloor = GetMinimumDemandFloorMultiplier(Lighting.ClockTime)
	local ownerAttr = hotel and hotel:GetAttribute("Owner")
	local ownerId = tonumber(ownerAttr)
	if ownerId == 0 then
		ownerId = nil
	end
	local guestMultiplier = GetGuestPopulationMultiplierForUserId(ownerId)
	local pressureDemandMult = GetMovementDemandGovernorMultiplier()
	local demand = math.max(baseDemand * pressureDemandMult, demandFloor * pressureDemandMult)
	local scaledCap = math.max(0, math.floor((baseCap * guestMultiplier) + 0.5))
	local target = math.min(scaledCap, math.floor(scaledCap * demand + 0.5))
	return math.max(0, target), scaledCap
end

function RecomputeTrackedGuestTotals()
	local total = 0
	for trackedUserId, guestList in pairs(PlayerGuests) do
		if type(guestList) == "table" then
			if #guestList == 0 then
				PlayerGuests[trackedUserId] = nil
			else
				total += #guestList
			end
		end
	end
	TotalGuestCount = total
	return total
end

function GetPlayerGuestList(userId)
	local guestList = PlayerGuests[userId]
	if not guestList then
		return {}
	end

	local originalCount = #guestList
	local writeIndex = 1
	local changed = false
	for readIndex = 1, originalCount do
		local data = guestList[readIndex]
		local model = data and data.Model or nil
		local stale = (not data) or (not model) or (AllGuests[model] ~= data) or IsInvalidGuest(model, data)
		if stale then
			changed = true
			if model and AllGuests[model] == data then
				AllGuests[model] = nil
			end
		else
			if writeIndex ~= readIndex then
				guestList[writeIndex] = data
				guestList[readIndex] = nil
				changed = true
			end
			writeIndex += 1
		end
	end

	for index = writeIndex, originalCount do
		guestList[index] = nil
	end

	if #guestList == 0 then
		PlayerGuests[userId] = nil
		guestList = {}
	end

	if changed then
		RecomputeTrackedGuestTotals()
		return PlayerGuests[userId] or guestList
	end

	return guestList
end

function GetPlayerGuestCount(userId)
	return #GetPlayerGuestList(userId)
end

function GetPlayerGuestMaxNow(player)
	local maxGuests = 0
	local guestMultiplier = GetGuestPopulationMultiplierForUserId(player and player.UserId)
	for _, hotel in ipairs(GetPlayerHotelModels(player)) do
		maxGuests += (GetHotelBaseCapacity(hotel) * guestMultiplier)
	end

	local perPlayerCap = GuestConfig.Spawn.MaxGlobalGuests or 0
	if perPlayerCap > 0 then
		perPlayerCap = math.floor((perPlayerCap * guestMultiplier) + 0.5)
		maxGuests = math.min(maxGuests, perPlayerCap)
	end

	if player and player:GetAttribute("GuestCapEnabled") == true then
		local manualCap = math.max(0, math.floor((tonumber(player:GetAttribute("GuestCap")) or 0) + 0.5))
		if manualCap <= 0 then
			manualCap = 500
		end
		maxGuests = math.min(maxGuests, manualCap)
	end

	return math.max(0, math.floor(maxGuests + 0.5))
end

function GetPlayerGuestHardCap(player)
	if not player then
		return 0
	end

	return math.max(0, math.floor(GetPlayerGuestMaxNow(player) + 0.5))
end

function GetPlayerGuestDemandTarget(player)
	local maxGuests = 0
	local guestMultiplier = GetGuestPopulationMultiplierForUserId(player and player.UserId)
	for _, hotel in ipairs(GetPlayerHotelModels(player)) do
		local targetCount = GetHotelTargetGuests(hotel)
		maxGuests += targetCount
	end

	local perPlayerCap = GuestConfig.Spawn.MaxGlobalGuests or 0
	if perPlayerCap > 0 then
		perPlayerCap = math.floor((perPlayerCap * guestMultiplier) + 0.5)
		maxGuests = math.min(maxGuests, perPlayerCap)
	end
	local hardCap = GetPlayerGuestHardCap(player)
	if hardCap > 0 then
		maxGuests = math.min(maxGuests, hardCap)
	end
	return math.max(0, math.floor(maxGuests + 0.5))
end

function PushGuestCountToPlayer(player)
	if not player or not player.Parent then return end
	local current = GetPlayerGuestCount(player.UserId)
	local maxNow = GetPlayerGuestHardCap(player)
	local guestMultiplier = GetGuestPopulationMultiplierForUserId(player.UserId)
	local demandTarget = GetPlayerGuestDemandTarget(player)
	local demandMultiplier = GetHourDemandMultiplier(Lighting.ClockTime) * GetSeasonDemandMultiplier()
	local ticketDemandMultiplier = GetTicketDemandMultiplierForOwner(player.UserId)
	local spawnBacklog = math.max(0, demandTarget - current)
	local avgPredictedQueueWait = GetOwnerAveragePredictedQueueWait(player.UserId)
	local unloadFallbackCount = GetOwnerUnloadFallbackCount(player.UserId)
	local rerouteWindow = LiftRerouteStats[player.UserId]
	local reroutesPerMinute = 0
	if rerouteWindow then
		local elapsed = math.max(1, tick() - (rerouteWindow.windowStart or tick()))
		reroutesPerMinute = (rerouteWindow.count or 0) * (60 / elapsed)
	end
	player:SetAttribute("GuestDemandTarget", demandTarget)
	player:SetAttribute("GuestDemandMultiplier", demandMultiplier)
	player:SetAttribute("GuestTicketDemandMultiplier", ticketDemandMultiplier)
	player:SetAttribute("GuestPassMultiplier", guestMultiplier)
	player:SetAttribute("GuestSpawnBacklog", spawnBacklog)
	player:SetAttribute("GuestAvgPredictedQueueWait", avgPredictedQueueWait)
	player:SetAttribute("GuestReroutesPerMinute", reroutesPerMinute)
	player:SetAttribute("GuestLiftFallbackUnloads", unloadFallbackCount)
	player:SetAttribute("GuestMovingCount", RuntimeMovingGuestCount)
	player:SetAttribute("GuestMovementBudgetPerTick", RuntimeMovementBudgetPerTick)
	player:SetAttribute("GuestMovementPressure", RuntimeMovementPressure)
	player:SetAttribute("GuestMoveCommandAgeP95", RuntimeMoveCommandAgeP95)
	pcall(function()
		GuestCountUpdateEvent:FireClient(player, current, maxNow)
	end)
end

function PushGuestCountsToAllPlayers()
	for _, player in ipairs(Players:GetPlayers()) do
		PushGuestCountToPlayer(player)
	end
end

function FindNearestBuilding(pos, buildingType, ownerUserId, avoidSet)
	local buildings = FindBuildingsByType(buildingType, ownerUserId)
	if #buildings == 0 and ownerUserId ~= nil then
		buildings = FindBuildingsByType(buildingType)
	end

	local now = tick()
	local best, bestDist = nil, math.huge
	for _, b in ipairs(buildings) do
		if avoidSet and avoidSet[b] and now < avoidSet[b] then continue end

		local d = FlatDist(pos, b:GetPivot().Position)
		if d < bestDist then bestDist = d; best = b end
	end
	return best, bestDist
end

function GetDoorBounds(door)
	if not door then
		return nil, nil
	end
	if door:IsA("Model") then
		return door:GetBoundingBox()
	elseif door:IsA("BasePart") then
		return door.CFrame, door.Size
	end
	return nil, nil
end

function GetBuildingApproachPosition(target, distanceFromDoor, sideOffset)
	if not target then
		return nil
	end
	local cf, size = target:GetBoundingBox()
	local outward = cf.LookVector
	local entryCenter = cf.Position + outward * (size.Z * 0.5)
	local door = target:FindFirstChild("Door", true)
	if door then
		local doorCF, doorSize = GetDoorBounds(door)
		if doorCF and doorSize then
			local horizontal = Vector3.new(doorCF.Position.X - cf.Position.X, 0, doorCF.Position.Z - cf.Position.Z)
			if horizontal.Magnitude > 0.1 then
				outward = horizontal.Unit
			end
			entryCenter = doorCF.Position
			distanceFromDoor = math.max(distanceFromDoor or 4, math.max(doorSize.X, doorSize.Z) * 0.65 + 2)
		end
	end
	local approach = entryCenter + outward * math.max(4, distanceFromDoor or 4)
	if sideOffset and math.abs(sideOffset) > 0.01 then
		local right = Vector3.yAxis:Cross(outward)
		if right.Magnitude > 0.1 then
			approach += right.Unit * sideOffset
		end
	end
	return ResolveWalkableGroundPos(approach, target, false)
end

function FindTicketQueueAnchors(ticketOffice)
	if not ticketOffice then
		return nil, nil
	end
	local laneOne = nil
	local laneTwo = nil
	for _, desc in ipairs(ticketOffice:GetDescendants()) do
		if desc:IsA("Attachment") then
			local normalized = NormalizeLookupToken(desc.Name)
			if (normalized == "q1" or normalized == "que1" or normalized == "queue1" or normalized == "qnumber1") and not laneOne then
				laneOne = desc
			elseif (normalized == "q2" or normalized == "que2" or normalized == "queue2" or normalized == "qnumber2") and not laneTwo then
				laneTwo = desc
			elseif (normalized == "queue" or normalized == "que") and not laneOne then
				laneOne = desc
			end
		end
	end
	if not laneOne then
		laneOne = ticketOffice:FindFirstChild("Attachment", true)
	end
	return laneOne, laneTwo
end

function CountTicketQueueGuests(ticketOffice, laneIndex)
	local count = 0
	for _, guestData in pairs(AllGuests) do
		if guestData ~= nil and guestData.TargetBuilding == ticketOffice then
			if guestData.State == STATE.BUYING_TICKET
				or (guestData.State == STATE.WALKING and guestData.NextAction == "Ticket") then
				if (tonumber(guestData.TicketQueueLane) or 1) == laneIndex then
					count += 1
				end
			end
		end
	end
	return count
end

function GetTicketQueueTargetPosition(data, ticketOffice)
	if not data or not ticketOffice then
		return nil
	end
	local laneOne, laneTwo = FindTicketQueueAnchors(ticketOffice)
	local laneIndex = tonumber(data.TicketQueueLane)
	if not laneIndex then
		local laneOneCount = CountTicketQueueGuests(ticketOffice, 1)
		local laneTwoCount = laneTwo and CountTicketQueueGuests(ticketOffice, 2) or math.huge
		laneIndex = (laneTwo and laneTwoCount < laneOneCount) and 2 or 1
		data.TicketQueueLane = laneIndex
	end
	local anchor = (laneIndex == 2 and laneTwo) or laneOne
	if not anchor then
		return GetBuildingApproachPosition(ticketOffice, 5)
	end
	local slot = tonumber(data.TicketQueueSlot)
	if not slot then
		slot = CountTicketQueueGuests(ticketOffice, laneIndex) + 1
		data.TicketQueueSlot = slot
	end
	local anchorCF = anchor.WorldCFrame
	local queueDir = -anchorCF.LookVector
	if queueDir.Magnitude < 0.1 then
		queueDir = -(ticketOffice:GetPivot().LookVector)
	end
	queueDir = Vector3.new(queueDir.X, 0, queueDir.Z)
	if queueDir.Magnitude < 0.1 then
		queueDir = Vector3.new(0, 0, -1)
	else
		queueDir = queueDir.Unit
	end
	local queuePos = anchor.WorldPosition + (queueDir * ((slot - 1) * TICKET_QUEUE_SLOT_SPACING))
	queuePos = ResolveWalkableGroundPos(queuePos, ticketOffice, false)
	return queuePos
end

function GetMedCenterEntryPosition(medCenter)
	if not medCenter then
		return nil
	end
	local entryAttachment = medCenter:FindFirstChild("MedEntry", true)
		or medCenter:FindFirstChild("Entry", true)
		or medCenter:FindFirstChild("Door", true)
	if entryAttachment and entryAttachment:IsA("Attachment") then
		return ResolveWalkableGroundPos(entryAttachment.WorldPosition, medCenter, false)
	end
	return GetBuildingApproachPosition(medCenter, 5)
end

-- ============================================================================
-- SLOPE HELPERS
-- ============================================================================
function IsGuestRideableSlopeModel(slopeModel)
	if not slopeModel or not slopeModel.Parent then
		return false
	end
	if slopeModel:GetAttribute("IsPath") == true then
		return false
	end
	if slopeModel:GetAttribute("IsQueue") == true then
		return false
	end
	return true
end

local function IsGuestUsableSlopePath(path)
	if type(path) ~= "table" or #path < 2 then
		return false
	end
	local totalLength = 0
	for i = 1, #path - 1 do
		local p0 = path[i]
		local p1 = path[i + 1]
		if typeof(p0) ~= "Vector3" or typeof(p1) ~= "Vector3" then
			return false
		end
		totalLength += (p1 - p0).Magnitude
	end
	return totalLength >= 6
end

function GetSlopeData(slopeModel)
	if not IsGuestRideableSlopeModel(slopeModel) then
		return nil, nil
	end

	-- Try _G.SlopeRegistry first
	local registry = _G.SlopeRegistry
	if registry then
		for _, entry in ipairs(registry) do
			if entry.Model == slopeModel and IsGuestUsableSlopePath(entry.Path) then
				return entry.Path, entry.Difficulty
			end
		end
	end

	-- Fallback to SlopeManager helper when available.
	local globalSlopeGetter = _G.GetSlopeData
	if type(globalSlopeGetter) == "function" then
		local ok, result = pcall(globalSlopeGetter, slopeModel)
		if ok and type(result) == "table" and IsGuestUsableSlopePath(result.Path) then
			return result.Path, result.Difficulty or slopeModel:GetAttribute("Difficulty") or "Green"
		end
	end

	-- Final fallback: parse from attributes
	local rawPoints = slopeModel:GetAttribute("RawPoints")
	if rawPoints then
		local ok, parsed = pcall(function() return HttpService:JSONDecode(rawPoints) end)
		if ok and parsed then
			local path = {}
			for _, pt in ipairs(parsed) do
				table.insert(path, Vector3.new(pt[1] or pt.X or 0, pt[2] or pt.Y or 0, pt[3] or pt.Z or 0))
			end
			if IsGuestUsableSlopePath(path) then
				return path, slopeModel:GetAttribute("Difficulty") or "Green"
			end
		end
	end
	return nil, nil
end

function FindSlopeForGuest(guestData, nearPos)
	local slopes = FindBuildingsByType("Slope", guestData and guestData.OwnerId or nil)
	if #slopes == 0 then
		slopes = FindBuildingsByType("Slope")
	end
	if #slopes == 0 then return nil end

	local personality = GuestConfig.Personalities[guestData.Personality]
	local allowed = GuestConfig.SlopeDifficulty.Allowed[guestData.Personality] or {1, 2}
	local preferred = GuestConfig.SlopeDifficulty.Preferred[guestData.Personality] or {1}

	local validSlopes = {}
	local preferredSlopes = {}

	local now = tick()
	for _, slope in ipairs(slopes) do
		if IsGuestRideableSlopeModel(slope) and not IsSlopeAvoided(guestData, slope, now) then
			local path, diff = GetSlopeData(slope)
			if path and #path > 1 then
				local diffNum = GetDifficultyNumber(diff, slope.Name)

				local isAllowed = false
				for _, a in ipairs(allowed) do
					if a == diffNum then isAllowed = true; break end
				end

				if isAllowed then
					table.insert(validSlopes, slope)
					for _, p in ipairs(preferred) do
						if p == diffNum then table.insert(preferredSlopes, slope); break end
					end
				end
			end
		end
	end

	-- Prefer preferred slopes, fallback to any valid
	local pool = #preferredSlopes > 0 and preferredSlopes or validSlopes
	if #pool == 0 then return nil end

	-- Prefer the closest downhill entry, not whichever endpoint was drawn first.
	if nearPos then
		local best = SelectClosestSlopeByEntry(pool, nearPos, 2500, 24, guestData)
		if best then
			return best
		end

		-- If no strict entry is found, use a relaxed fallback before giving up.
		local relaxed = SelectClosestSlopeByEntry(pool, nearPos, math.huge, 8, guestData)
		if relaxed then
			return relaxed
		end
	end

	return PickRandom(pool)
end

function FindAnySlopeForGuest(guestData, nearPos)
	local slopes = FindBuildingsByType("Slope", guestData and guestData.OwnerId or nil)
	if #slopes == 0 then
		slopes = FindBuildingsByType("Slope")
	end
	if #slopes == 0 then
		return nil
	end

	local now = tick()
	local pool = {}
	for _, slope in ipairs(slopes) do
		if IsGuestRideableSlopeModel(slope) and not IsSlopeAvoided(guestData, slope, now) then
			local path = GetSlopeData(slope)
			if path and #path > 1 then
				table.insert(pool, slope)
			end
		end
	end
	if #pool == 0 then
		return nil
	end

	if nearPos then
		local nearby = SelectClosestSlopeByEntry(pool, nearPos, math.huge, 6, guestData)
		if nearby then
			return nearby
		end
	end

	return PickRandom(pool)
end

function FindEmergencySlopeForGuest(guestData, nearPos)
	local slopes = FindBuildingsByType("Slope", guestData and guestData.OwnerId or nil)
	if #slopes == 0 then
		slopes = FindBuildingsByType("Slope")
	end
	if #slopes == 0 then
		return nil
	end

	local pool = {}
	for _, slope in ipairs(slopes) do
		if IsGuestRideableSlopeModel(slope) then
			local path = GetSlopeData(slope)
			if path and #path > 1 then
				table.insert(pool, slope)
			end
		end
	end
	if #pool == 0 then
		return nil
	end

	if nearPos then
		local nearby = SelectClosestSlopeByEntry(pool, nearPos, math.huge, 2, guestData)
		if nearby then
			return nearby
		end
	end

	return PickRandom(pool)
end

function GetDifficultyNumber(diff, slopeName)
	local diffToNum = { Green = 1, Blue = 2, Black = 3, ["Double Black"] = 4, DoubleBlack = 4, ["Triple Black"] = 5, TripleBlack = 5, Glade = 6 }
	if type(diff) == "number" then
		return diff
	end
	local resolved = diffToNum[tostring(diff)]
	if resolved then
		return resolved
	end
	local itemCfg = Config.Items[slopeName or ""]
	if itemCfg and itemCfg.Difficulty then
		return tonumber(itemCfg.Difficulty) or 1
	end
	return 1
end

function GetRemainingPathLength(path, startIndex)
	if not path or #path < 2 then return 0 end
	local idx = math.clamp(startIndex or 1, 1, #path - 1)
	local total = 0
	for i = idx, #path - 1 do
		total += (path[i + 1] - path[i]).Magnitude
	end
	return total
end

local function GetAdaptiveMinRemaining(path, requestedMin, floorMin, ratio)
	local floorValue = math.max(2, tonumber(floorMin) or 8)
	local desiredMin = math.max(floorValue, tonumber(requestedMin) or floorValue)
	local totalLength = GetRemainingPathLength(path, 1)
	if totalLength <= 0 then
		return floorValue
	end
	local ratioValue = math.max(0.25, tonumber(ratio) or 0.62)
	local adaptiveCap = math.max(floorValue, totalLength * ratioValue)
	return math.clamp(desiredMin, floorValue, adaptiveCap)
end

function GetNearestSlopeEntryIndex(path, nearPos, maxFlatDistance)
	if not path or #path < 2 then
		return 1
	end
	if not nearPos then
		return 1
	end

	local maxDist = math.max(20, tonumber(maxFlatDistance) or 96)
	local bestIndex = nil
	local bestScore = math.huge

	for i = 1, #path - 1 do
		local point = path[i]
		local nextPoint = path[i + 1]
		local flat = FlatDist(nearPos, point)
		if flat <= maxDist then
			local seg = nextPoint - point
			if seg.Magnitude > 0.1 then
				local downhillEnough = (nextPoint.Y - point.Y) <= 2
				local heightDelta = math.abs(point.Y - nearPos.Y)
				local score = flat + (heightDelta * 0.3) + (i * 0.08)
				if downhillEnough then
					score -= 2
				end
				if score < bestScore then
					bestScore = score
					bestIndex = i
				end
			end
		end
	end

	return bestIndex or 1
end

function GetSlopeEntryPosition(path, entryIndex)
	if not path or #path < 1 then
		return nil
	end
	local idx = math.clamp(entryIndex or 1, 1, math.max(1, #path - 1))
	local entryPoint = path[idx]
	local nextPoint = path[math.min(idx + 1, #path)] or (entryPoint + Vector3.new(0, 0, -1))
	local seg = nextPoint - entryPoint
	local flatSeg = Vector3.new(seg.X, 0, seg.Z)
	local rightVec
	if flatSeg.Magnitude > 0.1 then
		local unit = flatSeg.Unit
		rightVec = Vector3.new(-unit.Z, 0, unit.X)
	else
		rightVec = Vector3.new(1, 0, 0)
	end
	local laneOffset = rightVec * ((math.random() - 0.5) * 9)
	return GetGroundPos(entryPoint + laneOffset)
end

function GetReachableSlopeEntry(path, nearPos, maxFlatDistance, minRemainingLength)
	if not path or #path < 2 or not nearPos then
		return nil, nil, nil, nil
	end

	local maxDist = math.max(20, tonumber(maxFlatDistance) or 96)
	local minRemaining = GetAdaptiveMinRemaining(path, minRemainingLength, 8, 0.62)
	local entryIndex = GetNearestSlopeEntryIndex(path, nearPos, maxDist)
	if not entryIndex then
		return nil, nil, nil, nil
	end

	local entryPoint = path[entryIndex]
	local nextPoint = path[math.min(entryIndex + 1, #path)]
	if not entryPoint or not nextPoint then
		return nil, nil, nil, nil
	end

	local flatDist = FlatDist(nearPos, entryPoint)
	if flatDist > maxDist then
		return nil, nil, nil, nil
	end

	if (nextPoint.Y - entryPoint.Y) > 6 then
		return nil, nil, nil, nil
	end

	local remainingLength = GetRemainingPathLength(path, entryIndex)
	if remainingLength < minRemaining then
		return nil, nil, nil, nil
	end

	return entryIndex, entryPoint, flatDist, remainingLength
end

function SelectSkiEntryIndex(path, nearPos, strictMinRemaining, relaxedMinRemaining)
	if not path or #path < 2 then
		return nil, nil, nil
	end
	local maxUsableEntryIndex = math.max(1, #path - 2)
	local strictMin = GetAdaptiveMinRemaining(path, strictMinRemaining, 14, 0.78)
	local relaxedMin = GetAdaptiveMinRemaining(path, relaxedMinRemaining, 8, 0.62)

	local strictIndex, _, strictFlatDist, strictRemaining = GetReachableSlopeEntry(path, nearPos, math.huge, strictMin)
	if strictIndex then
		return math.clamp(strictIndex, 1, maxUsableEntryIndex), strictFlatDist, strictRemaining
	end

	local relaxedIndex, _, relaxedFlatDist, relaxedRemaining = GetReachableSlopeEntry(path, nearPos, math.huge, relaxedMin)
	if relaxedIndex then
		return math.clamp(relaxedIndex, 1, maxUsableEntryIndex), relaxedFlatDist, relaxedRemaining
	end

	local fallbackIndex = tonumber(GetNearestSlopeEntryIndex(path, nearPos, math.huge)) or 1
	fallbackIndex = math.clamp(fallbackIndex, 1, maxUsableEntryIndex)
	local remaining = GetRemainingPathLength(path, fallbackIndex)
	while fallbackIndex > 1 and remaining < relaxedMin do
		fallbackIndex -= 1
		remaining = GetRemainingPathLength(path, fallbackIndex)
	end

	local entryPoint = path[fallbackIndex] or path[1]
	local flatDist = nearPos and FlatDist(nearPos, entryPoint) or nil
	return fallbackIndex, flatDist, remaining
end

local function IsSlopeCrowdRelevantState(state)
	return state ~= STATE.LEAVING
		and state ~= STATE.SLEEPING
		and state ~= STATE.GOING_TO_HOTEL
		and state ~= STATE.EATING
		and state ~= STATE.RESTING
end

local function CountGuestsNearSlopeChoice(guestData, slope, entryPos)
	if not slope or not slope.Parent then
		return 0, 0
	end

	local ownerId = guestData and guestData.OwnerId or nil
	local function isRelevantGuest(guestModel)
		if ownerId and not GuestMatchesOwner(guestModel, ownerId) then
			return false
		end
		local state = tostring(guestModel:GetAttribute("State") or "")
		return IsSlopeCrowdRelevantState(state)
	end

	local entryGuests = 0
	if entryPos then
		entryGuests = CountNearbyGuests(entryPos, 56, isRelevantGuest)
	end

	local boxCF, boxSize = slope:GetBoundingBox()
	local slopeRadius = math.clamp(math.max(boxSize.X, boxSize.Z) * 0.32, 45, 150)
	local slopeGuests = CountNearbyGuests(boxCF.Position, slopeRadius, isRelevantGuest)
	return entryGuests, slopeGuests
end

local function ScoreSlopeForGuestChoice(guestData, slope, path, nearPos, entryIndex, flatDist, remainingLength)
	local entryPos = GetSlopeEntryPosition(path, entryIndex) or GetGroundPos(path[entryIndex] or path[1])
	local entryGuests, slopeGuests = CountGuestsNearSlopeChoice(guestData, slope, entryPos)
	local crowdPenalty = (entryGuests * 16) + (math.max(0, slopeGuests - 1) * 6)
	local flowBonus = math.min(18, math.max(0, remainingLength - 140) * 0.04)
	local repeatPenalty = 0
	if guestData and slope and slope.Parent then
		local slopeUUID = tostring(slope:GetAttribute("UUID") or "")
		if slopeUUID ~= "" and guestData.LastSlopeUUID == slopeUUID then
			local sinceLastSlope = tick() - (tonumber(guestData.LastSlopeUseAt) or 0)
			local cooldownPenalty = math.clamp(140 - sinceLastSlope, 0, 140)
			repeatPenalty = 55 + (cooldownPenalty * 0.85)
		end
	end
	local jitter = (math.random() - 0.5) * 9
	return flatDist + (math.max(0, 220 - remainingLength) * 0.2) + crowdPenalty + repeatPenalty - flowBonus + jitter, entryGuests, slopeGuests
end

local function ChooseSlopeCandidate(candidates, bestScore)
	if not candidates or #candidates == 0 or bestScore == math.huge then
		return nil
	end

	local scoreBand = math.max(42, math.abs(bestScore) * 0.16)
	local totalWeight = 0
	local shortlist = {}
	for _, entry in ipairs(candidates) do
		local scoreDelta = math.max(0, (entry.Score or bestScore) - bestScore)
		if scoreDelta <= scoreBand then
			local crowdPenalty = (entry.EntryGuests or 0) * 0.8 + (entry.SlopeGuests or 0) * 0.2
			local weight = 1 / math.max(0.18, 1 + (scoreDelta / math.max(scoreBand, 1)) + crowdPenalty)
			totalWeight += weight
			table.insert(shortlist, {
				Entry = entry,
				Weight = weight,
			})
		end
	end

	if #shortlist == 0 then
		local fallback = candidates[1]
		for _, entry in ipairs(candidates) do
			if (entry.Score or math.huge) < (fallback.Score or math.huge) then
				fallback = entry
			end
		end
		return fallback
	end
	if #shortlist == 1 then
		return shortlist[1].Entry
	end

	local roll = math.random() * totalWeight
	for _, shortlistEntry in ipairs(shortlist) do
		roll -= shortlistEntry.Weight
		if roll <= 0 then
			return shortlistEntry.Entry
		end
	end
	return shortlist[#shortlist].Entry
end

function SelectClosestSlopeByEntry(slopes, nearPos, maxFlatDistance, minRemainingLength, guestData)
	if not nearPos then
		return nil, nil, nil
	end

	local candidates = {}
	local bestScore = math.huge

	for _, slope in ipairs(slopes or {}) do
		local path = GetSlopeData(slope)
		if path and #path > 1 then
			local entryIndex, _, flatDist, remainingLength = GetReachableSlopeEntry(path, nearPos, maxFlatDistance, minRemainingLength)
			if entryIndex then
				local score, entryGuests, slopeGuests = ScoreSlopeForGuestChoice(guestData, slope, path, nearPos, entryIndex, flatDist, remainingLength)
				if score < bestScore then
					bestScore = score
				end
				table.insert(candidates, {
					Slope = slope,
					EntryIndex = entryIndex,
					FlatDist = flatDist,
					Score = score,
					EntryGuests = entryGuests,
					SlopeGuests = slopeGuests,
				})
			end
		end
	end

	local selected = ChooseSlopeCandidate(candidates, bestScore)
	if not selected then
		return nil, nil, nil
	end

	return selected.Slope, selected.EntryIndex, selected.FlatDist
end

function FindMergedTrailContinuation(data)
	if not data or IsSummerSeason() then return nil, nil end
	local currentSlope = data.SkiSlopeModel
	local currentPath = data.SkiPath
	if not currentSlope or not currentSlope.Parent or not currentPath or #currentPath < 2 then
		return nil, nil
	end

	local exitPos = data.Root and data.Root.Position or currentPath[#currentPath]
	local currTailA = currentPath[#currentPath - 1]
	local currTailB = currentPath[#currentPath]
	local currentDir = (currTailB - currTailA).Magnitude > 0.1 and (currTailB - currTailA).Unit or Vector3.new(0, 0, 1)
	local allowed = GuestConfig.SlopeDifficulty.Allowed[data.Personality] or {1, 2}
	local allowedSet = {}
	for _, a in ipairs(allowed) do
		allowedSet[a] = true
	end

	local slopes = FindBuildingsByType("Slope")
	if #slopes == 0 then return nil, nil end

	local visited = data.SkiVisitedSlopes or {}
	local bestSlope = nil
	local bestIndex = nil
	local bestScore = math.huge
	local bestDiffMismatch = false

	for _, slope in ipairs(slopes) do
		if slope ~= currentSlope and slope.Parent then
			local path, diff = GetSlopeData(slope)
			if path and #path >= 2 then
				local diffNum = GetDifficultyNumber(diff, slope.Name)
				-- Trail merges: allow ANY difficulty, don't block continuation
				-- Guests are already mid-mountain and MUST keep going downhill
				-- Difficulty mismatch is a score penalty, not a hard reject
				local diffMismatch = not allowedSet[diffNum]
				local slopeUUID = tostring(slope:GetAttribute("UUID") or "")
				if slopeUUID == "" or (visited[slopeUUID] or 0) < 2 then
					local nearestIndex = nil
					local nearestDist = math.huge
					local nearestHeightDelta = math.huge

					for i = 1, #path - 1 do
						local point = path[i]
						local flatDist = FlatDist(exitPos, point)
						if flatDist < nearestDist then
							local nextPoint = path[i + 1]
							local seg = nextPoint - point
							if seg.Magnitude > 0.1 then
								local candDir = seg.Unit
								local alignment = candDir:Dot(currentDir)
								-- Must be going roughly the same direction (0.3+) and downhill
								local mostlyDownhill = (nextPoint.Y - point.Y) <= 0.5
								local heightDelta = math.abs((point.Y or 0) - (exitPos.Y or 0))
								if alignment > 0.3 and mostlyDownhill and heightDelta < 15 then
									nearestDist = flatDist
									nearestIndex = i
									nearestHeightDelta = heightDelta
								end
							end
						end
					end

					if nearestIndex and nearestDist <= 25 then
						local remaining = GetRemainingPathLength(path, nearestIndex)
						if remaining >= 28 then
							local score = nearestDist + (nearestHeightDelta * 0.25)
							if nearestIndex <= 4 then
								score = score - 1.5
							end
							-- Prefer matching difficulty but don't reject mismatches
							if allowedSet[diffNum] then
								score = score - 5  -- bonus for matching difficulty
							end
							if score < bestScore then
								bestScore = score
								bestSlope = slope
								bestIndex = nearestIndex
								bestDiffMismatch = diffMismatch
							end
						end
					end
				end
			end
		end
	end

	return bestSlope, bestIndex, bestDiffMismatch
end

-- ============================================================================
-- LIFT HELPERS (Time-based — reads LiftCache for chair positions)
-- ============================================================================
-- The chair visuals are CLIENT-ONLY (created by LiftClient). The server cannot
-- see them. Instead, we read the same LiftCache data that the client uses,
-- compute chair positions with the same time math, and set RidingLift/RidingChair
-- attributes. The client's rider-snap code already handles guest positioning.
-- ============================================================================

local CableMath = nil
local CableConfig = nil
pcall(function() CableMath = require(ReplicatedStorage:WaitForChild("CableMath", 5)) end)
pcall(function() CableConfig = require(ReplicatedStorage:WaitForChild("CableConfig", 5)) end)

-- Parsed lift path cache: { [uuid] = { Segments, TotalDuration, CorrectedTimeSpacing, ConfigName } }
local ParsedLiftData = {}

function FindLiftModelByUUID(uuid)
	if not uuid or uuid == "" then return nil end
	for _, lift in ipairs(FindBuildingsByType("Lift")) do
		if lift:GetAttribute("UUID") == uuid then
			return lift
		end
	end
	return nil
end

local function GetStationMarkerPosition(marker)
	if not marker then
		return nil
	end
	if marker:IsA("Attachment") then
		return marker.WorldPosition
	elseif marker:IsA("BasePart") then
		return marker.Position
	end
	return nil
end

local function IsRoutingGeometryCandidate(inst, container)
	local current = inst
	while current and current ~= container do
		local parent = current.Parent
		if not parent then
			break
		end
		if parent:IsA("Model") then
			local lowered = string.lower(parent.Name)
			if lowered:find("cabin", 1, true)
				or lowered:find("carrier", 1, true)
				or lowered:find("chair", 1, true)
				or lowered:find("gondola", 1, true)
				or lowered:find("vehicle", 1, true)
				or lowered:find("cab", 1, true) then
				return false
			end
		end
		current = parent
	end
	return true
end

local function GetStationLineFallbackPoint(stationModel, markerName)
	if not stationModel then
		return nil
	end

	local preferredNames
	if markerName == "LoadHere" then
		preferredNames = { "LoadLine", "Line", "Queue", "Que" }
	elseif markerName == "UnloadHere" then
		preferredNames = { "UnloadLine", "Line", "LoadLine" }
	else
		preferredNames = { markerName, "Line", "LoadLine", "UnloadLine" }
	end

	for _, preferredName in ipairs(preferredNames) do
		local count = 0
		local sum = Vector3.zero
		for _, desc in ipairs(stationModel:GetDescendants()) do
			if desc.Name == preferredName and IsRoutingGeometryCandidate(desc, stationModel) then
				local pos = GetStationMarkerPosition(desc)
				if pos then
					sum += pos
					count += 1
				end
			end
		end
		if count > 0 then
			return sum / count
		end
	end

	return nil
end

function GetStationReferencePoint(stationModel, markerName)
	if not stationModel then return nil end

	local marker = nil
	if markerName then
		for _, desc in ipairs(stationModel:GetDescendants()) do
			if desc.Name == markerName and IsRoutingGeometryCandidate(desc, stationModel) then
				marker = desc
				break
			end
		end
	end
	local markerPos = GetStationMarkerPosition(marker)
	if markerPos then
		return markerPos
	end

	local lineFallback = GetStationLineFallbackPoint(stationModel, markerName)
	if lineFallback then
		return lineFallback
	end

	local a1Pos = GetStationMarkerPosition(stationModel:FindFirstChild("A1", true))
	local a2Pos = GetStationMarkerPosition(stationModel:FindFirstChild("A2", true))
	if a1Pos and a2Pos then
		return (a1Pos + a2Pos) * 0.5
	end

	return stationModel:GetPivot().Position
end

function ParseLiftCache(uuid)
	local liftCache = ReplicatedStorage:FindFirstChild("LiftCache")
	if not liftCache then return nil end
	local cacheObj = liftCache:FindFirstChild(uuid)
	if not cacheObj or not cacheObj:IsA("StringValue") or cacheObj.Value == "" then return nil end

	local ok, rawData = pcall(function() return HttpService:JSONDecode(cacheObj.Value) end)
	if not ok or not rawData then return nil end

	local segments = {}
	for _, s in ipairs(rawData.Segments or {}) do
		-- Preserve the same motion fields the client lift solver uses so
		-- guest boarding and unload checks stay aligned with visible chairs.
		table.insert(segments, {
			P0 = Vector3.new(s.P0[1], s.P0[2], s.P0[3]),
			P1 = Vector3.new(s.P1[1], s.P1[2], s.P1[3]),
			ArcPoint = s.ArcPoint and Vector3.new(s.ArcPoint[1], s.ArcPoint[2], s.ArcPoint[3]) or nil,
			Length = s.Length or 1,
			StartDist = s.StartDist or 0,
			EndDist = s.EndDist or 1,
			SegStartDist = s.SegStartDist or s.StartDist or 0,
			SegLength = s.SegLength or s.Length or 1,
			StartTime = s.StartTime or 0,
			EndTime = s.EndTime or 1,
			StartSpeed = s.StartSpeed or s.SpeedLimit or 5,
			EndSpeed = s.EndSpeed or s.SpeedLimit or 5,
			Accel = s.Accel or 0,
			SpeedLimit = s.SpeedLimit or s.StartSpeed or 5,
			IsStation = s.IsStation,
			IsPole = s.IsPole,
			IsSag = s.IsSag,
			SagAmount = s.SagAmount,
			DoorState = s.DoorState,
		})
	end

	local chairCount = 0
	if rawData.TotalDuration and rawData.CorrectedTimeSpacing and rawData.CorrectedTimeSpacing > 0 then
		-- Mirror LiftClient chair indexing exactly so guests stay attached to the same chair the visuals use.
		chairCount = math.max(1, math.round(rawData.TotalDuration / rawData.CorrectedTimeSpacing))
	end

	local parsed = {
		Segments = segments,
		TotalDuration = rawData.TotalDuration or 60,
		CorrectedTimeSpacing = rawData.CorrectedTimeSpacing or 5,
		ConfigName = rawData.ConfigName,
		ChairCount = chairCount,
		CacheObj = cacheObj,
	}

	-- Tag station segments by nearest station so unload logic can be exact.
	local liftModel = FindLiftModelByUUID(uuid)
	if liftModel then
		local startStation = liftModel:FindFirstChild("StartStation")
		local endStation = liftModel:FindFirstChild("EndStation")
		local startPos = GetStationReferencePoint(startStation, "LoadHere")
		local endPos = GetStationReferencePoint(endStation, "UnloadHere")
		if not startPos then startPos = liftModel:GetPivot().Position end
		if not endPos then endPos = liftModel:GetPivot().Position end

		for _, seg in ipairs(segments) do
			if seg.IsStation then
				local mid
				if seg.ArcPoint then
					-- Quadratic bezier midpoint (t=0.5)
					mid = (seg.P0 * 0.25) + (seg.ArcPoint * 0.5) + (seg.P1 * 0.25)
				else
					mid = seg.P0:Lerp(seg.P1, 0.5)
				end
				local distToStart = (mid - startPos).Magnitude
				local distToEnd = (mid - endPos).Magnitude
				seg.StationTag = (distToEnd < distToStart) and "End" or "Start"
			end
		end
	end

	ParsedLiftData[uuid] = parsed
	return parsed
end

function GetLiftMasterTime(uuid)
	local parsed = ParsedLiftData[uuid]
	if not parsed or not parsed.CacheObj then return 0 end
	local co = parsed.CacheObj
	local refTime = co:GetAttribute("RefTime") or 0
	local refTimestamp = co:GetAttribute("RefTimestamp") or Workspace:GetServerTimeNow()
	local refSpeed = co:GetAttribute("RefSpeed") or 1
	return refTime + ((Workspace:GetServerTimeNow() - refTimestamp) * refSpeed)
end

function GetChairPosFromTime(parsed, masterTime, chairOffset)
	if not parsed or parsed.TotalDuration <= 0 then return nil end
	local t = (masterTime + chairOffset) % parsed.TotalDuration

	local seg = nil
	for _, s in ipairs(parsed.Segments) do
		if t >= s.StartTime and t < s.EndTime then
			seg = s
			break
		end
	end
	if not seg then seg = parsed.Segments[#parsed.Segments] end
	if not seg then return nil end

	local timeInSeg = t - seg.StartTime
	local dist = seg.StartDist or 0
	if seg.StartSpeed and seg.EndSpeed and math.abs(seg.StartSpeed - seg.EndSpeed) > 0.001 then
		local accel = seg.Accel or 0
		dist += (seg.StartSpeed * timeInSeg) + (0.5 * accel * timeInSeg * timeInSeg)
	else
		dist += timeInSeg * (seg.StartSpeed or seg.SpeedLimit or 5)
	end

	local alpha = 0
	if seg.SegLength and seg.SegLength > 0 then
		alpha = (dist - (seg.SegStartDist or seg.StartDist or 0)) / seg.SegLength
	elseif seg.Length and seg.Length > 0 then
		alpha = (dist - (seg.StartDist or 0)) / seg.Length
	end
	alpha = math.clamp(alpha, 0, 1)

	local p0, p1 = seg.P0, seg.P1
	local pos, tangent
	local actualSag = 0
	if seg.IsStation or seg.ArcPoint then
		actualSag = 0
	elseif seg.SagAmount and math.abs(seg.SagAmount) > 0.001 then
		actualSag = seg.SagAmount
	elseif seg.IsSag then
		actualSag = (CableConfig and CableConfig.SagAmount) or 1.5
	else
		local spanDist = (p1 - p0).Magnitude
		local minDistanceForSag = CableConfig and CableConfig.MinDistanceForSag or math.huge
		if CableConfig and spanDist >= minDistanceForSag then
			actualSag = CableConfig.SagAmount
		end
	end

	if seg.ArcPoint and CableMath and CableMath.GetPointOnCircle then
		pos = CableMath.GetPointOnCircle(p0, seg.ArcPoint, p1, alpha)
		tangent = CableMath.GetCircleTangent and CableMath.GetCircleTangent(p0, seg.ArcPoint, p1, alpha) or nil
	elseif seg.ArcPoint then
		local t1 = 1 - alpha
		pos = t1 * t1 * p0 + 2 * t1 * alpha * seg.ArcPoint + alpha * alpha * p1
		tangent = ((seg.ArcPoint - p0) * (2 * t1)) + ((p1 - seg.ArcPoint) * (2 * alpha))
	elseif math.abs(actualSag) > 0.001 and CableMath and CableMath.GetPointOnCurve then
		pos = CableMath.GetPointOnCurve(p0, p1, actualSag, alpha)
		tangent = CableMath.GetTangent and CableMath.GetTangent(p0, p1, actualSag, alpha) or nil
	else
		pos = p0:Lerp(p1, alpha)
		tangent = p1 - p0
	end

	if tangent and tangent.Magnitude > 0.001 then
		tangent = tangent.Unit
	else
		tangent = (p1 - p0).Magnitude > 0.001 and (p1 - p0).Unit or Vector3.zAxis
	end

	local isStation = seg.IsStation
	local stationTag = seg.StationTag

	local itemCfg = Config.Items[parsed.ConfigName]
	if itemCfg and itemCfg.Type == "Carpet" then
		-- Carpets only have one visible travel span, so synthesize both terminal zones.
		if alpha <= 0.15 then
			isStation = true
			stationTag = "Start"
		elseif alpha >= 0.85 then
			isStation = true
			stationTag = "End"
		end
	end

	return pos, isStation, stationTag, tangent
end

function GetLiftStartPos(lift)
	if not lift then
		return Vector3.zero
	end

	local ss = lift:FindFirstChild("StartStation")
	local queueAttachment = QueueSystem.GetQueueAttachment(lift)
	local explicitLoadHere = ss and ss:FindFirstChild("LoadHere", true) or nil
	local queueStart = (queueAttachment or explicitLoadHere) and QueueSystem.GetQueueStartPosition(lift) or nil
	if queueStart then
		if queueAttachment or explicitLoadHere then
			local queuePos = GetLiftQueueLinePose and select(1, GetLiftQueueLinePose(lift)) or nil
			if queuePos then
				return ResolveWalkableGroundPos(queuePos, GetQueueGroundExtras(lift), false)
			end
		end
		local approachDir = Vector3.new(0, 0, 1)
		if queueAttachment then
			approachDir = GetFlatLookVector(-queueAttachment.WorldCFrame.LookVector, Vector3.new(0, 0, 1))
		elseif ss then
			approachDir = GetFlatLookVector(-ss:GetPivot().LookVector, Vector3.new(0, 0, 1))
		end
		local approachOffset = IsCarpetLift(lift) and 1.5 or 4
		return ResolveWalkableGroundPos(queueStart + (approachDir * approachOffset), GetQueueGroundExtras(lift), false)
	end

	if ss then
		local pos = GetStationReferencePoint(ss, "LoadHere")
		if pos then
			local flatLook = GetFlatLookVector(-ss:GetPivot().LookVector, Vector3.new(0, 0, 1))
			local approachOffset = IsCarpetLift(lift) and 1.5 or 4
			return ResolveWalkableGroundPos(pos + (flatLook * approachOffset), ss, false)
		end
		local fallbackOffset = IsCarpetLift(lift) and 2.5 or 5
		return ResolveWalkableGroundPos(ss:GetPivot().Position - (ss:GetPivot().LookVector * fallbackOffset), ss, false)
	end
	return ResolveWalkableGroundPos(lift:GetPivot().Position, lift, false)
end

function IsCarpetLift(lift)
	if not lift then
		return false
	end
	local _, itemCfg = GetConfigItemForModel(lift)
	return itemCfg and itemCfg.Type == "Carpet"
end

function GetLiftEndPos(lift, useFallbackOffset)
	local es = lift:FindFirstChild("EndStation")
	if es then
		local unloadPos = GetStationReferencePoint(es, "UnloadHere") or GetStationReferencePoint(es, "LoadHere")
		if unloadPos then
			if useFallbackOffset then
				local forwardDist = IsCarpetLift(lift) and 10 or 6
				return ResolveWalkableGroundPos(unloadPos + (es:GetPivot().LookVector * forwardDist), es, false)
			end
			return unloadPos
		end
		local pivot = es:GetPivot()
		local targetPos = pivot.Position
		if useFallbackOffset then
			local forwardDist = IsCarpetLift(lift) and 12 or 8
			targetPos = pivot.Position + pivot.LookVector * forwardDist
		end
		return ResolveWalkableGroundPos(targetPos, es, false)
	end
	return ResolveWalkableGroundPos(lift:GetPivot().Position, lift, false)
end

function GetLiftBoardingDirection(liftModel)
	if not liftModel then
		return nil
	end
	local startPos = GetLiftStartPos(liftModel)
	local endPos = GetLiftEndPos(liftModel, false)
	local flat = Vector3.new(endPos.X - startPos.X, 0, endPos.Z - startPos.Z)
	if flat.Magnitude < 0.001 then
		return nil
	end
	return flat.Unit
end

local GetLiftRoutingConfig

function GetLiftOperationalSpeedMultiplier(liftModel)
	if not liftModel or not liftModel.Parent then
		return 0
	end

	local status = string.lower(tostring(liftModel:GetAttribute("Status") or ""))
	local speedMult = tonumber(liftModel:GetAttribute("TargetSpeed"))

	if speedMult == nil then
		local uuid = liftModel:GetAttribute("UUID") or ""
		if uuid ~= "" then
			local liftCache = ReplicatedStorage:FindFirstChild("LiftCache")
			local cacheObj = liftCache and liftCache:FindFirstChild(uuid)
			if cacheObj then
				speedMult = tonumber(cacheObj:GetAttribute("RefSpeed"))
			end
		end
	end

	if speedMult == nil then
		if status == "stopped" or status == "broken" then
			speedMult = 0
		elseif status == "slow" then
			speedMult = 0.5
		else
			speedMult = 1
		end
	end

	if status == "broken" or status == "stopped" then
		return 0
	end
	if status == "stopped" and speedMult <= 0.05 then
		return 0
	end

	return math.clamp(speedMult, 0, 1.5)
end

function IsLiftOperationalForGuestRouting(liftModel)
	if not liftModel or not liftModel.Parent then
		return false
	end

	local status = string.lower(tostring(liftModel:GetAttribute("Status") or ""))
	local targetSpeed = tonumber(liftModel:GetAttribute("TargetSpeed"))
	if status == "broken" or status == "stopped" then
		return false
	end
	if targetSpeed ~= nil and targetSpeed <= 0.05 then
		return false
	end
	if not liftModel:FindFirstChild("StartStation") then
		return false
	end

	return GetLiftOperationalSpeedMultiplier(liftModel) > 0.05
end

function IsLiftBoardingAvailable(liftModel)
	return IsLiftOperationalForGuestRouting(liftModel)
end

local LiftSeatCountCache = {}

local function ParseSeatMarkerIndex(name)
	if type(name) ~= "string" then
		return nil
	end
	local token = string.match(name, "^Seat[_%-%s]?(%d+)$")
	return token and tonumber(token) or nil
end

local function CountSeatDescendants(inst)
	if not inst then
		return 0
	end

	local seatClassCount = 0
	local numberedMarkers = {}
	local markerCount = 0
	local hasGenericSeatMarker = false

	for _, desc in ipairs(inst:GetDescendants()) do
		if desc:IsA("Seat") or desc:IsA("VehicleSeat") then
			seatClassCount += 1
		end

		local markerIdx = ParseSeatMarkerIndex(desc.Name)
		if markerIdx ~= nil and not numberedMarkers[markerIdx] then
			numberedMarkers[markerIdx] = true
			markerCount += 1
		elseif desc.Name == "Seat" and (desc:IsA("BasePart") or desc:IsA("Attachment") or desc:IsA("Bone")) then
			hasGenericSeatMarker = true
		end
	end

	if markerCount <= 0 and hasGenericSeatMarker then
		markerCount = 1
	end

	if markerCount > 0 then
		return math.max(markerCount, seatClassCount)
	end
	return seatClassCount
end

local function FindLiftAssetFolder(configName)
	local itemCfg = Config.Items[configName]
	if not itemCfg then
		return nil
	end

	local targetId = tostring(itemCfg.ID or "")
	if targetId ~= "" then
		for _, asset in ipairs(LiftAssets:GetChildren()) do
			if tostring(asset:GetAttribute("ID") or "") == targetId then
				return asset
			end
		end
	end

	return LiftAssets:FindFirstChild(configName)
end

local function ResolveLiftSeatCount(configName)
	local cached = LiftSeatCountCache[configName]
	if cached then
		return cached
	end

	local itemCfg = Config.Items[configName]
	local configCapacity = tonumber(itemCfg and itemCfg.Capacity) or 0
	local resolved = configCapacity > 0 and configCapacity or 2

	local asset = FindLiftAssetFolder(configName)
	if asset then
		local assetSeatCount = 0
		local primaryCarrier = asset:FindFirstChild("Chair", true)
			or asset:FindFirstChild("Gondola", true)
			or asset:FindFirstChild("Carrier", true)
			or asset:FindFirstChild("Cabin", true)
		assetSeatCount = math.max(assetSeatCount, CountSeatDescendants(primaryCarrier))

		if assetSeatCount <= 0 then
			for _, child in ipairs(asset:GetChildren()) do
				if child:IsA("Model") then
					assetSeatCount = math.max(assetSeatCount, CountSeatDescendants(child))
				end
			end
		end

		if assetSeatCount > 0 then
			resolved = math.max(1, math.min(resolved, assetSeatCount))
		end
	end

	LiftSeatCountCache[configName] = resolved
	return resolved
end

function GetSeatCountForLift(configName)
	return ResolveLiftSeatCount(configName)
end

-- Find a boardable chair with an available seat
-- Track which seats have guests on them: { ["uuid_chairId_seatIdx"] = guestModel }
local OccupiedChairs = {}
local lastOccupiedChairsCleanup = 0

-- Periodic cleanup: remove stale occupied chair entries for guests that no longer exist
-- or are no longer riding. Without this, removed/destroyed guests permanently block seats.
function ParseOccupiedChairKey(key)
	if type(key) ~= "string" then
		return nil, nil, nil
	end
	local liftUUID, chairId, seatIdx = string.match(key, "^(.-)_(%d+)_(%d+)$")
	if not liftUUID or liftUUID == "" then
		return nil, nil, nil
	end
	return liftUUID, tonumber(chairId), tonumber(seatIdx)
end

function CleanupOccupiedChairs(force)
	local now = tick()
	if not force and (now - lastOccupiedChairsCleanup) < 5 then return end
	lastOccupiedChairsCleanup = now
	local stale = {}
	for key, guestModel in pairs(OccupiedChairs) do
		if not guestModel or not guestModel.Parent then
			table.insert(stale, key)
		else
			local data = AllGuests[guestModel]
			if not data or data.State ~= STATE.RIDING_LIFT then
				table.insert(stale, key)
			else
				local liftUUID, chairId, seatIdx = ParseOccupiedChairKey(key)
				if not liftUUID
					or data.LiftUUID ~= liftUUID
					or data.LiftChairId ~= chairId
					or data.LiftSeatIdx ~= seatIdx then
					table.insert(stale, key)
				end
			end
		end
	end
	if #stale > 0 then
		for _, key in ipairs(stale) do
			OccupiedChairs[key] = nil
		end
	end
end

local function GetSeatIndexFromSeatName(seatName)
	if type(seatName) ~= "string" then
		return nil
	end
	local parsed = string.match(seatName, "Seat_(%d+)") or string.match(seatName, "Seat(%d+)")
	return parsed and tonumber(parsed) or nil
end

local function IsSeatOccupiedByPlayer(liftUUID, chairId, seatIdx)
	for _, player in ipairs(Players:GetPlayers()) do
		if player:GetAttribute("RidingLift") == liftUUID and player:GetAttribute("RidingChair") == chairId then
			local playerSeatIdx = GetSeatIndexFromSeatName(player:GetAttribute("RidingSeat"))
			if playerSeatIdx == nil or playerSeatIdx == seatIdx then
				return true
			end
		end
	end
	return false
end

local function IsSeatCurrentlyTaken(liftUUID, chairId, seatIdx)
	local occupyKey = liftUUID .. "_" .. chairId .. "_" .. seatIdx
	if OccupiedChairs[occupyKey] then
		return true
	end
	if IsSeatOccupiedByPlayer(liftUUID, chairId, seatIdx) then
		return true
	end
	return false
end

local MIN_BOARDING_DIRECTION_DOT = 0.45
local START_STATION_DISTANCE_PADDING = 6

function IsChairBoardableAtStartStation(chairPos, isStation, stationTag, chairTangent, boardingDirection, startPos, endPos, boardWindow, isCarpet)
	if not chairPos or not isStation or stationTag ~= "Start" then
		return false
	end

	local distToStart = FlatDist(chairPos, startPos)
	local maxStartDist = math.max((tonumber(boardWindow) or 0) + START_STATION_DISTANCE_PADDING, isCarpet and 24 or 18)
	if distToStart > maxStartDist then
		return false
	end

	if endPos then
		local distToEnd = FlatDist(chairPos, endPos)
		if (distToEnd + START_STATION_DISTANCE_PADDING) < distToStart then
			return false
		end
	end

	if boardingDirection and chairTangent and not isCarpet then
		local flatTangent = Vector3.new(chairTangent.X, 0, chairTangent.Z)
		if flatTangent.Magnitude > 0.001 and flatTangent.Unit:Dot(boardingDirection) < MIN_BOARDING_DIRECTION_DOT then
			return false
		end
	end

	return true
end

-- Returns: chairId, seatIndex, distance  (or nil if none available)
function FindBoardableChair(liftModel, guestPos, maxRange)
	local uuid = liftModel:GetAttribute("UUID")
	if not uuid then return nil, nil, nil end
	if not IsLiftBoardingAvailable(liftModel) then return nil, nil, nil end

	CleanupOccupiedChairs()

	local parsed = ParsedLiftData[uuid] or ParseLiftCache(uuid)
	if not parsed or parsed.ChairCount == 0 then return nil, nil, nil end
	local routing = GetLiftRoutingConfig()

	local masterTime = GetLiftMasterTime(uuid)
	local startPos = GetLiftStartPos(liftModel)
	local endPos = GetLiftEndPos(liftModel, false)
	local boardAnchor = guestPos or select(1, GetLiftQueueLinePose(liftModel)) or startPos
	local seatCount = GetSeatCountForLift(parsed.ConfigName)
	local itemCfg = Config.Items[parsed.ConfigName]
	local isCarpet = itemCfg and itemCfg.Type == "Carpet"
	local boardWindow = math.max(2, tonumber(maxRange) or LIFT_QUEUE_BOARD_DISTANCE)
	if isCarpet then
		boardWindow = math.max(boardWindow, 20)
	end
	local boardingDirection = GetLiftBoardingDirection(liftModel)

	local bestChairId = nil
	local bestSeatIdx = nil
	local bestDist = boardWindow
	local chairCount = math.max(0, tonumber(parsed.ChairCount) or 0)
	if chairCount <= 0 then return nil, nil, nil end
	local correctedSpacing = tonumber(parsed.CorrectedTimeSpacing) or 5

	for i = 1, chairCount do
		local offset = (i - 1) * correctedSpacing
		local chairPos, isStation, stationTag, chairTangent = GetChairPosFromTime(parsed, masterTime, offset)
		if chairPos then
			local dist = FlatDist(chairPos, boardAnchor)
			local boardableAtStart = IsChairBoardableAtStartStation(
				chairPos,
				isStation,
				stationTag,
				chairTangent,
				boardingDirection,
				startPos,
				endPos,
				boardWindow,
				isCarpet
			)
			if boardableAtStart and dist < bestDist then
				for s = 1, seatCount do
					if not IsSeatCurrentlyTaken(uuid, i, s) then
						bestDist = dist
						bestChairId = i
						bestSeatIdx = s
						break
					end
				end
			end
		end
	end

	return bestChairId, bestSeatIdx, bestDist
end

-- Extended version with configurable range (for auto-seat timeout on gondolas etc)
function FindBoardableChairExtended(liftModel, guestPos, maxRange)
	local uuid = liftModel:GetAttribute("UUID")
	if not uuid then return nil, nil, nil end
	if not IsLiftBoardingAvailable(liftModel) then return nil, nil, nil end

	CleanupOccupiedChairs(true)

	local parsed = ParsedLiftData[uuid] or ParseLiftCache(uuid)
	if not parsed or parsed.ChairCount == 0 then return nil, nil, nil end
	local routing = GetLiftRoutingConfig()

	local masterTime = GetLiftMasterTime(uuid)
	local startPos = GetLiftStartPos(liftModel)
	local endPos = GetLiftEndPos(liftModel, false)
	local boardAnchor = guestPos or select(1, GetLiftQueueLinePose(liftModel)) or startPos
	local seatCount = GetSeatCountForLift(parsed.ConfigName)
	local itemCfg = Config.Items[parsed.ConfigName]
	local isCarpet = itemCfg and itemCfg.Type == "Carpet"
	local boardWindow = math.max(2, tonumber(maxRange) or LIFT_QUEUE_BOARD_EXTENDED_DISTANCE)
	if isCarpet then
		boardWindow = math.max(boardWindow, 24)
	end
	local boardingDirection = GetLiftBoardingDirection(liftModel)

	local bestChairId = nil
	local bestSeatIdx = nil
	local bestDist = boardWindow
	local chairCount = math.max(0, tonumber(parsed.ChairCount) or 0)
	if chairCount <= 0 then return nil, nil, nil end
	local correctedSpacing = tonumber(parsed.CorrectedTimeSpacing) or 5

	for i = 1, chairCount do
		local offset = (i - 1) * correctedSpacing
		local chairPos, isStation, stationTag, chairTangent = GetChairPosFromTime(parsed, masterTime, offset)
		if chairPos then
			local dist = FlatDist(chairPos, boardAnchor)
			local boardableAtStart = IsChairBoardableAtStartStation(
				chairPos,
				isStation,
				stationTag,
				chairTangent,
				boardingDirection,
				startPos,
				endPos,
				boardWindow,
				isCarpet
			)
			if boardableAtStart and dist < bestDist then
				for s = 1, seatCount do
					if not IsSeatCurrentlyTaken(uuid, i, s) then
						bestDist = dist
						bestChairId = i
						bestSeatIdx = s
						break
					end
				end
			end
		end
	end

	return bestChairId, bestSeatIdx, bestDist
end

-- Cache: which slopes are near each lift's end station
local LiftSlopeCache = {} -- { [liftModel] = { slopeModels, bestDifficulty, cacheTime } }
local LIFT_SLOPE_CACHE_TTL = 10 -- refresh every 10s (slopes may load late)
local MAX_GUEST_ACCESSORIES = 5

GetLiftRoutingConfig = function()
	local cfg = (GuestConfig.Spawn and GuestConfig.Spawn.LiftRouting) or {}
	return {
		OvercrowdedPressure = tonumber(cfg.OvercrowdedPressure) or 3.2,
		HardOvercrowdedPressure = tonumber(cfg.HardOvercrowdedPressure) or 4.8,
		MismatchMinPressure = tonumber(cfg.MismatchMinPressure) or 2.0,
		RerouteWaitSeconds = tonumber(cfg.RerouteWaitSeconds) or 10,
		AvoidLiftSeconds = tonumber(cfg.AvoidLiftSeconds) or 20,
		AllowMismatchWhenCrowded = cfg.AllowMismatchWhenCrowded ~= false,
		SameLiftRepeatPenalty = tonumber(cfg.SameLiftRepeatPenalty) or 0.9,
		CrowdPenaltyTickSeconds = tonumber(cfg.CrowdPenaltyTickSeconds) or 8,
		MinChairSpacingSeconds = tonumber(cfg.MinChairSpacingSeconds) or 2.2,
		MaxChairScan = math.max(8, math.floor(tonumber(cfg.MaxChairScan) or 80)),
	}
end

function GetQueueBehaviorConfig()
	local cfg = (GuestConfig.Spawn and GuestConfig.Spawn.QueueBehavior) or {}
	return {
		MinCommitWaitSeconds = math.max(0, tonumber(cfg.MinCommitWaitSeconds) or 25),
		RerouteCheckStartSeconds = math.max(0, tonumber(cfg.RerouteCheckStartSeconds) or 40),
		RerouteIfPredictedWaitAbove = math.max(5, tonumber(cfg.RerouteIfPredictedWaitAbove) or 80),
		MinImprovementToRerouteSeconds = math.max(1, tonumber(cfg.MinImprovementToRerouteSeconds) or 25),
		RerouteCooldownSeconds = math.max(1, tonumber(cfg.RerouteCooldownSeconds) or 15),
		EmergencyPressure = math.max(1.2, tonumber(cfg.EmergencyPressure) or 3.4),
		BoardingDistance = math.clamp(tonumber(cfg.BoardingDistance) or LIFT_QUEUE_BOARD_DISTANCE, 8.0, 42),
		BoardingExtendedDistance = math.clamp(tonumber(cfg.BoardingExtendedDistance) or LIFT_QUEUE_BOARD_EXTENDED_DISTANCE, 10.0, 52),
		BoardingExtendedDelaySeconds = math.clamp(tonumber(cfg.BoardingExtendedDelaySeconds) or LIFT_QUEUE_BOARD_EXTENDED_DELAY_SECONDS, 0, 60),
		ConnectedLiftMaxFlatDistance = math.max(40, tonumber(cfg.ConnectedLiftMaxFlatDistance) or 360),
		ConnectedLiftMaxRise = math.max(20, tonumber(cfg.ConnectedLiftMaxRise) or 70),
		ConnectedLiftMaxDrop = math.max(40, tonumber(cfg.ConnectedLiftMaxDrop) or 180),
		SlopeEntryMaxFlatDistance = math.max(50, tonumber(cfg.SlopeEntryMaxFlatDistance) or 650),
		SlopeEntryMaxRise = math.max(30, tonumber(cfg.SlopeEntryMaxRise) or 140),
		SlopeEntryMinRemainingLength = math.max(25, tonumber(cfg.SlopeEntryMinRemainingLength) or 90),
	}
end

local GetLiftQueueSoftLimit

function GetLiftQueuePressure(liftModel)
	if not liftModel then return 0 end
	local liftUUID = liftModel:GetAttribute("UUID") or ""
	if liftUUID == "" then return 0 end

	local queueLoad = 0
	local queueStats = LiftQueueStats[liftUUID]
	if queueStats then
		-- Walking guests are intent only; riders already on the cable should barely affect crowding.
		queueLoad = (queueStats.walking * 0.04) + (queueStats.waiting * 1.0) + (queueStats.riding * 0.04)
	end

	local routing = GetLiftRoutingConfig()
	local speedFactor = GetLiftOperationalSpeedMultiplier(liftModel)
	if speedFactor <= 0.05 then
		return math.max(routing.HardOvercrowdedPressure + 1, routing.OvercrowdedPressure + 1)
	end
	local parsed = ParsedLiftData[liftUUID] or ParseLiftCache(liftUUID)
	local seatCount = GetSeatCountForLift(parsed and parsed.ConfigName or liftModel.Name)
	local spacing = math.max(
		tonumber(routing.MinChairSpacingSeconds) or 2.2,
		tonumber(parsed and parsed.CorrectedTimeSpacing) or 5
	)
	local seatsPerSecond = (seatCount / math.max(1, spacing)) * speedFactor
	local queueCapacity = math.max(3.5, seatsPerSecond * 16)

	return queueLoad / queueCapacity
end

function GetLiftPredictedWaitSeconds(liftModel, queuePressureOverride)
	if not liftModel then return 0 end
	local liftUUID = liftModel:GetAttribute("UUID") or ""
	local parsed = (liftUUID ~= "" and (ParsedLiftData[liftUUID] or ParseLiftCache(liftUUID))) or nil
	local routing = GetLiftRoutingConfig()
	local speedFactor = GetLiftOperationalSpeedMultiplier(liftModel)
	if speedFactor <= 0.05 then
		return 9999
	end
	local seatCount = GetSeatCountForLift(parsed and parsed.ConfigName or liftModel.Name)
	local spacing = math.max(
		tonumber(routing.MinChairSpacingSeconds) or 2.2,
		tonumber(parsed and parsed.CorrectedTimeSpacing) or 5
	)
	local seatsPerSecond = math.max(0.04, (seatCount / math.max(1, spacing)) * speedFactor)
	local queueInfo = liftUUID ~= "" and LiftQueueStats[liftUUID] or nil
	local waitingCount = queueInfo and queueInfo.waiting or 0
	local walkingCount = queueInfo and queueInfo.walking or 0
	local baseWait = (waitingCount + (walkingCount * 0.04)) / seatsPerSecond
	local pressure = tonumber(queuePressureOverride) or GetLiftQueuePressure(liftModel)
	local softLimit = GetLiftQueueSoftLimit(liftModel)
	local overflow = math.max(0, waitingCount - softLimit)
	local overflowPenalty = overflow / seatsPerSecond
	local pressurePenalty = math.max(0, pressure - 2.6) * 2
	return baseWait + overflowPenalty + pressurePenalty + 2.5
end

GetLiftQueueSoftLimit = function(liftModel)
	if not liftModel then
		return 20
	end
	local liftUUID = liftModel:GetAttribute("UUID") or ""
	local parsed = (liftUUID ~= "" and (ParsedLiftData[liftUUID] or ParseLiftCache(liftUUID))) or nil
	local seatCount = GetSeatCountForLift(parsed and parsed.ConfigName or liftModel.Name)
	local spacing = math.max(1.5, (parsed and parsed.CorrectedTimeSpacing) or 5)
	local seatsPerSecond = seatCount / spacing
	local estimate = (seatCount * 5) + (seatsPerSecond * 22)
	return math.clamp(math.floor(estimate + 0.5), 14, 42)
end

function FlattenQueueDirection(v: Vector3?, fallback: Vector3): Vector3
	local dir = v and Vector3.new(v.X, 0, v.Z) or fallback
	if dir.Magnitude < 0.001 then
		return fallback
	end
	return dir.Unit
end

function GetQueueGroundExtras(queueModel: Instance?)
	if queueModel and queueModel.Parent then
		return { queueModel }
	end
	return nil
end

function ResolveQueueSurfaceY(liftModel: Model?, x: number, z: number, fallbackY: number): number
	local queueModel = nil
	if _G.QueueServer and liftModel then
		local liftUUID = liftModel:GetAttribute("UUID")
		if liftUUID and _G.QueueServer.Queues then
			local queueData = _G.QueueServer.Queues[liftUUID]
			queueModel = queueData and queueData.Model or nil
		end
	end
	local resolved = ResolveWalkableGroundPos(Vector3.new(x, fallbackY or 0, z), GetQueueGroundExtras(queueModel), false)
	return resolved.Y
end

function GetLiftQueueLoadHereLines(liftModel: Model?)
	if not liftModel then
		return {
			{
				position = Vector3.new(0, 0, 0),
				queueDir = Vector3.zAxis,
			},
		}
	end

	local now = tick()
	local cached = LiftQueueLoadHereCache[liftModel]
	if cached and (now - (cached.at or 0)) < LIFT_QUEUE_LOADHERE_CACHE_TTL and cached.lines and #cached.lines > 0 then
		return cached.lines
	end

	local startStation = liftModel:FindFirstChild("StartStation")
	local queueAttachment = QueueSystem.GetQueueAttachment(liftModel)
	local queueStart = QueueSystem.GetQueueStartPosition(liftModel)
	local fallbackDir = Vector3.zAxis
	if startStation then
		local stationLook = startStation:GetPivot().LookVector
		fallbackDir = FlattenQueueDirection(Vector3.new(-stationLook.X, 0, -stationLook.Z), Vector3.zAxis)
	end

	local lines = {}
	if queueAttachment and queueStart then
		local markerPos = queueAttachment.WorldPosition
		local queueDir = fallbackDir
		if queueAttachment:IsA("Attachment") then
			queueDir = FlattenQueueDirection(Vector3.new(-queueAttachment.WorldCFrame.LookVector.X, 0, -queueAttachment.WorldCFrame.LookVector.Z), fallbackDir)
		elseif queueAttachment:IsA("BasePart") then
			queueDir = FlattenQueueDirection(Vector3.new(-queueAttachment.CFrame.LookVector.X, 0, -queueAttachment.CFrame.LookVector.Z), fallbackDir)
		end
		local y = ResolveQueueSurfaceY(liftModel, markerPos.X, markerPos.Z, markerPos.Y)
		table.insert(lines, {
			position = Vector3.new(markerPos.X, y, markerPos.Z),
			queueDir = queueDir,
		})
		LiftQueueLoadHereCache[liftModel] = {
			at = now,
			lines = lines,
		}
		return lines
	end

	if startStation then
		for _, desc in ipairs(startStation:GetDescendants()) do
			if desc.Name == "LoadHere" then
				local markerPos = nil
				local markerDir = nil
				if desc:IsA("Attachment") then
					markerPos = desc.WorldPosition
					markerDir = -desc.WorldCFrame.LookVector
				elseif desc:IsA("BasePart") then
					markerPos = desc.Position
					markerDir = -desc.CFrame.LookVector
				end
				if markerPos then
					local queueDir = fallbackDir
					if markerDir then
						queueDir = FlattenQueueDirection(Vector3.new(markerDir.X, 0, markerDir.Z), fallbackDir)
					end
					local y = ResolveQueueSurfaceY(liftModel, markerPos.X, markerPos.Z, markerPos.Y)
					table.insert(lines, {
						position = Vector3.new(markerPos.X, y, markerPos.Z),
						queueDir = queueDir,
					})
				end
			end
		end
	end

	if #lines == 0 then
		local loadPos = GetLiftStartPos(liftModel)
		local y = ResolveQueueSurfaceY(liftModel, loadPos.X, loadPos.Z, loadPos.Y)
		lines = {
			{
				position = Vector3.new(loadPos.X, y, loadPos.Z),
				queueDir = fallbackDir,
			},
		}
	end

	LiftQueueLoadHereCache[liftModel] = {
		at = now,
		lines = lines,
	}
	return lines
end

function GetLiftQueueLinePose(liftModel)
	local lines = GetLiftQueueLoadHereLines(liftModel)
	local first = lines[1]
	return first.position, first.queueDir, lines
end

-- Cache for player-placed queue path points per lift UUID
local QueuePathCache = setmetatable({}, { __mode = "v" })
local QUEUE_PATH_CACHE_TTL = 5

local function FindQueuePathForLift(liftModel)
	if not liftModel then return nil end
	local liftUUID = liftModel:GetAttribute("UUID")
	if not liftUUID or liftUUID == "" then return nil end

	local now = tick()
	local cached = QueuePathCache[liftUUID]
	if cached and (now - (cached.at or 0)) < QUEUE_PATH_CACHE_TTL then
		return cached.path -- may be nil if no queue path exists
	end

	local placedFolder = Workspace:FindFirstChild("PlacedObjects")
	if not placedFolder then
		QueuePathCache[liftUUID] = { at = now, path = nil }
		return nil
	end

	for _, child in ipairs(placedFolder:GetChildren()) do
		if child:IsA("Model") and child:GetAttribute("IsQueue") == true then
			local targetUUID = child:GetAttribute("TargetUUID")
			if targetUUID == liftUUID then
				local slopeData = GetSlopeData(child)
				if slopeData and slopeData.Path and #slopeData.Path >= 2 then
					QueuePathCache[liftUUID] = { at = now, path = slopeData.Path }
					return slopeData.Path
				end
			end
		end
	end

	QueuePathCache[liftUUID] = { at = now, path = nil }
	return nil
end

function GetLiftQueueSlotTarget(liftModel, slotIndex, laneOffset)
	local loadPos, queueDir, lines = GetLiftQueueLinePose(liftModel)

	-- Check for player-placed queue path
	local queuePath = FindQueuePathForLift(liftModel)
	if queuePath and #queuePath >= 2 then
		local slot = math.max(1, math.floor(slotIndex or 1))
		-- Walk along the queue path, spacing guests evenly
		local totalDist = 0
		local segDists = {}
		for i = 1, #queuePath - 1 do
			local d = (queuePath[i + 1] - queuePath[i]).Magnitude
			table.insert(segDists, d)
			totalDist += d
		end

		-- Place the first guest near the end of the path (closest to lift), subsequent ones further back
		local distFromEnd = (slot - 1) * LIFT_QUEUE_SLOT_SPACING
		if distFromEnd > totalDist then
			-- Overflow: extend past the end of the path in the same direction
			local lastDir = (queuePath[#queuePath] - queuePath[#queuePath - 1])
			if lastDir.Magnitude > 0.1 then lastDir = lastDir.Unit else lastDir = Vector3.zAxis end
			-- Guests past the path end queue up in a straight line extending from the start
			local startDir = (queuePath[1] - queuePath[2])
			if startDir.Magnitude > 0.1 then startDir = startDir.Unit else startDir = -lastDir end
			local overflowDist = distFromEnd - totalDist
			local target = queuePath[1] + startDir * overflowDist
			local y = ResolveQueueSurfaceY(liftModel, target.X, target.Z, queuePath[1].Y)
			return Vector3.new(target.X, y, target.Z), slot, 1, 1
		end

		-- Walk backwards from end of path (end = near lift, start = far from lift)
		local remaining = distFromEnd
		for i = #segDists, 1, -1 do
			if remaining <= segDists[i] then
				local t = remaining / math.max(0.01, segDists[i])
				local pos = queuePath[i + 1]:Lerp(queuePath[i], t)
				local y = ResolveQueueSurfaceY(liftModel, pos.X, pos.Z, pos.Y)
				return Vector3.new(pos.X, y, pos.Z), slot, 1, 1
			end
			remaining -= segDists[i]
		end

		-- Fallback to start of path
		local p = queuePath[1]
		local y = ResolveQueueSurfaceY(liftModel, p.X, p.Z, p.Y)
		return Vector3.new(p.X, y, p.Z), slot, 1, 1
	end

	-- Original straight-line queue behavior
	lines = lines or {}
	local line = lines[1]
	if not line then
		line = {
			position = loadPos,
			queueDir = queueDir,
		}
		lines = { line }
	end

	local slot = math.max(1, math.floor(slotIndex or 1))
	local lineCount = math.max(1, #lines)
	local lineIndex = math.clamp(((slot - 1) % lineCount) + 1, 1, lineCount)
	line = lines[lineIndex] or line
	local depthIndex = math.max(1, math.floor((slot - 1) / lineCount) + 1)
	local lineDir = FlattenQueueDirection(line.queueDir, queueDir)
	local depthOffset = (depthIndex - 1) * LIFT_QUEUE_SLOT_SPACING
	local target = line.position + (lineDir * depthOffset)
	return Vector3.new(target.X, line.position.Y, target.Z), depthIndex, lineIndex, lineCount
end

function ComputeLiftQueueIndexFallback(data, liftUUID)
	if not data or not liftUUID or liftUUID == "" then return 1 end
	local now = tick()
	local myJoinTime = tonumber(data.WaitStartTime) or now
	local mySpawnTime = tonumber(data.SpawnTime) or now
	local index = 1
	for _, otherData in pairs(AllGuests) do
		if otherData ~= data
			and otherData.State == STATE.WAITING_LIFT
			and otherData.TargetLift
			and otherData.TargetLift.Parent
			and (otherData.TargetLift:GetAttribute("UUID") or "") == liftUUID then
			local otherJoin = tonumber(otherData.WaitStartTime) or now
			local otherSpawn = tonumber(otherData.SpawnTime) or now
			if otherJoin < myJoinTime or (otherJoin == myJoinTime and otherSpawn < mySpawnTime) then
				index += 1
			end
		end
	end
	return index
end

function GetLiftQueueIndex(data, liftUUID)
	if not data or not data.Model then
		return 1
	end
	local idx = LiftQueueIndexByModel[data.Model]
	if idx and idx > 0 then
		return idx
	end
	return ComputeLiftQueueIndexFallback(data, liftUUID)
end

function UpdateWaitingGuestQueuePosition(data, liftModel, queueIndex, now)
	if not data or not data.Root or not liftModel then return nil, nil, nil, nil, nil end
	local slot = math.clamp(math.floor(queueIndex or 1), 1, LIFT_QUEUE_MAX_TRACKED_SLOTS)
	data.QueueSlotIndex = slot
	local slotTarget, depthIndex, lineIndex, lineCount = GetLiftQueueSlotTarget(liftModel, slot, 0)
	if data.Model and data.Model.Parent then
		data.Model:SetAttribute("LiftQueueIndex", slot)
		data.Model:SetAttribute("LiftQueueDepth", depthIndex)
		data.Model:SetAttribute("LiftQueueLineIndex", lineIndex)
		data.Model:SetAttribute("LiftQueueLineCount", lineCount)
	end
	local distToSlot = FlatDist(data.Root.Position, slotTarget)
	data.QueueDepth = depthIndex
	data.QueueLineIndex = lineIndex
	data.QueueLineCount = lineCount

	local targetChanged = (not data.LastQueueSlotTarget) or (FlatDist(data.LastQueueSlotTarget, slotTarget) > 1.35)
	local needsRefresh = (not data.LastQueueMoveIssuedAt) or ((now - data.LastQueueMoveIssuedAt) >= LIFT_QUEUE_MOVE_REFRESH_SECONDS)
	if targetChanged or (needsRefresh and distToSlot > 2.6) then
		MoveGuestTo(data, slotTarget, nil)
		data.LastQueueMoveIssuedAt = now
		data.LastQueueSlotTarget = slotTarget
	end

	return slotTarget, distToSlot, depthIndex, lineIndex, lineCount
end

-- Invalidate cache when new slopes are placed
function InvalidateLiftSlopeCache()
	LiftSlopeCache = {}
end

function GetLiftServedSlopesInternal(liftModel, allSlopes, allLifts, visited, addedSlopes)
	if visited[liftModel] then return {}, {} end
	visited[liftModel] = true

	local endPos = GetLiftEndPos(liftModel, true)
	if not endPos then
		local es = liftModel:FindFirstChild("EndStation")
		if es then
			endPos = ResolveWalkableGroundPos(es:GetPivot().Position, es, false)
		else
			endPos = ResolveWalkableGroundPos(liftModel:GetPivot().Position, liftModel, false)
		end
	end

	local nearbySlopes = {}
	local difficulties = {}
	local diffToNum = { Green = 1, Blue = 2, Black = 3, ["Double Black"] = 4, DoubleBlack = 4, ["Triple Black"] = 5, TripleBlack = 5, Glade = 6 }

	-- 1. Direct slopes
	local routingCfg = (GuestConfig.Spawn and GuestConfig.Spawn.LiftRouting) or {}
	local maxSlopeFlat = tonumber(routingCfg.SlopeEntryMaxFlatDistance) or 650
	local maxSlopeRise = tonumber(routingCfg.SlopeEntryMaxRise) or 140
	local minSlopeRemainingCfg = tonumber(routingCfg.SlopeEntryMinRemainingLength) or 18
	local minSlopeRemaining = math.clamp(minSlopeRemainingCfg, 8, 24)
	for _, slope in ipairs(allSlopes) do
		if IsGuestRideableSlopeModel(slope) then
			local path, diff = GetSlopeData(slope)
			if path and #path > 1 then
				local entryIndex, entryPoint = GetReachableSlopeEntry(path, endPos, maxSlopeFlat, minSlopeRemaining)
				if entryIndex and entryPoint then
					local riseFromLift = entryPoint.Y - endPos.Y
					if riseFromLift <= maxSlopeRise and not addedSlopes[slope] then
						addedSlopes[slope] = true
						table.insert(nearbySlopes, slope)
						local diffNum
						if type(diff) == "number" then
							diffNum = diff
						else
							diffNum = diffToNum[tostring(diff)] or 1
						end
						if not diffNum or diffNum == 0 then
							local _, itemCfg = GetConfigItemForModel(slope)
							if itemCfg and itemCfg.Difficulty then
								diffNum = itemCfg.Difficulty
							end
						end
						diffNum = diffNum or 1
						difficulties[diffNum] = true
					end
				end
			end
		end
	end

	-- 2. Connected lifts (downstream)
	for _, nextLift in ipairs(allLifts) do
		if nextLift ~= liftModel and not visited[nextLift] then
			local nextStartPos = GetLiftStartPos(nextLift)
			if nextStartPos then
				local flatDist = (Vector3.new(endPos.X, 0, endPos.Z) - Vector3.new(nextStartPos.X, 0, nextStartPos.Z)).Magnitude
				local yDiff = nextStartPos.Y - endPos.Y
				local routingCfg = (GuestConfig.Spawn and GuestConfig.Spawn.LiftRouting) or {}
				local maxFlat = tonumber(routingCfg.ConnectedLiftMaxFlatDistance) or 360
				local maxRise = tonumber(routingCfg.ConnectedLiftMaxRise) or 70
				local maxDrop = tonumber(routingCfg.ConnectedLiftMaxDrop) or 180
				if flatDist <= maxFlat and yDiff <= maxRise and yDiff >= -maxDrop then
					local subSlopes, subDiffs = GetLiftServedSlopesInternal(nextLift, allSlopes, allLifts, visited, addedSlopes)
					for _, s in ipairs(subSlopes) do
						table.insert(nearbySlopes, s)
					end
					for d in pairs(subDiffs) do
						difficulties[d] = true
					end
				end
			end
		end
	end

	return nearbySlopes, difficulties
end

function GetLiftServedSlopes(liftModel)
	local cached = LiftSlopeCache[liftModel]
	if cached and (tick() - cached.cacheTime) < LIFT_SLOPE_CACHE_TTL then
		return cached.slopes, cached.difficulties
	end

	local allSlopes = FindBuildingsByType("Slope")
	local allLifts = FindBuildingsByType("Lift")

	local nearbySlopes, difficulties = GetLiftServedSlopesInternal(liftModel, allSlopes, allLifts, {}, {})

	-- DON'T cache empty results — slopes may not have loaded yet
	if #nearbySlopes == 0 then
		return nearbySlopes, difficulties
	end

	LiftSlopeCache[liftModel] = {
		slopes = nearbySlopes,
		difficulties = difficulties,
		cacheTime = tick(),
	}
	return nearbySlopes, difficulties
end

function RefreshLiftQueueStats()
	local stats = {}
	local waitingByLift = {}
	local indexByModel = {}
	local queueOrder = {}

	for _, otherData in pairs(AllGuests) do
		local targetLift = otherData and otherData.TargetLift
		if targetLift and targetLift.Parent then
			local liftUUID = otherData.LiftUUID or targetLift:GetAttribute("UUID")
			if liftUUID and liftUUID ~= "" then
				local entry = stats[liftUUID]
				if not entry then
					entry = { walking = 0, waiting = 0, riding = 0 }
					stats[liftUUID] = entry
				end
				if otherData.State == STATE.WALKING_TO_LIFT then
					entry.walking += 1
				elseif otherData.State == STATE.WAITING_LIFT then
					entry.waiting += 1
					local bucket = waitingByLift[liftUUID]
					if not bucket then
						bucket = {}
						waitingByLift[liftUUID] = bucket
					end
					table.insert(bucket, otherData)
				elseif otherData.State == STATE.RIDING_LIFT then
					entry.riding += 1
				end
			end
		end
	end

	for liftUUID, waitingList in pairs(waitingByLift) do
		if #waitingList > 1 then
			table.sort(waitingList, function(a, b)
				local aJoin = tonumber(a and a.WaitStartTime) or 0
				local bJoin = tonumber(b and b.WaitStartTime) or 0
				if aJoin ~= bJoin then
					return aJoin < bJoin
				end
				local aSpawn = tonumber(a and a.SpawnTime) or 0
				local bSpawn = tonumber(b and b.SpawnTime) or 0
				return aSpawn < bSpawn
			end)
		end

		local orderedModels = {}
		for idx, waitingData in ipairs(waitingList) do
			local model = waitingData and waitingData.Model
			if model and model.Parent then
				orderedModels[idx] = model
				indexByModel[model] = idx
				waitingData.QueueSlotIndex = idx
			end
		end
		queueOrder[liftUUID] = orderedModels
	end

	LiftQueueStats = stats
	LiftQueueOrder = queueOrder
	LiftQueueIndexByModel = indexByModel
end

task.spawn(function()
	while true do
		task.wait(1.0)  -- Lower queue-stat cadence at high populations to reduce server CPU spikes
		RefreshLiftQueueStats()
	end
end)

task.spawn(function()
	while true do
		task.wait(0.75)
		local workers = 0
		local maxWorkers = GetDirectorConfig().MaxSpawnWorkers
		for _, player in ipairs(Players:GetPlayers()) do
			if workers >= maxWorkers then
				break
			end
			local userId = player.UserId
			if FriendCache[userId] then
				PrefetchAvatarDescriptionsForUser(userId)
				workers += 1
			end
		end
	end
end)

function GetOwnerAverageSatisfaction(ownerId)
	local guestList = GetPlayerGuestList(ownerId)
	local total = 0
	local count = 0
	for _, data in ipairs(guestList) do
		if data and data.Model and data.Model.Parent then
			total += tonumber(data.Satisfaction) or 50
			count += 1
		end
	end
	if count == 0 then
		return tonumber(GuestConfig.Satisfaction and GuestConfig.Satisfaction.BaseValue) or 70
	end
	return total / count
end

function GetOwnerAverageQueuePressure(ownerId)
	local lifts = FindBuildingsByType("Lift", ownerId)
	if #lifts == 0 then
		return 0
	end
	local total = 0
	local count = 0
	for _, lift in ipairs(lifts) do
		if lift and lift.Parent then
			total += GetLiftQueuePressure(lift)
			count += 1
		end
	end
	if count == 0 then
		return 0
	end
	return total / count
end

function GetOwnerAveragePredictedQueueWait(ownerId)
	local lifts = FindBuildingsByType("Lift", ownerId)
	if #lifts == 0 then
		return 0
	end
	local total = 0
	local count = 0
	for _, lift in ipairs(lifts) do
		if lift and lift.Parent then
			total += GetLiftPredictedWaitSeconds(lift, nil)
			count += 1
		end
	end
	if count == 0 then
		return 0
	end
	return total / count
end

function GetOwnerUnloadFallbackCount(ownerId)
	local lifts = FindBuildingsByType("Lift", ownerId)
	if #lifts == 0 then
		return 0
	end
	local total = 0
	for _, lift in ipairs(lifts) do
		if lift and lift.Parent then
			local liftUUID = lift:GetAttribute("UUID")
			if liftUUID and liftUUID ~= "" then
				total += LiftUnloadFallbackCount[liftUUID] or 0
			end
		end
	end
	return total
end

function GetOwnerOfferingScore(ownerId)
	local lifts = FindBuildingsByType("Lift", ownerId)
	local slopes = FindBuildingsByType("Slope", ownerId)
	local foods = FindBuildingsByType("Food", ownerId)
	local rentals = FindBuildingsByType("Rental", ownerId)

	local liftCount = #lifts
	local slopeCount = #slopes
	local foodCount = #foods
	local rentalCount = #rentals

	local liftScore = math.clamp(liftCount / 4, 0, 1)
	local slopeScore = math.clamp(slopeCount / 8, 0, 1)
	local serviceScore = math.clamp((foodCount + rentalCount) / 5, 0, 1)
	local varietyScore = 0
	if liftCount > 0 then varietyScore += 0.35 end
	if slopeCount > 0 then varietyScore += 0.30 end
	if foodCount > 0 then varietyScore += 0.20 end
	if rentalCount > 0 then varietyScore += 0.15 end
	varietyScore = math.clamp(varietyScore, 0, 1)

	local satScore = math.clamp(GetOwnerAverageSatisfaction(ownerId) / 100, 0, 1)
	local queueScore = math.clamp(1 - (GetOwnerAverageQueuePressure(ownerId) / 3.4), 0, 1)
	local ratingScore = satScore

	local player = ownerId and Players:GetPlayerByUserId(ownerId) or nil
	if player then
		local ls = player:FindFirstChild("leaderstats")
		local ratingVal = ls and ls:FindFirstChild("Rating")
		if ratingVal then
			ratingScore = math.clamp((tonumber(ratingVal.Value) or 2.5) / 5, 0, 1)
		end
	end

	local score =
		(liftScore * 0.20) +
		(slopeScore * 0.18) +
		(serviceScore * 0.14) +
		(varietyScore * 0.12) +
		(satScore * 0.22) +
		(queueScore * 0.10) +
		(ratingScore * 0.04)

	return math.clamp(score, 0, 1)
end

function GetOwnerTicketPricingSignals(ownerId)
	if ownerId then
		local cached = TicketPricingSignalsCache[ownerId]
		local now = tick()
		if cached and (now - (cached.at or 0)) <= 2 then
			return cached.data
		end
	end

	local player = ownerId and Players:GetPlayerByUserId(ownerId) or nil
	local currentGuests = ownerId and GetPlayerGuestCount(ownerId) or 0
	local maxGuests = 0
	if player then
		maxGuests = GetPlayerGuestDemandTarget(player)
	end

	local occupancy = 0
	if maxGuests > 0 then
		occupancy = currentGuests / maxGuests
	elseif currentGuests > 0 then
		occupancy = 1
	end

	local avgSatisfaction = GetOwnerAverageSatisfaction(ownerId)
	local queuePressure = GetOwnerAverageQueuePressure(ownerId)
	local offeringQuality = GetOwnerOfferingScore(ownerId)
	local timeDemand = GetHourDemandMultiplier(Lighting.ClockTime) * GetSeasonDemandMultiplier()

	local signals = {
		occupancy = occupancy,
		currentGuests = currentGuests,
		maxGuests = maxGuests,
		avgSatisfaction = avgSatisfaction,
		queuePressure = queuePressure,
		offeringQuality = offeringQuality,
		timeDemand = timeDemand,
	}

	if ownerId then
		TicketPricingSignalsCache[ownerId] = { at = tick(), data = signals }
	end
	return signals
end

function ComputeDynamicTicketTargetPrice(ownerId, state, cfg, now)
	local basePrice = tonumber(state.basePrice) or cfg.DefaultBasePrice
	if not cfg.Enabled or not state.dynamicEnabled then
		return basePrice, nil
	end

	local sinceManual = now - (tonumber(state.lastManualUpdate) or 0)
	if sinceManual < cfg.ManualHoldSeconds then
		return basePrice, nil
	end

	local signals = GetOwnerTicketPricingSignals(ownerId)
	local occupancySignal = signals.occupancy - cfg.TargetOccupancy
	local queueSignal = signals.queuePressure - cfg.QueueBaseline
	local satSignal = (cfg.TargetSatisfaction - signals.avgSatisfaction) / 100
	local timeSignal = signals.timeDemand - 1

	local totalSignal =
		(occupancySignal * cfg.OccupancyWeight) +
		(queueSignal * cfg.QueueWeight) +
		(satSignal * cfg.SatisfactionWeight) +
		(timeSignal * cfg.TimeDemandWeight)

	local dynamicMultiplier = math.clamp(1 + totalSignal, cfg.MinDynamicMultiplier, cfg.MaxDynamicMultiplier)
	local targetPrice = basePrice * dynamicMultiplier

	-- Low-quality offerings should not hold premium pricing.
	local qualityCap = basePrice * (0.8 + (signals.offeringQuality * 0.95))
	targetPrice = math.min(targetPrice, qualityCap)
	targetPrice = math.clamp(targetPrice, cfg.MinPrice, cfg.MaxPrice)
	return targetPrice, signals
end

function RecomputeOwnerTicketPrice(ownerId, forceSnap)
	local state = GetTicketPricingState(ownerId)
	if not state then
		return nil, nil
	end

	local cfg = GetDynamicTicketPricingConfig()
	local now = tick()
	local targetPrice, signals = ComputeDynamicTicketTargetPrice(ownerId, state, cfg, now)
	targetPrice = math.clamp(targetPrice or state.basePrice or cfg.DefaultBasePrice, cfg.MinPrice, cfg.MaxPrice)

	if forceSnap then
		state.currentPrice = targetPrice
	else
		local current = tonumber(state.currentPrice) or targetPrice
		state.currentPrice = current + ((targetPrice - current) * cfg.Smoothing)
	end
	state.currentPrice = math.clamp(state.currentPrice, cfg.MinPrice, cfg.MaxPrice)

	local player = ownerId and Players:GetPlayerByUserId(ownerId) or nil
	if player then
		PushTicketPriceAttributes(player, state)
	end
	return state.currentPrice, signals
end

function ApplySavedTicketPricing(player, savedState)
	if not player or not player.Parent or type(savedState) ~= "table" then
		return false
	end

	local cfg = GetDynamicTicketPricingConfig()
	local state = GetTicketPricingState(player.UserId)
	if not state then
		return false
	end

	local savedBase = tonumber(savedState.BasePrice or savedState.basePrice)
	local savedCurrent = tonumber(savedState.CurrentPrice or savedState.currentPrice)
	local savedDynamicEnabled = savedState.DynamicEnabled
	if savedDynamicEnabled == nil then
		savedDynamicEnabled = savedState.dynamicEnabled
	end

	if savedBase and savedBase > 0 then
		state.basePrice = math.clamp(math.floor(savedBase + 0.5), cfg.MinPrice, cfg.MaxPrice)
	end

	if type(savedDynamicEnabled) == "boolean" then
		state.dynamicEnabled = savedDynamicEnabled and cfg.Enabled or false
	end

	if state.dynamicEnabled then
		state.currentPrice = state.basePrice or cfg.DefaultBasePrice
		RecomputeOwnerTicketPrice(player.UserId, true)
	else
		local resolvedCurrent = savedCurrent or state.basePrice or cfg.DefaultBasePrice
		state.currentPrice = math.clamp(math.floor(resolvedCurrent + 0.5), cfg.MinPrice, cfg.MaxPrice)
		PushTicketPriceAttributes(player, state)
	end

	return true
end

GetSavedTicketPricingFn.OnInvoke = function(player)
	if not player or not player.Parent then
		return nil
	end
	local state = GetTicketPricingState(player.UserId)
	if not state then
		return nil
	end
	return {
		BasePrice = math.floor((state.basePrice or 0) + 0.5),
		CurrentPrice = math.floor((state.currentPrice or 0) + 0.5),
		DynamicEnabled = state.dynamicEnabled == true,
	}
end

ApplySavedTicketPricingFn.OnInvoke = function(player, savedState)
	return ApplySavedTicketPricing(player, savedState)
end

function GetOwnerFairLiftTicketPrice(ownerId)
	local cfg = GetDynamicTicketPricingConfig()
	local signals = GetOwnerTicketPricingSignals(ownerId)
	local neutral = cfg.NeutralPriceForDemand

	local offeringQuality = tonumber(signals.offeringQuality) or 0
	local timeDemand = tonumber(signals.timeDemand) or 1
	local queuePressure = tonumber(signals.queuePressure) or 0
	local avgSatisfaction = tonumber(signals.avgSatisfaction) or cfg.TargetSatisfaction

	local qualityFactor = 0.62 + (offeringQuality * 0.95)
	local demandFactor = 0.70 + (math.clamp(timeDemand, 0.5, 1.7) * 0.30)
	local queuePenalty = math.max(0, (queuePressure - cfg.QueueBaseline) * 0.12)
	local satPenalty = math.max(0, (cfg.TargetSatisfaction - avgSatisfaction) / 100 * 0.22)

	local fairPrice = neutral * qualityFactor * demandFactor
	fairPrice *= math.max(0.4, 1 - queuePenalty - satPenalty)
	fairPrice = math.clamp(fairPrice, cfg.MinPrice, cfg.MaxPrice)
	return fairPrice, signals
end

function ShouldGuestRefuseLiftTicket(data, ticketPrice)
	if not data then
		return false, ticketPrice, 0
	end

	local fairPrice, signals = GetOwnerFairLiftTicketPrice(data.OwnerId)
	local ratio = ticketPrice / math.max(1, fairPrice)
	-- PATCHED: tolerance raised from 1.15 to 1.5 so realistic prices are accepted
	if ratio <= 1.65 then
		return false, fairPrice, 0
	end

	local refuseChance = math.clamp((ratio - 1.65) * 0.22, 0, 0.32)
	if data.Budget < (ticketPrice * 1.1) then
		refuseChance += 0.05
	end

	local sat = tonumber(data.Satisfaction) or 50
	if sat < 35 then
		refuseChance += 0.05
	elseif sat > 75 then
		refuseChance -= 0.12
	end

	local personality = GuestConfig.Personalities[data.Personality]
	if personality then
		local patience = tonumber(personality.Patience) or 1
		refuseChance += (1 - patience) * 0.03
	end

	if signals then
		refuseChance += math.clamp((signals.queuePressure - 1.8) * 0.015, -0.03, 0.03)
	end

	refuseChance = math.clamp(refuseChance, 0, 0.34)
	return math.random() < refuseChance, fairPrice, refuseChance
end

local _LIFT_DIAG_COUNT = 0
local _LIFT_DIAG_LAST_TIME = 0
local _LIFT_DIAG_LAST_LIFT_COUNT = 0

function GetLiftAvoidExpiry(guestData, liftUUID)
	if not guestData or not liftUUID or liftUUID == "" then
		return nil
	end
	local avoidMap = guestData.AvoidLiftUntil
	if type(avoidMap) ~= "table" then
		return nil
	end
	return tonumber(avoidMap[liftUUID])
end

function ScoreLiftForGuestChoice(guestData, lift, nearPos)
	local startStation = lift and lift:FindFirstChild("StartStation")
	if not startStation then
		return math.huge
	end

	local routing = GetLiftRoutingConfig()
	local liftUUID = tostring(lift:GetAttribute("UUID") or "")
	local queuePressure = GetLiftQueuePressure(lift)
	local predictedWait = GetLiftPredictedWaitSeconds(lift, queuePressure)
	local queueInfo = liftUUID ~= "" and LiftQueueStats[liftUUID] or nil
	local walkingCount = queueInfo and queueInfo.walking or 0
	local waitingCount = queueInfo and queueInfo.waiting or 0
	local ridingCount = queueInfo and queueInfo.riding or 0
	local softLimit = GetLiftQueueSoftLimit(lift)
	local overflow = math.max(0, waitingCount - softLimit)
	local commitmentPenalty = math.min(180, (walkingCount * 6.5) + (waitingCount * 3.5) + (ridingCount * 0.5))
	local startAnchor = select(1, GetLiftQueueLinePose(lift)) or GetLiftStartPos(lift)
	local dist = FlatDist(nearPos, startAnchor)
	local verticalDelta = startAnchor.Y - nearPos.Y
	local maxFlat = tonumber(routing.ConnectedLiftMaxFlatDistance) or 360
	local maxRise = tonumber(routing.ConnectedLiftMaxRise) or 70
	local maxDrop = tonumber(routing.ConnectedLiftMaxDrop) or 180
	if dist > maxFlat or verticalDelta > maxRise or verticalDelta < -maxDrop then
		return math.huge
	end
	local downhillReturnPenalty = 0
	if verticalDelta < -20 then
		downhillReturnPenalty = math.abs(verticalDelta + 20) * 1.85
	end
	local steepUphillPenalty = 0
	if verticalDelta > 90 then
		steepUphillPenalty = (verticalDelta - 90) * 0.35
	end
	local nearbyTransferBonus = 0
	if guestData and dist <= 110 and verticalDelta >= -18 and verticalDelta <= 120 then
		nearbyTransferBonus = 65
	end
	local condition = tonumber(lift:GetAttribute("Condition")) or 100
	local status = tostring(lift:GetAttribute("Status") or "Stopped")
	local staffEfficiency = math.max(0, tonumber(lift:GetAttribute("StaffEfficiency")) or 0)
	local staffed = lift:GetAttribute("LiftStaffed") == true or staffEfficiency > 0
	local mechanicCoverageUntil = tonumber(lift:GetAttribute("MechanicCoverageUntil")) or 0
	local mechanicSupported = mechanicCoverageUntil > os.time() or lift:GetAttribute("MechanicSupport") == true
	local serviceBonus = 0
	if staffed then
		serviceBonus += 18 + math.min(16, staffEfficiency * 12)
	end
	if mechanicSupported then
		serviceBonus += 8
	end

	local reliabilityPenalty = 0
	if status == "Slow" then
		reliabilityPenalty += 14
	end
	if condition < 70 then
		reliabilityPenalty += (70 - condition) * 0.4
	end
	if condition < 45 then
		reliabilityPenalty += (45 - condition) * 0.7
	end

	local waitPenalty = math.min(predictedWait, 120) * 5
	local crowdPenalty = math.max(0, queuePressure - 1) * 140
	local overflowPenalty = overflow * 14
	if queuePressure >= routing.OvercrowdedPressure then
		crowdPenalty += 90
	end
	if queuePressure >= routing.HardOvercrowdedPressure then
		crowdPenalty += 220
	end

	local jitter = (math.random() - 0.5) * math.max(18, math.min(50, dist * 0.12))
	local score = dist + downhillReturnPenalty + steepUphillPenalty + waitPenalty + crowdPenalty + overflowPenalty + commitmentPenalty + reliabilityPenalty - serviceBonus - nearbyTransferBonus + jitter
	if guestData and liftUUID ~= "" and guestData.LastLiftUUID == liftUUID then
		local sinceLastLift = tick() - (tonumber(guestData.LastLiftUseAt) or 0)
		local cooldownPenalty = math.clamp(120 - sinceLastLift, 0, 120)
		score += 85 + (cooldownPenalty * 1.25)
	end
	return score
end

function IsLiftUsableForGuestChoice(lift)
	if not lift or not lift.Parent then
		return false
	end
	if not lift:FindFirstChild("StartStation") then
		return false
	end

	local status = tostring(lift:GetAttribute("Status") or "")
	local started = lift:GetAttribute("Started") == true
	if status == "Running" or status == "Slow" or started then
		return true
	end

	return GetLiftOperationalSpeedMultiplier(lift) > 0.05
end

local function ChooseLiftCandidate(candidates, bestScore)
	if not candidates or #candidates == 0 or bestScore == math.huge then
		return nil
	end

	local candidateCount = #candidates
	local scoreBand = math.max(120, math.abs(bestScore) * 0.35)
	if candidateCount >= 6 then
		scoreBand += 120
	elseif candidateCount >= 4 then
		scoreBand += 70
	elseif candidateCount >= 3 then
		scoreBand += 35
	end
	scoreBand = math.clamp(scoreBand, 120, 420)

	local totalWeight = 0
	local shortlist = {}
	for _, entry in ipairs(candidates) do
		local scoreDelta = math.max(0, (entry.Score or bestScore) - bestScore)
		if scoreDelta <= scoreBand then
			local lift = entry.Lift
			local queuePressure = GetLiftQueuePressure(lift)
			local predictedWait = GetLiftPredictedWaitSeconds(lift, nil)
			local queueInfo = tostring(lift:GetAttribute("UUID") or "") ~= "" and LiftQueueStats[tostring(lift:GetAttribute("UUID") or "")] or nil
			local walkingCount = queueInfo and queueInfo.walking or 0
			local waitingCount = queueInfo and queueInfo.waiting or 0
			local congestionPenalty = (queuePressure * 0.55) + (math.min(predictedWait, 120) / 140) + (walkingCount * 0.09) + (waitingCount * 0.04)
			local weight = 1 / math.max(0.2, 1 + (scoreDelta / math.max(scoreBand, 1)) + congestionPenalty)
			if candidateCount >= 4 then
				local explorationBoost = 1 + (math.clamp(scoreDelta / math.max(scoreBand, 1), 0, 1.6) * 0.35)
				weight *= explorationBoost
			end
			totalWeight += weight
			table.insert(shortlist, {
				Lift = lift,
				Weight = weight,
			})
		end
	end

	if #shortlist == 0 then
		local fallback = candidates[1]
		for _, entry in ipairs(candidates) do
			if (entry.Score or math.huge) < (fallback.Score or math.huge) then
				fallback = entry
			end
		end
		return fallback and fallback.Lift or nil
	end
	if #shortlist == 1 then
		return shortlist[1].Lift
	end

	if #shortlist > 2 and math.random() < 0.16 then
		return shortlist[math.random(1, #shortlist)].Lift
	end

	local roll = math.random() * totalWeight
	for _, entry in ipairs(shortlist) do
		roll -= entry.Weight
		if roll <= 0 then
			return entry.Lift
		end
	end
	return shortlist[#shortlist].Lift
end

function FindFallbackLiftForGuest(guestData, nearPos)
	local ownerId = guestData and guestData.OwnerId or nil
	local lifts = FindBuildingsByType("Lift", ownerId)
	if #lifts == 0 then
		lifts = FindBuildingsByType("Lift")
	end
	if #lifts == 0 then
		return nil
	end

	nearPos = nearPos or (guestData and guestData.Root and guestData.Root.Position) or Vector3.zero
	local now = tick()
	if guestData and guestData.CommittedLift and guestData.CommittedLift.Parent and (tonumber(guestData.CommittedLiftUntil) or 0) > now then
		local committedLift = guestData.CommittedLift
		local committedUUID = tostring(guestData.CommittedLiftUUID or committedLift:GetAttribute("UUID") or "")
		local avoidExpiry = GetLiftAvoidExpiry(guestData, committedUUID)
		if IsLiftSelectableForGuest(guestData, committedLift) and (not avoidExpiry or avoidExpiry <= now) then
			return committedLift
		end
	end

	local bestLiftCandidates = {}
	local bestScore = math.huge
	local bestTransitCandidates = {}
	local bestTransitScore = math.huge
	for _, lift in ipairs(lifts) do
		local ss = lift:FindFirstChild("StartStation")
		if ss and IsLiftUsableForGuestChoice(lift) then
			local liftUUID = tostring(lift:GetAttribute("UUID") or "")
			local avoidExpiry = GetLiftAvoidExpiry(guestData, liftUUID)
			if not avoidExpiry or avoidExpiry <= now then
				local _, difficulties = GetLiftServedSlopes(lift)
				local anyDiffFound = false
				for _ in pairs(difficulties) do
					anyDiffFound = true
					break
				end

				local score = ScoreLiftForGuestChoice(guestData, lift, nearPos)
				if anyDiffFound then
					if score < bestScore then
						bestScore = score
					end
					table.insert(bestLiftCandidates, { Lift = lift, Score = score })
				else
					local rise = (GetLiftEndPos(lift, true).Y - GetLiftStartPos(lift).Y)
					if rise > 18 then
						if score < bestTransitScore then
							bestTransitScore = score
						end
						table.insert(bestTransitCandidates, { Lift = lift, Score = score })
					end
				end
			end
		end
	end

	local selectedLift = ChooseLiftCandidate(bestLiftCandidates, bestScore) or ChooseLiftCandidate(bestTransitCandidates, bestTransitScore)
	if selectedLift then
		CommitGuestToLift(guestData, selectedLift, 10)
	end
	return selectedLift
end

function FindLiftForGuest(guestData, nearPos)
	local ownerId = guestData and guestData.OwnerId or nil
	local lifts = FindBuildingsByType("Lift", ownerId)
	if #lifts == 0 then
		lifts = FindBuildingsByType("Lift")
	end
	if #lifts == 0 then
		return nil
	end

	nearPos = nearPos or ((guestData and guestData.Root and guestData.Root.Position) or Vector3.zero)
	local now = tick()
	if guestData and guestData.CommittedLift and guestData.CommittedLift.Parent and (tonumber(guestData.CommittedLiftUntil) or 0) > now then
		local committedLift = guestData.CommittedLift
		local committedUUID = tostring(guestData.CommittedLiftUUID or committedLift:GetAttribute("UUID") or "")
		local avoidExpiry = GetLiftAvoidExpiry(guestData, committedUUID)
		if IsLiftSelectableForGuest(guestData, committedLift) and (not avoidExpiry or avoidExpiry <= now) then
			return committedLift
		end
	end

	local allowed = GuestConfig.SlopeDifficulty.Allowed[guestData.Personality] or {1, 2}
	local preferred = GuestConfig.SlopeDifficulty.Preferred[guestData.Personality] or {1}
	local allowedSet = {}
	for _, a in ipairs(allowed) do
		allowedSet[a] = true
	end
	local preferredSet = {}
	for _, p in ipairs(preferred) do
		preferredSet[p] = true
	end

	local preferredCandidates = {}
	local allowedCandidates = {}
	local anyCandidates = {}
	local bestPreferredScore = math.huge
	local bestAllowedScore = math.huge
	local bestAnyScore = math.huge

	for _, lift in ipairs(lifts) do
		local startStation = lift:FindFirstChild("StartStation")
		if startStation and IsLiftUsableForGuestChoice(lift) then
			local liftUUID = tostring(lift:GetAttribute("UUID") or "")
			local avoidExpiry = GetLiftAvoidExpiry(guestData, liftUUID)
			if not avoidExpiry or avoidExpiry <= now then
				local _, difficulties = GetLiftServedSlopes(lift)
				local hasPreferred = false
				local hasAllowed = false
				local anyDiffFound = false
				for diffNum in pairs(difficulties) do
					anyDiffFound = true
					if preferredSet[diffNum] then
						hasPreferred = true
					end
					if allowedSet[diffNum] then
						hasAllowed = true
					end
				end

				local score = ScoreLiftForGuestChoice(guestData, lift, nearPos)
				if anyDiffFound then
					if hasPreferred then
						if score < bestPreferredScore then
							bestPreferredScore = score
						end
						table.insert(preferredCandidates, { Lift = lift, Score = score })
					end
					if hasAllowed then
						if score < bestAllowedScore then
							bestAllowedScore = score
						end
						table.insert(allowedCandidates, { Lift = lift, Score = score })
					end
					if score < bestAnyScore then
						bestAnyScore = score
					end
					table.insert(anyCandidates, { Lift = lift, Score = score })
				end
			end
		end
	end

	local selected = ChooseLiftCandidate(preferredCandidates, bestPreferredScore) or ChooseLiftCandidate(allowedCandidates, bestAllowedScore) or ChooseLiftCandidate(anyCandidates, bestAnyScore)
	if selected then
		CommitGuestToLift(guestData, selected, 12)
	end
	return selected
end

local function ShouldAttemptPostUnloadTransfer(data, currentLift, slope)
	if not data or not currentLift then
		return false
	end
	if (tonumber(data.PostUnloadTransferCount) or 0) >= POST_UNLOAD_TRANSFER_MAX_ATTEMPTS then
		return false
	end
	if data.Energy and data.Energy < 28 then
		return false
	end
	if data.WantsBreak == true then
		return false
	end
	local baseChance = 0.24
	if not slope then
		baseChance += 0.32
	end
	local personality = GuestConfig.Personalities[data.Personality]
	if personality and tonumber(personality.SkiSpeed) then
		baseChance += math.clamp((tonumber(personality.SkiSpeed) - 1) * 0.22, -0.06, 0.14)
	end
	return math.random() < math.clamp(baseChance, 0.08, 0.65)
end

local function FindPostUnloadTransferLift(data, currentLift)
	if not data or not currentLift or not currentLift.Parent then
		return nil
	end
	local ownerId = data.OwnerId
	local lifts = FindBuildingsByType("Lift", ownerId)
	if #lifts == 0 then
		lifts = FindBuildingsByType("Lift")
	end
	if #lifts == 0 then
		return nil
	end

	local fromPos = GetLiftEndPos(currentLift, true)
	local currentUUID = tostring(currentLift:GetAttribute("UUID") or "")
	local now = tick()
	local bestLift = nil
	local bestScore = math.huge

	for _, lift in ipairs(lifts) do
		if lift ~= currentLift and lift.Parent and IsLiftSelectableForGuest(data, lift) then
			local liftUUID = tostring(lift:GetAttribute("UUID") or "")
			if liftUUID ~= "" and liftUUID ~= currentUUID then
				local avoidExpiry = GetLiftAvoidExpiry(data, liftUUID)
				if not avoidExpiry or avoidExpiry <= now then
					local startPos = GetLiftStartPos(lift)
					local endPos = GetLiftEndPos(lift, true)
					local startDist = FlatDist(fromPos, startPos)
					local rise = endPos.Y - startPos.Y
					if startDist <= POST_UNLOAD_TRANSFER_MAX_START_DISTANCE and rise >= POST_UNLOAD_TRANSFER_MIN_RISE then
						local queuePressure = GetLiftQueuePressure(lift)
						local predictedWait = GetLiftPredictedWaitSeconds(lift, queuePressure)
						local score = startDist + (math.max(0, 24 - rise) * 2.4) + (predictedWait * 0.55) + (math.max(0, queuePressure - 1) * 70)
						if score < bestScore then
							bestScore = score
							bestLift = lift
						end
					end
				end
			end
		end
	end

	return bestLift
end

-- Pre-parse lift data when LiftCache changes
task.spawn(function()
	local liftCache = ReplicatedStorage:WaitForChild("LiftCache", 15)
	if not liftCache then return end
	for _, child in ipairs(liftCache:GetChildren()) do
		if child:IsA("StringValue") then ParseLiftCache(child.Name) end
	end
	liftCache.ChildAdded:Connect(function(child)
		if child:IsA("StringValue") then
			task.wait(0.2)
			ParseLiftCache(child.Name)
		end
	end)
	liftCache.ChildRemoved:Connect(function(child)
		ParsedLiftData[child.Name] = nil
	end)
end)

-- ============================================================================
-- MOVEMENT SYSTEM
-- ============================================================================
function IsPathSensitiveMovementState(state)
	return state == STATE.WALKING
		or state == STATE.WALKING_TO_LIFT
		or state == STATE.SKIING_TO_SLOPE
		or state == STATE.GOING_TO_HOTEL
		or state == STATE.LEAVING
end

function HasDirectMovementObstacle(data, fromPos: Vector3, toPos: Vector3): boolean
	if not data or not data.Model then
		return false
	end

	local flatDelta = Vector3.new(toPos.X - fromPos.X, 0, toPos.Z - fromPos.Z)
	if flatDelta.Magnitude < 14 then
		return false
	end

	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { data.Model }
	params.IgnoreWater = true

	local probeHeights = { 2.5, 5.0, 7.5 }
	for _, probeHeight in ipairs(probeHeights) do
		local origin = Vector3.new(fromPos.X, fromPos.Y + probeHeight, fromPos.Z)
		local target = Vector3.new(toPos.X, origin.Y, toPos.Z)
		local result = Workspace:Raycast(origin, target - origin, params)
		if result and result.Instance and result.Instance.CanCollide ~= false then
			return true
		end
	end

	return false
end

function FindMovementDetourTarget(data, fromPos: Vector3, toPos: Vector3): Vector3?
	if not data then
		return nil
	end

	local flatDelta = Vector3.new(toPos.X - fromPos.X, 0, toPos.Z - fromPos.Z)
	if flatDelta.Magnitude < 8 then
		return nil
	end

	local forward = flatDelta.Unit
	local perpendicular = Vector3.new(-forward.Z, 0, forward.X)
	local forwardStep = math.clamp(flatDelta.Magnitude * 0.25, 10, 28)
	local sideOffsets = { 10, -10, 16, -16, 24, -24, 34, -34, 46, -46, 58, -58 }
	for _, sideOffset in ipairs(sideOffsets) do
		local candidate = fromPos + (forward * forwardStep) + (perpendicular * sideOffset)
		local resolvedCandidate = ResolveMovementTargetPos(data, candidate)
		if not HasDirectMovementObstacle(data, fromPos, resolvedCandidate)
			and not HasDirectMovementObstacle(data, resolvedCandidate, toPos) then
			return resolvedCandidate
		end
	end

	return nil
end

function GetMovementPathProfiles(data)
	local state = data and data.State or nil
	if state == STATE.WALKING_TO_LIFT or state == STATE.SKIING_TO_SLOPE or state == STATE.GOING_TO_HOTEL then
		return {
			{ AgentRadius = 2.2, AgentHeight = 6, AgentCanJump = true, WaypointSpacing = 2.5 },
			{ AgentRadius = 3.0, AgentHeight = 6, AgentCanJump = true, WaypointSpacing = 3 },
			{ AgentRadius = 4.0, AgentHeight = 6, AgentCanJump = true, WaypointSpacing = 4 },
		}
	end
	return {
		{ AgentRadius = 2.4, AgentHeight = 6, AgentCanJump = true, WaypointSpacing = 3 },
		{ AgentRadius = 3.2, AgentHeight = 6, AgentCanJump = true, WaypointSpacing = 3.5 },
		{ AgentRadius = 4.5, AgentHeight = 6, AgentCanJump = true, WaypointSpacing = 4.5 },
	}
end

function GetMovementPathGoalCandidates(data, fromPos: Vector3, targetPos: Vector3)
	local candidates = {}
	local seen = {}
	local function push(pos: Vector3)
		local key = string.format("%.1f|%.1f|%.1f", pos.X, pos.Y, pos.Z)
		if seen[key] then
			return
		end
		seen[key] = true
		table.insert(candidates, pos)
	end

	push(targetPos)
	local flatDelta = Vector3.new(targetPos.X - fromPos.X, 0, targetPos.Z - fromPos.Z)
	if flatDelta.Magnitude >= 8 then
		local forward = flatDelta.Unit
		local right = Vector3.new(-forward.Z, 0, forward.X)
		for _, sideOffset in ipairs({ 8, -8, 14, -14 }) do
			push(ResolveMovementTargetPos(data, targetPos + (right * sideOffset)))
		end
		local backstep = math.clamp(flatDelta.Magnitude * 0.18, 6, 18)
		push(ResolveMovementTargetPos(data, targetPos - (forward * backstep)))
	end

	return candidates
end

function ComputeMovementPath(data, fromPos: Vector3, targetPos: Vector3)
	local bestWaypoints = nil
	local bestGoal = nil
	local bestScore = math.huge

	for _, goal in ipairs(GetMovementPathGoalCandidates(data, fromPos, targetPos)) do
		for _, profile in ipairs(GetMovementPathProfiles(data)) do
			local path = PathfindingService:CreatePath(profile)
			local ok = pcall(function()
				path:ComputeAsync(fromPos, goal)
			end)
			if ok and path.Status == Enum.PathStatus.Success then
				local waypoints = path:GetWaypoints()
				if waypoints and #waypoints >= 2 then
					local finalWaypoint = waypoints[#waypoints].Position
					local score = FlatDist(finalWaypoint, targetPos)
					score += math.max(0, #waypoints - 2) * 0.18
					score += FlatDist(goal, targetPos) * 0.12
					if score < bestScore then
						bestScore = score
						bestWaypoints = waypoints
						bestGoal = goal
					end
				end
			end
		end
	end

	return bestWaypoints, bestGoal
end

function MoveGuestTo(data: GuestData, targetPos: Vector3, callback: ((GuestData) -> ())?)
	local model = data.Model
	local hum = data.Humanoid
	if not model or not model.Parent or not hum or hum.Health <= 0 then return end

	if data.Root and data.Root.Anchored then
		data.Root.Anchored = false
	end
	GuestMovement.MoveTo(data, targetPos, callback)
end

function UpdateMovement(data, dt)
	local root = data.Root
	if not root or not data.MoveTarget then return end

	local pos = root.Position
	local now = tick()

	if data.State == STATE.WALKING_TO_LIFT and data.TargetLift then
		if not data.TargetLift.Parent or not IsLiftSelectableForGuest(data, data.TargetLift) then
			GuestMovement.StopMovement(data)
			data.TargetLift = nil
			data.State = STATE.DECIDING
			return
		end

		local liftStartPos = GetLiftStartPos(data.TargetLift)
		local queueAnchorPos = select(1, GetLiftQueueLinePose(data.TargetLift)) or liftStartPos
		local distToLiftApproach = FlatDist(pos, liftStartPos)
		local distToQueueAnchor = FlatDist(pos, queueAnchorPos)

		if (distToLiftApproach <= 14 or distToQueueAnchor <= 16) then
			if TryEnterLiftQueueFromProximity(data, 16) then return end
			GuestMovement.StopMovement(data)
			EnterLiftQueue(data)
			return
		end
	end

	GuestMovement.Update(data, dt)

	if data.PathFailures and data.PathFailures > 3 then
		local reason = (tick() - (data.MoveStartTime or tick()) > GuestMovement.GetMoveTimeout(data.State)) and "Timeout" or "Stuck"
		if HandleGoalNavigationFailure(data, reason) then
			return
		end
	end
end

function MarkLiftAvoidance(data, lift, seconds)
	if not data or not lift or not lift.Parent then
		return
	end
	local liftUUID = tostring(lift:GetAttribute("UUID") or "")
	if liftUUID == "" then
		return
	end
	data.AvoidLiftUntil = data.AvoidLiftUntil or {}
	data.AvoidLiftUntil[liftUUID] = tick() + math.max(4, tonumber(seconds) or 20)
	if data.CommittedLiftUUID == liftUUID then
		ClearLiftCommitment(data)
	end
end

function ClearLiftCommitment(data)
	if not data then
		return
	end
	data.CommittedLift = nil
	data.CommittedLiftUUID = nil
	data.CommittedLiftUntil = nil
end

function CommitGuestToLift(data, lift, seconds)
	if not data or not lift or not lift.Parent then
		return
	end
	local liftUUID = tostring(lift:GetAttribute("UUID") or "")
	if liftUUID == "" then
		return
	end
	data.CommittedLift = lift
	data.CommittedLiftUUID = liftUUID
	data.CommittedLiftUntil = tick() + math.max(3, tonumber(seconds) or 12)
end

function IsLiftSelectableForGuest(data, lift)
	if not data or not lift or not lift.Parent then
		return false
	end
	return IsLiftBoardingAvailable(lift)
end

function GetSlopeRuntimeKey(slope)
	if not slope then
		return ""
	end
	local uuid = tostring(slope:GetAttribute("UUID") or "")
	if uuid ~= "" then
		return uuid
	end
	return slope:GetFullName()
end

function MarkSlopeAvoidance(data, slope, seconds)
	if not data or not slope then return end
	local slopeKey = GetSlopeRuntimeKey(slope)
	if slopeKey == "" then return end
	data.AvoidSlopeUntil = data.AvoidSlopeUntil or {}
	data.AvoidSlopeUntil[slopeKey] = tick() + math.max(1, seconds or 25)
end

function IsSlopeAvoided(data, slope, now)
	if not data or not slope or not data.AvoidSlopeUntil then
		return false
	end
	local slopeKey = GetSlopeRuntimeKey(slope)
	if slopeKey == "" then
		return false
	end
	local expiry = data.AvoidSlopeUntil[slopeKey]
	return expiry ~= nil and expiry > (now or tick())
end

-- PERF FIX: Use CollectionService-tagged employees instead of Workspace:GetDescendants().
-- Falls back to scanning PlacedObjects children (much smaller set than all workspace).
function FindInstructorModelByUUID(uuid)
	if not uuid or uuid == "" then
		return nil
	end
	local uuidStr = tostring(uuid)
	-- Try CollectionService first (fast path)
	local tagged = CollectionService:GetTagged("Employee")
	if #tagged > 0 then
		for _, emp in ipairs(tagged) do
			if emp:IsA("Model") and emp:GetAttribute("EmployeeType") == "Instructor" then
				if tostring(emp:GetAttribute("UUID") or "") == uuidStr then
					return emp
				end
			end
		end
		return nil
	end
	-- Fallback: scan the dedicated Employees folder before any legacy placement containers.
	local employeesFolder = workspace:FindFirstChild("Employees")
	if employeesFolder then
		for _, obj in ipairs(employeesFolder:GetChildren()) do
			if obj:IsA("Model") and obj:GetAttribute("IsEmployee") == true and obj:GetAttribute("EmployeeType") == "Instructor" then
				if tostring(obj:GetAttribute("UUID") or "") == uuidStr then
					return obj
				end
			end
		end
	end
	-- Legacy fallback: scan PlacedObjects only (not entire workspace)
	local placed = GetPlacedObjects()
	if placed then
		for _, obj in ipairs(placed:GetDescendants()) do
			if obj:IsA("Model") and obj:GetAttribute("IsEmployee") == true and obj:GetAttribute("EmployeeType") == "Instructor" then
				if tostring(obj:GetAttribute("UUID") or "") == uuidStr then
					return obj
				end
			end
		end
	end
	return nil
end

function GetAssignedInstructorForGuest(data)
	if not data or not data.Model then
		return nil, nil
	end
	local instructorUUID = tostring(data.Model:GetAttribute("AssignedInstructorUUID") or "")
	if instructorUUID == "" then
		return nil, nil
	end
	local instructor = FindInstructorModelByUUID(instructorUUID)
	if not instructor or not instructor.Parent then
		return nil, nil
	end
	local guestUUID = tostring(data.GuestUUID or data.Model:GetAttribute("GuestUUID") or "")
	if guestUUID == "" or tostring(instructor:GetAttribute("AssignedGuestUUID") or "") ~= guestUUID then
		return nil, nil
	end
	local lessonPos = Vector3.new(
		tonumber(data.Model:GetAttribute("LessonTargetX")) or (instructor.PrimaryPart and instructor.PrimaryPart.Position.X or data.Root.Position.X),
		tonumber(data.Model:GetAttribute("LessonTargetY")) or (instructor.PrimaryPart and instructor.PrimaryPart.Position.Y or data.Root.Position.Y),
		tonumber(data.Model:GetAttribute("LessonTargetZ")) or (instructor.PrimaryPart and instructor.PrimaryPart.Position.Z or data.Root.Position.Z)
	)
	return instructor, lessonPos
end

function ClearGuestLessonAssignment(data, preserveInstructorAssignment)
	if not data or not data.Model then
		return
	end
	local model = data.Model
	local guestUUID = tostring(data.GuestUUID or model:GetAttribute("GuestUUID") or "")
	local instructorUUID = tostring(model:GetAttribute("AssignedInstructorUUID") or "")
	local instructor = data.TargetInstructor
	if (not instructor or not instructor.Parent) and instructorUUID ~= "" then
		instructor = FindInstructorModelByUUID(instructorUUID)
	end
	if not preserveInstructorAssignment and instructor and instructor.Parent then
		if tostring(instructor:GetAttribute("AssignedGuestUUID") or "") == guestUUID then
			instructor:SetAttribute("AssignedGuestUUID", nil)
		end
	end
	data.TargetInstructor = nil
	data.LessonTargetPos = nil
	data.LessonEndTime = nil
	model:SetAttribute("AssignedInstructorUUID", nil)
	model:SetAttribute("LessonTargetX", nil)
	model:SetAttribute("LessonTargetY", nil)
	model:SetAttribute("LessonTargetZ", nil)
	model:SetAttribute("TakingLesson", false)
	model:SetAttribute("LessonProgress", nil)
end

function ClearGuestMoveCommandState(data)
	data.MoveTarget = nil
	data.Waypoints = nil
	data.WaypointIndex = nil
	data.MoveResumeTarget = nil
	data.MoveResumeCallback = nil
	data.MoveCallback = nil
	data.LastMoveCommandTime = nil
	data.LastMoveCommandTarget = nil
	data.MoveProgressBaselineDist = nil
	data.LastProgressTime = nil
	data.NextStuckDetourAt = nil
	data.NextStuckCheckAt = nil
	data.StuckTimer = 0
	data.LastMovePos = nil
end

function TryEnterLiftQueueFromProximity(data, radiusOverride)
	if not data or not data.Root or not data.TargetLift or not data.TargetLift.Parent then
		return false
	end

	local lift = data.TargetLift
	if not IsLiftSelectableForGuest(data, lift) then
		return false
	end

	local liftStartPos = GetLiftStartPos(lift)
	local queueAnchorPos = select(1, GetLiftQueueLinePose(lift)) or liftStartPos
	local pos = data.Root.Position
	local bestDist = math.min(FlatDist(pos, liftStartPos), FlatDist(pos, queueAnchorPos))
	local handoffRadius = math.max(12, tonumber(radiusOverride) or 14)
	if bestDist > handoffRadius then
		return false
	end

	ClearGuestMoveCommandState(data)
	data.LiftApproachFailureCount = 0
	data.WaitStartTime = data.WaitStartTime or tick()
	EnterLiftQueue(data)
	return true
end

function HandleGoalNavigationFailure(data, reason)
	if not data or not data.Root then
		return false
	end

	data.PathFailureCount = (data.PathFailureCount or 0) + 1
	data.LastNavigationFailureReason = reason
	data.LastNavigationFailureAt = tick()
	ClearGuestMoveCommandState(data)

	if data.State == STATE.SKIING_TO_SLOPE then
		local failedSlope = data.TargetSlope
		data.SlopeWalkFailureCount = (data.SlopeWalkFailureCount or 0) + 1
		if failedSlope then
			MarkSlopeAvoidance(data, failedSlope, 40)
		end

		if failedSlope and data.SlopeWalkFailureCount >= 2 then -- Give guests one real retry before falling back to direct ski start.
			local failedPath = GetSlopeData(failedSlope)
			if failedPath and #failedPath > 1 then
				local entryIndex = tonumber(data.TargetSlopeEntryIndex) or GetNearestSlopeEntryIndex(failedPath, data.Root.Position, 140)
				local entryPos = GetSlopeEntryPosition(failedPath, entryIndex) or GetGroundPos(failedPath[entryIndex] or failedPath[1])
				NormalizeGuestUpright(data, entryPos)
				if TryStartSkiingDown(data, failedSlope, { EntryIndex = entryIndex }, "PostCrashRetry") then
					return true
				end
			end
		end

		local nextSlope = FindSlopeForGuest(data, data.Root.Position)
		if nextSlope and nextSlope.Parent then
			local nextPath = GetSlopeData(nextSlope)
			if nextPath and #nextPath > 1 then
				local entryIndex = GetNearestSlopeEntryIndex(nextPath, data.Root.Position, 140)
				local entryPos = GetSlopeEntryPosition(nextPath, entryIndex) or GetGroundPos(nextPath[entryIndex] or nextPath[1])
				data.State = STATE.SKIING_TO_SLOPE
				data.TargetSlope = nextSlope
				data.TargetSlopeEntryIndex = entryIndex
				MoveGuestTo(data, entryPos, function(guestData)
					if not TryStartSkiingDown(guestData, nextSlope, { EntryIndex = entryIndex }, "PostCrashContinue") then
						guestData.State = STATE.DECIDING
						guestData.TargetSlope = nil
						guestData.TargetSlopeEntryIndex = nil
					end
				end)
				return true
			end
		end

		data.TargetSlope = nil
		data.TargetSlopeEntryIndex = nil
		data.TargetLift = nil
		data.State = STATE.DECIDING
		data.WantsBreak = true
		data.IdleTimer = -0.35
		return true
	end

	if data.State == STATE.GOING_TO_HOTEL then
		local hotelModel = data.HotelModel
		if hotelModel and hotelModel.Parent then
			local hotelPos = ResolveHotelSpawnPos(hotelModel)
			NormalizeGuestUpright(data, hotelPos)
			data.MoveTarget = nil
			data.Waypoints = nil
			data.MoveCallback = nil
			data.MoveProgressBaselineDist = nil
			data.LastProgressTime = nil
			data.StuckTimer = 0
			SetGuestSleepingAfterMove(data)
			return true
		end
		data.State = STATE.DECIDING
		data.WantsBreak = false
		data.IdleTimer = -0.25
		return true
	end

	if data.State == STATE.WALKING_TO_LIFT then
		if TryEnterLiftQueueFromProximity(data, 18) then
			return true
		end
		if data.TargetLift then
			MarkLiftAvoidance(data, data.TargetLift, 60)
		end
		ClearLiftCommitment(data)
		data.TargetLift = nil
		data.LiftApproachFailureCount = 0
		data.State = STATE.DECIDING
		data.IdleTimer = -0.35
		return true
	end

	if data.State == STATE.GOING_TO_HOTEL then
		local hotelModel = data.HotelModel
		if hotelModel and hotelModel.Parent then
			local hotelPos = ResolveHotelSpawnPos(hotelModel)
			NormalizeGuestUpright(data, hotelPos)
			data.MoveTarget = nil
			data.Waypoints = nil
			data.MoveCallback = nil
			data.MoveProgressBaselineDist = nil
			data.LastProgressTime = nil
			data.StuckTimer = 0
			SetGuestSleepingAfterMove(data)
			return true
		end
		data.State = STATE.DECIDING
		data.WantsBreak = false
		data.IdleTimer = -0.25
		return true
	end

	if data.State == STATE.GOING_TO_HOTEL then
		local hotelModel = data.HotelModel
		if hotelModel and hotelModel.Parent then
			local hotelPos = ResolveHotelSpawnPos(hotelModel)
			NormalizeGuestUpright(data, hotelPos)
			data.MoveTarget = nil
			data.Waypoints = nil
			data.MoveCallback = nil
			data.MoveProgressBaselineDist = nil
			data.LastProgressTime = nil
			data.StuckTimer = 0
			SetGuestSleepingAfterMove(data)
			return true
		end
		data.State = STATE.DECIDING
		data.WantsBreak = false
		data.IdleTimer = -0.25
		return true
	end

	if data.State == STATE.WALKING then
		if data.TargetBuilding then
			data._AvoidBuildings = data._AvoidBuildings or {}
			data._AvoidBuildings[data.TargetBuilding] = tick() + 30
		end
		data.TargetBuilding = nil
		data.TargetInstructor = nil
		data.State = STATE.DECIDING
		data.IdleTimer = -0.2
		return true
	end

	return false
end

function NotifyCrowdedLift(ownerId, liftName, pressure, liftModel)
	local player = ownerId and Players:GetPlayerByUserId(ownerId) or nil
	if not player then return end
	local now = tick()
	local state = LiftCrowdNotifyState[ownerId] or { last = 0 }
	if (now - (state.last or 0)) < 20 then return end
	state.last = now
	LiftCrowdNotifyState[ownerId] = state
	local targetPos = nil
	if liftModel and liftModel.Parent then
		targetPos = GetLiftStartPos(liftModel)
	end
	NotifyPlayer(
		player,
		"Warning",
		"Lift Congestion",
		string.format("%s is overloaded (%.1fx). Guests are rerouting.", tostring(liftName or "A lift"), tonumber(pressure) or 0),
		4,
		BuildTeleportNotificationAction("Go To Lift", targetPos)
	)
end

function TryRerouteCrowdedLift(data, crowdPressure, sourceTag)
	if not data or not data.TargetLift or not data.TargetLift.Parent then return false end
	local now = tick()
	if data.NextLiftRerouteAt and now < data.NextLiftRerouteAt then
		return false
	end
	local oldLift = data.TargetLift
	local routing = GetLiftRoutingConfig()
	local queueBehavior = GetQueueBehaviorConfig()
	local oldPressure = tonumber(crowdPressure) or GetLiftQueuePressure(oldLift)
	local waitTime = now - (data.WaitStartTime or now)
	local oldPredictedWait = GetLiftPredictedWaitSeconds(oldLift, oldPressure)
	data.PredictedQueueWait = oldPredictedWait

	local oldQueueInfo = LiftQueueStats[oldLift:GetAttribute("UUID") or ""]
	local oldWaitingCount = oldQueueInfo and oldQueueInfo.waiting or 0
	local oldSoftLimit = GetLiftQueueSoftLimit(oldLift)
	local emergencyOverload =
		oldPressure >= queueBehavior.EmergencyPressure or
		oldWaitingCount >= math.floor(oldSoftLimit * 1.25)
	local smallQueue = oldWaitingCount < 10

	if not emergencyOverload then
		if smallQueue and waitTime < math.max(queueBehavior.MinCommitWaitSeconds + 35, 70) then
			return false
		end
		if oldPressure < routing.OvercrowdedPressure then
			return false
		end
		if waitTime < queueBehavior.MinCommitWaitSeconds then
			return false
		end
		if waitTime < queueBehavior.RerouteCheckStartSeconds then
			return false
		end
		if oldPredictedWait < queueBehavior.RerouteIfPredictedWaitAbove then
			return false
		end
	end

	local oldUUID = oldLift:GetAttribute("UUID") or ""
	local nearPos = (data.Root and data.Root.Position) or oldLift:GetPivot().Position
	local nextLift = FindLiftForGuest(data, nearPos)
	if not nextLift or nextLift == oldLift then
		return false
	end

	local nextPressure = GetLiftQueuePressure(nextLift)
	local nextPredictedWait = GetLiftPredictedWaitSeconds(nextLift, nextPressure)
	local waitImprovement = oldPredictedWait - nextPredictedWait
	local forceSwap = emergencyOverload
	if not forceSwap and waitImprovement < queueBehavior.MinImprovementToRerouteSeconds then
		return false
	end

	MarkLiftAvoidance(data, oldLift, routing.AvoidLiftSeconds)
	ClearLiftQueueState(data)
	data.NextLiftRerouteAt = now + queueBehavior.RerouteCooldownSeconds
	data.TargetLift = nextLift
	data.State = STATE.WALKING_TO_LIFT
	data.WaitStartTime = nil
	data.LastQueueEvalAt = 0
	data.PredictedQueueWait = nextPredictedWait
	data.MoveTarget = nil
	data.MoveCallback = nil
	data.Waypoints = nil

	local startPos = GetLiftStartPos(nextLift)
	MoveGuestTo(data, startPos, function()
		EnterLiftQueue(data)
	end)

	if not data._lastQueueStuckPenalty or (now - data._lastQueueStuckPenalty) > 30 then
		ApplySatisfaction(data, "StuckInQueue")
		data._lastQueueStuckPenalty = now
	end
	ShowSpeech(data.Model, PickRandom({"This line is crazy...", "Trying another lift!", "Too crowded here."}), 2.5)
	NotifyCrowdedLift(data.OwnerId, oldLift.Name, oldPressure, oldLift)
	if data.OwnerId then
		local stat = LiftRerouteStats[data.OwnerId]
		if not stat or (now - (stat.windowStart or 0)) > 60 then
			stat = {windowStart = now, count = 0}
			LiftRerouteStats[data.OwnerId] = stat
		end
		stat.count = (stat.count or 0) + 1
	end


	if oldUUID ~= "" then
		data.LastLiftUUID = oldUUID
	end
	return true
end

-- ============================================================================
-- SKIING SYSTEM — Realistic, dynamic, full-body carving
-- ============================================================================

-- Speed ranges per difficulty
local SLOPE_SPEED_PARAMS = {
	[1] = { BaseMin = 18, BaseMax = 30,  GravMult = 0.8,  MaxSpeed = 38  },  -- Green
	[2] = { BaseMin = 22, BaseMax = 38,  GravMult = 1.0,  MaxSpeed = 50  },  -- Blue
	[3] = { BaseMin = 35, BaseMax = 60,  GravMult = 1.7,  MaxSpeed = 85  },  -- Black
	[4] = { BaseMin = 48, BaseMax = 78,  GravMult = 2.2,  MaxSpeed = 115 },  -- Double Black
	[5] = { BaseMin = 58, BaseMax = 95,  GravMult = 2.8,  MaxSpeed = 140 },  -- Triple Black
}

-- Carve style per difficulty: { amplitude range, frequency range (turns/sec), tuck chance }
local CARVE_STYLES = {
	[1] = { AmpMin = 10, AmpMax = 18, FreqMin = 0.08, FreqMax = 0.16, TuckChance = 0.0,  StraightChance = 0.35 },  -- Green: wider, gentler S-turns
	[2] = { AmpMin = 14, AmpMax = 26, FreqMin = 0.12, FreqMax = 0.24, TuckChance = 0.1,  StraightChance = 0.15 },  -- Blue: wider medium carves
	[3] = { AmpMin = 18, AmpMax = 33, FreqMin = 0.16, FreqMax = 0.30, TuckChance = 0.25, StraightChance = 0.10 },  -- Black: aggressive but less twitchy
	[4] = { AmpMin = 22, AmpMax = 40, FreqMin = 0.18, FreqMax = 0.34, TuckChance = 0.40, StraightChance = 0.05 },  -- Double Black: big arcs
	[5] = { AmpMin = 26, AmpMax = 46, FreqMin = 0.20, FreqMax = 0.38, TuckChance = 0.55, StraightChance = 0.02 },  -- Triple Black: full send
}

function ClearSkiRuntimeData(data)
	data.SkiPath = nil
	data.SkiIndex = nil
	data.SkiProgress = nil
	data.SkiSpeed = nil
	data.SkiSlopeModel = nil
	data.SkiDifficulty = nil
	data.SkiDiffNum = nil
	data.SkiStartTime = nil
	data.SkiSlopeParams = nil
	data.SkiSpeedMult = nil
	data.SkiSkillLevel = nil
	data.SkiSmoothedDir = nil
	data.SkiCarvePhase = nil
	data.SkiCarveAmp = nil
	data.SkiCarveFreq = nil
	data.SkiLaneOffset = nil
	data.SkiIsTucking = nil
	data.SkiTuckTimer = nil
	data.SkiNextCarveChange = nil
	data.SkiBodyLean = nil
	data.SkiLastPos = nil
	data.SkiCarveStyle = nil
	data.SkiGroundY = nil
	data.SkiNextGroundSampleAt = nil
	data.SkiVisitedSlopes = nil
	data.TargetSlope = nil
	data.SyntheticPostUnloadRun = nil
	if data.Model and data.Model.Parent then
		data.Model:SetAttribute("SyntheticSkiRun", nil)
	end
end

function GetSafeFlatDirection(vec, fallback)
	local v = vec or fallback or Vector3.new(0, 0, 1)
	v = Vector3.new(v.X, 0, v.Z)
	if v.Magnitude < 0.01 then
		v = Vector3.new(0, 0, 1)
	end
	return v.Unit
end

function NormalizeGuestUpright(data, targetPos, extraGroundInstances)
	if not data or not data.Root or not data.Humanoid then return end
	local root = data.Root
	local hum = data.Humanoid
	local pos = targetPos or root.Position
	local groundPos = ResolveWalkableGroundPos(pos, extraGroundInstances or GetMovementExtraGroundInstances(data), false)
	local forward = GetSafeFlatDirection(data.SkiSmoothedDir, root.CFrame.LookVector)
	root.CFrame = CFrame.lookAt(groundPos, groundPos + forward)
	root.AssemblyLinearVelocity = Vector3.zero
	root.AssemblyAngularVelocity = Vector3.zero
	root.Anchored = false
	hum.PlatformStand = false
	hum.AutoRotate = true
	data.NextGroundSnapAt = 0
	data.LastMovePos = groundPos
end

function EnsureGuestWalkingPhysics(data, targetPos, extraGroundInstances)
	if not data or not data.Root or not data.Humanoid then return end
	local root = data.Root
	local hum = data.Humanoid
	if targetPos ~= nil then
		local pos = ResolveWalkableGroundPos(targetPos, extraGroundInstances or GetMovementExtraGroundInstances(data), false)
		local forward = GetSafeFlatDirection(data.SkiSmoothedDir, root.CFrame.LookVector)
		root.CFrame = CFrame.lookAt(pos, pos + forward)
		data.LastMovePos = pos
	end
	root.Anchored = false
	root.CanCollide = true
	root.AssemblyLinearVelocity = Vector3.zero
	root.AssemblyAngularVelocity = Vector3.zero
	hum.PlatformStand = false
	hum.AutoRotate = true
	if hum.WalkSpeed < 20 or hum.WalkSpeed > 32 then
		hum.WalkSpeed = 26
	end
	data.NextGroundSnapAt = 0
	if root and root.Parent then
		ApplyWalkerNetworkOwnership(root)
	end
end

local function EnsureMinimumSkiPathLength(path, startIndex, minLength)
	if type(path) ~= "table" or #path < 2 then
		return path, startIndex
	end
	local minLen = math.max(40, tonumber(minLength) or 120)
	local idx = math.clamp(tonumber(startIndex) or 1, 1, #path - 1)
	local remaining = GetRemainingPathLength(path, idx)
	if remaining >= minLen then
		return path, idx
	end

	local extended = {}
	for i = idx, #path do
		table.insert(extended, path[i])
	end
	if #extended < 2 then
		return path, idx
	end

	local lastPoint = extended[#extended]
	local prevPoint = extended[#extended - 1]
	local flatDir = GetSafeFlatDirection(lastPoint - prevPoint, Vector3.new(0, 0, -1))
	local remainingToAdd = minLen - remaining
	local guard = 0
	while remainingToAdd > 0 and guard < 16 do
		guard += 1
		local step = math.min(28, remainingToAdd)
		local nextXZ = lastPoint + (flatDir * step)
		local terrainY = GetTerrainY(nextXZ.X, nextXZ.Z)
		local nextY = math.min(lastPoint.Y - 1.1, terrainY + 3.5)
		local nextPoint = Vector3.new(nextXZ.X, nextY, nextXZ.Z)
		if (nextPoint - lastPoint).Magnitude < 0.5 then
			nextPoint = Vector3.new(nextXZ.X, lastPoint.Y - 1.1, nextXZ.Z)
		end
		table.insert(extended, nextPoint)
		remainingToAdd -= (nextPoint - lastPoint).Magnitude
		lastPoint = nextPoint
	end

	return extended, 1
end

local SYNTHETIC_POST_UNLOAD_MIN_RUN = 150
local ENABLE_SYNTHETIC_POST_UNLOAD_FALLBACK = false

local function BuildSyntheticSkiPath(startPos, preferredDir, minLength)
	local origin = ResolveWalkableGroundPos(startPos, nil, false)
	local flatPreferred = GetSafeFlatDirection(preferredDir, Vector3.new(0, 0, -1))
	local minLen = math.max(90, tonumber(minLength) or SYNTHETIC_POST_UNLOAD_MIN_RUN)
	local stepLength = 16
	local stepCount = math.max(8, math.ceil(minLen / stepLength))
	local angleCandidates = { 0, 10, -10, 20, -20, 35, -35, 55, -55, 75, -75, 100, -100, 140, -140, 180 }
	local bestPath = nil
	local bestScore = nil

	for _, degrees in ipairs(angleCandidates) do
		local yaw = math.rad(degrees)
		local cosA = math.cos(yaw)
		local sinA = math.sin(yaw)
		local dir = Vector3.new(
			(flatPreferred.X * cosA) - (flatPreferred.Z * sinA),
			0,
			(flatPreferred.X * sinA) + (flatPreferred.Z * cosA)
		)
		if dir.Magnitude < 0.01 then
			continue
		end
		dir = dir.Unit

		local candidate = { origin }
		local prev = origin
		local totalDrop = 0
		local totalLength = 0
		local flattenStreak = 0

		for _ = 1, stepCount do
			local nextXZ = prev + (dir * stepLength)
			local groundY = GetTerrainY(nextXZ.X, nextXZ.Z) + 3.5
			local targetY = math.min(prev.Y - 0.65, groundY)
			if targetY >= prev.Y - 0.2 then
				flattenStreak += 1
				targetY = prev.Y - 0.65
			else
				flattenStreak = 0
			end

			local nextPoint = Vector3.new(nextXZ.X, targetY, nextXZ.Z)
			totalLength += (nextPoint - prev).Magnitude
			totalDrop += math.max(0, prev.Y - nextPoint.Y)
			table.insert(candidate, nextPoint)
			prev = nextPoint

			if flattenStreak >= 4 and totalLength >= (minLen * 0.65) then
				break
			end
		end

		if #candidate >= 2 and totalLength >= (minLen * 0.75) then
			local alignment = flatPreferred:Dot(dir)
			local score = (totalDrop * 2.2) + (totalLength * 0.35) + (alignment * 8)
			if (not bestScore) or score > bestScore then
				bestScore = score
				bestPath = candidate
			end
		end
	end

	if not bestPath then
		bestPath = { origin }
		local prev = origin
		local remaining = minLen
		while remaining > 0 do
			local step = math.min(stepLength, remaining)
			local nextXZ = prev + (flatPreferred * step)
			local groundY = GetTerrainY(nextXZ.X, nextXZ.Z) + 3.5
			local forcedY = math.min(prev.Y - 0.9, groundY)
			local nextPoint = Vector3.new(nextXZ.X, forcedY, nextXZ.Z)
			table.insert(bestPath, nextPoint)
			remaining -= (nextPoint - prev).Magnitude
			prev = nextPoint
		end
	end

	return bestPath
end

local function StartSyntheticPostUnloadSki(data, reasonTag)
	if not ENABLE_SYNTHETIC_POST_UNLOAD_FALLBACK then
		return false
	end
	if not data or not data.Root or not data.Humanoid or not data.Model or not data.Model.Parent then
		return false
	end

	local now = tick()
	local startPos = data.Root.Position
	local preferredDir = data.SkiSmoothedDir or data.Root.CFrame.LookVector or Vector3.new(0, 0, -1)
	local path = BuildSyntheticSkiPath(startPos, preferredDir, SYNTHETIC_POST_UNLOAD_MIN_RUN)
	if type(path) ~= "table" or #path < 2 then
		return false
	end
	path = select(1, EnsureMinimumSkiPathLength(path, 1, SYNTHETIC_POST_UNLOAD_MIN_RUN))

	local diffNum = 2
	local slopeParams = SLOPE_SPEED_PARAMS[diffNum] or SLOPE_SPEED_PARAMS[1]
	local carveStyle = CARVE_STYLES[diffNum] or CARVE_STYLES[1]
	local personality = GuestConfig.Personalities[data.Personality]
	local speedMult = personality and personality.SkiSpeed or 1.0
	local skillLevel = personality and personality.SkillLevel or 2
	local laneOffset = (math.random() - 0.5) * 8
	local carveAmp = carveStyle.AmpMin + math.random() * (carveStyle.AmpMax - carveStyle.AmpMin)
	local carveFreq = carveStyle.FreqMin + math.random() * (carveStyle.FreqMax - carveStyle.FreqMin)
	carveAmp = carveAmp * math.clamp(0.9 + (skillLevel * 0.2), 1.0, 1.9)
	if skillLevel <= 1 then
		carveAmp = 0
	end

	local startForward = GetSafeFlatDirection(path[2] - path[1], preferredDir)
	local startGround = ResolveWalkableGroundPos(path[1], nil, false)
	data.Root.CFrame = CFrame.lookAt(startGround, startGround + startForward)
	data.Root.AssemblyLinearVelocity = Vector3.zero
	data.Root.AssemblyAngularVelocity = Vector3.zero
	data.Root.Anchored = true

	data.LastSkiStartRejectReason = nil
	data.Model:SetAttribute("SkiStartRejectReason", nil)
	data.State = STATE.SKIING_DOWN
	data.SlopeWalkFailureCount = 0
	data.TargetSlopeEntryIndex = nil
	data.PathFailureCount = 0
	data.SkiPath = path
	data.SkiIndex = 1
	data.SkiProgress = 0
	data.SkiSpeed = slopeParams.BaseMin * speedMult * 0.5
	data.SkiSlopeModel = nil
	data.SkiDifficulty = "Synthetic"
	data.SkiDiffNum = diffNum
	data.SkiStartTime = now
	data.SkiSlopeParams = slopeParams
	data.SkiSpeedMult = speedMult
	data.SkiSkillLevel = skillLevel
	data.SkiCarvePhase = math.random() * math.pi * 2
	data.SkiCarveFreq = carveFreq
	data.SkiCarveAmp = carveAmp
	data.SkiLaneOffset = laneOffset
	data.SkiCarveStyle = carveStyle
	data.SkiIsTucking = math.random() < carveStyle.TuckChance
	data.SkiTuckTimer = 0
	data.SkiNextCarveChange = 4 + math.random() * 7
	data.SkiBodyLean = 0
	data.SkiSmoothedDir = nil
	data.SkiLastPos = nil
	data.SyntheticPostUnloadRun = true
	data.RecentlyUnloadedAt = nil
	data.TargetLift = nil
	data.TargetSlope = nil
	data.WantsBreak = false
	data.PostUnloadSkiRequired = true
	data.PostUnloadSkiStartedAt = data.PostUnloadSkiStartedAt or now
	data.PostUnloadSkiAttempts = (tonumber(data.PostUnloadSkiAttempts) or 0) + 1
	data.PostUnloadSkiStartIndex = 1
	data.PostUnloadSkiLastAttemptAt = now
	data.PostUnloadSkiStartPos = startGround

	data.Humanoid.PlatformStand = true
	data.Humanoid.AutoRotate = false
	data.Model:SetAttribute("IsSkiing", true)
	data.Model:SetAttribute("State", STATE.SKIING_DOWN)
	data.Model:SetAttribute("SkiDifficulty", diffNum)
	data.Model:SetAttribute("SyntheticSkiRun", true)
	data.Model:SetAttribute("SkiStartContext", tostring(reasonTag or "SyntheticPostUnload"))
	ShowSpeech(data.Model, PickRandom({"Dropping in!", "Taking a fallback line!", "Skiing now!"}), 1.6)
	return true
end

function StartSkiingDown(data, slopeModel, options)
	options = options or {}
	local isContinuation = options.IsContinuation == true
	local requestedEntryIndex = math.floor(tonumber(options.EntryIndex) or 1)

	if IsSummerSeason() then
		data.LastSkiStartRejectReason = "summer"
		if data.Model and data.Model.Parent then
			data.Model:SetAttribute("SkiStartRejectReason", "summer")
		end
		data.State = STATE.DECIDING
		data.TargetSlope = nil
		return false
	end

	local path, difficulty = GetSlopeData(slopeModel)
	if not path or #path < 2 then
		data.LastSkiStartRejectReason = "invalid_path"
		if data.Model and data.Model.Parent then
			data.Model:SetAttribute("SkiStartRejectReason", "invalid_path")
		end
		data.State = STATE.IDLE
		return false
	end
	local maxEntryIndex = math.max(1, #path - 2)
	local entryIndex = math.clamp(requestedEntryIndex, 1, maxEntryIndex)
	if GetRemainingPathLength(path, entryIndex) < 45 and entryIndex > 1 then
		entryIndex = math.max(1, entryIndex - 1)
	end
	-- Keep guests on authored slope paths. Synthetic extension is only for explicit fallback mode.
	if options.AllowPathExtension == true then
		path, entryIndex = EnsureMinimumSkiPathLength(path, entryIndex, 140)
	end

	-- Difficulty number
	local diffNum = GetDifficultyNumber(difficulty, slopeModel.Name)
	local slopeParams = SLOPE_SPEED_PARAMS[diffNum] or SLOPE_SPEED_PARAMS[1]
	local carveStyle = CARVE_STYLES[diffNum] or CARVE_STYLES[1]

	-- Personality speed modifier
	local personality = GuestConfig.Personalities[data.Personality]
	local speedMult = personality and personality.SkiSpeed or 1.0
	local difficultySpeedBoost = 1.0
	if diffNum == 3 then
		difficultySpeedBoost = 1.25
	elseif diffNum >= 4 then
		difficultySpeedBoost = 1.45
	end
	speedMult = speedMult * difficultySpeedBoost
	local skillLevel = personality and personality.SkillLevel or 2
	local lessonBoost = 0
	if data.LastLessonAt and (tick() - data.LastLessonAt) <= 900 then
		lessonBoost = math.clamp(tonumber(data.LessonSkillBoost) or 0, 0, 1.25)
	end
	if data.SkiSlopeModel and data.SkiSlopeModel:GetAttribute("HasInstructor") == true and diffNum <= 2 and skillLevel <= 2 then
		local liveInstructorLevel = tonumber(data.SkiSlopeModel:GetAttribute("InstructorLevel")) or 0
		local liveLessonQuality = tonumber(data.SkiSlopeModel:GetAttribute("LessonQuality")) or 0
		lessonBoost = math.max(lessonBoost, math.min(1.1, 0.1 + (liveInstructorLevel * 0.12) + (liveLessonQuality * 0.05)))
	end
	skillLevel = skillLevel + lessonBoost

	-- Randomize carve parameters within the style range (each guest is unique)
	local carveAmp = carveStyle.AmpMin + math.random() * (carveStyle.AmpMax - carveStyle.AmpMin)
	local carveFreq = carveStyle.FreqMin + math.random() * (carveStyle.FreqMax - carveStyle.FreqMin)
	carveFreq = carveFreq * 0.82

	-- Better skiers carve wider with more control
	carveAmp = carveAmp * math.clamp(1.05 + (skillLevel * 0.24), 1.1, 2.2)
	if skillLevel <= 1 then
		carveAmp = 0
	end

	-- Random lateral offset from path center so guests don't all follow same line
	local laneOffset = (math.random() - 0.5) * 22  -- ±11 studs from center for wider track usage
	if isContinuation and data.SkiLaneOffset then
		laneOffset = (data.SkiLaneOffset * 0.78) + ((math.random() - 0.5) * 6)
	end

	data.LastSkiStartRejectReason = nil
	if data.Model and data.Model.Parent then
		data.Model:SetAttribute("SkiStartRejectReason", nil)
	end
	data.State = STATE.SKIING_DOWN
	data.SlopeWalkFailureCount = 0
	data.TargetSlopeEntryIndex = nil
	data.PathFailureCount = 0
	data.SkiPath = path
	data.SkiIndex = entryIndex
	data.SkiProgress = 0
	local startSpeed = slopeParams.BaseMin * speedMult * 0.5 -- start slow, build up
	if isContinuation and data.SkiSpeed then
		startSpeed = math.min(
			slopeParams.MaxSpeed,
			math.max(startSpeed * 0.8, (data.SkiSpeed or startSpeed) * 0.92)
		)
	end
	data.SkiSpeed = startSpeed
	data.SkiSlopeModel = slopeModel
	data.TargetSlope = slopeModel
	data.SkiDifficulty = difficulty
	data.RecentlyUnloadedAt = nil
	local slopeUUID = tostring(slopeModel:GetAttribute("UUID") or "")
	if slopeUUID ~= "" then
		data.LastSlopeUUID = slopeUUID
		data.LastSlopeUseAt = tick()
	end
	data.SkiDiffNum = diffNum
	data.SkiStartTime = tick()
	data.SkiSlopeParams = slopeParams
	data.SkiSpeedMult = speedMult
	data.SkiSkillLevel = skillLevel

	-- Carving state
	data.SkiCarvePhase = math.random() * math.pi * 2  -- random start so guests are out of sync
	data.SkiCarveFreq = carveFreq
	data.SkiCarveAmp = carveAmp
	data.SkiLaneOffset = laneOffset
	data.SkiCarveStyle = carveStyle

	-- Tuck state (straight downhill, no carving — for steeps/speed sections)
	data.SkiIsTucking = math.random() < carveStyle.TuckChance
	data.SkiTuckTimer = 0
	data.SkiNextCarveChange = 4 + math.random() * 7 -- switch carve/tuck every 4-11 seconds

	-- Body lean tracking
	data.SkiBodyLean = 0  -- current lean angle in radians (+ = right, - = left)

	-- Smoothed direction for gradual turning
	data.SkiSmoothedDir = nil
	data.SkiLastPos = nil
	data.SkiVisitedSlopes = data.SkiVisitedSlopes or {}
	local slopeUUID = tostring(slopeModel:GetAttribute("UUID") or "")
	if slopeUUID ~= "" then
		data.SkiVisitedSlopes[slopeUUID] = (data.SkiVisitedSlopes[slopeUUID] or 0) + 1
	end

	-- Disable normal humanoid movement
	data.Humanoid.PlatformStand = true
	data.Humanoid.AutoRotate = false
	data.Root.Anchored = true
	-- NetworkOwner already nil (set at spawn), server has full authority

	-- Set attribute for client visuals
	data.Model:SetAttribute("IsSkiing", true)
	data.Model:SetAttribute("State", STATE.SKIING_DOWN)
	data.Model:SetAttribute("SkiDifficulty", diffNum)

	if not isContinuation then
		ShowSpeech(data.Model, PickRandom({"Here we go!", "Woohoo!", "Let's ski!", "⛷️"}), 2)
	elseif math.random() < 0.22 then
		ShowSpeech(data.Model, PickRandom({"Trail merge!", "Keep going!", "Linking into another run."}), 1.8)
	end
	return true
end

function TryStartSkiingDown(data, slopeModel, options, contextTag)
	if data and data.Model and data.Model.Parent then
		local attempts = (tonumber(data.Model:GetAttribute("SkiStartAttemptCount")) or 0) + 1
		data.Model:SetAttribute("SkiStartAttemptCount", attempts)
		data.Model:SetAttribute("LastSkiStartAttemptContext", tostring(contextTag or "unknown"))
		data.Model:SetAttribute("LastSkiStartAttemptAt", tick())
	end

	local ok, startedOrErr = pcall(StartSkiingDown, data, slopeModel, options)
	if not ok then
		warn(string.format("[GuestServer] StartSkiingDown error (%s): %s", tostring(contextTag or "unknown"), tostring(startedOrErr)))
		if data and data.Model and data.Model.Parent then
			data.Model:SetAttribute("SkiStartError", tostring(startedOrErr))
			data.Model:SetAttribute("LastSkiStartSuccess", false)
		end
		return false
	end

	if data and data.Model and data.Model.Parent then
		if data.Model:GetAttribute("SkiStartError") ~= nil then
			data.Model:SetAttribute("SkiStartError", nil)
		end
		data.Model:SetAttribute("LastSkiStartSuccess", startedOrErr == true)
		if startedOrErr == true then
			data.Model:SetAttribute("LastSkiStartSuccessAt", tick())
		end
	end

	return startedOrErr == true
end

function TryContinueMergedTrail(data)
	local nextSlope, entryIndex, diffMismatch = FindMergedTrailContinuation(data)
	if not nextSlope or not entryIndex then
		local fallbackSlope = FindSlopeForGuest(data, data.Root and data.Root.Position or nil)
		if fallbackSlope and fallbackSlope.Parent then
			local fallbackPath = GetSlopeData(fallbackSlope)
			if fallbackPath and #fallbackPath >= 2 then
				local pathStart = fallbackPath[1]
				local guestPos = data.Root and data.Root.Position or pathStart
				-- Only merge if close (30 studs) and slope goes downhill from guest
				if FlatDist(guestPos, pathStart) <= 30 and pathStart.Y <= guestPos.Y + 5 then
					nextSlope = fallbackSlope
					entryIndex = 1
				end
			end
		end
		if not nextSlope or not entryIndex then
			return false
		end
	end

	local ok = TryStartSkiingDown(data, nextSlope, {
		EntryIndex = entryIndex,
		IsContinuation = true,
	})
	-- Show a reaction when merging onto a harder trail
	if ok and diffMismatch then
		local skill = data.SkiSkillLevel or 2
		if skill <= 1 then
			ShowSpeech(data.Model, PickRandom({"This is too hard! 😰", "Oh no...", "I'm scared!", "Uh oh... 😳"}), 2)
		elseif skill <= 2 then
			ShowSpeech(data.Model, PickRandom({"This is steep!", "Getting challenging!", "Whoa... 😬"}), 1.5)
		else
			ShowSpeech(data.Model, PickRandom({"Trail merge!", "Different run!", "Let's go! 🤙"}), 1.2)
		end
	end
	return ok == true
end

function UpdateSkiing(data, dt)
	if IsSummerSeason() then
		data.Root.Anchored = false
		data.Humanoid.PlatformStand = false
		data.Humanoid.AutoRotate = true
		data.Model:SetAttribute("IsSkiing", false)
		data.Model:SetAttribute("SkiSpeed", 0)
		ClearSkiRuntimeData(data)
		data.State = STATE.DECIDING
		data.WantsBreak = true
		return
	end

	if not data.SkiPath or data.SkiIndex >= #data.SkiPath then
		if not TryContinueMergedTrail(data) then
			FinishSkiRun(data)
		end
		return
	end

	local root = data.Root
	if not root or not root.Parent then return end
	if not root.Anchored then
		root.Anchored = true
	end
	if not data.Humanoid.PlatformStand then
		data.Humanoid.PlatformStand = true
	end
	data.Humanoid.AutoRotate = false

	local path = data.SkiPath
	local idx = data.SkiIndex
	local p0 = path[idx]
	local p1 = path[idx + 1]
	if not p0 or not p1 then
		if not TryContinueMergedTrail(data) then
			FinishSkiRun(data)
		end
		return
	end

	-- Segment info
	local segVec = p1 - p0
	local segLen = segVec.Magnitude
	if segLen < 0.1 then
		data.SkiIndex += 1
		return
	end
	local segDir = segVec / segLen

	-- ─────────────────────────────────────────────
	-- SPEED PHYSICS
	-- ─────────────────────────────────────────────
	local heightDiff = p0.Y - p1.Y
	local slopeAngle = math.atan2(math.max(heightDiff, 0), math.max(segLen, 1))

	local params = data.SkiSlopeParams
	local gravAccel = math.sin(slopeAngle) * 100 * params.GravMult * dt
	local friction = data.SkiSpeed * 0.02 * dt
	local targetSpeed = (params.BaseMin + params.BaseMax) / 2 * data.SkiSpeedMult
	local nudge = (targetSpeed - data.SkiSpeed) * 0.8 * dt

	if heightDiff > 0 then
		-- Downhill: real acceleration
		data.SkiSpeed = data.SkiSpeed + gravAccel + nudge - friction
		-- Tucking = less drag, more speed
		if data.SkiIsTucking then
			data.SkiSpeed = data.SkiSpeed + 5 * dt
		end
	else
		-- Flat/uphill
		data.SkiSpeed = data.SkiSpeed - 4 * dt + nudge * 0.5
	end
	data.SkiSpeed = math.clamp(data.SkiSpeed, params.BaseMin * 0.25, params.MaxSpeed)

	-- ─────────────────────────────────────────────
	-- ADVANCE ALONG PATH
	-- ─────────────────────────────────────────────
	local moveAmount = data.SkiSpeed * dt
	data.SkiProgress = data.SkiProgress + (moveAmount / segLen)

	while data.SkiProgress >= 1.0 and data.SkiIndex < #data.SkiPath do
		data.SkiProgress = data.SkiProgress - 1.0
		data.SkiIndex += 1

		idx = data.SkiIndex
		if idx >= #data.SkiPath then
			if not TryContinueMergedTrail(data) then
				FinishSkiRun(data)
			end
			return
		end

		p0 = path[idx]
		p1 = path[idx + 1]
		if not p0 or not p1 then
			if not TryContinueMergedTrail(data) then
				FinishSkiRun(data)
			end
			return
		end

		segVec = p1 - p0
		segLen = segVec.Magnitude
		if segLen < 0.1 then
			data.SkiProgress = 1.0
			continue
		end
		segDir = segVec / segLen
	end

	data.SkiProgress = math.clamp(data.SkiProgress, 0, 0.999)

	-- ─────────────────────────────────────────────
	-- CARVE / TUCK SWITCHING (dynamic behavior changes)
	-- ─────────────────────────────────────────────
	data.SkiTuckTimer = (data.SkiTuckTimer or 0) + dt
	if data.SkiTuckTimer >= data.SkiNextCarveChange then
		data.SkiTuckTimer = 0
		data.SkiNextCarveChange = 4 + math.random() * 7

		local style = data.SkiCarveStyle
		if data.SkiIsTucking then
			-- Switch from tuck → carving
			data.SkiIsTucking = false
			-- Re-randomize carve params slightly for variety
			data.SkiCarveFreq = (style.FreqMin + math.random() * (style.FreqMax - style.FreqMin)) * 0.82
			data.SkiCarveAmp = style.AmpMin + math.random() * (style.AmpMax - style.AmpMin)
			data.SkiCarveAmp = data.SkiCarveAmp * math.clamp(1.05 + (data.SkiSkillLevel * 0.24), 1.1, 2.2)
			if data.SkiSkillLevel <= 1 then data.SkiCarveAmp = 0 end
		else
			-- Maybe tuck, maybe go straight, or keep carving with new params
			local roll = math.random()
			if roll < style.TuckChance then
				data.SkiIsTucking = true
			elseif roll < style.TuckChance + style.StraightChance then
				-- Straight section: very low amplitude
				data.SkiIsTucking = false
				data.SkiCarveAmp = 1 + math.random() * 2
				data.SkiCarveFreq = 0.1
				if data.SkiSkillLevel <= 1 then data.SkiCarveAmp = 0 end
			else
				-- New carve pattern
				data.SkiCarveFreq = (style.FreqMin + math.random() * (style.FreqMax - style.FreqMin)) * 0.82
				data.SkiCarveAmp = style.AmpMin + math.random() * (style.AmpMax - style.AmpMin)
				data.SkiCarveAmp = data.SkiCarveAmp * math.clamp(1.05 + (data.SkiSkillLevel * 0.24), 1.1, 2.2)
				if data.SkiSkillLevel <= 1 then data.SkiCarveAmp = 0 end
			end
		end
	end

	-- ─────────────────────────────────────────────
	-- POSITION CALCULATION
	-- ─────────────────────────────────────────────
	local t = data.SkiProgress
	local basePos = p0:Lerp(p1, t)

	-- Lookahead direction (blend with next segment)
	local nextDir = segDir
	if idx + 2 <= #path then
		local nextSeg = path[idx + 2] - p1
		if nextSeg.Magnitude > 0.1 then
			nextDir = segDir:Lerp(nextSeg.Unit, math.clamp(t, 0, 1) * 0.5)
		end
	end

	-- Flat direction for perpendicular calculation
	local flatDir = Vector3.new(nextDir.X, 0, nextDir.Z)
	if flatDir.Magnitude < 0.01 then flatDir = Vector3.new(0, 0, 1) end
	flatDir = flatDir.Unit
	local rightVec = Vector3.new(-flatDir.Z, 0, flatDir.X)

	-- Carving offset
	local carveOffset = 0
	if not data.SkiIsTucking then
		data.SkiCarvePhase = data.SkiCarvePhase + data.SkiCarveFreq * math.pi * 2 * dt
		carveOffset = math.sin(data.SkiCarvePhase) * data.SkiCarveAmp
	end

	-- Total lateral offset: lane offset + carve
	local totalOffset = data.SkiLaneOffset + carveOffset
	local offsetPos = basePos + rightVec * totalOffset

	-- ─────────────────────────────────────────────
	-- TERRAIN SNAP + VERTICAL PHYSICS (JUMPING)
	-- ─────────────────────────────────────────────
	local now = tick()
	local shouldSampleGround = (not data.SkiNextGroundSampleAt) or (now >= data.SkiNextGroundSampleAt)
	if shouldSampleGround then
		data.SkiGroundY = GetTerrainY(offsetPos.X, offsetPos.Z)
		data.SkiNextGroundSampleAt = now + 0.1
	end
	local sampledGroundY = tonumber(data.SkiGroundY) or offsetPos.Y

	-- Process Y Velocity (Jumping / Airtime)
	data.SkiYOffset = data.SkiYOffset or 0
	data.SkiYVelocity = data.SkiYVelocity or 0

	if data.SkiYOffset > 0 or data.SkiYVelocity > 0 then
		-- Apply Gravity (Roblox standard is roughly 196.2, we use a floatier value for ski jumps)
		data.SkiYVelocity = data.SkiYVelocity - (workspace.Gravity * 0.45 * dt)
		data.SkiYOffset = data.SkiYOffset + (data.SkiYVelocity * dt)

		-- Hit the ground
		if data.SkiYOffset <= 0 then
			data.SkiYOffset = 0
			data.SkiYVelocity = 0
		end
	end

	-- Calculate final Y: Base Terrain + Any offset from carving/bumps + The Jump Height
	local terrainY = sampledGroundY + ((offsetPos.Y - sampledGroundY) * 0.35)
	local finalY = terrainY + 3.5 + data.SkiYOffset

	-- HumanoidRootPart center is ~3 studs above feet for R6/R15
	local finalPos = Vector3.new(offsetPos.X, finalY, offsetPos.Z)

	-- Safety: prevent fly-away
	if data.SkiLastPos then
		local maxMove = data.SkiSpeed * dt * 3 + 5
		local actualMove = (finalPos - data.SkiLastPos).Magnitude
		if actualMove > maxMove then
			finalPos = Vector3.new(basePos.X, finalY, basePos.Z)
		end
	end
	data.SkiLastPos = finalPos

	-- ─────────────────────────────────────────────
	-- BODY ORIENTATION (full body lean into turns + terrain slope following)
	-- ─────────────────────────────────────────────
	-- segDir between adjacent raw points is NEARLY FLAT because slopes have 500+ points.
	-- Use a WIDER window (8+ indices apart) to get the REAL slope angle.
	local lookBehind = math.max(1, idx - 4)
	local lookAhead = math.min(#path, idx + 4)
	local wideSlopeDir = path[lookAhead] - path[lookBehind]
	if wideSlopeDir.Magnitude < 0.5 then
		-- Fallback: try even wider
		lookBehind = math.max(1, idx - 8)
		lookAhead = math.min(#path, idx + 8)
		wideSlopeDir = path[lookAhead] - path[lookBehind]
	end
	local targetLook3D
	if wideSlopeDir.Magnitude > 0.5 then
		targetLook3D = wideSlopeDir.Unit
	else
		targetLook3D = segDir
	end

	-- Carve direction: the character looks INTO the turn
	local turnRate_val = 0
	if not data.SkiIsTucking and data.SkiCarveAmp > 2 then
		turnRate_val = math.cos(data.SkiCarvePhase) * data.SkiCarveFreq * data.SkiCarveAmp
		local turnAngle = math.atan2(turnRate_val * 0.04, 1)
		-- Rotate around Y axis for the turn yaw
		local cosA = math.cos(turnAngle)
		local sinA = math.sin(turnAngle)
		local lx = targetLook3D.X * cosA - targetLook3D.Z * sinA
		local lz = targetLook3D.X * sinA + targetLook3D.Z * cosA
		targetLook3D = Vector3.new(lx, targetLook3D.Y, lz)
		if targetLook3D.Magnitude > 0.01 then targetLook3D = targetLook3D.Unit end
	end

	-- Smooth direction (3D — preserves terrain slope information)
	if data.SkiSmoothedDir == nil then
		data.SkiSmoothedDir = targetLook3D
	end
	local smoothRate = 2 + data.SkiSkillLevel * 0.9
	data.SkiSmoothedDir = (data.SkiSmoothedDir + (targetLook3D - data.SkiSmoothedDir) * math.clamp(smoothRate * dt, 0, 1))
	if data.SkiSmoothedDir.Magnitude > 0.01 then
		data.SkiSmoothedDir = data.SkiSmoothedDir.Unit
	end

	-- Body lean: lean into the carve direction (roll angle)
	local targetLean = 0
	if not data.SkiIsTucking and data.SkiCarveAmp > 2 then
		targetLean = -turnRate_val * 0.015
		targetLean = math.clamp(targetLean, -math.rad(25), math.rad(25))
	end
	data.SkiBodyLean = data.SkiBodyLean + (targetLean - data.SkiBodyLean) * math.clamp(5 * dt, 0, 1)

	-- Additional pitch lean: slight forward crouch based on speed
	local speedFraction = data.SkiSpeed / (data.SkiSlopeParams.MaxSpeed + 1)
	local speedPitch = -math.rad(3 + speedFraction * 10)
	if data.SkiIsTucking then speedPitch = -math.rad(18) end  -- deep tuck

	-- Build final CFrame: lookAt uses 3D direction (naturally slopes downhill)
	-- Then apply additional speed-based crouch + body lean
	local lookCF = CFrame.lookAt(finalPos, finalPos + data.SkiSmoothedDir)
	local leanCF = CFrame.Angles(speedPitch, 0, data.SkiBodyLean)

	-- Apply Trick Physics (visual spins/flips)
	if data.Model:GetAttribute("DoingTrick") then
		data._trickTime = (data._trickTime or 0) + dt
		local duration = 1.5 -- Match the task.delay duration
		local progress = math.clamp(data._trickTime / duration, 0, 1)

		-- Use an EaseInOutSine curve so the spin starts/ends smoothly
		local easeProgress = -(math.cos(math.pi * progress) - 1) / 2

		local trickName = data._currentTrickName or ""
		local trickAngleX, trickAngleY, trickAngleZ = 0, 0, 0

		if trickName:find("Backflip") then
			-- 1 full backward rotation
			trickAngleX = easeProgress * math.rad(360)
		elseif trickName:find("360") then
			-- 1 full spin around Y axis
			trickAngleY = easeProgress * math.rad(360)
		elseif trickName:find("Cork 720") then
			-- Off-axis double spin
			trickAngleX = easeProgress * math.rad(360)
			trickAngleY = easeProgress * math.rad(720)
		elseif trickName:find("Misty") then
			-- Forward off-axis flip
			trickAngleX = -easeProgress * math.rad(360)
			trickAngleZ = easeProgress * math.rad(360)
		else
			-- Grabs / Shiftys (Tweaks)
			-- Tweaks shouldn't spin all the way around; they turn, hold, and return
			local tweakProgress = math.sin(progress * math.pi) -- 0 -> 1 -> 0
			trickAngleY = tweakProgress * math.rad(70)
			trickAngleZ = tweakProgress * math.rad(30)

			-- Alternate directions based on UUID hash so they don't all tweak the same way
			if data.SpawnTime % 2 > 1 then
				trickAngleY = -trickAngleY
				trickAngleZ = -trickAngleZ
			end
		end

		local trickSpin = CFrame.Angles(trickAngleX, trickAngleY, trickAngleZ)
		root.CFrame = lookCF * trickSpin * leanCF

	else
		data._trickTime = 0
		root.CFrame = lookCF * leanCF
	end

	-- ─────────────────────────────────────────────
	-- CRASH CHECK
	-- ─────────────────────────────────────────────
	local crashConfig = GuestConfig.Crash
	local effectiveSpeed = data.SkiSpeed
	if slopeAngle > 0.5 then effectiveSpeed = effectiveSpeed * crashConfig.SteepSlopeMultiplier end

	if effectiveSpeed > crashConfig.MinCrashSpeed then
		local crashChance = crashConfig.CrashChancePerSecond * dt

		if data.SkiSkillLevel <= 1 then
			crashChance *= crashConfig.BeginnerCrashMultiplier
		elseif data.SkiSkillLevel >= 4 then
			crashChance *= crashConfig.ExpertCrashMultiplier
		end

		if data.SkiDiffNum > data.SkiSkillLevel then
			crashChance *= 1.5 * (data.SkiDiffNum - data.SkiSkillLevel)
		end

		local rentalSupport = 0
		if data.RentalSupportUntil and tick() <= data.RentalSupportUntil then
			rentalSupport = math.clamp(tonumber(data.RentalSafetyBoost) or 0, 0, 0.35)
		end
		if rentalSupport > 0 then
			crashChance *= math.max(0.62, 1 - rentalSupport)
		end

		local slopeModel = data.SkiSlopeModel
		if slopeModel and slopeModel.Parent then
			local slopeCondition = tonumber(slopeModel:GetAttribute("SlopeCondition")) or 70
			local groomLevel = tonumber(slopeModel:GetAttribute("GroomLevel")) or 0
			local patrolLevel = tonumber(slopeModel:GetAttribute("SkiPatrolLevel")) or 0
			local instructorLevel = tonumber(slopeModel:GetAttribute("InstructorLevel")) or 0
			local patrolCoverage = slopeModel:GetAttribute("SkiPatrolCoverage") == true
			local hasInstructor = slopeModel:GetAttribute("HasInstructor") == true

			if slopeCondition >= 90 then
				crashChance *= 0.78
			elseif slopeCondition >= 80 then
				crashChance *= 0.86
			elseif slopeCondition <= 50 then
				crashChance *= 1.18
			end

			if groomLevel > 0 then
				crashChance *= math.max(0.72, 1 - (groomLevel * 0.035))
			end
			if patrolCoverage then
				crashChance *= math.max(0.7, 1 - (patrolLevel * 0.04))
			end
			if hasInstructor and data.SkiSkillLevel <= 2 and data.SkiDiffNum <= 2 then
				crashChance *= math.max(0.65, 1 - (instructorLevel * 0.05))
			end
		end

		if math.random() < crashChance then
			CrashGuest(data)
			return
		end
	end

	-- Update speed attribute for client
	data.Model:SetAttribute("SkiSpeed", math.round(data.SkiSpeed * 10) / 10)
	-- Velocity vector for client-side interpolation (smooth rendering between server ticks)
	data.Model:SetAttribute("SkiVelX", data.SkiSmoothedDir.X * data.SkiSpeed)
	data.Model:SetAttribute("SkiVelZ", data.SkiSmoothedDir.Z * data.SkiSpeed)

	-- TRICKS: Only on Black Diamond or harder slopes (no random flying on greens/blues)
	local trickCooldown = data.SkiTrickCooldown or 0
	local slopeDifficulty = data.SkiSlopeModel and data.SkiSlopeModel:GetAttribute("Difficulty") or "Green"
	local diffNum = (slopeDifficulty == "Black" and 3)
		or (slopeDifficulty == "Double Black" and 4)
		or (slopeDifficulty == "DoubleBlack" and 4)
		or 0

	-- Guests will only do tricks on steep slopes, when fast, off cooldown, and not already jumping
	if data.SkiSpeed > 25 and trickCooldown <= 0 and (data.SkiYOffset or 0) <= 0.1 and diffNum >= 3 then
		-- Only Intermediate and up can do tricks
		if data.SkiSkillLevel >= 2 then
			-- Randomly trigger while skiing on steep terrain
			local jumpChance = 0.03 * dt * 60 -- 3% chance per second (reduced from 5%)
			if math.random() < jumpChance then
				data.Model:SetAttribute("DoingTrick", true)

				-- Pick trick based on skill
				local trickPool = {}
				if data.SkiSkillLevel == 2 then
					trickPool = {"Safety Grab!", "Shifty!", "Method Grab!"}
				elseif data.SkiSkillLevel == 3 then
					trickPool = {"360 Spin!", "Backflip! 🔥", "Iron Cross!"}
				else
					trickPool = {"Cork 720! 🤯", "Misty Flip!", "Backflip! 🔥"}
				end

				local trickName = trickPool[math.random(#trickPool)]
				data._currentTrickName = trickName
				data.Model:SetAttribute("CurrentTrick", trickName) -- Sync to guestclient
				ShowSpeech(data.Model, trickName, 1.5)

				-- Moderate upward pop (not a rocket launch)
				data.SkiYVelocity = 25 + (math.random() * 10)

				-- Normal cooldown so they don't spam it constantly
				data.SkiTrickCooldown = math.random(10, 20) 

				task.delay(1.5, function()
					if data.Model and data.Model.Parent then
						data.Model:SetAttribute("DoingTrick", false)
						data.Model:SetAttribute("CurrentTrick", "")
					end
				end)
			end
		end
	end

	if trickCooldown > 0 then
		data.SkiTrickCooldown = trickCooldown - dt
	end
end

function FinishSkiRun(data)
	data.LastSkiRunFinishedAt = tick()

	data.Model:SetAttribute("IsSkiing", false)
	data.Model:SetAttribute("SkiSpeed", 0)

	local runDuration = tick() - (tonumber(data.SkiStartTime) or tick())
	local enforcePostUnloadSki = data.PostUnloadSkiRequired == true
	local postUnloadStartIndex = tonumber(data.PostUnloadSkiStartIndex)
	local skiIndexNow = tonumber(data.SkiIndex) or postUnloadStartIndex or 1
	local traversedSegments = (postUnloadStartIndex and skiIndexNow) and math.max(0, skiIndexNow - postUnloadStartIndex) or 0
	local postUnloadStartPos = data.PostUnloadSkiStartPos
	local currentPos = (data.Root and data.Root.Position) or postUnloadStartPos or Vector3.zero
	local flatTravelDist = postUnloadStartPos and FlatDist(postUnloadStartPos, currentPos) or 0
	local shortPostUnloadRun = (runDuration < 2.0 and flatTravelDist < 20 and traversedSegments < 2)
	if enforcePostUnloadSki and shortPostUnloadRun then
		local guestPos = (data.Root and data.Root.Position) or Vector3.zero
		ClearSkiRuntimeData(data)
		EnsureGuestWalkingPhysics(data, guestPos, nil)

		local retrySlope = FindSlopeForGuest(data, guestPos)
		if retrySlope then
			local retryPath = GetSlopeData(retrySlope)
			if retryPath and #retryPath > 1 then
				local retryEntryIndex = select(1, SelectSkiEntryIndex(retryPath, guestPos, 70, 26))
					or math.clamp((GetNearestSlopeEntryIndex(retryPath, guestPos, math.huge) or 1), 1, math.max(1, #retryPath - 2))
				local retryEntryPos = GetSlopeEntryPosition(retryPath, retryEntryIndex) or GetGroundPos(retryPath[retryEntryIndex] or retryPath[1])
				EnsureGuestWalkingPhysics(data, retryEntryPos, nil)
				data.PostUnloadSkiStartedAt = data.PostUnloadSkiStartedAt or tick()
				data.PostUnloadSkiNextRetryAt = nil
				data.PostUnloadSkiAttempts = (tonumber(data.PostUnloadSkiAttempts) or 0) + 1
				data.PostUnloadSkiStartIndex = retryEntryIndex
				data.PostUnloadSkiLastAttemptAt = tick()
				data.PostUnloadSkiStartPos = retryEntryPos
				if TryStartSkiingDown(data, retrySlope, { EntryIndex = retryEntryIndex }, "FinishSkiRunRetry") then
					return
				end
				-- Avoid instant retry loops on the same failed post-unload slope target.
				MarkSlopeAvoidance(data, retrySlope, 25)
				if data.TargetSlope == retrySlope then
					data.TargetSlope = nil
				end
				data.TargetSlopeEntryIndex = nil
			end
		end

		if StartSyntheticPostUnloadSki(data, "FinishSkiRunShort") then
			return
		end
		data.PostUnloadSkiNextRetryAt = tick() + 0.3
		data.State = STATE.DECIDING
		data.TargetLift = nil
		data.TargetSlope = nil
		data.TargetSlopeEntryIndex = nil
		data.WantsBreak = false
		return
	end
	data.PostUnloadSkiRequired = nil
	data.PostUnloadSkiStartedAt = nil
	data.PostUnloadSkiNextRetryAt = nil
	data.PostUnloadSkiAttempts = nil
	data.PostUnloadSkiStartIndex = nil
	data.PostUnloadSkiLastAttemptAt = nil
	data.PostUnloadSkiStartPos = nil

	local runs = (data.SkiRuns or 0) + 1
	data.SkiRuns = runs
	data.Model:SetAttribute("SkiRuns", runs)

	ApplySatisfaction(data, "SkiRunCompleted")

	local lessonBoost = 0
	if data.SkiSlopeModel then
		local groomLevel = data.SkiSlopeModel:GetAttribute("GroomLevel") or 0
		if groomLevel >= 70 then
			ApplySatisfaction(data, "GroomedSlope")
		elseif groomLevel < 30 then
			ApplySatisfaction(data, "UngroomedSlope")
		end

		local hasInstructor = data.SkiSlopeModel:GetAttribute("HasInstructor") == true
		local instructorLevel = tonumber(data.SkiSlopeModel:GetAttribute("InstructorLevel")) or 0
		local lessonQuality = tonumber(data.SkiSlopeModel:GetAttribute("LessonQuality")) or 0
		if hasInstructor and (data.SkiDiffNum or 0) <= 2 and (data.SkiSkillLevel or 0) <= 2 then
			data.LessonSkillBoost = math.max(tonumber(data.LessonSkillBoost) or 0, math.min(0.28, 0.04 + (instructorLevel * 0.025) + (lessonQuality * 0.02)))
		end
	end

	local restCfg = GuestConfig.Rest
	data.Energy = math.max(0, data.Energy - math.max(2, restCfg.EnergyDrainPerRun - (lessonBoost * 2)))

	SpendMoney(data, "LiftTicket")
	ReportRating(data, "GuestRodeLift")

	local satLevel = GetSatisfactionLevel(data)
	if satLevel == "Ecstatic" or satLevel == "Happy" then
		ShowSpeech(data.Model, PickRandom(GuestConfig.Complaints.Messages[satLevel]), 3)
	end

	ClearSkiRuntimeData(data)
	NormalizeGuestUpright(data, data.Root and data.Root.Position or nil, nil)

	if IsSummerSeason() then
		data.TargetLift = nil
		data.State = STATE.DECIDING
		data.WantsBreak = true
		return
	end

	local wantBreak = false
	if data.Energy < 30 then
		wantBreak = math.random() < restCfg.BreakChanceWhenTired
	else
		wantBreak = math.random() < restCfg.BreakChanceAfterRun
	end

	if wantBreak then
		data.State = STATE.DECIDING
		data.WantsBreak = true
	else
		local lift = FindLiftForGuest(data, data.Root.Position)
		if lift then
			data.State = STATE.WALKING_TO_LIFT
			data.TargetLift = lift
			local startPos = GetLiftStartPos(lift)
			MoveGuestTo(data, startPos, function()
				EnterLiftQueue(data)
			end)
		else
			data.State = STATE.DECIDING
			data.TargetLift = nil
		end
	end
end

function NotifyCrash(ownerId, crashSlopeModel)
	local player = ownerId and Players:GetPlayerByUserId(ownerId) or nil
	if not player then return end

	local now = tick()
	local state = CrashNotifyState[ownerId]
	if not state then
		state = { windowStart = now, count = 0, lastNotify = 0 }
	end

	if (now - state.windowStart) > 35 then
		state.windowStart = now
		state.count = 0
	end

	state.count += 1
	local shouldNotify = false
	local title = "Guest Crash"
	local crashSlopeName = "that slope"
	local targetPos = nil
	if crashSlopeModel and crashSlopeModel.Parent then
		crashSlopeName = tostring(crashSlopeModel:GetAttribute("DisplayName") or crashSlopeModel:GetAttribute("OriginalName") or crashSlopeModel.Name)
		local crashPath = GetSlopeData(crashSlopeModel)
		if crashPath and #crashPath > 0 then
			targetPos = GetGroundPos(crashPath[1])
		else
			targetPos = crashSlopeModel:GetPivot().Position
		end
	end
	local body = string.format("A guest crashed on %s.", crashSlopeName)

	if state.count >= 4 then
		shouldNotify = (now - state.lastNotify) > 12
		title = "Crash Spike"
		body = string.format("%d crashes recently. Add easier runs or Ski Patrol coverage.", state.count)
	elseif state.count >= 2 then
		shouldNotify = (now - state.lastNotify) > 20
		title = "Crash Alert"
		body = string.format("Multiple guests are crashing on %s. Slope difficulty may be too high.", crashSlopeName)
	else
		shouldNotify = (now - state.lastNotify) > 28
	end

	if shouldNotify then
		state.lastNotify = now
		NotifyPlayer(player, "Warning", title, body, 4, BuildTeleportNotificationAction("Go To Crash", targetPos))
	end

	CrashNotifyState[ownerId] = state
end

function CrashGuest(data)
	-- Unanchor for ragdoll
	data.Root.Anchored = false

	data.State = STATE.CRASHED
	data.CrashTime = tick()

	data.Humanoid.PlatformStand = true
	data.Humanoid.AutoRotate = false
	data.Humanoid.BreakJointsOnDeath = false
	data.Model:SetAttribute("IsSkiing", false)
	data.Model:SetAttribute("IsCrashed", true)
	data.Model:SetAttribute("SkiSpeed", 0)
	data.Model:SetAttribute("PatrolRescueTriggered", false)
	data.Model:SetAttribute("PendingMedCenterVisit", false)

	local isSevereCrash = false
	if data.SkiSpeed > 60 and math.random() < 0.25 then
		isSevereCrash = true
		data.Model:SetAttribute("NeedsSkiPatrol", true)
	end

	-- Build ragdoll: Motor6D → BallSocketConstraint (same technique as player skicontroller)
	local ragdollData = { motors = {}, constraints = {}, attachments = {}, partCollision = {} }
	local skiModel = data.Model:FindFirstChild("Skis")

	for _, desc in ipairs(data.Model:GetDescendants()) do
		if desc:IsA("Motor6D") and desc.Part0 and desc.Part1 then
			local a0 = Instance.new("Attachment")
			a0.CFrame = desc.C0
			a0.Parent = desc.Part0

			local a1 = Instance.new("Attachment")
			a1.CFrame = desc.C1
			a1.Parent = desc.Part1

			local socket = Instance.new("BallSocketConstraint")
			socket.Attachment0 = a0
			socket.Attachment1 = a1
			socket.LimitsEnabled = true
			socket.UpperAngle = 50
			socket.TwistLimitsEnabled = true
			socket.TwistLowerAngle = -35
			socket.TwistUpperAngle = 35
			socket.MaxFrictionTorque = 25
			socket.Parent = desc.Parent

			desc.Enabled = false
			table.insert(ragdollData.motors, desc)
			table.insert(ragdollData.attachments, a0)
			table.insert(ragdollData.attachments, a1)
			table.insert(ragdollData.constraints, socket)
		elseif desc:IsA("BasePart") then
			local isSkiPart = skiModel and desc:IsDescendantOf(skiModel)
			local isAccessory = desc:FindFirstAncestorWhichIsA("Accessory") ~= nil
			if isSkiPart then
				desc.CanCollide = false
				desc.CanQuery = false
			elseif desc.Name ~= "HumanoidRootPart" then
				table.insert(ragdollData.partCollision, {
					part = desc,
					canCollide = desc.CanCollide,
					canQuery = desc.CanQuery,
				})
				desc.CanCollide = not isAccessory
			end
		end
	end
	data.RagdollData = ragdollData

	-- Tumble impulse
	local root = data.Root
	if root then
		local tumbleDir = data.SkiSmoothedDir or Vector3.new(0, 0, 1)
		local crashSpeed = math.clamp((data.SkiSpeed or 20) * 0.2, 5, 30)
		root.AssemblyLinearVelocity = tumbleDir * crashSpeed + Vector3.new(0, math.clamp(crashSpeed * 0.4, 3, 12), 0)
		root.AssemblyAngularVelocity = Vector3.new(
			math.random(-6, 6), math.random(-4, 4), math.random(-6, 6)
		)
	end

	ApplySatisfaction(data, "Crashed")
	ShowSpeech(data.Model, PickRandom({"Ow!", "I crashed!", "Ouch!", "*crash* 💥", "Help!"}), 3)
	NotifyCrash(data.OwnerId, data.SkiSlopeModel)

	-- Clear ski data
	ClearSkiRuntimeData(data)

	-- Check for ski patrol rescue
	task.delay(2, function()
		if data.State ~= STATE.CRASHED then return end
		local hasPatrol = false

		-- PERF FIX: Use CollectionService or PlacedObjects instead of Workspace:GetDescendants()
		local patrolCandidates = CollectionService:GetTagged("Employee")
		if #patrolCandidates == 0 then
			local po = GetPlacedObjects()
			if po then patrolCandidates = po:GetDescendants() end
		end
		for _, emp in ipairs(patrolCandidates) do
			if emp:IsA("Model") and emp:GetAttribute("IsEmployee") and emp:GetAttribute("EmployeeType") == "SkiPatrol" and emp:FindFirstChild("HumanoidRootPart") then
				local patrolOwner = tonumber(emp:GetAttribute("EmployeeOwnerId")) or tonumber(emp:GetAttribute("OwnerId")) or tonumber(emp:GetAttribute("Owner"))
				if not (data.OwnerId and patrolOwner and patrolOwner ~= data.OwnerId) then
					local dist = FlatDist(data.Root.Position, emp.HumanoidRootPart.Position)
					if dist < 80 then
						hasPatrol = true
						break
					end
				end
			end
		end

		if hasPatrol and data.State == STATE.CRASHED then
			ApplySatisfaction(data, "RescuedByPatrol")
			ShowSpeech(data.Model, "Ski patrol is on the way.", 3)
			if data.Model and data.Model.Parent then
				data.Model:SetAttribute("NeedsSkiPatrol", true)
				data.Model:SetAttribute("PatrolRescueTriggered", false)
			end
			return
		end
	end)

	-- Auto-recover (slower without patrol)
	if not isSevereCrash then
		task.delay(GuestConfig.Crash.RescueTimeout or 8, function()
			if data.State == STATE.CRASHED and data.Model and data.Model.Parent then
				RecoverGuest(data)
			end
		end)
	else
		-- Severe crashes ONLY recover if ski patrol reaches them, or much longer timeout
		task.delay((GuestConfig.Crash.RescueTimeout or 6) * 4, function() -- PATCHED: was *8, 4x is enough
			if data.State == STATE.CRASHED and data.Model and data.Model.Parent then
				data.Model:SetAttribute("NeedsSkiPatrol", false)
				RecoverGuest(data)
			end
		end)
	end
end

function RecoverGuest(data)
	data.State = STATE.RECOVERING
	data.Model:SetAttribute("IsCrashed", false)

	-- Clean up ragdoll: restore Motor6Ds, remove BallSockets, restore collision
	local rd = data.RagdollData
	if rd then
		for _, constraint in ipairs(rd.constraints) do
			pcall(function() if constraint and constraint.Parent then constraint:Destroy() end end)
		end
		for _, attachment in ipairs(rd.attachments) do
			pcall(function() if attachment and attachment.Parent then attachment:Destroy() end end)
		end
		for _, motor in ipairs(rd.motors) do
			pcall(function() if motor and motor.Parent then motor.Enabled = true end end)
		end
		for _, entry in ipairs(rd.partCollision) do
			pcall(function()
				if entry.part and entry.part.Parent then
					entry.part.CanCollide = entry.canCollide
					entry.part.CanQuery = entry.canQuery
				end
			end)
		end
		data.RagdollData = nil
	end

	data.Humanoid.PlatformStand = false
	data.Humanoid.AutoRotate = true
	data.Humanoid:ChangeState(Enum.HumanoidStateType.GettingUp)

	ShowSpeech(data.Model, PickRandom({"I'm okay!", "That hurt...", "Getting up..."}), 2)

	task.delay(2, function()
		if data.Model and data.Model.Parent then
			data.SkiSpeed = nil
			NormalizeGuestUpright(data, data.Root and data.Root.Position or nil)

			if IsSummerSeason() then
				data.TargetLift = nil
				data.State = STATE.DECIDING
				data.WantsBreak = true
				return
			end

			if data.Model and data.Model:GetAttribute("PendingMedCenterVisit") == true then
				local medCenter = FindNearestBuilding(data.Root.Position, "MedCenter", data.OwnerId, data._AvoidBuildings)
				if medCenter then
					data.State = STATE.WALKING
					data.TargetBuilding = medCenter
					data.NextAction = "MedCenter"
					local medPos = GetMedCenterEntryPosition(medCenter) or GetGroundPos(medCenter:GetPivot().Position)
					MoveGuestTo(data, medPos, function(guestData)
						guestData.State = STATE.HEALING_MED_CENTER
						guestData.ActionTimer = 0
					end)
					return
				else
					data.Model:SetAttribute("PendingMedCenterVisit", false)
				end
			end

			-- After crash: go ride lift again or take a break
			if data.Energy < 30 or data.Satisfaction < 30 then
				data.State = STATE.DECIDING
				data.WantsBreak = true
			else
				-- Go ride lift again
				local lift = FindLiftForGuest(data, data.Root.Position)
				if lift then
					data.State = STATE.WALKING_TO_LIFT
					data.TargetLift = lift
					local startPos = GetLiftStartPos(lift)
					MoveGuestTo(data, startPos, function()
						EnterLiftQueue(data)
					end)
				else
					data.State = STATE.DECIDING
					data.TargetLift = nil
				end
			end
		end
	end)
end

-- ============================================================================
-- SATISFACTION SYSTEM
-- ============================================================================
function ApplySatisfaction(data, eventName)
	local base = GuestConfig.Satisfaction.Events[eventName] or 0
	if base == 0 then return end

	local personality = GuestConfig.Personalities[data.Personality]
	local sensitivity = personality and personality.SatisfactionSensitivity or 1.0

	local change = base * sensitivity
	data.Satisfaction = math.clamp(data.Satisfaction + change, 0, 100)
	data.Model:SetAttribute("Satisfaction", math.floor(data.Satisfaction))
end

function GetSatisfactionLevel(data)
	local sat = data.Satisfaction
	local t = GuestConfig.Satisfaction.Thresholds
	if sat >= t.Ecstatic then return "Ecstatic"
	elseif sat >= t.Happy then return "Happy"
	elseif sat >= t.Neutral then return "Neutral"
	elseif sat >= t.Unhappy then return "Unhappy"
	elseif sat >= t.Miserable then return "Miserable"
	else return "Leave" end
end

-- ============================================================================
-- ECONOMY SYSTEM
-- ============================================================================
function SpendMoney(data, category)
	local spendCfg = GuestConfig.Economy.Spending[category]
	if not spendCfg then return false end

	local cost = spendCfg.BaseCost or 0
	if category == "LiftTicket" then
		cost = GetTicketPriceForOwner(data.OwnerId)
		if data.Model and data.Model.Parent then
			data.Model:SetAttribute("LiftTicketPrice", math.floor(cost + 0.5))
		end

		local refused, fairPrice, refusalChance = ShouldGuestRefuseLiftTicket(data, cost)
		if data.Model and data.Model.Parent and fairPrice then
			data.Model:SetAttribute("LiftTicketFairPrice", math.floor(fairPrice + 0.5))
		end
		if data.Model and data.Model.Parent then
			data.Model:SetAttribute("LiftTicketRefusalChance", math.floor((refusalChance or 0) * 100 + 0.5))
		end

		if refused then
			local penalty = math.clamp(1 + ((cost - (fairPrice or cost)) * 0.08), 1, 4)
			local now = tick()
			if (not data.LastTicketRefusalPenaltyAt) or ((now - data.LastTicketRefusalPenaltyAt) >= 45) then
				data.LastTicketRefusalPenaltyAt = now
				data.Satisfaction = math.max(0, data.Satisfaction - penalty)
			end
			if data.Model and data.Model.Parent then
				data.Model:SetAttribute("Satisfaction", math.floor(tonumber(data.Satisfaction) or 0))
				data.Model:SetAttribute("RefusedLiftTicket", true)
				task.delay(4, function()
					if data.Model and data.Model.Parent then
						data.Model:SetAttribute("RefusedLiftTicket", false)
					end
				end)
			end

			if math.random() < 0.35 then
				ShowSpeech(data.Model, PickRandom({
					string.format("No way, $%d is too much.", math.floor(cost + 0.5)),
					"Ticket price is not worth it today.",
					"I am skipping that overpriced ticket.",
				}), 3)
			end
			return false
		end
	end

	if data.Budget < cost then
		-- Out of money
		data.Satisfaction = math.max(0, data.Satisfaction + (GuestConfig.Economy.OutOfMoney.SatisfactionPenalty or -10))
		if category == "LiftTicket" and math.random() < 0.55 then
			ShowSpeech(data.Model, "I cannot afford that lift ticket.", 3)
		end
		return false
	end

	data.Budget = data.Budget - cost
	data.TotalSpent = (data.TotalSpent or 0) + cost
	data.Model:SetAttribute("Budget", math.floor(data.Budget))

	-- Pay to resort owner
	local ownerId = data.OwnerId
	if ownerId and AddIncomeEvent then
		local player = Players:GetPlayerByUserId(ownerId)
		if player then
			pcall(function() AddIncomeEvent:Fire(player, cost, category, Enum.AnalyticsEconomyTransactionType.Gameplay) end)
		end
	end

	return true
end

function CheckTip(data, employeeType)
	local tipCfg = GuestConfig.Economy.Tips
	if data.Satisfaction < tipCfg.SatisfactionThreshold then return end
	if math.random() > tipCfg.ChancePerInteraction then return end

	local satRatio = data.Satisfaction / 100
	local personality = GuestConfig.Personalities[data.Personality]
	local tipMult = personality and personality.TipMultiplier or 1.0
	local tip = math.floor(tipCfg.BaseTip * satRatio * tipMult * math.min(satRatio * tipCfg.MaxTipMultiplier, tipCfg.MaxTipMultiplier))

	if tip > 0 and data.Budget >= tip then
		data.Budget = data.Budget - tip
		data.Model:SetAttribute("Budget", math.floor(data.Budget))

		if AddIncomeEvent then
			local player = Players:GetPlayerByUserId(data.OwnerId)
			if player then
				pcall(function() AddIncomeEvent:Fire(player, tip, "Tip", Enum.AnalyticsEconomyTransactionType.Gameplay) end)
			end
		end

		ShowSpeech(data.Model, "Here's a tip! 💰 $" .. tip, 3)
	end
end

-- ============================================================================
-- RATING INTEGRATION
-- ============================================================================
function ReportRating(data, eventType)
	if not RatingSystem then RatingSystem = _G.RatingSystem end
	if not RatingSystem then return end

	local player = Players:GetPlayerByUserId(data.OwnerId)
	if player then
		pcall(function()
			local guestToken
			local uuidAttr = data.Model and data.Model:GetAttribute("GuestUUID")
			if type(uuidAttr) == "string" and uuidAttr ~= "" then
				guestToken = uuidAttr
			elseif type(data.GuestUUID) == "string" and data.GuestUUID ~= "" then
				guestToken = data.GuestUUID
			else
				guestToken = tostring(data.SpawnTime or 0) .. ":" .. tostring((data.Model and data.Model.Name) or "Guest")
			end
			RatingSystem.ReportEvent(player, eventType, nil, {
				GuestToken = guestToken,
				CountGuest = (eventType == "GuestCompletedVacation") or (eventType == "GuestLeftHungry") or (eventType == "GuestLeftBroke") or (eventType == "GuestLeftTired"),
				HappyGuest = (eventType == "GuestCompletedVacation"),
				HungryGuest = (eventType == "GuestLeftHungry"),
			})
		end)
	end
end

-- ============================================================================
-- EMPLOYEE INTERACTION
-- ============================================================================
function CheckEmployeeBonus(data, building, interactionType)
	if not building then return end

	local hasLifty = building:GetAttribute("HasLifty")
	local hasChef = building:GetAttribute("HasChef")
	local hasTech = building:GetAttribute("HasTech")
	local staffLevel = building:GetAttribute("StaffLevel") or 1
	local staffEfficiency = building:GetAttribute("StaffEfficiency") or 1.0

	if interactionType == "Lift" and hasLifty then
		local bonus = GuestConfig.CalculateEmployeeBonus("Lifty", staffLevel)
		data.Satisfaction = math.clamp(data.Satisfaction + bonus, 0, 100)
		data.LiftServiceLevel = math.max(tonumber(data.LiftServiceLevel) or 0, staffLevel)
		data.LiftServiceEfficiency = math.max(tonumber(data.LiftServiceEfficiency) or 1, staffEfficiency)
		ApplySatisfaction(data, "BoardedLiftWithLifty")
		CheckTip(data, "Lifty")
	elseif interactionType == "Food" and hasChef then
		local bonus = GuestConfig.CalculateEmployeeBonus("Chef", staffLevel)
		data.Satisfaction = math.clamp(data.Satisfaction + bonus, 0, 100)
		data.FoodServiceLevel = staffLevel
		data.FoodServiceEfficiency = staffEfficiency
		data.LastFoodServiceAt = tick()
		ApplySatisfaction(data, "AteFoodWithChef")
		CheckTip(data, "Chef")
	elseif interactionType == "Rental" and hasTech then
		local bonus = GuestConfig.CalculateEmployeeBonus("RentalTech", staffLevel)
		data.Satisfaction = math.clamp(data.Satisfaction + bonus, 0, 100)
		data.RentalServiceLevel = staffLevel
		data.RentalServiceEfficiency = staffEfficiency
		data.RentalSafetyBoost = math.max(tonumber(data.RentalSafetyBoost) or 0, 0.08 + (staffLevel * 0.03) + (math.max(0, staffEfficiency - 1) * 0.12))
		data.RentalSupportUntil = tick() + 900
		ApplySatisfaction(data, "RentedGearWithTech")
		CheckTip(data, "RentalTech")
	end
end

-- ============================================================================
-- DECISION ENGINE
-- ============================================================================
function DecideNextAction(data)
	-- Priority-based decision making
	local sat = data.Satisfaction
	local hunger = data.Hunger
	local energy = data.Energy
	local hasSkis = data.HasSkis
	local pos = data.Root.Position
	local now = tick()

	-- Check if should leave
	if GetSatisfactionLevel(data) == "Leave" then
		return "Leave"
	end

	if data.ForceReturnToSkiUntil and now <= data.ForceReturnToSkiUntil and hasSkis and not IsSummerSeason() then
		local priorityLift = FindLiftForGuest(data, pos) or FindFallbackLiftForGuest(data, pos)
		if priorityLift then
			data.ForceReturnToSkiUntil = nil
			return "Ski", priorityLift
		end
	end

	-- Very hungry → eat
	if hunger < 25 then
		local food = FindNearestBuilding(pos, "Food", data.OwnerId, data._AvoidBuildings)
		if food then return "Eat", food end
		if not data.LastNoFoodPenalty or (tick() - data.LastNoFoodPenalty) > 60 then
			data.LastNoFoodPenalty = tick()
			ApplySatisfaction(data, "NoFoodAvailable")
			ReportRating(data, "GuestCouldntFindFood")
		end
	end

	-- Exhausted → rest
	if energy < 15 then
		local hotel = FindNearestBuilding(pos, "Hotel", data.OwnerId, data._AvoidBuildings)
		if hotel then return "Rest", hotel end
	end

	-- Wants a break (after ski run)
	if data.WantsBreak then
		data.WantsBreak = false
		if hunger < 60 then
			local food = FindNearestBuilding(pos, "Food", data.OwnerId, data._AvoidBuildings)
			if food then return "Eat", food end
		end
		if energy < 50 then
			local hotel = FindNearestBuilding(pos, "Hotel", data.OwnerId, data._AvoidBuildings)
			if hotel then return "Rest", hotel end
		end
	end

	-- Need rental gear
	if not hasSkis then
		if data.NeedsTicketBeforeRental and not data.HasResortTicket then
			local ticketOffice = FindNearestBuilding(pos, "TicketOffice", data.OwnerId, data._AvoidBuildings)
			if ticketOffice then
				return "Ticket", ticketOffice
			end
		end
		local rental = FindNearestBuilding(pos, "Rental", data.OwnerId, data._AvoidBuildings)
		if rental then return "Rent", rental end
		if not data.LastNoRentalPenalty or (tick() - data.LastNoRentalPenalty) > 60 then
			data.LastNoRentalPenalty = tick()
			ApplySatisfaction(data, "NoRentalAvailable")
		end
	end

	-- Assigned instructor lessons happen before free skiing for low-skill guests.
	local lessonSkill = tonumber(data.SkillLevel) or tonumber(data.SkiSkillLevel) or 0
	if hasSkis and not IsSummerSeason() and lessonSkill <= 3 then
		local lessonCfg = (((GuestConfig or {}).Economy or {}).Spending or {}).Lesson or {}
		local assignedInstructor = nil
		local assignedRecently = data.LastLessonAt and ((now - data.LastLessonAt) < 120)
		if not assignedRecently then
			assignedInstructor = GetAssignedInstructorForGuest(data)
			if assignedInstructor then
				local satReq = math.max(0, math.min(tonumber(lessonCfg.SatisfactionRequired) or 0, 10))
				local minBudget = math.max(0, (lessonCfg.BaseCost or 0) * 0.25)
				if sat >= satReq and hunger >= 15 and energy >= 20 and data.Budget >= minBudget then
					return "Lesson", assignedInstructor
				end
			elseif data.Model and data.Model:GetAttribute("AssignedInstructorUUID") then
				ClearGuestLessonAssignment(data)
			end
		end
	end

	-- Ready to ski! (main activity) — NOT during summer!
	if hasSkis and not IsSummerSeason() then
		local priceOk, liveTicketPrice, fairTicketPrice, priceRatio = pcall(function()
			local live = GetTicketPriceForOwner(data.OwnerId) or 0
			local fair = GetOwnerFairLiftTicketPrice(data.OwnerId) or 1
			return live, fair, live / math.max(1, fair)
		end)
		if not priceOk then
			liveTicketPrice = 0
			fairTicketPrice = 1
			priceRatio = 0
		end
		local recentlyFinishedRun = data.LastSkiRunFinishedAt and ((now - data.LastSkiRunFinishedAt) <= 45)
		local skipLiftChance = 0
		if priceRatio > 1.35 then
			skipLiftChance = math.clamp((priceRatio - 1.25) * 0.16, 0, 0.24)
			if data.Satisfaction < 25 then
				skipLiftChance = math.clamp(skipLiftChance + 0.04, 0, 0.28)
			end
			if data.Budget < (liveTicketPrice * 1.05) then
				skipLiftChance = math.clamp(skipLiftChance + 0.05, 0, 0.32)
			end
		end
		if recentlyFinishedRun then
			skipLiftChance = skipLiftChance * 0.15
		end
		skipLiftChance = math.clamp(skipLiftChance, 0, 0.16)

		if skipLiftChance > 0 and math.random() < skipLiftChance then
			if not data.LastPriceComplaint or (now - data.LastPriceComplaint) > 45 then
				data.LastPriceComplaint = now
				ShowSpeech(data.Model, PickRandom({
					string.format("Lift is overpriced at $%d.", liveTicketPrice),
					"Prices are too high for this resort.",
					"I am not paying that much for a ticket.",
				}), 3)
			end
			return "Wander"
		end

		local lift = FindLiftForGuest(data, pos)
		if lift then
			data._LiftRetryCount = 0
			return "Ski", lift
		end
		local fallbackLift = FindFallbackLiftForGuest(data, pos)
		if fallbackLift then
			data._LiftRetryCount = 0
			return "Ski", fallbackLift
		end

		-- Last-resort route safety net: if the richer scorer misses but a lift is
		-- operational, still send the guest there instead of dead-ending in Deciding.
		local emergencyLift = FindNearestBuilding(pos, "Lift", data.OwnerId, data._AvoidBuildings)
		if emergencyLift and IsLiftOperationalForGuestRouting(emergencyLift) then
			data._LiftRetryCount = 0
			return "Ski", emergencyLift
		end

		-- No sightseeing fallback here: guests should only ride lifts that serve skiable slopes.

		-- FIX: Track consecutive failed lift searches. After 3 failures, force
		-- the guest to Wander so they don't stand frozen in a Deciding→Idle loop.
		if RunService:IsStudio() and data.Model and data.Model.Parent then
			local studioOwnerLiftCount = #FindBuildingsByType("Lift", data.OwnerId)
			local studioOwnerSlopeCount = #FindBuildingsByType("Slope", data.OwnerId)
			local studioGlobalLiftCount = #FindBuildingsByType("Lift")
			local studioGlobalSlopeCount = #FindBuildingsByType("Slope")
			data.Model:SetAttribute("LiftDebug", string.format("ownerLifts=%d ownerSlopes=%d globalLifts=%d globalSlopes=%d", studioOwnerLiftCount, studioOwnerSlopeCount, studioGlobalLiftCount, studioGlobalSlopeCount))
		end
		data._LiftRetryCount = (data._LiftRetryCount or 0) + 1

		local ownerLiftCount = #FindBuildingsByType("Lift", data.OwnerId)
		local ownerSlopeCount = #FindBuildingsByType("Slope", data.OwnerId)
		local globalLiftCount = #FindBuildingsByType("Lift")
		local globalSlopeCount = #FindBuildingsByType("Slope")
		local hasAnyLift = (ownerLiftCount > 0) or (globalLiftCount > 0)
		local hasAnySlope = (ownerSlopeCount > 0) or (globalSlopeCount > 0)
		local trulyNoSlopes = not hasAnySlope
		local trulyNoLifts = hasAnySlope and (not hasAnyLift)
		local transientLiftSearchMiss = hasAnySlope and hasAnyLift

		local isFirstRunWindow = ((data.SkiRuns or 0) <= 0) and ((now - (tonumber(data.SpawnTime) or now)) <= 300)
		if (data._LiftRetryCount >= 4) and (not data.LastNoSlopePenalty or (tick() - data.LastNoSlopePenalty) > 45) then
			data.LastNoSlopePenalty = tick()
			if trulyNoSlopes then
				ShowSpeech(data.Model, PickRandom({"No slopes to ski on!", "Where are the slopes?!", "Build some slopes!"}), 4)
			elseif trulyNoLifts then
				ShowSpeech(data.Model, PickRandom({"No lifts are running.", "Need a lift to get up there.", "I cannot find an open lift."}), 4)
			elseif transientLiftSearchMiss then
				ShowSpeech(data.Model, PickRandom({"All lifts look busy right now.", "Trying to find a lift...", "I will catch the next chair."}), 3)
			end
			if (trulyNoSlopes or trulyNoLifts) and (not isFirstRunWindow) and (not data._LastSlopeSatPenalty or (tick() - data._LastSlopeSatPenalty) > 120) then
				data._LastSlopeSatPenalty = tick()
				if trulyNoSlopes then
					ApplySatisfaction(data, "NoSlopesAvailable")
				else
					ApplySatisfaction(data, "LiftClosed")
				end
				ReportRating(data, "GuestCouldntFindLift")
			end
		end

		if data._LiftRetryCount >= 3 then
			data._LiftRetryCount = 0
			-- Break the stuck loop: eat, rest, or wander instead of retrying forever
			if hunger < 70 then
				local food = FindNearestBuilding(pos, "Food", data.OwnerId, data._AvoidBuildings)
				if food then return "Eat", food end
			end
			if energy < 60 then
				local hotel = FindNearestBuilding(pos, "Hotel", data.OwnerId, data._AvoidBuildings)
				if hotel then return "Rest", hotel end
			end
			return "Wander"
		end

		return "RetryLift"
	end

	if IsSummerSeason() then
		if hunger < 70 then
			local food = FindNearestBuilding(pos, "Food", data.OwnerId)
			if food then return "Eat", food end
		end
		if energy < 60 then
			local hotel = FindNearestBuilding(pos, "Hotel", data.OwnerId)
			if hotel then return "Rest", hotel end
		end
		return "Wander"
	end

	if hunger < 60 then
		local food = FindNearestBuilding(pos, "Food", data.OwnerId)
		if food then return "Eat", food end
	end

	return "Wander"
end

function IsGuestNearHotelFootprint(data, padding)
	local hotelModel = data and data.HotelModel
	local root = data and data.Root
	if not hotelModel or not hotelModel.Parent or not root then
		return false
	end

	local boxCF, boxSize = hotelModel:GetBoundingBox()
	return not IsOutsideHotelBounds(boxCF, boxSize, root.Position, padding or 0)
end

function ForceGuestHotelEgress(data)
	local hotelModel = data and data.HotelModel
	local root = data and data.Root
	if not hotelModel or not hotelModel.Parent or not root then
		return false
	end

	local outsidePos = ResolveHotelSpawnPos(hotelModel)
	if typeof(outsidePos) ~= "Vector3" then
		return false
	end

	if FlatDist(root.Position, outsidePos) <= 6 then
		local facing = GetSafeFlatDirection(outsidePos - root.Position, root.CFrame.LookVector)
		root.CFrame = CFrame.lookAt(outsidePos, outsidePos + facing)
		root.AssemblyLinearVelocity = Vector3.zero
		root.AssemblyAngularVelocity = Vector3.zero
		return true
	end

	MoveGuestTo(data, outsidePos, nil)
	return true
end

-- ============================================================================
-- STATE HANDLERS
-- ============================================================================
function ProcessIdle(data, dt)
	SnapGuestOutsideHotelIfInside(data)
	SnapGuestToGroundIfFloating(data, 2.5)
	if data.HotelModel and data.HotelModel.Parent and (tick() - (data.SpawnTime or 0)) <= 10 and IsGuestNearHotelFootprint(data, 5) then
		if ForceGuestHotelEgress(data) then
			return
		end
	end
	data.IdleTimer = (data.IdleTimer or 0) + dt

	-- Random thoughts
	if data.IdleTimer > 3 and math.random() < 0.01 then
		local level = GetSatisfactionLevel(data)
		local msg = GuestConfig.GetComplaintMessage(data.Satisfaction)
		if msg then
			ShowSpeech(data.Model, msg, 4)
			data.Model:SetAttribute("Thought", msg)
		end
	end

	if data.IdleTimer > 0.5 then
		data.IdleTimer = 0
		data.State = STATE.DECIDING
	end
end

function ProcessDeciding(data)
	SnapGuestOutsideHotelIfInside(data)
	SnapGuestToGroundIfFloating(data, 2.5)
	if data.HotelModel and data.HotelModel.Parent and (tick() - (data.SpawnTime or 0)) <= 10 and IsGuestNearHotelFootprint(data, 5) then
		if ForceGuestHotelEgress(data) then
			return
		end
	end

	-- FIX: Safety net — if the guest has been cycling DECIDING/IDLE for too long,
	-- force a fresh activity dispatch. Stale MoveTarget can otherwise bypass this guard.
	local nowTick = tick()
	local lastActivity = data._LastActivityTime or data.SpawnTime or nowTick
	local staleMoveTarget = data.MoveTarget and ((nowTick - (data.LastMoveCommandTime or 0)) > 8)
	if (nowTick - lastActivity) > 15 and (not data.MoveTarget or staleMoveTarget) then
		if staleMoveTarget then
			ClearGuestMoveCommandState(data)
		end
		data._LastActivityTime = nowTick
		data._LiftRetryCount = 0
		local pos = data.Root and data.Root.Position or Vector3.zero
		-- Try eat/rest first, otherwise wander
		if (data.Hunger or 100) < 70 then
			local food = FindNearestBuilding(pos, "Food", data.OwnerId, data._AvoidBuildings)
			if food then
				data.State = STATE.WALKING
				data.TargetBuilding = food
				data.NextAction = "Eat"
				local cf, sz = food:GetBoundingBox()
				local eatPos = GetBuildingApproachPosition(food, (sz.Z / 2) + 5) or (cf.Position + cf.LookVector * ((sz.Z / 2) + 5))
				eatPos = GetGroundPos(eatPos)
				MoveGuestTo(data, eatPos, function() data.State = STATE.EATING; data.ActionTimer = 0 end)
				return
			end
		end
		data.State = STATE.WALKING
		data.NextAction = "Wander"
		data.WanderAnchor = pos
		local wanderTarget = pos + Vector3.new(math.random(-35, 35), 0, math.random(-35, 35))
		wanderTarget = ResolveWalkableGroundPos(wanderTarget, nil, false)
		MoveGuestTo(data, wanderTarget, function() data.State = STATE.IDLE; data.IdleTimer = 0 end)
		return
	end

	if not IsSummerSeason() and data.HasSkis and data.RecentlyUnloadedAt and (nowTick - data.RecentlyUnloadedAt) <= 75 then
		local guestPos = (data.Root and data.Root.Position) or Vector3.zero
		local chosenSlope = nil
		local chosenPath = nil
		local chosenEntryIndex = nil
		local chosenEntryPos = nil

		local postUnloadSlope = FindSlopeForGuest(data, guestPos)
			or FindAnySlopeForGuest(data, guestPos)
			or FindEmergencySlopeForGuest(data, guestPos)
		if postUnloadSlope then
			local postPath = GetSlopeData(postUnloadSlope)
			if postPath and #postPath > 1 then
				local postEntryIndex = select(1, SelectSkiEntryIndex(postPath, guestPos, 55, 20))
					or math.clamp((GetNearestSlopeEntryIndex(postPath, guestPos, math.huge) or 1), 1, math.max(1, #postPath - 2))
				local postEntryPos = GetSlopeEntryPosition(postPath, postEntryIndex) or GetGroundPos(postPath[postEntryIndex] or postPath[1])
				chosenSlope = postUnloadSlope
				chosenPath = postPath
				chosenEntryIndex = postEntryIndex
				chosenEntryPos = postEntryPos
			end
		end

		-- If smart selectors miss, force nearest usable authored slope so post-unload can't dead-loop.
		if not chosenSlope then
			local slopePool = FindBuildingsByType("Slope", data.OwnerId)
			if #slopePool == 0 then
				slopePool = FindBuildingsByType("Slope")
			end
			local bestDist = math.huge
			for _, candidate in ipairs(slopePool) do
				local candidatePath = GetSlopeData(candidate)
				if candidatePath and #candidatePath > 1 then
					local entryIndex = select(1, SelectSkiEntryIndex(candidatePath, guestPos, math.huge, 6))
						or math.clamp((GetNearestSlopeEntryIndex(candidatePath, guestPos, math.huge) or 1), 1, math.max(1, #candidatePath - 2))
					local entryPos = GetSlopeEntryPosition(candidatePath, entryIndex) or GetGroundPos(candidatePath[entryIndex] or candidatePath[1])
					local dist = FlatDist(guestPos, entryPos)
					if dist < bestDist then
						bestDist = dist
						chosenSlope = candidate
						chosenPath = candidatePath
						chosenEntryIndex = entryIndex
						chosenEntryPos = entryPos
					end
				end
			end
		end

		if chosenSlope and chosenPath and chosenEntryIndex and chosenEntryPos then
			data.PostUnloadSkiRequired = true
			data.PostUnloadSkiStartedAt = data.PostUnloadSkiStartedAt or nowTick
			data.PostUnloadSkiNextRetryAt = data.PostUnloadSkiNextRetryAt or (nowTick + 0.15)
			data.PostUnloadSkiAttempts = tonumber(data.PostUnloadSkiAttempts) or 0
			data.PostUnloadSkiStartPos = data.PostUnloadSkiStartPos or guestPos
			data.TargetLift = nil
			data.WantsBreak = false
			if TryStartSkiingDown(data, chosenSlope, { EntryIndex = chosenEntryIndex }, "DecidingPostUnload") then
				return
			end

			data.TargetSlope = chosenSlope
			data.TargetSlopeEntryIndex = chosenEntryIndex
			data.State = STATE.SKIING_TO_SLOPE
			MoveGuestTo(data, chosenEntryPos, function(guestData)
				if not TryStartSkiingDown(guestData, chosenSlope, { EntryIndex = chosenEntryIndex }, "DecidingPostUnloadWalkToEntry") then
					MarkSlopeAvoidance(guestData, chosenSlope, 18)
					guestData.PostUnloadSkiNextRetryAt = tick() + 0.35
					guestData.State = STATE.DECIDING
					if guestData.TargetSlope == chosenSlope then
						guestData.TargetSlope = nil
					end
					guestData.TargetSlopeEntryIndex = nil
				end
			end)
			return
		end

		-- No authored slope was resolved right now; keep the post-unload lock active briefly
		-- so we don't immediately bounce guests back into lift selection loops.
		data.PostUnloadSkiAttempts = (tonumber(data.PostUnloadSkiAttempts) or 0) + 1
		local postUnloadStart = tonumber(data.PostUnloadSkiStartedAt) or nowTick
		if data.PostUnloadSkiAttempts < 12 and (nowTick - postUnloadStart) <= 20 then
			data.PostUnloadSkiNextRetryAt = nowTick + 0.35
			data.TargetLift = nil
			data.WantsBreak = false
			return
		end
		data.PostUnloadSkiRequired = nil
		data.PostUnloadSkiStartedAt = nil
		data.PostUnloadSkiNextRetryAt = nil
		data.PostUnloadSkiAttempts = nil
		data.PostUnloadSkiStartPos = nil
		data.RecentlyUnloadedAt = nil
	end

	local action, target = DecideNextAction(data)

	if action == "Leave" then
		data.State = STATE.LEAVING
		ShowSpeech(data.Model, PickRandom(GuestConfig.Complaints.Messages.Miserable), 3)
		local leaveTarget = ResolveGuestLeaveTarget(data)
		MoveGuestTo(data, leaveTarget, function()
			RemoveGuest(data)
		end)
		task.delay(14, function()
			if data and data.Model and data.Model.Parent and data.State == STATE.LEAVING then
				RemoveGuest(data)
			end
		end)
		return

	elseif action == "Eat" and target then
		data.State = STATE.WALKING
		data.TargetBuilding = target
		data.TargetInstructor = nil
		data.NextAction = "Eat"
		local cf, size = target:GetBoundingBox()
		local frontOffset = (size.Z / 2) + 5
		local sideOffset = (math.random() - 0.5) * math.min(size.X * 0.5, 8)
		local eatPos = GetBuildingApproachPosition(target, frontOffset, sideOffset) or (cf.Position + cf.LookVector * frontOffset + cf.RightVector * sideOffset)
		eatPos = GetGroundPos(eatPos)
		MoveGuestTo(data, eatPos, function()
			data.State = STATE.EATING
			data.ActionTimer = 0
		end)

	elseif action == "Rest" and target then
		data.State = STATE.WALKING
		data.TargetBuilding = target
		data.TargetInstructor = nil
		data.NextAction = "Rest"
		local cf, size = target:GetBoundingBox()
		local frontOffset = (size.Z / 2) + 4
		local restPos = GetBuildingApproachPosition(target, frontOffset) or (cf.Position + cf.LookVector * frontOffset)
		restPos = GetGroundPos(restPos)
		MoveGuestTo(data, restPos, function()
			data.State = STATE.RESTING
			data.ActionTimer = 0
		end)

	elseif action == "Ticket" and target then
		data.State = STATE.WALKING
		data.TargetBuilding = target
		data.TargetInstructor = nil
		data.NextAction = "Ticket"
		data.TicketQueueSlot = nil
		data.TicketQueueLane = nil
		local queuePos = GetTicketQueueTargetPosition(data, target) or GetBuildingApproachPosition(target, 5)
		queuePos = GetGroundPos(queuePos)
		MoveGuestTo(data, queuePos, function(guestData)
			guestData.State = STATE.BUYING_TICKET
			guestData.ActionTimer = 0
		end)

	elseif action == "Rent" and target then
		data.State = STATE.WALKING
		data.TargetBuilding = target
		data.TargetInstructor = nil
		data.NextAction = "Rent"
		local cf, size = target:GetBoundingBox()
		local frontOffset = (size.Z / 2) + 4
		local rentPos = GetBuildingApproachPosition(target, frontOffset) or (cf.Position + cf.LookVector * frontOffset)
		rentPos = GetGroundPos(rentPos)
		MoveGuestTo(data, rentPos, function()
			data.State = STATE.RENTING_GEAR
			data.ActionTimer = 0
		end)

	elseif action == "Lesson" and target then
		local confirmedInstructor, lessonPos = GetAssignedInstructorForGuest(data)
		if not confirmedInstructor or confirmedInstructor ~= target then
			ClearGuestLessonAssignment(data)
			data.State = STATE.DECIDING
			return
		end
		data.State = STATE.WALKING
		data.TargetBuilding = nil
		data.TargetLift = nil
		data.TargetSlope = nil
		data.TargetInstructor = confirmedInstructor
		data.LessonTargetPos = lessonPos
		data.NextAction = "Lesson"
		MoveGuestTo(data, lessonPos, function(guestData)
			local liveInstructor = nil
			liveInstructor, guestData.LessonTargetPos = GetAssignedInstructorForGuest(guestData)
			if not liveInstructor or liveInstructor ~= confirmedInstructor then
				ClearGuestLessonAssignment(guestData)
				guestData.State = STATE.DECIDING
				return
			end
			guestData.TargetInstructor = liveInstructor
			guestData.State = STATE.TAKING_LESSON
			guestData.ActionTimer = 0
			guestData.Model:SetAttribute("State", STATE.TAKING_LESSON)
			guestData.Model:SetAttribute("TakingLesson", true)
		end)

	elseif action == "Ski" and target then
		data.State = STATE.WALKING_TO_LIFT
		data.TargetInstructor = nil
		data.TargetLift = target
		local queueAnchorPos = select(1, GetLiftQueueLinePose(target)) or GetLiftStartPos(target)
		local startPos = ResolveWalkableGroundPos(queueAnchorPos, GetQueueGroundExtras(target), false)
		MoveGuestTo(data, startPos, function()
			EnterLiftQueue(data)
		end)

	elseif action == "RetryLift" then
		data.TargetInstructor = nil
		data.State = STATE.IDLE
		data.TargetLift = nil
		data.IdleTimer = -1.25

	else
		data.State = STATE.WALKING
		data.TargetInstructor = nil

		if data.NextAction ~= "Wander" then
			data.WanderAnchor = data.Root.Position
		end
		data.NextAction = "Wander"

		local anchor = data.WanderAnchor or data.Root.Position
		if (data.Root.Position - anchor).Magnitude > 150 then
			anchor = data.Root.Position
			data.WanderAnchor = anchor
		end

		local wanderTarget = anchor + Vector3.new(
			math.random(-35, 35), 0, math.random(-35, 35)
		)
		wanderTarget = ResolveWalkableGroundPos(wanderTarget, nil, false)
		MoveGuestTo(data, wanderTarget, function()
			data.State = STATE.IDLE
			data.IdleTimer = 0
		end)
	end
end

function ProcessEating(data, dt)
	data.ActionTimer = (data.ActionTimer or 0) + dt

	local staffLevel = 0
	local staffEfficiency = 1
	if data.TargetBuilding and data.TargetBuilding:GetAttribute("HasChef") then
		staffLevel = tonumber(data.TargetBuilding:GetAttribute("StaffLevel")) or 1
		staffEfficiency = tonumber(data.TargetBuilding:GetAttribute("StaffEfficiency")) or 1
	end

	local eatDuration = 8
	local hungerRate = 3
	local energyRate = 0.2
	if staffLevel > 0 then
		eatDuration = math.max(4.5, 8 - (staffLevel * 0.45) - (math.max(0, staffEfficiency - 1) * 1.5))
		hungerRate = 3 + (staffLevel * 0.4) + (math.max(0, staffEfficiency - 1) * 1.4)
		energyRate = 0.25 + (staffLevel * 0.05)
	end

	if data.ActionTimer < 0.5 then
		ShowSpeech(data.Model, PickRandom({"Yum!", "This is good!", "Hungry! 🍔", "Eating..."}), 3)
	end

	data.Hunger = math.min(100, data.Hunger + hungerRate * dt)
	data.Energy = math.min(100, (data.Energy or 100) + energyRate * dt)
	data.Model:SetAttribute("Hunger", math.floor(data.Hunger))
	data.Model:SetAttribute("Energy", math.floor(data.Energy))

	if data.ActionTimer > eatDuration then
		data.Hunger = 100
		data.Model:SetAttribute("Hunger", 100)

		SpendMoney(data, "Food")

		if data.TargetBuilding then
			CheckEmployeeBonus(data, data.TargetBuilding, "Food")
		else
			ApplySatisfaction(data, "AteFood")
		end

		ReportRating(data, "GuestAteFood")

		data.State = STATE.IDLE
		data.IdleTimer = 0
		data.TargetBuilding = nil
	end
end

function ProcessResting(data, dt)
	data.ActionTimer = (data.ActionTimer or 0) + dt

	-- Restore energy
	local restRate = GuestConfig.Rest.EnergyRestorePerSecond
	data.Energy = math.min(100, data.Energy + restRate * dt)
	data.Model:SetAttribute("Energy", math.floor(data.Energy))

	-- Also slowly restore hunger
	data.Hunger = math.min(100, data.Hunger + 0.3 * dt)

	-- Rest satisfaction
	data.Satisfaction = math.min(100, data.Satisfaction + GuestConfig.Satisfaction.Recovery.Resting * dt)

	local restDuration = math.random(GuestConfig.Rest.RestDuration.Min, GuestConfig.Rest.RestDuration.Max)

	if data.ActionTimer > restDuration or data.Energy >= 90 then
		data.State = STATE.IDLE
		data.IdleTimer = 0
		data.TargetBuilding = nil
		ShowSpeech(data.Model, PickRandom({"Feeling rested!", "Ready to go!", "Let's ski! ⛷️"}), 2)
	end
end

function ProcessTakingLesson(data, dt)
	local instructor, lessonPos = GetAssignedInstructorForGuest(data)
	if not instructor or not lessonPos then
		ClearGuestLessonAssignment(data)
		data.State = STATE.DECIDING
		data.TargetInstructor = nil
		return
	end

	local instructorRoot = instructor.PrimaryPart or instructor:FindFirstChild("HumanoidRootPart")
	if not instructorRoot then
		ClearGuestLessonAssignment(data)
		data.State = STATE.DECIDING
		data.TargetInstructor = nil
		return
	end

	local targetPos = ResolveMovementTargetPos(data, lessonPos)
	local flatToLesson = FlatDist(data.Root.Position, targetPos)
	if flatToLesson > 8 then
		data.State = STATE.WALKING
		data.TargetInstructor = instructor
		data.LessonTargetPos = targetPos
		data.NextAction = "Lesson"
		MoveGuestTo(data, targetPos, function(guestData)
			local liveInstructor = nil
			liveInstructor, guestData.LessonTargetPos = GetAssignedInstructorForGuest(guestData)
			if not liveInstructor then
				ClearGuestLessonAssignment(guestData)
				guestData.State = STATE.DECIDING
				guestData.TargetInstructor = nil
				return
			end
			guestData.TargetInstructor = liveInstructor
			guestData.State = STATE.TAKING_LESSON
			guestData.Model:SetAttribute("State", STATE.TAKING_LESSON)
			guestData.Model:SetAttribute("TakingLesson", true)
		end)
		return
	end

	data.TargetInstructor = instructor
	data.LessonTargetPos = targetPos
	data.State = STATE.TAKING_LESSON
	data.Model:SetAttribute("State", STATE.TAKING_LESSON)
	data.Model:SetAttribute("TakingLesson", true)
	data.ActionTimer = (data.ActionTimer or 0) + dt

	if data.Root.Anchored then
		data.Root.Anchored = false
	end
	if data.Humanoid.PlatformStand then
		data.Humanoid.PlatformStand = false
	end
	data.Humanoid.AutoRotate = true
	data.Humanoid.WalkSpeed = math.max(14, data.Humanoid.WalkSpeed or 16)

	local faceTarget = instructorRoot.Position
	data.Root.CFrame = CFrame.lookAt(targetPos, Vector3.new(faceTarget.X, targetPos.Y, faceTarget.Z))
	data.Root.AssemblyLinearVelocity = Vector3.zero
	data.Root.AssemblyAngularVelocity = Vector3.zero

	if data.ActionTimer < 0.3 then
		ShowSpeech(data.Model, PickRandom({"Lesson time.", "Learning the basics.", "Listening closely."}), 2.5)
	end

	local lessonQuality = math.max(1, tonumber(instructor:GetAttribute("LessonQuality")) or tonumber(instructor:GetAttribute("InstructorLevel")) or 1)
	local instructorLevel = math.max(1, tonumber(instructor:GetAttribute("InstructorLevel")) or lessonQuality)
	local lessonDurationScale = math.clamp(tonumber(instructor:GetAttribute("LessonDurationScale")) or 1, 0.55, 1.2)
	local lessonDuration = math.clamp((12 - ((instructorLevel - 1) * 0.8) - ((lessonQuality - 1) * 0.45)) * lessonDurationScale, 4.5, 12)
	local progress = math.clamp(data.ActionTimer / lessonDuration, 0, 1)
	data.Model:SetAttribute("LessonProgress", math.floor(progress * 100 + 0.5))

	data.Hunger = math.max(0, data.Hunger - (0.18 * dt))
	data.Energy = math.max(0, data.Energy - (0.08 * dt))
	data.Model:SetAttribute("Hunger", math.floor(data.Hunger))
	data.Model:SetAttribute("Energy", math.floor(data.Energy))

	if data.ActionTimer >= lessonDuration then
		local lessonBoost = math.min(0.28, 0.04 + (instructorLevel * 0.025) + (lessonQuality * 0.02))
		data.LessonSkillBoost = math.max(tonumber(data.LessonSkillBoost) or 0, lessonBoost)
		SpendMoney(data, "Lesson")
		ApplySatisfaction(data, "TookLesson")
		ShowSpeech(data.Model, PickRandom({"I get it now!", "That helped a lot.", "Ready for the run!"}), 2.5)
		ClearGuestLessonAssignment(data)
		data.TargetInstructor = nil
		data.State = STATE.IDLE
		data.IdleTimer = 0
	end
end

function ProcessRenting(data, dt)
	data.ActionTimer = (data.ActionTimer or 0) + dt

	local staffLevel = 0
	local staffEfficiency = 1
	if data.TargetBuilding and data.TargetBuilding:GetAttribute("HasTech") then
		staffLevel = tonumber(data.TargetBuilding:GetAttribute("StaffLevel")) or 1
		staffEfficiency = tonumber(data.TargetBuilding:GetAttribute("StaffEfficiency")) or 1
	end

	local rentDuration = 4
	if staffLevel > 0 then
		rentDuration = math.max(2.25, 4 - (staffLevel * 0.35) - (math.max(0, staffEfficiency - 1) * 1.4))
	end

	if data.ActionTimer < 0.5 then
		ShowSpeech(data.Model, "Getting gear... 🎿", 3)
	end

	if data.ActionTimer > rentDuration then
		data.HasSkis = true
		data.Model:SetAttribute("HasSkis", true)
		data.Model:SetAttribute("NeedsRental", false)
		data.LastRentalAt = tick()

		if staffLevel > 0 then
			data.RentalSafetyBoost = math.max(tonumber(data.RentalSafetyBoost) or 0, 0.08 + (staffLevel * 0.03) + (math.max(0, staffEfficiency - 1) * 0.12))
			data.RentalSupportUntil = tick() + 900
		end

		SpendMoney(data, "Rental")

		if data.TargetBuilding then
			CheckEmployeeBonus(data, data.TargetBuilding, "Rental")
		else
			ApplySatisfaction(data, "RentedGear")
		end

		ShowSpeech(data.Model, PickRandom({"Got my gear!", "Ready to shred! 🎿", "Let's go!"}), 2)

		data.State = STATE.IDLE
		data.IdleTimer = 0
		data.TargetBuilding = nil
	end
end

function ProcessBuyingTicket(data, dt)
	data.ActionTimer = (data.ActionTimer or 0) + dt
	if not data.TargetBuilding or not data.TargetBuilding.Parent then
		data.State = STATE.DECIDING
		data.ActionTimer = 0
		return
	end

	if data.ActionTimer < 0.45 then
		ShowSpeech(data.Model, PickRandom({"Need my ticket first.", "Buying ticket...", "Almost at the window."}), 2.5)
	end

	local queuePos = GetTicketQueueTargetPosition(data, data.TargetBuilding)
	if queuePos and FlatDist(data.Root.Position, queuePos) > 2.8 then
		MoveGuestTo(data, queuePos, function(guestData)
			if guestData.State == STATE.WALKING then
				guestData.State = STATE.BUYING_TICKET
			end
		end)
		return
	end

	local ticketDuration = 3.1 + math.random() * 1.8
	if data.ActionTimer >= ticketDuration then
		data.HasResortTicket = true
		data.NeedsTicketBeforeRental = false
		if data.Model and data.Model.Parent then
			data.Model:SetAttribute("HasResortTicket", true)
			data.Model:SetAttribute("NeedsTicketBeforeRental", false)
			data.Model:SetAttribute("TicketPurchaseMode", "InPerson")
		end
		ShowSpeech(data.Model, PickRandom({"Ticket secured.", "Got my pass.", "Now I need my rental gear."}), 2)
		data.State = STATE.IDLE
		data.IdleTimer = 0
		data.ActionTimer = 0
		data.TargetBuilding = nil
		data.TicketQueueSlot = nil
		data.TicketQueueLane = nil
	end
end

function ProcessMedCenterHealing(data, dt)
	data.ActionTimer = (data.ActionTimer or 0) + dt
	if data.ActionTimer < 0.4 then
		ShowSpeech(data.Model, PickRandom({"Getting checked out.", "I need a quick recovery.", "Med team has me."}), 2.5)
	end

	if data.ActionTimer >= 6.5 then
		data.Energy = math.min(100, (data.Energy or 50) + 45)
		data.Hunger = math.min(100, (data.Hunger or 50) + 18)
		data.Satisfaction = math.min(100, (data.Satisfaction or 50) + 8)
		data.Model:SetAttribute("Energy", math.floor(data.Energy))
		data.Model:SetAttribute("Hunger", math.floor(data.Hunger))
		data.Model:SetAttribute("Satisfaction", math.floor(data.Satisfaction))
		data.Model:SetAttribute("PendingMedCenterVisit", false)
		data.Model:SetAttribute("PatrolRescueTriggered", false)
		data.ForceReturnToSkiUntil = tick() + 90
		data.State = STATE.DECIDING
		data.IdleTimer = 0
		data.ActionTimer = 0
		data.TargetBuilding = nil
		ShowSpeech(data.Model, PickRandom({"Feeling better.", "Back to the mountain.", "I can ski again."}), 2)
	end
end

function ProcessWaitingLift(data, dt)
	if IsSummerSeason() then
		ClearLiftQueueState(data)
		data.TargetLift = nil
		data.WaitStartTime = nil
		data.WantsBreak = true
		data.State = STATE.DECIDING
		return
	end

	local lift = data.TargetLift
	if not lift or not lift.Parent then
		ClearLiftQueueState(data)
		data.State = STATE.DECIDING
		data.TargetLift = nil
		return
	end

	local now = tick()
	local waitTime = now - (data.WaitStartTime or now)
	local routing = GetLiftRoutingConfig()
	local queueBehavior = GetQueueBehaviorConfig()
	if not IsLiftBoardingAvailable(lift) then
		MarkLiftAvoidance(data, lift, math.max(12, tonumber(routing.AvoidLiftSeconds) or 20))
		ClearLiftQueueState(data)
		data.WaitStartTime = nil
		data.LastQueueEvalAt = 0
		local altLift = FindLiftForGuest(data, data.Root and data.Root.Position or lift:GetPivot().Position)
		if altLift and altLift ~= lift then
			data.TargetLift = altLift
			data.State = STATE.WALKING_TO_LIFT
			local startPos = GetLiftStartPos(altLift)
			MoveGuestTo(data, startPos, function()
				EnterLiftQueue(data)
			end)
			ShowSpeech(data.Model, "This lift stopped. Trying another one.", 3)
		else
			data.TargetLift = nil
			data.State = STATE.DECIDING
			ShowSpeech(data.Model, "Lift is stopped. I will do something else.", 3)
		end
		return
	end

	local liftUUID = lift:GetAttribute("UUID") or ""
	local queueIndex = GetLiftQueueIndex(data, liftUUID)
	local slotTarget, distToSlot, queueDepth = UpdateWaitingGuestQueuePosition(data, lift, queueIndex, now)
	local frontDepth = math.max(1, tonumber(queueDepth) or 1)
	local isFrontOfQueue = frontDepth <= 1

	if slotTarget and distToSlot and distToSlot > 80 and waitTime > 8 then
		ClearLiftQueueState(data)
		data.State = STATE.WALKING_TO_LIFT
		data.WaitStartTime = nil
		data.LastQueueEvalAt = 0
		data.MoveTarget = nil
		data.MoveCallback = nil
		data.Waypoints = nil
		local startPos = GetLiftStartPos(lift)
		MoveGuestTo(data, startPos, function()
			EnterLiftQueue(data)
		end)
		return
	end

	local queuePressure = GetLiftQueuePressure(lift)
	local queueInfo = LiftQueueStats[liftUUID]
	local softQueueLimit = GetLiftQueueSoftLimit(lift)
	local waitingCount = queueInfo and queueInfo.waiting or 0
	local smallQueue = waitingCount < 10
	local overSoftCap = waitingCount >= softQueueLimit
	local predictedWait = GetLiftPredictedWaitSeconds(lift, queuePressure)
	data.PredictedQueueWait = predictedWait

	local emergencyOverload =
		queuePressure >= queueBehavior.EmergencyPressure or
		waitingCount >= math.floor(softQueueLimit * 1.25)
	local shouldEvalNormal =
		waitTime >= queueBehavior.RerouteCheckStartSeconds and
		predictedWait >= queueBehavior.RerouteIfPredictedWaitAbove and
		(overSoftCap or queuePressure >= routing.OvercrowdedPressure)
	local shouldEval = emergencyOverload or shouldEvalNormal
	if frontDepth > 1 then
		shouldEval = false
	end
	if emergencyOverload and waitTime < math.max(queueBehavior.MinCommitWaitSeconds, 18) then
		shouldEval = false
	end
	if smallQueue and not emergencyOverload and waitTime < math.max(queueBehavior.MinCommitWaitSeconds + 35, 70) then
		shouldEval = false
	end

	if shouldEval and ((not data.LastQueueEvalAt) or ((now - data.LastQueueEvalAt) >= 2.0)) then
		data.LastQueueEvalAt = now
		local sourceTag = emergencyOverload and "waiting-emergency" or "waiting"
		if TryRerouteCrowdedLift(data, queuePressure, sourceTag) then
			return
		end
	end

	if queuePressure >= routing.OvercrowdedPressure and waitTime >= 35 and waitingCount >= softQueueLimit then
		local interval = math.max(18, tonumber(routing.CrowdPenaltyTickSeconds) or 8)
		if not data.LastCrowdPenaltyTime or (now - data.LastCrowdPenaltyTime) >= interval then
			data.LastCrowdPenaltyTime = now
			ApplySatisfaction(data, "StuckInQueue")
		end
	end

	if waitTime > 40 then
		data.Satisfaction = math.max(0, data.Satisfaction - (GuestConfig.Satisfaction.Decay.Waiting * 0.65) * dt)
	end
	if waitTime > 80 then
		data.Satisfaction = math.max(0, data.Satisfaction - (GuestConfig.Satisfaction.Decay.WaitingLong * 0.65) * dt)
	end

	local giveUpAfter = math.max(queueBehavior.RerouteIfPredictedWaitAbove + 40, 120)
	giveUpAfter += math.min(300, math.max(0, frontDepth - 1) * 8)
	if waitTime > giveUpAfter and not isFrontOfQueue then
		if TryRerouteCrowdedLift(data, math.max(queuePressure, routing.OvercrowdedPressure), "waiting-timeout") then
			return
		end
		MarkLiftAvoidance(data, lift, math.max(tonumber(routing.AvoidLiftSeconds) or 30, 45))
		ApplySatisfaction(data, "StuckInQueue")
		local altLift = FindLiftForGuest(data, data.Root and data.Root.Position or lift:GetPivot().Position)
		if altLift and altLift ~= lift then
			ClearLiftQueueState(data)
			data.TargetLift = altLift
			data.State = STATE.WALKING_TO_LIFT
			data.WaitStartTime = nil
			data.LastQueueEvalAt = 0
			data.MoveTarget = nil
			data.MoveCallback = nil
			data.Waypoints = nil
			data.NextLiftRerouteAt = now + math.max(3, (tonumber(queueBehavior.RerouteCooldownSeconds) or 15) * 0.5)
			local startPos = GetLiftStartPos(altLift)
			MoveGuestTo(data, startPos, function()
				EnterLiftQueue(data)
			end)
			ShowSpeech(data.Model, "This line is too long. Trying another lift.", 3)
			return
		end
		ClearLiftQueueState(data)
		data.State = STATE.DECIDING
		data.TargetLift = nil
		data.WaitStartTime = nil
		ShowSpeech(data.Model, "This line is too long. I'll try another lift.", 3)
		return
	end

	local uuid = lift:GetAttribute("UUID") or ""
	local parsed = ParsedLiftData[uuid] or ParseLiftCache(uuid)
	local seatCount = parsed and GetSeatCountForLift(parsed.ConfigName) or 2

	-- Allow a small boarding pack at the front of the line so multi-seat chairs fill.
	local maxBoardingDepth = math.max(4, seatCount + 1)
	if not isFrontOfQueue and frontDepth > maxBoardingDepth then
		return
	end

	local frontStuckTime = now - (data.FrontOfQueueSince or now)
	if not data.FrontOfQueueSince then
		data.FrontOfQueueSince = now
		frontStuckTime = 0
	end
	if distToSlot and distToSlot > LIFT_QUEUE_FRONT_HOLD_RADIUS then
		if frontStuckTime > 3 and slotTarget then
			local correctionTarget = ResolveWalkableGroundPos(slotTarget, nil, false)
			MoveGuestTo(data, correctionTarget, nil)
			data.LastQueueMoveIssuedAt = now - 0.05
			if data.Root then
				data.Root.AssemblyLinearVelocity = Vector3.zero
			end
		end
	end

	local loadHerePos = select(1, GetLiftQueueLinePose(lift)) or GetLiftStartPos(lift)
	local boardAnchor = loadHerePos or slotTarget or (data.Root and data.Root.Position) or GetLiftStartPos(lift)
	local baseRange = queueBehavior.BoardingDistance or LIFT_QUEUE_BOARD_DISTANCE

	-- Measure boarding against the shared load point, not each guest's personal slot.
	-- That lets the first few queue spots claim different seats on the same incoming chair.
	local boardingRange = baseRange + (math.max(0, maxBoardingDepth - 1) * LIFT_QUEUE_SLOT_SPACING * 1.15)

	local chairId, seatIdx = FindBoardableChair(lift, boardAnchor, boardingRange)
	if not chairId and waitTime > (queueBehavior.BoardingExtendedDelaySeconds or LIFT_QUEUE_BOARD_EXTENDED_DELAY_SECONDS) then
		local baseExtended = queueBehavior.BoardingExtendedDistance or LIFT_QUEUE_BOARD_EXTENDED_DISTANCE
		local extendedRange = math.max(boardingRange + 6, baseExtended + (math.max(0, maxBoardingDepth - 1) * LIFT_QUEUE_SLOT_SPACING * 1.15))
		chairId, seatIdx = FindBoardableChairExtended(lift, boardAnchor, extendedRange)
	end
	if not chairId or not seatIdx then
		return
	end

	data.FrontOfQueueSince = nil

	local uuid = lift:GetAttribute("UUID") or ""
	if IsSeatCurrentlyTaken(uuid, chairId, seatIdx) then
		return
	end
	local occupyKey = uuid .. "_" .. chairId .. "_" .. seatIdx
	OccupiedChairs[occupyKey] = data.Model
	ClearLiftQueueState(data)
	data.MoveTarget = nil
	data.MoveCallback = nil
	data.Waypoints = nil
	data.State = STATE.RIDING_LIFT
	data.RideStartTime = tick()
	data.RideTravelTime = 0
	data.LiftChairId = chairId
	data.LiftSeatIdx = seatIdx
	data.LiftUUID = uuid
	data.LastLiftUUID = uuid ~= "" and uuid or data.LastLiftUUID
	data.LastLiftUseAt = tick()
	data.HasLeftBoardingStation = false
	data.LeftBoardingRideTime = nil
	data.BoardCycleTime = nil
	data.MinDistToEndThisRide = math.huge
	data.SeenEndStationThisRide = false
	data.LastDistToEndThisRide = nil
	data._wasStationSegment = true
	data.BoardingStationTag = "Start"
	local parsed = ParsedLiftData[uuid] or ParseLiftCache(uuid)
	if parsed and parsed.TotalDuration then
		data.LastKnownLiftDuration = parsed.TotalDuration
		if parsed.CorrectedTimeSpacing then
			local masterTime = GetLiftMasterTime(uuid)
			local offset = (chairId - 1) * parsed.CorrectedTimeSpacing
			data.BoardCycleTime = (masterTime + offset) % parsed.TotalDuration
		end
	end

	local seatName = "Seat_" .. seatIdx
	data.Model:SetAttribute("RidingLift", uuid)
	data.Model:SetAttribute("RidingChair", chairId)
	data.Model:SetAttribute("RidingSeat", seatName)
	data.Humanoid.PlatformStand = true
	data.Humanoid.AutoRotate = false
	if data.Root then
		data.Root.Anchored = true
		data.Root.CanCollide = false
		data.Root.AssemblyLinearVelocity = Vector3.zero
		data.Root.AssemblyAngularVelocity = Vector3.zero
		pcall(function() data.Root:SetNetworkOwner(nil) end)
	end

	ApplySatisfaction(data, "BoardedLift")
	CheckEmployeeBonus(data, lift, "Lift")
	ShowSpeech(data.Model, PickRandom({"Going up! ⬆️", "Nice view!", "Wheee!"}), 3)
end

function ProcessRidingLift(data, dt)
	local lift = data.TargetLift
	if not lift or not lift.Parent then
		SafeEjectFromLift(data, "RideMissingLift")
		return
	end

	local wallRideTime = tick() - (data.RideStartTime or tick())
	local speedFactor = GetLiftOperationalSpeedMultiplier(lift)
	data.RideTravelTime = (data.RideTravelTime or 0) + (dt * speedFactor)
	local effectiveRideTime = math.max(data.RideTravelTime or 0, wallRideTime)

	local uuid = data.LiftUUID or lift:GetAttribute("UUID") or ""
	local parsed = ParsedLiftData[uuid] or ParseLiftCache(uuid)
	local chairId = data.LiftChairId
	if parsed and chairId and parsed.CorrectedTimeSpacing then
		data.LastKnownLiftDuration = parsed.TotalDuration
		local masterTime = GetLiftMasterTime(uuid)
		local offset = (chairId - 1) * parsed.CorrectedTimeSpacing
		local chairCycleTime = (masterTime + offset) % parsed.TotalDuration
		local chairPos, isStationSegment, stationTag, chairTangent = GetChairPosFromTime(parsed, masterTime, offset)
		if chairPos then
			local startStationPos = GetLiftStartPos(lift)
			local endStationPos = GetLiftEndPos(lift, false)
			local distToStartStation = (chairPos - startStationPos).Magnitude
			local distToEndStation = (chairPos - endStationPos).Magnitude
			local boardingDirection = GetLiftBoardingDirection(lift)
			local headingBackDown = false
			if boardingDirection and chairTangent then
				local flatTangent = Vector3.new(chairTangent.X, 0, chairTangent.Z)
				if flatTangent.Magnitude > 0.001 then
					headingBackDown = flatTangent.Unit:Dot(boardingDirection) < -0.15
				end
			end

			local leftStationDistance = IsCarpetLift(data.TargetLift) and 24 or 18
			if isStationSegment == false
				or distToStartStation >= leftStationDistance
				or (stationTag == "End" and effectiveRideTime >= 4) then
				data.HasLeftBoardingStation = true
				data.LeftBoardingRideTime = data.LeftBoardingRideTime or effectiveRideTime
			end

			if data.HasLeftBoardingStation then
				local minDistToEnd = tonumber(data.MinDistToEndThisRide) or math.huge
				data.MinDistToEndThisRide = math.min(minDistToEnd, distToEndStation)
			end

			if data.HasLeftBoardingStation and effectiveRideTime >= 6 then
				local rideProgress = effectiveRideTime
				if data.BoardCycleTime ~= nil and parsed.TotalDuration and parsed.TotalDuration > 0 then
					rideProgress = (chairCycleTime - data.BoardCycleTime) % parsed.TotalDuration
				end

				local totalDuration = parsed.TotalDuration or 60
				local minRideBeforeUnload = math.max(6, totalDuration * 0.22)
				local confirmedEndStation = stationTag == "End"
				local unloadRadius = IsCarpetLift(data.TargetLift) and 16 or 20
				local nearUnloadZone = distToEndStation <= unloadRadius and (distToEndStation < distToStartStation or data.SeenEndStationThisRide == true)
				local broadUnloadZone = distToEndStation <= math.max(32, unloadRadius + 12)
				local minEndDist = data.MinDistToEndThisRide or math.huge
				local reachedTightEndProximity = minEndDist <= math.max(unloadRadius - 4, 10)
				if confirmedEndStation or nearUnloadZone or reachedTightEndProximity then
					data.SeenEndStationThisRide = true
				end
				local halfLoopTime = totalDuration * 0.5
				local halfLoopWindow = math.max(5, totalDuration * 0.14)
				local nearExpectedTop = rideProgress >= math.max(minRideBeforeUnload, halfLoopTime - halfLoopWindow)
				local broadTopFallback = nearExpectedTop and broadUnloadZone and distToEndStation < distToStartStation and (data.SeenEndStationThisRide == true or reachedTightEndProximity)
				local passedClosestTopApproach = reachedTightEndProximity and distToEndStation >= (minEndDist + 2)
				local missedTopAndCameBack = stationTag == "Start" and rideProgress >= math.max(16, totalDuration * 0.72)
				local startedReturnTrip = headingBackDown and minEndDist <= math.max(14, unloadRadius + 2) and distToEndStation <= math.max(32, minEndDist + 20)
				local headingBackDownAfterTop = headingBackDown and data.SeenEndStationThisRide == true
				local overshotUnloadZone = data.SeenEndStationThisRide == true and distToEndStation >= (minEndDist + 4)

				if rideProgress >= minRideBeforeUnload then
					if confirmedEndStation or nearUnloadZone or headingBackDownAfterTop or broadTopFallback then
						SafeEjectFromLift(data, "RideConfirmedEnd")
						return
					end

					if passedClosestTopApproach and distToEndStation <= 48 then
						SafeEjectFromLift(data, "RideClosestApproach")
						return
					end

					if overshotUnloadZone or missedTopAndCameBack or startedReturnTrip then
						SafeEjectFromLift(data, "RideOvershoot")
						return
					end
				end

				data.LastDistToEndThisRide = distToEndStation
			end
		end
	elseif data.LastKnownLiftDuration and effectiveRideTime >= math.clamp(data.LastKnownLiftDuration * 0.85, 25, 150) then
		SafeEjectFromLift(data, "RideDuration")
		return
	end

	if data.Root then
		data.Root.AssemblyLinearVelocity = Vector3.zero
		data.Root.AssemblyAngularVelocity = Vector3.zero
	end

	local loopDuration = (parsed and parsed.TotalDuration) or data.LastKnownLiftDuration or 120
	-- PATCHED: was 1.10 which caused premature ejection on slow/curved lifts
	local maxRideTime = math.clamp(loopDuration * 1.45, 45, 240)
	if effectiveRideTime > maxRideTime then
		SafeEjectFromLift(data, "RideHardTimeout")
	end
end

function SafeEjectFromLift(data, contextTag)
	local ok, err = pcall(EjectFromLift, data)
	if ok then
		return true
	end

	warn(string.format("[GuestServer] EjectFromLift error (%s): %s", tostring(contextTag or "unknown"), tostring(err)))
	if not data then
		return false
	end
	if data.Model and data.Model.Parent then
		data.Model:SetAttribute("EjectError", tostring(err))
	end

	local now = tick()
	if data.Root then
		data.Root.CanCollide = true
		data.Root.Anchored = false
		data.Root.AssemblyLinearVelocity = Vector3.zero
		data.Root.AssemblyAngularVelocity = Vector3.zero
	end
	if data.Humanoid then
		data.Humanoid.PlatformStand = false
		data.Humanoid.AutoRotate = true
	end

	data.TargetLift = nil
	data.TargetSlope = nil
	data.TargetSlopeEntryIndex = nil
	data.UnloadStartedAt = now
	data.UnloadTimer = 0
	data.RecentlyUnloadedAt = now
	data.PostUnloadSkiRequired = true
	data.PostUnloadSkiStartedAt = now
	data.PostUnloadSkiNextRetryAt = now + 0.1
	data.PostUnloadSkiAttempts = tonumber(data.PostUnloadSkiAttempts) or 0
	data.WantsBreak = false
	data.State = STATE.UNLOADING_LIFT

	if StartSyntheticPostUnloadSki(data, "SafeEjectFallback") then
		return true
	end
	data.State = STATE.DECIDING
	return false
end

function EjectFromLift(data)
	local previousChairId = data.LiftChairId
	local previousSeatIdx = data.LiftSeatIdx
	local root = data.Root
	local currentPos = root and root.Position or Vector3.zero
	local currentLook = root and root.CFrame.LookVector or Vector3.zAxis

	-- Clear occupied seat slot
	if data.LiftUUID and data.LiftChairId and data.LiftSeatIdx then
		local occupyKey = data.LiftUUID .. "_" .. data.LiftChairId .. "_" .. data.LiftSeatIdx
		if OccupiedChairs[occupyKey] == data.Model then
			OccupiedChairs[occupyKey] = nil
		end
	end

	-- Clear riding attributes (client stops snapping)
	data.Model:SetAttribute("RidingLift", nil)
	data.Model:SetAttribute("RidingChair", nil)
	data.Model:SetAttribute("RidingSeat", nil)

	-- Restore humanoid — CRITICAL FIX: re-enable collision after ride
	data.Humanoid.PlatformStand = false
	data.Humanoid.AutoRotate = true
	if data.Root then
		data.Root.CanCollide = true
		data.Root.Anchored = false
		ApplyWalkerNetworkOwnership(data.Root)
	end

	data.LiftChairId = nil
	data.LiftSeatIdx = nil
	data.LiftUUID = nil
	data.LastKnownLiftDuration = nil
	data.RideStartTime = nil
	data.RideTravelTime = nil
	data.HasLeftBoardingStation = nil
	data.LeftBoardingRideTime = nil
	data.BoardCycleTime = nil
	data.MinDistToEndThisRide = nil
	data.SeenEndStationThisRide = nil
	data.LastDistToEndThisRide = nil
	data.BoardingStationTag = nil
	data._wasStationSegment = nil
	ClearGuestMoveCommandState(data)

	-- Position at end station on ground
	local lift = data.TargetLift
	if lift and lift.Parent then
		local endPos = GetLiftEndPos(lift, true)
		local isCarpetLift = IsCarpetLift(lift)
		local exitOffset = Vector3.new(0, 0, isCarpetLift and 10 or 6)
		local endStation = lift:FindFirstChild("EndStation")
		local lookVector = Vector3.new(0, 0, 1)
		local rightVector = Vector3.new(1, 0, 0)
		if endStation then
			lookVector = endStation:GetPivot().LookVector
			rightVector = endStation:GetPivot().RightVector
			local lateralSpread = 0
			if previousChairId then
				lateralSpread += ((previousChairId % 7) - 3) * 2.2
			end
			if previousSeatIdx then
				lateralSpread += (previousSeatIdx - 1.5) * 1.6
			end
			if math.abs(lateralSpread) < 0.1 then
				lateralSpread = (math.random() - 0.5) * (isCarpetLift and 3.5 or 6)
			end
			local forwardPush = isCarpetLift and (10 + math.random() * 4) or (6 + math.random() * 3)
			exitOffset = (lookVector * forwardPush) + (rightVector * lateralSpread)
		end
		data.SkiSmoothedDir = endStation and lookVector or data.Root.CFrame.LookVector

		local groundExtras = nil
		if not isCarpetLift then
			groundExtras = {}
			if endStation then table.insert(groundExtras, endStation) end
			if lift then table.insert(groundExtras, lift) end
		end
		local exitPos = endPos + exitOffset
		local groundPos = ResolveWalkableGroundPos(exitPos, groundExtras, false)

		local terrainY = GetTerrainY(exitPos.X, exitPos.Z)
		if groundPos.Y < terrainY + 2 then
			groundPos = Vector3.new(groundPos.X, terrainY + 3.5, groundPos.Z)
		elseif isCarpetLift and groundPos.Y > terrainY + 5.5 then
			groundPos = Vector3.new(groundPos.X, terrainY + 3.5, groundPos.Z)
		end

		-- Keep guests from landing inside the terminal shell or too close to the chair.
		local stationBoxCF, stationBoxSize = endStation and endStation:GetBoundingBox()
		if stationBoxCF and stationBoxSize then
			local localPos = stationBoxCF:PointToObjectSpace(groundPos)
			local halfX = (stationBoxSize.X * 0.5) + 2
			local halfZ = (stationBoxSize.Z * 0.5) + 2
			local halfY = (stationBoxSize.Y * 0.5) + 8
			if math.abs(localPos.X) <= halfX and math.abs(localPos.Z) <= halfZ and math.abs(localPos.Y) <= halfY then
				local escapeDir = GetSafeFlatDirection(exitPos - stationBoxCF.Position, rightVector)
				local pushedExit = exitPos + (escapeDir * (isCarpetLift and 16 or 12))
				local pushedGround = ResolveWalkableGroundPos(pushedExit, groundExtras, false)
				local pushedLocal = stationBoxCF:PointToObjectSpace(pushedGround)
				if math.abs(pushedLocal.X) <= halfX and math.abs(pushedLocal.Z) <= halfZ and math.abs(pushedLocal.Y) <= halfY then
					groundPos = GetGroundPos(pushedExit)
				else
					groundPos = pushedGround
				end
			end
		elseif FlatDist(groundPos, currentPos) < 4 then
			local pushedExit = currentPos + (GetSafeFlatDirection(currentLook, Vector3.new(0, 0, 1)) * 16)
			local pushedGround = ResolveWalkableGroundPos(pushedExit, nil, false)
			if FlatDist(pushedGround, currentPos) < 4 then
				groundPos = GetGroundPos(pushedExit)
			else
				groundPos = pushedGround
			end
		end

		local forward = GetSafeFlatDirection(data.SkiSmoothedDir, currentLook)
		if root then
			root.CFrame = CFrame.lookAt(groundPos, groundPos + forward)
			root.AssemblyLinearVelocity = Vector3.zero
			root.AssemblyAngularVelocity = Vector3.zero
			root.Anchored = false
		end
		data.Humanoid.PlatformStand = false
		data.Humanoid.AutoRotate = true
	end

	local unloadNow = tick()
	data.State = STATE.UNLOADING_LIFT
	data.UnloadTimer = 0
	data.UnloadStartedAt = unloadNow
	data.RecentlyUnloadedAt = unloadNow
	-- Prime post-unload ski enforcement immediately so guests cannot chain back to lifts.
	data.PostUnloadSkiRequired = true
	data.PostUnloadSkiStartedAt = unloadNow
	data.PostUnloadSkiNextRetryAt = unloadNow + 0.2
	data.PostUnloadSkiAttempts = 0
	data.PostUnloadSkiStartIndex = nil
	data.PostUnloadSkiLastAttemptAt = nil
	data.PostUnloadSkiStartPos = data.Root and data.Root.Position or nil

	if not IsSummerSeason() then
		local guestPos = (data.Root and data.Root.Position) or currentPos
		local immediateSlope = nil
		local immediatePath = nil
		local immediateEntryIndex = nil
		local immediateEntryPos = nil

		local lift = data.TargetLift
		if lift and lift.Parent then
			local servedSlopes = select(1, GetLiftServedSlopes(lift))
			if servedSlopes and #servedSlopes > 0 then
				local servedSlope, servedEntryIndex = SelectClosestSlopeByEntry(servedSlopes, guestPos, 240, 24, data)
				if not servedSlope then
					servedSlope, servedEntryIndex = SelectClosestSlopeByEntry(servedSlopes, guestPos, math.huge, 8, data)
				end
				if servedSlope and servedEntryIndex then
					local servedPath = GetSlopeData(servedSlope)
					if servedPath and #servedPath > 1 then
						immediateSlope = servedSlope
						immediatePath = servedPath
						immediateEntryIndex = math.clamp(tonumber(servedEntryIndex) or 1, 1, math.max(1, #servedPath - 2))
						immediateEntryPos = GetSlopeEntryPosition(servedPath, immediateEntryIndex) or GetGroundPos(servedPath[immediateEntryIndex] or servedPath[1])
					end
				end
			end
		end

		if not immediateSlope then
			immediateSlope = FindSlopeForGuest(data, guestPos)
				or FindAnySlopeForGuest(data, guestPos)
				or FindEmergencySlopeForGuest(data, guestPos)
			immediatePath = immediateSlope and GetSlopeData(immediateSlope) or nil
			if immediatePath and #immediatePath > 1 then
				immediateEntryIndex = select(1, SelectSkiEntryIndex(immediatePath, guestPos, 70, 26))
					or math.clamp((tonumber(GetNearestSlopeEntryIndex(immediatePath, guestPos, math.huge)) or 1), 1, math.max(1, #immediatePath - 2))
				immediateEntryPos = GetSlopeEntryPosition(immediatePath, immediateEntryIndex) or GetGroundPos(immediatePath[immediateEntryIndex] or immediatePath[1])
			end
		end

		-- Emergency fallback: bypass avoidance and pick the nearest truly skiable slope.
		if not immediateEntryPos then
			local slopePool = FindBuildingsByType("Slope", data.OwnerId)
			if #slopePool == 0 then
				slopePool = FindBuildingsByType("Slope")
			end
			local bestSlope = nil
			local bestPath = nil
			local bestEntryIndex = nil
			local bestEntryPos = nil
			local bestDist = math.huge
			for _, candidate in ipairs(slopePool) do
				local candidatePath = GetSlopeData(candidate)
				if candidatePath and #candidatePath > 1 then
					local candidateEntryIndex = select(1, SelectSkiEntryIndex(candidatePath, guestPos, math.huge, 6))
						or math.clamp((tonumber(GetNearestSlopeEntryIndex(candidatePath, guestPos, math.huge)) or 1), 1, math.max(1, #candidatePath - 2))
					local candidateEntryPos = GetSlopeEntryPosition(candidatePath, candidateEntryIndex) or GetGroundPos(candidatePath[candidateEntryIndex] or candidatePath[1])
					local dist = FlatDist(guestPos, candidateEntryPos)
					if dist < bestDist then
						bestDist = dist
						bestSlope = candidate
						bestPath = candidatePath
						bestEntryIndex = candidateEntryIndex
						bestEntryPos = candidateEntryPos
					end
				end
			end
			immediateSlope = bestSlope
			immediatePath = bestPath
			immediateEntryIndex = bestEntryIndex
			immediateEntryPos = bestEntryPos
		end

		if immediateSlope and immediatePath and immediateEntryPos then
			EnsureGuestWalkingPhysics(data, immediateEntryPos, nil)
			data.TargetLift = nil
			data.WantsBreak = false
			data.PostUnloadSkiAttempts = 1
			data.PostUnloadSkiStartIndex = immediateEntryIndex
			data.PostUnloadSkiLastAttemptAt = unloadNow
			data.PostUnloadSkiStartPos = immediateEntryPos
			if TryStartSkiingDown(data, immediateSlope, { EntryIndex = immediateEntryIndex }, "EjectImmediate") then
				return
			end

			data.TargetSlope = immediateSlope
			data.TargetSlopeEntryIndex = immediateEntryIndex
			data.State = STATE.SKIING_TO_SLOPE
			MoveGuestTo(data, immediateEntryPos, function(guestData)
				if not TryStartSkiingDown(guestData, immediateSlope, { EntryIndex = immediateEntryIndex }, "EjectImmediateWalk") then
					MarkSlopeAvoidance(guestData, immediateSlope, 20)
					guestData.PostUnloadSkiNextRetryAt = tick() + 0.35
					guestData.State = STATE.DECIDING
					if guestData.TargetSlope == immediateSlope then
						guestData.TargetSlope = nil
					end
					guestData.TargetSlopeEntryIndex = nil
				end
			end)
			return
		end

		-- Last-resort fallback: force the longest available slope so guests always ski after unloading.
		local slopePool = FindBuildingsByType("Slope", data.OwnerId)
		if #slopePool == 0 then
			slopePool = FindBuildingsByType("Slope")
		end
		local longestSlope = nil
		local longestPath = nil
		local longestPoints = 0
		for _, candidate in ipairs(slopePool) do
			local points = tonumber(candidate:GetAttribute("PathPointCount")) or 0
			if points >= longestPoints then
				local candidatePath = GetSlopeData(candidate)
				if candidatePath and #candidatePath > 1 then
					longestSlope = candidate
					longestPath = candidatePath
					longestPoints = points
				end
			end
		end
		if longestSlope and longestPath then
			local longestEntryIndex = select(1, SelectSkiEntryIndex(longestPath, guestPos, math.huge, 2))
				or math.clamp((tonumber(GetNearestSlopeEntryIndex(longestPath, guestPos, math.huge)) or 1), 1, math.max(1, #longestPath - 2))
			local longestEntryPos = GetSlopeEntryPosition(longestPath, longestEntryIndex) or GetGroundPos(longestPath[longestEntryIndex] or longestPath[1])
			EnsureGuestWalkingPhysics(data, longestEntryPos, nil)
			data.TargetLift = nil
			data.WantsBreak = false
			data.PostUnloadSkiAttempts = math.max(1, (tonumber(data.PostUnloadSkiAttempts) or 0) + 1)
			data.PostUnloadSkiStartIndex = longestEntryIndex
			data.PostUnloadSkiLastAttemptAt = unloadNow
			data.PostUnloadSkiStartPos = longestEntryPos
			if TryStartSkiingDown(data, longestSlope, { EntryIndex = longestEntryIndex }, "EjectLongestSlopeFallback") then
				return
			end

			data.TargetSlope = longestSlope
			data.TargetSlopeEntryIndex = longestEntryIndex
			data.State = STATE.SKIING_TO_SLOPE
			MoveGuestTo(data, longestEntryPos, function(guestData)
				if not TryStartSkiingDown(guestData, longestSlope, { EntryIndex = longestEntryIndex }, "EjectLongestSlopeWalk") then
					MarkSlopeAvoidance(guestData, longestSlope, 20)
					guestData.PostUnloadSkiNextRetryAt = tick() + 0.35
					guestData.State = STATE.DECIDING
					if guestData.TargetSlope == longestSlope then
						guestData.TargetSlope = nil
					end
					guestData.TargetSlopeEntryIndex = nil
				end
			end)
			return
		end

		if StartSyntheticPostUnloadSki(data, "EjectSyntheticFallback") then
			return
		end
	end

	if IsSummerSeason() then
		ShowSpeech(data.Model, PickRandom({"Nice ride!", "Beautiful day!", "Let's take a break."}), 2)
	else
		ShowSpeech(data.Model, PickRandom({"Time to ski!", "Let's go!", "Top of the mountain! 🏔️"}), 2)
	end
end

function ProcessUnloadingLift(data, dt)
	local now = tick()
	data.UnloadStartedAt = data.UnloadStartedAt or now
	local dtTimer = (data.UnloadTimer or 0) + dt
	local wallTimer = now - data.UnloadStartedAt
	data.UnloadTimer = math.max(dtTimer, wallTimer)

	local unloadTimeout = IsCarpetLift(data.TargetLift) and 5.5 or 8.5
	if data.UnloadTimer > unloadTimeout then
		if data.TargetLift and data.TargetLift.Parent then
			MarkLiftAvoidance(data, data.TargetLift, 45)
		end
		if data.Root and data.Root.Parent then
			local safePos = ResolveWalkableGroundPos(data.Root.Position + Vector3.new(0, 2, 0), nil, false)
			NormalizeGuestUpright(data, safePos)
		end
		data.TargetLift = nil
		data.TargetSlope = nil
		data.TargetSlopeEntryIndex = nil
		data.SlopeWalkFailureCount = 0
		data.PostUnloadSkiRequired = true
		data.PostUnloadSkiStartedAt = now
		data.PostUnloadSkiNextRetryAt = now + 0.1
		data.PostUnloadSkiAttempts = tonumber(data.PostUnloadSkiAttempts) or 0
		data.PostUnloadSkiStartIndex = nil
		data.PostUnloadSkiLastAttemptAt = nil
		data.PostUnloadSkiStartPos = data.Root and data.Root.Position or nil
		data.WantsBreak = false
		data.State = STATE.DECIDING
		data.UnloadTimer = 0
		data.UnloadStartedAt = nil
		return
	end

	-- PATCHED: was 1.5, reduced for faster post-unload flow.
	if data.UnloadTimer > 0.3 then
		if IsSummerSeason() then
			data.TargetLift = nil
			data.WantsBreak = true
			data.State = STATE.DECIDING
			data.UnloadTimer = 0
			data.UnloadStartedAt = nil
			return
		end

		if data.PostUnloadSkiRequired ~= true then
			data.PostUnloadSkiRequired = true
			data.PostUnloadSkiStartedAt = now
			data.PostUnloadSkiAttempts = 0
			data.PostUnloadSkiNextRetryAt = nil
			data.PostUnloadSkiStartIndex = nil
			data.PostUnloadSkiLastAttemptAt = nil
			data.PostUnloadSkiStartPos = data.Root and data.Root.Position or nil
		end

		local lift = data.TargetLift
		local slope = nil
		local slopeEntryIndex = nil
		local slopeEntryFlatDist = nil
		local debugMsg = ""

		if lift and lift.Parent then
			local servedSlopes, servedDiffs = GetLiftServedSlopes(lift)

			-- Debug: show what difficulties the lift serves
			local diffNames = { [1] = "G", [2] = "B", [3] = "Bk", [4] = "DB" }
			local diffStr = ""
			if servedDiffs then
				for d in pairs(servedDiffs) do diffStr = diffStr .. (diffNames[d] or "?") .. "," end
			end
			debugMsg = lift.Name .. " served=" .. #servedSlopes .. " diffs=[" .. diffStr .. "]"

			if #servedSlopes > 0 then
				local allowed = GuestConfig.SlopeDifficulty.Allowed[data.Personality] or {1}
				local preferred = GuestConfig.SlopeDifficulty.Preferred[data.Personality] or {1}
				local diffToNum = { Green = 1, Blue = 2, Black = 3, ["Double Black"] = 4, DoubleBlack = 4, ["Triple Black"] = 5, TripleBlack = 5, Glade = 6 }
				local allowedSet = {}
				for _, a in ipairs(allowed) do allowedSet[a] = true end
				local preferredSet = {}
				for _, p in ipairs(preferred) do preferredSet[p] = true end

				local preferredSlopes = {}
				local allowedSlopes = {}

				for _, s in ipairs(servedSlopes) do
					local slopePath, diff = GetSlopeData(s)
					-- Skip lift-served entries that are not actually skiable paths.
					if slopePath and #slopePath > 1 then
						local diffNum = type(diff) == "number" and diff or (diffToNum[tostring(diff)] or 1)
						if preferredSet[diffNum] then
							table.insert(preferredSlopes, s)
						end
						-- Check allowed SEPARATELY (not elseif) — a slope can be both
						if allowedSet[diffNum] then
							table.insert(allowedSlopes, s)
						end
					end
				end

				local pool = #preferredSlopes > 0 and preferredSlopes 
					or #allowedSlopes > 0 and allowedSlopes 
					or servedSlopes

				debugMsg = debugMsg .. " pref=" .. #preferredSlopes .. " allow=" .. #allowedSlopes .. " pool=" .. #pool

				local pos = data.Root.Position
				local nearbySlope, nearbyEntryIndex, nearbyFlatDist = SelectClosestSlopeByEntry(pool, pos, 180, 24, data)
				if nearbySlope then
					slope = nearbySlope
					slopeEntryIndex = nearbyEntryIndex
					slopeEntryFlatDist = nearbyFlatDist
				else
					local fallbackSlope, fallbackEntryIndex, fallbackFlatDist = SelectClosestSlopeByEntry(pool, pos, math.huge, 8, data)
					if fallbackSlope then
						slope = fallbackSlope
						slopeEntryIndex = fallbackEntryIndex
						slopeEntryFlatDist = fallbackFlatDist
					end
				end

				if slope then
					local _, sd = GetSlopeData(slope)
					debugMsg = debugMsg .. " → " .. slope.Name .. "(d=" .. tostring(sd) .. ", walk=" .. tostring(math.floor((slopeEntryFlatDist or 0) + 0.5)) .. ")"
				else
					debugMsg = debugMsg .. " NO_CLOSE_POOL_SLOPE"
				end
			end
		else
			debugMsg = "NO_LIFT_REF"
		end

		-- Fallback: aggressively force a skiable slope before looping guests back into lift decisions.
		if not slope then
			local guestPos = data.Root and data.Root.Position or (lift and lift:GetPivot().Position) or Vector3.zero
			local fallbackSlope = FindSlopeForGuest(data, guestPos)
			if not fallbackSlope then
				fallbackSlope = FindAnySlopeForGuest(data, guestPos)
			end
			if not fallbackSlope then
				fallbackSlope = FindEmergencySlopeForGuest(data, guestPos)
			end
			if fallbackSlope then
				local fallbackPath, diff = GetSlopeData(fallbackSlope)
				local fallbackEntryIndex, _, fallbackFlatDist = GetReachableSlopeEntry(fallbackPath or {}, guestPos, math.huge, 8)
				if fallbackEntryIndex then
					slope = fallbackSlope
					slopeEntryIndex = fallbackEntryIndex
					slopeEntryFlatDist = fallbackFlatDist
					debugMsg = debugMsg .. " FALLBACK→" .. slope.Name .. "(d=" .. tostring(diff) .. ", walk=" .. tostring(math.floor((fallbackFlatDist or 0) + 0.5)) .. ")"
				elseif fallbackPath and #fallbackPath > 1 then
					slope = fallbackSlope
					slopeEntryIndex = math.clamp(GetNearestSlopeEntryIndex(fallbackPath, guestPos, math.huge) or 1, 1, #fallbackPath - 1)
					slopeEntryFlatDist = FlatDist(guestPos, fallbackPath[slopeEntryIndex] or guestPos)
					debugMsg = debugMsg .. " FALLBACK_NEAREST_ENTRY"
				end
			end

			if not slope then
				local slopePool = FindBuildingsByType("Slope", data.OwnerId)
				if #slopePool == 0 then
					slopePool = FindBuildingsByType("Slope")
				end
				if #slopePool > 0 then
					local emergencySlope, emergencyEntryIndex, emergencyFlatDist = SelectClosestSlopeByEntry(slopePool, guestPos, math.huge, 8, data)
					if emergencySlope and emergencyEntryIndex then
						slope = emergencySlope
						slopeEntryIndex = emergencyEntryIndex
						slopeEntryFlatDist = emergencyFlatDist
						debugMsg = debugMsg .. " EMERGENCY_SLOPE→" .. slope.Name
					end
				end
			end

			if not slope then
				debugMsg = debugMsg .. " NO_SLOPE_FOUND"
			end
		end


		local transferLift = nil
		if lift and lift.Parent and ShouldAttemptPostUnloadTransfer(data, lift, slope) then
			transferLift = FindPostUnloadTransferLift(data, lift)
		end
		if transferLift then
			local transferStart = GetLiftStartPos(transferLift)
			NormalizeGuestUpright(data, transferStart)
			ClearLiftQueueState(data)
			ClearLiftCommitment(data)
			data.TargetSlope = nil
			data.TargetSlopeEntryIndex = nil
			data.SlopeWalkFailureCount = 0
			data.PostUnloadSkiRequired = nil
			data.PostUnloadSkiStartedAt = nil
			data.PostUnloadSkiNextRetryAt = nil
			data.PostUnloadSkiAttempts = nil
			data.PostUnloadSkiStartIndex = nil
			data.PostUnloadSkiLastAttemptAt = nil
			data.PostUnloadSkiStartPos = nil
			data.PostUnloadTransferCount = (tonumber(data.PostUnloadTransferCount) or 0) + 1
			data.WantsBreak = false
			data.UnloadTimer = 0
			data.UnloadStartedAt = nil
			data.TargetLift = transferLift
			CommitGuestToLift(data, transferLift, 16)
			data.State = STATE.WALKING_TO_LIFT
			MoveGuestTo(data, transferStart, function(guestData)
				EnterLiftQueue(guestData)
			end)
			return
		end

		if slope then
			data.PostUnloadTransferCount = 0
			local guestPos = (data.Root and data.Root.Position) or (lift and lift:GetPivot().Position) or Vector3.zero
			local path = GetSlopeData(slope)
			if path and #path > 1 then
				local entryIndex, resolvedEntryFlatDist = SelectSkiEntryIndex(path, guestPos, 70, 26)
				entryIndex = entryIndex or math.clamp(tonumber(slopeEntryIndex) or 1, 1, math.max(1, #path - 2))
				slopeEntryFlatDist = resolvedEntryFlatDist or slopeEntryFlatDist
				local entryPos = GetSlopeEntryPosition(path, entryIndex) or GetGroundPos(path[entryIndex] or path[1])

				-- Hard rule: after unloading, commit to a real ski run first (no immediate lift-to-lift chaining).
				NormalizeGuestUpright(data, entryPos)
				data.PostUnloadSkiRequired = true
				data.PostUnloadSkiStartedAt = now
				data.PostUnloadSkiNextRetryAt = nil
				data.PostUnloadSkiAttempts = (tonumber(data.PostUnloadSkiAttempts) or 0) + 1
				data.PostUnloadSkiStartIndex = entryIndex
				data.PostUnloadSkiLastAttemptAt = now
				data.PostUnloadSkiStartPos = entryPos
				if lift and lift.Parent then
					MarkLiftAvoidance(data, lift, 45)
				end
				data.UnloadTimer = 0
				data.UnloadStartedAt = nil
				if not TryStartSkiingDown(data, slope, { EntryIndex = entryIndex }, "UnloadingLiftPrimary") then
					EnsureGuestWalkingPhysics(data, entryPos, nil)
					data.TargetLift = nil
					data.TargetSlope = slope
					data.TargetSlopeEntryIndex = entryIndex
					data.WantsBreak = false
					data.PostUnloadSkiNextRetryAt = now + 0.45
					data.State = STATE.SKIING_TO_SLOPE
					MoveGuestTo(data, entryPos, function(guestData)
						if not TryStartSkiingDown(guestData, slope, { EntryIndex = entryIndex }, "UnloadingLiftPrimaryWalk") then
							MarkSlopeAvoidance(guestData, slope, 20)
							guestData.PostUnloadSkiNextRetryAt = tick() + 0.35
							guestData.State = STATE.DECIDING
							if guestData.TargetSlope == slope then
								guestData.TargetSlope = nil
							end
							guestData.TargetSlopeEntryIndex = nil
						end
					end)
				end
				return
			end
		end

		local guestPos = (data.Root and data.Root.Position) or Vector3.zero
		local globalSlopePool = FindBuildingsByType("Slope", data.OwnerId)
		if #globalSlopePool == 0 then
			globalSlopePool = FindBuildingsByType("Slope")
		end
		if #globalSlopePool == 0 then
			local placedObjects = Workspace:FindFirstChild("PlacedObjects")
			if placedObjects then
				for _, inst in ipairs(placedObjects:GetDescendants()) do
					if inst:IsA("Model") and tostring(inst:GetAttribute("Type") or "") == "Slope" then
						table.insert(globalSlopePool, inst)
					end
				end
			end
		end
		local fallbackSlope, fallbackEntryIndex = SelectClosestSlopeByEntry(globalSlopePool, guestPos, math.huge, 8, data)
		if (not fallbackSlope or not fallbackEntryIndex) and #globalSlopePool > 0 then
			for _, candidateSlope in ipairs(globalSlopePool) do
				local candidatePath = GetSlopeData(candidateSlope)
				if candidatePath and #candidatePath > 1 then
					fallbackSlope = candidateSlope
					fallbackEntryIndex = math.clamp((GetNearestSlopeEntryIndex(candidatePath, guestPos, math.huge) or 1), 1, math.max(1, #candidatePath - 2))
					break
				end
			end
		end
		if fallbackSlope and fallbackEntryIndex then
			local fallbackPath = GetSlopeData(fallbackSlope)
			if fallbackPath and #fallbackPath > 1 then
				local entryIndex = select(1, SelectSkiEntryIndex(fallbackPath, guestPos, 55, 20))
					or math.clamp((tonumber(fallbackEntryIndex) or 1), 1, math.max(1, #fallbackPath - 2))
				local entryPos = GetSlopeEntryPosition(fallbackPath, entryIndex) or GetGroundPos(fallbackPath[entryIndex] or fallbackPath[1])
				NormalizeGuestUpright(data, entryPos)
				data.PostUnloadSkiRequired = true
				data.PostUnloadSkiStartedAt = now
				data.PostUnloadSkiNextRetryAt = now + 0.45
				data.PostUnloadSkiAttempts = (tonumber(data.PostUnloadSkiAttempts) or 0) + 1
				data.PostUnloadSkiStartIndex = entryIndex
				data.PostUnloadSkiLastAttemptAt = now
				data.PostUnloadSkiStartPos = entryPos
				data.TargetLift = nil
				data.TargetSlope = fallbackSlope
				data.TargetSlopeEntryIndex = entryIndex
				data.WantsBreak = false
				data.UnloadTimer = 0
				data.UnloadStartedAt = nil
				data.State = STATE.SKIING_TO_SLOPE
				MoveGuestTo(data, entryPos, function(guestData)
					if not TryStartSkiingDown(guestData, fallbackSlope, { EntryIndex = entryIndex }, "UnloadingLiftGlobalFallbackWalk") then
						MarkSlopeAvoidance(guestData, fallbackSlope, 20)
						guestData.PostUnloadSkiNextRetryAt = tick() + 0.35
						guestData.State = STATE.DECIDING
						if guestData.TargetSlope == fallbackSlope then
							guestData.TargetSlope = nil
						end
						guestData.TargetSlopeEntryIndex = nil
					end
				end)
				return
			end
		end

		if lift and lift.Parent then
			MarkLiftAvoidance(data, lift, 75)
		end

		data.PostUnloadSkiRequired = true
		data.PostUnloadSkiStartedAt = now
		data.PostUnloadSkiNextRetryAt = now + 0.2
		data.PostUnloadSkiAttempts = tonumber(data.PostUnloadSkiAttempts) or 0
		data.PostUnloadSkiStartIndex = nil
		data.PostUnloadSkiLastAttemptAt = nil
		data.PostUnloadSkiStartPos = data.Root and data.Root.Position or nil
		if StartSyntheticPostUnloadSki(data, "UnloadingLiftNoSlope") then
			return
		end
		data.State = STATE.DECIDING
		data.TargetLift = nil
		data.TargetSlope = nil
		data.TargetSlopeEntryIndex = nil
		data.UnloadTimer = 0
		data.UnloadStartedAt = nil
	end
end

-- ============================================================================
-- NEEDS UPDATE (continuous)
-- ============================================================================
function GetNeedsAttributePushInterval(guestCount)
	if guestCount >= 2200 then return 1.65 end
	if guestCount >= 1900 then return 1.45 end
	if guestCount >= 1600 then return 1.25 end
	if guestCount >= 1300 then return 1.08 end
	if guestCount >= 1100 then return 0.88 end
	if guestCount >= 800 then return 0.65 end
	if guestCount >= 500 then return 0.5 end
	if guestCount >= 300 then return 0.35 end
	return 0.25
end

function UpdateNeeds(data, dt)
	local now = tick()
	-- Hunger decay
	local hungerRate = -0.08
	if data.State == STATE.SKIING_DOWN then hungerRate = -0.2 end
	if data.State == STATE.EATING then hungerRate = 3.0 end
	data.Hunger = math.clamp(data.Hunger + hungerRate * dt, 0, 100)

	-- Energy decay
	local energyRate = -0.05
	if data.State == STATE.SKIING_DOWN then energyRate = -0.3 end
	if data.State == STATE.RESTING or data.State == STATE.SLEEPING then energyRate = GuestConfig.Rest.EnergyRestorePerSecond end
	if data.State == STATE.EATING then energyRate = 0.5 end
	data.Energy = math.clamp(data.Energy + energyRate * dt, 0, 100)

	-- Satisfaction continuous effects
	if data.Hunger < 30 then
		data.Satisfaction = math.max(0, data.Satisfaction - GuestConfig.Satisfaction.Decay.Hungry * dt)
	end
	if data.State == STATE.SKIING_DOWN then
		local skiRecovery = GuestConfig.Satisfaction.Recovery.Skiing + GetSnowmakingSkiRecoveryBonus(data)
		data.Satisfaction = math.min(100, data.Satisfaction + skiRecovery * dt)
	end

	-- Attribute push is throttled + diff-based to cut replication cost with large crowds.
	local spawnTime = tonumber(data.SpawnTime) or now
	local firstRunGraceActive = ((data.SkiRuns or 0) <= 0) and ((now - spawnTime) <= 300)
	if firstRunGraceActive and data.State ~= STATE.LEAVING then
		data.Satisfaction = math.max(data.Satisfaction, 24)
	end

	local stateChanged = data._lastPushedState ~= data.State
	local guestCount = GetTotalGuestCount()
	local pushInterval = GetNeedsAttributePushInterval(guestCount)
	local hungerInt = math.floor(data.Hunger + 0.5)
	local energyInt = math.floor(data.Energy + 0.5)
	local satInt = math.floor(data.Satisfaction + 0.5)
	local valuesChanged = (hungerInt ~= data._lastPushedHunger)
		or (energyInt ~= data._lastPushedEnergy)
		or (satInt ~= data._lastPushedSatisfaction)

	local canPush = stateChanged
		or (valuesChanged and ((not data._lastNeedsPush) or ((now - data._lastNeedsPush) >= pushInterval)))
	if not canPush then
		return
	end

	if stateChanged then
		data.Model:SetAttribute("State", data.State)
		data._lastPushedState = data.State
	end
	if hungerInt ~= data._lastPushedHunger then
		data.Model:SetAttribute("Hunger", hungerInt)
		data._lastPushedHunger = hungerInt
	end
	if energyInt ~= data._lastPushedEnergy then
		data.Model:SetAttribute("Energy", energyInt)
		data._lastPushedEnergy = energyInt
	end
	if satInt ~= data._lastPushedSatisfaction then
		data.Model:SetAttribute("Satisfaction", satInt)
		data._lastPushedSatisfaction = satInt
	end
	data._lastNeedsPush = now
end

-- ============================================================================
-- GUEST SPAWNING
-- ============================================================================
function ShuffleList(list)
	for i = #list, 2, -1 do
		local j = math.random(1, i)
		list[i], list[j] = list[j], list[i]
	end
end

function CacheFriends(userId)
	if FriendCache[userId] then return end
	FriendCache[userId] = {userId}
	task.spawn(function()
		pcall(function()
			local cacheCfg = GetAvatarCacheConfig()
			local fetchCap = math.max(20, cacheCfg.FriendFetchCap)
			local pages = Players:GetFriendsAsync(userId)
			local ids = {}
			local seen = {}
			while true do
				for _, item in ipairs(pages:GetCurrentPage()) do
					local id = tonumber(item.Id)
					if id and not seen[id] then
						seen[id] = true
						table.insert(ids, id)
						if #ids >= fetchCap then break end
					end
				end
				if pages.IsFinished or #ids >= fetchCap then break end
				pages:AdvanceToNextPageAsync()
			end

			if not seen[userId] then
				table.insert(ids, userId)
			end
			if #ids == 0 then
				ids = {userId}
			end

			FriendCache[userId] = ids
			FriendRotationQueue[userId] = nil
			FriendRecentUsed[userId] = FriendRecentUsed[userId] or {}
			AvatarPrefetchCursor[userId] = 1
			if EnsureAvatarNameAsync then
				EnsureAvatarNameAsync(userId)
			end
		end)
	end)
end

function IsRecentlyUsedFriend(userId, candidateId)
	local recent = FriendRecentUsed[userId]
	if not recent then return false end
	for _, id in ipairs(recent) do
		if id == candidateId then
			return true
		end
	end
	return false
end

function MarkRecentlyUsedFriend(userId, pickedId)
	local recent = FriendRecentUsed[userId]
	if not recent then
		recent = {}
		FriendRecentUsed[userId] = recent
	end
	table.insert(recent, pickedId)
	-- PATCHED: was 30, now scales to friend list size to prevent repeats
	local friendCount = #(FriendCache[userId] or {})
	local maxRecent = math.max(30, math.floor(friendCount * 0.8))
	while #recent > maxRecent do
		table.remove(recent, 1)
	end
end

function BuildFriendRotationQueue(userId)
	local ids = FriendCache[userId] or {userId}
	local queue = table.clone(ids)
	if #queue == 0 then
		queue = {userId}
	end
	ShuffleList(queue)
	FriendRotationQueue[userId] = queue
	return queue
end

function GetNextFriendId(userId)
	local queue = FriendRotationQueue[userId]
	if not queue or #queue == 0 then
		queue = BuildFriendRotationQueue(userId)
	end

	local fallback = queue[1] or userId
	local attempts = #queue
	for _ = 1, attempts do
		local candidateId = table.remove(queue, 1)
		if candidateId == nil then break end
		if not IsRecentlyUsedFriend(userId, candidateId) then
			MarkRecentlyUsedFriend(userId, candidateId)
			if #queue == 0 then
				BuildFriendRotationQueue(userId)
			end
			return candidateId
		end
		table.insert(queue, candidateId)
	end

	MarkRecentlyUsedFriend(userId, fallback)
	if #queue == 0 then
		BuildFriendRotationQueue(userId)
	end
	return fallback
end

function SanitizeGuestDescription(desc)
	if not desc then return end

	pcall(function() desc.HeadScale = 1 end)
	pcall(function() desc.HeightScale = 1 end)
	pcall(function() desc.WidthScale = 1 end)
	pcall(function() desc.DepthScale = 1 end)
	pcall(function() desc.BodyTypeScale = 0 end)
	pcall(function() desc.ProportionScale = 0 end)
end

function IsAllowedGuestAccessory(accessory)
	if not accessory then return false end

	local accessoryType = nil
	pcall(function()
		accessoryType = accessory.AccessoryType
	end)
	if accessoryType == nil then
		return false
	end

	return accessoryType == Enum.AccessoryType.Shirt
		or accessoryType == Enum.AccessoryType.Pants
		or accessoryType == Enum.AccessoryType.Jacket
		or accessoryType == Enum.AccessoryType.Sweater
		or accessoryType == Enum.AccessoryType.Shorts
		or accessoryType == Enum.AccessoryType.DressSkirt
		or accessoryType == Enum.AccessoryType.Hair
		or accessoryType == Enum.AccessoryType.Face
end

function GetAccessoryPriority(accessory)
	if not accessory then return 50 end
	local accessoryType = nil
	pcall(function()
		accessoryType = accessory.AccessoryType
	end)
	local byType = {}
	local function setPriority(enumName, priority)
		local enumValue = Enum.AccessoryType[enumName]
		if enumValue then
			byType[enumValue] = priority
		end
	end
	setPriority("Shirt", 1)
	setPriority("Pants", 1)
	setPriority("Jacket", 2)
	setPriority("Sweater", 2)
	setPriority("Shorts", 2)
	setPriority("DressSkirt", 2)
	setPriority("Hair", 1)
	setPriority("Hat", 3)
	setPriority("Face", 4)
	setPriority("Neck", 5)
	setPriority("Shoulder", 6)
	setPriority("Front", 7)
	setPriority("Back", 8)
	setPriority("Waist", 9)
	return byType[accessoryType] or 20
end

function OptimizeGuestModel(model)
	GuestPhysics.OptimizeModel(model)
end

function CreateGuestModel(player, spawnPos)
	local userId = player.UserId
	local model

	local pickId = tonumber(GetNextFriendId(userId)) or userId
	local avatarCfg = GetAvatarCacheConfig()
	local desc = GetCachedDescription(pickId)
	local usedFallbackDescription = false
	if not desc then
		local backlog = tonumber(player:GetAttribute("GuestSpawnBacklog")) or 0
		local overloadedBacklog = backlog > 120
		local fallbackChance = tonumber(avatarCfg.FallbackGenericChanceWhenBacklogged) or 0.2
		if overloadedBacklog then
			fallbackChance *= 0.35
		else
			fallbackChance *= 0.08
		end
		fallbackChance = math.clamp(fallbackChance, 0.01, 0.4)
		local shouldForceFallback = math.random() < fallbackChance
		if not shouldForceFallback then
			desc = FetchAndCacheAvatarDescription(pickId)
		end
	end
	if not desc then
		desc = GetFallbackAvatarDescription()
		usedFallbackDescription = true
	end
	SanitizeGuestDescription(desc)

	local createOk, createdModel = pcall(function()
		return Players:CreateHumanoidModelFromDescriptionAsync(desc, Enum.HumanoidRigType.R6)
	end)
	if createOk and createdModel then
		model = createdModel
	else
		model = GetGenericGuestTemplateClone()
		usedFallbackDescription = true
		if not model then
			local fallbackDesc = GetFallbackAvatarDescription()
			SanitizeGuestDescription(fallbackDesc)
			local fallbackOk, fallbackModel = pcall(function()
				return Players:CreateHumanoidModelFromDescriptionAsync(fallbackDesc, Enum.HumanoidRigType.R6)
			end)
			if fallbackOk then
				model = fallbackModel
			end
		end
	end

	if not model then
		return nil
	end

	if usedFallbackDescription then
		ApplyFallbackPaletteToModel(model, pickId)
	end

	local resolvedName = GetCachedAvatarName(pickId)
	model:SetAttribute("RealName", resolvedName or ("Guest " .. tostring(pickId)))
	if EnsureAvatarNameAsync then
		EnsureAvatarNameAsync(pickId)
	end
	if not resolvedName then
		task.spawn(function()
			for _ = 1, 16 do
				task.wait(0.25)
				if not model or not model.Parent then
					return
				end
				local freshName = GetCachedAvatarName(pickId)
				if freshName then
					model:SetAttribute("RealName", freshName)
					return
				end
			end
		end)
	end

	OptimizeGuestModel(model)

	model.Name = "Guest"

	local hum = model:FindFirstChild("Humanoid")
	if hum then
		hum.WalkSpeed = 26 -- PATCHED: was 24, guests need to keep up with walkways
		hum.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
	end
	if not hum then
		return model
	end

	local groundPos = ResolveWalkableGroundPos(spawnPos, nil, false)
	model:PivotTo(CFrame.new(groundPos))
	model.Parent = GuestsFolder

	local root = model:FindFirstChild("HumanoidRootPart")
	if root then
		ApplyWalkerNetworkOwnership(root)
	end

	-- Walk animation is now client-driven from real displacement speed.

	return model
end

function SpawnGuest(player, hotel)
	local userId = player.UserId
	if hotel and not hotel.Parent then return nil end

	-- Optional per-player limit (0 = disabled)
	local currentCount = GetPlayerGuestCount(userId)
	local playerHardCap = GetPlayerGuestHardCap(player)
	if playerHardCap > 0 and currentCount >= playerHardCap then return nil end

	local dynamicRunawayCap = GetDynamicRunawayGuestCap()
	if dynamicRunawayCap > 0 and GetTotalGuestCount() >= dynamicRunawayCap then
		return nil
	end

	-- Hotel capacity check
	if hotel then
		local hotelKey = GetHotelKey(hotel)
		local hotelGuests = 0
		for _, g in ipairs(GetPlayerGuestList(userId)) do
			if g.HotelKey == hotelKey or g.HotelModel == hotel then
				hotelGuests += 1
			end
		end
		local _, baseCap = GetHotelTargetGuests(hotel)
		if hotelGuests >= baseCap then return nil end
	end

	-- Spawn position
	local spawnPos
	if hotel then
		spawnPos = ResolveHotelSpawnPos(hotel)
	else
		spawnPos = Vector3.new(1024, 200, 1024)
	end

	local model = CreateGuestModel(player, spawnPos)
	if not model then return nil end
	local guestUUID = string.format("%d_%d_%d", userId, os.time(), math.random(1000, 9999))

	-- Pick personality
	local personalityName, personality = GuestConfig.GetRandomPersonality()

	-- Determine ski ownership
	local ownsSkis = math.random() < (GuestConfig.SkiOwnership[personalityName] or 0.5)

	-- Budget
	local budget = GuestConfig.GetBudget(personalityName)

	-- Create guest data
	local data = {
		Model = model,
		Root = model:FindFirstChild("HumanoidRootPart"),
		Humanoid = model:FindFirstChild("Humanoid"),
		GuestUUID = guestUUID,

		OwnerId = userId,
		HotelUUID = hotel and GetHotelUUID(hotel) or "",
		HotelKey = hotel and GetHotelKey(hotel) or "",
		HotelModel = hotel,

		State = STATE.IDLE,
		IdleTimer = math.random() * 2,  -- PATCHED: reduced initial idle stagger

		Personality = personalityName,
		SkillLevel = personality.SkillLevel,

		Satisfaction = GuestConfig.Satisfaction.BaseValue,
		Hunger = 80 + math.random() * 20,
		Energy = 80 + math.random() * 20,

		HasSkis = ownsSkis,
		NeedsTicketBeforeRental = (not ownsSkis) and (math.random() < TICKET_OFFICE_IN_PERSON_SHARE) or false,
		HasResortTicket = ownsSkis and true or false,
		TicketQueueLane = nil,
		TicketQueueSlot = nil,
		Budget = budget,
		TotalSpent = 0,
		SkiRuns = 0,

		-- Movement
		MoveTarget = nil,
		MoveCallback = nil,
		Waypoints = nil,
		WaypointIndex = nil,
		StuckTimer = 0,
		MoveStartTime = 0,
		LastMovePos = nil,
		LastMoveCommandTime = 0,

		-- Activity
		TargetBuilding = nil,
		TargetLift = nil,
		TargetSlope = nil,
		TargetInstructor = nil,
		LessonTargetPos = nil,
		ActionTimer = 0,
		WantsBreak = false,
		AvoidLiftUntil = {},
		LastLiftUUID = nil,
		LastLiftUseAt = nil,
		LastSlopeUUID = nil,
		LastSlopeUseAt = nil,
		RecentlyUnloadedAt = nil,
		LastCrowdPenaltyTime = 0,
		NextLiftRerouteAt = 0,
		LastQueueEvalAt = 0,
		PredictedQueueWait = 0,

		-- Ski
		SkiPath = nil,
		SkiIndex = nil,
		SkiProgress = nil,
		SkiSpeed = nil,
		SkiSmoothedDir = nil,
		SkiCarvePhase = nil,

		-- Lift
		LiftChairId = nil,
		LiftSeatIdx = nil,
		LiftUUID = nil,
		RideStartTime = nil,
		HasLeftBoardingStation = nil,
		MinDistToEndThisRide = nil,
		BoardingStationTag = nil,
		_wasStationSegment = nil,

		-- Timestamps
		SpawnTime = tick(),
		LastDecisionTime = 0,
		LastSpeechTime = 0,
		_lastNeedsPush = 0,
		_lastPushedState = nil,
		_lastPushedHunger = nil,
		_lastPushedEnergy = nil,
		_lastPushedSatisfaction = nil,
		_lastWalkingRerouteCheck = 0,
	}

	if not data.HasSkis then
		data.HasResortTicket = not data.NeedsTicketBeforeRental
	else
		data.HasResortTicket = true
	end

	-- Set all attributes on model
	model:SetAttribute("OwnerId", userId)
	model:SetAttribute("GuestUUID", guestUUID)
	model:SetAttribute("Personality", personalityName)
	model:SetAttribute("SkillLevel", data.SkillLevel)
	model:SetAttribute("Satisfaction", math.floor(data.Satisfaction))
	model:SetAttribute("Hunger", math.floor(data.Hunger))
	model:SetAttribute("Energy", math.floor(data.Energy))
	model:SetAttribute("HasSkis", data.HasSkis)
	model:SetAttribute("NeedsRental", not data.HasSkis)
	model:SetAttribute("NeedsTicketBeforeRental", data.NeedsTicketBeforeRental == true)
	model:SetAttribute("HasResortTicket", data.HasResortTicket == true)
	model:SetAttribute("TicketPurchaseMode", data.NeedsTicketBeforeRental and "InPerson" or "Online")
	model:SetAttribute("Budget", math.floor(data.Budget))
	model:SetAttribute("SkiRuns", 0)
	model:SetAttribute("State", STATE.IDLE)
	model:SetAttribute("IsSkiing", false)
	model:SetAttribute("IsCrashed", false)
	model:SetAttribute("RidingLift", false)
	model:SetAttribute("AssignedInstructorUUID", nil)
	model:SetAttribute("LessonTargetX", nil)
	model:SetAttribute("LessonTargetY", nil)
	model:SetAttribute("LessonTargetZ", nil)
	model:SetAttribute("TakingLesson", false)
	model:SetAttribute("LessonProgress", nil)
	model:SetAttribute("RealName", model:GetAttribute("RealName") or "Guest")
	model:SetAttribute("AssignedHotelUUID", data.HotelUUID or "")
	model:SetAttribute("AssignedHotelKey", data.HotelKey or "")

	-- Register
	AllGuests[model] = data
	TotalGuestCount += 1
	if not PlayerGuests[userId] then PlayerGuests[userId] = {} end
	table.insert(PlayerGuests[userId], data)
	PushGuestCountToPlayer(player)

	-- Initial greeting
	task.delay(1, function()
		if model and model.Parent then
			ShowSpeech(model, PickRandom({
				"Just arrived! ⛷️",
				"What a beautiful resort!",
				"Time to ski!",
				"Hello! 👋",
				"This looks fun!",
			}), 3)
		end
	end)

	return data
end

function RemoveGuest(data)
	local model = data.Model
	if not model then return end
	ClearGuestLessonAssignment(data)
	ClearLiftQueueState(data)

	-- Clean up lift riding state
	if data.LiftUUID and data.LiftChairId and data.LiftSeatIdx then
		local occupyKey = data.LiftUUID .. "_" .. data.LiftChairId .. "_" .. data.LiftSeatIdx
		if OccupiedChairs[occupyKey] == model then
			OccupiedChairs[occupyKey] = nil
		end
	end

	-- Report final rating
	local satLevel = GetSatisfactionLevel(data)
	if satLevel == "Ecstatic" or satLevel == "Happy" then
		ReportRating(data, "GuestCompletedVacation")
	elseif satLevel == "Miserable" or satLevel == "Leave" then
		if data.Hunger < 20 then ReportRating(data, "GuestLeftHungry") end
		if data.Budget < 5 then ReportRating(data, "GuestLeftBroke") end
		if data.Energy < 15 then ReportRating(data, "GuestLeftTired") end
	end

	-- Unregister
	local wasRegistered = AllGuests[model] ~= nil
	AllGuests[model] = nil
	if wasRegistered then
		TotalGuestCount = math.max(0, TotalGuestCount - 1)
	end
	local userId = data.OwnerId
	if PlayerGuests[userId] then
		for i, g in ipairs(PlayerGuests[userId]) do
			if g == data then
				table.remove(PlayerGuests[userId], i)
				break
			end
		end
	end

	-- Destroy
	model:Destroy()
end

-- ============================================================================
-- MAIN UPDATE LOOPS (split rates)
-- ============================================================================
local movementAccumulator = 0
local skiAccumulator = 0
local decisionAccumulator = 0
local runtimeRefreshAccumulator = 0
local lastRuntimeHeavyRepairAt = 0
local RUNTIME_HEAVY_REPAIR_BASE = 1.15

function GetRuntimeHeavyRepairInterval(): number
	local n = math.max(0, TotalGuestCount)
	if n >= 2200 then return 4.8 end
	if n >= 1900 then return 3.9 end
	if n >= 1600 then return 3.1 end
	if n >= 1300 then return 2.45 end
	if n >= 1000 then return 1.95 end
	return RUNTIME_HEAVY_REPAIR_BASE
end

function GetEffectiveRuntimeCandidateRefreshSeconds(guestCount: number): number
	local base = GetPerformanceConfig().RuntimeCandidateRefreshSeconds
	if guestCount >= 2200 then return math.max(base, 6.8) end
	if guestCount >= 1900 then return math.max(base, 5.8) end
	if guestCount >= 1600 then return math.max(base, 5.0) end
	if guestCount >= 1300 then return math.max(base, 4.2) end
	if guestCount >= 1000 then return math.max(base, 3.6) end
	if guestCount >= 750 then return math.max(base, 3.2) end
	if guestCount >= 600 then return math.max(base, 2.8) end
	if guestCount >= 500 then return math.max(base, 2.4) end
	if guestCount >= 380 then return math.max(base, 1.9) end
	if guestCount >= 260 then return math.max(base, 1.4) end
	return base
end

local nextMovementTelemetryAt = 0
local nextMovementPressureWarnAt = 0
local movementLod0: {Model} = {}
local movementLod1: {Model} = {}
local movementLod2: {Model} = {}
local skiLod0: {Model} = {}
local skiLod1: {Model} = {}
local skiLod2: {Model} = {}
local decisionLod0: {Model} = {}
local decisionLod1: {Model} = {}
local decisionLod2: {Model} = {}
local movementLodCursors = {1, 1, 1}
local skiLodCursors = {1, 1, 1}
local decisionLodCursors = {1, 1, 1}
decisionLodCursors.Urgent = {1, 1, 1}
decisionLodCursors.NextUrgentSweepAt = 0

function GetMovementUpdateInterval(guestCount)
	-- Movement commands are command-driven; lower check cadence under heavy load
	-- keeps physics time stable, which prevents visible slow-motion walking.
	-- 1.5k–2k+ guests: ~6–9 Hz movement scheduling is required for server headroom.
	if guestCount >= 2200 then return 1 / 6 end
	if guestCount >= 1900 then return 1 / 7 end
	if guestCount >= 1650 then return 1 / 8 end
	if guestCount >= 1400 then return 1 / 9 end
	if guestCount >= 1200 then return 1 / 10 end
	if guestCount >= 900 then return 1 / 11 end
	if guestCount >= 650 then return 1 / 10 end
	if guestCount >= 500 then return 1 / 9 end
	if guestCount >= 400 then return 1 / 11 end
	if guestCount >= 260 then return 1 / 13 end
	if guestCount >= 180 then return 1 / 15 end
	if guestCount >= 120 then return 1 / 20 end
	return 1 / 26
end

function GetSkiUpdateInterval(guestCount)
	local perf = GetPerformanceConfig()
	local hz = perf.SkiServerHz
	if guestCount >= 2200 then
		hz = math.min(hz, 6)
	elseif guestCount >= 1900 then
		hz = math.min(hz, 7)
	elseif guestCount >= 1600 then
		hz = math.min(hz, 8)
	elseif guestCount >= 1200 then
		hz = math.min(hz, 10)
	elseif guestCount >= 900 then
		hz = math.min(hz, 11)
	elseif guestCount >= 650 then
		hz = math.min(hz, 12)
	elseif guestCount >= 450 then
		hz = math.min(hz, 13)
	elseif guestCount >= 300 then
		hz = math.min(hz, 14)
	elseif guestCount >= 180 then
		hz = math.min(hz, 16)
	end

	local floorHz
	if guestCount >= 2200 then
		floorHz = 6
	elseif guestCount >= 1700 then
		floorHz = 7
	elseif guestCount >= 1200 then
		floorHz = 8
	elseif guestCount >= 900 then
		floorHz = 10
	elseif guestCount >= 650 then
		floorHz = 11
	elseif guestCount >= 450 then
		floorHz = 12
	elseif guestCount >= 300 then
		floorHz = 13
	elseif guestCount >= 180 then
		floorHz = 14
	else
		floorHz = 22
	end

	hz = math.max(floorHz, hz)
	return 1 / hz
end

function GetAdaptiveDecisionInterval(guestCount)
	local perf = GetPerformanceConfig()
	local lowHz = perf.DecisionHzLowLoad
	local highHz = perf.DecisionHzHighLoad
	-- Hard caps for mega-resorts: full decision pass is O(n) work per budget slice.
	if guestCount >= 2200 then
		return 1.05
	end
	if guestCount >= 1900 then
		return 0.92
	end
	if guestCount >= 1600 then
		return 0.78
	end
	if guestCount >= 1400 then
		return 1 / math.max(2, highHz - 2)
	end
	if guestCount >= 1000 then
		return 1 / math.max(3, highHz - 1)
	end
	if guestCount >= 700 then
		return math.max(0.32, 1 / math.max(2.8, highHz - 1.2))
	end
	if guestCount >= 500 then
		return math.max(0.4, 1 / math.max(2.4, highHz - 1.6))
	end
	if guestCount >= 400 then
		return math.max(0.48, 1 / math.max(2.1, highHz - 2.0))
	end
	if guestCount >= 220 then
		return 1 / math.max(highHz, lowHz - 1)
	end
	if guestCount >= 150 then
		return 1 / math.max(2.15, highHz + 0.4)
	end
	if guestCount >= 90 then
		return 1 / math.max(highHz, lowHz * 0.85)
	end
	return 1 / lowHz
end

function GetGroundSnapCadenceForPopulation(): number
	local n = math.max(0, TotalGuestCount)
	if n >= 2200 then return 1.35 end
	if n >= 1900 then return 1.15 end
	if n >= 1600 then return 0.95 end
	if n >= 1300 then return 0.78 end
	if n >= 1000 then return 0.68 end
	if n >= 900 then return 0.55 end
	if n >= 500 then return 0.48 end
	if n >= 300 then return 0.4 end
	if n >= 200 then return 0.34 end
	if n >= 120 then return 0.3 end
	return 0.25
end

-- ============================================================================
-- PLAYER-PROXIMITY LOD (distance to nearest live player character)
-- ============================================================================
local LOD_STATE_FORCE_TIER0 = {
	[STATE.RIDING_LIFT] = true,
	[STATE.BOARDING_LIFT] = true,
	[STATE.UNLOADING_LIFT] = true,
	[STATE.SKIING_DOWN] = true,
	[STATE.CRASHED] = true,
	[STATE.RECOVERING] = true,
}

function GuestLodIsEnabled(): boolean
	local lod = GuestConfig.LOD
	if not lod or lod.Enabled == false then
		return false
	end
	local minN = math.max(8, math.floor(tonumber(lod.MinGuestsToActivate) or 80))
	return TotalGuestCount >= minN
end

function GuestLodCollectPlayerRoots(): {Vector3}
	local roots = table.create(8)
	for _, plr in ipairs(Players:GetPlayers()) do
		local ch = plr.Character
		if ch and ch.Parent then
			local root = ch.PrimaryPart or ch:FindFirstChild("HumanoidRootPart")
			if root and root:IsA("BasePart") then
				roots[#roots + 1] = root.Position
			end
		end
	end
	return roots
end

function GuestLodMinDistSqToPlayers(pos: Vector3, roots: {Vector3}): number
	if #roots == 0 then
		return math.huge
	end
	local best = math.huge
	for i = 1, #roots do
		local p = roots[i]
		local dx = pos.X - p.X
		local dy = pos.Y - p.Y
		local dz = pos.Z - p.Z
		local d = dx * dx + dy * dy + dz * dz
		if d < best then
			best = d
		end
	end
	return best
end

function GuestLodDistanceTier(distSq: number, lod: {[string]: any}): number
	local hi = tonumber(lod.HighRadiusStuds) or 260
	local med = tonumber(lod.MediumRadiusStuds) or 620
	if med < hi then
		med = hi + 140
	end
	local rHi = hi * hi
	local rMed = med * med
	if distSq <= rHi then
		return 0
	end
	if distSq <= rMed then
		return 1
	end
	return 2
end

function GuestLodEffectiveTier(data: GuestData, distTier: number): number
	local st = data.State
	if st == STATE.SKIING_DOWN then
		local pop = math.max(0, TotalGuestCount)
		if pop >= 900 then
			return math.max(1, distTier)
		elseif pop >= 620 then
			return distTier
		end
		return 0
	end
	if LOD_STATE_FORCE_TIER0[st] then
		return 0
	end
	if st == STATE.WALKING_TO_LIFT or st == STATE.SKIING_TO_SLOPE or st == STATE.WAITING_LIFT or st == STATE.LEAVING then
		return math.min(distTier, 1)
	end
	return distTier
end

function PurgeInvalidGuest(model, data)
	if data then
		ClearGuestLessonAssignment(data)
		ClearLiftQueueState(data)
	elseif model then
		LiftQueueIndexByModel[model] = nil
	end
	if model and model.Parent then
		model:Destroy()
	end
	AllGuests[model] = nil
	TotalGuestCount = math.max(0, TotalGuestCount - 1)
	if data and PlayerGuests[data.OwnerId] then
		for i, g in ipairs(PlayerGuests[data.OwnerId]) do
			if g == data then
				table.remove(PlayerGuests[data.OwnerId], i)
				break
			end
		end
	end
end

function IsInvalidGuest(model, data)
	return (not model) or (not model.Parent) or (not data) or (not data.Root) or (not data.Humanoid)
end

function RefreshRuntimeCandidates()
	movementLod0 = {}
	movementLod1 = {}
	movementLod2 = {}
	skiLod0 = {}
	skiLod1 = {}
	skiLod2 = {}
	decisionLod0 = {}
	decisionLod1 = {}
	decisionLod2 = {}
	local nowRepair = tick()
	local doHeavyPhys = (nowRepair - lastRuntimeHeavyRepairAt) >= GetRuntimeHeavyRepairInterval()
	if doHeavyPhys then
		lastRuntimeHeavyRepairAt = nowRepair
	end
	local lodCfg = GuestConfig.LOD or {}
	local lodOn = GuestLodIsEnabled()
	local roots = lodOn and GuestLodCollectPlayerRoots() or {}
	if lodOn and #roots == 0 then
		lodOn = false
	end
	for model, data in pairs(AllGuests) do
		if IsInvalidGuest(model, data) then
			PurgeInvalidGuest(model, data)
		else
			if data.State == STATE.UNLOADING_LIFT then
				data.UnloadStartedAt = data.UnloadStartedAt or nowRepair
				if (nowRepair - data.UnloadStartedAt) > 6 then
					if data.Root then
						data.Root.CanCollide = true
						data.Root.Anchored = false
						data.Root.AssemblyLinearVelocity = Vector3.zero
						data.Root.AssemblyAngularVelocity = Vector3.zero
						ApplyWalkerNetworkOwnership(data.Root)
					end
					if data.Humanoid then
						data.Humanoid.PlatformStand = false
						data.Humanoid.AutoRotate = true
					end
					data.UnloadTimer = nil
					data.TargetLift = nil
					data.TargetSlope = nil
					data.TargetSlopeEntryIndex = nil
					data.State = STATE.DECIDING
				end
			else
				data.UnloadStartedAt = nil
			end
			-- Full Humanoid/HRP repair is very expensive at 200+ guests every refresh.
			-- Run the heavy fix on a timer; list membership still updates every refresh.
			if doHeavyPhys and data.Humanoid then
				local walkSpeed = data.Humanoid.WalkSpeed or 0
				if walkSpeed < 20 or walkSpeed > 32 then
					data.Humanoid.WalkSpeed = 26
				end
				if data.Root then
					local state = data.State
					local shouldBeFree = state ~= STATE.RIDING_LIFT
						and state ~= STATE.SKIING_DOWN
						and state ~= STATE.CRASHED
						and state ~= STATE.RECOVERING
					if shouldBeFree then
						if data.Root.Anchored or data.Humanoid.PlatformStand or not data.Root.CanCollide then
							EnsureGuestWalkingPhysics(data, nil, nil)
						else
							data.Humanoid.AutoRotate = true
						end
					end
				end
			end
			local tier = 0
			if lodOn and data.Root then
				local d2 = GuestLodMinDistSqToPlayers(data.Root.Position, roots)
				tier = GuestLodEffectiveTier(data, GuestLodDistanceTier(d2, lodCfg))
			end
			data._lodTier = tier
			if tier == 0 then
				table.insert(decisionLod0, model)
			elseif tier == 1 then
				table.insert(decisionLod1, model)
			else
				table.insert(decisionLod2, model)
			end
			if data.MoveTarget then
				if tier == 0 then
					table.insert(movementLod0, model)
				elseif tier == 1 then
					table.insert(movementLod1, model)
				else
					table.insert(movementLod2, model)
				end
			else
				data.LastMoveProcessAt = nil
			end
			if data.State == STATE.SKIING_DOWN then
				if tier == 0 then
					table.insert(skiLod0, model)
				elseif tier == 1 then
					table.insert(skiLod1, model)
				else
					table.insert(skiLod2, model)
				end
			else
				data.LastSkiProcessAt = nil
			end
		end
	end
	if #movementLod0 == 0 then movementLodCursors[1] = 1 end
	if #movementLod1 == 0 then movementLodCursors[2] = 1 end
	if #movementLod2 == 0 then movementLodCursors[3] = 1 end
	if #skiLod0 == 0 then skiLodCursors[1] = 1 end
	if #skiLod1 == 0 then skiLodCursors[2] = 1 end
	if #skiLod2 == 0 then skiLodCursors[3] = 1 end
	if #decisionLod0 == 0 then decisionLodCursors[1] = 1 end
	if #decisionLod1 == 0 then decisionLodCursors[2] = 1 end
	if #decisionLod2 == 0 then decisionLodCursors[3] = 1 end
	Workspace:SetAttribute("GuestLodEnabled", lodOn)
	Workspace:SetAttribute("GuestLodMoversH", #movementLod0)
	Workspace:SetAttribute("GuestLodMoversM", #movementLod1)
	Workspace:SetAttribute("GuestLodMoversL", #movementLod2)
end

function GetMovementBudget(totalMoving: number, movementInterval: number): number
	if totalMoving <= 0 then
		return 0
	end
	local perf = GetPerformanceConfig()
	local targetRevisit = math.max(0.3, perf.TargetMovementRevisitSeconds)
	local totalPop = math.max(0, TotalGuestCount)
	local minBudget = math.max(10, perf.MinMovementGuestsPerTick)
	if totalPop >= 2000 then
		minBudget = math.min(minBudget, 10)
	elseif totalPop >= 1400 then
		minBudget = math.min(minBudget, 12)
	elseif totalPop >= 1000 then
		minBudget = math.min(minBudget, 14)
	end
	local maxBudget = math.max(minBudget, perf.MaxMovementGuestsPerTickDynamic, perf.MaxMovementGuestsPerTick)
	local requiredBudget = math.ceil((totalMoving * movementInterval) / targetRevisit)
	-- FIX: properly clamp between min and max, then cap at totalMoving
	local budget = math.clamp(requiredBudget, minBudget, maxBudget)
	budget = math.min(budget, totalMoving)
	if totalPop > 0 and totalPop <= 550 then
		local softCap = math.max(12, math.ceil(totalMoving * 0.4))
		budget = math.min(budget, softCap)
	end
	if totalMoving > 0 and totalMoving <= 320 then
		budget = math.min(budget, math.max(10, math.ceil(totalMoving * 0.34)))
	end
	if totalPop >= 2200 then
		budget = math.min(budget, math.max(20, math.ceil(totalMoving * 0.16)))
	elseif totalPop >= 1800 then
		budget = math.min(budget, math.max(22, math.ceil(totalMoving * 0.19)))
	elseif totalPop >= 1400 then
		budget = math.min(budget, math.max(26, math.ceil(totalMoving * 0.24)))
	elseif totalPop >= 1000 then
		budget = math.min(budget, math.max(30, math.ceil(totalMoving * 0.28)))
	end
	return math.max(1, budget)
end

function GetDecisionBudget(totalGuests: number, decisionInterval: number): number
	if totalGuests <= 0 then
		return 0
	end
	local perf = GetPerformanceConfig()
	local targetRevisit = math.max(decisionInterval, perf.DecisionTargetRevisitSeconds)
	if totalGuests >= 3200 then
		targetRevisit *= 1.58
	elseif totalGuests >= 2600 then
		targetRevisit *= 1.48
	elseif totalGuests >= 2200 then
		targetRevisit *= 1.38
	elseif totalGuests >= 1800 then
		targetRevisit *= 1.28
	elseif totalGuests >= 1400 then
		targetRevisit *= 1.18
	elseif totalGuests >= 1000 then
		targetRevisit *= 1.12
	elseif totalGuests >= 900 then
		targetRevisit *= 1.2
	elseif totalGuests >= 700 then
		targetRevisit *= 1.32
	elseif totalGuests >= 500 then
		targetRevisit *= 1.42
	elseif totalGuests >= 400 then
		targetRevisit *= 1.5
	elseif totalGuests >= 200 then
		targetRevisit *= 1.2
	end
	local minBudget = math.max(6, perf.MinDecisionGuestsPerTick)
	if totalGuests >= 2000 then
		minBudget = math.min(minBudget, 16)
	elseif totalGuests >= 1400 then
		minBudget = math.min(minBudget, 18)
	elseif totalGuests >= 900 then
		minBudget = math.min(minBudget, 20)
	end
	if totalGuests <= 700 then
		minBudget = math.max(10, math.floor(minBudget * 0.7))
	end
	if totalGuests <= 450 then
		minBudget = math.max(9, math.floor(minBudget * 0.8))
	end
	if totalGuests <= 280 then
		minBudget = math.max(8, math.floor(minBudget * 0.85))
	end
	local maxBudget = math.max(minBudget, perf.MaxDecisionGuestsPerTick, perf.MaxDecisionGuestsPerTickDynamic)
	if totalGuests >= 2200 then
		maxBudget = math.min(maxBudget, 64)
	elseif totalGuests >= 1800 then
		maxBudget = math.min(maxBudget, 72)
	elseif totalGuests >= 1400 then
		maxBudget = math.min(maxBudget, 84)
	elseif totalGuests >= 1000 then
		maxBudget = math.min(maxBudget, 96)
	elseif totalGuests >= 700 then
		maxBudget = math.min(maxBudget, 72)
	elseif totalGuests >= 500 then
		maxBudget = math.min(maxBudget, 58)
	elseif totalGuests <= 400 then
		maxBudget = math.min(maxBudget, math.max(minBudget + 8, math.ceil(totalGuests * 0.26)))
	end
	local requiredBudget = math.ceil((totalGuests * decisionInterval) / targetRevisit)
	local budget = math.clamp(requiredBudget, minBudget, maxBudget)
	budget = math.min(budget, totalGuests)
	return math.max(1, budget)
end

function CollectMoveAgesFromLodList(list: {Model}, now: number, ages: {number}, maxPerList: number)
	local n = #list
	local step = 1
	if n > maxPerList then
		step = math.max(1, math.floor(n / maxPerList))
	end
	for i = 1, n, step do
		local model = list[i]
		local data = model and AllGuests[model] or nil
		if data and data.MoveTarget then
			local base = data.LastMoveCommandTime or data.MoveStartTime or now
			ages[#ages + 1] = math.max(0, now - base)
		end
	end
end

function ComputeMoveCommandAgeP95(now: number): number
	local ages = {}
	local cap = 50
	CollectMoveAgesFromLodList(movementLod0, now, ages, cap)
	CollectMoveAgesFromLodList(movementLod1, now, ages, cap)
	CollectMoveAgesFromLodList(movementLod2, now, ages, cap)
	local total = #ages
	if total <= 0 then
		return 0
	end
	table.sort(ages)
	local idx = math.max(1, math.min(total, math.ceil(total * 0.95)))
	return ages[idx]
end

function PushMovementTelemetryAttributes()
	Workspace:SetAttribute("GuestMovingCount", RuntimeMovingGuestCount)
	Workspace:SetAttribute("GuestMovementBudgetPerTick", RuntimeMovementBudgetPerTick)
	Workspace:SetAttribute("GuestMovementPressure", RuntimeMovementPressure)
	Workspace:SetAttribute("GuestMoveCommandAgeP95", RuntimeMoveCommandAgeP95)
end

function ProcessGuestDecisionState(data: GuestData, dt: number)
	if _G.SandboxGuestAIFrozen then return end

	local state = data.State
	if state ~= STATE.UNLOADING_LIFT then
		data.UnloadStartedAt = nil
	elseif data.UnloadStartedAt and (tick() - data.UnloadStartedAt) > 25 then
		local now = tick()
		if data.Root then
			data.Root.CanCollide = true
			data.Root.Anchored = false
			data.Root.AssemblyLinearVelocity = Vector3.zero
			data.Root.AssemblyAngularVelocity = Vector3.zero
		end
		if data.Humanoid then
			data.Humanoid.PlatformStand = false
			data.Humanoid.AutoRotate = true
		end
		if data.TargetLift and data.TargetLift.Parent then
			MarkLiftAvoidance(data, data.TargetLift, 45)
		end
		data.UnloadTimer = nil
		data.TargetLift = nil
		data.TargetSlope = nil
		data.TargetSlopeEntryIndex = nil
		data.PostUnloadSkiRequired = true
		data.PostUnloadSkiStartedAt = now
		data.PostUnloadSkiNextRetryAt = now + 0.1
		data.PostUnloadSkiAttempts = tonumber(data.PostUnloadSkiAttempts) or 0
		data.PostUnloadSkiStartIndex = nil
		data.PostUnloadSkiLastAttemptAt = nil
		data.PostUnloadSkiStartPos = data.Root and data.Root.Position or nil
		data.WantsBreak = false
		data.State = STATE.DECIDING
		state = data.State
	end
	if data.PostUnloadSkiRequired == true and state ~= STATE.UNLOADING_LIFT and state ~= STATE.SKIING_DOWN then
		local now = tick()
		data.PostUnloadSkiStartedAt = data.PostUnloadSkiStartedAt or now
		local postUnloadAttempts = tonumber(data.PostUnloadSkiAttempts) or 0
		local postUnloadElapsed = now - (tonumber(data.PostUnloadSkiStartedAt) or now)
		local hardTimeoutSeconds = 60
		local maxPostUnloadAttempts = 48
		if postUnloadAttempts >= maxPostUnloadAttempts or postUnloadElapsed > hardTimeoutSeconds then
			local guestPos = (data.Root and data.Root.Position) or Vector3.zero
			local fallbackSlope = FindSlopeForGuest(data, guestPos)
				or FindAnySlopeForGuest(data, guestPos)
				or FindEmergencySlopeForGuest(data, guestPos)
			if not fallbackSlope then
				local placedObjects = Workspace:FindFirstChild("PlacedObjects")
				if placedObjects then
					for _, inst in ipairs(placedObjects:GetDescendants()) do
						if inst:IsA("Model") and tostring(inst:GetAttribute("Type") or "") == "Slope" then
							local instPath = GetSlopeData(inst)
							if instPath and #instPath > 1 then
								fallbackSlope = inst
								break
							end
						end
					end
				end
			end
			if fallbackSlope then
				local fallbackPath = GetSlopeData(fallbackSlope)
				if fallbackPath and #fallbackPath > 1 then
					local fallbackEntryIndex = select(1, SelectSkiEntryIndex(fallbackPath, guestPos, 70, 26))
						or math.clamp((tonumber(GetNearestSlopeEntryIndex(fallbackPath, guestPos, math.huge)) or 1), 1, math.max(1, #fallbackPath - 2))
					local fallbackEntryPos = GetSlopeEntryPosition(fallbackPath, fallbackEntryIndex) or GetGroundPos(fallbackPath[fallbackEntryIndex] or fallbackPath[1])
					EnsureGuestWalkingPhysics(data, guestPos, nil)
					data.TargetLift = nil
					data.WantsBreak = false
					data.TargetSlope = fallbackSlope
					data.TargetSlopeEntryIndex = fallbackEntryIndex
					data.PostUnloadSkiNextRetryAt = now + 0.8
					data.State = STATE.SKIING_TO_SLOPE
					MoveGuestTo(data, fallbackEntryPos, function(guestData)
						if not TryStartSkiingDown(guestData, fallbackSlope, { EntryIndex = fallbackEntryIndex }, "PostUnloadHardFallback") then
							guestData.State = STATE.DECIDING
							guestData.TargetSlope = nil
							guestData.TargetSlopeEntryIndex = nil
						end
					end)
					return
				end
			end
			if data.TargetLift and data.TargetLift.Parent then
				MarkLiftAvoidance(data, data.TargetLift, 120)
			end
			if StartSyntheticPostUnloadSki(data, "PostUnloadHardFallback") then
				return
			end
			data.PostUnloadSkiRequired = nil
			data.PostUnloadSkiStartedAt = nil
			data.PostUnloadSkiNextRetryAt = nil
			data.PostUnloadSkiAttempts = nil
			data.PostUnloadSkiStartIndex = nil
			data.PostUnloadSkiLastAttemptAt = nil
			data.PostUnloadSkiStartPos = nil
			data.RecentlyUnloadedAt = nil
			data.TargetSlope = nil
			data.TargetSlopeEntryIndex = nil
			data.TargetLift = nil
			data.WantsBreak = false
			data.State = STATE.DECIDING
			return
		end
		if now >= (tonumber(data.PostUnloadSkiNextRetryAt) or 0) then
			local guestPos = (data.Root and data.Root.Position) or Vector3.zero
			local slopeTarget = (data.TargetSlope and data.TargetSlope.Parent) and data.TargetSlope or FindSlopeForGuest(data, guestPos)
			if not slopeTarget then
				slopeTarget = FindAnySlopeForGuest(data, guestPos)
			end
			if not slopeTarget then
				slopeTarget = FindEmergencySlopeForGuest(data, guestPos)
			end
			if not slopeTarget then
				local placedObjects = Workspace:FindFirstChild("PlacedObjects")
				if placedObjects then
					local bestSlope = nil
					local bestScore = math.huge
					for _, inst in ipairs(placedObjects:GetDescendants()) do
						if inst:IsA("Model") and tostring(inst:GetAttribute("Type") or "") == "Slope" then
							local instPath = GetSlopeData(inst)
							if instPath and #instPath > 1 then
								local nearestIndex = math.clamp((GetNearestSlopeEntryIndex(instPath, guestPos, math.huge) or 1), 1, math.max(1, #instPath - 2))
								local nearestPos = instPath[nearestIndex] or instPath[1]
								local score = FlatDist(guestPos, nearestPos)
								if score < bestScore then
									bestScore = score
									bestSlope = inst
								end
							end
						end
					end
					slopeTarget = bestSlope
				end
			end
			if slopeTarget then
				local slopePath = GetSlopeData(slopeTarget)
				data.PostUnloadSkiAttempts = (tonumber(data.PostUnloadSkiAttempts) or 0) + 1
				if slopePath and #slopePath > 1 then
					local forcedEntryIndex = select(1, SelectSkiEntryIndex(slopePath, guestPos, 70, 26))
						or math.clamp((tonumber(GetNearestSlopeEntryIndex(slopePath, guestPos, math.huge)) or 1), 1, math.max(1, #slopePath - 2))
					local forcedEntryPos = GetSlopeEntryPosition(slopePath, forcedEntryIndex) or GetGroundPos(slopePath[forcedEntryIndex] or slopePath[1])
					EnsureGuestWalkingPhysics(data, forcedEntryPos, nil)
					data.TargetLift = nil
					data.WantsBreak = false
					data.PostUnloadSkiStartIndex = forcedEntryIndex
					data.PostUnloadSkiLastAttemptAt = now
					data.PostUnloadSkiStartPos = forcedEntryPos
					if TryStartSkiingDown(data, slopeTarget, { EntryIndex = forcedEntryIndex }, "PostUnloadForced") then
						return
					end

					-- If instant-start fails, immediately walk to the slope entry and retry there.
					data.TargetSlope = slopeTarget
					data.TargetSlopeEntryIndex = forcedEntryIndex
					data.State = STATE.SKIING_TO_SLOPE
					MoveGuestTo(data, forcedEntryPos, function(guestData)
						if not TryStartSkiingDown(guestData, slopeTarget, { EntryIndex = forcedEntryIndex }, "PostUnloadWalkToEntry") then
							MarkSlopeAvoidance(guestData, slopeTarget, 25)
							guestData.PostUnloadSkiNextRetryAt = tick() + 0.35
							guestData.State = STATE.DECIDING
							if guestData.TargetSlope == slopeTarget then
								guestData.TargetSlope = nil
							end
							guestData.TargetSlopeEntryIndex = nil
						end
					end)
					data.PostUnloadSkiNextRetryAt = now + 0.75
					return
				end

				-- Failed to resolve a usable path for this slope. Avoid and try a different one.
				MarkSlopeAvoidance(data, slopeTarget, 25)
				if data.TargetSlope == slopeTarget then
					data.TargetSlope = nil
				end
				data.TargetSlopeEntryIndex = nil
			else
				-- Count failed retries even when no slope could be resolved so this state
				-- cannot loop forever waiting on unavailable routing.
				data.PostUnloadSkiAttempts = (tonumber(data.PostUnloadSkiAttempts) or 0) + 1
			end
			if (tonumber(data.PostUnloadSkiAttempts) or 0) >= 8 or postUnloadElapsed > 10 then
				if StartSyntheticPostUnloadSki(data, "PostUnloadRetry") then
					return
				end
			end
			data.PostUnloadSkiNextRetryAt = now + 0.45
		end
		data.TargetLift = nil
		data.WantsBreak = false
		EnsureGuestWalkingPhysics(data, data.Root and data.Root.Position or nil, nil)
		if data.State ~= STATE.SKIING_TO_SLOPE then
			data.State = STATE.DECIDING
		end
		return
	end

	if state == STATE.WALKING_TO_LIFT or state == STATE.WALKING or state == STATE.SKIING_TO_SLOPE then
		EnsureGuestWalkingPhysics(data, nil, nil)
	end

	if state == STATE.SKIING_DOWN then
		-- Ski state is processed in dedicated 30Hz loop.
		data._LastActivityTime = tick()
		return
	end

	-- FIX: Reset activity timer for any state that means the guest is doing something
	-- productive. Only IDLE and DECIDING are "inactive" states.
	if state ~= STATE.IDLE and state ~= STATE.DECIDING then
		data._LastActivityTime = tick()
	end

	if state == STATE.IDLE then
		ProcessIdle(data, dt)
		return
	end
	if state == STATE.DECIDING then
		-- PATCHED: removed redundant cooldown that stacked with loop cadence.
		data.LastDecisionTime = tick()
		ProcessDeciding(data)
		return
	end
	if state == STATE.WALKING_TO_LIFT then
		if data.PostUnloadSkiRequired == true then
			ClearGuestMoveCommandState(data)
			ClearLiftQueueState(data)
			ClearLiftCommitment(data)
			data.TargetLift = nil
			data.WantsBreak = false
			data.State = STATE.DECIDING
			return
		end
		-- Commit while walking; reroute decisions happen only in queue state.
		if IsSummerSeason() then
			data.TargetLift = nil
			data.WantsBreak = true
			data.MoveTarget = nil
			data.Waypoints = nil
			data.MoveCallback = nil
			data.State = STATE.DECIDING
		else
			local targetLift = data.TargetLift
			if targetLift and targetLift.Parent then
				-- FIX: Recover walkers that get stranded on intermediate detour/path targets.
				-- These guests can stop progressing 50-100 studs away from the true lift start
				-- while still reporting WALKING_TO_LIFT, which traps them forever.
				local startPos = GetLiftStartPos(targetLift)
				if data.MoveTarget and data.Root then
					local distToLift = FlatDist(data.Root.Position, startPos)
					local distToMoveTarget = FlatDist(data.Root.Position, data.MoveTarget)
					if distToLift < 14 then
						data.MoveTarget = nil
						data.Waypoints = nil
						data.MoveCallback = nil
						EnterLiftQueue(data)
						return
					end
					local noProgressFor = tick() - (data.LastProgressTime or tick())
					local strandedAtIntermediateTarget = distToMoveTarget < 8 and distToLift > 18
					if strandedAtIntermediateTarget or noProgressFor > 4 then
						data.MoveTarget = nil
						data.Waypoints = nil
						data.MoveCallback = nil
						data.MoveResumeTarget = nil
						data.MoveResumeCallback = nil
						MoveGuestTo(data, startPos, function()
							EnterLiftQueue(data)
						end)
						return
					end
				end
				if not data.MoveTarget then
					MoveGuestTo(data, startPos, function()
						EnterLiftQueue(data)
					end)
				end
			else
				data.State = STATE.DECIDING
				data.TargetLift = nil
			end
		end
		return
	end
	if state == STATE.SKIING_TO_SLOPE then
		if IsSummerSeason() then
			data.TargetSlope = nil
			data.WantsBreak = true
			data.MoveTarget = nil
			data.Waypoints = nil
			data.MoveCallback = nil
			data.State = STATE.DECIDING
			return
		end
		local targetSlope = data.TargetSlope
		if not targetSlope or not targetSlope.Parent then
			data.TargetSlope = nil
			data.State = STATE.DECIDING
			return
		end
		if not data.MoveTarget then
			local path = GetSlopeData(targetSlope)
			if path and #path > 1 then
				local guestPos = data.Root and data.Root.Position or path[1]
				local entryIndex = GetNearestSlopeEntryIndex(path, guestPos, 115)
				local entryPos = GetSlopeEntryPosition(path, entryIndex) or GetGroundPos(path[entryIndex] or path[1])
				MoveGuestTo(data, entryPos, function(guestData)
					if not TryStartSkiingDown(guestData, targetSlope, { EntryIndex = entryIndex }, "SkiingToSlopeArrival") then
						MarkSlopeAvoidance(guestData, targetSlope, 18)
						if guestData.PostUnloadSkiRequired == true then
							guestData.PostUnloadSkiNextRetryAt = tick() + 0.35
						end
						guestData.State = STATE.DECIDING
						if guestData.TargetSlope == targetSlope then
							guestData.TargetSlope = nil
						end
						guestData.TargetSlopeEntryIndex = nil
					end
				end)
			else
				data.TargetSlope = nil
				data.State = STATE.DECIDING
			end
		end
		return
	end
	if state == STATE.WALKING then
		-- Recovery: if callbacks clear unexpectedly and no target remains, re-enter decision flow.
		if not data.MoveTarget then
			data.State = STATE.DECIDING
		end
		return
	end
	if state == STATE.EATING then
		ProcessEating(data, dt)
		return
	end
	if state == STATE.RESTING or state == STATE.SLEEPING then
		ProcessResting(data, dt)
		return
	end
	if state == STATE.TAKING_LESSON then
		ProcessTakingLesson(data, dt)
		return
	end
	if state == STATE.RENTING_GEAR then
		ProcessRenting(data, dt)
		return
	end
	if state == STATE.BUYING_TICKET then
		ProcessBuyingTicket(data, dt)
		return
	end
	if state == STATE.HEALING_MED_CENTER then
		ProcessMedCenterHealing(data, dt)
		return
	end
	if state == STATE.WAITING_LIFT then
		if data.PostUnloadSkiRequired == true then
			ClearLiftQueueState(data)
			ClearLiftCommitment(data)
			data.TargetLift = nil
			data.WaitStartTime = nil
			data.WantsBreak = false
			data.State = STATE.DECIDING
			return
		end
		data.WaitStartTime = data.WaitStartTime or tick()
		ProcessWaitingLift(data, dt)
		return
	end
	if state == STATE.RIDING_LIFT then
		local now = tick()
		local cadence = tonumber(data.RideStateCheckCadence)
		if not cadence then
			local n = math.max(0, TotalGuestCount)
			if n >= 1800 then
				cadence = 0.22
			elseif n >= 1200 then
				cadence = 0.16
			elseif n >= 700 then
				cadence = 0.12
			else
				cadence = 0.07
			end
		end
		if now < (data.NextRideStateCheckAt or 0) then
			if data.Root then
				data.Root.AssemblyLinearVelocity = Vector3.zero
				data.Root.AssemblyAngularVelocity = Vector3.zero
			end
			return
		end
		data.NextRideStateCheckAt = now + cadence
		ProcessRidingLift(data, dt)
		return
	end
	if state == STATE.UNLOADING_LIFT then
		ProcessUnloadingLift(data, dt)
		return
	end
	if state == STATE.CRASHED then
		if data.Model and data.Model:GetAttribute("PatrolRescueTriggered") == true then
			data.Model:SetAttribute("PatrolRescueTriggered", false)
			RecoverGuest(data)
		end
		return
	end
	-- RECOVERING/LEAVING/GOING_TO_HOTEL are callback/timer-driven.
end

function DistributeLod3Way(budget: number, n0: number, n1: number, n2: number, wH: number, wM: number, wL: number): (number, number, number)
	local sumW = wH + wM + wL
	if sumW <= 0 then
		wH, wM, wL = 1, 0, 0
	else
		wH = wH / sumW
		wM = wM / sumW
		wL = wL / sumW
	end
	local tot = n0 + n1 + n2
	budget = math.min(budget, tot)
	local b0 = math.floor(budget * wH + 0.5)
	local b1 = math.floor(budget * wM + 0.5)
	local b2 = budget - b0 - b1
	b0 = math.clamp(b0, 0, n0)
	b1 = math.clamp(b1, 0, n1)
	b2 = math.clamp(b2, 0, n2)
	local used = b0 + b1 + b2
	local slack = budget - used
	while slack > 0 do
		if n0 > b0 then
			b0 += 1
			slack -= 1
		elseif n1 > b1 then
			b1 += 1
			slack -= 1
		elseif n2 > b2 then
			b2 += 1
			slack -= 1
		else
			break
		end
	end
	return b0, b1, b2
end

function ProcessMovementLodList(list: {Model}, budget: number, tierCursorIdx: number, moveDt: number)
	if budget <= 0 or #list <= 0 then
		return
	end
	local cur = movementLodCursors[tierCursorIdx]
	for _ = 1, budget do
		if cur > #list then
			cur = 1
		end
		local model = list[cur]
		cur += 1
		local data = model and AllGuests[model] or nil
		if data and not IsInvalidGuest(model, data) and data.MoveTarget then
			local _now = tick()
			local guestMoveDt = math.clamp(_now - (data.LastMoveProcessAt or (_now - moveDt)), moveDt, 1.25)
			if tierCursorIdx == 3 then
				guestMoveDt = math.min(guestMoveDt * 1.12, 1.32)
			elseif tierCursorIdx == 2 then
				guestMoveDt = math.min(guestMoveDt * 1.04, 1.28)
			end
			data.LastMoveProcessAt = _now
			pcall(UpdateMovement, data, guestMoveDt)
		end
	end
	movementLodCursors[tierCursorIdx] = cur
end

function ProcessSkiLodList(list: {Model}, budget: number, tierCursorIdx: number, skiDt: number)
	if budget <= 0 or #list <= 0 then
		return
	end
	local cur = skiLodCursors[tierCursorIdx]
	for _ = 1, budget do
		if cur > #list then
			cur = 1
		end
		local model = list[cur]
		cur += 1
		local data = model and AllGuests[model] or nil
		if data and not IsInvalidGuest(model, data) and data.State == STATE.SKIING_DOWN then
			local _now = tick()
			local maxSkiDt = (TotalGuestCount <= 900) and 0.22 or 0.36
			local guestSkiDt = math.clamp(_now - (data.LastSkiProcessAt or (_now - skiDt)), skiDt, maxSkiDt)
			if tierCursorIdx >= 2 then
				guestSkiDt = math.min(guestSkiDt * 1.02, maxSkiDt)
			end
			data.LastSkiProcessAt = _now
			pcall(UpdateSkiing, data, guestSkiDt)
		end
	end
	skiLodCursors[tierCursorIdx] = cur
end

function ProcessDecisionLodList(list: {Model}, budget: number, tierCursorIdx: number, dt: number, now: number, defaultGroundSnapCadence: number, urgentToken: number?)
	if budget <= 0 or #list <= 0 then
		return
	end
	local cur = decisionLodCursors[tierCursorIdx]
	local snapMult = (tierCursorIdx == 3) and 2.85 or (tierCursorIdx == 2) and 1.48 or 1
	for _ = 1, budget do
		if cur > #list then
			cur = 1
		end
		local model = list[cur]
		cur += 1
		local data = model and AllGuests[model] or nil
		if data and not IsInvalidGuest(model, data) then
			if urgentToken and data.UrgentDecisionToken == urgentToken then
				continue
			end
			pcall(function()
				if RescueGuestFromVoid(data) then
					return
				end
				local baseCad = tonumber(data.GroundSnapCadence) or defaultGroundSnapCadence
				local groundSnapCadence = baseCad * snapMult
				if (not data.NextGroundSnapAt) or now >= data.NextGroundSnapAt then
					data.NextGroundSnapAt = now + groundSnapCadence
					SnapGuestToGroundIfFloating(data, 3.0)
				end
				local guestDt = math.clamp(now - (data.LastDecisionProcessAt or now), 0, 1.5)
				data.LastDecisionProcessAt = now
				UpdateNeeds(data, guestDt)
				ProcessGuestDecisionState(data, guestDt)
			end)
		elseif data then
			PurgeInvalidGuest(model, data)
		end
	end
	decisionLodCursors[tierCursorIdx] = cur
end

local function IsUrgentDecisionGuest(data, now)
	if not data then
		return false
	end
	if data.State == STATE.UNLOADING_LIFT then
		return true
	end
	if data.PostUnloadSkiRequired == true then
		return true
	end
	if data.State == STATE.DECIDING then
		local recentlyUnloadedAt = tonumber(data.RecentlyUnloadedAt)
		if recentlyUnloadedAt and (now - recentlyUnloadedAt) <= 40 then
			return true
		end
	end
	return false
end

local function ProcessUrgentDecisionGuests(dt: number, now: number, defaultGroundSnapCadence: number, urgentToken: number): number
	local n0, n1, n2 = #decisionLod0, #decisionLod1, #decisionLod2
	local total = n0 + n1 + n2
	if total <= 0 then
		return 0
	end
	local pop = math.max(0, TotalGuestCount)
	local sweepGap = 0
	if pop >= 1800 then
		sweepGap = 0.24
	elseif pop >= 1400 then
		sweepGap = 0.21
	elseif pop >= 1000 then
		sweepGap = 0.19
	elseif pop >= 700 then
		sweepGap = 0.17
	elseif pop >= 500 then
		sweepGap = 0.14
	elseif pop >= 350 then
		sweepGap = 0.11
	end
	if sweepGap > 0 and now < decisionLodCursors.NextUrgentSweepAt then
		return 0
	end
	decisionLodCursors.NextUrgentSweepAt = now + sweepGap
	local sweepPercent = 0.2
	if pop >= 1800 then
		sweepPercent = 0.07
	elseif pop >= 1400 then
		sweepPercent = 0.09
	elseif pop >= 1000 then
		sweepPercent = 0.11
	elseif pop >= 700 then
		sweepPercent = 0.13
	elseif pop >= 500 then
		sweepPercent = 0.15
	elseif pop >= 350 then
		sweepPercent = 0.18
	end
	local sweepMin = 18
	local sweepMax = 160
	if pop >= 1400 then
		sweepMin, sweepMax = 10, 110
	elseif pop >= 900 then
		sweepMin, sweepMax = 12, 120
	elseif pop >= 500 then
		sweepMin, sweepMax = 14, 130
	end
	local sweepBudget = math.clamp(math.ceil(total * sweepPercent), sweepMin, sweepMax)
	if pop <= 220 then
		sweepBudget = math.min(total, math.max(sweepBudget, 42))
	end
	local b0, b1, b2 = DistributeLod3Way(sweepBudget, n0, n1, n2, 0.74, 0.2, 0.06)

	local function processList(list: {Model}, budget: number, cursorIdx: number): number
		if budget <= 0 or #list <= 0 then
			return 0
		end
		local cur = decisionLodCursors.Urgent[cursorIdx]
		local processedCount = 0
		for _ = 1, budget do
			if cur > #list then
				cur = 1
			end
			local model = list[cur]
			cur += 1
			local data = model and AllGuests[model] or nil
			if data and not IsInvalidGuest(model, data) and IsUrgentDecisionGuest(data, now) then
				data.UrgentDecisionToken = urgentToken
				processedCount += 1
				pcall(function()
					if RescueGuestFromVoid(data) then
						return
					end
					local baseCad = tonumber(data.GroundSnapCadence) or defaultGroundSnapCadence
					if (not data.NextGroundSnapAt) or now >= data.NextGroundSnapAt then
						data.NextGroundSnapAt = now + baseCad
						SnapGuestToGroundIfFloating(data, 3.0)
					end
					local guestDt = math.clamp(now - (data.LastDecisionProcessAt or now), 0, 1.5)
					data.LastDecisionProcessAt = now
					UpdateNeeds(data, guestDt)
					ProcessGuestDecisionState(data, guestDt)
				end)
			end
		end
		decisionLodCursors.Urgent[cursorIdx] = cur
		return processedCount
	end

	local processed = 0
	processed += processList(decisionLod0, b0, 1)
	processed += processList(decisionLod1, b1, 2)
	processed += processList(decisionLod2, b2, 3)
	return processed
end

function RunMovementStep(moveDt: number, budgetOverride: number?)
	local n0, n1, n2 = #movementLod0, #movementLod1, #movementLod2
	local total = n0 + n1 + n2
	if total <= 0 then
		return
	end
	local budget = math.min(budgetOverride or GetMovementBudget(total, moveDt), total)
	local lod = GuestConfig.LOD or {}
	local active = GuestLodIsEnabled()
	local wH = tonumber(lod.MovementBudgetHigh) or 0.66
	local wM = tonumber(lod.MovementBudgetMedium) or 0.24
	local wL = tonumber(lod.MovementBudgetLow) or 0.10
	local pop = math.max(0, TotalGuestCount)
	if pop >= 1200 then
		wH, wM, wL = 0.91, 0.07, 0.02
	elseif pop >= 850 then
		wH, wM, wL = 0.88, 0.09, 0.03
	elseif pop >= 600 then
		wH, wM, wL = 0.85, 0.11, 0.04
	elseif pop >= 450 then
		wH, wM, wL = 0.82, 0.13, 0.05
	end
	if not active then
		wH, wM, wL = 1, 0, 0
	end
	local b0, b1, b2 = DistributeLod3Way(budget, n0, n1, n2, wH, wM, wL)
	ProcessMovementLodList(movementLod0, b0, 1, moveDt)
	ProcessMovementLodList(movementLod1, b1, 2, moveDt)
	ProcessMovementLodList(movementLod2, b2, 3, moveDt)
end

function RunSkiStep(skiDt: number)
	local n0, n1, n2 = #skiLod0, #skiLod1, #skiLod2
	local total = n0 + n1 + n2
	if total <= 0 then
		return
	end
	local perf = GetPerformanceConfig()
	local budget = math.min(perf.MaxSkiGuestsPerTick, total)
	local pop = math.max(0, TotalGuestCount)
	if pop <= 160 then
		budget = math.min(total, math.max(budget, math.ceil(total * 0.72)))
	elseif pop <= 280 then
		budget = math.min(total, math.max(budget, math.ceil(total * 0.58)))
	elseif pop <= 420 then
		budget = math.min(total, math.max(budget, math.ceil(total * 0.42)))
	elseif pop <= 550 then
		budget = math.min(budget, math.max(16, math.ceil(total * 0.24)))
	elseif pop <= 700 then
		budget = math.min(budget, math.max(14, math.ceil(total * 0.20)))
	elseif pop <= 1000 then
		budget = math.min(budget, math.max(12, math.ceil(total * 0.17)))
	elseif pop <= 1400 then
		budget = math.min(budget, math.max(10, math.ceil(total * 0.15)))
	elseif pop >= 2200 then
		budget = math.min(budget, math.max(12, math.ceil(total * 0.16)))
	elseif pop >= 1800 then
		budget = math.min(budget, math.max(14, math.ceil(total * 0.19)))
	elseif pop >= 1400 then
		budget = math.min(budget, math.max(16, math.ceil(total * 0.22)))
	else
		budget = math.min(budget, math.max(18, math.ceil(total * 0.25)))
	end
	local lod = GuestConfig.LOD or {}
	local active = GuestLodIsEnabled()
	local wH = tonumber(lod.SkiBudgetHigh) or 0.72
	local wM = tonumber(lod.SkiBudgetMedium) or 0.2
	local wL = tonumber(lod.SkiBudgetLow) or 0.08
	if pop >= 1400 then
		wH, wM, wL = 0.90, 0.08, 0.02
	elseif pop >= 900 then
		wH, wM, wL = 0.88, 0.09, 0.03
	elseif pop >= 600 then
		wH, wM, wL = 0.85, 0.11, 0.04
	elseif pop >= 450 then
		wH, wM, wL = 0.82, 0.13, 0.05
	end
	if not active then
		wH, wM, wL = 1, 0, 0
	end
	local b0, b1, b2 = DistributeLod3Way(budget, n0, n1, n2, wH, wM, wL)
	ProcessSkiLodList(skiLod0, b0, 1, skiDt)
	ProcessSkiLodList(skiLod1, b1, 2, skiDt)
	ProcessSkiLodList(skiLod2, b2, 3, skiDt)
end

function RunDecisionStep(dt: number, budgetOverride: number?)
	if _G.SandboxGuestAIFrozen then
		return
	end
	local n0, n1, n2 = #decisionLod0, #decisionLod1, #decisionLod2
	local total = n0 + n1 + n2
	local now = tick()
	local defaultGroundSnapCadence = GetGroundSnapCadenceForPopulation()
	local urgentToken = math.floor(now * 1000 + 0.5)
	local urgentProcessed = ProcessUrgentDecisionGuests(dt, now, defaultGroundSnapCadence, urgentToken)
	if total <= 0 and urgentProcessed <= 0 then
		return
	end
	if total <= 0 then
		return
	end
	local budget = math.min(budgetOverride or total, total)
	local pop = math.max(0, TotalGuestCount)
	if pop >= 1200 then
		budget = math.min(budget, math.max(20, math.ceil(total * 0.22)))
	elseif pop >= 900 then
		budget = math.min(budget, math.max(18, math.ceil(total * 0.25)))
	elseif pop >= 650 then
		budget = math.min(budget, math.max(16, math.ceil(total * 0.29)))
	elseif pop >= 450 then
		budget = math.min(budget, math.max(14, math.ceil(total * 0.34)))
	end
	local lod = GuestConfig.LOD or {}
	local active = GuestLodIsEnabled()
	local wH = tonumber(lod.DecisionBudgetHigh) or 0.6
	local wM = tonumber(lod.DecisionBudgetMedium) or 0.28
	local wL = tonumber(lod.DecisionBudgetLow) or 0.12
	if pop >= 1200 then
		wH, wM, wL = 0.89, 0.09, 0.02
	elseif pop >= 900 then
		wH, wM, wL = 0.86, 0.10, 0.04
	elseif pop >= 650 then
		wH, wM, wL = 0.82, 0.13, 0.05
	elseif pop >= 450 then
		wH, wM, wL = 0.78, 0.16, 0.06
	end
	if not active then
		wH, wM, wL = 1, 0, 0
	end
	local b0, b1, b2 = DistributeLod3Way(budget, n0, n1, n2, wH, wM, wL)
	ProcessDecisionLodList(decisionLod0, b0, 1, dt, now, defaultGroundSnapCadence, urgentToken)
	ProcessDecisionLodList(decisionLod1, b1, 2, dt, now, defaultGroundSnapCadence, urgentToken)
	ProcessDecisionLodList(decisionLod2, b2, 3, dt, now, defaultGroundSnapCadence, urgentToken)
end

local GenericGuestTemplate: Model? = nil
local GenericGuestTemplateFailedAt = 0

function BuildGenericGuestTemplate()
	if GenericGuestTemplate then
		return GenericGuestTemplate
	end
	local now = tick()
	if GenericGuestTemplateFailedAt > 0 and (now - GenericGuestTemplateFailedAt) < 5 then
		return nil
	end
	local desc = GetFallbackAvatarDescription()
	SanitizeGuestDescription(desc)
	local ok, template = pcall(function()
		return Players:CreateHumanoidModelFromDescriptionAsync(desc, Enum.HumanoidRigType.R6)
	end)
	if not ok or not template then
		GenericGuestTemplateFailedAt = now
		return nil
	end
	OptimizeGuestModel(template)
	template.Name = "GuestTemplate"
	template.Archivable = true
	template.Parent = nil
	local hum = template:FindFirstChild("Humanoid")
	if hum then
		hum.WalkSpeed = 26
		hum.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
	end
	GenericGuestTemplateFailedAt = 0
	GenericGuestTemplate = template
	return GenericGuestTemplate
end

function CloneGenericGuestModel(spawnPos: Vector3)
	local template = BuildGenericGuestTemplate()
	if not template then
		return nil
	end
	local model = template:Clone()
	model.Name = "Guest"
	local hum = model:FindFirstChild("Humanoid")
	if hum then
		hum.WalkSpeed = 24
		hum.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
	end
	local groundPos = ResolveWalkableGroundPos(spawnPos, nil, false)
	model:PivotTo(CFrame.new(groundPos))
	model.Parent = GuestsFolder
	local root = model:FindFirstChild("HumanoidRootPart")
	if root then
		ApplyWalkerNetworkOwnership(root)
	end
	return model
end

local origCreateGuestModel = CreateGuestModel
CreateGuestModel = function(player, spawnPos)
	local avatarCfg = GetAvatarCacheConfig()
	local perf = GetPerformanceConfig()
	local totalGuests = GetTotalGuestCount()
	local useGeneric = false
	local preferThreshold = math.max(850, tonumber(avatarCfg.PreferGenericThreshold) or 850)
	local forceThreshold = math.max(1400, tonumber(avatarCfg.ForceGenericThreshold) or 1400)
	if totalGuests >= forceThreshold then
		useGeneric = true
	elseif totalGuests >= preferThreshold then
		local pressure = math.max(RuntimeMovementPressure or 0, RuntimeMoveCommandAgeP95 or 0)
		local extraChance = math.max(0, pressure - perf.MovementPressureSoftLimit) * 0.15
		local genericChance = math.clamp((tonumber(avatarCfg.FallbackGenericChanceWhenBacklogged) or 0.2) * 0.3 + extraChance, 0.05, 0.35)
		useGeneric = math.random() < genericChance
	end
	if useGeneric then
		local genericModel = CloneGenericGuestModel(spawnPos)
		if genericModel then
			genericModel:SetAttribute("RealName", "Guest " .. tostring(math.random(1000, 9999)))
			return genericModel
		end
	end
	return origCreateGuestModel(player, spawnPos)
end

RunService.Heartbeat:Connect(function(step)
	local guestCount = GetTotalGuestCount()
	local perf = GetPerformanceConfig()
	local now = tick()
	movementAccumulator += step
	skiAccumulator += step
	decisionAccumulator += step
	runtimeRefreshAccumulator += step

	if guestCount <= 0 then
		RuntimeMovingGuestCount = 0
		RuntimeMovementBudgetPerTick = 0
		RuntimeMovementPressure = 0
		if runtimeRefreshAccumulator >= math.max(2, GetEffectiveRuntimeCandidateRefreshSeconds(0)) then
			runtimeRefreshAccumulator = 0
			if (#movementLod0 + #movementLod1 + #movementLod2) > 0
				or (#skiLod0 + #skiLod1 + #skiLod2) > 0
				or (#decisionLod0 + #decisionLod1 + #decisionLod2) > 0 then
				RefreshRuntimeCandidates()
				CleanupOccupiedChairs()
			end
		end
		movementAccumulator = 0
		skiAccumulator = 0
		decisionAccumulator = 0
		if now >= nextMovementTelemetryAt then
			nextMovementTelemetryAt = now + 1.5
			RuntimeMoveCommandAgeP95 = 0
			PushMovementTelemetryAttributes()
		end
		return
	end

	if runtimeRefreshAccumulator >= GetEffectiveRuntimeCandidateRefreshSeconds(guestCount) then
		runtimeRefreshAccumulator = 0
		RefreshRuntimeCandidates()
		CleanupOccupiedChairs()
	end

	-- Near-frame movement updates for walkers.
	local movementInterval = GetMovementUpdateInterval(guestCount)
	local movingCount = #movementLod0 + #movementLod1 + #movementLod2
	local movementBudget = GetMovementBudget(movingCount, movementInterval)
	RuntimeMovingGuestCount = movingCount
	RuntimeMovementBudgetPerTick = movementBudget
	if movingCount > 0 and movementBudget > 0 then
		local revisitSeconds = (movingCount / movementBudget) * movementInterval
		RuntimeMovementPressure = math.max(0, revisitSeconds / math.max(0.3, perf.TargetMovementRevisitSeconds))
	else
		RuntimeMovementPressure = 0
	end
	local moveSteps = 0
	while movementAccumulator >= movementInterval and moveSteps < 1 do
		movementAccumulator -= movementInterval
		RunMovementStep(movementInterval, movementBudget)
		moveSteps += 1
	end
	if movementAccumulator > (movementInterval * 2) then
		movementAccumulator = movementInterval * 2
	end
	if now >= nextMovementTelemetryAt then
		local telemGap = 2.25
		if guestCount >= 2200 then
			telemGap = 6.0
		elseif guestCount >= 1600 then
			telemGap = 4.5
		elseif guestCount >= 1100 then
			telemGap = 3.4
		end
		nextMovementTelemetryAt = now + telemGap
		RuntimeMoveCommandAgeP95 = ComputeMoveCommandAgeP95(now)
		PushMovementTelemetryAttributes()
	end
	if RuntimeMovementPressure >= perf.MovementPressureHardLimit and now >= nextMovementPressureWarnAt then
		nextMovementPressureWarnAt = now + 12
	end

	-- Near-frame skiing updates for smooth downhill movement.
	local skiInterval = GetSkiUpdateInterval(guestCount)
	local skiSteps = 0
	while skiAccumulator >= skiInterval and skiSteps < 1 do
		skiAccumulator -= skiInterval
		RunSkiStep(skiInterval)
		skiSteps += 1
	end
	if skiAccumulator > (skiInterval * 2) then
		skiAccumulator = skiInterval * 2
	end

	local decisionInterval = GetAdaptiveDecisionInterval(guestCount)
	if decisionAccumulator < decisionInterval then
		return
	end

	local maxDecisionDt = 0.25
	if guestCount >= 2200 then
		maxDecisionDt = 0.42
	elseif guestCount >= 1600 then
		maxDecisionDt = 0.35
	end
	local dt = math.min(decisionAccumulator, maxDecisionDt)
	decisionAccumulator = 0
	local decidingCount = #decisionLod0 + #decisionLod1 + #decisionLod2
	local decisionBudget = GetDecisionBudget(decidingCount, decisionInterval)
	RunDecisionStep(dt, decisionBudget)
	if decidingCount == 0 and guestCount > 0 then
		RefreshRuntimeCandidates()
	end
end)

-- ============================================================================
-- SPAWNING WAVES
-- ============================================================================
-- TRIM_PRIORITY / NON_TRIMMABLE_STATES live in GuestConfig (see GuestTrimPriority, GuestNonTrimmableStates) to stay under Luau local register limits.

local populationReconcileBusy = false
local PendingSpawnBoost = 0
local PendingTrimBoost = 0

function QueuePopulationBoost(spawnBoost, trimBoost, reason)
	local addSpawn = math.max(0, math.floor(tonumber(spawnBoost) or 0))
	local addTrim = math.max(0, math.floor(tonumber(trimBoost) or 0))
	if addSpawn > 0 then
		local hardCap = GetDirectorConfig().SpawnBacklogHardCap
		PendingSpawnBoost = math.clamp(PendingSpawnBoost + addSpawn, 0, hardCap)
	end
	if addTrim > 0 then
		PendingTrimBoost += addTrim
	end
end

function TrimGuestsFromHotel(ownerUserId, guestList, toTrim)
	if toTrim <= 0 then return 0 end
	local trimP = GuestConfig.GuestTrimPriority
	table.sort(guestList, function(a, b)
		local pa = trimP[a.State] or 99
		local pb = trimP[b.State] or 99
		if pa ~= pb then return pa < pb end
		return (a.Satisfaction or 50) < (b.Satisfaction or 50)
	end)

	local removed = 0
	for _, guestData in ipairs(guestList) do
		if removed >= toTrim then break end
		if guestData and guestData.Model and guestData.Model.Parent and not GuestConfig.GuestNonTrimmableStates[guestData.State] then
			RemoveGuest(guestData)
			removed += 1
		end
	end
	local ownerPlayer = Players:GetPlayerByUserId(ownerUserId)
	if ownerPlayer then
		PushGuestCountToPlayer(ownerPlayer)
	end
	return removed
end

function ReconcilePopulation(options: {[string]: any}?): (number, number)
	if populationReconcileBusy then return 0, 0 end
	populationReconcileBusy = true

	local ok, spawned, trimmed = pcall(function()
		options = options or {}
		local spawnBudget = options.SpawnBudget
		if spawnBudget == nil then spawnBudget = GuestConfig.Spawn.MaxSpawnPerAdjust or 30 end
		local trimBudget = options.TrimBudget
		if trimBudget == nil then trimBudget = GuestConfig.Spawn.MaxTrimPerAdjust or 20 end
		local maxSpawnPerHotel = options.MaxSpawnPerHotelPerAdjust
		if maxSpawnPerHotel == nil then
			maxSpawnPerHotel = GuestConfig.Spawn.MaxSpawnPerHotelPerAdjust or 3
		end
		local spawnCooldown = math.max(0, tonumber(GuestConfig.Spawn.SpawnCooldown) or 0.02)
		local directorCfg = GetDirectorConfig()
		local targetFillAggressiveness = directorCfg.TargetFillAggressiveness
		local spawnWorkers = 1 -- Forced to 1 to stop frame drops when mass-spawning guests

		local totalSpawned = 0
		local totalTrimmed = 0
		for _, player in ipairs(Players:GetPlayers()) do
			CacheFriends(player.UserId)
			local hotels = GetPlayerHotelModels(player)

			-- Clean orphaned guests whose assigned hotel no longer exists.
			if trimBudget > 0 then
				local orphaned = {}
				for _, guestData in ipairs(PlayerGuests[player.UserId] or {}) do
					if guestData.HotelModel and not guestData.HotelModel.Parent and not GuestConfig.GuestNonTrimmableStates[guestData.State] then
						table.insert(orphaned, guestData)
					end
				end
				for _, guestData in ipairs(orphaned) do
					if trimBudget <= 0 then break end
					RemoveGuest(guestData)
					totalTrimmed += 1
					trimBudget -= 1
				end
			end

			local playerHardCap = GetPlayerGuestHardCap(player)
			if playerHardCap > 0 and trimBudget > 0 then
				local playerGuestList = {}
				for _, guestData in ipairs(PlayerGuests[player.UserId] or {}) do
					if guestData and guestData.Model and guestData.Model.Parent then
						table.insert(playerGuestList, guestData)
					end
				end
				local excessGuests = #playerGuestList - playerHardCap
				if excessGuests > 0 then
					local removed = TrimGuestsFromHotel(player.UserId, playerGuestList, math.min(excessGuests, trimBudget))
					totalTrimmed += removed
					trimBudget -= removed
				end
			end

			for _, hotel in ipairs(hotels) do
				if not hotel or not hotel.Parent then continue end
				local hotelKey = GetHotelKey(hotel)
				local targetCount = GetHotelTargetGuests(hotel)
				local hotelGuests = GetHotelGuestList(player.UserId, hotelKey, hotel)
				local currentCount = #hotelGuests
				local remainingPlayerCapacity = math.huge
				if playerHardCap > 0 then
					remainingPlayerCapacity = math.max(0, playerHardCap - GetPlayerGuestCount(player.UserId))
				end

				if currentCount < targetCount and spawnBudget > 0 and remainingPlayerCapacity > 0 then
					local deficit = targetCount - currentCount
					local adaptivePerHotelCap = math.max(
						maxSpawnPerHotel,
						math.clamp(math.ceil(deficit * targetFillAggressiveness), maxSpawnPerHotel, 45)
					)
					local needed = math.min(deficit, spawnBudget, adaptivePerHotelCap, remainingPlayerCapacity)
					for i = 1, needed do
						local data = SpawnGuest(player, hotel)
						if data then
							totalSpawned += 1
							spawnBudget -= 1
						end
						if spawnBudget <= 0 then break end
						-- Yield in controlled batches to keep heartbeat responsive.
						if (i % spawnWorkers) == 0 then
							task.wait(0.05)
						end
					end
				elseif currentCount > targetCount and trimBudget > 0 then
					local toTrim = math.min(currentCount - targetCount, trimBudget)
					local removed = TrimGuestsFromHotel(player.UserId, hotelGuests, toTrim)
					totalTrimmed += removed
					trimBudget -= removed
				end

				if spawnBudget <= 0 and trimBudget <= 0 then
					break
				end
			end
		end
		return totalSpawned, totalTrimmed
	end)

	populationReconcileBusy = false
	if not ok then
		return 0, 0
	end
	return spawned, trimmed
end

function SpawnMorningWave()
	if not IsResortOpen() then
		return
	end
	local hotels = FindBuildingsByType("Hotel")
	local baseSpawn = GuestConfig.Spawn.MaxSpawnPerAdjust or 30
	local baseTrim = GuestConfig.Spawn.MaxTrimPerAdjust or 20
	local totalGuests = GetTotalGuestCount()
	local immediateSpawnBudget = baseSpawn
	if totalGuests < 900 then
		immediateSpawnBudget = math.max(baseSpawn, math.floor(baseSpawn * 2.5))
	elseif totalGuests < 1400 then
		immediateSpawnBudget = math.max(baseSpawn, math.floor(baseSpawn * 1.6))
	end

	-- Morning waves ramp in over several ticks so guests don't pop all at once.
	QueuePopulationBoost(math.floor(baseSpawn * 5), 0, "morning")
	local spawned, trimmed = ReconcilePopulation({
		SpawnBudget = immediateSpawnBudget,
		TrimBudget = baseTrim,
		MaxSpawnPerHotelPerAdjust = GuestConfig.Spawn.MaxSpawnPerHotelPerAdjust or 3,
	})
	local spawnedN = tonumber(spawned) or 0
	local trimmedN = tonumber(trimmed) or 0
	local totalN = tonumber(GetTotalGuestCount()) or 0
end

function SetGuestSleepingAfterMove(guestData: GuestData)
	if not guestData or not guestData.Model or not guestData.Model.Parent then
		return
	end
	guestData.State = STATE.SLEEPING
	guestData.ActionTimer = 0
	ShowSpeech(guestData.Model, "Good night! 🌙", 3)
end

function SendSingleGuestHome(data: GuestData, bulkSleepMode: boolean)
	if not data or data.State == STATE.LEAVING then
		return
	end
	ClearLiftQueueState(data)

	local hotelModel = data.HotelModel
	if not hotelModel or not hotelModel.Parent then
		RemoveGuest(data)
		return
	end

	local hotelPos = ResolveHotelSpawnPos(hotelModel)
	if bulkSleepMode then
		-- Large-pop optimization: snap guests to a safe exterior hotel point instead of the cabin interior.
		data.MoveTarget = nil
		data.Waypoints = nil
		data.MoveCallback = nil
		data.Root.CFrame = CFrame.new(hotelPos)
		data.State = STATE.SLEEPING
		data.ActionTimer = 0
		return
	end

	data.State = STATE.GOING_TO_HOTEL
	MoveGuestTo(data, hotelPos, SetGuestSleepingAfterMove)
end

function SendGuestsHome()
	local bulkSleepMode = GetTotalGuestCount() > 350
	for _, data in pairs(AllGuests) do
		SendSingleGuestHome(data, bulkSleepMode)
	end
	-- Night should naturally be quieter; trim toward current night target.
	local _, trimmed = ReconcilePopulation({
		SpawnBudget = 0,
		TrimBudget = (GuestConfig.Spawn.MaxTrimPerAdjust or 20) * 4,
	})
end

-- ============================================================================
-- EVENT CONNECTIONS
-- ============================================================================

local hasSpawnedInitial = false

function SetPlayerTicketBasePrice(player, requestedPrice)
	if not player then return nil end

	local cfg = GetDynamicTicketPricingConfig()
	local requestedAuto = nil
	local rawPrice = requestedPrice
	if type(requestedPrice) == "table" then
		if requestedPrice.auto ~= nil then
			requestedAuto = requestedPrice.auto == true
		end
		rawPrice = requestedPrice.price
	end

	local state = GetTicketPricingState(player.UserId)
	if not state then return nil end

	if requestedAuto == true then
		state.dynamicEnabled = cfg.Enabled == true
		state.lastManualUpdate = tick()
		TicketPricingSignalsCache[player.UserId] = nil
		PushTicketPriceAttributes(player, state)
		return state.basePrice, state.dynamicEnabled and "auto_on" or "auto_unavailable"
	end

	if requestedAuto == false and rawPrice == nil then
		state.dynamicEnabled = false
		state.lastManualUpdate = tick()
		TicketPricingSignalsCache[player.UserId] = nil
		PushTicketPriceAttributes(player, state)
		return state.basePrice, "auto_off"
	end

	local parsed = tonumber(rawPrice)
	if not parsed then return nil end

	parsed = math.floor(parsed + 0.5)
	parsed = math.clamp(parsed, cfg.MinPrice, cfg.MaxPrice)

	state.basePrice = parsed
	state.currentPrice = parsed
	state.dynamicEnabled = false
	state.lastManualUpdate = tick()
	TicketPricingSignalsCache[player.UserId] = nil

	PushTicketPriceAttributes(player, state)
	return parsed, "manual"
end

-- Keep top-bar guest counters in sync for each player.
task.spawn(function()
	while true do
		task.wait(2)
		PushGuestCountsToAllPlayers()
	end
end)

-- Dynamic ticket pricing loop.
task.spawn(function()
	while true do
		local cfg = GetDynamicTicketPricingConfig()
		task.wait(cfg.UpdateInterval)
		for _, player in ipairs(Players:GetPlayers()) do
			RecomputeOwnerTicketPrice(player.UserId, false)
		end
	end
end)

-- Continuous population director:
-- Keeps population tied to building capacity + time-of-day demand curve.
task.spawn(function()
	while true do
		task.wait(GuestConfig.Spawn.PopulationAdjustInterval or 8)
		if hasSpawnedInitial then
			local resortOpen = IsResortOpen()
			local rawBaseSpawn = GuestConfig.Spawn.MaxSpawnPerAdjust or 30
			local totalGuests = GetTotalGuestCount()
			local paceScale = 1.0
			local movementPressure = RuntimeMovementPressure or 0
			local emergencyTrim = 0
			if movementPressure >= 2.0 then
				paceScale = 0.05
				emergencyTrim = math.max(18, math.floor((GuestConfig.Spawn.MaxTrimPerAdjust or 20) * 3.5))
			elseif movementPressure >= 1.65 then
				paceScale = 0.12
				emergencyTrim = math.max(12, math.floor((GuestConfig.Spawn.MaxTrimPerAdjust or 20) * 2.2))
			elseif movementPressure >= 1.35 then
				paceScale = 0.22
				emergencyTrim = math.max(8, math.floor((GuestConfig.Spawn.MaxTrimPerAdjust or 20) * 1.4))
			elseif movementPressure >= 1.15 then
				paceScale = 0.4
			elseif totalGuests >= 2200 then
				paceScale = 0.5
			elseif totalGuests >= 1600 then
				paceScale = 0.7
			end
			local baseSpawn = math.max(0, math.floor(rawBaseSpawn * paceScale))
			local baseTrim = GuestConfig.Spawn.MaxTrimPerAdjust or 20
			if not resortOpen then
				baseSpawn = 0
				PendingSpawnBoost = 0
			end
			local burstSpawn = math.min(PendingSpawnBoost, math.max(0, math.floor(baseSpawn * 1.2)))
			local burstTrim = math.min(PendingTrimBoost, baseTrim)
			if burstSpawn > 0 then
				PendingSpawnBoost -= burstSpawn
			end
			if burstTrim > 0 then
				PendingTrimBoost -= burstTrim
			end

			local spawned, trimmed = ReconcilePopulation({
				SpawnBudget = baseSpawn + burstSpawn,
				TrimBudget = baseTrim,
				MaxSpawnPerHotelPerAdjust = GuestConfig.Spawn.MaxSpawnPerHotelPerAdjust or 3,
			})
		end
	end
end)

-- DayCycle integration
local DayCycleEvent = ServerScriptService:FindFirstChild("DayCycleEvent")
if DayCycleEvent and DayCycleEvent:IsA("BindableEvent") then
	DayCycleEvent.Event:Connect(function(phase)
		if phase == "Morning" then
			if IsResortOpen() then
				SpawnMorningWave()
				NotifyAllPlayers("Info", "Morning Rush", "Guests are arriving for the day.", 4)
			end
		elseif phase == "Evening" then
			if not IsResortOpen() then
				return
			end
			local baseSpawn = GuestConfig.Spawn.MaxSpawnPerAdjust or 30
			QueuePopulationBoost(math.floor(baseSpawn * 1.5), 0, "evening-peak")
			local spawned = ReconcilePopulation({
				SpawnBudget = baseSpawn,
				TrimBudget = 0,
				MaxSpawnPerHotelPerAdjust = GuestConfig.Spawn.MaxSpawnPerHotelPerAdjust or 3,
			})
			NotifyAllPlayers("Warning", "Peak Hours", "Peak hours started. Guest traffic is at its highest.", 4.5)
		elseif phase == "Night" then
			NotifyAllPlayers("Info", "Nightfall", "Guest traffic is winding down for the night.", 3.5)
			SendGuestsHome()
		end
	end)
end

-- Watch for new buildings being placed (so guests spawn from newly placed hotels)
function OnBuildingAdded(obj)
	if not obj:IsA("Model") then return end
	task.wait(0.5) -- Let attributes settle
	MarkWalkableGroundCacheDirty()
	InvalidateBuildingTypeCache()

	-- Invalidate lift→slope cache any time a new building appears
	InvalidateLiftSlopeCache()
	-- DO NOT reset TicketPricingSignalsCache here; doing so resets demand to 1.0, 
	-- which artificially inflates hotel capacity and causes a spawn surge for EVERY placed object.
	-- Only reset bed capacity snapshot for hotel-type buildings to prevent
	-- non-hotel placements (e.g. lifts) from triggering guest spawn bursts
	local objType = obj:GetAttribute("Type")
	local _, itemCfg = GetConfigItemForModel(obj)
	local isHotelEarly = objType == "House"
		or objType == "Hotel"
		or (itemCfg and (itemCfg.Type == "House" or itemCfg.Type == "Hotel"))
	if isHotelEarly then
		TotalHotelBedCapacitySnapshot.at = 0
	end

	if isHotelEarly and hasSpawnedInitial then
		local baseSpawn = GuestConfig.Spawn.MaxSpawnPerAdjust or 30
		QueuePopulationBoost(baseSpawn, 0, "new-hotel")
		ReconcilePopulation({
			SpawnBudget = baseSpawn,
			TrimBudget = 0,
			MaxSpawnPerHotelPerAdjust = GuestConfig.Spawn.MaxSpawnPerHotelPerAdjust or 3,
		})
	end
end

local placed = GetPlacedObjects()
if placed then
	placed.ChildAdded:Connect(OnBuildingAdded)
	placed.ChildRemoved:Connect(function()
		MarkWalkableGroundCacheDirty()
		InvalidateBuildingTypeCache()
		InvalidateLiftSlopeCache()
	end)
end
-- Also watch if PlacedObjects itself gets created later
Workspace.ChildAdded:Connect(function(child)
	if child.Name == "PlacedObjects" then
		InvalidateBuildingTypeCache()
		child.ChildAdded:Connect(OnBuildingAdded)
		child.ChildRemoved:Connect(function()
			MarkWalkableGroundCacheDirty()
			InvalidateBuildingTypeCache()
			InvalidateLiftSlopeCache()
		end)
	end
end)

-- TerrainReady: spawn initial guests after world loads
-- PATCHED: Wait for _G.SessionFullyReady so buildings/slopes are restored before spawning
local TerrainReady = Events:FindFirstChild("TerrainReady")
if TerrainReady and TerrainReady:IsA("BindableEvent") then
	TerrainReady.Event:Connect(function()
		task.spawn(function()
			local waitStart = tick()
			while not _G.SessionFullyReady and (tick() - waitStart) < 60 do
				task.wait(1)
			end
			task.wait(2)
			ConnectSystems()
			if not hasSpawnedInitial then
				hasSpawnedInitial = true
				SpawnMorningWave()
			end
		end)
	end)
end

TicketPriceEvent.OnServerEvent:Connect(function(player, requestedPrice)
	if not player or not player.Parent then return end
	local applied, mode = SetPlayerTicketBasePrice(player, requestedPrice)
	if applied then
		local cfg = GetDynamicTicketPricingConfig()
		local appliedN = math.floor(tonumber(applied) or 0)
		local minPriceN = math.floor(tonumber(cfg.MinPrice) or 0)
		local maxPriceN = math.floor(tonumber(cfg.MaxPrice) or 0)
		if mode == "auto_on" then
			NotifyPlayer(player, "Success", "Auto Ticket Pricing", "Automatic ticket pricing is back on.", 3)
		elseif mode == "auto_unavailable" then
			NotifyPlayer(player, "Warning", "Auto Ticket Pricing", "Automatic ticket pricing is disabled in this server configuration.", 3)
		elseif mode == "auto_off" then
			NotifyPlayer(player, "Success", "Auto Ticket Pricing", "Automatic ticket pricing is off.", 3)
		else
			NotifyPlayer(
				player,
				"Success",
				"Ticket Price Set",
				"Lift ticket price locked to $" .. tostring(appliedN) .. " (range $" .. tostring(minPriceN) .. "-$" .. tostring(maxPriceN) .. "). Auto pricing is disabled until you re-enable it.",
				3.5
			)
		end
	else
		NotifyPlayer(player, "Warning", "Invalid Ticket Price", "Enter a valid number for ticket price.", 3)
	end
end)

-- Player management
PlayerGuests.__GuestBoostSignalBound = PlayerGuests.__GuestBoostSignalBound or {}

local function bindGuestBoostSignals(player)
	if not player or PlayerGuests.__GuestBoostSignalBound[player.UserId] then
		return
	end
	PlayerGuests.__GuestBoostSignalBound[player.UserId] = true
	for _, attrName in ipairs({ "CodeGuestBoostActive", "CodeGuestBoostEndTime", "CodeGuestBoostMultiplier" }) do
		player:GetAttributeChangedSignal(attrName):Connect(function()
			InvalidateGuestMultiplierCache(player.UserId)
			task.defer(function()
				if player.Parent then
					PushGuestCountToPlayer(player)
				end
			end)
		end)
	end
end

for _, existingPlayer in ipairs(Players:GetPlayers()) do
	CacheFriends(existingPlayer.UserId)
	bindGuestBoostSignals(existingPlayer)
	PlayerGuests[existingPlayer.UserId] = PlayerGuests[existingPlayer.UserId] or {}
	InitTicketPricingForPlayer(existingPlayer)
	RecomputeOwnerTicketPrice(existingPlayer.UserId, true)
	PushGuestCountToPlayer(existingPlayer)
end

Players.PlayerAdded:Connect(function(player)
	InvalidateGuestMultiplierCache(player.UserId)
	CacheFriends(player.UserId)
	bindGuestBoostSignals(player)
	PlayerGuests[player.UserId] = PlayerGuests[player.UserId] or {}
	InitTicketPricingForPlayer(player)
	RecomputeOwnerTicketPrice(player.UserId, true)
	PushGuestCountToPlayer(player)

	-- Spawn guests after buildings have loaded
	-- PATCHED: Wait for _G.SessionFullyReady instead of fixed 12s delay
	task.spawn(function()
		local waitStart = tick()
		while not _G.SessionFullyReady and (tick() - waitStart) < 60 do
			task.wait(1)
		end
		task.wait(3)
		if not hasSpawnedInitial then
			hasSpawnedInitial = true
			ConnectSystems()
			SpawnMorningWave()
		elseif #(PlayerGuests[player.UserId] or {}) == 0 then
			-- Player joined late, spawn their guests
			SpawnMorningWave()
		end
	end)
end)

-- FALLBACK: If nothing has triggered spawning after 30 seconds, force it
task.delay(30, function()
	if not hasSpawnedInitial then
		hasSpawnedInitial = true
		ConnectSystems()
		SpawnMorningWave()
	end
end)

FriendRotationQueue.__RotationCursor = FriendRotationQueue.__RotationCursor or {}

function getFriendRotationPool(userId)
	local ownerId = tonumber(userId)
	if not ownerId or ownerId <= 0 then
		return {}
	end

	local cached = FriendCache[ownerId]
	if type(cached) ~= "table" or #cached <= 1 then
		task.spawn(CacheFriends, ownerId)
	end

	local seen = {}
	local pool = {}
	for _, rawId in ipairs(type(cached) == "table" and cached or {}) do
		local friendId = tonumber(rawId)
		if friendId and friendId > 0 and friendId ~= ownerId and not seen[friendId] then
			seen[friendId] = true
			table.insert(pool, friendId)
		end
	end

	if #pool == 0 then
		table.insert(pool, ownerId)
	end

	return pool
end

function trimFriendRecentHistory(userId, poolSize)
	local recent = FriendRecentUsed[userId]
	if type(recent) ~= "table" then
		recent = {}
		FriendRecentUsed[userId] = recent
	end

	local seen = {}
	local trimmed = {}
	for _, rawId in ipairs(recent) do
		local friendId = tonumber(rawId)
		if friendId and friendId > 0 and not seen[friendId] then
			seen[friendId] = true
			table.insert(trimmed, friendId)
		end
	end

	local keepCount = math.max(0, math.min(#trimmed, math.max(0, math.min(poolSize - 1, 8))))
	while #trimmed > keepCount do
		table.remove(trimmed, 1)
	end

	FriendRecentUsed[userId] = trimmed
	return trimmed
end

function BuildFriendRotationQueue(userId)
	local ownerId = tonumber(userId)
	if not ownerId or ownerId <= 0 then
		return { userId }
	end

	local pool = getFriendRotationPool(ownerId)
	local recent = trimFriendRecentHistory(ownerId, #pool)
	local recentLookup = {}
	for _, recentId in ipairs(recent) do
		recentLookup[recentId] = true
	end

	local nonRecent = {}
	local fallbackRecent = {}
	for _, friendId in ipairs(pool) do
		if recentLookup[friendId] then
			table.insert(fallbackRecent, friendId)
		else
			table.insert(nonRecent, friendId)
		end
	end

	local orderedPool = (#nonRecent > 0) and nonRecent or pool
	local rotationBase = FriendRotationQueue.__RotationCursor[ownerId] or 0
	local rotationOffset = (#orderedPool > 0) and (rotationBase % #orderedPool) or 0
	local queue = {}
	for index = 1, #orderedPool do
		local rotatedIndex = ((index + rotationOffset - 1) % #orderedPool) + 1
		table.insert(queue, orderedPool[rotatedIndex])
	end
	for _, friendId in ipairs(fallbackRecent) do
		table.insert(queue, friendId)
	end

	FriendRotationQueue[ownerId] = queue
	return queue
end

function GetNextFriendId(userId)
	local ownerId = tonumber(userId)
	if not ownerId or ownerId <= 0 then
		return userId
	end

	local queue = FriendRotationQueue[ownerId]
	if type(queue) ~= "table" or #queue == 0 then
		queue = BuildFriendRotationQueue(ownerId)
	end
	if type(queue) ~= "table" or #queue == 0 then
		return ownerId
	end

	local friendId = tonumber(table.remove(queue, 1)) or ownerId
	FriendRotationQueue[ownerId] = queue

	local pool = getFriendRotationPool(ownerId)
	local recent = trimFriendRecentHistory(ownerId, #pool)
	for index = #recent, 1, -1 do
		if recent[index] == friendId then
			table.remove(recent, index)
		end
	end
	if friendId > 0 then
		table.insert(recent, friendId)
		trimFriendRecentHistory(ownerId, #pool)
	end

	local rotationSize = math.max(1, #pool)
	FriendRotationQueue.__RotationCursor[ownerId] = ((FriendRotationQueue.__RotationCursor[ownerId] or 0) + 1) % rotationSize
	if #queue == 0 then
		BuildFriendRotationQueue(ownerId)
	end

	return friendId
end

Players.PlayerRemoving:Connect(function(player)
	InvalidateGuestMultiplierCache(player.UserId)
	-- Clean up guests
	local guests = PlayerGuests[player.UserId]
	if guests then
		for _, data in ipairs(guests) do
			if data.Model and data.Model.Parent then
				data.Model:Destroy()
			end
			if AllGuests[data.Model] then
				AllGuests[data.Model] = nil
				TotalGuestCount = math.max(0, TotalGuestCount - 1)
			end
		end
	end
	PlayerGuests[player.UserId] = nil
	TicketPricingState[player.UserId] = nil
	TicketPricingSignalsCache[player.UserId] = nil
	FriendRotationQueue[player.UserId] = nil
	FriendRecentUsed[player.UserId] = nil
	FriendRotationQueue.__RotationCursor[player.UserId] = nil
	PlayerGuests.__GuestBoostSignalBound[player.UserId] = nil
end)

local EntitlementEvents = ReplicatedStorage:FindFirstChild("EntitlementEvents")
local ServerEntitlementChanged = EntitlementEvents and EntitlementEvents:FindFirstChild("ServerEntitlementChanged")
if ServerEntitlementChanged and ServerEntitlementChanged:IsA("BindableEvent") then
	ServerEntitlementChanged.Event:Connect(function(payload)
		local userId = type(payload) == "table" and tonumber(payload.userId) or nil
		if not userId then
			return
		end
		InvalidateGuestMultiplierCache(userId)
		local player = Players:GetPlayerByUserId(userId)
		if player then
			PushGuestCountToPlayer(player)
		end
	end)
end

MarketplaceService.PromptGamePassPurchaseFinished:Connect(function(player, passId, wasPurchased)
	if wasPurchased and passId == DOUBLE_GUESTS_PASS_ID then
		InvalidateGuestMultiplierCache(player.UserId)
		PushGuestCountToPlayer(player)
	end
end)

-- Client UI interaction
GuestUpdateEvent.OnServerEvent:Connect(function(player, action, guestModel, extraData)
	if not guestModel or not guestModel:IsDescendantOf(GuestsFolder) then return end
	local data = AllGuests[guestModel]
	if not data then return end
	if data.OwnerId ~= player.UserId then return end

	if action == "EquipSkis" then
		data.HasSkis = true
		guestModel:SetAttribute("HasSkis", true)
	elseif action == "UnequipSkis" then
		data.HasSkis = false
		guestModel:SetAttribute("HasSkis", false)
	elseif action == "Dismiss" then
		RemoveGuest(data)
	end
end)

-- ============================================================================
-- NAMETAG CREATION
-- ============================================================================
local GuestTagLabels = {} -- { [model] = { label = TextLabel, personality = string } }

function CreateNameTag(model, personalityName)
	-- Nametags disabled: too many floating labels with large guest counts
	return
end

-- Single updater loop (cheaper than one loop/thread per guest)
function GetNameTagUpdateInterval(guestCount)
	if guestCount >= 1500 then return 8 end
	if guestCount >= 1000 then return 6 end
	if guestCount >= 700 then return 4 end
	if guestCount >= 400 then return 2.5 end
	return 1
end

function IsNearAnyPlayer(position, maxDistance)
	local distSqLimit = maxDistance * maxDistance
	for _, player in ipairs(Players:GetPlayers()) do
		local char = player.Character
		local root = char and char:FindFirstChild("HumanoidRootPart")
		if root then
			local offset = root.Position - position
			local distSq = (offset.X * offset.X) + (offset.Y * offset.Y) + (offset.Z * offset.Z)
			if distSq <= distSqLimit then
				return true
			end
		end
	end
	return false
end

task.spawn(function()
	while true do
		local totalGuests = GetTotalGuestCount()
		task.wait(GetNameTagUpdateInterval(totalGuests))
		local dynamicUpdatesAllowed = totalGuests <= 450
		for model, tagData in pairs(GuestTagLabels) do
			local label = tagData and tagData.label
			if not model or not model.Parent or not label or not label.Parent then
				GuestTagLabels[model] = nil
			else
				local rootPart = model.PrimaryPart or model:FindFirstChild("HumanoidRootPart")
				if dynamicUpdatesAllowed and rootPart and IsNearAnyPlayer(rootPart.Position, 180) then
					local state = model:GetAttribute("State") or "Idle"
					local sat = model:GetAttribute("Satisfaction") or 50
					local emoji = sat >= 80 and "😊" or sat >= 50 and "😐" or "😟"
					local nextText = (tagData.personality or "Guest") .. " • " .. state .. " " .. emoji
					if label.Text ~= nextText then
						label.Text = nextText
					end
				end
			end
		end
	end
end)

-- Hook nametag creation into spawn
local origSpawnGuest = SpawnGuest
function ShouldCreateNameTagForNewGuest()
	local total = GetTotalGuestCount()
	if total <= 420 then
		return true
	end
	if total >= 1200 then
		return false
	end
	local chance = math.clamp(420 / math.max(1, total), 0.12, 0.95)
	return math.random() < chance
end

SpawnGuest = function(player, hotel)
	local data = origSpawnGuest(player, hotel)
	if data and data.Model then
		if ShouldCreateNameTagForNewGuest() then
			CreateNameTag(data.Model, data.Personality)
		end
	end
	return data
end

-- ─── TIP FLOAT HELPER ──────────────────────────────────────────────────────
-- Fires the TipFloat event so guestclient shows a "+$X 💰" label above the guest.
-- Called whenever a guest pays for something.
function FireTipFloat(guestModel, amount)
	if not guestModel or not guestModel.Parent then return end
	if not TipFloatEvent then return end
	local dispAmt = math.floor(amount + 0.5)
	if dispAmt <= 0 then return end
	for _, player in ipairs(Players:GetPlayers()) do
		pcall(function()
			TipFloatEvent:FireClient(player, guestModel, dispAmt)
		end)
	end
end

-- Wrap ProcessEating to fire tip float when the guest pays
local _origProcessEating = ProcessEating
ProcessEating = function(data, dt)
	local paidBefore = data._eatPaid
	_origProcessEating(data, dt)
	-- SpendMoney is called inside when ActionTimer > 8 and data.Hunger == 100
	if not paidBefore and data.State == STATE.IDLE and data.Hunger >= 99 then
		data._eatPaid = true
		local econ = GuestConfig.Economy
		local spending = econ and econ.Spending and econ.Spending.Food or {Base = 15}
		local amt = (spending.Base or 15) + math.random(0, (spending.Range or 20))
		FireTipFloat(data.Model, amt)
	elseif data.State ~= STATE.EATING then
		data._eatPaid = nil
	end
end

-- Wrap ProcessRenting to fire tip float when the guest pays
local _origProcessRenting = ProcessRenting
ProcessRenting = function(data, dt)
	local hadSkis = data.HasSkis
	_origProcessRenting(data, dt)
	if not hadSkis and data.HasSkis then
		local econ = GuestConfig.Economy
		local spending = econ and econ.Spending and econ.Spending.Rental or {Base = 25}
		local amt = (spending.Base or 25) + math.random(0, (spending.Range or 30))
		FireTipFloat(data.Model, amt)
	end
end

-- ─── SANDBOX MODE HOOKS ──────────────────────────────────────────────────────
_G.SandboxGuestAIFrozen = false
_G.SandboxGuestsFrozen = false

-- Expose spawn helper — SandboxServer fires SpawnGuest for a player's first hotel
_G.SandboxSpawnGuests = function(count)
	count = math.clamp(tonumber(count) or 5, 1, 200)
	local spawned = 0
	for _, player in ipairs(Players:GetPlayers()) do
		if spawned >= count then break end
		local hotels = GetPlayerHotelModels(player)
		if #hotels > 0 then
			for i = 1, math.min(count - spawned, 10) do
				local hotel = hotels[math.random(1, #hotels)]
				pcall(SpawnGuest, player, hotel)
				spawned += 1
				if spawned >= count then break end
			end
		end
	end
end

-- Poll ServerScriptService attribute set by sandboxserver as fallback
task.spawn(function()
	while true do
		local reqCount = ServerScriptService:GetAttribute("SandboxSpawnRequest")
		if reqCount and reqCount > 0 then
			ServerScriptService:SetAttribute("SandboxSpawnRequest", 0)
			if _G.SandboxSpawnGuests then _G.SandboxSpawnGuests(reqCount) end
		end
		local clearReq = ServerScriptService:GetAttribute("SandboxClearGuests")
		if clearReq then
			ServerScriptService:SetAttribute("SandboxClearGuests", false)
			for model, data in pairs(AllGuests) do
				pcall(RemoveGuest, data)
			end
		end
		task.wait(0.5)
	end
end)

_G.SandboxForceGuestsToSki = function()--why is bro using an alt 
	for model, data in pairs(AllGuests) do
		if data.State ~= STATE.RIDING_LIFT then
			data.HasSkis = true
			data.State = STATE.DECIDING
			data.WantsBreak = false
			data.Energy = 100
			data.Hunger = 100
		end
	end
end

_G.SandboxResetLiftQueues = function()
	for model, data in pairs(AllGuests) do
		if data.State == STATE.WAITING_LIFT then
			ClearLiftQueueState(data)
			data.State = STATE.DECIDING
		end
	end
end
