local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local SnowGunShared = require(ReplicatedStorage:WaitForChild("SnowGunShared"))
local PLACED_FOLDER = Workspace:WaitForChild("PlacedObjects")
local LocalPlayer = Players.LocalPlayer

local CONFIG = {
	Speeds = {
		Slow = 0.5,
		Medium = 1.0,
		Fast = 2.0,
		Off = 0,
	},
	SpinSpeeds = {
		Slow = 18,
		Medium = 42,
		Fast = 84,
		Off = 0,
	},
}

local gunCache = {}
local setupPending = {}

local function shouldManageModel(model)
	return model
		and model:IsA("Model")
		and SnowGunShared.IsSnowGunName(model.Name)
		and model:GetAttribute("IsPlacementGhost") ~= true
end

local function isPerfModeEnabled()
	return LocalPlayer and LocalPlayer:GetAttribute("Settings_SnowGunPerf") == true
end

local function resetGunVisuals(data)
	if not data then
		return
	end
	SnowGunShared.ApplyYawOffset(data.Rig, data.BaseCFrame, 0)
	SnowGunShared.ApplySpinParts(data.Rig, data.SpinParts, 0)
	data.ResetForPerf = true
end

local function normalizeState(state)
	local lowered = string.lower(tostring(state or "Off"))
	if lowered == "slow" then
		return "Slow"
	elseif lowered == "medium" then
		return "Medium"
	elseif lowered == "fast" then
		return "Fast"
	end
	return "Off"
end

local function getSpinSpeedForState(model, rig, state)
	if rig and rig.Config and rig.Config.DisableSpin then
		return 0
	end
	return CONFIG.SpinSpeeds[state] or 0
end

local function syncGunEffectsToState(model, data)
	if not data or not data.Rig then
		return
	end
	local state = normalizeState(model and model:GetAttribute("State"))
	SnowGunShared.SetVisualEffectsEnabled(data.Rig, state ~= "Off")
	data.EffectSuppressedForPerf = false
end

local function suppressGunEffectsForPerf(data)
	if not data or not data.Rig then
		return
	end
	SnowGunShared.SetVisualEffectsEnabled(data.Rig, false)
	data.EffectSuppressedForPerf = true
end

local function SetupGun(model)
	if gunCache[model] or not model or not model.Parent then
		return true
	end
	if not shouldManageModel(model) then
		return false
	end
	SnowGunShared.PrepareModel(model)

	local rig = SnowGunShared.ResolveRig(model)
	local baseCFrame = SnowGunShared.GetBaseCFrame(rig)
	if not rig or not baseCFrame then
		return false
	end

	SnowGunShared.ApplyConfiguredEmissionDirections(rig)
	SnowGunShared.ApplyYawOffset(rig, baseCFrame, 0)
	local spinParts = SnowGunShared.GetSpinParts(model, rig)

	local stateConn
	local descendantConn
	gunCache[model] = {
		Rig = rig,
		BaseCFrame = baseCFrame,
		OscillationSpeed = 0,
		SpinSpeed = 0,
		OscillationAngle = math.rad(rig.Profile.OscillationAngle or 0),
		SpinParts = spinParts,
		ResetForPerf = false,
		EffectSuppressedForPerf = false,
		StateConn = nil,
		DescendantConn = nil,
	}

	stateConn = model:GetAttributeChangedSignal("State"):Connect(function()
		local state = normalizeState(model:GetAttribute("State"))
		local cache = gunCache[model]
		if cache then
			cache.OscillationSpeed = CONFIG.Speeds[state] or 0
			cache.SpinSpeed = getSpinSpeedForState(model, cache.Rig, state)
			if isPerfModeEnabled() then
				suppressGunEffectsForPerf(cache)
			else
				syncGunEffectsToState(model, cache)
			end
		end
	end)

	descendantConn = model.DescendantAdded:Connect(function(descendant)
		if not SnowGunShared.IsSupportedVisualEffect(descendant) then
			return
		end
		task.defer(function()
			local cache = gunCache[model]
			if not cache or not model.Parent then
				return
			end
			if isPerfModeEnabled() then
				suppressGunEffectsForPerf(cache)
			else
				syncGunEffectsToState(model, cache)
			end
		end)
	end)

	gunCache[model].StateConn = stateConn
	gunCache[model].DescendantConn = descendantConn

	local state = normalizeState(model:GetAttribute("State"))
	gunCache[model].OscillationSpeed = CONFIG.Speeds[state] or 0
	gunCache[model].SpinSpeed = getSpinSpeedForState(model, rig, state)
	if isPerfModeEnabled() then
		suppressGunEffectsForPerf(gunCache[model])
	else
		syncGunEffectsToState(model, gunCache[model])
	end
	return true
end

local function QueueSetup(model, attempt)
	if gunCache[model] or not model or not model.Parent then
		setupPending[model] = nil
		return
	end
	attempt = attempt or 1
	if setupPending[model] and setupPending[model] >= attempt then
		return
	end
	setupPending[model] = attempt
	task.delay(attempt == 1 and 0 or 0.2, function()
		if gunCache[model] or not model or not model.Parent then
			setupPending[model] = nil
			return
		end
		if SetupGun(model) then
			setupPending[model] = nil
			return
		end
		setupPending[model] = nil
		if attempt < 20 then
			QueueSetup(model, attempt + 1)
		end
	end)
end

local function scanContainer(container)
	if not container then
		return
	end
	for _, child in ipairs(container:GetChildren()) do
		if shouldManageModel(child) then
			QueueSetup(child)
		end
	end
end

PLACED_FOLDER.ChildAdded:Connect(function(child)
	if shouldManageModel(child) then
		QueueSetup(child)
	end
end)
Workspace.ChildAdded:Connect(function(child)
	if child ~= PLACED_FOLDER and shouldManageModel(child) then
		QueueSetup(child)
	end
end)

scanContainer(PLACED_FOLDER)
scanContainer(Workspace)

RunService.RenderStepped:Connect(function()
	local currentTime = time()
	local perfMode = isPerfModeEnabled()

	for model, data in pairs(gunCache) do
		if not model.Parent then
			if data.StateConn then
				data.StateConn:Disconnect()
				data.StateConn = nil
			end
			if data.DescendantConn then
				data.DescendantConn:Disconnect()
				data.DescendantConn = nil
			end
			gunCache[model] = nil
			continue
		end

		if perfMode then
			if not data.ResetForPerf then
				resetGunVisuals(data)
			end
			if not data.EffectSuppressedForPerf then
				suppressGunEffectsForPerf(data)
			end
			continue
		elseif data.ResetForPerf then
			data.ResetForPerf = false
		end

		if data.EffectSuppressedForPerf then
			syncGunEffectsToState(model, data)
		end

		local yawAngle = 0
		if data.OscillationSpeed > 0 and data.OscillationAngle > 0 then
			yawAngle = math.sin(currentTime * data.OscillationSpeed) * data.OscillationAngle
		end
		SnowGunShared.ApplyYawOffset(data.Rig, data.BaseCFrame, yawAngle)
		SnowGunShared.ApplySpinParts(data.Rig, data.SpinParts, currentTime * data.SpinSpeed)
	end
end)

print("SnowGunVisuals Online")