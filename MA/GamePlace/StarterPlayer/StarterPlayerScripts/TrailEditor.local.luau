--[=[ PATH: StarterPlayerScripts/TrailEditorClient | TYPE: LocalScript ]=]--
--[[
	SCRIPT DESCRIPTION:
	Handles client-side trail editing. Allows the player to click a placed slope to open the editor and adjust features like Markers, Nets, Lights, and Tree Density, then dispatches the changes to the server.

	OLD SCRIPT CAPABILITIES:
	- Model raycasting to detect slopes.
	- Dynamic mapping of `Difficulty` and names.
	- Server dispatching and tween animations.
	- Mapped to physical UI elements.
	- Errored because `FindFirstChildWhichIsA` expected a perfect hierarchy.

	CHANGES (ADDED/REMOVED):
	- ADDED: Forced `Enabled = false` and off-screen positioning on startup to prevent screen clutter.
	- ADDED: Extreme safety checks on the Glade Slider mapping to prevent the script from crashing if elements are missing or renamed.
	- REMOVED: None. Retained all functionality.
]]

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

print("[TrailEditorClient] Initializing services and variables.")
local Player = Players.LocalPlayer
local Camera = workspace.CurrentCamera

local Events = ReplicatedStorage:WaitForChild("Events")
local ClosePanels = Events:FindFirstChild("ClosePanels")
if not ClosePanels then
	ClosePanels = Instance.new("BindableEvent")
	ClosePanels.Name = "ClosePanels"
	ClosePanels.Parent = Events
end
local EditSlopeRemote = Events:WaitForChild("EditSlopeRemote", 10)
if not EditSlopeRemote then
	EditSlopeRemote = Instance.new("RemoteEvent")
	EditSlopeRemote.Name = "EditSlopeRemote"
	EditSlopeRemote.Parent = Events
end
local RenamePlacedObject = Events:WaitForChild("RenamePlacedObject", 10)

-- Physical UI Hookup (Hardened)
local PlayerGui = Player:WaitForChild("PlayerGui")
local ModeState = PlayerGui:FindFirstChild("ModeState") or ReplicatedStorage:FindFirstChild("ModeState")
print("[TrailEditorClient] Awaiting TrailEditorUI.")
local EditorGui = PlayerGui:WaitForChild("TrailEditorUI", 10)
if not EditorGui then warn("[TrailEditorClient] TrailEditorUI not found!") return end
EditorGui.Enabled = false -- Hide immediately

local EditorPanel = EditorGui:WaitForChild("EditorPanel", 3)
if not EditorPanel then return end
EditorPanel.Visible = false
EditorPanel.Position = UDim2.new(1, 20, 0.5, 0) -- Set offscreen

local Header = EditorPanel:FindFirstChild("Header")
local SlopeName = EditorPanel:WaitForChild("SlopeName", 3)
local GladeSection = EditorPanel:WaitForChild("GladeSection", 3)
local ApplyBtn = EditorPanel:WaitForChild("ApplyBtn", 3)
local CloseBtn = (Header and (Header:FindFirstChild("CloseButton") or Header:FindFirstChild("CloseBtn")))
	or EditorPanel:FindFirstChild("CloseButton")
	or EditorPanel:FindFirstChild("CloseBtn")
	or EditorPanel:FindFirstChild("TextButton")
if CloseBtn == ApplyBtn then
	CloseBtn = nil
	for _, child in ipairs(EditorPanel:GetChildren()) do
		if child:IsA("TextButton") and child ~= ApplyBtn then
			CloseBtn = child
			break
		end
	end
end

local function bindGuiButton(button, callback)
	if not button or not button:IsA("GuiButton") then return end
	button.Active = true
	button.Selectable = true
	button.AutoButtonColor = true
	button.Activated:Connect(callback)
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

local function getSlopeDisplayName(model)
	local customName = sanitizeCustomName(model and model:GetAttribute("CustomName") or "")
	if customName ~= "" then
		return customName
	end
	local slopeName = tostring(model and model.Name or "")
	slopeName = slopeName:gsub("Slope_", ""):gsub("_", " ")
	slopeName = slopeName:gsub("^Slope ", "")
	slopeName = sanitizeCustomName(slopeName)
	if slopeName ~= "" then
		return slopeName
	end
	local difficulty = model and model:GetAttribute("Difficulty") or "Green"
	return tostring(difficulty) .. " Run"
end

local function ensureNameInput()
	local existing = EditorPanel:FindFirstChild("NameInput")
	if existing and existing:IsA("TextBox") then
		return existing
	end
	if SlopeName then
		SlopeName.Size = UDim2.new(0.5, 0, 0, 26)
		SlopeName.Position = UDim2.new(0.0357142873, 0, 0.145, 0)
		SlopeName.TextScaled = false
		SlopeName.TextSize = 13
		SlopeName.TextTransparency = 0.18
	end
	local input = Instance.new("TextBox")
	input.Name = "NameInput"
	input.AnchorPoint = Vector2.new(1, 0)
	input.Position = UDim2.new(0.964285731, 0, 0.14, 0)
	input.Size = UDim2.new(0.4, 0, 0, 28)
	input.BackgroundColor3 = Color3.fromRGB(30, 35, 43)
	input.BorderSizePixel = 0
	input.ClearTextOnFocus = false
	input.Font = Enum.Font.Gotham
	input.PlaceholderColor3 = Color3.fromRGB(132, 146, 167)
	input.PlaceholderText = "Custom name"
	input.Text = ""
	input.TextColor3 = Color3.fromRGB(240, 244, 255)
	input.TextSize = 12
	input.TextXAlignment = Enum.TextXAlignment.Left
	input.Parent = EditorPanel
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 8)
	corner.Parent = input
	local padding = Instance.new("UIPadding")
	padding.PaddingLeft = UDim.new(0, 10)
	padding.PaddingRight = UDim.new(0, 10)
	padding.Parent = input
	return input
end

local NameInput = ensureNameInput()

-- State
local selectedModel = nil
local selectionBox = nil
local isEditorOpen = false
local MobilePromptGui, MobileEditButton, MobileReticle
local isBuildMenuOpen
local mobilePromptTarget = nil
local raycastSlopeAtPointer, getCenterAimPointer, isPointerBlockedByGui

local function isMobileTrailMode()
	if not UserInputService.TouchEnabled then
		return false
	end
	local viewport = Camera and Camera.ViewportSize
	if viewport and viewport.X > 0 then
		return viewport.X <= 1100
	end
	return not UserInputService.MouseEnabled
end

local editState = {
	markers = true,
	nets = false,
	markerLights = true,
	gladeDensity = 50,
	width = 90,
}

local function findToggleRows()
	local rows = {}
	for _, child in ipairs(EditorPanel:GetChildren()) do
		if child:IsA("Frame") and child ~= Header and child ~= GladeSection then
			local label = child:FindFirstChildWhichIsA("TextLabel", true)
			local toggle = child:FindFirstChildWhichIsA("TextButton", true)
			if label and toggle then
				rows[string.lower(label.Text)] = child
			end
		end
	end
	return rows
end

local toggleRows = findToggleRows()
local markersToggleFrame = toggleRows["markers"]
local netsToggleFrame = toggleRows["safety nets"] or toggleRows["nets"]
local lightsToggleFrame = toggleRows["marker lights"] or toggleRows["lights"]

local function BindPhysicalToggle(frame, stateKey, callback)
	if not frame then return function() end end
	local toggleBg = frame:FindFirstChildWhichIsA("TextButton", true)
	if not toggleBg then return function() end end
	local knob = toggleBg:FindFirstChildWhichIsA("Frame", true)
	if not knob then return function() end end

	local isOn = editState[stateKey]

	local function setVisuals(on)
		toggleBg.BackgroundColor3 = on and Color3.fromRGB(80, 200, 120) or Color3.fromRGB(80, 80, 80)
		knob.Position = on and UDim2.new(1, -23, 0.5, -10) or UDim2.new(0, 3, 0.5, -10)
	end

	bindGuiButton(toggleBg, function()
		isOn = not isOn
		TweenService:Create(toggleBg, TweenInfo.new(0.2), { BackgroundColor3 = isOn and Color3.fromRGB(80, 200, 120) or Color3.fromRGB(80, 80, 80) }):Play()
		TweenService:Create(knob, TweenInfo.new(0.2, Enum.EasingStyle.Quad), { Position = isOn and UDim2.new(1, -23, 0.5, -10) or UDim2.new(0, 3, 0.5, -10) }):Play()
		editState[stateKey] = isOn
		if callback then callback(isOn) end
	end)

	return function(val)
		isOn = val
		editState[stateKey] = val
		setVisuals(val)
	end
end

print("[TrailEditorClient] Binding physical toggles.")
local setMarkers, setNets, setLights

setMarkers = BindPhysicalToggle(markersToggleFrame, "markers", function(isOn)
	if isOn and editState.nets then setNets(false) end
	if not isOn and editState.markerLights then setLights(false) end
end)

setNets = BindPhysicalToggle(netsToggleFrame, "nets", function(isOn)
	if isOn then
		if editState.markers then setMarkers(false) end
		if editState.markerLights then setLights(false) end
	end
end)

setLights = BindPhysicalToggle(lightsToggleFrame, "markerLights", function(isOn)
	if isOn then
		if editState.nets then setNets(false) end
		if not editState.markers then setMarkers(true) end
	end
end)

local function ResolveSliderParts(section)
	if not section then return nil end
	local contentFrame, titleLabel, valueLabel, trackBg, fill, knob

	for _, child in ipairs(section:GetChildren()) do
		if child:IsA("Frame") then
			local labelCount = 0
			local hasButton = false
			for _, desc in ipairs(child:GetDescendants()) do
				if desc:IsA("TextLabel") then
					labelCount += 1
				elseif desc:IsA("TextButton") then
					hasButton = true
				end
			end
			if labelCount >= 2 and hasButton then
				contentFrame = child
				break
			end
		end
	end
	if not contentFrame then return nil end

	for _, desc in ipairs(contentFrame:GetDescendants()) do
		if desc:IsA("TextLabel") then
			if desc.TextXAlignment == Enum.TextXAlignment.Right then
				valueLabel = valueLabel or desc
			else
				titleLabel = titleLabel or desc
			end
		elseif desc:IsA("TextButton") then
			knob = knob or desc
		end
	end

	if knob then
		local current = knob.Parent
		while current and current ~= contentFrame do
			if current:IsA("Frame") then
				trackBg = current
				break
			end
			current = current.Parent
		end
	end

	if trackBg then
		for _, child in ipairs(trackBg:GetChildren()) do
			if child:IsA("Frame") and child ~= knob then
				fill = fill or child
			end
		end
	end

	return {
		contentFrame = contentFrame,
		titleLabel = titleLabel,
		valueLabel = valueLabel,
		trackBg = trackBg,
		fill = fill,
		knob = knob,
	}
end

local function EnsureWidthSection()
	local existing = EditorPanel:FindFirstChild("WidthSection")
	if existing then return existing end
	if not GladeSection then return nil end
	local clone = GladeSection:Clone()
	clone.Name = "WidthSection"
	clone.Visible = false
	clone.Parent = EditorPanel
	return clone
end

local WidthSection = EnsureWidthSection()

local function BindSlider(section, formatter, callback)
	local parts = ResolveSliderParts(section)
	local slider = {
		section = section,
		parts = parts,
		min = 0,
		max = 100,
		value = 0,
		dragging = false,
	}

	local function applyValue(rawValue)
		if not slider.parts then return end
		local value = math.clamp(rawValue, slider.min, slider.max)
		slider.value = value
		local denom = math.max(0.0001, slider.max - slider.min)
		local relX = math.clamp((value - slider.min) / denom, 0, 1)
		slider.parts.fill.Size = UDim2.new(relX, 0, 1, 0)
		slider.parts.knob.Position = UDim2.new(relX, -9, 0.5, -9)
		slider.parts.valueLabel.Text = formatter(value)
		if callback then callback(value) end
	end

	if slider.parts and slider.parts.valueLabel and slider.parts.valueLabel:IsA("TextLabel") then
		local old = slider.parts.valueLabel
		local tb = Instance.new("TextBox")
		tb.Name = old.Name
		tb.Size = old.Size
		tb.Position = old.Position
		tb.AnchorPoint = old.AnchorPoint
		tb.BackgroundTransparency = 1
		tb.Font = old.Font
		tb.TextSize = old.TextSize
		tb.TextColor3 = old.TextColor3
		tb.TextXAlignment = old.TextXAlignment
		tb.TextYAlignment = old.TextYAlignment
		tb.LayoutOrder = old.LayoutOrder
		tb.ClearTextOnFocus = false
		tb.ZIndex = old.ZIndex + 1
		tb.Parent = old.Parent
		tb.Text = old.Text
		old:Destroy()
		slider.parts.valueLabel = tb

		tb.FocusLost:Connect(function()
			local str = tb.Text:match("[%d%.]+")
			local num = tonumber(str)
			if num then
				applyValue(num)
			else
				tb.Text = formatter(slider.value)
			end
		end)
	end

	function slider:setBounds(minValue, maxValue)
		slider.min = minValue
		slider.max = math.max(minValue, maxValue)
		applyValue(slider.value)
	end

	function slider:setValue(value)
		applyValue(value)
	end

	function slider:setTitle(text)
		if slider.parts and slider.parts.titleLabel then
			slider.parts.titleLabel.Text = text
		end
	end

	if slider.parts and slider.parts.knob and slider.parts.trackBg then
		slider.parts.knob.InputBegan:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
				slider.dragging = true
			end
		end)
		slider.parts.trackBg.InputBegan:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
				slider.dragging = true
				local trackAbsPos = slider.parts.trackBg.AbsolutePosition.X
				local trackAbsSize = slider.parts.trackBg.AbsoluteSize.X
				local relX = math.clamp((input.Position.X - trackAbsPos) / trackAbsSize, 0, 1)
				applyValue(slider.min + relX * (slider.max - slider.min))
			end
		end)
		UserInputService.InputChanged:Connect(function(input)
			if slider.dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
				local trackAbsPos = slider.parts.trackBg.AbsolutePosition.X
				local trackAbsSize = slider.parts.trackBg.AbsoluteSize.X
				local relX = math.clamp((input.Position.X - trackAbsPos) / trackAbsSize, 0, 1)
				applyValue(slider.min + relX * (slider.max - slider.min))
			end
		end)
		UserInputService.InputEnded:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
				slider.dragging = false
			end
		end)
	end

	return slider
end

local gladeSlider = BindSlider(GladeSection, function(value)
	return tostring(math.floor(value + 0.5)) .. "%"
end, function(value)
	editState.gladeDensity = math.floor(value + 0.5)
end)
if gladeSlider then
	gladeSlider:setBounds(0, 100)
	gladeSlider:setTitle("Glade Density")
end

local widthSlider = BindSlider(WidthSection, function(value)
	local rounded = math.floor(value * 10 + 0.5) / 10
	return tostring(rounded) .. " studs"
end, function(value)
	editState.width = math.floor(value * 10 + 0.5) / 10
end)
if widthSlider then
	widthSlider:setTitle("Width")
end

local function getWidthBounds(model)
	if not model then return 30, 160 end
	if model:GetAttribute("IsQueue") == true or model:GetAttribute("IsPath") == true then
		return 1, 160
	end
	return 30, 160
end

local function setDensityVisuals(val)
	editState.gladeDensity = val
	if gladeSlider then
		gladeSlider:setBounds(0, 100)
		gladeSlider:setValue(val)
	end
end

local function setWidthVisuals(model, val)
	editState.width = val
	if widthSlider then
		local minWidth, maxWidth = getWidthBounds(model)
		widthSlider:setBounds(minWidth, maxWidth)
		widthSlider:setValue(val)
	end
end

local function hasEditableWidth(model)
	return model and model:GetAttribute("Difficulty") ~= nil
end

local function ensureMobilePromptGui()
	if MobilePromptGui or not isMobileTrailMode() then
		return
	end
	MobilePromptGui = Instance.new("ScreenGui")
	MobilePromptGui.Name = "TrailEditorMobilePrompt"
	MobilePromptGui.ResetOnSpawn = false
	MobilePromptGui.IgnoreGuiInset = true
	MobilePromptGui.Parent = PlayerGui

	MobileEditButton = Instance.new("TextButton")
	MobileEditButton.Name = "OpenTrailEditorButton"
	MobileEditButton.AnchorPoint = Vector2.new(1, 1)
	MobileEditButton.Position = UDim2.new(1, -18, 1, -164)
	MobileEditButton.Size = UDim2.new(0, 160, 0, 48)
	MobileEditButton.BackgroundColor3 = Color3.fromRGB(36, 118, 212)
	MobileEditButton.BorderSizePixel = 0
	MobileEditButton.Font = Enum.Font.GothamBold
	MobileEditButton.Text = "EDIT TRAIL"
	MobileEditButton.TextSize = 16
	MobileEditButton.TextColor3 = Color3.fromRGB(255, 255, 255)
	MobileEditButton.Visible = false
	MobileEditButton.Parent = MobilePromptGui
	Instance.new("UICorner", MobileEditButton).CornerRadius = UDim.new(0, 10)

	MobileReticle = Instance.new("Frame")
	MobileReticle.Name = "TrailReticle"
	MobileReticle.AnchorPoint = Vector2.new(0.5, 0.5)
	MobileReticle.Position = UDim2.new(0.5, 0, 0.5, 0)
	MobileReticle.Size = UDim2.fromOffset(10, 10)
	MobileReticle.BackgroundColor3 = Color3.fromRGB(80, 200, 255)
	MobileReticle.BorderSizePixel = 0
	MobileReticle.Visible = false
	MobileReticle.Parent = MobilePromptGui
	Instance.new("UICorner", MobileReticle).CornerRadius = UDim.new(1, 0)
end

local function refreshMobilePrompt()
	ensureMobilePromptGui()
	if not MobileEditButton then
		return
	end
	local modeValue = PlayerGui:FindFirstChild("ModeState") or ReplicatedStorage:FindFirstChild("ModeState")
	local isBusy = modeValue and modeValue:IsA("StringValue") and modeValue.Value ~= ""
	local canAimForTrail = isMobileTrailMode() and not isEditorOpen and not isBusy and not isBuildMenuOpen()
	mobilePromptTarget = nil
	if canAimForTrail and raycastSlopeAtPointer and getCenterAimPointer and isPointerBlockedByGui then
		local pointer = getCenterAimPointer()
		if not isPointerBlockedByGui(pointer) then
			mobilePromptTarget = raycastSlopeAtPointer(pointer)
		end
	end
	local showButton = mobilePromptTarget ~= nil
	MobileEditButton.Visible = showButton
	MobileEditButton.Active = showButton
	MobileEditButton.AutoButtonColor = showButton
	MobileEditButton.BackgroundColor3 = showButton and Color3.fromRGB(36, 118, 212) or Color3.fromRGB(64, 70, 80)
	MobileEditButton.TextTransparency = showButton and 0 or 0.3
	MobileReticle.Visible = canAimForTrail
end

local function layoutEditorPanel(model, isGlade)
	local hasWidth = hasEditableWidth(model)
	local panelHeight = 260
	local applyY = 210
	if WidthSection then
		WidthSection.Visible = hasWidth
		WidthSection.Position = UDim2.new(0, 0, 0, 205)
		if hasWidth then
			panelHeight += 70
			applyY += 70
		end
	end
	if GladeSection then
		GladeSection.Visible = isGlade
		if isGlade then
			GladeSection.Position = UDim2.new(0, 0, 0, hasWidth and 275 or 205)
			panelHeight += 70
			applyY += 70
		end
	end
	EditorPanel.Size = UDim2.new(0, 280, 0, panelHeight)
	if ApplyBtn then
		ApplyBtn.Position = UDim2.new(0, 10, 0, applyY)
	end
end

isBuildMenuOpen = function()
	local modeValue = PlayerGui:FindFirstChild("ModeState") or ReplicatedStorage:FindFirstChild("ModeState")
	if modeValue and modeValue:IsA("StringValue") then
		local v = modeValue.Value:lower()
		if v == "build" or v == "place" or v == "placement" then return true end
	end
	if PlayerGui then
		for _, gui in ipairs(PlayerGui:GetChildren()) do
			if gui.Name == "PlacementGui" and gui.Enabled then return true end
		end
	end
	return false
end

local function isSlopeModelCandidate(model)
	if not (model and model:IsA("Model")) then return false end
	return model:GetAttribute("Type") == "Slope"
		or model:GetAttribute("Difficulty") ~= nil
		or model:GetAttribute("RawPoints") ~= nil
end

local function findSlopeModelByUUID(uuid)
	if not uuid then return nil end
	local placedObjects = workspace:FindFirstChild("PlacedObjects")
	if not placedObjects then return nil end
	for _, child in ipairs(placedObjects:GetDescendants()) do
		if child:IsA("Model") and child:GetAttribute("UUID") == uuid and isSlopeModelCandidate(child) then
			return child
		end
	end
	return nil
end

local function openEditor(model)
	if not model then return end
	print("[TrailEditorClient] Opening editor for slope: " .. model.Name)
	selectedModel = model

	if selectionBox then selectionBox:Destroy() end
	selectionBox = Instance.new("SelectionBox")
	selectionBox.Color3 = Color3.fromRGB(80, 200, 255)
	selectionBox.LineThickness = 0.06
	selectionBox.SurfaceTransparency = 0.85
	selectionBox.SurfaceColor3 = Color3.fromRGB(80, 200, 255)
	selectionBox.Adornee = model
	selectionBox.Parent = PlayerGui

	EditorGui.Enabled = true
	EditorPanel.Visible = true
	isEditorOpen = true
	refreshMobilePrompt()
	ClosePanels:Fire("TrailEditor")

	local diff = model:GetAttribute("Difficulty") or "Green"
	if SlopeName then
		SlopeName.Text = tostring(diff) .. " run"
	end
	if NameInput then
		NameInput.Text = sanitizeCustomName(model:GetAttribute("CustomName"))
		NameInput.PlaceholderText = getSlopeDisplayName(model)
	end

	setMarkers(model:GetAttribute("MarkersEnabled") ~= false)
	setNets(model:GetAttribute("NetsEnabled") == true)
	setLights(model:GetAttribute("MarkerLightsEnabled") ~= false)
	setWidthVisuals(model, tonumber(model:GetAttribute("SlopeWidth")) or 90)

	local isGlade = model.Name:lower():find("glade") or (diff or ""):lower():find("glade")
	if isGlade then
		setDensityVisuals(model:GetAttribute("GladeDensity") or 50)
	end
	layoutEditorPanel(model, isGlade)

	EditorPanel.Position = UDim2.new(1, 20, 0.5, 0)
	TweenService:Create(EditorPanel, TweenInfo.new(0.35, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Position = UDim2.new(1, -300, 0.5, 0) }):Play()
end

local function closeEditor()
	print("[TrailEditorClient] Closing editor.")
	isEditorOpen = false
	selectedModel = nil
	refreshMobilePrompt()

	if selectionBox then selectionBox:Destroy(); selectionBox = nil end
	TweenService:Create(EditorPanel, TweenInfo.new(0.25, Enum.EasingStyle.Quad, Enum.EasingDirection.In), { Position = UDim2.new(1, 20, 0.5, 0) }):Play()
	task.delay(0.3, function()
		if EditorPanel then
			EditorPanel.Visible = false
		end
		if EditorGui then
			EditorGui.Enabled = false
		end
	end)
end

bindGuiButton(CloseBtn, closeEditor)
ensureMobilePromptGui()
if MobileEditButton then
	bindGuiButton(MobileEditButton, function()
		if isEditorOpen then
			closeEditor()
			return
		end
		local modeValue = PlayerGui:FindFirstChild("ModeState") or ReplicatedStorage:FindFirstChild("ModeState")
		if modeValue and modeValue:IsA("StringValue") and modeValue.Value ~= "" then
			return
		end
		local slopeModel = mobilePromptTarget or raycastSlopeAtPointer(getCenterAimPointer())
		if slopeModel then
			openEditor(slopeModel)
		else
			refreshMobilePrompt()
		end
	end)
	refreshMobilePrompt()
end

if ApplyBtn then
	bindGuiButton(ApplyBtn, function()
		if not selectedModel then return end
		print("[TrailEditorClient] Applying changes for slope: " .. selectedModel.Name)
		local options = {
			markers = editState.markers,
			nets = editState.nets,
			markerLights = editState.markerLights,
		}
		local isGlade = selectedModel.Name:lower():find("glade") or (selectedModel:GetAttribute("Difficulty") or ""):lower():find("glade")
		if isGlade then options.gladeDensity = editState.gladeDensity end
		if hasEditableWidth(selectedModel) then
			options.width = editState.width
		end

		local editedUuid = selectedModel:GetAttribute("UUID")
		local widthChanged = hasEditableWidth(selectedModel) and math.abs((tonumber(selectedModel:GetAttribute("SlopeWidth")) or editState.width) - editState.width) >= 0.5
		local desiredCustomName = NameInput and sanitizeCustomName(NameInput.Text) or ""
		local currentCustomName = sanitizeCustomName(selectedModel:GetAttribute("CustomName"))
		if RenamePlacedObject and desiredCustomName ~= currentCustomName then
			RenamePlacedObject:FireServer(selectedModel, desiredCustomName)
		end
		EditSlopeRemote:FireServer(selectedModel, options)

		if editedUuid then
			-- PATCHED: Keep editor open during rebuild so retry loop can re-acquire
			local keepEditorOpenForRebuild = true
			task.spawn(function()
				-- PATCHED: Always use generous search for renamed/rebuilt slopes
				local attempts = 20
				local delayTime = 0.2
				for _ = 1, attempts do
					local replacement = findSlopeModelByUUID(editedUuid)
					if replacement then
						-- Always re-open the editor with the new model
						if replacement ~= selectedModel or not selectedModel or not selectedModel.Parent then
							openEditor(replacement)
						else
							selectedModel = replacement
						end
						keepEditorOpenForRebuild = false
						return
					end
					task.wait(delayTime)
				end
				keepEditorOpenForRebuild = false
			end)
		end

		TweenService:Create(ApplyBtn, TweenInfo.new(0.15), {BackgroundColor3 = Color3.fromRGB(100, 255, 140)}):Play()
		task.delay(0.3, function() if ApplyBtn.Parent then TweenService:Create(ApplyBtn, TweenInfo.new(0.3), {BackgroundColor3 = Color3.fromRGB(60, 160, 90)}):Play() end end)
	end)
end

local function findSlopeModelFromPart(part)
	if not part then return nil end
	local current = part
	while current and current ~= workspace do
		if isSlopeModelCandidate(current) then return current end
		current = current.Parent
	end
	return nil
end

raycastSlopeAtPointer = function(pointer)
	local ray = Camera:ViewportPointToRay(pointer.X, pointer.Y)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = {Player.Character}
	local result = workspace:Raycast(ray.Origin, ray.Direction * 1000, params)
	if not result then
		return nil
	end
	return findSlopeModelFromPart(result.Instance)
end

getCenterAimPointer = function()
	local viewport = Camera and Camera.ViewportSize or Vector2.new(0, 0)
	return Vector2.new(viewport.X * 0.5, viewport.Y * 0.5)
end

isPointerBlockedByGui = function(pointer)
	local guiObjects = PlayerGui:GetGuiObjectsAtPosition(pointer.X, pointer.Y)
	for _, obj in ipairs(guiObjects) do
		if obj.Visible then
			return true
		end
	end
	return false
end

RunService.RenderStepped:Connect(function()
	if isMobileTrailMode() then
		refreshMobilePrompt()
	elseif MobileEditButton then
		mobilePromptTarget = nil
		MobileEditButton.Visible = false
		MobileEditButton.Active = false
		MobileReticle.Visible = false
	end
end)

UserInputService.InputBegan:Connect(function(input, processed)
	if processed then return end
	if input.UserInputType ~= Enum.UserInputType.MouseButton1 and input.UserInputType ~= Enum.UserInputType.Touch then return end
	if input.UserInputType == Enum.UserInputType.Touch and isMobileTrailMode() then
		return
	end

	local pointer = Vector2.new(input.Position.X, input.Position.Y)
	if isPointerBlockedByGui(pointer) then return end

	if isEditorOpen then
		local slopeModel = raycastSlopeAtPointer(pointer)
		if slopeModel then openEditor(slopeModel); return end
		closeEditor()
		return
	end

	local modeValue = PlayerGui:FindFirstChild("ModeState") or ReplicatedStorage:FindFirstChild("ModeState")
	if modeValue and modeValue:IsA("StringValue") and modeValue.Value ~= "" then return end

	local slopeModel = raycastSlopeAtPointer(pointer)
	if slopeModel then openEditor(slopeModel) end
end)

UserInputService.InputBegan:Connect(function(input, processed)
	if input.KeyCode == Enum.KeyCode.Escape and isEditorOpen then closeEditor() end
end)

ClosePanels.Event:Connect(function(source)
	if source == "TrailEditor" then return end
	if isEditorOpen then closeEditor() else refreshMobilePrompt() end
end)

Player.CharacterAdded:Connect(function()
	task.defer(function()
		if isEditorOpen then
			closeEditor()
		else
			selectedModel = nil
			mobilePromptTarget = nil
			if selectionBox then selectionBox:Destroy(); selectionBox = nil end
			if EditorPanel then EditorPanel.Visible = false end
			if EditorGui then EditorGui.Enabled = false end
			refreshMobilePrompt()
		end
	end)
end)

local modeValue = PlayerGui:FindFirstChild("ModeState") or ReplicatedStorage:FindFirstChild("ModeState")
if modeValue and modeValue:IsA("StringValue") then
	modeValue:GetPropertyChangedSignal("Value"):Connect(refreshMobilePrompt)
end

task.defer(refreshMobilePrompt)
print("[TrailEditorClient] Ready.")