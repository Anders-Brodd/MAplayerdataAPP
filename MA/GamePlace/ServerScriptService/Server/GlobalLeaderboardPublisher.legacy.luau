local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local SlotData = ReplicatedStorage:WaitForChild("SlotData")
local UserIdValue = SlotData:WaitForChild("UserId")
local SlotNumValue = SlotData:WaitForChild("SlotNum")
local ResortNameValue = SlotData:WaitForChild("ResortName")

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

local LegacyGameDataStore = DataStoreService:GetDataStore("TycoonGameData")
local GameDataStore = if CanonicalProfile
	then CanonicalProfile.CreateSlotStoreProxy(LegacyGameDataStore, "TycoonGameData", "GameData")
	else LegacyGameDataStore
local LegacyBuildingStore = DataStoreService:GetDataStore("TycoonBuildings")
local BuildingStore = if CanonicalProfile
	then CanonicalProfile.CreateSlotStoreProxy(LegacyBuildingStore, "TycoonBuildings", "Buildings")
	else LegacyBuildingStore
local RatingStore = DataStoreService:GetDataStore("ResortRating_v4")
local LegacyRatingStore = DataStoreService:GetDataStore("ResortRating_v3")
local LegacyRatingStoreUnavailable = false
local MetaStore = DataStoreService:GetDataStore("LobbyLeaderboardMeta_v1")

local OrderedStores = {
	Richest = DataStoreService:GetOrderedDataStore("LobbyRichest_v1"),
	BiggestResort = DataStoreService:GetOrderedDataStore("LobbyBiggestResort_v1"),
	MostLifts = DataStoreService:GetOrderedDataStore("LobbyMostLifts_v1"),
	MostSlopes = DataStoreService:GetOrderedDataStore("LobbyMostSlopes_v1"),
	MostGuests = DataStoreService:GetOrderedDataStore("LobbyMostGuests_v1"),
	BestRating = DataStoreService:GetOrderedDataStore("LobbyBestRating_v1"),
}

local PUBLISH_INTERVAL = 300
local INITIAL_PUBLISH_DELAY = 20
local DEFAULT_RATING = 2.5
local RATING_ORDERED_SCALE = 1000

local function normalizeResortName(value)
	if value == nil then
		return nil
	end
	local cleaned = tostring(value)
	cleaned = cleaned:gsub("^%s+", ""):gsub("%s+$", "")
	if cleaned == "" then
		return nil
	end
	return cleaned
end

-- DS request reduction: per-session caches so publishCurrentResort never reads
-- GameData or Buildings from DataStore, and only re-reads rating every 5 minutes.
local _cachedRatingData = nil
local _cachedRatingAt   = 0
local _cachedPrevMostGuests  = nil
local _cachedPrevBestRating  = nil
local RATING_CACHE_TTL = 300  -- re-read rating from DS at most once per 5 minutes


local function buildFallbackResortName(player, slotNum)
	local ownerName = player and ((player.DisplayName ~= "" and player.DisplayName) or player.Name)
	if ownerName and ownerName ~= "" then
		return string.format("%s's Resort", ownerName)
	end
	return "Resort " .. tostring(slotNum)
end

local function safeGetAsync(store, key)
	local ok, result = pcall(function()
		return store:GetAsync(key)
	end)
	if ok then
		return result
	end
	return nil
end

local function safeSetAsync(store, key, value)
	local ok, result = pcall(function()
		store:SetAsync(key, value)
	end)
	if not ok then
		return false
	end
	return true
end

local function shouldDisableLegacyStore(err)
	local message = string.lower(tostring(err or ""))
	return string.find(message, "deleted", 1, true) ~= nil
		or string.find(message, "error code: 49", 1, true) ~= nil
end

local function tryReadLegacyRating(key)
	if LegacyRatingStoreUnavailable then
		return nil
	end
	local ok, result = pcall(function()
		return LegacyRatingStore:GetAsync(key)
	end)
	if ok then
		return type(result) == "table" and result or nil
	end
	if shouldDisableLegacyStore(result) then
		LegacyRatingStoreUnavailable = true
		warn("[GlobalLeaderboardPublisher] Legacy rating store unavailable (deleted). Disabling v3 fallback reads.")
	end
	return nil
end

local function getRatingDataWithFallback(userId, slotNum)
	local slotKey = string.format("Rating_%d_Slot_%d", userId, slotNum)
	local legacyUserKey = "Rating_" .. tostring(userId)

	local ratingData = safeGetAsync(RatingStore, slotKey)
	if type(ratingData) == "table" then
		return ratingData
	end

	ratingData = safeGetAsync(RatingStore, legacyUserKey)
	if type(ratingData) == "table" then
		return ratingData
	end

	local legacyRating = tryReadLegacyRating(slotKey) or tryReadLegacyRating(legacyUserKey)
	if type(legacyRating) == "table" then
		local migrated = {
			Rating = tonumber(legacyRating.Rating) or DEFAULT_RATING,
			Stats = type(legacyRating.Stats) == "table" and legacyRating.Stats or {},
			LastPlayed = tonumber(legacyRating.LastPlayed) or os.time(),
		}
		safeSetAsync(RatingStore, slotKey, migrated)
		return migrated
	end

	return {}
end

local function getResortContext()
	local userId = tonumber(UserIdValue.Value) or 0
	local slotNum = tonumber(SlotNumValue.Value) or 0
	if userId <= 0 or slotNum <= 0 then
		return nil
	end

	return {
		UserId = userId,
		SlotNum = slotNum,
		ResortKey = string.format("Resort_%d_%d", userId, slotNum),
		ResortName = normalizeResortName(ResortNameValue.Value),
	}
end

local function analyzeBuildings(buildingData)
	local stats = {
		TotalObjects = 0,
		Lifts = 0,
		Slopes = 0,
	}

	if type(buildingData) ~= "table" then
		return stats
	end

	for _, objectData in ipairs(buildingData) do
		if type(objectData) == "table" then
			stats.TotalObjects += 1
			local itemType = objectData.Type
			if itemType == "Slope" then
				stats.Slopes += 1
			elseif itemType == "TwoPoint" or itemType == "Carpet" then
				stats.Lifts += 1
			end
		end
	end

	return stats
end

local function getCurrentCash()
	local serverMoney = tonumber(ServerScriptService:GetAttribute("ServerMoney"))
	if serverMoney then
		return serverMoney
	end

	local player = Players:GetPlayers()[1]
	local leaderstats = player and player:FindFirstChild("leaderstats")
	local cashValue = leaderstats and (leaderstats:FindFirstChild("Cash") or leaderstats:FindFirstChild("Money"))
	return tonumber(cashValue and cashValue.Value) or 0
end

local function getPreviousOrderedValue(store, key)
	return tonumber(safeGetAsync(store, key))
end

local function getCurrentRating(player, ratingData)
	local leaderstats = player and player:FindFirstChild("leaderstats")
	local ratingValue = leaderstats and leaderstats:FindFirstChild("Rating")
	local liveRating = tonumber(ratingValue and ratingValue.Value)
	if liveRating then
		return liveRating, true
	end

	local storedRating = tonumber(type(ratingData) == "table" and ratingData.Rating)
	if storedRating then
		return storedRating, true
	end

	return DEFAULT_RATING, false
end

local function getCurrentRatingStats(player, ratingData)
	local liveRatingSystem = rawget(_G, "RatingSystem")
	if player and type(liveRatingSystem) == "table" and type(liveRatingSystem.GetStats) == "function" then
		local ok, liveStats = pcall(liveRatingSystem.GetStats, player)
		if ok and type(liveStats) == "table" then
			return liveStats
		end
	end

	local storedStats = type(ratingData) == "table" and type(ratingData.Stats) == "table" and ratingData.Stats
	if type(storedStats) == "table" then
		return storedStats
	end

	return {}
end

local function publishCurrentResort()
	local context = getResortContext()
	if not context then
		return false
	end

	local player = Players:GetPlayers()[1]

	-- Count buildings live from workspace instead of reading from DataStore each cycle
	local buildingStats = { TotalObjects = 0, Lifts = 0, Slopes = 0 }
	local placedObjects = workspace:FindFirstChild("PlacedObjects")
	if placedObjects then
		for _, model in ipairs(placedObjects:GetChildren()) do
			if model:IsA("Model") then
				buildingStats.TotalObjects += 1
				local t = model:GetAttribute("Type")
				if t == "Slope" then
					buildingStats.Slopes += 1
				elseif t == "TwoPoint" or t == "Carpet" then
					buildingStats.Lifts += 1
				end
			end
		end
	end

	-- Use cached ratingData; only re-fetch from DataStore every RATING_CACHE_TTL seconds
	local now = os.time()
	local ratingData
	if _cachedRatingData and (now - _cachedRatingAt) < RATING_CACHE_TTL then
		ratingData = _cachedRatingData
	else
		ratingData = getRatingDataWithFallback(context.UserId, context.SlotNum)
		if type(ratingData) == "table" then
			_cachedRatingData = ratingData
			_cachedRatingAt   = now
		end
	end
	if type(ratingData) == "table" and ratingData.LastPlayed == nil then
		ratingData.LastPlayed = now
	end

	-- ResortName is already in memory via ResortNameValue; no DS read needed
	local resolvedResortName = context.ResortName
	if not resolvedResortName or resolvedResortName == "" then
		resolvedResortName = buildFallbackResortName(player, context.SlotNum)
	end
	context.ResortName = resolvedResortName
	if ResortNameValue.Value ~= resolvedResortName then
		ResortNameValue.Value = resolvedResortName
	end

	local ratingStats = getCurrentRatingStats(player, ratingData)

	-- Cache previous ordered-store peaks per session (fetch once, reuse until we beat them)
	if _cachedPrevMostGuests == nil then
		_cachedPrevMostGuests = getPreviousOrderedValue(OrderedStores.MostGuests, context.ResortKey) or 0
	end
	if _cachedPrevBestRating == nil then
		_cachedPrevBestRating = getPreviousOrderedValue(OrderedStores.BestRating, context.ResortKey)
	end
	local previousBestRating = _cachedPrevBestRating
		and ((_cachedPrevBestRating > 5) and (_cachedPrevBestRating / RATING_ORDERED_SCALE) or _cachedPrevBestRating)
		or nil

	local rawRating, hasRatingSnapshot = getCurrentRating(player, ratingData)
	local cash = math.max(0, getCurrentCash())
	local rating = hasRatingSnapshot and math.clamp(rawRating, 0, 5) or math.clamp(previousBestRating or DEFAULT_RATING, 0, 5)
	local ratingOrderedValue = math.round(rating * RATING_ORDERED_SCALE)
	local totalGuests = math.max(_cachedPrevMostGuests, math.max(0, tonumber(ratingStats.TotalGuests) or 0))
	if totalGuests > _cachedPrevMostGuests then
		_cachedPrevMostGuests = totalGuests  -- keep peak for this session
	end
	local ownerName = player and player.Name or tostring(context.UserId)
	local ownerDisplayName = player and player.DisplayName or ownerName

	local meta = {
		UserId         = context.UserId,
		SlotNum        = context.SlotNum,
		ResortName     = context.ResortName,
		OwnerName      = ownerName,
		OwnerDisplayName = ownerDisplayName,
		Cash           = cash,
		TotalObjects   = buildingStats.TotalObjects,
		Lifts          = buildingStats.Lifts,
		Slopes         = buildingStats.Slopes,
		TotalGuests    = totalGuests,
		Rating         = rating,
		RatingOrderedValue = ratingOrderedValue,
		LastUpdated    = now,
	}

	safeSetAsync(MetaStore,                         context.ResortKey, meta)
	safeSetAsync(OrderedStores.Richest,             context.ResortKey, cash)
	safeSetAsync(OrderedStores.BiggestResort,        context.ResortKey, buildingStats.TotalObjects)
	safeSetAsync(OrderedStores.MostLifts,           context.ResortKey, buildingStats.Lifts)
	safeSetAsync(OrderedStores.MostSlopes,          context.ResortKey, buildingStats.Slopes)
	safeSetAsync(OrderedStores.MostGuests,          context.ResortKey, totalGuests)
	safeSetAsync(OrderedStores.BestRating,          context.ResortKey, ratingOrderedValue)

	return true
end

local publishQueued = false
local function queuePublish(delaySeconds)
	if publishQueued then
		return
	end
	publishQueued = true
	task.delay(delaySeconds or 5, function()
		publishQueued = false
		publishCurrentResort()
	end)
end

ResortNameValue:GetPropertyChangedSignal("Value"):Connect(function()
	queuePublish(2)
end)

SlotNumValue:GetPropertyChangedSignal("Value"):Connect(function()
	queuePublish(2)
end)

UserIdValue:GetPropertyChangedSignal("Value"):Connect(function()
	queuePublish(2)
end)

task.delay(INITIAL_PUBLISH_DELAY, publishCurrentResort)

task.spawn(function()
	while true do
		task.wait(PUBLISH_INTERVAL)
		publishCurrentResort()
	end
end)

Players.PlayerRemoving:Connect(function(player)
	if player.UserId == (tonumber(UserIdValue.Value) or -1) then
		publishCurrentResort()
	end
end)

game:BindToClose(function()
	publishCurrentResort()
end)
