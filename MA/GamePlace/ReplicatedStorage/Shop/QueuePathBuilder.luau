--[=[ PATH: ReplicatedStorage/Shop/QueuePathBuilder | TYPE: ModuleScript ]=]--
local QueuePathBuilder = {}

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")
local SlopeMath = require(script.Parent.SlopeMath)

local PREVIEW_COLOR = Color3.fromRGB(80, 180, 255)
local FENCE_COLOR = Color3.fromRGB(160, 160, 160)
local FENCE_HEIGHT = 3.5
local POST_INTERVAL = 8

local isDrawing = false
local points = {}
local width = 5
local previewFolder = nil
local connections = {}

local function raycastTerrain()
	local mouse = Players.LocalPlayer:GetMouse()
	local camera = Workspace.CurrentCamera
	local ray = camera:ScreenPointToRay(mouse.X, mouse.Y)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = { Workspace.Terrain }
	local result = Workspace:Raycast(ray.Origin, ray.Direction * 2000, params)
	return result and result.Position or nil
end

local function clearPreview()
	if previewFolder then previewFolder:Destroy() end
	previewFolder = Instance.new("Folder")
	previewFolder.Name = "QueuePreview"
	previewFolder.Parent = Workspace
end

local function createPost(pos, parent)
	local p = Instance.new("Part")
	p.Size = Vector3.new(0.4, FENCE_HEIGHT, 0.4)
	p.CFrame = CFrame.new(pos + Vector3.new(0, FENCE_HEIGHT/2, 0))
	p.Anchored = true
	p.CanCollide = false
	p.Material = Enum.Material.Metal
	p.Color = FENCE_COLOR
	p.Parent = parent
	return p
end

local function renderPreview()
	clearPreview()
	if #points < 1 then return end
	
	-- Visual anchor for start point
	local anchor = Instance.new("Part")
	anchor.Size = Vector3.new(1.2, 1.2, 1.2)
	anchor.Shape = Enum.PartType.Ball
	anchor.Color = Color3.fromRGB(85, 255, 127)
	anchor.Material = Enum.Material.Neon
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CastShadow = false
	anchor.Position = points[1]
	anchor.Parent = previewFolder
	
	local path = points
	if #points >= 2 then
		path = SlopeMath.generateAutoPath(points[1], points[#points], Workspace.Terrain, "Green")
		if #points > 2 then
			path = SlopeMath.generatePath(points, Workspace.Terrain)
		end
	end
	
	local halfW = width / 2
	
	-- Draw surface
	for i = 1, #path - 1 do
		local p1 = path[i]
		local p2 = path[i+1]
		local dir = (p2 - p1)
		local dist = dir.Magnitude
		if dist > 0.1 then
			local cframe = CFrame.lookAt((p1 + p2)/2, p2)
			local floor = Instance.new("Part")
			floor.Size = Vector3.new(width, 0.2, dist)
			floor.CFrame = cframe
			floor.Anchored = true
			floor.CanCollide = false
			floor.Color = PREVIEW_COLOR
			floor.Transparency = 0.5
			floor.Material = Enum.Material.Neon
			floor.Parent = previewFolder
		end
	end
	
	-- Draw Fences
	local distCounter = 0
	
	for i = 1, #path - 1 do
		local p1 = path[i]
		local p2 = path[i+1]
		local dir = (p2 - p1).Unit
		local right = dir:Cross(Vector3.yAxis).Unit
		local dist = (p2 - p1).Magnitude
		
		local left1 = p1 - (right * halfW)
		local left2 = p2 - (right * halfW)
		local right1 = p1 + (right * halfW)
		local right2 = p2 + (right * halfW)
		
		-- Rails
		local railSize = Vector3.new(0.2, 0.2, dist)
		local railY = Vector3.new(0, 3, 0)
		
		local railL = Instance.new("Part")
		railL.Size = railSize
		railL.CFrame = CFrame.lookAt((left1 + left2)/2 + railY, left2 + railY)
		railL.Anchored, railL.CanCollide, railL.Color = true, false, FENCE_COLOR
		railL.Parent = previewFolder

		local railR = railL:Clone()
		railR.CFrame = CFrame.lookAt((right1 + right2)/2 + railY, right2 + railY)
		railR.Parent = previewFolder
	end
end

function QueuePathBuilder.Start(startPos, fixedWidth, onFinish)
	if isDrawing then QueuePathBuilder.Stop() end
	isDrawing = true
	points = { startPos }
	width = fixedWidth
	
	connections.Render = RunService.RenderStepped:Connect(function()
		local hit = raycastTerrain()
		if hit then
			if #points > 1 then points[#points] = hit else table.insert(points, hit) end
			renderPreview()
		end
	end)
	
	connections.Input = UserInputService.InputBegan:Connect(function(input, gp)
		if gp then return end
		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			local hit = raycastTerrain()
			if hit then
				points[#points] = hit 
				table.insert(points, hit)
			end
		elseif input.KeyCode == Enum.KeyCode.Return or input.KeyCode == Enum.KeyCode.F then
			if #points >= 2 then
				if (points[#points] - points[#points-1]).Magnitude < 1 then table.remove(points, #points) end
				if #points >= 2 then
					local finalPath = SlopeMath.generatePath(points, Workspace.Terrain)
					onFinish(finalPath)
				end
			end
			QueuePathBuilder.Stop()
		elseif input.KeyCode == Enum.KeyCode.Z then
			QueuePathBuilder.Stop()
		end
	end)
end

function QueuePathBuilder.Stop()
	isDrawing = false
	for _, conn in pairs(connections) do conn:Disconnect() end
	connections = {}
	if previewFolder then previewFolder:Destroy() end
end

return QueuePathBuilder