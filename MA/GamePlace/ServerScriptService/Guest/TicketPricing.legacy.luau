if true then
	return
end

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

-- // CONFIG //
local CHECK_INTERVAL = 10 
local BASE_WILLINGNESS = 10 
local RATING_MULTIPLIER = 18 

-- // DEPENDENCIES //
local RatingSystem
task.spawn(function()
	repeat task.wait(1) until _G.RatingSystem or ServerScriptService:FindFirstChild("RatingSystem")
	if _G.RatingSystem then
		RatingSystem = _G.RatingSystem
	else
		local module = ServerScriptService:WaitForChild("Server"):FindFirstChild("RatingSystem")
		if module then RatingSystem = require(module) end
	end
end)

local Events = ReplicatedStorage:FindFirstChild("Events") or Instance.new("Folder", ReplicatedStorage)
Events.Name = "Events"

local TicketEvent = Events:FindFirstChild("SetTicketPrice") or Instance.new("RemoteEvent", Events)
TicketEvent.Name = "SetTicketPrice"

local NotificationEvent = Events:FindFirstChild("NotificationEvent") or Instance.new("RemoteEvent", Events)
NotificationEvent.Name = "NotificationEvent"

local PlayerPrices = {} 

local function getFairPrice(rating)
	return math.floor(BASE_WILLINGNESS + (rating * RATING_MULTIPLIER))
end

-- // MAIN LOGIC //
TicketEvent.OnServerEvent:Connect(function(player, price)
	if type(price) ~= "number" then return end

	-- No more max limit enforcement here!
	-- Clamp only minimum to prevent negative pricing exploits
	price = math.max(0, math.floor(price))

	PlayerPrices[player.UserId] = price
	player:SetAttribute("TicketPrice", price)

	-- Feedback
	local rating = RatingSystem and RatingSystem.GetRating(player) or 1
	local fair = getFairPrice(rating)

	if price > fair * 1.5 then
		NotificationEvent:FireClient(player, "Warning", "Guests think $"..price.." is a ripoff!")
	elseif price < fair * 0.5 then
		NotificationEvent:FireClient(player, "Info", "Guests love this cheap price!")
	else
		NotificationEvent:FireClient(player, "Success", "Ticket price set to $"..price)
	end
end)

-- // GAME LOOP //
task.spawn(function()
	while true do
		task.wait(CHECK_INTERVAL)
		for _, player in pairs(Players:GetPlayers()) do
			local currentPrice = PlayerPrices[player.UserId] or 10 
			local rating = RatingSystem and RatingSystem.GetRating(player) or 1
			local fairPrice = getFairPrice(rating)

			local ratio = currentPrice / math.max(1, fairPrice)
			local demand = 1.0

			if ratio > 1.0 then
				demand = math.max(0.1, 1.0 / (ratio * ratio * ratio))
			else
				demand = math.min(1.5, 1.0 + (1.0 - ratio))
			end

			player:SetAttribute("GuestDemand", demand)

			if RatingSystem then
				if ratio > 1.3 then
					if math.random() > 0.5 then 
						RatingSystem.ReportEvent(player, "GenericNegative", -0.05)
					end
				elseif ratio < 0.6 then
					if math.random() > 0.7 then 
						RatingSystem.ReportEvent(player, "GenericPositive", 0.02)
					end
				end
			end
		end
	end
end)

Players.PlayerRemoving:Connect(function(player)
	PlayerPrices[player.UserId] = nil
end)