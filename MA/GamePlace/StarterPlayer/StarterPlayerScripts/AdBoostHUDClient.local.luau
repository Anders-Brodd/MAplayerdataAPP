--[=[ PATH: StarterPlayerScripts/AdBoostHUDClient | TYPE: LocalScript ]=]--
--[[
	Ad Boost HUD — bottom-corner pill indicators for active Money and Research boosts.
	Each pill shows the boost icon/label and counts down the remaining time.
	Hover (desktop) or tap (mobile) expands a tooltip showing time left and how
	much extra income/RP the boost has earned so far this session.

	Tracks earnings by watching:
	  - MoneyUpdate  RemoteEvent (fires new absolute balance)
	  - ResearchUpdate RemoteEvent (fires a snapshot table with .RP)
	  - Player attributes AdMoneyBoostActive / AdResearchBoostActive (source of truth)
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")

local Player = Players.LocalPlayer
local PlayerGui = Player:WaitForChild("PlayerGui")
local Events = ReplicatedStorage:WaitForChild("Events")
local AdBoostResult = Events:WaitForChild("AdBoostResult")
local MoneyUpdate = Events:WaitForChild("MoneyUpdate", 30)
local ResearchUpdate = Events:FindFirstChild("ResearchUpdate") or Events:WaitForChild("ResearchUpdate", 30)

-- ── THEME ──
local THEME = {
	PillBg        = Color3.fromRGB(17, 19, 24),
	PillBorder    = Color3.fromRGB(42, 48, 60),
	MoneyColor    = Color3.fromRGB(90, 210, 120),
	ResearchColor = Color3.fromRGB(100, 160, 255),
	TooltipBg     = Color3.fromRGB(13, 15, 20),
	TextPrimary   = Color3.fromRGB(240, 240, 240),
	TextSub       = Color3.fromRGB(150, 155, 168),
	ExpiringColor = Color3.fromRGB(255, 180, 60),
	Font          = Enum.Font.GothamBold,
	FontSub       = Enum.Font.Gotham,
}

local PILL_HEIGHT   = 36
local PILL_PADDING  = 8   -- gap between pills
local EDGE_MARGIN   = 14  -- margin from screen edge
local TWEEN_OPEN    = TweenInfo.new(0.25, Enum.EasingStyle.Quart, Enum.EasingDirection.Out)
local TWEEN_CLOSE   = TweenInfo.new(0.18, Enum.EasingStyle.Quad,  Enum.EasingDirection.In)
local TOOLTIP_SHOW  = TweenInfo.new(0.15, Enum.EasingStyle.Quad,  Enum.EasingDirection.Out)

-- ── STATE ──
-- Money reward is now a flat instant grant — no "active boost" period to display.
-- Only the Research (RP) 2× boost gets a pill in this HUD.
local boostState = {
	Research = { active = false, endTime = 0, extraEarned = 0, prevRP = nil },
}
local pills = {}       -- [boostType] = pill Frame
local tooltipOpen = {} -- [boostType] = bool

-- ── ROOT GUI ──
local screenGui = Instance.new("ScreenGui")
screenGui.Name = "AdBoostHUD"
screenGui.DisplayOrder = 12
screenGui.ResetOnSpawn = false
screenGui.IgnoreGuiInset = false
screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
screenGui.Parent = PlayerGui

-- Container anchored to bottom-right
local container = Instance.new("Frame")
container.Name = "BoostContainer"
container.AnchorPoint = Vector2.new(1, 1)
container.Position = UDim2.new(1, -EDGE_MARGIN, 1, -EDGE_MARGIN)
container.Size = UDim2.new(0, 200, 0, 0)   -- height auto from list layout
container.AutomaticSize = Enum.AutomaticSize.Y
container.BackgroundTransparency = 1
container.ZIndex = 10
container.Parent = screenGui

local containerLayout = Instance.new("UIListLayout")
containerLayout.FillDirection = Enum.FillDirection.Vertical
containerLayout.HorizontalAlignment = Enum.HorizontalAlignment.Right
containerLayout.VerticalAlignment = Enum.VerticalAlignment.Bottom
containerLayout.SortOrder = Enum.SortOrder.LayoutOrder
containerLayout.Padding = UDim.new(0, PILL_PADDING)
containerLayout.Parent = container

-- ── HELPERS ──
local function formatTime(seconds)
	local s = math.max(0, math.floor(seconds))
	return string.format("%d:%02d", math.floor(s / 60), s % 60)
end

local function formatMoney(amount)
	if amount >= 1e6 then
		return string.format("$%.1fM", amount / 1e6)
	elseif amount >= 1e3 then
		return string.format("$%.1fK", amount / 1e3)
	else
		return string.format("$%d", math.floor(amount))
	end
end

local function formatRP(amount)
	if amount >= 1000 then
		return string.format("%.1fK RP", amount / 1000)
	else
		return string.format("%d RP", math.floor(amount))
	end
end

-- ── PILL BUILDER ──
local function buildPill(boostType)
	local isMoney = boostType == "Money"
	local accentColor = isMoney and THEME.MoneyColor or THEME.ResearchColor
	local icon = isMoney and "💰" or "🔬"
	local layoutOrder = isMoney and 2 or 1   -- Research above Money

	local pill = Instance.new("Frame")
	pill.Name = "BoostPill_" .. boostType
	pill.Size = UDim2.new(1, 0, 0, PILL_HEIGHT)
	pill.BackgroundColor3 = THEME.PillBg
	pill.BackgroundTransparency = 0.1
	pill.BorderSizePixel = 0
	pill.LayoutOrder = layoutOrder
	pill.ClipsDescendants = false
	pill.Visible = false
	pill.ZIndex = 10
	Instance.new("UICorner", pill).CornerRadius = UDim.new(0, 10)
	local stroke = Instance.new("UIStroke")
	stroke.Color = THEME.PillBorder
	stroke.Thickness = 1
	stroke.Transparency = 0.3
	stroke.Parent = pill

	-- Accent left bar
	local bar = Instance.new("Frame")
	bar.Name = "AccentBar"
	bar.Size = UDim2.new(0, 3, 1, -8)
	bar.Position = UDim2.fromOffset(5, 4)
	bar.BackgroundColor3 = accentColor
	bar.BorderSizePixel = 0
	bar.ZIndex = 11
	Instance.new("UICorner", bar).CornerRadius = UDim.new(0, 2)
	bar.Parent = pill

	-- Icon
	local iconLbl = Instance.new("TextLabel")
	iconLbl.Name = "Icon"
	iconLbl.Size = UDim2.fromOffset(26, PILL_HEIGHT)
	iconLbl.Position = UDim2.fromOffset(12, 0)
	iconLbl.BackgroundTransparency = 1
	iconLbl.Text = icon
	iconLbl.TextSize = 18
	iconLbl.Font = Enum.Font.GothamBold
	iconLbl.TextColor3 = accentColor
	iconLbl.TextXAlignment = Enum.TextXAlignment.Left
	iconLbl.ZIndex = 11
	iconLbl.Parent = pill

	-- "2x" badge
	local badge = Instance.new("TextLabel")
	badge.Name = "Badge"
	badge.Size = UDim2.fromOffset(28, 16)
	badge.Position = UDim2.fromOffset(36, (PILL_HEIGHT - 16) / 2)
	badge.BackgroundColor3 = accentColor
	badge.BackgroundTransparency = 0
	badge.Text = "2×"
	badge.TextSize = 11
	badge.Font = Enum.Font.GothamBlack
	badge.TextColor3 = Color3.fromRGB(0, 0, 0)
	badge.ZIndex = 11
	Instance.new("UICorner", badge).CornerRadius = UDim.new(0, 4)
	badge.Parent = pill

	-- Timer label
	local timerLbl = Instance.new("TextLabel")
	timerLbl.Name = "Timer"
	timerLbl.Size = UDim2.new(1, -72, 1, 0)
	timerLbl.Position = UDim2.fromOffset(68, 0)
	timerLbl.BackgroundTransparency = 1
	timerLbl.Text = "5:00"
	timerLbl.TextSize = 14
	timerLbl.Font = THEME.Font
	timerLbl.TextColor3 = THEME.TextPrimary
	timerLbl.TextXAlignment = Enum.TextXAlignment.Left
	timerLbl.ZIndex = 11
	timerLbl.Parent = pill

	-- ── TOOLTIP (child of pill so it stays anchored) ──
	local tooltip = Instance.new("Frame")
	tooltip.Name = "Tooltip"
	tooltip.AnchorPoint = Vector2.new(1, 1)
	tooltip.Position = UDim2.new(1, 0, 0, -6)
	tooltip.Size = UDim2.fromOffset(210, 72)
	tooltip.BackgroundColor3 = THEME.TooltipBg
	tooltip.BackgroundTransparency = 0.08
	tooltip.BorderSizePixel = 0
	tooltip.ZIndex = 20
	tooltip.Visible = false
	Instance.new("UICorner", tooltip).CornerRadius = UDim.new(0, 10)
	local tooltipStroke = Instance.new("UIStroke")
	tooltipStroke.Color = accentColor
	tooltipStroke.Thickness = 1
	tooltipStroke.Transparency = 0.5
	tooltipStroke.Parent = tooltip

	local ttPad = Instance.new("UIPadding")
	ttPad.PaddingLeft   = UDim.new(0, 10)
	ttPad.PaddingRight  = UDim.new(0, 10)
	ttPad.PaddingTop    = UDim.new(0, 8)
	ttPad.PaddingBottom = UDim.new(0, 8)
	ttPad.Parent = tooltip

	local ttLayout = Instance.new("UIListLayout")
	ttLayout.FillDirection = Enum.FillDirection.Vertical
	ttLayout.Padding = UDim.new(0, 4)
	ttLayout.SortOrder = Enum.SortOrder.LayoutOrder
	ttLayout.Parent = tooltip

	local ttTitle = Instance.new("TextLabel")
	ttTitle.Name = "Title"
	ttTitle.Size = UDim2.new(1, 0, 0, 18)
	ttTitle.BackgroundTransparency = 1
	ttTitle.Text = isMoney and "💰 2× MONEY BOOST" or "🔬 2× RESEARCH BOOST"
	ttTitle.TextSize = 13
	ttTitle.Font = Enum.Font.GothamBlack
	ttTitle.TextColor3 = accentColor
	ttTitle.TextXAlignment = Enum.TextXAlignment.Left
	ttTitle.LayoutOrder = 1
	ttTitle.Parent = tooltip

	local ttTime = Instance.new("TextLabel")
	ttTime.Name = "TimeLeft"
	ttTime.Size = UDim2.new(1, 0, 0, 16)
	ttTime.BackgroundTransparency = 1
	ttTime.Text = "Time left: 5:00"
	ttTime.TextSize = 12
	ttTime.Font = THEME.FontSub
	ttTime.TextColor3 = THEME.TextSub
	ttTime.TextXAlignment = Enum.TextXAlignment.Left
	ttTime.LayoutOrder = 2
	ttTime.Parent = tooltip

	local ttEarned = Instance.new("TextLabel")
	ttEarned.Name = "Earned"
	ttEarned.Size = UDim2.new(1, 0, 0, 16)
	ttEarned.BackgroundTransparency = 1
	ttEarned.Text = isMoney and "Bonus earned: $0" or "Bonus RP earned: 0 RP"
	ttEarned.TextSize = 12
	ttEarned.Font = THEME.FontSub
	ttEarned.TextColor3 = THEME.MoneyColor
	ttEarned.TextXAlignment = Enum.TextXAlignment.Left
	ttEarned.LayoutOrder = 3
	ttEarned.Parent = tooltip

	tooltip.Parent = pill

	-- Resize tooltip to fit content
	tooltip.AutomaticSize = Enum.AutomaticSize.Y

	pill.Parent = container
	return pill
end

-- ── SHOW / HIDE PILL ──
local function showPill(boostType)
	local pill = pills[boostType]
	if not pill then return end
	pill.Visible = true
	pill.BackgroundTransparency = 1
	TweenService:Create(pill, TWEEN_OPEN, { BackgroundTransparency = 0.1 }):Play()
end

local function hidePill(boostType)
	local pill = pills[boostType]
	if not pill then return end
	tooltipOpen[boostType] = false
	local tooltip = pill:FindFirstChild("Tooltip")
	if tooltip then tooltip.Visible = false end
	local t = TweenService:Create(pill, TWEEN_CLOSE, { BackgroundTransparency = 1 })
	t:Play()
	t.Completed:Once(function()
		if not boostState[boostType].active then
			pill.Visible = false
		end
	end)
end

-- ── TOOLTIP OPEN / CLOSE ──
local function openTooltip(boostType)
	local pill = pills[boostType]
	if not pill then return end
	local tooltip = pill:FindFirstChild("Tooltip")
	if not tooltip then return end
	tooltipOpen[boostType] = true
	tooltip.BackgroundTransparency = 1
	tooltip.Visible = true
	TweenService:Create(tooltip, TOOLTIP_SHOW, { BackgroundTransparency = 0.08 }):Play()
end

local function closeTooltip(boostType)
	local pill = pills[boostType]
	if not pill then return end
	local tooltip = pill:FindFirstChild("Tooltip")
	if not tooltip then return end
	tooltipOpen[boostType] = false
	local t = TweenService:Create(tooltip, TOOLTIP_SHOW, { BackgroundTransparency = 1 })
	t:Play()
	t.Completed:Once(function()
		if not tooltipOpen[boostType] then
			tooltip.Visible = false
		end
	end)
end

-- ── BUILD PILLS ──
-- Money boost is now instant — only the Research pill is needed.
pills["Research"] = buildPill("Research")

-- ── INPUT WIRING (hover + tap) ──
local isTouchDevice = UserInputService.TouchEnabled

for _, boostType in ipairs({ "Research" }) do
	local pill = pills[boostType]

	if isTouchDevice then
		-- Tap toggles tooltip on mobile
		pill.InputBegan:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.Touch then
				if tooltipOpen[boostType] then
					closeTooltip(boostType)
				else
					openTooltip(boostType)
				end
			end
		end)
	else
		-- Hover on desktop
		pill.MouseEnter:Connect(function()
			openTooltip(boostType)
		end)
		pill.MouseLeave:Connect(function()
			closeTooltip(boostType)
		end)
	end
end

-- ── BOOST ACTIVATION ──
local function activateBoost(boostType, endTime)
	local state = boostState[boostType]
	if not state then return end
	state.active = true
	state.endTime = endTime
	state.extraEarned = 0
	state.prevRP = nil   -- seed on first ResearchUpdate
	showPill(boostType)
end

local function deactivateBoost(boostType)
	local state = boostState[boostType]
	if not state then return end
	state.active = false
	hidePill(boostType)
end

-- ── TICK: update timers + tooltip content ──
local EXPIRING_THRESHOLD = 30 -- seconds

RunService.Heartbeat:Connect(function()
	for _, boostType in ipairs({ "Research" }) do
		local state = boostState[boostType]
		if not state.active then continue end

		local pill    = pills[boostType]
		local timer   = pill:FindFirstChild("Timer")
		local tooltip = pill:FindFirstChild("Tooltip")
		local ttTime  = tooltip and tooltip:FindFirstChild("TimeLeft")
		local ttEarned = tooltip and tooltip:FindFirstChild("Earned")

		local remaining = state.endTime - os.time()
		if remaining <= 0 then
			-- server attribute change will deactivate; degrade gracefully
			if timer then timer.Text = "0:00" end
			deactivateBoost(boostType)
			continue
		end

		local timeStr = formatTime(remaining)
		if timer then
			timer.Text = timeStr
			timer.TextColor3 = remaining <= EXPIRING_THRESHOLD and THEME.ExpiringColor or THEME.TextPrimary
		end

		if ttTime  then ttTime.Text  = "Time left: " .. timeStr end
		if ttEarned then
			if boostType == "Research" then
				ttEarned.Text = "Bonus RP: " .. formatRP(state.extraEarned)
			end
		end
	end
end)

-- ── RP INCOME TRACKING ──
-- Watch RP balance changes while research boost is active.
-- Since the boost is exactly 2×, the extra earned equals half the observed gain.
if ResearchUpdate then
	ResearchUpdate.OnClientEvent:Connect(function(snapshot)
		local state = boostState["Research"]
		local newRP = snapshot and tonumber(snapshot.RP)
		if newRP == nil then return end
		if not state.active then
			state.prevRP = newRP
			return
		end
		local prev = state.prevRP
		if prev ~= nil and newRP > prev then
			local delta = newRP - prev
			state.extraEarned = state.extraEarned + (delta / 2)
		end
		state.prevRP = newRP
	end)
end

-- ── LISTEN FOR BOOST EVENTS ──
-- Primary trigger: server fires AdBoostResult when Research boost is granted.
-- (Money is now an instant flat reward — no pill needed.)
AdBoostResult.OnClientEvent:Connect(function(boostType, success, endTime)
	if boostType ~= "Research" then return end
	if not success then return end
	activateBoost("Research", endTime)
end)

-- Secondary trigger: player attributes changed (handles reconnect / rejoin)
-- If the player already has a Research boost active when this script loads, show the pill.
local function syncFromAttributes()
	local researchEnd = tonumber(Player:GetAttribute("AdResearchBoostEndTime"))
	if researchEnd and os.time() < researchEnd and not boostState["Research"].active then
		activateBoost("Research", researchEnd)
	end
end

-- Attribute monitors for server-side expiry
Player:GetAttributeChangedSignal("AdResearchBoostActive"):Connect(function()
	local active = Player:GetAttribute("AdResearchBoostActive") == true
	if not active and boostState["Research"].active then
		deactivateBoost("Research")
	end
end)

-- Run sync on load (handles rejoining mid-boost)
task.defer(syncFromAttributes)

print("[AdBoostHUD] Loaded — Research boost pill ready.")
