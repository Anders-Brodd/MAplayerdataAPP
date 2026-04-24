--[[
    [NOTIFICATION HANDLER - FIXED]
    > Mode indicator starts HIDDEN
    > Better positioning (doesn't cover TopBar)
    > Studio-safe
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local Events = ReplicatedStorage:WaitForChild("Events", 10)
if not Events then return end

local NotificationEvent = Events:WaitForChild("NotificationEvent")
local CompensationModalEvent = Events:WaitForChild("CompensationModalEvent", 10)
local CompensationModalAck = Events:WaitForChild("CompensationModalAck", 10)
local Player = Players.LocalPlayer
local PlayerGui = Player:WaitForChild("PlayerGui")

-- // BRIDGE //
local ClientNotification = ReplicatedStorage:FindFirstChild("ClientNotification")
if not ClientNotification then
	ClientNotification = Instance.new("BindableEvent")
	ClientNotification.Name = "ClientNotification"
	ClientNotification.Parent = ReplicatedStorage
end

-- // CONFIG //
local THEME = {
	Success = {Color = Color3.fromRGB(85, 255, 127), Icon = "✓"},
	Error = {Color = Color3.fromRGB(255, 85, 85), Icon = "✕"},
	Warning = {Color = Color3.fromRGB(255, 200, 80), Icon = "⚠"},
	Info = {Color = Color3.fromRGB(100, 180, 255), Icon = "ℹ"},
	Positive = {Color = Color3.fromRGB(85, 255, 127), Icon = "✓"},
	Negative = {Color = Color3.fromRGB(255, 85, 85), Icon = "✕"},
	Delete = {Color = Color3.fromRGB(255, 70, 70), Icon = "🗑️"},
	Terraform = {Color = Color3.fromRGB(139, 90, 43), Icon = "🏔️"},
	Build = {Color = Color3.fromRGB(85, 255, 127), Icon = "🔨"},
	Mode = {Color = Color3.fromRGB(111, 66, 193), Icon = "◉"},
	Money = {Color = Color3.fromRGB(85, 255, 127), Icon = "💰"},
	Staff = {Color = Color3.fromRGB(100, 180, 255), Icon = "👷"},
	Placed = {Color = Color3.fromRGB(85, 255, 127), Icon = "✓"},
	Deleted = {Color = Color3.fromRGB(255, 150, 100), Icon = "🗑️"},
}

-- // SETUP GUI //
local ScreenGui = PlayerGui:WaitForChild("NotificationUI")
local Container = ScreenGui:WaitForChild("Container")
local ModeIndicator = ScreenGui:WaitForChild("ModeIndicator")

-- // MODE INDICATOR STATE //
local modeVisible = false

local function ShowModeIndicator(modeType, modeName, subtextStr)
	local theme = THEME[modeType] or THEME.Mode

	ModeIndicator.BackgroundColor3 = theme.Color
	ModeIndicator.Icon.Text = theme.Icon
	ModeIndicator.Title.Text = string.upper(modeName or modeType)
	ModeIndicator.Subtext.Text = subtextStr or "Press ESC to cancel"
	ModeIndicator.Stroke.Color = Color3.new(1, 1, 1)
	ModeIndicator.Stroke.Transparency = 0

	ModeIndicator.Visible = true
	modeVisible = true

	-- Slide down (position below TopBar area)
	TweenService:Create(ModeIndicator, TweenInfo.new(0.25, Enum.EasingStyle.Back), {
		Position = UDim2.new(0.5, -130, 0, 60) -- Below typical TopBar
	}):Play()

	-- Pulse animation
	task.spawn(function()
		while modeVisible do
			TweenService:Create(ModeIndicator.Stroke, TweenInfo.new(0.5), {Transparency = 0.7}):Play()
			task.wait(0.5)
			if not modeVisible then break end
			TweenService:Create(ModeIndicator.Stroke, TweenInfo.new(0.5), {Transparency = 0}):Play()
			task.wait(0.5)
		end
	end)
end

local function HideModeIndicator()
	modeVisible = false

	TweenService:Create(ModeIndicator, TweenInfo.new(0.2, Enum.EasingStyle.Quad), {
		Position = UDim2.new(0.5, -130, 0, -60)
	}):Play()

	task.delay(0.2, function()
		if not modeVisible then
			ModeIndicator.Visible = false
		end
	end)
end

local COMP_MODAL_HIDDEN = UDim2.new(0.5, 0, 1.5, 0)
local COMP_MODAL_SHOWN = UDim2.new(0.5, 0, 0.5, 0)
local COMP_MODAL_SHOW_TWEEN = TweenInfo.new(0.35, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local COMP_MODAL_HIDE_TWEEN = TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.In)

local activeCompensationModal = nil
local compensationInputConn = nil
local closedCompensationGrantIds = {}

local function getCompensationTemplate()
	local mainHUD = PlayerGui:FindFirstChild("MainHUD") or PlayerGui:WaitForChild("MainHUD", 10)
	if not mainHUD then
		return nil, nil
	end
	local tutorial = mainHUD:FindFirstChild("Tutorial")
	if not tutorial then
		return nil, nil
	end
	local template = tutorial:FindFirstChild("SkipConfirmation")
	if not template then
		return nil, nil
	end
	return template, mainHUD
end

local function closeCompensationModal(grantId)
	if compensationInputConn then
		compensationInputConn:Disconnect()
		compensationInputConn = nil
	end
	if not activeCompensationModal then
		return
	end

	local modal = activeCompensationModal
	activeCompensationModal = nil

	local tween = TweenService:Create(modal, COMP_MODAL_HIDE_TWEEN, {Position = COMP_MODAL_HIDDEN})
	tween.Completed:Once(function()
		if modal and modal.Parent then
			modal:Destroy()
		end
	end)
	tween:Play()

	if grantId and grantId ~= "" then
		closedCompensationGrantIds[grantId] = true
		if CompensationModalAck and CompensationModalAck:IsA("RemoteEvent") then
			CompensationModalAck:FireServer(grantId)
		end
	end
end

local function bindCompensationCloseButton(button, grantId, buttonText)
	if not button or not button:IsA("GuiButton") then
		return
	end
	button.Visible = true
	button.Active = true
	button.Selectable = true
	button.AutoButtonColor = true
	if type(buttonText) == "string" and buttonText ~= "" then
		button.Text = buttonText
	end
	local function onCloseRequest()
		closeCompensationModal(grantId)
	end
	button.Activated:Connect(onCloseRequest)
	button.MouseButton1Click:Connect(onCloseRequest)
end

local function showCompensationModal(grantId, title, message, amount)
	local normalizedGrantId = tostring(grantId or "")
	if normalizedGrantId ~= "" and closedCompensationGrantIds[normalizedGrantId] then
		return
	end
	if activeCompensationModal then
		return
	end

	local template, mainHUD = getCompensationTemplate()
	if not template or not mainHUD then
		return
	end

	local modal = template:Clone()
	modal.Name = "CompensationModal"
	modal.AnchorPoint = Vector2.new(0.5, 0.5)
	modal.Size = UDim2.new(0.58, 0, 0.5, 0)
	modal.Position = COMP_MODAL_HIDDEN
	modal.ZIndex = 80
	modal.Active = true
	modal.Parent = mainHUD
	modal.Visible = true
	local parentGui = modal:FindFirstAncestorWhichIsA("ScreenGui")
	if parentGui then
		parentGui.DisplayOrder = math.max(parentGui.DisplayOrder, 1000000)
		parentGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	end
	activeCompensationModal = modal

	local header = modal:FindFirstChild("Header")
	local headerTitle = nil
	if header then
		headerTitle = header:FindFirstChild("TextLabel")
			or header:FindFirstChild("TextLabel_Title")
			or header:FindFirstChild("Title")
			or header:FindFirstChildWhichIsA("TextLabel")
	end
	if headerTitle and headerTitle:IsA("TextLabel") then
		headerTitle.Text = (type(title) == "string" and title ~= "") and title or "$1,000,000 COMPENSATION"
	end

	local mainText = modal:FindFirstChild("MainText")
	if mainText then
		local amountText = typeof(amount) == "number" and string.format("$%s", tostring(math.floor(amount + 0.5))) or "$1,000,000"
		mainText.Text = (message or "Sorry for the money-loss issues. Existing affected saves receive $1,000,000 in compensation. New saves are not eligible.") .. "\n\nCompensation Added: " .. amountText
	end

	local buttons = modal:FindFirstChild("Buttons")
	if buttons then
		local primaryClose = nil
		for _, desc in ipairs(buttons:GetDescendants()) do
			if desc:IsA("GuiButton") then
				if not primaryClose then
					primaryClose = desc
				end
				bindCompensationCloseButton(desc, normalizedGrantId)
			end
		end
		if primaryClose then
			primaryClose.Text = "CLOSE"
			primaryClose.BackgroundColor3 = Color3.fromRGB(70, 170, 110)
		end
	end

	local headerClose = header and (header:FindFirstChild("CloseButton") or header:FindFirstChild("CloseBtn"))
	if headerClose and headerClose:IsA("GuiButton") then
		bindCompensationCloseButton(headerClose, normalizedGrantId)
	end

	if UserInputService and UserInputService.TouchEnabled then
		local mobileClose = Instance.new("TextButton")
		mobileClose.Name = "MobileCloseButton"
		mobileClose.AnchorPoint = Vector2.new(0.5, 1)
		mobileClose.Position = UDim2.new(0.5, 0, 1, -88)
		mobileClose.Size = UDim2.new(0, 220, 0, 56)
		mobileClose.BackgroundColor3 = Color3.fromRGB(70, 170, 110)
		mobileClose.BorderSizePixel = 0
		mobileClose.Font = Enum.Font.GothamBold
		mobileClose.Text = "CLOSE"
		mobileClose.TextColor3 = Color3.new(1, 1, 1)
		mobileClose.TextSize = 20
		mobileClose.ZIndex = math.max(modal.ZIndex + 4, 84)
		Instance.new("UICorner", mobileClose).CornerRadius = UDim.new(0, 12)
		mobileClose.Parent = modal
		bindCompensationCloseButton(mobileClose, normalizedGrantId)
	end

	compensationInputConn = UserInputService.InputBegan:Connect(function(input, gameProcessed)
		local dismiss = input.KeyCode == Enum.KeyCode.Escape or input.KeyCode == Enum.KeyCode.ButtonB
		if dismiss then
			closeCompensationModal(normalizedGrantId)
			return
		end
		if gameProcessed then
			return
		end
	end)

	TweenService:Create(modal, COMP_MODAL_SHOW_TWEEN, {Position = COMP_MODAL_SHOWN}):Play()
end

-- // TOAST NOTIFICATION //
local toastCount = 0

local function resolveTeleportTarget(actionData)
	if type(actionData) ~= "table" then
		return nil
	end
	local target = actionData.TargetCFrame or actionData.TargetPosition or actionData.Position
	if typeof(target) == "CFrame" then
		return target.Position
	end
	if typeof(target) == "Vector3" then
		return target
	end
	if type(target) == "table" then
		local x = tonumber(target.X or target.x)
		local y = tonumber(target.Y or target.y)
		local z = tonumber(target.Z or target.z)
		if x and y and z then
			return Vector3.new(x, y, z)
		end
	end
	local x = tonumber(actionData.X or actionData.x)
	local y = tonumber(actionData.Y or actionData.y)
	local z = tonumber(actionData.Z or actionData.z)
	if x and y and z then
		return Vector3.new(x, y, z)
	end
	return nil
end

local function performNotificationAction(actionData)
	if type(actionData) ~= "table" then
		return false
	end
	if tostring(actionData.ActionType or actionData.Type or "") ~= "Teleport" then
		return false
	end
	local destination = resolveTeleportTarget(actionData)
	if not destination then
		return false
	end
	local character = Player.Character
	local root = character and (character:FindFirstChild("HumanoidRootPart") or character.PrimaryPart)
	if not root then
		return false
	end
	local offset = Vector3.new(0, tonumber(actionData.HeightOffset) or 4, 0)
	character:PivotTo(CFrame.new(destination + offset))
	return true
end

local function spawnNotification(notifType, titleOrMsg, msgOrDuration, durationArg, actionArg)
	-- Handle mode indicator special calls
	if notifType == "ShowMode" then
		ShowModeIndicator(titleOrMsg, msgOrDuration, durationArg)
		return
	elseif notifType == "HideMode" then
		HideModeIndicator()
		return
	end

	-- Parse arguments
	local title = "Notification"
	local message = ""
	local duration = 4
	local actionData = nil
	local theme = THEME[notifType] or THEME.Info

	if typeof(titleOrMsg) == "string" and typeof(msgOrDuration) == "string" then
		title = titleOrMsg
		message = msgOrDuration
		if typeof(durationArg) == "number" then
			duration = durationArg
		elseif typeof(durationArg) == "table" then
			actionData = durationArg
		end
		if typeof(actionArg) == "table" then
			actionData = actionArg
		end
	elseif typeof(titleOrMsg) == "string" and typeof(msgOrDuration) == "number" then
		message = titleOrMsg
		duration = msgOrDuration
		if typeof(durationArg) == "table" then
			actionData = durationArg
		end
	elseif typeof(titleOrMsg) == "string" and msgOrDuration == nil then
		message = titleOrMsg
		if typeof(durationArg) == "table" then
			actionData = durationArg
		end
	end

	toastCount = toastCount + 1
	local order = toastCount

	local Frame = Instance.new("CanvasGroup")
	Frame.Name = "Toast_" .. order
	Frame.Size = UDim2.new(1, 0, 0, 0)
	Frame.BackgroundColor3 = Color3.fromRGB(25, 25, 30)
	Frame.BackgroundTransparency = 0.05
	Frame.BorderSizePixel = 0
	Frame.ClipsDescendants = true
	Frame.LayoutOrder = order
	Frame.Parent = Container

	Instance.new("UICorner", Frame).CornerRadius = UDim.new(0.1, 0)

	local Strip = Instance.new("Frame", Frame)
	Strip.Size = UDim2.new(0, 5, 1, 0)
	Strip.BackgroundColor3 = theme.Color
	Strip.BorderSizePixel = 0
	Instance.new("UICorner", Strip).CornerRadius = UDim.new(0.2, 0)

	local IconBg = Instance.new("Frame", Frame)
	IconBg.Size = UDim2.new(0, 30, 0, 30)
	IconBg.Position = UDim2.new(0, 12, 0, 10)
	IconBg.BackgroundColor3 = theme.Color
	IconBg.BorderSizePixel = 0
	Instance.new("UICorner", IconBg).CornerRadius = UDim.new(0.1, 0)

	local IconLbl = Instance.new("TextLabel", IconBg)
	IconLbl.Size = UDim2.new(1, 0, 1, 0)
	IconLbl.BackgroundTransparency = 1
	IconLbl.Text = theme.Icon or "ℹ"
	IconLbl.TextSize = 14
	IconLbl.Font = Enum.Font.GothamBold
	IconLbl.TextColor3 = Color3.new(1, 1, 1)

	local TitleLbl = Instance.new("TextLabel", Frame)
	TitleLbl.Size = UDim2.new(1, -55, 0, 18)
	TitleLbl.Position = UDim2.new(0, 50, 0, 8)
	TitleLbl.BackgroundTransparency = 1
	TitleLbl.Text = title
	TitleLbl.TextColor3 = Color3.new(1, 1, 1)
	TitleLbl.Font = Enum.Font.GothamBold
	TitleLbl.TextSize = 13
	TitleLbl.TextXAlignment = Enum.TextXAlignment.Left
	TitleLbl.TextTruncate = Enum.TextTruncate.AtEnd

	local MsgLbl = Instance.new("TextLabel", Frame)
	MsgLbl.Size = UDim2.new(1, -55, 0, 25)
	MsgLbl.Position = UDim2.new(0, 50, 0, 25)
	MsgLbl.BackgroundTransparency = 1
	MsgLbl.Text = message
	MsgLbl.TextColor3 = Color3.fromRGB(180, 180, 180)
	MsgLbl.Font = Enum.Font.Gotham
	MsgLbl.TextSize = 12
	MsgLbl.TextWrapped = true
	MsgLbl.TextXAlignment = Enum.TextXAlignment.Left

	local actionButton = nil
	if type(actionData) == "table" and tostring(actionData.ActionType or actionData.Type or "") == "Teleport" then
		actionButton = Instance.new("TextButton")
		actionButton.Name = "ActionButton"
		actionButton.Parent = Frame
		actionButton.Size = UDim2.new(0, 86, 0, 22)
		actionButton.Position = UDim2.new(1, -96, 1, -28)
		actionButton.BackgroundColor3 = Color3.fromRGB(62, 133, 255)
		actionButton.BorderSizePixel = 0
		actionButton.Font = Enum.Font.GothamBold
		actionButton.TextSize = 11
		actionButton.TextColor3 = Color3.new(1, 1, 1)
		actionButton.Text = tostring(actionData.Label or "Go To")
		actionButton.AutoButtonColor = true
		Instance.new("UICorner", actionButton).CornerRadius = UDim.new(0, 6)
		actionButton.MouseButton1Click:Connect(function()
			if performNotificationAction(actionData) then
				if Frame and Frame.Parent then
					Frame:Destroy()
				end
			end
		end)
	end

	local targetHeight = 58
	if #message > 50 then targetHeight = 75 end
	if actionButton then targetHeight = math.max(targetHeight, 82) end

	TweenService:Create(Frame, TweenInfo.new(0.3, Enum.EasingStyle.Back), {
		Size = UDim2.new(1, 0, 0, targetHeight)
	}):Play()

	-- Sound
	local soundId = "rbxassetid://6895079853"
	if notifType == "Error" or notifType == "Negative" then
		soundId = "rbxassetid://550209561"
	end

	local sound = Instance.new("Sound", Frame)
	sound.SoundId = soundId
	sound.Volume = 0.3
	sound:Play()

	task.delay(duration, function()
		if not Frame or not Frame.Parent then return end

		local fadeInfo = TweenInfo.new(0.25)
		TweenService:Create(Frame, fadeInfo, {BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0)}):Play()
		TweenService:Create(TitleLbl, fadeInfo, {TextTransparency = 1}):Play()
		TweenService:Create(MsgLbl, fadeInfo, {TextTransparency = 1}):Play()
		TweenService:Create(Strip, fadeInfo, {BackgroundTransparency = 1}):Play()
		TweenService:Create(IconBg, fadeInfo, {BackgroundTransparency = 1}):Play()
		TweenService:Create(IconLbl, fadeInfo, {TextTransparency = 1}):Play()

		task.wait(0.25)
		Frame:Destroy()
	end)
end

-- // GLOBAL ACCESS //
_G.Notify = {
	Toast = spawnNotification,
	Success = function(title, msg, dur) spawnNotification("Success", title, msg, dur) end,
	Error = function(title, msg, dur) spawnNotification("Error", title, msg, dur) end,
	Warning = function(title, msg, dur) spawnNotification("Warning", title, msg, dur) end,
	Info = function(title, msg, dur) spawnNotification("Info", title, msg, dur) end,

	ShowMode = ShowModeIndicator,
	HideMode = HideModeIndicator,

	DeleteModeOn = function()
		ShowModeIndicator("Delete", "DELETE MODE", "Click to delete • ESC to cancel")
		spawnNotification("Delete", "Delete Mode", "Click objects to remove", 2)
	end,
	DeleteModeOff = function()
		HideModeIndicator()
		spawnNotification("Info", "Exited", "Delete mode off", 1.5)
	end,
	TerraformModeOn = function()
		ShowModeIndicator("Terraform", "TERRAFORM", "Shape terrain • ESC to cancel")
		spawnNotification("Terraform", "Terraform", "Modify terrain", 2)
	end,
	TerraformModeOff = function()
		HideModeIndicator()
		spawnNotification("Info", "Exited", "Terraform mode off", 1.5)
	end,
	BuildModeOn = function(itemName)
		ShowModeIndicator("Build", itemName or "BUILD", "Click to place • R rotate • ESC cancel")
		spawnNotification("Build", "Placing", itemName or "item", 2)
	end,
	BuildModeOff = function()
		HideModeIndicator()
	end,
	ItemPlaced = function(name, cost)
		HideModeIndicator()
		local msg = (name or "Item") .. " placed"
		if cost then msg = msg .. " (-$" .. cost .. ")" end
		spawnNotification("Success", "Placed!", msg, 2)
	end,
	ItemDeleted = function(name)
		spawnNotification("Deleted", "Deleted", (name or "Object") .. " removed", 2)
	end,
	NotEnoughMoney = function(cost)
		spawnNotification("Error", "Not Enough Money", "Need $" .. (cost or "more"), 3)
	end,
	MoneyEarned = function(amount, source)
		local msg = "+$" .. amount
		if source then msg = msg .. " from " .. source end
		spawnNotification("Money", "Money Earned", msg, 2)
	end,
	StaffHired = function(name)
		spawnNotification("Staff", "Hired", (name or "Employee") .. " joined!", 3)
	end,
	StaffUpgraded = function(name, level)
		spawnNotification("Staff", "Upgraded", (name or "Employee") .. " → Lv" .. (level or "?"), 3)
	end,
}

NotificationEvent.OnClientEvent:Connect(spawnNotification)
ClientNotification.Event:Connect(spawnNotification)
if CompensationModalEvent and CompensationModalEvent:IsA("RemoteEvent") then
	CompensationModalEvent.OnClientEvent:Connect(showCompensationModal)
end