--[[
	GuestPhysics — Extracted from GuestServer V10.0
	
	Handles all guest model physics: collision, ground resolution, network ownership.
	
	KEY FIXES FROM OLD SYSTEM:
	1. HumanoidRootPart NOW keeps CanCollide = true so guests don't clip through terrain/floors
	2. Only cosmetic parts (accessories, mesh parts) have CanCollide disabled
	3. Ground snapping uses proper raycast from above instead of fighting disabled collisions
	4. Network ownership is applied once on spawn, not re-asserted every second
]]

local PhysicsService = game:GetService("PhysicsService")
local Workspace = game:GetService("Workspace")

local GuestPhysics = {}

-- Constants
local GUEST_COLLISION_GROUP = "Guests"
local MAX_GUEST_ACCESSORIES = 6
local TERRAIN_RAY_LENGTH = 200
local GROUND_SNAP_THRESHOLD = 4.0  -- studs above ground before we snap
local GROUND_SNAP_COOLDOWN = 0.5   -- seconds between snaps to prevent jitter
local QUEUE_COLLISION_STATES = {
	WaitingForLift = true,
	BoardingLift = true,
	RidingLift = true,
}

local function isCollisionGroupRegistered(name: string): boolean
	local okRegistered, registered = pcall(function()
		return PhysicsService:IsCollisionGroupRegistered(name)
	end)
	if okRegistered then
		return registered == true
	end

	local okGroups, groups = pcall(function()
		return PhysicsService:GetRegisteredCollisionGroups()
	end)
	if okGroups and type(groups) == "table" then
		for _, info in ipairs(groups) do
			if info and info.name == name then
				return true
			end
		end
	end
	return false
end

-- Ensure collision group exists
local function ensureCollisionGroup()
	if not isCollisionGroupRegistered(GUEST_COLLISION_GROUP) then
		pcall(function()
			PhysicsService:RegisterCollisionGroup(GUEST_COLLISION_GROUP)
		end)
		if not isCollisionGroupRegistered(GUEST_COLLISION_GROUP) then
			pcall(function()
				PhysicsService:CreateCollisionGroup(GUEST_COLLISION_GROUP)
			end)
		end
	end

	-- Guests don't collide with each other (performance)
	pcall(function()
		PhysicsService:CollisionGroupSetCollidable(GUEST_COLLISION_GROUP, GUEST_COLLISION_GROUP, false)
	end)
end
ensureCollisionGroup()

--- Allowed accessory types for guests (reduces part count)
local ALLOWED_ACCESSORY_TYPES = {
	[Enum.AccessoryType.Shirt] = true,
	[Enum.AccessoryType.Pants] = true,
	[Enum.AccessoryType.Jacket] = true,
	[Enum.AccessoryType.Sweater] = true,
	[Enum.AccessoryType.Shorts] = true,
	[Enum.AccessoryType.DressSkirt] = true,
	[Enum.AccessoryType.Hair] = true,
	[Enum.AccessoryType.Face] = true,
}

local ACCESSORY_PRIORITY = {}
do
	local priorities = {
		Shirt = 1, Pants = 1, Jacket = 2, Sweater = 2,
		Shorts = 2, DressSkirt = 2, Hair = 1, Hat = 3,
		Face = 4, Neck = 5, Shoulder = 6, Front = 7,
		Back = 8, Waist = 9,
	}
	for name, priority in pairs(priorities) do
		local enumVal = Enum.AccessoryType[name]
		if enumVal then
			ACCESSORY_PRIORITY[enumVal] = priority
		end
	end
end

--[[
	KEY FIX: Apply physics to guest parts with PROPER collision handling
	
	OLD BEHAVIOR (broken):
		- ALL parts had CanCollide = false
		- Guests clipped through floors, walls, terrain
		- Required aggressive ground snapping that caused jitter
	
	NEW BEHAVIOR:
		- HumanoidRootPart: CanCollide = TRUE (so Humanoid physics work)
		- Other body parts: CanCollide = false (reduce collision load) 
		- All parts: CollisionGroup = "Guests" (no guest-guest collision)
		- All non-root parts: Massless = true (performance)
		- No CanQuery/CanTouch on body (only HRP stays queryable)
]]
local function shouldUseQueueCollisionMode(model: Model): boolean
	if not model then
		return false
	end
	if model:GetAttribute("LiftQueueIndex") ~= nil then
		return true
	end
	return QUEUE_COLLISION_STATES[model:GetAttribute("State")] == true
end

local function reapplyModelPhysics(model: Model)
	if not model or not model.Parent then
		return
	end
	local queueCollisionMode = shouldUseQueueCollisionMode(model)
	for _, inst in ipairs(model:GetDescendants()) do
		if inst:IsA("BasePart") then
			local isAcc = inst:FindFirstAncestorOfClass("Accessory") ~= nil
			GuestPhysics.ApplyPartPhysics(inst, inst.Name == "HumanoidRootPart", isAcc, queueCollisionMode)
		end
	end
end

function GuestPhysics.ApplyPartPhysics(inst: BasePart, isHumanoidRootPart: boolean, isAccessory: boolean, queueCollisionMode: boolean?)
	if not inst or not inst:IsA("BasePart") then return end
	
	inst.CollisionGroup = GUEST_COLLISION_GROUP
	inst.CastShadow = false
	inst.CanTouch = false
	
	if isAccessory then
		inst.CanCollide = false
		inst.CanQuery = false
		inst.Massless = true
	elseif isHumanoidRootPart then
		local disableRootCollision = queueCollisionMode == true
		inst.CanCollide = not disableRootCollision
		inst.CanQuery = true
	else
		-- Keep the root collidable, but turn off crowd shoulder collisions while queued.
		inst.CanCollide = not queueCollisionMode
		inst.CanQuery = false
		inst.Massless = true
	end
end

--- Optimize a guest model's physics and accessories
function GuestPhysics.OptimizeModel(model: Model)
	if not model then return end
	
	local accessories = {}
	
	for _, inst in ipairs(model:GetDescendants()) do
		if inst:IsA("Accessory") then
			local accessoryType = nil
			pcall(function() accessoryType = inst.AccessoryType end)
			if accessoryType and ALLOWED_ACCESSORY_TYPES[accessoryType] then
				table.insert(accessories, inst)
			else
				inst:Destroy()
			end
		end
	end
	reapplyModelPhysics(model)
	
	-- Watch for new parts added (e.g., ski equipment)
	if not model:GetAttribute("_PhysicsWatcherBound") then
		model:SetAttribute("_PhysicsWatcherBound", true)
		model.DescendantAdded:Connect(function(desc)
			if desc:IsA("BasePart") then
				task.defer(function()
					if model.Parent and desc.Parent then
						local isAcc = desc:FindFirstAncestorOfClass("Accessory") ~= nil
						GuestPhysics.ApplyPartPhysics(desc, desc.Name == "HumanoidRootPart", isAcc, shouldUseQueueCollisionMode(model))
					end
				end)
			end
		end)
		model:GetAttributeChangedSignal("LiftQueueIndex"):Connect(function()
			task.defer(function()
				reapplyModelPhysics(model)
			end)
		end)
		model:GetAttributeChangedSignal("State"):Connect(function()
			task.defer(function()
				reapplyModelPhysics(model)
			end)
		end)
	end
	
	-- Delayed re-application for parts that load late
	for _, delaySeconds in ipairs({ 0.5 }) do
		task.delay(delaySeconds, function()
			if not model or not model.Parent then return end
			reapplyModelPhysics(model)
		end)
	end
	
	-- Trim excess accessories
	table.sort(accessories, function(a, b)
		local pa, pb = 20, 20
		pcall(function() pa = ACCESSORY_PRIORITY[a.AccessoryType] or 20 end)
		pcall(function() pb = ACCESSORY_PRIORITY[b.AccessoryType] or 20 end)
		if pa ~= pb then return pa < pb end
		return a.Name < b.Name
	end)
	for i = MAX_GUEST_ACCESSORIES + 1, #accessories do
		if accessories[i] and accessories[i].Parent then
			accessories[i]:Destroy()
		end
	end
	
	-- Disable unnecessary humanoid states
	local hum = model:FindFirstChildOfClass("Humanoid")
	if hum then
		pcall(function() hum:SetStateEnabled(Enum.HumanoidStateType.Climbing, false) end)
		pcall(function() hum:SetStateEnabled(Enum.HumanoidStateType.Swimming, false) end)
		pcall(function() hum:SetStateEnabled(Enum.HumanoidStateType.Seated, false) end)
		pcall(function() hum:SetStateEnabled(Enum.HumanoidStateType.FallingDown, true) end)
	end
end

--- Apply network ownership (player-owned for reliable Humanoid:MoveTo)
function GuestPhysics.ApplyNetworkOwnership(rootPart: BasePart, ownerPlayer: Player?)
	if not rootPart or not rootPart.Parent then return end
	pcall(function()
		rootPart:SetNetworkOwner(ownerPlayer) -- Player ownership
	end)
end

--- Sanitize a HumanoidDescription for consistent guest sizing
function GuestPhysics.SanitizeDescription(desc: HumanoidDescription)
	if not desc then return end
	pcall(function() desc.HeadScale = 1 end)
	pcall(function() desc.HeightScale = 1 end)
	pcall(function() desc.WidthScale = 1 end)
	pcall(function() desc.DepthScale = 1 end)
	pcall(function() desc.BodyTypeScale = 0 end)
	pcall(function() desc.ProportionScale = 0 end)
end

--[[
	Ground resolution — find where the ground is below/near a position.
	
	KEY FIX: Uses proper downward raycast that INCLUDES terrain,
	not the old broken system that fought with disabled collisions.
]]
function GuestPhysics.GetGroundPosition(position: Vector3, ignoreList: {Instance}?): Vector3
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = ignoreList or {}
	params.IgnoreWater = true
	
	-- Cast downward from well above
	local origin = Vector3.new(position.X, position.Y + 50, position.Z)
	local result = Workspace:Raycast(origin, Vector3.new(0, -TERRAIN_RAY_LENGTH, 0), params)
	
	if result then
		return result.Position + Vector3.new(0, 3, 0) -- Character half-height offset
	end
	
	-- Fallback: use terrain height
	local terrainY = GuestPhysics.GetTerrainY(position.X, position.Z)
	return Vector3.new(position.X, terrainY + 3, position.Z)
end

--- Get terrain height at a given XZ position
function GuestPhysics.GetTerrainY(x: number, z: number): number
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

--[[
	Ground snap — gently correct a guest that's floating or stuck underground.
	
	KEY FIXES:
	1. Only snaps if guest is significantly off-ground (>4 studs)
	2. Has built-in cooldown to prevent snap-jitter loops
	3. Does NOT snap during certain states (riding lift, skiing)
	4. Uses velocity check — only snaps when guest is relatively still
]]
function GuestPhysics.SnapToGroundIfNeeded(data: any, threshold: number?): boolean
	local root = data and data.Root
	local hum = data and data.Humanoid
	if not root or not root.Parent or not hum then return false end
	
	-- Don't snap while actively skiing or riding lift
	local state = data.State or ""
	if state == "RidingLift" or state == "SkiingDown" or state == "Crashed" then
		return false
	end
	
	-- Cooldown to prevent jitter
	local now = tick()
	if data._lastGroundSnap and (now - data._lastGroundSnap) < GROUND_SNAP_COOLDOWN then
		return false
	end
	
	-- Check if actually needs snapping
	local pos = root.Position
	local groundY = GuestPhysics.GetTerrainY(pos.X, pos.Z)
	local heightAboveGround = pos.Y - groundY
	local snapThreshold = threshold or GROUND_SNAP_THRESHOLD
	
	-- Only snap if floating too high or fallen below terrain
	if heightAboveGround > snapThreshold or heightAboveGround < -1 then
		-- Check velocity — don't snap while moving fast (e.g., jumping)
		local vel = root.AssemblyLinearVelocity
		local vertSpeed = math.abs(vel.Y)
		if vertSpeed > 10 then
			return false  -- Let physics handle it
		end
		
		-- Perform the snap
		local groundPos = GuestPhysics.GetGroundPosition(pos, {data.Model})
		local forward = root.CFrame.LookVector
		root.CFrame = CFrame.lookAt(groundPos, groundPos + forward)
		root.AssemblyLinearVelocity = Vector3.zero
		root.AssemblyAngularVelocity = Vector3.zero
		
		data._lastGroundSnap = now
		return true
	end
	
	return false
end

--- Check if a guest has fallen out of the map (below terrain - 50 studs)
function GuestPhysics.HasFallenOutOfMap(data: any): boolean
	local root = data and data.Root
	if not root then return true end
	
	local pos = root.Position
	local terrainY = GuestPhysics.GetTerrainY(pos.X, pos.Z)
	return pos.Y < (terrainY - 50)
end

--- Prepare a guest for lift riding (disable physics interference)
function GuestPhysics.PrepareForLiftRide(data: any)
	local root = data and data.Root
	local hum = data and data.Humanoid
	if not root or not hum then return end
	
	data.State = "RidingLift"
	hum.PlatformStand = true
	hum.AutoRotate = false
	hum.Sit = false
	root.AssemblyLinearVelocity = Vector3.zero
	root.AssemblyAngularVelocity = Vector3.zero
	-- During lift ride, root also shouldn't collide with lift geometry
	root.CanCollide = false
end

--- Restore guest physics after lift ride
function GuestPhysics.RestoreAfterLiftRide(data: any)
	local root = data and data.Root
	local hum = data and data.Humanoid
	local model = data and data.Model
	if not root or not hum then return end
	
	hum.PlatformStand = false
	hum.Sit = false
	hum.AutoRotate = true
	hum:ChangeState(Enum.HumanoidStateType.GettingUp)
	root.Anchored = false
	root.CanCollide = true  -- Restore collision for walking
	root.AssemblyLinearVelocity = Vector3.zero
	root.AssemblyAngularVelocity = Vector3.zero
	if model and model:IsA("Model") then
		model:SetAttribute("RidingLift", nil)
		model:SetAttribute("RidingChair", nil)
		model:SetAttribute("RidingSeat", nil)
		model:SetAttribute("LiftQueueIndex", nil)
		local currentState = model:GetAttribute("State")
		if currentState == "RidingLift" or currentState == "BoardingLift" or currentState == "WaitingForLift" or currentState == "UnloadingLift" then
			model:SetAttribute("State", "Walking")
		end
	end
	if data then
		data.State = "Walking"
		data.UnloadTimer = nil
		data.MoveTarget = nil
		data.Waypoints = nil
		data.WaypointIndex = nil
		data.MoveResumeTarget = nil
		data.MoveResumeCallback = nil
		data.MoveCallback = nil
		data.LastMoveCommandTime = nil
		data.LastMoveCommandTarget = nil
		data.MoveProgressBaselineDist = nil
		data.LastProgressTime = nil
		data.NextStuckDetourAt = nil
		data.NextStuckCheckAt = nil
		data.StuckTimer = 0
		data.LastMovePos = nil
	end
	GuestPhysics.ApplyNetworkOwnership(root)
end

--- Prepare a guest for skiing (disable collision for smooth terrain follow)
function GuestPhysics.PrepareForSkiing(data: any)
	local root = data and data.Root
	local hum = data and data.Humanoid
	if not root or not hum then return end
	
	hum.PlatformStand = true
	hum.AutoRotate = false
	-- During skiing, we control position directly
	root.CanCollide = false
end

--- Restore guest physics after skiing
function GuestPhysics.RestoreAfterSkiing(data: any)
	local root = data and data.Root
	local hum = data and data.Humanoid
	if not root or not hum then return end
	
	hum.PlatformStand = false
	hum.AutoRotate = true
	root.CanCollide = true
	root.Anchored = false
	GuestPhysics.ApplyNetworkOwnership(root)
end

return GuestPhysics