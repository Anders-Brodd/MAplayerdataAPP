--[[
	🖥️ TERRAIN CONTROLLER V3.1
	StarterPlayerScripts/TerrainController
	
	Does NOT build UI. Connects to existing StarterGui/TerrainUI.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Player = Players.LocalPlayer
local PlayerGui = Player:WaitForChild("PlayerGui")
local Camera = Workspace.CurrentCamera
local Mouse = Player:GetMouse()

local function getCurrentCamera()
	local current = Workspace.CurrentCamera
	if current then
		Camera = current
		return current
	end
	return Camera
end

-- // 📡 NETWORKING //
local Events = ReplicatedStorage:WaitForChild("Events")
local TerrainEvent = Events:WaitForChild("TerrainEvent", 5)
local MainHUD = PlayerGui:WaitForChild("MainHUD", 10)
local Dock = MainHUD and MainHUD:WaitForChild("Dock", 10)

-- // ⚙️ CONFIGURATION //
local CONFIG = {
	MinSize = 4,
	MaxSize = 60,
	MinStrength = 0.25,
	MaxStrength = 2,
	StrengthStep = 0.25,
	TickRate = 0.1,

	Colors = {
		ButtonNormal = Color3.fromRGB(45, 45, 50),
		ButtonHover = Color3.fromRGB(65, 65, 70),
		ButtonActive = Color3.fromRGB(0, 122, 255),
		TextPrimary = Color3.fromRGB(255, 255, 255),
		TextSecondary = Color3.fromRGB(180, 180, 180),

		Raise = Color3.fromRGB(76, 217, 100),
		Lower = Color3.fromRGB(255, 59, 48),
		Flatten = Color3.fromRGB(0, 170, 255),
		Smooth = Color3.fromRGB(170, 0, 255),
		Paint = Color3.fromRGB(255, 170, 0),
		None = Color3.fromRGB(255, 255, 255)
	},

	Materials = {
		{Name = "Snow", Mat = Enum.Material.Snow},
		{Name = "Rock", Mat = Enum.Material.Rock},
		{Name = "Ice", Mat = Enum.Material.Ice},
		{Name = "Grass", Mat = Enum.Material.Grass},
		{Name = "Mud", Mat = Enum.Material.Mud},
		{Name = "Concrete", Mat = Enum.Material.Concrete}
	},

	BaseCosts = { Raise = 15, Lower = 15, Flatten = 20, Smooth = 10, Paint = 5, None = 0 }
}

-- // STATE //
local isEquipped = false
local currentTool = "None"
local currentMaterial = Enum.Material.Snow
local brushSize = 12
local brushStrength = 1
local isMouseDown = false
local isMobileBrushActive = false
local mobileApplyInput = nil
local lastTouchAimPosition = nil
local lastTouchAimTimestamp = 0
local TOUCH_AIM_TIMEOUT = 0.45
local fireTerrainEdit
local beginTerrainStroke
local lastNormal = Vector3.new(0,1,0)
local currentBrushNormal = Vector3.new(0,1,0)
local userLockedFlattenY = nil -- When set, flatten always uses this height
local flattenPlaneY = nil
local lastSafeCharacterCF = nil
local lastSafetyCheck = 0
local transientCostStatusText = nil
local transientCostStatusColor = nil
local transientCostStatusUntil = 0
local lastSelfBlockWarningAt = 0
local lastTerrainSafetyRescueAt = 0

local function clampBrushStrengthValue(value)
	local stepped = math.floor(((tonumber(value) or 1) / CONFIG.StrengthStep) + 0.5) * CONFIG.StrengthStep
	return math.clamp(stepped, CONFIG.MinStrength, CONFIG.MaxStrength)
end

local function getBrushStrengthPercent()
	return math.floor((brushStrength * 100) + 0.5)
end

-- // VISUALS //
local CursorPart = nil
local CursorLight = nil

-- // UI REFERENCE VARIABLES //
local ScreenGui, MainFrame, ToolContainer, MaterialContainer, CostLabel, SizeLabel
local StrengthValueLabel
local MobileApplyButton, MobileStatusLabel, MobileReticle
local BuildFrameRef = nil
local openedFromButton = false
local toggleUI = nil
local terrainViewportConnection = nil
local applyTerrainResponsiveLayout = nil

-- // HELPER: Tween wrapper //
local function tween(obj, props, info)
	TweenService:Create(obj, info or TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), props):Play()
end

local function connectGuiButton(button, callback)
	if not button or not button:IsA("GuiButton") then return end
	button.Active = true
	button.Selectable = true
	button.AutoButtonColor = true

	local lastPress = 0
	local function fireOnce()
		local now = os.clock()
		if (now - lastPress) < 0.2 then return end
		lastPress = now
		callback()
	end

	-- Activated is primary, but this UI stack occasionally misses it on specific buttons.
	-- Bind legacy click/touch events as fallback.
	button.Activated:Connect(fireOnce)
	button.MouseButton1Click:Connect(fireOnce)
	if button:IsA("TextButton") or button:IsA("ImageButton") then
		button.TouchTap:Connect(function()
			fireOnce()
		end)
	end
end

local function isPointInsideGuiObject(guiObject, point)
	if not guiObject or not guiObject:IsA("GuiObject") then
		return false
	end
	local absPos = guiObject.AbsolutePosition
	local absSize = guiObject.AbsoluteSize
	return point.X >= absPos.X and point.Y >= absPos.Y and point.X <= (absPos.X + absSize.X) and point.Y <= (absPos.Y + absSize.Y)
end

local function setTerrainModeState(isEnabled)
	local modeState = PlayerGui:FindFirstChild("ModeState")
	if not modeState then return end
	modeState.Value = isEnabled and "Terraforming" or ""
end

local function isMobileTerrainMode()
	if not UserInputService.TouchEnabled then
		return false
	end
	if not UserInputService.MouseEnabled or not UserInputService.KeyboardEnabled then
		return true
	end
	local viewport = Camera and Camera.ViewportSize
	if viewport and viewport.X > 0 then
		return viewport.X <= 1366
	end
	return true
end

local function updateTouchAimFromInput(input)
	if not input or input.UserInputType ~= Enum.UserInputType.Touch then
		return
	end
	local inputPos = input.Position
	if typeof(inputPos) ~= "Vector3" then
		return
	end
	lastTouchAimPosition = Vector2.new(inputPos.X, inputPos.Y)
	lastTouchAimTimestamp = os.clock()
end

local function getTerrainAimScreenPosition()
	if isMobileTerrainMode() then
		local camera = getCurrentCamera()
		local viewport = camera and camera.ViewportSize or Vector2.new(0, 0)
		return Vector2.new(viewport.X * 0.5, viewport.Y * 0.5)
	end
	if lastTouchAimPosition and (os.clock() - lastTouchAimTimestamp) <= TOUCH_AIM_TIMEOUT then
		return lastTouchAimPosition
	end
	local mousePos = UserInputService:GetMouseLocation()
	return Vector2.new(mousePos.X, mousePos.Y)
end

local function getTerrainRayResult()
	local camera = getCurrentCamera()
	if not camera then
		return nil
	end
	local rayParams = RaycastParams.new()
	rayParams.FilterType = Enum.RaycastFilterType.Include
	rayParams.FilterDescendantsInstances = {Workspace.Terrain}

	local aim = getTerrainAimScreenPosition()
	local ray = camera:ScreenPointToRay(aim.X, aim.Y)
	return Workspace:Raycast(ray.Origin, ray.Direction * 2000, rayParams)
end

local function updateMobileTerrainControls()
	if MobileReticle then
		MobileReticle.Visible = isEquipped and isMobileTerrainMode()
	end
	if not MobileApplyButton then
		return
	end

	local canApply = isEquipped and currentTool ~= "None"
	MobileApplyButton.Visible = isEquipped and isMobileTerrainMode()
	MobileApplyButton.Active = canApply
	MobileApplyButton.AutoButtonColor = canApply
	MobileApplyButton.BackgroundColor3 = canApply and (isMouseDown and Color3.fromRGB(56, 170, 255) or Color3.fromRGB(33, 115, 215)) or Color3.fromRGB(70, 74, 82)
	MobileApplyButton.Text = isMouseDown and "RELEASE" or "HOLD APPLY"
	if MobileStatusLabel then
		if not isEquipped then
			MobileStatusLabel.Visible = false
		elseif currentTool == "None" then
			MobileStatusLabel.Visible = true
			MobileStatusLabel.Text = "Choose a terrain tool first"
		elseif isMouseDown then
			MobileStatusLabel.Visible = true
			if currentTool == "Flatten" and flattenPlaneY ~= nil then
				MobileStatusLabel.Text = string.format("Flatten plane locked | Size %d | Strength %d%%", brushSize, getBrushStrengthPercent())
			else
				MobileStatusLabel.Text = string.format("Applying %s | Size %d | Strength %d%%", currentTool, brushSize, getBrushStrengthPercent())
			end
		else
			MobileStatusLabel.Visible = true
			MobileStatusLabel.Text = string.format("Aim with camera and hold APPLY | Size %d | Strength %d%%", brushSize, getBrushStrengthPercent())
		end
	end
	if MobileReticle then
		MobileReticle.BackgroundColor3 = currentTool ~= "None" and (CONFIG.Colors[currentTool] or Color3.new(1, 1, 1)) or Color3.fromRGB(255, 255, 255)
	end
end

local function setMobileBrushState(isActive)
	isMobileBrushActive = isActive
	if not isActive then
		mobileApplyInput = nil
	end
	if isMobileTerrainMode() then
		isMouseDown = isActive and isEquipped and currentTool ~= "None"
		if isMouseDown and (currentTool == "Flatten" or currentTool == "Smooth") then
			local result = getTerrainRayResult()
			if result then
				lastNormal = result.Normal
				if currentTool == "Flatten" then
					if userLockedFlattenY then
						flattenPlaneY = userLockedFlattenY
					else
						flattenPlaneY = result.Position.Y
					end
				end
			end
		elseif not isMouseDown then
			if not userLockedFlattenY then flattenPlaneY = nil end
		end
		updateMobileTerrainControls()
		applyTerrainResponsiveLayout(currentTool == "Paint")
		if terrainViewportConnection then
			terrainViewportConnection:Disconnect()
			terrainViewportConnection = nil
		end
		local currentCamera = Workspace.CurrentCamera or Camera
		if currentCamera then
			terrainViewportConnection = currentCamera:GetPropertyChangedSignal("ViewportSize"):Connect(function()
				applyTerrainResponsiveLayout(currentTool == "Paint")
			end)
		end
	end
end

local function isApplyPressInput(input)
	return input and (input.UserInputType == Enum.UserInputType.Touch or input.UserInputType == Enum.UserInputType.MouseButton1)
end

local function beginMobileApply(input)
	if not isApplyPressInput(input) then
		return
	end
	updateTouchAimFromInput(input)
	if not (isMobileTerrainMode() and isEquipped and currentTool ~= "None") then
		updateMobileTerrainControls()
		return
	end
	mobileApplyInput = input
	setMobileBrushState(true)
	if beginTerrainStroke then
		beginTerrainStroke(input)
	end
end

local function endMobileApply(input)
	if input and mobileApplyInput and input ~= mobileApplyInput then
		local sameType = input.UserInputType == mobileApplyInput.UserInputType
		if not sameType then
			return
		end
	end
	setMobileBrushState(false)
end

local function getTerrainViewportSize()
	local currentCamera = Workspace.CurrentCamera or Camera
	local viewport = currentCamera and currentCamera.ViewportSize or Vector2.new(1280, 720)
	if viewport.X <= 0 or viewport.Y <= 0 then
		viewport = Vector2.new(1280, 720)
	end
	return viewport
end

applyTerrainResponsiveLayout = function(showMaterials)
	if not MainFrame then
		return
	end
	if not isMobileTerrainMode() then
		return
	end

	local viewport = getTerrainViewportSize()
	local maxWidth = math.max(320, math.floor(viewport.X - 24))
	local width = math.min(math.clamp(math.floor(viewport.X * 0.68), 320, 560), maxWidth)
	local height = showMaterials and 228 or 174
	MainFrame.Size = UDim2.new(0, width, 0, height)
	MainFrame.AnchorPoint = Vector2.new(0.5, 1)

	local sizeConstraint = MainFrame:FindFirstChild("MobileSizeConstraint")
	if sizeConstraint and sizeConstraint:IsA("UISizeConstraint") then
		sizeConstraint.MinSize = Vector2.new(math.min(320, width), 100)
		sizeConstraint.MaxSize = Vector2.new(maxWidth, 400)
	end

	local closeBtn = MainFrame:FindFirstChild("CloseButton")
	if closeBtn then
		layoutTerrainCloseButton(closeBtn)
	end

	local sizeFrame = MainFrame:FindFirstChild("MobileBrushControls")
	if sizeFrame then
		sizeFrame.Position = UDim2.new(1, -62, 1, -108)
	end

	local strengthFrame = MainFrame:FindFirstChild("MobileStrengthControls")
	if strengthFrame then
		strengthFrame.Position = UDim2.new(1, -122, 1, -108)
	end

	local strengthBar = MainFrame:FindFirstChild("StrengthBar")
	if strengthBar then
		strengthBar.Visible = not isMobileTerrainMode()
		strengthBar.Size = UDim2.fromOffset(math.clamp(math.floor(width * 0.72), 210, math.min(280, maxWidth)), 36)
		strengthBar.Position = UDim2.new(0.5, 0, 0, -8)
	end

	if MobileApplyButton then
		local applyWidth = math.clamp(width - 180, 148, 220)
		MobileApplyButton.Size = UDim2.fromOffset(applyWidth, 48)
		MobileApplyButton.Position = UDim2.new(0, 10, 1, -58)
	end

	if MobileStatusLabel then
		local statusX = 170
		if MobileApplyButton then
			statusX = MobileApplyButton.Position.X.Offset + MobileApplyButton.Size.X.Offset + 12
		end
		MobileStatusLabel.Position = UDim2.new(0, statusX, 1, -62)
		MobileStatusLabel.Size = UDim2.new(1, -(statusX + 10), 0, 54)
		MobileStatusLabel.TextSize = width <= 360 and 10 or width <= 420 and 11 or 12
		MobileStatusLabel.TextYAlignment = Enum.TextYAlignment.Center
		MobileStatusLabel.TextXAlignment = Enum.TextXAlignment.Left
	end
end

local function getEstimatedCost()
	local base = CONFIG.BaseCosts[currentTool] or 0
	if base <= 0 then
		return 0
	end
	local radius = math.max(2, brushSize * 0.5)
	local areaFactor = math.clamp((math.pi * radius * radius) / 120, 0.75, 4)
	local strengthFactor = math.max(0.5, brushStrength)
	return math.max(1, math.floor(((base / 10) * areaFactor * strengthFactor) + 0.5))
end

local function getCharacterRootAndHumanoid()
	local character = Player.Character
	if not character then return nil, nil, nil end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local root = character:FindFirstChild("HumanoidRootPart")
	return character, humanoid, root
end

local function getStandingTargetY(rootPosition)
	local character, humanoid, root = getCharacterRootAndHumanoid()
	if not character or not humanoid or not root then return nil end

	local rayParams = RaycastParams.new()
	rayParams.FilterType = Enum.RaycastFilterType.Exclude
	rayParams.FilterDescendantsInstances = {character, CursorPart}

	local rayOrigin = rootPosition + Vector3.new(0, 40, 0)
	local result = Workspace:Raycast(rayOrigin, Vector3.new(0, -140, 0), rayParams)
	if not result then return nil end

	local hipOffset = humanoid.HipHeight + (root.Size.Y * 0.5) + 1.5
	return result.Position.Y + hipOffset
end

local function preserveTerrainSafety(forceRescue)
	if not isEquipped then
		lastSafeCharacterCF = nil
		return
	end

	local character, humanoid, root = getCharacterRootAndHumanoid()
	if not character or not humanoid or not root or humanoid.Health <= 0 then return end

	local standingTargetY = getStandingTargetY(root.Position)
	if standingTargetY then
		if humanoid.FloorMaterial ~= Enum.Material.Air or root.Position.Y >= (standingTargetY - 2) then
			lastSafeCharacterCF = root.CFrame
		end

		local verticalVelocity = root.AssemblyLinearVelocity.Y
		local timeSinceEdit = os.clock() - (_lastTerrainEditTime or 0)
		local fallingBelowSurface = root.Position.Y < (standingTargetY - 8)
		local launchedAboveSurface = root.Position.Y > (standingTargetY + 3) and verticalVelocity >= 18 and timeSinceEdit <= 1.1
		if launchedAboveSurface then
			root.AssemblyLinearVelocity = Vector3.new(root.AssemblyLinearVelocity.X, math.min(root.AssemblyLinearVelocity.Y, 6), root.AssemblyLinearVelocity.Z)
		end
		local rescueCooldownElapsed = (os.clock() - lastTerrainSafetyRescueAt) >= 0.9
		local shouldAutoRescue = fallingBelowSurface and verticalVelocity <= -1 and timeSinceEdit > 2.2
		if rescueCooldownElapsed and (forceRescue or shouldAutoRescue) then
			local rotationOnly = root.CFrame - root.CFrame.Position
			-- Zero all velocity to prevent catapult/flying when terrain changes rapidly
			root.AssemblyLinearVelocity = Vector3.zero
			-- Clamp rescue distance to prevent huge jumps (max 20 studs per rescue)
			local clampedY = math.min(standingTargetY, root.Position.Y + 20)
			root.CFrame = CFrame.new(root.Position.X, clampedY, root.Position.Z) * rotationOnly
			lastTerrainSafetyRescueAt = os.clock()
			return
		end
	end

	local fallbackY = Workspace.FallenPartsDestroyHeight + 25
	if root.Position.Y < fallbackY and lastSafeCharacterCF then
		local safePos = lastSafeCharacterCF.Position + Vector3.new(0, 6, 0)
		local rotationOnly = root.CFrame - root.CFrame.Position
		root.AssemblyLinearVelocity = Vector3.zero
		root.CFrame = CFrame.new(safePos) * rotationOnly
		return
	end
end

-- // 🛠️ VISUAL FX //
local function spawnNotification(worldPos, text)
	if not ScreenGui or not ScreenGui.Enabled then return end
	local screenPos, onScreen = Camera:WorldToScreenPoint(worldPos)
	if not onScreen then return end

	local label = Instance.new("TextLabel")
	label.Parent = ScreenGui
	label.AnchorPoint = Vector2.new(0.5, 1)
	label.Position = UDim2.new(0, screenPos.X, 0, screenPos.Y - 20)
	label.Size = UDim2.new(0, 100, 0, 20)
	label.BackgroundTransparency = 1
	label.Text = text
	label.TextColor3 = Color3.fromRGB(255, 200, 100)
	label.TextStrokeTransparency = 0.5
	label.Font = Enum.Font.GothamBold
	label.TextSize = 16
	label.ZIndex = 100

	local t1 = TweenService:Create(label, TweenInfo.new(0.2), {TextTransparency = 0, Position = UDim2.new(0, screenPos.X, 0, screenPos.Y - 40)})
	t1:Play()
	task.delay(0.5, function()
		if not label.Parent then return end
		local t2 = TweenService:Create(label, TweenInfo.new(0.5), {TextTransparency = 1, TextStrokeTransparency = 1, Position = UDim2.new(0, screenPos.X, 0, screenPos.Y - 80)})
		t2:Play()
		t2.Completed:Wait()
		label:Destroy()
	end)
end

local function setTransientCostStatus(text, color, duration)
	transientCostStatusText = text
	transientCostStatusColor = color or CONFIG.Colors.TextSecondary
	transientCostStatusUntil = os.clock() + math.max(0.1, duration or 0.75)
	updateUIStats()
end

TerrainEvent.OnClientEvent:Connect(function(payload)
	if type(payload) ~= "table" then
		return
	end
	if payload.Action == "Blocked" and payload.Reason == "TooCloseToPlayer" then
		setTransientCostStatus("MOVE FARTHER FROM YOUR PLAYER", Color3.fromRGB(255, 186, 73), 0.9)
	end
end)

-- // 🛠️ UI CONNECTION LOGIC //
local function updateUIStats()
	if not SizeLabel or not CostLabel then return end
	local sizeHint = isMobileTerrainMode() and " (+/-)" or " (R/F)"
	local strengthHint = isMobileTerrainMode() and " (+/-)" or " (Q/E or [ / ])"
	SizeLabel.Text = "SIZE: <b>" .. brushSize .. "</b>" .. sizeHint .. "  |  STRENGTH: <b>" .. getBrushStrengthPercent() .. "%</b>" .. strengthHint
	if StrengthValueLabel then
		StrengthValueLabel.Text = getBrushStrengthPercent() .. "%"
	end
	local cost = getEstimatedCost()
	if currentTool == "None" then
		CostLabel.Text = "SELECT A TOOL"
		CostLabel.TextColor3 = CONFIG.Colors.TextSecondary
	elseif transientCostStatusText and transientCostStatusUntil > os.clock() then
		CostLabel.Text = transientCostStatusText
		CostLabel.TextColor3 = transientCostStatusColor or CONFIG.Colors.TextPrimary
	else
		CostLabel.Text = "COST: <font color='#FFCC00'>$" .. cost .. "</font> / STROKE"
		CostLabel.TextColor3 = CONFIG.Colors.TextPrimary
	end
end

local function layoutTerrainCloseButton(closeBtn)
	if not closeBtn or not closeBtn:IsA("GuiButton") then
		return
	end
	local compactTouch = isMobileTerrainMode()
	closeBtn.AnchorPoint = Vector2.new(1, 0)
	closeBtn.Position = compactTouch and UDim2.new(1, -10, 0, 10) or UDim2.new(1, -8, 0, 8)
	closeBtn.Size = compactTouch and UDim2.fromOffset(84, 34) or UDim2.fromOffset(58, 30)
	closeBtn.Text = compactTouch and "EXIT" or "X"
end

local function ensureCloseButton(infoBar)
	if not MainFrame then return nil end

	local existing = MainFrame:FindFirstChild("CloseButton")
	if existing and existing:IsA("GuiButton") then
		layoutTerrainCloseButton(existing)
		return existing
	end

	if infoBar then
		infoBar.Size = UDim2.new(1, -104, infoBar.Size.Y.Scale, infoBar.Size.Y.Offset)
	end

	local closeBtn = Instance.new("TextButton")
	closeBtn.Name = "CloseButton"
	closeBtn.BackgroundColor3 = Color3.fromRGB(255, 8, 53)
	closeBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
	closeBtn.Font = Enum.Font.GothamBold
	closeBtn.TextScaled = true
	closeBtn.ZIndex = (infoBar and infoBar.ZIndex or MainFrame.ZIndex) + 2
	closeBtn.Parent = MainFrame

	local padding = Instance.new("UIPadding")
	padding.PaddingTop = UDim.new(0, 5)
	padding.PaddingBottom = UDim.new(0, 5)
	padding.PaddingLeft = UDim.new(0, 8)
	padding.PaddingRight = UDim.new(0, 8)
	padding.Parent = closeBtn

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 8)
	corner.Parent = closeBtn

	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.fromRGB(120, 0, 20)
	stroke.Thickness = 1.25
	stroke.Transparency = 0.15
	stroke.Parent = closeBtn

	layoutTerrainCloseButton(closeBtn)

	connectGuiButton(closeBtn, function()
		setTerrainModeState(false)
		if toggleUI then
			toggleUI(false, "CloseButton")
		end
	end)

	return closeBtn
end

local function connectInterface()
	-- Wait for the UI generated by the other script to load
	ScreenGui = Player.PlayerGui:WaitForChild("TerrainEditerUI", 2)
	if not ScreenGui then warn("TerrainEditerUI not found in PlayerGui!") return end
	MainFrame = ScreenGui:WaitForChild("Toolbar", 2)
	ToolContainer = MainFrame:WaitForChild("Tools", 2)
	MaterialContainer = MainFrame:WaitForChild("Materials", 2)
	local InfoBar = MainFrame:WaitForChild("InfoBar", 2)
	SizeLabel = InfoBar:WaitForChild("SizeLabel", 2)
	CostLabel = InfoBar:WaitForChild("CostLabel", 2)
	ensureCloseButton(InfoBar)
	-- Create Flatten Height Lock bar
	do
		local heightBar = Instance.new("Frame")
		heightBar.Name = "FlattenHeightBar"
		heightBar.Size = UDim2.new(1, -20, 0, 36)
		heightBar.Position = UDim2.new(0, 10, 1, 6)
		heightBar.BackgroundColor3 = Color3.fromRGB(35, 38, 48)
		heightBar.BorderSizePixel = 0
		heightBar.Visible = false
		heightBar.ZIndex = MainFrame.ZIndex + 1
		heightBar.Parent = MainFrame
		local hbCorner = Instance.new("UICorner")
		hbCorner.CornerRadius = UDim.new(0, 8)
		hbCorner.Parent = heightBar
		local hbStroke = Instance.new("UIStroke")
		hbStroke.Color = Color3.fromRGB(0, 170, 255)
		hbStroke.Thickness = 1
		hbStroke.Transparency = 0.5
		hbStroke.Parent = heightBar
		local hlabel = Instance.new("TextLabel")
		hlabel.Size = UDim2.new(0, 52, 1, 0)
		hlabel.Position = UDim2.new(0, 8, 0, 0)
		hlabel.BackgroundTransparency = 1
		hlabel.Text = "Height:"
		hlabel.TextColor3 = Color3.fromRGB(200, 205, 215)
		hlabel.Font = Enum.Font.GothamMedium
		hlabel.TextSize = 13
		hlabel.TextXAlignment = Enum.TextXAlignment.Left
		hlabel.ZIndex = heightBar.ZIndex + 1
		hlabel.Parent = heightBar
		local heightInput = Instance.new("TextBox")
		heightInput.Name = "HeightInput"
		heightInput.Size = UDim2.new(0, 70, 0, 24)
		heightInput.Position = UDim2.new(0, 64, 0.5, -12)
		heightInput.BackgroundColor3 = Color3.fromRGB(50, 54, 65)
		heightInput.TextColor3 = Color3.fromRGB(255, 255, 255)
		heightInput.PlaceholderText = "auto"
		heightInput.PlaceholderColor3 = Color3.fromRGB(120, 125, 135)
		heightInput.Text = ""
		heightInput.Font = Enum.Font.GothamMedium
		heightInput.TextSize = 13
		heightInput.ClearTextOnFocus = false
		heightInput.ZIndex = heightBar.ZIndex + 1
		heightInput.Parent = heightBar
		Instance.new("UICorner", heightInput).CornerRadius = UDim.new(0, 6)
		local lockBtn = Instance.new("TextButton")
		lockBtn.Name = "LockButton"
		lockBtn.Size = UDim2.new(0, 54, 0, 24)
		lockBtn.Position = UDim2.new(0, 140, 0.5, -12)
		lockBtn.BackgroundColor3 = Color3.fromRGB(0, 140, 255)
		lockBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
		lockBtn.Text = "Lock"
		lockBtn.Font = Enum.Font.GothamBold
		lockBtn.TextSize = 12
		lockBtn.ZIndex = heightBar.ZIndex + 1
		lockBtn.Parent = heightBar
		Instance.new("UICorner", lockBtn).CornerRadius = UDim.new(0, 6)
		local resetBtn = Instance.new("TextButton")
		resetBtn.Name = "ResetButton"
		resetBtn.Size = UDim2.new(0, 54, 0, 24)
		resetBtn.Position = UDim2.new(0, 200, 0.5, -12)
		resetBtn.BackgroundColor3 = Color3.fromRGB(80, 85, 95)
		resetBtn.TextColor3 = Color3.fromRGB(200, 205, 215)
		resetBtn.Text = "Reset"
		resetBtn.Font = Enum.Font.GothamBold
		resetBtn.TextSize = 12
		resetBtn.ZIndex = heightBar.ZIndex + 1
		resetBtn.Parent = heightBar
		Instance.new("UICorner", resetBtn).CornerRadius = UDim.new(0, 6)
		lockBtn.MouseButton1Click:Connect(function()
			local val = tonumber(heightInput.Text)
			if val then
				userLockedFlattenY = val
				flattenPlaneY = val
				lockBtn.Text = "Locked"
				lockBtn.BackgroundColor3 = Color3.fromRGB(0, 200, 80)
				heightInput.TextColor3 = Color3.fromRGB(0, 255, 120)
			end
		end)
		resetBtn.MouseButton1Click:Connect(function()
			userLockedFlattenY = nil
			flattenPlaneY = nil
			lockBtn.Text = "Lock"
			lockBtn.BackgroundColor3 = Color3.fromRGB(0, 140, 255)
			heightInput.Text = ""
			heightInput.TextColor3 = Color3.fromRGB(255, 255, 255)
		end)
		heightInput.FocusLost:Connect(function(enterPressed)
			if enterPressed then
				local val = tonumber(heightInput.Text)
				if val then
					userLockedFlattenY = val
					flattenPlaneY = val
					lockBtn.Text = "Locked"
					lockBtn.BackgroundColor3 = Color3.fromRGB(0, 200, 80)
					heightInput.TextColor3 = Color3.fromRGB(0, 255, 120)
				end
			end
		end)
	end

	do
		local strengthBar = MainFrame:FindFirstChild("StrengthBar")
		if not strengthBar then
			strengthBar = Instance.new("Frame")
			strengthBar.Name = "StrengthBar"
			strengthBar.AnchorPoint = Vector2.new(0.5, 1)
			strengthBar.Position = UDim2.new(0.5, 0, 0, -8)
			strengthBar.Size = UDim2.fromOffset(228, 36)
			strengthBar.BackgroundColor3 = Color3.fromRGB(35, 38, 48)
			strengthBar.BorderSizePixel = 0
			strengthBar.ZIndex = MainFrame.ZIndex + 1
			strengthBar.Parent = MainFrame
			local barCorner = Instance.new("UICorner")
			barCorner.CornerRadius = UDim.new(0, 8)
			barCorner.Parent = strengthBar
			local barStroke = Instance.new("UIStroke")
			barStroke.Color = Color3.fromRGB(0, 170, 255)
			barStroke.Thickness = 1
			barStroke.Transparency = 0.45
			barStroke.Parent = strengthBar

			local title = Instance.new("TextLabel")
			title.BackgroundTransparency = 1
			title.Position = UDim2.new(0, 10, 0, 0)
			title.Size = UDim2.new(0, 74, 1, 0)
			title.Text = "Strength"
			title.TextColor3 = Color3.fromRGB(200, 205, 215)
			title.Font = Enum.Font.GothamMedium
			title.TextSize = 13
			title.TextXAlignment = Enum.TextXAlignment.Left
			title.ZIndex = strengthBar.ZIndex + 1
			title.Parent = strengthBar

			local minusBtn = Instance.new("TextButton")
			minusBtn.Name = "StrengthDown"
			minusBtn.Size = UDim2.fromOffset(32, 24)
			minusBtn.Position = UDim2.new(1, -106, 0.5, -12)
			minusBtn.BackgroundColor3 = CONFIG.Colors.ButtonNormal
			minusBtn.Text = "-"
			minusBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
			minusBtn.Font = Enum.Font.GothamBold
			minusBtn.TextSize = 16
			minusBtn.ZIndex = strengthBar.ZIndex + 1
			minusBtn.Parent = strengthBar
			Instance.new("UICorner", minusBtn).CornerRadius = UDim.new(0, 6)
			connectGuiButton(minusBtn, function()
				brushStrength = clampBrushStrengthValue(brushStrength - CONFIG.StrengthStep)
				updateUIStats()
				updateMobileTerrainControls()
			end)

			local valueLabel = Instance.new("TextLabel")
			valueLabel.Name = "StrengthValue"
			valueLabel.BackgroundTransparency = 1
			valueLabel.Size = UDim2.fromOffset(54, 24)
			valueLabel.Position = UDim2.new(1, -72, 0.5, -12)
			valueLabel.Text = "100%"
			valueLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
			valueLabel.Font = Enum.Font.GothamBold
			valueLabel.TextSize = 13
			valueLabel.ZIndex = strengthBar.ZIndex + 1
			valueLabel.Parent = strengthBar
			StrengthValueLabel = valueLabel

			local plusBtn = Instance.new("TextButton")
			plusBtn.Name = "StrengthUp"
			plusBtn.Size = UDim2.fromOffset(32, 24)
			plusBtn.Position = UDim2.new(1, -36, 0.5, -12)
			plusBtn.BackgroundColor3 = CONFIG.Colors.ButtonNormal
			plusBtn.Text = "+"
			plusBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
			plusBtn.Font = Enum.Font.GothamBold
			plusBtn.TextSize = 16
			plusBtn.ZIndex = strengthBar.ZIndex + 1
			plusBtn.Parent = strengthBar
			Instance.new("UICorner", plusBtn).CornerRadius = UDim.new(0, 6)
			connectGuiButton(plusBtn, function()
				brushStrength = clampBrushStrengthValue(brushStrength + CONFIG.StrengthStep)
				updateUIStats()
				updateMobileTerrainControls()
			end)
		else
			StrengthValueLabel = strengthBar:FindFirstChild("StrengthValue")
		end
	end

	if MainFrame then
		MainFrame.Visible = true
		MainFrame.AnchorPoint = Vector2.new(0.5, 1)
	end

	ScreenGui.Enabled = false -- Force hidden upon connection until toggled
	ScreenGui.IgnoreGuiInset = true -- Ensures full screen height context

	-- 1. Connect Tool Buttons
	local tools = {"Raise", "Lower", "Flatten", "Smooth", "Paint"}
	local toolButtons = {}
	local materialButtons = {}

	local function refreshToolVisuals(hoveredTool)
		for _, tName in ipairs(tools) do
			local button = toolButtons[tName] or ToolContainer:FindFirstChild(tName)
			if button then
				local targetColor = CONFIG.Colors.ButtonNormal
				if currentTool == tName then
					targetColor = CONFIG.Colors.ButtonActive
				elseif hoveredTool == tName then
					targetColor = CONFIG.Colors.ButtonHover
				end
				tween(button, {BackgroundColor3 = targetColor})
			end
		end
	end

	local function refreshMaterialVisuals(hoveredMaterial)
		for _, matData in ipairs(CONFIG.Materials) do
			local button = materialButtons[matData.Name] or MaterialContainer:FindFirstChild(matData.Name)
			if button then
				local targetColor = CONFIG.Colors.ButtonNormal
				if currentMaterial == matData.Mat then
					targetColor = CONFIG.Colors.ButtonActive
				elseif hoveredMaterial == matData.Name then
					targetColor = CONFIG.Colors.ButtonHover
				end
				tween(button, {BackgroundColor3 = targetColor})
			end
		end
	end

	local toolbarCorner = MainFrame:FindFirstChildOfClass("UICorner")
	local defaultToolbarCorner = toolbarCorner and toolbarCorner.CornerRadius or UDim.new(0.15, 0)
	local defaultToolPosition = ToolContainer.Position
	local defaultToolSize = ToolContainer.Size
	local expandedToolHeightScale = math.min(defaultToolSize.Y.Scale * 2, 0.78)

	local function applyToolbarLayout(showMaterials)
		local currentXScale = MainFrame.Size.X.Scale
		local currentXOffset = MainFrame.Size.X.Offset
		tween(MainFrame, {Size = UDim2.new(currentXScale, currentXOffset, 0, showMaterials and 160 or 110)})
		MaterialContainer.Visible = showMaterials
		ToolContainer.Position = defaultToolPosition
		if showMaterials then
			ToolContainer.Size = defaultToolSize
			if toolbarCorner then
				toolbarCorner.CornerRadius = defaultToolbarCorner
			end
		else
			ToolContainer.Size = UDim2.new(defaultToolSize.X.Scale, defaultToolSize.X.Offset, expandedToolHeightScale, defaultToolSize.Y.Offset)
			if toolbarCorner then
				toolbarCorner.CornerRadius = UDim.new(defaultToolbarCorner.Scale * 2, defaultToolbarCorner.Offset * 2)
			end
		end
		applyTerrainResponsiveLayout(showMaterials)
	end

	local function setToolVisuals(selectedName)
		refreshToolVisuals(nil)
		if selectedName ~= "Flatten" then
			if not userLockedFlattenY then flattenPlaneY = nil end
		end
		applyToolbarLayout(selectedName == "Paint")
		updateUIStats()
		if MainFrame then
			local heightBar = MainFrame:FindFirstChild("FlattenHeightBar")
			if heightBar then heightBar.Visible = (selectedName == "Flatten") end
		end
	end

	for _, toolName in ipairs(tools) do
		local btn = ToolContainer:FindFirstChild(toolName)
		if btn then
			toolButtons[toolName] = btn
			connectGuiButton(btn, function()
				if currentTool == toolName then
					currentTool = "None"
				else
					currentTool = toolName
				end
				setToolVisuals(currentTool)
			end)

			btn.MouseEnter:Connect(function()
				if currentTool ~= toolName then
					refreshToolVisuals(toolName)
				end
			end)
			btn.MouseLeave:Connect(function()
				refreshToolVisuals(nil)
			end)
		end
	end

	-- 2. Connect Material Buttons
	for _, matData in ipairs(CONFIG.Materials) do
		local matBtn = MaterialContainer:FindFirstChild(matData.Name)
		if matBtn then
			materialButtons[matData.Name] = matBtn
			connectGuiButton(matBtn, function()
				currentMaterial = matData.Mat
				refreshMaterialVisuals(nil)
			end)

			matBtn.MouseEnter:Connect(function()
				if currentMaterial ~= matData.Mat then
					refreshMaterialVisuals(matData.Name)
				end
			end)
			matBtn.MouseLeave:Connect(function()
				refreshMaterialVisuals(nil)
			end)
		end
	end

	-- 2.5 Sculpt Toggle Button (Dynamic Generation)
	local sculptToggleBtn = Instance.new("TextButton")
	sculptToggleBtn.Name = "SculptToggle"
	sculptToggleBtn.Size = UDim2.new(0, 100, 0, 30)
	sculptToggleBtn.Position = UDim2.new(0.5, 50, 0, -40) -- Just above the toolbar
	sculptToggleBtn.AnchorPoint = Vector2.new(0.5, 1)
	sculptToggleBtn.BackgroundColor3 = CONFIG.Colors.ButtonNormal
	sculptToggleBtn.TextColor3 = Color3.new(1,1,1)
	sculptToggleBtn.Font = Enum.Font.GothamBold
	sculptToggleBtn.TextSize = 14
	sculptToggleBtn.Text = "✏️ SCULPT: ADD"
	sculptToggleBtn.Visible = false
	sculptToggleBtn.Parent = MainFrame
	Instance.new("UICorner", sculptToggleBtn).CornerRadius = UDim.new(0, 4)

	local sculptMode = "Add"
	connectGuiButton(sculptToggleBtn, function()
		if sculptMode == "Add" then
			sculptMode = "Sub"
			sculptToggleBtn.Text = "⛏️ SCULPT: SUB"
			sculptToggleBtn.BackgroundColor3 = Color3.fromRGB(180, 50, 50)
		else
			sculptMode = "Add"
			sculptToggleBtn.Text = "✏️ SCULPT: ADD"
			sculptToggleBtn.BackgroundColor3 = CONFIG.Colors.ButtonNormal
		end
	end)

	local function updateSculptToggleVisibility()
		sculptToggleBtn.Visible = (currentTool == "Sculpt" or currentTool == "Raise") -- Support both names
	end

	-- 3. Connect Undo/Redo
	local undoBtn = ToolContainer:FindFirstChild("Undo")
	if undoBtn then
		connectGuiButton(undoBtn, function() TerrainEvent:FireServer({Action="Undo"}) end)
		undoBtn.MouseEnter:Connect(function() tween(undoBtn, {BackgroundColor3 = CONFIG.Colors.ButtonHover}) end)
		undoBtn.MouseLeave:Connect(function() tween(undoBtn, {BackgroundColor3 = CONFIG.Colors.ButtonNormal}) end)
	end

	local redoBtn = ToolContainer:FindFirstChild("Redo")
	if redoBtn then
		connectGuiButton(redoBtn, function() TerrainEvent:FireServer({Action="Redo"}) end)
		redoBtn.MouseEnter:Connect(function() tween(redoBtn, {BackgroundColor3 = CONFIG.Colors.ButtonHover}) end)
		redoBtn.MouseLeave:Connect(function() tween(redoBtn, {BackgroundColor3 = CONFIG.Colors.ButtonNormal}) end)
	end

	-- 4. Mobile Brush Size + Apply Controls
	if UserInputService.TouchEnabled then
		local sizeFrame = Instance.new("Frame", MainFrame)
		sizeFrame.Name = "MobileBrushControls"
		sizeFrame.Size = UDim2.new(0, 56, 0, 104)
		sizeFrame.Position = UDim2.new(1, 12, 0, 0)
		sizeFrame.BackgroundTransparency = 1

		local sizeLabel = Instance.new("TextLabel", sizeFrame)
		sizeLabel.Name = "Header"
		sizeLabel.Size = UDim2.new(0, 48, 0, 14)
		sizeLabel.Position = UDim2.new(0, 0, 0, -18)
		sizeLabel.BackgroundTransparency = 1
		sizeLabel.Text = "SIZE"
		sizeLabel.TextColor3 = CONFIG.Colors.TextSecondary
		sizeLabel.Font = Enum.Font.GothamBold
		sizeLabel.TextSize = 11

		local plus = Instance.new("TextButton", sizeFrame)
		plus.Size = UDim2.new(0, 48, 0, 48)
		plus.BackgroundColor3 = CONFIG.Colors.ButtonNormal
		plus.Text = "+"
		plus.TextColor3 = Color3.new(1,1,1)
		plus.Font = Enum.Font.GothamBold
		plus.TextSize = 20
		Instance.new("UICorner", plus).CornerRadius = UDim.new(0, 8)
		connectGuiButton(plus, function()
			brushSize = math.min(CONFIG.MaxSize, brushSize + 4)
			updateUIStats()
			updateMobileTerrainControls()
		end)

		local minus = plus:Clone()
		minus.Parent = sizeFrame
		minus.Position = UDim2.new(0, 0, 0, 56)
		minus.Text = "-"
		connectGuiButton(minus, function()
			brushSize = math.max(CONFIG.MinSize, brushSize - 4)
			updateUIStats()
			updateMobileTerrainControls()
		end)

		local strengthFrame = Instance.new("Frame", MainFrame)
		strengthFrame.Name = "MobileStrengthControls"
		strengthFrame.Size = UDim2.new(0, 56, 0, 104)
		strengthFrame.Position = UDim2.new(1, -52, 0, 0)
		strengthFrame.BackgroundTransparency = 1

		local strengthLabel = Instance.new("TextLabel", strengthFrame)
		strengthLabel.Name = "Header"
		strengthLabel.Size = UDim2.new(0, 48, 0, 14)
		strengthLabel.Position = UDim2.new(0, 0, 0, -18)
		strengthLabel.BackgroundTransparency = 1
		strengthLabel.Text = "POWER"
		strengthLabel.TextColor3 = CONFIG.Colors.TextSecondary
		strengthLabel.Font = Enum.Font.GothamBold
		strengthLabel.TextSize = 11

		local strengthUp = plus:Clone()
		strengthUp.Parent = strengthFrame
		connectGuiButton(strengthUp, function()
			brushStrength = clampBrushStrengthValue(brushStrength + CONFIG.StrengthStep)
			updateUIStats()
			updateMobileTerrainControls()
		end)

		local strengthDown = plus:Clone()
		strengthDown.Parent = strengthFrame
		strengthDown.Position = UDim2.new(0, 0, 0, 56)
		strengthDown.Text = "-"
		connectGuiButton(strengthDown, function()
			brushStrength = clampBrushStrengthValue(brushStrength - CONFIG.StrengthStep)
			updateUIStats()
			updateMobileTerrainControls()
		end)

		MobileApplyButton = Instance.new("TextButton")
		MobileApplyButton.Name = "ApplyButton"
		MobileApplyButton.Size = UDim2.new(0, 148, 0, 48)
		MobileApplyButton.Position = UDim2.new(1, 70, 0, 0)
		MobileApplyButton.BackgroundColor3 = Color3.fromRGB(33, 115, 215)
		MobileApplyButton.Text = "HOLD APPLY"
		MobileApplyButton.TextColor3 = Color3.fromRGB(255, 255, 255)
		MobileApplyButton.Font = Enum.Font.GothamBold
		MobileApplyButton.TextSize = 16
		MobileApplyButton.Active = true
		MobileApplyButton.Selectable = true
		MobileApplyButton.AutoButtonColor = true
		MobileApplyButton.Parent = MainFrame
		Instance.new("UICorner", MobileApplyButton).CornerRadius = UDim.new(0, 10)
		MobileApplyButton.InputBegan:Connect(beginMobileApply)
		MobileApplyButton.InputEnded:Connect(endMobileApply)
		MobileApplyButton.Activated:Connect(function()
			if not (isMobileTerrainMode() and isEquipped and currentTool ~= "None") then
				updateMobileTerrainControls()
				return
			end
			local result = getTerrainRayResult()
			if result then
				currentBrushNormal = result.Normal
				if currentTool == "Flatten" then
					flattenPlaneY = result.Position.Y
				end
				fireTerrainEdit(currentTool, result.Position, brushSize, currentMaterial, currentBrushNormal)
			end
		end)

		MobileStatusLabel = Instance.new("TextLabel")
		MobileStatusLabel.Name = "MobileStatusLabel"
		MobileStatusLabel.BackgroundTransparency = 1
		MobileStatusLabel.Position = UDim2.new(1, 70, 0, 54)
		MobileStatusLabel.Size = UDim2.new(0, 148, 0, 52)
		MobileStatusLabel.Font = Enum.Font.GothamMedium
		MobileStatusLabel.TextSize = 12
		MobileStatusLabel.TextWrapped = true
		MobileStatusLabel.TextColor3 = CONFIG.Colors.TextSecondary
		MobileStatusLabel.TextXAlignment = Enum.TextXAlignment.Left
		MobileStatusLabel.TextYAlignment = Enum.TextYAlignment.Top
		MobileStatusLabel.Text = "Aim with camera and hold APPLY"
		MobileStatusLabel.Parent = MainFrame

		MobileReticle = Instance.new("Frame")
		MobileReticle.Name = "TerrainReticle"
		MobileReticle.AnchorPoint = Vector2.new(0.5, 0.5)
		MobileReticle.Position = UDim2.new(0.5, 0, 0.5, 0)
		MobileReticle.Size = UDim2.fromOffset(10, 10)
		MobileReticle.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
		MobileReticle.BorderSizePixel = 0
		MobileReticle.Visible = false
		MobileReticle.ZIndex = 20
		MobileReticle.Parent = ScreenGui
		Instance.new("UICorner", MobileReticle).CornerRadius = UDim.new(1, 0)

		updateMobileTerrainControls()
	end
end

local ClosePanels = Events:FindFirstChild("ClosePanels")
if not ClosePanels then
	ClosePanels = Instance.new("BindableEvent")
	ClosePanels.Name = "ClosePanels"
	ClosePanels.Parent = Events
end

-- // 🔄 UI TOGGLE LOGIC //
toggleUI = function(forceState, source)
	if forceState ~= nil then isEquipped = forceState else isEquipped = not isEquipped end

	if not ScreenGui then 
		connectInterface() 
	end

	if ScreenGui then 
		ScreenGui.Enabled = isEquipped 
		endMobileApply(nil)
		if not userLockedFlattenY then flattenPlaneY = nil end
		if isEquipped then
			ClosePanels:Fire("Terrain")
			if Dock then Dock.Visible = false end
			if source == "Button" then
				openedFromButton = true
			else
				openedFromButton = false
			end
			if BuildFrameRef then BuildFrameRef.Visible = false end

			currentTool = "None"
			for _, toolName in ipairs({"Raise", "Lower", "Flatten", "Smooth", "Paint"}) do
				local toolButton = ToolContainer and ToolContainer:FindFirstChild(toolName)
				if toolButton then
					toolButton.BackgroundColor3 = CONFIG.Colors.ButtonNormal
				end
			end
			for _, matData in ipairs(CONFIG.Materials) do
				local materialButton = MaterialContainer and MaterialContainer:FindFirstChild(matData.Name)
				if materialButton then
					materialButton.BackgroundColor3 = (currentMaterial == matData.Mat) and CONFIG.Colors.ButtonActive or CONFIG.Colors.ButtonNormal
				end
			end
			updateUIStats()
			updateMobileTerrainControls()
			applyTerrainResponsiveLayout(currentTool == "Paint")
			-- Visual Intro (Adjusted Y position to avoid overlapping the Dock)
			MainFrame.Position = UDim2.new(0.5, 0, 1.2, 0)
			local targetYScale = isMobileTerrainMode() and 0.94 or 0.82
			tween(MainFrame, {Position = UDim2.new(0.5, 0, targetYScale, 0)}, TweenInfo.new(0.5, Enum.EasingStyle.Back, Enum.EasingDirection.Out))
		else
			if Dock then Dock.Visible = true end
			lastSafeCharacterCF = nil
			if openedFromButton and (source == "Key_Z" or source == "CloseButton") and BuildFrameRef then
				BuildFrameRef.Visible = true
			end
			openedFromButton = false

			if CursorPart then CursorPart.Transparency = 1 end
			if CursorLight then CursorLight.Enabled = false end
			updateMobileTerrainControls()
		end
	end
end

ClosePanels.Event:Connect(function(source)
	if source == "Terrain" then return end
	if isEquipped then toggleUI(false) end
end)

Player.CharacterAdded:Connect(function()
	task.defer(function()
		isMouseDown = false
		isMobileBrushActive = false
		mobileApplyInput = nil
		if not userLockedFlattenY then flattenPlaneY = nil end
		lastSafeCharacterCF = nil
		lastSafetyCheck = 0
		currentTool = "None"
		setTerrainModeState(false)
		if isEquipped then
			toggleUI(false, "Respawn")
		elseif ScreenGui then
			ScreenGui.Enabled = false
			updateUIStats()
			updateMobileTerrainControls()
			applyTerrainResponsiveLayout(false)
		end
		if CursorPart then CursorPart.Transparency = 1 end
		if CursorLight then CursorLight.Enabled = false end
		openedFromButton = false
	end)
end)

-- // 🖌️ BRUSH LOGIC (Unchanged) //
local function updateBrush()
	if not isEquipped or currentTool == "None" then
		if CursorPart then CursorPart.Transparency = 1 end
		if CursorLight then CursorLight.Enabled = false end
		return
	end

	if not CursorPart then
		CursorPart = Instance.new("Part")
		CursorPart.Name = "TerrainCursor"
		CursorPart.Shape = Enum.PartType.Ball
		CursorPart.Size = Vector3.new(1, 1, 1)
		CursorPart.Transparency = 0.5
		CursorPart.Material = Enum.Material.ForceField
		CursorPart.CanCollide = false
		CursorPart.Anchored = true
		CursorPart.CastShadow = false
		CursorPart.Parent = Workspace

		CursorLight = Instance.new("PointLight")
		CursorLight.Brightness = 1.2
		CursorLight.Shadows = false
		CursorLight.Parent = CursorPart
	end

	local result = getTerrainRayResult()

	if result then
		local pos = result.Position
		local normal = result.Normal

		-- ANGLE LOCK (Flatten + Smooth)
		if (currentTool == "Smooth" or currentTool == "Flatten") then
			if isMouseDown then
				normal = lastNormal -- Lock angle while dragging
			else
				lastNormal = normal -- Update angle while hovering
			end
		end

		if currentTool == "Flatten" and isMouseDown and flattenPlaneY ~= nil then
			pos = Vector3.new(pos.X, flattenPlaneY, pos.Z)
		end

		currentBrushNormal = normal
		
		local targetSize = Vector3.new(brushSize, brushSize, brushSize)
		CursorPart.Size = CursorPart.Size:Lerp(targetSize, 0.3)
		
		if CursorPart.Transparency == 1 or (CursorPart.Position - pos).Magnitude > 100 then
			CursorPart.Position = pos
		else
			CursorPart.Position = CursorPart.Position:Lerp(pos, 0.35)
		end
		
		CursorPart.Transparency = 0
		CursorPart.Color = CONFIG.Colors[currentTool] or Color3.new(1,1,1)

		CursorLight.Enabled = true
		CursorLight.Color = CursorPart.Color
		CursorLight.Range = math.max(18, brushSize * 0.9)
	else
		CursorPart.Transparency = 1
		CursorLight.Enabled = false
	end
end

local function isBuildHotkeyCaptured(): boolean
	local modeState = PlayerGui:FindFirstChild("ModeState")
	if modeState and modeState:IsA("StringValue") and modeState.Value ~= "" then
		return true
	end

	local placementUI = PlayerGui:FindFirstChild("PlacementUI")
	if placementUI and placementUI:IsA("ScreenGui") and placementUI.Enabled then
		return true
	end

	local buildEditHud = PlayerGui:FindFirstChild("BuildEditHud")
	if buildEditHud and buildEditHud:IsA("ScreenGui") and buildEditHud.Enabled then
		return true
	end

	return false
end

-- Forward declarations are initialized near state to support mobile apply callbacks.

-- // 🖱️ INPUT HANDLING //
UserInputService.InputBegan:Connect(function(input, gpe)
	if gpe then return end
	if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
		if terraformToggleButton and terraformToggleButton.Visible then
			local inputPos = input.Position
			local point = Vector2.new(inputPos.X, inputPos.Y)
			if isPointInsideGuiObject(terraformToggleButton, point) then
				fireTerraformToggle()
				return
			end
		end
	end
	if input.KeyCode == Enum.KeyCode.T then 
		if Player:GetAttribute("IsDrivingBison") then return end -- Don't open while driving snowcat
		if isEquipped then
			setTerrainModeState(false)
			toggleUI(false, "Key_T")
			return
		end
		if isBuildHotkeyCaptured() then return end -- Don't open during placement/editing even if the input was not flagged as processed
		setTerrainModeState(true)
		toggleUI(true, "Key_T")
	elseif input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
		if input.UserInputType == Enum.UserInputType.Touch and isMobileTerrainMode() then
			return
		end
		if isEquipped and currentTool ~= "None" then
			updateTouchAimFromInput(input)
			beginTerrainStroke(input)
		elseif isEquipped and currentTool == "None" then
			setTransientCostStatus("CHOOSE A TERRAIN TOOL FIRST", Color3.fromRGB(255, 186, 73), 0.9)
		end
	elseif input.KeyCode == Enum.KeyCode.R then
		brushSize = math.min(CONFIG.MaxSize, brushSize + 2)
		updateUIStats()
	elseif input.KeyCode == Enum.KeyCode.F then
		brushSize = math.max(CONFIG.MinSize, brushSize - 2)
		updateUIStats()
	elseif input.KeyCode == Enum.KeyCode.E or input.KeyCode == Enum.KeyCode.RightBracket or input.KeyCode == Enum.KeyCode.Equals or input.KeyCode == Enum.KeyCode.KeypadPlus then
		if isEquipped then
			brushStrength = clampBrushStrengthValue(brushStrength + CONFIG.StrengthStep)
			updateUIStats()
		end
	elseif input.KeyCode == Enum.KeyCode.Q or input.KeyCode == Enum.KeyCode.LeftBracket or input.KeyCode == Enum.KeyCode.Minus or input.KeyCode == Enum.KeyCode.KeypadMinus then
		if isEquipped then
			brushStrength = clampBrushStrengthValue(brushStrength - CONFIG.StrengthStep)
			updateUIStats()
		end
	elseif input.KeyCode == Enum.KeyCode.Z or input.KeyCode == Enum.KeyCode.Escape then
		if input.KeyCode == Enum.KeyCode.Z and (UserInputService:IsKeyDown(Enum.KeyCode.LeftControl) or UserInputService:IsKeyDown(Enum.KeyCode.RightControl)) then
			TerrainEvent:FireServer({Action = "Undo"})
		elseif isEquipped then
			setTerrainModeState(false)
			toggleUI(false, "Key_Z")
		end
	elseif input.KeyCode == Enum.KeyCode.Y and (UserInputService:IsKeyDown(Enum.KeyCode.LeftControl) or UserInputService:IsKeyDown(Enum.KeyCode.RightControl)) then
		TerrainEvent:FireServer({Action = "Redo"})
	end
end)

local boundTerraformButtons = {}
local terraformButtonWatcher = nil
local terraformToggleButton = nil

local function fireTerraformToggle()
	if Player:GetAttribute("IsDrivingBison") then
		return
	end
	setTerrainModeState(not isEquipped)
	toggleUI(nil, "Button")
end

local function connectTerraformToggleButton(terraformButton)
	if not terraformButton or not terraformButton:IsA("GuiButton") then
		return
	end
	terraformToggleButton = terraformButton
	if boundTerraformButtons[terraformButton] then
		return
	end
	boundTerraformButtons[terraformButton] = true
	connectGuiButton(terraformButton, fireTerraformToggle)
end

local function bindTerraformButtons(buttonsFrame)
	if terraformButtonWatcher then
		terraformButtonWatcher:Disconnect()
		terraformButtonWatcher = nil
	end
	if not buttonsFrame then
		warn("[TerrainClient] BuildFrame.Buttons not found; Terraform toggle binding deferred")
		return
	end

	connectTerraformToggleButton(buttonsFrame:FindFirstChild("Terraform"))
	connectTerraformToggleButton(buttonsFrame:FindFirstChild("Terrain"))

	terraformButtonWatcher = buttonsFrame.ChildAdded:Connect(function(child)
		if child.Name == "Terraform" or child.Name == "Terrain" then
			connectTerraformToggleButton(child)
		end
	end)
end

task.spawn(function()
	local MainHUD = PlayerGui:WaitForChild("MainHUD")
	local BuildFrame = MainHUD:WaitForChild("BuildFrame")
	BuildFrameRef = BuildFrame
	bindTerraformButtons(BuildFrame:FindFirstChild("Buttons"))

	BuildFrame.ChildAdded:Connect(function(child)
		if child.Name == "Buttons" then
			bindTerraformButtons(child)
		end
	end)
	MainHUD.ChildAdded:Connect(function(child)
		if child.Name == "BuildFrame" then
			BuildFrameRef = child
			bindTerraformButtons(child:FindFirstChild("Buttons"))
		end
	end)
end)

-- Remove redundant ModeState listener that auto-fires on join.

UserInputService.InputEnded:Connect(function(input)
	updateTouchAimFromInput(input)
	if mobileApplyInput and isApplyPressInput(input) then
		endMobileApply(input)
		if isMobileTerrainMode() then
			return
		end
	end
	if input.UserInputType == Enum.UserInputType.Touch and isMobileTerrainMode() then
		return
	end
	if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
		isMouseDown = false
		if not userLockedFlattenY then flattenPlaneY = nil end
		updateMobileTerrainControls()
		if input.UserInputType == Enum.UserInputType.Touch then
			lastTouchAimPosition = nil
			lastTouchAimTimestamp = 0
		end
	end
end)

UserInputService.InputChanged:Connect(function(input)
	if input.UserInputType ~= Enum.UserInputType.Touch then
		return
	end
	if not isEquipped or isMobileTerrainMode() then
		return
	end
	if isMouseDown then
		updateTouchAimFromInput(input)
	end
end)

-- // LOOP //
RunService.RenderStepped:Connect(function()
	updateBrush()
	local now = os.clock()
	if (now - lastSafetyCheck) >= 0.08 then
		lastSafetyCheck = now
		preserveTerrainSafety(false)
		if transientCostStatusText and transientCostStatusUntil > 0 and now >= transientCostStatusUntil then
			transientCostStatusText = nil
			transientCostStatusColor = nil
			transientCostStatusUntil = 0
			updateUIStats()
		end
	end
end)

local _lastTerrainEditTime = 0

local function shouldBlockSelfTerrainEdit(targetPos, tool, size)
	if tool ~= "Raise" then
		return false
	end
	local _, humanoid, root = getCharacterRootAndHumanoid()
	if not humanoid or not root then
		return false
	end
	local flatOffset = Vector3.new(targetPos.X - root.Position.X, 0, targetPos.Z - root.Position.Z).Magnitude
	local verticalOffset = math.abs(targetPos.Y - root.Position.Y)
	local flatLimit = math.max(2.75, (size * 0.18) + 1.5)
	local verticalLimit = math.max(5.5, (size * 0.18) + 4)
	return flatOffset <= flatLimit and verticalOffset <= verticalLimit
end

fireTerrainEdit = function(tool, position, size, material, normal)
	_lastTerrainEditTime = os.clock()
	if shouldBlockSelfTerrainEdit(position, tool, size) then
		local now = os.clock()
		if now - lastSelfBlockWarningAt >= 0.35 then
			lastSelfBlockWarningAt = now
			setTransientCostStatus("MOVE FARTHER FROM YOUR PLAYER", Color3.fromRGB(255, 186, 73), 0.9)
		end
		return false
	end
	TerrainEvent:FireServer({
		Action = "Edit",
		Tool = tool,
		Position = position,
		Size = size,
		Strength = brushStrength,
		Material = material,
		Normal = normal,
	})
	return true
end

beginTerrainStroke = function(input)
	updateTouchAimFromInput(input)
	if not (isEquipped and currentTool ~= "None") then
		return false
	end

	isMouseDown = true
	local res = getTerrainRayResult()
	if not res then
		updateMobileTerrainControls()
		return false
	end

	currentBrushNormal = res.Normal
	if currentTool == "Flatten" or currentTool == "Smooth" then
		lastNormal = res.Normal
		if currentTool == "Flatten" then
			if userLockedFlattenY then
				flattenPlaneY = userLockedFlattenY
			else
				flattenPlaneY = res.Position.Y
			end
		end
	end

	updateMobileTerrainControls()
	fireTerrainEdit(currentTool, res.Position, brushSize, currentMaterial, currentBrushNormal)
	return true
end

local function applyInterpolatedStroke(startPos, endPos, tool, size, material, normal)
	local dist = (endPos - startPos).Magnitude
	local flatSurface = typeof(normal) == "Vector3" and math.abs(normal.Y) >= 0.9
	local stepDist = flatSurface and math.max(2.5, size * 0.28) or math.max(4, size * 0.45) -- Send fewer, more deliberate edit events per drag
	local maxTeleportDistance = flatSurface and math.max(48, size * 1.35) or math.max(120, size * 2.5)
	local sentAny = false
	
	if dist <= stepDist then
		return fireTerrainEdit(tool, endPos, size, material, normal)
	end

	if dist > maxTeleportDistance then
		return false, true
	end

	local steps = math.min(flatSurface and 18 or 12, math.ceil(dist / stepDist))
	if steps <= 0 then
		return fireTerrainEdit(tool, endPos, size, material, normal)
	end

	local stepVec = (endPos - startPos) / steps
	
	for i = 1, steps do
		local interpPos = startPos + (stepVec * i)
		if fireTerrainEdit(tool, interpPos, size, material, normal) then
			sentAny = true
		end
	end
	return sentAny
end

task.spawn(function()
	local lastPos = nil
	local lastTime = 0
	while true do
		task.wait(0.05)
		local ok, err = pcall(function()
			if isMouseDown and isEquipped and currentTool ~= "None" and CursorPart and CursorPart.Transparency == 0 then
				local pos = CursorPart.Position
				local now = os.clock()
				if not lastPos then
					lastPos = pos
					lastTime = now
					if (now - _lastTerrainEditTime) > 0.12 then
						local strokeApplied = applyInterpolatedStroke(pos, pos, currentTool, brushSize, currentMaterial, currentBrushNormal)
						if strokeApplied then
							preserveTerrainSafety(false)
						end
					end
				else
					local dist = (pos - lastPos).Magnitude
					if dist > (brushSize * 0.2) or (now - lastTime) > 0.15 then
						local strokeApplied, resetAnchor = applyInterpolatedStroke(lastPos, pos, currentTool, brushSize, currentMaterial, currentBrushNormal)
						if strokeApplied then
							preserveTerrainSafety(false)
						end
						if strokeApplied or resetAnchor then
							lastPos = pos
							lastTime = now
						end
					end
				end
			else
				lastPos = nil
			end
		end)
		if not ok then
			warn("[TerrainClient] Brush loop error: " .. tostring(err))
			lastPos = nil
		end
	end
end)
-- Initialize connection on load
connectInterface()
print("TerrainClient Online")