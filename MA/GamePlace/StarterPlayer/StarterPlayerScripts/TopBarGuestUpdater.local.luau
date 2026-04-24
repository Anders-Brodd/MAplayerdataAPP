--[=[ PATH: StarterPlayerScripts/TopBarUpdater | TYPE: LocalScript ]=]--

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local Lighting = game:GetService("Lighting")
local StarterGui = game:GetService("StarterGui")
local Workspace = game:GetService("Workspace")
local colorFromRGB = Color3.fromRGB

local Player = Players.LocalPlayer
local PlayerGui = Player:WaitForChild("PlayerGui")
local SlotData = ReplicatedStorage:FindFirstChild("SlotData") or ReplicatedStorage:WaitForChild("SlotData", 15)

local function TryRequire(moduleScript)
	if not moduleScript or not moduleScript:IsA("ModuleScript") then
		return nil
	end
	local ok, result = pcall(require, moduleScript)
	if ok then
		return result
	end
	return nil
end

local Config = TryRequire(ReplicatedStorage:FindFirstChild("Config"))
local GuestConfig = nil
do
	local guestFolder = ReplicatedStorage:FindFirstChild("Guest")
	GuestConfig =
		TryRequire(guestFolder and guestFolder:FindFirstChild("GuestConfig")) or
		TryRequire(guestFolder and guestFolder:FindFirstChild("guestconfig")) or
		TryRequire(ReplicatedStorage:FindFirstChild("GuestConfig")) or
		TryRequire(ReplicatedStorage:FindFirstChild("guestconfig"))
end

local lastServerGuestTick = 0
local lastServerRatingSummaryTick = 0
local cachedGuestCurrent = 0
local cachedGuestMax = 0
local cachedGuestMaxDirty = true
local cachedRating = nil
local cachedMoney = nil
local eventsBound = false
local guestCountBound = false
local ratingBound = false
local moneyBound = false

local function FormatNumber(num)
	local value = tonumber(num) or 0
	local absValue = math.abs(value)

	local function formatScaled(divisor, suffix)
		local scaled = value / divisor
		local text
		if math.abs(scaled) >= 100 then
			text = string.format("%.0f%s", scaled, suffix)
		else
			text = string.format("%.1f%s", scaled, suffix)
		end
		return text:gsub("%.0([KMBT])", "%1")
	end

	if absValue >= 1000000000 then
		return formatScaled(1000000000, "B")
	elseif absValue >= 1000000 then
		return formatScaled(1000000, "M")
	elseif absValue >= 1000 then
		return formatScaled(1000, "K")
	end

	return tostring(math.floor(value + (value >= 0 and 0.5 or -0.5)))
end

local function FindDescendantByName(root, name, className)
	if not root then return nil end
	for _, d in ipairs(root:GetDescendants()) do
		if d.Name == name and (not className or d:IsA(className)) then
			return d
		end
	end
	return nil
end

local function GetResortOwnerUserId()
	local ownerValue = SlotData and SlotData:FindFirstChild("UserId")
	local ownerUserId = ownerValue and tonumber(ownerValue.Value) or nil
	if ownerUserId and ownerUserId > 0 then
		return ownerUserId
	end
	return Player.UserId
end

local function ShouldUseLocalPlayerRating()
	return GetResortOwnerUserId() == Player.UserId
end

local function FindTopBarInGui(guiRoot)
	if not guiRoot then return nil end

	local topContainer = guiRoot:FindFirstChild("Top")
	if topContainer then
		local nestedTopBar = topContainer:FindFirstChild("TopBar")
		if nestedTopBar and nestedTopBar:IsA("Frame") then
			return nestedTopBar
		end
	end

	local directTopBar = guiRoot:FindFirstChild("TopBar")
	if directTopBar and directTopBar:IsA("Frame") then
		return directTopBar
	end

	return FindDescendantByName(guiRoot, "TopBar", "Frame")
end

local function GetTopBar()
	local mainHUD = PlayerGui:FindFirstChild("MainHUD")
	if mainHUD then
		local topBar = FindTopBarInGui(mainHUD)
		if topBar then
			return topBar
		end
	end

	for _, child in ipairs(PlayerGui:GetChildren()) do
		if child:IsA("ScreenGui") then
			local topBar = FindTopBarInGui(child)
			if topBar then
				return topBar
			end
		end
	end

	return nil
end

local function GetGuestsUI()
	local topBar = GetTopBar()
	if not topBar then return nil, nil end

	local guests = topBar:FindFirstChild("Guests") or FindDescendantByName(topBar, "Guests", "Frame")
	if not guests then return nil, nil end

	local value = guests:FindFirstChild("Value") or FindDescendantByName(guests, "Value", "TextLabel")
	local outOf = guests:FindFirstChild("Out of") or guests:FindFirstChild("OutOf") or FindDescendantByName(guests, "Out of", "TextLabel")

	return value, outOf
end

local function GetMoneyUI()
	local topBar = GetTopBar()
	if not topBar then return nil end
	local moneyFrame = topBar:FindFirstChild("Money") or FindDescendantByName(topBar, "Money", "Frame")
	if not moneyFrame then return nil end
	return moneyFrame:FindFirstChild("MoneyText") or FindDescendantByName(moneyFrame, "MoneyText", "TextLabel") or moneyFrame:FindFirstChildWhichIsA("TextLabel", true)
end

local function GetRatingUI()
	local topBar = GetTopBar()
	if not topBar then return nil end
	return topBar:FindFirstChild("Rating") or FindDescendantByName(topBar, "Rating", "Frame")
end

local function IsPlacedObjectRootModel(model, placed)
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

local function UpdateGuestCount(current, max)
	local valueLabel, outOfLabel = GetGuestsUI()
	if not valueLabel and not outOfLabel then return end

	local currentText = FormatNumber(current)
	local maxValue = math.max(0, tonumber(max) or 0)

	if valueLabel then
		valueLabel.Text = currentText .. " /"
	end
	if outOfLabel then
		outOfLabel.Text = " " .. FormatNumber(maxValue)
	end
end

local function UpdateMoney(amount)
	local moneyLabel = GetMoneyUI()
	if not moneyLabel then return end
	moneyLabel.Text = "$ " .. FormatNumber(amount)
end

local function GetStarSlots(ratingFrame)
	local slots = {}
	local fallbackSlots = {}
	local fillImage = nil
	local halfImage = nil
	local emptyImage = nil

	for _, child in ipairs(ratingFrame:GetChildren()) do
		if child:IsA("ImageLabel") then
			table.insert(fallbackSlots, child)
			local name = string.lower(child.Name)
			if name == "fill" or name == "half" or name == "empty" then
				table.insert(slots, child)
				if name == "fill" and not fillImage then fillImage = child.Image end
				if name == "half" and not halfImage then halfImage = child.Image end
				if name == "empty" and not emptyImage then emptyImage = child.Image end
			end
		end
	end

	local function sortSlots(list)
		table.sort(list, function(a, b)
			if a.LayoutOrder ~= b.LayoutOrder then
				return a.LayoutOrder < b.LayoutOrder
			end
			if a.AbsolutePosition.X ~= b.AbsolutePosition.X then
				return a.AbsolutePosition.X < b.AbsolutePosition.X
			end
			return a.Name < b.Name
		end)
	end

	sortSlots(slots)
	sortSlots(fallbackSlots)

	if #slots == 0 then
		slots = fallbackSlots

		local starterMainHUD = StarterGui:FindFirstChild("MainHUD")
		local starterRating = starterMainHUD and starterMainHUD:FindFirstChild("Top") and starterMainHUD.Top:FindFirstChild("TopBar") and starterMainHUD.Top.TopBar:FindFirstChild("Rating")
		if starterRating then
			for _, child in ipairs(starterRating:GetChildren()) do
				if child:IsA("ImageLabel") then
					local name = string.lower(child.Name)
					if name == "fill" and not fillImage then fillImage = child.Image end
					if name == "half" and not halfImage then halfImage = child.Image end
					if name == "empty" and not emptyImage then emptyImage = child.Image end
				end
			end
		end

		if #fallbackSlots > 0 then
			emptyImage = emptyImage or fallbackSlots[#fallbackSlots].Image
			for _, slot in ipairs(fallbackSlots) do
				if slot.Image ~= emptyImage then
					fillImage = fillImage or slot.Image
					break
				end
			end
			fillImage = fillImage or fallbackSlots[1].Image
			halfImage = halfImage or fillImage
		end
	end

	return slots, fillImage, halfImage, emptyImage
end

local function GetRatingPalette(rating)
	return Color3.fromRGB(248, 210, 72), Color3.fromRGB(224, 182, 54), Color3.fromRGB(126, 98, 28), Color3.fromRGB(24, 18, 8)
end

local function IsOwnedByResortOwner(model)
	if not model then return false end
	local ownerUserId = GetResortOwnerUserId()
	local ownerAttr = model:GetAttribute("Owner")
	local ownerNum = tonumber(ownerAttr)
	if ownerNum ~= nil then
		return ownerNum == ownerUserId
	end
	return ownerAttr == nil and ownerUserId == Player.UserId
end

local function ComputeLocalResortActivity()
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

	for _, obj in ipairs(placed:GetChildren()) do
		if obj:IsA("Model") and IsOwnedByResortOwner(obj) then
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

local function ClampDisplayedRating(rating)
	rating = math.clamp(tonumber(rating) or 0, 0, 5)
	local currentGuests = cachedGuestCurrent
	if currentGuests == nil then
		currentGuests = 0
	end
	local activity = ComputeLocalResortActivity()
	local amenityCount = activity.BuiltLifts + activity.Food + activity.Lodging

	if currentGuests <= 0 then
		if amenityCount <= 0 then
			return 0
		end
		if activity.RunningLifts <= 0 then
			local idleCap = math.min(3.25, 1.45 + (math.min(amenityCount, 6) * 0.32))
			return math.min(rating, idleCap)
		end
		local waitingCap = math.min(4.35, 2.65 + (math.min(activity.RunningLifts, 4) * 0.28) + (math.min(activity.Food + activity.Lodging, 5) * 0.12))
		return math.min(rating, waitingCap)
	end

	return rating
end

local function ApplyRatingVisuals(rating)
	local ratingFrame = GetRatingUI()
	if not ratingFrame then return end

	rating = ClampDisplayedRating(rating)
	local slots, fillImage, halfImage, emptyImage = GetStarSlots(ratingFrame)
	if #slots == 0 then return end

	fillImage = fillImage or emptyImage or ""
	halfImage = halfImage or fillImage
	emptyImage = emptyImage or fillImage

	local fillColor, halfColor, emptyColor, frameColor = GetRatingPalette(rating)
	ratingFrame.BackgroundColor3 = frameColor

	local scaledRating = (rating / 5) * #slots
	for i, slot in ipairs(slots) do
		local slotFill = scaledRating - (i - 1)
		local image = emptyImage
		local tint = emptyColor
		if slotFill >= 1 then
			image = fillImage
			tint = fillColor
		elseif slotFill >= 0.5 then
			image = halfImage
			tint = halfColor
		end

		if image and image ~= "" then
			slot.Image = image
		end
		slot.ImageColor3 = tint
		slot.Visible = true
	end
end

local ratingWarningShown = false
local function UpdateRating(rating)
	local ok, err = pcall(ApplyRatingVisuals, rating)
	if not ok and not ratingWarningShown then
		ratingWarningShown = true
		warn("[TopBarGuestUpdater] Failed to update rating UI: " .. tostring(err))
	end
end

local function RefreshRatingFromServerSummary(force)
	if ShouldUseLocalPlayerRating() then
		return false
	end
	if not force and (tick() - lastServerRatingSummaryTick) < 4 then
		return false
	end

	local events = ReplicatedStorage:FindFirstChild("Events")
	local request = events and events:FindFirstChild("RatingSummaryRequest")
	if not request or not request:IsA("RemoteFunction") then
		return false
	end

	local ok, summary = pcall(function()
		return request:InvokeServer()
	end)
	if ok and type(summary) == "table" then
		cachedRating = tonumber(summary.Rating) or cachedRating
		lastServerRatingSummaryTick = tick()
		if cachedRating ~= nil then
			UpdateRating(cachedRating)
		end
		return true
	end

	return false
end

local function GetHourDemandMultiplier(hour)
	hour = (tonumber(hour) or 12) % 24
	local curve = GuestConfig and GuestConfig.Spawn and GuestConfig.Spawn.HourlyDemandCurve
	if type(curve) ~= "table" or #curve < 2 then
		if hour >= 16 and hour < 21 then return 1.25 end
		if hour >= 6 and hour < 11 then return 0.85 end
		if hour >= 22 or hour < 5 then return 0.35 end
		return 1.0
	end

	local prev = curve[1]
	for i = 2, #curve do
		local point = curve[i]
		local prevHour = tonumber(prev.Hour) or 0
		local pointHour = tonumber(point.Hour) or prevHour
		if hour <= pointHour then
			local span = math.max(0.001, pointHour - prevHour)
			local alpha = math.clamp((hour - prevHour) / span, 0, 1)
			local prevMult = tonumber(prev.Mult) or 1
			local pointMult = tonumber(point.Mult) or prevMult
			return prevMult + ((pointMult - prevMult) * alpha)
		end
		prev = point
	end

	local first = curve[1]
	local lastHour = tonumber(prev.Hour) or 24
	local firstHour = (tonumber(first.Hour) or 0) + 24
	local span = math.max(0.001, firstHour - lastHour)
	local wrappedHour = hour
	if wrappedHour < (tonumber(first.Hour) or 0) then
		wrappedHour += 24
	end
	local alpha = math.clamp((wrappedHour - lastHour) / span, 0, 1)
	local prevMult = tonumber(prev.Mult) or 1
	local firstMult = tonumber(first.Mult) or prevMult
	return prevMult + ((firstMult - prevMult) * alpha)
end

local function GetSeasonDemandMultiplier()
	local map = GuestConfig and GuestConfig.Spawn and GuestConfig.Spawn.SeasonDemandMultiplier or nil
	if type(map) ~= "table" then return 1 end

	local season = tostring(Lighting:GetAttribute("Season") or "Winter")
	if map[season] ~= nil then
		return tonumber(map[season]) or 1
	end

	local lowerSeason = string.lower(season)
	for key, value in pairs(map) do
		if string.lower(tostring(key)) == lowerSeason then
			return tonumber(value) or 1
		end
	end
	return 1
end

local function IsHotelModel(model)
	if not model or not model:IsA("Model") then return false, nil end

	local objType = model:GetAttribute("Type")
	local objCategory = model:GetAttribute("Category")
	local itemCfg = Config and Config.Items and Config.Items[model.Name] or nil
	local attrCapacity = tonumber(model:GetAttribute("Capacity")) or 0
	local cfgType = itemCfg and itemCfg.Type
	local cfgCategory = itemCfg and itemCfg.Category

	local matches =
		objType == "House" or objType == "Hotel" or
		cfgType == "House" or cfgType == "Hotel" or
		objCategory == "House" or objCategory == "Hotel" or
		cfgCategory == "House" or cfgCategory == "Hotel" or
		objCategory == "Housing" or cfgCategory == "Housing" or
		objCategory == "Accommodation" or cfgCategory == "Accommodation"

	if not matches and ((itemCfg and itemCfg.Capacity and itemCfg.Capacity > 0) or attrCapacity > 0) then
		matches = true
	end

	return matches, itemCfg, attrCapacity
end

local function ComputeLocalGuestCount()
	local current = 0
	local guestsFolder = Workspace:FindFirstChild("Guests")
	if guestsFolder then
		for _, child in ipairs(guestsFolder:GetChildren()) do
			if child:IsA("Model") then
				local ownerId = tonumber(child:GetAttribute("OwnerId"))
				if ownerId == GetResortOwnerUserId() then
					current += 1
				end
			end
		end
	end
	return current
end

local function ComputeLocalGuestMax()
	local maxGuests = 0
	local placed = Workspace:FindFirstChild("PlacedObjects")
	if placed then
		local guestsPerBed = GuestConfig and GuestConfig.Spawn and GuestConfig.Spawn.MaxGuestsPerHotelBed or 3.5
		for _, obj in ipairs(placed:GetChildren()) do
			if obj:IsA("Model") and IsOwnedByResortOwner(obj) then
				local isHotel, itemCfg, attrCapacity = IsHotelModel(obj)
				if isHotel then
					local capacity = (itemCfg and itemCfg.Capacity) or attrCapacity or 2
					local beds = math.max(1, math.floor(capacity * guestsPerBed))
					maxGuests += beds
				end
			end
		end
	end

	local passMultiplier = tonumber(Player:GetAttribute("GuestPassMultiplier")) or 1
	if passMultiplier <= 0 then
		passMultiplier = 1
	end
	if passMultiplier > 1 then
		maxGuests = math.floor((maxGuests * passMultiplier) + 0.5)
	end

	local perPlayerCap = GuestConfig and GuestConfig.Spawn and GuestConfig.Spawn.MaxGlobalGuests or 0
	if perPlayerCap and perPlayerCap > 0 then
		if passMultiplier > 1 then
			perPlayerCap = math.floor((perPlayerCap * passMultiplier) + 0.5)
		end
		maxGuests = math.min(maxGuests, perPlayerCap)
	end

	local capEnabled = Player:GetAttribute("GuestCapEnabled") == true
	local userCap = tonumber(Player:GetAttribute("GuestCap")) or 0
	if capEnabled then
		if userCap <= 0 then
			userCap = 500
		end
		if maxGuests > 0 then
			maxGuests = math.min(maxGuests, userCap)
		else
			maxGuests = userCap
		end
	end

	cachedGuestMax = maxGuests
	cachedGuestMaxDirty = false
	return maxGuests
end

local function GetLocalGuestMax()
	if cachedGuestMaxDirty then
		return ComputeLocalGuestMax()
	end
	return cachedGuestMax
end

local function BindEvents(events)
	if eventsBound or not events then return end
	eventsBound = true

	local function BindGuestCountEvent(remote)
		if guestCountBound or not remote or not remote:IsA("RemoteEvent") then return end
		guestCountBound = true
		remote.OnClientEvent:Connect(function(current, max)
			if GetResortOwnerUserId() ~= Player.UserId then
				cachedGuestCurrent = ComputeLocalGuestCount()
				cachedGuestMax = GetLocalGuestMax()
				UpdateGuestCount(cachedGuestCurrent, cachedGuestMax)
				return
			end
			cachedGuestCurrent = tonumber(current) or 0
			cachedGuestMax = tonumber(max) or 0
			lastServerGuestTick = tick()
			UpdateGuestCount(cachedGuestCurrent, cachedGuestMax)
		end)
	end

	local function BindRatingEvent(remote)
		if ratingBound or not remote or not remote:IsA("RemoteEvent") then return end
		ratingBound = true
		remote.OnClientEvent:Connect(function(rating)
			if ShouldUseLocalPlayerRating() then
				cachedRating = tonumber(rating) or cachedRating
				UpdateRating(cachedRating)
			else
				cachedRating = tonumber(rating) or cachedRating
				if not RefreshRatingFromServerSummary(true) and cachedRating ~= nil then
					UpdateRating(cachedRating)
				end
			end
		end)
	end

	BindGuestCountEvent(events:FindFirstChild("GuestCountUpdate"))
	BindRatingEvent(events:FindFirstChild("RatingUpdate"))

	local placedObjects = Workspace:FindFirstChild("PlacedObjects")
	if placedObjects then
		placedObjects.ChildAdded:Connect(function()
			cachedGuestMaxDirty = true
		end)
		placedObjects.ChildRemoved:Connect(function()
			cachedGuestMaxDirty = true
		end)
	end

	events.ChildAdded:Connect(function(child)
		if child.Name == "GuestCountUpdate" then
			BindGuestCountEvent(child)
		elseif child.Name == "RatingUpdate" then
			BindRatingEvent(child)
		end
	end)

	-- Backward compat if events folder existed but remotes were delayed.
	if not guestCountBound then
		local guestCountEvent = events:WaitForChild("GuestCountUpdate", 10)
		if guestCountEvent and guestCountEvent:IsA("RemoteEvent") then
			BindGuestCountEvent(guestCountEvent)
		end
	end
	if not ratingBound then
		local ratingEvent = events:WaitForChild("RatingUpdate", 10)
		if ratingEvent and ratingEvent:IsA("RemoteEvent") then
			BindRatingEvent(ratingEvent)
		end
	end
end

BindEvents(ReplicatedStorage:FindFirstChild("Events"))
ReplicatedStorage.ChildAdded:Connect(function(child)
	if child.Name == "Events" and child:IsA("Folder") then
		BindEvents(child)
	end
end)

local function BindLeaderstatsAndMoney()
	if moneyBound then return end
	local leaderstats = Player:FindFirstChild("leaderstats") or Player:WaitForChild("leaderstats", 15)
	if not leaderstats then return end

	local ratingValue = leaderstats:FindFirstChild("Rating")
	if not ratingValue then
		ratingValue = leaderstats:WaitForChild("Rating", 15)
	end
	if ratingValue and ShouldUseLocalPlayerRating() then
		cachedRating = tonumber(ratingValue.Value) or cachedRating
		UpdateRating(cachedRating)
		ratingValue.Changed:Connect(function(newVal)
			cachedRating = tonumber(newVal) or cachedRating
			UpdateRating(cachedRating)
		end)
	end

	local cashValue = leaderstats:FindFirstChild("Cash") or leaderstats:WaitForChild("Cash", 15)
	if cashValue then
		moneyBound = true
		cachedMoney = tonumber(Player:GetAttribute("Money")) or tonumber(cashValue.Value) or cachedMoney or 0
		UpdateMoney(cachedMoney)
		cashValue.Changed:Connect(function(newVal)
			cachedMoney = tonumber(newVal) or tonumber(Player:GetAttribute("Money")) or cachedMoney or 0
			UpdateMoney(cachedMoney)
		end)
	end
end

Player:GetAttributeChangedSignal("Money"):Connect(function()
	cachedMoney = tonumber(Player:GetAttribute("Money")) or cachedMoney or 0
	UpdateMoney(cachedMoney)
end)

Player:GetAttributeChangedSignal("GuestCap"):Connect(function()
	cachedGuestMaxDirty = true
end)

Player:GetAttributeChangedSignal("GuestCapEnabled"):Connect(function()
	cachedGuestMaxDirty = true
end)

Player.ChildAdded:Connect(function(child)
	if child.Name == "leaderstats" then
		task.defer(BindLeaderstatsAndMoney)
	end
end)

cachedMoney = tonumber(Player:GetAttribute("Money")) or cachedMoney
if cachedMoney ~= nil then
	UpdateMoney(cachedMoney)
end

task.defer(BindLeaderstatsAndMoney)

-- Fallback updater for guest count/max when server event is missing or stale.
task.spawn(function()
	local lastSummaryRefresh = 0
	while true do
		task.wait(2)
		local now = tick()
		if now - lastServerGuestTick > 3 then
			cachedGuestCurrent = ComputeLocalGuestCount()
			local fallbackMax = GetLocalGuestMax()
			if cachedGuestMax and cachedGuestMax > 0 then
				fallbackMax = math.max(fallbackMax, cachedGuestMax)
			end
			cachedGuestMax = fallbackMax
			UpdateGuestCount(cachedGuestCurrent, cachedGuestMax)
		end
		if cachedMoney == nil then
			cachedMoney = tonumber(Player:GetAttribute("Money"))
			local leaderstats = Player:FindFirstChild("leaderstats")
			local cashValue = leaderstats and leaderstats:FindFirstChild("Cash")
			if cachedMoney == nil and cashValue then
				cachedMoney = tonumber(cashValue.Value)
			end
		end
		if cachedMoney ~= nil then
			UpdateMoney(cachedMoney)
		end
		if ShouldUseLocalPlayerRating() then
			if cachedRating ~= nil then
				UpdateRating(cachedRating)
			end
		elseif now - lastSummaryRefresh >= 4 then
			lastSummaryRefresh = now
			RefreshRatingFromServerSummary(false)
		end
	end
end)

-- Initial paint
cachedGuestCurrent = ComputeLocalGuestCount()
cachedGuestMax = GetLocalGuestMax()
UpdateGuestCount(cachedGuestCurrent, cachedGuestMax)
if cachedMoney ~= nil then
	UpdateMoney(cachedMoney)
end
if ShouldUseLocalPlayerRating() then
	if cachedRating ~= nil then
		UpdateRating(cachedRating)
	end
else
	RefreshRatingFromServerSummary(true)
end

task.spawn(function()
	local MarketplaceService = game:GetService("MarketplaceService")
	local passId = 1708162428 -- 2x Guests Gamepass
	
	-- Retry logic to find the More button
	for attempt = 1, 30 do
		local topBar = GetTopBar()
		if topBar then
			local guests = topBar:FindFirstChild("Guests") or FindDescendantByName(topBar, "Guests", "Frame")
			if guests then
				local moreBtn = guests:FindFirstChild("More")
				if moreBtn and moreBtn:IsA("GuiButton") then
					-- Found it! Hook the click event
					moreBtn.MouseButton1Click:Connect(function()
						pcall(function()
							MarketplaceService:PromptGamePassPurchase(Player, passId)
						end)
					end)
					print("[TopBarGuestUpdater] Successfully hooked 2x Guests gamepass to TopBar.Guests.More button")
					break
				end
			end
		end
		
		if attempt == 30 then
			warn("[TopBarGuestUpdater] Could not find TopBar.Guests.More button after 30 attempts")
		end
		
		task.wait(0.5)
	end
end)

print("TopBarGuestUpdater Online")
