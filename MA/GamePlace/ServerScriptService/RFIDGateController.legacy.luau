local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local MODE_AUTO = "Auto"
local MODE_ALWAYS_OPEN = "AlwaysOpen"
local MODE_ALWAYS_CLOSED = "AlwaysClosed"

local MODE_DISPLAY = {
	[MODE_AUTO] = "Auto",
	[MODE_ALWAYS_OPEN] = "Always Open",
	[MODE_ALWAYS_CLOSED] = "Always Closed",
}

local MODE_SEQUENCE = {
	MODE_AUTO,
	MODE_ALWAYS_OPEN,
	MODE_ALWAYS_CLOSED,
}

local OPEN_RADIUS = 14
local ANIMATION_SPEED = 8
local OPEN_ANGLE = math.rad(65)
local UPDATE_INTERVAL = 0.2
local CLICK_DEBOUNCE = 0.35
local OPEN_COLOR = Color3.fromRGB(94, 255, 154)
local CLOSED_COLOR = Color3.fromRGB(255, 84, 84)

local controllers = {}

local function normalizeMode(mode)
	if mode == MODE_ALWAYS_OPEN or mode == MODE_ALWAYS_CLOSED then
		return mode
	end
	return MODE_AUTO
end

local function findFirstRoot(model)
	if not model or not model:IsA("Model") then
		return nil
	end

	return model:FindFirstChild("HumanoidRootPart")
		or model.PrimaryPart
		or model:FindFirstChild("RootPart")
		or model:FindFirstChild("Torso")
		or model:FindFirstChildWhichIsA("BasePart", true)
end

local function getHumanoidModelFromPart(part)
	local model = part and part:FindFirstAncestorOfClass("Model")
	while model do
		if model:FindFirstChildOfClass("Humanoid") then
			return model
		end
		local parent = model.Parent
		model = parent and parent:FindFirstAncestorOfClass("Model") or nil
	end
	return nil
end

local function setIndicator(part, isOpen)
	if not part or not part:IsA("BasePart") then
		return
	end

	part.Color = isOpen and OPEN_COLOR or CLOSED_COLOR
	part.Material = Enum.Material.Neon
end

local function playBeep(sound)
	if not sound or not sound:IsA("Sound") then
		return
	end

	sound.TimePosition = 0
	sound:Play()
end

local function buildModeBillboard(parent)
	local existing = parent:FindFirstChild("GateModeBillboard")
	if existing then
		return existing
	end

	local billboard = Instance.new("BillboardGui")
	billboard.Name = "GateModeBillboard"
	billboard.Size = UDim2.fromOffset(180, 40)
	billboard.StudsOffsetWorldSpace = Vector3.new(0, 3.5, 0)
	billboard.AlwaysOnTop = true
	billboard.LightInfluence = 0
	billboard.MaxDistance = 40
	billboard.Parent = parent

	local frame = Instance.new("Frame")
	frame.Name = "Frame"
	frame.AnchorPoint = Vector2.new(0.5, 0.5)
	frame.Position = UDim2.fromScale(0.5, 0.5)
	frame.Size = UDim2.fromScale(1, 1)
	frame.BackgroundColor3 = Color3.fromRGB(9, 14, 26)
	frame.BackgroundTransparency = 0.15
	frame.BorderSizePixel = 0
	frame.Parent = billboard

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 12)
	corner.Parent = frame

	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.fromRGB(59, 77, 119)
	stroke.Thickness = 1.25
	stroke.Transparency = 0.15
	stroke.Parent = frame

	local label = Instance.new("TextLabel")
	label.Name = "Label"
	label.AnchorPoint = Vector2.new(0.5, 0.5)
	label.Position = UDim2.fromScale(0.5, 0.5)
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.GothamBold
	label.TextSize = 15
	label.TextColor3 = Color3.fromRGB(233, 240, 255)
	label.TextStrokeTransparency = 0.8
	label.Text = "Gate: Auto"
	label.Parent = frame

	return billboard
end

local function buildLane(laneModel)
	local lane = {
		model = laneModel,
		position = laneModel:GetPivot().Position,
		leftMotors = {},
		rightMotors = {},
		isOpenValue = laneModel:FindFirstChild("isOpen"),
		signalPart = nil,
		beep = nil,
	}

	for _, descendant in ipairs(laneModel:GetDescendants()) do
		if descendant:IsA("Motor6D") then
			if descendant.Parent and descendant.Parent.Name == "L" then
				table.insert(lane.leftMotors, descendant)
			elseif descendant.Parent and descendant.Parent.Name == "R" then
				table.insert(lane.rightMotors, descendant)
			end
		elseif descendant:IsA("Sound") and descendant.Name == "beep" then
			lane.beep = descendant
		elseif descendant:IsA("BasePart") and descendant.Name == "Light" then
			lane.signalPart = descendant
		end
	end

	return lane
end

local function applyLaneAlpha(lane, alpha)
	local leftTransform = CFrame.Angles(0, -OPEN_ANGLE * alpha, 0)
	local rightTransform = CFrame.Angles(0, OPEN_ANGLE * alpha, 0)

	for _, motor in ipairs(lane.leftMotors) do
		motor.Transform = leftTransform
	end
	for _, motor in ipairs(lane.rightMotors) do
		motor.Transform = rightTransform
	end
end

local function setGateVisualState(controller, isOpen, silent)
	controller.model:SetAttribute("GateOpen", isOpen)

	for _, lane in ipairs(controller.lanes) do
		if lane.isOpenValue then
			lane.isOpenValue.Value = isOpen
		end
		setIndicator(lane.signalPart, isOpen)
		if not silent then
			playBeep(lane.beep)
		end
	end
end

local function updateModeUI(controller)
	local modeText = MODE_DISPLAY[controller.mode] or MODE_DISPLAY[MODE_AUTO]
	local currentIndex = table.find(MODE_SEQUENCE, controller.mode) or 1
	local nextMode = MODE_SEQUENCE[(currentIndex % #MODE_SEQUENCE) + 1]
	local nextText = MODE_DISPLAY[nextMode]

	if controller.prompt then
		controller.prompt.ActionText = "Set " .. nextText
		controller.prompt.ObjectText = "RFID Gate (" .. modeText .. ")"
	end

	if controller.billboard then
		local frame = controller.billboard:FindFirstChild("Frame")
		local label = frame and frame:FindFirstChild("Label")
		if label then
			label.Text = "Gate: " .. modeText
		end
	end
end

local function isPositionNearGate(controller, position)
	if (position - controller.basePart.Position).Magnitude <= OPEN_RADIUS then
		return true
	end

	for _, lane in ipairs(controller.lanes) do
		if (position - lane.position).Magnitude <= OPEN_RADIUS then
			return true
		end
	end

	return false
end

local function shouldAutoOpen(controller)
	local scanParams = controller.scanParams
	if not scanParams then
		return false
	end

	scanParams.FilterDescendantsInstances = {controller.model}
	local parts = Workspace:GetPartBoundsInRadius(controller.basePart.Position, controller.scanRadius, scanParams)
	local seenModels = {}
	for _, part in ipairs(parts) do
		local actorModel = getHumanoidModelFromPart(part)
		if actorModel and not seenModels[actorModel] then
			seenModels[actorModel] = true
			local root = findFirstRoot(actorModel)
			if root and isPositionNearGate(controller, root.Position) then
				return true
			end
		end
	end

	return false
end

local function computeDesiredOpen(controller)
	if controller.mode == MODE_ALWAYS_OPEN then
		return true
	elseif controller.mode == MODE_ALWAYS_CLOSED then
		return false
	end

	return shouldAutoOpen(controller)
end

local function setDesiredState(controller, desiredOpen)
	if controller.targetOpen == desiredOpen then
		return
	end

	controller.targetOpen = desiredOpen
	controller.targetAlpha = desiredOpen and 1 or 0
	setGateVisualState(controller, desiredOpen)
end

local function cycleMode(controller)
	local now = os.clock()
	if now - controller.lastClick < CLICK_DEBOUNCE then
		return
	end
	controller.lastClick = now

	local currentIndex = table.find(MODE_SEQUENCE, controller.mode) or 1
	controller.mode = MODE_SEQUENCE[(currentIndex % #MODE_SEQUENCE) + 1]
	controller.model:SetAttribute("GateMode", controller.mode)
	updateModeUI(controller)
	setDesiredState(controller, computeDesiredOpen(controller))
end

local function createController(gateModel)
	local movable = gateModel:FindFirstChild("Movable")
	local clickPart = movable and movable:FindFirstChild("Click")
	if not movable or not clickPart or not clickPart:IsA("BasePart") then
		return nil
	end

	local lanes = {}
	for _, child in ipairs(movable:GetChildren()) do
		if child:IsA("Model") and child.Name == "Gate" then
			table.insert(lanes, buildLane(child))
		end
	end
	if #lanes == 0 then
		return nil
	end

	table.sort(lanes, function(a, b)
		return a.position.X < b.position.X
	end)

	local basePart = gateModel.PrimaryPart or gateModel:FindFirstChild("Base") or clickPart
	local maxLaneDistance = 0
	for _, lane in ipairs(lanes) do
		maxLaneDistance = math.max(maxLaneDistance, (lane.position - basePart.Position).Magnitude)
	end
	local scanParams = OverlapParams.new()
	scanParams.FilterType = Enum.RaycastFilterType.Exclude
	scanParams.FilterDescendantsInstances = {gateModel}
	scanParams.MaxParts = 96

	local clickDetector = clickPart:FindFirstChildOfClass("ClickDetector") or Instance.new("ClickDetector")
	clickDetector.MaxActivationDistance = 18
	clickDetector.Parent = clickPart

	local prompt = clickPart:FindFirstChildOfClass("ProximityPrompt")
	if not prompt then
		prompt = Instance.new("ProximityPrompt")
		prompt.Name = "GateModePrompt"
		prompt.MaxActivationDistance = 12
		prompt.RequiresLineOfSight = false
		prompt.Style = Enum.ProximityPromptStyle.Default
		prompt.HoldDuration = 0
		prompt.KeyboardKeyCode = Enum.KeyCode.E
		prompt.GamepadKeyCode = Enum.KeyCode.ButtonX
		prompt.Parent = clickPart
	end

	local controller = {
		model = gateModel,
		basePart = basePart,
		scanRadius = OPEN_RADIUS + maxLaneDistance + 2,
		scanParams = scanParams,
		clickDetector = clickDetector,
		prompt = prompt,
		billboard = buildModeBillboard(clickPart),
		lanes = lanes,
		mode = normalizeMode(gateModel:GetAttribute("GateMode")),
		currentAlpha = 0,
		targetAlpha = 0,
		targetOpen = nil,
		lastClick = 0,
	}

	gateModel:SetAttribute("GateMode", controller.mode)
	gateModel:SetAttribute("GateOpen", false)

	clickDetector.MouseClick:Connect(function()
		cycleMode(controller)
	end)
	prompt.Triggered:Connect(function()
		cycleMode(controller)
	end)
	gateModel:GetAttributeChangedSignal("GateMode"):Connect(function()
		controller.mode = normalizeMode(gateModel:GetAttribute("GateMode"))
		updateModeUI(controller)
		setDesiredState(controller, computeDesiredOpen(controller))
	end)

	updateModeUI(controller)
	for _, lane in ipairs(controller.lanes) do
		applyLaneAlpha(lane, 0)
		setIndicator(lane.signalPart, false)
	end
	setGateVisualState(controller, false, true)
	setDesiredState(controller, computeDesiredOpen(controller))

	return controller
end

local function collectControllers()
	table.clear(controllers)
	for _, child in ipairs(Workspace:GetChildren()) do
		if child:IsA("Model") and child.Name == "RFID Gate" then
			local controller = createController(child)
			if controller then
				table.insert(controllers, controller)
			end
		end
	end
end

collectControllers()
Workspace.ChildAdded:Connect(function(child)
	if child:IsA("Model") and child.Name == "RFID Gate" then
		task.defer(function()
			local controller = createController(child)
			if controller then
				table.insert(controllers, controller)
			end
		end)
	end
end)

local accumulator = 0
RunService.Heartbeat:Connect(function(deltaTime)
	for _, controller in ipairs(controllers) do
		if controller.currentAlpha ~= controller.targetAlpha then
			local direction = controller.targetAlpha > controller.currentAlpha and 1 or -1
			controller.currentAlpha = math.clamp(controller.currentAlpha + (direction * deltaTime * ANIMATION_SPEED), 0, 1)
			for _, lane in ipairs(controller.lanes) do
				applyLaneAlpha(lane, controller.currentAlpha)
			end
		end
	end

	accumulator += deltaTime
	if accumulator < UPDATE_INTERVAL then
		return
	end
	accumulator = 0

	for _, controller in ipairs(controllers) do
		local liveMode = normalizeMode(controller.model:GetAttribute("GateMode"))
		if liveMode ~= controller.mode then
			controller.mode = liveMode
			updateModeUI(controller)
		end
		setDesiredState(controller, computeDesiredOpen(controller))
	end
end)
