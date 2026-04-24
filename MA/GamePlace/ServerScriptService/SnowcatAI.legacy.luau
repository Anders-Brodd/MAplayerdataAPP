--[=[
	PATH: ServerScriptService/SnowcatAI | TYPE: Script
	────────────────────────────────────────────
	AI GROOMER SYSTEM V1.0
	
	When a Groomer employee is hired, this script:
	1. Finds an unoccupied Prinoth Bison in workspace
	2. Drives it along slope paths autonomously 
	3. Prioritizes slopes with lowest GroomLevel
	4. Simulates tiller grooming (fires GroomEvent equivalent)
	5. Replicates movement to all clients for smooth visuals
	
	The AI uses the same CFrame-based movement as the player driver,
	and the same terrain grooming logic from SnowcatServer.
]=]--

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")

----------------------------------------------------------------
-- REMOTES (reuse from SnowcatServer)
----------------------------------------------------------------
local BisonEvents = ReplicatedStorage:WaitForChild("BisonEvents", 10)
local CFrameUpdate = BisonEvents and BisonEvents:FindFirstChild("BisonCFrame")

----------------------------------------------------------------
-- CONFIG
----------------------------------------------------------------
local AI_SPEED = 8           -- studs/sec (F2 working speed)
local AI_TURN_RATE = 0.8     -- rad/sec max turn
local GROOM_INTERVAL = 0.15  -- How often to groom terrain (seconds)
local GROOM_WIDTH = 28       -- Groom swath width (studs)
local GROOM_DEPTH = 4        -- Groom vertical depth
local WAYPOINT_REACH = 10    -- How close to get before next waypoint
local SLOPE_SCAN_INTERVAL = 15 -- Re-evaluate which slope needs grooming
local IDLE_AT_BASE_TIME = 5  -- Wait before heading to next slope

----------------------------------------------------------------
-- STATE
----------------------------------------------------------------
local ActiveAIGroomers = {} -- [employeeId] = { model, slopeTarget, state, ... }
local SlopeWaypointCache = setmetatable({}, { __mode = "k" })
local GroundRayParams = RaycastParams.new()
GroundRayParams.FilterType = Enum.RaycastFilterType.Include
GroundRayParams.FilterDescendantsInstances = {workspace.Terrain}

local function isBisonModel(model)
	return model
		and model:IsA("Model")
		and (model.Name == "Prinoth Bison" or model.Name == "Prinoth Leitwolf" or model.Name == "Snowcat")
end

----------------------------------------------------------------
-- HELPERS
----------------------------------------------------------------
local function getSlopesByNeed(ownerId)
	local slopeFolder = workspace:FindFirstChild("Slopes")
	if not slopeFolder then return {} end

	local slopes = {}
	for _, slope in ipairs(slopeFolder:GetChildren()) do
		if slope:IsA("Model") or slope:IsA("Folder") then
			local slopeOwner = tonumber(slope:GetAttribute("OwnerId")) or tonumber(slope:GetAttribute("PlacedByUserId")) or tonumber(slope:GetAttribute("Owner"))
			if ownerId == nil or slopeOwner == nil or slopeOwner == ownerId then
				local groomLevel = slope:GetAttribute("GroomLevel") or 0
				table.insert(slopes, { model = slope, groomLevel = groomLevel })
			end
		end
	end

	-- Sort by lowest grooming first (most in need)
	table.sort(slopes, function(a, b) return a.groomLevel < b.groomLevel end)
	return slopes
end

local function getObjectOwnerId(model)
	return tonumber(model:GetAttribute("OwnerId"))
		or tonumber(model:GetAttribute("Owner"))
		or tonumber(model:GetAttribute("PlacedByUserId"))
		or tonumber(model:GetAttribute("EmployeeOwnerId"))
		or tonumber(model:GetAttribute("AIOwnerId"))
end

local function isBisonPlayerOccupied(model)
	if model:GetAttribute("PlayerDriving") == true then
		return true
	end
	local driverUserId = tonumber(model:GetAttribute("DriverUserId")) or 0
	if driverUserId > 0 then
		return true
	end
	local frame = model.PrimaryPart
	local prompt = frame and frame:FindFirstChild("MountPrompt")
	if prompt and prompt:IsA("ProximityPrompt") and prompt.Enabled == false and model:GetAttribute("AIControlled") ~= true then
		return true
	end
	return false
end

local function isBisonOwnerCompatible(model, ownerId)
	local bisonOwnerId = getObjectOwnerId(model)
	return ownerId == nil or bisonOwnerId == nil or bisonOwnerId == ownerId
end

local function findAvailableBison(ownerId)
	local function pickFrom(list, requireExactOwner)
		for _, model in ipairs(list) do
			if isBisonModel(model)
				and model.PrimaryPart
				and model:GetAttribute("AIControlled") ~= true
				and not isBisonPlayerOccupied(model)
				and isBisonOwnerCompatible(model, ownerId) then
				local bisonOwnerId = getObjectOwnerId(model)
				if not requireExactOwner or ownerId == nil or bisonOwnerId == ownerId then
					return model
				end
			end
		end
		return nil
	end

	local tagged = CollectionService:GetTagged("BisonVehicle")
	if #tagged > 0 then
		local ownedMatch = pickFrom(tagged, ownerId ~= nil)
		if ownedMatch then
			return ownedMatch
		end
		if ownerId ~= nil then
			local fallback = pickFrom(tagged, false)
			if fallback then
				return fallback
			end
		end
	end

	local descendants = workspace:GetDescendants()
	local ownedMatch = pickFrom(descendants, ownerId ~= nil)
	if ownedMatch then
		return ownedMatch
	end
	if ownerId ~= nil then
		return pickFrom(descendants, false)
	end
	return nil
end

local function getSlopeId(slopeModel)
	if not slopeModel then
		return nil
	end
	return tostring(slopeModel:GetAttribute("UUID") or slopeModel:GetDebugId())
end

local function chooseSlopeForGroomer(groomerData)
	local slopes = getSlopesByNeed(groomerData.ownerId)
	if #slopes == 0 then
		return nil
	end
	local lastSlopeId = groomerData.lastSlopeId
	if lastSlopeId and #slopes > 1 then
		for _, entry in ipairs(slopes) do
			if getSlopeId(entry.model) ~= lastSlopeId then
				return entry
			end
		end
	end
	return slopes[1]
end

local function getSlopeWaypoints(slopeModel)
	local cached = SlopeWaypointCache[slopeModel]
	if cached then
		return table.clone(cached)
	end

	-- Extract position waypoints from slope parts
	local points = {}
	for _, part in ipairs(slopeModel:GetDescendants()) do
		if part:IsA("BasePart") then
			table.insert(points, part.Position)
		end
	end

	if #points < 2 then
		SlopeWaypointCache[slopeModel] = points
		return table.clone(points)
	end

	-- 1) Find the highest point to start
	local startIdx = 1
	local maxY = -math.huge
	for i, p in ipairs(points) do
		if p.Y > maxY then
			maxY = p.Y
			startIdx = i
		end
	end

	local ordered = { points[startIdx] }
	table.remove(points, startIdx)

	-- 2) Build path by traversing to nearest unvisited point
	while #points > 0 do
		local current = ordered[#ordered]
		local bestIdx = 1
		local bestDist = math.huge
		for i, p in ipairs(points) do
			local dist = (current - p).Magnitude
			if dist < bestDist then
				bestDist = dist
				bestIdx = i
			end
		end
		table.insert(ordered, points[bestIdx])
		table.remove(points, bestIdx)
	end

	-- 3) Thin out points (keep every 20 studs)
	local thinned = {}
	local lastPos = nil
	for _, pos in ipairs(ordered) do
		if not lastPos or (pos - lastPos).Magnitude > 20 then
			table.insert(thinned, pos)
			lastPos = pos
		end
	end

	-- Always include last point
	if #ordered > 0 and #thinned > 0 then
		local last = ordered[#ordered]
		if (last - thinned[#thinned]).Magnitude > 5 then
			table.insert(thinned, last)
		end
	end

	SlopeWaypointCache[slopeModel] = thinned
	return table.clone(thinned)
end

local function groundRaycast(position, model)
	local result = workspace:Raycast(
		position + Vector3.new(0, 30, 0),
		Vector3.new(0, -100, 0),
		GroundRayParams
	)
	return result and result.Position.Y or (position.Y - 4)
end

local function groomTerrain(cf, size)
	local halfSize = size / 2
	local p1 = cf.Position - halfSize
	local p2 = cf.Position + halfSize

	local min = Vector3.new(math.min(p1.X, p2.X), math.min(p1.Y, p2.Y), math.min(p1.Z, p2.Z))
	local max = Vector3.new(math.max(p1.X, p2.X), math.max(p1.Y, p2.Y), math.max(p1.Z, p2.Z))
	local region = Region3.new(min, max):ExpandToGrid(4)

	pcall(function()
		workspace.Terrain:ReplaceMaterial(region, 4, Enum.Material.Snow, Enum.Material.Salt)
		workspace.Terrain:SetMaterialColor(Enum.Material.Salt, Color3.fromRGB(235, 253, 255))
	end)
end

local function updateSlopeGroomLevel(slopeModel, amount)
	local current = slopeModel:GetAttribute("GroomLevel") or 0
	slopeModel:SetAttribute("GroomLevel", math.min(100, current + amount))
end

----------------------------------------------------------------
-- AI DRIVE LOOP (per groomer)
----------------------------------------------------------------
local function driveToWaypoints(groomerData)
	local model = groomerData.model
	local waypoints = groomerData.waypoints
	local frame = model.PrimaryPart
	if not frame or #waypoints == 0 then return end

	-- Ground offset calculation
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = { workspace.Terrain }

	local ray = workspace:Raycast(frame.Position + Vector3.new(0, 30, 0), Vector3.new(0, -100, 0), params)
	local groundOffset = 4 -- default
	if ray then
		groundOffset = math.clamp(frame.Position.Y - ray.Position.Y, 2.5, 6)
	end

	local bodyPos = frame.Position
	local bodyYaw = math.atan2(-frame.CFrame.LookVector.X, -frame.CFrame.LookVector.Z)
	local lastGroomTick = 0
	local lastReplicateTick = 0

	groomerData.state = "Grooming"

	for i, target in ipairs(waypoints) do
		if groomerData.cancelled then return end

		-- Drive toward this waypoint
		local arrived = false
		local stuckTimer = 0
		local lastPos = bodyPos

		while not arrived and not groomerData.cancelled do
			local dt = task.wait()
			dt = math.min(dt, 0.05)

			-- Calculate direction to target
			local diff = Vector3.new(target.X - bodyPos.X, 0, target.Z - bodyPos.Z)
			local dist = diff.Magnitude

			if dist < WAYPOINT_REACH then
				arrived = true
				break
			end

			-- Stuck detection
			if (bodyPos - lastPos).Magnitude < 0.1 then
				stuckTimer = stuckTimer + dt
				if stuckTimer > 5 then
					-- Skip this waypoint
					break
				end
			else
				stuckTimer = 0
			end
			lastPos = bodyPos

			-- Turn toward target
			local targetYaw = math.atan2(-diff.X, -diff.Z)
			local yawDiff = targetYaw - bodyYaw
			-- Normalize angle
			while yawDiff > math.pi do yawDiff = yawDiff - 2 * math.pi end
			while yawDiff < -math.pi do yawDiff = yawDiff + 2 * math.pi end

			bodyYaw = bodyYaw + math.clamp(yawDiff, -AI_TURN_RATE * dt, AI_TURN_RATE * dt)

			-- Move forward
			local forward = Vector3.new(-math.sin(bodyYaw), 0, -math.cos(bodyYaw))
			bodyPos = bodyPos + forward * AI_SPEED * dt

			-- Ground follow
			local groundY = groundRaycast(bodyPos, model)
			bodyPos = Vector3.new(bodyPos.X, groundY + groundOffset, bodyPos.Z)

			-- Build final CFrame
			local finalCF = CFrame.new(bodyPos) * CFrame.Angles(0, bodyYaw, 0)
			model:PivotTo(finalCF)

			-- Replicate to clients
			local now = tick()
			if CFrameUpdate and now - lastReplicateTick > 0.05 then
				lastReplicateTick = now
				CFrameUpdate:FireAllClients(model, finalCF)
			end

			-- Groom terrain periodically
			if now - lastGroomTick > GROOM_INTERVAL then
				lastGroomTick = now
				local groomCF = finalCF * CFrame.new(0, -3.5, 14) -- Behind vehicle, near tiller
				local groomSize = Vector3.new(GROOM_WIDTH, GROOM_DEPTH, 6)
				groomTerrain(groomCF, groomSize)

				-- Update slope groom level
				if groomerData.targetSlope then
					updateSlopeGroomLevel(groomerData.targetSlope, 0.5)
				end
			end
		end
	end

	groomerData.state = "Idle"
end

----------------------------------------------------------------
-- MAIN AI LOOP
----------------------------------------------------------------
local function startGroomerAI(employeeId, bisonModel, ownerId)
	local groomerData = {
		model = bisonModel,
		employeeId = employeeId,
		ownerId = ownerId,
		state = "Idle",
		targetSlope = nil,
		waypoints = {},
		cancelled = false,
	}

	bisonModel:SetAttribute("AIControlled", true)
	if ownerId then
		bisonModel:SetAttribute("AIOwnerId", ownerId)
	end

	-- Disable the mount prompt while AI is driving
	local frame = bisonModel.PrimaryPart
	if frame then
		frame.Anchored = true
		local prompt = frame:FindFirstChild("MountPrompt")
		if prompt then prompt.Enabled = false end
	end

	ActiveAIGroomers[employeeId] = groomerData

	task.spawn(function()
		while not groomerData.cancelled do
			local slopeEntry = chooseSlopeForGroomer(groomerData)
			if slopeEntry and slopeEntry.model then
				local targetSlope = slopeEntry.model
				groomerData.targetSlope = targetSlope
				groomerData.lastSlopeId = getSlopeId(targetSlope)

				local waypoints = getSlopeWaypoints(targetSlope)
				if #waypoints >= 2 then
					groomerData.waypoints = waypoints
					driveToWaypoints(groomerData)

					local reversed = {}
					for i = #waypoints, 1, -1 do
						table.insert(reversed, waypoints[i])
					end
					groomerData.waypoints = reversed
					driveToWaypoints(groomerData)
				end
			end

			groomerData.state = "Idle"
			task.wait(IDLE_AT_BASE_TIME)
		end

		bisonModel:SetAttribute("AIControlled", nil)
		bisonModel:SetAttribute("AIOwnerId", nil)
		if frame then
			frame.Anchored = false
			local prompt = frame:FindFirstChild("MountPrompt")
			if prompt then prompt.Enabled = true end
		end
		ActiveAIGroomers[employeeId] = nil
	end)

	return groomerData
end

local function stopGroomerAI(employeeId)
	local data = ActiveAIGroomers[employeeId]
	if data then
		data.cancelled = true
	end
end

----------------------------------------------------------------
-- EMPLOYEE SYSTEM INTEGRATION
-- Listen for Groomer employees being hired/fired
----------------------------------------------------------------
local Events = ReplicatedStorage:WaitForChild("Events", 10)

-- Scan for available snowcats and assign groomers
local function tryAssignSpecificGroomer(employeeId, ownerId)
	if not employeeId or ActiveAIGroomers[employeeId] then
		local existing = ActiveAIGroomers[employeeId]
		return existing and existing.model or nil
	end
	local clockTime = game.Lighting.ClockTime
	if clockTime >= 7 and clockTime < 20 then
		return nil
	end
	local bison = findAvailableBison(ownerId)
	if not bison then
		return nil
	end
	startGroomerAI(employeeId, bison, ownerId)
	return bison
end

local function scanAndAssignGroomers()
	-- Only groom at night (8 PM to 7 AM)
	local clockTime = game.Lighting.ClockTime
	if clockTime >= 7 and clockTime < 20 then return end

	local groomerAvailable = workspace:GetAttribute("GroomerEmployeeCount") or 0
	local aiCount = 0
	for _ in pairs(ActiveAIGroomers) do aiCount = aiCount + 1 end

	if groomerAvailable <= aiCount then return end -- No unassigned groomers

	-- Find slopes that can be groomed
	local slopes = getSlopesByNeed()
	if #slopes == 0 then return end

	-- Find available snowcats
	local tries = groomerAvailable - aiCount
	local availableGroomers = {}

	for _, child in ipairs(workspace:GetDescendants()) do
		if child:IsA("Model") and child:GetAttribute("IsEmployee") and child:GetAttribute("EmployeeType") == "Groomer" then
			local uuid = child:GetAttribute("UUID")
			if uuid and not ActiveAIGroomers[uuid] then
				table.insert(availableGroomers, {
					uuid = uuid,
					ownerId = tonumber(child:GetAttribute("EmployeeOwnerId")) or tonumber(child:GetAttribute("OwnerId")),
				})
			end
		end
	end

	for i = 1, math.min(tries, #availableGroomers) do
		local groomerInfo = availableGroomers[i]
		if not (groomerInfo and tryAssignSpecificGroomer(groomerInfo.uuid, groomerInfo.ownerId)) then
			break -- No more available snowcats
		end
	end
end

-- Periodic scan loop

task.spawn(function()
	task.wait(10) -- Wait for initial load
	while true do
		task.wait(SLOPE_SCAN_INTERVAL)

		local clockTime = game.Lighting.ClockTime
		if clockTime >= 7 and clockTime < 20 then
			-- It is daytime. If any groomers are active, stop them!
			local hasActive = false
			for id, _ in pairs(ActiveAIGroomers) do
				stopGroomerAI(id)
				hasActive = true
			end
			if hasActive then
			end
		else
			-- It is night time, run the scan
			scanAndAssignGroomers()
		end
	end
end)

-- Also trigger immediately when groomers are hired/fired
workspace:GetAttributeChangedSignal("GroomerEmployeeCount"):Connect(function()
	local count = workspace:GetAttribute("GroomerEmployeeCount") or 0
	if count <= 0 then
		-- Stop all AI groomers
		for id, _ in pairs(ActiveAIGroomers) do
			stopGroomerAI(id)
		end
	else
		-- New groomer hired — try to assign immediately
		task.delay(2, scanAndAssignGroomers)
	end
end)

-- Provide a global interface for EmployeeServer to check if an employee is driving
_G.SnowcatAI = {
	GetGroomerSnowcat = function(employeeId)
		local data = ActiveAIGroomers[employeeId]
		if data and data.model and data.model.Parent then
			return data.model
		end
		return nil
	end,
	GetGroomerTargetSlope = function(employeeId)
		local data = ActiveAIGroomers[employeeId]
		return data and data.targetSlope or nil
	end,
	GetGroomerState = function(employeeId)
		local data = ActiveAIGroomers[employeeId]
		return data and data.state or nil
	end,
	TryAssignGroomer = function(employeeId, ownerId)
		return tryAssignSpecificGroomer(employeeId, ownerId)
	end
}
