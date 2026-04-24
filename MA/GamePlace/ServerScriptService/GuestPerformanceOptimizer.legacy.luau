--!strict

local ENABLE_GUEST_PERF_OPTIMIZER = true
if not ENABLE_GUEST_PERF_OPTIMIZER then
	return
end

local PhysicsService = game:GetService("PhysicsService")
local Workspace = game:GetService("Workspace")

local GUESTS_FOLDER = Workspace:WaitForChild("Guests")
local GUEST_COLLISION_GROUP = "Guests"
local COLLISION_REAPPLY_DELAYS = {0.5}
local REFRESH_INTERVAL_SECONDS = 6.0
local MAX_GUESTS_PER_PASS = 80
local guestCollisionGroupConfigured = false
local scanCursor = 1

-- FIX: Only disable states that are genuinely unused by the guest system.
-- Jumping, FallingDown, GettingUp, and Ragdoll are ALL required by GuestServer:
--   Jumping    → obstacle avoidance + pathfinding waypoint jumps
--   FallingDown → GuestServer explicitly enables this in OptimizeGuestModel
--   GettingUp  → crash recovery (RecoverGuest calls ChangeState(GettingUp))
--   Ragdoll    → crash ragdoll physics system
local DISABLED_STATES = {
	[Enum.HumanoidStateType.Climbing] = true,
	[Enum.HumanoidStateType.Flying] = true,
	[Enum.HumanoidStateType.Swimming] = true,
}

local function safeSetStateEnabled(humanoid: Humanoid, state: Enum.HumanoidStateType, enabled: boolean)
	pcall(function()
		humanoid:SetStateEnabled(state, enabled)
	end)
end

local function ensureGuestCollisionGroupConfigured()
	if guestCollisionGroupConfigured then
		return
	end
	guestCollisionGroupConfigured = true

	pcall(function()
		PhysicsService:RegisterCollisionGroup(GUEST_COLLISION_GROUP)
	end)

	-- CRITICAL FIX: Only disable GUEST-GUEST collisions.
	-- OLD CODE disabled collision between guests and ALL groups (including terrain),
	-- which caused guests to fall through the world even with CanCollide=true.
	-- Guests MUST collide with Default (terrain, buildings, ground) to walk properly.
	pcall(function()
		PhysicsService:CollisionGroupSetCollidable(GUEST_COLLISION_GROUP, GUEST_COLLISION_GROUP, false)
	end)
end

local function applyGuestPartPhysics(descendant: BasePart)
	ensureGuestCollisionGroupConfigured()
	-- CRITICAL FIX: Keep HumanoidRootPart collision ON
	-- The old code disabled ALL collision, causing guests to clip through floors.
	-- HRP must collide with terrain for Humanoid:MoveTo to work.
	if descendant.Name == "HumanoidRootPart" then
		descendant.CanCollide = true
		descendant.CanQuery = true
		descendant.CanTouch = false
		descendant.CastShadow = false
	else
		descendant.CanCollide = false
		descendant.CanQuery = false
		descendant.CanTouch = false
		descendant.CastShadow = false
		descendant.Massless = true
	end
	pcall(function()
		descendant.CollisionGroup = GUEST_COLLISION_GROUP
	end)
	if descendant:IsA("MeshPart") then
		pcall(function()
			descendant.CollisionFidelity = Enum.CollisionFidelity.Box
		end)
	end
end

local function optimizePart(descendant: Instance)
	if descendant:IsA("BasePart") then
		applyGuestPartPhysics(descendant)
	end
end

local function reapplyGuestModelPhysics(model: Model)
	for _, descendant in ipairs(model:GetDescendants()) do
		optimizePart(descendant)
	end
end

local function optimizeHumanoid(model: Model)
	if model:GetAttribute("_GuestHumanoidOptimized") then return end

	local humanoid = model:FindFirstChildOfClass("Humanoid")
	if not humanoid then return end

	humanoid.AutoJumpEnabled = false
	humanoid.AutomaticScalingEnabled = false
	humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
	humanoid.HealthDisplayDistance = 0
	humanoid.NameDisplayDistance = 0
	-- FIX: Do NOT zero JumpPower/JumpHeight.
	-- GuestServer uses hum.Jump = true for obstacle avoidance (MoveGuestTo line 3502),
	-- pathfinding jump waypoints (line 3681), and stuck detection (line 3810).
	-- Zeroing these caused guests to get permanently stuck on any terrain step.

	for state in pairs(DISABLED_STATES) do
		safeSetStateEnabled(humanoid, state, false)
	end

	reapplyGuestModelPhysics(model)
	model.DescendantAdded:Connect(optimizePart)

	for _, delaySeconds in ipairs(COLLISION_REAPPLY_DELAYS) do
		task.delay(delaySeconds, function()
			if model.Parent then
				reapplyGuestModelPhysics(model)
			end
		end)
	end

	model:SetAttribute("_GuestHumanoidOptimized", true)
end

local function onGuestAdded(guest: Instance)
	if guest:IsA("Model") then
		task.defer(optimizeHumanoid, guest)
	end
end

local function partNeedsCollisionRefresh(part: Instance?): boolean
	if part == nil or not part:IsA("BasePart") then
		return false
	end
	-- CRITICAL FIX: HRP SHOULD have CanCollide + CanQuery true
	if part.Name == "HumanoidRootPart" then
		return not part.CanCollide or not part.CanQuery or part.CollisionGroup ~= GUEST_COLLISION_GROUP
	end
	-- Body parts should have everything disabled
	return part.CanCollide
		or part.CanQuery
		or part.CanTouch
		or part.CollisionGroup ~= GUEST_COLLISION_GROUP
end

task.spawn(function()
	while true do
		task.wait(REFRESH_INTERVAL_SECONDS)
		local guests = GUESTS_FOLDER:GetChildren()
		local guestCount = #guests
		if guestCount == 0 then
			scanCursor = 1
			continue
		end

		local scans = math.min(guestCount, MAX_GUESTS_PER_PASS)
		if scanCursor > guestCount then
			scanCursor = 1
		end

		for step = 1, scans do
			local index = ((scanCursor + step - 2) % guestCount) + 1
			local guest = guests[index]
			if guest and guest:IsA("Model") then
				local torso = guest:FindFirstChild("Torso", true)
					or guest:FindFirstChild("UpperTorso", true)
					or guest:FindFirstChild("LowerTorso", true)
				local root = guest:FindFirstChild("HumanoidRootPart", true)
				if partNeedsCollisionRefresh(torso) or partNeedsCollisionRefresh(root) then
					reapplyGuestModelPhysics(guest)
				end
			end
		end

		scanCursor = ((scanCursor + scans - 1) % guestCount) + 1
	end
end)

for _, guest in ipairs(GUESTS_FOLDER:GetChildren()) do
	onGuestAdded(guest)
end

GUESTS_FOLDER.ChildAdded:Connect(onGuestAdded)
