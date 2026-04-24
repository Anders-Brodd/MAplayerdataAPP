--[[
Script: SandboxServer
Description: Handles authorized sandbox mode actions. Validates ownership via Gamepass or Dev IDs, and strictly ensures the current session is a designated sandbox save slot before allowing any execution of economy, guest, weather, time, and world manipulations.
Old Features: Checked Gamepass, Dev IDs, and TeleportData for Sandbox authorization. Dispatched remote actions to modify shared server attributes, lighting, and workspace. Handled time multipliers and AI state globals. Returned an explicit 'isSandboxSlot' boolean alongside 'allowed'.
Added/Removed: Fixed a critical oversight where Gamepass owners could use sandbox commands in normal save slots. Separated the slot validation into an IsSandboxSlot() function, and updated HasAccess() to strictly require IsSandboxSlot() to be true before checking gamepass ownership. No features were removed. Datastores and remote names remain strictly unchanged. All logs remain concise and emoji-free.
]]

-- SCRIPT: SandboxServer (ServerScriptService)

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Lighting = game:GetService("Lighting")
local Workspace = game:GetService("Workspace")

local SANDBOX_GAMEPASS_ID = 1733258476
local SANDBOX_STARTING_MONEY = 999999999
local DEV_IDS = {
	[8843215003]  = true,
	[1090907828]  = true,
	[1624020068]  = true,
	[389306460]   = true,
	--	[1306183746]  = true,
	[1215727369]  = true,
	[game.CreatorId] = true,
}

-- ─── SETUP REMOTES ────────────────────────────────────────────────────────────
local SandboxEvents = ReplicatedStorage:FindFirstChild("SandboxEvents")
if not SandboxEvents then
	SandboxEvents = Instance.new("Folder")
	SandboxEvents.Name = "SandboxEvents"
	SandboxEvents.Parent = ReplicatedStorage

	local ae = Instance.new("RemoteEvent")
	ae.Name = "SandboxAction"
	ae.Parent = SandboxEvents

	local af = Instance.new("RemoteFunction")
	af.Name = "SandboxAuth"
	af.Parent = SandboxEvents
end

local SandboxAction = SandboxEvents.SandboxAction
local SandboxAuth   = SandboxEvents.SandboxAuth

-- ─── AUTHENTICATION ───────────────────────────────────────────────────────────
local function IsSandboxSlot(player)
	if not player then return false end

	-- Force visible for Devs testing in Studio.
	if game:GetService("RunService"):IsStudio() and DEV_IDS[player.UserId] then
		return true
	end

	-- Check player attribute (set by SlotDataLoader)
	local playerSandbox = player:GetAttribute("SandboxMode")
	if playerSandbox == true then
		return true
	end

	-- Check SlotData attribute
	local slotData = ReplicatedStorage:FindFirstChild("SlotData")
	if slotData then
		local sandboxAttr = slotData:GetAttribute("SandboxMode")
		if sandboxAttr == true then
			return true
		end
	end

	-- TeleportData fallback
	local joinData = player:GetJoinData()
	local tpData = joinData and joinData.TeleportData
	if tpData then
		if tpData.SandboxMode == true then
			return true
		end
		if tpData.Settings and tpData.Settings.SandboxMode == true then
			return true
		end
	end

	return false
end

local function HasAccess(player)
	-- STRICT CHECK: Must be a sandbox slot first!
	if not IsSandboxSlot(player) then 
		return false 
	end

	if DEV_IDS[player.UserId] then return true end

	local EM = require(game.ReplicatedStorage.EntitlementManager)

	-- Check dedicated Sandbox gamepass
	if EM.HasAccess(player, SANDBOX_GAMEPASS_ID) then return true end

	-- Match lobby logic: early supporters (founders / pre-order) also get sandbox
	if EM.HasFounderStatus(player) then return true end
	if EM.HasAccess(player, 1683937935) then return true end -- Pre-Order pass

	return false
end

SandboxAuth.OnServerInvoke = function(player)
	-- Sandbox UI visibility is purely flag-based.
	-- The lobby already gates slot creation behind the gamepass.
	-- Once in a sandbox world, everyone gets the UI.
	local isSandbox = IsSandboxSlot(player)
	return { 
		allowed = isSandbox,
		isSandboxSlot = isSandbox
	}
end

local function resolveTargetPlayer(actor, params)
	if typeof(actor) ~= "Instance" or not actor:IsA("Player") then
		return nil
	end
	if type(params) == "table" then
		local targetUserId = tonumber(params.targetUserId or params.userId)
		if targetUserId and targetUserId > 0 then
			local target = Players:GetPlayerByUserId(targetUserId)
			if target then
				return target
			end
		end
		local targetName = params.targetName
		if type(targetName) == "string" and targetName ~= "" then
			local lowered = string.lower(targetName)
			for _, otherPlayer in ipairs(Players:GetPlayers()) do
				if string.lower(otherPlayer.Name) == lowered or string.lower(otherPlayer.DisplayName) == lowered then
					return otherPlayer
				end
			end
		end
	end
	return actor
end

local function grantAllResearch(targetPlayer)
	if typeof(targetPlayer) ~= "Instance" or not targetPlayer:IsA("Player") then
		return
	end
	local adminBridge = ReplicatedStorage:FindFirstChild("Events") and ReplicatedStorage.Events:FindFirstChild("AdminGiveResearch")
	local configModule = ReplicatedStorage:FindFirstChild("ResearchConfig") or (ReplicatedStorage:FindFirstChild("Research") and ReplicatedStorage.Research:FindFirstChild("ResearchConfig"))
	if adminBridge and configModule then
		local config = require(configModule)
		for techId, _ in pairs(config.TechTree or {}) do
			adminBridge:Fire(targetPlayer, techId)
		end
	end
end

local SetSharedMoney
local sandboxBootstrapComplete = false
local function bootstrapSandboxSession(triggerPlayer)
	if sandboxBootstrapComplete then
		return
	end
	if not IsSandboxSlot(triggerPlayer) then
		return
	end
	
	sandboxBootstrapComplete = true
	local currentMoney = tonumber(ServerScriptService:GetAttribute("ServerMoney")) or 0
	if currentMoney < SANDBOX_STARTING_MONEY then
		SetSharedMoney(SANDBOX_STARTING_MONEY)
	end
	for _, targetPlayer in ipairs(Players:GetPlayers()) do
		grantAllResearch(targetPlayer)
	end
end

-- ─── SYSTEM HELPERS ───────────────────────────────────────────────────────────

SetSharedMoney = function(amount)
	local normalizedAmount = math.max(0, math.floor((tonumber(amount) or 0) + 0.5))
	local normalizedTickets = math.max(0, math.floor((tonumber(ServerScriptService:GetAttribute("ServerTickets")) or 0) + 0.5))
	local ms = ServerScriptService:FindFirstChild("MoneyServer", true)
	if ms and ms:FindFirstChild("SetSharedMoney") then
		ms.SetSharedMoney:Fire(normalizedAmount, normalizedTickets)
	else
		ServerScriptService:SetAttribute("ServerMoney", normalizedAmount)
		ServerScriptService:SetAttribute("ServerTickets", normalizedTickets)
		ServerScriptService:SetAttribute("EconomySessionBootstrapped", true)
		ServerScriptService:SetAttribute("EconomyHydrated", true)
		for _, targetPlayer in ipairs(Players:GetPlayers()) do
			targetPlayer:SetAttribute("Money", normalizedAmount)
			local leaderstats = targetPlayer:FindFirstChild("leaderstats")
			if leaderstats then
				local cashValue = leaderstats:FindFirstChild("Cash")
				if cashValue and cashValue:IsA("IntValue") then
					cashValue.Value = normalizedAmount
				end
			end
		end
	end
end

local function AddMoney(amount)
	local current = tonumber(ServerScriptService:GetAttribute("ServerMoney")) or 0
	SetSharedMoney(current + amount)
end

local function watchSandboxBootstrap(player)
	task.spawn(function()
		local timeoutAt = os.clock() + 15
		while player.Parent and os.clock() < timeoutAt do
			if IsSandboxSlot(player) then
				bootstrapSandboxSession(player)
				break
			end
			task.wait(0.5)
		end
	end)
end

local function SetMoney(amount)
	SetSharedMoney(amount)
end

-- ─── GUEST HELPERS ────────────────────────────────────────────────────────────
local function GetAllGuests()
	local guestFolder = Workspace:FindFirstChild("Guests")
	return guestFolder and guestFolder:GetChildren() or {}
end

local function ClearAllGuests()
	if _G.SandboxClearAllGuests then
		_G.SandboxClearAllGuests()
	else
		for _, g in ipairs(GetAllGuests()) do g:Destroy() end
	end
end

local function KillAllGuests()
	for _, g in ipairs(GetAllGuests()) do
		local hum = g:FindFirstChildOfClass("Humanoid")
		if hum then hum.Health = 0 end
	end
end

local function SpawnGuestsNow(count)
	if _G.SandboxSpawnGuests then
		_G.SandboxSpawnGuests(count)
	else
		local ss = ServerScriptService
		ss:SetAttribute("SandboxSpawnRequest", count)
	end
end

local function SetGuestSatisfaction(val)
	for _, g in ipairs(GetAllGuests()) do
		g:SetAttribute("Satisfaction", val)
	end
end

local function FreezeAllGuests(frozen)
	_G.SandboxGuestsFrozen = frozen
	for _, g in ipairs(GetAllGuests()) do
		local hum = g:FindFirstChildOfClass("Humanoid")
		if hum then hum.WalkSpeed = frozen and 0 or (g:GetAttribute("BaseWalkSpeed") or 16) end
	end
end

local function GiveAllGuestsSkis()
	for _, g in ipairs(GetAllGuests()) do
		g:SetAttribute("HasSkis", true)
	end
end

local function ForceAllGuestsToSki()
	if _G.SandboxForceGuestsToSki then
		_G.SandboxForceGuestsToSki()
	end
end

-- ─── WEATHER HELPERS ──────────────────────────────────────────────────────────
local WEATHER_PRESETS = {
	["Clear"]       = { WindSpeed = 5,   SnowRate = 0,   FogEnd = 2000, Temp = 2  },
	["LightSnow"]   = { WindSpeed = 20,  SnowRate = 30,  FogEnd = 800,  Temp = -3 },
	["HeavySnow"]   = { WindSpeed = 55,  SnowRate = 80,  FogEnd = 400,  Temp = -8 },
	["Blizzard"]    = { WindSpeed = 100, SnowRate = 120, FogEnd = 150,  Temp = -15},
}

local function ApplyWeatherPreset(name)
	local preset = WEATHER_PRESETS[name]
	if not preset then return end
	Lighting:SetAttribute("ManualTemp",  true)
	Lighting:SetAttribute("WindSpeed",   preset.WindSpeed)
	Lighting:SetAttribute("SnowRate",    preset.SnowRate)
	Lighting:SetAttribute("FogEnd",      preset.FogEnd)
	Lighting:SetAttribute("Temperature", preset.Temp)
	Lighting:SetAttribute("Weather",     name)
end

local SEASON_MAP = {
	["Winter"] = "Winter",
	["Spring"] = "Spring",
	["Summer"] = "Summer",
	["Autumn"] = "Autumn",
	["Fall"]   = "Autumn",
}

local function SetSeason(season)
	local mappedSeason = SEASON_MAP[season]
	if not mappedSeason then return end
	Lighting:SetAttribute("Season", mappedSeason)
	if _G.SetSeason then pcall(_G.SetSeason, mappedSeason) end
end

-- ─── SLOPE / WORLD HELPERS ───────────────────────────────────────────────────
local function ClearAllSlopes()
	local placedObjects = Workspace:FindFirstChild("PlacedObjects")
	if not placedObjects then return 0 end
	local removed = 0
	for _, obj in ipairs(placedObjects:GetChildren()) do
		if obj:GetAttribute("Type") == "Slope" then
			obj:Destroy()
			removed = removed + 1
		end
	end
	return removed
end

local function getCharacterRoot(player)
	if not (player and player.Character) then
		return nil
	end
	return player.Character:FindFirstChild("HumanoidRootPart")
end

local function getBaseTeleportPosition()
	local startSpawn = Workspace:FindFirstChild("StartSpawn")
	if startSpawn and startSpawn:IsA("BasePart") then
		return startSpawn.Position + Vector3.new(0, 6, 0)
	end
	return Vector3.new(0, 10, 0)
end

local function getModelTeleportPosition(model)
	if not (model and model:IsA("Model")) then
		return nil
	end
	local basePart = model.PrimaryPart or model:FindFirstChildWhichIsA("BasePart", true)
	if basePart then
		return basePart.Position + Vector3.new(0, math.max(8, basePart.Size.Y * 0.65), 0)
	end
	return model:GetPivot().Position + Vector3.new(0, 8, 0)
end

local function getSlopeTeleportPosition(model)
	local rawPoints = model and model:GetAttribute("RawPoints")
	if type(rawPoints) ~= "string" or rawPoints == "" then
		return nil
	end
	local ok, points = pcall(function()
		return game:GetService("HttpService"):JSONDecode(rawPoints)
	end)
	if not ok or type(points) ~= "table" or #points == 0 then
		return nil
	end
	local bestY = -math.huge
	local bestPoint = nil
	for _, point in ipairs(points) do
		if type(point) == "table" then
			local x = tonumber(point.x or point.X or point[1])
			local y = tonumber(point.y or point.Y or point[2])
			local z = tonumber(point.z or point.Z or point[3])
			if x and y and z and y > bestY then
				bestY = y
				bestPoint = Vector3.new(x, y, z)
			end
		end
	end
	if bestPoint then
		return bestPoint + Vector3.new(0, 8, 0)
	end
	return nil
end

local function getPeakTeleportPosition()
	local placedObjects = Workspace:FindFirstChild("PlacedObjects")
	local bestPosition = nil
	local bestScore = -math.huge
	if placedObjects then
		for _, child in ipairs(placedObjects:GetChildren()) do
			if child:IsA("Model") then
				local itemType = tostring(child:GetAttribute("Type") or "")
				local difficulty = child:GetAttribute("Difficulty")
				local nameLower = string.lower(child.Name)
				local isSlope = difficulty ~= nil or itemType == "Slope" or child:GetAttribute("RawPoints") ~= nil
				local isLift = itemType == "TwoPoint" or nameLower:find("lift", 1, true) or nameLower:find("chair", 1, true) or nameLower:find("gondola", 1, true) or nameLower:find("carpet", 1, true)
				if isSlope or isLift then
					local candidate = isSlope and getSlopeTeleportPosition(child) or getModelTeleportPosition(child)
					if candidate and candidate.Y > bestScore then
						bestScore = candidate.Y
						bestPosition = candidate
					end
				end
			end
		end
	end
	if bestPosition then
		return bestPosition
	end
	local basePos = getBaseTeleportPosition()
	return basePos + Vector3.new(0, 120, 0)
end

local function TeleportToTopOfMap(player)
	local root = getCharacterRoot(player)
	if not root then return end
	local target = getPeakTeleportPosition()
	root.CFrame = CFrame.new(target, target + root.CFrame.LookVector)
end

local function TeleportToBaseOfMap(player)
	local root = getCharacterRoot(player)
	if not root then return end
	local target = getBaseTeleportPosition()
	root.CFrame = CFrame.new(target, target + root.CFrame.LookVector)
end

local function ClearAllTrees()
	local treeFolder = Workspace:FindFirstChild("Trees")
	if treeFolder then treeFolder:ClearAllChildren() end
	local placed = Workspace:FindFirstChild("PlacedObjects")
	if placed then
		for _, obj in ipairs(placed:GetChildren()) do
			if obj:GetAttribute("Type") == "Tree" then obj:Destroy() end
		end
	end
end

local function RandomizeTrees()
	local placed = Workspace:FindFirstChild("PlacedObjects")
	if placed then
		for _, obj in ipairs(placed:GetChildren()) do
			if obj:GetAttribute("Type") == "Tree" then 
				obj:PivotTo(obj:GetPivot() * CFrame.Angles(0, math.rad(math.random(0,360)), 0))
			end
		end
	end
end

local function ClearBuildings()
	local placed = Workspace:FindFirstChild("PlacedObjects")
	if placed then
		for _, obj in ipairs(placed:GetChildren()) do
			local t = obj:GetAttribute("Type")
			if t and t ~= "Slope" and t ~= "Tree" and t ~= "Path" then
				obj:Destroy()
			end
		end
	end

	local liftCache = ReplicatedStorage:FindFirstChild("LiftCache")
	if liftCache then
		for _, child in ipairs(liftCache:GetChildren()) do
			child:Destroy()
		end
	end

	for _, child in ipairs(Workspace:GetChildren()) do
		if child:IsA("Folder") and string.match(child.Name, "^Visual_") then
			child:Destroy()
		end
	end
end

local function ClearPaths()
	local placed = Workspace:FindFirstChild("PlacedObjects")
	if placed then
		for _, obj in ipairs(placed:GetChildren()) do
			if obj:GetAttribute("Type") == "Path" then obj:Destroy() end
		end
	end
end

local function InstantFillLifts(player)
	SpawnGuestsNow(20)
end

-- ─── LIFT HELPERS ─────────────────────────────────────────────────────────────
local function ResetAllLiftQueues()
	if _G.SandboxResetLiftQueues then
		_G.SandboxResetLiftQueues()
	end
end

for _, player in ipairs(Players:GetPlayers()) do
	watchSandboxBootstrap(player)
end
Players.PlayerAdded:Connect(watchSandboxBootstrap)

-- ─── ACTION DISPATCH ──────────────────────────────────────────────────────────
SandboxAction.OnServerEvent:Connect(function(player, category, action, params)
	if not HasAccess(player) then
		return
	end
	params = params or {}

	-- ── ECONOMY ──
	if category == "Economy" then
		if action == "Add" then
			AddMoney(tonumber(params.amount) or 1000)
		elseif action == "Set" then
			SetMoney(tonumber(params.amount) or 0)
		elseif action == "Reset" then
			SetMoney(0)
		elseif action == "Max" then
			AddMoney(999999999)
		elseif action == "ToggleAutoIncome" then
			_G.SandboxAutoIncome = not _G.SandboxAutoIncome
			if _G.SandboxAutoIncome then
				task.spawn(function()
					while _G.SandboxAutoIncome do
						AddMoney(10000)
						task.wait(1)
					end
				end)
			end
		elseif action == "TriggerSpike" then
			AddMoney(500000)
		end

		-- ── GUESTS ──
	elseif category == "Guests" then
		if action == "Spawn" then
			SpawnGuestsNow(tonumber(params.count) or 10)
		elseif action == "Clear" then
			ClearAllGuests()
		elseif action == "KillAll" then
			KillAllGuests()
		elseif action == "MaxHappy" then
			SetGuestSatisfaction(100)
		elseif action == "Miserable" then
			SetGuestSatisfaction(5)
		elseif action == "Freeze" then
			FreezeAllGuests(true)
		elseif action == "Unfreeze" then
			FreezeAllGuests(false)
		elseif action == "GiveSkis" then
			GiveAllGuestsSkis()
		elseif action == "ForceSki" then
			ForceAllGuestsToSki()
		elseif action == "FreezeAI" then
			_G.SandboxGuestAIFrozen = not _G.SandboxGuestAIFrozen
		end

		-- ── WEATHER ──
	elseif category == "Weather" then
		if action == "Preset" then
			ApplyWeatherPreset(params.preset)
		elseif action == "Temperature" then
			local t = tonumber(params.value)
			if t then 
				Lighting:SetAttribute("ManualTemp", true)
				Lighting:SetAttribute("Temperature", t) 
			end
		elseif action == "WindSpeed" then
			local w = tonumber(params.value)
			if w then Lighting:SetAttribute("WindSpeed", w) end
		elseif action == "Season" then
			SetSeason(params.season)
		end

		-- ── TIME ──
	elseif category == "Time" then
		if action == "SetClock" then
			local h = tonumber(params.hour)
			if h then Lighting.ClockTime = math.clamp(h, 0, 24) end
		elseif action == "SpeedNormal" then
			_G.SandboxTimeMultiplier = 1
		elseif action == "Speed2x" then
			_G.SandboxTimeMultiplier = 2
		elseif action == "Speed10x" then
			_G.SandboxTimeMultiplier = 10
		elseif action == "Pause" then
			_G.SandboxTimeMultiplier = 0
		elseif action == "NextDay" then
			Lighting.ClockTime = 6
			if _G.DayNightCycle_ForceNewDay then pcall(_G.DayNightCycle_ForceNewDay) end
		end

		-- ── WORLD ──
	elseif category == "World" then
		if action == "ClearSlopes" then
			ClearAllSlopes()
		elseif action == "ClearTrees" then
			ClearAllTrees()
		elseif action == "RandomizeTrees" then
			RandomizeTrees()
		elseif action == "ClearBuildings" then
			ClearBuildings()
		elseif action == "ClearPaths" then
			ClearPaths()
		elseif action == "TeleportTop" then
			TeleportToTopOfMap(player)
		elseif action == "TeleportBottom" then
			TeleportToBaseOfMap(player)
		elseif action == "FillLifts" then
			InstantFillLifts(player)
		end

		-- ── DEBUG ──
	elseif category == "Debug" then
		if action == "GetStats" then
			local guests = GetAllGuests()
			player:SetAttribute("SB_GuestCount", #guests)
			player:SetAttribute("SB_WindSpeed",  tonumber(Lighting:GetAttribute("WindSpeed")) or 0)
			player:SetAttribute("SB_SnowRate",   tonumber(Lighting:GetAttribute("SnowRate"))  or 0)
			player:SetAttribute("SB_Temp",       tonumber(Lighting:GetAttribute("Temperature")) or 0)
			player:SetAttribute("SB_Season",     tostring(Lighting:GetAttribute("Season") or "?"))
			player:SetAttribute("SB_Money",      tonumber(ServerScriptService:GetAttribute("ServerMoney")) or 0)
			if _G.RatingSystem and _G.RatingSystem.GetRating then
				player:SetAttribute("SB_Rating", _G.RatingSystem.GetRating(player))
			end
		elseif action == "SetRating" then
			local val = tonumber(params.value)
			local targetPlayer = resolveTargetPlayer(player, params)
			if val and targetPlayer and _G.RatingSystem and _G.RatingSystem.SetRating then
				_G.RatingSystem.SetRating(targetPlayer, val)
			end
		elseif action == "UnlockResearch" then
			grantAllResearch(resolveTargetPlayer(player, params))
		elseif action == "MaxAllStats" then
			local targetPlayer = resolveTargetPlayer(player, params)
			AddMoney(99999999)
			Lighting:SetAttribute("Temperature", 0)
			Lighting:SetAttribute("WindSpeed", 0)
			Lighting:SetAttribute("SnowRate", 0)
			SetGuestSatisfaction(100)
			_G.SandboxTimeMultiplier = 1
			grantAllResearch(targetPlayer)
			if targetPlayer and _G.RatingSystem and _G.RatingSystem.SetRating then
				_G.RatingSystem.SetRating(targetPlayer, 5.0)
			end
		end
	end
end)

-- ─── TIME MULTIPLIER STATE ───────────────────────────────────────────────────
-- DayNightCycle reads this directly so sandbox time controls do not fight a second loop.
_G.SandboxTimeMultiplier = 1

-- ─── SANDBOX HOOKS IN GUESTSERVER ────────────────────────────────────────────
-- These globals are tested by GuestServer.lua decision loop. Non-breaking if GS doesn't read them yet.
_G.SandboxGuestsFrozen  = false
_G.SandboxGuestAIFrozen = false

task.defer(function()
	task.wait(5)
	if not _G.SandboxSpawnGuests then
		_G.SandboxSpawnGuests = function(count)
			ServerScriptService:SetAttribute("SandboxSpawnRequest", count)
		end
	end
	if not _G.SandboxClearAllGuests then
		_G.SandboxClearAllGuests = function()
			ServerScriptService:SetAttribute("SandboxClearGuests", true)
		end
	end
end)