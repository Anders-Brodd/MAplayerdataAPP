-- Mountain Architect Bug Report Server Handler
local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local WEBHOOK_URL = "https://webhook.lewisakura.moe/api/webhooks/1464049677333827732/JJ331OvhGp6PM0lrjOHiVkaa8FZI6YtCegC3GgELV1kueCVgCKPyqlMx-_B5J12hsHjT"
local Remote = ReplicatedStorage:WaitForChild("MountainArchitect_BugSystem_Remote")

-- Cooldown Table (PlayerUserId -> Tick)
local cooldowns = {}
local COOLDOWN_TIME = 60 -- Seconds between reports per player

local function formatTime(seconds)
    return os.date("!%Y-%m-%dT%H:%M:%SZ")
end

local function sendToDiscord(player, data)
    -- 1. Rate Limit Check
    local lastReport = cooldowns[player.UserId]
    if lastReport and (os.time() - lastReport) < COOLDOWN_TIME then
        return {Success = false, Message = "Please wait " .. math.ceil(COOLDOWN_TIME - (os.time() - lastReport)) .. "s before sending another report."}
    end

    -- 2. Validate Data
    if not data.Title or #data.Title < 3 then return {Success = false, Message = "Title too short."} end
    if not data.Description or #data.Description < 10 then return {Success = false, Message = "Description too short."} end

    -- 3. Determine Color based on Severity
    local color = 3447003 -- Default Blue
    if data.Severity == "Low" then color = 16776960 -- Yellow
    elseif data.Severity == "Medium" then color = 16753920 -- Orange
    elseif data.Severity == "High" then color = 15158332 -- Red
    elseif data.Severity == "Critical" then color = 10038562 -- Dark Red
    end

    -- 4. Construct Payload
    local payload = {
        username = "Mountain Architect Bot",
        avatar_url = "https://i.imgur.com/4W8p3qL.png", -- Generic bug icon, replace if desired
        embeds = {{
            title = "🪲 New Bug Report: " .. data.Title,
            description = data.Description,
            color = color,
            fields = {
                { name = "Category", value = data.Category, inline = true },
                { name = "Severity", value = "**" .. data.Severity .. "**", inline = true },
                { name = "Reproduction Steps", value = data.Steps or "None provided", inline = false },
                { name = "Reported By", value = player.Name .. " (" .. player.UserId .. ")", inline = true },
                { name = "Game Version", value = tostring(game.PlaceVersion), inline = true },
                { name = "Server JobID", value = game.JobId ~= "" and game.JobId or "Studio", inline = false },
                { name = "Camera Location", value = "`" .. data.CamCFrame .. "`", inline = false }
            },
            footer = {
                text = "Mountain Architect • " .. os.date("%c"),
            },
            timestamp = formatTime(os.time())
        }}
    }

    -- 5. Send Request
    local success, response = pcall(function()
        return HttpService:PostAsync(WEBHOOK_URL, HttpService:JSONEncode(payload))
    end)

    if success then
        cooldowns[player.UserId] = os.time()
        return {Success = true, Message = "Report sent to the team!"}
    else
        return {Success = false, Message = "Failed to connect to server. Try again."}
    end
end

Remote.OnServerInvoke = sendToDiscord
