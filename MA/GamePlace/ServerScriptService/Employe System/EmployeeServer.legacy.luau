--[=[ PATH: ServerScriptService/Building System/EmployeeServer | TYPE: Script ]=]--
--[[
Script Description:
This script handles all backend employee operations including economy, AI coordination, state management, weather awareness, and datastore persistence.
New/Added Capabilities:
- ADDED: Anti-stutter network! The server now acts purely as an AI Director, calculating coordinates but offloading Pathfinding natively to the client.
- ADDED: Uses Model Attributes (`TargetPosition` and `WalkSpeed`) to silently request the client to render smooth paths.
- ADDED: Implemented `SetNetworkOwner` upon Employee spawn. Player natively simulates Employee physics.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")
local DataStoreService = game:GetService("DataStoreService")
local TweenService = game:GetService("TweenService")
local MarketplaceService = game:GetService("MarketplaceService")
local CollectionService = game:GetService("CollectionService")
local Lighting = game:GetService("Lighting")

local Config = require(ReplicatedStorage:WaitForChild("EmployeeConfig"))
local SnowGunShared = require(ReplicatedStorage:WaitForChild("SnowGunShared"))
local Settings = Config.Settings

local CanonicalProfile = nil
do
	local serverFolder = ServerScriptService:FindFirstChild("Server")
	local profileModule = serverFolder and serverFolder:FindFirstChild("CanonicalPlayerProfile")
	if profileModule and profileModule:IsA("ModuleScript") then
		local ok, loaded = pcall(require, profileModule)
		if ok and type(loaded) == "table" then
			CanonicalProfile = loaded
		end
	end
end

local LegacyEmployeeStore = DataStoreService:GetDataStore("EmployeeData")
local EmployeeStore = if CanonicalProfile
	then CanonicalProfile.CreateSlotStoreProxy(LegacyEmployeeStore, "EmployeeData", "Employees")
	else LegacyEmployeeStore
local EmployeeBackupStore = DataStoreService:GetDataStore("EmployeeDataBackups_v1")

local WalkAnim = Instance.new("Animation")
WalkAnim.AnimationId = "rbxassetid://180426354"

local EMPLOYEE_SKI_TYPES = {
	SkiPatrol = true,
	Instructor = true,
}

local function GetEmployeeSkiTemplate()
	local assets = ReplicatedStorage:FindFirstChild("Assets")
	local gear = assets and assets:FindFirstChild("Gear")
	local skis = gear and gear:FindFirstChild("Skis")
	if skis and skis:IsA("Model") then
		return skis
	end
	return nil
end

local function GetCharacterFootParts(character, humanoid)
	if humanoid and humanoid.RigType == Enum.HumanoidRigType.R15 then
		return character:FindFirstChild("LeftFoot") or character:FindFirstChild("LeftLowerLeg"), character:FindFirstChild("RightFoot") or character:FindFirstChild("RightLowerLeg")
	end
	return character:FindFirstChild("Left Leg"), character:FindFirstChild("Right Leg")
end

local function FindSkiParts(model)
	if not model then return nil, nil end
	local left = model:FindFirstChild("LeftSki", true)
	local right = model:FindFirstChild("RightSki", true)
	if left and right and left:IsA("BasePart") and right:IsA("BasePart") then
		return left, right
	end
	local parts = {}
	for _, child in ipairs(model:GetDescendants()) do
		if child:IsA("BasePart") then
			table.insert(parts, child)
		end
	end
	return parts[1], parts[2]
end

local function PrepareSkiPart(part)
	if not part or not part:IsA("BasePart") then return end
	part.Anchored = false
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Massless = true
end

local function AttachSkiToFoot(skiPart, footPart)
	if not (skiPart and footPart and skiPart:IsA("BasePart") and footPart:IsA("BasePart")) then
		return
	end
	PrepareSkiPart(skiPart)
	local offset = CFrame.new(0, -0.4, 0.3) * CFrame.Angles(math.rad(90), 0, 0)
	skiPart.CFrame = footPart.CFrame * offset
	local weld = skiPart:FindFirstChildOfClass("WeldConstraint") or Instance.new("WeldConstraint")
	weld.Part0 = skiPart
	weld.Part1 = footPart
	weld.Parent = skiPart
end

local function AttachSkisToEmployee(model, employeeType)
	if not (model and EMPLOYEE_SKI_TYPES[employeeType]) then
		return
	end
	if model:GetAttribute("HasEmployeeSkis") == true then
		return
	end
	local hum = model:FindFirstChildOfClass("Humanoid")
	local leftFoot, rightFoot = GetCharacterFootParts(model, hum)
	if not (leftFoot and rightFoot) then
		return
	end
	local template = GetEmployeeSkiTemplate()
	if not template then
		return
	end
	local skiRig = template:Clone()
	skiRig.Name = "EmployeeSkis"
	skiRig.Parent = model
	local leftSki, rightSki = FindSkiParts(skiRig)
	AttachSkiToFoot(leftSki, leftFoot)
	AttachSkiToFoot(rightSki, rightFoot)
	model:SetAttribute("HasEmployeeSkis", true)
end

local function SetEmployeeSkiMode(npcModel, data, enabled, speedMultiplier)
	if not (npcModel and data) then
		return
	end
	local useSkis = enabled == true and data.UseSkis == true
	local desiredMultiplier = useSkis and math.max(1, tonumber(speedMultiplier) or 1.35) or 1
	data.IsSkiing = useSkis
	data.MovementSpeedMultiplier = desiredMultiplier
	npcModel:SetAttribute("EmployeeSkiing", useSkis)
	npcModel:SetAttribute("MovementSpeedMultiplier", desiredMultiplier)
end

local HAS_LOADED = false
local LOAD_ATTEMPTED = false
local IS_SAVING = false
local LAST_SAVE_TIME = 0
local ACTIVE_EMPLOYEE_KEY = nil
local STALE_LOAD_RETRY_COUNT = 0
local MAX_STALE_LOAD_RETRIES = 2

local Systems = {}

local EntitlementManager = nil
local entitlementLoaded, entitlementResult = pcall(function()
	return require(ReplicatedStorage:WaitForChild("EntitlementManager"))
end)
if entitlementLoaded then
	EntitlementManager = entitlementResult
else
end

local function ConnectSystems()
	local moneyServer = ServerScriptService:FindFirstChild("MoneyServer", true)
	if not moneyServer then
		local serverFolder = ServerScriptService:FindFirstChild("Server")
		if serverFolder then moneyServer = serverFolder:FindFirstChild("MoneyServer") end
	end
	if moneyServer then
		Systems.MoneyServer = moneyServer
		Systems.AddIncome = moneyServer:FindFirstChild("AddIncome")
		Systems.RequestTransaction = moneyServer:FindFirstChild("RequestTransaction")
	end
end
task.delay(3, ConnectSystems)

local Events = ReplicatedStorage:FindFirstChild("Events") or Instance.new("Folder", ReplicatedStorage)
Events.Name = "Events"

local function GetOrCreateEvent(name, className)
	local event = Events:FindFirstChild(name)
	if event and event.ClassName ~= className then
		event:Destroy()
		event = nil
	end
	if not event then
		event = Instance.new(className)
		event.Name = name
		event.Parent = Events
	end
	return event
end

local HireEvent = GetOrCreateEvent("EmployeeHire", "RemoteEvent")
local HireResultEvent = GetOrCreateEvent("EmployeeHireResult", "RemoteEvent")
local ManageEvent = GetOrCreateEvent("EmployeeManage", "RemoteEvent")
local SyncEvent = GetOrCreateEvent("EmployeeSync", "RemoteEvent")
local InspectEvent = GetOrCreateEvent("EmployeeInspect", "RemoteFunction")
local LegacyHireFunction = GetOrCreateEvent("HireEmployee", "RemoteFunction")
local LegacyUpgradeFunction = GetOrCreateEvent("UpgradeEmployee", "RemoteFunction")

local EmployeeSaveBindable = Events:FindFirstChild("EmployeeRequestSave")
if EmployeeSaveBindable and not EmployeeSaveBindable:IsA("BindableFunction") then
	EmployeeSaveBindable:Destroy()
	EmployeeSaveBindable = nil
end
if not EmployeeSaveBindable then
	EmployeeSaveBindable = Instance.new("BindableFunction")
	EmployeeSaveBindable.Name = "EmployeeRequestSave"
	EmployeeSaveBindable.Parent = Events
end

local LiftCache = ReplicatedStorage:WaitForChild("LiftCache", 20)

local function SyncLiftCache(liftModel)
	if not LiftCache or not liftModel or not liftModel.Parent then return false end
	local uuid = liftModel:GetAttribute("UUID")
	if not uuid then
		uuid = HttpService:GenerateGUID(false)
		liftModel:SetAttribute("UUID", uuid)
	end

	local cacheObj = LiftCache:FindFirstChild(uuid)
	if not cacheObj then
		liftModel:SetAttribute("RefreshID", HttpService:GenerateGUID(false))
		task.delay(0.4, function()
			if liftModel and liftModel.Parent then
				SyncLiftCache(liftModel)
			end
		end)
		return false
	end

	local speedMult = tonumber(liftModel:GetAttribute("TargetSpeed")) or 0
	local status = tostring(liftModel:GetAttribute("Status") or "Stopped")
	local lastSpeed = tonumber(cacheObj:GetAttribute("RefSpeed")) or 1
	local lastStatus = cacheObj:GetAttribute("Status")

	if math.abs(speedMult - lastSpeed) > 0.001 or status ~= lastStatus then
		local now = workspace:GetServerTimeNow()
		local lastRefTime = cacheObj:GetAttribute("RefTime") or 0
		local lastTimestamp = cacheObj:GetAttribute("RefTimestamp") or now
		local timePassed = now - lastTimestamp
		local currentMasterTime = lastRefTime + (timePassed * lastSpeed)

		cacheObj:SetAttribute("RefTime", currentMasterTime)
		cacheObj:SetAttribute("RefTimestamp", now)
		cacheObj:SetAttribute("RefSpeed", speedMult)
		cacheObj:SetAttribute("Status", status)
	end
	return true
end

local function IsRepairableLiftModel(obj)
	if not obj or not obj:IsA("Model") then
		return false
	end

	local liftType = obj:GetAttribute("Type")
	if liftType == "TwoPoint" or liftType == "Carpet" then
		return true
	end

	return obj:GetAttribute("UUID") ~= nil and obj:FindFirstChild("StartStation") ~= nil
end

local ActiveEmployees = {}
local AggregatedEffects = {}
local AssignedBuildings = {}
local HAS_SPAWNED_EMPLOYEE_THIS_SESSION = false
local HireRequestTimes = {}
local ManageRequestTimes = {}
local HIRE_REQUEST_COOLDOWN = 0.25
local MANAGE_REQUEST_COOLDOWN = 0.2

local function IsRateLimited(bucket, userId, cooldown)
	local now = os.clock()
	local lastAt = bucket[userId] or 0
	if (now - lastAt) < cooldown then
		return true
	end
	bucket[userId] = now
	return false
end

local function SendHireResult(player, employeeType, success, reason)
	if player and player.Parent then
		HireResultEvent:FireClient(player, {
			typeId = employeeType,
			success = success,
			reason = reason,
		})
	end
end

local SlotData = ReplicatedStorage:WaitForChild("SlotData", 30)
local SlotNumVal = SlotData and SlotData:WaitForChild("SlotNum", 10)
local UserIdVal = SlotData and SlotData:WaitForChild("UserId", 10)
local SlotCreatedTimeVal = SlotData and SlotData:WaitForChild("CreatedTime", 10)

local EMPLOYEE_PASSES = Config.Gamepasses or Config.Passes or {}
local DOUBLE_EMPLOYEES_PASS_ID = tonumber(EMPLOYEE_PASSES.DoubleEmployees) or 0
local UNLIMITED_EMPLOYEES_PASS_ID = tonumber(EMPLOYEE_PASSES.UnlimitedEmployees) or 0

local function CheckGamepass(userId, passId)
	if type(userId) ~= "number" or userId <= 0 then
		return false
	end
	if type(passId) ~= "number" or passId <= 0 then
		return false
	end

	if EntitlementManager and EntitlementManager.HasAccess then
		local ok, hasAccess = pcall(function()
			return EntitlementManager.HasAccess(userId, passId)
		end)
		if ok then
			return hasAccess == true
		end
	end

	local ok, owns = pcall(function()
		return MarketplaceService:UserOwnsGamePassAsync(userId, passId)
	end)
	return ok and owns or false
end

local function GetGamepassStatus(userId)
	local hasDouble = CheckGamepass(userId, DOUBLE_EMPLOYEES_PASS_ID)
	local hasUnlimited = false
	if UNLIMITED_EMPLOYEES_PASS_ID > 0 then
		if UNLIMITED_EMPLOYEES_PASS_ID == DOUBLE_EMPLOYEES_PASS_ID then
			hasUnlimited = hasDouble
		else
			hasUnlimited = CheckGamepass(userId, UNLIMITED_EMPLOYEES_PASS_ID)
		end
	end
	return {
		double = hasDouble,
		unlimited = hasUnlimited,
	}
end

local function GetMaxPerType(userId)
	local gp = GetGamepassStatus(userId)
	if gp.unlimited or gp.double then return 9999 end
	return Settings.MaxPerType
end

local function GetMaxTotal(userId)
	local gp = GetGamepassStatus(userId)
	if gp.unlimited or gp.double then return 9999 end
	return Settings.MaxTotal
end

local function GetCurrentWeather()
	return Lighting:GetAttribute("Weather") or "Clear"
end

local function GetCurrentTemperature()
	return Lighting:GetAttribute("Temperature") or 30
end

local function GetCurrentSeason()
	return Lighting:GetAttribute("Season") or "Winter"
end

local function GetWeatherMultipliers()
	return Config.GetWeatherMultipliers(GetCurrentWeather())
end

local function BuildEmployeeKeyFromOwnerAndSlot(ownerId, slotNum)
	if type(ownerId) ~= "number" or ownerId <= 0 or type(slotNum) ~= "number" or slotNum <= 0 then
		return nil
	end
	return string.format("User_%d_Slot_%d_Employees", ownerId, slotNum)
end

local function GetSlotKey()
	if not SlotNumVal or not UserIdVal then return nil end
	local ownerId = tonumber(UserIdVal.Value)
	local slotNum = tonumber(SlotNumVal.Value)
	if not ownerId or ownerId <= 0 or not slotNum or slotNum <= 0 then
		return nil
	end

	if type(_G.GetSlotKey) == "function" then
		local ok, slotBase = pcall(_G.GetSlotKey, ownerId)
		if ok and type(slotBase) == "string" and slotBase ~= "" then
			return slotBase .. "_Employees"
		end
	end

	return BuildEmployeeKeyFromOwnerAndSlot(ownerId, slotNum)
end

local function GetEmployeeLoadKeys()
	local keys = {}
	local seen = {}

	local function push(key)
		if type(key) ~= "string" or key == "" or seen[key] then
			return
		end
		seen[key] = true
		table.insert(keys, key)
	end

	local primary = GetSlotKey()
	if primary then
		push(primary)
	end

	local ownerId = UserIdVal and tonumber(UserIdVal.Value) or nil
	local slotNum = SlotNumVal and tonumber(SlotNumVal.Value) or nil
	if ownerId and ownerId > 0 and slotNum and slotNum > 0 then
		push(string.format("User_%d_Slot_%d_Employees", ownerId, slotNum))
		push(string.format("User_%d_Slot%d_Employees", ownerId, slotNum))
		-- Legacy keys from older slot-key builders that appended employees to the game-data key.
		push(string.format("User_%d_Slot_%d_GameData_Employees", ownerId, slotNum))
		push(string.format("User_%d_Slot%d_GameData_Employees", ownerId, slotNum))
		push(string.format("User_%d_Default_Employees", ownerId))
	end

	return keys
end

local function WaitForResolvedSlotKey(timeoutSeconds)
	local deadline = os.clock() + (timeoutSeconds or 15)
	while os.clock() < deadline do
		local key = GetSlotKey()
		if key then
			return key
		end
		task.wait(0.5)
	end
	return GetSlotKey()
end

local function GetOwnerUserId()
	if UserIdVal and UserIdVal.Value > 0 then
		return UserIdVal.Value
	end
	return 0
end

local function GetSlotEmployeePassFlagsForSync()
	local ownerId = GetOwnerUserId()
	if type(ownerId) ~= "number" or ownerId <= 0 then
		return { double = false, unlimited = false }
	end
	local gp = GetGamepassStatus(ownerId)
	return { double = gp.double == true, unlimited = gp.unlimited == true }
end

local function GetSessionCreatedTime()
	if SlotCreatedTimeVal and SlotCreatedTimeVal:IsA("IntValue") then
		return tonumber(SlotCreatedTimeVal.Value) or 0
	end
	return 0
end

local function WaitForResolvedCreatedTime(timeoutSeconds)
	local deadline = os.clock() + (timeoutSeconds or 12)
	local createdTime = GetSessionCreatedTime()
	while createdTime <= 0 and os.clock() < deadline do
		task.wait(0.5)
		createdTime = GetSessionCreatedTime()
	end
	return createdTime
end

local function SaveEmployeeBackup(key, payload)
	local employeeList = payload
	if type(payload) == "table" and type(payload.employees) == "table" then
		employeeList = payload.employees
	end
	local backupPayload = {
		__SavedAt = os.time(),
		employees = employeeList,
	}
	local createdTime = type(payload) == "table" and tonumber(payload.CreatedTime) or 0
	if createdTime and createdTime > 0 then
		backupPayload.CreatedTime = createdTime
	end
	pcall(function()
		EmployeeBackupStore:UpdateAsync(key, function(oldData)
			local oldTs = type(oldData) == "table" and tonumber(oldData.__SavedAt) or 0
			if oldTs and oldTs > backupPayload.__SavedAt then
				return oldData
			end
			return backupPayload
		end)
	end)
end

local function NormalizeEmployeePayload(raw)
	if type(raw) ~= "table" then
		return nil
	end

	local source = raw
	for _ = 1, 4 do
		if type(source) == "table" and type(source.employees) == "table" then
			source = source.employees
		else
			break
		end
	end

	local normalized = {}
	if #source > 0 then
		for _, entry in ipairs(source) do
			if type(entry) == "table" then
				table.insert(normalized, entry)
			end
		end
	else
		for _, entry in pairs(source) do
			if type(entry) == "table" then
				table.insert(normalized, entry)
			end
		end
	end

	return normalized
end

local function ExtractEmployeePayload(raw)
	local normalized = NormalizeEmployeePayload(raw)
	if type(normalized) ~= "table" then
		return nil, 0
	end
	local current = raw
	for _ = 1, 4 do
		if type(current) ~= "table" then
			break
		end
		local createdTime = tonumber(current.CreatedTime or current.createdTime or current.__CreatedTime) or 0
		if createdTime > 0 then
			return normalized, createdTime
		end
		current = current.employees
	end
	return normalized, 0
end

local function LoadEmployeeBackup(key)
	local ok, backup = pcall(function()
		return EmployeeBackupStore:GetAsync(key)
	end)
	if not ok or type(backup) ~= "table" then
		return nil, nil
	end

	local normalized, createdTime = ExtractEmployeePayload(backup)
	if type(normalized) == "table" then
		return normalized, tonumber(backup.__SavedAt) or 0, createdTime
	end

	return nil, nil, nil
end

local function LoadBestEmployeeBackup(keys, expectedCreatedTime)
	local bestData = nil
	local bestKey = nil
	local bestScore = -math.huge
	local bestCreatedTime = 0
	expectedCreatedTime = tonumber(expectedCreatedTime) or 0
	for _, key in ipairs(keys) do
		local data, ts, createdTime = LoadEmployeeBackup(key)
		if type(data) == "table" and #data > 0 then
			ts = tonumber(ts) or 0
			createdTime = tonumber(createdTime) or 0
			local score = math.clamp(#data, 0, 200000)
			if expectedCreatedTime > 0 then
				if createdTime == expectedCreatedTime then
					score += 1000000
				elseif createdTime > 0 then
					score -= 1000000
				end
			elseif createdTime > 0 then
				score += 1000
			end
			score += ts * 0.000001
			if score > bestScore then
				bestScore = score
				bestData = data
				bestKey = key
				bestCreatedTime = createdTime
			end
		end
	end
	return bestData, bestKey, bestCreatedTime
end

local function GetPlayerFromUserId(userId)
	return Players:GetPlayerByUserId(userId)
end

local function CountEmployeesByType(userId, typeName)
	local count = 0
	for _, data in pairs(ActiveEmployees) do
		if data.OwnerId == userId and data.Type == typeName then count = count + 1 end
	end
	return count
end

local function CountTotalEmployees(userId)
	local count = 0
	for _, data in pairs(ActiveEmployees) do
		if data.OwnerId == userId then count = count + 1 end
	end
	return count
end

local function GetSafeGroundPosition(pos, includePlacedObjects)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	-- Terrain should win by default so employee rescue/teleport logic does not snap staff
	-- onto restaurant roofs or other decorative build surfaces.
	if includePlacedObjects == true then
		local placedObjects = workspace:FindFirstChild("PlacedObjects")
		if placedObjects then
			params.FilterDescendantsInstances = {workspace.Terrain, placedObjects}
		else
			params.FilterDescendantsInstances = {workspace.Terrain}
		end
	else
		params.FilterDescendantsInstances = {workspace.Terrain}
	end
	local result = workspace:Raycast(Vector3.new(pos.X, pos.Y + 50, pos.Z), Vector3.new(0, -100, 0), params)
	if result then
		return Vector3.new(pos.X, result.Position.Y + 3, pos.Z)
	end
	return Vector3.new(pos.X, pos.Y + 3, pos.Z)
end

local function GetEmployeeRootPart(model)
	if not model then return nil end

	local root = model.PrimaryPart
	if root and root:IsA("BasePart") then
		return root
	end

	root = model:FindFirstChild("HumanoidRootPart")
		or model:FindFirstChild("Torso")
		or model:FindFirstChild("UpperTorso")
	if root and root:IsA("BasePart") then
		model.PrimaryPart = root
		return root
	end

	root = model:FindFirstChildWhichIsA("BasePart")
	if root then
		model.PrimaryPart = root
	end
	return root
end

local function TrySpendMoney(amount, itemName, transactionType)
	if not Systems.RequestTransaction then return false end
	local name = itemName or "EmployeeExpense"
	local typeVal = transactionType or Enum.AnalyticsEconomyTransactionType.Shop
	local ok, result = pcall(function()
		return Systems.RequestTransaction:Invoke(nil, amount, name, typeVal)
	end)
	return ok and result
end

local function AddIncome(ownerId, amount, itemName, transactionType)
	if not Systems.AddIncome then return end
	local player = GetPlayerFromUserId(ownerId)
	if player then
		local name = itemName or "EmployeeIncome"
		local typeVal = transactionType or Enum.AnalyticsEconomyTransactionType.Gameplay
		pcall(function() Systems.AddIncome:Fire(player, amount, name, typeVal) end)
	end
end

local function GetCurrentMoney()
	return ServerScriptService:GetAttribute("ServerMoney") or 0
end

local WageUnpaid = false
task.spawn(function()
	task.wait(30)
	while true do
		task.wait(Settings.WageInterval)
		if not HAS_LOADED then continue end

		local totalWages = 0
		for model, data in pairs(ActiveEmployees) do
			if model and model.Parent then
				local typeData = Config.GetTypeData(data.Type)
				if typeData then
					totalWages = totalWages + Config.GetWage(typeData.BaseWage, data.Level)
				end
			end
		end

		if totalWages > 0 then
			local canPay = TrySpendMoney(totalWages, "EmployeeWages", Enum.AnalyticsEconomyTransactionType.Shop)
			WageUnpaid = not canPay
			if not canPay then
				for model, data in pairs(ActiveEmployees) do
					if model and model.Parent then
						data.WagesPaid = false
					end
				end
			else
				for model, data in pairs(ActiveEmployees) do
					if model and model.Parent then
						data.WagesPaid = true
					end
				end
			end
		end
	end
end)

local function ApplyAggregatedEffects()
	workspace:SetAttribute("EmployeeSatisfactionBonus", AggregatedEffects.GuestSatisfaction or 0)
	workspace:SetAttribute("EmployeeRatingBonus", AggregatedEffects.ResortRating or 0)
	workspace:SetAttribute("EmployeeBreakdownReduction", AggregatedEffects.LiftBreakdownReduction or 0)
	workspace:SetAttribute("EmployeeSnowEfficiency", AggregatedEffects.SnowgunEfficiency or 0)
	workspace:SetAttribute("EmployeeFoodBonus", AggregatedEffects.FoodRevenue or 0)
	workspace:SetAttribute("EmployeeRentalBonus", AggregatedEffects.RentalRevenue or 0)
end

local function RecalculateEffects()
	AggregatedEffects = {}
	local groomerCount = 0
	for model, data in pairs(ActiveEmployees) do
		if model and model.Parent then
			local ok, effects = pcall(function() return Config.GetEffectsAtLevel(data.Type, data.Level) end)
			if ok and effects then
				for name, val in pairs(effects) do
					if type(val) == "number" then
						AggregatedEffects[name] = (AggregatedEffects[name] or 0) + val
					end
				end
			end
			if data.Type == "Groomer" then
				groomerCount = groomerCount + 1
			end
		end
	end
	workspace:SetAttribute("GroomerEmployeeCount", groomerCount)
	ApplyAggregatedEffects()
end

local function BuildEmployeeList()
	local list = {}
	local weather = GetCurrentWeather()
	local temp = GetCurrentTemperature()
	local passCacheByOwner = {}

	for model, data in pairs(ActiveEmployees) do
		if model and model.Parent then
			local typeData = Config.GetTypeData(data.Type)
			if typeData then
				local ownerId = tonumber(data.OwnerId) or GetOwnerUserId()
				local gp = passCacheByOwner[ownerId]
				if not gp then
					gp = GetGamepassStatus(ownerId)
					passCacheByOwner[ownerId] = gp
				end

				table.insert(list, {
					Model = model, UUID = data.UUID, Type = data.Type,
					Level = data.Level, Name = typeData.Name, Emoji = typeData.Emoji,
					Color = typeData.Color, Assignment = data.Assignment,
					State = data.State, TasksCompleted = data.TasksCompleted,
					TotalEarnings = data.TotalEarnings, HireTime = data.HireTime,
					Wage = Config.GetWage(typeData.BaseWage, data.Level),
					OwnerId = data.OwnerId, WagesPaid = data.WagesPaid,
					Weather = weather, Temperature = temp,
					HasDoublePass = gp.double,
					HasUnlimitedPass = gp.unlimited or gp.double,
				})
			end
		end
	end
	return list
end

local function BroadcastEmployeeUpdate()
	local list = BuildEmployeeList()
	local passFlags = GetSlotEmployeePassFlagsForSync()
	for _, player in ipairs(Players:GetPlayers()) do
		SyncEvent:FireClient(player, list, passFlags)
	end
end

local function SendEmployeeListToPlayer(player)
	SyncEvent:FireClient(player, BuildEmployeeList(), GetSlotEmployeePassFlagsForSync())
end

local SERVICE_ROLE_ATTRS = {
	LiftOperator = "HasLifty",
	Chef = "HasChef",
	RentalTech = "HasTech",
	Snowmaker = "HasSnowmaker",
	Janitor = "HasJanitor",
}

local function GetRoleAssignmentAttr(employeeType)
	return "AssignedEmployee_" .. tostring(employeeType or "Unknown")
end

local function FindActiveEmployeeDataByUUID(uuid)
	if not uuid then
		return nil, nil
	end
	for model, data in pairs(ActiveEmployees) do
		if data.UUID == uuid and model and model.Parent then
			return model, data
		end
	end
	return nil, nil
end

local function ResolveManagedEmployeeTarget(targetRef)
	if typeof(targetRef) == "Instance" and targetRef:IsA("Model") then
		local data = ActiveEmployees[targetRef]
		if data then
			return targetRef, data
		end
	end

	if type(targetRef) == "table" then
		local targetModel = targetRef.Model
		if typeof(targetModel) == "Instance" and targetModel:IsA("Model") then
			local data = ActiveEmployees[targetModel]
			if data then
				return targetModel, data
			end
		end
		local uuid = targetRef.UUID
		if type(uuid) == "string" and uuid ~= "" then
			return FindActiveEmployeeDataByUUID(uuid)
		end
	elseif type(targetRef) == "string" and targetRef ~= "" then
		return FindActiveEmployeeDataByUUID(targetRef)
	end

	return nil, nil
end

local function IsOwnerCompatibleObject(obj, ownerId)
	if ownerId == nil or ownerId == 0 then
		return true
	end
	local buildingOwner = tonumber(obj:GetAttribute("Owner"))
	if buildingOwner == nil or buildingOwner == 0 then
		return true
	end
	return buildingOwner == ownerId
end

local function GetServiceProbePosition(obj)
	if not obj then
		return Vector3.zero
	end
	local objType = obj:GetAttribute("Type")
	if objType == "TwoPoint" or objType == "Carpet" then
		local startStation = obj:FindFirstChild("StartStation")
		if startStation then
			return startStation:GetPivot().Position
		end
	end

	local preferredServiceNames = {
		"servicewindow", "service_window", "window", "counter", "frontcounter",
		"servicedesk", "desk", "pickup", "register", "order", "queue", "guestspawn",
		"customerspawn", "entry", "entrance",
	}
	for _, desc in ipairs(obj:GetDescendants()) do
		if desc:IsA("Attachment") then
			local lowerName = string.lower(desc.Name)
			for _, token in ipairs(preferredServiceNames) do
				if lowerName == token or lowerName:find(token, 1, true) then
					return desc.WorldPosition
				end
			end
		end
	end
	for _, desc in ipairs(obj:GetDescendants()) do
		if desc:IsA("BasePart") or desc:IsA("Model") then
			local lowerName = string.lower(desc.Name)
			for _, token in ipairs(preferredServiceNames) do
				if lowerName == token or lowerName:find(token, 1, true) then
					if desc:IsA("Model") then
						local serviceCF = desc:GetBoundingBox()
						return serviceCF.Position
					end
					return desc.Position
				end
			end
		end
	end
	for _, desc in ipairs(obj:GetDescendants()) do
		if desc:IsA("BasePart") or desc:IsA("Model") then
			local lowerName = string.lower(desc.Name)
			if lowerName == "door" or lowerName:find("door", 1, true) then
				if desc:IsA("Model") then
					local doorCF = desc:GetBoundingBox()
					return doorCF.Position
				end
				return desc.Position
			end
		end
	end
	return obj:GetPivot().Position
end

local function IsCleanableGuestBuilding(obj)
	if not obj or not obj.Parent then
		return false
	end
	local objType = tostring(obj:GetAttribute("Type") or "")
	local objName = tostring(obj.Name or "")
	if objType == "Food" or objType == "Rental" or objType == "House" then
		return true
	end
	return objName:find("Restaurant") ~= nil
		or objName:find("Food") ~= nil
		or objName:find("Cafe") ~= nil
		or objName:find("Rental") ~= nil
		or objName:find("Cabin") ~= nil
		or objName:find("Lodge") ~= nil
		or objName:find("Hotel") ~= nil
		or objName:find("House") ~= nil
end

local function IsGuestModelCandidate(model)
	if not model or not model:IsA("Model") then
		return false
	end
	if model:GetAttribute("IsEmployee") then
		return false
	end
	if not model:FindFirstChild("HumanoidRootPart") then
		return false
	end
	local parent = model.Parent
	if parent and (parent.Name == "Guests" or parent.Name == "GuestModels" or parent.Name == "NPCs") then
		return true
	end
	return model:GetAttribute("IsGuest") == true
		or model:GetAttribute("State") ~= nil
		or model:GetAttribute("Personality") ~= nil
end

local function IterateGuestModels(callback)
	local seen = {}
	local function visitContainer(container)
		if not container then
			return true
		end
		for _, child in ipairs(container:GetChildren()) do
			if child:IsA("Model") and not seen[child] and IsGuestModelCandidate(child) then
				seen[child] = true
				if callback(child) == false then
					return false
				end
			end
		end
		return true
	end
	if visitContainer(workspace:FindFirstChild("Guests")) == false then return end
	if visitContainer(workspace:FindFirstChild("GuestModels")) == false then return end
	if visitContainer(workspace:FindFirstChild("NPCs")) == false then return end
	visitContainer(workspace)
end

local function GuestMatchesOwner(guestModel, ownerId)
	if ownerId == nil or ownerId == 0 then
		return true
	end
	local guestOwner = tonumber(guestModel:GetAttribute("OwnerId")) or tonumber(guestModel:GetAttribute("Owner"))
	if guestOwner == nil or guestOwner == 0 then
		return true
	end
	return guestOwner == ownerId
end

local function CountNearbyGuests(pos, radius, predicate)
	local count = 0
	IterateGuestModels(function(guestModel)
		if predicate and not predicate(guestModel) then
			return
		end
		local root = guestModel:FindFirstChild("HumanoidRootPart")
		if root and (root.Position - pos).Magnitude < radius then
			count += 1
		end
	end)
	return count
end

local function CountNearbyCrashedGuests(pos, radius, ownerId)
	local count = 0
	IterateGuestModels(function(guestModel)
		if not GuestMatchesOwner(guestModel, ownerId) then
			return
		end
		if not guestModel:GetAttribute("IsCrashed") then
			return
		end
		local root = guestModel:FindFirstChild("HumanoidRootPart")
		if root and (root.Position - pos).Magnitude < radius then
			count += 1
		end
	end)
	return count
end

local function GetSlopeDifficultyWeight(slope)
	local difficulty = slope and (slope:GetAttribute("Difficulty") or "Green") or "Green"
	if difficulty == "Double Black" or difficulty == "DoubleBlack" then
		return 4
	elseif difficulty == "Black" then
		return 3
	elseif difficulty == "Blue" then
		return 2
	end
	return 1
end

local function RefreshBuildingOccupancy(building)
	if not building or not building.Parent then
		return
	end
	local hasServiceEmployee = false
	local bestEfficiency = nil
	local bestLevel = nil
	for employeeType, presenceAttr in pairs(SERVICE_ROLE_ATTRS) do
		local roleAttr = GetRoleAssignmentAttr(employeeType)
		local assignedUuid = building:GetAttribute(roleAttr)
		local _, assignedData = FindActiveEmployeeDataByUUID(assignedUuid)
		if assignedData then
			hasServiceEmployee = true
			building:SetAttribute(presenceAttr, true)
			local efficiency = tonumber(assignedData.Efficiency) or 1
			if not bestEfficiency or efficiency > bestEfficiency then
				bestEfficiency = efficiency
				bestLevel = assignedData.Level
			end
		else
			building:SetAttribute(roleAttr, nil)
			building:SetAttribute(presenceAttr, nil)
		end
	end
	building:SetAttribute("AssignedEmployee", nil)
	building:SetAttribute("HasEmployee", hasServiceEmployee or nil)
	building:SetAttribute("StaffEfficiency", bestEfficiency)
	building:SetAttribute("StaffLevel", bestLevel)
end

local function SetSnowgunOperationalState(building, state)
	if not building or not building.Parent then
		return
	end
	local desiredState = tostring(state or "Off")
	local runtime = _G.SnowmakingRuntime
	if runtime and runtime.SetGunState then
		local ok = pcall(runtime.SetGunState, building, desiredState)
		if ok then
			return
		end
	end
	building:SetAttribute("State", desiredState)
end

local function GetEmployeeSnowmakerIntensity(temp, clockTime)
	local baseIntensity = Config.GetSnowmakerIntensity(temp)
	if baseIntensity then
		return baseIntensity
	end

	clockTime = tonumber(clockTime) or 0
	local isDaytime = clockTime >= 7 and clockTime < 20
	local marginalLimit = isDaytime and 34 or 35
	if temp <= marginalLimit then
		return "Slow"
	end

	return nil
end

local function ClearRoleCoverage(employeeData, building)
	if not employeeData or not building then
		return
	end
	if employeeData.Type == "Snowmaker" then
		for _, attr in ipairs({"SnowmakerActive", "SnowmakerIntensity", "SnowStaffEfficiency", "SnowCoverageBonus", "SnowCostReduction", "SnowmakerIntensityBonus"}) do
			building:SetAttribute(attr, nil)
		end
		SetSnowgunOperationalState(building, "Off")
	elseif employeeData.Type == "SkiPatrol" then
		for _, attr in ipairs({"SkiPatrolCoverage", "SkiPatrolLevel", "SkiPatrolRadius"}) do
			building:SetAttribute(attr, nil)
		end
	elseif employeeData.Type == "Groomer" then
		for _, attr in ipairs({"GroomerCoverage", "GroomLevel"}) do
			building:SetAttribute(attr, nil)
		end
	elseif employeeData.Type == "Instructor" then
		for _, attr in ipairs({"HasInstructor", "InstructorLevel", "LessonQuality"}) do
			building:SetAttribute(attr, nil)
		end
	elseif employeeData.Type == "Janitor" then
		for _, attr in ipairs({"HasJanitor", "JanitorLevel", "JanitorCoverage", "NeedsCleaning", "CleanAreaTraffic"}) do
			building:SetAttribute(attr, nil)
		end
	end
end

local function UpdateSlopeRoleCoverage(employeeData, slope)
	if not employeeData or not slope or not slope.Parent then
		return
	end
	if employeeData.Type == "SkiPatrol" then
		slope:SetAttribute("SkiPatrolCoverage", true)
		slope:SetAttribute("SkiPatrolLevel", employeeData.Level)
		slope:SetAttribute("SkiPatrolRadius", 80 + (employeeData.Level * 10))
	elseif employeeData.Type == "Groomer" then
		slope:SetAttribute("GroomerCoverage", true)
		slope:SetAttribute("GroomLevel", employeeData.Level)
	elseif employeeData.Type == "Instructor" then
		slope:SetAttribute("HasInstructor", true)
		slope:SetAttribute("InstructorLevel", employeeData.Level)
		slope:SetAttribute("LessonQuality", employeeData.Level)
	end
end

local function GetDemandScoreForBuilding(employeeType, obj, searchPos, ownerId)
	local typeData = Config.GetTypeData(employeeType)
	if not typeData or not obj or not obj.Parent then
		return -math.huge
	end
	if not IsOwnerCompatibleObject(obj, ownerId) then
		return -math.huge
	end

	local assignmentType = typeData.AssignmentType
	local probePos = GetServiceProbePosition(obj)
	local distPenalty = (probePos - (searchPos or probePos)).Magnitude * 0.05

	if assignmentType == "Lift" then
		local nearbyGuests = CountNearbyGuests(probePos, 75, function(guestModel)
			if not GuestMatchesOwner(guestModel, ownerId) then
				return false
			end
			local state = tostring(guestModel:GetAttribute("State") or "")
			return state ~= "Leaving" and state ~= "Sleeping"
		end)
		local condition = tonumber(obj:GetAttribute("Condition")) or 100
		local status = tostring(obj:GetAttribute("Status") or "Stopped")
		local score = (nearbyGuests * 12) + (math.max(0, 85 - condition) * 1.2)
		if status == "Broken" then
			score += 120
		elseif status == "Stopped" then
			score += 25
		end
		return score - distPenalty
	elseif assignmentType == "Restaurant" then
		local guestRadius = typeData.GuestProximityRadius or 60
		local hungryGuests = CountNearbyGuests(probePos, guestRadius, function(guestModel)
			if not GuestMatchesOwner(guestModel, ownerId) then
				return false
			end
			local hunger = tonumber(guestModel:GetAttribute("Hunger")) or 100
			local state = tostring(guestModel:GetAttribute("State") or "")
			return hunger < 75 and state ~= "Eating" and state ~= "Leaving" and state ~= "Sleeping"
		end)
		local crowd = CountNearbyGuests(probePos, guestRadius, function(guestModel)
			return GuestMatchesOwner(guestModel, ownerId)
		end)
		return (hungryGuests * 16) + (crowd * 2) - distPenalty
	elseif assignmentType == "Rental" then
		local guestRadius = typeData.GuestProximityRadius or 50
		local rentalDemand = CountNearbyGuests(probePos, guestRadius, function(guestModel)
			if not GuestMatchesOwner(guestModel, ownerId) then
				return false
			end
			local state = tostring(guestModel:GetAttribute("State") or "")
			return guestModel:GetAttribute("HasSkis") ~= true and state ~= "Leaving" and state ~= "Sleeping"
		end)
		return (rentalDemand * 18) - distPenalty
	elseif assignmentType == "Snowgun" then
		local freezingTemp = typeData.FreezingTemp or 32
		local temp = GetCurrentTemperature()
		if temp > freezingTemp then
			return -25 - distPenalty
		end
		local coldness = math.max(0, freezingTemp - temp)
		local state = tostring(obj:GetAttribute("State") or "Off")
		local activeBonus = (state == "Off") and 70 or 30
		return activeBonus + (coldness * 4) - distPenalty
	elseif assignmentType == "Cleaning" then
		if not IsCleanableGuestBuilding(obj) then
			return -math.huge
		end
		local guestRadius = typeData.GuestProximityRadius or 70
		local nearbyGuests = CountNearbyGuests(probePos, guestRadius, function(guestModel)
			if not GuestMatchesOwner(guestModel, ownerId) then
				return false
			end
			local state = tostring(guestModel:GetAttribute("State") or "")
			return state ~= "Leaving" and state ~= "Sleeping"
		end)
		local cleanliness = math.clamp(tonumber(obj:GetAttribute("Cleanliness")) or 55, 0, 100)
		local dirtiness = math.max(0, 100 - cleanliness)
		local score = (dirtiness * 1.7) + (nearbyGuests * 10)
		if obj:GetAttribute("NeedsCleaning") == true then
			score += 20
		end
		return score - distPenalty
	elseif assignmentType == "Slope" then
		local difficulty = obj:GetAttribute("Difficulty") or "Green"
		local difficultyWeight = GetSlopeDifficultyWeight(obj)
		local condition = tonumber(obj:GetAttribute("SlopeCondition")) or 70
		if employeeType == "SkiPatrol" then
			local crashes = CountNearbyCrashedGuests(probePos, 90, ownerId)
			return (crashes * 90) + (difficultyWeight * 20) + (math.max(0, 75 - condition) * 0.4) - distPenalty
		elseif employeeType == "Groomer" then
			return (math.max(0, 100 - condition) * 2) + (difficultyWeight * 14) - distPenalty
		elseif employeeType == "Instructor" then
			if not Config.CanInstructorTeachDifficulty(difficulty) then
				return -math.huge
			end
			local learners = CountNearbyGuests(probePos, 90, function(guestModel)
				if not GuestMatchesOwner(guestModel, ownerId) then
					return false
				end
				local state = tostring(guestModel:GetAttribute("State") or "")
				local skillLevel = tonumber(guestModel:GetAttribute("SkiSkillLevel")) or 1
				return skillLevel <= 2 and state ~= "Leaving" and state ~= "Sleeping"
			end)
			local base = (difficulty == "Green") and 45 or 28
			return (learners * 14) + base - distPenalty
		end
	end

	return -distPenalty
end

local function IsBuildingTaken(building, employeeType)
	if not building or not building.Parent then return false end
	local roleAttr = employeeType and GetRoleAssignmentAttr(employeeType) or "AssignedEmployee"
	local assignedUuid = building:GetAttribute(roleAttr)
	if assignedUuid then
		local _, assignedData = FindActiveEmployeeDataByUUID(assignedUuid)
		if assignedData then
			return true
		end
		building:SetAttribute(roleAttr, nil)
		RefreshBuildingOccupancy(building)
	end
	local buildingAssignments = AssignedBuildings[building]
	if type(buildingAssignments) == "table" and employeeType then
		local trackedUuid = buildingAssignments[employeeType]
		if trackedUuid then
			local _, assignedData = FindActiveEmployeeDataByUUID(trackedUuid)
			if assignedData then
				return true
			end
			buildingAssignments[employeeType] = nil
		end
	end
	return false
end

local function AssignBuildingToEmployee(building, employeeData)
	if not building or not employeeData then return false end
	if IsBuildingTaken(building, employeeData.Type) then return false end

	AssignedBuildings[building] = AssignedBuildings[building] or {}
	AssignedBuildings[building][employeeData.Type] = employeeData.UUID
	building:SetAttribute(GetRoleAssignmentAttr(employeeData.Type), employeeData.UUID)

	local presenceAttr = SERVICE_ROLE_ATTRS[employeeData.Type]
	if presenceAttr then
		building:SetAttribute(presenceAttr, true)
	end
	RefreshBuildingOccupancy(building)
	UpdateSlopeRoleCoverage(employeeData, building)

	employeeData.Assignment = building.Name
	employeeData.AssignmentModel = building
	employeeData.AssignmentUUID = building:GetAttribute("UUID")
	return true
end

local function UnassignBuildingFromEmployee(employeeData)
	if not employeeData then return end
	local building = employeeData.AssignmentModel
	if building then
		local buildingAssignments = AssignedBuildings[building]
		if type(buildingAssignments) == "table" then
			buildingAssignments[employeeData.Type] = nil
			if next(buildingAssignments) == nil then
				AssignedBuildings[building] = nil
			end
		else
			AssignedBuildings[building] = nil
		end
		local roleAttr = GetRoleAssignmentAttr(employeeData.Type)
		if building:GetAttribute(roleAttr) == employeeData.UUID then
			building:SetAttribute(roleAttr, nil)
		end
		ClearRoleCoverage(employeeData, building)
		RefreshBuildingOccupancy(building)
	end
	employeeData.Assignment = nil
	employeeData.AssignmentModel = nil
	employeeData.AssignmentUUID = nil
end

local function FindBuildingForEmployee(employeeType, employeePosition, ownerId, currentAssignment)
	local typeData = Config.GetTypeData(employeeType)
	if not typeData then return nil end
	local placedObjects = workspace:FindFirstChild("PlacedObjects")
	if not placedObjects then return nil end
	local assignmentType = typeData.AssignmentType

	local function IsValidBuildingType(obj)
		local objType = obj:GetAttribute("Type")
		local objName = obj.Name
		if assignmentType == "Lift" then
			return objType == "TwoPoint" or objType == "Carpet"
		elseif assignmentType == "Restaurant" then
			return objType == "Food" or objName:find("Restaurant") or objName:find("Food")
		elseif assignmentType == "Rental" then
			return objType == "Rental" or objName:find("Rental")
		elseif assignmentType == "Snowgun" then
			return SnowGunShared.IsSnowGunName(objName)
		elseif assignmentType == "Cleaning" then
			return IsCleanableGuestBuilding(obj)
		elseif assignmentType == "Slope" then
			return obj:GetAttribute("Difficulty") ~= nil or objName:find("Slope") ~= nil
		end
		return false
	end

	local bestBuilding = nil
	local bestScore = -math.huge
	local searchPos = employeePosition or Vector3.zero
	for _, obj in ipairs(placedObjects:GetDescendants()) do
		if obj:IsA("Model") and IsValidBuildingType(obj) and IsOwnerCompatibleObject(obj, ownerId) then
			local isCurrent = currentAssignment and currentAssignment == obj
			if isCurrent or not IsBuildingTaken(obj, employeeType) then
				local score = GetDemandScoreForBuilding(employeeType, obj, searchPos, ownerId)
				if isCurrent then
					score += 12
				end
				if score > bestScore then
					bestScore = score
					bestBuilding = obj
				end
			end
		end
	end
	return bestBuilding
end

local function NormalizeBuildingLookupName(value)
	if type(value) ~= "string" then
		return ""
	end
	return string.lower(value):gsub("[^%w]+", "")
end

local function NameMatchesLookupTokens(name, tokens)
	local normalized = NormalizeBuildingLookupName(name)
	if normalized == "" then
		return false
	end
	for _, token in ipairs(tokens) do
		if normalized:find(token, 1, true) then
			return true
		end
	end
	return false
end

local function IsSpecialBuildingMatch(kind, obj)
	if not obj or not obj:IsA("Model") then
		return false
	end
	local objType = tostring(obj:GetAttribute("Type") or "")
	local objCategory = tostring(obj:GetAttribute("Category") or "")
	local name = obj.Name
	local kindKey = NormalizeBuildingLookupName(kind)

	if kindKey == "medcenter" then
		return objType == "MedCenter"
			or objType == "Medical"
			or objCategory == "MedCenter"
			or NameMatchesLookupTokens(name, { "medcenter", "medicalcenter", "firstaid" })
	elseif kindKey == "skipatrolhut" then
		return objType == "PatrolHut"
			or objCategory == "PatrolHut"
			or NameMatchesLookupTokens(name, { "skipatrolhut", "patrolhut", "patrolbase" })
	elseif kindKey == "ticketoffice" then
		return objType == "TicketOffice"
			or objCategory == "TicketOffice"
			or NameMatchesLookupTokens(name, { "ticketoffice", "bigticketoffice", "ticketbooth" })
	end

	return false
end

local function FindNearestSpecialBuilding(kind, ownerId, originPos)
	originPos = originPos or Vector3.zero
	local bestModel = nil
	local bestDistance = math.huge
	local seen = {}

	local function consider(obj)
		if not obj or seen[obj] then
			return
		end
		seen[obj] = true
		if not obj:IsA("Model") then
			return
		end
		if not IsOwnerCompatibleObject(obj, ownerId) then
			return
		end
		if not IsSpecialBuildingMatch(kind, obj) then
			return
		end
		local probePos = GetServiceProbePosition(obj)
		local dist = (probePos - originPos).Magnitude
		if dist < bestDistance then
			bestDistance = dist
			bestModel = obj
		end
	end

	local placedObjects = workspace:FindFirstChild("PlacedObjects")
	if placedObjects then
		for _, obj in ipairs(placedObjects:GetDescendants()) do
			consider(obj)
		end
	end
	for _, obj in ipairs(workspace:GetChildren()) do
		consider(obj)
	end

	return bestModel
end

local function ShouldUsePatrolHutMode(data)
	if data.HutPatrolMode == nil then
		local hash = 0
		for i = 1, #tostring(data.UUID or "") do
			hash = (hash + string.byte(tostring(data.UUID), i) * i) % 2048
		end
		if hash == 0 then
			hash = tonumber(data.OwnerId) or math.random(1, 2047)
		end
		data.HutPatrolMode = (hash % 2 == 0)
	end
	return data.HutPatrolMode == true
end

local function BuildPatrolHutPoints(hutModel)
	if not hutModel then
		return nil
	end
	local points = {}
	local cf, size = hutModel:GetBoundingBox()
	local center, fwd, right = cf.Position, cf.LookVector, cf.RightVector
	local radius = math.max(12, math.min(math.max(size.X, size.Z) * 0.7, 42))
	table.insert(points, GetSafeGroundPosition(center + fwd * radius, true))
	table.insert(points, GetSafeGroundPosition(center - fwd * radius, true))
	table.insert(points, GetSafeGroundPosition(center + right * radius, true))
	table.insert(points, GetSafeGroundPosition(center - right * radius, true))
	return points
end

local function FindDoorLikeDescendant(model)
	if not model then return nil end
	for _, desc in ipairs(model:GetDescendants()) do
		if desc:IsA("BasePart") or desc:IsA("Model") then
			local lowerName = string.lower(desc.Name)
			if lowerName == "door" or lowerName:find("door", 1, true) then
				return desc
			end
		end
	end
	return nil
end

local function FindNamedAttachment(root, names)
	if not root then
		return nil
	end
	for _, name in ipairs(names) do
		local attachment = root:FindFirstChild(name, true)
		if attachment and attachment:IsA("Attachment") then
			return attachment
		end
	end
	return nil
end

local function GetIndoorFloorPart(assignment)
	if not assignment then
		return nil
	end
	local floorPart = assignment:FindFirstChild("Base", true)
		or assignment:FindFirstChild("Foundation", true)
		or assignment:FindFirstChild("Floor", true)
		or assignment.PrimaryPart
	if floorPart and floorPart:IsA("BasePart") then
		return floorPart
	end
	return nil
end

local function GetIndoorFloorY(assignment, fallbackPos)
	local floorPart = GetIndoorFloorPart(assignment)
	if floorPart then
		return floorPart.Position.Y + (floorPart.Size.Y * 0.5) + 3
	end
	local samplePos = fallbackPos or (assignment and assignment:GetPivot().Position) or Vector3.zero
	return GetSafeGroundPosition(samplePos).Y
end

local function GetIndoorWorkPosition(assignment)
	local cf, size = assignment:GetBoundingBox()
	local floorY = GetIndoorFloorY(assignment, cf.Position)
	local spawnAttachment = FindNamedAttachment(assignment, {"EmployeeSpawn", "StaffSpawn", "WorkPosition", "Spawn"})
	if spawnAttachment then
		local attachmentPos = spawnAttachment.WorldPosition
		if math.abs(attachmentPos.Y - floorY) <= 6 then
			local workPos = Vector3.new(attachmentPos.X, floorY, attachmentPos.Z)
			local axis = spawnAttachment.WorldAxis
			local horizontalAxis = Vector3.new(axis.X, 0, axis.Z)
			if horizontalAxis.Magnitude < 0.1 then
				horizontalAxis = cf.LookVector
			else
				horizontalAxis = horizontalAxis.Unit
			end
			return workPos, workPos + horizontalAxis * 8
		end
	end

	local outward = cf.LookVector
	local door = FindDoorLikeDescendant(assignment)
	local entryCenter = Vector3.new(
		cf.Position.X + outward.X * (size.Z * 0.5),
		floorY,
		cf.Position.Z + outward.Z * (size.Z * 0.5)
	)
	if door then
		local doorCF, doorSize = door:GetBoundingBox()
		local horizontal = Vector3.new(doorCF.Position.X - cf.Position.X, 0, doorCF.Position.Z - cf.Position.Z)
		if horizontal.Magnitude > 0.1 then
			outward = horizontal.Unit
		end
		entryCenter = Vector3.new(doorCF.Position.X, floorY, doorCF.Position.Z)
		local insideDepth = math.max(3.5, math.min(math.max(doorSize.Z, doorSize.X) * 1.1, math.max(size.Z, size.X) * 0.24))
		local approachDepth = math.max(4, math.max(doorSize.Z, doorSize.X) * 0.75)
		local workPos = entryCenter - outward * insideDepth
		local facePos = entryCenter + outward * approachDepth
		return Vector3.new(workPos.X, floorY, workPos.Z), Vector3.new(facePos.X, floorY, facePos.Z)
	end

	local floorPart = GetIndoorFloorPart(assignment)
	local interiorCenter = cf.Position
	if floorPart then
		interiorCenter = Vector3.new(floorPart.Position.X, floorY, floorPart.Position.Z)
	end
	local workPos = Vector3.new(interiorCenter.X, floorY, interiorCenter.Z)
	local facePos = entryCenter + outward * math.max(4, size.Z * 0.12)
	return workPos, Vector3.new(facePos.X, floorY, facePos.Z)
end

local function ShowSpeechBubble(npc, message, duration)
	if not npc or not npc.Parent then return end
	local head = npc:FindFirstChild("Head")
	if not head then return end
	local existing = head:FindFirstChild("SpeechBubble")
	if existing then existing:Destroy() end
	duration = duration or 4

	local bubble = Instance.new("BillboardGui")
	bubble.Name = "SpeechBubble"
	bubble.Size = UDim2.new(0, 200, 0, 60)
	bubble.StudsOffset = Vector3.new(0, 5.5, 0)
	bubble.MaxDistance = 80
	bubble.Parent = head

	local bg = Instance.new("Frame", bubble)
	bg.Size = UDim2.new(1, 0, 1, 0)
	bg.BackgroundColor3 = Color3.new(1, 1, 1)
	bg.BackgroundTransparency = 0.1
	Instance.new("UICorner", bg).CornerRadius = UDim.new(0, 12)

	local text = Instance.new("TextLabel", bg)
	text.Size = UDim2.new(1, -10, 1, -10)
	text.Position = UDim2.new(0, 5, 0, 5)
	text.BackgroundTransparency = 1
	text.Text = message
	text.TextColor3 = Color3.fromRGB(40, 40, 40)
	text.Font = Enum.Font.GothamMedium
	text.TextSize = 14
	text.TextWrapped = true

	task.delay(duration, function()
		if bubble and bubble.Parent then bubble:Destroy() end
	end)
end

local function CreateNameTag(npc, typeData, employeeData)
	local head = npc:FindFirstChild("Head")
	if not head then return end

	local bg = Instance.new("BillboardGui", head)
	bg.Name = "NameTag"
	bg.Size = UDim2.new(0, 180, 0, 50)
	bg.StudsOffset = Vector3.new(0, 2.5, 0)
	bg.AlwaysOnTop = true
	bg.MaxDistance = 100

	local frame = Instance.new("Frame", bg)
	frame.Size = UDim2.new(1, 0, 1, 0)
	frame.BackgroundColor3 = Color3.fromRGB(20, 20, 25)
	frame.BackgroundTransparency = 0.3
	Instance.new("UICorner", frame).CornerRadius = UDim.new(0, 8)

	local strip = Instance.new("Frame", frame)
	strip.Size = UDim2.new(0, 4, 1, -6)
	strip.Position = UDim2.new(0, 3, 0, 3)
	strip.BackgroundColor3 = typeData.Color
	Instance.new("UICorner", strip).CornerRadius = UDim.new(0, 2)

	local emoji = Instance.new("TextLabel", frame)
	emoji.Size = UDim2.new(0, 25, 0, 25)
	emoji.Position = UDim2.new(0, 12, 0.5, 0)
	emoji.AnchorPoint = Vector2.new(0, 0.5)
	emoji.BackgroundTransparency = 1
	emoji.Text = typeData.Emoji
	emoji.TextSize = 18

	local nameLbl = Instance.new("TextLabel", frame)
	nameLbl.Name = "NameLabel"
	nameLbl.Size = UDim2.new(1, -45, 0, 20)
	nameLbl.Position = UDim2.new(0, 40, 0, 5)
	nameLbl.BackgroundTransparency = 1
	nameLbl.Text = typeData.Name
	nameLbl.TextColor3 = Color3.new(1, 1, 1)
	nameLbl.Font = Enum.Font.GothamBold
	nameLbl.TextSize = 14
	nameLbl.TextXAlignment = Enum.TextXAlignment.Left

	local statusLbl = Instance.new("TextLabel", frame)
	statusLbl.Name = "StatusLabel"
	statusLbl.Size = UDim2.new(1, -45, 0, 15)
	statusLbl.Position = UDim2.new(0, 40, 0, 25)
	statusLbl.BackgroundTransparency = 1
	statusLbl.Text = "Level " .. employeeData.Level .. " • Idle"
	statusLbl.TextColor3 = Color3.fromRGB(150, 150, 150)
	statusLbl.Font = Enum.Font.Gotham
	statusLbl.TextSize = 11
	statusLbl.TextXAlignment = Enum.TextXAlignment.Left
end

local function UpdateNameTag(npc, state, level)
	local head = npc:FindFirstChild("Head")
	if not head then return end
	local nameTag = head:FindFirstChild("NameTag")
	if not nameTag then return end
	local frame = nameTag:FindFirstChild("Frame")
	if not frame then return end
	local statusLbl = frame:FindFirstChild("StatusLabel")
	if statusLbl then
		local stateMap = {
			Working = "Working",
			Moving = "Walking",
			Break = "On break",
			Paused = "PAUSED",
			Wandering = "Patrolling",
			Patrolling = "Patrolling",
			Rescuing = "Rescuing",
			EscortToMed = "Escorting",
			Grooming = "Grooming",
			Teaching = "Teaching",
			Repairing = "Repairing",
			Overwhelmed = "Busy",
			Standby = "Standby",
			WaitingForNight = "Waiting",
			WaitingForSnowcat = "Waiting",
			WaitingStudent = "Waiting",
			SettingUp = "Setting up",
		}
		local stateText = stateMap[state] or "Idle"
		local unpaidTag = WageUnpaid and " UNPAID" or ""
		statusLbl.Text = "Lv" .. level .. " • " .. stateText .. unpaidTag
		local colorMap = {
			Paused = Color3.fromRGB(255, 80, 80),
			Working = Color3.fromRGB(80, 255, 80),
			Overwhelmed = Color3.fromRGB(255, 185, 60),
			Standby = Color3.fromRGB(120, 190, 255),
			Wandering = Color3.fromRGB(255, 200, 50),
			Rescuing = Color3.fromRGB(255, 100, 100),
			EscortToMed = Color3.fromRGB(255, 145, 105),
			Grooming = Color3.fromRGB(255, 200, 50),
			Teaching = Color3.fromRGB(50, 200, 100),
			Repairing = Color3.fromRGB(255, 165, 0),
		}
		statusLbl.TextColor3 = colorMap[state] or Color3.fromRGB(150, 150, 150)
	end
end

local FindPlacedObjectByUUID

local function GetEmployeesFolder()
	local folder = workspace:FindFirstChild("Employees")
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = "Employees"
		folder.Parent = workspace
	end
	return folder
end

local function SpawnEmployee(employeeType, spawnPos, ownerId, existingData)
	local typeData = Config.GetTypeData(employeeType)
	if not typeData then return nil end

	local customRigs = ReplicatedStorage:FindFirstChild("EmployeeRigs")
	local rigTemplate = ReplicatedStorage:FindFirstChild(employeeType) 
		or ReplicatedStorage:FindFirstChild(employeeType .. "Rig")
		or (customRigs and (customRigs:FindFirstChild(employeeType) or customRigs:FindFirstChild(employeeType .. "Rig")))

	local useOwnerAvatar = not (rigTemplate and rigTemplate:IsA("Model"))
	local ownerDesc = nil
	if useOwnerAvatar then
		pcall(function()
			ownerDesc = Players:GetHumanoidDescriptionFromUserId(ownerId or 1)
		end)
	end

	local model
	if useOwnerAvatar and ownerDesc then
		local ok, result = pcall(function()
			return Players:CreateHumanoidModelFromDescription(ownerDesc, Enum.HumanoidRigType.R15)
		end)
		if ok and result then
			model = result
			-- Add a colored Highlight so the employee stands out from guests
			local highlight = Instance.new("Highlight")
			local uniformColor = Config.GetTypeData(employeeType) and Config.GetTypeData(employeeType).UniformColor
			highlight.FillColor = uniformColor or Color3.fromRGB(0, 120, 255)
			highlight.FillTransparency = 0.6
			highlight.OutlineColor = uniformColor or Color3.fromRGB(0, 120, 255)
			highlight.OutlineTransparency = 0.3
			highlight.DepthMode = Enum.HighlightDepthMode.Occluded
			highlight.Parent = model
		else
			model = nil -- fall through to rig fallback
		end
	end
	if not model and rigTemplate and rigTemplate:IsA("Model") then
		model = rigTemplate:Clone()
	end
	if not model then
		-- No dedicated rig template: always use LiftOperator rig as a stable R6 base
		-- so every employee type has working Motor6Ds and never falls apart.
		local fallbackRig = customRigs and (
			customRigs:FindFirstChild("LiftOperator")
			or customRigs:FindFirstChild("MechanicBot")
		)
		if fallbackRig and fallbackRig:IsA("Model") then
			model = fallbackRig:Clone()
		else
			-- Last resort: build a minimal R6 rig by hand so we never depend on avatar service
			model = Instance.new("Model")
			local hrp = Instance.new("Part")
			hrp.Name = "HumanoidRootPart"; hrp.Size = Vector3.new(2,2,1)
			hrp.Transparency = 1; hrp.Parent = model
			local torso = Instance.new("Part")
			torso.Name = "Torso"; torso.Size = Vector3.new(2,2,1); torso.Parent = model
			local head = Instance.new("Part")
			head.Name = "Head"; head.Size = Vector3.new(2,1,1); head.Parent = model
			local mesh = Instance.new("SpecialMesh", head)
			mesh.Scale = Vector3.new(1.25,1.25,1.25)
			for _, limbInfo in ipairs({{"Left Arm",Vector3.new(1,2,1)},{"Right Arm",Vector3.new(1,2,1)},{"Left Leg",Vector3.new(1,2,1)},{"Right Leg",Vector3.new(1,2,1)}}) do
				local limb = Instance.new("Part")
				limb.Name = limbInfo[1]; limb.Size = limbInfo[2]; limb.Parent = model
			end
			local hum = Instance.new("Humanoid", model)
			model.PrimaryPart = hrp
			-- Root joint
			local rootJoint = Instance.new("Motor6D", hrp)
			rootJoint.Name = "RootJoint"; rootJoint.Part0 = hrp; rootJoint.Part1 = torso
			-- Neck
			local neck = Instance.new("Motor6D", torso)
			neck.Name = "Neck"; neck.Part0 = torso; neck.Part1 = head
			neck.C0 = CFrame.new(0,1,0); neck.C1 = CFrame.new(0,-0.5,0)
			-- Shoulders & Hips
			for _, jInfo in ipairs({
				{"Right Shoulder",torso,model:FindFirstChild("Right Arm"),CFrame.new(1,0.5,0),CFrame.new(-0.5,0.5,0)},
				{"Left Shoulder",torso,model:FindFirstChild("Left Arm"),CFrame.new(-1,0.5,0),CFrame.new(0.5,0.5,0)},
				{"Right Hip",torso,model:FindFirstChild("Right Leg"),CFrame.new(0.5,-1,0),CFrame.new(0,1,0)},
				{"Left Hip",torso,model:FindFirstChild("Left Leg"),CFrame.new(-0.5,-1,0),CFrame.new(0,1,0)},
			}) do
				local m6d = Instance.new("Motor6D", torso)
				m6d.Name = jInfo[1]; m6d.Part0 = jInfo[2]; m6d.Part1 = jInfo[3]
				m6d.C0 = jInfo[4]; m6d.C1 = jInfo[5]
			end
		end
		-- Apply uniform colors from config for this employee type
		local uniformColor = typeData.UniformColor or typeData.Color or Color3.fromRGB(100,100,100)
		local bc = model:FindFirstChildOfClass("BodyColors")
		if not bc then bc = Instance.new("BodyColors", model) end
		bc.TorsoColor3 = uniformColor
		bc.LeftArmColor3 = uniformColor
		bc.RightArmColor3 = uniformColor
		bc.LeftLegColor3 = uniformColor
		bc.RightLegColor3 = uniformColor
		bc.HeadColor3 = Color3.fromRGB(245, 205, 168) -- skin tone
		-- Remove any shirt graphic that might look out of place
		local shirtGraphic = model:FindFirstChildOfClass("ShirtGraphic")
		if shirtGraphic then shirtGraphic:Destroy() end
	end

	local uuid = existingData and existingData.UUID or HttpService:GenerateGUID(false):sub(1, 8)
	model.Name = employeeType .. "_" .. uuid

	if not model.PrimaryPart then
		model.PrimaryPart = model:FindFirstChild("HumanoidRootPart") or model:FindFirstChild("Torso") or model:FindFirstChild("UpperTorso")
	end

	local hum = model:FindFirstChild("Humanoid")
	if not hum then
		hum = Instance.new("Humanoid")
		hum.Parent = model
	end

	hum.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
	hum.WalkSpeed = typeData.BaseWalkSpeed

	local safePos = GetSafeGroundPosition(spawnPos)
	model:PivotTo(CFrame.new(safePos))

	model:SetAttribute("TargetPosition", nil)
	model:SetAttribute("IsEmployee", true)
	model:SetAttribute("OwnerId", ownerId)
	model:SetAttribute("EmployeeOwnerId", ownerId)
	model:SetAttribute("EmployeeType", employeeType)
	model:SetAttribute("UUID", uuid)
	model:SetAttribute("EmployeeOwnerId", ownerId)
	model:SetAttribute("EmployeeType", employeeType)
	model:SetAttribute("UUID", uuid)
	model:SetAttribute("EmployeeSkiing", false)
	model:SetAttribute("MovementSpeedMultiplier", 1)

	AttachSkisToEmployee(model, employeeType)
	model.Parent = GetEmployeesFolder()
	pcall(function()
		CollectionService:AddTag(model, "Employee")
	end)

	-- Keep skiing employees on server ownership so patrol physics do not depend on a client.
	local ownerPlayer = Players:GetPlayerByUserId(ownerId)
	local networkOwner = EMPLOYEE_SKI_TYPES[employeeType] and nil or ownerPlayer
	-- Temporarily anchor root so gravity doesn't drop the NPC before the client takes
	-- network ownership and calls Humanoid:MoveTo() (fixes "falls on spawn, stuck ~1 min").
	local rootForAnchor = model:FindFirstChild("HumanoidRootPart") or model.PrimaryPart
	if rootForAnchor and rootForAnchor:IsA("BasePart") then
		rootForAnchor.Anchored = true
	end
	for _, part in ipairs(model:GetDescendants()) do
		if part:IsA("BasePart") then
			part.Anchored = part == rootForAnchor
			pcall(function() part:SetNetworkOwner(networkOwner) end)
		end
	end
	task.delay(0.5, function()
		if rootForAnchor and rootForAnchor.Parent then
			rootForAnchor.Anchored = false
		end
	end)

	local animator = hum:FindFirstChildOfClass("Animator") or Instance.new("Animator", hum)
	local walkTrack = animator:LoadAnimation(WalkAnim)

	hum.Running:Connect(function(speed)
		if speed > 0.5 then
			if not walkTrack.IsPlaying then walkTrack:Play() end
			walkTrack:AdjustSpeed(speed / 16)
		else
			if walkTrack.IsPlaying then walkTrack:Stop() end
		end
	end)

	local lvl = existingData and existingData.Level or 1
	local employeeData = {
		UUID = uuid, Type = employeeType, Level = lvl,
		OwnerId = ownerId, State = "Idle", Paused = false,
		Assignment = nil, AssignmentModel = nil, AssignmentUUID = existingData and existingData.AssignmentUUID or nil,
		LastActionTime = 0, LastMoveTime = 0,
		NextBreakCheck = os.time() + math.random(60, 120),
		TargetPosition = nil, IsMoving = false,
		MoveStartTime = 0, MoveStartPos = nil, MoveIssuedAt = 0,
		WalkSpeed = Config.GetStatAtLevel(typeData.BaseWalkSpeed, typeData.UpgradeStats.WalkSpeed or 0, lvl),
		Efficiency = Config.GetStatAtLevel(typeData.BaseEfficiency, typeData.UpgradeStats.Efficiency or 0, lvl),
		MovementSpeedMultiplier = 1,
		UseSkis = EMPLOYEE_SKI_TYPES[employeeType] == true,
		TasksCompleted = existingData and existingData.TasksCompleted or 0,
		TotalEarnings = existingData and existingData.TotalEarnings or 0,
		HireTime = existingData and existingData.HireTime or os.time(),
		WagesPaid = true, LastWeatherSpeech = 0,
		JoblessTime = 0,
		RestoreGraceUntil = existingData and (os.time() + 45) or 0,
		LastKnownPosition = safePos,
	}

	local savedBuilding = nil
	if existingData and (existingData.AssignmentUUID or existingData.Assignment) then
		savedBuilding = FindPlacedObjectByUUID(existingData.AssignmentUUID, ownerId)
		if not savedBuilding and existingData.Assignment then
			local placedObjects = workspace:FindFirstChild("PlacedObjects")
			local bestMatch = nil
			local bestDistance = math.huge
			if placedObjects then
				for _, obj in ipairs(placedObjects:GetDescendants()) do
					if obj:IsA("Model") and obj.Name == existingData.Assignment and IsOwnerCompatibleObject(obj, ownerId) and not IsBuildingTaken(obj, employeeType) then
						local distance = (obj:GetPivot().Position - safePos).Magnitude
						if distance < bestDistance then
							bestDistance = distance
							bestMatch = obj
						end
					end
				end
			end
			savedBuilding = bestMatch
		end
	end

	local shouldAssignOnSpawn = typeData.RequiresAssignment or (typeData.JobType == "Stationary" and typeData.AssignmentType ~= nil)
	if shouldAssignOnSpawn then
		if savedBuilding and not IsBuildingTaken(savedBuilding, employeeType) then
			AssignBuildingToEmployee(savedBuilding, employeeData)
		else
			local building = FindBuildingForEmployee(employeeType, spawnPos, ownerId)
			if building then AssignBuildingToEmployee(building, employeeData) end
		end
	end

	CreateNameTag(model, typeData, employeeData)

	local clickTarget = model.PrimaryPart or model:FindFirstChildWhichIsA("BasePart")
	if clickTarget then
		local cd = Instance.new("ClickDetector", clickTarget)
		cd.MaxActivationDistance = 25
		cd.MouseClick:Connect(function(player)
			employeeData.Paused = not employeeData.Paused
			if employeeData.Paused then
				model:SetAttribute("TargetPosition", nil)
				ShowSpeechBubble(model, "Taking a pause.", 2)
			else
				employeeData.State = "Idle"
				ShowSpeechBubble(model, "Back to work.", 2)
			end
			UpdateNameTag(model, employeeData.Paused and "Paused" or employeeData.State, employeeData.Level)
			BroadcastEmployeeUpdate()
		end)
	end

	ActiveEmployees[model] = employeeData
	HAS_SPAWNED_EMPLOYEE_THIS_SESSION = true
	pcall(RecalculateEffects)

	task.delay(1, function()
		local line = Config.GetSpeechLine(employeeType, "Idle")
		if line then ShowSpeechBubble(model, line) end
	end)

	BroadcastEmployeeUpdate()
	return model, employeeData
end

-- ANTI-STUTTER: Offloaded Pathfinding Request Engine
local function MoveToTarget(npcModel, data, targetPos)
	local root = npcModel.PrimaryPart
	if not root then return false end
	local currentPos = root.Position
	local dist = (Vector3.new(targetPos.X, 0, targetPos.Z) - Vector3.new(currentPos.X, 0, currentPos.Z)).Magnitude

	if dist < 6 then
		data.IsMoving = false
		npcModel:SetAttribute("TargetPosition", nil)
		return false
	end

	data.IsMoving = true

	local hum = npcModel:FindFirstChildOfClass("Humanoid")
	local currentTarget = npcModel:GetAttribute("TargetPosition")
	if not currentTarget or (currentTarget - targetPos).Magnitude > 2 then
		npcModel:SetAttribute("TargetPosition", targetPos)
		local wm = GetWeatherMultipliers()
		local effMult = (data.WagesPaid == false) and 0.75 or 1
		local travelMult = math.max(0.75, tonumber(data.MovementSpeedMultiplier) or 1)
		local resolvedWalkSpeed = math.max(10, data.WalkSpeed * wm.SpeedMult * effMult * travelMult)
		npcModel:SetAttribute("WalkSpeed", resolvedWalkSpeed)
		if hum then
			hum.WalkSpeed = resolvedWalkSpeed
		end

		data.MoveStartTime = os.time()
		data.MoveStartPos = currentPos
		data.MoveIssuedAt = data.MoveStartTime
		data.MoveLastDistance = dist
		data.MoveLastProgressAt = data.MoveStartTime
		data.TeleportCount = 0
	end

	-- SERVER-SIDE MOVEMENT FALLBACK: always call MoveTo so the employee moves
	-- even when the client pathfinding hasn't picked up or is lagging.
	if hum then
		hum:MoveTo(targetPos)
	end

	local now = os.time()
	local lastDistance = tonumber(data.MoveLastDistance) or math.huge
	if dist <= math.max(3, lastDistance - 1.5) then
		data.MoveLastDistance = dist
		data.MoveLastProgressAt = now
	elseif dist > lastDistance + 2 then
		data.MoveLastDistance = dist
	end

	local noTargetProgressFor = now - (data.MoveLastProgressAt or now)
	if now - (data.MoveIssuedAt or now) > 12 and dist <= 18 then
		root.CFrame = CFrame.new(GetSafeGroundPosition(targetPos))
		data.IsMoving = false
		npcModel:SetAttribute("TargetPosition", nil)
		data.MoveLastDistance = nil
		data.MoveLastProgressAt = nil
		data.TeleportCount = 0
		return false
	end
	if now - (data.MoveStartTime or now) > 4 then
		local distFromStart = (currentPos - (data.MoveStartPos or currentPos)).Magnitude
		if distFromStart < 3 or (noTargetProgressFor >= 7 and dist > 8) then
			-- Rescue workers that are pinned on walls or moving in place without getting closer.
			root.CFrame = CFrame.new(GetSafeGroundPosition(targetPos))
			data.IsMoving = false
			npcModel:SetAttribute("TargetPosition", nil)
			data.MoveLastDistance = nil
			data.MoveLastProgressAt = nil
			data.TeleportCount = 0
			return false
		else
			data.MoveStartTime = now
			data.MoveStartPos = currentPos
			data.TeleportCount = 0
		end
	end

	return true
end

local function FaceTarget(npc, targetPos)
	local root = npc.PrimaryPart
	if root and (targetPos - root.Position).Magnitude > 1 then
		root.CFrame = CFrame.lookAt(root.Position, Vector3.new(targetPos.X, root.Position.Y, targetPos.Z))
	end
end

local function IsWithinWorkThreshold(currentPos, targetPos, maxDist, maxHorizontalDist)
	if not currentPos or not targetPos then
		return false
	end
	local dist = (currentPos - targetPos).Magnitude
	local hDist = (Vector3.new(currentPos.X, 0, currentPos.Z) - Vector3.new(targetPos.X, 0, targetPos.Z)).Magnitude
	return dist <= (maxDist or 8) or hDist <= (maxHorizontalDist or 5)
end

local function HasReachedStationaryWorkTarget(currentPos, workPos, facePos)
	if IsWithinWorkThreshold(currentPos, workPos, 8, 5) then
		return true
	end
	if facePos and IsWithinWorkThreshold(currentPos, facePos, 10, 7) then
		return true
	end
	return false
end

local function GetWorkPosition(assignment, employeeType)
	if not assignment or not assignment.Parent then return nil, nil end
	local typeData = Config.GetTypeData(employeeType)
	if not typeData then return nil, nil end
	local assignmentType = typeData.AssignmentType
	local pos = assignment:GetPivot().Position

	if assignmentType == "Lift" then
		local startStation = assignment:FindFirstChild("StartStation")
		if startStation then pos = startStation:GetPivot().Position + Vector3.new(3, 0, 3) end
		return GetSafeGroundPosition(pos, true), pos
	elseif assignmentType == "Rental" then
		return GetIndoorWorkPosition(assignment)
	elseif assignmentType == "Restaurant" then
		return GetIndoorWorkPosition(assignment)
	elseif assignmentType == "Cleaning" then
		return GetIndoorWorkPosition(assignment)
	elseif assignmentType == "Snowgun" then
		local spawnAttachment = FindNamedAttachment(assignment, {"EmployeeSpawn", "StaffSpawn", "WorkPosition", "Spawn"})
		if spawnAttachment then
			local attachmentPos = spawnAttachment.WorldPosition
			local safeGroundPos = GetSafeGroundPosition(attachmentPos)
			local workPos = Vector3.new(
				attachmentPos.X,
				math.max(attachmentPos.Y, safeGroundPos.Y),
				attachmentPos.Z
			)
			return workPos, pos
		end
		local cf, size = assignment:GetBoundingBox()
		local offsetDistance = math.max(4, math.max(size.X, size.Z) * 0.45)
		local workPos = cf.Position + (cf.RightVector * offsetDistance)
		local safeGroundPos = GetSafeGroundPosition(workPos)
		return Vector3.new(workPos.X, math.max(workPos.Y, safeGroundPos.Y), workPos.Z), pos
	end
	return pos, pos
end

local function SnapEmployeeToWorkPosition(npcModel, workPos, facePos, assignment)
	local root = GetEmployeeRootPart(npcModel)
	if not root or not workPos then
		return false
	end
	local hum = npcModel:FindFirstChildOfClass("Humanoid")
	if hum then
		hum.PlatformStand = false
	end
	root.Anchored = false
	local finalY = assignment and GetIndoorFloorY(assignment, workPos) or GetSafeGroundPosition(workPos).Y
	local finalPos = Vector3.new(workPos.X, finalY, workPos.Z)
	npcModel:PivotTo(CFrame.new(finalPos))
	if facePos then
		FaceTarget(npcModel, facePos)
	end
	return true
end

FindPlacedObjectByUUID = function(uuid, ownerId)
	if type(uuid) ~= "string" or uuid == "" then
		return nil
	end
	local placedObjects = workspace:FindFirstChild("PlacedObjects")
	if not placedObjects then
		return nil
	end
	for _, obj in ipairs(placedObjects:GetDescendants()) do
		if obj:IsA("Model") and obj:GetAttribute("UUID") == uuid and IsOwnerCompatibleObject(obj, ownerId) then
			return obj
		end
	end
	return nil
end

local function ResolveAssignment(data)
	if data.AssignmentModel and data.AssignmentModel.Parent then
		return data.AssignmentModel
	end
	local byUuid = FindPlacedObjectByUUID(data.AssignmentUUID, data.OwnerId)
	if byUuid then
		data.AssignmentModel = byUuid
		data.Assignment = byUuid.Name
		data.AssignmentUUID = byUuid:GetAttribute("UUID") or data.AssignmentUUID
		return byUuid
	end
	if not data.Assignment then
		return nil
	end
	local placedObjects = workspace:FindFirstChild("PlacedObjects")
	if not placedObjects then
		return nil
	end
	local bestMatch = nil
	local bestDistance = math.huge
	local origin = data.LastKnownPosition or Vector3.zero
	for _, obj in ipairs(placedObjects:GetDescendants()) do
		if obj:IsA("Model") and obj.Name == data.Assignment and IsOwnerCompatibleObject(obj, data.OwnerId) then
			local distance = (obj:GetPivot().Position - origin).Magnitude
			if distance < bestDistance then
				bestDistance = distance
				bestMatch = obj
			end
		end
	end
	if bestMatch then
		data.AssignmentModel = bestMatch
		data.Assignment = bestMatch.Name
		data.AssignmentUUID = bestMatch:GetAttribute("UUID") or data.AssignmentUUID
		return bestMatch
	end
	return nil
end

function GetEfficiency(data)
	local wm = GetWeatherMultipliers()
	local baseMult = (data.WagesPaid == false) and Settings.UnpaidEfficiencyMult or 1
	return data.Efficiency * wm.EfficiencyMult * baseMult
end

function GetIncomeMult(data)
	local wm = GetWeatherMultipliers()
	return wm.IncomeMult * ((data.WagesPaid == false) and 0.5 or 1)
end

function GetRoleWorkStats(data)
	local ok, stats = pcall(function()
		return Config.GetRoleWorkStats(data.Type, data.Level)
	end)
	return (ok and stats) or {
		Progress = 0,
		QualityMult = 1,
		ActionInterval = 15,
		CrowdCapacity = 5,
		RepairPower = 1,
		RecoveryThresholdBonus = 0,
		SnowPower = 1,
		LessonDurationMult = 1,
	}
end

function FindSlopes()
	local slopes = {}
	local placedObjects = workspace:FindFirstChild("PlacedObjects")
	if placedObjects then
		for _, obj in ipairs(placedObjects:GetChildren()) do
			if obj:GetAttribute("Type") == "Slope" or obj:GetAttribute("Difficulty") then
				table.insert(slopes, obj)
			end
		end
	end
	return slopes
end

function FindNearestSlope(pos, ownerIdOrFilter, maybeFilter)
	local ownerId = nil
	local filterFn = nil
	if type(ownerIdOrFilter) == "function" and maybeFilter == nil then
		filterFn = ownerIdOrFilter
	else
		ownerId = ownerIdOrFilter
		filterFn = maybeFilter
	end

	local slopes = FindSlopes()
	local nearest, nearestDist = nil, math.huge
	for _, slope in ipairs(slopes) do
		if IsOwnerCompatibleObject(slope, ownerId) and (not filterFn or filterFn(slope)) then
			local dist = (slope:GetPivot().Position - pos).Magnitude
			if dist < nearestDist then nearestDist = dist; nearest = slope end

		end
	end
	return nearest
end

function GetSlopeIdentity(slope)
	if not slope then
		return nil
	end
	return tostring(slope:GetAttribute("UUID") or slope:GetDebugId())
end

function FindDifferentSlope(pos, ownerId, currentSlope, filterFn)
	local currentId = GetSlopeIdentity(currentSlope)
	local slopes = FindSlopes()
	local nearest, nearestDist = nil, math.huge
	for _, slope in ipairs(slopes) do
		if IsOwnerCompatibleObject(slope, ownerId) and (not filterFn or filterFn(slope)) then
			if not currentId or GetSlopeIdentity(slope) ~= currentId then
				local dist = (slope:GetPivot().Position - pos).Magnitude
				if dist < nearestDist then
					nearestDist = dist
					nearest = slope
				end
			end
		end
	end
	return nearest
end

function CountEmployeesAssignedToSlope(employeeType, slope, ownerId)
	if not slope then
		return 0
	end
	local targetId = GetSlopeIdentity(slope)
	if not targetId then
		return 0
	end
	local count = 0
	for _, employeeData in pairs(ActiveEmployees) do
		if employeeData.Type == employeeType and employeeData.OwnerId == ownerId then
			local activeSlope = employeeData.PatrolSlope
			if activeSlope and activeSlope.Parent and GetSlopeIdentity(activeSlope) == targetId then
				count += 1
			end
		end
	end
	return count
end

function IsRelevantPatrolGuestState(state)
	return state ~= "Leaving"
		and state ~= "Sleeping"
		and state ~= "GoingToHotel"
		and state ~= "Eating"
		and state ~= "Resting"
end

function FindBestPatrolSlope(pos, ownerId, currentSlope, filterFn)
	local slopes = FindSlopes()
	local bestSlope, bestScore = nil, math.huge
	local currentId = GetSlopeIdentity(currentSlope)
	for _, slope in ipairs(slopes) do
		if IsOwnerCompatibleObject(slope, ownerId) and (not filterFn or filterFn(slope)) then
			local slopePos = slope:GetPivot().Position
			local boxCF, boxSize = slope:GetBoundingBox()
			local slopeRadius = math.clamp(math.max(boxSize.X, boxSize.Z) * 0.3, 55, 170)
			local assignedCount = CountEmployeesAssignedToSlope("SkiPatrol", slope, ownerId)
			local crashedCount = CountNearbyCrashedGuests(slopePos, slopeRadius, ownerId)
			local activeGuestCount = CountNearbyGuests(slopePos, slopeRadius, function(guestModel)
				if not GuestMatchesOwner(guestModel, ownerId) then
					return false
				end
				local state = tostring(guestModel:GetAttribute("State") or "")
				return IsRelevantPatrolGuestState(state)
			end)
			local dist = (slopePos - pos).Magnitude
			local sameSlopePenalty = (currentId and GetSlopeIdentity(slope) == currentId) and 24 or 0
			local staleCoveragePenalty = slope:GetAttribute("SkiPatrolCoverage") and 30 or 0
			local difficultyBonus = GetSlopeDifficultyWeight(slope) * 8
			local score = (dist * 0.32) + sameSlopePenalty + staleCoveragePenalty + (assignedCount * 120) - (crashedCount * 160) - (activeGuestCount * 5.5) - difficultyBonus
			if score < bestScore then
				bestScore = score
				bestSlope = slope
			end
		end
	end
	return bestSlope
end

local SKI_PATROL_CLAIM_TTL = 45
local SKI_PATROL_RESCUE_MAX_SECONDS = 28
local SKI_PATROL_ESCORT_MAX_SECONDS = 26
local SKI_PATROL_RESCUE_STALE_SECONDS = 10

function GetGuestRootPart(guestModel)
	if not guestModel then
		return nil
	end
	return guestModel:FindFirstChild("HumanoidRootPart") or guestModel.PrimaryPart
end

function GetSkiPatrolClaimKey(data)
	if not data then
		return ""
	end
	return tostring(data.UUID or data.OwnerId or "")
end

function ClearSkiPatrolClaim(guestModel, claimKey)
	if not guestModel or not guestModel.Parent then
		return
	end
	local currentClaim = tostring(guestModel:GetAttribute("SkiPatrolClaimedBy") or "")
	if claimKey and claimKey ~= "" and currentClaim ~= "" and currentClaim ~= claimKey then
		return
	end
	guestModel:SetAttribute("SkiPatrolClaimedBy", nil)
	guestModel:SetAttribute("SkiPatrolClaimedAt", nil)
end

function ClaimSkiPatrolGuest(guestModel, claimKey)
	if not guestModel or not guestModel.Parent or claimKey == "" then
		return false
	end
	guestModel:SetAttribute("SkiPatrolClaimedBy", claimKey)
	guestModel:SetAttribute("SkiPatrolClaimedAt", os.clock())
	return true
end

function ResetSkiPatrolRescueState(npcModel, data, claimKey, cooldownSeconds)
	if not data then
		return
	end
	if data.RescueTarget then
		ClearSkiPatrolClaim(data.RescueTarget, claimKey)
	end
	data.RescueTarget = nil
	data.MedCenterTarget = nil
	data.RescueStartedAt = nil
	data.RescueLastProgressAt = nil
	data.RescueLastDistance = nil
	data.EscortStartedAt = nil
	data.EscortLastProgressAt = nil
	data.EscortLastDistance = nil
	data.State = "Idle"
	data.IsMoving = false
	data.RescueCooldownUntil = os.clock() + math.max(1.5, tonumber(cooldownSeconds) or 4)
	if npcModel and npcModel.Parent then
		npcModel:SetAttribute("TargetPosition", nil)
	end
end

function FindCrashedGuest(pos, radius, ownerId, claimKey)
	local foundGuest = nil
	local foundDistance = math.huge
	local now = os.clock()
	IterateGuestModels(function(guestModel)
		if not GuestMatchesOwner(guestModel, ownerId) then
			return
		end
		if not guestModel:GetAttribute("IsCrashed") then
			return
		end

		local activeClaim = tostring(guestModel:GetAttribute("SkiPatrolClaimedBy") or "")
		if activeClaim ~= "" and activeClaim ~= claimKey then
			local claimAt = tonumber(guestModel:GetAttribute("SkiPatrolClaimedAt")) or 0
			if claimAt <= 0 or (now - claimAt) < SKI_PATROL_CLAIM_TTL then
				return
			end
			ClearSkiPatrolClaim(guestModel, activeClaim)
		end

		local root = GetGuestRootPart(guestModel)
		if root and root:IsA("BasePart") then
			local distance = (root.Position - pos).Magnitude
			if distance < radius and distance < foundDistance then
				foundGuest = guestModel
				foundDistance = distance
			end
		end
	end)
	return foundGuest
end

function CountNearbyGuests(pos, radius, predicate)
	local count = 0
	IterateGuestModels(function(guestModel)
		if predicate and not predicate(guestModel) then
			return
		end
		local root = guestModel:FindFirstChild("HumanoidRootPart")
		if root and (root.Position - pos).Magnitude < radius then
			count += 1
		end
	end)
	return count
end

function DoWander(npcModel, data)
	-- Periodically try to find a building assignment (throttled, every 15s)
	if not data.LastBuildingScan or (os.time() - data.LastBuildingScan) >= 15 then
		data.LastBuildingScan = os.time()
		local root = npcModel.PrimaryPart
		if root then
			local building = FindBuildingForEmployee(data.Type, root.Position, data.OwnerId)
			if building then
				AssignBuildingToEmployee(building, data)
				data.State = "Idle"
				data.WanderTarget = nil
				ShowSpeechBubble(npcModel, "Found a workplace!", 3)
				return
			end
		end
	end

	if data.State ~= "Wandering" or not data.WanderTarget then
		data.WanderTarget = npcModel.PrimaryPart.Position + Vector3.new(math.random(-30, 30), 0, math.random(-30, 30))
		data.State = "Wandering"
	end
	if not MoveToTarget(npcModel, data, data.WanderTarget) then
		data.WanderTarget = nil
		data.State = "Idle"
	end
	UpdateNameTag(npcModel, data.State, data.Level)
end

function GetMechanicTarget(currentPos, currentTarget, ownerId)
	local placedObjects = workspace:FindFirstChild("PlacedObjects")
	if not placedObjects then return nil, "None" end

	local priorityLift = nil
	local priorityScore = math.huge
	local damagedLift = nil
	local damagedScore = math.huge
	local patrolLift = nil
	local patrolScore = math.huge

	for _, obj in ipairs(placedObjects:GetChildren()) do
		if IsRepairableLiftModel(obj) and IsOwnerCompatibleObject(obj, ownerId) then
			local cond = tonumber(obj:GetAttribute("Condition")) or 100
			local status = tostring(obj:GetAttribute("Status") or "Stopped")
			local liftPos = obj:GetPivot().Position
			local dist = (currentPos - liftPos).Magnitude
			local hasOperator = obj:GetAttribute("LiftStaffed") == true
			local supportLevel = math.max(0, tonumber(obj:GetAttribute("StaffLevel")) or 0)
			local currentTargetBonus = (currentTarget and currentTarget == obj) and -18 or 0
			local supportBonus = hasOperator and -8 or 0

			-- Check if another mechanic is already assigned
			if not (currentTarget and currentTarget == obj) and obj:GetAttribute("MechanicSupport") == true then
				continue
			end

			if status == "Broken" or cond <= 35 or obj:GetAttribute("NeedsMechanicHelp") == true then
				local score = dist + (cond * 0.85) + currentTargetBonus + supportBonus - (supportLevel * 2)
				if status == "Broken" then
					score -= 45
				end
				if score < priorityScore then
					priorityScore = score
					priorityLift = obj
				end
			elseif cond < 92 then
				local score = dist + (cond * 0.6) + currentTargetBonus + supportBonus
				if score < damagedScore then
					damagedScore = score
					damagedLift = obj
				end
			else
				local score = dist + currentTargetBonus
				if score < patrolScore then
					patrolScore = score
					patrolLift = obj
				end
			end
		end
	end

	if priorityLift then return priorityLift, "Priority" end
	if damagedLift then return damagedLift, "Repair" end
	if patrolLift then return patrolLift, "Patrol" end
	return nil, "None"
end

function UpdateMechanic(npcModel, data)
	local hum = npcModel:FindFirstChild("Humanoid")
	if not hum then return end
	local eff = GetEfficiency(data)
	local roleStats = GetRoleWorkStats(data)

	local targetLift, intent = GetMechanicTarget(npcModel.PrimaryPart.Position, data.RepairTarget, data.OwnerId)

	if not targetLift then
		DoWander(npcModel, data)
		return
	end

	data.RepairTarget = targetLift

	local function stampSupport(lift, isActiveRepair)
		if not lift or not lift.Parent then return end
		lift:SetAttribute("MechanicSupport", true)
		lift:SetAttribute("MechanicSupportLevel", data.Level)
		lift:SetAttribute("MechanicSupportUUID", data.UUID)
		lift:SetAttribute("MechanicCoverageUntil", os.time() + (isActiveRepair and 25 or 18))
		if isActiveRepair then
			lift:SetAttribute("NeedsMechanicHelp", false)
		end
	end

	if intent == "Priority" or intent == "Repair" then
		local cond = tonumber(targetLift:GetAttribute("Condition")) or 100

		local targetPos = targetLift:GetPivot().Position
		local startStation = targetLift:FindFirstChild("StartStation")
		if startStation then targetPos = startStation:GetPivot().Position end
		targetPos = GetSafeGroundPosition(targetPos, true)

		local dist = (npcModel.PrimaryPart.Position - targetPos).Magnitude
		local hDist = (Vector3.new(npcModel.PrimaryPart.Position.X, 0, npcModel.PrimaryPart.Position.Z) - Vector3.new(targetPos.X, 0, targetPos.Z)).Magnitude

		if dist > 15 and hDist > 6 then
			data.State = "Moving"
			MoveToTarget(npcModel, data, targetPos)
			stampSupport(targetLift, false)
			if intent == "Priority" and math.random() < 0.05 then
				ShowSpeechBubble(npcModel, "Priority lift check. On it.", 2)
			end
		else
			data.IsMoving = false
			npcModel:SetAttribute("TargetPosition", nil)
			FaceTarget(npcModel, targetPos)
			data.State = "Repairing"
			stampSupport(targetLift, true)

			if not data.RepairLastTick then data.RepairLastTick = os.time() end

			if os.time() - data.RepairLastTick >= 1 then
				data.RepairLastTick = os.time()
				local healAmount = math.max(4, math.floor((5 + data.Level) * eff * roleStats.RepairPower))
				local newCond = math.min(100, cond + healAmount)
				targetLift:SetAttribute("Condition", newCond)
				targetLift:SetAttribute("NeedsMechanicHelp", newCond < 55)

				local status = tostring(targetLift:GetAttribute("Status") or "Stopped")
				local staffed = targetLift:GetAttribute("LiftStaffed") == true
					if status == "Broken" and newCond >= math.max(28, 35 - roleStats.RecoveryThresholdBonus) then
					targetLift:SetAttribute("Status", "Running")
					targetLift:SetAttribute("TargetSpeed", 1)
					status = "Running"
				end
				if status == "Slow" and newCond >= math.max(42, 55 - roleStats.RecoveryThresholdBonus) then
					targetLift:SetAttribute("Status", "Running")
					targetLift:SetAttribute("TargetSpeed", 1)
				end
				SyncLiftCache(targetLift)

				if newCond >= 96 then
					data.TasksCompleted = data.TasksCompleted + 1
					local typeData = Config.GetTypeData(data.Type)
					local income = math.floor((typeData.RepairIncome or 30) * eff * GetIncomeMult(data))
					AddIncome(data.OwnerId, income, "LiftRepair", Enum.AnalyticsEconomyTransactionType.Gameplay)
					data.TotalEarnings = data.TotalEarnings + income
					ShowSpeechBubble(npcModel, "Lift tuned up and ready.", 3)
					data.RepairTarget = nil
				elseif math.random() < 0.2 then
					ShowSpeechBubble(npcModel, "Keeping this lift in shape.", 3)
				end
			end
		end
	elseif intent == "Patrol" then
		local targetPos = targetLift:GetPivot().Position
		local startStation = targetLift:FindFirstChild("StartStation")
		if startStation then targetPos = startStation:GetPivot().Position end
		targetPos = GetSafeGroundPosition(targetPos, true)

		local dist = (npcModel.PrimaryPart.Position - targetPos).Magnitude
		local hDist = (Vector3.new(npcModel.PrimaryPart.Position.X, 0, npcModel.PrimaryPart.Position.Z) - Vector3.new(targetPos.X, 0, targetPos.Z)).Magnitude

		if dist > 20 and hDist > 6 then
			data.State = "Patrolling"
			MoveToTarget(npcModel, data, targetPos)
			stampSupport(targetLift, false)
		else
			data.IsMoving = false
			npcModel:SetAttribute("TargetPosition", nil)
			data.State = "Idle"
			stampSupport(targetLift, false)
			data.RepairTarget = nil
			if math.random() < 0.1 then
				ShowSpeechBubble(npcModel, "Routine lift check complete.", 3)
			end
		end
	end

	UpdateNameTag(npcModel, data.State, data.Level)
end

function UpdateLiftOperator(npcModel, data)
	local hum = npcModel:FindFirstChild("Humanoid")
	if not hum or not npcModel.PrimaryPart then return end
	local assignment = ResolveAssignment(data)

	if not assignment then
		UnassignBuildingFromEmployee(data)
		local newBuilding = FindBuildingForEmployee(data.Type, npcModel.PrimaryPart.Position, data.OwnerId, data.AssignmentModel)
		if newBuilding then
			AssignBuildingToEmployee(newBuilding, data)
			data.State = "Idle"
		else
			DoWander(npcModel, data)
			return
		end
		assignment = data.AssignmentModel
	end
	if not assignment then
		DoWander(npcModel, data)
		return
	end


	local workPos, facePos = GetWorkPosition(assignment, data.Type)
	if not workPos then return end
	local weather = GetCurrentWeather()
	local wm = GetWeatherMultipliers()
	local eff = GetEfficiency(data)
	local roleStats = GetRoleWorkStats(data)
	local now = os.time()
	local status = tostring(assignment:GetAttribute("Status") or "Stopped")
	local condition = tonumber(assignment:GetAttribute("Condition")) or 100
	local targetSpeed = tonumber(assignment:GetAttribute("TargetSpeed")) or 0
	local desiredSpeed = 1
	local needsRepair = status == "Broken" or condition <= 72
	local needsStart = status == "Stopped" or targetSpeed <= 0.01
	local dist = (npcModel.PrimaryPart.Position - workPos).Magnitude
	local hDist = (Vector3.new(npcModel.PrimaryPart.Position.X, 0, npcModel.PrimaryPart.Position.Z) - Vector3.new(workPos.X, 0, workPos.Z)).Magnitude

	if dist > 10 and hDist > 6 then
		data.State = needsRepair and "Repairing" or "Moving"
		MoveToTarget(npcModel, data, workPos)
		UpdateNameTag(npcModel, data.State, data.Level)
		return
	end

	data.IsMoving = false
	npcModel:SetAttribute("TargetPosition", nil)
	if facePos then FaceTarget(npcModel, facePos) end
	assignment:SetAttribute("HasLifty", true)
	assignment:SetAttribute("StaffEfficiency", eff)
	assignment:SetAttribute("StaffLevel", data.Level)
	assignment:SetAttribute("LiftStaffed", true)
	assignment:SetAttribute("LiftOperatorUUID", data.UUID)
	assignment:SetAttribute("LiftQueueCapacity", roleStats.CrowdCapacity)
	assignment:SetAttribute("LiftServiceQuality", roleStats.QualityMult)
	assignment:SetAttribute("LiftRepairPower", roleStats.RepairPower)

	if needsRepair then
		data.State = "Repairing"
		if now - (data.LastRepairTick or 0) >= 1 then
			data.LastRepairTick = now
			local repairAmount = math.max(4, math.floor(7 * eff * roleStats.RepairPower))
			local repairedCond = math.min(100, condition + repairAmount)
			assignment:SetAttribute("Condition", repairedCond)
			condition = repairedCond

			if status == "Broken" and repairedCond >= math.max(30, 40 - math.floor(roleStats.Progress * 10)) then
				assignment:SetAttribute("Status", "Stopped")
				assignment:SetAttribute("TargetSpeed", 0)
				status = "Stopped"
				ShowSpeechBubble(npcModel, "Got it moving again. Finishing checks.", 3)
			end

			if repairedCond >= math.max(76, 90 - math.floor(roleStats.Progress * 12)) then
				assignment:SetAttribute("Status", "Running")
				assignment:SetAttribute("TargetSpeed", desiredSpeed)
				status = "Running"
				needsRepair = false
				needsStart = false
				ShowSpeechBubble(npcModel, "Lift repaired and back online.", 3)
			end

			SyncLiftCache(assignment)
		end
	elseif needsStart then
		data.State = "Starting"
		assignment:SetAttribute("Status", "Running")
		assignment:SetAttribute("TargetSpeed", desiredSpeed)
		SyncLiftCache(assignment)
		ShowSpeechBubble(npcModel, "Starting the lift.", 3)
		status = "Running"
	else
		data.State = "Working"
		if status ~= "Running" or math.abs(targetSpeed - desiredSpeed) > 0.001 then
			assignment:SetAttribute("Status", "Running")
			assignment:SetAttribute("TargetSpeed", desiredSpeed)
			SyncLiftCache(assignment)
		end
		if wm.LiftSpeedOverride and now - data.LastWeatherSpeech > 60 then
			data.LastWeatherSpeech = now
			local line = Config.GetWeatherSpeech(data.Type, weather)
			if line then ShowSpeechBubble(npcModel, line, 4) end
		end
	end

	if now - data.LastActionTime > roleStats.ActionInterval then
		local typeData = Config.GetTypeData(data.Type)
		local probePos = GetServiceProbePosition(assignment)
		local nearbyGuests = CountNearbyGuests(probePos, 85, function(guestModel)
			if not GuestMatchesOwner(guestModel, data.OwnerId) then
				return false
			end
			local guestState = tostring(guestModel:GetAttribute("State") or "")
			return guestState ~= "Leaving" and guestState ~= "Sleeping"
		end)
		local handledGuests = math.min(nearbyGuests, roleStats.CrowdCapacity)
		local overflowGuests = math.max(0, nearbyGuests - roleStats.CrowdCapacity)
		local serviceBonus = handledGuests * (2.75 * roleStats.QualityMult)
		local conditionBonus = math.max(0, condition - 55) * (0.28 + (roleStats.Progress * 0.08))
		local recoveryBonus = (data.State == "Repairing" or data.State == "Starting") and (16 + math.floor(roleStats.Progress * 10)) or 0
		local overloadPenalty = (overflowGuests > 0) and math.max(0.72, 1 - (overflowGuests * 0.05)) or 1
		if overflowGuests > 0 and data.State == "Working" then
			data.State = "Busy"
		end
		local income = math.floor((typeData.BaseIncome + data.Level * 2 + serviceBonus + conditionBonus + recoveryBonus) * eff * GetIncomeMult(data) * overloadPenalty)
		AddIncome(data.OwnerId, income, "LiftOperatorBonus", Enum.AnalyticsEconomyTransactionType.Gameplay)
		data.TotalEarnings = data.TotalEarnings + income
		data.LastActionTime = now
		data.TasksCompleted = data.TasksCompleted + 1

		if (data.State == "Working" or data.State == "Busy") and condition < 98 then
			assignment:SetAttribute("Condition", math.min(100, condition + math.max(1, math.floor(eff * (2 + roleStats.Progress * 2)))))
		end

		if math.random() < 0.18 then
			local line = Config.GetSpeechLine(data.Type, data.State == "Working" and "Working" or "Idle")
			if line then ShowSpeechBubble(npcModel, line) end
		end
	end

	if not assignment.Parent then
		UnassignBuildingFromEmployee(data)
		data.State = "Idle"
	end

	UpdateNameTag(npcModel, data.State, data.Level)
end

function UpdateSkiPatrol(npcModel, data)
	local hum = npcModel:FindFirstChild("Humanoid")
	if not hum or not npcModel.PrimaryPart then return end
	local eff = GetEfficiency(data)
	local rescueRadius = 130 + (data.Level * 18)
	local claimKey = GetSkiPatrolClaimKey(data)
	SetEmployeeSkiMode(npcModel, data, true, 1.8)

	if data.RescueCooldownUntil and os.clock() < data.RescueCooldownUntil then
		UpdateNameTag(npcModel, data.State, data.Level)
		return
	end

	if data.State ~= "Rescuing" then
		data.RescueStartedAt = nil
		data.RescueLastProgressAt = nil
		data.RescueLastDistance = nil
	end
	if data.State ~= "EscortToMed" then
		data.EscortStartedAt = nil
		data.EscortLastProgressAt = nil
		data.EscortLastDistance = nil
	end

	if data.State ~= "Rescuing" and data.State ~= "EscortToMed" then
		if data.RescueTarget then
			local heldTarget = data.RescueTarget
			local heldRoot = GetGuestRootPart(heldTarget)
			if heldTarget.Parent and heldTarget:GetAttribute("IsCrashed") and heldRoot and heldRoot:IsA("BasePart") then
				ClaimSkiPatrolGuest(heldTarget, claimKey)
				data.State = "Rescuing"
				data.RescueStartedAt = os.clock()
				data.RescueLastProgressAt = data.RescueStartedAt
				data.RescueLastDistance = math.huge
			else
				ClearSkiPatrolClaim(heldTarget, claimKey)
				data.RescueTarget = nil
			end
		end
		if data.State ~= "Rescuing" then
			local crashed = FindCrashedGuest(npcModel.PrimaryPart.Position, rescueRadius, data.OwnerId, claimKey)
			if crashed then
				if data.RescueTarget and data.RescueTarget ~= crashed then
					ClearSkiPatrolClaim(data.RescueTarget, claimKey)
				end
				data.RescueTarget = crashed
				ClaimSkiPatrolGuest(crashed, claimKey)
				data.State = "Rescuing"
				data.RescueStartedAt = os.clock()
				data.RescueLastProgressAt = data.RescueStartedAt
				data.RescueLastDistance = math.huge
				ShowSpeechBubble(npcModel, "Crash spotted. Heading over.", 3)
			end
		end
	end

	if data.State == "Rescuing" then
		local target = data.RescueTarget
		local targetRoot = target and GetGuestRootPart(target) or nil
		if not target or not target.Parent or not target:GetAttribute("IsCrashed") or not targetRoot or not targetRoot:IsA("BasePart") then
			ResetSkiPatrolRescueState(npcModel, data, claimKey, 4)
		else
			local nowClock = os.clock()
			ClaimSkiPatrolGuest(target, claimKey)
			local dist = (npcModel.PrimaryPart.Position - targetRoot.Position).Magnitude
			local hDist = (Vector3.new(npcModel.PrimaryPart.Position.X, 0, npcModel.PrimaryPart.Position.Z) - Vector3.new(targetRoot.Position.X, 0, targetRoot.Position.Z)).Magnitude
			data.RescueStartedAt = data.RescueStartedAt or nowClock
			data.RescueLastProgressAt = data.RescueLastProgressAt or nowClock
			local lastRescueDistance = tonumber(data.RescueLastDistance) or math.huge
			if dist <= (lastRescueDistance - 1) then
				data.RescueLastProgressAt = nowClock
				data.RescueLastDistance = dist
			elseif dist > (lastRescueDistance + 2) then
				data.RescueLastDistance = dist
			end
			if (nowClock - data.RescueStartedAt) > SKI_PATROL_RESCUE_MAX_SECONDS
				or (nowClock - (data.RescueLastProgressAt or nowClock)) > SKI_PATROL_RESCUE_STALE_SECONDS then
				ResetSkiPatrolRescueState(npcModel, data, claimKey, 3.5)
				UpdateNameTag(npcModel, data.State, data.Level)
				return
			end
			if dist > 8 and hDist > 6 then
				MoveToTarget(npcModel, data, targetRoot.Position)
			else
				data.IsMoving = false
				npcModel:SetAttribute("TargetPosition", nil)
				ShowSpeechBubble(npcModel, "Help is here.", 3)
				local typeData = Config.GetTypeData(data.Type)
				local income = math.floor((typeData and typeData.RescueIncome or 20) * eff * GetIncomeMult(data))
				AddIncome(data.OwnerId, income, "SkiPatrolRescue", Enum.AnalyticsEconomyTransactionType.Gameplay)
				data.TotalEarnings = data.TotalEarnings + income
				data.TasksCompleted = data.TasksCompleted + 1
				if target and target.Parent then
					local medCenter = FindNearestSpecialBuilding("MedCenter", data.OwnerId, targetRoot.Position)
					target:SetAttribute("NeedsSkiPatrol", false)
					target:SetAttribute("PendingMedCenterVisit", medCenter ~= nil)
					target:SetAttribute("PatrolRescueTriggered", true)
					data.RescueStartedAt = nil
					data.RescueLastProgressAt = nil
					data.RescueLastDistance = nil
					if medCenter then
						target:SetAttribute("RescueMedCenterName", medCenter.Name)
						data.MedCenterTarget = medCenter
						data.State = "EscortToMed"
						data.RescueCooldownUntil = os.clock() + 0.65
						data.RescueTarget = nil
						data.EscortStartedAt = os.clock()
						data.EscortLastProgressAt = data.EscortStartedAt
						data.EscortLastDistance = math.huge
						ClearSkiPatrolClaim(target, claimKey)
					else
						ResetSkiPatrolRescueState(npcModel, data, claimKey, 8)
					end
				else
					ResetSkiPatrolRescueState(npcModel, data, claimKey, 8)
				end
			end
		end
		UpdateNameTag(npcModel, data.State, data.Level)
		return
	end

	if data.State == "EscortToMed" then
		local nowClock = os.clock()
		data.EscortStartedAt = data.EscortStartedAt or nowClock
		data.EscortLastProgressAt = data.EscortLastProgressAt or nowClock
		local medCenter = data.MedCenterTarget
		if not medCenter or not medCenter.Parent then
			medCenter = FindNearestSpecialBuilding("MedCenter", data.OwnerId, npcModel.PrimaryPart.Position)
			data.MedCenterTarget = medCenter
		end
		if medCenter then
			local targetPos = GetServiceProbePosition(medCenter)
			local dist = (npcModel.PrimaryPart.Position - targetPos).Magnitude
			local hDist = (Vector3.new(npcModel.PrimaryPart.Position.X, 0, npcModel.PrimaryPart.Position.Z) - Vector3.new(targetPos.X, 0, targetPos.Z)).Magnitude
			local lastEscortDistance = tonumber(data.EscortLastDistance) or math.huge
			if dist <= (lastEscortDistance - 1) then
				data.EscortLastProgressAt = nowClock
				data.EscortLastDistance = dist
			elseif dist > (lastEscortDistance + 2) then
				data.EscortLastDistance = dist
			end
			if (nowClock - data.EscortStartedAt) > SKI_PATROL_ESCORT_MAX_SECONDS
				or (nowClock - (data.EscortLastProgressAt or nowClock)) > SKI_PATROL_RESCUE_STALE_SECONDS then
				ResetSkiPatrolRescueState(npcModel, data, claimKey, 5)
				UpdateNameTag(npcModel, data.State, data.Level)
				return
			end
			if dist > 10 and hDist > 6 then
				MoveToTarget(npcModel, data, targetPos)
			else
				data.IsMoving = false
				npcModel:SetAttribute("TargetPosition", nil)
				ShowSpeechBubble(npcModel, "Dropping guest at med center.", 3)
				data.State = "Idle"
				data.MedCenterTarget = nil
				data.EscortStartedAt = nil
				data.EscortLastProgressAt = nil
				data.EscortLastDistance = nil
				data.RescueCooldownUntil = os.clock() + 6
			end
		else
			ResetSkiPatrolRescueState(npcModel, data, claimKey, 5)
		end
		UpdateNameTag(npcModel, data.State, data.Level)
		return
	end

	local useHutMode = ShouldUsePatrolHutMode(data)
	if useHutMode then
		local patrolHut = data.PatrolHutModel
		if not patrolHut or not patrolHut.Parent then
			patrolHut = FindNearestSpecialBuilding("SkiPatrolHut", data.OwnerId, npcModel.PrimaryPart.Position)
			data.PatrolHutModel = patrolHut
			data.HutPatrolPoints = nil
			data.HutPatrolIndex = nil
		end
		if patrolHut then
			if data.PatrolSlope and data.PatrolSlope.Parent and CountEmployeesAssignedToSlope("SkiPatrol", data.PatrolSlope, data.OwnerId) <= 1 then
				ClearRoleCoverage(data, data.PatrolSlope)
			end
			data.PatrolSlope = nil
			if not data.HutPatrolPoints or #data.HutPatrolPoints == 0 then
				data.HutPatrolPoints = BuildPatrolHutPoints(patrolHut)
				data.HutPatrolIndex = 1
			end
			if data.HutPatrolPoints and #data.HutPatrolPoints > 0 then
				if data.State == "Idle" then
					data.HutPatrolIndex = (data.HutPatrolIndex or 0) % #data.HutPatrolPoints + 1
					data.State = "Moving"
					data.IsMoving = false
				elseif data.State == "Moving" then
					local hutPoint = data.HutPatrolPoints[data.HutPatrolIndex]
					if hutPoint and not MoveToTarget(npcModel, data, hutPoint) then
						data.State = "Patrolling"
						data.PatrolEndTime = os.time() + math.random(6, 11)
						data.TasksCompleted = data.TasksCompleted + 1
						local income = math.floor((12 + data.Level * 2) * eff * GetIncomeMult(data))
						AddIncome(data.OwnerId, income, "SkiPatrolHut", Enum.AnalyticsEconomyTransactionType.Gameplay)
						data.TotalEarnings = data.TotalEarnings + income
					end
				elseif data.State == "Patrolling" then
					if os.time() > (data.PatrolEndTime or 0) then
						data.State = "Idle"
					end
				end
				UpdateNameTag(npcModel, data.State, data.Level)
				return
			end
		end
	end

	if not data.PatrolSlope or not data.PatrolSlope.Parent then
		data.PatrolSlope = FindBestPatrolSlope(npcModel.PrimaryPart.Position, data.OwnerId, nil)
		data.PatrolPoints = nil
		data.NextSlopeRotateAt = os.time() + math.max(35, 70 - data.Level * 2)
		if data.PatrolSlope then
			UpdateSlopeRoleCoverage(data, data.PatrolSlope)
			local diff = data.PatrolSlope:GetAttribute("Difficulty") or "Green"
			ShowSpeechBubble(npcModel, "Patrolling " .. diff .. " slope.", 3)
		end
	elseif os.time() >= (data.NextSlopeRotateAt or 0) then
		local oldSlope = data.PatrolSlope
		local nextSlope = FindBestPatrolSlope(npcModel.PrimaryPart.Position, data.OwnerId, data.PatrolSlope)
		data.NextSlopeRotateAt = os.time() + math.max(35, 70 - data.Level * 2)
		if nextSlope and nextSlope ~= data.PatrolSlope then
			if oldSlope and CountEmployeesAssignedToSlope("SkiPatrol", oldSlope, data.OwnerId) <= 1 then
				ClearRoleCoverage(data, oldSlope)
			end
			data.PatrolSlope = nextSlope
			data.PatrolPoints = nil
			data.PatrolIndex = nil
			UpdateSlopeRoleCoverage(data, data.PatrolSlope)
			local diff = data.PatrolSlope:GetAttribute("Difficulty") or "Green"
			ShowSpeechBubble(npcModel, "Moving patrol to " .. diff .. ".", 3)
		end
	end

	if data.PatrolSlope and (not data.PatrolPoints or #data.PatrolPoints == 0) then
		local points = {}
		local cf, size = data.PatrolSlope:GetBoundingBox()
		local center, fwd, right = cf.Position, cf.LookVector, cf.RightVector
		table.insert(points, GetSafeGroundPosition(center + fwd * (size.Z/2 - 10), true))
		table.insert(points, GetSafeGroundPosition(center - fwd * (size.Z/2 - 10), true))
		table.insert(points, GetSafeGroundPosition(center + right * (size.X/3), true))
		table.insert(points, GetSafeGroundPosition(center - right * (size.X/3), true))
		data.PatrolPoints = points
		data.PatrolIndex = 1
	end

	if not data.PatrolPoints or #data.PatrolPoints == 0 then
		DoWander(npcModel, data); return
	end

	if data.State == "Idle" then
		data.PatrolIndex = (data.PatrolIndex or 0) % #data.PatrolPoints + 1
		data.State = "Moving"
		data.IsMoving = false
	elseif data.State == "Moving" then
		local target = data.PatrolPoints[data.PatrolIndex]
		if target and not MoveToTarget(npcModel, data, target) then
			data.State = "Patrolling"
			data.PatrolEndTime = os.time() + math.random(5, 10)
			data.TasksCompleted = data.TasksCompleted + 1
			if data.PatrolSlope then
				local diff = data.PatrolSlope:GetAttribute("Difficulty") or "Green"
				local baseIncome = Config.GetDifficultyIncome(data.Type, diff)
				local income = math.floor(baseIncome * eff * GetIncomeMult(data))
				AddIncome(data.OwnerId, income, "SkiPatrolPatrol", Enum.AnalyticsEconomyTransactionType.Gameplay)
				data.TotalEarnings = data.TotalEarnings + income
				UpdateSlopeRoleCoverage(data, data.PatrolSlope)
			end
		end
	elseif data.State == "Patrolling" then
		if os.time() > (data.PatrolEndTime or 0) then data.State = "Idle" end
	end

	UpdateNameTag(npcModel, data.State, data.Level)
end

function UpdateGroomer(npcModel, data)
	local hum = npcModel:FindFirstChild("Humanoid")
	if not hum then return end
	local eff = GetEfficiency(data)
	local weather = GetCurrentWeather()
	local roleStats = GetRoleWorkStats(data)

	if weather == "Blizzard" then
		if data.State ~= "Idle" then
			data.State = "Idle"; data.IsMoving = false
			npcModel:SetAttribute("TargetPosition", nil)
			if os.time() - data.LastWeatherSpeech > 60 then
				data.LastWeatherSpeech = os.time()
				local line = Config.GetWeatherSpeech(data.Type, "Blizzard")
				if line then ShowSpeechBubble(npcModel, line, 4) end
			end
		end
		UpdateNameTag(npcModel, "Idle", data.Level); return
	end

	if _G.SnowcatAI then
		local tryAssign = _G.SnowcatAI.TryAssignGroomer
		if tryAssign and os.time() - (data.LastSnowcatAssignAttempt or 0) >= 5 then
			data.LastSnowcatAssignAttempt = os.time()
			pcall(function()
				tryAssign(data.UUID, data.OwnerId)
			end)
		end
		local bison = _G.SnowcatAI.GetGroomerSnowcat(data.UUID)
		if bison then
			local snowcatState = (_G.SnowcatAI.GetGroomerState and _G.SnowcatAI.GetGroomerState(data.UUID)) or "Driving"
			local activeSlope = (_G.SnowcatAI.GetGroomerTargetSlope and _G.SnowcatAI.GetGroomerTargetSlope(data.UUID)) or nil
			data.State = (snowcatState == "Grooming") and "Grooming" or "Driving"
			data.IsMoving = false

			if activeSlope and activeSlope.Parent then
				data.PatrolSlope = activeSlope
				UpdateSlopeRoleCoverage(data, activeSlope)
			end

			local frame = bison.PrimaryPart
			if frame and npcModel.PrimaryPart then
				local hrp = npcModel.PrimaryPart
				if not frame:FindFirstChild("BisonCharWeld") then
					hum.PlatformStand = true
					hrp.CFrame = frame.CFrame * CFrame.new(0, 3, 0)
					local w = Instance.new("WeldConstraint")
					w.Name = "BisonCharWeld"
					w.Part0 = frame
					w.Part1 = hrp
					w.Parent = frame
					hrp.Anchored = false
				end
			end

			local head = npcModel:FindFirstChild("Head")
			if head then
				local tag = head:FindFirstChild("NameTag")
				if tag then tag.Enabled = false end
			end
			UpdateNameTag(npcModel, data.State, data.Level)
			return
		end

		if data.State == "Driving" or data.State == "Grooming" or data.State == "WaitingForSnowcat" or data.State == "WaitingForNight" then
			hum.PlatformStand = false
			if npcModel.PrimaryPart then
				npcModel.PrimaryPart.Anchored = false
			end
			-- PERF FIX: Search npcModel + parent only instead of entire workspace
			local searchRoots = {npcModel}
			if npcModel.Parent and npcModel.Parent ~= workspace then
				table.insert(searchRoots, npcModel.Parent)
			end
			for _, searchRoot in ipairs(searchRoots) do
				for _, v in ipairs(searchRoot:GetDescendants()) do
					if v.Name == "BisonCharWeld" and v:IsA("WeldConstraint") and v.Part1 == npcModel.PrimaryPart then
						v:Destroy()
					end
				end
			end
			local head = npcModel:FindFirstChild("Head")
			if head then
				local tag = head:FindFirstChild("NameTag")
				if tag then tag.Enabled = true end
			end
		end

		data.IsMoving = false
		npcModel:SetAttribute("TargetPosition", nil)
		local clockTime = game.Lighting.ClockTime
		if clockTime >= 7 and clockTime < 20 then
			data.State = "WaitingForNight"
			if os.time() - (data.LastSnowcatSpeech or 0) > 45 then
				data.LastSnowcatSpeech = os.time()
				ShowSpeechBubble(npcModel, "We groom after dark with the snowcat.", 3)
			end
			UpdateNameTag(npcModel, data.State, data.Level)
			return
		else
			-- Night time: groom slopes on foot even without a snowcat
			data.State = "Grooming"
			if os.time() - (data.LastSnowcatSpeech or 0) > 30 then
				data.LastSnowcatSpeech = os.time()
				ShowSpeechBubble(npcModel, "No snowcat available — grooming on foot.", 3)
			end
			-- Fall through to patrol/groom logic below
		end
	end

	if not data.PatrolSlope or not data.PatrolSlope.Parent then
		data.PatrolSlope = FindNearestSlope(npcModel.PrimaryPart.Position, data.OwnerId)

		data.PatrolPoints = nil
	end

	if data.PatrolSlope and (not data.PatrolPoints or #data.PatrolPoints == 0) then
		local points = {}
		local cf, size = data.PatrolSlope:GetBoundingBox()
		local center, fwd = cf.Position, cf.LookVector
		for i = 0, 3 do
			local t = i / 3
			table.insert(points, GetSafeGroundPosition(center + fwd * ((0.5 - t) * size.Z)))
		end
		data.PatrolPoints = points
		data.PatrolIndex = 1
	end

	if not data.PatrolPoints or #data.PatrolPoints == 0 then
		DoWander(npcModel, data); return
	end

	if data.State == "Idle" then
		data.PatrolIndex = (data.PatrolIndex or 0) % #data.PatrolPoints + 1
		data.State = "Moving"; data.IsMoving = false
	elseif data.State == "Moving" then
		local target = data.PatrolPoints[data.PatrolIndex]
		if target and not MoveToTarget(npcModel, data, target) then
			data.State = "Grooming"
			data.GroomEndTime = os.time() + math.random(8, 15)
			ShowSpeechBubble(npcModel, "Grooming this section.", 3)
		end
	elseif data.State == "Grooming" then
		if os.time() > (data.GroomEndTime or 0) then
			data.TasksCompleted = data.TasksCompleted + 1
			if data.PatrolSlope then
				local cond = data.PatrolSlope:GetAttribute("SlopeCondition") or 70
				local improvement = math.floor(10 * eff)
				data.PatrolSlope:SetAttribute("SlopeCondition", math.min(100, cond + improvement))
				UpdateSlopeRoleCoverage(data, data.PatrolSlope)
				local diff = data.PatrolSlope:GetAttribute("Difficulty") or "Green"

				local typeData = Config.GetTypeData(data.Type)
				local income = math.floor((typeData.GroomIncome or 10) * eff * GetIncomeMult(data))
				AddIncome(data.OwnerId, income, "SlopeGrooming", Enum.AnalyticsEconomyTransactionType.Gameplay)
				data.TotalEarnings = data.TotalEarnings + income
			end
			data.State = "Idle"
		end
	end
	UpdateNameTag(npcModel, data.State, data.Level)
end

function UpdateSnowmaker(npcModel, data)
	local hum = npcModel:FindFirstChild("Humanoid")
	if not hum then return end
	local assignment = ResolveAssignment(data)

	if not assignment then
		UnassignBuildingFromEmployee(data)
		local newBuilding = FindBuildingForEmployee(data.Type, npcModel.PrimaryPart.Position, data.OwnerId)

		if newBuilding then
			AssignBuildingToEmployee(newBuilding, data)
			data.State = "Idle"
		else
			DoWander(npcModel, data)
			return
		end
		assignment = data.AssignmentModel
	end
	if not assignment then
		DoWander(npcModel, data)
		return
	end

	local function setInactiveRuntime()
		assignment:SetAttribute("SnowmakerActive", false)
		assignment:SetAttribute("SnowmakerIntensity", nil)
		assignment:SetAttribute("SnowStaffEfficiency", nil)
		assignment:SetAttribute("SnowCoverageBonus", nil)
		assignment:SetAttribute("SnowCostReduction", nil)
		assignment:SetAttribute("SnowmakerIntensityBonus", nil)
		SetSnowgunOperationalState(assignment, "Off")
	end

	local workPos, facePos = GetWorkPosition(assignment, data.Type)
	if not workPos then
		setInactiveRuntime()
		return
	end
	local temp = GetCurrentTemperature()
	local clockTime = game.Lighting.ClockTime
	local eff = GetEfficiency(data)
	local typeData = Config.GetTypeData(data.Type)
	local roleStats = GetRoleWorkStats(data)

	if data.State == "Break" then
		setInactiveRuntime()
		UpdateNameTag(npcModel, data.State, data.Level)
		return
	end

	if data.State == "Idle" or data.State == "Moving" then
		local pos = npcModel.PrimaryPart.Position
		local dist = (pos - workPos).Magnitude
		local hDist = (Vector3.new(pos.X, 0, pos.Z) - Vector3.new(workPos.X, 0, workPos.Z)).Magnitude
		if dist > 6 and hDist > 5 then
			data.State = "Moving"
			setInactiveRuntime()
			MoveToTarget(npcModel, data, workPos)
		else
			data.State = "Working"
			data.IsMoving = false
			npcModel:SetAttribute("TargetPosition", nil)
			if facePos then FaceTarget(npcModel, facePos) end
			assignment:SetAttribute("HasSnowmaker", true)
			assignment:SetAttribute("StaffEfficiency", eff)
		end
	elseif data.State == "Working" or data.State == "Overwhelmed" or data.State == "Standby" then
		if facePos then FaceTarget(npcModel, facePos) end

		assignment:SetAttribute("HasSnowmaker", true)
		assignment:SetAttribute("StaffEfficiency", eff)

		local intensity = GetEmployeeSnowmakerIntensity(temp, clockTime)
		if intensity then
			data.State = "Working"
			assignment:SetAttribute("SnowmakerActive", true)
			assignment:SetAttribute("SnowmakerIntensity", intensity)
			assignment:SetAttribute("SnowStaffEfficiency", math.max(0, (eff - 1) * roleStats.SnowPower))
			assignment:SetAttribute("SnowCoverageBonus", math.min(0.6, (0.08 + (data.Level * 0.025)) * roleStats.SnowPower))
			assignment:SetAttribute("SnowCostReduction", math.min(0.5, (0.08 + (data.Level * 0.02)) * (0.92 + roleStats.Progress * 0.35)))
			assignment:SetAttribute("SnowmakerIntensityBonus", math.min(0.45, (0.05 + (data.Level * 0.02)) * roleStats.SnowPower))
			SetSnowgunOperationalState(assignment, intensity)

			if os.time() - data.LastActionTime > roleStats.ActionInterval then
				local coldnessBonus = math.max(0, ((typeData.FreezingTemp or 32) - temp) * 0.35)
				local income = math.floor((typeData.BaseIncome + coldnessBonus + (data.Level * 1.5)) * eff * GetIncomeMult(data))

				AddIncome(data.OwnerId, income, "Snowmaking", Enum.AnalyticsEconomyTransactionType.Gameplay)
				data.TotalEarnings = data.TotalEarnings + income
				data.LastActionTime = os.time()
				data.TasksCompleted = data.TasksCompleted + 1
				if math.random() < 0.2 then
					if temp > (typeData.FreezingTemp or 32) then
						ShowSpeechBubble(npcModel, "Stretching snowmaking into the daytime.", 3)
					else
						ShowSpeechBubble(npcModel, temp < 15 and "Perfect snowmaking temps." or "Making snow at " .. temp .. " degrees", 3)
					end
				end
			end
		else
			data.State = "Standby"
			setInactiveRuntime()

			if os.time() - data.LastWeatherSpeech > 60 then
				data.LastWeatherSpeech = os.time()
				local line = Config.GetWeatherSpeech(data.Type, "TooWarm")
				if line then ShowSpeechBubble(npcModel, line, 4) end
			end
		end

		if not assignment.Parent then
			UnassignBuildingFromEmployee(data)
			data.State = "Idle"
		end
	end
	UpdateNameTag(npcModel, data.State, data.Level)
end

function UpdateStationaryWorker(npcModel, data, attrName)
	local hum = npcModel:FindFirstChild("Humanoid")
	if not hum then return end
	local assignment = ResolveAssignment(data)

	if not assignment then
		UnassignBuildingFromEmployee(data)
		local newBuilding = FindBuildingForEmployee(data.Type, npcModel.PrimaryPart.Position, data.OwnerId)
		if newBuilding then AssignBuildingToEmployee(newBuilding, data); data.State = "Idle"
		else DoWander(npcModel, data); return end
		assignment = data.AssignmentModel
	end
	if not assignment then DoWander(npcModel, data); return end

	local workPos, facePos = GetWorkPosition(assignment, data.Type)
	if not workPos then return end
	local eff = GetEfficiency(data)
	local typeData = Config.GetTypeData(data.Type)
	local roleStats = GetRoleWorkStats(data)

	if data.State == "Idle" or data.State == "Moving" then
		local pos = npcModel.PrimaryPart.Position
		if not HasReachedStationaryWorkTarget(pos, workPos, facePos) then
			data.State = "Moving"
			-- Pathfind to entry point (facePos) instead of interior (workPos)
			-- Buildings have solid walls that block pathfinding to interior positions
			local moveTarget = facePos or workPos
			MoveToTarget(npcModel, data, moveTarget)
		else
			-- Close enough to the entry or interior — snap onto the building floor, not the roof.
			SnapEmployeeToWorkPosition(npcModel, workPos, facePos, assignment)
			data.State = "Working"; data.IsMoving = false
			npcModel:SetAttribute("TargetPosition", nil)
			assignment:SetAttribute(attrName, true)
			assignment:SetAttribute("StaffEfficiency", eff)
			assignment:SetAttribute("StaffLevel", data.Level)
			assignment:SetAttribute("ServiceCapacity", roleStats.CrowdCapacity)
			assignment:SetAttribute("ServiceQuality", roleStats.QualityMult)
			assignment:SetAttribute("ServiceSpeed", roleStats.ActionInterval)
			ShowSpeechBubble(npcModel, (typeData.WorkingLines and typeData.WorkingLines[1]) or "Working.", 3)
		end
	elseif data.State == "Working" or data.State == "Overwhelmed" then
		if facePos then FaceTarget(npcModel, facePos) end

		if os.time() - data.LastActionTime > roleStats.ActionInterval then
			local guestRadius = typeData.GuestProximityRadius or 50
			local probePos = GetServiceProbePosition(assignment)
			local nearbyGuests = CountNearbyGuests(probePos, guestRadius, function(guestModel)
				return GuestMatchesOwner(guestModel, data.OwnerId)
			end)
			local serviceDemand = CountNearbyGuests(probePos, guestRadius, function(guestModel)
				if not GuestMatchesOwner(guestModel, data.OwnerId) then
					return false
				end
				local state = tostring(guestModel:GetAttribute("State") or "")
				if data.Type == "Chef" then
					local hunger = tonumber(guestModel:GetAttribute("Hunger")) or 100
					return hunger < 75 and state ~= "Eating" and state ~= "Leaving" and state ~= "Sleeping"
				end
				return guestModel:GetAttribute("HasSkis") ~= true and state ~= "Leaving" and state ~= "Sleeping"
			end)
			local handledDemand = math.min(serviceDemand, roleStats.CrowdCapacity)
			local overflowDemand = math.max(0, serviceDemand - roleStats.CrowdCapacity)
			local guestBonus = (handledDemand * (typeData.IncomePerNearbyGuest or typeData.IncomePerRental or 2) * roleStats.QualityMult) + (nearbyGuests * (1.2 + (roleStats.Progress * 0.8)))
			local overloadPenalty = overflowDemand > 0 and math.max(0.68, 1 - (overflowDemand * 0.07)) or 1
			assignment:SetAttribute("ServiceOverwhelmed", overflowDemand > 0)
			assignment:SetAttribute("ServiceStress", overflowDemand)
			data.State = overflowDemand > 0 and "Overwhelmed" or "Working"

			local income = math.floor((typeData.BaseIncome + data.Level * 2 + guestBonus) * eff * GetIncomeMult(data) * overloadPenalty)
			local itemName = (data.Type == "Chef") and "FoodSales" or "RentalSales"
			AddIncome(data.OwnerId, income, itemName, Enum.AnalyticsEconomyTransactionType.Gameplay)
			data.TotalEarnings = data.TotalEarnings + income
			data.LastActionTime = os.time()
			data.TasksCompleted = data.TasksCompleted + 1
			assignment:SetAttribute("ServiceDemand", serviceDemand)
			assignment:SetAttribute("ServiceCrowd", nearbyGuests)


			if data.Type == "Chef" and GetCurrentTemperature() < 32 then
				if math.random() < 0.1 then
					local line = Config.GetWeatherSpeech(data.Type, "Cold")
					if line then ShowSpeechBubble(npcModel, line, 3) end
				end
			elseif math.random() < 0.15 then
				local line = Config.GetSpeechLine(data.Type, "Working")
				if line then ShowSpeechBubble(npcModel, line) end
			end
		end

		if not assignment.Parent then
			UnassignBuildingFromEmployee(data); data.State = "Idle"
		end
	end
	UpdateNameTag(npcModel, data.State, data.Level)
end

function UpdateJanitor(npcModel, data)
	local hum = npcModel:FindFirstChild("Humanoid")
	if not hum then return end
	local assignment = ResolveAssignment(data)

	if not assignment then
		UnassignBuildingFromEmployee(data)
		local newBuilding = FindBuildingForEmployee(data.Type, npcModel.PrimaryPart.Position, data.OwnerId)
		if newBuilding then
			AssignBuildingToEmployee(newBuilding, data)
			data.State = "Idle"
		else
			DoWander(npcModel, data)
			return
		end
		assignment = data.AssignmentModel
	end
	if not assignment then
		DoWander(npcModel, data)
		return
	end

	local workPos, facePos = GetWorkPosition(assignment, data.Type)
	if not workPos then
		return
	end
	local eff = GetEfficiency(data)
	local typeData = Config.GetTypeData(data.Type)
	local roleStats = GetRoleWorkStats(data)

	if npcModel:GetAttribute("SpillTaskActive") == true then
		assignment:SetAttribute("HasJanitor", true)
		assignment:SetAttribute("JanitorCoverage", true)
		assignment:SetAttribute("JanitorLevel", data.Level)
		assignment:SetAttribute("StaffEfficiency", eff)
		assignment:SetAttribute("StaffLevel", data.Level)
		local spillTaskState = tostring(npcModel:GetAttribute("SpillTaskState") or "Walking")
		data.State = (spillTaskState == "Cleaning") and "Working" or "Moving"
		data.IsMoving = spillTaskState ~= "Cleaning"
		UpdateNameTag(npcModel, data.State, data.Level)
		return
	end

	if data.State == "Idle" or data.State == "Moving" then
		local pos = npcModel.PrimaryPart.Position
		if not HasReachedStationaryWorkTarget(pos, workPos, facePos) then
			data.State = "Moving"
			-- Pathfind to entry point, not interior (walls block pathfinding)
			local moveTarget = facePos or workPos
			MoveToTarget(npcModel, data, moveTarget)
		else
			-- Close enough to the entry or interior — snap onto a valid grounded work point.
			SnapEmployeeToWorkPosition(npcModel, workPos, facePos)
			data.State = "Working"
			data.IsMoving = false
			npcModel:SetAttribute("TargetPosition", nil)
			assignment:SetAttribute("HasJanitor", true)
			assignment:SetAttribute("JanitorCoverage", true)
			assignment:SetAttribute("JanitorLevel", data.Level)
			assignment:SetAttribute("StaffEfficiency", eff)
			assignment:SetAttribute("StaffLevel", data.Level)
			assignment:SetAttribute("Cleanliness", math.max(tonumber(assignment:GetAttribute("Cleanliness")) or 62, 62))
			assignment:SetAttribute("Dirtiness", 100 - math.clamp(tonumber(assignment:GetAttribute("Cleanliness")) or 62, 0, 100))
			ShowSpeechBubble(npcModel, (typeData.WorkingLines and typeData.WorkingLines[1]) or "Cleaning up.", 3)
		end
	elseif data.State == "Working" or data.State == "Overwhelmed" then
		if facePos then FaceTarget(npcModel, facePos) end

		if os.time() - data.LastActionTime > roleStats.ActionInterval then
			local guestRadius = typeData.GuestProximityRadius or 70
			local probePos = GetServiceProbePosition(assignment)
			local nearbyGuests = CountNearbyGuests(probePos, guestRadius, function(guestModel)
				if not GuestMatchesOwner(guestModel, data.OwnerId) then
					return false
				end
				local state = tostring(guestModel:GetAttribute("State") or "")
				return state ~= "Leaving" and state ~= "Sleeping"
			end)
			local handledGuests = math.min(nearbyGuests, roleStats.CrowdCapacity)
			local overflowGuests = math.max(0, nearbyGuests - roleStats.CrowdCapacity)
			local overloadPenalty = overflowGuests > 0 and math.max(0.7, 1 - (overflowGuests * 0.05)) or 1
			data.State = overflowGuests > 0 and "Overwhelmed" or "Working"

			local currentCleanliness = math.clamp(tonumber(assignment:GetAttribute("Cleanliness")) or 55, 0, 100)
			local trafficMess = nearbyGuests * 0.24
			local cleaningPower = ((11 + (data.Level * 2.1)) + (handledGuests * 1.05)) * eff * roleStats.QualityMult
			local newCleanliness = math.clamp(currentCleanliness - trafficMess + cleaningPower, 35, 100)
			assignment:SetAttribute("HasJanitor", true)
			assignment:SetAttribute("JanitorCoverage", true)
			assignment:SetAttribute("JanitorLevel", data.Level)
			assignment:SetAttribute("CleanAreaTraffic", nearbyGuests)
			assignment:SetAttribute("Cleanliness", newCleanliness)
			assignment:SetAttribute("Dirtiness", 100 - newCleanliness)
			assignment:SetAttribute("NeedsCleaning", newCleanliness < 62)
			assignment:SetAttribute("ServiceOverwhelmed", overflowGuests > 0)
			assignment:SetAttribute("ServiceStress", overflowGuests)

			local guestBonus = handledGuests * ((typeData.IncomePerNearbyGuest or 2) + (roleStats.Progress * 2.2))
			local qualityBonus = math.max(0, newCleanliness - 60) * 0.18
			local income = math.floor((typeData.BaseIncome + guestBonus + qualityBonus) * eff * GetIncomeMult(data) * overloadPenalty)
			AddIncome(data.OwnerId, income, "JanitorService", Enum.AnalyticsEconomyTransactionType.Gameplay)
			data.TotalEarnings = data.TotalEarnings + income
			data.LastActionTime = os.time()
			data.TasksCompleted = data.TasksCompleted + 1

			if math.random() < 0.18 then
				local line = Config.GetSpeechLine(data.Type, "Working")
				if line then ShowSpeechBubble(npcModel, line, 3) end
			end
		end

		if not assignment.Parent then
			UnassignBuildingFromEmployee(data)
			data.State = "Idle"
		end
	end
	UpdateNameTag(npcModel, data.State, data.Level)
end

local INSTRUCTOR_BLOCKED_GUEST_STATES = {
	Leaving = true,
	GoingToHotel = true,
	Sleeping = true,
	Crashed = true,
	Recovering = true,
	RidingLift = true,
	WaitingLift = true,
	UnloadingLift = true,
	RentingGear = true,
	SkiingDown = true,
	SkiingToSlope = true,
	TakingLesson = true,
}

function ResolveGuestModelByUUID(uuid)
	if not uuid or uuid == "" then
		return nil
	end
	local guestsFolder = workspace:FindFirstChild("Guests")
	if not guestsFolder then
		return nil
	end
	for _, guest in ipairs(guestsFolder:GetChildren()) do
		if tostring(guest:GetAttribute("GuestUUID") or "") == tostring(uuid) then
			return guest
		end
	end
	return nil
end

function ClearInstructorStudentAssignment(npcModel, data)
	local assignedGuest = data.AssignedGuestModel
	if (not assignedGuest or not assignedGuest.Parent) and data.AssignedGuestUUID then
		assignedGuest = ResolveGuestModelByUUID(data.AssignedGuestUUID)
	end
	if assignedGuest and assignedGuest.Parent and tostring(assignedGuest:GetAttribute("AssignedInstructorUUID") or "") == tostring(data.UUID or "") then
		assignedGuest:SetAttribute("AssignedInstructorUUID", nil)
		assignedGuest:SetAttribute("LessonTargetX", nil)
		assignedGuest:SetAttribute("LessonTargetY", nil)
		assignedGuest:SetAttribute("LessonTargetZ", nil)
		assignedGuest:SetAttribute("TakingLesson", false)
		assignedGuest:SetAttribute("LessonProgress", nil)
	end
	data.AssignedGuestUUID = nil
	data.AssignedGuestModel = nil
	data.AssignedGuestAt = nil
	npcModel:SetAttribute("AssignedGuestUUID", nil)
end

function GetInstructorLessonSpot(data)
	if not data.PatrolSlope or not data.PatrolSlope.Parent then
		return nil
	end
	local cf, size = data.PatrolSlope:GetBoundingBox()
	local center = cf.Position
	local fwd = cf.LookVector
	return GetSafeGroundPosition(center + fwd * math.clamp(size.Z * 0.18, 6, 18))
end

function FindInstructorLessonCandidate(data, lessonSpot)
	local guestsFolder = workspace:FindFirstChild("Guests")
	if not guestsFolder then
		return nil
	end
	local bestGuest = nil
	local bestScore = math.huge
	for _, guest in ipairs(guestsFolder:GetChildren()) do
		if guest:IsA("Model") and GuestMatchesOwner(guest, data.OwnerId) then
			local guestUUID = tostring(guest:GetAttribute("GuestUUID") or "")
			local assignedInstructorUUID = tostring(guest:GetAttribute("AssignedInstructorUUID") or "")
			local guestState = tostring(guest:GetAttribute("State") or "")
			local skillLevel = tonumber(guest:GetAttribute("SkillLevel")) or 1
			local hunger = tonumber(guest:GetAttribute("Hunger")) or 100
			local energy = tonumber(guest:GetAttribute("Energy")) or 100
			local hasSkis = guest:GetAttribute("HasSkis") ~= false
			local guestRoot = guest.PrimaryPart or guest:FindFirstChild("HumanoidRootPart")
			if guestUUID ~= ""
				and hasSkis
				and skillLevel <= 3
				and hunger >= 15
				and energy >= 15
				and guestRoot
				and (assignedInstructorUUID == "" or assignedInstructorUUID == tostring(data.UUID or ""))
				and not INSTRUCTOR_BLOCKED_GUEST_STATES[guestState] then
				local distToLesson = (guestRoot.Position - lessonSpot).Magnitude
				if distToLesson <= 1200 then
					local score = distToLesson + (skillLevel * 10)
					if score < bestScore then
						bestScore = score
						bestGuest = guest
					end
				end
			end
		end
	end
	return bestGuest
end

function AssignInstructorStudent(npcModel, data, guestModel, lessonSpot)
	local guestUUID = tostring(guestModel:GetAttribute("GuestUUID") or "")
	if guestUUID == "" then
		return false
	end
	data.AssignedGuestUUID = guestUUID
	data.AssignedGuestModel = guestModel
	data.AssignedGuestAt = os.time()
	npcModel:SetAttribute("AssignedGuestUUID", guestUUID)
	guestModel:SetAttribute("AssignedInstructorUUID", tostring(data.UUID or ""))
	guestModel:SetAttribute("LessonTargetX", lessonSpot.X)
	guestModel:SetAttribute("LessonTargetY", lessonSpot.Y)
	guestModel:SetAttribute("LessonTargetZ", lessonSpot.Z)
	guestModel:SetAttribute("TakingLesson", false)
	guestModel:SetAttribute("LessonProgress", nil)
	return true
end

function UpdateInstructor(npcModel, data)
	local hum = npcModel:FindFirstChild("Humanoid")
	if not hum or not npcModel.PrimaryPart then return end
	local eff = GetEfficiency(data)
	local weather = GetCurrentWeather()
	local roleStats = GetRoleWorkStats(data)
	SetEmployeeSkiMode(npcModel, data, true, 1.35)

	if weather == "Blizzard" then
		ClearInstructorStudentAssignment(npcModel, data)
		npcModel:SetAttribute("InstructorLevel", data.Level)
		npcModel:SetAttribute("LessonQuality", math.max(1, math.min(10, math.floor(data.Level * roleStats.QualityMult))))
		npcModel:SetAttribute("LessonDurationScale", roleStats.LessonDurationMult)
		if data.State ~= "Teaching" then
			data.State = "Teaching"
			data.IsMoving = false
			npcModel:SetAttribute("TargetPosition", nil)
			ShowSpeechBubble(npcModel, "Indoor theory class today.", 4)
		end
		if os.time() - data.LastActionTime > 25 then
			local typeData = Config.GetTypeData(data.Type)
			local income = math.floor((typeData.BaseIncome * 0.5) * eff * GetIncomeMult(data))
			AddIncome(data.OwnerId, income, "SkiLessonTheory", Enum.AnalyticsEconomyTransactionType.Gameplay)
			data.TotalEarnings = data.TotalEarnings + income
			data.LastActionTime = os.time()
		end
		UpdateNameTag(npcModel, "Teaching", data.Level)
		return
	end

	local instructorSlopeFilter = function(slope)
		local diff = slope:GetAttribute("Difficulty") or "Green"
		return Config.CanInstructorTeachDifficulty(diff)
	end

	if not data.PatrolSlope or not data.PatrolSlope.Parent then
		data.PatrolSlope = FindNearestSlope(npcModel.PrimaryPart.Position, data.OwnerId, instructorSlopeFilter)
		data.NextSlopeRotateAt = os.time() + math.max(45, 90 - data.Level * 2)
		if data.PatrolSlope then
			local diff = data.PatrolSlope:GetAttribute("Difficulty") or "Green"
			ShowSpeechBubble(npcModel, "Teaching on " .. diff .. " slope.", 3)
		end
	elseif os.time() >= (data.NextSlopeRotateAt or 0) then
		local nextSlope = FindDifferentSlope(npcModel.PrimaryPart.Position, data.OwnerId, data.PatrolSlope, instructorSlopeFilter)
		data.NextSlopeRotateAt = os.time() + math.max(45, 90 - data.Level * 2)
		if nextSlope and nextSlope ~= data.PatrolSlope then
			ClearInstructorStudentAssignment(npcModel, data)
			data.PatrolSlope = nextSlope
			local diff = data.PatrolSlope:GetAttribute("Difficulty") or "Green"
			ShowSpeechBubble(npcModel, "Moving lessons to " .. diff .. ".", 3)
		end
	end

	if not data.PatrolSlope or not data.PatrolSlope.Parent then
		ClearInstructorStudentAssignment(npcModel, data)
		DoWander(npcModel, data)
		return
	end

	UpdateSlopeRoleCoverage(data, data.PatrolSlope)
	local lessonQuality = math.max(1, math.min(10, math.floor((data.Level + math.max(0, eff - 1)) * roleStats.QualityMult)))
	npcModel:SetAttribute("InstructorLevel", data.Level)
	npcModel:SetAttribute("LessonQuality", lessonQuality)
	npcModel:SetAttribute("LessonDurationScale", roleStats.LessonDurationMult)

	local lessonSpot = GetInstructorLessonSpot(data)
	if not lessonSpot then
		ClearInstructorStudentAssignment(npcModel, data)
		DoWander(npcModel, data)
		return
	end
	npcModel:SetAttribute("LessonSpotX", lessonSpot.X)
	npcModel:SetAttribute("LessonSpotY", lessonSpot.Y)
	npcModel:SetAttribute("LessonSpotZ", lessonSpot.Z)

	local assignedGuest = data.AssignedGuestModel
	if (not assignedGuest or not assignedGuest.Parent) and data.AssignedGuestUUID then
		assignedGuest = ResolveGuestModelByUUID(data.AssignedGuestUUID)
		data.AssignedGuestModel = assignedGuest
	end
	if assignedGuest and assignedGuest.Parent and tostring(assignedGuest:GetAttribute("AssignedInstructorUUID") or "") ~= tostring(data.UUID or "") then
		assignedGuest = nil
		ClearInstructorStudentAssignment(npcModel, data)
	end

	local distToSpot = (npcModel.PrimaryPart.Position - lessonSpot).Magnitude
	local hDist = (Vector3.new(npcModel.PrimaryPart.Position.X, 0, npcModel.PrimaryPart.Position.Z) - Vector3.new(lessonSpot.X, 0, lessonSpot.Z)).Magnitude
	if distToSpot > 6 and hDist > 5 and MoveToTarget(npcModel, data, lessonSpot) then
		data.State = assignedGuest and "SettingUp" or "Moving"
		UpdateNameTag(npcModel, data.State, data.Level)
		return
	end

	data.IsMoving = false
	npcModel:SetAttribute("TargetPosition", nil)
	FaceTarget(npcModel, lessonSpot + npcModel.PrimaryPart.CFrame.LookVector)

	if (not assignedGuest or not assignedGuest.Parent) and ((data.NextStudentSearchAt or 0) <= os.time()) then
		data.NextStudentSearchAt = os.time() + 1
		local candidate = FindInstructorLessonCandidate(data, lessonSpot)
		if candidate and AssignInstructorStudent(npcModel, data, candidate, lessonSpot) then
			assignedGuest = candidate
			ShowSpeechBubble(npcModel, "Lesson spot is right here.", 3)
		end
	end

	if not assignedGuest or not assignedGuest.Parent then
		data.State = "WaitingStudent"
		UpdateNameTag(npcModel, data.State, data.Level)
		return
	end

	local guestRoot = assignedGuest.PrimaryPart or assignedGuest:FindFirstChild("HumanoidRootPart")
	local guestState = tostring(assignedGuest:GetAttribute("State") or "")
	if not guestRoot or INSTRUCTOR_BLOCKED_GUEST_STATES[guestState] then
		ClearInstructorStudentAssignment(npcModel, data)
		data.State = "WaitingStudent"
		UpdateNameTag(npcModel, data.State, data.Level)
		return
	end

	local distGuestToSpot = (guestRoot.Position - lessonSpot).Magnitude
	local distGuestToInstructor = (guestRoot.Position - npcModel.PrimaryPart.Position).Magnitude
	local assignedTooLong = data.AssignedGuestAt and (os.time() - data.AssignedGuestAt) > 150
	if assignedTooLong and guestState ~= "TakingLesson" then
		ClearInstructorStudentAssignment(npcModel, data)
		data.State = "WaitingStudent"
		UpdateNameTag(npcModel, data.State, data.Level)
		return
	end

	if guestState == "TakingLesson" and distGuestToSpot <= 10 and distGuestToInstructor <= 14 then
		data.State = "Teaching"
		FaceTarget(npcModel, guestRoot.Position)
		if os.time() - data.LastActionTime > math.max(8, roleStats.ActionInterval) then
			local typeData = Config.GetTypeData(data.Type)
			local income = math.floor((typeData.LessonIncome or 15) * eff * GetIncomeMult(data))
			AddIncome(data.OwnerId, income, "SkiLessonPractical", Enum.AnalyticsEconomyTransactionType.Gameplay)
			data.TotalEarnings = data.TotalEarnings + income
			data.LastActionTime = os.time()
			data.TasksCompleted = data.TasksCompleted + 1
		end
	else
		data.State = "WaitingStudent"
		if os.time() - (data.LastLessonPromptAt or 0) > 12 then
			data.LastLessonPromptAt = os.time()
			ShowSpeechBubble(npcModel, "Over here for your lesson.", 3)
		end
	end

	UpdateNameTag(npcModel, data.State, data.Level)
end

function CheckForBreak(npcModel, data)
	if data.Paused or data.State == "Break" then return data.State == "Break" end
	if os.time() >= data.NextBreakCheck then
		local breakChance = Config.GetBreakChance(data.Level)
		if math.random() < breakChance then
			local minBreak, maxBreak = Config.GetBreakDuration(data.Level)
			data.State = "Break"
			data.BreakEndTime = os.time() + math.random(minBreak, maxBreak)
			local line = Config.GetSpeechLine(data.Type, "Break")
			if line then ShowSpeechBubble(npcModel, line, 3) end
			npcModel:SetAttribute("TargetPosition", nil)
			return true
		end
		local roleStats = GetRoleWorkStats(data)
		local minNextBreak = math.max(45, math.floor(60 - (roleStats.Progress * 12)))
		local maxNextBreak = math.max(minNextBreak + 10, math.floor(120 - (roleStats.Progress * 24)))
		data.NextBreakCheck = os.time() + math.random(minNextBreak, maxNextBreak)
	end
	return false
end

function UpdateBreak(npcModel, data)
	if os.time() >= data.BreakEndTime then
		data.State = "Idle"; data.IsMoving = false
		ShowSpeechBubble(npcModel, "Back to work.", 2)
		return false
	end
	return true
end

function UpdateEmployee(npcModel, data)
	if not npcModel or not npcModel.Parent then return end
	if data.Paused then UpdateNameTag(npcModel, "Paused", data.Level); return end

	if data.State == "Break" then
		if UpdateBreak(npcModel, data) then UpdateNameTag(npcModel, "Break", data.Level); return end
	elseif CheckForBreak(npcModel, data) then return end

	if data.Type == "LiftOperator" then UpdateLiftOperator(npcModel, data)
	elseif data.Type == "Chef" then UpdateStationaryWorker(npcModel, data, "HasChef")
	elseif data.Type == "RentalTech" then UpdateStationaryWorker(npcModel, data, "HasTech")
	elseif data.Type == "Janitor" then UpdateJanitor(npcModel, data)
	elseif data.Type == "Snowmaker" then UpdateSnowmaker(npcModel, data)
	elseif data.Type == "SkiPatrol" then UpdateSkiPatrol(npcModel, data)
	elseif data.Type == "Groomer" then UpdateGroomer(npcModel, data)
	elseif data.Type == "Instructor" then UpdateInstructor(npcModel, data)
	elseif data.Type == "Mechanic" then UpdateMechanic(npcModel, data)
	end
end

-- Forward-declare SaveEmployees so the main loop can reference it
local SaveEmployees
local scheduleCoalescedEmployeeForceSave

task.spawn(function()
	while true do
		task.wait(1)
		for model, data in pairs(ActiveEmployees) do
			local rootPart = model and model.Parent and GetEmployeeRootPart(model)
			if rootPart then
				data.LastKnownPosition = rootPart.Position
				data.RootMissingSince = nil
				data.RespawnCount = 0 -- Reset after a healthy recovery so temporary root loss never snowballs into permanent removal.

				-- Old stuck detection removed here to prevent conflict with MoveToTarget teleports
				local hasJob = true
				local typeData = Config.GetTypeData(data.Type)
				local joblessQuitAfter = tonumber(Settings.JoblessQuitAfter) or 0

				if typeData and typeData.RequiresAssignment then
					if not data.AssignmentModel or not data.AssignmentModel.Parent then 
						hasJob = false 
					end
				elseif data.Type == "SkiPatrol" or data.Type == "Groomer" or data.Type == "Instructor" then
					if not data.PatrolSlope or not data.PatrolSlope.Parent then
						if data.Type == "Groomer" and (data.State == "WaitingForNight" or data.State == "WaitingForSnowcat" or data.State == "Driving" or data.State == "Idle") then
							-- Groomer is waiting, not considered jobless
						elseif data.Type == "Instructor" and (data.State == "WaitingStudent" or data.State == "Teaching") then
							-- Instructor without slope but teaching/waiting is still fine (e.g. blizzard indoor)
						else
							hasJob = false 
						end
					end
				elseif data.Type == "Mechanic" then
					local placedObjects = workspace:FindFirstChild("PlacedObjects")
					local hasLifts = false
					if placedObjects then
						for _, obj in ipairs(placedObjects:GetChildren()) do
							if obj:GetAttribute("Type") == "TwoPoint" then hasLifts = true; break end
						end
					end
					if not hasLifts then hasJob = false end
				end

				if not hasJob then
					local restoreGraceUntil = tonumber(data.RestoreGraceUntil) or 0
					if restoreGraceUntil > os.time() then
						data.JoblessTime = 0
						local ok2, err2 = pcall(UpdateEmployee, model, data)
						if not ok2 then warn("[EmployeeServer] UpdateEmployee ERROR (grace): " .. tostring(err2)) end
						continue
					end
					data.JoblessTime = (data.JoblessTime or 0) + 1
					if joblessQuitAfter > 0 and data.JoblessTime > joblessQuitAfter then
						ShowSpeechBubble(model, "No work here. I quit.", 4)
						task.delay(3, function()
							if model and model.Parent then model:Destroy() end
						end)
						UnassignBuildingFromEmployee(data)
						ActiveEmployees[model] = nil
						pcall(RecalculateEffects)
						SaveEmployees(true)
						continue
					end
				else
					data.JoblessTime = 0
				end

				local ok2, err2 = pcall(UpdateEmployee, model, data)
				if not ok2 then warn("[EmployeeServer] UpdateEmployee ERROR (" .. tostring(data.Type) .. " " .. tostring(data.UUID) .. "): " .. tostring(err2)) end
			else
				local now = os.time()
				data.RootMissingSince = data.RootMissingSince or now
				data.RespawnCount = (data.RespawnCount or 0)
				if model and model.Parent and (now - data.RootMissingSince) < 18 then
					continue
				end
				-- Throttle respawn churn, but never permanently delete staff just because restore/streaming dropped their root a few times.
				if data.RespawnCount >= 6 then
					warn(string.format("[EmployeeServer] %s employee %s exceeded respawn retry threshold, resetting counter and trying again.", tostring(data.Type), tostring(data.UUID)))
					data.RespawnCount = 0
				end
				data.RespawnCount = data.RespawnCount + 1

				local fallbackPos = data.LastKnownPosition or Vector3.new(0, 50, 0)
				local shouldRespawn = fallbackPos ~= nil
				UnassignBuildingFromEmployee(data)
				ActiveEmployees[model] = nil
				pcall(RecalculateEffects)

				if shouldRespawn then
					warn(string.format("[EmployeeServer] Respawning %s employee %s after root loss.", tostring(data.Type), tostring(data.UUID)))
					SpawnEmployee(data.Type, GetSafeGroundPosition(fallbackPos), data.OwnerId, data)
				end
				if model and model.Parent then
					model:Destroy()
				end
				scheduleCoalescedEmployeeForceSave()
			end
		end
	end
end)

function SerializeEmployees()
	local saveData = {}
	for model, data in pairs(ActiveEmployees) do
		if model and model.Parent then
			local rootPart = GetEmployeeRootPart(model)
			table.insert(saveData, {
				UUID = data.UUID, Type = data.Type, Level = data.Level,
				Assignment = data.Assignment, AssignmentUUID = data.AssignmentUUID, TasksCompleted = data.TasksCompleted,
				TotalEarnings = data.TotalEarnings, HireTime = data.HireTime,
				OwnerId = data.OwnerId,
				Position = rootPart and {X = rootPart.Position.X, Y = rootPart.Position.Y, Z = rootPart.Position.Z} or nil,
			})
		end
	end
	return saveData
end

function BuildEmployeeSavePayload(saveData)
	local payload = {
		employees = saveData,
	}
	local createdTime = GetSessionCreatedTime()
	if createdTime > 0 then
		payload.CreatedTime = createdTime
	end
	return payload
end

function GetPersistEmployeeKeys(primaryKey)
	local keys = {}
	local seen = {}
	local function push(key)
		if type(key) ~= "string" or key == "" or seen[key] then
			return
		end
		seen[key] = true
		table.insert(keys, key)
	end

	push(ACTIVE_EMPLOYEE_KEY)
	push(primaryKey)
	return keys
end

SaveEmployees = function(force)
	if not HAS_LOADED then return false end
	if not force and (os.time() - LAST_SAVE_TIME < 10) then return false end

	if IS_SAVING then
		local startWait = os.clock()
		while IS_SAVING and (os.clock() - startWait < 15) do
			task.wait(0.2)
		end
		if IS_SAVING then return false end
	end
	
	IS_SAVING = true
	local primaryKey = GetSlotKey()
	if (not primaryKey or primaryKey == "") and force then
		primaryKey = WaitForResolvedSlotKey(8)
	end
	local persistKeys = GetPersistEmployeeKeys(primaryKey)
	if #persistKeys == 0 then
		warn("[EmployeeServer] Skipping employee save because slot identity is unresolved.")
		return false
	end

	IS_SAVING = true
	local saveData = SerializeEmployees()
	local payload = BuildEmployeeSavePayload(saveData)
	local sessionCreatedTime = GetSessionCreatedTime()
	if sessionCreatedTime <= 0 then
		sessionCreatedTime = WaitForResolvedCreatedTime(force and 35 or 15)
		if sessionCreatedTime > 0 and (payload.CreatedTime or 0) <= 0 then
			payload.CreatedTime = sessionCreatedTime
		end
	end
	if #saveData == 0 and not HAS_SPAWNED_EMPLOYEE_THIS_SESSION and sessionCreatedTime <= 0 then
		IS_SAVING = false
		warn("[EmployeeServer] Skipping empty employee save because no employees have spawned and CreatedTime is unresolved.")
		return false
	end
	local savedAny = false

	for _, key in ipairs(persistKeys) do
		local success = false
		local lastErr = nil
		for attempt = 1, 5 do
			success, lastErr = pcall(function()
				EmployeeStore:UpdateAsync(key, function()
					return payload
				end)
			end)
			if success then
				break
			end
			task.wait(0.8 * attempt)
		end

		if success then
			savedAny = true
			SaveEmployeeBackup(key, payload)
		else
			warn(string.format("[EmployeeServer] Failed to save employees for %s: %s", key, tostring(lastErr)))
		end
	end

	IS_SAVING = false
	if savedAny then
		LAST_SAVE_TIME = os.time()
		print(string.format("[EmployeeServer] Saved %d employees to %s (CreatedTime=%s)", #saveData, table.concat(persistKeys, ", "), tostring(payload.CreatedTime or 0)))
	end
	return savedAny
end

local coalescedEmployeeForceSaveGen = 0
scheduleCoalescedEmployeeForceSave = function()
	coalescedEmployeeForceSaveGen += 1
	local gen = coalescedEmployeeForceSaveGen
	task.delay(8, function()
		if coalescedEmployeeForceSaveGen ~= gen then
			return
		end
		pcall(function()
			SaveEmployees(true)
		end)
	end)
end

EmployeeSaveBindable.OnInvoke = function(force)
	return SaveEmployees(force == true)
end

local BuildingRestoreReady = Events:FindFirstChild("BuildingRestoreReady")
local buildingRestoreObserved = (_G.BuildingStoreRestoreReady == true)

function HasPlacedObjectWithUUID(uuid, ownerId)
	if type(uuid) ~= "string" or uuid == "" then
		return false
	end
	local placedObjects = workspace:FindFirstChild("PlacedObjects")
	if not placedObjects then
		return false
	end
	for _, obj in ipairs(placedObjects:GetChildren()) do
		if obj:IsA("Model") and obj:GetAttribute("UUID") == uuid and IsOwnerCompatibleObject(obj, ownerId) then
			return true
		end
	end
	return false
end

function CountPlacedSlopesForOwner(ownerId)
	local placedObjects = workspace:FindFirstChild("PlacedObjects")
	if not placedObjects then
		return 0
	end
	local count = 0
	for _, obj in ipairs(placedObjects:GetChildren()) do
		if obj:IsA("Model")
			and (obj:GetAttribute("Type") == "Slope" or obj:GetAttribute("RawPoints") ~= nil)
			and IsOwnerCompatibleObject(obj, ownerId)
		then
			count += 1
		end
	end
	return count
end

function WaitForEmployeeRestorePrereqs(saveData, ownerId, timeoutSeconds)
	if type(saveData) ~= "table" or #saveData == 0 then
		return
	end

	local pendingAssignments = {}
	local needsSlopeRestore = false
	for _, empData in ipairs(saveData) do
		local typeData = Config.GetTypeData(empData.Type)
		if typeData and typeData.RequiresAssignment and type(empData.AssignmentUUID) == "string" and empData.AssignmentUUID ~= "" then
			pendingAssignments[empData.AssignmentUUID] = true
		end
		if empData.Type == "SkiPatrol" or empData.Type == "Groomer" or empData.Type == "Instructor" then
			needsSlopeRestore = true
		end
	end

	if not next(pendingAssignments) and not needsSlopeRestore then
		return
	end

	local deadline = os.clock() + (timeoutSeconds or 18)
	while os.clock() < deadline do
		local assignmentsReady = true
		for uuid in pairs(pendingAssignments) do
			if not HasPlacedObjectWithUUID(uuid, ownerId) then
				assignmentsReady = false
				break
			end
		end

		local slopesReady = true
		if needsSlopeRestore then
			slopesReady = CountPlacedSlopesForOwner(ownerId) > 0 or buildingRestoreObserved
		end

		if assignmentsReady and slopesReady then
			return
		end
		task.wait(0.5)
	end

	local assignmentsReady = true
	for uuid in pairs(pendingAssignments) do
		if not HasPlacedObjectWithUUID(uuid, ownerId) then
			assignmentsReady = false
			break
		end
	end
	local slopesReady = (not needsSlopeRestore) or CountPlacedSlopesForOwner(ownerId) > 0 or buildingRestoreObserved
	warn(string.format("[EmployeeServer] Proceeding with employee load after restore wait timeout. assignmentsReady=%s slopesReady=%s owner=%s", tostring(assignmentsReady), tostring(slopesReady), tostring(ownerId)))
end

function LoadEmployees()
	if HAS_LOADED or LOAD_ATTEMPTED then return end
	LOAD_ATTEMPTED = true
	task.wait(2)

	local primaryKey = WaitForResolvedSlotKey(15)
	local ownerId = GetOwnerUserId()
	local expectedCreatedTime = GetSessionCreatedTime()
	local freshSaveSession = SlotData and SlotData:GetAttribute("FreshSave") == true
	local forcePrimaryKeyOnly = false
	if expectedCreatedTime <= 0 then
		expectedCreatedTime = WaitForResolvedCreatedTime(12)
	end
	if not primaryKey or ownerId <= 0 then
		warn("[EmployeeServer] Employee load waiting for resolved slot identity.")
		LOAD_ATTEMPTED = false
		task.delay(5, LoadEmployees)
		return
	end
	if expectedCreatedTime <= 0 then
		if freshSaveSession then
			warn("[EmployeeServer] Employee load waiting for resolved slot CreatedTime on a fresh save.")
			LOAD_ATTEMPTED = false
			task.delay(5, LoadEmployees)
			return
		end
		forcePrimaryKeyOnly = true
		warn("[EmployeeServer] CreatedTime unresolved during employee load. Falling back to the current slot employee key only.")
	end

	local loadKeys = forcePrimaryKeyOnly and { primaryKey } or GetEmployeeLoadKeys()
	if #loadKeys == 0 then
		table.insert(loadKeys, primaryKey)
	end

	local saveData = nil
	local loadedKey = nil
	local loadedCreatedTime = 0
	local hadLookupError = false
	local rejectedStaleData = false
	for _, key in ipairs(loadKeys) do
		local success = false
		local result = nil
		local lastErr = nil
		for attempt = 1, 3 do
			success, result = pcall(function()
				return EmployeeStore:GetAsync(key)
			end)
			if success then
				break
			end
			lastErr = result
			task.wait(1.5 * attempt)
		end

		if success then
			local normalized, savedCreatedTime = ExtractEmployeePayload(result)
			if type(normalized) == "table" then
				if expectedCreatedTime > 0 and savedCreatedTime > 0 and savedCreatedTime ~= expectedCreatedTime then
					rejectedStaleData = true
					warn(string.format("[EmployeeServer] CreatedTime mismatch for %s (Store=%s, Expected=%s). Ignoring stale employee data.", key, tostring(savedCreatedTime), tostring(expectedCreatedTime)))
				elseif #normalized > 0 then
					saveData = normalized
					loadedKey = key
					loadedCreatedTime = savedCreatedTime
					break
				elseif saveData == nil then
					saveData = normalized
					loadedKey = key
					loadedCreatedTime = savedCreatedTime
				end
			elseif result ~= nil then
				warn(string.format("[EmployeeServer] Ignoring invalid employee payload for %s", key))
			end
		else
			hadLookupError = true
			warn(string.format("[EmployeeServer] Failed to load employees for %s: %s", key, tostring(lastErr)))
		end
	end

	if type(saveData) ~= "table" or #saveData == 0 then
		local backupData, backupKey, backupCreatedTime = LoadBestEmployeeBackup(loadKeys, expectedCreatedTime)
		if type(backupData) == "table" and #backupData > 0 then
			if expectedCreatedTime > 0 and backupCreatedTime > 0 and backupCreatedTime ~= expectedCreatedTime then
				rejectedStaleData = true
				warn(string.format("[EmployeeServer] Backup CreatedTime mismatch for %s (Backup=%s, Expected=%s). Ignoring stale employee backup.", tostring(backupKey), tostring(backupCreatedTime), tostring(expectedCreatedTime)))
			else
				saveData = backupData
				loadedKey = backupKey or loadedKey
				loadedCreatedTime = backupCreatedTime
				warn(string.format("[EmployeeServer] Restored %d employees from backup for %s (CreatedTime=%s)", #backupData, tostring(loadedKey), tostring(backupCreatedTime)))
			end
		end
	end

	if hadLookupError and saveData == nil then
		warn("[EmployeeServer] Blocking employee load because datastore reads failed and no safe snapshot was loaded.")
		LOAD_ATTEMPTED = false
		task.delay(5, LoadEmployees)
		return
	end

	ACTIVE_EMPLOYEE_KEY = loadedKey or primaryKey

	WaitForEmployeeRestorePrereqs(saveData, ownerId, 18)

	HAS_LOADED = true
	if not saveData or #saveData == 0 then
		print(string.format("[EmployeeServer] No saved employees found for %s (checked keys: %s, ExpectedCreatedTime=%s)", tostring(ACTIVE_EMPLOYEE_KEY or primaryKey), table.concat(loadKeys, ", "), tostring(expectedCreatedTime)))
		if rejectedStaleData and not freshSaveSession and STALE_LOAD_RETRY_COUNT < MAX_STALE_LOAD_RETRIES then
			STALE_LOAD_RETRY_COUNT += 1
			warn(string.format("[EmployeeServer] Retrying employee load after stale-data rejection (attempt %d/%d).", STALE_LOAD_RETRY_COUNT, MAX_STALE_LOAD_RETRIES))
			HAS_LOADED = false
			LOAD_ATTEMPTED = false
			task.delay(4 + (STALE_LOAD_RETRY_COUNT * 2), LoadEmployees)
			return
		end
		if rejectedStaleData then
			task.delay(2, function()
				if HAS_LOADED then
					SaveEmployees(true)
				end
			end)
		end
		return
	end

	STALE_LOAD_RETRY_COUNT = 0
	local existingUUIDs = {}
	for _, data in pairs(ActiveEmployees) do
		if data.UUID then existingUUIDs[data.UUID] = true end
	end

	local loaded = 0
	for i, empData in ipairs(saveData) do
		if empData.UUID and existingUUIDs[empData.UUID] then
			continue
		end
		if not Config.GetTypeData(empData.Type) then
			continue
		end
		local spawnPos = Vector3.new(0, 50, 0)
		if empData.Position then
			spawnPos = Vector3.new(empData.Position.X or 0, empData.Position.Y or 50, empData.Position.Z or 0)
		end
		empData.OwnerId = ownerId
		SpawnEmployee(empData.Type, spawnPos, ownerId, empData)
		if empData.UUID then existingUUIDs[empData.UUID] = true end
		loaded = loaded + 1
		if i % 5 == 0 then task.wait() end
	end
	print(string.format("[EmployeeServer] Loaded %d employees from %s (StoreCreatedTime=%s ExpectedCreatedTime=%s)", loaded, tostring(ACTIVE_EMPLOYEE_KEY or primaryKey), tostring(loadedCreatedTime), tostring(expectedCreatedTime)))
	if (loadedKey and primaryKey and loadedKey ~= primaryKey) or (expectedCreatedTime > 0 and loadedCreatedTime == 0) then
		task.delay(2, function()
			if HAS_LOADED then
				SaveEmployees(true)
			end
		end)
	end
	task.delay(1, BroadcastEmployeeUpdate)
end

local TerrainReady = Events:FindFirstChild("TerrainReady")

if BuildingRestoreReady and BuildingRestoreReady:IsA("BindableEvent") then
	BuildingRestoreReady.Event:Connect(function()
		buildingRestoreObserved = true
		task.delay(1, LoadEmployees)
	end)
	if _G.BuildingStoreRestoreReady == true then
		buildingRestoreObserved = true
		task.delay(0.5, LoadEmployees)
	end
end

if TerrainReady and TerrainReady:IsA("BindableEvent") then
	TerrainReady.Event:Connect(function()
		task.delay(3, LoadEmployees)
	end)
	if _G.TerrainReady == true then
		task.delay(2, LoadEmployees)
	end
end

-- Always schedule a fallback load attempt in case restore events fired before this script connected.
task.delay((((BuildingRestoreReady and BuildingRestoreReady:IsA("BindableEvent")) or (TerrainReady and TerrainReady:IsA("BindableEvent"))) and 12 or 8), LoadEmployees)

task.spawn(function()
	task.wait(30)
	while true do task.wait(90); if HAS_LOADED then SaveEmployees(false) end end
end)

Systems.ShouldPersistEmployeesForPlayer = function(player)
	if not player then
		return true
	end
	local ownerId = UserIdVal and tonumber(UserIdVal.Value) or nil
	if not ownerId or ownerId <= 0 then
		return true
	end
	return player.UserId == ownerId
end

Systems.ShouldSkipStandaloneEmployeeSave = function()
	if _G.CoordinatedSaveInProgress == true then
		return true
	end
	local lastCoordinatedSaveAt = tonumber(_G.LastCoordinatedSaveAt)
	return lastCoordinatedSaveAt ~= nil and (os.clock() - lastCoordinatedSaveAt) < 8
end

Players.PlayerRemoving:Connect(function(player)
	if Systems.ShouldSkipStandaloneEmployeeSave() then
		return
	end
	if Systems.ShouldPersistEmployeesForPlayer(player) then
		SaveEmployees(true)
	end
end)
game:BindToClose(function()
	if Systems.ShouldSkipStandaloneEmployeeSave() then
		return
	end
	SaveEmployees(true)
	task.wait(3)
end)

Systems.TryHireEmployee = function(player, employeeType, shouldRateLimit)
	if typeof(employeeType) ~= "string" then
		warn("[EmployeeServer] Hire rejected: InvalidType (not a string)")
		return false, "InvalidType"
	end

	local typeData = Config.GetTypeData(employeeType)
	if not typeData then
		warn("[EmployeeServer] Hire rejected: InvalidType " .. employeeType)
		return false, "InvalidType"
	end

	local ownerId = GetOwnerUserId()
	if not player or player.UserId ~= ownerId then
		warn("[EmployeeServer] Hire rejected: NotOwner")
		return false, "NotOwner"
	end

	if shouldRateLimit and IsRateLimited(HireRequestTimes, player.UserId, HIRE_REQUEST_COOLDOWN) then
		return false, "TooFast"
	end

	if CountEmployeesByType(ownerId, employeeType) >= GetMaxPerType(ownerId) then
		warn("[EmployeeServer] Hire rejected: TypeFull for " .. employeeType)
		return false, "TypeFull"
	end

	if CountTotalEmployees(ownerId) >= GetMaxTotal(ownerId) then
		warn("[EmployeeServer] Hire rejected: TotalFull")
		return false, "TotalFull"
	end

	local spawnPos = Vector3.new(0, 50, 0)
	if player.Character and player.Character.PrimaryPart then
		spawnPos = player.Character.PrimaryPart.Position + Vector3.new(math.random(-5, 5), 0, math.random(-5, 5))
	end

	if typeData.RequiresAssignment and not FindBuildingForEmployee(employeeType, spawnPos, ownerId) then
		warn("[EmployeeServer] Hire rejected: NoAssignment for " .. employeeType)
		return false, "NoAssignment"
	end

	local count = CountEmployeesByType(ownerId, employeeType)
	local cost = Config.GetHireCost(typeData.BaseCost, count)

	if not TrySpendMoney(cost, "Hire_" .. employeeType, Enum.AnalyticsEconomyTransactionType.Shop) then
		warn("[EmployeeServer] Hire rejected: NoFunds for " .. employeeType .. " (cost=" .. cost .. ")")
		return false, "NoFunds"
	end

	local model = SpawnEmployee(employeeType, spawnPos, ownerId)
	if not model then
		warn("[EmployeeServer] Hire rejected: SpawnFailed for " .. employeeType)
		return false, "SpawnFailed"
	end

	print("[EmployeeServer] Hired " .. employeeType .. " successfully")
	SaveEmployees(true)
	return true, "Success"
end

HireEvent.OnServerEvent:Connect(function(player, employeeType)
	local ok, success, reason = pcall(Systems.TryHireEmployee, player, employeeType, true)
	if not ok then
		warn("[EmployeeServer] TryHireEmployee ERROR: " .. tostring(success))
		SendHireResult(player, employeeType, false, "SpawnFailed")
		return
	end
	SendHireResult(player, employeeType, success, reason)
end)

LegacyHireFunction.OnServerInvoke = function(player, employeeType)
	local ok, success, reason = pcall(Systems.TryHireEmployee, player, employeeType, false)
	if not ok then
		warn("[EmployeeServer] TryHireEmployee ERROR (legacy): " .. tostring(success))
		return "SpawnFailed"
	end
	return success and "Success" or reason
end

LegacyUpgradeFunction.OnServerInvoke = function(player, employeeType)
	if typeof(employeeType) ~= "string" then
		return "InvalidType"
	end

	local ownerId = GetOwnerUserId()
	if player.UserId ~= ownerId then
		return "NotOwner"
	end

	local targetModel = nil
	local targetData = nil
	for model, data in pairs(ActiveEmployees) do
		if model and model.Parent and data.OwnerId == ownerId and data.Type == employeeType then
			if not targetData or data.Level < targetData.Level then
				targetModel = model
				targetData = data
			end
		end
	end

	if not targetData then
		return "NotOwned"
	end
	if targetData.Level >= Settings.MaxLevel then
		return "MaxLevel"
	end

	local cost = Config.GetUpgradeCost(targetData.Level)
	if not TrySpendMoney(cost, "Upgrade_" .. targetData.Type, Enum.AnalyticsEconomyTransactionType.Shop) then
		return "NoFunds"
	end

	targetData.Level = targetData.Level + 1
	local typeData = Config.GetTypeData(targetData.Type)
	targetData.WalkSpeed = Config.GetStatAtLevel(typeData.BaseWalkSpeed, typeData.UpgradeStats.WalkSpeed or 0, targetData.Level)
	targetData.Efficiency = Config.GetStatAtLevel(typeData.BaseEfficiency, typeData.UpgradeStats.Efficiency or 0, targetData.Level)

	local hum = targetModel and targetModel:FindFirstChild("Humanoid")
	if hum then
		hum.WalkSpeed = targetData.WalkSpeed
	end
	if targetData.AssignmentModel and targetData.AssignmentModel.Parent then
		targetData.AssignmentModel:SetAttribute("StaffEfficiency", targetData.Efficiency)
		targetData.AssignmentModel:SetAttribute("StaffLevel", targetData.Level)
	end

	pcall(RecalculateEffects)
	if targetModel and targetModel.Parent then
		ShowSpeechBubble(targetModel, "Level " .. targetData.Level .. " reached.", 4)
		UpdateNameTag(targetModel, targetData.State, targetData.Level)
	end
	SaveEmployees(true)
	task.defer(BroadcastEmployeeUpdate)
	return "Success"
end

ManageEvent.OnServerEvent:Connect(function(player, action, targetRef)
	if typeof(action) ~= "string" then
		return
	end

	if IsRateLimited(ManageRequestTimes, player.UserId, MANAGE_REQUEST_COOLDOWN) then
		return
	end

	local targetModel, data = ResolveManagedEmployeeTarget(targetRef)
	if not data or not targetModel then return end
	local ownerId = GetOwnerUserId()
	local canManage = player.UserId == ownerId or player.UserId == data.OwnerId

	if action == "Fire" and canManage then
		UnassignBuildingFromEmployee(data)
		targetModel:Destroy()
		ActiveEmployees[targetModel] = nil
		pcall(RecalculateEffects)
		SaveEmployees(true)
	elseif action == "Teleport" and canManage then
		if targetModel and targetModel.Parent then
			local root = GetEmployeeRootPart(targetModel)
			local character = player.Character
			local playerRoot = character and (character.PrimaryPart or character:FindFirstChild("HumanoidRootPart"))
			if root and character and playerRoot then
				local arrival = GetSafeGroundPosition(root.Position + Vector3.new(5, 0, 0))
				local humanoid = character:FindFirstChildOfClass("Humanoid")
				if humanoid then
					humanoid.Sit = false
					humanoid:ChangeState(Enum.HumanoidStateType.GettingUp)
				end
				playerRoot.AssemblyLinearVelocity = Vector3.zero
				playerRoot.AssemblyAngularVelocity = Vector3.zero
				character:PivotTo(CFrame.new(arrival))
				ShowSpeechBubble(targetModel, "Hi boss.", 2)
			end
		end
	elseif action == "Upgrade" and canManage then
		if data.Level >= Settings.MaxLevel then return end
		local cost = Config.GetUpgradeCost(data.Level)

		if not TrySpendMoney(cost, "Upgrade_"..data.Type, Enum.AnalyticsEconomyTransactionType.Shop) then return end

		data.Level = data.Level + 1
		local typeData = Config.GetTypeData(data.Type)
		data.WalkSpeed = Config.GetStatAtLevel(typeData.BaseWalkSpeed, typeData.UpgradeStats.WalkSpeed or 0, data.Level)
		data.Efficiency = Config.GetStatAtLevel(typeData.BaseEfficiency, typeData.UpgradeStats.Efficiency or 0, data.Level)
		local hum = targetModel:FindFirstChild("Humanoid")
		if hum then hum.WalkSpeed = data.WalkSpeed end
		if data.AssignmentModel and data.AssignmentModel.Parent then
			data.AssignmentModel:SetAttribute("StaffEfficiency", data.Efficiency)
			data.AssignmentModel:SetAttribute("StaffLevel", data.Level)
		end
		pcall(RecalculateEffects)
		ShowSpeechBubble(targetModel, "Level " .. data.Level .. " reached.", 4)
		UpdateNameTag(targetModel, data.State, data.Level)
		SaveEmployees(true)
	end
	task.wait(0.2)
	BroadcastEmployeeUpdate()
end)

InspectEvent.OnServerInvoke = function(player, targetModel)
	local data = ActiveEmployees[targetModel]
	if not data then return nil end
	local typeData = Config.GetTypeData(data.Type)
	if not typeData then return nil end
	local gp = GetGamepassStatus(GetOwnerUserId())
	return {
		UUID = data.UUID, Type = data.Type, TypeName = typeData.Name,
		Emoji = typeData.Emoji, Level = data.Level, MaxLevel = Settings.MaxLevel,
		State = data.State, Assignment = data.Assignment,
		TasksCompleted = data.TasksCompleted, TotalEarnings = data.TotalEarnings,
		Wage = Config.GetWage(typeData.BaseWage, data.Level),
		UpgradeCost = data.Level < Settings.MaxLevel and Config.GetUpgradeCost(data.Level) or nil,
		HireTime = data.HireTime, TimeSinceHire = os.time() - data.HireTime,
		OwnerId = data.OwnerId, WagesPaid = data.WagesPaid,
		Weather = GetCurrentWeather(), Temperature = GetCurrentTemperature(),
		HasDoublePass = gp.double, HasUnlimitedPass = gp.unlimited,
	}
end

SyncEvent.OnServerEvent:Connect(function(player)
	SendEmployeeListToPlayer(player)
end)

Players.PlayerAdded:Connect(function(player)
	task.wait(3)
	SendEmployeeListToPlayer(player)
end)

task.spawn(function()
	task.wait(15)
	while true do
		task.wait(10)
		if HAS_LOADED then
			BroadcastEmployeeUpdate()
		end
	end
end)