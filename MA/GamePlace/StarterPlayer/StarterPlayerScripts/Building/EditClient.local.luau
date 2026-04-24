local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local ProximityPromptService = game:GetService("ProximityPromptService")
local RunService = game:GetService("RunService")

local Player = Players.LocalPlayer
local PlayerGui = Player:WaitForChild("PlayerGui")
local MainHUD = PlayerGui:WaitForChild("MainHUD")
local BuildFrame = MainHUD:WaitForChild("BuildFrame")
local EditButton = BuildFrame:WaitForChild("Buttons"):WaitForChild("Edit")

local Events = ReplicatedStorage:WaitForChild("Events")
local ClosePanels = Events:FindFirstChild("ClosePanels")
if not ClosePanels then
	ClosePanels = Instance.new("BindableEvent")
	ClosePanels.Name = "ClosePanels"
	ClosePanels.Parent = Events
end

local CustomBuildingConfig = require(ReplicatedStorage:WaitForChild("CustomBuildingConfig"))
local Config = require(ReplicatedStorage:WaitForChild("Config"))
local EditEvent = ReplicatedStorage:FindFirstChild("EditPoleEvent")
if not EditEvent or not EditEvent:IsA("RemoteEvent") then
	if EditEvent then
		EditEvent:Destroy()
	end
	EditEvent = Instance.new("RemoteEvent")
	EditEvent.Name = "EditPoleEvent"
	EditEvent.Parent = ReplicatedStorage
end
local CustomBuildRequest = Events:WaitForChild("CustomBuildRequest")
local RequestPlaceItem = Events:WaitForChild("RequestPlaceItem")

local DRAG_SENSITIVITY = 0.2
local TARGET_POLE = "Pole"
local DEBUG_POLE_EDIT = true
local POLE_EDIT_MIN_COMMIT_DISTANCE = 0.05

local function PoleDebug(message, ...)
	if not DEBUG_POLE_EDIT then return end
	warn(string.format("[PoleEditClient] %s", tostring(message)), ...)
end

local ModeState = PlayerGui:FindFirstChild("ModeState") or Instance.new("StringValue")
ModeState.Name = "ModeState"
ModeState.Parent = PlayerGui

local isEditing = false
local dragging = false
local openedFromButton = false
local hoveredModel = nil
local hoveredHandle = nil
local hoveredKind = nil
local selectedModel = nil
local selectedKind = nil
local originalPoleCFrame = nil
local originalPolePivotOffset = Vector3.zero
local dragStartPolePrimaryPos = nil
local originalBlockState = nil
local dragStartMouseY = 0
local dragStartPoleY = 0
local dragPlaneY = 0
local dragOffset = Vector3.zero
local activeAxis = "X"
local poleEditMode = "Vertical" -- "Vertical" or "Slide"
local poleSlideAxis = Vector3.xAxis
local pendingCommitToken = 0
local dragStartPos = nil
local dragStartPointOnLine = nil

local SelectButton, MoveButton, AxisButton, AdjustMinusButton, AdjustPlusButton, RotateLeftButton, RotateRightButton, MobileReticle
local setSelection
local updateHud

local Highlight = Instance.new("Highlight")
Highlight.Name = "EditHighlight"
Highlight.FillColor = Color3.fromRGB(255, 230, 50)
Highlight.OutlineColor = Color3.fromRGB(255, 255, 255)
Highlight.FillTransparency = 0.45
Highlight.OutlineTransparency = 0
Highlight.Parent = PlayerGui

local HudGui = Instance.new("ScreenGui")
HudGui.Name = "BuildEditHud"
HudGui.ResetOnSpawn = false
HudGui.Enabled = false
HudGui.Parent = PlayerGui

local Panel = Instance.new("Frame")
Panel.AnchorPoint = Vector2.new(0.5, 1)
Panel.Position = UDim2.new(0.5, 0, 1, -18)
Panel.Size = UDim2.new(0, 560, 0, 84)
Panel.BackgroundColor3 = Color3.fromRGB(16, 20, 30)
Panel.BackgroundTransparency = 0.08
Panel.BorderSizePixel = 0
Panel.Parent = HudGui
Instance.new("UICorner", Panel).CornerRadius = UDim.new(0, 12)
local PanelStroke = Instance.new("UIStroke")
PanelStroke.Color = Color3.fromRGB(92, 148, 255)
PanelStroke.Transparency = 0.15
PanelStroke.Thickness = 1.5
PanelStroke.Parent = Panel

local TitleLabel = Instance.new("TextLabel")
TitleLabel.BackgroundTransparency = 1
TitleLabel.Position = UDim2.new(0, 14, 0, 10)
TitleLabel.Size = UDim2.new(1, -100, 0, 22)
TitleLabel.Font = Enum.Font.GothamBold
TitleLabel.TextSize = 16
TitleLabel.TextColor3 = Color3.fromRGB(244, 247, 255)
TitleLabel.TextXAlignment = Enum.TextXAlignment.Left
TitleLabel.Parent = Panel

local HintLabel = Instance.new("TextLabel")
HintLabel.BackgroundTransparency = 1
HintLabel.Position = UDim2.new(0, 14, 0, 34)
HintLabel.Size = UDim2.new(1, -28, 0, 20)
HintLabel.Font = Enum.Font.GothamMedium
HintLabel.TextSize = 12
HintLabel.TextColor3 = Color3.fromRGB(198, 208, 227)
HintLabel.TextXAlignment = Enum.TextXAlignment.Left
HintLabel.TextWrapped = true
HintLabel.Parent = Panel

local SelectionLabel = Instance.new("TextLabel")
SelectionLabel.BackgroundTransparency = 1
SelectionLabel.Position = UDim2.new(0, 14, 0, 56)
SelectionLabel.Size = UDim2.new(1, -28, 0, 18)
SelectionLabel.Font = Enum.Font.GothamMedium
SelectionLabel.TextSize = 12
SelectionLabel.TextColor3 = Color3.fromRGB(133, 154, 191)
SelectionLabel.TextXAlignment = Enum.TextXAlignment.Left
SelectionLabel.Parent = Panel

local ExitButton = Instance.new("TextButton")
ExitButton.AnchorPoint = Vector2.new(1, 0)
ExitButton.Position = UDim2.new(1, -10, 0, 10)
ExitButton.Size = UDim2.new(0, 76, 0, 28)
ExitButton.BackgroundColor3 = Color3.fromRGB(185, 61, 61)
ExitButton.BorderSizePixel = 0
ExitButton.Font = Enum.Font.GothamBold
ExitButton.Text = "DONE"
ExitButton.TextSize = 12
ExitButton.TextColor3 = Color3.fromRGB(255, 255, 255)
ExitButton.Active = true
ExitButton.Selectable = true
ExitButton.AutoButtonColor = true
ExitButton.Parent = Panel
Instance.new("UICorner", ExitButton).CornerRadius = UDim.new(0, 8)

local ModeButton = Instance.new("TextButton")
ModeButton.AnchorPoint = Vector2.new(1, 0)
ModeButton.Position = UDim2.new(1, -94, 0, 10)
ModeButton.Size = UDim2.new(0, 96, 0, 28)
ModeButton.BackgroundColor3 = Color3.fromRGB(48, 103, 196)
ModeButton.BorderSizePixel = 0
ModeButton.Font = Enum.Font.GothamBold
ModeButton.Text = "MODE: VERT"
ModeButton.TextSize = 11
ModeButton.TextColor3 = Color3.fromRGB(255, 255, 255)
ModeButton.Parent = Panel
Instance.new("UICorner", ModeButton).CornerRadius = UDim.new(0, 8)

local function createMobileButton(name, text, parent)
	local button = Instance.new("TextButton")
	button.Name = name
	button.BackgroundColor3 = Color3.fromRGB(34, 45, 67)
	button.BorderSizePixel = 0
	button.Font = Enum.Font.GothamBold
	button.Text = text
	button.TextSize = 12
	button.TextColor3 = Color3.fromRGB(255, 255, 255)
	button.AutoButtonColor = true
	button.Parent = parent
	Instance.new("UICorner", button).CornerRadius = UDim.new(0, 8)
	return button
end

if UserInputService.TouchEnabled then
	Panel.Position = UDim2.new(0.5, 0, 1, -12)
	Panel.Size = UDim2.new(1, -20, 0, 178)
	TitleLabel.Size = UDim2.new(1, -102, 0, 24)
	HintLabel.Position = UDim2.new(0, 14, 0, 36)
	HintLabel.Size = UDim2.new(1, -28, 0, 34)
	SelectionLabel.Position = UDim2.new(0, 14, 0, 72)
	SelectionLabel.Size = UDim2.new(1, -28, 0, 18)

	local buttonGrid = Instance.new("Frame")
	buttonGrid.Name = "MobileButtons"
	buttonGrid.BackgroundTransparency = 1
	buttonGrid.Position = UDim2.new(0, 12, 1, -80)
	buttonGrid.Size = UDim2.new(1, -24, 0, 68)
	buttonGrid.Parent = Panel

	local layout = Instance.new("UIGridLayout")
	layout.CellPadding = UDim2.new(0, 8, 0, 8)
	layout.CellSize = UDim2.new(0.25, -6, 0, 30)
	layout.FillDirectionMaxCells = 4
	layout.Parent = buttonGrid

	SelectButton = createMobileButton("SelectButton", "SELECT", buttonGrid)
	MoveButton = createMobileButton("MoveButton", "MOVE", buttonGrid)
	AxisButton = createMobileButton("AxisButton", "AXIS X", buttonGrid)
	AdjustMinusButton = createMobileButton("AdjustMinusButton", "SIZE-", buttonGrid)
	AdjustPlusButton = createMobileButton("AdjustPlusButton", "SIZE+", buttonGrid)
	RotateLeftButton = createMobileButton("RotateLeftButton", "ROT-", buttonGrid)
	RotateRightButton = createMobileButton("RotateRightButton", "ROT+", buttonGrid)

	MobileReticle = Instance.new("Frame")
	MobileReticle.Name = "EditReticle"
	MobileReticle.AnchorPoint = Vector2.new(0.5, 0.5)
	MobileReticle.Position = UDim2.new(0.5, 0, 0.5, 0)
	MobileReticle.Size = UDim2.fromOffset(10, 10)
	MobileReticle.BackgroundColor3 = Color3.fromRGB(255, 231, 92)
	MobileReticle.BorderSizePixel = 0
	MobileReticle.Visible = false
	MobileReticle.ZIndex = 10
	MobileReticle.Parent = HudGui
	Instance.new("UICorner", MobileReticle).CornerRadius = UDim.new(1, 0)
end

local function isMobileEditMode()
	if not UserInputService.TouchEnabled then
		return false
	end
	local camera = workspace.CurrentCamera
	local viewport = camera and camera.ViewportSize
	if viewport and viewport.X > 0 then
		return viewport.X <= 1100
	end
	return not UserInputService.MouseEnabled
end

local function getEditAimScreenPosition()
	if isMobileEditMode() then
		local viewport = workspace.CurrentCamera and workspace.CurrentCamera.ViewportSize or Vector2.new(0, 0)
		return Vector2.new(viewport.X * 0.5, viewport.Y * 0.5)
	end
	local mousePos = UserInputService:GetMouseLocation()
	return Vector2.new(mousePos.X, mousePos.Y)
end

local function getClosestPointOnLine(linePoint, lineDir, ray)
	local rayOrigin = ray.Origin
	local rayDir = ray.Direction.Unit
	
	-- Vector perpendicular to both lines
	local cross = lineDir:Cross(rayDir)
	local denom = cross:Dot(cross)
	
	if denom < 1e-6 then
		-- Lines are parallel, just project origin
		return linePoint + lineDir * (rayOrigin - linePoint):Dot(lineDir)
	end
	
	local t = (rayOrigin - linePoint):Cross(rayDir):Dot(cross) / denom
	return linePoint + lineDir * t
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

local function findPoleModel(part)
	local current = part
	while current and current ~= workspace do
		if current:IsA("Model") and current.Name:match("Pole") and current.Parent and current.Parent:GetAttribute("Type") == "TwoPoint" then
			return current
		end
		current = current.Parent
	end
	return nil
end

local function isSurfaceTowLift(poleModel)
	local lift = poleModel and poleModel.Parent
	if not lift then return false end
	local itemName = lift:GetAttribute("Item") or lift:GetAttribute("ItemName")
	if itemName and Config.Items[itemName] and Config.Items[itemName].SurfaceTow then
		return true
	end
	if Config.Items[lift.Name] and Config.Items[lift.Name].SurfaceTow then
		return true
	end
	return false
end

local function findCustomBlockModel(part)
	return nil
end

local function getMouseRayResult()
	local aim = getEditAimScreenPosition()
	local ray = workspace.CurrentCamera:ScreenPointToRay(aim.X, aim.Y)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = {Player.Character}
	return workspace:Raycast(ray.Origin, ray.Direction * 2000, params)
end

local function getPlaneHit(y)
	local aim = getEditAimScreenPosition()
	local ray = workspace.CurrentCamera:ScreenPointToRay(aim.X, aim.Y)
	if math.abs(ray.Direction.Y) < 1e-4 then
		return nil
	end
	local distance = (y - ray.Origin.Y) / ray.Direction.Y
	if distance < 0 then
		return nil
	end
	return ray.Origin + ray.Direction * distance
end

local function applyBlockState(model, state)
	if model and model.Parent then
		CustomBuildingConfig.ApplyState(model, state)
	end
end

local function commitBlockState(model, immediate)
	if not model or not model.Parent or model:GetAttribute("Type") ~= CustomBuildingConfig.TYPE_NAME then
		return
	end

	pendingCommitToken += 1
	local token = pendingCommitToken

	local function send()
		if token ~= pendingCommitToken or not model.Parent then
			return
		end
		local ok, result = pcall(function()
			return CustomBuildRequest:InvokeServer("Apply", model, CustomBuildingConfig.ReadState(model))
		end)
		if ok and type(result) == "table" and result.success and result.state then
			applyBlockState(model, result.state)
		end
	end

	if immediate then
		send()
	else
		task.delay(0.18, send)
	end
end

local function duplicateSelectedBlock(direction, useMirror)
	if dragging or not selectedModel or selectedKind ~= CustomBuildingConfig.TYPE_NAME then
		return
	end

	commitBlockState(selectedModel, true)
	if not selectedModel.Parent then
		return
	end

	local currentState = CustomBuildingConfig.ReadState(selectedModel)
	local nextState = CustomBuildingConfig.GetDuplicateState(selectedModel.Name, currentState, activeAxis, direction, useMirror)
	pcall(function()
		RequestPlaceItem:InvokeServer(CustomBuildingConfig.BuildPlacementPayload(selectedModel.Name, nextState))
	end)
end

local function setMobileButtonEnabled(button, enabled, text)
	if not button then
		return
	end
	button.Text = text or button.Text
	button.Active = enabled
	button.AutoButtonColor = enabled
	button.BackgroundColor3 = enabled and Color3.fromRGB(48, 103, 196) or Color3.fromRGB(46, 52, 64)
	button.TextTransparency = enabled and 0 or 0.3
end

local function updateMobileButtons()
	local visible = isEditing and isMobileEditMode()
	if MobileReticle then
		MobileReticle.Visible = visible
	end
	if not SelectButton then
		return
	end

	SelectButton.Visible = visible
	MoveButton.Visible = visible
	AxisButton.Visible = visible
	AdjustMinusButton.Visible = visible
	AdjustPlusButton.Visible = visible
	RotateLeftButton.Visible = visible
	RotateRightButton.Visible = visible

	if not visible then
		return
	end

	local hasHover = hoveredModel ~= nil and hoveredKind ~= nil
	setMobileButtonEnabled(SelectButton, hasHover, selectedModel and "RESELECT" or "SELECT")

	local isBlock = selectedKind == CustomBuildingConfig.TYPE_NAME and selectedModel ~= nil
	local isPole = selectedKind == TARGET_POLE and selectedModel ~= nil
	
	setMobileButtonEnabled(MoveButton, isBlock, dragging and "PLACE" or "MOVE")
	
	if isPole then
		setMobileButtonEnabled(AxisButton, true, poleEditMode == "Vertical" and "MODE: VERT" or "MODE: SLIDE")
	else
		setMobileButtonEnabled(AxisButton, isBlock and not dragging, "AXIS " .. activeAxis)
	end

	setMobileButtonEnabled(AdjustMinusButton, isBlock or isPole, isPole and "DOWN" or "SIZE-")
	setMobileButtonEnabled(AdjustPlusButton, isBlock or isPole, isPole and "UP" or "SIZE+")
	setMobileButtonEnabled(RotateLeftButton, isBlock and not dragging, "ROT-")
	setMobileButtonEnabled(RotateRightButton, isBlock and not dragging, "ROT+")
end

local function rotateSelected(direction)
	if selectedKind ~= CustomBuildingConfig.TYPE_NAME or not selectedModel then
		return
	end
	local state = CustomBuildingConfig.ReadState(selectedModel)
	state.Yaw = state.Yaw + (direction * CustomBuildingConfig.ROTATION_SNAP)
	applyBlockState(selectedModel, state)
	commitBlockState(selectedModel, false)
	updateHud()
end

local function adjustSelected(direction)
	if not selectedModel or not selectedKind then
		return
	end
	if selectedKind == TARGET_POLE and selectedModel.PrimaryPart then
		if isSurfaceTowLift(selectedModel) then return end
		local step = CustomBuildingConfig.DEFAULT_STEP
		local primaryPos = selectedModel.PrimaryPart.Position
		local targetY = primaryPos.Y + (direction * step)
		local pivotCF = selectedModel:GetPivot()
		local pivotOffset = pivotCF.Position - primaryPos
		local targetPrimaryPos = Vector3.new(primaryPos.X, targetY, primaryPos.Z)
		selectedModel:PivotTo(CFrame.new(targetPrimaryPos + pivotOffset) * pivotCF.Rotation)
		EditEvent:FireServer(selectedModel.Parent, selectedModel, selectedModel.PrimaryPart.Position)
	elseif selectedKind == CustomBuildingConfig.TYPE_NAME then
		local state = CustomBuildingConfig.ReadState(selectedModel)
		local delta = direction * CustomBuildingConfig.DEFAULT_STEP
		local size = state.Size
		if activeAxis == "X" then
			size = Vector3.new(size.X + delta, size.Y, size.Z)
		elseif activeAxis == "Y" then
			size = Vector3.new(size.X, size.Y + delta, size.Z)
		else
			size = Vector3.new(size.X, size.Y, size.Z + delta)
		end
		state.Size = CustomBuildingConfig.ClampSize(size)
		applyBlockState(selectedModel, state)
		commitBlockState(selectedModel, false)
	end
	updateHud()
end

local function toggleSelectedMove()
	if selectedKind ~= CustomBuildingConfig.TYPE_NAME or not selectedModel then
		return
	end
	if dragging then
		dragging = false
		commitBlockState(selectedModel, true)
		originalBlockState = nil
		updateHud()
		return
	end
		dragging = true
		originalBlockState = cloneState(CustomBuildingConfig.ReadState(selectedModel))
		dragPlaneY = originalBlockState.Position.Y
		local planeHit = getPlaneHit(dragPlaneY)
		dragOffset = planeHit and (originalBlockState.Position - planeHit) or Vector3.zero
		updateHud()
end

local function selectHoveredTarget()
	if not hoveredModel or not hoveredKind then
		setSelection(nil, nil)
		updateHud()
		return
	end
	setSelection(hoveredModel, hoveredKind)
	if selectedKind == TARGET_POLE and selectedModel and not selectedModel.PrimaryPart then
		selectedModel.PrimaryPart = selectedModel:FindFirstChild("Base") or selectedModel:FindFirstChildWhichIsA("BasePart")
	end
	updateHud()
end

local function updateDragFromAim()
	if not dragging or not selectedModel or selectedKind ~= CustomBuildingConfig.TYPE_NAME or not originalBlockState then
		return
	end
	local planeHit = getPlaneHit(dragPlaneY)
	if planeHit then
		local nextState = cloneState(originalBlockState)
		nextState.Position = CustomBuildingConfig.SnapVector3(planeHit + dragOffset)
		applyBlockState(selectedModel, nextState)
	end
end

local function updatePoleDragFromAim()
	if not dragging or selectedKind ~= TARGET_POLE or not selectedModel or not selectedModel.PrimaryPart then
		return
	end
	if not originalPoleCFrame or not dragStartPolePrimaryPos then
		return
	end

	if poleEditMode == "Vertical" then
		if isSurfaceTowLift(selectedModel) then return end
		local currentMouseY = UserInputService:GetMouseLocation().Y
		local pixelDelta = dragStartMouseY - currentMouseY
		local studDelta = pixelDelta * DRAG_SENSITIVITY
		local targetY = dragStartPoleY + studDelta
		local targetPrimaryPos = Vector3.new(dragStartPolePrimaryPos.X, targetY, dragStartPolePrimaryPos.Z)
		selectedModel:PivotTo(CFrame.new(targetPrimaryPos + originalPolePivotOffset) * originalPoleCFrame.Rotation)
	else
		if not dragStartPos or not dragStartPointOnLine then
			return
		end
		local aim = getEditAimScreenPosition()
		local mouseRay = workspace.CurrentCamera:ScreenPointToRay(aim.X, aim.Y)
		local currentPointOnLine = getClosestPointOnLine(dragStartPos, poleSlideAxis, mouseRay)
		local delta = (currentPointOnLine - dragStartPointOnLine):Dot(poleSlideAxis)
		local newPos = dragStartPos + (poleSlideAxis * delta)
		local targetPivotPos = newPos + originalPolePivotOffset
		selectedModel:PivotTo(CFrame.new(targetPivotPos) * originalPoleCFrame.Rotation)
	end
end

updateHud = function()
	if not isEditing then
		updateMobileButtons()
		return
	end

	local targetModel = selectedModel or hoveredModel
	local targetKind = selectedKind or hoveredKind
	local targetName = targetModel and targetModel.Name or "Nothing selected"

	TitleLabel.Text = "Edit Build"
	if isMobileEditMode() then
		if targetKind == CustomBuildingConfig.TYPE_NAME then
			HintLabel.Text = dragging
				and "Aim with camera and tap PLACE when the piece is lined up. Use AXIS and SIZE buttons for dimensions."
				or "Aim with camera, tap SELECT, then MOVE to reposition the selected build."
			SelectionLabel.Text = string.format("Selected: %s | Axis: %s", targetName, activeAxis)
		elseif targetKind == TARGET_POLE then
			HintLabel.Text = "Aim with camera, tap SELECT, then use UP / DOWN to move the pole."
			SelectionLabel.Text = "Selected: " .. targetName
		else
			HintLabel.Text = "Aim with camera at a lift pole or build, then tap SELECT."
			SelectionLabel.Text = "Selected: Nothing selected"
		end
	else
		if targetKind == CustomBuildingConfig.TYPE_NAME then
			HintLabel.Text = "Drag move | 1/2/3 axis | Wheel resize | Shift+wheel fine | R/T rotate | U/J height | C duplicate | M mirror | Z exit"
			SelectionLabel.Text = string.format("Selected: %s | Axis: %s | Snap: %.2f", targetName, activeAxis, CustomBuildingConfig.SNAP)
		elseif targetKind == TARGET_POLE then
			HintLabel.Text = "Drag pole to move. [V] toggle Up/Down or Back/Forth. | Z exit"
			SelectionLabel.Text = string.format("Selected: %s (%s)", targetName, poleEditMode)
		else
			HintLabel.Text = "Hover a lift pole, then click to edit it."
			SelectionLabel.Text = "Selected: " .. targetName
		end
		ModeButton.Visible = true
		ModeButton.Text = "MODE: " .. (poleEditMode == "Vertical" and "VERT" or "SLIDE")
	end
	updateMobileButtons()
end

setSelection = function(model, kind)
	if selectedKind == CustomBuildingConfig.TYPE_NAME and selectedModel and selectedModel ~= model then
		commitBlockState(selectedModel, true)
	end
	selectedModel = model
	selectedKind = kind
	updateHud()
end

local visiblePrompts = {}

local function getPromptWorldPosition(prompt)
	local parent = prompt and prompt.Parent
	if not parent then
		return nil
	end
	if parent:IsA("Attachment") then
		return parent.WorldPosition
	end
	if parent:IsA("BasePart") then
		return parent.Position
	end
	if parent:IsA("Model") then
		return parent:GetPivot().Position
	end
	return nil
end

local function hasNearbyEPrompt()
	local character = Player.Character
	local hrp = character and character:FindFirstChild("HumanoidRootPart")
	if not hrp then
		return false
	end
	for _, desc in ipairs(workspace:GetDescendants()) do
		if desc:IsA("ProximityPrompt") and desc.Enabled and desc.KeyboardKeyCode == Enum.KeyCode.E then
			local promptPos = getPromptWorldPosition(desc)
			if promptPos and (promptPos - hrp.Position).Magnitude <= math.max(desc.MaxActivationDistance, 0) + 1 then
				return true
			end
		end
	end
	return false
end

local function isEditHotkeyBlocked()
	if hasNearbyEPrompt() then
		return true
	end
	for prompt in pairs(visiblePrompts) do
		if prompt and prompt.Parent and prompt.Enabled and prompt.KeyboardKeyCode == Enum.KeyCode.E then
			return true
		end
		visiblePrompts[prompt] = nil
	end
	return false
end

ProximityPromptService.PromptShown:Connect(function(prompt)
	visiblePrompts[prompt] = true
end)

ProximityPromptService.PromptHidden:Connect(function(prompt)
	visiblePrompts[prompt] = nil
end)

local function stopEditing(revertCurrentDrag, reopenBuild)
	if revertCurrentDrag and dragging and selectedModel then
		if selectedKind == TARGET_POLE and originalPoleCFrame then
			selectedModel:PivotTo(originalPoleCFrame)
		elseif selectedKind == CustomBuildingConfig.TYPE_NAME and originalBlockState then
			applyBlockState(selectedModel, originalBlockState)
		end
	end

	if selectedKind == CustomBuildingConfig.TYPE_NAME and selectedModel then
		commitBlockState(selectedModel, true)
	end

	isEditing = false
	dragging = false
	hoveredModel = nil
	hoveredKind = nil
	selectedModel = nil
	selectedKind = nil
	originalPoleCFrame = nil
	originalPolePivotOffset = Vector3.zero
	dragStartPolePrimaryPos = nil
	originalBlockState = nil
	Highlight.Adornee = nil
	HudGui.Enabled = false
	ModeState.Value = ""
	updateMobileButtons()

	if reopenBuild and openedFromButton then
		BuildFrame.Visible = true
	end
	openedFromButton = false
end

local function startEditing(fromButton)
	if not isEditing and ModeState.Value ~= "" and ModeState.Value ~= "Editing" then
		return
	end

	openedFromButton = fromButton == true or BuildFrame.Visible
	isEditing = true
	dragging = false
	ModeState.Value = "Editing"
	HudGui.Enabled = true
	ClosePanels:Fire("Edit")
	BuildFrame.Visible = false
	updateHud()
end

if SelectButton then
	SelectButton.Activated:Connect(function()
		if isEditing then
			selectHoveredTarget()
		end
	end)
	MoveButton.Activated:Connect(function()
		if isEditing then
			toggleSelectedMove()
		end
	end)
	AxisButton.Activated:Connect(function()
		if not isEditing or selectedKind ~= CustomBuildingConfig.TYPE_NAME or not selectedModel or dragging then
			return
		end
		if selectedKind == TARGET_POLE then
			poleEditMode = poleEditMode == "Vertical" and "Slide" or "Vertical"
		else
			activeAxis = activeAxis == "X" and "Y" or (activeAxis == "Y" and "Z" or "X")
		end
		updateHud()
	end)
	AdjustMinusButton.Activated:Connect(function()
		if isEditing then
			adjustSelected(-1)
		end
	end)
	AdjustPlusButton.Activated:Connect(function()
		if isEditing then
			adjustSelected(1)
		end
	end)
	RotateLeftButton.Activated:Connect(function()
		if isEditing then
			rotateSelected(-1)
		end
		end)
	RotateRightButton.Activated:Connect(function()
		if isEditing then
			rotateSelected(1)
		end
	end)
end

ExitButton.Activated:Connect(function()
	if isEditing then
		stopEditing(true, true)
	end
end)

EditButton.MouseButton1Click:Connect(function()
	if isEditing then
		stopEditing(true, true)
	else
		startEditing(true)
	end
end)

ModeButton.MouseButton1Click:Connect(function()
	if isEditing then
		if poleEditMode == "Vertical" then
			poleEditMode = "Slide"
		else
			poleEditMode = "Vertical"
		end
		updateHud()
	end
end)

ClosePanels.Event:Connect(function(source)
	if source == "Edit" then
		return
	end
	if isEditing then
		stopEditing(false, false)
	end
end)

Player.CharacterAdded:Connect(function()
	task.defer(function()
		if isEditing then
			stopEditing(false, false)
		else
			dragging = false
			hoveredModel = nil
			hoveredKind = nil
			selectedModel = nil
			selectedKind = nil
			originalPoleCFrame = nil
			originalPolePivotOffset = Vector3.zero
			dragStartPolePrimaryPos = nil
			originalBlockState = nil
			Highlight.Adornee = nil
			HudGui.Enabled = false
			ModeState.Value = ""
			updateMobileButtons()
			openedFromButton = false
		end
	end)
end)

RunService.RenderStepped:Connect(function()
	if not isEditing then
		return
	end

	if selectedModel and not selectedModel.Parent then
		selectedModel = nil
		selectedKind = nil
	end

	if not dragging then
		local result = getMouseRayResult()
		local nextModel = nil
		local nextKind = nil
		if result and result.Instance then
			nextModel = findPoleModel(result.Instance)
			if nextModel then
				nextKind = TARGET_POLE
			end
		end
		hoveredModel = nextModel
		hoveredKind = nextKind
	end

	if dragging then
		if selectedKind == CustomBuildingConfig.TYPE_NAME then
			updateDragFromAim()
		elseif selectedKind == TARGET_POLE then
			updatePoleDragFromAim()
		end
	end

	Highlight.Adornee = selectedModel or hoveredModel
	updateHud()
end)

UserInputService.InputBegan:Connect(function(input, gameProcessed)
	if gameProcessed then
		return
	end

	if input.KeyCode == Enum.KeyCode.E then
		if isEditHotkeyBlocked() then
			return
		end
		if isEditing then
			stopEditing(true, true)
		else
			startEditing(false)
		end
		return
	end

	if not isEditing then
		return
	end

	if input.KeyCode == Enum.KeyCode.Z or input.KeyCode == Enum.KeyCode.Escape then
		stopEditing(true, true)
		return
	end

	if input.KeyCode == Enum.KeyCode.V and isEditing and selectedKind == TARGET_POLE then
		if isSurfaceTowLift(selectedModel) then
			poleEditMode = "Slide"
		else
			poleEditMode = (poleEditMode == "Vertical") and "Slide" or "Vertical"
		end
		updateHud()
		return
	end

	local activeModel = selectedModel or hoveredModel
	local activeKind = selectedKind or hoveredKind
	if activeModel and activeKind and (selectedModel ~= activeModel or selectedKind ~= activeKind) then
		setSelection(activeModel, activeKind)
	end

	if selectedKind == TARGET_POLE and selectedModel then
		if input.KeyCode == Enum.KeyCode.U or input.KeyCode == Enum.KeyCode.J then
			adjustSelected(input.KeyCode == Enum.KeyCode.U and 1 or -1)
			return
		end
	end

	if selectedKind == CustomBuildingConfig.TYPE_NAME and selectedModel then
		if input.KeyCode == Enum.KeyCode.One then
			activeAxis = "X"
			updateHud()
			return
		elseif input.KeyCode == Enum.KeyCode.Two then
			activeAxis = "Y"
			updateHud()
			return
		elseif input.KeyCode == Enum.KeyCode.Three then
			activeAxis = "Z"
			updateHud()
			return
		elseif input.KeyCode == Enum.KeyCode.V and isMobileEditMode() then
			-- AxisButton logic for mobile usually handled in AxisButton handler but good to have fallback
			return
		elseif input.KeyCode == Enum.KeyCode.R or input.KeyCode == Enum.KeyCode.T or input.KeyCode == Enum.KeyCode.Q then
			rotateSelected(input.KeyCode == Enum.KeyCode.R and 1 or -1)
			return
		elseif input.KeyCode == Enum.KeyCode.U or input.KeyCode == Enum.KeyCode.J then
			local direction = input.KeyCode == Enum.KeyCode.U and 1 or -1
			local isFineStep = UserInputService:IsKeyDown(Enum.KeyCode.LeftShift) or UserInputService:IsKeyDown(Enum.KeyCode.RightShift)
			local step = isFineStep and CustomBuildingConfig.FINE_STEP or CustomBuildingConfig.DEFAULT_STEP
			local state = CustomBuildingConfig.ReadState(selectedModel)
			state.Position = CustomBuildingConfig.SnapVector3(state.Position + Vector3.new(0, direction * step, 0))
			applyBlockState(selectedModel, state)
			commitBlockState(selectedModel, false)
			updateHud()
			return
		elseif input.KeyCode == Enum.KeyCode.C or input.KeyCode == Enum.KeyCode.M then
			duplicateSelectedBlock(input.KeyCode == Enum.KeyCode.C and 1 or -1, input.KeyCode == Enum.KeyCode.M)
			return
		end
	end

	if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
		if input.UserInputType == Enum.UserInputType.Touch and isMobileEditMode() then
			return
		end
		if not hoveredModel or not hoveredKind then
			setSelection(nil, nil)
			return
		end

		setSelection(hoveredModel, hoveredKind)
		if selectedKind == TARGET_POLE then
			if not selectedModel.PrimaryPart then
				selectedModel.PrimaryPart = selectedModel:FindFirstChild("Base") or selectedModel:FindFirstChildWhichIsA("BasePart")
			end
			if isSurfaceTowLift(selectedModel) then
				poleEditMode = "Slide"
			end
			if selectedModel.PrimaryPart then
				dragging = true
				local primaryPos = selectedModel.PrimaryPart.Position
				originalPoleCFrame = selectedModel:GetPivot()
				originalPolePivotOffset = originalPoleCFrame.Position - primaryPos
				dragStartPolePrimaryPos = primaryPos
				PoleDebug("Begin drag", selectedModel:GetFullName(), poleEditMode, primaryPos)
				
				if poleEditMode == "Vertical" then
					dragStartMouseY = UserInputService:GetMouseLocation().Y
					dragStartPoleY = primaryPos.Y
				else
					-- Slide mode
					dragStartPos = primaryPos
					local lift = selectedModel.Parent
					local s, e = lift:FindFirstChild("StartStation"), lift:FindFirstChild("EndStation")
					local dir = (s and e) and (e:GetPivot().Position - s:GetPivot().Position).Unit or selectedModel:GetPivot().LookVector
					poleSlideAxis = dir
					
					local aim = getEditAimScreenPosition()
					local mouseRay = workspace.CurrentCamera:ScreenPointToRay(aim.X, aim.Y)
					dragStartPointOnLine = getClosestPointOnLine(dragStartPos, poleSlideAxis, mouseRay)
				end
			end
		elseif selectedKind == CustomBuildingConfig.TYPE_NAME then
			dragging = true
			originalBlockState = cloneState(CustomBuildingConfig.ReadState(selectedModel))
			dragPlaneY = originalBlockState.Position.Y
			local planeHit = getPlaneHit(dragPlaneY)
			dragOffset = planeHit and (originalBlockState.Position - planeHit) or Vector3.zero
		end
		updateHud()
	end
end)

UserInputService.InputChanged:Connect(function(input)
	if not isEditing then
		return
	end

	if input.UserInputType == Enum.UserInputType.MouseWheel and not dragging and selectedKind == CustomBuildingConfig.TYPE_NAME and selectedModel then
		local delta = input.Position.Z
		if delta == 0 then
			return
		end
		local step = (UserInputService:IsKeyDown(Enum.KeyCode.LeftShift) or UserInputService:IsKeyDown(Enum.KeyCode.RightShift))
			and CustomBuildingConfig.FINE_STEP
			or CustomBuildingConfig.DEFAULT_STEP
		local direction = delta > 0 and step or -step
		local state = CustomBuildingConfig.ReadState(selectedModel)
		local size = state.Size
		if activeAxis == "X" then
			size = Vector3.new(size.X + direction, size.Y, size.Z)
		elseif activeAxis == "Y" then
			size = Vector3.new(size.X, size.Y + direction, size.Z)
		else
			size = Vector3.new(size.X, size.Y, size.Z + direction)
		end
		state.Size = CustomBuildingConfig.ClampSize(size)
		applyBlockState(selectedModel, state)
		commitBlockState(selectedModel, false)
		updateHud()
		return
	end

	if not dragging or not selectedModel then
		return
	end

	if input.UserInputType == Enum.UserInputType.MouseMovement or (input.UserInputType == Enum.UserInputType.Touch and not isMobileEditMode()) then
		if selectedKind == TARGET_POLE then
			updatePoleDragFromAim()
		elseif selectedKind == CustomBuildingConfig.TYPE_NAME and originalBlockState then
			updateDragFromAim()
		end
	end
end)

UserInputService.InputEnded:Connect(function(input)
	if not dragging or not selectedModel then
		return
	end

	if input.UserInputType == Enum.UserInputType.Touch and isMobileEditMode() then
		return
	end
	if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
		dragging = false
		if selectedKind == TARGET_POLE and selectedModel.PrimaryPart then
			local currentPrimary = selectedModel.PrimaryPart.Position
			local movedDistance = dragStartPolePrimaryPos and (currentPrimary - dragStartPolePrimaryPos).Magnitude or math.huge
			if movedDistance >= POLE_EDIT_MIN_COMMIT_DISTANCE then
				PoleDebug("Commit drag", selectedModel:GetFullName(), poleEditMode, movedDistance, currentPrimary)
				EditEvent:FireServer(selectedModel.Parent, selectedModel, currentPrimary)
			else
				PoleDebug("Skip commit (no movement)", selectedModel:GetFullName(), movedDistance)
			end
		elseif selectedKind == CustomBuildingConfig.TYPE_NAME then
			commitBlockState(selectedModel, true)
		end
		originalPoleCFrame = nil
		originalPolePivotOffset = Vector3.zero
		dragStartPolePrimaryPos = nil
		originalBlockState = nil
		updateHud()
	end
end)