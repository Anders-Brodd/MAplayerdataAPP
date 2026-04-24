--[=[ PATH: StarterPlayerScripts/SettingsController | TYPE: LocalScript ]=]--
--[[
	⚙️ SETTINGS CONTROLLER V5 — FULL OPTIMIZATION SUITE
	
	All settings actually work. UI matches Studio-built pill-toggle theme.
	Potato mode turns everything off at once for lowest-end devices.
]]

local Players = game:GetService("Players")
local Lighting = game:GetService("Lighting")
local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")
local LocalizationService = game:GetService("LocalizationService")
local TeleportService = game:GetService("TeleportService")
local MarketplaceService = game:GetService("MarketplaceService")
local Stats = game:GetService("Stats")

local Player = Players.LocalPlayer
local PlayerGui = Player:WaitForChild("PlayerGui")
local PlayerScripts = Player:WaitForChild("PlayerScripts")
local Events = ReplicatedStorage:WaitForChild("Events")
local PreferenceSync = Events:WaitForChild("PlayerPreferenceSync", 10)

-- Friend whitelist remotes (created by SlotPurchaseHandler)
local RequestFriendWhitelist = Events:WaitForChild("RequestFriendWhitelist", 10)
local UpdateFriendWhitelist  = Events:WaitForChild("UpdateFriendWhitelist", 10)
local SlotPurchaseUpdate     = Events:WaitForChild("SlotPurchaseUpdate", 10)
local ADD_FRIEND_SLOT_PRODUCT_ID = 3575008862

local hydratedPreferencePayload = nil
local hydratedSettings = nil
local hydratedMultiplayer = nil
local pendingSettingsSync = {}
local settingsSyncQueued = false
local pendingMultiplayerSync = nil
local multiplayerSyncQueued = false
local manualSaveBusy = false
local lastManualSaveAt = 0
local MANUAL_SAVE_LOCAL_COOLDOWN = 8
local LOBBY_PLACE_ID = 112432334473369

local DEFAULT_MULTIPLAYER = {
	TrustedBuild = true,
	TrustedDelete = true,
	TrustedUseOwnerResearch = true,
	VisitorBuild = false,
	VisitorDelete = false,
	TrustedUserIds = {},
}

local function releaseFocusedTextBox()
	local focused = UserInputService:GetFocusedTextBox()
	if focused then
		pcall(function()
			focused:ReleaseFocus()
		end)
	end
end

local function copySequentialArray(list)
	local out = {}
	if type(list) == "table" then
		for index, value in ipairs(list) do
			out[index] = value
		end
	end
	return out
end

local function sanitizeMultiplayerState(raw)
	local state = {
		TrustedBuild = DEFAULT_MULTIPLAYER.TrustedBuild,
		TrustedDelete = DEFAULT_MULTIPLAYER.TrustedDelete,
		TrustedUseOwnerResearch = DEFAULT_MULTIPLAYER.TrustedUseOwnerResearch,
		VisitorBuild = DEFAULT_MULTIPLAYER.VisitorBuild,
		VisitorDelete = DEFAULT_MULTIPLAYER.VisitorDelete,
		TrustedUserIds = {},
	}
	if type(raw) == "table" then
		for key, defaultValue in pairs(DEFAULT_MULTIPLAYER) do
			if key ~= "TrustedUserIds" and type(defaultValue) == "boolean" and type(raw[key]) == "boolean" then
				state[key] = raw[key]
			end
		end
		local seen = {}
		for _, rawUserId in ipairs(raw.TrustedUserIds or {}) do
			local userId = tonumber(rawUserId)
			if userId and userId > 0 and not seen[userId] then
				seen[userId] = true
				table.insert(state.TrustedUserIds, userId)
			end
		end
		table.sort(state.TrustedUserIds)
	end
	return state
end

local function fetchPreferencePayload()
	if PreferenceSync and PreferenceSync:IsA("RemoteFunction") then
		local ok, result = pcall(function()
			return PreferenceSync:InvokeServer("Get")
		end)
		if ok and type(result) == "table" then
			return result
		end
	end
	return nil
end

local function flushPendingSettingSync()
	if next(pendingSettingsSync) == nil then
		return
	end
	if not (PreferenceSync and PreferenceSync:IsA("RemoteFunction")) then
		return
	end
	local payload = pendingSettingsSync
	pendingSettingsSync = {}
	task.spawn(function()
		local ok = pcall(function()
			PreferenceSync:InvokeServer("SetSettings", payload)
		end)
		if not ok then
			for key, value in pairs(payload) do
				pendingSettingsSync[key] = value
			end
			if not settingsSyncQueued then
				settingsSyncQueued = true
				task.delay(0.5, function()
					settingsSyncQueued = false
					flushPendingSettingSync()
				end)
			end
		end
	end)
end

local function queueSettingPreferenceSave(key, value)
	pendingSettingsSync[key] = value
	if settingsSyncQueued then
		return
	end
	settingsSyncQueued = true
	task.delay(0.05, function()
		settingsSyncQueued = false
		flushPendingSettingSync()
	end)
end

local function flushPendingMultiplayerSync()
	if pendingMultiplayerSync == nil then
		return
	end
	if not (PreferenceSync and PreferenceSync:IsA("RemoteFunction")) then
		return
	end
	local payload = pendingMultiplayerSync
	pendingMultiplayerSync = nil
	task.spawn(function()
		pcall(function()
			PreferenceSync:InvokeServer("SetMultiplayer", payload)
		end)
	end)
end

local function queueMultiplayerPreferenceSave(state)
	pendingMultiplayerSync = sanitizeMultiplayerState(state)
	if multiplayerSyncQueued then
		return
	end
	multiplayerSyncQueued = true
	task.delay(0.15, function()
		multiplayerSyncQueued = false
		flushPendingMultiplayerSync()
	end)
end

local function requestManualSave()
	if manualSaveBusy then
		return false, "SAVE IN PROGRESS"
	end

	local now = os.clock()
	local remaining = MANUAL_SAVE_LOCAL_COOLDOWN - (now - lastManualSaveAt)
	if remaining > 0 then
		return false, string.format("WAIT %ds", math.ceil(remaining))
	end

	if not (PreferenceSync and PreferenceSync:IsA("RemoteFunction")) then
		return false, "SAVE SERVICE OFFLINE"
	end

	manualSaveBusy = true
	local ok, response = pcall(function()
		return PreferenceSync:InvokeServer("ManualSave")
	end)
	manualSaveBusy = false

	if not ok then
		return false, "SAVE ERROR"
	end

	if type(response) == "table" then
		if response.success == true then
			lastManualSaveAt = os.clock()
			return true, "SAVED"
		end
		if type(response.message) == "string" and response.message ~= "" then
			return false, string.upper(response.message)
		end
		return false, "SAVE FAILED"
	end
	if response == true then
		lastManualSaveAt = os.clock()
		return true, "SAVED"
	end
	return false, "SAVE FAILED"
end

--------------------------------------------------------------------------------
-- THEME COLORS (match Studio-built UI exactly)
--------------------------------------------------------------------------------
local THEME = {
	RowBg         = Color3.fromRGB(17, 19, 24),     -- 0.067, 0.075, 0.094
	RowCorner     = UDim.new(0.4, 0),
	ToggleOnBg    = Color3.fromRGB(0, 120, 215),     -- Blue ON
	ToggleOffBg   = Color3.fromRGB(60, 60, 70),      -- Grey OFF
	ToggleCorner  = UDim.new(0.35, 0),
	ToggleSize    = UDim2.new(0.194, 0, 0.717, 0),
	TogglePos     = UDim2.new(0.79, 0, 0.5, 0),
	LabelColor    = Color3.fromRGB(240, 240, 240),
	LabelFont     = Enum.Font.GothamBold,
	LabelSize     = 16,
	SubLabelColor = Color3.fromRGB(150, 150, 150),
	SubLabelFont  = Enum.Font.Gotham,
	SubLabelSize  = 11,
	SectionColor  = Color3.fromRGB(200, 200, 200),
	SectionFont   = Enum.Font.GothamBlack,
	SectionSize   = 13,
}

--------------------------------------------------------------------------------
-- SETTINGS STATE (persisted via Player attributes → SlotDataLoader auto-saves)
--------------------------------------------------------------------------------
local SETTINGS_ATTR_PREFIX = "Settings_"

-- Load saved settings from hydrated server preferences first, then player attributes.
local function loadSavedSetting(key, default)
	if hydratedSettings ~= nil then
		local hydratedValue = hydratedSettings[key]
		if type(hydratedValue) == "boolean" then
			return hydratedValue
		end
	end
	local attr = Player:GetAttribute(SETTINGS_ATTR_PREFIX .. key)
	if attr ~= nil then return attr end
	return default
end

local function loadSavedNumberSetting(key, default, minValue, maxValue)
	if hydratedSettings ~= nil then
		local hydratedValue = tonumber(hydratedSettings[key])
		if hydratedValue ~= nil then
			return math.clamp(math.floor(hydratedValue + 0.5), minValue, maxValue)
		end
	end
	local attr = tonumber(Player:GetAttribute(SETTINGS_ATTR_PREFIX .. key))
	if attr ~= nil then
		return math.clamp(math.floor(attr + 0.5), minValue, maxValue)
	end
	return default
end

local function normalizeUnitSystem(value)
	if type(value) ~= "string" then
		return "Imperial"
	end
	return string.lower(value) == "metric" and "Metric" or "Imperial"
end

local function getLocaleDefaultUnitSystem()
	local localeId = nil
	pcall(function()
		localeId = LocalizationService.SystemLocaleId
	end)
	if type(localeId) ~= "string" or localeId == "" then
		pcall(function()
			localeId = LocalizationService.RobloxLocaleId
		end)
	end
	if type(localeId) ~= "string" or localeId == "" then
		localeId = Player.LocaleId
	end
	local regionCode = type(localeId) == "string" and string.match(string.upper(localeId), "%-([A-Z][A-Z])$") or nil
	if regionCode == "US" or regionCode == "LR" or regionCode == "MM" then
		return "Imperial"
	end
	return "Metric"
end

local function loadSavedStringSetting(key, default)
	if hydratedSettings ~= nil and hydratedSettings[key] ~= nil then
		return normalizeUnitSystem(hydratedSettings[key])
	end
	local attr = Player:GetAttribute(SETTINGS_ATTR_PREFIX .. key)
	if attr ~= nil then
		return normalizeUnitSystem(attr)
	end
	return normalizeUnitSystem(default)
end

local function normalizeChoiceSetting(value, allowedValues, defaultValue)
	if type(value) ~= "string" then
		return defaultValue
	end
	for _, allowed in ipairs(allowedValues) do
		if value == allowed then
			return value
		end
	end
	return defaultValue
end

local function loadSavedChoiceSetting(key, defaultValue, allowedValues)
	if hydratedSettings ~= nil and hydratedSettings[key] ~= nil then
		return normalizeChoiceSetting(hydratedSettings[key], allowedValues, defaultValue)
	end
	local attr = Player:GetAttribute(SETTINGS_ATTR_PREFIX .. key)
	if attr ~= nil then
		return normalizeChoiceSetting(attr, allowedValues, defaultValue)
	end
	return defaultValue
end

local function sanitizeGuestCapValue(value)
	local numericValue = tonumber(value)
	if numericValue == nil then
		return 0
	end
	return math.clamp(math.floor(numericValue + 0.5), 0, 5000)
end

local SETTINGS = {
	Music       = loadSavedSetting("Music", true),
	Weather     = loadSavedSetting("Weather", true),
	Shadows     = loadSavedSetting("Shadows", true),
	Particles   = loadSavedSetting("Particles", true),
	GraphicsPreset = loadSavedChoiceSetting("GraphicsPreset", "Medium", {"Low", "Medium", "High", "Ultra"}),
	BuildingRenderDistance = loadSavedChoiceSetting("BuildingRenderDistance", "Medium", {"Near", "Medium", "Far", "Off"}),
	LiftRenderDistance = loadSavedChoiceSetting("LiftRenderDistance", "Medium", {"Near", "Medium", "Far", "Off"}),
	NPCRenderDistance = loadSavedChoiceSetting("NPCRenderDistance", "Medium", {"Near", "Medium", "Far", "Off"}),
	WeatherQuality = loadSavedChoiceSetting("WeatherQuality", "High", {"Low", "Medium", "High", "Ultra"}),
	ParticleQuality = loadSavedChoiceSetting("ParticleQuality", "High", {"Low", "Medium", "High", "Ultra"}),
	ParticleDensity = loadSavedChoiceSetting("ParticleDensity", "Medium", {"Low", "Medium", "High", "Ultra"}),
	RealisticParticles = loadSavedSetting("RealisticParticles", true),
	AdaptiveParticles = loadSavedSetting("AdaptiveParticles", true),
	FogEdgeBlend = loadSavedSetting("FogEdgeBlend", true),
	FogEdgeIntensity = loadSavedChoiceSetting("FogEdgeIntensity", "Medium", {"Low", "Medium", "High"}),
	Trees       = loadSavedSetting("Trees", true),
	GuestModels = loadSavedSetting("GuestModels", true),
	Atmosphere  = loadSavedSetting("Atmosphere", true),
	SunRays     = loadSavedSetting("SunRays", true),
	Bloom       = loadSavedSetting("Bloom", true),
	Decorations = loadSavedSetting("Decorations", true),
	GuestLOD    = loadSavedSetting("GuestLOD", false),
	GuestPerformanceMode = loadSavedChoiceSetting("GuestPerformanceMode", "Off", {"Off", "Balanced", "Aggressive", "Extreme"}),
	SlopeDifficulty = loadSavedSetting("SlopeDifficulty", false),
	FPSCounter  = loadSavedSetting("FPSCounter", false),
	ShowMobileSkiButton = loadSavedSetting("ShowMobileSkiButton", true),
	UnitSystem  = loadSavedStringSetting("UnitSystem", getLocaleDefaultUnitSystem()),
	MaxGuestCap = 0,
	MaxGuestCapEnabled = loadSavedSetting("MaxGuestCapEnabled", false),
}

local MULTIPLAYER = sanitizeMultiplayerState(hydratedMultiplayer)

local SETTINGS_VISUAL_KEY_OVERRIDES = {
	SlopeDifficultyOverlay = "SlopeDifficulty",
	ShowFPSCounter = "FPSCounter",
	AdaptiveParticleBudget = "AdaptiveParticles",
}

local function refreshSettingsUiFromState()
	local mainHud = PlayerGui:FindFirstChild("MainHUD")
	local frame = mainHud and mainHud:FindFirstChild("SettingsFrame")
	if not frame then
		return
	end
	local content = frame:FindFirstChild("Content")
	if not content then
		return
	end

	for _, row in ipairs(content:GetChildren()) do
		if row:IsA("GuiObject") then
			local settingKey = SETTINGS_VISUAL_KEY_OVERRIDES[row.Name] or row.Name
			local settingValue = SETTINGS[settingKey]
			if settingValue ~= nil then
				local toggle = row:FindFirstChild("Toggle")
				if toggle and toggle:IsA("TextButton") and type(settingValue) == "boolean" then
					toggle.Text = settingValue and "ON" or "OFF"
					toggle.BackgroundColor3 = settingValue and THEME.ToggleOnBg or THEME.ToggleOffBg
				end
				local choice = row:FindFirstChild("Choice")
				if choice and choice:IsA("TextButton") and type(settingValue) == "string" then
					choice.Text = string.upper(settingValue)
				end
			end
		end
	end
end

local function applyHydratedSettingsPayload(payload)
	if not (payload and type(payload.Settings) == "table") then
		return false
	end
	local payloadSettings = payload.Settings
	hydratedPreferencePayload = payload
	hydratedSettings = payloadSettings
	for key, value in pairs(payloadSettings) do
		if SETTINGS[key] ~= nil then
			if type(SETTINGS[key]) == "boolean" and type(value) == "boolean" then
				SETTINGS[key] = value
				Player:SetAttribute(SETTINGS_ATTR_PREFIX .. key, value)
			elseif type(SETTINGS[key]) == "number" and tonumber(value) ~= nil then
				local sanitizedValue = sanitizeGuestCapValue(value)
				SETTINGS[key] = sanitizedValue
				Player:SetAttribute(SETTINGS_ATTR_PREFIX .. key, sanitizedValue)
			elseif type(SETTINGS[key]) == "string" and type(value) == "string" then
				local sanitizedValue = (key == "UnitSystem") and normalizeUnitSystem(value) or value
				SETTINGS[key] = sanitizedValue
				Player:SetAttribute(SETTINGS_ATTR_PREFIX .. key, sanitizedValue)
			end
		end
	end
	Player:SetAttribute("GuestCap", sanitizeGuestCapValue(SETTINGS.MaxGuestCap))
	Player:SetAttribute("GuestCapEnabled", SETTINGS.MaxGuestCapEnabled == true)
	Player:SetAttribute(SETTINGS_ATTR_PREFIX .. "UnitSystem", SETTINGS.UnitSystem)
	if type(payload.Multiplayer) == "table" then
		hydratedMultiplayer = sanitizeMultiplayerState(payload.Multiplayer)
		MULTIPLAYER = sanitizeMultiplayerState(hydratedMultiplayer)
	end
	task.defer(refreshSettingsUiFromState)
	return true
end

local trackSlopeDifficultySignsForModel
local refreshSlopeDifficultyOverlay

task.defer(function()
	for _ = 1, 6 do
		if applyHydratedSettingsPayload(fetchPreferencePayload()) then
			break
		end
		task.wait(1)
	end
end)

-- Save a setting locally and enqueue a server-backed preference sync.
local function saveSetting(key, value)
	Player:SetAttribute(SETTINGS_ATTR_PREFIX .. key, value)
	queueSettingPreferenceSave(key, value)
end

Player:SetAttribute("GuestCap", sanitizeGuestCapValue(SETTINGS.MaxGuestCap))
Player:SetAttribute("GuestCapEnabled", SETTINGS.MaxGuestCapEnabled == true)

task.defer(function()
	local placedObjects = workspace:WaitForChild("PlacedObjects", 30)
	if not placedObjects then
		return
	end
	local function handlePotentialSlopeModel(child)
		if child:IsA("Model") and child:GetAttribute("Type") == "Slope" then
			trackSlopeDifficultySignsForModel(child)
			refreshSlopeDifficultyOverlay()
		end
	end
	placedObjects.ChildAdded:Connect(handlePotentialSlopeModel)
	-- DescendantAdded removed: ChildAdded above fires once per model (was N times per part)
	for _, child in ipairs(placedObjects:GetDescendants()) do
		if child:IsA("Model") and child:GetAttribute("Type") == "Slope" then
			trackSlopeDifficultySignsForModel(child)
		end
	end
	refreshSlopeDifficultyOverlay()
end)

local isSettingsOpen = false
local TWEEN_INFO = TweenInfo.new(0.35, Enum.EasingStyle.Quart, Enum.EasingDirection.Out)
local SETTINGS_POS_HIDDEN  = UDim2.new(0.5, 0, 1.5, 0)
local SETTINGS_POS_VISIBLE = UDim2.new(0.5, 0, 0.5, 0)
local settingsViewportConnection = nil

local function getViewportSize()
	local camera = Workspace.CurrentCamera
	if camera and camera.ViewportSize.X > 0 and camera.ViewportSize.Y > 0 then
		return camera.ViewportSize
	end
	return Vector2.new(1920, 1080)
end

local function applyResponsiveTextSizing(root, isTouchLayout)
	for _, desc in ipairs(root:GetDescendants()) do
		if desc:IsA("TextLabel") or desc:IsA("TextButton") or desc:IsA("TextBox") then
			local baseSize = desc:GetAttribute("ResponsiveBaseTextSize")
			if baseSize == nil then
				baseSize = desc.TextSize
				desc:SetAttribute("ResponsiveBaseTextSize", baseSize)
			end
			desc.TextSize = isTouchLayout and math.max(baseSize, math.floor(baseSize * 1.1 + 0.5)) or baseSize
		end
	end
end

local function applyResponsiveRowSizing(content, isTouchLayout)
	for _, child in ipairs(content:GetChildren()) do
		if (child:IsA("Frame") or child:IsA("TextButton")) and child.Size.Y.Scale == 0 and child.Size.Y.Offset >= 36 then
			local baseHeight = child:GetAttribute("ResponsiveBaseHeight")
			if baseHeight == nil then
				baseHeight = child.Size.Y.Offset
				child:SetAttribute("ResponsiveBaseHeight", baseHeight)
			end
			local targetHeight = isTouchLayout and math.max(baseHeight, 46) or baseHeight
			child.Size = UDim2.new(child.Size.X.Scale, child.Size.X.Offset, 0, targetHeight)
		end
	end
end

local function applyResponsiveTicketRow(ticketRow, isTouchLayout)
	if not (ticketRow and ticketRow:IsA("Frame")) then
		return
	end
	local title = ticketRow:FindFirstChild("Title")
	local meta = ticketRow:FindFirstChild("Meta")
	local input = ticketRow:FindFirstChild("Input")
	local minus = ticketRow:FindFirstChild("Minus")
	local plus = ticketRow:FindFirstChild("Plus")
	local autoToggle = ticketRow:FindFirstChild("AutoToggle")
	local apply = ticketRow:FindFirstChild("Apply")
	if not (title and meta and input and minus and plus and autoToggle and apply) then
		return
	end

	local rowWidth = math.max(ticketRow.AbsoluteSize.X, 320)
	local compact = isTouchLayout or rowWidth < 620
	if compact then
		ticketRow.Size = UDim2.new(1, 0, 0, 142)
		meta.Position = UDim2.fromOffset(12, 26)
		meta.Size = UDim2.new(1, -24, 0, 24)
		input.Position = UDim2.fromOffset(12, 54)
		input.Size = UDim2.fromOffset(86, 28)
		minus.Position = UDim2.fromOffset(104, 54)
		minus.Size = UDim2.fromOffset(28, 28)
		plus.Position = UDim2.fromOffset(138, 54)
		plus.Size = UDim2.fromOffset(28, 28)
		apply.Position = UDim2.fromOffset(12, 96)
		apply.Size = UDim2.fromOffset(96, 30)
		autoToggle.Position = UDim2.fromOffset(118, 96)
		autoToggle.Size = UDim2.new(1, -130, 0, 30)
	else
		ticketRow.Size = UDim2.new(1, 0, 0, 108)
		meta.Position = UDim2.fromOffset(12, 26)
		meta.Size = UDim2.new(1, -24, 0, 12)
		input.Position = UDim2.fromOffset(12, 42)
		input.Size = UDim2.fromOffset(94, 26)
		minus.Position = UDim2.fromOffset(182, 42)
		minus.Size = UDim2.fromOffset(28, 26)
		plus.Position = UDim2.fromOffset(216, 42)
		plus.Size = UDim2.fromOffset(28, 26)
		apply.Position = UDim2.new(1, -88, 0, 42)
		apply.Size = UDim2.fromOffset(76, 26)
		autoToggle.Position = UDim2.fromOffset(12, 76)
		autoToggle.Size = UDim2.fromOffset(108, 24)
	end
end

local applyResponsiveGuestCapRow

local function refreshSettingsCanvas(content)
	if not (content and content.Parent) then
		return
	end
	local layout = content:FindFirstChildOfClass("UIListLayout")
	local padding = content:FindFirstChildOfClass("UIPadding")
	local topPad = (padding and padding.PaddingTop.Offset) or 0
	local bottomPad = (padding and padding.PaddingBottom.Offset) or 0
	local listHeight = (layout and layout.AbsoluteContentSize.Y) or 0
	local canvasY = math.max(0, listHeight + topPad + bottomPad + 72)
	content.CanvasSize = UDim2.new(0, 0, 0, canvasY)
end

local function applyResponsiveSettingsLayout(frame, content)
	if not (frame and content) then
		return
	end

	local viewport = getViewportSize()
	local shortSide = math.min(viewport.X, viewport.Y)
	local isTouchLayout = UserInputService.TouchEnabled and shortSide <= 1100
	local width = math.clamp(math.floor(viewport.X * (isTouchLayout and 0.84 or 0.58)), isTouchLayout and 520 or 620, isTouchLayout and 860 or 940)
	local height = math.clamp(math.floor(viewport.Y * (isTouchLayout and 0.8 or 0.72)), isTouchLayout and 540 or 560, isTouchLayout and 820 or 860)
	local headerHeight = isTouchLayout and 68 or 58

	frame.Size = UDim2.fromOffset(width, height)
	frame.AnchorPoint = Vector2.new(0.5, 0.5)
	frame.Position = isSettingsOpen and SETTINGS_POS_VISIBLE or SETTINGS_POS_HIDDEN
	frame.ClipsDescendants = true

	local header = frame:FindFirstChild("Header")
	if header and header:IsA("GuiObject") then
		header.Size = UDim2.new(1, 0, 0, headerHeight)
	end

	local tabBar = frame:FindFirstChild("SettingsTabBar")
	local tabBarHeight = 0
	if tabBar and tabBar:IsA("GuiObject") then
		tabBarHeight = isTouchLayout and 40 or 36
		tabBar.Position = UDim2.fromOffset(6, headerHeight + 14)
		tabBar.Size = UDim2.new(1, -12, 0, tabBarHeight)
	end

	content.Position = UDim2.fromOffset(6, headerHeight + tabBarHeight + 20)
	content.Size = UDim2.new(1, -12, 1, -(headerHeight + tabBarHeight + 26))
	content.ScrollBarThickness = isTouchLayout and 12 or 9
	content.AutomaticCanvasSize = Enum.AutomaticSize.None

	applyResponsiveRowSizing(content, isTouchLayout)
	applyResponsiveTicketRow(content:FindFirstChild("LiftTickets"), isTouchLayout)
	applyResponsiveGuestCapRow(content:FindFirstChild("GuestCapRow"), isTouchLayout)
	applyResponsiveTextSizing(frame, isTouchLayout)
	refreshSettingsCanvas(content)
end

local function bindViewportResponsive(frame, content)
	if settingsViewportConnection then
		settingsViewportConnection:Disconnect()
		settingsViewportConnection = nil
	end
	local function hookCamera(camera)
		if not camera then
			return
		end
		if settingsViewportConnection then
			settingsViewportConnection:Disconnect()
		end
		settingsViewportConnection = camera:GetPropertyChangedSignal("ViewportSize"):Connect(function()
			applyResponsiveSettingsLayout(frame, content)
		end)
	end
	Workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
		hookCamera(Workspace.CurrentCamera)
		applyResponsiveSettingsLayout(frame, content)
	end)
	hookCamera(Workspace.CurrentCamera)
end

-- Set initial player attributes (legacy compat + local hydration)
Player:SetAttribute("MusicEnabled", SETTINGS.Music)
Player:SetAttribute("ParticlesEnabled", SETTINGS.Particles)
Player:SetAttribute("SlopeDifficultyOverlayEnabled", SETTINGS.SlopeDifficulty)
for key, val in pairs(SETTINGS) do
	Player:SetAttribute(SETTINGS_ATTR_PREFIX .. key, val)
end

--------------------------------------------------------------------------------
-- ACTUAL OPTIMIZATION FUNCTIONS (these do real work)
--------------------------------------------------------------------------------

local setWeatherAudioEnabled

local function setMusic(on)
	SETTINGS.Music = on; saveSetting("Music", on)
	Player:SetAttribute("MusicEnabled", on)
	local function applyMusicToggle(container)
		for _, desc in pairs(container:GetDescendants()) do
			if desc:IsA("Sound") and desc.Name ~= "Click" then
				if not on then
					if desc:GetAttribute("OriginalVolume") == nil then
						desc:SetAttribute("OriginalVolume", desc.Volume)
					end
					desc.Volume = 0
				else
					local originalVolume = desc:GetAttribute("OriginalVolume")
					if originalVolume ~= nil then
						desc.Volume = originalVolume
					end
				end
			end
		end
	end
	applyMusicToggle(workspace)
	applyMusicToggle(game:GetService("SoundService"))
	if setWeatherAudioEnabled then
		setWeatherAudioEnabled(SETTINGS.Weather and on)
	end
end

local function setShadows(on)
	SETTINGS.Shadows = on; saveSetting("Shadows", on)
	Lighting.GlobalShadows = on
end

local WEATHER_HINTS = {
	weather = true,
	snow = true,
	blizzard = true,
	rain = true,
	storm = true,
	wind = true,
}

local function isWeatherLinkedInstance(inst)
	local current = inst
	while current do
		local name = string.lower(current.Name or "")
		for hint in pairs(WEATHER_HINTS) do
			if string.find(name, hint, 1, true) then
				return true
			end
		end
		current = current.Parent
	end
	return false
end

local function setWeatherVisualsEnabled(enabled)
	for _, desc in pairs(workspace:GetDescendants()) do
		if (desc:IsA("ParticleEmitter") or desc:IsA("Beam") or desc:IsA("Trail")) and isWeatherLinkedInstance(desc) then
			desc.Enabled = enabled
		end
	end
end

setWeatherAudioEnabled = function(enabled)
	local soundService = game:GetService("SoundService")
	for _, desc in pairs(soundService:GetDescendants()) do
		if desc:IsA("Sound") and isWeatherLinkedInstance(desc) then
			if not enabled then
				if desc:GetAttribute("_origWeatherVolume") == nil then
					desc:SetAttribute("_origWeatherVolume", desc.Volume)
				end
				desc.Volume = 0
				desc.Playing = false
			else
				local originalVolume = desc:GetAttribute("_origWeatherVolume")
				if originalVolume ~= nil then
					desc.Volume = originalVolume
				end
			end
		end
	end
end

local function setWeather(on)
	SETTINGS.Weather = on; saveSetting("Weather", on)
	for _, child in pairs(PlayerScripts:GetChildren()) do
		if child.Name:lower():find("weather") and child:IsA("LocalScript") then
			child.Disabled = not on
		end
	end
	setWeatherVisualsEnabled(on and SETTINGS.Particles)
	setWeatherAudioEnabled(on and SETTINGS.Music)
end

local function setParticles(on)
	SETTINGS.Particles = on; saveSetting("Particles", on)
	Player:SetAttribute("ParticlesEnabled", on)
	for _, desc in pairs(workspace:GetDescendants()) do
		if desc:IsA("ParticleEmitter") or desc:IsA("Trail") or desc:IsA("Beam") then
			desc.Enabled = on
		end
	end
	setWeatherVisualsEnabled(on and SETTINGS.Weather)
end

-- Helper: toggle transparency on all BaseParts in a model/folder
local function toggleModelTransparency(model, on)
	for _, part in pairs(model:GetDescendants()) do
		if part:IsA("BasePart") then
			if not on then
				if part:GetAttribute("_origTransp") == nil then
					part:SetAttribute("_origTransp", part.Transparency)
				end
				if part:GetAttribute("_origCanCollide") == nil then
					part:SetAttribute("_origCanCollide", part.CanCollide)
				end
				if part:GetAttribute("_origCanTouch") == nil then
					part:SetAttribute("_origCanTouch", part.CanTouch)
				end
				part.Transparency = 1
				part.CanCollide = false
				part.CanTouch = false
			else
				local origTransparency = part:GetAttribute("_origTransp")
				local origCanCollide = part:GetAttribute("_origCanCollide")
				local origCanTouch = part:GetAttribute("_origCanTouch")
				if origTransparency ~= nil then part.Transparency = origTransparency end
				if origCanCollide ~= nil then part.CanCollide = origCanCollide end
				if origCanTouch ~= nil then part.CanTouch = origCanTouch end
			end
		end
	end
end

-- Check if a model is a tree by name
local function isTreeModel(model)
	local n = model.Name:lower()
	return n:find("tree") or n:find("pine") or n:find("spruce") or n:find("fir") or n:find("birch")
		or n:find("cedar") or n:find("oak") or n:find("bush") or n:find("shrub")
end

local slopeOverlayTrackedModels = {}
local slopeOverlayConnections = {}

local function getAncestorSlopeModel(instance)
	local current = instance
	while current do
		if current:IsA("Model") and current:GetAttribute("Type") == "Slope" then
			return current
		end
		current = current.Parent
	end
	return nil
end

local function isSlopeDifficultySignModel(model)
	if not model or not model:IsA("Model") then
		return false
	end
	if not model.Name:lower():find("sign") then
		return false
	end
	return getAncestorSlopeModel(model) ~= nil
end

local function applySlopeDifficultySignVisibility(signModel, enabled)
	if not isSlopeDifficultySignModel(signModel) then
		return
	end
	for _, desc in ipairs(signModel:GetDescendants()) do
		if desc:IsA("BasePart") then
			desc.LocalTransparencyModifier = enabled and 0 or 1
		elseif desc:IsA("Decal") or desc:IsA("Texture") then
			desc.Transparency = enabled and 0 or 1
		end
	end
end

local function applySlopeDifficultySignVisibilityRecursive(root, enabled)
	if not root then
		return
	end
	if root:IsA("Model") then
		applySlopeDifficultySignVisibility(root, enabled)
	end
	for _, desc in ipairs(root:GetDescendants()) do
		if desc:IsA("Model") then
			applySlopeDifficultySignVisibility(desc, enabled)
		end
	end
end

trackSlopeDifficultySignsForModel = function(slopeModel)
	if slopeOverlayTrackedModels[slopeModel] then
		applySlopeDifficultySignVisibilityRecursive(slopeModel, SETTINGS.SlopeDifficulty)
		return
	end
	slopeOverlayTrackedModels[slopeModel] = true
	applySlopeDifficultySignVisibilityRecursive(slopeModel, SETTINGS.SlopeDifficulty)

	slopeOverlayConnections[slopeModel] = slopeModel.DescendantAdded:Connect(function(descendant)
		if descendant:IsA("Model") then
			applySlopeDifficultySignVisibility(descendant, SETTINGS.SlopeDifficulty)
		end
	end)

	slopeModel.Destroying:Connect(function()
		slopeOverlayTrackedModels[slopeModel] = nil
		local conn = slopeOverlayConnections[slopeModel]
		if conn then
			conn:Disconnect()
			slopeOverlayConnections[slopeModel] = nil
		end
	end)
end

refreshSlopeDifficultyOverlay = function()
	local placedObjects = workspace:FindFirstChild("PlacedObjects")
	if not placedObjects then
		return
	end
	for _, child in ipairs(placedObjects:GetDescendants()) do
		if child:IsA("Model") and child:GetAttribute("Type") == "Slope" then
			trackSlopeDifficultySignsForModel(child)
			applySlopeDifficultySignVisibilityRecursive(child, SETTINGS.SlopeDifficulty)
		end
	end
end

local function setUnitSystem(nextUnitSystem)
	local resolved = normalizeUnitSystem(nextUnitSystem)
	SETTINGS.UnitSystem = resolved
	saveSetting("UnitSystem", resolved)
end

local function setGraphicsPreset(choice)
	local resolved = normalizeChoiceSetting(choice, {"Low", "Medium", "High", "Ultra"}, "Medium")
	SETTINGS.GraphicsPreset = resolved
	saveSetting("GraphicsPreset", resolved)
end

local function forceRevealAllPlacedBuildings()
	local placed = Workspace:FindFirstChild("PlacedObjects")
	if not placed then
		return
	end
	for _, desc in ipairs(placed:GetDescendants()) do
		if desc:IsA("BasePart") and desc.LocalTransparencyModifier ~= 0 then
			desc.LocalTransparencyModifier = 0
		end
	end
end

local function setBuildingRenderDistance(choice)
	local resolved = normalizeChoiceSetting(choice, {"Near", "Medium", "Far", "Off"}, "Medium")
	SETTINGS.BuildingRenderDistance = resolved
	saveSetting("BuildingRenderDistance", resolved)
	if resolved == "Off" then
		task.defer(forceRevealAllPlacedBuildings)
	end
end

local function setLiftRenderDistance(choice)
	local resolved = normalizeChoiceSetting(choice, {"Near", "Medium", "Far", "Off"}, "Medium")
	SETTINGS.LiftRenderDistance = resolved
	saveSetting("LiftRenderDistance", resolved)
end

local function setNPCRenderDistance(choice)
	local resolved = normalizeChoiceSetting(choice, {"Near", "Medium", "Far", "Off"}, "Medium")
	SETTINGS.NPCRenderDistance = resolved
	saveSetting("NPCRenderDistance", resolved)
end

local function setWeatherQuality(choice)
	local resolved = normalizeChoiceSetting(choice, {"Low", "Medium", "High", "Ultra"}, "High")
	SETTINGS.WeatherQuality = resolved
	saveSetting("WeatherQuality", resolved)
end

local function setParticleQuality(choice)
	local resolved = normalizeChoiceSetting(choice, {"Low", "Medium", "High", "Ultra"}, "High")
	SETTINGS.ParticleQuality = resolved
	saveSetting("ParticleQuality", resolved)
end

local function setParticleDensity(choice)
	local resolved = normalizeChoiceSetting(choice, {"Low", "Medium", "High", "Ultra"}, "Medium")
	SETTINGS.ParticleDensity = resolved
	saveSetting("ParticleDensity", resolved)
end

local function setRealisticParticles(on)
	SETTINGS.RealisticParticles = on
	saveSetting("RealisticParticles", on)
end

local function setAdaptiveParticles(on)
	SETTINGS.AdaptiveParticles = on
	saveSetting("AdaptiveParticles", on)
end

local function setFogEdgeBlend(on)
	SETTINGS.FogEdgeBlend = on
	saveSetting("FogEdgeBlend", on)
end

local function setFogEdgeIntensity(choice)
	local resolved = normalizeChoiceSetting(choice, {"Low", "Medium", "High"}, "Medium")
	SETTINGS.FogEdgeIntensity = resolved
	saveSetting("FogEdgeIntensity", resolved)
end

local function setTrees(on)
	SETTINGS.Trees = on; saveSetting("Trees", on)
	-- 1. TreeFolder (world-generated trees)
	local treeFolder = workspace:FindFirstChild("TreeFolder")
	if treeFolder then
		for _, tree in pairs(treeFolder:GetChildren()) do
			toggleModelTransparency(tree, on)
		end
	end
	-- 2. GladeTrees folders inside slopes
	for _, desc in pairs(workspace:GetDescendants()) do
		if desc:IsA("Folder") and desc.Name == "GladeTrees" then
			for _, tree in pairs(desc:GetChildren()) do
				toggleModelTransparency(tree, on)
			end
		end
	end
	-- 3. User-placed trees inside PlacedObjects
	local placedObjects = workspace:FindFirstChild("PlacedObjects")
	if placedObjects then
		for _, obj in pairs(placedObjects:GetDescendants()) do
			if (obj:IsA("Model") or obj:IsA("BasePart")) and isTreeModel(obj) then
				toggleModelTransparency(obj, on)
			end
		end
	end
end

local function setGuestModels(on)
	SETTINGS.GuestModels = on; saveSetting("GuestModels", on)
	Player:SetAttribute("GuestModelsVisible", on)
end

local function setGuestCap(value)
	local resolved = sanitizeGuestCapValue(value)
	SETTINGS.MaxGuestCap = resolved
	saveSetting("MaxGuestCap", resolved)
	Player:SetAttribute("GuestCap", resolved)
end

local function setGuestCapEnabled(on)
	local enabled = on == true
	SETTINGS.MaxGuestCapEnabled = enabled
	saveSetting("MaxGuestCapEnabled", enabled)
	Player:SetAttribute("GuestCapEnabled", enabled)
end

local _savedAtmDensity = nil
local function setAtmosphere(on)
	SETTINGS.Atmosphere = on; saveSetting("Atmosphere", on)
	local atm = Lighting:FindFirstChildOfClass("Atmosphere")
	if atm then
		if not on then
			_savedAtmDensity = _savedAtmDensity or atm.Density
			atm.Density = 0
			atm.Haze = 0
		else
			atm.Density = _savedAtmDensity or 0.3
			atm.Haze = 1
		end
	end
	
end

local function setSunRays(on)
	SETTINGS.SunRays = on; saveSetting("SunRays", on)
	local sr = Lighting:FindFirstChildOfClass("SunRaysEffect")
	if sr then sr.Enabled = on end
	
end

local function setBloom(on)
	SETTINGS.Bloom = on; saveSetting("Bloom", on)
	local bloom = Lighting:FindFirstChildOfClass("BloomEffect")
	if bloom then bloom.Enabled = on end
	local cc = Lighting:FindFirstChildOfClass("ColorCorrectionEffect")
	if cc then cc.Enabled = on end
	
end

local function setGuestPerformanceMode(choice)
	local resolved = normalizeChoiceSetting(choice, {"Off", "Balanced", "Aggressive", "Extreme"}, "Off")
	SETTINGS.GuestPerformanceMode = resolved
	saveSetting("GuestPerformanceMode", resolved)
	local lp = game.Players.LocalPlayer
	if lp then
		local forceDistanceCull = (resolved ~= "Off")
		lp:SetAttribute("GuestModelDistanceCullEnabled", forceDistanceCull or SETTINGS.GuestLOD == true)
	end
end

local function setGuestLOD(on)
	SETTINGS.GuestLOD = on; saveSetting("GuestLOD", on)
	local lp = game.Players.LocalPlayer
	if lp then
		local forceDistanceCull = SETTINGS.GuestPerformanceMode ~= "Off"
		lp:SetAttribute("GuestLODEnabled", on)
		lp:SetAttribute("GuestModelDistanceCullEnabled", forceDistanceCull or on)
	end
	-- When LOD is disabled, un-cull all currently culled guests
	if not on then
		local guestsFolder = workspace:FindFirstChild("Guests")
		if guestsFolder then
			for _, model in ipairs(guestsFolder:GetChildren()) do
				if model:GetAttribute("_Culled") then
					model:SetAttribute("_Culled", nil)
					for _, part in ipairs(model:GetDescendants()) do
						if part:IsA("BasePart") then
							part.LocalTransparencyModifier = 0
							local orig = part:GetAttribute("_OrigTransparency")
							if orig ~= nil then
								part.Transparency = orig
								part:SetAttribute("_OrigTransparency", nil)
							end
						end
					end
				end
			end
		end
	end
end

-- Apply initial GuestLOD attribute
do
	local lp = game.Players.LocalPlayer
	if lp then
		lp:SetAttribute("GuestLODEnabled", SETTINGS.GuestLOD)
		lp:SetAttribute("GuestModelDistanceCullEnabled", (SETTINGS.GuestPerformanceMode ~= "Off") or SETTINGS.GuestLOD)
	end
end

local function setDecorations(on)
	SETTINGS.Decorations = on; saveSetting("Decorations", on)
	-- Only target slope decorations: markers, nets, signs — NOT lift poles
	local DECOR_NAMES = {"marker", "safetynet", "slopesign", "slopemarker", "trailmarker"}
	for _, model in pairs(workspace:GetDescendants()) do
		if model:IsA("BasePart") or model:IsA("Model") then
			local name = model.Name:lower()
			local isDecor = false
			for _, pattern in ipairs(DECOR_NAMES) do
				if name:find(pattern) then isDecor = true; break end
			end
			-- Also catch "Net" but only if parent looks slope-related (not lift)
			if not isDecor and name == "net" then
				local parentName = model.Parent and model.Parent.Name:lower() or ""
				if parentName:find("slope") or parentName:find("decor") or parentName:find("trail") then
					isDecor = true
				end
			end
			if isDecor then
				toggleModelTransparency(model, on)
			end
		end
	end
	
end

local function setSlopeDifficulty(on)
	SETTINGS.SlopeDifficulty = on; saveSetting("SlopeDifficulty", on)
	Player:SetAttribute("SlopeDifficultyOverlayEnabled", on)
	refreshSlopeDifficultyOverlay()
	
end

local fpsLabel = nil
local fpsConn = nil

local function setFPSCounter(on)
	SETTINGS.FPSCounter = on; saveSetting("FPSCounter", on)
	if on then
		if not fpsLabel then
			local sg = PlayerGui:FindFirstChild("FPSGui")
			if not sg then
				sg = Instance.new("ScreenGui")
				sg.Name = "FPSGui"
				sg.DisplayOrder = 100
				sg.IgnoreGuiInset = true
				sg.Parent = PlayerGui
			end
			fpsLabel = Instance.new("TextLabel")
			fpsLabel.Name = "FPS"
			fpsLabel.Size = UDim2.new(0, 80, 0, 24)
			fpsLabel.Position = UDim2.new(1, -90, 0, 8)
			fpsLabel.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
			fpsLabel.BackgroundTransparency = 0.5
			fpsLabel.TextColor3 = Color3.fromRGB(0, 255, 100)
			fpsLabel.Font = Enum.Font.Code
			fpsLabel.TextSize = 14
			fpsLabel.Text = "FPS: --"
			fpsLabel.ZIndex = 999
			Instance.new("UICorner", fpsLabel).CornerRadius = UDim.new(0, 4)
			fpsLabel.Parent = sg
		end
		fpsLabel.Visible = true
		if not fpsConn then
			local lastTime = tick()
			local frameCount = 0
			fpsConn = RunService.RenderStepped:Connect(function()
				frameCount += 1
				local now = tick()
				if now - lastTime >= 1 then
					if fpsLabel then
						fpsLabel.Text = "FPS: " .. math.floor(frameCount / (now - lastTime))
					end
					frameCount = 0
					lastTime = now
				end
			end)
		end
	else
		if fpsLabel then fpsLabel.Visible = false end
		if fpsConn then fpsConn:Disconnect(); fpsConn = nil end
	end

end

local AUTO_PERF_ENABLED = true
local AUTO_PERF_SAMPLE_WINDOW = 1.25
local AUTO_PERF_COMPLEXITY_SCAN_INTERVAL = 3
local AUTO_PERF_CHANGE_COOLDOWN = 1.6

local autoPerfTier = 0
local autoPerfSampleFrames = 0
local autoPerfSampleTime = 0
local autoPerfGuestCount = 0
local autoPerfLiftCount = 0
local autoPerfLastComplexityScan = 0
local autoPerfLastTierChangeAt = 0

local function isLiftLikeModel(model)
	if not (model and model:IsA("Model")) then
		return false
	end
	local modelType = string.lower(tostring(model:GetAttribute("Type") or ""))
	if modelType == "twopoint" or modelType == "carpet" or modelType == "lift" then
		return true
	end
	local lowerName = string.lower(model.Name)
	return lowerName:find("lift", 1, true) ~= nil
		or lowerName:find("tow", 1, true) ~= nil
		or lowerName:find("gondola", 1, true) ~= nil
		or lowerName:find("chair", 1, true) ~= nil
end

local function refreshAutoPerfComplexity(now)
	if (now - autoPerfLastComplexityScan) < AUTO_PERF_COMPLEXITY_SCAN_INTERVAL then
		return
	end
	autoPerfLastComplexityScan = now

	local guestsFolder = Workspace:FindFirstChild("Guests")
	autoPerfGuestCount = guestsFolder and #guestsFolder:GetChildren() or 0

	autoPerfLiftCount = 0
	local placedObjects = Workspace:FindFirstChild("PlacedObjects")
	if placedObjects then
		for _, child in ipairs(placedObjects:GetChildren()) do
			if child:IsA("Model") and isLiftLikeModel(child) then
				autoPerfLiftCount += 1
			end
		end
	end
end

local function applyRuntimeRenderingTier(tier)
	pcall(function()
		if tier >= 3 then
			settings().Rendering.QualityLevel = Enum.QualityLevel.Level01
		elseif tier == 2 then
			settings().Rendering.QualityLevel = Enum.QualityLevel.Level03
		elseif tier == 1 then
			settings().Rendering.QualityLevel = Enum.QualityLevel.Level05
		else
			settings().Rendering.QualityLevel = Enum.QualityLevel.Automatic
		end
	end)

	if tier >= 2 then
		Lighting.GlobalShadows = false
		pcall(function()
			Workspace.Terrain.Decoration = false
		end)
	elseif tier == 1 then
		Lighting.GlobalShadows = SETTINGS.Shadows
		pcall(function()
			Workspace.Terrain.Decoration = SETTINGS.Trees
		end)
	else
		Lighting.GlobalShadows = SETTINGS.Shadows
		pcall(function()
			Workspace.Terrain.Decoration = true
		end)
	end
end

local function setRuntimePerfTier(tier)
	tier = math.clamp(math.floor(tonumber(tier) or 0), 0, 3)
	if autoPerfTier == tier then
		return
	end
	autoPerfTier = tier
	Player:SetAttribute(SETTINGS_ATTR_PREFIX .. "RuntimePerfTier", tier)
	applyRuntimeRenderingTier(tier)
end

local function getDesiredAutoPerfTier(avgFps)
	local tier = 0
	if avgFps < 57 then
		tier = 1
	end
	if avgFps < 49 then
		tier = 2
	end
	if avgFps < 42 then
		tier = 3
	end

	if autoPerfGuestCount >= 130 or autoPerfLiftCount >= 7 then
		tier = math.max(tier, 1)
	end
	if autoPerfGuestCount >= 190 or autoPerfLiftCount >= 10 then
		tier = math.max(tier, 2)
	end
	if autoPerfGuestCount >= 260 then
		tier = math.max(tier, 3)
	end

	return math.clamp(tier, 0, 3)
end

if AUTO_PERF_ENABLED then
	local initialTier = math.clamp(math.floor(tonumber(Player:GetAttribute(SETTINGS_ATTR_PREFIX .. "RuntimePerfTier")) or 0), 0, 3)
	autoPerfTier = initialTier
	Player:SetAttribute(SETTINGS_ATTR_PREFIX .. "RuntimePerfTier", autoPerfTier)
	applyRuntimeRenderingTier(autoPerfTier)

	RunService.RenderStepped:Connect(function(dt)
		local clampedDt = math.clamp(dt, 1 / 240, 0.2)
		autoPerfSampleFrames += 1
		autoPerfSampleTime += clampedDt

		if autoPerfSampleTime < AUTO_PERF_SAMPLE_WINDOW then
			return
		end

		local now = os.clock()
		refreshAutoPerfComplexity(now)

		local avgFps = autoPerfSampleFrames / math.max(autoPerfSampleTime, 1e-3)
		autoPerfSampleFrames = 0
		autoPerfSampleTime = 0

		local desiredTier = getDesiredAutoPerfTier(avgFps)
		if desiredTier < autoPerfTier then
			local relaxThreshold = (desiredTier == 0 and 63) or (desiredTier == 1 and 56) or 50
			if avgFps < relaxThreshold then
				desiredTier = autoPerfTier
			end
		end

		if desiredTier ~= autoPerfTier and (now - autoPerfLastTierChangeAt) >= AUTO_PERF_CHANGE_COOLDOWN then
			setRuntimePerfTier(desiredTier)
			autoPerfLastTierChangeAt = now
		end
	end)
end

-- Helper to force a UI toggle visually
local function forceToggleVisual(name, isOn)
	local content = _settingsFrame and _settingsFrame:FindFirstChild("Content")
	if not content then return end
	local row = content:FindFirstChild(name)
	if not row then return end
	local toggle = row:FindFirstChild("Toggle")
	if not toggle then return end
	toggle.Text = isOn and "ON" or "OFF"
	toggle.BackgroundColor3 = isOn and THEME.ToggleOnBg or THEME.ToggleOffBg
end

local isPotatoMode = false
local prePotato = {}

-- POTATO MODE: turns off everything non-essential at once
local function activatePotatoMode()
	if isPotatoMode then
		isPotatoMode = false
		setShadows(prePotato.Shadows == nil and true or prePotato.Shadows)
		setWeather(prePotato.Weather == nil and true or prePotato.Weather)
		setParticles(prePotato.Particles == nil and true or prePotato.Particles)
		setTrees(prePotato.Trees == nil and true or prePotato.Trees)
		setAtmosphere(prePotato.Atmosphere == nil and true or prePotato.Atmosphere)
		setSunRays(prePotato.SunRays == nil and true or prePotato.SunRays)
		setBloom(prePotato.Bloom == nil and true or prePotato.Bloom)
		setDecorations(prePotato.Decorations == nil and true or prePotato.Decorations)
		setGuestModels(prePotato.GuestModels == nil and true or prePotato.GuestModels)
		setSlopeDifficulty(prePotato.SlopeDifficulty == nil and true or prePotato.SlopeDifficulty)
		setGraphicsPreset(prePotato.GraphicsPreset == nil and "Medium" or prePotato.GraphicsPreset)
		setBuildingRenderDistance(prePotato.BuildingRenderDistance == nil and "Medium" or prePotato.BuildingRenderDistance)
		setLiftRenderDistance(prePotato.LiftRenderDistance == nil and "Medium" or prePotato.LiftRenderDistance)
		setNPCRenderDistance(prePotato.NPCRenderDistance == nil and "Medium" or prePotato.NPCRenderDistance)
		setWeatherQuality(prePotato.WeatherQuality == nil and "High" or prePotato.WeatherQuality)
		setParticleQuality(prePotato.ParticleQuality == nil and "High" or prePotato.ParticleQuality)
		setParticleDensity(prePotato.ParticleDensity == nil and "Medium" or prePotato.ParticleDensity)
		setRealisticParticles(prePotato.RealisticParticles == nil and true or prePotato.RealisticParticles)
		setAdaptiveParticles(prePotato.AdaptiveParticles == nil and true or prePotato.AdaptiveParticles)
		setFogEdgeBlend(prePotato.FogEdgeBlend == nil and true or prePotato.FogEdgeBlend)
		setFogEdgeIntensity(prePotato.FogEdgeIntensity == nil and "Medium" or prePotato.FogEdgeIntensity)
		setGuestPerformanceMode(prePotato.GuestPerformanceMode == nil and "Off" or prePotato.GuestPerformanceMode)
		
		pcall(function() workspace.Terrain.Decoration = true end)
		pcall(function() settings().Rendering.QualityLevel = 0 end)
		
		local toUpdate = {
			Shadows=SETTINGS.Shadows, Weather=SETTINGS.Weather, Particles=SETTINGS.Particles, 
			Trees=SETTINGS.Trees, Atmosphere=SETTINGS.Atmosphere, SunRays=SETTINGS.SunRays, 
			Bloom=SETTINGS.Bloom, Decorations=SETTINGS.Decorations, GuestModels=SETTINGS.GuestModels, 
			SlopeDifficultyOverlay=SETTINGS.SlopeDifficulty
		}
		for name, val in pairs(toUpdate) do forceToggleVisual(name, val) end

		local content = _settingsFrame and _settingsFrame:FindFirstChild("Content")
		local potatoBtn = content and content:FindFirstChild("EnablePotatoMode")
		if potatoBtn then potatoBtn.Text = "ENABLE POTATO MODE"; potatoBtn.BackgroundColor3 = Color3.fromRGB(125, 88, 40) end
	else
		isPotatoMode = true
		prePotato = {
			Shadows=SETTINGS.Shadows, Weather=SETTINGS.Weather, Particles=SETTINGS.Particles, 
			Trees=SETTINGS.Trees, Atmosphere=SETTINGS.Atmosphere, SunRays=SETTINGS.SunRays, 
			Bloom=SETTINGS.Bloom, Decorations=SETTINGS.Decorations, GuestModels=SETTINGS.GuestModels, 
			SlopeDifficulty=SETTINGS.SlopeDifficulty,
			GraphicsPreset=SETTINGS.GraphicsPreset,
			BuildingRenderDistance=SETTINGS.BuildingRenderDistance,
			LiftRenderDistance=SETTINGS.LiftRenderDistance,
			NPCRenderDistance=SETTINGS.NPCRenderDistance,
			WeatherQuality=SETTINGS.WeatherQuality,
			ParticleQuality=SETTINGS.ParticleQuality,
			ParticleDensity=SETTINGS.ParticleDensity,
			RealisticParticles=SETTINGS.RealisticParticles,
			AdaptiveParticles=SETTINGS.AdaptiveParticles,
			FogEdgeBlend=SETTINGS.FogEdgeBlend,
			FogEdgeIntensity=SETTINGS.FogEdgeIntensity,
			GuestPerformanceMode=SETTINGS.GuestPerformanceMode,
		}
		
		setShadows(false)
		setWeather(false)
		setParticles(false)
		setTrees(false)
		setAtmosphere(false)
		setSunRays(false)
		setBloom(false)
		setDecorations(false)
		setGuestModels(false)
		setSlopeDifficulty(false)
		setGraphicsPreset("Low")
		setBuildingRenderDistance("Near")
		setLiftRenderDistance("Near")
		setNPCRenderDistance("Near")
		setWeatherQuality("Low")
		setParticleQuality("Low")
		setParticleDensity("Low")
		setRealisticParticles(false)
		setAdaptiveParticles(true)
		setFogEdgeBlend(false)
		setGuestPerformanceMode("Extreme")
		
		pcall(function() workspace.Terrain.Decoration = false end)
		pcall(function() settings().Rendering.QualityLevel = 1 end)
		
		local toUpdate = {"Shadows", "Weather", "Particles", "Trees", "Atmosphere", "SunRays", "Bloom", "Decorations", "GuestModels", "SlopeDifficultyOverlay"}
		for _, name in ipairs(toUpdate) do forceToggleVisual(name, false) end
		
		local content = _settingsFrame and _settingsFrame:FindFirstChild("Content")
		local potatoBtn = content and content:FindFirstChild("EnablePotatoMode")
		if potatoBtn then potatoBtn.Text = "DISABLE POTATO MODE"; potatoBtn.BackgroundColor3 = THEME.Red end
	end
end

-- Legacy auto-perf pass is disabled; the Settings_RuntimePerfTier system above is authoritative.
local AUTO_PERF_ENABLED = false
local AUTO_PERF_SAMPLE_INTERVAL = 0.5
local AUTO_PERF_ESCALATE1_FPS = 58
local AUTO_PERF_ESCALATE2_FPS = 50
local AUTO_PERF_RECOVER1_FPS = 62
local AUTO_PERF_RECOVER0_FPS = 66
local AUTO_PERF_ESCALATE1_TIME = 3
local AUTO_PERF_ESCALATE2_TIME = 4
local AUTO_PERF_RECOVER_TIME = 10

local runtimePerfTier = 0
Player:SetAttribute("RuntimePerformanceTier", runtimePerfTier)

local function ReadAverageFPS()
	local frameRateManager = Stats:FindFirstChild("FrameRateManager")
	if not frameRateManager then
		return nil
	end
	local avgItem = frameRateManager:FindFirstChild("AverageFPS")
	if not avgItem then
		return nil
	end
	local numericValue = nil
	pcall(function()
		numericValue = avgItem:GetValue()
	end)
	if type(numericValue) == "number" and numericValue > 0 then
		return numericValue
	end
	local valueText = nil
	pcall(function()
		valueText = avgItem:GetValueString()
	end)
	if type(valueText) == "string" then
		local parsed = tonumber(string.match(valueText, "([%d%.]+)"))
		if parsed then
			return parsed
		end
	end
	return nil
end

local function SetRuntimePerformanceTier(nextTier)
	nextTier = math.clamp(math.floor(tonumber(nextTier) or 0), 0, 2)
	if runtimePerfTier == nextTier then
		return
	end
	runtimePerfTier = nextTier
	Player:SetAttribute("RuntimePerformanceTier", runtimePerfTier)

	if runtimePerfTier > 0 then
		if not isPotatoMode then
			activatePotatoMode()
		end
	else
		if isPotatoMode then
			activatePotatoMode()
		end
	end
end

if AUTO_PERF_ENABLED then
	task.spawn(function()
		local sampleClock = 0
		local lowTier1Time = 0
		local lowTier2Time = 0
		local recoverTime = 0
		while true do
			local dt = RunService.RenderStepped:Wait()
			sampleClock += dt
			if sampleClock < AUTO_PERF_SAMPLE_INTERVAL then
				continue
			end
			sampleClock = 0

			local fps = ReadAverageFPS() or (1 / math.max(dt, 1 / 240))
			if runtimePerfTier > 0 and not isPotatoMode then
				activatePotatoMode()
			end
			if runtimePerfTier == 0 then
				if fps < AUTO_PERF_ESCALATE1_FPS then
					lowTier1Time += AUTO_PERF_SAMPLE_INTERVAL
					if lowTier1Time >= AUTO_PERF_ESCALATE1_TIME then
						SetRuntimePerformanceTier(1)
						lowTier1Time = 0
						recoverTime = 0
					end
				else
					lowTier1Time = math.max(0, lowTier1Time - (AUTO_PERF_SAMPLE_INTERVAL * 0.5))
				end
			elseif runtimePerfTier == 1 then
				if fps < AUTO_PERF_ESCALATE2_FPS then
					lowTier2Time += AUTO_PERF_SAMPLE_INTERVAL
					if lowTier2Time >= AUTO_PERF_ESCALATE2_TIME then
						SetRuntimePerformanceTier(2)
						lowTier2Time = 0
						recoverTime = 0
					end
				else
					lowTier2Time = math.max(0, lowTier2Time - (AUTO_PERF_SAMPLE_INTERVAL * 0.5))
				end

				if fps >= AUTO_PERF_RECOVER0_FPS then
					recoverTime += AUTO_PERF_SAMPLE_INTERVAL
					if recoverTime >= AUTO_PERF_RECOVER_TIME then
						SetRuntimePerformanceTier(0)
						recoverTime = 0
						lowTier2Time = 0
					end
				else
					recoverTime = math.max(0, recoverTime - AUTO_PERF_SAMPLE_INTERVAL)
				end
			else
				if fps >= AUTO_PERF_RECOVER1_FPS then
					recoverTime += AUTO_PERF_SAMPLE_INTERVAL
					if recoverTime >= AUTO_PERF_RECOVER_TIME then
						SetRuntimePerformanceTier(1)
						recoverTime = 0
						lowTier2Time = 0
					end
				else
					recoverTime = math.max(0, recoverTime - AUTO_PERF_SAMPLE_INTERVAL)
				end
			end
		end
	end)
end

--------------------------------------------------------------------------------
-- UI BUILDER (matches Studio pill-toggle theme exactly)
--------------------------------------------------------------------------------

local function createSectionHeader(parent, text, layoutOrder)
	local lbl = Instance.new("TextLabel")
	lbl.Name = "SectionHeader_" .. text
	lbl.Size = UDim2.new(1, 0, 0, 25)
	lbl.BackgroundTransparency = 1
	lbl.Text = text
	lbl.TextColor3 = THEME.SectionColor
	lbl.Font = THEME.SectionFont
	lbl.TextSize = THEME.SectionSize
	lbl.TextXAlignment = Enum.TextXAlignment.Left
	lbl.LayoutOrder = layoutOrder
	local pad = Instance.new("UIPadding")
	pad.PaddingLeft = UDim.new(0, 8)
	pad.Parent = lbl
	lbl.Parent = parent
	return lbl
end

local function createToggleRow(parent, label, subtitle, layoutOrder, defaultOn, callback)
	local row = Instance.new("Frame")
	row.Name = label:gsub(" ", "")
	row.Size = UDim2.new(1, 0, 0, 42)
	row.BackgroundColor3 = THEME.RowBg
	row.BackgroundTransparency = 0
	row.LayoutOrder = layoutOrder
	row.Parent = parent
	Instance.new("UICorner", row).CornerRadius = UDim.new(0, 6)

	local lbl = Instance.new("TextLabel")
	lbl.Name = "TextLabel"
	lbl.Size = UDim2.new(0.7, 0, subtitle and 0.55 or 1, 0)
	lbl.Position = UDim2.new(0.027, 0, 0, 0)
	lbl.BackgroundTransparency = 1
	lbl.Text = label
	lbl.TextColor3 = THEME.LabelColor
	lbl.Font = THEME.LabelFont
	lbl.TextSize = THEME.LabelSize
	lbl.TextXAlignment = Enum.TextXAlignment.Left
	lbl.TextYAlignment = subtitle and Enum.TextYAlignment.Bottom or Enum.TextYAlignment.Center
	lbl.Parent = row
	local lblPad = Instance.new("UIPadding")
	lblPad.PaddingLeft = UDim.new(0, 4)
	lblPad.Parent = lbl

	if subtitle then
		local sub = Instance.new("TextLabel")
		sub.Name = "Subtitle"
		sub.Size = UDim2.new(0.7, 0, 0.4, 0)
		sub.Position = UDim2.new(0.027, 0, 0.55, 0)
		sub.BackgroundTransparency = 1
		sub.Text = subtitle
		sub.TextColor3 = THEME.SubLabelColor
		sub.Font = THEME.SubLabelFont
		sub.TextSize = THEME.SubLabelSize
		sub.TextXAlignment = Enum.TextXAlignment.Left
		sub.Parent = row
		local subPad = Instance.new("UIPadding")
		subPad.PaddingLeft = UDim.new(0, 4)
		subPad.Parent = sub
	end

	local toggle = Instance.new("TextButton")
	toggle.Name = "Toggle"
	toggle.Size = THEME.ToggleSize
	toggle.AnchorPoint = Vector2.new(0, 0.5)
	toggle.Position = THEME.TogglePos
	toggle.BackgroundColor3 = defaultOn and THEME.ToggleOnBg or THEME.ToggleOffBg
	toggle.Text = defaultOn and "ON" or "OFF"
	toggle.TextColor3 = Color3.fromRGB(0, 0, 0)
	toggle.TextTransparency = 0.27
	toggle.Font = Enum.Font.GothamBold
	toggle.TextSize = 14
	toggle.AutoButtonColor = true
	toggle.Parent = row
	Instance.new("UICorner", toggle).CornerRadius = THEME.ToggleCorner

	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.fromRGB(0, 0, 0)
	stroke.Thickness = 0.1
	stroke.Transparency = 0.53
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.Parent = toggle

	local isOn = defaultOn
	toggle.Activated:Connect(function()
		isOn = not isOn
		toggle.Text = isOn and "ON" or "OFF"
		toggle.BackgroundColor3 = isOn and THEME.ToggleOnBg or THEME.ToggleOffBg
		callback(isOn)
	end)

	return row, toggle
end

local bindGuiButton

local function createChoiceRow(parent, label, subtitle, layoutOrder, currentValue, choices, callback)
	local row = Instance.new("Frame")
	row.Name = label:gsub(" ", "")
	row.Size = UDim2.new(1, 0, 0, 42)
	row.BackgroundColor3 = THEME.RowBg
	row.BackgroundTransparency = 0
	row.LayoutOrder = layoutOrder
	row.Parent = parent
	Instance.new("UICorner", row).CornerRadius = UDim.new(0, 6)

	local lbl = Instance.new("TextLabel")
	lbl.Name = "TextLabel"
	lbl.Size = UDim2.new(0.7, 0, subtitle and 0.55 or 1, 0)
	lbl.Position = UDim2.new(0.027, 0, 0, 0)
	lbl.BackgroundTransparency = 1
	lbl.Text = label
	lbl.TextColor3 = THEME.LabelColor
	lbl.Font = THEME.LabelFont
	lbl.TextSize = THEME.LabelSize
	lbl.TextXAlignment = Enum.TextXAlignment.Left
	lbl.TextYAlignment = subtitle and Enum.TextYAlignment.Bottom or Enum.TextYAlignment.Center
	lbl.Parent = row
	local lblPad = Instance.new("UIPadding")
	lblPad.PaddingLeft = UDim.new(0, 4)
	lblPad.Parent = lbl

	if subtitle then
		local sub = Instance.new("TextLabel")
		sub.Name = "Subtitle"
		sub.Size = UDim2.new(0.7, 0, 0.4, 0)
		sub.Position = UDim2.new(0.027, 0, 0.55, 0)
		sub.BackgroundTransparency = 1
		sub.Text = subtitle
		sub.TextColor3 = THEME.SubLabelColor
		sub.Font = THEME.SubLabelFont
		sub.TextSize = THEME.SubLabelSize
		sub.TextXAlignment = Enum.TextXAlignment.Left
		sub.Parent = row
		local subPad = Instance.new("UIPadding")
		subPad.PaddingLeft = UDim.new(0, 4)
		subPad.Parent = sub
	end

	local button = Instance.new("TextButton")
	button.Name = "Choice"
	button.Size = UDim2.new(0.24, 0, 0.72, 0)
	button.AnchorPoint = Vector2.new(0, 0.5)
	button.Position = UDim2.new(0.72, 0, 0.5, 0)
	button.BackgroundColor3 = Color3.fromRGB(24, 27, 34)
	button.TextColor3 = THEME.LabelColor
	button.Font = Enum.Font.GothamBold
	button.TextSize = 12
	button.AutoButtonColor = true
	button.Parent = row
	Instance.new("UICorner", button).CornerRadius = UDim.new(0, 8)
	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.fromRGB(42, 48, 60)
	stroke.Transparency = 0.15
	stroke.Parent = button

	local index = 1
	for choiceIndex, choice in ipairs(choices) do
		if choice == currentValue then
			index = choiceIndex
			break
		end
	end

	local function syncChoiceButton()
		button.Text = string.upper(choices[index] or tostring(currentValue or ""))
	end

	bindGuiButton(button, function()
		index = (index % #choices) + 1
		syncChoiceButton()
		callback(choices[index])
	end)
	
	syncChoiceButton()
	return row, button
end

bindGuiButton = function(button, callback)
	if not (button and callback) then return end
	if button:GetAttribute("SettingsBound") then return end
	button:SetAttribute("SettingsBound", true)
	button.Active = true
	button.Selectable = true
	button.AutoButtonColor = true
	local busy = false
	button.Activated:Connect(function()
		if busy then return end
		busy = true
		releaseFocusedTextBox()
		callback()
		task.delay(0.15, function()
			busy = false
		end)
	end)
end

local function createActionButton(parent, text, color, layoutOrder, callback)
	local btn = Instance.new("TextButton")
	btn.Name = text:gsub(" ", "")
	btn.Size = UDim2.new(1, 0, 0, 42)
	btn.BackgroundColor3 = color
	btn.Text = text
	btn.TextColor3 = Color3.fromRGB(255, 255, 255)
	btn.Font = Enum.Font.GothamBlack
	btn.TextSize = 15
	btn.LayoutOrder = layoutOrder
	btn.AutoButtonColor = true
	btn.Parent = parent
	Instance.new("UICorner", btn).CornerRadius = THEME.RowCorner

	bindGuiButton(btn, callback)
	return btn
end

applyResponsiveGuestCapRow = function(row, isTouchLayout)
	if not (row and row:IsA("Frame")) then
		return
	end
	local meta = row:FindFirstChild("Meta")
	local toggle = row:FindFirstChild("EnabledToggle")
	local input = row:FindFirstChild("Input")
	local minus = row:FindFirstChild("Minus")
	local plus = row:FindFirstChild("Plus")
	local apply = row:FindFirstChild("Apply")
	if not (meta and toggle and input and minus and plus and apply) then
		return
	end

	local rowWidth = math.max(row.AbsoluteSize.X, 320)
	local compact = isTouchLayout or rowWidth < 620
	if compact then
		row.Size = UDim2.new(1, 0, 0, 168)
		meta.Position = UDim2.fromOffset(12, 26)
		meta.Size = UDim2.new(1, -24, 0, 24)
		toggle.Position = UDim2.fromOffset(12, 54)
		toggle.Size = UDim2.fromOffset(76, 24)
		input.Position = UDim2.fromOffset(12, 84)
		input.Size = UDim2.fromOffset(90, 28)
		minus.Position = UDim2.fromOffset(108, 84)
		minus.Size = UDim2.fromOffset(28, 28)
		plus.Position = UDim2.fromOffset(142, 84)
		plus.Size = UDim2.fromOffset(28, 28)
		apply.Position = UDim2.fromOffset(12, 126)
		apply.Size = UDim2.new(1, -24, 0, 30)
	else
		row.Size = UDim2.new(1, 0, 0, 128)
		meta.Position = UDim2.fromOffset(12, 26)
		meta.Size = UDim2.new(1, -24, 0, 12)
		toggle.Position = UDim2.fromOffset(12, 42)
		toggle.Size = UDim2.fromOffset(76, 26)
		input.Position = UDim2.fromOffset(94, 42)
		input.Size = UDim2.fromOffset(82, 26)
		minus.Position = UDim2.fromOffset(182, 42)
		minus.Size = UDim2.fromOffset(28, 26)
		plus.Position = UDim2.fromOffset(216, 42)
		plus.Size = UDim2.fromOffset(28, 26)
		apply.Position = UDim2.new(1, -88, 0, 42)
		apply.Size = UDim2.fromOffset(76, 26)
	end
end

local function createGuestCapRow(parent, layoutOrder)
	local row = Instance.new("Frame")
	row.Name = "GuestCapRow"
	row.Size = UDim2.new(1, 0, 0, 128)
	row.BackgroundColor3 = THEME.RowBg
	row.BorderSizePixel = 0
	row.LayoutOrder = layoutOrder
	row.Parent = parent
	Instance.new("UICorner", row).CornerRadius = THEME.RowCorner
	local rowStroke = Instance.new("UIStroke")
	rowStroke.Color = Color3.fromRGB(32, 36, 44)
	rowStroke.Parent = row

	local title = Instance.new("TextLabel")
	title.Name = "Title"
	title.BackgroundTransparency = 1
	title.Position = UDim2.fromOffset(12, 8)
	title.Size = UDim2.new(1, -24, 0, 16)
	title.Text = "Max Guests"
	title.TextColor3 = THEME.LabelColor
	title.Font = Enum.Font.GothamBold
	title.TextSize = 15
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.Parent = row

	local meta = Instance.new("TextLabel")
	meta.Name = "Meta"
	meta.BackgroundTransparency = 1
	meta.Position = UDim2.fromOffset(12, 26)
	meta.Size = UDim2.new(1, -24, 0, 12)
	meta.TextColor3 = THEME.SubLabelColor
	meta.Font = THEME.SubLabelFont
	meta.TextSize = THEME.SubLabelSize
	meta.TextXAlignment = Enum.TextXAlignment.Left
	meta.Parent = row

	local toggle = Instance.new("TextButton")
	toggle.Name = "EnabledToggle"
	toggle.Position = UDim2.fromOffset(12, 42)
	toggle.Size = UDim2.fromOffset(76, 26)
	toggle.BackgroundColor3 = THEME.ToggleOffBg
	toggle.Text = "OFF"
	toggle.TextColor3 = Color3.fromRGB(255, 255, 255)
	toggle.Font = Enum.Font.GothamBlack
	toggle.TextSize = 11
	toggle.Parent = row
	local toggleCorner = Instance.new("UICorner")
	toggleCorner.CornerRadius = UDim.new(0, 8)
	toggleCorner.Parent = toggle
	local toggleStroke = Instance.new("UIStroke")
	toggleStroke.Color = Color3.fromRGB(42, 48, 60)
	toggleStroke.Transparency = 0.2
	toggleStroke.Parent = toggle

	local input = Instance.new("TextBox")
	input.Name = "Input"
	input.Position = UDim2.fromOffset(94, 42)
	input.Size = UDim2.fromOffset(82, 26)
	input.BackgroundColor3 = Color3.fromRGB(24, 27, 34)
	input.TextColor3 = Color3.fromRGB(120, 255, 180)
	input.PlaceholderText = "0"
	input.ClearTextOnFocus = false
	input.Font = Enum.Font.GothamBold
	input.TextSize = 16
	input.Parent = row
	local inputCorner = Instance.new("UICorner")
	inputCorner.CornerRadius = UDim.new(0, 6)
	inputCorner.Parent = input
	local inputStroke = Instance.new("UIStroke")
	inputStroke.Color = Color3.fromRGB(42, 48, 60)
	inputStroke.Transparency = 0.2
	inputStroke.Parent = input

	local minus = Instance.new("TextButton")
	minus.Name = "Minus"
	minus.Size = UDim2.fromOffset(28, 26)
	minus.Position = UDim2.fromOffset(182, 42)
	minus.BackgroundColor3 = Color3.fromRGB(24, 27, 34)
	minus.Text = "-"
	minus.TextColor3 = THEME.LabelColor
	minus.Font = Enum.Font.GothamBlack
	minus.TextSize = 14
	minus.Parent = row
	local minusCorner = Instance.new("UICorner")
	minusCorner.CornerRadius = UDim.new(0, 8)
	minusCorner.Parent = minus
	local minusStroke = Instance.new("UIStroke")
	minusStroke.Color = Color3.fromRGB(42, 48, 60)
	minusStroke.Transparency = 0.2
	minusStroke.Parent = minus

	local plus = Instance.new("TextButton")
	plus.Name = "Plus"
	plus.Size = UDim2.fromOffset(28, 26)
	plus.Position = UDim2.fromOffset(216, 42)
	plus.BackgroundColor3 = Color3.fromRGB(24, 27, 34)
	plus.Text = "+"
	plus.TextColor3 = THEME.LabelColor
	plus.Font = Enum.Font.GothamBlack
	plus.TextSize = 14
	plus.Parent = row
	local plusCorner = Instance.new("UICorner")
	plusCorner.CornerRadius = UDim.new(0, 8)
	plusCorner.Parent = plus
	local plusStroke = Instance.new("UIStroke")
	plusStroke.Color = Color3.fromRGB(42, 48, 60)
	plusStroke.Transparency = 0.2
	plusStroke.Parent = plus

	local apply = Instance.new("TextButton")
	apply.Name = "Apply"
	apply.Position = UDim2.new(1, -88, 0, 42)
	apply.Size = UDim2.fromOffset(76, 26)
	apply.BackgroundColor3 = Color3.fromRGB(0, 120, 215)
	apply.Text = "APPLY"
	apply.TextColor3 = Color3.fromRGB(255, 255, 255)
	apply.Font = Enum.Font.GothamBold
	apply.TextSize = 11
	apply.BorderSizePixel = 0
	apply.Parent = row
	local applyCorner = Instance.new("UICorner")
	applyCorner.CornerRadius = UDim.new(0, 8)
	applyCorner.Parent = apply
	local applyStroke = Instance.new("UIStroke")
	applyStroke.Color = Color3.fromRGB(10, 60, 120)
	applyStroke.Transparency = 0.15
	applyStroke.Parent = apply

	local function parseValue()
		local digits = tostring(input.Text or ""):gsub("[^%d]", "")
		return sanitizeGuestCapValue(tonumber(digits) or SETTINGS.MaxGuestCap or 0)
	end

	local function getEnabledCapValue()
		local value = parseValue()
		if value <= 0 then
			return 500
		end
		return value
	end

	local function syncGuestCapUi()
		local enabled = SETTINGS.MaxGuestCapEnabled == true
		local currentValue = sanitizeGuestCapValue(SETTINGS.MaxGuestCap)
		if enabled and currentValue <= 0 then
			currentValue = 500
		end

		meta.Text = enabled
			and string.format("ON = manual guest cap enabled. Current max %d", currentValue)
			or "OFF = unlimited guests (manual max cap disabled)."
		toggle.Text = enabled and "ON" or "OFF"
		toggle.BackgroundColor3 = enabled and THEME.ToggleOnBg or THEME.ToggleOffBg

		input.TextEditable = enabled
		input.TextColor3 = enabled and Color3.fromRGB(120, 255, 180) or Color3.fromRGB(130, 140, 160)
		if not input:IsFocused() then
			input.Text = tostring(currentValue)
		end

		minus.Active = enabled
		minus.AutoButtonColor = enabled
		minus.TextTransparency = enabled and 0 or 0.45
		minus.BackgroundTransparency = enabled and 0 or 0.35

		plus.Active = enabled
		plus.AutoButtonColor = enabled
		plus.TextTransparency = enabled and 0 or 0.45
		plus.BackgroundTransparency = enabled and 0 or 0.35

		apply.Active = enabled
		apply.AutoButtonColor = enabled
		apply.Text = enabled and "APPLY" or "OFF"
		apply.BackgroundColor3 = enabled and Color3.fromRGB(0, 120, 215) or Color3.fromRGB(65, 67, 78)
		apply.TextTransparency = enabled and 0 or 0.25
	end

	local function flashApply(text, color)
		apply.Text = text
		apply.BackgroundColor3 = color
		task.delay(0.9, function()
			if apply and apply.Parent then
				syncGuestCapUi()
			end
		end)
	end

	bindGuiButton(toggle, function()
		local enableCap = not (SETTINGS.MaxGuestCapEnabled == true)
		setGuestCapEnabled(enableCap)
		if enableCap and sanitizeGuestCapValue(SETTINGS.MaxGuestCap) <= 0 then
			setGuestCap(500)
		end
		syncGuestCapUi()
	end)

	bindGuiButton(minus, function()
		if SETTINGS.MaxGuestCapEnabled ~= true then
			return
		end
		input.Text = tostring(math.max(25, getEnabledCapValue() - 25))
	end)
	bindGuiButton(plus, function()
		if SETTINGS.MaxGuestCapEnabled ~= true then
			return
		end
		input.Text = tostring(math.min(5000, getEnabledCapValue() + 25))
	end)
	bindGuiButton(apply, function()
		if SETTINGS.MaxGuestCapEnabled ~= true then
			syncGuestCapUi()
			return
		end
		local value = getEnabledCapValue()
		setGuestCap(value)
		input.Text = tostring(value)
		flashApply("SAVED", Color3.fromRGB(40, 160, 80))
	end)
	input.FocusLost:Connect(function()
		if SETTINGS.MaxGuestCapEnabled == true then
			input.Text = tostring(getEnabledCapValue())
		else
			input.Text = tostring(sanitizeGuestCapValue(SETTINGS.MaxGuestCap))
		end
	end)
	Player:GetAttributeChangedSignal("GuestCap"):Connect(function()
		SETTINGS.MaxGuestCap = sanitizeGuestCapValue(Player:GetAttribute("GuestCap"))
		syncGuestCapUi()
	end)
	Player:GetAttributeChangedSignal("GuestCapEnabled"):Connect(function()
		SETTINGS.MaxGuestCapEnabled = Player:GetAttribute("GuestCapEnabled") == true
		syncGuestCapUi()
	end)
	syncGuestCapUi()
	applyResponsiveGuestCapRow(row, UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled)
	return row
end

local function createRedeemCodeRow(parent, layoutOrder)
	local row = Instance.new("Frame")
	row.Name = "RedeemCodeRow"
	row.Size = UDim2.new(1, 0, 0, 78)
	row.BackgroundColor3 = THEME.RowBg
	row.BorderSizePixel = 0
	row.LayoutOrder = layoutOrder
	row.Parent = parent
	Instance.new("UICorner", row).CornerRadius = UDim.new(0, 6)

	local title = Instance.new("TextLabel")
	title.Name = "Title"
	title.BackgroundTransparency = 1
	title.Position = UDim2.fromOffset(12, 8)
	title.Size = UDim2.new(1, -24, 0, 16)
	title.Text = "Redeem Code"
	title.TextColor3 = Color3.fromRGB(255, 205, 120)
	title.Font = Enum.Font.GothamBold
	title.TextSize = 14
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.Parent = row

	local subtitle = Instance.new("TextLabel")
	subtitle.Name = "Subtitle"
	subtitle.BackgroundTransparency = 1
	subtitle.Position = UDim2.fromOffset(12, 25)
	subtitle.Size = UDim2.new(1, -24, 0, 14)
	subtitle.Text = "Enter limited-time reward codes"
	subtitle.TextColor3 = THEME.SubLabelColor
	subtitle.Font = THEME.SubLabelFont
	subtitle.TextSize = THEME.SubLabelSize
	subtitle.TextXAlignment = Enum.TextXAlignment.Left
	subtitle.Parent = row

	local input = Instance.new("TextBox")
	input.Name = "Input"
	input.Position = UDim2.fromOffset(12, 43)
	input.Size = UDim2.new(1, -132, 0, 28)
	input.BackgroundColor3 = Color3.fromRGB(24, 27, 34)
	input.Text = ""
	input.PlaceholderText = "Type code..."
	input.PlaceholderColor3 = Color3.fromRGB(110, 110, 130)
	input.TextColor3 = Color3.fromRGB(255, 255, 255)
	input.Font = Enum.Font.GothamBold
	input.TextSize = 14
	input.ClearTextOnFocus = false
	input.Parent = row
	local inputCorner = Instance.new("UICorner")
	inputCorner.CornerRadius = UDim.new(0, 6)
	inputCorner.Parent = input
	local inputPad = Instance.new("UIPadding")
	inputPad.PaddingLeft = UDim.new(0, 8)
	inputPad.Parent = input

	local redeemBtn = Instance.new("TextButton")
	redeemBtn.Name = "Redeem"
	redeemBtn.Position = UDim2.new(1, -112, 0, 43)
	redeemBtn.Size = UDim2.fromOffset(100, 28)
	redeemBtn.BackgroundColor3 = Color3.fromRGB(0, 120, 215)
	redeemBtn.Text = "REDEEM"
	redeemBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
	redeemBtn.Font = Enum.Font.GothamBold
	redeemBtn.TextSize = 12
	redeemBtn.Parent = row
	local btnCorner = Instance.new("UICorner")
	btnCorner.CornerRadius = UDim.new(0, 6)
	btnCorner.Parent = redeemBtn

	local busy = false
	local function setButton(text, color)
		redeemBtn.Text = text
		redeemBtn.BackgroundColor3 = color
	end

	input.FocusLost:Connect(function()
		input.Text = string.upper(string.gsub(tostring(input.Text or ""), "%s+", ""))
	end)

	bindGuiButton(redeemBtn, function()
		if busy then
			return
		end
		local code = string.upper(string.gsub(tostring(input.Text or ""), "%s+", ""))
		if code == "" then
			setButton("ENTER CODE", Color3.fromRGB(170, 80, 70))
			task.delay(1, function()
				if redeemBtn and redeemBtn.Parent then
					setButton("REDEEM", Color3.fromRGB(0, 120, 215))
				end
			end)
			return
		end

		local redeemRemote = Events:FindFirstChild("RedeemCode")
		if not (redeemRemote and redeemRemote:IsA("RemoteFunction")) then
			setButton("OFFLINE", Color3.fromRGB(170, 80, 70))
			task.delay(1.2, function()
				if redeemBtn and redeemBtn.Parent then
					setButton("REDEEM", Color3.fromRGB(0, 120, 215))
				end
			end)
			return
		end

		busy = true
		setButton("CHECKING...", Color3.fromRGB(70, 100, 150))
		local ok, result = pcall(function()
			return redeemRemote:InvokeServer(code)
		end)
		if ok and type(result) == "table" and result.Success == true then
			setButton("REDEEMED", Color3.fromRGB(40, 160, 90))
			input.Text = ""
		else
			setButton("INVALID", Color3.fromRGB(170, 80, 70))
		end
		task.delay(1.2, function()
			busy = false
			if redeemBtn and redeemBtn.Parent then
				setButton("REDEEM", Color3.fromRGB(0, 120, 215))
			end
		end)
	end)

	return row
end

local _settingsFrame = nil
local settingsTween = nil
local settingsTweenToken = 0
local settingsDock = nil
local openSettings
local closeSettings
local toggleSettings

local function createManualSaveRow(parent, layoutOrder)
	local row = Instance.new("Frame")
	row.Name = "ManualSaveRow"
	row.Size = UDim2.new(1, 0, 0, 72)
	row.BackgroundColor3 = THEME.RowBg
	row.BorderSizePixel = 0
	row.LayoutOrder = layoutOrder
	row.Parent = parent
	Instance.new("UICorner", row).CornerRadius = THEME.RowCorner

	local title = Instance.new("TextLabel")
	title.Name = "Title"
	title.Size = UDim2.new(0.62, 0, 0, 20)
	title.Position = UDim2.fromOffset(12, 8)
	title.BackgroundTransparency = 1
	title.Text = "Manual Save (Fallback)"
	title.TextColor3 = Color3.fromRGB(120, 220, 255)
	title.Font = Enum.Font.GothamBold
	title.TextSize = 14
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.Parent = row

	local subtitle = Instance.new("TextLabel")
	subtitle.Name = "Subtitle"
	subtitle.Size = UDim2.new(0.62, 0, 0, 30)
	subtitle.Position = UDim2.fromOffset(12, 28)
	subtitle.BackgroundTransparency = 1
	subtitle.Text = "Forces an immediate full save across all systems."
	subtitle.TextColor3 = THEME.SubLabelColor
	subtitle.Font = THEME.SubLabelFont
	subtitle.TextSize = THEME.SubLabelSize
	subtitle.TextWrapped = true
	subtitle.TextXAlignment = Enum.TextXAlignment.Left
	subtitle.TextYAlignment = Enum.TextYAlignment.Top
	subtitle.Parent = row

	local saveBtn = Instance.new("TextButton")
	saveBtn.Name = "SaveNow"
	saveBtn.Size = UDim2.fromOffset(118, 34)
	saveBtn.Position = UDim2.new(1, -130, 0, 10)
	saveBtn.BackgroundColor3 = Color3.fromRGB(0, 120, 215)
	saveBtn.Text = "SAVE NOW"
	saveBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
	saveBtn.Font = Enum.Font.GothamBlack
	saveBtn.TextSize = 12
	saveBtn.Parent = row
	Instance.new("UICorner", saveBtn).CornerRadius = UDim.new(0, 8)

	local status = Instance.new("TextLabel")
	status.Name = "Status"
	status.Size = UDim2.fromOffset(118, 18)
	status.Position = UDim2.new(1, -130, 0, 48)
	status.BackgroundTransparency = 1
	status.Text = "Idle"
	status.TextColor3 = THEME.SubLabelColor
	status.Font = Enum.Font.Gotham
	status.TextSize = 11
	status.TextXAlignment = Enum.TextXAlignment.Center
	status.Parent = row

	local opNonce = 0
	bindGuiButton(saveBtn, function()
		if manualSaveBusy then
			status.Text = "Save in progress"
			status.TextColor3 = Color3.fromRGB(255, 210, 120)
			return
		end
		opNonce += 1
		local thisOp = opNonce
		saveBtn.Text = "SAVING..."
		saveBtn.BackgroundColor3 = Color3.fromRGB(70, 110, 170)
		status.Text = "Contacting server..."
		status.TextColor3 = THEME.SubLabelColor

		task.spawn(function()
			local ok, message = requestManualSave()
			if thisOp ~= opNonce or not (saveBtn and saveBtn.Parent and status and status.Parent) then
				return
			end

			if ok then
				saveBtn.Text = "SAVED"
				saveBtn.BackgroundColor3 = Color3.fromRGB(40, 160, 90)
				status.Text = "Saved at " .. os.date("%X")
				status.TextColor3 = Color3.fromRGB(120, 230, 170)
				task.delay(1.2, function()
					if thisOp ~= opNonce or not (saveBtn and saveBtn.Parent and status and status.Parent) then
						return
					end
					saveBtn.Text = "SAVE NOW"
					saveBtn.BackgroundColor3 = Color3.fromRGB(0, 120, 215)
					status.TextColor3 = THEME.SubLabelColor
				end)
			else
				saveBtn.Text = "SAVE NOW"
				saveBtn.BackgroundColor3 = Color3.fromRGB(0, 120, 215)
				status.Text = message or "Save failed"
				status.TextColor3 = Color3.fromRGB(255, 150, 120)
			end
		end)
	end)

	return row
end

local function createReturnToLobbyRow(parent, layoutOrder)
	local row = Instance.new("Frame")
	row.Name = "ReturnToLobbyRow"
	row.Size = UDim2.new(1, 0, 0, 72)
	row.BackgroundColor3 = THEME.RowBg
	row.BorderSizePixel = 0
	row.LayoutOrder = layoutOrder
	row.Parent = parent
	Instance.new("UICorner", row).CornerRadius = THEME.RowCorner

	local title = Instance.new("TextLabel")
	title.Name = "Title"
	title.Size = UDim2.new(0.62, 0, 0, 20)
	title.Position = UDim2.fromOffset(12, 8)
	title.BackgroundTransparency = 1
	title.Text = "Return To Lobby"
	title.TextColor3 = Color3.fromRGB(255, 220, 120)
	title.Font = Enum.Font.GothamBold
	title.TextSize = 14
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.Parent = row

	local subtitle = Instance.new("TextLabel")
	subtitle.Name = "Subtitle"
	subtitle.Size = UDim2.new(0.62, 0, 0, 30)
	subtitle.Position = UDim2.fromOffset(12, 28)
	subtitle.BackgroundTransparency = 1
	subtitle.Text = "Go back to the resort slot screen without leaving the game."
	subtitle.TextColor3 = THEME.SubLabelColor
	subtitle.Font = THEME.SubLabelFont
	subtitle.TextSize = THEME.SubLabelSize
	subtitle.TextWrapped = true
	subtitle.TextXAlignment = Enum.TextXAlignment.Left
	subtitle.TextYAlignment = Enum.TextYAlignment.Top
	subtitle.Parent = row

	local lobbyBtn = Instance.new("TextButton")
	lobbyBtn.Name = "BackToLobby"
	lobbyBtn.Size = UDim2.fromOffset(132, 34)
	lobbyBtn.Position = UDim2.new(1, -144, 0, 10)
	lobbyBtn.BackgroundColor3 = Color3.fromRGB(180, 105, 40)
	lobbyBtn.Text = "BACK TO LOBBY"
	lobbyBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
	lobbyBtn.Font = Enum.Font.GothamBlack
	lobbyBtn.TextSize = 11
	lobbyBtn.Parent = row
	Instance.new("UICorner", lobbyBtn).CornerRadius = UDim.new(0, 8)

	local status = Instance.new("TextLabel")
	status.Name = "Status"
	status.Size = UDim2.fromOffset(132, 18)
	status.Position = UDim2.new(1, -144, 0, 48)
	status.BackgroundTransparency = 1
	status.Text = "Press once"
	status.TextColor3 = THEME.SubLabelColor
	status.Font = Enum.Font.Gotham
	status.TextSize = 11
	status.TextXAlignment = Enum.TextXAlignment.Center
	status.Parent = row

	local confirmUntil = 0
	local teleporting = false
	bindGuiButton(lobbyBtn, function()
		if teleporting then
			return
		end

		local now = os.clock()
		if now > confirmUntil then
			confirmUntil = now + 3
			lobbyBtn.Text = "PRESS AGAIN"
			lobbyBtn.BackgroundColor3 = Color3.fromRGB(215, 130, 55)
			status.Text = "Tap again to confirm"
			status.TextColor3 = Color3.fromRGB(255, 220, 120)
			task.delay(3, function()
				if teleporting or os.clock() <= confirmUntil or not (lobbyBtn and lobbyBtn.Parent and status and status.Parent) then
					return
				end
				lobbyBtn.Text = "BACK TO LOBBY"
				lobbyBtn.BackgroundColor3 = Color3.fromRGB(180, 105, 40)
				status.Text = "Press once"
				status.TextColor3 = THEME.SubLabelColor
			end)
			return
		end

		teleporting = true
		status.Text = "Teleporting..."
		status.TextColor3 = Color3.fromRGB(120, 230, 170)
		lobbyBtn.Text = "LEAVING..."
		lobbyBtn.BackgroundColor3 = Color3.fromRGB(80, 140, 90)
		closeSettings(_settingsFrame)

		local ok, err = pcall(function()
			TeleportService:Teleport(LOBBY_PLACE_ID, Player)
		end)
		if not ok then
			teleporting = false
			confirmUntil = 0
			status.Text = "Teleport failed"
			status.TextColor3 = Color3.fromRGB(255, 150, 120)
			lobbyBtn.Text = "BACK TO LOBBY"
			lobbyBtn.BackgroundColor3 = Color3.fromRGB(180, 105, 40)
			warn("[SettingsController] Return to lobby failed: " .. tostring(err))
		end
	end)

	return row
end

--------------------------------------------------------------------------------
-- PANEL OPEN/CLOSE
--------------------------------------------------------------------------------
local ClosePanels = Events:FindFirstChild("ClosePanels")
if not ClosePanels then
	ClosePanels = Instance.new("BindableEvent")
	ClosePanels.Name = "ClosePanels"
	ClosePanels.Parent = Events
end

local function playSettingsTween(frame, targetPos)
	if settingsTween then
		settingsTween:Cancel()
		settingsTween = nil
	end
	settingsTween = TweenService:Create(frame, TWEEN_INFO, {Position = targetPos})
	settingsTween:Play()
end

ClosePanels.Event:Connect(function(source)
	if source == "Settings" then return end
	if isSettingsOpen and _settingsFrame then
		settingsTweenToken += 1
		local tweenToken = settingsTweenToken
		isSettingsOpen = false
		playSettingsTween(_settingsFrame, SETTINGS_POS_HIDDEN)
		task.delay(TWEEN_INFO.Time, function()
			if tweenToken == settingsTweenToken and not isSettingsOpen and _settingsFrame then
				_settingsFrame.Visible = false
			end
		end)
	end
end)

openSettings = function(frame)
	if isSettingsOpen and frame.Visible then return end
	settingsTweenToken += 1
	isSettingsOpen = true
	_settingsFrame = frame
	ClosePanels:Fire("Settings")
	frame.Active = true
	frame.Visible = true
	local content = frame:FindFirstChild("Content")
	if content then
		refreshSettingsUiFromState()
		applyResponsiveSettingsLayout(frame, content)
	end
	local sg = frame:FindFirstAncestorOfClass("ScreenGui")
	if sg then sg.Enabled = true end
	playSettingsTween(frame, SETTINGS_POS_VISIBLE)
end

closeSettings = function(frame)
	if not frame then return end
	releaseFocusedTextBox()
	UserInputService.MouseBehavior = Enum.MouseBehavior.Default
	UserInputService.MouseIconEnabled = true
	settingsTweenToken += 1
	local tweenToken = settingsTweenToken
	isSettingsOpen = false
	playSettingsTween(frame, SETTINGS_POS_HIDDEN)
	task.delay(TWEEN_INFO.Time, function()
		if tweenToken == settingsTweenToken and not isSettingsOpen and frame then
			frame.Visible = false
		end
	end)
end

toggleSettings = function(frame)
	if isSettingsOpen then closeSettings(frame) else openSettings(frame) end
end

local settingsFilterState = {
	Tab = "All",
	Query = "",
}

local settingsTabButtons = {}

local SETTINGS_CATEGORY_BY_ROW = {
	Music = "Visual",
	Weather = "Visual",
	Shadows = "Visual",
	Particles = "Visual",
	Trees = "Visual",
	GuestModels = "Visual",
	Atmosphere = "Visual",
	SunRays = "Visual",
	Bloom = "Visual",
	Decorations = "Visual",
	GuestLOD = "Visual",
	GuestPerformanceMode = "Visual",
	GraphicsPreset = "Visual",
	BuildingRenderDistance = "Visual",
	LiftRenderDistance = "Visual",
	NPCRenderDistance = "Visual",
	WeatherQuality = "Visual",
	ParticleQuality = "Visual",
	ParticleDensity = "Visual",
	RealisticParticles = "Visual",
	AdaptiveParticleBudget = "Visual",
	FogEdgeBlend = "Visual",
	FogEdgeIntensity = "Visual",
	SlopeDifficultyOverlay = "Gameplay",
	UnitSystem = "Gameplay",
	ShowFPSCounter = "Gameplay",
	ShowMobileSkiButton = "Gameplay",
	GuestCapRow = "Gameplay",
	EnablePotatoMode = "System",
	ManualSaveRow = "System",
	ReturnToLobbyRow = "System",
	JoinCodeDisplay = "Multiplayer",
	JoinFriend = "Multiplayer",
	TrustedFriendsManager = "Multiplayer",
	MultiplayerAccessInfo = "Multiplayer",
	VisitorsCanBuild = "Multiplayer",
	VisitorsCanDelete = "Multiplayer",
	TrustedCanBuild = "Multiplayer",
	TrustedCanDelete = "Multiplayer",
	TrustedUseHostResearch = "Multiplayer",
	FriendWhitelistManager = "Multiplayer",
	RedeemCodeRow = "System",
	Divider = "Multiplayer",
}

local function getSettingsCategoryForRow(row)
	if not row then
		return "System"
	end
	local explicit = row:GetAttribute("SettingsCategory")
	if type(explicit) == "string" and explicit ~= "" then
		return explicit
	end
	local mapped = SETTINGS_CATEGORY_BY_ROW[row.Name]
	if mapped then
		row:SetAttribute("SettingsCategory", mapped)
		return mapped
	end
	if string.find(row.Name, "SectionHeader_", 1, true) == 1 then
		local headerText = string.upper(string.gsub(string.sub(row.Name, 15), "_", " "))
		if headerText:find("GRAPHICS", 1, true) or headerText:find("PERFORMANCE", 1, true) then
			mapped = "Visual"
		elseif headerText:find("MULTIPLAYER", 1, true) or headerText:find("RESORT ACCESS", 1, true) then
			mapped = "Multiplayer"
		elseif headerText:find("CODE", 1, true) or headerText:find("SYSTEM", 1, true) then
			mapped = "System"
		elseif headerText:find("GAMEPLAY", 1, true) then
			mapped = "Gameplay"
		else
			mapped = "Gameplay"
		end
		row:SetAttribute("SettingsCategory", mapped)
		return mapped
	end
	row:SetAttribute("SettingsCategory", "System")
	return "System"
end

local function getSettingsRowSearchText(row)
	local chunks = { row.Name }
	for _, desc in ipairs(row:GetDescendants()) do
		if desc:IsA("TextLabel") or desc:IsA("TextButton") then
			if type(desc.Text) == "string" and desc.Text ~= "" then
				table.insert(chunks, desc.Text)
			end
		elseif desc:IsA("TextBox") then
			if type(desc.PlaceholderText) == "string" and desc.PlaceholderText ~= "" then
				table.insert(chunks, desc.PlaceholderText)
			end
		end
	end
	return string.lower(table.concat(chunks, " "))
end

local function setSettingsRowVisible(row, visible)
	if not row:IsA("GuiObject") then
		return
	end
	if row:GetAttribute("FilterBaseXScale") == nil then
		row:SetAttribute("FilterBaseXScale", row.Size.X.Scale)
		row:SetAttribute("FilterBaseXOffset", row.Size.X.Offset)
		row:SetAttribute("FilterBaseYScale", row.Size.Y.Scale)
		row:SetAttribute("FilterBaseYOffset", row.Size.Y.Offset)
	end

	if visible then
		row.Visible = true
		row.Size = UDim2.new(
			row:GetAttribute("FilterBaseXScale") or row.Size.X.Scale,
			row:GetAttribute("FilterBaseXOffset") or row.Size.X.Offset,
			row:GetAttribute("FilterBaseYScale") or row.Size.Y.Scale,
			row:GetAttribute("FilterBaseYOffset") or row.Size.Y.Offset
		)
	else
		row.Visible = false
		row.Size = UDim2.new(
			row:GetAttribute("FilterBaseXScale") or row.Size.X.Scale,
			row:GetAttribute("FilterBaseXOffset") or row.Size.X.Offset,
			0,
			0
		)
	end
end

local function refreshSettingsTabButtons()
	for tabName, button in pairs(settingsTabButtons) do
		if button and button.Parent then
			local selected = (settingsFilterState.Tab == tabName)
			button.BackgroundColor3 = selected and Color3.fromRGB(0, 120, 215) or Color3.fromRGB(24, 27, 34)
			button.TextColor3 = selected and Color3.fromRGB(255, 255, 255) or Color3.fromRGB(200, 205, 220)
		end
	end
end

local function applySettingsFilters(content)
	if not content then
		return
	end
	local activeTab = settingsFilterState.Tab or "All"
	local query = string.lower(settingsFilterState.Query or "")
	for _, child in ipairs(content:GetChildren()) do
		if child:IsA("GuiObject") and not child:IsA("UIListLayout") and not child:IsA("UIPadding") then
			local category = getSettingsCategoryForRow(child)
			local matchesTab = (activeTab == "All") or (category == activeTab)
			local matchesQuery = true
			if query ~= "" then
				matchesQuery = string.find(getSettingsRowSearchText(child), query, 1, true) ~= nil
			end
			setSettingsRowVisible(child, matchesTab and matchesQuery)
		end
	end
	refreshSettingsTabButtons()
	refreshSettingsCanvas(content)
	task.defer(function()
		refreshSettingsCanvas(content)
	end)
end

--------------------------------------------------------------------------------
-- CONNECT UI
--------------------------------------------------------------------------------
local function ConnectUI()
	local mainHud = PlayerGui:WaitForChild("MainHUD", 10)
	if not mainHud then warn("❌ SettingsController: MainHUD not found!") return end

	local dock = mainHud:WaitForChild("Dock", 10)
	local settingsFrame = mainHud:WaitForChild("SettingsFrame", 10)
	settingsDock = dock
	if not dock or not settingsFrame then warn("❌ SettingsController: Missing UI!") return end

	-- Start hidden
	settingsFrame.Position = SETTINGS_POS_HIDDEN
	settingsFrame.Visible = false

	-- Wire dock button
	local dockAliases = {"settings", "setting", "options", "gear", "config"}
	local function onDockClick()
		toggleSettings(settingsFrame)
	end
	for _, desc in ipairs(dock:GetDescendants()) do
		if desc:IsA("GuiButton") then
			local name = desc.Name:lower():gsub("[%s_%-]+", "")
			for _, alias in ipairs(dockAliases) do
				if name:find(alias) then
					bindGuiButton(desc, onDockClick)
					
					break
				end
			end
		end
	end

	-- Wire close button
	local header = settingsFrame:FindFirstChild("Header")
	if header then
		local closeBtn = header:FindFirstChild("CloseButton")
		if closeBtn then
			bindGuiButton(closeBtn, function()
				closeSettings(settingsFrame)
			end)
		end
	end

	-- Get or create Content scroll frame
	local content = settingsFrame:FindFirstChild("Content")
	if not content then
		content = Instance.new("ScrollingFrame")
		content.Name = "Content"
		content.Size = UDim2.new(0.99, 0, 0.875, 0)
		content.Position = UDim2.new(0.008, 0, 0.125, 0)
		content.BackgroundTransparency = 1
		content.ScrollBarThickness = 4
		content.ScrollBarImageColor3 = Color3.fromRGB(80, 80, 100)
		content.Parent = settingsFrame
	end
	applyResponsiveSettingsLayout(settingsFrame, content)
	bindViewportResponsive(settingsFrame, content)

	local closeBtn = header and header:FindFirstChild("CloseButton")
	if closeBtn and closeBtn:IsA("GuiButton") then
		closeBtn.AnchorPoint = Vector2.new(1, 0.5)
		closeBtn.Position = UDim2.new(1, -24, 0.5, 0)
	end

	if header then
		local searchBox = header:FindFirstChild("SettingsSearch")
		if searchBox and not searchBox:IsA("TextBox") then
			searchBox:Destroy()
			searchBox = nil
		end
		if not searchBox then
			searchBox = Instance.new("TextBox")
			searchBox.Name = "SettingsSearch"
			searchBox.Parent = header
			local searchCorner = Instance.new("UICorner")
			searchCorner.CornerRadius = UDim.new(0, 8)
			searchCorner.Parent = searchBox
			local searchPad = Instance.new("UIPadding")
			searchPad.PaddingLeft = UDim.new(0, 8)
			searchPad.Parent = searchBox
		end
		searchBox.AnchorPoint = Vector2.new(1, 0.5)
		searchBox.Size = UDim2.fromOffset(176, 28)
		searchBox.Position = UDim2.new(1, -168, 0.5, 0)
		searchBox.BackgroundColor3 = Color3.fromRGB(24, 27, 34)
		searchBox.BorderSizePixel = 0
		searchBox.PlaceholderText = "Search settings..."
		searchBox.PlaceholderColor3 = Color3.fromRGB(125, 130, 145)
		searchBox.TextColor3 = Color3.fromRGB(255, 255, 255)
		searchBox.Font = Enum.Font.Gotham
		searchBox.TextSize = 13
		searchBox.TextXAlignment = Enum.TextXAlignment.Left
		searchBox.ClearTextOnFocus = false
		if searchBox.Text == "TextBox" then
			searchBox.Text = ""
		end
		if not searchBox:GetAttribute("SettingsSearchBound") then
			searchBox:SetAttribute("SettingsSearchBound", true)
			searchBox:GetPropertyChangedSignal("Text"):Connect(function()
				settingsFilterState.Query = string.lower((string.match(searchBox.Text or "", "^%s*(.-)%s*$") or ""))
				applySettingsFilters(content)
			end)
		end
	end

	local tabBar = settingsFrame:FindFirstChild("SettingsTabBar")
	if not (tabBar and tabBar:IsA("Frame")) then
		if tabBar then
			tabBar:Destroy()
		end
		tabBar = Instance.new("Frame")
		tabBar.Name = "SettingsTabBar"
		tabBar.BackgroundTransparency = 1
		tabBar.Parent = settingsFrame
	end
	for _, child in ipairs(tabBar:GetChildren()) do
		if child:IsA("GuiObject") then
			child:Destroy()
		end
	end

	settingsTabButtons = {}
	local tabs = { "All", "Visual", "Gameplay", "Multiplayer", "System" }
	for index, tabName in ipairs(tabs) do
		local button = Instance.new("TextButton")
		button.Name = tabName
		button.Size = UDim2.new(1 / #tabs, -4, 1, 0)
		button.Position = UDim2.new((index - 1) / #tabs, 2, 0, 0)
		button.BackgroundColor3 = Color3.fromRGB(24, 27, 34)
		button.Text = string.upper(tabName)
		button.TextColor3 = Color3.fromRGB(200, 205, 220)
		button.Font = Enum.Font.GothamBold
		button.TextSize = 11
		button.Parent = tabBar
		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(0, 8)
		corner.Parent = button
		settingsTabButtons[tabName] = button
		bindGuiButton(button, function()
			settingsFilterState.Tab = tabName
			applySettingsFilters(content)
		end)
	end

	-- Clear old script-created rows so rebuilt sections stay in sync when this UI reconnects.
	local studioNames = {Music=true, Shadows=true, Particles=true, Weather=true}
	local rebuiltNames = {
		["SectionHeader_PERFORMANCE"] = true,
		["SectionHeader_GRAPHICS QUALITY"] = true,
		["SectionHeader_GRAPHICS"] = true,
		["Trees"] = true,
		["GuestModels"] = true,
		["Atmosphere"] = true,
		["SunRays"] = true,
		["Bloom"] = true,
		["Decorations"] = true,
		["GuestLOD"] = true,
		["GuestPerformanceMode"] = true,
		["GraphicsPreset"] = true,
		["BuildingRenderDistance"] = true,
		["LiftRenderDistance"] = true,
		["NPCRenderDistance"] = true,
		["WeatherQuality"] = true,
		["ParticleQuality"] = true,
		["ParticleDensity"] = true,
		["RealisticParticles"] = true,
		["AdaptiveParticles"] = true,
		["AdaptiveParticleBudget"] = true,
		["FogEdgeBlend"] = true,
		["FogEdgeIntensity"] = true,
		["SlopeDifficultyOverlay"] = true,
		["UnitSystem"] = true,
		["ShowFPSCounter"] = true,
		["ShowMobileSkiButton"] = true,
		["GuestCapRow"] = true,
		["EnablePotatoMode"] = true,
		["ManualSaveRow"] = true,
		["ReturnToLobbyRow"] = true,
		["SectionHeader_CODES"] = true,
		["RedeemCodeRow"] = true,
		["SectionHeader_GAMEPLAY"] = true,
		["SectionHeader_SYSTEM"] = true,
		["Divider"] = true,
	}
	for _, child in pairs(content:GetChildren()) do
		if rebuiltNames[child.Name] and not studioNames[child.Name] then
			child:Destroy()
		elseif child.Name == "Streaming" or child.Name == "Render" or child.Name == "ShadowQuality" then
			child:Destroy()
		end
	end

	-- Ensure UIListLayout
	local layout = content:FindFirstChildOfClass("UIListLayout")
	if not layout then
		layout = Instance.new("UIListLayout")
		layout.Parent = content
	end
	-- ALWAYS force these properties (existing Studio layout may have wrong sort)
	layout.Padding = UDim.new(0, 6)
	layout.FillDirection = Enum.FillDirection.Vertical
	layout.SortOrder = Enum.SortOrder.LayoutOrder

	-- Ensure UIPadding
	local pad = content:FindFirstChildOfClass("UIPadding")
	if not pad then
		pad = Instance.new("UIPadding")
		pad.PaddingTop = UDim.new(0, 6)
		pad.PaddingLeft = UDim.new(0, 5)
		pad.PaddingRight = UDim.new(0, 5)
		pad.Parent = content
	end

	-- Fix existing Studio toggle rows: assign LayoutOrder + convert to offset sizing
	local studioOrder = {Music = 10, Weather = 11, Shadows = 12, Particles = 13}
	for name, order in pairs(studioOrder) do
		local f = content:FindFirstChild(name)
		if f then
			f.LayoutOrder = order
			-- Convert scale-based height to offset so it matches script-created rows
			if f.Size.Y.Scale > 0 and f.Size.Y.Offset == 0 then
				f.Size = UDim2.new(1, 0, 0, 42)
			end
		end
	end

	-- Bind existing Studio toggles
	local function bindExistingToggle(name, callback)
		local f = content:FindFirstChild(name)
		if not f then return end
		local toggle = f:FindFirstChild("Toggle")
		if not toggle then return end
		-- Update visual to current state
		toggle.Text = SETTINGS[name] and "ON" or "OFF"
		toggle.BackgroundColor3 = SETTINGS[name] and THEME.ToggleOnBg or THEME.ToggleOffBg
		toggle.Activated:Connect(function()
			SETTINGS[name] = not SETTINGS[name]
			toggle.Text = SETTINGS[name] and "ON" or "OFF"
			toggle.BackgroundColor3 = SETTINGS[name] and THEME.ToggleOnBg or THEME.ToggleOffBg
			callback(SETTINGS[name])
		end)
	end

	bindExistingToggle("Music", setMusic)
	bindExistingToggle("Weather", setWeather)
	bindExistingToggle("Shadows", setShadows)
	bindExistingToggle("Particles", function(on)
		setParticles(on)
	end)

	createSectionHeader(content, "GRAPHICS", 14)
	createToggleRow(content, "Trees", "Hide world trees and glades for better FPS", 15, SETTINGS.Trees, setTrees)
	createToggleRow(content, "Guest Models", "Hide guest characters if crowds start lagging", 16, SETTINGS.GuestModels, setGuestModels)
	createToggleRow(content, "Atmosphere", "Turn off fog and sky atmosphere effects", 17, SETTINGS.Atmosphere, setAtmosphere)
	createToggleRow(content, "Sun Rays", "Turn off bright sunlight bloom rays", 18, SETTINGS.SunRays, setSunRays)
	createToggleRow(content, "Bloom", "Turn off extra glow effects", 19, SETTINGS.Bloom, setBloom)
	createToggleRow(content, "Decorations", "Hide extra decor props for cleaner performance", 20, SETTINGS.Decorations, setDecorations)
	createToggleRow(content, "Guest LOD", "Distance-based guest culling. Disable to keep all guests visible.", 21, SETTINGS.GuestLOD, setGuestLOD)
	createChoiceRow(content, "Guest Performance Mode", "Crowd optimization override. Aggressive/Extreme may ignore NPC distance Off.", 22, SETTINGS.GuestPerformanceMode, {"Off", "Balanced", "Aggressive", "Extreme"}, setGuestPerformanceMode)
	createChoiceRow(content, "Graphics Preset", "Global visual quality profile", 23, SETTINGS.GraphicsPreset, {"Low", "Medium", "High", "Ultra"}, setGraphicsPreset)
	createChoiceRow(content, "Building Render Distance", "Near/Medium/Far/Off building draw distance", 24, SETTINGS.BuildingRenderDistance, {"Near", "Medium", "Far", "Off"}, setBuildingRenderDistance)
	createChoiceRow(content, "Lift Render Distance", "Near/Medium/Far/Off lift draw distance", 25, SETTINGS.LiftRenderDistance, {"Near", "Medium", "Far", "Off"}, setLiftRenderDistance)
	createChoiceRow(content, "NPC Render Distance", "Near/Medium/Far/Off guest and employee draw distance", 26, SETTINGS.NPCRenderDistance, {"Near", "Medium", "Far", "Off"}, setNPCRenderDistance)
	createChoiceRow(content, "Weather Quality", "Scales realism and density of weather effects", 27, SETTINGS.WeatherQuality, {"Low", "Medium", "High", "Ultra"}, setWeatherQuality)
	createChoiceRow(content, "Particle Quality", "Scales visual density for non-weather particles", 28, SETTINGS.ParticleQuality, {"Low", "Medium", "High", "Ultra"}, setParticleQuality)
	createChoiceRow(content, "Particle Density", "Controls how many particles are emitted", 29, SETTINGS.ParticleDensity, {"Low", "Medium", "High", "Ultra"}, setParticleDensity)
	createToggleRow(content, "Realistic Particles", "Enable physically-inspired particle behavior", 30, SETTINGS.RealisticParticles, setRealisticParticles)
	createToggleRow(content, "Adaptive Particle Budget", "Auto-reduce particle load if FPS drops", 31, SETTINGS.AdaptiveParticles, setAdaptiveParticles)
	createToggleRow(content, "Fog Edge Blend", "Blend distant culling with atmospheric fog", 32, SETTINGS.FogEdgeBlend, setFogEdgeBlend)
	createChoiceRow(content, "Fog Edge Intensity", "Controls how early distance fog starts", 33, SETTINGS.FogEdgeIntensity, {"Low", "Medium", "High"}, setFogEdgeIntensity)
	createSectionHeader(content, "GAMEPLAY", 34)
	createToggleRow(content, "Slope Difficulty Overlay", "Show or hide run colors on the mountain", 35, SETTINGS.SlopeDifficulty, setSlopeDifficulty)
	createChoiceRow(content, "Unit System", "Switch between imperial and metric units", 36, SETTINGS.UnitSystem, {"Imperial", "Metric"}, setUnitSystem)
	createToggleRow(content, "Show FPS Counter", "Show your frame rate in the corner", 37, SETTINGS.FPSCounter, setFPSCounter)
	local isMobileOnlyLayout = UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled
	if isMobileOnlyLayout then
		createToggleRow(content, "Show Mobile Ski Button", "Hide the on-screen ski button while still keeping stop/recover visible if you are already skiing", 38, SETTINGS.ShowMobileSkiButton, function(on)
			SETTINGS.ShowMobileSkiButton = on
			saveSetting("ShowMobileSkiButton", on)
		end)
	end
	createGuestCapRow(content, isMobileOnlyLayout and 39 or 38)
	createSectionHeader(content, "SYSTEM", isMobileOnlyLayout and 40 or 39)
	createActionButton(content, "Enable Potato Mode", Color3.fromRGB(125, 88, 40), isMobileOnlyLayout and 41 or 40, activatePotatoMode)
	createManualSaveRow(content, isMobileOnlyLayout and 42 or 41)
	createReturnToLobbyRow(content, isMobileOnlyLayout and 43 or 42)
	createSectionHeader(content, "CODES", isMobileOnlyLayout and 44 or 43)
	createRedeemCodeRow(content, isMobileOnlyLayout and 45 or 44)

	local existingTicketRow = content:FindFirstChild("LiftTickets")
	if existingTicketRow then
		existingTicketRow:Destroy()
	end
	local existingPricingHeader = content:FindFirstChild("SectionHeader_💸 RESORT PRICING")
	if existingPricingHeader then
		existingPricingHeader:Destroy()
	end

	-- Performance and visibility controls are rebuilt here so older saved settings
	-- still show up in the current single-panel layout.

	-- ═══════════════════════════════════════
	-- JOIN CODE SECTION (integrated)
	-- ═══════════════════════════════════════

	-- Divider
	local divider = Instance.new("Frame")
	divider.Name = "Divider"
	divider.Size = UDim2.new(0.9, 0, 0, 2)
	divider.BackgroundColor3 = Color3.fromRGB(60, 60, 80)
	divider.BackgroundTransparency = 0.3
	divider.BorderSizePixel = 0
	divider.LayoutOrder = 70
	divider.Parent = content

	if not hydratedPreferencePayload then
		local payload = fetchPreferencePayload()
		if payload then
			hydratedPreferencePayload = payload
			if type(payload.Multiplayer) == "table" then
				hydratedMultiplayer = sanitizeMultiplayerState(payload.Multiplayer)
				MULTIPLAYER = sanitizeMultiplayerState(hydratedMultiplayer)
			end
		end
	end

	createSectionHeader(content, "🔗 MULTIPLAYER", 71)

	-- Your Code row
	local codeRow = Instance.new("Frame")
	codeRow.Name = "JoinCodeDisplay"
	codeRow.Size = UDim2.new(1, 0, 0, 70)
	codeRow.BackgroundColor3 = THEME.RowBg
	codeRow.LayoutOrder = 72
	codeRow.Parent = content
	Instance.new("UICorner", codeRow).CornerRadius = THEME.RowCorner

	local codeTitle = Instance.new("TextLabel")
	codeTitle.Name = "Title"
	codeTitle.Size = UDim2.new(1, 0, 0, 18)
	codeTitle.Position = UDim2.new(0, 0, 0, 4)
	codeTitle.BackgroundTransparency = 1
	codeTitle.Text = "YOUR SERVER CODE"
	codeTitle.TextColor3 = Color3.fromRGB(80, 200, 120)
	codeTitle.Font = Enum.Font.GothamBold
	codeTitle.TextSize = 12
	codeTitle.Parent = codeRow

	local codeDisplay = Instance.new("TextLabel")
	codeDisplay.Name = "CodeDisplay"
	codeDisplay.Size = UDim2.new(0.55, 0, 0, 30)
	codeDisplay.Position = UDim2.new(0.03, 0, 0, 30)
	codeDisplay.BackgroundTransparency = 1
	codeDisplay.Text = "LOADING..."
	codeDisplay.TextColor3 = Color3.fromRGB(255, 255, 255)
	codeDisplay.Font = Enum.Font.GothamBlack
	codeDisplay.TextSize = 28
	codeDisplay.TextXAlignment = Enum.TextXAlignment.Left
	codeDisplay.Parent = codeRow

	local function focusCodeForManualCopy(code)
		local overlay = codeRow:FindFirstChild("ManualCopyInput")
		if overlay and not overlay:IsA("TextBox") then
			overlay:Destroy()
			overlay = nil
		end
		if not overlay then
			overlay = Instance.new("TextBox")
			overlay.Name = "ManualCopyInput"
			overlay.Size = codeDisplay.Size
			overlay.Position = codeDisplay.Position
			overlay.BackgroundTransparency = 1
			overlay.ClearTextOnFocus = false
			overlay.MultiLine = false
			overlay.TextXAlignment = Enum.TextXAlignment.Left
			overlay.TextColor3 = codeDisplay.TextColor3
			overlay.Font = codeDisplay.Font
			overlay.TextSize = codeDisplay.TextSize
			overlay.ZIndex = codeDisplay.ZIndex + 1
			overlay.Parent = codeRow
			overlay.FocusLost:Connect(function()
				if overlay and overlay.Parent then
					overlay.Visible = false
				end
				codeDisplay.Visible = true
			end)
		end
		codeDisplay.Visible = false
		overlay.Visible = true
		overlay.Active = true
		overlay.TextEditable = true
		overlay.Text = code
		task.defer(function()
			if overlay and overlay.Parent then
				overlay:CaptureFocus()
				overlay.CursorPosition = #code + 1
				overlay.SelectionStart = 1
			end
		end)
	end

	local copyBtn = Instance.new("TextButton")
	copyBtn.Name = "CopyBtn"
	copyBtn.Size = UDim2.new(0.3, 0, 0, 28)
	copyBtn.Position = UDim2.new(0.65, 0, 0, 32)
	copyBtn.BackgroundColor3 = Color3.fromRGB(34, 37, 43)
	copyBtn.Text = "COPY PIN"
	copyBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
	copyBtn.Font = Enum.Font.GothamBold
	copyBtn.TextSize = 12
	copyBtn.AutoButtonColor = true
	copyBtn.Parent = codeRow
	Instance.new("UICorner", copyBtn).CornerRadius = UDim.new(0.4, 0)

	-- Wire up code display from JoinCodeSystem's StringValue
	task.spawn(function()
		local evts = ReplicatedStorage:WaitForChild("Events", 10)
		if not evts then return end
		local codeVal = evts:WaitForChild("ServerAccessCode", 10)
		if codeVal then
			local function updateCode()
				local v = codeVal.Value
				if v and v ~= "" and v ~= "ERR" then
					codeDisplay.Text = v
				else
					codeDisplay.Text = "..."
				end
			end
			codeVal.Changed:Connect(updateCode)
			updateCode()
		end
	end)

	-- Copy button
	local lastCopy = 0
	local function doCopy()
		local now = os.clock()
		if (now - lastCopy) < 0.5 then return end
		lastCopy = now
		local code = codeDisplay.Text
		if code == "LOADING..." or code == "..." then return end

		local copiedToClipboard = false
		local clipboardFn = type(getfenv) == "function" and getfenv().setclipboard or nil
		if type(clipboardFn) == "function" then
			copiedToClipboard = pcall(function()
				clipboardFn(code)
			end)
		end
		if not copiedToClipboard then
			focusCodeForManualCopy(code)
		end

		local orig = copyBtn.Text
		local origColor = copyBtn.BackgroundColor3
		copyBtn.Text = copiedToClipboard and "COPIED" or "PIN SELECTED"
		copyBtn.BackgroundColor3 = Color3.fromRGB(76, 164, 90)
		task.delay(1.2, function()
			if copyBtn and copyBtn.Parent then
				copyBtn.Text = orig
				copyBtn.BackgroundColor3 = origColor
			end
		end)
	end
	bindGuiButton(copyBtn, doCopy)

	-- Join friend row
	local joinRow = Instance.new("Frame")
	joinRow.Name = "JoinFriend"
	joinRow.Size = UDim2.new(1, 0, 0, 70)
	joinRow.BackgroundColor3 = THEME.RowBg
	joinRow.LayoutOrder = 73
	joinRow.Parent = content
	Instance.new("UICorner", joinRow).CornerRadius = THEME.RowCorner

	local joinTitle = Instance.new("TextLabel")
	joinTitle.Name = "Title"
	joinTitle.Size = UDim2.new(1, 0, 0, 18)
	joinTitle.Position = UDim2.new(0, 0, 0, 4)
	joinTitle.BackgroundTransparency = 1
	joinTitle.Text = "JOIN A FRIEND"
	joinTitle.TextColor3 = Color3.fromRGB(255, 140, 50)
	joinTitle.Font = Enum.Font.GothamBold
	joinTitle.TextSize = 12
	joinTitle.Parent = joinRow

	local inputBox = Instance.new("TextBox")
	inputBox.Name = "InputBox"
	inputBox.Size = UDim2.new(0.55, 0, 0, 30)
	inputBox.Position = UDim2.new(0.03, 0, 0, 30)
	inputBox.BackgroundColor3 = Color3.fromRGB(34, 37, 43)
	inputBox.Text = ""
	inputBox.PlaceholderText = "Enter code..."
	inputBox.PlaceholderColor3 = Color3.fromRGB(100, 100, 120)
	inputBox.TextColor3 = Color3.fromRGB(255, 255, 255)
	inputBox.Font = Enum.Font.GothamBold
	inputBox.TextSize = 20
	inputBox.ClearTextOnFocus = false
	inputBox.Parent = joinRow
	Instance.new("UICorner", inputBox).CornerRadius = UDim.new(0.3, 0)
	local inputPad = Instance.new("UIPadding")
	inputPad.PaddingLeft = UDim.new(0, 8)
	inputPad.Parent = inputBox

	local joinBtn = Instance.new("TextButton")
	joinBtn.Name = "JoinBtn"
	joinBtn.Size = UDim2.new(0.3, 0, 0, 28)
	joinBtn.Position = UDim2.new(0.65, 0, 0, 32)
	joinBtn.BackgroundColor3 = Color3.fromRGB(255, 140, 50)
	joinBtn.Text = "JOIN >"
	joinBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
	joinBtn.Font = Enum.Font.GothamBold
	joinBtn.TextSize = 13
	joinBtn.AutoButtonColor = true
	joinBtn.Parent = joinRow
	Instance.new("UICorner", joinBtn).CornerRadius = UDim.new(0.4, 0)

	-- Join button logic
	local isJoining = false
	local function doJoin()
		if isJoining then return end
		local pin = string.upper(string.gsub(inputBox.Text, "%s+", ""))
		if #pin < 4 then
			joinBtn.Text = "ENTER CODE"
			joinBtn.BackgroundColor3 = Color3.fromRGB(200, 50, 50)
			task.wait(1)
			joinBtn.Text = "JOIN >"
			joinBtn.BackgroundColor3 = Color3.fromRGB(255, 140, 50)
			return
		end

		isJoining = true
		joinBtn.Text = "SEARCHING..."
		joinBtn.BackgroundColor3 = Color3.fromRGB(25, 30, 40)

		local evts = ReplicatedStorage:FindFirstChild("Events")
		local resolveFunc = evts and evts:FindFirstChild("ResolveJoinPin")
		local response = "NO_REMOTE"

		if resolveFunc then
			local ok, result = pcall(function() return resolveFunc:InvokeServer(pin) end)
			response = ok and result or "CONNECTION_ERR"
		end

		if response == "TELEPORTING" then
			joinBtn.Text = "✈️ TELEPORTING..."
			joinBtn.BackgroundColor3 = Color3.fromRGB(80, 200, 120)
		elseif response == "ALREADY_HERE" then
			joinBtn.Text = "✓ ALREADY HERE"
			joinBtn.BackgroundColor3 = Color3.fromRGB(100, 150, 255)
			task.wait(2)
			isJoining = false
			joinBtn.Text = "JOIN >"
			joinBtn.BackgroundColor3 = Color3.fromRGB(255, 140, 50)
		elseif response == "STUDIO_NO_TP" then
			joinBtn.Text = "STUDIO MODE"
			joinBtn.BackgroundColor3 = Color3.fromRGB(200, 200, 50)
			task.wait(2)
			isJoining = false
			joinBtn.Text = "JOIN >"
			joinBtn.BackgroundColor3 = Color3.fromRGB(255, 140, 50)
		else
			joinBtn.Text = "❌ " .. tostring(response)
			joinBtn.BackgroundColor3 = Color3.fromRGB(200, 50, 50)
			task.wait(2)
			isJoining = false
			joinBtn.Text = "JOIN >"
			joinBtn.BackgroundColor3 = Color3.fromRGB(255, 140, 50)
		end
	end

	bindGuiButton(joinBtn, doJoin)

	createSectionHeader(content, "🛠️ RESORT ACCESS", 74)

	local isResortOwner = Player:GetAttribute("IsOwner") == true
	if isResortOwner then
		local function commitMultiplayerState()
			MULTIPLAYER = sanitizeMultiplayerState(MULTIPLAYER)
			queueMultiplayerPreferenceSave(MULTIPLAYER)
		end

		createToggleRow(content, "Visitors Can Build", "Let anyone in the server place items here", 75, MULTIPLAYER.VisitorBuild, function(on)
			MULTIPLAYER.VisitorBuild = on
			commitMultiplayerState()
		end)
		createToggleRow(content, "Visitors Can Delete", "Let anyone remove placed builds here", 76, MULTIPLAYER.VisitorDelete, function(on)
			MULTIPLAYER.VisitorDelete = on
			commitMultiplayerState()
		end)
		createToggleRow(content, "Trusted Can Build", "Trusted players can place items with you", 77, MULTIPLAYER.TrustedBuild, function(on)
			MULTIPLAYER.TrustedBuild = on
			commitMultiplayerState()
		end)
		createToggleRow(content, "Trusted Can Delete", "Trusted players can remove shared builds", 78, MULTIPLAYER.TrustedDelete, function(on)
			MULTIPLAYER.TrustedDelete = on
			commitMultiplayerState()
		end)
		createToggleRow(content, "Trusted Use Host Research", "Trusted players can place with your unlocks", 79, MULTIPLAYER.TrustedUseOwnerResearch, function(on)
			MULTIPLAYER.TrustedUseOwnerResearch = on
			commitMultiplayerState()
		end)

		local trustRow = Instance.new("Frame")
		trustRow.Name = "TrustedFriendsManager"
		trustRow.Size = UDim2.new(1, 0, 0, 238)
		trustRow.BackgroundColor3 = THEME.RowBg
		trustRow.LayoutOrder = 80
		trustRow.Parent = content
		Instance.new("UICorner", trustRow).CornerRadius = THEME.RowCorner

		local trustTitle = Instance.new("TextLabel")
		trustTitle.Name = "Title"
		trustTitle.Size = UDim2.new(1, -24, 0, 18)
		trustTitle.Position = UDim2.fromOffset(12, 8)
		trustTitle.BackgroundTransparency = 1
		trustTitle.Text = "PLAYER ACCESS"
		trustTitle.TextColor3 = Color3.fromRGB(130, 210, 255)
		trustTitle.Font = Enum.Font.GothamBold
		trustTitle.TextSize = 12
		trustTitle.TextXAlignment = Enum.TextXAlignment.Left
		trustTitle.Parent = trustRow

		local trustSummaryLabel = Instance.new("TextLabel")
		trustSummaryLabel.Name = "Summary"
		trustSummaryLabel.Size = UDim2.new(1, -24, 0, 28)
		trustSummaryLabel.Position = UDim2.fromOffset(12, 28)
		trustSummaryLabel.BackgroundTransparency = 1
		trustSummaryLabel.TextColor3 = THEME.SubLabelColor
		trustSummaryLabel.Font = THEME.SubLabelFont
		trustSummaryLabel.TextSize = THEME.SubLabelSize
		trustSummaryLabel.TextWrapped = true
		trustSummaryLabel.TextXAlignment = Enum.TextXAlignment.Left
		trustSummaryLabel.TextYAlignment = Enum.TextYAlignment.Top
		trustSummaryLabel.Parent = trustRow

		local playerList = Instance.new("ScrollingFrame")
		playerList.Name = "PlayerList"
		playerList.Size = UDim2.new(1, -24, 1, -72)
		playerList.Position = UDim2.fromOffset(12, 60)
		playerList.BackgroundTransparency = 1
		playerList.BorderSizePixel = 0
		playerList.ScrollBarThickness = 6
		playerList.CanvasSize = UDim2.new(0, 0, 0, 0)
		playerList.AutomaticCanvasSize = Enum.AutomaticSize.Y
		playerList.Parent = trustRow

		local playerListLayout = Instance.new("UIListLayout")
		playerListLayout.Padding = UDim.new(0, 8)
		playerListLayout.Parent = playerList

		local function isTrustedUserId(userId)
			for _, trustedUserId in ipairs(MULTIPLAYER.TrustedUserIds) do
				if trustedUserId == userId then
					return true
				end
			end
			return false
		end

		local function setTrustedUserId(userId, shouldTrust)
			local nextTrusted = {}
			for _, trustedUserId in ipairs(MULTIPLAYER.TrustedUserIds) do
				if trustedUserId ~= userId then
					table.insert(nextTrusted, trustedUserId)
				end
			end
			if shouldTrust then
				table.insert(nextTrusted, userId)
			end
			table.sort(nextTrusted)
			MULTIPLAYER.TrustedUserIds = nextTrusted
			commitMultiplayerState()
		end

		local function requestKickPlayer(targetPlayer)
			if not (PreferenceSync and PreferenceSync:IsA("RemoteFunction")) then
				return false
			end
			local ok, result = pcall(function()
				return PreferenceSync:InvokeServer("KickPlayer", { UserId = targetPlayer.UserId })
			end)
			return ok and result == true
		end

		local function refreshTrustUi()
			for _, child in ipairs(playerList:GetChildren()) do
				if not child:IsA("UIListLayout") then
					child:Destroy()
				end
			end

			local roster = {}
			local trustedCount = 0
			for _, otherPlayer in ipairs(Players:GetPlayers()) do
				if otherPlayer ~= Player then
					table.insert(roster, otherPlayer)
					if isTrustedUserId(otherPlayer.UserId) then
						trustedCount += 1
					end
				end
			end
			table.sort(roster, function(a, b)
				return string.lower(a.DisplayName) < string.lower(b.DisplayName)
			end)

			local visitorCount = math.max(0, #roster - trustedCount)
			trustSummaryLabel.Text = string.format("Everyone here is either TRUSTED or VISITOR. Trusted: %d | Visitors: %d | Use the buttons below to change status or kick someone.", trustedCount, visitorCount)

			if #roster == 0 then
				local emptyLabel = Instance.new("TextLabel")
				emptyLabel.Name = "EmptyState"
				emptyLabel.Size = UDim2.new(1, -4, 0, 42)
				emptyLabel.BackgroundColor3 = Color3.fromRGB(24, 27, 34)
				emptyLabel.Text = "No other players are in this server right now."
				emptyLabel.TextColor3 = THEME.SubLabelColor
				emptyLabel.Font = Enum.Font.GothamMedium
				emptyLabel.TextSize = 12
				emptyLabel.Parent = playerList
				Instance.new("UICorner", emptyLabel).CornerRadius = UDim.new(0.3, 0)
				return
			end

			for _, otherPlayer in ipairs(roster) do
				local trusted = isTrustedUserId(otherPlayer.UserId)

				local row = Instance.new("Frame")
				row.Name = "Player_" .. tostring(otherPlayer.UserId)
				row.Size = UDim2.new(1, -4, 0, 52)
				row.BackgroundColor3 = Color3.fromRGB(24, 27, 34)
				row.Parent = playerList
				Instance.new("UICorner", row).CornerRadius = UDim.new(0.3, 0)

				local playerName = Instance.new("TextLabel")
				playerName.Name = "PlayerName"
				playerName.Size = UDim2.new(1, -210, 0, 20)
				playerName.Position = UDim2.fromOffset(10, 7)
				playerName.BackgroundTransparency = 1
				playerName.Text = otherPlayer.DisplayName .. " (@" .. otherPlayer.Name .. ")"
				playerName.TextColor3 = THEME.LabelColor
				playerName.Font = Enum.Font.GothamBold
				playerName.TextSize = 13
				playerName.TextXAlignment = Enum.TextXAlignment.Left
				playerName.Parent = row

				local playerStatus = Instance.new("TextLabel")
				playerStatus.Name = "PlayerStatus"
				playerStatus.Size = UDim2.new(1, -210, 0, 16)
				playerStatus.Position = UDim2.fromOffset(10, 28)
				playerStatus.BackgroundTransparency = 1
				playerStatus.Text = trusted and "Status: TRUSTED" or "Status: VISITOR"
				playerStatus.TextColor3 = trusted and Color3.fromRGB(130, 210, 255) or THEME.SubLabelColor
				playerStatus.Font = Enum.Font.Gotham
				playerStatus.TextSize = 11
				playerStatus.TextXAlignment = Enum.TextXAlignment.Left
				playerStatus.Parent = row

				local statusBtn = Instance.new("TextButton")
				statusBtn.Name = "StatusButton"
				statusBtn.Size = UDim2.fromOffset(96, 28)
				statusBtn.Position = UDim2.new(1, -196, 0, 12)
				statusBtn.BackgroundColor3 = trusted and Color3.fromRGB(170, 70, 70) or Color3.fromRGB(0, 120, 215)
				statusBtn.Text = trusted and "SET VISITOR" or "SET TRUSTED"
				statusBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
				statusBtn.Font = Enum.Font.GothamBold
				statusBtn.TextSize = 11
				statusBtn.Parent = row
				Instance.new("UICorner", statusBtn).CornerRadius = UDim.new(0.35, 0)

				local kickBtn = Instance.new("TextButton")
				kickBtn.Name = "KickButton"
				kickBtn.Size = UDim2.fromOffset(82, 28)
				kickBtn.Position = UDim2.new(1, -92, 0, 12)
				kickBtn.BackgroundColor3 = Color3.fromRGB(125, 55, 55)
				kickBtn.Text = "KICK"
				kickBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
				kickBtn.Font = Enum.Font.GothamBold
				kickBtn.TextSize = 11
				kickBtn.Parent = row
				Instance.new("UICorner", kickBtn).CornerRadius = UDim.new(0.35, 0)

				bindGuiButton(statusBtn, function()
					setTrustedUserId(otherPlayer.UserId, not trusted)
					refreshTrustUi()
				end)

				bindGuiButton(kickBtn, function()
					kickBtn.Text = "KICKING"
					kickBtn.BackgroundColor3 = Color3.fromRGB(90, 90, 100)
					local kicked = requestKickPlayer(otherPlayer)
					if kicked then
						kickBtn.Text = "KICKED"
						kickBtn.BackgroundColor3 = Color3.fromRGB(70, 130, 90)
						task.delay(0.4, refreshTrustUi)
					else
						kickBtn.Text = "FAILED"
						kickBtn.BackgroundColor3 = Color3.fromRGB(170, 70, 70)
						task.delay(1, refreshTrustUi)
					end
				end)
			end
		end

		Players.PlayerAdded:Connect(function()
			refreshTrustUi()
		end)
		Players.PlayerRemoving:Connect(function()
			refreshTrustUi()
		end)
		refreshTrustUi()

		-- ── FRIEND WHITELIST SECTION (private servers only) ─────────
		local isPrivateServer = game.PrivateServerId ~= "" and game.PrivateServerOwnerId > 0
		if isPrivateServer then
		createSectionHeader(content, "👥 FRIEND WHITELIST", 81)

		local fwRow = Instance.new("Frame")
		fwRow.Name = "FriendWhitelistManager"
		fwRow.Size = UDim2.new(1, 0, 0, 260)
		fwRow.BackgroundColor3 = THEME.RowBg
		fwRow.LayoutOrder = 82
		fwRow.Parent = content
		Instance.new("UICorner", fwRow).CornerRadius = THEME.RowCorner

		local fwTitle = Instance.new("TextLabel")
		fwTitle.Name = "Title"
		fwTitle.Size = UDim2.new(1, -24, 0, 18)
		fwTitle.Position = UDim2.fromOffset(12, 8)
		fwTitle.BackgroundTransparency = 1
		fwTitle.Text = "MANAGE FRIENDS"
		fwTitle.TextColor3 = Color3.fromRGB(130, 210, 255)
		fwTitle.Font = Enum.Font.GothamBold
		fwTitle.TextSize = 12
		fwTitle.TextXAlignment = Enum.TextXAlignment.Left
		fwTitle.Parent = fwRow

		local fwSlotsLabel = Instance.new("TextLabel")
		fwSlotsLabel.Name = "SlotsLabel"
		fwSlotsLabel.Size = UDim2.new(1, -24, 0, 16)
		fwSlotsLabel.Position = UDim2.fromOffset(12, 28)
		fwSlotsLabel.BackgroundTransparency = 1
		fwSlotsLabel.Text = "Loading..."
		fwSlotsLabel.TextColor3 = THEME.SubLabelColor
		fwSlotsLabel.Font = THEME.SubLabelFont
		fwSlotsLabel.TextSize = THEME.SubLabelSize
		fwSlotsLabel.TextXAlignment = Enum.TextXAlignment.Left
		fwSlotsLabel.Parent = fwRow

		-- Add friend input row
		local fwAddRow = Instance.new("Frame")
		fwAddRow.Name = "AddRow"
		fwAddRow.Size = UDim2.new(1, -24, 0, 34)
		fwAddRow.Position = UDim2.fromOffset(12, 48)
		fwAddRow.BackgroundTransparency = 1
		fwAddRow.Parent = fwRow

		local fwInput = Instance.new("TextBox")
		fwInput.Name = "UsernameInput"
		fwInput.PlaceholderText = "Enter username..."
		fwInput.Text = ""
		fwInput.Size = UDim2.new(1, -96, 1, 0)
		fwInput.BackgroundColor3 = Color3.fromRGB(24, 27, 38)
		fwInput.BorderSizePixel = 0
		fwInput.TextColor3 = THEME.LabelColor
		fwInput.PlaceholderColor3 = THEME.SubLabelColor
		fwInput.TextSize = 13
		fwInput.Font = Enum.Font.Gotham
		fwInput.ClearTextOnFocus = false
		fwInput.Parent = fwAddRow
		Instance.new("UICorner", fwInput).CornerRadius = UDim.new(0, 6)
		local fwInputPad = Instance.new("UIPadding")
		fwInputPad.PaddingLeft = UDim.new(0, 8)
		fwInputPad.PaddingRight = UDim.new(0, 8)
		fwInputPad.Parent = fwInput

		local fwAddBtn = Instance.new("TextButton")
		fwAddBtn.Name = "AddBtn"
		fwAddBtn.Text = "ADD"
		fwAddBtn.Size = UDim2.new(0, 80, 1, 0)
		fwAddBtn.Position = UDim2.new(1, -80, 0, 0)
		fwAddBtn.BackgroundColor3 = Color3.fromRGB(60, 190, 80)
		fwAddBtn.BorderSizePixel = 0
		fwAddBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
		fwAddBtn.TextSize = 13
		fwAddBtn.Font = Enum.Font.GothamBold
		fwAddBtn.Parent = fwAddRow
		Instance.new("UICorner", fwAddBtn).CornerRadius = UDim.new(0, 6)

		-- Friend list
		local fwList = Instance.new("ScrollingFrame")
		fwList.Name = "FriendList"
		fwList.Size = UDim2.new(1, -24, 0, 120)
		fwList.Position = UDim2.fromOffset(12, 88)
		fwList.BackgroundColor3 = Color3.fromRGB(24, 27, 34)
		fwList.BorderSizePixel = 0
		fwList.ScrollBarThickness = 4
		fwList.CanvasSize = UDim2.new(0, 0, 0, 0)
		fwList.AutomaticCanvasSize = Enum.AutomaticSize.Y
		fwList.Parent = fwRow
		Instance.new("UICorner", fwList).CornerRadius = UDim.new(0, 6)
		local fwListLayout = Instance.new("UIListLayout")
		fwListLayout.Padding = UDim.new(0, 4)
		fwListLayout.SortOrder = Enum.SortOrder.LayoutOrder
		fwListLayout.Parent = fwList
		local fwListPad = Instance.new("UIPadding")
		fwListPad.PaddingLeft = UDim.new(0, 4)
		fwListPad.PaddingRight = UDim.new(0, 4)
		fwListPad.PaddingTop = UDim.new(0, 4)
		fwListPad.PaddingBottom = UDim.new(0, 4)
		fwListPad.Parent = fwList

		local fwEmptyLabel = Instance.new("TextLabel")
		fwEmptyLabel.Name = "EmptyLabel"
		fwEmptyLabel.Text = "No friends whitelisted yet."
		fwEmptyLabel.Size = UDim2.fromScale(1, 1)
		fwEmptyLabel.BackgroundTransparency = 1
		fwEmptyLabel.TextColor3 = THEME.SubLabelColor
		fwEmptyLabel.TextSize = 12
		fwEmptyLabel.Font = Enum.Font.Gotham
		fwEmptyLabel.Parent = fwList

		-- Buy button
		local fwBuyBtn = Instance.new("TextButton")
		fwBuyBtn.Name = "BuyBtn"
		fwBuyBtn.Text = "＋ Buy More Friend Slots"
		fwBuyBtn.Size = UDim2.new(1, -24, 0, 34)
		fwBuyBtn.Position = UDim2.fromOffset(12, 216)
		fwBuyBtn.BackgroundColor3 = Color3.fromRGB(200, 155, 20)
		fwBuyBtn.BorderSizePixel = 0
		fwBuyBtn.TextColor3 = Color3.fromRGB(30, 20, 0)
		fwBuyBtn.TextSize = 13
		fwBuyBtn.Font = Enum.Font.GothamBold
		fwBuyBtn.Parent = fwRow
		Instance.new("UICorner", fwBuyBtn).CornerRadius = UDim.new(0, 8)

		-- State
		local fwFriends: {number} = {}
		local fwTotalSlots = 0

		local function fwClearList()
			for _, child in ipairs(fwList:GetChildren()) do
				if child:IsA("Frame") and child.Name:match("^FriendEntry_") then
					child:Destroy()
				end
			end
		end

		local function fwBuildEntry(userId: number, index: number)
			local entry = Instance.new("Frame")
			entry.Name = "FriendEntry_" .. userId
			entry.Size = UDim2.new(1, -4, 0, 36)
			entry.BackgroundColor3 = Color3.fromRGB(30, 34, 50)
			entry.BorderSizePixel = 0
			entry.LayoutOrder = index
			entry.Parent = fwList
			Instance.new("UICorner", entry).CornerRadius = UDim.new(0, 6)

			local nameLabel = Instance.new("TextLabel")
			nameLabel.Name = "Name"
			nameLabel.Text = "UserId: " .. userId
			nameLabel.Size = UDim2.new(1, -80, 1, 0)
			nameLabel.BackgroundTransparency = 1
			nameLabel.TextColor3 = Color3.fromRGB(220, 220, 240)
			nameLabel.TextSize = 12
			nameLabel.Font = Enum.Font.Gotham
			nameLabel.TextXAlignment = Enum.TextXAlignment.Left
			nameLabel.Parent = entry
			local namePad = Instance.new("UIPadding")
			namePad.PaddingLeft = UDim.new(0, 8)
			namePad.Parent = nameLabel

			task.spawn(function()
				local ok, name = pcall(function()
					return Players:GetNameFromUserIdAsync(userId)
				end)
				if ok and name and nameLabel and nameLabel.Parent then
					nameLabel.Text = "@" .. name
				end
			end)

			local removeBtn = Instance.new("TextButton")
			removeBtn.Name = "Remove"
			removeBtn.Text = "Remove"
			removeBtn.Size = UDim2.new(0, 64, 0, 24)
			removeBtn.Position = UDim2.new(1, -70, 0.5, -12)
			removeBtn.BackgroundColor3 = Color3.fromRGB(200, 60, 60)
			removeBtn.BorderSizePixel = 0
			removeBtn.TextColor3 = Color3.new(1, 1, 1)
			removeBtn.TextSize = 11
			removeBtn.Font = Enum.Font.GothamBold
			removeBtn.Parent = entry
			Instance.new("UICorner", removeBtn).CornerRadius = UDim.new(0, 6)

			bindGuiButton(removeBtn, function()
				if UpdateFriendWhitelist then
					UpdateFriendWhitelist:FireServer("remove", userId)
				end
				entry:Destroy()
				task.delay(0.5, function()
					if RequestFriendWhitelist then
						RequestFriendWhitelist:FireServer()
					end
				end)
			end)
		end

		local function fwApplyData(data)
			if type(data) ~= "table" then return end
			fwTotalSlots = tonumber(data.slots) or 0
			fwFriends = {}
			for _, uid in ipairs(data.friends or {}) do
				table.insert(fwFriends, uid)
			end
			fwSlotsLabel.Text = string.format("%d / %d friend slots used", #fwFriends, fwTotalSlots)
			fwClearList()
			fwEmptyLabel.Visible = #fwFriends == 0
			for i, uid in ipairs(fwFriends) do
				fwBuildEntry(uid, i)
			end
		end

		-- Listen for server push updates (whitelist data or purchase updates)
		if SlotPurchaseUpdate then
			SlotPurchaseUpdate.OnClientEvent:Connect(function(data)
				if type(data) == "table" then
					if data.friends then
						fwApplyData(data)
					else
						-- Purchase update without friend list — re-request
						task.spawn(function()
							if RequestFriendWhitelist then
								RequestFriendWhitelist:FireServer()
							end
						end)
					end
				end
			end)
		end
		-- Request initial data
		task.spawn(function()
			task.wait(1)
			if RequestFriendWhitelist then
				RequestFriendWhitelist:FireServer()
			end
		end)

		-- Add friend
		bindGuiButton(fwAddBtn, function()
			local raw = string.match(fwInput.Text, "^%s*(.-)%s*$")
			if not raw or raw == "" then return end
			fwAddBtn.Text = "..."
			fwAddBtn.BackgroundColor3 = Color3.fromRGB(40, 45, 55)

			task.spawn(function()
				local uid = tonumber(raw)
				if uid then
					if UpdateFriendWhitelist then
						UpdateFriendWhitelist:FireServer("add", uid)
					end
				else
					local ok, resolved = pcall(function()
						return Players:GetUserIdFromNameAsync(raw)
					end)
					if ok and resolved then
						if UpdateFriendWhitelist then
							UpdateFriendWhitelist:FireServer("add", resolved)
						end
					else
						fwAddBtn.Text = "NOT FOUND"
						fwAddBtn.BackgroundColor3 = Color3.fromRGB(200, 50, 50)
						task.wait(1.5)
						fwAddBtn.Text = "ADD"
						fwAddBtn.BackgroundColor3 = Color3.fromRGB(60, 190, 80)
						return
					end
				end
				fwInput.Text = ""
				fwAddBtn.Text = "ADD"
				fwAddBtn.BackgroundColor3 = Color3.fromRGB(60, 190, 80)
				task.delay(0.8, function()
					if RequestFriendWhitelist then
						RequestFriendWhitelist:FireServer()
					end
				end)
			end)
		end)

		-- Buy more friend slots
		bindGuiButton(fwBuyBtn, function()
			MarketplaceService:PromptProductPurchase(Player, ADD_FRIEND_SLOT_PRODUCT_ID)
		end)

		end -- if isPrivateServer

	else
		local accessInfo = Instance.new("Frame")
		accessInfo.Name = "MultiplayerAccessInfo"
		accessInfo.Size = UDim2.new(1, 0, 0, 58)
		accessInfo.BackgroundColor3 = THEME.RowBg
		accessInfo.LayoutOrder = 75
		accessInfo.Parent = content
		Instance.new("UICorner", accessInfo).CornerRadius = THEME.RowCorner

		local infoTitle = Instance.new("TextLabel")
		infoTitle.Size = UDim2.new(1, -24, 0, 18)
		infoTitle.Position = UDim2.fromOffset(12, 8)
		infoTitle.BackgroundTransparency = 1
		infoTitle.Text = "OWNER MANAGED"
		infoTitle.TextColor3 = Color3.fromRGB(130, 210, 255)
		infoTitle.Font = Enum.Font.GothamBold
		infoTitle.TextSize = 12
		infoTitle.TextXAlignment = Enum.TextXAlignment.Left
		infoTitle.Parent = accessInfo

		local infoBody = Instance.new("TextLabel")
		infoBody.Size = UDim2.new(1, -24, 0, 24)
		infoBody.Position = UDim2.fromOffset(12, 26)
		infoBody.BackgroundTransparency = 1
		infoBody.Text = "Only the resort owner can change trusted friend and visitor permissions."
		infoBody.TextColor3 = THEME.SubLabelColor
		infoBody.Font = THEME.SubLabelFont
		infoBody.TextSize = THEME.SubLabelSize
		infoBody.TextWrapped = true
		infoBody.TextXAlignment = Enum.TextXAlignment.Left
		infoBody.Parent = accessInfo
	end

	applySettingsFilters(content)

	-- Update canvas size
	task.defer(function()
		task.wait(0.05)
		refreshSettingsCanvas(content)
		if layout then
			layout:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(function()
				refreshSettingsCanvas(content)
			end)
		end
		local existingPadding = content:FindFirstChildOfClass("UIPadding")
		if existingPadding then
			existingPadding:GetPropertyChangedSignal("PaddingTop"):Connect(function()
				refreshSettingsCanvas(content)
			end)
			existingPadding:GetPropertyChangedSignal("PaddingBottom"):Connect(function()
				refreshSettingsCanvas(content)
			end)
		end
	end)
end

--------------------------------------------------------------------------------
-- START
--------------------------------------------------------------------------------
task.spawn(ConnectUI)

UserInputService.InputBegan:Connect(function(input, gameProcessed)
	if gameProcessed then return end
	if input.KeyCode ~= Enum.KeyCode.Escape then return end
	if UserInputService:GetFocusedTextBox() then return end
	if _settingsFrame and isSettingsOpen then
		closeSettings(_settingsFrame)
	end
end)

-- Apply saved non-default settings after world loads
task.delay(3, function()
	if not SETTINGS.Music then setMusic(false) end
	if not SETTINGS.Shadows then setShadows(false) end
	if not SETTINGS.Weather then setWeather(false) end
	if not SETTINGS.Particles then setParticles(false) end
	if not SETTINGS.Trees then setTrees(false) end
	if not SETTINGS.GuestModels then setGuestModels(false) end
	if not SETTINGS.Atmosphere then setAtmosphere(false) end
	if not SETTINGS.SunRays then setSunRays(false) end
	if not SETTINGS.Bloom then setBloom(false) end
	if not SETTINGS.Decorations then setDecorations(false) end
	setSlopeDifficulty(SETTINGS.SlopeDifficulty)
	if SETTINGS.FPSCounter then setFPSCounter(true) end
	
end)
