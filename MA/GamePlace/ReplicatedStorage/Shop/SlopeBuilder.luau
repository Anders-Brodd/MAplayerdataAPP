--[=[ PATH: ReplicatedStorage/Shop/SlopeBuilder | TYPE: ModuleScript ]=]--

--[[
	SLOPE BUILDER V11

	- Drag mode: hold and draw
	- Point mode: place pivots and finish with F
	- Variable width via scroll
	- Terrain-only raycasts
	- 2-point pivot mode auto-generates a run
]]

local SlopeBuilder = {}

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local ContextActionService = game:GetService("ContextActionService")
local Workspace = game:GetService("Workspace")

local SlopeMath = nil
local slopeMathModule = script.Parent and script.Parent:FindFirstChild("SlopeMath")
if slopeMathModule and slopeMathModule:IsA("ModuleScript") then
	local ok, loaded = pcall(require, slopeMathModule)
	if ok then
		SlopeMath = loaded
	end
end

local CONFIG = {
	SAMPLE_DISTANCE = 6,
	MIN_LENGTH = 15,
	QUEUE_SPACING = 6.5, -- Matches GuestServer config (Comfortable spacing)
	PREVIEW_UPDATE = 0.03,

	DEFAULT_WIDTH = 90,
	-- Keep build-time width bounds aligned with shared/server slope validation.
	MIN_WIDTH = 30,
	MAX_WIDTH = 160,
	WIDTH_STEP = 5,   -- finer steps at low widths

	COLORS = {
		Green = Color3.fromRGB(76, 209, 55),
		Blue = Color3.fromRGB(52, 152, 219),
		Black = Color3.fromRGB(44, 62, 80),
		["Double Black"] = Color3.fromRGB(255, 215, 0),
		Edge = Color3.fromRGB(255, 255, 255),
		WidthMarker = Color3.fromRGB(255, 165, 0),
	},
}

local isDrawing = false
local isDragging = false
local drawMode = "drag"
local widthLocked = false
local pathPoints = {}
local widthData = {}
local currentWidth = CONFIG.DEFAULT_WIDTH
local previewFolder = nil
local connections = {}
local wheelBlockBound = false
local WHEEL_BLOCK_ACTION = "SlopeBuilder_BlockMouseWheelZoom"
local livePreviewFolder = nil

local function raycastTerrain(screenPos)
	local player = Players.LocalPlayer
	local mouse = player:GetMouse()
	local camera = Workspace.CurrentCamera
	if not camera then return nil end

	local x, y
	if screenPos then
		x, y = screenPos.X, screenPos.Y
	else
		x, y = mouse.X, mouse.Y
	end
	local ray = camera:ScreenPointToRay(x, y)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = { Workspace.Terrain }
	params.IgnoreWater = true

	local result = Workspace:Raycast(ray.Origin, ray.Direction * 10000, params)
	return result and result.Position or nil
end

local function getDifficulty(points)
	if #points < 2 then return "Green" end
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

	if maxAngle < 12 then return "Green" end
	if maxAngle < 25 then return "Blue" end
	if maxAngle < 40 then return "Black" end
	return "Double Black"
end

local function getPathLength(points)
	if #points < 2 then return 0 end
	local total = 0
	for i = 1, #points - 1 do
		total = total + (points[i + 1] - points[i]).Magnitude
	end
	return total
end

local function clearPreview()
	if previewFolder then
		previewFolder:Destroy()
		previewFolder = nil
	end
	if livePreviewFolder then livePreviewFolder:Destroy() livePreviewFolder = nil end
end

local function getWidthAt(idx, source)
	source = source or widthData
	if #source == 0 then return currentWidth end
	if #source == 1 then return source[1].width end

	local prev, nxt
	for _, wd in ipairs(source) do
		if wd.index <= idx then prev = wd end
		if wd.index >= idx and not nxt then nxt = wd end
	end

	if not prev then return source[1].width end
	if not nxt then return source[#source].width end
	if prev.index == nxt.index then return prev.width end

	local t = (idx - prev.index) / (nxt.index - prev.index)
	t = t * t * (3 - 2 * t)
	return prev.width + (nxt.width - prev.width) * t
end

local function getPlacementPath()
	if drawMode ~= "point" or #pathPoints ~= 2 or not SlopeMath or type(SlopeMath.generateAutoPath) ~= "function" then
		return pathPoints, false
	end
	local difficulty = getDifficulty(pathPoints)
	local ok, generated = pcall(function()
		return SlopeMath.generateAutoPath(pathPoints[1], pathPoints[2], Workspace.Terrain, difficulty)
	end)
	if not ok or type(generated) ~= "table" or #generated < 2 then
		return pathPoints, false
	end
	return generated, true
end

local function mapControlIndex(controlIndex, controlCount, pathCount)
	controlIndex = math.clamp(math.floor(controlIndex or 1), 1, math.max(1, controlCount))
	if controlCount <= 1 then
		return 1
	end
	local t = (controlIndex - 1) / (controlCount - 1)
	return math.clamp(math.floor(t * math.max(1, pathCount - 1) + 1), 1, math.max(1, pathCount))
end

local function buildMappedWidthData(pathCount)
	local mapped = {}
	pathCount = math.max(1, pathCount or #pathPoints)

	if #widthData == 0 then
		return {
			{ index = 1, width = currentWidth },
			{ index = pathCount, width = currentWidth },
		}
	end

	for _, wd in ipairs(widthData) do
		local srcIndex = tonumber(wd.index or 1) or 1
		local width = math.clamp(tonumber(wd.width or currentWidth) or currentWidth, CONFIG.MIN_WIDTH, CONFIG.MAX_WIDTH)
		local mappedIndex = mapControlIndex(srcIndex, #pathPoints, pathCount)
		table.insert(mapped, { index = mappedIndex, width = width })
	end

	table.sort(mapped, function(a, b)
		return a.index < b.index
	end)

	local deduped = {}
	for _, wd in ipairs(mapped) do
		if deduped[#deduped] and deduped[#deduped].index == wd.index then
			deduped[#deduped].width = wd.width
		else
			table.insert(deduped, wd)
		end
	end

	local function ensureBoundary(index)
		for _, wd in ipairs(deduped) do
			if wd.index == index then
				return
			end
		end
		table.insert(deduped, { index = index, width = currentWidth })
	end
	ensureBoundary(1)
	ensureBoundary(pathCount)
	table.sort(deduped, function(a, b)
		return a.index < b.index
	end)

	return deduped
end

local function generateMesh(points, folder, isLive)
	local renderPoints = points
	local showControlPoints = points
	if drawMode == "point" and points == pathPoints then
		-- For live preview, don't auto-path, just straight line
		if not isLive then
			renderPoints = getPlacementPath()
		end
	end
	if #renderPoints < 2 then return end

	local widthSource = widthData
	if points == pathPoints then
		-- For live preview, assume constant width
		if isLive then
			widthSource = {{index=1, width=currentWidth}, {index=#renderPoints, width=currentWidth}}
		else
			widthSource = buildMappedWidthData(#renderPoints)
		end
	end

	local difficulty = getDifficulty(renderPoints)
	local color = CONFIG.COLORS[difficulty] or CONFIG.COLORS.Green

	for i = 1, #renderPoints - 1 do
		local p1 = renderPoints[i]
		local p2 = renderPoints[i + 1]
		local dist = (p2 - p1).Magnitude
		if dist < 0.5 then continue end
		local mid = (p1 + p2) / 2
		local dir = (p2 - p1).Unit

		local line = Instance.new("Part")
		line.Name = "CenterLine"
		line.Anchored = true
		line.CanCollide = false
		line.CastShadow = false
		line.Material = Enum.Material.Neon
		line.Color = color
		line.Size = Vector3.new(2, 0.5, dist)
		line.CFrame = CFrame.lookAt(mid + Vector3.new(0, 0.5, 0), mid + Vector3.new(0, 0.5, 0) + dir)
		line.Transparency = 0.3
		line.Parent = folder
	end

	for i = 1, #renderPoints - 1, 3 do
		local p1 = renderPoints[i]
		local p2 = renderPoints[math.min(i + 2, #renderPoints)]
		local dist = (p2 - p1).Magnitude
		if dist < 2 then continue end

		local mid = (p1 + p2) / 2
		local dir = (p2 - p1).Unit
		local right = dir:Cross(Vector3.yAxis)
		if right.Magnitude < 0.1 then continue end
		right = right.Unit

		local w = getWidthAt(i, widthSource) / 2
		
		for _, side in ipairs({ -1, 1 }) do
			local edgePos = mid + (right * w * side)
			local edge = Instance.new("Part")
			edge.Name = "Edge"
			edge.Anchored = true
			edge.CanCollide = false
			edge.CastShadow = false
			edge.Material = Enum.Material.Neon
			edge.Color = CONFIG.COLORS.Edge
			edge.Size = Vector3.new(0.5, 0.3, dist)
			edge.CFrame = CFrame.lookAt(edgePos + Vector3.new(0, 0.3, 0), edgePos + Vector3.new(0, 0.3, 0) + dir)
			edge.Transparency = 0.5
			edge.Parent = folder
		end
	end

	for _, wd in ipairs(widthSource) do
		local idx = math.clamp(wd.index, 1, #renderPoints)
		local pos = renderPoints[idx]
		if pos then
			local marker = Instance.new("Part")
			marker.Name = "WidthMarker"
			marker.Shape = Enum.PartType.Cylinder
			marker.Anchored = true
			marker.CanCollide = false
			marker.Material = Enum.Material.Neon
			marker.Color = CONFIG.COLORS.WidthMarker
			marker.Size = Vector3.new(0.25, wd.width, 0.25)
			marker.CFrame = CFrame.new(pos + Vector3.new(0, 1, 0)) * CFrame.Angles(0, 0, math.rad(90))
			marker.Transparency = 0.45
			marker.Parent = folder
		end
	end

	local function endpoint(pos, col)
		local p = Instance.new("Part")
		p.Shape = Enum.PartType.Ball
		p.Anchored = true
		p.CanCollide = false
		p.Material = Enum.Material.Neon
		p.Color = col
		p.Size = Vector3.new(4, 4, 4)
		p.Position = pos + Vector3.new(0, 2, 0)
		p.Transparency = 0.3
		p.Parent = folder
	end
	
	-- CAPACITY ESTIMATOR
	local totalLen = getPathLength(renderPoints)
	local capacity = math.floor(totalLen / CONFIG.QUEUE_SPACING)
	
	local capLabel = folder:FindFirstChild("CapacityLabel")
	if not capLabel then
		local part = Instance.new("Part")
		part.Name = "CapacityLabel"
		part.Transparency = 1
		part.Anchored = true
		part.CanCollide = false
		part.Size = Vector3.new(1,1,1)
		part.Parent = folder
		local gui = Instance.new("BillboardGui", part)
		gui.Size = UDim2.fromOffset(200, 50)
		gui.AlwaysOnTop = true
		local txt = Instance.new("TextLabel", gui)
		txt.Size = UDim2.fromScale(1,1)
		txt.BackgroundTransparency = 1
		txt.TextStrokeTransparency = 0
		txt.TextColor3 = Color3.new(1,1,1)
		txt.Font = Enum.Font.GothamBlack
		txt.TextSize = 20
		capLabel = part
	end
	
	capLabel.Position = renderPoints[#renderPoints] + Vector3.new(0, 5, 0)
	local gui = capLabel:FindFirstChildWhichIsA("BillboardGui")
	if gui then
		gui.Adornee = capLabel
		local txt = gui:FindFirstChildWhichIsA("TextLabel")
		if txt and widthLocked then
			txt.Text = "Capacity: ~" .. capacity .. " guests"
		end
	end

	endpoint(renderPoints[1], Color3.fromRGB(0, 255, 0))
	endpoint(renderPoints[#renderPoints], Color3.fromRGB(255, 0, 0))

	if drawMode == "point" then
		for idx, pt in ipairs(showControlPoints) do
			local wp = Instance.new("Part")
			wp.Name = "Waypoint_" .. idx
			wp.Shape = Enum.PartType.Ball
			wp.Anchored = true
			wp.CanCollide = false
			wp.Material = Enum.Material.Neon
			wp.Color = color
			wp.Size = Vector3.new(3, 3, 3)
			wp.Position = pt + Vector3.new(0, 2, 0)
			wp.Transparency = 0.5
			wp.Parent = folder
		end
	end
end

local function renderPreview(points, parentOverride)
	clearPreview()
	if #points < 2 then return end
	previewFolder = Instance.new("Folder")
	previewFolder.Name = "SlopePreview"
	previewFolder.Parent = parentOverride or Workspace
	generateMesh(points, previewFolder, false)
end

local function stopAllConnections()
	for _, conn in pairs(connections) do
		if conn then conn:Disconnect() end
	end
	connections = {}
end

local function setWheelZoomBlocked(blocked)
	if blocked and not wheelBlockBound then
		ContextActionService:BindActionAtPriority(
			WHEEL_BLOCK_ACTION,
			function(_, _, input)
				if isDrawing and input and input.UserInputType == Enum.UserInputType.MouseWheel then
					return Enum.ContextActionResult.Sink
				end
				return Enum.ContextActionResult.Pass
			end,
			false,
			Enum.ContextActionPriority.High.Value + 100,
			Enum.UserInputType.MouseWheel
		)
		wheelBlockBound = true
	elseif (not blocked) and wheelBlockBound then
		ContextActionService:UnbindAction(WHEEL_BLOCK_ACTION)
		wheelBlockBound = false
	end
end

local function finishPath(onComplete)
	if #pathPoints >= 2 then
		local placementPoints = pathPoints
		if drawMode == "point" then
			placementPoints = getPlacementPath()
		end
		local totalLength = getPathLength(placementPoints)
		if totalLength >= CONFIG.MIN_LENGTH then
			local difficulty = getDifficulty(placementPoints)
			local mappedWidths = buildMappedWidthData(#placementPoints)
			if onComplete then
				onComplete(placementPoints, difficulty, mappedWidths)
			end
		end
	end

	clearPreview()
	pathPoints = {}
	widthData = {}
	isDragging = false
end

local function startDragMode(onComplete, fixedStart, overrideWidth)
	local lastSamplePos = nil
	local lastUpdateTime = 0

	connections.inputBegan = UserInputService.InputBegan:Connect(function(input, processed)
		if processed then return end
		if input.UserInputType ~= Enum.UserInputType.MouseButton1 then return end

		local hitPos = raycastTerrain()
		if hitPos then
			isDragging = true
			if fixedStart then
				pathPoints = { fixedStart, hitPos }
				widthData = { { index = 1, width = currentWidth }, { index = 2, width = currentWidth } }
			else
				pathPoints = { hitPos }
				widthData = { { index = 1, width = currentWidth } }
			end
			lastSamplePos = hitPos
		end
	end)

	connections.inputEnded = UserInputService.InputEnded:Connect(function(input)
		if input.UserInputType ~= Enum.UserInputType.MouseButton1 then return end
		if not isDragging then return end
		finishPath(onComplete)
	end)

	connections.widthScroll = UserInputService.InputChanged:Connect(function(input)
		if widthLocked then return end
		if input.UserInputType == Enum.UserInputType.MouseWheel and isDragging then
			currentWidth = math.clamp(currentWidth + input.Position.Z * CONFIG.WIDTH_STEP, CONFIG.MIN_WIDTH, CONFIG.MAX_WIDTH)
			if #pathPoints > 0 then
				if #widthData == 0 then
					for i = 1, #pathPoints do
						table.insert(widthData, { index = i, width = currentWidth })
					end
				else
					for _, wd in ipairs(widthData) do
						wd.width = currentWidth
					end
					for i = #widthData + 1, #pathPoints do
						table.insert(widthData, { index = i, width = currentWidth })
					end
				end
			end
		end
	end)

	connections.update = RunService.RenderStepped:Connect(function()
		if not isDrawing or not isDragging then return end
		local now = tick()
		if now - lastUpdateTime < CONFIG.PREVIEW_UPDATE then return end
		lastUpdateTime = now

		local hitPos = raycastTerrain()
		if not hitPos then return end
		if lastSamplePos and (hitPos - lastSamplePos).Magnitude >= CONFIG.SAMPLE_DISTANCE then
			table.insert(pathPoints, hitPos)
			lastSamplePos = hitPos
		end

		if #pathPoints >= 2 then
			renderPreview(pathPoints)
		end
	end)
end

local function startPointMode(onComplete)
	local tapStartInfo = nil -- For mobile tap vs. drag detection

	connections.inputBegan = UserInputService.InputBegan:Connect(function(input, processed)
		if processed then return end

		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			if UserInputService.TouchEnabled then
				tapStartInfo = { Position = input.Position, Time = tick() }
			else
				local hitPos = raycastTerrain()
				if not hitPos then return end
				table.insert(pathPoints, hitPos)
				table.insert(widthData, { index = #pathPoints, width = currentWidth })
				if #pathPoints >= 2 then renderPreview(pathPoints) end
			end
		elseif input.UserInputType == Enum.UserInputType.MouseButton2 or input.KeyCode == Enum.KeyCode.Z then
			if #pathPoints > 0 then
				table.remove(pathPoints)
				for i = #widthData, 1, -1 do
					if widthData[i].index > #pathPoints then
						table.remove(widthData, i)
					end
				end
				if #pathPoints >= 2 then
					renderPreview(pathPoints)
				else
					clearPreview()
					previewFolder = Instance.new("Folder")
					previewFolder.Name = "SlopePreview"
					previewFolder.Parent = Workspace
				end
			end
		end

		if input.KeyCode == Enum.KeyCode.F then
			finishPath(onComplete)
		end
	end)

	connections.inputEnded = UserInputService.InputEnded:Connect(function(input, processed)
		if processed or not isDrawing or drawMode ~= "point" then return end

		if input.UserInputType == Enum.UserInputType.MouseButton1 and tapStartInfo then
			local MAX_TAP_DURATION = 0.3
			local MAX_TAP_MOVEMENT = 20 -- screen pixels

			local duration = tick() - tapStartInfo.Time
			local movement = (input.Position - tapStartInfo.Position).Magnitude

			if duration < MAX_TAP_DURATION and movement < MAX_TAP_MOVEMENT then
				-- This is a tap. Place the point.
				-- Use the START position of the tap for the raycast.
				local hitPos = raycastTerrain(tapStartInfo.Position)
				if not hitPos then return end
				table.insert(pathPoints, hitPos)
				table.insert(widthData, { index = #pathPoints, width = currentWidth })
				if #pathPoints >= 2 then renderPreview(pathPoints) end
			end

			tapStartInfo = nil -- Reset for next tap
		end
	end)

	connections.widthScroll = UserInputService.InputChanged:Connect(function(input)
		if widthLocked then return end -- Disable scrolling if width is locked
		if input.UserInputType == Enum.UserInputType.MouseWheel then
			currentWidth = math.clamp(currentWidth + input.Position.Z * CONFIG.WIDTH_STEP, CONFIG.MIN_WIDTH, CONFIG.MAX_WIDTH)
			if #pathPoints > 0 then
				if #widthData == 0 then
					for i = 1, #pathPoints do
						table.insert(widthData, { index = i, width = currentWidth })
					end
				else
					for _, wd in ipairs(widthData) do
						wd.width = currentWidth
					end
					for i = #widthData + 1, #pathPoints do
						table.insert(widthData, { index = i, width = currentWidth })
					end
				end
			end
			if #pathPoints >= 2 then renderPreview(pathPoints) end
		end
	end)

	connections.update = RunService.RenderStepped:Connect(function()
		if not isDrawing or #pathPoints == 0 then return end
		local hitPos = raycastTerrain()
		if not hitPos then return end

		if previewFolder then
			if livePreviewFolder then livePreviewFolder:Destroy() end
			livePreviewFolder = Instance.new("Folder")
			livePreviewFolder.Name = "LivePreview"
			livePreviewFolder.Parent = Workspace
			
			local cursor = previewFolder:FindFirstChild("LiveCursor")
			if not cursor then
				cursor = Instance.new("Part")
				cursor.Name = "LiveCursor"
				cursor.Shape = Enum.PartType.Ball
				cursor.Anchored = true
				cursor.CanCollide = false
				cursor.Material = Enum.Material.Neon
				cursor.Color = Color3.fromRGB(255, 255, 0)
				cursor.Size = Vector3.new(3, 3, 3)
				cursor.Transparency = 0.4
				cursor.Parent = previewFolder
			end
			cursor.Position = hitPos + Vector3.new(0, 2, 0)

			local liveLine = previewFolder:FindFirstChild("LiveLine")
			local lastPt = pathPoints[#pathPoints]
			
			if lastPt then
				local dist = (hitPos - lastPt).Magnitude
				if dist > 2 then
					-- Generate full mesh for live segment
					local tempPoints = {lastPt, hitPos}
					generateMesh(tempPoints, livePreviewFolder, true)
				end
			end

			local widthCircle = previewFolder:FindFirstChild("WidthCircle")
			if not widthCircle then
				widthCircle = Instance.new("Part")
				widthCircle.Name = "WidthCircle"
				widthCircle.Shape = Enum.PartType.Cylinder
				widthCircle.Anchored = true
				widthCircle.CanCollide = false
				widthCircle.Material = Enum.Material.Neon
				widthCircle.Color = CONFIG.COLORS.WidthMarker
				widthCircle.Transparency = 0.7
				widthCircle.Parent = previewFolder
			end
			widthCircle.Size = Vector3.new(0.2, currentWidth, 0.2)
			widthCircle.CFrame = CFrame.new(hitPos + Vector3.new(0, 0.5, 0)) * CFrame.Angles(0, 0, math.rad(90))
		end
	end)
end

function SlopeBuilder.startDrawing(onComplete, mode, options)
	-- Capture attributes BEFORE reset
	options = options or {}
	local overrideWidth = options.width
	local fixedStart = options.fixedStart
	widthLocked = options.widthLocked == true

	if isDrawing then SlopeBuilder.stopDrawing() end

	drawMode = mode == "point" and "point" or "drag"
	isDrawing = true
	isDragging = false
	setWheelZoomBlocked(true)
	pathPoints = {}
	widthData = {}
	
	currentWidth = overrideWidth or CONFIG.DEFAULT_WIDTH

	if drawMode == "drag" then
		startDragMode(onComplete, fixedStart, overrideWidth)
	else
		previewFolder = Instance.new("Folder")
		previewFolder.Name = "SlopePreview"
		previewFolder.Parent = Workspace
		startPointMode(onComplete)
		-- Force initial preview update so the line from the lift appears immediately
		if fixedStart then
			local cursor = Instance.new("Part")
			cursor.Anchored = true
			cursor.CanCollide = false
			cursor.Transparency = 1
			cursor.Parent = previewFolder
			-- Trigger render manually
			task.delay(0.05, function()
				local mousePos = raycastTerrain()
				if mousePos then
					local tempPoints = {fixedStart, mousePos}
					generateMesh(tempPoints, previewFolder, true)
				end
			end)
		end
	end
end

function SlopeBuilder.stopDrawing()
	isDrawing = false
	isDragging = false
	pathPoints = {}
	widthData = {}
	widthLocked = false
	Players.LocalPlayer:SetAttribute("QueueOverrideWidth", nil) -- Cleanup
	Players.LocalPlayer:SetAttribute("QueueFixedStartPoint", nil)
	setWheelZoomBlocked(false)
	stopAllConnections()
	clearPreview()
end

function SlopeBuilder.setMode(mode)
	drawMode = mode == "point" and "point" or "drag"
end

function SlopeBuilder.getMode()
	return drawMode
end

function SlopeBuilder.setWidth(width)
	currentWidth = math.clamp(width, CONFIG.MIN_WIDTH, CONFIG.MAX_WIDTH)
end

function SlopeBuilder.getWidth()
	return currentWidth
end

function SlopeBuilder.isDrawing()
	return isDrawing
end

function SlopeBuilder.isActive()
	return isDrawing
end

function SlopeBuilder.clear()
	clearPreview()
end

function SlopeBuilder.getDifficultyColor(difficulty)
	return CONFIG.COLORS[difficulty] or CONFIG.COLORS.Green
end

function SlopeBuilder.render(points, difficulty, parent)
	pathPoints = points or {}
	renderPreview(pathPoints, parent)
	return previewFolder
end

SlopeBuilder.Render = SlopeBuilder.render

return SlopeBuilder
