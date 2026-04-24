if true then
	return
end

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")

local Player = Players.LocalPlayer
local PlayerGui = Player:WaitForChild("PlayerGui")
local MainHUD = PlayerGui:WaitForChild("MainHUD")
local BuildFrame = MainHUD:WaitForChild("BuildFrame")
local BuilderButton = BuildFrame:WaitForChild("Buttons"):WaitForChild("Paint")

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

local Controls = nil
local FreecamPart = nil
local isBuilderOpen = false
local openedFromButton = false
local selectedModel = nil
local hoveredModel = nil
local previewGhost = nil
local placingItemName = nil
local selectedColor = CustomBuildingConfig.DEFAULT_COLOR
local selectedMaterial = CustomBuildingConfig.DEFAULT_MATERIAL
local activeAxis = "X"
local currentPlacementRotation = 0
local dragging = false
local dragPlaneY = 0
local dragOffset = Vector3.zero
local pendingCommitToken = 0

local TerrainRayParams = RaycastParams.new()
TerrainRayParams.FilterType = Enum.RaycastFilterType.Include
TerrainRayParams.FilterDescendantsInstances = {workspace.Terrain}
TerrainRayParams.IgnoreWater = true

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

local function enableFreecam()
	if FreecamPart then
		return
	end
	FreecamPart = Instance.new("Part")
	FreecamPart.Name = "BuilderStudioFreecamRoot"
	FreecamPart.Transparency = 1
	FreecamPart.CanCollide = false
	FreecamPart.Anchored = true
	FreecamPart.Size = Vector3.new(1, 1, 1)
	FreecamPart.Position = (Player.Character and Player.Character:GetPivot().Position or workspace.CurrentCamera.CFrame.Position) + Vector3.new(0, 16, 0)
	FreecamPart.Parent = workspace
	workspace.CurrentCamera.CameraSubject = FreecamPart
	local rootPart = Player.Character and Player.Character:FindFirstChild("HumanoidRootPart")
	if rootPart then
		rootPart.Anchored = true
	end
end

local function disableFreecam()
	if not FreecamPart then
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
		if humanoid:GetState() == Enum.HumanoidStateType.Freefall then
			humanoid:ChangeState(Enum.HumanoidStateType.GettingUp)
		end
	end
	FreecamPart:Destroy()
	FreecamPart = nil
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

local function getMouseRayResult()
	local mousePos = UserInputService:GetMouseLocation()
	local ray = workspace.CurrentCamera:ScreenPointToRay(mousePos.X, mousePos.Y)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local ignore = {Player.Character}
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
	local mousePos = UserInputService:GetMouseLocation()
	local ray = workspace.CurrentCamera:ScreenPointToRay(mousePos.X, mousePos.Y)
	if math.abs(ray.Direction.Y) < 1e-4 then
		return nil
	end
	local distance = (y - ray.Origin.Y) / ray.Direction.Y
	if distance < 0 then
		return nil
	end
	return ray.Origin + ray.Direction * distance
end

local Highlight = Instance.new("Highlight")
Highlight.Name = "BuilderStudioHighlight"
Highlight.FillColor = Color3.fromRGB(92, 148, 255)
Highlight.OutlineColor = Color3.fromRGB(255, 255, 255)
Highlight.FillTransparency = 0.45
Highlight.Parent = PlayerGui

local Gui = Instance.new("ScreenGui")
Gui.Name = "BuilderStudioGui"
Gui.ResetOnSpawn = false
Gui.Enabled = false
Gui.Parent = PlayerGui

local Panel = Instance.new("ScrollingFrame")
Panel.Name = "Panel"
Panel.AnchorPoint = Vector2.new(1, 1)
Panel.Position = UDim2.new(1, -18, 1, -18)
Panel.Size = UDim2.new(0, 440, 0, 560)
Panel.BackgroundColor3 = Color3.fromRGB(14, 18, 28)
Panel.BackgroundTransparency = 0.06
Panel.BorderSizePixel = 0
Panel.AutomaticCanvasSize = Enum.AutomaticSize.Y
Panel.CanvasSize = UDim2.new()
Panel.ScrollingDirection = Enum.ScrollingDirection.Y
Panel.ScrollBarThickness = 6
Panel.ScrollBarImageColor3 = Color3.fromRGB(92, 148, 255)
Panel.Parent = Gui
Instance.new("UICorner", Panel).CornerRadius = UDim.new(0, 14)
local panelStroke = Instance.new("UIStroke")
panelStroke.Color = Color3.fromRGB(92, 148, 255)
panelStroke.Transparency = 0.1
panelStroke.Thickness = 1.5
panelStroke.Parent = Panel

local layout = Instance.new("UIListLayout")
layout.Padding = UDim.new(0, 8)
layout.SortOrder = Enum.SortOrder.LayoutOrder
layout.Parent = Panel

local padding = Instance.new("UIPadding")
padding.PaddingTop = UDim.new(0, 14)
padding.PaddingBottom = UDim.new(0, 14)
padding.PaddingLeft = UDim.new(0, 14)
padding.PaddingRight = UDim.new(0, 14)
padding.Parent = Panel

local Header = Instance.new("Frame")
Header.Name = "Header"
Header.Size = UDim2.new(1, 0, 0, 36)
Header.BackgroundTransparency = 1
Header.LayoutOrder = 0
Header.Parent = Panel

local TitleLabel = Instance.new("TextLabel")
TitleLabel.BackgroundTransparency = 1
TitleLabel.Position = UDim2.new(0, 0, 0, 0)
TitleLabel.Size = UDim2.new(1, -94, 0, 20)
TitleLabel.Font = Enum.Font.GothamBlack
TitleLabel.Text = "BUILDER STUDIO"
TitleLabel.TextColor3 = Color3.fromRGB(244, 247, 255)
TitleLabel.TextSize = 18
TitleLabel.TextXAlignment = Enum.TextXAlignment.Left
TitleLabel.Parent = Header

local SubtitleLabel = Instance.new("TextLabel")
SubtitleLabel.BackgroundTransparency = 1
SubtitleLabel.Position = UDim2.new(0, 0, 0, 20)
SubtitleLabel.Size = UDim2.new(1, -94, 0, 14)
SubtitleLabel.Font = Enum.Font.GothamMedium
SubtitleLabel.Text = "Dedicated custom building mode. 0.05 snap, Studio-style tools, saves on rejoin."
SubtitleLabel.TextColor3 = Color3.fromRGB(182, 198, 229)
SubtitleLabel.TextSize = 11
SubtitleLabel.TextXAlignment = Enum.TextXAlignment.Left
SubtitleLabel.Parent = Header

local DoneButton = Instance.new("TextButton")
DoneButton.AnchorPoint = Vector2.new(1, 0)
DoneButton.Position = UDim2.new(1, 0, 0, 0)
DoneButton.Size = UDim2.new(0, 84, 0, 30)
DoneButton.BackgroundColor3 = Color3.fromRGB(185, 61, 61)
DoneButton.BorderSizePixel = 0
DoneButton.Font = Enum.Font.GothamBold
DoneButton.Text = "DONE"
DoneButton.TextColor3 = Color3.fromRGB(255, 255, 255)
DoneButton.TextSize = 12
DoneButton.Parent = Header
Instance.new("UICorner", DoneButton).CornerRadius = UDim.new(0, 8)

local StatusLabel = Instance.new("TextLabel")
StatusLabel.Name = "StatusLabel"
StatusLabel.Size = UDim2.new(1, 0, 0, 42)
StatusLabel.BackgroundColor3 = Color3.fromRGB(20, 24, 36)
StatusLabel.BackgroundTransparency = 0.12
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
local statusPadding = Instance.new("UIPadding")
statusPadding.PaddingLeft = UDim.new(0, 12)
statusPadding.PaddingRight = UDim.new(0, 12)
statusPadding.Parent = StatusLabel

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
	frame.BackgroundTransparency = 0.12
	frame.BorderSizePixel = 0
	frame.Size = UDim2.new(1, 0, 0, height)
	frame.LayoutOrder = order
	frame.Parent = Panel
	Instance.new("UICorner", frame).CornerRadius = UDim.new(0, 10)
	return frame
end

createSectionLabel(2, "New Piece")
local NewShapesFrame = createSectionFrame(3, 72)
local newShapeGrid = Instance.new("UIGridLayout")
newShapeGrid.CellSize = UDim2.new(0, 76, 0, 28)
newShapeGrid.CellPadding = UDim2.new(0, 6, 0, 6)
newShapeGrid.Parent = NewShapesFrame

createSectionLabel(4, "Selected Shape")
local SelectedShapesFrame = createSectionFrame(5, 72)
local selectedShapeGrid = Instance.new("UIGridLayout")
selectedShapeGrid.CellSize = UDim2.new(0, 76, 0, 28)
selectedShapeGrid.CellPadding = UDim2.new(0, 6, 0, 6)
selectedShapeGrid.Parent = SelectedShapesFrame

createSectionLabel(6, "Transform")
local TransformFrame = createSectionFrame(7, 154)
local transformGrid = Instance.new("UIGridLayout")
transformGrid.CellSize = UDim2.new(0, 95, 0, 30)
transformGrid.CellPadding = UDim2.new(0, 8, 0, 8)
transformGrid.Parent = TransformFrame

createSectionLabel(8, "Colors")
local ColorsFrame = createSectionFrame(9, 72)
local colorGrid = Instance.new("UIGridLayout")
colorGrid.CellSize = UDim2.new(0, 76, 0, 28)
colorGrid.CellPadding = UDim2.new(0, 6, 0, 6)
colorGrid.Parent = ColorsFrame

createSectionLabel(10, "Materials")
local MaterialsFrame = createSectionFrame(11, 68)
local materialGrid = Instance.new("UIGridLayout")
materialGrid.CellSize = UDim2.new(0, 98, 0, 24)
materialGrid.CellPadding = UDim2.new(0, 6, 0, 6)
materialGrid.Parent = MaterialsFrame

local shapeButtons = {}
local selectedShapeButtons = {}
local axisButtons = {}
local colorButtons = {}
local materialButtons = {}

local function createActionButton(parent, text, color)
	local button = Instance.new("TextButton")
	button.BackgroundColor3 = color or Color3.fromRGB(30, 37, 52)
	button.BorderSizePixel = 0
	button.Text = text
	button.TextColor3 = Color3.fromRGB(245, 247, 255)
	button.TextSize = 11
	button.Font = Enum.Font.GothamBold
	button.Parent = parent
	Instance.new("UICorner", button).CornerRadius = UDim.new(0, 8)
	return button
end

local function setCaption(button, text)
	local label = button:FindFirstChild("BuilderCaption")
	if not label then
		label = Instance.new("TextLabel")
		label.Name = "BuilderCaption"
		label.BackgroundTransparency = 1
		label.AnchorPoint = Vector2.new(0.5, 1)
		label.Position = UDim2.new(0.5, 0, 1, -2)
		label.Size = UDim2.new(1, -4, 0, 12)
		label.Font = Enum.Font.GothamBold
		label.TextColor3 = Color3.fromRGB(236, 242, 255)
		label.TextSize = 9
		label.ZIndex = 8
		label.Parent = button
	end
	label.Text = text
end

BuilderButton.BackgroundColor3 = Color3.fromRGB(25, 53, 102)
BuilderButton.AutoButtonColor = true
BuilderButton.Text = "Builder"
setCaption(BuilderButton, "STUDIO")

local function refreshStatus()
	local lines = {
		"Click to select, drag to move, wheel to scale, and use 1 / 2 / 3 to swap axes.",
		"Hotkeys: R/T rotate, [/] nudge, -/+ scale, U/J vertical, C duplicate, M mirror, G ground, Delete remove.",
	}
	if placingItemName and previewGhost then
		table.insert(lines, 1, string.format("Placing %s | Click to place | Z cancels preview", placingItemName))
	elseif selectedModel and selectedModel.Parent then
		local state = CustomBuildingConfig.ReadState(selectedModel)
		table.insert(lines, 1, string.format("Selected %s | Axis %s | Size %.2f x %.2f x %.2f", selectedModel.Name, activeAxis, state.Size.X, state.Size.Y, state.Size.Z))
	else
		table.insert(lines, 1, "No piece selected. Spawn a new shape or click one of your placed pieces.")
	end
	StatusLabel.Text = table.concat(lines, "\n")
end

local function clearPreviewGhost()
	if previewGhost then
		previewGhost:Destroy()
		previewGhost = nil
	end
	placingItemName = nil
	currentPlacementRotation = 0
	refreshStatus()
end

local function createPreviewGhost(itemName)
	clearPreviewGhost()
	placingItemName = itemName
	currentPlacementRotation = 0
	previewGhost = CustomBuildingConfig.CreateModel(itemName)
	for _, part in ipairs(previewGhost:GetDescendants()) do
		if part:IsA("BasePart") then
			part.Transparency = 0.5
			part.CanCollide = false
			part.Color = Color3.fromRGB(110, 195, 255)
			part.Material = Enum.Material.ForceField
		end
	end
	previewGhost.Parent = workspace
	refreshStatus()
end

local function refreshPaletteVisuals()
	for _, entry in ipairs(colorButtons) do
		local stroke = entry.Button:FindFirstChildOfClass("UIStroke")
		if stroke then
			stroke.Transparency = entry.Color == selectedColor and 0 or 1
		end
	end
	for _, entry in ipairs(materialButtons) do
		local stroke = entry.Button:FindFirstChildOfClass("UIStroke")
		if stroke then
			stroke.Transparency = entry.Material == selectedMaterial and 0 or 1
		end
	end
end

local function refreshAxisVisuals()
	for axis, button in pairs(axisButtons) do
		button.BackgroundColor3 = axis == activeAxis and Color3.fromRGB(92, 148, 255) or Color3.fromRGB(30, 37, 52)
	end
end

local applySelectedState

local function setSelection(model)
	selectedModel = model
	if selectedModel and selectedModel.Parent then
		local state = CustomBuildingConfig.ReadState(selectedModel)
		selectedColor = state.Color
		selectedMaterial = state.Material
	end
	refreshPaletteVisuals()
	refreshStatus()
end

local function nudgeSelected(direction)
	if not selectedModel or not selectedModel.Parent then
		return
	end
	local state = CustomBuildingConfig.ReadState(selectedModel)
	local step = (UserInputService:IsKeyDown(Enum.KeyCode.LeftShift) or UserInputService:IsKeyDown(Enum.KeyCode.RightShift)) and CustomBuildingConfig.FINE_STEP or CustomBuildingConfig.DEFAULT_STEP
	local axisVector = CustomBuildingConfig.GetAxisVector(state.Yaw, activeAxis)
	state.Position = CustomBuildingConfig.SnapVector3(state.Position + (axisVector * step * direction))
	applySelectedState(state, true)
end

local function scaleSelected(direction)
	if not selectedModel or not selectedModel.Parent then
		return
	end
	local step = (UserInputService:IsKeyDown(Enum.KeyCode.LeftShift) or UserInputService:IsKeyDown(Enum.KeyCode.RightShift)) and CustomBuildingConfig.FINE_STEP or CustomBuildingConfig.DEFAULT_STEP
	local signedStep = direction > 0 and step or -step
	local state = CustomBuildingConfig.ReadState(selectedModel)
	local size = state.Size
	if activeAxis == "X" then
		size = Vector3.new(size.X + signedStep, size.Y, size.Z)
	elseif activeAxis == "Y" then
		size = Vector3.new(size.X, size.Y + signedStep, size.Z)
	else
		size = Vector3.new(size.X, size.Y, size.Z + signedStep)
	end
	state.Size = CustomBuildingConfig.ClampSize(size)
	applySelectedState(state, true)
end

local function groundSelected()
	if not selectedModel or not selectedModel.Parent then
		return
	end
	local state = CustomBuildingConfig.ReadState(selectedModel)
	local pivotPos = selectedModel:GetPivot().Position
	local bbCF, bbSize = selectedModel:GetBoundingBox()
	local bottomOffset = pivotPos.Y - (bbCF.Position.Y - (bbSize.Y / 2))
	local rayResult = workspace:Raycast(Vector3.new(state.Position.X, math.max(state.Position.Y + 256, 512), state.Position.Z), Vector3.new(0, -1024, 0), TerrainRayParams)
	if not rayResult then
		return
	end
	state.Position = CustomBuildingConfig.SnapVector3(Vector3.new(state.Position.X, rayResult.Position.Y + bottomOffset - 0.05, state.Position.Z))
	applySelectedState(state, true)
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
		if ok and type(result) == "table" and result.success and result.state then
			CustomBuildingConfig.ApplyState(selectedModel, result.state)
		end
	end
	if immediate then
		send()
	else
		task.delay(0.12, send)
	end
end

applySelectedState = function(nextState, immediate)
	if not selectedModel or not selectedModel.Parent then
		return
	end
	CustomBuildingConfig.ApplyState(selectedModel, nextState)
	commitSelected(immediate)
	refreshStatus()
end

local function paintSelected()
	if not selectedModel or not selectedModel.Parent then
		refreshPaletteVisuals()
		return
	end
	local state = CustomBuildingConfig.ReadState(selectedModel)
	state.Color = selectedColor
	state.Material = selectedMaterial
	CustomBuildingConfig.ApplyState(selectedModel, state)
	local ok, result = pcall(function()
		return CustomBuildRequest:InvokeServer("Paint", selectedModel, {
			Color = selectedColor,
			Material = selectedMaterial,
		})
	end)
	if ok and type(result) == "table" and result.success and result.state then
		CustomBuildingConfig.ApplyState(selectedModel, result.state)
	end
	refreshPaletteVisuals()
	refreshStatus()
end

local function morphSelected(itemName)
	if not selectedModel or not selectedModel.Parent then
		return
	end
	local state = CustomBuildingConfig.ReadState(selectedModel)
	state.Shape = CustomBuildingConfig.GetShape(itemName)
	applySelectedState(state, true)
end

local function duplicateSelected(useMirror)
	if not selectedModel or not selectedModel.Parent then
		return
	end
	commitSelected(true)
	local currentState = CustomBuildingConfig.ReadState(selectedModel)
	local nextState = CustomBuildingConfig.GetDuplicateState(selectedModel.Name, currentState, activeAxis, 1, useMirror == true)
	nextState.Color = selectedColor
	nextState.Material = selectedMaterial
	local ok, result = pcall(function()
		return RequestPlaceItem:InvokeServer(CustomBuildingConfig.BuildPlacementPayload(selectedModel.Name, nextState))
	end)
	if ok and type(result) == "table" and result.success and result.uuid then
		local model = findModelByUuid(result.uuid)
		if model then
			setSelection(model)
		else
			task.delay(0.2, function()
				local delayed = findModelByUuid(result.uuid)
				if delayed then
					setSelection(delayed)
				end
			end)
		end
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

local function placePreviewPiece()
	if not previewGhost or not placingItemName then
		return
	end
	local state = CustomBuildingConfig.ReadState(previewGhost)
	state.Color = selectedColor
	state.Material = selectedMaterial
	local payload = CustomBuildingConfig.BuildPlacementPayload(placingItemName, state)
	local ok, result = pcall(function()
		return RequestPlaceItem:InvokeServer(payload)
	end)
	if ok and type(result) == "table" and result.success then
		clearPreviewGhost()
		if result.uuid then
			local model = findModelByUuid(result.uuid)
			if model then
				setSelection(model)
			else
				task.delay(0.2, function()
					local delayed = findModelByUuid(result.uuid)
					if delayed then
						setSelection(delayed)
					end
				end)
			end
		end
	end
end

local function closeBuilder(reopenBuild)
	if selectedModel and selectedModel.Parent then
		commitSelected(true)
	end
	dragging = false
	hoveredModel = nil
	setSelection(nil)
	clearPreviewGhost()
	Highlight.Adornee = nil
	Gui.Enabled = false
	isBuilderOpen = false
	ModeState.Value = ""
	disableFreecam()
	if reopenBuild and openedFromButton then
		BuildFrame.Visible = true
	end
	openedFromButton = false
end

local function openBuilder(fromButton)
	if not isBuilderOpen and ModeState.Value ~= "" and ModeState.Value ~= "Builder" then
		return
	end
	openedFromButton = fromButton == true or BuildFrame.Visible
	isBuilderOpen = true
	ModeState.Value = "Builder"
	Gui.Enabled = true
	ClosePanels:Fire("Builder")
	BuildFrame.Visible = false
	enableFreecam()
	refreshAxisVisuals()
	refreshPaletteVisuals()
	refreshStatus()
end

local function beginDragSelection()
	if not selectedModel or not selectedModel.Parent then
		return
	end
	dragging = true
	local state = CustomBuildingConfig.ReadState(selectedModel)
	dragPlaneY = state.Position.Y
	local planeHit = getPlaneHit(dragPlaneY)
	dragOffset = planeHit and (state.Position - planeHit) or Vector3.zero
end

for _, itemName in ipairs(CustomBuildingConfig.GetItemNames()) do
	local newButton = createActionButton(NewShapesFrame, CustomBuildingConfig.GetShapeLabel(itemName), Color3.fromRGB(30, 37, 52))
	newButton.MouseButton1Click:Connect(function()
		createPreviewGhost(itemName)
	end)
	table.insert(shapeButtons, newButton)

	local selectedButton = createActionButton(SelectedShapesFrame, CustomBuildingConfig.GetShapeLabel(itemName), Color3.fromRGB(30, 37, 52))
	selectedButton.MouseButton1Click:Connect(function()
		morphSelected(itemName)
	end)
	table.insert(selectedShapeButtons, selectedButton)
end

axisButtons.X = createActionButton(TransformFrame, "Axis X", Color3.fromRGB(92, 148, 255))
axisButtons.Y = createActionButton(TransformFrame, "Axis Y", Color3.fromRGB(30, 37, 52))
axisButtons.Z = createActionButton(TransformFrame, "Axis Z", Color3.fromRGB(30, 37, 52))
for axisName, button in pairs(axisButtons) do
	button.MouseButton1Click:Connect(function()
		activeAxis = axisName
		refreshAxisVisuals()
		refreshStatus()
	end)
end

createActionButton(TransformFrame, "Rotate -", Color3.fromRGB(30, 37, 52)).MouseButton1Click:Connect(function()
	if not selectedModel or not selectedModel.Parent then return end
	local state = CustomBuildingConfig.ReadState(selectedModel)
	state.Yaw = state.Yaw - CustomBuildingConfig.ROTATION_SNAP
	applySelectedState(state, true)
end)

createActionButton(TransformFrame, "Rotate +", Color3.fromRGB(30, 37, 52)).MouseButton1Click:Connect(function()
	if not selectedModel or not selectedModel.Parent then return end
	local state = CustomBuildingConfig.ReadState(selectedModel)
	state.Yaw = state.Yaw + CustomBuildingConfig.ROTATION_SNAP
	applySelectedState(state, true)
end)

createActionButton(TransformFrame, "Move Up", Color3.fromRGB(30, 37, 52)).MouseButton1Click:Connect(function()
	if not selectedModel or not selectedModel.Parent then return end
	local state = CustomBuildingConfig.ReadState(selectedModel)
	state.Position = CustomBuildingConfig.SnapVector3(state.Position + Vector3.new(0, CustomBuildingConfig.DEFAULT_STEP, 0))
	applySelectedState(state, true)
end)

createActionButton(TransformFrame, "Move Down", Color3.fromRGB(30, 37, 52)).MouseButton1Click:Connect(function()
	if not selectedModel or not selectedModel.Parent then return end
	local state = CustomBuildingConfig.ReadState(selectedModel)
	state.Position = CustomBuildingConfig.SnapVector3(state.Position - Vector3.new(0, CustomBuildingConfig.DEFAULT_STEP, 0))
	applySelectedState(state, true)
end)

createActionButton(TransformFrame, "Duplicate", Color3.fromRGB(25, 90, 68)).MouseButton1Click:Connect(function()
	duplicateSelected(false)
end)

createActionButton(TransformFrame, "Mirror Copy", Color3.fromRGB(72, 58, 118)).MouseButton1Click:Connect(function()
	duplicateSelected(true)
end)

createActionButton(TransformFrame, "Nudge -", Color3.fromRGB(30, 37, 52)).MouseButton1Click:Connect(function()
	nudgeSelected(-1)
end)

createActionButton(TransformFrame, "Nudge +", Color3.fromRGB(30, 37, 52)).MouseButton1Click:Connect(function()
	nudgeSelected(1)
end)

createActionButton(TransformFrame, "Scale -", Color3.fromRGB(30, 37, 52)).MouseButton1Click:Connect(function()
	scaleSelected(-1)
end)

createActionButton(TransformFrame, "Scale +", Color3.fromRGB(30, 37, 52)).MouseButton1Click:Connect(function()
	scaleSelected(1)
end)

createActionButton(TransformFrame, "Ground", Color3.fromRGB(72, 58, 118)).MouseButton1Click:Connect(function()
	groundSelected()
end)

createActionButton(TransformFrame, "Delete", Color3.fromRGB(170, 60, 60)).MouseButton1Click:Connect(function()
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
		paintSelected()
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
		paintSelected()
	end)
	table.insert(materialButtons, { Button = button, Material = materialName })
end

refreshAxisVisuals()
refreshPaletteVisuals()
refreshStatus()

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

RunService.RenderStepped:Connect(function(dt)
	if not isBuilderOpen then
		return
	end

	local controls = getControls()
	if controls and FreecamPart then
		local moveVector = controls:GetMoveVector()
		local cameraCFrame = workspace.CurrentCamera.CFrame
		local look = Vector3.new(cameraCFrame.LookVector.X, 0, cameraCFrame.LookVector.Z)
		if look.Magnitude < 1e-3 then
			look = Vector3.new(0, 0, -1)
		else
			look = look.Unit
		end
		local right = Vector3.new(cameraCFrame.RightVector.X, 0, cameraCFrame.RightVector.Z)
		if right.Magnitude < 1e-3 then
			right = Vector3.new(1, 0, 0)
		else
			right = right.Unit
		end
		local vertical = 0
		if UserInputService:IsKeyDown(Enum.KeyCode.Space) then
			vertical += 1
		end
		if UserInputService:IsKeyDown(Enum.KeyCode.LeftControl) or UserInputService:IsKeyDown(Enum.KeyCode.RightControl) then
			vertical -= 1
		end
		local speed = (UserInputService:IsKeyDown(Enum.KeyCode.LeftShift) or UserInputService:IsKeyDown(Enum.KeyCode.RightShift)) and 140 or 60
		local moveDirection = (look * -moveVector.Z) + (right * moveVector.X) + Vector3.new(0, vertical, 0)
		if moveDirection.Magnitude > 0 then
			FreecamPart.Position += moveDirection * speed * dt
		end
	end

	local rayResult = getMouseRayResult()
	if not dragging then
		hoveredModel = rayResult and rayResult.Instance and findCustomBlockModel(rayResult.Instance) or nil
	end
	Highlight.Adornee = selectedModel or hoveredModel

	if previewGhost then
		local hitPosition = rayResult and rayResult.Position or (FreecamPart and FreecamPart.Position or Vector3.zero)
		local bbCF, bbSize = previewGhost:GetBoundingBox()
		local pivotPos = previewGhost:GetPivot().Position
		local bottomOffset = pivotPos.Y - (bbCF.Position.Y - bbSize.Y / 2)
		if bottomOffset > 50 or bottomOffset < -10 then
			bottomOffset = 0
		end
		hitPosition += Vector3.new(0, bottomOffset, 0)
		hitPosition = CustomBuildingConfig.SnapVector3(hitPosition)
		previewGhost:PivotTo(CustomBuildingConfig.BuildCFrame(hitPosition, currentPlacementRotation))
	end

	refreshStatus()
end)

UserInputService.InputBegan:Connect(function(input, gameProcessed)
	if gameProcessed then
		return
	end


	if not isBuilderOpen then
		return
	end

	if input.KeyCode == Enum.KeyCode.Z then
		if previewGhost then
			clearPreviewGhost()
		else
			closeBuilder(true)
		end
		return
	end

	if input.KeyCode == Enum.KeyCode.Q or input.KeyCode == Enum.KeyCode.Escape then
		closeBuilder(true)
		return
	end

	if input.KeyCode == Enum.KeyCode.One then
		activeAxis = "X"
		refreshAxisVisuals()
		refreshStatus()
		return
	elseif input.KeyCode == Enum.KeyCode.Two then
		activeAxis = "Y"
		refreshAxisVisuals()
		refreshStatus()
		return
	elseif input.KeyCode == Enum.KeyCode.Three then
		activeAxis = "Z"
		refreshAxisVisuals()
		refreshStatus()
		return
	end

	if previewGhost then
		if input.KeyCode == Enum.KeyCode.R then
			currentPlacementRotation += CustomBuildingConfig.ROTATION_SNAP
			return
		elseif input.KeyCode == Enum.KeyCode.T or input.KeyCode == Enum.KeyCode.Q then
			currentPlacementRotation -= CustomBuildingConfig.ROTATION_SNAP
			return
		end
	end

	if selectedModel and selectedModel.Parent then
		if input.KeyCode == Enum.KeyCode.R then
			local state = CustomBuildingConfig.ReadState(selectedModel)
			state.Yaw += CustomBuildingConfig.ROTATION_SNAP
			applySelectedState(state, true)
			return
		elseif input.KeyCode == Enum.KeyCode.T or input.KeyCode == Enum.KeyCode.Q then
			local state = CustomBuildingConfig.ReadState(selectedModel)
			state.Yaw -= CustomBuildingConfig.ROTATION_SNAP
			applySelectedState(state, true)
			return
		elseif input.KeyCode == Enum.KeyCode.LeftBracket then
			nudgeSelected(-1)
			return
		elseif input.KeyCode == Enum.KeyCode.RightBracket then
			nudgeSelected(1)
			return
		elseif input.KeyCode == Enum.KeyCode.Minus then
			scaleSelected(-1)
			return
		elseif input.KeyCode == Enum.KeyCode.Equals then
			scaleSelected(1)
			return
		elseif input.KeyCode == Enum.KeyCode.U then
			local state = CustomBuildingConfig.ReadState(selectedModel)
			state.Position = CustomBuildingConfig.SnapVector3(state.Position + Vector3.new(0, CustomBuildingConfig.DEFAULT_STEP, 0))
			applySelectedState(state, true)
			return
		elseif input.KeyCode == Enum.KeyCode.J then
			local state = CustomBuildingConfig.ReadState(selectedModel)
			state.Position = CustomBuildingConfig.SnapVector3(state.Position - Vector3.new(0, CustomBuildingConfig.DEFAULT_STEP, 0))
			applySelectedState(state, true)
			return
		elseif input.KeyCode == Enum.KeyCode.G then
			groundSelected()
			return
		elseif input.KeyCode == Enum.KeyCode.C then
			duplicateSelected(false)
			return
		elseif input.KeyCode == Enum.KeyCode.M then
			duplicateSelected(true)
			return
		elseif input.KeyCode == Enum.KeyCode.Delete or input.KeyCode == Enum.KeyCode.Backspace then
			deleteSelected()
			return
		end
	end

	if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
		if previewGhost then
			placePreviewPiece()
			return
		end
		if hoveredModel then
			setSelection(hoveredModel)
			beginDragSelection()
		else
			setSelection(nil)
		end
	end
end)

UserInputService.InputChanged:Connect(function(input)
	if not isBuilderOpen then
		return
	end

	if input.UserInputType == Enum.UserInputType.MouseWheel and selectedModel and selectedModel.Parent and not dragging then
		local delta = input.Position.Z
		if delta == 0 then
			return
		end
		local step = (UserInputService:IsKeyDown(Enum.KeyCode.LeftShift) or UserInputService:IsKeyDown(Enum.KeyCode.RightShift)) and CustomBuildingConfig.FINE_STEP or CustomBuildingConfig.DEFAULT_STEP
		local signedStep = delta > 0 and step or -step
		local state = CustomBuildingConfig.ReadState(selectedModel)
		local size = state.Size
		if activeAxis == "X" then
			size = Vector3.new(size.X + signedStep, size.Y, size.Z)
		elseif activeAxis == "Y" then
			size = Vector3.new(size.X, size.Y + signedStep, size.Z)
		else
			size = Vector3.new(size.X, size.Y, size.Z + signedStep)
		end
		state.Size = CustomBuildingConfig.ClampSize(size)
		applySelectedState(state, false)
		return
	end

	if dragging and selectedModel and selectedModel.Parent and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
		local planeHit = getPlaneHit(dragPlaneY)
		if planeHit then
			local state = CustomBuildingConfig.ReadState(selectedModel)
			state.Position = CustomBuildingConfig.SnapVector3(planeHit + dragOffset)
			CustomBuildingConfig.ApplyState(selectedModel, state)
			refreshStatus()
		end
	end
end)

UserInputService.InputEnded:Connect(function(input)
	if not dragging or not selectedModel or not selectedModel.Parent then
		return
	end
	if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
		dragging = false
		commitSelected(true)
		refreshStatus()
	end
end)