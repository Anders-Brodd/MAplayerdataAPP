local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage:WaitForChild("Config"))
local CustomBuildingConfig = require(ReplicatedStorage:WaitForChild("CustomBuildingConfig"))

local CUSTOM_BUILDING_ENABLED = false

local Events = ReplicatedStorage:WaitForChild("Events")
local CustomBuildRequest = Events:FindFirstChild("CustomBuildRequest")
if CustomBuildRequest and not CustomBuildRequest:IsA("RemoteFunction") then
	CustomBuildRequest:Destroy()
	CustomBuildRequest = nil
end
if not CustomBuildRequest then
	CustomBuildRequest = Instance.new("RemoteFunction")
	CustomBuildRequest.Name = "CustomBuildRequest"
	CustomBuildRequest.Parent = Events
end

local RequestBuildingSave = Events:FindFirstChild("RequestBuildingSave")
if RequestBuildingSave and not RequestBuildingSave:IsA("BindableEvent") then
	RequestBuildingSave:Destroy()
	RequestBuildingSave = nil
end
if not RequestBuildingSave then
	RequestBuildingSave = Instance.new("BindableEvent")
	RequestBuildingSave.Name = "RequestBuildingSave"
	RequestBuildingSave.Parent = Events
end

local function getPlacedFolder()
	local folder = workspace:FindFirstChild("PlacedObjects")
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = "PlacedObjects"
		folder.Parent = workspace
	end
	return folder
end

local function isEditableTarget(player, model)
	if not model or not model:IsA("Model") then
		return false
	end
	if model:GetAttribute("Type") ~= CustomBuildingConfig.TYPE_NAME then
		return false
	end
	if model:GetAttribute("Owner") ~= player.UserId then
		return false
	end
	return model:IsDescendantOf(getPlacedFolder())
end

local function readMergedState(model, payload)
	local current = CustomBuildingConfig.ReadState(model)
	payload = type(payload) == "table" and payload or {}
	return {
		Position = typeof(payload.Position) == "Vector3" and payload.Position or current.Position,
		Yaw = type(payload.Yaw) == "number" and payload.Yaw or current.Yaw,
		Size = typeof(payload.Size) == "Vector3" and payload.Size or current.Size,
		Color = typeof(payload.Color) == "Color3" and payload.Color or current.Color,
		Material = payload.Material or current.Material,
		Shape = type(payload.Shape) == "string" and payload.Shape or current.Shape,
	}
end

CustomBuildRequest.OnServerInvoke = function(player, action, model, payload)
	if not CUSTOM_BUILDING_ENABLED then
		return { success = false, reason = "Builder Studio is temporarily disabled." }
	end
	if action == "Apply" then
		if not isEditableTarget(player, model) then
			return { success = false, reason = "Invalid target." }
		end
		local nextState = readMergedState(model, payload)
		local applied = CustomBuildingConfig.ApplyState(model, nextState)
		if not applied then
			return { success = false, reason = "Failed to update piece." }
		end
		if RequestBuildingSave then
			RequestBuildingSave:Fire()
		end
		return { success = true, model = model, state = CustomBuildingConfig.ReadState(model) }
	elseif action == "Paint" then
		if not isEditableTarget(player, model) then
			return { success = false, reason = "Invalid target." }
		end
		local current = CustomBuildingConfig.ReadState(model)
		local applied = CustomBuildingConfig.ApplyState(model, {
			Position = current.Position,
			Yaw = current.Yaw,
			Size = current.Size,
			Color = typeof(payload) == "table" and payload.Color or current.Color,
			Material = type(payload) == "table" and payload.Material or current.Material,
			Shape = current.Shape,
		})
		if not applied then
			return { success = false, reason = "Failed to paint piece." }
		end
		if RequestBuildingSave then
			RequestBuildingSave:Fire()
		end
		return { success = true, model = model, state = CustomBuildingConfig.ReadState(model) }
	elseif action == "ReadState" then
		if not isEditableTarget(player, model) then
			return { success = false, reason = "Invalid target." }
		end
		return { success = true, model = model, state = CustomBuildingConfig.ReadState(model) }
	end

	return { success = false, reason = "Unknown action." }
end