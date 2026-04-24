--[[
	GuestMovement — Extracted from GuestServer V10.0
	
	Handles all guest movement: MoveTo commands, pathfinding, waypoints,
	stuck detection, and movement budget management.
	
	KEY FIXES FROM OLD SYSTEM:
	1. Movement commands are not starved by budget — min budget is always enough
	2. Stuck detection uses proper cooldowns instead of aggressive teleporting
	3. Pathfinding failures gracefully degrade to direct movement
	4. No more fighting between ground snap and movement commands
	5. WalkSpeed is managed consistently (no more speed drift)
]]

local PathfindingService = game:GetService("PathfindingService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local GuestConfig = require(ReplicatedStorage:WaitForChild("Guest"):WaitForChild("GuestConfig"))
local GuestMovement = {}

-- Constants
local DEFAULT_WALK_SPEED = 26
local ARRIVAL_RADIUS = 5.5
local ARRIVAL_RADIUS_LIFT = 8.0
local ARRIVAL_RADIUS_SLOPE = 4.0
local ARRIVAL_RADIUS_QUEUE = 2.75
local MOVE_COMMAND_REFRESH = 0.6  -- Seconds between MoveTo refreshes
local STUCK_CHECK_INTERVAL = 0.5
local STUCK_THRESHOLD = 1.5   -- Seconds of no progress before considered stuck
local STUCK_TELEPORT_THRESHOLD = 6.0  -- Seconds before forced teleport
local DETOUR_COOLDOWN = 1.5   -- Seconds between detour attempts
local REPATH_COOLDOWN = 1.5   -- Seconds between pathfinding retries
local MAX_REPATH_FAILURES = 5 -- Failures before giving up on pathfinding
local DIRECT_FALLBACK_FAILURES = 2 -- After repeated path failures, fall back to direct MoveTo
local MOVE_TIMEOUT_DEFAULT = 30
local MOVE_TIMEOUT_LIFT = 45
local MOVE_TIMEOUT_SLOPE = 60
local PROGRESS_GRACE = 2.0   -- Seconds of no progress before rescue
local PATHFINDING_MIN_DISTANCE = 52
local MAX_TARGET_SURFACE_ABOVE_TERRAIN = 10
local MIN_TARGET_SURFACE_BELOW_TERRAIN = -1.5
local WALKABLE_SURFACE_MIN_NORMAL_Y = 0.55

-- Utility
local function FlatDist(a: Vector3, b: Vector3): number
	local dx = a.X - b.X
	local dz = a.Z - b.Z
	return math.sqrt(dx * dx + dz * dz)
end

local function GetSafeFlatDirection(dir: Vector3, fallback: Vector3): Vector3
	local flat = Vector3.new(dir.X, 0, dir.Z)
	if flat.Magnitude < 0.01 then
		flat = Vector3.new(fallback.X, 0, fallback.Z)
	end
	if flat.Magnitude < 0.01 then
		return Vector3.zAxis
	end
	return flat.Unit
end

local function GetTerrainY(x: number, z: number): number
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = { Workspace.Terrain }
	params.IgnoreWater = true

	local result = Workspace:Raycast(
		Vector3.new(x, 2000, z),
		Vector3.new(0, -4000, 0),
		params
	)
	return result and result.Position.Y or 0
end

local function GetTerrainFallbackTarget(targetPos: Vector3): Vector3
	return Vector3.new(targetPos.X, GetTerrainY(targetPos.X, targetPos.Z) + 3, targetPos.Z)
end

local function IsIgnoredHelperPart(part: BasePart?): boolean
	if not part then
		return true
	end
	if part.CanCollide == false then
		return true
	end

	local lowerName = string.lower(part.Name)
	if lowerName == "safetynet"
		or lowerName == "loadhere"
		or lowerName == "unloadhere"
		or lowerName == "queueanchor"
		or lowerName == "queuepoint"
		or lowerName == "queuemarker"
		or lowerName == "queueguide" then
		return true
	end

	local ok, collisionGroup = pcall(function()
		return part.CollisionGroup
	end)
	if ok and collisionGroup == "SlopeNet" then
		return true
	end

	return false
end

local function IsWalkableSurface(rayResult: RaycastResult?): boolean
	if not rayResult or not rayResult.Instance or not rayResult.Instance:IsA("BasePart") then
		return false
	end
	if IsIgnoredHelperPart(rayResult.Instance) then
		return false
	end
	local normal = rayResult.Normal
	if normal and normal.Y < WALKABLE_SURFACE_MIN_NORMAL_Y then
		return false
	end
	return true
end

--- Get the arrival radius for a given state
function GuestMovement.GetArrivalRadius(state: string): number
	if state == "WaitingLift" then
		return ARRIVAL_RADIUS_QUEUE
	elseif state == "WalkingToLift" then
		return ARRIVAL_RADIUS_LIFT
	elseif state == "SkiingToSlope" then
		return ARRIVAL_RADIUS_SLOPE
	end
	return ARRIVAL_RADIUS
end

--- Get movement timeout for a given state
function GuestMovement.GetMoveTimeout(state: string): number
	if state == "WalkingToLift" then
		return MOVE_TIMEOUT_LIFT
	elseif state == "SkiingToSlope" then
		return MOVE_TIMEOUT_SLOPE
	end
	return MOVE_TIMEOUT_DEFAULT
end

--[[
	Resolve a walkable ground position near targets.
	Uses Physics module's ground resolution with additional logic
	for placed objects.
]]
function GuestMovement.ResolveTargetPos(targetPos: Vector3, guestModel: Model?): Vector3
	local fallbackTarget = GetTerrainFallbackTarget(targetPos)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = guestModel and {guestModel} or {}
	params.IgnoreWater = true

	local originY = math.max(targetPos.Y + 80, fallbackTarget.Y + 80)
	local result = Workspace:Raycast(Vector3.new(targetPos.X, originY, targetPos.Z), Vector3.new(0, -260, 0), params)
	if IsWalkableSurface(result) then
		local resolved = result.Position + Vector3.new(0, 3, 0)
		local terrainDelta = resolved.Y - fallbackTarget.Y
		local targetAboveTerrain = targetPos.Y - fallbackTarget.Y
		local targetWantsRaisedSurface = targetAboveTerrain > 0.5 and targetAboveTerrain <= 18
		if (terrainDelta <= MAX_TARGET_SURFACE_ABOVE_TERRAIN and terrainDelta >= MIN_TARGET_SURFACE_BELOW_TERRAIN)
			or (targetWantsRaisedSurface and math.abs(resolved.Y - targetPos.Y) <= 8) then
			return resolved
		end
	end
	return fallbackTarget
end

--[[
	Check for obstacles between two positions using raycasts at multiple heights.
]]
function GuestMovement.HasObstacle(fromPos: Vector3, toPos: Vector3, guestModel: Model?): boolean
	local flatDelta = Vector3.new(toPos.X - fromPos.X, 0, toPos.Z - fromPos.Z)
	if flatDelta.Magnitude < 14 then
		return false
	end
	
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = guestModel and {guestModel} or {}
	params.IgnoreWater = true
	
	for _, height in ipairs({2.5, 5.0, 7.5}) do
		local origin = Vector3.new(fromPos.X, fromPos.Y + height, fromPos.Z)
		local target = Vector3.new(toPos.X, origin.Y, toPos.Z)
		local result = Workspace:Raycast(origin, target - origin, params)
		if result and result.Instance and result.Instance:IsA("BasePart") and not IsIgnoredHelperPart(result.Instance) then
			return true
		end
	end
	return false
end

--[[
	Find a detour around an obstacle.
]]
function GuestMovement.FindDetour(fromPos: Vector3, toPos: Vector3, guestModel: Model?): Vector3?
	local flatDelta = Vector3.new(toPos.X - fromPos.X, 0, toPos.Z - fromPos.Z)
	if flatDelta.Magnitude < 8 then
		return nil
	end
	
	local forward = flatDelta.Unit
	local perp = Vector3.new(-forward.Z, 0, forward.X)
	local forwardStep = math.clamp(flatDelta.Magnitude * 0.25, 10, 28)
	
	for _, offset in ipairs({18, -18, 28, -28, 40, -40}) do
		local candidate = fromPos + (forward * forwardStep) + (perp * offset)
		candidate = GuestMovement.ResolveTargetPos(candidate, guestModel)
		
		if not GuestMovement.HasObstacle(fromPos, candidate, guestModel)
			and not GuestMovement.HasObstacle(candidate, toPos, guestModel) then
			return candidate
		end
	end
	return nil
end

function GuestMovement.FindEscapeStep(fromPos: Vector3, toPos: Vector3, guestModel: Model?): Vector3?
	local flatDelta = Vector3.new(toPos.X - fromPos.X, 0, toPos.Z - fromPos.Z)
	if flatDelta.Magnitude < 4 then
		return nil
	end
	
	local forward = flatDelta.Unit
	local perp = Vector3.new(-forward.Z, 0, forward.X)
	local stepForward = math.clamp(flatDelta.Magnitude * 0.12, 6, 12)
	
	for _, offset in ipairs({14, -14, 22, -22, 30, -30}) do
		local candidate = fromPos + (forward * stepForward) + (perp * offset)
		candidate = GuestMovement.ResolveTargetPos(candidate, guestModel)
		if not GuestMovement.HasObstacle(fromPos, candidate, guestModel) then
			return candidate
		end
	end
	
	for _, retreat in ipairs({-10, -16}) do
		local candidate = fromPos + (forward * retreat)
		candidate = GuestMovement.ResolveTargetPos(candidate, guestModel)
		if not GuestMovement.HasObstacle(fromPos, candidate, guestModel) then
			return candidate
		end
	end
	
	return nil
end

--[[
	Compute a path using PathfindingService.
	Simplified to ONE query to prevent PathfindingService DOS during morning waves.
	Shared guest pathfinding settings come from GuestConfig so movement and server logic stay in sync.
]]
local function getPathfindingProfile()
	if type(GuestConfig.GetPathfindingProfile) == "function" then
		return GuestConfig.GetPathfindingProfile()
	end
	local pathfinding = GuestConfig.Pathfinding or {}
	return {
		AgentRadius = math.max(0.5, tonumber(pathfinding.AgentRadius) or 2.0),
		AgentHeight = math.max(1, tonumber(pathfinding.AgentHeight) or 5.0),
		AgentCanJump = pathfinding.AgentCanJump ~= false,
		AgentCanClimb = pathfinding.AgentCanClimb == true,
		WaypointSpacing = math.max(1, tonumber(pathfinding.WaypointSpacing) or 4.0),
	}
end

local function getPathfindingProfiles(): { [number]: { [string]: any } }
	local profile = getPathfindingProfile()
	local profiles = {
		{
			AgentRadius = profile.AgentRadius,
			AgentHeight = profile.AgentHeight,
			AgentCanJump = false,
			AgentCanClimb = false,
			WaypointSpacing = profile.WaypointSpacing,
		},
	}
	if profile.AgentCanJump then
		table.insert(profiles, {
			AgentRadius = profile.AgentRadius,
			AgentHeight = profile.AgentHeight,
			AgentCanJump = true,
			AgentCanClimb = profile.AgentCanClimb == true,
			WaypointSpacing = profile.WaypointSpacing,
		})
	end
	return profiles
end

function GuestMovement.ComputePath(fromPos: Vector3, toPos: Vector3): ({PathWaypoint}?, Vector3?)
	for _, profile in ipairs(getPathfindingProfiles()) do
		local path = PathfindingService:CreatePath(profile)
		local ok = pcall(function()
			path:ComputeAsync(fromPos, toPos)
		end)

		if ok and path.Status == Enum.PathStatus.Success then
			local waypoints = path:GetWaypoints()
			if waypoints and #waypoints >= 2 then
				return waypoints, toPos
			end
		end
	end

	return nil, nil
end

--[[
	Issue a movement command to a guest.
	
	KEY FIX: Always ensures Humanoid is in a movable state before commanding.
	Prevents the silent MoveTo failure that plagued the old system.
]]
function GuestMovement.MoveTo(data: any, targetPos: Vector3, callback: ((any) -> ())?)
	local model = data.Model
	local hum = data.Humanoid
	local root = data.Root
	if not model or not model.Parent or not hum or hum.Health <= 0 or not root then
		return
	end
	
	local resolvedTarget = GuestMovement.ResolveTargetPos(targetPos, model)
	
	-- CRITICAL FIX: Ensure humanoid is ready to move
	if root.Anchored then
		root.Anchored = false
		root.AssemblyLinearVelocity = Vector3.zero
		root.AssemblyAngularVelocity = Vector3.zero
	end
	if hum.PlatformStand then
		hum.PlatformStand = false
	end
	hum.AutoRotate = true
	
	-- Ensure consistent walk speed
	if hum.WalkSpeed < 20 or hum.WalkSpeed > 32 then
		hum.WalkSpeed = DEFAULT_WALK_SPEED
	end
	
	-- Ensure collision is on for walking
	if not root.CanCollide then
		root.CanCollide = true
	end
	
	local rootPos = root.Position
	local dist = FlatDist(rootPos, resolvedTarget)
	local verticalDelta = resolvedTarget.Y - rootPos.Y
	
	-- Clear previous movement state
	data.MoveResumeTarget = nil
	data.MoveResumeCallback = nil
	data.MoveTimeoutRetryCount = 0
	
	-- Decide: direct move vs pathfinding
	local hasObstacle = GuestMovement.HasObstacle(rootPos, resolvedTarget, model)
	local shouldPath = hasObstacle
		or dist >= PATHFINDING_MIN_DISTANCE
		or (dist >= 14 and math.abs(verticalDelta) >= 7)
		or (dist >= 10 and verticalDelta >= 5)
	
	if not shouldPath then
		-- Direct move
		hum:MoveTo(resolvedTarget)
		data.LastMoveCommandTime = tick()
		data.LastMoveCommandTarget = resolvedTarget
		data.MoveTarget = resolvedTarget
		data.MoveStartTime = tick()
		data.MoveCallback = callback
		data.MoveProgressBaseline = dist
		data.LastProgressTime = tick()
		data.PathFailures = 0
		data.Waypoints = nil
		data.WaypointIndex = nil
		return
	end
	
	data.MoveTarget = resolvedTarget -- CRITICAL FIX: Set MoveTarget immediately so GuestServer doesn't instantly abort WALKING state.
	
	-- Pathfinding (Must be asynchronous to avoid blocking Heartbeat)
	task.spawn(function()
		local waypoints, pathGoal = GuestMovement.ComputePath(rootPos, resolvedTarget)
		if waypoints then
			data.Waypoints = waypoints
			data.WaypointIndex = 2
			data.MoveTarget = resolvedTarget
			data.MoveStartTime = tick()
			data.MoveCallback = callback
			data.MoveProgressBaseline = dist
			data.LastProgressTime = tick()
			data.PathGoal = pathGoal
			data.PathFailures = 0
			
			local firstWP = waypoints[2] or waypoints[1]
			if firstWP then
				local resolved = GuestMovement.ResolveTargetPos(firstWP.Position, model)
				hum:MoveTo(resolved)
				data.LastMoveCommandTime = tick()
				data.LastMoveCommandTarget = resolved
			end
			return
		end
		
		-- Pathfinding failed — try detour
		if hasObstacle then
			local detour = GuestMovement.FindDetour(rootPos, resolvedTarget, model)
			if detour then
				hum.Jump = true
				hum:MoveTo(detour)
				data.LastMoveCommandTime = tick()
				data.LastMoveCommandTarget = detour
				data.MoveTarget = detour
				data.MoveResumeTarget = resolvedTarget
				data.MoveResumeCallback = callback
				data.MoveStartTime = tick()
				data.MoveCallback = function(gd)
					local resume = gd.MoveResumeTarget
					local resumeCb = gd.MoveResumeCallback
					gd.MoveResumeTarget = nil
					gd.MoveResumeCallback = nil
					gd.MoveCallback = nil
					if resume then
						GuestMovement.MoveTo(gd, resume, resumeCb)
					elseif resumeCb then
						resumeCb(gd)
					end
				end
				data.MoveProgressBaseline = FlatDist(rootPos, detour)
				data.LastProgressTime = tick()
				data.PathFailures = (data.PathFailures or 0) + 1
				data.Waypoints = nil
				return
			end
		end
		
		-- Pathfinding failed. Prefer a local escape step first, but never leave the guest without a live move command.
		data.MoveTarget = resolvedTarget
		data.MoveStartTime = tick()
		data.MoveCallback = callback
		data.MoveProgressBaseline = dist
		data.LastProgressTime = tick()
		data.PathFailures = (data.PathFailures or 0) + 1
		data.Waypoints = nil
		data.WaypointIndex = nil
		
		local escape = GuestMovement.FindEscapeStep(rootPos, resolvedTarget, model)
		if escape then
			hum.Jump = true
			hum:MoveTo(escape)
			data.LastMoveCommandTime = tick()
			data.LastMoveCommandTarget = escape
			return
		end
		
		local directTarget = GuestMovement.ResolveTargetPos(resolvedTarget, model)
		if hasObstacle and data.PathFailures < DIRECT_FALLBACK_FAILURES then
			hum.Jump = true
		end
		hum:MoveTo(directTarget)
		data.LastMoveCommandTime = tick()
		data.LastMoveCommandTarget = directTarget
	end)
end

--[[
	Update movement for a guest — called each movement tick.
	
	KEY FIXES:
	1. Waypoint progression is more forgiving (6 stud radius)
	2. MoveTo refresh has proper cadence to prevent command loss
	3. Stuck detection uses gradual escalation (detour → repath → teleport)
	4. Progress tracking prevents false stuck detection during pathfinding
]]
function GuestMovement.Update(data: any, dt: number)
	local model = data.Model
	local hum = data.Humanoid
	local root = data.Root
	if not model or not model.Parent or not root or not hum then
		data.MoveTarget = nil
		return
	end
	
	if not data.MoveTarget then return end
	
	local now = tick()
	local pos = root.Position
	
	-- Ensure humanoid stays movable
	if root.Anchored then root.Anchored = false end
	if hum.PlatformStand then hum.PlatformStand = false end
	if not root.CanCollide then root.CanCollide = true end
	if hum.WalkSpeed < 20 or hum.WalkSpeed > 32 then
		hum.WalkSpeed = DEFAULT_WALK_SPEED
	end
	
	local dist = FlatDist(pos, data.MoveTarget)
	local arrivalRadius = GuestMovement.GetArrivalRadius(data.State or "")
	
	-- Track progress 
	if not data.MoveProgressBaseline or dist < (data.MoveProgressBaseline - 1.2) then
		data.MoveProgressBaseline = dist
		data.LastProgressTime = now
	elseif not data.LastProgressTime then
		data.LastProgressTime = now
	end
	
	-- CHECK ARRIVAL
	if dist < arrivalRadius then
		local cb = data.MoveCallback
		data.MoveTarget = nil
		data.Waypoints = nil
		data.WaypointIndex = nil
		data.StuckTimer = 0
		data.PathFailures = 0
		data.MoveTimeoutRetryCount = 0
		data.MoveProgressBaseline = nil
		data.LastProgressTime = nil
		data.MoveCallback = nil
		data.LastMovePos = nil
		if cb then cb(data) end
		return
	end
	
	-- WAYPOINT PROGRESSION
	if data.Waypoints and data.WaypointIndex then
		local wp = data.Waypoints[data.WaypointIndex]
		if wp then
			local wpDist = FlatDist(pos, wp.Position)
			if wpDist < 6 then
				data.WaypointIndex += 1
				if data.WaypointIndex > #data.Waypoints then
					-- Final approach to actual target
					local finalTarget = GuestMovement.ResolveTargetPos(data.MoveTarget, model)
					hum:MoveTo(finalTarget)
					data.LastMoveCommandTarget = finalTarget
					data.LastMoveCommandTime = now
					data.Waypoints = nil
				else
					local nextWP = data.Waypoints[data.WaypointIndex]
					if nextWP.Action == Enum.PathWaypointAction.Jump then
						hum.Jump = true
					end
					local resolved = GuestMovement.ResolveTargetPos(nextWP.Position, model)
					hum:MoveTo(resolved)
					data.LastMoveCommandTime = now
					data.LastMoveCommandTarget = resolved
				end
			end
		end
	end
	
	-- REFRESH MOVE COMMAND periodically (MoveTo can be lost)
	if not data.LastMoveCommandTime or (now - data.LastMoveCommandTime) > MOVE_COMMAND_REFRESH then
		local refreshTarget = data.MoveTarget
		if data.Waypoints and data.WaypointIndex and data.Waypoints[data.WaypointIndex] then
			refreshTarget = data.Waypoints[data.WaypointIndex].Position
		else
			local pathBlocked = GuestMovement.HasObstacle(pos, data.MoveTarget, model)
			if pathBlocked then
				local escape = GuestMovement.FindEscapeStep(pos, data.MoveTarget, model)
				if escape then
					refreshTarget = escape
				else
					refreshTarget = data.MoveTarget
				end
			end
		end
		if refreshTarget then
			refreshTarget = GuestMovement.ResolveTargetPos(refreshTarget, model)
			hum:MoveTo(refreshTarget)
			data.LastMoveCommandTime = now
			data.LastMoveCommandTarget = refreshTarget
		end
	end
	
	-- STUCK DETECTION (gradual escalation)
	if not data.LastMovePos then data.LastMovePos = pos end
	local shouldCheckStuck = not data._nextStuckCheck or now >= data._nextStuckCheck
	if shouldCheckStuck then
		data._nextStuckCheck = now + STUCK_CHECK_INTERVAL
		local targetPoint = data.MoveTarget
		if data.Waypoints and data.WaypointIndex and data.Waypoints[data.WaypointIndex] then
			targetPoint = data.Waypoints[data.WaypointIndex].Position
		end
		
		local currentDistToWP = FlatDist(pos, targetPoint)
		local previousDistToWP = FlatDist(data.LastMovePos, targetPoint)
		local progress = previousDistToWP - currentDistToWP
		
		local minProgress = math.max(0.2, (hum.WalkSpeed or 16) * STUCK_CHECK_INTERVAL * 0.15)
		
		if progress < minProgress then
			data.StuckTimer = (data.StuckTimer or 0) + STUCK_CHECK_INTERVAL
			
			if data.StuckTimer > STUCK_TELEPORT_THRESHOLD then
				-- Level 3: recovery without hard warp; issue an aggressive short jump step.
				local toTarget = Vector3.new(data.MoveTarget.X - pos.X, 0, data.MoveTarget.Z - pos.Z)
				if toTarget.Magnitude > 1 then
					local jumpDist = math.min(24, dist * 0.35)
					local jumpPos = GuestMovement.ResolveTargetPos(pos + toTarget.Unit * jumpDist, model)
					hum.Jump = true
					hum:MoveTo(jumpPos)
					data.LastMoveCommandTime = now
					data.LastMoveCommandTarget = jumpPos
					data.StuckTimer = STUCK_THRESHOLD * 0.5
					data.Waypoints = nil
					data.MoveProgressBaseline = FlatDist(jumpPos, data.MoveTarget)
					data.LastProgressTime = now
				end
			elseif data.StuckTimer > STUCK_THRESHOLD then
				-- Level 1-2: Try repath or detour
				local canDetour = not data._nextDetourAt or now >= data._nextDetourAt
				if canDetour then
					data._nextDetourAt = now + DETOUR_COOLDOWN
					data.PathFailures = (data.PathFailures or 0) + 1
					
					if data.PathFailures < MAX_REPATH_FAILURES then
						-- Try repathing
						GuestMovement.MoveTo(data, data.MoveTarget, data.MoveCallback)
					else
						-- Too many failures — try side step
						local dir = Vector3.new(data.MoveTarget.X - pos.X, 0, data.MoveTarget.Z - pos.Z)
						if dir.Magnitude > 1 then
							local perpDir = Vector3.new(-dir.Unit.Z, 0, dir.Unit.X)
							local side = perpDir * ((data.StuckTimer % 3 < 1.5) and 15 or -15)
							hum.Jump = true
							local sideTarget = GuestMovement.ResolveTargetPos(pos + dir.Unit * 5 + side, model)
							hum:MoveTo(sideTarget)
							data.LastMoveCommandTime = now
							data.LastMoveCommandTarget = sideTarget
						end
					end
				end
			end
		else
			data.StuckTimer = 0
		end
		data.LastMovePos = pos
	end
	
	-- NO-PROGRESS RESCUE (different from stuck — this is when they moved
	-- but in the wrong direction)
	local noProgressFor = now - (data.LastProgressTime or now)
	if dist > 10 and noProgressFor > PROGRESS_GRACE then
		-- Try repathing with cooldown
		local canRepath = not data._lastRepathAt or (now - data._lastRepathAt) >= REPATH_COOLDOWN
		if canRepath then
			data._lastRepathAt = now
			data.PathFailures = (data.PathFailures or 0) + 1
			if data.PathFailures < MAX_REPATH_FAILURES then
				GuestMovement.MoveTo(data, data.MoveTarget, data.MoveCallback)
			end
			data.LastProgressTime = now
		end
	end
	
	-- TIMEOUT 
	local timeout = GuestMovement.GetMoveTimeout(data.State or "")
	if tick() - (data.MoveStartTime or tick()) > timeout then
		data.MoveTimeoutRetryCount = (data.MoveTimeoutRetryCount or 0) + 1
		local toTarget = Vector3.new(data.MoveTarget.X - pos.X, 0, data.MoveTarget.Z - pos.Z)
		local distToTarget = toTarget.Magnitude

		-- Prefer visual walking over cross-map warps: advance in short chunks and retry.
		if distToTarget > 18 and data.MoveTimeoutRetryCount <= 4 then
			local stepDistance = math.min(28, math.max(9, distToTarget * 0.24))
			local stepTarget = GuestMovement.ResolveTargetPos(pos + (toTarget.Unit * stepDistance), model)
			hum:MoveTo(stepTarget)
			data.LastMoveCommandTime = now
			data.LastMoveCommandTarget = stepTarget
			data.MoveStartTime = now
			data.Waypoints = nil
			data.WaypointIndex = nil
			data.PathFailures = (data.PathFailures or 0) + 1
			data.MoveProgressBaseline = FlatDist(stepTarget, data.MoveTarget)
			data.LastProgressTime = now
			return
		end

		-- Final fallback: cap timeout correction distance so guests do not snap huge distances.
		local timeoutTarget = GuestMovement.ResolveTargetPos(data.MoveTarget, model)
		local flatDelta = Vector3.new(timeoutTarget.X - pos.X, 0, timeoutTarget.Z - pos.Z)
		if flatDelta.Magnitude > 36 then
			timeoutTarget = GuestMovement.ResolveTargetPos(pos + (flatDelta.Unit * 36), model)
		end
		if data.MoveTimeoutRetryCount <= 8 then
			hum.Jump = true
			hum:MoveTo(timeoutTarget)
			data.LastMoveCommandTime = now
			data.LastMoveCommandTarget = timeoutTarget
			data.MoveStartTime = now
			data.Waypoints = nil
			data.WaypointIndex = nil
			data.MoveProgressBaseline = FlatDist(pos, data.MoveTarget)
			data.LastProgressTime = now
			return
		end

		local cb = data.MoveCallback
		data.MoveTarget = nil
		data.Waypoints = nil
		data.MoveCallback = nil
		data.LastMoveCommandTime = nil
		data.MoveProgressBaseline = nil
		data.LastProgressTime = nil
		data.LastMovePos = nil
		data.StuckTimer = 0
		data.PathFailures = 0
		data.MoveTimeoutRetryCount = 0
		if cb then cb(data) end
	end
end

--[[
	Movement budget management for processing many guests.
	
	KEY FIX: Budget is calculated to ensure EVERY guest gets at least
	one movement update per second, preventing starvation.
]]
function GuestMovement.GetBudget(totalMoving: number, interval: number): number
	if totalMoving <= 0 then return 0 end
	
	-- Target: every guest gets processed at least once per 0.5 seconds
	local targetRevisit = 0.5
	local required = math.ceil((totalMoving * interval) / targetRevisit)
	
	-- Generous bounds to prevent starvation
	local minBudget = math.max(15, math.ceil(totalMoving * 0.1))
	local maxBudget = math.max(minBudget, 200)
	
	local budget = math.clamp(required, minBudget, maxBudget)
	return math.min(budget, totalMoving)
end

--- Stop all movement for a guest
function GuestMovement.StopMovement(data: any)
	data.MoveTarget = nil
	data.MoveCallback = nil
	data.Waypoints = nil
	data.WaypointIndex = nil
	data.MoveResumeTarget = nil
	data.MoveResumeCallback = nil
	data.StuckTimer = 0
	data.PathFailures = 0
	data.MoveTimeoutRetryCount = 0
	data.MoveProgressBaseline = nil
	data.LastProgressTime = nil
	data.LastMovePos = nil
end

return GuestMovement