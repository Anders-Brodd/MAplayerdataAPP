local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")

local Player = Players.LocalPlayer
local PlayerGui = Player:WaitForChild("PlayerGui")
local MainHUD = PlayerGui:WaitForChild("MainHUD")
local BuildFrame = MainHUD:WaitForChild("BuildFrame")
local BuilderButton = BuildFrame:WaitForChild("Buttons"):WaitForChild("Paint")

local BUILDER_STUDIO_ENABLED = false
if not BUILDER_STUDIO_ENABLED then
	BuilderButton.Visible = false
	BuilderButton.Active = false
	BuilderButton.AutoButtonColor = false
	BuilderButton.Text = ""
	local existingCaption = BuilderButton:FindFirstChild("BuilderCaption")
	if existingCaption then
		existingCaption:Destroy()
	end
	return
end

local Events = ReplicatedStorage:WaitForChild("Events")
local ClosePanels = Events:FindFirstChild("ClosePanels")
if not ClosePanels then
	ClosePanels = Instance.new("BindableEvent")
	ClosePanels.Name = "ClosePanels"
	ClosePanels.Parent = Events
end

local CustomBuildingConfig = require(ReplicatedStorage:WaitForChild("CustomBuildingConfig"))
local RequestPlaceItem = Events:WaitForChild("RequestPlaceItem")
local RequestRemoveItem = Events:WaitForChild("RequestRemoveItem")
local CustomBuildRequest = Events:WaitForChild("CustomBuildRequest")

local ModeState = PlayerGui:FindFirstChild("ModeState") or Instance.new("StringValue")
ModeState.Name = "ModeState"
ModeState.Parent = PlayerGui

local function releaseFocusedTextBox()
	local focused = UserInputService:GetFocusedTextBox()
	if focused then
		pcall(function()
			focused:ReleaseFocus()
		end)
	end
end

local TOOLS = { "Place", "Select", "Move", "Scale", "Rotate", "Paint" }
local TOOL_COLORS = {
	Place = Color3.fromRGB(92, 148, 255),
	Select = Color3.fromRGB(92, 148, 255),
	Move = Color3.fromRGB(76, 209, 153),
	Scale = Color3.fromRGB(255, 176, 88),
	Rotate = Color3.fromRGB(187, 116, 255),
	Paint = Color3.fromRGB(255, 120, 120),
}

local Controls = nil
local FreecamPart = nil
local isBuilderOpen = false
local openedFromButton = false
local activeTool = "Place"
local selectedAxis = "X"
local currentShapeItemName = CustomBuildingConfig.ITEM_NAME
local currentPlacementRotation = 0
local selectedModel = nil
local hoveredModel = nil
local previewGhost = nil
local dragging = false
local dragPlaneY = 0
local dragOffset = Vector3.zero
local selectedColor = CustomBuildingConfig.DEFAULT_COLOR
local selectedMaterial = CustomBuildingConfig.DEFAULT_MATERIAL
local pendingCommitToken = 0
local pendingPaintToken = 0
local lastRayResult = nil
local lastStatusText = ""
local lastViewportSize = Vector2.zero
local lastActionKey = ""
local handleDragging = false
local handleDragState = nil
local dragFromSelection = false
local freecamVerticalInput = 0
local freecamRotateActive = false
local freecamCameraYaw = 0
local freecamCameraPitch = 0
local FREECAM_ROTATE_SENSITIVITY = 0.0032
local hsvHue, hsvSaturation, hsvValue = Color3.toHSV(CustomBuildingConfig.DEFAULT_COLOR)
local pickingColorArea = false
local pickingHue = false
local materialDropdownOpen = false

local TerrainRayParams = RaycastParams.new()
TerrainRayParams.FilterType = Enum.RaycastFilterType.Include
TerrainRayParams.FilterDescendantsInstances = {workspace.Terrain}
TerrainRayParams.IgnoreWater = true

local function isTouchBuilder()
	return UserInputService.TouchEnabled and not UserInputService.MouseEnabled
end

local function wantsFreecam()
	return not isTouchBuilder()
end

local function setButtonCaption(button, text)
	local caption = button:FindFirstChild("BuilderCaption")
	if not caption then
		caption = Instance.new("TextLabel")
		caption.Name = "BuilderCaption"
		caption.BackgroundTransparency = 1
		caption.AnchorPoint = Vector2.new(0.5, 1)
		caption.Position = UDim2.new(0.5, 0, 1, -2)
		caption.Size = UDim2.new(1, -4, 0, 12)
		caption.Font = Enum.Font.GothamBold
		caption.TextColor3 = Color3.fromRGB(236, 242, 255)
		caption.TextSize = 9
		caption.ZIndex = 8
		caption.Parent = button
	end
	caption.Text = text
end


local function getControls()
	if Controls then
		return Controls
	end
	local playerScripts = Player:FindFirstChild("PlayerScripts")
	if not playerScripts then
		return nil
	end
	local playerModule = playerScripts:FindFirstChild("PlayerModule")
	if not playerModule then
		return nil
	end
	Controls = require(playerModule):GetControls()
	return Controls
end

local function getScreenPoint()
	local camera = workspace.CurrentCamera
	if not camera then
		return Vector2.zero
	end
	if isTouchBuilder() then
		local viewport = camera.ViewportSize
		return Vector2.new(viewport.X * 0.5, viewport.Y * 0.5)
	end
	return UserInputService:GetMouseLocation()
end

local function pointInside(guiObject, point)
	if not guiObject.Visible then
		return false
	end
	local pos = guiObject.AbsolutePosition
	local size = guiObject.AbsoluteSize
	return point.X >= pos.X and point.X <= pos.X + size.X and point.Y >= pos.Y and point.Y <= pos.Y + size.Y
end

local function getBottomOffset(model)
	if not model then
		return 0
	end
	local pivotPos = model:GetPivot().Position
	local bbCF, bbSize = model:GetBoundingBox()
	local offset = pivotPos.Y - (bbCF.Position.Y - (bbSize.Y * 0.5))
	if offset > 50 or offset < -10 then
		return 0
	end
	return offset
end

local function findCustomBlockModel(part)
	local current = part
	while current and current ~= workspace do
		if current:IsA("Model") and current:GetAttribute("Type") == CustomBuildingConfig.TYPE_NAME and current:GetAttribute("UUID") and current:GetAttribute("Owner") == Player.UserId then
			return current
		end
		current = current.Parent
	end
	return nil
end

local function findModelByUuid(uuid)
	if type(uuid) ~= "string" or uuid == "" then
		return nil
	end
	local placedFolder = workspace:FindFirstChild("PlacedObjects")
	if not placedFolder then
		return nil
	end
	for _, child in ipairs(placedFolder:GetChildren()) do
		if child:IsA("Model") and child:GetAttribute("UUID") == uuid and child:GetAttribute("Owner") == Player.UserId then
			return child
		end
	end
	return nil
end

local function getRayResult()
	local camera = workspace.CurrentCamera
	if not camera then
		return nil
	end
	local screenPoint = getScreenPoint()
	local ray = camera:ScreenPointToRay(screenPoint.X, screenPoint.Y)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local ignore = { Player.Character }
	if previewGhost then
		table.insert(ignore, previewGhost)
	end
	if FreecamPart then
		table.insert(ignore, FreecamPart)
	end
	params.FilterDescendantsInstances = ignore
	return workspace:Raycast(ray.Origin, ray.Direction * 3000, params)
end

local function getPlaneHit(y)
	local camera = workspace.CurrentCamera
	if not camera then
		return nil
	end
	local screenPoint = getScreenPoint()
	local ray = camera:ScreenPointToRay(screenPoint.X, screenPoint.Y)
	if math.abs(ray.Direction.Y) < 1e-4 then
		return nil
	end
	local distance = (y - ray.Origin.Y) / ray.Direction.Y
	if distance < 0 then
		return nil
	end
	return ray.Origin + ray.Direction * distance
end

local function alignPositionToSurface(model, hitPosition)
	if not hitPosition then
		return nil
	end
	return CustomBuildingConfig.SnapVector3(hitPosition + Vector3.new(0, getBottomOffset(model), 0))
end

local function normalIdToAxis(normalId)
	if normalId == Enum.NormalId.Left or normalId == Enum.NormalId.Right then
		return "X"
	elseif normalId == Enum.NormalId.Top or normalId == Enum.NormalId.Bottom then
		return "Y"
	end
	return "Z"
end

local function normalIdToLocalDirection(normalId)
	if normalId == Enum.NormalId.Right then
		return Vector3.new(1, 0, 0)
	elseif normalId == Enum.NormalId.Left then
		return Vector3.new(-1, 0, 0)
	elseif normalId == Enum.NormalId.Top then
		return Vector3.new(0, 1, 0)
	elseif normalId == Enum.NormalId.Bottom then
		return Vector3.new(0, -1, 0)
	elseif normalId == Enum.NormalId.Front then
		return Vector3.new(0, 0, -1)
	end
	return Vector3.new(0, 0, 1)
end

local function syncBuilderFreecamCameraState()
	local camera = workspace.CurrentCamera
	if not camera then
		return
	end
	local pitch, yaw = camera.CFrame:ToOrientation()
	freecamCameraYaw = yaw
	freecamCameraPitch = math.clamp(pitch, -math.rad(80), math.rad(80))
end

local function updateBuilderFreecamCamera()
	local camera = workspace.CurrentCamera
	if not camera or not FreecamPart then
		return
	end
	camera.CameraType = Enum.CameraType.Scriptable
	camera.CFrame = CFrame.new(FreecamPart.Position) * CFrame.fromOrientation(freecamCameraPitch, freecamCameraYaw, 0)
end

local function releaseBuilderFreecamCamera()
	local camera = workspace.CurrentCamera
	if camera then
		camera.CameraType = Enum.CameraType.Custom
	end
	freecamRotateActive = false
	UserInputService.MouseBehavior = Enum.MouseBehavior.Default
	UserInputService.MouseIconEnabled = true
end

local function enableFreecam()
	if not wantsFreecam() or FreecamPart then
		return
	end
	FreecamPart = Instance.new("Part")
	FreecamPart.Name = "BuilderStudioFreecamRoot"
	FreecamPart.Transparency = 1
	FreecamPart.CanCollide = false
	FreecamPart.Anchored = true
	FreecamPart.Size = Vector3.new(1, 1, 1)
	local currentCamera = workspace.CurrentCamera
	FreecamPart.Position = (Player.Character and Player.Character:GetPivot().Position or (currentCamera and currentCamera.CFrame.Position) or Vector3.zero) + Vector3.new(0, 16, 0)
	FreecamPart.Parent = workspace
	syncBuilderFreecamCameraState()
	updateBuilderFreecamCamera()
	local rootPart = Player.Character and Player.Character:FindFirstChild("HumanoidRootPart")
	if rootPart then
		rootPart.Anchored = true
	end
	UserInputService.MouseBehavior = Enum.MouseBehavior.Default
	UserInputService.MouseIconEnabled = true
end

local function disableFreecam()
	if not FreecamPart then
		releaseBuilderFreecamCamera()
		return
	end
	local rootPart = Player.Character and Player.Character:FindFirstChild("HumanoidRootPart")
	if rootPart then
		local rayResult = workspace:Raycast(FreecamPart.Position + Vector3.new(0, 32, 0), Vector3.new(0, -512, 0), TerrainRayParams)
		local groundedPosition = rayResult and (rayResult.Position + Vector3.new(0, 4, 0)) or FreecamPart.Position
		rootPart.AssemblyLinearVelocity = Vector3.zero
		rootPart.AssemblyAngularVelocity = Vector3.zero
		rootPart.CFrame = CFrame.new(groundedPosition)
		rootPart.Anchored = false
	end
	local humanoid = Player.Character and Player.Character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		workspace.CurrentCamera.CameraSubject = humanoid
	elseif rootPart then
		workspace.CurrentCamera.CameraSubject = rootPart
	end
	FreecamPart:Destroy()
	FreecamPart = nil
	releaseBuilderFreecamCamera()
end

local Highlight = Instance.new("Highlight")
Highlight.Name = "BuilderStudioHighlightV2"
Highlight.FillColor = Color3.fromRGB(92, 148, 255)
Highlight.OutlineColor = Color3.fromRGB(255, 255, 255)
Highlight.FillTransparency = 0.45
Highlight.Parent = PlayerGui

local MoveHandles = Instance.new("Handles")
MoveHandles.Name = "BuilderMoveHandles"
MoveHandles.Style = Enum.HandlesStyle.Movement
MoveHandles.Faces = Faces.new(true, true, true, true, true, true)
MoveHandles.Color3 = Color3.fromRGB(76, 209, 153)
MoveHandles.Visible = false
MoveHandles.Parent = PlayerGui

local ScaleHandles = Instance.new("Handles")
ScaleHandles.Name = "BuilderScaleHandles"
ScaleHandles.Style = Enum.HandlesStyle.Resize
ScaleHandles.Faces = Faces.new(true, true, true, true, true, true)
ScaleHandles.Color3 = Color3.fromRGB(255, 176, 88)
ScaleHandles.Visible = false
ScaleHandles.Parent = PlayerGui

local RotateHandles = Instance.new("ArcHandles")
RotateHandles.Name = "BuilderRotateHandles"
RotateHandles.Axes = Axes.new(false, true, false)
RotateHandles.Color3 = Color3.fromRGB(187, 116, 255)
RotateHandles.Visible = false
RotateHandles.Parent = PlayerGui

local Gui = Instance.new("ScreenGui")
Gui.Name = "BuilderStudioGuiV2"
Gui.ResetOnSpawn = false
Gui.Enabled = false
Gui.Parent = PlayerGui

local Panel = Instance.new("ScrollingFrame")
Panel.Name = "Panel"
Panel.AnchorPoint = Vector2.new(1, 0)
Panel.Position = UDim2.new(1, -18, 0, 120)
Panel.Size = UDim2.new(0, 330, 0, 420)
Panel.BackgroundColor3 = Color3.fromRGB(14, 18, 28)
Panel.BackgroundTransparency = 0.04
Panel.BorderSizePixel = 0
Panel.AutomaticCanvasSize = Enum.AutomaticSize.Y
Panel.CanvasSize = UDim2.new()
Panel.ScrollingDirection = Enum.ScrollingDirection.Y
Panel.ScrollBarThickness = 5
Panel.ScrollBarImageColor3 = Color3.fromRGB(92, 148, 255)
Panel.Visible = true
Panel.Parent = Gui
Instance.new("UICorner", Panel).CornerRadius = UDim.new(0, 14)
local PanelStroke = Instance.new("UIStroke")
PanelStroke.Color = Color3.fromRGB(92, 148, 255)
PanelStroke.Transparency = 0.12
PanelStroke.Thickness = 1.5
PanelStroke.Parent = Panel

local PanelLayout = Instance.new("UIListLayout")
PanelLayout.Padding = UDim.new(0, 8)
PanelLayout.SortOrder = Enum.SortOrder.LayoutOrder
PanelLayout.Parent = Panel

local PanelPadding = Instance.new("UIPadding")
PanelPadding.PaddingTop = UDim.new(0, 12)
PanelPadding.PaddingBottom = UDim.new(0, 12)
PanelPadding.PaddingLeft = UDim.new(0, 12)
PanelPadding.PaddingRight = UDim.new(0, 12)
PanelPadding.Parent = Panel

local function createSectionLabel(order, text)
	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Size = UDim2.new(1, 0, 0, 16)
	label.LayoutOrder = order
	label.Font = Enum.Font.GothamBold
	label.Text = text
	label.TextSize = 12
	label.TextColor3 = Color3.fromRGB(245, 247, 255)
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.Parent = Panel
	return label
end

local function createSectionFrame(order, height)
	local frame = Instance.new("Frame")
	frame.BackgroundColor3 = Color3.fromRGB(20, 24, 36)
	frame.BackgroundTransparency = 0.08
	frame.BorderSizePixel = 0
	frame.Size = UDim2.new(1, 0, 0, height)
	frame.LayoutOrder = order
	frame.Parent = Panel
	Instance.new("UICorner", frame).CornerRadius = UDim.new(0, 10)
	return frame
end

local function createActionButton(parent, text, color)
	local button = Instance.new("TextButton")
	button.BackgroundColor3 = color or Color3.fromRGB(30, 37, 52)
	button.BorderSizePixel = 0
	button.Text = text
	button.TextColor3 = Color3.fromRGB(245, 247, 255)
	button.TextSize = 11
	button.Font = Enum.Font.GothamBold
	button.AutoButtonColor = true
	button.Parent = parent
	Instance.new("UICorner", button).CornerRadius = UDim.new(0, 8)
	return button
end

local Header = Instance.new("Frame")
Header.BackgroundTransparency = 1
Header.Size = UDim2.new(1, 0, 0, 40)
Header.LayoutOrder = 0
Header.Parent = Panel

local TitleLabel = Instance.new("TextLabel")
TitleLabel.BackgroundTransparency = 1
TitleLabel.Size = UDim2.new(1, -90, 0, 20)
TitleLabel.Font = Enum.Font.GothamBlack
TitleLabel.Text = "BUILD STUDIO"
TitleLabel.TextColor3 = Color3.fromRGB(244, 247, 255)
TitleLabel.TextSize = 18
TitleLabel.TextXAlignment = Enum.TextXAlignment.Left
TitleLabel.Parent = Header

local SubtitleLabel = Instance.new("TextLabel")
SubtitleLabel.BackgroundTransparency = 1
SubtitleLabel.Position = UDim2.new(0, 0, 0, 20)
SubtitleLabel.Size = UDim2.new(1, -90, 0, 14)
SubtitleLabel.Font = Enum.Font.GothamMedium
SubtitleLabel.Text = "Clean tools. Saves automatically."
SubtitleLabel.TextColor3 = Color3.fromRGB(182, 198, 229)
SubtitleLabel.TextSize = 11
SubtitleLabel.TextXAlignment = Enum.TextXAlignment.Left
SubtitleLabel.Parent = Header

local DoneButton = createActionButton(Header, "DONE", Color3.fromRGB(185, 61, 61))
DoneButton.AnchorPoint = Vector2.new(1, 0)
DoneButton.Position = UDim2.new(1, 0, 0, 0)
DoneButton.Size = UDim2.new(0, 84, 0, 30)

local StatusLabel = Instance.new("TextLabel")
StatusLabel.Name = "StatusLabel"
StatusLabel.Size = UDim2.new(1, 0, 0, 48)
StatusLabel.BackgroundColor3 = Color3.fromRGB(20, 24, 36)
StatusLabel.BackgroundTransparency = 0.08
StatusLabel.BorderSizePixel = 0
StatusLabel.Font = Enum.Font.GothamMedium
StatusLabel.TextColor3 = Color3.fromRGB(223, 231, 246)
StatusLabel.TextSize = 12
StatusLabel.TextWrapped = true
StatusLabel.TextXAlignment = Enum.TextXAlignment.Left
StatusLabel.TextYAlignment = Enum.TextYAlignment.Center
StatusLabel.LayoutOrder = 1
StatusLabel.Parent = Panel
Instance.new("UICorner", StatusLabel).CornerRadius = UDim.new(0, 10)
local StatusPadding = Instance.new("UIPadding")
StatusPadding.PaddingLeft = UDim.new(0, 12)
StatusPadding.PaddingRight = UDim.new(0, 12)
StatusPadding.Parent = StatusLabel

local ToolsLabel = createSectionLabel(2, "Tools")
local ToolsFrame = createSectionFrame(3, 74)
local ToolsGrid = Instance.new("UIGridLayout")
ToolsGrid.CellSize = UDim2.new(0, 92, 0, 28)
ToolsGrid.CellPadding = UDim2.new(0, 6, 0, 6)
ToolsGrid.Parent = ToolsFrame

local ShapesLabel = createSectionLabel(4, "Shapes")
local ShapesFrame = createSectionFrame(5, 72)
local ShapesGrid = Instance.new("UIGridLayout")
ShapesGrid.CellSize = UDim2.new(0, 92, 0, 28)
ShapesGrid.CellPadding = UDim2.new(0, 6, 0, 6)
ShapesGrid.Parent = ShapesFrame

local ActionsLabel = createSectionLabel(6, "Actions")
local ActionsFrame = createSectionFrame(7, 110)
local ActionsGrid = Instance.new("UIGridLayout")
ActionsGrid.CellSize = UDim2.new(0, 144, 0, 30)
ActionsGrid.CellPadding = UDim2.new(0, 8, 0, 8)
ActionsGrid.Parent = ActionsFrame

local AxisLabel = createSectionLabel(8, "Scale Axis")
local AxisFrame = createSectionFrame(9, 38)
local AxisGrid = Instance.new("UIGridLayout")
AxisGrid.FillDirection = Enum.FillDirection.Horizontal
AxisGrid.CellSize = UDim2.new(0, 94, 0, 28)
AxisGrid.CellPadding = UDim2.new(0, 8, 0, 0)
AxisGrid.Parent = AxisFrame

local UtilityLabel = createSectionLabel(10, "Selected Piece")
local UtilityFrame = createSectionFrame(11, 72)
local UtilityGrid = Instance.new("UIGridLayout")
UtilityGrid.CellSize = UDim2.new(0, 144, 0, 28)
UtilityGrid.CellPadding = UDim2.new(0, 8, 0, 8)
UtilityGrid.Parent = UtilityFrame

local ColorsLabel = createSectionLabel(12, "Colors")
local ColorsFrame = createSectionFrame(13, 72)
local ColorGrid = Instance.new("UIGridLayout")
ColorGrid.CellSize = UDim2.new(0, 92, 0, 28)
ColorGrid.CellPadding = UDim2.new(0, 6, 0, 6)
ColorGrid.Parent = ColorsFrame

local MaterialsLabel = createSectionLabel(14, "Materials")
local MaterialsFrame = createSectionFrame(15, 68)
local MaterialGrid = Instance.new("UIGridLayout")
MaterialGrid.CellSize = UDim2.new(0, 144, 0, 24)
MaterialGrid.CellPadding = UDim2.new(0, 8, 0, 6)
MaterialGrid.Parent = MaterialsFrame


local MobilePrimaryButton = createActionButton(Gui, "PLACE HERE", Color3.fromRGB(92, 148, 255))
MobilePrimaryButton.AnchorPoint = Vector2.new(0.5, 1)
MobilePrimaryButton.Position = UDim2.new(0.5, 0, 1, -18)
MobilePrimaryButton.Size = UDim2.new(0, 220, 0, 48)
MobilePrimaryButton.Visible = false
MobilePrimaryButton.TextScaled = true
MobilePrimaryButton.ZIndex = 10

local TouchReticle = Instance.new("TextLabel")
TouchReticle.Name = "TouchReticle"
TouchReticle.AnchorPoint = Vector2.new(0.5, 0.5)
TouchReticle.Position = UDim2.new(0.5, 0, 0.5, 0)
TouchReticle.Size = UDim2.new(0, 36, 0, 36)
TouchReticle.BackgroundTransparency = 1
TouchReticle.Text = "+"
TouchReticle.TextColor3 = Color3.fromRGB(92, 148, 255)
TouchReticle.Font = Enum.Font.GothamBlack
TouchReticle.TextScaled = true
TouchReticle.TextStrokeTransparency = 0.35
TouchReticle.Visible = false
TouchReticle.ZIndex = 10
TouchReticle.Parent = Gui

local PaintPopup = Instance.new("Frame")
PaintPopup.Name = "PaintPopup"
PaintPopup.AnchorPoint = Vector2.new(1, 0)
PaintPopup.Position = UDim2.new(1, -338, 0, 120)
PaintPopup.Size = UDim2.new(0, 250, 0, 320)
PaintPopup.BackgroundColor3 = Color3.fromRGB(16, 20, 30)
PaintPopup.BackgroundTransparency = 0.05
PaintPopup.BorderSizePixel = 0
PaintPopup.Visible = false
PaintPopup.Parent = Gui
Instance.new("UICorner", PaintPopup).CornerRadius = UDim.new(0, 14)
local PaintPopupStroke = Instance.new("UIStroke")
PaintPopupStroke.Color = TOOL_COLORS.Paint
PaintPopupStroke.Transparency = 0.15
PaintPopupStroke.Thickness = 1.5
PaintPopupStroke.Parent = PaintPopup

local PaintTitle = Instance.new("TextLabel")
PaintTitle.BackgroundTransparency = 1
PaintTitle.Position = UDim2.new(0, 14, 0, 10)
PaintTitle.Size = UDim2.new(1, -28, 0, 18)
PaintTitle.Font = Enum.Font.GothamBold
PaintTitle.Text = "Color Picker"
PaintTitle.TextSize = 14
PaintTitle.TextColor3 = Color3.fromRGB(244, 247, 255)
PaintTitle.TextXAlignment = Enum.TextXAlignment.Left
PaintTitle.Parent = PaintPopup

local PaintHint = Instance.new("TextLabel")
PaintHint.BackgroundTransparency = 1
PaintHint.Position = UDim2.new(0, 14, 0, 30)
PaintHint.Size = UDim2.new(1, -28, 0, 24)
PaintHint.Font = Enum.Font.GothamMedium
PaintHint.Text = "Drag in the picker for any color. Material uses a dropdown."
PaintHint.TextWrapped = true
PaintHint.TextSize = 11
PaintHint.TextColor3 = Color3.fromRGB(184, 198, 225)
PaintHint.TextXAlignment = Enum.TextXAlignment.Left
PaintHint.Parent = PaintPopup

local ColorArea = Instance.new("Frame")
ColorArea.Name = "ColorArea"
ColorArea.Position = UDim2.new(0, 14, 0, 66)
ColorArea.Size = UDim2.new(0, 170, 0, 170)
ColorArea.BackgroundColor3 = Color3.fromRGB(255, 0, 0)
ColorArea.BorderSizePixel = 0
ColorArea.Active = true
ColorArea.Parent = PaintPopup
Instance.new("UICorner", ColorArea).CornerRadius = UDim.new(0, 10)

local ColorAreaWhite = Instance.new("Frame")
ColorAreaWhite.BackgroundColor3 = Color3.new(1, 1, 1)
ColorAreaWhite.BorderSizePixel = 0
ColorAreaWhite.Size = UDim2.new(1, 0, 1, 0)
ColorAreaWhite.Parent = ColorArea
Instance.new("UICorner", ColorAreaWhite).CornerRadius = UDim.new(0, 10)
local WhiteGradient = Instance.new("UIGradient")
WhiteGradient.Transparency = NumberSequence.new({
	NumberSequenceKeypoint.new(0, 0),
	NumberSequenceKeypoint.new(1, 1),
})
WhiteGradient.Rotation = 0
WhiteGradient.Parent = ColorAreaWhite

local ColorAreaBlack = Instance.new("Frame")
ColorAreaBlack.BackgroundColor3 = Color3.new(0, 0, 0)
ColorAreaBlack.BorderSizePixel = 0
ColorAreaBlack.Size = UDim2.new(1, 0, 1, 0)
ColorAreaBlack.Parent = ColorArea
Instance.new("UICorner", ColorAreaBlack).CornerRadius = UDim.new(0, 10)
local BlackGradient = Instance.new("UIGradient")
BlackGradient.Transparency = NumberSequence.new({
	NumberSequenceKeypoint.new(0, 1),
	NumberSequenceKeypoint.new(1, 0),
})
BlackGradient.Rotation = 90
BlackGradient.Parent = ColorAreaBlack

local ColorCursor = Instance.new("Frame")
ColorCursor.AnchorPoint = Vector2.new(0.5, 0.5)
ColorCursor.Size = UDim2.new(0, 14, 0, 14)
ColorCursor.BackgroundTransparency = 1
ColorCursor.Parent = ColorArea
local ColorCursorStroke = Instance.new("UIStroke")
ColorCursorStroke.Color = Color3.fromRGB(255, 255, 255)
ColorCursorStroke.Thickness = 2
ColorCursorStroke.Parent = ColorCursor
Instance.new("UICorner", ColorCursor).CornerRadius = UDim.new(1, 0)

local HueBar = Instance.new("Frame")
HueBar.Name = "HueBar"
HueBar.Position = UDim2.new(0, 194, 0, 66)
HueBar.Size = UDim2.new(0, 18, 0, 170)
HueBar.BorderSizePixel = 0
HueBar.Active = true
HueBar.Parent = PaintPopup
Instance.new("UICorner", HueBar).CornerRadius = UDim.new(0, 8)
local HueGradient = Instance.new("UIGradient")
HueGradient.Color = ColorSequence.new({
	ColorSequenceKeypoint.new(0.00, Color3.fromRGB(255, 0, 0)),
	ColorSequenceKeypoint.new(0.17, Color3.fromRGB(255, 255, 0)),
	ColorSequenceKeypoint.new(0.33, Color3.fromRGB(0, 255, 0)),
	ColorSequenceKeypoint.new(0.50, Color3.fromRGB(0, 255, 255)),
	ColorSequenceKeypoint.new(0.67, Color3.fromRGB(0, 0, 255)),
	ColorSequenceKeypoint.new(0.83, Color3.fromRGB(255, 0, 255)),
	ColorSequenceKeypoint.new(1.00, Color3.fromRGB(255, 0, 0)),
})
HueGradient.Rotation = 90
HueGradient.Parent = HueBar

local HueCursor = Instance.new("Frame")
HueCursor.AnchorPoint = Vector2.new(0.5, 0.5)
HueCursor.Size = UDim2.new(1, 6, 0, 6)
HueCursor.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
HueCursor.BorderSizePixel = 0
HueCursor.Parent = HueBar
Instance.new("UICorner", HueCursor).CornerRadius = UDim.new(1, 0)

local ColorPreview = Instance.new("Frame")
ColorPreview.Position = UDim2.new(0, 14, 0, 248)
ColorPreview.Size = UDim2.new(0, 32, 0, 32)
ColorPreview.BorderSizePixel = 0
ColorPreview.Parent = PaintPopup
Instance.new("UICorner", ColorPreview).CornerRadius = UDim.new(0, 8)

local MaterialDropdownButton = createActionButton(PaintPopup, "Material", Color3.fromRGB(30, 37, 52))
MaterialDropdownButton.Position = UDim2.new(0, 58, 0, 248)
MaterialDropdownButton.Size = UDim2.new(0, 154, 0, 32)
MaterialDropdownButton.TextXAlignment = Enum.TextXAlignment.Left

local MaterialDropdown = Instance.new("Frame")
MaterialDropdown.Position = UDim2.new(0, 58, 0, 286)
MaterialDropdown.Size = UDim2.new(0, 154, 0, 0)
MaterialDropdown.BackgroundColor3 = Color3.fromRGB(20, 24, 36)
MaterialDropdown.BackgroundTransparency = 0.02
MaterialDropdown.BorderSizePixel = 0
MaterialDropdown.Visible = false
MaterialDropdown.ClipsDescendants = true
MaterialDropdown.Parent = PaintPopup
Instance.new("UICorner", MaterialDropdown).CornerRadius = UDim.new(0, 10)
local MaterialDropdownLayout = Instance.new("UIListLayout")
MaterialDropdownLayout.Padding = UDim.new(0, 4)
MaterialDropdownLayout.Parent = MaterialDropdown
local MaterialDropdownPadding = Instance.new("UIPadding")
MaterialDropdownPadding.PaddingTop = UDim.new(0, 6)
MaterialDropdownPadding.PaddingBottom = UDim.new(0, 6)
MaterialDropdownPadding.PaddingLeft = UDim.new(0, 6)
MaterialDropdownPadding.PaddingRight = UDim.new(0, 6)
MaterialDropdownPadding.Parent = MaterialDropdown

local toolButtons = {}
local shapeButtons = {}
local axisButtons = {}
local colorButtons = {}
local materialButtons = {}
local utilityButtons = {}
local sectionRegistry = {}
local refreshShapeButtons

local function registerSection(label, frame)
	sectionRegistry[label] = {
		LabelHeight = label.Size.Y.Offset,
		FrameHeight = frame.Size.Y.Offset,
	}
end

local function setSectionVisible(label, frame, isVisible)
	local config = sectionRegistry[label]
	if not config then
		label.Visible = isVisible
		frame.Visible = isVisible
		return
	end
	label.Visible = isVisible
	frame.Visible = isVisible
	label.Size = UDim2.new(1, 0, 0, isVisible and config.LabelHeight or 0)
	frame.Size = UDim2.new(1, 0, 0, isVisible and config.FrameHeight or 0)
	label.TextTransparency = isVisible and 0 or 1
	frame.BackgroundTransparency = isVisible and 0.08 or 1
	frame.Active = isVisible
end

registerSection(ShapesLabel, ShapesFrame)
registerSection(AxisLabel, AxisFrame)
registerSection(UtilityLabel, UtilityFrame)
registerSection(ColorsLabel, ColorsFrame)
registerSection(MaterialsLabel, MaterialsFrame)

local function updatePreviewGhostAppearance()
	if not previewGhost then
		return
	end
	for _, part in ipairs(previewGhost:GetDescendants()) do
		if part:IsA("BasePart") then
			part.Transparency = 0.45
			part.CanCollide = false
			part.Color = selectedColor
			part.Material = Enum.Material.ForceField
		end
	end
end

local function clearPreviewGhost()
	if previewGhost then
		previewGhost:Destroy()
		previewGhost = nil
	end
	currentPlacementRotation = 0
end

local function createPreviewGhost(itemName)
	clearPreviewGhost()
	currentShapeItemName = itemName
	previewGhost = CustomBuildingConfig.CreateModel(itemName)
	updatePreviewGhostAppearance()
	previewGhost.Parent = workspace
	refreshShapeButtons()
end

local function updateGizmos()
	local adornee = selectedModel and selectedModel.Parent and CustomBuildingConfig.GetBasePart(selectedModel) or nil
	local showDesktopGizmos = isBuilderOpen and not isTouchBuilder() and adornee ~= nil
	MoveHandles.Adornee = showDesktopGizmos and activeTool == "Move" and adornee or nil
	MoveHandles.Visible = showDesktopGizmos and activeTool == "Move"
	ScaleHandles.Adornee = showDesktopGizmos and activeTool == "Scale" and adornee or nil
	ScaleHandles.Visible = showDesktopGizmos and activeTool == "Scale"
	RotateHandles.Adornee = showDesktopGizmos and activeTool == "Rotate" and adornee or nil
	RotateHandles.Visible = showDesktopGizmos and activeTool == "Rotate"
end

local function refreshPaintPopup()
	local showPopup = isBuilderOpen and activeTool == "Paint"
	PaintPopup.Visible = showPopup
	if not showPopup then
		materialDropdownOpen = false
		MaterialDropdown.Visible = false
		MaterialDropdown.Size = UDim2.new(0, 154, 0, 0)
		return
	end
	if isTouchBuilder() then
		PaintPopup.AnchorPoint = Vector2.new(0, 0)
		PaintPopup.Position = UDim2.new(0, 12, 0, 396)
	else
		PaintPopup.AnchorPoint = Vector2.new(1, 0)
		PaintPopup.Position = UDim2.new(1, -338, 0, 120)
	end
	ColorArea.BackgroundColor3 = Color3.fromHSV(hsvHue, 1, 1)
	ColorCursor.Position = UDim2.new(hsvSaturation, 0, 1 - hsvValue, 0)
	HueCursor.Position = UDim2.new(0.5, 0, hsvHue, 0)
	ColorPreview.BackgroundColor3 = selectedColor
	MaterialDropdownButton.Text = "Material: " .. selectedMaterial
	MaterialDropdown.Visible = materialDropdownOpen
	MaterialDropdown.Size = UDim2.new(0, 154, 0, materialDropdownOpen and (8 + (#materialButtons * 28)) or 0)
	for _, entry in ipairs(materialButtons) do
		entry.Button.BackgroundColor3 = entry.Material == selectedMaterial and TOOL_COLORS.Paint or Color3.fromRGB(30, 37, 52)
	end
end

local function refreshPaletteVisuals()
	updatePreviewGhostAppearance()
	refreshPaintPopup()
	updateGizmos()
end

local function refreshToolButtons()
	for toolName, button in pairs(toolButtons) do
		button.BackgroundColor3 = toolName == activeTool and (TOOL_COLORS[toolName] or Color3.fromRGB(92, 148, 255)) or Color3.fromRGB(30, 37, 52)
	end
	TouchReticle.TextColor3 = TOOL_COLORS[activeTool] or Color3.fromRGB(92, 148, 255)
	refreshPaintPopup()
	updateGizmos()
end

refreshShapeButtons = function()
	for _, entry in ipairs(shapeButtons) do
		entry.Button.BackgroundColor3 = entry.ItemName == currentShapeItemName and Color3.fromRGB(92, 148, 255) or Color3.fromRGB(30, 37, 52)
		entry.Button.TextColor3 = Color3.fromRGB(245, 247, 255)
		if entry.ItemName == currentShapeItemName and activeTool == "Place" then
			entry.Button.TextColor3 = Color3.fromRGB(255, 255, 255)
		end
	end
end

local function refreshAxisButtons()
	for axisName, button in pairs(axisButtons) do
		button.BackgroundColor3 = axisName == selectedAxis and Color3.fromRGB(92, 148, 255) or Color3.fromRGB(30, 37, 52)
	end
end

local function setSelection(model)
	selectedModel = model and model.Parent and model or nil
	if selectedModel then
		local state = CustomBuildingConfig.ReadState(selectedModel)
		selectedColor = state.Color
		selectedMaterial = state.Material
		hsvHue, hsvSaturation, hsvValue = Color3.toHSV(selectedColor)
	end
	materialDropdownOpen = false
	refreshPaletteVisuals()
end

local function commitSelected(immediate)
	if not selectedModel or not selectedModel.Parent then
		return
	end
	pendingCommitToken += 1
	local token = pendingCommitToken
	local function send()
		if token ~= pendingCommitToken or not selectedModel or not selectedModel.Parent then
			return
		end
		local ok, result = pcall(function()
			return CustomBuildRequest:InvokeServer("Apply", selectedModel, CustomBuildingConfig.ReadState(selectedModel))
		end)
		if ok and type(result) == "table" and result.success and result.state and selectedModel and selectedModel.Parent then
			CustomBuildingConfig.ApplyState(selectedModel, result.state)
		end
	end
	if immediate then
		send()
	else
		task.delay(0.12, send)
	end
end

local function applySelectedState(nextState, immediate)
	if not selectedModel or not selectedModel.Parent then
		return
	end
	CustomBuildingConfig.ApplyState(selectedModel, nextState)
	commitSelected(immediate)
end

local function selectHoveredModel()
	if hoveredModel and hoveredModel.Parent then
		setSelection(hoveredModel)
		return true
	end
	setSelection(nil)
	return false
end

local function previewPaintSelection()
	if not selectedModel or not selectedModel.Parent then
		refreshPaletteVisuals()
		return
	end
	local state = CustomBuildingConfig.ReadState(selectedModel)
	state.Color = selectedColor
	state.Material = selectedMaterial
	CustomBuildingConfig.ApplyState(selectedModel, state)
	refreshPaletteVisuals()
end

local function paintSelected()
	if not selectedModel or not selectedModel.Parent then
		refreshPaletteVisuals()
		return
	end
	previewPaintSelection()
	pendingPaintToken += 1
	local token = pendingPaintToken
	task.delay(0.05, function()
		if token ~= pendingPaintToken or not selectedModel or not selectedModel.Parent then
			return
		end
		local ok, result = pcall(function()
			return CustomBuildRequest:InvokeServer("Paint", selectedModel, {
				Color = selectedColor,
				Material = selectedMaterial,
			})
		end)
		if ok and type(result) == "table" and result.success and result.state and selectedModel and selectedModel.Parent then
			CustomBuildingConfig.ApplyState(selectedModel, result.state)
		end
		refreshPaletteVisuals()
	end)
end

local function duplicateSelected(useMirror)
	if not selectedModel or not selectedModel.Parent then
		return
	end
	commitSelected(true)
	local currentState = CustomBuildingConfig.ReadState(selectedModel)
	local nextState = CustomBuildingConfig.GetDuplicateState(selectedModel.Name, currentState, selectedAxis, 1, useMirror == true)
	nextState.Color = selectedColor
	nextState.Material = selectedMaterial
	local ok, result = pcall(function()
		return RequestPlaceItem:InvokeServer(CustomBuildingConfig.BuildPlacementPayload(selectedModel.Name, nextState))
	end)
	if ok and type(result) == "table" and result.success and result.uuid then
		task.delay(0.15, function()
			local model = findModelByUuid(result.uuid)
			if model then
				setSelection(model)
			end
		end)
	end
end

local function deleteSelected()
	if not selectedModel or not selectedModel.Parent then
		return
	end
	pcall(function()
		RequestRemoveItem:InvokeServer(selectedModel)
	end)
	setSelection(nil)
end

local function moveSelectedToHit(hitPosition)
	if not selectedModel or not selectedModel.Parent or not hitPosition then
		return
	end
	local state = CustomBuildingConfig.ReadState(selectedModel)
	state.Position = alignPositionToSurface(selectedModel, hitPosition)
	applySelectedState(state, true)
end

local function moveSelectedToCurrentHit()
	if not lastRayResult then
		return
	end
	moveSelectedToHit(lastRayResult.Position)
end

local function raiseSelected(direction)
	if not selectedModel or not selectedModel.Parent then
		return
	end
	local step = CustomBuildingConfig.DEFAULT_STEP * (direction or 1)
	local state = CustomBuildingConfig.ReadState(selectedModel)
	state.Position = CustomBuildingConfig.SnapVector3(state.Position + Vector3.new(0, step, 0))
	applySelectedState(state, true)
end

local function groundSelected()
	if not selectedModel or not selectedModel.Parent then
		return
	end
	local state = CustomBuildingConfig.ReadState(selectedModel)
	local rayResult = workspace:Raycast(Vector3.new(state.Position.X, math.max(state.Position.Y + 256, 512), state.Position.Z), Vector3.new(0, -1024, 0), TerrainRayParams)
	if not rayResult then
		return
	end
	state.Position = alignPositionToSurface(selectedModel, rayResult.Position)
	applySelectedState(state, true)
end

local function scaleSelected(direction)
	if not selectedModel or not selectedModel.Parent then
		return
	end
	local step = CustomBuildingConfig.DEFAULT_STEP * (direction > 0 and 1 or -1)
	local state = CustomBuildingConfig.ReadState(selectedModel)
	local size = state.Size
	if selectedAxis == "X" then
		size = Vector3.new(size.X + step, size.Y, size.Z)
	elseif selectedAxis == "Y" then
		size = Vector3.new(size.X, size.Y + step, size.Z)
	else
		size = Vector3.new(size.X, size.Y, size.Z + step)
	end
	state.Size = CustomBuildingConfig.ClampSize(size)
	applySelectedState(state, true)
end

local function rotateCurrent(direction)
	local rotationStep = CustomBuildingConfig.ROTATION_SNAP * (direction > 0 and 1 or -1)
	if previewGhost then
		currentPlacementRotation += rotationStep
		return
	end
	if not selectedModel or not selectedModel.Parent then
		return
	end
	local state = CustomBuildingConfig.ReadState(selectedModel)
	state.Yaw += rotationStep
	applySelectedState(state, true)
end

local function cloneState(state)
	return {
		Position = state.Position,
		Yaw = state.Yaw,
		Size = state.Size,
		Color = state.Color,
		Material = state.Material,
		Shape = state.Shape,
	}
end

local function beginHandleDrag(normalId)
	if not selectedModel or not selectedModel.Parent then
		return nil
	end
	handleDragging = true
	dragFromSelection = false
	handleDragState = CustomBuildingConfig.ReadState(selectedModel)
	if normalId then
		selectedAxis = normalIdToAxis(normalId)
	end
	refreshAxisButtons()
	return handleDragState
end

local function endHandleDrag()
	if handleDragging then
		commitSelected(true)
	end
	handleDragging = false
	handleDragState = nil
end

local function getHandleWorldDirection(normalId, state)
	local baseYaw = state and state.Yaw or 0
	local basis = CFrame.Angles(0, math.rad(CustomBuildingConfig.SnapYaw(baseYaw)), 0)
	return basis:VectorToWorldSpace(normalIdToLocalDirection(normalId))
end

MoveHandles.MouseButton1Down:Connect(function(normalId)
	beginHandleDrag(normalId)
end)
MoveHandles.MouseDrag:Connect(function(normalId, distance)
	if not handleDragState or not selectedModel or not selectedModel.Parent then
		return
	end
	local nextState = cloneState(handleDragState)
	nextState.Position = CustomBuildingConfig.SnapVector3(handleDragState.Position + (getHandleWorldDirection(normalId, handleDragState) * distance))
	CustomBuildingConfig.ApplyState(selectedModel, nextState)
	commitSelected(false)
end)
MoveHandles.MouseButton1Up:Connect(endHandleDrag)

ScaleHandles.MouseButton1Down:Connect(function(normalId)
	beginHandleDrag(normalId)
end)
ScaleHandles.MouseDrag:Connect(function(normalId, distance)
	if not handleDragState or not selectedModel or not selectedModel.Parent then
		return
	end
	local nextState = cloneState(handleDragState)
	local axisName = normalIdToAxis(normalId)
	local oldSize = handleDragState.Size
	local oldExtent = axisName == "X" and oldSize.X or (axisName == "Y" and oldSize.Y or oldSize.Z)
	local newExtent = math.clamp(CustomBuildingConfig.RoundToStep(oldExtent + distance), CustomBuildingConfig.MIN_SIZE, CustomBuildingConfig.MAX_SIZE)
	local actualDelta = newExtent - oldExtent
	if axisName == "X" then
		nextState.Size = Vector3.new(newExtent, oldSize.Y, oldSize.Z)
	elseif axisName == "Y" then
		nextState.Size = Vector3.new(oldSize.X, newExtent, oldSize.Z)
	else
		nextState.Size = Vector3.new(oldSize.X, oldSize.Y, newExtent)
	end
	local worldDirection = getHandleWorldDirection(normalId, handleDragState)
	nextState.Position = CustomBuildingConfig.SnapVector3(handleDragState.Position + (worldDirection * (actualDelta * 0.5)))
	CustomBuildingConfig.ApplyState(selectedModel, nextState)
	commitSelected(false)
end)
ScaleHandles.MouseButton1Up:Connect(endHandleDrag)

RotateHandles.MouseButton1Down:Connect(function()
	beginHandleDrag(Enum.NormalId.Top)
end)
RotateHandles.MouseDrag:Connect(function(axis, relativeAngle)
	if axis ~= Enum.Axis.Y or not handleDragState or not selectedModel or not selectedModel.Parent then
		return
	end
	local nextState = cloneState(handleDragState)
	nextState.Yaw = CustomBuildingConfig.SnapYaw(handleDragState.Yaw + math.deg(relativeAngle))
	CustomBuildingConfig.ApplyState(selectedModel, nextState)
	commitSelected(false)
end)
RotateHandles.MouseButton1Up:Connect(endHandleDrag)

local function placePreviewPiece()
	if not previewGhost or not currentShapeItemName then
		return
	end
	local state = CustomBuildingConfig.ReadState(previewGhost)
	state.Color = selectedColor
	state.Material = selectedMaterial
	local payload = CustomBuildingConfig.BuildPlacementPayload(currentShapeItemName, state)
	local ok, result = pcall(function()
		return RequestPlaceItem:InvokeServer(payload)
	end)
	if ok and type(result) == "table" and result.success then
		clearPreviewGhost()
		task.delay(0.15, function()
			if result.uuid then
				local model = findModelByUuid(result.uuid)
				if model then
					setSelection(model)
				end
			end
			if isBuilderOpen and activeTool == "Place" then
				createPreviewGhost(currentShapeItemName)
			end
		end)
	end
end

local function beginDragSelection()
	if isTouchBuilder() or activeTool == "Place" or not selectedModel or not selectedModel.Parent then
		return
	end
	dragging = true
	dragFromSelection = true
	local state = CustomBuildingConfig.ReadState(selectedModel)
	dragPlaneY = state.Position.Y
	local planeHit = getPlaneHit(dragPlaneY)
	dragOffset = planeHit and (state.Position - planeHit) or Vector3.zero
end

local function setTool(toolName)
	if activeTool == toolName then
		return
	end
	activeTool = toolName
	dragging = false
	materialDropdownOpen = false
	if activeTool ~= "Place" then
		clearPreviewGhost()
	elseif not previewGhost then
		createPreviewGhost(currentShapeItemName)
	end
	refreshToolButtons()
	refreshShapeButtons()
end

local function createToolButton(toolName)
	local button = createActionButton(ToolsFrame, toolName, Color3.fromRGB(30, 37, 52))
	button.MouseButton1Click:Connect(function()
		setTool(toolName)
	end)
	toolButtons[toolName] = button
end

for _, toolName in ipairs(TOOLS) do
	createToolButton(toolName)
end

for _, itemName in ipairs(CustomBuildingConfig.GetItemNames()) do
	local button = createActionButton(ShapesFrame, CustomBuildingConfig.GetShapeLabel(itemName), Color3.fromRGB(30, 37, 52))
	button.MouseButton1Click:Connect(function()
		currentShapeItemName = itemName
		refreshShapeButtons()
		if activeTool == "Place" then
			createPreviewGhost(itemName)
		end
	end)
	table.insert(shapeButtons, { Button = button, ItemName = itemName })
end

axisButtons.X = createActionButton(AxisFrame, "Width", Color3.fromRGB(92, 148, 255))
axisButtons.Y = createActionButton(AxisFrame, "Height", Color3.fromRGB(30, 37, 52))
axisButtons.Z = createActionButton(AxisFrame, "Depth", Color3.fromRGB(30, 37, 52))
for axisName, button in pairs(axisButtons) do
	button.MouseButton1Click:Connect(function()
		selectedAxis = axisName
		refreshAxisButtons()
	end)
end

utilityButtons.Duplicate = createActionButton(UtilityFrame, "Duplicate", Color3.fromRGB(25, 90, 68))
utilityButtons.Duplicate.MouseButton1Click:Connect(function()
	duplicateSelected(false)
end)
utilityButtons.Mirror = createActionButton(UtilityFrame, "Mirror Copy", Color3.fromRGB(72, 58, 118))
utilityButtons.Mirror.MouseButton1Click:Connect(function()
	duplicateSelected(true)
end)
utilityButtons.Ground = createActionButton(UtilityFrame, "Ground", Color3.fromRGB(72, 58, 118))
utilityButtons.Ground.MouseButton1Click:Connect(function()
	groundSelected()
end)
utilityButtons.Delete = createActionButton(UtilityFrame, "Delete", Color3.fromRGB(170, 60, 60))
utilityButtons.Delete.MouseButton1Click:Connect(function()
	deleteSelected()
end)

for _, swatch in ipairs(CustomBuildingConfig.PALETTE_COLORS) do
	local button = createActionButton(ColorsFrame, swatch.Name, swatch.Color)
	button.TextColor3 = swatch.Color:Lerp(Color3.new(0, 0, 0), 0.72)
	local stroke = Instance.new("UIStroke")
	stroke.Transparency = 1
	stroke.Parent = button
	button.MouseButton1Click:Connect(function()
		selectedColor = swatch.Color
		refreshPaletteVisuals()
		if activeTool == "Paint" then
			paintSelected()
		end
	end)
	table.insert(colorButtons, { Button = button, Color = swatch.Color })
end

for _, materialName in ipairs(CustomBuildingConfig.PALETTE_MATERIALS) do
	local button = createActionButton(MaterialsFrame, materialName, Color3.fromRGB(30, 37, 52))
	local stroke = Instance.new("UIStroke")
	stroke.Transparency = 1
	stroke.Parent = button
	button.MouseButton1Click:Connect(function()
		selectedMaterial = materialName
		refreshPaletteVisuals()
		if activeTool == "Paint" then
			paintSelected()
		end
	end)
	table.insert(materialButtons, { Button = button, Material = materialName })
end

for _, entry in ipairs(colorButtons) do
	entry.Button.Visible = false
end
colorButtons = {}

for _, entry in ipairs(materialButtons) do
	entry.Button.Visible = false
end
materialButtons = {}

for _, materialName in ipairs(CustomBuildingConfig.PALETTE_MATERIALS) do
	local button = createActionButton(MaterialDropdown, materialName, Color3.fromRGB(30, 37, 52))
	button.Size = UDim2.new(1, 0, 0, 24)
	button.TextXAlignment = Enum.TextXAlignment.Left
	button.MouseButton1Click:Connect(function()
		selectedMaterial = materialName
		materialDropdownOpen = false
		refreshPaletteVisuals()
		if activeTool == "Paint" then
			paintSelected()
		end
	end)
	table.insert(materialButtons, { Button = button, Material = materialName })
end

MaterialDropdownButton.MouseButton1Click:Connect(function()
	materialDropdownOpen = not materialDropdownOpen
	refreshPaletteVisuals()
end)

local function setColorFromHSV(h, s, v, shouldCommit)
	hsvHue = math.clamp(h, 0, 1)
	hsvSaturation = math.clamp(s, 0, 1)
	hsvValue = math.clamp(v, 0, 1)
	selectedColor = Color3.fromHSV(hsvHue, hsvSaturation, hsvValue)
	previewPaintSelection()
	if shouldCommit then
		paintSelected()
	else
		refreshPaletteVisuals()
	end
end

local function updateColorAreaFromPoint(point, shouldCommit)
	local relativeX = math.clamp((point.X - ColorArea.AbsolutePosition.X) / math.max(ColorArea.AbsoluteSize.X, 1), 0, 1)
	local relativeY = math.clamp((point.Y - ColorArea.AbsolutePosition.Y) / math.max(ColorArea.AbsoluteSize.Y, 1), 0, 1)
	setColorFromHSV(hsvHue, relativeX, 1 - relativeY, shouldCommit)
end

local function updateHueFromPoint(point, shouldCommit)
	local relativeY = math.clamp((point.Y - HueBar.AbsolutePosition.Y) / math.max(HueBar.AbsoluteSize.Y, 1), 0, 1)
	setColorFromHSV(relativeY, hsvSaturation, hsvValue, shouldCommit)
end

ColorArea.InputBegan:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
		pickingColorArea = true
		updateColorAreaFromPoint(input.Position, false)
	end
end)

HueBar.InputBegan:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
		pickingHue = true
		updateHueFromPoint(input.Position, false)
	end
end)

local function createToolAction(text, color, callback)
	local button = createActionButton(ActionsFrame, text, color)
	button.MouseButton1Click:Connect(callback)
	return button
end

local function rebuildActionButtons()
	for _, child in ipairs(ActionsFrame:GetChildren()) do
		if not child:IsA("UIGridLayout") then
			child:Destroy()
		end
	end

	local hasSelection = selectedModel and selectedModel.Parent ~= nil
	local touchMode = isTouchBuilder()
	if activeTool == "Place" then
		createToolAction("Place Here", TOOL_COLORS.Place, placePreviewPiece)
		createToolAction("Rotate -", Color3.fromRGB(30, 37, 52), function() rotateCurrent(-1) end)
		createToolAction("Rotate +", Color3.fromRGB(30, 37, 52), function() rotateCurrent(1) end)
		createToolAction("Cancel Preview", Color3.fromRGB(80, 60, 60), clearPreviewGhost)
		return
	end

	if not hasSelection then
		createToolAction("Select Looking At", TOOL_COLORS.Select, selectHoveredModel)
		createToolAction("Clear Selection", Color3.fromRGB(30, 37, 52), function() setSelection(nil) end)
		return
	end

	if activeTool == "Select" then
		createToolAction("Select Looking At", TOOL_COLORS.Select, selectHoveredModel)
		createToolAction("Clear Selection", Color3.fromRGB(30, 37, 52), function() setSelection(nil) end)
	elseif activeTool == "Move" then
		createToolAction("Ground", Color3.fromRGB(72, 58, 118), groundSelected)
		if touchMode then
			createToolAction("Move Here", TOOL_COLORS.Move, moveSelectedToCurrentHit)
			createToolAction("Raise", Color3.fromRGB(30, 37, 52), function() raiseSelected(1) end)
			createToolAction("Lower", Color3.fromRGB(30, 37, 52), function() raiseSelected(-1) end)
		end
	elseif activeTool == "Scale" then
		if touchMode then
			createToolAction("Shrink", TOOL_COLORS.Scale, function() scaleSelected(-1) end)
			createToolAction("Grow", TOOL_COLORS.Scale, function() scaleSelected(1) end)
		end
	elseif activeTool == "Rotate" then
		if touchMode then
			createToolAction("Rotate -", TOOL_COLORS.Rotate, function() rotateCurrent(-1) end)
			createToolAction("Rotate +", TOOL_COLORS.Rotate, function() rotateCurrent(1) end)
		end
	elseif activeTool == "Paint" then
		createToolAction("Select Looking At", TOOL_COLORS.Select, selectHoveredModel)
		if touchMode then
			createToolAction("Apply Paint", TOOL_COLORS.Paint, paintSelected)
		end
	end
end

local function refreshSectionVisibility()
	local hasSelection = selectedModel and selectedModel.Parent ~= nil
	setSectionVisible(ShapesLabel, ShapesFrame, activeTool == "Place")
	setSectionVisible(AxisLabel, AxisFrame, false)
	setSectionVisible(UtilityLabel, UtilityFrame, hasSelection)
	setSectionVisible(ColorsLabel, ColorsFrame, false)
	setSectionVisible(MaterialsLabel, MaterialsFrame, false)
	refreshAxisButtons()
	refreshShapeButtons()
	refreshPaintPopup()
	local actionKey = table.concat({activeTool, hasSelection and "1" or "0", previewGhost and "1" or "0", isTouchBuilder() and "touch" or "desktop"}, ":")
	if actionKey ~= lastActionKey then
		lastActionKey = actionKey
		rebuildActionButtons()
	end
end

local function refreshMobileControls()
	local touchMode = isTouchBuilder() and isBuilderOpen
	TouchReticle.Visible = touchMode
	if not touchMode then
		MobilePrimaryButton.Visible = false
		return
	end
	if activeTool == "Place" then
		MobilePrimaryButton.Visible = previewGhost ~= nil
		MobilePrimaryButton.Text = previewGhost and "PLACE HERE" or "CHOOSE SHAPE"
		MobilePrimaryButton.BackgroundColor3 = TOOL_COLORS.Place
	elseif activeTool == "Select" then
		MobilePrimaryButton.Visible = true
		MobilePrimaryButton.Text = "SELECT TARGET"
		MobilePrimaryButton.BackgroundColor3 = TOOL_COLORS.Select
	elseif activeTool == "Move" then
		MobilePrimaryButton.Visible = selectedModel ~= nil
		MobilePrimaryButton.Text = "MOVE HERE"
		MobilePrimaryButton.BackgroundColor3 = TOOL_COLORS.Move
	elseif activeTool == "Paint" then
		MobilePrimaryButton.Visible = hoveredModel ~= nil or selectedModel ~= nil
		MobilePrimaryButton.Text = "PAINT TARGET"
		MobilePrimaryButton.BackgroundColor3 = TOOL_COLORS.Paint
	else
		MobilePrimaryButton.Visible = false
	end
end

local function refreshPlatformLayout()
	local camera = workspace.CurrentCamera
	local viewport = camera and camera.ViewportSize or Vector2.new(1280, 720)
	lastViewportSize = viewport
	if isTouchBuilder() then
		Panel.AnchorPoint = Vector2.new(0, 0)
		Panel.Position = UDim2.new(0, 12, 0, 90)
		Panel.Size = UDim2.new(0, math.clamp(viewport.X - 24, 260, 300), 0, 292)
		Panel.ScrollBarThickness = 5
		Panel.ScrollingEnabled = true
		PaintPopup.Size = UDim2.new(0, math.clamp(viewport.X - 24, 260, 300), 0, 320)
		StatusLabel.Size = UDim2.new(1, 0, 0, 56)
		ActionsGrid.CellSize = UDim2.new(0, 126, 0, 30)
		AxisGrid.CellSize = UDim2.new(0, 82, 0, 28)
		UtilityGrid.CellSize = UDim2.new(0, 126, 0, 28)
		ColorGrid.CellSize = UDim2.new(0, 82, 0, 28)
		MaterialGrid.CellSize = UDim2.new(0, 126, 0, 24)
	else
		Panel.AnchorPoint = Vector2.new(1, 0)
		Panel.Position = UDim2.new(1, -18, 0, 120)
		Panel.Size = UDim2.new(0, 310, 0, 348)
		Panel.ScrollBarThickness = 0
		Panel.ScrollingEnabled = false
		PaintPopup.Size = UDim2.new(0, 250, 0, 320)
		StatusLabel.Size = UDim2.new(1, 0, 0, 48)
		ActionsGrid.CellSize = UDim2.new(0, 134, 0, 30)
		AxisGrid.CellSize = UDim2.new(0, 86, 0, 28)
		UtilityGrid.CellSize = UDim2.new(0, 134, 0, 28)
		ColorGrid.CellSize = UDim2.new(0, 86, 0, 28)
		MaterialGrid.CellSize = UDim2.new(0, 134, 0, 24)
	end
	refreshPaintPopup()
	refreshMobileControls()
end

local function refreshStatus()
	local currentShapeLabel = CustomBuildingConfig.GetShapeLabel(currentShapeItemName)
	local lines = {}
	if activeTool == "Place" then
		table.insert(lines, string.format("Place mode. Shape: %s.", currentShapeLabel))
		table.insert(lines, isTouchBuilder() and "Aim with the center reticle and tap PLACE HERE." or "Click in the world to place. WASD/QE move the camera. Mouse wheel zooms the camera only.")
	elseif activeTool == "Select" then
		table.insert(lines, selectedModel and ("Selected: " .. selectedModel.Name) or "Select mode.")
		table.insert(lines, isTouchBuilder() and "Aim at one of your pieces and tap SELECT TARGET." or "Click one of your pieces to select it, then drag it directly in the world.")
	elseif activeTool == "Move" then
		table.insert(lines, selectedModel and ("Moving: " .. selectedModel.Name) or "Move mode.")
		table.insert(lines, isTouchBuilder() and "Aim where it should go, then tap MOVE HERE." or "Use the green move gizmo or drag the selected piece directly with the mouse.")
	elseif activeTool == "Scale" then
		local axisLabel = selectedAxis == "X" and "Width" or (selectedAxis == "Y" and "Height" or "Depth")
		table.insert(lines, selectedModel and ("Scale mode. Axis: " .. axisLabel .. ".") or "Scale mode.")
		table.insert(lines, isTouchBuilder() and "Use Grow or Shrink on mobile." or "Use the orange resize gizmo. Mouse wheel never scales blocks.")
	elseif activeTool == "Rotate" then
		table.insert(lines, selectedModel and ("Rotate mode. Selected: " .. selectedModel.Name) or "Rotate mode.")
		table.insert(lines, isTouchBuilder() and "Use Rotate - and Rotate + for clean 15 degree steps." or "Use the purple rotation ring. Rotation still saves as upright yaw only.")
	else
		table.insert(lines, selectedModel and ("Paint mode. Selected: " .. selectedModel.Name) or "Paint mode.")
		table.insert(lines, isTouchBuilder() and "Pick a color/material and it applies to the selected piece." or "Use the full color picker and material dropdown in the paint panel.")
	end
	local text = table.concat(lines, "\n")
	if text ~= lastStatusText then
		lastStatusText = text
		StatusLabel.Text = text
	end
end

local function isPointerOverBuilderUi()
	if not Gui.Enabled or isTouchBuilder() then
		return false
	end
	local point = UserInputService:GetMouseLocation()
	return pointInside(Panel, point) or pointInside(PaintPopup, point) or pointInside(MobilePrimaryButton, point)
end

local function closeBuilder(reopenBuild)
	releaseFocusedTextBox()
	if selectedModel and selectedModel.Parent then
		commitSelected(true)
	end
	dragging = false
	handleDragging = false
	pickingColorArea = false
	pickingHue = false
	materialDropdownOpen = false
	setSelection(nil)
	hoveredModel = nil
	Highlight.Adornee = nil
	clearPreviewGhost()
	Gui.Enabled = false
	PaintPopup.Visible = false
	MoveHandles.Visible = false
	MoveHandles.Adornee = nil
	ScaleHandles.Visible = false
	ScaleHandles.Adornee = nil
	RotateHandles.Visible = false
	RotateHandles.Adornee = nil
	isBuilderOpen = false
	ModeState.Value = ""
	disableFreecam()
	MobilePrimaryButton.Visible = false
	TouchReticle.Visible = false
	if reopenBuild and openedFromButton then
		BuildFrame.Visible = true
	end
	openedFromButton = false
end

local function openBuilder(fromButton)
	releaseFocusedTextBox()
	if not isBuilderOpen and ModeState.Value ~= "" and ModeState.Value ~= "Builder" then
		return
	end
	openedFromButton = fromButton == true or BuildFrame.Visible
	isBuilderOpen = true
	activeTool = "Place"
	selectedAxis = "X"
	currentShapeItemName = CustomBuildingConfig.ITEM_NAME
	materialDropdownOpen = false
	lastActionKey = ""
	setSelection(nil)
	Gui.Enabled = true
	ModeState.Value = "Builder"
	ClosePanels:Fire("Builder")
	BuildFrame.Visible = false
	Panel.CanvasPosition = Vector2.zero
	if wantsFreecam() then
		enableFreecam()
	else
		disableFreecam()
	end
	refreshPlatformLayout()
	refreshToolButtons()
	refreshShapeButtons()
	refreshAxisButtons()
	refreshPaletteVisuals()
	createPreviewGhost(currentShapeItemName)
	refreshSectionVisibility()
	refreshStatus()
end

DoneButton.MouseButton1Click:Connect(function()
	if isBuilderOpen then
		closeBuilder(true)
	end
end)

BuilderButton.MouseButton1Click:Connect(function()
	if isBuilderOpen then
		closeBuilder(true)
	else
		openBuilder(true)
	end
end)

ClosePanels.Event:Connect(function(source)
	if source == "Builder" then
		return
	end
	if isBuilderOpen then
		closeBuilder(false)
	end
end)

MobilePrimaryButton.MouseButton1Click:Connect(function()
	if not isBuilderOpen then
		return
	end
	if activeTool == "Place" then
		placePreviewPiece()
	elseif activeTool == "Select" then
		selectHoveredModel()
	elseif activeTool == "Move" then
		moveSelectedToCurrentHit()
	elseif activeTool == "Paint" then
		if hoveredModel and hoveredModel.Parent then
			setSelection(hoveredModel)
		end
		paintSelected()
	end
end)

RunService.RenderStepped:Connect(function(dt)
	if not isBuilderOpen then
		return
	end

	if workspace.CurrentCamera and workspace.CurrentCamera.ViewportSize ~= lastViewportSize then
		refreshPlatformLayout()
	end

	if wantsFreecam() then
		local controls = getControls()
		if controls and FreecamPart then
			local moveVector = controls:GetMoveVector()
			local orientationCF = CFrame.fromOrientation(freecamCameraPitch, freecamCameraYaw, 0)
			local look = Vector3.new(orientationCF.LookVector.X, 0, orientationCF.LookVector.Z)
			if look.Magnitude < 1e-3 then
				look = Vector3.new(0, 0, -1)
			else
				look = look.Unit
			end
			local right = Vector3.new(orientationCF.RightVector.X, 0, orientationCF.RightVector.Z)
			if right.Magnitude < 1e-3 then
				right = Vector3.new(1, 0, 0)
			else
				right = right.Unit
			end
			local vertical = 0
			if UserInputService:IsKeyDown(Enum.KeyCode.E) then
				vertical += 1
			end
			if UserInputService:IsKeyDown(Enum.KeyCode.Q) then
				vertical -= 1
			end
			local speed = 60
			local moveDirection = (look * -moveVector.Z) + (right * moveVector.X) + Vector3.new(0, vertical, 0)
			if moveDirection.Magnitude > 0 then
				FreecamPart.Position += moveDirection * speed * dt
			end
			updateBuilderFreecamCamera()
		end
	end

	if selectedModel and not selectedModel.Parent then
		setSelection(nil)
	end

	lastRayResult = getRayResult()
	if not dragging then
		hoveredModel = lastRayResult and lastRayResult.Instance and findCustomBlockModel(lastRayResult.Instance) or nil
	end
	Highlight.Adornee = selectedModel or hoveredModel

	if previewGhost then
		local hitPosition = lastRayResult and lastRayResult.Position or (FreecamPart and FreecamPart.Position or (Player.Character and Player.Character:GetPivot().Position) or Vector3.zero)
		local aligned = alignPositionToSurface(previewGhost, hitPosition)
		if aligned then
			previewGhost:PivotTo(CustomBuildingConfig.BuildCFrame(aligned, currentPlacementRotation))
		end
		updatePreviewGhostAppearance()
	end

	if dragging and selectedModel and selectedModel.Parent and not isTouchBuilder() then
		local planeHit = getPlaneHit(dragPlaneY)
		if planeHit then
			local state = CustomBuildingConfig.ReadState(selectedModel)
			state.Position = CustomBuildingConfig.SnapVector3(planeHit + dragOffset)
			CustomBuildingConfig.ApplyState(selectedModel, state)
		end
	end

	refreshSectionVisibility()
	refreshStatus()
	refreshMobileControls()
end)

UserInputService.InputBegan:Connect(function(input, gameProcessed)
	if gameProcessed or not isBuilderOpen then
		return
	end

	if input.KeyCode == Enum.KeyCode.Escape then
		closeBuilder(true)
		return
	end

	if isTouchBuilder() then
		return
	end

	if input.UserInputType == Enum.UserInputType.MouseButton2 and FreecamPart and not isPointerOverBuilderUi() then
		freecamRotateActive = true
		UserInputService.MouseBehavior = Enum.MouseBehavior.LockCurrentPosition
		UserInputService.MouseIconEnabled = false
		return
	end

	if input.UserInputType == Enum.UserInputType.MouseButton1 then
		if isPointerOverBuilderUi() then
			return
		end
		if activeTool == "Place" and previewGhost then
			placePreviewPiece()
			return
		end
		if hoveredModel then
			setSelection(hoveredModel)
			task.defer(function()
				if isBuilderOpen and not handleDragging and selectedModel and selectedModel.Parent and selectedModel == hoveredModel then
					beginDragSelection()
				end
			end)
		else
			setSelection(nil)
		end
	end
end)

UserInputService.InputChanged:Connect(function(input, gameProcessed)
	if not isBuilderOpen then
		return
	end
	if pickingColorArea and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
		updateColorAreaFromPoint(input.Position, false)
	end
	if pickingHue and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
		updateHueFromPoint(input.Position, false)
	end
	if input.UserInputType == Enum.UserInputType.MouseMovement and freecamRotateActive and FreecamPart then
		freecamCameraYaw -= input.Delta.X * FREECAM_ROTATE_SENSITIVITY
		freecamCameraPitch = math.clamp(freecamCameraPitch - (input.Delta.Y * FREECAM_ROTATE_SENSITIVITY), -math.rad(80), math.rad(80))
		updateBuilderFreecamCamera()
	end
	if gameProcessed or isTouchBuilder() then
		return
	end
	if input.UserInputType == Enum.UserInputType.MouseWheel and FreecamPart and not isPointerOverBuilderUi() then
		FreecamPart.Position += CFrame.fromOrientation(freecamCameraPitch, freecamCameraYaw, 0).LookVector * (input.Position.Z * 12)
		updateBuilderFreecamCamera()
	end
end)

UserInputService.InputEnded:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.MouseButton2 and freecamRotateActive then
		freecamRotateActive = false
		if not UserInputService:GetFocusedTextBox() then
			UserInputService.MouseBehavior = Enum.MouseBehavior.Default
			UserInputService.MouseIconEnabled = true
		end
	end
	if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
		local shouldCommitPaint = pickingColorArea or pickingHue
		pickingColorArea = false
		pickingHue = false
		if shouldCommitPaint and activeTool == "Paint" then
			paintSelected()
		end
	end
	if not dragging or not selectedModel or not selectedModel.Parent then
		return
	end
	if input.UserInputType == Enum.UserInputType.MouseButton1 then
		dragging = false
		dragFromSelection = false
		commitSelected(true)
	end
end)

refreshToolButtons()
refreshShapeButtons()
refreshAxisButtons()
refreshPaletteVisuals()
refreshPlatformLayout()
refreshSectionVisibility()
refreshStatus()
