local Workspace = game:GetService("Workspace")

local FALL_THRESHOLD_OFFSET = 15
local SAFE_RAY_DISTANCE = 30
local SAFE_FLOOR_DISTANCE = 15
local RESCUE_HEIGHT_OFFSET = 5
local CHECK_INTERVAL = 0.8

local lastSafeByModel = {}
local lastRescueAt = {}

local function getEmployeesFolder()
	local folder = Workspace:FindFirstChild("Employees")
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = "Employees"
		folder.Parent = Workspace
	end
	return folder
end

local function migrateStrayEmployees(folder)
	for _, child in ipairs(Workspace:GetChildren()) do
		if child:IsA("Model") and child:GetAttribute("IsEmployee") == true and child.Parent == Workspace then
			child.Parent = folder
		end
	end
end

local function getStartSpawnCF()
	local startSpawn = Workspace:FindFirstChild("StartSpawn", true)
	if startSpawn and startSpawn:IsA("SpawnLocation") then
		return startSpawn.CFrame + Vector3.new(0, RESCUE_HEIGHT_OFFSET, 0)
	end
	return nil
end

local function updateSafePosition(model, root)
	local rayParams = RaycastParams.new()
	rayParams.FilterType = Enum.RaycastFilterType.Exclude
	rayParams.FilterDescendantsInstances = {model}

	local result = Workspace:Raycast(root.Position + Vector3.new(0, 4, 0), Vector3.new(0, -SAFE_RAY_DISTANCE, 0), rayParams)
	if result and (root.Position.Y - result.Position.Y) <= SAFE_FLOOR_DISTANCE then
		lastSafeByModel[model] = root.CFrame
	end
end

local function rescueEmployee(model, root)
	local now = tick()
	if lastRescueAt[model] and (now - lastRescueAt[model]) < 1.5 then
		return
	end
	lastRescueAt[model] = now

	local targetCF = lastSafeByModel[model]
	if not targetCF then
		targetCF = getStartSpawnCF()
	end
	if not targetCF then
		return
	end

	root.AssemblyLinearVelocity = Vector3.zero
	root.AssemblyAngularVelocity = Vector3.zero
	model:PivotTo(targetCF + Vector3.new(0, RESCUE_HEIGHT_OFFSET, 0))
end

while true do
	local employeesFolder = getEmployeesFolder()
	if employeesFolder then
		migrateStrayEmployees(employeesFolder)
		for _, model in ipairs(employeesFolder:GetChildren()) do
			if model:IsA("Model") then
				local humanoid = model:FindFirstChildOfClass("Humanoid")
				local root = model:FindFirstChild("HumanoidRootPart")
				if humanoid and root and humanoid.Health > 0 then
					updateSafePosition(model, root)
					if root.Position.Y < (Workspace.FallenPartsDestroyHeight + FALL_THRESHOLD_OFFSET) then
						rescueEmployee(model, root)
					end
				end
			end
		end
	end
	task.wait(CHECK_INTERVAL)
end
