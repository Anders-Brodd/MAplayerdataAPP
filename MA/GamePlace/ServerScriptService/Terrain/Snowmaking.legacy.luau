--[[
	SNOW MAKING SERVER V6.5 (Blended Realism + Half Distance)
	ServerScriptService/Snowmaking
	
	CHANGES:
	- DISTANCE: Cut Core speed in half (70-90).
	- BLENDING: Added LightEmission and Rotation to make particles fuse into a dense cloud.
	- VISUALS: Adjusted Transparency curves for a softer, organic look.
]]

local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Workspace = game:GetService("Workspace")
local TweenService = game:GetService("TweenService")
local Players = game:GetService("Players")
local Lighting = game:GetService("Lighting")

local SnowGunShared = require(ReplicatedStorage:WaitForChild("SnowGunShared"))

-- // 📡 EVENTS //
local Events = ReplicatedStorage:FindFirstChild("Events") or Instance.new("Folder", ReplicatedStorage)
Events.Name = "Events"
local GunInteractEvent = Events:FindFirstChild("SnowGunInteract") or Instance.new("RemoteEvent", Events)
GunInteractEvent.Name = "SnowGunInteract"
local PLACED_FOLDER = Workspace:FindFirstChild("PlacedObjects") or Instance.new("Folder", Workspace)
PLACED_FOLDER.Name = "PlacedObjects"

-- // ⚙️ CONFIGURATION //
local CONFIG = {
	UpdateInterval = 0.6,
	UpkeepInterval = 5.0,
	OscillationAngle = 35,
	FreezingPoint = 32, OptimalTemp = 28,
	MarginalStaffedDayTemp = 34,
	MarginalStaffedNightTemp = 35,
	MarginalStaffedDayEfficiency = 0.18,
	MarginalStaffedNightEfficiency = 0.28,
	BaseVolume = 0.5, WaterVolume = 0.3,
	GunNames = SnowGunShared.GetItemNames(true),

	IntensitySettings = {
		-- Reduced Radius to match the shorter throw
		Slow =   { SpeedScalar = 0.6, Cost = 5,   SoundPitch = 0.8, OscillationSpeed = 0.4, Radius = 15 },
		Medium = { SpeedScalar = 0.9, Cost = 10,  SoundPitch = 1.0, OscillationSpeed = 0.8, Radius = 25 },
		Fast =   { SpeedScalar = 1.3, Cost = 20,  SoundPitch = 1.2, OscillationSpeed = 1.5, Radius = 35 },
		Off =    { SpeedScalar = 0,   Cost = 0,   SoundPitch = 0,   OscillationSpeed = 0,   Radius = 0 }
	}
}

local activeGuns = {}
local setupPending = {}
local QueueSetup
local runningGunCount = 0
local SNOW_TEXTURE = "rbxassetid://254854270"

local function GetSnowmakingEfficiency(model, temp)
	if temp <= CONFIG.OptimalTemp then
		return 1.0
	end
	if temp <= CONFIG.FreezingPoint then
		return 0.5
	end
	if model and model:GetAttribute("SnowmakerActive") then
		local clockTime = Lighting.ClockTime
		local isDaytime = clockTime >= 7 and clockTime < 20
		local marginalTemp = isDaytime and CONFIG.MarginalStaffedDayTemp or CONFIG.MarginalStaffedNightTemp
		if temp <= marginalTemp then
			return isDaytime and CONFIG.MarginalStaffedDayEfficiency or CONFIG.MarginalStaffedNightEfficiency
		end
	end
	return 0
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
local TERRAIN_ONLY_PARAMS = RaycastParams.new()
TERRAIN_ONLY_PARAMS.FilterType = Enum.RaycastFilterType.Include
TERRAIN_ONLY_PARAMS.FilterDescendantsInstances = { Workspace.Terrain }

local function SetEmittersEnabled(part, enabled)
	if not part then return end
	for _, child in ipairs(part:GetChildren()) do
		if child:IsA("ParticleEmitter") then
			child.Enabled = enabled
		end
	end
end

local function ConfigureEmitter(emitter, spec)
	emitter.Enabled = true
	emitter.Texture = SNOW_TEXTURE
	emitter.Rate = spec.Rate
	emitter.Speed = spec.Speed
	emitter.Drag = spec.Drag
	emitter.Acceleration = spec.Acceleration
	emitter.Lifetime = spec.Lifetime
	emitter.SpreadAngle = spec.SpreadAngle
	emitter.Size = spec.Size
	emitter.LightEmission = spec.LightEmission
	emitter.Rotation = spec.Rotation
	emitter.RotSpeed = spec.RotSpeed
	emitter.Transparency = spec.Transparency
	emitter.ZOffset = spec.ZOffset
end

local function ConfigureSmoke(smoke, scalar, throwDistance, rateScale)
	if not smoke then
		return
	end
	smoke.Enabled = true
	smoke.Size = math.max(8, (throwDistance / 10) * rateScale)
	smoke.Opacity = math.clamp(0.18 + (0.18 * scalar), 0.12, 0.5)
	smoke.RiseVelocity = math.max(10, (throwDistance * 0.22) + (8 * scalar))
	smoke.TimeScale = math.max(4, 5 + (3 * scalar))
end

local function BuildEmitterSpec(style, scalar, throwDistance, rateScale)
	local baseThrow = math.max(25, throwDistance)
	if style == "Core" then
		return {
			Rate = 54 * scalar * rateScale,
			Speed = NumberRange.new(baseThrow * 0.68, baseThrow * 0.82),
			Drag = 3.1,
			Acceleration = Vector3.new(0, -24, 0),
			Lifetime = NumberRange.new(1.9, 2.8),
			SpreadAngle = Vector2.new(6, 6),
			Size = NumberSequence.new({NumberSequenceKeypoint.new(0, 2.4), NumberSequenceKeypoint.new(1, 5.8)}),
			LightEmission = 0.16,
			Rotation = NumberRange.new(-180, 180),
			RotSpeed = NumberRange.new(-10, 10),
			Transparency = NumberSequence.new({
				NumberSequenceKeypoint.new(0, 0.28),
				NumberSequenceKeypoint.new(0.8, 0.62),
				NumberSequenceKeypoint.new(1, 1),
			}),
			ZOffset = 0.15,
		}
	elseif style == "SkuaCore" then
		return {
			Rate = 30 * scalar * rateScale,
			Speed = NumberRange.new(baseThrow * 0.52, baseThrow * 0.66),
			Drag = 2.1,
			Acceleration = Vector3.new(0, -10, 0),
			Lifetime = NumberRange.new(2.6, 3.4),
			SpreadAngle = Vector2.new(3, 3),
			Size = NumberSequence.new({NumberSequenceKeypoint.new(0, 5.2), NumberSequenceKeypoint.new(1, 7.8)}),
			LightEmission = 0.2,
			Rotation = NumberRange.new(-180, 180),
			RotSpeed = NumberRange.new(-12, 12),
			Transparency = NumberSequence.new({
				NumberSequenceKeypoint.new(0, 0.38),
				NumberSequenceKeypoint.new(0.74, 0.58),
				NumberSequenceKeypoint.new(1, 1),
			}),
			ZOffset = 0.24,
		}
	elseif style == "Cloud" then
		return {
			Rate = 18 * scalar * rateScale,
			Speed = NumberRange.new(baseThrow * 0.34, baseThrow * 0.5),
			Drag = 4.4,
			Acceleration = Vector3.new(0, -10, 0),
			Lifetime = NumberRange.new(2.5, 4.1),
			SpreadAngle = Vector2.new(20, 20),
			Size = NumberSequence.new({NumberSequenceKeypoint.new(0, 5.2), NumberSequenceKeypoint.new(1, 9.2)}),
			LightEmission = 0.1,
			Rotation = NumberRange.new(-180, 180),
			RotSpeed = NumberRange.new(-8, 8),
			Transparency = NumberSequence.new({
				NumberSequenceKeypoint.new(0, 1),
				NumberSequenceKeypoint.new(0.16, 0.7),
				NumberSequenceKeypoint.new(1, 1),
			}),
			ZOffset = 0.8,
		}
	elseif style == "SkuaBridge" then
		return {
			Rate = 20 * scalar * rateScale,
			Speed = NumberRange.new(baseThrow * 0.32, baseThrow * 0.46),
			Drag = 4.1,
			Acceleration = Vector3.new(0, -8, 0),
			Lifetime = NumberRange.new(2.2, 3.1),
			SpreadAngle = Vector2.new(12, 12),
			Size = NumberSequence.new({NumberSequenceKeypoint.new(0, 5.8), NumberSequenceKeypoint.new(1, 8.8)}),
			LightEmission = 0.08,
			Rotation = NumberRange.new(-180, 180),
			RotSpeed = NumberRange.new(-6, 6),
			Transparency = NumberSequence.new({
				NumberSequenceKeypoint.new(0, 0.9),
				NumberSequenceKeypoint.new(0.14, 0.54),
				NumberSequenceKeypoint.new(0.88, 0.72),
				NumberSequenceKeypoint.new(1, 1),
			}),
			ZOffset = 0.96,
		}
	elseif style == "Down" then
		return {
			Rate = 14 * scalar * rateScale,
			Speed = NumberRange.new(baseThrow * 0.22, baseThrow * 0.34),
			Drag = 4.8,
			Acceleration = Vector3.new(0, -42, 0),
			Lifetime = NumberRange.new(1.3, 2.1),
			SpreadAngle = Vector2.new(10, 10),
			Size = NumberSequence.new({NumberSequenceKeypoint.new(0, 2.2), NumberSequenceKeypoint.new(1, 5.2)}),
			LightEmission = 0.08,
			Rotation = NumberRange.new(-180, 180),
			RotSpeed = NumberRange.new(-6, 6),
			Transparency = NumberSequence.new({
				NumberSequenceKeypoint.new(0, 0.3),
				NumberSequenceKeypoint.new(0.7, 0.62),
				NumberSequenceKeypoint.new(1, 1),
			}),
			ZOffset = 0.55,
		}
	elseif style == "SkuaTail" then
		return {
			Rate = 10 * scalar * rateScale,
			Speed = NumberRange.new(baseThrow * 0.18, baseThrow * 0.28),
			Drag = 5.1,
			Acceleration = Vector3.new(0, -32, 0),
			Lifetime = NumberRange.new(1.5, 2.3),
			SpreadAngle = Vector2.new(14, 14),
			Size = NumberSequence.new({NumberSequenceKeypoint.new(0, 3.4), NumberSequenceKeypoint.new(1, 5.8)}),
			LightEmission = 0.06,
			Rotation = NumberRange.new(-180, 180),
			RotSpeed = NumberRange.new(-5, 5),
			Transparency = NumberSequence.new({
				NumberSequenceKeypoint.new(0, 0.36),
				NumberSequenceKeypoint.new(0.68, 0.62),
				NumberSequenceKeypoint.new(1, 1),
			}),
			ZOffset = 0.48,
		}
	elseif style == "Mist" then
		return {
			Rate = 8 * scalar * rateScale,
			Speed = NumberRange.new(baseThrow * 0.16, baseThrow * 0.26),
			Drag = 5.2,
			Acceleration = Vector3.new(0, -4, 0),
			Lifetime = NumberRange.new(2.6, 3.8),
			SpreadAngle = Vector2.new(28, 28),
			Size = NumberSequence.new({NumberSequenceKeypoint.new(0, 6.5), NumberSequenceKeypoint.new(1, 11)}),
			LightEmission = 0.04,
			Rotation = NumberRange.new(-180, 180),
			RotSpeed = NumberRange.new(-4, 4),
			Transparency = NumberSequence.new({
				NumberSequenceKeypoint.new(0, 0.92),
				NumberSequenceKeypoint.new(0.22, 0.78),
				NumberSequenceKeypoint.new(1, 1),
			}),
			ZOffset = 1.2,
		}
	end
	return BuildEmitterSpec("Mist", scalar, throwDistance, rateScale)
end

-- // ☁️ REALISTIC BLENDING UPDATE //
local function UpdateEmitters(data, settings)
	local rig = data.Rig
	if not rig then return end

	if data.State == "Off" then
		SnowGunShared.SetVisualEffectsEnabled(rig, false)
		return
	end

	SnowGunShared.SetVisualEffectsEnabled(rig, true)

	local scalar = settings.SpeedScalar
	local profile = data.Profile or SnowGunShared.GetProfile(data.ModelName)
	local throwDistance = profile.ThrowDistance or 80
	local rateScale = profile.EmitterRateScale or 1

	if rig.EmitterMode == "Nozzle" and rig.Nozzle then
		local nozzle = rig.Nozzle
		local core = nozzle:FindFirstChild("Core")
		if core then
			ConfigureEmitter(core, BuildEmitterSpec("Core", scalar, throwDistance, rateScale))
		end
		local cloud = nozzle:FindFirstChild("Cloud")
		if cloud then
			ConfigureEmitter(cloud, BuildEmitterSpec("Cloud", scalar, throwDistance, rateScale))
		end
		local mist = nozzle:FindFirstChild("Mist")
		if mist then
			ConfigureEmitter(mist, BuildEmitterSpec("Mist", scalar, throwDistance, rateScale))
		end
		return
	end

	for _, emitterPart in ipairs(rig.Emitters) do
		local style = "Mist"
		if data.ModelName == "Skua-30" or data.ModelName == "Stoat-6" or data.ModelName == "Stoat-10" then
			if emitterPart.Name == "SkuaSnowLong" or emitterPart.Name == "StoatSnowLong" then
				style = "SkuaCore"
			elseif emitterPart.Name == "SnowHead" then
				style = "SkuaBridge"
			elseif emitterPart.Name == "SkuaSnowDown" or emitterPart.Name == "StoatSnowDown" then
				style = "SkuaTail"
			end
		elseif emitterPart.Name == "SnowC" or emitterPart.Name == "SkuaSnowLong" or emitterPart.Name == "StoatSnowLong" or emitterPart.Name == "SnowMaker" then
			style = "Core"
		elseif emitterPart.Name == "SkuaSnowDown" or emitterPart.Name == "StoatSnowDown" then
			style = "Down"
		else
			style = "Mist"
		end
		for _, emitter in ipairs(emitterPart:GetChildren()) do
			if emitter:IsA("ParticleEmitter") then
				ConfigureEmitter(emitter, BuildEmitterSpec(style, scalar, throwDistance, rateScale))
			elseif emitter:IsA("Smoke") then
				ConfigureSmoke(emitter, scalar, throwDistance, rateScale)
			end
		end
	end
end

local function SetGunState(model, newState)
	local data = activeGuns[model]
	newState = normalizeState(newState)
	model:SetAttribute("State", newState)
	if not data then
		if model and model.Parent then
			QueueSetup(model)
		end
		return
	end
	if data.State == newState then return end
	data.State = newState

	local settings = CONFIG.IntensitySettings[newState]
	UpdateEmitters(data, settings)

	local wasRunning = data.IsRunning == true
	local nowRunning = newState ~= "Off"
	data.IsRunning = nowRunning
	if wasRunning ~= nowRunning then
		if nowRunning then
			runningGunCount += 1
		else
			runningGunCount = math.max(0, runningGunCount - 1)
		end
	end
	if not nowRunning then
		if data.Sounds.Run then TweenService:Create(data.Sounds.Run, TweenInfo.new(1), {Volume = 0}):Play() end
		if data.Sounds.Water then TweenService:Create(data.Sounds.Water, TweenInfo.new(1), {Volume = 0}):Play() end
	else
		if data.Sounds.Run then 
			data.Sounds.Run.Volume = CONFIG.BaseVolume; data.Sounds.Run.PlaybackSpeed = settings.SoundPitch; if not data.Sounds.Run.IsPlaying then data.Sounds.Run:Play() end
		end
		if data.Sounds.Water then
			data.Sounds.Water.Volume = CONFIG.WaterVolume; data.Sounds.Water.PlaybackSpeed = settings.SoundPitch; if not data.Sounds.Water.IsPlaying then data.Sounds.Water:Play() end
		end
	end
end

GunInteractEvent.OnServerEvent:Connect(function(player, action, args)
	if action == "SetState" and args.Model and args.State then SetGunState(args.Model, args.State) end
end)

local function SetupGun(model)
	if activeGuns[model] or not model or not model.Parent then return true end
	SnowGunShared.PrepareModel(model)

	local rig = SnowGunShared.ResolveRig(model)
	local baseCFrame = SnowGunShared.GetBaseCFrame(rig)
	if not rig or not baseCFrame then return false end
	if rig.EmitterMode == "None" then return false end

	SnowGunShared.ApplyConfiguredEmissionDirections(rig)

	if rig.EmitterMode == "Nozzle" and rig.Nozzle and rig.PivotPart then
		local existingWeld = rig.Nozzle:FindFirstChild("SnowGunNozzleWeld")
		if not existingWeld then
			local weld = Instance.new("WeldConstraint")
			weld.Name = "SnowGunNozzleWeld"
			weld.Part0 = rig.PivotPart
			weld.Part1 = rig.Nozzle
			weld.Parent = rig.PivotPart
		end
		rig.Nozzle.Anchored = true
		rig.Nozzle.CanCollide = false
	end

	SnowGunShared.ApplyYawOffset(rig, baseCFrame, 0)
	local sprayDirection = SnowGunShared.GetSprayDirectionWorld(rig)
	local directionLocal = sprayDirection and baseCFrame:VectorToObjectSpace(sprayDirection.Unit) or Vector3.new(0, 0, -1)

	local initialState = normalizeState(model:GetAttribute("State"))

	activeGuns[model] = {
		Rig = rig,
		PivotPart = rig.PivotPart,
		Sounds = {
			Run = rig.RunSound,
			Water = rig.WaterSound,
			Compressor = rig.CompressorSound,
			Pressure = rig.PressureSound,
		},
		BaseCFrame = baseCFrame,
		DirectionLocal = directionLocal,
		State = initialState,
		IsRunning = initialState ~= "Off",
		LastTerrainUpdate = tick(),
		OwnerId = model:GetAttribute("Owner"),
		Profile = rig.Profile,
		ModelName = model.Name,
	}
	model:SetAttribute("State", initialState)
	UpdateEmitters(activeGuns[model], CONFIG.IntensitySettings[initialState])
	if initialState ~= "Off" then
		runningGunCount += 1
		if rig.RunSound then
			rig.RunSound.Volume = CONFIG.BaseVolume
			rig.RunSound.PlaybackSpeed = CONFIG.IntensitySettings[initialState].SoundPitch
			if not rig.RunSound.IsPlaying then rig.RunSound:Play() end
		end
		if rig.WaterSound then
			rig.WaterSound.Volume = CONFIG.WaterVolume
			rig.WaterSound.PlaybackSpeed = CONFIG.IntensitySettings[initialState].SoundPitch
			if not rig.WaterSound.IsPlaying then rig.WaterSound:Play() end
		end
	end
	return true
end

QueueSetup = function(model, attempt)
	if activeGuns[model] or not model or not model.Parent then
		setupPending[model] = nil
		return
	end
	attempt = attempt or 1
	if setupPending[model] and setupPending[model] >= attempt then
		return
	end
	setupPending[model] = attempt
	task.delay(attempt == 1 and 0 or 0.25, function()
		if activeGuns[model] or not model or not model.Parent then
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

-- UPKEEP
task.spawn(function()
	while true do
		task.wait(CONFIG.UpkeepInterval)
		local costs = {}
		for model, data in pairs(activeGuns) do
			if data.IsRunning and data.OwnerId then
				local upkeepScale = (data.Profile and data.Profile.UpkeepMultiplier) or 1
				local costReduction = math.clamp(tonumber(model:GetAttribute("SnowCostReduction")) or 0, 0, 0.75)
				local upkeepCost = math.max(0, math.floor(((CONFIG.IntensitySettings[data.State].Cost * upkeepScale) * (1 - costReduction)) + 0.5))
				costs[data.OwnerId] = (costs[data.OwnerId] or 0) + upkeepCost
			end
		end
		local MoneySystem = ServerScriptService:FindFirstChild("MoneyServer", true)
		if MoneySystem and MoneySystem:FindFirstChild("RequestTransaction") then
			for uid, cost in pairs(costs) do local p = Players:GetPlayerByUserId(uid); if p then MoneySystem.RequestTransaction:Invoke(p, cost, "SnowGunUpkeep", Enum.AnalyticsEconomyTransactionType.Gameplay) end end
		end
	end
end)

-- Cache magic carpet exclusion zones so snow doesn't paint over them
local carpetExclusions = {}
local lastCarpetScan = 0
local CARPET_SCAN_INTERVAL = 10

local function refreshCarpetExclusions()
	local now = tick()
	if now - lastCarpetScan < CARPET_SCAN_INTERVAL then return end
	lastCarpetScan = now
	local newExclusions = {}
	local placed = Workspace:FindFirstChild("PlacedObjects")
	if placed then
		for _, obj in ipairs(placed:GetChildren()) do
			if obj:GetAttribute("Type") == "Carpet" then
				local cf, size = obj:GetBoundingBox()
				-- Add padding around carpet to prevent snow from visually covering it
				table.insert(newExclusions, {
					Center = cf.Position,
					HalfX = size.X / 2 + 4,
					HalfZ = size.Z / 2 + 4,
				})
			end
		end
	end
	carpetExclusions = newExclusions
end

local function isInCarpetZone(x, z)
	for _, zone in ipairs(carpetExclusions) do
		if math.abs(x - zone.Center.X) < zone.HalfX and math.abs(z - zone.Center.Z) < zone.HalfZ then
			return true
		end
	end
	return false
end

local function paintTopTerrainSnow(centerPos, radius, fullCoverage)
	refreshCarpetExclusions()
	local region = Region3.new(centerPos - Vector3.new(radius, 10, radius), centerPos + Vector3.new(radius, 10, radius)):ExpandToGrid(4)
	local materials, occupancy = Workspace.Terrain:ReadVoxels(region, 4)
	local modified = false

	for x = 1, materials.Size.X do
		for z = 1, materials.Size.Z do
			local voxelPos = region.CFrame.Position + Vector3.new((x-1)*4 - region.Size.X/2 + 2, 0, (z-1)*4 - region.Size.Z/2 + 2)
			-- Skip voxels inside magic carpet exclusion zones
			if isInCarpetZone(voxelPos.X, voxelPos.Z) then continue end
			local normalized = (Vector3.new(voxelPos.X, centerPos.Y, voxelPos.Z) - centerPos).Magnitude / math.max(radius, 1)
			if normalized <= 1 then
				local coverage = 1 - math.clamp(normalized, 0, 1)
				local shouldPaint = fullCoverage and coverage > 0.04 or coverage > 0.18
				if shouldPaint then
					for y = materials.Size.Y, 1, -1 do
						if occupancy[x][y][z] > 0 then
							if materials[x][y][z] ~= Enum.Material.Snow then
								materials[x][y][z] = Enum.Material.Snow
								modified = true
							end
							break
						end
					end
				end
			end
		end
	end

	if modified then
		Workspace.Terrain:WriteVoxels(region, 4, materials, occupancy)
	end
end

local function paintTerrainAlongPath(startPos, endPos, startRadius, endRadius, samples)
	for i = 0, math.max(1, samples - 1) do
		local alpha = samples <= 1 and 1 or (i / (samples - 1))
		local probePos = startPos:Lerp(endPos, alpha)
		local probeResult = Workspace:Raycast(probePos + Vector3.new(0, 64, 0), Vector3.new(0, -220, 0), TERRAIN_ONLY_PARAMS)
		if probeResult then
			local radius = startRadius + ((endRadius - startRadius) * alpha)
			paintTopTerrainSnow(probeResult.Position, radius, true)
		end
	end
end

-- 🎨 PAINTING LOOP (PERF: skip entire loop when no guns running or temp above freezing)
RunService.Heartbeat:Connect(function(dt)
	local now = tick()
	local temp = Lighting:GetAttribute("Temperature") or 32

	-- Short-circuit: skip iteration entirely when no guns are running
	if runningGunCount == 0 then return end

	for model, data in pairs(activeGuns) do
		if not model.Parent then activeGuns[model] = nil; continue end
		if not data.LastTerrainUpdate then data.LastTerrainUpdate = now end

		local eff = GetSnowmakingEfficiency(model, temp)
		if data.IsRunning and eff > 0 then
			local s = CONFIG.IntensitySettings[data.State]
			local staffEfficiency = 1 + math.max(0, tonumber(model:GetAttribute("SnowStaffEfficiency")) or 0)
			local coverageBonus = 1 + math.max(0, tonumber(model:GetAttribute("SnowCoverageBonus")) or 0)
			local intensityBonus = 1 + math.max(0, tonumber(model:GetAttribute("SnowmakerIntensityBonus")) or 0)
			if (now - data.LastTerrainUpdate > CONFIG.UpdateInterval / math.max(0.05, (eff * staffEfficiency))) then
				data.LastTerrainUpdate = now

				local profile = data.Profile or SnowGunShared.GetProfile(data.ModelName)
				local throwDist = (profile.ThrowDistance or 80) * s.SpeedScalar * intensityBonus
				local oscillationAngle = math.rad(profile.OscillationAngle or CONFIG.OscillationAngle)
				local angle = math.sin(time() * s.OscillationSpeed) * oscillationAngle
				local virtualCFrame = SnowGunShared.GetOscillatedBaseCFrame(data.Rig, data.BaseCFrame, angle)
				local directionLocal = data.DirectionLocal or Vector3.new(0, 0, -1)
				local lookDir = virtualCFrame:VectorToWorldSpace(directionLocal).Unit

				local drop = Vector3.new(0, -30 * s.SpeedScalar, 0)
				local impactOrigin = data.BaseCFrame.Position + (lookDir * throwDist) + drop + Vector3.new(0, 50, 0)
				local res = Workspace:Raycast(impactOrigin, Vector3.new(0, -320, 0), TERRAIN_ONLY_PARAMS)

				if res then
					local centerPos = res.Position
					local radius = math.max(8, s.Radius * (profile.RadiusMultiplier or 1) * coverageBonus)
					if data.ModelName == "Skua-30" then
						local plumeStart = data.BaseCFrame.Position + (lookDir * math.max(14, throwDist * 0.18))
						paintTerrainAlongPath(plumeStart, centerPos, math.max(5, radius * 0.22), radius * 0.72, 5)
					end
					paintTopTerrainSnow(centerPos, radius, true)
				end
			end
		end
	end
end)

local function scanContainer(container)
	if not container then
		return
	end
	for _, child in ipairs(container:GetChildren()) do
		if SnowGunShared.IsSnowGunName(child.Name) then
			QueueSetup(child)
		end
	end
end

local function Check()
_G.SnowmakingRuntime = _G.SnowmakingRuntime or {}
_G.SnowmakingRuntime.SetGunState = SetGunState
_G.SnowmakingRuntime.QueueSetup = QueueSetup
	scanContainer(PLACED_FOLDER)
	scanContainer(Workspace)
end
PLACED_FOLDER.ChildAdded:Connect(function(child)
	if SnowGunShared.IsSnowGunName(child.Name) then
		QueueSetup(child)
	end
end)
Workspace.ChildAdded:Connect(function(child)
	if child ~= PLACED_FOLDER and SnowGunShared.IsSnowGunName(child.Name) then
		QueueSetup(child)
	end
end)
Check()