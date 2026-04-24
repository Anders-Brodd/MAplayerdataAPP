--[=[ PATH: StarterPlayerScripts/LiftCommandController | TYPE: LocalScript ]=]--
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local MarketplaceService = game:GetService("MarketplaceService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")
local EntitlementManager = require(ReplicatedStorage:WaitForChild("EntitlementManager"))
local EntitlementEvents = ReplicatedStorage:FindFirstChild("EntitlementEvents")
local EntitlementChanged = EntitlementEvents and EntitlementEvents:FindFirstChild("EntitlementChanged")

local Player = Players.LocalPlayer
local PlayerGui = Player:WaitForChild("PlayerGui")
local Events = ReplicatedStorage:WaitForChild("Events")
local ControlEvent = Events:WaitForChild("LiftControlEvent")
local RenamePlacedObject = Events:WaitForChild("RenamePlacedObject", 10)

local GAMEPASS_ID = 1704778044 -- Gamepass ID
local GROUP_ID = 398051359
local MIN_RANK = 240

-- // UI REFERENCES //
local ScreenGui = PlayerGui:WaitForChild("LiftCommandUI", 10)
if not ScreenGui then warn("[LiftCommandController] LiftCommandUI not found") return end
local MainFrame = ScreenGui:WaitForChild("MainFrame")
local Container = MainFrame:WaitForChild("Container")
local Header = MainFrame:WaitForChild("Header")
local CloseButton = Header:WaitForChild("CloseButton")
local Template = ScreenGui:WaitForChild("LiftTemplate")

-- State
local hasPremium = false
local isMenuOpen = false
local OPEN_POSITION = MainFrame.Position
local CLOSED_POSITION = UDim2.new(OPEN_POSITION.X.Scale, OPEN_POSITION.X.Offset, 1.5, OPEN_POSITION.Y.Offset)
local OPEN_TWEEN = TweenInfo.new(0.3, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local CLOSE_TWEEN = TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.In)

local ClosePanels = Events:FindFirstChild("ClosePanels")
if not ClosePanels then
	ClosePanels = Instance.new("BindableEvent")
	ClosePanels.Name = "ClosePanels"
	ClosePanels.Parent = Events
end

MainFrame.Visible = false
MainFrame.Position = CLOSED_POSITION

local function setMenuState(open)
	if isMenuOpen == open and MainFrame.Visible == open then
		return
	end

	isMenuOpen = open
	if open then
		ClosePanels:Fire("LiftListLegacy")
		MainFrame.Visible = true
		MainFrame.Position = CLOSED_POSITION
		TweenService:Create(MainFrame, OPEN_TWEEN, {Position = OPEN_POSITION}):Play()
		return
	end

	local tween = TweenService:Create(MainFrame, CLOSE_TWEEN, {Position = CLOSED_POSITION})
	tween:Play()
	tween.Completed:Once(function()
		if not isMenuOpen then
			MainFrame.Visible = false
		end
	end)
end

local function bindGuiButton(button, callback)
	if not (button and callback) then return end
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
			local inputType = input.UserInputType
			if inputType == Enum.UserInputType.Touch or inputType == Enum.UserInputType.MouseButton1 then
				fire()
			end
		end)
	end
end

local function sanitizeCustomName(raw)
	local text = tostring(raw or "")
	text = text:gsub("[%c]", " ")
	text = text:gsub("%s+", " ")
	text = text:gsub("^%s+", "")
	text = text:gsub("%s+$", "")
	if #text > 48 then
		text = string.sub(text, 1, 48)
	end
	return text
end

local function getLiftDisplayName(lift)
	local customName = sanitizeCustomName(lift and lift:GetAttribute("CustomName") or "")
	if customName ~= "" then
		return customName
	end
	return sanitizeCustomName(lift and lift.Name or "Lift")
end

-- // CHECK PERMISSIONS (Pass OR Rank) //
local function CheckAccess()
	hasPremium = false

	-- 1. Check Group Rank
	local success, rank = pcall(function() return Player:GetRankInGroup(GROUP_ID) end)
	if success and rank and rank >= MIN_RANK then
		hasPremium = true
		return
	end

	-- 2. Check Gamepass
	local passSuccess, result = pcall(function()
		return EntitlementManager.HasAccess(Player.UserId, GAMEPASS_ID)
	end)
	if passSuccess and result then
		hasPremium = true
	end
end
CheckAccess()

-- // HELPER: REFRESH LIST //
local function RefreshList()
	-- Clear old items
	for _, child in ipairs(Container:GetChildren()) do
		if child:IsA("Frame") then child:Destroy() end
	end

	-- Ensure Container has a layout with proper spacing
	if not Container:FindFirstChildOfClass("UIListLayout") then
		local layout = Instance.new("UIListLayout")
		layout.Padding = UDim.new(0, 8)
		layout.SortOrder = Enum.SortOrder.LayoutOrder
		layout.Parent = Container
	end
	if not Container:FindFirstChildOfClass("UIPadding") then
		local pad = Instance.new("UIPadding")
		pad.PaddingTop = UDim.new(0, 6)
		pad.PaddingBottom = UDim.new(0, 6)
		pad.PaddingLeft = UDim.new(0, 6)
		pad.PaddingRight = UDim.new(0, 6)
		pad.Parent = Container
	end

	local Placed = Workspace:FindFirstChild("PlacedObjects")
	if not Placed then return end

	for _, lift in ipairs(Placed:GetChildren()) do
		-- Only show actual Lifts (Type = TwoPoint or Carpet)
		local liftType = lift:GetAttribute("Type")
		if lift:IsA("Model") and lift:GetAttribute("UUID") and (liftType == "TwoPoint" or liftType == "Carpet") then

			local card = Template:Clone()
			card.Name = lift.Name
			card.Visible = true
			card.Parent = Container

			-- References
			local StatusLbl = card.Status
			card.LiftName.Size = UDim2.new(0.42, 0, 0, 22)
			card.LiftName.TextSize = 14
			card.LiftName.TextWrapped = true
			card.LiftName.TextXAlignment = Enum.TextXAlignment.Left

			StatusLbl.Size = UDim2.new(0.42, 0, 0, 16)
			StatusLbl.TextSize = 11

			local NameBox = Instance.new("TextBox")
			NameBox.Name = "NameBox"
			NameBox.BackgroundColor3 = Color3.fromRGB(28, 33, 41)
			NameBox.BorderSizePixel = 0
			NameBox.ClearTextOnFocus = false
			NameBox.Font = Enum.Font.Gotham
			NameBox.PlaceholderColor3 = Color3.fromRGB(139, 151, 173)
			NameBox.Position = UDim2.new(0.023, 0, 0.30, 0)
			NameBox.Size = UDim2.new(0.42, 0, 0, 24)
			NameBox.Text = ""
			NameBox.TextColor3 = Color3.fromRGB(240, 244, 255)
			NameBox.TextSize = 12
			NameBox.TextXAlignment = Enum.TextXAlignment.Left
			NameBox.Parent = card
			local nameCorner = Instance.new("UICorner")
			nameCorner.CornerRadius = UDim.new(0, 7)
			nameCorner.Parent = NameBox
			local namePadding = Instance.new("UIPadding")
			namePadding.PaddingLeft = UDim.new(0, 8)
			namePadding.PaddingRight = UDim.new(0, 8)
			namePadding.Parent = NameBox

			local function commitLiftRename()
				if not RenamePlacedObject then
					return
				end
				local requestedName = sanitizeCustomName(NameBox.Text)
				local currentName = sanitizeCustomName(lift:GetAttribute("CustomName"))
				if requestedName == currentName then
					return
				end
				RenamePlacedObject:FireServer(lift, requestedName)
			end

			local function UpdateLiftName()
				card.LiftName.Text = getLiftDisplayName(lift)
				if NameBox and not NameBox:IsFocused() then
					NameBox.Text = sanitizeCustomName(lift:GetAttribute("CustomName"))
				end
				NameBox.PlaceholderText = sanitizeCustomName(lift.Name)
			end
			UpdateLiftName()
			lift:GetAttributeChangedSignal("CustomName"):Connect(UpdateLiftName)
			NameBox.FocusLost:Connect(function()
				commitLiftRename()
			end)

			local function UpdateStatus()
				local status = lift:GetAttribute("Status") or "Stopped"
				StatusLbl.Text = "Status: " .. status
				if status == "Running" then StatusLbl.TextColor3 = Color3.fromRGB(85, 255, 127)
				elseif status == "Broken" then StatusLbl.TextColor3 = Color3.fromRGB(255, 85, 85)
				elseif status == "Slow" then StatusLbl.TextColor3 = Color3.fromRGB(255, 170, 0)
				else StatusLbl.TextColor3 = Color3.fromRGB(150, 150, 150) end
			end
			UpdateStatus()
			lift:GetAttributeChangedSignal("Status"):Connect(UpdateStatus)

			-- Standard Buttons
			local Std = card.StandardFrame
			bindGuiButton(Std.StartBtn, function() ControlEvent:FireServer("Start", lift) end)
			bindGuiButton(Std.StopBtn, function() ControlEvent:FireServer("Stop", lift) end)

			-- Premium Section
			local Prem = card.PremiumFrame

			-- [[ FIX: FIND LOCK OVERLAY CORRECTLY ]]
			-- It is a child of the CARD, not the PremiumFrame, based on your screenshot
			local Lock = card:FindFirstChild("LockOverlay") 

			if not hasPremium then
				-- SHOW OVERLAY (Locked)
				if Lock then
					Lock.Visible = true
					local unlockBtn = Lock:FindFirstChild("UnlockButton")
					if unlockBtn then
						bindGuiButton(unlockBtn, function()
							MarketplaceService:PromptGamePassPurchase(Player, GAMEPASS_ID)
						end)
					end
				end
			else
				-- HIDE OVERLAY (Unlocked)
				if Lock then Lock.Visible = false end

				-- Premium Logic (Only connects if unlocked)
				bindGuiButton(Prem.RepairBtn, function() ControlEvent:FireServer("Repair", lift) end)
				bindGuiButton(Prem.SlowBtn, function() ControlEvent:FireServer("Slow", lift) end)
				local function UpdateSlowButton()
					local status = lift:GetAttribute("Status") or "Stopped"
					Prem.SlowBtn.Text = (status == "Slow") and "RESUME" or "SLOW"
					Prem.SlowBtn.BackgroundColor3 = (status == "Slow") and Color3.fromRGB(85, 170, 255) or Color3.fromRGB(255, 170, 0)
				end
				UpdateSlowButton()
				lift:GetAttributeChangedSignal("Status"):Connect(UpdateSlowButton)

				-- Seats Toggle
				local seatsDisabled = lift:GetAttribute("DisableSeats") == true
				local function UpdateSeats()
					Prem.NoSeatsBtn.Text = seatsDisabled and "NO SEATS: ON" or "NO SEATS: OFF"
					Prem.NoSeatsBtn.BackgroundColor3 = seatsDisabled and Color3.fromRGB(255, 85, 85) or Color3.fromRGB(80,80,80)
				end
				UpdateSeats()
				bindGuiButton(Prem.NoSeatsBtn, function()
					ControlEvent:FireServer("ToggleSeats", lift)
					seatsDisabled = not seatsDisabled
					UpdateSeats()
				end)

				-- Doors Toggle
				local doorsClosed = lift:GetAttribute("CloseDoors") == true
				local function UpdateDoors()
					Prem.CloseDoorsBtn.Text = doorsClosed and "DOORS: SHUT" or "DOORS: OPEN"
					Prem.CloseDoorsBtn.BackgroundColor3 = doorsClosed and Color3.fromRGB(255, 85, 85) or Color3.fromRGB(80,80,80)
				end
				UpdateDoors()
				bindGuiButton(Prem.CloseDoorsBtn, function()
					ControlEvent:FireServer("ToggleDoors", lift)
					doorsClosed = not doorsClosed
					UpdateDoors()
				end)
			end
		end
	end
end

-- // PURCHASE SUCCESS //
MarketplaceService.PromptGamePassPurchaseFinished:Connect(function(player, passId, wasPurchased)
	if player == Player and passId == GAMEPASS_ID and wasPurchased then
		CheckAccess()
		RefreshList()
	end
end)

if EntitlementChanged and EntitlementChanged:IsA("RemoteEvent") then
	EntitlementChanged.OnClientEvent:Connect(function(payload)
		if type(payload) ~= "table" or tonumber(payload.userId) ~= Player.UserId then
			return
		end
		CheckAccess()
		if isMenuOpen then
			RefreshList()
		end
	end)
end

local mainHud = PlayerGui:WaitForChild("MainHUD", 10)
local dock = mainHud and mainHud:WaitForChild("Dock", 10)
local liftsButton = dock and dock:FindFirstChild("Lifts")
if liftsButton and liftsButton:IsA("GuiButton") then
	bindGuiButton(liftsButton, function()
		if not isMenuOpen then
			RefreshList()
		end
		setMenuState(not isMenuOpen)
	end)
	liftsButton.Active = true
	liftsButton.Selectable = true
end

ClosePanels.Event:Connect(function(source)
	if source == "LiftListLegacy" then return end
	if isMenuOpen then
		setMenuState(false)
	end
end)

bindGuiButton(CloseButton, function()
	setMenuState(false)
end)

UserInputService.InputBegan:Connect(function(input, gameProcessed)
	if gameProcessed then return end
	if input.KeyCode ~= Enum.KeyCode.Escape then return end
	if isMenuOpen then
		setMenuState(false)
	end
end)
