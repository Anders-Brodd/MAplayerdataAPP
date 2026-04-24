--[[
	SCRIPT: LiftClient
	WHAT IT DOES:
	Handles client-side physics, rendering, and visual updates for ski lifts.
	Calculates chair position, sway, and rotation based on track segments.
	Manages player and guest sitting animations and physics snapping.
	Handles visual rendering optimizations based on camera distance (LOD).
	Simulates wind, momentum, and emergency stop energy transfer.
	Draws surface tow ropes and calculates rider ground orientation.
	Reads baked DoorStates dynamically from the server.
	Computes true kinematic position during acceleration chunks.
	
	CHANGES:
	- FIXED: Auto-dismount math error. `endPoint` is already a Vector3, so passing it through `TableToVec()` caused an index error.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")

local LocalPlayer = Players.LocalPlayer
local Config = require(ReplicatedStorage:WaitForChild("Config"))
local CableMath = require(ReplicatedStorage:WaitForChild("CableMath"))
local CableConfig = require(ReplicatedStorage:WaitForChild("CableConfig"))
local GraphicsProfile = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("GraphicsProfile"))

local CarpetTerrainUtil = { AdaptInterval = 0.4 }
CarpetTerrainUtil.Raycast = RaycastParams.new()
CarpetTerrainUtil.Raycast.FilterType = Enum.RaycastFilterType.Include
CarpetTerrainUtil.Raycast.FilterDescendantsInstances = {Workspace.Terrain}
CarpetTerrainUtil.Raycast.IgnoreWater = true

------------------------------------------------------------------------
-- TUNING CONSTANTS
------------------------------------------------------------------------
-- Large resorts routinely span well beyond 1800 studs, which made distant restored lifts
-- look chairless after rejoin. Keep the throttle tiers, but push the hard hide much farther out.
local LOD_HIDE_BASE    = 2600
local ROT_LERP_SPEED   = 10.0 

local GRAVITY          = 50
local PENDULUM_LENGTH  = 4.5 
local PITCH_DAMPING    = 2.2 
local ROLL_DAMPING     = 3.5 
local STATION_DAMPING  = 2.5 
local MAX_SWAY_ANGLE   = math.rad(14) 
local ACCEL_FILTER     = 0.1 

local PITCH_ACCEL_GAIN = 0.15 
local ROLL_ACCEL_GAIN  = 0.05 
local CENTRIPETAL_GAIN = 0.25
local ELEVATION_GAIN   = 0.10
local MAX_ACCEL        = 100 

local WIND_ENABLED     = true
local WIND_STRENGTH    = 0.4 
local WIND_GUST_SCALE  = 60
local WIND_TIME_SCALE  = 0.15

local Lighting = game:GetService("Lighting")
local function GetLiveWindStrength()
	local ws = tonumber(Lighting:GetAttribute("WindSpeed")) or 5
	return math.clamp(ws / 70, 0.05, 1.5)
end

local POLE_IMPULSE     = 0.35
local POLE_KICK        = 0.01
local BODY_DIR_LERP    = 5.0
local RIDER_LERP_SPEED = 20.0

local SPEED_ACCEL      = 0.5 

-- Surface Tow Settings
local TOW_ROPE_THICKNESS = (CableConfig.Thickness or 0.2) * 0.5 
local TOW_RAYCAST_HEIGHT = 3.0 
local TOW_RETRACT_DIST   = 2.0 
local TOW_DRAG_LAG       = 12.0 
local TOW_IDLE_HANG_ANGLE = 0 
local TOW_FULL_RAYCAST_BASE = 520
local SEAT_TOUCH_ENABLE_DISTANCE = 52
local SEAT_TOUCH_ENABLE_DISTANCE_SQ = SEAT_TOUCH_ENABLE_DISTANCE * SEAT_TOUCH_ENABLE_DISTANCE
local FAR_CHAIR_SIMPLIFY_RATIO = 0.58
local HEAVY_SEAT_TOUCH_RECHECK_INTERVAL = 0.35
local STRESS_SEAT_TOUCH_RECHECK_INTERVAL = 0.5
local REMOTE_RIDER_UPDATE_INTERVAL_BASE = 1 / 60
local REMOTE_RIDER_UPDATE_INTERVAL_HEAVY = 1 / 45
local REMOTE_RIDER_UPDATE_INTERVAL_STRESS = 1 / 36
local NEAR_CHAIR_PRIORITY_DISTANCE = 560
local NEAR_CHAIR_PRIORITY_DISTANCE_SQ = NEAR_CHAIR_PRIORITY_DISTANCE * NEAR_CHAIR_PRIORITY_DISTANCE
local CHAIR_HIDE_DISTANCE_HYSTERESIS_HIDE = 1.06
local CHAIR_HIDE_DISTANCE_HYSTERESIS_SHOW = 0.90
local MAX_CABLE_SNAP_PERP_OFFSET = 13.5
local GLOBAL_SEAT_TOUCH_COOLDOWN = 0.45
local PER_SEAT_TOUCH_COOLDOWN = 0.95

local function BuildLiftPhysicsProfile(configData, liftName)
	local profile = {
		PoleImpulseScale = 1.0,
		PoleKickScale = 1.0,
		TerminalDirLerpScale = 1.0,
		TerminalPolePoseBlend = 0.28,
		TerminalPoleForceScale = 1.0,
		TerminalPoleDampingScale = 1.0,
		StationDirBoost = 1.35,
		StationRotLerpScale = 0.92,
		TerminalPoleImpulseScale = 0.65,
		TerminalPoleKickScale = 0.75,
		TerminalPoleStationDirBoost = 0.9,
		TerminalPoleFlipBlendScale = 1.0,
		TerminalPoleSwayDamping = 0.0,
		AllowTerminalHardFlip = true,
		DisableTerminalPoleCableSnap = false,
		CableSnapPerpMax = MAX_CABLE_SNAP_PERP_OFFSET,
		CableSnapPerpMaxStation = math.min(MAX_CABLE_SNAP_PERP_OFFSET, 9.5),
		CableSnapDistanceRatio = 0.78,
	}

	local name = string.lower(tostring(liftName or ""))
	local hasBubble = configData and configData.HasBubbleBar == true
	local isFixedGripQuad = name:find("fixed", 1, true) ~= nil and name:find("quad", 1, true) ~= nil

	if hasBubble then
		profile.PoleImpulseScale = 0.28
		profile.PoleKickScale = 0.3
		profile.TerminalDirLerpScale = 0.24
		profile.TerminalPolePoseBlend = 0.12
		profile.TerminalPoleForceScale = 0.74
		profile.TerminalPoleDampingScale = 1.24
		profile.StationDirBoost = 1.02
		profile.StationRotLerpScale = 0.68
		profile.TerminalPoleImpulseScale = 0.1
		profile.TerminalPoleKickScale = 0.12
		profile.TerminalPoleStationDirBoost = 0.58
		profile.TerminalPoleFlipBlendScale = 0.22
		profile.TerminalPoleSwayDamping = 2.8
		profile.AllowTerminalHardFlip = false
		profile.DisableTerminalPoleCableSnap = false
		profile.CableSnapPerpMax = 5.75
		profile.CableSnapPerpMaxStation = 4.25
		profile.CableSnapDistanceRatio = 0.62
	elseif isFixedGripQuad then
		profile.PoleImpulseScale = 0.66
		profile.PoleKickScale = 0.7
		profile.TerminalDirLerpScale = 0.55
		profile.TerminalPolePoseBlend = 0.22
		profile.TerminalPoleForceScale = 0.88
		profile.TerminalPoleDampingScale = 1.12
		profile.StationDirBoost = 1.12
		profile.StationRotLerpScale = 0.86
		profile.TerminalPoleImpulseScale = 0.38
		profile.TerminalPoleKickScale = 0.45
		profile.TerminalPoleStationDirBoost = 0.78
		profile.TerminalPoleFlipBlendScale = 0.68
		profile.TerminalPoleSwayDamping = 1.2
		profile.AllowTerminalHardFlip = false
		profile.DisableTerminalPoleCableSnap = false
		profile.CableSnapPerpMax = 9.25
		profile.CableSnapPerpMaxStation = 7.25
		profile.CableSnapDistanceRatio = 0.70
	end

	return profile
end

local TowGroundRaycastParams = RaycastParams.new()
TowGroundRaycastParams.FilterType = Enum.RaycastFilterType.Include
TowGroundRaycastParams.FilterDescendantsInstances = {Workspace.Terrain}

local function GetRuntimeLiftPerfTier()
	local tier = tonumber(LocalPlayer:GetAttribute("Settings_RuntimePerfTier"))
	if tier == nil then
		tier = tonumber(LocalPlayer:GetAttribute("RuntimePerformanceTier"))
	end
	tier = tonumber(tier) or 0
	return math.clamp(math.floor(tier + 0.5), 0, 3)
end

local function GetRuntimeLiftPerfScale()
	local tier = GetRuntimeLiftPerfTier()
	if tier >= 3 then
		return 0.34
	elseif tier >= 2 then
		return 0.5
	elseif tier >= 1 then
		return 0.74
	end
	return 1
end

local function GetRuntimeLiftUpdateScale()
	local tier = GetRuntimeLiftPerfTier()
	if tier >= 3 then
		return 2.2
	elseif tier >= 2 then
		return 1.7
	elseif tier >= 1 then
		return 1.25
	end
	return 1
end

local function GetLiftLoadUpdateScale(activeLiftCount, activeChairCount)
	local scale = 1
	if activeLiftCount >= 14 or activeChairCount >= 1400 then
		scale = 2.6
	elseif activeLiftCount >= 11 or activeChairCount >= 1100 then
		scale = 2.2
	elseif activeLiftCount >= 9 or activeChairCount >= 900 then
		scale = 1.9
	elseif activeLiftCount >= 7 or activeChairCount >= 650 then
		scale = 1.6
	elseif activeLiftCount >= 5 or activeChairCount >= 420 then
		scale = 1.35
	end
	return scale
end

local function GetLiftHideDistanceSq()
	local scale = GraphicsProfile.GetDistanceScale(LocalPlayer, "LiftRenderDistance")
	local runtimeScale = GetRuntimeLiftPerfScale()
	local tier = GetRuntimeLiftPerfTier()
	local distance = LOD_HIDE_BASE * scale * runtimeScale
	-- Keep a practical floor so chairs still restore near spawn on aggressive profiles.
	local minDistance = 420
	if tier >= 3 then
		minDistance = 240
	elseif tier >= 2 then
		minDistance = 290
	elseif tier >= 1 then
		minDistance = 360
	end
	distance = math.max(distance, minDistance)
	return distance * distance
end

local function GetTowFullRaycastSq()
	local scale = GraphicsProfile.GetDistanceScale(LocalPlayer, "LiftRenderDistance")
	local runtimeScale = GetRuntimeLiftPerfScale()
	local tier = GetRuntimeLiftPerfTier()
	local distance = TOW_FULL_RAYCAST_BASE * scale * runtimeScale
	local minDistance = 300
	if tier >= 3 then
		minDistance = 170
	elseif tier >= 2 then
		minDistance = 220
	elseif tier >= 1 then
		minDistance = 260
	end
	distance = math.max(distance, minDistance)
	return distance * distance
end

local function GetTowFarRaycastInterval()
	local preset = GraphicsProfile.GetPreset(LocalPlayer)
	if preset == "Low" then return 0.55 end
	if preset == "Medium" then return 0.36 end
	if preset == "High" then return 0.22 end
	return 0.15
end

local function GetLiftVisualUpdateInterval(distSq, loadScale)
	loadScale = loadScale or 1
	local hideSq = GetLiftHideDistanceSq()
	local tier = GetRuntimeLiftPerfTier()

	-- Keep nearby and mid-range lifts on full-rate updates so chairs stay smooth.
	if distSq <= hideSq * 0.30 then
		return 0
	end

	local interval = 1 / 55
	if distSq > hideSq * 0.55 then
		interval = 1 / 42
	end
	if distSq > hideSq * 0.78 then
		interval = 1 / 30
	end

	if loadScale >= 2.4 and distSq > hideSq * 0.60 then
		interval = math.max(interval, 1 / 26)
	elseif loadScale >= 1.8 and distSq > hideSq * 0.70 then
		interval = math.max(interval, 1 / 32)
	end

	if tier >= 3 and distSq > hideSq * 0.65 then
		interval = math.max(interval, 1 / 24)
	elseif tier >= 2 and distSq > hideSq * 0.75 then
		interval = math.max(interval, 1 / 28)
	end

	return interval
end

local function GetTowGroundRaycastBudget(loadScale)
	local tier = GetRuntimeLiftPerfTier()
	local budget
	if tier >= 3 then
		budget = 8
	elseif tier >= 2 then
		budget = 12
	elseif tier >= 1 then
		budget = 18
	else
		budget = 26
	end
	if loadScale and loadScale >= 2.2 then
		budget = math.max(8, budget - 2)
	end
	return budget
end

local function GetChairUpdateStride(liftDistSq, liftHideSq, chairCount, isSurfaceTow, loadScale)
	loadScale = loadScale or 1
	local tier = GetRuntimeLiftPerfTier()

	-- Keep a large near field at full-rate so visible chairs do not appear to run at 20Hz/5Hz.
	if isSurfaceTow or liftDistSq <= (liftHideSq * 0.55) then
		return 1
	end

	local stride = 1
	if liftDistSq > (liftHideSq * 0.55) then
		stride = 2
	end
	if liftDistSq > (liftHideSq * 0.82) then
		stride = 3
	end

	if chairCount >= 760 and loadScale >= 2.6 and liftDistSq > (liftHideSq * 0.9) then
		stride = math.max(stride, 4)
	end
	if tier >= 3 and chairCount >= 900 and loadScale >= 2.8 and liftDistSq > (liftHideSq * 0.94) then
		stride = math.max(stride, 5)
	end

	return math.clamp(stride, 1, 5)
end

local function GetFrameChairUpdateBudget(activeLiftCount, activeChairCount, loadScale)
	if activeLiftCount < 16 and activeChairCount < 1800 then
		return math.huge
	end

	local budget = 900
	if loadScale >= 2.4 then
		budget = 700
	end

	local tier = GetRuntimeLiftPerfTier()
	if tier >= 3 then
		budget = math.floor(budget * 0.8)
	elseif tier >= 2 then
		budget = math.floor(budget * 0.9)
	end

	return math.max(420, budget)
end

------------------------------------------------------------------------
-- STATE
------------------------------------------------------------------------
local ActiveLifts = {}
local LiftSetupTokens = {}
local PendingVisualRebuilds = {}
local VisualRebuildRetryCounts = {}
-- Some restored resorts have very long loops; a low client cap can truncate the line
-- and make the second half of a lift appear chairless after rejoin.
-- Keep this high enough for long lines, but avoid pathological client load.
local MAX_VISUAL_CHAIRS_PER_LIFT = 640
local GLOBAL_VISUAL_CHAIR_BUDGET = 1200
local SitAnimTrack = nil
local LastTouchTime = 0
local LastSeatTouchByKey = {}
local GuestRiders = {}
local GuestRideConnections = {} 
local GuestsFolder = nil
local GuestsChildAddedConn = nil
local GuestsChildRemovedConn = nil
local GuestSitAnims = {}
local RiderCollisionRestore = {}
local GuestRiderNextPoseAt = setmetatable({}, { __mode = "k" })
local LiftEventRemote = nil
local LocalRideStaleSince = nil
local LastRideExitSignalAt = 0
local BOARD_REQUEST_COOLDOWN = 0.6
local BOARD_REQUEST_PROXIMITY_SQ = 25
local STALE_RIDE_CLEAR_TIMEOUT = 3.5

local function SetRiderCollisionSuppressed(character, suppressed)
	if not character then
		return
	end
	if not suppressed then
		for part, state in pairs(RiderCollisionRestore) do
			if part and part.Parent and state then
				part.CanCollide = state.CanCollide
				part.CanTouch = state.CanTouch
			end
		end
		table.clear(RiderCollisionRestore)
		return
	end

	for _, desc in ipairs(character:GetDescendants()) do
		if desc:IsA("BasePart") then
			if RiderCollisionRestore[desc] == nil then
				RiderCollisionRestore[desc] = {
					CanCollide = desc.CanCollide,
					CanTouch = desc.CanTouch,
				}
			end
			desc.CanCollide = false
			desc.CanTouch = false
		end
	end
end

-- // HELPER: PLACEABLE UUID CACHE (avoids per-frame scan of PlacedObjects) //
local UUIDCache = {}
local UUIDCacheReady = false
local UUIDAttributeConnections = {}
local UUIDCacheFolderConnections = {}

local function ShouldTrackUUIDInstance(inst)
	return inst and (inst:IsA("Model") or inst:IsA("BasePart") or inst:IsA("Folder"))
end

local function RemoveInstanceFromUUIDCache(inst)
	for uuid, cachedInst in pairs(UUIDCache) do
		if cachedInst == inst then
			UUIDCache[uuid] = nil
		end
	end
end

local function DisconnectUUIDSignals()
	for inst, conn in pairs(UUIDAttributeConnections) do
		if conn then
			conn:Disconnect()
		end
		UUIDAttributeConnections[inst] = nil
	end
	for _, conn in ipairs(UUIDCacheFolderConnections) do
		conn:Disconnect()
	end
	UUIDCacheFolderConnections = {}
end

local function TrackUUIDInstance(inst)
	if not ShouldTrackUUIDInstance(inst) then
		return
	end

	if UUIDAttributeConnections[inst] then
		local uuid = inst:GetAttribute("UUID")
		if uuid then
			UUIDCache[uuid] = inst
		end
		return
	end

	local function syncUUID()
		RemoveInstanceFromUUIDCache(inst)
		local uuid = inst:GetAttribute("UUID")
		if uuid and inst:IsDescendantOf(Workspace) then
			UUIDCache[uuid] = inst
		end
	end

	UUIDAttributeConnections[inst] = inst:GetAttributeChangedSignal("UUID"):Connect(syncUUID)
	syncUUID()
end

local function UntrackUUIDInstance(inst)
	if not ShouldTrackUUIDInstance(inst) then
		return
	end
	local conn = UUIDAttributeConnections[inst]
	if conn then
		conn:Disconnect()
		UUIDAttributeConnections[inst] = nil
	end
	RemoveInstanceFromUUIDCache(inst)
end

local function RebuildUUIDCache()
	local folder = Workspace:FindFirstChild("PlacedObjects")
	DisconnectUUIDSignals()
	if not folder then
		UUIDCache = {}
		return
	end
	UUIDCache = {}
	TrackUUIDInstance(folder)
	for _, obj in ipairs(folder:GetDescendants()) do
		TrackUUIDInstance(obj)
	end
end

local function SetupUUIDCacheListeners()
	if UUIDCacheReady then return end
	local folder = Workspace:FindFirstChild("PlacedObjects")
	if not folder then return end
	UUIDCacheReady = true
	RebuildUUIDCache()
	table.insert(UUIDCacheFolderConnections, folder.DescendantAdded:Connect(function(child)
		TrackUUIDInstance(child)
	end))
	table.insert(UUIDCacheFolderConnections, folder.DescendantRemoving:Connect(function(child)
		UntrackUUIDInstance(child)
	end))
end

task.defer(SetupUUIDCacheListeners)

local function GetLiftEventRemote()
	if LiftEventRemote and LiftEventRemote.Parent then
		return LiftEventRemote
	end
	local eventsFolder = ReplicatedStorage:FindFirstChild("Events")
	LiftEventRemote = eventsFolder and eventsFolder:FindFirstChild("LiftEvent") or nil
	return LiftEventRemote
end

local function ForceClearLocalRideState()
	LocalPlayer:SetAttribute("RidingLift", nil)
	LocalPlayer:SetAttribute("RidingChair", nil)
	LocalPlayer:SetAttribute("RidingSeat", nil)

	local now = tick()
	if now - LastRideExitSignalAt >= 1.0 then
		local liftEvent = GetLiftEventRemote()
		if liftEvent then
			liftEvent:FireServer("Exit")
			LastRideExitSignalAt = now
		end
	end
end

local function TryRequestLiftBoard(lift, chairId, seatName)
	if not lift or chairId == nil then
		return false
	end
	if LocalPlayer:GetAttribute("RidingLift") then
		return false
	end

	if not UUIDCacheReady then
		SetupUUIDCacheListeners()
	end
	local realLiftModel = UUIDCache[lift.UniqueKey]
	if not realLiftModel then
		return false
	end
	if realLiftModel:GetAttribute("DisableSeats") == true then
		return false
	end

	local seatToken = tostring(seatName or "")
	local parsedSeatIndex = tonumber(string.match(seatToken, "Seat_(%d+)") or string.match(seatToken, "Seat(%d+)")) or 1
	local resolvedSeatName = "Seat_" .. math.max(1, parsedSeatIndex)

	local now = tick()
	if now - LastTouchTime < BOARD_REQUEST_COOLDOWN then
		return false
	end

	local liftEvent = GetLiftEventRemote()
	if not liftEvent then
		return false
	end

	LastTouchTime = now
	liftEvent:FireServer("RequestSit", realLiftModel, chairId, resolvedSeatName)
	return true
end

local Assets = ReplicatedStorage:WaitForChild("Assets")
local LiftFolders = Assets:FindFirstChild("Lifts")
local LiftAssetCacheById = {}

local function GetRuntimeChairCap()
	local preset = GraphicsProfile.GetPreset(LocalPlayer)
	local renderChoice = GraphicsProfile.GetDistanceChoice(LocalPlayer, "LiftRenderDistance")
	local tier = GetRuntimeLiftPerfTier()
	if tier >= 3 then
		return 130
	elseif tier >= 2 then
		return 180
	elseif tier >= 1 then
		return 260
	end
	if preset == "Low" then
		return 220
	end
	if renderChoice == "Near" then
		return 260
	end
	if renderChoice == "Medium" then
		return 420
	end
	return MAX_VISUAL_CHAIRS_PER_LIFT
end

local function GetGlobalChairBudget()
	local tier = GetRuntimeLiftPerfTier()
	if tier >= 3 then
		return 360
	elseif tier >= 2 then
		return 600
	elseif tier >= 1 then
		return 840
	end
	return GLOBAL_VISUAL_CHAIR_BUDGET
end

local function FindLiftAssetById(targetID, liftName)
	-- Only cache positive results; a nil/false cache entry would permanently block
	-- any lift whose ID attributes hadn't replicated yet on the first lookup (race condition).
	local cached = LiftAssetCacheById[targetID]
	if cached then return cached end

	local asset = nil
	if LiftFolders then
		for _, child in ipairs(LiftFolders:GetChildren()) do
			if (child:IsA("Model") or child:IsA("Folder")) and tostring(child:GetAttribute("ID")) == targetID then
				asset = child
				break
			end
		end
	end
	if not asset and type(liftName) == "string" and liftName ~= "" then
		asset = Assets:FindFirstChild(liftName, true)
	end
	if not asset then
		local scanned = 0
		for _, desc in ipairs(Assets:GetDescendants()) do
			local attrID = desc:GetAttribute("ID")
			if attrID and tostring(attrID) == targetID then
				asset = desc
				break
			end
			scanned += 1
			if scanned % 500 == 0 then
				task.wait()
			end
		end
	end

	if asset then
		LiftAssetCacheById[targetID] = asset
	end
	return asset
end

function CarpetTerrainUtil.GetWorldPivotPosition(inst)
	if not inst then return nil end
	if inst:IsA("Model") then return inst:GetPivot().Position end
	if inst:IsA("BasePart") then return inst.Position end
	return nil
end

function CarpetTerrainUtil.SamplePoint(flatPos, fallbackY)
	local originY = math.max(flatPos.Y + 600, fallbackY + 600, 2500)
	local result = Workspace:Raycast(Vector3.new(flatPos.X, originY, flatPos.Z), Vector3.new(0, -(originY + 4000), 0), CarpetTerrainUtil.Raycast)
	if result then
		return Vector3.new(flatPos.X, result.Position.Y, flatPos.Z)
	end
	return Vector3.new(flatPos.X, fallbackY, flatPos.Z)
end

function CarpetTerrainUtil.BuildSamples(startPos, endPos, numSamples)
	numSamples = math.max(2, numSamples or 2)
	local samples = table.create(numSamples)
	for i = 1, numSamples do
		local t = (i - 1) / (numSamples - 1)
		local flatPos = startPos:Lerp(endPos, t)
		samples[i] = CarpetTerrainUtil.SamplePoint(flatPos, flatPos.Y)
	end
	for _ = 1, 2 do
		for i = 2, numSamples - 1 do
			local prevY = samples[i - 1].Y
			local curr = samples[i]
			local nextY = samples[i + 1].Y
			samples[i] = Vector3.new(curr.X, (prevY + curr.Y + nextY) / 3, curr.Z)
		end
	end
	return samples
end

function CarpetTerrainUtil.GetEndpointPosition(stationModel)
	if not stationModel then return nil end
	local base = stationModel:FindFirstChild("Base") or stationModel.PrimaryPart or stationModel:FindFirstChildWhichIsA("BasePart")
	if base and base:IsA("BasePart") then
		local s1 = base:FindFirstChild("S1")
		if s1 and s1:IsA("Attachment") then
			return CarpetTerrainUtil.SamplePoint(s1.WorldPosition, s1.WorldPosition.Y)
		end
		return CarpetTerrainUtil.SamplePoint(base.Position, base.Position.Y)
	end
	local pivotPosition = CarpetTerrainUtil.GetWorldPivotPosition(stationModel)
	if pivotPosition then
		return CarpetTerrainUtil.SamplePoint(pivotPosition, pivotPosition.Y)
	end
	return nil
end

function CarpetTerrainUtil.SortSections(sections, startPos, axis)
	table.sort(sections, function(a, b)
		local aPos = CarpetTerrainUtil.GetWorldPivotPosition(a) or startPos
		local bPos = CarpetTerrainUtil.GetWorldPivotPosition(b) or startPos
		return (aPos - startPos):Dot(axis) < (bPos - startPos):Dot(axis)
	end)
	return sections
end

function CarpetTerrainUtil.AdaptVisual(lift, realLiftModel)
	if not realLiftModel then return end
	local sectionsFolder = realLiftModel:FindFirstChild("Sections")
	local startStation = realLiftModel:FindFirstChild("StartStation")
	local endStation = realLiftModel:FindFirstChild("EndStation")
	if not sectionsFolder or not startStation or not endStation then return end

	local startPos = CarpetTerrainUtil.GetEndpointPosition(startStation)
	local endPos = CarpetTerrainUtil.GetEndpointPosition(endStation)
	if not startPos or not endPos then return end

	local axis = endPos - startPos
	if axis.Magnitude < 0.1 then return end
	local axisDir = axis.Unit
	local sections = CarpetTerrainUtil.SortSections(sectionsFolder:GetChildren(), startPos, axisDir)
	if #sections == 0 then return end

	local points = CarpetTerrainUtil.BuildSamples(startPos, endPos, math.max(#sections + 1, 6))
	local pathLength = 0
	for i = 1, #points - 1 do
		pathLength += (points[i + 1] - points[i]).Magnitude
	end
	lift.CarpetPathPoints = points
	lift.CarpetPathLength = pathLength

	local configRot = CFrame.Angles(math.rad(lift.ConfigData.ChairRotationX or 0), math.rad(lift.ConfigData.ChairRotationY or 0), math.rad(lift.ConfigData.ChairRotationZ or 0))
	for i, section in ipairs(sections) do
		local sampleA = points[i]
		local sampleB = points[i + 1]
		local pos = sampleA:Lerp(sampleB, 0.5)
		local dir = sampleB - sampleA
		if dir.Magnitude < 0.1 then dir = axisDir else dir = dir.Unit end
		local targetCF = CFrame.lookAt(pos, pos + dir) * configRot
		if section:IsA("BasePart") then
			section.CFrame = targetCF
		elseif section:IsA("Model") then
			local secBase = section:FindFirstChild("Base") or section.PrimaryPart or section:FindFirstChildWhichIsA("BasePart")
			if secBase then
				local offset = secBase.CFrame:Inverse() * section:GetPivot()
				section:PivotTo(targetCF * offset)
			else
				section:PivotTo(targetCF)
			end
		end
	end
end

-- // HELPER: OCCUPANCY TRACKING //
local function IsChairOccupied(liftUUID, chairID)
	if LocalPlayer:GetAttribute("RidingLift") == liftUUID and LocalPlayer:GetAttribute("RidingChair") == chairID then
		return true
	end
	for guest, _ in pairs(GuestRiders) do
		if guest:GetAttribute("RidingLift") == liftUUID and guest:GetAttribute("RidingChair") == chairID then
			return true
		end
	end
	return false
end

local function PlayGuestSitAnim(guestModel)
	if GuestSitAnims[guestModel] then return end

	local liftID = guestModel:GetAttribute("RidingLift")
	if liftID and ActiveLifts[liftID] then
		local data = ActiveLifts[liftID].ConfigData
		if data.SurfaceTow == true or data.Type == "Carpet" then return end
	end

	local hum = guestModel:FindFirstChild("Humanoid")
	if not hum then return end
	local animator = hum:FindFirstChild("Animator")
	if not animator then animator = Instance.new("Animator", hum) end
	local anim = Instance.new("Animation")
	if hum.RigType == Enum.HumanoidRigType.R15 then
		anim.AnimationId = "rbxassetid://2506281703"
	else
		anim.AnimationId = "rbxassetid://103561694332640"
	end
	local track = animator:LoadAnimation(anim)
	track.Looped = true
	track.Priority = Enum.AnimationPriority.Action
	track:Play()
	GuestSitAnims[guestModel] = track
end

local function StopGuestSitAnim(guestModel)
	local track = GuestSitAnims[guestModel]
	if track then
		track:Stop()
		GuestSitAnims[guestModel] = nil
	end
end

local function UntrackGuestModel(model)
	local connections = GuestRideConnections[model]
	if connections then
		if typeof(connections) == "table" then
			for _, conn in pairs(connections) do
				if conn then
					conn:Disconnect()
				end
			end
		else
			connections:Disconnect()
		end
		GuestRideConnections[model] = nil
	end
	if GuestRiders[model] then
		GuestRiders[model] = nil
	end
	StopGuestSitAnim(model)
end

local function RefreshGuestRiderState(model)
	if not model or not model.Parent then
		UntrackGuestModel(model)
		return
	end
	local ridingLift = model:GetAttribute("RidingLift")
	local ridingChair = model:GetAttribute("RidingChair")
	local ridingSeat = model:GetAttribute("RidingSeat")
	local isRiding = ridingLift and ridingLift ~= false and ridingChair ~= nil and ridingSeat ~= nil
	if isRiding then
		GuestRiders[model] = true
	else
		GuestRiders[model] = nil
		StopGuestSitAnim(model)
	end
end

local function TrackGuestModel(model)
	if not model or not model:IsA("Model") then return end
	if GuestRideConnections[model] then return end
	GuestRideConnections[model] = {
		model:GetAttributeChangedSignal("RidingLift"):Connect(function()
			RefreshGuestRiderState(model)
		end),
		model:GetAttributeChangedSignal("RidingChair"):Connect(function()
			RefreshGuestRiderState(model)
		end),
		model:GetAttributeChangedSignal("RidingSeat"):Connect(function()
			RefreshGuestRiderState(model)
		end),
		model.AncestryChanged:Connect(function(_, parent)
			if not parent then
				UntrackGuestModel(model)
			end
		end),
	}
	RefreshGuestRiderState(model)
end

local function BindGuestsFolder(folder)
	if GuestsFolder == folder then return end

	if GuestsChildAddedConn then GuestsChildAddedConn:Disconnect(); GuestsChildAddedConn = nil end
	if GuestsChildRemovedConn then GuestsChildRemovedConn:Disconnect(); GuestsChildRemovedConn = nil end
	for model in pairs(GuestRideConnections) do
		UntrackGuestModel(model)
	end

	GuestsFolder = folder
	if not folder then return end

	GuestsChildAddedConn = folder.ChildAdded:Connect(function(child)
		if child:IsA("Model") then TrackGuestModel(child) end
	end)
	GuestsChildRemovedConn = folder.ChildRemoved:Connect(function(child)
		UntrackGuestModel(child)
	end)

	for _, child in ipairs(folder:GetChildren()) do
		if child:IsA("Model") then TrackGuestModel(child) end
	end
end

------------------------------------------------------------------------
-- UTILITIES
------------------------------------------------------------------------
local function TableToVec(t) return Vector3.new(t[1], t[2], t[3]) end
local function Clamp(val, lo, hi) return math.max(lo, math.min(hi, val)) end

local function ClampVec3(v, maxMag)
	if v.Magnitude > maxMag then return v.Unit * maxMag end
	return v
end

local function SafeLookAt(dir)
	local flat = Vector3.new(dir.X, 0, dir.Z)
	if flat.Magnitude < 0.001 then
		return CFrame.lookAt(Vector3.zero, Vector3.new(0, dir.Y > 0 and 1 or -1, 0), Vector3.xAxis)
	end
	return CFrame.lookAt(Vector3.zero, dir)
end

local function LerpDirection(current, target, alpha)
	if current.Magnitude < 0.001 then return target end
	if target.Magnitude < 0.001 then return current end
	local result = current + (target - current) * Clamp(alpha, 0, 1)
	if result.Magnitude < 0.001 then return current end
	return result.Unit
end

local function ClampLiftSag(p0, p1, sag)
	local span = (p1 - p0).Magnitude
	if span <= 0.001 then
		return 0
	end

	-- Match client sag limits to the same dynamic regime as server cable rendering.
	-- A low fixed clamp (e.g. 6) makes long detachable spans ride visibly above rope.
	local sagRatio = tonumber(CableConfig.SagRatio) or 0.035
	local dynamicSag = span * sagRatio
	local maxSag = math.max(2, dynamicSag * 1.5)
	return math.clamp(sag, -maxSag, maxSag)
end

local function UpdateTowRope(ropePart, p1, p2)
	local ropeVec = p2 - p1
	local dist = ropeVec.Magnitude
	if dist < 0.1 then
		ropePart.Transparency = 1
		return
	end

	-- Cylinders are lengthwise on the X axis, so align and size the rope on X.
	local xAxis = ropeVec.Unit
	local guideAxis = math.abs(xAxis:Dot(Vector3.yAxis)) > 0.98 and Vector3.zAxis or Vector3.yAxis
	local zAxis = xAxis:Cross(guideAxis)
	if zAxis.Magnitude < 0.001 then
		zAxis = Vector3.zAxis
	else
		zAxis = zAxis.Unit
	end
	local yAxis = zAxis:Cross(xAxis).Unit

	ropePart.Transparency = 0
	ropePart.Size = Vector3.new(dist, TOW_ROPE_THICKNESS, TOW_ROPE_THICKNESS)
	ropePart.CFrame = CFrame.fromMatrix((p1 + p2) / 2, xAxis, yAxis, zAxis)
end

local function GetStableModelPivot(model, referencePos)
	local pivot = model:GetPivot()
	local bboxCF, bboxSize = model:GetBoundingBox()
	if bboxSize.Magnitude <= 0.001 then
		return pivot
	end

	local stablePosition = bboxCF.Position
	local pivotToBBox = (pivot.Position - stablePosition).Magnitude
	local suspiciousPivotOffset = math.max(12, bboxSize.Magnitude * 1.5)
	if referencePos then
		local pivotToReference = (pivot.Position - referencePos).Magnitude
		local bboxToReference = (stablePosition - referencePos).Magnitude
		if pivotToReference > (bboxToReference + math.max(4, bboxSize.Magnitude * 0.35))
			and pivotToReference > (bboxToReference * 1.5) then
			return CFrame.new(stablePosition) * pivot.Rotation
		end
	end

	if pivotToBBox > suspiciousPivotOffset then
		return CFrame.new(stablePosition) * pivot.Rotation
	end

	return pivot
end

local function GetProxyPivot(obj)
	if obj:IsA("Model") then return GetStableModelPivot(obj) end
	return obj.CFrame
end

local function AddDoorAxisOffset(configData, amount, axisName, direction, currentX, currentY, currentZ)
	local axis = string.upper(tostring(axisName or "X"))
	local signedAmount = amount * direction
	if axis == "Y" then
		currentY += signedAmount
	elseif axis == "Z" then
		currentZ += signedAmount
	else
		currentX += signedAmount
	end
	return currentX, currentY, currentZ
end

local function GetDoorTranslation(configData, isLeftDoor, openAmount)
	local splitDistance = (configData.DoorOpenWidth or 1.5) * openAmount
	local splitDirection
	if isLeftDoor then
		splitDirection = tonumber(configData.DoorLeftDirection) or 1
	else
		splitDirection = tonumber(configData.DoorRightDirection) or -1
	end

	local x, y, z = 0, 0, 0
	x, y, z = AddDoorAxisOffset(configData, splitDistance, configData.DoorOpenAxis or "X", splitDirection, x, y, z)

	local outwardDistance = math.max(0, tonumber(configData.DoorOutwardAmount) or 0) * openAmount
	if outwardDistance > 0 then
		local outwardDirection = tonumber(configData.DoorOutwardDirection) or 1
		x, y, z = AddDoorAxisOffset(configData, outwardDistance, configData.DoorOutwardAxis or "X", outwardDirection, x, y, z)
	end

	return CFrame.new(x, y, z)
end

local function GetAnimatedComponentTransform(configData, componentName, closeAmount, hingeOffset)
	if closeAmount <= 0 then return CFrame.new() end
	local axis = string.upper(tostring(configData[componentName .. "RotateAxis"] or "Z"))
	local closeAngle = tonumber(configData[componentName .. "CloseAngle"]) or 0
	local rad = math.rad(closeAngle * closeAmount)
	local rotCF
	if axis == "X" then rotCF = CFrame.Angles(rad, 0, 0)
	elseif axis == "Y" then rotCF = CFrame.Angles(0, rad, 0)
	else rotCF = CFrame.Angles(0, 0, rad) end

	local transform = rotCF
	if hingeOffset then
		transform = hingeOffset * rotCF * hingeOffset:Inverse()
	end

	local closeOffset = configData[componentName .. "CloseOffset"]
	if typeof(closeOffset) == "Vector3" then
		transform = CFrame.new(closeOffset * closeAmount) * transform
	end

	return transform
end

local function CaptureAnimatedComponent(model, componentName, configData)
	local obj = model:FindFirstChild(componentName, true)
	if not obj then return nil end
	local objCF = obj:IsA("Model") and obj:GetPivot() or obj.CFrame
	local relCF = model:GetPivot():Inverse() * objCF
	
	local hingeOffset = nil
	local configuredHinge = configData and configData[componentName .. "HingeOffset"]
	if typeof(configuredHinge) == "Vector3" then
		hingeOffset = CFrame.new(configuredHinge)
	elseif typeof(configuredHinge) == "CFrame" then
		hingeOffset = configuredHinge
	elseif configData and configData[componentName .. "UsePivotAsHinge"] == true then
		hingeOffset = CFrame.new()
	else
		local hinge = obj:FindFirstChild("Hinge", true)
		if hinge then
			local hingeWorld = hinge:IsA("Attachment") and hinge.WorldCFrame.Position or hinge.Position
			hingeOffset = CFrame.new(objCF:Inverse() * CFrame.new(hingeWorld).Position)
		elseif obj:IsA("Model") then
			local modelPivot = model:GetPivot()
			local cf, size = obj:GetBoundingBox()
			local halfSize = size / 2
			local topCenter = cf.Position + cf.UpVector * halfSize.Y
			
			-- Fallback hinge guess for bubble/bar assets without an explicit hinge.
			-- Prefer config-driven hinge data for production assets.
			local candidates = {
				topCenter,
				topCenter + cf.RightVector * halfSize.X,
				topCenter - cf.RightVector * halfSize.X,
				topCenter + cf.LookVector * halfSize.Z,
				topCenter - cf.LookVector * halfSize.Z,
			}
			
			local bestPoint = topCenter
			local bestZ = -999
			for _, pt in ipairs(candidates) do
				local localZ = (modelPivot:Inverse() * CFrame.new(pt)).Position.Z
				if localZ > bestZ then
					bestZ = localZ
					bestPoint = pt
				end
			end
			
			local hingeLocal = objCF:Inverse() * CFrame.new(bestPoint)
			hingeOffset = CFrame.new(hingeLocal.Position)
		end
	end
	
	return {Obj = obj, RelCF = relCF, HingeOffset = hingeOffset}
end

local function PrepareVisualModel(model)
	for _, p in ipairs(model:GetDescendants()) do
		if p:IsA("BasePart") then
			p.CanCollide = false
			p.CanTouch = false
			p.CanQuery = false
			p.CastShadow = true
			p.Massless = true
			p.Anchored = true
		end
	end
end

local function ApplyChairColor(model, colors, id)
	if not colors then return end
	local c = colors[id % #colors + 1]
	if not c then return end
	for _, p in ipairs(model:GetDescendants()) do
		if p:IsA("BasePart") and (p.Name == "SeatColor" or p.Name:match("Seat") or p.Name:match("Cabin") or p.Name:match("Body")) then
			p.Color = c
		end
	end
end

local function FindGripAnchor(model)
	-- Highest-priority authored clamp points.
	local c2 = model:FindFirstChild("C2", true)
	if c2 and (c2:IsA("Attachment") or c2:IsA("BasePart")) then
		return c2
	end
	local exactGrip = model:FindFirstChild("Grip", true)
	if exactGrip and (exactGrip:IsA("Attachment") or exactGrip:IsA("BasePart")) then
		return exactGrip
	end

	local candidates = {}
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("Attachment") or d:IsA("BasePart") then
			local lower = string.lower(d.Name)
			if d.Name == "Grip" or string.find(lower, "grip", 1, true) ~= nil then
				table.insert(candidates, d)
			end
		end
	end
	if #candidates == 0 then
		return nil
	end

	local hasAttachmentCandidate = false
	for _, candidate in ipairs(candidates) do
		if candidate:IsA("Attachment") then
			hasAttachmentCandidate = true
			break
		end
	end

	local bboxCF, bboxSize = model:GetBoundingBox()
	local topCenter = bboxCF.Position + bboxCF.UpVector * (bboxSize.Y * 0.5)
	local topFlat = Vector3.new(topCenter.X, 0, topCenter.Z)
	local maxVertical = math.max(8, bboxSize.Y * 2.5)
	local maxHorizontal = math.max(8, math.max(bboxSize.X, bboxSize.Z) * 1.75)
	local maxCenterDistance = math.max(16, bboxSize.Magnitude * 1.75)

	local best = nil
	local bestScore = math.huge
	for _, candidate in ipairs(candidates) do
		if hasAttachmentCandidate and not candidate:IsA("Attachment") then
			continue
		end

		local pos = candidate:IsA("Attachment") and candidate.WorldPosition or candidate.Position
		local centerDistance = (pos - bboxCF.Position).Magnitude
		if centerDistance > maxCenterDistance then
			continue
		end

		local vertical = math.abs(pos.Y - topCenter.Y)
		local horizontal = (Vector3.new(pos.X, 0, pos.Z) - topFlat).Magnitude
		local outlierPenalty = 0
		if vertical > maxVertical then
			outlierPenalty += (vertical - maxVertical) * 3
		end
		if horizontal > maxHorizontal then
			outlierPenalty += (horizontal - maxHorizontal) * 2
		end
		local nameBias = (candidate.Name == "Grip") and -2 or 0
		local typeBias = candidate:IsA("Attachment") and -0.35 or 0
		local score = (vertical * 0.6) + horizontal + outlierPenalty + nameBias + typeBias
		if score < bestScore then
			bestScore = score
			best = candidate
		end
	end

	return best
end

local function GetCableAnchorWorldCFrame(model)
	-- Prefer the authored grip attachment/part first; this is the true cable hook point.
	local gripObj = FindGripAnchor(model)
	if gripObj then
		return gripObj:IsA("Attachment") and gripObj.WorldCFrame or gripObj.CFrame
	end

	-- Fallback for legacy assets that only ship a decorative grip model.
	local referenceModel = model:FindFirstChild("New Grip", true)
	if referenceModel and referenceModel:IsA("Model") then
		local cf, size = referenceModel:GetBoundingBox()
		return cf * CFrame.new(0, size.Y / 2, 0)
	end

	local cf, size = model:GetBoundingBox()
	return cf * CFrame.new(0, size.Y / 2, 0)
end

local function GetGripPivotOffset(model)
	local gripWorld = GetCableAnchorWorldCFrame(model)
	local authoredPivot = model:GetPivot()
	local stablePivot = GetStableModelPivot(model, gripWorld.Position)

	-- Preserve full grip-frame orientation to prevent 90°/looping drift on direction changes.
	if (authoredPivot.Position - gripWorld.Position).Magnitude <= 120 then
		return gripWorld:Inverse() * authoredPivot
	end
	return gripWorld:Inverse() * stablePivot
end

local function GetGripHeightOffset(model)
	local gripObj = FindGripAnchor(model)
	if not gripObj then
		return 0
	end

	local gripPos = gripObj:IsA("Attachment") and gripObj.WorldPosition or gripObj.Position
	local referenceModel = model:FindFirstChild("New Grip", true)
	local referenceCF, referenceSize
	if referenceModel and referenceModel:IsA("Model") then
		referenceCF, referenceSize = referenceModel:GetBoundingBox()
	else
		referenceCF, referenceSize = model:GetBoundingBox()
	end

	local referenceTop = referenceCF.Position + referenceCF.UpVector * (referenceSize.Y / 2)
	local gripHeight = math.abs(gripPos.Y - referenceTop.Y)
	if gripHeight < 0.01 then
		return 0
	end

	return math.clamp(gripHeight, 0, 4)
end

local function GetGripRenderPosition(railPos, lift, _chair, gripHeight)
	if not lift or not lift.ConfigData then
		return railPos
	end

	local configData = lift.ConfigData
	if configData.SurfaceTow == true then
		-- Surface-tow clamps can look too high against authored rope meshes.
		-- Respect explicit tow offsets first, then fall back to gripHeight.
		local towDrop = tonumber(configData.SurfaceTowGripDrop)
			or tonumber(configData.TowGripDrop)
			or tonumber(configData.TowCableDrop)
			or tonumber(configData.TowGripHeightOffset)
			or tonumber(configData.CableOffsetY)
			or tonumber(configData.GripDrop)
			or tonumber(lift.GripDrop)
		if towDrop == nil or towDrop <= 0 then
			towDrop = tonumber(gripHeight) or 0
		end
		towDrop = math.clamp(towDrop, 0, 12)
		if towDrop > 0 then
			return railPos - Vector3.new(0, towDrop, 0)
		end
		return railPos
	end

	local chairDrop = tonumber(lift.GripDrop)
	if chairDrop and chairDrop > 0 then
		return railPos - Vector3.new(0, math.clamp(chairDrop, 0, 8), 0)
	end
	return railPos
end

local function CreateLODChairVisual(_lift, _id)
	return nil
end

local function ClosestPointOnSegment(a, b, point)
	local ab = b - a
	local denom = ab:Dot(ab)
	if denom <= 0.0001 then
		return a
	end
	local t = (point - a):Dot(ab) / denom
	t = math.clamp(t, 0, 1)
	return a + (ab * t)
end

local function GetMajorAxisAndHalf(part)
	local size = part.Size
	if size.X >= size.Y and size.X >= size.Z then
		return part.CFrame.RightVector, size.X * 0.5
	elseif size.Y >= size.Z then
		return part.CFrame.UpVector, size.Y * 0.5
	end
	return part.CFrame.LookVector, size.Z * 0.5
end

local function EnsureLiftCableSegmentCache(lift, realLiftModel)
	if lift.CableSegCacheModel == realLiftModel and lift.CableSegCache then
		local cached = lift.CableSegCache
		if #cached > 0 then
			return cached
		end
	end

	local cache = {}
	for _, desc in ipairs(realLiftModel:GetDescendants()) do
		if desc:IsA("BasePart") and desc.Name == "CableSeg" then
			local axis, half = GetMajorAxisAndHalf(desc)
			table.insert(cache, {
				Part = desc,
				Axis = axis,
				Half = half,
			})
		end
	end

	lift.CableSegCacheModel = realLiftModel
	lift.CableSegCache = cache
	return cache
end

local function SnapPointToVisualCable(lift, realLiftModel, point, preferredIndex)
	if not realLiftModel or not point then
		return nil, nil, nil
	end
	local cache = EnsureLiftCableSegmentCache(lift, realLiftModel)
	if #cache == 0 then
		return nil, nil, nil
	end

	local bestPoint = nil
	local bestIndex = nil
	local bestDistSq = math.huge
	local preferredPoint = nil
	local preferredDistSq = nil

	local function evaluate(index, isPreferred)
		local seg = cache[index]
		if not seg or not seg.Part or not seg.Part.Parent then
			return
		end
		local center = seg.Part.CFrame.Position
		local axis = seg.Axis
		local half = seg.Half
		local a = center - axis * half
		local b = center + axis * half
		local candidate = ClosestPointOnSegment(a, b, point)
		local delta = point - candidate
		local distSq = delta:Dot(delta)
		if isPreferred then
			preferredPoint = candidate
			preferredDistSq = distSq
		end
		if distSq < bestDistSq then
			bestDistSq = distSq
			bestPoint = candidate
			bestIndex = index
		end
	end

	if preferredIndex and preferredIndex >= 1 and preferredIndex <= #cache then
		evaluate(preferredIndex, true)
		if preferredPoint and preferredDistSq and preferredDistSq <= 9 then
			return preferredPoint, preferredIndex, preferredDistSq
		end
	end

	for index = 1, #cache do
		if index ~= preferredIndex then
			evaluate(index, false)
		end
	end

	if preferredPoint and preferredDistSq and preferredDistSq <= (bestDistSq + 0.75) then
		return preferredPoint, preferredIndex, preferredDistSq
	end

	-- Allow larger corrections for lifts whose baked path is offset from visual cable,
	-- but still clamp to a safe range to avoid hopping to unrelated lines.
	if bestIndex and bestDistSq <= 196 then
		return bestPoint, bestIndex, bestDistSq
	end
	return nil, nil, nil
end

local function GetLiftVisualFocusPosition(realLiftModel, lift, camPos)
	if realLiftModel and realLiftModel.Parent then
		local startStation = realLiftModel:FindFirstChild("StartStation")
		local endStation = realLiftModel:FindFirstChild("EndStation")
		if startStation and endStation then
			local startCF = startStation:GetBoundingBox()
			local endCF = endStation:GetBoundingBox()
			if camPos then
				return ClosestPointOnSegment(startCF.Position, endCF.Position, camPos)
			end
			return startCF.Position:Lerp(endCF.Position, 0.5)
		end
		local cf = realLiftModel:GetBoundingBox()
		return cf.Position
	end
	if lift and lift.Chairs and lift.Chairs[1] and lift.Chairs[1].Phys then
		return lift.Chairs[1].Phys.LastWorldPos
	end
	return nil
end

------------------------------------------------------------------------
-- SIT / EXIT SYSTEM
------------------------------------------------------------------------
local function GetSitAnimId()
	local char = LocalPlayer.Character
	if char and char:FindFirstChild("Humanoid") then
		if char.Humanoid.RigType == Enum.HumanoidRigType.R15 then
			return "rbxassetid://2506281703"
		else
			return "rbxassetid://103561694332640"
		end
	end
	return "rbxassetid://103561694332640"
end

local function StartSitState()
	local char = LocalPlayer.Character
	if not char then return end

	local liftID = LocalPlayer:GetAttribute("RidingLift")
	local isStandingLift = false

	if liftID and ActiveLifts[liftID] then
		local data = ActiveLifts[liftID].ConfigData
		if data.SurfaceTow == true or data.Type == "Carpet" then 
			isStandingLift = true 
		end
	end

	local hum = char:FindFirstChild("Humanoid")
	local root = char:FindFirstChild("HumanoidRootPart")
	if not hum or not root then return end

	hum.PlatformStand = true
	hum.AutoRotate = false
	root.AssemblyLinearVelocity = Vector3.zero
	root.AssemblyAngularVelocity = Vector3.zero
	SetRiderCollisionSuppressed(char, true)

	if not isStandingLift then
		local animator = hum:FindFirstChild("Animator") or Instance.new("Animator", hum)
		local anim = Instance.new("Animation")
		anim.AnimationId = GetSitAnimId()
		SitAnimTrack = animator:LoadAnimation(anim)
		SitAnimTrack.Looped = true
		SitAnimTrack:Play()
	end
end

local function EndSitState()
	local char = LocalPlayer.Character
	if char and char:FindFirstChild("Humanoid") then
		char.Humanoid.PlatformStand = false
		char.Humanoid.AutoRotate = true

		if SitAnimTrack then 
			SitAnimTrack:Stop() 
			SitAnimTrack = nil
			local root = char:FindFirstChild("HumanoidRootPart")
			if root then
				root.AssemblyLinearVelocity = root.CFrame.LookVector * 20 + Vector3.new(0, 15, 0)
			end
		end
	end
	SetRiderCollisionSuppressed(char, false)
end

LocalPlayer:GetAttributeChangedSignal("RidingLift"):Connect(function()
	if LocalPlayer:GetAttribute("RidingLift") then 
		StartSitState() 
	else 
		EndSitState() 
		-- Add a longer cooldown to prevent immediately getting grabbed again at the drop-off station
		LastTouchTime = tick() + 2.0
	end
end)

UserInputService.JumpRequest:Connect(function()
	if LocalPlayer:GetAttribute("RidingLift") then
		local LiftEvent = ReplicatedStorage:FindFirstChild("Events") and ReplicatedStorage.Events:FindFirstChild("LiftEvent")
		if LiftEvent then LiftEvent:FireServer("Exit") end
	end
end)

------------------------------------------------------------------------
-- OPTIMIZED CABLE SOLVER
------------------------------------------------------------------------
local function FindSegmentForTime(segments, t)
	local left, right = 1, #segments
	while left <= right do
		local mid = math.floor((left + right) / 2)
		local seg = segments[mid]
		if t < seg.StartTime then
			right = mid - 1
		elseif t >= seg.EndTime then
			left = mid + 1
		else
			return seg, mid
		end
	end
	return nil, nil
end

local function GetPosFromTime_Optimized(lift, masterTime, chair)
	if not lift.TotalDuration or lift.TotalDuration <= 0 then return nil, nil, nil end

	if lift.ConfigData.Type == "Carpet" and lift.CarpetPathPoints and #lift.CarpetPathPoints > 1 and (lift.CarpetPathLength or 0) > 0.01 then
		local t = masterTime % lift.TotalDuration
		local targetDistance = (t / math.max(lift.TotalDuration, 0.001)) * lift.CarpetPathLength
		local remaining = targetDistance
		for i = 1, #lift.CarpetPathPoints - 1 do
			local a = lift.CarpetPathPoints[i]
			local b = lift.CarpetPathPoints[i + 1]
			local segLength = (b - a).Magnitude
			if segLength > 0.001 then
				if remaining <= segLength or i == (#lift.CarpetPathPoints - 1) then
					local alpha = math.clamp(remaining / segLength, 0, 1)
					local pos = a:Lerp(b, alpha)
					local tangent = (b - a).Unit
					return pos, tangent, lift.Segments[1]
				end
				remaining -= segLength
			end
		end
	end

	-- Single-span carpets can use a direct linear shortcut; multi-section carpets use the normal segment solver.
	if lift.ConfigData.Type == "Carpet" and #lift.Segments == 1 then
		local t = masterTime % lift.TotalDuration
		local seg = lift.Segments[1]
		if not seg then return nil, nil, nil end

		local p0, p1 = seg.P0, seg.P1
		local totalDist = (p1 - p0).Magnitude
		if totalDist < 0.01 then return p0, Vector3.new(0,0,1), seg end

		local currentDist = t * (seg.StartSpeed or 5)
		local alpha = math.clamp(currentDist / totalDist, 0, 1)

		local pos = p0:Lerp(p1, alpha)
		local tangent = (p1 - p0).Unit

		return pos, tangent, seg
	end

	-- STANDARD TWO-POINT MATH
	local t = masterTime % lift.TotalDuration

	local idx = chair.CachedSegmentIndex or 1
	local seg = lift.Segments[idx]
	local segIndex = idx

	if not (seg and t >= seg.StartTime and t < seg.EndTime) then
		local found = false
		local nextIdx = (idx % #lift.Segments) + 1
		local nextSeg = lift.Segments[nextIdx]
		if nextSeg and t >= nextSeg.StartTime and t < nextSeg.EndTime then
			seg = nextSeg
			segIndex = nextIdx
			chair.CachedSegmentIndex = nextIdx
			found = true
		else
			if #lift.Segments > 12 then
				local foundSeg, foundIdx = FindSegmentForTime(lift.Segments, t)
				if foundSeg then
					seg = foundSeg
					segIndex = foundIdx
					chair.CachedSegmentIndex = foundIdx
					found = true
				end
			else
				for i, s in ipairs(lift.Segments) do
					if t >= s.StartTime and t < s.EndTime then 
						seg = s 
						segIndex = i
						chair.CachedSegmentIndex = i
						found = true
						break 
					end
				end
			end
		end
		if not found then
			segIndex = #lift.Segments
			seg = lift.Segments[segIndex]
		end
	end

	if not seg then return nil, nil, nil end

	local segStartTime = seg.StartTime or 0
	local segEndTime = seg.EndTime or segStartTime
	local segDuration = math.max(0, segEndTime - segStartTime)
	local timeInSeg = Clamp(t - segStartTime, 0, segDuration)
	local dist = seg.StartDist or 0

	if seg.StartSpeed and seg.EndSpeed and math.abs(seg.StartSpeed - seg.EndSpeed) > 0.001 then
		local a = seg.Accel or 0
		dist = dist + (seg.StartSpeed * timeInSeg) + (0.5 * a * timeInSeg * timeInSeg)
	else
		dist = dist + (timeInSeg * (seg.StartSpeed or 5))
	end

	local alpha = 0
	if seg.SegLength and seg.SegLength > 0 then 
		alpha = (dist - (seg.SegStartDist or seg.StartDist or 0)) / seg.SegLength 
	elseif seg.Length and seg.Length > 0 then 
		alpha = (dist - (seg.StartDist or 0)) / seg.Length 
	end
	alpha = Clamp(alpha, 0, 1)

	local p0, p1 = seg.P0, seg.P1
	local pos, tangent

	local actualSag = 0
	if seg.IsStation or seg.ArcPoint then
		actualSag = 0
	elseif (seg.SagAmount and math.abs(seg.SagAmount) > 0.001) then
		actualSag = seg.SagAmount
	elseif seg.IsSag then
		actualSag = CableConfig.SagAmount
	else
		local spanDist = (p1 - p0).Magnitude
		if spanDist >= CableConfig.MinDistanceForSag then
			actualSag = CableConfig.SagAmount
		else
			actualSag = 0
		end
	end
	if math.abs(actualSag) > 0.001 then
		actualSag = ClampLiftSag(p0, p1, actualSag)
	end

	if seg.ArcPoint then
		lift.ArcSolveCache = lift.ArcSolveCache or {}
		local segCache = lift.ArcSolveCache[segIndex]
		if not segCache then
			segCache = {}
			lift.ArcSolveCache[segIndex] = segCache
		end

		local alphaKey = math.clamp(math.floor(alpha * 256 + 0.5), 0, 256)
		local cached = segCache[alphaKey]
		if cached and cached.P0 == p0 and cached.P1 == p1 and cached.Arc == seg.ArcPoint then
			pos = cached.Pos
			tangent = cached.Tangent
		else
			pos = CableMath.GetPointOnCircle(p0, seg.ArcPoint, p1, alpha)
			tangent = CableMath.GetCircleTangent(p0, seg.ArcPoint, p1, alpha)
			segCache[alphaKey] = {Pos = pos, Tangent = tangent, P0 = p0, P1 = p1, Arc = seg.ArcPoint}
		end
	elseif math.abs(actualSag) > 0.001 then
		pos = CableMath.GetPointOnCurve(p0, p1, actualSag, alpha)
		tangent = CableMath.GetTangent(p0, p1, actualSag, alpha)
	else
		pos = p0:Lerp(p1, alpha)
		tangent = (p1 - p0).Unit
	end

	if not tangent or tangent.Magnitude < 0.001 then
		local fallback = p1 - p0
		tangent = (fallback.Magnitude > 0.001) and fallback.Unit or Vector3.zAxis
	end

	return pos, tangent, seg
end

------------------------------------------------------------------------
-- CHAIR CREATION
------------------------------------------------------------------------
local function CreateChair(lift, id, offsetTime)
	if not lift.Config.Model then return nil end
	local model = lift.Config.Model:Clone()
	model.Name = "Chair_" .. id

	if not model.PrimaryPart then
		local p = Instance.new("Part")
		p.Name = "AutoPrimaryPart"
		p.Transparency = 1
		p.CanCollide = false
		p.CanTouch = false
		p.CanQuery = false
		p.Anchored = true
		p.Massless = true
		p.Size = Vector3.new(1, 1, 1)
		p.CFrame = GetStableModelPivot(model)
		p.Parent = model
		model.PrimaryPart = p
	end

	PrepareVisualModel(model)

	local body = model:FindFirstChild("Body", true) or model
	local bodyPivot = GetProxyPivot(body)

	local tilter = model:FindFirstChild("Tilter", true)
	local attC1, attC2 = nil, nil
	if tilter then attC1 = tilter:FindFirstChild("C1", true) end
	attC2 = model:FindFirstChild("C2", true)
	if not attC2 then
		for _, desc in ipairs(model:GetDescendants()) do
			if desc:IsA("Attachment") and desc.Name == "Grip" then
				attC2 = desc
				break
			end
		end
	end

	local c2OffsetFromBody = CFrame.new()
	if attC2 then
		c2OffsetFromBody = bodyPivot:Inverse() * attC2.WorldCFrame
	end

	local attRaycast = model:FindFirstChild("Raycast", true)
	local raycastOffsetFromBody = CFrame.new()
	local hasRaycast = false
	if attRaycast then
		raycastOffsetFromBody = bodyPivot:Inverse() * attRaycast.WorldCFrame
		hasRaycast = true
	end

	local vectorC2ToRaycast = Vector3.new(0, -5, 0)
	if attC2 and attRaycast then
		vectorC2ToRaycast = attRaycast.Position - attC2.Position
	end

	local seatOffsets = {} 
	local seatTriggers = {}
	local seatCounter = 0
	local seatYawOffsetDeg = tonumber(lift.ConfigData.SeatTriggerYawOffsetDeg) or 0
	local seatYawOffset = CFrame.Angles(0, math.rad(seatYawOffsetDeg), 0)

	local function IsSeatTriggerCandidate(part)
		if not part or not part:IsA("BasePart") then
			return false
		end
		return part.Name:match("^Seat[_%d]*$") ~= nil
	end

	local function BindSeatTrigger(seatTrigger, uniqueName)
		if math.abs(seatYawOffsetDeg) > 0.001 then
			seatTrigger.CFrame = seatTrigger.CFrame * seatYawOffset
		end

		seatTrigger:SetAttribute("IsLiftSeat", true)
		seatOffsets[uniqueName] = bodyPivot:Inverse() * seatTrigger.CFrame
		seatTrigger.CanTouch = false
		table.insert(seatTriggers, seatTrigger)

		seatTrigger.Touched:Connect(function(hit)
			if hit.Parent == LocalPlayer.Character then
				local now = tick()
				local touchKey = tostring(lift.UniqueKey) .. ":" .. tostring(id) .. ":" .. tostring(uniqueName)
				local lastSeatTouch = LastSeatTouchByKey[touchKey] or 0
				if (now - LastTouchTime) > GLOBAL_SEAT_TOUCH_COOLDOWN and (now - lastSeatTouch) > PER_SEAT_TOUCH_COOLDOWN then
					if not LocalPlayer:GetAttribute("RidingLift") then
						if not UUIDCacheReady then
							SetupUUIDCacheListeners()
						end
						local realLiftModel = UUIDCache[lift.UniqueKey]

						if realLiftModel and realLiftModel:GetAttribute("DisableSeats") == true then
							return
						end

						LastTouchTime = now
						LastSeatTouchByKey[touchKey] = now
						if realLiftModel then
							local LiftEvent = ReplicatedStorage:FindFirstChild("Events") and ReplicatedStorage.Events:FindFirstChild("LiftEvent")
							if LiftEvent then
								LiftEvent:FireServer("RequestSit", realLiftModel, id, uniqueName)
							end
						end
					end
				end
			end
		end)
	end

	for _, child in ipairs(model:GetDescendants()) do
		if IsSeatTriggerCandidate(child) then
			local hasVisualMesh = child:IsA("MeshPart")
				or (child:FindFirstChildOfClass("SpecialMesh") ~= nil)
				or (child:IsA("UnionOperation"))

			seatCounter = seatCounter + 1
			local uniqueName = "Seat_" .. seatCounter

			local seatTrigger = child
			if hasVisualMesh then
				-- Keep the visible seat mesh; create an invisible trigger part instead.
				seatTrigger = Instance.new("Part")
				seatTrigger.Name = uniqueName
				seatTrigger.Size = child.Size
				seatTrigger.CFrame = child.CFrame
				seatTrigger.Transparency = 1
				seatTrigger.CanCollide = false
				seatTrigger.CanTouch = false
				seatTrigger.CanQuery = false
				seatTrigger.Anchored = true
				seatTrigger.Massless = true
				seatTrigger.Parent = model
				child.Name = "SeatMesh_" .. seatCounter
			else
				child.Name = uniqueName
				child.Transparency = 1
				child.CanTouch = false
				seatTrigger = child
			end

			BindSeatTrigger(seatTrigger, uniqueName)
		end
	end

	if seatCounter == 0 and lift.ConfigData.Type ~= "Carpet" then
		local fallbackSeatCount = math.max(1, tonumber(lift.ConfigData.Capacity) or 1)
		local lateralStep = fallbackSeatCount > 1 and 1.6 or 0
		for index = 1, fallbackSeatCount do
			seatCounter = seatCounter + 1
			local uniqueName = "Seat_" .. seatCounter
			local lateralOffset = (index - ((fallbackSeatCount + 1) * 0.5)) * lateralStep
			local seatTrigger = Instance.new("Part")
			seatTrigger.Name = uniqueName
			seatTrigger.Size = Vector3.new(2.2, 1, 2.2)
			seatTrigger.CFrame = bodyPivot * CFrame.new(lateralOffset, 0, 0)
			seatTrigger.Transparency = 1
			seatTrigger.CanCollide = false
			seatTrigger.CanTouch = false
			seatTrigger.CanQuery = false
			seatTrigger.Anchored = true
			seatTrigger.Massless = true
			seatTrigger.Parent = model
			BindSeatTrigger(seatTrigger, uniqueName)
		end
	end

	local doors = nil
	if lift.ConfigData.HasDoors then
		local doorL = model:FindFirstChild("DoorL", true)
		local doorR = model:FindFirstChild("DoorR", true)
		if doorL or doorR then
			local modelPivot = model:GetPivot()
			doors = { State = 0, TargetState = 0, L = nil, R = nil }
			if doorL then
				local relCF = modelPivot:Inverse() * (doorL:IsA("Model") and doorL:GetPivot() or doorL.CFrame)
				doors.L = { Obj = doorL, RelCF = relCF }
			end
			if doorR then
				local relCF = modelPivot:Inverse() * (doorR:IsA("Model") and doorR:GetPivot() or doorR.CFrame)
				doors.R = { Obj = doorR, RelCF = relCF }
			end
		end
	end

	local bubbleBar = nil
	if lift.ConfigData.HasBubbleBar then
		local bar = CaptureAnimatedComponent(model, "Bar", lift.ConfigData)
		local bubble = CaptureAnimatedComponent(model, "Bubble", lift.ConfigData)
		if bar or bubble then
			bubbleBar = {
				State = nil,
				TargetState = 1,
				Bar = bar,
				Bubble = bubble,
			}
		end
	end

	ApplyChairColor(model, lift.Config.Colors, id)
	local gripAnchor = FindGripAnchor(model)
	local pivotFromGrip = GetGripPivotOffset(model)
	local gripWorld = model:GetPivot() * pivotFromGrip:Inverse()
	local tilterFromGrip = CFrame.new()
	if tilter then
		local tCF = tilter:IsA("Model") and tilter:GetPivot() or tilter.CFrame
		tilterFromGrip = gripWorld:Inverse() * tCF
	end

	local towRope = nil
	if lift.ConfigData.SurfaceTow == true then
		towRope = Instance.new("Part")
		towRope.Name = "TowRope"
		towRope.Shape = Enum.PartType.Cylinder
		towRope.Color = Color3.fromRGB(20,20,20)
		towRope.Material = Enum.Material.Fabric
		towRope.Anchored = true
		towRope.CanCollide = false
		towRope.CanTouch = false
		towRope.CanQuery = false
		towRope.CastShadow = true
		towRope.Parent = model 
	end

	local lodVisual = CreateLODChairVisual(lift, id)

	return {
		Model = model,
		TilterObj = tilter, 
		BodyObj = body,        
		Doors = doors,
		BubbleBar = bubbleBar,
		OffsetTime = offsetTime,
		ID = id,
		PivotFromGrip = pivotFromGrip,
		LODPivotFromGrip = lodVisual and lodVisual.PivotFromGrip or CFrame.new(),
		TilterFromGrip = tilterFromGrip,
		HasGripAnchor = gripAnchor ~= nil,
		TowRope = towRope, 
		AttC1 = attC1, 
		AttC2 = attC2, 
		AttRaycast = attRaycast,
		C2OffsetFromBody = c2OffsetFromBody, 
		RaycastOffsetFromBody = raycastOffsetFromBody,
		VectorC2ToRaycast = vectorC2ToRaycast, 
		HasRaycast = hasRaycast,
		SeatOffsets = seatOffsets,
		SeatTriggers = seatTriggers,
		SeatTouchEnabled = false,
		NextSimplePoseAt = 0,
		CachedSegmentIndex = 1,

		Phys = {
			LastWorldPos = nil,
			LastVelocity = Vector3.zero,
			LastTangent  = Vector3.new(1, 0, 0),
			FilteredAccel = Vector3.zero,

			PitchAngle = 0,
			PitchVel   = 0,
			RollAngle  = 0,
			RollVel    = 0,

			VerticalImpulse = 0,

			VisualRot = CFrame.new(),
			SmoothedBodyDir = nil,

			WasOnPole = false,
			WindSeed = math.random() * 1000,

			GroundHit = nil, 
		},

		WeightMult = 0.85 + (math.random() * 0.3),
		LengthMult = 0.9 + (math.random() * 0.2),
	}
end

------------------------------------------------------------------------
-- LIFT SETUP FROM DATA
------------------------------------------------------------------------
local function GetAuthoritativeLiftTime(cacheObj)
	if not cacheObj then
		return 0
	end

	local refTime = tonumber(cacheObj:GetAttribute("RefTime")) or 0
	local refTimestamp = tonumber(cacheObj:GetAttribute("RefTimestamp"))
	local refSpeed = tonumber(cacheObj:GetAttribute("RefSpeed")) or 0
	local status = tostring(cacheObj:GetAttribute("Status") or "Running")

	if not refTimestamp or status == "Broken" then
		return refTime
	end

	local elapsed = math.max(0, Workspace:GetServerTimeNow() - refTimestamp)
	return refTime + (elapsed * refSpeed)
end

local SetupLiftFromData

local function QueueLiftVisualRebuild(uniqueKey, cacheObj, reason)
	if not uniqueKey or not cacheObj or not cacheObj:IsA("StringValue") then
		return
	end
	if PendingVisualRebuilds[uniqueKey] then
		return
	end
	local retryCount = (VisualRebuildRetryCounts[uniqueKey] or 0) + 1
	VisualRebuildRetryCounts[uniqueKey] = retryCount
	local delayTime = math.min(1.5, 0.2 + ((retryCount - 1) * 0.15))
	PendingVisualRebuilds[uniqueKey] = true
	task.delay(delayTime, function()
		PendingVisualRebuilds[uniqueKey] = nil
		if not cacheObj.Parent then
			return
		end
		warn(string.format("[LiftClient] Rebuilding visuals for %s (%s).", tostring(uniqueKey), tostring(reason or "retry")))
		SetupLiftFromData(uniqueKey, cacheObj.Value, cacheObj)
	end)
end

SetupLiftFromData = function(uniqueKey, rawDataString, cacheObj)
	LiftSetupTokens[uniqueKey] = (LiftSetupTokens[uniqueKey] or 0) + 1
	local setupToken = LiftSetupTokens[uniqueKey]

	if ActiveLifts[uniqueKey] and ActiveLifts[uniqueKey].VisualFolder then
		ActiveLifts[uniqueKey].VisualFolder:Destroy()
	end
	ActiveLifts[uniqueKey] = nil

	local success, rawData = pcall(function()
		return game:GetService("HttpService"):JSONDecode(rawDataString)
	end)
	if not success then
		QueueLiftVisualRebuild(uniqueKey, cacheObj, "cache decode failed")
		return 
	end

	local liftName = rawData.ConfigName
	local configData = Config.Items[liftName]
	if not configData then
		-- Fallback: resolve via model ID attribute in case name was corrupted by rename
		local liftModel = UUIDCache[uniqueKey]
		if liftModel then
			local modelId = liftModel:GetAttribute("ID")
			if modelId then
				local resolvedName
				resolvedName, configData = Config.GetItemById(modelId)
				if resolvedName then liftName = resolvedName end
			end
		end
		if not configData then
			QueueLiftVisualRebuild(uniqueKey, cacheObj, "missing config")
			return
		end
	end

	if type(rawData.Segments) ~= "table" or #rawData.Segments == 0 then
		QueueLiftVisualRebuild(uniqueKey, cacheObj, "missing path segments")
		return
	end

	local segments = {}
	for _, s in ipairs(rawData.Segments) do
		table.insert(segments, {
			P0 = TableToVec(s.P0), P1 = TableToVec(s.P1),
			ArcPoint = s.ArcPoint and TableToVec(s.ArcPoint) or nil,
			Length = s.Length or 1, StartDist = s.StartDist or 0, EndDist = s.EndDist or 1,
			SegStartDist = s.SegStartDist, SegLength = s.SegLength,
			StartTime = s.StartTime or 0, EndTime = s.EndTime or 1,
			StartSpeed = s.StartSpeed or s.SpeedLimit or 5, EndSpeed = s.EndSpeed or s.SpeedLimit or 5, Accel = s.Accel or 0,
			IsStation = s.IsStation, IsPole = s.IsPole,
			IsSag = s.IsSag, SagAmount = s.SagAmount,
			DoorState = s.DoorState
		})
	end

	local folder = Instance.new("Folder")
	folder.Name = "Visual_" .. uniqueKey

	local targetID = tostring(configData.ID)
	local mainAsset = FindLiftAssetById(targetID, liftName)

	if not mainAsset then 
		QueueLiftVisualRebuild(uniqueKey, cacheObj, "lift asset missing")
		return 
	end

	local actualModel = nil
	local lodModel = nil

	-- // FORCE INVISIBLE SEAT GENERATION FOR CARPETS
	if configData.Type == "Carpet" then
		actualModel = Instance.new("Model")
		actualModel.Name = "CarpetInvisibleSeat"

		local body = Instance.new("Part")
		body.Name = "Body"
		body.Size = Vector3.new(4, 1, 4)
		body.Transparency = 1
		body.CanCollide = false
		body.Anchored = true
		body.CFrame = CFrame.new(0, 0, 0)
		body.Parent = actualModel
		actualModel.PrimaryPart = body

		local seat = Instance.new("Part")
		seat.Name = "Seat1"
		seat.Size = Vector3.new(4, 6, 4)
		seat.Transparency = 1
		seat.CanCollide = false
		seat.Anchored = true
		seat.CFrame = CFrame.new(0, 2.5, 0) 
		seat.Parent = actualModel

		local grip = Instance.new("Part")
		grip.Name = "Grip"
		grip.Transparency = 1
		grip.CanCollide = false
		grip.CFrame = CFrame.new(0, 0, 0)
		grip.Parent = actualModel
	else
		if mainAsset:IsA("Model") and (mainAsset.Name == "Chair" or mainAsset.Name == "Gondola") then
			actualModel = mainAsset
		else
			actualModel = mainAsset:FindFirstChild("Chair", true) or mainAsset:FindFirstChild("Gondola", true)
		end
		if not actualModel then
			for _, child in ipairs(mainAsset:GetChildren()) do
				if child:IsA("Model") and child.Name ~= "StartStation" and child.Name ~= "EndStation" and child.Name ~= "Pole" and child.Name ~= "ADPole" then
					actualModel = child
					break
				end
			end
		end
	end

	if not actualModel then 
		QueueLiftVisualRebuild(uniqueKey, cacheObj, "carrier model missing")
		return 
	end

	local totalDuration = math.max(1, tonumber(rawData.TotalDuration) or 60)
	local correctedTimeSpacing = tonumber(rawData.CorrectedTimeSpacing) or 5
	if correctedTimeSpacing <= 0 then
		correctedTimeSpacing = 5
	end

	local configuredGripHeight = tonumber(configData.GripHeight) or 0
	local gripHeight = GetGripHeightOffset(actualModel)
	if configuredGripHeight > 0 then
		gripHeight = configuredGripHeight
	end
	local configuredGripDrop = tonumber(configData.GripDrop) or tonumber(configData.ChairGripDrop)
	local gripDrop = 0
	if configData.AllowVisualGripDrop == true and configuredGripDrop and configuredGripDrop >= 0 then
		gripDrop = configuredGripDrop
	end

	local liftObj = {
		Config = { Model = actualModel, Colors = configData.ChairColors },
		LODModelSource = nil,
		UseLODChairs = false,
		Segments = segments,
		TotalDuration = totalDuration,
		CorrectedTimeSpacing = correctedTimeSpacing,
		VisualFolder = folder,
		UniqueKey = uniqueKey,
		ConfigData = configData,
		LiftName = liftName,
		PhysicsProfile = BuildLiftPhysicsProfile(configData, liftName),
		GripHeight = gripHeight,
		GripDrop = gripDrop,

		CurrentSmoothSpeed = tonumber(cacheObj and cacheObj:GetAttribute("RefSpeed")) or 1,
		RunningTime = GetAuthoritativeLiftTime(cacheObj),
		LastStatus = tostring(cacheObj and cacheObj:GetAttribute("Status") or "Running")
	}

	local chairs = {}
	local chairCount = math.max(1, math.round(liftObj.TotalDuration / liftObj.CorrectedTimeSpacing))
	local activeLiftCount = 0
	for _ in pairs(ActiveLifts) do
		activeLiftCount += 1
	end
	local globalBudget = GetGlobalChairBudget()
	local perLiftBudget = math.max(80, math.floor(globalBudget / math.max(1, activeLiftCount + 1)))
	local runtimeChairCap = math.max(1, math.min(MAX_VISUAL_CHAIRS_PER_LIFT, GetRuntimeChairCap(), perLiftBudget))
	if chairCount > runtimeChairCap then
		warn(string.format("[LiftClient] Clamping visual chair count for %s from %d to %d.", tostring(uniqueKey), chairCount, runtimeChairCap))
		chairCount = runtimeChairCap
	end
	for i = 1, chairCount do
		if LiftSetupTokens[uniqueKey] ~= setupToken then
			folder:Destroy()
			return
		end
		local offsetTime = (i - 1) * liftObj.CorrectedTimeSpacing
		local chair = CreateChair(liftObj, i, offsetTime)
		if chair then table.insert(chairs, chair) end
		if i % 6 == 0 then
			task.wait()
		end
	end

	if LiftSetupTokens[uniqueKey] ~= setupToken then
		folder:Destroy()
		return
	end

	folder.Parent = Workspace
	liftObj.Chairs = chairs
	liftObj.ExpectedChairCount = chairCount
	liftObj.SetupCompletedAt = GlobalTime
	liftObj.LastSelfHealAt = 0
	ActiveLifts[uniqueKey] = liftObj
	VisualRebuildRetryCounts[uniqueKey] = 0
	if #chairs == 0 and cacheObj then
		QueueLiftVisualRebuild(uniqueKey, cacheObj, "empty setup")
	end
end

BindGuestsFolder(Workspace:FindFirstChild("Guests"))
Workspace.ChildAdded:Connect(function(child)
	if child.Name == "Guests" and child:IsA("Folder") then
		BindGuestsFolder(child)
	end
end)
Workspace.ChildRemoved:Connect(function(child)
	if child == GuestsFolder then
		BindGuestsFolder(nil)
	end
end)

------------------------------------------------------------------------
-- MAIN RENDER LOOP
------------------------------------------------------------------------
local GlobalTime = 0

RunService:BindToRenderStep("LiftClient_Render", Enum.RenderPriority.Camera.Value - 1, function(dt)
	dt = math.min(dt, 0.05)
	GlobalTime = GlobalTime + dt

	local camPos = Workspace.CurrentCamera.CFrame.Position
	local liftCache = ReplicatedStorage:FindFirstChild("LiftCache")
	if not liftCache then return end

	local occupiedChairsByLift = {}
	do
		local localLift = LocalPlayer:GetAttribute("RidingLift")
		local localChair = LocalPlayer:GetAttribute("RidingChair")
		if localLift and localChair ~= nil then
			local liftKey = tostring(localLift)
			local chairMap = occupiedChairsByLift[liftKey]
			if not chairMap then
				chairMap = {}
				occupiedChairsByLift[liftKey] = chairMap
			end
			chairMap[tostring(localChair)] = true
		end

		for guestModel in pairs(GuestRiders) do
			if guestModel and guestModel.Parent then
				local guestLift = guestModel:GetAttribute("RidingLift")
				local guestChair = guestModel:GetAttribute("RidingChair")
				if guestLift and guestChair ~= nil then
					local liftKey = tostring(guestLift)
					local chairMap = occupiedChairsByLift[liftKey]
					if not chairMap then
						chairMap = {}
						occupiedChairsByLift[liftKey] = chairMap
					end
					chairMap[tostring(guestChair)] = true
				end
			end
		end
	end

	local activeLiftCount = 0
	local activeChairCount = 0
	for _, activeLift in pairs(ActiveLifts) do
		activeLiftCount += 1
		activeChairCount += #(activeLift.Chairs or {})
	end
	local loadUpdateScale = GetLiftLoadUpdateScale(activeLiftCount, activeChairCount)
	local runtimeLiftTier = GetRuntimeLiftPerfTier()
	local heavyDynamicsMode = runtimeLiftTier >= 2 or loadUpdateScale >= 2.1
	local chairFrameBudget = GetFrameChairUpdateBudget(activeLiftCount, activeChairCount, loadUpdateScale)
	local seatTouchRecheckInterval = 0.2
	if loadUpdateScale >= 3 then
		seatTouchRecheckInterval = STRESS_SEAT_TOUCH_RECHECK_INTERVAL
	elseif heavyDynamicsMode then
		seatTouchRecheckInterval = HEAVY_SEAT_TOUCH_RECHECK_INTERVAL
	end

	for uniqueKey, lift in pairs(ActiveLifts) do
		local dataValue = liftCache:FindFirstChild(uniqueKey)
		if not dataValue then continue end

		local targetSpeed = tonumber(dataValue:GetAttribute("RefSpeed")) or 1
		local currentStatus = tostring(dataValue:GetAttribute("Status") or "Running")
		local authoritativeTime = GetAuthoritativeLiftTime(dataValue)

		if lift.ConfigData.Type == "Carpet" and (not lift.NextCarpetAdaptAt or GlobalTime >= lift.NextCarpetAdaptAt) then
			if not UUIDCacheReady then SetupUUIDCacheListeners() end
			CarpetTerrainUtil.AdaptVisual(lift, UUIDCache[uniqueKey])
			lift.NextCarpetAdaptAt = GlobalTime + CarpetTerrainUtil.AdaptInterval
		end

		local eStopTriggered = false
		if currentStatus == "Broken" and lift.LastStatus ~= "Broken" then
			eStopTriggered = true
		end
		lift.LastStatus = currentStatus

		if currentStatus == "Broken" then
			lift.CurrentSmoothSpeed = 0 
		elseif math.abs(lift.CurrentSmoothSpeed - targetSpeed) > 0.01 then
			local direction = (targetSpeed > lift.CurrentSmoothSpeed) and 1 or -1
			lift.CurrentSmoothSpeed = lift.CurrentSmoothSpeed + (direction * SPEED_ACCEL * dt)

			if direction == 1 and lift.CurrentSmoothSpeed > targetSpeed then lift.CurrentSmoothSpeed = targetSpeed end
			if direction == -1 and lift.CurrentSmoothSpeed < targetSpeed then lift.CurrentSmoothSpeed = targetSpeed end
		else
			lift.CurrentSmoothSpeed = targetSpeed
		end

		local predictedTime = lift.RunningTime + (dt * lift.CurrentSmoothSpeed)
		if math.abs(authoritativeTime - lift.RunningTime) > 0.35 then
			lift.RunningTime = authoritativeTime
		else
			lift.RunningTime = predictedTime + ((authoritativeTime - predictedTime) * math.min(dt * 8, 1))
		end
		local masterTime = lift.RunningTime

		local forceCloseDoors = false
		if not UUIDCacheReady then SetupUUIDCacheListeners() end
		local realLiftModel = UUIDCache[lift.UniqueKey]
		if realLiftModel and realLiftModel:GetAttribute("CloseDoors") == true then
			forceCloseDoors = true
		end

		local liftFocusPos = GetLiftVisualFocusPosition(realLiftModel, lift, camPos)
		local liftDistSq = liftFocusPos and (liftFocusPos - camPos):Dot(liftFocusPos - camPos) or 0
		local localRidingLift = LocalPlayer:GetAttribute("RidingLift")
		local localRidingChair = LocalPlayer:GetAttribute("RidingChair")
		local shouldForceUpdateForRider = tostring(localRidingLift or "") == tostring(lift.UniqueKey)

		local visualInterval = GetLiftVisualUpdateInterval(liftDistSq, loadUpdateScale)
		if shouldForceUpdateForRider then
			visualInterval = 0
		end
		if visualInterval > 0 then
			local nextVisualUpdateAt = lift.NextVisualUpdateAt or 0
			if GlobalTime < nextVisualUpdateAt then
				continue
			end
			lift.NextVisualUpdateAt = GlobalTime + visualInterval
		else
			lift.NextVisualUpdateAt = GlobalTime
		end

		if realLiftModel then
			-- // BULLWHEEL ANIMATION //
			if not lift.BullwheelsCached then
				lift.BullwheelsCached = true
				lift.Bullwheels = {}
				local function CacheBW(stationName)
					local station = realLiftModel:FindFirstChild(stationName)
					if station then
						local bw = station:FindFirstChild("Bullwheel", true)
						if bw and (bw:IsA("BasePart") or bw:IsA("Model")) then
							local pivot = bw:IsA("Model") and bw:GetPivot() or bw.CFrame
							local size = bw:IsA("Model") and bw:GetExtentsSize() or bw.Size

							local dirMult = -1 
							local p1, p2
							local a1 = station:FindFirstChild("A1", true)
							local a2 = station:FindFirstChild("A2", true)
							if a1 and a2 then
								p1 = a1:IsA("BasePart") and a1.Position or a1.WorldPosition
								p2 = a2:IsA("BasePart") and a2.Position or a2.WorldPosition
							else
								local f1 = station:FindFirstChild("F1", true)
								local f2 = station:FindFirstChild("F2", true)
								if f1 and f2 then
									p1 = f1:IsA("BasePart") and f1.Position or f1.WorldPosition
									p2 = f2:IsA("BasePart") and f2.Position or f2.WorldPosition
								end
							end

							if p1 and p2 then
								local c = pivot.Position
								local v1 = p1 - c
								local v2 = p2 - c
								local crossY = (v1.Z * v2.X) - (v1.X * v2.Z)
								if crossY > 0 then dirMult = -1 else dirMult = 1 end
							end

							local safeRadius = math.max((math.max(size.X, size.Z)/2), 0.001)
							table.insert(lift.Bullwheels, {Obj = bw, Base = pivot, Radius = safeRadius, DirMult = dirMult})
						end
					end
				end
				CacheBW("StartStation")
				CacheBW("EndStation")
			end

			local allowBullwheelAnim = not heavyDynamicsMode or shouldForceUpdateForRider
			if not allowBullwheelAnim then
				allowBullwheelAnim = liftDistSq <= (GetLiftHideDistanceSq() * 0.25)
			end
			if lift.Bullwheels and allowBullwheelAnim then
				local dist = lift.RunningTime * (lift.ConfigData.Speed or 10)
				for _, bw in ipairs(lift.Bullwheels) do
					if bw.Obj.Parent then
						local rot = CFrame.Angles(0, (dist / bw.Radius) * bw.DirMult, 0)
						if bw.Obj:IsA("Model") then bw.Obj:PivotTo(bw.Base * rot)
						else bw.Obj.CFrame = bw.Base * rot end
					end
				end
			end
		end

		local configRot = CFrame.Angles(
			math.rad(lift.ConfigData.ChairRotationX or 0),
			math.rad(lift.ConfigData.ChairRotationY or 0),
			math.rad(lift.ConfigData.ChairRotationZ or 0)
		)
		local gripHeight    = lift.GripHeight or lift.ConfigData.GripHeight or 0
		local doorOpenWidth = lift.ConfigData.DoorOpenWidth or 1.5
		local isSurfaceTow  = lift.ConfigData.SurfaceTow == true
		local isCarpet      = lift.ConfigData.Type == "Carpet"
		local liftHideSq = GetLiftHideDistanceSq()
		local towFullRaycastSq = GetTowFullRaycastSq()
		local towFarRaycastInterval = GetTowFarRaycastInterval()
		local localRidingLift = LocalPlayer:GetAttribute("RidingLift")
		local localRidingChair = LocalPlayer:GetAttribute("RidingChair")
		local shouldForceUpdateForRider = tostring(localRidingLift or "") == tostring(lift.UniqueKey)
		if liftDistSq > (liftHideSq * 1.1) and not shouldForceUpdateForRider then
			if not lift.AllChairsHidden then
				for _, chair in ipairs(lift.Chairs) do
					if chair.Model and chair.Model.Parent then
						chair.Model.Parent = nil
					end
					if chair.LODModel and chair.LODModel.Parent then
						chair.LODModel.Parent = nil
					end
				end
				lift.AllChairsHidden = true
			end
			continue
		else
			lift.AllChairsHidden = false
		end
		if lift.ExpectedChairCount and liftDistSq <= (liftHideSq * 0.6) then
			local createdChairCount = #(lift.Chairs or {})
			local minHealthyCount = math.max(1, math.floor(lift.ExpectedChairCount * 0.5))
			if createdChairCount < minHealthyCount and (GlobalTime - (lift.SetupCompletedAt or 0)) > 1.25 and (GlobalTime - (lift.LastSelfHealAt or 0)) > 2.5 then
				lift.LastSelfHealAt = GlobalTime
				QueueLiftVisualRebuild(uniqueKey, dataValue, string.format("underfilled chair build %d/%d", createdChairCount, lift.ExpectedChairCount))
			end
		end

		local occupiedChairMap = occupiedChairsByLift[tostring(lift.UniqueKey)] or {}
		local localCharacter = LocalPlayer.Character
		local localRoot = localCharacter and localCharacter:FindFirstChild("HumanoidRootPart")
		local ridingLiftAttr = LocalPlayer:GetAttribute("RidingLift")
		local localPlayerRidingAnyLift = (type(ridingLiftAttr) == "string" and ridingLiftAttr ~= "") or type(ridingLiftAttr) == "number"
		local modeStateValue = ""
		local playerGui = LocalPlayer:FindFirstChild("PlayerGui")
		if playerGui then
			local modeState = playerGui:FindFirstChild("ModeState")
			if modeState and modeState:IsA("StringValue") then
				modeStateValue = tostring(modeState.Value or "")
			end
		end
		local isEditingMode = modeStateValue ~= ""
		local allowSeatTouchChecks = localRoot and not localPlayerRidingAnyLift and not isEditingMode and liftDistSq <= (liftHideSq * 0.3)
		if heavyDynamicsMode and not shouldForceUpdateForRider and liftDistSq > (NEAR_CHAIR_PRIORITY_DISTANCE_SQ * 4) then
			allowSeatTouchChecks = false
		end

		local chairUpdateStride = 1
		if not shouldForceUpdateForRider then
			chairUpdateStride = GetChairUpdateStride(liftDistSq, liftHideSq, #(lift.Chairs or {}), isSurfaceTow, loadUpdateScale)
		end
		local chairSliceCursor = tonumber(lift.ChairSliceCursor) or 0
		if chairUpdateStride > 1 then
			chairSliceCursor = (chairSliceCursor % chairUpdateStride) + 1
		else
			chairSliceCursor = 1
		end
		lift.ChairSliceCursor = chairSliceCursor
		local towGroundRaycastBudget = GetTowGroundRaycastBudget(loadUpdateScale)

		for chairIndex, chair in ipairs(lift.Chairs) do
			local chairOccupied = occupiedChairMap[tostring(chair.ID)] == true
			local isLocalRiderChair = shouldForceUpdateForRider and tostring(localRidingChair or "") == tostring(chair.ID)
			local phys = chair.Phys
			local cachedPos = phys and phys.LastWorldPos
			local cachedDistSq = math.huge
			if cachedPos then
				local cachedDelta = camPos - cachedPos
				cachedDistSq = cachedDelta:Dot(cachedDelta)
			end
			local cachedSegIndex = chair.CachedSegmentIndex or 1
			local cachedSeg = lift.Segments[cachedSegIndex]
			local prevSeg = lift.Segments[cachedSegIndex - 1] or lift.Segments[#lift.Segments]
			local nextSeg = lift.Segments[cachedSegIndex + 1] or lift.Segments[1]
			local isStationPriority = cachedSeg and cachedSeg.IsStation == true
			local isPolePriority = cachedSeg and cachedSeg.IsPole == true
			local isStationNeighborPriority = (prevSeg and prevSeg.IsStation == true) or (nextSeg and nextSeg.IsStation == true)
			local isPoleNeighborPriority = (prevSeg and prevSeg.IsPole == true) or (nextSeg and nextSeg.IsPole == true)
			local isNearCameraPriority = cachedDistSq <= NEAR_CHAIR_PRIORITY_DISTANCE_SQ
			local shouldBypassThrottles = chairOccupied
				or isLocalRiderChair
				or isStationPriority
				or isPolePriority
				or isStationNeighborPriority
				or isPoleNeighborPriority
				or isNearCameraPriority

			if chairUpdateStride > 1 and not shouldBypassThrottles and ((chairIndex - chairSliceCursor) % chairUpdateStride ~= 0) then
				continue
			end
			if chairFrameBudget == 0 and not shouldBypassThrottles then
				continue
			end
			if chairFrameBudget > 0 and not shouldBypassThrottles then
				chairFrameBudget -= 1
			end

			local chairTime = (masterTime + chair.OffsetTime) % lift.TotalDuration

			local railPos, railTan, seg = GetPosFromTime_Optimized(lift, chairTime, chair)
			if not railPos then continue end

			local physicsProfile = lift.PhysicsProfile
			local currentSegIndex = chair.CachedSegmentIndex or cachedSegIndex or 1
			local currentSeg = seg or lift.Segments[currentSegIndex]
			local prevCurrentSeg = lift.Segments[currentSegIndex - 1] or lift.Segments[#lift.Segments]
			local nextCurrentSeg = lift.Segments[currentSegIndex + 1] or lift.Segments[1]
			local isTerminalPoleSegment = (currentSeg and currentSeg.IsPole == true)
				and ((prevCurrentSeg and prevCurrentSeg.IsStation == true) or (nextCurrentSeg and nextCurrentSeg.IsStation == true))
			if isTerminalPoleSegment then
				local previousPoseTan = phys.LastPoseRailTan or phys.LastTangent or railTan
				local poseBlend = (physicsProfile and physicsProfile.TerminalPolePoseBlend) or 0.28
				local poseAlpha = math.clamp(dt * 18 * poseBlend, 0.05, 0.3)
				local blendedTan = previousPoseTan:Lerp(railTan, poseAlpha)
				if blendedTan.Magnitude > 0.001 then
					railTan = blendedTan.Unit
				end
				phys.LastPoseRailTan = railTan
			else
				phys.LastPoseRailTan = nil
			end
			local forceAccurateCableSnap = lift.ConfigData and lift.ConfigData.HasBubbleBar == true
			local allowCableSnap = chairOccupied
				or isLocalRiderChair
				or isSurfaceTow
				or isNearCameraPriority
				or isStationPriority
				or isPolePriority
				or isStationNeighborPriority
				or isPoleNeighborPriority
				or (seg and (seg.IsStation or seg.IsPole))
			if not allowCableSnap and cachedDistSq ~= math.huge then
				local snapRatio = (physicsProfile and physicsProfile.CableSnapDistanceRatio) or 0.78
				allowCableSnap = cachedDistSq <= (liftHideSq * snapRatio)
			end
			if forceAccurateCableSnap then
				allowCableSnap = true
			end
			if isTerminalPoleSegment and physicsProfile and physicsProfile.DisableTerminalPoleCableSnap == true and not forceAccurateCableSnap then
				allowCableSnap = false
			end
			if realLiftModel and not isCarpet and allowCableSnap then
				local snappedPos, snappedIndex = SnapPointToVisualCable(lift, realLiftModel, railPos, chair.CachedCableSegIndex)
				if snappedPos then
					local railDir = (railTan.Magnitude > 0.001) and railTan.Unit or Vector3.zAxis
					local delta = snappedPos - railPos
					local along = railDir * delta:Dot(railDir)
					local perp = delta - along
					local maxPerpSnap = (physicsProfile and physicsProfile.CableSnapPerpMax) or MAX_CABLE_SNAP_PERP_OFFSET
					if seg and seg.IsStation then
						maxPerpSnap = math.min(maxPerpSnap, (physicsProfile and physicsProfile.CableSnapPerpMaxStation) or maxPerpSnap)
					end
					if perp.Magnitude <= maxPerpSnap then
						railPos = railPos + perp
						chair.CachedCableSegIndex = snappedIndex
					end
				end
			end

			local distVec = camPos - railPos
			local distToCamSq = distVec:Dot(distVec)
			local isNearCameraNow = distToCamSq <= NEAR_CHAIR_PRIORITY_DISTANCE_SQ

			if chair.SeatTriggers and #chair.SeatTriggers > 0 then
				local shouldRecalcSeatTouch = shouldForceUpdateForRider
				if not shouldRecalcSeatTouch then
					local nextSeatTouchEvalAt = chair.NextSeatTouchEvalAt or 0
					if GlobalTime >= nextSeatTouchEvalAt then
						shouldRecalcSeatTouch = true
						chair.NextSeatTouchEvalAt = GlobalTime + seatTouchRecheckInterval
					end
				end
				if shouldRecalcSeatTouch then
					local shouldEnableSeatTouch = false
					if allowSeatTouchChecks and localRoot and ((seg and seg.IsStation) or isStationNeighborPriority or isCarpet) then
						local rootDelta = localRoot.Position - railPos
						local flatDelta = Vector3.new(rootDelta.X, 0, rootDelta.Z)
						local withinVerticalBand = math.abs(rootDelta.Y) <= 24
						shouldEnableSeatTouch = withinVerticalBand and flatDelta:Dot(flatDelta) <= SEAT_TOUCH_ENABLE_DISTANCE_SQ
					end
					if chair.SeatTouchEnabled ~= shouldEnableSeatTouch then
						chair.SeatTouchEnabled = shouldEnableSeatTouch
						for _, seatTrigger in ipairs(chair.SeatTriggers) do
							if seatTrigger and seatTrigger.Parent then
								seatTrigger.CanTouch = shouldEnableSeatTouch
							end
						end
					end
				end
			end

			local hideDistSq = liftHideSq * CHAIR_HIDE_DISTANCE_HYSTERESIS_HIDE
			local showDistSq = liftHideSq * CHAIR_HIDE_DISTANCE_HYSTERESIS_SHOW
			local currentlyDistanceHidden = chair.DistanceHidden == true
			local shouldHideByDistance
			if currentlyDistanceHidden then
				shouldHideByDistance = distToCamSq > showDistSq
			else
				shouldHideByDistance = distToCamSq > hideDistSq
			end
			if chairOccupied or isLocalRiderChair then
				shouldHideByDistance = false
			end

			if shouldHideByDistance then
				chair.DistanceHidden = true
				if chair.Model.Parent then chair.Model.Parent = nil end
				if chair.LODModel and chair.LODModel.Parent then chair.LODModel.Parent = nil end
				phys.LastWorldPos = railPos
				phys.LastTangent = railTan
				phys.LastVelocity = Vector3.zero
			else
				chair.DistanceHidden = false
				if chair.LODModel and chair.LODModel.Parent then chair.LODModel.Parent = nil end
				if not chair.Model.Parent then chair.Model.Parent = lift.VisualFolder end

				if isCarpet then
					local currentVel = phys.LastWorldPos and ((railPos - phys.LastWorldPos) / math.max(dt, 0.001)) or Vector3.zero
					phys.LastWorldPos = railPos
					phys.LastTangent = railTan
					phys.LastVelocity = currentVel

					local targetRot = SafeLookAt(railTan)
					phys.VisualRot = targetRot

					local gripCF = CFrame.new(railPos) * phys.VisualRot
					chair.Model:PivotTo(gripCF * chair.PivotFromGrip)

				elseif isSurfaceTow then
					local towLook = railTan
					if towLook.Magnitude < 0.001 then
						towLook = Vector3.zAxis
					else
						towLook = towLook.Unit
					end
					local gripPos = GetGripRenderPosition(railPos, lift, chair, gripHeight)
					local gripCF = CFrame.new(gripPos) * CFrame.lookAt(Vector3.zero, towLook)

					if chair.TilterObj then
						if chair.TilterObj:IsA("Model") then
							chair.TilterObj:PivotTo(gripCF * configRot * chair.TilterFromGrip)
						else
							chair.TilterObj.CFrame = gripCF * configRot * chair.TilterFromGrip
						end
					end

					-- Keep the tow clamp strictly on the computed rope path (no attachment drift).
					local topPoint = gripPos

					local bottomTarget = nil
					local aimCF = nil

					local flatLook = Vector3.new(railTan.X, 0, railTan.Z)
					if flatLook.Magnitude < 0.001 then
						flatLook = Vector3.zAxis
					else
						flatLook = flatLook.Unit
					end

					if chairOccupied then
						local dragOffset = railTan * TOW_DRAG_LAG
						local searchPos = topPoint - dragOffset
						local rayOrigin = Vector3.new(searchPos.X, topPoint.Y + 20, searchPos.Z)
						local groundY = topPoint.Y - 30
						local shouldRaycast = true
						local groundRaycastInterval = towFarRaycastInterval
						if not isLocalRiderChair then
							if distToCamSq > (towFullRaycastSq * 1.35) then
								groundRaycastInterval = math.max(groundRaycastInterval, 0.55)
							elseif distToCamSq > towFullRaycastSq then
								groundRaycastInterval = math.max(groundRaycastInterval, 0.35)
							end
						end
						if distToCamSq > towFullRaycastSq then
							local nowClock = os.clock()
							local nextGroundRaycastAt = chair.Phys.NextGroundRaycastAt or 0
							if nowClock < nextGroundRaycastAt then
								shouldRaycast = false
							else
								chair.Phys.NextGroundRaycastAt = nowClock + groundRaycastInterval
							end
						end

						if shouldRaycast and towGroundRaycastBudget <= 0 then
							shouldRaycast = false
						end

						if shouldRaycast then
							towGroundRaycastBudget -= 1
							local rayResult = Workspace:Raycast(rayOrigin, Vector3.new(0, -500, 0), TowGroundRaycastParams)
							if rayResult then
								groundY = rayResult.Position.Y
							elseif chair.Phys.GroundHit then
								groundY = chair.Phys.GroundHit.Y - TOW_RAYCAST_HEIGHT
							end
						elseif chair.Phys.GroundHit then
							groundY = chair.Phys.GroundHit.Y - TOW_RAYCAST_HEIGHT
						end

						bottomTarget = Vector3.new(searchPos.X, groundY + TOW_RAYCAST_HEIGHT, searchPos.Z)
						chair.Phys.GroundHit = bottomTarget 

						local stickVec = topPoint - bottomTarget
						local yAxis
						if stickVec.Magnitude < 0.001 then
							yAxis = Vector3.yAxis
						else
							yAxis = stickVec.Unit
						end
						local forward = railTan - (yAxis * railTan:Dot(yAxis))
						if forward.Magnitude < 0.001 then
							forward = Vector3.new(0, 0, -1) - (yAxis * Vector3.new(0, 0, -1):Dot(yAxis))
							if forward.Magnitude < 0.001 then
								forward = Vector3.xAxis
							end
						end
						forward = forward.Unit
						local xAxis = forward:Cross(yAxis)
						if xAxis.Magnitude < 0.001 then
							xAxis = Vector3.xAxis
						else
							xAxis = xAxis.Unit
						end
						aimCF = CFrame.fromMatrix(bottomTarget, xAxis, yAxis)

					else
						chair.Phys.GroundHit = nil 
						local flatTan = Vector3.new(railTan.X, 0, railTan.Z)
						if flatTan.Magnitude < 0.001 then
							flatTan = Vector3.zAxis
						else
							flatTan = flatTan.Unit
						end
						aimCF = CFrame.lookAt(topPoint, topPoint - flatTan)

						bottomTarget = (aimCF * CFrame.new(0, -TOW_RETRACT_DIST, 0)).Position
						if chair.HasRaycast then
							bottomTarget = (aimCF * chair.RaycastOffsetFromBody).Position
						end
					end

					local finalBodyCF = nil
					if chairOccupied and chair.HasRaycast then
						local bodyRot = aimCF.Rotation * chair.C2OffsetFromBody.Rotation:Inverse()
						finalBodyCF = CFrame.new(bottomTarget) * bodyRot * CFrame.new(-chair.RaycastOffsetFromBody.Position)
					else
						local bodyRot = aimCF.Rotation * chair.C2OffsetFromBody.Rotation:Inverse()
						finalBodyCF = CFrame.new(topPoint) * bodyRot * CFrame.new(-chair.C2OffsetFromBody.Position)
					end

					if chair.BodyObj then
						if chair.BodyObj:IsA("Model") then
							chair.BodyObj:PivotTo(finalBodyCF)
						else
							chair.BodyObj.CFrame = finalBodyCF
						end
					end

					if chair.TowRope then
						local p1 = topPoint
						local p2 = bottomTarget 
						if chair.AttC2 then p1 = chair.AttC2.WorldPosition end
						if chairOccupied and chair.HasRaycast then
							if chair.AttC2 then
								p2 = chair.AttC2.WorldPosition 
							else
								p2 = (finalBodyCF * chair.C2OffsetFromBody).Position
							end
						else
							if chair.HasRaycast then 
								p2 = (finalBodyCF * chair.RaycastOffsetFromBody).Position
							end
						end

						local ropeStart = topPoint
						local ropeEnd = nil

						if chair.AttC2 then
							ropeEnd = chair.AttC2.WorldPosition
						else
							ropeEnd = (finalBodyCF * chair.C2OffsetFromBody).Position
						end

						UpdateTowRope(chair.TowRope, ropeStart, ropeEnd)
					end

					phys.LastWorldPos = railPos
					phys.LastTangent = railTan
					phys.LastVelocity = Vector3.zero

				else
					local shouldUseSimplePose = not chairOccupied
						and not isLocalRiderChair
						and not isNearCameraNow
						and not (seg and (seg.IsStation or seg.IsPole))
						and not (lift.ConfigData and lift.ConfigData.HasBubbleBar == true)
						and distToCamSq > (liftHideSq * FAR_CHAIR_SIMPLIFY_RATIO)
					if shouldUseSimplePose then
						local nextSimplePoseAt = chair.NextSimplePoseAt or 0
						if GlobalTime < nextSimplePoseAt then
							continue
						end

						local simpleUpdateInterval = heavyDynamicsMode and (1 / 30) or (1 / 55)
						if distToCamSq > (liftHideSq * 0.72) then
							simpleUpdateInterval = heavyDynamicsMode and (1 / 24) or (1 / 42)
						end
						chair.NextSimplePoseAt = GlobalTime + simpleUpdateInterval

						local gripPos = GetGripRenderPosition(railPos, lift, chair, gripHeight)
						local simpleLook = (railTan.Magnitude > 0.001) and railTan.Unit or Vector3.zAxis
						local swingPhase = (GlobalTime * (0.9 + (chair.WeightMult * 0.35))) + (chair.OffsetTime * 0.18) + (chair.ID * 0.11)
						local swayPitch = math.sin(swingPhase) * 0.04 * chair.WeightMult
						local swayRoll = math.cos(swingPhase * 1.17) * 0.03 * chair.WeightMult
						local simpleGripCF = CFrame.new(gripPos, gripPos + simpleLook) * CFrame.Angles(swayPitch, 0, swayRoll) * configRot
						chair.Model:PivotTo(simpleGripCF * chair.PivotFromGrip)
						if chair.TilterObj then
							local finalTilterCF = simpleGripCF * chair.TilterFromGrip
							if chair.TilterObj:IsA("Model") then
								chair.TilterObj:PivotTo(finalTilterCF)
							else
								chair.TilterObj.CFrame = finalTilterCF
							end
						end
						phys.LastWorldPos = railPos
						phys.LastTangent = railTan
						phys.LastVelocity = Vector3.zero
						continue
					end

					local L = PENDULUM_LENGTH * chair.LengthMult
					local W = chair.WeightMult

					if phys.LastWorldPos == nil then
						phys.LastWorldPos = railPos
						phys.FilteredAccel = Vector3.zero
						phys.SmoothedBodyDir = (railTan.Magnitude > 0.001) and railTan.Unit or Vector3.zAxis
						phys.VisualRot = SafeLookAt(railTan)
					end

					local currentVel = (railPos - phys.LastWorldPos) / math.max(dt, 0.001)
					local rawAccel = Vector3.zero

					if phys.LastVelocity then
						rawAccel = (currentVel - phys.LastVelocity) / math.max(dt, 0.001)
					end

					if eStopTriggered and phys.LastVelocity then
						local forwardSpeed = phys.LastVelocity:Dot(railTan)
						if forwardSpeed > 0.5 then
							local swingImpulse = forwardSpeed / L
							phys.PitchVel = phys.PitchVel + (swingImpulse * 1.5)
							phys.RollVel = phys.RollVel + ((math.random() * 0.5) - 0.25) * swingImpulse
						end
					end

					phys.FilteredAccel = phys.FilteredAccel:Lerp(rawAccel, ACCEL_FILTER)
					local accel = ClampVec3(phys.FilteredAccel, MAX_ACCEL)

					local tangentDelta = (railTan - phys.LastTangent) / math.max(dt, 0.001)
					local turnSharpness = tangentDelta.Magnitude
					local turnDirection = phys.LastTangent:Cross(tangentDelta).Y 

					local forward = Vector3.new(railTan.X, 0, railTan.Z)
					if forward.Magnitude < 0.001 then forward = Vector3.zAxis else forward = forward.Unit end
					local right = Vector3.new(0, 1, 0):Cross(forward)
					if right.Magnitude < 0.001 then right = Vector3.xAxis else right = right.Unit end

					local terminalPoleForceScale = 1
					local terminalPoleDampingScale = 1
					if isTerminalPoleSegment then
						terminalPoleForceScale = (physicsProfile and physicsProfile.TerminalPoleForceScale) or 1
						terminalPoleDampingScale = (physicsProfile and physicsProfile.TerminalPoleDampingScale) or 1
					end
					local forwardInertia = -Clamp(accel:Dot(forward), -MAX_ACCEL, MAX_ACCEL) * terminalPoleForceScale
					local lateralInertia = -Clamp(accel:Dot(right), -MAX_ACCEL, MAX_ACCEL) * terminalPoleForceScale
					local verticalAccel  = Clamp(accel.Y, -MAX_ACCEL, MAX_ACCEL)

					local speed = currentVel.Magnitude
					local centripetalForce = speed * turnSharpness * CENTRIPETAL_GAIN * terminalPoleForceScale
					local centripetalSway = (turnDirection > 0 and -1 or 1) * centripetalForce * -1 

					local pitchDamp = PITCH_DAMPING
					local rollDamp  = ROLL_DAMPING

					if seg and seg.IsStation then
						pitchDamp = pitchDamp + STATION_DAMPING
						rollDamp  = rollDamp  + STATION_DAMPING
						centripetalSway = 0 
					elseif isTerminalPoleSegment then
						pitchDamp = pitchDamp * terminalPoleDampingScale
						rollDamp = rollDamp * terminalPoleDampingScale
					end

					local windPitchForce = 0
					local windRollForce  = 0
					local shouldRunFullSecondaryPhysics = chairOccupied or shouldForceUpdateForRider
					if not shouldRunFullSecondaryPhysics then
						shouldRunFullSecondaryPhysics = (not heavyDynamicsMode) and distToCamSq <= (liftHideSq * 0.15)
					end
					if WIND_ENABLED and shouldRunFullSecondaryPhysics and not (seg and seg.IsStation) then
						local wx = (railPos.X / WIND_GUST_SCALE) + (GlobalTime * WIND_TIME_SCALE)
						local wz = (railPos.Z / WIND_GUST_SCALE) + phys.WindSeed
						local wt = GlobalTime * WIND_TIME_SCALE * 1.3 + phys.WindSeed
						local wWind = GetLiveWindStrength()
						windPitchForce = math.noise(wx, wz, wt) * wWind * W
						windRollForce  = math.noise(wz + 100, wx + 50, wt + 200) * wWind * W
					end

					local onPole = seg and seg.IsPole or false
					if shouldRunFullSecondaryPhysics and onPole and not phys.WasOnPole then
						local poleImpulseScale = (physicsProfile and physicsProfile.PoleImpulseScale) or 1
						local poleKickScale = (physicsProfile and physicsProfile.PoleKickScale) or 1
						if isTerminalPoleSegment then
							poleImpulseScale = poleImpulseScale * ((physicsProfile and physicsProfile.TerminalPoleImpulseScale) or 0.6)
							poleKickScale = poleKickScale * ((physicsProfile and physicsProfile.TerminalPoleKickScale) or 0.7)
							phys.PitchVel = phys.PitchVel * 0.8
							phys.RollVel = phys.RollVel * 0.8
						end
						phys.VerticalImpulse = POLE_IMPULSE * W * poleImpulseScale
						phys.PitchVel = phys.PitchVel + (math.random() * 0.5 - 0.25) * POLE_KICK * poleKickScale
						phys.RollVel = phys.RollVel + (math.random() * 0.5 - 0.25) * POLE_KICK * poleKickScale
					end
					phys.WasOnPole = onPole

					phys.VerticalImpulse = phys.VerticalImpulse * (1 - (dt * 5))
					local poleBumpY = 0
					if phys.VerticalImpulse > 0.1 then
						poleBumpY = phys.VerticalImpulse * dt
					else
						phys.VerticalImpulse = 0
					end

					local pitchAccel = -(GRAVITY / L) * math.sin(phys.PitchAngle)
					- pitchDamp * phys.PitchVel
						+ forwardInertia * PITCH_ACCEL_GAIN * W
						+ verticalAccel * ELEVATION_GAIN * W
						+ windPitchForce
					phys.PitchVel = phys.PitchVel + pitchAccel * dt
					phys.PitchAngle = phys.PitchAngle + phys.PitchVel * dt
					phys.PitchAngle = Clamp(phys.PitchAngle, -MAX_SWAY_ANGLE, MAX_SWAY_ANGLE)

					local rollAccel = -(GRAVITY / L) * math.sin(phys.RollAngle)
					- rollDamp * phys.RollVel
						+ lateralInertia * ROLL_ACCEL_GAIN * W
						+ centripetalSway * W
						+ windRollForce
					phys.RollVel = phys.RollVel + rollAccel * dt
					phys.RollAngle = phys.RollAngle + phys.RollVel * dt
					phys.RollAngle = Clamp(phys.RollAngle, -MAX_SWAY_ANGLE, MAX_SWAY_ANGLE)

					if isTerminalPoleSegment then
						local terminalSwayDamping = (physicsProfile and physicsProfile.TerminalPoleSwayDamping) or 0
						if terminalSwayDamping > 0 then
							local dampAlpha = math.clamp(1 - (dt * terminalSwayDamping), 0.2, 1)
							phys.PitchVel = phys.PitchVel * dampAlpha
							phys.RollVel = phys.RollVel * dampAlpha
						end
					end

					local lookVector = railTan
					local targetRot = SafeLookAt(lookVector)
					local visualRotLerp = ROT_LERP_SPEED
					if seg and seg.IsStation then
						visualRotLerp = visualRotLerp * ((physicsProfile and physicsProfile.StationRotLerpScale) or 0.92)
					end
					if phys.LastTangent and phys.LastTangent:Dot(railTan) < -0.2 then
						visualRotLerp = visualRotLerp * ((physicsProfile and physicsProfile.TerminalDirLerpScale) or 0.6)
					end
					if isTerminalPoleSegment then
						local terminalLerpScale = (physicsProfile and physicsProfile.TerminalDirLerpScale) or 0.6
						visualRotLerp = visualRotLerp * math.max(0.2, terminalLerpScale * 0.85)
					end
					phys.VisualRot = phys.VisualRot:Lerp(targetRot, math.min(dt * visualRotLerp, 1))

					local gripPos = GetGripRenderPosition(railPos, lift, chair, gripHeight)
					local gripCF = CFrame.new(gripPos) * phys.VisualRot * configRot

					local targetBodyDir = Vector3.new(railTan.X, 0, railTan.Z)
					if targetBodyDir.Magnitude < 0.001 then
						targetBodyDir = phys.SmoothedBodyDir or Vector3.zAxis
					else
						targetBodyDir = targetBodyDir.Unit
					end

					if phys.SmoothedBodyDir == nil then
						phys.SmoothedBodyDir = targetBodyDir
					else
						local terminalFlipBlendScale = (physicsProfile and physicsProfile.TerminalPoleFlipBlendScale) or 1
						local dotDir = phys.SmoothedBodyDir:Dot(targetBodyDir)
						if isTerminalPoleSegment and dotDir < 0 then
							local preBlendAlpha = math.clamp(dt * BODY_DIR_LERP * 0.14 * terminalFlipBlendScale, 0, 0.22)
							targetBodyDir = LerpDirection(phys.SmoothedBodyDir, targetBodyDir, preBlendAlpha)
							dotDir = phys.SmoothedBodyDir:Dot(targetBodyDir)
						end
						if dotDir < -0.35 then
							-- Prevent looped spins when a chair direction flips around terminal transitions,
							-- but avoid a full one-frame snap for heavy chairs.
							local allowHardFlip = not (seg and seg.IsStation)
							if allowHardFlip and isTerminalPoleSegment and physicsProfile and physicsProfile.AllowTerminalHardFlip == false then
								allowHardFlip = false
							end
							if dotDir < -0.92 and allowHardFlip then
								phys.SmoothedBodyDir = targetBodyDir
							else
								local terminalScale = (physicsProfile and physicsProfile.TerminalDirLerpScale) or 0.6
								local flipAlpha = math.clamp(dt * BODY_DIR_LERP * math.max(0.25, terminalScale) * terminalFlipBlendScale, 0, 0.65)
								phys.SmoothedBodyDir = LerpDirection(phys.SmoothedBodyDir, targetBodyDir, flipAlpha)
							end
						else
							local dirLerpAlpha = dt * BODY_DIR_LERP
							if dotDir < 0 then
								dirLerpAlpha = dirLerpAlpha * 0.25
							end
							if seg and (seg.IsStation or seg.IsPole) then
								local stationBoost = (physicsProfile and physicsProfile.StationDirBoost) or 1.35
								if isTerminalPoleSegment then
									local terminalPoleBoostScale = (physicsProfile and physicsProfile.TerminalPoleStationDirBoost) or 0.85
									stationBoost = stationBoost * terminalPoleBoostScale * terminalFlipBlendScale
								end
								dirLerpAlpha = math.max(dirLerpAlpha, dt * BODY_DIR_LERP * stationBoost)
							end
							phys.SmoothedBodyDir = LerpDirection(phys.SmoothedBodyDir, targetBodyDir, dirLerpAlpha)
						end
					end
					local bodyRot = SafeLookAt(phys.SmoothedBodyDir)
						* CFrame.Angles(phys.PitchAngle, 0, phys.RollAngle)
					local hangingGrip = CFrame.new(gripCF.Position) * bodyRot * configRot
					chair.Model:PivotTo(hangingGrip * chair.PivotFromGrip)

					if chair.TilterObj then
						local finalTilterCF = gripCF * chair.TilterFromGrip
						if chair.TilterObj:IsA("Model") then
							chair.TilterObj:PivotTo(finalTilterCF)
						else
							chair.TilterObj.CFrame = finalTilterCF
						end
					end

					local animateCabinParts = shouldRunFullSecondaryPhysics or distToCamSq <= (liftHideSq * 0.09)
					if animateCabinParts and chair.BubbleBar then
						local targetState
						if lift.ConfigData.BarOpenInStation == false then
							targetState = forceCloseDoors and 0 or 1
						else
							targetState = (seg and seg.IsStation and not forceCloseDoors) and 1 or 0
						end
						local lerpSpeed = tonumber(lift.ConfigData.BubbleBarLerpSpeed) or 3
						if chair.BubbleBar.State == nil then
							chair.BubbleBar.State = targetState
						else
							chair.BubbleBar.State = chair.BubbleBar.State + ((targetState - chair.BubbleBar.State) * math.min(dt * lerpSpeed, 1))
						end
						chair.BubbleBar.TargetState = targetState
						local closeAmount = 1 - chair.BubbleBar.State

						local barCloseAmount = (lift.ConfigData.EnableBarClosing == false) and 0 or closeAmount
						local bubbleCloseAmount = (lift.ConfigData.EnableBubbleClosing == false) and 0 or closeAmount

						if chair.BubbleBar.Bar and chair.BubbleBar.Bar.Obj.Parent then
							local finalCF = chair.Model:GetPivot() * chair.BubbleBar.Bar.RelCF * GetAnimatedComponentTransform(lift.ConfigData, "Bar", barCloseAmount, chair.BubbleBar.Bar.HingeOffset)
							if chair.BubbleBar.Bar.Obj:IsA("Model") then
								chair.BubbleBar.Bar.Obj:PivotTo(finalCF)
							else
								chair.BubbleBar.Bar.Obj.CFrame = finalCF
							end
						end

						if chair.BubbleBar.Bubble and chair.BubbleBar.Bubble.Obj.Parent then
							local finalCF = chair.Model:GetPivot() * chair.BubbleBar.Bubble.RelCF * GetAnimatedComponentTransform(lift.ConfigData, "Bubble", bubbleCloseAmount, chair.BubbleBar.Bubble.HingeOffset)
							if chair.BubbleBar.Bubble.Obj:IsA("Model") then
								chair.BubbleBar.Bubble.Obj:PivotTo(finalCF)
							else
								chair.BubbleBar.Bubble.Obj.CFrame = finalCF
							end
						end
					end

					if animateCabinParts and chair.Doors then
						local targetState = chair.Doors.TargetState or 0

						if seg and seg.DoorState ~= nil then
							targetState = seg.DoorState
						else
							targetState = (seg and seg.IsStation and not forceCloseDoors) and 1 or 0
						end

						if forceCloseDoors then targetState = 0 end

						chair.Doors.TargetState = targetState
						chair.Doors.State = chair.Doors.State + ((targetState - chair.Doors.State) * math.min(dt * 3, 1))

						if chair.Doors.L and chair.Doors.L.Obj.Parent then
							local finalCF = chair.Model:GetPivot()
								* GetDoorTranslation(lift.ConfigData, true, chair.Doors.State)
								* chair.Doors.L.RelCF
							if chair.Doors.L.Obj:IsA("Model") then
								chair.Doors.L.Obj:PivotTo(finalCF)
							else
								chair.Doors.L.Obj.CFrame = finalCF
							end
						end
						if chair.Doors.R and chair.Doors.R.Obj.Parent then
							local finalCF = chair.Model:GetPivot()
								* GetDoorTranslation(lift.ConfigData, false, chair.Doors.State)
								* chair.Doors.R.RelCF
							if chair.Doors.R.Obj:IsA("Model") then
								chair.Doors.R.Obj:PivotTo(finalCF)
							else
								chair.Doors.R.Obj.CFrame = finalCF
							end
						end
					end

					phys.LastWorldPos = railPos
					phys.LastVelocity = currentVel
					phys.LastTangent  = railTan
				end 
			end
		end
	end

	local riders = {}
	for guestModel in pairs(GuestRiders) do
		if guestModel and guestModel.Parent then
			table.insert(riders, guestModel)
		else
			UntrackGuestModel(guestModel)
		end
	end

	if LocalPlayer.Character and LocalPlayer:GetAttribute("RidingLift") then
		table.insert(riders, LocalPlayer.Character)
	end

	local claimedSeatKeys = {}
	for _, rider in ipairs(riders) do
		local playerObj = Players:GetPlayerFromCharacter(rider)
		local source = playerObj or rider

		if not playerObj then
			local rootForThrottle = rider:FindFirstChild("HumanoidRootPart")
			local distSqToCam = math.huge
			if rootForThrottle then
				local deltaToCam = rootForThrottle.Position - camPos
				distSqToCam = deltaToCam:Dot(deltaToCam)
			end
			-- Keep guest rider pose updates full-rate for near/medium ranges to avoid visible
			-- seat jitter and "lagging behind" chairs. Only throttle when very far away.
			local throttleDistance = NEAR_CHAIR_PRIORITY_DISTANCE * 3
			local throttleDistSq = throttleDistance * throttleDistance
			if distSqToCam > throttleDistSq then
				local nowClock = os.clock()
				local nextPoseAt = GuestRiderNextPoseAt[rider] or 0
				if nowClock < nextPoseAt then
					continue
				end
				local riderInterval = REMOTE_RIDER_UPDATE_INTERVAL_BASE
				if loadUpdateScale >= 3 then
					riderInterval = REMOTE_RIDER_UPDATE_INTERVAL_STRESS
				elseif heavyDynamicsMode then
					riderInterval = REMOTE_RIDER_UPDATE_INTERVAL_HEAVY
				end
				GuestRiderNextPoseAt[rider] = nowClock + riderInterval
			end
		end

		local liftID = source:GetAttribute("RidingLift")
		local chairID = source:GetAttribute("RidingChair")
		local seatName = source:GetAttribute("RidingSeat")
		if not liftID or not chairID or not seatName then
			continue
		end

		local lift = ActiveLifts[liftID]
		local chairData = lift and lift.Chairs[chairID]
		if not lift or not chairData then
			continue
		end

		local realLiftModel = UUIDCache[liftID]
		local startStationPos, endStationPos
		if realLiftModel then
			local startStation = realLiftModel:FindFirstChild("StartStation")
			local endStation = realLiftModel:FindFirstChild("EndStation")
			if startStation then
				startStationPos = GetProxyPivot(startStation).Position
			end
			if endStation then
				endStationPos = GetProxyPivot(endStation).Position
			end
		end

		local isSurfaceTow = (lift.ConfigData.SurfaceTow == true)
		local isCarpet = (lift.ConfigData.Type == "Carpet")
		local seatOffset = chairData.SeatOffsets and chairData.SeatOffsets[seatName]
		if not isSurfaceTow and not isCarpet and not seatOffset then
			continue
		end

		local seatKey = tostring(liftID) .. ":" .. tostring(chairID) .. ":" .. tostring(seatName)
		if claimedSeatKeys[seatKey] then
			continue
		end
		claimedSeatKeys[seatKey] = true

		if isCarpet then
			local finalSeg = lift.Segments[#lift.Segments]
			local endPoint = finalSeg and finalSeg.P1
			if endPoint and chairData.Phys.LastWorldPos then
				local distToEnd = (chairData.Phys.LastWorldPos - endPoint).Magnitude
				if distToEnd < 2.5 then
					local root = rider:FindFirstChild("HumanoidRootPart")
					if root and chairData.Phys.LastTangent then
						root.AssemblyLinearVelocity = chairData.Phys.LastTangent * 15
					end

					if source == LocalPlayer then
						source:SetAttribute("RidingLift", nil)
						source:SetAttribute("RidingChair", nil)
						source:SetAttribute("RidingSeat", nil)
						local LiftEvent = ReplicatedStorage:FindFirstChild("Events") and ReplicatedStorage.Events:FindFirstChild("LiftEvent")
						if LiftEvent then LiftEvent:FireServer("Exit") end
					end
					continue
				end
			end
		end

		if source == LocalPlayer and not isSurfaceTow and endStationPos and chairData.Phys.LastWorldPos then
			local distToEnd = (chairData.Phys.LastWorldPos - endStationPos).Magnitude
			local distToStart = startStationPos and (chairData.Phys.LastWorldPos - startStationPos).Magnitude or math.huge
			local headingBackDown = false
			if chairData.Phys.LastTangent and startStationPos then
				local boardDir = endStationPos - startStationPos
				local flatBoardDir = Vector3.new(boardDir.X, 0, boardDir.Z)
				local flatTangent = Vector3.new(chairData.Phys.LastTangent.X, 0, chairData.Phys.LastTangent.Z)
				if flatBoardDir.Magnitude > 0.001 and flatTangent.Magnitude > 0.001 then
					headingBackDown = flatTangent.Unit:Dot(flatBoardDir.Unit) < -0.15
				end
			end

			if distToEnd <= 18 or (headingBackDown and distToEnd <= 24 and distToEnd <= distToStart) then
				source:SetAttribute("RidingLift", nil)
				source:SetAttribute("RidingChair", nil)
				source:SetAttribute("RidingSeat", nil)
				local LiftEvent = ReplicatedStorage:FindFirstChild("Events") and ReplicatedStorage.Events:FindFirstChild("LiftEvent")
				if LiftEvent then LiftEvent:FireServer("Exit") end
				continue
			end
		end

		local targetCF = nil
		if isSurfaceTow and chairData.Phys.GroundHit then
			local seatWorldPos = chairData.Phys.GroundHit + Vector3.new(0, 1.0, 0)
			local lookDir = chairData.Phys.LastTangent or Vector3.new(1, 0, 0)
			local flatLook = Vector3.new(lookDir.X, 0, lookDir.Z)
			if flatLook.Magnitude < 0.001 then
				flatLook = Vector3.zAxis
			else
				flatLook = flatLook.Unit
			end
			targetCF = CFrame.lookAt(seatWorldPos, seatWorldPos + flatLook)
		else
			local bodyPivot = GetProxyPivot(chairData.BodyObj)
			if isCarpet then
				local beltPos = chairData.Phys.LastWorldPos or bodyPivot.Position
				local lookDir = chairData.Phys.LastTangent or bodyPivot.LookVector
				local flatLook = Vector3.new(lookDir.X, 0, lookDir.Z)
				if flatLook.Magnitude < 0.001 then
					flatLook = Vector3.zAxis
				else
					flatLook = flatLook.Unit
				end
				local standPos = beltPos + Vector3.new(0, 2.7, 0)
				targetCF = CFrame.lookAt(standPos, standPos + flatLook)
			else
				local offsetRaw = lift.ConfigData.SeatHeightOffset
				local seatLiftHeight = (offsetRaw ~= nil and offsetRaw) or (playerObj and 1.6 or 1.15)
				local riderHeightOffsetAdd = tonumber(playerObj and lift.ConfigData.PlayerSeatHeightOffsetAdd or lift.ConfigData.GuestSeatHeightOffsetAdd) or 0
				seatLiftHeight += riderHeightOffsetAdd
				local riderYawOffsetDeg = tonumber(playerObj and lift.ConfigData.PlayerSeatYawOffsetDeg or lift.ConfigData.GuestSeatYawOffsetDeg) or 0
				local riderYawOffset = CFrame.Angles(0, math.rad(riderYawOffsetDeg), 0)
				local normalizeSeatFacing = (playerObj and lift.ConfigData.NormalizePlayerSeatFacing == true)
					or lift.ConfigData.NormalizeGuestSeatFacing == true
				if normalizeSeatFacing then
					local seatWorldPos = (bodyPivot * CFrame.new(seatOffset.Position)).Position
					targetCF = CFrame.new(seatWorldPos) * bodyPivot.Rotation * riderYawOffset * CFrame.new(0, seatLiftHeight, 0)
				else
					targetCF = bodyPivot * seatOffset * riderYawOffset * CFrame.new(0, seatLiftHeight, 0)
				end
			end
		end

		local root = rider:FindFirstChild("HumanoidRootPart")
		if root then
			if isCarpet then
				root.CFrame = targetCF
			elseif not playerObj then
				-- Keep remote guest riders locked to chair pose to avoid visual jitter/lag.
				root.CFrame = targetCF
			else
				local alpha = Clamp(dt * RIDER_LERP_SPEED, 0, 1)
				root.CFrame = root.CFrame:Lerp(targetCF, alpha)
			end
			root.AssemblyLinearVelocity = Vector3.zero
			root.AssemblyAngularVelocity = Vector3.zero
		end
	end
end)

local LiftCache = ReplicatedStorage:WaitForChild("LiftCache")

local function OnDataAdded(child)
	if child:IsA("StringValue") then
		task.wait(0.1)
		SetupLiftFromData(child.Name, child.Value, child)
		child.Changed:Connect(function()
			SetupLiftFromData(child.Name, child.Value, child)
		end)
	end
end

local function OnDataRemoved(child)
	LiftSetupTokens[child.Name] = (LiftSetupTokens[child.Name] or 0) + 1
	if ActiveLifts[child.Name] then
		if ActiveLifts[child.Name].VisualFolder then
			ActiveLifts[child.Name].VisualFolder:Destroy()
		end
		ActiveLifts[child.Name] = nil
	end
end

LiftCache.ChildAdded:Connect(OnDataAdded)
LiftCache.ChildRemoved:Connect(OnDataRemoved)
for _, c in ipairs(LiftCache:GetChildren()) do OnDataAdded(c) end