local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local Player = Players.LocalPlayer
local PlayerGui = Player:WaitForChild("PlayerGui")
local MainHUD = PlayerGui:WaitForChild("MainHUD")
local TopBar = MainHUD:WaitForChild("Top"):WaitForChild("TopBar")
local Events = ReplicatedStorage:WaitForChild("Events")
local SlotData = ReplicatedStorage:WaitForChild("SlotData")
local PreferenceSync = Events:WaitForChild("PlayerPreferenceSync", 10)
local TicketEvent = Events:WaitForChild("SetTicketPrice", 10)

local ClosePanels = Events:FindFirstChild("ClosePanels")
if not ClosePanels then
	ClosePanels = Instance.new("BindableEvent")
	ClosePanels.Name = "ClosePanels"
	ClosePanels.Parent = Events
end

local THEME = {
	RowBg = Color3.fromRGB(17, 19, 24),
	Label = Color3.fromRGB(240, 240, 240),
	Sub = Color3.fromRGB(150, 150, 150),
	InputBg = Color3.fromRGB(24, 27, 34),
	InputStroke = Color3.fromRGB(42, 48, 60),
	Button = Color3.fromRGB(0, 120, 215),
	ButtonAlt = Color3.fromRGB(34, 37, 43),
	On = Color3.fromRGB(40, 160, 80),
	Off = Color3.fromRGB(90, 54, 26),
}

local function isCompactTouchLayout()
	local camera = workspace.CurrentCamera
	local viewport = camera and camera.ViewportSize or Vector2.new(1280, 720)
	return UserInputService.TouchEnabled and math.min(viewport.X, viewport.Y) <= 1100
end

local function getOpenPosition()
	return isCompactTouchLayout() and UDim2.new(0.5, 0, 0.44, 0) or UDim2.new(0.5, 0, 0.5, 0)
end

local function getClosedPosition()
	return UDim2.new(0.5, 0, 1.5, 0)
end

local TWEEN_INFO = TweenInfo.new(0.25, Enum.EasingStyle.Quart, Enum.EasingDirection.Out)
local BUTTON_NAME = "ResortSettingsTopButton"
local BUTTON_GUI_NAME = "ResortSettingsUI"
local WAYPOINT_BUTTON_NAME = "WaypointTopButton"

local state = {
	isOpen = false,
	frame = nil,
	content = nil,
	button = nil,
	resortName = "My Resort",
	resortInfo = "",
	isResortOpen = true,
	allLights = true,
}

local function bindGuiButton(button, callback)
	if not (button and callback and button:IsA("GuiObject")) then
		return
	end
	button.Active = true
	button.Selectable = true
	if button:IsA("GuiButton") then
		button.Activated:Connect(callback)
	else
		button.InputBegan:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
				callback()
			end
		end)
	end
end

local function round(instance, radius)
	local corner = instance:FindFirstChildOfClass("UICorner") or Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, radius)
	corner.Parent = instance
	return corner
end

local function stroke(instance, color)
	local s = instance:FindFirstChildOfClass("UIStroke") or Instance.new("UIStroke")
	s.Color = color
	s.Transparency = 0.15
	s.Parent = instance
	return s
end

local function getViewportSize()
	local camera = workspace.CurrentCamera
	return camera and camera.ViewportSize or Vector2.new(1280, 720)
end

local function refreshStateFromReplicated()
	state.resortName = SlotData:FindFirstChild("ResortName") and SlotData.ResortName.Value or state.resortName
	state.resortInfo = tostring(SlotData:GetAttribute("ResortInfo") or state.resortInfo or "")
	state.isResortOpen = SlotData:GetAttribute("ResortOpen") ~= false
	state.allLights = SlotData:GetAttribute("ResortAllLights") ~= false
end

local function sendResortState(overrides)
	refreshStateFromReplicated()
	local payload = {
		ResortName = state.resortName,
		Info = state.resortInfo,
		IsOpen = state.isResortOpen,
		AllLights = state.allLights,
	}
	for key, value in pairs(overrides or {}) do
		payload[key] = value
	end
	state.resortName = tostring(payload.ResortName or state.resortName)
	state.resortInfo = tostring(payload.Info or "")
	state.isResortOpen = payload.IsOpen ~= false
	state.allLights = payload.AllLights ~= false
	if PreferenceSync and PreferenceSync:IsA("RemoteFunction") then
		pcall(function()
			PreferenceSync:InvokeServer("SetResort", payload)
		end)
	end
end

local function parseTicketInput(text)
	local digits = tostring(text or ""):gsub("[^%d]", "")
	return math.max(0, tonumber(digits) or tonumber(Player:GetAttribute("TicketPriceBase")) or tonumber(Player:GetAttribute("TicketPrice")) or 0)
end

local function createSectionHeader(parent, text, order)
	local label = Instance.new("TextLabel")
	label.Name = "SectionHeader_" .. text
	label.Size = UDim2.new(1, 0, 0, 24)
	label.BackgroundTransparency = 1
	label.Text = text
	label.TextColor3 = Color3.fromRGB(200, 200, 200)
	label.Font = Enum.Font.GothamBlack
	label.TextSize = 13
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.LayoutOrder = order
	label.Parent = parent
	return label
end

local function createBaseRow(parent, name, height, order)
	local row = Instance.new("Frame")
	row.Name = name
	row.Size = UDim2.new(1, 0, 0, height)
	row.BackgroundColor3 = THEME.RowBg
	row.BorderSizePixel = 0
	row.LayoutOrder = order
	row.Parent = parent
	round(row, 12)
	stroke(row, Color3.fromRGB(32, 36, 44))
	return row
end

local function createToggleRow(parent, name, title, subtitle, order, getter, setter)
	local row = createBaseRow(parent, name, 58, order)
	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Position = UDim2.fromOffset(12, 8)
	label.Size = UDim2.new(1, -126, 0, 18)
	label.Font = Enum.Font.GothamBold
	label.Text = title
	label.TextColor3 = THEME.Label
	label.TextSize = 15
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.Parent = row
	local sub = Instance.new("TextLabel")
	sub.BackgroundTransparency = 1
	sub.Position = UDim2.fromOffset(12, 28)
	sub.Size = UDim2.new(1, -126, 0, 14)
	sub.Font = Enum.Font.Gotham
	sub.Text = subtitle
	sub.TextColor3 = THEME.Sub
	sub.TextSize = 11
	sub.TextXAlignment = Enum.TextXAlignment.Left
	sub.Parent = row
	local toggle = Instance.new("TextButton")
	toggle.Size = UDim2.fromOffset(92, 30)
	toggle.Position = UDim2.new(1, -104, 0.5, -15)
	toggle.BorderSizePixel = 0
	toggle.Font = Enum.Font.GothamBold
	toggle.TextSize = 12
	toggle.Parent = row
	round(toggle, 10)
	local function sync()
		local on = getter()
		toggle.Text = on and "ON" or "OFF"
		toggle.BackgroundColor3 = on and THEME.On or THEME.Off
	end
	bindGuiButton(toggle, function()
		setter(not getter())
		sync()
	end)
	sync()
	return row, sync
end

local function createTextRow(parent, name, title, subtitle, order, multiline, getter, setter)
	local rowHeight = multiline and 132 or 86
	local row = createBaseRow(parent, name, rowHeight, order)
	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Position = UDim2.fromOffset(12, 8)
	label.Size = UDim2.new(1, -24, 0, 18)
	label.Font = Enum.Font.GothamBold
	label.Text = title
	label.TextColor3 = THEME.Label
	label.TextSize = 15
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.Parent = row
	local sub = Instance.new("TextLabel")
	sub.BackgroundTransparency = 1
	sub.Position = UDim2.fromOffset(12, 28)
	sub.Size = UDim2.new(1, -24, 0, 14)
	sub.Font = Enum.Font.Gotham
	sub.Text = subtitle
	sub.TextColor3 = THEME.Sub
	sub.TextSize = 11
	sub.TextXAlignment = Enum.TextXAlignment.Left
	sub.Parent = row
	local input = Instance.new("TextBox")
	input.Size = UDim2.new(1, -108, 0, multiline and 58 or 28)
	input.Position = UDim2.fromOffset(12, multiline and 50 or 48)
	input.BackgroundColor3 = THEME.InputBg
	input.TextColor3 = THEME.Label
	input.PlaceholderText = multiline and "Tell guests what kind of mountain this is..." or "Enter resort name"
	input.Font = Enum.Font.Gotham
	input.TextSize = multiline and 13 or 15
	input.TextXAlignment = Enum.TextXAlignment.Left
	input.TextYAlignment = multiline and Enum.TextYAlignment.Top or Enum.TextYAlignment.Center
	input.ClearTextOnFocus = false
	input.TextWrapped = multiline
	input.MultiLine = multiline
	input.Text = getter()
	input.Parent = row
	round(input, 8)
	stroke(input, THEME.InputStroke)
	local padding = Instance.new("UIPadding")
	padding.PaddingLeft = UDim.new(0, 8)
	padding.PaddingTop = UDim.new(0, multiline and 6 or 0)
	padding.Parent = input
	local save = Instance.new("TextButton")
	save.Size = UDim2.fromOffset(84, 28)
	save.Position = UDim2.new(1, -96, 0, multiline and 50 or 48)
	save.BackgroundColor3 = THEME.Button
	save.Text = "SAVE"
	save.TextColor3 = Color3.fromRGB(255, 255, 255)
	save.Font = Enum.Font.GothamBold
	save.TextSize = 12
	save.BorderSizePixel = 0
	save.Parent = row
	round(save, 8)
	stroke(save, Color3.fromRGB(10, 60, 120))
	bindGuiButton(save, function()
		setter(input.Text)
		save.Text = "SAVED"
		save.BackgroundColor3 = THEME.On
		task.delay(0.8, function()
			if save and save.Parent then
				save.Text = "SAVE"
				save.BackgroundColor3 = THEME.Button
			end
		end)
	end)
	return row, input
end

local function applyResponsiveTicketRow(row)
	if not row then return end
	local compact = isCompactTouchLayout()
	local rowWidth = math.max(row.AbsoluteSize.X, 320)
	local input = row:FindFirstChild("TicketInput")
	local minus = row:FindFirstChild("TicketMinus")
	local plus = row:FindFirstChild("TicketPlus")
	local apply = row:FindFirstChild("TicketApply")
	local autoToggle = row:FindFirstChild("TicketAuto")
	if not (input and minus and plus and apply and autoToggle) then return end
	if compact then
		local inputWidth = math.clamp(math.floor(rowWidth * 0.28), 88, 116)
		row.Size = UDim2.new(1, 0, 0, 142)
		input.Size = UDim2.fromOffset(inputWidth, 32)
		input.Position = UDim2.fromOffset(12, 54)
		minus.Size = UDim2.fromOffset(32, 32)
		minus.Position = UDim2.fromOffset(16 + inputWidth, 54)
		plus.Size = UDim2.fromOffset(32, 32)
		plus.Position = UDim2.fromOffset(54 + inputWidth, 54)
		apply.Size = UDim2.fromOffset(84, 32)
		apply.Position = UDim2.new(1, -96, 0, 54)
		autoToggle.Size = UDim2.new(1, -24, 0, 28)
		autoToggle.Position = UDim2.fromOffset(12, 102)
	else
		row.Size = UDim2.new(1, 0, 0, 118)
		input.Size = UDim2.fromOffset(92, 28)
		input.Position = UDim2.fromOffset(12, 50)
		minus.Size = UDim2.fromOffset(28, 28)
		minus.Position = UDim2.fromOffset(110, 50)
		plus.Size = UDim2.fromOffset(28, 28)
		plus.Position = UDim2.fromOffset(144, 50)
		apply.Size = UDim2.fromOffset(76, 28)
		apply.Position = UDim2.new(1, -88, 0, 50)
		autoToggle.Size = UDim2.fromOffset(108, 24)
		autoToggle.Position = UDim2.fromOffset(12, 86)
	end
end

local function createTicketRow(parent, order)
	local row = createBaseRow(parent, "LiftTicketPrice", 118, order)
	local title = Instance.new("TextLabel")
	title.BackgroundTransparency = 1
	title.Position = UDim2.fromOffset(12, 8)
	title.Size = UDim2.new(1, -24, 0, 18)
	title.Font = Enum.Font.GothamBold
	title.Text = "Lift Ticket Price"
	title.TextColor3 = THEME.Label
	title.TextSize = 15
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.Parent = row
	local meta = Instance.new("TextLabel")
	meta.BackgroundTransparency = 1
	meta.Position = UDim2.fromOffset(12, 28)
	meta.Size = UDim2.new(1, -24, 0, 14)
	meta.Font = Enum.Font.Gotham
	meta.TextColor3 = THEME.Sub
	meta.TextSize = 11
	meta.TextXAlignment = Enum.TextXAlignment.Left
	meta.Parent = row
	local input = Instance.new("TextBox")
	input.Name = "TicketInput"
	input.Size = UDim2.fromOffset(92, 28)
	input.Position = UDim2.fromOffset(12, 50)
	input.BackgroundColor3 = THEME.InputBg
	input.TextColor3 = Color3.fromRGB(120, 255, 180)
	input.PlaceholderText = "$30"
	input.ClearTextOnFocus = false
	input.Font = Enum.Font.GothamBold
	input.TextSize = 14
	input.Parent = row
	round(input, 8)
	stroke(input, THEME.InputStroke)
	local minus = Instance.new("TextButton")
	minus.Name = "TicketMinus"
	minus.Size = UDim2.fromOffset(28, 28)
	minus.Position = UDim2.fromOffset(110, 50)
	minus.BackgroundColor3 = THEME.InputBg
	minus.Text = "-"
	minus.TextColor3 = THEME.Label
	minus.Font = Enum.Font.GothamBlack
	minus.TextSize = 14
	minus.Parent = row
	round(minus, 8)
	stroke(minus, THEME.InputStroke)
	local plus = Instance.new("TextButton")
	plus.Name = "TicketPlus"
	plus.Size = UDim2.fromOffset(28, 28)
	plus.Position = UDim2.fromOffset(144, 50)
	plus.BackgroundColor3 = THEME.InputBg
	plus.Text = "+"
	plus.TextColor3 = THEME.Label
	plus.Font = Enum.Font.GothamBlack
	plus.TextSize = 14
	plus.Parent = row
	round(plus, 8)
	stroke(plus, THEME.InputStroke)
	local apply = Instance.new("TextButton")
	apply.Name = "TicketApply"
	apply.Size = UDim2.fromOffset(76, 28)
	apply.Position = UDim2.new(1, -88, 0, 50)
	apply.BackgroundColor3 = THEME.Button
	apply.Text = "APPLY"
	apply.TextColor3 = Color3.fromRGB(255, 255, 255)
	apply.Font = Enum.Font.GothamBold
	apply.TextSize = 12
	apply.BorderSizePixel = 0
	apply.Parent = row
	round(apply, 8)
	stroke(apply, Color3.fromRGB(10, 60, 120))
	local autoToggle = Instance.new("TextButton")
	autoToggle.Name = "TicketAuto"
	autoToggle.Size = UDim2.fromOffset(108, 24)
	autoToggle.Position = UDim2.fromOffset(12, 86)
	autoToggle.BackgroundColor3 = THEME.ButtonAlt
	autoToggle.TextColor3 = THEME.Label
	autoToggle.Font = Enum.Font.GothamBold
	autoToggle.TextSize = 11
	autoToggle.BorderSizePixel = 0
	autoToggle.Parent = row
	round(autoToggle, 8)
	stroke(autoToggle, THEME.InputStroke)
	local function sync()
		local base = math.floor((tonumber(Player:GetAttribute("TicketPriceBase")) or parseTicketInput(input.Text)) + 0.5)
		local live = math.floor((tonumber(Player:GetAttribute("TicketPrice")) or base) + 0.5)
		local autoOn = Player:GetAttribute("TicketPricingEnabled") == true
		meta.Text = string.format("Set $%d  •  Live $%d  •  Auto %s", base, live, autoOn and "ON" or "OFF")
		if not input:IsFocused() then
			input.Text = "$" .. base
		end
		autoToggle.Text = autoOn and "AUTO ON" or "AUTO OFF"
		autoToggle.BackgroundColor3 = autoOn and THEME.On or THEME.Off
	end
	bindGuiButton(minus, function()
		input.Text = "$" .. math.max(0, parseTicketInput(input.Text) - 5)
	end)
	bindGuiButton(plus, function()
		input.Text = "$" .. (parseTicketInput(input.Text) + 5)
	end)
	bindGuiButton(apply, function()
		local price = parseTicketInput(input.Text)
		input.Text = "$" .. price
		TicketEvent:FireServer({price = price, auto = false})
		apply.Text = "SAVED"
		apply.BackgroundColor3 = THEME.On
		task.delay(0.8, function()
			if apply and apply.Parent then
				apply.Text = "APPLY"
				apply.BackgroundColor3 = THEME.Button
			end
		end)
	end)
	bindGuiButton(autoToggle, function()
		TicketEvent:FireServer({auto = not (Player:GetAttribute("TicketPricingEnabled") == true)})
	end)
	input.FocusLost:Connect(function()
		input.Text = "$" .. parseTicketInput(input.Text)
	end)
	Player:GetAttributeChangedSignal("TicketPrice"):Connect(sync)
	Player:GetAttributeChangedSignal("TicketPriceBase"):Connect(sync)
	Player:GetAttributeChangedSignal("TicketPricingEnabled"):Connect(sync)
	sync()
	applyResponsiveTicketRow(row)
	return row
end

local function applyResponsiveFrame(frame, content)
	local viewport = getViewportSize()
	local touch = UserInputService.TouchEnabled
	local compact = touch and math.min(viewport.X, viewport.Y) <= 1100
	frame.Size = compact and UDim2.new(0.92, 0, 0.68, 0) or UDim2.new(0.55, 0, 0.6, 0)
	content.ScrollBarThickness = compact and 6 or 4
	local ticketRow = content and content:FindFirstChild("LiftTicketPrice")
	if ticketRow then
		applyResponsiveTicketRow(ticketRow)
	end
end

local function buildUi()
	if state.frame then
		return
	end
	local template = MainHUD:WaitForChild("SettingsFrame")
	local frame = template:Clone()
	frame.Name = "ResortSettingsFrame"
	frame.Visible = false
	frame.Position = getClosedPosition()
	frame.Parent = MainHUD
	local header = frame:WaitForChild("Header")
	header.Title.Text = "Resort Settings"
	header.Subtitle.Text = "Mountain controls, identity, pricing, and operations"
	local content = frame:WaitForChild("Content")
	for _, child in ipairs(content:GetChildren()) do
		child:Destroy()
	end
	content.AutomaticCanvasSize = Enum.AutomaticSize.Y
	content.CanvasSize = UDim2.fromOffset(0, 0)
	content.ScrollingDirection = Enum.ScrollingDirection.Y
	local layout = Instance.new("UIListLayout")
	layout.Padding = UDim.new(0, 6)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = content
	local pad = Instance.new("UIPadding")
	pad.PaddingTop = UDim.new(0, 6)
	pad.PaddingLeft = UDim.new(0, 5)
	pad.PaddingRight = UDim.new(0, 5)
	pad.Parent = content

	createSectionHeader(content, "🏔️ RESORT", 1)
	local _, resortNameInput = createTextRow(content, "ResortNameRow", "Resort Name", "What guests and leaderboards will see", 2, false, function()
		return state.resortName
	end, function(value)
		sendResortState({ ResortName = string.sub((value or ""):gsub("^%s+", ""):gsub("%s+$", ""), 1, 48) })
	end)
	local _, resortInfoInput = createTextRow(content, "ResortInfoRow", "Resort Info", "Short description for your mountain vibe and focus", 3, true, function()
		return state.resortInfo
	end, function(value)
		sendResortState({ Info = string.sub(value or "", 1, 280) })
	end)
	local _, syncOpen = createToggleRow(content, "ResortOpenRow", "Resort Open", "Pause arrivals without deleting your resort", 4, function()
		return state.isResortOpen
	end, function(value)
		sendResortState({ IsOpen = value })
	end)
	local _, syncLights = createToggleRow(content, "ResortLightsRow", "All Lights", "Turn all resort lights on or off at once", 5, function()
		return state.allLights
	end, function(value)
		sendResortState({ AllLights = value })
	end)
	createSectionHeader(content, "💸 PRICING", 6)
	createTicketRow(content, 7)

	local closeButton = header:WaitForChild("CloseButton")
	bindGuiButton(closeButton, function()
		state.isOpen = false
		TweenService:Create(frame, TWEEN_INFO, { Position = getClosedPosition() }):Play()
		task.delay(TWEEN_INFO.Time, function()
			if frame and not state.isOpen then
				frame.Visible = false
			end
		end)
	end)

	ClosePanels.Event:Connect(function(source)
		if source == "ResortSettings" then return end
		if state.isOpen and frame then
			state.isOpen = false
			TweenService:Create(frame, TWEEN_INFO, { Position = getClosedPosition() }):Play()
			task.delay(TWEEN_INFO.Time, function()
				if frame and not state.isOpen then
					frame.Visible = false
				end
			end)
		end
	end)

	applyResponsiveFrame(frame, content)
	state.frame = frame
	state.content = content
	state.resortNameInput = resortNameInput
	state.resortInfoInput = resortInfoInput
	state.syncOpen = syncOpen
	state.syncLights = syncLights
end

local function togglePanel()
	buildUi()
	if state.isOpen then
		state.isOpen = false
		TweenService:Create(state.frame, TWEEN_INFO, { Position = getClosedPosition() }):Play()
		task.delay(TWEEN_INFO.Time, function()
			if state.frame and not state.isOpen then
				state.frame.Visible = false
			end
		end)
	else
		refreshStateFromReplicated()
		if state.resortNameInput and not state.resortNameInput:IsFocused() then
			state.resortNameInput.Text = state.resortName
		end
		if state.resortInfoInput and not state.resortInfoInput:IsFocused() then
			state.resortInfoInput.Text = state.resortInfo
		end
		if state.syncOpen then state.syncOpen() end
		if state.syncLights then state.syncLights() end
		state.isOpen = true
		ClosePanels:Fire("ResortSettings")
		state.frame.Visible = true
		applyResponsiveFrame(state.frame, state.content)
		TweenService:Create(state.frame, TWEEN_INFO, { Position = getOpenPosition() }):Play()
	end
end

local function isWaypointButtonReady(waypointButton)
	if not (waypointButton and waypointButton:IsA("GuiObject")) then
		return false
	end
	if waypointButton.AbsoluteSize.X <= 0 or waypointButton.AbsoluteSize.Y <= 0 then
		return false
	end
	-- Avoid inheriting transient startup placement before the waypoint button finalizes.
	return waypointButton.Position.X.Scale >= 0.95
end

local function updateButtonLayout()
	if not state.button then return end
	state.button.Visible = true
	local waypointButton = PlayerGui:FindFirstChild(WAYPOINT_BUTTON_NAME, true)
	if isWaypointButtonReady(waypointButton) then
		state.button.Position = UDim2.new(
			0,
			math.floor(waypointButton.AbsolutePosition.X + math.max(0, (waypointButton.AbsoluteSize.X - state.button.AbsoluteSize.X) * 0.5)),
			0,
			math.floor(waypointButton.AbsolutePosition.Y + waypointButton.AbsoluteSize.Y + 10)
		)
		return
	end
	local rightMargin = UserInputService.TouchEnabled and 18 or 22
	local topMargin = UserInputService.TouchEnabled and 172 or 142
	state.button.Position = UDim2.new(1, -math.floor(rightMargin), 0, math.floor(topMargin))
end

local function ensureButton()
	if state.button then return end
	local buttonGui = PlayerGui:FindFirstChild(BUTTON_GUI_NAME)
	if not buttonGui then
		buttonGui = Instance.new("ScreenGui")
		buttonGui.Name = BUTTON_GUI_NAME
		buttonGui.ResetOnSpawn = false
		buttonGui.IgnoreGuiInset = false
		buttonGui.ClipToDeviceSafeArea = true
		buttonGui.ScreenInsets = Enum.ScreenInsets.CoreUISafeInsets
		buttonGui.DisplayOrder = 8
		buttonGui.ZIndexBehavior = Enum.ZIndexBehavior.Global
		buttonGui.Parent = PlayerGui
	end
	local button = Instance.new("ImageButton")
	button.Name = BUTTON_NAME
	button.Size = UDim2.fromOffset(42, 42)
	button.AnchorPoint = Vector2.new(1, 0)
	button.Position = UDim2.new(1, -22, 0, 142)
	button.BackgroundColor3 = Color3.fromRGB(20, 24, 33)
	button.BackgroundTransparency = 0.02
	button.BorderSizePixel = 0
	button.Image = "rbxthumb://type=Asset&id=74316155901650&w=150&h=150"
	button.ScaleType = Enum.ScaleType.Fit
	button.ImageColor3 = Color3.fromRGB(235, 242, 255)
	button.ZIndex = 10
	button.Parent = buttonGui
	round(button, 12)
	stroke(button, Color3.fromRGB(66, 78, 98))
	local buttonGradient = Instance.new("UIGradient")
	buttonGradient.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(34, 40, 56)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(13, 17, 24))
	})
	buttonGradient.Rotation = 90
	buttonGradient.Parent = button
	bindGuiButton(button, togglePanel)
	state.button = button
	updateButtonLayout()
end

refreshStateFromReplicated()
buildUi()
ensureButton()
updateButtonLayout()
task.defer(updateButtonLayout)
task.delay(0.15, updateButtonLayout)
task.delay(0.5, updateButtonLayout)

SlotData:GetAttributeChangedSignal("ResortInfo"):Connect(function()
	refreshStateFromReplicated()
	if state.resortInfoInput and not state.resortInfoInput:IsFocused() then
		state.resortInfoInput.Text = state.resortInfo
	end
	if state.syncOpen then state.syncOpen() end
	if state.syncLights then state.syncLights() end
end)
SlotData:GetAttributeChangedSignal("ResortOpen"):Connect(function()
	refreshStateFromReplicated()
	if state.syncOpen then state.syncOpen() end
end)
SlotData:GetAttributeChangedSignal("ResortAllLights"):Connect(function()
	refreshStateFromReplicated()
	if state.syncLights then state.syncLights() end
end)
local resortNameValue = SlotData:WaitForChild("ResortName")
resortNameValue:GetPropertyChangedSignal("Value"):Connect(function()
	refreshStateFromReplicated()
	if state.resortNameInput and not state.resortNameInput:IsFocused() then
		state.resortNameInput.Text = state.resortName
	end
end)

local lastViewportSize = Vector2.zero
local viewportConn = nil

local function refreshResponsiveLayout()
	updateButtonLayout()
	if state.frame and state.frame.Visible then
		applyResponsiveFrame(state.frame, state.content)
	end
end

local function bindViewportListener(camera)
	if viewportConn then
		viewportConn:Disconnect()
		viewportConn = nil
	end
	if not camera then
		return
	end
	lastViewportSize = camera.ViewportSize
	viewportConn = camera:GetPropertyChangedSignal("ViewportSize"):Connect(function()
		local viewport = camera.ViewportSize
		if viewport ~= lastViewportSize then
			lastViewportSize = viewport
			refreshResponsiveLayout()
		end
	end)
end

bindViewportListener(workspace.CurrentCamera)
workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
	bindViewportListener(workspace.CurrentCamera)
	refreshResponsiveLayout()
end)

if state.button then
	state.button:GetPropertyChangedSignal("AbsoluteSize"):Connect(refreshResponsiveLayout)
end
if state.frame then
	state.frame:GetPropertyChangedSignal("Visible"):Connect(refreshResponsiveLayout)
end
MainHUD.DescendantAdded:Connect(function(desc)
	if desc.Name == WAYPOINT_BUTTON_NAME then
		task.defer(refreshResponsiveLayout)
	end
end)
MainHUD.DescendantRemoving:Connect(function(desc)
	if desc.Name == WAYPOINT_BUTTON_NAME then
		task.defer(refreshResponsiveLayout)
	end
end)

print("ResortSettingsClient Online")