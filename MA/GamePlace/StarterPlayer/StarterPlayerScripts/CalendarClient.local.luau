--[=[ PATH: StarterPlayerScripts/CalendarClient | TYPE: LocalScript ]=]--
--[[
	CalendarClient
	Handles opening the Weather/Season/Time controller (CalendarFrame) 
	when the TimeWeather display in the top bar is clicked.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local MarketplaceService = game:GetService("MarketplaceService")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local Lighting = game:GetService("Lighting")

local Player = Players.LocalPlayer
local PlayerGui = Player:WaitForChild("PlayerGui")
local MainHUD = PlayerGui:WaitForChild("MainHUD", 10)
if not MainHUD then return end

local Top = MainHUD:WaitForChild("Top")
local TopBar = Top:WaitForChild("TopBar")
local TimeWeather = MainHUD:FindFirstChild("TimeWeather") or MainHUD:WaitForChild("TimeWeather", 10)
if not TimeWeather then return end

local CalendarFrame = MainHUD:WaitForChild("CalendarFrame")
local Header = CalendarFrame:WaitForChild("Header")
local CloseButton = Header:WaitForChild("CloseButton")
local ControlPanel = CalendarFrame:WaitForChild("ControlPanel")

local Events = ReplicatedStorage:WaitForChild("Events")
local ClosePanels = Events:FindFirstChild("ClosePanels")
if not ClosePanels then
	ClosePanels = Instance.new("BindableEvent")
	ClosePanels.Name = "ClosePanels"
	ClosePanels.Parent = Events
end

local AdminWeatherUpdate = Events:FindFirstChild("AdminWeatherUpdate")
if not AdminWeatherUpdate then
	AdminWeatherUpdate = Instance.new("RemoteEvent")
	AdminWeatherUpdate.Name = "AdminWeatherUpdate"
	AdminWeatherUpdate.Parent = Events
end

local EntitlementManager = require(ReplicatedStorage:WaitForChild("EntitlementManager"))
local EntitlementEvents = ReplicatedStorage:FindFirstChild("EntitlementEvents")
local EntitlementChanged = EntitlementEvents and EntitlementEvents:FindFirstChild("EntitlementChanged")

local WEATHER_PASS_ID = 1707796502
local hasWeatherPass = false

local function bindGuiButton(button, callback)
	if not button or not button:IsA("GuiButton") then
		return
	end
	button.Active = true
	button.Selectable = true

	local lastPress = 0
	button.Activated:Connect(function()
		local now = os.clock()
		if now - lastPress < 0.15 then
			return
		end
		lastPress = now
		callback()
	end)
end

local function ensureOpenHitbox(container)
	if not container then
		return nil
	end
	if container:IsA("GuiButton") then
		return container
	end

	local hitbox = container:FindFirstChild("OpenHitbox")
	if hitbox and hitbox:IsA("TextButton") then
		hitbox.ZIndex = math.max(container.ZIndex + 10, 10)
		return hitbox
	end

	hitbox = Instance.new("TextButton")
	hitbox.Name = "OpenHitbox"
	hitbox.BackgroundTransparency = 1
	hitbox.BorderSizePixel = 0
	hitbox.Text = ""
	hitbox.AutoButtonColor = false
	hitbox.Size = UDim2.fromScale(1, 1)
	hitbox.ZIndex = math.max(container.ZIndex + 10, 10)
	hitbox.Parent = container
	return hitbox
end

local function CheckAccess()
	hasWeatherPass = false
	local success, result = pcall(function()
		return EntitlementManager.HasAccess(Player.UserId, WEATHER_PASS_ID)
	end)
	if success and result then
		hasWeatherPass = true
	end
end

local LockOverlay = CalendarFrame:FindFirstChild("LockOverlay")
if not LockOverlay then
	LockOverlay = Instance.new("TextButton")
	LockOverlay.Name = "LockOverlay"
	LockOverlay.Parent = CalendarFrame
	Instance.new("UICorner", LockOverlay).CornerRadius = UDim.new(0, 12)
end

if LockOverlay.Parent ~= ControlPanel then
	LockOverlay.Parent = ControlPanel
end

-- Only cover the interactive control area so the header/exit row is always reachable.
LockOverlay.Size = UDim2.fromScale(1, 1)
LockOverlay.Position = UDim2.fromScale(0, 0)
LockOverlay.BackgroundColor3 = Color3.fromRGB(15, 20, 30)
LockOverlay.BackgroundTransparency = 0.15
LockOverlay.Text = ""
LockOverlay.AutoButtonColor = false
LockOverlay.ZIndex = 100

if not LockOverlay:FindFirstChild("LockIcon") then
	local lockIcon = Instance.new("TextLabel")
	lockIcon.Name = "LockIcon"
	lockIcon.Size = UDim2.fromOffset(60, 60)
	lockIcon.Position = UDim2.new(0.5, 0, 0.4, 0)
	lockIcon.AnchorPoint = Vector2.new(0.5, 0.5)
	lockIcon.BackgroundTransparency = 1
	lockIcon.Text = "🔒"
	lockIcon.TextSize = 48
	lockIcon.ZIndex = 101
	lockIcon.Parent = LockOverlay

	local lockText = Instance.new("TextLabel")
	lockText.Name = "LockText"
	lockText.Size = UDim2.new(1, -40, 0, 30)
	lockText.Position = UDim2.new(0.5, 0, 0.4, 40)
	lockText.AnchorPoint = Vector2.new(0.5, 0.5)
	lockText.BackgroundTransparency = 1
	lockText.Text = "WEATHER CONTROLLER"
	lockText.Font = Enum.Font.GothamBlack
	lockText.TextColor3 = Color3.fromRGB(255, 255, 255)
	lockText.TextSize = 20
	lockText.ZIndex = 101
	lockText.Parent = LockOverlay

	local subText = Instance.new("TextLabel")
	subText.Name = "SubText"
	subText.Size = UDim2.new(1, -40, 0, 20)
	subText.Position = UDim2.new(0.5, 0, 0.4, 65)
	subText.AnchorPoint = Vector2.new(0.5, 0.5)
	subText.BackgroundTransparency = 1
	subText.Text = "Click to Unlock"
	subText.Font = Enum.Font.GothamMedium
	subText.TextColor3 = Color3.fromRGB(255, 200, 50)
	subText.TextSize = 14
	subText.ZIndex = 101
	subText.Parent = LockOverlay
end

-- Push Header ZIndex so the 'Close' button doesn't get buried behind the lock overlay
Header.ZIndex = 105
for _, child in ipairs(Header:GetDescendants()) do
	if child:IsA("GuiObject") then
		child.ZIndex = child.ZIndex + 105
	end
end

local function UpdateLockState()
	if hasWeatherPass then
		LockOverlay.Visible = false
	else
		LockOverlay.Visible = true
	end
end

bindGuiButton(LockOverlay, function()
	MarketplaceService:PromptGamePassPurchase(Player, WEATHER_PASS_ID)
end)

MarketplaceService.PromptGamePassPurchaseFinished:Connect(function(purchaser, passId, wasPurchased)
	if purchaser == Player and passId == WEATHER_PASS_ID and wasPurchased then
		CheckAccess()
		UpdateLockState()
	end
end)

if EntitlementChanged and EntitlementChanged:IsA("RemoteEvent") then
	EntitlementChanged.OnClientEvent:Connect(function(payload)
		if type(payload) ~= "table" or tonumber(payload.userId) ~= Player.UserId then
			return
		end
		CheckAccess()
		UpdateLockState()
	end)
end

-- // WIRING BUTTONS & SLIDERS //
local SeasonsGrid = ControlPanel:WaitForChild("SeasonsSection"):WaitForChild("Grid")
local WeatherGrid = ControlPanel:WaitForChild("WeatherSection"):WaitForChild("Grid")
local TimeSection = ControlPanel:WaitForChild("TimeSection")

local function updateActiveButtons()
	local activeSeason = Lighting:GetAttribute("Season") or "Winter"
	local activeWeather = Lighting:GetAttribute("Weather") or "Clear"

	for _, btn in ipairs(SeasonsGrid:GetChildren()) do
		if btn:IsA("GuiButton") then
			local stroke = btn:FindFirstChildOfClass("UIStroke")
			if stroke then
				stroke.Transparency = (btn.Name == activeSeason) and 0 or 1
			end
		end
	end

	for _, btn in ipairs(WeatherGrid:GetChildren()) do
		if btn:IsA("GuiButton") then
			local stroke = btn:FindFirstChildOfClass("UIStroke")
			if stroke then
				stroke.Transparency = (btn.Name == activeWeather) and 0 or 1
			end
		end
	end
end

Lighting:GetAttributeChangedSignal("Season"):Connect(updateActiveButtons)
Lighting:GetAttributeChangedSignal("Weather"):Connect(updateActiveButtons)
updateActiveButtons()

for _, btn in ipairs(SeasonsGrid:GetChildren()) do
	if btn:IsA("GuiButton") then
		bindGuiButton(btn, function()
			if hasWeatherPass then
				AdminWeatherUpdate:FireServer("Season", btn.Name)
			end
		end)
	end
end

for _, btn in ipairs(WeatherGrid:GetChildren()) do
	if btn:IsA("GuiButton") then
		bindGuiButton(btn, function()
			if hasWeatherPass then
				AdminWeatherUpdate:FireServer("Weather", btn.Name)
			end
		end)
	end
end

local sliderBg, sliderKnob, sliderFill
for _, child in ipairs(TimeSection:GetChildren()) do
	if child:IsA("CanvasGroup") then
		sliderBg = child
		sliderFill = child:FindFirstChildOfClass("Frame")
	elseif child:IsA("Frame") and child.Name == "Frame" then
		sliderKnob = child
	end
end

local timeLabel = sliderKnob and sliderKnob:FindFirstChild("Time") and sliderKnob.Time:FindFirstChildOfClass("TextLabel")
local isDraggingTime = false

if sliderBg and sliderKnob then
	local function updateTimeFromInput(input)
		if not hasWeatherPass then return end
		local bgPos = sliderBg.AbsolutePosition.X
		local bgSize = sliderBg.AbsoluteSize.X
		local x = math.clamp(input.Position.X - bgPos, 0, bgSize)
		local alpha = (bgSize > 0) and (x / bgSize) or 0
		
		sliderKnob.Position = UDim2.new(alpha, 0, sliderKnob.Position.Y.Scale, sliderKnob.Position.Y.Offset)
		if sliderFill then
			sliderFill.Size = UDim2.new(alpha, 0, 1, 0)
		end
		
		local timeVal = alpha * 24
		if timeLabel then
			local hours = math.floor(timeVal)
			local minutes = math.floor((timeVal - hours) * 60)
			timeLabel.Text = string.format("%02d:%02d", hours, minutes)
		end
		
		AdminWeatherUpdate:FireServer("Time", timeVal)
	end

	sliderBg.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			isDraggingTime = true
			updateTimeFromInput(input)
		end
	end)
	
	sliderKnob.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			isDraggingTime = true
		end
	end)

	UserInputService.InputChanged:Connect(function(input)
		if isDraggingTime and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
			updateTimeFromInput(input)
		end
	end)

	UserInputService.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			isDraggingTime = false
		end
	end)
end

local OPEN_POS = UDim2.new(0.5, 0, 0.5, 0)
local CLOSED_POS = UDim2.new(0.5, 0, 1.55, 0)
local OPEN_TWEEN = TweenInfo.new(0.28, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local CLOSE_TWEEN = TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.In)

local isOpen = false

local function setOpen(open)
	if isOpen == open then return end
	isOpen = open

	if open then
		CheckAccess()
		UpdateLockState()
		ClosePanels:Fire("Calendar")
		CalendarFrame.Visible = true
		CalendarFrame.Position = CLOSED_POS
		TweenService:Create(CalendarFrame, OPEN_TWEEN, { Position = OPEN_POS }):Play()
	else
		local t = TweenService:Create(CalendarFrame, CLOSE_TWEEN, { Position = CLOSED_POS })
		t:Play()
		t.Completed:Connect(function()
			if not isOpen then
				CalendarFrame.Visible = false
			end
		end)
	end
end

ClosePanels.Event:Connect(function(source)
	if source ~= "Calendar" and isOpen then
		setOpen(false)
	end
end)

local openHitbox = ensureOpenHitbox(TimeWeather)
bindGuiButton(openHitbox, function()
	setOpen(not isOpen)
end)

bindGuiButton(CloseButton, function()
	setOpen(false)
end)

-- Ensure initial state
CalendarFrame.Visible = false
CalendarFrame.Position = CLOSED_POS

RunService.RenderStepped:Connect(function()
	if not isDraggingTime and isOpen and sliderKnob then
		local timeVal = Lighting.ClockTime
		local alpha = timeVal / 24
		sliderKnob.Position = UDim2.new(alpha, 0, sliderKnob.Position.Y.Scale, sliderKnob.Position.Y.Offset)
		if sliderFill then
			sliderFill.Size = UDim2.new(alpha, 0, 1, 0)
		end
		if timeLabel then
			local hours = math.floor(timeVal)
			local minutes = math.floor((timeVal - hours) * 60)
			timeLabel.Text = string.format("%02d:%02d", hours, minutes)
		end
	end
end)

task.spawn(function()
	CheckAccess()
	UpdateLockState()
end)