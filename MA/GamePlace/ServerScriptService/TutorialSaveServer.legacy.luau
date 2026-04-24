-- TutorialSaveServer
-- Single source of truth for tutorial progression.
-- Keeps tutorial state per save slot so only TutorialController + this script own the flow.

local Players = game:GetService("Players")
local DataStoreService = game:GetService("DataStoreService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local SLIDE_COUNT = 9
local LOAD_TIMEOUT = 20
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

local LegacyTutorialStore = DataStoreService:GetDataStore("TutorialProgress_V1")
local TutorialStore = if CanonicalProfile
	then CanonicalProfile.CreateSlotStoreProxy(LegacyTutorialStore, "TutorialProgress_V1", "Tutorial")
	else LegacyTutorialStore
local SessionStates = {}

local Events = ReplicatedStorage:WaitForChild("Events")

local SaveTutorialSlide = Events:FindFirstChild("SaveTutorialSlide")
if not SaveTutorialSlide then
	SaveTutorialSlide = Instance.new("RemoteEvent")
	SaveTutorialSlide.Name = "SaveTutorialSlide"
	SaveTutorialSlide.Parent = Events
end

local GetTutorialSlide = Events:FindFirstChild("GetTutorialSlide")
if not GetTutorialSlide then
	GetTutorialSlide = Instance.new("RemoteFunction")
	GetTutorialSlide.Name = "GetTutorialSlide"
	GetTutorialSlide.Parent = Events
end

local AdvanceTutorial = Events:FindFirstChild("AdvanceTutorial")
if not AdvanceTutorial then
	AdvanceTutorial = Instance.new("RemoteEvent")
	AdvanceTutorial.Name = "AdvanceTutorial"
	AdvanceTutorial.Parent = Events
end

local function clampSlide(value)
	return math.clamp(math.floor(tonumber(value) or 1), 1, SLIDE_COUNT)
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

local function waitForSlot(player, timeoutSeconds)
	local startedAt = os.clock()
	local slotNum = getResolvedSlotNum(player)
	while player.Parent == Players and slotNum == nil and (os.clock() - startedAt) < (timeoutSeconds or LOAD_TIMEOUT) do
		task.wait(0.25)
		slotNum = getResolvedSlotNum(player)
	end
	return slotNum
end

local function getKey(player, slotNum)
	return string.format("tutorial_%s_slot_%s", tostring(player.UserId), tostring(slotNum))
end

local function normalizeState(raw)
	local state = {
		Stage = 1,
		Completed = false,
		Skipped = false,
	}

	if type(raw) == "number" then
		state.Stage = clampSlide(raw)
		return state
	end

	if type(raw) == "table" then
		state.Stage = clampSlide(raw.Stage or raw.Slide or raw.CurrentSlide or 1)
		state.Completed = raw.Completed == true
		state.Skipped = raw.Skipped == true
		if state.Completed or state.Skipped then
			state.Stage = SLIDE_COUNT
		end
	end

	return state
end

local function setTutorialStateReady(player, ready)
	player:SetAttribute("TutorialStateReady", ready == true)
end

local function applyState(player, state)
	player:SetAttribute("TutorialStage", state.Stage)
	player:SetAttribute("TutorialCompleted", state.Completed)
	player:SetAttribute("TutorialSkipped", state.Skipped)
	setTutorialStateReady(player, true)
end

local function readState(player)
	local slotNum = waitForSlot(player)
	if not slotNum then
		local fallback = {Stage = 1, Completed = false, Skipped = false}
		SessionStates[player] = fallback
		applyState(player, fallback)
		return fallback, nil
	end

	local key = getKey(player, slotNum)
	local ok, result = pcall(function()
		return TutorialStore:GetAsync(key)
	end)

	local state = normalizeState(ok and result or nil)
	state.PendingPersist = nil
	SessionStates[player] = state
	applyState(player, state)
	return state, key
end

local function writeState(player, state)
	local slotNum = waitForSlot(player, 5)
	if not slotNum then
		state.PendingPersist = true
		SessionStates[player] = state
		applyState(player, state)
		return false
	end

	local key = getKey(player, slotNum)
	SessionStates[player] = state
	applyState(player, state)

	local ok, err = pcall(function()
		TutorialStore:SetAsync(key, {
			Stage = clampSlide(state.Stage),
			Completed = state.Completed == true,
			Skipped = state.Skipped == true,
		})
	end)

	if not ok then
		warn(string.format("[TutorialSaveServer] Failed to save tutorial state for %s: %s", player.Name, tostring(err)))
	end

	return ok
end

local function getSessionState(player)
	local existing = SessionStates[player]
	if existing then
		return existing
	end
	local state = readState(player)
	return state
end

SaveTutorialSlide.OnServerEvent:Connect(function(player, slideNumber)
	if type(slideNumber) ~= "number" then
		return
	end

	local state = getSessionState(player)
	if state.Completed or state.Skipped then
		return
	end

	state.Stage = clampSlide(slideNumber)
	writeState(player, state)
end)

GetTutorialSlide.OnServerInvoke = function(player)
	local state = getSessionState(player)
	return clampSlide(state.Stage)
end

AdvanceTutorial.OnServerEvent:Connect(function(player, action, value)
	if type(action) ~= "string" then
		return
	end

	local state = getSessionState(player)

	if action == "Skip" then
		state.Stage = SLIDE_COUNT
		state.Skipped = true
		state.Completed = true
		writeState(player, state)
		return
	end

	if action == "Complete" then
		state.Stage = SLIDE_COUNT
		state.Completed = true
		state.Skipped = false
		writeState(player, state)
		return
	end

	if action == "Advance" then
		state.Stage = clampSlide(value)
		writeState(player, state)
	end
end)

local function hookPlayer(player)
	setTutorialStateReady(player, false)

	local function syncTutorialStateForResolvedSlot()
		local existing = SessionStates[player]
		if existing and existing.PendingPersist then
			writeState(player, existing)
			return
		end
		SessionStates[player] = nil
		readState(player)
	end

	task.spawn(syncTutorialStateForResolvedSlot)

	for _, attributeName in ipairs({ "SlotNum", "CurrentSlot", "ActiveSlot" }) do
		player:GetAttributeChangedSignal(attributeName):Connect(function()
			task.spawn(syncTutorialStateForResolvedSlot)
		end)
	end
end

Players.PlayerAdded:Connect(hookPlayer)

Players.PlayerRemoving:Connect(function(player)
	SessionStates[player] = nil
end)

for _, player in ipairs(Players:GetPlayers()) do
	task.spawn(hookPlayer, player)
end
