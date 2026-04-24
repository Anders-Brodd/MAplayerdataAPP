local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local PlacedObjects = Workspace:WaitForChild("PlacedObjects")
local Events = ReplicatedStorage:WaitForChild("Events")
local BuildingRestoreReady = Events:FindFirstChild("BuildingRestoreReady")
local TerrainRestoreReady = Events:FindFirstChild("TerrainRestoreReady")

local REPAIR_DELAY = 5
local REPAIR_COOLDOWN = 60

local pendingRepair = {}
local repairQueued = {}
local slopeConnections = {}
local lastRepairAt = {}

local function isSlopeModel(instance)
	return instance
		and instance:IsA("Model")
		and (instance:GetAttribute("Type") == "Slope"
			or instance:GetAttribute("RawPoints") ~= nil
			or instance:GetAttribute("Difficulty") ~= nil)
end

local function disconnectSlope(model)
	local connections = slopeConnections[model]
	if not connections then
		return
	end
	for _, connection in ipairs(connections) do
		connection:Disconnect()
	end
	slopeConnections[model] = nil
	pendingRepair[model] = nil
	repairQueued[model] = nil
	lastRepairAt[model] = nil
end

local function getExpectedDecor(model)
	local markers = model:GetAttribute("MarkersEnabled") ~= false
	local nets = model:GetAttribute("NetsEnabled") == true
	local markerLights = model:GetAttribute("MarkerLightsEnabled") ~= false
	local hasDifficulty = type(model:GetAttribute("Difficulty")) == "string"
	local expectsSign = hasDifficulty and model:GetAttribute("IsPath") ~= true and model:GetAttribute("IsQueue") ~= true
	if nets then
		markers = false
		markerLights = false
	end
	if markerLights and not markers then
		markers = true
	end
	return {
		markers = markers,
		nets = nets,
		markerLights = markerLights,
		expectsSign = expectsSign,
	}
end

local function getObservedDecor(model)
	local hasMarkers = false
	local hasNets = false
	local hasLights = false
	local hasSign = false
	for _, child in ipairs(model:GetChildren()) do
		if child.Name == "SlopeMarker" or child.Name == "Marker" then
			hasMarkers = true
			for _, descendant in ipairs(child:GetDescendants()) do
				if descendant:IsA("PointLight") and descendant.Name == "MarkerLight" then
					hasLights = true
					break
				end
			end
		elseif child.Name == "Net"
			or child.Name == "SafetyNet"
			or child.Name == "NetPole"
			or child:GetAttribute("GeneratedSlopeNet") == true
			or child:GetAttribute("Type") == "SlopeNet" then
			hasNets = true
		elseif child.Name == "SlopeSign" then
			hasSign = true
		end
	end
	return {
		hasMarkers = hasMarkers,
		hasNets = hasNets,
		hasLights = hasLights,
		hasSign = hasSign,
	}
end

local function needsRepair(model)
	if not model.Parent then
		return false
	end
	local editSlopeDecor = _G.EditSlopeDecor
	if type(editSlopeDecor) ~= "function" then
		return false
	end
	local rawPoints = model:GetAttribute("RawPoints")
	if type(rawPoints) ~= "string" or rawPoints == "" then
		return false
	end
	local expected = getExpectedDecor(model)
	local observed = getObservedDecor(model)
	if expected.markers ~= observed.hasMarkers then
		return true, expected
	end
	if expected.nets ~= observed.hasNets then
		return true, expected
	end
	if expected.markerLights ~= observed.hasLights then
		return true, expected
	end
	if expected.expectsSign and not observed.hasSign then
		return true, expected
	end
	return false, expected
end

local function repairSlope(model)
	if not isSlopeModel(model) or not model.Parent then
		return
	end
	if repairQueued[model] then
		return
	end
	repairQueued[model] = true
	task.delay(REPAIR_DELAY, function()
		repairQueued[model] = nil
		if not isSlopeModel(model) or not model.Parent then
			return
		end
		local now = os.clock()
		if lastRepairAt[model] and (now - lastRepairAt[model]) < REPAIR_COOLDOWN then
			return
		end
		local shouldRepair, expected = needsRepair(model)
		if not shouldRepair then
			return
		end
		lastRepairAt[model] = now
		-- Serialized: only one EditSlopeDecor runs at a time to prevent freeze
		while _G._SlopeDecorRepairBusy do
			task.wait(0.5)
			if not isSlopeModel(model) or not model.Parent then return end
		end
		_G._SlopeDecorRepairBusy = true
		local ok, result = pcall(function()
			return _G.EditSlopeDecor(model, expected)
		end)
		_G._SlopeDecorRepairBusy = false
		if not ok or result == false then
			warn(string.format("[SlopeDecorRuntimePatch] Failed to repair decor for %s", model:GetFullName()))
			return
		end
		print(string.format("[SlopeDecorRuntimePatch] Repaired decor for %s", model:GetFullName()))
	end)
end

local function queueRepairSweep(resetCooldown)
	for _, child in ipairs(PlacedObjects:GetChildren()) do
		if isSlopeModel(child) then
			if resetCooldown then
				lastRepairAt[child] = nil
			end
			repairSlope(child)
		end
	end
end

local function scheduleRestoreSweeps(resetCooldown)
	for _, delaySeconds in ipairs({4}) do   -- was {1,4,8}: three stacked sweeps caused t+10s freeze
		task.delay(delaySeconds, function()
			queueRepairSweep(resetCooldown)
		end)
	end
end

local function registerSlope(model)
	if not isSlopeModel(model) or slopeConnections[model] then
		return
	end
	slopeConnections[model] = {
		model.ChildAdded:Connect(function()
			repairSlope(model)
		end),
		model.ChildRemoved:Connect(function()
			repairSlope(model)
		end),
		model:GetAttributeChangedSignal("MarkersEnabled"):Connect(function()
			repairSlope(model)
		end),
		model:GetAttributeChangedSignal("NetsEnabled"):Connect(function()
			repairSlope(model)
		end),
		model:GetAttributeChangedSignal("MarkerLightsEnabled"):Connect(function()
			repairSlope(model)
		end),
		model.AncestryChanged:Connect(function(_, parent)
			if parent == nil then
				disconnectSlope(model)
			end
		end),
	}
	repairSlope(model)
end

for _, child in ipairs(PlacedObjects:GetChildren()) do
	if isSlopeModel(child) then
		registerSlope(child)
	end
end

PlacedObjects.ChildAdded:Connect(function(child)
	if isSlopeModel(child) then
		registerSlope(child)
	end
end)

PlacedObjects.ChildRemoved:Connect(function(child)
	if slopeConnections[child] then
		disconnectSlope(child)
	end
end)

if BuildingRestoreReady and BuildingRestoreReady:IsA("BindableEvent") then
	BuildingRestoreReady.Event:Connect(function()
		scheduleRestoreSweeps(true)
	end)
end

if TerrainRestoreReady and TerrainRestoreReady:IsA("BindableEvent") then
	TerrainRestoreReady.Event:Connect(function()
		scheduleRestoreSweeps(true)
	end)
end

task.delay(6, function()
	queueRepairSweep(false)
end)
