local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Events = ReplicatedStorage:WaitForChild("Events")
local RenamePlacedObject = Events:FindFirstChild("RenamePlacedObject")
if not RenamePlacedObject then
	RenamePlacedObject = Instance.new("RemoteEvent")
	RenamePlacedObject.Name = "RenamePlacedObject"
	RenamePlacedObject.Parent = Events
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

local function sanitizeCustomName(raw)
	local text = tostring(raw or "")
	text = text:gsub("[%c]", " ")
	text = text:gsub("%s+", " ")
	text = text:gsub("^%s+", "")
	text = text:gsub("%s+$", "")
	if #text > 48 then
		text = string.sub(text, 1, 48)
	end
	return text
end

local function isRenamableModel(model)
	if not (model and model:IsA("Model")) then
		return false
	end
	local itemType = tostring(model:GetAttribute("Type") or "")
	if model:GetAttribute("Difficulty") ~= nil or itemType == "Slope" or model:GetAttribute("RawPoints") ~= nil then
		return true
	end
	if itemType == "TwoPoint" or itemType == "Carpet" then
		return true
	end
	return false
end

local function isOwnedByPlayer(model, player)
	local ownerId = tonumber(model:GetAttribute("Owner")) or tonumber(model:GetAttribute("OwnerId"))
	return ownerId ~= nil and ownerId == player.UserId
end

RenamePlacedObject.OnServerEvent:Connect(function(player, model, requestedName)
	if typeof(model) ~= "Instance" then
		return
	end

	local placedObjects = Workspace:FindFirstChild("PlacedObjects")
	if not placedObjects or model.Parent ~= placedObjects then
		return
	end
	if not isRenamableModel(model) then
		return
	end
	if not isOwnedByPlayer(model, player) then
		return
	end

	local cleanName = sanitizeCustomName(requestedName)
	if cleanName == "" then
		model:SetAttribute("CustomName", nil)
		RequestBuildingSave:Fire()
		return
	end
	model:SetAttribute("CustomName", cleanName)
	RequestBuildingSave:Fire()
end)
