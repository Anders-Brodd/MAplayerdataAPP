--[[
	snowcatclient.lua — Prinoth Bison (Client) — V3 FIXES
	──────────────────────────────────────────────────────
	FIXES V3:
	1. Ground offset computed from TRACK parts only (not blade/tiller extremes)
	2. Wheel spin uses per-wheel axle detection from model orientation
	3. Mobile touch controls for all functions
	4. Server saves/restores snowcat position above terrain on rejoin
	5. Smoother ground follow with proper spring-damper

	Hold SPACE (1s) to dismount. Free orbit camera.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local ContextActionService = game:GetService("ContextActionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local LocalPlayer = Players.LocalPlayer
local Camera = workspace.CurrentCamera
local GraphicsProfile = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("GraphicsProfile"))

-- Detect mobile/touch
local isMobile = UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled

----------------------------------------------------------------
-- REMOTES
----------------------------------------------------------------
local BisonEvents = ReplicatedStorage:WaitForChild("BisonEvents", 10)
if not BisonEvents then warn("BisonEvents not found!"); return end
local CFrameUpdate = BisonEvents:WaitForChild("BisonCFrame")
local MountEvent   = BisonEvents:WaitForChild("BisonMount")
local DismountEvent = BisonEvents:WaitForChild("BisonDismount")
local GroomEvent   = BisonEvents:WaitForChild("BisonGroom")
local ProgressEvent = BisonEvents:WaitForChild("GroomProgress")

----------------------------------------------------------------
-- STATE
----------------------------------------------------------------
local isDriving = false
local activeBison = nil
local bisonFrame = nil

local velocity = 0
local angularVel = 0
local bodyYaw = 0
local bodyPos = Vector3.zero
local smoothPitch = 0
local smoothRoll = 0

-- Height follower state (rate-limited, no spring)
local prevTargetY = nil  -- previous frame's target Y for rate limiting

-- Ground offset: distance from pivot to where tracks contact ground
local groundOffset = 0

-- Input
local inputW, inputS, inputA, inputD = false, false, false, false
local inputBrake = false
local spaceHoldTime = 0

-- Track/wheel spin state
local trackWheels = {} -- {model, localCF, radius, isLeftSide}
local trackCogs = {}  -- {model, localCF, radius, isLeftSide}
local wheelSpinAngle = 0 -- accumulated rotation

-- Attachment state
local bladeHeight = 0
local bladeTilt = 0
local bladeWingsOpen = false
local tillerHeight = 0
local tillerSpinning = false
local tillerSpinAngle = 0
local tillerWingsDown = false
local tillerWingAngle = 0
local winchLength = 0
local winchAutoTension = false

-- Attachment parts
local bladeParts = {}
local tillerParts = {}
local winchParts = {}
local suspWheelsL = {}
local suspWheelsR = {}
local attachOriginalCFs = {}
local tillerSpinSet = {}
local tillerLeftWingSet = {}
local tillerRightWingSet = {}

-- Audio
local sndEngine = nil
local sndReverse = nil
local sndHydraulic = nil
local prevBladeDir = 0
local prevTillerDir = 0

-- Particle FX
local tillerParticles = nil
local bladeParticles = nil
local tillerAnchorPart = nil
local bladeAnchorPart = nil
local paintCenterPart = nil
local lastClientGroomFire = 0
local lastGroomSampleCF = nil
local lastGroomSampleSize = nil
local hudUpdateAccumulator = 0
local audioUpdateAccumulator = 0
local particleUpdateAccumulator = 0
local HUD_UPDATE_INTERVAL = 0.1
local AUDIO_UPDATE_INTERVAL = 0.1
local PARTICLE_UPDATE_INTERVAL = 0.12
local GROOM_FIRE_INTERVAL = 0.3
local GROOM_MIN_POSITION_DELTA = 3
local GROOM_MIN_LOOK_DELTA = 0.02

local GROUND_SAMPLE_OFFSETS = {
	Vector3.new(-7, 0, -12), Vector3.new(7, 0, -12),
	Vector3.new(-7, 0, -6),  Vector3.new(7, 0, -6),
	Vector3.new(-7, 0, 0),   Vector3.new(7, 0, 0),
	Vector3.new(-7, 0, 6),   Vector3.new(7, 0, 6),
	Vector3.new(-7, 0, 12),  Vector3.new(7, 0, 12),
}
local GroundHitBuffer = table.create(#GROUND_SAMPLE_OFFSETS)
local GroundValueBuffer = table.create(#GROUND_SAMPLE_OFFSETS)

-- Attachment constants
local ATTACH_SPEED = 2.0
local BLADE_MAX_RAISE = 6
local BLADE_MAX_LOWER = 3
local BLADE_MAX_TILT = 0.3
local TILLER_MAX_RAISE = 5
local TILLER_MAX_LOWER = 2
local TILLER_SPIN_SPEED = 4
local WINCH_MAX_LENGTH = 40

----------------------------------------------------------------
-- TUNING
----------------------------------------------------------------
local MODEL_VISUAL_OFFSET = -math.pi / 2

local GEARS = {
	{name = "F1", maxSpd = 6,  accel = 35},
	{name = "F2", maxSpd = 12, accel = 25},
	{name = "F3", maxSpd = 20, accel = 18},
}
local REVERSE_GEARS = {
	{name = "R1", maxSpd = 5,  accel = 25},
	{name = "R2", maxSpd = 10, accel = 15},
}
local currentGear = 2
local currentRevGear = 1

local MAX_SPEED    = 20
local MAX_REVERSE  = 10
local BRAKE_FORCE  = 40
local COAST_DRAG   = 8

-- Turning: tracked vehicle differential steering
local MAX_TURN     = 1.4
local TURN_ACCEL   = 4.0
local TURN_DRAG    = 5.0

-- Ground follow: rate-limited direct follower (no spring, no bounce)
-- A real snowcat has very long tracks (24+ feet). It barely pitches
-- over bumps because the tracks span the bump. Extremely tight limits.
local MAX_HEIGHT_UP_RATE   = 8
local MAX_HEIGHT_DOWN_RATE = 12
local PITCH_SMOOTH    = 1.5      -- very very slow pitch (takes ~0.7s to settle)
local ROLL_SMOOTH     = 1.5
local SLOPE_GRAVITY   = 8

----------------------------------------------------------------
-- RAYCAST
----------------------------------------------------------------
local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude
rayParams.FilterDescendantsInstances = {}

----------------------------------------------------------------
-- MOBILE INPUT STATE (must be declared BEFORE bindDrivingInputs)
----------------------------------------------------------------
local mobileInputBladeUp = false
local mobileInputBladeDown = false
local mobileInputTiltL = false
local mobileInputTiltR = false
local mobileInputTillerUp = false
local mobileInputTillerDown = false

----------------------------------------------------------------
-- INPUT: ContextActionService (sinks keys so other scripts don't receive them)
----------------------------------------------------------------
local BISON_ACTION_NAMES = {
	"BisonForward", "BisonReverse", "BisonLeft", "BisonRight",
	"BisonBrake", "BisonToggleSpin", "BisonToggleWings",
	"BisonBladeUp", "BisonBladeDown", "BisonTiltL", "BisonTiltR",
	"BisonTillerUp", "BisonTillerDown",
}

local function bindDrivingInputs()
	-- Movement (hold)
	ContextActionService:BindAction("BisonForward", function(_, state)
		inputW = (state == Enum.UserInputState.Begin)
		return Enum.ContextActionResult.Sink
	end, false, Enum.KeyCode.W)

	ContextActionService:BindAction("BisonReverse", function(_, state)
		inputS = (state == Enum.UserInputState.Begin)
		return Enum.ContextActionResult.Sink
	end, false, Enum.KeyCode.S)

	ContextActionService:BindAction("BisonLeft", function(_, state)
		inputA = (state == Enum.UserInputState.Begin)
		return Enum.ContextActionResult.Sink
	end, false, Enum.KeyCode.A)

	ContextActionService:BindAction("BisonRight", function(_, state)
		inputD = (state == Enum.UserInputState.Begin)
		return Enum.ContextActionResult.Sink
	end, false, Enum.KeyCode.D)

	ContextActionService:BindAction("BisonBrake", function(_, state)
		inputBrake = (state == Enum.UserInputState.Begin)
		if state == Enum.UserInputState.End then spaceHoldTime = 0 end
		return Enum.ContextActionResult.Sink
	end, false, Enum.KeyCode.Space)

	-- Toggles (press only)
	ContextActionService:BindAction("BisonToggleSpin", function(_, state)
		if state == Enum.UserInputState.Begin then
			tillerSpinning = not tillerSpinning
		end
		return Enum.ContextActionResult.Sink
	end, false, Enum.KeyCode.T)

	ContextActionService:BindAction("BisonToggleWings", function(_, state)
		if state == Enum.UserInputState.Begin then
			tillerWingsDown = not tillerWingsDown
		end
		return Enum.ContextActionResult.Sink
	end, false, Enum.KeyCode.V)

	-- Blade/Tiller (hold) - Q, E, Z, X, R, F all sunk
	ContextActionService:BindAction("BisonBladeUp", function(_, state)
		mobileInputBladeUp = (state == Enum.UserInputState.Begin)
		return Enum.ContextActionResult.Sink
	end, false, Enum.KeyCode.Q)

	ContextActionService:BindAction("BisonBladeDown", function(_, state)
		mobileInputBladeDown = (state == Enum.UserInputState.Begin)
		return Enum.ContextActionResult.Sink
	end, false, Enum.KeyCode.E)

	ContextActionService:BindAction("BisonTiltL", function(_, state)
		mobileInputTiltL = (state == Enum.UserInputState.Begin)
		return Enum.ContextActionResult.Sink
	end, false, Enum.KeyCode.Z)

	ContextActionService:BindAction("BisonTiltR", function(_, state)
		mobileInputTiltR = (state == Enum.UserInputState.Begin)
		return Enum.ContextActionResult.Sink
	end, false, Enum.KeyCode.X)

	ContextActionService:BindAction("BisonTillerUp", function(_, state)
		mobileInputTillerUp = (state == Enum.UserInputState.Begin)
		return Enum.ContextActionResult.Sink
	end, false, Enum.KeyCode.R)

	ContextActionService:BindAction("BisonTillerDown", function(_, state)
		mobileInputTillerDown = (state == Enum.UserInputState.Begin)
		return Enum.ContextActionResult.Sink
	end, false, Enum.KeyCode.F)
end

local function unbindDrivingInputs()
	for _, name in ipairs(BISON_ACTION_NAMES) do
		ContextActionService:UnbindAction(name)
	end
	-- Reset all inputs
	inputW, inputS, inputA, inputD, inputBrake = false, false, false, false, false
	mobileInputBladeUp = false; mobileInputBladeDown = false
	mobileInputTiltL = false; mobileInputTiltR = false
	mobileInputTillerUp = false; mobileInputTillerDown = false
end

-- (mobileInput vars declared above, before bindDrivingInputs)

----------------------------------------------------------------
-- HUD + MOBILE UI
----------------------------------------------------------------
local hudGui = nil
local hudRefs = {}
local groomingFadeTimer = 0

local HUD_COLORS = {
	bg      = Color3.fromRGB(10, 10, 12),
	panel   = Color3.fromRGB(20, 20, 25),
	amber   = Color3.fromRGB(255, 165, 0),
	green   = Color3.fromRGB(40, 200, 60),
	red     = Color3.fromRGB(200, 40, 40),
	text    = Color3.fromRGB(200, 200, 190),
	dim     = Color3.fromRGB(80, 80, 75),
	barBg   = Color3.fromRGB(30, 30, 35),
}

local function makeFrame(props)
	local f = Instance.new("Frame")
	f.BackgroundColor3 = props.Color or HUD_COLORS.panel
	f.BackgroundTransparency = props.Trans or 0
	f.BorderSizePixel = 0
	f.Size = props.Size or UDim2.new(1, 0, 1, 0)
	f.Position = props.Pos or UDim2.new(0, 0, 0, 0)
	f.AnchorPoint = props.Anchor or Vector2.new(0, 0)
	if props.Corner then
		local c = Instance.new("UICorner")
		c.CornerRadius = UDim.new(0, props.Corner)
		c.Parent = f
	end
	f.Parent = props.Parent
	return f
end

local function makeLabel(props)
	local t = Instance.new("TextLabel")
	t.BackgroundTransparency = 1
	t.Size = props.Size or UDim2.new(1, 0, 1, 0)
	t.Position = props.Pos or UDim2.new(0, 0, 0, 0)
	t.AnchorPoint = props.Anchor or Vector2.new(0, 0)
	t.Font = props.Font or Enum.Font.Code
	t.TextColor3 = props.Color or HUD_COLORS.text
	t.TextSize = props.TextSize or 12
	t.Text = props.Text or ""
	t.TextXAlignment = props.XAlign or Enum.TextXAlignment.Left
	t.Parent = props.Parent
	return t
end

-- Mobile touch button helper
local function makeTouchButton(props)
	local btn = Instance.new("TextButton")
	btn.Name = props.Name or "Btn"
	btn.Size = props.Size or UDim2.new(0, 60, 0, 60)
	btn.Position = props.Pos or UDim2.new(0, 0, 0, 0)
	btn.AnchorPoint = props.Anchor or Vector2.new(0, 0)
	btn.BackgroundColor3 = props.Color or Color3.fromRGB(30, 30, 35)
	btn.BackgroundTransparency = props.Trans or 0.3
	btn.BorderSizePixel = 0
	btn.Text = props.Text or ""
	btn.TextColor3 = props.TextColor or HUD_COLORS.amber
	btn.TextSize = props.TextSize or 14
	btn.Font = props.Font or Enum.Font.GothamBold
	btn.AutoButtonColor = true
	btn.Parent = props.Parent
	if props.Corner then
		local c = Instance.new("UICorner")
		c.CornerRadius = UDim.new(0, props.Corner)
		c.Parent = btn
	end
	local stroke = Instance.new("UIStroke")
	stroke.Color = props.StrokeColor or HUD_COLORS.amber
	stroke.Transparency = 0.5
	stroke.Thickness = 1
	stroke.Parent = btn
	return btn
end

local function bindGuiButton(btn, callback)
	if not (btn and callback) then return end
	local firedAt = 0
	local function fire()
		local now = os.clock()
		if now - firedAt < 0.12 then return end
		firedAt = now
		callback()
	end
	btn.Activated:Connect(fire)
	btn.InputBegan:Connect(function(input)
		local inputType = input.UserInputType
		if inputType == Enum.UserInputType.Touch or inputType == Enum.UserInputType.MouseButton1 then
			fire()
		end
	end)
end

-- Wire a touch button to set a boolean true on press, false on release
local function wireHoldButton(btn, setter)
	btn.TouchLongPress:Connect(function() end) -- prevent context menu
	btn.InputBegan:Connect(function(input)
		local inputType = input.UserInputType
		if inputType == Enum.UserInputType.Touch or inputType == Enum.UserInputType.MouseButton1 then
			setter(true)
		end
	end)
	btn.InputEnded:Connect(function(input)
		local inputType = input.UserInputType
		if inputType == Enum.UserInputType.Touch or inputType == Enum.UserInputType.MouseButton1 then
			setter(false)
		end
	end)
	btn.MouseLeave:Connect(function()
		setter(false)
	end)
end

-- Wire a touch button as a toggle
local function wireToggleButton(btn, getter, setter, onLabel, offLabel)
	bindGuiButton(btn, function()
		setter(not getter())
		btn.Text = getter() and onLabel or offLabel
		btn.TextColor3 = getter() and HUD_COLORS.green or HUD_COLORS.dim
	end)
end

local mobileGui = nil

local function createMobileControls(parent)
	if not isMobile then return end
	if mobileGui then mobileGui:Destroy() end

	local gui = Instance.new("ScreenGui")
	gui.Name = "BisonMobile"
	gui.ResetOnSpawn = false
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.Parent = LocalPlayer.PlayerGui
	mobileGui = gui

	-- === LEFT SIDE: Movement (WASD equivalent) ===
	local moveFrame = makeFrame({
		Parent = gui,
		Size = UDim2.new(0, 180, 0, 180),
		Pos = UDim2.new(0, 15, 1, -30),
		Anchor = Vector2.new(0, 1),
		Color = HUD_COLORS.bg,
		Trans = 0.6,
		Corner = 8,
	})

	-- W (forward)
	local btnW = makeTouchButton({
		Parent = moveFrame, Name = "W",
		Size = UDim2.new(0, 56, 0, 56),
		Pos = UDim2.new(0.5, 0, 0, 4),
		Anchor = Vector2.new(0.5, 0),
		Text = "▲", TextSize = 22, Corner = 8,
	})
	wireHoldButton(btnW, function(v) inputW = v end)

	-- S (reverse)
	local btnS = makeTouchButton({
		Parent = moveFrame, Name = "S",
		Size = UDim2.new(0, 56, 0, 56),
		Pos = UDim2.new(0.5, 0, 1, -4),
		Anchor = Vector2.new(0.5, 1),
		Text = "▼", TextSize = 22, Corner = 8,
	})
	wireHoldButton(btnS, function(v) inputS = v end)

	-- A (left)
	local btnA = makeTouchButton({
		Parent = moveFrame, Name = "A",
		Size = UDim2.new(0, 56, 0, 56),
		Pos = UDim2.new(0, 4, 0.5, 0),
		Anchor = Vector2.new(0, 0.5),
		Text = "◀", TextSize = 22, Corner = 8,
	})
	wireHoldButton(btnA, function(v) inputA = v end)

	-- D (right)
	local btnD = makeTouchButton({
		Parent = moveFrame, Name = "D",
		Size = UDim2.new(0, 56, 0, 56),
		Pos = UDim2.new(1, -4, 0.5, 0),
		Anchor = Vector2.new(1, 0.5),
		Text = "▶", TextSize = 22, Corner = 8,
	})
	wireHoldButton(btnD, function(v) inputD = v end)

	-- Brake (center of dpad)
	local btnBrake = makeTouchButton({
		Parent = moveFrame, Name = "Brake",
		Size = UDim2.new(0, 50, 0, 50),
		Pos = UDim2.new(0.5, 0, 0.5, 0),
		Anchor = Vector2.new(0.5, 0.5),
		Text = "BRK", TextSize = 11, Corner = 25,
		Color = Color3.fromRGB(60, 20, 20),
		StrokeColor = HUD_COLORS.red,
		TextColor = HUD_COLORS.red,
	})
	wireHoldButton(btnBrake, function(v) inputBrake = v end)

	-- === RIGHT SIDE: Attachment controls ===
	local attachFrame = makeFrame({
		Parent = gui,
		Size = UDim2.new(0, 200, 0, 260),
		Pos = UDim2.new(1, -15, 1, -30),
		Anchor = Vector2.new(1, 1),
		Color = HUD_COLORS.bg,
		Trans = 0.6,
		Corner = 8,
	})
	local aPad = Instance.new("UIPadding")
	aPad.PaddingLeft = UDim.new(0, 6)
	aPad.PaddingRight = UDim.new(0, 6)
	aPad.PaddingTop = UDim.new(0, 6)
	aPad.PaddingBottom = UDim.new(0, 6)
	aPad.Parent = attachFrame

	-- Row labels + buttons
	local rowH = 44
	local btnW2 = 55

	-- BLADE UP / DOWN
	makeLabel({Parent = attachFrame, Size = UDim2.new(0, 50, 0, rowH), Pos = UDim2.new(0, 0, 0, 0), Text = "BLD", TextSize = 11, Color = HUD_COLORS.amber, Font = Enum.Font.GothamBold})
	local bUp = makeTouchButton({Parent = attachFrame, Size = UDim2.new(0, btnW2, 0, 36), Pos = UDim2.new(0, 52, 0, 4), Text = "▲ UP", TextSize = 10, Corner = 6})
	wireHoldButton(bUp, function(v) mobileInputBladeUp = v end)
	local bDn = makeTouchButton({Parent = attachFrame, Size = UDim2.new(0, btnW2, 0, 36), Pos = UDim2.new(0, 112, 0, 4), Text = "▼ DN", TextSize = 10, Corner = 6})
	wireHoldButton(bDn, function(v) mobileInputBladeDown = v end)

	-- BLADE TILT
	makeLabel({Parent = attachFrame, Size = UDim2.new(0, 50, 0, rowH), Pos = UDim2.new(0, 0, 0, rowH), Text = "TLT", TextSize = 11, Color = HUD_COLORS.amber, Font = Enum.Font.GothamBold})
	local tL = makeTouchButton({Parent = attachFrame, Size = UDim2.new(0, btnW2, 0, 36), Pos = UDim2.new(0, 52, 0, rowH + 4), Text = "◀ L", TextSize = 10, Corner = 6})
	wireHoldButton(tL, function(v) mobileInputTiltL = v end)
	local tR = makeTouchButton({Parent = attachFrame, Size = UDim2.new(0, btnW2, 0, 36), Pos = UDim2.new(0, 112, 0, rowH + 4), Text = "R ▶", TextSize = 10, Corner = 6})
	wireHoldButton(tR, function(v) mobileInputTiltR = v end)

	-- TILLER UP / DOWN
	makeLabel({Parent = attachFrame, Size = UDim2.new(0, 50, 0, rowH), Pos = UDim2.new(0, 0, 0, rowH*2), Text = "TLR", TextSize = 11, Color = HUD_COLORS.amber, Font = Enum.Font.GothamBold})
	local tlUp = makeTouchButton({Parent = attachFrame, Size = UDim2.new(0, btnW2, 0, 36), Pos = UDim2.new(0, 52, 0, rowH*2 + 4), Text = "▲ UP", TextSize = 10, Corner = 6})
	wireHoldButton(tlUp, function(v) mobileInputTillerUp = v end)
	local tlDn = makeTouchButton({Parent = attachFrame, Size = UDim2.new(0, btnW2, 0, 36), Pos = UDim2.new(0, 112, 0, rowH*2 + 4), Text = "▼ DN", TextSize = 10, Corner = 6})
	wireHoldButton(tlDn, function(v) mobileInputTillerDown = v end)

	-- TOGGLES ROW: Spin, Wings, Exit
	local toggleY = rowH * 3 + 8
	local btnSpin = makeTouchButton({Parent = attachFrame, Size = UDim2.new(0, 55, 0, 36), Pos = UDim2.new(0, 0, 0, toggleY), Text = "SPIN", TextSize = 10, Corner = 6})
	wireToggleButton(btnSpin,
		function() return tillerSpinning end,
		function(v) tillerSpinning = v end,
		"SPIN", "SPIN"
	)

	local btnWings = makeTouchButton({Parent = attachFrame, Size = UDim2.new(0, 55, 0, 36), Pos = UDim2.new(0, 60, 0, toggleY), Text = "WING", TextSize = 10, Corner = 6})
	wireToggleButton(btnWings,
		function() return tillerWingsDown end,
		function(v) tillerWingsDown = v end,
		"WING", "WING"
	)

	local btnExit = makeTouchButton({
		Parent = attachFrame,
		Size = UDim2.new(0, 60, 0, 36),
		Pos = UDim2.new(0, 120, 0, toggleY),
		Text = "EXIT",
		TextSize = 10, Corner = 6,
		Color = Color3.fromRGB(80, 20, 20),
		StrokeColor = HUD_COLORS.red,
		TextColor = HUD_COLORS.red,
	})
	bindGuiButton(btnExit, function()
		DismountEvent:FireServer()
	end)
end

local function destroyMobileControls()
	if mobileGui then
		mobileGui:Destroy()
		mobileGui = nil
	end
	-- Reset all mobile input flags
	mobileInputBladeUp = false
	mobileInputBladeDown = false
	mobileInputTiltL = false
	mobileInputTiltR = false
	mobileInputTillerUp = false
	mobileInputTillerDown = false
end

local function createHUD()
	if hudGui then hudGui:Destroy() end

	local gui = Instance.new("ScreenGui")
	gui.Name = "BisonHUD"
	gui.ResetOnSpawn = false
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.Parent = LocalPlayer.PlayerGui

	-- ════════════════════════════════════════════════════
	-- SPEEDOMETER — bottom-right, compact & clean
	-- ════════════════════════════════════════════════════
	local meterW = isMobile and 140 or 160
	local meterH = isMobile and 70 or 80
	local meterYOff = isMobile and -145 or -16
	local meterXOff = isMobile and -10 or -16

	local meter = makeFrame({
		Parent = gui,
		Size = UDim2.new(0, meterW, 0, meterH),
		Pos = UDim2.new(1, meterXOff, 1, meterYOff),
		Anchor = Vector2.new(1, 1),
		Color = Color3.fromRGB(12, 12, 16),
		Corner = 8,
	})
	meter.BackgroundTransparency = 0.15
	local meterStroke = Instance.new("UIStroke")
	meterStroke.Color = HUD_COLORS.amber
	meterStroke.Transparency = 0.7
	meterStroke.Thickness = 1
	meterStroke.Parent = meter

	-- Speed number (big + centered)
	local speedLabel = makeLabel({
		Parent = meter,
		Size = UDim2.new(1, 0, 0, 38),
		Pos = UDim2.new(0, 0, 0, 6),
		Text = "0",
		TextSize = isMobile and 28 or 32,
		Font = Enum.Font.GothamBlack,
		Color = Color3.fromRGB(255, 255, 255),
		XAlign = Enum.TextXAlignment.Center,
	})
	-- "MPH" label (small, under speed)
	makeLabel({
		Parent = meter,
		Size = UDim2.new(1, 0, 0, 14),
		Pos = UDim2.new(0, 0, 0, 40),
		Text = "MPH",
		TextSize = 9,
		Font = Enum.Font.Gotham,
		Color = HUD_COLORS.dim,
		XAlign = Enum.TextXAlignment.Center,
	})

	-- Gear indicator (bottom-left of meter)
	local gearLabel = makeLabel({
		Parent = meter,
		Size = UDim2.new(0, 40, 0, 20),
		Pos = UDim2.new(0, 10, 1, -24),
		Text = "N",
		TextSize = 14,
		Font = Enum.Font.GothamBold,
		Color = HUD_COLORS.dim,
		XAlign = Enum.TextXAlignment.Left,
	})

	-- RPM bar (bottom of meter, thin horizontal)
	local rpmBg = makeFrame({
		Parent = meter,
		Size = UDim2.new(1, -20, 0, 4),
		Pos = UDim2.new(0.5, 0, 1, -8),
		Anchor = Vector2.new(0.5, 1),
		Color = HUD_COLORS.barBg,
		Corner = 2,
	})
	local rpmFill = makeFrame({
		Parent = rpmBg,
		Size = UDim2.new(0, 0, 1, 0),
		Color = HUD_COLORS.amber,
		Corner = 2,
	})

	-- ════════════════════════════════════════════════════
	-- ⚙ BUTTON — opens controls panel, positioned above meter
	-- ════════════════════════════════════════════════════
	local menuOpen = false
	local menuBtnSize = isMobile and 32 or 28
	local menuBtn = Instance.new("TextButton")
	menuBtn.Name = "ControlsBtn"
	menuBtn.Size = UDim2.new(0, menuBtnSize, 0, menuBtnSize)
	menuBtn.Position = UDim2.new(1, meterXOff, 1, meterYOff - meterH - 6)
	menuBtn.AnchorPoint = Vector2.new(1, 1)
	menuBtn.BackgroundColor3 = Color3.fromRGB(12, 12, 16)
	menuBtn.BackgroundTransparency = 0.15
	menuBtn.Text = "⚙"
	menuBtn.TextSize = isMobile and 18 or 16
	menuBtn.TextColor3 = HUD_COLORS.amber
	menuBtn.Font = Enum.Font.GothamBold
	menuBtn.BorderSizePixel = 0
	menuBtn.AutoButtonColor = false
	menuBtn.Parent = gui
	local btnCorner = Instance.new("UICorner")
	btnCorner.CornerRadius = UDim.new(0, 6)
	btnCorner.Parent = menuBtn
	local btnStroke = Instance.new("UIStroke")
	btnStroke.Color = HUD_COLORS.amber
	btnStroke.Transparency = 0.7
	btnStroke.Thickness = 1
	btnStroke.Parent = menuBtn

	-- ════════════════════════════════════════════════════
	-- CONTROLS PANEL — expandable, shows keybinds + status
	-- ════════════════════════════════════════════════════
	local panelW = isMobile and 240 or 260
	local panelH = isMobile and 260 or 280
	local panel = makeFrame({
		Parent = gui,
		Size = UDim2.new(0, panelW, 0, panelH),
		Pos = UDim2.new(1, meterXOff, 1, meterYOff - meterH - 6 - menuBtnSize - 4),
		Anchor = Vector2.new(1, 1),
		Color = Color3.fromRGB(12, 12, 16),
		Corner = 8,
	})
	panel.BackgroundTransparency = 0.1
	panel.Visible = false
	local panelStroke = Instance.new("UIStroke")
	panelStroke.Color = HUD_COLORS.amber
	panelStroke.Transparency = 0.6
	panelStroke.Thickness = 1
	panelStroke.Parent = panel

	local pPad = Instance.new("UIPadding")
	pPad.PaddingLeft = UDim.new(0, 10)
	pPad.PaddingRight = UDim.new(0, 10)
	pPad.PaddingTop = UDim.new(0, 8)
	pPad.Parent = panel

	-- Title
	makeLabel({Parent = panel, Size = UDim2.new(1, 0, 0, 18), Pos = UDim2.new(0, 0, 0, 0),
		Text = "SNOWCAT CONTROLS", TextSize = 11, Font = Enum.Font.GothamBold, Color = HUD_COLORS.amber, XAlign = Enum.TextXAlignment.Left})

	-- Divider
	local div1 = makeFrame({Parent = panel, Size = UDim2.new(1, 0, 0, 1), Pos = UDim2.new(0, 0, 0, 22), Color = HUD_COLORS.amber})
	div1.BackgroundTransparency = 0.7

	-- Keybinds section
	local keybinds = {
		{"W / S", "Drive / Reverse"},
		{"A / D", "Steer Left / Right"},
		{"Q / E", "Blade Up / Down"},
		{"Z / X", "Blade Tilt L / R"},
		{"R / F", "Tiller Up / Down"},
		{"T", "Toggle Tiller Spin"},
		{"V", "Toggle Tiller Wings"},
		{"Space (Hold)", "Exit Snowcat"},
	}
	local keyY = 28
	for _, bind in ipairs(keybinds) do
		makeLabel({Parent = panel, Size = UDim2.new(0, 70, 0, 16), Pos = UDim2.new(0, 0, 0, keyY),
			Text = bind[1], TextSize = 10, Font = Enum.Font.GothamBold, Color = Color3.fromRGB(255, 255, 255), XAlign = Enum.TextXAlignment.Left})
		makeLabel({Parent = panel, Size = UDim2.new(1, -75, 0, 16), Pos = UDim2.new(0, 75, 0, keyY),
			Text = bind[2], TextSize = 10, Font = Enum.Font.Gotham, Color = HUD_COLORS.dim, XAlign = Enum.TextXAlignment.Left})
		keyY = keyY + 17
	end

	-- Divider 2
	local div2 = makeFrame({Parent = panel, Size = UDim2.new(1, 0, 0, 1), Pos = UDim2.new(0, 0, 0, keyY + 4), Color = HUD_COLORS.amber})
	div2.BackgroundTransparency = 0.7

	-- Status section
	local statusY = keyY + 10
	local barW = panelW - 100

	-- Blade Height
	makeLabel({Parent = panel, Size = UDim2.new(0, 50, 0, 14), Pos = UDim2.new(0, 0, 0, statusY),
		Text = "BLADE", TextSize = 9, Font = Enum.Font.GothamBold, Color = HUD_COLORS.amber, XAlign = Enum.TextXAlignment.Left})
	local bladeHBg = makeFrame({Parent = panel, Size = UDim2.new(0, barW, 0, 5), Pos = UDim2.new(0, 55, 0, statusY + 5), Color = HUD_COLORS.barBg, Corner = 2})
	local bladeHFill = makeFrame({Parent = bladeHBg, Size = UDim2.new(0.5, 0, 1, 0), Color = HUD_COLORS.amber, Corner = 2})

	-- Blade Tilt
	makeLabel({Parent = panel, Size = UDim2.new(0, 50, 0, 14), Pos = UDim2.new(0, 0, 0, statusY + 18),
		Text = "TILT", TextSize = 9, Font = Enum.Font.GothamBold, Color = HUD_COLORS.amber, XAlign = Enum.TextXAlignment.Left})
	local bladeTBg = makeFrame({Parent = panel, Size = UDim2.new(0, barW, 0, 5), Pos = UDim2.new(0, 55, 0, statusY + 23), Color = HUD_COLORS.barBg, Corner = 2})
	local bladeTFill = makeFrame({Parent = bladeTBg, Size = UDim2.new(0.5, 0, 1, 0), Color = HUD_COLORS.amber, Corner = 2})

	-- Tiller Height
	makeLabel({Parent = panel, Size = UDim2.new(0, 50, 0, 14), Pos = UDim2.new(0, 0, 0, statusY + 36),
		Text = "TILLER", TextSize = 9, Font = Enum.Font.GothamBold, Color = HUD_COLORS.amber, XAlign = Enum.TextXAlignment.Left})
	local tillerHBg = makeFrame({Parent = panel, Size = UDim2.new(0, barW, 0, 5), Pos = UDim2.new(0, 55, 0, statusY + 41), Color = HUD_COLORS.barBg, Corner = 2})
	local tillerHFill = makeFrame({Parent = tillerHBg, Size = UDim2.new(0.5, 0, 1, 0), Color = HUD_COLORS.amber, Corner = 2})

	-- Spin + Wings (inline)
	local spinLabel = makeLabel({Parent = panel, Size = UDim2.new(0, 80, 0, 14), Pos = UDim2.new(0, 0, 0, statusY + 54),
		Text = "SPIN: OFF", TextSize = 9, Font = Enum.Font.GothamBold, Color = HUD_COLORS.dim, XAlign = Enum.TextXAlignment.Left})
	local wingsLabel = makeLabel({Parent = panel, Size = UDim2.new(0, 100, 0, 14), Pos = UDim2.new(0, 90, 0, statusY + 54),
		Text = "WINGS: CLOSED", TextSize = 9, Font = Enum.Font.GothamBold, Color = HUD_COLORS.dim, XAlign = Enum.TextXAlignment.Left})

	-- Groom bar (bottom of panel)
	local groomTextLabel = makeLabel({Parent = panel, Size = UDim2.new(0, 80, 0, 14), Pos = UDim2.new(0, 0, 0, statusY + 70),
		Text = "NO SLOPE", TextSize = 9, Font = Enum.Font.GothamBold, Color = HUD_COLORS.dim, XAlign = Enum.TextXAlignment.Left})
	local groomBarBg = makeFrame({Parent = panel, Size = UDim2.new(1, -90, 0, 5), Pos = UDim2.new(0, 85, 0, statusY + 75), Color = HUD_COLORS.barBg, Corner = 2})
	local groomBarFill = makeFrame({Parent = groomBarBg, Size = UDim2.new(0, 0, 1, 0), Color = HUD_COLORS.green, Corner = 2})

	-- ⚙ toggle
	menuBtn.MouseButton1Click:Connect(function()
		menuOpen = not menuOpen
		panel.Visible = menuOpen
		menuBtn.Text = menuOpen and "✕" or "⚙"
	end)

	hudRefs = {
		speed = speedLabel,
		rpmFill = rpmFill,
		gear = gearLabel,
		bladeH = bladeHFill,
		bladeT = bladeTFill,
		tillerH = tillerHFill,
		spin = spinLabel,
		wings = wingsLabel,
		groomText = groomTextLabel,
		groomFill = groomBarFill,
	}
	hudGui = gui
end

local function destroyHUD()
	if hudGui then
		hudGui:Destroy()
		hudGui = nil
		hudRefs = {}
	end
end

----------------------------------------------------------------
-- HELPERS
----------------------------------------------------------------
local function findByName(parent, targetName)
	for _, child in pairs(parent:GetDescendants()) do
		if child.Name == targetName then return child end
	end
	return nil
end

local function collectGroup(inst, frameCF)
	local group = {}
	if not inst then return group end
	if inst:IsA("BasePart") then
		attachOriginalCFs[inst] = frameCF:ToObjectSpace(inst.CFrame)
		table.insert(group, inst)
	end
	for _, part in pairs(inst:GetDescendants()) do
		if part:IsA("BasePart") then
			attachOriginalCFs[part] = frameCF:ToObjectSpace(part.CFrame)
			table.insert(group, part)
		end
	end
	return group
end

local function rebuildTillerPartSets()
	table.clear(tillerSpinSet)
	table.clear(tillerLeftWingSet)
	table.clear(tillerRightWingSet)

	for _, part in ipairs(tillerParts.spinParts or {}) do tillerSpinSet[part] = true end
	for _, part in ipairs(tillerParts.leftWingParts or {}) do tillerLeftWingSet[part] = true end
	for _, part in ipairs(tillerParts.rightWingParts or {}) do tillerRightWingSet[part] = true end
end

local function shouldSendGroomSample(sampleCF, sampleSize)
	if not lastGroomSampleCF or not lastGroomSampleSize then
		return true
	end

	if (sampleCF.Position - lastGroomSampleCF.Position).Magnitude >= GROOM_MIN_POSITION_DELTA then
		return true
	end

	local lookDot = math.clamp(sampleCF.LookVector:Dot(lastGroomSampleCF.LookVector), -1, 1)
	if 1 - lookDot >= GROOM_MIN_LOOK_DELTA then
		return true
	end

	return (sampleSize - lastGroomSampleSize).Magnitude >= 1
end

----------------------------------------------------------------
-- COMPUTE GROUND OFFSET FROM TRACK/WHEEL PARTS ONLY
-- The old method measured from pivot to the absolute lowest part,
-- which included the blade (which hangs lower than the tracks).
-- This version finds the lowest point of wheel/track/bogie parts only.
----------------------------------------------------------------
local function computeTrackGroundOffset(model, frame)
	local pivotY = frame.Position.Y
	local lowestTrackY = math.huge

	-- Strategy: Find the lowest Y among parts in the FLWHEELS/FRWHEELS groups
	-- and the main track meshes. These are what actually contact the ground.
	local trackGroups = {"FLWHEELS", "FRWHEELS"}
	local foundTrackParts = false

	for _, groupName in ipairs(trackGroups) do
		local group = findByName(model, groupName)
		if group then
			for _, part in pairs(group:GetDescendants()) do
				if part:IsA("BasePart") then
					local bot = part.Position.Y - part.Size.Y / 2
					if bot < lowestTrackY then lowestTrackY = bot end
					foundTrackParts = true
				end
			end
		end
	end

	-- Also check parts named "Track" or containing "track" (the actual treads)
	for _, part in pairs(model:GetDescendants()) do
		if part:IsA("BasePart") then
			local nameUpper = part.Name:upper()
			if nameUpper:find("TRACK") or nameUpper:find("TREAD") or nameUpper:find("BOGIE") then
				local bot = part.Position.Y - part.Size.Y / 2
				if bot < lowestTrackY then lowestTrackY = bot end
				foundTrackParts = true
			end
		end
	end

	if not foundTrackParts then
		-- Fallback: use the server-computed values if available
		local serverBottom = model:GetAttribute("BottomY")
		if serverBottom then
			-- But add 2 studs to avoid counting the blade
			lowestTrackY = serverBottom + 2
		else
			-- Last resort: scan all parts but ignore Blade/Tiller/Winch children
			local bladeModel = model:FindFirstChild("Blade")
			local tillerModel = model:FindFirstChild("Tiller")
			local winchModel = model:FindFirstChild("Winch")
			for _, part in pairs(model:GetDescendants()) do
				if part:IsA("BasePart") then
					local isAttachment = false
					if bladeModel and part:IsDescendantOf(bladeModel) then isAttachment = true end
					if tillerModel and part:IsDescendantOf(tillerModel) then isAttachment = true end
					if winchModel and part:IsDescendantOf(winchModel) then isAttachment = true end
					if not isAttachment then
						local bot = part.Position.Y - part.Size.Y / 2
						if bot < lowestTrackY then lowestTrackY = bot end
					end
				end
			end
		end
	end

	if lowestTrackY == math.huge then
		return 4 -- safe fallback
	end

	-- Offset = how far above ground the pivot needs to be.
	-- Add a tiny 0.15 stud buffer so tracks sit ON the ground, not clipping.
	local offset = (pivotY - lowestTrackY) + 0.15
	if offset < 1 then offset = 1 end
	return offset
end

----------------------------------------------------------------
-- MOUNT / DISMOUNT
----------------------------------------------------------------
MountEvent.OnClientEvent:Connect(function(model, player, mounted)
	if player ~= LocalPlayer then return end

	if mounted then
		activeBison = model
		bisonFrame = model.PrimaryPart
		isDriving = true
		LocalPlayer:SetAttribute("IsDrivingBison", true)

		local cf = bisonFrame.CFrame
		bodyPos = cf.Position
		bodyYaw = math.atan2(-cf.LookVector.X, -cf.LookVector.Z)
		velocity = 0
		angularVel = 0
		smoothPitch = 0
		smoothRoll = 0
		prevTargetY = nil
		spaceHoldTime = 0

		rayParams.FilterDescendantsInstances = {model, LocalPlayer.Character}

		-- Compute ground offset from TRACK parts only (not blade/tiller)
		groundOffset = computeTrackGroundOffset(model, bisonFrame)

		-- Snap to correct height
		local ray = workspace:Raycast(
			bodyPos + Vector3.new(0, 50, 0),
			Vector3.new(0, -120, 0),
			rayParams
		)
		if ray then
			bodyPos = Vector3.new(bodyPos.X, ray.Position.Y + groundOffset, bodyPos.Z)
			print("Ground=" .. string.format("%.1f", ray.Position.Y)
				.. " TrackOffset=" .. string.format("%.1f", groundOffset)
				.. " BodyY=" .. string.format("%.1f", bodyPos.Y))
		end


	-- Camera
		local camPart = model:FindFirstChild("BisonCamSubject")
		if not camPart then
			camPart = Instance.new("Part")
			camPart.Name = "BisonCamSubject"
			camPart.Size = Vector3.new(1, 1, 1)
			camPart.Transparency = 1
			camPart.CanCollide = false
			camPart.CanQuery = false
			camPart.Anchored = true
			camPart.Parent = model
		end
		camPart.CFrame = CFrame.new(bodyPos + Vector3.new(0, 4, 0))
		Camera.CameraType = Enum.CameraType.Custom
		Camera.CameraSubject = camPart

		-- Attachment setup
		bladeParts = {}
		tillerParts = {}
		winchParts = {}
		attachOriginalCFs = {}

		local frameCF = bisonFrame.CFrame

		-- BLADE
		local bladeModel = model:FindFirstChild("Blade")
		if bladeModel then
			local bladeRig = findByName(bladeModel, "BladeRig")
			local bladePlateModel = nil
			if bladeRig then
				for _, child in pairs(bladeRig:GetChildren()) do
					if child.Name == "Blade" and child:IsA("Model") then
						bladePlateModel = child; break
					end
				end
			end
			bladeParts.plateParts = bladePlateModel and collectGroup(bladePlateModel, frameCF) or {}
			if bladeRig then
				local ear1 = findByName(bladeRig, "BladeEar1")
				local ear2 = findByName(bladeRig, "BladeEar2")
				bladeParts.leftWingParts = collectGroup(ear1, frameCF)
				bladeParts.rightWingParts = collectGroup(ear2, frameCF)
				for _, p in ipairs(bladeParts.leftWingParts) do table.insert(bladeParts.plateParts, p) end
				for _, p in ipairs(bladeParts.rightWingParts) do table.insert(bladeParts.plateParts, p) end
			else
				bladeParts.leftWingParts = {}
				bladeParts.rightWingParts = {}
			end
			local hinge = findByName(bladeModel, "LowerbladeAnchorPoint")
			if hinge and hinge:IsA("BasePart") then
				bladeParts.hingeCFOffset = frameCF:ToObjectSpace(hinge.CFrame)
			end
		end

		-- TILLER
		local tillerModel = model:FindFirstChild("Tiller")
		if tillerModel then
			local tillerOp = findByName(tillerModel, "TillerOperation")
			if tillerOp then
				local tillerDrumModel = nil
				for _, child in pairs(tillerOp:GetChildren()) do
					if child.Name == "Tiller" and child:IsA("Model") then
						tillerDrumModel = child; break
					end
				end
				tillerParts.spinParts = collectGroup(tillerDrumModel, frameCF)
				local tillerOpBase = findByName(tillerOp, "Base")
				tillerParts.frameParts = collectGroup(tillerOpBase, frameCF)
				local tillerBaseModel = findByName(tillerModel, "TillerBase")
				if tillerBaseModel then
					for _, p in ipairs(collectGroup(tillerBaseModel, frameCF)) do
						table.insert(tillerParts.frameParts, p)
					end
				end
				local leftEnd = findByName(tillerOp, "LeftEnd")
				local rightEnd = findByName(tillerOp, "RightEnd")
				tillerParts.leftWingParts = collectGroup(leftEnd, frameCF)
				tillerParts.rightWingParts = collectGroup(rightEnd, frameCF)
				if leftEnd then tillerParts.leftWingHingeOffset = frameCF:ToObjectSpace(leftEnd:GetPivot()) end
				if rightEnd then tillerParts.rightWingHingeOffset = frameCF:ToObjectSpace(rightEnd:GetPivot()) end
			else
				tillerParts.spinParts = {}
				tillerParts.frameParts = {}
				tillerParts.leftWingParts = {}
				tillerParts.rightWingParts = {}
			end
			local hinge = findByName(tillerModel, "RotateAround")
			if hinge and hinge:IsA("BasePart") then
				tillerParts.hingeCFOffset = frameCF:ToObjectSpace(hinge.CFrame)
			end
			local spinCenter = findByName(tillerModel, "TillerRotate")
			if spinCenter and spinCenter:IsA("BasePart") then
				tillerParts.spinCenterOffset = frameCF:ToObjectSpace(spinCenter.CFrame)
			end
		end
		rebuildTillerPartSets()

		-- WINCH
		local winchModel = model:FindFirstChild("Winch") or findByName(model, "Winch")
		if winchModel and winchModel:IsA("Model") then
			local hook = findByName(winchModel, "Crane hook")
			local ring = findByName(winchModel, "ring")
			winchParts.hookParts = {}
			if hook and hook:IsA("BasePart") then
				attachOriginalCFs[hook] = frameCF:ToObjectSpace(hook.CFrame)
				table.insert(winchParts.hookParts, hook)
			end
			if ring and ring:IsA("BasePart") then
				attachOriginalCFs[ring] = frameCF:ToObjectSpace(ring.CFrame)
				table.insert(winchParts.hookParts, ring)
			end
		end

		-- Reset attachment state
		bladeHeight = 0; bladeTilt = 0; bladeWingsOpen = false
		tillerHeight = 0; tillerSpinning = false; tillerSpinAngle = 0; tillerWingsDown = false
		tillerWingAngle = 0
		winchLength = 0; winchAutoTension = false

		-- ═══════════════════════════════════════════════════
		-- WHEEL DISCOVERY (suspension only, no spin)
		-- ═══════════════════════════════════════════════════
		suspWheelsL = {}
		suspWheelsR = {}
		for _, sideName in ipairs({"FLWHEELS", "FRWHEELS"}) do
			local side = findByName(activeBison, sideName)
			if side then
				for _, child in ipairs(side:GetChildren()) do
					if child:IsA("Model") and string.find(child.Name:upper(), "WHEEL") then
						local localCF = frameCF:ToObjectSpace(child:GetPivot())
						local isLeftSide = (sideName == "FLWHEELS")
						local wData = {
							model = child,
							localCF = localCF,
							diffY = 0,
						}
						if isLeftSide then
							table.insert(suspWheelsL, wData)
						else
							table.insert(suspWheelsR, wData)
						end
					end
				end
			end
		end
		print("Suspension wheels (L/R): " .. #suspWheelsL .. " / " .. #suspWheelsR)

		-- TRACK WHEEL/COG COLLECTION for spin animation
		trackWheels = {}
		trackCogs = {}
		for _, sideName in ipairs({"FLWHEELS", "FRWHEELS"}) do
			local side = findByName(activeBison, sideName)
			if side then
				local isLeft = (sideName == "FLWHEELS")
				for _, child in ipairs(side:GetChildren()) do
					if child:IsA("Model") then
						local isCog = child.Name:upper():find("COG") ~= nil
						local localCF = frameCF:ToObjectSpace(child:GetPivot())
						-- Estimate radius from largest dimension (Y or X)
						local biggest = nil
						local biggestVol = 0
						for _, part in ipairs(child:GetDescendants()) do
							if part:IsA("BasePart") then
								local vol = part.Size.X * part.Size.Y * part.Size.Z
								if vol > biggestVol then biggestVol = vol; biggest = part end
							end
						end
						local radius = biggest and math.max(biggest.Size.X, biggest.Size.Y) / 2 or 0.8
						local entry = {
							model = child,
							localCF = localCF,
							radius = radius,
							isLeft = isLeft,
						}
						if isCog then
							table.insert(trackCogs, entry)
						else
							table.insert(trackWheels, entry)
						end
					end
				end
			end
		end
		print("Track wheels: " .. #trackWheels .. " | Cogs: " .. #trackCogs)

		-- AUDIO
		sndEngine = Instance.new("Sound")
		sndEngine.SoundId = "rbxassetid://116523768803276"
		sndEngine.Looped = true
		sndEngine.Volume = 0.6
		sndEngine.PlaybackSpeed = 0.85
		sndEngine.RollOffMaxDistance = 120
		sndEngine.Parent = bisonFrame
		sndEngine:Play()

		sndReverse = Instance.new("Sound")
		sndReverse.SoundId = "rbxassetid://3877834081"
		sndReverse.Looped = true
		sndReverse.Volume = 0.5
		sndReverse.RollOffMaxDistance = 80
		sndReverse.Parent = bisonFrame

		sndHydraulic = Instance.new("Sound")
		sndHydraulic.SoundId = "rbxassetid://18918646108"
		sndHydraulic.Looped = false
		sndHydraulic.Volume = 0.45
		sndHydraulic.RollOffMaxDistance = 60
		sndHydraulic.Parent = bisonFrame
		prevBladeDir = 0; prevTillerDir = 0

		-- PARTICLES: Tiller spray
		-- Anchored parts updated manually each frame (welds don't work with PivotTo)
		tillerAnchorPart = Instance.new("Part")
		tillerAnchorPart.Name = "TillerParticleAnchor"
		tillerAnchorPart.Transparency = 1; tillerAnchorPart.CanCollide = false
		tillerAnchorPart.CanQuery = false; tillerAnchorPart.Anchored = true
		tillerAnchorPart.Size = Vector3.new(0.5, 0.5, 0.5)
		tillerAnchorPart.CFrame = bisonFrame.CFrame * CFrame.new(0, -1, 12)
		tillerAnchorPart.Parent = activeBison

		tillerParticles = Instance.new("ParticleEmitter")
		tillerParticles.Texture = "rbxasset://textures/particles/smoke_main.dds"
		tillerParticles.Color = ColorSequence.new(Color3.fromRGB(255,255,255), Color3.fromRGB(220,230,245))
		tillerParticles.Size = NumberSequence.new({NumberSequenceKeypoint.new(0,0.5),NumberSequenceKeypoint.new(0.5,1.5),NumberSequenceKeypoint.new(1,0.1)})
		tillerParticles.Transparency = NumberSequence.new({NumberSequenceKeypoint.new(0,0.2),NumberSequenceKeypoint.new(0.7,0.6),NumberSequenceKeypoint.new(1,1)})
		tillerParticles.Lifetime = NumberRange.new(0.6,1.5)
		tillerParticles.Speed = NumberRange.new(15,30)
		tillerParticles.SpreadAngle = Vector2.new(60,90)
		tillerParticles.Acceleration = Vector3.new(0,-20,0)
		if GraphicsProfile.IsRealisticParticlesEnabled(LocalPlayer) then
			tillerParticles.Drag = 2.4
			tillerParticles.LightInfluence = 0.25
		else
			tillerParticles.Drag = 1.5
			tillerParticles.LightInfluence = 0
		end
		tillerParticles.Rate = 0
		tillerParticles.Rotation = NumberRange.new(0,360); tillerParticles.RotSpeed = NumberRange.new(-180,180)
		tillerParticles.Enabled = false; tillerParticles.Parent = tillerAnchorPart

		-- PARTICLES: Blade snow push
		bladeAnchorPart = Instance.new("Part")
		bladeAnchorPart.Name = "BladeParticleAnchor"
		bladeAnchorPart.Transparency = 1; bladeAnchorPart.CanCollide = false
		bladeAnchorPart.CanQuery = false; bladeAnchorPart.Anchored = true
		bladeAnchorPart.Size = Vector3.new(0.5,0.5,0.5)
		bladeAnchorPart.CFrame = bisonFrame.CFrame * CFrame.new(0,-2,-12)
		bladeAnchorPart.Parent = activeBison

		bladeParticles = Instance.new("ParticleEmitter")
		bladeParticles.Texture = "rbxasset://textures/particles/smoke_main.dds"
		bladeParticles.Color = ColorSequence.new(Color3.fromRGB(255,255,255), Color3.fromRGB(230,240,250))
		bladeParticles.Size = NumberSequence.new({NumberSequenceKeypoint.new(0,1.0),NumberSequenceKeypoint.new(0.4,3.0),NumberSequenceKeypoint.new(1,0.5)})
		bladeParticles.Transparency = NumberSequence.new({NumberSequenceKeypoint.new(0,0.3),NumberSequenceKeypoint.new(0.5,0.6),NumberSequenceKeypoint.new(1,1)})
		bladeParticles.Lifetime = NumberRange.new(0.5,1.2)
		bladeParticles.Speed = NumberRange.new(10,20)
		bladeParticles.SpreadAngle = Vector2.new(80,60)
		bladeParticles.Acceleration = Vector3.new(0,-10,0)
		if GraphicsProfile.IsRealisticParticlesEnabled(LocalPlayer) then
			bladeParticles.Drag = 1.8
			bladeParticles.LightInfluence = 0.2
		else
			bladeParticles.Drag = 1
			bladeParticles.LightInfluence = 0
		end
		bladeParticles.Rate = 0
		bladeParticles.Rotation = NumberRange.new(0,360); bladeParticles.RotSpeed = NumberRange.new(-90,90)
		bladeParticles.Enabled = false; bladeParticles.Parent = bladeAnchorPart
		paintCenterPart = activeBison:FindFirstChild("PaintCenter")
		lastClientGroomFire = 0
		lastGroomSampleCF = nil
		lastGroomSampleSize = nil
		hudUpdateAccumulator = 0
		audioUpdateAccumulator = 0

		local ok, mountErr = pcall(function()
			print("[Client] Mounted!")
			createHUD()
			createMobileControls()
			bindDrivingInputs()
		end)
		if not ok then
			warn("[BisonClient] Mount setup failed: " .. tostring(mountErr))
			isDriving = false
			LocalPlayer:SetAttribute("IsDrivingBison", nil)
			activeBison = nil
			bisonFrame = nil
			inputW, inputS, inputA, inputD, inputBrake = false, false, false, false, false
			Camera.CameraType = Enum.CameraType.Custom
			Camera.CameraSubject = LocalPlayer.Character and LocalPlayer.Character:FindFirstChildOfClass("Humanoid") or nil
			unbindDrivingInputs()
			destroyHUD()
			destroyMobileControls()
			DismountEvent:FireServer()
			return
		end
	else
		-- DISMOUNT
		isDriving = false
		LocalPlayer:SetAttribute("IsDrivingBison", nil)
		activeBison = nil
		bisonFrame = nil
		velocity = 0; angularVel = 0; prevTargetY = nil

		Camera.CameraType = Enum.CameraType.Custom
		Camera.CameraSubject = LocalPlayer.Character and
			LocalPlayer.Character:FindFirstChildOfClass("Humanoid") or nil

		inputW, inputS, inputA, inputD, inputBrake = false, false, false, false, false

		if sndEngine then sndEngine:Stop(); sndEngine:Destroy(); sndEngine = nil end
		if sndReverse then sndReverse:Stop(); sndReverse:Destroy(); sndReverse = nil end
		if sndHydraulic then sndHydraulic:Destroy(); sndHydraulic = nil end
		tillerParticles = nil; bladeParticles = nil
		tillerAnchorPart = nil; bladeAnchorPart = nil; paintCenterPart = nil
		lastClientGroomFire = 0
		lastGroomSampleCF = nil
		lastGroomSampleSize = nil
		hudUpdateAccumulator = 0
		audioUpdateAccumulator = 0
		table.clear(tillerSpinSet)
		table.clear(tillerLeftWingSet)
		table.clear(tillerRightWingSet)

		unbindDrivingInputs()
		destroyHUD()
		destroyMobileControls()
		print("[Client] Dismounted!")
	end
end)

----------------------------------------------------------------
-- DRIVING LOOP
----------------------------------------------------------------
local lastReplicateTime = 0

RunService.RenderStepped:Connect(function(dt)
	if not isDriving or not activeBison or not bisonFrame then return end
	dt = math.min(dt, 0.05)

	-- HOLD SPACE TO DISMOUNT
	if inputBrake then
		spaceHoldTime = spaceHoldTime + dt
		if spaceHoldTime >= 1.0 then
			DismountEvent:FireServer()
			spaceHoldTime = 0
			return
		end
	else
		spaceHoldTime = 0
	end

	-- THROTTLE
	local throttle = 0
	if inputW then throttle = 1 end
	if inputS then throttle = -1 end

	if throttle > 0 then
		if currentGear < #GEARS and velocity > GEARS[currentGear].maxSpd - 0.5 then
			currentGear = currentGear + 1
		end
		local gear = GEARS[currentGear]
		velocity = velocity + gear.accel * dt
		if velocity > gear.maxSpd then velocity = gear.maxSpd end
	elseif throttle < 0 then
		if currentRevGear < #REVERSE_GEARS and velocity < -(REVERSE_GEARS[currentRevGear].maxSpd - 0.5) then
			currentRevGear = currentRevGear + 1
		end
		local revGear = REVERSE_GEARS[currentRevGear]
		velocity = velocity - revGear.accel * dt
		if velocity < -revGear.maxSpd then velocity = -revGear.maxSpd end
	else
		if velocity > 0 then
			velocity = math.max(0, velocity - COAST_DRAG * dt)
			if currentGear > 1 and velocity < GEARS[currentGear-1].maxSpd - 1 then
				currentGear = currentGear - 1
			end
		elseif velocity < 0 then
			velocity = math.min(0, velocity + COAST_DRAG * dt)
			if currentRevGear > 1 and velocity > -(REVERSE_GEARS[currentRevGear-1].maxSpd - 1) then
				currentRevGear = currentRevGear - 1
			end
		end
	end

	if inputBrake then
		if velocity > 0 then velocity = math.max(0, velocity - BRAKE_FORCE * dt)
		elseif velocity < 0 then velocity = math.min(0, velocity + BRAKE_FORCE * dt) end
	end

	-- STEERING
	local steer = 0
	if inputA then steer = 1 end
	if inputD then steer = -1 end

	local speedFactor = 1 - math.clamp(math.abs(velocity) / MAX_SPEED, 0, 0.4)
	local targetTurn = steer * MAX_TURN * speedFactor

	if steer ~= 0 then
		angularVel = angularVel + (targetTurn - angularVel) * math.min(1, TURN_ACCEL * dt)
	else
		angularVel = angularVel * math.max(0, 1 - TURN_DRAG * dt)
	end
	bodyYaw = bodyYaw + angularVel * dt

	-- FORWARD MOVEMENT
	local forward = Vector3.new(-math.sin(bodyYaw), 0, -math.cos(bodyYaw))
	bodyPos = bodyPos + forward * velocity * dt

	-- GROUND FOLLOW: 10 raycasts
	local yawCF = CFrame.Angles(0, bodyYaw, 0)
	local groundHits = GroundHitBuffer
	local hitValues = GroundValueBuffer
	table.clear(groundHits)
	table.clear(hitValues)

	local hitCount = 0
	for i, offset in ipairs(GROUND_SAMPLE_OFFSETS) do
		local worldOffset = yawCF:VectorToWorldSpace(offset)
		local cornerXZ = bodyPos + worldOffset
		local origin = Vector3.new(cornerXZ.X, bodyPos.Y + 50, cornerXZ.Z)
		local result = workspace:Raycast(origin, Vector3.new(0, -100, 0), rayParams)
		if result then
			local hitY = result.Position.Y
			groundHits[i] = hitY
			hitCount += 1
			hitValues[hitCount] = hitY
		else
			groundHits[i] = nil
		end
	end

	if hitCount > 0 then
		-- MEDIAN ground height: the middle value of sorted hits.
		-- This ignores both dips (low outliers) and bumps (high outliers),
		-- giving the most representative "where the ground actually is" value.
		-- A 10-ton snowcat doesn't react to individual terrain cells.
		table.sort(hitValues)
		local medianIdx = math.ceil(hitCount * 0.5)
		local effectiveGround = hitValues[medianIdx]
		local targetY = effectiveGround + groundOffset

		-- Rate-limited direct height follow.
		-- Speed-dependent smoothing: when stopped/slow, settle FAST onto terrain.
		-- At high speed, smooth heavily to "plow through" bumps.
		if prevTargetY == nil then prevTargetY = targetY end

		-- Faster settle when nearly stopped, slower when moving fast
		local speedPct = math.clamp(math.abs(velocity) / 15, 0, 1)
		local smoothRate = 12 - speedPct * 8  -- 12/s when stopped → 4/s at speed
		local smoothedTarget = prevTargetY + (targetY - prevTargetY) * math.min(1, smoothRate * dt)
		prevTargetY = smoothedTarget

		local heightError = smoothedTarget - bodyPos.Y
		local maxMove
		if heightError > 0 then
			maxMove = MAX_HEIGHT_UP_RATE * dt
		else
			maxMove = MAX_HEIGHT_DOWN_RATE * dt
		end
		local move = math.clamp(heightError, -maxMove, maxMove)
		bodyPos = Vector3.new(bodyPos.X, bodyPos.Y + move, bodyPos.Z)

		-- PITCH from front vs rear raycasts
		local frontG, fC = 0, 0
		local rearG, rC = 0, 0
		for i = 1, 4 do
			if groundHits[i] then frontG = frontG + groundHits[i]; fC = fC + 1 end
		end
		for i = 7, 10 do
			if groundHits[i] then rearG = rearG + groundHits[i]; rC = rC + 1 end
		end
		local targetPitch = 0
		if fC > 0 and rC > 0 then
			targetPitch = math.atan2(frontG/fC - rearG/rC, 18)
		end

		-- ROLL from left vs right raycasts
		local leftG, lC = 0, 0
		local rightG, rC2 = 0, 0
		for i = 1, 9, 2 do
			if groundHits[i] then leftG = leftG + groundHits[i]; lC = lC + 1 end
		end
		for i = 2, 10, 2 do
			if groundHits[i] then rightG = rightG + groundHits[i]; rC2 = rC2 + 1 end
		end
		local targetRoll = 0
		if lC > 0 and rC2 > 0 then
			targetRoll = math.atan2(rightG/rC2 - leftG/lC, 14)
		end

		local pitchAlpha = 1 - math.exp(-PITCH_SMOOTH * dt)
		local rollAlpha = 1 - math.exp(-ROLL_SMOOTH * dt)
		smoothPitch = smoothPitch + (targetPitch - smoothPitch) * pitchAlpha
		smoothRoll = smoothRoll + (targetRoll - smoothRoll) * rollAlpha

		-- Slope gravity (applied ONCE)
		velocity = velocity - math.sin(smoothPitch) * SLOPE_GRAVITY * dt
	end

	smoothPitch = math.clamp(smoothPitch, -0.18, 0.18)  -- ~10 degrees max pitch
	smoothRoll = math.clamp(smoothRoll, -0.12, 0.12)   -- ~7 degrees max roll

	-- BUILD CFRAME
	local finalCF = CFrame.new(bodyPos)
		* CFrame.Angles(0, bodyYaw, 0)
		* CFrame.Angles(smoothPitch, 0, smoothRoll)
		* CFrame.Angles(0, MODEL_VISUAL_OFFSET, 0)

	activeBison:PivotTo(finalCF)

	-- ════════════════════════════════════════════
	-- WHEEL SUSPENSION (position only, no spin)
	-- ════════════════════════════════════════════
	-- WHEEL SUSPENSION + TRACK SPIN
	local trackWheelRadius = 0.95
	local trackSpinDelta = (velocity / trackWheelRadius) * dt
	wheelSpinAngle = wheelSpinAngle + trackSpinDelta

	local function processWheels(wheels)
		for _, w in ipairs(wheels) do
			local restCF = finalCF * w.localCF
			local castFrom = restCF.Position + Vector3.new(0, 5, 0)
			local hit = workspace:Raycast(castFrom, Vector3.new(0, -10, 0), rayParams)
			local target = 0
			if hit then
				target = math.clamp(hit.Position.Y - restCF.Position.Y, -0.5, 0.8)
			end
			w.diffY = w.diffY + (target - w.diffY) * math.min(1, 15 * dt)
			local suspCF = finalCF * CFrame.new(0, w.diffY, 0) * w.localCF
			-- Apply track spin on top of suspension offset
			w.model:PivotTo(suspCF * CFrame.Angles(wheelSpinAngle, 0, 0))
		end
	end

	processWheels(suspWheelsL)
	processWheels(suspWheelsR)

	-- ════════════════════════════════════════════
	-- ATTACHMENT INPUT (CAS sets mobileInput* flags for both keyboard and mobile)
	-- ════════════════════════════════════════════
	if mobileInputBladeUp then bladeHeight = math.clamp(bladeHeight + ATTACH_SPEED * dt / BLADE_MAX_RAISE, -1, 1) end
	if mobileInputBladeDown then bladeHeight = math.clamp(bladeHeight - ATTACH_SPEED * dt / BLADE_MAX_RAISE, -1, 1) end
	if mobileInputTiltL then bladeTilt = math.clamp(bladeTilt - ATTACH_SPEED * dt, -1, 1) end
	if mobileInputTiltR then bladeTilt = math.clamp(bladeTilt + ATTACH_SPEED * dt, -1, 1) end
	if mobileInputTillerUp then tillerHeight = math.clamp(tillerHeight + ATTACH_SPEED * dt / TILLER_MAX_RAISE, -1, 1) end
	if mobileInputTillerDown then tillerHeight = math.clamp(tillerHeight - ATTACH_SPEED * dt / TILLER_MAX_RAISE, -1, 1) end

	if tillerSpinning then tillerSpinAngle = tillerSpinAngle + TILLER_SPIN_SPEED * dt end

	-- BLADE ANIMATION
	if bladeParts.plateParts and #bladeParts.plateParts > 0 and bladeParts.hingeCFOffset then
		local raiseAngle = bladeHeight > 0 and (bladeHeight * 0.5) or (bladeHeight * 0.3)
		local tiltAngle = bladeTilt * BLADE_MAX_TILT
		local rotCF = CFrame.Angles(0, tiltAngle, raiseAngle)
		local hingeCF = finalCF * bladeParts.hingeCFOffset
		for _, part in ipairs(bladeParts.plateParts) do
			local orig = attachOriginalCFs[part]
			if orig then
				local relToHinge = hingeCF:ToObjectSpace(finalCF * orig)
				part.CFrame = hingeCF * rotCF * relToHinge
			end
		end
	end

	-- TILLER ANIMATION
	if tillerParts.hingeCFOffset then
		local raiseAngle = tillerHeight > 0 and (tillerHeight * 0.4) or (tillerHeight * 0.2)
		local hingeCF = finalCF * tillerParts.hingeCFOffset
		local raiseRotCF = CFrame.Angles(raiseAngle, 0, 0)
		local spinSet = tillerSpinSet
		local leftWingSet = tillerLeftWingSet
		local rightWingSet = tillerRightWingSet

		local wingTarget = tillerWingsDown and 1.5 or 0
		tillerWingAngle = tillerWingAngle + (wingTarget - tillerWingAngle) * math.min(1, ATTACH_SPEED * dt * 2)

		for _, part in ipairs(tillerParts.frameParts or {}) do
			if not spinSet[part] then
				local orig = attachOriginalCFs[part]
				if orig then
					local relToHinge = hingeCF:ToObjectSpace(finalCF * orig)
					local raisedCF = hingeCF * raiseRotCF * relToHinge

					if leftWingSet[part] and tillerParts.leftWingHingeOffset then
						local wHingeWorld = finalCF * tillerParts.leftWingHingeOffset
						local wHingeRel = hingeCF:ToObjectSpace(wHingeWorld)
						local raisedWHinge = hingeCF * raiseRotCF * wHingeRel
						local partRelToWH = raisedWHinge:ToObjectSpace(raisedCF)
						part.CFrame = raisedWHinge * CFrame.Angles(0, 0, -tillerWingAngle) * partRelToWH
					elseif rightWingSet[part] and tillerParts.rightWingHingeOffset then
						local wHingeWorld = finalCF * tillerParts.rightWingHingeOffset
						local wHingeRel = hingeCF:ToObjectSpace(wHingeWorld)
						local raisedWHinge = hingeCF * raiseRotCF * wHingeRel
						local partRelToWH = raisedWHinge:ToObjectSpace(raisedCF)
						part.CFrame = raisedWHinge * CFrame.Angles(0, 0, tillerWingAngle) * partRelToWH
					else
						part.CFrame = raisedCF
					end
				end
			end
		end

		if tillerParts.spinCenterOffset and tillerParts.spinParts then
			local spinCenterWorld = finalCF * tillerParts.spinCenterOffset
			local spinRelToHinge = hingeCF:ToObjectSpace(spinCenterWorld)
			local raisedSpinCenter = hingeCF * raiseRotCF * spinRelToHinge
			local spinRotCF = CFrame.Angles(tillerSpinAngle, 0, 0)
			for _, part in ipairs(tillerParts.spinParts) do
				local orig = attachOriginalCFs[part]
				if orig then
					local relToHinge = hingeCF:ToObjectSpace(finalCF * orig)
					local raisedPartCF = hingeCF * raiseRotCF * relToHinge
					local relToSpin = raisedSpinCenter:ToObjectSpace(raisedPartCF)
					part.CFrame = raisedSpinCenter * spinRotCF * relToSpin
				end
			end
		end
	end

	-- Camera
	local camPart = activeBison:FindFirstChild("BisonCamSubject")
	if camPart then camPart.CFrame = CFrame.new(bodyPos + Vector3.new(0, 4, 0)) end

	audioUpdateAccumulator = audioUpdateAccumulator + dt
	local shouldUpdateAudio = audioUpdateAccumulator >= AUDIO_UPDATE_INTERVAL
	if shouldUpdateAudio then
		audioUpdateAccumulator = 0
	end

	particleUpdateAccumulator = particleUpdateAccumulator + dt
	local shouldUpdateParticles = particleUpdateAccumulator >= PARTICLE_UPDATE_INTERVAL
	if shouldUpdateParticles then
		particleUpdateAccumulator = 0
	end

	hudUpdateAccumulator = hudUpdateAccumulator + dt
	local shouldUpdateHUD = hudUpdateAccumulator >= HUD_UPDATE_INTERVAL
	if shouldUpdateHUD then
		hudUpdateAccumulator = 0
	end

	-- AUDIO
	if shouldUpdateAudio and sndEngine then
		local speedRatio = math.clamp(math.abs(velocity) / MAX_SPEED, 0, 1)
		sndEngine.PlaybackSpeed = 0.8 + speedRatio * 0.5
		sndEngine.Volume = 0.5 + speedRatio * 0.3
	end
	if shouldUpdateAudio and sndReverse then
		if velocity < -0.5 then
			if not sndReverse.IsPlaying then sndReverse:Play() end
		else
			if sndReverse.IsPlaying then sndReverse:Stop() end
		end
	end
	if shouldUpdateAudio and sndHydraulic then
		local bladeDir = 0
		if mobileInputBladeUp then bladeDir = 1 end
		if mobileInputBladeDown then bladeDir = -1 end
		if bladeDir ~= 0 and bladeDir ~= prevBladeDir and prevBladeDir ~= 0 then sndHydraulic:Play() end
		if bladeDir ~= 0 then prevBladeDir = bladeDir end

		local tillerDir = 0
		if mobileInputTillerUp then tillerDir = 1 end
		if mobileInputTillerDown then tillerDir = -1 end
		if tillerDir ~= 0 and tillerDir ~= prevTillerDir and prevTillerDir ~= 0 then sndHydraulic:Play() end
		if tillerDir ~= 0 then prevTillerDir = tillerDir end
	end

	-- PARTICLES: Update anchor positions (they're anchored, not welded)
	if tillerAnchorPart and tillerAnchorPart.Parent == activeBison then
		tillerAnchorPart.CFrame = finalCF * CFrame.new(0, -1, 12)
	end
	if bladeAnchorPart and bladeAnchorPart.Parent == activeBison then
		bladeAnchorPart.CFrame = finalCF * CFrame.new(0, -2, -12)
	end

	local particleScale = GraphicsProfile.GetParticleScale(LocalPlayer) * GraphicsProfile.GetParticleDensityScale(LocalPlayer)
	local adaptiveScale = 1
	local realisticParticles = GraphicsProfile.IsRealisticParticlesEnabled(LocalPlayer)
	if GraphicsProfile.IsAdaptiveParticlesEnabled(LocalPlayer) then
		local fps = (dt > 0) and (1 / dt) or 60
		if fps < 58 then
			adaptiveScale = fps <= 24 and 0.3 or math.clamp((fps - 24) / 34, 0.3, 1)
		end
	end

	if tillerParticles then
		if realisticParticles then
			tillerParticles.Drag = 2.4
			tillerParticles.LightInfluence = 0.25
		else
			tillerParticles.Drag = 1.5
			tillerParticles.LightInfluence = 0
		end
		local shouldSpray = tillerSpinning and tillerHeight < 0.1 and math.abs(velocity) > 0.3
		tillerParticles.Enabled = shouldSpray and shouldUpdateParticles
		if shouldSpray then
			tillerParticles.Rate = math.clamp(math.abs(velocity) * 14 * particleScale * adaptiveScale, 8, 220)
			if not paintCenterPart or paintCenterPart.Parent ~= activeBison then
				paintCenterPart = activeBison:FindFirstChild("PaintCenter")
			end
			local now = tick()
			local sampleCF
			local sampleSize
			if paintCenterPart then
				local pSize = paintCenterPart.Size
				sampleCF = paintCenterPart.CFrame
				sampleSize = Vector3.new(math.max(pSize.X, 28), 4, math.max(pSize.Z, 6))
			else
				sampleCF = finalCF * CFrame.new(0, -3.5, 14)
				sampleSize = Vector3.new(20, 4, 6)
			end
			if now - lastClientGroomFire >= GROOM_FIRE_INTERVAL and shouldSendGroomSample(sampleCF, sampleSize) then
				lastClientGroomFire = now
				lastGroomSampleCF = sampleCF
				lastGroomSampleSize = sampleSize
				GroomEvent:FireServer(sampleCF, sampleSize)
			end
		end
	end
	if bladeParticles then
		if realisticParticles then
			bladeParticles.Drag = 1.8
			bladeParticles.LightInfluence = 0.2
		else
			bladeParticles.Drag = 1
			bladeParticles.LightInfluence = 0
		end
		local shouldPush = velocity > 1 and bladeHeight < 0.1
		bladeParticles.Enabled = shouldPush and shouldUpdateParticles
		if shouldPush then bladeParticles.Rate = math.clamp(velocity * 9 * particleScale * adaptiveScale, 6, 140) end
	end

	-- HUD UPDATES
	if shouldUpdateHUD and hudGui and hudRefs.speed then
		hudRefs.speed.Text = string.format("%.0f", math.abs(velocity) * 0.63)

		local activeGear = (velocity >= -0.1) and GEARS[currentGear] or REVERSE_GEARS[currentRevGear]
		local rpmPct = math.clamp(math.abs(velocity) / activeGear.maxSpd, 0, 1)
		hudRefs.rpmFill.Size = UDim2.new(rpmPct, 0, 1, 0)
		hudRefs.rpmFill.BackgroundColor3 = rpmPct > 0.85 and HUD_COLORS.red or HUD_COLORS.amber

		if math.abs(velocity) < 0.5 and throttle == 0 then
			hudRefs.gear.Text = "N"; hudRefs.gear.TextColor3 = HUD_COLORS.dim
		elseif throttle > 0 or velocity > 0.5 then
			hudRefs.gear.Text = GEARS[currentGear].name; hudRefs.gear.TextColor3 = HUD_COLORS.green
		else
			hudRefs.gear.Text = "R" .. currentRevGear; hudRefs.gear.TextColor3 = HUD_COLORS.red
		end

		hudRefs.bladeH.Size = UDim2.new((bladeHeight + 1) / 2, 0, 1, 0)
		hudRefs.bladeT.Size = UDim2.new((bladeTilt + 1) / 2, 0, 1, 0)
		hudRefs.tillerH.Size = UDim2.new((tillerHeight + 1) / 2, 0, 1, 0)

		hudRefs.spin.Text = tillerSpinning and "SPIN: ON" or "SPIN: OFF"
		hudRefs.spin.TextColor3 = tillerSpinning and HUD_COLORS.green or HUD_COLORS.dim
		hudRefs.wings.Text = tillerWingsDown and "WINGS: FLAT" or "WINGS: CLOSED"
		hudRefs.wings.TextColor3 = tillerWingsDown and HUD_COLORS.amber or HUD_COLORS.dim

	end

	-- REPLICATE
	local now = tick()
	if now - lastReplicateTime >= 0.05 then
		lastReplicateTime = now
		CFrameUpdate:FireServer(activeBison, finalCF)
	end
end)

----------------------------------------------------------------
-- OTHER PLAYERS: Smooth interpolation for remote snowcats
-- Instead of a single 30% lerp per network update (looks ~5Hz),
-- we store the target CFrame and interpolate toward it every frame.
----------------------------------------------------------------
local remoteBisonTargets = {} -- [model] = { target = CFrame, current = CFrame }

CFrameUpdate.OnClientEvent:Connect(function(model, cf)
	if model == activeBison then return end
	if model and model:IsA("Model") and model.PrimaryPart then
		if not remoteBisonTargets[model] then
			remoteBisonTargets[model] = { target = cf, current = model:GetPivot() }
		else
			remoteBisonTargets[model].target = cf
		end
	end
end)

-- Smooth interpolation loop for remote snowcats (runs at render FPS)
RunService.RenderStepped:Connect(function(dt)
	if next(remoteBisonTargets) == nil then return end
	for model, data in pairs(remoteBisonTargets) do
		if not model or not model.Parent or not model.PrimaryPart then
			remoteBisonTargets[model] = nil
		else
			-- Exponential smoothing: ~90% of the way to target in ~0.1s
			local alpha = 1 - math.exp(-15 * dt)
			data.current = data.current:Lerp(data.target, alpha)
			model:PivotTo(data.current)
		end
	end
end)

----------------------------------------------------------------
-- TOP-OF-SCREEN GROOMING OVERLAY (minigame feel)
----------------------------------------------------------------
local groomGui = nil
local groomRefs = {}
local groomFadeTimer = 0
local groomOverlayEnabled = true -- H key toggles this

local function createGroomOverlay()
	if groomGui then groomGui:Destroy() end

	local gui = Instance.new("ScreenGui")
	gui.Name = "BisonGroomOverlay"
	gui.ResetOnSpawn = false
	gui.DisplayOrder = 8
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.Parent = LocalPlayer.PlayerGui

	-- Single subtle text label — top center, no box, just text
	local label = Instance.new("TextLabel")
	label.Name = "GroomLabel"
	label.Size = UDim2.new(0, 400, 0, 24)
	label.Position = UDim2.new(0.5, 0, 0, 14)
	label.AnchorPoint = Vector2.new(0.5, 0)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.GothamBold
	label.TextSize = 13
	label.TextColor3 = Color3.fromRGB(200, 200, 210)
	label.TextTransparency = 0.15
	label.Text = ""
	label.Visible = false
	label.Parent = gui

	groomRefs = { label = label }
	groomGui = gui
end

local function destroyGroomOverlay()
	if groomGui then
		groomGui:Destroy()
		groomGui = nil
		groomRefs = {}
	end
end

local function updateGroomOverlay(slopeName, groomLevel)
	if not groomOverlayEnabled then return end

	if not groomGui or not groomRefs.label then
		createGroomOverlay()
	end

	local pct = math.clamp(groomLevel, 0, 100)
	groomRefs.label.Text = string.format("Grooming: %s — %.0f%%", string.upper(slopeName), pct)
	groomRefs.label.Visible = true
	groomFadeTimer = 4.0

	-- Color shifts subtly with progress
	if pct >= 90 then
		groomRefs.label.TextColor3 = Color3.fromRGB(100, 220, 160)
	elseif pct >= 50 then
		groomRefs.label.TextColor3 = Color3.fromRGB(200, 210, 180)
	else
		groomRefs.label.TextColor3 = Color3.fromRGB(200, 200, 210)
	end

	-- Also update the small bottom HUD bar
	if hudGui and hudRefs.groomText then
		hudRefs.groomText.Text = "GROOMING: " .. string.upper(slopeName)
		hudRefs.groomText.TextColor3 = pct >= 80 and HUD_COLORS.green or HUD_COLORS.amber
		hudRefs.groomFill.Size = UDim2.new(pct / 100, 0, 1, 0)
	end
end

-- Grooming overlay fade logic (called from Heartbeat)
local function updateGroomFade(dt)
	if groomFadeTimer > 0 then
		groomFadeTimer = groomFadeTimer - dt
		if groomFadeTimer <= 0 and groomRefs.label then
			groomRefs.label.Visible = false
			if hudGui and hudRefs.groomText then
				hudRefs.groomText.Text = "NO SLOPE"
				hudRefs.groomText.TextColor3 = HUD_COLORS.dim
				hudRefs.groomFill.Size = UDim2.new(0, 0, 1, 0)
			end
		end
	end
end

-- Hook into Heartbeat for fade timer
RunService.Heartbeat:Connect(function(dt)
	if groomFadeTimer <= 0 then return end
	updateGroomFade(dt)
end)

-- H key toggles grooming overlay
UserInputService.InputBegan:Connect(function(input, gameProcessed)
	if gameProcessed then return end
	if input.KeyCode == Enum.KeyCode.H then
		groomOverlayEnabled = not groomOverlayEnabled
		if not groomOverlayEnabled and groomRefs.label then
			groomRefs.label.Visible = false
		end
	end
end)

-- Wire the progress event to the overlay
if ProgressEvent then
	ProgressEvent.OnClientEvent:Connect(function(slopeName, groomLevel)
		updateGroomOverlay(slopeName, groomLevel)
		groomingFadeTimer = 3.0 -- also update bottom HUD fade
	end)
end

print("[BisonClient] Online. Walk up and press E. Hold Space to exit.")