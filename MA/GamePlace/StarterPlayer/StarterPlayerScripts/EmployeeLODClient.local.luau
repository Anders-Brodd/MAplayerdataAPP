local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Player = Players.LocalPlayer
local GraphicsProfile = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("GraphicsProfile"))

local BASE_NPC_DISTANCE = 280
local UPDATE_INTERVAL = 0.2
local CULL_ENTER_MULTIPLIER = 1.1
local CULL_EXIT_MULTIPLIER = 0.9
local SPAWN_REVEAL_SECONDS = 20

local tracked = {}
local spawnRevealUntil = os.clock() + SPAWN_REVEAL_SECONDS

local function buildEmployeeRecord(model)
	local parts = {}
	for _, desc in ipairs(model:GetDescendants()) do
		if desc:IsA("BasePart") then
			table.insert(parts, desc)
		end
	end
	return {
		Model = model,
		Parts = parts,
		Culled = false,
	}
end

local function applyCulled(record, culled)
	if record.Culled == culled then
		return
	end
	record.Culled = culled
	local model = record.Model
	model:SetAttribute("_ClientEmployeeCulled", culled)
	for _, part in ipairs(record.Parts) do
		if part.Parent then
			part.LocalTransparencyModifier = culled and 1 or 0
		end
	end
end

local function registerEmployee(model)
	if tracked[model] then
		return
	end
	local record = buildEmployeeRecord(model)
	tracked[model] = record
	model.DescendantAdded:Connect(function(desc)
		if desc:IsA("BasePart") and tracked[model] then
			table.insert(record.Parts, desc)
		end
	end)
	model.Destroying:Connect(function()
		tracked[model] = nil
	end)
end

local function bindEmployeesFolder(folder)
	for _, child in ipairs(folder:GetChildren()) do
		if child:IsA("Model") then
			registerEmployee(child)
		end
	end
	folder.ChildAdded:Connect(function(child)
		if child:IsA("Model") then
			registerEmployee(child)
		end
	end)
	folder.ChildRemoved:Connect(function(child)
		tracked[child] = nil
	end)
end

local employeesFolder = Workspace:FindFirstChild("Employees")
if employeesFolder then
	bindEmployeesFolder(employeesFolder)
else
	Workspace.ChildAdded:Connect(function(child)
		if child.Name == "Employees" and child:IsA("Folder") then
			bindEmployeesFolder(child)
		end
	end)
end

Player.CharacterAdded:Connect(function()
	spawnRevealUntil = os.clock() + SPAWN_REVEAL_SECONDS
end)

local accum = 0
RunService.Heartbeat:Connect(function(dt)
	accum += dt
	if accum < UPDATE_INTERVAL then
		return
	end
	accum = 0
	local camera = Workspace.CurrentCamera
	if not camera then
		return
	end
	local camPos = camera.CFrame.Position
	if os.clock() < spawnRevealUntil then
		for model, record in pairs(tracked) do
			if not model.Parent then
				tracked[model] = nil
			else
				applyCulled(record, false)
			end
		end
		return
	end
	local distScale = GraphicsProfile.GetDistanceScale(Player, "NPCRenderDistance")
	local maxDist = BASE_NPC_DISTANCE * distScale
	local cullEnterSq = (maxDist * CULL_ENTER_MULTIPLIER) ^ 2
	local cullExitSq = (maxDist * CULL_EXIT_MULTIPLIER) ^ 2

	for model, record in pairs(tracked) do
		if not model.Parent then
			tracked[model] = nil
			continue
		end
		local root = model:FindFirstChild("HumanoidRootPart")
		if not root then
			continue
		end
		local delta = root.Position - camPos
		local distSq = delta:Dot(delta)
		if record.Culled then
			applyCulled(record, distSq > cullExitSq)
		else
			applyCulled(record, distSq > cullEnterSq)
		end
	end
end)
