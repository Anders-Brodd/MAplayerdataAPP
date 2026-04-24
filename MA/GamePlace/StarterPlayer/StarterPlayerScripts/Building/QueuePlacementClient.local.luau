--[=[ PATH: StarterPlayerScripts/QueuePlacementClient | TYPE: LocalScript ]=]--
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")

local Player = Players.LocalPlayer
local PlayerGui = Player:WaitForChild("PlayerGui")
local Events = ReplicatedStorage:WaitForChild("Events")

local Config = require(ReplicatedStorage:WaitForChild("Config"))
local QueueSystem = require(ReplicatedStorage:WaitForChild("QueueSystem"))
local QueuePathBuilder = require(ReplicatedStorage:WaitForChild("Shop"):WaitForChild("QueuePathBuilder"))

local StartQueueEvent = Events:WaitForChild("StartQueuePlacement")
local PlaceQueueRemote = Events:WaitForChild("PlaceQueue")

local highlight = Instance.new("Highlight")
highlight.FillColor = Color3.fromRGB(85, 255, 127)
highlight.OutlineColor = Color3.fromRGB(255, 255, 255)
highlight.FillTransparency = 0.5
highlight.OutlineTransparency = 0
highlight.Parent = PlayerGui

local isSelecting = false
local hoverTarget = nil

local function getMouseTarget()
	local mouse = Player:GetMouse()
	local target = mouse.Target
	if target then
		local model = target:FindFirstAncestorOfClass("Model")
		if model then
			if QueueSystem.GetQueueAttachment(model) then return model end
			local item = Config.Items[model.Name]
			if item and (item.Category == "Lifts" or item.Category == "Buildings" or item.Type == "TwoPoint" or item.Type == "Carpet") then
				return model
			end
		end
	end
	return nil
end

local function startDrawing(targetModel)
	isSelecting = false
	highlight.Adornee = nil
	
	local startPos = QueueSystem.GetQueueStartPosition(targetModel) or targetModel:GetPivot().Position
	
	local itemConfig = Config.Items[targetModel.Name]
	local capacity = 1
	if itemConfig then
		capacity = itemConfig.Capacity or 1
		if itemConfig.Type == "TwoPoint" or itemConfig.Type == "Carpet" then
			capacity = itemConfig.Capacity or 2
		end
	end
	
	local width = QueueSystem.GetQueueWidth(capacity)
	
	QueuePathBuilder.Start(startPos, width, function(pathPoints)
		PlaceQueueRemote:FireServer({
			TargetUUID = targetModel:GetAttribute("UUID"),
			Path = pathPoints,
			Width = width
		})
	end)
end

StartQueueEvent.Event:Connect(function()
	isSelecting = true
end)

UserInputService.InputBegan:Connect(function(input, gp)
	if gp then return end
	
	if isSelecting then
		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			if hoverTarget then
				startDrawing(hoverTarget)
			end
		elseif input.KeyCode == Enum.KeyCode.Z or input.KeyCode == Enum.KeyCode.Escape then
			isSelecting = false
			highlight.Adornee = nil
		end
	end
end)

RunService.RenderStepped:Connect(function()
	if isSelecting then
		hoverTarget = getMouseTarget()
		highlight.Adornee = hoverTarget
	end
end)