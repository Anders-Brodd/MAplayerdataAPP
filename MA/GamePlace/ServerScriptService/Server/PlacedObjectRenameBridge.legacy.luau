local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Events = ReplicatedStorage:WaitForChild("Events")
local RenamePlacedObject = Events:WaitForChild("RenamePlacedObject")
local PlacedObjects = Workspace:WaitForChild("PlacedObjects")

local MAX_NAME_LENGTH = 48
local trackedConnections = {}

local function sanitizeName(raw)
	local text = tostring(raw or "")
	text = text:gsub("[%c]", " ")
	text = text:gsub("%s+", " ")
	text = text:gsub("^%s+", "")
	text = text:gsub("%s+$", "")
	if #text > MAX_NAME_LENGTH then
		text = string.sub(text, 1, MAX_NAME_LENGTH)
		text = text:gsub("%s+$", "")
	end
	return text
end

local function isSupportedPlacedObject(model)
	if not (model and model:IsA("Model") and model:IsDescendantOf(PlacedObjects)) then
		return false
	end

	local typeName = tostring(model:GetAttribute("Type") or "")
	if typeName == "Slope" or typeName == "TwoPoint" or typeName == "Carpet" then
		return true
	end

	return model:FindFirstChild("StartStation") ~= nil and model:FindFirstChild("EndStation") ~= nil
end

local function ensureDefaultName(model)
	local existing = sanitizeName(model:GetAttribute("DefaultPlacedName"))
	if existing == "" then
		model:SetAttribute("DefaultPlacedName", model.Name)
	end
end

local function syncDisplayName(model, incomingName)
	if not isSupportedPlacedObject(model) then
		return
	end

	ensureDefaultName(model)

	local customName = sanitizeName(incomingName)
	if customName == "" then
		customName = sanitizeName(model:GetAttribute("CustomName"))
	end

	local defaultName = sanitizeName(model:GetAttribute("DefaultPlacedName"))
	if defaultName == "" then
		defaultName = model.Name
	end

	if sanitizeName(model:GetAttribute("CustomName")) ~= customName then
		model:SetAttribute("CustomName", customName)
	end
end

local function untrackModel(model)
	local connection = trackedConnections[model]
	if connection then
		connection:Disconnect()
		trackedConnections[model] = nil
	end
end

local function trackModel(model)
	if not isSupportedPlacedObject(model) then
		return
	end
	if trackedConnections[model] then
		return
	end

	ensureDefaultName(model)
	syncDisplayName(model)
	trackedConnections[model] = model:GetAttributeChangedSignal("CustomName"):Connect(function()
		syncDisplayName(model)
	end)
end

RenamePlacedObject.OnServerEvent:Connect(function(player, target, requestedName)
	if not isSupportedPlacedObject(target) then
		return
	end

	local owner = target:GetAttribute("Owner")
	if typeof(owner) == "number" and owner ~= player.UserId then
		return
	end

	syncDisplayName(target, requestedName)
end)

PlacedObjects.ChildAdded:Connect(function(child)
	if child:IsA("Model") then
		trackModel(child)
	end
end)

PlacedObjects.ChildRemoved:Connect(function(child)
	untrackModel(child)
end)

for _, child in ipairs(PlacedObjects:GetChildren()) do
	if child:IsA("Model") then
		trackModel(child)
	end
end
