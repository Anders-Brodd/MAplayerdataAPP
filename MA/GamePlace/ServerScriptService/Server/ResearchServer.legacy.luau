--!strict
--[=[ PATH: ServerScriptService.Server.ResearchServer | TYPE: Script ]=]--

-- Legacy duplicate block retained for reference but intentionally disabled.
if false then
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local DataStoreService = game:GetService("DataStoreService")
local RunService = game:GetService("RunService")

local ResearchFolder = ReplicatedStorage:WaitForChild("Research")
local ResearchConfig = require(ResearchFolder:WaitForChild("ResearchConfig"))

local Events = ReplicatedStorage:WaitForChild("Events")

local function ensureRemote(name: string, className: string)
	local existing = Events:FindFirstChild(name)
	if existing and existing.ClassName ~= className then
		existing:Destroy()
		existing = nil
	end
	if existing then
		return existing
	end

	local instance = Instance.new(className)
	instance.Name = name
	instance.Parent = Events
	return instance
end

local ResearchUpdate = ensureRemote("ResearchUpdate", "RemoteEvent") :: RemoteEvent
local StartResearch = ensureRemote("StartResearch", "RemoteFunction") :: RemoteFunction
local GetResearchState = ensureRemote("GetResearchState", "RemoteFunction") :: RemoteFunction
local ResearchRequestSave = ensureRemote("ResearchRequestSave", "BindableFunction") :: BindableFunction

local ResearchStore = nil
if not RunService:IsStudio() then
	ResearchStore = DataStoreService:GetDataStore(ResearchConfig.DataStoreName)
end

type CurrentResearch = {
	Id: string,
	StartTime: number,
	EndTime: number,
}

type ResearchState = {
	Player: Player,
	UserId: number,
	Loaded: boolean,
	Loading: boolean,
	Saving: boolean,
	Dirty: boolean,
	LoadFailed: boolean,
	LastRequestAt: number,
	LastSaveAt: number,
	LastProgressAt: number,
	StoreKey: string?,
	RP: number,
	Unlocked: {[string]: boolean},
	Current: CurrentResearch?,
}

local PASSIVE_RP_PER_TICK = math.max(0, math.floor(tonumber(ResearchConfig.PassiveRPPerTick) or 0))
local PASSIVE_TICK_SECONDS = math.max(1, math.floor(tonumber(ResearchConfig.PassiveTickSeconds) or 1))
local OFFLINE_CAP_SECONDS = math.max(0, math.floor(tonumber(ResearchConfig.OfflineProgressCapSeconds) or 0))
local MAX_RP = math.max(0, math.floor(tonumber(ResearchConfig.MaxRP) or 250000))
local START_RP = math.max(0, math.floor(tonumber(ResearchConfig.StartRP) or 0))
local SAVE_DEBOUNCE_SECONDS = 5
local RATE_LIMIT_SECONDS = 0.25
local LOAD_TIMEOUT_SECONDS = 30
local SAVE_KEY_SUFFIX = "Research_v1"

local playerStates: {[number]: ResearchState} = {}
local saveTokens: {[number]: number} = {}
local loadTokens: {[number]: number} = {}

local function clampRP(value: number): number
	return math.clamp(math.floor(value + 0.5), 0, MAX_RP)
end

local function isKnownTechId(techId: any): boolean
	return type(techId) == "string" and ResearchConfig.TechTree[techId] ~= nil
end

local function buildDefaultUnlocked(): {[string]: boolean}
	local unlocked = {}
	local roots = type(ResearchConfig.RootNodes) == "table" and ResearchConfig.RootNodes or {}
	for _, techId in ipairs(roots) do
		if isKnownTechId(techId) then
			unlocked[techId] = true
		end
	end
	if next(unlocked) == nil and isKnownTechId("Basics") then
		unlocked.Basics = true
	end
	return unlocked
end

local function cloneUnlocked(source: any): {[string]: boolean}
	local unlocked = buildDefaultUnlocked()
	if type(source) ~= "table" then
		return unlocked
	end
	for techId, value in pairs(source) do
		if value == true and isKnownTechId(techId) then
			unlocked[techId] = true
		end
	end
	return unlocked
end

local function sanitizeCurrent(source: any): CurrentResearch?
	if type(source) ~= "table" then
		return nil
	end

	local techId = source.Id
	if not isKnownTechId(techId) then
		return nil
	end

	local startTime = math.max(0, math.floor(tonumber(source.StartTime) or 0))
	local endTime = math.max(startTime, math.floor(tonumber(source.EndTime) or 0))
	if startTime <= 0 or endTime <= startTime then
		return nil
	end

	return {
		Id = techId,
		StartTime = startTime,
		EndTime = endTime,
	}
end

local function makeSnapshot(state: ResearchState)
	local unlocked = {}
	for techId, value in pairs(state.Unlocked) do
		if value == true then
			unlocked[techId] = true
		end
	end

	local snapshot = {
		SchemaVersion = ResearchConfig.SchemaVersion,
		RP = clampRP(state.RP),
		Unlocked = unlocked,
		Current = state.Current and {
			Id = state.Current.Id,
			StartTime = state.Current.StartTime,
			EndTime = state.Current.EndTime,
		} or nil,
	}

	return snapshot
end

local function resolveIdentity(player: Player): (number?, number?, number?)
	local slotData = ReplicatedStorage:FindFirstChild("SlotData")
	if slotData then
		local userIdValue = slotData:FindFirstChild("UserId")
		local slotNumValue = slotData:FindFirstChild("SlotNum")
		local createdTimeValue = slotData:FindFirstChild("CreatedTime")
		local userId = userIdValue and tonumber((userIdValue :: any).Value) or nil
		local slotNum = slotNumValue and tonumber((slotNumValue :: any).Value) or nil
		local createdTime = createdTimeValue and tonumber((createdTimeValue :: any).Value) or nil
		if userId and userId > 0 then
			if slotNum and slotNum > 0 then
				return userId, slotNum, math.max(0, createdTime or 0)
			end
			return userId, 0, math.max(0, createdTime or 0)
		end
	end

	if player and player.UserId > 0 then
		return player.UserId, 0, 0
	end

	return nil, nil, nil
end

local function makeStoreKey(userId: number, slotNum: number, createdTime: number): string
	if slotNum > 0 then
		if createdTime > 0 then
			return string.format("User_%d_Slot_%d_CT_%d_%s", userId, slotNum, createdTime, SAVE_KEY_SUFFIX)
		end
		return string.format("User_%d_Slot_%d_%s", userId, slotNum, SAVE_KEY_SUFFIX)
	end
	return string.format("User_%d_%s", userId, SAVE_KEY_SUFFIX)
end

local function getState(player: Player): ResearchState
	local existing = playerStates[player.UserId]
	if existing then
		existing.Player = player
		return existing
	end

	local state: ResearchState = {
		Player = player,
		UserId = player.UserId,
		Loaded = false,
		Loading = false,
		Saving = false,
		Dirty = false,
		LoadFailed = false,
		LastRequestAt = 0,
		LastSaveAt = 0,
		LastProgressAt = os.time(),
		StoreKey = nil,
		RP = START_RP,
		Unlocked = buildDefaultUnlocked(),
		Current = nil,
	}
	playerStates[player.UserId] = state
	return state
end

local function touchDirty(state: ResearchState)
	state.Dirty = true
end

local function pushSnapshot(player: Player, state: ResearchState)
	if player.Parent ~= Players then
		return
	end
	ResearchUpdate:FireClient(player, makeSnapshot(state))
end

local function finalizeCurrentResearch(state: ResearchState, now: number): boolean
	if not state.Current then
		return false
	end

	if now < state.Current.EndTime then
		return false
	end

	state.Unlocked[state.Current.Id] = true
	state.Current = nil
	return true
end

local function applyPassiveProgress(state: ResearchState, now: number): boolean
	if PASSIVE_RP_PER_TICK <= 0 then
		state.LastProgressAt = now
		return false
	end

	local lastProgressAt = state.LastProgressAt or now
	if now <= lastProgressAt then
		return false
	end

	local elapsed = now - lastProgressAt
	if OFFLINE_CAP_SECONDS > 0 then
		elapsed = math.min(elapsed, OFFLINE_CAP_SECONDS)
	end

	local ticks = math.floor(elapsed / PASSIVE_TICK_SECONDS)
	if ticks <= 0 then
		return false
	end

	state.LastProgressAt = lastProgressAt + (ticks * PASSIVE_TICK_SECONDS)
	local rpToAdd = ticks * PASSIVE_RP_PER_TICK
	if rpToAdd > 0 then
		state.RP = clampRP(state.RP + rpToAdd)
	end
	return true
end

local function maybeSyncState(player: Player, state: ResearchState)
	if not state.Loaded then
		return
	end

	local now = os.time()
	local changed = false
	if applyPassiveProgress(state, now) then
		touchDirty(state)
		changed = true
	end
	if finalizeCurrentResearch(state, now) then
		touchDirty(state)
		changed = true
	end

	if changed then
		pushSnapshot(player, state)
		return
	end
end

local function saveState(player: Player, state: ResearchState, immediate: boolean): boolean
	if not state.Loaded or not state.StoreKey or state.Saving then
		return false
	end

	local now = os.time()
	if not immediate and not state.Dirty then
		return false
	end

	state.Saving = true
	local payload = {
		SchemaVersion = ResearchConfig.SchemaVersion,
		RP = clampRP(state.RP),
		Unlocked = makeSnapshot(state).Unlocked,
		Current = state.Current and {
			Id = state.Current.Id,
			StartTime = state.Current.StartTime,
			EndTime = state.Current.EndTime,
		} or nil,
		LastProgressAt = state.LastProgressAt,
		SavedAt = now,
	}

	local success = false
	local errorMessage = nil

	if RunService:IsStudio() or not ResearchStore then
		success = true
	else
		local ok, err = pcall(function()
			ResearchStore:UpdateAsync(state.StoreKey, function()
				return payload
			end)
		end)
		success = ok
		if not ok then
			errorMessage = tostring(err)
		end
	end

	state.Saving = false
	if success then
		state.Dirty = false
		state.LastSaveAt = now
		return true
	end

	warn(string.format("[ResearchServer] Failed to save research state for %s: %s", player.Name, tostring(errorMessage)))
	return false
end

local function queueSave(player: Player, immediate: boolean?)
	local state = playerStates[player.UserId]
	if not state or not state.Loaded then
		return
	end

	local userId = player.UserId
	saveTokens[userId] = (saveTokens[userId] or 0) + 1
	local token = saveTokens[userId]
	local delaySeconds = immediate and 0 or SAVE_DEBOUNCE_SECONDS

	task.delay(delaySeconds, function()
		if not player.Parent or saveTokens[userId] ~= token then
			return
		end
		local currentState = playerStates[userId]
		if not currentState then
			return
		end
		saveState(player, currentState, immediate == true)
	end)
end

local function loadStateForPlayer(player: Player)
	local state = getState(player)
	if state.Loading or state.Loaded then
		return
	end

	state.Loading = true
	local userId = player.UserId
	loadTokens[userId] = (loadTokens[userId] or 0) + 1
	local token = loadTokens[userId]

	task.spawn(function()
		if RunService:IsStudio() then
			state.RP = MAX_RP
			state.Unlocked = buildDefaultUnlocked()
			for techId in pairs(ResearchConfig.TechTree) do
				state.Unlocked[techId] = true
			end
			state.Current = nil
			state.LastProgressAt = os.time()
			state.Loaded = true
			state.Loading = false
			state.Dirty = false
			pushSnapshot(player, state)
			return
		end

		local identityUserId: number? = nil
		local slotNum = 0
		local createdTime = 0
		local deadline = os.clock() + LOAD_TIMEOUT_SECONDS
		while player.Parent == Players and loadTokens[userId] == token and os.clock() < deadline do
			local resolvedUserId, resolvedSlotNum, resolvedCreatedTime = resolveIdentity(player)
			if resolvedUserId and resolvedUserId > 0 then
				identityUserId = resolvedUserId
				slotNum = resolvedSlotNum or 0
				createdTime = resolvedCreatedTime or 0
				break
			end
			task.wait(0.25)
		end

		if not player.Parent or loadTokens[userId] ~= token then
			state.Loading = false
			return
		end

		if not identityUserId then
			identityUserId = player.UserId
		end

		state.StoreKey = makeStoreKey(identityUserId, slotNum, createdTime)

		local payload = nil
		if ResearchStore then
			local ok, result = pcall(function()
				return ResearchStore:GetAsync(state.StoreKey)
			end)
			if ok then
				payload = result
			else
				warn(string.format("[ResearchServer] Failed to load research data for %s: %s", player.Name, tostring(result)))
			end
		end

		local now = os.time()
		if type(payload) == "table" then
			state.RP = clampRP(tonumber(payload.RP) or START_RP)
			state.Unlocked = cloneUnlocked(payload.Unlocked)
			state.Current = sanitizeCurrent(payload.Current)
			state.LastProgressAt = math.floor(tonumber(payload.LastProgressAt) or now)
		else
			state.RP = START_RP
			state.Unlocked = buildDefaultUnlocked()
			state.Current = nil
			state.LastProgressAt = now
		end

		applyPassiveProgress(state, now)
		if finalizeCurrentResearch(state, now) then
			touchDirty(state)
		end

		state.Loaded = true
		state.Loading = false
		state.Dirty = true
		pushSnapshot(player, state)
		queueSave(player, true)
	end)
end

local function validateTechRequirements(state: ResearchState, techId: string): boolean
	local tech = ResearchConfig.TechTree[techId]
	if not tech then
		return false
	end
	if type(tech.Reqs) ~= "table" then
		return true
	end
	for _, reqId in ipairs(tech.Reqs) do
		if type(reqId) == "string" and not state.Unlocked[reqId] then
			return false
		end
	end
	return true
end

local function startResearchForPlayer(player: Player, techId: any): string
	if type(techId) ~= "string" or techId == "" then
		return "Invalid"
	end

	local state = playerStates[player.UserId]
	if not state or not state.Loaded then
		return "NotReady"
	end

	local now = os.time()
	if now - (state.LastRequestAt or 0) < RATE_LIMIT_SECONDS then
		return "RateLimited"
	end
	state.LastRequestAt = now

	maybeSyncState(player, state)

	local tech = ResearchConfig.TechTree[techId]
	if not tech then
		return "Invalid"
	end

	if state.Unlocked[techId] then
		return "AlreadyUnlocked"
	end

	if state.Current then
		return "Busy"
	end

	if not validateTechRequirements(state, techId) then
		return "Locked"
	end

	local cost = clampRP(tonumber(tech.Cost) or 0)
	if state.RP < cost then
		return "NotEnoughRP"
	end

	local duration = math.max(0, math.floor(tonumber(tech.Time) or 0))
	state.RP = clampRP(state.RP - cost)
	state.Current = {
		Id = techId,
		StartTime = now,
		EndTime = now + duration,
	}
	state.LastProgressAt = math.max(state.LastProgressAt, now)
	state.Dirty = true

	if duration <= 0 then
		state.Unlocked[techId] = true
		state.Current = nil
	end

	pushSnapshot(player, state)
	queueSave(player)
	return "Started"
end

local function requestResearchSnapshot(player: Player)
	local state = playerStates[player.UserId]
	if not state or not state.Loaded then
		return nil
	end
	maybeSyncState(player, state)
	return makeSnapshot(state)
end

ResearchUpdate.Name = "ResearchUpdate"
StartResearch.Name = "StartResearch"
GetResearchState.Name = "GetResearchState"
ResearchRequestSave.Name = "ResearchRequestSave"

StartResearch.OnServerInvoke = function(player: Player, techId: any)
	local state = playerStates[player.UserId]
	if not state then
		return "NotReady"
	end
	if not state.Loaded then
		return "NotReady"
	end
	local result = startResearchForPlayer(player, techId)
	return result
end

GetResearchState.OnServerInvoke = function(player: Player)
	return requestResearchSnapshot(player)
end

ResearchRequestSave.OnInvoke = function()
	local allOk = true
	for _, state in pairs(playerStates) do
		if state.Loaded and state.Player.Parent == Players then
			maybeSyncState(state.Player, state)
			local ok = saveState(state.Player, state, true)
			allOk = allOk and ok
		end
	end
	return allOk
end

Players.PlayerAdded:Connect(function(player)
	loadStateForPlayer(player)
end)

Players.PlayerRemoving:Connect(function(player)
	local state = playerStates[player.UserId]
	if state and state.Loaded then
		maybeSyncState(player, state)
		saveState(player, state, true)
	end
	playerStates[player.UserId] = nil
	saveTokens[player.UserId] = nil
	loadTokens[player.UserId] = nil
end)

for _, player in ipairs(Players:GetPlayers()) do
	task.spawn(function()
		loadStateForPlayer(player)
	end)
end

task.spawn(function()
	while true do
		task.wait(1)
		for _, player in ipairs(Players:GetPlayers()) do
			local state = playerStates[player.UserId]
			if state and state.Loaded then
				maybeSyncState(player, state)
			end
		end
	end
end)

task.spawn(function()
	while true do
		task.wait(ResearchConfig.AutoSaveSeconds or 45)
		for _, state in pairs(playerStates) do
			if state.Loaded and state.Dirty and state.Player.Parent == Players then
				saveState(state.Player, state, false)
			end
		end
	end
end)

game:BindToClose(function()
	for _, state in pairs(playerStates) do
		if state.Loaded and state.Player.Parent == Players then
			maybeSyncState(state.Player, state)
			saveState(state.Player, state, true)
		end
	end
	task.wait(2)
end)

print("ResearchServer Online")
end

--[=[ PATH: ServerScriptService/MainGame/GameWorld/ResearchServer | TYPE: Script ]=]--
-- ResearchServer V2: server-authoritative progression + slot-aware persistence.

local Players = game:GetService("Players")
local DataStoreService = game:GetService("DataStoreService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local RunService = game:GetService("RunService")
local MultiplayerPermissions = require(script.Parent:WaitForChild("MultiplayerPermissions"))

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

local ResearchFolder = ReplicatedStorage:FindFirstChild("Research")
if not ResearchFolder then
	ResearchFolder = Instance.new("Folder")
	ResearchFolder.Name = "Research"
	ResearchFolder.Parent = ReplicatedStorage
end

local ConfigModule = ResearchFolder:FindFirstChild("ResearchConfig") or ResearchFolder:WaitForChild("ResearchConfig", 10)
if not ConfigModule then
	ConfigModule = ReplicatedStorage:FindFirstChild("ResearchConfig") or ReplicatedStorage:WaitForChild("ResearchConfig", 10)
end
if not ConfigModule or not ConfigModule:IsA("ModuleScript") then
	return
end

local Config = require(ConfigModule)
local ResearchStoreName = Config.DataStoreName or "TycoonResearchData"
local LegacyResearchStore = DataStoreService:GetDataStore(ResearchStoreName)
local ResearchStore = if CanonicalProfile
	then CanonicalProfile.CreateSlotStoreProxy(LegacyResearchStore, ResearchStoreName, "Research")
	else LegacyResearchStore

local Events = getOrCreate(ReplicatedStorage, "Events", "Folder")
local ResearchUpdate = getOrCreate(Events, "ResearchUpdate", "RemoteEvent")
local StartResearchFunc = getOrCreate(Events, "StartResearch", "RemoteFunction")
local GetResearchStateFunc = getOrCreate(Events, "GetResearchState", "RemoteFunction")
local CheckUnlockRemote = getOrCreate(Events, "CheckUnlockClient", "RemoteFunction")
local AdminBridge = getOrCreate(Events, "AdminGiveResearch", "BindableEvent")
local AdminResearchRequest = getOrCreate(Events, "AdminResearchRequest", "BindableFunction")

local ResearchSaveBindable = Events:FindFirstChild("ResearchRequestSave")
if ResearchSaveBindable and not ResearchSaveBindable:IsA("BindableFunction") then
	ResearchSaveBindable:Destroy()
	ResearchSaveBindable = nil
end
if not ResearchSaveBindable then
	ResearchSaveBindable = Instance.new("BindableFunction")
	ResearchSaveBindable.Name = "ResearchRequestSave"
	ResearchSaveBindable.Parent = Events
end

local CheckUnlockBindable = getOrCreate(ServerStorage, "Research_CheckUnlock", "BindableFunction")
local NotificationEvent = Events:FindFirstChild("NotificationEvent")

local START_RP = math.max(0, math.floor(tonumber(Config.StartRP) or 0))
local PASSIVE_RP_PER_TICK = math.max(0, math.floor(tonumber(Config.PassiveRPPerTick) or 0))
local PASSIVE_TICK_SECONDS = math.max(1, math.floor(tonumber(Config.PassiveTickSeconds) or 5))
local OFFLINE_PROGRESS_CAP_SECONDS = math.max(PASSIVE_TICK_SECONDS, math.floor(tonumber(Config.OfflineProgressCapSeconds) or 1800))
local AUTO_SAVE_SECONDS = math.max(15, math.floor(tonumber(Config.AutoSaveSeconds) or 45))
local MAX_RP = math.max(START_RP, math.floor(tonumber(Config.MaxRP) or 250000))

local DEV_ACCESS = {
	[1090907828] = true, -- LopeRB1
	[8843215003] = true, -- AndersBrodd
	-- 	[1624020068] = true, -- Racssalor
	[389306460] = true,
	[1215727369] = true,
	-- [1306183746] = true, -- cchiliz
}

local function isSandboxResearchSession(player)
	if RunService:IsStudio() then
		return true
	end
	if typeof(player) ~= "Instance" or not player:IsA("Player") then
		return false
	end
	if player:GetAttribute("SandboxMode") == true then
		return true
	end
	local slotData = ReplicatedStorage:FindFirstChild("SlotData")
	return slotData ~= nil and slotData:GetAttribute("SandboxMode") == true
end

local TechTree = {}
for techId, rawTech in pairs(Config.TechTree or {}) do
	local reqs = {}
	if type(rawTech.Req) == "string" and rawTech.Req ~= "" then
		table.insert(reqs, rawTech.Req)
	end
	if type(rawTech.Reqs) == "table" then
		for _, req in ipairs(rawTech.Reqs) do
			if type(req) == "string" and req ~= "" then
				table.insert(reqs, req)
			end
		end
	end

	local dedup = {}
	local seen = {}
	for _, req in ipairs(reqs) do
		if not seen[req] then
			seen[req] = true
			table.insert(dedup, req)
		end
	end

	local unlocks = {}
	if type(rawTech.Unlocks) == "table" then
		for _, item in ipairs(rawTech.Unlocks) do
			if type(item) == "string" and item ~= "" then
				table.insert(unlocks, item)
			end
		end
	end

	TechTree[techId] = {
		Id = techId,
		Name = tostring(rawTech.Name or techId),
		Desc = tostring(rawTech.Desc or ""),
		Cost = math.max(0, math.floor(tonumber(rawTech.Cost) or 0)),
		Time = math.max(0, math.floor(tonumber(rawTech.Time) or 0)),
		Reqs = dedup,
		Unlocks = unlocks,
		Branch = tostring(rawTech.Branch or "General"),
		Sort = tonumber(rawTech.Sort) or 0,
	}
end

local RootNodes = {}
if type(Config.RootNodes) == "table" then
	for _, nodeId in ipairs(Config.RootNodes) do
		if type(nodeId) == "string" and TechTree[nodeId] then
			table.insert(RootNodes, nodeId)
		end
	end
end
if #RootNodes == 0 and TechTree.Basics then
	table.insert(RootNodes, "Basics")
end
if #RootNodes == 0 then
	for nodeId, tech in pairs(TechTree) do
		if #tech.Reqs == 0 then
			table.insert(RootNodes, nodeId)
		end
	end
end

local UnlockIndex = {}
for techId, tech in pairs(TechTree) do
	for _, itemName in ipairs(tech.Unlocks) do
		local list = UnlockIndex[itemName]
		if not list then
			list = {}
			UnlockIndex[itemName] = list
		end
		table.insert(list, techId)
	end
end

local ResearchBonuses = type(Config.ResearchBonuses) == "table" and Config.ResearchBonuses or {}
local DiscountAttributeByBucket = {
	Lifts = "ResearchDiscount_Lifts",
	Slopes = "ResearchDiscount_Slopes",
	Buildings = "ResearchDiscount_Buildings",
	Snow = "ResearchDiscount_Snow",
}
local DiscountCaps = {
	Lifts = 0.4,
	Slopes = 0.3,
	Buildings = 0.35,
	Snow = 0.3,
}
local MAX_INCOME_BONUS = 0.35

local function computeResearchBonusSnapshot(data)
	local snapshot = {
		Discounts = {
			Lifts = 0,
			Slopes = 0,
			Buildings = 0,
			Snow = 0,
		},
		IncomeBonus = 0,
	}

	for techId, isUnlocked in pairs(data.Unlocked or {}) do
		if isUnlocked == true then
			local bonus = ResearchBonuses[techId]
			if type(bonus) == "table" then
				if type(bonus.Discounts) == "table" then
					for bucket, amount in pairs(bonus.Discounts) do
						if snapshot.Discounts[bucket] ~= nil then
							snapshot.Discounts[bucket] += tonumber(amount) or 0
						end
					end
				end
				snapshot.IncomeBonus += tonumber(bonus.IncomeBonus) or 0
			end
		end
	end

	for bucket, cap in pairs(DiscountCaps) do
		snapshot.Discounts[bucket] = math.clamp(snapshot.Discounts[bucket] or 0, 0, cap)
	end
	snapshot.IncomeBonus = math.clamp(snapshot.IncomeBonus, 0, MAX_INCOME_BONUS)
	return snapshot
end

local function applyResearchBonusesToPlayer(player, data)
	if typeof(player) ~= "Instance" or not player:IsA("Player") or type(data) ~= "table" then
		return
	end
	local snapshot = computeResearchBonusSnapshot(data)
	for bucket, attrName in pairs(DiscountAttributeByBucket) do
		player:SetAttribute(attrName, snapshot.Discounts[bucket] or 0)
	end
	player:SetAttribute("ResearchIncomeBonus", snapshot.IncomeBonus)
end

local function applyRootUnlocks(data)
	if type(data) ~= "table" or type(data.Unlocked) ~= "table" then
		return
	end
	for _, rootId in ipairs(RootNodes) do
		data.Unlocked[rootId] = true
	end
end

local function applySandboxResearchState(player, data)
	if type(data) ~= "table" or not isSandboxResearchSession(player) then
		return false
	end
	local changed = false
	for techId in pairs(TechTree) do
		if data.Unlocked[techId] ~= true then
			data.Unlocked[techId] = true
			changed = true
		end
	end
	if data.Current ~= nil then
		data.Current = nil
		changed = true
	end
	if data.RP ~= MAX_RP then
		data.RP = MAX_RP
		changed = true
	end
	applyRootUnlocks(data)
	return changed
end

local sessionData = {} -- [userId] = data
local sessionKeyByUser = {} -- [userId] = datastore key
local dirtyUsers = {} -- [userId] = true
local saveEligibleUsers = {} -- [userId] = true if it is safe to persist this session
local lastStartRequestAt = {} -- [userId] = os.clock()
local lastReadRequestAt = {} -- [userId] = os.clock()
local loadInProgress = {} -- [userId] = true while research state is being loaded
local snapshotRevisionByUser = {} -- [userId] = monotonically increasing snapshot revision

local function isFiniteNumber(value)
	return type(value) == "number" and value == value and value > -math.huge and value < math.huge
end

local function clampRP(value)
	if not isFiniteNumber(value) then
		return START_RP
	end
	value = math.floor(value)
	if value < 0 then
		return 0
	end
	if value > MAX_RP then
		return MAX_RP
	end
	return value
end

local function copyUnlockedMap(unlocked)
	local out = {}
	for techId, isUnlocked in pairs(unlocked) do
		if isUnlocked == true then
			out[techId] = true
		end
	end
	return out
end

local function copyCurrent(current)
	if not current then
		return nil
	end
	return {
		Id = current.Id,
		StartTime = current.StartTime,
		EndTime = current.EndTime,
	}
end

local function buildClientSnapshot(data, revision)
	local snapshot = {
		RP = clampRP(data.RP),
		Unlocked = copyUnlockedMap(data.Unlocked),
		Current = copyCurrent(data.Current),
	}
	if type(revision) == "number" then
		snapshot.Revision = revision
	end
	return snapshot
end

local function markDirty(userId)
	dirtyUsers[userId] = true
end

local function getSnapshotRevision(userId)
	return snapshotRevisionByUser[userId] or 0
end

local function bumpSnapshotRevision(userId)
	local nextRevision = (snapshotRevisionByUser[userId] or 0) + 1
	snapshotRevisionByUser[userId] = nextRevision
	return nextRevision
end

local function getResolvedSlotNum(player)
	for _, attributeName in ipairs({ "SlotNum", "CurrentSlot", "ActiveSlot" }) do
		local slotNum = tonumber(player:GetAttribute(attributeName))
		if slotNum and slotNum > 0 then
			return slotNum
		end
	end

	local slotData = ReplicatedStorage:FindFirstChild("SlotData")
	local slotValue = slotData and slotData:FindFirstChild("SlotNum")
	local replicatedSlotNum = slotValue and tonumber(slotValue.Value)
	if replicatedSlotNum and replicatedSlotNum > 0 then
		return replicatedSlotNum
	end

	return nil
end

local function getResearchKeysForPlayer(player)
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
			pushKey(slotKey)
		end
	end

	local slotNum = getResolvedSlotNum(player)
	if slotNum and slotNum > 0 then
		pushKey(string.format("User_%d_Slot_%d", userId, slotNum))
		pushKey(string.format("User_%d_Slot_%d_ResearchV2", userId, slotNum)) -- migration from earlier prototype keys
	end

	pushKey(string.format("User_%d_DefaultSlot", userId))
	pushKey(string.format("User_%d_Default_ResearchV2", userId))

	if #keys == 0 then
		pushKey(string.format("User_%d_DefaultSlot", userId))
	end

	return keys
end

local function makeDefaultData()
	local data = {
		Version = tonumber(Config.SchemaVersion) or 1,
		RP = START_RP,
		Unlocked = {},
		Current = nil,
		LastTick = os.time(),
		LastSeen = os.time(),
	}
	applyRootUnlocks(data)
	return data
end

local function sanitizeLoadedData(raw)
	local data = makeDefaultData()
	if type(raw) ~= "table" then
		return data
	end

	data.Version = tonumber(raw.Version) or data.Version
	data.RP = clampRP(raw.RP)

	if type(raw.Unlocked) == "table" then
		data.Unlocked = {}
		for techId, isUnlocked in pairs(raw.Unlocked) do
			if TechTree[techId] and isUnlocked == true then
				data.Unlocked[techId] = true
			end
		end
	end

	if type(raw.Current) == "table" then
		local currentId = raw.Current.Id
		local endTime = tonumber(raw.Current.EndTime)
		local startTime = tonumber(raw.Current.StartTime) or os.time()
		if type(currentId) == "string" and TechTree[currentId] and endTime and endTime > 0 then
			data.Current = {
				Id = currentId,
				StartTime = startTime,
				EndTime = math.floor(endTime),
			}
		end
	end

	data.LastTick = math.floor(tonumber(raw.LastTick) or os.time())
	data.LastSeen = math.floor(tonumber(raw.LastSeen) or os.time())
	applyRootUnlocks(data)

	return data
end

local function areReqsUnlocked(data, tech)
	for _, reqId in ipairs(tech.Reqs) do
		if not data.Unlocked[reqId] then
			return false
		end
	end
	return true
end

local function completeResearch(data, techId)
	data.Unlocked[techId] = true
	data.Current = nil
	applyRootUnlocks(data)
end

local function applyOfflineProgress(data, now)
	local changed = false
	local completedTechId = nil

	if data.Current then
		if now >= data.Current.EndTime then
			completedTechId = data.Current.Id
			completeResearch(data, data.Current.Id)
			changed = true
		end
	end

	local lastTick = tonumber(data.LastTick) or now
	if lastTick > now then
		lastTick = now
	end
	local rawElapsed = now - lastTick
	local elapsed = math.min(rawElapsed, OFFLINE_PROGRESS_CAP_SECONDS)
	if elapsed >= PASSIVE_TICK_SECONDS then
		local ticks = math.floor(elapsed / PASSIVE_TICK_SECONDS)
		if ticks > 0 then
			data.RP = clampRP(data.RP + (ticks * PASSIVE_RP_PER_TICK))
			-- Advance LastTick to now minus only the sub-tick remainder so the live loop
			-- doesn't re-award the uncapped portion of a long offline session.
			local remainder = elapsed - (ticks * PASSIVE_TICK_SECONDS)
			data.LastTick = now - remainder
			changed = true
		end
	else
		-- No full ticks yet; advance LastTick to now so no backlog accumulates
		data.LastTick = now
	end

	return changed, completedTechId
end

local function getResearchSubjectPlayer(player)
	local proxyPlayer = MultiplayerPermissions.GetResearchProxyPlayer(player)
	if proxyPlayer then
		return proxyPlayer
	end
	return player
end

local function sendUpdate(player)
	local subjectPlayer = getResearchSubjectPlayer(player)
	local data = sessionData[subjectPlayer.UserId]
	if not data then
		return
	end
	local revision = bumpSnapshotRevision(subjectPlayer.UserId)
	ResearchUpdate:FireClient(player, buildClientSnapshot(data, revision))
end

local function sendUpdateToResearchViewers(subjectPlayer)
	sendUpdate(subjectPlayer)
	for _, otherPlayer in ipairs(Players:GetPlayers()) do
		if otherPlayer ~= subjectPlayer and getResearchSubjectPlayer(otherPlayer) == subjectPlayer then
			sendUpdate(otherPlayer)
		end
	end
end

local function savePlayerById(userId)
	if saveEligibleUsers[userId] ~= true then
		return false
	end

	local data = sessionData[userId]
	local key = sessionKeyByUser[userId]
	if not data or not key then
		return false
	end

	local payload = {
		Version = tonumber(Config.SchemaVersion) or data.Version or 1,
		RP = clampRP(data.RP),
		Unlocked = copyUnlockedMap(data.Unlocked),
		Current = copyCurrent(data.Current),
		LastTick = math.floor(tonumber(data.LastTick) or os.time()),
		LastSeen = os.time(),
	}

	local ok, err = pcall(function()
		ResearchStore:UpdateAsync(key, function()
			return payload
		end)
	end)

	if ok then
		dirtyUsers[userId] = nil
		return true
	end

	warn(string.format("[ResearchServer] Save failed for user %s key %s: %s", tostring(userId), tostring(key), tostring(err)))
	return false
end

local function savePlayer(player)
	savePlayerById(player.UserId)
end

ResearchSaveBindable.OnInvoke = function(targetUserId)
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

local function trySendCompleteNotification(player, techId, sourceTag)
	if not NotificationEvent or not NotificationEvent:IsA("RemoteEvent") then
		return
	end
	local tech = TechTree[techId]
	if not tech then
		return
	end
	NotificationEvent:FireClient(
		player,
		"Positive",
		"RESEARCH COMPLETE",
		string.format("%s (%s)", tech.Name, sourceTag),
		5
	)
end

local function isItemUnlocked(player, itemName)
	if RunService:IsStudio() then
		return true
	end
	local subjectPlayer = getResearchSubjectPlayer(player)
	local data = sessionData[subjectPlayer.UserId]
	if not data then
		return false
	end

	local techIds = UnlockIndex[itemName]
	if not techIds then
		return true
	end

	for _, techId in ipairs(techIds) do
		if data.Unlocked[techId] then
			return true
		end
	end

	return false
end

local function waitForSlotSelection(player, timeoutSeconds)
	local timeoutAt = os.clock() + (timeoutSeconds or 15)
	while player.Parent and os.clock() < timeoutAt do
		local slotNum = getResolvedSlotNum(player)
		if slotNum and slotNum > 0 then
			return slotNum
		end
		task.wait(0.2)


	end
	return getResolvedSlotNum(player)
end

local function loadPlayer(player)
	local userId = player.UserId
	if loadInProgress[userId] then
		return sessionData[userId]
	end
	loadInProgress[userId] = true

	if RunService:IsStudio() then
		local data = makeDefaultData()
		applySandboxResearchState(player, data)
		data.LastSeen = os.time()
		sessionData[userId] = data
		saveEligibleUsers[userId] = false
		applyResearchBonusesToPlayer(player, data)
		sendUpdate(player)
		loadInProgress[userId] = nil
		return data
	end

	waitForSlotSelection(player, 20)

	local keys = getResearchKeysForPlayer(player)
	local primaryKey = keys[1]
	sessionKeyByUser[userId] = primaryKey

	local loaded = nil
	local loadedKey = nil
	local hadLookupError = false

	for _, key in ipairs(keys) do
		local ok, data = pcall(function()
			return ResearchStore:GetAsync(key)
		end)
		if not ok then
			hadLookupError = true
		elseif data ~= nil then
			loaded = data
			loadedKey = key
			break
		end
	end

	local data = sanitizeLoadedData(loaded)
	local now = os.time()
	local changed, completedTech = applyOfflineProgress(data, now)

	if DEV_ACCESS[userId] then
		data.RP = MAX_RP
		for techId, _ in pairs(TechTree) do
			data.Unlocked[techId] = true
		end
		data.Current = nil
		changed = true
	end
	if applySandboxResearchState(player, data) then
		changed = true
	end

	data.LastSeen = now
	sessionData[userId] = data
	applyResearchBonusesToPlayer(player, data)

	local saveEligible = not (hadLookupError and loaded == nil)
	saveEligibleUsers[userId] = saveEligible
	if not saveEligible then
		warn(string.format("[ResearchServer] Blocking research saves for user %s because datastore reads failed and no safe snapshot was not loaded.", tostring(userId)))
	end

	if loadedKey and loadedKey ~= primaryKey then
		changed = true -- migrate legacy key to primary key on next save
	end
	if saveEligible and (loaded == nil or changed) then
		markDirty(userId)
	end

	sendUpdate(player)

	if completedTech then
		trySendCompleteNotification(player, completedTech, "offline")
	end

	loadInProgress[userId] = nil
	return data
end

local function canStartResearchNow(userId)
	local nowClock = os.clock()
	local last = lastStartRequestAt[userId] or 0
	if nowClock - last < 0.2 then
		return false
	end
	lastStartRequestAt[userId] = nowClock
	return true
end

local function canReadResearchNow(userId)
	local nowClock = os.clock()
	local last = lastReadRequestAt[userId] or 0
	lastReadRequestAt[userId] = nowClock
	return (nowClock - last) >= 0.05
end

local function ensurePlayerLoaded(player, timeoutSeconds)
	local existing = sessionData[player.UserId]
	if existing then
		if applySandboxResearchState(player, existing) then
			applyResearchBonusesToPlayer(player, existing)
			markDirty(player.UserId)
			task.spawn(function()
				savePlayerById(player.UserId)
			end)
		end
		return existing
	end

	if not loadInProgress[player.UserId] then
		loadPlayer(player)
	end

	local timeoutAt = os.clock() + (timeoutSeconds or 3)
	while player.Parent and os.clock() < timeoutAt do
		existing = sessionData[player.UserId]
		if existing then
			if applySandboxResearchState(player, existing) then
				applyResearchBonusesToPlayer(player, existing)
				markDirty(player.UserId)
				task.spawn(function()
					savePlayerById(player.UserId)
				end)
			end
			return existing
		end
		task.wait(0.1)
	end

	return sessionData[player.UserId]
end

CheckUnlockBindable.OnInvoke = function(player, itemName)
	if typeof(player) ~= "Instance" or not player:IsA("Player") then
		return false
	end
	if type(itemName) ~= "string" or itemName == "" then
		return false
	end
	ensurePlayerLoaded(player, 2)
	return isItemUnlocked(player, itemName)
end

CheckUnlockRemote.OnServerInvoke = function(player, itemName)
	canReadResearchNow(player.UserId)
	if type(itemName) ~= "string" or itemName == "" then
		return false
	end
	ensurePlayerLoaded(player, 2)
	return isItemUnlocked(player, itemName)
end

GetResearchStateFunc.OnServerInvoke = function(player)
	canReadResearchNow(player.UserId)
	local subjectPlayer = getResearchSubjectPlayer(player)
	local data = ensurePlayerLoaded(subjectPlayer, 2)
	if not data then
		return nil
	end
	return buildClientSnapshot(data, getSnapshotRevision(subjectPlayer.UserId))
end

StartResearchFunc.OnServerInvoke = function(player, techId)
	if type(techId) ~= "string" or techId == "" then
		return "Invalid"
	end
	if not canStartResearchNow(player.UserId) then
		return "RateLimited"
	end

	local subjectPlayer = getResearchSubjectPlayer(player)
	local data = ensurePlayerLoaded(subjectPlayer, 2)
	if not data then
		return "NotReady"
	end

	local tech = TechTree[techId]
	if not tech then
		return "Invalid"
	end

	if data.Unlocked[techId] then
		return "Unlocked"
	end

	if data.Current then
		return "Busy"
	end

	if not areReqsUnlocked(data, tech) then
		return "Locked"
	end

	if data.RP < tech.Cost then
		return "Poor"
	end

	data.RP = clampRP(data.RP - tech.Cost)

	if tech.Time <= 0 then
		completeResearch(data, techId)
		trySendCompleteNotification(player, techId, "instant")
		if subjectPlayer ~= player then
			trySendCompleteNotification(subjectPlayer, techId, "instant")
		end
	else
		local now = os.time()
		data.Current = {
			Id = techId,
			StartTime = now,
			EndTime = now + tech.Time,
		}
	end

	applyResearchBonusesToPlayer(subjectPlayer, data)
	markDirty(subjectPlayer.UserId)
	sendUpdateToResearchViewers(subjectPlayer)
	task.spawn(function()
		savePlayerById(subjectPlayer.UserId)
	end)
	return "Started"
end

local function adminUnlockResearch(targetPlayer, techId)
	if typeof(targetPlayer) ~= "Instance" or not targetPlayer:IsA("Player") then
		return false, "InvalidTarget"
	end
	if type(techId) ~= "string" or not TechTree[techId] then
		return false, "InvalidTech"
	end

	local data = ensurePlayerLoaded(targetPlayer, 2)
	if not data then
		return false, "NotReady"
	end

	data.Unlocked[techId] = true
	if data.Current and data.Current.Id == techId then
		data.Current = nil
	end
	applyRootUnlocks(data)
	applyResearchBonusesToPlayer(targetPlayer, data)
	markDirty(targetPlayer.UserId)
	sendUpdateToResearchViewers(targetPlayer)
	if NotificationEvent and NotificationEvent:IsA("RemoteEvent") then
		NotificationEvent:FireClient(targetPlayer, "Positive", "ADMIN UNLOCK", TechTree[techId].Name, 4)
	end
	return true, nil
end

AdminBridge.Event:Connect(function(targetPlayer, techId)
	adminUnlockResearch(targetPlayer, techId)
end)

AdminResearchRequest.OnInvoke = function(targetPlayer, action)
	if typeof(targetPlayer) ~= "Instance" or not targetPlayer:IsA("Player") then
		return false, "InvalidTarget"
	end
	local data = ensurePlayerLoaded(targetPlayer, 2)
	if not data then
		return false, "NotReady"
	end
	if action == "UnlockAll" then
		for techId in pairs(TechTree) do
			data.Unlocked[techId] = true
		end
		data.Current = nil
		data.RP = MAX_RP
		applyRootUnlocks(data)
		applyResearchBonusesToPlayer(targetPlayer, data)
		markDirty(targetPlayer.UserId)
		sendUpdateToResearchViewers(targetPlayer)
		if NotificationEvent and NotificationEvent:IsA("RemoteEvent") then
			NotificationEvent:FireClient(targetPlayer, "Positive", "ADMIN RESEARCH", "All research unlocked", 4)
		end
		task.spawn(function()
			savePlayerById(targetPlayer.UserId)
		end)
		return true, nil
	elseif action == "MaxRP" then
		data.RP = MAX_RP
		markDirty(targetPlayer.UserId)
		sendUpdateToResearchViewers(targetPlayer)
		task.spawn(function()
			savePlayerById(targetPlayer.UserId)
		end)
		if NotificationEvent and NotificationEvent:IsA("RemoteEvent") then
			NotificationEvent:FireClient(targetPlayer, "Positive", "ADMIN RESEARCH", "Research Points filled", 4)
		end
		return true, nil
	end
	return false, "UnknownAction"
end

task.spawn(function()
	while true do
		task.wait(1)
		local now = os.time()
		for userId, data in pairs(sessionData) do
			local changed = false
			local completedTechId = nil

			if data.Current and now >= data.Current.EndTime then
				completedTechId = data.Current.Id
				completeResearch(data, data.Current.Id)
				changed = true
			end

			local lastTick = tonumber(data.LastTick) or now
			if lastTick > now then
				lastTick = now
			end
			-- Cap elapsed to OFFLINE_PROGRESS_CAP_SECONDS as a safety net against
			-- time-skip exploitation or missed offline-progress capping.
			local elapsed = math.min(now - lastTick, OFFLINE_PROGRESS_CAP_SECONDS)
			if elapsed >= PASSIVE_TICK_SECONDS then
				local ticks = math.floor(elapsed / PASSIVE_TICK_SECONDS)
				if ticks > 0 then
					local rpGain = ticks * PASSIVE_RP_PER_TICK
					-- Boosts: ad + code passive RP multipliers
					local player = Players:GetPlayerByUserId(userId)
					if player and player:GetAttribute("AdResearchBoostActive") == true then
						rpGain = rpGain * 2
					end
					if player and player:GetAttribute("CodeResearchBoostActive") == true then
						local codeResearchMult = tonumber(player:GetAttribute("CodeResearchBoostMultiplier")) or 2
						rpGain = rpGain * math.max(1, codeResearchMult)
					end
					data.RP = clampRP(data.RP + rpGain)
					data.LastTick = lastTick + (ticks * PASSIVE_TICK_SECONDS)
					changed = true
				end
			else
				data.LastTick = lastTick
			end

			-- Consume PendingRPGrant from dev product purchases (set by AdBoostServer)
			local player = Players:GetPlayerByUserId(userId)
			if player then
				local pendingRP = tonumber(player:GetAttribute("PendingRPGrant")) or 0
				if pendingRP > 0 then
					data.RP = clampRP(data.RP + pendingRP)
					player:SetAttribute("PendingRPGrant", nil)
					changed = true
				end
			end

			if changed then
				markDirty(userId)
				if not player then
					player = Players:GetPlayerByUserId(userId)
				end
				if player then
					applyResearchBonusesToPlayer(player, data)
					sendUpdate(player)
					if completedTechId then
						trySendCompleteNotification(player, completedTechId, "live")
					end
				end
			end
		end
	end
end)

task.spawn(function()
	task.wait(math.max(20, math.floor(AUTO_SAVE_SECONDS * 0.4)))
	while true do
		task.wait(AUTO_SAVE_SECONDS)
		if _G.CoordinatedSaveInProgress ~= true then
			for userId, _ in pairs(dirtyUsers) do
				savePlayerById(userId)
			end
		end
	end
end)

local function initPlayer(player)
	player:GetAttributeChangedSignal("SandboxMode"):Connect(function()
		local data = sessionData[player.UserId]
		if data and applySandboxResearchState(player, data) then
			applyResearchBonusesToPlayer(player, data)
			markDirty(player.UserId)
			sendUpdateToResearchViewers(player)
			task.spawn(function()
				savePlayerById(player.UserId)
			end)
		end
	end)
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
		savePlayer(player)
	end
	local userId = player.UserId
	sessionData[userId] = nil
	sessionKeyByUser[userId] = nil
	dirtyUsers[userId] = nil
	saveEligibleUsers[userId] = nil
	lastStartRequestAt[userId] = nil
	lastReadRequestAt[userId] = nil
	loadInProgress[userId] = nil
	snapshotRevisionByUser[userId] = nil
end)

game:BindToClose(function()
	if shouldSkipStandaloneSave() then
		return
	end
	for _, player in ipairs(Players:GetPlayers()) do
		savePlayer(player)
	end
end)
