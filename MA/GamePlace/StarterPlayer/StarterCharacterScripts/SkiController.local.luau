--[[
	SKI SYSTEM V3.0 — FULL PHYSICS OVERHAUL
	LocalScript in StarterPlayerScripts (or StarterCharacterScripts)
	
	=== MAJOR CHANGES FROM V2 ===
	• FIXED: Floating above ground — no more math.huge MaxForce fighting gravity
	• FIXED: Bump launches — multi-point raycasting + critically-damped suspension
	• FIXED: Spinning on bumps — "micro-air" grace period prevents air rotation on tiny hops
	• FIXED: Terrain normal jitter — weighted average of multiple raycasts + smoothing
	• NEW: Proper ski physics model (slope gravity, carving vs skidding, edge angle)
	• NEW: Two-foot raycast system (left foot + right foot) for stability
	• NEW: Smooth terrain-following orientation with interpolation
	• NEW: Proper air detection with grace period (no false air from bumps)
	• NEW: Speed-dependent suspension (stiffer at high speed to absorb bumps)
	• NEW: Avatar Joint Upgrade ragdoll with proper recovery
	• NEW: Clean state machine (Grounded → Airborne → Crashed → Recovering)
	• NEW: Edge angle / carving physics based on real ski mechanics
	• NEW: Aerodynamic drag (tuck position at speed)
	• NEW: Centripetal force in turns (realistic carving feel)
	
	=== CONTROLS ===
	Q         — Toggle skiing on/off
	A / D     — Steer / Carve
	W         — Push (pole push, only works at low speed on ground)
	S         — Brake (snowplow)
	Space     — Jump (hold to charge)
	R         — Manual recovery from crash
	
	=== HOW THE PHYSICS WORK ===
	We do NOT use LinearVelocity with MaxForce=huge. That's what caused floating.
	Instead we use VectorForce to APPLY forces (gravity, suspension, steering) and
	let Roblox physics handle the rest naturally. The character feels weight because
	gravity actually pulls them down, and suspension pushes them up only when the
	ground is close enough.
]]

-- ============================================================================
-- SERVICES
-- ============================================================================
local Players          = game:GetService("Players")
local RunService       = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage= game:GetService("ReplicatedStorage")
local TweenService     = game:GetService("TweenService")
local Workspace        = game:GetService("Workspace")

local Player = Players.LocalPlayer
local PlayerGui = Player:WaitForChild("PlayerGui")
local Camera = Workspace.CurrentCamera
local Events = ReplicatedStorage:WaitForChild("Events", 10)
local SETTINGS_ATTR_PREFIX = "Settings_"
local Shared = ReplicatedStorage:WaitForChild("Shared")
local GraphicsProfile = require(Shared:WaitForChild("GraphicsProfile"))
local SkiStateSchema = require(Shared:WaitForChild("SkiStateSchema"))
local SkiPhysicsModel = require(Shared:WaitForChild("SkiPhysicsModel"))
local ProceduralSkiAnimator = require(Shared:WaitForChild("ProceduralSkiAnimator"))
local SkiMistVFX = require(Shared:WaitForChild("SkiMistVFX"))

-- ============================================================================
-- NETWORKING
-- ============================================================================
local SkiEvent = ReplicatedStorage:WaitForChild("SkiEvent", 10)
if not SkiEvent then
	SkiEvent = Instance.new("RemoteEvent")
	SkiEvent.Name = "SkiEvent"
	SkiEvent.Parent = ReplicatedStorage
end

-- ============================================================================
-- CONFIGURATION
-- ============================================================================
local CONFIG = {
	-- ── GRAVITY & TERMINAL VELOCITY ──
	-- We use workspace.Gravity for actual gravity (default 196.2)
	-- SlopeGravityMultiplier boosts the downhill acceleration force
	SlopeGravityMultiplier = 0.75,  -- Slightly stronger accel so flats don't feel dead
	TerminalVelocity = 170,         -- Restore some top-end without runaway

	-- ── FRICTION ──
	-- Real ski friction coefficients: 0.02–0.14 depending on conditions
	-- These are intentionally LOW — skis are slippery! Speed comes from gravity.
	Friction_Glide   = 0.038,   -- Base friction when going straight
	Friction_Carve   = 0.088,   -- Friction during carved turns (edge digs in)
	Friction_Skid    = 0.22,    -- Friction when skidding sideways
	Friction_Brake   = 0.95,    -- Snowplow braking friction

	-- ── AERODYNAMIC DRAG ──
	-- Drag = 0.5 * Cd * A * rho * v^2 (simplified)
	-- Keep this very low so speed builds naturally on slopes
	DragCoefficient  = 0.0020, -- Keep speed growth controlled but less sticky

	-- ── TURNING / CARVING ──
	-- Carving turn radius: at low speed you can make tight turns,
	-- at high speed turns are wider but still very much there
	TurnSpeed_Base   = 3.9,     -- Turn rate at low/medium speed (degrees per frame-second)
	TurnSpeed_High   = 2.15,    -- Turn rate at high speed (still substantial!)
	TurnSpeed_Uturn  = 7.8,     -- Extra low-speed turn authority for clean U-turns
	HighSpeedThreshold = 80,    -- Speed where turn rate transitions to high-speed value
	UTurnAssistSpeed = 28,      -- Below this speed, steering becomes more pivot-friendly
	MinSpeedToTurn   = 2,       -- Need this much speed to start turning
	TurnInputResponse = 13.5,   -- Input smoothing for stable steering (higher = snappier)
	CarveGrip        = 0.992,   -- Higher = carving preserves more speed (was 0.90)
	CarveHeadingForce = 16.5,   -- Pulls travel direction toward ski heading
	Friction_CarveSide = 0.52,  -- Extra lateral bite while carving to prevent strafing
	HeadingBlend     = 0.72,    -- Visual heading priority over raw slip direction
	MinEdgeAngle     = 10,
	MaxEdgeAngle     = 65,      -- Maximum visual tilt angle (degrees)
	MinTurnRadius    = 10,
	MaxTurnRadius    = 220,
	MaxTurnRate      = 9.5,
	TurnBlendSpeedLow = 12,
	TurnBlendSpeedHigh = 60,
	SlopeMinAngle    = 2.5,     -- Slopes below this barely accelerate you
	SlopeFullAngle   = 22,      -- Slopes at/above this get full slope acceleration
	RollingResistance = 2.7,    -- Constant speed scrub while grounded
	BrakeDeceleration = 42,     -- Flat brake decel when holding S
	BrakeSpeedFactor  = 0.23,   -- Extra brake decel that scales with speed
	BrakeLowSpeedBoost = 1.6,
	StopModeThresholdMPH = 110, -- Below: pizza stop, above: side-slip stop
	BrakeSideTurnResponse = 7.2,
	BrakeSideSlipFrictionBoost = 2.35,
	BrakeSideSlipGlideBoost = 1.45,
	BrakeSideSlipDecelBoost = 1.65,
	StaticHoldMaxSpeed = 5.2,
	StaticHoldForce = 17,

	-- ── PROPULSION (POLE PUSH) ──
	PushForce       = 13.5,     -- Force per push
	PushMaxSpeed    = 28,       -- Can't push above this speed
	PushCooldown    = 0.5,      -- Full push cycle duration
	PushImpulsePhase = 0.30,    -- Boost fires after front plant phase
	PushImpulseScale = 0.62,    -- Small IRL-like burst per cycle
	PushFlatBoost   = 1.7,

	-- ── JUMPING ──
	JumpBase        = 22,       -- Minimum jump impulse
	JumpMax         = 92,       -- Maximum jump impulse (fully charged)
	JumpChargeTime  = 0.9,      -- Seconds to fully charge
	MaxJumpUpVelocity = 92,     -- Hard cap for upward velocity after jump impulse
	HighSpeedJumpSoftCap = 38,  -- Start reducing jump strength above this speed
	HighSpeedJumpMinScale = 0.60, -- Max-speed jump keeps this fraction of charged power
	JumpForwardScale = 0.24,    -- Portion of jump sent forward for pop without flight

	-- ── SUSPENSION (TERRAIN FOLLOWING) ──
	-- This is the critical system. We use a spring-damper model.
	-- The key insight: we DON'T override gravity. We add an upward force
	-- ONLY when close to the ground, and let gravity do its thing otherwise.
	TargetRideHeight = 3.0,     -- Desired height above ground (stud units)
	RaycastLength    = 10.0,    -- How far down to look for ground (longer for steep slopes)

	-- Spring parameters (critically damped for no bounce)
	-- F_spring = stiffness * displacement - damping * velocity_y
	SpringStiffness  = 3200,    -- Newtons per stud of displacement
	SpringDamping    = 150,     -- Damping coefficient (high = no bounce)

	-- Speed-adaptive suspension
	SpringStiffnessAtSpeed = 5500,  -- Stiffer at high speed (absorbs bumps better)
	SpeedForMaxStiffness   = 80,    -- Speed at which max stiffness kicks in

	-- Multi-ray terrain sampling
	RaySpreadForward = 2.5,    -- How far forward/back to cast extra rays
	RaySpreadSide    = 1.5,    -- How far left/right to cast extra rays

	-- Terrain normal smoothing (prevents jitter from rough terrain)
	NormalSmoothSpeed = 10.0,  -- How fast the smoothed normal tracks the real one

	-- ── AIR DETECTION ──
	-- Grace period prevents "micro-air" from bumps triggering air state
	AirGraceTime      = 0.2,   -- Seconds of no ground before "real air" (was 0.15, bumped up)
	AirGraceAfterJump = 0.04,  -- Intentional jumps become "real air" quickly for tricks
	AirDragMultiplier = 1.1,   -- Extra drag in true air so you don't rocket forever
	FlipPitchSpeed    = 8.2,   -- Air flip speed (rad/s scale before dt)
	FlipYawSpeed      = 4.8,   -- Air spin speed (rad/s scale before dt)
	GroundSnapSpeed    = 25,    -- Extra downward force to prevent hopping (was 15)
	-- If the ground is within this distance, apply a "snap" force to prevent hopping
	GroundSnapDistance = 5.5,   -- Wider snap range (was 4.5)
	CrestStickDistance = 7.0,   -- Keep contact over short crest gaps
	CrestStickTime = 0.16,      -- Ground-loss grace for crest transitions
	CrestAdhesionStrength = 0.55, -- Extra near-ground adhesion in Gs
	OutwardNormalDamping = 10.0, -- Damps lift-off speed along terrain normal
	MaxOutwardNormalSpeed = 8.0, -- Hard cap for outward normal velocity

	-- ── CRASH SYSTEM ──
	Crash = {
		MinCrashSpeed         = 60,   -- Minimum speed for crash risk
		LandingAngleTolerance = 58,   -- Max degrees from upright to land safely
		CrashRecoveryTime     = 2.4,  -- Seconds to recover
		RagdollStrength       = 500,  -- AnimationConstraint force during ragdoll
		-- Higher = stiffer ragdoll (less floppy/choppy)
		-- 100 was way too low → limbs went crazy
		-- 500 = natural flop without spastic jerking
		LandingSuccessBase    = 0.82, -- More forgiving trick landings
	},

	-- ── CAMERA & VISUALS ──
	FOV_Base        = 70,
	FOV_Max         = 100,
	FOV_SpeedScale  = 80,       -- Speed at which FOV reaches max
	CameraShake     = 0.25,     -- Shake intensity multiplier
	TiltMax         = 50,       -- Max visual body tilt in turns (degrees)

	-- ── INPUT ──
	Keybind = Enum.KeyCode.Q,

	-- ── ANIMATIONS ──
	-- Fill in your animation asset IDs (just the number)
	Animations = {
		Idle     = "",   -- Standing still on skis
		BootWalk = "",   -- Walking in ski boots / clipping around flats
		BootRun  = "",   -- Running in ski boots
		SkiGlide = "",   -- Optional override for glide (falls back to Skiing)
		Skiing   = "",   -- Moving forward
		Carving  = "",   -- Turning
		PolePush = "109421560901475",   -- Pushing with poles on flats
		BrakeStop = "",  -- Snowplow braking / stopping
		Jump     = "",   -- Takeoff
		AirTrick = "",   -- Spinning in air
		Landing  = "",   -- Landing impact
		Crashed  = "",   -- On the ground after crash
	}
}

-- ============================================================================
-- STATE MACHINE
-- ============================================================================
-- States: "idle" | "skiing" | "airborne" | "crashed" | "recovering" | "off"
local State = {
	current         = "off",

	-- Physics state
	velocity        = Vector3.zero,
	facingCFrame    = CFrame.new(),     -- Where the skier is pointing
	smoothNormal    = Vector3.yAxis,    -- Smoothed ground normal
	groundHeight    = 0,                -- Distance to ground
	groundHit       = false,            -- Is there ground below?

	-- Air tracking
	airTimer        = 0,                -- How long since last ground contact
	isReallyInAir   = false,            -- True only after grace period
	groundLostTimer = 0,                -- Short hysteresis for crest transitions
	airRotation     = CFrame.identity,  -- Rotation tracking while airborne
	rotationInAir   = 0,               -- Total rotation for trick scoring
	lastGroundCFrame= CFrame.new(),     -- CFrame when we left the ground

	-- Jump
	jumpCharge      = 0,
	isChargingJump  = false,
	justJumped      = false,
	jumpCooldown    = 0,

	-- Push
	lastPushTime    = 0,
	pushCycleElapsed = 0,
	pushCyclePrimed = false,
	pushImpulseFired = false,

	-- Input
	steer           = 0,    -- -1 to 1
	braking         = false,
	pushing         = false,
	turnRate        = 0,
	slipAmount      = 0,
	groundedAlpha   = 0,
	pushAnimTimer   = 0,
	rideHeight      = nil,
	savedAnimateEnabled = nil,
	brakeSlideSign  = 1,
	wasBraking      = false,
}

-- ============================================================================
-- REFERENCES (filled on equip)
-- ============================================================================
local function updateSkiStateAttribute()
	pcall(function()
		Player:SetAttribute("SkiState", State.current)
		Player:SetAttribute("SkiActive", State.current ~= "off")
	end)
end

updateSkiStateAttribute()

local Character, RootPart, Humanoid, Animator
local VectorForceInst, AlignOrientInst   -- Physics movers
local PhysicsAttachment                   -- Attachment for forces
local HumanoidDiedConnection

-- Avatar Joint Upgrade
local AnimationConstraints = {}
local OriginalConstraintStates = {}
local HasAvatarJointUpgrade = false
local RagdollRuntime = {
	active = false,
	motors = {},
	constraints = {},
	attachments = {},
	partCollision = {},
}

-- Effects
local ParticleEmitters = {}
local Sounds = {}
local ScreenGui, SpeedLabel, SpeedUnitsLabel, ChargeBar, ChargeBarBg
local DesktopToggleGui, DesktopToggleButton
local MobileToggleGui, MobileToggleButton, MobileTurnLeftButton, MobileTurnRightButton
local MobileTurnLeftHeld = false
local MobileTurnRightHeld = false
local mobileButtonSteer = 0
local mobileToggleRetryQueued = false
local toggleSkis
local updateMobileToggleButton

-- Animation tracks
local AnimTracks = {}
local LoadedAnimTrackSet = {}
local CurrentAnim = nil
local ProceduralAnimatorInst
local MistController
local lastForeignAnimStop = 0

-- Raycast params (reused every frame)
local RayParams = RaycastParams.new()
local lastRideableRaycastRefresh = 0

local function isRideableDecorName(name)
	if type(name) ~= "string" then
		return false
	end
	local lowered = string.lower(name)
	return lowered == "ramp" or lowered == "ski rail"
end

local function shouldTreatAsRideableDecor(inst)
	if not inst or not inst:IsA("Model") then
		return false
	end
	if isRideableDecorName(inst.Name) then
		return true
	end
	return isRideableDecorName(inst:GetAttribute("ItemName"))
		or isRideableDecorName(inst:GetAttribute("DisplayName"))
		or isRideableDecorName(inst:GetAttribute("OriginalName"))
end

local function refreshRideableRaycastFilter(force)
	local now = tick()
	if not force and (now - lastRideableRaycastRefresh) < 0.75 then
		return
	end
	lastRideableRaycastRefresh = now

	local includeList = {Workspace.Terrain}
	local placedObjects = Workspace:FindFirstChild("PlacedObjects")
	if placedObjects then
		for _, inst in ipairs(placedObjects:GetDescendants()) do
			if shouldTreatAsRideableDecor(inst) then
				table.insert(includeList, inst)
			end
		end
	end

	RayParams.FilterDescendantsInstances = includeList
	RayParams.FilterType = Enum.RaycastFilterType.Include
	RayParams.IgnoreWater = true
end

local function estimateRideHeight(character, rootPart, humanoid)
	if character and rootPart then
		local leftFoot = character:FindFirstChild("LeftFoot") or character:FindFirstChild("LeftLowerLeg") or character:FindFirstChild("Left Leg")
		local rightFoot = character:FindFirstChild("RightFoot") or character:FindFirstChild("RightLowerLeg") or character:FindFirstChild("Right Leg")
		if leftFoot and rightFoot then
			local leftLocal = rootPart.CFrame:PointToObjectSpace(leftFoot.Position)
			local rightLocal = rootPart.CFrame:PointToObjectSpace(rightFoot.Position)
			local avgFootDepth = ((-leftLocal.Y) + (-rightLocal.Y)) * 0.5
			local skiAllowance = 0.48
			return math.clamp(avgFootDepth + skiAllowance, 2.5, 6.5)
		end
	end

	if humanoid then
		return math.clamp((humanoid.HipHeight or 2) + 1.1, 2.5, 6.5)
	end

	return CONFIG.TargetRideHeight
end

local ClosePanels = Events and Events:FindFirstChild("ClosePanels")
if Events and not ClosePanels then
	ClosePanels = Instance.new("BindableEvent")
	ClosePanels.Name = "ClosePanels"
	ClosePanels.Parent = Events
end

local ModeState = PlayerGui:FindFirstChild("ModeState") or Instance.new("StringValue")
ModeState.Name = "ModeState"
ModeState.Parent = PlayerGui

local staleSkiHud = PlayerGui:FindFirstChild("SkiHUD")
if staleSkiHud then
	staleSkiHud:Destroy()
end
local staleDesktopControls = PlayerGui:FindFirstChild("SkiDesktopControls")
if staleDesktopControls then
	staleDesktopControls:Destroy()
end
local staleMobileControls = PlayerGui:FindFirstChild("SkiMobileControls")
if staleMobileControls then
	staleMobileControls:Destroy()
end

local function isMetricUnits()
	local unitSystem = Player:GetAttribute(SETTINGS_ATTR_PREFIX .. "UnitSystem")
	return type(unitSystem) == "string" and string.lower(unitSystem) == "metric"
end

local function supportsDesktopSkiControls()
	return false
end

local function supportsMobileSkiControls()
	return UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled
end

local function isMobileSkiButtonEnabled()
	local value = Player:GetAttribute(SETTINGS_ATTR_PREFIX .. "ShowMobileSkiButton")
	if type(value) == "boolean" then
		return value
	end
	return true
end

local function getDisplaySpeed(speed)
	local mph = math.floor(speed * 0.6818)
	if isMetricUnits() then
		return math.floor((mph * 1.60934) + 0.5), "KM/H"
	end
	return mph, "MPH"
end

local function refreshSpeedUnitsLabel()
	if SpeedUnitsLabel then
		SpeedUnitsLabel.Text = isMetricUnits() and "KM/H" or "MPH"
	end
end

local UIBlockerPaths = {
	{"MainHUD", "BuildFrame"},
	{"MainHUD", "SettingsFrame"},
	{"MainHUD", "CalendarFrame"},
	{"MainHUD", "ResearchFrame"},
	{"MainHUD", "EmployeesFrame"},
	{"LiftCommandUI", "MainFrame"},
	{"LiftControlUI", "MainFrame"},
	{"SandboxUI", "Main"},
	{"SnowGunUI", "Main"},
	{"SlopeBuilderUI", "MainPanel"},
}
local UIBlockerConnections = {}
local blockerCheckQueued = false

-- ============================================================================
-- UTILITY FUNCTIONS
-- ============================================================================

local function lerp(a, b, t)
	return a + (b - a) * math.clamp(t, 0, 1)
end

local function lerpVector3(a, b, t)
	t = math.clamp(t, 0, 1)
	return Vector3.new(
		a.X + (b.X - a.X) * t,
		a.Y + (b.Y - a.Y) * t,
		a.Z + (b.Z - a.Z) * t
	)
end

local function inverseLerp(a, b, v)
	if math.abs(b - a) < 0.001 then return 0 end
	return math.clamp((v - a) / (b - a), 0, 1)
end

-- Safe unit vector (returns fallback if magnitude is too small)
local function safeUnit(v, fallback)
	fallback = fallback or Vector3.zero
	if v.Magnitude < 0.001 then return fallback end
	return v.Unit
end

-- Project vector onto plane defined by normal
local function projectOnPlane(v, normal)
	return v - v:Dot(normal) * normal
end

local function resetCharacterMotorTransforms(character)
	if not character then
		return
	end
	for _, desc in ipairs(character:GetDescendants()) do
		if desc:IsA("Motor6D") then
			desc.Transform = CFrame.new()
		end
	end
end

local function getHalfExtentAlong(partCF, size, axis)
	local right = partCF.RightVector
	local up = partCF.UpVector
	local look = partCF.LookVector
	return (math.abs(axis:Dot(right)) * size.X * 0.5)
		+ (math.abs(axis:Dot(up)) * size.Y * 0.5)
		+ (math.abs(axis:Dot(look)) * size.Z * 0.5)
end

local function getMountedSkiParts(character)
	if not character then
		return nil
	end
	local skisModel = character:FindFirstChild("Skis")
	if not skisModel then
		return nil
	end

	local parts = {}
	local left = skisModel:FindFirstChild("LeftSki", true)
	local right = skisModel:FindFirstChild("RightSki", true)
	if left and left:IsA("BasePart") then
		table.insert(parts, left)
	end
	if right and right:IsA("BasePart") then
		table.insert(parts, right)
	end
	if #parts > 0 then
		return parts
	end

	for _, desc in ipairs(skisModel:GetDescendants()) do
		if desc:IsA("BasePart") and not string.find(desc.Name, "SkiTipCollider", 1, true) then
			table.insert(parts, desc)
		end
	end

	return (#parts > 0) and parts or nil
end

local function syncRideHeightWithMountedSkis(character, rootPart)
	if not character or not rootPart then
		return false
	end
	local skiParts = getMountedSkiParts(character)
	if not skiParts then
		return false
	end

	local rayParams = RaycastParams.new()
	rayParams.FilterType = Enum.RaycastFilterType.Exclude
	rayParams.FilterDescendantsInstances = {character}
	rayParams.IgnoreWater = true

	local desiredSkiGroundGap = 0.05
	local depthSum = 0
	local depthCount = 0
	local gapSum = 0
	local gapCount = 0

	for _, skiPart in ipairs(skiParts) do
		local halfY = getHalfExtentAlong(skiPart.CFrame, skiPart.Size, Vector3.yAxis)
		local skiBottomY = skiPart.Position.Y - halfY
		depthSum += (rootPart.Position.Y - skiBottomY)
		depthCount += 1

		local groundHit = Workspace:Raycast(skiPart.Position + Vector3.new(0, 6, 0), Vector3.new(0, -24, 0), rayParams)
		if groundHit then
			gapSum += (skiBottomY - groundHit.Position.Y)
			gapCount += 1
		end
	end

	if depthCount <= 0 then
		return false
	end

	State.rideHeight = math.clamp((depthSum / depthCount) + desiredSkiGroundGap, 2.4, 6.4)

	if gapCount > 0 and rootPart.Parent then
		local averageGap = gapSum / gapCount
		local verticalCorrection = math.clamp(desiredSkiGroundGap - averageGap, -2.4, 2.4)
		if math.abs(verticalCorrection) > 0.015 then
			rootPart.CFrame = rootPart.CFrame + Vector3.new(0, verticalCorrection, 0)
			local velocity = rootPart.AssemblyLinearVelocity
			rootPart.AssemblyLinearVelocity = Vector3.new(velocity.X, velocity.Y * 0.2, velocity.Z)
		end
	end

	return true
end

-- ============================================================================
-- MULTI-POINT TERRAIN SAMPLING
-- ============================================================================
-- Cast multiple rays around the character to get a stable ground normal
-- and height. This prevents jitter from rough terrain and stops bump launches.

local function sampleTerrain(position, lookVector, rightVector)
	refreshRideableRaycastFilter(false)
	local results = {}
	local hitCount = 0
	local avgNormal = Vector3.zero
	local closestDist = math.huge
	local closestHit = nil

	-- Ray origins: center, forward, back, left, right, and FORWARD-DOWN
	-- The forward-down ray is critical: it detects upcoming terrain slope
	-- changes BEFORE we reach them, so we can pre-tilt the character
	-- instead of slamming into the new slope nose-first
	local offsets = {
		{ offset = Vector3.zero,                                              weight = 3.0 },  -- Center (heaviest weight)
		{ offset = lookVector * CONFIG.RaySpreadForward,                      weight = 2.0 },  -- Forward (higher weight — we care about what's ahead)
		{ offset = lookVector * CONFIG.RaySpreadForward * 1.8,                weight = 1.5 },  -- Far forward (terrain prediction)
		{ offset = -lookVector * CONFIG.RaySpreadForward * 0.4,               weight = 0.8 },  -- Back (less weight)
		{ offset = rightVector * CONFIG.RaySpreadSide,                        weight = 1.0 },  -- Right
		{ offset = -rightVector * CONFIG.RaySpreadSide,                       weight = 1.0 },  -- Left
	}

	local totalWeight = 0

	for _, ray in ipairs(offsets) do
		local origin = position + ray.offset + Vector3.new(0, 1, 0) -- Start slightly above
		local direction = Vector3.new(0, -(CONFIG.RaycastLength + 1), 0)

		local result = Workspace:Raycast(origin, direction, RayParams)

		if result then
			local dist = (origin - result.Position).Magnitude - 1  -- Subtract the 1 we added
			hitCount = hitCount + 1
			avgNormal = avgNormal + result.Normal * ray.weight
			totalWeight = totalWeight + ray.weight

			if dist < closestDist then
				closestDist = dist
				closestHit = result
			end
		end
	end

	if hitCount > 0 and totalWeight > 0 then
		avgNormal = safeUnit(avgNormal / totalWeight, Vector3.yAxis)
		return true, avgNormal, closestDist, closestHit
	end

	return false, Vector3.yAxis, math.huge, nil
end

-- ============================================================================
-- ANIMATION SYSTEM
-- ============================================================================

local function clearCustomAnimationTracks()
	for _, track in pairs(AnimTracks) do
		if track then
			pcall(function() track:Stop(0) end)
			pcall(function() track:Destroy() end)
		end
	end
	AnimTracks = {}
	LoadedAnimTrackSet = {}
	CurrentAnim = nil
end

local function stopForeignAnimationTracks(fadeTime)
	if not Humanoid then return end
	fadeTime = fadeTime or 0
	for _, track in ipairs(Humanoid:GetPlayingAnimationTracks()) do
		if not LoadedAnimTrackSet[track] then
			pcall(function()
				track:Stop(fadeTime)
			end)
		end
	end
end

local function setCharacterAnimateEnabled(enabled)
	if not Character then return end
	local animateScript = Character:FindFirstChild("Animate")
	if animateScript and animateScript:IsA("LocalScript") then
		animateScript.Enabled = enabled
	end
end

local function loadAnimations()
	if not Humanoid then return end
	clearCustomAnimationTracks()

	Animator = Humanoid:FindFirstChildOfClass("Animator")
	if not Animator then
		Animator = Instance.new("Animator")
		Animator.Parent = Humanoid
	end

	for name, id in pairs(CONFIG.Animations) do
		if id and id ~= "" then
			local anim = Instance.new("Animation")
			local idString = tostring(id)
			if string.find(idString, "rbxassetid://", 1, true) then
				anim.AnimationId = idString
			else
				anim.AnimationId = "rbxassetid://" .. idString
			end
			local ok, track = pcall(function()
				return Animator:LoadAnimation(anim)
			end)
			if ok and track then
				if name == "PolePush" then
					local prioritySet = false
					pcall(function()
						track.Priority = Enum.AnimationPriority.Action4
						prioritySet = true
					end)
					if not prioritySet then
						pcall(function()
							track.Priority = Enum.AnimationPriority.Action
						end)
					end
				elseif name == "Jump" or name == "AirTrick" or name == "Landing" or name == "Crashed" then
					track.Priority = Enum.AnimationPriority.Action
				else
					track.Priority = Enum.AnimationPriority.Movement
				end
				AnimTracks[name] = track
				LoadedAnimTrackSet[track] = true
			end
		end
	end
end

local function playAnim(name, fadeTime, doLoop)
	fadeTime = fadeTime or 0.2
	if doLoop == nil then doLoop = true end

	local track = AnimTracks[name]
	if not track then return end
	if CurrentAnim == name and track.IsPlaying then return end

	-- Stop current
	if CurrentAnim and AnimTracks[CurrentAnim] then
		AnimTracks[CurrentAnim]:Stop(fadeTime)
	end

	if name == "PolePush" then
		for trackName, otherTrack in pairs(AnimTracks) do
			if trackName ~= "PolePush" and otherTrack and otherTrack.IsPlaying then
				otherTrack:Stop(math.min(fadeTime, 0.08))
			end
		end
	end

	track.Looped = doLoop
	track:Play(fadeTime)
	CurrentAnim = name
end

local function stopAllAnims(fadeTime)
	fadeTime = fadeTime or 0.2
	for _, track in pairs(AnimTracks) do
		if track and track.IsPlaying then
			track:Stop(fadeTime)
		end
	end
	CurrentAnim = nil
end

local function getFallbackAnimForState(proceduralState)
	if not proceduralState then
		return nil, true
	end

	local label = proceduralState.state or proceduralState.debugLabel
	if label == "BootWalk" then
		if (proceduralState.speed or 0) >= 7 and AnimTracks.BootRun then
			return "BootRun", true
		end
		return "BootWalk", true
	elseif label == "BootRun" then
		if AnimTracks.BootRun then
			return "BootRun", true
		end
		return "BootWalk", true
	elseif label == "PolePush" then
		if State.pushing then
			return "PolePush", true
		end
		return AnimTracks.SkiGlide and "SkiGlide" or "Skiing", true
	elseif label == "BrakeStop" then
		return "BrakeStop", true
	elseif label == "Carve" then
		return "Carving", true
	elseif label == "SkiGlide" then
		local speed = proceduralState.speed or 0
		if speed < 4 and AnimTracks.BootWalk then
			return "BootWalk", true
		elseif speed < 12 and AnimTracks.BootRun then
			return "BootRun", true
		end
		return AnimTracks.SkiGlide and "SkiGlide" or "Skiing", true
	elseif label == "Airborne" then
		if math.abs(State.rotationInAir or 0) >= 35 and AnimTracks.AirTrick then
			return "AirTrick", true
		end
		return "Jump", false
	elseif label == "Crash" then
		return "Crashed", true
	elseif label == "Recovering" or label == "SkiIdle" then
		return "Idle", true
	end

	return nil, true
end

local function updateFallbackAnimations(proceduralState)
	if next(AnimTracks) == nil then
		return
	end

	if (not State.pushing) and CurrentAnim == "PolePush" and AnimTracks.PolePush and AnimTracks.PolePush.IsPlaying then
		AnimTracks.PolePush:Stop(0.06)
		CurrentAnim = nil
	end

	if State.pushing and AnimTracks.PolePush then
		playAnim("PolePush", 0.06, true)
		return
	end

	if CurrentAnim == "Landing" or CurrentAnim == "Jump" then
		local lockedTrack = AnimTracks[CurrentAnim]
		if lockedTrack and lockedTrack.IsPlaying then
			return
		end
	end

	local animName, looped = getFallbackAnimForState(proceduralState)
	if not animName then
		return
	end

	playAnim(animName, 0.12, looped)
end

-- ============================================================================
-- AVATAR JOINT UPGRADE (RAGDOLL)
-- ============================================================================

local function detectAvatarJointUpgrade()
	AnimationConstraints = {}
	OriginalConstraintStates = {}

	-- Check if character actually has AnimationConstraints
	-- This is the ONLY reliable check (property might not reflect reality)
	for _, desc in pairs(Character:GetDescendants()) do
		if desc:IsA("AnimationConstraint") then
			table.insert(AnimationConstraints, desc)
			OriginalConstraintStates[desc] = {
				IsKinematic = desc.IsKinematic,
				MaxForce    = desc.MaxForce,
				MaxTorque   = desc.MaxTorque,
			}
		end
	end

	HasAvatarJointUpgrade = #AnimationConstraints > 0

	if HasAvatarJointUpgrade then
	end

	return HasAvatarJointUpgrade
end

local function clearRuntimeRagdoll()
	for _, constraint in ipairs(RagdollRuntime.constraints) do
		pcall(function()
			if constraint and constraint.Parent then
				constraint:Destroy()
			end
		end)
	end

	for _, attachment in ipairs(RagdollRuntime.attachments) do
		pcall(function()
			if attachment and attachment.Parent then
				attachment:Destroy()
			end
		end)
	end

	for _, motor in ipairs(RagdollRuntime.motors) do
		pcall(function()
			if motor and motor.Parent then
				motor.Enabled = true
			end
		end)
	end

	for _, entry in ipairs(RagdollRuntime.partCollision) do
		pcall(function()
			if entry.part and entry.part.Parent then
				entry.part.CanCollide = entry.canCollide
				entry.part.CanQuery = entry.canQuery
				entry.part.CanTouch = entry.canTouch
			end
		end)
	end

	RagdollRuntime.active = false
	RagdollRuntime.motors = {}
	RagdollRuntime.constraints = {}
	RagdollRuntime.attachments = {}
	RagdollRuntime.partCollision = {}
end

local function buildRuntimeRagdoll()
	clearRuntimeRagdoll()
	if not Character then return end

	local skiModel = Character:FindFirstChild("Skis")
	for _, desc in ipairs(Character:GetDescendants()) do
		if desc:IsA("Motor6D") and desc.Part0 and desc.Part1 then
			local a0 = Instance.new("Attachment")
			a0.CFrame = desc.C0
			a0.Parent = desc.Part0

			local a1 = Instance.new("Attachment")
			a1.CFrame = desc.C1
			a1.Parent = desc.Part1

			local socket = Instance.new("BallSocketConstraint")
			socket.Attachment0 = a0
			socket.Attachment1 = a1
			socket.LimitsEnabled = true
			socket.UpperAngle = 42
			socket.TwistLimitsEnabled = true
			socket.TwistLowerAngle = -30
			socket.TwistUpperAngle = 30
			socket.MaxFrictionTorque = 35
			socket.Parent = desc.Parent

			desc.Enabled = false
			table.insert(RagdollRuntime.motors, desc)
			table.insert(RagdollRuntime.attachments, a0)
			table.insert(RagdollRuntime.attachments, a1)
			table.insert(RagdollRuntime.constraints, socket)
		elseif desc:IsA("BasePart") then
			local isSkiPart = skiModel and desc:IsDescendantOf(skiModel)
			local isAccessoryPart = desc:FindFirstAncestorWhichIsA("Accessory") ~= nil
			if isSkiPart then
				desc.CanCollide = false
				desc.CanQuery = false
				desc.CanTouch = false
			elseif desc.Name ~= "HumanoidRootPart" then
				table.insert(RagdollRuntime.partCollision, {
					part = desc,
					canCollide = desc.CanCollide,
					canQuery = desc.CanQuery,
					canTouch = desc.CanTouch,
				})
				desc.CanCollide = not isAccessoryPart
				desc.CanTouch = not isAccessoryPart
			end
		end
	end

	RagdollRuntime.active = true
end

-- Forward declarations so crash/recovery paths can call later functions safely.
local recoverFromCrash
local unequipSkis

local function enableRagdoll(impactVelocity)
	if State.current == "crashed" or State.current == "recovering" then return end

	State.current = "crashed"
	updateSkiStateAttribute()
	if ProceduralAnimatorInst then
		ProceduralAnimatorInst:ResetPose()
	end

	if VectorForceInst then VectorForceInst.Enabled = false end
	if AlignOrientInst then AlignOrientInst.Enabled = false end

	if Humanoid then
		Humanoid.AutoRotate = false
		Humanoid.BreakJointsOnDeath = false
		Humanoid.PlatformStand = true
	end

	buildRuntimeRagdoll()

	if RootPart then
		RootPart.AssemblyAngularVelocity = RootPart.AssemblyAngularVelocity * 0.2
		if impactVelocity then
			local planar = Vector3.new(impactVelocity.X, 0, impactVelocity.Z)
			local crashDir = safeUnit(planar, RootPart.CFrame.LookVector)
			local crashSpeed = math.clamp(planar.Magnitude * 0.18, 8, 36)
			local upBoost = math.clamp(impactVelocity.Magnitude * 0.05, 3, 10)
			RootPart.AssemblyLinearVelocity = crashDir * crashSpeed + Vector3.new(0, upBoost, 0)
		else
			RootPart.AssemblyLinearVelocity = Vector3.zero
		end
	end

	if Sounds.Wind then Sounds.Wind.Volume = 0 end
	if Sounds.Carve then Sounds.Carve.Volume = 0 end
	for _, p in pairs(ParticleEmitters) do p.Rate = 0 end

	task.delay(CONFIG.Crash.CrashRecoveryTime, function()
		if State.current == "crashed" then
			recoverFromCrash()
		end
	end)
end


recoverFromCrash = function()
	if State.current == "recovering" then return end
	State.current = "recovering"
	updateSkiStateAttribute()

	-- Stop all motion
	if RootPart then
		RootPart.AssemblyLinearVelocity = Vector3.zero
		RootPart.AssemblyAngularVelocity = Vector3.zero
		local pos = RootPart.Position
		local lookDir = RootPart.CFrame.LookVector
		local flatLook = Vector3.new(lookDir.X, 0, lookDir.Z)
		if flatLook.Magnitude < 0.01 then flatLook = Vector3.new(0, 0, -1) end
		RootPart.CFrame = CFrame.lookAt(pos, pos + flatLook.Unit)
	end
	State.velocity = Vector3.zero

	clearRuntimeRagdoll()

	-- Briefly stand the character up, then hand control back to ski physics.
	if Humanoid then
		Humanoid.PlatformStand = false
		Humanoid.AutoRotate = true
		local targetSpeed = State.savedWalkSpeed or 16
		if targetSpeed < 0.1 then targetSpeed = 16 end
		Humanoid.WalkSpeed = targetSpeed
		Humanoid.JumpPower = State.savedJumpPower or 50
		Humanoid.JumpHeight = State.savedJumpHeight or 7.2
		pcall(function()
			Humanoid:ChangeState(Enum.HumanoidStateType.GettingUp)
		end)
	end

	State.velocity = Vector3.zero
	State.airTimer = 0
	State.isReallyInAir = false
	State.groundLostTimer = 0
	State.rotationInAir = 0
	State.justJumped = false
	State.jumpCooldown = 0.15

	task.delay(0.35, function()
		if State.current ~= "recovering" or not Humanoid or not RootPart or not Character or not Character.Parent then
			return
		end
		Humanoid.PlatformStand = true
		Humanoid.AutoRotate = false
		Humanoid.WalkSpeed = 0
		Humanoid.JumpPower = 0
		Humanoid.JumpHeight = 0
		if VectorForceInst then VectorForceInst.Enabled = true end
		if AlignOrientInst then
			AlignOrientInst.Enabled = true
			AlignOrientInst.CFrame = RootPart.CFrame
		end
		State.current = "skiing"
		State.velocity = RootPart.AssemblyLinearVelocity
		State.facingCFrame = RootPart.CFrame
		updateSkiStateAttribute()
		playAnim("Idle")
	end)
end

-- ============================================================================
-- LANDING CHECK
-- ============================================================================

local function checkLanding(groundNormal)
	if State.current ~= "skiing" then return end

	-- Only check if we were truly in the air (past grace period)
	if not State.isReallyInAir then return end
	local minAirTime = math.max(CONFIG.AirGraceAfterJump, 0.08)
	if State.airTimer < minAirTime then return end

	local speed = State.velocity.Magnitude

	-- Calculate landing angle (how far from upright)
	local landingDot = RootPart.CFrame.UpVector:Dot(groundNormal)
	landingDot = math.clamp(landingDot, -1, 1)
	local landingAngle = math.deg(math.acos(landingDot))

	-- Determine if we crash
	local shouldCrash = false

	-- Very bad angle = always crash
	if landingAngle > CONFIG.Crash.LandingAngleTolerance * 1.5 then
		shouldCrash = true
		-- High speed + moderate angle = chance of crash
	elseif speed > CONFIG.Crash.MinCrashSpeed and landingAngle > CONFIG.Crash.LandingAngleTolerance * 0.5 then
		local crashChance = 1.0 - CONFIG.Crash.LandingSuccessBase
		-- More speed = more crash chance
		crashChance = crashChance + (speed - CONFIG.Crash.MinCrashSpeed) / 200
		-- Worse angle = more crash chance
		crashChance = crashChance + (landingAngle - CONFIG.Crash.LandingAngleTolerance * 0.5) / 90
		crashChance = math.clamp(crashChance, 0, 0.95)
		shouldCrash = math.random() < crashChance
	end

	if shouldCrash then
		enableRagdoll(State.velocity)
	else
		-- Successful landing.
		-- Preserve carry speed by projecting the incoming velocity onto the landing plane
		-- instead of scaling it down on touchdown.
		local incomingVelocity = State.velocity
		local landingVelocity = projectOnPlane(incomingVelocity, groundNormal)
		local horizontalSpeed = Vector3.new(incomingVelocity.X, 0, incomingVelocity.Z).Magnitude

		if horizontalSpeed > 0.01 then
			if landingVelocity.Magnitude > 0.01 then
				landingVelocity = landingVelocity.Unit * math.max(landingVelocity.Magnitude, horizontalSpeed)
			else
				local fallbackFwd = projectOnPlane(State.facingCFrame.LookVector, groundNormal)
				fallbackFwd = safeUnit(fallbackFwd, projectOnPlane(RootPart.CFrame.LookVector, groundNormal))
				landingVelocity = fallbackFwd * horizontalSpeed
			end
		end

		State.velocity = landingVelocity
		RootPart.AssemblyLinearVelocity = landingVelocity

		-- Force character orientation to match terrain
		local pos = RootPart.Position
		local flatFwd = projectOnPlane(State.facingCFrame.LookVector, groundNormal)
		if flatFwd.Magnitude > 0.01 then
			flatFwd = flatFwd.Unit
			local right = flatFwd:Cross(groundNormal).Unit
			State.facingCFrame = CFrame.fromMatrix(pos, right, groundNormal, -flatFwd)
		end

		playAnim("Landing", 0.1, false)
		task.delay(0.4, function()
			if State.current == "skiing" and not State.isReallyInAir then
				playAnim("Skiing")
			end
		end)
	end

	-- Reset air tracking
	State.airTimer = 0
	State.isReallyInAir = false
	State.rotationInAir = 0
end

-- ============================================================================
-- VFX / AUDIO / UI
-- ============================================================================

local function createParticles(parent)
	if MistController then
		MistController:Destroy()
	end
	MistController = SkiMistVFX.new(parent, Player, GraphicsProfile)
	ParticleEmitters = MistController and MistController.Emitters or {}
end

local function createAudio(parent)
	local wind = Instance.new("Sound", parent)
	wind.SoundId = ""
	wind.Looped = true
	wind.Volume = 0
	wind.RollOffMode = Enum.RollOffMode.InverseTapered
	wind:Play()
	Sounds.Wind = wind

	local carve = Instance.new("Sound", parent)
	carve.SoundId = "rbxassetid://130767448"
	carve.Looped = true
	carve.Volume = 0
	carve.RollOffMode = Enum.RollOffMode.InverseTapered
	carve:Play()
	Sounds.Carve = carve
end

local function createUI()
	if ScreenGui then ScreenGui:Destroy() end

	ScreenGui = Instance.new("ScreenGui")
	ScreenGui.Name = "SkiHUD"
	ScreenGui.ResetOnSpawn = true
	ScreenGui.Parent = Player.PlayerGui

	-- Speed display
	SpeedLabel = Instance.new("TextLabel")
	SpeedLabel.Size = UDim2.new(0, 200, 0, 50)
	SpeedLabel.Position = UDim2.new(0.5, -100, 0.85, 0)
	SpeedLabel.BackgroundTransparency = 1
	SpeedLabel.TextColor3 = Color3.new(1, 1, 1)
	SpeedLabel.Font = Enum.Font.GothamBlack
	SpeedLabel.TextSize = 40
	SpeedLabel.Text = "0"
	SpeedLabel.TextStrokeTransparency = 0.4
	SpeedLabel.TextStrokeColor3 = Color3.new(0, 0, 0)
	SpeedLabel.Parent = ScreenGui

	local units = Instance.new("TextLabel", SpeedLabel)
	units.Size = UDim2.new(1, 0, 0.5, 0)
	units.Position = UDim2.new(0, 0, 0.9, 0)
	units.BackgroundTransparency = 1
	units.TextColor3 = Color3.fromRGB(200, 210, 230)
	units.Font = Enum.Font.GothamMedium
	units.TextSize = 16
	units.Text = "MPH"
	SpeedUnitsLabel = units
	refreshSpeedUnitsLabel()
	Player:GetAttributeChangedSignal(SETTINGS_ATTR_PREFIX .. "UnitSystem"):Connect(refreshSpeedUnitsLabel)
	units.TextStrokeTransparency = 0.5

	-- Jump charge bar
	ChargeBarBg = Instance.new("Frame", ScreenGui)
	ChargeBarBg.Size = UDim2.new(0, 200, 0, 8)
	ChargeBarBg.Position = UDim2.new(0.5, -100, 0.83, 0)
	ChargeBarBg.BackgroundColor3 = Color3.fromRGB(30, 30, 30)
	ChargeBarBg.BackgroundTransparency = 0.4
	ChargeBarBg.BorderSizePixel = 0

	local corner = Instance.new("UICorner", ChargeBarBg)
	corner.CornerRadius = UDim.new(0, 4)

	ChargeBar = Instance.new("Frame", ChargeBarBg)
	ChargeBar.Size = UDim2.new(0, 0, 1, 0)
	ChargeBar.BackgroundColor3 = Color3.fromRGB(255, 180, 0)
	ChargeBar.BorderSizePixel = 0

	local corner2 = Instance.new("UICorner", ChargeBar)
	corner2.CornerRadius = UDim.new(0, 4)

	-- State indicator (debug — remove in production)
	local stateLabel = Instance.new("TextLabel", ScreenGui)
	stateLabel.Name = "StateLabel"
	stateLabel.Size = UDim2.new(0, 200, 0, 25)
	stateLabel.Position = UDim2.new(0.5, -100, 0.78, 0)
	stateLabel.BackgroundTransparency = 1
	stateLabel.TextColor3 = Color3.fromRGB(180, 180, 180)
	stateLabel.Font = Enum.Font.GothamMedium
	stateLabel.TextSize = 14
	stateLabel.Text = ""
	stateLabel.TextStrokeTransparency = 0.6
end

-- ============================================================================
-- EQUIP / UNEQUIP
-- ============================================================================

local function equipSkis()
	Character = Player.Character
	if not Character then return end

	RootPart = Character:WaitForChild("HumanoidRootPart", 5)
	Humanoid = Character:WaitForChild("Humanoid", 5)
	if not RootPart or not Humanoid then
		return
	end

	-- Setup raycast filter
	refreshRideableRaycastFilter(true)

	-- Death cleanup
	if HumanoidDiedConnection then
		HumanoidDiedConnection:Disconnect()
		HumanoidDiedConnection = nil
	end
	HumanoidDiedConnection = Humanoid.Died:Connect(function()
		unequipSkis()
	end)

	-- Reset state
	State.current = "skiing"
	updateSkiStateAttribute()
	State.velocity = RootPart.AssemblyLinearVelocity
	State.facingCFrame = RootPart.CFrame
	State.smoothNormal = Vector3.yAxis
	State.airTimer = 0
	State.isReallyInAir = false
	State.groundLostTimer = 0
	State.jumpCharge = 0
	State.isChargingJump = false
	State.justJumped = false
	State.steer = 0
	State.braking = false
	State.wasBraking = false
	State.pushing = false
	State.pushCycleElapsed = 0
	State.pushCyclePrimed = false
	State.pushImpulseFired = false
	State.turnRate = 0
	State.slipAmount = 0
	State.groundedAlpha = 1
	State.pushAnimTimer = 0
	State.rideHeight = estimateRideHeight(Character, RootPart, Humanoid)
	MobileTurnLeftHeld = false
	MobileTurnRightHeld = false
	mobileButtonSteer = 0

	-- Detect Avatar Joint Upgrade
	detectAvatarJointUpgrade()

	local animateScript = Character:FindFirstChild("Animate")
	if animateScript and animateScript:IsA("LocalScript") then
		State.savedAnimateEnabled = animateScript.Enabled
		animateScript.Enabled = false
	end

	-- ── CREATE PHYSICS MOVERS ──
	-- We use VectorForce (not LinearVelocity!) so gravity still works naturally.
	-- VectorForce ADDS a force to the character. If we don't add any upward force,
	-- the character falls normally. We only push up when the ground is close.
	PhysicsAttachment = Instance.new("Attachment")
	PhysicsAttachment.Name = "SkiPhysicsAtt"
	PhysicsAttachment.Parent = RootPart

	VectorForceInst = Instance.new("VectorForce")
	VectorForceInst.Name = "SkiForce"
	VectorForceInst.Attachment0 = PhysicsAttachment
	VectorForceInst.Force = Vector3.zero
	VectorForceInst.ApplyAtCenterOfMass = true
	VectorForceInst.RelativeTo = Enum.ActuatorRelativeTo.World
	VectorForceInst.Parent = RootPart

	AlignOrientInst = Instance.new("AlignOrientation")
	AlignOrientInst.Name = "SkiOrient"
	AlignOrientInst.Attachment0 = PhysicsAttachment
	AlignOrientInst.Mode = Enum.OrientationAlignmentMode.OneAttachment
	AlignOrientInst.RigidityEnabled = false   -- Use responsiveness instead
	AlignOrientInst.Responsiveness = 25       -- Medium responsiveness — doesn't fight collisions as hard
	AlignOrientInst.MaxTorque = 50000         -- Enough to orient but can be overpowered by collision
	AlignOrientInst.CFrame = RootPart.CFrame
	AlignOrientInst.Parent = RootPart

	-- ── HUMANOID SETUP ──
	-- Save original movement stats to restore on unequip
	-- Stop saving 0 if they equip while already skiing
	if Humanoid.WalkSpeed > 0.1 then
		State.savedWalkSpeed = Humanoid.WalkSpeed
	end
	if Humanoid.JumpPower > 0.1 then
		State.savedJumpPower = Humanoid.JumpPower
	end
	if Humanoid.JumpHeight > 0.1 then
		State.savedJumpHeight = Humanoid.JumpHeight
	end
	
	-- Force camera out of first person to prevent the core camera module from violently forcing character rotation
	if Player.CameraMinZoomDistance < 10 then
		State.savedMinZoom = Player.CameraMinZoomDistance
		Player.CameraMinZoomDistance = 10
	end
	
	Humanoid.PlatformStand = true
	Humanoid.AutoRotate = false
	Humanoid.WalkSpeed = 0
	Humanoid.JumpPower = 0
	Humanoid.JumpHeight = 0

	-- Hard reset any pre-existing tracks so we do not blend Roblox/default tracks with ski tracks.
	stopForeignAnimationTracks(0)
	resetCharacterMotorTransforms(Character)
	RunService.Heartbeat:Wait()
	resetCharacterMotorTransforms(Character)

	-- Tell server to attach skis only after locomotion + joint transforms are stabilized.
	if SkiEvent then
		SkiEvent:FireServer(true)
	end

	-- Once skis replicate back, settle ride-height for a few frames so run->equip and stand->equip match.
	task.spawn(function()
		local deadline = tick() + 1.2
		local settledFrames = 0
		while tick() < deadline do
			if State.current ~= "skiing" or not Character or not Character.Parent or not RootPart or not RootPart.Parent then
				return
			end
			if syncRideHeightWithMountedSkis(Character, RootPart) then
				settledFrames += 1
				if settledFrames >= 6 then
					return
				end
			end
			RunService.Heartbeat:Wait()
		end
	end)

	-- ── EFFECTS ──
	createParticles(RootPart)
	createAudio(RootPart)
	createUI()
	loadAnimations()
	if ProceduralAnimatorInst then
		ProceduralAnimatorInst:Destroy()
	end
	ProceduralAnimatorInst = ProceduralSkiAnimator.new(Character, Humanoid)

	State.facingCFrame = RootPart.CFrame

	playAnim("Idle")
	stopForeignAnimationTracks(0)
	lastForeignAnimStop = tick()
	if updateMobileToggleButton then
		updateMobileToggleButton()
	end
end

unequipSkis = function()
	State.current = "off"
	updateSkiStateAttribute()
	clearRuntimeRagdoll()
	if HumanoidDiedConnection then
		HumanoidDiedConnection:Disconnect()
		HumanoidDiedConnection = nil
	end

	if SkiEvent then
		SkiEvent:FireServer(false)
	end

	stopAllAnims(0)
	clearCustomAnimationTracks()
	if ProceduralAnimatorInst then
		ProceduralAnimatorInst:Destroy()
		ProceduralAnimatorInst = nil
	end
	setCharacterAnimateEnabled(State.savedAnimateEnabled ~= false)
	State.savedAnimateEnabled = nil

	-- Destroy physics
	if VectorForceInst then VectorForceInst:Destroy() VectorForceInst = nil end
	if AlignOrientInst then AlignOrientInst:Destroy() AlignOrientInst = nil end
	if PhysicsAttachment then PhysicsAttachment:Destroy() PhysicsAttachment = nil end

	-- Destroy effects
	if ScreenGui then ScreenGui:Destroy() ScreenGui = nil end
	local staleHud = PlayerGui:FindFirstChild("SkiHUD")
	if staleHud then staleHud:Destroy() end
	if MistController then
		MistController:Destroy()
		MistController = nil
	end
	ParticleEmitters = {}
	for _, s in pairs(Sounds) do pcall(function() s:Destroy() end) end
	Sounds = {}

	-- Restore humanoid — ensure ragdoll recovery is complete
	if Humanoid then
		Humanoid.PlatformStand = false
		Humanoid.AutoRotate = true
		local targetSpeed = State.savedWalkSpeed or 150
		if targetSpeed < 0.1 then targetSpeed = 16 end
		Humanoid.WalkSpeed = targetSpeed
		Humanoid.JumpPower = State.savedJumpPower or 50
		Humanoid.JumpHeight = State.savedJumpHeight or 7.2
	end
	MobileTurnLeftHeld = false
	MobileTurnRightHeld = false
	mobileButtonSteer = 0

	-- Force-reset root part physics so player isn't stuck on the ground
	local root = Character and Character:FindFirstChild("HumanoidRootPart")
	if root then
		root.AssemblyLinearVelocity = Vector3.zero
		root.AssemblyAngularVelocity = Vector3.zero
		-- Stand the character up if they were ragdolled
		local pos = root.Position
		local lookDir = root.CFrame.LookVector
		local flatLook = Vector3.new(lookDir.X, 0, lookDir.Z)
		if flatLook.Magnitude < 0.01 then flatLook = Vector3.new(0, 0, -1) end
		root.CFrame = CFrame.lookAt(pos, pos + flatLook.Unit)
	end

	-- Reset camera
	TweenService:Create(Camera, TweenInfo.new(0.8, Enum.EasingStyle.Cubic), {
		FieldOfView = CONFIG.FOV_Base
	}):Play()
	if State.savedMinZoom then
		Player.CameraMinZoomDistance = State.savedMinZoom
		State.savedMinZoom = nil
	end
	if updateMobileToggleButton then
		updateMobileToggleButton()
	end
end

local function findGuiObjectByPath(pathParts)
	local current = PlayerGui
	for _, name in ipairs(pathParts) do
		current = current and current:FindFirstChild(name)
		if not current then
			return nil
		end
	end
	return current
end

local function isGuiObjectOnScreen(guiObject)
	if not guiObject or not guiObject:IsA("GuiObject") or not guiObject.Visible then
		return false
	end

	local size = guiObject.AbsoluteSize
	if size.X <= 0 or size.Y <= 0 then
		return false
	end

	local viewport = Camera and Camera.ViewportSize or Vector2.zero
	if viewport.X <= 0 or viewport.Y <= 0 then
		return true
	end

	local position = guiObject.AbsolutePosition
	return position.X < viewport.X
		and position.Y < viewport.Y
		and (position.X + size.X) > 0
		and (position.Y + size.Y) > 0
end

local function isUiBlockingSkis()
	if UserInputService:GetFocusedTextBox() then
		return true
	end

	if ModeState and ModeState.Value ~= "" then
		return true
	end

	for _, pathParts in ipairs(UIBlockerPaths) do
		if isGuiObjectOnScreen(findGuiObjectByPath(pathParts)) then
			return true
		end
	end

	return false
end

local function disconnectGuiBlockerConnections(guiObject)
	local connections = UIBlockerConnections[guiObject]
	if not connections then
		return
	end
	for _, connection in ipairs(connections) do
		connection:Disconnect()
	end
	UIBlockerConnections[guiObject] = nil
end

local function queueSkiBlockerCheck()
	if blockerCheckQueued then
		return
	end
	blockerCheckQueued = true
	task.defer(function()
		blockerCheckQueued = false
		if (State.current == "skiing" or State.current == "airborne") and isUiBlockingSkis() then
			unequipSkis()
		end
	end)
end

local function bindGuiBlocker(guiObject)
	if not guiObject or not guiObject:IsA("GuiObject") or UIBlockerConnections[guiObject] then
		return
	end

	UIBlockerConnections[guiObject] = {
		guiObject:GetPropertyChangedSignal("Visible"):Connect(queueSkiBlockerCheck),
		guiObject:GetPropertyChangedSignal("Position"):Connect(queueSkiBlockerCheck),
		guiObject.AncestryChanged:Connect(function(_, parent)
			if not parent then
				disconnectGuiBlockerConnections(guiObject)
			end
			queueSkiBlockerCheck()
		end),
	}
end

local function watchSkiBlockerGuis()
	for _, pathParts in ipairs(UIBlockerPaths) do
		bindGuiBlocker(findGuiObjectByPath(pathParts))
	end
end

local function setMobileTurnHeld(direction, isHeld)
	if direction == "left" then
		MobileTurnLeftHeld = isHeld
	elseif direction == "right" then
		MobileTurnRightHeld = isHeld
	end
	mobileButtonSteer = (MobileTurnLeftHeld and 1 or 0) + (MobileTurnRightHeld and -1 or 0)
	if updateMobileToggleButton then
		updateMobileToggleButton()
	end
end

local function bindHoldButton(button, direction)
	if not button then
		return
	end
	button.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.Touch or input.UserInputType == Enum.UserInputType.MouseButton1 then
			setMobileTurnHeld(direction, true)
		end
	end)
	button.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.Touch or input.UserInputType == Enum.UserInputType.MouseButton1 then
			setMobileTurnHeld(direction, false)
		end
	end)
	button.AncestryChanged:Connect(function(_, parent)
		if not parent then
			setMobileTurnHeld(direction, false)
		end
	end)
end

local function createMobileSteerButton(name, text, position)
	local button = Instance.new("TextButton")
	button.Name = name
	button.AnchorPoint = Vector2.new(1, 1)
	button.Size = UDim2.fromOffset(56, 48)
	button.Position = position
	button.BackgroundColor3 = Color3.fromRGB(20, 28, 42)
	button.BackgroundTransparency = 0.08
	button.TextColor3 = Color3.new(1, 1, 1)
	button.Font = Enum.Font.GothamBlack
	button.TextSize = 22
	button.Text = text
	button.AutoButtonColor = false
	button.Parent = MobileToggleGui
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 14)
	corner.Parent = button
	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.fromRGB(8, 32, 64)
	stroke.Transparency = 0.18
	stroke.Parent = button
	return button
end

local function ensureDesktopToggleButton()
	if not supportsDesktopSkiControls() then
		return
	end
	if DesktopToggleGui and DesktopToggleGui.Parent and DesktopToggleButton and DesktopToggleButton.Parent then
		return
	end
	DesktopToggleGui = Instance.new("ScreenGui")
	DesktopToggleGui.Name = "SkiDesktopControls"
	DesktopToggleGui.ResetOnSpawn = true
	DesktopToggleGui.DisplayOrder = 34
	DesktopToggleGui.Parent = PlayerGui

	DesktopToggleButton = Instance.new("TextButton")
	DesktopToggleButton.Name = "ToggleSki"
	DesktopToggleButton.AnchorPoint = Vector2.new(0, 1)
	DesktopToggleButton.Size = UDim2.fromOffset(120, 48)
	DesktopToggleButton.Position = UDim2.new(0, 20, 1, -124)
	DesktopToggleButton.BackgroundColor3 = Color3.fromRGB(14, 131, 116)
	DesktopToggleButton.BackgroundTransparency = 0.08
	DesktopToggleButton.TextColor3 = Color3.new(1, 1, 1)
	DesktopToggleButton.Font = Enum.Font.GothamBlack
	DesktopToggleButton.TextSize = 18
	DesktopToggleButton.Text = "SKI (Q)"
	DesktopToggleButton.AutoButtonColor = true
	DesktopToggleButton.Parent = DesktopToggleGui
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 16)
	corner.Parent = DesktopToggleButton
	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.fromRGB(8, 32, 64)
	stroke.Transparency = 0.15
	stroke.Parent = DesktopToggleButton
	DesktopToggleButton.Activated:Connect(function()
		if toggleSkis then
			toggleSkis()
		end
	end)
end

local function ensureMobileToggleButton()
	if not supportsMobileSkiControls() then
		return
	end
	if MobileToggleGui and MobileToggleGui.Parent and MobileToggleButton and MobileToggleButton.Parent and MobileTurnLeftButton and MobileTurnRightButton then
		return
	end
	MobileToggleGui = Instance.new("ScreenGui")
	MobileToggleGui.Name = "SkiMobileControls"
	MobileToggleGui.ResetOnSpawn = true
	MobileToggleGui.DisplayOrder = 35
	MobileToggleGui.Parent = PlayerGui

	MobileTurnLeftButton = createMobileSteerButton("TurnLeft", "<", UDim2.new(1, -318, 1, -204))
	MobileTurnRightButton = createMobileSteerButton("TurnRight", ">", UDim2.new(1, -244, 1, -204))
	bindHoldButton(MobileTurnLeftButton, "left")
	bindHoldButton(MobileTurnRightButton, "right")

	MobileToggleButton = Instance.new("TextButton")
	MobileToggleButton.Name = "ToggleSki"
	MobileToggleButton.AnchorPoint = Vector2.new(1, 1)
	MobileToggleButton.Size = UDim2.fromOffset(104, 48)
	MobileToggleButton.Position = UDim2.new(1, -40, 1, -150)
	MobileToggleButton.BackgroundColor3 = Color3.fromRGB(14, 131, 116)
	MobileToggleButton.TextColor3 = Color3.new(1, 1, 1)
	MobileToggleButton.Font = Enum.Font.GothamBlack
	MobileToggleButton.TextSize = 20
	MobileToggleButton.Text = "SKI"
	MobileToggleButton.AutoButtonColor = true
	MobileToggleButton.Parent = MobileToggleGui
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 16)
	corner.Parent = MobileToggleButton
	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.fromRGB(8, 32, 64)
	stroke.Transparency = 0.15
	stroke.Parent = MobileToggleButton
	MobileToggleButton.Activated:Connect(function()
		if toggleSkis then
			toggleSkis()
		end
	end)
end

updateMobileToggleButton = function()
	local blocked = Player:GetAttribute("IsDrivingBison") or isUiBlockingSkis()
	local canSteer = State.current == "skiing" or State.current == "airborne"

	if supportsDesktopSkiControls() then
		ensureDesktopToggleButton()
		if DesktopToggleButton then
			DesktopToggleButton.Visible = not Player:GetAttribute("IsDrivingBison")
			if State.current == "off" then
				DesktopToggleButton.Text = "SKI (Q)"
				DesktopToggleButton.BackgroundColor3 = blocked and Color3.fromRGB(68, 76, 96) or Color3.fromRGB(14, 131, 116)
				DesktopToggleButton.AutoButtonColor = not blocked
			elseif State.current == "crashed" then
				DesktopToggleButton.Text = "RECOVER"
				DesktopToggleButton.BackgroundColor3 = Color3.fromRGB(220, 148, 32)
				DesktopToggleButton.AutoButtonColor = true
			else
				DesktopToggleButton.Text = "STOP"
				DesktopToggleButton.BackgroundColor3 = Color3.fromRGB(228, 77, 66)
				DesktopToggleButton.AutoButtonColor = true
			end
			DesktopToggleButton.TextTransparency = blocked and State.current == "off" and 0.25 or 0
		end
	end

	if not supportsMobileSkiControls() then
		return
	end
	ensureMobileToggleButton()
	if not MobileToggleButton then
		return
	end
	local showStartButton = State.current ~= "off" or (isMobileSkiButtonEnabled() and not blocked)
	MobileToggleButton.Visible = (not Player:GetAttribute("IsDrivingBison")) and showStartButton
	if MobileTurnLeftButton then
		MobileTurnLeftButton.Visible = canSteer
		MobileTurnLeftButton.BackgroundColor3 = MobileTurnLeftHeld and Color3.fromRGB(72, 182, 255) or Color3.fromRGB(18, 34, 40)
	end
	if MobileTurnRightButton then
		MobileTurnRightButton.Visible = canSteer
		MobileTurnRightButton.BackgroundColor3 = MobileTurnRightHeld and Color3.fromRGB(72, 182, 255) or Color3.fromRGB(18, 34, 40)
	end
	if State.current == "off" then
		MobileToggleButton.Text = "SKI"
		MobileToggleButton.BackgroundColor3 = blocked and Color3.fromRGB(68, 76, 96) or Color3.fromRGB(14, 131, 116)
		MobileToggleButton.AutoButtonColor = not blocked
	elseif State.current == "crashed" then
		MobileToggleButton.Text = "RECOVER"
		MobileToggleButton.BackgroundColor3 = Color3.fromRGB(220, 148, 32)
		MobileToggleButton.AutoButtonColor = true
	else
		MobileToggleButton.Text = "STOP"
		MobileToggleButton.BackgroundColor3 = Color3.fromRGB(228, 77, 66)
		MobileToggleButton.AutoButtonColor = true
	end
	MobileToggleButton.TextTransparency = blocked and State.current == "off" and 0.25 or 0
end

watchSkiBlockerGuis()
PlayerGui.ChildAdded:Connect(function()
	task.defer(function()
		watchSkiBlockerGuis()
		queueSkiBlockerCheck()
		if updateMobileToggleButton then
			updateMobileToggleButton()
		end
	end)
end)
UserInputService.TextBoxFocused:Connect(queueSkiBlockerCheck)
Player:GetAttributeChangedSignal("IsDrivingBison"):Connect(function()
	queueSkiBlockerCheck()
	if updateMobileToggleButton then
		updateMobileToggleButton()
	end
end)
Player:GetAttributeChangedSignal(SETTINGS_ATTR_PREFIX .. "ShowMobileSkiButton"):Connect(function()
	if updateMobileToggleButton then
		updateMobileToggleButton()
	end
end)
ModeState:GetPropertyChangedSignal("Value"):Connect(function()
	queueSkiBlockerCheck()
	if updateMobileToggleButton then
		updateMobileToggleButton()
	end
end)
if ClosePanels then
	ClosePanels.Event:Connect(function(source)
		if source ~= "Ski" then
			queueSkiBlockerCheck()
			if updateMobileToggleButton then
				updateMobileToggleButton()
			end
		end
	end)
end

toggleSkis = function()
	if State.current == "off" then
		if Player:GetAttribute("IsDrivingBison") then return end
		if isUiBlockingSkis() then
			if ClosePanels then
				ClosePanels:Fire("Ski")
			end
			if not mobileToggleRetryQueued then
				mobileToggleRetryQueued = true
				task.delay(0.15, function()
					mobileToggleRetryQueued = false
					if State.current == "off" and not Player:GetAttribute("IsDrivingBison") and not isUiBlockingSkis() then
						equipSkis()
						if updateMobileToggleButton then
							updateMobileToggleButton()
						end
					elseif updateMobileToggleButton then
						updateMobileToggleButton()
					end
				end)
			end
			if updateMobileToggleButton then
				updateMobileToggleButton()
			end
			return
		end
		equipSkis()
		if updateMobileToggleButton then
			updateMobileToggleButton()
		end
		return
	end
	if State.current == "crashed" then
		recoverFromCrash()
		if updateMobileToggleButton then
			updateMobileToggleButton()
		end
		return
	end
	if State.current == "recovering" then
		return
	end
	unequipSkis()
	if updateMobileToggleButton then
		updateMobileToggleButton()
	end
end

ensureMobileToggleButton()
updateMobileToggleButton()

-- ============================================================================
-- INPUT HANDLING
-- ============================================================================

UserInputService.InputBegan:Connect(function(input, gameProcessed)
	if gameProcessed then return end

	-- Toggle skiing unless another build tool owns the keybind.
	if input.KeyCode == CONFIG.Keybind then
		local modeState = PlayerGui:FindFirstChild("ModeState") or ReplicatedStorage:FindFirstChild("ModeState")
		if modeState and modeState.Value == "Terraforming" then
			return
		end
		toggleSkis()
		return
	end

	-- Manual crash recovery
	if input.KeyCode == Enum.KeyCode.R and State.current == "crashed" then
		recoverFromCrash()
		return
	end

	-- Skiing inputs
	if State.current ~= "skiing" then return end

	if input.KeyCode == Enum.KeyCode.W then
		State.pushing = true
		State.pushCyclePrimed = false
		State.pushCycleElapsed = 0
		State.pushImpulseFired = false
		State.pushAnimTimer = math.max(0.2, tonumber(CONFIG.PushCooldown) or 0.6)

	elseif input.KeyCode == Enum.KeyCode.S then
		State.braking = true

	elseif input.KeyCode == Enum.KeyCode.Space then
		-- Start charging jump
		State.isChargingJump = true
		State.jumpCharge = 0
	end
end)

UserInputService.InputEnded:Connect(function(input)
	if input.KeyCode == Enum.KeyCode.W then
		State.pushing = false
		State.pushCyclePrimed = false
		State.pushCycleElapsed = 0
		State.pushImpulseFired = false

	elseif input.KeyCode == Enum.KeyCode.S then
		State.braking = false

	elseif input.KeyCode == Enum.KeyCode.Space then
		-- Release jump
		if State.isChargingJump and State.current == "skiing" and not State.isReallyInAir then
			local chargePercent = math.clamp(State.jumpCharge / CONFIG.JumpChargeTime, 0, 1)
			local baseJumpPower = lerp(CONFIG.JumpBase, CONFIG.JumpMax, chargePercent)
			local speed = State.velocity.Magnitude
			local highSpeedT = inverseLerp(CONFIG.HighSpeedJumpSoftCap, CONFIG.TerminalVelocity, speed)
			local speedScale = lerp(1.0, CONFIG.HighSpeedJumpMinScale, highSpeedT)
			local jumpPower = baseJumpPower * speedScale
			local normal = safeUnit(State.smoothNormal, Vector3.yAxis)
			local upFactor = math.clamp(normal:Dot(Vector3.yAxis), 0.15, 1.0)
			local forwardDir = projectOnPlane(State.facingCFrame.LookVector, normal)
			if forwardDir.Magnitude < 0.01 then
				forwardDir = projectOnPlane(State.facingCFrame.LookVector, Vector3.yAxis)
			end
			forwardDir = safeUnit(forwardDir, Vector3.new(0, 0, -1))
			local forwardImpulse = jumpPower * CONFIG.JumpForwardScale * (1 - upFactor)

			-- Controlled jump impulse: mostly vertical, slight forward pop.
			local upwardImpulse = math.min(
				(jumpPower * 0.7) + (jumpPower * upFactor * 0.55),
				CONFIG.MaxJumpUpVelocity
			)
			local jumpImpulse = Vector3.new(0, upwardImpulse, 0) + (forwardDir * forwardImpulse)
			State.velocity = State.velocity + jumpImpulse
			local minTakeoffY = upwardImpulse * 0.5
			if State.velocity.Y < minTakeoffY then
				State.velocity = Vector3.new(State.velocity.X, minTakeoffY, State.velocity.Z)
			end
			if State.velocity.Y > CONFIG.MaxJumpUpVelocity then
				State.velocity = Vector3.new(State.velocity.X, CONFIG.MaxJumpUpVelocity, State.velocity.Z)
			end
			if RootPart then
				local physVel = RootPart.AssemblyLinearVelocity + jumpImpulse
				if physVel.Y < minTakeoffY then
					physVel = Vector3.new(physVel.X, minTakeoffY, physVel.Z)
				end
				if physVel.Y > CONFIG.MaxJumpUpVelocity then
					physVel = Vector3.new(physVel.X, CONFIG.MaxJumpUpVelocity, physVel.Z)
				end
				RootPart.AssemblyLinearVelocity = physVel
			end

			State.justJumped = true
			State.jumpCooldown = 0.22  -- Keep suspension/ground snap from stealing jump takeoff
			State.airTimer = CONFIG.AirGraceAfterJump
			State.isReallyInAir = true
			State.rotationInAir = 0
			State.lastGroundCFrame = RootPart.CFrame

			playAnim("Jump", 0.1, false)

		end

		State.isChargingJump = false
		State.jumpCharge = 0
		if ChargeBar then
			ChargeBar.Size = UDim2.new(0, 0, 1, 0)
			ChargeBar.BackgroundColor3 = Color3.fromRGB(255, 180, 0)
		end
	end
end)

-- ============================================================================
-- MAIN PHYSICS LOOP
-- ============================================================================

RunService.Heartbeat:Connect(function(dt)
	-- Bail if not skiing or no character
	if State.current == "off" then return end
	if not RootPart or not RootPart.Parent then return end
	if not Humanoid or Humanoid.Health <= 0 then return end
	if (State.current == "skiing" or State.current == "airborne") and not Character:FindFirstChild("Skis") and Humanoid.PlatformStand == false then
		unequipSkis()
		return
	end

	-- ── CRASHED STATE: just disable movers and wait ──
	if State.current == "crashed" or State.current == "recovering" then
		if VectorForceInst and VectorForceInst.Enabled then
			VectorForceInst.Enabled = false
		end
		if AlignOrientInst and AlignOrientInst.Enabled then
			AlignOrientInst.Enabled = false
		end
		return
	end

	if tick() - lastForeignAnimStop > 0.25 then
		stopForeignAnimationTracks(0.06)
		lastForeignAnimStop = tick()
	end

	-- ════════════════════════════════════════════════════════
	-- 0. INPUT POLLING
	-- ════════════════════════════════════════════════════════
	local rawSteer = 0
	if UserInputService:IsKeyDown(Enum.KeyCode.A) then rawSteer = rawSteer + 1 end
	if UserInputService:IsKeyDown(Enum.KeyCode.D) then rawSteer = rawSteer - 1 end
	if math.abs(rawSteer) < 0.01 and mobileButtonSteer ~= 0 then
		rawSteer = mobileButtonSteer
	end
	if math.abs(rawSteer) < 0.01 and Humanoid then
		local moveDir = projectOnPlane(Humanoid.MoveDirection, State.smoothNormal)
		if moveDir.Magnitude > 0.01 then
			local steerAxis = safeUnit(projectOnPlane(State.facingCFrame.RightVector, State.smoothNormal), Vector3.xAxis)
			rawSteer = math.clamp(-moveDir.Unit:Dot(steerAxis), -1, 1)
			if math.abs(rawSteer) < 0.12 then
				rawSteer = 0
			end
		end
	end
	State.steer = lerp(State.steer, rawSteer, math.clamp(CONFIG.TurnInputResponse * dt, 0, 1))
	if math.abs(State.steer) < 0.02 then
		State.steer = 0
	end
	if math.abs(rawSteer) > 0.1 then
		State.brakeSlideSign = math.sign(rawSteer)
	end

	local brakingJustStarted = State.braking and (not State.wasBraking)
	if brakingJustStarted then
		if math.abs(rawSteer) > 0.1 then
			State.brakeSlideSign = math.sign(rawSteer)
		elseif math.abs(State.steer) > 0.1 then
			State.brakeSlideSign = math.sign(State.steer)
		elseif State.brakeSlideSign == 0 then
			State.brakeSlideSign = 1
		end
	end
	State.wasBraking = State.braking

	-- Jump charge update
	if State.isChargingJump then
		State.jumpCharge = State.jumpCharge + dt
		local p = math.clamp(State.jumpCharge / CONFIG.JumpChargeTime, 0, 1)
		if ChargeBar then
			ChargeBar.Size = UDim2.new(p, 0, 1, 0)
			ChargeBar.BackgroundColor3 = p >= 1
				and Color3.fromRGB(255, 50, 50)
				or Color3.fromRGB(255, 180, 0)
		end
	end

	-- ════════════════════════════════════════════════════════
	-- 1. TERRAIN SAMPLING (multi-point raycast)
	-- ════════════════════════════════════════════════════════
	local lookDir = Vector3.new(State.facingCFrame.LookVector.X, 0, State.facingCFrame.LookVector.Z)
	if lookDir.Magnitude < 0.01 then lookDir = Vector3.new(0, 0, -1) end
	lookDir = lookDir.Unit
	local rightDir = Vector3.new(-lookDir.Z, 0, lookDir.X)
	local rideHeight = State.rideHeight or CONFIG.TargetRideHeight

	local groundHit, rawNormal, groundDist, hitResult = sampleTerrain(
		RootPart.Position, lookDir, rightDir
	)

	-- Smooth the normal to prevent jitter
	if groundHit then
		State.smoothNormal = lerpVector3(
			State.smoothNormal,
			rawNormal,
			math.clamp(CONFIG.NormalSmoothSpeed * dt, 0, 1)
		)
		if State.smoothNormal.Magnitude > 0.01 then
			State.smoothNormal = State.smoothNormal.Unit
		else
			State.smoothNormal = Vector3.yAxis
		end
	end

	State.groundHit = groundHit
	State.groundHeight = groundDist

	-- ════════════════════════════════════════════════════════
	-- 2. AIR STATE DETECTION (with grace period)
	-- ════════════════════════════════════════════════════════

	-- Update jump cooldown
	if State.justJumped then
		State.jumpCooldown = State.jumpCooldown - dt
		if State.jumpCooldown <= 0 then
			State.justJumped = false
		end
	end
	State.pushAnimTimer = math.max(0, State.pushAnimTimer - dt)

	-- Determine if we're on the ground
	-- Use a wider detection range (2x ride height) so steep terrain transitions
	-- don't trigger false "airborne" states
	local rawOnGround = groundHit
		and groundDist < rideHeight * 2.0  -- Within suspension range (wider!)
		and not State.justJumped                          -- Not in jump cooldown
	if rawOnGround and State.isReallyInAir and groundDist > (rideHeight * 1.2) then
		rawOnGround = false
	end
	if rawOnGround then
		State.groundLostTimer = 0
	else
		State.groundLostTimer = State.groundLostTimer + dt
	end

	local onGround = rawOnGround
	if (not rawOnGround)
		and groundHit
		and (not State.justJumped)
		and groundDist < CONFIG.CrestStickDistance
		and State.groundLostTimer <= CONFIG.CrestStickTime
	then
		onGround = true
	end

	if State.isReallyInAir and groundDist > (rideHeight * 1.2) then
		onGround = false
	end
	State.groundedAlpha = State.groundedAlpha + (((onGround and 1 or 0) - State.groundedAlpha) * math.clamp(12 * dt, 0, 1))

	-- Realistic pole push cycle:
	-- front plant -> one small drive boost -> recover -> next push.
	-- Keep cycle running while W is held so animation does not die on brief airtime.
	if State.pushing then
		local planarSpeed = projectOnPlane(State.velocity, State.smoothNormal).Magnitude
		local cycleDuration = math.max(0.2, tonumber(CONFIG.PushCooldown) or 0.6)
		local impulsePhase = math.clamp(tonumber(CONFIG.PushImpulsePhase) or 0.30, 0.05, 0.95)
		local impulseScale = math.clamp(tonumber(CONFIG.PushImpulseScale) or 0.62, 0.1, 3)

		if not State.pushCyclePrimed then
			State.pushCyclePrimed = true
			State.pushCycleElapsed = 0
			State.pushImpulseFired = false
			State.pushAnimTimer = cycleDuration
		end

		State.pushCycleElapsed = (State.pushCycleElapsed or 0) + dt
		local triggerTime = cycleDuration * impulsePhase
		local canImpulse = onGround and (not State.isReallyInAir) and (planarSpeed < CONFIG.PushMaxSpeed)

		if (not State.pushImpulseFired)
			and State.pushCycleElapsed >= triggerTime
			and canImpulse
		then
			local pushDir = projectOnPlane(State.facingCFrame.LookVector, State.smoothNormal)
			if pushDir.Magnitude > 0.01 then
				pushDir = pushDir.Unit
			else
				pushDir = State.facingCFrame.LookVector
			end

			local impulse = SkiPhysicsModel.GetPushImpulse(CONFIG, planarSpeed) * impulseScale
			State.velocity = State.velocity + pushDir * impulse
			State.lastPushTime = tick()
			State.pushImpulseFired = true
		end

		if State.pushCycleElapsed >= cycleDuration then
			-- Hard reset each stroke so every cycle restarts fully in front.
			State.pushCycleElapsed = 0
			State.pushImpulseFired = false
			State.pushAnimTimer = cycleDuration
		end
	else
		State.pushCyclePrimed = false
		State.pushCycleElapsed = 0
		State.pushImpulseFired = false
	end
	local wasReallyInAir = State.isReallyInAir

	if onGround then
		-- We have ground contact
		if State.isReallyInAir then
			-- We were in the air → landing!
			checkLanding(State.smoothNormal)
		end
		State.airTimer = 0
		State.isReallyInAir = false
	else
		-- No ground contact
		State.airTimer = State.airTimer + dt

		-- Only enter "real air" state after grace period.
		-- Intentional jumps shorten this so flips feel responsive.
		local effectiveAirGrace = State.justJumped and CONFIG.AirGraceAfterJump or CONFIG.AirGraceTime
		if State.airTimer > effectiveAirGrace then
			if not State.isReallyInAir then
				-- Just entered air state
				State.isReallyInAir = true
				State.lastGroundCFrame = RootPart.CFrame
				State.rotationInAir = 0
			end
		end
	end

	-- ════════════════════════════════════════════════════════
	-- 3. CALCULATE FORCES
	-- ════════════════════════════════════════════════════════

	-- We accumulate forces and apply them via VectorForce.
	-- Roblox gravity is already applied by the engine, so we don't add it again.
	-- We only add: suspension, slope acceleration, friction, steering, drag.

	local totalForce = Vector3.zero
	local speed = State.velocity.Magnitude
	local mass = RootPart.AssemblyMass

	if onGround then
		-- ══════════════════════════
		-- GROUNDED PHYSICS
		-- ══════════════════════════
		local normal = State.smoothNormal
		local stopModeThresholdSpeed = (tonumber(CONFIG.StopModeThresholdMPH) or 110) / 0.6818
		local planarGroundSpeed = projectOnPlane(State.velocity, normal).Magnitude
		local highSpeedBrakeMode = State.braking and (planarGroundSpeed >= stopModeThresholdSpeed)
		local sideSlipBrakeAlpha = highSpeedBrakeMode
			and inverseLerp(stopModeThresholdSpeed - 8, stopModeThresholdSpeed + 18, planarGroundSpeed)
			or 0

		-- ── A. SUSPENSION ──
		-- Spring-damper: pushes up when below ride height, lets you fall when above
		local heightError = rideHeight - groundDist
		local verticalVelocity = RootPart.AssemblyLinearVelocity:Dot(normal)

		-- Speed-adaptive stiffness: stiffer at high speed to absorb bumps
		local speedFraction = inverseLerp(0, CONFIG.SpeedForMaxStiffness, speed)
		local currentStiffness = lerp(CONFIG.SpringStiffness, CONFIG.SpringStiffnessAtSpeed, speedFraction)

		-- Spring force = stiffness * error - damping * velocity
		-- This is a critically-damped spring (no bouncing!)
		local springForce = (heightError * currentStiffness) - (verticalVelocity * CONFIG.SpringDamping)

		-- CLAMP: Don't let suspension launch you upward aggressively
		-- This is the key fix for bump launches!
		local maxUpForce = mass * Workspace.Gravity * 3  -- Max 3G upward
		springForce = math.clamp(springForce, -mass * Workspace.Gravity * 0.5, maxUpForce)

		-- Apply suspension in the normal direction (so it works on slopes)
		totalForce = totalForce + normal * springForce

		-- Dampen/limit outward speed along surface normal so crest bumps don't launch us.
		if verticalVelocity > 0 then
			totalForce = totalForce - normal * (verticalVelocity * mass * CONFIG.OutwardNormalDamping)

			if verticalVelocity > CONFIG.MaxOutwardNormalSpeed then
				State.velocity = State.velocity - normal * (verticalVelocity - CONFIG.MaxOutwardNormalSpeed)
			end
		end

		-- ── B. GROUND SNAP / DOWNHILL ADHESION ──
		-- Two systems work together to keep you on the ground:
		-- 1. Ground snap: gentle pull when slightly above ride height
		-- 2. Downhill adhesion: at speed, actively pull toward terrain surface
		--    This is what prevents launching off when transitioning from steep to flat

		-- Ground snap (close to surface)
		if groundDist > rideHeight and groundDist < CONFIG.GroundSnapDistance then
			local snapStrength = inverseLerp(CONFIG.GroundSnapDistance, rideHeight, groundDist)
			totalForce = totalForce - normal * (CONFIG.GroundSnapSpeed * mass * snapStrength)
		end

		-- Downhill adhesion (speed-dependent)
		-- The faster you go, the more we pull you into the terrain
		-- This mimics how real skiers press into the snow at speed
		if speed > 15 then
			local adhesionStrength = inverseLerp(15, 100, speed) * 0.4 -- Up to 0.4G at high speed
			local downIntoTerrain = -normal * mass * Workspace.Gravity * adhesionStrength
			totalForce = totalForce + downIntoTerrain
		end

		-- ── C. SLOPE ACCELERATION ──
		-- Gravity component parallel to the slope surface
		-- This is what makes you accelerate downhill!
		local gravity = Vector3.new(0, -Workspace.Gravity, 0)
		local slopeForce = gravity - (gravity:Dot(normal) * normal)
		local slopeSine = slopeForce.Magnitude / math.max(Workspace.Gravity, 0.001)
		local minSlopeSine = math.sin(math.rad(CONFIG.SlopeMinAngle))
		local fullSlopeSine = math.sin(math.rad(CONFIG.SlopeFullAngle))
		local slopeScale = inverseLerp(minSlopeSine, fullSlopeSine, slopeSine)
		totalForce = totalForce + slopeForce * mass * CONFIG.SlopeGravityMultiplier * slopeScale

		-- ── D. FRICTION ──
		-- Different friction for different states
		local forwardDir = safeUnit(projectOnPlane(State.facingCFrame.LookVector, normal), lookDir)
		local rightSki  = safeUnit(projectOnPlane(State.facingCFrame.RightVector, normal), rightDir)

		if highSpeedBrakeMode then
			local slideSign = State.brakeSlideSign or 1
			if math.abs(rawSteer) > 0.55 then
				slideSign = math.sign(rawSteer)
			end
			if slideSign == 0 then
				slideSign = (State.brakeSlideSign ~= 0) and State.brakeSlideSign or 1
			end
			State.brakeSlideSign = slideSign

			local sideTargetForward = safeUnit(rightSki * slideSign, forwardDir)
			local sideTurnBlend = math.clamp((CONFIG.BrakeSideTurnResponse + (planarGroundSpeed * 0.012)) * dt, 0, 0.16)
			forwardDir = safeUnit(forwardDir:Lerp(sideTargetForward, sideTurnBlend), sideTargetForward)
			rightSki = safeUnit(forwardDir:Cross(normal), rightDir)
			forwardDir = safeUnit(normal:Cross(rightSki), forwardDir)
		end

		local fwdSpeed  = State.velocity:Dot(forwardDir)
		local sideSpeed = State.velocity:Dot(rightSki)

		local glideFriction, sideFriction, edgeAlpha = SkiPhysicsModel.GetFrictionProfile(
			CONFIG,
			speed,
			State.steer,
			State.braking
		)
		if sideSlipBrakeAlpha > 0 then
			sideFriction *= lerp(1, CONFIG.BrakeSideSlipFrictionBoost, sideSlipBrakeAlpha)
			glideFriction *= lerp(1, CONFIG.BrakeSideSlipGlideBoost, sideSlipBrakeAlpha)
		end
		State.slipAmount = math.clamp(math.abs(sideSpeed) / math.max(projectOnPlane(State.velocity, normal).Magnitude, 1), 0, 1)

		-- Apply forward friction
		if speed > 0.5 then
			local fwdFrictionForce = -forwardDir * fwdSpeed * glideFriction * mass
			totalForce = totalForce + fwdFrictionForce
		end

		-- Apply sideways friction (high — prevents sliding sideways)
		local sideFrictionForce = -rightSki * sideSpeed * sideFriction * mass
		totalForce = totalForce + sideFrictionForce

		-- Constant rolling resistance to stop runaway speed buildup on gentle slopes.
		if speed > 0.5 then
			totalForce = totalForce - State.velocity.Unit * (CONFIG.RollingResistance * mass)
		end

		-- Active brake force (S key): strong decel, stronger at high speed.
		if State.braking then
			local planarVelocity = projectOnPlane(State.velocity, normal)
			local planarSpeed = planarVelocity.Magnitude
			if planarSpeed > 0.5 then
				local brakeModeScale = highSpeedBrakeMode and lerp(1.08, CONFIG.BrakeSideSlipDecelBoost, sideSlipBrakeAlpha) or 1
				local brakeAccel = SkiPhysicsModel.GetBrakeDeceleration(CONFIG, planarSpeed, 1) * brakeModeScale
				totalForce = totalForce - planarVelocity.Unit * (brakeAccel * mass)
			end
		end

		-- ── E. AERODYNAMIC DRAG ──
		-- Proportional to v² (quadratic drag)
		if speed > 5 then
			local dragForce = -State.velocity.Unit * CONFIG.DragCoefficient * speed * speed * mass
				* SkiPhysicsModel.GetDragMultiplier(CONFIG, speed, State.braking, edgeAlpha)
			totalForce = totalForce + dragForce
		end

		-- ── F. STEERING / CARVING ──
		State.turnRate = 0
		if math.abs(State.steer) > 0.08 and speed > CONFIG.MinSpeedToTurn then
			local signedTurnRate = SkiPhysicsModel.GetTurnRate(CONFIG, speed, State.steer, Workspace.Gravity)
			State.turnRate = signedTurnRate
			local turnAngle = math.rad(signedTurnRate) * dt * 60

			-- Rotate heading first, then pull velocity toward that heading.
			-- This avoids the "strafe + tiny body turn" look.
			local headingRot = CFrame.fromAxisAngle(normal, turnAngle)
			local headingForward = headingRot * forwardDir
			headingForward = safeUnit(projectOnPlane(headingForward, normal), forwardDir)
			local headingRight = safeUnit(headingForward:Cross(normal), rightDir)
			headingForward = safeUnit(normal:Cross(headingRight), headingForward)

			State.facingCFrame = CFrame.fromMatrix(RootPart.Position, headingRight, normal, -headingForward)

			local planarVelocity = projectOnPlane(State.velocity, normal)
			local planarSpeed = planarVelocity.Magnitude
			if planarSpeed > 0.5 then
				local desiredPlanarVelocity = headingForward * planarSpeed
				local headingError = desiredPlanarVelocity - planarVelocity
				local carveAssistForce = headingError * mass * CONFIG.CarveHeadingForce * math.abs(State.steer)
				totalForce = totalForce + carveAssistForce
			end

			-- Speed penalty from turning (carving is efficient, but not free).
			-- Keep this softer, especially at lower speeds, so flats don't feel like instant brake.
			if speed > 8 then
				local carveIntensity = math.abs(State.steer) * inverseLerp(14, 95, speed)
				local carveLoss = 1.0 - ((1.0 - CONFIG.CarveGrip) * carveIntensity * dt * 0.75)
				State.velocity = State.velocity * math.max(carveLoss, 0.996)
			end
		else
			State.turnRate = State.turnRate * math.max(0, 1 - (8 * dt))
		end

		-- ── G. STOP FRICTION (prevents sliding at very low speed) ──
		local stopHoldForce = SkiPhysicsModel.GetStopHoldForce(
			CONFIG,
			projectOnPlane(State.velocity, normal).Magnitude,
			State.pushing,
			State.braking
		)
		if stopHoldForce > 0 then
			local stopForce = -projectOnPlane(State.velocity, normal) * stopHoldForce * mass
			totalForce = totalForce + stopForce
		end

		-- ── H. ORIENT CHARACTER TO TERRAIN ──
		-- Align character up-vector to ground normal, facing along velocity
		-- CRITICAL: We project velocity onto the slope plane so that vertical
		-- velocity components (from going over bumps) don't pitch the character
		-- nose-down. Only the horizontal movement direction matters for facing.

		-- ANTI-TIP SYSTEM: Check if the ACTUAL physical orientation has been
		-- knocked off by a collision (bump). If so, force-correct it.
		-- This is what prevents the "tips catch a bump → character flips" bug.
		local actualUp = RootPart.CFrame.UpVector
		local desiredUp = normal
		local tipAngle = math.deg(math.acos(math.clamp(actualUp:Dot(desiredUp), -1, 1)))

		if tipAngle > 25 then
			-- Character has been tipped significantly by a collision!
			-- Kill any angular velocity that's continuing the rotation
			RootPart.AssemblyAngularVelocity = RootPart.AssemblyAngularVelocity * 0.3

			-- Also kill any vertical velocity that would keep us bouncing
			if RootPart.AssemblyLinearVelocity.Y > 5 then
				local vel = RootPart.AssemblyLinearVelocity
				RootPart.AssemblyLinearVelocity = Vector3.new(vel.X, vel.Y * 0.3, vel.Z)
			end
		end

		local flatVel = projectOnPlane(State.velocity, normal)
		local headingForward = safeUnit(projectOnPlane(State.facingCFrame.LookVector, normal), lookDir)
		if flatVel.Magnitude > 1.5 then
			if highSpeedBrakeMode and sideSlipBrakeAlpha > 0.05 then
				local sideForward = forwardDir
				local sideRight = sideForward:Cross(normal)
				if sideRight.Magnitude > 0.01 then
					sideRight = sideRight.Unit
					sideForward = normal:Cross(sideRight).Unit
					State.facingCFrame = CFrame.fromMatrix(RootPart.Position, sideRight, normal, -sideForward)
				end
			else
				local targetFwd = flatVel.Unit
				local headingWeight = lerp(0.2, CONFIG.HeadingBlend, math.abs(State.steer))
				local newFwd = safeUnit(lerpVector3(targetFwd, headingForward, headingWeight), headingForward)
				local newRight = newFwd:Cross(normal)
				if newRight.Magnitude > 0.01 then
					newRight = newRight.Unit
					-- Re-derive forward to ensure orthogonality
					newFwd = normal:Cross(newRight).Unit

					-- Apply visual tilt (banking into turns)
					local tiltAngle = State.steer * math.rad(CONFIG.TiltMax) * math.clamp(speed / 60, 0, 1)
					local baseCFrame = CFrame.fromMatrix(RootPart.Position, newRight, normal, -newFwd)
					State.facingCFrame = baseCFrame * CFrame.Angles(0, 0, tiltAngle)
				end
			end
		else
			-- Stopped: just align up to normal, keep current facing direction
			local fwd = projectOnPlane(State.facingCFrame.LookVector, normal)
			if fwd.Magnitude > 0.01 then
				fwd = fwd.Unit
				local right = fwd:Cross(normal)
				if right.Magnitude > 0.01 then
					right = right.Unit
					State.facingCFrame = CFrame.fromMatrix(RootPart.Position, right, normal, -fwd)
				end
			end

			-- Slow pivot turning when stopped
			if math.abs(State.steer) > 0.1 and speed < 5 then
				local pivotRate = math.max(CONFIG.TurnSpeed_Uturn * 40, 80)
				local pivotAngle = State.steer * math.rad(pivotRate) * dt
				local pivotForward = CFrame.fromAxisAngle(normal, pivotAngle) * headingForward
				pivotForward = safeUnit(projectOnPlane(pivotForward, normal), headingForward)
				local pivotRight = safeUnit(pivotForward:Cross(normal), rightDir)
				pivotForward = safeUnit(normal:Cross(pivotRight), pivotForward)
				State.facingCFrame = CFrame.fromMatrix(RootPart.Position, pivotRight, normal, -pivotForward)
			end
		end

	else
		State.turnRate = State.turnRate * math.max(0, 1 - (6 * dt))
		State.slipAmount = 0
		-- ══════════════════════════
		-- AIRBORNE PHYSICS
		-- ══════════════════════════
		-- Roblox gravity handles the falling. We just add air drag and rotation control.

		-- Air drag (slight)
		if speed > 5 then
			local dragMult = State.isReallyInAir and CONFIG.AirDragMultiplier or 0.55
			local airDragForce = -State.velocity.Unit * CONFIG.DragCoefficient * dragMult * speed * speed * mass
			totalForce = totalForce + airDragForce
		end

		-- During micro-air over crest bumps, pull back toward surface and damp lift-off velocity.
		if (not State.isReallyInAir)
			and groundHit
			and (not State.justJumped)
			and groundDist < CONFIG.CrestStickDistance
		then
			local nearGround = inverseLerp(CONFIG.CrestStickDistance, rideHeight, groundDist)
			local adhesion = mass * Workspace.Gravity * CONFIG.CrestAdhesionStrength * nearGround
			totalForce = totalForce - State.smoothNormal * adhesion

			local outward = State.velocity:Dot(State.smoothNormal)
			if outward > 0 then
				local damp = math.clamp(CONFIG.OutwardNormalDamping * dt, 0, 1)
				State.velocity = State.velocity - State.smoothNormal * outward * damp
			end
		end

		-- ═══════════════════════════════════════════════════════
		-- CRITICAL FIX: ORIENTATION DURING AIR
		-- ═══════════════════════════════════════════════════════
		-- The old code aligned facing to velocity direction even in air.
		-- When falling, velocity points DOWN → character pitches forward
		-- → ski tips catch ground first → FLIP.
		--
		-- FIX: During grace period (micro-bumps), LOCK the last grounded
		-- orientation. During real air, keep the character level but allow
		-- player-controlled rotation for tricks.

		if not State.isReallyInAir then
			-- ── GRACE PERIOD (micro-bump) ──
			-- Hold the last good grounded orientation. Don't rotate at all.
			-- Don't align to velocity. Don't do anything that would pitch forward.
			-- The character just glides with the same pose it had on the ground.

			-- CRITICAL: Kill any angular velocity imparted by bump collisions!
			-- This is what prevents "bump collision → spin" from cascading
			if RootPart then
				RootPart.AssemblyAngularVelocity = RootPart.AssemblyAngularVelocity * 0.1
			end

			-- Keep position updated on the CFrame
			State.facingCFrame = CFrame.new(RootPart.Position) * 
				(State.facingCFrame - State.facingCFrame.Position)
		else
			-- ── REAL AIR (past grace period) ──
			-- Player has full rotation control for tricks.
			-- Much faster rotation speed for satisfying flips!

			local pitch = 0
			local yaw = State.steer

			-- W/S for pitch in air (backflip/frontflip)
			if UserInputService:IsKeyDown(Enum.KeyCode.W) then pitch = -1 end
			if UserInputService:IsKeyDown(Enum.KeyCode.S) then pitch = 1 end

			-- Reduce control slightly when falling very fast (but keep it fun)
			local fallSpeed = math.max(-RootPart.AssemblyLinearVelocity.Y, 0)
			local controlMult = 1.0
			if fallSpeed > 100 then
				controlMult = 0.82
			elseif fallSpeed > 60 then
				controlMult = 0.92
			end
			local speedControlScale = lerp(1.0, 0.90, inverseLerp(40, 120, speed))
			controlMult = controlMult * speedControlScale

			local pitchSpeed = CONFIG.FlipPitchSpeed * dt * controlMult
			local yawSpeed = CONFIG.FlipYawSpeed * dt * controlMult

			-- Apply player rotation
			if math.abs(pitch) > 0.1 or math.abs(yaw) > 0.1 then
				State.facingCFrame = State.facingCFrame * CFrame.Angles(
					pitch * pitchSpeed,
					yaw * yawSpeed,
					0
				)
			end

			-- Natural gravity torque: gently pull toward upright when NOT inputting
			-- This prevents you from being stuck upside-down if you let go
			if math.abs(pitch) < 0.1 and math.abs(yaw) < 0.1 then
				local currentUp = State.facingCFrame.UpVector
				local uprightness = currentUp:Dot(Vector3.yAxis)

				-- Only correct when significantly off-axis, and gently
				if uprightness < 0.7 then
					local correctionStrength = (1 - uprightness) * 0.15 * dt
					local flatFwd = Vector3.new(
						State.facingCFrame.LookVector.X, 0,
						State.facingCFrame.LookVector.Z
					)
					if flatFwd.Magnitude > 0.01 then
						local uprightCF = CFrame.lookAt(
							State.facingCFrame.Position,
							State.facingCFrame.Position + flatFwd
						)
						State.facingCFrame = State.facingCFrame:Lerp(uprightCF, correctionStrength)
					end
				end
			end

			-- Track rotation for trick scoring
			State.rotationInAir = State.rotationInAir + math.deg((math.abs(yaw) * yawSpeed) + (math.abs(pitch) * pitchSpeed))
		end
	end

	-- ════════════════════════════════════════════════════════
	-- 4. INTEGRATE VELOCITY
	-- ════════════════════════════════════════════════════════

	-- Apply accumulated forces to our tracked velocity
	-- We track velocity ourselves so we can do proper ski physics
	-- but we let Roblox handle the actual position via VectorForce
	State.velocity = State.velocity + (totalForce / mass) * dt

	-- Terminal velocity clamp
	if State.velocity.Magnitude > CONFIG.TerminalVelocity then
		State.velocity = State.velocity.Unit * CONFIG.TerminalVelocity
	end

	-- ════════════════════════════════════════════════════════
	-- 5. APPLY TO CHARACTER
	-- ════════════════════════════════════════════════════════

	-- The VectorForce approach:
	-- We compute the DIFFERENCE between our desired velocity and the current
	-- physical velocity, then apply a force to correct it.
	-- This is much more stable than setting velocity directly.

	local currentPhysVelocity = RootPart.AssemblyLinearVelocity
	local velocityError = State.velocity - currentPhysVelocity
	if not onGround then
		-- In air, never correct vertical velocity. Let gravity control hangtime.
		velocityError = Vector3.new(velocityError.X, 0, velocityError.Z)
	end

	-- PD controller for velocity tracking
	-- Higher gain = more responsive (our ski physics actually take effect)
	local velocityGain = onGround and 25 or 6
	local correctionForce = velocityError * mass * velocityGain

	-- Clamp correction force to prevent extreme impulses
	local maxCorrectionMagnitude = mass * (onGround and 800 or 220)
	if correctionForce.Magnitude > maxCorrectionMagnitude then
		correctionForce = correctionForce.Unit * maxCorrectionMagnitude
	end

	VectorForceInst.Force = totalForce + correctionForce

	-- Keep our tracked velocity in sync with physics (prevents drift)
	-- IMPORTANT: Only blend back a TINY amount. The old 0.15 was too high
	-- and was UNDOING our turn steering every frame at high speed.
	-- 0.03 = 3% blend → our simulation controls, physics just adds collision response
	local syncBlend = onGround and 0.03 or 0.18
	State.velocity = lerpVector3(State.velocity, currentPhysVelocity, syncBlend)

	-- Orientation
	AlignOrientInst.CFrame = State.facingCFrame

	-- ════════════════════════════════════════════════════════
	-- 6. VISUAL UPDATES
	-- ════════════════════════════════════════════════════════

	local planarVelocity = projectOnPlane(State.velocity, State.smoothNormal)
	local planarSpeed = planarVelocity.Magnitude
	local stopModeThresholdSpeed = (tonumber(CONFIG.StopModeThresholdMPH) or 110) / 0.6818
	local highSpeedSlideAlpha = 0
	if State.braking and onGround then
		highSpeedSlideAlpha = inverseLerp(stopModeThresholdSpeed - 8, stopModeThresholdSpeed + 18, planarSpeed)
	end
	local lowSpeedBrakeAlpha = State.braking and (1 - highSpeedSlideAlpha) or 0
	local displayMotionSpeed = onGround and planarSpeed or speed
	if onGround and displayMotionSpeed < 2.2 and (not State.pushing) and (not State.braking) then
		displayMotionSpeed = 0
	end
	local displaySpeed, _ = getDisplaySpeed(displayMotionSpeed)
	local mph = math.floor(displayMotionSpeed * 0.6818)

	-- Speed display
	if SpeedLabel then
		SpeedLabel.Text = tostring(displaySpeed)
	end

	-- State debug display
	local stateLabel = ScreenGui and ScreenGui:FindFirstChild("StateLabel")
	local wantsBootWalk = onGround
		and planarSpeed < 16
		and not State.braking
		and not State.isReallyInAir
		and math.abs(State.steer) < 0.55
	local pushCycleDuration = math.max(0.2, tonumber(CONFIG.PushCooldown) or 0.6)

	local proceduralState = SkiStateSchema.Build({
		current = State.current,
		velocity = State.velocity,
		normal = State.smoothNormal,
		groundedAlpha = State.groundedAlpha,
		grounded = onGround,
		airborne = State.isReallyInAir,
		steer = State.steer,
		turnRate = State.turnRate,
		slipAmount = State.slipAmount,
		brakeAlpha = State.braking and 1 or 0,
		lowSpeedBrakeAlpha = lowSpeedBrakeAlpha,
		highSpeedSlideAlpha = highSpeedSlideAlpha,
		stopSlideSign = State.brakeSlideSign or 1,
		pushAlpha = math.clamp(State.pushAnimTimer / pushCycleDuration, 0, 1),
		pushing = State.pushing,
		pushCyclePhase = math.clamp((State.pushCycleElapsed or 0) / pushCycleDuration, 0, 1),
		pushCycleDuration = pushCycleDuration,
		stopAlpha = 1 - inverseLerp(0.75, 7, planarSpeed),
		forward = State.facingCFrame.LookVector,
		planarVelocity = planarVelocity,
		wantsBootWalk = wantsBootWalk,
	})
	if stateLabel then
		local airStr = State.isReallyInAir and "AIR" or (State.airTimer > 0 and "grace" or "GROUND")
		stateLabel.Text = string.format("%s H:%.1f %s", proceduralState.debugLabel, State.groundHeight, airStr)
	end

	-- Dynamic FOV
	local targetFOV = lerp(CONFIG.FOV_Base, CONFIG.FOV_Max, inverseLerp(0, CONFIG.FOV_SpeedScale, speed))
	Camera.FieldOfView = lerp(Camera.FieldOfView, targetFOV, 5 * dt)

	-- Camera shake (only grounded at high speed)
	if onGround and mph > 35 then
		local shakeIntensity = CONFIG.CameraShake * inverseLerp(35, 80, mph)
		local shake = (math.random() - 0.5) * shakeIntensity
		Camera.CFrame = Camera.CFrame * CFrame.Angles(0, 0, math.rad(shake))
	end

	-- Audio
	if Sounds.Wind then
		Sounds.Wind.Volume = math.clamp(speed / 80, 0, 1)
		Sounds.Wind.PlaybackSpeed = 0.5 + (speed / 120)
	end

	if Sounds.Carve then
		local shouldCarve = onGround and (math.abs(State.steer) > 0.15 or State.braking)
		local targetVol = shouldCarve and math.clamp(speed / 25, 0, 1.5) or 0
		Sounds.Carve.Volume = lerp(Sounds.Carve.Volume, targetVol, 8 * dt)
		Sounds.Carve.PlaybackSpeed = 0.7 + (speed / 100)
	end

	-- Particles
	local densityScale = GraphicsProfile.GetParticleScale(Player) * GraphicsProfile.GetParticleDensityScale(Player)
	local adaptiveScale = 1
	if GraphicsProfile.IsAdaptiveParticlesEnabled(Player) then
		local frameFPS = (dt > 0) and (1 / dt) or 60
		if frameFPS < 58 then
			adaptiveScale = frameFPS <= 26 and 0.35 or math.clamp((frameFPS - 26) / 32, 0.35, 1)
		end
	end
	if MistController then
		MistController:Update(proceduralState, dt, densityScale, adaptiveScale)
	end
	if ProceduralAnimatorInst then
		ProceduralAnimatorInst:Step(dt, proceduralState)
	end

	-- ════════════════════════════════════════════════════════
	-- 7. ANIMATION UPDATES
	-- ════════════════════════════════════════════════════════
	updateFallbackAnimations(proceduralState)
end)

-- ============================================================================
-- DONE
-- ============================================================================
