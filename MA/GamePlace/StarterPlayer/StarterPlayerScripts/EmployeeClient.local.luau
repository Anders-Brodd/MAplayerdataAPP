--[=[ PATH: StarterPlayerScripts/EmployeeClient | TYPE: LocalScript ]=]--
--[[
	SCRIPT DESCRIPTION:
	Connects the physical Studio-built unified 3-column Staff UI to the server, processing real-time employee data and handling interactions. 

	CHANGES (ADDED/REMOVED):
	- ADDED: Forced `Visible = false` on `EmployeesFrame`, `Template_HireCard`, and `Template_EmpRow` right at initialization to permanently clean up the screen state.
	- ADDED: 5-second timeouts to `WaitForChild` for critical templates to bypass script freezing if names mismatch.
	- ADDED: Client-side pathfinding network. Listens for "TargetPosition" updates from the server and fluidly pathfinds/moves the AI locally to stop stutter walking.
	- CHANGED: InfoBox split into InfoStat (label column) and InfoValue (value column) TextLabels.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local MarketplaceService = game:GetService("MarketplaceService")
local UserInputService = game:GetService("UserInputService")
local GuiService = game:GetService("GuiService")
local PathfindingService = game:GetService("PathfindingService")
local RunService = game:GetService("RunService")

local Player = Players.LocalPlayer
local PlayerGui = Player:WaitForChild("PlayerGui")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local ProceduralSkiAnimator = require(Shared:WaitForChild("ProceduralSkiAnimator"))
local SkiStateSchema = require(Shared:WaitForChild("SkiStateSchema"))

local Config = require(ReplicatedStorage:WaitForChild("EmployeeConfig"))
local Settings = Config.Settings

local EntitlementManager = nil
do
	local ok, moduleOrErr = pcall(function() return require(ReplicatedStorage:WaitForChild("EntitlementManager")) end)
	if ok then EntitlementManager = moduleOrErr end
end

local EMPLOYEE_PASSES = (Config.Gamepasses or Config.Passes or {})
local DOUBLE_EMPLOYEES_PASS_ID = tonumber(EMPLOYEE_PASSES.DoubleEmployees) or 0
local UNLIMITED_EMPLOYEES_PASS_ID = tonumber(EMPLOYEE_PASSES.UnlimitedEmployees) or 0

local themeBackground = Color3.fromRGB(20, 20, 22)
local themeText = Color3.fromRGB(255, 255, 255)
local themeSubText = Color3.fromRGB(150, 150, 150)

local GamepassInfo = { HasDouble = false, HasUnlimited = false }
local LastSlotEmployeePassFlags = nil
local LastWeather = "Clear"
local LastTemperature = 30

local Events = ReplicatedStorage:WaitForChild("Events", 10)
local EntitlementEvents = ReplicatedStorage:FindFirstChild("EntitlementEvents")
local EntitlementChanged = EntitlementEvents and EntitlementEvents:FindFirstChild("EntitlementChanged")
if not Events then return end

local HireEvent = Events:WaitForChild("EmployeeHire", 10)
local HireResultEvent = Events:WaitForChild("EmployeeHireResult", 10)
local ManageEvent = Events:WaitForChild("EmployeeManage", 10)
local SyncEvent = Events:WaitForChild("EmployeeSync", 10)
local InspectEvent = Events:WaitForChild("EmployeeInspect", 10)

if not (HireEvent and HireResultEvent and ManageEvent and SyncEvent and InspectEvent) then return end

local ClientNotification = ReplicatedStorage:FindFirstChild("ClientNotification")
local function ShowEmployeeNotice(kind, title, message, duration)
	if ClientNotification and ClientNotification:IsA("BindableEvent") then
		ClientNotification:Fire(kind or "Info", title or "Employees", message or "", duration or 2.5)
	end
end

local AllEmployees = {}
local MyEmployees = {}
local isMenuOpen = false
local selectedEmployee = nil
local OwnerUserId = 0
local HirePendingByType = {}
local HireFlashByType = {}
local manageActionBusy = false
local HIRE_REQUEST_TIMEOUT = 2.5
local FEEDBACK_DURATION = 1.2
local HIRE_FLASH_STYLES = {
	TooFast = { text = "WAIT", color = Color3.fromRGB(180, 140, 40) },
	NotOwner = { text = "OWNER ONLY", color = Color3.fromRGB(180, 70, 70) },
	InvalidType = { text = "ERROR", color = Color3.fromRGB(180, 70, 70) },
	TypeFull = { text = "FULL", color = Color3.fromRGB(100, 100, 110) },
	UpgradeCap = { text = "BUY UNLIMITED", color = Color3.fromRGB(210, 140, 40) },
	TotalFull = { text = "MAX STAFF", color = Color3.fromRGB(100, 100, 110) },
	NoFunds = { text = "NO CASH", color = Color3.fromRGB(180, 70, 70) },
	NoAssignment = { text = "NEEDS BUILDING", color = Color3.fromRGB(180, 140, 40) },
	SpawnFailed = { text = "TRY AGAIN", color = Color3.fromRGB(180, 70, 70) },
}

local SlotData = ReplicatedStorage:FindFirstChild("SlotData")
if SlotData then
	local UserIdVal = SlotData:FindFirstChild("UserId")
	if UserIdVal then
		OwnerUserId = UserIdVal.Value
		UserIdVal.Changed:Connect(function(newVal) OwnerUserId = newVal end)
	end
end

local function IsMyEmployee(emp)
	if type(emp) ~= "table" then return false end
	local ownerId = tonumber(emp.OwnerId)
	if not ownerId then return false end
	if ownerId == Player.UserId then return true end
	if OwnerUserId ~= 0 and ownerId == OwnerUserId then return true end
	return false
end

local function bindGuiButton(button, callback)
	if not (button and button:IsA("GuiButton")) then return false end
	if button:GetAttribute("EmployeeBound") then return false end
	button:SetAttribute("EmployeeBound", true)
	button.Active = true
	button.Selectable = true
	button.AutoButtonColor = true
	local busy = false
	local function fire()
		if busy then return end
		busy = true
		callback()
		task.delay(0.2, function()
			busy = false
		end)
	end
	button.Activated:Connect(fire)
	return true
end

-- Physical UI Hooks (Hardened) - EmployeesFrame is now inside MainHUD
local MainHUD = PlayerGui:WaitForChild("MainHUD", 10)
local EmployeesFrame = MainHUD:WaitForChild("EmployeesFrame", 5)
if not EmployeesFrame then return end

EmployeesFrame.Visible = false -- Force hidden at startup
local EMPLOYEES_HIDDEN_POSITION = UDim2.new(0.5, 0, 1.55, 0)
local EMPLOYEES_VISIBLE_POSITION = UDim2.new(0.5, 0, 0.5, 0)
local EMPLOYEES_OPEN_TWEEN = TweenInfo.new(0.3, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local EMPLOYEES_CLOSE_TWEEN = TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
EmployeesFrame.Position = EMPLOYEES_HIDDEN_POSITION

local function getViewportSize()
	local camera = workspace.CurrentCamera
	if camera and camera.ViewportSize.X > 0 and camera.ViewportSize.Y > 0 then
		return camera.ViewportSize
	end
	return Vector2.new(1280, 720)
end

local GridContainer, BottomContainer, RosterBox, InfoBox, ActionBox, InfoTitle, InfoStat, InfoValue, FireBtn, UpgradeBtn, TpToBtn, EmployeesHeader, SummaryLabel, ExitBtn

local function applyResponsiveEmployeesLayout()
	local viewport = getViewportSize()
	local shortSide = math.min(viewport.X, viewport.Y)
	local compact = UserInputService.TouchEnabled and shortSide <= 1100
	local aspect = EmployeesFrame:FindFirstChildOfClass("UIAspectRatioConstraint")
	if aspect then
		aspect:Destroy()
	end
	EmployeesFrame.Size = compact and UDim2.new(0.9, 0, 0.76, 0) or UDim2.new(0.538200736, 0, 0.55, 0)
	if SummaryLabel then
		SummaryLabel.AnchorPoint = Vector2.new(1, 0.5)
		SummaryLabel.Position = UDim2.new(1, compact and -88 or -74, 0.5, 0)
		SummaryLabel.Size = UDim2.fromOffset(compact and 176 or 154, compact and 22 or 18)
		SummaryLabel.TextXAlignment = Enum.TextXAlignment.Right
	end
	if RosterBox then
		RosterBox.Active = true
		RosterBox.Selectable = true
		RosterBox.ScrollingDirection = Enum.ScrollingDirection.Y
		RosterBox.ScrollBarThickness = compact and 8 or 6
	end
	if GridContainer then
		GridContainer.Active = true
		GridContainer.Selectable = true
		GridContainer.ScrollingDirection = Enum.ScrollingDirection.Y
	end
end

local function IsEmployeesMenuOpen() return isMenuOpen or EmployeesFrame.Visible end

local Body = EmployeesFrame:WaitForChild("Body")
GridContainer = Body:WaitForChild("GridContainer")
BottomContainer = Body:WaitForChild("BottomContainer")
RosterBox = BottomContainer:WaitForChild("RosterBox")
InfoBox = BottomContainer:WaitForChild("InfoBox")
ActionBox = BottomContainer:WaitForChild("ActionBox")

InfoTitle = InfoBox:WaitForChild("InfoTitle")
InfoStat  = InfoBox:WaitForChild("InfoStat")
InfoValue = InfoBox:WaitForChild("InfoValue")

FireBtn = ActionBox:WaitForChild("FireBtn")
UpgradeBtn = ActionBox:WaitForChild("UpgradeBtn")
TpToBtn = ActionBox:WaitForChild("TpToBtn")

EmployeesHeader = EmployeesFrame:FindFirstChild("Header")
SummaryLabel = EmployeesHeader and EmployeesHeader:FindFirstChild("Summary")
ExitBtn = EmployeesHeader and EmployeesHeader:FindFirstChild("CloseButton")
applyResponsiveEmployeesLayout()

local TemplateCard = GridContainer:FindFirstChild("Template_HireCard") or GridContainer:WaitForChild("Template_HireCard", 5)
local HireGridLayout = GridContainer:FindFirstChildOfClass("UIGridLayout")
if HireGridLayout then
	HireGridLayout.SortOrder = Enum.SortOrder.LayoutOrder
end
for _, child in ipairs(GridContainer:GetChildren()) do
	if child.Name == "Template_HireCard" and child:IsA("GuiObject") then
		if child ~= TemplateCard then
			child:Destroy()
		else
			child.Visible = false
			child.LayoutOrder = -9999
		end
	end
end
if TemplateCard then TemplateCard.Visible = false end
local function refreshHireGridCanvas()
	if HireGridLayout then
		task.defer(function()
			GridContainer.CanvasSize = UDim2.new(0, 0, 0, HireGridLayout.AbsoluteContentSize.Y + 20)
		end)
	end
end
local TemplateRow = RosterBox:FindFirstChild("Template_EmpRow") or RosterBox:FindFirstChild("EmpRow") or RosterBox:WaitForChild("Template_EmpRow", 5) or RosterBox:FindFirstChild("EmpRow")
if TemplateRow then TemplateRow.Visible = false end

local function setEmployeesMenuState(open)
	if isMenuOpen == open and EmployeesFrame.Visible == open then return end
	isMenuOpen = open
	if open then
		applyResponsiveEmployeesLayout()
		EmployeesFrame.Visible = true
		EmployeesFrame.Position = EMPLOYEES_HIDDEN_POSITION
		if RosterBox then
			RosterBox.CanvasPosition = Vector2.new(0, 0)
		end
		if GridContainer then
			GridContainer.CanvasPosition = Vector2.new(0, 0)
		end
		TweenService:Create(EmployeesFrame, EMPLOYEES_OPEN_TWEEN, {Position = EMPLOYEES_VISIBLE_POSITION}):Play()
		return
	end
	local tween = TweenService:Create(EmployeesFrame, EMPLOYEES_CLOSE_TWEEN, {Position = EMPLOYEES_HIDDEN_POSITION})
	tween:Play()
	tween.Completed:Once(function() if not isMenuOpen then EmployeesFrame.Visible = false end end)
end

local function FormatMoney(n) return n >= 1000 and string.format("$%.1fK", n/1000) or "$" .. n end

local function HasUnlimitedEmployeeCap()
	return GamepassInfo.HasUnlimited or GamepassInfo.HasDouble
end

local function GetMaxPerTypeForUI()
	if HasUnlimitedEmployeeCap() then return 9999 end
	return Settings.MaxPerType
end

local function GetCountByType(t)
	local c = 0
	for _,e in ipairs(MyEmployees) do if e.Type == t then c = c + 1 end end
	return c
end

local function GetMaxTotalForUI()
	if HasUnlimitedEmployeeCap() then return 9999 end
	return Settings.MaxTotal
end

local function GetTotalEmployeeCount() return #MyEmployees end

local function UpdateStaffSummary()
	if not SummaryLabel then return end
	local maxTotal = GetMaxTotalForUI()
	local maxText = HasUnlimitedEmployeeCap() and "UNL" or tostring(maxTotal)
	SummaryLabel.Text = string.format("STAFF %d / %s", GetTotalEmployeeCount(), maxText)
end

local function BuildRosterSignature(list)
	local parts = table.create(#list)
	for i, emp in ipairs(list) do
		parts[i] = table.concat({
			tostring(emp.UUID or ""),
			tostring(emp.OwnerId or 0),
			tostring(emp.Type or ""),
			tostring(emp.Level or 1),
		}, "|")
	end
	return table.concat(parts, ";")
end

local LastRosterRenderSignature = ""
local LastDoublePassPromptAt = 0
local DOUBLE_PASS_PROMPT_COOLDOWN = 1.5

local _purchasedUnlimitedThisSession = false
local function CanOfferDoubleCapUpgrade()
	if _purchasedUnlimitedThisSession then return false end
	return DOUBLE_EMPLOYEES_PASS_ID > 0 and not HasUnlimitedEmployeeCap()
end

local function PromptDoubleCapUpgrade()
	if not CanOfferDoubleCapUpgrade() then return false end
	local now = os.clock()
	if (now - LastDoublePassPromptAt) < DOUBLE_PASS_PROMPT_COOLDOWN then return false end
	LastDoublePassPromptAt = now
	local ok, err = pcall(function() MarketplaceService:PromptGamePassPurchase(Player, DOUBLE_EMPLOYEES_PASS_ID) end)
	return ok
end

local function ShouldMergeLocalEntitlementsForStaffCaps()
	if OwnerUserId == 0 then
		return true
	end
	return Player.UserId == OwnerUserId
end

local function MergeLocalPlayerEntitlementPasses()
	if not EntitlementManager then
		return
	end
	local userId = Player.UserId
	if DOUBLE_EMPLOYEES_PASS_ID > 0 then
		local ok, hasPass = pcall(function()
			return EntitlementManager.HasAccess(userId, DOUBLE_EMPLOYEES_PASS_ID)
		end)
		if ok and hasPass then
			GamepassInfo.HasDouble = true
			if UNLIMITED_EMPLOYEES_PASS_ID == 0 or UNLIMITED_EMPLOYEES_PASS_ID == DOUBLE_EMPLOYEES_PASS_ID then
				GamepassInfo.HasUnlimited = true
			end
		end
	end
	if UNLIMITED_EMPLOYEES_PASS_ID > 0 and UNLIMITED_EMPLOYEES_PASS_ID ~= DOUBLE_EMPLOYEES_PASS_ID then
		local ok, hasPass = pcall(function()
			return EntitlementManager.HasAccess(userId, UNLIMITED_EMPLOYEES_PASS_ID)
		end)
		if ok and hasPass then
			GamepassInfo.HasUnlimited = true
		end
	end
end

local function RefreshGamepassInfoFromEntitlements()
	GamepassInfo.HasDouble = false
	GamepassInfo.HasUnlimited = false
	if type(LastSlotEmployeePassFlags) == "table" then
		if LastSlotEmployeePassFlags.double == true then
			GamepassInfo.HasDouble = true
		end
		if LastSlotEmployeePassFlags.unlimited == true then
			GamepassInfo.HasUnlimited = true
		end
	end
	if ShouldMergeLocalEntitlementsForStaffCaps() then
		MergeLocalPlayerEntitlementPasses()
	end
	if #AllEmployees > 0 then
		for _, emp in ipairs(AllEmployees) do
			if emp.HasDoublePass then
				GamepassInfo.HasDouble = true
			end
			if emp.HasUnlimitedPass then
				GamepassInfo.HasUnlimited = true
			end
		end
	end
end

local function SetHireFlash(typeId, reason, duration)
	local style = HIRE_FLASH_STYLES[reason]
	if not style then HireFlashByType[typeId] = nil; return end
	HireFlashByType[typeId] = { text = style.text, color = style.color, expiresAt = tick() + (duration or FEEDBACK_DURATION) }
end

local function GetHireFlash(typeId)
	local flash = HireFlashByType[typeId]
	if flash and tick() >= flash.expiresAt then HireFlashByType[typeId] = nil; flash = nil end
	return flash
end

local function ClearHirePending(typeId) HirePendingByType[typeId] = nil end

local function GetOwnerName(ownerId)
	if ownerId == Player.UserId then return "You" end
	local player = Players:GetPlayerByUserId(ownerId)
	if player then return player.Name end
	return "Unknown"
end

local function resolveHireCardNodes(card)
	return {
		accent = card:FindFirstChild("Frame") or card:FindFirstChildWhichIsA("Frame"),
		header = card:FindFirstChild("Header") or card:FindFirstChild("Title"),
		desc = card:FindFirstChild("Desc") or card:FindFirstChild("Description"),
		capacity = card:FindFirstChild("Capacity") or card:FindFirstChild("Count"),
		price = card:FindFirstChild("Price") or card:FindFirstChild("price") or card:FindFirstChild("BaseCost"),
		hireBtn = card:FindFirstChild("HireBtn") or card:FindFirstChild("HireButton") or card:FindFirstChildWhichIsA("TextButton"),
	}
end

local function resolveRosterRowNodes(row)
	return {
		accent = row:FindFirstChild("Frame") or row:FindFirstChildWhichIsA("Frame"),
		name = row:FindFirstChild("NameLabel") or row:FindFirstChild("Name"),
		state = row:FindFirstChild("StateLabel") or row:FindFirstChild("Status") or row:FindFirstChild("State"),
		owner = row:FindFirstChild("OwnerLabel") or row:FindFirstChild("Owner"),
		level = row:FindFirstChild("Level") or row:FindFirstChild("LevelLabel"),
		click = row:FindFirstChild("ClickTarget") or row:FindFirstChildWhichIsA("GuiButton"),
	}
end

local generatedCards = {}
local RequestHire
local RunManageAction

local function RenderHireCards()
	if not TemplateCard then return end
	local sortedTypes = {}
	for typeId, typeData in pairs(Config.Types) do table.insert(sortedTypes, {id = typeId, data = typeData}) end
	table.sort(sortedTypes, function(a, b) return (a.data.BaseCost or 0) < (b.data.BaseCost or 0) end)

	for idx, entry in ipairs(sortedTypes) do
		local typeId = entry.id
		local typeData = entry.data
		local cardName = "Card_" .. tostring(typeId)

		local card = GridContainer:FindFirstChild(cardName)
		local capacityLbl, hireBtn

		if not card then
			card = TemplateCard:Clone()
			card.Name = cardName
			card.LayoutOrder = idx
			card.Visible = true
			card.Parent = GridContainer
		end

		if card then
			local nodes = resolveHireCardNodes(card)
			local icon = card:FindFirstChild("Icon")
			if icon then icon.Text = typeData.Emoji or "" end
			if nodes.header then nodes.header.Text = typeData.Name end
			if nodes.desc then nodes.desc.Text = typeData.Description or "" end
			if nodes.accent then nodes.accent.BackgroundColor3 = typeData.Color or Color3.fromRGB(120, 120, 120) end
			if nodes.price then nodes.price.Text = "Base " .. FormatMoney(typeData.BaseCost or 0) end
			capacityLbl = nodes.capacity
			hireBtn = nodes.hireBtn
			if hireBtn and hireBtn:GetAttribute("EmployeeBound") ~= true then
				bindGuiButton(hireBtn, function() RequestHire(typeId, hireBtn) end)
			end
		end

		if card then
			local count = GetCountByType(typeId)
			local maxPer = GetMaxPerTypeForUI()
			local cost = Config.GetHireCost(typeData.BaseCost, count)
			local isFull = count >= maxPer
			local canOfferUpgrade = count >= (Settings.MaxPerType or 5) and CanOfferDoubleCapUpgrade()

			if capacityLbl then
				local maxStr = HasUnlimitedEmployeeCap() and "\226\136\158" or tostring(maxPer)
				capacityLbl.Text = count .. " / " .. maxStr
			end

			if hireBtn then
				local flash = GetHireFlash(typeId)
				local pending = HirePendingByType[typeId] ~= nil
				if flash then
					hireBtn.Text = flash.text; hireBtn.BackgroundColor3 = flash.color; hireBtn.AutoButtonColor = false
				elseif pending then
					hireBtn.Text = "HIRING..."; hireBtn.BackgroundColor3 = Color3.fromRGB(100, 100, 110); hireBtn.AutoButtonColor = false
				else
					if canOfferUpgrade then
						hireBtn.Text = "BUY UNLIMITED"; hireBtn.BackgroundColor3 = Color3.fromRGB(210, 140, 40); hireBtn.AutoButtonColor = true
					else
						hireBtn.Text = isFull and "FULL" or ("HIRE " .. FormatMoney(cost))
						hireBtn.BackgroundColor3 = isFull and Color3.fromRGB(100, 100, 110) or Color3.fromRGB(40, 200, 80)
						hireBtn.AutoButtonColor = not isFull
					end
				end
			end
		end
	end
	refreshHireGridCanvas()
	UpdateStaffSummary()
end

RequestHire = function(typeId, hireBtn)
	local count = GetCountByType(typeId)
	local total = GetTotalEmployeeCount()
	local maxPer = GetMaxPerTypeForUI()
	local maxTotal = GetMaxTotalForUI()

	if HirePendingByType[typeId] then return end

	if count >= maxPer then
		local canOfferUpgrade = count >= (Settings.MaxPerType or 5) and CanOfferDoubleCapUpgrade()
		if canOfferUpgrade then
			local prompted = PromptDoubleCapUpgrade()
			SetHireFlash(typeId, "UpgradeCap")
			if prompted then
				local typeData = Config.GetTypeData(typeId)
				ShowEmployeeNotice("Info", "Employees", string.format("%s is at %d/%d. Buy Unlimited Employees to remove the staff cap.", typeData and typeData.Name or typeId, count, Settings.MaxPerType), 3)
			else
				ShowEmployeeNotice("Info", "Employees", "Unlimited Employees pass required for more staff of this type.", 2.5)
			end
			if IsEmployeesMenuOpen() then RenderHireCards() end
			return
		end

		SetHireFlash(typeId, "TypeFull")
		local typeData = Config.GetTypeData(typeId)
		ShowEmployeeNotice("Warning", "Employee Cap", string.format("%s is at max (%d/%d).", typeData and typeData.Name or typeId, count, maxPer), 2.5)
		if IsEmployeesMenuOpen() then RenderHireCards() end
		return
	end

	if total >= maxTotal then
		SetHireFlash(typeId, "TotalFull")
		ShowEmployeeNotice("Warning", "Employee Cap", string.format("Max employees reached (%d/%d).", total, maxTotal), 2.5)
		if IsEmployeesMenuOpen() then RenderHireCards() end
		return
	end

	local pendingState = { requestedAt = tick(), priorCount = count, priorTotal = total }
	HirePendingByType[typeId] = pendingState

	if hireBtn then
		hireBtn.Text = "HIRING..."
		hireBtn.BackgroundColor3 = Color3.fromRGB(100, 100, 110)
		hireBtn.AutoButtonColor = false
	end

	HireEvent:FireServer(typeId)

	task.delay(HIRE_REQUEST_TIMEOUT, function()
		if HirePendingByType[typeId] == pendingState then
			ClearHirePending(typeId)
			if IsEmployeesMenuOpen() then RenderHireCards() end
		end
	end)
end

local function RenderInfoBox()
	if not selectedEmployee then
		InfoTitle.Text = "INFO"
		if InfoStat  then InfoStat.Text  = "" end
		if InfoValue then InfoValue.Text = "Select an employee from the roster to view details." end
		FireBtn.Visible = false
		UpgradeBtn.Visible = false
		TpToBtn.Visible = false
		return
	end

	local emp = selectedEmployee
	local typeData = Config.GetTypeData(emp.Type)
	local isMine = IsMyEmployee(emp)

	local details = emp
	if InspectEvent then pcall(function() details = InspectEvent:InvokeServer(emp.Model) or emp end) end

	InfoTitle.Text = string.upper(typeData.Name)

	local wageStatus = (details.WagesPaid == false) and "[UNPAID]" or "Paid"
	local upCost = details.UpgradeCost and FormatMoney(details.UpgradeCost) or "MAX"

	if InfoStat then
		InfoStat.Text = "Owner:\nLevel:\nState:\nWage:\nEarnings:\nTasks Done:"
	end
	if InfoValue then
		InfoValue.Text = string.format(
			"%s\n%d / %d\n%s\n$%d/min (%s)\n%s\n%d",
			GetOwnerName(emp.OwnerId),
			details.Level, Settings.MaxLevel,
			details.State or emp.State or "Idle",
			details.Wage or 0, wageStatus,
			FormatMoney(details.TotalEarnings or 0),
			details.TasksCompleted or 0
		)
	end

	TpToBtn.Visible = true

	if isMine then
		FireBtn.Visible = true
		UpgradeBtn.Visible = true
		if details.Level >= Settings.MaxLevel then
			UpgradeBtn.Text = "MAX LEVEL"
			UpgradeBtn.BackgroundColor3 = Color3.fromRGB(100, 100, 110)
		else
			UpgradeBtn.Text = "UPGRADE " .. upCost
			UpgradeBtn.BackgroundColor3 = Color3.fromRGB(220, 120, 40)
		end
	else
		FireBtn.Visible = false
		UpgradeBtn.Visible = false
	end
end

local function RenderRosterBox()
	local previousRosterCanvas = RosterBox and RosterBox.CanvasPosition or Vector2.zero
	for _, child in ipairs(RosterBox:GetChildren()) do
		local isTemplate = child == TemplateRow or child.Name == "Template_EmpRow" or child.Name == "EmpRow"
		local isLayout = child:IsA("UIListLayout") or child:IsA("UICorner") or child:IsA("UIGradient")
		local isAPadding = child:IsA("UIPadding") and child.Name == "APadding"
		if child:IsA("GuiObject") and not isTemplate and not isLayout and not isAPadding then
			child:Destroy()
		end
	end

	if #AllEmployees == 0 then
		local emptyLbl = Instance.new("TextLabel")
		emptyLbl.Size = UDim2.new(1, 0, 0, 50)
		emptyLbl.BackgroundTransparency = 1
		emptyLbl.Text = "No employees hired."
		emptyLbl.TextColor3 = themeSubText
		emptyLbl.Font = Enum.Font.GothamMedium
		emptyLbl.TextSize = 14
		emptyLbl.Parent = RosterBox
		RosterBox.CanvasSize = UDim2.new(0, 0, 0, 50)
		LastRosterRenderSignature = BuildRosterSignature(AllEmployees)
		return
	end

	if not TemplateRow then return end

	for i, emp in ipairs(AllEmployees) do
		local typeData = Config.GetTypeData(emp.Type)
		if not typeData then continue end

		local isSel = selectedEmployee and selectedEmployee.UUID == emp.UUID
		local isMine = IsMyEmployee(emp)

		local row = TemplateRow:Clone()
		row.Name = "EmpRow_" .. (emp.UUID or tostring(i))
		row.BackgroundColor3 = isSel and Color3.fromRGB(50, 100, 200) or Color3.fromRGB(35, 35, 42)
		row.LayoutOrder = isMine and i or (i + 1000)
		row.Visible = true
		local zp = row:FindFirstChild("ZPadding")
		if zp then zp:Destroy() end
		row.Parent = RosterBox

		local stroke = row:FindFirstChildOfClass("UIStroke")
		if stroke then
			stroke.Color = isSel and Color3.fromRGB(80, 140, 255) or Color3.fromRGB(55, 55, 60)
			stroke.Thickness = isSel and 1.5 or 1
			stroke.Transparency = isSel and 0 or 0.5
		end

		local nodes = resolveRosterRowNodes(row)
		if nodes.accent then nodes.accent.BackgroundColor3 = typeData.Color or Color3.fromRGB(150, 150, 150) end
		if nodes.name then nodes.name.Text = (typeData.Emoji or "") .. " " .. typeData.Name end
		if nodes.level then nodes.level.Text = "Lv " .. tostring(emp.Level or 1) end
		if nodes.state then
			nodes.state.Text = emp.State or "Idle"
			nodes.state.TextColor3 = (emp.State == "Working" or emp.State == "Grooming" or emp.State == "Teaching") and Color3.fromRGB(80, 255, 80) or themeSubText
		end
		if nodes.owner then
			nodes.owner.Text = isMine and "Yours" or "Other"
			nodes.owner.TextColor3 = isMine and Color3.fromRGB(50, 200, 100) or themeSubText
		end
		if nodes.click then
			bindGuiButton(nodes.click, function()
				selectedEmployee = emp
				RenderRosterBox()
				RenderInfoBox()
			end)
		end
	end

	local listLayout = RosterBox:FindFirstChildOfClass("UIListLayout")
	if listLayout then
		task.defer(function()
			RosterBox.CanvasSize = UDim2.new(0, 0, 0, listLayout.AbsoluteContentSize.Y + 20)
			local maxCanvasY = math.max(0, listLayout.AbsoluteContentSize.Y + 20 - RosterBox.AbsoluteWindowSize.Y)
			RosterBox.CanvasPosition = Vector2.new(0, math.clamp(previousRosterCanvas.Y, 0, maxCanvasY))
		end)
	end
	LastRosterRenderSignature = BuildRosterSignature(AllEmployees)
end

RunManageAction = function(button, busyText, callback)
	if manageActionBusy then return false end
	manageActionBusy = true
	local previousText = button.Text
	button.Text = busyText
	button.AutoButtonColor = false
	callback()
	task.delay(0.35, function()
		manageActionBusy = false
		if button and button.Parent then button.Text = previousText; button.AutoButtonColor = true end
		if IsEmployeesMenuOpen() then RenderRosterBox(); RenderInfoBox() end
	end)
	return true
end

local function getManageTarget(emp)
	if not emp then
		return nil
	end
	return {
		UUID = emp.UUID,
		Model = emp.Model,
	}
end

if FireBtn then
	bindGuiButton(FireBtn, function()
		if selectedEmployee and IsMyEmployee(selectedEmployee) then
			local target = getManageTarget(selectedEmployee)
			selectedEmployee = nil
			RunManageAction(FireBtn, "FIRING...", function() ManageEvent:FireServer("Fire", target) end)
		end
	end)
end

if UpgradeBtn then
	bindGuiButton(UpgradeBtn, function()
		if selectedEmployee and IsMyEmployee(selectedEmployee) and selectedEmployee.Level < Settings.MaxLevel then
			local target = getManageTarget(selectedEmployee)
			RunManageAction(UpgradeBtn, "UPGRADING...", function() ManageEvent:FireServer("Upgrade", target) end)
		end
	end)
end

if TpToBtn then
	bindGuiButton(TpToBtn, function()
		if selectedEmployee then
			local target = getManageTarget(selectedEmployee)
			RunManageAction(TpToBtn, "TELEPORTING...", function() ManageEvent:FireServer("Teleport", target) end)
		end
	end)
end

HireResultEvent.OnClientEvent:Connect(function(result)
	if type(result) ~= "table" then return end
	local typeId = result.typeId
	if type(typeId) == "string" then
		ClearHirePending(typeId)
		if result.success then HireFlashByType[typeId] = nil else
			SetHireFlash(typeId, result.reason)
			local reasonText = { TooFast = "Please wait before hiring again.", NotOwner = "Only the slot owner can hire staff.", InvalidType = "That employee type is invalid.", TypeFull = "That employee type is already at max.", TotalFull = "You reached your maximum employee count.", NoFunds = "Not enough money to hire this employee.", NoAssignment = "Place required buildings first.", SpawnFailed = "Employee spawn failed. Try again.", }
			ShowEmployeeNotice("Warning", "Employee Hire", reasonText[result.reason] or "Hire failed.", 2.5)
		end
	end
	if IsEmployeesMenuOpen() then RenderHireCards() end
end)

SyncEvent.OnClientEvent:Connect(function(list, slotPassFlags)
	AllEmployees = list or {}
	if type(slotPassFlags) == "table" then
		LastSlotEmployeePassFlags = slotPassFlags
	else
		LastSlotEmployeePassFlags = nil
	end
	LastWeather = "Clear"
	LastTemperature = 30

	if #AllEmployees > 0 then
		for _, emp in ipairs(AllEmployees) do
			if emp.Weather then LastWeather = emp.Weather end
			if emp.Temperature then LastTemperature = emp.Temperature end
		end
	end

	RefreshGamepassInfoFromEntitlements()

	MyEmployees = {}
	for _, e in ipairs(AllEmployees) do if IsMyEmployee(e) then table.insert(MyEmployees, e) end end
	UpdateStaffSummary()

	for typeId, pending in pairs(HirePendingByType) do
		local currentCount = GetCountByType(typeId)
		if currentCount > (pending.priorCount or 0) or GetTotalEmployeeCount() > (pending.priorTotal or 0) or currentCount >= GetMaxPerTypeForUI() then
			ClearHirePending(typeId)
			HireFlashByType[typeId] = nil
		end
	end

	if selectedEmployee then
		local found = false
		for _, e in ipairs(AllEmployees) do
			if e.UUID == selectedEmployee.UUID then selectedEmployee = e; found = true; break end
		end
		if not found then selectedEmployee = nil end
	end

	local rosterSignature = BuildRosterSignature(AllEmployees)
	if IsEmployeesMenuOpen() then
		RenderHireCards()
		if rosterSignature ~= LastRosterRenderSignature then
			RenderRosterBox()
		end
		RenderInfoBox()
	end
end)

if EntitlementChanged and EntitlementChanged:IsA("RemoteEvent") then
	EntitlementChanged.OnClientEvent:Connect(function(payload)
		if type(payload) ~= "table" or tonumber(payload.userId) ~= Player.UserId then
			return
		end
		RefreshGamepassInfoFromEntitlements()
		UpdateStaffSummary()
		if IsEmployeesMenuOpen() then
			RenderHireCards()
			RenderRosterBox()
			RenderInfoBox()
		end
	end)
end

local ClosePanels = Events:FindFirstChild("ClosePanels")
if not ClosePanels then ClosePanels = Instance.new("BindableEvent"); ClosePanels.Name = "ClosePanels"; ClosePanels.Parent = Events end

ClosePanels.Event:Connect(function(source)
	if source == "Employees" then return end
	if isMenuOpen then setEmployeesMenuState(false) end
end)

EmployeesFrame:GetPropertyChangedSignal("Visible"):Connect(function()
	local visible = EmployeesFrame.Visible
	if visible == isMenuOpen then return end
	isMenuOpen = visible
	if visible then
		SyncEvent:FireServer()
		if RosterBox then
			RosterBox.CanvasPosition = Vector2.new(0, 0)
		end
		task.defer(function() if EmployeesFrame.Visible then RenderHireCards(); RenderRosterBox(); RenderInfoBox() end end)
		return
	end
	manageActionBusy = false
end)

local lastToggleAt = 0
local function ToggleMenu()
	local now = os.clock()
	if now - lastToggleAt < 0.2 then
		return
	end
	lastToggleAt = now
	local nextState = not isMenuOpen
	if nextState then
		ClosePanels:Fire("Employees")
		SyncEvent:FireServer()
		RenderHireCards(); RenderRosterBox(); RenderInfoBox()
	end
	setEmployeesMenuState(nextState)
end

if ExitBtn then bindGuiButton(ExitBtn, ToggleMenu) end

local Dock = MainHUD:WaitForChild("Dock", 10)
if Dock then
	local btn = Dock:FindFirstChild("Employees") or Dock:FindFirstChild("Staff")
	if btn and btn:IsA("GuiButton") then
		bindGuiButton(btn, ToggleMenu)
	end
end

local function getModeStateValue(): string
	local mode = PlayerGui:FindFirstChild("ModeState")
	if mode and mode:IsA("StringValue") then
		return mode.Value
	end
	return ""
end


task.delay(1, function() SyncEvent:FireServer() end)

local employeeViewportConnection = nil
local function bindEmployeeViewportResponsive()
	if employeeViewportConnection then
		employeeViewportConnection:Disconnect()
		employeeViewportConnection = nil
	end
	local camera = workspace.CurrentCamera
	if camera then
		employeeViewportConnection = camera:GetPropertyChangedSignal("ViewportSize"):Connect(applyResponsiveEmployeesLayout)
	end
end

workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
	bindEmployeeViewportResponsive()
	task.defer(applyResponsiveEmployeesLayout)
end)
bindEmployeeViewportResponsive()

task.spawn(function()
	while true do task.wait(5); if isMenuOpen then SyncEvent:FireServer() end end
end)

MarketplaceService.PromptGamePassPurchaseFinished:Connect(function(purchaser, passId, wasPurchased)
	if purchaser ~= Player then return end
	if passId ~= DOUBLE_EMPLOYEES_PASS_ID and passId ~= UNLIMITED_EMPLOYEES_PASS_ID then return end
	GamepassInfo.HasDouble = false
	GamepassInfo.HasUnlimited = false
	RefreshGamepassInfoFromEntitlements()
	if isMenuOpen then SyncEvent:FireServer(); RenderHireCards() end
	if wasPurchased then
		_purchasedUnlimitedThisSession = true
		ShowEmployeeNotice("Success", "Employees", "Unlimited Employees unlocked. Staff cap removed.", 2.5)
	end
end)

--========================================================================================
-- CLIENT PATHFINDING / ANTI-STUTTER WORKER ENGINE
--========================================================================================
local PathfindingAgents = {}

local EmployeeAnimState = {}

local function SafeUnit(vector, fallback)
	if vector.Magnitude > 1e-4 then
		return vector.Unit
	end
	return fallback or Vector3.zero
end

local function RemoveEmployeeProceduralController(model)
	local state = EmployeeAnimState[model]
	if state and state.controller then
		state.controller:Destroy()
	end
	EmployeeAnimState[model] = nil
end

local function UpdateEmployeeAnimations(model, dt)
	local hum = model:FindFirstChild("Humanoid")
	if not hum then return end
	local root = model:FindFirstChild("HumanoidRootPart")
	if not root then
		RemoveEmployeeProceduralController(model)
		return
	end

	local isSkiing = model:GetAttribute("EmployeeSkiing") == true
	local hasSkis = model:GetAttribute("HasEmployeeSkis") == true
	local state = EmployeeAnimState[model]
	if not state then
		state = { controller = nil }
		EmployeeAnimState[model] = state
	end

	if not isSkiing and not hasSkis then
		RemoveEmployeeProceduralController(model)
		return
	end

	if not state.controller then
		state.controller = ProceduralSkiAnimator.new(model, hum)
	end
	if not state.controller then
		return
	end

	local planarVelocity = Vector3.new(root.AssemblyLinearVelocity.X, 0, root.AssemblyLinearVelocity.Z)
	local planarDirection = SafeUnit(planarVelocity, Vector3.new(root.CFrame.LookVector.X, 0, root.CFrame.LookVector.Z))
	local lookVector = SafeUnit(Vector3.new(root.CFrame.LookVector.X, 0, root.CFrame.LookVector.Z), planarDirection)
	local turnCross = (lookVector.X * planarDirection.Z) - (lookVector.Z * planarDirection.X)
	local steer = math.clamp(-turnCross * 2.4, -1, 1)

	state.controller:Step(dt or (1 / 60), SkiStateSchema.Build({
		current = isSkiing and "skiing" or "off",
		velocity = root.AssemblyLinearVelocity,
		normal = root.CFrame.UpVector,
		groundedAlpha = 1,
		grounded = true,
		steer = steer,
		turnRate = steer * math.clamp(planarVelocity.Magnitude / 16, 0, 3.5),
		slipAmount = math.clamp(math.abs(turnCross), 0, 1),
		forward = root.CFrame.LookVector,
		planarVelocity = planarVelocity,
		speed = planarVelocity.Magnitude,
		wantsBootWalk = hasSkis and not isSkiing,
	}))
end

local function IsLocalEmployeeModel(model)
	local ownerId = tonumber(model:GetAttribute("OwnerId"))
	if not ownerId then
		return false
	end
	if ownerId == Player.UserId then
		return true
	end
	if OwnerUserId ~= 0 and ownerId == OwnerUserId then
		return true
	end
	return false
end

local function UpdateClientPathfinding(model)
	if not model.PrimaryPart or not model:FindFirstChild("Humanoid") then return end

	if not IsLocalEmployeeModel(model) then return end

	local targetPos = model:GetAttribute("TargetPosition")
	local hum = model:FindFirstChild("Humanoid")

	if not targetPos then
		if PathfindingAgents[model] then
			PathfindingAgents[model].Active = false
		end
		hum:MoveTo(model.PrimaryPart.Position)
		return
	end

	hum.WalkSpeed = model:GetAttribute("WalkSpeed") or 16

	if not PathfindingAgents[model] then
		PathfindingAgents[model] = {
			Active = true,
			WaypointIndex = 1,
			Waypoints = {},
			LastPathTime = 0,
			LastMoveToTime = 0,
			LastStuckCheckPos = nil,
			LastStuckCheckTime = 0,
		}
	end

	local agent = PathfindingAgents[model]
	agent.Active = true
	agent.LastPathTime = tick()
	agent.LastMoveToTime = tick()
	agent.LastStuckCheckPos = model.PrimaryPart.Position
	agent.LastStuckCheckTime = tick()

	task.spawn(function()
		local path = PathfindingService:CreatePath({
			AgentRadius = 3,
			AgentHeight = 5.5,
			AgentCanJump = true,
			WaypointSpacing = 4
		})

		local success = pcall(function() path:ComputeAsync(model.PrimaryPart.Position, targetPos) end)
		if success and path.Status == Enum.PathStatus.Success then
			agent.Waypoints = path:GetWaypoints()
			agent.WaypointIndex = 2

			if #agent.Waypoints >= 2 then
				local nextWp = agent.Waypoints[agent.WaypointIndex]
				if nextWp.Action == Enum.PathWaypointAction.Jump then hum.Jump = true end
				hum:MoveTo(nextWp.Position)
				agent.LastMoveToTime = tick()
			else
				hum:MoveTo(targetPos)
				agent.LastMoveToTime = tick()
			end
		else
			hum:MoveTo(targetPos)
			agent.LastMoveToTime = tick()
			agent.Waypoints = {}
			agent.WaypointIndex = 1
		end
	end)
end

local EmployeeList = {}

local function OnEmployeeAdded(model)
	if not model:IsA("Model") then return end
	task.wait()
	if not model:GetAttribute("IsEmployee") then return end

	EmployeeList[model] = true

	model:GetAttributeChangedSignal("TargetPosition"):Connect(function()
		UpdateClientPathfinding(model)
	end)

	if model:GetAttribute("TargetPosition") then
		UpdateClientPathfinding(model)
	end
end

workspace.DescendantAdded:Connect(function(desc)
	if desc:IsA("Model") then
		OnEmployeeAdded(desc)
	end
end)

for _, desc in ipairs(workspace:GetDescendants()) do
	if desc:IsA("Model") then
		OnEmployeeAdded(desc)
	end
end

RunService.Heartbeat:Connect(function(dt)
	for model in pairs(EmployeeList) do
		if not model.Parent or not model.PrimaryPart then
			EmployeeList[model] = nil
			RemoveEmployeeProceduralController(model)
			continue
		end
		UpdateEmployeeAnimations(model, dt)
	end

	for model, agent in pairs(PathfindingAgents) do
		if not agent.Active then continue end
		if not model.Parent or not model.PrimaryPart then
			PathfindingAgents[model] = nil
			continue
		end

		local targetPos = model:GetAttribute("TargetPosition")
		if not targetPos then
			agent.Active = false
			continue
		end

		local hum = model:FindFirstChild("Humanoid")
		if not hum then continue end

		hum.WalkSpeed = model:GetAttribute("WalkSpeed") or 16
		local currentPos = model.PrimaryPart.Position
		local now = tick()

		local moveToAge = now - (agent.LastMoveToTime or 0)
		if moveToAge > 6 then
			hum:MoveTo(targetPos)
			agent.LastMoveToTime = now
		end

		local pathAge = now - (agent.LastPathTime or 0)
		local stuckDist = agent.LastStuckCheckPos and (currentPos - agent.LastStuckCheckPos).Magnitude or 999
		if pathAge > 8 and stuckDist < 4 then
			agent.LastPathTime = now
			agent.LastStuckCheckPos = currentPos
			agent.LastStuckCheckTime = now
			UpdateClientPathfinding(model)
			continue
		end

		if now - (agent.LastStuckCheckTime or 0) > 4 then
			agent.LastStuckCheckPos = currentPos
			agent.LastStuckCheckTime = now
		end

		if agent.Waypoints and agent.WaypointIndex <= #agent.Waypoints then
			local wp = agent.Waypoints[agent.WaypointIndex]
			local dist = (Vector3.new(wp.Position.X, 0, wp.Position.Z) - Vector3.new(currentPos.X, 0, currentPos.Z)).Magnitude

			if dist < 4 then
				agent.WaypointIndex = agent.WaypointIndex + 1
				if agent.WaypointIndex > #agent.Waypoints then
					hum:MoveTo(targetPos)
					agent.LastMoveToTime = now
				else
					local nextWp = agent.Waypoints[agent.WaypointIndex]
					if nextWp.Action == Enum.PathWaypointAction.Jump then hum.Jump = true end
					hum:MoveTo(nextWp.Position)
					agent.LastMoveToTime = now
				end
			end
		end
	end
end)