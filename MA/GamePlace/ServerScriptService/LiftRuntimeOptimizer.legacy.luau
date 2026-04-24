local Workspace = game:GetService("Workspace")

local KEEP_TOUCH_TOKENS = {
	"seat",
	"trigger",
	"scan",
	"button",
	"prompt",
	"sensor",
	"detector",
	"gate",
}

local FORCE_NO_COLLIDE_TOKENS = {
	"pole",
	"tower",
	"pylon",
	"support",
	"bullwheel",
	"sheave",
	"cable",
	"rope",
	"chair",
	"carrier",
	"hanger",
	"grip",
	"seat",
	"bar",
	"bubble",
	"arm",
}

local trackedLiftModels = {}

local function hasToken(value, tokens)
	if value == "" then
		return false
	end
	for _, token in ipairs(tokens) do
		if string.find(value, token, 1, true) then
			return true
		end
	end
	return false
end

local function isLiftModel(model)
	if not (model and model:IsA("Model")) then
		return false
	end
	local modelType = string.lower(tostring(model:GetAttribute("Type") or ""))
	if modelType == "twopoint" or modelType == "carpet" or modelType == "lift" then
		return true
	end
	local lowerName = string.lower(model.Name)
	return string.find(lowerName, "lift", 1, true) ~= nil
		or string.find(lowerName, "tow", 1, true) ~= nil
		or string.find(lowerName, "gondola", 1, true) ~= nil
		or string.find(lowerName, "chair", 1, true) ~= nil
end

local function shouldKeepTouch(part)
	if part:GetAttribute("KeepTouch") == true then
		return true
	end
	local lowerName = string.lower(part.Name)
	local lowerParentName = part.Parent and string.lower(part.Parent.Name) or ""
	return hasToken(lowerName, KEEP_TOUCH_TOKENS)
		or hasToken(lowerParentName, KEEP_TOUCH_TOKENS)
end

local function shouldForceNoCollide(part)
	if part:GetAttribute("KeepCollide") == true then
		return false
	end
	local lowerName = string.lower(part.Name)
	local lowerParentName = part.Parent and string.lower(part.Parent.Name) or ""
	return hasToken(lowerName, FORCE_NO_COLLIDE_TOKENS)
		or hasToken(lowerParentName, FORCE_NO_COLLIDE_TOKENS)
end

local function optimizeLiftDescendant(desc)
	if desc:IsA("Script") then
		local fullName = string.lower(desc:GetFullName())
		if string.find(fullName, "bullwheel", 1, true) and not desc.Disabled then
			desc.Disabled = true
		end
		return
	end

	if not desc:IsA("BasePart") then
		return
	end

	if desc.Anchored and desc.CanTouch and not shouldKeepTouch(desc) then
		desc.CanTouch = false
	end

	if shouldForceNoCollide(desc) then
		if desc.CanCollide then
			desc.CanCollide = false
		end
		if desc.CanQuery then
			desc.CanQuery = false
		end
		if desc.CanTouch and not shouldKeepTouch(desc) then
			desc.CanTouch = false
		end
	end
end

local function optimizeLiftModel(model)
	if trackedLiftModels[model] then
		return
	end
	trackedLiftModels[model] = true

	for _, desc in ipairs(model:GetDescendants()) do
		optimizeLiftDescendant(desc)
	end

	model.DescendantAdded:Connect(function(desc)
		task.defer(function()
			if desc and desc.Parent and model.Parent then
				optimizeLiftDescendant(desc)
			end
		end)
	end)

	model.Destroying:Connect(function()
		trackedLiftModels[model] = nil
	end)
end

local function bindPlacedObjects(placedObjects)
	for _, child in ipairs(placedObjects:GetChildren()) do
		if child:IsA("Model") and isLiftModel(child) then
			optimizeLiftModel(child)
		end
	end

	placedObjects.ChildAdded:Connect(function(child)
		if child:IsA("Model") and isLiftModel(child) then
			optimizeLiftModel(child)
		end
	end)
end

local placedObjects = Workspace:FindFirstChild("PlacedObjects")
if placedObjects then
	bindPlacedObjects(placedObjects)
end

Workspace.ChildAdded:Connect(function(child)
	if child.Name == "PlacedObjects" and child:IsA("Folder") then
		bindPlacedObjects(child)
	end
end)
