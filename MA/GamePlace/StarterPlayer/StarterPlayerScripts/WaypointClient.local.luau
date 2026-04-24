--[=[ PATH: StarterPlayerScripts/WaypointClient | TYPE: LocalScript ]=]--
--[[
SCRIPT: WaypointClient
DOES: Manages a local UI and world markers for waypoints (Spawn, Lifts, Services, Vehicles, Runs). Handles tracking, teleportation, dynamic visibility based on distance, and saves player preferences.
OLD SCRIPT DID:
- Displayed waypoints using screen-sized offsets so they changed physical size as the camera moved.
- Waypoints were always visible regardless of distance.
- Only had one full-info display style for markers.
ADDED/REMOVED:
- Added physical world sizing using UDim2 Scale (studs) instead of Offset (pixels) to keep markers a set size in the world.
- Added a 2000 stud MaxDistance constraint to all BillboardGuis to hide them when too far.
- Added an IconFrame display state for waypoints over 500 studs away.
- Added a FullFrame display state for waypoints under 500 studs away (or when actively tracked).
- Modified `rebuildVisuals` to generate both FullFrame and IconFrame layouts with TextScaled properties to accommodate physical stud sizing.
- Modified `updateVisualState` to calculate camera distance, toggle the visual frames, and dynamically resize the BillboardGui.
- Modified `round` utility to support UDim inputs for fully circular UI corners.
- Added extensive concise logging for debugging purposes.
]]

local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Player = Players.LocalPlayer
local PlayerGui = Player:WaitForChild("PlayerGui")
local MainHUD = PlayerGui:WaitForChild("MainHUD", 15)
if not MainHUD then

	return
end

local Top = MainHUD:WaitForChild("Top", 15)
local TopBar = Top and Top:WaitForChild("TopBar", 15)
if not TopBar then

	return
end

local Events = ReplicatedStorage:WaitForChild("Events")
local PreferenceSync = Events:WaitForChild("PlayerPreferenceSync", 10)
local ClosePanels = Events:FindFirstChild("ClosePanels")
if not ClosePanels then
	ClosePanels = Instance.new("BindableEvent")
	ClosePanels.Name = "ClosePanels"
	ClosePanels.Parent = Events
end
local Camera = Workspace.CurrentCamera
local function getCamera()
	Camera = Workspace.CurrentCamera or Camera
	return Camera
end
local WAYPOINT_GUI_NAME = "WaypointUI"
local WAYPOINT_BUTTON_NAME = "WaypointTopButton"
local WAYPOINT_PANEL_NAME = "WaypointPanel"
local WAYPOINT_ANCHOR_FOLDER = "LocalWaypointAnchors"
local PANEL_WIDTH = 420
local PANEL_HEIGHT = 430
local ROW_HEIGHT = 48
local MAX_ROWS = 48
local HOTKEY_PANEL = Enum.KeyCode.J
local HOTKEY_MARKERS = Enum.KeyCode.K
local PANEL_OPEN_POS = UDim2.new(0.5, 0, 0.5, 0)

local function isPlacementModeActive()
	local modeState = PlayerGui:FindFirstChild("ModeState") or ReplicatedStorage:FindFirstChild("ModeState")
	return modeState ~= nil and modeState.Value == "Placing"
end
local PANEL_CLOSED_POS = UDim2.new(0.5, 0, 1.55, 0)
local PANEL_TWEEN = TweenInfo.new(0.24, Enum.EasingStyle.Quart, Enum.EasingDirection.Out)

local COLORS = {
	Panel = Color3.fromRGB(16, 18, 22),
	Card = Color3.fromRGB(20, 23, 29),
	CardActive = Color3.fromRGB(24, 56, 98),
	Stroke = Color3.fromRGB(28, 32, 39),
	Text = Color3.fromRGB(240, 244, 255),
	Subtle = Color3.fromRGB(171, 181, 207),
	Off = Color3.fromRGB(17, 19, 24),
	On = Color3.fromRGB(34, 197, 94),
	Close = Color3.fromRGB(255, 61, 87),
}

local CATEGORY_ORDER = { "Spawn", "Lifts", "Services", "Spills", "Vehicles", "Runs" }
local CATEGORY_INFO = {
	Spawn = { label = "SPAWN", color = Color3.fromRGB(235, 239, 255), default = true },
	Lifts = { label = "LIFTS", color = Color3.fromRGB(255, 172, 65), default = true },
	Services = { label = "SERVICE", color = Color3.fromRGB(82, 173, 255), default = true },
	Spills = { label = "SPILLS", color = Color3.fromRGB(100, 219, 190), default = true },
	Vehicles = { label = "VEHICLE", color = Color3.fromRGB(255, 222, 92), default = true },
	Runs = { label = "RUN", color = Color3.fromRGB(84, 214, 103), default = false },
}

local RUN_DIFFICULTY_STYLE = {
	Green = { color = Color3.fromRGB(76, 209, 55), label = "GREEN", icon = "●", fill = Color3.fromRGB(28, 60, 34) },
	Blue = { color = Color3.fromRGB(52, 152, 219), label = "BLUE", icon = "■", fill = Color3.fromRGB(24, 44, 72) },
	Black = { color = Color3.fromRGB(240, 244, 255), label = "BLACK", icon = "◆", fill = Color3.fromRGB(18, 20, 24) },
	["Double Black"] = { color = Color3.fromRGB(255, 215, 0), label = "DOUBLE BLACK", icon = "◆◆", fill = Color3.fromRGB(25, 22, 12) },
	["Triple Black"] = { color = Color3.fromRGB(229, 57, 53), label = "TRIPLE BLACK", icon = "◆◆◆", fill = Color3.fromRGB(45, 14, 14) },
	Glade = { color = Color3.fromRGB(90, 170, 74), label = "GLADE", icon = "✦", fill = Color3.fromRGB(22, 52, 28) },
}

local state = {
	panelOpen = false,
	masterMarkers = true,
	categoryEnabled = {},
	button = nil,
	panel = nil,
	tracker = nil,
	waypoints = {},
	rows = {},
	anchors = {},
	billboards = {},
	beams = {},
	activeWaypointId = nil,
	lastRefresh = 0,
	ui = {},
	panelTween = nil,
	backdropTween = nil,
	connections = {},
	placedConnections = {},
	lastTeleportAt = 0,
}

for _, category in ipairs(CATEGORY_ORDER) do
	state.categoryEnabled[category] = CATEGORY_INFO[category].default
end

local waypointSaveQueued = false

local function isPlacedObjectRootModel(model, placed)
	if not (model and model:IsA("Model") and placed) then
		return false
	end
	local parent = model.Parent
	while parent and parent ~= placed do
		if parent:IsA("Model") and (
			parent:GetAttribute("UUID") ~= nil
			or parent:GetAttribute("Type") ~= nil
			or parent:GetAttribute("Category") ~= nil
		) then
			return false
		end
		parent = parent.Parent
	end
	return parent == placed
end

local function buildWaypointPreferencePayload()
	local categories = {}
	for _, category in ipairs(CATEGORY_ORDER) do
		categories[category] = state.categoryEnabled[category] == true
	end
	return {
		MasterMarkers = state.masterMarkers == true,
		ActiveWaypointId = state.activeWaypointId,
		CategoryEnabled = categories,
	}
end

local function flushWaypointPreferenceSave()
	if not (PreferenceSync and PreferenceSync:IsA("RemoteFunction")) then
		return
	end
	local payload = buildWaypointPreferencePayload()
	task.spawn(function()
		local ok, err = pcall(function()
			PreferenceSync:InvokeServer("SetWaypoints", payload)
		end)
		if ok then
			
		else
			
		end
	end)
end

local function scheduleWaypointPreferenceSave()
	if waypointSaveQueued then
		return
	end
	waypointSaveQueued = true
	task.delay(0.6, function()
		waypointSaveQueued = false
		flushWaypointPreferenceSave()
	end)
end

local function applySavedWaypointPreferences(payload)
	if type(payload) ~= "table" then
		return
	end
	if type(payload.MasterMarkers) == "boolean" then
		state.masterMarkers = payload.MasterMarkers
	end
	if type(payload.ActiveWaypointId) == "string" and payload.ActiveWaypointId ~= "" then
		state.activeWaypointId = payload.ActiveWaypointId
	else
		state.activeWaypointId = nil
	end
	if type(payload.CategoryEnabled) == "table" then
		for _, category in ipairs(CATEGORY_ORDER) do
			local enabled = payload.CategoryEnabled[category]
			if type(enabled) == "boolean" then
				state.categoryEnabled[category] = enabled
			end
		end
	end

end

do
	if PreferenceSync and PreferenceSync:IsA("RemoteFunction") then
		local ok, result = pcall(function()
			return PreferenceSync:InvokeServer("Get")
		end)
		if ok and type(result) == "table" and type(result.Waypoints) == "table" then
			applySavedWaypointPreferences(result.Waypoints)
		end
	end
end

local function round(inst, radius)
	local corner = inst:FindFirstChildOfClass("UICorner") or Instance.new("UICorner")
	if typeof(radius) == "UDim" then
		corner.CornerRadius = radius
	else
		corner.CornerRadius = UDim.new(0, radius or 8)
	end
	corner.Parent = inst
	return corner
end

local function stroke(inst, color, thickness)
	local outline = inst:FindFirstChildOfClass("UIStroke") or Instance.new("UIStroke")
	outline.Color = color or COLORS.Stroke
	outline.Thickness = thickness or 1
	outline.Parent = inst
	return outline
end

local function bindGuiButton(button, callback)
	if not (button and callback) then return end
	local firedAt = 0
	local function fire()
		local now = os.clock()
		if now - firedAt < 0.2 then return end
		firedAt = now
		callback()
	end
	if button:IsA("GuiButton") then
		button.Activated:Connect(fire)
	else
		button.InputBegan:Connect(function(input)
			local inputType = input.UserInputType
			if inputType == Enum.UserInputType.Touch or inputType == Enum.UserInputType.MouseButton1 then
				fire()
			end
		end)
	end
end

local function getRoot()
	local character = Player.Character
	if not character then return nil end
	return character:FindFirstChild("HumanoidRootPart")
end

local function formatDistance(studs)
	local value = math.max(0, tonumber(studs) or 0)
	if value >= 5280 then
		return string.format("%.1f mi", value / 5280)
	elseif value >= 1000 then
		return string.format("%.1fk", value / 1000)
	end
	return string.format("%d st", math.floor(value + 0.5))
end

local function tidyName(text)
	text = tostring(text or "")
	text = text:gsub("_", " ")
	text = text:gsub("%s+", " ")
	return text
end

local function getCustomDisplayName(model)
	if not model then
		return ""
	end
	local customName = tidyName(model:GetAttribute("CustomName") or "")
	customName = customName:gsub("^%s+", "")
	customName = customName:gsub("%s+$", "")
	if #customName > 48 then
		customName = string.sub(customName, 1, 48)
	end
	return customName
end

local function getPlacedDisplayName(model, fallbackName)
	local customName = getCustomDisplayName(model)
	if customName ~= "" then
		return customName
	end
	local baseName = tidyName(model and model.Name or "")
	baseName = baseName:gsub("^Slope ", "")
	baseName = baseName:gsub("^%s+", "")
	baseName = baseName:gsub("%s+$", "")
	if baseName ~= "" then
		return baseName
	end
	return fallbackName or ""
end

local function normalizeDifficulty(raw)
	local value = tidyName(raw)
	value = value:gsub("^%l", string.upper)
	if value == "Doubleblack" then return "Double Black" end
	if value == "Tripleblack" then return "Triple Black" end
	if value == "Glades" then return "Glade" end
	return value == "" and "Green" or value
end

local function getWaypointVisualStyle(waypoint)
	local categoryInfo = CATEGORY_INFO[waypoint.Category]
	local style = {
		color = categoryInfo.color,
		label = categoryInfo.label,
		icon = string.sub(categoryInfo.label, 1, 1),
		fill = Color3.fromRGB(14, 16, 20),
	}
	if waypoint.Category == "Runs" and waypoint.Instance then
		local difficulty = normalizeDifficulty(waypoint.Instance:GetAttribute("Difficulty"))
		local runStyle = RUN_DIFFICULTY_STYLE[difficulty]
		if runStyle then
			style.color = runStyle.color
			style.label = runStyle.label
			style.icon = runStyle.icon
			style.fill = runStyle.fill
		end
	end
	return style
end

local function decodePoints(raw)
	if type(raw) ~= "string" or raw == "" then return nil end
	local ok, decoded = pcall(function()
		return HttpService:JSONDecode(raw)
	end)
	if not ok or type(decoded) ~= "table" or #decoded < 2 then return nil end
	local points = {}
	for _, entry in ipairs(decoded) do
		local x = tonumber(entry[1] or entry.x)
		local y = tonumber(entry[2] or entry.y)
		local z = tonumber(entry[3] or entry.z)
		if x and y and z then
			table.insert(points, Vector3.new(x, y, z))
		end
	end
	return #points >= 2 and points or nil
end

local function ensureGui()
	local gui = PlayerGui:FindFirstChild(WAYPOINT_GUI_NAME)
	if gui then return gui end

	gui = Instance.new("ScreenGui")
	gui.Name = WAYPOINT_GUI_NAME
	gui.ResetOnSpawn = false
	gui.DisplayOrder = 8
	gui.Parent = PlayerGui
	return gui
end

local function ensureAnchorFolder()
	local folder = Workspace:FindFirstChild(WAYPOINT_ANCHOR_FOLDER)
	if folder then return folder end

	folder = Instance.new("Folder")
	folder.Name = WAYPOINT_ANCHOR_FOLDER
	folder.Parent = Workspace
	return folder
end

local function clearRows()
	for _, row in ipairs(state.rows) do
		row:Destroy()
	end
	table.clear(state.rows)
end

local function clearVisuals()
	for _, inst in pairs(state.billboards) do
		inst:Destroy()
	end
	for _, inst in pairs(state.beams) do
		inst:Destroy()
	end
	for _, inst in pairs(state.anchors) do
		inst:Destroy()
	end
	table.clear(state.billboards)
	table.clear(state.beams)
	table.clear(state.anchors)
end

local function getModelBasePart(model)
	if not (model and model:IsA("Model")) then return nil end
	if model.PrimaryPart then return model.PrimaryPart end
	return model:FindFirstChildWhichIsA("BasePart", true)
end

local function classifyPlacedModel(model)
	local itemType = tostring(model:GetAttribute("Type") or "")
	local difficulty = model:GetAttribute("Difficulty")
	local nameLower = string.lower(model.Name)
	if difficulty ~= nil or itemType == "Slope" or model:GetAttribute("RawPoints") ~= nil then
		local label = normalizeDifficulty(difficulty or "Green")
		return "Runs", getPlacedDisplayName(model, string.format("%s Run", label)), "Slope"
	end
	if itemType == "TwoPoint" or nameLower:find("lift", 1, true) or nameLower:find("chair", 1, true) or nameLower:find("gondola", 1, true) or nameLower:find("carpet", 1, true) then
		return "Lifts", getPlacedDisplayName(model, tidyName(model.Name)), "Model"
	end
	if itemType == "Rental" or itemType == "Shop" or itemType == "Food" or nameLower:find("rental", 1, true) or nameLower:find("shop", 1, true) or nameLower:find("lodge", 1, true) or nameLower:find("cafe", 1, true) then
		return "Services", getPlacedDisplayName(model, tidyName(model.Name)), "Model"
	end
	if nameLower:find("bison", 1, true) or nameLower:find("snowcat", 1, true) then
		return "Vehicles", getPlacedDisplayName(model, tidyName(model.Name)), "Model"
	end
	return nil, nil, nil
end

local function getWaypointPosition(waypoint)
	if waypoint.Kind == "Slope" and waypoint.Instance then
		local points = decodePoints(waypoint.Instance:GetAttribute("RawPoints"))
		if points then
			local index = math.max(1, math.floor(#points * 0.5))
			return points[index] + Vector3.new(0, 8, 0)
		end
	end
	local instance = waypoint.Instance
	if instance and instance.Parent then
		if instance:IsA("SpawnLocation") or instance:IsA("BasePart") then
			return instance.Position + Vector3.new(0, 8, 0)
		elseif instance:IsA("Model") then
			local basePart = getModelBasePart(instance)
			if basePart then
				return basePart.Position + Vector3.new(0, math.max(8, basePart.Size.Y * 0.65), 0)
			end
			return instance:GetPivot().Position + Vector3.new(0, 8, 0)
		end
	end
	return waypoint.Position or Vector3.zero
end

local function discoverWaypoints()
	local waypoints = {}
	local order = 0

	local startSpawn = Workspace:FindFirstChild("StartSpawn")
	if startSpawn and startSpawn:IsA("SpawnLocation") then
		order += 1
		table.insert(waypoints, {
			Id = "spawn:start",
			Name = "Base Spawn",
			Category = "Spawn",
			Kind = "Spawn",
			Instance = startSpawn,
			Order = order,
		})
	end

	local bison = Workspace:FindFirstChild("Prinoth Bison")
	if bison and bison:IsA("Model") then
		order += 1
		table.insert(waypoints, {
			Id = "vehicle:prinoth_bison",
			Name = "Snowcat",
			Category = "Vehicles",
			Kind = "Model",
			Instance = bison,
			Order = order,
		})
	end

	local placed = Workspace:FindFirstChild("PlacedObjects")
	if placed then
		for _, child in ipairs(placed:GetDescendants()) do
			if child:IsA("Model") and isPlacedObjectRootModel(child, placed) then
				local category, displayName, kind = classifyPlacedModel(child)
				if category then
					order += 1
					table.insert(waypoints, {
						Id = tostring(child:GetAttribute("UUID") or (displayName .. ":" .. tostring(order))),
						Name = displayName,
						Category = category,
						Kind = kind,
						Instance = child,
						Order = order,
					})
				end
			end
		end
	end

	local spillsFolder = Workspace:FindFirstChild("Spills")
	if spillsFolder then
		for _, spill in ipairs(spillsFolder:GetChildren()) do
			if spill:IsA("Model") then
				order += 1
				local spillId = tostring(spill:GetAttribute("SpillId") or spill:GetAttribute("BuildingUUID") or spill.Name or ("spill:" .. tostring(order)))
				table.insert(waypoints, {
					Id = "spill:" .. spillId,
					Name = "Spill",
					Category = "Spills",
					Kind = "Model",
					Instance = spill,
					Order = order,
				})
			end
		end
	end

	table.sort(waypoints, function(a, b)
		if a.Category ~= b.Category then
			local ia = table.find(CATEGORY_ORDER, a.Category) or 999
			local ib = table.find(CATEGORY_ORDER, b.Category) or 999
			if ia ~= ib then return ia < ib end
		end
		return (a.Order or 999) < (b.Order or 999)
	end)

	state.waypoints = waypoints

	if state.activeWaypointId then
		local found = false
		for _, waypoint in ipairs(waypoints) do
			if waypoint.Id == state.activeWaypointId then
				found = true
				break
			end
		end
		if not found then
			state.activeWaypointId = nil
			scheduleWaypointPreferenceSave()
		end
	end
end

local function getActiveWaypoint()
	for _, waypoint in ipairs(state.waypoints) do
		if waypoint.Id == state.activeWaypointId then
			return waypoint
		end
	end
	return nil
end

local function categoryVisible(category, waypointId)
	if waypointId and waypointId == state.activeWaypointId then
		return true
	end
	return state.masterMarkers and state.categoryEnabled[category] ~= false
end

local function applyToggleVisual(button, enabled, accent)
	button.BackgroundColor3 = enabled and accent or COLORS.Off
	button.TextColor3 = enabled and Color3.fromRGB(16, 18, 22) or COLORS.Text
	local outline = button:FindFirstChildOfClass("UIStroke")
	if outline then
		outline.Color = enabled and accent or COLORS.Stroke
	end
end

local refreshRows

local function updateTracker()
	if not state.tracker then return end
	local active = getActiveWaypoint()
	local root = getRoot()
	if not active or not root then
		state.tracker.Visible = false
		return
	end
	local position = getWaypointPosition(active)
	state.tracker.Visible = true
	state.ui.trackerAccent.BackgroundColor3 = CATEGORY_INFO[active.Category].color
	state.ui.trackerTitle.Text = active.Name
	state.ui.trackerMeta.Text = string.format("%s  •  %s", CATEGORY_INFO[active.Category].label, formatDistance((position - root.Position).Magnitude))
	if state.ui.trackerTeleport then
		state.ui.trackerTeleport.BackgroundColor3 = CATEGORY_INFO[active.Category].color
		state.ui.trackerTeleport.TextColor3 = Color3.fromRGB(16, 18, 22)
	end
end

local function teleportToWaypoint(waypoint)
	local character = Player.Character
	local root = getRoot()
	if not (waypoint and character and root) then return end
	local now = os.clock()
	if now - state.lastTeleportAt < 0.35 then return end
	state.lastTeleportAt = now

	local targetPosition = getWaypointPosition(waypoint)
	local targetCFrame = CFrame.new(targetPosition)
	local instance = waypoint.Instance
	if instance and instance.Parent then
		if instance:IsA("SpawnLocation") or instance:IsA("BasePart") then
			targetPosition = instance.Position + Vector3.new(0, math.max(6, instance.Size.Y * 0.6 + 3), 0)
			targetCFrame = CFrame.new(targetPosition)
		elseif instance:IsA("Model") then
			local basePart = getModelBasePart(instance)
			if basePart then
				local bbCF, bbSize = instance:GetBoundingBox()
				local look = Vector3.new(basePart.CFrame.LookVector.X, 0, basePart.CFrame.LookVector.Z)
				if look.Magnitude <= 0.01 and root then
					look = Vector3.new(root.Position.X - bbCF.Position.X, 0, root.Position.Z - bbCF.Position.Z)
				end
				if look.Magnitude <= 0.01 then
					look = Vector3.new(0, 0, -1)
				end
				look = look.Unit
				local horizontalOffset = math.max(8, math.max(bbSize.X, bbSize.Z) * 0.6)
				local verticalOffset = math.max(8, bbSize.Y * 0.55 + 3)
				targetPosition = bbCF.Position + (look * horizontalOffset) + Vector3.new(0, verticalOffset, 0)
				targetCFrame = CFrame.lookAt(targetPosition, targetPosition + look)
			end
		end
	end

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid.Sit = false
		humanoid:ChangeState(Enum.HumanoidStateType.GettingUp)
	end
	root.AssemblyLinearVelocity = Vector3.zero
	root.AssemblyAngularVelocity = Vector3.zero
	character:PivotTo(targetCFrame)
	state.activeWaypointId = waypoint.Id
	scheduleWaypointPreferenceSave()
	refreshRows()
	updateTracker()
end

function refreshRows()
	if not state.ui.list then return end
	clearRows()
	local root = getRoot()
	local visibleCount = 0
	for _, waypoint in ipairs(state.waypoints) do
		if categoryVisible(waypoint.Category, waypoint.Id) then
			visibleCount += 1
			if visibleCount > MAX_ROWS then break end
			local row = Instance.new("TextButton")
			row.Name = "WaypointRow"
			row.BackgroundColor3 = waypoint.Id == state.activeWaypointId and COLORS.CardActive or COLORS.Card
			row.BorderSizePixel = 0
			row.AutoButtonColor = true
			row.Text = ""
			row.Size = UDim2.new(1, 0, 0, ROW_HEIGHT)
			row.Position = UDim2.new(0, 0, 0, (visibleCount - 1) * (ROW_HEIGHT + 6))
			row.ZIndex = 11
			row.Parent = state.ui.list
			round(row, 8)
			stroke(row, waypoint.Id == state.activeWaypointId and CATEGORY_INFO[waypoint.Category].color or COLORS.Stroke, 1)

			local accent = Instance.new("Frame")
			accent.BackgroundColor3 = CATEGORY_INFO[waypoint.Category].color
			accent.BorderSizePixel = 0
			accent.Size = UDim2.new(0, 6, 1, 0)
			accent.ZIndex = 12
			accent.Parent = row
			round(accent, 8)

			local title = Instance.new("TextLabel")
			title.BackgroundTransparency = 1
			title.Position = UDim2.fromOffset(14, 5)
			title.Size = UDim2.new(1, -132, 0, 16)
			title.Font = Enum.Font.GothamBold
			title.TextSize = 13
			title.TextColor3 = COLORS.Text
			title.TextXAlignment = Enum.TextXAlignment.Left
			title.Text = waypoint.Name
			title.ZIndex = 12
			title.Parent = row

			local meta = Instance.new("TextLabel")
			meta.BackgroundTransparency = 1
			meta.Position = UDim2.fromOffset(14, 22)
			meta.Size = UDim2.new(1, -132, 0, 13)
			meta.Font = Enum.Font.Gotham
			meta.TextSize = 11
			meta.TextColor3 = COLORS.Subtle
			meta.TextXAlignment = Enum.TextXAlignment.Left
			meta.Text = string.format("%s  •  %s", CATEGORY_INFO[waypoint.Category].label, root and formatDistance((getWaypointPosition(waypoint) - root.Position).Magnitude) or "--")
			meta.ZIndex = 12
			meta.Parent = row

			local teleport = Instance.new("TextButton")
			teleport.BackgroundColor3 = CATEGORY_INFO[waypoint.Category].color
			teleport.BorderSizePixel = 0
			teleport.AnchorPoint = Vector2.new(1, 0.5)
			teleport.Position = UDim2.new(1, -66, 0.5, 0)
			teleport.Size = UDim2.fromOffset(52, 26)
			teleport.Text = "TP"
			teleport.TextColor3 = Color3.fromRGB(16, 18, 22)
			teleport.Font = Enum.Font.GothamBold
			teleport.TextSize = 11
			teleport.ZIndex = 12
			teleport.Parent = row
			round(teleport, 7)
			stroke(teleport, CATEGORY_INFO[waypoint.Category].color, 1)

			local track = Instance.new("TextButton")
			track.BackgroundColor3 = waypoint.Id == state.activeWaypointId and CATEGORY_INFO[waypoint.Category].color or COLORS.Off
			track.BorderSizePixel = 0
			track.AnchorPoint = Vector2.new(1, 0.5)
			track.Position = UDim2.new(1, -8, 0.5, 0)
			track.Size = UDim2.fromOffset(52, 26)
			track.Text = waypoint.Id == state.activeWaypointId and "ON" or "TRACK"
			track.TextColor3 = waypoint.Id == state.activeWaypointId and Color3.fromRGB(16, 18, 22) or COLORS.Text
			track.Font = Enum.Font.GothamBold
			track.TextSize = 10
			track.ZIndex = 12
			track.Parent = row
			round(track, 7)
			stroke(track, waypoint.Id == state.activeWaypointId and CATEGORY_INFO[waypoint.Category].color or COLORS.Stroke, 1)

			local function toggleTrack()
				if state.activeWaypointId == waypoint.Id then
					state.activeWaypointId = nil
				else
					state.activeWaypointId = waypoint.Id
				end
				scheduleWaypointPreferenceSave()
				refreshRows()
				updateTracker()
			end
			bindGuiButton(row, toggleTrack)
			bindGuiButton(track, toggleTrack)
			bindGuiButton(teleport, function()
				teleportToWaypoint(waypoint)
			end)
			table.insert(state.rows, row)
		end
	end
	if visibleCount == 0 then
		local empty = Instance.new("TextLabel")
		empty.BackgroundTransparency = 1
		empty.Position = UDim2.fromOffset(4, 18)
		empty.Size = UDim2.new(1, -8, 0, 36)
		empty.Font = Enum.Font.Gotham
		empty.TextSize = 13
		empty.TextWrapped = true
		empty.TextColor3 = COLORS.Subtle
		empty.Text = "No visible waypoints. Enable a category or turn markers back on."
		empty.ZIndex = 11
		empty.Parent = state.ui.list
		table.insert(state.rows, empty)
	end
	state.ui.list.CanvasSize = UDim2.fromOffset(0, math.max(0, visibleCount * (ROW_HEIGHT + 6) + 8))
end

local function rebuildVisuals()
	clearVisuals()
	local gui = ensureGui()
	local folder = ensureAnchorFolder()

	for _, waypoint in ipairs(state.waypoints) do
		local position = getWaypointPosition(waypoint)
		local visualStyle = getWaypointVisualStyle(waypoint)

		local anchor = Instance.new("Part")
		anchor.Name = "WaypointAnchor_" .. waypoint.Id
		anchor.Anchored = true
		anchor.CanCollide = false
		anchor.CanTouch = false
		anchor.CanQuery = false
		anchor.Transparency = 1
		anchor.Size = Vector3.new(0.5, 0.5, 0.5)
		anchor.Position = position
		anchor.Parent = folder
		state.anchors[waypoint.Id] = anchor

		local billboard = Instance.new("BillboardGui")
		billboard.Name = "Billboard_" .. waypoint.Id
		billboard.Adornee = anchor
		billboard.AlwaysOnTop = true
		billboard.LightInfluence = 0
		billboard.MaxDistance = 2000
		billboard.Parent = gui
		state.billboards[waypoint.Id] = billboard

		local fullFrame = Instance.new("Frame")
		fullFrame.Name = "FullFrame"
		fullFrame.BackgroundColor3 = visualStyle.fill
		fullFrame.BorderSizePixel = 0
		fullFrame.Size = UDim2.fromScale(1, 1)
		fullFrame.Visible = false
		fullFrame.Parent = billboard
		round(fullFrame, 10)
		stroke(fullFrame, visualStyle.color, 1)

		local title = Instance.new("TextLabel")
		title.Name = "Title"
		title.BackgroundTransparency = 1
		title.Position = UDim2.fromScale(0.05, 0.1)
		title.Size = UDim2.fromScale(0.9, 0.45)
		title.Font = Enum.Font.GothamBold
		title.TextScaled = true
		title.TextColor3 = COLORS.Text
		title.TextXAlignment = Enum.TextXAlignment.Left
		title.Text = waypoint.Name
		title.Parent = fullFrame

		local meta = Instance.new("TextLabel")
		meta.Name = "Meta"
		meta.BackgroundTransparency = 1
		meta.Position = UDim2.fromScale(0.05, 0.55)
		meta.Size = UDim2.fromScale(0.9, 0.35)
		meta.Font = Enum.Font.Gotham
		meta.TextScaled = true
		meta.TextColor3 = COLORS.Subtle
		meta.TextXAlignment = Enum.TextXAlignment.Left
		meta.Text = visualStyle.label
		meta.Parent = fullFrame

		local iconFrame = Instance.new("Frame")
		iconFrame.Name = "IconFrame"
		iconFrame.BackgroundColor3 = visualStyle.fill
		iconFrame.BorderSizePixel = 0
		iconFrame.Size = UDim2.fromScale(1, 1)
		iconFrame.Visible = false
		iconFrame.Parent = billboard
		round(iconFrame, UDim.new(1, 0))
		stroke(iconFrame, visualStyle.color, 1.5)

		local iconText = Instance.new("TextLabel")
		iconText.Name = "IconText"
		iconText.BackgroundTransparency = 1
		iconText.Position = UDim2.fromScale(0.2, 0.2)
		iconText.Size = UDim2.fromScale(0.6, 0.6)
		iconText.Font = Enum.Font.GothamBold
		iconText.TextScaled = true
		iconText.TextColor3 = visualStyle.color
		iconText.Text = visualStyle.icon
		iconText.Parent = iconFrame

		local beam = Instance.new("Part")
		beam.Name = "Beam_" .. waypoint.Id
		beam.Anchored = true
		beam.CanCollide = false
		beam.CanTouch = false
		beam.CanQuery = false
		beam.CastShadow = false
		beam.Material = Enum.Material.Neon
		beam.Color = visualStyle.color
		beam.Transparency = 1
		beam.Size = Vector3.new(0.9, 18, 0.9)
		beam.Position = position - Vector3.new(0, 1, 0)
		beam.Parent = folder
		state.beams[waypoint.Id] = beam
	end
end

local function updateVisualState()
	local root = getRoot()
	local camera = getCamera()
	if not camera then
		return
	end
	local camPos = camera.CFrame.Position

	for _, waypoint in ipairs(state.waypoints) do
		local anchor = state.anchors[waypoint.Id]
		local billboard = state.billboards[waypoint.Id]
		local beam = state.beams[waypoint.Id]
		local position = getWaypointPosition(waypoint)

		if anchor then
			anchor.Position = position
		end

		if billboard then
			local dist = (position - camPos).Magnitude
			local isTracked = (waypoint.Id == state.activeWaypointId)
			local categoryEnabled = categoryVisible(waypoint.Category, waypoint.Id)
			local shouldShow = (dist <= 2000) and (categoryEnabled or isTracked)

			billboard.Enabled = shouldShow

			if shouldShow then
				local fullFrame = billboard:FindFirstChild("FullFrame")
				local iconFrame = billboard:FindFirstChild("IconFrame")

				local useFullFrame = isTracked or (dist > 180 and dist <= 1100)
				if useFullFrame then
					billboard.Size = UDim2.new(16, 0, 5, 0)
					if fullFrame then
						fullFrame.Visible = true
						fullFrame.BackgroundColor3 = isTracked and COLORS.CardActive or Color3.fromRGB(14, 16, 20)
						local outline = fullFrame:FindFirstChildOfClass("UIStroke")
						if outline then
							outline.Color = isTracked and COLORS.Text or getWaypointVisualStyle(waypoint).color
						end

						local meta = fullFrame:FindFirstChild("Meta")
						if meta then
							meta.Text = string.format("%s  •  %s", getWaypointVisualStyle(waypoint).label, root and formatDistance((position - root.Position).Magnitude) or "--")
						end
					end
					if iconFrame then iconFrame.Visible = false end
				else
					local iconStuds = dist <= 180 and 2.8 or 3.5
					billboard.Size = UDim2.new(iconStuds, 0, iconStuds, 0)
					if fullFrame then fullFrame.Visible = false end
					if iconFrame then
						iconFrame.Visible = true
						iconFrame.BackgroundColor3 = getWaypointVisualStyle(waypoint).fill
						local outline = iconFrame:FindFirstChildOfClass("UIStroke")
						if outline then
							outline.Color = getWaypointVisualStyle(waypoint).color
						end
					end
				end
			end
		end

		if beam then
			beam.Color = CATEGORY_INFO[waypoint.Category].color
			beam.Position = position - Vector3.new(0, 1, 0)
			beam.Transparency = waypoint.Id == state.activeWaypointId and (0.16 + (math.sin(os.clock() * 4) * 0.05)) or 1
		end
	end
end

local function refreshAll()
	discoverWaypoints()
	rebuildVisuals()
	refreshRows()
	updateTracker()
	updateVisualState()
	state.lastRefresh = os.clock()
end

local function setPanelVisible(visible)
	state.panelOpen = visible == true
	if not state.panel then
		return
	end

	if state.panelTween then
		state.panelTween:Cancel()
		state.panelTween = nil
	end
	if state.backdropTween then
		state.backdropTween:Cancel()
		state.backdropTween = nil
	end

	local backdrop = state.ui.backdrop
	if backdrop then
		backdrop.Visible = false
		backdrop.BackgroundTransparency = 1
	end
	if state.panelOpen then
		state.panel.Visible = true
		state.panel.Position = PANEL_CLOSED_POS
		state.panelTween = TweenService:Create(state.panel, PANEL_TWEEN, { Position = PANEL_OPEN_POS, BackgroundTransparency = 0.04 })
		state.panelTween:Play()
	else
		state.panelTween = TweenService:Create(state.panel, PANEL_TWEEN, { Position = PANEL_CLOSED_POS, BackgroundTransparency = 0.12 })
		state.panelTween:Play()
		task.delay(PANEL_TWEEN.Time + 0.02, function()
			if not state.panelOpen and state.panel then
				state.panel.Visible = false
			end
		end)
	end
end

local function updateButtonLayout()
	if not state.button then return end
	state.button.Visible = true
	local rightMargin = UserInputService.TouchEnabled and 18 or 22
	local topMargin = UserInputService.TouchEnabled and 122 or 92
	state.button.Position = UDim2.new(
		1,
		-math.floor(rightMargin),
		0,
		math.floor(topMargin)
	)
	if state.panel and state.panelOpen then
		state.panel.Visible = true
		state.panel.Position = PANEL_OPEN_POS
	end
	if state.ui.backdrop then
		state.ui.backdrop.Visible = false
	end
	if state.ui.buttonFallback then
		state.ui.buttonFallback.Visible = false
		state.ui.buttonFallback.TextColor3 = COLORS.Text
		state.ui.buttonFallback.TextSize = 10
		state.ui.buttonFallback.Font = Enum.Font.GothamBlack
		state.ui.buttonFallback.Text = "WP"
		state.ui.buttonFallback.TextStrokeTransparency = 0.75
		state.ui.buttonFallback.TextStrokeColor3 = Color3.fromRGB(5, 9, 18)
		state.ui.buttonFallback.TextTransparency = 0
	end
	if state.ui.buttonKey then
		state.ui.buttonKey.Visible = not UserInputService.TouchEnabled
		state.ui.buttonKey.TextColor3 = COLORS.Subtle
		state.ui.buttonKey.Text = "J"
		state.ui.buttonKey.TextSize = 8
	end
end

local function ensureUi()
	if state.button and state.panel and state.tracker then return end
	local gui = ensureGui()

	local button = Instance.new("ImageButton")
	button.Name = WAYPOINT_BUTTON_NAME
	button.BackgroundColor3 = Color3.fromRGB(20, 24, 33)
	button.BackgroundTransparency = 0.02
	button.BorderSizePixel = 0
	button.AutoButtonColor = true
	button.Size = UDim2.fromOffset(42, 42)
	button.AnchorPoint = Vector2.new(1, 0)
	button.Position = UDim2.new(1, -22, 0, 92)
	button.Image = "rbxthumb://type=Asset&id=10516012789&w=150&h=150"
	button.ScaleType = Enum.ScaleType.Fit
	button.ImageColor3 = Color3.fromRGB(235, 242, 255)
	button.ZIndex = 10
	button.Parent = gui
	round(button, 12)
	stroke(button, Color3.fromRGB(66, 78, 98), 1)
	local buttonGradient = Instance.new("UIGradient")
	buttonGradient.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(34, 40, 56)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(13, 17, 24))
	})
	buttonGradient.Rotation = 90
	buttonGradient.Parent = button
	state.button = button

	local backdrop = Instance.new("TextButton")
	backdrop.Name = "WaypointBackdrop"
	backdrop.BackgroundColor3 = Color3.fromRGB(5, 8, 14)
	backdrop.BackgroundTransparency = 1
	backdrop.BorderSizePixel = 0
	backdrop.Size = UDim2.fromScale(1, 1)
	backdrop.Text = ""
	backdrop.Visible = false
	backdrop.Active = false
	backdrop.AutoButtonColor = false
	backdrop.ZIndex = 9
	backdrop.Parent = gui
	state.ui.backdrop = backdrop

	local fallback = Instance.new("TextLabel")
	fallback.Name = "FallbackLabel"
	fallback.BackgroundTransparency = 1
	fallback.Size = UDim2.fromScale(1, 1)
	fallback.Font = Enum.Font.GothamBlack
	fallback.TextSize = 10
	fallback.Text = "WP"
	fallback.TextColor3 = COLORS.Text
	fallback.ZIndex = 11
	fallback.Parent = button
	state.ui.buttonFallback = fallback

	local keyHint = Instance.new("TextLabel")
	keyHint.Name = "KeyHint"
	keyHint.BackgroundTransparency = 1
	keyHint.AnchorPoint = Vector2.new(1, 0)
	keyHint.Position = UDim2.new(1, -4, 0, 2)
	keyHint.Size = UDim2.fromOffset(16, 10)
	keyHint.Font = Enum.Font.GothamBlack
	keyHint.TextSize = 8
	keyHint.TextXAlignment = Enum.TextXAlignment.Right
	keyHint.Text = "J"
	keyHint.ZIndex = 11
	keyHint.Parent = button
	state.ui.buttonKey = keyHint

	local panel = Instance.new("Frame")
	panel.Name = WAYPOINT_PANEL_NAME
	panel.BackgroundColor3 = COLORS.Panel
	panel.BackgroundTransparency = 0.04
	panel.BorderSizePixel = 0
	panel.Visible = false
	panel.AnchorPoint = Vector2.new(0.5, 0.5)
	panel.Position = PANEL_CLOSED_POS
	panel.Size = UDim2.fromOffset(PANEL_WIDTH, PANEL_HEIGHT)
	panel.ZIndex = 10
	panel.Parent = gui
	round(panel, 16)
	stroke(panel, COLORS.Stroke, 1)
	state.panel = panel

	local title = Instance.new("TextLabel")
	title.BackgroundTransparency = 1
	title.Position = UDim2.fromOffset(18, 14)
	title.Size = UDim2.new(1, -96, 0, 24)
	title.Font = Enum.Font.GothamBlack
	title.Text = "WAYPOINTS"
	title.TextColor3 = COLORS.Text
	title.TextSize = 24
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.ZIndex = 11
	title.Parent = panel

	local subtitle = Instance.new("TextLabel")
	subtitle.BackgroundTransparency = 1
	subtitle.Position = UDim2.fromOffset(18, 42)
	subtitle.Size = UDim2.new(1, -36, 0, 14)
	subtitle.Font = Enum.Font.Gotham
	subtitle.Text = "Track lifts, services, spills, snowcats, spawn, and runs"
	subtitle.TextColor3 = COLORS.Subtle
	subtitle.TextSize = 12
	subtitle.TextXAlignment = Enum.TextXAlignment.Left
	subtitle.ZIndex = 11
	subtitle.Parent = panel

	local close = Instance.new("TextButton")
	close.BackgroundColor3 = COLORS.Close
	close.BorderSizePixel = 0
	close.Size = UDim2.fromOffset(42, 34)
	close.AnchorPoint = Vector2.new(1, 0)
	close.Position = UDim2.new(1, -16, 0, 14)
	close.Text = "EXIT"
	close.TextColor3 = COLORS.Text
	close.Font = Enum.Font.GothamBlack
	close.TextSize = 12
	close.ZIndex = 11
	close.Parent = panel
	round(close, 10)
	stroke(close, Color3.fromRGB(120, 16, 30), 1)

	local allToggle = Instance.new("TextButton")
	allToggle.BackgroundColor3 = COLORS.On
	allToggle.BorderSizePixel = 0
	allToggle.Size = UDim2.fromOffset(92, 30)
	allToggle.Position = UDim2.fromOffset(18, 74)
	allToggle.Text = "MARKERS"
	allToggle.Font = Enum.Font.GothamBold
	allToggle.TextSize = 10
	allToggle.ZIndex = 11
	allToggle.Parent = panel
	round(allToggle, 8)
	stroke(allToggle, COLORS.On, 1)
	state.ui.allToggle = allToggle

	local clearTracked = Instance.new("TextButton")
	clearTracked.BackgroundColor3 = COLORS.Off
	clearTracked.BorderSizePixel = 0
	clearTracked.Size = UDim2.fromOffset(106, 30)
	clearTracked.AnchorPoint = Vector2.new(1, 0)
	clearTracked.Position = UDim2.new(1, -18, 0, 74)
	clearTracked.Text = "CLEAR TRACK"
	clearTracked.TextColor3 = COLORS.Text
	clearTracked.Font = Enum.Font.GothamBold
	clearTracked.TextSize = 10
	clearTracked.ZIndex = 11
	clearTracked.Parent = panel
	round(clearTracked, 8)
	stroke(clearTracked, COLORS.Stroke, 1)

	local toggleRow = Instance.new("Frame")
	toggleRow.BackgroundTransparency = 1
	toggleRow.Position = UDim2.fromOffset(18, 114)
	toggleRow.Size = UDim2.new(1, -36, 0, 34)
	toggleRow.ZIndex = 11
	toggleRow.Parent = panel
	state.ui.categoryToggles = {}
	local x = 0
	for _, category in ipairs(CATEGORY_ORDER) do
		local info = CATEGORY_INFO[category]
		local toggle = Instance.new("TextButton")
		toggle.BackgroundColor3 = info.default and info.color or COLORS.Off
		toggle.BorderSizePixel = 0
		toggle.Size = UDim2.fromOffset(60, 30)
		toggle.Position = UDim2.fromOffset(x, 0)
		toggle.Text = info.label
		toggle.TextSize = 9
		toggle.Font = Enum.Font.GothamBold
		toggle.ZIndex = 11
		toggle.Parent = toggleRow
		round(toggle, 8)
		stroke(toggle, info.color, 1)
		state.ui.categoryToggles[category] = toggle
		x += 64
	end

	local list = Instance.new("ScrollingFrame")
	list.Name = "List"
	list.BackgroundTransparency = 1
	list.BorderSizePixel = 0
	list.Position = UDim2.fromOffset(18, 156)
	list.Size = UDim2.new(1, -36, 1, -174)
	list.ScrollBarThickness = 6
	list.CanvasSize = UDim2.fromOffset(0, 0)
	list.ZIndex = 10
	list.Parent = panel
	state.ui.list = list

	local tracker = Instance.new("Frame")
	tracker.BackgroundColor3 = COLORS.Panel
	tracker.BorderSizePixel = 0
	tracker.Size = UDim2.fromOffset(308, 56)
	tracker.AnchorPoint = Vector2.new(1, 0)
	tracker.Position = UDim2.new(1, -18, 0, 86)
	tracker.Visible = false
	tracker.ZIndex = 10
	tracker.Parent = gui
	round(tracker, 10)
	stroke(tracker, COLORS.Stroke, 1)
	state.tracker = tracker

	local trackerAccent = Instance.new("Frame")
	trackerAccent.BackgroundColor3 = CATEGORY_INFO.Spawn.color
	trackerAccent.BorderSizePixel = 0
	trackerAccent.Size = UDim2.new(0, 6, 1, 0)
	trackerAccent.Parent = tracker
	round(trackerAccent, 10)
	state.ui.trackerAccent = trackerAccent

	local trackerTitle = Instance.new("TextLabel")
	trackerTitle.BackgroundTransparency = 1
	trackerTitle.Position = UDim2.fromOffset(16, 8)
	trackerTitle.Size = UDim2.new(1, -134, 0, 16)
	trackerTitle.Font = Enum.Font.GothamBold
	trackerTitle.Text = "Tracked waypoint"
	trackerTitle.TextColor3 = COLORS.Text
	trackerTitle.TextSize = 14
	trackerTitle.TextXAlignment = Enum.TextXAlignment.Left
	trackerTitle.ZIndex = 11
	trackerTitle.Parent = tracker
	state.ui.trackerTitle = trackerTitle

	local trackerMeta = Instance.new("TextLabel")
	trackerMeta.BackgroundTransparency = 1
	trackerMeta.Position = UDim2.fromOffset(16, 28)
	trackerMeta.Size = UDim2.new(1, -134, 0, 14)
	trackerMeta.Font = Enum.Font.Gotham
	trackerMeta.TextColor3 = COLORS.Subtle
	trackerMeta.TextSize = 11
	trackerMeta.TextXAlignment = Enum.TextXAlignment.Left
	trackerMeta.ZIndex = 11
	trackerMeta.Parent = tracker
	state.ui.trackerMeta = trackerMeta

	local trackerTeleport = Instance.new("TextButton")
	trackerTeleport.BackgroundColor3 = CATEGORY_INFO.Spawn.color
	trackerTeleport.BorderSizePixel = 0
	trackerTeleport.AnchorPoint = Vector2.new(1, 0.5)
	trackerTeleport.Position = UDim2.new(1, -38, 0.5, 0)
	trackerTeleport.Size = UDim2.fromOffset(84, 28)
	trackerTeleport.Text = "TELEPORT"
	trackerTeleport.TextColor3 = Color3.fromRGB(16, 18, 22)
	trackerTeleport.Font = Enum.Font.GothamBlack
	trackerTeleport.TextSize = 10
	trackerTeleport.ZIndex = 11
	trackerTeleport.Parent = tracker
	round(trackerTeleport, 8)
	stroke(trackerTeleport, CATEGORY_INFO.Spawn.color, 1)
	state.ui.trackerTeleport = trackerTeleport

	local trackerClear = Instance.new("TextButton")
	trackerClear.BackgroundColor3 = COLORS.Off
	trackerClear.BorderSizePixel = 0
	trackerClear.Size = UDim2.fromOffset(26, 26)
	trackerClear.AnchorPoint = Vector2.new(1, 0)
	trackerClear.Position = UDim2.new(1, -8, 0, 8)
	trackerClear.Text = "X"
	trackerClear.TextColor3 = COLORS.Text
	trackerClear.Font = Enum.Font.GothamBold
	trackerClear.TextSize = 10
	trackerClear.ZIndex = 11
	trackerClear.Parent = tracker
	round(trackerClear, 7)
	stroke(trackerClear, COLORS.Stroke, 1)

	bindGuiButton(button, function()
		local nextOpen = not state.panelOpen
		if nextOpen and ClosePanels then
			ClosePanels:Fire("Waypoints")
		end
		setPanelVisible(nextOpen)
		refreshRows()
	end)
	bindGuiButton(backdrop, function()
		setPanelVisible(false)
	end)
	bindGuiButton(close, function()
		setPanelVisible(false)
	end)
	bindGuiButton(allToggle, function()
		state.masterMarkers = not state.masterMarkers
		applyToggleVisual(allToggle, state.masterMarkers, COLORS.On)
		scheduleWaypointPreferenceSave()
		refreshRows()
	end)
	bindGuiButton(clearTracked, function()
		state.activeWaypointId = nil
		scheduleWaypointPreferenceSave()
		refreshRows()
		updateTracker()
	end)
	bindGuiButton(trackerClear, function()
		state.activeWaypointId = nil
		scheduleWaypointPreferenceSave()
		refreshRows()
		updateTracker()
	end)
	bindGuiButton(trackerTeleport, function()
		teleportToWaypoint(getActiveWaypoint())
	end)
	for category, toggle in pairs(state.ui.categoryToggles) do
		bindGuiButton(toggle, function()
			state.categoryEnabled[category] = not state.categoryEnabled[category]
			applyToggleVisual(toggle, state.categoryEnabled[category], CATEGORY_INFO[category].color)
			scheduleWaypointPreferenceSave()
			refreshRows()
		end)
		applyToggleVisual(toggle, state.categoryEnabled[category], CATEGORY_INFO[category].color)
	end
	applyToggleVisual(allToggle, state.masterMarkers, COLORS.On)

	if ClosePanels then
		ClosePanels.Event:Connect(function(source)
			if source == "Waypoints" then return end
			if state.panelOpen then
				setPanelVisible(false)
			end
		end)
	end
end

local function bindPlacedFolder()
	local _waypointRefreshQueued = false
	for _, connection in ipairs(state.placedConnections) do
		connection:Disconnect()
	end
	table.clear(state.placedConnections)
	local placed = Workspace:FindFirstChild("PlacedObjects")
	if not placed then return end

	local function watchPlacedModel(model)
		if not (model and model:IsA("Model")) then
			return
		end
		table.insert(state.placedConnections, model:GetAttributeChangedSignal("CustomName"):Connect(function()
			task.defer(refreshAll)
		end))
		table.insert(state.placedConnections, model:GetPropertyChangedSignal("Name"):Connect(function()
			task.defer(refreshAll)
		end))
	end

	table.insert(state.placedConnections, placed.DescendantAdded:Connect(function(child)
		if child:IsA("Model") and isPlacedObjectRootModel(child, placed) then
			watchPlacedModel(child)
		end
		-- Debounced: was task.defer(refreshAll) every DescendantAdded = N calls per placed model.
		-- Now queues at most once per frame regardless of how many parts stream in.
		if not _waypointRefreshQueued then
			_waypointRefreshQueued = true
			task.defer(function()
				_waypointRefreshQueued = false
				refreshAll()
			end)
		end
	end))
	table.insert(state.placedConnections, placed.DescendantRemoving:Connect(function()
		-- Debounced: queue at most one refreshAll per frame
		if not _waypointRefreshQueued then
			_waypointRefreshQueued = true
			task.defer(function()
				_waypointRefreshQueued = false
				refreshAll()
			end)
		end
	end))
	for _, child in ipairs(placed:GetDescendants()) do
		if child:IsA("Model") and isPlacedObjectRootModel(child, placed) then
			watchPlacedModel(child)
		end
	end
end

local function bindRuntime()
	table.insert(state.connections, Workspace.ChildAdded:Connect(function(child)
		if child.Name == "PlacedObjects" then
			bindPlacedFolder()
			refreshAll()
		end
	end))
	table.insert(state.connections, Player.CharacterAdded:Connect(function()
		task.wait(0.5)
		refreshRows()
		updateTracker()
	end))
	table.insert(state.connections, UserInputService.InputBegan:Connect(function(input, gameProcessed)
		if gameProcessed then return end
		if UserInputService:GetFocusedTextBox() then return end
		if input.KeyCode == HOTKEY_MARKERS then
			state.masterMarkers = not state.masterMarkers
			if state.ui.allToggle then
				applyToggleVisual(state.ui.allToggle, state.masterMarkers, COLORS.On)
			end
			scheduleWaypointPreferenceSave()
			refreshRows()
		end
	end))
	table.insert(state.connections, Workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
		Camera = Workspace.CurrentCamera
		updateButtonLayout()
		updateVisualState()
	end))
	table.insert(state.connections, RunService.RenderStepped:Connect(function()
		if os.clock() - state.lastRefresh > 4 then
			refreshAll()
		end
		updateButtonLayout()
		updateVisualState()
		updateTracker()
	end))
end

ensureUi()
updateButtonLayout()
task.defer(updateButtonLayout)
task.delay(0.15, updateButtonLayout)
task.delay(0.5, updateButtonLayout)
bindPlacedFolder()
refreshAll()
bindRuntime()