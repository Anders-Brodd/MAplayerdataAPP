local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local SlotData = ReplicatedStorage:WaitForChild("SlotData", 10)
local GuestConfig = require(ReplicatedStorage:WaitForChild("Guest"):WaitForChild("GuestConfig"))
local GUEST_FOLDER_NAME = "Guests"
local BASE_TRIMS_PER_TICK = 4
local MAX_TRIMS_PER_TICK = 24
local TICK_INTERVAL = 1.0

local function getGuestFolder()
	return Workspace:FindFirstChild(GUEST_FOLDER_NAME)
end

local function getSlotOwnerId()
	if not SlotData then
		return nil
	end
	local userIdValue = SlotData:FindFirstChild("UserId")
	if userIdValue and userIdValue:IsA("IntValue") then
		local userId = tonumber(userIdValue.Value)
		if userId and userId > 0 then
			return userId
		end
	end
	return nil
end

local function getOwnerPlayer()
	local ownerUserId = getSlotOwnerId()
	if ownerUserId then
		local ownerPlayer = Players:GetPlayerByUserId(ownerUserId)
		if ownerPlayer then
			return ownerPlayer
		end
	end
	return Players:GetPlayers()[1]
end

local function getConfiguredCap()
	local spawnCfg = GuestConfig and GuestConfig.Spawn or nil
	if type(spawnCfg) ~= "table" then
		return 0
	end
	return math.max(0, math.floor((tonumber(spawnCfg.MaxGlobalGuests) or 0) + 0.5))
end

local function clampDesiredCap(rawCap)
	local cap = math.max(0, math.floor((tonumber(rawCap) or 0) + 0.5))
	local configuredCap = getConfiguredCap()
	if configuredCap > 0 then
		cap = (cap > 0) and math.min(cap, configuredCap) or configuredCap
	end
	return cap
end

local function getDesiredCap()
	local ownerPlayer = getOwnerPlayer()
	local resortOpen = true
	if SlotData then
		resortOpen = SlotData:GetAttribute("ResortOpen") ~= false
	end
	if not resortOpen then
		return 0
	end
	if not ownerPlayer then
		return nil
	end

	local capEnabled = ownerPlayer:GetAttribute("GuestCapEnabled") == true
	if not capEnabled then
		return nil
	end

	local userCap = tonumber(ownerPlayer:GetAttribute("GuestCap")) or 0
	if userCap <= 0 then
		userCap = getConfiguredCap()
	end
	if userCap <= 0 then
		userCap = 500
	end
	return clampDesiredCap(userCap)
end

local function getNumericOwnerAttr(model)
	local keys = { "OwnerId", "Owner", "ResortOwner", "PlayerUserId" }
	for _, key in ipairs(keys) do
		local raw = model:GetAttribute(key)
		local value = tonumber(raw)
		if value then
			return value
		end
	end
	return nil
end

local function guestBelongsToOwner(model, ownerUserId)
	if not model or not model:IsA("Model") then
		return false
	end
	if not ownerUserId then
		return true
	end
	local guestOwner = getNumericOwnerAttr(model)
	if guestOwner == nil then
		return true
	end
	return guestOwner == ownerUserId
end

local function collectOwnedGuests()
	local folder = getGuestFolder()
	if not folder then
		return {}
	end
	local ownerUserId = getSlotOwnerId()
	local guests = {}
	for _, child in ipairs(folder:GetChildren()) do
		if guestBelongsToOwner(child, ownerUserId) then
			table.insert(guests, child)
		end
	end
	return guests
end

local function scoreGuestForTrim(guest)
	local score = 0
	if guest:GetAttribute("Dismissed") then
		score += 1000
	end
	if guest:GetAttribute("Leaving") then
		score += 500
	end
	local state = string.upper(tostring(guest:GetAttribute("State") or ""))
	if state == "IDLE" or state == "DECIDING" then
		score += 100
	elseif state == "EXITING" or state == "LEAVING" then
		score += 250
	elseif state:find("LIFT", 1, true) ~= nil then
		score -= 200
	elseif state:find("SKI", 1, true) ~= nil then
		score -= 150
	end
	local hrp = guest:FindFirstChild("HumanoidRootPart")
	if hrp then
		score += math.clamp(hrp.Position.Magnitude / 1000, 0, 50)
	end
	return score
end

local function despawnGuest(guest)
	if not guest or not guest.Parent then
		return false
	end
	guest:SetAttribute("Dismissed", true)
	guest:SetAttribute("Leaving", true)
	local hum = guest:FindFirstChildOfClass("Humanoid")
	if hum then
		hum.Health = 0
	end
	guest:Destroy()
	return true
end

local function getTrimBudget(overflow)
	local overflowN = math.max(0, math.floor(tonumber(overflow) or 0))
	if overflowN <= 0 then
		return 0
	end
	local adaptive = math.ceil(overflowN * 0.2)
	return math.clamp(math.max(BASE_TRIMS_PER_TICK, adaptive), BASE_TRIMS_PER_TICK, MAX_TRIMS_PER_TICK)
end

local function enforceGuestCap()
	local desiredCap = getDesiredCap()
	if desiredCap == nil then
		return
	end
	local guests = collectOwnedGuests()
	local overflow = #guests - desiredCap
	if overflow <= 0 then
		return
	end
	table.sort(guests, function(a, b)
		return scoreGuestForTrim(a) > scoreGuestForTrim(b)
	end)
	local trims = math.min(overflow, getTrimBudget(overflow))
	for index = 1, trims do
		despawnGuest(guests[index])
	end
end

local function bindOwnerSignals(player)
	player:GetAttributeChangedSignal("GuestCap"):Connect(function()
		task.defer(enforceGuestCap)
	end)
	player:GetAttributeChangedSignal("GuestCapEnabled"):Connect(function()
		task.defer(enforceGuestCap)
	end)
end

for _, player in ipairs(Players:GetPlayers()) do
	bindOwnerSignals(player)
end

Players.PlayerAdded:Connect(function(player)
	bindOwnerSignals(player)
	task.defer(enforceGuestCap)
end)

if SlotData then
	SlotData:GetAttributeChangedSignal("ResortOpen"):Connect(function()
		task.defer(enforceGuestCap)
	end)
end

Workspace.ChildAdded:Connect(function(child)
	if child.Name == GUEST_FOLDER_NAME then
		task.defer(enforceGuestCap)
	end
end)

while true do
	enforceGuestCap()
	task.wait(TICK_INTERVAL)
end