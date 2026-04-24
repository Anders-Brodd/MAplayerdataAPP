--[[
    MOUNTAIN ARCHITECT - DUAL SERVER HANDLER (Discord + Stratum)
    Place in ServerScriptService > BugReport_Server
]]

local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

-- // CONFIGURATION //
-- 1. Your Discord Webhook (Keep this for the Discord alerts)
local DISCORD_WEBHOOK = "https://webhook.lewisakura.moe/api/webhooks/1494781755914190898/hQxZRmptI4pf1H20Ms8ZFlIMrfFwBESMe3wL5Ol5VghFnA50hyilfBkzTtXce9rb-YCJ"
-- 2. Your Custom Website API (For the Database)
local STRATUM_API = "https://stratum.coderhue.dev/api/bugs.php"
local REMOTE_NAME = "MountainArchitect_BugSystem_Remote"

-- // SETUP REMOTE //
local Remote = ReplicatedStorage:FindFirstChild(REMOTE_NAME)
if not Remote then
	Remote = Instance.new("RemoteFunction")
	Remote.Name = REMOTE_NAME
	Remote.Parent = ReplicatedStorage
end

-- // COOLDOWN LOGIC //
local cooldowns = {}
local COOLDOWN_TIME = 60 -- Seconds between reports per player

local function sendToDiscord(player, data)
	-- 1. Rate Limit Check
	local lastReport = cooldowns[player.UserId]
	if lastReport and (os.time() - lastReport) < COOLDOWN_TIME then
		local waitTime = math.ceil(COOLDOWN_TIME - (os.time() - lastReport))
		return {Success = false, Message = "Please wait " .. waitTime .. "s before sending another report."}
	end

	-- 2. Validate Data
	if not data.Title or #data.Title < 3 then return {Success = false, Message = "Title is too short."} end
	if not data.Description or #data.Description < 10 then return {Success = false, Message = "Description is too short."} end

	-- 3. Color Logic
	local color = 3447003 -- Blue
	if data.Severity == "Low" then color = 16776960 -- Yellow
	elseif data.Severity == "Medium" then color = 16753920 -- Orange
	elseif data.Severity == "High" then color = 15158332 -- Red
	elseif data.Severity == "Critical" then color = 10038562 -- Dark Red
	end

	-- 4. Payload Construction (Discord Format)
	local discordPayload = {
		content = "Get to work.", -- PING!
		username = "Mountain Architect Bot",
		avatar_url = "https://i.imgur.com/4W8p3qL.png",
		embeds = {{
			title = "🪲 New Bug Report: " .. data.Title,
			description = data.Description,
			color = color,
			fields = {
				{ name = "Category", value = data.Category, inline = true },
				{ name = "Severity", value = "**" .. data.Severity .. "**", inline = true },
				{ name = "Reproduction Steps", value = data.Steps or "None provided", inline = false },
				{ name = "Reported By", value = player.Name .. " (" .. player.UserId .. ")", inline = true },
				{ name = "Client Data", value = data.DeviceInfo or "N/A", inline = false },
				{ name = "Server JobID", value = game.JobId ~= "" and game.JobId or "Studio", inline = false },
				{ name = "Camera Location", value = "`" .. tostring(data.CamCFrame) .. "`", inline = false }
			},
			footer = { text = "Mountain Architect • " .. os.date("%c") },
			timestamp = os.date("!%Y-%m-%dT%H:%M:%SZ")
		}}
	}

	local discordJson = HttpService:JSONEncode(discordPayload)

	-- 5. Send to DISCORD (Async)
	coroutine.wrap(function()
		local success, err = pcall(function()
			HttpService:PostAsync(DISCORD_WEBHOOK, discordJson)
		end)
	end)()

	-- 6. Payload Construction (Stratum API Format)
	-- The PHP API expects a flat JSON object, not a Discord embed structure.
	local stratumPayload = {
		Title = data.Title,
		Description = data.Description,
		Steps = data.Steps or "",
		Category = data.Category or "Coding",
		Severity = data.Severity or "Medium",
		ReportedBy = player.Name,
		DeviceInfo = data.DeviceInfo or "N/A",
		CamCFrame = tostring(data.CamCFrame)
	}

	local stratumJson = HttpService:JSONEncode(stratumPayload)

	-- 7. Send to STRATUM WEBSITE (Async)
	coroutine.wrap(function()
		local success, response = pcall(function()
			HttpService:PostAsync(STRATUM_API, stratumJson)
		end)
	end)()

	-- 8. Success for Client
	cooldowns[player.UserId] = os.time()
	return {Success = true, Message = "Report sent to Discord & Database!"}
end

Remote.OnServerInvoke = sendToDiscord
