local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local MarketplaceService = game:GetService("MarketplaceService")

local Player = Players.LocalPlayer
local PlayerGui = Player:WaitForChild("PlayerGui")

local EVENT_DEBOUNCE_SECONDS = 0.2
local REMOTE_WAIT_SECONDS = 2
local MAX_TEXT_LENGTH = 120

local trackedButtons = setmetatable({}, { __mode = "k" })
local trackedMenus = setmetatable({}, { __mode = "k" })
local menuOpenAt = {}
local lastEventAt = {}

local telemetryRemote = nil

local function fnv32(text)
	local hash = 2166136261
	for i = 1, #text do
		hash = bit32.bxor(hash, string.byte(text, i))
		hash = (hash * 16777619) % 4294967296
	end
	return hash
end

local function sanitizeSegment(raw)
	local text = string.lower(tostring(raw or ""))
	text = string.gsub(text, "[^%w]+", "_")
	text = string.gsub(text, "_+", "_")
	text = string.gsub(text, "^_", "")
	text = string.gsub(text, "_$", "")
	if text == "" then
		return "x"
	end
	return text
end

local function trimText(text)
	local asText = tostring(text or "")
	if #asText > MAX_TEXT_LENGTH then
		return string.sub(asText, 1, MAX_TEXT_LENGTH)
	end
	return asText
end

local function getGuiPath(guiObject)
	local segments = {}
	local current = guiObject
	while current and current ~= PlayerGui do
		table.insert(segments, 1, sanitizeSegment(current.Name))
		current = current.Parent
	end
	local path = table.concat(segments, "_")
	if path == "" then
		return "unknown"
	end
	return path
end

local function getTelemetryRemote()
	if telemetryRemote and telemetryRemote.Parent then
		return telemetryRemote
	end

	local eventsFolder = ReplicatedStorage:FindFirstChild("Events")
	if eventsFolder then
		local remote = eventsFolder:FindFirstChild("ClientTelemetryEvent")
		if not remote then
			local ok, waited = pcall(function()
				return eventsFolder:WaitForChild("ClientTelemetryEvent", REMOTE_WAIT_SECONDS)
			end)
			if ok then
				remote = waited
			end
		end
		if remote and remote:IsA("RemoteEvent") then
			telemetryRemote = remote
			return telemetryRemote
		end
	end

	local direct = ReplicatedStorage:FindFirstChild("ClientTelemetryEvent")
	if direct and direct:IsA("RemoteEvent") then
		telemetryRemote = direct
		return telemetryRemote
	end

	return nil
end

local function shouldDebounce(eventKey)
	local nowClock = os.clock()
	local lastAt = lastEventAt[eventKey]
	if lastAt and (nowClock - lastAt) < EVENT_DEBOUNCE_SECONDS then
		return true
	end
	lastEventAt[eventKey] = nowClock
	return false
end

local function sendTelemetry(category, action, payload)
	local eventKey = string.format("%s:%s:%s", tostring(category), tostring(action), tostring(payload and payload.path or payload and payload.event_name or "x"))
	if shouldDebounce(eventKey) then
		return
	end

	local remote = getTelemetryRemote()
	if remote then
		pcall(function()
			remote:FireServer({
				category = category,
				action = action,
				data = payload,
			})
		end)
		return
	end
end

local function bindButton(button)
	if trackedButtons[button] then
		return
	end
	trackedButtons[button] = true

	button.Activated:Connect(function()
		if button:GetAttribute("AnalyticsIgnore") == true or button:GetAttribute("TelemetryIgnore") == true then
			return
		end

		local buttonText = ""
		pcall(function()
			buttonText = tostring(button.Text)
		end)

		local path = getGuiPath(button)
		local eventName = string.format("ui_%s_%08x", path, fnv32(path))
		sendTelemetry("ui", "button_click", {
			event_name = eventName,
			path = path,
			button_name = trimText(button.Name),
			button_text = trimText(buttonText),
		})
	end)
end

local function shouldTrackMenuObject(guiObject)
	if guiObject:IsA("GuiButton") then
		return false
	end
	if guiObject:GetAttribute("TelemetryIgnore") == true or guiObject:GetAttribute("AnalyticsIgnore") == true then
		return false
	end
	
	if guiObject:IsA("ScreenGui") then
		return true
	end
	
	if guiObject:IsA("GuiObject") then
		local parent = guiObject.Parent
		if parent and parent:IsA("ScreenGui") then
			return true
		end
		
		local name = string.lower(guiObject.Name)
		if string.match(name, "panel$")
			or string.match(name, "menu$")
			or string.match(name, "frame$")
			or string.match(name, "gui$")
			or string.match(name, "window$")
			or string.match(name, "popup$")
			or string.match(name, "modal$")
			or string.match(name, "dialog$")
			or string.match(name, "screen$") then
			return true
		end
	end
	
	return false
end

local function bindMenu(guiObject)
	if trackedMenus[guiObject] or not shouldTrackMenuObject(guiObject) then
		return
	end
	trackedMenus[guiObject] = true

	local menuKey = getGuiPath(guiObject)
	local isScreenGui = guiObject:IsA("ScreenGui")
	local propName = isScreenGui and "Enabled" or "Visible"
	
	if guiObject[propName] then
		menuOpenAt[guiObject] = os.clock()
		sendTelemetry("menu", "open", {
			menu = menuKey,
			path = menuKey,
		})
	end

	guiObject:GetPropertyChangedSignal(propName):Connect(function()
		if guiObject[propName] then
			menuOpenAt[guiObject] = os.clock()
			sendTelemetry("menu", "open", {
				menu = menuKey,
				path = menuKey,
			})
		else
			local openedAt = menuOpenAt[guiObject]
			menuOpenAt[guiObject] = nil
			local duration = 0
			if openedAt then
				duration = math.max(0, os.clock() - openedAt)
			end
			sendTelemetry("menu", "close", {
				menu = menuKey,
				path = menuKey,
				duration_seconds = math.floor(duration * 1000 + 0.5) / 1000,
			})
		end
	end)
end

local function bindPurchaseTelemetry()
	MarketplaceService.PromptGamePassPurchaseFinished:Connect(function(passId, wasPurchased)
		sendTelemetry("purchase", "gamepass_prompt_result", {
			item_id = passId,
			purchased = wasPurchased == true,
			source = "client",
		})
	end)

	local okSub, subSignal = pcall(function()
		return MarketplaceService.PromptSubscriptionPurchaseFinished
	end)
	if okSub and typeof(subSignal) == "RBXScriptSignal" then
		subSignal:Connect(function(subscriptionId, wasPurchased)
			sendTelemetry("purchase", "subscription_prompt_result", {
				item_id = tostring(subscriptionId),
				purchased = wasPurchased == true,
				source = "client",
			})
		end)
	end

	local okProduct, productSignal = pcall(function()
		return MarketplaceService.PromptProductPurchaseFinished
	end)
	if okProduct and typeof(productSignal) == "RBXScriptSignal" then
		productSignal:Connect(function(userIdOrProductId, productIdOrPurchased, purchasedMaybe)
			local productId = productIdOrPurchased
			local wasPurchased = purchasedMaybe
			if type(productIdOrPurchased) == "boolean" then
				productId = userIdOrProductId
				wasPurchased = productIdOrPurchased
			end
			sendTelemetry("purchase", "product_prompt_result", {
				item_id = tonumber(productId) or 0,
				purchased = wasPurchased == true,
				source = "client",
			})
		end)
	end
end

for _, child in ipairs(PlayerGui:GetChildren()) do
	if child:IsA("ScreenGui") then
		bindMenu(child)
	end
end

for _, descendant in ipairs(PlayerGui:GetDescendants()) do
	if descendant:IsA("GuiButton") then
		bindButton(descendant)
	end
	if descendant:IsA("GuiObject") or descendant:IsA("ScreenGui") then
		bindMenu(descendant)
	end
end

PlayerGui.DescendantAdded:Connect(function(descendant)
	if descendant:IsA("GuiButton") then
		bindButton(descendant)
	end
	if descendant:IsA("GuiObject") or descendant:IsA("ScreenGui") then
		bindMenu(descendant)
	end
end)

bindPurchaseTelemetry()
