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
local PaintButton = BuildFrame:WaitForChild("Buttons"):WaitForChild("Paint")

local Events = ReplicatedStorage:WaitForChild("Events")
local ClosePanels = Events:FindFirstChild("ClosePanels")
if not ClosePanels then
	ClosePanels = Instance.new("BindableEvent")
	ClosePanels.Name = "ClosePanels"
	ClosePanels.Parent = Events
end

local CustomBuildingConfig = require(ReplicatedStorage:WaitForChild("CustomBuildingConfig"))
local CustomBuildRequest = Events:WaitForChild("CustomBuildRequest")

local ModeState = PlayerGui:FindFirstChild("ModeState") or Instance.new("StringValue")
ModeState.Name = "ModeState"
ModeState.Parent = PlayerGui

local isPainting = false
local openedFromButton = false
local hoveredModel = nil
local selectedColor = CustomBuildingConfig.DEFAULT_COLOR
local selectedColorName = CustomBuildingConfig.PALETTE_COLORS[1] and CustomBuildingConfig.PALETTE_COLORS[1].Name or "Custom"
local selectedMaterial = CustomBuildingConfig.DEFAULT_MATERIAL
local colorButtons = {}
local materialButtons = {}

local Highlight = Instance.new("Highlight")
Highlight.Name = "PaintHighlight"
Highlight.FillColor = Color3.fromRGB(92, 148, 255)
Highlight.OutlineColor = Color3.fromRGB(255, 255, 255)
Highlight.FillTransparency = 0.45
Highlight.Parent = PlayerGui

local PaintGui = Instance.new("ScreenGui")
PaintGui.Name = "BuildPaintHud"
PaintGui.ResetOnSpawn = false
PaintGui.Enabled = false
PaintGui.Parent = PlayerGui

local Panel = Instance.new("Frame")
Panel.AnchorPoint = Vector2.new(1, 1)
Panel.Position = UDim2.new(1, -20, 1, -20)
Panel.Size = UDim2.new(0, 360, 0, 280)
Panel.BackgroundColor3 = Color3.fromRGB(16, 20, 30)
Panel.BackgroundTransparency = 0.06
Panel.BorderSizePixel = 0
Panel.Parent = PaintGui
Instance.new("UICorner", Panel).CornerRadius = UDim.new(0, 12)
local PanelStroke = Instance.new("UIStroke")
PanelStroke.Color = Color3.fromRGB(92, 148, 255)
PanelStroke.Transparency = 0.15
PanelStroke.Thickness = 1.5
PanelStroke.Parent = Panel

local TitleLabel = Instance.new("TextLabel")
TitleLabel.BackgroundTransparency = 1
TitleLabel.Position = UDim2.new(0, 14, 0, 12)
TitleLabel.Size = UDim2.new(1, -90, 0, 22)
TitleLabel.Font = Enum.Font.GothamBold
TitleLabel.Text = "Paint Builder Piece"
TitleLabel.TextSize = 16
TitleLabel.TextColor3 = Color3.fromRGB(244, 247, 255)
TitleLabel.TextXAlignment = Enum.TextXAlignment.Left
TitleLabel.Parent = Panel

local ExitButton = Instance.new("TextButton")
ExitButton.AnchorPoint = Vector2.new(1, 0)
ExitButton.Position = UDim2.new(1, -12, 0, 10)
ExitButton.Size = UDim2.new(0, 72, 0, 28)
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

local HintLabel = Instance.new("TextLabel")
HintLabel.BackgroundTransparency = 1
HintLabel.Position = UDim2.new(0, 14, 0, 38)
HintLabel.Size = UDim2.new(1, -28, 0, 16)
HintLabel.Font = Enum.Font.GothamMedium
HintLabel.Text = "Pick a color and material, then click any Builder Piece. Press Z or Q to exit."
HintLabel.TextSize = 12
HintLabel.TextColor3 = Color3.fromRGB(198, 208, 227)
HintLabel.TextXAlignment = Enum.TextXAlignment.Left
HintLabel.TextWrapped = true
HintLabel.Parent = Panel

local SelectionLabel = Instance.new("TextLabel")
SelectionLabel.BackgroundTransparency = 1
SelectionLabel.Position = UDim2.new(0, 14, 1, -24)
SelectionLabel.Size = UDim2.new(1, -28, 0, 16)
SelectionLabel.Font = Enum.Font.GothamMedium
SelectionLabel.Text = "Hover a Builder Piece to paint it."
SelectionLabel.TextSize = 12
SelectionLabel.TextColor3 = Color3.fromRGB(133, 154, 191)
SelectionLabel.TextXAlignment = Enum.TextXAlignment.Left
SelectionLabel.Parent = Panel

local ColorsLabel = Instance.new("TextLabel")
ColorsLabel.BackgroundTransparency = 1
ColorsLabel.Position = UDim2.new(0, 14, 0, 68)
ColorsLabel.Size = UDim2.new(1, -28, 0, 16)
ColorsLabel.Font = Enum.Font.GothamBold
ColorsLabel.Text = "Colors"
ColorsLabel.TextSize = 13
ColorsLabel.TextColor3 = Color3.fromRGB(240, 244, 252)
ColorsLabel.TextXAlignment = Enum.TextXAlignment.Left
ColorsLabel.Parent = Panel

local ColorsFrame = Instance.new("Frame")
ColorsFrame.BackgroundTransparency = 1
ColorsFrame.Position = UDim2.new(0, 14, 0, 88)
ColorsFrame.Size = UDim2.new(1, -28, 0, 72)
ColorsFrame.Parent = Panel
local ColorGrid = Instance.new("UIGridLayout")
ColorGrid.CellSize = UDim2.new(0, 60, 0, 28)
ColorGrid.CellPadding = UDim2.new(0, 6, 0, 6)
ColorGrid.Parent = ColorsFrame

local MaterialsLabel = Instance.new("TextLabel")
MaterialsLabel.BackgroundTransparency = 1
MaterialsLabel.Position = UDim2.new(0, 14, 0, 168)
MaterialsLabel.Size = UDim2.new(1, -28, 0, 16)
MaterialsLabel.Font = Enum.Font.GothamBold
MaterialsLabel.Text = "Materials"
MaterialsLabel.TextSize = 13
MaterialsLabel.TextColor3 = Color3.fromRGB(240, 244, 252)
MaterialsLabel.TextXAlignment = Enum.TextXAlignment.Left
MaterialsLabel.Parent = Panel

local MaterialsFrame = Instance.new("Frame")
MaterialsFrame.BackgroundTransparency = 1
MaterialsFrame.Position = UDim2.new(0, 14, 0, 188)
MaterialsFrame.Size = UDim2.new(1, -28, 0, 58)
MaterialsFrame.Parent = Panel
local MaterialGrid = Instance.new("UIGridLayout")
MaterialGrid.CellSize = UDim2.new(0, 106, 0, 24)
MaterialGrid.CellPadding = UDim2.new(0, 6, 0, 6)
MaterialGrid.Parent = MaterialsFrame

local function setButtonStroke(button, activeColor)
	local stroke = button:FindFirstChildOfClass("UIStroke")
	if stroke then
		stroke.Color = activeColor
		stroke.Thickness = 2
		stroke.Transparency = 0
	end
end

local function clearButtonStroke(button)
	local stroke = button:FindFirstChildOfClass("UIStroke")
	if stroke then
		stroke.Transparency = 1
	end
end

local function refreshPaletteVisuals()
	for _, entry in ipairs(colorButtons) do
		if entry.Color == selectedColor then
			setButtonStroke(entry.Button, Color3.fromRGB(255, 255, 255))
		else
			clearButtonStroke(entry.Button)
		end
	end
	for _, entry in ipairs(materialButtons) do
		if entry.Material == selectedMaterial then
			setButtonStroke(entry.Button, Color3.fromRGB(92, 148, 255))
		else
			clearButtonStroke(entry.Button)
		end
	end
end

for _, swatch in ipairs(CustomBuildingConfig.PALETTE_COLORS) do
	local button = Instance.new("TextButton")
	button.BackgroundColor3 = swatch.Color
	button.BorderSizePixel = 0
	button.Text = swatch.Name
	button.TextSize = 11
	button.Font = Enum.Font.GothamBold
	button.TextColor3 = swatch.Color:Lerp(Color3.new(0, 0, 0), 0.75)
	button.Parent = ColorsFrame
	Instance.new("UICorner", button).CornerRadius = UDim.new(0, 8)
	local stroke = Instance.new("UIStroke")
	stroke.Transparency = 1
	stroke.Parent = button
	button.MouseButton1Click:Connect(function()
		selectedColor = swatch.Color
		selectedColorName = swatch.Name
		refreshPaletteVisuals()
	end)
	table.insert(colorButtons, {Button = button, Color = swatch.Color})
end

for _, materialName in ipairs(CustomBuildingConfig.PALETTE_MATERIALS) do
	local button = Instance.new("TextButton")
	button.BackgroundColor3 = Color3.fromRGB(24, 30, 42)
	button.BorderSizePixel = 0
	button.Text = materialName
	button.TextSize = 11
	button.Font = Enum.Font.GothamBold
	button.TextColor3 = Color3.fromRGB(240, 244, 252)
	button.Parent = MaterialsFrame
	Instance.new("UICorner", button).CornerRadius = UDim.new(0, 8)
	local stroke = Instance.new("UIStroke")
	stroke.Transparency = 1
	stroke.Parent = button
	button.MouseButton1Click:Connect(function()
		selectedMaterial = materialName
		refreshPaletteVisuals()
	end)
	table.insert(materialButtons, {Button = button, Material = materialName})
end
refreshPaletteVisuals()

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

local function getMouseTarget()
	local mousePos = UserInputService:GetMouseLocation()
	local ray = workspace.CurrentCamera:ScreenPointToRay(mousePos.X, mousePos.Y)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = {Player.Character}
	local result = workspace:Raycast(ray.Origin, ray.Direction * 2000, params)
	if result and result.Instance then
		return findCustomBlockModel(result.Instance)
	end
	return nil
end

local function stopPainting(reopenBuild)
	isPainting = false
	hoveredModel = nil
	Highlight.Adornee = nil
	PaintGui.Enabled = false
	ModeState.Value = ""
	if reopenBuild and openedFromButton then
		BuildFrame.Visible = true
	end
	openedFromButton = false
end

local function startPainting(fromButton)
	if not isPainting and ModeState.Value ~= "" and ModeState.Value ~= "Painting" then
		return
	end
	openedFromButton = fromButton == true or BuildFrame.Visible
	isPainting = true
	ModeState.Value = "Painting"
	PaintGui.Enabled = true
	ClosePanels:Fire("Paint")
	BuildFrame.Visible = false
end

local function paintHoveredModel()
	if not hoveredModel then
		return
	end
	local optimistic = CustomBuildingConfig.ReadState(hoveredModel)
	optimistic.Color = selectedColor
	optimistic.Material = selectedMaterial
	CustomBuildingConfig.ApplyState(hoveredModel, optimistic)
	local ok, result = pcall(function()
		return CustomBuildRequest:InvokeServer("Paint", hoveredModel, {
			Color = selectedColor,
			Material = selectedMaterial,
		})
	end)
	if ok and type(result) == "table" and result.success and result.state then
		CustomBuildingConfig.ApplyState(hoveredModel, result.state)
	end
end

ExitButton.Activated:Connect(function()
	if isPainting then
		stopPainting(true)
	end
end)

PaintButton.MouseButton1Click:Connect(function()
	if isPainting then
		stopPainting(true)
	else
		startPainting(true)
	end
end)

ClosePanels.Event:Connect(function(source)
	if source == "Paint" then
		return
	end
	if isPainting then
		stopPainting(false)
	end
end)

RunService.RenderStepped:Connect(function()
	if not isPainting then
		return
	end
	hoveredModel = getMouseTarget()
	Highlight.Adornee = hoveredModel
	if hoveredModel then
		SelectionLabel.Text = string.format("Target: %s | Color: %s | Material: %s", hoveredModel.Name, selectedColorName, selectedMaterial)
	else
		SelectionLabel.Text = string.format("Hover a Builder Piece | Color: %s | Material: %s", selectedColorName, selectedMaterial)
	end
end)

local function isPointerBlockedByGui(pointer)
	for _, obj in ipairs(PlayerGui:GetGuiObjectsAtPosition(pointer.X, pointer.Y)) do
		if obj.Visible then
			return true
		end
	end
	return false
end

UserInputService.InputBegan:Connect(function(input, gameProcessed)
	if gameProcessed or not isPainting then
		return
	end

	if input.KeyCode == Enum.KeyCode.Z or input.KeyCode == Enum.KeyCode.Q or input.KeyCode == Enum.KeyCode.Escape then
		stopPainting(true)
		return
	end

	if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
		local pointer = Vector2.new(input.Position.X, input.Position.Y)
		if isPointerBlockedByGui(pointer) then return end
		paintHoveredModel()
	end
end)