--[=[ PATH: StarterPlayerScripts/SlopeClient | TYPE: LocalScript ]=]--
--[[
SCRIPT: SlopeClient V15
DOES: Handles slope drawing (point mode), width control, decor toggles, and live, continuous path previewing matching terrain angles. It differentiates between camera drags/swipes and intended taps to ensure points are only placed on intentional clicks. It also filters inputs overlapping with core/custom UI elements to prevent accidental placement.
OLD SCRIPT DID: 
- Handled point-to-point drawing.
- Width previews were rigid straight cylinders locked to a global axis, ignoring curves.
- Edge previews stepped over points leaving disjointed, straight segments that didn't match the slope's curve.
- Added a `getRightVector` calculation to dynamically determine the perpendicular angle of the path at any given node.
- Replaced the rigid cylinder WidthMarkers with orientation-aware markers that dynamically rotate to align perfectly across the slope path.
- Updated Edge preview generation to continuously link edge nodes between every single point, rendering a smooth, curving visual that perfectly matches the terrain.
- Immediately triggered point placement on `InputBegan`, causing camera adjustment swipes on mobile to accidentally drop points.
- Lacked strict manual checks for custom GUIs, allowing inputs on non-active UI frames (like menu backgrounds or chat) to place points.
ADDED/REMOVED:
- Added `touchStartPos` and `touchStartTime` variables to track the origin and duration of an input.
- Moved point placement logic from `InputBegan` to `InputEnded` to allow for drag evaluation.
- Implemented distance thresholding (< 15 pixels) and time thresholding (< 0.6s) to accurately filter out mobile camera panning and swiping.
- Integrated an explicit `PlayerGui:GetGuiObjectsAtPosition` iteration on both press and release. This forcibly halts point placement if the touch overlaps with `menuGui`, `hudGui`, or any standard active object (joystick/chat), circumventing unhandled `gpe` edges.
]]

local Players = game:GetService("Players")
local UIS = game:GetService("UserInputService")
local GuiService = game:GetService("GuiService")
local RunService = game:GetService("RunService")
local RS = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")
local TweenService = game:GetService("TweenService")

print("[SlopeClient] Initializing V15 (Curved Previews & Touch Validation)")

local Player = Players.LocalPlayer
local PlayerGui = Player:WaitForChild("PlayerGui")
local Camera = workspace.CurrentCamera
local Config = require(RS:WaitForChild("Config"))
local Events = RS:WaitForChild("Events")
local PlaceEvent = Events:WaitForChild("PlaceItem")
local ClosePanels = Events:FindFirstChild("ClosePanels")
if not ClosePanels then
	ClosePanels = Instance.new("BindableEvent")
	ClosePanels.Name = "ClosePanels"
	ClosePanels.Parent = Events
end
local ModeState = PlayerGui:FindFirstChild("ModeState") or Instance.new("StringValue")
ModeState.Name = "ModeState"
ModeState.Parent = PlayerGui
local ShopFolder = RS:FindFirstChild("Shop")
local SlopeMathModule = ShopFolder and ShopFolder:FindFirstChild("SlopeMath")
local MainHUD = PlayerGui:WaitForChild("MainHUD", 10)
local Dock = MainHUD and MainHUD:WaitForChild("Dock", 10)
local SlopeMath = nil
if SlopeMathModule and SlopeMathModule:IsA("ModuleScript") then
	local ok, loaded = pcall(require, SlopeMathModule)
	if ok then
		SlopeMath = loaded
		print("[SlopeClient] Loaded SlopeMath Module")
	end
end

local existingHud = PlayerGui:FindFirstChild("SlopeBuilderUI")
if existingHud then
	existingHud.Enabled = false
	local existingMain = existingHud:FindFirstChild("MainPanel")
	if existingMain and existingMain:IsA("GuiObject") then
		existingMain.Visible = false
	end
end

local SLOPE_COLORS = {
	[1] = Color3.fromRGB(76, 209, 55),
	[2] = Color3.fromRGB(52, 152, 219),
	[3] = Color3.fromRGB(44, 62, 80),
	[4] = Color3.fromRGB(255, 215, 0),
	[5] = Color3.fromRGB(44, 62, 80),
}

local DIFF_NAMES = {
	[1] = "Green Circle",
	[2] = "Blue Square",
	[3] = "Black Diamond",
	[4] = "Double Black",
	[5] = "Triple Black",
}

local DIFF_KEYS = {
	[1] = "Green",
	[2] = "Blue",
	[3] = "Black",
	[4] = "Double Black",
	[5] = "Triple Black",
}

local DIFF_DEF_WIDTH = {
	Green = 90,
	Blue = 70,
	Black = 45,
	["Double Black"] = 35,
	["Triple Black"] = 28,
	["Glade"] = 32,
}

local DRAW = {
	MIN_LEN = 15,
	DEF_W = 90,
	-- Match the server/shared minimum width so finish/edit rebuilds stay stable.
	MIN_W = 30,
	MAX_W = 160,
	W_STEP = 5,
}

local COST_RATE = {
	Green = 2,
	Blue = 4,
	Black = 7,
	["Double Black"] = 11,
	["Triple Black"] = 16,
	["Glade"] = 5,
}

local MAX_ANGLE = {
	Green = 25,
	Blue = 35,
	Black = 50,
	["Double Black"] = 90,
	["Triple Black"] = 90,
	["Glade"] = 45,
}

local isMenuOpen = false
local isDrawing = false
local slopePoints = {}
local widthData = {}
local currentWidth = DRAW.DEF_W
local selectedSlope = nil
local slopeSnaps = {}
local activeSnap = nil
local slopeData = nil
local slopeName = nil
local previewFolder = nil
local menuGui = nil
local hudGui = nil
local conns = {}
local hudConns = {}
local lastPreviewHit = nil
local lastPreviewRenderAt = 0
local lastPreviewRenderHit = nil
local lastPreviewControlCount = 0
local mobileTouchPos = nil
local connectorFolder = nil
local connectorPoints = {}

local function GetSlopeMenuPriceText(itemName)
	local details = type(Config.GetPlacementPriceDetails) == "function" and Config.GetPlacementPriceDetails(itemName, Player) or nil
	local price = details and details.FinalCost or Config.GetPlacementCost(itemName, Player)
	local discountPercent = details and details.DiscountPercent or 0
	if discountPercent and discountPercent > 0 then
		return string.format("$%d (-%d%%)", price, discountPercent)
	end
	return "$" .. price
end

local function RefreshSlopeMenuPrices()
	if not menuGui then return end
	for _, descendant in ipairs(menuGui:GetDescendants()) do
		if descendant:IsA("TextButton") then
			local itemName = descendant:GetAttribute("SlopeItemName") or descendant.Name
			local priceLabel = descendant:FindFirstChild("PriceLabel")
			if type(itemName) == "string" and priceLabel and priceLabel:IsA("TextLabel") and Config.Items[itemName] then
				priceLabel.Text = GetSlopeMenuPriceText(itemName)
			end
		end
	end
end

local function UseCenteredTouchAim()
	if not UIS.TouchEnabled then return false end
	if not UIS.KeyboardEnabled then return true end
	return Camera and Camera.ViewportSize.X < 900 or false
end

local function GetSlopeAimScreenPosition()
	if UseCenteredTouchAim() then
		if mobileTouchPos then return mobileTouchPos, true end
		local viewport = Camera.ViewportSize
		return Vector2.new(viewport.X * 0.5, viewport.Y * 0.5), true
	end
	return UIS:GetMouseLocation(), false
end

local decorOptions = {
	markers = true,
	nets = true,
	markerLights = true,
}

local function BuildPlacementPathFromControlPoints(controls)
	controls = controls or slopePoints
	if #controls == 2 and SlopeMath and type(SlopeMath.generateAutoPath) == "function" then
		local difficultyKey = (selectedSlope and selectedSlope.DifficultyKey) or "Green"
		local ok, generated = pcall(function()
			return SlopeMath.generateAutoPath(controls[1], controls[2], workspace.Terrain, difficultyKey)
		end)
		if ok and type(generated) == "table" and #generated >= 2 then
			return generated, true
		end
	end
	return controls, false
end

local function MapControlIndex(controlIndex, controlCount, pathCount)
	controlIndex = math.clamp(math.floor(controlIndex or 1), 1, math.max(1, controlCount))
	if controlCount <= 1 then return 1 end
	local t = (controlIndex - 1) / (controlCount - 1)
	return math.clamp(math.floor(t * math.max(1, pathCount - 1) + 1), 1, math.max(1, pathCount))
end

local function BuildMappedWidthData(pathCount, controls)
	controls = controls or slopePoints
	pathCount = math.max(1, pathCount or #controls)
	local mapped = {}

	if #widthData == 0 then
		table.insert(mapped, {index = 1, width = currentWidth})
		table.insert(mapped, {index = pathCount, width = currentWidth})
		return mapped
	end

	local isPathOrQueue = selectedSlope and (selectedSlope.Name == "Queue Path" or (slopeData and slopeData.IsPath))
	local clampMin = isPathOrQueue and 1 or DRAW.MIN_W

	for _, wd in ipairs(widthData) do
		local srcIndex = tonumber(wd.index or 1) or 1
		local width = tonumber(wd.width or currentWidth) or currentWidth
		width = math.clamp(width, clampMin, DRAW.MAX_W)
		local mappedIndex = MapControlIndex(srcIndex, #controls, pathCount)
		table.insert(mapped, {index = mappedIndex, width = width})
	end

	local function ensureBoundary(index)
		for _, wd in ipairs(mapped) do
			if wd.index == index then return end
		end
		local boundaryWidth = currentWidth
		if index == 1 and #mapped > 0 then
			boundaryWidth = mapped[1].width
		elseif index == pathCount and #mapped > 0 then
			boundaryWidth = mapped[#mapped].width
		end
		table.insert(mapped, {index = index, width = boundaryWidth})
	end

	ensureBoundary(1)
	ensureBoundary(pathCount)
	table.sort(mapped, function(a, b) return a.index < b.index end)

	local deduped = {}
	for _, wd in ipairs(mapped) do
		if deduped[#deduped] and deduped[#deduped].index == wd.index then
			deduped[#deduped].width = wd.width
		else
			table.insert(deduped, wd)
		end
	end

	return deduped
end

local function Round(inst, r)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, r or 8)
	c.Parent = inst
	return c
end

local function Stroke(inst, col, th)
	local s = Instance.new("UIStroke")
	s.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	s.Color = col or Color3.fromRGB(0,0,0)
	s.Thickness = th or 1
	s.Parent = inst
	return s
end

local function SetTextSafe(inst, value)
	if not inst then return end
	if inst:IsA("TextLabel") or inst:IsA("TextButton") or inst:IsA("TextBox") then
		inst.Text = tostring(value or "")
	end
end

local function FormatCompactMoney(value)
	local amount = math.max(0, tonumber(value) or 0)
	if amount >= 1000000 then
		return string.format("$%.2fM", amount / 1000000)
	elseif amount >= 1000 then
		return string.format("$%.1fk", amount / 1000)
	end
	return "$" .. math.floor(amount + 0.5)
end

local function findChildByNames(parent, names)
	if not parent then
		return nil
	end
	for _, name in ipairs(names) do
		local child = parent:FindFirstChild(name)
		if child then
			return child
		end
	end
	return nil
end

local function bindGuiButton(button, callback)
	if not (button and callback) then return end
	button.Active = true
	button.Selectable = true
	button.AutoButtonColor = true
	local firedAt = 0
	local function fire()
		local now = os.clock()
		if now - firedAt < 0.12 then return end
		firedAt = now
		callback()
	end
	local activatedConn = button.Activated:Connect(fire)
	table.insert(hudConns, activatedConn)
end

local function RayTerrain(x, y, isViewport)
	if not Camera then return nil end

	local screenX, screenY = x, y
	if not screenX then
		local aim, vport = GetSlopeAimScreenPosition()
		screenX, screenY = aim.X, aim.Y
		isViewport = vport
	end
	if isViewport == nil then isViewport = true end

	local ray
	if isViewport then
		ray = Camera:ViewportPointToRay(screenX, screenY)
	else
		local inset = game:GetService("GuiService"):GetGuiInset()
		ray = Camera:ViewportPointToRay(screenX, screenY - inset.Y)
	end

	local p = RaycastParams.new()
	p.FilterType = Enum.RaycastFilterType.Include
	p.FilterDescendantsInstances = {workspace.Terrain}
	p.IgnoreWater = true
	local hit = workspace:Raycast(ray.Origin, ray.Direction * 10000, p)
	return hit and hit.Position or nil
end

local function PathLen(points)
	if #points < 2 then return 0 end
	local total = 0
	for i = 1, #points - 1 do
		total = total + (points[i + 1] - points[i]).Magnitude
	end
	return total
end

local function LiveDifficulty(points)
	if #points < 2 then return "Green", 0 end
	local maxAngle = 0
	local step = math.max(1, math.floor(#points / 15))
	for i = 1, #points - step, step do
		local p1 = points[i]
		local p2 = points[i + step]
		local h = Vector3.new(p2.X - p1.X, 0, p2.Z - p1.Z).Magnitude
		local v = math.abs(p2.Y - p1.Y)
		if h > 1 then
			maxAngle = math.max(maxAngle, math.deg(math.atan(v / h)))
		end
	end

	if maxAngle < 12 then return "Green", maxAngle end
	if maxAngle < 25 then return "Blue", maxAngle end
	if maxAngle < 40 then return "Black", maxAngle end
	return "Double Black", maxAngle
end

local function CostEstimate(points)
	local len = PathLen(points)
	local itemName = tostring(currentItemName or (slopeData and slopeData.Name) or "")
	if itemName ~= "" then
		return Config.GetPlacementCost(itemName, Player, len)
	end
	local basePrice = math.max(0, math.floor(tonumber(slopeData and slopeData.Price) or 0))
	local perStud = math.max(0, tonumber(slopeData and slopeData.PricePerStud) or 0)
	return math.floor(basePrice + (len * perStud))
end

local function GetWidthAt(index, widthSource)
	widthSource = widthSource or widthData
	if #widthSource == 0 then return currentWidth end
	if #widthSource == 1 then return widthSource[1].width end
	local prev, nxt
	for _, wd in ipairs(widthSource) do
		if wd.index <= index then prev = wd end
		if wd.index >= index and not nxt then nxt = wd end
	end
	if not prev then return widthSource[1].width end
	if not nxt then return widthSource[#widthSource].width end
	if prev.index == nxt.index then return prev.width end
	local t = (index - prev.index) / (nxt.index - prev.index)
	t = t * t * (3 - 2 * t)
	return prev.width + (nxt.width - prev.width) * t
end

local function ClearPreview()
	if previewFolder then
		previewFolder:Destroy()
		previewFolder = nil
	end
	if connectorFolder then
		connectorFolder:Destroy()
		connectorFolder = nil
	end
	connectorPoints = {}
end

local function EnsurePreview(color)
	if previewFolder and previewFolder.Parent then return end
	previewFolder = Instance.new("Folder")
	previewFolder.Name = "SlopePreview"
	previewFolder.Parent = workspace

	local cursor = Instance.new("Part")
	cursor.Name = "Cursor"
	cursor.Shape = Enum.PartType.Ball
	cursor.Size = Vector3.new(3, 3, 3)
	cursor.Anchored = true
	cursor.CanCollide = false
	cursor.Material = Enum.Material.Neon
	cursor.Color = color
	cursor.Transparency = 0.4
	cursor.Parent = previewFolder
	print("[SlopeClient] Instantiated Preview Folder")
end

local function RenderPreview(activeControls)
	if not previewFolder then return end
	for _, child in ipairs(previewFolder:GetChildren()) do
		if child.Name ~= "Cursor" then
			child:Destroy()
		end
	end

	if #activeControls < 2 or not selectedSlope then return end

	local previewPath, usedAutoPath = BuildPlacementPathFromControlPoints(activeControls)
	if #previewPath < 2 then return end
	local previewWidths = BuildMappedWidthData(#previewPath, activeControls)

	local color = SLOPE_COLORS[selectedSlope.Difficulty] or SLOPE_COLORS[1]

	local function getRightVector(idx)
		local pA = previewPath[math.max(1, idx - 1)]
		local pB = previewPath[math.min(#previewPath, idx + 1)]
		local dir = (pB - pA).Unit
		local right = dir:Cross(Vector3.yAxis)
		if right.Magnitude < 0.001 then return Vector3.xAxis end
		return right.Unit
	end

	local function snapToTerrain(pos)
		local rp = RaycastParams.new()
		rp.FilterType = Enum.RaycastFilterType.Include
		rp.FilterDescendantsInstances = {workspace.Terrain}
		rp.IgnoreWater = true
		local result = workspace:Raycast(pos + Vector3.new(0, 200, 0), Vector3.new(0, -600, 0), rp)
		if result then return result.Position end
		return pos
	end

	if slopeName == "Queue Path" then
		local function createStanchion(parent, pos)
			local pole = Instance.new("Part")
			pole.Anchored = true; pole.CanCollide = false; pole.CanQuery = false; pole.CanTouch = false
			pole.Material = Enum.Material.Metal
			pole.Color = Color3.fromRGB(180, 180, 190)
			pole.Size = Vector3.new(0.3, 3.2, 0.3)
			pole.CFrame = CFrame.new(pos) * CFrame.new(0, 1.6, 0)
			pole.Parent = parent

			local mesh = Instance.new("CylinderMesh", pole)
			local base = Instance.new("CylinderHandleAdornment")
			base.Radius = 1.1; base.Height = 0.2; base.InnerRadius = 0
			base.Color3 = Color3.fromRGB(50, 50, 55)
			base.CFrame = CFrame.new(0, -1.6, 0) * CFrame.Angles(math.pi/2, 0, 0)
			base.Adornee = pole; base.Parent = pole

			local attach1 = Instance.new("Attachment", pole); attach1.Position = Vector3.new(0, 1.2, 0)
			local attach2 = Instance.new("Attachment", pole); attach2.Position = Vector3.new(0, 0.4, 0)
			return pole, attach1, attach2
		end

		local function drawRopeConstraint(parent, att1, att2)
			local rope = Instance.new("RopeConstraint")
			rope.Attachment0 = att1; rope.Attachment1 = att2
			rope.Visible = true; rope.Color = BrickColor.new("Crimson")
			rope.Thickness = 0.15
			rope.Length = (att1.WorldPosition - att2.WorldPosition).Magnitude * 1.05
			rope.Parent = parent
			return rope
		end

		local drawFences = decorOptions.nets
		local prevLeftTop, prevLeftMid, prevRightTop, prevRightMid

		for i = 1, #previewPath do
			local p1 = previewPath[i]
			local rightVec = getRightVector(i)
			local hw = GetWidthAt(i, previewWidths) * 0.5

			if drawFences then
				local leftPos = p1 - (rightVec * hw)
				local rightPos = p1 + (rightVec * hw)
				local _, lAtt1, lAtt2 = createStanchion(previewFolder, leftPos)
				local _, rAtt1, rAtt2 = createStanchion(previewFolder, rightPos)

				if prevLeftTop then
					drawRopeConstraint(previewFolder, prevLeftTop, lAtt1)
					drawRopeConstraint(previewFolder, prevLeftMid, lAtt2)
				end
				if prevRightTop then
					drawRopeConstraint(previewFolder, prevRightTop, rAtt1)
					drawRopeConstraint(previewFolder, prevRightMid, rAtt2)
				end
				prevLeftTop = lAtt1; prevLeftMid = lAtt2
				prevRightTop = rAtt1; prevRightMid = rAtt2
			end
		end

		for _, idx in ipairs({1, #previewPath}) do
			local p = previewPath[idx]
			local hw = GetWidthAt(idx, previewWidths)
			local right = getRightVector(idx)
			local forward = Vector3.yAxis:Cross(right).Unit

			local ind = Instance.new("Part")
			ind.Anchored = true; ind.CanCollide = false; ind.Material = Enum.Material.Neon
			ind.Color = Color3.fromRGB(255, 50, 50)
			ind.Size = Vector3.new(hw, 0.2, 1)
			ind.CFrame = CFrame.lookAt(p + Vector3.new(0,0.1,0), p + Vector3.new(0,0.1,0) + forward)
			ind.Parent = previewFolder
		end
	else
		for i = 1, #previewPath - 1 do
			local p1 = previewPath[i]
			local p2 = previewPath[i + 1]
			local dist = (p2 - p1).Magnitude
			if dist < 0.1 then continue end
			local mid = (p1 + p2) * 0.5
			local dir = (p2 - p1).Unit

			-- Centerline
			local line = Instance.new("Part")
			line.Name = "CenterLine"; line.Anchored = true; line.CanCollide = false; line.CastShadow = false
			line.Material = Enum.Material.Neon; line.Color = color; line.Transparency = 0.3
			line.Size = Vector3.new(2, 0.5, dist)
			line.CFrame = CFrame.lookAt(mid + Vector3.yAxis * 0.5, mid + Vector3.yAxis * 0.5 + dir)
			line.Parent = previewFolder

			-- Continuous Edges
			local r1 = getRightVector(i)
			local r2 = getRightVector(i + 1)
			local hw1 = GetWidthAt(i, previewWidths) * 0.5
			local hw2 = GetWidthAt(i + 1, previewWidths) * 0.5

			for _, side in ipairs({-1, 1}) do
				local e1raw = p1 + r1 * hw1 * side
				local e2raw = p2 + r2 * hw2 * side
				local e1 = snapToTerrain(e1raw) + Vector3.new(0, 0.5, 0)
				local e2 = snapToTerrain(e2raw) + Vector3.new(0, 0.5, 0)
				local eDist = (e2 - e1).Magnitude
				if eDist < 0.1 then continue end
				local eMid = (e1 + e2) * 0.5
				local eDir = (e2 - e1).Unit

				local edge = Instance.new("Part")
				edge.Name = "Edge"; edge.Anchored = true; edge.CanCollide = false; edge.CastShadow = false
				edge.Material = Enum.Material.Neon; edge.Color = Color3.new(1, 1, 1); edge.Transparency = 0.5
				edge.Size = Vector3.new(0.5, 0.3, eDist)
				edge.CFrame = CFrame.lookAt(eMid, eMid + eDir)
				edge.Parent = previewFolder
			end
		end
	end

	for _, wd in ipairs(previewWidths) do
		local idx = math.clamp(wd.index, 1, #previewPath)
		local pos = previewPath[idx]
		if not pos then continue end

		local right = getRightVector(idx)
		local forward = Vector3.yAxis:Cross(right).Unit

		-- Snap both edges to terrain for width marker so it stays visible
		local hw = wd.width * 0.5
		local leftEdge = snapToTerrain(pos - right * hw)
		local rightEdge = snapToTerrain(pos + right * hw)
		local markerCenter = (leftEdge + rightEdge) * 0.5 + Vector3.new(0, 0.6, 0)
		local markerDir = (rightEdge - leftEdge)
		local markerWidth = markerDir.Magnitude
		if markerWidth < 0.1 then markerWidth = wd.width end
		local markerRight = markerDir.Unit
		local markerLook = forward

		local marker = Instance.new("Part")
		marker.Name = "WidthMarker"; marker.Anchored = true; marker.CanCollide = false
		marker.Material = Enum.Material.Neon; marker.Color = Color3.fromRGB(255, 165, 0); marker.Transparency = 0.55
		marker.Size = Vector3.new(markerWidth, 0.3, 0.6)
		marker.CFrame = CFrame.lookAt(markerCenter, markerCenter + markerLook)
		marker.Parent = previewFolder
	end

	local function Ball(pos, col)
		local b = Instance.new("Part")
		b.Transparency = 1
		b.CanCollide = false
		b.Anchored = true
		b.Size = Vector3.new(0.1, 0.1, 0.1)
		b.Position = pos + Vector3.yAxis * 2
		b.Parent = previewFolder

		local bb = Instance.new("BillboardGui")
		bb.Adornee = b; bb.Size = UDim2.new(0, 18, 0, 18); bb.AlwaysOnTop = true; bb.Parent = b
		local f = Instance.new("Frame"); f.Size = UDim2.new(1, 0, 1, 0); f.BackgroundColor3 = col
		f.BackgroundTransparency = 0.2; f.Parent = bb
		Instance.new("UICorner", f).CornerRadius = UDim.new(1, 0)
		local s = Instance.new("UIStroke"); s.Color = Color3.new(1, 1, 1); s.Thickness = 2; s.Parent = f
	end
	Ball(previewPath[1], Color3.fromRGB(0, 255, 0))
	Ball(previewPath[#previewPath], Color3.fromRGB(255, 0, 0))

	for idx, p in ipairs(activeControls) do
		local wp = Instance.new("Part")
		wp.Name = "Waypoint_" .. idx
		wp.Transparency = 1
		wp.CanCollide = false
		wp.Anchored = true
		wp.Size = Vector3.new(0.1, 0.1, 0.1)
		wp.Position = p + Vector3.yAxis * 2
		wp.Parent = previewFolder

		local bb = Instance.new("BillboardGui")
		bb.Adornee = wp; bb.Size = UDim2.new(0, 14, 0, 14); bb.AlwaysOnTop = true; bb.Parent = wp
		local f = Instance.new("Frame"); f.Size = UDim2.new(1, 0, 1, 0); f.BackgroundColor3 = color
		f.BackgroundTransparency = 0.2; f.Parent = bb
		Instance.new("UICorner", f).CornerRadius = UDim.new(1, 0)
		local s = Instance.new("UIStroke"); s.Color = Color3.new(1, 1, 1); s.Thickness = 1.5; s.Parent = f
	end

	if usedAutoPath and #previewPath > #activeControls then
		for i = 2, #previewPath - 1 do
			local p = previewPath[i]
			local autoNode = Instance.new("Part")
			autoNode.Name = "AutoNode_" .. i; autoNode.Shape = Enum.PartType.Ball; autoNode.Size = Vector3.new(1.8, 1.8, 1.8)
			autoNode.Position = p + Vector3.yAxis * 1.5; autoNode.Anchored = true; autoNode.CanCollide = false
			autoNode.Material = Enum.Material.Neon; autoNode.Color = Color3.fromRGB(255, 200, 0); autoNode.Transparency = 0.7
			autoNode.Parent = previewFolder
		end
	end
end

local function SetCurrentWidth(newWidth)
	local isPathOrQueue = selectedSlope and (selectedSlope.Name == "Queue Path" or (slopeData and slopeData.IsPath))
	local minW = isPathOrQueue and 1 or DRAW.MIN_W
	currentWidth = math.clamp(newWidth, minW, DRAW.MAX_W)
	if #slopePoints > 0 then
		if #widthData == 0 then
			for i = 1, #slopePoints do
				table.insert(widthData, {index = i, width = currentWidth})
			end
		else
			for _, wd in ipairs(widthData) do
				wd.width = currentWidth
			end
			for i = #widthData + 1, #slopePoints do
				table.insert(widthData, {index = i, width = currentWidth})
			end
		end
	end
	print("[SlopeClient] Width set to " .. tostring(currentWidth))
end

local function ChangeWidthBy(stepDelta)
	if not stepDelta or stepDelta == 0 then return end
	local isPathOrQueue = selectedSlope and (selectedSlope.Name == "Queue Path" or (slopeData and slopeData.IsPath))
	local step = isPathOrQueue and 1 or DRAW.W_STEP
	SetCurrentWidth(currentWidth + stepDelta * step)
end

local function AddControlPoint(hit)
	if not hit then return false end
	table.insert(slopePoints, hit)
	table.insert(widthData, {index = #slopePoints, width = currentWidth})
	return true
end

local function StopDrawing()
	print("[SlopeClient] Drawing Stopped")
	if Dock then Dock.Visible = true end
	isDrawing = false
	slopePoints = {}
	widthData = {}
	lastPreviewHit = nil
	lastPreviewRenderAt = 0
	lastPreviewRenderHit = nil
	lastPreviewControlCount = 0
	selectedSlope = nil
	slopeData = nil
	slopeName = nil
	if ModeState.Value == "Slope" then
		ModeState.Value = ""
	end

	for _, c in pairs(conns) do
		if typeof(c) == "RBXScriptConnection" then c:Disconnect()
		elseif typeof(c) == "Instance" then c:Destroy() end
	end
	conns = {}

	ClearPreview()

	if hudGui then
		hudGui.Enabled = false
		local mainPanel = hudGui:FindFirstChild("MainPanel")
		if mainPanel then mainPanel.Visible = false end
		for _, c in pairs(hudConns) do
			if typeof(c) == "RBXScriptConnection" then
				c:Disconnect()
			elseif typeof(c) == "Instance" then
				c:Destroy()
			end
		end
		hudConns = {}
		print("[SlopeClient] HUD Hidden & Connections Cleared")
	end
end

local function BuildDefaultDecorOptions(difficultyKey)
	decorOptions.markers = true
	decorOptions.nets = (difficultyKey == "Green" or difficultyKey == "Blue")
	decorOptions.markerLights = true
end

local function CreateHUD(slopeName, slopeData, fnSend, fnUndo, fnAddPoint)
	hudGui = PlayerGui:WaitForChild("SlopeBuilderUI")
	if not hudGui then
		warn("[SlopeClient] SlopeBuilderUI missing from PlayerGui")
		return nil
	end
	hudGui.Enabled = true
	print("[SlopeClient] Active UI hooked to physical HUD")

	local main = hudGui:WaitForChild("MainPanel")
	main.Visible = true  -- MainPanel defaults to Visible=false, must explicitly show it
	local header = main:WaitForChild("HeaderRow")
	local titleLbl = findChildByNames(header, {"Title", "SlopeTitle"})
	local costLbl = findChildByNames(header, {"CostLabel", "PriceLabel", "EstimateLabel"})

	local decorRow = main:WaitForChild("DecorRow")
	local markerBtn = findChildByNames(decorRow, {"MarkersBtn", "Markers"})
	local netBtn = findChildByNames(decorRow, {"NetsBtn", "Nets"})
	local lightBtn = findChildByNames(decorRow, {"LightsBtn", "Lights"})

	local statsRow = main:WaitForChild("StatsRow")
	local widthMinus = findChildByNames(statsRow, {"WidthMinus", "MinusBtn"})
	local widthPlus = findChildByNames(statsRow, {"WidthPlus", "PlusBtn"})
	local widthLabel = findChildByNames(statsRow, {"WidthLabel", "WidthValue"})
	local diffLabel = findChildByNames(statsRow, {"DiffLabel", "DifficultyLabel"})

	local elevationBar = main:WaitForChild("ElevationBar")
	local elevationFill = findChildByNames(elevationBar, {"ElevationFill", "Fill"})
	local elevationText = findChildByNames(elevationBar, {"ElevationText", "Meta", "Stats"})

	local actionRow = main:WaitForChild("ActionRow")
	local undoBtn = findChildByNames(actionRow, {"UndoBtn", "Undo"})
	local finishBtn = findChildByNames(actionRow, {"FinishBtn", "Finish", "DoneBtn"})
	local cancelBtn = findChildByNames(actionRow, {"CancelBtn", "Cancel", "ExitBtn"})

	if not (titleLbl and costLbl and markerBtn and netBtn and lightBtn and widthMinus and widthPlus and widthLabel and diffLabel and elevationFill and elevationText and undoBtn and finishBtn and cancelBtn) then
		warn("[SlopeClient] SlopeBuilderUI is missing required controls.")
		return nil
	end

	local staleAddPoint = main:FindFirstChild("TouchAddPointBtn")
	if staleAddPoint then staleAddPoint:Destroy() end
	local staleHint = main:FindFirstChild("TouchHint")
	if staleHint then staleHint:Destroy() end
	local staleReticle = hudGui:FindFirstChild("TouchReticle")
	if staleReticle then staleReticle:Destroy() end

	local addPointBtn = nil
	local color = SLOPE_COLORS[slopeData.Difficulty] or SLOPE_COLORS[1]
	titleLbl.Text = slopeName:upper()
	titleLbl.TextColor3 = color
	SetTextSafe(costLbl, FormatCompactMoney(0))

	if slopeData.IsQueue or slopeData.IsPath then 
		decorRow.Visible = false 
	else
		decorRow.Visible = true
	end

	local DECOR_ON_COLOR  = Color3.fromRGB(34, 197, 94)
	local DECOR_OFF_COLOR = Color3.fromRGB(17, 19, 24)

	local function refreshButtons()
		markerBtn.BackgroundColor3 = decorOptions.markers and DECOR_ON_COLOR or DECOR_OFF_COLOR
		markerBtn.TextColor3 = decorOptions.markers and Color3.fromRGB(240,240,240) or Color3.fromRGB(150, 150, 155)

		netBtn.BackgroundColor3 = decorOptions.nets and DECOR_ON_COLOR or DECOR_OFF_COLOR
		netBtn.TextColor3 = decorOptions.nets and Color3.fromRGB(240,240,240) or Color3.fromRGB(150, 150, 155)

		local lightOn = decorOptions.markerLights and decorOptions.markers
		lightBtn.BackgroundColor3 = lightOn and DECOR_ON_COLOR or DECOR_OFF_COLOR
		lightBtn.TextColor3 = lightOn and Color3.fromRGB(240,240,240) or Color3.fromRGB(150, 150, 155)
	end

	bindGuiButton(markerBtn, function()
		decorOptions.markers = not decorOptions.markers
		if not decorOptions.markers then decorOptions.markerLights = false end
		refreshButtons()
	end)

	bindGuiButton(netBtn, function()
		decorOptions.nets = not decorOptions.nets
		refreshButtons()
	end)

	bindGuiButton(lightBtn, function()
		if not decorOptions.markers then return end
		decorOptions.markerLights = not decorOptions.markerLights
		refreshButtons()
	end)

	bindGuiButton(widthMinus, function() ChangeWidthBy(-1) end)
	bindGuiButton(widthPlus, function() ChangeWidthBy(1) end)

	bindGuiButton(cancelBtn, function() StopDrawing() end)
	bindGuiButton(undoBtn, function() if fnUndo then fnUndo() end end)
	bindGuiButton(finishBtn, function() if fnSend then fnSend() end end)

	if UseCenteredTouchAim() then
		finishBtn.Text = "DONE"

		addPointBtn = Instance.new("TextButton")
		addPointBtn.Name = "TouchAddPointBtn"
		addPointBtn.AnchorPoint = Vector2.new(0.5, 1)
		addPointBtn.Size = UDim2.new(0, 176, 0, 44)
		addPointBtn.Position = UDim2.new(0.5, 0, 0, -8)
		addPointBtn.BackgroundColor3 = color
		addPointBtn.BorderSizePixel = 0
		addPointBtn.Text = "SET START"
		addPointBtn.TextColor3 = Color3.fromRGB(240, 240, 240)
		addPointBtn.Font = Enum.Font.GothamBlack
		addPointBtn.TextScaled = true
		addPointBtn.ZIndex = 4
		addPointBtn.Parent = main
		Round(addPointBtn, 10)
		Stroke(addPointBtn, Color3.fromRGB(0, 0, 0), 1)
		table.insert(hudConns, addPointBtn)
		bindGuiButton(addPointBtn, function()
			if fnAddPoint then fnAddPoint() end
		end)

		local touchHint = Instance.new("TextLabel")
		touchHint.Name = "TouchHint"
		touchHint.AnchorPoint = Vector2.new(0.5, 1)
		touchHint.Size = UDim2.new(0, 240, 0, 20)
		touchHint.Position = UDim2.new(0.5, 0, 0, -56)
		touchHint.BackgroundColor3 = Color3.fromRGB(17, 19, 24)
		touchHint.BackgroundTransparency = 0.15
		touchHint.BorderSizePixel = 0
		touchHint.Text = "Aim with camera, then tap ADD POINT"
		touchHint.TextColor3 = Color3.fromRGB(230, 230, 235)
		touchHint.Font = Enum.Font.GothamMedium
		touchHint.TextSize = 12
		touchHint.ZIndex = 4
		touchHint.Parent = main
		Round(touchHint, 8)
		table.insert(hudConns, touchHint)

		local touchReticle = Instance.new("TextLabel")
		touchReticle.Name = "TouchReticle"
		touchReticle.AnchorPoint = Vector2.new(0.5, 0.5)
		touchReticle.Size = UDim2.new(0, 36, 0, 36)
		touchReticle.Position = UDim2.new(0.5, 0, 0.5, 0)
		touchReticle.BackgroundTransparency = 1
		touchReticle.Text = "+"
		touchReticle.TextColor3 = color
		touchReticle.Font = Enum.Font.GothamBlack
		touchReticle.TextScaled = true
		touchReticle.TextStrokeTransparency = 0.35
		touchReticle.ZIndex = 4
		touchReticle.Parent = hudGui
		table.insert(hudConns, touchReticle)
	end

	refreshButtons()

	return function(activeControls)
		refreshButtons()
		if addPointBtn then
			if #slopePoints == 0 then
				SetTextSafe(addPointBtn, "SET START")
			elseif #slopePoints == 1 then
				SetTextSafe(addPointBtn, "SET END")
			else
				SetTextSafe(addPointBtn, "ADD TURN")
			end
		end
		SetTextSafe(widthLabel, string.format("WIDTH %d", math.floor(currentWidth + 0.5)))
		if #activeControls >= 2 then
			local statPoints = BuildPlacementPathFromControlPoints(activeControls)
			local diff, maxAngle = LiveDifficulty(statPoints)
			local di = (diff == "Green" and 1) or (diff == "Blue" and 2) or (diff == "Black" and 3) or 4
			local dcol = SLOPE_COLORS[di] or SLOPE_COLORS[1]
			SetTextSafe(diffLabel, string.format("%s • %d°", string.upper(diff), math.floor(maxAngle + 0.5)))
			diffLabel.TextColor3 = dcol
			SetTextSafe(costLbl, FormatCompactMoney(CostEstimate(statPoints)))
			local drop = statPoints[1].Y - statPoints[#statPoints].Y
			local length = PathLen(statPoints)
			local pct = math.clamp(math.abs(drop) / 500, 0, 1)
			TweenService:Create(elevationFill, TweenInfo.new(0.15), {Size = UDim2.new(pct, 0, 1, 0)}):Play()
			SetTextSafe(elevationText, string.format("DROP %.0f • LEN %.0f", drop, length))
		else
			SetTextSafe(diffLabel, "AWAITING PATH")
			SetTextSafe(costLbl, FormatCompactMoney(0))
			SetTextSafe(elevationText, "DROP -- • LEN --")
		end
	end
end

local function BuildSlopeConnectors()
	if connectorFolder then connectorFolder:Destroy() end
	connectorFolder = Instance.new("Folder")
	connectorFolder.Name = "SlopeConnectors"
	connectorFolder.Parent = workspace
	connectorPoints = {}

	local placed = workspace:FindFirstChild("PlacedObjects")
	if not placed then return end

	for _, obj in ipairs(placed:GetDescendants()) do
		if obj:IsA("Model") and obj:GetAttribute("Type") == "Slope" then
			local rawPath = obj:GetAttribute("RawPoints")
			if rawPath then
				local okPath, pathData = pcall(function() return HttpService:JSONDecode(rawPath) end)
				if okPath and type(pathData) == "table" and #pathData > 1 then
					local pathPoints = {}
					for _, d in ipairs(pathData) do table.insert(pathPoints, Vector3.new(d[1], d[2], d[3])) end

					local totalLength = 0
					local segmentDistances = {0}
					for i = 1, #pathPoints - 1 do
						local dist = (pathPoints[i+1] - pathPoints[i]).Magnitude
						totalLength += dist
						segmentDistances[i+1] = totalLength
					end

					local function addConnector(pos)
						local p = Instance.new("Part")
						p.Size, p.Shape, p.Anchored, p.CanCollide, p.Material, p.Color, p.Transparency = Vector3.new(7,7,7), Enum.PartType.Ball, true, false, Enum.Material.Neon, Color3.fromRGB(0, 255, 127), 0.4
						p.Position = pos + Vector3.new(0, 2, 0)
						p.Parent = connectorFolder
						table.insert(connectorPoints, {Pos = pos, Part = p, IsNet = false, Model = obj})
					end

					-- Restrict slope snapping to true endpoints so run joins do not lock
					-- onto interior samples and create broken merges.
					addConnector(pathPoints[1])
					if #pathPoints > 1 then
						addConnector(pathPoints[#pathPoints])
					end
				end
			end
		end
	end
end

local function StartDrawing(newSlopeName, newSlopeData)
	if isDrawing then StopDrawing() end
	ClosePanels:Fire("Slope")
	ModeState.Value = "Slope"
	if Dock then Dock.Visible = false end
	print("[SlopeClient] Starting Drawing Routine for " .. tostring(newSlopeName))
	slopeName = newSlopeName
	slopeData = newSlopeData
	local diff = slopeData.Difficulty or 1
	local isGlade = slopeName == "Glade"
	if type(diff) == "string" then
		diff = (diff == "Green" and 1) or (diff == "Blue" and 2) or (diff == "Black" and 3) or (diff == "Double Black" and 4) or (diff == "Triple Black" and 5) or (diff == "Glade" and 2) or 1
	end

	selectedSlope = {
		Name = slopeName,
		Price = slopeData.Price,
		Difficulty = diff,
		DifficultyKey = isGlade and "Glade" or (DIFF_KEYS[diff] or "Green"),
	}
	BuildDefaultDecorOptions(selectedSlope.DifficultyKey)

	isDrawing = true
	slopePoints = {}
	widthData = {}
	slopeSnaps = {}

	if slopeData and (slopeData.IsQueue or slopeData.IsPath) then
		currentWidth = 4
	else
		currentWidth = DIFF_DEF_WIDTH[selectedSlope.DifficultyKey] or DRAW.DEF_W
	end

	if menuGui then
		menuGui:Destroy()
		menuGui = nil
		isMenuOpen = false
	end

	local color = SLOPE_COLORS[diff] or SLOPE_COLORS[1]
	lastPreviewHit = nil
	lastPreviewRenderAt = 0
	lastPreviewRenderHit = nil
	lastPreviewControlCount = 0
	EnsurePreview(color)
	BuildSlopeConnectors()

	local function AddPointFromPreview()
		local hit = lastPreviewHit or RayTerrain()
		if not hit then return end
		AddControlPoint(hit)
	end

	local function ShowSlopeError(msg)
		if costLbl then
			local prev = costLbl.Text
			local prevColor = costLbl.TextColor3
			costLbl.Text = msg
			costLbl.TextColor3 = Color3.fromRGB(255, 80, 80)
			task.delay(2, function()
				if costLbl and costLbl.Text == msg then
					costLbl.Text = prev
					costLbl.TextColor3 = prevColor
				end
			end)
		end
	end

	local function SendSlope()
		if #slopePoints < 2 then
			ShowSlopeError("NEED 2+ POINTS")
			return
		end

		local placementPoints = BuildPlacementPathFromControlPoints(slopePoints)

		if #placementPoints < 2 then
			ShowSlopeError("PATH INVALID")
			warn("[SlopeClient] Slope path invalid")
			return
		end

		if PathLen(placementPoints) < DRAW.MIN_LEN then
			ShowSlopeError("TOO SHORT (MIN " .. DRAW.MIN_LEN .. " STUDS)")
			warn("[SlopeClient] Slope too short")
			return
		end

		local _, actualMax = LiveDifficulty(placementPoints)
		local detectedDiff = "Green"
		if actualMax >= 50 then detectedDiff = "Double Black"
		elseif actualMax >= 35 then detectedDiff = "Black"
		elseif actualMax >= 25 then detectedDiff = "Blue"
		end
		local diffKey = selectedSlope and selectedSlope.DifficultyKey or "Green"
		local maxAllowed = MAX_ANGLE[diffKey] or 90
		if actualMax > maxAllowed then
			diffKey = detectedDiff
			if selectedSlope then
				selectedSlope.DifficultyKey = diffKey
				selectedSlope.Difficulty = (diffKey == "Green" and 1) or (diffKey == "Blue" and 2) or (diffKey == "Black" and 3) or 4
			end
		end

		local mappedWidthData = BuildMappedWidthData(#placementPoints, slopePoints)
		
		local connections = {}
		if slopeSnaps[1] then connections.Start = slopeSnaps[1] end
		if slopeSnaps[#slopePoints] then connections.End = slopeSnaps[#slopePoints] end
		-- If it's a two-point auto path, the second point corresponds to the end
		if #slopePoints == 2 and #placementPoints > 2 and slopeSnaps[2] then connections.End = slopeSnaps[2] end


		PlaceEvent:FireServer(slopeName, {
			ItemName = slopeName,
			Points = placementPoints,
			Difficulty = selectedSlope.DifficultyKey,
			Type = "Slope",
			WidthData = mappedWidthData,
			DecorOptions = {
				markers = decorOptions.markers,
				nets = decorOptions.nets,
				markerLights = decorOptions.markerLights,
			},
			DrawMode = "point",
			AutoPath = (#slopePoints == 2),
			Connections = connections,
		})

		print("[SlopeClient] Slope Payload Sent to Server")
		StopDrawing()
	end

	local function UndoPoint()
		if #slopePoints == 0 then return end
		table.remove(slopePoints)
		table.remove(slopeSnaps)
		for i = #widthData, 1, -1 do
			if widthData[i].index > #slopePoints then
				table.remove(widthData, i)
			end
		end
		print("[SlopeClient] Undid Last Point")
	end

	local UpdateHUD = CreateHUD(slopeName, slopeData, SendSlope, UndoPoint, AddPointFromPreview)
	if not UpdateHUD then
		warn("[SlopeClient] Aborting slope drawing because HUD setup failed.")
		StopDrawing()
		return
	end

	local touchStartPos = nil
	local touchStartTime = 0

	conns.inputBegan = UIS.InputBegan:Connect(function(input, gpe)
		if gpe then return end

		if (input.KeyCode == Enum.KeyCode.Z and not UIS:IsKeyDown(Enum.KeyCode.LeftControl) and not UIS:IsKeyDown(Enum.KeyCode.RightControl))
			or input.KeyCode == Enum.KeyCode.Escape then
			StopDrawing()
			return
		end

		if input.KeyCode == Enum.KeyCode.M then
			decorOptions.markers = not decorOptions.markers
			if not decorOptions.markers then decorOptions.markerLights = false end
			return
		end
		if input.KeyCode == Enum.KeyCode.N then decorOptions.nets = not decorOptions.nets return end
		if input.KeyCode == Enum.KeyCode.L then
			if decorOptions.markers then decorOptions.markerLights = not decorOptions.markerLights end
			return
		end
		if input.KeyCode == Enum.KeyCode.LeftBracket then ChangeWidthBy(-1) return end
		if input.KeyCode == Enum.KeyCode.RightBracket then ChangeWidthBy(1) return end
		if input.KeyCode == Enum.KeyCode.F then SendSlope() return end
		if input.KeyCode == Enum.KeyCode.Z and (UIS:IsKeyDown(Enum.KeyCode.LeftControl) or UIS:IsKeyDown(Enum.KeyCode.RightControl)) then
			UndoPoint()
			return
		end

		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			local guiObjects = PlayerGui:GetGuiObjectsAtPosition(input.Position.X, input.Position.Y)
			for _, obj in ipairs(guiObjects) do
				if obj.Visible and (obj.Active or obj:IsA("GuiButton") or (menuGui and obj:IsDescendantOf(menuGui)) or (hudGui and obj:IsDescendantOf(hudGui))) then
					print("[SlopeClient] InputBegan ignored due to strictly checked UI overlap.")
					return
				end
			end

			touchStartPos = input.Position
			touchStartTime = os.clock()
			if input.UserInputType == Enum.UserInputType.Touch and not UseCenteredTouchAim() then
				mobileTouchPos = Vector2.new(input.Position.X, input.Position.Y)
			end
		end
	end)

	conns.inputEnded = UIS.InputEnded:Connect(function(input, gpe)
		if gpe then return end

		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			if touchStartPos then
				local dist = (Vector2.new(input.Position.X, input.Position.Y) - Vector2.new(touchStartPos.X, touchStartPos.Y)).Magnitude
				local timeElapsed = os.clock() - touchStartTime

				if dist < 15 and timeElapsed < 0.6 then
					local guiObjects = PlayerGui:GetGuiObjectsAtPosition(input.Position.X, input.Position.Y)
					local clickedUI = false
					for _, obj in ipairs(guiObjects) do
						if obj.Visible and (obj.Active or obj:IsA("GuiButton") or (menuGui and obj:IsDescendantOf(menuGui)) or (hudGui and obj:IsDescendantOf(hudGui))) then
							clickedUI = true
							print("[SlopeClient] InputEnded ignored due to strictly checked UI overlap.")
							break
						end
					end

					if not clickedUI then
						if input.UserInputType == Enum.UserInputType.Touch and UseCenteredTouchAim() then
							touchStartPos = nil
							return
						end
					local hit = lastPreviewHit or RayTerrain(input.Position.X, input.Position.Y, true)
					if activeSnap then
						hit = activeSnap.Position
					end
					if AddControlPoint(hit) then
						if activeSnap then table.insert(slopeSnaps, activeSnap)
						else table.insert(slopeSnaps, false) end
							print("[SlopeClient] Placed point successfully via tap/click.")
						end
					end
				else
					print(string.format("[SlopeClient] Input rejected as point target (Drag/Hold detected). Dist: %.2f, Time: %.2f", dist, timeElapsed))
				end
			end
			touchStartPos = nil
		end
	end)

	conns.render = RunService.RenderStepped:Connect(function()
		if not isDrawing then return end
		if not UseCenteredTouchAim() then
			local m = UIS:GetMouseLocation()
			local guiObjects = PlayerGui:GetGuiObjectsAtPosition(m.X, m.Y)
			for _, obj in ipairs(guiObjects) do
				if obj.Visible and ((hudGui and obj:IsDescendantOf(hudGui)) or obj:IsA("GuiButton") or obj.Active) then
					return
				end
			end
		end
		EnsurePreview(color)
		
		-- Connector logic
		local hit = nil
		local aim = GetSlopeAimScreenPosition()
		local ray = Camera:ScreenPointToRay(aim.X, aim.Y)
		local bestScreenDist = UseCenteredTouchAim() and 72 or 44
		local bestWorldDist = 10
		local bestConn = nil
		
		for _, c in ipairs(connectorPoints) do
			local screenPos, onScreen = Camera:WorldToViewportPoint(c.Pos)
			local picked = false
			if onScreen and screenPos.Z > 0 then
				local delta = Vector2.new(screenPos.X, screenPos.Y) - aim
				local screenDist = delta.Magnitude
				if screenDist < bestScreenDist then
					bestScreenDist = screenDist
					bestConn = c
					picked = true
				end
			end
			if not picked and not bestConn then
				local v = c.Pos - ray.Origin
				local d = v:Cross(ray.Direction).Magnitude
				if d < bestWorldDist and v:Dot(ray.Direction) > 0 then
					bestWorldDist = d
					bestConn = c
				end
			end
			c.Part.Color = c.IsNet and Color3.fromRGB(255, 120, 0) or Color3.fromRGB(255, 200, 0)
		end

		activeSnap = nil
		if bestConn then hit = bestConn.Pos; bestConn.Part.Color = Color3.fromRGB(0, 255, 0)
			activeSnap = {UUID = bestConn.Model:GetAttribute("UUID"), Position = bestConn.Pos}
		else hit = RayTerrain(aim.X, aim.Y) end
		
		lastPreviewHit = hit
		local cursor = previewFolder and previewFolder:FindFirstChild("Cursor")
		if cursor and hit then
			cursor.Position = activeSnap and hit or (hit + Vector3.yAxis * 2)
		end

		local activeControls = table.clone(slopePoints)
		if hit then table.insert(activeControls, hit) end

		local now = os.clock()
		local movedEnough = false
		if hit and lastPreviewRenderHit then
			movedEnough = (hit - lastPreviewRenderHit).Magnitude >= 0.75
		elseif hit or lastPreviewRenderHit then
			movedEnough = true
		end
		local shouldRefresh = movedEnough or (#activeControls ~= lastPreviewControlCount) or ((now - lastPreviewRenderAt) >= 0.05)
		if not shouldRefresh then return end

		lastPreviewRenderAt = now
		lastPreviewRenderHit = hit
		lastPreviewControlCount = #activeControls
		RenderPreview(activeControls)
		if UpdateHUD then UpdateHUD(activeControls) end
	end)
end

ClosePanels.Event:Connect(function(source)
	if source == "Slope" then return end
	if isDrawing then StopDrawing() end
	if menuGui then
		menuGui:Destroy()
		menuGui = nil
		isMenuOpen = false
	end
end)

Player.CharacterAdded:Connect(function()
	task.defer(function()
		if isDrawing then
			StopDrawing()
		end
		if menuGui then
			menuGui:Destroy()
			menuGui = nil
		end
		isMenuOpen = false
		lastPreviewHit = nil
		lastPreviewRenderAt = 0
		lastPreviewRenderHit = nil
		lastPreviewControlCount = 0
		activeSnap = nil
		slopeSnaps = {}
		mobileTouchPos = nil
		if ModeState.Value == "Slope" then
			ModeState.Value = ""
		end
		ClearPreview()
	end)
end)

local function OpenMenu()
	if isDrawing then StopDrawing() end
	ClosePanels:Fire("Slope")

	if menuGui then
		menuGui:Destroy()
		menuGui = nil
		isMenuOpen = false
		return
	end

	isMenuOpen = true
	menuGui = Instance.new("ScreenGui")
	menuGui.Name = "SlopeMenu"
	menuGui.ResetOnSpawn = false
	menuGui.IgnoreGuiInset = true
	menuGui.DisplayOrder = 5
	menuGui.Parent = PlayerGui

	local backdrop = Instance.new("TextButton")
	backdrop.Name = "Backdrop"
	backdrop.Size = UDim2.fromScale(1, 1)
	backdrop.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
	backdrop.BackgroundTransparency = 0.35
	backdrop.BorderSizePixel = 0
	backdrop.Text = ""
	backdrop.AutoButtonColor = false
	backdrop.Parent = menuGui

	local main = Instance.new("Frame")
	main.Size = UDim2.new(0, 540, 0, 440)
	main.Position = UDim2.new(0.5, 0, 0.5, 0)
	main.AnchorPoint = Vector2.new(0.5, 0.5)
	main.BackgroundColor3 = Color3.fromRGB(24, 25, 30)
	main.BorderSizePixel = 0
	main.Parent = menuGui
	Round(main, 12)
	local menuStroke = Stroke(main, Color3.fromRGB(0, 0, 0), 1)

	local header = Instance.new("Frame")
	header.Size = UDim2.new(1, 0, 0, 50)
	header.BackgroundTransparency = 1
	header.Parent = main
	local hpad = Instance.new("UIPadding")
	hpad.PaddingLeft = UDim.new(0, 20)
	hpad.PaddingRight = UDim.new(0, 20)
	hpad.Parent = header

	local title = Instance.new("TextLabel")
	title.Text = "SLOPE SELECTION"
	title.Size = UDim2.new(0.6, 0, 1, 0)
	title.BackgroundTransparency = 1
	title.Font = Enum.Font.GothamBlack
	title.TextSize = 20
	title.TextColor3 = Color3.fromRGB(240, 240, 240)
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.Parent = header

	local close = Instance.new("TextButton")
	close.Text = "EXIT"
	close.Size = UDim2.new(0, 60, 0, 30)
	close.Position = UDim2.new(1, -60, 0.5, 0)
	close.AnchorPoint = Vector2.new(0, 0.5)
	close.BackgroundColor3 = Color3.fromRGB(255, 8, 53)
	close.TextColor3 = Color3.new(1, 1, 1)
	close.Font = Enum.Font.GothamBold
	close.TextSize = 11
	close.Parent = header
	Round(close, 6)
	local function closeMenu()
		if menuGui then
			menuGui:Destroy()
			menuGui = nil
		end
		isMenuOpen = false
	end
	bindGuiButton(close, closeMenu)
	bindGuiButton(backdrop, closeMenu)

	local sub = Instance.new("TextLabel")
	sub.Size = UDim2.new(1, -40, 0, 16)
	sub.Position = UDim2.new(0, 20, 0, 48)
	sub.BackgroundTransparency = 1
	sub.Text = "Default: Green/Blue = nets on. Black+ = nets off. Toggle in build HUD (M/N/L)."
	sub.Font = Enum.Font.GothamMedium
	sub.TextSize = 10
	sub.TextColor3 = Color3.fromRGB(150, 150, 155)
	sub.TextXAlignment = Enum.TextXAlignment.Left
	sub.Parent = main

	local div = Instance.new("Frame")
	div.Size = UDim2.new(1, 0, 0, 1)
	div.Position = UDim2.new(0, 0, 0, 68)
	div.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
	div.BorderSizePixel = 0
	div.Parent = main

	local content = Instance.new("ScrollingFrame")
	content.Size = UDim2.new(1, -30, 1, -86)
	content.Position = UDim2.new(0, 15, 0, 76)
	content.BackgroundTransparency = 1
	content.ScrollBarThickness = 4
	content.ScrollBarImageColor3 = Color3.fromRGB(76, 209, 55)
	content.Parent = main

	local grid = Instance.new("UIGridLayout")
	grid.CellSize = UDim2.new(0, 150, 0, 170)
	grid.CellPadding = UDim2.new(0, 10, 0, 10)
	grid.SortOrder = Enum.SortOrder.LayoutOrder
	grid.Parent = content

	local order = 0
	for itemName, itemData in pairs(Config.Items) do
		if itemData.Category == "Slopes" or itemData.Type == "Slope" then
			order += 1
			local diff = itemData.Difficulty or 1
			if type(diff) == "string" then
				diff = (diff == "Green" and 1) or (diff == "Blue" and 2) or (diff == "Black" and 3) or (diff == "Double Black" and 4) or 1
			end

			local color = SLOPE_COLORS[diff] or SLOPE_COLORS[1]
			local diffName = DIFF_NAMES[diff] or "Green Circle"
			local price = GetSlopeMenuPriceText(itemName)

			local btn = Instance.new("TextButton")
			btn.Name = itemName
			btn:SetAttribute("SlopeItemName", itemName)
			btn.Text = ""
			btn.BackgroundColor3 = Color3.fromRGB(17, 19, 24)
			btn.LayoutOrder = diff or order
			btn.Parent = content
			Round(btn, 10)
			local btnStroke = Stroke(btn, Color3.fromRGB(0, 0, 0), 1)

			local bar = Instance.new("Frame")
			bar.Size = UDim2.new(1, 0, 0, 6)
			bar.BackgroundColor3 = color
			bar.BorderSizePixel = 0
			bar.Parent = btn
			Round(bar, 10)

			local iconBg = Instance.new("Frame")
			iconBg.Size = UDim2.new(0, 50, 0, 50)
			iconBg.Position = UDim2.new(0.5, 0, 0.25, 0)
			iconBg.AnchorPoint = Vector2.new(0.5, 0.5)
			iconBg.BackgroundColor3 = color
			iconBg.BackgroundTransparency = 0.8
			iconBg.Parent = btn
			Round(iconBg, 25)

			local iconText = Instance.new("TextLabel")
			iconText.Text = "^"
			iconText.Size = UDim2.new(1, 0, 1, 0)
			iconText.BackgroundTransparency = 1
			iconText.TextSize = 22
			iconText.TextColor3 = Color3.fromRGB(240, 240, 240)
			iconText.Font = Enum.Font.GothamBlack
			iconText.Parent = iconBg

			local nameLbl = Instance.new("TextLabel")
			nameLbl.Text = diffName
			nameLbl.Size = UDim2.new(1, 0, 0, 20)
			nameLbl.Position = UDim2.new(0, 0, 0.55, 0)
			nameLbl.BackgroundTransparency = 1
			nameLbl.TextColor3 = Color3.fromRGB(240, 240, 240)
			nameLbl.Font = Enum.Font.GothamBold
			nameLbl.TextSize = 14
			nameLbl.Parent = btn

			local priceLbl = Instance.new("TextLabel")
			priceLbl.Name = "PriceLabel"
			priceLbl.Text = price
			priceLbl.Size = UDim2.new(1, 0, 0, 20)
			priceLbl.Position = UDim2.new(0, 0, 0.7, 0)
			priceLbl.BackgroundTransparency = 1
			priceLbl.TextColor3 = Color3.fromRGB(76, 209, 55)
			priceLbl.Font = Enum.Font.GothamBlack
			priceLbl.TextSize = 16
			priceLbl.Parent = btn

			btn.MouseEnter:Connect(function()
				TweenService:Create(btnStroke, TweenInfo.new(0.2), {Color = color}):Play()
				TweenService:Create(btn, TweenInfo.new(0.2), {BackgroundColor3 = Color3.fromRGB(50, 50, 55)}):Play()
			end)

			btn.MouseLeave:Connect(function()
				TweenService:Create(btnStroke, TweenInfo.new(0.2), {Color = Color3.fromRGB(0, 0, 0)}):Play()
				TweenService:Create(btn, TweenInfo.new(0.2), {BackgroundColor3 = Color3.fromRGB(17, 19, 24)}):Play()
			end)

			bindGuiButton(btn, function()
				StartDrawing(itemName, itemData)
			end)
		end
	end
	RefreshSlopeMenuPrices()
end

for _, attrName in pairs(Config.DiscountAttributeByBucket or {}) do
	Player:GetAttributeChangedSignal(attrName):Connect(function()
		RefreshSlopeMenuPrices()
	end)
end

UIS.InputBegan:Connect(function(input, gpe)
	if gpe then return end
	if input.KeyCode == Enum.KeyCode.Escape then
		if isDrawing then
			StopDrawing()
		elseif menuGui then
			menuGui:Destroy()
			menuGui = nil
			isMenuOpen = false
		end
	end
end)

task.spawn(function()
	local bridge = Events:WaitForChild("StartSlopePlacement", 2)
	if not bridge then
		bridge = Instance.new("BindableEvent")
		bridge.Name = "StartSlopePlacement"
		bridge.Parent = Events
	end
	bridge.Event:Connect(function(name, data)
		StartDrawing(name, data)
	end)
end)

print("[SlopeClient] V15 loaded.")