-- TerrainStore
-- ServerScriptService (MainGame/GameWorld)
-- Handles terrain action persistence with slot-specific data storage

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local ServerScriptService = game:GetService("ServerScriptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

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

local TrackEvent = Instance.new("BindableEvent")
TrackEvent.Name = "TrackTerrainAction"
TrackEvent.Parent = script

local PopEvent = Instance.new("BindableEvent")
PopEvent.Name = "PopTerrainAction"
PopEvent.Parent = script

local PushEvent = Instance.new("BindableEvent")
PushEvent.Name = "PushTerrainAction" 
PushEvent.Parent = script



local LegacyTerrainStore = DataStoreService:GetDataStore("TycoonTerrain")
local TerrainStore = if CanonicalProfile
	then CanonicalProfile.CreateSlotStoreProxy(LegacyTerrainStore, "TycoonTerrain", "TerrainActions")
	else LegacyTerrainStore
local TerrainBackupStore = DataStoreService:GetDataStore("TycoonTerrainBackups_v1")
local LegacyGameDataStore = DataStoreService:GetDataStore("TycoonGameData")
local GameDataStore = if CanonicalProfile
	then CanonicalProfile.CreateSlotStoreProxy(LegacyGameDataStore, "TycoonGameData", "GameData")
	else LegacyGameDataStore

local TerrainServer

local sessionData = {}

local SlotData = ReplicatedStorage:WaitForChild("SlotData")
local SlotNumVal = SlotData:WaitForChild("SlotNum")
local UserIdVal = SlotData:WaitForChild("UserId")
local CreatedTimeVal = SlotData:FindFirstChild("CreatedTime")
if CreatedTimeVal and not CreatedTimeVal:IsA("IntValue") then
	CreatedTimeVal:Destroy()
	CreatedTimeVal = nil
end
if not CreatedTimeVal then
	CreatedTimeVal = Instance.new("IntValue")
	CreatedTimeVal.Name = "CreatedTime"
	CreatedTimeVal.Parent = SlotData
end
local Events = ReplicatedStorage:WaitForChild("Events")
local TerrainReady = Events:WaitForChild("TerrainReady")
local TerrainRestoreReady = Events:FindFirstChild("TerrainRestoreReady")
if not TerrainRestoreReady then
	TerrainRestoreReady = Instance.new("BindableEvent")
	TerrainRestoreReady.Name = "TerrainRestoreReady"
	TerrainRestoreReady.Parent = Events
end

local WipeEvent = Events:FindFirstChild("WipeTerrainStore")
if WipeEvent and not WipeEvent:IsA("BindableEvent") then
	WipeEvent:Destroy()
	WipeEvent = nil
end
if not WipeEvent then
	WipeEvent = Instance.new("BindableEvent")
	WipeEvent.Name = "WipeTerrainStore"
	WipeEvent.Parent = Events
end

local TerrainSaveBindable = Events:FindFirstChild("TerrainRequestSave")
if TerrainSaveBindable and not TerrainSaveBindable:IsA("BindableFunction") then
	TerrainSaveBindable:Destroy()
	TerrainSaveBindable = nil
end
if not TerrainSaveBindable then
	TerrainSaveBindable = Instance.new("BindableFunction")
	TerrainSaveBindable.Name = "TerrainRequestSave"
	TerrainSaveBindable.Parent = Events
end

local TerrainForceReload = Events:FindFirstChild("TerrainForceReload")
if TerrainForceReload and not TerrainForceReload:IsA("BindableFunction") then
	TerrainForceReload:Destroy()
	TerrainForceReload = nil
end
if not TerrainForceReload then
	TerrainForceReload = Instance.new("BindableFunction")
	TerrainForceReload.Name = "TerrainForceReload"
	TerrainForceReload.Parent = Events
end

local HAS_LOADED = false
local CAN_PERSIST = false
local ACTIVE_TERRAIN_KEY = nil
local LOAD_LOCKED_BY_ERROR = false
local LOAD_IN_PROGRESS = false
local LAST_SESSION_SAVE_AT = 0
local SESSION_SAVE_COOLDOWN_SECONDS = 30
local LAST_TERRAIN_BACKUP_AT = 0
local TERRAIN_BACKUP_MIN_INTERVAL_SECONDS = 600
_G.TerrainStoreRestoreReady = false
_G.TerrainRestoreActionCount = 0

local function markTerrainRestoreReady()
	if _G.TerrainStoreRestoreReady then return end
	_G.TerrainStoreRestoreReady = true
	if TerrainRestoreReady then
		TerrainRestoreReady:Fire()
	end
end

local function getSessionOwnerId(timeoutSeconds)
	local start = tick()
	while UserIdVal.Value == 0 do
		if tick() - start > (timeoutSeconds or 5) then return nil end
		task.wait(0.2)

	end
	return UserIdVal.Value
end

local function getSessionSlotNum(timeoutSeconds)
	local start = tick()
	while SlotNumVal.Value == 0 do
		if tick() - start > (timeoutSeconds or 5) then return nil end
		task.wait(0.2)
	end
	return SlotNumVal.Value
end

local function getCanonicalTerrainKey(ownerId, slotNum)
	return string.format("User_%d_Slot_%d_Terrain", ownerId, slotNum)
end

local function getLegacyTerrainKey(ownerId, slotNum)
	return "User_" .. ownerId .. "_Slot" .. slotNum
end

local function buildSlotKeyCandidatesFor(ownerId, slotNum)
	if not ownerId or not slotNum then
		return {}
	end

	local candidates = {}
	local seen = {}
	local function push(key)
		if type(key) ~= "string" or key == "" or seen[key] then
			return
		end
		seen[key] = true
		table.insert(candidates, key)
	end

	if type(_G.GetSlotKey) == "function" then
		local ok, slotBase = pcall(_G.GetSlotKey, ownerId)
		if ok and type(slotBase) == "string" and slotBase ~= "" then
			push(slotBase .. "_Terrain")
		end
	end

	push(getCanonicalTerrainKey(ownerId, slotNum))
	push(string.format("User_%d_Slot_%d_Terrain", ownerId, slotNum))
	push(getLegacyTerrainKey(ownerId, slotNum))
	return candidates
end

local function buildSlotKeyCandidates()
	local ownerId = getSessionOwnerId()
	local slotNum = getSessionSlotNum()
	return buildSlotKeyCandidatesFor(ownerId, slotNum)
end

local function getGameDataLoadKeys(ownerId, slotNum)
	if not ownerId or not slotNum then
		return {}
	end
	return {
		string.format("User_%d_Slot_%d_GameData", ownerId, slotNum),
		string.format("User_%d_Slot%d_GameData", ownerId, slotNum),
		string.format("User_%d_Slot_%d", ownerId, slotNum),
		string.format("User_%d_Slot%d", ownerId, slotNum),
	}
end

local function sessionHasExistingGameData(ownerId, slotNum)
	if not ownerId or not slotNum then
		return nil
	end
	local hadLookupError = false
	for _, key in ipairs(getGameDataLoadKeys(ownerId, slotNum)) do
		local ok, payload = pcall(function()
			return GameDataStore:GetAsync(key)
		end)
		if ok then
			if type(payload) == "table" and (payload.CreatedTime ~= nil or payload.Money ~= nil or payload.Objects ~= nil or payload.ResortName ~= nil) then
				return true
			end
		else
			hadLookupError = true
			warn("[TerrainStore] Game data lookup failed for key " .. tostring(key) .. ": " .. tostring(payload))
		end
	end
	if hadLookupError then
		return nil
	end
	return false
end

local function getSessionCreatedTime()
	if CreatedTimeVal and CreatedTimeVal:IsA("IntValue") then
		return tonumber(CreatedTimeVal.Value) or 0
	end
	return 0
end

local function isFreshSaveSession()
	return SlotData:GetAttribute("FreshSave") == true
end

local function wipeKeysFromStore(store, keys, label)
	for _, key in ipairs(keys) do
		local ok, err = pcall(function()
			store:RemoveAsync(key)
		end)
		if not ok then
			warn("[TerrainStore] Failed to wipe " .. tostring(label) .. " key " .. tostring(key) .. ": " .. tostring(err))
		end
	end
end

local function wipeStaleTerrainData(ownerId, slotNum)
	local keys = buildSlotKeyCandidatesFor(ownerId, slotNum)
	wipeKeysFromStore(TerrainStore, keys, "terrain")
	wipeKeysFromStore(TerrainBackupStore, keys, "terrain backup")
end

local function getSessionBucket()
	local ownerId = getSessionOwnerId()
	if not ownerId then
		return nil, nil
	end
	local bucket = sessionData[ownerId]
	if not bucket then
		bucket = {}
		sessionData[ownerId] = bucket
	end
	return ownerId, bucket
end

local function serializePos(vec)
	return {math.floor(vec.X*10), math.floor(vec.Y*10), math.floor(vec.Z*10)}
end

local function deserializePos(tbl)
	return Vector3.new(tbl[1]/10, tbl[2]/10, tbl[3]/10)
end

local function loadFromStoreWithRetries(key)
	local lastErr = nil
	for attempt = 1, 4 do
		local ok, result = pcall(function()
			return TerrainStore:GetAsync(key)
		end)
		if ok then
			return true, result
		end
		lastErr = result
		task.wait(0.8 * attempt)
	end
	return false, nil, tostring(lastErr)
end

local function waitForUpdateBudget(maxWaitSeconds)
	local deadline = os.clock() + math.max(0, tonumber(maxWaitSeconds) or 0)
	repeat
		local ok, budget = pcall(function()
			return DataStoreService:GetRequestBudgetForRequestType(Enum.DataStoreRequestType.UpdateAsync)
		end)
		if ok and type(budget) == "number" and budget >= 1 then
			return true
		end
		if os.clock() >= deadline then
			return false
		end
		task.wait(0.25)
	until false
end

local function saveToStoreWithRetries(key, payload, force)
	local lastErr = nil
	for attempt = 1, 5 do
		if not waitForUpdateBudget(force and 8 or 1.5) then
			lastErr = "budget_exhausted"
			break
		end
		local ok, err = pcall(function()
			TerrainStore:UpdateAsync(key, function()
				return payload
			end)
		end)
		if ok then
			return true
		end
		lastErr = err
		task.wait(1.0 * attempt)
	end
	return false, tostring(lastErr)
end

local function loadBestBackupSnapshot(keys, expectedCreatedTime)
	local bestData = nil
	local bestKey = nil
	local bestScore = -math.huge
	expectedCreatedTime = tonumber(expectedCreatedTime) or 0
	for _, key in ipairs(keys) do
		local ok, backup = pcall(function()
			return TerrainBackupStore:GetAsync(key)
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

local function saveBackupSnapshot(key, payload, force)
	if not force and (os.clock() - LAST_TERRAIN_BACKUP_AT) < TERRAIN_BACKUP_MIN_INTERVAL_SECONDS then
		return
	end
	if not waitForUpdateBudget(force and 6 or 0.75) then
		return
	end
	local backupPayload = table.clone(payload)
	backupPayload.__SavedAt = os.time()
	pcall(function()
		TerrainBackupStore:UpdateAsync(key, function(oldData)
			local oldTs = type(oldData) == "table" and tonumber(oldData.__SavedAt) or 0
			if oldTs and oldTs > backupPayload.__SavedAt then
				return oldData
			end
			return backupPayload
		end)
	end)
	LAST_TERRAIN_BACKUP_AT = os.clock()
end

local function shouldSaveSessionForPlayer(player)
	if not player then
		return true
	end
	local ownerId = tonumber(UserIdVal.Value)
	if not ownerId or ownerId <= 0 then
		return true
	end
	return player.UserId == ownerId
end

local function savePlayer(player, force)
	if not shouldSaveSessionForPlayer(player) then
		return false
	end
	if not HAS_LOADED then
		return false
	end
	if not CAN_PERSIST then
		warn("[TerrainStore] Save skipped because persistence is locked after failed datastore reads.")
		return false
	end
	if not force and (os.clock() - LAST_SESSION_SAVE_AT) < SESSION_SAVE_COOLDOWN_SECONDS then
		return false
	end

	local ownerId, data = getSessionBucket()
	if not ownerId or not data then
		return false
	end

	local sessionCreatedTime = getSessionCreatedTime()
	if sessionCreatedTime <= 0 and force and isFreshSaveSession() then
		local deadline = os.clock() + 8
		while sessionCreatedTime <= 0 and os.clock() < deadline do
			task.wait(0.25)
			sessionCreatedTime = getSessionCreatedTime()
		end
	end
	if sessionCreatedTime > 0 then
		data.CreatedTime = sessionCreatedTime
	end

	local key = ACTIVE_TERRAIN_KEY
	if not key then
		local candidates = buildSlotKeyCandidates()
		key = candidates[1]
		ACTIVE_TERRAIN_KEY = key
	end
	if not key and force then
		local deadline = os.clock() + 8
		repeat
			local candidates = buildSlotKeyCandidates()
			key = candidates[1]
			if key then
				ACTIVE_TERRAIN_KEY = key
				break
			end
			task.wait(0.25)
		until os.clock() >= deadline
	end
	if not key then
		warn("[TerrainStore] Save skipped because terrain key is unresolved.")
		return false
	end

	local success, err = saveToStoreWithRetries(key, data, force)
	if not success then
		warn("[TerrainStore] Save failed for key " .. tostring(key) .. ": " .. tostring(err))
		return false
	end

	saveBackupSnapshot(key, data, force)
	LAST_SESSION_SAVE_AT = os.clock()
	return true
end

local function loadPlayer(player)
	if not player then return 0 end
	if HAS_LOADED or LOAD_IN_PROGRESS then return 0 end
	LOAD_IN_PROGRESS = true

	local function finishLoad(result)
		LOAD_IN_PROGRESS = false
		return result
	end

	local ownerId = getSessionOwnerId()
	local slotNum = getSessionSlotNum()
	local candidates = buildSlotKeyCandidates()
	if not ownerId or not slotNum or #candidates == 0 then
		warn("[TerrainStore] Slot identity unavailable during terrain load.")
		return finishLoad(0)
	end

	local hasGameData = sessionHasExistingGameData(ownerId, slotNum)
	if hasGameData == false then
		wipeStaleTerrainData(ownerId, slotNum)
		sessionData = {}
		sessionData[ownerId] = {}
		ACTIVE_TERRAIN_KEY = candidates[1]
		HAS_LOADED = true
		CAN_PERSIST = true
		LOAD_LOCKED_BY_ERROR = false
		warn("[TerrainStore] Skipping terrain restore because no matching game data exists for this slot. Cleared orphaned terrain actions.")
		return finishLoad(0)
	end

	local expectedCreatedTime = getSessionCreatedTime()
	local loadedData = nil
	local loadedKey = nil
	local bestLoadScore = -math.huge
	local hadLookupError = false

	local function getTerrainLoadScore(payload)
		if type(payload) ~= "table" then
			return -math.huge
		end
		local savedCreatedTime = tonumber(payload.CreatedTime) or 0
		local score = math.clamp(#payload, 0, 200000)
		if expectedCreatedTime > 0 then
			if savedCreatedTime == expectedCreatedTime then
				score += 1000000
			elseif savedCreatedTime > 0 then
				score += 1000
			end
		elseif savedCreatedTime > 0 then
			score += 1000
		end
		return score
	end

	for _, key in ipairs(candidates) do
		local ok, result, err = loadFromStoreWithRetries(key)
		if ok then
			if type(result) == "table" then
				local score = getTerrainLoadScore(result)
				if not loadedData or score > bestLoadScore then
					loadedData = result
					loadedKey = key
					bestLoadScore = score
				end
			elseif result ~= nil then
				warn("[TerrainStore] Ignoring invalid terrain payload for key " .. tostring(key))
			end
		else
			hadLookupError = true
			warn("[TerrainStore] Load failed for key " .. tostring(key) .. ": " .. tostring(err))
		end
	end

	if not loadedData then
		local backupData, backupKey = loadBestBackupSnapshot(candidates, expectedCreatedTime)
		if type(backupData) == "table" then
			loadedData = backupData
			loadedKey = backupKey
			warn("[TerrainStore] Recovered terrain actions from backup key " .. tostring(backupKey))
		end
	end

	if not loadedData and hadLookupError then
		LOAD_LOCKED_BY_ERROR = true
		CAN_PERSIST = false
		warn("[TerrainStore] Blocking terrain writes because reads failed and no safe snapshot could be loaded.")
		return finishLoad(0)
	end

	if type(loadedData) ~= "table" then
		loadedData = {}
	end

	local freshSaveSession = isFreshSaveSession()
	local savedCreatedTime = tonumber(loadedData.CreatedTime) or 0
	if expectedCreatedTime > 0 and savedCreatedTime > 0 and savedCreatedTime ~= expectedCreatedTime then
		warn(string.format(
			"[TerrainStore] CreatedTime mismatch for %s (Store=%s, Expected=%s). Ignoring stale terrain actions from an older save in this slot.",
			tostring(loadedKey or candidates[1]),
			tostring(savedCreatedTime),
			tostring(expectedCreatedTime)
		))
		wipeStaleTerrainData(ownerId, slotNum)
		loadedData = {}
		loadedKey = candidates[1]
	elseif #loadedData > 0 and freshSaveSession and (savedCreatedTime == 0 or expectedCreatedTime == 0 or savedCreatedTime ~= expectedCreatedTime) then
		warn(string.format(
			"[TerrainStore] Ignoring terrain actions for fresh save %s because they likely belong to a deleted world.",
			tostring(loadedKey or candidates[1])
		))
		wipeStaleTerrainData(ownerId, slotNum)
		loadedData = {}
		loadedKey = candidates[1]
	end

	sessionData = {}
	sessionData[ownerId] = loadedData
	ACTIVE_TERRAIN_KEY = loadedKey or candidates[1]
	local restoredCount = #sessionData[ownerId]

	local TS = ServerScriptService:FindFirstChild("TerrainServer")
	if not TS then
		local tFolder = ServerScriptService:FindFirstChild("Terrain")
		if tFolder then TS = tFolder:FindFirstChild("TerrainServer") end
	end

	if not TS then
		warn("[TerrainStore] TerrainServer was unavailable during restore.")
		HAS_LOADED = true
		CAN_PERSIST = true
		LOAD_LOCKED_BY_ERROR = false
		return finishLoad(0)
	end

	local restoreTarget = TS:WaitForChild("RestoreTerrain")
	for _, action in ipairs(sessionData[ownerId]) do
		local restoredData = {
			Tool = action.Tool,
			Position = deserializePos(action.Pos),
			Size = action.Size,
			Strength = tonumber(action.Strength) or 1,
			Material = action.Mat,
			Normal = action.Norm and deserializePos(action.Norm) or nil
		}
		restoreTarget:Fire(player, restoredData)
	end

	HAS_LOADED = true
	CAN_PERSIST = true
	LOAD_LOCKED_BY_ERROR = false
	warn("[TerrainStore] Restored " .. tostring(restoredCount) .. " terrain actions for key " .. tostring(ACTIVE_TERRAIN_KEY))
	return finishLoad(restoredCount)
end

local queuedTerrainSaveToken = 0
local function queueTerrainSave(delaySeconds)
	queuedTerrainSaveToken += 1
	local token = queuedTerrainSaveToken
	task.delay(delaySeconds or 2.5, function()
		if token ~= queuedTerrainSaveToken then
			return
		end
		savePlayer(nil, false)
	end)
end

TerrainSaveBindable.OnInvoke = function(force)
	return savePlayer(nil, force == true)
end

TerrainForceReload.OnInvoke = function(ownerUserId)
	ownerUserId = tonumber(ownerUserId)
	if not ownerUserId or ownerUserId <= 0 then
		ownerUserId = tonumber(UserIdVal.Value)
	end
	if not ownerUserId or ownerUserId <= 0 then
		return false
	end

	local ownerPlayer = Players:GetPlayerByUserId(ownerUserId)
	if not ownerPlayer then
		ownerPlayer = Players:GetPlayers()[1]
	end
	if not ownerPlayer then
		return false
	end

	_G.TerrainStoreRestoreReady = false
	_G.TerrainRestoreActionCount = 0
	HAS_LOADED = false
	CAN_PERSIST = false
	LOAD_IN_PROGRESS = false

	local restored = loadPlayer(ownerPlayer)
	_G.TerrainRestoreActionCount = restored or 0
	if restored and restored > 0 then
		local settleDelay = math.clamp(0.5 + (restored * 0.0015), 0.5, 4.5)
		task.wait(settleDelay)
	end
	markTerrainRestoreReady()
	return true
end

if WipeEvent then
	WipeEvent.Event:Connect(function(slotNum, ownerId)
		slotNum = tonumber(slotNum)
		ownerId = tonumber(ownerId)
		if not slotNum or not ownerId then
			return
		end
		wipeStaleTerrainData(ownerId, slotNum)
		if tonumber(UserIdVal.Value) == ownerId and tonumber(SlotNumVal.Value) == slotNum then
			sessionData[ownerId] = {}
			ACTIVE_TERRAIN_KEY = buildSlotKeyCandidatesFor(ownerId, slotNum)[1]
			LOAD_IN_PROGRESS = false
		end
		_G.TerrainRestoreActionCount = 0
	end)
end

-- Wait for TerrainReady to load
if TerrainReady then
	TerrainReady.Event:Connect(function()
		task.wait(1) -- Load edits quickly so buildings can Raycast correctly later
		local slotWaitStart = tick()
		while SlotNumVal.Value == 0 and (tick() - slotWaitStart) < 15 do
			task.wait(0.25)
		end
		local restoredTotal = 0
		if SlotNumVal.Value > 0 then
			local ownerPlayer = Players:GetPlayerByUserId(UserIdVal.Value)
			if not ownerPlayer then
				ownerPlayer = Players:GetPlayers()[1]
			end
			if ownerPlayer then
				restoredTotal = loadPlayer(ownerPlayer)
			end
		end
		_G.TerrainRestoreActionCount = restoredTotal
		if restoredTotal > 0 then
			-- Let bulk voxel updates settle before downstream systems unlock players.
			local settleDelay = math.clamp(0.5 + (restoredTotal * 0.0015), 0.5, 4.5)
			task.wait(settleDelay)
		end
		markTerrainRestoreReady()
	end)
end

-- Also load if player joins LATER
Players.PlayerAdded:Connect(function(player)
	task.wait(3)
	local readyWaitStart = tick()
	while not _G.TerrainReady and (tick() - readyWaitStart) < 45 do
		task.wait(0.5)
	end
	if SlotNumVal.Value > 0 and not HAS_LOADED then
		local restored = loadPlayer(player)
		if restored and restored > 0 then
			_G.TerrainRestoreActionCount = math.max(_G.TerrainRestoreActionCount or 0, restored or 0)
		end
	end
end)

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
	savePlayer(player, true)
end)

game:BindToClose(function()
	if shouldSkipStandaloneSave() then
		return
	end
	savePlayer(nil, true)
end)

-- PERF: Increased autosave from 60s to 120s. BindToClose still catches shutdown saves.
-- Offset terrain autosaves from the main slot autosave so both stores do not burst at once.
task.spawn(function()
	task.wait(35)
	while true do
		task.wait(120)
		if not shouldSkipStandaloneSave() then
			savePlayer(nil, false)
		end
	end
end)

TrackEvent.Event:Connect(function(player, data)
	local _, bucket = getSessionBucket()
	if not bucket then return end

	local entry = {
		Tool = data.Tool,
		Pos = serializePos(data.Position),
		Size = data.Size,
		Strength = tonumber(data.Strength) or 1,
		Mat = data.Material.Value,
		Norm = data.Normal and serializePos(data.Normal) or nil
	}
	table.insert(bucket, entry)
	queueTerrainSave()
end)

PopEvent.Event:Connect(function(player)
	local _, bucket = getSessionBucket()
	if not bucket then return end
	local count = #bucket
	if count > 0 then
		table.remove(bucket, count)
		queueTerrainSave()
	end
end)



PushEvent.Event:Connect(function(player, data)
	local _, bucket = getSessionBucket()
	if not bucket then return end

	local entry = {
		Tool = data.Tool,
		Pos = serializePos(data.Position),
		Size = data.Size,
		Strength = tonumber(data.Strength) or 1,
		Mat = data.Material.Value,
		Norm = data.Normal and serializePos(data.Normal) or nil
	}
	table.insert(bucket, entry)
	queueTerrainSave()
end)
