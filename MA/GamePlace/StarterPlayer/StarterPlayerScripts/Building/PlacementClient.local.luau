--[=[ PATH: StarterPlayerScripts/PlacementClient | TYPE: LocalScript ]=]--
--[[
	SCRIPT DESCRIPTION:
	Handles client-side item placement logic, including ghost model rendering, physics raycasting, slope limit validation, money checks, mobile controls, and server dispatching. Integrates with physical UI elements.

	OLD SCRIPT CAPABILITIES:
	- Enforced `MaxDistance`, minimum length, and `MaxAngle`.
	- Live money check against player leaderstats.
	- Dynamic UI warnings.
	- Ghost model collision and coloring.
	- Mapped physical UI instances from `GeneratedPlacementUIs`.
	- Halted due to infinite yield on improperly named CancelButton.

	CHANGES (ADDED/REMOVED):
	- ADDED: Forced `Visible = false` and `Enabled = false` on all root GUI elements and templates during initialization to clear screen clutter.
	- ADDED: 3-second timeouts to all `WaitForChild` calls for UI components to prevent infinite yields.
	- ADDED: Fallback `FindFirstChildWhichIsA` lookups for UI buttons in case the UI developer renames them.
	- REMOVED: None. Retained all core placement validation, ghost mechanics, and server remotes.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
local ContextActionService = game:GetService("ContextActionService")
local GuiService = game:GetService("GuiService")
local BuildStatusIndicator = require(ReplicatedStorage:WaitForChild("BuildStatusIndicator"))

local CarpetTerrainUtil = {}
CarpetTerrainUtil.Raycast = RaycastParams.new()
CarpetTerrainUtil.Raycast.FilterType = Enum.RaycastFilterType.Include
CarpetTerrainUtil.Raycast.FilterDescendantsInstances = {workspace.Terrain}
CarpetTerrainUtil.Raycast.IgnoreWater = true

local Player = Players.LocalPlayer
local PlayerMouse = Player:GetMouse()
local Config = require(ReplicatedStorage:WaitForChild("Config"))
local CustomBuildingConfig = require(ReplicatedStorage:WaitForChild("CustomBuildingConfig"))
local DecorMilestoneConfig = require(ReplicatedStorage:WaitForChild("DecorMilestoneConfig"))
local Events = ReplicatedStorage:WaitForChild("Events")
local RequestPlaceItem = Events:WaitForChild("RequestPlaceItem")
local Assets = ReplicatedStorage:WaitForChild("Assets")
local CheckUnlockClient = Events:FindFirstChild("CheckUnlockClient")
local ResearchUpdate = Events:FindFirstChild("ResearchUpdate")
local GetResearchState = Events:FindFirstChild("GetResearchState")
local DecorMilestoneUpdate = Events:FindFirstChild("DecorMilestoneUpdate")
local GetDecorMilestoneState = Events:FindFirstChild("GetDecorMilestoneState")

local ResearchConfig = nil
do
	local researchFolder = ReplicatedStorage:FindFirstChild("Research")
	local module = nil
	if researchFolder then module = researchFolder:FindFirstChild("ResearchConfig") end
	if not module then module = ReplicatedStorage:FindFirstChild("ResearchConfig") end
	if module and module:IsA("ModuleScript") then ResearchConfig = require(module) end
end

function CarpetTerrainUtil.samplePoint(flatPos, fallbackY)
	local originY = math.max(flatPos.Y + 600, fallbackY + 600, 2500)
	local result = workspace:Raycast(Vector3.new(flatPos.X, originY, flatPos.Z), Vector3.new(0, -(originY + 4000), 0), CarpetTerrainUtil.Raycast)
	if result then
		return Vector3.new(flatPos.X, result.Position.Y, flatPos.Z)
	end
	return Vector3.new(flatPos.X, fallbackY, flatPos.Z)
end

function CarpetTerrainUtil.buildSamples(startPos, endPos, numSamples)
	numSamples = math.max(2, numSamples or 2)
	local samples = table.create(numSamples)
	for i = 1, numSamples do
		local t = (i - 1) / (numSamples - 1)
		local flatPos = startPos:Lerp(endPos, t)
		samples[i] = CarpetTerrainUtil.samplePoint(flatPos, flatPos.Y)
	end
	for _ = 1, 2 do
		for i = 2, numSamples - 1 do
			local prevY = samples[i - 1].Y
			local curr = samples[i]
			local nextY = samples[i + 1].Y
			samples[i] = Vector3.new(curr.X, (prevY + curr.Y + nextY) / 3, curr.Z)
		end
	end
	return samples
end

-- Check terrain roughness along a carpet path. Returns true if placeable, false + message if too rough.
function CarpetTerrainUtil.checkTerrainRoughness(startPos, endPos, itemData)
	local maxRoughness = (itemData and itemData.MaxTerrainRoughness) or 8
	local dist = (endPos - startPos).Magnitude
	local numSamples = math.clamp(math.ceil(dist / 6), 4, 60)
	local rawSamples = table.create(numSamples)
	for i = 1, numSamples do
		local t = (i - 1) / (numSamples - 1)
		local flatPos = startPos:Lerp(endPos, t)
		rawSamples[i] = CarpetTerrainUtil.samplePoint(flatPos, flatPos.Y)
	end

	-- Check adjacent height jumps against roughness threshold
	local worstJump = 0
	for i = 2, numSamples do
		local jump = math.abs(rawSamples[i].Y - rawSamples[i - 1].Y)
		if jump > worstJump then
			worstJump = jump
		end
	end

	if worstJump > maxRoughness then
		return false, "TERRAIN TOO ROUGH"
	end

	-- Also check overall height variance — reject if terrain is mountainous
	local startY = rawSamples[1].Y
	local endY = rawSamples[numSamples].Y
	for i = 2, numSamples - 1 do
		local expectedY = startY + (endY - startY) * ((i - 1) / (numSamples - 1))
		local deviation = math.abs(rawSamples[i].Y - expectedY)
		if deviation > maxRoughness * 1.5 then
			return false, "TERRAIN TOO UNEVEN"
		end
	end

	return true, nil
end

-- UI References
local PlayerGui = Player:WaitForChild("PlayerGui")
local MainHUD = PlayerGui:WaitForChild("MainHUD")
local BuildFrame = MainHUD:WaitForChild("BuildFrame")
local Dock = MainHUD:WaitForChild("Dock")

-- Nudge the dock up on mobile/touch so it doesn't hide behind Roblox native controls
if UserInputService.TouchEnabled then
	local guiService = game:GetService("GuiService")
	local insetTop, insetBottom = 0, 0
	pcall(function()
		local insets = guiService:GetGuiInset()
		insetTop = insets.Y
	end)
	pcall(function()
		-- Use SafeAreaInsets if available (modern Roblox)
		local safeArea = guiService:GetSafeAreaInsets()
		if safeArea then insetBottom = safeArea.bottom or 0 end
	end)
	local bottomPad = math.max(insetBottom, 36) -- at least 36px above bottom edge
	Dock.Position = UDim2.new(Dock.Position.X.Scale, Dock.Position.X.Offset, 1, -bottomPad - Dock.AbsoluteSize.Y)
end

local Header = BuildFrame:WaitForChild("Header")
local CloseButton = Header:WaitForChild("CloseButton")
local CategoryTabs = Header:WaitForChild("CategoryTabs")
local ContentFrame = BuildFrame:WaitForChild("Content")
SearchButton = Header:FindFirstChild("SearchButton")
SearchPanel = BuildFrame:FindFirstChild("SearchPanel")
SearchBox = SearchPanel and SearchPanel:FindFirstChild("SearchBox")

-- Physical Generated UIs Hookup (Hardened)
local PlacementHelperUI = PlayerGui:FindFirstChild("PlacementUI") or PlayerGui:WaitForChild("PlacementUI", 3)
if not PlacementHelperUI then return end

local CostGui = PlacementHelperUI
CostGui.Enabled = false
CostGui.DisplayOrder = math.max(CostGui.DisplayOrder, 40)

local MobileControlsGui = CostGui:WaitForChild("PlacementMobileControls", 3)
if MobileControlsGui then MobileControlsGui.Visible = false end

local TooltipGui = CostGui:WaitForChild("PlacementTooltipUI", 3)
if TooltipGui then TooltipGui.Visible = false end

local function resolvePlacementLabel(labelName)
	local direct = CostGui:FindFirstChild(labelName)
	if direct and (direct:IsA("TextLabel") or direct:IsA("TextButton")) then
		return direct
	end
	if TooltipGui then
		local nested = TooltipGui:FindFirstChild(labelName, true)
		if nested and (nested:IsA("TextLabel") or nested:IsA("TextButton")) then
			return nested
		end
	end
	return nil
end

local CostLabel = resolvePlacementLabel("CostLabel")
local WarningLabel = resolvePlacementLabel("WarningLabel")
local HintLabel = resolvePlacementLabel("HintLabel")
if CostLabel then CostLabel.Visible = false end
if WarningLabel then WarningLabel.Visible = false end
if HintLabel then HintLabel.Visible = false end

local MobileActionBtn, MobileCancelBtn, MobileRotateBtn, MobileCostLbl
local function IsCompactTouchViewport()
	if not UserInputService.TouchEnabled then return false end
	if not UserInputService.KeyboardEnabled then return true end
	local camera = workspace.CurrentCamera
	return camera and camera.ViewportSize.X < 900 or false
end

local function ApplyMobilePlacementControlLayout()
	if not MobileControlsGui or not IsCompactTouchViewport() then return end

	MobileControlsGui.Size = UDim2.fromScale(1, 1)
	MobileControlsGui.Position = UDim2.fromScale(0.5, 0)
	MobileControlsGui.AnchorPoint = Vector2.new(0.5, 0)
	MobileControlsGui.BackgroundTransparency = 1
	MobileControlsGui.ZIndex = 30

	local cancelBar = MobileControlsGui:FindFirstChild("CancelBar")
	if cancelBar and cancelBar:IsA("GuiObject") then
		cancelBar.AnchorPoint = Vector2.new(0.5, 1)
		cancelBar.Size = UDim2.fromOffset(188, 40)
		cancelBar.Position = UDim2.new(0.5, 0, 1, -255)
		cancelBar.BackgroundTransparency = 0.18
		cancelBar.ZIndex = 31
		local cancelLabel = cancelBar:FindFirstChildWhichIsA("TextLabel")
		if cancelLabel then
			cancelLabel.Size = UDim2.new(0.45, -4, 1, 0)
			cancelLabel.Position = UDim2.new(0, 10, 0, 0)
			cancelLabel.TextSize = 16
			cancelLabel.TextWrapped = false
			cancelLabel.ZIndex = 32
		end
		local cancelButton = cancelBar:FindFirstChild("CancelButton") or cancelBar:FindFirstChildWhichIsA("TextButton")
		if cancelButton then
			cancelButton.AnchorPoint = Vector2.new(1, 0.5)
			cancelButton.Size = UDim2.fromOffset(96, 34)
			cancelButton.Position = UDim2.new(1, -8, 0.5, 0)
			cancelButton.TextSize = 16
			cancelButton.ZIndex = 32
		end
	end

	if MobileCostLbl then
		MobileCostLbl.AnchorPoint = Vector2.new(0.5, 1)
		MobileCostLbl.Size = UDim2.fromOffset(260, 28)
		MobileCostLbl.Position = UDim2.new(0.5, 0, 1, -218)
		MobileCostLbl.TextSize = 18
		MobileCostLbl.ZIndex = 32
	end

	if MobileRotateBtn then
		MobileRotateBtn.AnchorPoint = Vector2.new(0, 1)
		MobileRotateBtn.Size = UDim2.fromOffset(88, 52)
		MobileRotateBtn.Position = UDim2.new(0, 18, 1, -250)
		MobileRotateBtn.TextSize = 18
		MobileRotateBtn.ZIndex = 32
	end

	if MobileActionBtn then
		MobileActionBtn.AnchorPoint = Vector2.new(1, 1)
		MobileActionBtn.Size = UDim2.fromOffset(88, 52)
		MobileActionBtn.Position = UDim2.new(1, -18, 1, -250)
		MobileActionBtn.TextSize = 18
		MobileActionBtn.ZIndex = 32
	end
end

if MobileControlsGui then
	MobileActionBtn = MobileControlsGui:WaitForChild("ActionButton", 3) or MobileControlsGui:FindFirstChildWhichIsA("TextButton")
	local cancelBar = MobileControlsGui:WaitForChild("CancelBar", 3)
	if cancelBar then
		MobileCancelBtn = cancelBar:FindFirstChild("CancelButton") or cancelBar:FindFirstChild("TextButton") or cancelBar:FindFirstChildWhichIsA("TextButton")
	end
	MobileRotateBtn = MobileControlsGui:WaitForChild("RotateButton", 3)
	MobileCostLbl = MobileControlsGui:WaitForChild("MobileCostLabel", 3) or MobileControlsGui:FindFirstChildWhichIsA("TextLabel")
	ApplyMobilePlacementControlLayout()
end

InfoPanel = BuildFrame:WaitForChild("InfoPanel", 3)
if InfoPanel then InfoPanel.Visible = false end

local TemplateItemCard = BuildFrame:FindFirstChild("PlacementItemCard") or CostGui:FindFirstChild("PlacementItemCard") or BuildFrame:WaitForChild("PlacementItemCard", 3)
if TemplateItemCard then TemplateItemCard.Visible = false end

local TemplateLockOverlay = nil
if TemplateItemCard then
	TemplateLockOverlay = TemplateItemCard:WaitForChild("LockOverlay", 3)
	if TemplateLockOverlay then TemplateLockOverlay.Visible = false end
end

-- State
isMenuOpen = false
isPlacing = false
isValidPlacement = true
placementWarning = ""
lastLoggedValidity = true
isProcessingPlacement = false 
currentItemName = nil
currentGhost = nil
startGhost = nil
currentRotation = 0
placementStep = 1
liftStartCFrame = nil
buttonByItemName = {}
activeSpinners = {}
latestResearchSnapshot = { Unlocked = {} }
latestDecorMilestoneSnapshot = { BestScore = 0, CurrentScore = 0, UnlockedItems = {}, UnlockedMilestones = {}, NextMilestone = nil }
hasResearchSnapshot = false
hasDecorMilestoneSnapshot = false
unlockTechByItem = {}
currentCategory = "Buildings"
placementGhostParts = {}
lastGhostColorKey = nil
buildSearchText = ""
buildSearchOpen = false
local CreateViewport
local lastObstructionCheckPos = nil
local lastObstructionCheckStep = 0
local lastObstructionCheckAt = 0
local lastObstructed = false
local lastComputedCost = 0
local mobileWorldHit = nil
local placementReticle = nil
local mobileHintLabel = nil
local hybridTouchPlacementActive = false
local currentInfoItemName = nil
local currentHeightOffset = 0
local freecamRotateActive = false
local freecamCameraYaw = 0
local freecamCameraPitch = 0
local FREECAM_ROTATE_SENSITIVITY = 0.0032

local NET_ITEM_KEY = "net"
local NET_SNAP_THRESHOLD = 8
local OBSTRUCTION_CHECK_INTERVAL = 0.08
local OBSTRUCTION_MOVE_THRESHOLD = 0.75
local DecorMilestoneStatusLabel = nil
local MAX_PLACEMENT_HEIGHT_OFFSET = 250
local DEFAULT_PLACEMENT_HEIGHT_STEP = 2
local FINE_PLACEMENT_HEIGHT_STEP = 0.5

local function GetPlacementHeightStep()
	if UserInputService:IsKeyDown(Enum.KeyCode.LeftShift) or UserInputService:IsKeyDown(Enum.KeyCode.RightShift) then
		return FINE_PLACEMENT_HEIGHT_STEP
	end
	return DEFAULT_PLACEMENT_HEIGHT_STEP
end

local function AdjustPlacementHeight(delta)
	currentHeightOffset = math.clamp(currentHeightOffset + delta, -MAX_PLACEMENT_HEIGHT_OFFSET, MAX_PLACEMENT_HEIGHT_OFFSET)
end

local function FormatPlacementHeightOffset()
	local rounded = math.round(currentHeightOffset * 10) / 10
	if math.abs(rounded) < 0.05 then
		return "0"
	end
	if math.abs(rounded - math.round(rounded)) < 0.05 then
		return string.format("%+d", math.round(rounded))
	end
	return string.format("%+.1f", rounded)
end

local placementFeedbackToken = 0
local function showPlacementFailure(message)
	placementFeedbackToken += 1
	local token = placementFeedbackToken
	BuildStatusIndicator.show(PlayerGui, tostring(message or "PLACE FAILED"))
	task.delay(1.5, function()
		if placementFeedbackToken == token then
			BuildStatusIndicator.hide(PlayerGui)
		end
	end)
end

-- Freecam State
local FreecamPart = nil
local freecamReturnCharacter = nil
local freecamReturnCFrame = nil
local Controls = nil

-- MODE CONFLICT PREVENTION
local ModeState = PlayerGui:FindFirstChild("ModeState") or Instance.new("StringValue", PlayerGui)
ModeState.Name = "ModeState"
ModeState.Value = ""

local TWEEN_INFO = TweenInfo.new(0.4, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local POS_OPEN = UDim2.new(0.5, 0, 0.5, 0)
local POS_CLOSED = UDim2.new(0.5, 0, 1.5, 0)
local PLACEMENT_CANCEL_ACTION = "PlacementCancelAction"
local PLACEMENT_ROTATE_CW_ACTION = "PlacementRotateClockwise"
local PLACEMENT_ROTATE_CCW_ACTION = "PlacementRotateCounterClockwise"
local ROTATE_HOLD_INITIAL_DELAY = 0.18
local ROTATE_HOLD_REPEAT_INTERVAL = 0.045
local rotateHoldTokens = {}
local CreateGhost, ToggleMenu, ActivatePlacement, ConfirmPlacement, UpdateGhost, setGhostUpdateEnabled
local buildMenuTween = nil
local buildMenuTweenToken = 0
local buildViewportConnection = nil
local isMenuOpen = false
local InfoPanel = nil

local function rotatePlacement(step)
	if not isPlacing then
		return
	end
	currentRotation = (currentRotation + step) % 360
	if currentGhost then
		UpdateGhost(0)
	end
end

local function stopRotateHold(actionName)
	rotateHoldTokens[actionName] = (rotateHoldTokens[actionName] or 0) + 1
end

local function startRotateHold(actionName, keyCode, step)
	stopRotateHold(actionName)
	rotatePlacement(step)
	local token = rotateHoldTokens[actionName]
	task.spawn(function()
		task.wait(ROTATE_HOLD_INITIAL_DELAY)
		while rotateHoldTokens[actionName] == token and isPlacing and UserInputService:IsKeyDown(keyCode) do
			rotatePlacement(step)
			task.wait(ROTATE_HOLD_REPEAT_INTERVAL)
		end
	end)
end

local function unbindPlacementRotateActions()
	stopRotateHold(PLACEMENT_ROTATE_CW_ACTION)
	stopRotateHold(PLACEMENT_ROTATE_CCW_ACTION)
	ContextActionService:UnbindAction(PLACEMENT_ROTATE_CW_ACTION)
	ContextActionService:UnbindAction(PLACEMENT_ROTATE_CCW_ACTION)
end

local function bindPlacementRotateActions()
	unbindPlacementRotateActions()
	ContextActionService:BindActionAtPriority(PLACEMENT_ROTATE_CW_ACTION, function(actionName, inputState)
		if not isPlacing then
			return Enum.ContextActionResult.Pass
		end
		if inputState == Enum.UserInputState.Begin then
			startRotateHold(actionName, Enum.KeyCode.R, 15)
		elseif inputState == Enum.UserInputState.End or inputState == Enum.UserInputState.Cancel then
			stopRotateHold(actionName)
		end
		return Enum.ContextActionResult.Sink
	end, false, Enum.ContextActionPriority.High.Value, Enum.KeyCode.R)
	ContextActionService:BindActionAtPriority(PLACEMENT_ROTATE_CCW_ACTION, function(actionName, inputState)
		if not isPlacing then
			return Enum.ContextActionResult.Pass
		end
		if inputState == Enum.UserInputState.Begin then
			startRotateHold(actionName, Enum.KeyCode.T, -15)
		elseif inputState == Enum.UserInputState.End or inputState == Enum.UserInputState.Cancel then
			stopRotateHold(actionName)
		end
		return Enum.ContextActionResult.Sink
	end, false, Enum.ContextActionPriority.High.Value, Enum.KeyCode.T)
end

local function GetBuildViewportSize()
	local camera = workspace.CurrentCamera
	if camera and camera.ViewportSize.X > 0 and camera.ViewportSize.Y > 0 then
		return camera.ViewportSize
	end
	return Vector2.new(1280, 720)
end

local function applySearchPanelStyling()
	if SearchPanel and SearchPanel:IsA("Frame") then
		SearchPanel.BackgroundColor3 = Color3.fromRGB(17, 19, 24)
		SearchPanel.BackgroundTransparency = 0.02
		SearchPanel.BorderSizePixel = 0
		SearchPanel.ClipsDescendants = true
		local corner = SearchPanel:FindFirstChildOfClass("UICorner") or Instance.new("UICorner")
		corner.CornerRadius = UDim.new(0, 10)
		corner.Parent = SearchPanel
		local stroke = SearchPanel:FindFirstChildOfClass("UIStroke") or Instance.new("UIStroke")
		stroke.Color = Color3.fromRGB(49, 56, 70)
		stroke.Transparency = 0.25
		stroke.Thickness = 1
		stroke.Parent = SearchPanel
	end
	if SearchButton and SearchButton:IsA("GuiButton") then
		SearchButton.BackgroundColor3 = Color3.fromRGB(17, 19, 24)
		SearchButton.BorderSizePixel = 0
		SearchButton.AutoButtonColor = true
		local btnCorner = SearchButton:FindFirstChildOfClass("UICorner") or Instance.new("UICorner")
		btnCorner.CornerRadius = UDim.new(0, 8)
		btnCorner.Parent = SearchButton
		local btnStroke = SearchButton:FindFirstChildOfClass("UIStroke") or Instance.new("UIStroke")
		btnStroke.Color = Color3.fromRGB(49, 56, 70)
		btnStroke.Transparency = 0.35
		btnStroke.Thickness = 1
		btnStroke.Parent = SearchButton
	end
	if SearchBox and SearchBox:IsA("TextBox") then
		SearchBox.BackgroundColor3 = Color3.fromRGB(24, 27, 34)
		SearchBox.BorderSizePixel = 0
		SearchBox.ClearTextOnFocus = false
		SearchBox.TextColor3 = Color3.fromRGB(255, 255, 255)
		SearchBox.PlaceholderColor3 = Color3.fromRGB(125, 130, 145)
		SearchBox.TextSize = 13
		SearchBox.Font = Enum.Font.Gotham
		local boxCorner = SearchBox:FindFirstChildOfClass("UICorner") or Instance.new("UICorner")
		boxCorner.CornerRadius = UDim.new(0, 8)
		boxCorner.Parent = SearchBox
		local boxPad = SearchBox:FindFirstChildOfClass("UIPadding") or Instance.new("UIPadding")
		boxPad.PaddingLeft = UDim.new(0, 8)
		boxPad.PaddingRight = UDim.new(0, 8)
		boxPad.Parent = SearchBox
	end
end

local function ApplyResponsiveBuildLayout()
	local viewport = GetBuildViewportSize()
	local compactTouch = UserInputService.TouchEnabled and (not UserInputService.KeyboardEnabled or viewport.X <= 900 or viewport.Y <= 700)

	local baseWidth = math.max(BuildFrame.AbsoluteSize.X, 640)
	local baseHeight = math.max(BuildFrame.AbsoluteSize.Y, 420)
	local frameWidth = compactTouch and math.clamp(math.floor(viewport.X * 0.92), 560, 980) or baseWidth
	local frameHeight = compactTouch and math.clamp(math.floor(viewport.Y * 0.82), 500, 900) or baseHeight
	local headerHeight = compactTouch and 112 or 100
	local buttonBarHeight = compactTouch and 56 or 52
	local edgePadding = 24
	local controlGap = 8
	local closeWidth = compactTouch and 80 or 72
	local searchWidth = compactTouch and 40 or 38
	local actionRowHeight = 34
	local actionRowTop = headerHeight - actionRowHeight - 4

	if compactTouch then
		BuildFrame.Size = UDim2.fromOffset(frameWidth, frameHeight)
		BuildFrame.AnchorPoint = Vector2.new(0.5, 0.5)
		BuildFrame.Position = isMenuOpen and POS_OPEN or POS_CLOSED
	end

	Header.Size = UDim2.new(1, -16, 0, headerHeight)
	Header.Position = UDim2.fromOffset(8, 8)
	Header.ClipsDescendants = false

	CloseButton.AnchorPoint = Vector2.new(1, 0)
	CloseButton.Size = UDim2.fromOffset(closeWidth, actionRowHeight)
	CloseButton.Position = UDim2.new(1, -edgePadding, 0, actionRowTop)
	if SearchButton and SearchButton:IsA("GuiButton") then
		SearchButton.AnchorPoint = Vector2.new(1, 0)
		SearchButton.Size = UDim2.fromOffset(searchWidth, actionRowHeight)
		SearchButton.Position = UDim2.new(1, -(edgePadding + closeWidth + controlGap), 0, actionRowTop)
	end

	local rightInset = edgePadding + closeWidth + controlGap + searchWidth + 6
	local title = Header:FindFirstChild("Title")
	if title and title:IsA("TextLabel") then
		title.AnchorPoint = Vector2.new(0, 0)
		title.Position = UDim2.fromOffset(12, 8)
		title.Size = UDim2.new(1, -(12 + rightInset), 0, 24)
		title.TextXAlignment = Enum.TextXAlignment.Left
		title.TextYAlignment = Enum.TextYAlignment.Center
	end
	local subtitle = Header:FindFirstChild("Subtitle")
	if subtitle and subtitle:IsA("TextLabel") then
		subtitle.AnchorPoint = Vector2.new(0, 0)
		subtitle.Position = UDim2.fromOffset(12, 34)
		subtitle.Size = UDim2.new(1, -(12 + rightInset), 0, 18)
		subtitle.TextXAlignment = Enum.TextXAlignment.Left
		subtitle.TextYAlignment = Enum.TextYAlignment.Center
	end

	CategoryTabs.AnchorPoint = Vector2.new(0, 0)
	CategoryTabs.Position = UDim2.fromOffset(12, actionRowTop)
	CategoryTabs.Size = UDim2.new(1, -(12 + rightInset), 0, actionRowHeight)
	local categoryLayout = CategoryTabs:FindFirstChildOfClass("UIListLayout")
	if categoryLayout then
		categoryLayout.FillDirection = Enum.FillDirection.Horizontal
		categoryLayout.HorizontalAlignment = Enum.HorizontalAlignment.Left
		categoryLayout.VerticalAlignment = Enum.VerticalAlignment.Center
		categoryLayout.Padding = UDim.new(0, 4)
	end

	ContentFrame.Position = UDim2.fromOffset(10, headerHeight + 12)
	ContentFrame.Size = UDim2.new(1, -20, 1, -(headerHeight + buttonBarHeight + 24))
	ContentFrame.ScrollBarThickness = compactTouch and 10 or 8

	local buttonBar = BuildFrame:FindFirstChild("Buttons")
	if buttonBar and buttonBar:IsA("GuiObject") then
		buttonBar.AnchorPoint = Vector2.new(0.5, 1)
		buttonBar.Position = UDim2.new(0.5, 0, 1, -10)
		buttonBar.Size = UDim2.new(1, -20, 0, buttonBarHeight)
		local layout = buttonBar:FindFirstChildOfClass("UIListLayout")
		if layout then
			layout.FillDirection = Enum.FillDirection.Horizontal
			layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
			layout.VerticalAlignment = Enum.VerticalAlignment.Center
			layout.HorizontalFlex = Enum.UIFlexAlignment.SpaceEvenly
			layout.VerticalFlex = Enum.UIFlexAlignment.None
		end
		for _, child in ipairs(buttonBar:GetChildren()) do
			if child:IsA("GuiButton") then
				child.Size = UDim2.fromOffset(70, 46)
			end
		end
	end

	if SearchPanel and SearchPanel:IsA("GuiObject") then
		applySearchPanelStyling()
		SearchPanel.AnchorPoint = Vector2.new(1, 0)
		SearchPanel.Size = UDim2.fromOffset(math.min(compactTouch and 318 or 300, math.floor(frameWidth * 0.46)), math.max(224, frameHeight - (headerHeight + buttonBarHeight + 24)))
		SearchPanel.Position = UDim2.new(1, -10, 0, headerHeight + 12)
	end

	if InfoPanel then
		InfoPanel.Size = UDim2.fromOffset(math.min(240, frameWidth - 32), 210)
		InfoPanel.Position = UDim2.new(1, -12, 1, -(buttonBarHeight + 14))
		InfoPanel.AnchorPoint = Vector2.new(1, 1)
	end
end

local function BindResponsiveBuildLayout()
	if buildViewportConnection then
		buildViewportConnection:Disconnect()
		buildViewportConnection = nil
	end
	local camera = workspace.CurrentCamera
	if camera then
		buildViewportConnection = camera:GetPropertyChangedSignal("ViewportSize"):Connect(function()
			ApplyResponsiveBuildLayout()
		end)
	end
end

local BUILD_TAB_THEME = {
	ActiveBg = Color3.fromRGB(17, 50, 90), ActiveText = Color3.fromRGB(100, 190, 255), ActiveStroke = Color3.fromRGB(75, 130, 230),
	InactiveBg = Color3.fromRGB(17, 19, 24), InactiveText = Color3.fromRGB(240, 240, 245), InactiveStroke = Color3.fromRGB(49, 56, 70),
}

local ghostUprightCorrection = CFrame.new()
local SelectCategory, GenerateButtons, SetupUI, CleanupGhosts
local UpdateInfoPanel, HideInfoPanel
local RefreshButtonResearchLocks, requestResearchSnapshot, requestDecorMilestoneSnapshot, UpdateDecorMilestoneHeader, getItemLockState
local CreateMobileControls, UpdateMobileButtons, CancelPlacement
local EnableFreecam, DisableFreecam, GetControls

local AssetCache = {}
local AssetIdCache = {}

local function CleanName(n) return n:lower():gsub("^%s+", ""):gsub("%s+$", "") end

local function applyCategoryTabVisual(button, isActive)
	button.BackgroundColor3 = isActive and BUILD_TAB_THEME.ActiveBg or BUILD_TAB_THEME.InactiveBg
	button.TextColor3 = isActive and BUILD_TAB_THEME.ActiveText or BUILD_TAB_THEME.InactiveText
	local stroke = button:FindFirstChildOfClass("UIStroke")
	if stroke then stroke.Color = isActive and BUILD_TAB_THEME.ActiveStroke or BUILD_TAB_THEME.InactiveStroke end
end

local function connectGuiButton(button, callback)
	-- Support CanvasGroup cards: prefer the full-surface Button child when present.
	if button and button:IsA("CanvasGroup") then
		local innerBtn = button:FindFirstChild("Button")
		if innerBtn and innerBtn:IsA("GuiButton") then
			button = innerBtn
		end
	end
	if not button or not button:IsA("GuiButton") then return nil end

	button.Active = true
	button.Selectable = true
	button.AutoButtonColor = true

	local lastPress = 0
	local function fireOnce()
		local now = os.clock()
		if (now - lastPress) < 0.12 then return end
		lastPress = now
		do
			local focused = UserInputService:GetFocusedTextBox()
			if focused then
				pcall(function()
					focused:ReleaseFocus()
				end)
			end
		end
		callback()
	end

	local connections = { button.Activated:Connect(fireOnce) }
	if button:IsA("TextButton") or button:IsA("ImageButton") then
		table.insert(connections, button.MouseButton1Click:Connect(fireOnce))
		table.insert(connections, button.TouchTap:Connect(fireOnce))
	end
	return connections
end

local function isTouchConsumedByPlacementUi(screenPos)
	if typeof(screenPos) ~= "Vector2" then
		return false
	end
	for _, obj in ipairs(PlayerGui:GetGuiObjectsAtPosition(screenPos.X, screenPos.Y)) do
		if obj.Visible and (
			obj:IsDescendantOf(BuildFrame)
			or (PlacementHelperUI and obj:IsDescendantOf(PlacementHelperUI))
			or obj:IsA("GuiButton")
			or obj.Active
		) then
			return true
		end
	end
	return false
end

local function IsMobilePlacementMode()
	if not UserInputService.TouchEnabled then return false end
	if not UserInputService.MouseEnabled then return true end
	if not UserInputService.KeyboardEnabled then return true end
	return hybridTouchPlacementActive
end

local function setPlacementInputMode(isTouch)
	if not UserInputService.TouchEnabled or not UserInputService.MouseEnabled or not UserInputService.KeyboardEnabled then
		return
	end
	local nextValue = isTouch == true
	if hybridTouchPlacementActive == nextValue then
		return
	end
	hybridTouchPlacementActive = nextValue
	mobileWorldHit = nil
	if isPlacing and CreateMobileControls then
		CreateMobileControls(true)
	end
end

local function EnsurePlacementReticle()
	if placementReticle and placementReticle.Parent then return placementReticle end
	local reticle = Instance.new("TextLabel")
	reticle.Name = "PlacementReticle"
	reticle.AnchorPoint = Vector2.new(0.5, 0.5)
	reticle.Size = UDim2.fromOffset(42, 42)
	reticle.Position = UDim2.fromScale(0.5, 0.5)
	reticle.BackgroundTransparency = 1
	reticle.Text = "+"
	reticle.TextColor3 = Color3.fromRGB(82, 255, 139)
	reticle.TextStrokeTransparency = 0.45
	reticle.Font = Enum.Font.GothamBlack
	reticle.TextScaled = true
	reticle.ZIndex = 30
	reticle.Visible = false
	reticle.Parent = CostGui
	placementReticle = reticle
	return reticle
end

local function EnsureMobileHintLabel()
	if mobileHintLabel and mobileHintLabel.Parent then return mobileHintLabel end
	if not MobileControlsGui then return nil end
	local panel = MobileControlsGui:FindFirstChild("MainPanel") or MobileControlsGui
	local hint = Instance.new("TextLabel")
	hint.Name = "MobileHintLabel"
	hint.AnchorPoint = Vector2.new(0.5, 1)
	hint.Size = UDim2.new(1, -32, 0, 22)
	hint.Position = UDim2.new(0.5, 0, 0, -8)
	hint.BackgroundTransparency = 1
	hint.Text = "Aim with camera and tap PLACE"
	hint.TextColor3 = Color3.fromRGB(220, 220, 225)
	hint.Font = Enum.Font.GothamMedium
	hint.TextSize = 12
	hint.TextXAlignment = Enum.TextXAlignment.Center
	hint.Visible = false
	hint.Parent = panel
	mobileHintLabel = hint
	return hint
end

task.spawn(function()
	local lastViewport = Vector2.zero
	while task.wait(0.3) do
		local camera = workspace.CurrentCamera
		local viewport = camera and camera.ViewportSize or Vector2.zero
		if viewport ~= lastViewport then
			lastViewport = viewport
			ApplyMobilePlacementControlLayout()
		elseif MobileControlsGui and MobileControlsGui.Visible then
			ApplyMobilePlacementControlLayout()
		end
	end
end)

local function RefreshGhostPartCache()
	table.clear(placementGhostParts)
	lastGhostColorKey = nil
	if not currentGhost then return end
	for _, part in ipairs(currentGhost:GetDescendants()) do
		if part:IsA("BasePart") then
			part.CanCollide = false
			part.CanTouch = false
			part.CanQuery = false
			table.insert(placementGhostParts, part)
		end
	end
end

local function SetGhostPartsColor(color)
	local key = string.format("%d_%d_%d", math.floor(color.R * 255 + 0.5), math.floor(color.G * 255 + 0.5), math.floor(color.B * 255 + 0.5))
	if key == lastGhostColorKey then return end
	lastGhostColorKey = key
	for _, part in ipairs(placementGhostParts) do
		if part and part.Parent then
			part.Color = color
		end
	end
end

local function UpdatePlacementFeedback(currentCost, screenPos, isTwoPointOrCarpet)
	if IsMobilePlacementMode() then
		if MobileControlsGui and MobileCostLbl then
			local statusText = isValidPlacement and "READY" or ((placementWarning ~= "" and placementWarning) or "BLOCKED")
			MobileCostLbl.Text = string.format("$%d  •  %s", currentCost, statusText)
			MobileCostLbl.TextColor3 = isValidPlacement and Color3.fromRGB(120, 255, 140) or Color3.fromRGB(255, 135, 135)
		end
		local hint = EnsureMobileHintLabel()
		if hint then
			if isTwoPointOrCarpet then
				hint.Text = placementStep == 1 and "Aim with camera and tap SET START" or "Aim with camera and tap SET END"
			else
				hint.Text = "Aim with camera and tap PLACE"
			end
			hint.TextColor3 = isValidPlacement and Color3.fromRGB(230, 230, 235) or Color3.fromRGB(255, 170, 170)
			hint.Visible = true
		end
		return
	end

	CostGui.Enabled = true
	if TooltipGui then TooltipGui.Visible = true end
	if CostLabel then
		CostLabel.Visible = true
		CostLabel.Text = "$" .. currentCost
	end

	if isValidPlacement then
		if CostLabel then CostLabel.TextColor3 = Color3.new(0.5, 1, 0.5) end
		if WarningLabel then WarningLabel.Visible = false end
	else
		if CostLabel then CostLabel.TextColor3 = Color3.new(1, 0.5, 0.5) end
		if WarningLabel then
			WarningLabel.Visible = true
			WarningLabel.Text = placementWarning
		end
	end

	if HintLabel then
		HintLabel.Visible = true
		local placeActionText = "Click — Place"
		if isTwoPointOrCarpet then
			placeActionText = placementStep == 1 and "Click — Set Start" or "Click — Set End"
		end
		HintLabel.Text = string.format("Z — Cancel  |  R — Rotate  |  T — Counter-Rotate  |  U/J — Height (%s studs)  |  %s", FormatPlacementHeightOffset(), placeActionText)
	end

	local viewport = workspace.CurrentCamera.ViewportSize
	local posX = screenPos.X + 20
	local posY = screenPos.Y - 20

	if CostLabel and WarningLabel then
		if posX + 150 > viewport.X then
			posX = screenPos.X - 10
			CostLabel.AnchorPoint = Vector2.new(1, 1)
			WarningLabel.AnchorPoint = Vector2.new(1, 1)
			WarningLabel.TextXAlignment = Enum.TextXAlignment.Right
			CostLabel.TextXAlignment = Enum.TextXAlignment.Right
		else
			CostLabel.AnchorPoint = Vector2.new(0, 1)
			WarningLabel.AnchorPoint = Vector2.new(0, 1)
			WarningLabel.TextXAlignment = Enum.TextXAlignment.Left
			CostLabel.TextXAlignment = Enum.TextXAlignment.Left
		end

		if posY - 50 < 0 then
			posY = screenPos.Y + 20
			CostLabel.AnchorPoint = Vector2.new(CostLabel.AnchorPoint.X, 0)
			WarningLabel.AnchorPoint = Vector2.new(WarningLabel.AnchorPoint.X, 0)
		end

		CostLabel.Position = UDim2.new(0, posX, 0, posY)
		if CostLabel.AnchorPoint.Y == 1 then
			WarningLabel.Position = UDim2.new(0, posX, 0, posY - 25)
		else
			WarningLabel.Position = UDim2.new(0, posX, 0, posY + 25)
		end
	end
end

local function GetS1Pos(model)
	if not model then return nil end
	for _, d in ipairs(model:GetDescendants()) do
		if (d:IsA("Attachment") or d:IsA("BasePart")) and CleanName(d.Name):sub(-2) == "s1" then return d:IsA("Attachment") and d.WorldPosition or d.Position end
	end
	return model:GetPivot().Position
end

local function GetPlayerMoney()
	local leaderstats = Player:FindFirstChild("leaderstats")
	if leaderstats then
		local money = leaderstats:FindFirstChild("Money") or leaderstats:FindFirstChild("Cash")
		if money then return money.Value end
	end
	return math.huge
end

local function ResolvePlacementBasePart(model)
	if not model then return nil end
	if model:IsA("BasePart") then return model end
	local baseObj = model:FindFirstChild("Base", true)
	if baseObj then
		if baseObj:IsA("BasePart") then return baseObj end
		if baseObj:IsA("Model") and baseObj.PrimaryPart then return baseObj.PrimaryPart end
		local nestedBase = baseObj:FindFirstChild("Base", true)
		if nestedBase and nestedBase:IsA("BasePart") then return nestedBase end
	end
	if model:IsA("Model") and model.PrimaryPart then return model.PrimaryPart end
	return model:FindFirstChildWhichIsA("BasePart", true)
end

local GetSnappedNetPlacementCF  -- forward declaration for use in BuildSpecialPlacementCF

local function IsNetItem(name)
	return CleanName(name or "") == NET_ITEM_KEY
end

local function ProjectOntoPlane(direction, normal)
	local up = normal.Magnitude > 0.001 and normal.Unit or Vector3.yAxis
	local projected = direction - up * direction:Dot(up)
	if projected.Magnitude > 0.001 then
		return projected.Unit
	end
	return nil
end

local function GetFallbackPlanarDirection(normal)
	return ProjectOntoPlane(Vector3.new(0, 0, -1), normal)
		or ProjectOntoPlane(Vector3.new(1, 0, 0), normal)
		or Vector3.new(0, 0, -1)
end

local function BuildTerrainAlignedPlacementCF(position, surfaceNormal, yawDegrees)
	local up = surfaceNormal.Magnitude > 0.001 and surfaceNormal.Unit or Vector3.yAxis
	local yawForward = CFrame.Angles(0, math.rad(yawDegrees), 0).LookVector
	local forward = ProjectOntoPlane(yawForward, up) or GetFallbackPlanarDirection(up)
	return CFrame.lookAt(position, position + forward, up) * ghostUprightCorrection
end

local function BuildDownhillAlignedPlacementCF(position, surfaceNormal, yawDegrees, uprightOnly)
	local up = uprightOnly and Vector3.yAxis or (surfaceNormal.Magnitude > 0.001 and surfaceNormal.Unit or Vector3.yAxis)
	local downhill = ProjectOntoPlane(Vector3.new(0, -1, 0), surfaceNormal.Magnitude > 0.001 and surfaceNormal.Unit or Vector3.yAxis)
	local baseForward = downhill or GetFallbackPlanarDirection(surfaceNormal.Magnitude > 0.001 and surfaceNormal.Unit or Vector3.yAxis)
	if uprightOnly then
		baseForward = Vector3.new(baseForward.X, 0, baseForward.Z)
		if baseForward.Magnitude > 0.001 then
			baseForward = baseForward.Unit
		else
			baseForward = CFrame.Angles(0, math.rad(yawDegrees), 0).LookVector
		end
	end
	local yawRotation = uprightOnly and CFrame.Angles(0, math.rad(yawDegrees), 0) or CFrame.fromAxisAngle(up, math.rad(yawDegrees))
	local rotatedForward = yawRotation:VectorToWorldSpace(baseForward)
	local forward = uprightOnly and Vector3.new(rotatedForward.X, 0, rotatedForward.Z) or (ProjectOntoPlane(rotatedForward, up) or baseForward)
	if forward.Magnitude <= 0.001 then
		forward = baseForward
	else
		forward = forward.Unit
	end
	return CFrame.lookAt(position, position + forward, up) * ghostUprightCorrection
end

local function BuildSpecialPlacementCF(itemName, itemData, position, surfaceNormal, yawDegrees)
	local adjustedYaw = (tonumber(yawDegrees) or 0) + (tonumber(itemData and itemData.PlacementYawOffset) or 0)
	if itemData and itemData.PlacementMode == "SlopeDownhill" then
		return BuildDownhillAlignedPlacementCF(position, surfaceNormal, adjustedYaw, itemData.UprightOnSlope == true)
	end
	if IsNetItem(itemName) then
		return GetSnappedNetPlacementCF(position, surfaceNormal)
	end
	return CFrame.new(position) * CFrame.Angles(0, math.rad(adjustedYaw), 0) * ghostUprightCorrection
end

local function GetNetAxisAndHalfLength(model, pivotCF)
	local cf = pivotCF or (model and model:GetPivot()) or CFrame.new()
	local basePart = ResolvePlacementBasePart(model)
	if not basePart then
		return cf.RightVector, 7.5
	end

	local useX = basePart.Size.X >= basePart.Size.Z
	local axis = useX and cf.RightVector or -cf.LookVector
	local halfLength = math.max(useX and basePart.Size.X or basePart.Size.Z, 1) * 0.5
	return axis.Unit, halfLength
end

local function GetNetEndpoints(model, pivotCF)
	local cf = pivotCF or model:GetPivot()
	local axis, halfLength = GetNetAxisAndHalfLength(model, cf)
	local center = cf.Position
	return center - axis * halfLength, center + axis * halfLength, axis, halfLength
end

GetSnappedNetPlacementCF = function(hitPos, surfaceNormal)
	local baseCF = BuildTerrainAlignedPlacementCF(hitPos, surfaceNormal, currentRotation)
	if not currentGhost then
		return baseCF
	end

	local placedObjects = workspace:FindFirstChild("PlacedObjects")
	if not placedObjects then
		return baseCF
	end

	local up = surfaceNormal.Magnitude > 0.001 and surfaceNormal.Unit or Vector3.yAxis
	local previewStart, previewEnd, _, halfLength = GetNetEndpoints(currentGhost, baseCF)
	local previewEndpoints = {
		{ Position = previewStart, Sign = -1 },
		{ Position = previewEnd, Sign = 1 },
	}

	local bestCF = baseCF
	local bestDistance = NET_SNAP_THRESHOLD

	for _, inst in ipairs(placedObjects:GetChildren()) do
		if inst:IsA("Model") and inst ~= currentGhost and CleanName(inst.Name) == NET_ITEM_KEY then
			local netStart, netEnd, netAxis = GetNetEndpoints(inst)
			local snapAxis = ProjectOntoPlane(netAxis, up) or ProjectOntoPlane(-netAxis, up) or GetFallbackPlanarDirection(up)
			for _, previewInfo in ipairs(previewEndpoints) do
				for _, targetEndpoint in ipairs({ netStart, netEnd }) do
					local initialDistance = (previewInfo.Position - targetEndpoint).Magnitude
					if initialDistance <= bestDistance then
						for _, axisDir in ipairs({ snapAxis, -snapAxis }) do
							local center = previewInfo.Sign < 0 and (targetEndpoint + axisDir * halfLength) or (targetEndpoint - axisDir * halfLength)
							local candidateCF = CFrame.lookAt(center, center + axisDir, up) * ghostUprightCorrection
							local snappedStart, snappedEnd = GetNetEndpoints(currentGhost, candidateCF)
							local snappedEndpoint = previewInfo.Sign < 0 and snappedStart or snappedEnd
							local snappedDistance = (snappedEndpoint - targetEndpoint).Magnitude
							if snappedDistance < bestDistance then
								bestDistance = snappedDistance
								bestCF = candidateCF
							end
						end
					end
				end
			end
		end
	end

	return bestCF
end

GetControls = function()
	if Controls then return Controls end
	local playerScripts = Player:FindFirstChild("PlayerScripts")
	if playerScripts then
		local pm = playerScripts:FindFirstChild("PlayerModule")
		if pm then Controls = require(pm):GetControls() end
	end
	return Controls
end

local function syncPlacementFreecamCameraState()
	local camera = workspace.CurrentCamera
	if not camera then
		return
	end
	local pitch, yaw = camera.CFrame:ToOrientation()
	freecamCameraYaw = yaw
	freecamCameraPitch = math.clamp(pitch, -math.rad(80), math.rad(80))
end

local function updatePlacementFreecamCamera()
	local camera = workspace.CurrentCamera
	if not camera or not FreecamPart then
		return
	end
	camera.CameraType = Enum.CameraType.Scriptable
	camera.CFrame = CFrame.new(FreecamPart.Position) * CFrame.fromOrientation(freecamCameraPitch, freecamCameraYaw, 0)
end

local function releasePlacementFreecamCamera()
	local camera = workspace.CurrentCamera
	if camera then
		camera.CameraType = Enum.CameraType.Custom
	end
	freecamRotateActive = false
	UserInputService.MouseBehavior = Enum.MouseBehavior.Default
	UserInputService.MouseIconEnabled = true
end

local function RestoreCharacterAfterFreecam(rootPart)
	if not rootPart then return end

	local restoreCFrame = freecamReturnCFrame or rootPart.CFrame
	local _, yaw, _ = restoreCFrame:ToOrientation()
	local rayParams = RaycastParams.new()
	rayParams.FilterType = Enum.RaycastFilterType.Exclude
	rayParams.FilterDescendantsInstances = {Player.Character, FreecamPart}
	rayParams.IgnoreWater = true

	local rayOrigin = restoreCFrame.Position + Vector3.new(0, 24, 0)
	local rayResult = workspace:Raycast(rayOrigin, Vector3.new(0, -256, 0), rayParams)
	local targetPos = rayResult and (rayResult.Position + Vector3.new(0, 4, 0)) or (restoreCFrame.Position + Vector3.new(0, 4, 0))

	rootPart.AssemblyLinearVelocity = Vector3.zero
	rootPart.AssemblyAngularVelocity = Vector3.zero
	rootPart.CFrame = CFrame.new(targetPos) * CFrame.Angles(0, yaw, 0)
end

EnableFreecam = function()
	if FreecamPart then return end
	FreecamPart = Instance.new("Part")
	FreecamPart.Name = "PlacementFreecamRoot"
	FreecamPart.Transparency = 1
	FreecamPart.CanCollide = false
	FreecamPart.Anchored = true
	FreecamPart.Size = Vector3.new(1, 1, 1)

	local currentCamera = workspace.CurrentCamera
	local targetPos = Player.Character and Player.Character:GetPivot().Position or (currentCamera and currentCamera.CFrame.Position) or Vector3.zero
	FreecamPart.Position = targetPos + Vector3.new(0, 15, 0)
	FreecamPart.Parent = workspace
	syncPlacementFreecamCameraState()
	updatePlacementFreecamCamera()

	local rootPart = Player.Character and Player.Character:FindFirstChild("HumanoidRootPart")
	if rootPart then
		freecamReturnCharacter = Player.Character
		freecamReturnCFrame = rootPart.CFrame
		rootPart.AssemblyLinearVelocity = Vector3.zero
		rootPart.AssemblyAngularVelocity = Vector3.zero
		rootPart.Anchored = true
	else
		freecamReturnCharacter = nil
		freecamReturnCFrame = nil
	end
	UserInputService.MouseBehavior = Enum.MouseBehavior.Default
	UserInputService.MouseIconEnabled = true
end

DisableFreecam = function()
	if not FreecamPart then
		releasePlacementFreecamCamera()
		return
	end
	local character = Player.Character
	local rootPart = character and character:FindFirstChild("HumanoidRootPart")
	if rootPart then
		if freecamReturnCharacter == character and freecamReturnCFrame then
			RestoreCharacterAfterFreecam(rootPart)
		end
		rootPart.Anchored = false
	end

	local humanoid = character and character:FindFirstChild("Humanoid")
	if humanoid then
		workspace.CurrentCamera.CameraSubject = humanoid
		if humanoid:GetState() == Enum.HumanoidStateType.Freefall then
			humanoid:ChangeState(Enum.HumanoidStateType.GettingUp)
		end
	elseif rootPart then
		workspace.CurrentCamera.CameraSubject = rootPart
	end
	freecamReturnCharacter = nil
	freecamReturnCFrame = nil
	FreecamPart:Destroy()
	FreecamPart = nil
	releasePlacementFreecamCamera()
end

CleanupGhosts = function()
	if currentGhost then currentGhost:Destroy() currentGhost = nil end
	if startGhost then startGhost:Destroy() startGhost = nil end
	table.clear(placementGhostParts)
	lastGhostColorKey = nil
	lastObstructionCheckPos = nil
	lastObstructionCheckStep = 0
	lastObstructionCheckAt = 0
	lastObstructed = false
	lastComputedCost = 0
	CostGui.Enabled = false
	if TooltipGui then TooltipGui.Visible = false end
	if CostLabel then CostLabel.Visible = false end
	if WarningLabel then WarningLabel.Visible = false end
	if HintLabel then HintLabel.Visible = false end
	if placementReticle then placementReticle.Visible = false end
	if mobileHintLabel then mobileHintLabel.Visible = false end
end

CancelPlacement = function(reopenMenu)
	isPlacing = false
	setGhostUpdateEnabled(false)
	isProcessingPlacement = false
	isValidPlacement = true
	placementWarning = ""
	lastLoggedValidity = true
	placementStep = 1
	liftStartCFrame = nil
	currentRotation = 0
	currentHeightOffset = 0
	currentItemName = nil
	hybridTouchPlacementActive = false
	mobileWorldHit = nil
	ContextActionService:UnbindAction(PLACEMENT_CANCEL_ACTION)
	unbindPlacementRotateActions()
	ModeState.Value = ""
	CleanupGhosts()
	DisableFreecam()
	CreateMobileControls(false)
	if reopenMenu ~= false then ToggleMenu(true) end
end

local function CreateMetalFenceClientTemplate()
	local model = Instance.new("Model")
	model.Name = "Metal Fence"
	local fenceColor = Color3.fromRGB(158, 158, 162)
	local postH = 3.5
	local postW = 0.4
	local span = 8
	local railH = 0.2
	local railD = 0.14
	local half = span * 0.5
	local function addPost(sign)
		local p = Instance.new("Part")
		p.Name = (sign < 0) and "Post_L" or "Post_R"
		p.Anchored = true
		p.CanCollide = true
		p.Material = Enum.Material.Metal
		p.Color = fenceColor
		p.Size = Vector3.new(postW, postH, postW)
		p.CFrame = CFrame.new(sign * half, postH * 0.5, 0)
		p.Parent = model
	end
	addPost(-1)
	addPost(1)
	local rail = Instance.new("Part")
	rail.Name = "Rail"
	rail.Anchored = true
	rail.CanCollide = true
	rail.Material = Enum.Material.Metal
	rail.Color = fenceColor
	rail.Size = Vector3.new(span - postW, railH, railD)
	rail.CFrame = CFrame.new(0, postH - 0.35, 0)
	rail.Parent = model
	model.PrimaryPart = rail
	return model
end

local function CreateNetClientTemplate()
	local model = Instance.new("Model")
	model.Name = "Net"
	local base = Instance.new("Part")
	base.Name = "Base"
	base.Anchored = true
	base.CanCollide = true
	base.Material = Enum.Material.SmoothPlastic
	base.Color = Color3.fromRGB(255, 130, 55)
	base.Size = Vector3.new(16, 0.4, 0.3)
	base.CFrame = CFrame.new()
	base.Parent = model
	model.PrimaryPart = base
	return model
end

CreateGhost = function(name)
	if currentGhost then currentGhost:Destroy() currentGhost = nil end
	local itemConfig = Config.Items[name]
	if not itemConfig then return end

	local function finalizeGhost(newGhost)
		if not newGhost then
			return false
		end

		ghostUprightCorrection = CFrame.new()
		local basePartCount = 0
		for _, p in ipairs(newGhost:GetDescendants()) do
			if p:IsA("BasePart") then
				basePartCount += 1
				p.Transparency = 0.25
				p.CanCollide = false
				p.CanTouch = false
				p.CanQuery = false
				p.Color = Color3.new(0, 1, 0)
				p.Material = Enum.Material.ForceField
			elseif p:IsA("Script") or p:IsA("LocalScript") then
				p:Destroy()
			end
		end

		if basePartCount == 0 then
			warn(string.format("[PlacementClient] Placement asset for '%s' has no BaseParts; refusing to spawn an invisible ghost.", tostring(name)))
			newGhost:Destroy()
			return false
		end

		currentGhost = newGhost
		if not (itemConfig.Type == "TwoPoint" or itemConfig.Type == "Carpet") then
			local basePart = ResolvePlacementBasePart(newGhost)
			if basePart and basePart:IsA("BasePart") then
				local pivotCF = newGhost:GetPivot()
				local baseCF = basePart.CFrame
				local relRot = pivotCF.Rotation:Inverse() * baseCF.Rotation
				local currentUp = relRot.UpVector
				local targetUp = Vector3.yAxis
				local dotVal = currentUp:Dot(targetUp)
				if dotVal < 0.99 then
					local axis = currentUp:Cross(targetUp)
					if axis.Magnitude > 0.001 then
						local angle = math.acos(math.clamp(dotVal, -1, 1))
						ghostUprightCorrection = CFrame.fromAxisAngle(axis.Unit, angle)
					end
				end
			end
		end

		newGhost:SetAttribute("IsPlacementGhost", true)
		newGhost.Parent = workspace
		local ghostHighlight = Instance.new("Highlight")
		ghostHighlight.Name = "PlacementGhostHighlight"
		ghostHighlight.Adornee = newGhost
		ghostHighlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
		ghostHighlight.FillTransparency = 1
		ghostHighlight.OutlineTransparency = 0.08
		ghostHighlight.OutlineColor = Color3.fromRGB(92, 255, 152)
		ghostHighlight.Parent = newGhost
		RefreshGhostPartCache()
		return true
	end

	if itemConfig.Type == CustomBuildingConfig.TYPE_NAME then
		finalizeGhost(CustomBuildingConfig.CreateModel(name))
		return
	end

	local mainAsset = AssetCache[name]
	if not mainAsset and itemConfig.ID then
		mainAsset = AssetIdCache[tostring(itemConfig.ID)]
	end
	if not mainAsset then
		for _, v in ipairs(Assets:GetDescendants()) do
			if v.Name == name then mainAsset = v break end
		end
	end
	if not mainAsset and name == "Metal Fence" then
		mainAsset = CreateMetalFenceClientTemplate()
	end
	if not mainAsset and name == "Net" then
		mainAsset = CreateNetClientTemplate()
	end
	if mainAsset then AssetCache[name] = mainAsset end
	if not mainAsset then
		warn(string.format("[PlacementClient] Missing placement asset for '%s'.", tostring(name)))
		return
	end

	local objectToClone = mainAsset
	if itemConfig.Type == "TwoPoint" or itemConfig.Type == "Carpet" then
		if placementStep == 1 then objectToClone = mainAsset:FindFirstChild("StartStation")
		else objectToClone = mainAsset:FindFirstChild("EndStation") end
	elseif mainAsset:IsA("Folder") then
		objectToClone = mainAsset:FindFirstChildOfClass("Model") or mainAsset:FindFirstChildWhichIsA("BasePart")
	end

	if not objectToClone then
		warn(string.format("[PlacementClient] No cloneable placement object found for '%s'.", tostring(name)))
		return
	end

	if objectToClone:IsA("Model") then
		finalizeGhost(objectToClone:Clone())
		return
	end

	if objectToClone:IsA("BasePart") then
		local wrapper = Instance.new("Model")
		wrapper.Name = tostring(objectToClone.Name)
		local clonedPart = objectToClone:Clone()
		clonedPart.Parent = wrapper
		wrapper.PrimaryPart = clonedPart
		finalizeGhost(wrapper)
		return
	end

	warn(string.format("[PlacementClient] Unsupported placement asset type '%s' for '%s'.", objectToClone.ClassName, tostring(name)))
end

function normalizeBuildSearchQuery(value)
	local text = string.lower(tostring(value or ""))
	text = text:gsub("^%s+", ""):gsub("%s+$", "")
	text = text:gsub("%s+", " ")
	return text
end

function itemMatchesBuildSearch(itemName, itemData)
	if buildSearchText == "" then
		return true
	end
	local haystack = string.lower(table.concat({
		tostring(itemName or ""),
		tostring(itemData and itemData.Type or ""),
		tostring(itemData and itemData.Category or ""),
		tostring(itemData and itemData.Description or ""),
	}, " "))
	for token in string.gmatch(buildSearchText, "[^%s]+") do
		if not string.find(haystack, token, 1, true) then
			return false
		end
	end
	return true
end

function setBuildSearchOpen(isOpen)
	buildSearchOpen = isOpen == true
	if SearchPanel and SearchPanel:IsA("GuiObject") then
		SearchPanel.Visible = buildSearchOpen
	end
	if SearchButton and SearchButton:IsA("GuiButton") then
		SearchButton.BackgroundColor3 = buildSearchOpen and Color3.fromRGB(73, 108, 152) or Color3.fromRGB(55, 65, 82)
	end
	if not buildSearchOpen and SearchBox and SearchBox:IsA("TextBox") then
		SearchBox:ReleaseFocus()
	end
end

function setBuildSearchQuery(text)
	local normalized = normalizeBuildSearchQuery(text)
	if normalized == buildSearchText then
		return
	end
	buildSearchText = normalized
	SelectCategory(currentCategory)
end

SelectCategory = function(catName)
	currentCategory = catName
	if InfoPanel then HideInfoPanel() end
	for _, t in ipairs(CategoryTabs:GetChildren()) do
		if t:IsA("GuiButton") then applyCategoryTabVisual(t, t.Name == catName) end
	end
	for _, btn in ipairs(ContentFrame:GetChildren()) do
		if btn:IsA("GuiButton") or btn:IsA("CanvasGroup") then
			if btn.Name ~= "Delete" and btn.Name ~= "Remove" then
				local ok, err = pcall(function()
					local data = Config.Items[btn.Name]
					local shouldShow = false
					if data and data.ShowInMenu ~= false and data.Category == catName then
						if data.AllowedUsers ~= nil then
							for _, u in ipairs(data.AllowedUsers) do
								if u == Player.Name then shouldShow = true; break end
							end
						else
							shouldShow = true
						end
					end
					if shouldShow and not itemMatchesBuildSearch(btn.Name, data) then
						shouldShow = false
					end
					btn.Visible = shouldShow
					if shouldShow then
						if not btn:FindFirstChild("Preview") then
							task.defer(function()
								if btn.Parent and btn.Visible and currentCategory == catName then
									CreateViewport(btn, btn.Name)
								end
							end)
						end
					else
						activeSpinners[btn] = nil
						local preview = btn:FindFirstChild("Preview")
						if preview then
							preview:Destroy()
						end
					end
				end)
				if not ok then
					btn.Visible = false
					warn(string.format("[PlacementClient] Failed to switch category for '%s': %s", tostring(btn.Name), tostring(err)))
				end
			end
		end
	end
	if UpdateDecorMilestoneHeader then
		UpdateDecorMilestoneHeader()
	end
end

local ClosePanels = Events:FindFirstChild("ClosePanels")
if not ClosePanels then
	ClosePanels = Instance.new("BindableEvent")
	ClosePanels.Name = "ClosePanels"
	ClosePanels.Parent = Events
end

local function playBuildMenuTween(targetPos)
	if buildMenuTween then
		buildMenuTween:Cancel()
		buildMenuTween = nil
	end
	buildMenuTween = TweenService:Create(BuildFrame, TWEEN_INFO, {Position = targetPos})
	buildMenuTween:Play()
end

ClosePanels.Event:Connect(function(source)
	if source == "Build" then return end
	if isPlacing then CancelPlacement(false) end
	if isMenuOpen then
		buildMenuTweenToken += 1
		local tweenToken = buildMenuTweenToken
		isMenuOpen = false
		playBuildMenuTween(POS_CLOSED)
		task.delay(0.4, function()
			if tweenToken == buildMenuTweenToken and not isMenuOpen then
				BuildFrame.Visible = false
			end
		end)
	end
end)

Player.CharacterAdded:Connect(function()
	task.defer(function()
		ContextActionService:UnbindAction(PLACEMENT_CANCEL_ACTION)
		if isPlacing then
			CancelPlacement(false)
		else
			ModeState.Value = ""
			DisableFreecam()
			CleanupGhosts()
			CreateMobileControls(false)
			isMenuOpen = false
			buildMenuTweenToken += 1
			if buildMenuTween then
				buildMenuTween:Cancel()
				buildMenuTween = nil
			end
			BuildFrame.Visible = false
			BuildFrame.Position = POS_CLOSED
			if InfoPanel then HideInfoPanel() end
		end
	end)
end)

ToggleMenu = function(forceState)
	local nextState = forceState
	if nextState == nil then
		nextState = not isMenuOpen
	end
	if nextState and ModeState.Value == "Removing" and not isPlacing then
		ClosePanels:Fire("Build")
		if ModeState.Value == "Removing" then
			warn("[PlacementClient] Clearing stale Removing mode while opening build menu.")
			ModeState.Value = ""
		end
	end
	do
		local focused = UserInputService:GetFocusedTextBox()
		if focused then
			pcall(function()
				focused:ReleaseFocus()
			end)
		end
	end
	if nextState == isMenuOpen and ((nextState and BuildFrame.Visible) or (not nextState and not BuildFrame.Visible)) then
		return
	end

	buildMenuTweenToken += 1
	local tweenToken = buildMenuTweenToken
	isMenuOpen = nextState
	ApplyResponsiveBuildLayout()
	local targetPos = isMenuOpen and POS_OPEN or POS_CLOSED

	if isMenuOpen then
		ClosePanels:Fire("Build")
		SelectCategory("Buildings")
		BuildFrame.Visible = true
		if InfoPanel then HideInfoPanel() end
		UpdateDecorMilestoneHeader()
		-- Run server snapshot calls async so menu opens instantly without blocking
		task.spawn(function()
			requestResearchSnapshot()
			requestDecorMilestoneSnapshot()
			RefreshButtonResearchLocks()
			UpdateDecorMilestoneHeader()
		end)
	end

	playBuildMenuTween(targetPos)
	if not isMenuOpen then
		task.delay(0.4, function()
			if tweenToken == buildMenuTweenToken and not isMenuOpen then
				BuildFrame.Visible = false
			end
		end)
	end
end

ActivatePlacement = function(name)
	if ModeState.Value == "Removing" then
		ClosePanels:Fire("Build")
		if ModeState.Value == "Removing" then
			warn("[PlacementClient] Clearing stale Removing mode before placement.")
			ModeState.Value = ""
		end
	end
	do
		local focused = UserInputService:GetFocusedTextBox()
		if focused then
			pcall(function()
				focused:ReleaseFocus()
			end)
		end
	end
	ClosePanels:Fire("Build")
	if InfoPanel then HideInfoPanel() end
	currentItemName = name
	isPlacing = true
	setGhostUpdateEnabled(true)
	placementStep = 1
	liftStartCFrame = nil
	currentRotation = 0
	currentHeightOffset = 0
	isProcessingPlacement = false
	ModeState.Value = "Placing"
	isValidPlacement = true
	placementWarning = ""
	lastLoggedValidity = true

	local itemData = Config.Items[name]
	local isDecor = itemData and (itemData.Category == "Decor" or itemData.Type == "Decor" or itemData.Category == "Decore")

	if not isDecor and not IsMobilePlacementMode() then EnableFreecam() end
	CleanupGhosts()
	ToggleMenu(false)
	CreateGhost(name)
	if not currentGhost then
		warn(string.format("[PlacementClient] Failed to create placement ghost for '%s'.", tostring(name)))
		CancelPlacement(true)
		return
	end

	ContextActionService:UnbindAction(PLACEMENT_CANCEL_ACTION)
	bindPlacementRotateActions()
	ContextActionService:BindActionAtPriority(PLACEMENT_CANCEL_ACTION, function(_, inputState)
		if inputState ~= Enum.UserInputState.Begin or not isPlacing then return Enum.ContextActionResult.Pass end
		CancelPlacement(true)
		return Enum.ContextActionResult.Sink
	end, false, Enum.ContextActionPriority.High.Value, Enum.KeyCode.Z)

	CreateMobileControls(true)
end

ConfirmPlacement = function()
	if not currentGhost then return end
	if not isValidPlacement then
		-- If blocked by money, alert MoneyShopClient (which decides between ad prompt and shop).
		if placementWarning == "NOT ENOUGH MONEY" then
			local ClientNotification = ReplicatedStorage:FindFirstChild("ClientNotification")
			if ClientNotification and ClientNotification:IsA("BindableEvent") then
				ClientNotification:Fire("Error", "Not Enough Money",
					string.format("Need $%d", lastComputedCost), 3,
					lastComputedCost, currentItemName)
			end
		end
		if IsMobilePlacementMode() and MobileCostLbl then
			local oldText = MobileCostLbl.Text
			local oldColor = MobileCostLbl.TextColor3
			MobileCostLbl.Text = "CANNOT PLACE"
			MobileCostLbl.TextColor3 = Color3.fromRGB(255, 80, 80)
			task.delay(1, function()
				if MobileCostLbl and MobileCostLbl.Text == "CANNOT PLACE" then
					MobileCostLbl.Text = oldText
					MobileCostLbl.TextColor3 = oldColor
				end
			end)
		end
		return 
	end
	if isProcessingPlacement then return end

	isProcessingPlacement = true

	-- Show "BUILDING..." indicator
	BuildStatusIndicator.show(PlayerGui, "BUILDING...")

	local cf = currentGhost:GetPivot()
	local data = Config.Items[currentItemName]
	if not data then
		warn("[PlacementClient] Missing placement item data during confirm. Recovering state.")
		BuildStatusIndicator.hide(PlayerGui)
		isProcessingPlacement = false
		RecoverBrokenPlacementState(true)
		return
	end

	if data.Type == "TwoPoint" or data.Type == "Carpet" then
		if placementStep == 1 then
			liftStartCFrame = cf
			placementStep = 2
			currentHeightOffset = 0
			startGhost = currentGhost
			currentGhost = nil
			CreateGhost(currentItemName)
			if not currentGhost then
				warn(string.format("[PlacementClient] Recovery triggered while setting lift start for '%s': next ghost failed to spawn.", tostring(currentItemName)))
				BuildStatusIndicator.hide(PlayerGui)
				isProcessingPlacement = false
				RecoverBrokenPlacementState(true)
				return
			end
			if UpdateMobileButtons then UpdateMobileButtons() end
			BuildStatusIndicator.hide(PlayerGui)
			isProcessingPlacement = false
		else
			local endPos = currentGhost:GetPivot().Position
			local finalStartCF = CFrame.new(liftStartCFrame.Position, endPos)
			local finalEndCF = CFrame.new(endPos, liftStartCFrame.Position)
			local success, result = pcall(function() return RequestPlaceItem:InvokeServer({ItemName=currentItemName, CFrame=finalStartCF, EndCFrame=finalEndCF}) end)
			local placementSucceeded = success and result ~= false and result ~= nil
			if placementSucceeded and type(result) == "table" and result.success == false then
				placementSucceeded = false
			end
			if placementSucceeded then
				CleanupGhosts()
				placementStep = 1
				liftStartCFrame = nil
				CreateGhost(currentItemName)
				CreateMobileControls(true)
				if not currentGhost then
					warn(string.format("[PlacementClient] Recovery triggered after placing '%s': next ghost failed to spawn.", tostring(currentItemName)))
					BuildStatusIndicator.hide(PlayerGui)
					isProcessingPlacement = false
					RecoverBrokenPlacementState(true)
					return
				end
				BuildStatusIndicator.hide(PlayerGui)
			else
				showPlacementFailure((not success and tostring(result)) or (type(result) == "table" and tostring(result.message or result.reason or result.error or "PLACE FAILED")) or "PLACE FAILED")
			end
			isProcessingPlacement = false
		end
	else
		local success, result = pcall(function()
			return RequestPlaceItem:InvokeServer({
				ItemName = currentItemName,
				CFrame = cf,
				HeightOffset = currentHeightOffset,
				YawDegrees = currentRotation,
			})
		end)
		local placementSucceeded = success and result ~= false and result ~= nil
		if placementSucceeded and type(result) == "table" and result.success == false then
			placementSucceeded = false
		end
		if placementSucceeded then
			CleanupGhosts()
			CreateGhost(currentItemName)
			CreateMobileControls(true)
			if not currentGhost then
				warn(string.format("[PlacementClient] Recovery triggered after placing '%s': next ghost failed to spawn.", tostring(currentItemName)))
				BuildStatusIndicator.hide(PlayerGui)
				isProcessingPlacement = false
				RecoverBrokenPlacementState(true)
				return
			end
			BuildStatusIndicator.hide(PlayerGui)
		else
			showPlacementFailure((not success and tostring(result)) or (type(result) == "table" and tostring(result.message or result.reason or result.error or "PLACE FAILED")) or "PLACE FAILED")
		end
		isProcessingPlacement = false
	end
end

local function UpdateMobileHit(input)
	setPlacementInputMode(true)
	mobileWorldHit = Vector2.new(input.Position.X, input.Position.Y)
end

local function GetPlacementAimScreenPosition()
	local camera = workspace.CurrentCamera
	if not camera then
		return Vector2.zero, true
	end
	if IsMobilePlacementMode() then
		if mobileWorldHit then return mobileWorldHit, true end
		local viewport = camera.ViewportSize
		return Vector2.new(viewport.X * 0.5, viewport.Y * 0.5), true
	end
	return UserInputService:GetMouseLocation(), false
end

local function BuildPlacementAimRay(camera, aimPos, isViewport)
	if isViewport then
		return camera:ViewportPointToRay(aimPos.X, aimPos.Y)
	end

	if PlayerMouse then
		local unitRay = PlayerMouse.UnitRay
		if unitRay then
			return unitRay
		end
	end

	local insetTopLeft = select(1, GuiService:GetGuiInset())
	return camera:ViewportPointToRay(aimPos.X - insetTopLeft.X, aimPos.Y - insetTopLeft.Y)
end

local SPAWN_PROTECTION_PADDING = Vector3.new(24, 12, 24)
local cachedSpawnLocations = nil

local function getSpawnLocations()
	if cachedSpawnLocations == nil then
		cachedSpawnLocations = {}
		for _, inst in ipairs(workspace:GetDescendants()) do
			if inst:IsA("SpawnLocation") then
				table.insert(cachedSpawnLocations, inst)
			end
		end
	end
	return cachedSpawnLocations
end

workspace.DescendantAdded:Connect(function(inst)
	if inst:IsA("SpawnLocation") then
		cachedSpawnLocations = nil
	end
end)

workspace.DescendantRemoving:Connect(function(inst)
	if inst:IsA("SpawnLocation") then
		cachedSpawnLocations = nil
	end
end)

local function shouldProtectSpawnPlacement(itemData)
	local itemType = tostring(itemData and itemData.Type or "")
	return itemType == "House" or itemType == "Hotel"
end

local function overlapsProtectedSpawn(model, itemData)
	if not model or not shouldProtectSpawnPlacement(itemData) then
		return false
	end

	local spawnLocations = getSpawnLocations()
	if #spawnLocations == 0 then
		return false
	end

	local overlapParams = OverlapParams.new()
	overlapParams.FilterType = Enum.RaycastFilterType.Include
	overlapParams.FilterDescendantsInstances = {model}

	for _, spawnLocation in ipairs(spawnLocations) do
		if spawnLocation and spawnLocation.Parent then
			local parts = workspace:GetPartBoundsInBox(
				spawnLocation.CFrame,
				spawnLocation.Size + SPAWN_PROTECTION_PADDING,
				overlapParams
			)
			if #parts > 0 then
				return true
			end
		end
	end

	return false
end

UpdateGhost = function(dt)
	if isPlacing and not isProcessingPlacement then
		if not currentGhost or currentGhost.Parent == nil then
			warn("[PlacementClient] Recovering from broken placement state: ghost missing during placement.")
			RecoverBrokenPlacementState(true)
			return
		end
	end

	if FreecamPart then
		local ctrl = GetControls()
		if ctrl then
			local moveVec = ctrl:GetMoveVector()
			local camCF = workspace.CurrentCamera.CFrame
			local lookDir = camCF.LookVector
			local rightDir = camCF.RightVector
			local flatLook = Vector3.new(lookDir.X, 0, lookDir.Z).Unit
			if flatLook.Magnitude == 0 then flatLook = Vector3.new(0, 0, -1) end
			local flatRight = Vector3.new(rightDir.X, 0, rightDir.Z).Unit
			local vertical = 0
			if UserInputService:IsKeyDown(Enum.KeyCode.E) then vertical = 1 end
			if UserInputService:IsKeyDown(Enum.KeyCode.Q) then vertical = -1 end
			local speed = 60
			if UserInputService:IsKeyDown(Enum.KeyCode.LeftShift) then speed = 150 end
			local moveDir = (flatLook * -moveVec.Z) + (flatRight * moveVec.X) + Vector3.new(0, vertical, 0)
			if moveDir.Magnitude > 0 then FreecamPart.Position = FreecamPart.Position + (moveDir * speed * dt) end
		end
	end

	if not currentGhost or not isPlacing then return end

	local aimPos, isViewport = GetPlacementAimScreenPosition()
	local itemData = Config.Items[currentItemName]
	if not itemData then
		warn("[PlacementClient] Missing item data while updating ghost. Recovering state.")
		RecoverBrokenPlacementState(true)
		return
	end
	local isTwoPointOrCarpet = itemData and (itemData.Type == "TwoPoint" or itemData.Type == "Carpet")
	local rotOffset = CFrame.Angles(0, math.rad(isTwoPointOrCarpet and itemData.StationRotation or 0), 0)

	if not IsMobilePlacementMode() then
		local guiObjects = PlayerGui:GetGuiObjectsAtPosition(aimPos.X, aimPos.Y)
		for _, obj in ipairs(guiObjects) do
			if obj.Visible and (obj:IsDescendantOf(BuildFrame) or (PlacementHelperUI and obj:IsDescendantOf(PlacementHelperUI)) or obj:IsA("GuiButton") or obj.Active) then
				if currentGhost and placementStep == 1 then
					local currentPivot = currentGhost:GetPivot()
					local currentPos = currentPivot.Position
					local newCF = BuildSpecialPlacementCF(currentItemName, itemData, currentPos, currentPivot.UpVector, currentRotation)
					if isTwoPointOrCarpet then currentGhost:PivotTo(newCF * rotOffset) else currentGhost:PivotTo(newCF) end
				end
				return
			end
		end
	end

	local camera = workspace.CurrentCamera
	if not camera then return end
	local ray = BuildPlacementAimRay(camera, aimPos, isViewport)

	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local ignoreList = {currentGhost, startGhost, Player.Character}
	local treeFolder = workspace:FindFirstChild("TreeFolder")
	if treeFolder then table.insert(ignoreList, treeFolder) end
	local guestFolder = workspace:FindFirstChild("Guests")
	if guestFolder then table.insert(ignoreList, guestFolder) end
	local placedObjects = workspace:FindFirstChild("PlacedObjects")
	if placedObjects and IsNetItem(currentItemName) then
		for _, child in ipairs(placedObjects:GetChildren()) do
			if child:IsA("Model") and CleanName(child.Name) == NET_ITEM_KEY then
				table.insert(ignoreList, child)
			end
		end
	end
	if FreecamPart then table.insert(ignoreList, FreecamPart) end
	params.FilterDescendantsInstances = ignoreList

	local res = workspace:Raycast(ray.Origin, ray.Direction * 8000, params)
	if not res then return end

	local hitPos = res.Position
	local hitNormal = res.Normal
	isValidPlacement = true
	placementWarning = ""

	local bottomOffset = 0
	local basePart = ResolvePlacementBasePart(currentGhost)
	if basePart and basePart:IsA("BasePart") then
		bottomOffset = currentGhost:GetPivot().Position.Y - (basePart.Position.Y - basePart.Size.Y / 2)
	else
		local bbCF, bbSize = currentGhost:GetBoundingBox()
		local pivotPos = currentGhost:GetPivot().Position
		bottomOffset = pivotPos.Y - (bbCF.Position.Y - bbSize.Y / 2)
	end
	if bottomOffset > 50 or bottomOffset < -10 then bottomOffset = 0 end
	hitPos = hitPos + Vector3.new(0, bottomOffset, 0)
	if itemData and itemData.Type == CustomBuildingConfig.TYPE_NAME then
		hitPos = CustomBuildingConfig.SnapVector3(hitPos)
	end
	if not (itemData and itemData.SurfaceTow) then
		hitPos = hitPos + Vector3.new(0, currentHeightOffset, 0)
	end

	if placementStep == 1 then
		local targetCF = BuildSpecialPlacementCF(currentItemName, itemData, hitPos, hitNormal, currentRotation)
		if isTwoPointOrCarpet then currentGhost:PivotTo(targetCF * rotOffset) else currentGhost:PivotTo(targetCF) end
	elseif placementStep == 2 and liftStartCFrame then
		local pureEndCF = CFrame.new(hitPos, liftStartCFrame.Position)
		currentGhost:PivotTo(pureEndCF * rotOffset)
		if startGhost then
			local pureStartCF = CFrame.new(liftStartCFrame.Position, hitPos)
			startGhost:PivotTo(pureStartCF * rotOffset)
		end

		local dist = (hitPos - liftStartCFrame.Position).Magnitude
		local vIn = liftStartCFrame.Position
		local vOut = hitPos
		local dH = Vector3.new(vOut.X - vIn.X, 0, vOut.Z - vIn.Z).Magnitude
		local dV = vOut.Y - vIn.Y
		local pitchAngle = math.abs(math.deg(math.atan2(dV, dH)))
		local enforceDistanceLimit = not isTwoPointOrCarpet

		if dist < 50 then
			isValidPlacement = false
			placementWarning = "TOO SHORT (MIN: 50 STUDS)"
		elseif enforceDistanceLimit and itemData.MaxDistance and dist > itemData.MaxDistance then
			isValidPlacement = false
			placementWarning = "TOO FAR (MAX: " .. itemData.MaxDistance .. " STUDS)"
		elseif itemData.MaxAngle and pitchAngle > itemData.MaxAngle then
			isValidPlacement = false
			placementWarning = "TOO STEEP (MAX: " .. itemData.MaxAngle .. "°)"
		end

		-- Carpet-specific: check terrain roughness along the path
		if isValidPlacement and itemData.Type == "Carpet" and itemData.MaxTerrainRoughness then
			local roughOk, roughMsg = CarpetTerrainUtil.checkTerrainRoughness(liftStartCFrame.Position, hitPos, itemData)
			if not roughOk then
				isValidPlacement = false
				placementWarning = roughMsg
			end
		end

		if itemData.Type == "Carpet" and startGhost then
			local gFolder = currentGhost:FindFirstChild("GhostSections")
			if not gFolder then
				gFolder = Instance.new("Folder")
				gFolder.Name = "GhostSections"
				gFolder.Parent = currentGhost
			end
			local tpl = AssetCache[currentItemName]
			if not tpl and itemData.ID then tpl = AssetIdCache[tostring(itemData.ID)] end
			if not tpl then tpl = Assets:FindFirstChild(currentItemName, true) end
			if tpl then AssetCache[currentItemName] = tpl end
			local secTpl = tpl and tpl:FindFirstChild("Section")
			if secTpl then
				local p1 = GetS1Pos(startGhost)
				local p2 = GetS1Pos(currentGhost)
				local dir = dist > 0.1 and (p2 - p1).Unit or Vector3.zAxis
				local configRot = CFrame.Angles(math.rad(itemData.ChairRotationX or 0), math.rad(itemData.ChairRotationY or 0), math.rad(itemData.ChairRotationZ or 0))
				local secBasePart = secTpl:IsA("Model") and (secTpl:FindFirstChild("Base") or secTpl.PrimaryPart or secTpl:FindFirstChildWhichIsA("BasePart")) or secTpl
				local rawSize = secBasePart:IsA("BasePart") and secBasePart.Size or Vector3.new(10, 10, 10)
				local rotatedSize = configRot * rawSize
				local secStep = math.abs(rotatedSize.Z)
				if secStep < 0.1 then secStep = math.abs(rotatedSize.X) end
				secStep = math.max(1, secStep)
				local numSections = math.max(1, math.ceil(dist / secStep))
				local terrainSamples = Config.ShouldTerrainBlend(currentItemName, itemData) and CarpetTerrainUtil.buildSamples(p1, p2, numSections + 1) or nil

				local currentChildren = gFolder:GetChildren()
				local currentCount = #currentChildren
				for i = currentCount + 1, numSections do
					local sec = secTpl:Clone()
					sec.Name = "GhostSection"
					for _, part in ipairs(sec:GetDescendants()) do
						if part:IsA("BasePart") then
							part.Transparency = 0.5
							part.CanCollide = false
							part.CanTouch = false
							part.CanQuery = false
							part.Material = Enum.Material.ForceField
						end
						if part:IsA("Script") then part:Destroy() end
					end
					if sec:IsA("BasePart") then
						sec.Transparency = 0.5
						sec.CanCollide = false
						sec.CanTouch = false
						sec.CanQuery = false
						sec.Material = Enum.Material.ForceField
					end
					sec.Parent = gFolder
				end
				for i = numSections + 1, currentCount do
					if currentChildren[i] then currentChildren[i]:Destroy() end
				end

				local updatedChildren = gFolder:GetChildren()
				for i = 1, numSections do
					local sec = updatedChildren[i]
					local sampleA = terrainSamples and terrainSamples[i] or (p1 + dir * ((i - 1) * secStep))
					local sampleB = terrainSamples and terrainSamples[i + 1] or (p1 + dir * (i * secStep))
					local pos = sampleA:Lerp(sampleB, 0.5)
					local secDir = sampleB - sampleA
					if secDir.Magnitude < 0.1 then secDir = dir end
					secDir = secDir.Unit
					local secCF = CFrame.lookAt(pos, pos + secDir) * configRot
					if sec:IsA("BasePart") then
						sec.CFrame = secCF
					elseif sec:IsA("Model") then
						local secBase = sec:FindFirstChild("Base") or sec.PrimaryPart or sec:FindFirstChildWhichIsA("BasePart")
						if secBase then
							local offset = secBase.CFrame:Inverse() * sec:GetPivot()
							sec:PivotTo(secCF * offset)
						else
							sec:PivotTo(secCF)
						end
					end
				end
			end
		end
	end

	local isDecor = itemData and (itemData.Category == "Decor" or itemData.Type == "Decor" or itemData.Category == "Decore")
	if not isDecor then
		local shouldCheckObstruction = placementStep ~= lastObstructionCheckStep
			or not lastObstructionCheckPos
			or (hitPos - lastObstructionCheckPos).Magnitude >= OBSTRUCTION_MOVE_THRESHOLD
			or (os.clock() - lastObstructionCheckAt) >= OBSTRUCTION_CHECK_INTERVAL
		if shouldCheckObstruction then
			lastObstructionCheckPos = hitPos
			lastObstructionCheckStep = placementStep
			lastObstructionCheckAt = os.clock()
			lastObstructed = false
			local obstructionParams = OverlapParams.new()
			obstructionParams.FilterType = Enum.RaycastFilterType.Include
			local placedFolder = workspace:FindFirstChild("PlacedObjects")
			if placedFolder then
				obstructionParams.FilterDescendantsInstances = {placedFolder}
				
				local checkCF, checkSize

				local basePart = ResolvePlacementBasePart(currentGhost)
				if basePart and basePart:IsA("BasePart") then
					checkCF = basePart.CFrame
					checkSize = basePart.Size
				else
					checkCF, checkSize = currentGhost:GetBoundingBox()
					if checkSize.Magnitude > 150 then -- Cap query size fallback
						checkCF = currentGhost:GetPivot()
						checkSize = Vector3.new(20, 20, 20)
					end
				end
				
				local parts = workspace:GetPartBoundsInBox(checkCF, checkSize * 0.95, obstructionParams)
				lastObstructed = #parts > 0
			end
		end
		if lastObstructed then
			isValidPlacement = false
			if placementWarning == "" then placementWarning = "OBSTRUCTED" end
		end
	else
		lastObstructed = false
	end

	if isValidPlacement and overlapsProtectedSpawn(currentGhost, itemData) then
		isValidPlacement = false
		placementWarning = "TOO CLOSE TO SPAWN"
	end

	local currentCost = 0
	if itemData then
		local placementDist = nil
		if isTwoPointOrCarpet and placementStep == 2 and liftStartCFrame then
			placementDist = (hitPos - liftStartCFrame.Position).Magnitude
		end
		currentCost = Config.GetPlacementCost(currentItemName, Player, (startGhost and (itemData.Type == "TwoPoint" or itemData.Type == "Carpet")) and placementDist or nil)
	end
	lastComputedCost = currentCost

	if GetPlayerMoney() < currentCost then
		isValidPlacement = false
		placementWarning = "NOT ENOUGH MONEY"
	end

	if isValidPlacement ~= lastLoggedValidity then lastLoggedValidity = isValidPlacement end
	SetGhostPartsColor(isValidPlacement and Color3.new(0, 1, 0) or Color3.new(1, 0, 0))
	UpdatePlacementFeedback(currentCost, aimPos or Vector2.zero, isTwoPointOrCarpet)
end

local SLOPE_COLORS = {
	[1] = Color3.fromRGB(76, 209, 55), [2] = Color3.fromRGB(52, 152, 219), [3] = Color3.fromRGB(44, 62, 80), [4] = Color3.fromRGB(255, 215, 0), [5] = Color3.fromRGB(255, 50, 50),
}
local function getDifficultyColor(data)
	if data.Type ~= "Slope" then return Color3.fromRGB(92, 148, 255) end
	local diff = data.Difficulty or 1
	if type(diff) == "string" then
		if diff == "Green" then diff = 1 elseif diff == "Blue" then diff = 2 elseif diff == "Black" then diff = 3 elseif diff == "Double Black" then diff = 4 elseif diff == "Triple Black" then diff = 5 end
	end
	return SLOPE_COLORS[diff] or SLOPE_COLORS[1]
end

local function trimCompactNumber(text)
	text = tostring(text)
	text = text:gsub("(%..-)0+$", "%1")
	text = text:gsub("%.$", "")
	return text
end

local function formatCompactMoney(value)
	local amount = math.max(0, tonumber(value) or 0)
	if amount >= 1000000000 then
		return trimCompactNumber(string.format("%.2f", amount / 1000000000)) .. "B"
	elseif amount >= 1000000 then
		return trimCompactNumber(string.format("%.2f", amount / 1000000)) .. "M"
	elseif amount >= 1000 then
		local inThousands = amount / 1000
		local decimals = inThousands >= 100 and 0 or 1
		return trimCompactNumber(string.format("%." .. decimals .. "f", inThousands)) .. "k"
	end
	return tostring(math.floor(amount + 0.5))
end

local function resolveItemNameFromData(data)
	if type(data) ~= "table" then return nil end
	if type(data.Name) == "string" and data.Name ~= "" then
		return data.Name
	end
	local rawId = data.ID or data.Id
	if rawId and Config.ItemNameById then
		return Config.ItemNameById[rawId]
	end
	for itemName, itemData in pairs(Config.Items or {}) do
		if itemData == data then
			return itemName
		end
	end
	return nil
end

local function formatPriceText(data, itemNameOverride)
	local itemName = (type(itemNameOverride) == "string" and itemNameOverride ~= "" and itemNameOverride) or resolveItemNameFromData(data)
	local price = nil
	if itemName and type(Config.GetPlacementCost) == "function" then
		local ok, resolved = pcall(Config.GetPlacementCost, itemName, Player)
		if ok then
			price = tonumber(resolved)
		end
	end
	price = price or tonumber(data and data.Price) or tonumber(data and data.BasePrice) or 0
	price = math.max(0, price)
	if data and (data.Type == "TwoPoint" or data.Type == "Carpet") and tonumber(data.PricePerStud) then
		return string.format("FROM $%s", formatCompactMoney(price))
	end
	return string.format("$%s", formatCompactMoney(price))
end

local MENU_PRICE_THEME = {
	AffordableText = Color3.fromRGB(67, 255, 136),
	AffordableBackground = Color3.fromRGB(18, 98, 31),
	AffordableAccent = Color3.fromRGB(67, 255, 136),
	UnaffordableText = Color3.fromRGB(255, 128, 128),
	UnaffordableBackground = Color3.fromRGB(104, 26, 26),
	UnaffordableAccent = Color3.fromRGB(255, 92, 92),
}

local ghostUpdateConnection
local placementRecoveryQueued = false

local function RecoverBrokenPlacementState(reopenMenu)
	if placementRecoveryQueued then
		return
	end
	placementRecoveryQueued = true
	task.defer(function()
		placementRecoveryQueued = false
		ContextActionService:UnbindAction(PLACEMENT_CANCEL_ACTION)
		unbindPlacementRotateActions()
		BuildStatusIndicator.hide(PlayerGui)
		if isPlacing then
			CancelPlacement(reopenMenu ~= false)
		elseif FreecamPart or (workspace.CurrentCamera and workspace.CurrentCamera.CameraType == Enum.CameraType.Scriptable) or currentGhost or startGhost or CostGui.Enabled or isProcessingPlacement or ModeState.Value == "Placing" then
			DisableFreecam()
			CleanupGhosts()
			CreateMobileControls(false)
			isProcessingPlacement = false
			hybridTouchPlacementActive = false
			mobileWorldHit = nil
			ModeState.Value = ""
		end
	end)
end

local function hasStalePlacementState()
	return (not isPlacing) and (
		FreecamPart ~= nil
		or (workspace.CurrentCamera and workspace.CurrentCamera.CameraType == Enum.CameraType.Scriptable)
		or currentGhost ~= nil
		or startGhost ~= nil
		or isProcessingPlacement
		or CostGui.Enabled
		or (MobileControlsGui and MobileControlsGui.Visible == true)
		or ModeState.Value == "Placing"
	)
end

RunService.RenderStepped:Connect(function(dt)
	for btn, state in pairs(activeSpinners) do
		if btn and btn.Parent and btn.Visible then
			state.angle = state.angle + dt * 0.8
			local offset = CFrame.Angles(0, state.angle, 0) * state.baseOffset
			state.cam.CFrame = CFrame.new(state.center + offset, state.center)
		else
			activeSpinners[btn] = nil
		end
	end
	if hasStalePlacementState() then
		RecoverBrokenPlacementState(false)
	end
end)

local function IndexAssets()
	local start = os.clock()
	for i, obj in ipairs(Assets:GetDescendants()) do
		if obj:IsA("Model") or obj:IsA("Folder") then
			local id = obj:GetAttribute("ID")
			if id then AssetIdCache[tostring(id)] = obj end
		end
		if i % 500 == 0 and (os.clock() - start) > 0.02 then task.wait(); start = os.clock() end
	end
end
task.spawn(IndexAssets)

local function ResolvePreviewModel(itemConfig, model)
	if not model then return nil end
	if itemConfig and (itemConfig.Category == "Lifts" or itemConfig.Type == "TwoPoint" or itemConfig.Type == "Carpet") and model:IsA("Folder") then
		local preferredNames
		if itemConfig.Type == "Carpet" then
			preferredNames = {"Section", "Chair", "StartStation", "EndStation", "Pole"}
		else
			preferredNames = {"StartStation", "EndStation", "Chair", "Gondola", "Section", "Pole"}
		end
		for _, childName in ipairs(preferredNames) do
			local candidate = model:FindFirstChild(childName, true)
			if candidate and candidate:IsA("Model") then
				return candidate
			end
		end
		for _, child in ipairs(model:GetChildren()) do
			if child:IsA("Model") then
				return child
			end
		end
	end
	if model:IsA("Folder") and model:FindFirstChild("StartStation") then
		return model.StartStation
	end
	return model
end

local function BuildSafePreviewProxy(model)
	if not model or not model:IsA("Model") then return nil end
	local proxy = Instance.new("Model")
	proxy.Name = model.Name .. "_Preview"
	local clonedParts = 0
	for _, desc in ipairs(model:GetDescendants()) do
		if desc:IsA("BasePart") then
			local ok, partClone = pcall(function()
				return desc:Clone()
			end)
			if ok and partClone then
				for _, child in ipairs(partClone:GetDescendants()) do
					if child:IsA("Script") or child:IsA("LocalScript") or child:IsA("ModuleScript") then
						child:Destroy()
					end
				end
				partClone.Anchored = true
				partClone.CanCollide = false
				partClone.CanTouch = false
				partClone.CanQuery = false
				partClone.Parent = proxy
				clonedParts += 1
				if clonedParts >= 20 then
					break
				end
			end
		end
	end
	if clonedParts <= 0 then
		proxy:Destroy()
		return nil
	end
	return proxy
end

CreateViewport = function(button, modelName)
	if button:FindFirstChild("Preview") then
		return
	end
	local itemConfig = Config.Items[modelName]
	local isHeavyPreview = itemConfig and (itemConfig.Category == "Lifts" or itemConfig.Type == "TwoPoint" or itemConfig.Type == "Carpet")
	local model = nil
	if itemConfig and itemConfig.Type == CustomBuildingConfig.TYPE_NAME then
		model = CustomBuildingConfig.CreateModel(modelName)
	else
		model = AssetCache[modelName]
		if not model and itemConfig and itemConfig.ID then model = AssetIdCache[tostring(itemConfig.ID)] end
		if not model then model = Assets:FindFirstChild(modelName, true) end
		if model then AssetCache[modelName] = model end
		model = ResolvePreviewModel(itemConfig, model)
	end

	-- B-039: menu preview only — some lifts lack an Assets entry; use a similar lift mesh without caching under the wrong name.
	if (not model or not model:IsA("Model")) and itemConfig then
		local PREVIEW_FALLBACK_BY_ITEM = {
			["Fixed Grip Double"] = "Double Vintage Chairlift",
		}
		local altName = PREVIEW_FALLBACK_BY_ITEM[modelName]
		if altName then
			local alt = AssetCache[altName]
			if not alt then
				local altCfg = Config.Items[altName]
				if altCfg and altCfg.ID then alt = AssetIdCache[tostring(altCfg.ID)] end
			end
			if not alt then alt = Assets:FindFirstChild(altName, true) end
			if alt then
				model = ResolvePreviewModel(itemConfig, alt)
			end
		end
	end

	if not model or not model:IsA("Model") then return end
	if isHeavyPreview then
		local safeProxy = BuildSafePreviewProxy(model)
		if safeProxy then
			model = safeProxy
		end
	end
	local oldV = button:FindFirstChild("Preview")
	if oldV then oldV:Destroy() end

	local viewport = Instance.new("ViewportFrame", button)
	viewport.Name = "Preview"
	viewport.Size = UDim2.new(1, -8, 1, -40)
	viewport.Position = UDim2.new(0, 4, 0, 30)
	viewport.BackgroundTransparency = 1
	viewport.ZIndex = button.ZIndex + 1

	local ok, clone = pcall(function()
		return model:Clone()
	end)
	if not ok or not clone then
		viewport:Destroy()
		return
	end

	local setupOk, setupErr = pcall(function()
		for _, desc in ipairs(clone:GetDescendants()) do
			if desc:IsA("Script") or desc:IsA("LocalScript") or desc:IsA("ModuleScript") then
				desc:Destroy()
			elseif desc:IsA("BasePart") then
				desc.Anchored = true
				desc.CanCollide = false
			end
		end

		clone.Parent = viewport
		local cam = Instance.new("Camera")
		cam.Parent = viewport
		viewport.CurrentCamera = cam

		local cf, size = clone:GetBoundingBox()
		local maxDim = math.max(size.X, size.Y, size.Z)
		if not (maxDim > 0) then
			maxDim = 8
		end
		local dist = maxDim * 0.65
		local baseOffset = Vector3.new(dist / 1.5, dist / 1.5, dist)
		cam.CFrame = CFrame.new(cf.Position + baseOffset, cf.Position)

		if not isHeavyPreview then
			local spinState = { cam = cam, center = cf.Position, baseOffset = baseOffset, angle = 0 }
			button.MouseEnter:Connect(function()
				activeSpinners[button] = spinState
			end)
			button.MouseLeave:Connect(function()
				activeSpinners[button] = nil
				spinState.angle = 0
				if cam.Parent then
					cam.CFrame = CFrame.new(spinState.center + spinState.baseOffset, spinState.center)
				end
			end)
		end
	end)

	if not setupOk then
		activeSpinners[button] = nil
		warn(string.format("[PlacementClient] Failed to build preview for %s: %s", tostring(modelName), tostring(setupErr)))
		viewport:Destroy()
	end
end

do
	if ResearchConfig and type(ResearchConfig.TechTree) == "table" then
		for techId, techData in pairs(ResearchConfig.TechTree) do
			if type(techData.Unlocks) == "table" then
				for _, itemName in ipairs(techData.Unlocks) do
					local itemConfig = Config.Items[itemName]
					if itemConfig and (itemConfig.ShowInMenu == false or itemConfig.Loadable == false) then
						continue
					end
					if type(itemName) == "string" and itemName ~= "" then
						local list = unlockTechByItem[itemName]
						if not list then list = {}; unlockTechByItem[itemName] = list end
						table.insert(list, techId)
					end
				end
			end
		end
	end
end

local function normalizeResearchSnapshot(snapshot)
	local normalized = { Unlocked = {} }
	if type(snapshot) ~= "table" then return normalized end
	if type(snapshot.Unlocked) == "table" then
		for techId, unlocked in pairs(snapshot.Unlocked) do
			if unlocked == true then normalized.Unlocked[techId] = true end
		end
	end
	return normalized
end

local function normalizeDecorMilestoneSnapshot(snapshot)
	local normalized = {
		BestScore = 0,
		CurrentScore = 0,
		UnlockedItems = {},
		UnlockedMilestones = {},
		NextMilestone = nil,
	}
	if type(snapshot) ~= "table" then return normalized end
	normalized.BestScore = math.max(0, math.floor(tonumber(snapshot.BestScore) or 0))
	normalized.CurrentScore = math.max(0, math.floor(tonumber(snapshot.CurrentScore) or 0))
	if type(snapshot.UnlockedItems) == "table" then
		for itemName, unlocked in pairs(snapshot.UnlockedItems) do
			if unlocked == true then normalized.UnlockedItems[itemName] = true end
		end
	end
	if type(snapshot.UnlockedMilestones) == "table" then
		for milestoneId, unlocked in pairs(snapshot.UnlockedMilestones) do
			if unlocked == true then normalized.UnlockedMilestones[milestoneId] = true end
		end
	end
	if type(snapshot.NextMilestone) == "table" and type(snapshot.NextMilestone.Name) == "string" then
		normalized.NextMilestone = {
			Id = snapshot.NextMilestone.Id,
			Name = snapshot.NextMilestone.Name,
			Score = math.max(0, math.floor(tonumber(snapshot.NextMilestone.Score) or 0)),
		}
	end
	return normalized
end

local function getDecorRequirement(itemName)
	if not DecorMilestoneConfig or type(DecorMilestoneConfig.GetRequirement) ~= "function" then
		return nil
	end
	local ok, requirement = pcall(function()
		return DecorMilestoneConfig.GetRequirement(itemName)
	end)
	return ok and requirement or nil
end

local function findOverlayTextLabels(overlay)
	local titleLabel = overlay:FindFirstChild("Title", true)
	local subtitleLabel = overlay:FindFirstChild("Subtitle", true)
	if titleLabel and titleLabel:IsA("TextLabel") and subtitleLabel and subtitleLabel:IsA("TextLabel") then
		return titleLabel, subtitleLabel
	end
	for _, descendant in ipairs(overlay:GetDescendants()) do
		if descendant:IsA("TextLabel") then
			if not titleLabel then
				titleLabel = descendant
			elseif descendant ~= titleLabel and not subtitleLabel then
				subtitleLabel = descendant
			end
		end
	end
	return titleLabel, subtitleLabel
end

local function setButtonLockedVisual(button, itemName, lockState)
	local locked = type(lockState) == "table" and lockState.unlocked ~= true
	local overlay = button:FindFirstChild("ResearchLockedOverlay")
	if locked then
		if not overlay and TemplateLockOverlay then
			overlay = TemplateLockOverlay:Clone()
			overlay.Name = "ResearchLockedOverlay"
			overlay.Visible = true
			overlay.Active = false
			overlay.Selectable = false
			overlay.ZIndex = button.ZIndex + 8
			for _, d in ipairs(overlay:GetDescendants()) do
				if d:IsA("GuiObject") then d.Active = false; d.Selectable = false; d.ZIndex = math.max(d.ZIndex, overlay.ZIndex + 1) end
			end
			overlay.Parent = button
		end
		if overlay then
			local titleLabel, subtitleLabel = findOverlayTextLabels(overlay)
			if titleLabel and titleLabel:IsA("TextLabel") then
				titleLabel.Text = lockState.title or "LOCKED"
			end
			if subtitleLabel and subtitleLabel:IsA("TextLabel") then
				subtitleLabel.Text = lockState.subtitle or string.format("Locked: %s", itemName)
			end
		end
	else
		if overlay then overlay:Destroy() end
	end
	if button:IsA("GuiButton") then
		button.AutoButtonColor = not locked
	end
	button:SetAttribute("ResearchLocked", locked and lockState and lockState.lockType == "Research" or false)
	button:SetAttribute("DecorLocked", locked and lockState and lockState.lockType == "DecorMilestone" or false)
end

local function isUnlockedFromSnapshot(itemName)
	local unlockers = unlockTechByItem[itemName]
	if not unlockers then return true end
	if type(latestResearchSnapshot) ~= "table" then return false end
	local unlockedMap = latestResearchSnapshot.Unlocked
	if type(unlockedMap) ~= "table" then return false end
	for _, techId in ipairs(unlockers) do
		if unlockedMap[techId] == true then return true end
	end
	return false
end

local function getResearchLockState(itemName)
	local unlockers = unlockTechByItem[itemName]
	if not unlockers then
		return { unlocked = true }
	end
	local unlocked = false
	if next(unlockTechByItem) ~= nil and hasResearchSnapshot then
		unlocked = isUnlockedFromSnapshot(itemName)
	else
		-- No snapshot yet: assume unlocked optimistically (async snapshot request will refresh locks)
		-- Avoid per-item InvokeServer which would block the UI for every button
		unlocked = true
	end
	return {
		unlocked = unlocked,
		lockType = "Research",
		title = "RESEARCH REQUIRED",
		subtitle = string.format("Unlock %s in Research.", itemName),
	}
end

local function canPlaceByResearch(itemName)
	return getResearchLockState(itemName).unlocked
end

local function isUnlockedFromDecorSnapshot(itemName)
	local requirement = getDecorRequirement(itemName)
	if not requirement then return true end
	if type(latestDecorMilestoneSnapshot) ~= "table" then return false end
	local unlockedItems = latestDecorMilestoneSnapshot.UnlockedItems
	if type(unlockedItems) == "table" and unlockedItems[itemName] == true then return true end
	local unlockedMilestones = latestDecorMilestoneSnapshot.UnlockedMilestones
	if type(unlockedMilestones) ~= "table" then return false end
	return unlockedMilestones[requirement.Id] == true
end

getItemLockState = function(itemName)
	local requirement = getDecorRequirement(itemName)
	if requirement then
		return {
			unlocked = hasDecorMilestoneSnapshot and isUnlockedFromDecorSnapshot(itemName) or false,
			lockType = "DecorMilestone",
			title = "DECOR MILESTONE",
			subtitle = string.format("Reach %s (%d decor score).", requirement.Name, requirement.Score),
		}
	end
	return getResearchLockState(itemName)
end

local function estimateMenuPrice(data)
	if type(data) ~= "table" then return math.huge end
	local itemName = resolveItemNameFromData(data)
	local directPrice = itemName and Config.GetPlacementCost(itemName, Player) or tonumber(data.Price) or tonumber(data.BasePrice)
	if directPrice then return math.max(0, directPrice) end
	local perStud = tonumber(data.PricePerStud)
	if perStud then return math.max(0, perStud * 100) end
	return math.huge
end

local function findButtonPriceLabel(button)
	if not button then return nil end
	local price = button:FindFirstChild("Price") or button:FindFirstChild("BaseCost") or button:FindFirstChild("Cost")
	if price and price:IsA("TextLabel") then
		return price
	end
	for _, child in ipairs(button:GetChildren()) do
		if child:IsA("TextLabel") and child.Name ~= "Title" and child.Name ~= "TextLabel" then
			return child
		end
	end
	return nil
end

function findAllButtonPriceLabels(button)
	local labels = {}
	if not button then
		return labels
	end
	for _, child in ipairs(button:GetChildren()) do
		if child:IsA("TextLabel") and (child.Name == "Price" or child.Name == "BaseCost" or child.Name == "Cost") then
			table.insert(labels, child)
		end
	end
	local fallback = findButtonPriceLabel(button)
	if fallback then
		for _, existing in ipairs(labels) do
			if existing == fallback then
				return labels
			end
		end
		table.insert(labels, fallback)
	end
	return labels
end

local function findButtonAccentBar(button)
	if not button then return nil end
	local accent = button:FindFirstChild("Frame")
	if accent and accent:IsA("Frame") then
		return accent
	end
	for _, child in ipairs(button:GetChildren()) do
		if child:IsA("Frame") and child.Size.X.Scale <= 0.08 then
			return child
		end
	end
	return nil
end

local function UpdateButtonAffordability(itemName, button)
	local data = Config.Items[itemName]
	if not data then return end
	local priceLabels = findAllButtonPriceLabels(button)
	if #priceLabels == 0 then return end

	local resolvedMenuPrice = nil
	if type(Config.GetPlacementCost) == "function" then
		local ok, value = pcall(Config.GetPlacementCost, itemName, Player)
		if ok then
			resolvedMenuPrice = tonumber(value)
		end
	end
	local menuPrice = resolvedMenuPrice or estimateMenuPrice(data)
	local canAfford = menuPrice == math.huge or GetPlayerMoney() >= menuPrice
	local accentBar = findButtonAccentBar(button)
	local displayText = formatPriceText(data, itemName)

	for _, priceLabel in ipairs(priceLabels) do
		priceLabel.Text = displayText
		priceLabel.Visible = true
		priceLabel.TextColor3 = canAfford and MENU_PRICE_THEME.AffordableText or MENU_PRICE_THEME.UnaffordableText
		priceLabel.BackgroundColor3 = canAfford and MENU_PRICE_THEME.AffordableBackground or MENU_PRICE_THEME.UnaffordableBackground
	end

	if accentBar then
		accentBar.BackgroundColor3 = canAfford and MENU_PRICE_THEME.AffordableAccent or MENU_PRICE_THEME.UnaffordableAccent
		local stroke = accentBar:FindFirstChildOfClass("UIStroke")
		if stroke then
			stroke.Color = accentBar.BackgroundColor3
		end
	end
end

local function RefreshButtonAffordability()
	for itemName, button in pairs(buttonByItemName) do
		if button and button.Parent then
			UpdateButtonAffordability(itemName, button)
		end
	end
end

local function getMenuUsefulnessRank(data)
	local category = tostring(data and data.Category or "")
	local itemType = tostring(data and data.Type or "")
	if category == "Buildings" then
		if itemType == CustomBuildingConfig.TYPE_NAME then return -1 end
		if itemType == "House" or itemType == "Hotel" then return 0 end
		if itemType == "Restaurant" or itemType == "Shop" then return 1 end
		return 2
	elseif category == "Lifts" then
		if itemType == "Carpet" then return 0 end
		if itemType == "TwoPoint" then return 1 end
		return 2
	elseif category == "Slopes" then return math.max(0, math.min(9, (tonumber(data.Difficulty) or 1) - 1))
	end
	return 5
end

local function UpdateButtonLayoutOrders()
	local entries = {}
	for itemName, button in pairs(buttonByItemName) do
		local data = Config.Items[itemName]
		if button and button.Parent and data then
			local lockState = getItemLockState(itemName)
			table.insert(entries, { name = itemName, button = button, unlocked = lockState.unlocked == true, usefulness = getMenuUsefulnessRank(data), price = estimateMenuPrice(data) })
		end
	end
	table.sort(entries, function(a, b)
		if a.unlocked ~= b.unlocked then return a.unlocked and not b.unlocked end
		if a.usefulness ~= b.usefulness then return a.usefulness < b.usefulness end
		if a.price ~= b.price then return a.price < b.price end
		return a.name < b.name
	end)
	for index, entry in ipairs(entries) do entry.button.LayoutOrder = index end
end

function applyResearchSnapshot(snapshot)
	latestResearchSnapshot = normalizeResearchSnapshot(snapshot)
	hasResearchSnapshot = true
	RefreshButtonResearchLocks()
end

function applyDecorMilestoneSnapshot(snapshot)
	latestDecorMilestoneSnapshot = normalizeDecorMilestoneSnapshot(snapshot)
	hasDecorMilestoneSnapshot = true
	RefreshButtonResearchLocks()
end

function requestResearchSnapshot()
	if not GetResearchState or not GetResearchState:IsA("RemoteFunction") then return end
	local ok, snapshot = pcall(function() return GetResearchState:InvokeServer() end)
	if ok and type(snapshot) == "table" then applyResearchSnapshot(snapshot) end
end

function requestDecorMilestoneSnapshot()
	if not GetDecorMilestoneState or not GetDecorMilestoneState:IsA("RemoteFunction") then return end
	local ok, snapshot = pcall(function() return GetDecorMilestoneState:InvokeServer() end)
	if ok and type(snapshot) == "table" then applyDecorMilestoneSnapshot(snapshot) end
end

function ensureDecorHeaderLabel()
	if DecorMilestoneStatusLabel and DecorMilestoneStatusLabel.Parent then
		return DecorMilestoneStatusLabel
	end
	local existing = Header:FindFirstChild("DecorMilestoneStatus")
	if existing and existing:IsA("TextLabel") then
		DecorMilestoneStatusLabel = existing
		return existing
	end
	local label = Instance.new("TextLabel")
	label.Name = "DecorMilestoneStatus"
	label.BackgroundTransparency = 1
	label.Position = UDim2.new(0, 12, 1, -18)
	label.Size = UDim2.new(1, -78, 0, 16)
	label.Font = Enum.Font.GothamMedium
	label.TextSize = 11
	label.TextColor3 = Color3.fromRGB(164, 193, 232)
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.TextTruncate = Enum.TextTruncate.AtEnd
	label.ZIndex = 25
	label.Parent = Header
	DecorMilestoneStatusLabel = label
	return label
end

function UpdateDecorMilestoneHeader()
	local label = ensureDecorHeaderLabel()
	if currentCategory ~= "Decor" or not (BuildFrame.Visible or isMenuOpen) then
		label.Visible = false
		return
	end
	label.Visible = true
	if not hasDecorMilestoneSnapshot then
		label.Text = "Decor score syncing..."
		return
	end
	local score = math.max(latestDecorMilestoneSnapshot.BestScore or 0, latestDecorMilestoneSnapshot.CurrentScore or 0)
	local nextMilestone = latestDecorMilestoneSnapshot.NextMilestone
	if nextMilestone then
		label.Text = string.format("Decor Score %d / %d - Next: %s", score, nextMilestone.Score, nextMilestone.Name)
	else
		label.Text = string.format("All decor unlocked - Decor Score %d", score)
	end
end

RefreshButtonResearchLocks = function()
	for itemName, button in pairs(buttonByItemName) do
		if button and button.Parent then
			setButtonLockedVisual(button, itemName, getItemLockState(itemName))
		end
	end
	RefreshButtonAffordability()
	if not isMenuOpen then
		UpdateButtonLayoutOrders()
	end
	UpdateDecorMilestoneHeader()
	if currentInfoItemName and InfoPanel and InfoPanel.Visible then
		UpdateInfoPanel(currentInfoItemName)
	end
end

UpdateInfoPanel = function(itemName)
	if not InfoPanel then return end
	local data = Config.Items[itemName]
	if not data then return end
	currentInfoItemName = itemName

	local title = InfoPanel:FindFirstChild("Title")
	if title then title.Text = string.upper(itemName) end

	local distanceStuds = nil
	local priceDetails
	if type(Config.GetPlacementPriceDetails) == "function" then
		priceDetails = Config.GetPlacementPriceDetails(itemName, Player, distanceStuds)
	else
		local basePrice = math.max(0, tonumber(data.Price) or 0)
		local pricePerStud = math.max(0, tonumber(data.PricePerStud) or 0)
		local grossCost = basePrice + (math.max(0, tonumber(distanceStuds) or 0) * pricePerStud)
		local discount = type(Config.GetResearchDiscountForPlayer) == "function"
			and Config.GetResearchDiscountForPlayer(Player, itemName, data)
			or 0
		priceDetails = {
			BasePrice = basePrice,
			PricePerStud = pricePerStud,
			GrossCost = grossCost,
			Discount = discount,
			DiscountPercent = math.floor((math.max(0, tonumber(discount) or 0) * 100) + 0.5),
			DiscountedBasePrice = type(Config.ApplyDiscount) == "function"
				and Config.ApplyDiscount(data.Price or 0, discount)
				or basePrice,
			DiscountedPricePerStud = type(Config.ApplyDiscount) == "function"
				and Config.ApplyDiscount(data.PricePerStud or 0, discount)
				or pricePerStud,
			FinalCost = type(Config.GetPlacementCost) == "function"
				and Config.GetPlacementCost(itemName, Player, distanceStuds)
				or grossCost,
			Bucket = type(Config.GetDiscountBucket) == "function"
				and Config.GetDiscountBucket(itemName, data)
				or nil,
		}
	end
	local function formatDiscountedAmount(rawAmount, discountedAmount)
		local raw = math.max(0, math.floor(tonumber(rawAmount) or 0))
		local final = math.max(0, math.floor(tonumber(discountedAmount) or raw))
		if final < raw then
			return string.format("$%d -> $%d", raw, final)
		end
		return string.format("$%d", final)
	end

	local container = InfoPanel:FindFirstChild("StatsContainer")
	if container then
		for _, c in ipairs(container:GetChildren()) do if c:IsA("Frame") then c:Destroy() end end
		local function AddStat(label, value)
			local row = Instance.new("Frame", container)
			row.Size = UDim2.new(1, 0, 0, 20)
			row.BackgroundTransparency = 1
			local l = Instance.new("TextLabel", row)
			l.Size = UDim2.new(0.5, 0, 1, 0)
			l.BackgroundTransparency = 1
			l.Text = label
			l.TextColor3 = Color3.fromRGB(160, 160, 170)
			l.Font = Enum.Font.GothamMedium
			l.TextSize = 12
			l.TextXAlignment = Enum.TextXAlignment.Left
			local v = Instance.new("TextLabel", row)
			v.Size = UDim2.new(0.5, 0, 1, 0)
			v.Position = UDim2.new(0.5, 0, 0, 0)
			v.BackgroundTransparency = 1
			v.Text = tostring(value)
			v.TextColor3 = Color3.fromRGB(255, 255, 255)
			v.Font = Enum.Font.GothamBold
			v.TextSize = 12
			v.TextXAlignment = Enum.TextXAlignment.Right
		end

		if (data.Type == "TwoPoint" or data.Type == "Carpet") and data.PricePerStud then
			AddStat("Base Price", formatDiscountedAmount(priceDetails and priceDetails.BasePrice or data.Price or 0, priceDetails and priceDetails.DiscountedBasePrice or data.Price or 0))
			AddStat("Cost/Stud", formatDiscountedAmount(priceDetails and priceDetails.PricePerStud or data.PricePerStud or 0, priceDetails and priceDetails.DiscountedPricePerStud or data.PricePerStud or 0))
		else
			AddStat("Price", formatDiscountedAmount(priceDetails and priceDetails.GrossCost or data.Price or 0, priceDetails and priceDetails.FinalCost or data.Price or 0))
		end
		if priceDetails and (priceDetails.DiscountPercent or 0) > 0 then
			AddStat("Research Discount", string.format("-%d%%", priceDetails.DiscountPercent))
		end
		if data.Type == CustomBuildingConfig.TYPE_NAME then
			AddStat("Shape", CustomBuildingConfig.GetShapeLabel(itemName))
			AddStat("Snap", string.format("%.2f studs", CustomBuildingConfig.SNAP))
			AddStat("Edit", "Move / Scale / Duplicate")
			AddStat("Rotate", string.format("%d° steps", CustomBuildingConfig.ROTATION_SNAP))
		end
		if data.Type == "TwoPoint" or data.Type == "Carpet" then
			if data.Speed then AddStat("Speed", data.Speed .. " sps") end
			if data.Capacity then AddStat("Chair Cap", data.Capacity) end
			if data.Detachable ~= nil then AddStat("Detachable", data.Detachable and "Yes" or "No") end
		end
		if data.Capacity then AddStat("Capacity", data.Capacity .. " Guests") end
		if data.Type then AddStat("Type", data.Type) end
		
		if string.match(string.lower(itemName), "slope") or string.match(string.lower(itemName), "glade") then
			AddStat("Info", "Left-click to place nodes. Follow terrain down carefully. Press X/Complete to finish.")
		elseif string.match(string.lower(itemName), "queue") or string.match(string.lower(itemName), "path") then
			AddStat("Info", "Click on a lift or building entrance to start. Route with left-clicks to path out the queue.")
		elseif data.Description then
			AddStat("Info", data.Description)
		end
	end
	InfoPanel.Visible = true
end

HideInfoPanel = function()
	currentInfoItemName = nil
	if InfoPanel then
		InfoPanel.Visible = false
		local title = InfoPanel:FindFirstChild("Title")
		if title then title.Text = "SELECT ITEM" end
		local container = InfoPanel:FindFirstChild("StatsContainer")
		if container then for _, c in ipairs(container:GetChildren()) do if c:IsA("Frame") then c:Destroy() end end end
	end
end

GenerateButtons = function()
	if not TemplateItemCard then return end
	buttonByItemName = {}
	activeSpinners = {}
	for _, c in ipairs(ContentFrame:GetChildren()) do
		if (c:IsA("GuiButton") or c:IsA("CanvasGroup")) and c.Name ~= "Delete" and c.Name ~= "Remove" then c:Destroy() end
	end

	for name, data in pairs(Config.Items) do
		if data.ShowInMenu == false then continue end
		if data.AllowedUsers ~= nil then
			local allowed = false
			for _, u in ipairs(data.AllowedUsers) do
				if u == Player.Name then allowed = true; break end
			end
			if not allowed then continue end
		end

		local btn = TemplateItemCard:Clone()
		btn.Name = name
		btn.Visible = true
		btn.Parent = ContentFrame
		buttonByItemName[name] = btn

		local clickSurface = btn:FindFirstChild("Button")
		if clickSurface and clickSurface:IsA("GuiButton") then
			clickSurface.Visible = true
			clickSurface.Active = true
			clickSurface.Selectable = true
			clickSurface.AutoButtonColor = true
			clickSurface.ZIndex = math.max(clickSurface.ZIndex, btn.ZIndex + 20)
		end
		local previewFrame = btn:FindFirstChild("Preview")
		if previewFrame and previewFrame:IsA("GuiObject") then
			previewFrame.Active = false
			previewFrame.Selectable = false
		end

		local s = btn:FindFirstChildOfClass("UIStroke")
		local accent = btn:FindFirstChild("Frame") or btn:FindFirstChildWhichIsA("Frame")
		local accentColor = getDifficultyColor(data)
		if data.Type == "Slope" and s then s.Color = accentColor end
		if accent then accent.BackgroundColor3 = accentColor end

		local title = btn:FindFirstChild("Title") or btn:FindFirstChild("TextLabel")
		if title and title:IsA("TextLabel") then title.Text = name; title.ZIndex = btn.ZIndex + 5 end

		for _, priceLabel in ipairs(findAllButtonPriceLabels(btn)) do
			priceLabel.ZIndex = btn.ZIndex + 5
		end
		UpdateButtonAffordability(name, btn)

		local lockState = getItemLockState(name)
		setButtonLockedVisual(btn, name, lockState)

		local expectedCategory = data.Category
		local hoverSurface = (clickSurface and clickSurface:IsA("GuiButton")) and clickSurface or btn
		connectGuiButton(btn, function()
			if currentCategory ~= expectedCategory or btn.Visible ~= true then return end
			local latestLockState = getItemLockState(name)
			setButtonLockedVisual(btn, name, latestLockState)
			if latestLockState.unlocked ~= true then return end
			if data.Type == "Slope" then
				local bridge = Events:FindFirstChild("StartSlopePlacement")
				if not bridge then bridge = Instance.new("BindableEvent"); bridge.Name = "StartSlopePlacement"; bridge.Parent = Events end
				bridge:Fire(name, data)
				ToggleMenu(false)
				return
			end
			ActivatePlacement(name)
		end)
		hoverSurface.MouseEnter:Connect(function() UpdateInfoPanel(name) end)
		hoverSurface.MouseLeave:Connect(function() HideInfoPanel() end)
	end
	RefreshButtonAffordability()
	UpdateButtonLayoutOrders()
	SelectCategory(currentCategory)
end

SetupUI = function()
	BuildFrame.Visible = true
	BuildFrame.ClipsDescendants = false
	BuildFrame.AnchorPoint = Vector2.new(0.5, 0.5)
	ApplyResponsiveBuildLayout()
	BuildFrame.Position = POS_CLOSED
	BuildFrame.ZIndex = 10
	Header.ZIndex = 20
	CloseButton.ZIndex = 25
	ContentFrame.ZIndex = 15
	for _, child in ipairs(Header:GetChildren()) do if child:IsA("GuiObject") then child.ZIndex = 25 end end
	if SearchPanel and SearchPanel:IsA("GuiObject") then
		SearchPanel.ZIndex = 35
		for _, child in ipairs(SearchPanel:GetDescendants()) do
			if child:IsA("GuiObject") then
				child.ZIndex = math.max(child.ZIndex, 36)
			end
		end
	end
	if SearchBox and SearchBox:IsA("TextBox") then
		SearchBox.Text = ""
	end
	buildSearchText = ""
	setBuildSearchOpen(false)
	local padding = ContentFrame:FindFirstChildOfClass("UIPadding") or Instance.new("UIPadding", ContentFrame)
	padding.PaddingTop = UDim.new(0, 10); padding.PaddingBottom = UDim.new(0, 10); padding.PaddingLeft = UDim.new(0, 10); padding.PaddingRight = UDim.new(0, 10)
	local grid = ContentFrame:FindFirstChildOfClass("UIGridLayout") or Instance.new("UIGridLayout", ContentFrame)
	grid.CellSize = UDim2.new(0, 145, 0, 145); grid.CellPadding = UDim2.new(0, 10, 0, 10)
	grid.HorizontalAlignment = Enum.HorizontalAlignment.Center; grid.SortOrder = Enum.SortOrder.LayoutOrder
end

-- Connections
(function()
	local dockBuildButton = Dock:WaitForChild("Build")
	dockBuildButton.Active = true
	dockBuildButton.Selectable = true
	dockBuildButton.AutoButtonColor = true
	connectGuiButton(dockBuildButton, function() ToggleMenu() end)
	connectGuiButton(CloseButton, function()
		if isPlacing then
			CancelPlacement(false)
		else
			if InfoPanel then HideInfoPanel() end
			setBuildSearchOpen(false)
			ToggleMenu(false)
			buildMenuTweenToken += 1
			BuildFrame.Visible = false
			BuildFrame.Position = POS_CLOSED
			isMenuOpen = false
		end
	end)

	for _, tabButton in ipairs(CategoryTabs:GetChildren()) do
		if tabButton:IsA("GuiButton") then
			connectGuiButton(tabButton, function()
				SelectCategory(tabButton.Name)
			end)
		end
	end

	if SearchButton and SearchButton:IsA("GuiButton") then
		connectGuiButton(SearchButton, function()
			setBuildSearchOpen(not buildSearchOpen)
			if buildSearchOpen and SearchBox and SearchBox:IsA("TextBox") then
				SearchBox:CaptureFocus()
			end
		end)
	end
	if SearchBox and SearchBox:IsA("TextBox") then
		SearchBox:GetPropertyChangedSignal("Text"):Connect(function()
			if SearchBox.Text ~= "" and not buildSearchOpen then
				setBuildSearchOpen(true)
			end
			setBuildSearchQuery(SearchBox.Text)
		end)
		SearchBox.FocusLost:Connect(function(enterPressed)
			if enterPressed then
				SearchBox:ReleaseFocus()
			end
		end)
	end

	if ResearchUpdate and ResearchUpdate:IsA("RemoteEvent") then
		ResearchUpdate.OnClientEvent:Connect(function(snapshot) applyResearchSnapshot(snapshot) end)
	end

	if DecorMilestoneUpdate and DecorMilestoneUpdate:IsA("RemoteEvent") then
		DecorMilestoneUpdate.OnClientEvent:Connect(function(snapshot) applyDecorMilestoneSnapshot(snapshot) end)
	end
end)();

(function()
	local moneyValueConnection = nil
	local leaderstatsChildConnection = nil
	local observedLeaderstats = nil

	local function bindMoneyAffordabilityRefresh()
		local leaderstats = Player:FindFirstChild("leaderstats")
		if leaderstats ~= observedLeaderstats then
			observedLeaderstats = leaderstats
			if leaderstatsChildConnection then
				leaderstatsChildConnection:Disconnect()
				leaderstatsChildConnection = nil
			end
			if leaderstats then
				leaderstatsChildConnection = leaderstats.ChildAdded:Connect(function(child)
					if child.Name == "Money" or child.Name == "Cash" then
						task.defer(RefreshButtonAffordability)
					end
				end)
			end
		end

		if moneyValueConnection then
			moneyValueConnection:Disconnect()
			moneyValueConnection = nil
		end

		local moneyValue = leaderstats and (leaderstats:FindFirstChild("Money") or leaderstats:FindFirstChild("Cash"))
		if moneyValue then
			moneyValueConnection = moneyValue:GetPropertyChangedSignal("Value"):Connect(RefreshButtonAffordability)
		end

		RefreshButtonAffordability()
	end

	Player.ChildAdded:Connect(function(child)
		if child.Name == "leaderstats" then
			task.defer(RefreshButtonAffordability)
		end
	end)

	bindMoneyAffordabilityRefresh()
end)()

UpdateMobileButtons = function()
	if not MobileActionBtn then return end
	local data = Config.Items[currentItemName]
	if not data then return end
	if data.Type == "TwoPoint" or data.Type == "Carpet" then
		MobileActionBtn.Text = placementStep == 1 and "SET START" or "SET END"
	else
		MobileActionBtn.Text = "PLACE"
	end
	MobileActionBtn.BackgroundColor3 = Color3.fromRGB(50, 50, 60)
end

CreateMobileControls = function(visible)
	local isMobile = IsMobilePlacementMode()
	if not isMobile then
		if MobileControlsGui then MobileControlsGui.Visible = false end
		if TooltipGui then TooltipGui.Visible = visible end
		if CostLabel then CostLabel.Visible = visible end
		if WarningLabel then WarningLabel.Visible = visible and (not isValidPlacement) and placementWarning ~= "" end
		if HintLabel then HintLabel.Visible = visible end
		if placementReticle then placementReticle.Visible = false end
		if mobileHintLabel then mobileHintLabel.Visible = false end
		if not visible then CostGui.Enabled = false end
		return
	end

	if TooltipGui then TooltipGui.Visible = false end
	if CostLabel then CostLabel.Visible = false end
	if WarningLabel then WarningLabel.Visible = false end
	if HintLabel then HintLabel.Visible = false end

	local reticle = EnsurePlacementReticle()
	if reticle then reticle.Visible = false end
	local hint = EnsureMobileHintLabel()
	if hint then hint.Visible = visible end

	if MobileControlsGui then
		MobileControlsGui.Visible = visible
		if visible then
			MobileControlsGui.Active = false
			UpdateMobileButtons()
			CostGui.Enabled = true
		else
			CostGui.Enabled = false
		end
	end
end

if MobileCancelBtn then connectGuiButton(MobileCancelBtn, function() CancelPlacement(true) end) end
if MobileRotateBtn then connectGuiButton(MobileRotateBtn, function()
	currentRotation = (currentRotation + 45) % 360
	if isPlacing and currentGhost then
		UpdateGhost(0)
	end
end) end
if MobileActionBtn then connectGuiButton(MobileActionBtn, function() ConfirmPlacement() end) end

(function()
	local isUpHeld = false
	local isDownHeld = false
	if MobileUpBtn then
		MobileUpBtn.InputBegan:Connect(function(i)
			if i.UserInputType == Enum.UserInputType.Touch or i.UserInputType == Enum.UserInputType.MouseButton1 then
				isUpHeld = true
				while isUpHeld and isPlacing do
					AdjustPlacementHeight(GetPlacementHeightStep())
					task.wait(0.15)
				end
			end
		end)
		MobileUpBtn.InputEnded:Connect(function(i)
			if i.UserInputType == Enum.UserInputType.Touch or i.UserInputType == Enum.UserInputType.MouseButton1 then
				isUpHeld = false
			end
		end)
	end

	if MobileDownBtn then
		MobileDownBtn.InputBegan:Connect(function(i)
			if i.UserInputType == Enum.UserInputType.Touch or i.UserInputType == Enum.UserInputType.MouseButton1 then
				isDownHeld = true
				while isDownHeld and isPlacing do
					AdjustPlacementHeight(-GetPlacementHeightStep())
					task.wait(0.15)
				end
			end
		end)
		MobileDownBtn.InputEnded:Connect(function(i)
			if i.UserInputType == Enum.UserInputType.Touch or i.UserInputType == Enum.UserInputType.MouseButton1 then
				isDownHeld = false
			end
		end)
	end
end)()

UserInputService.TouchTap:Connect(function(touchPositions, gameProcessed)
	if gameProcessed or not isPlacing then
		return
	end
	setPlacementInputMode(true)
	if not IsMobilePlacementMode() then
		return
	end
	local touchPos = type(touchPositions) == "table" and touchPositions[1]
	if typeof(touchPos) ~= "Vector2" then
		return
	end
	if isTouchConsumedByPlacementUi(touchPos) then
		return
	end
	mobileWorldHit = touchPos
	ConfirmPlacement()
end)

UserInputService.InputBegan:Connect(function(i, p)
	if isPlacing and (i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.MouseButton2) then
		setPlacementInputMode(false)
	end
	if isPlacing and not IsMobilePlacementMode() and FreecamPart and i.UserInputType == Enum.UserInputType.MouseButton2 then
		freecamRotateActive = true
		UserInputService.MouseBehavior = Enum.MouseBehavior.LockCurrentPosition
		UserInputService.MouseIconEnabled = false
		return
	end
	if (not isPlacing) and (FreecamPart or (workspace.CurrentCamera and workspace.CurrentCamera.CameraType == Enum.CameraType.Scriptable)) then
		RecoverBrokenPlacementState(false)
	end
	if isPlacing and (i.KeyCode == Enum.KeyCode.Z or i.KeyCode == Enum.KeyCode.Escape) then CancelPlacement(true); return end
	if p then return end
	if i.KeyCode == Enum.KeyCode.Escape then
		if isMenuOpen then
			ToggleMenu(false)
		end
		return
	end
	if isPlacing then
		if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then
			if IsMobilePlacementMode() and not p then
				UpdateMobileHit(i)
			end

			if UserInputService.TouchEnabled and i.UserInputType == Enum.UserInputType.Touch then return end
			if MobileControlsGui and MobileControlsGui.Visible and i.UserInputType ~= Enum.UserInputType.MouseButton1 then return end
			ConfirmPlacement()
		elseif i.KeyCode == Enum.KeyCode.U or i.KeyCode == Enum.KeyCode.PageUp then
			AdjustPlacementHeight(GetPlacementHeightStep())
		elseif i.KeyCode == Enum.KeyCode.J or i.KeyCode == Enum.KeyCode.PageDown then
			AdjustPlacementHeight(-GetPlacementHeightStep())
		end
	end
end)

UserInputService.InputChanged:Connect(function(i, p)
	if isPlacing and i.UserInputType == Enum.UserInputType.Touch then
		UpdateMobileHit(i)
	elseif isPlacing and i.UserInputType == Enum.UserInputType.MouseMovement then
		setPlacementInputMode(false)
	end
	if not isPlacing or IsMobilePlacementMode() or not FreecamPart then
		return
	end
	if i.UserInputType == Enum.UserInputType.MouseMovement and freecamRotateActive then
		freecamCameraYaw -= i.Delta.X * FREECAM_ROTATE_SENSITIVITY
		freecamCameraPitch = math.clamp(freecamCameraPitch - (i.Delta.Y * FREECAM_ROTATE_SENSITIVITY), -math.rad(80), math.rad(80))
		updatePlacementFreecamCamera()
	elseif i.UserInputType == Enum.UserInputType.MouseWheel then
		local lookVector = CFrame.fromOrientation(freecamCameraPitch, freecamCameraYaw, 0).LookVector
		FreecamPart.Position += lookVector * (i.Position.Z * 8)
	end
end)

UserInputService.InputEnded:Connect(function(i)
	if i.UserInputType == Enum.UserInputType.MouseButton2 and freecamRotateActive then
		freecamRotateActive = false
		if not UserInputService:GetFocusedTextBox() then
			UserInputService.MouseBehavior = Enum.MouseBehavior.Default
			UserInputService.MouseIconEnabled = true
		end
	end
end)

RunService.RenderStepped:Connect(function()
	if isPlacing and FreecamPart and not IsMobilePlacementMode() then
		updatePlacementFreecamCamera()
	elseif not FreecamPart and workspace.CurrentCamera and workspace.CurrentCamera.CameraType == Enum.CameraType.Scriptable then
		workspace.CurrentCamera.CameraType = Enum.CameraType.Custom
	end
end)

setGhostUpdateEnabled = function(enabled)
	if enabled then
		if not ghostUpdateConnection then
			ghostUpdateConnection = RunService.RenderStepped:Connect(UpdateGhost)
		end
	elseif ghostUpdateConnection then
		ghostUpdateConnection:Disconnect()
		ghostUpdateConnection = nil
	end
end

SetupUI()
requestResearchSnapshot()
requestDecorMilestoneSnapshot()
task.defer(RefreshButtonAffordability)
GenerateButtons()
BindResponsiveBuildLayout()
workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
	BindResponsiveBuildLayout()
	task.defer(ApplyResponsiveBuildLayout)
end)

do
	TesterStatuesReady = Events:FindFirstChild("TesterStatuesReady") or Events:WaitForChild("TesterStatuesReady", 5)
	if TesterStatuesReady then
		TesterStatuesReady.OnClientEvent:Connect(function(newItems)
			local changed = false
			for name, data in pairs(newItems) do
				if not Config.Items[name] then
					Config.Items[name] = data
					changed = true
				end
			end
			if changed then
				GenerateButtons()
			end
		end)
	end
end

RefreshButtonResearchLocks()
ToggleMenu(false)
-- Hold-R/Q continuous rotation for placement
do
	_rotateHeldDir = 0
	_rotateThread = nil

	UserInputService.InputBegan:Connect(function(input, gp)
		if gp then return end
		if not currentGhost then return end
		if input.KeyCode == Enum.KeyCode.R or input.KeyCode == Enum.KeyCode.T then
			local dir = input.KeyCode == Enum.KeyCode.R and 15 or -15
			_rotateHeldDir = dir
			if _rotateThread then task.cancel(_rotateThread) end
			_rotateThread = task.spawn(function()
				task.wait(0.3)
				while _rotateHeldDir ~= 0 do
					currentRotation = (currentRotation + _rotateHeldDir) % 360
					if currentGhost then UpdateGhost(0) end
					task.wait(0.08)
				end
			end)
		end
	end)

	UserInputService.InputEnded:Connect(function(input)
		if input.KeyCode == Enum.KeyCode.R or input.KeyCode == Enum.KeyCode.T then
			_rotateHeldDir = 0
			if _rotateThread then
				task.cancel(_rotateThread)
				_rotateThread = nil
			end
		end
	end)
end
