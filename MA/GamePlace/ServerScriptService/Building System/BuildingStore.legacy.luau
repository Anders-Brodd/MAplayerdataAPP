--[=[ PATH: ServerScriptService/Building System/BuildingStore | TYPE: Script ]=]--
--[[
	💾 BUILDING STORE V4.2 (MAGIC CARPET SAVE SUPPORT)
	
	WHAT THE OLD SCRIPT DID:
	- Managed saving and restoring of items, including TwoPoint and Slope models.
	
	WHAT THIS SCRIPT DOES NOW (ADDED/REMOVED):
	- ADDED: Handles `Type = "Carpet"` internally as a subset of the TwoPoint save structure. Carpets will properly save and restore their start and end positions securely without requiring pole data.
]]

local Players = game:GetService("Players")
local DataStoreService = game:GetService("DataStoreService")
local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

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

local Config = require(ReplicatedStorage:WaitForChild("Config"))
local CustomBuildingConfig = require(ReplicatedStorage:WaitForChild("CustomBuildingConfig"))
local STORE_NAME = "TycoonBuildings" 
local LegacyStore = DataStoreService:GetDataStore(STORE_NAME)
local STORE = if CanonicalProfile
	then CanonicalProfile.CreateSlotStoreProxy(LegacyStore, STORE_NAME, "Buildings")
	else LegacyStore
local BACKUP_STORE = DataStoreService:GetDataStore("TycoonBuildingsBackups_v1")
local LegacyGameDataStore = DataStoreService:GetDataStore("TycoonGameData")
local GAME_DATA_STORE = if CanonicalProfile
	then CanonicalProfile.CreateSlotStoreProxy(LegacyGameDataStore, "TycoonGameData", "GameData")
	else LegacyGameDataStore

local SLOT_NUM = 0
local USER_ID = 0
local LAST_SESSION_SAVE_AT = 0
local SESSION_SAVE_COOLDOWN_SECONDS = 30
local FORCED_SAVE_COOLDOWN_SECONDS = 3
local SAVE_IN_FLIGHT = false
local _buildingsDirty = false  -- only save when something actually changed

local Events = ReplicatedStorage:WaitForChild("Events")
local WipeEvent = Events:WaitForChild("WipeBuildingStore", 10) or Instance.new("BindableEvent", Events)
if WipeEvent.Name ~= "WipeBuildingStore" then WipeEvent.Name = "WipeBuildingStore" end
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

local BuildingSaveNow = Events:FindFirstChild("BuildingRequestSaveNow")
if BuildingSaveNow and not BuildingSaveNow:IsA("BindableFunction") then
	BuildingSaveNow:Destroy()
	BuildingSaveNow = nil
end
if not BuildingSaveNow then
	BuildingSaveNow = Instance.new("BindableFunction")
	BuildingSaveNow.Name = "BuildingRequestSaveNow"
	BuildingSaveNow.Parent = Events
end

local BuildingForceReload = Events:FindFirstChild("BuildingForceReload")
if BuildingForceReload and not BuildingForceReload:IsA("BindableFunction") then
	BuildingForceReload:Destroy()
	BuildingForceReload = nil
end
if not BuildingForceReload then
	BuildingForceReload = Instance.new("BindableFunction")
	BuildingForceReload.Name = "BuildingForceReload"
	BuildingForceReload.Parent = Events
end

local TerrainReady = Events:WaitForChild("TerrainReady", 10)
local BuildingRestoreReady = Events:FindFirstChild("BuildingRestoreReady")
if not BuildingRestoreReady then
	BuildingRestoreReady = Instance.new("BindableEvent")
	BuildingRestoreReady.Name = "BuildingRestoreReady"
	BuildingRestoreReady.Parent = Events
end

-- Tree tracking event (keeps trees deleted persistently)
local TrackDeletedTree = Events:FindFirstChild("TrackDeletedTree")

local SlotDataValue = ReplicatedStorage:FindFirstChild("SlotData") or Instance.new("Folder")
SlotDataValue.Name = "SlotData"
SlotDataValue.Parent = ReplicatedStorage

local SlotCreatedTimeValue = SlotDataValue:FindFirstChild("CreatedTime")
if SlotCreatedTimeValue and not SlotCreatedTimeValue:IsA("IntValue") then
	SlotCreatedTimeValue:Destroy()
	SlotCreatedTimeValue = nil
end
if not SlotCreatedTimeValue then
	SlotCreatedTimeValue = Instance.new("IntValue")
	SlotCreatedTimeValue.Name = "CreatedTime"
	SlotCreatedTimeValue.Parent = SlotDataValue
end

-- ============================================================
-- FIND PLACEMENT SERVER
-- ============================================================
local function FindScript(name)
	local scriptObj = ServerScriptService:FindFirstChild(name)
	if scriptObj and scriptObj:IsA("Script") then return scriptObj end
	local serverFolder = ServerScriptService:FindFirstChild("Server")
	if serverFolder and serverFolder:FindFirstChild(name) then return serverFolder[name] end
	local buildFolder = ServerScriptService:FindFirstChild("Building System")
	if buildFolder then
		local found = buildFolder:FindFirstChild(name)
		if found then return found end
	end
	return ServerScriptService:FindFirstChild(name, true)
end

local PlacementScript = FindScript("PlacementServer")
local RealRestoreEvent = nil

if PlacementScript then
	RealRestoreEvent = PlacementScript:WaitForChild("RestoreItem", 10)
else
end

local function ensurePlacementRestoreBridge()
	if RealRestoreEvent and RealRestoreEvent.Parent then
		return RealRestoreEvent
	end
	local placementScript = FindScript("PlacementServer")
	if placementScript then
		RealRestoreEvent = placementScript:WaitForChild("RestoreItem", 120)
	end
	if not RealRestoreEvent then
		warn("[BuildingStore] PlacementServer.RestoreItem missing after extended wait; building/lift restores cannot run.")
	end
	return RealRestoreEvent
end

-- ============================================================
-- HELPERS (LEGACY COMPATIBLE)
-- ============================================================
local function packVector3(v) 
	return {v.X, v.Y, v.Z}
end

local function unpackVector3(t) 
	return Vector3.new(t[1], t[2], t[3]) 
end

local function packColor3(color)
	return {color.R, color.G, color.B}
end

local function unpackColor3(values)
	return Color3.new(values[1], values[2], values[3])
end

local function packCFrame(cf) 
	return {cf:GetComponents()} 
end

local function unpackCFrame(t) 
	return CFrame.new(table.unpack(t)) 
end

local MAX_RESTORE_COMPONENT_MAGNITUDE = 200000
local MAX_RESTORE_TREE_SWEEP_SECONDS = 8
local TREE_SWEEP_YIELD_INTERVAL = 6

local function isFiniteNumber(value)
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function sanitizeRestoreNumber(value, clampMagnitude)
	local num = tonumber(value)
	if not isFiniteNumber(num) then
		return nil
	end
	if clampMagnitude then
		num = math.clamp(num, -clampMagnitude, clampMagnitude)
	end
	return num
end

local function unpackVector3Safe(t)
	if type(t) ~= "table" then
		return nil
	end
	local x = sanitizeRestoreNumber(t[1], MAX_RESTORE_COMPONENT_MAGNITUDE)
	local y = sanitizeRestoreNumber(t[2], MAX_RESTORE_COMPONENT_MAGNITUDE)
	local z = sanitizeRestoreNumber(t[3], MAX_RESTORE_COMPONENT_MAGNITUDE)
	if not x or not y or not z then
		return nil
	end
	return Vector3.new(x, y, z)
end

local function unpackColor3Safe(values)
	if type(values) ~= "table" then
		return nil
	end
	local r = sanitizeRestoreNumber(values[1], nil)
	local g = sanitizeRestoreNumber(values[2], nil)
	local b = sanitizeRestoreNumber(values[3], nil)
	if not r or not g or not b then
		return nil
	end
	return Color3.new(math.clamp(r, 0, 1), math.clamp(g, 0, 1), math.clamp(b, 0, 1))
end

local function unpackCFrameSafe(t)
	if type(t) ~= "table" or #t < 12 then
		return nil
	end
	local components = table.create(12)
	for i = 1, 12 do
		local value = sanitizeRestoreNumber(t[i], MAX_RESTORE_COMPONENT_MAGNITUDE)
		if not value then
			return nil
		end
		components[i] = value
	end
	return CFrame.new(table.unpack(components))
end

local function readSlotIdentityNumber(inst)
	if not inst then
		return 0
	end
	if inst:IsA("IntValue") or inst:IsA("NumberValue") then
		return math.floor(tonumber(inst.Value) or 0)
	end
	if inst:IsA("StringValue") then
		return math.floor(tonumber(inst.Value) or 0)
	end
	return 0
end

local function getActiveSlotIdentity()
	local slotData = ReplicatedStorage:FindFirstChild("SlotData")
	local activeUserId = 0
	local activeSlotNum = 0
	if slotData then
		activeUserId = readSlotIdentityNumber(slotData:FindFirstChild("UserId"))
		activeSlotNum = readSlotIdentityNumber(slotData:FindFirstChild("SlotNum"))
	end
	if activeUserId > 0 and activeSlotNum > 0 then
		return activeUserId, activeSlotNum
	end
	if USER_ID > 0 and SLOT_NUM > 0 then
		return USER_ID, SLOT_NUM
	end
	return nil, nil
end

local function syncCachedSlotIdentity()
	local activeUserId, activeSlotNum = getActiveSlotIdentity()
	if activeUserId and activeSlotNum then
		USER_ID = activeUserId
		SLOT_NUM = activeSlotNum
		return activeUserId, activeSlotNum
	end
	return nil, nil
end

local function getSessionCreatedTime()
	if SlotCreatedTimeValue and SlotCreatedTimeValue:IsA("IntValue") then
		return tonumber(SlotCreatedTimeValue.Value) or 0
	end
	return 0
end

local function isFreshSaveSession()
	return SlotDataValue:GetAttribute("FreshSave") == true
end

local function getKey(userId, slotNum)
	userId = userId or USER_ID
	slotNum = slotNum or SLOT_NUM
	if (not userId or userId == 0) or (not slotNum or slotNum == 0) then
		userId, slotNum = getActiveSlotIdentity()
	end
	if not userId or not slotNum or slotNum == 0 or userId == 0 then return nil end
	local ct = getSessionCreatedTime()
	if ct > 0 then
		return string.format("User_%d_Slot_%d_CT_%d_Buildings_v3", userId, slotNum, ct)
	end
	return "User_" .. userId .. "_Slot_" .. slotNum .. "_Buildings_v2"
end

local function getLoadKeys(userId, slotNum)
	local keys = {}
	local seen = {}
	local function push(key)
		if type(key) ~= "string" or key == "" or seen[key] then
			return
		end
		seen[key] = true
		table.insert(keys, key)
	end

	-- Primary key includes CreatedTime when available (isolates new saves after slot reuse).
	push(getKey(userId, slotNum))

	-- Legacy keys: only when this session is NOT a fresh save, so new saves never pull old slot buildings.
	if not isFreshSaveSession() and userId and slotNum then
		push(string.format("User_%d_Slot_%d_Buildings_v2", userId, slotNum))
		push(string.format("User_%d_Slot_%d_Buildings", userId, slotNum))
		push(string.format("User_%d_Slot%d_Buildings", userId, slotNum))
		if type(_G.GetSlotKey) == "function" then
			local ok, slotBase = pcall(_G.GetSlotKey, userId)
			if ok and type(slotBase) == "string" and slotBase ~= "" then
				push(slotBase .. "_Buildings_v2")
			end
		end
	end
	return keys
end

local function getGameDataLoadKeys(userId, slotNum)
	if not userId or not slotNum then
		return {}
	end
	return {
		string.format("User_%d_Slot_%d_GameData", userId, slotNum),
		string.format("User_%d_Slot%d_GameData", userId, slotNum),
		string.format("User_%d_Slot_%d", userId, slotNum),
		string.format("User_%d_Slot%d", userId, slotNum),
	}
end

local function sessionHasExistingGameData(userId, slotNum)
	if not userId or not slotNum then
		return nil
	end
	local hadLookupError = false
	for _, key in ipairs(getGameDataLoadKeys(userId, slotNum)) do
		local ok, payload = pcall(function()
			return GAME_DATA_STORE:GetAsync(key)
		end)
		if ok then
			if type(payload) == "table" and (payload.CreatedTime ~= nil or payload.Money ~= nil or payload.Objects ~= nil or payload.ResortName ~= nil) then
				return true
			end
		else
			hadLookupError = true
			warn("[BuildingStore] Game data lookup failed for key " .. tostring(key) .. ": " .. tostring(payload))
		end
	end
	if hadLookupError then
		return nil
	end
	return false
end

local function wipeKeysFromStore(store, keys, label)
	for _, key in ipairs(keys) do
		local ok, err = pcall(function()
			store:RemoveAsync(key)
		end)
		if not ok then
			warn("[BuildingStore] Failed to wipe " .. tostring(label) .. " key " .. tostring(key) .. ": " .. tostring(err))
		end
	end
end

local function wipeStaleBuildingData(userId, slotNum)
	local keys = getLoadKeys(userId, slotNum)
	wipeKeysFromStore(STORE, keys, "building")
	wipeKeysFromStore(BACKUP_STORE, keys, "building backup")
end

local function wipeLegacyBuildingKeysNoCT(userId, slotNum)
	if not userId or not slotNum then
		return
	end
	local legacy = {
		string.format("User_%d_Slot_%d_Buildings_v2", userId, slotNum),
		string.format("User_%d_Slot_%d_Buildings", userId, slotNum),
		string.format("User_%d_Slot%d_Buildings", userId, slotNum),
	}
	wipeKeysFromStore(STORE, legacy, "legacy building")
	wipeKeysFromStore(BACKUP_STORE, legacy, "legacy building backup")
end

local function loadStoreWithRetries(key)
	local lastErr = nil
	for attempt = 1, 4 do
		local ok, result = pcall(function()
			return STORE:GetAsync(key)
		end)
		if ok then
			return true, result
		end
		lastErr = result
		task.wait(0.8 * attempt)
	end
	return false, nil, tostring(lastErr)
end

local function loadBestBackupSnapshot(keys, expectedCreatedTime)
	local bestData = nil
	local bestKey = nil
	local bestScore = -math.huge
	expectedCreatedTime = tonumber(expectedCreatedTime) or 0
	for _, key in ipairs(keys) do
		local ok, backup = pcall(function()
			return BACKUP_STORE:GetAsync(key)
		end)
		if ok and type(backup) == "table" then
			local savedCreatedTime = tonumber(backup.CreatedTime) or 0
			local score = math.clamp(#backup, 0, 200000)
			if expectedCreatedTime > 0 then
				if savedCreatedTime == expectedCreatedTime then
					score += 1000000
				elseif savedCreatedTime > 0 then
					score -= 1000000
				end
			elseif savedCreatedTime > 0 then
				score += 1000
			end
			score += (tonumber(backup.__SavedAt) or 0) * 0.000001
			if score > bestScore then
				bestScore = score
				bestData = backup
				bestKey = key
			end
		end
	end
	return bestData, bestKey
end

local function saveBackupSnapshot(key, payload)
	local backupPayload = {
		__SavedAt = os.time(),
	}
	if type(payload) == "table" then
		local createdTime = tonumber(payload.CreatedTime) or 0
		if createdTime > 0 then
			backupPayload.CreatedTime = createdTime
		end
	end
	for i, entry in ipairs(payload) do
		if type(entry) == "table" then
			backupPayload[i] = table.clone(entry)
		else
			backupPayload[i] = entry
		end
	end
	pcall(function()
		BACKUP_STORE:UpdateAsync(key, function(oldData)
			local oldTs = type(oldData) == "table" and tonumber(oldData.__SavedAt) or 0
			if oldTs and oldTs > backupPayload.__SavedAt then
				return oldData
			end
			return backupPayload
		end)
	end)
end

local function deepCopy(value)
	if type(value) ~= "table" then
		return value
	end

	local copy = {}
	for key, child in pairs(value) do
		copy[key] = deepCopy(child)
	end
	return copy
end

local function copyChunkedAttributeToData(model, data, baseAttrName, chunkCountAttrName)
	local chunkCount = math.max(0, math.floor(tonumber(model:GetAttribute(chunkCountAttrName)) or 0))
	if chunkCount <= 1 then
		local rawValue = model:GetAttribute(baseAttrName)
		if type(rawValue) == "string" and rawValue ~= "" then
			data[baseAttrName] = rawValue
		end
		return
	end

	data[chunkCountAttrName] = chunkCount
	for i = 1, chunkCount do
		local attrName = (i == 1) and baseAttrName or (baseAttrName .. "_" .. i)
		local rawValue = model:GetAttribute(attrName)
		if type(rawValue) == "string" and rawValue ~= "" then
			data[attrName] = rawValue
		end
	end
end

local function copyRestoreSnapshotsToData(model, data)
	if not model or type(data) ~= "table" then
		return
	end

	local treeSnapshot = model:GetAttribute("TreeSnapshot")
	if type(treeSnapshot) == "string" and treeSnapshot ~= "" then
		data.TreeSnapshot = treeSnapshot
	end

	local treeMoveSnapshot = model:GetAttribute("TreeMoveSnapshot")
	if type(treeMoveSnapshot) == "string" and treeMoveSnapshot ~= "" then
		data.TreeMoveSnapshot = treeMoveSnapshot
	end

	copyChunkedAttributeToData(model, data, "TerrainSnapshot", "TerrainSnapshotChunkCount")
end

local function copyStoredSnapshotsToPayload(stored, payload)
	if type(stored) ~= "table" or type(payload) ~= "table" then
		return
	end

	local treeSnapshot = stored.TreeSnapshot
	if type(treeSnapshot) == "string" and treeSnapshot ~= "" then
		payload.TreeSnapshot = treeSnapshot
	end

	local treeMoveSnapshot = stored.TreeMoveSnapshot
	if type(treeMoveSnapshot) == "string" and treeMoveSnapshot ~= "" then
		payload.TreeMoveSnapshot = treeMoveSnapshot
	end

	local chunkCount = math.max(0, math.floor(tonumber(stored.TerrainSnapshotChunkCount) or 0))
	if chunkCount <= 1 then
		local rawValue = stored.TerrainSnapshot
		if type(rawValue) == "string" and rawValue ~= "" then
			payload.TerrainSnapshot = rawValue
		end
		return
	end

	payload.TerrainSnapshotChunkCount = chunkCount
	for i = 1, chunkCount do
		local attrName = (i == 1) and "TerrainSnapshot" or ("TerrainSnapshot_" .. i)
		local rawValue = stored[attrName]
		if type(rawValue) == "string" and rawValue ~= "" then
			payload[attrName] = rawValue
		end
	end
end

local function getStoredEntryScore(entry)
	if type(entry) ~= "table" then
		return 0
	end

	local score = 0
	for key, value in pairs(entry) do
		if value ~= nil then
			score += 1
			if type(value) == "table" then
				score += 1
			elseif type(value) == "string" then
				score += math.min(#value, 64) / 64
			end
		end
	end
	return score
end

-- Prefer the save row with more serialized trail geometry when UUIDs collide (B-033).
local function slopeSavePayloadWeight(entry)
	if type(entry) ~= "table" or entry.Type ~= "Slope" then
		return -1
	end
	local w = 0
	for _, key in ipairs({ "PathJson", "PointsJson", "ControlPointsJson", "WidthDataJson" }) do
		local v = entry[key]
		if type(v) == "string" then
			w += #v
		end
	end
	return w
end

local function dedupeStoredObjectsByUUID(entries)
	local deduped = {}
	local indexByUUID = {}

	for _, entry in ipairs(entries) do
		local uuid = type(entry) == "table" and entry.UUID or nil
		if type(uuid) == "string" and uuid ~= "" then
			local existingIndex = indexByUUID[uuid]
			if existingIndex then
				local old = deduped[existingIndex]
				local swNew = slopeSavePayloadWeight(entry)
				local swOld = slopeSavePayloadWeight(old)
				if swNew >= 0 and swOld >= 0 then
					if swNew > swOld then
						deduped[existingIndex] = entry
					elseif swNew == swOld and getStoredEntryScore(entry) > getStoredEntryScore(old) then
						deduped[existingIndex] = entry
					end
				elseif getStoredEntryScore(entry) > getStoredEntryScore(old) then
					deduped[existingIndex] = entry
				end
			else
				indexByUUID[uuid] = #deduped + 1
				table.insert(deduped, entry)
			end
		else
			table.insert(deduped, entry)
		end
	end

	return deduped
end

local UNRESOLVED_RESTORE_ENTRIES = {}
_G.BuildingRestoreUnresolvedEntries = {}
_G.BuildingRestoreUnresolvedCount = 0
ServerScriptService:SetAttribute("BuildingRestoreUnresolvedCount", 0)

local function resetUnresolvedRestoreEntries()
	table.clear(UNRESOLVED_RESTORE_ENTRIES)
	_G.BuildingRestoreUnresolvedEntries = {}
	_G.BuildingRestoreUnresolvedCount = 0
	ServerScriptService:SetAttribute("BuildingRestoreUnresolvedCount", 0)
end

local function shouldPreserveUnresolvedReason(reason)
	reason = tostring(reason or "")
	return reason == "item_unresolved"
		or reason == "loadable_disabled"
		or reason == "resolve_failed"
		or reason == "restore_failed"
		or reason == "restore_returned_false"
end

local IGNORED_UNRESOLVED_ITEM_NAMES = {
	AssistantTempHotel = true,
	AssistantJanitorTestFood = true,
}

local function shouldIgnoreUnresolvedStoredItem(stored, reason)
	if tostring(reason or "") ~= "item_unresolved" then
		return false
	end
	if type(stored) ~= "table" then
		return false
	end
	local itemName = tostring(stored.Item or "")
	return IGNORED_UNRESOLVED_ITEM_NAMES[itemName] == true
end

local function registerUnresolvedStoredItem(stored, reason)
	if shouldIgnoreUnresolvedStoredItem(stored, reason) then
		return
	end

	local preserved = deepCopy(stored)
	preserved.__RestoreReason = tostring(reason)
	table.insert(UNRESOLVED_RESTORE_ENTRIES, preserved)

	local unresolvedEntries = _G.BuildingRestoreUnresolvedEntries or {}
	local summary = {
		Item = preserved and preserved.Item,
		ID = preserved and preserved.ID,
		UUID = preserved and preserved.UUID,
		Reason = tostring(reason),
	}
	table.insert(unresolvedEntries, summary)
	_G.BuildingRestoreUnresolvedEntries = unresolvedEntries
	_G.BuildingRestoreUnresolvedCount = #unresolvedEntries
	Events:SetAttribute("BuildingRestoreUnresolvedCount", #unresolvedEntries)
	ServerScriptService:SetAttribute("BuildingRestoreUnresolvedCount", #unresolvedEntries)

	local previewStart = math.max(1, #unresolvedEntries - 4)
	local previewParts = {}
	for i = previewStart, #unresolvedEntries do
		local entry = unresolvedEntries[i]
		table.insert(previewParts, string.format("%s | %s | %s", tostring(entry.Item or "?"), tostring(entry.ID or "?"), tostring(entry.Reason or "?")))
	end
	local previewText = table.concat(previewParts, "\n")
	Events:SetAttribute("BuildingRestoreUnresolvedPreview", previewText)
	ServerScriptService:SetAttribute("BuildingRestoreUnresolvedPreview", previewText)
	warn(string.format("[BuildingStore] Unresolved restore item: item=%s id=%s reason=%s uuid=%s", tostring(summary.Item), tostring(summary.ID), tostring(summary.Reason), tostring(summary.UUID)))

end

local function appendUnresolvedRestoreEntries(objectsData)
	if #UNRESOLVED_RESTORE_ENTRIES == 0 then
		return
	end

	for _, stored in ipairs(UNRESOLVED_RESTORE_ENTRIES) do
		local reason = type(stored) == "table" and stored.__RestoreReason or nil
		if shouldPreserveUnresolvedReason(reason) then
			local preserved = deepCopy(stored)
			preserved.__RestoreReason = nil
			table.insert(objectsData, preserved)
		end
	end
end

local function looksLikeStoredSlope(stored)
	if type(stored) ~= "table" then
		return false
	end
	return stored.Type == "Slope"
		or stored.PathJson ~= nil
		or stored.PointsJson ~= nil
		or stored.RawPoints ~= nil
		or stored.Points ~= nil
		or stored.ControlPointsJson ~= nil
		or stored.ControlPoints ~= nil
		or stored.WidthDataJson ~= nil
		or stored.WidthData ~= nil
		or stored.Difficulty ~= nil
end

local function getCanonicalSlopeItemName(stored)
	if not looksLikeStoredSlope(stored) then
		return nil
	end
	if stored.Item == "Queue Path" or stored.Item == "Concrete Path" then
		return stored.Item
	end

	local difficulty = tostring(stored.Difficulty or "")
	local slopeNames = {
		["Green"] = "Green Slope",
		["Blue"] = "Blue Slope",
		["Black"] = "Black Slope",
		["Double Black"] = "Double Black Slope",
		["DoubleBlack"] = "Double Black Slope",
		["Triple Black"] = "Triple Black Slope",
		["TripleBlack"] = "Triple Black Slope",
		["Glade"] = "Glade",
	}
	return slopeNames[difficulty]
end

local SPECIAL_BUILDING_TYPE_FALLBACKS = {
	TicketOffice = true,
	SnowcatGarage = true,
	MedCenter = true,
	PatrolHut = true,
}

local function resolveSpecialBuildingByType(rawType)
	if type(rawType) ~= "string" or SPECIAL_BUILDING_TYPE_FALLBACKS[rawType] ~= true then
		return nil, nil
	end

	local bestName = nil
	local bestConfig = nil
	local bestId = math.huge
	for itemName, itemCfg in pairs(Config.Items) do
		if type(itemCfg) == "table" and itemCfg.Type == rawType then
			local cfgId = tonumber(itemCfg.ID) or math.huge
			if itemCfg.Category == "Buildings" and cfgId <= bestId then
				bestId = cfgId
				bestName = itemName
				bestConfig = itemCfg
			end
		end
	end

	return bestName, bestConfig
end

local function normalizeStoredItem(stored)
	local resolvedName, itemConfig, resolveMode = Config.ResolveItem(stored and stored.Item, stored and stored.ID)
	if not itemConfig then
		local fallbackNameByType, fallbackConfigByType = resolveSpecialBuildingByType(stored and stored.Type)
		if fallbackConfigByType then
			resolvedName, itemConfig, resolveMode = fallbackNameByType, fallbackConfigByType, "type_fallback"
		end
	end
	if not itemConfig then
		local fallbackSlopeName = getCanonicalSlopeItemName(stored)
		if fallbackSlopeName then
			resolvedName, itemConfig, resolveMode = Config.ResolveItem(fallbackSlopeName, nil)
		end
		if not itemConfig and looksLikeStoredSlope(stored) then
			local normalizedSlope = deepCopy(stored)
			normalizedSlope.Type = "Slope"
			normalizedSlope.Item = fallbackSlopeName or tostring(stored.Item or "Green Slope")
			if type(stored.Item) == "string" and string.find(stored.Item, "Slope_", 1, true) == 1 then
				return normalizedSlope, nil, "runtime_slope_name"
			end
			return normalizedSlope, nil, "slope_payload_fallback"
		end
		if not itemConfig then
			return nil, nil, "item_unresolved"
		end
	end
	if itemConfig.Loadable == false then
		return nil, nil, "loadable_disabled"
	end

	local normalized = deepCopy(stored)
	normalized.Item = resolvedName
	normalized.Type = itemConfig.Type
	local saveId = Config.GetSaveId(resolvedName, itemConfig)
	if saveId then
		normalized.ID = saveId
	elseif itemConfig.ID then
		normalized.ID = tostring(itemConfig.ID)
	end

	return normalized, itemConfig, resolveMode
end

local function getStaticRestoreClusterKey(stored)
	if type(stored) ~= "table" then
		return nil
	end

	local itemType = stored.Type
	if itemType == nil or itemType == CustomBuildingConfig.TYPE_NAME or itemType == "Slope" or itemType == "TwoPoint" or itemType == "Carpet" then
		return nil
	end

	local packedCf = stored.CF
	if type(packedCf) ~= "table" or #packedCf < 12 then
		return nil
	end

	local components = table.create(12)
	for i = 1, 12 do
		local value = tonumber(packedCf[i])
		if not value then
			return nil
		end
		components[i] = string.format("%.3f", value)
	end

	return table.concat({ tostring(stored.Item or "?"), tostring(itemType), table.unpack(components) }, "|")
end

local HAS_LOADED = false
local CAN_PERSIST = false
local ACTIVE_BUILDING_KEY = nil
local pendingRequestedSave = false
_G.BuildingStoreRestoreReady = false
_G.BuildingRestoreItemCount = 0
_G.BuildingRestoreInProgress = false

local function markBuildingRestoreReady()
	if _G.BuildingStoreRestoreReady then return end
	_G.BuildingStoreRestoreReady = true
	if BuildingRestoreReady then
		BuildingRestoreReady:Fire()
	end
end

local function updateRestoreDebug(stage, index, total, stored)
	local itemName = stored and tostring(stored.Item or stored.ID or stored.Type or "?") or "?"
	local uuid = stored and tostring(stored.UUID or "?") or "?"
	script:SetAttribute("RestoreStage", tostring(stage or "Unknown"))
	script:SetAttribute("RestoreIndex", tonumber(index) or 0)
	script:SetAttribute("RestoreTotal", tonumber(total) or 0)
	script:SetAttribute("RestoreItem", itemName)
	script:SetAttribute("RestoreUUID", uuid)
	if stage ~= "Buildings" or index == 1 or index == total or (index % 25) == 0 then
		warn(string.format("[BuildingStore] Restore progress stage=%s index=%d/%d item=%s uuid=%s", tostring(stage), tonumber(index) or 0, tonumber(total) or 0, itemName, uuid))
	end
end

-- ============================================================
-- CLEAR TREES AROUND A MODEL (server-side TreeFolder)
-- ============================================================
local function ensureTreeFolderQueryable(treeFolder)
	if not treeFolder then return end
	for _, desc in ipairs(treeFolder:GetDescendants()) do
		if desc:IsA("BasePart") and desc.CanQuery == false then
			desc.CanQuery = true
		end
	end
end

local function clearTreesAroundModel(model, padding)
	local treeFolder = workspace:FindFirstChild("TreeFolder")
	if not treeFolder then return 0 end
	ensureTreeFolderQueryable(treeFolder)

	padding = padding or Vector3.new(6, 40, 6)
	local cleared = 0

	local ok, cf, size = pcall(function()
		return model:GetBoundingBox()
	end)
	if not ok or not cf then return 0 end

	if size.X > 200 or size.Z > 200 then
		size = Vector3.new(math.min(size.X, 200), size.Y, math.min(size.Z, 200))
	end

	local overlapParams = OverlapParams.new()
	overlapParams.FilterType = Enum.RaycastFilterType.Include
	overlapParams.FilterDescendantsInstances = {treeFolder}

	local parts = workspace:GetPartBoundsInBox(cf, size + padding, overlapParams)
	local checked = {}

	for _, part in ipairs(parts) do
		local current = part
		while current and current.Parent and current.Parent ~= treeFolder do
			current = current.Parent
		end
		if current and current.Parent == treeFolder and not checked[current] then
			checked[current] = true
			local treePos = current:IsA("Model") and current:GetPivot().Position or current.Position
			if TrackDeletedTree then
				TrackDeletedTree:Fire(nil, treePos.X, treePos.Z)
			end
			current:Destroy()
			cleared += 1
		end
	end

	return cleared
end

local function clearTreesAlongPath(startPos, endPos, width)
	local treeFolder = workspace:FindFirstChild("TreeFolder")
	if not treeFolder then return 0 end
	ensureTreeFolderQueryable(treeFolder)

	width = width or 20
	local cleared = 0
	local dist = (endPos - startPos).Magnitude
	local dir = dist > 1 and (endPos - startPos).Unit or Vector3.zAxis
	local steps = math.ceil(dist / 40)

	for s = 0, steps do
		local t = steps > 0 and (s / steps) or 0
		local pos = startPos:Lerp(endPos, t)

		local overlapParams = OverlapParams.new()
		overlapParams.FilterType = Enum.RaycastFilterType.Include
		overlapParams.FilterDescendantsInstances = {treeFolder}

		local cframe = CFrame.lookAt(pos, pos + dir)
		local parts = workspace:GetPartBoundsInBox(cframe, Vector3.new(width, 50, 40), overlapParams)

		local checked = {}
		for _, part in ipairs(parts) do
			local current = part
			while current and current.Parent and current.Parent ~= treeFolder do
				current = current.Parent
			end
			if current and current.Parent == treeFolder and not checked[current] then
				checked[current] = true
				local treePos = current:IsA("Model") and current:GetPivot().Position or current.Position
				if TrackDeletedTree then
					TrackDeletedTree:Fire(nil, treePos.X, treePos.Z)
				end
				current:Destroy()
				cleared += 1
			end
		end
	end

	return cleared
end

-- ============================================================
-- FINAL TREE CLEARING PASS
-- ============================================================
local function clearTreesFromMoveSnapshot(model)
	if not model then return 0 end

	local rawJson = model:GetAttribute("TreeMoveSnapshot")
	if type(rawJson) ~= "string" or rawJson == "" then return 0 end

	local ok, movedTrees = pcall(function()
		return HttpService:JSONDecode(rawJson)
	end)
	if not ok or type(movedTrees) ~= "table" then return 0 end

	local treeFolder = workspace:FindFirstChild("TreeFolder")
	if not treeFolder then return 0 end
	ensureTreeFolderQueryable(treeFolder)

	local overlapParams = OverlapParams.new()
	overlapParams.FilterType = Enum.RaycastFilterType.Include
	overlapParams.FilterDescendantsInstances = {treeFolder}

	local cleared = 0
	local checked = {}
	for index, info in ipairs(movedTrees) do
		local cfComponents = type(info) == "table" and info.CF or nil
		if type(cfComponents) == "table" and #cfComponents >= 3 then
			local x = sanitizeRestoreNumber(cfComponents[1], MAX_RESTORE_COMPONENT_MAGNITUDE)
			local y = sanitizeRestoreNumber(cfComponents[2], MAX_RESTORE_COMPONENT_MAGNITUDE)
			local z = sanitizeRestoreNumber(cfComponents[3], MAX_RESTORE_COMPONENT_MAGNITUDE)
			if x and y and z then
				local targetPos = Vector3.new(x, y, z)
				local parts = workspace:GetPartBoundsInBox(CFrame.new(targetPos), Vector3.new(10, 140, 10), overlapParams)
				for _, part in ipairs(parts) do
					local current = part
					while current and current.Parent and current.Parent ~= treeFolder do
						current = current.Parent
					end
					if current and current.Parent == treeFolder and not checked[current] then
						local treePos = current:IsA("Model") and current:GetPivot().Position or current.Position
						local planarDelta = Vector2.new(treePos.X - targetPos.X, treePos.Z - targetPos.Z)
						if planarDelta.Magnitude <= 8 then
							checked[current] = true
							if TrackDeletedTree then
								TrackDeletedTree:Fire(nil, treePos.X, treePos.Z)
							end
							current:Destroy()
							cleared += 1
						end
					end
				end
			end
		end
		if index % TREE_SWEEP_YIELD_INTERVAL == 0 then
			task.wait()
		end
	end

	return cleared
end

local function finalTreeClearPass()
	local treeFolder = workspace:FindFirstChild("TreeFolder")
	if not treeFolder then return 0, false end

	local placedFolder = workspace:FindFirstChild("PlacedObjects")
	if not placedFolder then return 0, false end

	local totalCleared = 0
	local startedAt = tick()
	local timedOut = false

	for _, model in ipairs(placedFolder:GetChildren()) do
		if (tick() - startedAt) > MAX_RESTORE_TREE_SWEEP_SECONDS then
			timedOut = true
			break
		end

		local itemType = model:GetAttribute("Type")
		totalCleared += clearTreesFromMoveSnapshot(model)

		if itemType == "Slope" then
			local rawJson = model:GetAttribute("RawPoints")
			if rawJson then
				local ok, pathPoints = pcall(function() return HttpService:JSONDecode(rawJson) end)
				if ok and type(pathPoints) == "table" and #pathPoints >= 2 then
					local step = math.max(1, math.floor(#pathPoints / 30))
					local processedSegments = 0
					for i = 1, #pathPoints - step, step do
						if (tick() - startedAt) > MAX_RESTORE_TREE_SWEEP_SECONDS then
							timedOut = true
							break
						end

						local pt1 = pathPoints[i]
						local pt2 = pathPoints[math.min(i + step, #pathPoints)]
						if type(pt1) == "table" and type(pt2) == "table" then
							local x1 = sanitizeRestoreNumber(pt1[1], MAX_RESTORE_COMPONENT_MAGNITUDE)
							local y1 = sanitizeRestoreNumber(pt1[2], MAX_RESTORE_COMPONENT_MAGNITUDE)
							local z1 = sanitizeRestoreNumber(pt1[3], MAX_RESTORE_COMPONENT_MAGNITUDE)
							local x2 = sanitizeRestoreNumber(pt2[1], MAX_RESTORE_COMPONENT_MAGNITUDE)
							local y2 = sanitizeRestoreNumber(pt2[2], MAX_RESTORE_COMPONENT_MAGNITUDE)
							local z2 = sanitizeRestoreNumber(pt2[3], MAX_RESTORE_COMPONENT_MAGNITUDE)
							if x1 and y1 and z1 and x2 and y2 and z2 then
								local p1 = Vector3.new(x1, y1, z1)
								local p2 = Vector3.new(x2, y2, z2)
								local dir = (p2 - p1)
								local dist = dir.Magnitude
								if dist >= 1 then
									local mid = (p1 + p2) / 2
									dir = dir.Unit

									local overlapParams = OverlapParams.new()
									overlapParams.FilterType = Enum.RaycastFilterType.Include
									overlapParams.FilterDescendantsInstances = {treeFolder}

									local cframe = CFrame.lookAt(mid, mid + dir)
									local parts = workspace:GetPartBoundsInBox(cframe, Vector3.new(100, 30, math.clamp(dist + 5, 5, 220)), overlapParams)

									local checked = {}
									for _, part in ipairs(parts) do
										local current = part
										while current and current.Parent and current.Parent ~= treeFolder do
											current = current.Parent
										end
										if current and current.Parent == treeFolder and not checked[current] then
											checked[current] = true
											local treePos = current:IsA("Model") and current:GetPivot().Position or current.Position
											if TrackDeletedTree then
												TrackDeletedTree:Fire(nil, treePos.X, treePos.Z)
											end
											current:Destroy()
											totalCleared += 1
										end
									end
								end
							end
						end

						processedSegments += 1
						if processedSegments % TREE_SWEEP_YIELD_INTERVAL == 0 then
							task.wait()
						end
					end
				end
			end

		elseif itemType == "TwoPoint" or itemType == "Carpet" then
			local startStation = model:FindFirstChild("StartStation")
			local endStation = model:FindFirstChild("EndStation")
			if startStation then totalCleared += clearTreesAroundModel(startStation) end
			if endStation then totalCleared += clearTreesAroundModel(endStation) end

			if startStation and endStation then
				local p1 = startStation:GetPivot().Position
				local p2 = endStation:GetPivot().Position
				totalCleared += clearTreesAlongPath(p1, p2, 20)
			end

			if itemType == "TwoPoint" then
				for _, child in ipairs(model:GetChildren()) do
					if child.Name:match("Pole") then
						totalCleared += clearTreesAroundModel(child, Vector3.new(4, 40, 4))
					end
				end
			end
		else
			totalCleared += clearTreesAroundModel(model)
		end

		task.wait()
	end

	if timedOut then
		warn(string.format("[BuildingStore] Final tree clear pass timed out after %.1fs; continuing restore to avoid server freeze.", MAX_RESTORE_TREE_SWEEP_SECONDS))
	end

	return totalCleared, timedOut
end

-- ============================================================
-- RESTORE A SINGLE SLOPE → SlopeManager
-- ============================================================
local function decodeStoredSlopePoints(rawPoints)
	if rawPoints == nil then
		return nil
	end

	local decoded = rawPoints
	if type(rawPoints) == "string" then
		if rawPoints == "" then
			return nil
		end
		local ok, parsed = pcall(function()
			return HttpService:JSONDecode(rawPoints)
		end)
		if not ok or type(parsed) ~= "table" then
			return nil
		end
		decoded = parsed
	end

	if type(decoded) == "table" then
		if type(decoded.Points) == "table" then
			decoded = decoded.Points
		elseif type(decoded.points) == "table" then
			decoded = decoded.points
		elseif type(decoded.Path) == "table" then
			decoded = decoded.Path
		elseif type(decoded.path) == "table" then
			decoded = decoded.path
		end
	end

	if type(decoded) ~= "table" then
		return nil
	end

	local points = {}
	for _, p in ipairs(decoded) do
		if typeof(p) == "Vector3" then
			table.insert(points, p)
		elseif type(p) == "table" then
			local x = tonumber(p[1] or p.X or p.x)
			local y = tonumber(p[2] or p.Y or p.y)
			local z = tonumber(p[3] or p.Z or p.z)
			if type(x) == "number" and type(y) == "number" and type(z) == "number" then
				table.insert(points, Vector3.new(x, y, z))
			end
		end
	end

	if #points < 2 then
		return nil
	end

	return points
end

local function resolveStoredSlopePath(stored)
	local sources = {
		{ key = "PathJson", presmoothed = true },
		{ key = "PointsJson", presmoothed = true },
		{ key = "Points", presmoothed = true },
		{ key = "RawPoints", presmoothed = true },
		{ key = "ControlPointsJson", presmoothed = false },
		{ key = "ControlPoints", presmoothed = false },
	}

	for _, source in ipairs(sources) do
		local points = decodeStoredSlopePoints(stored[source.key])
		if points and #points >= 2 then
			return points, source.presmoothed, source.key
		end
	end

	return nil, false, nil
end

local function restoreSlope(stored)
	local waitStart = tick()
	while not _G.PlaceSlope do
		if tick() - waitStart > 20 then
			return false
		end
		task.wait(0.5)

	end

	local points, presmoothed, pointSource = resolveStoredSlopePath(stored)
	if not points or #points < 2 then
		return false
	end

	local slopeData = {
		Points = points,
		pathPoints = points,
		Difficulty = stored.Difficulty or "Green",
		Type = "Slope",
		ItemName = stored.Item,
		CustomName = stored.CustomName,
		UUID = stored.UUID or HttpService:GenerateGUID(false),
		Presmoothed = presmoothed,
		IsRestoring = true,
		Price = stored.Price,
		PlacementTime = stored.PlacementTime,
	}

	local widthJson = stored.WidthDataJson or stored.WidthData
	if type(widthJson) == "string" and widthJson ~= "" then
		local ok, decoded = pcall(function() return HttpService:JSONDecode(widthJson) end)
		if ok and type(decoded) == "table" then
			slopeData.WidthData = decoded
		end
	elseif type(widthJson) == "table" then
		slopeData.WidthData = widthJson
	end

	local decorOptions = {}
	if stored.UseNets ~= nil then
		decorOptions.nets = stored.UseNets == true
	end
	if stored.NetsEnabled ~= nil then
		decorOptions.nets = stored.NetsEnabled == true
	end
	if stored.MarkersEnabled ~= nil then
		decorOptions.markers = stored.MarkersEnabled == true
	end
	if stored.UseMarkers ~= nil then
		decorOptions.markers = stored.UseMarkers == true
	end
	if stored.MarkerLightsEnabled ~= nil then
		decorOptions.markerLights = stored.MarkerLightsEnabled == true
	end
	if stored.MarkerLights ~= nil then
		decorOptions.markerLights = stored.MarkerLights == true
	end
	if next(decorOptions) ~= nil then
		slopeData.DecorOptions = decorOptions
	end

	local activeUserId = select(1, syncCachedSlotIdentity())
	if not activeUserId then
		warn("[BuildingStore] Skipping slope restore because active slot owner is unresolved")
		return false
	end
	local success = _G.PlaceSlope(activeUserId, slopeData)
	if not success then
	end
	return success
end

-- ============================================================
-- SAVE LOGIC
-- ============================================================
local function shouldSaveSessionForPlayer(player)
	if not player then
		return true
	end
	if USER_ID <= 0 then
		return true
	end
	return player.UserId == USER_ID
end

local function saveData(force)
	if SAVE_IN_FLIGHT then
		return false
	end
	if not HAS_LOADED then
		return false
	end
	if not force and not _buildingsDirty then
		return false  -- nothing changed since last save
	end
	if not CAN_PERSIST then
		warn("[BuildingStore] Save skipped because persistence is locked after failed datastore reads.")
		return false
	end
	if _G.BuildingRestoreInProgress == true then
		return false
	end

	local now = os.clock()
	local cooldown = force and FORCED_SAVE_COOLDOWN_SECONDS or SESSION_SAVE_COOLDOWN_SECONDS
	if cooldown > 0 and (now - LAST_SESSION_SAVE_AT) < cooldown then
		return false
	end

	local activeUserId, activeSlotNum = syncCachedSlotIdentity()
	if not activeUserId or not activeSlotNum then
		warn("[BuildingStore] Skipping save because active slot identity is unresolved")
		return false
	end

	local key = ACTIVE_BUILDING_KEY or getKey(activeUserId, activeSlotNum)
	if not key then
		return false
	end
	ACTIVE_BUILDING_KEY = key

	local objectsData = {}
	local serializedCount = 0
	local sessionCreatedTime = getSessionCreatedTime()
	if sessionCreatedTime > 0 then
		objectsData.CreatedTime = sessionCreatedTime
	end
	local placedFolder = workspace:FindFirstChild("PlacedObjects")

	if placedFolder then
		for _, model in ipairs(placedFolder:GetChildren()) do
			local owner = model:GetAttribute("Owner")
			local ownerNum = tonumber(owner)
			if owner == nil or owner == "" or ownerNum == nil or ownerNum == activeUserId then
				local itemType = model:GetAttribute("Type")
				local modelId = model:GetAttribute("ID")
				local resolvedName, itemConfig = nil, nil
				if modelId then
					resolvedName, itemConfig = Config.GetItemById(modelId)
				end
				if not itemConfig then
					local defaultName = model:GetAttribute("DefaultPlacedName") or model.Name
					itemConfig = Config.Items[defaultName]
					resolvedName = defaultName
				end
				if not itemConfig then
					local fallbackNameByType, fallbackConfigByType = resolveSpecialBuildingByType(itemType)
					if fallbackConfigByType then
						resolvedName = fallbackNameByType
						itemConfig = fallbackConfigByType
					end
				end
				if itemConfig and type(resolvedName) == "string" and resolvedName ~= "" then
					if model:GetAttribute("DefaultPlacedName") == nil then
						model:SetAttribute("DefaultPlacedName", resolvedName)
					end
				end
				local isStructuredPersistentType = itemType == CustomBuildingConfig.TYPE_NAME or itemType == "Slope" or itemType == "TwoPoint" or itemType == "Carpet"
				if model:GetAttribute("IsPlacementGhost") == true or model:GetAttribute("GeneratedSlopeNet") == true or itemType == "SlopeNet" then
					continue
				end
				if not itemConfig and not isStructuredPersistentType then
					if ownerNum == nil or ownerNum ~= activeUserId then
						continue
					end
				end
				local data = {
					Item = resolvedName or model.Name,
					Type = itemType,
					UUID = model:GetAttribute("UUID") or HttpService:GenerateGUID(false)
				}
				local paid = model:GetAttribute("PaidPrice")
				if not paid then paid = model:GetAttribute("Price") end
				if paid then data.Price = paid end
				local ptime = model:GetAttribute("PlacementTime")
				if ptime then data.PlacementTime = ptime end
				local saveId = itemConfig and Config.GetSaveId(resolvedName, itemConfig) or nil
				if saveId then
					data.ID = tostring(saveId)
				elseif modelId then
					data.ID = tostring(modelId)
				end

				local customName = model:GetAttribute("CustomName")
				if type(customName) == "string" and customName ~= "" then
					data.CustomName = customName
				end

				if itemType == CustomBuildingConfig.TYPE_NAME then
					local state = CustomBuildingConfig.ReadState(model)
					data.CF = packCFrame(model:GetPivot())
					data.Size = packVector3(state.Size)
					data.Color = packColor3(state.Color)
					data.Material = state.Material
					data.Shape = state.Shape
				elseif itemType == "Slope" then
					local pathJson = model:GetAttribute("RawPoints")
					local controlJson = model:GetAttribute("ControlPoints")
					local widthJson = model:GetAttribute("WidthData")
					local runtimeSlopeData = nil
					if (type(pathJson) ~= "string" or pathJson == "") or (type(widthJson) ~= "string" or widthJson == "") then
						local slopeGetter = _G.GetSlopeData
						if type(slopeGetter) == "function" then
							local ok, runtimeData = pcall(slopeGetter, model)
							if ok and type(runtimeData) == "table" then
								runtimeSlopeData = runtimeData
							end
						end
					end
					if (type(pathJson) ~= "string" or pathJson == "") and runtimeSlopeData and type(runtimeSlopeData.Path) == "table" and #runtimeSlopeData.Path >= 2 then
						local serializedPath = {}
						for _, point in ipairs(runtimeSlopeData.Path) do
							table.insert(serializedPath, packVector3(point))
						end
						pathJson = HttpService:JSONEncode(serializedPath)
						model:SetAttribute("RawPoints", pathJson)
					end
					if (type(widthJson) ~= "string" or widthJson == "") and runtimeSlopeData and type(runtimeSlopeData.WidthData) == "table" and #runtimeSlopeData.WidthData > 0 then
						local serializedWidthData = {}
						for _, wd in ipairs(runtimeSlopeData.WidthData) do
							table.insert(serializedWidthData, { wd.index, wd.width })
						end
						widthJson = HttpService:JSONEncode(serializedWidthData)
						model:SetAttribute("WidthData", widthJson)
					end
					data.PathJson = pathJson
					data.ControlPointsJson = controlJson
					data.PointsJson = pathJson or controlJson
					local difficulty = model:GetAttribute("Difficulty") or (runtimeSlopeData and runtimeSlopeData.Difficulty)
					if model:GetAttribute("IsPath") == true then
						data.Item = "Concrete Path"
					elseif model:GetAttribute("IsQueue") == true then
						data.Item = "Queue Path"
					else
						local slopeNames = {
							["Green"] = "Green Slope",
							["Blue"] = "Blue Slope",
							["Black"] = "Black Slope",
							["Double Black"] = "Double Black Slope",
							["Triple Black"] = "Triple Black Slope",
							["Glade"] = "Glade",
						}
						data.Item = slopeNames[tostring(difficulty or "")] or data.Item
					end
					local slopeResolvedName, slopeResolvedConfig = Config.ResolveItem(data.Item, data.ID)
					local slopeSaveId = slopeResolvedConfig and Config.GetSaveId(slopeResolvedName, slopeResolvedConfig) or nil
					if slopeSaveId then
						data.ID = tostring(slopeSaveId)
					end
					local netsEnabled = model:GetAttribute("NetsEnabled")
					if netsEnabled == nil then
						netsEnabled = model:GetAttribute("UseNets")
					end
					data.UseNets = netsEnabled
					data.NetsEnabled = netsEnabled
					data.MarkersEnabled = model:GetAttribute("MarkersEnabled")
					data.MarkerLightsEnabled = model:GetAttribute("MarkerLightsEnabled")
					data.WidthDataJson = widthJson
					data.Difficulty = difficulty
					data.CustomName = model:GetAttribute("CustomName")

				elseif itemType == "TwoPoint" or itemType == "Carpet" then
					local s = model:FindFirstChild("StartStation")
					local e = model:FindFirstChild("EndStation")
					if s and e then
						data.StartCF = packCFrame(s:GetPivot())
						data.EndCF = packCFrame(e:GetPivot())
					else
						data.Start = packVector3(model:GetAttribute("P1") or Vector3.zero)
						data.End = packVector3(model:GetAttribute("P2") or Vector3.zero)
					end

					if itemType == "TwoPoint" then
						local poles = {}
						for _, child in ipairs(model:GetChildren()) do
							if child.Name:match("Pole_%d+") then
								table.insert(poles, {Name = child.Name, CF = packCFrame(child:GetPivot())})
							end
						end
						if #poles > 0 then
							data.Poles = poles
						end
					end
				else
					data.CF = packCFrame(model:GetPivot())
					local savedHeightOffset = tonumber(model:GetAttribute("PlacementHeightOffset")) or 0
					if math.abs(savedHeightOffset) > 0.01 then
						data.HeightOffset = savedHeightOffset
					end
					local savedCleanliness = tonumber(model:GetAttribute("Cleanliness"))
					if savedCleanliness ~= nil then
						data.Cleanliness = math.clamp(savedCleanliness, 0, 100)
					end
					local savedDirtiness = tonumber(model:GetAttribute("Dirtiness"))
					if savedDirtiness ~= nil then
						data.Dirtiness = math.clamp(savedDirtiness, 0, 100)
					end
					if model:GetAttribute("NeedsCleaning") ~= nil then
						data.NeedsCleaning = model:GetAttribute("NeedsCleaning") == true
					end
					if model:GetAttribute("HasJanitor") ~= nil then
						data.HasJanitor = model:GetAttribute("HasJanitor") == true
					end
					local savedJanitorLevel = tonumber(model:GetAttribute("JanitorLevel"))
					if savedJanitorLevel ~= nil then
						data.JanitorLevel = math.max(0, savedJanitorLevel)
					end
					if model:GetAttribute("JanitorCoverage") ~= nil then
						data.JanitorCoverage = model:GetAttribute("JanitorCoverage") == true
					end
					local savedCleanAreaTraffic = tonumber(model:GetAttribute("CleanAreaTraffic"))
					if savedCleanAreaTraffic ~= nil then
						data.CleanAreaTraffic = math.max(0, savedCleanAreaTraffic)
					end
				end

				copyRestoreSnapshotsToData(model, data)
				table.insert(objectsData, data)
				serializedCount += 1
				if (serializedCount % 20) == 0 then
					task.wait()
				end
			end
		end
	end

	appendUnresolvedRestoreEntries(objectsData)
	objectsData = dedupeStoredObjectsByUUID(objectsData)
	SAVE_IN_FLIGHT = true

	local MAX_RETRIES = 5
	local BASE_DELAY = 1.5
	local success = false
	local err = nil
	
	for attempt = 1, MAX_RETRIES do
		success, err = pcall(function()
			STORE:UpdateAsync(key, function(oldData)
				return objectsData
			end)
		end)
		
		if success then
			break
		else
			warn("[BuildingStore] Save failed (Attempt " .. attempt .. "/" .. MAX_RETRIES .. "): " .. tostring(err))
			if attempt < MAX_RETRIES then
				task.wait(BASE_DELAY + math.random() * 2)
				BASE_DELAY = BASE_DELAY * 2
			end
		end
	end

	if not success then
		SAVE_IN_FLIGHT = false
		return false
	end

	saveBackupSnapshot(key, objectsData)
	LAST_SESSION_SAVE_AT = os.clock()
	_buildingsDirty = false  -- reset after successful save
	SAVE_IN_FLIGHT = false
	return true
end

local function countBuildingPayloadEntries(tbl)
	if type(tbl) ~= "table" then
		return 0
	end
	local maxIndex = 0
	for k, v in pairs(tbl) do
		if type(k) == "number" and k == math.floor(k) and k >= 1 and type(v) == "table" then
			if k > maxIndex then
				maxIndex = k
			end
		end
	end
	if maxIndex > 0 then
		return maxIndex
	end
	return #tbl
end

-- ============================================================
-- LOAD LOGIC
-- ============================================================
local function loadData()
	resetUnresolvedRestoreEntries()

	local activeUserId, activeSlotNum = syncCachedSlotIdentity()
	if isFreshSaveSession() and getSessionCreatedTime() > 0 and activeUserId and activeSlotNum then
		wipeLegacyBuildingKeysNoCT(activeUserId, activeSlotNum)
	end
	local candidateKeys = getLoadKeys(activeUserId, activeSlotNum)
	local key = candidateKeys[1]
	if not key then
		warn("[BuildingStore] No active slot identity; skipping building restore")
		CAN_PERSIST = false
		_G.BuildingRestoreItemCount = 0
		markBuildingRestoreReady()
		return
	end

	local hasGameData = sessionHasExistingGameData(activeUserId, activeSlotNum)
	if hasGameData == false then
		wipeStaleBuildingData(activeUserId, activeSlotNum)
		HAS_LOADED = true
		CAN_PERSIST = true
		ACTIVE_BUILDING_KEY = key
		_G.BuildingRestoreItemCount = 0
		_G.BuildingRestoreInProgress = false
		warn("[BuildingStore] Skipping building restore because no matching game data exists for this slot. Cleared orphaned building entries.")
		markBuildingRestoreReady()
		return
	end

	local expectedCreatedTime = getSessionCreatedTime()
	local freshSaveSession = isFreshSaveSession()

	local function payloadPassesCreatedTimeRules(result)
		if type(result) ~= "table" then
			return false
		end
		local savedCreatedTime = tonumber(result.CreatedTime) or 0
		if expectedCreatedTime > 0 and savedCreatedTime > 0 and savedCreatedTime ~= expectedCreatedTime then
			return false
		end
		return true
	end

	local function payloadPassesFreshSaveRules(result, candidateKey)
		if type(result) ~= "table" then
			return false
		end
		local savedCreatedTime = tonumber(result.CreatedTime) or 0
		if not (#result > 0 and freshSaveSession and (savedCreatedTime == 0 or expectedCreatedTime == 0 or savedCreatedTime ~= expectedCreatedTime)) then
			return true
		end
		if hasGameData == false then
			return false
		end
		if hasGameData == true then
			warn(string.format(
				"[BuildingStore] FreshSave heuristics matched for %s, but game data exists for this slot — keeping candidate during multi-key selection.",
				tostring(candidateKey)
			))
		end
		return true
	end

	local data = nil
	local resolvedKey = nil
	local hadLookupError = false
	local bestScore = -1
	local loadedTables = 0

	for _, candidateKey in ipairs(candidateKeys) do
		local ok, result, err = loadStoreWithRetries(candidateKey)
		if ok then
			if type(result) == "table" then
				loadedTables += 1
				if payloadPassesCreatedTimeRules(result) and payloadPassesFreshSaveRules(result, candidateKey) then
					local score = countBuildingPayloadEntries(result)
					if score > bestScore then
						bestScore = score
						data = result
						resolvedKey = candidateKey
					end
				else
					warn(string.format("[BuildingStore] Skipping incompatible building payload for key %s (CreatedTime/fresh-save rules).", tostring(candidateKey)))
				end
			elseif result ~= nil then
				warn("[BuildingStore] Ignoring invalid payload for key " .. tostring(candidateKey))
			end
		else
			hadLookupError = true
			warn("[BuildingStore] Load failed for key " .. tostring(candidateKey) .. ": " .. tostring(err))
		end
	end

	if loadedTables > 1 and resolvedKey and bestScore >= 0 then
		warn(string.format(
			"[BuildingStore] Chose richest compatible building payload: key=%s items=%d (evaluated %d table payloads).",
			tostring(resolvedKey),
			bestScore,
			loadedTables
		))
	end

	if not data then
		local backupData, backupKey = loadBestBackupSnapshot(candidateKeys, expectedCreatedTime)
		if type(backupData) == "table" then
			data = backupData
			resolvedKey = backupKey
			warn("[BuildingStore] Recovered building data from backup key " .. tostring(backupKey))
		end
	end

	if not data and hadLookupError then
		HAS_LOADED = true
		CAN_PERSIST = false
		ACTIVE_BUILDING_KEY = key
		_G.BuildingRestoreItemCount = 0
		warn("[BuildingStore] Blocking building saves because datastore reads failed and no safe snapshot was loaded.")
		markBuildingRestoreReady()
		return
	end

	HAS_LOADED = true
	CAN_PERSIST = true
	ACTIVE_BUILDING_KEY = resolvedKey or key

	if data and #data > 0 then
			ensurePlacementRestoreBridge()
			data = dedupeStoredObjectsByUUID(data)
			_G.BuildingRestoreItemCount = #data
			_G.BuildingRestoreInProgress = true
			local restoreWatchdogToken = HttpService:GenerateGUID(false)
			script:SetAttribute("RestoreWatchdogToken", restoreWatchdogToken)
			local restoreWatchdogSeconds = math.clamp(90 + math.floor((#data) * 0.4), 90, 270)
			task.delay(restoreWatchdogSeconds, function()
				if _G.BuildingRestoreInProgress and not _G.BuildingStoreRestoreReady and script:GetAttribute("RestoreWatchdogToken") == restoreWatchdogToken then
					warn("[BuildingStore] Restore watchdog fired. Forcing restore ready to prevent load freeze.")
					_G.BuildingRestoreInProgress = false
					updateRestoreDebug("WatchdogForcedReady", tonumber(script:GetAttribute("RestoreIndex")) or 0, tonumber(script:GetAttribute("RestoreTotal")) or 0, nil)
					markBuildingRestoreReady()
				end
			end)

			local buildings = {}
			local lifts = {}
			local slopes = {}

			for _, stored in ipairs(data) do
				local normalizedStored, _, unresolvedReason = normalizeStoredItem(stored)
				if not normalizedStored then
					registerUnresolvedStoredItem(stored, unresolvedReason or "resolve_failed")
					continue
				end

				if normalizedStored.Type == "Slope" then
					table.insert(slopes, normalizedStored)
				elseif normalizedStored.Type == "TwoPoint" or normalizedStored.Type == "Carpet" then
					table.insert(lifts, normalizedStored)
				else
					table.insert(buildings, normalizedStored)
				end
			end

			warn(string.format(
				"[BuildingStore] Restore candidates for %s: total=%d buildings=%d lifts=%d slopes=%d",
				tostring(ACTIVE_BUILDING_KEY or key),
				#data,
				#buildings,
				#lifts,
				#slopes
			))


			local staticRestoreClusterCounts = {}
			for _, stored in ipairs(buildings) do
				local clusterKey = getStaticRestoreClusterKey(stored)
				if clusterKey then
					staticRestoreClusterCounts[clusterKey] = (staticRestoreClusterCounts[clusterKey] or 0) + 1
				end
			end

			-- 1. BUILDINGS
			for i, stored in ipairs(buildings) do
				if script:GetAttribute("RestoreWatchdogToken") ~= restoreWatchdogToken then break end
				updateRestoreDebug("Buildings", i, #buildings, stored)
				local isCustomBuilding = stored.Type == CustomBuildingConfig.TYPE_NAME
				if not stored.CF then
					registerUnresolvedStoredItem(stored, isCustomBuilding and "missing_custom_cf" or "missing_cf")
					continue
				end

				local clusterKey = getStaticRestoreClusterKey(stored)
				if clusterKey and (staticRestoreClusterCounts[clusterKey] or 0) >= 4 then
					registerUnresolvedStoredItem(stored, "overlap_cluster")
					continue
				end

				if RealRestoreEvent then
					local restoreCF = unpackCFrameSafe(stored.CF)
					if not restoreCF then
						registerUnresolvedStoredItem(stored, "invalid_cf")
						continue
					end

					local payload = {
						UUID = stored.UUID,
						Type = stored.Type,
						Item = stored.Item,
						ID = stored.ID,
						OwnerId = activeUserId,
						Price = stored.Price,
						PlacementTime = stored.PlacementTime,
						CF = restoreCF,
						CustomName = stored.CustomName,
						Cleanliness = stored.Cleanliness,
						Dirtiness = stored.Dirtiness,
						NeedsCleaning = stored.NeedsCleaning,
						HasJanitor = stored.HasJanitor,
						JanitorLevel = stored.JanitorLevel,
						JanitorCoverage = stored.JanitorCoverage,
						CleanAreaTraffic = stored.CleanAreaTraffic,
					}
					local storedHeightOffset = tonumber(stored.HeightOffset)
					if storedHeightOffset and math.abs(storedHeightOffset) > 0.01 then
						payload.HeightOffset = math.clamp(storedHeightOffset, -1000, 1000)
					end
					if isCustomBuilding then
						if stored.Size then
							local restoredSize = unpackVector3Safe(stored.Size)
							if restoredSize then
								payload.Size = restoredSize
							end
						end
						if stored.Color then
							local restoredColor = unpackColor3Safe(stored.Color)
							if restoredColor then
								payload.Color = restoredColor
							end
						end
						payload.Material = stored.Material
						payload.Shape = stored.Shape
					end
					copyStoredSnapshotsToPayload(stored, payload)
					local ok, err = pcall(function()
						RealRestoreEvent:Fire(nil, payload)
					end)
					if not ok then
						warn(string.format("[BuildingStore] Building restore failed item=%s uuid=%s err=%s", tostring(stored.Item), tostring(stored.UUID), tostring(err)))
						registerUnresolvedStoredItem(stored, "restore_failed")
					end
				end
				if i % 2 == 0 then task.wait() end
			end

			task.wait(0.3)
			for i, stored in ipairs(lifts) do
				if script:GetAttribute("RestoreWatchdogToken") ~= restoreWatchdogToken then break end
				updateRestoreDebug("Lifts", i, #lifts, stored)
				if RealRestoreEvent then
					local payload = {
						UUID = stored.UUID,
						Type = stored.Type,
						Item = stored.Item,
						ID = stored.ID,
						OwnerId = activeUserId,
						Price = stored.Price,
						PlacementTime = stored.PlacementTime,
						CustomName = stored.CustomName,
					}
					if stored.StartCF and stored.EndCF then
						local startCF = unpackCFrameSafe(stored.StartCF)
						local endCF = unpackCFrameSafe(stored.EndCF)
						if not startCF or not endCF then
							registerUnresolvedStoredItem(stored, "invalid_lift_cframe")
							continue
						end
						payload.StartCF = startCF
						payload.EndCF = endCF
						payload.HasRotation = true
					else
						if stored.Start then
							local startPos = unpackVector3Safe(stored.Start)
							if startPos then
								payload.Start = startPos
							end
						end
						if stored.End then
							local endPos = unpackVector3Safe(stored.End)
							if endPos then
								payload.End = endPos
							end
						end
						payload.HasRotation = false
					end
					if stored.Poles then
						local unpackedPoles = {}
						for _, pData in ipairs(stored.Poles) do
							local poleCF = pData and unpackCFrameSafe(pData.CF)
							if poleCF then
								table.insert(unpackedPoles, {Name = pData.Name, CF = poleCF})
							end
						end
						payload.Poles = unpackedPoles
					end
					copyStoredSnapshotsToPayload(stored, payload)
					local ok, err = pcall(function()
						RealRestoreEvent:Fire(nil, payload)
					end)
					if not ok then
						warn(string.format("[BuildingStore] Lift restore failed item=%s uuid=%s err=%s", tostring(stored.Item), tostring(stored.UUID), tostring(err)))
						registerUnresolvedStoredItem(stored, "restore_failed")
					end
				end
				task.wait(0.5)
			end

			task.wait(0.3) 



			-- 3. SLOPES
			local restoredSlopeCount = 0
			for i, stored in ipairs(slopes) do
				if script:GetAttribute("RestoreWatchdogToken") ~= restoreWatchdogToken then break end
				updateRestoreDebug("Slopes", i, #slopes, stored)
				local ok, result = pcall(function()
					return restoreSlope(stored)
				end)
				if ok and result then
					restoredSlopeCount += 1
				elseif not ok then
					warn(string.format("[BuildingStore] Slope restore failed item=%s uuid=%s err=%s", tostring(stored.Item), tostring(stored.UUID), tostring(result)))
					registerUnresolvedStoredItem(stored, "restore_failed")
				else
					warn(string.format("[BuildingStore] Slope restore returned false item=%s uuid=%s", tostring(stored.Item), tostring(stored.UUID)))
					registerUnresolvedStoredItem(stored, "restore_returned_false")
				end
				task.wait()
			end

			-- 4. FINAL TREE CLEARING PASS
			local finalSweepDelay = math.min(6, 1 + (#slopes * 0.08))
			if finalSweepDelay > 0 then task.wait(finalSweepDelay) end
			updateRestoreDebug("FinalTreeClear", 1, 1, nil)
			local finalSweepOk, finalSweepCleared, finalSweepTimedOut = pcall(finalTreeClearPass)
			if not finalSweepOk then
				warn("[BuildingStore] Final tree clear pass failed: " .. tostring(finalSweepCleared))
			else
				if finalSweepTimedOut then
					warn("[BuildingStore] Final tree clear pass timed out and was truncated to keep server responsive.")
				end
				if type(finalSweepCleared) == "number" then
					warn(string.format("[BuildingStore] Final tree clear removed %d tree entries.", finalSweepCleared))
				end
			end

			if #UNRESOLVED_RESTORE_ENTRIES > 0 then
				local reasonCounts = {}
				for _, entry in ipairs(_G.BuildingRestoreUnresolvedEntries or {}) do
					local reason = tostring(entry and entry.Reason or "unknown")
					reasonCounts[reason] = (reasonCounts[reason] or 0) + 1
				end
				local reasonParts = {}
				for reason, count in pairs(reasonCounts) do
					table.insert(reasonParts, string.format("%s=%d", reason, count))
				end
				table.sort(reasonParts)
				warn(string.format(
					"[BuildingStore] Skipped %d/%d restore entries for %s. Reasons: %s",
					#UNRESOLVED_RESTORE_ENTRIES,
					#data,
					tostring(ACTIVE_BUILDING_KEY or key),
					(#reasonParts > 0) and table.concat(reasonParts, ", ") or "unknown"
				))
			end
			local settleDelay = math.clamp(0.35 + (#data * 0.01), 0.35, 3.0)
			task.wait(settleDelay)
			_G.BuildingRestoreInProgress = false
			script:SetAttribute("RestoreWatchdogToken", "")
			updateRestoreDebug("Complete", #data, #data, nil)
			markBuildingRestoreReady()
		else
			_G.BuildingRestoreItemCount = 0
			_G.BuildingRestoreInProgress = false
			script:SetAttribute("RestoreWatchdogToken", "")
			updateRestoreDebug("Complete", 0, 0, nil)
			markBuildingRestoreReady()
		end
end

local function clearOwnedPlacedObjects(ownerId)
	ownerId = tonumber(ownerId)
	if not ownerId or ownerId <= 0 then
		return
	end
	local placedFolder = workspace:FindFirstChild("PlacedObjects")
	if not placedFolder then
		return
	end
	for _, model in ipairs(placedFolder:GetChildren()) do
		if tonumber(model:GetAttribute("Owner")) == ownerId then
			model:Destroy()
		end
	end
end

BuildingForceReload.OnInvoke = function(ownerUserId)
	ownerUserId = tonumber(ownerUserId)
	if not ownerUserId or ownerUserId <= 0 then
		local slotData = ReplicatedStorage:FindFirstChild("SlotData")
		local userIdValue = slotData and slotData:FindFirstChild("UserId")
		ownerUserId = userIdValue and tonumber(userIdValue.Value) or nil
	end
	if not ownerUserId or ownerUserId <= 0 then
		return false
	end

	_G.BuildingStoreRestoreReady = false
	_G.BuildingRestoreItemCount = 0
	HAS_LOADED = false
	CAN_PERSIST = false

	clearOwnedPlacedObjects(ownerUserId)
	task.wait(1.5)  -- stagger: let TerrainStore load first
	loadData()
	return true
end

-- ============================================================
-- INIT — WAIT FOR TERRAIN READY
-- ============================================================
local SlotData = ReplicatedStorage:WaitForChild("SlotData")
local SlotNumVal = SlotData:WaitForChild("SlotNum")
local UserIdVal = SlotData:WaitForChild("UserId")

local LOADING_STARTED = false

local function startLoad()
	if LOADING_STARTED then return end
	LOADING_STARTED = true

	task.spawn(function()
		local startWait = tick()
		while SlotNumVal.Value == 0 or UserIdVal.Value == 0 do
			if tick() - startWait > 30 then
				markBuildingRestoreReady()
				return
			end
			task.wait(0.5)
		end

		SLOT_NUM = SlotNumVal.Value
		USER_ID = UserIdVal.Value

		if not _G.TerrainReady then
			local terrainWaitStart = tick()
			local terrainDone = false
			local conn
			conn = TerrainReady.Event:Connect(function()
				terrainDone = true
				if conn then conn:Disconnect() end
			end)

			while not terrainDone and not _G.TerrainReady do
				if tick() - terrainWaitStart > 120 then
					if conn then conn:Disconnect() end
					break
				end
				task.wait(0.5)
			end

			if conn then pcall(function() conn:Disconnect() end) end
		end

		if not _G.TerrainStoreRestoreReady then
			local restoreWaitStart = tick()
			local restoreDone = false
			local restoreConn
			local terrainRestoreReadyEvent = Events:FindFirstChild("TerrainRestoreReady")
			if terrainRestoreReadyEvent and terrainRestoreReadyEvent:IsA("BindableEvent") then
				restoreConn = terrainRestoreReadyEvent.Event:Connect(function()
					restoreDone = true
					if restoreConn then restoreConn:Disconnect() end
				end)
			end

			while not restoreDone and not _G.TerrainStoreRestoreReady do
				if tick() - restoreWaitStart > 180 then
					if restoreConn then restoreConn:Disconnect() end
					break
				end
				task.wait(0.5)
			end

			if restoreConn then pcall(function() restoreConn:Disconnect() end) end
		end

		task.wait(0.25)
		loadData()
	end)
end

if TerrainReady then
	TerrainReady.Event:Connect(function()
		startLoad()
	end)
end

task.delay(5, function()
	if not LOADING_STARTED then
		startLoad()
	end
end)

-- ============================================================
-- WIPE EVENT
-- ============================================================
if WipeEvent then
	WipeEvent.Event:Connect(function(sNum, uId)
		local key = getKey(uId, sNum)
		if key then
			local success, err = pcall(function() STORE:RemoveAsync(key) end)
			if success then
				script:SetAttribute("RestoreWatchdogToken", "")
				_G.BuildingRestoreInProgress = false
				HAS_LOADED = true
				CAN_PERSIST = true
				ACTIVE_BUILDING_KEY = key
				local placedFolder = workspace:FindFirstChild("PlacedObjects")
				if placedFolder then
					for _, m in ipairs(placedFolder:GetChildren()) do
						if m:GetAttribute("Owner") == uId then m:Destroy() end
					end
				end
			end
		end
	end)
end

-- ============================================================
-- AUTO-SAVE
-- ============================================================
if RequestBuildingSave then
	RequestBuildingSave.Event:Connect(function(forceImmediate)
		if not HAS_LOADED then
			return
		end
		if not CAN_PERSIST then
			warn("[BuildingStore] Ignoring save request while persistence is locked.")
			return
		end
		if forceImmediate == true then
			pendingRequestedSave = false
			saveData(true)
			return
		end
		if pendingRequestedSave then
			return
		end
		pendingRequestedSave = true
		task.delay(2, function()
			pendingRequestedSave = false
			saveData()
		end)
	end)
end

BuildingSaveNow.OnInvoke = function(force)
	return saveData(force == true)
end

local function shouldSkipStandaloneSave()
	if _G.CoordinatedSaveInProgress == true then
		return true
	end
	local lastCoordinatedSaveAt = tonumber(_G.LastCoordinatedSaveAt)
	return lastCoordinatedSaveAt ~= nil and (os.clock() - lastCoordinatedSaveAt) < 8
end

Players.PlayerRemoving:Connect(function(player)
	if shouldSkipStandaloneSave() then
		return
	end
	if shouldSaveSessionForPlayer(player) then
		saveData(true)
	end
end)

-- Mark dirty whenever the placed objects folder changes so we only save when needed
task.spawn(function()
	local placed = workspace:WaitForChild("PlacedObjects", 30)
	if placed then
		placed.ChildAdded:Connect(function() _buildingsDirty = true end)
		placed.ChildRemoved:Connect(function() _buildingsDirty = true end)
	end
end)

task.spawn(function()
	task.wait(50)
	while true do
		task.wait(60)
		if _G.CoordinatedSaveInProgress ~= true then
			saveData(false)
		end
	end
end)

game:BindToClose(function() 
	if shouldSkipStandaloneSave() then
		return
	end
	saveData(true)
	task.wait(2) 
end)
