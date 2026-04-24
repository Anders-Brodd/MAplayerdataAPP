-- Disabled after guest rollback.

local ENABLE_GUEST_SAFETY_NET_HOTFIX = false
if not ENABLE_GUEST_SAFETY_NET_HOTFIX then
	return
end

local Workspace = game:GetService("Workspace")

local PLACED_OBJECTS_NAME = "PlacedObjects"
local GUESTS_FOLDER_NAME = "Guests"
local NET_NAME = "SafetyNet"
local GUEST_STATES_TO_FREE = {
	Walking = true,
	Deciding = true,
	Idle = true,
}

local overlapParams = OverlapParams.new()
overlapParams.FilterType = Enum.RaycastFilterType.Exclude

local CHECK_INTERVAL = 1.2
local MAX_GUESTS_PER_PASS = 70
local scanCursor = 1

local function isSafetyNet(part)
	return part and part:IsA("BasePart") and part.Name == NET_NAME
end

local function makeSafetyNetPassThrough(part)
	if not isSafetyNet(part) then
		return
	end
	part.CanCollide = false
	part.CanTouch = false
	part.Massless = true
end

local function sweepSafetyNets(root)
	for _, desc in ipairs(root:GetDescendants()) do
		makeSafetyNetPassThrough(desc)
	end
end

local function getGuestRoot(model)
	if not model or not model:IsA("Model") then
		return nil, nil
	end
	return model:FindFirstChild("HumanoidRootPart"), model:FindFirstChildOfClass("Humanoid")
end

local function findBlockingSafetyNet(guest, hrp)
	overlapParams.FilterDescendantsInstances = {guest}
	local parts = Workspace:GetPartBoundsInBox(hrp.CFrame, hrp.Size + Vector3.new(1.5, 2, 1.5), overlapParams)
	for _, part in ipairs(parts) do
		if isSafetyNet(part) then
			return part
		end
	end
	return nil
end

local function nudgeGuestOutOfNet(guest, hrp, humanoid, net)
	local away = hrp.Position - net.Position
	away = Vector3.new(away.X, 0, away.Z)
	if away.Magnitude < 0.25 then
		away = Vector3.new(net.CFrame.RightVector.X, 0, net.CFrame.RightVector.Z)
	end
	if away.Magnitude < 0.25 then
		away = Vector3.zAxis
	end
	away = away.Unit

	local destination = hrp.Position + (away * 8) + Vector3.new(0, 2.5, 0)
	guest:PivotTo(CFrame.new(destination, destination + away))
	humanoid:MoveTo(destination + (away * 6))
end

local function shouldFreeGuest(guest)
	if guest:GetAttribute("IsSkiing") or guest:GetAttribute("RidingLift") then
		return false
	end
	local state = guest:GetAttribute("State")
	return GUEST_STATES_TO_FREE[state] == true
end

local function unstickGuestsFromSafetyNets()
	local guestsFolder = Workspace:FindFirstChild(GUESTS_FOLDER_NAME)
	if not guestsFolder then
		return
	end

	local guests = guestsFolder:GetChildren()
	local guestCount = #guests
	if guestCount <= 0 then
		scanCursor = 1
		return
	end

	if scanCursor > guestCount then
		scanCursor = 1
	end

	local scans = math.min(guestCount, MAX_GUESTS_PER_PASS)
	for step = 1, scans do
		local index = ((scanCursor + step - 2) % guestCount) + 1
		local guest = guests[index]
		if guest and shouldFreeGuest(guest) then
			local hrp, humanoid = getGuestRoot(guest)
			if hrp and humanoid and humanoid.Health > 0 then
				local horizontalVelocity = Vector3.new(hrp.AssemblyLinearVelocity.X, 0, hrp.AssemblyLinearVelocity.Z).Magnitude
				if horizontalVelocity < 3 then
					local blockingNet = findBlockingSafetyNet(guest, hrp)
					if blockingNet then
						nudgeGuestOutOfNet(guest, hrp, humanoid, blockingNet)
					end
				end
			end
		end
	end

	scanCursor = ((scanCursor + scans - 1) % guestCount) + 1
end

local placedObjects = Workspace:FindFirstChild(PLACED_OBJECTS_NAME)
if placedObjects then
	sweepSafetyNets(placedObjects)
	placedObjects.DescendantAdded:Connect(function(desc)
		makeSafetyNetPassThrough(desc)
	end)
end

Workspace.DescendantAdded:Connect(function(desc)
	makeSafetyNetPassThrough(desc)
end)

task.spawn(function()
	while true do
		unstickGuestsFromSafetyNets()
		task.wait(CHECK_INTERVAL)
	end
end)
