local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")
local modeState = playerGui:FindFirstChild("ModeState")

local FALL_THRESHOLD_OFFSET = 20
local SAFE_RAY_DISTANCE = 48
local SAFE_FLOOR_DISTANCE = 14
local PLACEMENT_SAFE_FLOOR_DISTANCE = 24
local RESCUE_HEIGHT_OFFSET = 6
local RESCUE_COOLDOWN = 1.5
local MISSING_GROUND_DROP_THRESHOLD = 60
local PLACEMENT_MISSING_GROUND_DROP_THRESHOLD = 16
local MISSING_GROUND_DESCENT_VELOCITY = -28
local PLACEMENT_MISSING_GROUND_DESCENT_VELOCITY = -4
local MISSING_GROUND_STUCK_GRACE = 0.45
local PLACEMENT_MISSING_GROUND_STUCK_GRACE = 0.2
local HEARTBEAT_INTERVAL = 0.5

-- Cache ray direction and params once, never recreate each frame
local RAY_DIRECTION = Vector3.new(0, -SAFE_RAY_DISTANCE, 0)
local RAY_OFFSET = Vector3.new(0, 4, 0)
local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude

local lastSafeCF = nil
local lastRescueAt = 0
local lastHeartbeatTick = 0
local missingGroundSince = nil

-- Cache character parts and invalidate on character change
local cachedCharacter = nil
local cachedHumanoid = nil
local cachedRoot = nil

local function refreshCharacterCache()
	cachedCharacter = player.Character
	if not cachedCharacter then
		cachedHumanoid = nil
		cachedRoot = nil
		return
	end
	cachedHumanoid = cachedCharacter:FindFirstChildOfClass("Humanoid")
	cachedRoot = cachedCharacter:FindFirstChild("HumanoidRootPart")
	-- Update ray exclusion to current character
	rayParams.FilterDescendantsInstances = {cachedCharacter}
end

local function getRescueTarget()
	if lastSafeCF then
		return lastSafeCF + Vector3.new(0, RESCUE_HEIGHT_OFFSET, 0)
	end
	local respawnLocation = player.RespawnLocation
	if respawnLocation and respawnLocation:IsDescendantOf(Workspace) then
		return respawnLocation.CFrame + Vector3.new(0, RESCUE_HEIGHT_OFFSET, 0)
	end
	local startSpawn = Workspace:FindFirstChild("StartSpawn", true)
	if startSpawn and startSpawn:IsA("SpawnLocation") then
		return startSpawn.CFrame + Vector3.new(0, RESCUE_HEIGHT_OFFSET, 0)
	end
	return nil
end

local function getCurrentModeValue()
	return modeState and modeState.Value or ""
end

local function isPlacementSafetyMode()
	local modeValue = getCurrentModeValue()
	return modeValue == "Placing" or modeValue == "Builder" or modeValue == "Slope"
end

local function isPlayerInSkiRescueBypassState()
	if player:GetAttribute("SkiActive") ~= true then return false end
	local skiState = tostring(player:GetAttribute("SkiState") or "")
	return skiState == "skiing" or skiState == "airborne"
end

local function updateLastSafe(humanoid, root)
	local result = Workspace:Raycast(root.Position + RAY_OFFSET, RAY_DIRECTION, rayParams)
	if not result then return false end
	local safeFloorDistance = isPlacementSafetyMode() and PLACEMENT_SAFE_FLOOR_DISTANCE or SAFE_FLOOR_DISTANCE
	if humanoid.FloorMaterial ~= Enum.Material.Air or (root.Position.Y - result.Position.Y) <= safeFloorDistance then
		lastSafeCF = root.CFrame
	end
	return true
end

local function rescueCharacter(root)
	local targetCF = getRescueTarget()
	if not targetCF then return end
	lastRescueAt = tick()
	missingGroundSince = nil
	root.AssemblyLinearVelocity = Vector3.zero
	root.AssemblyAngularVelocity = Vector3.zero
	root.CFrame = targetCF
end

local function onCharacterAdded()
	lastSafeCF = nil
	lastRescueAt = 0
	missingGroundSince = nil
	refreshCharacterCache()
end

player.CharacterAdded:Connect(onCharacterAdded)
if player.Character then
	onCharacterAdded()
end

local fallenPartsDestroyHeight = Workspace.FallenPartsDestroyHeight

RunService.Heartbeat:Connect(function()
	local now = tick()
	if now - lastHeartbeatTick < HEARTBEAT_INTERVAL then return end
	lastHeartbeatTick = now

	-- Early exits before touching anything else
	if player:GetAttribute("WorldLoadLocked") == true then return end
	if player:GetAttribute("RidingLift") then return end

	local character = cachedCharacter
	local humanoid = cachedHumanoid
	local root = cachedRoot

	-- Validate cache is still good
	if not character or character.Parent ~= Workspace then
		refreshCharacterCache()
		return
	end
	if not humanoid or not root then return end
	if humanoid.Health <= 0 then return end
	if humanoid.Sit or humanoid.SeatPart then return end

	local rootPos = root.Position
	local hasGroundBelow = updateLastSafe(humanoid, root)
	if hasGroundBelow then
		missingGroundSince = nil
	elseif not missingGroundSince then
		missingGroundSince = now
	end

	local canRescue = (now - lastRescueAt) >= RESCUE_COOLDOWN

	if rootPos.Y < (fallenPartsDestroyHeight + FALL_THRESHOLD_OFFSET) and canRescue then
		rescueCharacter(root)
		return
	end

	if canRescue and not hasGroundBelow and not isPlayerInSkiRescueBypassState() then
		local placementMode = isPlacementSafetyMode()
		local dropThreshold = placementMode and PLACEMENT_MISSING_GROUND_DROP_THRESHOLD or MISSING_GROUND_DROP_THRESHOLD
		local descentVelocityThreshold = placementMode and PLACEMENT_MISSING_GROUND_DESCENT_VELOCITY or MISSING_GROUND_DESCENT_VELOCITY
		local stuckGrace = placementMode and PLACEMENT_MISSING_GROUND_STUCK_GRACE or MISSING_GROUND_STUCK_GRACE
		local stuckWithoutGround = missingGroundSince ~= nil and (now - missingGroundSince) >= stuckGrace
		if root.AssemblyLinearVelocity.Y <= descentVelocityThreshold or stuckWithoutGround then
			if lastSafeCF then
				if lastSafeCF.Position.Y - rootPos.Y >= dropThreshold then
					rescueCharacter(root)
				end
			else
				local fallbackTarget = getRescueTarget()
				if fallbackTarget and rootPos.Y <= (fallbackTarget.Position.Y - dropThreshold) then
					rescueCharacter(root)
				end
			end
		end
	end
end)