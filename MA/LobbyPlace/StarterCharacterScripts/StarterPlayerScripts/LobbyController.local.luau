--[[
Script: LobbyController
V3.9: Fixed mobile delete button GuiState + ghost play trigger.
      Removed ensureTouchHitTarget for delFrame — delBtn handles touch natively.
      bindGuiButton now only uses Activated (no double-fire on mobile).
      buildAdvancedToggle initial text corrected to "Show advanced".
      Rename icon now guards against Loading state.
      Delete now uses invokeSlotRequestWithRetry for consistency.
      Play/teleport wrapped in pcall.
      refreshCreationLayout double-deferred for accurate first-open sizing.
]]

-- LobbyController V3.9
-- StarterPlayerScripts

local Players              = game:GetService("Players")
local ReplicatedStorage    = game:GetService("ReplicatedStorage")
local TweenService         = game:GetService("TweenService")
local MarketplaceService   = game:GetService("MarketplaceService")
local RunService           = game:GetService("RunService")
local UserInputService     = game:GetService("UserInputService")
local EntitlementManager   = require(ReplicatedStorage:WaitForChild("EntitlementManager"))

-- // CONFIGURATION //
local SLOT_UNLOCK_PASS_ID      = 1792834210
local LEGACY_EXTRA_SLOTS_PASS_ID = 1724355823
local SANDBOX_GAMEPASS_ID     = 1733258476
local DONATE_PRODUCT_ID       = 3521261263

local RENAME_ICON_IDLE    = "rbxassetid://106688936262608"
local RENAME_ICON_EDITING = "rbxassetid://92828243"

-- // CREATION UI ANIMATION //
local CREATION_TWEEN_IN  = TweenInfo.new(0.45, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)
local CREATION_TWEEN_OUT = TweenInfo.new(0.25, Enum.EasingStyle.Quint, Enum.EasingDirection.In)
local CREATION_POS_OPEN  = UDim2.new(0.5, 0, 0.5, 0)
local CREATION_POS_CLOSE = UDim2.new(0.5, 0, 0.65, 0)

-- // ADVANCED SETTINGS TOGGLE //
local ADVANCED_NODE_NAMES = {
	"TreeDensity",
	"DenseTrees",
	"ElevationFalloff",
	"MapScale",
	"MapScaleMode",
}
local advancedExpanded = false

-- // WAIT FOR REMOTES //
local SlotRequest           = ReplicatedStorage:WaitForChild("SlotRequest", 10)
local TeleportToSlot        = ReplicatedStorage:WaitForChild("TeleportToSlot", 10)
local SlotUpdate            = ReplicatedStorage:WaitForChild("SlotUpdate", 10)
local TeleportStatus        = ReplicatedStorage:WaitForChild("TeleportStatus", 10)
local LobbyNoticePreference = ReplicatedStorage:FindFirstChild("LobbyNoticePreference") or ReplicatedStorage:WaitForChild("LobbyNoticePreference", 10)
local Events                = ReplicatedStorage:FindFirstChild("Events") or ReplicatedStorage:WaitForChild("Events", 10)
local ResolveJoinPin        = Events and (Events:FindFirstChild("ResolveJoinPin") or Events:WaitForChild("ResolveJoinPin", 10))
local FunnellingRemote      = ReplicatedStorage:WaitForChild("FunnellingRemote", 10)
local ClientAnalyticsEvent  = ReplicatedStorage:FindFirstChild("ClientAnalyticsEvent") or ReplicatedStorage:WaitForChild("ClientAnalyticsEvent", 10)
local OpenDonationUI        = ReplicatedStorage:WaitForChild("OpenDonationUI", 10)

-- // FUNNEL HELPER //
local function logStep(stepName)
	if not FunnellingRemote then
		warn("[LobbyUI] FunnellingRemote not found — cannot log step: " .. tostring(stepName))
		return
	end
	local ok, err = pcall(function()
		FunnellingRemote:FireServer(stepName)
	end)
	if not ok then
		warn("[LobbyUI] Failed to fire funnel step '" .. tostring(stepName) .. "': " .. tostring(err))
	end

	if ClientAnalyticsEvent then
		pcall(function()
			ClientAnalyticsEvent:FireServer("lobby_" .. string.lower(tostring(stepName)))
		end)
	end
end

local function logCustomEvent(eventName)
	if not ClientAnalyticsEvent then
		return
	end
	pcall(function()
		ClientAnalyticsEvent:FireServer("action_" .. string.lower(string.gsub(tostring(eventName or "unknown"), "[^%w]+", "_")))
	end)
end

local player    = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui", 30)
local gui       = playerGui and playerGui:WaitForChild("SlotSelectionGui", 20)

local function deepFind(root, name)
	if not root then return nil end
	return root:FindFirstChild(name, true)
end

local function ensureSlotSandboxTag(card)
	if not card then return nil end
	local existing = card:FindFirstChild("SandboxTag")
	if existing then return existing end
	local storage = playerGui and playerGui:FindFirstChild("Storage")
	local template = storage and storage:FindFirstChild("TagSandbox")
	if not template then return nil end
	local clone = template:Clone()
	clone.Name = "SandboxTag"
	clone.Visible = false
	clone.Parent = card
	clone.Active = false
	clone.Interactable = false
	local textButton = clone:FindFirstChild("Text")
	if textButton and textButton:IsA("GuiButton") then
		textButton.Active = false
		textButton.AutoButtonColor = false
	end
	return clone
end

local background = deepFind(gui, "Background")
local slotsFrame = deepFind(gui, "SlotsFrame")
local creationUI = deepFind(gui, "CreationUI")
local loadingUI  = deepFind(gui, "TeleportScreen")

local COLORS = {
	Empty       = Color3.fromRGB(16, 18, 22),
	Hover       = Color3.fromRGB(21, 24, 29),
	Danger      = Color3.fromRGB(255, 21, 83),
	Locked      = Color3.fromRGB(10, 12, 15),
	ToggleOn    = Color3.fromRGB(80, 220, 140),
	ToggleOff   = Color3.fromRGB(255, 21, 83),
	CycleBtn    = Color3.fromRGB(16, 18, 22),
	CycleActive = Color3.fromRGB(16, 18, 22),
	Tester      = Color3.fromRGB(255, 120, 0),
	BtnNo       = Color3.fromRGB(255, 21, 83),
	BtnYes      = Color3.fromRGB(80, 220, 140),
	BtnOther    = Color3.fromRGB(8, 9, 11),
	Advanced    = Color3.fromRGB(22, 25, 30),
}

local isRefreshing             = false
local hasLoadedSlotsOnce       = false
local hasQueuedRecoveryRefresh = false
local ownsExtraSlots           = false
local ownsSandboxPass          = false
local activeSlotForCreation    = nil
local serviceNoticeShown       = false
local createRequestInProgress  = false
local hideServiceNoticeForever = false
local SLOT_REQUEST_RETRY_ATTEMPTS      = 4
local SLOT_REQUEST_RETRY_DELAY_SECONDS = 0.75
local SLOT_LOADING_TITLE = "Loading Slots..."
local SLOT_LOADING_BODY  = "Please wait while your resorts are loaded."

local function hasEntitlement(passId)
	local ok, hasAccess = pcall(function()
		return EntitlementManager.HasAccess(player.UserId, passId)
	end)
	if ok then return hasAccess == true end
	warn("[LobbyUI] EntitlementManager check failed for pass " .. tostring(passId))
	return false
end

local function hasSlotUnlockAccess()
	local ok, hasAccess = pcall(function()
		if EntitlementManager.HasAccessOrSub(player.UserId, SLOT_UNLOCK_PASS_ID) then
			return true
		end
		if EntitlementManager.HasAccessOrSub(player.UserId, LEGACY_EXTRA_SLOTS_PASS_ID) then
			return true
		end
		return EntitlementManager.HasSubscription(player.UserId, "UnlimitedSlots")
			or EntitlementManager.HasSubscription(player.UserId, "ResortPass")
	end)
	if ok then
		return hasAccess == true
	end
	return false
end

local DENSITY_OPTIONS = {"Off", "Low", "Medium", "High", "Insane", "Extreme"}
local DENSITY_VALUES  = {"None", "Low", "Medium", "High", "Insane", "Extreme"}
local densityIndex    = 4

local elevationFalloffEnabled = true
local sandboxModeEnabled      = false
local mapScaleValue           = 1
local MAP_SCALE_MODE_OPTIONS  = {
	{ Value = "HeightOnly", Label = "Height only" },
	{ Value = "SizeOnly",   Label = "Size only" },
	{ Value = "Both",       Label = "Both" },
}
local mapScaleModeIndex = 1
local MAP_SCALE_MIN = 0.75
local MAP_SCALE_MAX = 2.5

local SERVICE_NOTICE = {
	Eyebrow    = "UPDATE",
	Title      = "$1,000,000 COMPENSATION",
	Message    = table.concat({
		"$1,000,000 has been added to existing affected saves as compensation for players who lost money.",
		"New saves are not eligible. If you lost much more than this on an older save, let me know and I can review it.",
		"",
		"Join our Discord (link on game page) for updates, report any issues, and/or make a ticket about save issues!",
		"",
		"Thanks for your patience!"
	}, "\n"),
	ButtonText = "GOT IT",
	LogoImage  = "rbxassetid://1461403878",
	LogoLabel  = "UPDATES",
}

local FALLBACK_WORLD_PRESETS = {
	{ Name = "Whistler Peak",     Latitude = 50.1163,  Longitude = -122.9574 },
	{ Name = "Blackcomb Ridge",   Latitude = 50.1214,  Longitude = -122.9486 },
	{ Name = "Aspen Summit",      Latitude = 39.1911,  Longitude = -106.8175 },
	{ Name = "Vail Ridge",        Latitude = 39.6403,  Longitude = -106.3742 },
	{ Name = "Jackson Basin",     Latitude = 43.5887,  Longitude = -110.8274 },
	{ Name = "Park City Peaks",   Latitude = 40.6514,  Longitude = -111.5078 },
	{ Name = "Deer Valley Heights", Latitude = 40.6191, Longitude = -111.4780 },
	{ Name = "Alta Point",        Latitude = 40.5886,  Longitude = -111.6377 },
	{ Name = "Snowbird Cirque",   Latitude = 40.5808,  Longitude = -111.6555 },
	{ Name = "Big Sky Divide",    Latitude = 45.2847,  Longitude = -111.4018 },
	{ Name = "Sun Valley Crest",  Latitude = 43.6786,  Longitude = -114.3517 },
	{ Name = "Mammoth Crest",     Latitude = 37.6308,  Longitude = -119.0326 },
	{ Name = "Tahoe Palisade",    Latitude = 39.1962,  Longitude = -120.2357 },
	{ Name = "Zermatt Glacier",   Latitude = 45.9763,  Longitude = 7.6586    },
	{ Name = "Verbier Heights",   Latitude = 46.0965,  Longitude = 7.2286    },
	{ Name = "St Moritz Run",     Latitude = 46.4908,  Longitude = 9.8355    },
	{ Name = "Chamonix Face",     Latitude = 45.9237,  Longitude = 6.8694    },
	{ Name = "Val d'Isere",       Latitude = 45.4474,  Longitude = 6.9802    },
	{ Name = "Courchevel Ridge",  Latitude = 45.4142,  Longitude = 6.6348    },
	{ Name = "Kitzbuhel Alps",    Latitude = 47.4436,  Longitude = 12.3920   },
	{ Name = "St Anton Pass",     Latitude = 47.1286,  Longitude = 10.2639   },
	{ Name = "Niseko Powder",     Latitude = 42.8644,  Longitude = 140.6994  },
	{ Name = "Hakuba Valley",     Latitude = 36.6982,  Longitude = 137.8619  },
	{ Name = "Furano Snowfield",  Latitude = 43.3425,  Longitude = 142.3830  },
	{ Name = "Gulmarg Bowl",      Latitude = 34.0484,  Longitude = 74.3851   },
	{ Name = "Gudauri Ridge",     Latitude = 42.4698,  Longitude = 44.4921   },
	{ Name = "Catedral Andes",    Latitude = -41.1683, Longitude = -71.4394  },
	{ Name = "Valle Nevado",      Latitude = -33.3505, Longitude = -70.2533  },
	{ Name = "Portillo Spine",    Latitude = -32.8356, Longitude = -70.1292  },
	{ Name = "Treble Cone",       Latitude = -44.6935, Longitude = 169.3952  },
}

local function trimOptionalText(rawValue)
	if type(rawValue) ~= "string" then return nil end
	local trimmed = rawValue:match("^%s*(.-)%s*$")
	if trimmed == "" then return nil end
	return trimmed
end

local function getFallbackWorldPreset(slotNum)
	local numericSlot = tonumber(slotNum) or 0
	local seed = math.abs((player.UserId * 131) + (numericSlot * 977) + math.floor(os.clock() * 1000))
	local rng = Random.new(seed)
	return FALLBACK_WORLD_PRESETS[rng:NextInteger(1, #FALLBACK_WORLD_PRESETS)]
end

local function resolveCreationDefaults(slotNum, rawName, latitude, longitude)
	local preset = nil
	local resolvedLat  = latitude
	local resolvedLong = longitude
	if resolvedLat == nil or resolvedLong == nil then
		preset = getFallbackWorldPreset(slotNum)
		resolvedLat  = preset.Latitude
		resolvedLong = preset.Longitude
	end
	local resolvedName = trimOptionalText(rawName)
	if not resolvedName then
		resolvedName = preset and preset.Name or "New Resort"
	end
	return resolvedName, resolvedLat, resolvedLong, preset
end

local TOOLTIPS = {
	TreeDensity    = { "Tree Density",      "How many trees cover your mountain.\n<b>Off</b> = no trees at all.\n<b>Low/Medium</b> = light to moderate forest.\n<b>High</b> = dense coverage across the map.\n<b>Insane</b> = very heavy forest density.\n<b>Extreme</b> = the maximum supported density." },
	ElevFalloff    = { "Elevation Falloff", "Whether trees thin out near the summit.\n<b>ON</b> = trees sparse at higher elevations.\n<b>OFF</b> = forests grow to the very peak.\nON gives a more realistic mountain look.\nOFF creates a heavily forested summit.\nRecommended: ON for most builds." },
	SnowTrees      = { "Snow Trees",        "Toggles snow-covered tree variants.\n<b>ON</b> = snow trees near the upper mountain.\n<b>OFF</b> = same tree style used everywhere.\nBest combined with Elevation Falloff ON.\nNo effect if Tree Density is set to Off.\nPurely a visual preference." },
	HeightScale    = { "Height Scale",      "Multiplies the height of your mountain.\n<b>Default</b> = standard elevation, no change.\n<b>High</b> = noticeably taller peaks.\n<b>Extreme</b> = dramatically steep terrain.\nAffects guest travel time to the top.\nHigher = longer world generation time." },
	MapSize        = { "Map Size",          "Controls the total playable area.\n<b>Default</b> = 8192 studs wide.\n<b>Large</b> = 12288 studs wide.\n<b>Massive</b> = 16384 studs (4× default).\nLarger maps take longer to generate.\nMore space for runs, lifts, and buildings." },
	NoiseIntensity = { "Noise Intensity",   "Controls terrain surface bumpiness.\n<b>Flat</b> = very smooth, clean slopes.\n<b>Low/Medium</b> = subtle natural variation.\n<b>High</b> = noticeable bumps and ridges.\n<b>Insane</b> = very jagged, rocky terrain.\nAffects overall slope smoothness." },
	RiverMode      = { "River Mode",        "Carves a river valley through the map.\nCreates a low corridor in the terrain.\nGreat for scenic routes and variety.\nThe path is procedurally generated.\nMay reduce skiable area on small maps.\nWorks best with larger map sizes." },
	RealisticTrees = { "Realistic Trees",   "Switches between two tree asset styles.\n<b>ON</b> = detailed RTree realistic assets.\n<b>OFF</b> = standard stylized trees.\nRealistic trees are heavier to render.\nRecommended OFF for large maps.\nOFF is better for lower-end devices." },
	LatLong        = { "Lat / Long",        "Base your mountain on real elevation data.\nUse coordinates from Google Maps.\n<b>N/S</b> for latitude, <b>E/W</b> for longitude.\nNegative longitude = western coordinates.\nLeave blank for a procedural mountain.\nData sourced via Google Maps API." },
	MapScale       = { "Map Scale",         "Strength of the selected scale mode.\n<b>1.0</b> = standard, no scaling applied.\nHigher values = more dramatic effect.\nApplies to height, size, or both.\nValues above 1.5 increase load times.\nCombine with Scale Mode below." },
	MapScaleMode   = { "Scale Mode",        "What the Map Scale value applies to.\n<b>Height Only</b> = taller, same footprint.\n<b>Size Only</b> = wider, same height.\n<b>Both</b> = taller and wider combined.\nBoth is the heaviest generation option.\nHigher scale = longer load times." },
	Sandbox        = { "Sandbox Mode",      "A mode for experimenting freely.\n<b>Unlimited money</b> for placing anything.\nIncludes weather control and cheats.\nProgress saves permanently as normal.\nRequires the Sandbox gamepass.\nDoes not affect normal resort saves." },
}

local activeTooltip    = nil
local tooltipSessionId = 0
local TOOLTIP_FADE     = TweenInfo.new(0.15)

local function showTooltip(tooltipFrame, name, info)
	if not tooltipFrame then return end
	local nameLbl = tooltipFrame:FindFirstChild("Name")
	local infoLbl = tooltipFrame:FindFirstChild("Info")
	if nameLbl then nameLbl.Text = name end
	if infoLbl then infoLbl.Text = info end
	tooltipSessionId += 1
	activeTooltip = tooltipFrame
	tooltipFrame.Visible = true
	tooltipFrame.BackgroundTransparency = 1
	if nameLbl then nameLbl.TextTransparency = 1 end
	if infoLbl then infoLbl.TextTransparency = 1 end
	TweenService:Create(tooltipFrame, TOOLTIP_FADE, {BackgroundTransparency = 0}):Play()
	if nameLbl then TweenService:Create(nameLbl, TOOLTIP_FADE, {TextTransparency = 0}):Play() end
	if infoLbl then TweenService:Create(infoLbl, TOOLTIP_FADE, {TextTransparency = 0}):Play() end
end

local function hideTooltip(tooltipFrame)
	if not tooltipFrame then return end
	local sessionAtHide = tooltipSessionId
	activeTooltip = nil
	local nameLbl = tooltipFrame:FindFirstChild("Name")
	local infoLbl = tooltipFrame:FindFirstChild("Info")
	TweenService:Create(tooltipFrame, TOOLTIP_FADE, {BackgroundTransparency = 1}):Play()
	if nameLbl then TweenService:Create(nameLbl, TOOLTIP_FADE, {TextTransparency = 1}):Play() end
	if infoLbl then TweenService:Create(infoLbl, TOOLTIP_FADE, {TextTransparency = 1}):Play() end
	task.delay(TOOLTIP_FADE.Time, function()
		if tooltipSessionId == sessionAtHide then
			tooltipFrame.Visible = false
		end
	end)
end

local function attachTooltip(element, tooltipFrame, name, info)
	if not element or not tooltipFrame then return end
	element.MouseEnter:Connect(function() showTooltip(tooltipFrame, name, info) end)
	element.MouseLeave:Connect(function() hideTooltip(tooltipFrame) end)
end

local function formatMapScaleText(value)
	local rounded = math.floor((value * 100) + 0.5) / 100
	local text = string.format("%.2f", rounded)
	return text:gsub("%f[0]0+$", ""):gsub("%.$", "")
end

local function sanitizeMapScale(value)
	local scale = tonumber(value)
	if not scale or scale ~= scale or scale == math.huge or scale == -math.huge then scale = 1 end
	return math.clamp(scale, MAP_SCALE_MIN, MAP_SCALE_MAX)
end

local function applyMapScaleInput(textBox)
	if not textBox then return end
	mapScaleValue = sanitizeMapScale(textBox.Text)
	textBox.Text = formatMapScaleText(mapScaleValue)
end

local function getMapScaleModeOption()
	return MAP_SCALE_MODE_OPTIONS[mapScaleModeIndex] or MAP_SCALE_MODE_OPTIONS[1]
end

local function ensureMapScaleModeNode(settingsFrame, templateNode)
	if not settingsFrame or not templateNode then return nil, nil end
	local mapScaleModeNode = settingsFrame:FindFirstChild("MapScaleMode")
	if not mapScaleModeNode then
		mapScaleModeNode = templateNode:Clone()
		mapScaleModeNode.Name = "MapScaleMode"
		mapScaleModeNode.LayoutOrder = 3
		mapScaleModeNode.Parent = settingsFrame
		local valueObj = mapScaleModeNode:FindFirstChild("Value")
		if valueObj then valueObj:Destroy() end
	end
	local label = mapScaleModeNode:FindFirstChild("Label", true)
	if label then label.Text = "Scale Mode" end
	local input = mapScaleModeNode:FindFirstChild("Input") or mapScaleModeNode:FindFirstChildWhichIsA("TextBox", true)
	if input then input:Destroy() end
	local buttonFrame = mapScaleModeNode:FindFirstChild("Button")
	local button = buttonFrame and (buttonFrame:FindFirstChild("Text") or (buttonFrame:IsA("TextButton") and buttonFrame))
	if not button then
		button = Instance.new("TextButton")
		button.Name = "Button"
		button.Parent = mapScaleModeNode
	end
	button.BorderSizePixel = 0
	button.AutoButtonColor = true
	button.Font = Enum.Font.GothamBold
	button.TextColor3 = Color3.fromRGB(240, 244, 255)
	button.TextSize = 12
	button.Text = getMapScaleModeOption().Label
	local corner = button:FindFirstChildOfClass("UICorner")
	if not corner then
		corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(0, 6)
		corner.Parent = button
	end
	return mapScaleModeNode, button
end

local function parseCoordinateInput(rawValue, axis, latitudeHint)
	if rawValue == nil then return nil end
	local rawText = tostring(rawValue):match("^%s*(.-)%s*$")
	if rawText == "" then return nil end
	local upper = string.upper(rawText):gsub(",", ".")
	local hasNorth = upper:find("N", 1, true) ~= nil
	local hasSouth = upper:find("S", 1, true) ~= nil
	local hasEast  = upper:find("E", 1, true) ~= nil
	local hasWest  = upper:find("W", 1, true) ~= nil
	local cleaned  = upper:gsub("°", ""):gsub("[NSEW]", ""):gsub("%s+", "")
	local value = tonumber(cleaned)
	if not value or value ~= value or value == math.huge or value == -math.huge then return nil end
	if axis == "Latitude" then
		if hasSouth then value = -math.abs(value)
		elseif hasNorth then value = math.abs(value) end
		return math.clamp(value, -90, 90)
	end
	if hasEast then value = math.abs(value)
	elseif hasWest then value = -math.abs(value) end
	return math.clamp(value, -180, 180)
end

local function ensureMapScaleNode(settingsFrame, templateNode)
	if not settingsFrame or not templateNode then return nil, nil end
	local mapScaleNode = settingsFrame:FindFirstChild("MapScale")
	if not mapScaleNode then
		mapScaleNode = templateNode:Clone()
		mapScaleNode.Name = "MapScale"
		mapScaleNode.LayoutOrder = 2
		mapScaleNode.Parent = settingsFrame
		local valueObj = mapScaleNode:FindFirstChild("Value")
		if valueObj then valueObj:Destroy() end
		local oldButton = mapScaleNode:FindFirstChild("Button") or mapScaleNode:FindFirstChildWhichIsA("TextButton", true)
		if oldButton then oldButton:Destroy() end
	end
	local label = mapScaleNode:FindFirstChild("Label", true)
	if label then label.Text = "Map Scale" end
	local existingInput = mapScaleNode:FindFirstChild("Input") or mapScaleNode:FindFirstChildWhichIsA("TextBox", true)
	if existingInput then
		existingInput.Text = formatMapScaleText(mapScaleValue)
		return mapScaleNode, existingInput
	end
	local storage = playerGui:FindFirstChild("Storage")
	local textInpTemplate = storage and storage:FindFirstChild("TextInp")
	if not textInpTemplate then return mapScaleNode, nil end
	local inputContainer = textInpTemplate:Clone()
	inputContainer.Name = "Input"
	inputContainer.Visible = true
	inputContainer.ImageColor3 = COLORS.BtnOther
	inputContainer.Parent = mapScaleNode
	local input = inputContainer:FindFirstChildWhichIsA("TextBox", true)
	if input then
		input.BackgroundColor3 = COLORS.BtnOther
		input.ClearTextOnFocus = false
		input.PlaceholderText = "1.0"
		input.TextXAlignment = Enum.TextXAlignment.Center
		input.Text = formatMapScaleText(mapScaleValue)
	end
	return mapScaleNode, input
end

local function refreshCreationLayout(scrollFrame)
	if not scrollFrame then return end
	-- Double-defer: first pass lets layout update, second pass measures accurately
	task.defer(function()
		task.defer(function()
			local lowestBottom = 0
			local scrollTop = scrollFrame.AbsolutePosition.Y
			for _, child in ipairs(scrollFrame:GetChildren()) do
				if child:IsA("GuiObject") and child.Visible then
					local bottom = (child.AbsolutePosition.Y - scrollTop) + child.AbsoluteSize.Y
					if bottom > lowestBottom then lowestBottom = bottom end
				end
			end
			scrollFrame.CanvasSize = UDim2.new(0, 0, 0, math.max(lowestBottom + 24, scrollFrame.AbsoluteSize.Y + 24))
		end)
	end)
end

local function applyAdvancedVisibility(settingsFrame, toggleBtn, scrollFrame)
	if not settingsFrame then return end
	for _, nodeName in ipairs(ADVANCED_NODE_NAMES) do
		local node = settingsFrame:FindFirstChild(nodeName)
		if node then node.Visible = advancedExpanded end
	end
	if toggleBtn then
		-- FIX: was hardcoded to "Hide Advanced" on init regardless of advancedExpanded
		toggleBtn.Text = advancedExpanded and "Hide advanced" or "Show advanced"
	end
	refreshCreationLayout(scrollFrame)
end

local function buildAdvancedToggle(scrollFrame, settingsFrame)
	if not scrollFrame then return nil end
	local existing = scrollFrame:FindFirstChild("AdvancedToggle")
	if existing then return existing end

	local toggleBtn = Instance.new("TextButton")
	toggleBtn.Name = "AdvancedToggle"
	toggleBtn.Size = UDim2.new(1, 0, 1, 0)
	toggleBtn.AnchorPoint = Vector2.new(0.5, 0)
	toggleBtn.Position = UDim2.new(0.5, 0, 0, 0)
	toggleBtn.BackgroundColor3 = COLORS.Advanced
	toggleBtn.BorderSizePixel = 0
	toggleBtn.AutoButtonColor = true
	toggleBtn.Font = Enum.Font.GothamBold
	-- FIX: was "Hide Advanced" — should match initial advancedExpanded = false state
	toggleBtn.Text = "Show advanced"
	toggleBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
	toggleBtn.TextScaled = true
	toggleBtn.LayoutOrder = 99
	toggleBtn.Parent = scrollFrame

	local aspectRatio = Instance.new("UIAspectRatioConstraint")
	aspectRatio.AspectRatio = 12.091
	aspectRatio.Parent = toggleBtn

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0.3, 0)
	corner.Parent = toggleBtn

	local padding = Instance.new("UIPadding")
	padding.PaddingBottom = UDim.new(0.1, 0)
	padding.PaddingTop    = UDim.new(0.1, 0)
	padding.Parent = toggleBtn

	toggleBtn.Activated:Connect(function()
		advancedExpanded = not advancedExpanded
		applyAdvancedVisibility(settingsFrame, toggleBtn, scrollFrame)
	end)

	return toggleBtn
end

-- // HEADER BUTTON HELPERS //
local function getLobbyHeaderButtons()
	if background then
		local container = background:FindFirstChild("Container")
		local header    = container and container:FindFirstChild("Header")
		local buttons   = header and header:FindFirstChild("Buttons")
		if buttons then return buttons end
	end
	local header = deepFind(gui, "Header")
	return header and header:FindFirstChild("Buttons")
end

local function getHeaderButton(buttonName)
	local buttonsContainer = getLobbyHeaderButtons()
	if not buttonsContainer then return nil end
	local button = buttonsContainer:FindFirstChild(buttonName)
	if button and (button:IsA("TextButton") or button:IsA("ImageButton")) then
		return button
	end
	return nil
end

local function normalizeButtonText(text)
	local cleaned = tostring(text or "")
	cleaned = cleaned:gsub("<.->", " ")
	cleaned = cleaned:gsub("%s+", " ")
	cleaned = cleaned:match("^%s*(.-)%s*$") or ""
	return string.upper(cleaned)
end

local function getHeaderButtonByLabel(targetLabel, fallbackNames)
	local wanted = normalizeButtonText(targetLabel)
	local buttonsContainer = getLobbyHeaderButtons()
	if buttonsContainer then
		for _, child in ipairs(buttonsContainer:GetChildren()) do
			if child:IsA("TextButton") or child:IsA("ImageButton") then
				local buttonText = normalizeButtonText(child.Text)
				if buttonText == wanted or string.find(buttonText, wanted, 1, true) then
					return child
				end
			end
		end
	end
	for _, buttonName in ipairs(fallbackNames or {}) do
		local fallback = getHeaderButton(buttonName)
		if fallback then return fallback end
	end
	return nil
end

-- FIX: Only connect Activated. Connecting both Activated and MouseButton1Click
-- causes double-fires on mobile where both events can fire from one tap.
local function bindGuiButton(button, callback)
	if not (button and callback) then return end
	local firedAt = 0
	local function fire()
		local now = os.clock()
		if now - firedAt < 0.12 then return end
		firedAt = now
		callback()
	end
	button.Activated:Connect(fire)
end

-- // CREATION UI ANIMATION //
local function getCreationCanvasGroup()
	if creationUI and creationUI:IsA("CanvasGroup") then return creationUI end
	return nil
end

local function showCreationUI()
	if not creationUI then return end
	creationUI.AnchorPoint = Vector2.new(0.5, 0.5)
	creationUI.Position = CREATION_POS_CLOSE
	creationUI.Visible = true
	local cg = getCreationCanvasGroup()
	if cg then
		cg.GroupTransparency = 1
		TweenService:Create(cg, CREATION_TWEEN_IN, {GroupTransparency = 0}):Play()
	end
	TweenService:Create(creationUI, CREATION_TWEEN_IN, {Position = CREATION_POS_OPEN}):Play()
end

local function hideCreationUI(callback)
	if not creationUI then
		if callback then callback() end
		return
	end
	local cg = getCreationCanvasGroup()
	TweenService:Create(creationUI, CREATION_TWEEN_OUT, {Position = CREATION_POS_CLOSE}):Play()
	if cg then
		TweenService:Create(cg, CREATION_TWEEN_OUT, {GroupTransparency = 1}):Play()
	end
	task.delay(CREATION_TWEEN_OUT.Time, function()
		creationUI.Visible = false
		if callback then callback() end
	end)
end

local function showServiceNotice()
	if serviceNoticeShown or hideServiceNoticeForever or not gui then return end
	serviceNoticeShown = true
	local existing = gui:FindFirstChild("GuestServiceNotice")
	if existing then existing:Destroy() end

	local overlay = Instance.new("Frame")
	overlay.Name = "GuestServiceNotice"
	overlay.Size = UDim2.fromScale(1, 1)
	overlay.BackgroundColor3 = Color3.fromRGB(4, 6, 10)
	overlay.BackgroundTransparency = 1
	overlay.BorderSizePixel = 0
	overlay.ZIndex = 80
	overlay.Active = true
	overlay.Parent = gui

	local card = Instance.new("Frame")
	card.Name = "Card"
	card.AnchorPoint = Vector2.new(0.5, 0.5)
	card.Position = UDim2.new(0.5, 0, 0.5, 22)
	card.Size = UDim2.new(0.58, 0, 0, 320)
	card.BackgroundColor3 = COLORS.Empty
	card.BorderSizePixel = 0
	card.ZIndex = 81
	card.Parent = overlay

	local cardConstraint = Instance.new("UISizeConstraint")
	cardConstraint.MinSize = Vector2.new(380, 308)
	cardConstraint.MaxSize = Vector2.new(620, 360)
	cardConstraint.Parent = card

	local cardCorner = Instance.new("UICorner")
	cardCorner.CornerRadius = UDim.new(0, 12)
	cardCorner.Parent = card

	local cardStroke = Instance.new("UIStroke")
	cardStroke.Color = Color3.fromRGB(28, 32, 39)
	cardStroke.Thickness = 1.5
	cardStroke.Parent = card

	local cardGradient = Instance.new("UIGradient")
	cardGradient.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(18, 21, 27)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(11, 13, 17)),
	})
	cardGradient.Rotation = 90
	cardGradient.Parent = card

	local accent = Instance.new("Frame")
	accent.Name = "Accent"
	accent.Size = UDim2.new(1, 0, 0, 4)
	accent.BackgroundColor3 = COLORS.Tester
	accent.BorderSizePixel = 0
	accent.ZIndex = 82
	accent.Parent = card

	local accentCorner = Instance.new("UICorner")
	accentCorner.CornerRadius = UDim.new(0, 12)
	accentCorner.Parent = accent

	local accentMask = Instance.new("Frame")
	accentMask.AnchorPoint = Vector2.new(0.5, 1)
	accentMask.Position = UDim2.new(0.5, 0, 1, 0)
	accentMask.Size = UDim2.new(1, 0, 0, 8)
	accentMask.BackgroundColor3 = COLORS.Empty
	accentMask.BorderSizePixel = 0
	accentMask.ZIndex = 83
	accentMask.Parent = accent

	local padding = Instance.new("UIPadding")
	padding.PaddingTop    = UDim.new(0, 20)
	padding.PaddingBottom = UDim.new(0, 20)
	padding.PaddingLeft   = UDim.new(0, 20)
	padding.PaddingRight  = UDim.new(0, 20)
	padding.Parent = card

	local eyebrow = Instance.new("TextLabel")
	eyebrow.Name = "Eyebrow"
	eyebrow.Size = UDim2.new(0, 142, 0, 28)
	eyebrow.BackgroundColor3 = Color3.fromRGB(87, 41, 29)
	eyebrow.BorderSizePixel = 0
	eyebrow.Font = Enum.Font.GothamBold
	eyebrow.Text = SERVICE_NOTICE.Eyebrow
	eyebrow.TextColor3 = Color3.fromRGB(255, 224, 211)
	eyebrow.TextSize = 13
	eyebrow.ZIndex = 82
	eyebrow.Parent = card

	local eyebrowCorner = Instance.new("UICorner")
	eyebrowCorner.CornerRadius = UDim.new(0, 8)
	eyebrowCorner.Parent = eyebrow

	local logoPanel = Instance.new("Frame")
	logoPanel.Name = "LogoPanel"
	logoPanel.AnchorPoint = Vector2.new(1, 0)
	logoPanel.Position = UDim2.new(1, 0, 0, 38)
	logoPanel.Size = UDim2.new(0, 118, 0, 124)
	logoPanel.BackgroundColor3 = Color3.fromRGB(14, 17, 23)
	logoPanel.BackgroundTransparency = 0.08
	logoPanel.BorderSizePixel = 0
	logoPanel.ZIndex = 82
	logoPanel.Parent = card

	local logoPanelCorner = Instance.new("UICorner")
	logoPanelCorner.CornerRadius = UDim.new(0, 12)
	logoPanelCorner.Parent = logoPanel

	local logoPanelStroke = Instance.new("UIStroke")
	logoPanelStroke.Color = Color3.fromRGB(28, 32, 39)
	logoPanelStroke.Thickness = 1
	logoPanelStroke.Parent = logoPanel

	local logo = Instance.new("ImageLabel")
	logo.Name = "Logo"
	logo.AnchorPoint = Vector2.new(0.5, 0)
	logo.Position = UDim2.new(0.5, 0, 0, 14)
	logo.Size = UDim2.new(0, 70, 0, 70)
	logo.BackgroundTransparency = 1
	logo.Image = SERVICE_NOTICE.LogoImage
	logo.ScaleType = Enum.ScaleType.Fit
	logo.ZIndex = 83
	logo.Parent = logoPanel

	local logoLabel = Instance.new("TextLabel")
	logoLabel.Name = "LogoLabel"
	logoLabel.AnchorPoint = Vector2.new(0.5, 1)
	logoLabel.Position = UDim2.new(0.5, 0, 1, -12)
	logoLabel.Size = UDim2.new(1, -18, 0, 20)
	logoLabel.BackgroundTransparency = 1
	logoLabel.Font = Enum.Font.GothamBold
	logoLabel.Text = SERVICE_NOTICE.LogoLabel
	logoLabel.TextColor3 = Color3.fromRGB(133, 146, 170)
	logoLabel.TextSize = 11
	logoLabel.TextWrapped = true
	logoLabel.ZIndex = 83
	logoLabel.Parent = logoPanel

	local logoButton = Instance.new("TextButton")
	logoButton.Name = "LogoButton"
	logoButton.Size = UDim2.fromScale(1, 1)
	logoButton.BackgroundTransparency = 1
	logoButton.BorderSizePixel = 0
	logoButton.AutoButtonColor = false
	logoButton.Text = ""
	logoButton.ZIndex = 84
	logoButton.Parent = logoPanel

	local title = Instance.new("TextLabel")
	title.Name = "Title"
	title.Position = UDim2.new(0, 0, 0, 40)
	title.Size = UDim2.new(1, -136, 0, 54)
	title.BackgroundTransparency = 1
	title.Font = Enum.Font.GothamBold
	title.Text = SERVICE_NOTICE.Title
	title.TextColor3 = Color3.fromRGB(240, 244, 255)
	title.TextSize = 26
	title.TextWrapped = true
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.TextYAlignment = Enum.TextYAlignment.Top
	title.ZIndex = 82
	title.Parent = card

	local message = Instance.new("TextLabel")
	message.Name = "Message"
	message.Position = UDim2.new(0, 0, 0, 104)
	message.Size = UDim2.new(1, -136, 0, 116)
	message.BackgroundTransparency = 1
	message.Font = Enum.Font.GothamBold
	message.Text = SERVICE_NOTICE.Message
	message.TextColor3 = Color3.fromRGB(176, 188, 208)
	message.TextSize = 16
	message.TextWrapped = true
	message.TextXAlignment = Enum.TextXAlignment.Left
	message.TextYAlignment = Enum.TextYAlignment.Top
	message.ZIndex = 82
	message.Parent = card

	local helper = Instance.new("TextLabel")
	helper.Name = "Helper"
	helper.Position = UDim2.new(0, 0, 0, 214)
	helper.Size = UDim2.new(1, -136, 0, 20)
	helper.BackgroundTransparency = 1
	helper.Font = Enum.Font.GothamBold
	helper.Text = "Tap the icon for directions"
	helper.TextColor3 = Color3.fromRGB(118, 129, 148)
	helper.TextSize = 13
	helper.TextXAlignment = Enum.TextXAlignment.Left
	helper.TextYAlignment = Enum.TextYAlignment.Center
	helper.ZIndex = 82
	helper.Parent = card

	local hideToggle = Instance.new("TextButton")
	hideToggle.Name = "HideToggle"
	hideToggle.Position = UDim2.new(0, 0, 0, 238)
	hideToggle.Size = UDim2.new(1, -136, 0, 24)
	hideToggle.BackgroundTransparency = 1
	hideToggle.BorderSizePixel = 0
	hideToggle.AutoButtonColor = false
	hideToggle.Text = ""
	hideToggle.ZIndex = 82
	hideToggle.Parent = card

	local hideToggleState = false
	local hideBox = Instance.new("Frame")
	hideBox.Name = "Box"
	hideBox.Position = UDim2.new(0, 0, 0.5, -8)
	hideBox.Size = UDim2.new(0, 16, 0, 16)
	hideBox.BackgroundColor3 = Color3.fromRGB(14, 17, 23)
	hideBox.BorderSizePixel = 0
	hideBox.ZIndex = 83
	hideBox.Parent = hideToggle

	local hideBoxCorner = Instance.new("UICorner")
	hideBoxCorner.CornerRadius = UDim.new(0, 4)
	hideBoxCorner.Parent = hideBox

	local hideBoxStroke = Instance.new("UIStroke")
	hideBoxStroke.Color = Color3.fromRGB(72, 80, 95)
	hideBoxStroke.Thickness = 1
	hideBoxStroke.Parent = hideBox

	local hideCheck = Instance.new("TextLabel")
	hideCheck.Name = "Check"
	hideCheck.Size = UDim2.fromScale(1, 1)
	hideCheck.BackgroundTransparency = 1
	hideCheck.Font = Enum.Font.GothamBold
	hideCheck.Text = ""
	hideCheck.TextColor3 = Color3.fromRGB(235, 240, 248)
	hideCheck.TextSize = 12
	hideCheck.ZIndex = 84
	hideCheck.Parent = hideBox

	local hideLabel = Instance.new("TextLabel")
	hideLabel.Name = "Label"
	hideLabel.Position = UDim2.new(0, 26, 0, 0)
	hideLabel.Size = UDim2.new(1, -26, 1, 0)
	hideLabel.BackgroundTransparency = 1
	hideLabel.Font = Enum.Font.GothamBold
	hideLabel.Text = "Do not show this again"
	hideLabel.TextColor3 = Color3.fromRGB(176, 188, 208)
	hideLabel.TextSize = 13
	hideLabel.TextXAlignment = Enum.TextXAlignment.Left
	hideLabel.TextYAlignment = Enum.TextYAlignment.Center
	hideLabel.ZIndex = 83
	hideLabel.Parent = hideToggle

	local function refreshHideToggle()
		hideCheck.Text = hideToggleState and "✓" or ""
		hideBox.BackgroundColor3 = hideToggleState and COLORS.CycleActive or Color3.fromRGB(14, 17, 23)
		hideBoxStroke.Color = hideToggleState and Color3.fromRGB(81, 107, 172) or Color3.fromRGB(72, 80, 95)
	end
	refreshHideToggle()

	local button = Instance.new("TextButton")
	button.Name = "Confirm"
	button.AnchorPoint = Vector2.new(0.5, 1)
	button.Position = UDim2.new(0.5, 0, 1, -12)
	button.Size = UDim2.new(0, 176, 0, 38)
	button.BackgroundColor3 = COLORS.CycleActive
	button.BorderSizePixel = 0
	button.AutoButtonColor = true
	button.Font = Enum.Font.GothamBold
	button.Text = SERVICE_NOTICE.ButtonText
	button.TextColor3 = Color3.fromRGB(255, 255, 255)
	button.TextSize = 15
	button.ZIndex = 82
	button.Parent = card

	local buttonCorner = Instance.new("UICorner")
	buttonCorner.CornerRadius = UDim.new(0, 8)
	buttonCorner.Parent = button

	local buttonStroke = Instance.new("UIStroke")
	buttonStroke.Color = Color3.fromRGB(81, 107, 172)
	buttonStroke.Thickness = 1
	buttonStroke.Parent = button

	local buttonPadding = Instance.new("UIPadding")
	buttonPadding.PaddingLeft  = UDim.new(0, 12)
	buttonPadding.PaddingRight = UDim.new(0, 12)
	buttonPadding.Parent = button

	local closing = false
	local function dismissNotice()
		if closing then return end
		closing = true
		if hideToggleState and LobbyNoticePreference then
			hideServiceNoticeForever = true
			pcall(function() LobbyNoticePreference:InvokeServer("SetHideServiceNotice", true) end)
		end
		TweenService:Create(overlay, TweenInfo.new(0.16, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {BackgroundTransparency = 1}):Play()
		TweenService:Create(card, TweenInfo.new(0.16, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {Position = UDim2.new(0.5, 0, 0.5, 12)}):Play()
		task.delay(0.16, function()
			if overlay and overlay.Parent then overlay:Destroy() end
		end)
	end

	bindGuiButton(hideToggle, function() hideToggleState = not hideToggleState; refreshHideToggle() end)
	bindGuiButton(button, dismissNotice)
	bindGuiButton(logoButton, function()
		helper.Text = "Open the game page, then click Communications."
		helper.TextColor3 = Color3.fromRGB(166, 196, 255)
		TweenService:Create(logoPanel, TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {BackgroundTransparency = 0}):Play()
		TweenService:Create(logoPanelStroke, TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {Color = Color3.fromRGB(88, 114, 185)}):Play()
		task.delay(2.4, function()
			if helper and helper.Parent then helper.Text = "Tap the icon for directions"; helper.TextColor3 = Color3.fromRGB(118, 129, 148) end
			if logoPanel and logoPanel.Parent then TweenService:Create(logoPanel, TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {BackgroundTransparency = 0.08}):Play() end
			if logoPanelStroke and logoPanelStroke.Parent then TweenService:Create(logoPanelStroke, TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {Color = Color3.fromRGB(28, 32, 39)}):Play() end
		end)
	end)

	TweenService:Create(overlay, TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {BackgroundTransparency = 0.35}):Play()
	TweenService:Create(card, TweenInfo.new(0.22, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {Position = UDim2.new(0.5, 0, 0.5, 0)}):Play()
end

local function hideLobbyPanels(except)
	for _, name in ipairs({ "How2", "LobbyTutorial", "JoinFriendPanel" }) do
		local panel = deepFind(gui, name)
		if panel and panel ~= except then panel.Visible = false end
	end
end

local function bindExistingTutorialUI()
	if not gui then return nil end
	local legacy = gui:FindFirstChild("LobbyTutorial")
	if legacy then legacy:Destroy() end
	local tutorial = deepFind(gui, "How2")
	if not tutorial or not tutorial:IsA("Frame") then return nil end
	tutorial.Visible = false

	local button = getHeaderButtonByLabel("GET STARTED", { "DonateButton", "TutorialButton" })
	if button and not button:GetAttribute("LobbyBound") then
		button:SetAttribute("LobbyBound", true)
		bindGuiButton(button, function()
			local nextVisible = not tutorial.Visible
			hideLobbyPanels(nextVisible and tutorial or nil)
			tutorial.Visible = nextVisible
		end)
	end

	local close = tutorial:FindFirstChild("CloseButton") or tutorial:FindFirstChild("Close")
	if close and close:IsA("GuiButton") and not close:GetAttribute("LobbyBound") then
		close:SetAttribute("LobbyBound", true)
		bindGuiButton(close, function() tutorial.Visible = false end)
	end
	return tutorial
end

local function getResolveJoinPinRemote()
	if ResolveJoinPin and ResolveJoinPin:IsA("RemoteFunction") then return ResolveJoinPin end
	local eventsFolder = ReplicatedStorage:FindFirstChild("Events")
	local remote = eventsFolder and eventsFolder:FindFirstChild("ResolveJoinPin")
	if remote and remote:IsA("RemoteFunction") then
		ResolveJoinPin = remote
		return remote
	end
	return nil
end

local function bindExistingJoinFriendUI()
	if not gui then return nil end
	local panel = deepFind(gui, "JoinFriendPanel")
	if not panel or not panel:IsA("Frame") then return nil end
	panel.Visible = false

	local button = (background and background:FindFirstChild("JoinFriendButton")) or deepFind(gui, "JoinFriendButton")
	local inputBox = deepFind(panel, "FriendCodeInput")
	local statusLabel = deepFind(panel, "JoinFriendStatus")
	local joinBtn = deepFind(panel, "Yes")
	local closeBtn = deepFind(panel, "No")
	if not (button and inputBox and joinBtn and closeBtn) then return panel end

	local defaultJoinText = joinBtn.Text
	local defaultStatusColor = statusLabel and statusLabel.TextColor3 or Color3.fromRGB(166, 196, 255)
	local isJoining = false

	local function setStatus(text, color)
		if statusLabel then statusLabel.Text = text or ""; statusLabel.TextColor3 = color or defaultStatusColor end
	end
	local function resetJoinUi()
		isJoining = false; joinBtn.Text = defaultJoinText; joinBtn.Active = true; joinBtn.AutoButtonColor = true
	end
	local function closePanel()
		if isJoining then return end; panel.Visible = false; setStatus("")
	end
	local function doJoin()
		if isJoining then return end
		local pin = string.upper(string.gsub(inputBox.Text or "", "%s+", ""))
		if #pin < 4 then
			joinBtn.Text = "ENTER CODE"
			setStatus("Enter a valid friend code first.", Color3.fromRGB(255, 120, 120))
			task.delay(1.2, resetJoinUi); return
		end
		local resolveFunc = getResolveJoinPinRemote()
		if not resolveFunc then
			joinBtn.Text = "OFFLINE"
			setStatus("Join service is not ready yet. Try again in a moment.", Color3.fromRGB(255, 120, 120))
			task.delay(1.6, resetJoinUi); return
		end
		isJoining = true; joinBtn.Text = "SEARCHING..."; joinBtn.Active = false; joinBtn.AutoButtonColor = false
		setStatus("Looking up your friend's world...", Color3.fromRGB(166, 196, 255))
		local ok, response = pcall(function() return resolveFunc:InvokeServer(pin) end)
		response = ok and response or "CONNECTION_ERR"
		if response == "TELEPORTING" then
			joinBtn.Text = "TELEPORTING..."
			setStatus("Teleporting you to your friend's world...", Color3.fromRGB(120, 235, 170)); return
		elseif response == "ALREADY_HERE" then
			joinBtn.Text = "ALREADY THERE"
			setStatus("You are already connected to that server.", Color3.fromRGB(166, 196, 255))
		elseif response == "INVALID_PIN" or response == "INVALID_FMT" then
			joinBtn.Text = "INVALID CODE"
			setStatus("That friend code could not be found.", Color3.fromRGB(255, 120, 120))
		elseif response == "STUDIO_NO_TP" then
			joinBtn.Text = "STUDIO MODE"
			setStatus("Studio cannot complete the actual teleport.", Color3.fromRGB(255, 235, 140))
		elseif response and string.match(tostring(response), "^TP_FAIL") then
			joinBtn.Text = "TP FAILED"
			setStatus("Teleport failed. Try the code again in a second.", Color3.fromRGB(255, 120, 120))
		elseif response == "CONNECTION_ERR" or response == "NO_REMOTE" then
			joinBtn.Text = "OFFLINE"
			setStatus("Could not contact the join service.", Color3.fromRGB(255, 120, 120))
		else
			joinBtn.Text = "ERROR"
			setStatus("Unexpected join response: " .. tostring(response), Color3.fromRGB(255, 120, 120))
		end
		task.delay(1.8, function() if joinBtn and joinBtn.Parent then resetJoinUi() end end)
	end

	if not button:GetAttribute("LobbyJoinBound") then
		button:SetAttribute("LobbyJoinBound", true)
		bindGuiButton(button, function()
			local nextVisible = not panel.Visible
			hideLobbyPanels(nextVisible and panel or nil)
			panel.Visible = nextVisible
			if nextVisible then
				setStatus("")
				task.defer(function() if inputBox and inputBox.Parent then inputBox:CaptureFocus() end end)
			end
		end)
	end
	if not closeBtn:GetAttribute("LobbyJoinBound") then
		closeBtn:SetAttribute("LobbyJoinBound", true)
		bindGuiButton(closeBtn, closePanel)
	end
	if not joinBtn:GetAttribute("LobbyJoinBound") then
		joinBtn:SetAttribute("LobbyJoinBound", true)
		bindGuiButton(joinBtn, doJoin)
		inputBox.FocusLost:Connect(function(enterPressed) if enterPressed and panel.Visible then doJoin() end end)
	end
	return panel
end

local function generateMissingSlots()
	if not slotsFrame then return end
	local templateSlot = slotsFrame:FindFirstChild("Slot1")
	if templateSlot then
		for i = 4, 9 do
			if not slotsFrame:FindFirstChild("Slot"..i) then
				print("[LobbyUI] Auto-generating UI frame for Slot " .. i)
				local newSlot = templateSlot:Clone()
				newSlot.Name = "Slot"..i
				newSlot.LayoutOrder = i
				newSlot.Parent = slotsFrame
			end
		end
	else
		warn("[LobbyUI] Slot1 not found. Cannot auto-generate missing slots.")
	end
end

local function setCardLoadingState(card)
	if not card then return end
	card:SetAttribute("SlotState", "Loading")
	local nameLbl   = deepFind(card, "Name")
	local infoLbl   = deepFind(card, "Info")
	local playFrame = deepFind(card, "Play")
	local newFrame  = deepFind(card, "New")
	local delFrame  = deepFind(card, "Delete")
	local sandboxTag = ensureSlotSandboxTag(card)
	local playBtn = playFrame and playFrame:FindFirstChild("Text")
	local newBtn  = newFrame  and newFrame:FindFirstChild("Text")
	local delBtn  = delFrame  and delFrame:FindFirstChild("Text")
	if nameLbl then nameLbl.Text = SLOT_LOADING_TITLE; nameLbl:SetAttribute("OriginalName", nil) end
	if infoLbl   then infoLbl.Text   = SLOT_LOADING_BODY end
	if playFrame then playFrame.Visible = false end
	if newFrame  then newFrame.Visible  = false end
	if delFrame  then delFrame.Visible  = false end
	if sandboxTag then sandboxTag.Visible = false end
	if playBtn then playBtn.Active = false end
	if newBtn  then newBtn.Active  = false end
	if delBtn  then delBtn.Active  = false end
	card.BackgroundColor3 = COLORS.Empty
end

local function setAllCardsLoadingState()
	if not slotsFrame then return end
	for i = 1, 9 do setCardLoadingState(deepFind(slotsFrame, "Slot" .. i)) end
end

local function resetCardVisualState(card)
	if not card then return end
	local nameLbl   = deepFind(card, "Name")
	local infoLbl   = deepFind(card, "Info")
	local playFrame = deepFind(card, "Play")
	local newFrame  = deepFind(card, "New")
	local delFrame  = deepFind(card, "Delete")
	local playBtn = playFrame and playFrame:FindFirstChild("Text")
	local newBtn  = newFrame  and newFrame:FindFirstChild("Text")
	local delBtn  = delFrame  and delFrame:FindFirstChild("Text")
	card.BackgroundTransparency = 0
	if nameLbl  then nameLbl.TextTransparency  = 0 end
	if infoLbl  then infoLbl.TextTransparency  = 0 end
	if playFrame then playFrame.ImageTransparency = 0.65 end
	if newFrame  then newFrame.ImageTransparency  = 0.65 end
	if delFrame  then delFrame.ImageTransparency  = 0.65 end
	if playBtn then playBtn.Active = true; playBtn.AutoButtonColor = true end
	if newBtn  then newBtn.Active  = true; newBtn.AutoButtonColor  = true end
	if delBtn  then delBtn.Active  = true; delBtn.AutoButtonColor  = true end
end

local function invokeSlotRequestWithRetry(action, ...)
	local packedArgs = table.pack(...)
	local lastResult = nil
	for attempt = 1, SLOT_REQUEST_RETRY_ATTEMPTS do
		local ok, result = pcall(function()
			return SlotRequest:InvokeServer(action, table.unpack(packedArgs, 1, packedArgs.n))
		end)
		if ok and type(result) == "table" then
			lastResult = result
			if result.Success then
				if attempt > 1 then print("[LobbyUI] Slot request succeeded on retry " .. attempt .. " for action " .. tostring(action)) end
				return result
			end
			if not result.Retryable then return result end
		else
			lastResult = { Success = false, Error = ok and "Unknown" or tostring(result), Retryable = true }
		end
		if attempt < SLOT_REQUEST_RETRY_ATTEMPTS then task.wait(SLOT_REQUEST_RETRY_DELAY_SECONDS * attempt) end
	end
	return lastResult
end

local function refreshUI(forceRefresh)
	if isRefreshing then return end
	isRefreshing = true
	if not hasLoadedSlotsOnce then setAllCardsLoadingState() end
	print("[LobbyUI] Refreshing slots UI. Force: " .. tostring(forceRefresh))

	local result = invokeSlotRequestWithRetry(forceRefresh and "Refresh" or "Get")

	if result and result.Success then
		hasLoadedSlotsOnce = true

		if result.IsFirstTime and not forceRefresh then
			print("[LobbyUI] First time player detected. Auto-creating Slot 1 and skipping lobby...")
			local targetSlot = 1
			local settingsData = {}
			
			if loadingUI then
				loadingUI.Visible = true
				local textLabel = loadingUI:FindFirstChildWhichIsA("TextLabel", true)
				if textLabel then textLabel.Text = "Creating world..." end
			end
			RunService.Heartbeat:Wait()
			
			local createResult = invokeSlotRequestWithRetry("Create", targetSlot, settingsData)
			if createResult and createResult.Success then
				if logCustomEvent then logCustomEvent("first_time_auto_skip") end
				if logStep then
					logStep("new_slot_clicked")
					logStep("creation_screen_seen")
					logStep("create_clicked")
					logStep("world_created")
					logStep("world_joined")
					logStep("teleport_started")
				end
				
				if loadingUI then
					local textLabel = loadingUI:FindFirstChildWhichIsA("TextLabel", true)
					if textLabel then textLabel.Text = "Preparing world..." end
				end
				RunService.Heartbeat:Wait()
				
				local tpOk, tpResult = pcall(function()
					return TeleportToSlot:InvokeServer(targetSlot)
				end)
				if not tpOk or not (tpResult and tpResult.Success) then
					warn("[LobbyUI] Auto-teleport failed for first-time player.")
				else
					return -- Auto-setup successful, do not load rest of Lobby UI.
				end
			else
				warn("[LobbyUI] Auto-create failed for first-time player.")
			end
			
			if loadingUI then loadingUI.Visible = false end
		end

		local loadedSlotCount = 0
		if type(result.Slots) == "table" then
			for _ in pairs(result.Slots) do loadedSlotCount += 1 end
		end
		ownsExtraSlots  = result.OwnsExtraSlots or false
		ownsSandboxPass = result.OwnsSandbox or false
		local isTester  = result.IsTester or false
		if not ownsExtraSlots  then ownsExtraSlots  = hasSlotUnlockAccess() end
		if not ownsSandboxPass then ownsSandboxPass = hasEntitlement(SANDBOX_GAMEPASS_ID) end

		for i = 1, 9 do
			local card = deepFind(slotsFrame, "Slot"..i)
			if card then
				card.LayoutOrder = i
				if i > 6 and not isTester then card.Visible = false; continue
				else card.Visible = true end

				local slot      = result.Slots and result.Slots["SlotKey_" .. i]
				local nameLbl   = deepFind(card, "Name")
				local infoLbl   = deepFind(card, "Info")
				local playFrame = deepFind(card, "Play")
				local newFrame  = deepFind(card, "New")
				local delFrame  = deepFind(card, "Delete")
				local sandboxTag = ensureSlotSandboxTag(card)
				local playBtn = playFrame and playFrame:FindFirstChild("Text")
				local newBtn  = newFrame  and newFrame:FindFirstChild("Text")
				local delBtn  = delFrame  and delFrame:FindFirstChild("Text")

				resetCardVisualState(card)
				if sandboxTag then sandboxTag.Visible = (slot and slot.SandboxMode == true) or false end

				if slot then
					card:SetAttribute("SlotState", "Loaded")
					logStep("slots_loaded")
					if playBtn then playBtn.Active = true end
					if newBtn  then newBtn.Active  = true end
					if delBtn  then delBtn.Active  = true end
					if nameLbl then nameLbl.Text = slot.Name; nameLbl:SetAttribute("OriginalName", slot.Name) end
					if infoLbl  then infoLbl.Text  = "Last played: <b>" .. tostring(slot.LastPlayed) .. "</b>" end
					if playFrame then playFrame.Visible = true end
					if newFrame  then newFrame.Visible  = false end
					if delFrame  then delFrame.Visible  = true end
				else
					card:SetAttribute("SlotState", "Loaded")
					logStep("slots_loaded")
					if playBtn then playBtn.Active = false end
					if delBtn  then delBtn.Active  = false end
					if newBtn  then newBtn.Active  = true end
					if playFrame then playFrame.Visible = false end
					if delFrame  then delFrame.Visible  = false end
					if newFrame  then newFrame.Visible  = true end
					if i > 6 then
						if nameLbl then nameLbl.Text = "TESTER Slot"; nameLbl:SetAttribute("OriginalName", nil) end
						if infoLbl then infoLbl.Text = "Creates <b>testing server</b> save" end
						if newBtn  then newBtn.Text  = "New" end
						card.BackgroundColor3 = COLORS.Empty
					elseif i > 3 and not ownsExtraSlots then
						if nameLbl then nameLbl.Text = "Locked Slot"; nameLbl:SetAttribute("OriginalName", nil) end
						if infoLbl then infoLbl.Text = "Requires <b>Slot Unlock</b> pass or active Resort/Unlimited Slots subscription" end
						if newBtn  then newBtn.Text  = "Unlock" end
						card.BackgroundColor3 = COLORS.Locked
					else
						if nameLbl then nameLbl.Text = "Empty Slot"; nameLbl:SetAttribute("OriginalName", nil) end
						if infoLbl then infoLbl.Text = "Create a <b>new resort</b> to get started" end
						if newBtn  then newBtn.Text  = "New" end
						card.BackgroundColor3 = COLORS.Empty
					end
				end

				if i > 6 then
					if newBtn  then newBtn.BackgroundColor3  = COLORS.Tester; newBtn.TextColor3  = Color3.fromRGB(255, 255, 255) end
					if playBtn then playBtn.BackgroundColor3 = COLORS.Tester; playBtn.TextColor3 = Color3.fromRGB(255, 255, 255) end
				end
			end
		end

		local scrollFrame   = creationUI and creationUI:FindFirstChild("Scroll")
		local settingsFrame = scrollFrame and scrollFrame:FindFirstChild("Settings")
		local function findNode(name)
			return (settingsFrame and settingsFrame:FindFirstChild(name)) or (scrollFrame and scrollFrame:FindFirstChild(name))
		end
		local sandboxNode  = findNode("Sandbox") or findNode("RealisticMode")
		local sandboxFrame = sandboxNode and sandboxNode:FindFirstChild("Button")
		local sandboxBtn   = sandboxFrame and sandboxFrame:FindFirstChild("Text")

		if sandboxBtn then
			if ownsSandboxPass then
				local sbColor = sandboxModeEnabled and COLORS.ToggleOn or COLORS.ToggleOff
				sandboxBtn.Text = sandboxModeEnabled and "ON" or "OFF"
				sandboxBtn.BackgroundColor3 = sbColor
				sandboxBtn.TextColor3 = sandboxModeEnabled and Color3.fromRGB(20, 60, 35) or Color3.fromRGB(255, 255, 255)
				local wrapper = sandboxBtn.Parent
				if wrapper and (wrapper:IsA("ImageLabel") or wrapper:IsA("ImageButton")) and wrapper.Name == "Button" then wrapper.ImageColor3 = sbColor end
			else
				sandboxBtn.Text = "GET PASS"
				sandboxBtn.BackgroundColor3 = Color3.fromRGB(150, 100, 20)
				sandboxBtn.TextColor3 = Color3.fromRGB(255, 230, 150)
			end
		end

		if loadedSlotCount == 0 and not forceRefresh and not hasQueuedRecoveryRefresh then
			hasQueuedRecoveryRefresh = true
			warn("[LobbyUI] Initial slot list was empty. Queuing one forced refresh.")
			task.delay(1.0, function() hasQueuedRecoveryRefresh = false; refreshUI(true) end)
		elseif loadedSlotCount > 0 then
			hasQueuedRecoveryRefresh = false
		end
	else
		warn("[LobbyUI] Failed to get slots data: " .. tostring(result and result.Error))
	end

	isRefreshing = false
end

local function setupCreationUI()
	if not creationUI then
		warn("[LobbyUI] CreationUI frame not found. Creation flow will not work.")
		return
	end

	creationUI.Visible = false

	local donateButton = getHeaderButtonByLabel("DONATE", { "TutorialButton", "DonateButton" })
	if donateButton and not donateButton:GetAttribute("LobbyBound") then
		donateButton:SetAttribute("LobbyBound", true)
		bindGuiButton(donateButton, function()
			logCustomEvent("donate_click")
			OpenDonationUI:FireServer()
		end)
	end

	local buttonsFrame = creationUI:FindFirstChild("Buttons")
	if not buttonsFrame then warn("[LobbyUI] CreationUI missing Buttons frame.") end

	local btnCancel = buttonsFrame and buttonsFrame:FindFirstChild("Cancel")
	local btnCreate = buttonsFrame and buttonsFrame:FindFirstChild("Create")
	local scrollFrame = creationUI:FindFirstChild("Scroll")

	local resortNameNode = scrollFrame and scrollFrame:FindFirstChild("Resort Name")
	local latNode        = scrollFrame and scrollFrame:FindFirstChild("Latitude (Optional)")
	local longNode       = scrollFrame and scrollFrame:FindFirstChild("Longitude (Optional)")
	local nameInput = resortNameNode and resortNameNode:FindFirstChild("Input")
	local latInput  = latNode  and latNode:FindFirstChild("Input")
	local longInput = longNode and longNode:FindFirstChild("Input")

	local storage = playerGui:FindFirstChild("Storage")
	local tooltipTemplate = storage and storage:FindFirstChild("Tooltip")
	local tooltipFrame = creationUI:FindFirstChild("Tooltip")
	if not tooltipFrame then
		if tooltipTemplate then
			tooltipFrame = tooltipTemplate:Clone()
			tooltipFrame.Name = "Tooltip"
			tooltipFrame.Visible = false
			tooltipFrame.Parent = creationUI
		else
			warn("[LobbyUI] PlayerGui.Storage.Tooltip not found.")
		end
	end

	local settingsFrame = scrollFrame and scrollFrame:FindFirstChild("Settings")
	local function findNode(name)
		return (settingsFrame and settingsFrame:FindFirstChild(name)) or (scrollFrame and scrollFrame:FindFirstChild(name))
	end

	local densityNode = findNode("TreeDensity") or findNode("DenseTrees")
	local elevNode    = findNode("ElevationFalloff")
	local sandboxNode = findNode("Sandbox") or findNode("RealisticMode")

	local templateNode = densityNode or sandboxNode or elevNode
	local mapScaleNode, mapScaleInput = ensureMapScaleNode(settingsFrame, templateNode)
	local mapScaleModeNode, mapScaleModeBtn = ensureMapScaleModeNode(settingsFrame, templateNode or mapScaleNode)

	if mapScaleNode     then mapScaleNode.LayoutOrder     = 2; attachTooltip(mapScaleNode,     tooltipFrame, TOOLTIPS.MapScale[1],     TOOLTIPS.MapScale[2]) end
	if mapScaleModeNode then mapScaleModeNode.LayoutOrder = 3; attachTooltip(mapScaleModeNode, tooltipFrame, TOOLTIPS.MapScaleMode[1], TOOLTIPS.MapScaleMode[2]) end
	if mapScaleInput then
		mapScaleInput.Text = formatMapScaleText(mapScaleValue)
		mapScaleInput.FocusLost:Connect(function() applyMapScaleInput(mapScaleInput) end)
	end
	if mapScaleModeBtn then
		mapScaleModeBtn.Text = getMapScaleModeOption().Label
		mapScaleModeBtn.Activated:Connect(function()
			mapScaleModeIndex = (mapScaleModeIndex % #MAP_SCALE_MODE_OPTIONS) + 1
			mapScaleModeBtn.Text = getMapScaleModeOption().Label
		end)
	end
	if sandboxNode then sandboxNode.LayoutOrder = math.max(sandboxNode.LayoutOrder, 4) end
	if elevNode    then elevNode.LayoutOrder    = math.max(elevNode.LayoutOrder, 5) end

	local advancedToggleBtn = buildAdvancedToggle(scrollFrame, settingsFrame)
	advancedExpanded = false
	applyAdvancedVisibility(settingsFrame, advancedToggleBtn, scrollFrame)

	refreshCreationLayout(scrollFrame)

	local function resolveBtn(node, name)
		if not node then return nil end
		local frame = node:FindFirstChild(name or "Button")
		if not frame then return nil end
		return frame:FindFirstChild("Text")
	end

	local function setBtnColor(btn, color)
		if not btn then return end
		btn.BackgroundColor3 = color
		btn.Font = Enum.Font.GothamBold
		btn.TextColor3 = color == COLORS.ToggleOn and Color3.fromRGB(20, 60, 35) or Color3.fromRGB(255, 255, 255)
		local t = btn.Text
		if t ~= "ON" and t ~= "OFF" and #t > 0 then
			btn.Text = t:sub(1,1):upper() .. t:sub(2):lower()
		end
		local wrapper = btn.Parent
		if wrapper and (wrapper:IsA("ImageLabel") or wrapper:IsA("ImageButton")) and wrapper.Name == "Button" then
			wrapper.ImageColor3 = color
		end
	end

	if mapScaleModeBtn then setBtnColor(mapScaleModeBtn, COLORS.BtnOther) end

	local densityBtn = resolveBtn(densityNode)
	if densityBtn then
		setBtnColor(densityBtn, COLORS.BtnOther)
		densityBtn.Text = DENSITY_OPTIONS[densityIndex]
		densityBtn.Activated:Connect(function()
			densityIndex = (densityIndex % #DENSITY_OPTIONS) + 1
			densityBtn.Text = DENSITY_OPTIONS[densityIndex]
		end)
		attachTooltip(densityNode or densityBtn, tooltipFrame, TOOLTIPS.TreeDensity[1], TOOLTIPS.TreeDensity[2])
	end

	local elevBtn = resolveBtn(elevNode)
	if elevBtn then
		setBtnColor(elevBtn, COLORS.ToggleOn)
		elevBtn.Text = "ON"
		elevBtn.Activated:Connect(function()
			elevationFalloffEnabled = not elevationFalloffEnabled
			elevBtn.Text = elevationFalloffEnabled and "ON" or "OFF"
			setBtnColor(elevBtn, elevationFalloffEnabled and COLORS.ToggleOn or COLORS.ToggleOff)
		end)
		attachTooltip(elevNode or elevBtn, tooltipFrame, TOOLTIPS.ElevFalloff[1], TOOLTIPS.ElevFalloff[2])
	end

	local sandboxBtn = resolveBtn(sandboxNode)
	if sandboxBtn then
		sandboxBtn.Active = true
		sandboxBtn.AutoButtonColor = true
		setBtnColor(sandboxBtn, COLORS.ToggleOff)
		sandboxBtn.Activated:Connect(function()
			if ownsSandboxPass then
				sandboxModeEnabled = not sandboxModeEnabled
				sandboxBtn.Text = sandboxModeEnabled and "ON" or "OFF"
				setBtnColor(sandboxBtn, sandboxModeEnabled and COLORS.ToggleOn or COLORS.ToggleOff)
			else
				print("[LobbyUI] Sandbox button clicked. Prompting purchase.")
				MarketplaceService:PromptGamePassPurchase(player, SANDBOX_GAMEPASS_ID)
			end
		end)
		attachTooltip(sandboxNode or sandboxBtn, tooltipFrame, TOOLTIPS.Sandbox[1], TOOLTIPS.Sandbox[2])
	end

	if latNode  then attachTooltip(latNode,  tooltipFrame, TOOLTIPS.LatLong[1], TOOLTIPS.LatLong[2]) end
	if longNode then attachTooltip(longNode, tooltipFrame, TOOLTIPS.LatLong[1], TOOLTIPS.LatLong[2]) end

	local function resetCreationForm()
		if elevBtn    then elevBtn.Text = "ON"; setBtnColor(elevBtn, COLORS.ToggleOn) end
		if sandboxBtn and ownsSandboxPass then sandboxBtn.Text = "OFF"; setBtnColor(sandboxBtn, COLORS.ToggleOff) end
		if densityBtn then densityIndex = 4; densityBtn.Text = DENSITY_OPTIONS[densityIndex] end
		mapScaleValue = 1; mapScaleModeIndex = 1
		if mapScaleInput   then mapScaleInput.Text   = formatMapScaleText(mapScaleValue) end
		if mapScaleModeBtn then mapScaleModeBtn.Text = getMapScaleModeOption().Label end
		elevationFalloffEnabled = true
		sandboxModeEnabled = false
		advancedExpanded = false
		applyAdvancedVisibility(settingsFrame, advancedToggleBtn, scrollFrame)
	end

	if btnCancel then
		bindGuiButton(btnCancel, function()
			print("[LobbyUI] Creation cancelled by user.")
			logCustomEvent("creation_cancel")
			activeSlotForCreation = nil
			hideCreationUI(resetCreationForm)
		end)
	end

	if btnCreate then
		bindGuiButton(btnCreate, function()
			if createRequestInProgress then return end
			logStep("create_clicked")
			local targetSlot = activeSlotForCreation
			if not targetSlot then
				warn("[LobbyUI] Attempted to create slot but activeSlotForCreation is nil.")
				return
			end
			print("[LobbyUI] Create button clicked for slot " .. tostring(targetSlot))

			local parsedLat  = parseCoordinateInput(latInput  and latInput.Text  or "", "Latitude")
			local parsedLong = parseCoordinateInput(longInput and longInput.Text or "", "Longitude", parsedLat)
			local finalName, resolvedLat, resolvedLong, fallbackPreset = resolveCreationDefaults(targetSlot, nameInput and nameInput.Text or nil, parsedLat, parsedLong)
			applyMapScaleInput(mapScaleInput)

			if fallbackPreset then
				print(string.format("[LobbyUI] Using fallback resort preset '%s' for slot %s (%.4f, %.4f).", fallbackPreset.Name, tostring(targetSlot), resolvedLat, resolvedLong))
			end

			local settingsData = {
				Name      = finalName,
				Latitude  = resolvedLat,
				Longitude = resolvedLong,
				Settings  = {
					TreeDensity      = DENSITY_VALUES[densityIndex],
					TreeStyle        = "Regular",
					ElevationFalloff = elevationFalloffEnabled,
					SandboxMode      = sandboxModeEnabled,
					MapScale         = mapScaleValue,
					MapScaleMode     = getMapScaleModeOption().Value,
					Latitude         = resolvedLat,
					Longitude        = resolvedLong,
				}
			}

			createRequestInProgress = true
			local originalText = btnCreate.Text
			btnCreate.Text = "Creating..."
			btnCreate.Active = false
			btnCreate.AutoButtonColor = false
			if loadingUI then
				loadingUI.Visible = true
				local textLabel = loadingUI:FindFirstChildWhichIsA("TextLabel", true)
				if textLabel then textLabel.Text = "Creating world..." end
			end
			RunService.Heartbeat:Wait()

			local result = invokeSlotRequestWithRetry("Create", targetSlot, settingsData)

			if result and result.Success then
				print("[LobbyUI] Successfully created new slot " .. tostring(targetSlot))
				logStep("world_created")

				if nameInput then nameInput.Text = "" end
				if latInput  then latInput.Text  = "" end
				if longInput then longInput.Text  = "" end

				activeSlotForCreation = nil
				hideCreationUI(function()
					local targetCard = slotsFrame and deepFind(slotsFrame, "Slot" .. tostring(targetSlot))
					if targetCard then setCardLoadingState(targetCard) end
					resetCreationForm()
				end)

				logStep("world_joined")
				logStep("teleport_started")
				btnCreate.Text = "Teleporting..."
				if loadingUI then
					loadingUI.Visible = true
					local textLabel = loadingUI:FindFirstChildWhichIsA("TextLabel", true)
					if textLabel then textLabel.Text = "Preparing world..." end
				end
				RunService.Heartbeat:Wait()
				-- FIX: wrapped in pcall to avoid unhandled errors on teleport failure
				local tpOk, tpResult = pcall(function()
					return TeleportToSlot:InvokeServer(targetSlot)
				end)
				if not tpOk or not (tpResult and tpResult.Success) then
					warn("[LobbyUI] Auto-teleport failed for slot " .. tostring(targetSlot) .. (not tpOk and (" | " .. tostring(tpResult)) or ""))
					btnCreate.Text = originalText
					btnCreate.Active = true
					btnCreate.AutoButtonColor = true
					createRequestInProgress = false
					if loadingUI then loadingUI.Visible = false end
					refreshUI(false)
				end
			else
				warn("[LobbyUI] Failed to create new slot: " .. tostring(result and result.Error))
				btnCreate.Text = originalText
				btnCreate.Active = true
				btnCreate.AutoButtonColor = true
				createRequestInProgress = false
				if loadingUI then loadingUI.Visible = false end
			end
		end)
	end
end

-- // CONFIRM PANEL //
local confirmPanel   = background and background:FindFirstChild("Confirm")
local confirmButtons = confirmPanel and (confirmPanel:FindFirstChild("Buttons") or confirmPanel)
local confirmYesBtn  = confirmButtons and confirmButtons:FindFirstChild("Yes")
local confirmNoBtn   = confirmButtons and confirmButtons:FindFirstChild("No")
local confirmYesConn = nil
local confirmNoConn  = nil
local confirmBackdropConn = nil
local touchConfirmModal = nil
local touchConfirmYesConn = nil
local touchConfirmNoConn = nil
local touchConfirmBackdropConn = nil

local function ensureTouchConfirmModal()
	if not gui then return nil end
	local existing = gui:FindFirstChild("TouchConfirmModal")
	if existing and existing:IsA("Frame") then
		touchConfirmModal = existing
		return existing
	end

	local modal = Instance.new("Frame")
	modal.Name = "TouchConfirmModal"
	modal.BackgroundTransparency = 1
	modal.Size = UDim2.fromScale(1, 1)
	modal.Position = UDim2.fromScale(0, 0)
	modal.Visible = false
	modal.ZIndex = 200
	modal.Parent = gui

	local backdrop = Instance.new("TextButton")
	backdrop.Name = "Backdrop"
	backdrop.BackgroundColor3 = Color3.new(0, 0, 0)
	backdrop.BackgroundTransparency = 0.3
	backdrop.BorderSizePixel = 0
	backdrop.Text = ""
	backdrop.AutoButtonColor = false
	backdrop.Size = UDim2.fromScale(1, 1)
	backdrop.Position = UDim2.fromScale(0, 0)
	backdrop.ZIndex = 200
	backdrop.Parent = modal

	local card = Instance.new("Frame")
	card.Name = "Card"
	card.AnchorPoint = Vector2.new(0.5, 0.5)
	card.Position = UDim2.fromScale(0.5, 0.5)
	card.Size = UDim2.fromScale(0.86, 0.34)
	card.BackgroundColor3 = Color3.fromRGB(13, 15, 19)
	card.BorderSizePixel = 0
	card.ZIndex = 201
	card.Parent = modal
	local cardCorner = Instance.new("UICorner")
	cardCorner.CornerRadius = UDim.new(0, 16)
	cardCorner.Parent = card

	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.fromRGB(255, 21, 83)
	stroke.Thickness = 2
	stroke.Transparency = 0.15
	stroke.Parent = card

	local title = Instance.new("TextLabel")
	title.Name = "Title"
	title.BackgroundTransparency = 1
	title.Size = UDim2.fromScale(0.88, 0.18)
	title.Position = UDim2.fromScale(0.06, 0.08)
	title.Font = Enum.Font.GothamBold
	title.TextColor3 = Color3.fromRGB(255, 255, 255)
	title.TextScaled = true
	title.TextWrapped = true
	title.ZIndex = 202
	title.Parent = card

	local body = Instance.new("TextLabel")
	body.Name = "Body"
	body.BackgroundTransparency = 1
	body.Size = UDim2.fromScale(0.88, 0.38)
	body.Position = UDim2.fromScale(0.06, 0.28)
	body.Font = Enum.Font.Gotham
	body.TextColor3 = Color3.fromRGB(230, 235, 245)
	body.TextScaled = true
	body.TextWrapped = true
	body.RichText = true
	body.ZIndex = 202
	body.Parent = card

	local buttons = Instance.new("Frame")
	buttons.Name = "Buttons"
	buttons.BackgroundTransparency = 1
	buttons.Size = UDim2.fromScale(0.88, 0.18)
	buttons.Position = UDim2.fromScale(0.06, 0.76)
	buttons.ZIndex = 202
	buttons.Parent = card

	local list = Instance.new("UIListLayout")
	list.FillDirection = Enum.FillDirection.Horizontal
	list.HorizontalAlignment = Enum.HorizontalAlignment.Center
	list.VerticalAlignment = Enum.VerticalAlignment.Center
	list.Padding = UDim.new(0.04, 0)
	list.Parent = buttons

	local function makeButton(name, text, color)
		local btn = Instance.new("TextButton")
		btn.Name = name
		btn.Size = UDim2.fromScale(0.46, 1)
		btn.BackgroundColor3 = color
		btn.BorderSizePixel = 0
		btn.Font = Enum.Font.GothamBold
		btn.Text = text
		btn.TextColor3 = Color3.fromRGB(255, 255, 255)
		btn.TextScaled = true
		btn.AutoButtonColor = true
		btn.ZIndex = 202
		btn.Parent = buttons
		local btnCorner = Instance.new("UICorner")
		btnCorner.CornerRadius = UDim.new(0, 12)
		btnCorner.Parent = btn
		return btn
	end

	makeButton("Cancel", "CANCEL", Color3.fromRGB(34, 38, 44))
	makeButton("Delete", "DELETE", Color3.fromRGB(255, 21, 83))

	touchConfirmModal = modal
	return modal
end

local function ensureConfirmBackdrop()
	if not background then return nil end
	local backdrop = background:FindFirstChild("ConfirmBackdrop")
	if backdrop and not backdrop:IsA("TextButton") then
		backdrop:Destroy()
		backdrop = nil
	end
	if not backdrop then
		backdrop = Instance.new("TextButton")
		backdrop.Name = "ConfirmBackdrop"
		backdrop.BackgroundColor3 = Color3.new(0, 0, 0)
		backdrop.BackgroundTransparency = 0.35
		backdrop.BorderSizePixel = 0
		backdrop.Text = ""
		backdrop.AutoButtonColor = false
		backdrop.Visible = false
		backdrop.Size = UDim2.fromScale(1, 1)
		backdrop.Position = UDim2.fromScale(0, 0)
		backdrop.ZIndex = 49
		backdrop.Parent = background
	end
	backdrop.Active = true
	backdrop.Selectable = true
	return backdrop
end

local function forceGuiObjectModal(guiObject, zIndex)
	if not guiObject or not guiObject:IsA("GuiObject") then return end
	guiObject.ZIndex = math.max(guiObject.ZIndex or 1, zIndex)
	guiObject.Visible = true
	if guiObject:IsA("CanvasGroup") then
		guiObject.GroupTransparency = 0
		guiObject.Active = true
		guiObject.Interactable = true
	else
		guiObject.Active = true
	end
	for _, child in ipairs(guiObject:GetDescendants()) do
		if child:IsA("GuiObject") then
			child.ZIndex = math.max(child.ZIndex or 1, zIndex + 1)
			child.Visible = true
			child.Active = child:IsA("GuiButton") or child.Active
		end
		if child:IsA("CanvasGroup") then
			child.GroupTransparency = 0
			child.Interactable = true
		end
		if child:IsA("TextButton") or child:IsA("ImageButton") then
			child.Selectable = true
			child.AutoButtonColor = true
		end
	end
	guiObject.Parent = guiObject.Parent
end

local function showConfirm(slotName, onYes)
	if UserInputService.TouchEnabled then
		local modal = ensureTouchConfirmModal()
		if not modal then return end
		if touchConfirmYesConn then touchConfirmYesConn:Disconnect(); touchConfirmYesConn = nil end
		if touchConfirmNoConn then touchConfirmNoConn:Disconnect(); touchConfirmNoConn = nil end
		if touchConfirmBackdropConn then touchConfirmBackdropConn:Disconnect(); touchConfirmBackdropConn = nil end
		local card = modal:FindFirstChild("Card")
		local titleLbl = card and card:FindFirstChild("Title")
		local bodyLbl = card and card:FindFirstChild("Body")
		local buttons = card and card:FindFirstChild("Buttons")
		local cancelBtn = buttons and buttons:FindFirstChild("Cancel")
		local deleteBtn = buttons and buttons:FindFirstChild("Delete")
		local backdrop = modal:FindFirstChild("Backdrop")
		if titleLbl then titleLbl.Text = 'Delete "' .. tostring(slotName) .. '"?' end
		if bodyLbl then
			bodyLbl.Text = "<font color=\"#FF1044\"><b>This can NOT be undone.</b></font>\nYour resort, guests, and all progress will be gone forever.\n<b>Seriously make sure you mean it.</b>"
		end
		local fired = false
		local function dismiss()
			modal.Visible = false
			if touchConfirmYesConn then touchConfirmYesConn:Disconnect(); touchConfirmYesConn = nil end
			if touchConfirmNoConn then touchConfirmNoConn:Disconnect(); touchConfirmNoConn = nil end
			if touchConfirmBackdropConn then touchConfirmBackdropConn:Disconnect(); touchConfirmBackdropConn = nil end
		end
		if deleteBtn then
			touchConfirmYesConn = deleteBtn.Activated:Connect(function()
				if fired then return end
				fired = true
				dismiss()
				onYes()
			end)
		end
		if cancelBtn then
			touchConfirmNoConn = cancelBtn.Activated:Connect(function()
				dismiss()
			end)
		end
		if backdrop then
			touchConfirmBackdropConn = backdrop.Activated:Connect(function()
				if fired then return end
				dismiss()
			end)
		end
		modal.Visible = true
		return
	end

	if not confirmPanel then return end
	if confirmYesConn then confirmYesConn:Disconnect(); confirmYesConn = nil end
	if confirmNoConn  then confirmNoConn:Disconnect();  confirmNoConn  = nil end
	forceGuiObjectModal(confirmPanel, 50)
	local titleLbl = confirmPanel:FindFirstChild("Title") or confirmPanel:FindFirstChildWhichIsA("TextLabel")
	if titleLbl then titleLbl.Text = 'Delete "' .. tostring(slotName) .. '"?' end
	local mainText = confirmPanel:FindFirstChild("MainText")
	if mainText then
		mainText.Text = "<font color=\"#FF1044\"><b>This can NOT be undone.</b></font>\nYour resort, guests, and all progress will be gone forever.\n<b>Seriously make sure you mean it.</b>"
	end
	local fired = false
	local function dismiss()
		confirmPanel.Visible = false
		local backdrop = ensureConfirmBackdrop()
		if backdrop then backdrop.Visible = false end
		if confirmYesConn then confirmYesConn:Disconnect(); confirmYesConn = nil end
		if confirmNoConn  then confirmNoConn:Disconnect();  confirmNoConn  = nil end
		if confirmBackdropConn then confirmBackdropConn:Disconnect(); confirmBackdropConn = nil end
	end
	if confirmYesBtn then
		confirmYesConn = confirmYesBtn.Activated:Connect(function()
			if fired then return end; fired = true; dismiss(); onYes()
		end)
	end
	if confirmNoBtn then
		confirmNoConn = confirmNoBtn.Activated:Connect(function() dismiss() end)
	end
	local backdrop = ensureConfirmBackdrop()
	if backdrop then
		backdrop.Visible = true
		backdrop.ZIndex = 49
		if confirmBackdropConn then confirmBackdropConn:Disconnect(); confirmBackdropConn = nil end
		confirmBackdropConn = backdrop.Activated:Connect(function()
			if fired then return end
			dismiss()
		end)
	end
	confirmPanel.Size = UDim2.fromScale(0.55, 0.55)
	confirmPanel.Position = UDim2.fromScale(0.5, 0.5)
	confirmPanel.AnchorPoint = Vector2.new(0.5, 0.5)
	confirmPanel.Visible = true
end

local PULSE_SPEED  = 1.4
local BASE_ROTATE  = 25
local EXTRA_ROTATE = 55

local function bindHoverTransparency(imageLabel)
	if not imageLabel or not imageLabel:IsA("ImageLabel") then return end
	local button   = imageLabel:FindFirstChild("Text")
	local stroke   = button and button:FindFirstChildWhichIsA("UIStroke")
	local gradient = stroke and stroke:FindFirstChildWhichIsA("UIGradient")
	if not stroke or not gradient then warn("Missing UIStroke/UIGradient on", imageLabel:GetFullName()) return end

	local strokeContextual, gradientContextual
	if not imageLabel:FindFirstChild("Delete") then
		strokeContextual = stroke:Clone()
		strokeContextual.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual
		strokeContextual.Parent = button
		gradientContextual = strokeContextual:FindFirstChildWhichIsA("UIGradient")
	end

	local base = imageLabel.ImageTransparency
	local hovered, hoverP, pulseT, angle = false, 0, 0, 0

	RunService.Heartbeat:Connect(function(dt)
		hoverP = math.clamp(hoverP + dt * (hovered and 1/0.35 or -1/0.25), 0, 1)
		pulseT = pulseT + dt * PULSE_SPEED * hoverP
		local pulse = math.sin(pulseT * math.pi * 2) * 0.5 + 0.5
		angle = (angle + dt * (BASE_ROTATE + EXTRA_ROTATE * pulse * hoverP)) % 360
		imageLabel.ImageTransparency = math.clamp(base - hoverP * (0.1 + pulse * 0.3), 0, 1)
		stroke.Thickness = 0.07 * hoverP
		gradient.Rotation = angle
		if strokeContextual then
			strokeContextual.Thickness = 0.04 * hoverP
			if gradientContextual then gradientContextual.Rotation = angle end
		end
	end)

	-- Only wire mouse hover on non-touch devices; touch has no hover concept
	if not UserInputService.TouchEnabled then
		button.MouseEnter:Connect(function() hovered = true end)
		button.MouseLeave:Connect(function() hovered = false end)
	end
end

-- FIX: ensureTouchHitTarget is no longer used for delFrame.
-- Kept only for play and new frames, which don't have GuiState visual requirements.
local function ensureTouchHitTarget(parent, name, callback)
	if not UserInputService.TouchEnabled or not parent then return nil end

	-- FIX: destroy any stale touch target that may exist from a previous version
	local existing = parent:FindFirstChild(name)
	if existing then
		existing:Destroy()
		existing = nil
	end

	local target = Instance.new("TextButton")
	target.Name = name
	target.BackgroundTransparency = 1
	target.Text = ""
	target.AutoButtonColor = false
	target.BorderSizePixel = 0
	target.Size = UDim2.fromScale(1, 1)
	target.Position = UDim2.fromScale(0.5, 0.5)
	target.AnchorPoint = Vector2.new(0.5, 0.5)
	target.ZIndex = (parent.ZIndex or 1) + 1
	target.Parent = parent

	target.Active = true
	target.Selectable = true
	if callback then
		bindGuiButton(target, callback)
	end
	return target
end

local function setupSlotCard(slotNum)
	local card = deepFind(slotsFrame, "Slot"..slotNum)
	if not card then warn("[LobbyUI] Slot card " .. slotNum .. " not found.") return end

	local nameLbl   = deepFind(card, "Name")
	local delFrame  = deepFind(card, "Delete")
	local playFrame = deepFind(card, "Play")
	local newFrame  = deepFind(card, "New")
	local delBtn  = delFrame  and delFrame:FindFirstChild("Text")
	local playBtn = playFrame and playFrame:FindFirstChild("Text")
	local newBtn  = newFrame  and newFrame:FindFirstChild("Text")

	-- FIX: clean up any stale TouchDeleteTarget overlays from prior versions
	-- that would block delBtn from receiving touch and updating GuiState
	local staleDelTarget = delFrame and delFrame:FindFirstChild("TouchDeleteTarget")
	if staleDelTarget then staleDelTarget:Destroy() end

	bindHoverTransparency(delFrame)
	bindHoverTransparency(playFrame)
	bindHoverTransparency(newFrame)

	if nameLbl then
		local renameIcon = nameLbl:FindFirstChildWhichIsA("ImageLabel")
		if renameIcon then
			renameIcon.Image = RENAME_ICON_IDLE
			local isEditing = false

			local function commitRename(textBox)
				if not isEditing then return end
				isEditing = false
				local raw = textBox.Text:match("^%s*(.-)%s*$")
				local newName = (raw ~= "") and raw or (nameLbl:GetAttribute("OriginalName") or nameLbl.Text)
				textBox:Destroy()
				nameLbl.Visible = true
				renameIcon.Image = RENAME_ICON_IDLE
				local originalName = nameLbl:GetAttribute("OriginalName") or ""
				if newName ~= originalName then
					print("[LobbyUI] Renaming slot " .. slotNum .. " to: " .. newName)
					nameLbl.Text = newName
					local ok, result = pcall(function()
						return SlotRequest:InvokeServer("Rename", slotNum, newName)
					end)
					if not ok or not (result and result.Success) then
						warn("[LobbyUI] Rename failed for slot " .. slotNum .. ". Reverting.")
						nameLbl.Text = originalName
					else
						nameLbl:SetAttribute("OriginalName", newName)
					end
				end
			end

			local function beginRename()
				-- FIX: guard against rename while card is still loading
				if card:GetAttribute("SlotState") == "Loading" then return end
				local origName = nameLbl:GetAttribute("OriginalName")
				print("[LobbyUI] Rename icon clicked for slot " .. slotNum .. " | OriginalName=" .. tostring(origName) .. " | isEditing=" .. tostring(isEditing))
				if not origName or isEditing then return end
				isEditing = true
				renameIcon.Image = RENAME_ICON_EDITING
				local textBox = Instance.new("TextBox")
				textBox.Name = "RenameInput"
				textBox.Size = nameLbl.Size
				textBox.Position = nameLbl.Position
				textBox.AnchorPoint = nameLbl.AnchorPoint
				textBox.BackgroundColor3 = Color3.fromRGB(28, 32, 42)
				textBox.BorderSizePixel = 0
				textBox.ClearTextOnFocus = false
				textBox.Font = nameLbl.Font
				textBox.TextColor3 = nameLbl.TextColor3
				textBox.TextSize = nameLbl.TextSize
				textBox.TextXAlignment = nameLbl.TextXAlignment
				textBox.PlaceholderText = nameLbl:GetAttribute("OriginalName") or nameLbl.Text
				textBox.Text = nameLbl:GetAttribute("OriginalName") or nameLbl.Text
				textBox.ZIndex = nameLbl.ZIndex + 1
				local corner = Instance.new("UICorner")
				corner.CornerRadius = UDim.new(0, 4)
				corner.Parent = textBox
				textBox.Parent = nameLbl.Parent
				nameLbl.Visible = false
				textBox.FocusLost:Connect(function() commitRename(textBox) end)
				textBox:CaptureFocus()
			end

			renameIcon.Activated:Connect(beginRename)
		end
	end

	local function requestDelete()
		if card:GetAttribute("SlotState") == "Loading" then return end
		print("[LobbyUI] Delete button clicked for slot " .. slotNum)
		logCustomEvent("slot_delete_click")
		local slotName = nameLbl and (nameLbl:GetAttribute("OriginalName") or nameLbl.Text) or ("Slot " .. slotNum)
		showConfirm(slotName, function()
			print("[LobbyUI] Confirmed delete for slot " .. slotNum)
			local DISABLED_COLOR = COLORS.BtnOther
			local baseDelTrans   = delFrame  and delFrame.ImageTransparency  or 0
			local basePlayTrans  = playFrame and playFrame.ImageTransparency or 0
			local baseDelColor   = delBtn  and delBtn.BackgroundColor3  or nil
			local basePlayColor  = playBtn and playBtn.BackgroundColor3 or nil
			local infoLbl = deepFind(card, "Info")
			card.BackgroundTransparency = 0.6
			if nameLbl  then nameLbl.TextTransparency  = 0.5 end
			if infoLbl  then infoLbl.TextTransparency  = 0.5 end
			if delFrame  then delFrame.ImageTransparency  = 1 end
			if playFrame then playFrame.ImageTransparency = 1 end
			if delBtn  then delBtn.BackgroundColor3  = DISABLED_COLOR; delBtn.Active  = false; delBtn.AutoButtonColor  = false end
			if playBtn then playBtn.BackgroundColor3 = DISABLED_COLOR; playBtn.Active = false; playBtn.AutoButtonColor = false end
			card:SetAttribute("SlotState", "Loading")

			-- FIX: use retry wrapper for consistency (was a bare InvokeServer call)
			local result = invokeSlotRequestWithRetry("Delete", slotNum)

			if not (result and result.Success) then
				warn("[LobbyUI] Delete request failed for slot " .. slotNum)
				card:SetAttribute("SlotState", "Loaded")
				card.BackgroundTransparency = 0
				if nameLbl then nameLbl.TextTransparency = 0 end
				if infoLbl  then infoLbl.TextTransparency  = 0 end
				if delFrame  then delFrame.ImageTransparency  = baseDelTrans end
				if playFrame then playFrame.ImageTransparency = basePlayTrans end
				if delBtn  and baseDelColor  then delBtn.BackgroundColor3  = baseDelColor;  delBtn.Active  = true; delBtn.AutoButtonColor  = true end
				if playBtn and basePlayColor then playBtn.BackgroundColor3 = basePlayColor; playBtn.Active = true; playBtn.AutoButtonColor = true end
			else
				print("[LobbyUI] Delete request successful for slot " .. slotNum)
				refreshUI(false)
			end
		end)
	end

	local function doPlay()
		if card:GetAttribute("SlotState") == "Loading" then return end
		print("[LobbyUI] Play button clicked for slot " .. slotNum)
		logCustomEvent("slot_play_click")
		logStep("teleport_started")
		-- FIX: wrapped in pcall to prevent unhandled remote errors
		local ok, result = pcall(function()
			return TeleportToSlot:InvokeServer(slotNum)
		end)
		if not ok or not result then
			warn("[LobbyUI] Teleport failed for slot " .. slotNum .. (not ok and (" | " .. tostring(result)) or ""))
		end
	end

	local function doNew()
		if card:GetAttribute("SlotState") == "Loading" then return end
		if slotNum <= 6 and slotNum > 3 and not ownsExtraSlots then
			print("[LobbyUI] Unlock button clicked for slot " .. slotNum .. ". Prompting purchase.")
			logCustomEvent("slot_unlock_prompt")
			MarketplaceService:PromptGamePassPurchase(player, SLOT_UNLOCK_PASS_ID)
			return
		end
		print("[LobbyUI] New button clicked for slot " .. slotNum .. ". Opening CreationUI.")
		logStep("new_slot_clicked")
		logStep("creation_frame_opened")
		activeSlotForCreation = slotNum
		if creationUI then
			local currentSlotNumObj = creationUI:FindFirstChild("CurrentSlotNum")
			if currentSlotNumObj and currentSlotNumObj:IsA("ValueBase") then
				currentSlotNumObj.Value = slotNum
			end
			local scrollFrame = creationUI:FindFirstChild("Scroll")
			showCreationUI()
			refreshCreationLayout(scrollFrame)
		else
			warn("[LobbyUI] Cannot open CreationUI; frame is missing.")
		end
	end

	-- FIX: No touch hit target for delete. delBtn is a real TextButton and
	-- handles touch natively. A hit target overlay was blocking GuiState
	-- updates and causing the play button to fire on the same tap.
	-- Only play and new get touch targets (they have no GuiState requirement).
	ensureTouchHitTarget(playFrame, "TouchPlayTarget", doPlay)
	ensureTouchHitTarget(newFrame,  "TouchNewTarget",  doNew)

	-- Wire the real buttons for PC (and as the authoritative touch handler for delete)
	if delBtn  then bindGuiButton(delBtn,  requestDelete) end
	if playBtn then bindGuiButton(playBtn, doPlay) end
	if newBtn  then bindGuiButton(newBtn,  doNew) end
end

if TeleportStatus then
	TeleportStatus.OnClientEvent:Connect(function(statusType, message)
		print("[LobbyUI] Teleport Status [" .. tostring(statusType) .. "]: " .. tostring(message))
		if slotsFrame then slotsFrame.Visible = false end
		if creationUI then creationUI.Visible = false end
		if loadingUI then
			loadingUI.Visible = true
			local textLabel = loadingUI:FindFirstChildWhichIsA("TextLabel", true)
			if textLabel then textLabel.Text = message end
			if statusType == "Error" then
				createRequestInProgress = false
				task.delay(3, function()
					loadingUI.Visible = false
					if slotsFrame then slotsFrame.Visible = true end
					refreshUI(true)
				end)
			end
		else
			warn("[LobbyUI] TeleportScreen UI frame not found to display message: " .. tostring(message))
		end
	end)
end

SlotUpdate.OnClientEvent:Connect(function()
	print("[LobbyUI] SlotUpdate event received from server.")
	isRefreshing = false
	refreshUI(false)
end)

MarketplaceService.PromptGamePassPurchaseFinished:Connect(function(purchasedPlayer, gamePassId, wasPurchased)
	if purchasedPlayer == player and wasPurchased then
		if gamePassId == SLOT_UNLOCK_PASS_ID or gamePassId == LEGACY_EXTRA_SLOTS_PASS_ID then
			print("[LobbyUI] Slot unlock entitlement purchased. Refreshing UI.")
			ownsExtraSlots = true
			logCustomEvent("slot_unlock_purchased")
			refreshUI(true)
		elseif gamePassId == SANDBOX_GAMEPASS_ID then
			print("[LobbyUI] Sandbox game pass purchased. Refreshing UI.")
			ownsSandboxPass = true
			logCustomEvent("sandbox_purchased")
			refreshUI(true)
		end
	end
end)

-- // INIT //
print("[LobbyUI] Initializing slot cards.")
if loadingUI    then loadingUI.Visible    = false end
if confirmPanel then confirmPanel.Visible = false end

if gui then
	generateMissingSlots()
	setupCreationUI()
	bindExistingTutorialUI()
	bindExistingJoinFriendUI()
	for i = 1, 9 do setupSlotCard(i) end
	setAllCardsLoadingState()
	task.spawn(function() refreshUI(false) end)
	task.spawn(function()
		if LobbyNoticePreference then
			local ok, result = pcall(function() return LobbyNoticePreference:InvokeServer("Get") end)
			if ok and type(result) == "table" then
				hideServiceNoticeForever = result.HideServiceNotice == true
			end
		end
		task.delay(0.35, showServiceNotice)
	end)
else
	warn("[LobbyUI] Failed to initialize: SlotSelectionGui not found.")
end

print("[LobbyUI] V3.9 Loaded - Mobile delete fixed, all patches applied.")