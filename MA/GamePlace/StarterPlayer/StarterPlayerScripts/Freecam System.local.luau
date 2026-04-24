--[[
    SKI RESORT CINEMATIC FREECAM (CLIENT) - ULTIMATE EDITION [SECURE LOCK]
    -------------------------------------------------
    LOCATION: Put this in StarterPlayer -> StarterPlayerScripts
    
    CHANGE LOG:
    - Added 'secureCallback' wrapper. Even if UI is clicked, settings WILL NOT change without Gamepass.
    - Added 'TEST_MODE_FORCE_LOCK' for developer testing.
    - Added visual transparency to locked items.
    
    CONFIGURATION:
    1. Set 'GAMEPASS_ID' to your real Gamepass ID.
    2. Set 'TEST_MODE_FORCE_LOCK' to true if you want to see what it looks like for a non-buyer.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Lighting = game:GetService("Lighting")
local Workspace = game:GetService("Workspace")
local MarketplaceService = game:GetService("MarketplaceService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ok, EntitlementManager = pcall(function()
	return require(ReplicatedStorage:WaitForChild("EntitlementManager", 5))
end)
if not ok then
	EntitlementManager = { HasAccess = function() return false end }
end
local EntitlementEvents = ReplicatedStorage:FindFirstChild("EntitlementEvents")
local EntitlementChanged = EntitlementEvents and EntitlementEvents:FindFirstChild("EntitlementChanged")

local Player = Players.LocalPlayer
local Camera = Workspace.CurrentCamera

local Events = ReplicatedStorage:WaitForChild("Events", 10)
local ClosePanels = Events and Events:FindFirstChild("ClosePanels")
if Events and not ClosePanels then
	ClosePanels = Instance.new("BindableEvent")
	ClosePanels.Name = "ClosePanels"
	ClosePanels.Parent = Events
end

-- --- CONFIGURATION ---
local GAMEPASS_ID = 1705274438 -- REPLACE THIS WITH YOUR GAMEPASS ID
local TEST_MODE_FORCE_LOCK = false -- Set to TRUE to simulate NOT owning the gamepass

local SETTINGS = {
	NormalSpeed = 1.0,
	FastSpeedMultiplier = 3.0,
	SlowSpeedMultiplier = 0.2,
	Smoothness = 90, -- 0 to 100
	RotationSmoothness = 95, -- 0 to 100
	Sensitivity = 0.003,
	HideUiKey = Enum.KeyCode.H
}

local UI_THEME = {
	Background = Color3.fromRGB(20, 20, 25),
	Header = Color3.fromRGB(30, 30, 35),
	Accent = Color3.fromRGB(0, 170, 255),
	Locked = Color3.fromRGB(200, 50, 50), -- Red for locked
	Text = Color3.fromRGB(240, 240, 240),
	SubText = Color3.fromRGB(150, 150, 160),
	Button = Color3.fromRGB(50, 50, 60)
}

-- --- STATE ---
local isFreecamEnabled = false
local isUiVisible = true
local cameraPos = Camera.CFrame.Position
local currentCameraRot = Vector2.new(0, 0)
local targetCameraRot = Vector2.new(0, 0)
local cameraRoll = 0
local currentVel = Vector3.new(0, 0, 0)
local currentFOV = 70
local targetFOV = 70
local hasGamepass = false
local overrideClockTime = nil

-- Store original environment state to restore on exit
local storedState = {}
local lockTarget = nil       -- Vector3 world position to lock camera to
local lockEnabled = false    -- Whether lock-to-point is active

-- Effects Storage
local dofEffect = Lighting:FindFirstChildOfClass("DepthOfFieldEffect") or Instance.new("DepthOfFieldEffect", Lighting)
local colorEffect = Lighting:FindFirstChildOfClass("ColorCorrectionEffect") or Instance.new("ColorCorrectionEffect", Lighting)
local blurEffect = Lighting:FindFirstChildOfClass("BlurEffect") or Instance.new("BlurEffect", Lighting)
local sunRays = Lighting:FindFirstChildOfClass("SunRaysEffect") or Instance.new("SunRaysEffect", Lighting)
local atmosphere = Lighting:FindFirstChildOfClass("Atmosphere")

-- Initial Effect States
dofEffect.Enabled = false
blurEffect.Enabled = false
blurEffect.Size = 0

-- --- GAMEPASS CHECK ---
local function checkGamepass()
	if TEST_MODE_FORCE_LOCK then
		hasGamepass = false
		return
	end

	local success, result = pcall(function()
		return EntitlementManager.HasAccess(Player.UserId, GAMEPASS_ID)
	end)

	if success then
		hasGamepass = result
		if hasGamepass and game.CreatorId == Player.UserId and RunService:IsStudio() then
		end
	else
		hasGamepass = false
	end
end

checkGamepass()

-- Unlock on purchase
MarketplaceService.PromptGamePassPurchaseFinished:Connect(function(player, purchasedPassId, purchaseSuccess)
	if player == Player and purchasedPassId == GAMEPASS_ID and purchaseSuccess then
		checkGamepass()
	end
end)

if EntitlementChanged and EntitlementChanged:IsA("RemoteEvent") then
	EntitlementChanged.OnClientEvent:Connect(function(payload)
		if type(payload) ~= "table" or tonumber(payload.userId) ~= Player.UserId then
			return
		end
		checkGamepass()
	end)
end

-- --- UI GENERATION ---
local gui = Instance.new("ScreenGui")
gui.Name = "CinematicFreecamUI"
gui.ResetOnSpawn = false
gui.Enabled = false
gui.IgnoreGuiInset = true 
gui.Parent = Player:WaitForChild("PlayerGui")

local mainFrame = Instance.new("Frame")
mainFrame.Name = "ControlPanel"
mainFrame.Size = UDim2.new(0, 320, 0, 600)
mainFrame.AnchorPoint = Vector2.new(0, 0.5)
mainFrame.Position = UDim2.new(0, 20, 0.5, 0)
mainFrame.BackgroundColor3 = UI_THEME.Background
mainFrame.BorderSizePixel = 0
mainFrame.Visible = true
mainFrame.Parent = gui

Instance.new("UICorner", mainFrame).CornerRadius = UDim.new(0, 12)

-- Header
local header = Instance.new("Frame")
header.Size = UDim2.new(1, 0, 0, 50)
header.BackgroundColor3 = UI_THEME.Header
header.BorderSizePixel = 0
header.Parent = mainFrame
Instance.new("UICorner", header).CornerRadius = UDim.new(0, 12)

local title = Instance.new("TextLabel")
title.Text = "CINEMATIC PRO"
title.Font = Enum.Font.GothamBlack
title.TextSize = 20
title.TextColor3 = UI_THEME.Text
title.Size = UDim2.new(1, -20, 1, 0)
title.Position = UDim2.new(0, 15, 0, 0)
title.BackgroundTransparency = 1
title.TextXAlignment = Enum.TextXAlignment.Left
title.Parent = header

-- Hint Text
local hint = Instance.new("TextLabel")
hint.Text = "Press H to Hide UI"
hint.Font = Enum.Font.GothamBold
hint.TextSize = 10
hint.TextColor3 = UI_THEME.SubText
hint.Size = UDim2.new(0, 100, 1, 0)
hint.Position = UDim2.new(1, -110, 0, 0)
hint.BackgroundTransparency = 1
hint.TextXAlignment = Enum.TextXAlignment.Right
hint.Parent = header

-- Container
local container = Instance.new("ScrollingFrame")
container.Size = UDim2.new(1, 0, 1, -60)
container.Position = UDim2.new(0, 0, 0, 60)
container.BackgroundTransparency = 1
container.BorderSizePixel = 0
container.ScrollBarThickness = 4
container.AutomaticCanvasSize = Enum.AutomaticSize.Y
container.CanvasSize = UDim2.new(0, 0, 0, 0)
container.Parent = mainFrame

local layout = Instance.new("UIListLayout")
layout.Parent = container
layout.SortOrder = Enum.SortOrder.LayoutOrder
layout.Padding = UDim.new(0, 10)
layout.HorizontalAlignment = Enum.HorizontalAlignment.Center

local padding = Instance.new("UIPadding")
padding.Parent = container
padding.PaddingTop = UDim.new(0, 5)
padding.PaddingLeft = UDim.new(0, 10)
padding.PaddingRight = UDim.new(0, 10)
padding.PaddingBottom = UDim.new(0, 20)

-- --- UI COMPONENT FUNCTIONS ---

local function createSection(text, order)
	local label = Instance.new("TextLabel")
	label.Text = text
	label.Font = Enum.Font.GothamBlack
	label.TextColor3 = UI_THEME.Accent
	label.TextSize = 12
	label.Size = UDim2.new(1, 0, 0, 25)
	label.BackgroundTransparency = 1
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.LayoutOrder = order
	label.Parent = container
end

local function createSlider(name, minVal, maxVal, defaultVal, callback, order, isPremium)
	local frame = Instance.new("Frame")
	frame.Size = UDim2.new(1, 0, 0, 50)
	frame.BackgroundColor3 = Color3.fromRGB(30, 30, 35)
	frame.LayoutOrder = order
	frame.Parent = container
	Instance.new("UICorner", frame).CornerRadius = UDim.new(0, 8)

	-- Determine Locked State
	local isLocked = isPremium and not hasGamepass

	if isLocked then
		frame.BackgroundTransparency = 0.5 -- Fade out locked items
	end

	local label = Instance.new("TextLabel")
	label.Text = name .. (isLocked and " [LOCKED]" or "")
	label.Font = Enum.Font.GothamMedium
	label.TextColor3 = isLocked and UI_THEME.Locked or UI_THEME.Text
	label.TextSize = 14
	label.Size = UDim2.new(1, -10, 0, 20)
	label.Position = UDim2.new(0, 10, 0, 5)
	label.BackgroundTransparency = 1
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.Parent = frame

	local valLabel = Instance.new("TextLabel")
	valLabel.Text = string.format("%.2f", defaultVal)
	valLabel.Font = Enum.Font.GothamBold
	valLabel.TextColor3 = UI_THEME.SubText
	valLabel.TextSize = 12
	valLabel.Size = UDim2.new(0, 50, 0, 20)
	valLabel.Position = UDim2.new(1, -60, 0, 5)
	valLabel.BackgroundTransparency = 1
	valLabel.TextXAlignment = Enum.TextXAlignment.Right
	valLabel.Parent = frame

	local sliderBg = Instance.new("Frame")
	sliderBg.Size = UDim2.new(1, -20, 0, 6)
	sliderBg.Position = UDim2.new(0, 10, 0, 35)
	sliderBg.BackgroundColor3 = Color3.fromRGB(15, 15, 20)
	sliderBg.BorderSizePixel = 0
	sliderBg.Parent = frame
	Instance.new("UICorner", sliderBg).CornerRadius = UDim.new(1, 0)

	local fill = Instance.new("Frame")
	fill.Size = UDim2.new((defaultVal - minVal)/(maxVal - minVal), 0, 1, 0)
	fill.BackgroundColor3 = isLocked and UI_THEME.Locked or UI_THEME.Accent
	fill.BorderSizePixel = 0
	fill.Parent = sliderBg
	Instance.new("UICorner", fill).CornerRadius = UDim.new(1, 0)

	local trigger = Instance.new("TextButton")
	trigger.Size = UDim2.new(1, 0, 1, 0)
	trigger.BackgroundTransparency = 1
	trigger.Text = ""
	trigger.Parent = sliderBg

	local isDragging = false

	-- SECURE CALLBACK WRAPPER
	local function secureUpdate(val)
		if isPremium and not hasGamepass then
			return -- HARD STOP: Do not run the callback if locked
		end
		callback(val)
	end

	local function updateVisuals(input)
		local pos = math.clamp((input.Position.X - sliderBg.AbsolutePosition.X) / sliderBg.AbsoluteSize.X, 0, 1)
		local newVal = minVal + (pos * (maxVal - minVal))

		fill.Size = UDim2.new(pos, 0, 1, 0)
		valLabel.Text = string.format("%.2f", newVal)
		secureUpdate(newVal)
	end

	trigger.MouseButton1Down:Connect(function() 
		if isPremium and not hasGamepass then
			MarketplaceService:PromptGamePassPurchase(Player, GAMEPASS_ID)
			return
		end
		isDragging = true 
	end)

	UserInputService.InputEnded:Connect(function(input) 
		if input.UserInputType == Enum.UserInputType.MouseButton1 then isDragging = false end 
	end)

	UserInputService.InputChanged:Connect(function(input)
		if isDragging and input.UserInputType == Enum.UserInputType.MouseMovement then
			updateVisuals(input)
		end
	end)

	-- Live update if they buy it while menu is open
	task.spawn(function()
		while true do
			if isPremium and hasGamepass and label.Text:find("LOCKED") then
				label.Text = name
				label.TextColor3 = UI_THEME.Text
				fill.BackgroundColor3 = UI_THEME.Accent
				frame.BackgroundTransparency = 0
			end
			task.wait(1)
		end
	end)
end

local function createToggle(name, defaultState, callback, order, isPremium)
	local frame = Instance.new("Frame")
	frame.Size = UDim2.new(1, 0, 0, 40)
	frame.BackgroundColor3 = Color3.fromRGB(30, 30, 35)
	frame.LayoutOrder = order
	frame.Parent = container
	Instance.new("UICorner", frame).CornerRadius = UDim.new(0, 8)

	local isLocked = isPremium and not hasGamepass
	if isLocked then frame.BackgroundTransparency = 0.5 end

	local label = Instance.new("TextLabel")
	label.Text = name .. (isLocked and " [LOCKED]" or "")
	label.Font = Enum.Font.GothamMedium
	label.TextColor3 = isLocked and UI_THEME.Locked or UI_THEME.Text
	label.TextSize = 14
	label.Size = UDim2.new(0.7, 0, 1, 0)
	label.Position = UDim2.new(0, 10, 0, 0)
	label.BackgroundTransparency = 1
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.Parent = frame

	local btn = Instance.new("TextButton")
	btn.Size = UDim2.new(0, 24, 0, 24)
	btn.Position = UDim2.new(1, -34, 0.5, -12)
	btn.BackgroundColor3 = defaultState and UI_THEME.Accent or Color3.fromRGB(50, 50, 60)
	btn.Text = ""
	btn.Parent = frame
	Instance.new("UICorner", btn).CornerRadius = UDim.new(0, 6)

	btn.MouseButton1Click:Connect(function()
		if isPremium and not hasGamepass then
			MarketplaceService:PromptGamePassPurchase(Player, GAMEPASS_ID)
			return
		end

		defaultState = not defaultState
		btn.BackgroundColor3 = defaultState and UI_THEME.Accent or Color3.fromRGB(50, 50, 60)
		callback(defaultState)
	end)

	task.spawn(function()
		while true do
			if isPremium and hasGamepass and label.Text:find("LOCKED") then
				label.Text = name
				label.TextColor3 = UI_THEME.Text
				frame.BackgroundTransparency = 0
			end
			task.wait(1)
		end
	end)
end

local function createKeybindButton(text, settingKey, order)
	local frame = Instance.new("Frame")
	frame.Size = UDim2.new(1, 0, 0, 40)
	frame.BackgroundColor3 = Color3.fromRGB(30, 30, 35)
	frame.LayoutOrder = order
	frame.Parent = container
	Instance.new("UICorner", frame).CornerRadius = UDim.new(0, 8)

	local label = Instance.new("TextLabel")
	label.Text = text
	label.Font = Enum.Font.GothamMedium
	label.TextColor3 = UI_THEME.Text
	label.TextSize = 14
	label.Size = UDim2.new(0.6, 0, 1, 0)
	label.Position = UDim2.new(0, 10, 0, 0)
	label.BackgroundTransparency = 1
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.Parent = frame

	local btn = Instance.new("TextButton")
	btn.Size = UDim2.new(0.35, 0, 0.7, 0)
	btn.Position = UDim2.new(0.62, 0, 0.15, 0)
	btn.BackgroundColor3 = UI_THEME.Button
	btn.Text = SETTINGS[settingKey].Name
	btn.TextColor3 = UI_THEME.Accent
	btn.Font = Enum.Font.GothamBold
	btn.TextSize = 12
	btn.Parent = frame
	Instance.new("UICorner", btn).CornerRadius = UDim.new(0, 6)

	local listening = false

	btn.MouseButton1Click:Connect(function()
		if listening then return end
		listening = true
		btn.Text = "PRESS KEY..."
		btn.TextColor3 = UI_THEME.SubText

		local connection
		connection = UserInputService.InputBegan:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.Keyboard then
				SETTINGS[settingKey] = input.KeyCode
				btn.Text = input.KeyCode.Name
				btn.TextColor3 = UI_THEME.Accent
				listening = false

				if settingKey == "HideUiKey" then
					hint.Text = "Press " .. input.KeyCode.Name .. " to Hide UI"
				end
				connection:Disconnect()
			end
		end)
	end)
end

-- --- BUILD UI ---
-- Last argument: TRUE = Premium/Locked, FALSE = Free

createSection("MOVEMENT & CAMERA", 1)
createSlider("Move Speed", 0.1, 10, 1, function(val) SETTINGS.NormalSpeed = val end, 2, false)
createSlider("Move Smoothness", 0, 100, 90, function(val) SETTINGS.Smoothness = val end, 3, false)
createSlider("Look Smoothness", 0, 100, 95, function(val) SETTINGS.RotationSmoothness = val end, 4, false)
createSlider("Field of View", 5, 170, 70, function(val) 
	targetFOV = val
end, 5, false)
createSlider("Camera Roll", -45, 45, 0, function(val) cameraRoll = val end, 6, false)

createSection("ENVIRONMENT & ATMOSPHERE", 7)
createSlider("Time of Day", 0, 24, 14, function(val) 
	overrideClockTime = val
	Lighting.ClockTime = val 
end, 8, true)
createSlider("Exposure", -2, 2, 0, function(val) Lighting.ExposureCompensation = val end, 9, true)

if atmosphere then
	createSlider("Atmosphere Haze", 0, 1, 0, function(val) atmosphere.Density = val end, 10, true)
end
if sunRays then
	createSlider("Sun Rays Intensity", 0, 1, 0.25, function(val) sunRays.Intensity = val end, 11, true)
end

createSection("CINEMATIC EFFECTS", 12)
createToggle("Cinematic Bars", false, function(active)
	local bars = gui:FindFirstChild("CinematicBars")
	if active then
		if not bars then
			bars = Instance.new("Folder")
			bars.Name = "CinematicBars"
			bars.Parent = gui
			local top = Instance.new("Frame", bars)
			top.Size = UDim2.new(1, 0, 0.12, 0)
			top.BackgroundColor3 = Color3.new(0,0,0)
			top.BorderSizePixel = 0
			local bot = Instance.new("Frame", bars)
			bot.Size = UDim2.new(1, 0, 0.12, 0)
			bot.Position = UDim2.new(0, 0, 1, -bot.Size.Y.Offset)
			bot.AnchorPoint = Vector2.new(0, 1)
			bot.BackgroundColor3 = Color3.new(0,0,0)
			bot.BorderSizePixel = 0
		end
	else
		if bars then bars:Destroy() end
	end
end, 11, true)

createToggle("Enable Blur", false, function(val) 
	blurEffect.Enabled = val 
	if val then blurEffect.Size = 10 end
end, 12, true)
createSlider("Blur Strength", 0, 30, 10, function(val) blurEffect.Size = val end, 13, true)

createSection("DEPTH OF FIELD", 14)
createToggle("Enable DOF", false, function(val) dofEffect.Enabled = val end, 15, true)
createSlider("Focus Distance", 0, 200, 10, function(val) dofEffect.FocusDistance = val end, 16, true)
createSlider("Blur Intensity", 0, 1, 0.25, function(val) dofEffect.InFocusRadius = 30 - (val*20) end, 17, true)

createSection("COLOR GRADING", 18)
createSlider("Saturation", -1, 1, 0, function(val) colorEffect.Saturation = val end, 19, true)
createSlider("Contrast", -1, 1, 0, function(val) colorEffect.Contrast = val end, 20, true)

createSection("KEYBINDS", 21)
createKeybindButton("Toggle UI Visibility", "HideUiKey", 22)

-- --- CAMERA & LOGIC ---

local function enableFreecam()
	-- Snapshot state
	storedState = {
		ClockTime = Lighting.ClockTime,
		Exposure = Lighting.ExposureCompensation,
		FOV = Camera.FieldOfView,
		DOF_Enabled = dofEffect.Enabled,
		Blur_Enabled = blurEffect.Enabled,
		Saturation = colorEffect.Saturation,
		Contrast = colorEffect.Contrast
	}
	if atmosphere then storedState.AtmosphereDensity = atmosphere.Density end
	if sunRays then storedState.SunRaysIntensity = sunRays.Intensity end

	-- Save player's current movement stats so we restore them on exit
	if Player.Character and Player.Character:FindFirstChild("Humanoid") then
		storedState.WalkSpeed = Player.Character.Humanoid.WalkSpeed
		storedState.JumpPower = Player.Character.Humanoid.JumpPower
	end

	Camera = Workspace.CurrentCamera
	if ClosePanels then ClosePanels:Fire("Freecam") end
	isFreecamEnabled = true
	Player:SetAttribute("FreecamActive", true)
	gui.Enabled = true
	isUiVisible = true
	mainFrame.Visible = true

	Camera.CameraType = Enum.CameraType.Scriptable
	Camera.FieldOfView = currentFOV

	if Player.Character and Player.Character:FindFirstChild("Humanoid") then
		Player.Character.Humanoid.WalkSpeed = 0
		Player.Character.Humanoid.JumpPower = 0
	end
	UserInputService.MouseIconEnabled = true
	cameraPos = Camera.CFrame.Position
	local rx, ry, rz = Camera.CFrame:ToOrientation()
	targetCameraRot = Vector2.new(ry, rx)
	currentCameraRot = targetCameraRot
	targetFOV = Camera.FieldOfView
	currentFOV = targetFOV
	overrideClockTime = nil
end

local function disableFreecam()
	isFreecamEnabled = false
	Player:SetAttribute("FreecamActive", false)
	gui.Enabled = false
	Camera.CameraType = Enum.CameraType.Custom

	-- Restore
	if storedState.ClockTime then Lighting.ClockTime = storedState.ClockTime end
	if storedState.Exposure then Lighting.ExposureCompensation = storedState.Exposure end
	if storedState.FOV then Camera.FieldOfView = storedState.FOV end
	dofEffect.Enabled = storedState.DOF_Enabled or false
	blurEffect.Enabled = storedState.Blur_Enabled or false
	colorEffect.Saturation = storedState.Saturation or 0
	colorEffect.Contrast = storedState.Contrast or 0
	if atmosphere and storedState.AtmosphereDensity then atmosphere.Density = storedState.AtmosphereDensity end
	if sunRays and storedState.SunRaysIntensity then sunRays.Intensity = storedState.SunRaysIntensity end

	if Player.Character and Player.Character:FindFirstChild("Humanoid") then
		Player.Character.Humanoid.WalkSpeed = storedState.WalkSpeed or 150
		Player.Character.Humanoid.JumpPower = storedState.JumpPower or 50
		Player.Character.Humanoid.PlatformStand = false
		Player.Character.Humanoid.AutoRotate = true
		local hrp = Player.Character:FindFirstChild("HumanoidRootPart")
		if hrp then hrp.Anchored = false end
	end
	UserInputService.MouseIconEnabled = true
	UserInputService.MouseBehavior = Enum.MouseBehavior.Default
	Camera.CameraSubject = Player.Character and Player.Character:FindFirstChildOfClass("Humanoid") or nil
	overrideClockTime = nil
	lockEnabled = false
	lockTarget = nil
end

if ClosePanels then
	ClosePanels.Event:Connect(function(source)
		if source == "Freecam" then return end
		if isFreecamEnabled then disableFreecam() end
	end)
end

Player.CharacterAdded:Connect(function()
	task.defer(function()
		if isFreecamEnabled then
			disableFreecam()
		else
			UserInputService.MouseBehavior = Enum.MouseBehavior.Default
			UserInputService.MouseIconEnabled = true
		end
	end)
end)

-- Inputs
UserInputService.InputBegan:Connect(function(input, gameProcessed)
	if isFreecamEnabled and input.KeyCode == SETTINGS.HideUiKey and input.UserInputType == Enum.UserInputType.Keyboard then
		if not UserInputService:GetFocusedTextBox() then
			isUiVisible = not isUiVisible
			mainFrame.Visible = isUiVisible
			UserInputService.MouseIconEnabled = isUiVisible
			return 
		end
	end

	if gameProcessed then return end

	if input.KeyCode == Enum.KeyCode.P and (UserInputService:IsKeyDown(Enum.KeyCode.LeftShift) or UserInputService:IsKeyDown(Enum.KeyCode.RightShift)) then
		if isFreecamEnabled then
			disableFreecam()
		else
			checkGamepass()
			enableFreecam()
		end
	end

	-- R key: Lock camera to current look-at point
	if isFreecamEnabled and input.KeyCode == Enum.KeyCode.R then
		if lockEnabled then
			-- Toggle off
			lockEnabled = false
			lockTarget = nil
		else
			-- Lock to whatever point the camera is looking at
			local rayOrigin = Camera.CFrame.Position
			local rayDir = Camera.CFrame.LookVector * 2000
			local rayParams = RaycastParams.new()
			rayParams.FilterType = Enum.RaycastFilterType.Exclude
			rayParams.FilterDescendantsInstances = {Player.Character}
			local result = workspace:Raycast(rayOrigin, rayDir, rayParams)
			if result then
				lockTarget = result.Position
				lockEnabled = true
			else
				-- Lock to a far point in front
				lockTarget = rayOrigin + rayDir
				lockEnabled = true
			end
		end
	end
end)

UserInputService.InputChanged:Connect(function(input)
	if not isFreecamEnabled then return end

	if input.UserInputType == Enum.UserInputType.MouseWheel then
		if not isUiVisible then
			local zoomSpeed = 5 
			targetFOV = math.clamp(targetFOV - (input.Position.Z * zoomSpeed), 5, 170)
		end
	end

	if input.UserInputType == Enum.UserInputType.MouseMovement then
		if UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton2) then
			local delta = input.Delta
			targetCameraRot = targetCameraRot - Vector2.new(delta.X * SETTINGS.Sensitivity, delta.Y * SETTINGS.Sensitivity)
			targetCameraRot = Vector2.new(targetCameraRot.X, math.clamp(targetCameraRot.Y, -math.rad(89), math.rad(89)))
			UserInputService.MouseBehavior = Enum.MouseBehavior.LockCurrentPosition
		else
			if isUiVisible then
				UserInputService.MouseBehavior = Enum.MouseBehavior.Default
			else
				UserInputService.MouseBehavior = Enum.MouseBehavior.LockCenter
			end
		end
	end
end)

-- Main Loop
local wasFreecamEnabled = false
RunService.RenderStepped:Connect(function(dt)
	if not isFreecamEnabled then
		if wasFreecamEnabled then
			UserInputService.MouseBehavior = Enum.MouseBehavior.Default
			UserInputService.MouseIconEnabled = true
			wasFreecamEnabled = false
		end
		return
	end
	wasFreecamEnabled = true

	if overrideClockTime then
		Lighting.ClockTime = overrideClockTime
	end

	currentFOV = currentFOV + (targetFOV - currentFOV) * (1 - math.pow(0.01, dt))
	if math.abs(Camera.FieldOfView - currentFOV) > 0.01 then
		Camera.FieldOfView = currentFOV
	end

	-- Convert 0-100 to a lerp alpha (0 = snappy, 100 = ultra smooth)
	local function getAlpha(smoothness, deltaTime)
		-- Invert the slider (100 -> 0.001, 0 -> 1)
		local t = math.clamp(1 - (smoothness / 100), 0.001, 1)
		-- Framerate independent lerp mapping
		return 1 - math.pow(1 - t, deltaTime * 60)
	end

	local rotAlpha = getAlpha(SETTINGS.RotationSmoothness, dt)
	currentCameraRot = currentCameraRot:Lerp(targetCameraRot, rotAlpha)

	local moveVector = Vector3.new(0, 0, 0)
	if UserInputService:IsKeyDown(Enum.KeyCode.W) then moveVector = moveVector + Vector3.new(0, 0, -1) end
	if UserInputService:IsKeyDown(Enum.KeyCode.S) then moveVector = moveVector + Vector3.new(0, 0, 1) end
	if UserInputService:IsKeyDown(Enum.KeyCode.A) then moveVector = moveVector + Vector3.new(-1, 0, 0) end
	if UserInputService:IsKeyDown(Enum.KeyCode.D) then moveVector = moveVector + Vector3.new(1, 0, 0) end
	if UserInputService:IsKeyDown(Enum.KeyCode.E) then moveVector = moveVector + Vector3.new(0, 1, 0) end
	if UserInputService:IsKeyDown(Enum.KeyCode.Q) then moveVector = moveVector + Vector3.new(0, -1, 0) end

	local speedMultiplier = SETTINGS.NormalSpeed
	if UserInputService:IsKeyDown(Enum.KeyCode.LeftShift) then speedMultiplier = speedMultiplier * SETTINGS.FastSpeedMultiplier end
	if UserInputService:IsKeyDown(Enum.KeyCode.LeftAlt) then speedMultiplier = speedMultiplier * SETTINGS.SlowSpeedMultiplier end

	local camCFrame = CFrame.fromOrientation(currentCameraRot.Y, currentCameraRot.X, math.rad(cameraRoll))
	local targetVel = (camCFrame * moveVector) * (50 * speedMultiplier)
	local moveAlpha = getAlpha(SETTINGS.Smoothness, dt)
	currentVel = currentVel:Lerp(targetVel, moveAlpha)
	cameraPos = cameraPos + (currentVel * dt)

	-- Lock-to-point: override camera rotation to always face lockTarget
	if lockEnabled and lockTarget then
		Camera.CFrame = CFrame.lookAt(cameraPos, lockTarget) * CFrame.Angles(0, 0, math.rad(cameraRoll))
		-- Update current rotation to match so it doesn't snap when unlocking
		local rx, ry, rz = Camera.CFrame:ToOrientation()
		currentCameraRot = Vector2.new(ry, rx)
		targetCameraRot = currentCameraRot
	else
		Camera.CFrame = CFrame.new(cameraPos) * camCFrame
	end
end)
