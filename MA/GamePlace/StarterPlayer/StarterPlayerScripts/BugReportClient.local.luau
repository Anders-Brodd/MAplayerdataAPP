--[[
    MOUNTAIN ARCHITECT - CLIENT LOGIC
]]
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local Stats = game:GetService("Stats")
local TextService = game:GetService("TextService")

local OPEN_POSITION = UDim2.new(0.5, 0, 0.5, 0)
local HIDDEN_POSITION = UDim2.new(0.5, 0, 1.2, 0)
local Player = Players.LocalPlayer
local REMOTE_NAME = "MountainArchitect_BugSystem_Remote"
local Remote = ReplicatedStorage:WaitForChild(REMOTE_NAME, 10)
if not Remote then 
	warn("CRITICAL: Bug Report Remote not found! Make sure Server Script is running.") 
	return
end

local Screen = Player:WaitForChild("PlayerGui"):WaitForChild("BugReportUI")
local MainFrame = Screen:WaitForChild("MainFrame")
local OpenBtn = Screen:WaitForChild("ReportBugBtn")
local Toast = Screen:FindFirstChild("Toast")
local ToastLabel = Toast and Toast:FindFirstChild("Label")
local Header = MainFrame:WaitForChild("Header")
local Footer = MainFrame:WaitForChild("Footer")
local CloseBtn = Header:FindFirstChild("CloseButton") or Header:FindFirstChild("CloseBtn")

-- Inputs
local Content = MainFrame:WaitForChild("Content")
local TitleInput = Content:WaitForChild("TitleInput")
local DescInput = Content:WaitForChild("DescInput")
local StepsInput = Content:WaitForChild("StepsInput")
local SubmitBtn = Footer:WaitForChild("SubmitBtn")
local DescCounter = DescInput:FindFirstChild("CharCounter")
local StepsCounter = StepsInput:FindFirstChild("CharCounter")

Content.ScrollingDirection = Enum.ScrollingDirection.Y
Content.AutomaticCanvasSize = Enum.AutomaticSize.Y
Content.CanvasSize = UDim2.fromOffset(0, 0)
DescInput.TextScaled = false
DescInput.TextSize = 14
if DescInput:IsA("TextBox") then
	DescInput.MultiLine = true
end
StepsInput.TextScaled = false
StepsInput.TextSize = 14
if StepsInput:IsA("TextBox") then
	StepsInput.MultiLine = true
	StepsInput.TextYAlignment = Enum.TextYAlignment.Top
	StepsInput.ClearTextOnFocus = false
end
if StepsInput:IsA("GuiObject") and StepsInput.Size.Y.Scale == 0 and StepsInput.Size.Y.Offset > 0 and StepsInput.Size.Y.Offset < 120 then
	StepsInput.Size = UDim2.new(StepsInput.Size.X.Scale, StepsInput.Size.X.Offset, 0, 140)
end
Content.ScrollingEnabled = true

local Events = ReplicatedStorage:FindFirstChild("Events")
local ClosePanels = Events and Events:FindFirstChild("ClosePanels")
if Events and not ClosePanels then
	ClosePanels = Instance.new("BindableEvent")
	ClosePanels.Name = "ClosePanels"
	ClosePanels.Parent = Events
end

local function bindGuiButton(button, callback)
	if not button or not button:IsA("GuiButton") then
		return
	end
	button.Active = true
	button.Selectable = true
	button.AutoButtonColor = true
	button.Activated:Connect(callback)
end

-- // CONFIG & THEME //
local THEME = {
	Primary = Color3.fromRGB(59, 130, 246),
	Darker = Color3.fromRGB(17, 19, 24),
	Dark = Color3.fromRGB(26, 29, 36),
	SubText = Color3.fromRGB(156, 163, 175),
	Text = Color3.fromRGB(243, 244, 246),
	Red = Color3.fromRGB(239, 68, 68),
	Green = Color3.fromRGB(34, 197, 94)
}

-- State
local isOpen = false
local selectedCategory = "Gameplay"
local selectedSeverity = "Low"

local function ensureSuggestionSeverityButton(container)
	local existing = container:FindFirstChild("Suggestion")
	if existing and existing:IsA("TextButton") then
		return existing
	end
	local template = container:FindFirstChild("Low") or container:FindFirstChildWhichIsA("TextButton")
	if not template then
		return nil
	end
	local button = template:Clone()
	button.Name = "Suggestion"
	button.Text = "Suggestion"
	button.BackgroundColor3 = Color3.fromRGB(16, 19, 24)
	button.BackgroundTransparency = 0
	button.Parent = container
	return button
end

local debounce = false
local activeTween = nil
local toggleToken = 0

-- // NOTIFICATION BRIDGE //
local function NotifyBridge(type, title, msg)
	if _G.Notify and _G.Notify[type] then
		_G.Notify[type](title, msg, 4)
	elseif _G.Notify and _G.Notify.Toast then
		_G.Notify.Toast(type, title, msg, 4)
	else
		if not Toast then return end
		ToastLabel.Text = msg
		ToastLabel.TextColor3 = (type == "Error") and THEME.Red or THEME.Green
		Toast.Visible = true
		TweenService:Create(Toast, TweenInfo.new(0.5, Enum.EasingStyle.Quint), {Position = UDim2.new(0.5, -150, 0, 60)}):Play()
		task.delay(3, function()
			TweenService:Create(Toast, TweenInfo.new(0.5, Enum.EasingStyle.Quint), {Position = UDim2.new(0.5, -150, 0, -60)}):Play()
		end)
	end
end

-- // ANIMATION FUNCTIONS //
local function toggleUI(state)
	toggleToken += 1
	local thisToggle = toggleToken
	isOpen = state
	
	if activeTween then
		activeTween:Cancel()
		activeTween = nil
	end
	
	local uiScale = MainFrame:FindFirstChildOfClass("UIScale") or Instance.new("UIScale", MainFrame)
	
	if isOpen then
		if ClosePanels then
			ClosePanels:Fire("BugReport")
		end
		MainFrame.Visible = true
		MainFrame.Position = UDim2.new(0.5, 0, 0.5, 0)
		MainFrame.BackgroundTransparency = 0
		uiScale.Scale = 0.85
		activeTween = TweenService:Create(uiScale, TweenInfo.new(0.3, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {Scale = 1})
		activeTween:Play()
	else
		activeTween = TweenService:Create(uiScale, TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {Scale = 0.85})
		activeTween:Play()
		
		activeTween.Completed:Once(function()
			if toggleToken == thisToggle and not isOpen then
				MainFrame.Visible = false
			end
		end)
	end
end

-- // CLIENT STATS HARVESTER //
local function GetClientStats()
	local cam = workspace.CurrentCamera
	-- Resolution
	local res = cam and cam.ViewportSize or Vector2.new(0,0)
	local resStr = math.floor(res.X) .. "x" .. math.floor(res.Y)
	-- Inputs
	local inputs = {}
	if UserInputService.TouchEnabled then table.insert(inputs, "Touch") end
	if UserInputService.KeyboardEnabled then table.insert(inputs, "Keyboard") end
	if UserInputService.MouseEnabled then table.insert(inputs, "Mouse") end
	if UserInputService.GamepadEnabled then table.insert(inputs, "Gamepad") end
	if UserInputService.VREnabled then table.insert(inputs, "VR") end
	local inputStr = table.concat(inputs, ", ")
	-- Performance
	local fps = math.floor(workspace:GetRealPhysicsFPS())
	local mem = math.floor(Stats:GetTotalMemoryUsageMb())
	local ping = math.floor(Player:GetNetworkPing() * 1000) .. "ms"
	-- Device/Settings
	local locale = Player.LocaleId
	local quality = "Auto"
	pcall(function() quality = UserSettings().GameSettings.SavedQualityLevel.Name end)
	local platform = (GuiService:IsTenFootInterface()) and "Console" or (UserInputService.TouchEnabled and not UserInputService.MouseEnabled) and "Mobile" or "PC"
	
	return string.format(
		"**FPS:** %d  |  **Ping:** %s  |  **Mem:** %dMB\n" ..
			"**Res:** %s  |  **Platform:** %s\n" ..
			"**Inputs:** %s\n" ..
			"**Locale:** %s  |  **Graphics:** %s",
		fps, ping, mem, resStr, platform, inputStr, locale, quality
	)
end

-- // CHARACTER COUNTER //
local function scrollTextBoxIntoView(textBox)
	if not textBox or not Content or not Content.Parent then
		return
	end
	
	local visibleTop = Content.AbsolutePosition.Y
	local visibleBottom = visibleTop + Content.AbsoluteSize.Y
	local boxTop = textBox.AbsolutePosition.Y
	local boxBottom = boxTop + textBox.AbsoluteSize.Y
	local canvasY = Content.CanvasPosition.Y
	
	if boxBottom > visibleBottom - 12 then
		Content.CanvasPosition = Vector2.new(0, math.max(0, canvasY + (boxBottom - (visibleBottom - 12))))
	elseif boxTop < visibleTop + 12 then
		Content.CanvasPosition = Vector2.new(0, math.max(0, canvasY - ((visibleTop + 12) - boxTop)))
	end
end

local function normalizeInputPadding(textBox)
	local padding = textBox and textBox:FindFirstChildOfClass("UIPadding")
	if not padding or padding:GetAttribute("Normalized") then
		return
	end

	local width = textBox.AbsoluteSize.X > 0 and textBox.AbsoluteSize.X or 600
	local height = textBox.AbsoluteSize.Y > 0 and textBox.AbsoluteSize.Y or 100
	padding.PaddingLeft = UDim.new(0, math.max(10, math.floor((width * padding.PaddingLeft.Scale) + padding.PaddingLeft.Offset + 0.5)))
	padding.PaddingRight = UDim.new(0, math.max(10, math.floor((width * padding.PaddingRight.Scale) + padding.PaddingRight.Offset + 0.5)))
	padding.PaddingTop = UDim.new(0, math.max(10, math.floor((height * padding.PaddingTop.Scale) + padding.PaddingTop.Offset + 0.5)))
	padding.PaddingBottom = UDim.new(0, math.max(10, math.floor((height * padding.PaddingBottom.Scale) + padding.PaddingBottom.Offset + 0.5)))
	padding:SetAttribute("Normalized", true)
end

local function getInputPaddingOffsets(textBox)
	local padding = textBox and textBox:FindFirstChildOfClass("UIPadding")
	if not padding then
		return 0, 0
	end
	return padding.PaddingLeft.Offset + padding.PaddingRight.Offset, padding.PaddingTop.Offset + padding.PaddingBottom.Offset
end

local function getCounterHeight(counterLabel)
	if not counterLabel then
		return 0
	end
	local measured = counterLabel.AbsoluteSize.Y
	if measured > 0 then
		return measured
	end
	return math.max(16, math.floor(counterLabel.TextSize * 1.6))
end

local function resizeMultilineInput(textBox, counterLabel, minHeight)
	if not textBox then
		return
	end

	normalizeInputPadding(textBox)
	local paddingX, paddingY = getInputPaddingOffsets(textBox)
	local availableWidth = math.max(140, textBox.AbsoluteSize.X - paddingX - 6)
	local sampleText = textBox.Text ~= "" and textBox.Text or textBox.PlaceholderText or " "
	if not string.find(sampleText, "\n", 1, true) then
		sampleText ..= "\n "
	end
	local measured = TextService:GetTextSize(sampleText, textBox.TextSize, textBox.Font, Vector2.new(availableWidth, math.huge))
	local counterHeight = getCounterHeight(counterLabel)
	local targetHeight = math.max(minHeight, measured.Y + paddingY + counterHeight + 14)
	if math.abs(textBox.Size.Y.Offset - targetHeight) > 1 then
		textBox.Size = UDim2.new(textBox.Size.X.Scale, textBox.Size.X.Offset, 0, targetHeight)
		if textBox:IsFocused() then
			task.defer(function()
				scrollTextBoxIntoView(textBox)
			end)
		end
	end
end

local function bindCounter(textBox, counterLabel, maxChars, minHeight)
	if not textBox or not counterLabel then
		return
	end
	
	local function refreshCounter()
		local len = #textBox.Text
		counterLabel.Text = len .. "/" .. maxChars
		counterLabel.TextColor3 = (len > math.floor(maxChars * 0.9)) and THEME.Red or THEME.SubText
		if len > maxChars then
			textBox.Text = string.sub(textBox.Text, 1, maxChars)
		end
		resizeMultilineInput(textBox, counterLabel, minHeight)
		
		if textBox:IsFocused() then
			scrollTextBoxIntoView(textBox)
		end
	end
	
	textBox.Focused:Connect(function()
		task.defer(function()
			resizeMultilineInput(textBox, counterLabel, minHeight)
			scrollTextBoxIntoView(textBox)
		end)
	end)
	textBox:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
		resizeMultilineInput(textBox, counterLabel, minHeight)
	end)
	
	textBox:GetPropertyChangedSignal("Text"):Connect(refreshCounter)
	refreshCounter()
end

bindCounter(DescInput, DescCounter, 1000, 120)
bindCounter(StepsInput, StepsCounter, 1000, 220)

-- // UI WIRING //
local CatContainer = Content:WaitForChild("CategoryContainer")
local function refreshCategoryButtons()
	for _, b in pairs(CatContainer:GetChildren()) do
		if b:IsA("TextButton") then
			local isSelected = (b.Name == selectedCategory)
			TweenService:Create(b, TweenInfo.new(0.2), {BackgroundColor3 = isSelected and THEME.Primary or THEME.Dark}):Play()
		end
	end
end
for _, btn in pairs(CatContainer:GetChildren()) do
	if btn:IsA("TextButton") then
		bindGuiButton(btn, function()
			selectedCategory = btn.Name
			refreshCategoryButtons()
		end)
	end
end
refreshCategoryButtons()

local SevContainer = Content:WaitForChild("SeverityContainer")
ensureSuggestionSeverityButton(SevContainer)
local severityOrder = { Suggestion = 1, Low = 2, Medium = 3, High = 4, Critical = 5 }
local sevLayout = SevContainer:FindFirstChildOfClass("UIListLayout")
if sevLayout then
	sevLayout.SortOrder = Enum.SortOrder.LayoutOrder
end
for _, child in ipairs(SevContainer:GetChildren()) do
	if child:IsA("TextButton") then
		child.LayoutOrder = severityOrder[child.Name] or 99
		child.Size = UDim2.new(0.184, 0, 1, 0)
		child.TextScaled = false
		child.TextSize = 11
	end
end

local function refreshSeverityButtons()
	for _, b in pairs(SevContainer:GetChildren()) do
		if b:IsA("TextButton") then
			local isSelected = (b.Name == selectedSeverity)
			local activeColor = THEME.Dark
			if b.Name == "Suggestion" then
				activeColor = Color3.fromRGB(59, 130, 246)
			elseif b.Name == "Low" then
				activeColor = Color3.fromRGB(34, 197, 94)
			elseif b.Name == "Medium" then
				activeColor = Color3.fromRGB(245, 158, 11)
			elseif b.Name == "High" then
				activeColor = Color3.fromRGB(239, 68, 68)
			elseif b.Name == "Critical" then
				activeColor = Color3.fromRGB(190, 24, 93)
			end
			b.BackgroundColor3 = isSelected and activeColor or THEME.Dark
			b.BackgroundTransparency = isSelected and 0.15 or 0
		end
	end
end
for _, btn in pairs(SevContainer:GetChildren()) do
	if btn:IsA("TextButton") then
		bindGuiButton(btn, function()
			selectedSeverity = btn.Name
			refreshSeverityButtons()
		end)
	end
end
refreshSeverityButtons()

MainFrame.Position = HIDDEN_POSITION
MainFrame.BackgroundTransparency = 1
MainFrame.Visible = false

bindGuiButton(OpenBtn, function()
	toggleUI(not isOpen)
end)
bindGuiButton(CloseBtn, function()
	toggleUI(false)
end)

if ClosePanels then
	ClosePanels.Event:Connect(function(source)
		if source ~= "BugReport" and isOpen then
			toggleUI(false)
		end
	end)
end

-- Submit Logic
bindGuiButton(SubmitBtn, function()
	if debounce then return end
	debounce = true
	local originalText = SubmitBtn.Text
	SubmitBtn.Text = "COLLECTING DATA..."
	SubmitBtn.BackgroundColor3 = THEME.SubText
	
	-- Gather Data
	local camera = workspace.CurrentCamera
	local camCFrame = string.format("%.1f, %.1f, %.1f", camera.CFrame.Position.X, camera.CFrame.Position.Y, camera.CFrame.Position.Z)
	local deviceInfo = GetClientStats()
	
	local payload = {
		Title = TitleInput.Text,
		Description = DescInput.Text,
		Steps = StepsInput.Text,
		Category = selectedCategory,
		Severity = selectedSeverity,
		CamCFrame = camCFrame,
		DeviceInfo = deviceInfo
	}
	
	SubmitBtn.Text = "SENDING..."
	local success, result = pcall(function()
		return Remote:InvokeServer(payload)
	end)
	
	if success and result and result.Success then
		NotifyBridge("Success", "Report Sent!", "Thanks for helping us improve!")
		toggleUI(false)
		TitleInput.Text = ""
		DescInput.Text = ""
		StepsInput.Text = ""
	else
		local msg = (result and result.Message) or "Connection Failed"
		NotifyBridge("Error", "Failed", msg)
	end
	
	SubmitBtn.Text = originalText
	SubmitBtn.BackgroundColor3 = THEME.Primary
	debounce = false
end)