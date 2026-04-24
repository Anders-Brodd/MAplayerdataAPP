--[[
Script: SlotDataLoader
Description: Manages the loading, restoring, and saving of player slot data upon entering the main game place. Handles DataStore retrieval, setting synchronization, character loading locks, and world generation initialization based on teleport data received from the lobby.
Old Features: Handled character loading locks, data saving, delayed world restoration waiting for terrain and building scripts to be ready, and initialization of player slot variables. Provided fallback loading for studio. Managed deleted trees. Included emojis in console logs and client updates.
Added/Removed: Removed all emojis from console prints, warnings, and client update messages to comply with strict logging rules. Added extensive data extraction inside InitializePlayer to fully capture and process the TeleportData payload from the lobby, including ResortName, SandboxMode, and Timestamp. Added detailed, concise console logging for data parsing and state transitions. Maintained all existing datastore names, functionality, and connection logic. No features were simplified or removed.
]]

-- SlotDataLoader V4.0 - TeleportData Integration & Strict Logging
-- ServerScriptService (MainGame)

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local DataStoreService = game:GetService("DataStoreService")
local RunService = game:GetService("RunService")
local HttpService = game:GetService("HttpService")
local Lighting = game:GetService("Lighting")

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

-- // CONFIGURATION //
local DATA_STORE_VERSION = "TycoonGameData"
local PLAYER_WAYPOINT_STORE_VERSION = "TycoonWaypointPreferences_v1"
local LegacyGameStore = DataStoreService:GetDataStore(DATA_STORE_VERSION)
local LegacyPlayerWaypointStore = DataStoreService:GetDataStore(PLAYER_WAYPOINT_STORE_VERSION)
local GameStore = if CanonicalProfile
	then CanonicalProfile.CreateSlotStoreProxy(LegacyGameStore, DATA_STORE_VERSION, "GameData")
	else LegacyGameStore
local PlayerWaypointStore = if CanonicalProfile
	then CanonicalProfile.CreateUserStoreProxy(LegacyPlayerWaypointStore, PLAYER_WAYPOINT_STORE_VERSION, "WaypointPreferences")
	else LegacyPlayerWaypointStore
local COMPENSATION_STORE_VERSION = "GlobalCompensationClaims_v1"
local CompensationStore = DataStoreService:GetDataStore(COMPENSATION_STORE_VERSION)
local BACKUP_STORE_VERSION = "TycoonGameDataBackups_v1"
local BackupStore = DataStoreService:GetDataStore(BACKUP_STORE_VERSION)
local DATA_LOSS_GRANT_ID = "Mar2026_DataLoss_3M_v2"
-- Roblox DataStore keys are max 50 chars; claim keys must NOT embed the full grant id string.
local COMPENSATION_DS_KEY_TAG = "M26"
local DATA_LOSS_GRANT_AMOUNT = 0  -- Disabled: compensation period ended
local DATA_LOSS_COMPENSATION_CREATED_BEFORE = DateTime.fromUniversalTime(2026, 3, 21, 0, 0, 0).UnixTimestamp
local COMPENSATION_MODAL_TITLE = "$1,000,000 COMPENSATION"
local COMPENSATION_MODAL_MESSAGE = "Sorry for the money-loss issues. Existing affected saves receive $1,000,000 in compensation. New saves are not eligible."
local ZERO_BALANCE_OVERWRITE_GUARD_MIN = 1000
local SUSPICIOUS_ZERO_RESTORE_MIN_OBJECTS = 3

local ACTIVE_GAME_DATA_KEY = nil
local ALLOW_SLOT_SAVES = false

local AUTOSAVE_INTERVAL = 120

-- Toggle this to false to simulate live game environment in Studio
local ENABLE_STUDIO_MODE = true
local IS_STUDIO = RunService:IsStudio() and ENABLE_STUDIO_MODE
-- In Studio, default to slot 1 unless overridden via ServerScriptService attribute "StudioTestSlot".
local STUDIO_TEST_SLOT = math.max(1, math.floor(tonumber(ServerScriptService:GetAttribute("StudioTestSlot")) or 1))
local MAX_SAVE_SLOT_INDEX = 8
local DEFAULT_STARTING_MONEY = 125000
local SANDBOX_STARTING_MONEY = 999999999
local DEFAULT_STARTING_TICKETS = 10
local HIGH_BALANCE_EMPTY_SAVE_WARNING = 5000000

local HANDLE_BUILDINGS = false 

-- // REFERENCES //
local Events = ReplicatedStorage:WaitForChild("Events")
local LoadingUpdate = Events:FindFirstChild("LoadingUpdate") or Instance.new("RemoteEvent", Events)
LoadingUpdate.Name = "LoadingUpdate"

local WipeBuildingEvent = Events:FindFirstChild("WipeBuildingStore") or Instance.new("BindableEvent", Events)
WipeBuildingEvent.Name = "WipeBuildingStore"

local RequestSave = Events:FindFirstChild("RequestSave") or Instance.new("BindableFunction", Events)
RequestSave.Name = "RequestSave"

local AdminRefreshWorld = Events:FindFirstChild("AdminRefreshWorld")
if AdminRefreshWorld and not AdminRefreshWorld:IsA("BindableFunction") then
	AdminRefreshWorld:Destroy()
	AdminRefreshWorld = nil
end
if not AdminRefreshWorld then
	AdminRefreshWorld = Instance.new("BindableFunction")
	AdminRefreshWorld.Name = "AdminRefreshWorld"
	AdminRefreshWorld.Parent = Events
end

local NotificationEvent = Events:FindFirstChild("NotificationEvent")
if NotificationEvent and not NotificationEvent:IsA("RemoteEvent") then
	NotificationEvent:Destroy()
	NotificationEvent = nil
end
if not NotificationEvent then
	NotificationEvent = Instance.new("RemoteEvent")
	NotificationEvent.Name = "NotificationEvent"
	NotificationEvent.Parent = Events
end

local CompensationModalEvent = Events:FindFirstChild("CompensationModalEvent")
if CompensationModalEvent and not CompensationModalEvent:IsA("RemoteEvent") then
	CompensationModalEvent:Destroy()
	CompensationModalEvent = nil
end
if not CompensationModalEvent then
	CompensationModalEvent = Instance.new("RemoteEvent")
	CompensationModalEvent.Name = "CompensationModalEvent"
	CompensationModalEvent.Parent = Events
end

local CompensationModalAck = Events:FindFirstChild("CompensationModalAck")
if CompensationModalAck and not CompensationModalAck:IsA("RemoteEvent") then
	CompensationModalAck:Destroy()
	CompensationModalAck = nil
end
if not CompensationModalAck then
	CompensationModalAck = Instance.new("RemoteEvent")
	CompensationModalAck.Name = "CompensationModalAck"
	CompensationModalAck.Parent = Events
end

local SlotDataValue = ReplicatedStorage:FindFirstChild("SlotData") or Instance.new("Folder", ReplicatedStorage)
SlotDataValue.Name = "SlotData"

local function ensureIntChild(folder, name, defaultNum)
	local fallback = math.floor((tonumber(defaultNum) or 0) + 0.5)
	local existing = folder:FindFirstChild(name)
	if existing and not existing:IsA("IntValue") then
		warn(string.format("[SlotDataLoader] Replacing %s (%s) with IntValue for session identity.", name, existing.ClassName))
		existing:Destroy()
		existing = nil
	end
	if not existing then
		local v = Instance.new("IntValue")
		v.Name = name
		v.Value = fallback
		v.Parent = folder
		return v
	end
	return existing
end

local UserIdValue = ensureIntChild(SlotDataValue, "UserId", 0)
local SlotNumValue = ensureIntChild(SlotDataValue, "SlotNum", 0)

local ResortNameValue = SlotDataValue:FindFirstChild("ResortName") or Instance.new("StringValue", SlotDataValue)
ResortNameValue.Name = "ResortName"

local TrustedUserIdsValue = SlotDataValue:FindFirstChild("TrustedUserIdsJson") or Instance.new("StringValue", SlotDataValue)
TrustedUserIdsValue.Name = "TrustedUserIdsJson"
TrustedUserIdsValue.Value = TrustedUserIdsValue.Value ~= "" and TrustedUserIdsValue.Value or "[]"
SlotDataValue:SetAttribute("FreshSave", SlotDataValue:GetAttribute("FreshSave") == true)
SlotDataValue:SetAttribute("CompensationEligible", SlotDataValue:GetAttribute("CompensationEligible") == true)

local SlotCreatedTime = ensureIntChild(SlotDataValue, "CreatedTime", 0)

-- Always start each server with an unclaimed session identity.
-- This prevents stale/baked values from forcing players into a false "Joining Session" path.
UserIdValue.Value = 0
SlotNumValue.Value = 0
SlotCreatedTime.Value = 0
SlotDataValue:SetAttribute("CompensationEligible", false)

local PreferenceRemote = Events:FindFirstChild("PlayerPreferenceSync")
if PreferenceRemote and not PreferenceRemote:IsA("RemoteFunction") then
	PreferenceRemote:Destroy()
	PreferenceRemote = nil
end
if not PreferenceRemote then
	PreferenceRemote = Instance.new("RemoteFunction")
	PreferenceRemote.Name = "PlayerPreferenceSync"
	PreferenceRemote.Parent = Events
end

local ApplySavedTicketPricing = Events:FindFirstChild("ApplySavedTicketPricing")
local GetSavedTicketPricing = Events:FindFirstChild("GetSavedTicketPricing")

local SETTINGS_DEFAULTS = {
	Music = true,
	Weather = true,
	Shadows = true,
	Particles = true,
	GraphicsPreset = "Medium",
	BuildingRenderDistance = "Medium",
	LiftRenderDistance = "Medium",
	NPCRenderDistance = "Medium",
	WeatherQuality = "High",
	ParticleQuality = "High",
	ParticleDensity = "Medium",
	RealisticParticles = true,
	AdaptiveParticles = true,
	FogEdgeBlend = true,
	FogEdgeIntensity = "Medium",
	Trees = true,
	GuestModels = true,
	GuestLOD = true,
	GuestPerformanceMode = "Off",
	Atmosphere = true,
	SunRays = true,
	Bloom = true,
	Decorations = true,
	SlopeDifficulty = false,
	FPSCounter = false,
	ShowMobileSkiButton = true,
	UnitSystem = "Imperial",
	SnowGunMute = false,
	SnowGunPerf = false,
	MaxGuestCap = 0,
	MaxGuestCapEnabled = false,
}

local WAYPOINT_CATEGORY_DEFAULTS = {
	Spawn = true,
	Lifts = true,
	Services = true,
	Vehicles = true,
	Runs = false,
}

local MULTIPLAYER_DEFAULTS = {
	TrustedBuild = true,
	TrustedDelete = true,
	TrustedUseOwnerResearch = true,
	VisitorBuild = false,
	VisitorDelete = false,
	TrustedUserIds = {},
}

local RESORT_DEFAULTS = {
	IsOpen = true,
	AllLights = true,
	Info = "",
}

local PlayerPreferences

local function deepCopyTable(value)
	if type(value) ~= "table" then
		return value
	end
	local copy = {}
	for key, child in pairs(value) do
		copy[key] = deepCopyTable(child)
	end
	return copy
end

local function buildDefaultPlayerPreferences()
	return {
		Settings = deepCopyTable(SETTINGS_DEFAULTS),
		Waypoints = {
			MasterMarkers = true,
			ActiveWaypointId = nil,
			CategoryEnabled = deepCopyTable(WAYPOINT_CATEGORY_DEFAULTS),
		},
		Multiplayer = deepCopyTable(MULTIPLAYER_DEFAULTS),
		Resort = deepCopyTable(RESORT_DEFAULTS),
		TicketPricing = nil,
	}
end

local function sanitizeSettingValue(key, value)
	local defaultValue = SETTINGS_DEFAULTS[key]
	if defaultValue == nil then
		return nil
	end

	local expectedType = type(defaultValue)
	if expectedType == "boolean" then
		if type(value) == "boolean" then
			return value
		end
		return defaultValue
	end

	if expectedType == "string" then
		if type(value) ~= "string" then
			return defaultValue
		end
		if key == "UnitSystem" then
			return string.lower(value) == "metric" and "Metric" or "Imperial"
		end
		if key == "GraphicsPreset" or key == "WeatherQuality" or key == "ParticleQuality" or key == "ParticleDensity" then
			if value == "Low" or value == "Medium" or value == "High" or value == "Ultra" then
				return value
			end
			return defaultValue
		end
		if key == "BuildingRenderDistance" or key == "NPCRenderDistance" then
			if value == "Near" or value == "Medium" or value == "Far" or value == "Off" then
				return value
			end
			return defaultValue
		end
		if key == "LiftRenderDistance" then
			if value == "Near" or value == "Medium" or value == "Far" or value == "Off" then
				return value
			end
			return defaultValue
		end
		if key == "FogEdgeIntensity" then
			if value == "Low" or value == "Medium" or value == "High" then
				return value
			end
			return defaultValue
		end
		if key == "GuestPerformanceMode" then
			if value == "Off" or value == "Balanced" or value == "Aggressive" or value == "Extreme" then
				return value
			end
			return defaultValue
		end
		return value
	end

	if expectedType == "number" then
		local numericValue = tonumber(value)
		if numericValue == nil then
			return defaultValue
		end
		if key == "MaxGuestCap" then
			return math.clamp(math.floor(numericValue + 0.5), 0, 5000)
		end
		return math.floor(numericValue + 0.5)
	end

	return defaultValue
end

local function coerceIncomingSettingValue(key, value)
	local defaultValue = SETTINGS_DEFAULTS[key]
	if defaultValue == nil then
		return nil
	end

	local expectedType = type(defaultValue)
	if expectedType == "boolean" then
		if type(value) == "boolean" then
			return value
		end
		return nil
	end

	if expectedType == "string" then
		if type(value) == "string" then
			return sanitizeSettingValue(key, value)
		end
		return nil
	end

	if expectedType == "number" then
		if tonumber(value) ~= nil then
			return sanitizeSettingValue(key, value)
		end
		return nil
	end

	return nil
end

local function sanitizeSettingsPreferences(raw)
	local sanitized = {}
	for key in pairs(SETTINGS_DEFAULTS) do
		sanitized[key] = sanitizeSettingValue(key, raw and raw[key])
	end
	return sanitized
end

local function sanitizeWaypointPreferences(raw)
	local sanitized = {
		MasterMarkers = true,
		ActiveWaypointId = nil,
		CategoryEnabled = {},
	}
	if type(raw) == "table" then
		if type(raw.MasterMarkers) == "boolean" then
			sanitized.MasterMarkers = raw.MasterMarkers
		end
		if type(raw.ActiveWaypointId) == "string" and raw.ActiveWaypointId ~= "" then
			sanitized.ActiveWaypointId = raw.ActiveWaypointId
		end
		if type(raw.CategoryEnabled) == "table" then
			for category, defaultValue in pairs(WAYPOINT_CATEGORY_DEFAULTS) do
				local enabled = raw.CategoryEnabled[category]
				if type(enabled) == "boolean" then
					sanitized.CategoryEnabled[category] = enabled
				else
					sanitized.CategoryEnabled[category] = defaultValue
				end
			end
		else
			for category, defaultValue in pairs(WAYPOINT_CATEGORY_DEFAULTS) do
				sanitized.CategoryEnabled[category] = defaultValue
			end
		end
	else
		for category, defaultValue in pairs(WAYPOINT_CATEGORY_DEFAULTS) do
			sanitized.CategoryEnabled[category] = defaultValue
		end
	end
	return sanitized
end

local function sanitizeTrustedUserIds(raw)
	local ids = {}
	local seen = {}
	if type(raw) ~= "table" then
		return ids
	end
	for _, value in ipairs(raw) do
		local userId = tonumber(value)
		if userId and userId > 0 and not seen[userId] then
			seen[userId] = true
			table.insert(ids, userId)
		end
	end
	table.sort(ids)
	return ids
end

local function sanitizeMultiplayerPreferences(raw)
	local sanitized = deepCopyTable(MULTIPLAYER_DEFAULTS)
	if type(raw) ~= "table" then
		return sanitized
	end
	for key, defaultValue in pairs(MULTIPLAYER_DEFAULTS) do
		if key ~= "TrustedUserIds" and type(defaultValue) == "boolean" and type(raw[key]) == "boolean" then
			sanitized[key] = raw[key]
		end
	end
	sanitized.TrustedUserIds = sanitizeTrustedUserIds(raw.TrustedUserIds)
	return sanitized
end

local function sanitizeResortPreferences(raw)
	local sanitized = deepCopyTable(RESORT_DEFAULTS)
	if type(raw) ~= "table" then
		return sanitized
	end
	if type(raw.IsOpen) == "boolean" then
		sanitized.IsOpen = raw.IsOpen
	end
	if type(raw.AllLights) == "boolean" then
		sanitized.AllLights = raw.AllLights
	end
	if type(raw.Info) == "string" then
		sanitized.Info = string.sub(raw.Info, 1, 280)
	end
	return sanitized
end

local PlayerWaypointPreferences = {}
local DirtyWaypointPreferenceUsers = {}

local function getWaypointPreferenceStoreKey(userId)
	return "User_" .. tostring(userId) .. "_WaypointPreferences"
end

local function getStoredWaypointPreferencesForPlayer(player)
	if not player then
		return nil
	end
	local stored = PlayerWaypointPreferences[player.UserId]
	if stored then
		return sanitizeWaypointPreferences(stored)
	end
	return nil
end

local function setStoredWaypointPreferencesForPlayer(player, prefs)
	if not player then
		return sanitizeWaypointPreferences(prefs)
	end
	local sanitized = sanitizeWaypointPreferences(prefs)
	PlayerWaypointPreferences[player.UserId] = sanitized
	return sanitized
end

local function markWaypointPreferencesDirty(player)
	if player then
		DirtyWaypointPreferenceUsers[player.UserId] = true
	end
end

local function saveWaypointPreferencesForUserId(userId)
	local prefs = PlayerWaypointPreferences[userId]
	if not prefs then
		DirtyWaypointPreferenceUsers[userId] = nil
		return
	end
	local payload = sanitizeWaypointPreferences(prefs)
	local success, err = pcall(function()
		PlayerWaypointStore:SetAsync(getWaypointPreferenceStoreKey(userId), payload)
	end)
	if success then
		DirtyWaypointPreferenceUsers[userId] = nil
	else
	end
end

local waypointPreferenceFlushGen = {}
local WAYPOINT_PREFERENCE_SAVE_DEBOUNCE_SEC = 5

local function scheduleWaypointPreferencesFlush(userId)
	if type(userId) ~= "number" or userId <= 0 then
		return
	end
	local gen = (waypointPreferenceFlushGen[userId] or 0) + 1
	waypointPreferenceFlushGen[userId] = gen
	task.delay(WAYPOINT_PREFERENCE_SAVE_DEBOUNCE_SEC, function()
		if waypointPreferenceFlushGen[userId] ~= gen then
			return
		end
		if not DirtyWaypointPreferenceUsers[userId] then
			return
		end
		saveWaypointPreferencesForUserId(userId)
	end)
end

local function flushWaypointPreferencesNow(userId)
	if type(userId) ~= "number" or userId <= 0 then
		return
	end
	waypointPreferenceFlushGen[userId] = (waypointPreferenceFlushGen[userId] or 0) + 1
	saveWaypointPreferencesForUserId(userId)
end

local function loadWaypointPreferencesForPlayer(player)
	if not player then
		return sanitizeWaypointPreferences(nil)
	end
	local fallback = PlayerPreferences and PlayerPreferences.Waypoints or nil
	if RunService:IsStudio() then
		return setStoredWaypointPreferencesForPlayer(player, fallback)
	end
	local success, result = pcall(function()
		return PlayerWaypointStore:GetAsync(getWaypointPreferenceStoreKey(player.UserId))
	end)
	if success then
		if type(result) == "table" then
			return setStoredWaypointPreferencesForPlayer(player, result)
		end
		return setStoredWaypointPreferencesForPlayer(player, fallback)
	end
	return setStoredWaypointPreferencesForPlayer(player, fallback)
end

local function sanitizeTicketPricingPreferences(raw)
	if type(raw) ~= "table" then
		return nil
	end
	local basePrice = tonumber(raw.BasePrice or raw.basePrice)
	local currentPrice = tonumber(raw.CurrentPrice or raw.currentPrice)
	local dynamicEnabled = raw.DynamicEnabled
	if dynamicEnabled == nil then
		dynamicEnabled = raw.dynamicEnabled
	end
	if basePrice == nil and currentPrice == nil and type(dynamicEnabled) ~= "boolean" then
		return nil
	end
	return {
		BasePrice = basePrice and math.max(0, math.floor(basePrice + 0.5)) or nil,
		CurrentPrice = currentPrice and math.max(0, math.floor(currentPrice + 0.5)) or nil,
		DynamicEnabled = type(dynamicEnabled) == "boolean" and dynamicEnabled or nil,
	}
end

local function sanitizePlayerPreferences(raw)
	local defaults = buildDefaultPlayerPreferences()
	if type(raw) ~= "table" then
		return defaults
	end
	defaults.Settings = sanitizeSettingsPreferences(raw.Settings)
	defaults.Waypoints = sanitizeWaypointPreferences(raw.Waypoints)
	defaults.Multiplayer = sanitizeMultiplayerPreferences(raw.Multiplayer)
	defaults.Resort = sanitizeResortPreferences(raw.Resort)
	defaults.TicketPricing = sanitizeTicketPricingPreferences(raw.TicketPricing)
	return defaults
end

PlayerPreferences = buildDefaultPlayerPreferences()

local function updateReplicatedMultiplayerState()
	local multiplayer = sanitizeMultiplayerPreferences(PlayerPreferences and PlayerPreferences.Multiplayer or nil)
	SlotDataValue:SetAttribute("Multiplayer_TrustedBuild", multiplayer.TrustedBuild)
	SlotDataValue:SetAttribute("Multiplayer_TrustedDelete", multiplayer.TrustedDelete)
	SlotDataValue:SetAttribute("Multiplayer_TrustedUseOwnerResearch", multiplayer.TrustedUseOwnerResearch)
	SlotDataValue:SetAttribute("Multiplayer_VisitorBuild", multiplayer.VisitorBuild)
	SlotDataValue:SetAttribute("Multiplayer_VisitorDelete", multiplayer.VisitorDelete)
	local jsonOk, jsonStr = pcall(function()
		return HttpService:JSONEncode(multiplayer.TrustedUserIds)
	end)
	TrustedUserIdsValue.Value = (jsonOk and type(jsonStr) == "string") and jsonStr or "[]"
end

local function updateReplicatedResortState()
	local resort = sanitizeResortPreferences(PlayerPreferences and PlayerPreferences.Resort or nil)
	SlotDataValue:SetAttribute("ResortOpen", resort.IsOpen)
	SlotDataValue:SetAttribute("ResortAllLights", resort.AllLights)
	SlotDataValue:SetAttribute("ResortInfo", resort.Info)
end

updateReplicatedMultiplayerState()
updateReplicatedResortState()

local function getOwnerPlayer()
	if UserIdValue.Value <= 0 then
		return nil
	end
	return Players:GetPlayerByUserId(UserIdValue.Value)
end

local function setPlayerPreferencesReady(player, ready)
	if player then
		player:SetAttribute("PlayerPreferencesReady", ready == true)
	end
end

local function applyPlayerPreferencesToPlayer(player, prefs)
	if not player then
		return
	end
	local resolved = sanitizePlayerPreferences(prefs or PlayerPreferences)
	local waypointPrefs = getStoredWaypointPreferencesForPlayer(player) or resolved.Waypoints
	waypointPrefs = sanitizeWaypointPreferences(waypointPrefs)
	for key, value in pairs(resolved.Settings) do
		player:SetAttribute("Settings_" .. key, value)
	end
	player:SetAttribute("GuestCap", sanitizeSettingValue("MaxGuestCap", resolved.Settings.MaxGuestCap))
	player:SetAttribute("GuestCapEnabled", resolved.Settings.MaxGuestCapEnabled == true)
	player:SetAttribute("WaypointMasterMarkers", waypointPrefs.MasterMarkers ~= false)
	player:SetAttribute("WaypointActiveId", waypointPrefs.ActiveWaypointId or "")
	for category, defaultValue in pairs(WAYPOINT_CATEGORY_DEFAULTS) do
		local enabled = waypointPrefs.CategoryEnabled[category]
		if type(enabled) ~= "boolean" then
			enabled = defaultValue
		end
		player:SetAttribute("WaypointCategory_" .. category, enabled)
	end
	setPlayerPreferencesReady(player, true)
end

local function buildPreferencesFromPlayer(player)
	local prefs = sanitizePlayerPreferences(PlayerPreferences)
	if not player then
		return prefs
	end

	for key in pairs(SETTINGS_DEFAULTS) do
		prefs.Settings[key] = sanitizeSettingValue(key, player:GetAttribute("Settings_" .. key))
	end

	prefs.Resort = sanitizeResortPreferences({
		IsOpen = SlotDataValue:GetAttribute("ResortOpen"),
		AllLights = SlotDataValue:GetAttribute("ResortAllLights"),
		Info = SlotDataValue:GetAttribute("ResortInfo"),
	})

	local masterMarkers = player:GetAttribute("WaypointMasterMarkers")
	if type(masterMarkers) == "boolean" then
		prefs.Waypoints.MasterMarkers = masterMarkers
	end

	local activeWaypointId = player:GetAttribute("WaypointActiveId")
	if type(activeWaypointId) == "string" and activeWaypointId ~= "" then
		prefs.Waypoints.ActiveWaypointId = activeWaypointId
	else
		prefs.Waypoints.ActiveWaypointId = nil
	end

	for category, defaultValue in pairs(WAYPOINT_CATEGORY_DEFAULTS) do
		local enabled = player:GetAttribute("WaypointCategory_" .. category)
		prefs.Waypoints.CategoryEnabled[category] = type(enabled) == "boolean" and enabled or defaultValue
	end

	local getSavedTicketPricing = Events:FindFirstChild("GetSavedTicketPricing")
	if getSavedTicketPricing and getSavedTicketPricing:IsA("BindableFunction") then
		local ok, result = pcall(function()
			return getSavedTicketPricing:Invoke(player)
		end)
		if ok then
			prefs.TicketPricing = sanitizeTicketPricingPreferences(result)
		end
	end

	return sanitizePlayerPreferences(prefs)
end

local function setStoredPlayerPreferences(prefs, shouldApplyToOwner)
	PlayerPreferences = sanitizePlayerPreferences(prefs)
	updateReplicatedMultiplayerState()
	updateReplicatedResortState()
	if shouldApplyToOwner then
		applyPlayerPreferencesToPlayer(getOwnerPlayer(), PlayerPreferences)
	end
end

local RunManualSaveRequest -- forward declaration
local SaveGameData -- forward declaration
local PendingPreferenceSaveToken = 0

local function schedulePreferenceSnapshotSave()
	PendingPreferenceSaveToken += 1
	local token = PendingPreferenceSaveToken
	task.delay(2, function()
		if token ~= PendingPreferenceSaveToken then
			return
		end
		if not ALLOW_SLOT_SAVES or not SaveGameData then
			return
		end
		pcall(function()
			SaveGameData(true)
		end)
	end)
end

PreferenceRemote.OnServerInvoke = function(player, action, payload)
	if action == "Get" then
		local deadline = tick() + 20
		while player and player.Parent and player:GetAttribute("PlayerPreferencesReady") ~= true and tick() < deadline do
			task.wait(0.1)
		end
		return buildPreferencesFromPlayer(player)
	end

	if not player or not player.Parent then
		return false
	end

	if action == "SetSettings" then
		if player.UserId ~= UserIdValue.Value then
			return false
		end
		local nextPrefs = sanitizePlayerPreferences(PlayerPreferences)
		if type(payload) == "table" then
			for key, value in pairs(payload) do
				local sanitizedValue = coerceIncomingSettingValue(key, value)
				if sanitizedValue ~= nil then
					nextPrefs.Settings[key] = sanitizedValue
					player:SetAttribute("Settings_" .. key, sanitizedValue)
					if key == "MaxGuestCap" then
						player:SetAttribute("GuestCap", sanitizeSettingValue("MaxGuestCap", sanitizedValue))
					elseif key == "MaxGuestCapEnabled" then
						player:SetAttribute("GuestCapEnabled", sanitizedValue == true)
					end
				end
			end
		end
		PlayerPreferences = nextPrefs
		setPlayerPreferencesReady(player, true)
		schedulePreferenceSnapshotSave()
		return true
	elseif action == "SetWaypoints" then
		local nextWaypoints = setStoredWaypointPreferencesForPlayer(player, payload)
		player:SetAttribute("WaypointMasterMarkers", nextWaypoints.MasterMarkers ~= false)
		player:SetAttribute("WaypointActiveId", nextWaypoints.ActiveWaypointId or "")
		for category, enabled in pairs(nextWaypoints.CategoryEnabled) do
			player:SetAttribute("WaypointCategory_" .. category, enabled)
		end
		if player.UserId == UserIdValue.Value then
			local nextPrefs = sanitizePlayerPreferences(PlayerPreferences)
			nextPrefs.Waypoints = nextWaypoints
			PlayerPreferences = nextPrefs
		end
		markWaypointPreferencesDirty(player)
		scheduleWaypointPreferencesFlush(player.UserId)
		setPlayerPreferencesReady(player, true)
		return true
	elseif action == "SetMultiplayer" then
		if player.UserId ~= UserIdValue.Value then
			return false
		end
		local nextPrefs = sanitizePlayerPreferences(PlayerPreferences)
		nextPrefs.Multiplayer = sanitizeMultiplayerPreferences(payload)
		PlayerPreferences = nextPrefs
		updateReplicatedMultiplayerState()
		setPlayerPreferencesReady(player, true)
		schedulePreferenceSnapshotSave()
		return true
	elseif action == "SetResort" then
		if player.UserId ~= UserIdValue.Value then
			return false
		end
		local nextPrefs = sanitizePlayerPreferences(PlayerPreferences)
		local nextResort = sanitizeResortPreferences(type(payload) == "table" and payload or nil)
		if type(payload) == "table" and type(payload.Info) ~= "nil" then
			nextResort.Info = sanitizeResortPreferences({ Info = payload.Info }).Info
		end
		nextPrefs.Resort = nextResort
		PlayerPreferences = nextPrefs
		if type(payload) == "table" and type(payload.ResortName) == "string" then
			ResortNameValue.Value = string.sub(payload.ResortName, 1, 48)
		end
		updateReplicatedResortState()
		setPlayerPreferencesReady(player, true)
		schedulePreferenceSnapshotSave()
		return true
	elseif action == "ManualSave" then
		return RunManualSaveRequest(player)
	elseif action == "KickPlayer" then
		if player.UserId ~= UserIdValue.Value then
			return false
		end
		local targetUserId = type(payload) == "table" and tonumber(payload.UserId or payload.userId) or tonumber(payload)
		if not targetUserId or targetUserId <= 0 or targetUserId == UserIdValue.Value then
			return false
		end
		local targetPlayer = Players:GetPlayerByUserId(targetUserId)
		if not targetPlayer then
			return false
		end
		task.defer(function()
			targetPlayer:Kick("Removed from the server by the resort owner.")
		end)
		return true
	end

	return false
end

-- // DELETED TREES TRACKING //
local TrackDeletedTree = Events:FindFirstChild("TrackDeletedTree") or Instance.new("BindableEvent", Events)
TrackDeletedTree.Name = "TrackDeletedTree"

local DeletedTreePositions = {}
_G.DeletedTreePositions = DeletedTreePositions

local function getDeletedTreeBucketKey(x, z)
	return math.floor(x / 10) .. "_" .. math.floor(z / 10)
end

local function isDeletedTreeBucketMatch(x, z)
	local bucketX = math.floor(x / 10)
	local bucketZ = math.floor(z / 10)
	for dx = -1, 1 do
		for dz = -1, 1 do
			if DeletedTreePositions[tostring(bucketX + dx) .. "_" .. tostring(bucketZ + dz)] then
				return true
			end
		end
	end
	return false
end

TrackDeletedTree.Event:Connect(function(player, x, z)
	local key = getDeletedTreeBucketKey(x, z)
	DeletedTreePositions[key] = true
end)

-- // ROBUST SCRIPT FINDER //
local function FindScript(name)
	local target = string.lower(name)

	local scriptObj = ServerScriptService:FindFirstChild(name)
	if scriptObj and scriptObj:IsA("Script") then return scriptObj end

	local serverFolder = ServerScriptService:FindFirstChild("Server")
	if serverFolder then
		local exact = serverFolder:FindFirstChild(name)
		if exact and exact:IsA("Script") then return exact end
	end

	local buildingFolder = ServerScriptService:FindFirstChild("Building")
	if buildingFolder then
		local exact = buildingFolder:FindFirstChild(name)
		if exact and exact:IsA("Script") then return exact end
	end

	local recursiveExact = ServerScriptService:FindFirstChild(name, true)
	if recursiveExact and recursiveExact:IsA("Script") then
		return recursiveExact
	end

	for _, desc in ipairs(ServerScriptService:GetDescendants()) do
		if desc:IsA("Script") and string.lower(desc.Name) == target then
			return desc
		end
	end

	return nil
end

local EXPECT_TERRAINSTORE_READY = FindScript("TerrainStore") ~= nil
local BuildingStoreScript = FindScript("BuildingStore")
local EXPECT_BUILDINGSTORE_READY = BuildingStoreScript ~= nil
local ECONOMY_BOOTSTRAP_ATTR = "EconomySessionBootstrapped"
local ECONOMY_HYDRATED_ATTR = "EconomyHydrated"
local WORLD_GENERATION_ACTIVE_STATUSES = { running = true, restoring = true, finishing = true }
local WORLD_LOAD_SOFT_TIMEOUT = 45
local WORLD_LOAD_HARD_TIMEOUT = 120
local WORLD_LOAD_TIMEOUT_POLL = 5
local WORLD_LOAD_FAILSAFE_TIMEOUT = 150

local function getWorldGenerationStatus()
	local status = _G.WorldGenerationStatus
	if type(status) ~= "string" or status == "" then
		return "idle"
	end
	return status
end

local function isWorldGenerationActive()
	return WORLD_GENERATION_ACTIVE_STATUSES[getWorldGenerationStatus()] == true
end

local function getWorldGenerationElapsed()
	local startedAt = tonumber(_G.WorldGenerationStartedAt)
	if not startedAt then
		return nil
	end
	return tick() - startedAt
end

local function getEmergencySpawnPosition()
	for _, player in ipairs(Players:GetPlayers()) do
		local waitingRoom = workspace:FindFirstChild("WaitingRoom_" .. player.Name)
		if waitingRoom and waitingRoom:IsA("BasePart") then
			return waitingRoom.Position + Vector3.new(0, 6, 0)
		end
	end
	return Vector3.new(4096, 5120, 4096)
end

local function ensureEmergencyRespawn()
	local existing = workspace:FindFirstChild("EmergencyWorldSpawn")
	if existing and existing:IsA("SpawnLocation") then
		return existing
	end
	if existing then
		existing:Destroy()
	end

	local spawn = Instance.new("SpawnLocation")
	spawn.Name = "EmergencyWorldSpawn"
	spawn.Size = Vector3.new(18, 2, 18)
	spawn.Position = getEmergencySpawnPosition()
	spawn.Anchored = true
	spawn.Transparency = 1
	spawn.CanCollide = true
	spawn.CanTouch = false
	spawn.CanQuery = false
	spawn.Parent = workspace
	return spawn
end

local function movePlayersToEmergencyRespawn()
	local emergencySpawn = ensureEmergencyRespawn()
	local targetCF = emergencySpawn.CFrame + Vector3.new(0, 6, 0)
	for _, player in ipairs(Players:GetPlayers()) do
		player.RespawnLocation = emergencySpawn
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if root then
			root.AssemblyLinearVelocity = Vector3.zero
			root.AssemblyAngularVelocity = Vector3.zero
			root.CFrame = targetCF
		end
	end
end

-- // DYNAMIC CONNECTION TO SCRIPTS //
local MoneySystem = FindScript("MoneyServer")
local SetSharedMoney = nil

local function resolveSetSharedMoney()
	if SetSharedMoney and SetSharedMoney.Parent and SetSharedMoney:IsA("BindableEvent") then
		return SetSharedMoney
	end
	if not MoneySystem or not MoneySystem.Parent then
		MoneySystem = FindScript("MoneyServer")
	end
	if MoneySystem then
		local candidate = MoneySystem:FindFirstChild("SetSharedMoney")
		if not candidate then
			candidate = MoneySystem:WaitForChild("SetSharedMoney", 2)
		end
		if candidate and candidate:IsA("BindableEvent") then
			SetSharedMoney = candidate
			return SetSharedMoney
		end
	end
	return nil
end

local function syncEconomyFallbackToPlayers(cash)
	local validCash = math.max(0, math.floor((tonumber(cash) or 0) + 0.5))
	local moneyUpdate = Events:FindFirstChild("MoneyUpdate")
	for _, targetPlayer in ipairs(Players:GetPlayers()) do
		targetPlayer:SetAttribute("Money", validCash)
		local leaderstats = targetPlayer:FindFirstChild("leaderstats")
		if leaderstats then
			local cashValue = leaderstats:FindFirstChild("Cash")
			if cashValue and cashValue:IsA("IntValue") then
				cashValue.Value = validCash
			end
		end
		if moneyUpdate and moneyUpdate:IsA("RemoteEvent") then
			moneyUpdate:FireClient(targetPlayer, validCash)
		end
	end
end

local function getDefaultStartingMoney(sandboxModeOverride)
	local sandboxModeEnabled = sandboxModeOverride
	if sandboxModeEnabled == nil then
		sandboxModeEnabled = SlotDataValue:GetAttribute("SandboxMode") == true
		if sandboxModeEnabled ~= true then
			local ownerPlayer = Players:GetPlayerByUserId(UserIdValue.Value)
			sandboxModeEnabled = ownerPlayer and ownerPlayer:GetAttribute("SandboxMode") == true or false
		end
	end
	return sandboxModeEnabled and SANDBOX_STARTING_MONEY or DEFAULT_STARTING_MONEY
end

local function applyEconomySnapshot(cash, tickets)
	local validCash = math.max(0, math.floor((tonumber(cash) or getDefaultStartingMoney()) + 0.5))
	local validTickets = math.max(0, math.floor((tonumber(tickets) or DEFAULT_STARTING_TICKETS) + 0.5))
	ServerScriptService:SetAttribute("ServerMoney", validCash)
	ServerScriptService:SetAttribute("ServerTickets", validTickets)
	ServerScriptService:SetAttribute(ECONOMY_BOOTSTRAP_ATTR, true)
	ServerScriptService:SetAttribute(ECONOMY_HYDRATED_ATTR, true)
	syncEconomyFallbackToPlayers(validCash)

	local bridge = resolveSetSharedMoney()
	if bridge then
		bridge:Fire(validCash, validTickets)
		return
	end

	task.spawn(function()
		for _ = 1, 10 do
			task.wait(1)
			local retryBridge = resolveSetSharedMoney()
			if retryBridge then
				retryBridge:Fire(validCash, validTickets)
				return
			end
		end
	end)
end

local function getHydratedEconomySnapshot()
	if ServerScriptService:GetAttribute(ECONOMY_HYDRATED_ATTR) ~= true then
		return nil, nil
	end
	local currentMoney = tonumber(ServerScriptService:GetAttribute("ServerMoney"))
	local currentTickets = tonumber(ServerScriptService:GetAttribute("ServerTickets"))
	if currentMoney == nil or currentTickets == nil then
		return nil, nil
	end
	return math.max(0, math.floor(currentMoney + 0.5)), math.max(0, math.floor(currentTickets + 0.5))
end

local GenerateWorldEvent = Events:WaitForChild("GenerateWorld", 30)
local TerrainReadyEvent = Events:WaitForChild("TerrainReady", 30)
local BuildingRestoreReadyEvent = Events:FindFirstChild("BuildingRestoreReady")
local TerrainRestoreReadyEvent = Events:FindFirstChild("TerrainRestoreReady")

local WORLD_SESSION_READY = false
local LOCK_CONNECTIONS = {}
local WORLD_RESTORE_FLOW_STARTED = false
local HAS_STARTED_GAME_DATA_LOAD = false

local BASE_POST_RESTORE_DELAY = 2.0
local MAX_POST_RESTORE_DELAY = 6
local TERRAIN_DELAY_PER_ACTION = 0.0015
local BUILDING_DELAY_PER_ITEM = 0.005

-- // HELPER FUNCTIONS //
local function SerializeVector(v) 
	return {x = math.floor(v.X*100)/100, y = math.floor(v.Y*100)/100, z = math.floor(v.Z*100)/100} 
end

local function SerializeCFrame(cf) 
	local x, y, z, R00, R01, R02, R10, R11, R12, R20, R21, R22 = cf:GetComponents()
	return {x, y, z, R00, R01, R02, R10, R11, R12, R20, R21, R22} 
end

local function GetGameDataKey(userId, slotNum)
	return "User_" .. userId .. "_Slot_" .. slotNum .. "_GameData"
end

local function GetCurrentSlotBaseKey()
	local userId = tonumber(UserIdValue.Value) or 0
	local slotNum = tonumber(SlotNumValue.Value) or 0
	if userId == 0 or slotNum == 0 then
		return nil
	end
	return string.format("User_%d_Slot_%d", userId, slotNum)
end

local function GetCurrentSlotKey()
	local userId = tonumber(UserIdValue.Value) or 0
	local slotNum = tonumber(SlotNumValue.Value) or 0
	if userId == 0 or slotNum == 0 then return nil end
	return GetGameDataKey(userId, slotNum)
end

_G.GetSlotKey = function(expectedUserId)
	local baseKey = GetCurrentSlotBaseKey()
	if not baseKey then
		return nil
	end
	if expectedUserId ~= nil then
		local expected = tonumber(expectedUserId)
		if not expected or expected <= 0 or expected ~= UserIdValue.Value then
			return nil
		end
	end
	return baseKey
end

_G.GetSessionOwnerUserId = function()
	return UserIdValue.Value > 0 and UserIdValue.Value or nil
end

_G.GetSessionSlotNum = function()
	local n = tonumber(SlotNumValue.Value) or 0
	return n > 0 and n or nil
end

local function GetLegacyGameDataKeys(userId, slotNum)
	local keys = {}
	userId = tonumber(userId) or 0
	slotNum = tonumber(slotNum) or 0
	if userId == 0 or slotNum == 0 then
		return keys
	end
	table.insert(keys, "User_" .. tostring(userId) .. "_Slot" .. tostring(slotNum) .. "_GameData")
	table.insert(keys, "User_" .. tostring(userId) .. "_Slot_" .. tostring(slotNum))
	table.insert(keys, "User_" .. tostring(userId) .. "_Slot" .. tostring(slotNum))
	return keys
end

local function LooksLikeGameData(data)
	if type(data) ~= "table" then
		return false
	end
	return data.Money ~= nil
		or data.Tickets ~= nil
		or data.CreatedTime ~= nil
		or data.Timestamp ~= nil
		or data.PlayerPreferences ~= nil
		or data.ResortName ~= nil
		or data.Day ~= nil
end

local function GetLoadableGameDataKeys()
	local keys = {}
	local seen = {}
	local primary = GetCurrentSlotKey()
	if primary then
		seen[primary] = true
		table.insert(keys, primary)
	end
	for _, legacyKey in ipairs(GetLegacyGameDataKeys(UserIdValue.Value, SlotNumValue.Value)) do
		if not seen[legacyKey] then
			seen[legacyKey] = true
			table.insert(keys, legacyKey)
		end
	end
	return keys
end

local function GetPersistGameDataKeys()
	local keys = {}
	local seen = {}
	if type(ACTIVE_GAME_DATA_KEY) == "string" and ACTIVE_GAME_DATA_KEY ~= "" then
		seen[ACTIVE_GAME_DATA_KEY] = true
		table.insert(keys, ACTIVE_GAME_DATA_KEY)
	end
	local primary = GetCurrentSlotKey()
	if primary and not seen[primary] then
		seen[primary] = true
		table.insert(keys, primary)
	end
	return keys
end

local function GetBestBackupSnapshot(keys)
	local bestData = nil
	local bestKey = nil
	local bestTimestamp = -math.huge
	for _, candidateKey in ipairs(keys) do
		local success, result = pcall(function()
			return BackupStore:GetAsync(candidateKey)
		end)
		if success and LooksLikeGameData(result) then
			local ts = tonumber(result.Timestamp) or 0
			if ts > bestTimestamp then
				bestTimestamp = ts
				bestData = result
				bestKey = candidateKey
			end
		elseif success and result ~= nil then
			warn("[SlotDataLoader] Ignoring non-game backup payload for key " .. tostring(candidateKey))
		elseif not success then
			warn("[SlotDataLoader] Backup load failed for key " .. tostring(candidateKey) .. ": " .. tostring(result))
		end
	end
	return bestData, bestKey
end

local function ShouldRejectSuspiciousZeroOverwrite(newData, oldData)
	if type(newData) ~= "table" or type(oldData) ~= "table" then
		return false
	end
	local newMoney = tonumber(newData.Money)
	local oldMoney = tonumber(oldData.Money)
	if newMoney == nil or oldMoney == nil then
		return false
	end
	newMoney = math.max(0, math.floor(newMoney + 0.5))
	oldMoney = math.max(0, math.floor(oldMoney + 0.5))
	if newMoney > 0 or oldMoney < ZERO_BALANCE_OVERWRITE_GUARD_MIN then
		return false
	end
	local oldTimestamp = tonumber(oldData.Timestamp) or 0
	local createdMatches = tonumber(oldData.CreatedTime or 0) == tonumber(newData.CreatedTime or 0)
	return createdMatches or oldTimestamp > 0
end

local function applyCharacterLoadLock(character, enabled)
	if not character then return end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local root = character:FindFirstChild("HumanoidRootPart")

	if enabled then
		if humanoid then
			if humanoid:GetAttribute("PreLoad_WalkSpeed") == nil then
				humanoid:SetAttribute("PreLoad_WalkSpeed", humanoid.WalkSpeed)
				humanoid:SetAttribute("PreLoad_JumpPower", humanoid.JumpPower)
				humanoid:SetAttribute("PreLoad_JumpHeight", humanoid.JumpHeight)
				humanoid:SetAttribute("PreLoad_AutoRotate", humanoid.AutoRotate)
			end

			humanoid.WalkSpeed = 0
			humanoid.JumpPower = 0
			humanoid.JumpHeight = 0
			humanoid.AutoRotate = false
		end

		if root then
			root.Anchored = true
		end
	else
		if root then
			root.Anchored = false
		end

		if humanoid then
			local ws = humanoid:GetAttribute("PreLoad_WalkSpeed")
			local jp = humanoid:GetAttribute("PreLoad_JumpPower")
			local jh = humanoid:GetAttribute("PreLoad_JumpHeight")
			local ar = humanoid:GetAttribute("PreLoad_AutoRotate")

			humanoid.WalkSpeed = typeof(ws) == "number" and ws or 150
			humanoid.JumpPower = typeof(jp) == "number" and jp or 50
			humanoid.JumpHeight = typeof(jh) == "number" and jh or 7.2
			humanoid.AutoRotate = (type(ar) == "boolean") and ar or true
		end
	end
end

local function setPlayerLoadLock(player, enabled)
	if not player then return end
	player:SetAttribute("WorldLoadLocked", enabled)

	if LOCK_CONNECTIONS[player] then
		LOCK_CONNECTIONS[player]:Disconnect()
		LOCK_CONNECTIONS[player] = nil
	end

	if enabled then
		LOCK_CONNECTIONS[player] = player.CharacterAdded:Connect(function(char)
			task.defer(function()
				applyCharacterLoadLock(char, true)
			end)
		end)
	end

	if player.Character then
		applyCharacterLoadLock(player.Character, enabled)
	end
end

local function fireGenerateWorld(player, settings)
	if not GenerateWorldEvent then
		return false
	end

	if GenerateWorldEvent:IsA("BindableEvent") then
		GenerateWorldEvent:Fire(player, settings)
		return true
	end

	return false
end

local function invokeBindable(name, ...)
	local bindable = Events:FindFirstChild(name)
	if not bindable or not bindable:IsA("BindableFunction") then
		return false, "missing"
	end
	local args = table.pack(...)
	local ok, result = pcall(function()
		return bindable:Invoke(table.unpack(args, 1, args.n))
	end)
	if not ok then
		return false, tostring(result)
	end
	if result == false then
		return false, "returned_false"
	end
	return true, result
end

local LastSaveTime = 0
local MANUAL_SAVE_COOLDOWN_SECONDS = 25
local LastManualSaveAt = 0
local ManualSaveInFlight = false
local _lastSavedMoney = nil
local _lastSavedTickets = nil
local LastGameDataFingerprint = nil
local LAST_GAME_BACKUP_AT = 0
local GAME_BACKUP_MIN_INTERVAL_SECONDS = 600
local COORDINATED_SAVE_COOLDOWN_SECONDS = 8
local CoordinatedSaveInFlight = false
local LastCoordinatedSaveAt = 0
local LastCoordinatedSaveReport = nil

-- // SAVING SYSTEM //
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

local function buildGameDataFingerprint(saveData)
	local stablePayload = {
		Money = saveData.Money,
		Tickets = saveData.Tickets,
		Objects = saveData.Objects,
		ResortName = saveData.ResortName,
		ResortInfo = saveData.ResortInfo,
		ResortOpen = saveData.ResortOpen,
		ResortAllLights = saveData.ResortAllLights,
		SlotNum = saveData.SlotNum,
		CreatedTime = saveData.CreatedTime,
		Day = saveData.Day,
		DeletedTrees = saveData.DeletedTrees,
		PlayerPreferences = saveData.PlayerPreferences,
	}
	local ok, encoded = pcall(function()
		return HttpService:JSONEncode(stablePayload)
	end)
	if ok and type(encoded) == "string" then
		return encoded
	end
	return table.concat({
		tostring(saveData.Money),
		tostring(saveData.Tickets),
		tostring(saveData.ResortName),
		tostring(saveData.ResortInfo),
		tostring(saveData.ResortOpen),
		tostring(saveData.ResortAllLights),
		tostring(saveData.Day),
		tostring(#(saveData.DeletedTrees or {})),
	}, "|")
end

local function shouldWriteGameBackup(force)
	if force then
		return true
	end
	return (os.clock() - LAST_GAME_BACKUP_AT) >= GAME_BACKUP_MIN_INTERVAL_SECONDS
end

SaveGameData = function(force)
	local saveKeys = GetPersistGameDataKeys()
	if #saveKeys == 0 or not ALLOW_SLOT_SAVES then return end

	local currentMoney, currentTickets = getHydratedEconomySnapshot()
	if currentMoney == nil or currentTickets == nil then
		return
	end
	if currentMoney <= 0 then
		warn(string.format("[SlotDataLoader] Attempting to save zero balance (keys=%s, slot=%s, owner=%s)", table.concat(saveKeys, ","), tostring(SlotNumValue.Value), tostring(UserIdValue.Value)))
	end
	local objectsData = {}
	local seenObjectUUIDs = {}

	if not force and (os.time() - LastSaveTime < 10) then
		return
	end
	if HANDLE_BUILDINGS then
		local placedFolder = workspace:FindFirstChild("PlacedObjects")
		if placedFolder then
			for _, model in ipairs(placedFolder:GetChildren()) do
				local itemType = model:GetAttribute("Type")
				local data = { Item = model.Name, Type = itemType, UUID = model:GetAttribute("UUID") }
				if itemType == "Slope" then
					data.Points = model:GetAttribute("RawPoints") 
					data.UseNets = model:GetAttribute("UseNets")
					data.Difficulty = model:GetAttribute("Difficulty")
				elseif itemType == "TwoPoint" then
					local p1 = model:GetAttribute("P1")
					local p2 = model:GetAttribute("P2")
					if p1 and p2 then
						data.Start = SerializeVector(p1)
						data.End = SerializeVector(p2)
					else 
						data = nil 
					end
				elseif itemType == "Static" or itemType == "House" or itemType == "Food" or itemType == "Rental" then
					data.CF = SerializeCFrame(model:GetPivot())
				end
				if data then
					local uuid = data.UUID
					if type(uuid) == "string" and uuid ~= "" then
						if not seenObjectUUIDs[uuid] then
							seenObjectUUIDs[uuid] = true
							table.insert(objectsData, data)
						end
					else
						table.insert(objectsData, data)
					end
				end
			end
		end
	end

	local player = Players:GetPlayerByUserId(UserIdValue.Value)
	local preferenceSnapshot = buildPreferencesFromPlayer(player)
	PlayerPreferences = preferenceSnapshot

	local saveData = { 
		Money = currentMoney, 
		Tickets = currentTickets, 
		Objects = objectsData, 
		Timestamp = os.time(), 
		ResortName = ResortNameValue.Value,
		ResortInfo = tostring(SlotDataValue:GetAttribute("ResortInfo") or ""),
		ResortOpen = SlotDataValue:GetAttribute("ResortOpen") ~= false,
		ResortAllLights = SlotDataValue:GetAttribute("ResortAllLights") ~= false,
		SlotNum = SlotNumValue.Value,
		CreatedTime = SlotCreatedTime.Value,
		Day = math.max(1, math.floor(tonumber(Lighting:GetAttribute("Day")) or 1)),
		DeletedTrees = {},
		LastPosition = nil,
		PlayerPreferences = preferenceSnapshot,
	}

	if player and player.Character and player.Character.PrimaryPart then
		saveData.LastPosition = {
			player.Character.PrimaryPart.Position.X,
			player.Character.PrimaryPart.Position.Y,
			player.Character.PrimaryPart.Position.Z
		}
	end

	for treeKey, _ in pairs(DeletedTreePositions) do
		table.insert(saveData.DeletedTrees, treeKey)
	end
	table.sort(saveData.DeletedTrees)

	local saveFingerprint = buildGameDataFingerprint(saveData)
	if not force and saveFingerprint == LastGameDataFingerprint then
		return
	end

	local MAX_RETRIES = 5
	local BASE_DELAY = 1.5
	local anyKeySaved = false
	local writeBackupThisPass = shouldWriteGameBackup(force)
	local wroteBackupThisPass = false

	for _, saveKey in ipairs(saveKeys) do
		local success = false
		local err = nil
		local retryDelay = BASE_DELAY
		for attempt = 1, MAX_RETRIES do
			if not waitForUpdateBudget(force and 8 or 1.5) then
				err = "budget_exhausted"
				break
			end
			success, err = pcall(function()
				GameStore:UpdateAsync(saveKey, function(oldData)
					if ShouldRejectSuspiciousZeroOverwrite(saveData, oldData) then
						warn(string.format("[SlotDataLoader] Blocked suspicious zero-money overwrite for %s (old=%s new=%s)", tostring(saveKey), tostring(oldData and oldData.Money), tostring(saveData.Money)))
						return oldData
					end
					return saveData
				end)
			end)
			if success then
				anyKeySaved = true
				if writeBackupThisPass and waitForUpdateBudget(force and 6 or 0.75) then
					pcall(function()
						BackupStore:UpdateAsync(saveKey, function(oldBackup)
							local oldTimestamp = type(oldBackup) == "table" and (tonumber(oldBackup.Timestamp) or 0) or 0
							local newTimestamp = tonumber(saveData.Timestamp) or 0
							if oldTimestamp > newTimestamp then
								return oldBackup
							end
							return saveData
						end)
					end)
					wroteBackupThisPass = true
				end
				break
			else
				warn("[SlotDataLoader] Save failed for key " .. tostring(saveKey) .. " (Attempt " .. attempt .. "/" .. MAX_RETRIES .. "): " .. tostring(err))
				if attempt < MAX_RETRIES then
					task.wait(retryDelay + math.random() * 2)
					retryDelay = retryDelay * 2
				end
			end
		end
	end
	if anyKeySaved then
		LastSaveTime = os.time()
		_lastSavedMoney = currentMoney
		_lastSavedTickets = currentTickets
		LastGameDataFingerprint = saveFingerprint
		if wroteBackupThisPass then
			LAST_GAME_BACKUP_AT = os.clock()
		end
	elseif ALLOW_SLOT_SAVES then
		warn("[SlotDataLoader] SaveGameData finished with no successful DataStore writes (check throttling / errors above).")
	end
end

local function invokeBindableSaver(name, ...)
	local bindable = Events:FindFirstChild(name)
	if not bindable then
		return { available = false, ok = false, detail = "missing" }
	end
	if not bindable:IsA("BindableFunction") then
		return { available = true, ok = false, detail = "wrong_type" }
	end
	local args = table.pack(...)
	local ok, result = pcall(function()
		return bindable:Invoke(table.unpack(args, 1, args.n))
	end)
	if not ok then
		return { available = true, ok = false, detail = tostring(result) }
	end
	if type(result) == "table" and result.success ~= nil then
		local detail = result.message or result.reason
		return { available = true, ok = (result.success == true), detail = detail and tostring(detail) or nil }
	end
	if result == false then
		return { available = true, ok = false, detail = "returned_false" }
	end
	return { available = true, ok = true, detail = result == nil and "ok" or tostring(result) }
end

local function runSubsystemSaves()
	if CoordinatedSaveInFlight and LastCoordinatedSaveReport then
		return LastCoordinatedSaveReport
	end
	if LastCoordinatedSaveReport and (os.clock() - LastCoordinatedSaveAt) < COORDINATED_SAVE_COOLDOWN_SECONDS then
		return LastCoordinatedSaveReport
	end

	CoordinatedSaveInFlight = true
	_G.CoordinatedSaveInProgress = true
	_G.LastCoordinatedSaveAt = os.clock()

	local report = {
		success = true,
		savedAt = os.time(),
		steps = {},
	}

	local function addStep(name, ok, detail)
		table.insert(report.steps, {
			name = name,
			ok = ok == true,
			detail = detail,
		})
		if ok ~= true then
			report.success = false
		end
	end

	local function pauseBetweenSteps()
		task.wait(0.15)
	end

	local slotOk, slotErr = pcall(function()
		SaveGameData(true)
	end)
	addStep("CoreSlot", slotOk, slotOk and "ok" or tostring(slotErr))
	pauseBetweenSteps()

	local buildingResult = invokeBindableSaver("BuildingRequestSaveNow", true)
	if buildingResult.available then
		addStep("Buildings", buildingResult.ok, buildingResult.detail)
	else
		local requestBuildingSave = Events:FindFirstChild("RequestBuildingSave")
		if requestBuildingSave and requestBuildingSave:IsA("BindableEvent") then
			local ok, err = pcall(function()
				requestBuildingSave:Fire(true)
			end)
			addStep("Buildings", ok, ok and "fired" or tostring(err))
		else
			addStep("Buildings", false, "unavailable")
		end
	end
	pauseBetweenSteps()

	local employeeResult = invokeBindableSaver("EmployeeRequestSave", true)
	addStep("Employees", employeeResult.available and employeeResult.ok or false, employeeResult.detail)
	pauseBetweenSteps()

	local terrainResult = invokeBindableSaver("TerrainRequestSave", true)
	addStep("Terrain", terrainResult.available and terrainResult.ok or false, terrainResult.detail)
	pauseBetweenSteps()

	local researchResult = invokeBindableSaver("ResearchRequestSave", UserIdValue.Value, true)
	addStep("Research", researchResult.available and researchResult.ok or false, researchResult.detail)
	pauseBetweenSteps()

	local decorResult = invokeBindableSaver("DecorMilestoneRequestSave", UserIdValue.Value, true)
	addStep("DecorMilestones", decorResult.available and decorResult.ok or false, decorResult.detail)

	CoordinatedSaveInFlight = false
	LastCoordinatedSaveAt = os.clock()
	LastCoordinatedSaveReport = report
	_G.CoordinatedSaveInProgress = false
	_G.LastCoordinatedSaveAt = LastCoordinatedSaveAt
	return report
end

RunManualSaveRequest = function(player)
	if not player or player.Parent ~= Players then
		return {
			success = false,
			message = "Player not available.",
		}
	end
	if player.UserId ~= UserIdValue.Value then
		return {
			success = false,
			message = "Only the slot owner can force-save.",
		}
	end
	if not ALLOW_SLOT_SAVES then
		return {
			success = false,
			message = "Save system is still initializing.",
		}
	end
	if ManualSaveInFlight then
		return {
			success = false,
			message = "Manual save already running.",
		}
	end

	local now = os.clock()
	local elapsed = now - LastManualSaveAt
	if elapsed < MANUAL_SAVE_COOLDOWN_SECONDS then
		return {
			success = false,
			message = string.format("Manual save cooldown active (%ds).", math.ceil(MANUAL_SAVE_COOLDOWN_SECONDS - elapsed)),
		}
	end

	ManualSaveInFlight = true
	local ok, result = pcall(runSubsystemSaves)
	ManualSaveInFlight = false

	if not ok then
		return {
			success = false,
			message = "Manual save failed unexpectedly.",
			error = tostring(result),
		}
	end

	LastManualSaveAt = os.clock()
	result.message = result.success and "Manual save complete." or "Manual save finished with some subsystem errors."
	return result
end

local AdminRefreshInFlight = false
AdminRefreshWorld.OnInvoke = function(requestingPlayer, targetUserId, targetSlotNum)
	if AdminRefreshInFlight then
		return false
	end

	targetUserId = tonumber(targetUserId)
	targetSlotNum = tonumber(targetSlotNum)
	if not targetUserId or not targetSlotNum then
		return false
	end
	if targetUserId ~= tonumber(UserIdValue.Value) or targetSlotNum ~= tonumber(SlotNumValue.Value) then
		return false
	end

	local ownerPlayer = Players:GetPlayerByUserId(targetUserId)
	if not ownerPlayer then
		return false
	end

	AdminRefreshInFlight = true
	for _, p in ipairs(Players:GetPlayers()) do
		setPlayerLoadLock(p, true)
		LoadingUpdate:FireClient(p, "Applying admin world refresh...", 4, 65)
	end

	local saveOk = pcall(function()
		runSubsystemSaves()
	end)
	if not saveOk then
		warn("[SlotDataLoader] Admin refresh pre-save encountered errors, continuing with reload.")
	end

	HAS_STARTED_GAME_DATA_LOAD = false
	WORLD_RESTORE_FLOW_STARTED = false
	WORLD_SESSION_READY = false
	_G.SessionFullyReady = false
	_G.WorldFullyReady = false
	_G.TerrainReady = false
	_G.TerrainSettled = false
	_G.TerrainWriteInProgress = false
	_G.TerrainStoreRestoreReady = false
	_G.BuildingStoreRestoreReady = false
	_G.TerrainRestoreActionCount = 0
	_G.BuildingRestoreItemCount = 0

	local resetEvent = Events:FindFirstChild("ForceResetWorldSession")
	if resetEvent and resetEvent:IsA("BindableEvent") then
		pcall(function()
			resetEvent:Fire(targetUserId, targetSlotNum)
		end)
	end

	local regenSettings = {
		CreatedTime = SlotCreatedTime.Value,
		MapScale = SlotDataValue:GetAttribute("MapScale") or 1,
		MapScaleMode = SlotDataValue:GetAttribute("MapScaleMode") or "HeightOnly",
		SandboxMode = SlotDataValue:GetAttribute("SandboxMode") == true,
	}

	if not fireGenerateWorld(ownerPlayer, regenSettings) then
		AdminRefreshInFlight = false
		return false
	end

	task.spawn(function()
		local terrainReadyTimeout = tick() + 120
		while not ((_G.TerrainSettled == true) and (_G.TerrainWriteInProgress ~= true)) and tick() < terrainReadyTimeout do
			task.wait(0.25)
		end

		local terrainReloadOk = invokeBindable("TerrainForceReload", targetUserId)
		if not terrainReloadOk then
			warn("[SlotDataLoader] TerrainForceReload failed during admin refresh.")
		end

		local buildingReloadOk = invokeBindable("BuildingForceReload", targetUserId)
		if not buildingReloadOk then
			warn("[SlotDataLoader] BuildingForceReload failed during admin refresh.")
		end

		AdminRefreshInFlight = false
	end)

	return true
end

local function fireCompensationModal(player)
	if not player or player.Parent ~= Players then
		return
	end
	if (tonumber(DATA_LOSS_GRANT_AMOUNT) or 0) <= 0 then
		return
	end
	if not CompensationModalEvent or not CompensationModalEvent:IsA("RemoteEvent") then
		return
	end
	CompensationModalEvent:FireClient(player, DATA_LOSS_GRANT_ID, COMPENSATION_MODAL_TITLE, COMPENSATION_MODAL_MESSAGE, DATA_LOSS_GRANT_AMOUNT)
end

local function buildCompensationClaimKey(userId)
	userId = math.floor(tonumber(userId) or 0)
	local slotNum = math.clamp(math.floor((tonumber(SlotNumValue.Value) or 0) + 0.5), 0, 32)
	local createdTime = math.clamp(math.max(0, math.floor(tonumber(SlotCreatedTime.Value) or 0)), 0, 4102444800)
	local tag = tostring(COMPENSATION_DS_KEY_TAG or "G"):gsub("[^%w]", "")
	if #tag > 8 then
		tag = string.sub(tag, 1, 8)
	end
	-- Roblox DataStore key max length 50; compact deterministic format (no long "CT" decimal strings).
	local key = string.format("%d_%d_%x_%s", userId, slotNum, createdTime, tag)
	if #key > 50 then
		key = string.format("%d_%d_%s", userId, slotNum, tag)
	end
	if #key > 50 then
		warn("[SlotDataLoader] Compensation claim key over limit after shrink; using minimal user+tag key.")
		key = string.format("C%d_%s", userId, tag)
	end
	if #key > 50 then
		key = string.sub(key, 1, 50)
	end
	return key
end

local function markCompensationModalDismissed(userId)
	if type(userId) ~= "number" or userId <= 0 then
		return
	end
	local claimKey = buildCompensationClaimKey(userId)
	local success, err = pcall(function()
		CompensationStore:UpdateAsync(claimKey, function(oldValue)
			if type(oldValue) ~= "table" then
				return oldValue
			end
			local record = oldValue
			if record.NotificationDismissedAt == nil then
				record.NotificationDismissedAt = os.time()
			end
			record.Amount = tonumber(record.Amount) or DATA_LOSS_GRANT_AMOUNT
			record.SlotNum = tonumber(record.SlotNum) or SlotNumValue.Value
			record.DataStoreKey = record.DataStoreKey or ACTIVE_GAME_DATA_KEY or GetCurrentSlotKey()
			return record
		end)
	end)
	if not success then
		warn("[SlotDataLoader] Failed to persist compensation modal dismissal for user " .. tostring(userId) .. ": " .. tostring(err))
	end
end

if CompensationModalAck and CompensationModalAck:IsA("RemoteEvent") then
	CompensationModalAck.OnServerEvent:Connect(function(player, grantId)
		if not player or player.Parent ~= Players then
			return
		end
		if tostring(grantId) ~= DATA_LOSS_GRANT_ID then
			return
		end
		markCompensationModalDismissed(player.UserId)
	end)
end

local function IsCompensationEligibleForLoadedData(data)
	if type(data) ~= "table" then
		return false
	end
	local createdTime = tonumber(data.CreatedTime)
	if not createdTime then
		return false
	end
	createdTime = math.floor(createdTime + 0.5)
	if createdTime < 946684800 or createdTime > 4102444800 then
		return false
	end
	return createdTime < DATA_LOSS_COMPENSATION_CREATED_BEFORE
end

local function AwardDataLossCompensationIfNeeded(player)
	if not player or player.UserId ~= UserIdValue.Value then
		return
	end
	if (tonumber(DATA_LOSS_GRANT_AMOUNT) or 0) <= 0 then
		return
	end
	if SlotDataValue:GetAttribute("FreshSave") == true or SlotDataValue:GetAttribute("CompensationEligible") ~= true then
		-- Only existing affected saves are eligible for this compensation grant.
		return
	end
	local sessionCt = math.floor(tonumber(SlotCreatedTime.Value) or 0)
	if sessionCt < 946684800 or sessionCt > 4102444800 or sessionCt >= DATA_LOSS_COMPENSATION_CREATED_BEFORE then
		return
	end
	local currentMoney, currentTickets = getHydratedEconomySnapshot()
	if currentMoney == nil or currentTickets == nil then
		return
	end

	local claimKey = buildCompensationClaimKey(player.UserId)
	local granted = false
	local shouldShowModal = false
	local success, err = pcall(function()
		CompensationStore:UpdateAsync(claimKey, function(oldValue)
			local record = type(oldValue) == "table" and oldValue or nil
			if not record then
				granted = true
				shouldShowModal = true
				return {
					GrantedAt = os.time(),
					Amount = DATA_LOSS_GRANT_AMOUNT,
					SlotNum = SlotNumValue.Value,
					DataStoreKey = ACTIVE_GAME_DATA_KEY or GetCurrentSlotKey(),
					NotificationShownAt = os.time(),
					NotificationDismissedAt = nil,
				}
			end
			if record.NotificationDismissedAt == nil then
				shouldShowModal = true
				record.NotificationShownAt = os.time()
			end
			record.Amount = tonumber(record.Amount) or DATA_LOSS_GRANT_AMOUNT
			record.SlotNum = tonumber(record.SlotNum) or SlotNumValue.Value
			record.DataStoreKey = record.DataStoreKey or ACTIVE_GAME_DATA_KEY or GetCurrentSlotKey()
			return record
		end)
	end)
	if not success then
		warn("[SlotDataLoader] Compensation claim failed for user " .. tostring(player.UserId) .. ": " .. tostring(err))
		return
	end

	if granted then
		applyEconomySnapshot(currentMoney + DATA_LOSS_GRANT_AMOUNT, currentTickets)
		task.defer(function()
			SaveGameData(true)
		end)
	end

	if shouldShowModal then
		if granted then
			for _, targetPlayer in ipairs(Players:GetPlayers()) do
				fireCompensationModal(targetPlayer)
			end
		else
			fireCompensationModal(player)
		end
	elseif granted and NotificationEvent and NotificationEvent:IsA("RemoteEvent") then
		NotificationEvent:FireClient(player, "Positive", COMPENSATION_MODAL_TITLE, COMPENSATION_MODAL_MESSAGE, 6)
	end
end

function isTerrainGenerationSettled()
	return (_G.TerrainSettled == true) and (_G.TerrainWriteInProgress ~= true)
end

function isTerrainRestoreReady()
	return isTerrainGenerationSettled() and ((not EXPECT_TERRAINSTORE_READY) or (_G.TerrainStoreRestoreReady == true))
end

function isBuildingRestoreReady()
	return (not EXPECT_BUILDINGSTORE_READY) or (_G.BuildingStoreRestoreReady == true)
end

function getPostRestoreDelaySeconds()
	local terrainActions = tonumber(_G.TerrainRestoreActionCount) or 0
	local buildingItems = tonumber(_G.BuildingRestoreItemCount) or 0
	local extraDelay = (terrainActions * TERRAIN_DELAY_PER_ACTION) + (buildingItems * BUILDING_DELAY_PER_ITEM)
	return math.clamp(BASE_POST_RESTORE_DELAY + extraDelay, BASE_POST_RESTORE_DELAY, MAX_POST_RESTORE_DELAY)
end

function waitForRestoreSystems(ownerPlayer)
	if IS_STUDIO then return true end
	local timeoutSeconds = 120
	local startedAt = tick()
	local nextHudUpdate = 0


	while tick() - startedAt < timeoutSeconds do
		if not BuildingRestoreReadyEvent then
			local ev = Events:FindFirstChild("BuildingRestoreReady")
			if ev and ev:IsA("BindableEvent") then
				BuildingRestoreReadyEvent = ev
			end
		end
		if not TerrainRestoreReadyEvent then
			local ev = Events:FindFirstChild("TerrainRestoreReady")
			if ev and ev:IsA("BindableEvent") then
				TerrainRestoreReadyEvent = ev
			end
		end

		local terrainReady = isTerrainRestoreReady()
		local terrainSettled = isTerrainGenerationSettled()
		local buildingReady = isBuildingRestoreReady()

		if terrainReady and buildingReady then
			return true
		end

		local now = tick()
		if ownerPlayer and now >= nextHudUpdate then
			local progress = 55
			if terrainReady then progress += 20 end
			if buildingReady then
				progress += 20
			elseif terrainReady and EXPECT_BUILDINGSTORE_READY then
				if not BuildingStoreScript or not BuildingStoreScript.Parent then
					BuildingStoreScript = FindScript("BuildingStore")
				end
				local rIdx = tonumber(BuildingStoreScript and BuildingStoreScript:GetAttribute("RestoreIndex")) or 0
				local rTot = tonumber(BuildingStoreScript and BuildingStoreScript:GetAttribute("RestoreTotal")) or 0
				if rTot > 0 then
					progress = 75 + math.floor(math.clamp(rIdx / rTot, 0, 1) * 15)
				else
					local planned = tonumber(_G.BuildingRestoreItemCount) or 0
					progress = planned > 0 and 76 or 75
				end
			end
			progress = math.clamp(progress, 55, 95)

			local buildingHud = "Ready"
			if not buildingReady then
				if EXPECT_BUILDINGSTORE_READY then
					if not BuildingStoreScript or not BuildingStoreScript.Parent then
						BuildingStoreScript = FindScript("BuildingStore")
					end
					local stage = BuildingStoreScript and BuildingStoreScript:GetAttribute("RestoreStage")
					local rIdx = tonumber(BuildingStoreScript and BuildingStoreScript:GetAttribute("RestoreIndex")) or 0
					local rTot = tonumber(BuildingStoreScript and BuildingStoreScript:GetAttribute("RestoreTotal")) or 0
					local planned = tonumber(_G.BuildingRestoreItemCount) or 0
					if stage and rTot > 0 then
						buildingHud = string.format("Loading %s %d/%d", tostring(stage), rIdx, rTot)
					elseif planned > 0 then
						buildingHud = string.format("Loading (%d objects queued)", planned)
					else
						buildingHud = "Loading (starting building restore...)"
					end
				else
					buildingHud = "Ready"
				end
			end

			local msg = string.format(
				"Restoring world... Terrain: %s | Buildings: %s",
				(terrainReady and terrainSettled) and "Ready" or (terrainSettled and "Restoring" or "Generating"),
				buildingHud
			)
			LoadingUpdate:FireClient(ownerPlayer, msg, 4, progress)
			nextHudUpdate = now + 1
		end

		task.wait(0.25)

		if tick() - startedAt > timeoutSeconds + 5 then
			break
		end
	end

	return false
end

function finalizeSessionLoad(lastPosition)
	if WORLD_SESSION_READY then return end

	local settleDelay = getPostRestoreDelaySeconds()
	local owner = Players:GetPlayerByUserId(UserIdValue.Value)
	if owner then
		LoadingUpdate:FireClient(owner, string.format("Finalizing world sync (%.1fs)...", settleDelay), 4, 90)
	end

	task.delay(settleDelay, function()
		local worldReadyWaitStart = tick()
		local WORLD_READY_TIMEOUT = 12

		while not _G.WorldFullyReady and (tick() - worldReadyWaitStart) < WORLD_READY_TIMEOUT do
			local pOwner = Players:GetPlayerByUserId(UserIdValue.Value)
			if pOwner then
				local elapsed = math.floor(tick() - worldReadyWaitStart)
				LoadingUpdate:FireClient(pOwner, string.format("World systems starting up... (%ds)", elapsed), 4, 92 + math.min(elapsed, 6))
			end
			task.wait(0.5)
		end

		local pOwner = Players:GetPlayerByUserId(UserIdValue.Value)
		if pOwner and lastPosition then
			pcall(function()
				local char = pOwner.Character
				if (not char) or (not char:FindFirstChildOfClass("Humanoid")) or (not char:FindFirstChild("HumanoidRootPart")) then
					pcall(function()
						pOwner:LoadCharacter()
					end)
					local deadline = tick() + 8
					repeat
						char = pOwner.Character
						if char and char:FindFirstChildOfClass("Humanoid") and char:FindFirstChild("HumanoidRootPart") then
							break
						end
						task.wait(0.25)
					until tick() >= deadline
				end
				if not char then
					warn("[SlotDataLoader] Unable to recover owner character during session finalization for user " .. tostring(pOwner.UserId))
					return
				end
				local root = char:WaitForChild("HumanoidRootPart", 10)
				if root then
					local pos = Vector3.new(lastPosition[1], lastPosition[2], lastPosition[3])
					if pos.Y < 50 then
						pos = Vector3.new(pos.X, 100, pos.Z)
					end
					root.CFrame = CFrame.new(pos + Vector3.new(0, 5, 0))
				end
			end)
		end

		WORLD_SESSION_READY = true
		_G.SessionFullyReady = true

		for _, p in ipairs(Players:GetPlayers()) do
			LoadingUpdate:FireClient(p, "Loading complete!", 5, 100)
			task.defer(function()
				local char = p.Character
				local humanoid = char and char:FindFirstChildOfClass("Humanoid")
				local root = char and char:FindFirstChild("HumanoidRootPart")
				if (not char) or (not humanoid) or (not root) then
					pcall(function()
						p:LoadCharacter()
					end)
					return
				end
				root.Anchored = false
				root.AssemblyLinearVelocity = Vector3.zero
				root.AssemblyAngularVelocity = Vector3.zero
				humanoid.PlatformStand = false
				humanoid.AutoRotate = true
			end)
			setPlayerLoadLock(p, false)
		end
	end)
end

-- // LOADING SYSTEM //
local CREATED_TIME_MIN_UNIX = 946684800 -- 2000-01-01 UTC
local CREATED_TIME_MAX_UNIX = 4102444800 -- ~2099

function normalizeSessionCreatedTime(value)
	if value == nil then
		return nil
	end
	local n = tonumber(value)
	if not n or n ~= n or n == math.huge or n == -math.huge then
		return nil
	end
	n = math.floor(n + 0.5)
	if n < CREATED_TIME_MIN_UNIX or n > CREATED_TIME_MAX_UNIX then
		return nil
	end
	return n
end

function bootstrapFreshSaveSessionFromLoad()
	SlotDataValue:SetAttribute("FreshSave", true)
	SlotDataValue:SetAttribute("CompensationEligible", false)

	local wipeBuilding = Events:FindFirstChild("WipeBuildingStore")
	if wipeBuilding and wipeBuilding:IsA("BindableEvent") then pcall(function() wipeBuilding:Fire(SlotNumValue.Value, UserIdValue.Value) end) end
	local wipeTerrain = Events:FindFirstChild("WipeTerrainStore")
	if wipeTerrain and wipeTerrain:IsA("BindableEvent") then pcall(function() wipeTerrain:Fire(SlotNumValue.Value, UserIdValue.Value) end) end
	ALLOW_SLOT_SAVES = true
	Lighting:SetAttribute("Day", 1)
	setStoredPlayerPreferences(buildDefaultPlayerPreferences(), true)
	applyEconomySnapshot(getDefaultStartingMoney(), DEFAULT_STARTING_TICKETS)
	finalizeSessionLoad(nil)
end

function loadGameDataWithRetries(key)
	local lastError = nil
	for attempt = 1, 3 do
		local success, payload = pcall(function()
			return GameStore:GetAsync(key)
		end)
		if success then
			return true, payload
		end
		lastError = payload
		task.wait(0.75 * attempt)
	end
	return false, lastError
end

function LoadGameData(teleportCreatedTime)
	local loadKeys = GetLoadableGameDataKeys()
	local key = loadKeys[1]
	if not key then
		finalizeSessionLoad(nil)
		return
	end

	local success = false
	local data = nil
	local resolvedKey = nil
	local hadLookupErrors = false
	for _, candidateKey in ipairs(loadKeys) do
		success, data = loadGameDataWithRetries(candidateKey)
		if not success then
			hadLookupErrors = true
			warn("[SlotDataLoader] Load failed for key " .. tostring(candidateKey) .. ": " .. tostring(data))
		elseif data and LooksLikeGameData(data) then
			resolvedKey = candidateKey
			break
		elseif data ~= nil then
			warn("[SlotDataLoader] Ignoring non-game payload for key " .. tostring(candidateKey))
			data = nil
		end
	end

	ACTIVE_GAME_DATA_KEY = resolvedKey or key

	if not data then
		local backupData, backupKey = GetBestBackupSnapshot(loadKeys)
		if backupData then
			data = backupData
			resolvedKey = backupKey or resolvedKey or key
			ACTIVE_GAME_DATA_KEY = resolvedKey or key
			warn("[SlotDataLoader] Recovered slot data from backup key " .. tostring(resolvedKey))
		else
			if hadLookupErrors then
				warn("[SlotDataLoader] DataStore lookups failed and no backup snapshot was found. Refusing fresh-save initialization to prevent overwrite.")
				ACTIVE_GAME_DATA_KEY = nil
				ALLOW_SLOT_SAVES = false
				for _, targetPlayer in ipairs(Players:GetPlayers()) do
					setPlayerLoadLock(targetPlayer, true)
					LoadingUpdate:FireClient(targetPlayer, "DataStore services are unstable right now. Your save was not modified. Please rejoin shortly.", 4, 0)
				end
				task.delay(4, function()
					for _, targetPlayer in ipairs(Players:GetPlayers()) do
						if targetPlayer and targetPlayer.Parent == Players then
							warn(string.format("[SlotDataLoader] Keeping %s in-server after DataStore instability; slot saves remain disabled for this session.", targetPlayer.Name))
							setPlayerLoadLock(targetPlayer, false)
						end
					end
				end)
				return
			end
			warn("[SlotDataLoader] No saved slot data found for keys " .. table.concat(loadKeys, ", ") .. ". Initializing a fresh save.")
			bootstrapFreshSaveSessionFromLoad()
			return
		end
	end

	if resolvedKey and resolvedKey ~= key then
		warn("[SlotDataLoader] Loaded slot data from legacy key " .. tostring(resolvedKey) .. ". Future saves will migrate to " .. tostring(key))
	end

	local teleTs = normalizeSessionCreatedTime(teleportCreatedTime)
	if teleTs == nil and teleportCreatedTime ~= nil and teleportCreatedTime ~= 0 and tostring(teleportCreatedTime) ~= "" then
		warn(string.format("[SlotDataLoader] Ignoring invalid Teleport CreatedTime (%s) for key %s.", tostring(teleportCreatedTime), tostring(key)))
	end

	local savedTs = normalizeSessionCreatedTime(data.CreatedTime)
	if savedTs then
		if teleTs and teleTs > savedTs + 10 then
			warn(string.format(
				"[SlotDataLoader] Teleport CreatedTime (%s) is newer than Store CreatedTime (%s). Lobby initiated a fresh save! Wiping stale data for slot %s.",
				tostring(teleTs), tostring(savedTs), tostring(key)
			))
			bootstrapFreshSaveSessionFromLoad()
			return
		elseif teleTs and savedTs ~= teleTs then
			-- Critical: never wipe a live save just because TeleportData carries a mismatched (but not significantly newer) CreatedTime.
			-- We trust the DataStore, normalize the session CreatedTime, and continue loading it.
			warn(string.format(
				"[SlotDataLoader] CreatedTime mismatch for %s (Store=%s, Teleport=%s). Loading store data and normalizing session CreatedTime.",
				tostring(key), tostring(savedTs), tostring(teleTs)
			))
		end
		if SlotCreatedTime.Value <= 0 or SlotCreatedTime.Value ~= savedTs then
			SlotCreatedTime.Value = savedTs
		end
	elseif SlotCreatedTime.Value <= 0 then
		local synthesizedCreatedTime = teleTs or os.time()
		SlotCreatedTime.Value = synthesizedCreatedTime
		data.CreatedTime = synthesizedCreatedTime
		warn(string.format(
			"[SlotDataLoader] Loaded legacy slot %s without CreatedTime. Synthesizing session CreatedTime=%s for migration.",
			tostring(key), tostring(synthesizedCreatedTime)
		))
	end

	if type(data) ~= "table" then
		warn("[SlotDataLoader] LoadGameData lost slot payload after CreatedTime handling; finishing with empty session.")
		finalizeSessionLoad(nil)
		return
	end

	local savedSlotNum = tonumber(data.SlotNum)
	local sessionSlotNum = tonumber(SlotNumValue.Value)
	if savedSlotNum and sessionSlotNum and savedSlotNum ~= sessionSlotNum then
		-- Critical: never wipe a live save due to SlotNum mismatch. Slot selection can drift across versions.
		warn(string.format(
			"[SlotDataLoader] SlotNum mismatch for %s (Store=%s, Expected=%s). Loading store data without wiping.",
			tostring(key), tostring(savedSlotNum), tostring(sessionSlotNum)
		))
	end

	SlotDataValue:SetAttribute("FreshSave", false)
	SlotDataValue:SetAttribute("CompensationEligible", IsCompensationEligibleForLoadedData(data))
	ALLOW_SLOT_SAVES = true
	local backupData = nil
	local backupKey = nil
	local savedMoney = tonumber(data.Money)
	if savedMoney == nil then
		savedMoney = getDefaultStartingMoney(SlotDataValue:GetAttribute("SandboxMode") == true)
	end
	local savedTickets = tonumber(data.Tickets) or DEFAULT_STARTING_TICKETS
	local savedDay = math.max(1, math.floor(tonumber(data.Day) or 1))
	local savedObjectCount = type(data.Objects) == "table" and #data.Objects or 0
	if savedMoney <= 0 then
		backupData, backupKey = GetBestBackupSnapshot(loadKeys)
		local backupMoney = backupData and tonumber(backupData.Money) or nil
		if backupMoney and backupMoney > savedMoney then
			warn(string.format("[SlotDataLoader] Loaded zero/low balance from %s. Recovering backup balance %s from %s.", tostring(resolvedKey or key), tostring(backupMoney), tostring(backupKey)))
			data = backupData
			savedMoney = math.max(0, math.floor(backupMoney + 0.5))
			savedTickets = tonumber(backupData.Tickets) or savedTickets
			savedDay = math.max(1, math.floor(tonumber(backupData.Day) or savedDay))
			ACTIVE_GAME_DATA_KEY = backupKey or ACTIVE_GAME_DATA_KEY
		end
	end
	if savedMoney <= 0 and (savedObjectCount >= SUSPICIOUS_ZERO_RESTORE_MIN_OBJECTS or savedDay > 1) then
		local fallbackMoney = getDefaultStartingMoney(SlotDataValue:GetAttribute("SandboxMode") == true)
		local recoveredMoney = math.max(fallbackMoney, math.max(tonumber(_lastSavedMoney) or 0, tonumber(backupMoney) or 0))
		warn(string.format("[SlotDataLoader] Suspicious zero balance detected for %s (objects=%d day=%d). Restoring safe fallback %d.", tostring(resolvedKey or key), savedObjectCount, savedDay, recoveredMoney))
		savedMoney = recoveredMoney
		ALLOW_SLOT_SAVES = false
		warn("[SlotDataLoader] Disabled slot saves for this session after suspicious zero-balance recovery to avoid overwriting a healthier backup.")
	end

	local loadedKeyForLog = resolvedKey or key
	warn(string.format(
		"[SlotDataLoader] Loaded slot %s with money=%s tickets=%s objects=%s fresh=%s",
		tostring(loadedKeyForLog),
		tostring(savedMoney),
		tostring(savedTickets),
		tostring(savedObjectCount),
		tostring(SlotDataValue:GetAttribute("FreshSave"))
	))

	local sandboxModeEnabled = SlotDataValue:GetAttribute("SandboxMode") == true
	local startingMoneyFloor = getDefaultStartingMoney(sandboxModeEnabled)
	if sandboxModeEnabled and savedMoney < startingMoneyFloor then
		savedMoney = startingMoneyFloor
	end
	applyEconomySnapshot(savedMoney, savedTickets)
	Lighting:SetAttribute("Day", savedDay)
	setStoredPlayerPreferences(data.PlayerPreferences, true)
	if data.ResortOpen ~= nil or data.ResortAllLights ~= nil or data.ResortInfo ~= nil then
		local mergedPreferences = sanitizePlayerPreferences(PlayerPreferences)
		mergedPreferences.Resort = sanitizeResortPreferences({
			IsOpen = data.ResortOpen,
			AllLights = data.ResortAllLights,
			Info = data.ResortInfo,
		})
		setStoredPlayerPreferences(mergedPreferences, true)
	end
	local applySavedTicketPricing = Events:FindFirstChild("ApplySavedTicketPricing")
	if applySavedTicketPricing and applySavedTicketPricing:IsA("BindableFunction") then
		local ownerPlayer = getOwnerPlayer()
		if ownerPlayer and PlayerPreferences.TicketPricing then
			local ok, err = pcall(function()
				applySavedTicketPricing:Invoke(ownerPlayer, PlayerPreferences.TicketPricing)
			end)
			if not ok then
			end
		end
	end
	if data.ResortName then ResortNameValue.Value = data.ResortName end
	AwardDataLossCompensationIfNeeded(getOwnerPlayer())

	if data.DeletedTrees and #data.DeletedTrees > 0 then
		for _, treeKey in ipairs(data.DeletedTrees) do
			DeletedTreePositions[treeKey] = true
		end
		_G.DeletedTreePositions = DeletedTreePositions

		local treeFolder = workspace:FindFirstChild("TreeFolder")
		if treeFolder then
			local cleaned = 0
			for _, tree in ipairs(treeFolder:GetChildren()) do
				local pos = tree:GetPivot().Position
				if isDeletedTreeBucketMatch(pos.X, pos.Z) then
					tree:Destroy()
					cleaned = cleaned + 1
				end
			end
		end
	end

	finalizeSessionLoad(data.LastPosition)
end

-- // VALIDATE AND DEFAULT SETTINGS //
local MAP_SCALE_MIN = 0.75
local MAP_SCALE_MAX = 2.5
local LEGACY_MAP_SCALE_MODE = "LegacyBoth"

function sanitizeMapScaleMode(value)
	if type(value) ~= "string" then
		return LEGACY_MAP_SCALE_MODE
	end
	if value == LEGACY_MAP_SCALE_MODE or value == "Both" or value == "HeightOnly" or value == "SizeOnly" then
		return value
	end
	local normalized = string.gsub(value, "%s+", "")
	if normalized == "HeightOnly" or normalized == "Height" then
		return "HeightOnly"
	end
	if normalized == "SizeOnly" or normalized == "Size" then
		return "SizeOnly"
	end
	if normalized == "Both" then
		return "Both"
	end
	return LEGACY_MAP_SCALE_MODE
end

function inferUnsignedLongitude(value, latitudeHint)
	local absValue = math.abs(value)
	local absLat = latitudeHint and math.abs(latitudeHint) or nil
	if absValue <= 35 then
		return absValue
	end
	if absValue >= 125 then
		return absValue
	end
	if absLat and absLat < 10 then
		return absValue
	end
	return -absValue
end

function sanitizeCoordinateValue(rawValue, axis, latitudeHint)
	if rawValue == nil then
		return nil
	end

	local hasNorth = false
	local hasSouth = false
	local hasEast = false
	local hasWest = false
	local value = nil

	if type(rawValue) == "number" then
		value = rawValue
	else
		local rawText = tostring(rawValue):match("^%s*(.-)%s*$")
		if rawText == "" then
			return nil
		end

		local upper = string.upper(rawText):gsub(",", ".")
		hasNorth = upper:find("N", 1, true) ~= nil
		hasSouth = upper:find("S", 1, true) ~= nil
		hasEast = upper:find("E", 1, true) ~= nil
		hasWest = upper:find("W", 1, true) ~= nil
		local cleaned = upper:gsub("°", ""):gsub("[NSEW]", ""):gsub("%s+", "")
		value = tonumber(cleaned)
	end

	if not value or value ~= value or value == math.huge or value == -math.huge then
		return nil
	end

	if axis == "Latitude" then
		if hasSouth then
			value = -math.abs(value)
		elseif hasNorth then
			value = math.abs(value)
		end
		return math.clamp(value, -90, 90)
	end

	if hasEast then
		value = math.abs(value)
	elseif hasWest then
		value = -math.abs(value)
	end

	return math.clamp(value, -180, 180)
end

function validateSettings(settings)
	if not settings then
		settings = {}
	end

	settings.Latitude = sanitizeCoordinateValue(settings.Latitude, "Latitude")
	settings.Longitude = sanitizeCoordinateValue(settings.Longitude, "Longitude", settings.Latitude)

	local validDensities = {None=true, Low=true, Medium=true, High=true, Ultra=true, Insane=true, Extreme=true, GameBreaking=true}
	if not settings.TreeDensity or not validDensities[settings.TreeDensity] then
		settings.TreeDensity = "High"
	end

	local validStyles = {Regular=true, Realistic=true}
	if not settings.TreeStyle or not validStyles[settings.TreeStyle] then
		settings.TreeStyle = "Regular"
	end

	if settings.ElevationFalloff == nil then
		settings.ElevationFalloff = true
	end

	local mapScale = tonumber(settings.MapScale)
	if not mapScale or mapScale ~= mapScale or mapScale == math.huge or mapScale == -math.huge then
		mapScale = 1
	end
	settings.MapScale = math.clamp(mapScale, MAP_SCALE_MIN, MAP_SCALE_MAX)
	if settings.MapScaleMode == nil or settings.MapScaleMode == "" then
		settings.MapScaleMode = "HeightOnly"
	else
		settings.MapScaleMode = sanitizeMapScaleMode(settings.MapScaleMode)
	end

	local normalizedCreatedTime = normalizeSessionCreatedTime(settings.CreatedTime)
	if not normalizedCreatedTime then
		normalizedCreatedTime = normalizeSessionCreatedTime(SlotCreatedTime.Value) or os.time()
	end
	settings.CreatedTime = normalizedCreatedTime

	local normalizedSeed = tonumber(settings.Seed)
	if normalizedSeed and normalizedSeed == normalizedSeed and normalizedSeed ~= math.huge and normalizedSeed ~= -math.huge then
		settings.Seed = math.max(1, math.floor(normalizedSeed + 0.5))
	else
		-- Legacy saves can be missing Seed; fall back to the stable slot CreatedTime instead
		-- of minting a brand-new random world every time the save is restored.
		settings.Seed = normalizedCreatedTime
	end

	return settings
end

function readTeleportNumber(teleportData, keys)
	if type(teleportData) ~= "table" then
		return nil
	end
	for _, key in ipairs(keys) do
		local value = tonumber(teleportData[key])
		if value and value > 0 then
			return math.floor(value + 0.5)
		end
	end
	return nil
end

-- // START GAME LOGIC //
function beginGameDataLoad(teleportCreatedTime)
	if HAS_STARTED_GAME_DATA_LOAD then
		return false
	end
	HAS_STARTED_GAME_DATA_LOAD = true
	LoadGameData(teleportCreatedTime)
	return true
end

function recoverStuckWorldLoad(reason)
	if WORLD_SESSION_READY then
		return false
	end

	warn("[SlotDataLoader] " .. tostring(reason))

	if not HAS_STARTED_GAME_DATA_LOAD then
		local owner = Players:GetPlayerByUserId(UserIdValue.Value)
		if owner and owner.Parent == Players then
			LoadingUpdate:FireClient(owner, "Load stalled. Recovering save data...", 4, 88)
		end
		return beginGameDataLoad(SlotCreatedTime.Value)
	end

	local currentMoney, currentTickets = getHydratedEconomySnapshot()
	if currentMoney == nil or currentTickets == nil then
		applyEconomySnapshot(DEFAULT_STARTING_MONEY, DEFAULT_STARTING_TICKETS)
	end

	WORLD_RESTORE_FLOW_STARTED = true
	WORLD_SESSION_READY = true
	_G.SessionFullyReady = true
	_G.WorldFullyReady = true
	_G.TerrainReady = true
	_G.TerrainSettled = true
	_G.TerrainWriteInProgress = false
	-- Do NOT force TerrainStoreRestoreReady / BuildingStoreRestoreReady here.
	-- Those flags must reflect real store work; faking them causes partial terrain/slope/lift/building restores.

	for _, targetPlayer in ipairs(Players:GetPlayers()) do
		setPlayerLoadLock(targetPlayer, false)
		LoadingUpdate:FireClient(targetPlayer, "Loading complete!", 5, 100)
	end

	return true
end

function InitializePlayer(player)
	setPlayerPreferencesReady(player, false)
	loadWaypointPreferencesForPlayer(player)

	if WORLD_SESSION_READY then
		setPlayerLoadLock(player, false)
	else
		setPlayerLoadLock(player, true)
	end

	local slotNum = 0
	local ownerId = player.UserId
	local isOwner = false
	local teleportData = nil
	local teleportCreatedTime = 0
	local settings = nil
	local hadExplicitOwnerData = false

	if IS_STUDIO then
		slotNum = STUDIO_TEST_SLOT
		isOwner = true
	else
		local joinData = player:GetJoinData()
		teleportData = joinData.TeleportData

		if teleportData then
			local teleportedSlotNum = readTeleportNumber(teleportData, {"SlotNum", "slotNum", "CurrentSlot", "currentSlot", "ActiveSlot", "activeSlot", "Slot", "slot", "SelectedSlot", "selectedSlot"})
			if not teleportedSlotNum and type(teleportData.Settings) == "table" then
				teleportedSlotNum = readTeleportNumber(teleportData.Settings, {"SlotNum", "slotNum", "CurrentSlot", "currentSlot", "ActiveSlot", "activeSlot"})
			end
			if teleportedSlotNum then
				slotNum = teleportedSlotNum
			end

			local teleportedOwnerId = readTeleportNumber(teleportData, {"UserId", "userId", "OwnerUserId", "ownerUserId", "OwnerId", "ownerId", "HostUserId", "hostUserId", "HostId", "hostId"})
			if not teleportedOwnerId and type(teleportData.Settings) == "table" then
				teleportedOwnerId = readTeleportNumber(teleportData.Settings, {"UserId", "userId", "OwnerUserId", "ownerUserId", "OwnerId", "ownerId"})
			end
			if teleportedOwnerId then
				hadExplicitOwnerData = true
				ownerId = teleportedOwnerId
				isOwner = (ownerId == player.UserId)
			end

			if teleportData.ResortName then
				ResortNameValue.Value = teleportData.ResortName
			end

			if teleportData.Settings then
				settings = teleportData.Settings
				if settings.CreatedTime and settings.CreatedTime > 0 then
					teleportCreatedTime = settings.CreatedTime
				end
			end

			if teleportData.SandboxMode ~= nil then
				if not settings then settings = {} end
				settings.SandboxMode = teleportData.SandboxMode
			end

			if teleportCreatedTime == 0 and teleportData.CreatedTime then
				teleportCreatedTime = teleportData.CreatedTime
			elseif teleportCreatedTime == 0 and teleportData.Timestamp then
				teleportCreatedTime = teleportData.Timestamp
			end
		else
			if (tonumber(SlotNumValue.Value) or 0) == 0 then
				warn("[SlotDataLoader] Missing TeleportData for initial live join. Refusing to assume slot 1.")
				setPlayerLoadLock(player, true)
				LoadingUpdate:FireClient(player, "Missing slot data from lobby. Please rejoin from the lobby.", 4, 0)
				task.delay(3, function()
					if player and player.Parent == Players then
						player:Kick("Missing slot data from lobby. Please rejoin through the lobby.")
					end
				end)
				return
			else
				slotNum = tonumber(SlotNumValue.Value) or 0
			end
		end

		if (tonumber(SlotNumValue.Value) or 0) == 0 and slotNum <= 0 then
			warn("[SlotDataLoader] Missing SlotNum in TeleportData for initial live join. Refusing to assume slot 1.")
			setPlayerLoadLock(player, true)
			LoadingUpdate:FireClient(player, "Missing slot number from lobby. Please rejoin from the lobby.", 4, 0)
			task.delay(3, function()
				if player and player.Parent == Players then
					player:Kick("Missing slot number from lobby. Please rejoin through the lobby.")
				end
			end)
			return
		elseif slotNum <= 0 then
			slotNum = tonumber(SlotNumValue.Value) or 0
		end

		if slotNum > 0 then
			-- Use EffectiveMaxSlots attribute if set by SlotPurchaseHandler (extra slot purchases),
			-- otherwise fall back to the hard-coded MAX_SAVE_SLOT_INDEX constant.
			local effectiveMax = tonumber(player:GetAttribute("EffectiveMaxSlots")) or MAX_SAVE_SLOT_INDEX
			slotNum = math.clamp(math.floor((tonumber(slotNum) or 0) + 0.5), 1, effectiveMax)
		end

		-- If the server is unclaimed but we have a valid slot, force the first entrant
		-- to start the session to avoid the "Joining Session" dead-state.
		if SlotNumValue.Value == 0 and slotNum > 0 and not isOwner then
			if not hadExplicitOwnerData then
				ownerId = player.UserId
			end
			isOwner = true
			warn(string.format("[SlotDataLoader] Promoted first player %s as session host for slot %s (owner=%s)", player.Name, tostring(slotNum), tostring(ownerId)))
		end
	end

	-- GUARD: Once slot ownership is claimed, never allow late joiners to re-initialize it.
	-- This prevents a joining player (whose TeleportData has their own UserId)
	-- from overwriting the host's world with their own slot data during early startup.
	local serverAlreadyInitialized = (tonumber(SlotNumValue.Value) or 0) > 0 and (tonumber(UserIdValue.Value) or 0) > 0
	if serverAlreadyInitialized and not IS_STUDIO then
		isOwner = false
	end

	if not serverAlreadyInitialized then
		SlotNumValue.Value = slotNum
		UserIdValue.Value = ownerId
		SlotCreatedTime.Value = teleportCreatedTime
		ACTIVE_GAME_DATA_KEY = nil
		ALLOW_SLOT_SAVES = false
		player:SetAttribute("IsOwner", true)
		player:SetAttribute("SlotNum", slotNum)

		if not settings then
			settings = {
				Latitude              = nil,
				Longitude             = nil,
				TreeDensity           = "High",
				TreeStyle             = "Regular",
				SnowTreesEnabled      = true,
				SnowTrees             = true,
				ElevationFalloff      = true,
				HeightScaleMultiplier = "Default",
				MapSize               = "Default",
				NoiseIntensity        = "Normal",
				RiverMode             = false,
				SandboxMode           = false,
				MapScale              = 1,
				MapScaleMode          = "HeightOnly",
				Seed                  = math.random(1, 999999),
				CreatedTime           = teleportCreatedTime
			}
		end

		settings = validateSettings(settings)
		local sandboxModeEnabled = settings.SandboxMode == true
		SlotDataValue:SetAttribute("SandboxMode", sandboxModeEnabled)
		SlotDataValue:SetAttribute("MapScale", settings.MapScale)
		SlotDataValue:SetAttribute("MapScaleMode", settings.MapScaleMode)
		player:SetAttribute("SandboxMode", sandboxModeEnabled)
		player:SetAttribute("MapScale", settings.MapScale)
		player:SetAttribute("MapScaleMode", settings.MapScaleMode)

		if GenerateWorldEvent then
			if EXPECT_TERRAINSTORE_READY then
				_G.TerrainStoreRestoreReady = false
				_G.TerrainRestoreActionCount = 0
			end
			if EXPECT_BUILDINGSTORE_READY then
				_G.BuildingStoreRestoreReady = false
				_G.BuildingRestoreItemCount = 0
			end
			WORLD_SESSION_READY = false
			WORLD_RESTORE_FLOW_STARTED = false

			LoadingUpdate:FireClient(player, "Starting Terrain Gen...", 1, 10)

			if not fireGenerateWorld(player, settings) then
				LoadingUpdate:FireClient(player, "World generation setup error. Forcing save-data restore.", 4, 90)
				beginGameDataLoad(SlotCreatedTime.Value)
			end
			task.delay(WORLD_LOAD_FAILSAFE_TIMEOUT, function()
				if player and player.Parent == Players and player:GetAttribute("IsOwner") == true and not WORLD_SESSION_READY then
					recoverStuckWorldLoad("Owner session load watchdog exceeded failsafe timeout.")
				end
			end)
		else
			LoadingUpdate:FireClient(player, "World generation event missing. Forcing save-data restore.", 4, 90)
			beginGameDataLoad(SlotCreatedTime.Value)
		end
	else
		player:SetAttribute("IsOwner", false)
		player:SetAttribute("SlotNum", SlotNumValue.Value)
		player:SetAttribute("SandboxMode", SlotDataValue:GetAttribute("SandboxMode") == true)
		applyPlayerPreferencesToPlayer(player, buildDefaultPlayerPreferences())
		if WORLD_SESSION_READY then
			LoadingUpdate:FireClient(player, "Session ready!", 5, 100)
			setPlayerLoadLock(player, false)
		else
			LoadingUpdate:FireClient(player, "Joining Session...", 1, 50)
		end
	end
end

local STALE_TERRAIN_READY_WARNED = false

function isTerrainReadyForRestoreFlow()
	if (_G.TerrainSettled == true) and (_G.TerrainWriteInProgress ~= true) then
		return true
	end

	if getWorldGenerationStatus() == "ready" and (_G.TerrainWriteInProgress ~= true) then
		if not STALE_TERRAIN_READY_WARNED then
			STALE_TERRAIN_READY_WARNED = true
			warn("[SlotDataLoader] World generation is ready but TerrainSettled is stale. Proceeding with restore flow.")
		end
		return true
	end

	return false
end

function startRestoreFlow()
	if WORLD_RESTORE_FLOW_STARTED or WORLD_SESSION_READY then return end
	if not isTerrainReadyForRestoreFlow() then
		task.defer(function()
			local timeoutAt = tick() + 120
			while not isTerrainReadyForRestoreFlow() and tick() < timeoutAt do
				task.wait(0.25)
			end
			if WORLD_RESTORE_FLOW_STARTED or WORLD_SESSION_READY then return end
			if not isTerrainReadyForRestoreFlow() then
				local owner = Players:GetPlayerByUserId(UserIdValue.Value)
				if owner then
					LoadingUpdate:FireClient(owner, "Terrain scan stalled. Recovering save data...", 4, 72)
				end
				recoverStuckWorldLoad("Terrain restore flow timed out waiting for terrain readiness.")
				return
			end
			WORLD_RESTORE_FLOW_STARTED = true
			local owner = Players:GetPlayerByUserId(UserIdValue.Value)
			if owner then
				LoadingUpdate:FireClient(owner, "Terrain generated. Restoring saved world...", 3, 55)
			end
			waitForRestoreSystems(owner)
			beginGameDataLoad(SlotCreatedTime.Value)
		end)
		return
	end
	WORLD_RESTORE_FLOW_STARTED = true

	local owner = Players:GetPlayerByUserId(UserIdValue.Value)
	if owner then
		LoadingUpdate:FireClient(owner, "Terrain generated. Restoring saved world...", 3, 55)
	end

	waitForRestoreSystems(owner)
	beginGameDataLoad(SlotCreatedTime.Value)
end

if TerrainReadyEvent then
	TerrainReadyEvent.Event:Connect(startRestoreFlow)
end

task.delay(3, function()
	if not WORLD_SESSION_READY and not WORLD_RESTORE_FLOW_STARTED and isTerrainReadyForRestoreFlow() then
		startRestoreFlow()
	end
end)

Players.PlayerAdded:Connect(InitializePlayer)
for _, p in ipairs(Players:GetPlayers()) do 
	task.spawn(function() InitializePlayer(p) end) 
end

Players.PlayerRemoving:Connect(function(player)
	if LOCK_CONNECTIONS[player] then
		LOCK_CONNECTIONS[player]:Disconnect()
		LOCK_CONNECTIONS[player] = nil
	end
	if player.UserId == UserIdValue.Value then
		pcall(runSubsystemSaves)
	end
	if DirtyWaypointPreferenceUsers[player.UserId] then
		flushWaypointPreferencesNow(player.UserId)
	end
end)

task.spawn(function() 
	-- Offset slot autosaves from terrain autosaves to reduce DataStore queue bursts.
	task.wait(math.max(15, math.floor(AUTOSAVE_INTERVAL * 0.45)))
	while true do 
		task.wait(AUTOSAVE_INTERVAL)
		if _G.CoordinatedSaveInProgress ~= true then
			SaveGameData() 
		end
	end 
end)

-- CRITICAL: Keep server alive on shutdown to finish saving.
-- Without this, DataStore writes from PlayerRemoving can be cut short,
-- causing money/progress loss on AFK-kick or server cycling.
game:BindToClose(function()
	pcall(runSubsystemSaves)
	for _, player in ipairs(Players:GetPlayers()) do
		if DirtyWaypointPreferenceUsers[player.UserId] then
			flushWaypointPreferencesNow(player.UserId)
		end
	end
	-- Give DataStore writes time to complete
	task.wait(3)
end)

task.spawn(function()
	task.wait(WORLD_LOAD_SOFT_TIMEOUT)
	while not WORLD_SESSION_READY do
		local generationStatus = getWorldGenerationStatus()
		local generationElapsed = getWorldGenerationElapsed()
		local generationElapsedText = generationElapsed and string.format("%.1f", generationElapsed) or "unknown"

		if not WORLD_RESTORE_FLOW_STARTED and generationStatus == "ready" then
			if isTerrainReadyForRestoreFlow() then
				warn(string.format("[SlotDataLoader] World load watchdog observed ready terrain after %ss. Starting restore flow.", generationElapsedText))
				startRestoreFlow()
			else
				warn(string.format("[SlotDataLoader] World load soft-timeout (%ds). Generation is ready after %ss but terrain has not settled yet, extending watchdog.", WORLD_LOAD_SOFT_TIMEOUT, generationElapsedText))
			end
			task.wait(WORLD_LOAD_TIMEOUT_POLL)
		elseif isWorldGenerationActive() and (generationElapsed == nil or generationElapsed < WORLD_LOAD_HARD_TIMEOUT) then
			warn(string.format("[SlotDataLoader] World load soft-timeout (%ds). Generation still %s after %ss, extending watchdog.", WORLD_LOAD_SOFT_TIMEOUT, generationStatus, generationElapsedText))
			task.wait(WORLD_LOAD_TIMEOUT_POLL)
		else
			if not workspace:FindFirstChild("StartSpawn") then
				movePlayersToEmergencyRespawn()
			end
			if not HAS_STARTED_GAME_DATA_LOAD then
				warn(string.format("[SlotDataLoader] World load timeout. Generation status=%s elapsed=%ss. Forcing immediate save-data restore.", generationStatus, generationElapsedText))
				beginGameDataLoad(SlotCreatedTime.Value)
				return
			end
			warn(string.format("[SlotDataLoader] World load timeout. Generation status=%s elapsed=%ss. Force-unlocking players.", generationStatus, generationElapsedText))
			_G.WorldFullyReady = true
			_G.SessionFullyReady = true
			finalizeSessionLoad(nil)
			return
		end
	end
end)

RequestSave.OnInvoke = function()
	local report = runSubsystemSaves()
	return report.success == true
end