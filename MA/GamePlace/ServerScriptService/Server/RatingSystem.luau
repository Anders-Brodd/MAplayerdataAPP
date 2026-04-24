local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local DataStoreService = game:GetService("DataStoreService")
local Workspace = game:GetService("Workspace")

local SlotData = ReplicatedStorage:FindFirstChild("SlotData") or ReplicatedStorage:WaitForChild("SlotData", 10)
local SnowGunShared = nil
pcall(function()
	SnowGunShared = require(ReplicatedStorage:WaitForChild("SnowGunShared"))
end)

local Config = nil
pcall(function()
	local cfg = ReplicatedStorage:FindFirstChild("Config")
	if cfg then Config = require(cfg) end
end)

-- // DATASTORES //
local RatingStore = DataStoreService:GetDataStore("ResortRating_v4")
local LegacyRatingStore = DataStoreService:GetDataStore("ResortRating_v3")
local LegacyRatingStoreUnavailable = false
local AUTOSAVE_INTERVAL = 120 

local BadgeService = game:GetService("BadgeService")

-- BADGE IDs (User must fill these in)
local RatingBadges = {
	[0] = 0, -- 0 Star Badge ID
	[1] = 0, -- 1 Star Badge ID 
	[2] = 0, -- 2 Star Badge ID
	[3] = 0, -- 3 Star Badge ID
	[4] = 0, -- 4 Star Badge ID
	[5] = 0, -- 5 Star Badge ID
}

-- // RATING CONFIG //
local RatingConfig = {
	StartingRating = 1.0,
	MinRating = 0,
	MaxRating = 5,

	Volatility = 0.015, 

	Events = {
		GuestCompletedVacation = 4.2, 
		GuestAteFood = 4.0,
		GuestRodeLift = 3.8,
		GuestHappyThought = 3.6,

		GuestLeftHungry = 1.0,
		GuestLeftBroke = 1.2,
		GuestLeftTired = 1.5,
		GuestCouldntFindFood = 0.8,
		GuestCouldntFindLift = 1.0,

		NoFoodBuildings = -0.06,
		NoLodging = -0.04,
		NoSlopes = -0.08,
		LowVariety = -0.03,
	},

	AmenityBonus = {
		HasFood = 0.2,
		HasLodging = 0.2,
		HasMultipleLifts = 0.3,
		Variety = 0.8,
	}
}

-- // SETUP EVENTS //
local Events = ReplicatedStorage:FindFirstChild("Events") or Instance.new("Folder", ReplicatedStorage)
Events.Name = "Events"
local RatingEvent = Events:FindFirstChild("RatingUpdate") or Instance.new("RemoteEvent", Events)
RatingEvent.Name = "RatingUpdate"
local RatingSummaryRequest = Events:FindFirstChild("RatingSummaryRequest") or Instance.new("RemoteFunction", Events)
RatingSummaryRequest.Name = "RatingSummaryRequest"

local ReportRatingEvent = script:FindFirstChild("ReportRatingChange") or Instance.new("BindableEvent")
ReportRatingEvent.Name = "ReportRatingChange"
ReportRatingEvent.Parent = script

local NotificationEvent = Events:FindFirstChild("NotificationEvent") or Instance.new("RemoteEvent", Events)
NotificationEvent.Name = "NotificationEvent"

-- // PLAYER DATA //
local PlayerRatings = {}

-- // HELPER FUNCTIONS //
local function awardBadgeSafe(userId, badgeId)
	if not badgeId or badgeId == 0 then return end
	pcall(function()
		if not BadgeService:UserHasBadgeAsync(userId, badgeId) then
			BadgeService:AwardBadge(userId, badgeId)
		end
	end)
end

local function checkBadges(player, rating)
	local userId = player.UserId
	local wholeStars = math.max(0, math.floor(rating))
	if rating < 0.5 then
		awardBadgeSafe(userId, RatingBadges[0])
	else
		for star = 1, wholeStars do
			awardBadgeSafe(userId, RatingBadges[star])
		end
	end
end

local function clampRating(rating)
	return math.clamp(rating, RatingConfig.MinRating, RatingConfig.MaxRating)
end

local function roundHalf(value)
	return math.floor((math.clamp(tonumber(value) or 0, 0, 5) * 2) + 0.5) / 2
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

local function getSafeRatio(part, whole)
	if whole <= 0 then
		return 0
	end
	return math.clamp(part / whole, 0, 1)
end

local function clampNearOverall(score, overall, lowerSlack, upperSlack)
	local floorValue = math.max(0.5, overall - lowerSlack)
	local ceilValue = math.min(5, overall + upperSlack)
	return math.clamp(score, floorValue, ceilValue)
end

local function getEventCount(stats, eventType)
	local eventCounts = type(stats.EventCounts) == "table" and stats.EventCounts or nil
	return eventCounts and math.max(0, tonumber(eventCounts[eventType]) or 0) or 0
end

local function updateLeaderstats(player, rating)
	local ls = player:FindFirstChild("leaderstats")
	if ls then
		local rVal = ls:FindFirstChild("Rating")
		if rVal then rVal.Value = rating end
	end
end

local function ensureStatsTable(data)
	local stats = type(data.Stats) == "table" and data.Stats or {}
	stats.TotalGuests = math.max(0, tonumber(stats.TotalGuests) or 0)
	stats.HappyGuests = math.max(0, tonumber(stats.HappyGuests) or 0)
	stats.HungryGuests = math.max(0, tonumber(stats.HungryGuests) or 0)
	stats.EventCounts = type(stats.EventCounts) == "table" and stats.EventCounts or {}
	data.Stats = stats
	return stats
end

local function trackGuestStats(data, statMeta, eventType)
	if not data then
		return
	end

	local meta = type(statMeta) == "table" and statMeta or {}
	local stats = ensureStatsTable(data)
	if eventType and eventType ~= "" then
		stats.EventCounts[eventType] = math.max(0, tonumber(stats.EventCounts[eventType]) or 0) + 1
	end

	local guestToken = meta.GuestToken and tostring(meta.GuestToken) or nil
	local recent = data._recentGuestStatTokens
	if type(recent) ~= "table" then
		recent = {}
		data._recentGuestStatTokens = recent
	end

	local guestState = nil
	if guestToken then
		guestState = recent[guestToken]
		if type(guestState) ~= "table" then
			guestState = {}
			recent[guestToken] = guestState
		end
		guestState.SeenAt = os.clock()
	end

	if meta.CountGuest and not (guestState and guestState.CountGuest) then
		stats.TotalGuests += 1
		if guestState then guestState.CountGuest = true end
	end
	if meta.HappyGuest and not (guestState and guestState.HappyGuest) then
		stats.HappyGuests += 1
		if guestState then guestState.HappyGuest = true end
	end
	if meta.HungryGuest and not (guestState and guestState.HungryGuest) then
		stats.HungryGuests += 1
		if guestState then guestState.HungryGuest = true end
	end

	local now = os.clock()
	local tokenCount = 0
	for token, info in pairs(recent) do
		if type(info) ~= "table" or (now - (tonumber(info.SeenAt) or 0)) > 600 then
			recent[token] = nil
		else
			tokenCount += 1
		end
	end
	if tokenCount > 512 then
		data._recentGuestStatTokens = {}
	end
end

local function getRatingKey(player)
	local slotNum = player:GetAttribute("SlotNum") or player:GetAttribute("ActiveSlot") or 1
	return "Rating_" .. player.UserId .. "_Slot_" .. tostring(slotNum)
end

local function getResortOwnerUserId()
	local ownerValue = SlotData and SlotData:FindFirstChild("UserId")
	return ownerValue and ownerValue.Value or 0
end

local function getResortOwnerPlayer()
	local ownerUserId = getResortOwnerUserId()
	if ownerUserId and ownerUserId > 0 then
		return Players:GetPlayerByUserId(ownerUserId)
	end
	return nil
end

local function resolveSummaryPlayer(requestingPlayer)
	return getResortOwnerPlayer() or requestingPlayer
end

local function getFreshSaveStartingRating()
	if SlotData and SlotData:GetAttribute("FreshSave") == true then
		return 0
	end
	return RatingConfig.StartingRating
end

local function shouldDisableLegacyStore(err)
	local message = string.lower(tostring(err or ""))
	return string.find(message, "deleted", 1, true) ~= nil
		or string.find(message, "error code: 49", 1, true) ~= nil
end

local function readRatingData(store, key)
	local success, payload = pcall(function()
		return store:GetAsync(key)
	end)
	if success and type(payload) == "table" then
		return payload, true
	end
	return nil, success
end

local function tryReadLegacyRating(key)
	if LegacyRatingStoreUnavailable then
		return nil
	end
	local success, payloadOrErr = pcall(function()
		return LegacyRatingStore:GetAsync(key)
	end)
	if success and type(payloadOrErr) == "table" then
		return payloadOrErr
	end
	if not success and shouldDisableLegacyStore(payloadOrErr) then
		LegacyRatingStoreUnavailable = true
		warn("[RatingSystem] Legacy rating store is unavailable (deleted). Disabling v3 fallback reads.")
	end
	return nil
end

local function migrateLegacyRatingToV4(player, legacyData)
	if type(legacyData) ~= "table" then
		return
	end
	local slotKey = getRatingKey(player)
	pcall(function()
		RatingStore:UpdateAsync(slotKey, function(current)
			if type(current) == "table" and current.Rating ~= nil then
				return current
			end
			return {
				Rating = tonumber(legacyData.Rating) or RatingConfig.StartingRating,
				Stats = type(legacyData.Stats) == "table" and legacyData.Stats or { TotalGuests = 0, HappyGuests = 0, HungryGuests = 0 },
				LastPlayed = tonumber(legacyData.LastPlayed) or os.time(),
			}
		end)
	end)
end

local function savePlayerRating(player)
	if not player then return end
	local userId = player.UserId
	local data = PlayerRatings[userId]
	if not data then return end

	local MAX_RETRIES = 5
	local BASE_DELAY = 1.5
	local success = false
	local err = nil

	for attempt = 1, MAX_RETRIES do
		success, err = pcall(function()
			RatingStore:UpdateAsync(getRatingKey(player), function(oldData)
				return {
					Rating = data.Rating,
					Stats = data.Stats,
					LastPlayed = os.time()
				}
			end)
		end)

		if success then
			break
		else
			warn("[RatingSystem] Save failed (Attempt " .. attempt .. "/" .. MAX_RETRIES .. "): " .. tostring(err))
			if attempt < MAX_RETRIES then
				task.wait(BASE_DELAY + math.random() * 2)
				BASE_DELAY = BASE_DELAY * 2
			end
		end
	end
end

local function loadPlayerRating(player)
	local userId = player.UserId
	local slotKey = getRatingKey(player)
	local legacyUserKey = "Rating_" .. tostring(userId)
	local defaultData = {
		Rating = getFreshSaveStartingRating(),
		Stats = { TotalGuests = 0, HappyGuests = 0, HungryGuests = 0 }
	}

	local data, success = readRatingData(RatingStore, slotKey)
	if (not data) and success then
		data = readRatingData(RatingStore, legacyUserKey)
	end

	if not data then
		local legacyData = tryReadLegacyRating(slotKey)
		if not legacyData then
			legacyData = tryReadLegacyRating(legacyUserKey)
		end
		if legacyData then
			data = legacyData
			migrateLegacyRatingToV4(player, legacyData)
		end
	end

	if type(data) == "table" then
		defaultData.Rating = data.Rating or RatingConfig.StartingRating
		defaultData.Stats = data.Stats or defaultData.Stats
	end

	defaultData.Stats = ensureStatsTable(defaultData)
	return defaultData
end

local function IsPlacedObjectRootModel(obj, placed)
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

local function GetPlacedObjectModels(placed)
	local results = {}
	if not placed then
		return results
	end

	for _, obj in ipairs(placed:GetDescendants()) do
		if IsPlacedObjectRootModel(obj, placed) then
			table.insert(results, obj)
		end
	end

	return results
end

local function isSnowmakingModel(obj)
	if not obj or not obj:IsA("Model") then
		return false
	end
	if SnowGunShared and SnowGunShared.IsSnowGunName and SnowGunShared.IsSnowGunName(obj.Name) then
		return true
	end
	local lowerName = string.lower(obj.Name)
	return lowerMatch(lowerName, {"snowcannon", "snowgun", "swine tower", "narwhal tower", "skua", "stoat"})
end

local function countAmenities(userId)
	local counts = {
		Lifts = 0,
		Slopes = 0,
		Food = 0,
		Lodging = 0,
		Restaurants = 0,
		Rentals = 0,
		Lodges = 0,
		Others = 0,
		Snowmaking = 0,
		ActiveSnowmaking = 0,
	}
	local placed = Workspace:FindFirstChild("PlacedObjects")
	if not placed then
		return counts
	end

	for _, obj in ipairs(GetPlacedObjectModels(placed)) do
		local owner = tonumber(obj:GetAttribute("Owner"))
		if owner == userId then
			local objType = tostring(obj:GetAttribute("Type") or "")
			local objCategory = tostring(obj:GetAttribute("Category") or "")
			local itemCfg = nil
			local modelId = obj:GetAttribute("ID")
			if modelId and Config and Config.GetItemById then
				_, itemCfg = Config.GetItemById(modelId)
			end
			if not itemCfg and Config and Config.Items then
				itemCfg = Config.Items[obj.Name]
			end
			local cfgType = itemCfg and tostring(itemCfg.Type or "") or ""
			local cfgCategory = itemCfg and tostring(itemCfg.Category or "") or ""
			local lowerName = string.lower(obj.Name)

			local isSlope = lowerMatch(objType, {"slope"}) or lowerMatch(cfgType, {"slope"}) or lowerMatch(cfgCategory, {"slope", "slopes"})
			local isLift = lowerMatch(objType, {"twopoint", "lift", "carpet"})
				or lowerMatch(cfgType, {"twopoint", "lift", "carpet"})
				or lowerMatch(lowerName, {"lift", "chair", "gondola", "tram"})
			local isRestaurant = lowerMatch(objType, {"food", "restaurant", "cafe"})
				or lowerMatch(cfgType, {"food", "restaurant", "cafe"})
				or lowerMatch(objCategory, {"food", "restaurant", "cafe"})
				or lowerMatch(cfgCategory, {"food", "restaurant", "cafe"})
				or lowerMatch(lowerName, {"food", "restaurant", "cafe", "snack", "burger", "pizza"})
			local isRental = lowerMatch(objType, {"rental"})
				or lowerMatch(cfgType, {"rental"})
				or lowerMatch(objCategory, {"rental"})
				or lowerMatch(cfgCategory, {"rental"})
				or lowerMatch(lowerName, {"rental", "rent", "ski shop", "gear shop"})
			local isLodge = lowerMatch(objType, {"house", "hotel", "lodging"})
				or lowerMatch(cfgType, {"house", "hotel", "lodging"})
				or lowerMatch(objCategory, {"house", "hotel", "housing", "accommodation", "lodging"})
				or lowerMatch(cfgCategory, {"house", "hotel", "housing", "accommodation", "lodging"})
				or lowerMatch(lowerName, {"hotel", "house", "lodge", "cabin", "inn"})


			local isSnowmaking = isSnowmakingModel(obj)
			local categorized = false
			if isSlope then
				counts.Slopes += 1
				categorized = true
			end
			if isLift then
				counts.Lifts += 1
				categorized = true
			end
			if isRestaurant then
				counts.Restaurants += 1
				categorized = true
			end
			if isRental then
				counts.Rentals += 1
				categorized = true
			end
			if isLodge then
				counts.Lodges += 1
				categorized = true
			end
			if isSnowmaking then
				counts.Snowmaking += 1
				if obj:GetAttribute("State") ~= "Off" or obj:GetAttribute("SnowmakerActive") == true then
					counts.ActiveSnowmaking += 1
				end
				categorized = true
			end
			if not categorized then
				counts.Others += 1
			end
		end
	end

	counts.Food = counts.Restaurants
	counts.Lodging = counts.Lodges
	return counts
end

local function isCleanableAmenityModel(obj)
	if not obj or not obj:IsA("Model") then
		return false
	end
	local objType = string.lower(tostring(obj:GetAttribute("Type") or ""))
	local lowerName = string.lower(obj.Name)
	if objType == "food" or objType == "rental" or objType == "house" then
		return true
	end
	return lowerMatch(lowerName, {"restaurant", "food", "cafe", "rental", "cabin", "lodge", "hotel", "house"})
end

local function summarizeCleanliness(userId)
	local placed = Workspace:FindFirstChild("PlacedObjects")
	local totalCleanliness = 0
	local cleanableBuildings = 0
	local dirtyBuildings = 0
	local janitorCoverage = 0
	if not placed then
		return {
			Cleanliness = 100,
			DirtyBuildings = 0,
			CleanableBuildings = 0,
			JanitorCoverage = 0,
			JanitorCoverageRatio = 0,
		}
	end

	for _, obj in ipairs(GetPlacedObjectModels(placed)) do
		if tonumber(obj:GetAttribute("Owner")) == userId and isCleanableAmenityModel(obj) then
			cleanableBuildings += 1
			local janitorLevel = math.max(0, tonumber(obj:GetAttribute("JanitorLevel")) or 0)
			local hasJanitor = obj:GetAttribute("HasJanitor") == true or janitorLevel > 0
			if hasJanitor then
				janitorCoverage += 1
			end
			local cleanliness = tonumber(obj:GetAttribute("Cleanliness"))
			if cleanliness == nil then
				cleanliness = hasJanitor and (92 + math.max(0, janitorLevel - 1) * 2) or 55
			end
			local dirtiness = tonumber(obj:GetAttribute("Dirtiness"))
			if dirtiness ~= nil then
				cleanliness = math.min(cleanliness, 100 - dirtiness)
			end
			cleanliness = math.clamp(cleanliness, 0, 100)

			if hasJanitor then
				local janitorFloor = math.clamp(92 + math.max(0, janitorLevel - 1) * 2, 92, 98)
				cleanliness = math.max(cleanliness, janitorFloor)
			end

			totalCleanliness += cleanliness
			local needsCleaning = obj:GetAttribute("NeedsCleaning") == true
			if hasJanitor then
				if cleanliness < 88 then
					dirtyBuildings += 1
				end
			elseif cleanliness < 60 or needsCleaning then
				dirtyBuildings += 1
			end
		end
	end

	local coverageRatio = getSafeRatio(janitorCoverage, cleanableBuildings)
	local averageCleanliness = cleanableBuildings > 0 and math.floor((totalCleanliness / cleanableBuildings) + 0.5) or 100
	if janitorCoverage > 0 then
		local janitorAverageFloor = 90
		if coverageRatio >= 0.25 then
			janitorAverageFloor = 91
		end
		if coverageRatio >= 0.5 then
			janitorAverageFloor = 93
		end
		if coverageRatio >= 0.75 then
			janitorAverageFloor = 95
		end
		if coverageRatio >= 1 then
			janitorAverageFloor = 97
		end
		averageCleanliness = math.max(averageCleanliness, janitorAverageFloor)
	end
	return {
		Cleanliness = averageCleanliness,
		DirtyBuildings = dirtyBuildings,
		CleanableBuildings = cleanableBuildings,
		JanitorCoverage = janitorCoverage,
		JanitorCoverageRatio = coverageRatio,
	}
end

local REVIEW_NAMES = {
	"Avery S.", "Logan P.", "Mia R.", "Noah K.", "Sage M.", "Levi T.", "Aria H.", "Mason W.",
	"Ivy C.", "Theo J.", "Nora B.", "Kai D.",
}

local REVIEW_ACCENTS = {
	Blue = { R = 92, G = 180, B = 255 },
	Cyan = { R = 88, G = 226, B = 226 },
	Gold = { R = 255, G = 210, B = 102 },
	Green = { R = 86, G = 214, B = 140 },
	Orange = { R = 255, G = 167, B = 103 },
	Red = { R = 245, G = 109, B = 109 },
}

local function getReviewCountFromStats(totalGuests)
	totalGuests = math.max(0, math.floor(tonumber(totalGuests) or 0))
	if totalGuests <= 0 then
		return 0
	end
	return math.max(1, math.min(totalGuests, math.floor((totalGuests * 0.55) + 0.5)))
end

local function getPositiveShare(happyRatio, hungryRatio)
	return math.clamp((happyRatio * 0.8) + ((1 - hungryRatio) * 0.2), 0, 1)
end

local function createReviewCard(title, body, stars, badge, accentName)
	return {
		Title = title,
		Body = body,
		Stars = math.clamp(math.floor((tonumber(stars) or 0) + 0.5), 1, 5),
		Badge = badge,
		AccentRGB = REVIEW_ACCENTS[accentName] or REVIEW_ACCENTS.Blue,
	}
end

local function buildOperationalSignals(player, stats, amenities)
	local totalGuests = math.max(0, tonumber(stats.TotalGuests) or 0)
	local reroutesPerMinute = math.max(0, tonumber(player and player:GetAttribute("GuestReroutesPerMinute")) or 0)
	local foodMisses = getEventCount(stats, "GuestCouldntFindFood")
	local liftMisses = getEventCount(stats, "GuestCouldntFindLift")
	local brokeExits = getEventCount(stats, "GuestLeftBroke")
	local tiredExits = getEventCount(stats, "GuestLeftTired")
	local amenityCapacity = math.max(1, (amenities.Lifts * 20) + (amenities.Restaurants * 12) + (amenities.Rentals * 10) + (amenities.Lodges * 14) + (amenities.Others * 4))
	local activeSnowmaking = math.max(0, tonumber(amenities.ActiveSnowmaking) or 0)
	local snowmakingCoverage = math.clamp(activeSnowmaking / math.max(1, amenities.Slopes), 0, 1)
	local cleanliness = player and summarizeCleanliness(player.UserId) or {
		Cleanliness = 100,
		DirtyBuildings = 0,
		CleanableBuildings = 0,
		JanitorCoverage = 0,
		JanitorCoverageRatio = 0,
	}
	return {
		ReroutesPerMinute = reroutesPerMinute,
		FoodMisses = foodMisses,
		LiftMisses = liftMisses,
		BrokeExits = brokeExits,
		TiredExits = tiredExits,
		FoodMissRate = getSafeRatio(foodMisses, totalGuests),
		LiftMissRate = getSafeRatio(liftMisses, totalGuests),
		BrokeExitRate = getSafeRatio(brokeExits, totalGuests),
		TiredExitRate = getSafeRatio(tiredExits, totalGuests),
		GuestLoad = totalGuests / amenityCapacity,
		Cleanliness = cleanliness.Cleanliness,
		DirtyBuildings = cleanliness.DirtyBuildings,
		CleanableBuildings = cleanliness.CleanableBuildings,
		JanitorCoverage = cleanliness.JanitorCoverage,
		JanitorCoverageRatio = cleanliness.JanitorCoverageRatio,
		Snowmaking = math.max(0, tonumber(amenities.Snowmaking) or 0),
		ActiveSnowmaking = activeSnowmaking,
		SnowmakingCoverage = snowmakingCoverage,
	}
end

local function buildCategoryScores(rating, stats, amenities, happyRatio, hungryRatio, operational)
	local overall = math.clamp(tonumber(rating) or 0, 0, 5)
	local totalGuests = math.max(0, tonumber(stats.TotalGuests) or 0)

	local amenityCoverage = math.clamp(((math.min(amenities.Restaurants, 5) * 1.0) + (math.min(amenities.Rentals, 4) * 0.9) + (math.min(amenities.Lodges, 4) * 1.1) + (math.min(amenities.Lifts, 6) * 1.25) + (math.min(amenities.Others, 6) * 0.35) + (math.min(amenities.ActiveSnowmaking or 0, 6) * 0.55)) / 25.9, 0, 1)
	local sizeCoverage = math.clamp(((amenities.Lifts * 1.35) + (amenities.Restaurants * 1.0) + (amenities.Rentals * 0.9) + (amenities.Lodges * 1.15) + (amenities.Others * 0.45) + ((amenities.Snowmaking or 0) * 0.35)) / 27.1, 0, 1)
	local positiveShare = totalGuests > 0 and getPositiveShare(happyRatio, hungryRatio) or 0

	local amenitiesScore = clampNearOverall(
		(overall * 0.8)
			+ (amenityCoverage * 2.2)
		- (operational.FoodMissRate * 1.25)
		- (operational.LiftMissRate * 0.75)
		- (hungryRatio * 0.55)
		- (amenities.Restaurants == 0 and 0.85 or 0)
		- (amenities.Lifts == 0 and 0.9 or 0),
		overall,
		1.85,
		1.0
	)

	local qualityScore = clampNearOverall(
		(overall * 0.94)
			+ (positiveShare * 0.55)
			+ (math.max(0, operational.Cleanliness - 88) * 0.022)
			+ (operational.JanitorCoverageRatio * 0.25)
			+ (operational.SnowmakingCoverage * 0.4)
			+ (math.min(operational.ActiveSnowmaking, 4) * 0.08)
		- (hungryRatio * 0.8)
		- (operational.FoodMissRate * 0.75)
		- (operational.BrokeExitRate * 0.4)
		- (operational.TiredExitRate * 0.3)
		- (math.max(0, 80 - operational.Cleanliness) * 0.018)
		- (operational.DirtyBuildings * 0.06),
		overall,
		1.5,
		0.95
	)

	local crowdScore = totalGuests <= 0 and clampNearOverall(overall + 0.5, overall, 0.4, 0.8) or clampNearOverall(
		(overall * 0.88)
			+ 0.35
		- (math.max(0, operational.GuestLoad - 0.5) * 3.0)
		- (math.min(operational.ReroutesPerMinute / 4, 1.5) * 1.6)
		- (operational.LiftMissRate * 0.7),
		overall,
		1.5,
		0.9
	)

	local sizeScore = clampNearOverall(
		(overall * 0.75)
			+ 0.15
			+ (sizeCoverage * 2.0)
		- (amenities.Lifts == 0 and 0.45 or 0),
		overall,
		0.85,
		1.15
	)

	return {
		Amenities = roundHalf(amenitiesScore),
		Quality = roundHalf(qualityScore),
		Crowdy = roundHalf(crowdScore),
		ResortSize = roundHalf(sizeScore),
	}
end

local function pickReviewLabel(rating, happyRatio, hungryRatio, amenities, operational, categoryScores)
	local totalSignals = (amenities.Restaurants + amenities.Rentals + amenities.Lodges + amenities.Lifts)
	if rating <= 0 and totalSignals == 0 then
		return "No reviews yet"
	elseif operational.ReroutesPerMinute >= 3 and categoryScores.Crowdy <= 2.5 then
		return "Too crowded"
	elseif amenities.Restaurants == 0 or operational.FoodMissRate >= 0.3 then
		return "Needs food"
	elseif operational.CleanableBuildings > 0 and operational.Cleanliness <= 45 then
		return "Needs cleanup"
	elseif rating >= 4.5 and happyRatio >= 0.82 and hungryRatio <= 0.12 and amenities.Lifts >= 3 then
		return "Loved it"
	elseif rating >= 3.9 and happyRatio >= 0.68 and categoryScores.Crowdy >= 3.5 then
		return "Busy but good"
	elseif rating >= 3.0 then
		return "Getting better"
	elseif categoryScores.Amenities <= 2.5 or categoryScores.Quality <= 2.5 then
		return "Needs work"
	elseif rating >= 1.8 then
		return "Rough"
	end
	return "Not great"
end

local function buildDynamicReviews(player, rating, stats, amenities, happyRatio, hungryRatio, categoryScores, operational)
	local totalGuests = math.max(0, tonumber(stats.TotalGuests) or 0)
	local reviewCount = getReviewCountFromStats(totalGuests)
	if totalGuests <= 0 then
		return {
			{
				Name = "System",
				Title = "No guest reviews yet",
				Body = "Nobody has visited the resort long enough to leave real feedback yet. Once guests start riding lifts and using the facilities, reviews will start showing up here automatically.",
				Badge = "Info",
				Stars = math.max(1, roundHalf(rating)),
				AccentRGB = REVIEW_ACCENTS.Cyan,
			},
		}, reviewCount
	end

	local totalAmenities = amenities.Restaurants + amenities.Rentals + amenities.Lodges + amenities.Lifts + amenities.Others
	local pool = {

		-- CARD 1: Overview (250-300 chars)
		createReviewCard(
			rating >= 4.2 and "Genuinely one of my favourite visits" or (rating >= 3 and "Solid day overall, a few rough edges" or "Not quite there yet, needs some work"),
			rating >= 4.2
				and "Came here not expecting much and honestly left really impressed. The lifts were running well, food was easy to find, and nothing felt broken or half finished. Would absolutely come back and have already told several friends they should give it a proper visit."
				or (rating >= 3
					and "Had a decent time overall, though there were a couple of moments where things felt a bit disorganised. Nothing that completely ruined the day, but with a few improvements and some extra polish this place could genuinely become one of the better resorts around."
					or "You can tell there is real ambition behind this resort but it still feels like it is missing some important pieces. Better flow between areas and a few more amenities would go a long way toward making this feel like a proper destination worth returning to."),
			rating,
			"Overview",
			rating >= 3.5 and "Cyan" or "Orange"
		),

		-- CARD 2: Amenities (100-150 chars)
		createReviewCard(
			categoryScores.Amenities >= 4 and "Loads to do, genuinely impressed" or (categoryScores.Amenities >= 3 and "Decent selection but could use more" or "Really lacking in options right now"),
			amenities.Restaurants == 0
				and "Nowhere to eat at all, which is a real problem. By midday most people were leaving hungry and frustrated."
				or (amenities.Lifts == 0
					and "No proper lift access makes everything harder than it needs to be. Hiking back up every run gets old very fast."
					or (totalAmenities <= 3
						and string.format("Still pretty bare with only %d lift%s and %d place%s to eat or stay. Needs a lot more built out before it feels like a complete resort.", amenities.Lifts, amenities.Lifts == 1 and "" or "s", amenities.Restaurants, amenities.Restaurants == 1 and "" or "s")
						or string.format("Solid setup overall with %d lift%s, %d restaurant%s, and %d rental%s on site. More than enough to keep you busy for a full day.", amenities.Lifts, amenities.Lifts == 1 and "" or "s", amenities.Restaurants, amenities.Restaurants == 1 and "" or "s", amenities.Rentals, amenities.Rentals == 1 and "" or "s"))),
			categoryScores.Amenities,
			"Amenities",
			categoryScores.Amenities >= 3.5 and "Green" or "Red"
		),

		-- CARD 3: Quality (100-150 chars)
		createReviewCard(
			categoryScores.Quality >= 4 and "Everything felt polished and well run" or (categoryScores.Quality >= 3 and "Mostly fine but a few things felt off" or "The experience felt pretty rough overall"),
			operational.CleanableBuildings > 0 and operational.Cleanliness < 58
				and string.format("Cleanliness is at %d%% with %d dirty spots still unattended. It makes the whole resort feel neglected.", operational.Cleanliness, operational.DirtyBuildings)
				or (hungryRatio >= 0.28
					and "Too many guests left hungry. When that many people go away dissatisfied it drags down the whole experience."
					or (((operational.FoodMisses > 0) or (operational.LiftMisses > 0))
						and string.format("Still some friction here. %d food misses and %d lift misses logged. Small issues but they add up quickly.", operational.FoodMisses, operational.LiftMisses)
						or (getPositiveShare(happyRatio, hungryRatio) >= 0.7
							and "Most guests left happy and everything flowed well. You can tell real thought has gone into how the resort runs."
							or "Some parts work well but others still need attention. The inconsistency is what holds the score back right now."))),
			categoryScores.Quality,
			"Quality",
			categoryScores.Quality >= 3.5 and "Blue" or "Orange"
		),

		-- CARD 4: Crowd (100-150 chars)
		createReviewCard(
			categoryScores.Crowdy >= 4 and "Never felt crowded, great flow all day" or (categoryScores.Crowdy >= 3 and "Gets busy at peak times but manageable" or "Way too crowded, the queues were brutal"),
			operational.ReroutesPerMinute >= 3
				and "Lift lines backed up constantly and guests kept getting rerouted elsewhere. It made the whole day feel chaotic."
				or (operational.GuestLoad >= 1.1
					and "Holds up fine when quiet but peak hours get chaotic fast. The capacity just is not keeping up with demand yet."
					or "Easy to get around all day. Never had to fight for a lift or wait long at any point, which made a real difference."),
			categoryScores.Crowdy,
			"Crowd",
			categoryScores.Crowdy >= 3.5 and "Green" or "Red"
		),

		-- CARD 5: Resort Size (100-150 chars)
		createReviewCard(
			categoryScores.ResortSize >= 4 and "Feels like a fully fledged resort" or (categoryScores.ResortSize >= 3 and "Good foundation, still room to grow" or "Feels more like a small slope than a resort"),
			totalAmenities <= 2
				and "Not enough here to fill a full day. Feels more like a small hill than a proper resort at this point."
				or (amenities.Lifts >= 3 and (amenities.Lodges + amenities.Restaurants + amenities.Rentals) >= 4
					and "Starting to feel like a real resort now. Multiple lifts, food, lodging, and rentals all in one place is great."
					or string.format("Decent base with %d lift%s but still needs more variety and scale to feel like a full resort that is actually worth travelling to.", amenities.Lifts, amenities.Lifts == 1 and "" or "s")),
			categoryScores.ResortSize,
			"Size",
			categoryScores.ResortSize >= 3.5 and "Gold" or "Blue"
		),
	}

	local rotated = {}
	local rotationSeed = (math.floor(os.time() / 45) + (player and player.UserId or 0) + totalAmenities + math.floor(operational.ReroutesPerMinute + 0.5))

	local displayCount = math.min(15, math.max(5, reviewCount))
	if totalGuests <= 0 then displayCount = 0 end

	for i = 1, displayCount do
		local poolIndex = ((i - 1) % #pool) + 1
		local review = pool[poolIndex]
		local clone = table.clone(review)
		clone.Name = REVIEW_NAMES[((rotationSeed + i - 2) % #REVIEW_NAMES) + 1]
		if i > 5 then
			clone.Badge = "Guest Review"
		end
		rotated[i] = clone
	end

	return rotated, reviewCount
end

-- // RATING ALGORITHM //
local function changeRating(player, eventType, customAmount, statMeta)
	if not player then return end
	local userId = player.UserId
	local data = PlayerRatings[userId]
	if not data then return end

	local targetRating = customAmount or RatingConfig.Events[eventType]
	if not targetRating then return end

	local oldRating = data.Rating
	local change = 0

	if eventType == "PeriodicUpdate" then
		local amenityScore = tonumber(customAmount) or 0
		local equilibrium = math.clamp(RatingConfig.StartingRating + amenityScore * 18, RatingConfig.MinRating, RatingConfig.MaxRating)
		local strength = math.clamp(RatingConfig.Volatility * 8.5, 0.03, 0.095)
		data.Rating = clampRating((oldRating * (1 - strength)) + (equilibrium * strength))
		change = data.Rating - oldRating
	else
		local strength = RatingConfig.Volatility
		if targetRating < 2.5 then strength = strength * 1.1 end 
		if oldRating >= 4.0 and targetRating > oldRating then
			local struggleFactor = math.clamp(5.0 - oldRating, 0.1, 1.0)
			strength = strength * struggleFactor
			strength = strength * 0.25 
		end
		local newRating = (oldRating * (1 - strength)) + (targetRating * strength)
		data.Rating = clampRating(newRating)
		change = data.Rating - oldRating
	end

	trackGuestStats(data, statMeta, eventType)
	updateLeaderstats(player, data.Rating)
	checkBadges(player, data.Rating)
	if player.UserId == getResortOwnerUserId() then
		RatingEvent:FireAllClients(data.Rating)
	else
		RatingEvent:FireClient(player, data.Rating)
	end

	if math.abs(change) >= 0.05 and eventType ~= "PeriodicUpdate" then
		local color = change > 0 and "Info" or "Warning"
		local symbol = change > 0 and "⬆" or "⬇"
		local msg = string.format("Rating %s (%s)", symbol, eventType)
		NotificationEvent:FireClient(player, color, msg)
	end
end

-- // CONNECTIONS //
local function setupPlayer(player)
	local ls = player:FindFirstChild("leaderstats")
	if not ls then
		ls = Instance.new("Folder")
		ls.Name = "leaderstats"
		ls.Parent = player
	end

	local rVal = ls:FindFirstChild("Rating")
	if not rVal then
		rVal = Instance.new("NumberValue")
		rVal.Name = "Rating"
		rVal.Value = 0
		rVal.Parent = ls
	end

	local data = loadPlayerRating(player)
	PlayerRatings[player.UserId] = data
	rVal.Value = data.Rating

	task.spawn(function()
		task.wait(2)
		if player.UserId == getResortOwnerUserId() then
			RatingEvent:FireAllClients(data.Rating)
		else
			RatingEvent:FireClient(player, data.Rating)
		end
	end)
end

Players.PlayerAdded:Connect(setupPlayer)

for _, player in ipairs(Players:GetPlayers()) do
	task.spawn(setupPlayer, player)
end

Players.PlayerRemoving:Connect(function(player)
	savePlayerRating(player)
	PlayerRatings[player.UserId] = nil
end)

game:BindToClose(function()
	for _, player in pairs(Players:GetPlayers()) do savePlayerRating(player) end
end)

ReportRatingEvent.Event:Connect(function(player, eventType, customAmount, statMeta)
	changeRating(player, eventType, customAmount, statMeta)
end)

-- // PERIODIC CHECK //
task.spawn(function()
	while true do
		task.wait(30)
		for userId, _ in pairs(PlayerRatings) do
			local player = Players:GetPlayerByUserId(userId)
			if player then
				local amenities = countAmenities(userId)
				local stats = ensureStatsTable(PlayerRatings[userId])
				local operational = summarizeCleanliness(userId)
				local bonus = 0
				local supportAmenities = amenities.Restaurants + amenities.Rentals + amenities.Lodges

				if amenities.Food > 0 then bonus = bonus + RatingConfig.AmenityBonus.HasFood
				else bonus = bonus + RatingConfig.Events.NoFoodBuildings end

				if amenities.Lodging > 0 then bonus = bonus + RatingConfig.AmenityBonus.HasLodging
				else bonus = bonus + RatingConfig.Events.NoLodging end

				if amenities.Lifts >= 2 then bonus = bonus + RatingConfig.AmenityBonus.HasMultipleLifts end
				if amenities.Food > 0 and amenities.Lodging > 0 and amenities.Lifts > 0 then
					bonus = bonus + RatingConfig.AmenityBonus.Variety
				end

				bonus = bonus + (math.min(math.max(amenities.Lifts - 2, 0), 4) * 0.12)
				bonus = bonus + (math.min(math.max(supportAmenities - 2, 0), 5) * 0.07)
				bonus = bonus + (math.min(amenities.ActiveSnowmaking or 0, 5) * 0.05)
				bonus = bonus + ((operational.SnowmakingCoverage or 0) * 0.22)

				if operational.CleanableBuildings > 0 then
					bonus = bonus + (math.max(0, operational.Cleanliness - 90) * 0.02)
					bonus = bonus + (operational.JanitorCoverageRatio * 0.18)
				end

				if math.max(0, tonumber(stats.TotalGuests) or 0) >= 15 then
					bonus = bonus + 0.08
				end

				changeRating(player, "PeriodicUpdate", bonus * 0.1)
			end
		end
	end
end)

-- // AUTOSAVE //
task.spawn(function()
	while true do
		task.wait(AUTOSAVE_INTERVAL)
		for _, player in pairs(Players:GetPlayers()) do savePlayerRating(player) end
	end
end)

-- // API //
local RatingSystem = {}
function RatingSystem.GetRating(player)
	if not player or not PlayerRatings[player.UserId] then return getFreshSaveStartingRating() end
	return PlayerRatings[player.UserId].Rating
end
function RatingSystem.ReportEvent(player, eventType, customAmount, statMeta)
	changeRating(player, eventType, customAmount, statMeta)
end
function RatingSystem.GetStats(player)
	if not player or not PlayerRatings[player.UserId] then
		return {
			TotalGuests = 0,
			HappyGuests = 0,
			HungryGuests = 0,
			EventCounts = {},
		}
	end
	local stats = ensureStatsTable(PlayerRatings[player.UserId])
	return {
		TotalGuests = stats.TotalGuests,
		HappyGuests = stats.HappyGuests,
		HungryGuests = stats.HungryGuests,
		EventCounts = table.clone(stats.EventCounts),
	}
end
function RatingSystem.GetSummary(player)
	local rating = RatingSystem.GetRating(player)
	local stats = RatingSystem.GetStats(player)
	local amenities = player and countAmenities(player.UserId) or {
		Lifts = 0,
		Slopes = 0,
		Food = 0,
		Lodging = 0,
		Restaurants = 0,
		Rentals = 0,
		Lodges = 0,
		Others = 0,
	}
	local totalGuests = math.max(0, tonumber(stats.TotalGuests) or 0)
	local happyGuests = math.max(0, tonumber(stats.HappyGuests) or 0)
	local hungryGuests = math.max(0, tonumber(stats.HungryGuests) or 0)
	local happyRatio = getSafeRatio(happyGuests, totalGuests)
	local hungryRatio = getSafeRatio(hungryGuests, totalGuests)
	local positiveShare = totalGuests > 0 and getPositiveShare(happyRatio, hungryRatio) or 0
	local operational = buildOperationalSignals(player, stats, amenities)
	local categoryScores = buildCategoryScores(rating, stats, amenities, happyRatio, hungryRatio, operational)
	local reviewLabel = totalGuests <= 0 and "Needs data" or pickReviewLabel(rating, happyRatio, hungryRatio, amenities, operational, categoryScores)
	local reviews, reviewCount = buildDynamicReviews(player, rating, stats, amenities, happyRatio, hungryRatio, categoryScores, operational)
	return {
		Rating = rating,
		Stats = stats,
		Amenities = {
			Lifts = amenities.Lifts,
			Food = amenities.Food,
			Lodging = amenities.Lodging,
		},
		Breakdown = {
			Restaurants = amenities.Restaurants,
			Rentals = amenities.Rentals,
			Lodges = amenities.Lodges,
			Others = amenities.Others,
			Lifts = amenities.Lifts,
		},
		Operational = {
			ReroutesPerMinute = operational.ReroutesPerMinute,
			FoodMisses = operational.FoodMisses,
			LiftMisses = operational.LiftMisses,
			BrokeExits = operational.BrokeExits,
			TiredExits = operational.TiredExits,
			GuestLoad = operational.GuestLoad,
			Cleanliness = operational.Cleanliness,
			DirtyBuildings = operational.DirtyBuildings,
			CleanableBuildings = operational.CleanableBuildings,
			JanitorCoverage = operational.JanitorCoverage,
			JanitorCoverageRatio = operational.JanitorCoverageRatio,
			Snowmaking = operational.Snowmaking,
			ActiveSnowmaking = operational.ActiveSnowmaking,
			SnowmakingCoverage = operational.SnowmakingCoverage,
		},
		CategoryScores = categoryScores,
		HappyRatio = happyRatio,
		HungryRatio = hungryRatio,
		ReviewLabel = reviewLabel,
		ReviewCount = reviewCount,
		PositiveShare = positiveShare,
		Reviews = reviews,
		RefreshEpoch = math.floor(os.time() / 45),
	}
end
function RatingSystem.SetRating(player, newRating)
	local data = PlayerRatings[player.UserId]
	if data then
		data.Rating = clampRating(newRating)
		updateLeaderstats(player, data.Rating)
		if player.UserId == getResortOwnerUserId() then
			RatingEvent:FireAllClients(data.Rating)
		else
			RatingEvent:FireClient(player, data.Rating)
		end
	end
end
_G.RatingSystem = RatingSystem

RatingSummaryRequest.OnServerInvoke = function(player)
	return RatingSystem.GetSummary(resolveSummaryPlayer(player))
end

return RatingSystem