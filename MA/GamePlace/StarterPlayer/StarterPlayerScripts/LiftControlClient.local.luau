--[=[ PATH: StarterPlayerScripts/LiftControlClient | TYPE: LocalScript ]=]--
-- Controls the LiftControlUI based on the selected lift.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local MarketplaceService = game:GetService("MarketplaceService")
local UserInputService = game:GetService("UserInputService")
local EntitlementManager = require(ReplicatedStorage:WaitForChild("EntitlementManager"))
local EntitlementEvents = ReplicatedStorage:FindFirstChild("EntitlementEvents")
local EntitlementChanged = EntitlementEvents and EntitlementEvents:FindFirstChild("EntitlementChanged")

local Player = Players.LocalPlayer
local PlayerGui = Player:WaitForChild("PlayerGui")
local LiftUI = PlayerGui:WaitForChild("LiftControlUI", 10)
if not LiftUI then warn("[LiftControlClient] LiftControlUI not found") return end
local MainFrame = LiftUI:WaitForChild("MainFrame")
if LiftUI:IsA("ScreenGui") then
	LiftUI.Enabled = false
end
MainFrame.Active = true
MainFrame.Selectable = true

local Events = ReplicatedStorage:WaitForChild("Events")
local ControlEvent = Events:WaitForChild("LiftControlEvent")
local RenamePlacedObject = Events:WaitForChild("RenamePlacedObject", 10)

local ClosePanels = Events:FindFirstChild("ClosePanels")
if not ClosePanels then
	ClosePanels = Instance.new("BindableEvent")
	ClosePanels.Name = "ClosePanels"
	ClosePanels.Parent = Events
end

-- // CONFIG //
local GAMEPASS_ID = 1704778044
local GROUP_ID = 398051359
local MIN_RANK = 240

-- // UI ELEMENTS //
local Header = MainFrame:WaitForChild("Header")
local TitleLabel = Header:WaitForChild("LiftName")
local CloseButton = Header:WaitForChild("CloseButton")

local Controls = MainFrame:WaitForChild("Controls")
local StartBtn = Controls:WaitForChild("StartButton")
local StopBtn = Controls:WaitForChild("StopButton")
local SlowBtn = Controls:WaitForChild("SlowButton")
local EStopBtn = Controls:WaitForChild("EStopButton")

local Dashboard = MainFrame:WaitForChild("Dashboard")
local SpeedLabel = Dashboard:WaitForChild("SpeedContainer"):WaitForChild("SpeedLabel")
local StatusLabel = Dashboard:WaitForChild("StatusContainer"):WaitForChild("StatusRow"):WaitForChild("StatusLabel")
local ConditionLabel = Dashboard:WaitForChild("StatusContainer"):WaitForChild("ConditionRow"):WaitForChild("ConditionLabel")
local BarFill = Dashboard:WaitForChild("StatusContainer"):WaitForChild("BarBackground"):WaitForChild("BarFill")

local RepairBtn = MainFrame:WaitForChild("RepairButton")

-- Premium Elements
local PremiumFrame = MainFrame:WaitForChild("PremiumFrame")
local LockOverlay = MainFrame:WaitForChild("LockOverlay")
local NoSeatsBtn = PremiumFrame:WaitForChild("NoSeatsBtn") 
local CloseDoorsBtn = PremiumFrame:WaitForChild("CloseDoorsBtn")

-- // STATE //
local currentLift = nil
local isOpen = false
local hasPremium = false
local uiConnections = {}
local isRenaming = false

local function sanitizeCustomName(raw)
	local text = tostring(raw or "")
	text = text:gsub("[%c]", " ")
	text = text:gsub("%s+", " ")
	text = text:gsub("^%s+", "")
	text = text:gsub("%s+$", "")
	if #text > 48 then text = string.sub(text, 1, 48) end
	return text
end

local function getLiftDisplayName(lift)
	local customName = sanitizeCustomName(lift and lift:GetAttribute("CustomName") or "")
	if customName ~= "" then return customName end
	return sanitizeCustomName(lift and lift.Name or "Lift")
end

local MainScale = MainFrame:FindFirstChildOfClass("UIScale")
local SizeConstraint = MainFrame:FindFirstChild("MobileSizeConstraint")
local DefaultMainSize = MainFrame.Size
local DefaultMainPosition = MainFrame.Position
local DefaultControlsSize = Controls.Size
local DefaultControlsPosition = Controls.Position
local DefaultRepairSize = RepairBtn.Size
local DefaultRepairPosition = RepairBtn.Position
local DefaultRepairTextSize = RepairBtn.TextSize
local DefaultMinSize = (SizeConstraint and SizeConstraint:IsA("UISizeConstraint")) and SizeConstraint.MinSize or nil
local DefaultMaxSize = (SizeConstraint and SizeConstraint:IsA("UISizeConstraint")) and SizeConstraint.MaxSize or nil

-- // CHECK PERMISSIONS //
-- // INLINE RENAME UI //
local RenameBox = Instance.new("TextBox")
RenameBox.Name = "RenameBox"
RenameBox.BackgroundColor3 = Color3.fromRGB(22, 26, 34)
RenameBox.BorderSizePixel = 0
RenameBox.ClearTextOnFocus = false
RenameBox.Font = TitleLabel.Font
RenameBox.TextSize = TitleLabel.TextSize
RenameBox.TextColor3 = Color3.fromRGB(240, 244, 255)
RenameBox.PlaceholderColor3 = Color3.fromRGB(139, 151, 173)
RenameBox.PlaceholderText = "Lift name"
RenameBox.Text = ""
RenameBox.TextXAlignment = Enum.TextXAlignment.Left
RenameBox.TextTruncate = Enum.TextTruncate.AtEnd
RenameBox.Size = UDim2.new(1, -52, 1, 0)
RenameBox.Position = UDim2.new(0, 0, 0, 0)
RenameBox.Visible = false
RenameBox.ZIndex = TitleLabel.ZIndex + 1
RenameBox.Parent = TitleLabel.Parent
local renameCorner = Instance.new("UICorner")
renameCorner.CornerRadius = UDim.new(0, 5)
renameCorner.Parent = RenameBox
local renamePadding = Instance.new("UIPadding")
renamePadding.PaddingLeft = UDim.new(0, 6)
renamePadding.PaddingRight = UDim.new(0, 4)
renamePadding.Parent = RenameBox

local ConfirmRenameBtn = Instance.new("TextButton")
ConfirmRenameBtn.Name = "ConfirmRename"
ConfirmRenameBtn.Text = "\u{2713}"
ConfirmRenameBtn.Font = Enum.Font.GothamBold
ConfirmRenameBtn.TextSize = 16
ConfirmRenameBtn.TextColor3 = Color3.fromRGB(85, 255, 127)
ConfirmRenameBtn.BackgroundColor3 = Color3.fromRGB(34, 40, 50)
ConfirmRenameBtn.BorderSizePixel = 0
ConfirmRenameBtn.Size = UDim2.new(0, 24, 0, 24)
ConfirmRenameBtn.Position = UDim2.new(1, -50, 0.5, -12)
ConfirmRenameBtn.Visible = false
ConfirmRenameBtn.ZIndex = TitleLabel.ZIndex + 2
ConfirmRenameBtn.Parent = TitleLabel.Parent
Instance.new("UICorner", ConfirmRenameBtn).CornerRadius = UDim.new(0, 6)

local CancelRenameBtn = Instance.new("TextButton")
CancelRenameBtn.Name = "CancelRename"
CancelRenameBtn.Text = "\u{2717}"
CancelRenameBtn.Font = Enum.Font.GothamBold
CancelRenameBtn.TextSize = 16
CancelRenameBtn.TextColor3 = Color3.fromRGB(255, 85, 85)
CancelRenameBtn.BackgroundColor3 = Color3.fromRGB(34, 40, 50)
CancelRenameBtn.BorderSizePixel = 0
CancelRenameBtn.Size = UDim2.new(0, 24, 0, 24)
CancelRenameBtn.Position = UDim2.new(1, -24, 0.5, -12)
CancelRenameBtn.Visible = false
CancelRenameBtn.ZIndex = TitleLabel.ZIndex + 2
CancelRenameBtn.Parent = TitleLabel.Parent
Instance.new("UICorner", CancelRenameBtn).CornerRadius = UDim.new(0, 6)

local function setRenameMode(active)
	isRenaming = active
	RenameBox.Visible = active
	ConfirmRenameBtn.Visible = active
	CancelRenameBtn.Visible = active
	TitleLabel.Visible = not active
	CloseButton.Visible = not active
	if active and currentLift then
		local custom = sanitizeCustomName(currentLift:GetAttribute("CustomName") or "")
		RenameBox.Text = custom
		RenameBox.PlaceholderText = sanitizeCustomName(currentLift.Name or "Lift")
		RenameBox:CaptureFocus()
	end
end

local function commitRename()
	if not isRenaming or not currentLift then
		setRenameMode(false)
		return
	end
	local requestedName = sanitizeCustomName(RenameBox.Text)
	setRenameMode(false)
	if RenamePlacedObject then
		RenamePlacedObject:FireServer(currentLift, requestedName)
	end
end

local function cancelRename()
	setRenameMode(false)
end

ConfirmRenameBtn.Activated:Connect(function()
	RenameBox:ReleaseFocus()
	commitRename()
end)
CancelRenameBtn.Activated:Connect(function()
	RenameBox:ReleaseFocus()
	cancelRename()
end)

RenameBox.FocusLost:Connect(function(enterPressed)
	if enterPressed then
		commitRename()
	end
end)

local function CheckAccess()
	hasPremium = false

	local success, rank = pcall(function() return Player:GetRankInGroup(GROUP_ID) end)
	if success and rank and rank >= MIN_RANK then
		hasPremium = true
		return
	end

	local passSuccess, result = pcall(function()
		return EntitlementManager.HasAccess(Player.UserId, GAMEPASS_ID)
	end)
	if passSuccess and result then
		hasPremium = true
	end
end
CheckAccess()

local function bindGuiButton(button, callback)
	if not (button and callback and button:IsA("GuiObject")) then return end
	button.Active = true
	button.Selectable = button:IsA("GuiButton")
	if button:IsA("GuiButton") then
		button.AutoButtonColor = true
	end
	local firedAt = 0
	local function fire()
		local now = os.clock()
		if now - firedAt < 0.2 then return end
		firedAt = now
		callback()
	end
	if button:IsA("GuiButton") then
		button.Activated:Connect(fire)
	else
		button.InputBegan:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.Touch or input.UserInputType == Enum.UserInputType.MouseButton1 then
				fire()
			end
		end)
	end
end

local function disconnectUIConnections()
	for _, conn in ipairs(uiConnections) do
		if conn and conn.Disconnect then
			conn:Disconnect()
		end
	end
	table.clear(uiConnections)
end

-- Click title to start renaming (must be after bindGuiButton is defined)
local RenameTrigger = Instance.new("TextButton")
RenameTrigger.Name = "RenameTrigger"
RenameTrigger.Text = ""
RenameTrigger.BackgroundTransparency = 1
RenameTrigger.Size = UDim2.new(1, 0, 1, 0)
RenameTrigger.ZIndex = TitleLabel.ZIndex
RenameTrigger.Parent = TitleLabel
bindGuiButton(RenameTrigger, function()
	if not isOpen or not currentLift then return end
	setRenameMode(true)
end)

-- // FUNCTIONS //
local function CloseUI()
	if isRenaming then
		cancelRename()
	end
	isOpen = false
	MainFrame.Visible = false
	if LiftUI:IsA("ScreenGui") then
		LiftUI.Enabled = false
	end
	disconnectUIConnections()
	currentLift = nil
end

local function SendCommand(action)
	if not currentLift then return end
	ControlEvent:FireServer(action, currentLift)
end

local function UpdateLockState()
	if hasPremium then
		LockOverlay.Visible = false
	else
		LockOverlay.Visible = true
	end
end

local function applyResponsiveLayout()
	local camera = workspace.CurrentCamera
	local viewport = camera and camera.ViewportSize or Vector2.new(1280, 720)
	local shortSide = math.min(viewport.X, viewport.Y)
	local touchLayout = UserInputService.TouchEnabled and shortSide <= 1100

	if MainScale then
		MainScale.Scale = touchLayout and 1.05 or 1
	end
	if SizeConstraint and SizeConstraint:IsA("UISizeConstraint") then
		SizeConstraint.MinSize = touchLayout and Vector2.new(320, 460) or (DefaultMinSize or Vector2.new(300, 400))
		SizeConstraint.MaxSize = touchLayout and Vector2.new(620, 760) or (DefaultMaxSize or Vector2.new(math.huge, math.huge))
	end

	if touchLayout then
		MainFrame.Size = UDim2.new(0, math.min(math.floor(viewport.X - 24), 620), 0, math.min(math.floor(viewport.Y - 120), 700))
		MainFrame.Position = UDim2.new(0.5, 0, 0.44, 0)
		Controls.Position = UDim2.new(0.0165, 0, 0.43, 0)
		Controls.Size = UDim2.new(0.9669, 0, 0.15, 0)
		RepairBtn.Position = UDim2.new(0.0165, 0, 0.835, 0)
		RepairBtn.Size = UDim2.new(0.9669, 0, 0.125, 0)
		RepairBtn.TextSize = 15
	else
		MainFrame.Size = DefaultMainSize
		MainFrame.Position = DefaultMainPosition
		Controls.Position = DefaultControlsPosition
		Controls.Size = DefaultControlsSize
		RepairBtn.Position = DefaultRepairPosition
		RepairBtn.Size = DefaultRepairSize
		RepairBtn.TextSize = DefaultRepairTextSize
	end
end

local function UpdateDisplay()
	if not isOpen or not currentLift or not currentLift.Parent then return end

	-- Read Attributes
	local status = currentLift:GetAttribute("Status") or "Unknown"
	local condition = currentLift:GetAttribute("Condition") or 100
	local targetSpeed = currentLift:GetAttribute("TargetSpeed") or 0

	local seatsDisabled = currentLift:GetAttribute("DisableSeats") == true
	local doorsClosed = currentLift:GetAttribute("CloseDoors") == true

	-- Update Text
	if not isRenaming then
		TitleLabel.Text = getLiftDisplayName(currentLift) .. " Control"
	end
	StatusLabel.Text = status
	ConditionLabel.Text = math.floor(condition) .. "%"
	SpeedLabel.Text = (targetSpeed * 100) .. "%"

	-- Update Bar Color & Size
	BarFill.Size = UDim2.new(condition / 100, 0, 1, 0)

	if condition > 50 then
		BarFill.BackgroundColor3 = Color3.fromRGB(85, 255, 127)
	elseif condition > 20 then
		BarFill.BackgroundColor3 = Color3.fromRGB(255, 170, 0)
	else
		BarFill.BackgroundColor3 = Color3.fromRGB(255, 0, 0)
	end

	-- Status Color
	if status == "Running" then StatusLabel.TextColor3 = Color3.new(0,1,0)
	elseif status == "Broken" then StatusLabel.TextColor3 = Color3.new(1,0,0)
	else StatusLabel.TextColor3 = Color3.new(1,1,1) end

	SlowBtn.Text = (status == "Slow") and "RESUME" or "SLOW"
	SlowBtn.BackgroundColor3 = (status == "Slow") and Color3.fromRGB(85, 170, 255) or Color3.fromRGB(255, 170, 0)

	-- Update Premium Buttons Text/Color
	if hasPremium then
		NoSeatsBtn.Text = seatsDisabled and "NO SEATS: ON" or "NO SEATS: OFF"
		NoSeatsBtn.BackgroundColor3 = seatsDisabled and Color3.fromRGB(255, 85, 85) or Color3.fromRGB(80,80,80)

		CloseDoorsBtn.Text = doorsClosed and "DOORS: SHUT" or "DOORS: OPEN"
		CloseDoorsBtn.BackgroundColor3 = doorsClosed and Color3.fromRGB(255, 85, 85) or Color3.fromRGB(80,80,80)
	end
end

local function bindLiftSignals(lift)
	disconnectUIConnections()
	if not lift then return end
	for _, attributeName in ipairs({"Status", "Condition", "TargetSpeed", "DisableSeats", "CloseDoors"}) do
		table.insert(uiConnections, lift:GetAttributeChangedSignal(attributeName):Connect(UpdateDisplay))
	end
	table.insert(uiConnections, lift.AncestryChanged:Connect(function(_, parent)
		if not parent then
			CloseUI()
		end
	end))
	table.insert(uiConnections, lift:GetAttributeChangedSignal("CustomName"):Connect(function()
		if not isRenaming then
			UpdateDisplay()
		end
	end))
end

-- // EVENT LISTENERS //
ControlEvent.OnClientEvent:Connect(function(action, payload)
	if action == "OpenUI" then
		CheckAccess()
		currentLift = payload
		bindLiftSignals(currentLift)
		ClosePanels:Fire("LiftControl")
		isOpen = true
		if LiftUI:IsA("ScreenGui") then
			LiftUI.Enabled = true
		end
		MainFrame.Visible = true
		applyResponsiveLayout()
		UpdateLockState()
		UpdateDisplay()
	end
end)

ClosePanels.Event:Connect(function(source)
	if source == "LiftControl" then return end
	if isOpen then CloseUI() end
end)

-- Purchase Listener
MarketplaceService.PromptGamePassPurchaseFinished:Connect(function(player, passId, wasPurchased)
	if player == Player and passId == GAMEPASS_ID and wasPurchased then
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
		if isOpen then
			UpdateDisplay()
		end
	end)
end

bindGuiButton(CloseButton, CloseUI)
bindGuiButton(StartBtn, function() SendCommand("Start") end)
bindGuiButton(StopBtn, function() SendCommand("Stop") end)
bindGuiButton(SlowBtn, function() SendCommand("Slow") end)
bindGuiButton(EStopBtn, function() SendCommand("EStop") end)
bindGuiButton(RepairBtn, function() SendCommand("Repair") end)
bindGuiButton(NoSeatsBtn, function() SendCommand("ToggleSeats") end)
bindGuiButton(CloseDoorsBtn, function() SendCommand("ToggleDoors") end)
bindGuiButton(LockOverlay, function()
	MarketplaceService:PromptGamePassPurchase(Player, GAMEPASS_ID)
end)
local unlockButton = LockOverlay:FindFirstChild("UnlockButton")
if unlockButton and unlockButton:IsA("GuiButton") then
	bindGuiButton(unlockButton, function()
		MarketplaceService:PromptGamePassPurchase(Player, GAMEPASS_ID)
	end)
end

UserInputService.InputBegan:Connect(function(input, processed)
	if not isOpen then return end
	if input.KeyCode == Enum.KeyCode.Escape then
		if isRenaming then
			cancelRename()
			return
		end
		if not processed then
			CloseUI()
		end
	end
end)

local function bindViewportWatcher()
	local camera = workspace.CurrentCamera
	if not camera then
		return
	end
	camera:GetPropertyChangedSignal("ViewportSize"):Connect(function()
		applyResponsiveLayout()
		if isOpen then
			UpdateDisplay()
		end
	end)
end

workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
	applyResponsiveLayout()
	bindViewportWatcher()
end)
task.defer(function()
	applyResponsiveLayout()
	bindViewportWatcher()
end)

local displayAccumulator = 0
RunService.Heartbeat:Connect(function(step)
	if not isOpen or not currentLift then
		displayAccumulator = 0
		return
	end
	displayAccumulator += step
	if displayAccumulator < 0.15 then return end
	displayAccumulator = 0
	UpdateDisplay()
end)

MainFrame.Visible = false
UpdateLockState()
