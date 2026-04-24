--[=[ PATH: ServerScriptService/Server/UpdateManager.legacy.luau | TYPE: Script ]=]--
--[[
	UPDATE MANAGER & SOFT SHUTDOWN
	1. Notifies Discord on new version deployment.
	2. Handles Soft Shutdown (Teleport to Lobby -> Teleport back to New Server).
]]

local TeleportService = game:GetService("TeleportService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local DataStoreService = game:GetService("DataStoreService")
local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local WEBHOOK_URL = "https://discord.com/api/webhooks/1473451536716927170/lBhyAHJm1ovPWIL75wPxgKNoYSOgCKB41AenSGUQTWuHzgtnypZub151sAPh2nIwxJQA"
local VersionStore = DataStoreService:GetDataStore("GameVersionHistory")

-- // DISCORD NOTIFICATION //
local function PostUpdateNotification()
	if RunService:IsStudio() then return end

	local version = game.PlaceVersion
	local key = "Version_" .. version

	-- Check if already announced
	local success, announced = pcall(function()
		return VersionStore:GetAsync(key)
	end)

	if success and not announced then
		-- Mark as announced immediately to prevent race conditions
		VersionStore:SetAsync(key, true)

		local payload = {
			username = "Mountain Architect Updates",
			avatar_url = "https://i.imgur.com/4W8p3qL.png",
			content = "Attention Testers! New Update Deployed.",
			embeds = {{
				title = "Update v" .. version,
				description = "A new server version has been published. Soft shutdown initiated for all servers.",
				color = 5763719, -- Green
				fields = {
					{ name = "Status", value = "Live", inline = true },
					{ name = "Time", value = os.date("!%Y-%m-%dT%H:%M:%SZ"), inline = true }
				},
				footer = { text = "Mountain Architect Automation" }
			}}
		}

		pcall(function()
			HttpService:PostAsync(WEBHOOK_URL, HttpService:JSONEncode(payload))
		end)
	end
end

-- // SOFT SHUTDOWN LOGIC //
local function PerformSoftShutdown()
	if RunService:IsStudio() then return end

	local players = Players:GetPlayers()
	if #players == 0 then return end

	-- Force Save via SlotDataLoader
	local Events = ReplicatedStorage:FindFirstChild("Events")
	if Events then
		local RequestSave = Events:FindFirstChild("RequestSave")
		if RequestSave then
			local success, _ = pcall(function() return RequestSave:Invoke() end)
		end
	end

	-- UI for Countdown
	for _, player in ipairs(players) do
		local gui = Instance.new("ScreenGui")
		gui.Name = "ShutdownGUI"
		gui.IgnoreGuiInset = true
		gui.Parent = player:WaitForChild("PlayerGui")
		
		local bar = Instance.new("Frame")
		bar.Size = UDim2.new(1, 0, 0, 60)
		bar.BackgroundColor3 = Color3.fromRGB(230, 60, 60)
		bar.BorderSizePixel = 0
		bar.Parent = gui
		
		local label = Instance.new("TextLabel")
		label.Size = UDim2.new(1, 0, 1, 0)
		label.BackgroundTransparency = 1
		label.Text = "⚠️ SERVER RESTARTING IN 60s"
		label.TextColor3 = Color3.new(1, 1, 1)
		label.Font = Enum.Font.GothamBold
		label.TextSize = 24
		label.Parent = bar
	end

	-- Countdown Loop
	for i = 60, 1, -1 do
		for _, player in ipairs(Players:GetPlayers()) do
			local gui = player.PlayerGui:FindFirstChild("ShutdownGUI")
			if gui and gui:FindFirstChild("Frame") and gui.Frame:FindFirstChild("TextLabel") then
				gui.Frame.TextLabel.Text = "⚠️ SERVER RESTARTING IN " .. i .. "s"
			end
		end
		task.wait(1)
	end

	-- Teleport to Start Place
	TeleportService:TeleportAsync(game.PlaceId, Players:GetPlayers())
	task.wait(10)
end

-- // INITIALIZATION //

-- 2. Check for update notification (only on normal servers)
if game.PrivateServerId == "" then
	task.spawn(PostUpdateNotification)
end

-- 3. Bind Shutdown
game:BindToClose(function()
	PerformSoftShutdown()
end)