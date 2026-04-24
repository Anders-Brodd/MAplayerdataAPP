local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local function IsLegacyBullwheelScript(instance)
	if not (instance and instance:IsA("Script")) then
		return false
	end
	return string.find(instance:GetFullName(), "Bullwheel", 1, true) ~= nil
end

local function DisableScriptIfNeeded(instance)
	if not IsLegacyBullwheelScript(instance) then
		return
	end
	if not instance.Disabled then
		instance.Disabled = true
	end
end

local function ScanRoot(root)
	if not root then
		return
	end
	for _, descendant in ipairs(root:GetDescendants()) do
		DisableScriptIfNeeded(descendant)
	end
end

local placedObjects = Workspace:FindFirstChild("PlacedObjects")
if placedObjects then
	ScanRoot(placedObjects)
	placedObjects.DescendantAdded:Connect(function(descendant)
		DisableScriptIfNeeded(descendant)
	end)
end

local assets = ReplicatedStorage:FindFirstChild("Assets")
local liftsFolder = assets and assets:FindFirstChild("Lifts")
if liftsFolder then
	ScanRoot(liftsFolder)
	liftsFolder.DescendantAdded:Connect(function(descendant)
		DisableScriptIfNeeded(descendant)
	end)
end

Workspace.ChildAdded:Connect(function(child)
	if child.Name == "PlacedObjects" then
		ScanRoot(child)
		child.DescendantAdded:Connect(function(descendant)
			DisableScriptIfNeeded(descendant)
		end)
	end
end)
