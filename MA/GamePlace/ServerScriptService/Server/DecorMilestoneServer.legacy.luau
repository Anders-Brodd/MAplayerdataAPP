local Players = game:GetService("Players")
local DataStoreService = game:GetService("DataStoreService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local ServerScriptService = game:GetService("ServerScriptService")
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

local DecorMilestoneConfig = require(ReplicatedStorage:WaitForChild("DecorMilestoneConfig"))
local Config = require(ReplicatedStorage:WaitForChild("Config"))
local Store = nil
if not RunService:IsStudio() then
	local legacyStore = DataStoreService:GetDataStore(DecorMilestoneConfig.DataStoreName)
	Store = if CanonicalProfile
		then CanonicalProfile.CreateSlotStoreProxy(legacyStore, DecorMilestoneConfig.DataStoreName, "Decor")
		else legacyStore
end

local function getOrCreate(parent, name, className)
	local existing = parent:FindFirstChild(name)
	if existing and existing:IsA(className) then
		return existing
	end
	if existing then
		existing:Destroy()
	end
	local obj = Instance.new(className)
	obj.Name = name
	obj.Parent = parent
	return obj
end

local Events = getOrCreate(ReplicatedStorage, "Events", "Folder")
local DecorMilestoneUpdate = getOrCreate(Events, "DecorMilestoneUpdate", "RemoteEvent")
local GetDecorMilestoneState = getOrCreate(Events, "GetDecorMilestoneState", "RemoteFunction")
local NotificationEvent = Events:FindFirstChild("NotificationEvent")
local BuildingRestoreReady = Events:FindFirstChild("BuildingRestoreReady")
local DecorMilestoneSaveBindable = Events:FindFirstChild("DecorMilestoneRequestSave")
if DecorMilestoneSaveBindable and not DecorMilestoneSaveBindable:IsA("BindableFunction") then
	DecorMilestoneSaveBindable:Destroy()
	DecorMilestoneSaveBindable = nil
end
if not DecorMilestoneSaveBindable then
	DecorMilestoneSaveBindable = Instance.new("BindableFunction")
	DecorMilestoneSaveBindable.Name = "DecorMilestoneRequestSave"
	DecorMilestoneSaveBindable.Parent = Events
end
local DecorMilestoneCheck = getOrCreate(ServerStorage, "DecorMilestone_CheckUnlock", "BindableFunction")

local sessionData = {}
local sessionKeyByUser = {}
local dirtyUsers = {}
local saveEligibleUsers = {}
local pendingRefreshByUser = {}
local lastReadRequestAt = {}

local function copyUnlockedMap(map)
	local out = {}
	for key, value in pairs(map or {}) do
		if value == true then
			out[key] = true
		end
	end
	return out
end

local function sanitizeLoadedData(raw)
	local data = {
		Version = tonumber(DecorMilestoneConfig.SchemaVersion) or 1,
		BestScore = 0,
		CurrentScore = 0,
		UnlockedMilestones = {},
		LastSeen = os.time(),
	}
	if type(raw) ~= "table" then
		return data
	end
	data.Version = tonumber(raw.Version) or data.Version
	data.BestScore = math.max(0, math.floor(tonumber(raw.BestScore) or 0))
	data.CurrentScore = math.max(0, math.floor(tonumber(raw.CurrentScore) or 0))
	if type(raw.UnlockedMilestones) == "table" then
		for _, milestone in ipairs(DecorMilestoneConfig.Milestones or {}) do
			if raw.UnlockedMilestones[milestone.Id] == true then
				data.UnlockedMilestones[milestone.Id] = true
			end
		end
	end
	data.LastSeen = math.floor(tonumber(raw.LastSeen) or os.time())
	return data
end

local function applyStudioSandboxState(data)
	if not RunService:IsStudio() then
		return false
	end
	local changed = false
	local maxMilestoneScore = 0
	for _, milestone in ipairs(DecorMilestoneConfig.Milestones or {}) do
		maxMilestoneScore = math.max(maxMilestoneScore, tonumber(milestone.Score) or 0)
		if data.UnlockedMilestones[milestone.Id] ~= true then
			data.UnlockedMilestones[milestone.Id] = true
			changed = true
		end
	end
	if data.BestScore < maxMilestoneScore then
		data.BestScore = maxMilestoneScore
		changed = true
	end
	if data.CurrentScore < data.BestScore then
		data.CurrentScore = data.BestScore
		changed = true
	end
	return changed
end

local function getMilestoneUnlocks(data)
	local unlocked = {}
	for _, milestone in ipairs(DecorMilestoneConfig.Milestones or {}) do
		if data.BestScore >= milestone.Score and data.UnlockedMilestones[milestone.Id] ~= true then
			data.UnlockedMilestones[milestone.Id] = true
			table.insert(unlocked, milestone)
		end
	end
	return unlocked
end

local function buildSnapshot(data)
	local nextMilestone = DecorMilestoneConfig.GetNextMilestone(data.BestScore)
	return {
		BestScore = math.max(0, math.floor(tonumber(data.BestScore) or 0)),
		CurrentScore = math.max(0, math.floor(tonumber(data.CurrentScore) or 0)),
		UnlockedMilestones = copyUnlockedMap(data.UnlockedMilestones),
		UnlockedItems = DecorMilestoneConfig.GetUnlockedItems(data.UnlockedMilestones),
		NextMilestone = nextMilestone and {
			Id = nextMilestone.Id,
			Name = nextMilestone.Name,
			Score = nextMilestone.Score,
		} or nil,
	}
end

local function markDirty(userId)
	dirtyUsers[userId] = true
end

local function getDecorKeysForPlayer(player)
	local userId = player.UserId
	local keys = {}
	local seen = {}

	local function pushKey(key)
		if type(key) ~= "string" or key == "" or seen[key] then
			return
		end
		seen[key] = true
		table.insert(keys, key)
	end

	if type(_G.GetSlotKey) == "function" then
		local ok, slotKey = pcall(_G.GetSlotKey, userId)
		if ok and type(slotKey) == "string" and slotKey ~= "" then
			pushKey(slotKey .. "_DecorMilestones")
		end
	end

	local slotNum = tonumber(player:GetAttribute("SlotNum"))
	if slotNum and slotNum > 0 then
		pushKey(string.format("User_%d_Slot_%d_DecorMilestones", userId, slotNum))
	end

	pushKey(string.format("User_%d_Default_DecorMilestones", userId))
	return keys
end

local function waitForSlotSelection(player, timeoutSeconds)
	local timeoutAt = os.clock() + (timeoutSeconds or 15)
	while player.Parent and os.clock() < timeoutAt do
		local slotNum = tonumber(player:GetAttribute("SlotNum"))
		if slotNum and slotNum > 0 then
			return
		end
		task.wait(0.2)
	end
end

local function getPlacedFolder()
	local folder = workspace:FindFirstChild("PlacedObjects")
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = "PlacedObjects"
		folder.Parent = workspace
	end
	return folder
end

local function getModelScore(model)
	if not model or not model:IsA("Model") then
		return 0
	end
	local itemName = model.Name
	local itemConfig = Config.Items[itemName]
	local itemType = model:GetAttribute("Type") or (itemConfig and itemConfig.Type)
	if itemType == "TwoPoint" then
		return 5
	elseif itemType == "Carpet" then
		return 3
	elseif itemType == "House" or itemType == "Hotel" then
		local capacity = tonumber((itemConfig and itemConfig.Capacity) or model:GetAttribute("Capacity") or 0) or 0
		return math.max(1, math.floor(math.max(capacity, 2) / 2))
	elseif itemType == "Food" or itemType == "Rental" then
		return 3
	elseif itemType == "Vehicle" then
		return 2
	elseif itemType == "Slope" then
		if itemConfig and (itemConfig.IsQueue or itemConfig.IsPath or DecorMilestoneConfig.UtilityItems[itemName]) then
			return 0
		end
		local difficulty = tonumber((itemConfig and itemConfig.Difficulty) or model:GetAttribute("Difficulty") or 1) or 1
		return 2 + math.max(0, math.floor(difficulty) - 1)
	end
	return 0
end

local function computeCurrentScore(userId)
	local total = 0
	for _, model in ipairs(getPlacedFolder():GetChildren()) do
		if model:IsA("Model") and model:GetAttribute("Owner") == userId then
			total += getModelScore(model)
		end
	end
	return total
end

local function sendSnapshot(player)
	local data = sessionData[player.UserId]
	if not data then
		return
	end
	DecorMilestoneUpdate:FireClient(player, buildSnapshot(data))
end

local function canReadNow(userId)
	local nowClock = os.clock()
	local lastRead = lastReadRequestAt[userId] or 0
	if nowClock - lastRead < 0.05 then
		return false
	end
	lastReadRequestAt[userId] = nowClock
	return true
end

local function savePlayerById(userId)
	if not Store then
		dirtyUsers[userId] = nil
		return true
	end
	if saveEligibleUsers[userId] ~= true then
		return false
	end

	local data = sessionData[userId]
	local key = sessionKeyByUser[userId]
	if not data or not key then
		return false
	end
	local payload = {
		Version = tonumber(DecorMilestoneConfig.SchemaVersion) or data.Version or 1,
		BestScore = math.max(0, math.floor(tonumber(data.BestScore) or 0)),
		CurrentScore = math.max(0, math.floor(tonumber(data.CurrentScore) or 0)),
		UnlockedMilestones = copyUnlockedMap(data.UnlockedMilestones),
		LastSeen = os.time(),
	}
	local ok, err = pcall(function()
		Store:UpdateAsync(key, function()
			return payload
		end)
	end)
	if ok then
		dirtyUsers[userId] = nil
		return true
	end
	warn(string.format("[DecorMilestoneServer] Save failed for user %s key %s: %s", tostring(userId), tostring(key), tostring(err)))
	return false
end

local function notifyUnlocks(player, unlockedMilestones)
	if not NotificationEvent or not NotificationEvent:IsA("RemoteEvent") then
		return
	end
	for _, milestone in ipairs(unlockedMilestones) do
		NotificationEvent:FireClient(
			player,
			"Positive",
			"RESORT STYLE",
			string.format("%s unlocked new decor items.", milestone.Name),
			5
		)
	end
end

local function refreshPlayerScore(player, announceUnlocks)
	local data = sessionData[player.UserId]
	if not data then
		return
	end
	local previousCurrent = data.CurrentScore
	local currentScore = computeCurrentScore(player.UserId)
	data.CurrentScore = currentScore
	local previousBest = data.BestScore
	if currentScore > data.BestScore then
		data.BestScore = currentScore
	end
	local newlyUnlocked = getMilestoneUnlocks(data)
	if data.BestScore ~= previousBest or data.CurrentScore ~= previousCurrent or #newlyUnlocked > 0 then
		markDirty(player.UserId)
	end
	sendSnapshot(player)
	if announceUnlocks and #newlyUnlocked > 0 then
		notifyUnlocks(player, newlyUnlocked)
	end
end

local function scheduleRefresh(userId, delaySeconds)
	if pendingRefreshByUser[userId] then
		return
	end
	pendingRefreshByUser[userId] = true
	task.delay(delaySeconds or 0.75, function()
		pendingRefreshByUser[userId] = nil
		local player = Players:GetPlayerByUserId(userId)
		if player then
			refreshPlayerScore(player, true)
		end
	end)
end

local function scheduleRefreshAll(delaySeconds)
	for userId, _ in pairs(sessionData) do
		scheduleRefresh(userId, delaySeconds)
	end
end

local function scheduleRefreshForModel(model, delaySeconds)
	local ownerId = tonumber(model and model:GetAttribute("Owner"))
	if ownerId and ownerId > 0 then
		scheduleRefresh(ownerId, delaySeconds)
		return
	end
	scheduleRefreshAll(delaySeconds)
end

local function loadPlayer(player)
	if not Store then
		local data = sanitizeLoadedData(nil)
		applyStudioSandboxState(data)
		sessionData[player.UserId] = data
		saveEligibleUsers[player.UserId] = false
		sendSnapshot(player)
		scheduleRefresh(player.UserId, 0.25)
		return
	end

	waitForSlotSelection(player, 20)
	local keys = getDecorKeysForPlayer(player)
	local primaryKey = keys[1]
	sessionKeyByUser[player.UserId] = primaryKey

	local loaded = nil
	local loadedKey = nil
	local hadLookupError = false
	for _, key in ipairs(keys) do
		local ok, raw = pcall(function()
			return Store:GetAsync(key)
		end)
		if not ok then
			hadLookupError = true
		elseif raw ~= nil then
			loaded = raw
			loadedKey = key
			break
		end
	end

	local data = sanitizeLoadedData(loaded)
	getMilestoneUnlocks(data)
	sessionData[player.UserId] = data
	local saveEligible = not (hadLookupError and loaded == nil)
	saveEligibleUsers[player.UserId] = saveEligible
	if not saveEligible then
		warn(string.format("[DecorMilestoneServer] Blocking decor milestone saves for user %s because datastore reads failed and no safe snapshot was loaded.", tostring(player.UserId)))
	end
	if saveEligible and (loaded == nil or (loadedKey and loadedKey ~= primaryKey)) then
		markDirty(player.UserId)
	end
	sendSnapshot(player)
	scheduleRefresh(player.UserId, 0.25)
end

DecorMilestoneCheck.OnInvoke = function(player, itemName)
	if typeof(player) ~= "Instance" or not player:IsA("Player") then
		return { managed = false, allowed = false }
	end
	if type(itemName) ~= "string" or itemName == "" then
		return { managed = false, allowed = false }
	end
	local requirement = DecorMilestoneConfig.GetRequirement(itemName)
	if not requirement then
		return { managed = false, allowed = true }
	end
	if RunService:IsStudio() then
		return {
			managed = true,
			allowed = true,
			lockType = "DecorMilestone",
			title = "RESORT STYLE",
			subtitle = "Unlocked in Studio sandbox mode.",
			milestoneId = requirement.Id,
			milestoneName = requirement.Name,
			score = requirement.Score,
		}
	end
	local data = sessionData[player.UserId]
	local allowed = data and data.UnlockedMilestones[requirement.Id] == true or false
	return {
		managed = true,
		allowed = allowed,
		lockType = "DecorMilestone",
		title = "RESORT STYLE",
		subtitle = string.format("%s at %d style.", requirement.Name, requirement.Score),
		milestoneId = requirement.Id,
		milestoneName = requirement.Name,
		score = requirement.Score,
	}
end

GetDecorMilestoneState.OnServerInvoke = function(player)
	if not canReadNow(player.UserId) then
		return nil
	end
	local data = sessionData[player.UserId]
	if not data then
		return nil
	end
	return buildSnapshot(data)
end

DecorMilestoneSaveBindable.OnInvoke = function(targetUserId)
	local userId = tonumber(targetUserId)
	if userId and userId > 0 then
		return savePlayerById(userId)
	end

	local ownerId = nil
	if type(_G.GetSessionOwnerUserId) == "function" then
		ownerId = tonumber(_G.GetSessionOwnerUserId())
	end
	if ownerId and ownerId > 0 then
		return savePlayerById(ownerId)
	end

	local savedAny = false
	for anyUserId in pairs(sessionData) do
		if savePlayerById(anyUserId) then
			savedAny = true
		end
	end
	return savedAny
end

local function initPlayer(player)
	task.spawn(function()
		loadPlayer(player)
	end)
end

Players.PlayerAdded:Connect(initPlayer)
for _, player in ipairs(Players:GetPlayers()) do
	initPlayer(player)
end

local function shouldSkipStandaloneSave()
	if _G.CoordinatedSaveInProgress == true then
		return true
	end
	local lastCoordinatedSaveAt = tonumber(_G.LastCoordinatedSaveAt)
	return lastCoordinatedSaveAt ~= nil and (os.clock() - lastCoordinatedSaveAt) < 8
end

Players.PlayerRemoving:Connect(function(player)
	if not shouldSkipStandaloneSave() then
		savePlayerById(player.UserId)
	end
	sessionData[player.UserId] = nil
	sessionKeyByUser[player.UserId] = nil
	dirtyUsers[player.UserId] = nil
	saveEligibleUsers[player.UserId] = nil
	pendingRefreshByUser[player.UserId] = nil
	lastReadRequestAt[player.UserId] = nil
end)

game:BindToClose(function()
	if shouldSkipStandaloneSave() then
		return
	end
	for _, player in ipairs(Players:GetPlayers()) do
		savePlayerById(player.UserId)
	end
end)

task.spawn(function()
	while true do
		task.wait(math.max(15, tonumber(DecorMilestoneConfig.AutoSaveSeconds) or 60))
		for userId, _ in pairs(dirtyUsers) do
			savePlayerById(userId)
		end
	end
end)

local placedFolder = getPlacedFolder()
placedFolder.ChildAdded:Connect(function(child)
	scheduleRefreshForModel(child, 1)
end)
placedFolder.ChildRemoved:Connect(function(child)
	scheduleRefreshForModel(child, 1)
end)

if BuildingRestoreReady and BuildingRestoreReady:IsA("BindableEvent") then
	BuildingRestoreReady.Event:Connect(function()
		scheduleRefreshAll(0.5)
	end)
elseif _G.BuildingStoreRestoreReady then
	scheduleRefreshAll(0.5)
else
	task.delay(5, function()
		scheduleRefreshAll(0.5)
	end)
end