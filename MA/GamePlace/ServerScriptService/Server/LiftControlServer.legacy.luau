--[[
	SCRIPT: LiftControlServer
	WHAT IT DOES:
	Manages the server-side state of all ski lifts. Handles initialization, degradation over time (condition decay), proximity prompts for control panels, and processes client requests for premium toggles.
	
	WHAT WAS FIXED:
	- ADDED: Magic Carpet Support. `SetupPanel` and `ScanModelForPanels` now explicitly allow models with `Type == "Carpet"` to initialize and be controlled.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ServerScriptService = game:GetService("ServerScriptService")
local Workspace = game:GetService("Workspace")

local MultiplayerPermissions = require(ServerScriptService.Server:WaitForChild("MultiplayerPermissions"))

local Events = ReplicatedStorage:FindFirstChild("Events") or Instance.new("Folder", ReplicatedStorage)
Events.Name = "Events"

local ControlEvent = Events:FindFirstChild("LiftControlEvent") or Instance.new("RemoteEvent", Events)
ControlEvent.Name = "LiftControlEvent"
local NotificationEvent = Events:FindFirstChild("NotificationEvent") or Instance.new("RemoteEvent", Events)
NotificationEvent.Name = "NotificationEvent"

-- // CONFIG //
local DECAY_RATE = 0.5 
local DECAY_INTERVAL = 5 
local MECHANIC_REPAIR_AMOUNT = 5 

-- [[ PREMIUM CONFIG ]] --
local GAMEPASS_ID = 1704778044
local GROUP_ID = 398051359
local MIN_RANK = 240

local LiftCache = ReplicatedStorage:WaitForChild("LiftCache", 20)

local PANEL_FALLBACK_NAMES = {
	Panel = true,
	ControlPanel = true,
	Controller = true,
	Base = true,
}

-- // HELPER: CHECK PERMISSIONS //
local function HasPremiumAccess(player)
	local success, rank = pcall(function() return player:GetRankInGroup(GROUP_ID) end)
	if success and rank and rank >= MIN_RANK then
		return true
	end

	local passSuccess, result = pcall(function()
		return require(game.ReplicatedStorage.EntitlementManager).HasAccess(player.UserId, GAMEPASS_ID)
	end)
	if passSuccess and result then
		return true
	end

	local ownsPassSuccess, ownsPass = pcall(function()
		return MarketplaceService:UserOwnsGamePassAsync(player.UserId, GAMEPASS_ID)
	end)
	if ownsPassSuccess and ownsPass then
		return true
	end

	return false
end

-- // TRACKED LIFTS //
local TrackedLifts = {}

-- // HELPER: INSTANT CACHE SYNC //
local function SyncLiftCache(liftModel)
	if not LiftCache then return end
	local uuid = liftModel:GetAttribute("UUID")
	if not uuid then return end

	local cacheObj = LiftCache:FindFirstChild(uuid)
	if not cacheObj then return end

	local speedMult = liftModel:GetAttribute("TargetSpeed") or 0
	local status = liftModel:GetAttribute("Status") or "Stopped"
	local lastSpeed = cacheObj:GetAttribute("RefSpeed") or 1
	local lastStatus = cacheObj:GetAttribute("Status")

	if math.abs(speedMult - lastSpeed) > 0.001 or status ~= lastStatus then
		local lastRefTime = cacheObj:GetAttribute("RefTime") or 0
		local lastTimestamp = cacheObj:GetAttribute("RefTimestamp") or workspace:GetServerTimeNow()
		local timePassed = workspace:GetServerTimeNow() - lastTimestamp
		local currentMasterTime = lastRefTime + (timePassed * lastSpeed)

		cacheObj:SetAttribute("RefTime", currentMasterTime)
		cacheObj:SetAttribute("RefTimestamp", workspace:GetServerTimeNow())
		cacheObj:SetAttribute("RefSpeed", speedMult)
		cacheObj:SetAttribute("Status", status)
	end
end

-- // INITIALIZE LIFT ATTRIBUTES //
local function InitLift(liftModel)
	if liftModel:GetAttribute("ControlInitialized") then
		TrackedLifts[liftModel] = true
		return
	end

	local existingStatus = liftModel:GetAttribute("Status")
	local existingTargetSpeed = liftModel:GetAttribute("TargetSpeed")

	if existingStatus == nil and existingTargetSpeed == nil then
		-- Default newly restored lifts to online so players don't have to restart every lift after join.
		liftModel:SetAttribute("Status", "Running")
		liftModel:SetAttribute("TargetSpeed", 1)
	else
		local resolvedStatus = existingStatus
		if resolvedStatus == nil then
			resolvedStatus = ((tonumber(existingTargetSpeed) or 0) > 0.01) and "Running" or "Stopped"
			liftModel:SetAttribute("Status", resolvedStatus)
		end
		if existingTargetSpeed == nil then
			local fallbackSpeed = 0
			if resolvedStatus == "Running" then
				fallbackSpeed = 1
			elseif resolvedStatus == "Slow" then
				fallbackSpeed = 0.5
			end
			liftModel:SetAttribute("TargetSpeed", fallbackSpeed)
		end
	end
	if liftModel:GetAttribute("Condition") == nil then
		liftModel:SetAttribute("Condition", 100)
	end
	if liftModel:GetAttribute("DisableSeats") == nil then
		liftModel:SetAttribute("DisableSeats", false)
	end
	if liftModel:GetAttribute("CloseDoors") == nil then
		liftModel:SetAttribute("CloseDoors", false)
	end

	liftModel:SetAttribute("ControlInitialized", true)
	SyncLiftCache(liftModel)

	TrackedLifts[liftModel] = true
	liftModel.Destroying:Connect(function()
		TrackedLifts[liftModel] = nil
	end)
end

-- // SETUP PROXIMITY PROMPTS //
local function ResolveLiftFromDescendant(descendant)
	local current = descendant
	while current and current.Parent do
		if current.Parent.Name == "PlacedObjects" and current:IsA("Model") then
			return current
		end
		current = current.Parent
	end
	return nil
end

local function IsValidPanelCandidate(desc)
	if not (desc and desc:IsA("BasePart")) then
		return false
	end
	if PANEL_FALLBACK_NAMES[desc.Name] then
		return true
	end
	local lowered = string.lower(desc.Name)
	return lowered:find("panel", 1, true) ~= nil or lowered:find("control", 1, true) ~= nil
end

local function GetFallbackPanelCandidates(liftModel)
	local candidates = {}
	for _, stationName in ipairs({"StartStation", "EndStation"}) do
		local station = liftModel:FindFirstChild(stationName)
		if station and station:IsA("Model") then
			local explicit = station:FindFirstChild("Panel", true)
			if explicit and explicit:IsA("BasePart") then
				table.insert(candidates, explicit)
			else
				local base = station:FindFirstChild("Base", true)
				if base and base:IsA("BasePart") then
					table.insert(candidates, base)
				else
					local firstPart = station:FindFirstChildWhichIsA("BasePart", true)
					if firstPart then
						table.insert(candidates, firstPart)
					end
				end
			end
		end
	end
	return candidates
end

local function LiftHasPrompt(liftModel)
	return liftModel and liftModel:FindFirstChild("LiftPrompt", true) ~= nil
end

local function getLiftDisplayName(liftModel)
	local custom = liftModel:GetAttribute("CustomName")
	if type(custom) == "string" and custom ~= "" then
		return custom
	end
	return liftModel.Name or "Lift"
end

local function IsInsideStation(part, liftModel)
	local startStation = liftModel:FindFirstChild("StartStation")
	local endStation = liftModel:FindFirstChild("EndStation")
	if startStation and part:IsDescendantOf(startStation) then return true end
	if endStation and part:IsDescendantOf(endStation) then return true end
	return false
end

local function SetupPanel(panel)
	local liftModel = ResolveLiftFromDescendant(panel)
	if not liftModel then return end

	local lType = liftModel:GetAttribute("Type")
	if lType ~= "TwoPoint" and lType ~= "Carpet" then
		return
	end

	-- Only attach prompts to parts inside StartStation / EndStation
	-- so they stay fixed and don't follow moving carriers
	if not IsInsideStation(panel, liftModel) then
		return
	end

	InitLift(liftModel)

	-- Skip if this panel already has a prompt
	local prompt = panel:FindFirstChild("LiftPrompt")
	if prompt then return end

	prompt = Instance.new("ProximityPrompt")
	prompt.Name = "LiftPrompt"
	prompt.ObjectText = getLiftDisplayName(liftModel)
	prompt.ActionText = "Open Panel"
	prompt.RequiresLineOfSight = false
	prompt.MaxActivationDistance = 10
	prompt.HoldDuration = 0
	prompt.Parent = panel

	prompt.Triggered:Connect(function(player)
		ControlEvent:FireClient(player, "OpenUI", liftModel)
	end)

	liftModel:GetAttributeChangedSignal("CustomName"):Connect(function()
		prompt.ObjectText = getLiftDisplayName(liftModel)
	end)
end

-- // DECAY & REPAIR LOOP //
local function GetLiftSupportState(lift)
	local staffed = lift:GetAttribute("LiftStaffed") == true or (tonumber(lift:GetAttribute("StaffEfficiency")) or 0) > 0
	local staffEfficiency = math.max(0, tonumber(lift:GetAttribute("StaffEfficiency")) or 0)
	local mechanicCoverageUntil = tonumber(lift:GetAttribute("MechanicCoverageUntil")) or 0
	local mechanicCoverage = mechanicCoverageUntil > os.time() or lift:GetAttribute("MechanicSupport") == true
	local mechanicLevel = math.max(0, tonumber(lift:GetAttribute("MechanicSupportLevel")) or 0)

	local decayMultiplier = 1
	if staffed then
		decayMultiplier *= math.clamp(0.88 - math.min(0.34, staffEfficiency * 0.18), 0.5, 0.88)
	end
	if mechanicCoverage then
		decayMultiplier *= math.clamp(0.82 - math.min(0.42, mechanicLevel * 0.08), 0.38, 0.82)
	end

	return staffed, mechanicCoverage, staffEfficiency, mechanicLevel, decayMultiplier
end

local function getLiftOwnerUserId(lift)
	if not lift then
		return nil
	end
	local ownerId = tonumber(lift:GetAttribute("Owner"))
		or tonumber(lift:GetAttribute("OwnerId"))
		or tonumber(lift:GetAttribute("PlacedByUserId"))
	if not ownerId or ownerId <= 0 then
		return nil
	end
	return ownerId
end

local function getLiftOwnerPlayer(lift)
	local ownerId = getLiftOwnerUserId(lift)
	if not ownerId then
		return nil
	end
	return Players:GetPlayerByUserId(ownerId)
end

local function canControlLift(player, liftModel)
	if not (player and liftModel) then
		return false
	end
	if MultiplayerPermissions.CanDelete(player, liftModel) then
		return true
	end
	local ownerId = getLiftOwnerUserId(liftModel)
	return ownerId ~= nil and ownerId == player.UserId
end

local function sendLiftNotification(lift, title, body)
	local owner = getLiftOwnerPlayer(lift)
	if owner then
		NotificationEvent:FireClient(owner, "Warning", title, body, 5)
	end
end

task.spawn(function()
	while true do
		task.wait(DECAY_INTERVAL)

		for lift in pairs(TrackedLifts) do
			if lift and lift.Parent then
				local currentCond = tonumber(lift:GetAttribute("Condition")) or 100
				local status = tostring(lift:GetAttribute("Status") or "Stopped")
				local targetSpeed = tonumber(lift:GetAttribute("TargetSpeed")) or 0
				local stateChanged = false
				local staffed, mechanicCoverage, _, mechanicLevel, decayMultiplier = GetLiftSupportState(lift)

				if mechanicCoverage then
					local repairAmount = math.max(MECHANIC_REPAIR_AMOUNT, MECHANIC_REPAIR_AMOUNT + math.floor(mechanicLevel * 1.5) + (staffed and 1 or 0))
					local newCond = math.min(100, currentCond + repairAmount)
					lift:SetAttribute("Condition", newCond)
					currentCond = newCond

					if status == "Broken" and newCond >= 35 then
						lift:SetAttribute("Status", "Running")
						lift:SetAttribute("TargetSpeed", 1)
						stateChanged = true
					elseif status == "Slow" and newCond >= 55 and targetSpeed <= 0.5 then
						lift:SetAttribute("Status", "Running")
						lift:SetAttribute("TargetSpeed", 1)
						stateChanged = true
					end
				elseif status == "Running" or status == "Slow" then
					local decayRate = DECAY_RATE * decayMultiplier
					if currentCond >= 92 then
						decayRate *= 0.5
					elseif currentCond >= 80 then
						decayRate *= 0.7
					end

					local newCond = math.max(0, currentCond - decayRate)

					if newCond <= 18 and status == "Running" then
						lift:SetAttribute("Status", "Slow")
						lift:SetAttribute("TargetSpeed", 0.45)
						stateChanged = true
						sendLiftNotification(lift, "LIFT WARNING", string.format("%s is slowing down and needs attention.", lift.Name))
						status = "Slow"
					end

					if newCond <= 0 then
						if staffed then
							newCond = 8
							if status ~= "Slow" or targetSpeed > 0.45 then
								lift:SetAttribute("Status", "Slow")
								lift:SetAttribute("TargetSpeed", 0.45)
								stateChanged = true
							end
						elseif status ~= "Broken" then
							lift:SetAttribute("Status", "Broken")
							lift:SetAttribute("TargetSpeed", 0)
							stateChanged = true
							sendLiftNotification(lift, "LIFT BREAKDOWN", string.format("%s broke down and needs repairs.", lift.Name))
						end
					end

					lift:SetAttribute("Condition", newCond)
				end

				if currentCond <= 35 then
					lift:SetAttribute("NeedsMechanicHelp", true)
				elseif currentCond >= 60 then
					lift:SetAttribute("NeedsMechanicHelp", false)
				end

				if stateChanged then
					SyncLiftCache(lift)
				end
			else
				TrackedLifts[lift] = nil
			end
		end
	end
end)

-- // HANDLE COMMANDS FROM CLIENT //
ControlEvent.OnServerEvent:Connect(function(player, action, liftModel)
	if type(action) ~= "string" then return end
	if not (liftModel and liftModel:IsA("Model") and liftModel:IsDescendantOf(Workspace)) then return end
	if not canControlLift(player, liftModel) then return end

	local currentStatus = liftModel:GetAttribute("Status")

	if action == "Start" then
		if currentStatus ~= "Broken" then
			liftModel:SetAttribute("Status", "Running")
			liftModel:SetAttribute("TargetSpeed", 1)
			SyncLiftCache(liftModel)
		end

	elseif action == "Stop" then
		if currentStatus ~= "Broken" then
			liftModel:SetAttribute("Status", "Stopped")
			liftModel:SetAttribute("TargetSpeed", 0)
			SyncLiftCache(liftModel)
		end

	elseif action == "Slow" then
		if HasPremiumAccess(player) and currentStatus ~= "Broken" then
			local currentSpeed = tonumber(liftModel:GetAttribute("TargetSpeed")) or 0
			local isAlreadySlow = currentStatus == "Slow" or (currentStatus == "Running" and currentSpeed > 0 and currentSpeed <= 0.55)
			if isAlreadySlow then
				liftModel:SetAttribute("Status", "Running")
				liftModel:SetAttribute("TargetSpeed", 1)
			else
				liftModel:SetAttribute("Status", "Slow")
				liftModel:SetAttribute("TargetSpeed", 0.5)
			end
			SyncLiftCache(liftModel)
		end

	elseif action == "EStop" then
		liftModel:SetAttribute("Status", "Broken")
		liftModel:SetAttribute("TargetSpeed", 0)
		liftModel:SetAttribute("Condition", 0)
		SyncLiftCache(liftModel)
		sendLiftNotification(liftModel, "LIFT BREAKDOWN", string.format("%s was emergency stopped.", liftModel.Name))

	elseif action == "Repair" then
		liftModel:SetAttribute("Condition", 100)
		if currentStatus == "Broken" then
			liftModel:SetAttribute("Status", "Stopped")
			liftModel:SetAttribute("TargetSpeed", 0)
		end
		SyncLiftCache(liftModel)

	elseif action == "ToggleSeats" then
		if HasPremiumAccess(player) then
			local current = liftModel:GetAttribute("DisableSeats")
			liftModel:SetAttribute("DisableSeats", not current)
		end

	elseif action == "ToggleDoors" then
		if HasPremiumAccess(player) then
			local current = liftModel:GetAttribute("CloseDoors")
			liftModel:SetAttribute("CloseDoors", not current)
		end
	end
end)

-- // AUTO-DETECT PANELS //
local ScannedLifts = {}

local function ScanModelForPanels(model)
	if not model:IsA("Model") then return end
	if ScannedLifts[model] then return end
	ScannedLifts[model] = true

	local lType = model:GetAttribute("Type")
	if lType ~= "TwoPoint" and lType ~= "Carpet" then return end

	InitLift(model)

	-- Only look for panels inside StartStation / EndStation to avoid
	-- attaching prompts to moving carriers (e.g. magic carpet belt)
	local foundAnyPanel = false
	for _, stationName in ipairs({"StartStation", "EndStation"}) do
		local station = model:FindFirstChild(stationName)
		if station and station:IsA("Model") then
			for _, desc in ipairs(station:GetDescendants()) do
				if IsValidPanelCandidate(desc) then
					foundAnyPanel = true
					SetupPanel(desc)
				end
			end
		end
	end

	if not foundAnyPanel then
		for _, fallback in ipairs(GetFallbackPanelCandidates(model)) do
			SetupPanel(fallback)
		end
	end

	-- Watch for late-added station descendants only
	model.DescendantAdded:Connect(function(desc)
		if IsValidPanelCandidate(desc) and IsInsideStation(desc, model) then
			SetupPanel(desc)
		end
	end)

	task.delay(1, function()
		if model.Parent and not LiftHasPrompt(model) then
			for _, fallback in ipairs(GetFallbackPanelCandidates(model)) do
				SetupPanel(fallback)
			end
		end
	end)

	model.Destroying:Connect(function()
		ScannedLifts[model] = nil
	end)
end

local function WatchPlacedObjects()
	local placedFolder = workspace:FindFirstChild("PlacedObjects")
	if not placedFolder then
		placedFolder = workspace:WaitForChild("PlacedObjects", 30)
	end
	if not placedFolder then
		return
	end

	for _, child in ipairs(placedFolder:GetChildren()) do
		ScanModelForPanels(child)
	end

	placedFolder.ChildAdded:Connect(function(child)
		task.wait(0.5) 
		ScanModelForPanels(child)
	end)
end

task.spawn(WatchPlacedObjects)