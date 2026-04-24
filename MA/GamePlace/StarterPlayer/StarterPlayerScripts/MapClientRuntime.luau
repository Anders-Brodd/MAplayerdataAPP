--!strict

local MapClientRuntime = {}

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local Player = Players.LocalPlayer
local PlayerGui = Player:WaitForChild("PlayerGui")
local Events = ReplicatedStorage:WaitForChild("Events")
local MapRemote = Events:WaitForChild("GetResortMapData", 15) :: RemoteFunction?

local THEME = {
	Panel = Color3.fromRGB(17, 19, 24),
	PanelAlt = Color3.fromRGB(24, 27, 34),
	Header = Color3.fromRGB(14, 18, 30),
	Card = Color3.fromRGB(22, 25, 32),
	CardAlt = Color3.fromRGB(28, 32, 40),
	Stroke = Color3.fromRGB(42, 48, 60),
	Text = Color3.fromRGB(240, 240, 240),
	Muted = Color3.fromRGB(155, 165, 180),
	Accent = Color3.fromRGB(0, 120, 215),
	AccentSoft = Color3.fromRGB(62, 139, 255),
	Success = Color3.fromRGB(40, 160, 80),
	Danger = Color3.fromRGB(180, 40, 40),
	MapBase = Color3.fromRGB(88, 120, 92),
	MapMid = Color3.fromRGB(122, 148, 118),
	MapSnow = Color3.fromRGB(232, 236, 240),
	Lift = Color3.fromRGB(200, 60, 50),
	LiftDark = Color3.fromRGB(80, 30, 30),
	Building = Color3.fromRGB(255, 204, 82),
	Player = Color3.fromRGB(255, 84, 84),
}

local DIFFICULTIES = {
	Green = { color = Color3.fromRGB(48, 168, 66), width = 6, symbol = "●", minZoom = 0.85 },
	Blue = { color = Color3.fromRGB(38, 122, 220), width = 6, symbol = "■", minZoom = 0.85 },
	Black = { color = Color3.fromRGB(18, 18, 18), width = 7, symbol = "◆", minZoom = 0.95 },
	["Double Black"] = { color = Color3.fromRGB(10, 10, 10), width = 8, symbol = "◆◆", minZoom = 1.05 },
}
local DEFAULT_DIFFICULTY = { color = Color3.fromRGB(100, 180, 255), width = 5, symbol = "●", minZoom = 0.85 }
local BUILDING_ICONS = { Food = "FOOD", Rental = "RENT", Shop = "SHOP", House = "LODGE", Building = "BASE" }

local CONTENT_W = 1800
local CONTENT_H = 1300
local CONTENT_PAD = 140
local MIN_ZOOM = 0.7
local MAX_ZOOM = 3.4
local DEFAULT_ZOOM = 1
local OPEN_PANEL_POSITION = UDim2.new(0.5, 0, 0.54, 0)
local MAP_BUTTON_GUI_NAME = "MapTopButtonUI"
local MAP_TOP_BUTTON_NAME = "MapTopButton"
local WAYPOINT_TOP_BUTTON_NAME = "WaypointTopButton"
local RESORT_SETTINGS_TOP_BUTTON_NAME = "ResortSettingsTopButton"

type PackedPoint = {number}
type Bounds = { MinX: number, MinZ: number, MaxX: number, MaxZ: number }
type ZoomEntry = { gui: GuiObject, minZoom: number }
type MapRefs = {
	gui: ScreenGui?,
	panel: Frame?,
	viewport: Frame?,
	surface: Frame?,
	surfaceScale: UIScale?,
	zoomLabel: TextLabel?,
	statusLabel: TextLabel?,
	playerDot: Frame?,
	playerLabel: Frame?,
	statsBody: Frame?,
	detailBody: Frame?,
	resetButton: TextButton?,
	playerButton: TextButton?,
	zoomInButton: TextButton?,
	zoomOutButton: TextButton?,
	closeButton: TextButton?,
}

type RuntimeState = {
	started: boolean,
	isOpen: boolean,
	isLoading: boolean,
	boundButtons: {[GuiObject]: boolean},
	mapData: {[string]: any}?,
	bounds: Bounds?,
	baseScale: number,
	baseOffset: Vector2,
	zoom: number,
	panOffset: Vector2,
	hoveringViewport: boolean,
	dragging: boolean,
	dragInput: InputObject?,
	dragStartPosition: Vector2,
	dragStartPan: Vector2,
	zoomEntries: {ZoomEntry},
	refs: MapRefs,
	connections: {RBXScriptConnection},
	topButtonGui: ScreenGui?,
	topButton: ImageButton?,
}

local state: RuntimeState = {
	started = false,
	isOpen = false,
	isLoading = false,
	boundButtons = {},
	mapData = nil,
	bounds = nil,
	baseScale = 1,
	baseOffset = Vector2.zero,
	zoom = DEFAULT_ZOOM,
	panOffset = Vector2.zero,
	hoveringViewport = false,
	dragging = false,
	dragInput = nil,
	dragStartPosition = Vector2.zero,
	dragStartPan = Vector2.zero,
	zoomEntries = {},
	refs = {},
	connections = {},
	topButtonGui = nil,
	topButton = nil,
}

local function addConnection(connection: RBXScriptConnection)
	table.insert(state.connections, connection)
	return connection
end

local function clearConnections()
	for _, connection in ipairs(state.connections) do
		if connection.Connected then
			connection:Disconnect()
		end
	end
	table.clear(state.connections)
end

local function round(instance: GuiObject, radius: number)
	local corner = instance:FindFirstChildOfClass("UICorner") or Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, radius)
	corner.Parent = instance
	return corner
end

local function outline(instance: GuiObject, color: Color3?, thickness: number?, transparency: number?)
	local stroke = instance:FindFirstChildOfClass("UIStroke") or Instance.new("UIStroke")
	stroke.Color = color or THEME.Stroke
	stroke.Thickness = thickness or 1
	stroke.Transparency = transparency or 0.15
	stroke.Parent = instance
	return stroke
end

local function addGradient(instance: GuiObject, colors: ColorSequence, rotation: number?)
	local gradient = Instance.new("UIGradient")
	gradient.Color = colors
	gradient.Rotation = rotation or 0
	gradient.Parent = instance
	return gradient
end

local function createFrame(parent: Instance, name: string, size: UDim2, position: UDim2, color: Color3, transparency: number?, zIndex: number?): Frame
	local frame = Instance.new("Frame")
	frame.Name = name
	frame.Size = size
	frame.Position = position
	frame.BackgroundColor3 = color
	frame.BackgroundTransparency = transparency or 0
	frame.BorderSizePixel = 0
	frame.ZIndex = zIndex or 1
	frame.Parent = parent
	return frame
end

local function createLabel(parent: Instance, name: string, text: string, size: UDim2, position: UDim2, color: Color3, textSize: number, bold: boolean?, zIndex: number?): TextLabel
	local label = Instance.new("TextLabel")
	label.Name = name
	label.BackgroundTransparency = 1
	label.Size = size
	label.Position = position
	label.Text = text
	label.TextColor3 = color
	label.Font = bold and Enum.Font.GothamBold or Enum.Font.Gotham
	label.TextSize = textSize
	label.TextWrapped = true
	label.BorderSizePixel = 0
	label.ZIndex = zIndex or 1
	label.Parent = parent
	return label
end

local function createButton(parent: Instance, name: string, text: string, size: UDim2, position: UDim2, color: Color3, zIndex: number?): TextButton
	local button = Instance.new("TextButton")
	button.Name = name
	button.Size = size
	button.Position = position
	button.BackgroundColor3 = color
	button.BorderSizePixel = 0
	button.AutoButtonColor = true
	button.Text = text
	button.TextColor3 = THEME.Text
	button.Font = Enum.Font.GothamBold
	button.TextSize = 13
	button.ZIndex = zIndex or 1
	button.Parent = parent
	round(button, 10)
	outline(button, THEME.Stroke, 1, 0.2)
	return button
end

local function raiseZIndex(root: Instance, amount: number)
	if root:IsA("GuiObject") then
		root.ZIndex += amount
	end
	for _, descendant in ipairs(root:GetDescendants()) do
		if descendant:IsA("GuiObject") then
			descendant.ZIndex += amount
		end
	end
end

local function bindButton(button: GuiObject?, callback: () -> ())
	if not button or state.boundButtons[button] then
		return
	end
	state.boundButtons[button] = true
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

local function getViewportSize(): Vector2
	local camera = Workspace.CurrentCamera
	return camera and camera.ViewportSize or Vector2.new(1280, 720)
end

local function getPlayerWorldPosition(): Vector3?
	local character = Player.Character
	local hrp = character and character:FindFirstChild("HumanoidRootPart")
	if hrp and hrp:IsA("BasePart") then
		return hrp.Position
	end
	return nil
end

local function normaliseBounds(rawBounds: any): Bounds
	local fallback = { MinX = -300, MinZ = -300, MaxX = 300, MaxZ = 300 }
	if type(rawBounds) == "table" then
		fallback = {
			MinX = tonumber(rawBounds.MinX) or fallback.MinX,
			MinZ = tonumber(rawBounds.MinZ) or fallback.MinZ,
			MaxX = tonumber(rawBounds.MaxX) or fallback.MaxX,
			MaxZ = tonumber(rawBounds.MaxZ) or fallback.MaxZ,
		}
	end

	local playerPos = getPlayerWorldPosition()
	if playerPos then
		fallback.MinX = math.min(fallback.MinX, playerPos.X - 60)
		fallback.MinZ = math.min(fallback.MinZ, playerPos.Z - 60)
		fallback.MaxX = math.max(fallback.MaxX, playerPos.X + 60)
		fallback.MaxZ = math.max(fallback.MaxZ, playerPos.Z + 60)
	end

	if fallback.MaxX - fallback.MinX < 1 then
		fallback.MaxX += 1
	end
	if fallback.MaxZ - fallback.MinZ < 1 then
		fallback.MaxZ += 1
	end
	return fallback
end

local function buildMapContentBounds(data: {[string]: any}): Bounds
	local fallback = normaliseBounds(data.Bounds)
	local contentBounds = {
		MinX = fallback.MinX,
		MinZ = fallback.MinZ,
		MaxX = fallback.MaxX,
		MaxZ = fallback.MaxZ,
	}
	local foundContent = false

	local function includePoint(worldX: number?, worldZ: number?, margin: number?)
		if type(worldX) ~= "number" or type(worldZ) ~= "number" then
			return
		end
		local pad = margin or 0
		if not foundContent then
			contentBounds.MinX = worldX - pad
			contentBounds.MaxX = worldX + pad
			contentBounds.MinZ = worldZ - pad
			contentBounds.MaxZ = worldZ + pad
			foundContent = true
			return
		end
		contentBounds.MinX = math.min(contentBounds.MinX, worldX - pad)
		contentBounds.MaxX = math.max(contentBounds.MaxX, worldX + pad)
		contentBounds.MinZ = math.min(contentBounds.MinZ, worldZ - pad)
		contentBounds.MaxZ = math.max(contentBounds.MaxZ, worldZ + pad)
	end

	for _, slope in ipairs(data.Slopes or {}) do
		if type(slope.Points) == "table" then
			for _, point in ipairs(slope.Points) do
				if type(point) == "table" then
					includePoint(point[1], point[3], 24)
				end
			end
		end
	end

	for _, lift in ipairs(data.Lifts or {}) do
		local startPos = lift.StartPos
		local endPos = lift.EndPos
		if type(startPos) == "table" then
			includePoint(startPos[1], startPos[3], 36)
		end
		if type(endPos) == "table" then
			includePoint(endPos[1], endPos[3], 36)
		end
	end

	for _, building in ipairs(data.Buildings or {}) do
		local position = building.Position
		if type(position) == "table" then
			includePoint(position[1], position[3], 26)
		end
	end

	local playerPos = getPlayerWorldPosition()
	if playerPos then
		includePoint(playerPos.X, playerPos.Z, 44)
	end

	if not foundContent then
		return fallback
	end

	local width = math.max(1, contentBounds.MaxX - contentBounds.MinX)
	local height = math.max(1, contentBounds.MaxZ - contentBounds.MinZ)
	local padX = math.max(70, width * 0.12)
	local padZ = math.max(70, height * 0.12)
	contentBounds.MinX -= padX
	contentBounds.MaxX += padX
	contentBounds.MinZ -= padZ
	contentBounds.MaxZ += padZ
	return contentBounds
end

local function rebuildProjection(bounds: Bounds)
	state.bounds = bounds
	local worldWidth = math.max(1, bounds.MaxX - bounds.MinX)
	local worldHeight = math.max(1, bounds.MaxZ - bounds.MinZ)
	state.baseScale = math.min((CONTENT_W - CONTENT_PAD * 2) / worldWidth, (CONTENT_H - CONTENT_PAD * 2) / worldHeight)
	local drawWidth = worldWidth * state.baseScale
	local drawHeight = worldHeight * state.baseScale
	state.baseOffset = Vector2.new(
		CONTENT_PAD + (CONTENT_W - CONTENT_PAD * 2 - drawWidth) * 0.5,
		CONTENT_PAD + (CONTENT_H - CONTENT_PAD * 2 - drawHeight) * 0.5
	)
end

local function worldToContent(worldX: number, worldZ: number): Vector2
	local bounds = state.bounds
	if not bounds then
		return Vector2.new(CONTENT_W * 0.5, CONTENT_H * 0.5)
	end
	return Vector2.new(
		state.baseOffset.X + (worldX - bounds.MinX) * state.baseScale,
		state.baseOffset.Y + (worldZ - bounds.MinZ) * state.baseScale
	)
end

local function clampPanOffset(offset: Vector2): Vector2
	local viewport = state.refs.viewport
	if not viewport then
		return offset
	end
	local viewportSize = viewport.AbsoluteSize
	local scaledSize = Vector2.new(CONTENT_W * state.zoom, CONTENT_H * state.zoom)
	local maxPanX = math.max(0, (scaledSize.X - viewportSize.X) * 0.5 + 40)
	local maxPanY = math.max(0, (scaledSize.Y - viewportSize.Y) * 0.5 + 40)
	return Vector2.new(
		math.clamp(offset.X, -maxPanX, maxPanX),
		math.clamp(offset.Y, -maxPanY, maxPanY)
	)
end

local function refreshZoomVisibility()
	for _, entry in ipairs(state.zoomEntries) do
		if entry.gui and entry.gui.Parent then
			entry.gui.Visible = state.zoom >= entry.minZoom
		end
	end
end

local function updateZoomLabel()
	if state.refs.zoomLabel then
		state.refs.zoomLabel.Text = string.format("%d%%", math.floor(state.zoom * 100 + 0.5))
	end
	if state.refs.statusLabel then
		state.refs.statusLabel.Text = string.format("Drag to explore  •  Scroll or use +/-  •  Zoom %d%%", math.floor(state.zoom * 100 + 0.5))
	end
end

local function applyViewTransform()
	local surface = state.refs.surface
	local surfaceScale = state.refs.surfaceScale
	if not surface or not surfaceScale then
		return
	end
	state.panOffset = clampPanOffset(state.panOffset)
	surface.Position = UDim2.new(0.5, math.floor(state.panOffset.X + 0.5), 0.5, math.floor(state.panOffset.Y + 0.5))
	surfaceScale.Scale = state.zoom
	refreshZoomVisibility()
	updateZoomLabel()
end

local function setZoom(newZoom: number, focusLocalPosition: Vector2?)
	local viewport = state.refs.viewport
	if not viewport then
		return
	end
	local clampedZoom = math.clamp(newZoom, MIN_ZOOM, MAX_ZOOM)
	if math.abs(clampedZoom - state.zoom) < 0.001 then
		return
	end
	local viewportCenter = viewport.AbsoluteSize * 0.5
	local focus = focusLocalPosition or viewportCenter
	local oldZoom = state.zoom
	local mapOffset = (focus - viewportCenter - state.panOffset) / oldZoom
	state.zoom = clampedZoom
	state.panOffset = focus - viewportCenter - mapOffset * state.zoom
	applyViewTransform()
end

local function focusContentPoint(point: Vector2, desiredZoom: number?)
	if desiredZoom then
		state.zoom = math.clamp(desiredZoom, MIN_ZOOM, MAX_ZOOM)
	end
	local contentCenter = Vector2.new(CONTENT_W * 0.5, CONTENT_H * 0.5)
	state.panOffset = -((point - contentCenter) * state.zoom)
	applyViewTransform()
end

local function fitView()
	state.zoom = DEFAULT_ZOOM
	state.panOffset = Vector2.zero
	applyViewTransform()
end

local function focusPlayer()
	local playerPos = getPlayerWorldPosition()
	if not playerPos then
		fitView()
		return
	end
	focusContentPoint(worldToContent(playerPos.X, playerPos.Z), math.max(state.zoom, 1))
end

local function registerZoomEntry(gui: GuiObject, minZoom: number)
	table.insert(state.zoomEntries, { gui = gui, minZoom = minZoom })
end

local function clearDetailBody()
	local detailBody = state.refs.detailBody
	if not detailBody then
		return
	end
	for _, child in ipairs(detailBody:GetChildren()) do
		child:Destroy()
	end
end

local function populateStats(data: {[string]: any})
	local statsBody = state.refs.statsBody
	if not statsBody then
		return
	end
	for _, child in ipairs(statsBody:GetChildren()) do
		child:Destroy()
	end

	local slopes = data.Slopes or {}
	local lifts = data.Lifts or {}
	local buildings = data.Buildings or {}
	local counts = { Green = 0, Blue = 0, Black = 0, ["Double Black"] = 0 }
	for _, slope in ipairs(slopes) do
		local difficulty = tostring(slope.Difficulty or "Green")
		if counts[difficulty] ~= nil then
			counts[difficulty] += 1
		end
	end
	local bounds = state.bounds or normaliseBounds(data.Bounds)
	local worldWidth = math.floor(bounds.MaxX - bounds.MinX + 0.5)
	local worldHeight = math.floor(bounds.MaxZ - bounds.MinZ + 0.5)
	local rows = {
		{ label = "Lifts online", value = tostring(#lifts), color = THEME.Lift },
		{ label = "Trails drawn", value = tostring(#slopes), color = THEME.AccentSoft },
		{ label = "Facilities", value = tostring(#buildings), color = THEME.Building },
		{ label = "World span", value = string.format("%dx%d", worldWidth, worldHeight), color = THEME.Success },
	}

	for index, row in ipairs(rows) do
		local y = (index - 1) * 52
		local card = createFrame(statsBody, "Stat" .. index, UDim2.new(1, 0, 0, 44), UDim2.fromOffset(0, y), THEME.CardAlt, 0, 2)
		round(card, 12)
		outline(card, THEME.Stroke, 1, 0.12)
		local accent = createFrame(card, "Accent", UDim2.fromOffset(4, 24), UDim2.fromOffset(10, 10), row.color, 0, 3)
		round(accent, 4)
		createLabel(card, "Value", row.value, UDim2.new(0, 80, 0, 18), UDim2.fromOffset(24, 7), THEME.Text, 16, true, 4).TextXAlignment = Enum.TextXAlignment.Left
		createLabel(card, "Label", row.label, UDim2.new(1, -36, 0, 14), UDim2.fromOffset(24, 24), THEME.Muted, 11, false, 4).TextXAlignment = Enum.TextXAlignment.Left
	end

	local mix = createFrame(statsBody, "DifficultyMix", UDim2.new(1, 0, 0, 112), UDim2.fromOffset(0, #rows * 52 + 8), THEME.CardAlt, 0, 2)
	round(mix, 12)
	outline(mix, THEME.Stroke, 1, 0.12)
	createLabel(mix, "Title", "Trail mix", UDim2.new(1, -20, 0, 18), UDim2.fromOffset(12, 10), THEME.Text, 14, true, 3).TextXAlignment = Enum.TextXAlignment.Left
	local difficultyRows = {
		{ key = "Green", color = DIFFICULTIES.Green.color },
		{ key = "Blue", color = DIFFICULTIES.Blue.color },
		{ key = "Black", color = DIFFICULTIES.Black.color },
		{ key = "Double Black", color = DIFFICULTIES["Double Black"].color },
	}
	for index, row in ipairs(difficultyRows) do
		local y = 34 + (index - 1) * 18
		local dot = createFrame(mix, row.key .. "Dot", UDim2.fromOffset(10, 10), UDim2.fromOffset(12, y + 2), row.color, 0, 4)
		round(dot, 5)
		createLabel(mix, row.key .. "Label", row.key, UDim2.new(1, -70, 0, 16), UDim2.fromOffset(28, y), THEME.Muted, 11, false, 4).TextXAlignment = Enum.TextXAlignment.Left
		createLabel(mix, row.key .. "Value", tostring(counts[row.key]), UDim2.new(0, 40, 0, 16), UDim2.new(1, -48, 0, y), THEME.Text, 11, true, 4).TextXAlignment = Enum.TextXAlignment.Right
	end
end

local function populateDetails(data: {[string]: any})
	clearDetailBody()
	local detailBody = state.refs.detailBody
	if not detailBody then
		return
	end

	local cards = {
		{ title = "Navigation", body = "Drag to pan around the mountain. Scroll, tap +/-, or use Fit to reframe the whole resort.", accent = THEME.Accent },
		{ title = "Player focus", body = "Use Center on me to snap the map back to your current spot if you get lost while exploring.", accent = THEME.Player },
		{ title = "Reading the map", body = "Lift lines stay visible at any zoom. Trail names and detail badges fade in as you zoom closer for a cleaner overview.", accent = THEME.Success },
	}
	for index, cardData in ipairs(cards) do
		local y = (index - 1) * 82
		local card = createFrame(detailBody, "DetailCard" .. index, UDim2.new(1, 0, 0, 72), UDim2.fromOffset(0, y), THEME.CardAlt, 0, 2)
		round(card, 12)
		outline(card, THEME.Stroke, 1, 0.12)
		local accent = createFrame(card, "Accent", UDim2.fromOffset(4, 24), UDim2.fromOffset(10, 12), cardData.accent, 0, 3)
		round(accent, 4)
		createLabel(card, "Title", cardData.title, UDim2.new(1, -28, 0, 18), UDim2.fromOffset(24, 10), THEME.Text, 13, true, 4).TextXAlignment = Enum.TextXAlignment.Left
		local body = createLabel(card, "Body", cardData.body, UDim2.new(1, -28, 0, 34), UDim2.fromOffset(24, 30), THEME.Muted, 11, false, 4)
		body.TextXAlignment = Enum.TextXAlignment.Left
		body.TextYAlignment = Enum.TextYAlignment.Top
	end

	local legend = createFrame(detailBody, "LegendCard", UDim2.new(1, 0, 0, 150), UDim2.fromOffset(0, 82 * #cards + 8), THEME.CardAlt, 0, 2)
	round(legend, 12)
	outline(legend, THEME.Stroke, 1, 0.12)
	createLabel(legend, "LegendTitle", "Legend", UDim2.new(1, -20, 0, 18), UDim2.fromOffset(12, 10), THEME.Text, 14, true, 3).TextXAlignment = Enum.TextXAlignment.Left
	local legendRows = {
		{ label = "Lift", color = THEME.Lift, symbol = "--" },
		{ label = "Facility", color = THEME.Building, symbol = "[]" },
		{ label = "You", color = THEME.Player, symbol = "ME" },
		{ label = "Green", color = DIFFICULTIES.Green.color, symbol = "G" },
		{ label = "Blue", color = DIFFICULTIES.Blue.color, symbol = "B" },
		{ label = "Black", color = DIFFICULTIES.Black.color, symbol = "K" },
		{ label = "Double Black", color = DIFFICULTIES["Double Black"].color, symbol = "2K" },
	}
	for index, row in ipairs(legendRows) do
		local column = (index - 1) % 2
		local r = math.floor((index - 1) / 2)
		local x = 12 + column * 106
		local y = 38 + r * 30
		local badge = createFrame(legend, "LegendBadge" .. index, UDim2.fromOffset(28, 18), UDim2.fromOffset(x, y), row.color, 0, 4)
		round(badge, 8)
		createLabel(badge, "Symbol", row.symbol, UDim2.new(1, 0, 1, 0), UDim2.fromOffset(0, 0), Color3.new(1, 1, 1), 9, true, 5).TextXAlignment = Enum.TextXAlignment.Center
		createLabel(legend, "LegendText" .. index, row.label, UDim2.fromOffset(70, 18), UDim2.fromOffset(x + 34, y), THEME.Muted, 11, false, 4).TextXAlignment = Enum.TextXAlignment.Left
	end
end

local function renderBackdrop(surface: Frame)
	local backdrop = createFrame(surface, "Backdrop", UDim2.fromOffset(CONTENT_W, CONTENT_H), UDim2.fromOffset(0, 0), THEME.MapBase, 0, 1)
	addGradient(backdrop, ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(238, 242, 246)),
		ColorSequenceKeypoint.new(0.2, Color3.fromRGB(205, 214, 216)),
		ColorSequenceKeypoint.new(0.48, THEME.MapMid),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(74, 105, 80)),
	}), 90)

	local shadowSpecs = {
		{ pos = Vector2.new(320, 310), size = Vector2.new(820, 300), rotation = -14, color = Color3.fromRGB(92, 116, 98), alpha = 0.16 },
		{ pos = Vector2.new(1090, 250), size = Vector2.new(980, 320), rotation = 12, color = Color3.fromRGB(110, 132, 116), alpha = 0.2 },
		{ pos = Vector2.new(1460, 470), size = Vector2.new(740, 220), rotation = -9, color = Color3.fromRGB(78, 102, 84), alpha = 0.24 },
	}
	for index, spec in ipairs(shadowSpecs) do
		local ridge = createFrame(backdrop, "Ridge" .. index, UDim2.fromOffset(spec.size.X, spec.size.Y), UDim2.fromOffset(spec.pos.X, spec.pos.Y), spec.color, spec.alpha, 2)
		ridge.AnchorPoint = Vector2.new(0.5, 0.5)
		ridge.Rotation = spec.rotation
		round(ridge, math.floor(spec.size.Y * 0.45))
	end

	for i = 0, 18 do
		local y = 170 + i * 58
		local contour = createFrame(backdrop, "Contour" .. i, UDim2.fromOffset(CONTENT_W + 120, 2), UDim2.fromOffset(CONTENT_W * 0.5, y), Color3.fromRGB(70, 92, 74), 0.78, 3)
		contour.AnchorPoint = Vector2.new(0.5, 0.5)
		contour.Rotation = -10 + (i % 3) * 4
		round(contour, 2)
	end

	for i = 1, 8 do
		local snow = createFrame(backdrop, "SnowBand" .. i, UDim2.fromOffset(420 + i * 34, 32), UDim2.fromOffset(200 + i * 175, 150 + (i % 3) * 40), THEME.MapSnow, 0.72, 4)
		snow.AnchorPoint = Vector2.new(0.5, 0.5)
		snow.Rotation = -11 + i
		round(snow, 18)
	end
end

local function createMapLine(parent: Instance, name: string, p1: Vector2, p2: Vector2, color: Color3, thickness: number, transparency: number?, zIndex: number?): Frame?
	local delta = p2 - p1
	local length = delta.Magnitude
	if length < 0.5 then
		return nil
	end
	local line = createFrame(parent, name, UDim2.fromOffset(length, thickness), UDim2.fromOffset((p1.X + p2.X) * 0.5, (p1.Y + p2.Y) * 0.5), color, transparency, zIndex)
	line.AnchorPoint = Vector2.new(0.5, 0.5)
	line.Rotation = math.deg(math.atan2(delta.Y, delta.X))
	round(line, math.max(1, math.floor(thickness * 0.5)))
	return line
end

local function createPillLabel(parent: Instance, name: string, textValue: string, size: Vector2, position: Vector2, fill: Color3, textColor: Color3, zIndex: number): Frame
	local edgeMargin = 16
	local clampedPosition = Vector2.new(
		math.clamp(position.X, size.X * 0.5 + edgeMargin, CONTENT_W - size.X * 0.5 - edgeMargin),
		math.clamp(position.Y, size.Y * 0.5 + edgeMargin, CONTENT_H - size.Y * 0.5 - edgeMargin)
	)
	local pill = createFrame(parent, name, UDim2.fromOffset(size.X, size.Y), UDim2.fromOffset(clampedPosition.X, clampedPosition.Y), fill, 0.08, zIndex)
	pill.AnchorPoint = Vector2.new(0.5, 0.5)
	round(pill, math.floor(size.Y * 0.5))
	outline(pill, Color3.fromRGB(255, 255, 255), 1, 0.88)
	local label = createLabel(pill, "Text", textValue, UDim2.new(1, -10, 1, 0), UDim2.fromOffset(5, 0), textColor, 12, true, zIndex + 1)
	label.TextXAlignment = Enum.TextXAlignment.Center
	return pill
end

local function renderSlopes(surface: Frame, slopes: {{[string]: any}})
	for index, slope in ipairs(slopes) do
		local points = slope.Points
		if type(points) ~= "table" or #points < 2 then
			continue
		end
		local diffName = tostring(slope.Difficulty or "Green")
		local diff = DIFFICULTIES[diffName] or DEFAULT_DIFFICULTY
		for i = 2, #points do
			local prev = points[i - 1] :: PackedPoint
			local curr = points[i] :: PackedPoint
			local p1 = worldToContent(prev[1], prev[3])
			local p2 = worldToContent(curr[1], curr[3])
			createMapLine(surface, string.format("SlopeShadow_%d_%d", index, i), p1, p2, Color3.fromRGB(14, 20, 16), diff.width + 9, 0.44, 9)
			createMapLine(surface, string.format("SlopeOutline_%d_%d", index, i), p1, p2, Color3.fromRGB(250, 250, 250), diff.width + 5, 0.02, 10)
			createMapLine(surface, string.format("SlopeLine_%d_%d", index, i), p1, p2, diff.color, diff.width + (diffName == "Green" and 1 or 0), 0, 11)
		end
		local top = points[1] :: PackedPoint
		local mid = points[math.ceil(#points * 0.5)] :: PackedPoint
		local topPos = worldToContent(top[1], top[3]) + Vector2.new(0, -18)
		local midPos = worldToContent(mid[1], mid[3])
		local nameLabel = createPillLabel(surface, "SlopeLabel" .. index, tostring(slope.Name or "Trail"), Vector2.new(122, 24), topPos, Color3.fromRGB(18, 23, 32), THEME.Text, 14)
		registerZoomEntry(nameLabel, diff.minZoom)
		local badge = createFrame(surface, "SlopeBadge" .. index, UDim2.fromOffset(diffName == "Double Black" and 24 or 20, diffName == "Double Black" and 24 or 20), UDim2.fromOffset(midPos.X, midPos.Y), diff.color, 0, 14)
		badge.AnchorPoint = Vector2.new(0.5, 0.5)
		round(badge, 999)
		createLabel(badge, "Symbol", diff.symbol, UDim2.new(1, 0, 1, 0), UDim2.fromOffset(0, 0), Color3.new(1, 1, 1), diffName == "Double Black" and 7 or 10, true, 15).TextXAlignment = Enum.TextXAlignment.Center
		registerZoomEntry(badge, diff.minZoom)
	end
end

local function renderLifts(surface: Frame, lifts: {{[string]: any}})
	for index, lift in ipairs(lifts) do
		local startPos = lift.StartPos
		local endPos = lift.EndPos
		if type(startPos) ~= "table" or type(endPos) ~= "table" then
			continue
		end
		local p1 = worldToContent(startPos[1], startPos[3])
		local p2 = worldToContent(endPos[1], endPos[3])
		local delta = p2 - p1
		local length = delta.Magnitude
		if length < 2 then
			continue
		end
		createMapLine(surface, "LiftShadow" .. index, p1, p2, THEME.LiftDark, 3, 0.1, 18)
		local segments = math.max(1, math.floor(length / 42))
		for seg = 0, segments - 1 do
			local t1 = seg / segments
			local t2 = math.min(1, t1 + 0.55 / segments)
			createMapLine(surface, string.format("LiftDash_%d_%d", index, seg), p1 + delta * t1, p1 + delta * t2, THEME.Lift, 4, 0, 19)
		end
		for stationIndex, station in ipairs({ p1, p2 }) do
			local halo = createFrame(surface, string.format("StationHalo_%d_%d", index, stationIndex), UDim2.fromOffset(20, 20), UDim2.fromOffset(station.X, station.Y), THEME.Lift, 0.4, 20)
			halo.AnchorPoint = Vector2.new(0.5, 0.5)
			round(halo, 999)
			local stationNode = createFrame(surface, string.format("Station_%d_%d", index, stationIndex), UDim2.fromOffset(12, 12), UDim2.fromOffset(station.X, station.Y), THEME.Lift, 0, 21)
			stationNode.AnchorPoint = Vector2.new(0.5, 0.5)
			round(stationNode, 999)
			outline(stationNode, Color3.new(1, 1, 1), 2, 0.05)
		end
		local labelPos = p1:Lerp(p2, 0.5) + Vector2.new(0, -24)
		local pill = createPillLabel(surface, "LiftLabel" .. index, tostring(lift.Name or "Lift"), Vector2.new(138, 26), labelPos, Color3.fromRGB(28, 25, 21), Color3.fromRGB(255, 220, 198), 22)
		registerZoomEntry(pill, 0.78)
	end
end

local function renderBuildings(surface: Frame, buildings: {{[string]: any}})
	for index, building in ipairs(buildings) do
		local position = building.Position
		if type(position) ~= "table" then
			continue
		end
		local mapPos = worldToContent(position[1], position[3])
		local marker = createFrame(surface, "BuildingMarker" .. index, UDim2.fromOffset(28, 28), UDim2.fromOffset(mapPos.X, mapPos.Y), THEME.Building, 0, 23)
		marker.AnchorPoint = Vector2.new(0.5, 0.5)
		round(marker, 8)
		outline(marker, Color3.fromRGB(80, 60, 10), 1.5, 0.12)
		createLabel(marker, "Icon", BUILDING_ICONS[tostring(building.Type or "Building")] or "BASE", UDim2.new(1, 0, 1, 0), UDim2.fromOffset(0, 0), Color3.fromRGB(50, 42, 15), 9, true, 24).TextXAlignment = Enum.TextXAlignment.Center
		local label = createPillLabel(surface, "BuildingLabel" .. index, tostring(building.Name or "Facility"), Vector2.new(110, 22), mapPos + Vector2.new(0, 24), Color3.fromRGB(40, 36, 24), Color3.fromRGB(255, 237, 190), 24)
		registerZoomEntry(label, 1.1)
	end
end

local function renderPlayerMarker(surface: Frame)
	local dot = createFrame(surface, "PlayerDot", UDim2.fromOffset(18, 18), UDim2.fromOffset(-1000, -1000), THEME.Player, 0, 28)
	dot.AnchorPoint = Vector2.new(0.5, 0.5)
	round(dot, 999)
	outline(dot, Color3.new(1, 1, 1), 2, 0.05)
	local pulse = createFrame(dot, "Pulse", UDim2.fromOffset(30, 30), UDim2.fromOffset(-6, -6), THEME.Player, 0.52, 27)
	round(pulse, 999)
	TweenService:Create(pulse, TweenInfo.new(1.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out, -1, false), {
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(42, 42),
		Position = UDim2.fromOffset(-12, -12),
	}):Play()
	local label = createPillLabel(surface, "PlayerLabel", "YOU", Vector2.new(56, 22), Vector2.new(-1000, -1000), Color3.fromRGB(170, 36, 36), THEME.Text, 29)
	state.refs.playerDot = dot
	state.refs.playerLabel = label
end

local function updatePlayerMarker()
	local dot = state.refs.playerDot
	local label = state.refs.playerLabel
	if not dot or not label or not state.bounds then
		return
	end
	local playerPos = getPlayerWorldPosition()
	if not playerPos then
		return
	end
	local mapPos = worldToContent(playerPos.X, playerPos.Z)
	dot.Position = UDim2.fromOffset(mapPos.X, mapPos.Y)
	label.Position = UDim2.fromOffset(mapPos.X, mapPos.Y - 26)
end

local function destroyMapGui()
	clearConnections()
	state.zoomEntries = {}
	state.hoveringViewport = false
	state.dragging = false
	state.dragInput = nil
	local currentGui = state.refs.gui
	state.refs = {}
	if currentGui and currentGui.Parent then
		currentGui:Destroy()
	end
	local gui = PlayerGui:FindFirstChild("ResortMapGui")
	if gui and gui:IsA("ScreenGui") then
		gui:Destroy()
	end
end

local function buildMapGui(data: {[string]: any})
	destroyMapGui()
	state.mapData = data
	rebuildProjection(buildMapContentBounds(data))
	state.zoom = DEFAULT_ZOOM
	state.panOffset = Vector2.zero

	local viewportSize = getViewportSize()
	local compact = viewportSize.X < 1280
	local panelWidth = math.clamp(math.floor(viewportSize.X - 120), 1020, 1460)
	local panelHeight = math.clamp(math.floor(viewportSize.Y - 80), 660, 860)
	local sideWidth = compact and 214 or 248
	local contentGap = 12
	local viewportWidth = panelWidth - sideWidth * 2 - contentGap * 4
	local viewportHeight = panelHeight - 108

	local gui = Instance.new("ScreenGui")
	gui.Name = "ResortMapGui"
	gui.ResetOnSpawn = false
	gui.DisplayOrder = 35
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.Parent = PlayerGui

	local overlay = createFrame(gui, "Overlay", UDim2.fromScale(10, 10), UDim2.fromScale(-4.5, -4.5), Color3.fromRGB(5, 8, 14), 0.34, 1)
	bindButton(overlay, function()
		MapClientRuntime.Close()
	end)

	local panel = createFrame(gui, "MapPanel", UDim2.fromOffset(panelWidth, panelHeight), OPEN_PANEL_POSITION, THEME.Panel, 0, 2)
	panel.AnchorPoint = Vector2.new(0.5, 0.5)
	round(panel, 18)
	outline(panel, THEME.Stroke, 1.5, 0.05)
	addGradient(panel, ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(20, 22, 28)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(12, 14, 18)),
	}), 90)

	local header = createFrame(panel, "Header", UDim2.new(1, -20, 0, 56), UDim2.fromOffset(10, 10), THEME.Header, 0, 3)
	round(header, 14)
	outline(header, THEME.Stroke, 1, 0.1)
	createLabel(header, "Title", "Resort Trail Map", UDim2.new(1, -250, 0, 24), UDim2.fromOffset(74, 8), THEME.Text, 22, true, 4).TextXAlignment = Enum.TextXAlignment.Left
	local subtitleText = string.format("%d trails  •  %d lifts  •  %d facilities", #(data.Slopes or {}), #(data.Lifts or {}), #(data.Buildings or {}))
	local subtitle = createLabel(header, "Subtitle", subtitleText, UDim2.new(1, -250, 0, 16), UDim2.fromOffset(74, 32), THEME.Muted, 11, false, 4)
	subtitle.TextXAlignment = Enum.TextXAlignment.Left
	local zoomChip = createFrame(header, "ZoomChip", UDim2.fromOffset(88, 30), UDim2.new(1, -196, 0, 13), THEME.CardAlt, 0, 4)
	round(zoomChip, 10)
	outline(zoomChip, THEME.Stroke, 1, 0.12)
	local zoomLabel = createLabel(zoomChip, "ZoomLabel", "100%", UDim2.new(1, 0, 1, 0), UDim2.fromOffset(0, 0), THEME.Text, 12, true, 5)
	zoomLabel.TextXAlignment = Enum.TextXAlignment.Center
	local closeButton = createButton(header, "CloseButton", "X", UDim2.fromOffset(38, 38), UDim2.new(1, -48, 0, 9), THEME.Danger, 5)

	local leftColumn = createFrame(panel, "LeftColumn", UDim2.fromOffset(sideWidth, viewportHeight), UDim2.fromOffset(10, 76), THEME.PanelAlt, 0, 3)
	round(leftColumn, 16)
	outline(leftColumn, THEME.Stroke, 1, 0.12)
	local rightColumn = createFrame(panel, "RightColumn", UDim2.fromOffset(sideWidth, viewportHeight), UDim2.fromOffset(panelWidth - sideWidth - 10, 76), THEME.PanelAlt, 0, 3)
	round(rightColumn, 16)
	outline(rightColumn, THEME.Stroke, 1, 0.12)
	local viewport = createFrame(panel, "Viewport", UDim2.fromOffset(viewportWidth, viewportHeight), UDim2.fromOffset(sideWidth + contentGap * 2, 76), THEME.Card, 0, 3)
	round(viewport, 16)
	outline(viewport, THEME.Stroke, 1, 0.08)
	viewport.ClipsDescendants = true

	local statusBar = createFrame(viewport, "StatusBar", UDim2.new(1, -24, 0, 28), UDim2.fromOffset(12, 12), Color3.fromRGB(12, 16, 22), 0.18, 5)
	round(statusBar, 10)
	local statusLabel = createLabel(statusBar, "Status", "Drag to explore  •  Scroll or use +/-", UDim2.new(1, -12, 1, 0), UDim2.fromOffset(12, 0), THEME.Text, 11, false, 6)
	statusLabel.TextXAlignment = Enum.TextXAlignment.Left

	local controls = createFrame(leftColumn, "ControlsCard", UDim2.new(1, -20, 0, 136), UDim2.fromOffset(10, 10), THEME.Card, 0, 4)
	round(controls, 14)
	outline(controls, THEME.Stroke, 1, 0.12)
	createLabel(controls, "ControlsTitle", "Map tools", UDim2.new(1, -20, 0, 18), UDim2.fromOffset(12, 10), THEME.Text, 14, true, 5).TextXAlignment = Enum.TextXAlignment.Left
	createLabel(controls, "ControlsBody", "Use these when you want a quick reframe without dragging the map around by hand.", UDim2.new(1, -20, 0, 30), UDim2.fromOffset(12, 30), THEME.Muted, 11, false, 5).TextXAlignment = Enum.TextXAlignment.Left
	local zoomOutButton = createButton(controls, "ZoomOut", "-", UDim2.new(0.5, -8, 0, 34), UDim2.fromOffset(12, 78), THEME.CardAlt, 5)
	local zoomInButton = createButton(controls, "ZoomIn", "+", UDim2.new(0.5, -8, 0, 34), UDim2.new(0.5, 4, 0, 78), THEME.Accent, 5)
	local resetButton = createButton(controls, "FitButton", "Fit resort", UDim2.new(0.5, -8, 0, 30), UDim2.fromOffset(12, 116), THEME.CardAlt, 5)
	local playerButton = createButton(controls, "PlayerButton", "Center on me", UDim2.new(0.5, -8, 0, 30), UDim2.new(0.5, 4, 0, 116), THEME.Success, 5)

	local statsLabel = createLabel(leftColumn, "StatsTitle", "Mountain readout", UDim2.new(1, -20, 0, 18), UDim2.fromOffset(12, 158), THEME.Text, 14, true, 4)
	statsLabel.TextXAlignment = Enum.TextXAlignment.Left
	local statsBody = createFrame(leftColumn, "StatsBody", UDim2.new(1, -20, 1, -190), UDim2.fromOffset(10, 186), THEME.PanelAlt, 1, 4)
	statsBody.BorderSizePixel = 0

	local detailHeader = createLabel(rightColumn, "DetailTitle", "Map notes", UDim2.new(1, -20, 0, 18), UDim2.fromOffset(12, 12), THEME.Text, 14, true, 4)
	detailHeader.TextXAlignment = Enum.TextXAlignment.Left
	local detailBody = createFrame(rightColumn, "DetailBody", UDim2.new(1, -20, 1, -40), UDim2.fromOffset(10, 36), THEME.PanelAlt, 1, 4)
	detailBody.BorderSizePixel = 0

	local footer = createFrame(panel, "Footer", UDim2.new(1, -20, 0, 26), UDim2.fromOffset(10, panelHeight - 36), THEME.Header, 0, 3)
	round(footer, 12)
	outline(footer, THEME.Stroke, 1, 0.15)
	local bounds = state.bounds or normaliseBounds(data.Bounds)
	local footerText = createLabel(footer, "FooterText", string.format("World span: %d x %d studs  •  Press M to close", math.floor(bounds.MaxX - bounds.MinX + 0.5), math.floor(bounds.MaxZ - bounds.MinZ + 0.5)), UDim2.new(1, -18, 1, 0), UDim2.fromOffset(12, 0), THEME.Muted, 11, false, 4)
	footerText.TextXAlignment = Enum.TextXAlignment.Left

	raiseZIndex(header, 40)
	raiseZIndex(leftColumn, 40)
	raiseZIndex(rightColumn, 40)
	raiseZIndex(footer, 40)

	local surface = createFrame(viewport, "MapSurface", UDim2.fromOffset(CONTENT_W, CONTENT_H), UDim2.fromScale(0.5, 0.5), THEME.MapBase, 0, 4)
	surface.AnchorPoint = Vector2.new(0.5, 0.5)
	local surfaceScale = Instance.new("UIScale")
	surfaceScale.Parent = surface

	state.refs = {
		gui = gui,
		panel = panel,
		viewport = viewport,
		surface = surface,
		surfaceScale = surfaceScale,
		zoomLabel = zoomLabel,
		statusLabel = statusLabel,
		statsBody = statsBody,
		detailBody = detailBody,
		resetButton = resetButton,
		playerButton = playerButton,
		zoomInButton = zoomInButton,
		zoomOutButton = zoomOutButton,
		closeButton = closeButton,
	}

	renderBackdrop(surface)
	if data.Slopes and #data.Slopes > 0 then
		renderSlopes(surface, data.Slopes)
	else
		local emptyCard = createFrame(surface, "EmptyState", UDim2.fromOffset(320, 62), UDim2.fromOffset(CONTENT_W * 0.5, CONTENT_H * 0.5 - 10), Color3.fromRGB(18, 22, 28), 0.1, 24)
		emptyCard.AnchorPoint = Vector2.new(0.5, 0.5)
		round(emptyCard, 14)
		outline(emptyCard, THEME.Stroke, 1, 0.18)
		local emptyTitle = createLabel(emptyCard, "EmptyTitle", "No trails placed yet", UDim2.new(1, -20, 0, 18), UDim2.fromOffset(10, 12), THEME.Text, 14, true, 25)
		emptyTitle.TextXAlignment = Enum.TextXAlignment.Center
		local emptyBody = createLabel(emptyCard, "EmptyBody", "Lift lines still show the resort footprint. Add runs and zoom in to get the full ski-map look.", UDim2.new(1, -20, 0, 22), UDim2.fromOffset(10, 32), THEME.Muted, 11, false, 25)
		emptyBody.TextXAlignment = Enum.TextXAlignment.Center
	end
	if data.Lifts and #data.Lifts > 0 then
		renderLifts(surface, data.Lifts)
	end
	if data.Buildings and #data.Buildings > 0 then
		renderBuildings(surface, data.Buildings)
	end
	renderPlayerMarker(surface)
	updatePlayerMarker()
	populateStats(data)
	populateDetails(data)
	applyViewTransform()

	bindButton(closeButton, function()
		MapClientRuntime.Close()
	end)
	bindButton(zoomInButton, function()
		setZoom(state.zoom * 1.18)
	end)
	bindButton(zoomOutButton, function()
		setZoom(state.zoom / 1.18)
	end)
	bindButton(resetButton, fitView)
	bindButton(playerButton, focusPlayer)

	addConnection(viewport.MouseEnter:Connect(function()
		state.hoveringViewport = true
	end))
	addConnection(viewport.MouseLeave:Connect(function()
		state.hoveringViewport = false
	end))
	addConnection(viewport.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			state.dragging = true
			state.dragInput = input
			state.dragStartPosition = Vector2.new(input.Position.X, input.Position.Y)
			state.dragStartPan = state.panOffset
		end
	end))
	addConnection(UserInputService.InputChanged:Connect(function(input)
		if not state.refs.viewport then
			return
		end
		if state.dragging and state.dragInput and (input == state.dragInput or input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
			local now = Vector2.new(input.Position.X, input.Position.Y)
			state.panOffset = state.dragStartPan + (now - state.dragStartPosition)
			applyViewTransform()
		end
		if state.isOpen and state.hoveringViewport and input.UserInputType == Enum.UserInputType.MouseWheel then
			local localPosition = Vector2.new(input.Position.X, input.Position.Y) - state.refs.viewport.AbsolutePosition
			local direction = if input.Position.Z > 0 then 1 else -1
			setZoom(state.zoom * (direction > 0 and 1.12 or 0.88), localPosition)
		end
	end))
	addConnection(UserInputService.InputEnded:Connect(function(input)
		if state.dragInput and input == state.dragInput then
			state.dragging = false
			state.dragInput = nil
		end
	end))
end

local function showLoadingDialog()
	local gui = Instance.new("ScreenGui")
	gui.Name = "ResortMapLoading"
	gui.ResetOnSpawn = false
	gui.DisplayOrder = 34
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.Parent = PlayerGui
	local card = createFrame(gui, "Card", UDim2.fromOffset(320, 88), UDim2.fromScale(0.5, 0.5), THEME.Header, 0, 2)
	card.AnchorPoint = Vector2.new(0.5, 0.5)
	round(card, 14)
	outline(card, THEME.Stroke, 1, 0.08)
	local title = createLabel(card, "Title", "Loading mountain map", UDim2.new(1, -20, 0, 20), UDim2.fromOffset(12, 16), THEME.Text, 16, true, 3)
	title.TextXAlignment = Enum.TextXAlignment.Center
	local subtitle = createLabel(card, "Subtitle", "Pulling the latest resort layout and drawing a cleaner ski map...", UDim2.new(1, -26, 0, 32), UDim2.fromOffset(13, 42), THEME.Muted, 11, false, 3)
	subtitle.TextXAlignment = Enum.TextXAlignment.Center
	return gui
end

function MapClientRuntime.Open()
	if state.isOpen or state.isLoading then
		return
	end
	if not MapRemote then
		warn("[MapClient] GetResortMapData remote not found")
		return
	end
	state.isLoading = true
	local loadingGui = showLoadingDialog()
	local ok, data = pcall(function()
		return MapRemote:InvokeServer()
	end)
	loadingGui:Destroy()
	state.isLoading = false
	if not ok or type(data) ~= "table" then
		warn("[MapClient] Map data failed: " .. tostring(data))
		return
	end
	buildMapGui(data)
	state.isOpen = true
	if state.refs.panel then
		state.refs.panel.Position = UDim2.new(0.5, 0, 1.4, 0)
		TweenService:Create(state.refs.panel, TweenInfo.new(0.35, Enum.EasingStyle.Quart, Enum.EasingDirection.Out), {
			Position = OPEN_PANEL_POSITION,
		}):Play()
	end
end

function MapClientRuntime.Close()
	if not state.isOpen then
		return
	end
	state.isOpen = false
	local panel = state.refs.panel
	local gui = state.refs.gui
	if panel and gui then
		local tween = TweenService:Create(panel, TweenInfo.new(0.22, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
			Position = UDim2.new(0.5, 0, 1.35, 0),
		})
		tween:Play()
		tween.Completed:Connect(function()
			if gui.Parent then
				gui:Destroy()
			end
			destroyMapGui()
		end)
	else
		destroyMapGui()
	end
end

local function toggleMap()
	if state.isOpen then
		MapClientRuntime.Close()
	else
		MapClientRuntime.Open()
	end
end

local function findGuiObjectByName(name: string): GuiObject?
	for _, descendant in ipairs(PlayerGui:GetDescendants()) do
		if descendant:IsA("GuiObject") and descendant.Name == name then
			return descendant
		end
	end
	return nil
end

local function ensureTopButton()
	if state.topButton and state.topButton.Parent and state.topButtonGui and state.topButtonGui.Parent then
		return
	end

	local buttonGui = PlayerGui:FindFirstChild(MAP_BUTTON_GUI_NAME)
	if buttonGui and not buttonGui:IsA("ScreenGui") then
		buttonGui:Destroy()
		buttonGui = nil
	end
	if not buttonGui then
		local createdGui = Instance.new("ScreenGui")
		createdGui.Name = MAP_BUTTON_GUI_NAME
		createdGui.ResetOnSpawn = false
		createdGui.IgnoreGuiInset = false
		createdGui.ClipToDeviceSafeArea = true
		createdGui.ScreenInsets = Enum.ScreenInsets.CoreUISafeInsets
		createdGui.DisplayOrder = 8
		createdGui.ZIndexBehavior = Enum.ZIndexBehavior.Global
		createdGui.Parent = PlayerGui
		buttonGui = createdGui
		state.topButtonGui = createdGui
		state.topButton = nil
	else
		state.topButtonGui = buttonGui
	end

	local button = buttonGui:FindFirstChild(MAP_TOP_BUTTON_NAME)
	if button and not button:IsA("ImageButton") then
		button:Destroy()
		button = nil
	end
	if not button then
		local createdButton = Instance.new("ImageButton")
		createdButton.Name = MAP_TOP_BUTTON_NAME
		createdButton.Size = UDim2.fromOffset(42, 42)
		createdButton.BackgroundColor3 = Color3.fromRGB(20, 24, 33)
		createdButton.BackgroundTransparency = 0.02
		createdButton.BorderSizePixel = 0
		createdButton.AutoButtonColor = true
		createdButton.Image = ""
		createdButton.ScaleType = Enum.ScaleType.Fit
		createdButton.ZIndex = 10
		createdButton.Parent = buttonGui
		round(createdButton, 12)
		outline(createdButton, Color3.fromRGB(66, 78, 98), 1, 0.08)
		addGradient(createdButton, ColorSequence.new({
			ColorSequenceKeypoint.new(0, Color3.fromRGB(34, 40, 56)),
			ColorSequenceKeypoint.new(1, Color3.fromRGB(13, 17, 24)),
		}), 90)

		local fallback = Instance.new("TextLabel")
		fallback.Name = "FallbackLabel"
		fallback.BackgroundTransparency = 1
		fallback.Size = UDim2.fromScale(1, 1)
		fallback.Font = Enum.Font.GothamBlack
		fallback.Text = "MAP"
		fallback.TextColor3 = THEME.Text
		fallback.TextSize = 9
		fallback.ZIndex = 11
		fallback.Parent = createdButton

		local keyHint = Instance.new("TextLabel")
		keyHint.Name = "KeyHint"
		keyHint.BackgroundTransparency = 1
		keyHint.AnchorPoint = Vector2.new(1, 0)
		keyHint.Position = UDim2.new(1, -4, 0, 2)
		keyHint.Size = UDim2.fromOffset(16, 10)
		keyHint.Font = Enum.Font.GothamBlack
		keyHint.Text = ""
		keyHint.TextColor3 = THEME.Muted
		keyHint.TextSize = 8
		keyHint.TextXAlignment = Enum.TextXAlignment.Right
		keyHint.ZIndex = 11
		keyHint.Parent = createdButton

		button = createdButton
	end

	state.topButton = button
	bindButton(button, toggleMap)
end

local function updateTopButtonLayout()
	ensureTopButton()
	local button = state.topButton
	if not button then
		return
	end

	button.Visible = true
	local fallback = button:FindFirstChild("FallbackLabel")
	if fallback and fallback:IsA("TextLabel") then
		fallback.Visible = true
	end
	local keyHint = button:FindFirstChild("KeyHint")
	if keyHint and keyHint:IsA("TextLabel") then
		keyHint.Visible = not UserInputService.TouchEnabled
	end

	local buttonSize = button.AbsoluteSize
	if buttonSize.X <= 0 or buttonSize.Y <= 0 then
		buttonSize = Vector2.new(42, 42)
	end

	local anchor = findGuiObjectByName(RESORT_SETTINGS_TOP_BUTTON_NAME)
	if not anchor or not anchor.Visible then
		anchor = findGuiObjectByName(WAYPOINT_TOP_BUTTON_NAME)
	end

	if anchor and anchor ~= button and anchor.Visible then
		button.Position = UDim2.fromOffset(
			math.floor(anchor.AbsolutePosition.X + math.max(0, (anchor.AbsoluteSize.X - buttonSize.X) * 0.5)),
			math.floor(anchor.AbsolutePosition.Y + anchor.AbsoluteSize.Y + 8)
		)
		return
	end

	local viewport = getViewportSize()
	local rightMargin = UserInputService.TouchEnabled and 18 or 22
	local topMargin = UserInputService.TouchEnabled and 222 or 192
	button.Position = UDim2.fromOffset(
		math.floor(viewport.X - buttonSize.X - rightMargin),
		math.floor(topMargin)
	)
end

local function bindMapButtonsInGui(root: Instance)
	for _, descendant in ipairs(root:GetDescendants()) do
		if descendant:IsA("GuiObject") and descendant.Name == "MapButton" then
			bindButton(descendant, toggleMap)
		end
	end
end

function MapClientRuntime.Run()
	if state.started then
		return
	end
	state.started = true
	if not MapRemote then
		warn("[MapClient] GetResortMapData remote not found")
		return
	end

	ensureTopButton()
	updateTopButtonLayout()

	UserInputService.InputBegan:Connect(function(input, processed)
		if processed then
			return
		end
		if input.KeyCode == Enum.KeyCode.Escape and state.isOpen then
			MapClientRuntime.Close()
		end
	end)

	RunService.Heartbeat:Connect(function()
		updateTopButtonLayout()
		if state.isOpen then
			updatePlayerMarker()
		end
	end)

	task.defer(function()
		for _, gui in ipairs(PlayerGui:GetChildren()) do
			bindMapButtonsInGui(gui)
		end
		updateTopButtonLayout()
	end)
	PlayerGui.ChildAdded:Connect(function(child)
		task.defer(function()
			bindMapButtonsInGui(child)
			updateTopButtonLayout()
		end)
	end)
	PlayerGui.DescendantRemoving:Connect(function(descendant)
		if descendant.Name == WAYPOINT_TOP_BUTTON_NAME or descendant.Name == RESORT_SETTINGS_TOP_BUTTON_NAME then
			task.defer(updateTopButtonLayout)
		end
	end)

	print("[MapClient] Enhanced map ready.")
end

return MapClientRuntime
