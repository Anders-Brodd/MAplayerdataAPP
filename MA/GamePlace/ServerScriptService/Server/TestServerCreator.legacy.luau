local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TeleportService = game:GetService("TeleportService")
local RunService = game:GetService("RunService")

-- // CONFIGURATION //
local MAIN_GAME_ID = 117869454878577
local TEST_GAME_ID = 9856266771

-- Automatically detect if we are in the Test Place
local TARGET_PLACE_ID = (game.PlaceId == TEST_GAME_ID) and TEST_GAME_ID or MAIN_GAME_ID

-- 1. Create the RemoteFunction if it doesn't exist
local remoteName = "CreateTestServer"
local remote = ReplicatedStorage:FindFirstChild(remoteName)
if not remote then
	remote = Instance.new("RemoteFunction")
	remote.Name = remoteName
	remote.Parent = ReplicatedStorage
end

-- 2. Handle the Client Request
remote.OnServerInvoke = function(player)

	-- CHECK: Are we in Studio?
	if RunService:IsStudio() then
		return "STUDIO_ERR"
	end

	local placeId = (TARGET_PLACE_ID > 0) and TARGET_PLACE_ID or game.PlaceId

	-- Attempt to reserve a server
	local code
	local success, err = pcall(function()
		code = TeleportService:ReserveServerAsync(placeId)
	end)

	if not success or not code then
		return "RESERVE_ERR"
	end

	-- Create TeleportOptions with the code embedded
	local teleportOptions = Instance.new("TeleportOptions")
	teleportOptions.ReservedServerAccessCode = code

	-- CRITICAL: Pass the code as TeleportData so the new server knows its own code
	teleportOptions:SetTeleportData({
		JoinCode = code,
		CreatedBy = player.Name,
		Timestamp = os.time()
	})

	-- Teleport the player
	local tpSuccess, tpErr = pcall(function()
		TeleportService:TeleportAsync(placeId, {player}, teleportOptions)
	end)

	if not tpSuccess then
		return "TP_ERR: " .. tostring(tpErr)
	end

	return "SUCCESS"
end