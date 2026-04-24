local ProceduralSkiAnimator = {}
ProceduralSkiAnimator.__index = ProceduralSkiAnimator

local TWO_PI = math.pi * 2
local Workspace = game:GetService("Workspace")
local POLE_HAND_MOUNT_OFFSET = Vector3.zero

local function safeUnit(vector, fallback)
	if typeof(vector) == "Vector3" and vector.Magnitude > 1e-4 then
		return vector.Unit
	end
	return fallback or Vector3.new(0, 0, -1)
end

local function inverseLerp(a, b, value)
	if b == a then
		return 0
	end
	return math.clamp((value - a) / (b - a), 0, 1)
end

local function setMotorTransform(motor, target, alpha)
	if not motor then
		return
	end
	motor.Transform = motor.Transform:Lerp(target, math.clamp(alpha, 0, 1))
end

local function lookAtStable(origin, dir, primaryUp, fallbackUp)
	local look = safeUnit(dir, Vector3.new(0, -1, 0))
	local up = safeUnit(primaryUp, Vector3.yAxis)
	if math.abs(look:Dot(up)) > 0.9 then
		up = safeUnit(fallbackUp, Vector3.xAxis)
		if math.abs(look:Dot(up)) > 0.9 then
			up = Vector3.zAxis
		end
	end
	return CFrame.lookAt(origin, origin + look, up)
end

local function enforceLateralOrder(center, leftPos, rightPos, axis, minHalfSeparation)
	local minHalf = math.max(minHalfSeparation or 0.15, 0.05)
	local leftLat = (leftPos - center):Dot(axis)
	local rightLat = (rightPos - center):Dot(axis)

	if leftLat > -minHalf then
		leftPos = leftPos + (axis * ((-minHalf) - leftLat))
		leftLat = -minHalf
	end
	if rightLat < minHalf then
		rightPos = rightPos + (axis * (minHalf - rightLat))
		rightLat = minHalf
	end

	if leftLat >= rightLat then
		local mid = (leftLat + rightLat) * 0.5
		leftPos = leftPos + (axis * ((-minHalf) - mid))
		rightPos = rightPos + (axis * (minHalf - mid))
	end

	return leftPos, rightPos
end

local function findDescendant(root, name)
	if not root then
		return nil
	end
	return root:FindFirstChild(name, true)
end

local function findPoleInstance(character, side)
	if not character then
		return nil
	end

	local name = side .. "Pole"
	local direct = character:FindFirstChild(name)
	if direct then
		return direct
	end

	local legacy = character:FindFirstChild("SkiPoles")
	if legacy then
		local fromLegacy = legacy:FindFirstChild(name, true)
		if fromLegacy then
			return fromLegacy
		end
	end

	return nil
end

local function findPalmAttachment(part)
	if not part then
		return nil
	end
	for _, name in ipairs({"Hand", "GripAttachment", "LeftGripAttachment", "RightGripAttachment"}) do
		local att = part:FindFirstChild(name)
		if att and att:IsA("Attachment") then
			return att
		end
	end
	for _, child in ipairs(part:GetChildren()) do
		if child:IsA("Attachment") then
			return child
		end
	end
	return nil
end

local function sanitizeBaseFootLocals(leftLocal, rightLocal, rootPart, humanoid)
	if typeof(leftLocal) ~= "Vector3" or typeof(rightLocal) ~= "Vector3" then
		local fallbackHalf = 0.72
		local fallbackY = -2.58
		local fallbackZ = -0.28
		return Vector3.new(-fallbackHalf, fallbackY, fallbackZ), Vector3.new(fallbackHalf, fallbackY, fallbackZ)
	end

	local rootWidth = (rootPart and rootPart:IsA("BasePart")) and rootPart.Size.X or 2
	local minHalfSpread = math.max(0.60, rootWidth * 0.30)
	local maxHalfSpread = math.max(minHalfSpread + 0.28, rootWidth * 0.92)
	local halfSpread = math.clamp(rootWidth * 0.34, minHalfSpread, maxHalfSpread)

	local hipHeight = (humanoid and tonumber(humanoid.HipHeight)) or 2
	local targetY = -math.clamp(hipHeight + 0.85, 2.35, 3.45)
	local measuredY = (leftLocal.Y + rightLocal.Y) * 0.5
	local avgY = math.clamp((targetY * 0.75) + (measuredY * 0.25), -4.2, -1.3)
	local avgZ = -0.28

	return Vector3.new(-halfSpread, avgY, avgZ), Vector3.new(halfSpread, avgY, avgZ)
end

function ProceduralSkiAnimator.new(character, humanoid)
	if not character or not humanoid then
		return nil
	end

	local self = setmetatable({}, ProceduralSkiAnimator)
	self.character = character
	self.humanoid = humanoid
	self.rootPart = character:FindFirstChild("HumanoidRootPart")
	self.motors = {
		RootJoint = findDescendant(character, "RootJoint"),
		Waist = findDescendant(character, "Waist"),
		Neck = findDescendant(character, "Neck"),
		LeftShoulder = findDescendant(character, "LeftShoulder"),
		RightShoulder = findDescendant(character, "RightShoulder"),
		LeftElbow = findDescendant(character, "LeftElbow"),
		RightElbow = findDescendant(character, "RightElbow"),
		LeftHip = findDescendant(character, "LeftHip"),
		RightHip = findDescendant(character, "RightHip"),
		LeftKnee = findDescendant(character, "LeftKnee"),
		RightKnee = findDescendant(character, "RightKnee"),
	}

	self.gaitPhase = 0
	self.pushPhase = 0
	self.pushCycle = 0
	self.lastTurnSign = 1
	self.ikTargets = {}
	self.ikControls = {}
	self.pushActiveSide = -1
	self.lastPushAlpha = 0
	self.prevLeftHandPos = nil
	self.prevRightHandPos = nil
	self.prevLeftPoleDir = nil
	self.prevRightPoleDir = nil
	self.prevLeftPlantPoint = nil
	self.prevRightPlantPoint = nil
	self.leftPushPlantAnchor = nil
	self.rightPushPlantAnchor = nil
	self.lastPushCyclePhase = nil
	self.wasPushState = false
	self.poleRayParams = RaycastParams.new()
	self.poleRayParams.FilterType = Enum.RaycastFilterType.Exclude
	self.poleRayParams.IgnoreWater = true
	self.poleRayParams.FilterDescendantsInstances = {character}
	self.poleLengths = {
		Left = 2.35,
		Right = 2.35,
	}
	self.nextPoleLengthRefresh = 0
	self.nextGripRefresh = 0
	self.leftFootPart = findDescendant(character, "LeftFoot") or findDescendant(character, "LeftLowerLeg")
	self.rightFootPart = findDescendant(character, "RightFoot") or findDescendant(character, "RightLowerLeg")
	self.leftHandPart = findDescendant(character, "LeftHand") or findDescendant(character, "LeftLowerArm") or findDescendant(character, "Left Arm")
	self.rightHandPart = findDescendant(character, "RightHand") or findDescendant(character, "RightLowerArm") or findDescendant(character, "Right Arm")
	self.leftPoleGripLocal = Vector3.zero
	self.rightPoleGripLocal = Vector3.zero
	local leftPalmAttachment = findPalmAttachment(self.leftHandPart)
	local rightPalmAttachment = findPalmAttachment(self.rightHandPart)
	if leftPalmAttachment then
		self.leftPoleGripLocal = leftPalmAttachment.Position + POLE_HAND_MOUNT_OFFSET
	end
	if rightPalmAttachment then
		self.rightPoleGripLocal = rightPalmAttachment.Position + POLE_HAND_MOUNT_OFFSET
	end
	self.baseLeftFootLocal = nil
	self.baseRightFootLocal = nil

	if self.rootPart and self.leftFootPart and self.rightFootPart then
		local rawLeft = self.rootPart.CFrame:PointToObjectSpace(self.leftFootPart.Position)
		local rawRight = self.rootPart.CFrame:PointToObjectSpace(self.rightFootPart.Position)
		self.baseLeftFootLocal, self.baseRightFootLocal = sanitizeBaseFootLocals(rawLeft, rawRight, self.rootPart, self.humanoid)
	end

	self:_setupIK()
	return self
end

function ProceduralSkiAnimator:_createTarget(name)
	if not self.rootPart then
		return nil
	end
	local attachment = Instance.new("Attachment")
	attachment.Name = "SkiIKTarget_" .. name
	attachment.Parent = self.rootPart
	self.ikTargets[name] = attachment
	return attachment
end

function ProceduralSkiAnimator:_createIKControl(name, chainRootName, endEffectorName, targetAttachment)
	local chainRoot = findDescendant(self.character, chainRootName)
	local endEffector = findDescendant(self.character, endEffectorName)
	if not chainRoot or not endEffector or not targetAttachment then
		return nil
	end

	local ik = Instance.new("IKControl")
	ik.Name = "SkiIK_" .. name
	ik.ChainRoot = chainRoot
	ik.EndEffector = endEffector
	ik.Target = targetAttachment
	ik.Weight = 0
	ik.Enabled = true

	pcall(function()
		if string.find(name, "Foot", 1, true) then
			ik.Type = Enum.IKControlType.Transform
		else
			ik.Type = Enum.IKControlType.Position
		end
	end)
	pcall(function()
		ik.Priority = 1
	end)
	ik.Parent = self.humanoid
	self.ikControls[name] = ik
	return ik
end

function ProceduralSkiAnimator:_setupIK()
	if not self.rootPart or not self.humanoid then
		return
	end

	local leftFootTarget = self:_createTarget("LeftFoot")
	local rightFootTarget = self:_createTarget("RightFoot")
	local leftHandTarget = self:_createTarget("LeftHand")
	local rightHandTarget = self:_createTarget("RightHand")

	self:_createIKControl("LeftFoot", "LeftUpperLeg", "LeftFoot", leftFootTarget)
	self:_createIKControl("RightFoot", "RightUpperLeg", "RightFoot", rightFootTarget)
	self:_createIKControl("LeftHand", "LeftUpperArm", "LeftHand", leftHandTarget)
	self:_createIKControl("RightHand", "RightUpperArm", "RightHand", rightHandTarget)
end

function ProceduralSkiAnimator:_setTargetWorldCFrame(targetName, worldCFrame)
	local attachment = self.ikTargets[targetName]
	if not attachment or not self.rootPart then
		return
	end
	attachment.CFrame = self.rootPart.CFrame:ToObjectSpace(worldCFrame)
end

function ProceduralSkiAnimator:_setIKWeight(name, targetWeight, dt)
	local ik = self.ikControls[name]
	if not ik then
		return
	end
	local current = ik.Weight
	ik.Weight = current + ((math.clamp(targetWeight, 0, 1) - current) * math.clamp((dt or (1 / 60)) * 16, 0, 1))
end

function ProceduralSkiAnimator:_buildHandTargetCFrame(poleHandPos, poleDir, primaryUp, fallbackUp, gripLocal)
	local orientation = lookAtStable(Vector3.zero, poleDir, primaryUp, fallbackUp)
	local rotationOnly = orientation - orientation.Position
	local localGrip = gripLocal or Vector3.zero
	local gripWorldOffset = rotationOnly:VectorToWorldSpace(localGrip)
	local handPartPos = poleHandPos - gripWorldOffset
	return CFrame.new(handPartPos) * rotationOnly
end

function ProceduralSkiAnimator:_refreshPoleLengths()
	if tick() < (self.nextPoleLengthRefresh or 0) then
		return
	end
	self.nextPoleLengthRefresh = tick() + 0.45

	if not self.character then
		return
	end

	for _, side in ipairs({"Left", "Right"}) do
		local poleRoot = findPoleInstance(self.character, side)
		if poleRoot then
			local handAtt = findDescendant(poleRoot, "Hand")
			local pointAtt = findDescendant(poleRoot, "Point")
			if handAtt and pointAtt and handAtt:IsA("Attachment") and pointAtt:IsA("Attachment") then
				local len = (pointAtt.WorldPosition - handAtt.WorldPosition).Magnitude
				if len > 0.45 and len < 8 then
					self.poleLengths[side] = len
				end
			end
		end
	end
end

function ProceduralSkiAnimator:_refreshGripOffsets()
	if tick() < (self.nextGripRefresh or 0) then
		return
	end
	self.nextGripRefresh = tick() + 0.35

	if not self.character then
		return
	end

	for _, side in ipairs({"Left", "Right"}) do
		local handPart = (side == "Left") and self.leftHandPart or self.rightHandPart
		local poleRoot = findPoleInstance(self.character, side)
		if handPart and poleRoot then
			local handAtt = findDescendant(poleRoot, "Hand")
			if handAtt and handAtt:IsA("Attachment") then
				local localGrip = handPart.CFrame:PointToObjectSpace(handAtt.WorldPosition)
				if side == "Left" then
					self.leftPoleGripLocal = localGrip
				else
					self.rightPoleGripLocal = localGrip
				end
			end
		end
	end
end

function ProceduralSkiAnimator:_getPoleLength(side)
	self:_refreshPoleLengths()
	self:_refreshGripOffsets()
	return self.poleLengths[side] or 2.35
end

function ProceduralSkiAnimator:_projectPointToGround(seedPoint, normal)
	if not self.poleRayParams then
		return seedPoint
	end

	self.poleRayParams.FilterDescendantsInstances = {self.character}
	local castOrigin = seedPoint + (normal * 4.5)
	local castDirection = -normal * 12
	local result = Workspace:Raycast(castOrigin, castDirection, self.poleRayParams)
	if result then
		return result.Position - (normal * 0.03)
	end

	return seedPoint - (normal * 0.18)
end

function ProceduralSkiAnimator:ResetPose()
	for _, motor in pairs(self.motors) do
		if motor then
			motor.Transform = CFrame.new()
		end
	end
	for _, ik in pairs(self.ikControls) do
		if ik then
			ik.Weight = 0
		end
	end
	self.prevLeftHandPos = nil
	self.prevRightHandPos = nil
	self.prevLeftPoleDir = nil
	self.prevRightPoleDir = nil
	self.prevLeftPlantPoint = nil
	self.prevRightPlantPoint = nil
	self.leftPushPlantAnchor = nil
	self.rightPushPlantAnchor = nil
	self.lastPushCyclePhase = nil
	self.wasPushState = false
end

function ProceduralSkiAnimator:Destroy()
	self:ResetPose()
	for _, ik in pairs(self.ikControls) do
		if ik then
			ik:Destroy()
		end
	end
	for _, attachment in pairs(self.ikTargets) do
		if attachment then
			attachment:Destroy()
		end
	end
	self.ikControls = {}
	self.ikTargets = {}
end

function ProceduralSkiAnimator:Step(dt, state)
	if not self.character or not self.character.Parent then
		return
	end

	state = state or {}
	local delta = dt or (1 / 60)
	local stateName = state.state or state.debugLabel or "Off"
	local speed = math.max(state.speed or 0, 0)
	local groundedAlpha = math.clamp(state.groundedAlpha or 0, 0, 1)
	local steer = math.clamp(state.steer or 0, -1, 1)
	local carveAlpha = math.clamp(state.carveAlpha or 0, 0, 1)
	local brakeAlpha = math.clamp(state.brakeAlpha or 0, 0, 1)
	local lowSpeedBrakeAlpha = math.clamp(state.lowSpeedBrakeAlpha or brakeAlpha, 0, 1)
	local highSpeedSlideAlpha = math.clamp(state.highSpeedSlideAlpha or 0, 0, 1)
	local pushAlpha = math.clamp(state.pushAlpha or 0, 0, 1)
	local stopAlpha = math.clamp(state.stopAlpha or 0, 0, 1)
	local wantsBootWalk = state.wantsBootWalk == true

	local isOff = (stateName == "Off") or (stateName == "RidingLift")
	if isOff then
		for name, _ in pairs(self.ikControls) do
			self:_setIKWeight(name, 0, delta)
		end
		for _, motor in pairs(self.motors) do
			setMotorTransform(motor, CFrame.new(), delta * 10)
		end
		return
	end

	if state.turnSign and state.turnSign ~= 0 then
		self.lastTurnSign = state.turnSign
	end
	local walkAlpha = wantsBootWalk and math.clamp(inverseLerp(0.2, 12, speed), 0, 1) or 0
	if stateName == "BootWalk" then
		walkAlpha = math.max(walkAlpha, 0.45)
	elseif stateName == "BootRun" then
		walkAlpha = math.max(walkAlpha, 0.75)
	end
	if speed < 1.2 then
		walkAlpha = 0
	end

	local gaitSpeed = 1.8 + (speed * 0.15)
	if stateName == "BootRun" then
		gaitSpeed = gaitSpeed + 1.35
	end
	self.gaitPhase = (self.gaitPhase + (delta * gaitSpeed * TWO_PI)) % TWO_PI
	self.pushPhase = (self.pushPhase + delta * (2.2 + (speed * 0.04))) % TWO_PI

	local walkSin = math.sin(self.gaitPhase)
	local walkCos = math.cos(self.gaitPhase)
	local pushSin = math.sin(self.pushPhase)

	local speedAlpha = inverseLerp(0, 70, speed)
	local leanForward = -0.03 + (speedAlpha * 0.002)
	local steerIntent = inverseLerp(0.14, 0.55, math.abs(steer))
	local carveLean = (state.leanAngle or (steer * carveAlpha * math.rad(28))) * groundedAlpha * steerIntent
	local brakeLean = (math.rad(16) * lowSpeedBrakeAlpha) + (math.rad(10) * stopAlpha) + (math.rad(9) * highSpeedSlideAlpha)
	local wedgeYaw = 0
	if lowSpeedBrakeAlpha > 0.18 then
		wedgeYaw = math.rad(4.5) * inverseLerp(0.18, 1, lowSpeedBrakeAlpha)
	end

	local walkSwing = 0
	local walkLiftL = 0
	local walkLiftR = 0

	local pushHeld = state.pushing == true
	local isPushState = pushHeld or (stateName == "PolePush") or (pushAlpha > 0.12)
	local isBootState = (stateName == "BootWalk") or (stateName == "BootRun")
	local isSkiTravelState = (stateName == "SkiGlide") or (stateName == "Carve") or (stateName == "BrakeStop") or (stateName == "Airborne")
	local isTravelPoleState = (not isPushState) and (isSkiTravelState or isBootState or speed > 2.2)
	local isIdlePoleState = (not isPushState) and (not isTravelPoleState)
	if not isPushState then
		self.leftPushPlantAnchor = nil
		self.rightPushPlantAnchor = nil
		self.lastPushCyclePhase = nil
	end

	local pushStrength = math.max(pushAlpha, stateName == "PolePush" and 0.9 or 0)
	local leftPlant = 0
	local rightPlant = 0
	if isPushState then
		if not self.wasPushState then
			self.pushCycle = 0
			self.leftPushPlantAnchor = nil
			self.rightPushPlantAnchor = nil
			self.lastPushCyclePhase = nil
		end
		local externalPhase = tonumber(state.pushCyclePhase)
		if externalPhase then
			local phase = math.clamp(externalPhase, 0, 0.999)
			local wrapped = (self.lastPushCyclePhase ~= nil) and (phase < self.lastPushCyclePhase)
			self.pushCycle = phase
			if wrapped then
				self.leftPushPlantAnchor = nil
				self.rightPushPlantAnchor = nil
				self.prevLeftPlantPoint = nil
				self.prevRightPlantPoint = nil
				self.prevLeftHandPos = nil
				self.prevRightHandPos = nil
			end
			self.lastPushCyclePhase = phase
		else
			local cycleRate = 1.45
			local cycleDuration = tonumber(state.pushCycleDuration)
			if cycleDuration and cycleDuration > 1e-3 then
				cycleRate = 1 / cycleDuration
			end
			local nextCycle = (self.pushCycle + (delta * cycleRate)) % 1
			local wrapped = nextCycle < self.pushCycle
			self.pushCycle = nextCycle
			if wrapped then
				self.leftPushPlantAnchor = nil
				self.rightPushPlantAnchor = nil
				self.prevLeftPlantPoint = nil
				self.prevRightPlantPoint = nil
				self.prevLeftHandPos = nil
				self.prevRightHandPos = nil
			end
			self.lastPushCyclePhase = self.pushCycle
		end
		local cycle = self.pushCycle
		local contactAlpha
		if cycle < 0.16 then
			contactAlpha = 0.7 + (0.3 * (cycle / 0.16))
		elseif cycle < 0.78 then
			contactAlpha = 1
		else
			local t = (cycle - 0.78) / 0.22
			contactAlpha = 1 - (0.85 * t)
		end
		leftPlant = math.clamp(contactAlpha, 0, 1)
		rightPlant = leftPlant
	else
		self.pushCycle = 0
		leftPlant = math.max(0, pushSin) * 0.05
		rightPlant = math.max(0, -pushSin) * 0.05
	end
	local pushCycle = self.pushCycle
	self.lastPushAlpha = pushAlpha

	local leftShoulderPitch
	local rightShoulderPitch
	local leftElbowPitch
	local rightElbowPitch
	local pushDriveAlpha = 0

	if isIdlePoleState then
		-- Idle pose: hands in front, elbows at ~90 degrees.
		leftShoulderPitch = -0.88
		rightShoulderPitch = -0.88
		leftElbowPitch = -math.rad(90)
		rightElbowPitch = -math.rad(90)
	elseif isTravelPoleState then
		-- Moving without push input: rest hands down by sides.
		leftShoulderPitch = -0.22
		rightShoulderPitch = -0.22
		leftElbowPitch = -0.28
		rightElbowPitch = -0.28
	else
		-- Push cycle arm line (brown ref): setup in front, rear drive, then arc recovery.
		local driveAlpha
		if pushCycle < 0.22 then
			driveAlpha = 0
		elseif pushCycle < 0.78 then
			driveAlpha = (pushCycle - 0.22) / 0.56
		else
			driveAlpha = 1 - ((pushCycle - 0.78) / 0.22)
		end
		driveAlpha = math.clamp(driveAlpha, 0, 1)
		pushDriveAlpha = driveAlpha
		leftShoulderPitch = -0.54 - (driveAlpha * 0.74)
		rightShoulderPitch = -0.54 - (driveAlpha * 0.74)
		leftElbowPitch = -1.16 + (driveAlpha * 0.30)
		rightElbowPitch = -1.16 + (driveAlpha * 0.30)
	end

	local shoulderRollBase = 0.12
	local shoulderRollCarve = carveLean * 0.24
	local armBrakeReach = brakeAlpha * 0.16
	local leftShoulderRollOffset = 0
	local rightShoulderRollOffset = 0
	if isIdlePoleState then
		-- Bring forearms inward so palms face each other in front idle pose.
		leftShoulderRollOffset = -0.16
		rightShoulderRollOffset = 0.16
	elseif isTravelPoleState then
		leftShoulderRollOffset = -0.04
		rightShoulderRollOffset = 0.04
	end
	if isPushState then
		-- Keep elbows flared slightly out during drive so poles do not cross behind.
		shoulderRollBase = shoulderRollBase + (0.22 * pushDriveAlpha)
	end

	local waistPitch = leanForward - brakeLean + (walkCos * walkAlpha * 0.02)
	waistPitch = math.clamp(waistPitch, -0.10, 0.015)
	local waistRoll = carveLean * 0.7
	local hipFlex = (0.006 + (speedAlpha * 0.012) + (carveAlpha * 0.015) + (lowSpeedBrakeAlpha * 0.018) + (highSpeedSlideAlpha * 0.012)) * groundedAlpha
	local hipPitchBase = -(hipFlex + (brakeAlpha * 0.009))
	local hipRoll = -waistRoll * 0.6
	local kneeFlexBase = (0.14 + (hipFlex * 1.55) + (carveAlpha * 0.2) + (lowSpeedBrakeAlpha * 0.12) + (highSpeedSlideAlpha * 0.08)) * groundedAlpha
	local leftKneePitch = kneeFlexBase + (math.max(0, carveLean) * 0.18)
	local rightKneePitch = kneeFlexBase + (math.max(0, -carveLean) * 0.18)

	setMotorTransform(self.motors.RootJoint, CFrame.Angles(waistPitch * 0.18, 0, waistRoll * 0.16), delta * 14)
	setMotorTransform(self.motors.Waist, CFrame.Angles(waistPitch, 0, waistRoll), delta * 14)
	setMotorTransform(self.motors.Neck, CFrame.Angles(-waistPitch * 0.35, 0, -waistRoll * 0.45), delta * 14)

	local leftHipPitch = math.clamp(hipPitchBase + walkSwing, -0.12, 0.03)
	local rightHipPitch = math.clamp(hipPitchBase - walkSwing, -0.12, 0.03)
	setMotorTransform(self.motors.LeftHip, CFrame.Angles(leftHipPitch, -wedgeYaw, hipRoll + (carveLean * 0.38)), delta * 14)
	setMotorTransform(self.motors.RightHip, CFrame.Angles(rightHipPitch, wedgeYaw, hipRoll - (carveLean * 0.38)), delta * 14)

	-- Keep knees coupled to hip flex so stance compression looks natural while skiing.
	setMotorTransform(self.motors.LeftKnee, CFrame.Angles(leftKneePitch, 0, 0), delta * 16)
	setMotorTransform(self.motors.RightKnee, CFrame.Angles(rightKneePitch, 0, 0), delta * 16)

	-- Arms are animation-driven only; do not procedurally rotate shoulders/elbows.
	setMotorTransform(self.motors.LeftShoulder, CFrame.new(), delta * 14)
	setMotorTransform(self.motors.RightShoulder, CFrame.new(), delta * 14)
	setMotorTransform(self.motors.LeftElbow, CFrame.new(), delta * 14)
	setMotorTransform(self.motors.RightElbow, CFrame.new(), delta * 14)

	if not self.rootPart then
		return
	end

	local normal = safeUnit(state.normal, self.rootPart.CFrame.UpVector)
	local forward = safeUnit(state.forward, Vector3.new(self.rootPart.CFrame.LookVector.X, 0, self.rootPart.CFrame.LookVector.Z))
	local right = safeUnit(forward:Cross(normal), self.rootPart.CFrame.RightVector)
	forward = safeUnit(normal:Cross(right), forward)
	if right:Dot(self.rootPart.CFrame.RightVector) < 0 then
		right = -right
		forward = safeUnit(normal:Cross(right), forward)
	end
	if highSpeedSlideAlpha > 0.05 then
		local slideSign = (state.stopSlideSign and state.stopSlideSign ~= 0) and state.stopSlideSign or self.lastTurnSign
		if slideSign == 0 then
			slideSign = 1
		end
		local sideForward = safeUnit(right * slideSign, forward)
		local slideVisualAlpha = math.clamp(highSpeedSlideAlpha * 0.45, 0, 0.45)
		forward = safeUnit(forward:Lerp(sideForward, slideVisualAlpha), sideForward)
		right = safeUnit(forward:Cross(normal), right)
		forward = safeUnit(normal:Cross(right), forward)
	end

	local position = self.rootPart.Position
	local leftLocal = self.baseLeftFootLocal or Vector3.new(-0.72, -2.58, -0.28)
	local rightLocal = self.baseRightFootLocal or Vector3.new(0.72, -2.58, -0.28)
	local skiStanceAlpha = math.clamp((1 - walkAlpha) * groundedAlpha, 0, 1)
	local stanceCompression = (0.15 + (speedAlpha * 0.18) + (carveAlpha * 0.14) + (lowSpeedBrakeAlpha * 0.16) + (highSpeedSlideAlpha * 0.10)) * skiStanceAlpha
	local footSpread = (math.abs(leftLocal.X) + math.abs(rightLocal.X)) * 0.5 + (wedgeYaw * 1.35)
	local minFootSpread = math.max(0.52, ((self.rootPart and self.rootPart.Size.X) or 2) * 0.24)
	footSpread = math.max(footSpread, minFootSpread)
	local footBack = math.clamp(math.max(0.25, -((leftLocal.Z + rightLocal.Z) * 0.5)) + (brakeAlpha * 0.08), 0.25, 1.35)
	local footHeight = ((leftLocal.Y + rightLocal.Y) * 0.5) + 0.02 + stanceCompression
	local footStep = 0

	local leftFootPos = position + (right * -footSpread) + (forward * (footStep - footBack)) + (normal * footHeight)
	local rightFootPos = position + (right * footSpread) + (forward * (-footStep - footBack)) + (normal * footHeight)
	local feetCenter = position + (forward * -footBack) + (normal * footHeight)
	leftFootPos, rightFootPos = enforceLateralOrder(feetCenter, leftFootPos, rightFootPos, right, math.max(0.18, footSpread * 0.45))

	local handOut = 0.98 + (math.abs(carveLean) * 0.28)
	if isIdlePoleState then
		handOut = 0.40
	elseif isPushState then
		handOut = 0.56 + (pushDriveAlpha * 0.20)
	elseif isTravelPoleState then
		handOut = 0.54
	end
	local leftForwardOffset
	local rightForwardOffset
	local leftUpOffset
	local rightUpOffset

	if isIdlePoleState then
		leftForwardOffset = 0.72
		rightForwardOffset = 0.72
		leftUpOffset = -0.92
		rightUpOffset = -0.92
	elseif isTravelPoleState then
		leftForwardOffset = 0.10
		rightForwardOffset = 0.10
		leftUpOffset = -1.46
		rightUpOffset = -1.46
	else
		-- 4-phase hand arc: front setup -> drop plant -> rear drive -> aerial recovery.
		if pushCycle < 0.22 then
			-- Start push from idle-like pose, just a bit higher.
			leftForwardOffset = 0.78
			rightForwardOffset = 0.78
			leftUpOffset = -0.90
			rightUpOffset = -0.90
		elseif pushCycle < 0.34 then
			local t = (pushCycle - 0.22) / 0.12
			leftForwardOffset = 0.78 + ((1.24 - 0.78) * t)
			rightForwardOffset = 0.78 + ((1.24 - 0.78) * t)
			leftUpOffset = -0.90 + ((-0.84 - (-0.90)) * t)
			rightUpOffset = -0.90 + ((-0.84 - (-0.90)) * t)
		elseif pushCycle < 0.78 then
			local t = (pushCycle - 0.34) / 0.44
			leftForwardOffset = 1.24 + ((-0.24 - 1.24) * t)
			rightForwardOffset = 1.24 + ((-0.24 - 1.24) * t)
			leftUpOffset = -0.84 + ((-0.96 - (-0.84)) * t)
			rightUpOffset = -0.84 + ((-0.96 - (-0.84)) * t)
		else
			local t = (pushCycle - 0.78) / 0.22
			leftForwardOffset = -0.24 + ((1.24 - (-0.24)) * t)
			rightForwardOffset = -0.24 + ((1.24 - (-0.24)) * t)
			leftUpOffset = -0.96 + ((-0.30 - (-0.96)) * t)
			rightUpOffset = -0.96 + ((-0.30 - (-0.96)) * t)
		end
	end

	local leftHandPos = position + (right * -handOut) + (forward * leftForwardOffset) + (normal * leftUpOffset)
	local rightHandPos = position + (right * handOut) + (forward * rightForwardOffset) + (normal * rightUpOffset)

	local leftPoleDir
	local rightPoleDir
	if isPushState then
		local cycle = pushCycle
		local setupTilt = math.rad(7)
		local driveTilt = math.rad(34)
		local function pushPoleDir(sideSign)
			local setup = safeUnit((-normal * 0.975) + (forward * 0.18) + (right * 0.12 * sideSign), -normal)
			local drive = safeUnit((-normal * math.cos(driveTilt)) + (-forward * math.sin(driveTilt)) + (right * 0.16 * sideSign), -normal)
			if cycle < 0.22 then
				return setup
			elseif cycle < 0.34 then
				return safeUnit(setup:Lerp(drive, (cycle - 0.22) / 0.12), drive)
			elseif cycle < 0.78 then
				return drive
			else
				return safeUnit(drive:Lerp(setup, (cycle - 0.78) / 0.22), setup)
			end
		end
		leftPoleDir = pushPoleDir(-1)
		rightPoleDir = pushPoleDir(1)
	elseif isIdlePoleState then
		leftPoleDir = safeUnit((-normal * 0.975) + (forward * 0.18) + (right * -0.08), -normal)
		rightPoleDir = safeUnit((-normal * 0.975) + (forward * 0.18) + (right * 0.08), -normal)
	elseif isTravelPoleState then
		leftPoleDir = safeUnit((-normal * 0.92) + (forward * 0.12) + (right * -0.10), -normal)
		rightPoleDir = safeUnit((-normal * 0.92) + (forward * 0.12) + (right * 0.10), -normal)
	else
		local planted = safeUnit((-normal * 0.95) + (forward * 0.18), -normal)
		local recovery = safeUnit((-forward * 0.82) + (-normal * 0.28), -forward)
		leftPoleDir = (leftPlant > 0.12) and planted or recovery
		rightPoleDir = (rightPlant > 0.12) and planted or recovery
	end

	local function applyPlantFromPolePoint(sideName, handPos, poleDir, plantedAlpha, sideSign, footPos)
		local alpha = math.clamp(plantedAlpha or 0, 0, 1)
		if alpha <= 0 then
			return handPos
		end

		local poleLength = self:_getPoleLength(sideName)
		local forwardBias
		local downBias
		local plantPoint
		local lockToWorldPoint = false
		if isPushState then
			local cycle = pushCycle
			-- Push stroke target for pole point:
			-- 1) staged 4 studs ahead at ~40° setup,
			-- 2) drive/plant,
			-- 3) pull back to about 3 studs behind,
			-- 4) recover back ahead and repeat.
			if cycle < 0.22 then
				forwardBias = 1.55
			elseif cycle < 0.78 then
				local t = (cycle - 0.22) / 0.56
				forwardBias = 1.55 + ((-1.2 - 1.55) * t)
			else
				local t = (cycle - 0.78) / 0.22
				forwardBias = -1.2 + ((1.55 - (-1.2)) * t)
			end
			downBias = (cycle < 0.22) and 0.05 or 0.10
			local sideBias = 0.23 + (0.08 * pushDriveAlpha)
			plantPoint = position
				+ (forward * forwardBias)
				+ (right * (sideBias * sideSign))
				- (normal * downBias)

			local lockStart = 0.22
			local lockEnd = 0.72
			if cycle >= lockStart and cycle < lockEnd then
				if groundedAlpha > 0.35 then
					plantPoint = self:_projectPointToGround(plantPoint, normal)
				end
				local anchor = (sideName == "Left") and self.leftPushPlantAnchor or self.rightPushPlantAnchor
				if not anchor then
					anchor = plantPoint
					if sideName == "Left" then
						self.leftPushPlantAnchor = anchor
					else
						self.rightPushPlantAnchor = anchor
					end
				end
				plantPoint = anchor
				lockToWorldPoint = true
			else
				if sideName == "Left" then
					self.leftPushPlantAnchor = nil
				else
					self.rightPushPlantAnchor = nil
				end
			end
		elseif isIdlePoleState then
			-- Idle poles should sit in a stable arc in front of the player, not beside the boots.
			forwardBias = 1.55
			downBias = 0.05
			local sideBias = 0.23
			plantPoint = position
				+ (forward * forwardBias)
				+ (right * (sideBias * sideSign))
				- (normal * downBias)
		else
			forwardBias = 0.24 + (0.55 * alpha)
			downBias = 0.10
			local sideBias = 0.08
			plantPoint = footPos
				+ (forward * forwardBias)
				+ (right * (sideBias * sideSign))
				- (normal * downBias)
		end

		if (not lockToWorldPoint) and groundedAlpha > 0.35 then
			plantPoint = self:_projectPointToGround(plantPoint, normal)
		end

		local previousPlant = (sideName == "Left") and self.prevLeftPlantPoint or self.prevRightPlantPoint
		local plantSmooth = lockToWorldPoint and 1 or math.clamp(delta * (isPushState and 80 or 18), 0, 1)
		if previousPlant then
			plantPoint = previousPlant:Lerp(plantPoint, plantSmooth)
		end
		if sideName == "Left" then
			self.prevLeftPlantPoint = plantPoint
		else
			self.prevRightPlantPoint = plantPoint
		end

		local plantedHandPos = plantPoint - (poleDir * poleLength)
		return handPos:Lerp(plantedHandPos, alpha)
	end

	-- Poles are accessories; do not force pole angle/ground placement here.
	-- Drive the push by arm/hand motion only.

	local handSmooth = math.clamp(delta * (isPushState and 10 or 12), 0, 1)
	if self.prevLeftHandPos then
		leftHandPos = self.prevLeftHandPos:Lerp(leftHandPos, handSmooth)
	end
	if self.prevRightHandPos then
		rightHandPos = self.prevRightHandPos:Lerp(rightHandPos, handSmooth)
	end
	local handCenter = position
		+ (forward * ((leftForwardOffset + rightForwardOffset) * 0.5))
		+ (normal * ((leftUpOffset + rightUpOffset) * 0.5))
	local handMinHalf = isPushState and 0.34 or 0.24
	leftHandPos, rightHandPos = enforceLateralOrder(handCenter, leftHandPos, rightHandPos, right, handMinHalf)
	self.prevLeftHandPos = leftHandPos
	self.prevRightHandPos = rightHandPos

	local dirSmooth = math.clamp(delta * (isPushState and 8 or 11), 0, 1)
	if self.prevLeftPoleDir then
		leftPoleDir = safeUnit(self.prevLeftPoleDir:Lerp(leftPoleDir, dirSmooth), leftPoleDir)
	end
	if self.prevRightPoleDir then
		rightPoleDir = safeUnit(self.prevRightPoleDir:Lerp(rightPoleDir, dirSmooth), rightPoleDir)
	end
	self.prevLeftPoleDir = leftPoleDir
	self.prevRightPoleDir = rightPoleDir

	local turnSign = (state.turnSign and state.turnSign ~= 0) and state.turnSign or math.sign(steer)
	local canEdge = (stateName == "Carve") and (carveAlpha > 0.38) and (steerIntent > 0.72) and (lowSpeedBrakeAlpha < 0.05) and (highSpeedSlideAlpha < 0.08)
	local edgeIntent = canEdge and math.max(steerIntent, 0.74) or 0
	local carveEdgeAlpha = math.clamp(carveAlpha * groundedAlpha * edgeIntent * (1 - (brakeAlpha * 0.75)), 0, 1)
	local baseEdgeRoll = math.rad(3) * carveEdgeAlpha * turnSign
	local leftEdgeRoll = baseEdgeRoll
	local rightEdgeRoll = baseEdgeRoll
	if turnSign ~= 0 then
		local outsideScale = 1.04
		local insideScale = 0.98
		local leftIsOutside = (-1) == -turnSign
		leftEdgeRoll = baseEdgeRoll * (leftIsOutside and outsideScale or insideScale)
		rightEdgeRoll = baseEdgeRoll * (leftIsOutside and insideScale or outsideScale)
	end

	-- Feet stay flat to slope (up = terrain normal), then roll onto edge only while carving.
	self:_setTargetWorldCFrame("LeftFoot", CFrame.lookAt(leftFootPos, leftFootPos + forward, normal) * CFrame.fromAxisAngle(forward, leftEdgeRoll))
	self:_setTargetWorldCFrame("RightFoot", CFrame.lookAt(rightFootPos, rightFootPos + forward, normal) * CFrame.fromAxisAngle(forward, rightEdgeRoll))
	local leftHandRot = (self.leftHandPart and (self.leftHandPart.CFrame - self.leftHandPart.Position)) or CFrame.identity
	local rightHandRot = (self.rightHandPart and (self.rightHandPart.CFrame - self.rightHandPart.Position)) or CFrame.identity
	local leftHandTarget = CFrame.new(leftHandPos) * leftHandRot
	local rightHandTarget = CFrame.new(rightHandPos) * rightHandRot
	self:_setTargetWorldCFrame("LeftHand", leftHandTarget)
	self:_setTargetWorldCFrame("RightHand", rightHandTarget)

	local airborne = state.airborne == true
	local footWeight = airborne and 0 or math.clamp(groundedAlpha * 1.0, 0, 1)
	local handWeight = 0

	self:_setIKWeight("LeftFoot", footWeight, delta)
	self:_setIKWeight("RightFoot", footWeight, delta)
	self:_setIKWeight("LeftHand", handWeight, delta)
	self:_setIKWeight("RightHand", handWeight, delta)
	self.wasPushState = isPushState
end

return ProceduralSkiAnimator
