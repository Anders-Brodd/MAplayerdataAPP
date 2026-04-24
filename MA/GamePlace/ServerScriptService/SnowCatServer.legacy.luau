--[[
	SnowcatServer.lua — Prinoth Bison (Server) — V3
	─────────────────────────────────────────────────
	FIX: On dismount, save position above terrain.
	     On player leave, keep snowcat elevated.
	     Periodic idle check lifts parked snowcats out of terrain.
	     Grooming now skips terrain directly under parked snowcats.
]]
local Players = game:GetService("Players")
local ServerStorage = game:GetService("ServerStorage")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local RunService = game:GetService("RunService")

----------------------------------------------------------------
-- REMOTE EVENTS
----------------------------------------------------------------
local function getOrCreate(className, name, parent)
	local obj = parent:FindFirstChild(name)
	if not obj then
		obj = Instance.new(className)
		obj.Name = name
		obj.Parent = parent
	end
	return obj
end

local BisonEvents = getOrCreate("Folder", "BisonEvents", ReplicatedStorage)
local CFrameUpdate  = getOrCreate("UnreliableRemoteEvent", "BisonCFrame", BisonEvents)
local MountEvent    = getOrCreate("RemoteEvent", "BisonMount", BisonEvents)
local DismountEvent = getOrCreate("RemoteEvent", "BisonDismount", BisonEvents)
local GroomEvent    = getOrCreate("RemoteEvent", "BisonGroom", BisonEvents)
local ProgressEvent = getOrCreate("RemoteEvent", "GroomProgress", BisonEvents)

----------------------------------------------------------------
-- ACTIVE BISONS
----------------------------------------------------------------
local ActiveBisons = {} -- [model] = { driver, frame, groundOffset }
local CachedSlopeEntries = {}
local lastSlopeCacheRebuild = 0
local SLOPE_CACHE_REBUILD_INTERVAL = 5

local function getSlopeContainer()
	return workspace:FindFirstChild("PlacedObjects") or workspace:FindFirstChild("Slopes")
end

local function rebuildSlopeCache(force)
	local now = os.clock()
	if not force and (now - lastSlopeCacheRebuild) < SLOPE_CACHE_REBUILD_INTERVAL then
		return CachedSlopeEntries
	end
	lastSlopeCacheRebuild = now
	table.clear(CachedSlopeEntries)
	local slopeFolder = getSlopeContainer()
	if not slopeFolder then
		return CachedSlopeEntries
	end
	for _, slope in ipairs(slopeFolder:GetChildren()) do
		if (slope:IsA("Model") or slope:IsA("Folder")) and slope:GetAttribute("Type") == "Slope" then
			local ok, cf, size = pcall(function()
				local boxCF, boxSize = slope:GetBoundingBox()
				return boxCF, boxSize
			end)
			if ok and cf and size then
				local planarRadius = math.max(25, math.sqrt((size.X * 0.5) ^ 2 + (size.Z * 0.5) ^ 2) + 12)
				table.insert(CachedSlopeEntries, {
					model = slope,
					center = cf.Position,
					radius = planarRadius,
				})
			end
		end
	end
	return CachedSlopeEntries
end

----------------------------------------------------------------
-- TERRAIN-SAFE POSITIONING
-- Raycasts down from the snowcat and lifts it above ground if sunk.
----------------------------------------------------------------
local idleRayParams = RaycastParams.new()
idleRayParams.FilterType = Enum.RaycastFilterType.Exclude

local function liftAboveGround(model, data)
	if not model or not model.PrimaryPart then return end
	if data.driver then return end -- Don't interfere while someone is driving

	local frame = data.frame
	if not frame then return end

	-- Compute ground offset from track parts (same logic as client)
	local pivotY = frame.Position.Y
	local lowestTrackY = math.huge
	local foundTracks = false

	-- Search for wheel/track groups
	for _, part in pairs(model:GetDescendants()) do
		if part:IsA("BasePart") then
			local nameUpper = part.Name:upper()
			local parentName = part.Parent and part.Parent.Name:upper() or ""
			if parentName:find("WHEEL") or nameUpper:find("TRACK") or nameUpper:find("TREAD") or nameUpper:find("BOGIE") then
				local bot = part.Position.Y - part.Size.Y / 2
				if bot < lowestTrackY then lowestTrackY = bot end
				foundTracks = true
			end
		end
	end

	if not foundTracks then
		-- Fallback: use stored attribute
		local serverBottom = model:GetAttribute("BottomY")
		if serverBottom then
			lowestTrackY = serverBottom + 2 -- +2 to avoid blade
		else
			return -- Can't determine, skip
		end
	end

	local trackOffset = (pivotY - lowestTrackY) + 0.15
	if trackOffset < 1 then trackOffset = 1 end

	-- Raycast down to find ground
	idleRayParams.FilterDescendantsInstances = {model}
	local ray = workspace:Raycast(
		frame.Position + Vector3.new(0, 50, 0),
		Vector3.new(0, -120, 0),
		idleRayParams
	)

	if ray then
		local idealY = ray.Position.Y + trackOffset
		local currentY = frame.Position.Y
		-- If sunk more than 1 stud below ideal, or floating more than 10 studs, correct
		if currentY < idealY - 0.5 then
			local newCF = model:GetPivot() + Vector3.new(0, idealY - currentY, 0)
			model:PivotTo(newCF)
		end
	end
end

----------------------------------------------------------------
-- SETUP
----------------------------------------------------------------
local function SetupBison(model)
	if model:GetAttribute("BisonRigged") then return end
	model:SetAttribute("BisonRigged", true)

	local frame = nil
	for _, desc in pairs(model:GetDescendants()) do
		if desc:IsA("BasePart") and desc.Name == "SnowcatFrame" then
			frame = desc; break
		end
	end
	if not frame then
		frame = model.PrimaryPart or model:FindFirstChildWhichIsA("BasePart", true)
	end
	if not frame then return end
	model.PrimaryPart = frame

	local count = 0
	for _, part in pairs(model:GetDescendants()) do
		if part:IsA("BasePart") and part ~= frame then
			local weld = Instance.new("WeldConstraint")
			weld.Part0 = frame
			weld.Part1 = part
			weld.Parent = frame
			part.Anchored = true
			part.CanCollide = false
			count += 1
		end
	end
	frame.Anchored = true
	frame.CanCollide = false

	-- Store bounds
	local lowestY = math.huge
	for _, part in pairs(model:GetDescendants()) do
		if part:IsA("BasePart") then
			local bot = part.Position.Y - part.Size.Y / 2
			if bot < lowestY then lowestY = bot end
		end
	end
	model:SetAttribute("PivotY", frame.Position.Y)
	model:SetAttribute("BottomY", lowestY)

	-- ProximityPrompt
	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "MountPrompt"
	prompt.ActionText = "Drive"
	prompt.ObjectText = "Prinoth Bison"
	prompt.MaxActivationDistance = 15
	prompt.HoldDuration = 0.3
	prompt.RequiresLineOfSight = false
	prompt.Parent = frame

	CollectionService:AddTag(model, "BisonVehicle")
	ActiveBisons[model] = { driver = nil, frame = frame }
	model:SetAttribute("PlayerDriving", false)
	model:SetAttribute("DriverUserId", 0)
	if model:GetAttribute("AIControlled") == nil then
		model:SetAttribute("AIControlled", false)
	end

	-- Mount handler
	prompt.Triggered:Connect(function(player)
		local data = ActiveBisons[model]
		if not data then return end
		if data.driver == nil then
			data.driver = player
			model:SetAttribute("PlayerDriving", true)
			model:SetAttribute("DriverUserId", player.UserId)

			local char = player.Character
			if char then
				local hum = char:FindFirstChildOfClass("Humanoid")
				local hrp = char:FindFirstChild("HumanoidRootPart")
				if hum and hrp then
					hum.PlatformStand = true
					hrp.Anchored = true
					hrp.CFrame = frame.CFrame * CFrame.new(0, 3, 0)
					local w = Instance.new("WeldConstraint")
					w.Name = "BisonCharWeld"
					w.Part0 = frame
					w.Part1 = hrp
					w.Parent = frame
				end
			end

			MountEvent:FireAllClients(model, player, true)
			prompt.Enabled = false
		end
	end)

	-- Initial terrain check: make sure the snowcat isn't sunk on spawn/restore
	task.delay(3, function()
		if ActiveBisons[model] then
			liftAboveGround(model, ActiveBisons[model])
		end
	end)
end

----------------------------------------------------------------
-- DISMOUNT
----------------------------------------------------------------
DismountEvent.OnServerEvent:Connect(function(player)
	for model, data in pairs(ActiveBisons) do
		if data.driver == player then
			data.driver = nil
			model:SetAttribute("PlayerDriving", false)
			model:SetAttribute("DriverUserId", 0)

			local char = player.Character
			if char then
				local hum = char:FindFirstChildOfClass("Humanoid")
				local hrp = char:FindFirstChild("HumanoidRootPart")
				if hum and hrp then
					local w = data.frame:FindFirstChild("BisonCharWeld")
					if w then w:Destroy() end
					hum.PlatformStand = false
					hrp.Anchored = false
					hrp.CFrame = data.frame.CFrame * CFrame.new(-10, 5, 0)
				end
			end

			local prompt = data.frame:FindFirstChild("MountPrompt")
			if prompt then prompt.Enabled = true end
			MountEvent:FireAllClients(model, player, false)

			-- After dismount, ensure snowcat is above terrain
			-- and restore groomed terrain (Salt→Snow) underneath to prevent craters
			task.delay(0.5, function()
				if ActiveBisons[model] then
					liftAboveGround(model, ActiveBisons[model])
					-- Restore terrain under the snowcat
					local pos = data.frame.Position
					local region = Region3.new(
						Vector3.new(pos.X - 18, pos.Y - 12, pos.Z - 18),
						Vector3.new(pos.X + 18, pos.Y + 4, pos.Z + 18)
					):ExpandToGrid(4)
					workspace.Terrain:ReplaceMaterial(region, 4, Enum.Material.Salt, Enum.Material.Snow)
				end
			end)

			break
		end
	end
end)

----------------------------------------------------------------
-- CFRAME REPLICATION
-- PERF FIX: Don't call PivotTo on the server — this replicates
-- anchored-part CFrames back to the driving client, causing
-- 20Hz flicker/stutter. Instead, just store the latest CFrame
-- and relay to other clients. Grooming already uses paintCenter.
----------------------------------------------------------------
CFrameUpdate.OnServerEvent:Connect(function(player, model, cf)
	if not model or not model:IsA("Model") then return end
	local data = ActiveBisons[model]
	if not data or data.driver ~= player then return end
	-- Store latest CFrame for server-side queries (idle checks, etc)
	data.lastCF = cf
	for _, p in ipairs(Players:GetPlayers()) do
		if p ~= player then
			CFrameUpdate:FireClient(p, model, cf)
		end
	end
end)

----------------------------------------------------------------
-- CLEANUP
----------------------------------------------------------------
Players.PlayerRemoving:Connect(function(player)
	for model, data in pairs(ActiveBisons) do
		if data.driver == player then
			data.driver = nil
			model:SetAttribute("PlayerDriving", false)
			model:SetAttribute("DriverUserId", 0)
			local w = data.frame:FindFirstChild("BisonCharWeld")
			if w then w:Destroy() end
			local prompt = data.frame:FindFirstChild("MountPrompt")
			if prompt then prompt.Enabled = true end
			MountEvent:FireAllClients(model, player, false)

			-- Lift above ground after player leaves
			task.delay(1, function()
				if ActiveBisons[model] then
					liftAboveGround(model, ActiveBisons[model])
				end
			end)
		end
	end
end)

----------------------------------------------------------------
-- IDLE SNOWCAT TERRAIN CHECK (every 30 seconds)
-- Prevents parked snowcats from sinking due to terrain changes,
-- grooming, or terrain streaming.
----------------------------------------------------------------
task.spawn(function()
	while true do
		task.wait(30)
		for model, data in pairs(ActiveBisons) do
			if not data.driver then
				pcall(function()
					liftAboveGround(model, data)
				end)
			end
		end
	end
end)

----------------------------------------------------------------
-- AUTO-RIG
----------------------------------------------------------------
task.wait(2)
for _, m in pairs(workspace:GetDescendants()) do
	if m:IsA("Model") and (m.Name == "Prinoth Bison" or m.Name == "Prinoth Leitwolf" or m.Name == "Snowcat") then
		SetupBison(m)
	end
end

workspace.DescendantAdded:Connect(function(d)
	if d:IsA("Model") and (d.Name == "Prinoth Bison" or d.Name == "Prinoth Leitwolf" or d.Name == "Snowcat") then
		task.delay(0.5, function() SetupBison(d) end)
	end
end)

----------------------------------------------------------------
-- GROOMING
----------------------------------------------------------------
local lastGroomTime = {}

GroomEvent.OnServerEvent:Connect(function(player, groomCF, groomSize)
	local now = tick()
	local last = lastGroomTime[player] or 0
	if now - last < 0.35 then return end
	lastGroomTime[player] = now

	local isDriving = false
	for _, data in pairs(ActiveBisons) do
		if data.driver == player then isDriving = true; break end
	end
	if not isDriving then return end

	if typeof(groomCF) ~= "CFrame" or typeof(groomSize) ~= "Vector3" then return end
	if math.max(groomSize.X, groomSize.Y, groomSize.Z) > 30 then return end

	-- Check if any PARKED snowcat is within the groom zone.
	-- If so, skip grooming to prevent digging holes under idle snowcats.
	local groomPos = groomCF.Position
	for model, data in pairs(ActiveBisons) do
		if not data.driver and data.frame then
			local dist = (data.frame.Position - groomPos).Magnitude
			if dist < 25 then -- PATCHED: was 15, enlarged to prevent craters around parked snowcats
				return -- Don't groom under a parked snowcat
			end
		end
	end

	local halfSize = groomSize / 2
	local p1 = groomCF.Position - halfSize
	local p2 = groomCF.Position + halfSize
	local min = Vector3.new(math.min(p1.X, p2.X), math.min(p1.Y, p2.Y), math.min(p1.Z, p2.Z))
	local max = Vector3.new(math.max(p1.X, p2.X), math.max(p1.Y, p2.Y), math.max(p1.Z, p2.Z))
	local region = Region3.new(min, max):ExpandToGrid(4)

	workspace.Terrain:ReplaceMaterial(region, 4, Enum.Material.Snow, Enum.Material.Salt)
	workspace.Terrain:SetMaterialColor(Enum.Material.Salt, Color3.fromRGB(235, 253, 255))

	local highestGroom = nil
	local groomedName = nil
	local closestSlope = nil
	local closestDist = math.huge
	for _, entry in ipairs(rebuildSlopeCache(false)) do
		local slope = entry.model
		if slope and slope.Parent then
			local planarDist = (Vector3.new(entry.center.X, 0, entry.center.Z) - Vector3.new(groomPos.X, 0, groomPos.Z)).Magnitude
			if planarDist <= entry.radius and planarDist < closestDist then
				closestSlope = slope
				closestDist = planarDist
			end
		end
	end
	if closestSlope then
		local current = closestSlope:GetAttribute("GroomLevel") or 0
		local newLevel = math.min(100, current + 0.4)
		closestSlope:SetAttribute("GroomLevel", newLevel)
		highestGroom = newLevel
		groomedName = closestSlope.Name
	end

	if player and highestGroom then
		ProgressEvent:FireClient(player, groomedName, highestGroom)
	end
end)

----------------------------------------------------------------
-- GROOMING DECAY
----------------------------------------------------------------
task.spawn(function()
	while true do
		task.wait(30)
		for _, entry in ipairs(rebuildSlopeCache(false)) do
			local slope = entry.model
			if slope and slope.Parent then
				local current = slope:GetAttribute("GroomLevel") or 0
				if current > 0 then
					slope:SetAttribute("GroomLevel", math.max(0, current - 1))
				end
			end
		end
	end
end)

Players.PlayerRemoving:Connect(function(player)
	lastGroomTime[player] = nil
end)