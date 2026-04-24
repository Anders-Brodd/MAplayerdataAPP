local Workspace = game:GetService("Workspace")

local PlacedObjects = Workspace:WaitForChild("PlacedObjects")

local STATIC_DECOR_NAMES = {
	["Slow Sign"] = true,
	["Boundary Sign"] = true,
	["Bench 1"] = true,
	["Bench 2"] = true,
	["Bench 3"] = true,
	["Bench 4"] = true,
	["Bench 5"] = true,
}

local function shouldPatchModel(model)
	return model and model:IsA("Model") and STATIC_DECOR_NAMES[model.Name] == true
end

local function anchorModel(model)
	for _, descendant in ipairs(model:GetDescendants()) do
		if descendant:IsA("BasePart") then
			descendant.Anchored = true
			descendant.AssemblyLinearVelocity = Vector3.zero
			descendant.AssemblyAngularVelocity = Vector3.zero
		end
	end
end

local function fixBenchSeatFacing(model)
	if not string.find(model.Name, "Bench", 1, true) then
		return
	end

	local barrier = model:FindFirstChild("Barrier", true)
	if not barrier or not barrier:IsA("BasePart") then
		return
	end

	local flatBarrierLook = Vector3.new(barrier.CFrame.LookVector.X, 0, barrier.CFrame.LookVector.Z)
	if flatBarrierLook.Magnitude < 0.001 then
		flatBarrierLook = Vector3.zAxis
	else
		flatBarrierLook = flatBarrierLook.Unit
	end

	for _, descendant in ipairs(model:GetDescendants()) do
		if descendant:IsA("Seat") then
			local seatPos = descendant.Position
			local desiredLook = -flatBarrierLook
			descendant.CFrame = CFrame.lookAt(seatPos, seatPos + desiredLook, Vector3.yAxis)
			descendant.AssemblyLinearVelocity = Vector3.zero
			descendant.AssemblyAngularVelocity = Vector3.zero
		end
	end
end

local function fixBoundarySignOrientation(model)
	if model.Name ~= "Boundary Sign" then
		return
	end

	local pivot = model:GetPivot()
	if math.abs(pivot.UpVector:Dot(Vector3.yAxis)) >= 0.8 then
		return
	end

	local flatLook = Vector3.new(pivot.LookVector.X, 0, pivot.LookVector.Z)
	local flatRight = Vector3.new(pivot.RightVector.X, 0, pivot.RightVector.Z)
	local forward = flatLook.Magnitude >= flatRight.Magnitude and flatLook or flatRight
	if forward.Magnitude < 0.001 then
		forward = Vector3.zAxis
	else
		forward = forward.Unit
	end

	model:PivotTo(CFrame.lookAt(pivot.Position, pivot.Position + forward, Vector3.yAxis))
	anchorModel(model)
end

local function fixSlowSignGuestPhysics(model)
	if model.Name ~= "Slow Sign" then
		return
	end
	for _, descendant in ipairs(model:GetDescendants()) do
		if descendant:IsA("BasePart") then
			descendant.CanCollide = false
		end
	end
end

local function patchStaticDecor(model)
	if not shouldPatchModel(model) then
		return
	end

	anchorModel(model)
	fixSlowSignGuestPhysics(model)
	fixBenchSeatFacing(model)
	fixBoundarySignOrientation(model)
end

local queuedModels = {}

local function queuePatchForModel(model)
	if not shouldPatchModel(model) then
		return
	end
	if queuedModels[model] then
		return
	end
	queuedModels[model] = true
	task.defer(function()
		queuedModels[model] = nil
		if model and model.Parent then
			patchStaticDecor(model)
		end
	end)
end

local function patchFromInstance(instance)
	if not instance then
		return
	end
	if instance:IsA("Model") then
		queuePatchForModel(instance)
		return
	end
	local model = instance:FindFirstAncestorOfClass("Model")
	if model then
		queuePatchForModel(model)
	end
end

for _, child in ipairs(PlacedObjects:GetChildren()) do
	patchFromInstance(child)
end

PlacedObjects.ChildAdded:Connect(function(child)
	patchFromInstance(child)
end)

PlacedObjects.DescendantAdded:Connect(function(descendant)
	patchFromInstance(descendant)
end)
