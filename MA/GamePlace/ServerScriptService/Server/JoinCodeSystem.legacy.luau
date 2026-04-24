local MemoryStoreService = game:GetService("MemoryStoreService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TeleportService = game:GetService("TeleportService")

-- // CONFIGURATION //
local PinMap = MemoryStoreService:GetSortedMap("GameJoinCodes")
local UPDATE_RATE = 15
local EXPIRATION = 40

local MAIN_GAME_ID = 117869454878577
local TEST_GAME_ID = 9856266771

-- Automatically detect if we are in the Test Place
local TARGET_PLACE_ID = (game.PlaceId == TEST_GAME_ID) and TEST_GAME_ID or MAIN_GAME_ID

-- // SETUP REMOTES (Robust Creation) //
local Events = ReplicatedStorage:FindFirstChild("Events") or Instance.new("Folder", ReplicatedStorage)
Events.Name = "Events"

local CodeValue = Events:FindFirstChild("ServerAccessCode")
if not CodeValue then
	CodeValue = Instance.new("StringValue")
	CodeValue.Name = "ServerAccessCode"
	CodeValue.Parent = Events
end

local ResolvePinFunc = Events:FindFirstChild("ResolveJoinPin")
if not ResolvePinFunc then
	ResolvePinFunc = Instance.new("RemoteFunction")
	ResolvePinFunc.Name = "ResolveJoinPin"
	ResolvePinFunc.Parent = Events
end

-- // STATE //
local CurrentLongCode = nil
local CurrentPin = nil

local function buildStoredJoinCodeValue(targetPlaceId, targetId, playerNameCsv)
	return string.format("%d@%s|%s", tonumber(targetPlaceId) or MAIN_GAME_ID, tostring(targetId or ""), tostring(playerNameCsv or ""))
end

local function parseStoredJoinCodeValue(rawValue)
	local header = string.split(tostring(rawValue or ""), "|")[1] or ""
	local placeIdText, targetId = string.match(header, "^(%d+)@(.+)$")
	if placeIdText and targetId and targetId ~= "" then
		local parsedPlaceId = tonumber(placeIdText)
		if parsedPlaceId and parsedPlaceId > 0 then
			return parsedPlaceId, targetId
		end
	end
	if header ~= "" then
		return TARGET_PLACE_ID, header
	end
	return nil, nil
end

-- // HELPER: UPDATE PIN WITH PLAYERS //
local function updatePinListing()
	if CurrentPin and CurrentLongCode then
		-- Collect Player Names
		local names = {}
		for _, p in ipairs(Players:GetPlayers()) do
			table.insert(names, p.Name)
		end
		local nameString = table.concat(names, ",")

		local storedValue = buildStoredJoinCodeValue(TARGET_PLACE_ID, CurrentLongCode, nameString)

		pcall(function() 
			PinMap:SetAsync(CurrentPin, storedValue, EXPIRATION) 
		end)
	end
end

-- // HANDLER: TELEPORT REQUEST //
ResolvePinFunc.OnServerInvoke = function(player, pinInput)
	if not pinInput or string.len(pinInput) < 4 then return "INVALID_FMT" end

	local success, result = pcall(function() return PinMap:GetAsync(pinInput) end)
	if not success or not result then return "INVALID_PIN" end

	local placeId, targetId = parseStoredJoinCodeValue(result)
	if not placeId or not targetId then return "INVALID_PIN" end

	if targetId == game.JobId or targetId == game.PrivateServerId then return "ALREADY_HERE" end
	if RunService:IsStudio() then return "STUDIO_NO_TP" end

	local tpSuccess, tpErr = pcall(function()
		-- Check format to decide teleport type
		if string.match(targetId, "^[A-Z0-9]+%-[A-Z0-9]+") or string.len(targetId) > 40 then
			TeleportService:TeleportToPrivateServer(placeId, targetId, {player})
		else
			local tpOptions = Instance.new("TeleportOptions")
			tpOptions.ServerInstanceId = targetId
			TeleportService:TeleportAsync(placeId, {player}, tpOptions)
		end
	end)

	return tpSuccess and "TELEPORTING" or "TP_FAIL"
end

-- // CORE LOGIC //
local function onPlayerAdded(player)
	if not CurrentPin then
		if RunService:IsStudio() then
			CurrentPin = "99999"; CurrentLongCode = "STUDIO_CODE"; CodeValue.Value = CurrentPin
			return
		end

		if game.PrivateServerId ~= "" and game.PrivateServerOwnerId > 0 then
			CurrentLongCode = game.PrivateServerId
		elseif game.PrivateServerId ~= "" and game.PrivateServerOwnerId == 0 then
			local joinData = player:GetJoinData()
			if joinData.TeleportData and joinData.TeleportData.JoinCode then
				CurrentLongCode = joinData.TeleportData.JoinCode
			else
				CurrentLongCode = game.PrivateServerId
			end
		else
			CurrentLongCode = game.JobId
		end

		if CurrentLongCode and CurrentLongCode ~= "" then
			CurrentPin = tostring(math.random(10000, 99999))
			CodeValue.Value = CurrentPin
			updatePinListing()
		end
	end
end

Players.PlayerAdded:Connect(onPlayerAdded)
for _, p in ipairs(Players:GetPlayers()) do onPlayerAdded(p) end

task.spawn(function()
	while true do task.wait(UPDATE_RATE); updatePinListing() end
end)

game:BindToClose(function()
	if CurrentPin then pcall(function() PinMap:RemoveAsync(CurrentPin) end) end
end)