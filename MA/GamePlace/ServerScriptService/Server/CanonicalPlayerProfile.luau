local DataStoreService = game:GetService("DataStoreService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local PROFILE_STORE_NAME = "MA_PlayerProfile_V1"
local PROFILE_VERSION = 1
local MAX_SLOT_SCAN = 8
local CACHE_TTL_SECONDS = 20

local profileStore = DataStoreService:GetDataStore(PROFILE_STORE_NAME)

local module = {}

local cacheByUserId = {}

local function deepCopy(value, depth)
	if type(value) ~= "table" then
		return value
	end
	if depth <= 0 then
		return {}
	end
	local out = {}
	for k, v in pairs(value) do
		out[k] = deepCopy(v, depth - 1)
	end
	return out
end

local function nowTs()
	return os.time()
end

local function getProfileKey(userId)
	return "u_" .. tostring(userId)
end

local function ensureProfileShape(raw, userId)
	local data = type(raw) == "table" and raw or {}
	if type(data.Slots) ~= "table" then
		data.Slots = {}
	end
	if type(data.Global) ~= "table" then
		data.Global = {}
	end
	if type(data.Migration) ~= "table" then
		data.Migration = {}
	end
	data.UserId = userId
	data.Version = PROFILE_VERSION
	data.LastSeenAt = nowTs()
	return data
end

local function ensureSlot(profile, slotNum, create)
	local key = tostring(slotNum)
	local slot = profile.Slots[key]
	if not slot and create then
		slot = {
			Meta = {
				CreatedAt = nowTs(),
				UpdatedAt = nowTs(),
				MigratedFromLegacy = false,
				LegacyKeys = {},
			},
		}
		profile.Slots[key] = slot
	end
	if slot and type(slot.Meta) ~= "table" then
		slot.Meta = {
			CreatedAt = nowTs(),
			UpdatedAt = nowTs(),
			MigratedFromLegacy = false,
			LegacyKeys = {},
		}
	end
	if slot and type(slot.Meta.LegacyKeys) ~= "table" then
		slot.Meta.LegacyKeys = {}
	end
	return slot
end

local function getCachedProfile(userId)
	local cached = cacheByUserId[userId]
	if not cached then
		return nil
	end
	if (os.clock() - cached.AtClock) > CACHE_TTL_SECONDS then
		cacheByUserId[userId] = nil
		return nil
	end
	return deepCopy(cached.Data, 8)
end

local function setCachedProfile(userId, profile)
	cacheByUserId[userId] = {
		AtClock = os.clock(),
		Data = deepCopy(profile, 8),
	}
end

local function loadProfile(userId, forceRefresh)
	if not forceRefresh then
		local cached = getCachedProfile(userId)
		if cached then
			return cached
		end
	end

	local key = getProfileKey(userId)
	local loaded = nil
	pcall(function()
		loaded = profileStore:GetAsync(key)
	end)

	local normalized = ensureProfileShape(loaded, userId)
	setCachedProfile(userId, normalized)
	return deepCopy(normalized, 8)
end

local function updateProfile(userId, mutator)
	local key = getProfileKey(userId)
	local saved = nil
	local ok, err = pcall(function()
		saved = profileStore:UpdateAsync(key, function(previous)
			local profile = ensureProfileShape(previous, userId)
			local result = mutator(profile)
			if type(result) == "table" then
				profile = result
			end
			profile.UserId = userId
			profile.Version = PROFILE_VERSION
			profile.LastSeenAt = nowTs()
			profile.LastUpdatedAt = nowTs()
			return profile
		end)
	end)
	if not ok then
		return false, err
	end
	local normalized = ensureProfileShape(saved, userId)
	setCachedProfile(userId, normalized)
	return true, deepCopy(normalized, 8)
end

local function parseUserSlotFromKey(key)
	if type(key) ~= "string" then
		return nil, nil
	end
	local userStr, slotStr = string.match(key, "^User_(%d+)_Slot_?(%d+)")
	if userStr and slotStr then
		return tonumber(userStr), tonumber(slotStr)
	end
	local tutUser, tutSlot = string.match(key, "^tutorial_(%d+)_slot_(%d+)$")
	if tutUser and tutSlot then
		return tonumber(tutUser), tonumber(tutSlot)
	end
	return nil, nil
end

local function parseUserFromKey(key)
	if type(key) ~= "string" then
		return nil
	end
	local userStr = string.match(key, "^User_(%d+)_")
	if userStr then
		return tonumber(userStr)
	end
	local rawUser = string.match(key, "^(%d+)$")
	if rawUser then
		return tonumber(rawUser)
	end
	local tutUser = string.match(key, "^tutorial_(%d+)_slot_%d+$")
	if tutUser then
		return tonumber(tutUser)
	end
	return nil
end

local function markLegacyKey(profile, slotNum, segment, legacyKey, storeName)
	local slot = ensureSlot(profile, slotNum, true)
	slot.Meta.UpdatedAt = nowTs()
	slot.Meta.MigratedFromLegacy = true
	slot.Meta.LastMigratedAt = nowTs()
	local marker = tostring(segment) .. "@" .. tostring(storeName or "legacy")
	slot.Meta.LegacyKeys[marker] = tostring(legacyKey)
end

local function tryReadSlotSegment(userId, slotNum, segment)
	local profile = loadProfile(userId, false)
	local slot = ensureSlot(profile, slotNum, false)
	if not slot then
		return nil
	end
	if slot[segment] == nil then
		return nil
	end
	return deepCopy(slot[segment], 8)
end

local function tryWriteSlotSegment(userId, slotNum, segment, value, legacyKey, storeName)
	local ok = updateProfile(userId, function(profile)
		local slot = ensureSlot(profile, slotNum, true)
		slot[segment] = deepCopy(value, 8)
		if legacyKey then
			markLegacyKey(profile, slotNum, segment, legacyKey, storeName)
		end
		return profile
	end)
	return ok
end

local function tryRemoveSlotSegment(userId, slotNum, segment)
	local ok = updateProfile(userId, function(profile)
		local slot = ensureSlot(profile, slotNum, false)
		if slot then
			slot[segment] = nil
			slot.Meta.UpdatedAt = nowTs()
		end
		return profile
	end)
	return ok
end

local function tryReadGlobalValue(userId, field)
	local profile = loadProfile(userId, false)
	if profile.Global[field] == nil then
		return nil
	end
	return deepCopy(profile.Global[field], 8)
end

local function tryWriteGlobalValue(userId, field, value, legacyKey, storeName)
	local ok = updateProfile(userId, function(profile)
		profile.Global[field] = deepCopy(value, 8)
		if legacyKey then
			profile.Migration[field] = profile.Migration[field] or {}
			profile.Migration[field].LegacyKey = tostring(legacyKey)
			profile.Migration[field].LegacyStore = tostring(storeName or "legacy")
			profile.Migration[field].LastMigratedAt = nowTs()
		end
		return profile
	end)
	return ok
end

local function extractCreatedTime(payload)
	if type(payload) ~= "table" then
		return nil
	end
	local created = tonumber(payload.CreatedTime)
	if not created or created < 1 then
		return nil
	end
	return math.floor(created + 0.5)
end

local function appendCreatedTimeSlotBases(keys, userId, slotNum, createdTime)
	local seen = {}
	for _, key in ipairs(keys) do
		seen[key] = true
	end
	local created = extractCreatedTime({ CreatedTime = createdTime })
	if not created then
		return keys
	end
	local bases = {
		string.format("User_%d_Slot_%d_CT_%d", userId, slotNum, created),
		string.format("User_%d_Slot%d_CT_%d", userId, slotNum, created),
	}
	for _, base in ipairs(bases) do
		if not seen[base] then
			seen[base] = true
			table.insert(keys, 1, base)
		end
	end
	return keys
end

local function gameDataKeys(userId, slotNum)
	return {
		string.format("User_%d_Slot_%d_GameData", userId, slotNum),
		string.format("User_%d_Slot%d_GameData", userId, slotNum),
		string.format("User_%d_Slot_%d", userId, slotNum),
		string.format("User_%d_Slot%d", userId, slotNum),
	}
end

local function buildingsKeys(userId, slotNum, createdTime)
	local keys = {
		string.format("User_%d_Slot_%d_Buildings_v2", userId, slotNum),
		string.format("User_%d_Slot_%d_Buildings", userId, slotNum),
		string.format("User_%d_Slot%d_Buildings", userId, slotNum),
	}
	local bases = appendCreatedTimeSlotBases({}, userId, slotNum, createdTime)
	for _, base in ipairs(bases) do
		table.insert(keys, 1, base .. "_Buildings_v3")
	end
	return keys
end

local function terrainMetaKeys(userId, slotNum, createdTime)
	local keys = {
		string.format("User_%d_Slot%d_TerrainMeta", userId, slotNum),
		string.format("User_%d_Slot_%d_TerrainMeta", userId, slotNum),
	}
	local bases = appendCreatedTimeSlotBases({}, userId, slotNum, createdTime)
	for _, base in ipairs(bases) do
		table.insert(keys, 1, base .. "_TerrainMeta")
	end
	return keys
end

local function terrainActionKeys(userId, slotNum, createdTime)
	local keys = {
		string.format("User_%d_Slot_%d_Terrain", userId, slotNum),
		string.format("User_%d_Slot%d_Terrain", userId, slotNum),
		string.format("User_%d_Slot%d", userId, slotNum),
	}
	local bases = appendCreatedTimeSlotBases({}, userId, slotNum, createdTime)
	for _, base in ipairs(bases) do
		table.insert(keys, 1, base .. "_Terrain")
	end
	return keys
end

local function researchKeys(userId, slotNum)
	return {
		string.format("User_%d_Slot_%d_ResearchV2", userId, slotNum),
		string.format("User_%d_Slot%d_ResearchV2", userId, slotNum),
		string.format("User_%d_Default_ResearchV2", userId),
	}
end

local function employeeKeys(userId, slotNum)
	return {
		string.format("User_%d_Slot_%d_Employees", userId, slotNum),
		string.format("User_%d_Slot%d_Employees", userId, slotNum),
		string.format("User_%d_Slot_%d_GameData_Employees", userId, slotNum),
		string.format("User_%d_Slot%d_GameData_Employees", userId, slotNum),
		string.format("User_%d_Default_Employees", userId),
	}
end

local function decorKeys(userId, slotNum)
	return {
		string.format("User_%d_Slot_%d_DecorMilestones", userId, slotNum),
		string.format("User_%d_Slot%d_DecorMilestones", userId, slotNum),
	}
end

local function tutorialKeys(userId, slotNum)
	return {
		string.format("tutorial_%d_slot_%d", userId, slotNum),
	}
end

local function environmentKeys(userId, slotNum)
	return {
		string.format("User_%d_Slot_%d_Env", userId, slotNum),
		string.format("User_%d_Slot%d_Env", userId, slotNum),
	}
end

local function readFirstExisting(store, keys)
	for _, key in ipairs(keys) do
		local ok, value = pcall(function()
			return store:GetAsync(key)
		end)
		if ok and value ~= nil then
			return value, key
		end
	end
	return nil, nil
end

local function getResearchStoreName()
	local researchFolder = ReplicatedStorage:FindFirstChild("Research")
	local configModule = researchFolder and researchFolder:FindFirstChild("ResearchConfig")
	if configModule and configModule:IsA("ModuleScript") then
		local ok, config = pcall(require, configModule)
		if ok and type(config) == "table" and type(config.DataStoreName) == "string" and config.DataStoreName ~= "" then
			return config.DataStoreName
		end
	end
	return "TycoonResearchData"
end

local function getDecorStoreName()
	local configModule = ReplicatedStorage:FindFirstChild("DecorMilestoneConfig")
	if configModule and configModule:IsA("ModuleScript") then
		local ok, config = pcall(require, configModule)
		if ok and type(config) == "table" and type(config.DataStoreName) == "string" and config.DataStoreName ~= "" then
			return config.DataStoreName
		end
	end
	return "TycoonDecorMilestones"
end

function module.MigrateUserFromLegacy(userId)
	local nUserId = tonumber(userId)
	if not nUserId or nUserId < 1 then
		return false, "Invalid user id"
	end

	local stores = {
		GameData = DataStoreService:GetDataStore("TycoonGameData"),
		Buildings = DataStoreService:GetDataStore("TycoonBuildings"),
		TerrainMeta = DataStoreService:GetDataStore("TycoonTerrainGen"),
		TerrainActions = DataStoreService:GetDataStore("TycoonTerrain"),
		Environment = DataStoreService:GetDataStore("TycoonEnvironment"),
		Tutorial = DataStoreService:GetDataStore("TutorialProgress_V1"),
		Research = DataStoreService:GetDataStore(getResearchStoreName()),
		Employees = DataStoreService:GetDataStore("EmployeeData"),
		Decor = DataStoreService:GetDataStore(getDecorStoreName()),
		WaypointPreferences = DataStoreService:GetDataStore("TycoonWaypointPreferences_v1"),
		DailyRewards = DataStoreService:GetDataStore("DailyRewards_v1"),
		SlotPurchases = DataStoreService:GetDataStore("SlotPurchases_v1"),
		FriendWhitelist = DataStoreService:GetDataStore("FriendWhitelist_v1"),
	}

	local migratedSlots = 0
	for slotNum = 1, MAX_SLOT_SCAN do
		local gameData, gameKey = readFirstExisting(stores.GameData, gameDataKeys(nUserId, slotNum))
		local createdTime = extractCreatedTime(gameData)
		local buildings, buildingsKey = readFirstExisting(stores.Buildings, buildingsKeys(nUserId, slotNum, createdTime))
		local terrainMeta, terrainMetaKey = readFirstExisting(stores.TerrainMeta, terrainMetaKeys(nUserId, slotNum, createdTime))
		local terrainActions, terrainActionsKey = readFirstExisting(stores.TerrainActions, terrainActionKeys(nUserId, slotNum, createdTime))
		local environmentData, environmentKey = readFirstExisting(stores.Environment, environmentKeys(nUserId, slotNum))
		local tutorialData, tutorialKey = readFirstExisting(stores.Tutorial, tutorialKeys(nUserId, slotNum))
		local research, researchKey = readFirstExisting(stores.Research, researchKeys(nUserId, slotNum))
		local employees, employeesKey = readFirstExisting(stores.Employees, employeeKeys(nUserId, slotNum))
		local decor, decorKey = readFirstExisting(stores.Decor, decorKeys(nUserId, slotNum))

		if gameData ~= nil or buildings ~= nil or terrainMeta ~= nil or terrainActions ~= nil or environmentData ~= nil or tutorialData ~= nil or research ~= nil or employees ~= nil or decor ~= nil then
			updateProfile(nUserId, function(profile)
				local slot = ensureSlot(profile, slotNum, true)
				if slot.GameData == nil and gameData ~= nil then
					slot.GameData = deepCopy(gameData, 8)
					markLegacyKey(profile, slotNum, "GameData", gameKey or "", "TycoonGameData")
				end
				if slot.Buildings == nil and buildings ~= nil then
					slot.Buildings = deepCopy(buildings, 8)
					markLegacyKey(profile, slotNum, "Buildings", buildingsKey or "", "TycoonBuildings")
				end
				if slot.TerrainMeta == nil and terrainMeta ~= nil then
					slot.TerrainMeta = deepCopy(terrainMeta, 8)
					markLegacyKey(profile, slotNum, "TerrainMeta", terrainMetaKey or "", "TycoonTerrainGen")
				end
				if slot.TerrainActions == nil and terrainActions ~= nil then
					slot.TerrainActions = deepCopy(terrainActions, 8)
					markLegacyKey(profile, slotNum, "TerrainActions", terrainActionsKey or "", "TycoonTerrain")
				end
				if slot.Environment == nil and environmentData ~= nil then
					slot.Environment = deepCopy(environmentData, 8)
					markLegacyKey(profile, slotNum, "Environment", environmentKey or "", "TycoonEnvironment")
				end
				if slot.Tutorial == nil and tutorialData ~= nil then
					slot.Tutorial = deepCopy(tutorialData, 8)
					markLegacyKey(profile, slotNum, "Tutorial", tutorialKey or "", "TutorialProgress_V1")
				end
				if slot.Research == nil and research ~= nil then
					slot.Research = deepCopy(research, 8)
					markLegacyKey(profile, slotNum, "Research", researchKey or "", getResearchStoreName())
				end
				if slot.Employees == nil and employees ~= nil then
					slot.Employees = deepCopy(employees, 8)
					markLegacyKey(profile, slotNum, "Employees", employeesKey or "", "EmployeeData")
				end
				if slot.Decor == nil and decor ~= nil then
					slot.Decor = deepCopy(decor, 8)
					markLegacyKey(profile, slotNum, "Decor", decorKey or "", getDecorStoreName())
				end
				slot.Meta.MigratedFromLegacy = true
				slot.Meta.LastMigratedAt = nowTs()
				return profile
			end)
			migratedSlots += 1
		end
	end

	local waypointKey = string.format("User_%d_WaypointPreferences", nUserId)
	local waypointData = readFirstExisting(stores.WaypointPreferences, { waypointKey })
	if waypointData ~= nil then
		updateProfile(nUserId, function(profile)
			if profile.Global.WaypointPreferences == nil then
				profile.Global.WaypointPreferences = deepCopy(waypointData, 8)
				profile.Migration.WaypointPreferences = {
					LegacyStore = "TycoonWaypointPreferences_v1",
					LegacyKey = waypointKey,
					LastMigratedAt = nowTs(),
				}
			end
			return profile
		end)
	end

	local dailyKey = tostring(nUserId)
	local dailyData = readFirstExisting(stores.DailyRewards, { dailyKey })
	if dailyData ~= nil then
		updateProfile(nUserId, function(profile)
			if profile.Global.DailyRewards == nil then
				profile.Global.DailyRewards = deepCopy(dailyData, 8)
				profile.Migration.DailyRewards = {
					LegacyStore = "DailyRewards_v1",
					LegacyKey = dailyKey,
					LastMigratedAt = nowTs(),
				}
			end
			return profile
		end)
	end

	local purchasesKey = tostring(nUserId)
	local purchasesData = readFirstExisting(stores.SlotPurchases, { purchasesKey })
	if purchasesData ~= nil then
		updateProfile(nUserId, function(profile)
			if profile.Global.SlotPurchases == nil then
				profile.Global.SlotPurchases = deepCopy(purchasesData, 8)
				profile.Migration.SlotPurchases = {
					LegacyStore = "SlotPurchases_v1",
					LegacyKey = purchasesKey,
					LastMigratedAt = nowTs(),
				}
			end
			return profile
		end)
	end

	local whitelistKey = tostring(nUserId)
	local whitelistData = readFirstExisting(stores.FriendWhitelist, { whitelistKey })
	if whitelistData ~= nil then
		updateProfile(nUserId, function(profile)
			if profile.Global.FriendWhitelist == nil then
				profile.Global.FriendWhitelist = deepCopy(whitelistData, 8)
				profile.Migration.FriendWhitelist = {
					LegacyStore = "FriendWhitelist_v1",
					LegacyKey = whitelistKey,
					LastMigratedAt = nowTs(),
				}
			end
			return profile
		end)
	end

	updateProfile(nUserId, function(profile)
		profile.Migration.LastFullMigrationAt = nowTs()
		profile.Migration.LastFullMigrationPlaceId = game.PlaceId
		return profile
	end)

	return true, {
		MigratedSlots = migratedSlots,
	}
end

function module.CreateSlotStoreProxy(legacyStore, storeName, segment)
	local proxy = {}

	function proxy:GetAsync(key)
		local userId, slotNum = parseUserSlotFromKey(key)
		if not userId or not slotNum then
			if segment == "Research" and type(key) == "string" then
				local u = string.match(key, "^User_(%d+)_Default_ResearchV2$")
				if u then
					userId = tonumber(u)
					slotNum = 1
				end
			end
		end
		if userId and slotNum then
			local canonicalValue = tryReadSlotSegment(userId, slotNum, segment)
			if canonicalValue ~= nil then
				return canonicalValue
			end
			local legacyValue = legacyStore:GetAsync(key)
			if legacyValue ~= nil then
				local ok = tryWriteSlotSegment(userId, slotNum, segment, legacyValue, key, storeName)
				if not ok then
					warn("[CanonicalProfile] Failed to migrate " .. tostring(storeName) .. " key " .. tostring(key))
				end
			end
			return legacyValue
		end
		return legacyStore:GetAsync(key)
	end

	function proxy:SetAsync(key, value, userIds, options)
		local result = legacyStore:SetAsync(key, value, userIds, options)
		local userId, slotNum = parseUserSlotFromKey(key)
		if not userId or not slotNum then
			if segment == "Research" and type(key) == "string" then
				local u = string.match(key, "^User_(%d+)_Default_ResearchV2$")
				if u then
					userId = tonumber(u)
					slotNum = 1
				end
			end
		end
		if userId and slotNum then
			local ok = tryWriteSlotSegment(userId, slotNum, segment, value, key, storeName)
			if not ok then
				warn("[CanonicalProfile] Failed to mirror SetAsync for " .. tostring(storeName) .. " key " .. tostring(key))
			end
		end
		return result
	end

	function proxy:UpdateAsync(key, transformFunction, userIds, options)
		local result = legacyStore:UpdateAsync(key, transformFunction, userIds, options)
		local userId, slotNum = parseUserSlotFromKey(key)
		if not userId or not slotNum then
			if segment == "Research" and type(key) == "string" then
				local u = string.match(key, "^User_(%d+)_Default_ResearchV2$")
				if u then
					userId = tonumber(u)
					slotNum = 1
				end
			end
		end
		if userId and slotNum and result ~= nil then
			local ok = tryWriteSlotSegment(userId, slotNum, segment, result, key, storeName)
			if not ok then
				warn("[CanonicalProfile] Failed to mirror UpdateAsync for " .. tostring(storeName) .. " key " .. tostring(key))
			end
		end
		return result
	end

	function proxy:RemoveAsync(key, userIds, options)
		local result = legacyStore:RemoveAsync(key, userIds, options)
		local userId, slotNum = parseUserSlotFromKey(key)
		if userId and slotNum then
			tryRemoveSlotSegment(userId, slotNum, segment)
		end
		return result
	end

	return proxy
end

function module.CreateUserStoreProxy(legacyStore, storeName, field)
	local proxy = {}

	function proxy:GetAsync(key)
		local userId = parseUserFromKey(key)
		if userId then
			local canonicalValue = tryReadGlobalValue(userId, field)
			if canonicalValue ~= nil then
				return canonicalValue
			end
			local legacyValue = legacyStore:GetAsync(key)
			if legacyValue ~= nil then
				local ok = tryWriteGlobalValue(userId, field, legacyValue, key, storeName)
				if not ok then
					warn("[CanonicalProfile] Failed to migrate global key " .. tostring(key))
				end
			end
			return legacyValue
		end
		return legacyStore:GetAsync(key)
	end

	function proxy:SetAsync(key, value, userIds, options)
		local result = legacyStore:SetAsync(key, value, userIds, options)
		local userId = parseUserFromKey(key)
		if userId then
			local ok = tryWriteGlobalValue(userId, field, value, key, storeName)
			if not ok then
				warn("[CanonicalProfile] Failed to mirror global SetAsync for key " .. tostring(key))
			end
		end
		return result
	end

	function proxy:UpdateAsync(key, transformFunction, userIds, options)
		local result = legacyStore:UpdateAsync(key, transformFunction, userIds, options)
		local userId = parseUserFromKey(key)
		if userId and result ~= nil then
			local ok = tryWriteGlobalValue(userId, field, result, key, storeName)
			if not ok then
				warn("[CanonicalProfile] Failed to mirror global UpdateAsync for key " .. tostring(key))
			end
		end
		return result
	end

	function proxy:RemoveAsync(key, userIds, options)
		local result = legacyStore:RemoveAsync(key, userIds, options)
		local userId = parseUserFromKey(key)
		if userId then
			updateProfile(userId, function(profile)
				profile.Global[field] = nil
				return profile
			end)
		end
		return result
	end

	return proxy
end

return module
