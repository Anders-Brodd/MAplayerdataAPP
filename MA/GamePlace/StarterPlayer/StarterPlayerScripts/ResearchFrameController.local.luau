--!strict
--[=[ PATH: Players/[Player]/PlayerScripts/ResearchFrameController | TYPE: LocalScript ]=]--

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local Player = Players.LocalPlayer
local MainHUD = Player:WaitForChild("PlayerGui"):WaitForChild("MainHUD")
local ResearchFrame = MainHUD:WaitForChild("ResearchFrame")
local Header = ResearchFrame:WaitForChild("Header")
local CloseButton = Header:WaitForChild("CloseButton")
local ContentRaw = ResearchFrame:WaitForChild("Content")
local QueueFrame = ResearchFrame:FindFirstChild("Queue") :: Frame?
local Dock = MainHUD:WaitForChild("Dock")
local ResearchButton = Dock:WaitForChild("Research", 10)

local ResearchFolder = ReplicatedStorage:WaitForChild("Research")
local Config = require(ResearchFolder:WaitForChild("ResearchConfig"))
local BuildingConfig = require(ReplicatedStorage:WaitForChild("Config"))

local Events = ReplicatedStorage:WaitForChild("Events")
local ResearchUpdate = Events:WaitForChild("ResearchUpdate")
local StartResearch = Events:WaitForChild("StartResearch")
local GetResearchState = Events:WaitForChild("GetResearchState")

local ClosePanels = Events:FindFirstChild("ClosePanels")
if not ClosePanels then
	ClosePanels = Instance.new("BindableEvent")
	ClosePanels.Name = "ClosePanels"
	ClosePanels.Parent = Events
end

-- ─── Ensure Content is a ScrollingFrame ───────────────────────────────────────
local Content: ScrollingFrame
if ContentRaw:IsA("ScrollingFrame") then
	Content = ContentRaw
else
	local s = Instance.new("ScrollingFrame")
	s.Name = "Content"; s.AnchorPoint = ContentRaw.AnchorPoint
	s.Position = ContentRaw.Position; s.Size = ContentRaw.Size
	s.BackgroundColor3 = ContentRaw.BackgroundColor3
	s.BackgroundTransparency = ContentRaw.BackgroundTransparency
	s.BorderColor3 = ContentRaw.BorderColor3; s.BorderSizePixel = ContentRaw.BorderSizePixel
	s.ZIndex = ContentRaw.ZIndex; s.ClipsDescendants = true
	s.ScrollBarImageColor3 = Color3.fromRGB(180,180,180)
	s.ScrollBarImageTransparency = 0.25; s.ScrollBarThickness = 8
	s.ScrollingDirection = Enum.ScrollingDirection.XY
	s.CanvasSize = UDim2.fromOffset(0,0); s.AutomaticCanvasSize = Enum.AutomaticSize.None
	for _, child in ipairs(ContentRaw:GetChildren()) do child.Parent = s end
	s.Parent = ResearchFrame; ContentRaw:Destroy(); Content = s
end

-- ─── Header labels ────────────────────────────────────────────────────────────
local LayoutConfig  = type(Config.Layout) == "table" and Config.Layout or nil
local titleLabel    = Header:FindFirstChild("Title")    :: TextLabel?
local subtitleLabel = Header:FindFirstChild("Subtitle") :: TextLabel?
local rpLabel       = Header:FindFirstChild("RPLabel")  :: TextLabel?
local baseTitle    = titleLabel    and titleLabel.Text    or "Research"
local baseSubtitle = subtitleLabel and subtitleLabel.Text or "Unlock better lifts, guests, and systems."

-- ─── RP Tooltip ───────────────────────────────────────────────────────────────
local rpTooltip: Frame? = nil
local rpTooltipHideToken = 0
local RP_TOOLTIP_ICON  = "rbxassetid://127770762563624"
local RP_TOOLTIP_TITLE = "Research Points"
local RP_TOOLTIP_TEXT  = "You start with 220 RP and passively earn 4 RP every 15 seconds while playing. Spend RP to research new tech and unlock better resort content. You can also gain RP from ad boosts, purchases, and RP multipliers."

-- ─── Layout constants ─────────────────────────────────────────────────────────
local TREE_PAD_X = 48; local TREE_PAD_Y = 52
local COL_GAP = 112;   local ROW_GAP = 28
local nodeScale = 1

-- ─── Runtime state ────────────────────────────────────────────────────────────
local isOpen = false; local needsRender = true
local renderedNodes: {[string]: Frame} = {}
local lastClockTick = 0
local researchStateLoaded = false
local latestSnapshotRevision = -1

local clientData = {
	RP = 0,
	Unlocked = {} :: {[string]: boolean},
	Current  = nil :: {Id: string, StartTime: number, EndTime: number}?,
	Revision = nil :: number?,
}

-- ─── Queue state ──────────────────────────────────────────────────────────────
local QUEUE_MAX = 6; local QUEUE_MIN_DISPLAY = 3
local researchQueue: {string} = {}
local queueAdvancing = false; local advanceScheduled = false
local queuedResearchAdvancePending = false
local EMPTY_SLOT_TEXT = "Click on a <b>research option</b> to add to <b>queue.</b>"
local queueBarTweens: {[number]: Tween?} = {}
local queueHoverConnsList: {[number]: {RBXScriptConnection}} = {}

-- ─── TechTree (populated below) ───────────────────────────────────────────────
local TechTree: {[string]: {[string]: any}} = {}
local ChildMap: {[string]: {string}} = {}

-- ─── Forward declarations ─────────────────────────────────────────────────────
local render: () -> ()
local renderQueue: () -> ()
local updateHeader: () -> ()

-- ═════════════════════════════════════════════════════════════════════════════
--  TECH TREE BUILD
-- ═════════════════════════════════════════════════════════════════════════════
for techId, raw in pairs(Config.TechTree or {}) do
	local reqs = {}
	if type(raw.Req) == "string" and raw.Req ~= "" then table.insert(reqs, raw.Req) end
	if type(raw.Reqs) == "table" then
		for _, r in ipairs(raw.Reqs) do
			if type(r) == "string" and r ~= "" then table.insert(reqs, r) end
		end
	end
	local unlocks = {}
	if type(raw.Unlocks) == "table" then
		for _, name in ipairs(raw.Unlocks) do
			if type(name) == "string" and name ~= "" then
				local ic = BuildingConfig.Items[name]
				if ic and (ic.ShowInMenu == false or ic.Loadable == false) then continue end
				table.insert(unlocks, name)
			end
		end
	end
	TechTree[techId] = {
		Id = techId, Name = tostring(raw.Name or techId), Desc = tostring(raw.Desc or ""),
		Cost = math.max(0, math.floor(tonumber(raw.Cost) or 0)),
		Time = math.max(0, math.floor(tonumber(raw.Time) or 0)),
		Reqs = reqs, Unlocks = unlocks,
		Branch = tostring(raw.Branch or "General"), Sort = tonumber(raw.Sort) or 0,
	}
	ChildMap[techId] = {}
end
for techId, tech in pairs(TechTree) do
	for _, reqId in ipairs(tech.Reqs) do
		if ChildMap[reqId] then table.insert(ChildMap[reqId], techId) end
	end
end

-- ═════════════════════════════════════════════════════════════════════════════
--  PURE HELPERS
-- ═════════════════════════════════════════════════════════════════════════════
local function isInQueue(techId: string): boolean
	for _, id in ipairs(researchQueue) do if id == techId then return true end end
	return false
end

local function getNodeState(techId: string): string
	if clientData.Unlocked[techId] then return "Unlocked" end
	if clientData.Current and clientData.Current.Id == techId then return "Researching" end
	if isInQueue(techId) then return "Available" end
	local tech = TechTree[techId]
	if not tech then return "Locked" end
	for _, reqId in ipairs(tech.Reqs) do
		if not clientData.Unlocked[reqId] then return "Locked" end
	end
	return "Available"
end

local function formatTime(seconds: number): string
	seconds = math.max(0, math.floor(seconds))
	if seconds < 60 then return string.format("%ds", seconds) end
	local m = math.floor(seconds/60); local s2 = seconds % 60
	if m < 60 then return string.format("%dm %02ds", m, s2) end
	local h = math.floor(m/60); m = m%60; return string.format("%dh %02dm", h, m)
end

local function formatRP(value: number): string
	value = math.max(0, math.floor(value+.5))
	if value >= 1e9 then return string.format("%.1fB", value/1e9):gsub("%.0B","B") end
	if value >= 1e6 then return string.format("%.1fM", value/1e6):gsub("%.0M","M") end
	if value >= 1e3 then return string.format("%.1fK", value/1e3):gsub("%.0K","K") end
	return tostring(value)
end

local function sanitizeSnapshot(raw: any)
	local snap = { RP=0, Unlocked={} :: {[string]:boolean}, Current=nil :: {Id:string,StartTime:number,EndTime:number}?, Revision=nil :: number? }
	if type(raw) ~= "table" then return snap end
	snap.RP = math.max(0, math.floor(tonumber(raw.RP) or 0))
	local revision = tonumber(raw.Revision)
	if revision then
		snap.Revision = math.max(0, math.floor(revision))
	end
	if type(raw.Unlocked) == "table" then
		for id, v in pairs(raw.Unlocked) do
			if v == true and TechTree[id] then snap.Unlocked[id] = true end
		end
	end
	if type(raw.Current) == "table" then
		local cId = raw.Current.Id; local eT = tonumber(raw.Current.EndTime)
		local sT = tonumber(raw.Current.StartTime) or os.time()
		if type(cId) == "string" and TechTree[cId] and eT then
			snap.Current = { Id=cId, StartTime=math.floor(sT), EndTime=math.floor(eT) }
		end
	end
	return snap
end

local function bindGuiButton(button: GuiObject?, callback: () -> ())
	if not button then return end
	button.Active = true; button.Selectable = true
	local lastFire = 0
	local function fire()
		local now = os.clock(); if now - lastFire < 0.2 then return end
		lastFire = now; callback()
	end
	if button:IsA("GuiButton") then
		button.AutoButtonColor = true; button.Activated:Connect(fire)
	else
		button.InputBegan:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.MouseButton1
				or input.UserInputType == Enum.UserInputType.Touch then fire() end
		end)
	end
end

-- ═════════════════════════════════════════════════════════════════════════════
--  RP TOOLTIP
-- ═════════════════════════════════════════════════════════════════════════════
local function ensureRPTooltip(): Frame
	if rpTooltip and rpTooltip.Parent == MainHUD then return rpTooltip end
	local t = Instance.new("Frame"); t.Name="RPTooltip"; t.AnchorPoint=Vector2.new(1,1)
	t.Position=UDim2.fromOffset(0,0); t.Size=UDim2.fromOffset(290,106)
	t.BackgroundColor3=Color3.fromRGB(24,25,30); t.BorderSizePixel=0
	t.Visible=false; t.ZIndex=60; t.Parent=MainHUD
	local c=Instance.new("UICorner"); c.CornerRadius=UDim.new(0,12); c.Parent=t
	local st=Instance.new("UIStroke"); st.Color=Color3.fromRGB(66,82,104); st.Thickness=1; st.Transparency=0.2; st.Parent=t
	local icon=Instance.new("ImageLabel"); icon.BackgroundTransparency=1; icon.Image=RP_TOOLTIP_ICON
	icon.ImageColor3=Color3.fromRGB(62,139,255); icon.ScaleType=Enum.ScaleType.Fit
	icon.Position=UDim2.new(0,14,0,10); icon.Size=UDim2.fromOffset(26,26); icon.ZIndex=41; icon.Parent=t
	local tl=Instance.new("TextLabel"); tl.BackgroundTransparency=1; tl.Text=RP_TOOLTIP_TITLE
	tl.TextColor3=Color3.new(1,1,1); tl.Font=Enum.Font.GothamBold; tl.TextSize=14; tl.TextWrapped=true
	tl.TextXAlignment=Enum.TextXAlignment.Left; tl.TextYAlignment=Enum.TextYAlignment.Center
	tl.Position=UDim2.new(0,46,0,8); tl.Size=UDim2.new(1,-56,0,24); tl.ZIndex=41; tl.Parent=t
	local tip=Instance.new("TextLabel"); tip.BackgroundTransparency=1; tip.Text=RP_TOOLTIP_TEXT
	tip.TextColor3=Color3.fromRGB(220,225,235); tip.Font=Enum.Font.Gotham; tip.TextSize=13; tip.TextWrapped=true
	tip.TextXAlignment=Enum.TextXAlignment.Left; tip.TextYAlignment=Enum.TextYAlignment.Top
	tip.Position=UDim2.new(0,12,0,36); tip.Size=UDim2.new(1,-24,1,-46); tip.ZIndex=41; tip.Parent=t
	rpTooltip=t; return t
end

local function updateRPTooltipPlacement()
	local tt = ensureRPTooltip()
	if not rpLabel or not rpLabel.Parent then return end
	local cam = Workspace.CurrentCamera
	local screen = (cam and cam.ViewportSize.X > 0) and cam.ViewportSize or Vector2.new(1920,1080)
	local tSz = tt.AbsoluteSize; if tSz.X <= 0 then tSz = Vector2.new(tt.Size.X.Offset, tt.Size.Y.Offset) end
	local lPos = rpLabel.AbsolutePosition; local lSz = rpLabel.AbsoluteSize
	local x = math.clamp(lPos.X+lSz.X, tSz.X+8, screen.X-8)
	local y = math.clamp(ResearchFrame.AbsolutePosition.Y-12, tSz.Y+8, screen.Y-8)
	tt.Position = UDim2.fromOffset(math.floor(x+.5), math.floor(y+.5))
end

local function setRPTooltipVisible(visible: boolean, autoHide: number?)
	local tt = ensureRPTooltip(); rpTooltipHideToken += 1; local tok = rpTooltipHideToken
	if visible then updateRPTooltipPlacement() end; tt.Visible = visible
	if visible and autoHide and autoHide > 0 then
		task.delay(autoHide, function() if rpTooltipHideToken == tok and tt.Parent then tt.Visible=false end end)
	end
end

local function alignBuyRPButton(label: TextLabel, compact: boolean?)
	local buyBtn = Header:FindFirstChild("BuyRPButton")
	if not buyBtn or not buyBtn:IsA("GuiObject") then return end
	local isCom = compact ~= nil and compact or (label.Size.X.Offset <= 140)
	local bW = isCom and 84 or 96; local bH = isCom and 28 or 30
	local lW = isCom and 110 or 164
	local closeBtn = Header:FindFirstChild("CloseButton")
	local cPos = (closeBtn and closeBtn:IsA("GuiObject")) and closeBtn.Position or UDim2.new(1,-16,0.5,0)
	buyBtn.Size=UDim2.new(0,bW,0,bH); buyBtn.AnchorPoint=Vector2.new(1,0.5)
	buyBtn.Position=UDim2.new(cPos.X.Scale, cPos.X.Offset-12, 0.5,0)
	buyBtn.ZIndex=math.max(label.ZIndex, Header.ZIndex+2)
	label.AnchorPoint=Vector2.new(1,0.5); label.Size=UDim2.new(0,lW,0, isCom and 28 or 30)
	label.Position=UDim2.new(cPos.X.Scale, cPos.X.Offset-12-bW-10, 0.5,0)
	local tt = ensureRPTooltip()
	tt.Size = isCom and UDim2.fromOffset(250,118) or UDim2.fromOffset(290,106)
	updateRPTooltipPlacement()
end

local function ensureRPLabel(): TextLabel
	local label = rpLabel
	if not label or label.Parent ~= Header then
		label=Instance.new("TextLabel"); label.Name="RPLabel"; label.Parent=Header; rpLabel=label
	end
	label.Active=true; label.Selectable=true
	label.BackgroundColor3=Color3.fromRGB(6,13,49); label.BackgroundTransparency=0.25
	label.Font=Enum.Font.GothamBold; label.Text="RP: 0"; label.TextColor3=Color3.fromRGB(182,211,255)
	label.TextSize=14; label.TextScaled=false; label.TextWrapped=false
	label.TextTruncate=Enum.TextTruncate.AtEnd; label.TextXAlignment=Enum.TextXAlignment.Right
	label.TextYAlignment=Enum.TextYAlignment.Center; label.ZIndex=math.max(Header.ZIndex+2,20)
	if not label:FindFirstChildOfClass("UICorner") then
		local c=Instance.new("UICorner"); c.CornerRadius=UDim.new(0,8); c.Parent=label
	end
	if not label:FindFirstChildOfClass("UIPadding") then
		local p=Instance.new("UIPadding"); p.PaddingLeft=UDim.new(0,10); p.PaddingRight=UDim.new(0,10); p.Parent=label
	end
	if label:GetAttribute("ResearchTooltipBound") ~= true then
		label.MouseEnter:Connect(function() setRPTooltipVisible(true) end)
		label.MouseLeave:Connect(function() setRPTooltipVisible(false) end)
		label.InputBegan:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.Touch then setRPTooltipVisible(true,3) end
		end)
		label:SetAttribute("ResearchTooltipBound", true)
	end
	alignBuyRPButton(label); return label
end

-- ═════════════════════════════════════════════════════════════════════════════
--  HEADER
-- ═════════════════════════════════════════════════════════════════════════════
updateHeader = function()
	if titleLabel then titleLabel.Text = baseTitle end
	if subtitleLabel then subtitleLabel.Text = baseSubtitle end
	local label = ensureRPLabel()
	label.Text = "RP: " .. formatRP(clientData.RP)
	alignBuyRPButton(label)
end

-- ═════════════════════════════════════════════════════════════════════════════
--  TEMPLATES
-- ═════════════════════════════════════════════════════════════════════════════
local function pickTemplate(name: string, validator: ((Frame)->boolean)?): Frame?
	local fallback: Frame? = nil
	for _, child in ipairs(Content:GetChildren()) do
		if child:IsA("Frame") and child.Name == name then
			if not fallback then fallback = child end
			if not validator or validator(child) then return child end
		end
	end
	return fallback
end

local templateAvailable = pickTemplate("OptionAvailable")
local templateBought    = pickTemplate("OptionBought")
local templateLocked    = pickTemplate("OptionLocked", function(f) return f:FindFirstChild("Frame") ~= nil end)
local lineTemplate      = pickTemplate("Line")

if not templateAvailable or not templateBought or not templateLocked or not lineTemplate then
	warn("[ResearchFrameController] Missing research templates"); return
end

local function hideTemplates()
	for _, child in ipairs(Content:GetChildren()) do
		if child:IsA("GuiObject") and (child.Name=="OptionAvailable" or child.Name=="OptionBought"
			or child.Name=="OptionLocked" or child.Name=="Line") then
			child.Visible = false
		end
	end
end
hideTemplates()

if QueueFrame then
	for _, child in ipairs(QueueFrame:GetChildren()) do
		if child:IsA("Frame") and (child.Name=="Template1" or child.Name=="Template2" or child.Name=="Template3") then
			child.Visible = false
		end
	end
end

-- ═════════════════════════════════════════════════════════════════════════════
--  QUEUE SLOT MANAGEMENT
-- ═════════════════════════════════════════════════════════════════════════════
local function getQueueTemplate(idx: number): Frame?
	if not QueueFrame then return nil end
	local t = QueueFrame:FindFirstChild("Template"..tostring(math.min(idx,3)))
	return t and t:IsA("Frame") and t or nil
end

local function cloneTemplateForSlot(idx: number): Frame?
	if not QueueFrame then return nil end
	local src = QueueFrame:FindFirstChild("Template1")
	if not src or not src:IsA("Frame") then return nil end
	local clone = src:Clone(); clone.Name="Template"..tostring(idx)
	clone.Visible=false; clone.Parent=QueueFrame; return clone
end

local function getOrCreateSlotFrame(idx: number): Frame?
	if idx <= 3 then return getQueueTemplate(idx) end
	local ex = QueueFrame and QueueFrame:FindFirstChild("Template"..tostring(idx))
	if ex and ex:IsA("Frame") then return ex end
	return cloneTemplateForSlot(idx)
end

local function stopBarTween(idx: number)
	local t = queueBarTweens[idx]; if t then t:Cancel(); queueBarTweens[idx]=nil end
end

local function cleanHoverConns(idx: number)
	local list = queueHoverConnsList[idx]
	if list then for _, c in ipairs(list) do c:Disconnect() end end
	queueHoverConnsList[idx] = {}
end

-- Fade a slot out then call onDone
local function animateSlotOut(slotFrame: Frame, onDone: () -> ())
	local info = TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	local cg = slotFrame:IsA("CanvasGroup") and slotFrame or slotFrame:FindFirstChildOfClass("CanvasGroup")
	if cg then
		local t = TweenService:Create(cg, info, { GroupTransparency = 1 })
		t:Play(); t.Completed:Once(onDone)
	else
		local done = false
		local function finish() if not done then done=true; onDone() end end
		TweenService:Create(slotFrame, info, { BackgroundTransparency = 1 }):Play()
		for _, d in ipairs(slotFrame:GetDescendants()) do
			if d:IsA("TextLabel") then
				TweenService:Create(d, info, { TextTransparency=1, BackgroundTransparency=1 }):Play()
			elseif d:IsA("ImageLabel") or d:IsA("ImageButton") then
				TweenService:Create(d, info, { ImageTransparency=1, BackgroundTransparency=1 }):Play()
			end
		end
		task.delay(0.2, finish)
	end
end

-- Animate progress bar for active slot
local function animateBar(idx: number, slotFrame: Frame, techId: string?)
	stopBarTween(idx)
	local barFrame = slotFrame:FindFirstChild("Bar")
	if not barFrame or not barFrame:IsA("CanvasGroup") then return end
	local filled = barFrame:FindFirstChild("Filled")
	if not filled or not filled:IsA("GuiObject") then return end
	filled.Visible = true

	if idx == 1 and techId and clientData.Current and clientData.Current.Id == techId then
		local cur = clientData.Current
		local total    = math.max(1, cur.EndTime - cur.StartTime)
		local elapsed  = math.max(0, os.time() - cur.StartTime)
		local progress = math.clamp(elapsed / total, 0, 1)
		local remaining = math.max(0, cur.EndTime - os.time())
		filled.Size = UDim2.new(progress, 0, 0.1, 0)
		if remaining > 0 then
			local t = TweenService:Create(filled,
				TweenInfo.new(remaining, Enum.EasingStyle.Linear, Enum.EasingDirection.Out),
				{ Size = UDim2.new(1, 0, 0.1, 0) })
			t:Play(); queueBarTweens[idx] = t
		else
			filled.Size = UDim2.new(1, 0, 0.1, 0)
		end
	else
		filled.Size = UDim2.new(0, 0, 0.1, 0)
	end
end

-- ═════════════════════════════════════════════════════════════════════════════
--  QUEUE ADVANCE / ENQUEUE / DEQUEUE
-- ═════════════════════════════════════════════════════════════════════════════
local requestQueueAdvance: () -> ()

local function advanceQueue()
	if queueAdvancing then return end
	if clientData.Current then return end
	if #researchQueue == 0 then return end

	local techId = researchQueue[1]
	queueAdvancing = true

	task.spawn(function()
		local ok, result = pcall(function() return StartResearch:InvokeServer(techId) end)
		queueAdvancing = false
		if ok and result == "Started" then
			if researchQueue[1] == techId then
				table.remove(researchQueue, 1)
			else
				for i, queuedId in ipairs(researchQueue) do
					if queuedId == techId then
						table.remove(researchQueue, i)
						break
					end
				end
			end
			renderQueue(); needsRender = true
			if isOpen then render() end
			return
		end

		warn("[ResearchFrameController] Queue advance failed:", techId, result)
		if result == "NotReady" or result == "Busy" or result == "RateLimited" then
			renderQueue(); needsRender = true
			if isOpen then render() end
			local retryDelay = result == "RateLimited" and 0.3 or 0.6
			task.delay(retryDelay, function()
				if not clientData.Current and researchQueue[1] == techId then
					advanceQueue()
				end
			end)
			return
		end

		for i, queuedId in ipairs(researchQueue) do
			if queuedId == techId then
				table.remove(researchQueue, i)
				break
			end
		end
		local tech = TechTree[techId]
		if tech and tech.Cost > 0 then
			clientData.RP = math.min(clientData.RP + tech.Cost, Config.MaxRP or 250000)
			updateHeader()
		end
		renderQueue(); needsRender = true
		if isOpen then render() end
	end)
end

requestQueueAdvance = function()
	if queueAdvancing then return end
	if clientData.Current then
		queuedResearchAdvancePending = false
		return
	end
	if #researchQueue == 0 then
		queuedResearchAdvancePending = false
		return
	end
	if not researchStateLoaded then
		queuedResearchAdvancePending = true
		return
	end
	queuedResearchAdvancePending = false
	advanceQueue()
end

local function dequeueAndRefund(techId: string)
	for i, id in ipairs(researchQueue) do
		if id == techId then table.remove(researchQueue, i); break end
	end
	local tech = TechTree[techId]
	if tech and tech.Cost > 0 then
		clientData.RP = math.min(clientData.RP + tech.Cost, Config.MaxRP or 250000)
		updateHeader()
	end
end

local function enqueueTech(techId: string)
	if clientData.Unlocked[techId] then return end
	if isInQueue(techId) then return end
	if clientData.Current and clientData.Current.Id == techId then return end
	if #researchQueue >= QUEUE_MAX then warn("[ResearchFrameController] Queue full"); return end

	if not researchStateLoaded then
		warn("[ResearchFrameController] Deferring research queue until the initial server snapshot arrives.")
	end

	local tech = TechTree[techId]
	if not tech then warn("[ResearchFrameController] Unknown tech:", techId); return end

	-- RP check: only block if we have a real RP value from the server (> 0)
	if clientData.RP > 0 and clientData.RP < tech.Cost then
		warn("[ResearchFrameController] Not enough RP:", clientData.RP, "<", tech.Cost); return
	end
	-- Deduct client-side for instant UI feedback
	if tech.Cost > 0 and clientData.RP >= tech.Cost then
		clientData.RP = math.max(0, clientData.RP - tech.Cost)
		updateHeader()
	end

	table.insert(researchQueue, techId)
	renderQueue(); needsRender = true
	if isOpen then render() end

	requestQueueAdvance()
end

-- ═════════════════════════════════════════════════════════════════════════════
--  RENDER QUEUE UI
-- ═════════════════════════════════════════════════════════════════════════════
renderQueue = function()
	if not QueueFrame then return end

	local activeSlots  = clientData.Current and 1 or 0
	local displayCount = math.max(QUEUE_MIN_DISPLAY, #researchQueue + activeSlots)
	displayCount = math.min(displayCount, QUEUE_MAX)

	-- Fix LayoutOrder on the 2 Studio Padding instances
	local studioPaddings: {GuiObject} = {}
	for _, child in ipairs(QueueFrame:GetChildren()) do
		if child.Name == "Padding" and not child:GetAttribute("QueueGenerated") and child:IsA("GuiObject") then
			table.insert(studioPaddings, child)
		end
	end
	table.sort(studioPaddings, function(a,b) return a.LayoutOrder > b.LayoutOrder end)
	for i, pad in ipairs(studioPaddings) do
		pad.LayoutOrder = (displayCount - i) * 2  -- even numbers between slot odd-LOs
	end

	local paddingTemplate: GuiObject? = studioPaddings[1] or QueueFrame:FindFirstChild("Padding")

	for slotIndex = 1, displayCount do
		local slotFrame = getOrCreateSlotFrame(slotIndex)
		if not slotFrame then continue end

		cleanHoverConns(slotIndex)
		stopBarTween(slotIndex)

		-- Slot 1 = active research; rest = queue items
		local techId: string?
		if clientData.Current then
			techId = slotIndex == 1 and clientData.Current.Id or researchQueue[slotIndex - 1]
		else
			techId = researchQueue[slotIndex]
		end

		local isEmpty = techId == nil
		local isActive = slotIndex == 1 and clientData.Current ~= nil

		-- Nr label
		local nrLabel = slotFrame:FindFirstChild("Nr") :: TextLabel?
		if nrLabel then
			nrLabel.RichText = true
			nrLabel.Text = "#<b>" .. tostring(slotIndex) .. "</b>"
		end

		-- Name label
		local nameLabel = slotFrame:FindFirstChild("Name") :: TextLabel?
		if nameLabel then
			if isEmpty then
				nameLabel.RichText = true; nameLabel.Text = EMPTY_SLOT_TEXT
			else
				nameLabel.RichText = false
				local tech = TechTree[techId :: string]
				nameLabel.Text = tech and tech.Name or (techId :: string):gsub("_"," ")
			end
		end

		animateBar(slotIndex, slotFrame, techId)

		local hoverDel = slotFrame:FindFirstChild("HoverDel") :: CanvasGroup?
		if hoverDel then
			hoverDel.Visible = not isEmpty and not isActive
			hoverDel.GroupTransparency = 1
		end

		if not isEmpty and not isActive and techId then
			local capId = techId :: string
			local capFrame = slotFrame

			local function showDel()
				if hoverDel then TweenService:Create(hoverDel,
					TweenInfo.new(0.3, Enum.EasingStyle.Quart, Enum.EasingDirection.Out),
					{ GroupTransparency=0 }):Play() end
			end
			local function hideDel()
				if hoverDel then TweenService:Create(hoverDel,
					TweenInfo.new(0.4, Enum.EasingStyle.Quart, Enum.EasingDirection.In),
					{ GroupTransparency=1 }):Play() end
			end

			local c1 = slotFrame.MouseEnter:Connect(showDel)
			local c2 = slotFrame.MouseLeave:Connect(hideDel)
			local c3 = slotFrame.InputBegan:Connect(function(input)
				if input.UserInputType == Enum.UserInputType.Touch then showDel(); task.delay(2, hideDel) end
			end)
			table.insert(queueHoverConnsList[slotIndex], c1)
			table.insert(queueHoverConnsList[slotIndex], c2)
			table.insert(queueHoverConnsList[slotIndex], c3)

			local hitbox = hoverDel and hoverDel:FindFirstChild("Hitbox")
			if hitbox then
				local c4 = hitbox.InputBegan:Connect(function(input)
					if input.UserInputType == Enum.UserInputType.MouseButton1
						or input.UserInputType == Enum.UserInputType.Touch then
						cleanHoverConns(slotIndex)
						animateSlotOut(capFrame, function()
							dequeueAndRefund(capId)
							renderQueue(); needsRender = true
							if isOpen then render() end
						end)
					end
				end)
				table.insert(queueHoverConnsList[slotIndex], c4)
			end
		end

		-- Reversed LayoutOrder: slot 1 = bottom (highest LO)
		local slotLO = (displayCount - slotIndex) * 2 + 1
		slotFrame.LayoutOrder = slotLO

		-- Generated padding between slots 4+
		local padName = "Generated_QueuePadding_"..slotIndex
		local existingPad = QueueFrame:FindFirstChild(padName)
		if existingPad then existingPad:Destroy() end
		if paddingTemplate and slotIndex >= 3 and slotIndex < displayCount then
			local pad = paddingTemplate:Clone()
			pad.Name = padName; pad:SetAttribute("QueueGenerated", true)
			pad.LayoutOrder = slotLO - 1; pad.Visible = true; pad.Parent = QueueFrame
		end

		slotFrame.Visible = true
	end

	-- Hide unused slots
	for idx = displayCount + 1, QUEUE_MAX do
		local ex = QueueFrame:FindFirstChild("Template"..idx)
		if ex and ex:IsA("Frame") then ex.Visible = false end
		local pad = QueueFrame:FindFirstChild("Generated_QueuePadding_"..idx)
		if pad then pad:Destroy() end
	end
end

-- ═════════════════════════════════════════════════════════════════════════════
--  CONTENT TREE RENDER
-- ═════════════════════════════════════════════════════════════════════════════
local function getTemplatePixelSize(template: Frame): Vector2
	local abs = Content.AbsoluteSize
	local w = math.floor(((template.Size.X.Scale*abs.X)+template.Size.X.Offset)*nodeScale+.5)
	local h = math.floor(((template.Size.Y.Scale*abs.Y)+template.Size.Y.Offset)*nodeScale+.5)
	return Vector2.new(math.max(250,w), math.max(154,h))
end

local function buildLayout(nodeSize: Vector2)
	local positions: {[string]: Vector2} = {}
	local farX, farY = 0, 0
	if LayoutConfig and type(LayoutConfig.NodeLayout) == "table" then
		for techId in pairs(TechTree) do
			local info = LayoutConfig.NodeLayout[techId]
			local col = info and tonumber(info.Column)
			local row = info and tonumber(info.Row)
			if col ~= nil and row ~= nil then
				local pos = Vector2.new(
					TREE_PAD_X + (math.floor(col+.5)*(nodeSize.X+COL_GAP)),
					TREE_PAD_Y + ((math.max(1,math.floor(row+.5))-1)*(nodeSize.Y+ROW_GAP))
				)
				positions[techId] = pos
			else
				positions[techId] = Vector2.new(TREE_PAD_X, TREE_PAD_Y)
			end
		end
	else
		local ordered = {}
		for id in pairs(TechTree) do table.insert(ordered, id) end
		table.sort(ordered)
		for i, id in ipairs(ordered) do
			positions[id] = Vector2.new(TREE_PAD_X+(i-1)*(nodeSize.X+COL_GAP), TREE_PAD_Y)
		end
	end
	for _, pos in pairs(positions) do farX=math.max(farX,pos.X); farY=math.max(farY,pos.Y) end
	return positions, Vector2.new(farX+nodeSize.X+TREE_PAD_X, farY+nodeSize.Y+TREE_PAD_Y)
end

local function isPointInGui(gui: GuiObject?, pt: Vector2): boolean
	if not gui then return false end
	local p=gui.AbsolutePosition; local s=gui.AbsoluteSize
	return pt.X>=p.X and pt.X<=p.X+s.X and pt.Y>=p.Y and pt.Y<=p.Y+s.Y
end

local function getResearchBonusText(tech): string
	local bonusMap = type(Config.ResearchBonuses)=="table" and Config.ResearchBonuses or nil
	local bonus = bonusMap and bonusMap[tech.Id]
	if type(bonus) ~= "table" then return "" end
	local parts = {}
	if type(bonus.Discounts) == "table" then
		for _, b in ipairs({
			{key="Lifts",label="lift costs"},{key="Slopes",label="slope costs"},
			{key="Buildings",label="building costs"},{key="Snow",label="snowmaking costs"}
			}) do
			local amt = tonumber(bonus.Discounts[b.key]) or 0
			if amt > 0 then table.insert(parts, string.format("%d%% cheaper %s", math.floor(amt*100+.5), b.label)) end
		end
	end
	local ib = tonumber(bonus.IncomeBonus) or 0
	if ib > 0 then table.insert(parts, string.format("%d%% more income", math.floor(ib*100+.5))) end
	if #parts == 0 then return "" end
	return "\nBonus: "..table.concat(parts, " • ")
end

local function setCardText(card: Frame, tech, state: string)
	local labels = {}
	for _, child in ipairs(card:GetChildren()) do
		if child:IsA("TextLabel") then table.insert(labels, child) end
	end
	table.sort(labels, function(a,b)
		if a.TextSize ~= b.TextSize then return a.TextSize > b.TextSize end
		return a.AbsolutePosition.Y < b.AbsolutePosition.Y
	end)
	local title=labels[1]; local desc=labels[2]
	if title then title.Text = tech.Name end
	if desc then
		local meta = string.format("%s • %s RP • %s",
			string.upper(tostring(tech.Branch or "General")), formatRP(tech.Cost), formatTime(tech.Time))
		local unlocks = #tech.Unlocks > 0 and ("\nUnlocks: "..table.concat(tech.Unlocks,", ")) or ""
		local bonus = getResearchBonusText(tech)
		if state == "Researching" and clientData.Current then
			desc.Text = string.format("Time left: %s\n%s%s%s",
				formatTime(math.max(0,clientData.Current.EndTime-os.time())), meta, bonus, unlocks)
		elseif state == "Locked" then
			local names = {}
			for _, rId in ipairs(tech.Reqs) do
				table.insert(names, TechTree[rId] and TechTree[rId].Name or rId)
			end
			desc.Text = string.format("Requires: %s\n%s\n%s%s", table.concat(names,", "), meta, tech.Desc, bonus)
		elseif state == "Unlocked" then
			desc.Text = string.format("%s\n%s%s\nUnlocked%s", meta, tech.Desc, bonus, unlocks)
		else
			desc.Text = string.format("%s\n%s%s%s", meta, tech.Desc, bonus, unlocks)
		end
		desc.TextWrapped=true; desc.TextYAlignment=Enum.TextYAlignment.Top
	end
	local lockFrame = card:FindFirstChild("Frame")
	if lockFrame and lockFrame:IsA("Frame") then lockFrame.Visible = state=="Locked" end
end

local function clearGenerated()
	renderedNodes = {}
	for _, child in ipairs(Content:GetChildren()) do
		if child:GetAttribute("ResearchGenerated") == true then child:Destroy() end
	end
end

local function applyLineColor(line: Frame, color: Color3)
	line.BackgroundColor3 = color
	for _, d in ipairs(line:GetDescendants()) do
		if d:IsA("UIStroke") then d.Color=color
		elseif d:IsA("UIGradient") then d.Color=ColorSequence.new(color,color) end
	end
end

local function createLaneDecor(nodeSize: Vector2, canvasSize: Vector2)
	if not LayoutConfig or type(LayoutConfig.Lanes) ~= "table" then return end
	for _, lane in ipairs(LayoutConfig.Lanes) do
		local sr=tonumber(lane.StartRow); local er=tonumber(lane.EndRow)
		if sr and er then
			local lc = typeof(lane.Color)=="Color3" and lane.Color or Color3.fromRGB(120,160,255)
			local margin = math.floor(ROW_GAP/2)-4
			local top    = TREE_PAD_Y+((sr-1)*(nodeSize.Y+ROW_GAP))-margin
			local bottom = TREE_PAD_Y+((er-1)*(nodeSize.Y+ROW_GAP))+nodeSize.Y+margin
			local stripe = Instance.new("Frame")
			stripe.Name="Generated_Lane_"..tostring(lane.Id or lane.Label or "Lane")
			stripe:SetAttribute("ResearchGenerated",true)
			stripe.BackgroundColor3=lc; stripe.BackgroundTransparency=0.9
			stripe.BorderSizePixel=0; stripe.ZIndex=1
			stripe.Position=UDim2.fromOffset(12,top)
			stripe.Size=UDim2.fromOffset(math.max(0,canvasSize.X-24), math.max(24,bottom-top))
			stripe.Parent=Content
			local stk=Instance.new("UIStroke"); stk.Color=lc; stk.Transparency=0.35; stk.Thickness=1; stk.Parent=stripe
			local cor=Instance.new("UICorner"); cor.CornerRadius=UDim.new(0,14); cor.Parent=stripe
			local lbl=Instance.new("TextLabel"); lbl.BackgroundTransparency=1
			lbl.Text=tostring(lane.Label or lane.Id or "CATEGORY")
			lbl.Font=Enum.Font.GothamBold; lbl.TextSize=16; lbl.TextXAlignment=Enum.TextXAlignment.Left
			lbl.TextColor3=lc:Lerp(Color3.new(1,1,1),0.18); lbl.ZIndex=2
			lbl.Position=UDim2.fromOffset(20,10); lbl.Size=UDim2.new(1,-40,0,22); lbl.Parent=stripe
		end
	end
end

local lineColors = {
	Locked="Locked", Available="Available", Researching="Available", Unlocked="Unlocked"
}
local lineColorValues = {
	Locked=Color3.fromRGB(225,225,225), Available=Color3.fromRGB(35,86,255), Unlocked=Color3.fromRGB(69,245,69)
}

local function makeSegment(fromPos: Vector2, toPos: Vector2, state: string)
	local line = lineTemplate:Clone()
	line.Name="Generated_Line"; line:SetAttribute("ResearchGenerated",true)
	line.Visible=true; line.ZIndex=2; line.AnchorPoint=Vector2.zero
	line.Position=UDim2.fromOffset(math.min(fromPos.X,toPos.X), math.min(fromPos.Y,toPos.Y))
	local thickness = math.max(4, lineTemplate.Size.Y.Offset)
	if fromPos.X ~= toPos.X then
		line.Size=UDim2.fromOffset(math.max(1,math.abs(toPos.X-fromPos.X)), thickness)
	else
		line.Size=UDim2.fromOffset(thickness, math.max(1,math.abs(toPos.Y-fromPos.Y)))
	end
	local colorKey = lineColors[state] or "Locked"
	applyLineColor(line, lineColorValues[colorKey] or lineColorValues.Locked)
	line.Parent=Content
end

local function connect(parentPos: Vector2, childPos: Vector2, nodeSize: Vector2, state: string)
	local startPos=Vector2.new(parentPos.X+nodeSize.X, parentPos.Y+nodeSize.Y*.5)
	local endPos=Vector2.new(childPos.X, childPos.Y+nodeSize.Y*.5)
	local midX=math.floor((startPos.X+endPos.X)*.5)
	makeSegment(startPos, Vector2.new(midX,startPos.Y), state)
	makeSegment(Vector2.new(midX,startPos.Y), Vector2.new(midX,endPos.Y), state)
	makeSegment(Vector2.new(midX,endPos.Y), endPos, state)
end

render = function()
	if not needsRender then return end
	needsRender = false
	hideTemplates(); clearGenerated(); updateHeader()

	local nodeSize = getTemplatePixelSize(templateAvailable)
	local positions, canvasSize = buildLayout(nodeSize)
	Content.CanvasSize = UDim2.fromOffset(canvasSize.X, canvasSize.Y)
	createLaneDecor(nodeSize, canvasSize)

	for parentId, children in pairs(ChildMap) do
		local pPos = positions[parentId]
		if pPos then
			for _, childId in ipairs(children) do
				local cPos = positions[childId]
				if cPos then connect(pPos, cPos, nodeSize, getNodeState(childId)) end
			end
		end
	end

	for techId, tech in pairs(TechTree) do
		local pos = positions[techId]
		if not pos then continue end

		local state = getNodeState(techId)
		local tmpl = templateLocked
		if state == "Unlocked" then tmpl = templateBought
		elseif state == "Available" or state == "Researching" then tmpl = templateAvailable end

		local node = tmpl:Clone()
		node.Name = "Generated_Node_"..techId
		node:SetAttribute("ResearchGenerated", true)
		node.Visible = true
		node.Position = UDim2.fromOffset(pos.X, pos.Y)
		node.Size = UDim2.fromOffset(nodeSize.X, nodeSize.Y)
		node.ZIndex = 5

		for _, d in ipairs(node:GetDescendants()) do
			if d:IsA("GuiObject") then d.ZIndex = math.max(d.ZIndex, node.ZIndex+1) end
		end

		setCardText(node, tech, state)

		if state == "Available" then
			local clickSurface = Instance.new("TextButton")
			clickSurface.Name = "ClickSurface"
			clickSurface.BackgroundTransparency = 1
			clickSurface.BorderSizePixel = 0
			clickSurface.Text = ""
			clickSurface.AutoButtonColor = false
			clickSurface.Active = true
			clickSurface.Selectable = true
			clickSurface.Size = UDim2.fromScale(1, 1)
			clickSurface.ZIndex = node.ZIndex + 8
			clickSurface.Parent = node
			local capId = techId
			bindGuiButton(clickSurface, function()
				enqueueTech(capId)
			end)
		end

		node.Parent = Content
		renderedNodes[techId] = node
	end
end

-- ═════════════════════════════════════════════════════════════════════════════
--  CANVAS PAN
-- ═════════════════════════════════════════════════════════════════════════════
local canvasPanning = false
local canvasPanInput: InputObject? = nil
local canvasPanStart: Vector2? = nil
local canvasPanCanvasStart: Vector2? = nil
local canvasPanMoved = 0
local clickedNodeTechId: string? = nil
local CLICK_THRESHOLD = 6

local function findNodeUnderPoint(pt: Vector2): string?
	for techId, node in pairs(renderedNodes) do
		if node.Parent and node.Visible and isPointInGui(node, pt) then return techId end
	end
	return nil
end

local function stopCanvasPan()
	canvasPanning=false; canvasPanInput=nil; canvasPanStart=nil
	canvasPanCanvasStart=nil; canvasPanMoved=0; clickedNodeTechId=nil
end

local function finalizeCanvasInteraction(input: InputObject?)
	if input and canvasPanInput and input ~= canvasPanInput then return end
	local techId = clickedNodeTechId
	local shouldActivate = canvasPanMoved < CLICK_THRESHOLD and techId ~= nil and getNodeState(techId) == "Available"
	stopCanvasPan()
	if shouldActivate and techId then enqueueTech(techId) end
end

-- ═════════════════════════════════════════════════════════════════════════════
--  OPEN / CLOSE
-- ═════════════════════════════════════════════════════════════════════════════
local function applyResponsiveLayout()
	needsRender = true; if isOpen then render() end
end

local function setOpen(open: boolean)
	if isOpen == open then return end
	isOpen = open
	local uiScale = ResearchFrame:FindFirstChildOfClass("UIScale") or Instance.new("UIScale", ResearchFrame)
	if open then
		ClosePanels:Fire("Research"); applyResponsiveLayout()
		ResearchFrame.Visible = true; ResearchFrame.Position = UDim2.new(0.5,0,0.5,0)
		uiScale.Scale = 0.85
		TweenService:Create(uiScale, TweenInfo.new(0.3,Enum.EasingStyle.Back,Enum.EasingDirection.Out), {Scale=1}):Play()
		needsRender = true; render(); renderQueue()
		task.defer(updateRPTooltipPlacement)
	else
		setRPTooltipVisible(false)
		local t = TweenService:Create(uiScale, TweenInfo.new(0.2,Enum.EasingStyle.Quad,Enum.EasingDirection.In), {Scale=0.85})
		t:Play()
		t.Completed:Once(function() if not isOpen then ResearchFrame.Visible=false end end)
	end
end

-- ═════════════════════════════════════════════════════════════════════════════
--  SNAPSHOT
-- ═════════════════════════════════════════════════════════════════════════════
local function applySnapshot(snapshot: any)
	local sanitized = sanitizeSnapshot(snapshot)
	local incomingRevision = sanitized.Revision
	if incomingRevision and incomingRevision < latestSnapshotRevision then
		return
	end
	if incomingRevision then
		latestSnapshotRevision = incomingRevision
	end

	local prevCurrent = clientData.Current
	clientData = sanitized
	researchStateLoaded = true

	if prevCurrent and not clientData.Current then
		local slot1 = getOrCreateSlotFrame(1)
		if slot1 and slot1.Visible then
			animateSlotOut(slot1, function()
				task.defer(requestQueueAdvance)
				renderQueue(); needsRender=true
				if isOpen then render() end
			end)
		else
			task.defer(requestQueueAdvance)
		end
	end

	updateHeader(); needsRender=true; renderQueue()
	if queuedResearchAdvancePending then
		task.defer(requestQueueAdvance)
	end
	if isOpen then render() end
end

-- ═════════════════════════════════════════════════════════════════════════════
--  WIRING
-- ═════════════════════════════════════════════════════════════════════════════
bindGuiButton(ResearchButton, function() setOpen(not isOpen) end)
bindGuiButton(CloseButton,    function() setOpen(false) end)

ClosePanels.Event:Connect(function(source)
	if source ~= "Research" and isOpen then setOpen(false) end
end)

ResearchUpdate.OnClientEvent:Connect(function(snapshot) applySnapshot(snapshot) end)

Content:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
	needsRender=true; if isOpen then render(); updateRPTooltipPlacement() end
end)

Content.Active = true
Content.InputBegan:Connect(function(input)
	if not isOpen then return end
	if input.UserInputType ~= Enum.UserInputType.MouseButton1 and input.UserInputType ~= Enum.UserInputType.Touch then return end
	canvasPanStart=Vector2.new(input.Position.X, input.Position.Y)
	canvasPanCanvasStart=Content.CanvasPosition; canvasPanMoved=0
	clickedNodeTechId=findNodeUnderPoint(canvasPanStart)
	-- Track every press so tap-to-enqueue still works when ScrollingFrame consumes button activation.
	canvasPanning=true; canvasPanInput=input
end)

Content.InputChanged:Connect(function(input)
	if not canvasPanning then return end
	if input.UserInputType ~= Enum.UserInputType.MouseMovement and input.UserInputType ~= Enum.UserInputType.Touch then return end
	if not canvasPanStart or not canvasPanCanvasStart then stopCanvasPan(); return end
	local cur = Vector2.new(input.Position.X, input.Position.Y)
	local delta = cur - canvasPanStart
	canvasPanMoved = math.max(canvasPanMoved, delta.Magnitude)
	if canvasPanMoved < CLICK_THRESHOLD then return end
	local target = canvasPanCanvasStart - delta
	local maxX = math.max(0, Content.CanvasSize.X.Offset - Content.AbsoluteSize.X)
	local maxY = math.max(0, Content.CanvasSize.Y.Offset - Content.AbsoluteSize.Y)
	Content.CanvasPosition = Vector2.new(math.clamp(target.X,0,maxX), math.clamp(target.Y,0,maxY))
end)

Content.InputEnded:Connect(function(input) finalizeCanvasInteraction(input) end)

UserInputService.InputBegan:Connect(function(input, processed)
	if UserInputService:GetFocusedTextBox() then return end
	if processed then return end
	if isOpen and input.KeyCode == Enum.KeyCode.Escape then setOpen(false) end
end)

UserInputService.InputEnded:Connect(function(input)
	if input == canvasPanInput then finalizeCanvasInteraction(input) end
end)

local function hookCamera(cam: Camera?)
	if not cam then return end
	cam:GetPropertyChangedSignal("ViewportSize"):Connect(function()
		applyResponsiveLayout(); updateRPTooltipPlacement()
	end)
end
hookCamera(Workspace.CurrentCamera)
Workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
	hookCamera(Workspace.CurrentCamera); task.defer(applyResponsiveLayout)
end)

-- ═════════════════════════════════════════════════════════════════════════════
--  RENDERSTEP
-- ═════════════════════════════════════════════════════════════════════════════
RunService.RenderStepped:Connect(function()
	if not isOpen then return end
	local now = os.clock()
	if now - lastClockTick < 0.2 then return end
	lastClockTick = now
	updateHeader()
	if clientData.Current then
		local node = renderedNodes[clientData.Current.Id]
		if node then setCardText(node, TechTree[clientData.Current.Id], "Researching") end
		if os.time() >= clientData.Current.EndTime and not advanceScheduled and not queueAdvancing then
			advanceScheduled = true
			task.delay(0.6, function()
				if not clientData.Current and #researchQueue > 0 then advanceQueue() end
				advanceScheduled = false
			end)
		end
	end
end)

-- ═════════════════════════════════════════════════════════════════════════════
--  INIT
-- ═════════════════════════════════════════════════════════════════════════════
ResearchFrame.AnchorPoint = Vector2.new(0.5, 0.5)
ResearchFrame.Visible = false
ResearchFrame.Position = UDim2.new(0.5, 0, 1.5, 0)

applyResponsiveLayout()
updateHeader()
renderQueue()

local INITIAL_SNAPSHOT_MAX_ATTEMPTS = 12
local INITIAL_SNAPSHOT_RETRY_DELAY = 1.0
local initialSnapshotAttempts = 0

local function requestInitialResearchSnapshot()
	if researchStateLoaded or not Player.Parent then
		return
	end

	initialSnapshotAttempts += 1
	local ok, snapshot = pcall(function()
		return GetResearchState:InvokeServer()
	end)
	if ok and type(snapshot) == "table" then
		applySnapshot(snapshot)
		return
	end

	if initialSnapshotAttempts < INITIAL_SNAPSHOT_MAX_ATTEMPTS then
		warn(string.format("[ResearchFrameController] Failed to get initial research state (attempt %d/%d); retrying.", initialSnapshotAttempts, INITIAL_SNAPSHOT_MAX_ATTEMPTS))
		task.delay(INITIAL_SNAPSHOT_RETRY_DELAY, requestInitialResearchSnapshot)
	else
		warn("[ResearchFrameController] Failed to get initial research state after retries")
	end
end

requestInitialResearchSnapshot()

print("ResearchFrameController Online")