local Players = game:GetService("Players")
local ProximityPromptService = game:GetService("ProximityPromptService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")

local Player = Players.LocalPlayer
local PlayerGui = Player:WaitForChild("PlayerGui")

local screenGui = Instance.new("ScreenGui")
screenGui.Name = "SpillPromptUI"
screenGui.ResetOnSpawn = false
screenGui.IgnoreGuiInset = true
screenGui.DisplayOrder = 90
screenGui.Parent = PlayerGui

local frame = Instance.new("Frame")
frame.Name = "PromptFrame"
frame.AnchorPoint = Vector2.new(0.5, 1)
frame.Position = UDim2.new(0.5, 0, 0.91, 0)
frame.Size = UDim2.new(0, 260, 0, 86)
frame.BackgroundColor3 = Color3.fromRGB(21, 26, 30)
frame.BackgroundTransparency = 0.12
frame.Visible = false
frame.Parent = screenGui

local frameScale = Instance.new("UIScale")
frameScale.Scale = 0.97
frameScale.Parent = frame

local corner = Instance.new("UICorner")
corner.CornerRadius = UDim.new(0, 14)
corner.Parent = frame

local stroke = Instance.new("UIStroke")
stroke.Color = Color3.fromRGB(96, 191, 205)
stroke.Thickness = 1.5
stroke.Transparency = 0.15
stroke.Parent = frame

local keyChip = Instance.new("TextLabel")
keyChip.Name = "KeyChip"
keyChip.AnchorPoint = Vector2.new(0, 0.5)
keyChip.Position = UDim2.new(0, 12, 0.5, -10)
keyChip.Size = UDim2.new(0, 52, 0, 34)
keyChip.BackgroundColor3 = Color3.fromRGB(34, 46, 55)
keyChip.TextColor3 = Color3.fromRGB(245, 252, 255)
keyChip.Font = Enum.Font.GothamBold
keyChip.TextScaled = true
keyChip.Text = "E"
keyChip.Parent = frame

local keyCorner = Instance.new("UICorner")
keyCorner.CornerRadius = UDim.new(0, 10)
keyCorner.Parent = keyChip

local title = Instance.new("TextLabel")
title.Name = "Title"
title.BackgroundTransparency = 1
title.Position = UDim2.new(0, 78, 0, 12)
title.Size = UDim2.new(1, -90, 0, 22)
title.Font = Enum.Font.GothamBold
title.TextColor3 = Color3.fromRGB(244, 248, 250)
title.TextXAlignment = Enum.TextXAlignment.Left
title.TextSize = 18
title.Text = "Clean Spill"
title.Parent = frame

local hint = Instance.new("TextLabel")
hint.Name = "Hint"
hint.BackgroundTransparency = 1
hint.Position = UDim2.new(0, 78, 0, 34)
hint.Size = UDim2.new(1, -90, 0, 18)
hint.Font = Enum.Font.Gotham
hint.TextColor3 = Color3.fromRGB(176, 188, 194)
hint.TextXAlignment = Enum.TextXAlignment.Left
hint.TextSize = 13
hint.Text = "Hold to mop this mess"
hint.Parent = frame

local barBack = Instance.new("Frame")
barBack.Name = "BarBack"
barBack.Position = UDim2.new(0, 78, 1, -18)
barBack.Size = UDim2.new(1, -94, 0, 8)
barBack.BackgroundColor3 = Color3.fromRGB(38, 50, 56)
barBack.Parent = frame

local barBackCorner = Instance.new("UICorner")
barBackCorner.CornerRadius = UDim.new(1, 0)
barBackCorner.Parent = barBack

local barFill = Instance.new("Frame")
barFill.Name = "BarFill"
barFill.Size = UDim2.new(0, 0, 1, 0)
barFill.BackgroundColor3 = Color3.fromRGB(100, 219, 190)
barFill.Parent = barBack

local barFillCorner = Instance.new("UICorner")
barFillCorner.CornerRadius = UDim.new(1, 0)
barFillCorner.Parent = barFill

local holdButton = Instance.new("TextButton")
holdButton.Name = "HoldButton"
holdButton.AnchorPoint = Vector2.new(1, 0.5)
holdButton.Position = UDim2.new(1, -12, 0.5, -10)
holdButton.Size = UDim2.new(0, 66, 0, 32)
holdButton.BackgroundColor3 = Color3.fromRGB(34, 46, 55)
holdButton.TextColor3 = Color3.fromRGB(232, 246, 250)
holdButton.Font = Enum.Font.GothamBold
holdButton.TextSize = 14
holdButton.Text = "HOLD"
holdButton.Visible = false
holdButton.Parent = frame

local holdCorner = Instance.new("UICorner")
holdCorner.CornerRadius = UDim.new(0, 10)
holdCorner.Parent = holdButton

local currentPrompt = nil
local currentInputType = nil
local renderConnection = nil
local holdStart = nil
local promptConnections = {}
local promptTweenToken = 0

local VISIBLE_POSITION = UDim2.new(0.5, 0, 0.88, 0)
local HIDDEN_POSITION = UDim2.new(0.5, 0, 0.91, 0)

local function disconnectPromptConnections()
	for _, connection in ipairs(promptConnections) do
		connection:Disconnect()
	end
	table.clear(promptConnections)
end

local function animatePromptFrame(visible)
	promptTweenToken += 1
	local tweenToken = promptTweenToken
	if visible then
		frame.Visible = true
		frame.Position = HIDDEN_POSITION
		frameScale.Scale = 0.97
		TweenService:Create(frame, TweenInfo.new(0.16, Enum.EasingStyle.Quart, Enum.EasingDirection.Out), {Position = VISIBLE_POSITION}):Play()
		TweenService:Create(frameScale, TweenInfo.new(0.16, Enum.EasingStyle.Quart, Enum.EasingDirection.Out), {Scale = 1}):Play()
		return
	end
	TweenService:Create(frame, TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {Position = HIDDEN_POSITION}):Play()
	TweenService:Create(frameScale, TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {Scale = 0.97}):Play()
	task.delay(0.13, function()
		if promptTweenToken == tweenToken and not currentPrompt then
			frame.Visible = false
		end
	end)
end

local function setProgress(alpha)
	barFill.Size = UDim2.new(math.clamp(alpha, 0, 1), 0, 1, 0)
end

local function stopProgress()
	holdStart = nil
	if renderConnection then
		renderConnection:Disconnect()
		renderConnection = nil
	end
	stroke.Transparency = 0.15
	setProgress(0)
end

local function beginProgress(prompt)
	stopProgress()
	holdStart = os.clock()
	renderConnection = RunService.RenderStepped:Connect(function()
		if currentPrompt ~= prompt then
			return
		end
		local pulse = 0.08 + (math.abs(math.sin(os.clock() * 3.4)) * 0.14)
		stroke.Transparency = pulse
		if not holdStart then
			return
		end
		local holdDuration = math.max(0.05, tonumber(prompt.HoldDuration) or 1)
		setProgress((os.clock() - holdStart) / holdDuration)
	end)
end

local function hidePrompt()
	stopProgress()
	disconnectPromptConnections()
	currentPrompt = nil
	currentInputType = nil
	animatePromptFrame(false)
end

local function getKeyText(prompt, inputType)
	if inputType == Enum.ProximityPromptInputType.Touch then
		return "TAP"
	elseif inputType == Enum.ProximityPromptInputType.Gamepad then
		return "X"
	end
	local keyCode = prompt.KeyboardKeyCode
	if keyCode and keyCode ~= Enum.KeyCode.Unknown then
		local ok, keyName = pcall(function()
			return UserInputService:GetStringForKeyCode(keyCode)
		end)
		if ok and keyName and keyName ~= "" then
			return string.upper(keyName)
		end
		return keyCode.Name
	end
	return "E"
end

local function getHintText(inputType)
	if inputType == Enum.ProximityPromptInputType.Touch then
		return "Hold the button to mop this mess"
	elseif inputType == Enum.ProximityPromptInputType.Gamepad then
		return "Hold X to mop this mess"
	end
	return "Hold to mop this mess"
end

local function bindPrompt(prompt)
	table.insert(promptConnections, prompt.PromptButtonHoldBegan:Connect(function()
		beginProgress(prompt)
	end))
	table.insert(promptConnections, prompt.PromptButtonHoldEnded:Connect(function()
		stopProgress()
	end))
	table.insert(promptConnections, prompt.Triggered:Connect(function()
		setProgress(1)
		title.Text = "Cleaning..."
		hint.Text = "Mop in use"
		task.delay(0.25, function()
			if currentPrompt == prompt then
				hidePrompt()
			end
		end)
	end))
	table.insert(promptConnections, prompt.TriggerEnded:Connect(function()
		stopProgress()
	end))
end

local function showPrompt(prompt, inputType)
	hidePrompt()
	currentPrompt = prompt
	currentInputType = inputType
	title.Text = prompt.ActionText ~= "" and prompt.ActionText or "Clean Spill"
	hint.Text = getHintText(inputType)
	keyChip.Text = getKeyText(prompt, inputType)
	holdButton.Visible = (inputType == Enum.ProximityPromptInputType.Touch)
	animatePromptFrame(true)
	bindPrompt(prompt)
end

ProximityPromptService.PromptShown:Connect(function(prompt, inputType)
	if prompt:GetAttribute("IsSpillPrompt") ~= true then
		return
	end
	showPrompt(prompt, inputType)
end)

ProximityPromptService.PromptHidden:Connect(function(prompt)
	if prompt == currentPrompt then
		hidePrompt()
	end
end)

local function beginTouchHold()
	if currentPrompt then
		currentPrompt:InputHoldBegin()
	end
end

local function endTouchHold()
	if currentPrompt then
		currentPrompt:InputHoldEnd()
	end
end

holdButton.MouseButton1Down:Connect(beginTouchHold)
holdButton.MouseButton1Up:Connect(endTouchHold)

holdButton.InputEnded:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.Touch or input.UserInputType == Enum.UserInputType.MouseButton1 then
		endTouchHold()
	end
end)
