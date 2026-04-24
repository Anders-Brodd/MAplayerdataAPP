local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local HELPER_FOLDER = Workspace:FindFirstChild("GateRuntimeHelpers") or Instance.new("Folder")
HELPER_FOLDER.Name = "GateRuntimeHelpers"
HELPER_FOLDER.Archivable = false
HELPER_FOLDER.Parent = Workspace

local PLACED_OBJECTS = Workspace:FindFirstChild("PlacedObjects") or Instance.new("Folder")
PLACED_OBJECTS.Name = "PlacedObjects"
PLACED_OBJECTS.Parent = Workspace

local OPEN_ANGLE_RADIANS = math.rad(82)
local OPEN_TWEEN_INFO = TweenInfo.new(0.38, Enum.EasingStyle.Sine, Enum.EasingDirection.Out)
local CLOSE_TWEEN_INFO = TweenInfo.new(0.34, Enum.EasingStyle.Sine, Enum.EasingDirection.In)
local HOLD_OPEN_SECONDS = 0.9
local LANE_COOLDOWN_SECONDS = 0.7
local ACTOR_COOLDOWN_SECONDS = 1.25
local SCAN_INTERVAL_SECONDS = 0.14
local GATE_BEEP_SOUND_ID = "rbxassetid://1468236750"

local GATE_DEFINITIONS = {
	["axess gate"] = {
		Lanes = {
			{ Name = "Left", QueueAttachment = "LeftQueue", FlapsModel = "LeftFlaps" },
			{ Name = "Right", QueueAttachment = "RightQueue", FlapsModel = "RightFlaps" },
		},
	},
	["axess quad gate"] = {
		Lanes = {
			{ Name = "Left", QueueAttachment = "LeftQueue", FlapsModel = "LeftFlaps" },
			{ Name = "MiddleLeft", QueueAttachment = "MiddleLeftQueue", FlapsModel = "MiddleLeftFlaps" },
			{ Name = "MiddleRight", QueueAttachment = "MiddleRightQueue", FlapsModel = "MiddleRightFlaps" },
			{ Name = "Right", QueueAttachment = "RightQueue", FlapsModel = "RightFlaps" },
		},
	},
}

local GateStates = setmetatable({}, { __mode = "k" })
local RegisteredModels = setmetatable({}, { __mode = "k" })

local SHARED_OVERLAP_PARAMS = OverlapParams.new()
SHARED_OVERLAP_PARAMS.FilterType = Enum.RaycastFilterType.Exclude
SHARED_OVERLAP_PARAMS.MaxParts = 32

local function normalizeName(name)
	return string.lower(tostring(name or ""))
end

local function getGateDefinition(modelName)
	return GATE_DEFINITIONS[normalizeName(modelName)]
end

local function flattenDirection(direction, fallback)
	local flat = Vector3.new(direction.X, 0, direction.Z)
	if flat.Magnitude < 0.001 then
		flat = Vector3.new(fallback.X, 0, fallback.Z)
	end
	if flat.Magnitude < 0.001 then
		return Vector3.new(1, 0, 0)
	end
	return flat.Unit
end

local function getHumanoidModelFromPart(part)
	local model = part and part:FindFirstAncestorOfClass("Model")
	while model do
		local humanoid = model:FindFirstChildOfClass("Humanoid")
		if humanoid then
			return model, humanoid
		end
		local parent = model.Parent
		model = parent and parent:FindFirstAncestorOfClass("Model") or nil
	end
	return nil, nil
end

local function getRootPart(model)
	if not model then return nil end
	return model:FindFirstChild("HumanoidRootPart") or model.PrimaryPart or model:FindFirstChildWhichIsA("BasePart")
end

local function getHalfExtentOnAxis(part, axis)
	local cf = part.CFrame
	return (math.abs(cf.RightVector:Dot(axis)) * part.Size.X * 0.5)
		+ (math.abs(cf.UpVector:Dot(axis)) * part.Size.Y * 0.5)
		+ (math.abs(cf.LookVector:Dot(axis)) * part.Size.Z * 0.5)
end

local function rotateCFrameAroundPoint(cf, pivotPoint, radians)
	return CFrame.new(pivotPoint) * CFrame.Angles(0, radians, 0) * CFrame.new(-pivotPoint) * cf
end

local function collectFlapParts(flapsModel)
	local flapParts = {}
	for _, descendant in ipairs(flapsModel:GetDescendants()) do
		if descendant:IsA("BasePart") and string.find(string.lower(descendant.Name), "flap", 1, true) then
			table.insert(flapParts, descendant)
		end
	end
	table.sort(flapParts, function(a, b)
		return a.Name < b.Name
	end)
	return flapParts
end

local function stopTweens(lane)
	if lane.ActiveTweens then
		for _, tween in ipairs(lane.ActiveTweens) do
			pcall(function() tween:Cancel() end)
		end
	end
	lane.ActiveTweens = {}
end

local function tweenLaneTo(lane, targetKey, tweenInfo)
	stopTweens(lane)
	for _, flapState in ipairs(lane.Flaps) do
		local tween = TweenService:Create(flapState.Part, tweenInfo, {
			CFrame = flapState[targetKey],
		})
		table.insert(lane.ActiveTweens, tween)
		tween:Play()
	end
end

local function createHelperPart(model, laneName, center, forward, width)
	local helper = Instance.new("Part")
	helper.Name = string.format("%s_%s_Scan", model.Name, laneName)
	helper.Anchored = true
	helper.CanCollide = false
	helper.CanTouch = false
	helper.CanQuery = false
	helper.Transparency = 1
	helper.Size = Vector3.new(math.clamp(width, 3.5, 6.5), 6, 4.5)
	helper.CFrame = CFrame.lookAt(center, center + forward)
	helper.Locked = true
	helper.Massless = true
	helper.Archivable = false
	helper.Parent = HELPER_FOLDER

	local sound = Instance.new("Sound")
	sound.Name = "GateBeep"
	sound.SoundId = GATE_BEEP_SOUND_ID
	sound.Volume = 0.28
	sound.RollOffMode = Enum.RollOffMode.Inverse
	sound.RollOffMinDistance = 6
	sound.RollOffMaxDistance = 45
	sound.Parent = helper

	return helper, sound
end

local function buildLaneState(model, laneDef)
	local queueAttachment = model:FindFirstChild(laneDef.QueueAttachment, true)
	local flapsModel = model:FindFirstChild(laneDef.FlapsModel, true)
	if not (queueAttachment and queueAttachment:IsA("Attachment") and flapsModel and flapsModel:IsA("Model")) then
		return nil
	end

	local flapParts = collectFlapParts(flapsModel)
	if #flapParts == 0 then
		return nil
	end

	local laneCenter = Vector3.zero
	for _, part in ipairs(flapParts) do
		laneCenter += part.Position
		part.CanCollide = false
	end
	laneCenter /= #flapParts

	local forward = flattenDirection(laneCenter - queueAttachment.WorldPosition, model:GetPivot().LookVector)
	local right = Vector3.new(-forward.Z, 0, forward.X)
	local flapStates = {}
	local laneHalfWidth = 1.75

	for _, part in ipairs(flapParts) do
		local sideDot = (part.Position - laneCenter):Dot(right)
		local sideSign = sideDot >= 0 and 1 or -1
		local halfExtent = getHalfExtentOnAxis(part, right)
		laneHalfWidth = math.max(laneHalfWidth, math.abs(sideDot) + halfExtent)

		-- Hinge point: the edge of the flap closest to the lane center (where it attaches to the gate body)
		-- This is the INNER edge, so we go TOWARD the center from the part position
		local hingePoint = part.Position - (right * sideSign * halfExtent)
		-- Keep hinge at original Y so flap only swings horizontally
		hingePoint = Vector3.new(hingePoint.X, part.Position.Y, hingePoint.Z)

		-- Determine open direction: flap should swing OUTWARD (away from center)
		local openAngle = OPEN_ANGLE_RADIANS * sideSign

		-- Use the hinge as a true fixed pivot: compute final CFrame by rotating around the hinge
		-- The hinge is at the inner edge of the flap and must NOT move
		local relCF = CFrame.new(hingePoint):Inverse() * part.CFrame
		local openCF_candidate = CFrame.new(hingePoint) * CFrame.Angles(0, openAngle, 0) * relCF

		-- Verify the flap actually moves away from center; if not, flip the angle
		local closedDist = math.abs((part.Position - laneCenter):Dot(right))
		local openDist = math.abs((openCF_candidate.Position - laneCenter):Dot(right))
		local openCF
		if openDist >= closedDist then
			openCF = openCF_candidate
		else
			openCF = CFrame.new(hingePoint) * CFrame.Angles(0, -openAngle, 0) * relCF
		end

		table.insert(flapStates, {
			Part = part,
			ClosedCF = part.CFrame,
			OpenCF = openCF,
		})
	end

	local scanCenter = queueAttachment.WorldPosition + (forward * 1.6) + Vector3.new(0, 2.4, 0)
	local helperPart, sound = createHelperPart(model, laneDef.Name, scanCenter, forward, laneHalfWidth * 2 + 0.8)

	return {
		Name = laneDef.Name,
		GateModel = model,
		QueueAttachment = queueAttachment,
		Flaps = flapStates,
		Forward = forward,
		Right = right,
		LaneCenter = laneCenter,
		HelperPart = helperPart,
		Sound = sound,
		Cooldowns = setmetatable({}, { __mode = "k" }),
		BusyUntil = 0,
		ActiveTweens = {},
	}
end

local function cleanupGateState(model)
	local gateState = GateStates[model]
	if not gateState then
		RegisteredModels[model] = nil
		return
	end

	for _, lane in ipairs(gateState.Lanes) do
		stopTweens(lane)
		if lane.HelperPart then
			lane.HelperPart:Destroy()
		end
	end

	GateStates[model] = nil
	RegisteredModels[model] = nil
end

local function closeLane(lane)
	tweenLaneTo(lane, "ClosedCF", CLOSE_TWEEN_INFO)
	lane.BusyUntil = tick() + LANE_COOLDOWN_SECONDS
end

local function triggerLane(lane, actorModel, now)
	now = now or tick()
	lane.Cooldowns[actorModel] = now + ACTOR_COOLDOWN_SECONDS
	lane.BusyUntil = now + HOLD_OPEN_SECONDS + LANE_COOLDOWN_SECONDS

	if lane.Sound then
		lane.Sound:Stop()
		lane.Sound:Play()
	end

	tweenLaneTo(lane, "OpenCF", OPEN_TWEEN_INFO)
	task.delay(HOLD_OPEN_SECONDS, function()
		if lane.GateModel and lane.GateModel.Parent then
			closeLane(lane)
		end
	end)
end

local function findBestActorForLane(lane, now)
	if not (lane.HelperPart and lane.HelperPart.Parent and lane.GateModel and lane.GateModel.Parent) then
		return nil
	end

	SHARED_OVERLAP_PARAMS.FilterDescendantsInstances = { HELPER_FOLDER, lane.GateModel }

	local bestModel = nil
	local bestDistance = math.huge
	local seen = {}

	for _, part in ipairs(Workspace:GetPartBoundsInBox(lane.HelperPart.CFrame, lane.HelperPart.Size, SHARED_OVERLAP_PARAMS)) do
		local actorModel, humanoid = getHumanoidModelFromPart(part)
		if actorModel and humanoid and not seen[actorModel] and humanoid.Health > 0 then
			seen[actorModel] = true
			local root = getRootPart(actorModel)
			local cooldownUntil = lane.Cooldowns[actorModel]
			if root and (not cooldownUntil or cooldownUntil <= now) then
				local offset = root.Position - lane.QueueAttachment.WorldPosition
				local flatDistance = Vector3.new(offset.X, 0, offset.Z).Magnitude
				if flatDistance <= 8 then
					if flatDistance < bestDistance then
						bestDistance = flatDistance
						bestModel = actorModel
					end
				end
			end
		end
	end

	return bestModel
end

local function registerGateModel(model)
	if not (model and model:IsA("Model")) then return end
	if RegisteredModels[model] then return end

	local definition = getGateDefinition(model.Name)
	if not definition then return end
	RegisteredModels[model] = true

	local lanes = {}
	for _, laneDef in ipairs(definition.Lanes) do
		local laneState = buildLaneState(model, laneDef)
		if laneState then
			table.insert(lanes, laneState)
		end
	end

	if #lanes == 0 then
		RegisteredModels[model] = nil
		return
	end

	GateStates[model] = {
		Model = model,
		Lanes = lanes,
	}
end

for _, child in ipairs(Workspace:GetChildren()) do
	if child:IsA("Model") then
		registerGateModel(child)
	end
end

for _, child in ipairs(PLACED_OBJECTS:GetChildren()) do
	if child:IsA("Model") then
		registerGateModel(child)
	end
end

Workspace.ChildAdded:Connect(function(child)
	if child:IsA("Model") then
		task.defer(registerGateModel, child)
	end
end)

PLACED_OBJECTS.ChildAdded:Connect(function(child)
	if child:IsA("Model") then
		task.defer(registerGateModel, child)
	end
end)

local scanAccumulator = 0
RunService.Heartbeat:Connect(function(dt)
	scanAccumulator += dt
	if scanAccumulator < SCAN_INTERVAL_SECONDS then
		return
	end
	scanAccumulator = 0
	local now = tick()

	for model, gateState in pairs(GateStates) do
		if not model.Parent then
			cleanupGateState(model)
		else
			for _, lane in ipairs(gateState.Lanes) do
				if now >= (lane.BusyUntil or 0) then
					local actorModel = findBestActorForLane(lane, now)
					if actorModel then
						triggerLane(lane, actorModel, now)
					end
				end
			end
		end
	end
end)
