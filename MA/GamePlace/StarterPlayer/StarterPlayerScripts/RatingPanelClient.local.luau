local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local Player = Players.LocalPlayer
local PlayerGui = Player:WaitForChild("PlayerGui")
local MainHUD = PlayerGui:WaitForChild("MainHUD")
local RatingPanel = MainHUD:WaitForChild("Rating")
local LegacyRatingFrame = MainHUD:FindFirstChild("RatingFrame")
local TopBar = MainHUD:WaitForChild("Top"):WaitForChild("TopBar")
local RatingButton = TopBar:WaitForChild("Rating")
local Header = RatingPanel:WaitForChild("Header")
local Content = RatingPanel:WaitForChild("Content")

local function findNamedChild(parent, name, className)
	for _, child in ipairs(parent:GetChildren()) do
		if child.Name == name and (not className or child:IsA(className)) then
			return child
		end
	end
	return nil
end

local RatingPage = Content:WaitForChild("Rating")
local ReviewPage = Content:WaitForChild("Review")
local ReviewCard = findNamedChild(RatingPage, "Reviews", "Frame")
local ReviewListFrame = findNamedChild(ReviewPage, "Reviews", "ScrollingFrame")
local ReviewSummaryFrame = findNamedChild(ReviewPage, "Reviews", "Frame")
local ReviewTemplate = ReviewListFrame and ReviewListFrame:FindFirstChild("Template") or nil
local ReviewSpacerTemplate = ReviewListFrame and (ReviewListFrame:FindFirstChild("Zpadding") or ReviewListFrame:FindFirstChild("ZPadding")) or nil
local PageLayout = Content:FindFirstChildOfClass("UIPageLayout")
local Events = ReplicatedStorage:WaitForChild("Events")
local SlotData = ReplicatedStorage:WaitForChild("SlotData")

local RatingUpdate = Events:WaitForChild("RatingUpdate", 15)
local RatingSummaryRequest = Events:WaitForChild("RatingSummaryRequest", 15)
local ClosePanels = Events:FindFirstChild("ClosePanels")
if not ClosePanels then
	ClosePanels = Instance.new("BindableEvent")
	ClosePanels.Name = "ClosePanels"
	ClosePanels.Parent = Events
end

local Config = nil
pcall(function()
	local configModule = ReplicatedStorage:FindFirstChild("Config")
	if configModule then
		Config = require(configModule)
	end
end)

if LegacyRatingFrame then
	LegacyRatingFrame.Visible = false
	LegacyRatingFrame.Active = false
end

local OPEN_POSITION = UDim2.new(0.5, 0, 0.5, 0)
local CLOSED_POSITION = UDim2.new(0.5, 0, 1.5, 0)
local OPEN_TWEEN = TweenInfo.new(0.28, Enum.EasingStyle.Quart, Enum.EasingDirection.Out)
local CLOSE_TWEEN = TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.In)

local state = {
	IsOpen = false,
	ActiveTween = nil,
	Summary = nil,
	MetricPageIndex = 1,
	ReviewIndex = 1,
	LastRating = nil,   -- tracks previous rating for trend arrow
}

local ui = {
	RatingPage = RatingPage,
	ReviewPage = ReviewPage,
	PageLayout = PageLayout,
	MetricFrame = nil,
	MetricTitle = nil,
	MetricPrevious = nil,
	MetricNext = nil,
	MetricRows = {},
	CategoryFrame = nil,
	CategoryRows = {},
	HeaderStars = Header:WaitForChild("Rating"),
	TopBarStars = RatingButton,
	ReviewName = ReviewCard and ReviewCard:WaitForChild("Name") or nil,
	ReviewBody = ReviewCard and ReviewCard:WaitForChild("Content") or nil,
	ReviewDate = ReviewCard and ReviewCard:WaitForChild("Date") or nil,
	ReviewMore = ReviewCard and ReviewCard:WaitForChild("More") or nil,
	ReviewSummaryName = ReviewSummaryFrame and ReviewSummaryFrame:FindFirstChild("Name") or nil,
	ReviewSummaryBody = ReviewSummaryFrame and ReviewSummaryFrame:FindFirstChild("Content") or nil,
	ReviewSummaryDate = ReviewSummaryFrame and ReviewSummaryFrame:FindFirstChild("Date") or nil,
	ReviewBack = ReviewSummaryFrame and ReviewSummaryFrame:FindFirstChild("Back") or nil,
	ReviewList = ReviewListFrame,
	ReviewListTemplate = ReviewTemplate,
	ReviewSpacerTemplate = ReviewSpacerTemplate,
	CloseButton = Header:WaitForChild("CloseButton"),
	Title = Header:WaitForChild("Title"),
	Subtitle = Header:WaitForChild("Subtitle"),
	TrendLabel = nil,    -- created dynamically next to HeaderStars
}

local starBundles = {}
local starOrigSizes = {}   -- [star] = original UDim2 size, captured once at bundle creation
local animationCooldown = false
local trendFadeThread = nil

-- Creates or returns the trend TextLabel parented to the given frame
local function ensureTrendLabel(parentFrame)
	if not parentFrame then return nil end
	local existing = parentFrame:FindFirstChild("_TrendArrow")
	if existing then return existing end
	local label = Instance.new("TextLabel")
	label.Name = "_TrendArrow"
	label.BackgroundTransparency = 1
	label.Size = UDim2.new(0.2, 0, 1, 0)
	label.Font = Enum.Font.GothamBold
	label.TextScaled = true
	label.TextXAlignment = Enum.TextXAlignment.Center
	label.TextYAlignment = Enum.TextYAlignment.Top
	label.Text = ""
	label.Parent = parentFrame
	return label
end

-- Animates a subtle pop-scale on all stars in a bundle.
-- Uses starOrigSizes to always reset to the true original size.
local function animateStarPop(bundle)
	if not bundle or animationCooldown then return end
	animationCooldown = true
	task.delay(1.5, function() animationCooldown = false end)

	for i, star in ipairs(bundle.Stars) do
		local orig = starOrigSizes[star]
		if not orig then continue end
		star.Size = orig
		task.delay((i - 1) * 0.05, function()
			if not star or not star.Parent then return end
			local up = TweenService:Create(star, TweenInfo.new(0.1, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
				Size = UDim2.new(orig.X.Scale * 1.15, orig.X.Offset * 1.15, orig.Y.Scale * 1.15, orig.Y.Offset * 1.15)
			})
			up:Play()
			up.Completed:Once(function()
				if not star or not star.Parent then return end
				TweenService:Create(star, TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
					Size = orig
				}):Play()
			end)
		end)
	end
end

-- Updates the trend label. Only shown on the panel header, not the TopBar.
local function updateTrendLabel(label, oldRating, newRating)
	if not label then return end
	if oldRating == nil then
		label.Text = ""
		return
	end
	local diff = newRating - oldRating
	if math.abs(diff) < 0.01 then
		return
	end

	-- Cancel any pending fade
	if trendFadeThread then
		task.cancel(trendFadeThread)
		trendFadeThread = nil
	end

	label.TextTransparency = 0
	if diff > 0 then
		label.Text = "▲"
		label.TextColor3 = Color3.fromRGB(86, 214, 140)
	else
		label.Text = "▼"
		label.TextColor3 = Color3.fromRGB(235, 96, 96)
	end

	-- Fade out after 8 seconds
	trendFadeThread = task.delay(8, function()
		if label and label.Parent then
			TweenService:Create(label, TweenInfo.new(1.0, Enum.EasingStyle.Quad), { TextTransparency = 1 }):Play()
			task.delay(1.0, function()
				if label and label.Parent then
					label.Text = ""
					label.TextTransparency = 0
				end
			end)
		end
		trendFadeThread = nil
	end)
end

local function bindGuiButton(button, callback)
	if not (button and callback and button:IsA("GuiObject")) then
		return
	end
	if button:GetAttribute("RatingBound") then
		return
	end
	button:SetAttribute("RatingBound", true)
	button.Active = true
	button.Selectable = true
	local busy = false
	local function fire()
		if busy then
			return
		end
		busy = true
		callback()
		task.delay(0.15, function()
			busy = false
		end)
	end
	if button:IsA("GuiButton") then
		button.Activated:Connect(fire)
	else
		button.InputBegan:Connect(function(input)
			local inputType = input.UserInputType
			if inputType == Enum.UserInputType.MouseButton1 or inputType == Enum.UserInputType.Touch then
				fire()
			end
		end)
	end
end

local function roundHalf(value)
	return math.clamp(math.floor(((tonumber(value) or 0) * 2) + 0.5) / 2, 0, 5)
end

local function getOwnerUserId()
	local ownerValue = SlotData:FindFirstChild("UserId")
	local ownerUserId = ownerValue and tonumber(ownerValue.Value) or nil
	if ownerUserId and ownerUserId > 0 then
		return ownerUserId
	end
	return Player.UserId
end

local function lowerMatch(value, patterns)
	local lowered = string.lower(tostring(value or ""))
	for _, pattern in ipairs(patterns) do
		if string.find(lowered, pattern, 1, true) then
			return true
		end
	end
	return false
end

local function countAmenityBreakdown(summary)
	local breakdown = {
		Restaurants = 0,
		Rentals = 0,
		Lodges = 0,
		Others = 0,
		Lifts = 0,
	}

	if summary and type(summary.Breakdown) == "table" then
		breakdown.Restaurants = math.max(0, tonumber(summary.Breakdown.Restaurants) or 0)
		breakdown.Rentals = math.max(0, tonumber(summary.Breakdown.Rentals) or 0)
		breakdown.Lodges = math.max(0, tonumber(summary.Breakdown.Lodges) or 0)
		breakdown.Others = math.max(0, tonumber(summary.Breakdown.Others) or 0)
		breakdown.Lifts = math.max(0, tonumber(summary.Breakdown.Lifts) or 0)
		return breakdown
	end

	if summary and type(summary.Amenities) == "table" then
		breakdown.Restaurants = math.max(0, tonumber(summary.Amenities.Food) or tonumber(summary.Amenities.Restaurants) or 0)
		breakdown.Rentals = math.max(0, tonumber(summary.Amenities.Rentals) or 0)
		breakdown.Lodges = math.max(0, tonumber(summary.Amenities.Lodging) or tonumber(summary.Amenities.Lodges) or 0)
		breakdown.Others = math.max(0, tonumber(summary.Amenities.Others) or 0)
		breakdown.Lifts = math.max(0, tonumber(summary.Amenities.Lifts) or 0)
		return breakdown
	end

	local placedObjects = Workspace:FindFirstChild("PlacedObjects")
	if not placedObjects then
		return breakdown
	end

	local ownerUserId = getOwnerUserId()
	for _, obj in ipairs(placedObjects:GetDescendants()) do
		if obj:IsA("Model") then
			local owner = tonumber(obj:GetAttribute("Owner"))
			if owner == ownerUserId then
				local itemCfg = nil
				local modelId = obj:GetAttribute("ID")
				if modelId and Config and Config.GetItemById then
					_, itemCfg = Config.GetItemById(modelId)
				end
				if not itemCfg and Config and Config.Items then
					itemCfg = Config.Items[obj.Name]
				end
				local objType = tostring(obj:GetAttribute("Type") or "")
				local objCategory = tostring(obj:GetAttribute("Category") or "")
				local cfgType = itemCfg and tostring(itemCfg.Type or "") or ""
				local cfgCategory = itemCfg and tostring(itemCfg.Category or "") or ""
				local lowerName = string.lower(obj.Name)

				local isLift = lowerMatch(objType, {"twopoint", "lift", "carpet"})
					or lowerMatch(cfgType, {"twopoint", "lift", "carpet"})
					or lowerMatch(lowerName, {"lift", "chair", "gondola", "tram"})
				local isRestaurant = lowerMatch(objType, {"food", "restaurant", "cafe"})
					or lowerMatch(cfgType, {"food", "restaurant", "cafe"})
					or lowerMatch(objCategory, {"food", "restaurant", "cafe"})
					or lowerMatch(cfgCategory, {"food", "restaurant", "cafe"})
					or lowerMatch(lowerName, {"food", "restaurant", "cafe", "snack", "burger", "pizza"})
				local isRental = lowerMatch(objType, {"rental"})
					or lowerMatch(cfgType, {"rental"})
					or lowerMatch(objCategory, {"rental"})
					or lowerMatch(cfgCategory, {"rental"})
					or lowerMatch(lowerName, {"rental", "rent", "ski shop", "gear shop"})
				local isLodge = lowerMatch(objType, {"house", "hotel", "lodging"})
					or lowerMatch(cfgType, {"house", "hotel", "lodging"})
					or lowerMatch(objCategory, {"house", "hotel", "housing", "accommodation", "lodging"})
					or lowerMatch(cfgCategory, {"house", "hotel", "housing", "accommodation", "lodging"})
					or lowerMatch(lowerName, {"hotel", "house", "lodge", "cabin", "inn"})
					or (itemCfg and tonumber(itemCfg.Capacity) and tonumber(itemCfg.Capacity) > 0)

				local categorized = false
				if isLift then
					breakdown.Lifts += 1
					categorized = true
				end
				if isRestaurant then
					breakdown.Restaurants += 1
					categorized = true
				end
				if isRental then
					breakdown.Rentals += 1
					categorized = true
				end
				if isLodge then
					breakdown.Lodges += 1
					categorized = true
				end
				if not categorized then
					breakdown.Others += 1
				end
			end
		end
	end

	if summary and summary.Amenities then
		breakdown.Restaurants = math.max(breakdown.Restaurants, math.max(0, tonumber(summary.Amenities.Food) or 0))
		breakdown.Lodges = math.max(breakdown.Lodges, math.max(0, tonumber(summary.Amenities.Lodging) or 0))
		breakdown.Lifts = math.max(breakdown.Lifts, math.max(0, tonumber(summary.Amenities.Lifts) or 0))
	end

	return breakdown
end

local function ensureStarBundle(frame)
	local existing = starBundles[frame]
	if existing then
		return existing
	end

	local fillImage = ""
	local halfImage = ""
	local emptyImage = ""
	local tint = Color3.fromRGB(255, 28, 70)
	local starSize = UDim2.new(0.18, 0, 1, 0) -- default; overridden if template children exist
	for _, child in ipairs(frame:GetChildren()) do
		if child:IsA("ImageLabel") then
			if child.Name == "Fill" then
				fillImage = child.Image
				tint = child.ImageColor3
				starSize = child.Size -- inherit the designed size exactly
			elseif child.Name == "Half" then
				halfImage = child.Image
			elseif child.Name == "Empty" and emptyImage == "" then
				emptyImage = child.Image
			end
			child:Destroy()
		end
	end

	local layout = frame:FindFirstChildOfClass("UIListLayout")
	if not layout then
		layout = Instance.new("UIListLayout")
		layout.FillDirection = Enum.FillDirection.Horizontal
		layout.HorizontalAlignment = Enum.HorizontalAlignment.Left
		layout.VerticalAlignment = Enum.VerticalAlignment.Center
		layout.Padding = UDim.new(0, 4)
		layout.Parent = frame
	end

	local stars = {}
	for index = 1, 5 do
		local star = Instance.new("ImageLabel")
		star.Name = "Star" .. index
		star.BackgroundTransparency = 1
		star.BorderSizePixel = 0
		star.Size = starSize
		star.ScaleType = Enum.ScaleType.Fit
		star.ImageColor3 = tint
		star.Parent = frame
		local aspect = Instance.new("UIAspectRatioConstraint")
		aspect.AspectRatio = 1
		aspect.Parent = star
		starOrigSizes[star] = starSize  -- store original size for animation reset
		stars[index] = star
	end

	local bundle = {
		Fill = fillImage,
		Half = halfImage ~= "" and halfImage or fillImage,
		Empty = emptyImage ~= "" and emptyImage or fillImage,
		Tint = tint,
		Stars = stars,
	}
	starBundles[frame] = bundle
	return bundle
end

-- Returns a color matching the rating value, same gradient used by the top bar.
-- 0–1.5 → red, 1.5–2.5 → orange, 2.5–3.5 → yellow, 3.5–4.5 → lime, 4.5–5 → green
local function getRatingColor(rating)
	local r = math.clamp(tonumber(rating) or 0, 0, 5)
	if r < 1.5 then
		return Color3.fromRGB(235, 64, 52)   -- red
	elseif r < 2.5 then
		local t = (r - 1.5) / 1.0
		return Color3.fromRGB(
			235 + math.floor((255 - 235) * t),
			64  + math.floor((160 - 64)  * t),
			52  + math.floor((20  - 52)  * t)
		)                                     -- red → orange
	elseif r < 3.5 then
		local t = (r - 2.5) / 1.0
		return Color3.fromRGB(
			255 + math.floor((200 - 255) * t),
			160 + math.floor((210 - 160) * t),
			20  + math.floor((20  - 20)  * t)
		)                                     -- orange → yellow
	elseif r < 4.5 then
		local t = (r - 3.5) / 1.0
		return Color3.fromRGB(
			200 + math.floor((80  - 200) * t),
			210 + math.floor((200 - 210) * t),
			20  + math.floor((80  - 20)  * t)
		)                                     -- yellow → lime
	else
		return Color3.fromRGB(80, 200, 80)    -- green
	end
end

local function setStarRating(frame, rating)
	local bundle = ensureStarBundle(frame)
	local rounded = roundHalf(rating)
	local full = math.floor(rounded)
	local hasHalf = (rounded - full) >= 0.5
	local fillColor = getRatingColor(rating)
	for index, star in ipairs(bundle.Stars) do
		if index <= full then
			star.Image = bundle.Fill
			star.ImageColor3 = fillColor
			star.ImageTransparency = 0
		elseif index == full + 1 and hasHalf then
			star.Image = bundle.Half
			star.ImageColor3 = Color3.new(1, 1, 1)
			star.ImageTransparency = 0.7
		else
			star.Image = bundle.Empty
			star.ImageColor3 = Color3.new(1, 1, 1)
			star.ImageTransparency = 0.7
		end
	end
end

local function countRunningLifts()
	local placedObjects = Workspace:FindFirstChild("PlacedObjects")
	if not placedObjects then
		return 0
	end
	local ownerUserId = getOwnerUserId()
	local running = 0
	for _, obj in ipairs(placedObjects:GetDescendants()) do
		if obj:IsA("Model") then
			local owner = tonumber(obj:GetAttribute("Owner"))
			if owner == ownerUserId then
				local lowerName = string.lower(obj.Name)
				local objType = string.lower(tostring(obj:GetAttribute("Type") or ""))
				local status = string.lower(tostring(obj:GetAttribute("Status") or ""))
				local targetSpeed = tonumber(obj:GetAttribute("TargetSpeed")) or 0
				local isLift = lowerMatch(objType, {"twopoint", "lift", "carpet"}) or lowerMatch(lowerName, {"lift", "chair", "gondola", "tram", "tow"})
				if isLift and (status == "running" or targetSpeed > 0.05) then
					running += 1
				end
			end
		end
	end
	return running
end

local function applyIdleResortClamp(summary)
	local breakdown = countAmenityBreakdown(summary)
	local totalGuests = math.max(0, tonumber(summary.Stats and summary.Stats.TotalGuests) or 0)
	local runningLifts = countRunningLifts()
	local amenityCount = breakdown.Lifts + breakdown.Restaurants + breakdown.Rentals + breakdown.Lodges + breakdown.Others

	if totalGuests <= 0 then
		summary.ReviewCount = 0
		summary.PositiveShare = 0
		summary.ReviewLabel = amenityCount > 0 and "Awaiting guest feedback" or "Resort not operating"
		if amenityCount <= 0 then
			summary.Rating = 0
		elseif runningLifts <= 0 then
			local idleCap = math.min(3.25, 1.45 + (math.min(amenityCount, 6) * 0.32))
			summary.Rating = math.min(summary.Rating, idleCap)
		else
			local waitingCap = math.min(4.35, 2.65 + (math.min(runningLifts, 4) * 0.28) + (math.min(breakdown.Restaurants + breakdown.Rentals + breakdown.Lodges, 5) * 0.12))
			summary.Rating = math.min(summary.Rating, waitingCap)
		end
		for key, value in pairs(summary.CategoryScores) do
			summary.CategoryScores[key] = math.min(roundHalf(value or 0), roundHalf(summary.Rating))
		end
	end

	return summary
end

local function normalizeSummary(raw)
	local stats = type(raw) == "table" and type(raw.Stats) == "table" and raw.Stats or {}
	local amenities = type(raw) == "table" and type(raw.Amenities) == "table" and raw.Amenities or {}
	local breakdown = type(raw) == "table" and type(raw.Breakdown) == "table" and raw.Breakdown or {}
	local operational = type(raw) == "table" and type(raw.Operational) == "table" and raw.Operational or {}
	local categoryScores = type(raw) == "table" and type(raw.CategoryScores) == "table" and raw.CategoryScores or {}
	local reviews = type(raw) == "table" and type(raw.Reviews) == "table" and raw.Reviews or {}
	local info = {
		Rating = math.clamp(tonumber(raw and raw.Rating) or 0, 0, 5),
		ReviewLabel = tostring(raw and raw.ReviewLabel or "Resort Rating"),
		ReviewCount = math.max(0, tonumber(raw and raw.ReviewCount) or #reviews),
		PositiveShare = math.clamp(tonumber(raw and raw.PositiveShare) or 0, 0, 1),
		HappyRatio = math.clamp(tonumber(raw and raw.HappyRatio) or 0, 0, 1),
		HungryRatio = math.clamp(tonumber(raw and raw.HungryRatio) or 0, 0, 1),
		RefreshEpoch = math.max(0, tonumber(raw and raw.RefreshEpoch) or 0),
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
		Breakdown = {
			Restaurants = math.max(0, tonumber(breakdown.Restaurants) or 0),
			Rentals = math.max(0, tonumber(breakdown.Rentals) or 0),
			Lodges = math.max(0, tonumber(breakdown.Lodges) or 0),
			Others = math.max(0, tonumber(breakdown.Others) or 0),
			Lifts = math.max(0, tonumber(breakdown.Lifts) or tonumber(amenities.Lifts) or 0),
		},
		Operational = {
			ReroutesPerMinute = math.max(0, tonumber(operational.ReroutesPerMinute) or 0),
			FoodMisses = math.max(0, tonumber(operational.FoodMisses) or 0),
			LiftMisses = math.max(0, tonumber(operational.LiftMisses) or 0),
			BrokeExits = math.max(0, tonumber(operational.BrokeExits) or 0),
			TiredExits = math.max(0, tonumber(operational.TiredExits) or 0),
			GuestLoad = math.max(0, tonumber(operational.GuestLoad) or 0),
			Cleanliness = math.clamp(tonumber(operational.Cleanliness) or 100, 0, 100),
			DirtyBuildings = math.max(0, tonumber(operational.DirtyBuildings) or 0),
			CleanableBuildings = math.max(0, tonumber(operational.CleanableBuildings) or 0),
			JanitorCoverage = math.max(0, tonumber(operational.JanitorCoverage) or 0),
			JanitorCoverageRatio = math.clamp(tonumber(operational.JanitorCoverageRatio) or 0, 0, 1),
		},
		CategoryScores = {
			Amenities = roundHalf(categoryScores.Amenities or raw and raw.Rating or 0),
			Quality = roundHalf(categoryScores.Quality or raw and raw.Rating or 0),
			Crowdy = roundHalf(categoryScores.Crowdy or raw and raw.Rating or 0),
			ResortSize = roundHalf(categoryScores.ResortSize or raw and raw.Rating or 0),
		},
		Reviews = reviews,
	}
	return applyIdleResortClamp(info)
end

local function getFallbackSummary()
	return normalizeSummary({
		Rating = 0,
		ReviewLabel = "Needs data",
		ReviewCount = 0,
		PositiveShare = 0,
		HappyRatio = 0,
		HungryRatio = 0,
		Stats = {
			TotalGuests = 0,
			HappyGuests = 0,
			HungryGuests = 0,
		},
		Amenities = {
			Lifts = 0,
			Food = 0,
			Lodging = 0,
		},
		Breakdown = {
			Restaurants = 0,
			Rentals = 0,
			Lodges = 0,
			Others = 0,
			Lifts = 0,
		},
		Operational = {
			ReroutesPerMinute = 0,
			FoodMisses = 0,
			LiftMisses = 0,
			BrokeExits = 0,
			TiredExits = 0,
			GuestLoad = 0,
			Cleanliness = 100,
			DirtyBuildings = 0,
			CleanableBuildings = 0,
			JanitorCoverage = 0,
			JanitorCoverageRatio = 0,
		},
		CategoryScores = {
			Amenities = 0,
			Quality = 0,
			Crowdy = 0,
			ResortSize = 0,
		},
		Reviews = {
			{
				Name = "System",
				Body = "Your rating feed will populate once the resort has guest activity and the rating backend returns data.",
				Badge = "Info",
				Stars = 0,
				IsPlaceholder = true,
			},
		},
	})
end

local function buildMetricPages(summary, breakdown)
	return {
		{
			Title = "AMENITIES",
			Rows = {
				{ Title = "Restaurants", Amount = tostring(breakdown.Restaurants) },
				{ Title = "Rentals", Amount = tostring(breakdown.Rentals) },
				{ Title = "Lodges", Amount = tostring(breakdown.Lodges) },
				{ Title = "Decor & Other", Amount = tostring(breakdown.Others) },
			},
		},
		{
			Title = "GUESTS",
			Rows = {
				{ Title = "Total guests", Amount = tostring(summary.Stats.TotalGuests) },
				{ Title = "Happy guests", Amount = tostring(summary.Stats.HappyGuests) },
				{ Title = "Hungry exits", Amount = tostring(summary.Stats.HungryGuests) },
				{ Title = "Reroutes / min", Amount = string.format("%.1f", summary.Operational.ReroutesPerMinute) },
			},
		},
		{
			Title = "RESORT",
			Rows = {
				{ Title = "Lifts", Amount = tostring(breakdown.Lifts) },
				{ Title = "Cleanliness", Amount = string.format("%d%%", summary.Operational.Cleanliness) },
				{ Title = "Dirty spots", Amount = tostring(summary.Operational.DirtyBuildings) },
				{ Title = "Janitors", Amount = tostring(summary.Operational.JanitorCoverage) },
			},
		},
	}
end

local function buildCategoryRatings(summary, breakdown)
	return {
		Amenities = roundHalf(summary.CategoryScores.Amenities or summary.Rating or 0),
		Quality = roundHalf(summary.CategoryScores.Quality or summary.Rating or 0),
		Crowdy = roundHalf(summary.CategoryScores.Crowdy or summary.Rating or 0),
		ResortSize = roundHalf(summary.CategoryScores.ResortSize or summary.Rating or 0),
	}
end

local function renderMetricPage(summary)
	if not ui.MetricFrame then
		return
	end
	local breakdown = countAmenityBreakdown(summary)
	local pages = buildMetricPages(summary, breakdown)
	if state.MetricPageIndex > #pages then
		state.MetricPageIndex = 1
	elseif state.MetricPageIndex < 1 then
		state.MetricPageIndex = #pages
	end
	local page = pages[state.MetricPageIndex]
	ui.MetricTitle.Text = page.Title
	for index, row in ipairs(ui.MetricRows) do
		local rowData = page.Rows[index]
		if row and rowData then
			local title = row:FindFirstChild("Title")
			local amount = row:FindFirstChild("Amount")
			if title and title:IsA("TextLabel") then
				title.Text = rowData.Title
			end
			if amount and amount:IsA("TextLabel") then
				amount.Text = rowData.Amount
			end
		end
	end
	return breakdown
end

local function renderCategoryRatings(summary, breakdown)
	local ratings = buildCategoryRatings(summary, breakdown)
	for key, row in pairs(ui.CategoryRows) do
		local starFrame = row and row:FindFirstChild("Rating")
		if starFrame and starFrame:IsA("Frame") then
			setStarRating(starFrame, ratings[key] or 0)
		end
	end

	local oldRating = state.LastRating
	local newRating = summary.Rating
	-- Only animate/show trend when the visual star display actually changes (rounded to nearest 0.5)
	local ratingChanged = oldRating ~= nil and roundHalf(newRating) ~= roundHalf(oldRating)

	-- Ensure Header bundle is built first so we can copy its images to TopBar if needed
	setStarRating(ui.HeaderStars, summary.Rating)

	-- TopBar (RatingButton) may not have Fill/Half/Empty children so its bundle ends up
	-- with blank images. Fully replace its bundle with the Header's so they are always identical.
	local headerBundle = starBundles[ui.HeaderStars]
	if headerBundle and headerBundle.Fill ~= "" then
		local topBarBundle = starBundles[ui.TopBarStars]
		if not topBarBundle or topBarBundle.Fill == "" then
			local topBarFrame = ui.TopBarStars
			for _, child in ipairs(topBarFrame:GetChildren()) do
				if string.find(child.Name, "^Star%d") then
					child:Destroy()
				end
			end
			local tbSize = headerBundle.Stars[1] and headerBundle.Stars[1].Size or UDim2.new(0.18, 0, 1, 0)
			local stars = {}
			for index = 1, 5 do
				local star = Instance.new("ImageLabel")
				star.Name = "Star" .. index
				star.BackgroundTransparency = 1
				star.BorderSizePixel = 0
				star.Size = tbSize
				star.ScaleType = Enum.ScaleType.Fit
				star.Parent = topBarFrame
				local aspect = Instance.new("UIAspectRatioConstraint")
				aspect.AspectRatio = 1
				aspect.Parent = star
				starOrigSizes[star] = tbSize
				stars[index] = star
			end
			starBundles[topBarFrame] = {
				Fill  = headerBundle.Fill,
				Half  = headerBundle.Half,
				Empty = headerBundle.Empty,
				Tint  = headerBundle.Tint,
				Stars = stars,
			}
		end
	end

	setStarRating(ui.TopBarStars, summary.Rating)

	-- Trend label only on the panel header
	if not ui.TrendLabel then
		ui.TrendLabel = ensureTrendLabel(ui.HeaderStars)
	end

	-- Fire animation and trend arrow only when rating actually changed
	if ratingChanged then
		animateStarPop(starBundles[ui.HeaderStars])
		animateStarPop(starBundles[ui.TopBarStars])
		updateTrendLabel(ui.TrendLabel, oldRating, newRating)
	end

	state.LastRating = newRating
end

-- Truncates text to at most maxLen characters, breaking on the last word boundary
-- so we never cut mid-word. Appends an ellipsis when text is shortened.
-- minLen is informational only (used so short texts are left untouched).
local function truncateBody(text, minLen, maxLen)
	text = tostring(text or "")
	if #text <= maxLen then
		return text
	end
	-- Find the last space at or before maxLen so we don't break a word
	local cut = string.sub(text, 1, maxLen)
	local wordBoundary = string.match(cut, "^(.*%S)%s+%S*$")
	if wordBoundary and #wordBoundary >= minLen then
		cut = wordBoundary
	else
		-- No clean boundary within the minimum — hard cut at maxLen
		cut = string.sub(text, 1, maxLen)
	end
	return cut .. "…"
end

local function renderReview(summary)
	local reviews = summary.Reviews
	if #reviews == 0 then
		reviews = getFallbackSummary().Reviews
	end
	local displayedReviewCount = 0
	for _, reviewEntry in ipairs(reviews) do
		if type(reviewEntry) == "table" and reviewEntry.IsPlaceholder ~= true then
			displayedReviewCount += 1
		end
	end
	local totalReviewCount = math.max(displayedReviewCount, tonumber(summary.ReviewCount) or 0)
	if state.ReviewIndex > #reviews then
		state.ReviewIndex = 1
	elseif state.ReviewIndex < 1 then
		state.ReviewIndex = #reviews
	end
	local review = reviews[state.ReviewIndex]
	local timestamp = os.time() - ((state.ReviewIndex - 1) * 2700)
	local badge = review.Badge and tostring(review.Badge) or "Guest Review"
	local dateText = string.format("%s  @ %s  •  %s", os.date("%m/%d/%Y", timestamp), os.date("%H:%M", timestamp), badge)

	-- Overview card shown at the bottom of the Rating page: 200–300 characters
	local overviewBody = truncateBody(tostring(review.Body or ""), 200, 300)
	if ui.ReviewBody then ui.ReviewBody.Text = overviewBody end
	if ui.ReviewName then ui.ReviewName.Text = tostring(review.Name or "Guest") end
	if ui.ReviewDate then ui.ReviewDate.Text = dateText end

	-- Summary panel card at the top of the Review page: 200–300 characters
	if ui.ReviewSummaryBody then ui.ReviewSummaryBody.Text = truncateBody(tostring(review.Body or ""), 200, 300) end
	if ui.ReviewSummaryName then ui.ReviewSummaryName.Text = tostring(review.Name or "Guest") end
	if ui.ReviewSummaryDate then ui.ReviewSummaryDate.Text = dateText end

	if ui.ReviewMore then
		if displayedReviewCount > 1 and totalReviewCount > displayedReviewCount then
			ui.ReviewMore.Text = string.format("View recent reviews (%d of %d)", displayedReviewCount, totalReviewCount)
		elseif displayedReviewCount > 1 then
			ui.ReviewMore.Text = string.format("View all reviews (%d)", displayedReviewCount)
		elseif totalReviewCount > displayedReviewCount then
			ui.ReviewMore.Text = string.format("View recent reviews (%d of %d)", displayedReviewCount, totalReviewCount)
		else
			ui.ReviewMore.Text = "View review"
		end
		ui.ReviewMore.AutoButtonColor = true
	end
	if ui.ReviewList and ui.ReviewListTemplate then
		ui.ReviewListTemplate.Visible = false
		if ui.ReviewSpacerTemplate then
			ui.ReviewSpacerTemplate.Visible = false
		end
		for _, child in ipairs(ui.ReviewList:GetChildren()) do
			if child:GetAttribute("GeneratedReviewItem") then
				child:Destroy()
			end
		end
		for index, entry in ipairs(reviews) do
			local card = ui.ReviewListTemplate:Clone()
			card.Name = string.format("Review_%d", index)
			card.LayoutOrder = (index * 2) - 1
			card.Visible = true
			card:SetAttribute("GeneratedReviewItem", true)
			local nameLabel = card:FindFirstChild("Name")
			local bodyLabel = card:FindFirstChild("Content")
			local dateLabel = card:FindFirstChild("Date")
			local ratingFrame = card:FindFirstChild("Rating")
			local entryTimestamp = os.time() - ((index - 1) * 2700)
			if nameLabel then nameLabel.Text = tostring(entry.Name or "Guest") end
			-- Scrolling frame list cards: 100–150 characters
			if bodyLabel then bodyLabel.Text = truncateBody(tostring(entry.Body or ""), 100, 150) end
			if dateLabel then
				local entryBadge = entry.Badge and tostring(entry.Badge) or "Guest Review"
				dateLabel.Text = string.format("%s  @ %s  •  %s", os.date("%m/%d/%Y", entryTimestamp), os.date("%H:%M", entryTimestamp), entryBadge)
			end
			if ratingFrame and ratingFrame:IsA("Frame") then
				setStarRating(ratingFrame, tonumber(entry.Stars) or summary.Rating or 0)
			end
			card.Parent = ui.ReviewList
			if index < #reviews and ui.ReviewSpacerTemplate then
				local spacer = ui.ReviewSpacerTemplate:Clone()
				spacer.Name = string.format("ZPadding_%d", index)
				spacer.LayoutOrder = 999999
				spacer.Visible = true
				spacer:SetAttribute("GeneratedReviewItem", true)
				spacer.Parent = ui.ReviewList
			end
		end
	end
end

local function renderSummary(summary)
	state.Summary = normalizeSummary(summary)
	ui.Title.Text = "RESORT RATINGS"
	local displayedReviewCount = 0
	for _, reviewEntry in ipairs(state.Summary.Reviews) do
		if type(reviewEntry) == "table" and reviewEntry.IsPlaceholder ~= true then
			displayedReviewCount += 1
		end
	end
	local totalReviewCount = math.max(displayedReviewCount, tonumber(state.Summary.ReviewCount) or 0)
	local subtitleText = string.format("%s • %d guest reviews", state.Summary.ReviewLabel, totalReviewCount)
	if displayedReviewCount > 0 and totalReviewCount > displayedReviewCount then
		subtitleText = string.format("%s • Showing %d of %d guest reviews", state.Summary.ReviewLabel, displayedReviewCount, totalReviewCount)
	end
	ui.Subtitle.Text = subtitleText
	local breakdown = renderMetricPage(state.Summary)
	renderCategoryRatings(state.Summary, breakdown)
	renderReview(state.Summary)
end

local function refreshSummary()
	if not RatingSummaryRequest or not RatingSummaryRequest:IsA("RemoteFunction") then
		renderSummary(getFallbackSummary())
		return
	end
	local ok, response = pcall(function()
		return RatingSummaryRequest:InvokeServer()
	end)
	if ok and type(response) == "table" then
		renderSummary(response)
	else
		renderSummary(state.Summary or getFallbackSummary())
	end
end

local function playTween(target, tweenInfo)
	if state.ActiveTween then
		state.ActiveTween:Cancel()
	end
	state.ActiveTween = TweenService:Create(RatingPanel, tweenInfo, { Position = target })
	state.ActiveTween:Play()
	return state.ActiveTween
end

local function setPanelOpen(open)
	if state.IsOpen == open then
		return
	end
	state.IsOpen = open
	if open then
		ClosePanels:Fire("Rating")
		RatingPanel.Visible = true
		RatingPanel.Active = true
		RatingPanel.Position = CLOSED_POSITION
		if ui.PageLayout and ui.RatingPage then
			ui.PageLayout:JumpTo(ui.RatingPage)
		end
		playTween(OPEN_POSITION, OPEN_TWEEN)
		refreshSummary()
	else
		local tween = playTween(CLOSED_POSITION, CLOSE_TWEEN)
		tween.Completed:Once(function()
			if not state.IsOpen then
				RatingPanel.Visible = false
			end
		end)
	end
end

local function connectUi()
	ui.MetricFrame = RatingPage:FindFirstChild("MiniStats")
	ui.CategoryFrame = RatingPage:FindFirstChild("Ratings")

	if ui.MetricFrame then
		local titleFrame = ui.MetricFrame:FindFirstChild("Title")
		if titleFrame then
			ui.MetricTitle = titleFrame:FindFirstChild("Title")
			ui.MetricPrevious = titleFrame:FindFirstChild("Previous")
			ui.MetricNext = titleFrame:FindFirstChild("Next")
		end
		for index = 1, 4 do
			ui.MetricRows[index] = ui.MetricFrame:FindFirstChild(tostring(index))
		end
	end

	if ui.CategoryFrame then
		for _, name in ipairs({ "Amenities", "Quality", "Crowdy", "ResortSize" }) do
			ui.CategoryRows[name] = ui.CategoryFrame:FindFirstChild(name)
		end
	end

	bindGuiButton(RatingButton, function()
		setPanelOpen(not state.IsOpen)
	end)
	bindGuiButton(ui.CloseButton, function()
		setPanelOpen(false)
	end)
	if ui.ReviewMore then
		bindGuiButton(ui.ReviewMore, function()
			if state.Summary then
				renderReview(state.Summary)
			end
			if ui.PageLayout and ui.ReviewPage then
				ui.PageLayout:JumpTo(ui.ReviewPage)
			end
		end)
	end
	if ui.ReviewBack then
		bindGuiButton(ui.ReviewBack, function()
			if ui.PageLayout and ui.RatingPage then
				ui.PageLayout:JumpTo(ui.RatingPage)
			end
		end)
	end
	if ui.MetricPrevious then
		bindGuiButton(ui.MetricPrevious, function()
			state.MetricPageIndex -= 1
			if state.MetricPageIndex < 1 then
				state.MetricPageIndex = 3
			end
			if state.Summary then
				renderSummary(state.Summary)
			end
		end)
	end
	if ui.MetricNext then
		bindGuiButton(ui.MetricNext, function()
			state.MetricPageIndex += 1
			if state.MetricPageIndex > 3 then
				state.MetricPageIndex = 1
			end
			if state.Summary then
				renderSummary(state.Summary)
			end
		end)
	end

	ClosePanels.Event:Connect(function(source)
		if source ~= "Rating" and state.IsOpen then
			setPanelOpen(false)
		end
	end)

	UserInputService.InputBegan:Connect(function(input, gameProcessed)
		if gameProcessed then
			return
		end
		if input.KeyCode == Enum.KeyCode.Escape and state.IsOpen and not UserInputService:GetFocusedTextBox() then
			setPanelOpen(false)
		end
	end)

	if RatingUpdate and RatingUpdate:IsA("RemoteEvent") then
		RatingUpdate.OnClientEvent:Connect(function()
			refreshSummary()
		end)
	end

	RatingPanel.AnchorPoint = Vector2.new(0.5, 0.5)
	RatingPanel.Position = CLOSED_POSITION
	RatingPanel.Visible = false
	RatingPanel.Active = true
	refreshSummary()

	task.spawn(function()
		while true do
			task.wait(20)
			if state.IsOpen then
				refreshSummary()
			end
		end
	end)
end

connectUi()