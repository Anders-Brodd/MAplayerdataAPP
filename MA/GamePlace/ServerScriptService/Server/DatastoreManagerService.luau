local DataStoreService = game:GetService("DataStoreService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local ResearchFolder = ReplicatedStorage:FindFirstChild("Research")
local ResearchConfigModule = ResearchFolder and ResearchFolder:FindFirstChild("ResearchConfig")
local DecorConfigModule = ReplicatedStorage:FindFirstChild("DecorMilestoneConfig")

local ResearchConfig = nil
if ResearchConfigModule and ResearchConfigModule:IsA("ModuleScript") then
	local ok, result = pcall(require, ResearchConfigModule)
	if ok and type(result) == "table" then
		ResearchConfig = result
	end
end

local DecorConfig = nil
if DecorConfigModule and DecorConfigModule:IsA("ModuleScript") then
	local ok, result = pcall(require, DecorConfigModule)
	if ok and type(result) == "table" then
		DecorConfig = result
	end
end

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

local ResearchStoreName = (ResearchConfig and ResearchConfig.DataStoreName) or "TycoonResearchData"
local DecorStoreName = (DecorConfig and DecorConfig.DataStoreName) or "TycoonDecorMilestones"

local LegacyGameStore = DataStoreService:GetDataStore("TycoonGameData")
local LegacyBuildingStore = DataStoreService:GetDataStore("TycoonBuildings")
local LegacyTerrainMetaStore = DataStoreService:GetDataStore("TycoonTerrainGen")
local LegacyTerrainActionStore = DataStoreService:GetDataStore("TycoonTerrain")
local LegacyResearchStore = DataStoreService:GetDataStore(ResearchStoreName)
local LegacyEmployeeStore = DataStoreService:GetDataStore("EmployeeData")
local LegacyDecorStore = DataStoreService:GetDataStore(DecorStoreName)

local STORES = {
	Game = if CanonicalProfile then CanonicalProfile.CreateSlotStoreProxy(LegacyGameStore, "TycoonGameData", "GameData") else LegacyGameStore,
	Buildings = if CanonicalProfile then CanonicalProfile.CreateSlotStoreProxy(LegacyBuildingStore, "TycoonBuildings", "Buildings") else LegacyBuildingStore,
	TerrainMeta = if CanonicalProfile then CanonicalProfile.CreateSlotStoreProxy(LegacyTerrainMetaStore, "TycoonTerrainGen", "TerrainMeta") else LegacyTerrainMetaStore,
	TerrainActions = if CanonicalProfile then CanonicalProfile.CreateSlotStoreProxy(LegacyTerrainActionStore, "TycoonTerrain", "TerrainActions") else LegacyTerrainActionStore,
	Research = if CanonicalProfile then CanonicalProfile.CreateSlotStoreProxy(LegacyResearchStore, ResearchStoreName, "Research") else LegacyResearchStore,
	Employees = if CanonicalProfile then CanonicalProfile.CreateSlotStoreProxy(LegacyEmployeeStore, "EmployeeData", "Employees") else LegacyEmployeeStore,
	Decor = if CanonicalProfile then CanonicalProfile.CreateSlotStoreProxy(LegacyDecorStore, DecorStoreName, "Decor") else LegacyDecorStore,
	Audit = DataStoreService:GetDataStore("DevPanel_DatastoreAudit_v1"),
}

local MAX_SLOT_SCAN = 8
local MIN_SLOT_INDEX = 1

local Events = ReplicatedStorage:FindFirstChild("Events")

local Service = {}

local function safeGet(store, key)
	local ok, result = pcall(function()
		return store:GetAsync(key)
	end)
	if not ok then
		return false, nil
	end
	return true, result
end

local function safeSet(store, key, payload)
	local ok, err = pcall(function()
		store:SetAsync(key, payload)
	end)
	return ok, err
end

local function safeSetWithRetries(store, key, payload, maxRetries)
	local retries = math.max(1, math.floor(tonumber(maxRetries) or 3))
	local delaySeconds = 0.35
	local lastErr = nil
	for attempt = 1, retries do
		local ok, err = safeSet(store, key, payload)
		if ok then
			return true, nil
		end
		lastErr = err
		if attempt < retries then
			task.wait(delaySeconds)
			delaySeconds = math.min(2, delaySeconds * 1.75)
		end
	end
	return false, lastErr
end

local function safeRemove(store, key)
	local ok, err = pcall(function()
		store:RemoveAsync(key)
	end)
	return ok, err
end

local function safeRemoveWithRetries(store, key, maxRetries)
	local retries = math.max(1, math.floor(tonumber(maxRetries) or 3))
	local delaySeconds = 0.35
	local lastErr = nil
	for attempt = 1, retries do
		local ok, err = safeRemove(store, key)
		if ok then
			return true, nil
		end
		lastErr = err
		if attempt < retries then
			task.wait(delaySeconds)
			delaySeconds = math.min(2, delaySeconds * 1.75)
		end
	end
	return false, lastErr
end

local function toNumber(value)
	local n = tonumber(value)
	if not n then
		return nil
	end
	if n ~= n or n == math.huge or n == -math.huge then
		return nil
	end
	return n
end

local function gameDataKeys(userId, slotNum)
	return {
		string.format("User_%d_Slot_%d_GameData", userId, slotNum),
		string.format("User_%d_Slot%d_GameData", userId, slotNum),
		string.format("User_%d_Slot_%d", userId, slotNum),
		string.format("User_%d_Slot%d", userId, slotNum),
	}
end

local function extractCreatedTime(payload)
	if type(payload) ~= "table" then
		return nil
	end
	local createdTime = toNumber(payload.CreatedTime)
	if not createdTime or createdTime < 1 then
		return nil
	end
	return math.floor(createdTime + 0.5)
end

local function appendCreatedTimeSlotBases(keys, userId, slotNum, createdTime)
	local seen = {}
	for _, key in ipairs(keys) do
		seen[key] = true
	end
	local nCreatedTime = extractCreatedTime({CreatedTime = createdTime})
	if not nCreatedTime then
		return keys
	end
	local candidates = {
		string.format("User_%d_Slot_%d_CT_%d", userId, slotNum, nCreatedTime),
		string.format("User_%d_Slot%d_CT_%d", userId, slotNum, nCreatedTime),
	}
	for _, candidate in ipairs(candidates) do
		if not seen[candidate] then
			seen[candidate] = true
			table.insert(keys, 1, candidate)
		end
	end
	return keys
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
	}
	local bases = appendCreatedTimeSlotBases({}, userId, slotNum, createdTime)
	for _, base in ipairs(bases) do
		table.insert(keys, 1, base .. "_Terrain")
	end
	return keys
end

local function researchKeys(userId, slotNum, includeDefault)
	local keys = {
		string.format("User_%d_Slot_%d_ResearchV2", userId, slotNum),
		string.format("User_%d_Slot%d_ResearchV2", userId, slotNum),
	}
	if includeDefault ~= false then
		table.insert(keys, string.format("User_%d_Default_ResearchV2", userId))
	end
	return keys
end

local function employeeKeys(userId, slotNum, includeDefault)
	local keys = {
		string.format("User_%d_Slot_%d_Employees", userId, slotNum),
		string.format("User_%d_Slot%d_Employees", userId, slotNum),
		string.format("User_%d_Slot_%d_GameData_Employees", userId, slotNum),
		string.format("User_%d_Slot%d_GameData_Employees", userId, slotNum),
	}
	if includeDefault == true then
		table.insert(keys, string.format("User_%d_Default_Employees", userId))
	end
	return keys
end

local function decorKeys(userId, slotNum)
	return {
		string.format("User_%d_Slot_%d_DecorMilestones", userId, slotNum),
		string.format("User_%d_Slot%d_DecorMilestones", userId, slotNum),
	}
end

local function readFirst(store, keys)
	for _, key in ipairs(keys) do
		local ok, value = safeGet(store, key)
		if ok and value ~= nil then
			return value, key
		end
	end
	return nil, nil
end

local function hasAnyData(userId, slotNum)
	local checks = {
		{ Store = STORES.Game, Keys = gameDataKeys(userId, slotNum) },
		{ Store = STORES.Buildings, Keys = buildingsKeys(userId, slotNum) },
		{ Store = STORES.TerrainMeta, Keys = terrainMetaKeys(userId, slotNum) },
		{ Store = STORES.Research, Keys = researchKeys(userId, slotNum, false) },
	}
	for _, check in ipairs(checks) do
		local value = readFirst(check.Store, check.Keys)
		if value ~= nil then
			return true
		end
	end
	return false
end

local function sanitizeGamePatch(gameData)
	if type(gameData) ~= "table" then
		return nil
	end
	local out = {}
	if gameData.Money ~= nil then
		local money = toNumber(gameData.Money)
		if money then
			out.Money = math.max(0, math.floor(money + 0.5))
		end
	end
	if gameData.Tickets ~= nil then
		local tickets = toNumber(gameData.Tickets)
		if tickets then
			out.Tickets = math.max(0, math.floor(tickets + 0.5))
		end
	end
	return out
end

local function sanitizeResearchPatch(research)
	if type(research) ~= "table" then
		return nil
	end
	local out = {}
	if research.RP ~= nil then
		local rp = toNumber(research.RP)
		if rp then
			out.RP = math.max(0, math.floor(rp + 0.5))
		end
	end
	if research.MaxRP ~= nil then
		local maxRp = toNumber(research.MaxRP)
		if maxRp then
			out.MaxRP = math.max(0, math.floor(maxRp + 0.5))
		end
	end
	if type(research.Unlocked) == "table" then
		out.Unlocked = {}
		for techId, unlocked in pairs(research.Unlocked) do
			if type(techId) == "string" and unlocked == true then
				out.Unlocked[techId] = true
			end
		end
	end
	return out
end

function Service.DiscoverSlots(userId)
	local nUserId = toNumber(userId)
	if not nUserId or nUserId < 1 then
		return false, "Invalid user id"
	end
	local slots = {}
	for slot = 1, MAX_SLOT_SCAN do
		if hasAnyData(nUserId, slot) then
			table.insert(slots, slot)
		end
	end
	return true, slots
end

function Service.LoadSlot(userId, slotNum)
	local nUserId = toNumber(userId)
	local nSlot = toNumber(slotNum)
	if not nUserId or nUserId < 1 or not nSlot or nSlot < 1 then
		return false, "Invalid user/slot"
	end

	local gameData, gameKey = readFirst(STORES.Game, gameDataKeys(nUserId, nSlot))
	local createdTime = extractCreatedTime(gameData)
	local buildingsData, buildingsKey = readFirst(STORES.Buildings, buildingsKeys(nUserId, nSlot, createdTime))
	local terrainMetaData, terrainMetaKey = readFirst(STORES.TerrainMeta, terrainMetaKeys(nUserId, nSlot, createdTime))
	local terrainActionData, terrainActionKey = readFirst(STORES.TerrainActions, terrainActionKeys(nUserId, nSlot, createdTime))
	local researchData, researchKey = readFirst(STORES.Research, researchKeys(nUserId, nSlot, true))

	return true, {
		UserId = nUserId,
		SlotNum = nSlot,
		GameData = gameData,
		Buildings = buildingsData,
		TerrainMeta = terrainMetaData,
		TerrainActions = terrainActionData,
		Research = researchData,
		LoadedKeys = {
			GameData = gameKey,
			Buildings = buildingsKey,
			TerrainMeta = terrainMetaKey,
			TerrainActions = terrainActionKey,
			Research = researchKey,
		},
		ReadToken = tostring(os.time()) .. ":" .. tostring(math.random(10000, 99999)),
	}
end

function Service.SaveSlot(userId, slotNum, payload)
	local nUserId = toNumber(userId)
	local nSlot = toNumber(slotNum)
	if not nUserId or nUserId < 1 or not nSlot or nSlot < 1 then
		return false, "Invalid user/slot"
	end
	if type(payload) ~= "table" then
		return false, "Invalid payload"
	end

	local baseGameData = readFirst(STORES.Game, gameDataKeys(nUserId, nSlot)) or {}
	if type(baseGameData) ~= "table" then
		baseGameData = {}
	end
	local gamePatch = sanitizeGamePatch(payload.GameData)
	local createdTime = extractCreatedTime(baseGameData)
	if gamePatch then
		for key, value in pairs(gamePatch) do
			baseGameData[key] = value
		end
		baseGameData.UpdatedAt = os.time()
		local ok, err = safeSet(STORES.Game, gameDataKeys(nUserId, nSlot)[1], baseGameData)
		if not ok then
			return false, "Failed to save game data: " .. tostring(err)
		end
	end

	if type(payload.Buildings) == "table" then
		local ok, err = safeSet(STORES.Buildings, buildingsKeys(nUserId, nSlot, createdTime)[1], payload.Buildings)
		if not ok then
			return false, "Failed to save buildings: " .. tostring(err)
		end
	end

	if type(payload.TerrainMeta) == "table" then
		local ok, err = safeSet(STORES.TerrainMeta, terrainMetaKeys(nUserId, nSlot, createdTime)[1], payload.TerrainMeta)
		if not ok then
			return false, "Failed to save terrain metadata: " .. tostring(err)
		end
	end

	if type(payload.TerrainActions) == "table" then
		local ok, err = safeSet(STORES.TerrainActions, terrainActionKeys(nUserId, nSlot, createdTime)[1], payload.TerrainActions)
		if not ok then
			return false, "Failed to save terrain actions: " .. tostring(err)
		end
	end

	local baseResearch = readFirst(STORES.Research, researchKeys(nUserId, nSlot, true)) or {}
	if type(baseResearch) ~= "table" then
		baseResearch = {}
	end
	local researchPatch = sanitizeResearchPatch(payload.Research)
	if researchPatch then
		for key, value in pairs(researchPatch) do
			baseResearch[key] = value
		end
		baseResearch.Version = tonumber((ResearchConfig and ResearchConfig.SchemaVersion) or baseResearch.Version or 2) or 2
		baseResearch.LastSeen = os.time()
		local ok, err = safeSet(STORES.Research, researchKeys(nUserId, nSlot, true)[1], baseResearch)
		if not ok then
			return false, "Failed to save research: " .. tostring(err)
		end
	end

	return true
end

function Service.WipeSlot(userId, slotNum)
	local nUserId = toNumber(userId)
	local nSlot = toNumber(slotNum)
	if not nUserId or nUserId < 1 or not nSlot or nSlot < 1 then
		return false, "Invalid user/slot"
	end

	local gameData = readFirst(STORES.Game, gameDataKeys(nUserId, nSlot))
	local createdTime = extractCreatedTime(gameData)
	local wipes = {
		{ Store = STORES.Game, Keys = gameDataKeys(nUserId, nSlot) },
		{ Store = STORES.Buildings, Keys = buildingsKeys(nUserId, nSlot, createdTime) },
		{ Store = STORES.TerrainMeta, Keys = terrainMetaKeys(nUserId, nSlot, createdTime) },
		{ Store = STORES.TerrainActions, Keys = terrainActionKeys(nUserId, nSlot, createdTime) },
		{ Store = STORES.Research, Keys = researchKeys(nUserId, nSlot, false) },
		{ Store = STORES.Employees, Keys = employeeKeys(nUserId, nSlot, false) },
		{ Store = STORES.Decor, Keys = decorKeys(nUserId, nSlot) },
	}

	for _, wipe in ipairs(wipes) do
		for _, key in ipairs(wipe.Keys) do
			local ok, err = safeRemove(wipe.Store, key)
			if not ok then
				return false, "Failed to wipe key " .. tostring(key) .. ": " .. tostring(err)
			end
		end
	end

	return true
end

function Service.AppendAudit(record)
	if type(record) ~= "table" then
		return false, "Invalid audit record"
	end

	local targetUserId = tonumber(record.TargetUserId)
	local slotNum = tonumber(record.SlotNum)
	if not targetUserId or targetUserId < 1 or not slotNum or slotNum < 1 then
		return false, "Invalid audit target"
	end

	local key = string.format("Audit_%d_Slot_%d", targetUserId, slotNum)
	local entry = {
		Timestamp = os.time(),
		Action = tostring(record.Action or "Unknown"),
		ActorUserId = tonumber(record.ActorUserId) or 0,
		TargetUserId = targetUserId,
		SlotNum = slotNum,
		Success = record.Success == true,
		Summary = tostring(record.Summary or ""),
	}

	local ok, err = pcall(function()
		STORES.Audit:UpdateAsync(key, function(oldData)
			local list = {}
			if type(oldData) == "table" then
				for i = 1, math.min(#oldData, 99) do
					table.insert(list, oldData[i])
				end
			end
			table.insert(list, 1, entry)
			return list
		end)
	end)

	if not ok then
		return false, tostring(err)
	end

	return true
end

return Service
