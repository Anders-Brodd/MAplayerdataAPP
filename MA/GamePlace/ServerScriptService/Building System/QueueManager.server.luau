--[=[ PATH: ServerScriptService/Building System/QueueManager | TYPE: Script ]=]--
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Events = ReplicatedStorage:WaitForChild("Events")
local PlaceQueueRemote = Instance.new("RemoteEvent")
PlaceQueueRemote.Name = "PlaceQueue"
PlaceQueueRemote.Parent = Events

local StartQueuePlacement = Instance.new("BindableEvent")
StartQueuePlacement.Name = "StartQueuePlacement"
StartQueuePlacement.Parent = Events

PlaceQueueRemote.OnServerEvent:Connect(function(player, data)
	if not data or not data.TargetUUID or not data.Path then return end
	
	local placedObjects = workspace:FindFirstChild("PlacedObjects")
	if not placedObjects then return end
	local targetModel
	for _, obj in ipairs(placedObjects:GetDescendants()) do
		if obj:IsA("Model") and obj:GetAttribute("UUID") == data.TargetUUID then
			targetModel = obj
			break
		end
	end
	
	if not targetModel then return end
	if targetModel:GetAttribute("Owner") ~= player.UserId then return end
	
	local slopeData = {
		Points = data.Path,
		WidthData = {{index = 1, width = data.Width}, {index = #data.Path, width = data.Width}},
		Difficulty = "Green",
		ItemName = "Queue Path",
		DecorOptions = {
			nets = true,
			markers = false,
			markerLights = false
		},
		TargetUUID = data.TargetUUID,
		IsQueue = true,
		Presmoothed = true
	}
	
	if _G.PlaceSlope then
		_G.PlaceSlope(player, slopeData)
	else
	end
end)