local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local HttpService = game:GetService("HttpService")
local TextChatService = game:GetService("TextChatService")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local SNAPSHOT_REMOTE_NAME = "TelemetryGetSnapshot"
local TOGGLE_KEY = Enum.KeyCode.J
local MAX_TEXT_LENGTH = 180000
local MAX_RECENT_EVENTS = 80
local CHAT_COMMAND_NAME = "OpenPlayerData"
local CHAT_ALIAS = "/playerdata"
local TAB_ORDER = {"Overview", "Economy", "Building", "UI", "Events", "Raw"}

local snapshotRemote = nil

local function trim(value)
	return string.gsub(tostring(value or ""), "^%s*(.-)%s*$", "%1")
end

local function toNumber(value)
	local num = tonumber(value)
	if not num or num ~= num or num == math.huge or num == -math.huge then
		return 0
	end
	return num
end

local function startsWith(text, prefix)
	return string.sub(text, 1, #prefix) == prefix
end

local function formatCount(value)
	local rounded = math.floor(toNumber(value) + 0.5)
	local text = tostring(rounded)
	while true do
		local updated, hits = string.gsub(text, "^(%-?%d+)(%d%d%d)", "%1,%2")
		text = updated
		if hits == 0 then
			break
		end
	end
	return text
end

local function formatSeconds(value)
	local total = math.max(0, math.floor(toNumber(value) + 0.5))
	local h = math.floor(total / 3600)
	local m = math.floor((total % 3600) / 60)
	local s = total % 60
	if h > 0 then
		return string.format("%dh %02dm %02ds", h, m, s)
	end
	if m > 0 then
		return string.format("%dm %02ds", m, s)
	end
	return string.format("%ds", s)
end

local function safeJson(value)
	local ok, encoded = pcall(function()
		return HttpService:JSONEncode(value)
	end)
	if not ok then
		return tostring(value)
	end
	return encoded
end

local function formatPayload(payload)
	local encoded = safeJson(payload)
	if #encoded > MAX_TEXT_LENGTH then
		return string.sub(encoded, 1, MAX_TEXT_LENGTH) .. "\n\n[TRUNCATED]"
	end
	return encoded
end

local function lowerTrim(value)
	return string.lower(trim(value))
end

local function getSnapshotRemote()
	if snapshotRemote and snapshotRemote.Parent then
		return snapshotRemote
	end
	local found = ReplicatedStorage:FindFirstChild(SNAPSHOT_REMOTE_NAME)
	if found and found:IsA("RemoteFunction") then
		snapshotRemote = found
		return snapshotRemote
	end
	return nil
end

local function hasViewerAccess()
	local remote = getSnapshotRemote()
	if not remote then
		return false
	end

	for attempt = 1, 3 do
		local ok, result = pcall(function()
			return remote:InvokeServer(player.UserId)
		end)

		if ok and type(result) == "table" then
			if result.Success == true then
				return true
			end
			local errText = tostring(result.Error or "")
			if errText == "Unauthorized" or errText == "Forbidden" then
				return false
			end
		end

		task.wait(0.4 * attempt)
	end

	return false
end

if not hasViewerAccess() then
	return
end

local screen = Instance.new("ScreenGui")
screen.Name = "TelemetryDataManagerUI"
screen.ResetOnSpawn = false
screen.IgnoreGuiInset = true
screen.Enabled = false
screen.Parent = playerGui

local frame = Instance.new("Frame")
frame.Name = "Panel"
frame.AnchorPoint = Vector2.new(0.5, 0.5)
frame.Position = UDim2.new(0.5, 0, 0.5, 0)
frame.Size = UDim2.new(0.9, 0, 0.84, 0)
frame.BackgroundColor3 = Color3.fromRGB(18, 23, 33)
frame.BorderSizePixel = 0
frame.Parent = screen

local frameCorner = Instance.new("UICorner")
frameCorner.CornerRadius = UDim.new(0, 10)
frameCorner.Parent = frame

local stroke = Instance.new("UIStroke")
stroke.Color = Color3.fromRGB(69, 88, 122)
stroke.Thickness = 1
stroke.Parent = frame

local title = Instance.new("TextLabel")
title.Name = "Title"
title.BackgroundTransparency = 1
title.Position = UDim2.new(0, 14, 0, 8)
title.Size = UDim2.new(1, -190, 0, 28)
title.Font = Enum.Font.GothamBold
title.TextSize = 18
title.TextColor3 = Color3.fromRGB(236, 242, 255)
title.TextXAlignment = Enum.TextXAlignment.Left
title.Text = "Data Manager (Ctrl+J or /playerdata)"
title.Parent = frame

local status = Instance.new("TextLabel")
status.Name = "Status"
status.BackgroundTransparency = 1
status.Position = UDim2.new(0, 14, 0, 34)
status.Size = UDim2.new(1, -190, 0, 20)
status.Font = Enum.Font.Gotham
status.TextSize = 13
status.TextColor3 = Color3.fromRGB(169, 183, 214)
status.TextXAlignment = Enum.TextXAlignment.Left
status.Text = "Ready"
status.Parent = frame

local refreshButton = Instance.new("TextButton")
refreshButton.Name = "RefreshButton"
refreshButton.AnchorPoint = Vector2.new(1, 0)
refreshButton.Position = UDim2.new(1, -104, 0, 10)
refreshButton.Size = UDim2.new(0, 88, 0, 28)
refreshButton.BackgroundColor3 = Color3.fromRGB(39, 118, 81)
refreshButton.BorderSizePixel = 0
refreshButton.Font = Enum.Font.GothamBold
refreshButton.TextSize = 13
refreshButton.TextColor3 = Color3.fromRGB(246, 255, 249)
refreshButton.Text = "Refresh"
refreshButton.Parent = frame

local refreshCorner = Instance.new("UICorner")
refreshCorner.CornerRadius = UDim.new(0, 8)
refreshCorner.Parent = refreshButton

local closeButton = Instance.new("TextButton")
closeButton.Name = "CloseButton"
closeButton.AnchorPoint = Vector2.new(1, 0)
closeButton.Position = UDim2.new(1, -10, 0, 10)
closeButton.Size = UDim2.new(0, 88, 0, 28)
closeButton.BackgroundColor3 = Color3.fromRGB(111, 43, 55)
closeButton.BorderSizePixel = 0
closeButton.Font = Enum.Font.GothamBold
closeButton.TextSize = 13
closeButton.TextColor3 = Color3.fromRGB(255, 241, 244)
closeButton.Text = "Close"
closeButton.Parent = frame

local closeCorner = Instance.new("UICorner")
closeCorner.CornerRadius = UDim.new(0, 8)
closeCorner.Parent = closeButton

local targetLabel = Instance.new("TextLabel")
targetLabel.Name = "TargetLabel"
targetLabel.BackgroundTransparency = 1
targetLabel.Position = UDim2.new(0, 12, 0, 58)
targetLabel.Size = UDim2.new(0, 44, 0, 24)
targetLabel.Font = Enum.Font.GothamBold
targetLabel.TextSize = 12
targetLabel.TextColor3 = Color3.fromRGB(208, 219, 248)
targetLabel.TextXAlignment = Enum.TextXAlignment.Left
targetLabel.Text = "Player"
targetLabel.Parent = frame

local targetBox = Instance.new("TextBox")
targetBox.Name = "TargetBox"
targetBox.BackgroundColor3 = Color3.fromRGB(9, 14, 22)
targetBox.BorderSizePixel = 0
targetBox.Position = UDim2.new(0, 58, 0, 56)
targetBox.Size = UDim2.new(0, 190, 0, 28)
targetBox.ClearTextOnFocus = false
targetBox.Font = Enum.Font.Gotham
targetBox.TextSize = 12
targetBox.TextColor3 = Color3.fromRGB(236, 242, 255)
targetBox.PlaceholderColor3 = Color3.fromRGB(140, 155, 185)
targetBox.PlaceholderText = "Name or userId"
targetBox.Text = player.Name
targetBox.Parent = frame

local targetCorner = Instance.new("UICorner")
targetCorner.CornerRadius = UDim.new(0, 6)
targetCorner.Parent = targetBox

local loadButton = Instance.new("TextButton")
loadButton.Name = "LoadButton"
loadButton.BackgroundColor3 = Color3.fromRGB(47, 73, 124)
loadButton.BorderSizePixel = 0
loadButton.Position = UDim2.new(0, 254, 0, 56)
loadButton.Size = UDim2.new(0, 56, 0, 28)
loadButton.Font = Enum.Font.GothamBold
loadButton.TextSize = 12
loadButton.TextColor3 = Color3.fromRGB(242, 247, 255)
loadButton.Text = "Load"
loadButton.Parent = frame

local loadCorner = Instance.new("UICorner")
loadCorner.CornerRadius = UDim.new(0, 6)
loadCorner.Parent = loadButton

local selfButton = Instance.new("TextButton")
selfButton.Name = "SelfButton"
selfButton.BackgroundColor3 = Color3.fromRGB(59, 97, 76)
selfButton.BorderSizePixel = 0
selfButton.Position = UDim2.new(0, 314, 0, 56)
selfButton.Size = UDim2.new(0, 56, 0, 28)
selfButton.Font = Enum.Font.GothamBold
selfButton.TextSize = 12
selfButton.TextColor3 = Color3.fromRGB(242, 255, 246)
selfButton.Text = "Self"
selfButton.Parent = frame

local selfCorner = Instance.new("UICorner")
selfCorner.CornerRadius = UDim.new(0, 6)
selfCorner.Parent = selfButton

local searchBox = Instance.new("TextBox")
searchBox.Name = "SearchBox"
searchBox.BackgroundColor3 = Color3.fromRGB(9, 14, 22)
searchBox.BorderSizePixel = 0
searchBox.Position = UDim2.new(0, 378, 0, 56)
searchBox.Size = UDim2.new(0, 220, 0, 28)
searchBox.ClearTextOnFocus = false
searchBox.Font = Enum.Font.Gotham
searchBox.TextSize = 12
searchBox.TextColor3 = Color3.fromRGB(236, 242, 255)
searchBox.PlaceholderColor3 = Color3.fromRGB(140, 155, 185)
searchBox.PlaceholderText = "Search within current tab"
searchBox.Text = ""
searchBox.Parent = frame

local searchCorner = Instance.new("UICorner")
searchCorner.CornerRadius = UDim.new(0, 6)
searchCorner.Parent = searchBox

local filterBox = Instance.new("TextBox")
filterBox.Name = "FilterBox"
filterBox.BackgroundColor3 = Color3.fromRGB(9, 14, 22)
filterBox.BorderSizePixel = 0
filterBox.Position = UDim2.new(0, 604, 0, 56)
filterBox.Size = UDim2.new(0, 210, 0, 28)
filterBox.ClearTextOnFocus = false
filterBox.Font = Enum.Font.Gotham
filterBox.TextSize = 12
filterBox.TextColor3 = Color3.fromRGB(236, 242, 255)
filterBox.PlaceholderColor3 = Color3.fromRGB(140, 155, 185)
filterBox.PlaceholderText = "Category filter (all/ui/money...)"
filterBox.Text = "all"
filterBox.Parent = frame

local filterCorner = Instance.new("UICorner")
filterCorner.CornerRadius = UDim.new(0, 6)
filterCorner.Parent = filterBox

local tabsFrame = Instance.new("Frame")
tabsFrame.Name = "Tabs"
tabsFrame.BackgroundTransparency = 1
tabsFrame.Position = UDim2.new(0, 10, 0, 90)
tabsFrame.Size = UDim2.new(1, -20, 0, 30)
tabsFrame.Parent = frame

local tabsLayout = Instance.new("UIListLayout")
tabsLayout.FillDirection = Enum.FillDirection.Horizontal
tabsLayout.HorizontalAlignment = Enum.HorizontalAlignment.Left
tabsLayout.VerticalAlignment = Enum.VerticalAlignment.Center
tabsLayout.Padding = UDim.new(0, 6)
tabsLayout.Parent = tabsFrame

local scroll = Instance.new("ScrollingFrame")
scroll.Name = "Content"
scroll.Position = UDim2.new(0, 10, 0, 126)
scroll.Size = UDim2.new(1, -20, 1, -136)
scroll.BackgroundColor3 = Color3.fromRGB(10, 14, 20)
scroll.BorderSizePixel = 0
scroll.ScrollBarThickness = 8
scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
scroll.CanvasSize = UDim2.fromOffset(0, 0)
scroll.Parent = frame

local scrollCorner = Instance.new("UICorner")
scrollCorner.CornerRadius = UDim.new(0, 8)
scrollCorner.Parent = scroll

local content = Instance.new("TextLabel")
content.Name = "ContentText"
content.BackgroundTransparency = 1
content.Position = UDim2.new(0, 8, 0, 8)
content.Size = UDim2.new(1, -16, 0, 0)
content.AutomaticSize = Enum.AutomaticSize.Y
content.Font = Enum.Font.Code
content.TextSize = 13
content.TextColor3 = Color3.fromRGB(208, 219, 248)
content.TextWrapped = true
content.TextXAlignment = Enum.TextXAlignment.Left
content.TextYAlignment = Enum.TextYAlignment.Top
content.Text = "No snapshot loaded yet."
content.Parent = scroll

local tabButtons = {}
local busy = false
local currentTab = "Overview"
local currentTargetUserId = player.UserId
local currentTargetLabel = player.Name
local currentSnapshot = nil
local currentModel = nil

local function sortedPairsDesc(map)
	local rows = {}
	if type(map) ~= "table" then
		return rows
	end
	for key, value in pairs(map) do
		table.insert(rows, {
			key = tostring(key),
			value = toNumber(value),
		})
	end
	table.sort(rows, function(a, b)
		if a.value == b.value then
			return a.key < b.key
		end
		return a.value > b.value
	end)
	return rows
end

local function summarizeEventData(data)
	if type(data) ~= "table" then
		return ""
	end
	local keys = {}
	for key in pairs(data) do
		table.insert(keys, tostring(key))
	end
	table.sort(keys)
	local chunks = {}
	local maxPairs = 3
	for i = 1, math.min(maxPairs, #keys) do
		local key = keys[i]
		table.insert(chunks, string.format("%s=%s", key, tostring(data[key])))
	end
	if #keys > maxPairs then
		table.insert(chunks, "+" .. tostring(#keys - maxPairs) .. " more")
	end
	return table.concat(chunks, ", ")
end

local function buildModelFromSnapshot(snapshot)
	if type(snapshot) ~= "table" then
		return nil
	end

	local stored = type(snapshot.StoredAndPending) == "table" and snapshot.StoredAndPending or {}
	local stats = type(stored.Stats) == "table" and stored.Stats or {}
	local categoryCounts = type(stored.CategoryCounts) == "table" and stored.CategoryCounts or {}
	local session = type(snapshot.Session) == "table" and snapshot.Session or {}
	local menuDurations = type(session.MenuDurations) == "table" and session.MenuDurations or {}
	local recentEventsRaw = type(session.RecentEvents) == "table" and session.RecentEvents or {}

	local recentEvents = {}
	for _, eventEntry in ipairs(recentEventsRaw) do
		if type(eventEntry) == "table" then
			table.insert(recentEvents, eventEntry)
		end
	end
	table.sort(recentEvents, function(a, b)
		return toNumber(a.ts) > toNumber(b.ts)
	end)

	return {
		snapshot = snapshot,
		stats = stats,
		categoryCounts = categoryCounts,
		categoryRows = sortedPairsDesc(categoryCounts),
		menuRows = sortedPairsDesc(menuDurations),
		recentEvents = recentEvents,
		session = session,
	}
end

local function normalizeCategoryFilter(raw)
	local token = lowerTrim(raw)
	if token == "" or token == "all" then
		return "all"
	end
	token = string.gsub(token, "[^%w_]+", "_")
	token = string.gsub(token, "_+", "_")
	token = string.gsub(token, "^_", "")
	token = string.gsub(token, "_$", "")
	if token == "" then
		return "all"
	end
	return token
end

local function eventMatchesFilters(eventEntry, categoryFilter, searchLower)
	local category = lowerTrim(eventEntry.category or "action")
	if categoryFilter ~= "all" and category ~= categoryFilter then
		return false
	end

	if searchLower == "" then
		return true
	end

	local hay = table.concat({
		lowerTrim(eventEntry.category),
		lowerTrim(eventEntry.action),
		lowerTrim(summarizeEventData(eventEntry.data)),
	}, " ")
	return string.find(hay, searchLower, 1, true) ~= nil
end

local function formatEventLine(index, eventEntry)
	local ts = toNumber(eventEntry.ts)
	local stamp = ts > 0 and os.date("%Y-%m-%d %H:%M:%S", ts) or "Unknown time"
	local category = tostring(eventEntry.category or "action")
	local action = tostring(eventEntry.action or "event")
	local summary = summarizeEventData(eventEntry.data)
	if summary ~= "" then
		return string.format("%d. [%s] %s/%s | %s", index, stamp, category, action, summary)
	end
	return string.format("%d. [%s] %s/%s", index, stamp, category, action)
end

local function applySearch(lines, searchLower)
	if searchLower == "" then
		return lines
	end

	local filtered = {}
	for _, line in ipairs(lines) do
		if startsWith(line, "===") or string.find(string.lower(line), searchLower, 1, true) then
			table.insert(filtered, line)
		end
	end

	if #filtered == 0 then
		return {"No lines matched search: " .. searchLower}
	end
	return filtered
end

local function buildOverviewLines(model)
	local lines = {}
	table.insert(lines, "=== OVERVIEW ===")
	table.insert(lines, string.format("User: %s (%s)", tostring(model.snapshot.Username or "Unknown"), tostring(model.snapshot.UserId or "?")))
	table.insert(lines, string.format("Generated: %s", os.date("%Y-%m-%d %H:%M:%S", toNumber(model.snapshot.GeneratedAt))))
	table.insert(lines, string.format("Session Elapsed: %s", formatSeconds(model.session.ElapsedSeconds)))
	table.insert(lines, string.format("Offline Snapshot: %s", tostring(model.snapshot.Offline == true)))
	table.insert(lines, "")
	table.insert(lines, "=== CORE COUNTERS ===")
	table.insert(lines, "- TimesPlayed: " .. formatCount(model.stats.TimesPlayed))
	table.insert(lines, "- TotalPlaytimeSeconds: " .. formatSeconds(model.stats.TotalPlaytimeSeconds))
	table.insert(lines, "- ButtonsClicked: " .. formatCount(model.stats.ButtonsClicked))
	table.insert(lines, "- MenusOpened: " .. formatCount(model.stats.MenusOpened))
	table.insert(lines, "- BuildingsPlaced: " .. formatCount(model.stats.BuildingsPlaced))
	table.insert(lines, "- BuildingCancellations: " .. formatCount(model.stats.BuildingCancellations))
	table.insert(lines, "- BugReports: " .. formatCount(model.stats.BugReports))
	table.insert(lines, "")
	table.insert(lines, "=== CATEGORY COUNTS (HIGH TO LOW) ===")
	if #model.categoryRows == 0 then
		table.insert(lines, "No category counts yet.")
	else
		for _, row in ipairs(model.categoryRows) do
			table.insert(lines, string.format("- %s: %s", row.key, formatCount(row.value)))
		end
	end
	return lines
end

local function buildEconomyLines(model, categoryFilter, searchLower)
	local lines = {}
	table.insert(lines, "=== ECONOMY ===")
	table.insert(lines, "- MoneyIn: " .. formatCount(model.stats.MoneyIn))
	table.insert(lines, "- MoneyOut: " .. formatCount(model.stats.MoneyOut))
	table.insert(lines, "- RobuxSpent: " .. formatCount(model.stats.RobuxSpent))
	table.insert(lines, "")
	table.insert(lines, "=== ECONOMY EVENTS ===")
	local count = 0
	for _, eventEntry in ipairs(model.recentEvents) do
		local category = lowerTrim(eventEntry.category or "")
		local economyCategory = (category == "money" or category == "purchase")
		if economyCategory and eventMatchesFilters(eventEntry, categoryFilter, searchLower) then
			count += 1
			table.insert(lines, formatEventLine(count, eventEntry))
			if count >= MAX_RECENT_EVENTS then
				break
			end
		end
	end
	if count == 0 then
		table.insert(lines, "No economy events matched current filters.")
	end
	return lines
end

local function buildBuildingLines(model, categoryFilter, searchLower)
	local lines = {}
	table.insert(lines, "=== BUILDING & RESORT ===")
	table.insert(lines, "- BuildingsPlaced: " .. formatCount(model.stats.BuildingsPlaced))
	table.insert(lines, "- BuildingCancellations: " .. formatCount(model.stats.BuildingCancellations))
	table.insert(lines, "- ResortsCreated: " .. formatCount(model.stats.ResortsCreated))
	table.insert(lines, "- ResortsDeleted: " .. formatCount(model.stats.ResortsDeleted))
	table.insert(lines, "")
	table.insert(lines, "=== BUILDING/RESORT EVENTS ===")
	local count = 0
	for _, eventEntry in ipairs(model.recentEvents) do
		local category = lowerTrim(eventEntry.category or "")
		local relevant = (category == "building" or category == "resort")
		if relevant and eventMatchesFilters(eventEntry, categoryFilter, searchLower) then
			count += 1
			table.insert(lines, formatEventLine(count, eventEntry))
			if count >= MAX_RECENT_EVENTS then
				break
			end
		end
	end
	if count == 0 then
		table.insert(lines, "No building/resort events matched current filters.")
	end
	return lines
end

local function buildUiLines(model, categoryFilter, searchLower)
	local lines = {}
	table.insert(lines, "=== UI ===")
	table.insert(lines, "- ButtonsClicked: " .. formatCount(model.stats.ButtonsClicked))
	table.insert(lines, "- MenusOpened: " .. formatCount(model.stats.MenusOpened))
	table.insert(lines, "")
	table.insert(lines, "=== MENU DURATIONS (LONGEST FIRST) ===")
	if #model.menuRows == 0 then
		table.insert(lines, "No menu durations tracked yet.")
	else
		for _, row in ipairs(model.menuRows) do
			table.insert(lines, string.format("- %s: %s", row.key, formatSeconds(row.value)))
		end
	end
	table.insert(lines, "")
	table.insert(lines, "=== UI/MENU EVENTS ===")
	local count = 0
	for _, eventEntry in ipairs(model.recentEvents) do
		local category = lowerTrim(eventEntry.category or "")
		local relevant = (category == "ui" or category == "menu" or category == "action")
		if relevant and eventMatchesFilters(eventEntry, categoryFilter, searchLower) then
			count += 1
			table.insert(lines, formatEventLine(count, eventEntry))
			if count >= MAX_RECENT_EVENTS then
				break
			end
		end
	end
	if count == 0 then
		table.insert(lines, "No UI/menu events matched current filters.")
	end
	return lines
end

local function buildEventLines(model, categoryFilter, searchLower)
	local lines = {}
	table.insert(lines, "=== EVENTS (NEWEST FIRST) ===")
	local count = 0
	for _, eventEntry in ipairs(model.recentEvents) do
		if eventMatchesFilters(eventEntry, categoryFilter, searchLower) then
			count += 1
			table.insert(lines, formatEventLine(count, eventEntry))
			if count >= MAX_RECENT_EVENTS then
				break
			end
		end
	end
	if count == 0 then
		table.insert(lines, "No recent events matched current filters.")
	end
	table.insert(lines, "")
	table.insert(lines, "Tip: filter categories include all, ui, menu, money, purchase, building, resort, bug_report, action, session")
	return lines
end

local function setOpen(isOpen)
	screen.Enabled = isOpen
end

local function renderCurrentView()
	if not currentModel then
		content.Text = "No snapshot loaded yet."
		return
	end

	local searchLower = lowerTrim(searchBox.Text)
	local categoryFilter = normalizeCategoryFilter(filterBox.Text)
	local lines = {}

	if currentTab == "Overview" then
		lines = applySearch(buildOverviewLines(currentModel), searchLower)
	elseif currentTab == "Economy" then
		lines = buildEconomyLines(currentModel, categoryFilter, searchLower)
	elseif currentTab == "Building" then
		lines = buildBuildingLines(currentModel, categoryFilter, searchLower)
	elseif currentTab == "UI" then
		lines = buildUiLines(currentModel, categoryFilter, searchLower)
	elseif currentTab == "Events" then
		lines = buildEventLines(currentModel, categoryFilter, searchLower)
	else
		local rawText = formatPayload(currentSnapshot)
		if searchLower ~= "" and not string.find(string.lower(rawText), searchLower, 1, true) then
			rawText = "No raw JSON match for search: " .. searchLower
		end
		if #rawText > MAX_TEXT_LENGTH then
			rawText = string.sub(rawText, 1, MAX_TEXT_LENGTH) .. "\n\n[TRUNCATED]"
		end
		content.Text = rawText
		status.Text = string.format("Viewing %s (%s) | Tab: %s | Filter: %s", currentTargetLabel, tostring(currentTargetUserId), currentTab, categoryFilter)
		return
	end

	local joined = table.concat(lines, "\n")
	if #joined > MAX_TEXT_LENGTH then
		joined = string.sub(joined, 1, MAX_TEXT_LENGTH) .. "\n\n[TRUNCATED]"
	end
	content.Text = joined
	status.Text = string.format("Viewing %s (%s) | Tab: %s | Filter: %s", currentTargetLabel, tostring(currentTargetUserId), currentTab, categoryFilter)
end

local function setActiveTab(tabName)
	currentTab = tabName
	for name, button in pairs(tabButtons) do
		if name == tabName then
			button.BackgroundColor3 = Color3.fromRGB(67, 120, 201)
			button.TextColor3 = Color3.fromRGB(246, 250, 255)
		else
			button.BackgroundColor3 = Color3.fromRGB(31, 43, 62)
			button.TextColor3 = Color3.fromRGB(185, 201, 231)
		end
	end
	renderCurrentView()
end

for _, tabName in ipairs(TAB_ORDER) do
	local tabButton = Instance.new("TextButton")
	tabButton.Name = tabName .. "Tab"
	tabButton.Size = UDim2.new(0, 104, 1, 0)
	tabButton.BackgroundColor3 = Color3.fromRGB(31, 43, 62)
	tabButton.BorderSizePixel = 0
	tabButton.Font = Enum.Font.GothamBold
	tabButton.TextSize = 12
	tabButton.Text = tabName
	tabButton.TextColor3 = Color3.fromRGB(185, 201, 231)
	tabButton.Parent = tabsFrame

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 6)
	corner.Parent = tabButton

	tabButton.Activated:Connect(function()
		setActiveTab(tabName)
	end)

	tabButtons[tabName] = tabButton
end

local function resolveDisplayNameForUserId(userId)
	local online = Players:GetPlayerByUserId(userId)
	if online then
		return online.Name
	end
	local ok, resolved = pcall(function()
		return Players:GetNameFromUserIdAsync(userId)
	end)
	if ok and type(resolved) == "string" and resolved ~= "" then
		return resolved
	end
	return tostring(userId)
end

local function resolveTargetUser(inputText)
	local cleaned = trim(inputText)
	if cleaned == "" then
		return player.UserId, player.Name, nil
	end

	local numeric = tonumber(cleaned)
	if numeric and numeric > 0 then
		local userId = math.floor(numeric)
		return userId, resolveDisplayNameForUserId(userId), nil
	end

	local lowered = string.lower(cleaned)
	for _, online in ipairs(Players:GetPlayers()) do
		if string.lower(online.Name) == lowered or string.lower(online.DisplayName) == lowered then
			return online.UserId, online.Name, nil
		end
	end

	local partialMatch = nil
	for _, online in ipairs(Players:GetPlayers()) do
		if startsWith(string.lower(online.Name), lowered) or startsWith(string.lower(online.DisplayName), lowered) then
			if partialMatch then
				partialMatch = false
				break
			end
			partialMatch = online
		end
	end
	if partialMatch and partialMatch ~= false then
		return partialMatch.UserId, partialMatch.Name, nil
	end

	local idOk, resolvedUserId = pcall(function()
		return Players:GetUserIdFromNameAsync(cleaned)
	end)
	if idOk and resolvedUserId then
		return resolvedUserId, resolveDisplayNameForUserId(resolvedUserId), nil
	end

	return nil, nil, "Player not found"
end

local function fetchSnapshot(targetUserId, targetLabel)
	if busy then
		return
	end
	busy = true
	status.Text = "Loading telemetry snapshot..."

	local remote = getSnapshotRemote()
	if not remote then
		content.Text = "TelemetryGetSnapshot remote is missing."
		status.Text = "Unavailable"
		busy = false
		return
	end

	local ok, result = pcall(function()
		return remote:InvokeServer(targetUserId)
	end)

	if not ok then
		content.Text = "Snapshot request failed: " .. tostring(result)
		status.Text = "Request failed"
		busy = false
		return
	end

	if type(result) ~= "table" then
		content.Text = "Unexpected snapshot response type."
		status.Text = "Bad response"
		busy = false
		return
	end

	if result.Success ~= true then
		content.Text = formatPayload(result)
		status.Text = "Telemetry service returned an error"
		busy = false
		return
	end

	local snapshot = result.Snapshot or result
	currentSnapshot = snapshot
	currentModel = buildModelFromSnapshot(snapshot)
	currentTargetUserId = tonumber(snapshot.UserId) or tonumber(targetUserId) or player.UserId
	currentTargetLabel = tostring(snapshot.Username or targetLabel or currentTargetUserId)
	targetBox.Text = currentTargetLabel

	renderCurrentView()
	status.Text = "Updated at " .. os.date("%X")
	busy = false
end

local function loadTargetFromInput()
	local targetUserId, targetName, err = resolveTargetUser(targetBox.Text)
	if not targetUserId then
		status.Text = tostring(err or "Unable to resolve player")
		return
	end
	fetchSnapshot(targetUserId, targetName)
end

local function openPanel()
	setOpen(true)
	fetchSnapshot(currentTargetUserId, currentTargetLabel)
end

local function togglePanel()
	if screen.Enabled then
		setOpen(false)
	else
		openPanel()
	end
end

local function bindChatCommand()
	local commandsFolder = TextChatService:FindFirstChild("TextChatCommands")
	if not commandsFolder then
		commandsFolder = Instance.new("Folder")
		commandsFolder.Name = "TextChatCommands"
		commandsFolder.Parent = TextChatService
	end

	local command = commandsFolder:FindFirstChild(CHAT_COMMAND_NAME)
	if command and not command:IsA("TextChatCommand") then
		command:Destroy()
		command = nil
	end

	if not command then
		command = Instance.new("TextChatCommand")
		command.Name = CHAT_COMMAND_NAME
		command.PrimaryAlias = CHAT_ALIAS
		command.Parent = commandsFolder
	end

	command.Triggered:Connect(function()
		openPanel()
	end)

	player.Chatted:Connect(function(message)
		if lowerTrim(message) == CHAT_ALIAS then
			openPanel()
		end
	end)
end

refreshButton.Activated:Connect(function()
	fetchSnapshot(currentTargetUserId, currentTargetLabel)
end)

loadButton.Activated:Connect(loadTargetFromInput)

selfButton.Activated:Connect(function()
	targetBox.Text = player.Name
	fetchSnapshot(player.UserId, player.Name)
end)

closeButton.Activated:Connect(function()
	setOpen(false)
end)

targetBox.FocusLost:Connect(function(enterPressed)
	if enterPressed then
		loadTargetFromInput()
	end
end)

searchBox:GetPropertyChangedSignal("Text"):Connect(function()
	if screen.Enabled then
		renderCurrentView()
	end
end)

filterBox:GetPropertyChangedSignal("Text"):Connect(function()
	if screen.Enabled then
		renderCurrentView()
	end
end)

bindChatCommand()
setActiveTab("Overview")

UserInputService.InputBegan:Connect(function(input, gameProcessed)
	if gameProcessed then
		return
	end
	if input.KeyCode ~= TOGGLE_KEY then
		return
	end

	local ctrlDown = UserInputService:IsKeyDown(Enum.KeyCode.LeftControl) or UserInputService:IsKeyDown(Enum.KeyCode.RightControl)
	if not ctrlDown then
		return
	end

	togglePanel()
end)
