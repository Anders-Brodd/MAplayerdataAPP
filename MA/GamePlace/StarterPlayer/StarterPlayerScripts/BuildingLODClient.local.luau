local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Player = Players.LocalPlayer
local GraphicsProfile = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("GraphicsProfile"))

local BASE_BUILDING_DISTANCE = 1800
local UPDATE_INTERVAL = 0.25
local FORCE_REVEAL_INTERVAL = 0.8
local CULL_ENTER_MULTIPLIER = 1.08
local CULL_EXIT_MULTIPLIER = 0.92
local SPAWN_REVEAL_SECONDS = 20

local tracked = {}
local lastForceRevealAt = 0
local spawnRevealUntil = os.clock() + SPAWN_REVEAL_SECONDS

local function isPlacedObjectRootModel(model, placed)
	if not (model and model:IsA("Model") and placed) then
		return false
	end
	local parent = model.Parent
	while parent and parent ~= placed do
		if parent:IsA("Model") and (
			parent:GetAttribute("UUID") ~= nil
			or parent:GetAttribute("Type") ~= nil
			or parent:GetAttribute("Category") ~= nil
		) then
			return false
		end
		parent = parent.Parent
	end
	return parent == placed
end

local function isManagedBuilding(model)
	if not model:IsA("Model") then
		return false
	end
	local buildingType = tostring(model:GetAttribute("Type") or "")
	if buildingType == "TwoPoint" or buildingType == "Carpet" or buildingType == "Lift" then
		return false
	end
	return true
end

local function buildRecord(model)
	local parts = {}
	for _, desc in ipairs(model:GetDescendants()) do
		if desc:IsA("BasePart") then
			table.insert(parts, desc)
		end
	end
	local record = {
		Model = model,
		Parts = parts,
		Culled = false,
		DescendantAddedConn = nil,
	}
	record.DescendantAddedConn = model.DescendantAdded:Connect(function(desc)
		if desc:IsA("BasePart") then
			table.insert(record.Parts, desc)
			desc.LocalTransparencyModifier = record.Culled and 1 or 0
		end
	end)
	return record
end

local function setRecordCulled(record, shouldCull)
	if record.Culled == shouldCull then
		return
	end
	record.Culled = shouldCull
	for _, part in ipairs(record.Parts) do
		if part.Parent then
			part.LocalTransparencyModifier = shouldCull and 1 or 0
		end
	end
end

local function unregisterModel(model)
	local record = tracked[model]
	if not record then
		return
	end
	setRecordCulled(record, false)
	if record.DescendantAddedConn then
		record.DescendantAddedConn:Disconnect()
		record.DescendantAddedConn = nil
	end
	tracked[model] = nil
end

local function registerModel(model)
	if tracked[model] or not isManagedBuilding(model) then
		return
	end
	tracked[model] = buildRecord(model)
	model.Destroying:Connect(function()
		unregisterModel(model)
	end)
end

local function rebuildTracked()
	for model in pairs(tracked) do
		unregisterModel(model)
	end
	table.clear(tracked)
	local placed = Workspace:FindFirstChild("PlacedObjects")
	if not placed then
		return
	end
	for _, child in ipairs(placed:GetDescendants()) do
		if child:IsA("Model") and isPlacedObjectRootModel(child, placed) then
			registerModel(child)
		end
	end
end

local function forceRevealAllBuildings()
	local placed = Workspace:FindFirstChild("PlacedObjects")
	if not placed then
		return
	end
	for _, desc in ipairs(placed:GetDescendants()) do
		if desc:IsA("BasePart") and desc.LocalTransparencyModifier ~= 0 then
			desc.LocalTransparencyModifier = 0
		end
	end
end

local function bindPlacedObjects()
	local placed = Workspace:FindFirstChild("PlacedObjects")
	if not placed then
		return false
	end
	rebuildTracked()
	placed.ChildAdded:Connect(function(child)
		if child:IsA("Model") then
			registerModel(child)
		end
	end)
	placed.ChildRemoved:Connect(function(child)
		unregisterModel(child)
	end)
	return true
end

if not bindPlacedObjects() then
	Workspace.ChildAdded:Connect(function(child)
		if child.Name == "PlacedObjects" then
			bindPlacedObjects()
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
	local cameraPos = camera.CFrame.Position
	if os.clock() < spawnRevealUntil then
		for model, record in pairs(tracked) do
			if not model.Parent then
				unregisterModel(model)
			else
				setRecordCulled(record, false)
			end
		end
		forceRevealAllBuildings()
		return
	end
	local distanceChoice = GraphicsProfile.GetDistanceChoice(Player, "BuildingRenderDistance")
	local distanceOff = distanceChoice == "Off"
	if distanceOff then
		local now = tick()
		if now - lastForceRevealAt >= FORCE_REVEAL_INTERVAL then
			lastForceRevealAt = now
			forceRevealAllBuildings()
		end
		for model, record in pairs(tracked) do
			if not model.Parent then
				unregisterModel(model)
			else
				setRecordCulled(record, false)
			end
		end
		return
	end
	local distanceScale = GraphicsProfile.GetDistanceScale(Player, "BuildingRenderDistance")
	local maxDistance = BASE_BUILDING_DISTANCE * distanceScale
	local cullEnterDistanceSq = (maxDistance * CULL_ENTER_MULTIPLIER) ^ 2
	local cullExitDistanceSq = (maxDistance * CULL_EXIT_MULTIPLIER) ^ 2

	for model, record in pairs(tracked) do
		if not model.Parent then
			unregisterModel(model)
			continue
		end
		local pivotPos = model:GetPivot().Position
		local delta = pivotPos - cameraPos
		local distSq = delta:Dot(delta)
		if record.Culled then
			setRecordCulled(record, distSq > cullExitDistanceSq)
		else
			setRecordCulled(record, distSq > cullEnterDistanceSq)
		end
	end
end)
