local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local Player = Players.LocalPlayer
local PlayerGui = Player:WaitForChild("PlayerGui")
local MainHUD = PlayerGui:WaitForChild("MainHUD")
if MainHUD:FindFirstChild("Rating") then
	script.Disabled = true
	return
end
local RatingFrame = MainHUD:WaitForChild("RatingFrame")
local Header = RatingFrame:WaitForChild("Header")
local Body = RatingFrame:WaitForChild("Body")
local CloseButton = Header:WaitForChild("CloseButton")
local Top = MainHUD:WaitForChild("Top")
local TopBar = Top:WaitForChild("TopBar")
local RatingButton = TopBar:WaitForChild("Rating")
local Events = ReplicatedStorage:WaitForChild("Events")
local RatingUpdate = Events:WaitForChild("RatingUpdate")
local RatingSummaryRequest = Events:WaitForChild("RatingSummaryRequest")

local OPEN_POSITION = UDim2.new(0.5, 0, 0.5, 0)
local CLOSED_POSITION = UDim2.new(0.5, 0, 1.55, 0)
local OPEN_TWEEN = TweenInfo.new(0.28, Enum.EasingStyle.Quart, Enum.EasingDirection.Out)
local CLOSE_TWEEN = TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.In)

local ClosePanels = Events:FindFirstChild("ClosePanels")
if not ClosePanels then
	ClosePanels = Instance.new("BindableEvent")
	ClosePanels.Name = "ClosePanels"
	ClosePanels.Parent = Events
end

local THEME = {
	Panel = Color3.fromRGB(24, 27, 33),
	PanelEdge = Color3.fromRGB(66, 78, 98),
	HeaderA = Color3.fromRGB(38, 45, 59),
	HeaderB = Color3.fromRGB(22, 27, 37),
	Card = Color3.fromRGB(28, 32, 40),
	CardAlt = Color3.fromRGB(22, 26, 34),
	Tab = Color3.fromRGB(26, 30, 38),
	TabActive = Color3.fromRGB(44, 61, 88),
	Ink = Color3.fromRGB(238, 243, 252),
	Muter = Color3.fromRGB(160, 172, 193),
	Blue = Color3.fromRGB(120, 182, 255),
	Cyan = Color3.fromRGB(105, 206, 232),
	Gold = Color3.fromRGB(242, 202, 112),
	Green = Color3.fromRGB(102, 202, 146),
	Orange = Color3.fromRGB(235, 166, 102),
	Red = Color3.fromRGB(225, 115, 115),
}

local TABS = {
	{ Key = "Overview", Label = "Overview" },
	{ Key = "Reviews", Label = "Reviews" },
	{ Key = "Guests", Label = "Guests" },
}

local REVIEW_NAMES = {
	"Avery S.",
	"Logan P.",
	"Mia R.",
	"Noah K.",
	"Sage M.",
	"Levi T.",
	"Aria H.",
	"Mason W.",
}

local ui = {
	Built = false,
	IsOpen = false,
	ActiveTween = nil,
	CurrentTab = "Overview",
	LastSummary = nil,
	Scroll = nil,
	Content = nil,
	TabBar = nil,
	TabButtons = {},
	ReviewCount = nil,
	HeaderStars = nil,
	HeaderRating = nil,
	RefreshLoopStarted = false,
}

local function bindGuiButton(button, callback)
	if not (button and callback) then return end
	button.Active = true
	button.Selectable = true
	local lastFire = 0
	local function fire()
		local now = os.clock()
		if now - lastFire < 0.2 then return end
		lastFire = now
		callback()
	end
	if button:IsA("GuiButton") then
		button.Activated:Connect(fire)
	else
		button.InputBegan:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
				fire()
			end
		end)
	end
end

local function getViewportSize()
	local camera = Workspace.CurrentCamera
	if camera and camera.ViewportSize.X > 0 and camera.ViewportSize.Y > 0 then
		return camera.ViewportSize
	end
	return Vector2.new(1920, 1080)
end

local function formatPercent(value)
	return string.format("%d%%", math.floor((math.clamp(tonumber(value) or 0, 0, 1) * 100) + 0.5))
end

local function formatRating(value)
	return string.format("%.1f", math.clamp(tonumber(value) or 0, 0, 5))
end

local function starString(value)
	local rating = math.clamp(tonumber(value) or 0, 0, 5)
	local full = math.floor(rating + 0.001)
	local empty = math.max(0, 5 - full)
	return string.rep("★", full) .. string.rep("☆", empty)
end

local function isOwnedByLocalPlayer(model)
	if not model then return false end
	local ownerAttr = model:GetAttribute("Owner")
	local ownerNum = tonumber(ownerAttr)
	if ownerNum ~= nil then
		return ownerNum == Player.UserId
	end
	return ownerAttr == nil
end

local function isPlacedObjectRootModel(model, placed)
	if not (model and model:IsA("Model") and placed) then
		return false
	end
	local parent = model.Parent
	while parent and parent ~= placed do
		if parent:IsA("Model") and (
			parent:GetAttribute("UUID") ~= nil
			or parent:GetAttribute("Type") ~= nil
			or parent:GetAttribute("Category") ~= nil
		) then
			return false
		end
		parent = parent.Parent
	end
	return parent == placed
end

local function computeLocalResortActivity()
	local activity = {
		BuiltLifts = 0,
		RunningLifts = 0,
		Food = 0,
		Lodging = 0,
	}
	local placed = Workspace:FindFirstChild("PlacedObjects")
	if not placed then
		return activity
	end
	for _, obj in ipairs(placed:GetDescendants()) do
		if obj:IsA("Model") and isPlacedObjectRootModel(obj, placed) and isOwnedByLocalPlayer(obj) then
			local lowerName = string.lower(obj.Name)
			local objType = string.lower(tostring(obj:GetAttribute("Type") or ""))
			local objCategory = string.lower(tostring(obj:GetAttribute("Category") or ""))
			local status = string.lower(tostring(obj:GetAttribute("Status") or ""))
			local targetSpeed = tonumber(obj:GetAttribute("TargetSpeed")) or 0
			local isLift = objType:find("lift", 1, true) or objType:find("twopoint", 1, true) or objType:find("carpet", 1, true)
				or lowerName:find("lift", 1, true) or lowerName:find("chair", 1, true) or lowerName:find("gondola", 1, true)
				or lowerName:find("tram", 1, true) or lowerName:find("tow", 1, true)
			local isFood = objType:find("food", 1, true) or objType:find("restaurant", 1, true) or objType:find("cafe", 1, true)
				or objCategory:find("food", 1, true) or objCategory:find("restaurant", 1, true) or objCategory:find("cafe", 1, true)
				or lowerName:find("food", 1, true) or lowerName:find("restaurant", 1, true) or lowerName:find("cafe", 1, true)
			local isLodging = objType:find("house", 1, true) or objType:find("hotel", 1, true) or objType:find("lodging", 1, true)
				or objCategory:find("house", 1, true) or objCategory:find("hotel", 1, true) or objCategory:find("housing", 1, true)
				or objCategory:find("accommodation", 1, true) or objCategory:find("lodging", 1, true)
				or lowerName:find("hotel", 1, true) or lowerName:find("house", 1, true) or lowerName:find("lodge", 1, true) or lowerName:find("cabin", 1, true)
			if isLift then
				activity.BuiltLifts += 1
				if status == "running" or targetSpeed > 0.05 then
					activity.RunningLifts += 1
				end
			elseif isFood then
				activity.Food += 1
			elseif isLodging then
				activity.Lodging += 1
			end
		end
	end
	return activity
end

local function applyIdleResortClamp(info)
	local activity = computeLocalResortActivity()
	local totalGuests = math.max(0, tonumber(info.Stats and info.Stats.TotalGuests) or 0)
	local amenityCount = activity.BuiltLifts + activity.Food + activity.Lodging

	if totalGuests <= 0 then
		info.ReviewCount = 0
		info.PositiveShare = 0
		info.ReviewLabel = amenityCount > 0 and "Awaiting guest feedback" or "Resort not operating"
		if amenityCount <= 0 then
			info.Rating = 0
		elseif activity.RunningLifts <= 0 then
			local idleCap = math.min(3.25, 1.45 + (math.min(amenityCount, 6) * 0.32))
			info.Rating = math.min(info.Rating, idleCap)
		else
			local waitingCap = math.min(4.35, 2.65 + (math.min(activity.RunningLifts, 4) * 0.28) + (math.min(activity.Food + activity.Lodging, 5) * 0.12))
			info.Rating = math.min(info.Rating, waitingCap)
		end
	end

	return info
end

local function normalizeSummary(summary)
	local stats = type(summary) == "table" and type(summary.Stats) == "table" and summary.Stats or {}
	local amenities = type(summary) == "table" and type(summary.Amenities) == "table" and summary.Amenities or {}
	local reviews = type(summary) == "table" and type(summary.Reviews) == "table" and summary.Reviews or {}
	local info = {
		Rating = math.clamp(tonumber(summary and summary.Rating) or 0, 0, 5),
		HappyRatio = math.clamp(tonumber(summary and summary.HappyRatio) or 0, 0, 1),
		HungryRatio = math.clamp(tonumber(summary and summary.HungryRatio) or 0, 0, 1),
		ReviewLabel = tostring(summary and summary.ReviewLabel or "Resort Rating"),
		ReviewCount = math.max(0, tonumber(summary and summary.ReviewCount) or 0),
		PositiveShare = math.clamp(tonumber(summary and summary.PositiveShare) or 0, 0, 1),
		RefreshEpoch = math.max(0, tonumber(summary and summary.RefreshEpoch) or 0),
		Reviews = reviews,
		Stats = {
			TotalGuests = math.max(0, tonumber(stats.TotalGuests) or 0),
			HappyGuests = math.max(0, tonumber(stats.HappyGuests) or 0),
			HungryGuests = math.max(0, tonumber(stats.HungryGuests) or 0),
		},
		Amenities = {
			Lifts = math.max(0, tonumber(amenities.Lifts) or 0),
			Food = math.max(0, tonumber(amenities.Food) or 0),
			Lodging = math.max(0, tonumber(amenities.Lodging) or 0),
		},
	}
	return applyIdleResortClamp(info)
end

local function getReviewCount(info)
	if (info.ReviewCount or 0) > 0 then
		return info.ReviewCount
	end
	local totalGuests = info.Stats.TotalGuests
	if totalGuests > 0 then
		return math.max(6, math.floor(totalGuests * 0.68 + 0.5))
	end
	return 0
end

local function getPositiveShare(info)
	if (info.PositiveShare or 0) > 0 then
		return info.PositiveShare
	end
	if (info.Stats.TotalGuests or 0) <= 0 and (info.ReviewCount or 0) <= 0 then
		return 0
	end
	local score = (info.HappyRatio * 0.8) + ((1 - info.HungryRatio) * 0.2)
	return math.clamp(score, 0, 1)
end

local function resolveReviewAccent(review)
	local rgb = review and review.AccentRGB
	if type(rgb) == "table" then
		return Color3.fromRGB(math.clamp(tonumber(rgb.R) or 92, 0, 255), math.clamp(tonumber(rgb.G) or 180, 0, 255), math.clamp(tonumber(rgb.B) or 255, 0, 255))
	end
	return review and review.Accent or THEME.Blue
end

local function makeText(parent, props)
	local label = Instance.new(props.ClassName or "TextLabel")
	label.BackgroundTransparency = 1
	label.BorderSizePixel = 0
	label.TextColor3 = props.TextColor3 or THEME.Ink
	label.Font = props.Font or Enum.Font.Gotham
	label.TextSize = props.TextSize or 14
	label.TextWrapped = props.TextWrapped == true
	label.TextTruncate = props.TextTruncate or Enum.TextTruncate.None
	label.TextXAlignment = props.TextXAlignment or Enum.TextXAlignment.Left
	label.TextYAlignment = props.TextYAlignment or Enum.TextYAlignment.Center
	label.Size = props.Size or UDim2.new(1, 0, 0, props.Height or 18)
	label.Position = props.Position or UDim2.new()
	label.AutomaticSize = props.AutomaticSize or Enum.AutomaticSize.None
	label.Text = props.Text or ""
	label.RichText = props.RichText == true
	label.Name = props.Name or label.Name
	label.Parent = parent
	return label
end

local function makeFrame(parent, name, bg, height)
	local frame = Instance.new("Frame")
	frame.Name = name
	frame.BackgroundColor3 = bg or THEME.Card
	frame.BackgroundTransparency = 0.02
	frame.BorderSizePixel = 0
	frame.Size = UDim2.new(1, 0, 0, height or 96)
	frame.Parent = parent
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 14)
	corner.Parent = frame
	local gradient = Instance.new("UIGradient")
	gradient.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, bg or THEME.Card),
		ColorSequenceKeypoint.new(1, THEME.CardAlt),
	})
	gradient.Rotation = 90
	gradient.Parent = frame
	local stroke = Instance.new("UIStroke")
	stroke.Color = THEME.PanelEdge
	stroke.Transparency = 0.28
	stroke.Parent = frame
	return frame
end

local function clearContent()
	if not ui.Content then return end
	for _, child in ipairs(ui.Content:GetChildren()) do
		if not child:IsA("UIListLayout") and not child:IsA("UIPadding") then
			child:Destroy()
		end
	end
end

local function createMetricChip(parent, title, value, accent)
	local chip = makeFrame(parent, title .. "Chip", THEME.CardAlt, 66)
	chip.Size = UDim2.new(0.5, -6, 0, 66)
	local accentLine = Instance.new("Frame")
	accentLine.BackgroundColor3 = accent
	accentLine.BorderSizePixel = 0
	accentLine.Size = UDim2.new(0, 54, 0, 3)
	accentLine.Position = UDim2.fromOffset(16, 12)
	accentLine.Parent = chip
	local accentCorner = Instance.new("UICorner")
	accentCorner.CornerRadius = UDim.new(1, 0)
	accentCorner.Parent = accentLine
	makeText(chip, {
		Name = "Title",
		Text = title,
		Position = UDim2.fromOffset(16, 20),
		Size = UDim2.new(1, -32, 0, 16),
		TextSize = 12,
		Font = Enum.Font.GothamMedium,
		TextColor3 = THEME.Muter,
	})
	makeText(chip, {
		Name = "Value",
		Text = value,
		Position = UDim2.fromOffset(16, 36),
		Size = UDim2.new(1, -32, 0, 22),
		TextSize = 18,
		Font = Enum.Font.GothamBold,
		TextColor3 = accent,
	})
	return chip
end

local function createBarCard(parent, title, value, detail, fillColor)
	local card = makeFrame(parent, title .. "Card", THEME.Card, 84)
	makeText(card, {
		Text = title,
		Position = UDim2.fromOffset(16, 12),
		Size = UDim2.new(1, -32, 0, 18),
		TextSize = 13,
		Font = Enum.Font.GothamBold,
	})
	makeText(card, {
		Text = value,
		Position = UDim2.new(1, -100, 0, 12),
		Size = UDim2.fromOffset(84, 18),
		TextSize = 13,
		Font = Enum.Font.GothamBold,
		TextXAlignment = Enum.TextXAlignment.Right,
		TextColor3 = fillColor,
	})
	local track = Instance.new("Frame")
	track.BackgroundColor3 = Color3.fromRGB(29, 36, 48)
	track.BorderSizePixel = 0
	track.Position = UDim2.fromOffset(16, 38)
	track.Size = UDim2.new(1, -32, 0, 10)
	track.Parent = card
	local trackCorner = Instance.new("UICorner")
	trackCorner.CornerRadius = UDim.new(1, 0)
	trackCorner.Parent = track
	local fill = Instance.new("Frame")
	fill.BackgroundColor3 = fillColor
	fill.BorderSizePixel = 0
	fill.Size = UDim2.new(math.clamp(detail.Fill or 0, 0, 1), 0, 1, 0)
	fill.Parent = track
	local fillCorner = Instance.new("UICorner")
	fillCorner.CornerRadius = UDim.new(1, 0)
	fillCorner.Parent = fill
	makeText(card, {
		Text = detail.Text,
		Position = UDim2.fromOffset(16, 54),
		Size = UDim2.new(1, -32, 0, 16),
		TextSize = 12,
		Font = Enum.Font.Gotham,
		TextColor3 = THEME.Muter,
	})
	return card
end

local function createReviewCard(parent, review, index)
	local card = makeFrame(parent, "ReviewCard" .. index, (index % 2 == 0) and THEME.CardAlt or THEME.Card, 144)
	local accent = resolveReviewAccent(review)
	local avatar = Instance.new("Frame")
	avatar.BackgroundColor3 = Color3.fromRGB(31, 37, 47)
	avatar.BorderSizePixel = 0
	avatar.Size = UDim2.fromOffset(42, 42)
	avatar.Position = UDim2.fromOffset(16, 16)
	avatar.Parent = card
	local avatarCorner = Instance.new("UICorner")
	avatarCorner.CornerRadius = UDim.new(1, 0)
	avatarCorner.Parent = avatar
	local avatarStroke = Instance.new("UIStroke")
	avatarStroke.Color = accent
	avatarStroke.Transparency = 0.12
	avatarStroke.Parent = avatar
	makeText(avatar, {
		Text = string.sub(review.Name, 1, 1),
		Size = UDim2.fromScale(1, 1),
		TextSize = 18,
		Font = Enum.Font.GothamBlack,
		TextColor3 = THEME.Ink,
		TextXAlignment = Enum.TextXAlignment.Center,
	})
	makeText(card, {
		Text = review.Name,
		Position = UDim2.fromOffset(68, 14),
		Size = UDim2.new(1, -170, 0, 18),
		TextSize = 13,
		Font = Enum.Font.GothamBold,
	})
	makeText(card, {
		Text = starString(review.Stars),
		Position = UDim2.fromOffset(68, 34),
		Size = UDim2.fromOffset(120, 20),
		TextSize = 18,
		Font = Enum.Font.GothamBold,
		TextColor3 = THEME.Gold,
		TextXAlignment = Enum.TextXAlignment.Left,
	})
	local badgePill = Instance.new("Frame")
	badgePill.BackgroundColor3 = Color3.fromRGB(34, 40, 52)
	badgePill.BorderSizePixel = 0
	badgePill.Size = UDim2.fromOffset(92, 22)
	badgePill.Position = UDim2.new(1, -108, 0, 16)
	badgePill.Parent = card
	local badgeCorner = Instance.new("UICorner")
	badgeCorner.CornerRadius = UDim.new(1, 0)
	badgeCorner.Parent = badgePill
	local badgeStroke = Instance.new("UIStroke")
	badgeStroke.Color = accent
	badgeStroke.Transparency = 0.35
	badgeStroke.Parent = badgePill
	makeText(badgePill, {
		Text = review.Badge,
		Size = UDim2.fromScale(1, 1),
		TextSize = 10,
		Font = Enum.Font.GothamBold,
		TextXAlignment = Enum.TextXAlignment.Center,
		TextColor3 = THEME.Muter,
	})
	makeText(card, {
		Text = review.Title,
		Position = UDim2.fromOffset(16, 72),
		Size = UDim2.new(1, -32, 0, 18),
		TextSize = 13,
		Font = Enum.Font.GothamBold,
		TextTruncate = Enum.TextTruncate.AtEnd,
	})
	makeText(card, {
		Text = review.Body,
		Position = UDim2.fromOffset(16, 94),
		Size = UDim2.new(1, -32, 0, 34),
		TextSize = 12,
		Font = Enum.Font.Gotham,
		TextColor3 = THEME.Muter,
		TextWrapped = true,
		TextYAlignment = Enum.TextYAlignment.Top,
	})
	return card
end

local function buildReviews(info)
	if type(info.Reviews) == "table" and #info.Reviews > 0 then
		return info.Reviews
	end
	if (info.Stats.TotalGuests or 0) <= 0 then
		return {
			{
				Name = "System",
				Badge = "Awaiting guests",
				Stars = 0,
				Title = "No guest feedback yet",
				Body = "Ratings and reviews will start filling in once guests visit and use the resort.",
				Accent = THEME.Muter,
				IsPlaceholder = true,
			},
		}
	end
	local reviews = {}
	local food = info.Amenities.Food
	local lifts = info.Amenities.Lifts
	local lodging = info.Amenities.Lodging
	local happy = info.HappyRatio
	local hungry = info.HungryRatio
	local rating = info.Rating
	local seeds = {
		{
			Stars = rating >= 4.4 and 5 or 4,
			Title = rating >= 4.4 and "Loved the mountain flow" or "Fun day, just needs a little polish",
			Body = rating >= 4.4
				and "The trails felt smooth and the whole resort looked put together. I would stay longer just to try another run."
				or "The skiing is fun and the base has a nice look, but a few more upgrades would make the whole visit feel premium.",
			Accent = THEME.Cyan,
		},
		{
			Stars = food > 0 and hungry < 0.2 and 5 or (food > 0 and 4 or 2),
			Title = food > 0 and "Food stops kept the day going" or "Please add somewhere to eat",
			Body = food > 0
				and "Having a food stop nearby kept the trip easy. Guests can stay on the mountain longer when snacks are close."
				or "The skiing is there, but guests start fading when there is nowhere to grab food. This is the biggest missing piece right now.",
			Accent = food > 0 and THEME.Orange or THEME.Red,
		},
		{
			Stars = lifts >= 3 and 5 or (lifts >= 1 and 4 or 2),
			Title = lifts >= 3 and "Lift lineup feels legit" or (lifts >= 1 and "Could use more lift variety" or "Not enough lift access"),
			Body = lifts >= 3
				and "There was enough lift coverage that the mountain felt active instead of repetitive."
				or (lifts >= 1
					and "The current lifts work, but adding another option would spread guests out and make the resort feel larger."
					or "Guests are noticing the limited lift access. Another lift would help the resort scale up fast."),
			Accent = THEME.Blue,
		},
		{
			Stars = lodging > 0 and 5 or 3,
			Title = lodging > 0 and "Nice place to stay after skiing" or "Good day-trip mountain",
			Body = lodging > 0
				and "The resort feels more complete when there is a place to stay nearby. It reads like a proper destination."
				or "This works well for a quick visit, but some lodging would make the base feel more alive.",
			Accent = lodging > 0 and THEME.Green or THEME.Gold,
		},
		{
			Stars = happy >= 0.8 and 5 or (happy >= 0.6 and 4 or 3),
			Title = happy >= 0.8 and "Guests leave happy" or "Mood is decent, but not maxed yet",
			Body = happy >= 0.8
				and "Most guests are clearly having a good time. The resort has enough variety that people leave impressed."
				or "There is a solid base here, but the next wave of amenities and polish would move ratings faster.",
			Accent = THEME.Cyan,
		},
	}
	for index, seed in ipairs(seeds) do
		seed.Name = REVIEW_NAMES[((index - 1) % #REVIEW_NAMES) + 1]
		seed.Badge = index == 1 and "Most Helpful" or (index == 2 and "Food" or (index == 3 and "Lifts" or "Guest Review"))
		table.insert(reviews, seed)
	end
	return reviews
end

local function countActualReviews(reviews)
	local count = 0
	for _, review in ipairs(reviews or {}) do
		if type(review) == "table" and review.IsPlaceholder ~= true then
			count += 1
		end
	end
	return count
end

local function ensureUiBuilt()
	if ui.Built then return end
	ui.Built = true

	for _, child in ipairs(Body:GetChildren()) do
		if child:IsA("UIListLayout") or child:IsA("UIPadding") then
			child:Destroy()
		elseif child:IsA("GuiObject") then
			child.Visible = false
		end
	end

	Body.BackgroundTransparency = 1
	Body.ClipsDescendants = true

	ui.TabBar = Instance.new("Frame")
	ui.TabBar.Name = "TabBar"
	ui.TabBar.BackgroundTransparency = 1
	ui.TabBar.Position = UDim2.fromOffset(0, 0)
	ui.TabBar.Size = UDim2.new(1, 0, 0, 42)
	ui.TabBar.Parent = Body

	local tabPadding = Instance.new("UIPadding")
	tabPadding.PaddingLeft = UDim.new(0, 2)
	tabPadding.PaddingRight = UDim.new(0, 2)
	tabPadding.Parent = ui.TabBar

	local tabLayout = Instance.new("UIListLayout")
	tabLayout.FillDirection = Enum.FillDirection.Horizontal
	tabLayout.HorizontalAlignment = Enum.HorizontalAlignment.Left
	tabLayout.Padding = UDim.new(0, 10)
	tabLayout.Parent = ui.TabBar

	for _, def in ipairs(TABS) do
		local button = Instance.new("TextButton")
		button.Name = def.Key
		button.AutoButtonColor = false
		button.BackgroundColor3 = THEME.Tab
		button.BackgroundTransparency = 0.04
		button.BorderSizePixel = 0
		button.Size = UDim2.fromOffset(116, 34)
		button.Font = Enum.Font.GothamBold
		button.TextSize = 13
		button.TextColor3 = THEME.Ink
		button.Text = def.Label
		button.Parent = ui.TabBar
		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(0, 12)
		corner.Parent = button
		local gradient = Instance.new("UIGradient")
		gradient.Name = "TabGradient"
		gradient.Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, THEME.Tab),
			ColorSequenceKeypoint.new(1, THEME.CardAlt),
		})
		gradient.Rotation = 90
		gradient.Parent = button
		local stroke = Instance.new("UIStroke")
		stroke.Color = THEME.PanelEdge
		stroke.Transparency = 0.15
		stroke.Parent = button
		local accent = Instance.new("Frame")
		accent.Name = "Accent"
		accent.BackgroundColor3 = THEME.Blue
		accent.BackgroundTransparency = 0.82
		accent.BorderSizePixel = 0
		accent.Size = UDim2.new(0, 42, 0, 3)
		accent.Position = UDim2.new(0.5, -21, 1, -6)
		accent.Parent = button
		local accentCorner = Instance.new("UICorner")
		accentCorner.CornerRadius = UDim.new(1, 0)
		accentCorner.Parent = accent
		ui.TabButtons[def.Key] = button
	end

	ui.Scroll = Instance.new("ScrollingFrame")
	ui.Scroll.Name = "ReviewScroll"
	ui.Scroll.BackgroundTransparency = 1
	ui.Scroll.BorderSizePixel = 0
	ui.Scroll.Position = UDim2.fromOffset(0, 52)
	ui.Scroll.Size = UDim2.new(1, 0, 1, -52)
	ui.Scroll.ScrollBarThickness = 6
	ui.Scroll.ScrollBarImageColor3 = THEME.PanelEdge
	ui.Scroll.CanvasSize = UDim2.new()
	ui.Scroll.AutomaticCanvasSize = Enum.AutomaticSize.None
	ui.Scroll.Parent = Body

	ui.Content = Instance.new("Frame")
	ui.Content.Name = "Content"
	ui.Content.BackgroundTransparency = 1
	ui.Content.Size = UDim2.new(1, -6, 0, 0)
	ui.Content.AutomaticSize = Enum.AutomaticSize.Y
	ui.Content.Parent = ui.Scroll

	local padding = Instance.new("UIPadding")
	padding.PaddingTop = UDim.new(0, 2)
	padding.PaddingBottom = UDim.new(0, 18)
	padding.PaddingLeft = UDim.new(0, 2)
	padding.PaddingRight = UDim.new(0, 6)
	padding.Parent = ui.Content

	local layout = Instance.new("UIListLayout")
	layout.Padding = UDim.new(0, 10)
	layout.Parent = ui.Content
	layout:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(function()
		ui.Scroll.CanvasSize = UDim2.new(0, 0, 0, layout.AbsoluteContentSize.Y + 8)
	end)

	local titleLabel = Header:FindFirstChild("Title")
	if titleLabel and titleLabel:IsA("TextLabel") then
		titleLabel.TextScaled = false
		titleLabel.Font = Enum.Font.GothamBold
		titleLabel.TextColor3 = THEME.Ink
		titleLabel.BackgroundTransparency = 1
	end
	local subtitle = Header:FindFirstChild("Subtitle")
	if subtitle and subtitle:IsA("TextLabel") then
		subtitle.TextScaled = false
		subtitle.Font = Enum.Font.GothamMedium
		subtitle.TextColor3 = THEME.Muter
		subtitle.BackgroundTransparency = 1
		subtitle.TextTransparency = 0
	end
	ui.HeaderRating = Header:FindFirstChild("RatingValue")
	if not ui.HeaderRating then
		ui.HeaderRating = Header:FindFirstChild("Summary")
	end
	if ui.HeaderRating and ui.HeaderRating:IsA("TextLabel") then
		ui.HeaderRating.TextScaled = false
		ui.HeaderRating.Font = Enum.Font.GothamBlack
		ui.HeaderRating.TextColor3 = THEME.Gold
		ui.HeaderRating.BackgroundTransparency = 1
		ui.HeaderRating.TextXAlignment = Enum.TextXAlignment.Center
		ui.HeaderRating.TextYAlignment = Enum.TextYAlignment.Center
	end
	CloseButton.TextScaled = false
	CloseButton.Font = Enum.Font.GothamBold
	CloseButton.TextColor3 = Color3.fromRGB(255, 242, 242)
	CloseButton.TextTransparency = 0

	ui.ReviewCount = makeText(Header, {
		Name = "ReviewCount",
		Text = "",
		Position = UDim2.new(0, 18, 0, 52),
		Size = UDim2.new(0, 260, 0, 16),
		TextSize = 11,
		Font = Enum.Font.GothamMedium,
		TextColor3 = THEME.Muter,
	})
	ui.HeaderStars = makeText(Header, {
		Name = "HeaderStars",
		Text = "",
		Position = UDim2.new(1, -182, 0, 48),
		Size = UDim2.fromOffset(132, 22),
		TextSize = 20,
		Font = Enum.Font.GothamBold,
		TextColor3 = THEME.Gold,
		TextXAlignment = Enum.TextXAlignment.Center,
	})
end

local function updateTabVisuals()
	for key, button in pairs(ui.TabButtons) do
		local active = key == ui.CurrentTab
		button.BackgroundColor3 = active and THEME.TabActive or THEME.Tab
		button.TextColor3 = active and THEME.Ink or THEME.Muter
		local stroke = button:FindFirstChildOfClass("UIStroke")
		if stroke then
			stroke.Color = active and THEME.Blue or THEME.PanelEdge
			stroke.Transparency = active and 0.05 or 0.18
		end
		local gradient = button:FindFirstChild("TabGradient")
		if gradient and gradient:IsA("UIGradient") then
			gradient.Color = active and ColorSequence.new({
				ColorSequenceKeypoint.new(0, Color3.fromRGB(53, 72, 104)),
				ColorSequenceKeypoint.new(1, Color3.fromRGB(34, 46, 70)),
			}) or ColorSequence.new({
				ColorSequenceKeypoint.new(0, THEME.Tab),
				ColorSequenceKeypoint.new(1, THEME.CardAlt),
			})
		end
		local accent = button:FindFirstChild("Accent")
		if accent and accent:IsA("Frame") then
			accent.BackgroundTransparency = active and 0.05 or 0.82
			accent.BackgroundColor3 = active and THEME.Cyan or THEME.Blue
		end
	end
end

local function renderOverview(info)
	local hero = makeFrame(ui.Content, "HeroCard", THEME.Card, 180)
	local grad = Instance.new("UIGradient")
	grad.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(22, 31, 47)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(13, 18, 28)),
	})
	grad.Rotation = 12
	grad.Parent = hero
	makeText(hero, {
		Text = "Guest sentiment",
		Position = UDim2.fromOffset(18, 16),
		Size = UDim2.new(1, -160, 0, 18),
		TextSize = 13,
		Font = Enum.Font.GothamBold,
		TextColor3 = THEME.Muter,
	})
	makeText(hero, {
		Text = formatRating(info.Rating) .. " / 5",
		Position = UDim2.fromOffset(18, 34),
		Size = UDim2.new(0, 180, 0, 40),
		TextSize = 32,
		Font = Enum.Font.GothamBlack,
	})
	makeText(hero, {
		Text = starString(info.Rating),
		Position = UDim2.fromOffset(18, 78),
		Size = UDim2.new(0, 140, 0, 22),
		TextSize = 20,
		Font = Enum.Font.GothamBold,
		TextColor3 = THEME.Gold,
	})
	local preview = buildReviews(info)
	local totalReviewCount = getReviewCount(info)
	local previewCount = math.min(2, countActualReviews(preview))
	local reviewCountText = string.format("%s • %d guest reviews", info.ReviewLabel, math.max(totalReviewCount, previewCount))
	if previewCount > 0 and totalReviewCount > previewCount then
		reviewCountText = string.format("%s • Showing %d of %d guest reviews", info.ReviewLabel, previewCount, totalReviewCount)
	end
	makeText(hero, {
		Text = reviewCountText,
		Position = UDim2.fromOffset(18, 106),
		Size = UDim2.new(1, -36, 0, 18),
		TextSize = 12,
		Font = Enum.Font.GothamMedium,
		TextColor3 = THEME.Muter,
	})
	makeText(hero, {
		Text = "Players raise this by keeping guests happy, fed, and giving them enough lifts and places to stay.",
		Position = UDim2.fromOffset(18, 130),
		Size = UDim2.new(1, -36, 0, 32),
		TextSize = 12,
		Font = Enum.Font.Gotham,
		TextColor3 = THEME.Muter,
		TextWrapped = true,
	})

	local chipWrap = Instance.new("Frame")
	chipWrap.Name = "ChipWrap"
	chipWrap.BackgroundTransparency = 1
	chipWrap.Size = UDim2.new(1, 0, 0, 134)
	chipWrap.Parent = ui.Content
	local chipLayout = Instance.new("UIGridLayout")
	chipLayout.CellSize = UDim2.new(0.5, -6, 0, 62)
	chipLayout.CellPadding = UDim2.new(0, 12, 0, 10)
	chipLayout.Parent = chipWrap
	createMetricChip(chipWrap, "Happy guests", formatPercent(info.HappyRatio), THEME.Green)
	createMetricChip(chipWrap, "Hungry exits", formatPercent(info.HungryRatio), THEME.Orange)
	createMetricChip(chipWrap, "Lift count", tostring(info.Amenities.Lifts), THEME.Blue)
	createMetricChip(chipWrap, "Food + lodging", string.format("%d + %d", info.Amenities.Food, info.Amenities.Lodging), THEME.Cyan)

	createBarCard(ui.Content, "Overall mood", formatPercent(getPositiveShare(info)), {
		Fill = getPositiveShare(info),
		Text = string.format("%d of %d guests left happy", info.Stats.HappyGuests, info.Stats.TotalGuests),
	}, THEME.Green)
	createBarCard(ui.Content, "Food coverage", formatPercent(1 - info.HungryRatio), {
		Fill = 1 - info.HungryRatio,
		Text = info.Amenities.Food > 0 and "Food exists, but more stops can still lift ratings." or "No food stops means guests are leaving hungry.",
	}, info.Amenities.Food > 0 and THEME.Orange or THEME.Red)
	createBarCard(ui.Content, "Resort depth", string.format("%d key amenities", info.Amenities.Lifts + info.Amenities.Food + info.Amenities.Lodging), {
		Fill = math.clamp((info.Amenities.Lifts + info.Amenities.Food + info.Amenities.Lodging) / 8, 0, 1),
		Text = "More lifts, restaurants, and lodging make the resort feel complete.",
	}, THEME.Blue)

	makeText(ui.Content, {
		Text = "What guests are saying",
		Height = 18,
		TextSize = 13,
		Font = Enum.Font.GothamBold,
	})
	for index = 1, math.min(2, #preview) do
		createReviewCard(ui.Content, preview[index], index)
	end
end

local function renderReviews(info)
	local reviews = buildReviews(info)
	local totalReviewCount = getReviewCount(info)
	local displayedReviewCount = countActualReviews(reviews)
	local reviewFeedText = string.format("%d guest reviews • %s recommend this resort", math.max(totalReviewCount, displayedReviewCount), formatPercent(getPositiveShare(info)))
	if displayedReviewCount > 0 and totalReviewCount > displayedReviewCount then
		reviewFeedText = string.format("Showing %d of %d guest reviews • %s recommend this resort", displayedReviewCount, totalReviewCount, formatPercent(getPositiveShare(info)))
	end
	local banner = makeFrame(ui.Content, "ReviewBanner", THEME.Card, 90)
	makeText(banner, {
		Text = "Review feed",
		Position = UDim2.fromOffset(16, 12),
		Size = UDim2.new(1, -32, 0, 18),
		TextSize = 14,
		Font = Enum.Font.GothamBold,
	})
	makeText(banner, {
		Text = reviewFeedText,
		Position = UDim2.fromOffset(16, 34),
		Size = UDim2.new(1, -32, 0, 18),
		TextSize = 12,
		Font = Enum.Font.GothamMedium,
		TextColor3 = THEME.Muter,
	})
	makeText(banner, {
		Text = "Good reviews come from smooth skiing, enough lifts, food coverage, and a base area that feels complete.",
		Position = UDim2.fromOffset(16, 54),
		Size = UDim2.new(1, -32, 0, 22),
		TextSize = 12,
		Font = Enum.Font.Gotham,
		TextColor3 = THEME.Muter,
		TextWrapped = true,
	})
	for index, review in ipairs(reviews) do
		createReviewCard(ui.Content, review, index)
	end
end

local function renderGuests(info)
	local actionCard = makeFrame(ui.Content, "ActionCard", THEME.Card, 120)
	makeText(actionCard, {
		Text = "What moves the rating next",
		Position = UDim2.fromOffset(16, 14),
		Size = UDim2.new(1, -32, 0, 18),
		TextSize = 14,
		Font = Enum.Font.GothamBold,
	})
	local suggestions = {
		info.Amenities.Food > 0 and "Food coverage exists. More restaurant density will keep hungry exits down." or "Add a rental or restaurant so guests stop leaving hungry.",
		info.Amenities.Lifts >= 3 and "Lift variety is solid. Focus on terrain polish and guest flow next." or "Add another lift or queue route so the mountain feels larger and guests spread out.",
		info.Amenities.Lodging > 0 and "Lodging is helping the base feel complete." or "A hotel or cabin cluster will make the resort feel more like a destination.",
	}
	for index, text in ipairs(suggestions) do
		makeText(actionCard, {
			Text = string.format("%d. %s", index, text),
			Position = UDim2.fromOffset(16, 18 + (index * 24)),
			Size = UDim2.new(1, -32, 0, 20),
			TextSize = 12,
			Font = Enum.Font.Gotham,
			TextColor3 = THEME.Muter,
			TextWrapped = true,
		})
	end
	createBarCard(ui.Content, "Guest happiness", formatPercent(info.HappyRatio), {
		Fill = info.HappyRatio,
		Text = string.format("%d happy guests out of %d total", info.Stats.HappyGuests, info.Stats.TotalGuests),
	}, THEME.Green)
	createBarCard(ui.Content, "Food pressure", formatPercent(info.HungryRatio), {
		Fill = info.HungryRatio,
		Text = info.HungryRatio > 0.2 and "Guests are noticing missing food options." or "Food pressure is under control right now.",
	}, info.HungryRatio > 0.2 and THEME.Red or THEME.Orange)
	createBarCard(ui.Content, "Amenity spread", string.format("%d lifts • %d food • %d lodging", info.Amenities.Lifts, info.Amenities.Food, info.Amenities.Lodging), {
		Fill = math.clamp((info.Amenities.Lifts + info.Amenities.Food + info.Amenities.Lodging) / 8, 0, 1),
		Text = "Balanced amenities raise ratings more reliably than only adding one category.",
	}, THEME.Cyan)
end

local function renderSummary(summary)
	ensureUiBuilt()
	local info = normalizeSummary(summary)
	ui.LastSummary = info

	Header.BackgroundTransparency = 0.04
	Header.BackgroundColor3 = Color3.fromRGB(20, 24, 34)
	local headerGradient = Header:FindFirstChildOfClass("UIGradient")
	if headerGradient then
		headerGradient.Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, THEME.HeaderA),
			ColorSequenceKeypoint.new(1, THEME.HeaderB),
		})
	end
	RatingFrame.BackgroundColor3 = THEME.Panel
	local frameGradient = RatingFrame:FindFirstChildOfClass("UIGradient")
	if frameGradient then
		frameGradient.Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, Color3.fromRGB(22, 28, 39)),
			ColorSequenceKeypoint.new(1, Color3.fromRGB(14, 18, 26)),
		})
	end

	local titleLabel = Header:FindFirstChild("Title")
	local subtitle = Header:FindFirstChild("Subtitle")
	local ratingValue = ui.HeaderRating or Header:FindFirstChild("RatingValue") or Header:FindFirstChild("Summary")
	if titleLabel then titleLabel.Text = "Resort Reviews" end
	if subtitle then subtitle.Text = info.ReviewLabel end
	if ratingValue then ratingValue.Text = string.format("%s / 5", formatRating(info.Rating)) end
	if ui.ReviewCount then
		local displayedReviewCount = countActualReviews(buildReviews(info))
		local totalReviewCount = getReviewCount(info)
		if displayedReviewCount > 0 and totalReviewCount > displayedReviewCount then
			ui.ReviewCount.Text = string.format("Showing %d of %d guest reviews • %s positive", displayedReviewCount, totalReviewCount, formatPercent(getPositiveShare(info)))
		else
			ui.ReviewCount.Text = string.format("%d guest reviews • %s positive", math.max(totalReviewCount, displayedReviewCount), formatPercent(getPositiveShare(info)))
		end
	end
	if ui.HeaderStars then ui.HeaderStars.Text = starString(info.Rating) end

	updateTabVisuals()
	clearContent()
	if ui.CurrentTab == "Reviews" then
		renderReviews(info)
	elseif ui.CurrentTab == "Guests" then
		renderGuests(info)
	else
		renderOverview(info)
	end
end

local function applyResponsiveLayout()
	ensureUiBuilt()
	local viewport = getViewportSize()
	local shortSide = math.min(viewport.X, viewport.Y)
	local isTouchLayout = UserInputService.TouchEnabled and shortSide <= 1100
	local width = math.clamp(math.floor(viewport.X * (isTouchLayout and 0.9 or 0.56)), isTouchLayout and 540 or 720, isTouchLayout and 940 or 1080)
	local height = math.clamp(math.floor(viewport.Y * (isTouchLayout and 0.8 or 0.72)), isTouchLayout and 500 or 560, isTouchLayout and 900 or 860)
	RatingFrame.Size = UDim2.fromOffset(width, height)
	Header.Size = UDim2.new(1, -20, 0, isTouchLayout and 90 or 78)
	Header.Position = UDim2.fromOffset(10, 10)
	Body.Position = UDim2.fromOffset(12, isTouchLayout and 106 or 94)
	Body.Size = UDim2.new(1, -24, 1, -(isTouchLayout and 118 or 106))

	local titleLabel = Header:FindFirstChild("Title")
	local subtitle = Header:FindFirstChild("Subtitle")
	local ratingValue = ui.HeaderRating or Header:FindFirstChild("RatingValue") or Header:FindFirstChild("Summary")
	local closeWidth = isTouchLayout and 66 or 58
	local closeHeight = isTouchLayout and 30 or 28
	local ratingBlockWidth = isTouchLayout and 140 or 152
	local rightInset = 16
	local titleRightInset = rightInset + closeWidth + 12 + ratingBlockWidth + 12
	if titleLabel and titleLabel:IsA("TextLabel") then
		titleLabel.TextScaled = false
		titleLabel.TextWrapped = false
		titleLabel.TextTruncate = Enum.TextTruncate.AtEnd
		titleLabel.Position = UDim2.fromOffset(18, isTouchLayout and 10 or 8)
		titleLabel.Size = UDim2.new(1, -titleRightInset, 0, isTouchLayout and 24 or 22)
		titleLabel.TextSize = isTouchLayout and 20 or 18
	end
	if subtitle and subtitle:IsA("TextLabel") then
		subtitle.TextScaled = false
		subtitle.TextWrapped = false
		subtitle.TextTruncate = Enum.TextTruncate.AtEnd
		subtitle.Position = UDim2.fromOffset(18, isTouchLayout and 34 or 30)
		subtitle.Size = UDim2.new(1, -titleRightInset, 0, 16)
		subtitle.TextSize = isTouchLayout and 12 or 11
	end
	if ui.ReviewCount then
		ui.ReviewCount.TextScaled = false
		ui.ReviewCount.TextWrapped = false
		ui.ReviewCount.TextTruncate = Enum.TextTruncate.AtEnd
		ui.ReviewCount.Position = UDim2.fromOffset(18, isTouchLayout and 54 or 48)
		ui.ReviewCount.Size = UDim2.new(1, -titleRightInset, 0, 14)
		ui.ReviewCount.TextSize = isTouchLayout and 11 or 10
	end
	if ratingValue and ratingValue:IsA("TextLabel") then
		ratingValue.AnchorPoint = Vector2.new(1, 0)
		ratingValue.TextScaled = false
		ratingValue.TextWrapped = false
		ratingValue.Position = UDim2.new(1, -(rightInset + closeWidth + 12), 0, isTouchLayout and 10 or 8)
		ratingValue.Size = UDim2.fromOffset(ratingBlockWidth, isTouchLayout and 28 or 26)
		ratingValue.TextSize = isTouchLayout and 26 or 24
	end
	if ui.HeaderStars then
		ui.HeaderStars.AnchorPoint = Vector2.new(1, 0)
		ui.HeaderStars.TextScaled = false
		ui.HeaderStars.Position = UDim2.new(1, -(rightInset + closeWidth + 12), 0, isTouchLayout and 42 or 36)
		ui.HeaderStars.Size = UDim2.fromOffset(ratingBlockWidth, isTouchLayout and 24 or 22)
		ui.HeaderStars.TextSize = isTouchLayout and 18 or 17
		ui.HeaderStars.TextWrapped = false
		ui.HeaderStars.TextXAlignment = Enum.TextXAlignment.Center
	end
	CloseButton.AnchorPoint = Vector2.new(1, 0)
	CloseButton.TextScaled = false
	CloseButton.Position = UDim2.new(1, -rightInset, 0, isTouchLayout and 10 or 8)
	CloseButton.Size = UDim2.fromOffset(closeWidth, closeHeight)
	CloseButton.TextSize = isTouchLayout and 10 or 9
	if ui.TabBar then
		ui.TabBar.Size = UDim2.new(1, 0, 0, isTouchLayout and 46 or 42)
	end
	if ui.Scroll then
		ui.Scroll.Position = UDim2.fromOffset(0, isTouchLayout and 50 or 48)
		ui.Scroll.Size = UDim2.new(1, 0, 1, -(isTouchLayout and 50 or 48))
	end
	for _, button in pairs(ui.TabButtons) do
		button.Size = UDim2.fromOffset(isTouchLayout and 122 or 116, isTouchLayout and 36 or 34)
		button.TextSize = isTouchLayout and 13 or 13
	end
	for _, desc in ipairs(RatingFrame:GetDescendants()) do
		if desc:IsA("TextLabel") or desc:IsA("TextButton") then
			local base = desc:GetAttribute("ResponsiveBaseTextSize")
			if base == nil then
				base = desc.TextSize
				desc:SetAttribute("ResponsiveBaseTextSize", base)
			end
			desc.TextSize = isTouchLayout and math.max(base, math.floor(base * 1.08 + 0.5)) or base
		end
	end
	if ui.LastSummary then
		renderSummary(ui.LastSummary)
	end
end

local function playTween(target)
	if ui.ActiveTween then
		ui.ActiveTween:Cancel()
	end
	ui.ActiveTween = TweenService:Create(RatingFrame, target == OPEN_POSITION and OPEN_TWEEN or CLOSE_TWEEN, { Position = target })
	ui.ActiveTween:Play()
	return ui.ActiveTween
end

local function setOpen(open)
	if ui.IsOpen == open then return end
	ui.IsOpen = open
	applyResponsiveLayout()
	if ui.IsOpen then
		ClosePanels:Fire("Rating")
		RatingFrame.Visible = true
		RatingFrame.Position = CLOSED_POSITION
		playTween(OPEN_POSITION)
	else
		local tween = playTween(CLOSED_POSITION)
		tween.Completed:Once(function()
			if not ui.IsOpen then
				RatingFrame.Visible = false
			end
		end)
	end
end

local function refreshSummary()
	local ok, summary = pcall(function()
		return RatingSummaryRequest:InvokeServer()
	end)
	if ok and type(summary) == "table" then
		renderSummary(summary)
	end
end

ClosePanels.Event:Connect(function(source)
	if source ~= "Rating" and ui.IsOpen then
		setOpen(false)
	end
end)

RatingUpdate.OnClientEvent:Connect(function(newRating)
	if ui.LastSummary then
		ui.LastSummary.Rating = tonumber(newRating) or ui.LastSummary.Rating
	end
	if ui.IsOpen then
		refreshSummary()
	end
end)

bindGuiButton(RatingButton, function()
	if ui.IsOpen then
		setOpen(false)
	else
		refreshSummary()
		setOpen(true)
	end
end)

bindGuiButton(CloseButton, function()
	setOpen(false)
end)

local function hookCamera(camera)
	if not camera then return end
	camera:GetPropertyChangedSignal("ViewportSize"):Connect(applyResponsiveLayout)
end
Workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
	hookCamera(Workspace.CurrentCamera)
	applyResponsiveLayout()
end)
hookCamera(Workspace.CurrentCamera)

for _, button in pairs(ui.TabButtons) do
	bindGuiButton(button, function() end)
end

RatingButton.Active = true
RatingButton.Selectable = true
RatingFrame.Visible = false
RatingFrame.Position = CLOSED_POSITION
ensureUiBuilt()
applyResponsiveLayout()
refreshSummary()

if not ui.RefreshLoopStarted then
	ui.RefreshLoopStarted = true
	task.spawn(function()
		while true do
			task.wait(20)
			if ui.IsOpen then
				refreshSummary()
			end
		end
	end)
end

for key, button in pairs(ui.TabButtons) do
	local tabKey = key
	bindGuiButton(button, function()
		ui.CurrentTab = tabKey
		if ui.LastSummary then
			renderSummary(ui.LastSummary)
		end
	end)
end
