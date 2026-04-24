-- Disabled after guest rollback.

local ENABLE_GUEST_HOUSE_EXIT_HOTFIX = true
if not ENABLE_GUEST_HOUSE_EXIT_HOTFIX then
	return
end

local Workspace = game:GetService("Workspace")

local placedObjects = Workspace:WaitForChild("PlacedObjects")
local guestsFolder = Workspace:WaitForChild("Guests")

local CHECK_INTERVAL = 1.25
local STUCK_SECONDS = 1.5
local MIN_PROGRESS = 0.35
local RESCUE_COOLDOWN = 2.5
local HOUSE_PADDING = Vector3.new(2, 3, 2)
local MAX_GUESTS_PER_PASS = 85
local scanCursor = 1

local houseCache = {}
local guestTrack = {}

local function flatten(vector)
	return Vector3.new(vector.X, 0, vector.Z)
end

local function isHouse(model)
	return model:IsA("Model") and (model:GetAttribute("Type") == "House" or model:GetAttribute("Type") == "Hotel")
end

local function getDoorBounds(door)
	if door:IsA("Model") then
		return door:GetBoundingBox()
	elseif door:IsA("BasePart") then
		return door.CFrame, door.Size
	end
	return nil
end

local function buildHouseInfo(model)
	local door = model:FindFirstChild("Door", true)
	if not door then
		return nil
	end

	local doorCf, doorSize = getDoorBounds(door)
	if not doorCf or not doorSize then
		return nil
	end

	local boundsCf, boundsSize = model:GetBoundingBox()
	local outward = flatten(doorCf.Position - boundsCf.Position)
	if outward.Magnitude < 0.1 then
		outward = -flatten(boundsCf.LookVector)
	end
	if outward.Magnitude < 0.1 then
		return nil
	end
	outward = outward.Unit

	local offset = math.max(4, math.max(doorSize.X, doorSize.Z) * 0.8)
	local doorCenter = doorCf.Position
	local groundY = math.max(boundsCf.Position.Y, doorCenter.Y)
	local outsideTarget = doorCenter + outward * (offset + 2) + Vector3.new(0, 1.5, 0)
	outsideTarget = Vector3.new(outsideTarget.X, groundY + 1.5, outsideTarget.Z)

	return {
		model = model,
		boundsCf = boundsCf,
		boundsSize = boundsSize,
		outsideTarget = outsideTarget,
		outward = outward,
	}
end

local function refreshHouseCache()
	table.clear(houseCache)
	for _, child in ipairs(placedObjects:GetChildren()) do
		if isHouse(child) then
			local info = buildHouseInfo(child)
			if info then
				houseCache[child] = info
			end
		end
	end
end

local function isPointInsideHouse(info, position)
	local localPos = info.boundsCf:PointToObjectSpace(position)
	local half = info.boundsSize * 0.5 + HOUSE_PADDING
	return math.abs(localPos.X) <= half.X and math.abs(localPos.Y) <= half.Y and math.abs(localPos.Z) <= half.Z
end

local function getContainingHouse(position)
	for _, info in pairs(houseCache) do
		if isPointInsideHouse(info, position) then
			return info
		end
	end
	return nil
end

local function rescueGuest(guest, humanoid, rootPart, info, now)
	rootPart.CFrame = CFrame.new(info.outsideTarget, info.outsideTarget + info.outward)
	humanoid:MoveTo(info.outsideTarget + info.outward * 8)
	guestTrack[guest] = {
		lastPosition = info.outsideTarget,
		stuckSince = nil,
		rescuedAt = now,
	}
end

refreshHouseCache()
placedObjects.ChildAdded:Connect(function(child)
	if isHouse(child) then
		task.defer(refreshHouseCache)
	end
end)
placedObjects.ChildRemoved:Connect(function(child)
	if houseCache[child] then
		task.defer(refreshHouseCache)
	end
end)

while true do
	task.wait(CHECK_INTERVAL)
	local now = os.clock()
	local guests = guestsFolder:GetChildren()
	local guestCount = #guests
	if guestCount <= 0 then
		scanCursor = 1
		continue
	end

	if scanCursor > guestCount then
		scanCursor = 1
	end

	local scans = math.min(guestCount, MAX_GUESTS_PER_PASS)
	for step = 1, scans do
		local index = ((scanCursor + step - 2) % guestCount) + 1
		local guest = guests[index]
		if not guest or not guest:IsA("Model") then
			continue
		end

		local humanoid = guest:FindFirstChildOfClass("Humanoid")
		local rootPart = guest:FindFirstChild("HumanoidRootPart", true)
		if not humanoid or not rootPart or not rootPart:IsA("BasePart") then
			continue
		end

		local info = getContainingHouse(rootPart.Position)
		local track = guestTrack[guest]
		local lastPosition = track and track.lastPosition or rootPart.Position
		local moved = flatten(rootPart.Position - lastPosition).Magnitude

		if not info then
			guestTrack[guest] = {
				lastPosition = rootPart.Position,
				stuckSince = nil,
				rescuedAt = track and track.rescuedAt or nil,
			}
			continue
		end

		local walkToPoint = humanoid.WalkToPoint
		local wantsOutside = walkToPoint.Magnitude > 0 and not isPointInsideHouse(info, walkToPoint)
		local stuckSince = track and track.stuckSince or nil
		local canRescueAgain = not track or not track.rescuedAt or (now - track.rescuedAt) >= RESCUE_COOLDOWN
		local desiredDirection = flatten(walkToPoint - info.boundsCf.Position)
		local badExitSide = desiredDirection.Magnitude > 0.1 and desiredDirection.Unit:Dot(info.outward) < -0.2

		if wantsOutside and canRescueAgain and badExitSide then
			rescueGuest(guest, humanoid, rootPart, info, now)
			continue
		end

		if wantsOutside and moved < MIN_PROGRESS then
			if not stuckSince then
				stuckSince = now
			elseif canRescueAgain and (now - stuckSince) >= STUCK_SECONDS then
				rescueGuest(guest, humanoid, rootPart, info, now)
				continue
			end
		else
			stuckSince = nil
		end

		guestTrack[guest] = {
			lastPosition = rootPart.Position,
			stuckSince = stuckSince,
			rescuedAt = track and track.rescuedAt or nil,
		}
	end

	scanCursor = ((scanCursor + scans - 1) % guestCount) + 1
end
