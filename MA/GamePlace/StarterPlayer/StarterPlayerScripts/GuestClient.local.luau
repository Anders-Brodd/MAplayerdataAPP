--[=[ PATH: StarterPlayerScripts/GuestClient | TYPE: LocalScript ]=]--
--[[
	👥 GUEST CLIENT V10.0 — VISUAL & UI LAYER
	
	This is a PURE VISUAL script. All guest AI runs on the server.
	This script handles:
	• Speech bubbles (from server events)
	• Ski model attachment visuals
	• Click-to-inspect info panel
	• Skiing visual effects (snow spray)
	• Attribute-driven UI updates
	
	NO AI LOGIC HERE. Server controls everything.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Player = Players.LocalPlayer
local PlayerGui = Player:WaitForChild("PlayerGui")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local GraphicsProfile = require(Shared:WaitForChild("GraphicsProfile"))
local SkiStateSchema = require(Shared:WaitForChild("SkiStateSchema"))
local ProceduralSkiAnimator = require(Shared:WaitForChild("ProceduralSkiAnimator"))
local SkiMistVFX = require(Shared:WaitForChild("SkiMistVFX"))

local Events = ReplicatedStorage:WaitForChild("Events", 10)
local GuestSpeechEvent = Events and Events:FindFirstChild("GuestSpeech")
local GuestUpdateEvent = Events and Events:FindFirstChild("GuestUpdate")
local ClosePanels = Events and Events:FindFirstChild("ClosePanels")
if Events and not ClosePanels then
	ClosePanels = Instance.new("BindableEvent")
	ClosePanels.Name = "ClosePanels"
	ClosePanels.Parent = Events
end
local GuestFolder = ReplicatedStorage:FindFirstChild("Guest")
local GuestConfigModule = GuestFolder and (GuestFolder:FindFirstChild("GuestConfig") or GuestFolder:FindFirstChild("guestconfig"))
local GuestConfig = {}
if GuestConfigModule and GuestConfigModule:IsA("ModuleScript") then
	local ok, cfg = pcall(require, GuestConfigModule)
	if ok and type(cfg) == "table" then
		GuestConfig = cfg
	end
end

local perfCfg = (GuestConfig and GuestConfig.Performance) or {}
local WALKER_SMOOTHING_ENABLED = perfCfg.ClientWalkerSmoothingEnabled == true
local WALKER_SMOOTHING_DISTANCE = math.max(120, tonumber(perfCfg.ClientWalkerSmoothingDistance) or 300)

local CachedGuestModels = {}
local GuestVisualPartsCache = setmetatable({}, { __mode = "k" })
local GuestVisualOverlayCache = setmetatable({}, { __mode = "k" })
local GuestVisualPartWatch = setmetatable({}, { __mode = "k" })
local GuestVisualOverlayWatch = setmetatable({}, { __mode = "k" })
local GuestProceduralControllers = setmetatable({}, { __mode = "k" })
local GuestFolderWorkspace = nil
local GuestFolderAddedConn = nil
local GuestFolderRemovedConn = nil
local WorkspaceGuestAddedConn = nil
local WorkspaceGuestRemovedConn = nil
local GuestLifecycleWatch = setmetatable({}, { __mode = "k" })
local SkiSmoothCandidates = setmetatable({}, { __mode = "k" })
local GetGuestPerformanceModeLevel

local function DisconnectGuestLifecycleWatch(model)
	if not model then
		return
	end
	local connections = GuestLifecycleWatch[model]
	if connections then
		for _, connection in ipairs(connections) do
			connection:Disconnect()
		end
	end
	GuestLifecycleWatch[model] = nil
end

local function IsGuestMarkedSkiing(model)
	if not model then
		return false
	end
	if model:GetAttribute("IsSkiing") == true then
		return true
	end
	local state = tostring(model:GetAttribute("State") or "")
	return state == "SkiingDown" or state == "SkiingToSlope"
end

local function RefreshGuestSkiCandidate(model)
	if not model then
		return
	end
	if not model.Parent then
		SkiSmoothCandidates[model] = nil
		return
	end

	local ridingLift = model:GetAttribute("RidingLift")
	if IsGuestMarkedSkiing(model) and not ridingLift then
		SkiSmoothCandidates[model] = true
	else
		SkiSmoothCandidates[model] = nil
	end
end

local function TrackGuestLifecycle(model)
	if not model then
		return
	end

	if GuestLifecycleWatch[model] then
		RefreshGuestSkiCandidate(model)
		return
	end

	local connections = {}
	GuestLifecycleWatch[model] = connections

	local function bindAttribute(name)
		connections[#connections + 1] = model:GetAttributeChangedSignal(name):Connect(function()
			RefreshGuestSkiCandidate(model)
		end)
	end

	bindAttribute("IsSkiing")
	bindAttribute("State")
	bindAttribute("RidingLift")
	connections[#connections + 1] = model.AncestryChanged:Connect(function(_, parent)
		if not parent then
			SkiSmoothCandidates[model] = nil
			DisconnectGuestLifecycleWatch(model)
			return
		end
		RefreshGuestSkiCandidate(model)
	end)

	RefreshGuestSkiCandidate(model)
end

local function RemoveGuestFromCache(target)
	if not target then
		return
	end
	GuestVisualPartsCache[target] = nil
	GuestVisualOverlayCache[target] = nil
	GuestVisualPartWatch[target] = nil
	GuestVisualOverlayWatch[target] = nil
	SkiSmoothCandidates[target] = nil
	GuestProxyModeState[target] = nil
	DisconnectGuestLifecycleWatch(target)
	for i = #CachedGuestModels, 1, -1 do
		if CachedGuestModels[i] == target then
			table.remove(CachedGuestModels, i)
		end
	end
end

local function RebuildGuestCache()
	table.clear(CachedGuestModels)
	GuestFolderWorkspace = Workspace:FindFirstChild("Guests")
	if not GuestFolderWorkspace then return end
	for _, child in ipairs(GuestFolderWorkspace:GetChildren()) do
		if child:IsA("Model") then
			table.insert(CachedGuestModels, child)
			TrackGuestLifecycle(child)
		end
	end
end

local function BindGuestCache()
	if GuestFolderAddedConn then GuestFolderAddedConn:Disconnect(); GuestFolderAddedConn = nil end
	if GuestFolderRemovedConn then GuestFolderRemovedConn:Disconnect(); GuestFolderRemovedConn = nil end

	RebuildGuestCache()
	if not GuestFolderWorkspace then return end

	GuestFolderAddedConn = GuestFolderWorkspace.ChildAdded:Connect(function(child)
		if child:IsA("Model") then
			table.insert(CachedGuestModels, child)
			TrackGuestLifecycle(child)
		end
	end)

	GuestFolderRemovedConn = GuestFolderWorkspace.ChildRemoved:Connect(function(child)
		RemoveGuestFromCache(child)
	end)
end

WorkspaceGuestAddedConn = Workspace.ChildAdded:Connect(function(child)
	if child.Name == "Guests" then
		BindGuestCache()
	end
end)

WorkspaceGuestRemovedConn = Workspace.ChildRemoved:Connect(function(child)
	if child == GuestFolderWorkspace then
		BindGuestCache()
	end
end)

BindGuestCache()

local function GetGuestVisualParts(model)
	local cached = GuestVisualPartsCache[model]
	if cached then
		return cached
	end
	local parts = {}
	for _, desc in ipairs(model:GetDescendants()) do
		if desc:IsA("BasePart") then
			table.insert(parts, desc)
		end
	end
	GuestVisualPartsCache[model] = parts
	if not GuestVisualPartWatch[model] then
		GuestVisualPartWatch[model] = true
		model.DescendantAdded:Connect(function(desc)
			if desc:IsA("BasePart") then
				local current = GuestVisualPartsCache[model]
				if current then
					table.insert(current, desc)
				end
			end
		end)
	end
	return parts
end

local function GetGuestVisualOverlays(model)
	local cached = GuestVisualOverlayCache[model]
	if cached then
		return cached
	end
	local overlays = {}
	for _, desc in ipairs(model:GetDescendants()) do
		if desc:IsA("Decal") or desc:IsA("Texture") then
			table.insert(overlays, desc)
		end
	end
	GuestVisualOverlayCache[model] = overlays
	if not GuestVisualOverlayWatch[model] then
		GuestVisualOverlayWatch[model] = true
		model.DescendantAdded:Connect(function(desc)
			if desc:IsA("Decal") or desc:IsA("Texture") then
				local current = GuestVisualOverlayCache[model]
				if current then
					table.insert(current, desc)
				end
			end
		end)
	end
	return overlays
end

local function SetGuestModelLocalCulled(model, isCulled)
	if not model then
		return
	end
	model:SetAttribute("_Culled", isCulled and true or nil)
	for _, part in ipairs(GetGuestVisualParts(model)) do
		if part.Parent then
			part.LocalTransparencyModifier = isCulled and 1 or 0
			-- Legacy cleanup: older builds stored _OrigTransparency and sometimes left it at 1,
			-- which can make guests stay visually invisible after uncull.
			if part:GetAttribute("_OrigTransparency") ~= nil then
				part:SetAttribute("_OrigTransparency", nil)
			end
		end
	end
	for _, overlay in ipairs(GetGuestVisualOverlays(model)) do
		if overlay.Parent then
			if isCulled then
				if overlay:GetAttribute("_GuestOrigOverlayTransparency") == nil then
					overlay:SetAttribute("_GuestOrigOverlayTransparency", overlay.Transparency)
				end
				overlay.Transparency = 1
			else
				local originalTransparency = overlay:GetAttribute("_GuestOrigOverlayTransparency")
				if originalTransparency ~= nil then
					overlay.Transparency = originalTransparency
					overlay:SetAttribute("_GuestOrigOverlayTransparency", nil)
				end
			end
		end
	end
end

local GuestProxyModeState = setmetatable({}, { __mode = "k" })

local function SetGuestModelProxyMode(model, enabled)
	if not model then
		return
	end
	local desired = enabled == true
	if (GuestProxyModeState[model] == true) == desired then
		return
	end
	local isCulled = model:GetAttribute("_Culled") == true
	if desired then
		if isCulled then
			SetGuestModelLocalCulled(model, false)
		end
		GuestProxyModeState[model] = true
	else
		GuestProxyModeState[model] = nil
		if isCulled then
			return
		end
	end

	local root = model:FindFirstChild("HumanoidRootPart")
	for _, part in ipairs(GetGuestVisualParts(model)) do
		if part.Parent then
			if desired then
				part.LocalTransparencyModifier = (root and part == root) and 0 or 1
			else
				part.LocalTransparencyModifier = 0
			end
		end
	end

	for _, overlay in ipairs(GetGuestVisualOverlays(model)) do
		if overlay.Parent then
			if desired then
				if overlay:GetAttribute("_GuestOrigOverlayTransparency") == nil then
					overlay:SetAttribute("_GuestOrigOverlayTransparency", overlay.Transparency)
				end
				overlay.Transparency = 1
			else
				local originalTransparency = overlay:GetAttribute("_GuestOrigOverlayTransparency")
				if originalTransparency ~= nil then
					overlay.Transparency = originalTransparency
					overlay:SetAttribute("_GuestOrigOverlayTransparency", nil)
				end
			end
		end
	end
end

local function bindGuiButton(button, callback)
	if not (button and callback) then return end
	button.Active = true
	button.Selectable = true
	button.AutoButtonColor = true
	local firedAt = 0
	local function fire()
		local now = os.clock()
		if now - firedAt < 0.2 then return end
		firedAt = now
		callback()
	end
	if button:IsA("GuiButton") then
		button.Activated:Connect(fire)
	else
		button.InputBegan:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.Touch or input.UserInputType == Enum.UserInputType.MouseButton1 then
				fire()
			end
		end)
	end
end

-- ============================================================================
-- SPEECH LOG (track last N messages per guest for info panel)
-- ============================================================================
local GuestSpeechLogs = {} -- { [model] = { "msg1", "msg2", ... } }
local MAX_SPEECH_LOG = 8

local function LogGuestSpeech(model, message)
	if not GuestSpeechLogs[model] then
		GuestSpeechLogs[model] = {}
	end
	table.insert(GuestSpeechLogs[model], message)
	while #GuestSpeechLogs[model] > MAX_SPEECH_LOG do
		table.remove(GuestSpeechLogs[model], 1)
	end
end

-- ============================================================================
-- SPEECH BUBBLE SYSTEM
-- ============================================================================
local function CreateSpeechBubble(model, message, duration)
	if not model or not model.Parent then return end
	local root = model:FindFirstChild("HumanoidRootPart")
	if not root then return end

	duration = duration or 4
	if GetGuestPerformanceModeLevel() >= 2 then
		return
	end

	local existing = root:FindFirstChild("SpeechBubble")
	if existing then existing:Destroy() end

	if not message or message == "" then return end

	local bubble = Instance.new("BillboardGui")
	bubble.Name = "SpeechBubble"
	bubble.Size = UDim2.new(0, 180, 0, 50)
	bubble.ExtentsOffsetWorldSpace = Vector3.new(0, 7, 0)
	bubble.MaxDistance = 60
	bubble.Parent = root

	local bg = Instance.new("Frame", bubble)
	bg.Size = UDim2.new(1, 0, 1, 0)
	bg.BackgroundColor3 = Color3.new(1, 1, 1)
	bg.BackgroundTransparency = 0.08
	Instance.new("UICorner", bg).CornerRadius = UDim.new(0, 10)

	local shadow = Instance.new("ImageLabel", bg)
	shadow.Size = UDim2.new(1, 6, 1, 6)
	shadow.Position = UDim2.new(0, -3, 0, -3)
	shadow.BackgroundTransparency = 1
	shadow.ImageTransparency = 0.7
	shadow.ImageColor3 = Color3.new(0, 0, 0)
	shadow.ScaleType = Enum.ScaleType.Slice
	shadow.ZIndex = 0

	local text = Instance.new("TextLabel", bg)
	text.Size = UDim2.new(1, -12, 1, -8)
	text.Position = UDim2.new(0, 6, 0, 4)
	text.BackgroundTransparency = 1
	text.Text = message
	text.TextColor3 = Color3.fromRGB(30, 30, 30)
	text.Font = Enum.Font.GothamMedium
	text.TextSize = 13
	text.TextWrapped = true

	-- Animate in
	bg.BackgroundTransparency = 1
	text.TextTransparency = 1
	TweenService:Create(bg, TweenInfo.new(0.25), {BackgroundTransparency = 0.08}):Play()
	TweenService:Create(text, TweenInfo.new(0.25), {TextTransparency = 0}):Play()

	-- Auto-remove
	task.delay(duration, function()
		if bubble and bubble.Parent then
			TweenService:Create(bg, TweenInfo.new(0.2), {BackgroundTransparency = 1}):Play()
			TweenService:Create(text, TweenInfo.new(0.2), {TextTransparency = 1}):Play()
			task.delay(0.3, function()
				if bubble and bubble.Parent then bubble:Destroy() end
			end)
		end
	end)
end

if GuestSpeechEvent then
	GuestSpeechEvent.OnClientEvent:Connect(function(model, message, duration)
		CreateSpeechBubble(model, message, duration)
		if model and message then
			LogGuestSpeech(model, message)
		end
	end)
end

-- ============================================================================
-- SKI VISUAL ATTACHMENT (Attribute-driven)
-- ============================================================================
local function AttachSkisVisual(model)
	if model:FindFirstChild("GuestSkis") then return end

	local skiAsset = ReplicatedStorage:FindFirstChild("Assets")
		and ReplicatedStorage.Assets:FindFirstChild("Gear")
		and ReplicatedStorage.Assets.Gear:FindFirstChild("Skis")
	if not skiAsset then return end

	local skis = skiAsset:Clone()
	skis.Name = "GuestSkis"

	local function findLegFallback(sideToken)
		local side = string.lower(sideToken or "")
		for _, desc in ipairs(model:GetDescendants()) do
			if desc:IsA("BasePart") then
				local lowerName = string.lower(desc.Name)
				if string.find(lowerName, side, 1, true)
					and (
						string.find(lowerName, "foot", 1, true)
						or string.find(lowerName, "lowerleg", 1, true)
						or string.find(lowerName, "leg", 1, true)
					) then
					return desc
				end
			end
		end
		return nil
	end

	local leftLeg = model:FindFirstChild("Left Leg")
	local rightLeg = model:FindFirstChild("Right Leg")
	-- R15 and custom-rig fallback
	if not leftLeg then leftLeg = model:FindFirstChild("LeftFoot") or model:FindFirstChild("LeftLowerLeg") or findLegFallback("left") end
	if not rightLeg then rightLeg = model:FindFirstChild("RightFoot") or model:FindFirstChild("RightLowerLeg") or findLegFallback("right") end
	if not leftLeg or not rightLeg then return end

	local lSki = skis:FindFirstChild("LeftSki") or skis:FindFirstChild("Left")
	local rSki = skis:FindFirstChild("RightSki") or skis:FindFirstChild("Right")

	if not lSki then
		local children = skis:GetChildren()
		for _, c in ipairs(children) do if c:IsA("BasePart") then lSki = lSki or c; if lSki and c ~= lSki then rSki = c end end end
		if lSki and not rSki then rSki = lSki:Clone(); rSki.Name = "RightSki"; rSki.Parent = skis end
	end

	local function weldGuestSki(ski, footPart)
		local offset = CFrame.new(0, -1, 0.3) * CFrame.Angles(math.rad(90), 0, 0)
		ski.CFrame = footPart.CFrame * offset
		local weld = Instance.new("Weld")
		weld.Name = "GuestSkiWeld"
		weld.Part0 = footPart
		weld.Part1 = ski
		weld.C0 = offset
		weld.C1 = CFrame.identity
		weld.Parent = ski
	end

	if lSki and rSki then
		for _, p in ipairs(skis:GetDescendants()) do
			if p:IsA("BasePart") then p.CanCollide = false; p.CanQuery = false; p.CanTouch = false; p.Anchored = false; p.Massless = true end
		end

		weldGuestSki(lSki, leftLeg)

		weldGuestSki(rSki, rightLeg)

		skis.Parent = model
	end
end

local function DetachSkisVisual(model)
	local skis = model:FindFirstChild("GuestSkis")
	if skis then skis:Destroy() end
end

-- ============================================================================
-- SKIING PARTICLE EFFECTS
-- ============================================================================
local activeEffects = {}
local BASE_VISUAL_ACTIVE_DISTANCE = 420
local MIN_VISUAL_ACTIVE_DISTANCE = 220
local SKI_SMOOTH_DISTANCE = 1450

local RUNTIME_VISUAL_DISTANCE_MULT = {1.0, 0.75, 0.55, 0.4}
local RUNTIME_VISUAL_INTERVAL_MULT = {1.0, 1.35, 1.75, 2.3}
local RUNTIME_SMOOTH_INTERVAL = {0, 1 / 80, 1 / 55, 1 / 38}

local GUEST_PERF_MODE_LEVEL = {
	Off = 0,
	Balanced = 1,
	Aggressive = 2,
	Extreme = 3,
}

local GUEST_PERF_VISUAL_DISTANCE_MULT = {1.0, 0.82, 0.64, 0.48}
local GUEST_PERF_VISUAL_INTERVAL_MULT = {1.0, 1.2, 1.55, 2.0}
local GUEST_PERF_OFF_RENDER_DISTANCE = {0, 760, 470, 320}
local GUEST_PERF_MAX_VISIBLE_SCALE = {0, 0, 0.3, 0.16}
local GUEST_PERF_MAX_VISIBLE_MIN = {0, 0, 72, 40}
local GUEST_PERF_MAX_VISIBLE_MAX = {0, 0, 170, 92}

GetGuestPerformanceModeLevel = function()
	local rawMode = tostring(Player:GetAttribute("Settings_GuestPerformanceMode") or "Off")
	local direct = GUEST_PERF_MODE_LEVEL[rawMode]
	if direct ~= nil then
		return direct
	end
	local upperMode = string.upper(rawMode)
	if upperMode == "OFF" then
		return 0
	elseif upperMode == "AGGRESSIVE" then
		return 2
	elseif upperMode == "EXTREME" then
		return 3
	end
	return 1
end

local function GetRuntimePerfTier()
	local tier = tonumber(Player:GetAttribute("Settings_RuntimePerfTier"))
	if tier == nil then
		tier = tonumber(Player:GetAttribute("RuntimePerformanceTier"))
	end
	if tier == nil then
		return 0
	end
	return math.clamp(math.floor(tier + 0.5), 0, 3)
end

local function GetVisualActiveDistance(guestCount)
	local baseDistance = BASE_VISUAL_ACTIVE_DISTANCE
	if guestCount >= 1500 then
		baseDistance = MIN_VISUAL_ACTIVE_DISTANCE
	elseif guestCount >= 1200 then
		baseDistance = 240
	elseif guestCount >= 900 then
		baseDistance = 270
	elseif guestCount >= 650 then
		baseDistance = 300
	elseif guestCount >= 450 then
		baseDistance = 340
	elseif guestCount >= 280 then
		baseDistance = 375
	end
	local runtimeTier = GetRuntimePerfTier()
	local runtimeMult = RUNTIME_VISUAL_DISTANCE_MULT[runtimeTier + 1] or 1
	return math.max(150, baseDistance * runtimeMult)
end

local function GetNPCDistanceScale()
	return GraphicsProfile.GetDistanceScale(Player, "NPCRenderDistance")
end

local function GetGuestParticleScale()
	return GraphicsProfile.GetParticleScale(Player) * GraphicsProfile.GetParticleDensityScale(Player)
end

local function GetAdaptiveGuestParticleScale(dt)
	if not GraphicsProfile.IsAdaptiveParticlesEnabled(Player) then
		return 1
	end
	local fps = (dt > 0) and (1 / dt) or 60
	if fps >= 58 then return 1 end
	if fps <= 26 then return 0.35 end
	return math.clamp((fps - 26) / 32, 0.35, 1)
end

local function ApplyGuestEmitterStyle(p)
	local realistic = GraphicsProfile.IsRealisticParticlesEnabled(Player)
	if realistic then
		p.Size = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.22),
			NumberSequenceKeypoint.new(0.35, 1.05),
			NumberSequenceKeypoint.new(1, 0.18),
		})
		p.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.2),
			NumberSequenceKeypoint.new(0.6, 0.55),
			NumberSequenceKeypoint.new(1, 1),
		})
		p.Lifetime = NumberRange.new(0.35, 0.8)
		p.Speed = NumberRange.new(4, 12)
		p.Drag = 2.2
		p.Acceleration = Vector3.new(0, -7, 0)
		p.Rotation = NumberRange.new(0, 360)
		p.RotSpeed = NumberRange.new(-120, 120)
	else
		p.Size = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.5),
			NumberSequenceKeypoint.new(1, 2.0),
		})
		p.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.5),
			NumberSequenceKeypoint.new(1, 1),
		})
		p.Lifetime = NumberRange.new(0.3, 0.6)
		p.Speed = NumberRange.new(2, 5)
		p.Drag = 3
		p.Acceleration = Vector3.zero
		p.Rotation = NumberRange.new(0, 0)
		p.RotSpeed = NumberRange.new(0, 0)
	end
end

local function CreateSkiEffects(model)
	if activeEffects[model] then return end
	local root = model:FindFirstChild("HumanoidRootPart")
	if not root then return end

	activeEffects[model] = {
		Controller = SkiMistVFX.new(root, Player, GraphicsProfile),
	}
end

local function RemoveSkiEffects(model)
	local effects = activeEffects[model]
	if not effects then return end
	if effects.Controller then
		effects.Controller:Destroy()
	end
	for _, obj in pairs(effects) do
		if typeof(obj) == "Instance" then pcall(function() obj:Destroy() end) end
	end
	activeEffects[model] = nil
end

local function UpdateSkiEffects(model, dt, skiState)
	local effects = activeEffects[model]
	if not effects or not effects.Controller then return end
	local densityScale = GetGuestParticleScale()
	local adaptiveScale = GetAdaptiveGuestParticleScale(dt or 1 / 60)
	effects.Controller:Update(skiState, dt or (1 / 60), densityScale, adaptiveScale)
end

local function RefreshAllGuestParticleStyles()
	for _, effects in pairs(activeEffects) do
		if effects.Controller then
			effects.Controller:RefreshStyle()
		end
	end
end

Player:GetAttributeChangedSignal("Settings_RealisticParticles"):Connect(RefreshAllGuestParticleStyles)

-- ============================================================================
-- INFO PANEL — CLICK-TO-INSPECT
-- ============================================================================
local THEME = {
	Bg = Color3.fromRGB(13, 16, 22),
	Card = Color3.fromRGB(19, 23, 31),
	CardAlt = Color3.fromRGB(24, 29, 38),
	Accent = Color3.fromRGB(45, 125, 235),
	AccentSoft = Color3.fromRGB(93, 170, 255),
	Green = Color3.fromRGB(76, 209, 55),
	Yellow = Color3.fromRGB(255, 200, 50),
	Red = Color3.fromRGB(220, 60, 60),
	TextPrimary = Color3.new(1, 1, 1),
	TextSecondary = Color3.fromRGB(184, 190, 202),
	TextMuted = Color3.fromRGB(120, 128, 142),
	Border = Color3.fromRGB(44, 52, 66),
}

local SKILL_DATA = {
	[1] = {Name = "Green Circle", Color = Color3.fromRGB(76, 209, 55), Icon = "🟢"},
	[2] = {Name = "Blue Square", Color = Color3.fromRGB(52, 152, 219), Icon = "🔵"},
	[3] = {Name = "Black Diamond", Color = Color3.fromRGB(100, 100, 110), Icon = "◆"},
	[4] = {Name = "Double Black", Color = Color3.fromRGB(255, 215, 0), Icon = "◆◆"},
}

local InfoGui = nil
local infoPanel = nil
local infoBackdrop = nil
local currentTarget = nil
local isInfoOpen = false
local infoViewportConnection = nil

local function getInfoPanelLayout()
	local currentCamera = Workspace.CurrentCamera
	local viewport = currentCamera and currentCamera.ViewportSize or Vector2.new(1280, 720)
	if viewport.X <= 0 or viewport.Y <= 0 then
		viewport = Vector2.new(1280, 720)
	end
	local shortSide = math.min(viewport.X, viewport.Y)
	local isTouchLayout = UserInputService.TouchEnabled and shortSide <= 1100
	local width = math.clamp(math.floor(viewport.X * (isTouchLayout and 0.74 or 0.3)), isTouchLayout and 310 or 350, isTouchLayout and 400 or 430)
	local height = math.clamp(math.floor(viewport.Y * (isTouchLayout and 0.58 or 0.7)), isTouchLayout and 400 or 500, isTouchLayout and 540 or 650)
	return {
		isTouchLayout = isTouchLayout,
		width = width,
		height = height,
		headerHeight = isTouchLayout and 84 or 92,
		openPosition = UDim2.new(0.5, 0, 0.5, 0),
		closedPosition = UDim2.new(0.5, 0, 1.55, 0),
	}
end

local function applyInfoPanelLayout()
	if not infoPanel then return end
	local layout = getInfoPanelLayout()
	infoPanel.AnchorPoint = Vector2.new(0.5, 0.5)
	infoPanel.Size = UDim2.fromOffset(layout.width, layout.height)
	infoPanel.Position = isInfoOpen and layout.openPosition or layout.closedPosition

	if infoBackdrop then
		infoBackdrop.Size = UDim2.new(1, 0, 1, 0)
	end

	local header = infoPanel:FindFirstChild("Header")
	if header and header:IsA("GuiObject") then
		header.Size = UDim2.new(1, 0, 0, layout.headerHeight)
		local closeBtn = header:FindFirstChild("CloseButton")
		if closeBtn then
			closeBtn.Size = layout.isTouchLayout and UDim2.fromOffset(78, 32) or UDim2.fromOffset(88, 34)
			closeBtn.Position = UDim2.new(1, layout.isTouchLayout and -90 or -100, 0, layout.isTouchLayout and 12 or 14)
		end
		local nameLabel = header:FindFirstChild("GuestName")
		if nameLabel and nameLabel:IsA("TextLabel") then
			nameLabel.Size = UDim2.new(1, -174, 0, layout.isTouchLayout and 24 or 26)
			nameLabel.Position = UDim2.new(0, 66, 0, layout.isTouchLayout and 10 or 12)
			nameLabel.TextSize = layout.isTouchLayout and 18 or 20
		end
		local personLabel = header:FindFirstChild("Personality")
		if personLabel and personLabel:IsA("TextLabel") then
			personLabel.Size = UDim2.new(1, -174, 0, 18)
			personLabel.Position = UDim2.new(0, 66, 0, layout.isTouchLayout and 35 or 40)
			personLabel.TextSize = layout.isTouchLayout and 11 or 12
		end
		local stateLabel = header:FindFirstChild("StateLabel")
		if stateLabel and stateLabel:IsA("TextLabel") then
			stateLabel.Size = layout.isTouchLayout and UDim2.new(0, 148, 0, 22) or UDim2.new(0, 168, 0, 24)
			stateLabel.Position = UDim2.new(1, layout.isTouchLayout and -160 or -182, 1, layout.isTouchLayout and -30 or -34)
			stateLabel.TextSize = layout.isTouchLayout and 10 or 11
		end
	end

	local content = infoPanel:FindFirstChild("Content")
	if content and content:IsA("ScrollingFrame") then
		local topInset = layout.headerHeight + 10
		content.Position = UDim2.new(0, 14, 0, topInset)
		content.Size = UDim2.new(1, -28, 1, -(topInset + 14))
		content.ScrollBarThickness = layout.isTouchLayout and 5 or 4
		local list = content:FindFirstChildOfClass("UIListLayout")
		if list then
			list.Padding = UDim.new(0, layout.isTouchLayout and 8 or 10)
		end
	end
end

local function bindInfoPanelViewport()
	if infoViewportConnection then
		infoViewportConnection:Disconnect()
		infoViewportConnection = nil
	end
	local currentCamera = Workspace.CurrentCamera
	if currentCamera then
		infoViewportConnection = currentCamera:GetPropertyChangedSignal("ViewportSize"):Connect(applyInfoPanelLayout)
	end
end

local function setGuiZIndexRecursive(root, zIndex)
	if not root then return end
	if root:IsA("GuiObject") then
		root.ZIndex = zIndex
	end
	for _, descendant in ipairs(root:GetDescendants()) do
		if descendant:IsA("GuiObject") then
			descendant.ZIndex = zIndex
		end
	end
end

local function makeSectionLabel(parent, text, order)
	local label = Instance.new("TextLabel")
	label.Name = text:gsub("[^%w]", "") .. "Section"
	label.Size = UDim2.new(1, 0, 0, 18)
	label.BackgroundTransparency = 1
	label.Text = text
	label.TextColor3 = THEME.TextMuted
	label.Font = Enum.Font.GothamBold
	label.TextSize = 11
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.LayoutOrder = order
	label.ZIndex = 12
	label.Parent = parent
	return label
end

local function BuildInfoPanel()
	if InfoGui then InfoGui:Destroy() end

	InfoGui = Instance.new("ScreenGui")
	InfoGui.Name = "GuestInfoPanel"
	InfoGui.ResetOnSpawn = false
	InfoGui.DisplayOrder = 10
	InfoGui.IgnoreGuiInset = true
	InfoGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	InfoGui.Parent = PlayerGui

	infoBackdrop = Instance.new("TextButton")
	infoBackdrop.Name = "Backdrop"
	infoBackdrop.Size = UDim2.new(1, 0, 1, 0)
	infoBackdrop.BackgroundColor3 = Color3.fromRGB(3, 6, 10)
	infoBackdrop.BackgroundTransparency = 1
	infoBackdrop.AutoButtonColor = false
	infoBackdrop.Text = ""
	infoBackdrop.BorderSizePixel = 0
	infoBackdrop.Visible = false
	infoBackdrop.ZIndex = 9
	infoBackdrop.Parent = InfoGui
	bindGuiButton(infoBackdrop, function()
		CloseInfoPanel()
	end)

	infoPanel = Instance.new("Frame", InfoGui)
	infoPanel.Name = "Panel"
	infoPanel.BackgroundColor3 = THEME.Bg
	infoPanel.BackgroundTransparency = 0.02
	infoPanel.BorderSizePixel = 0
	infoPanel.ClipsDescendants = true
	infoPanel.ZIndex = 10
	Instance.new("UICorner", infoPanel).CornerRadius = UDim.new(0, 18)
	local s = Instance.new("UIStroke", infoPanel); s.Color = THEME.Border; s.Thickness = 2
	local panelGradient = Instance.new("UIGradient", infoPanel)
	panelGradient.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(16, 20, 27)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(10, 13, 18)),
	})

	-- HEADER
	local header = Instance.new("Frame", infoPanel)
	header.Name = "Header"
	header.Size = UDim2.new(1, 0, 0, 84)
	header.BackgroundColor3 = THEME.CardAlt
	header.BorderSizePixel = 0
	header.ZIndex = 11
	Instance.new("UICorner", header).CornerRadius = UDim.new(0, 18)
	local headerGradient = Instance.new("UIGradient", header)
	headerGradient.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(23, 28, 38)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(15, 18, 25)),
	})
	local hMask = Instance.new("Frame", header)
	hMask.Size = UDim2.new(1, 0, 0.5, 0); hMask.Position = UDim2.new(0, 0, 0.5, 0)
	hMask.BackgroundColor3 = THEME.CardAlt; hMask.BorderSizePixel = 0
	hMask.ZIndex = 11

	-- Mood icon
	local moodBg = Instance.new("Frame", header)
	moodBg.Name = "MoodBg"
	moodBg.Size = UDim2.new(0, 46, 0, 46)
	moodBg.Position = UDim2.new(0, 12, 0.5, 0)
	moodBg.AnchorPoint = Vector2.new(0, 0.5)
	moodBg.BackgroundColor3 = Color3.fromRGB(30, 37, 49)
	moodBg.ZIndex = 12
	local moodStroke = Instance.new("UIStroke", moodBg)
	moodStroke.Color = Color3.fromRGB(56, 71, 95)
	moodStroke.Thickness = 1.5
	Instance.new("UICorner", moodBg).CornerRadius = UDim.new(0.5, 0)

	local moodIcon = Instance.new("TextLabel", moodBg)
	moodIcon.Name = "MoodIcon"
	moodIcon.Size = UDim2.new(1, 0, 1, 0)
	moodIcon.BackgroundTransparency = 1
	moodIcon.Text = "😊"
	moodIcon.TextSize = 24
	moodIcon.ZIndex = 13

	-- Name
	local nameLabel = Instance.new("TextLabel", header)
	nameLabel.Name = "GuestName"
	nameLabel.Size = UDim2.new(1, -180, 0, 26)
	nameLabel.Position = UDim2.new(0, 68, 0, 12)
	nameLabel.BackgroundTransparency = 1
	nameLabel.Text = "Guest"
	nameLabel.TextColor3 = THEME.TextPrimary
	nameLabel.Font = Enum.Font.GothamBlack
	nameLabel.TextSize = 20
	nameLabel.ZIndex = 12
	nameLabel.TextXAlignment = Enum.TextXAlignment.Left

	-- Personality badge
	local personLabel = Instance.new("TextLabel", header)
	personLabel.Name = "Personality"
	personLabel.Size = UDim2.new(1, -180, 0, 18)
	personLabel.Position = UDim2.new(0, 68, 0, 40)
	personLabel.BackgroundTransparency = 1
	personLabel.Text = "⛷️ Intermediate"
	personLabel.TextColor3 = THEME.TextSecondary
	personLabel.Font = Enum.Font.GothamMedium
	personLabel.TextSize = 12
	personLabel.ZIndex = 12
	personLabel.TextXAlignment = Enum.TextXAlignment.Left

	-- State label
	local stateLabel = Instance.new("TextLabel", header)
	stateLabel.Name = "StateLabel"
	stateLabel.Size = UDim2.new(0, 168, 0, 24)
	stateLabel.Position = UDim2.new(1, -180, 0, 56)
	stateLabel.BackgroundColor3 = Color3.fromRGB(23, 33, 48)
	stateLabel.BackgroundTransparency = 0
	stateLabel.Text = "Idle"
	stateLabel.TextColor3 = THEME.AccentSoft
	stateLabel.Font = Enum.Font.GothamBold
	stateLabel.TextSize = 11
	stateLabel.TextXAlignment = Enum.TextXAlignment.Center
	Instance.new("UICorner", stateLabel).CornerRadius = UDim.new(0, 10)
	local stateStroke = Instance.new("UIStroke", stateLabel)
	stateStroke.Color = Color3.fromRGB(51, 75, 112)
	stateStroke.Thickness = 1
	stateLabel.ZIndex = 12

	-- Close button
	local closeBtn = Instance.new("TextButton", header)
	closeBtn.Name = "CloseButton"
	closeBtn.Size = UDim2.fromOffset(92, 36)
	closeBtn.Position = UDim2.new(1, -104, 0, 14)
	closeBtn.BackgroundColor3 = THEME.Red
	closeBtn.Text = "EXIT"
	closeBtn.TextColor3 = Color3.new(1, 1, 1)
	closeBtn.Font = Enum.Font.GothamBlack
	closeBtn.TextSize = 12
	closeBtn.ZIndex = 12
	Instance.new("UICorner", closeBtn).CornerRadius = UDim.new(0, 10)
	local closeStroke = Instance.new("UIStroke", closeBtn)
	closeStroke.Color = Color3.fromRGB(104, 20, 32)
	closeStroke.Thickness = 1.2
	bindGuiButton(closeBtn, function() CloseInfoPanel() end)

	-- CONTENT area (scrollable)
	local content = Instance.new("ScrollingFrame", infoPanel)
	content.Name = "Content"
	content.Size = UDim2.new(1, -28, 1, -106)
	content.Position = UDim2.new(0, 14, 0, 94)
	content.BackgroundTransparency = 1
	content.BorderSizePixel = 0
	content.ScrollBarThickness = 4
	content.ScrollBarImageColor3 = THEME.Accent
	content.AutomaticCanvasSize = Enum.AutomaticSize.Y
	content.CanvasSize = UDim2.new(0, 0, 0, 0)
	content.ZIndex = 12

	local layout = Instance.new("UIListLayout", content)
	layout.Padding = UDim.new(0, 10)
	local contentPadding = Instance.new("UIPadding", content)
	contentPadding.PaddingBottom = UDim.new(0, 8)
	contentPadding.PaddingLeft = UDim.new(0, 2)
	contentPadding.PaddingRight = UDim.new(0, 2)

	bindInfoPanelViewport()
	infoPanel.Visible = false
	applyInfoPanelLayout()
	return infoPanel
end

local function MakeBarRow(parent, label, order)
	local row = Instance.new("Frame", parent)
	row.Name = label .. "Bar"
	row.Size = UDim2.new(1, 0, 0, 40)
	row.BackgroundColor3 = THEME.Card
	row.BorderSizePixel = 0
	Instance.new("UICorner", row).CornerRadius = UDim.new(0, 12)
	local rowStroke = Instance.new("UIStroke", row)
	rowStroke.Color = THEME.Border
	rowStroke.Thickness = 1
	row.LayoutOrder = order

	local lbl = Instance.new("TextLabel", row)
	lbl.Size = UDim2.new(0, 92, 1, 0)
	lbl.Position = UDim2.fromOffset(12, 0)
	lbl.BackgroundTransparency = 1
	lbl.Text = label
	lbl.TextColor3 = THEME.TextSecondary
	lbl.Font = Enum.Font.GothamMedium
	lbl.TextSize = 12
	lbl.TextXAlignment = Enum.TextXAlignment.Left

	local barBg = Instance.new("Frame", row)
	barBg.Name = "BarBg"
	barBg.Size = UDim2.new(1, -150, 0, 12)
	barBg.Position = UDim2.new(0, 104, 0.5, 0)
	barBg.AnchorPoint = Vector2.new(0, 0.5)
	barBg.BackgroundColor3 = Color3.fromRGB(40, 40, 50)
	Instance.new("UICorner", barBg).CornerRadius = UDim.new(0, 4)

	local fill = Instance.new("Frame", barBg)
	fill.Name = "Fill"
	fill.Size = UDim2.new(0.5, 0, 1, 0)
	fill.BackgroundColor3 = THEME.Green
	Instance.new("UICorner", fill).CornerRadius = UDim.new(0, 4)

	local val = Instance.new("TextLabel", row)
	val.Name = "Value"
	val.Size = UDim2.new(0, 48, 1, 0)
	val.Position = UDim2.new(1, -60, 0, 0)
	val.BackgroundTransparency = 1
	val.Text = "50%"
	val.TextColor3 = THEME.TextPrimary
	val.Font = Enum.Font.GothamBold
	val.TextSize = 12
	val.TextXAlignment = Enum.TextXAlignment.Right

	return row
end

local function UpdateBar(panel, barName, value, color)
	local bar = panel:FindFirstChild("Content") and panel.Content:FindFirstChild(barName .. "Bar")
	if not bar then return end
	local fill = bar:FindFirstChild("BarBg") and bar.BarBg:FindFirstChild("Fill")
	local val = bar:FindFirstChild("Value")
	if fill then
		TweenService:Create(fill, TweenInfo.new(0.3), {Size = UDim2.new(math.clamp(value / 100, 0, 1), 0, 1, 0)}):Play()
		if color then fill.BackgroundColor3 = color end
	end
	if val then val.Text = math.floor(value) .. "%" end
end

local function RefreshInfoPanel()
	if not isInfoOpen or not currentTarget or not currentTarget.Parent then
		if isInfoOpen then CloseInfoPanel() end
		return
	end

	local panel = infoPanel
	if not panel then return end

	local attr = currentTarget:GetAttributes()
	local sat = attr.Satisfaction or 50
	local hunger = attr.Hunger or 100
	local energy = attr.Energy or 100
	local skill = math.clamp(attr.SkillLevel or 1, 1, 4)

	-- Mood
	local moodColor, moodEmoji
	if sat >= 80 then moodColor = Color3.fromRGB(80, 220, 80); moodEmoji = "🤩"
	elseif sat >= 50 then moodColor = Color3.fromRGB(255, 220, 50); moodEmoji = "😊"
	elseif sat >= 30 then moodColor = Color3.fromRGB(255, 150, 50); moodEmoji = "😐"
	else moodColor = Color3.fromRGB(255, 60, 60); moodEmoji = "😡" end

	-- Header
	local header = panel:FindFirstChild("Header")
	if header then
		local n = header:FindFirstChild("GuestName")
		if n then n.Text = attr.RealName or "Guest" end
		local p = header:FindFirstChild("Personality")
		if p then p.Text = "⛷️ " .. (attr.Personality or "Skier") end
		local st = header:FindFirstChild("StateLabel")
		if st then st.Text = "🎿 " .. (attr.State or "Idle") end
		local mBg = header:FindFirstChild("MoodBg")
		if mBg then mBg.BackgroundColor3 = Color3.new(moodColor.R * 0.3, moodColor.G * 0.3, moodColor.B * 0.3) end
		local mI = mBg and mBg:FindFirstChild("MoodIcon")
		if mI then mI.Text = moodEmoji end
	end

	-- Bars
	local satColor = sat >= 70 and THEME.Green or sat >= 40 and THEME.Yellow or THEME.Red
	UpdateBar(panel, "Satisfaction", sat, satColor)
	UpdateBar(panel, "Hunger", hunger, hunger > 40 and THEME.Green or hunger > 20 and THEME.Yellow or THEME.Red)
	UpdateBar(panel, "Energy", energy, energy > 40 and THEME.Green or energy > 20 and THEME.Yellow or THEME.Red)

	-- Skill
	local content = panel:FindFirstChild("Content")
	if content then
		local skillRow = content:FindFirstChild("SkillRow")
		if skillRow then
			local skillData = SKILL_DATA[skill]
			local lbl = skillRow:FindFirstChild("SkillValue")
			if lbl and skillData then
				lbl.Text = skillData.Icon .. " " .. skillData.Name
				lbl.TextColor3 = skillData.Color
			end
		end

		-- Economy row
		local ecoRow = content:FindFirstChild("EconomyRow")
		if ecoRow then
			local runsLbl = ecoRow:FindFirstChild("Runs")
			if runsLbl then runsLbl.Text = "🎿 " .. (attr.SkiRuns or 0) .. " runs" end
			local budgetLbl = ecoRow:FindFirstChild("Budget")
			if budgetLbl then budgetLbl.Text = "💰 $" .. math.floor(attr.Budget or 0) end
		end

		-- Thought row
		local thoughtRow = content:FindFirstChild("ThoughtRow")
		if thoughtRow then
			local tLbl = thoughtRow:FindFirstChild("ThoughtText")
			if tLbl then
				local speech = attr.Speech or attr.Thought or ""
				if speech == "" then
					-- Use latest from speech log
					local logs = GuestSpeechLogs[currentTarget] or {}
					if #logs > 0 then speech = logs[#logs] end
				end
				if speech == "" then speech = "..." end
				tLbl.Text = '"' .. speech .. '"'
			end
		end

		-- Update chat log
		local chatBox = content:FindFirstChild("ChatLog")
		if chatBox then
			for _, c in ipairs(chatBox:GetChildren()) do
				if c:IsA("TextLabel") then c:Destroy() end
			end
			local logs = GuestSpeechLogs[currentTarget] or {}
			if #logs == 0 then
				local emptyMsg = Instance.new("TextLabel", chatBox)
				emptyMsg.ZIndex = 12
				emptyMsg.Size = UDim2.new(1, -10, 0, 20)
				emptyMsg.BackgroundTransparency = 1
				emptyMsg.Text = "No messages yet..."
				emptyMsg.TextColor3 = THEME.TextMuted
				emptyMsg.Font = Enum.Font.Gotham
				emptyMsg.TextSize = 10
				emptyMsg.TextXAlignment = Enum.TextXAlignment.Left
			else
				for i, msg in ipairs(logs) do
					local line = Instance.new("TextLabel", chatBox)
					line.ZIndex = 12
					line.Size = UDim2.new(1, -10, 0, 16)
					line.BackgroundTransparency = 1
					line.Text = "• " .. msg
					line.TextColor3 = THEME.TextSecondary
					line.Font = Enum.Font.Gotham
					line.TextSize = 10
					line.TextXAlignment = Enum.TextXAlignment.Left
					line.TextWrapped = true
					line.AutomaticSize = Enum.AutomaticSize.Y
					line.LayoutOrder = i
				end
			end
		end
	end
end

local function OpenInfoPanel(model)
	currentTarget = model
	isInfoOpen = true

	if not infoPanel then BuildInfoPanel() end

	-- Rebuild dynamic content
	local content = infoPanel:FindFirstChild("Content")
	if ClosePanels then
		ClosePanels:Fire("GuestInfo")
	end

	if content then
		for _, c in ipairs(content:GetChildren()) do
			if not c:IsA("UIListLayout") and not c:IsA("UIPadding") then
				c:Destroy()
			end
		end
	end

	makeSectionLabel(content, "RESORT GUEST", 1)

	-- Build bars
	local satisfactionRow = MakeBarRow(content, "Satisfaction", 2)
	local hungerRow = MakeBarRow(content, "Hunger", 3)
	local energyRow = MakeBarRow(content, "Energy", 4)
	setGuiZIndexRecursive(satisfactionRow, 12)
	setGuiZIndexRecursive(hungerRow, 12)
	setGuiZIndexRecursive(energyRow, 12)

	-- Skill row
	local skillRow = Instance.new("Frame", content)
	skillRow.Name = "SkillRow"
	skillRow.Size = UDim2.new(1, 0, 0, 42)
	skillRow.BackgroundColor3 = THEME.Card
	skillRow.BorderSizePixel = 0
	Instance.new("UICorner", skillRow).CornerRadius = UDim.new(0, 12)
	local skillStroke = Instance.new("UIStroke", skillRow)
	skillStroke.Color = THEME.Border
	skillStroke.Thickness = 1
	skillRow.LayoutOrder = 5

	setGuiZIndexRecursive(skillRow, 12)

	local skillLbl = Instance.new("TextLabel", skillRow)
	skillLbl.Size = UDim2.new(0, 90, 1, 0)
	skillLbl.Position = UDim2.fromOffset(12, 0)
	skillLbl.BackgroundTransparency = 1
	skillLbl.Text = "Skill"
	skillLbl.TextColor3 = THEME.TextSecondary
	skillLbl.Font = Enum.Font.GothamMedium
	skillLbl.TextSize = 12
	skillLbl.TextXAlignment = Enum.TextXAlignment.Left

	local skillVal = Instance.new("TextLabel", skillRow)
	skillVal.Name = "SkillValue"
	skillVal.Size = UDim2.new(1, -120, 1, 0)
	skillVal.Position = UDim2.new(0, 102, 0, 0)
	skillVal.BackgroundTransparency = 1
	skillVal.Text = "🟢 Green Circle"
	skillVal.TextColor3 = THEME.Green
	skillVal.Font = Enum.Font.GothamBold
	skillVal.TextSize = 13
	skillVal.TextXAlignment = Enum.TextXAlignment.Left

	-- Divider
	local div = Instance.new("Frame", content)
	div.Size = UDim2.new(1, 0, 0, 1)
	div.BackgroundColor3 = THEME.Border
	div.BorderSizePixel = 0
	div.LayoutOrder = 6
	div.ZIndex = 12

	-- Economy row
	local ecoRow = Instance.new("Frame", content)
	ecoRow.Name = "EconomyRow"
	ecoRow.Size = UDim2.new(1, 0, 0, 42)
	ecoRow.BackgroundColor3 = THEME.Card
	ecoRow.BorderSizePixel = 0
	Instance.new("UICorner", ecoRow).CornerRadius = UDim.new(0, 12)
	local ecoStroke = Instance.new("UIStroke", ecoRow)
	ecoStroke.Color = THEME.Border
	ecoStroke.Thickness = 1
	ecoRow.LayoutOrder = 7

	setGuiZIndexRecursive(ecoRow, 12)

	local runsLbl = Instance.new("TextLabel", ecoRow)
	runsLbl.Name = "Runs"
	runsLbl.Size = UDim2.new(0.5, -6, 1, 0)
	runsLbl.Position = UDim2.fromOffset(12, 0)
	runsLbl.BackgroundTransparency = 1
	runsLbl.Text = "🎿 0 runs"
	runsLbl.TextColor3 = THEME.TextPrimary
	runsLbl.Font = Enum.Font.GothamMedium
	runsLbl.TextSize = 13
	runsLbl.TextXAlignment = Enum.TextXAlignment.Left

	local budgetLbl = Instance.new("TextLabel", ecoRow)
	budgetLbl.Name = "Budget"
	budgetLbl.Size = UDim2.new(0.5, -18, 1, 0)
	budgetLbl.Position = UDim2.new(0.5, 6, 0, 0)
	budgetLbl.BackgroundTransparency = 1
	budgetLbl.Text = "💰 $0"
	budgetLbl.TextColor3 = THEME.Yellow
	budgetLbl.Font = Enum.Font.GothamBold
	budgetLbl.TextSize = 13
	budgetLbl.TextXAlignment = Enum.TextXAlignment.Right

	-- Thought row (shows latest thought)
	local thoughtRow = Instance.new("Frame", content)
	thoughtRow.Name = "ThoughtRow"
	thoughtRow.Size = UDim2.new(1, 0, 0, 40)
	thoughtRow.BackgroundColor3 = THEME.CardAlt
	local thoughtStroke = Instance.new("UIStroke", thoughtRow)
	thoughtStroke.Color = THEME.Border
	thoughtStroke.Thickness = 1
	thoughtRow.LayoutOrder = 8
	Instance.new("UICorner", thoughtRow).CornerRadius = UDim.new(0, 8)

	setGuiZIndexRecursive(thoughtRow, 12)

	local thoughtIcon = Instance.new("TextLabel", thoughtRow)
	thoughtIcon.Size = UDim2.new(0, 25, 1, 0)
	thoughtIcon.Position = UDim2.new(0, 6, 0, 0)
	thoughtIcon.BackgroundTransparency = 1
	thoughtIcon.Text = "💭"
	thoughtIcon.TextSize = 16

	local thoughtText = Instance.new("TextLabel", thoughtRow)
	thoughtText.Name = "ThoughtText"
	thoughtText.Size = UDim2.new(1, -38, 1, -6)
	thoughtText.Position = UDim2.new(0, 32, 0, 3)
	thoughtText.BackgroundTransparency = 1
	thoughtText.Text = '"..."'
	thoughtText.TextColor3 = THEME.TextSecondary
	thoughtText.Font = Enum.Font.GothamMedium
	thoughtText.TextSize = 11
	thoughtText.TextWrapped = true
	thoughtText.TextXAlignment = Enum.TextXAlignment.Left

	-- Speech log (scrollable chat history)
	local chatLabel = Instance.new("TextLabel", content)
	chatLabel.Size = UDim2.new(1, 0, 0, 18)
	chatLabel.BackgroundTransparency = 1
	chatLabel.Text = "CONVERSATION"
	chatLabel.TextColor3 = THEME.TextMuted
	chatLabel.Font = Enum.Font.GothamBold
	chatLabel.TextSize = 12
	chatLabel.TextXAlignment = Enum.TextXAlignment.Left
	chatLabel.LayoutOrder = 9
	chatLabel.ZIndex = 12

	local chatBox = Instance.new("ScrollingFrame", content)
	chatBox.Name = "ChatLog"
	chatBox.Size = UDim2.new(1, 0, 0, 90)
	chatBox.BackgroundColor3 = THEME.CardAlt
	chatBox.BorderSizePixel = 0
	chatBox.ScrollBarThickness = 3
	chatBox.ScrollBarImageColor3 = THEME.Accent
	chatBox.AutomaticCanvasSize = Enum.AutomaticSize.Y
	chatBox.CanvasSize = UDim2.new(0, 0, 0, 0)
	chatBox.LayoutOrder = 10
	Instance.new("UICorner", chatBox).CornerRadius = UDim.new(0, 8)
	Instance.new("UIPadding", chatBox).PaddingLeft = UDim.new(0, 6)
	chatBox.ZIndex = 12

	local chatLayout = Instance.new("UIListLayout", chatBox)
	chatLayout.Padding = UDim.new(0, 2)
	chatLayout.SortOrder = Enum.SortOrder.LayoutOrder

	-- Populate chat log from speech history
	local logs = GuestSpeechLogs[model] or {}
	if #logs == 0 then
		local emptyMsg = Instance.new("TextLabel", chatBox)
		emptyMsg.ZIndex = 12
		emptyMsg.Size = UDim2.new(1, -10, 0, 20)
		emptyMsg.BackgroundTransparency = 1
		emptyMsg.Text = "No messages yet..."
		emptyMsg.TextColor3 = THEME.TextMuted
		emptyMsg.Font = Enum.Font.Gotham
		emptyMsg.TextSize = 10
		emptyMsg.TextXAlignment = Enum.TextXAlignment.Left
	else
		for i, msg in ipairs(logs) do
			local line = Instance.new("TextLabel", chatBox)
			line.ZIndex = 12
			line.Size = UDim2.new(1, -10, 0, 16)
			line.BackgroundTransparency = 1
			line.Text = "• " .. msg
			line.TextColor3 = THEME.TextSecondary
			line.Font = Enum.Font.Gotham
			line.TextSize = 10
			line.TextXAlignment = Enum.TextXAlignment.Left
			line.TextWrapped = true
			line.AutomaticSize = Enum.AutomaticSize.Y
			line.LayoutOrder = i
		end
	end

	-- Divider 2
	local div2 = Instance.new("Frame", content)
	div2.Size = UDim2.new(1, 0, 0, 1)
	div2.BackgroundColor3 = THEME.Border
	div2.BorderSizePixel = 0
	div2.LayoutOrder = 11
	div2.ZIndex = 12

	-- TELEPORT TO GUEST button
	local teleportBtn = Instance.new("TextButton", content)
	teleportBtn.Name = "TeleportBtn"
	teleportBtn.Size = UDim2.new(1, 0, 0, 42)
	teleportBtn.BackgroundColor3 = THEME.Accent
	teleportBtn.BackgroundTransparency = 0
	teleportBtn.Text = "TELEPORT TO GUEST"
	teleportBtn.TextColor3 = Color3.new(1, 1, 1)
	teleportBtn.Font = Enum.Font.GothamBold
	teleportBtn.TextSize = 12
	teleportBtn.LayoutOrder = 12
	Instance.new("UICorner", teleportBtn).CornerRadius = UDim.new(0, 12)
	setGuiZIndexRecursive(teleportBtn, 12)
	local teleportStroke = Instance.new("UIStroke", teleportBtn)
	teleportStroke.Color = Color3.fromRGB(12, 59, 118)
	teleportStroke.Thickness = 1.2

	bindGuiButton(teleportBtn, function()
		if currentTarget and currentTarget.Parent then
			local root = currentTarget:FindFirstChild("HumanoidRootPart")
			if root then
				local char = Player.Character
				local charRoot = char and char:FindFirstChild("HumanoidRootPart")
				if charRoot then
					charRoot.CFrame = root.CFrame * CFrame.new(5, 3, 5)
				end
			end
		end
	end)

	-- Dismiss button
	local dismissBtn = Instance.new("TextButton", content)
	dismissBtn.Name = "DismissBtn"
	dismissBtn.Size = UDim2.new(1, 0, 0, 42)
	dismissBtn.BackgroundColor3 = Color3.fromRGB(39, 18, 24)
	dismissBtn.BackgroundTransparency = 0
	dismissBtn.Text = "DISMISS GUEST"
	dismissBtn.TextColor3 = Color3.fromRGB(255, 205, 210)
	dismissBtn.Font = Enum.Font.GothamBold
	dismissBtn.TextSize = 12
	dismissBtn.LayoutOrder = 13
	Instance.new("UICorner", dismissBtn).CornerRadius = UDim.new(0, 12)
	setGuiZIndexRecursive(dismissBtn, 12)
	local dStroke = Instance.new("UIStroke", dismissBtn); dStroke.Color = THEME.Red; dStroke.Thickness = 1

	bindGuiButton(dismissBtn, function()
		if currentTarget and GuestUpdateEvent then
			GuestUpdateEvent:FireServer("Dismiss", currentTarget)
			CloseInfoPanel()
		end
	end)

	-- Show panel
	local panelLayout = getInfoPanelLayout()
	if infoBackdrop then
		infoBackdrop.Visible = true
		infoBackdrop.BackgroundTransparency = 1
	end
	infoPanel.Visible = true
	infoPanel.Position = panelLayout.closedPosition
	TweenService:Create(infoPanel, TweenInfo.new(0.3, Enum.EasingStyle.Quart, Enum.EasingDirection.Out), {
		Position = panelLayout.openPosition
	}):Play()

	RefreshInfoPanel()
end

function CloseInfoPanel()
	isInfoOpen = false
	currentTarget = nil
	if infoBackdrop then
		infoBackdrop.BackgroundTransparency = 1
	end
	if infoPanel then
		local panelLayout = getInfoPanelLayout()
		TweenService:Create(infoPanel, TweenInfo.new(0.22, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
			Position = panelLayout.closedPosition
		}):Play()
		task.delay(0.24, function()
			if infoBackdrop and not isInfoOpen then
				infoBackdrop.Visible = false
			end
			if infoPanel and not isInfoOpen then
				infoPanel.Visible = false
			end
		end)
	end
end

if ClosePanels then
	ClosePanels.Event:Connect(function(source)
		if source ~= "GuestInfo" and isInfoOpen then
			CloseInfoPanel()
		end
	end)
end

-- ============================================================================
-- CLICK-TO-SELECT GUEST
-- ============================================================================
UserInputService.InputBegan:Connect(function(input, processed)
	if processed then return end
	if input.UserInputType ~= Enum.UserInputType.MouseButton1 and input.UserInputType ~= Enum.UserInputType.Touch then return end

	local camera = Workspace.CurrentCamera
	if not camera then return end

	local ray = camera:ScreenPointToRay(input.Position.X, input.Position.Y)

	local gFolder = Workspace:FindFirstChild("Guests")
	if not gFolder then return end

	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = {gFolder}

	local result = Workspace:Raycast(ray.Origin, ray.Direction * 500, params)
	if result and result.Instance then
		-- Walk up to find guest model
		local current = result.Instance
		while current and current.Parent ~= gFolder do
			current = current.Parent
		end

		if current and current:IsA("Model") and current:GetAttribute("OwnerId") then
			OpenInfoPanel(current)
		end
	end
end)

-- ============================================================================
-- CLIENT-SIDE SKI INTERPOLATION (fixes 20Hz anchored part replication jitter)
-- ============================================================================
-- Server anchors skiing guests and sets CFrame at 60Hz on Heartbeat.
-- But Roblox only replicates anchored CFrames to clients at ~20Hz.
-- We detect each new server position, then predict FORWARD between updates
-- using the velocity attributes the server provides.
-- ============================================================================
local TERRAIN_RAY_PARAMS_CLIENT = RaycastParams.new()
TERRAIN_RAY_PARAMS_CLIENT.FilterType = Enum.RaycastFilterType.Include
TERRAIN_RAY_PARAMS_CLIENT.FilterDescendantsInstances = {Workspace.Terrain}

local SkiSmoothData = {} -- { [model] = { serverCF, renderCF, lastServerChangeTime } }
local SMALL_ERROR_BAND = 2.4
local MEDIUM_ERROR_BAND = 10
local LARGE_ERROR_BAND = 24

local function GetSkiPositionCorrectionAlpha(errorMagnitude)
	if errorMagnitude <= SMALL_ERROR_BAND then
		return 0.01
	end
	if errorMagnitude <= MEDIUM_ERROR_BAND then
		return 0.03
	end
	if errorMagnitude <= LARGE_ERROR_BAND then
		return 0.075
	end
	return math.clamp(0.12 + ((errorMagnitude - LARGE_ERROR_BAND) / 110), 0.12, 0.22)
end

local PARK_FEATURE_NAMES = {
	["Short Rail"] = true,
	["Simple Box"] = true,
	["Box /w Hump"] = true,
	["Long Rail"] = true,
}

local PARK_FEATURE_RADIUS_BY_NAME = {
	["Short Rail"] = 17,
	["Simple Box"] = 15,
	["Box /w Hump"] = 18,
	["Long Rail"] = 22,
}

local PARK_FEATURE_BASE_CHANCE_BY_SKILL = {
	[2] = 0.22,
	[3] = 0.35,
	[4] = 0.48,
}

local PARK_FEATURE_TRICK_POOL_BY_SKILL = {
	[2] = {"Safety Grab!", "Shifty!", "Method Grab!"},
	[3] = {"360 Spin!", "Backflip!", "Iron Cross!"},
	[4] = {"Cork 720!", "Misty Flip!", "Backflip!"},
}

local PARK_FEATURE_CACHE_TTL = 1.2
local PARK_FEATURE_RETRY_DEBOUNCE = 2.4
local PARK_FEATURE_COOLDOWN_MIN = 4.5
local PARK_FEATURE_COOLDOWN_MAX = 8.5

local ParkFeatureCache = {
	entries = {},
	at = 0,
}

local function GetParkFeatureJumpRange(featureName)
	if featureName == "Simple Box" then
		return 3.4, 5.1
	end
	if featureName == "Box /w Hump" then
		return 4.4, 6.6
	end
	if featureName == "Long Rail" then
		return 3.2, 5.4
	end
	return 2.8, 4.2
end

local function GetNearbyParkFeatures()
	local now = tick()
	if (now - (ParkFeatureCache.at or 0)) <= PARK_FEATURE_CACHE_TTL then
		return ParkFeatureCache.entries
	end

	local entries = {}
	local placed = Workspace:FindFirstChild("PlacedObjects")
	if placed then
		for _, obj in ipairs(placed:GetChildren()) do
			if obj:IsA("Model") and PARK_FEATURE_NAMES[obj.Name] then
				local ownerId = tonumber(obj:GetAttribute("Owner")) or tonumber(obj:GetAttribute("OwnerId")) or 0
				if ownerId == 0 or ownerId == Player.UserId then
					local cf, size = obj:GetBoundingBox()
					local configuredRadius = PARK_FEATURE_RADIUS_BY_NAME[obj.Name] or 16
					local dynamicRadius = math.max(configuredRadius, math.max(size.X, size.Z) * 0.32)
					table.insert(entries, {
						model = obj,
						name = obj.Name,
						center = cf.Position,
						radius = dynamicRadius,
					})
				end
			end
		end
	end

	ParkFeatureCache.entries = entries
	ParkFeatureCache.at = now
	return entries
end

local function MaybeStartLocalParkTrick(model, data, rootPos, heading, speed, now)
	if not model or not data then
		return nil
	end

	local skillLevel = tonumber(model:GetAttribute("SkillLevel")) or 0
	if skillLevel < 2 then
		return nil
	end
	if speed < 18 then
		return nil
	end
	if data.nextLocalParkTrickAt and now < data.nextLocalParkTrickAt then
		return nil
	end

	local entries = GetNearbyParkFeatures()
	if #entries == 0 then
		return nil
	end

	local bestEntry = nil
	local bestDist = math.huge
	for _, entry in ipairs(entries) do
		if entry.model and entry.model.Parent then
			local flatDelta = Vector3.new(entry.center.X - rootPos.X, 0, entry.center.Z - rootPos.Z)
			local dist = flatDelta.Magnitude
			if dist <= entry.radius and dist < bestDist then
				if dist <= 0.05 then
					bestEntry = entry
					bestDist = dist
				else
					local toward = flatDelta.Unit
					if heading:Dot(toward) >= 0.12 then
						local seenAt = data.localParkFeatureSeen and data.localParkFeatureSeen[entry.model]
						if not seenAt or (now - seenAt) >= PARK_FEATURE_RETRY_DEBOUNCE then
							bestEntry = entry
							bestDist = dist
						end
					end
				end
			end
		end
	end

	if not bestEntry then
		return nil
	end

	data.localParkFeatureSeen = data.localParkFeatureSeen or setmetatable({}, { __mode = "k" })
	data.localParkFeatureSeen[bestEntry.model] = now

	local baseChance = PARK_FEATURE_BASE_CHANCE_BY_SKILL[math.floor(skillLevel)] or 0.2
	local speedBonus = math.clamp((speed - 22) / 45, 0, 0.18)
	local triggerChance = math.clamp(baseChance + speedBonus, 0.08, 0.75)
	if math.random() > triggerChance then
		return nil
	end

	local jumpMin, jumpMax = GetParkFeatureJumpRange(bestEntry.name)
	local jumpHeight = jumpMin + (math.random() * (jumpMax - jumpMin))
	local duration = 1.0 + (math.random() * 0.45)
	local trickPool = PARK_FEATURE_TRICK_POOL_BY_SKILL[math.floor(skillLevel)] or PARK_FEATURE_TRICK_POOL_BY_SKILL[2]
	local trickName = trickPool[math.random(1, #trickPool)]
	local trick = {
		featureName = bestEntry.name,
		trickName = trickName,
		startAt = now,
		endAt = now + duration,
		duration = duration,
		jumpHeight = jumpHeight,
	}
	data.localParkTrick = trick
	data.nextLocalParkTrickAt = now + PARK_FEATURE_COOLDOWN_MIN + (math.random() * (PARK_FEATURE_COOLDOWN_MAX - PARK_FEATURE_COOLDOWN_MIN))
	return trick
end

local function UpdateSkiSmoothing(dt, camPos, guestCount)
	local guestPerfLevel = GetGuestPerformanceModeLevel()
	local smoothingDistance = SKI_SMOOTH_DISTANCE
	local minSmoothDistance = 900
	if guestCount and guestCount >= 420 then
		smoothingDistance = 980
		minSmoothDistance = 760
	elseif guestCount and guestCount >= 240 then
		smoothingDistance = 1120
		minSmoothDistance = 840
	elseif guestCount and guestCount >= 120 then
		smoothingDistance = 1280
		minSmoothDistance = 920
	end

	local npcDistanceChoice = GraphicsProfile.GetDistanceChoice(Player, "NPCRenderDistance")
	if npcDistanceChoice == "Far" then
		smoothingDistance += 220
	elseif npcDistanceChoice == "Off" then
		if guestPerfLevel <= 0 then
			smoothingDistance = math.max(smoothingDistance, 2400)
			minSmoothDistance = math.max(minSmoothDistance, 1300)
		else
			smoothingDistance = math.max(smoothingDistance, GUEST_PERF_OFF_RENDER_DISTANCE[guestPerfLevel + 1] or 520)
			minSmoothDistance = math.min(minSmoothDistance, math.floor(smoothingDistance * 0.78))
		end
	end

	local runtimeTier = GetRuntimePerfTier()
	local runtimeMult = RUNTIME_VISUAL_DISTANCE_MULT[runtimeTier + 1] or 1
	if runtimeTier >= 2 then
		runtimeMult = math.max(runtimeMult, 0.72)
	elseif runtimeTier == 1 then
		runtimeMult = math.max(runtimeMult, 0.82)
	end
	local guestPerfMult = GUEST_PERF_VISUAL_DISTANCE_MULT[guestPerfLevel + 1] or 1
	smoothingDistance = math.max(minSmoothDistance, smoothingDistance * runtimeMult * guestPerfMult)
	if guestPerfLevel >= 2 then
		smoothingDistance = math.min(smoothingDistance, guestPerfLevel >= 3 and 360 or 520)
	end
	for model in pairs(SkiSmoothCandidates) do
		if not model or not model:IsA("Model") then
			SkiSmoothCandidates[model] = nil
			SkiSmoothData[model] = nil
			continue
		end

		local isSkiing = IsGuestMarkedSkiing(model)
		if not isSkiing or model:GetAttribute("RidingLift") then
			SkiSmoothCandidates[model] = nil
			SkiSmoothData[model] = nil
			continue
		end

		local root = model:FindFirstChild("HumanoidRootPart")
		if not root then continue end
		-- Deep jitter fix: only run client ski CFrame interpolation when server uses
		-- anchored replication for ski guests. If the guest is physics-driven, this
		-- client write fights server/physics and causes telekinesis-like rubber-banding.
		if not root.Anchored then
			SkiSmoothData[model] = nil
			continue
		end
		if camPos and (root.Position - camPos).Magnitude > smoothingDistance then
			SkiSmoothCandidates[model] = nil
			SkiSmoothData[model] = nil
			continue
		end


		local velX = model:GetAttribute("SkiVelX") or 0
		local velZ = model:GetAttribute("SkiVelZ") or 0
		local speed = model:GetAttribute("SkiSpeed") or 0

		if speed < 2 then continue end

		local data = SkiSmoothData[model]
		local serverCF = root.CFrame -- latest replicated server position

		if not data then
			local initialHeading = Vector3.new(serverCF.LookVector.X, 0, serverCF.LookVector.Z)
			if initialHeading.Magnitude < 0.01 then
				initialHeading = Vector3.new(0, 0, 1)
			else
				initialHeading = initialHeading.Unit
			end
			data = {
				serverCF = serverCF,
				renderCF = serverCF,
				lastServerPos = serverCF.Position,
				smoothedPos = serverCF.Position,
				heading = initialHeading,
				timeSinceServer = 0,
				terrainY = serverCF.Position.Y,
				nextTerrainSampleAt = 0,
			}
			SkiSmoothData[model] = data
		end

		local posDelta = (serverCF.Position - data.lastServerPos).Magnitude
		if posDelta > 0.1 then
			data.serverCF = serverCF
			data.lastServerPos = serverCF.Position
			data.timeSinceServer = 0
			if data.smoothedPos then
				local catchupAlpha = (posDelta > 12) and 1 or math.clamp(0.22 + (posDelta / 40), 0.22, 0.55)
				data.smoothedPos = data.smoothedPos:Lerp(serverCF.Position, catchupAlpha)
			else
				data.smoothedPos = serverCF.Position
			end
		else
			data.timeSinceServer = (data.timeSinceServer or 0) + dt
		end

		local now = tick()
		local velocity = Vector3.new(velX, 0, velZ)
		local headingForFeature = velocity
		if headingForFeature.Magnitude < 0.05 then
			local look = root.CFrame.LookVector
			headingForFeature = Vector3.new(look.X, 0, look.Z)
		end
		if headingForFeature.Magnitude > 0.05 then
			headingForFeature = headingForFeature.Unit
			MaybeStartLocalParkTrick(model, data, root.Position, headingForFeature, speed, now)
		end

		local timeSinceServer = data.timeSinceServer or 0
		if timeSinceServer > 0.12 then
			local staleFade = math.clamp(1 - ((timeSinceServer - 0.12) / 0.24), 0, 1)
			velocity *= staleFade
		end
		local extrapolationTime = math.clamp(timeSinceServer + dt, 0, 0.12)
		local predictedPos = data.serverCF.Position + (velocity * extrapolationTime)
		predictedPos = data.smoothedPos:Lerp(predictedPos, math.clamp(10 * dt, 0, 0.65))

		local sampleNow = now
		if sampleNow >= (data.nextTerrainSampleAt or 0) then
			local rayRes = Workspace:Raycast(
				Vector3.new(predictedPos.X, predictedPos.Y + 50, predictedPos.Z),
				Vector3.new(0, -200, 0),
				TERRAIN_RAY_PARAMS_CLIENT
			)
			local sampledY = rayRes and (rayRes.Position.Y + 3.5) or predictedPos.Y
			data.terrainY = sampledY
			local sampleInterval = 0.16
			if speed >= 100 then
				sampleInterval = 0.08
			elseif speed >= 70 then
				sampleInterval = 0.11
			elseif speed >= 45 then
				sampleInterval = 0.13
			end
			data.nextTerrainSampleAt = sampleNow + sampleInterval
		end

		local terrainY = data.terrainY or predictedPos.Y
		local blendedY = predictedPos.Y + ((terrainY - predictedPos.Y) * math.clamp(7 * dt, 0, 1))

		local serverDoingTrick = model:GetAttribute("DoingTrick") == true
		local localParkTrick = data.localParkTrick
		local localParkTrickActive = localParkTrick and now <= (localParkTrick.endAt or 0)
		if localParkTrick and not localParkTrickActive then
			data.localParkTrick = nil
			localParkTrick = nil
		end

		-- If server says we're doing a trick, trust replicated server Y.
		-- For locally-triggered park features, add a local jump arc so the skier
		-- can visibly clear rails/boxes instead of ground-sticking.
		if serverDoingTrick then
			local serverY = data.serverCF.Position.Y
			blendedY = predictedPos.Y + ((serverY - predictedPos.Y) * math.clamp(12 * dt, 0, 1))
		elseif localParkTrickActive then
			local duration = math.max(0.4, tonumber(localParkTrick.duration) or 1.2)
			local progress = math.clamp((now - (localParkTrick.startAt or now)) / duration, 0, 1)
			blendedY += math.sin(progress * math.pi) * (tonumber(localParkTrick.jumpHeight) or 3.5)
		end

		predictedPos = Vector3.new(predictedPos.X, blendedY, predictedPos.Z)

		local serverPos = data.serverCF.Position
		local correctionVec = serverPos - predictedPos
		local correctionMag = correctionVec.Magnitude
		local correctionAlpha = GetSkiPositionCorrectionAlpha(correctionMag)
		local correctedPos = predictedPos
		if correctionAlpha > 0 then
			correctedPos = predictedPos:Lerp(serverPos, correctionAlpha)
		end

		-- Prevent hard snap-backs for large replication gaps.
		local maxCorrectionStep = math.max(2.25, (speed * dt * 0.95))
		local correctionStep = correctedPos - predictedPos
		if correctionStep.Magnitude > maxCorrectionStep then
			correctionStep = correctionStep.Unit * maxCorrectionStep
			correctedPos = predictedPos + correctionStep
		end

		data.smoothedPos = correctedPos

		local headingTarget
		if velocity.Magnitude > 2 then
			headingTarget = velocity.Unit
		else
			local look = data.serverCF.LookVector
			headingTarget = Vector3.new(look.X, 0, look.Z)
		end
		if headingTarget.Magnitude < 0.01 then
			headingTarget = data.heading or Vector3.new(0, 0, 1)
		end
		headingTarget = headingTarget.Unit

		local currentHeading = data.heading or headingTarget
		data.heading = (currentHeading + (headingTarget - currentHeading) * math.clamp(8 * dt, 0, 0.4)).Unit

		local targetCF = CFrame.lookAt(correctedPos, correctedPos + data.heading)
		if correctionMag > MEDIUM_ERROR_BAND then
			local serverFacingCF = data.serverCF - data.serverCF.Position + correctedPos
			local orientBlend = math.clamp((correctionMag - MEDIUM_ERROR_BAND) / (LARGE_ERROR_BAND * 1.6), 0, 0.15)
			targetCF = targetCF:Lerp(serverFacingCF, orientBlend)
		end

		-- Trick Math Override
		if serverDoingTrick or localParkTrickActive then
			local progress
			local trickName
			if localParkTrickActive and not serverDoingTrick then
				data.trickTime = 0
				local duration = math.max(0.4, tonumber(localParkTrick.duration) or 1.2)
				progress = math.clamp((now - (localParkTrick.startAt or now)) / duration, 0, 1)
				trickName = tostring(localParkTrick.trickName or "")
			else
				data.trickTime = (data.trickTime or 0) + dt
				local duration = 1.5
				progress = math.clamp(data.trickTime / duration, 0, 1)
				trickName = model:GetAttribute("CurrentTrick") or ""
			end

			local easeProgress = -(math.cos(math.pi * progress) - 1) / 2
			local trickAngleX, trickAngleY, trickAngleZ = 0, 0, 0

			if trickName:find("Backflip") then
				trickAngleX = easeProgress * math.rad(360)
			elseif trickName:find("360") then
				trickAngleY = easeProgress * math.rad(360)
			elseif trickName:find("Cork 720") then
				trickAngleX = easeProgress * math.rad(360)
				trickAngleY = easeProgress * math.rad(720)
			elseif trickName:find("Misty") then
				trickAngleX = -easeProgress * math.rad(360)
				trickAngleZ = easeProgress * math.rad(360)
			else
				local tweakProgress = math.sin(progress * math.pi)
				trickAngleY = tweakProgress * math.rad(70)
				trickAngleZ = tweakProgress * math.rad(30)
			end

			local trickSpin = CFrame.Angles(trickAngleX, trickAngleY, trickAngleZ)

			-- Because the client smoother always tries to lerp, we bypass the lerp smoothing
			-- entirely when doing a trick to prevent spongy spin math.
			data.renderCF = targetCF * trickSpin
		else
			data.trickTime = 0
			data.renderCF = data.renderCF:Lerp(targetCF, math.clamp(8 * dt, 0, 0.32))
		end

		-- Keep skiing root motion server-authoritative to prevent client/server CFrame tug-of-war jitter.
		-- We still maintain renderCF for local visual systems that reference smoothed ski state.
	end
end

local function CleanupSkiSmoothing()
	for model in pairs(SkiSmoothData) do
		if not model or not model.Parent then
			SkiSmoothData[model] = nil
		end
	end
end

local WalkerSmoothData = {}
local function UpdateWalkerSmoothing(dt, guestModels, camPos, now, guestCount)
	if not WALKER_SMOOTHING_ENABLED then return end
	local guestPerfLevel = GetGuestPerformanceModeLevel()
	if guestPerfLevel >= 2 then
		for model in pairs(WalkerSmoothData) do
			WalkerSmoothData[model] = nil
		end
		return
	end

	local guestSliceDivisor = 1
	if guestCount >= 420 then
		guestSliceDivisor = 6
	elseif guestCount >= 280 then
		guestSliceDivisor = 5
	elseif guestCount >= 170 then
		guestSliceDivisor = 4
	elseif guestCount >= 90 then
		guestSliceDivisor = 3
	elseif guestCount >= 50 then
		guestSliceDivisor = 2
	end
	if crowdSurvivalActive then
		guestSliceDivisor = math.max(guestSliceDivisor, 7)
	end
	if guestSliceDivisor > 1 then
		walkerSliceCursor = (walkerSliceCursor % guestSliceDivisor) + 1
	else
		walkerSliceCursor = 1
	end

	for index, model in ipairs(guestModels) do
		if guestSliceDivisor > 1 and ((index - walkerSliceCursor) % guestSliceDivisor ~= 0) then
			continue
		end
		if not model:IsA("Model") then continue end
		if IsGuestMarkedSkiing(model) then
			WalkerSmoothData[model] = nil
			continue
		end
		if model:GetAttribute("RidingLift") then
			WalkerSmoothData[model] = nil
			continue
		end

		local root = model:FindFirstChild("HumanoidRootPart")
		if not root then continue end
		if camPos then
			local runtimeTier = GetRuntimePerfTier()
			local walkerDistance = 180 * (RUNTIME_VISUAL_DISTANCE_MULT[runtimeTier + 1] or 1)
			walkerDistance *= (GUEST_PERF_VISUAL_DISTANCE_MULT[guestPerfLevel + 1] or 1)
			local walkerDistanceSq = walkerDistance * walkerDistance
			local toCamera = root.Position - camPos
			if toCamera:Dot(toCamera) > walkerDistanceSq then
				WalkerSmoothData[model] = nil
				continue
			end
		end

		local serverPos = root.Position
		local data = WalkerSmoothData[model]
		if not data then
			local look = root.CFrame.LookVector
			local forward = Vector3.new(look.X, 0, look.Z)
			if forward.Magnitude < 0.01 then forward = Vector3.zAxis else forward = forward.Unit end
			data = {
				lastServerPos = serverPos,
				lastObservedPos = serverPos,
				lastObservedAt = now,
				observedVel = Vector3.zero,
				renderPos = serverPos,
				renderCF = root.CFrame,
				forward = forward,
				timeSinceUpdate = 0,
			}
			WalkerSmoothData[model] = data
		end

		local movedVec = serverPos - data.lastServerPos
		local moved = movedVec.Magnitude
		if moved > 18 then
			data.lastServerPos = serverPos
			data.lastObservedPos = serverPos
			data.lastObservedAt = now
			data.observedVel = Vector3.zero
			data.renderPos = serverPos
			data.renderCF = root.CFrame
			data.timeSinceUpdate = 0
			continue
		end

		if moved > 0.03 then
			local observedDt = math.max(1 / 240, now - (data.lastObservedAt or now))
			local observedStep = serverPos - (data.lastObservedPos or serverPos)
			local observedPlanar = Vector3.new(observedStep.X, 0, observedStep.Z)
			local observedVel = observedPlanar / observedDt
			local prevObservedVel = data.observedVel or Vector3.zero
			data.observedVel = prevObservedVel:Lerp(observedVel, math.clamp(observedDt * 10, 0.2, 0.6))
			data.lastObservedPos = serverPos
			data.lastObservedAt = now
			data.lastServerPos = serverPos
			data.timeSinceUpdate = 0
		else
			data.timeSinceUpdate = (data.timeSinceUpdate or 0) + dt
			if data.observedVel and data.observedVel.Magnitude > 0 then
				data.observedVel *= math.clamp(1 - (dt * 2.5), 0, 1)
			end
		end

		local assemblyVel = Vector3.new(root.AssemblyLinearVelocity.X, 0, root.AssemblyLinearVelocity.Z)
		local observedVel = data.observedVel or Vector3.zero
		local planarVel = assemblyVel
		if observedVel.Magnitude > 0.15 then
			if planarVel.Magnitude < 0.35 then
				planarVel = observedVel
			else
				planarVel = planarVel:Lerp(observedVel, 0.35)
			end
		end
		if data.timeSinceUpdate > 0.28 and planarVel.Magnitude < 0.7 then
			planarVel = Vector3.zero
		end

		local predictedPos = data.renderPos + (planarVel * dt)
		if data.timeSinceUpdate > 0.04 and planarVel.Magnitude > 0.1 then
			local lead = math.clamp(data.timeSinceUpdate * 0.4, 0, 0.12)
			predictedPos += planarVel * lead
		end

		local errorVec = serverPos - predictedPos
		local errorMag = errorVec.Magnitude
		local correctedPos = predictedPos
		if errorMag > 12 then
			correctedPos = serverPos
		else
			local correctionAlpha
			if errorMag < 1.5 then
				correctionAlpha = 0.05
			elseif errorMag < 4 then
				correctionAlpha = 0.16
			elseif errorMag < 8 then
				correctionAlpha = 0.28
			else
				correctionAlpha = 0.42
			end
			correctedPos = predictedPos:Lerp(serverPos, correctionAlpha)
		end
		correctedPos = Vector3.new(correctedPos.X, serverPos.Y, correctedPos.Z)
		data.renderPos = correctedPos

		local headingTarget = data.forward
		if planarVel.Magnitude > 0.45 then
			headingTarget = planarVel.Unit
		else
			local queueFacing = Vector3.new(
				tonumber(model:GetAttribute("QueueFacingX")) or 0,
				0,
				tonumber(model:GetAttribute("QueueFacingZ")) or 0
			)
			if queueFacing.Magnitude > 0.01 then
				headingTarget = queueFacing.Unit
			else
				local look = root.CFrame.LookVector
				local serverForward = Vector3.new(look.X, 0, look.Z)
				if serverForward.Magnitude > 0.01 then
					headingTarget = serverForward.Unit
				end
			end
		end
		if headingTarget.Magnitude < 0.01 then
			headingTarget = data.forward
		end
		if headingTarget.Magnitude < 0.01 then
			headingTarget = Vector3.zAxis
		end
		data.forward = (data.forward + (headingTarget - data.forward) * math.clamp(10 * dt, 0, 0.5)).Unit
		local targetCF = CFrame.lookAt(correctedPos, correctedPos + data.forward)
		data.renderCF = data.renderCF:Lerp(targetCF, math.clamp(12 * dt, 0, 0.55))
		root.CFrame = data.renderCF
	end
end

local function CleanupWalkerSmoothing()
	for model in pairs(WalkerSmoothData) do
		if not model or not model.Parent then
			WalkerSmoothData[model] = nil
		end
	end
end

-- Terrain raycast params for client interpolation
-- ============================================================================
-- MAIN UPDATE LOOP (Visual sync)
-- ============================================================================
local lastVisualUpdate = 0
local lastSkiSmoothUpdate = 0
local lastWalkerSmoothUpdate = 0
local cleanupCounter = 0 -- PERF: throttle cleanup sweeps
local visualSliceCursor = 0
local walkerSliceCursor = 0
local crowdSurvivalActive = false

local function GetSkiSmoothingInterval()
	local runtimeTier = GetRuntimePerfTier()
	local baseInterval = RUNTIME_SMOOTH_INTERVAL[runtimeTier + 1] or 0
	local guestPerfLevel = GetGuestPerformanceModeLevel()
	if guestPerfLevel <= 0 then
		return baseInterval
	end
	local perfMinimum = (guestPerfLevel == 1 and (1 / 45)) or (guestPerfLevel == 2 and (1 / 28)) or (1 / 18)
	if baseInterval <= 0 then
		return perfMinimum
	end
	return math.max(baseInterval, perfMinimum)
end

local function GetWalkerSmoothingInterval(guestCount)
	local baseInterval
	if guestCount >= 700 then
		baseInterval = 0.24
	elseif guestCount >= 450 then
		baseInterval = 0.18
	elseif guestCount >= 220 then
		baseInterval = 0.12
	elseif guestCount >= 90 then
		baseInterval = 0.08
	else
		baseInterval = 0.04
	end
	if baseInterval <= 0 then
		return 0
	end
	local runtimeTier = GetRuntimePerfTier()
	local runtimeMult = RUNTIME_VISUAL_INTERVAL_MULT[runtimeTier + 1] or 1
	local guestPerfLevel = GetGuestPerformanceModeLevel()
	local guestPerfMult = GUEST_PERF_VISUAL_INTERVAL_MULT[guestPerfLevel + 1] or 1
	return baseInterval * runtimeMult * guestPerfMult
end

local function GetVisualUpdateInterval(guestCount)
	local baseInterval
	if guestCount >= 700 then
		baseInterval = 1.0
	elseif guestCount >= 450 then
		baseInterval = 0.8
	elseif guestCount >= 220 then
		baseInterval = 0.6
	elseif guestCount >= 90 then
		baseInterval = 0.42
	else
		baseInterval = 0.3
	end
	local runtimeTier = GetRuntimePerfTier()
	local runtimeMult = RUNTIME_VISUAL_INTERVAL_MULT[runtimeTier + 1] or 1
	local guestPerfLevel = GetGuestPerformanceModeLevel()
	local guestPerfMult = GUEST_PERF_VISUAL_INTERVAL_MULT[guestPerfLevel + 1] or 1
	return baseInterval * runtimeMult * guestPerfMult
end

-- ============================================================================
-- GUEST ANIMATION MANAGEMENT
-- ============================================================================
-- Tracks per-guest animation state to avoid playing walk anim while skiing
local GuestAnimTracks = {} -- { [model] = { ski = AnimTrack?, sit = AnimTrack?, state = "idle"|"skiing"|"sitting" } }
local GuestWalkTracks = {} -- { [model] = { track = AnimTrack?, lastPos = Vector3?, lastAt = number? } }

local SKI_ANIM_ID = "rbxassetid://180435571" -- ski/tow animation (arms forward, legs together)
local SIT_ANIM_R15 = "rbxassetid://2506281703"
local SIT_ANIM_R6  = "rbxassetid://103561694332640"
local WALK_ANIM_ID = "rbxassetid://180426354"
local WALK_PLAY_THRESHOLD = 0.08
local WALK_STOP_THRESHOLD = 0.03
local WALK_SPEED_NORMALIZER = 14

local function GetGuestAnimState(model)
	if not GuestAnimTracks[model] then
		GuestAnimTracks[model] = { ski = nil, sit = nil, state = "idle" }
	end
	return GuestAnimTracks[model]
end

local function StopAllGuestAnims(model)
	local state = GuestAnimTracks[model]
	if not state then return end
	if state.ski then pcall(function() state.ski:Stop() end); state.ski = nil end
	if state.sit then pcall(function() state.sit:Stop() end); state.sit = nil end
	state.state = "idle"
end

local function PlayGuestAnim(model, animType)
	local state = GetGuestAnimState(model)
	if state.state == animType then return end -- already playing

	local hum = model:FindFirstChild("Humanoid")
	if not hum then return end
	local animator = hum:FindFirstChild("Animator")
	if not animator then animator = Instance.new("Animator", hum) end

	-- Stop current
	StopAllGuestAnims(model)

	local animId
	if animType == "skiing" then
		animId = SKI_ANIM_ID
	elseif animType == "sitting" then
		if hum.RigType == Enum.HumanoidRigType.R15 then
			animId = SIT_ANIM_R15
		else
			animId = SIT_ANIM_R6
		end
	else
		return -- idle = no forced animation
	end

	local anim = Instance.new("Animation")
	anim.AnimationId = animId
	local track = animator:LoadAnimation(anim)
	track.Looped = true
	track.Priority = Enum.AnimationPriority.Action
	track:Play()

	if animType == "skiing" then
		state.ski = track
	elseif animType == "sitting" then
		state.sit = track
	end
	state.state = animType
end

local function StopGuestWalkAnim(model)
	local state = GuestWalkTracks[model]
	if not state then return end
	if state.track and state.track.IsPlaying then
		pcall(function()
			state.track:Stop(0.12)
		end)
	end
end

local function UpdateGuestWalkAnim(model, root)
	local hum = model:FindFirstChild("Humanoid")
	if not hum then
		GuestWalkTracks[model] = nil
		return
	end
	local state = GuestWalkTracks[model]
	if not state then
		state = {}
		GuestWalkTracks[model] = state
	end
	local now = tick()
	local planarVel = Vector3.new(root.AssemblyLinearVelocity.X, 0, root.AssemblyLinearVelocity.Z).Magnitude
	if state.lastPos and state.lastAt then
		local elapsed = math.max(1 / 240, now - state.lastAt)
		local delta = Vector3.new(root.Position.X, 0, root.Position.Z) - Vector3.new(state.lastPos.X, 0, state.lastPos.Z)
		local displacementSpeed = delta.Magnitude / elapsed
		if displacementSpeed > planarVel then
			planarVel = displacementSpeed
		end
	end
	state.lastPos = root.Position
	state.lastAt = now

	if planarVel < WALK_STOP_THRESHOLD then
		StopGuestWalkAnim(model)
		return
	end
	if planarVel < WALK_PLAY_THRESHOLD then
		return
	end

	if not state.track then
		local animator = hum:FindFirstChild("Animator")
		if not animator then animator = Instance.new("Animator", hum) end
		local walkAnim = Instance.new("Animation")
		walkAnim.AnimationId = WALK_ANIM_ID
		local track = animator:LoadAnimation(walkAnim)
		track.Looped = true
		track.Priority = Enum.AnimationPriority.Movement
		state.track = track
	end
	if not state.track then return end
	if not state.track.IsPlaying then
		pcall(function()
			state.track:Play(0.12)
		end)
	end
	local speedScale = math.clamp(planarVel / WALK_SPEED_NORMALIZER, 0.35, 1.7)
	pcall(function()
		state.track:AdjustSpeed(speedScale)
	end)
end

local function RemoveGuestProceduralController(model)
	local controller = GuestProceduralControllers[model]
	if controller then
		controller:Destroy()
		GuestProceduralControllers[model] = nil
	end
end

local function GetGuestProceduralController(model)
	local controller = GuestProceduralControllers[model]
	if controller then
		return controller
	end
	local hum = model:FindFirstChild("Humanoid")
	if not hum then
		return nil
	end
	controller = ProceduralSkiAnimator.new(model, hum)
	GuestProceduralControllers[model] = controller
	return controller
end

local function SafeUnit(vector, fallback)
	if vector.Magnitude > 1e-4 then
		return vector.Unit
	end
	return fallback or Vector3.zero
end

local function BuildGuestProceduralState(model, root, isSkiing, hasSkis, ridingLift)
	local lookVector = SafeUnit(Vector3.new(root.CFrame.LookVector.X, 0, root.CFrame.LookVector.Z), Vector3.new(0, 0, -1))
	local planarVelocity
	local speed
	if isSkiing then
		planarVelocity = Vector3.new(
			tonumber(model:GetAttribute("SkiVelX")) or root.AssemblyLinearVelocity.X,
			0,
			tonumber(model:GetAttribute("SkiVelZ")) or root.AssemblyLinearVelocity.Z
		)
		speed = tonumber(model:GetAttribute("SkiSpeed")) or planarVelocity.Magnitude
	else
		planarVelocity = Vector3.new(root.AssemblyLinearVelocity.X, 0, root.AssemblyLinearVelocity.Z)
		speed = planarVelocity.Magnitude
	end

	local planarDirection = SafeUnit(planarVelocity, lookVector)
	local turnCross = (lookVector.X * planarDirection.Z) - (lookVector.Z * planarDirection.X)
	local steer = math.clamp(-turnCross * 3, -1, 1)

	return SkiStateSchema.Build({
		current = isSkiing and "skiing" or "off",
		velocity = Vector3.new(planarVelocity.X, root.AssemblyLinearVelocity.Y, planarVelocity.Z),
		normal = root.CFrame.UpVector,
		groundedAlpha = ridingLift and 0 or 1,
		grounded = not ridingLift,
		steer = steer,
		turnRate = steer * math.clamp(speed / 18, 0, 4.5),
		slipAmount = math.clamp(math.abs(turnCross), 0, 1),
		forward = root.CFrame.LookVector,
		planarVelocity = planarVelocity,
		speed = speed,
		ridingLift = ridingLift and ridingLift ~= false,
		wantsBootWalk = hasSkis == true and not isSkiing and not ridingLift,
	})
end

RunService.Heartbeat:Connect(function(dt)
	local now = tick()
	local guestModels = CachedGuestModels
	local guestCount = #guestModels
	if guestCount <= 0 then
		crowdSurvivalActive = false
		for proxiedModel in pairs(GuestProxyModeState) do
			SetGuestModelProxyMode(proxiedModel, false)
		end
		return
	end
	if crowdSurvivalActive then
		if guestCount <= 520 then
			crowdSurvivalActive = false
			for proxiedModel in pairs(GuestProxyModeState) do
				SetGuestModelProxyMode(proxiedModel, false)
			end
		end
	elseif guestCount >= 700 then
		crowdSurvivalActive = true
	end
	local camera = Workspace.CurrentCamera
	local camPos = camera and camera.CFrame.Position

	-- FAST: ski smoothing remains high-frequency near the camera, but is throttled by runtime perf tier.
	if crowdSurvivalActive then
		table.clear(SkiSmoothData)
		table.clear(WalkerSmoothData)
	else
		local skiInterval = GetSkiSmoothingInterval()
		local elapsedSki = now - lastSkiSmoothUpdate
		if skiInterval <= 0 or elapsedSki >= skiInterval then
			lastSkiSmoothUpdate = now
			UpdateSkiSmoothing(skiInterval <= 0 and dt or math.max(dt, elapsedSki), camPos, guestCount)
		end
		local walkerInterval = GetWalkerSmoothingInterval(guestCount)
		local elapsedWalker = now - lastWalkerSmoothUpdate
		if walkerInterval <= 0 or elapsedWalker >= walkerInterval then
			lastWalkerSmoothUpdate = now
			UpdateWalkerSmoothing(walkerInterval <= 0 and dt or math.max(dt, elapsedWalker), guestModels, camPos, now, guestCount)
		end
	end

	-- SLOW: visual checks scale down as guest counts rise.
	local visualInterval = GetVisualUpdateInterval(guestCount)
	if crowdSurvivalActive then
		visualInterval = math.max(1.15, visualInterval)
	end
	if now - lastVisualUpdate < visualInterval then return end
	lastVisualUpdate = now

	local guestPerfLevel = GetGuestPerformanceModeLevel()
	local visualActiveDistance = GetVisualActiveDistance(guestCount) * GetNPCDistanceScale()
	local npcDistanceChoice = GraphicsProfile.GetDistanceChoice(Player, "NPCRenderDistance")
	local npcDistanceOff = npcDistanceChoice == "Off"
	local renderDistance = math.min(1200, visualActiveDistance * 0.85)
	local runtimePerfTier = GetRuntimePerfTier()
	if runtimePerfTier >= 2 then
		visualActiveDistance *= 0.58
		renderDistance *= 0.56
	elseif runtimePerfTier >= 1 then
		visualActiveDistance *= 0.76
		renderDistance *= 0.74
	end

	local perfDistanceMult = GUEST_PERF_VISUAL_DISTANCE_MULT[guestPerfLevel + 1] or 1
	visualActiveDistance *= perfDistanceMult
	renderDistance *= perfDistanceMult

	local crowdProxyDistance = 0
	if crowdSurvivalActive then
		crowdProxyDistance = 128
		if npcDistanceChoice == "Far" then
			crowdProxyDistance = 150
		elseif npcDistanceOff then
			crowdProxyDistance = 165
		end
		crowdProxyDistance *= math.max(0.85, GetNPCDistanceScale())
		visualActiveDistance = math.min(visualActiveDistance, crowdProxyDistance * 0.72)
		renderDistance = math.huge
	end
	local crowdProxyDistanceSq = crowdProxyDistance * crowdProxyDistance

	local guestModelsVisible = Player:GetAttribute("GuestModelsVisible") ~= false
	if not crowdSurvivalActive then
		if npcDistanceOff then
			if guestPerfLevel <= 0 then
				renderDistance = 1000000
				visualActiveDistance = 1000000
			else
				local forcedDistance = GUEST_PERF_OFF_RENDER_DISTANCE[guestPerfLevel + 1] or 520
				renderDistance = math.min(renderDistance, forcedDistance)
				visualActiveDistance = math.min(visualActiveDistance, forcedDistance * 0.8)
			end
		elseif not guestModelsVisible then
			-- Keep a small near-field bubble visible so guests never stay invisible when you
			-- are standing right next to them.
			renderDistance = math.max(140, math.min(renderDistance, 180))
			visualActiveDistance = math.max(90, math.min(visualActiveDistance, 130))
		end
	end

	local visualActiveDistanceSq = visualActiveDistance * visualActiveDistance
	local forceUncullDistance = crowdSurvivalActive and crowdProxyDistance
		or (npcDistanceOff and (guestPerfLevel <= 0 and math.huge or math.max(90, renderDistance * 0.45)) or math.max(70, math.min(260, renderDistance * 0.35)))
	local forceUncullDistanceSq = forceUncullDistance * forceUncullDistance

	local guestSliceDivisor = 1
	if not npcDistanceOff or guestPerfLevel >= 1 then
		if guestCount >= 420 then
			guestSliceDivisor = 8
		elseif guestCount >= 280 then
			guestSliceDivisor = 6
		elseif guestCount >= 170 then
			guestSliceDivisor = 5
		elseif guestCount >= 90 then
			guestSliceDivisor = 3
		elseif guestCount >= 50 then
			guestSliceDivisor = 2
		end
	end
	if crowdSurvivalActive then
		guestSliceDivisor = math.max(guestSliceDivisor, 7)
	end
	if guestSliceDivisor > 1 then
		visualSliceCursor = (visualSliceCursor % guestSliceDivisor) + 1
	else
		visualSliceCursor = 1
	end

	local visibleBudget = nil
	if guestPerfLevel >= 2 and camPos then
		local sortedGuests = {}
		for _, model in ipairs(guestModels) do
			if model:IsA("Model") then
				local root = model:FindFirstChild("HumanoidRootPart")
				if root then
					local delta = root.Position - camPos
					table.insert(sortedGuests, {model = model, distSq = delta:Dot(delta)})
				end
			end
		end
		table.sort(sortedGuests, function(a, b)
			return a.distSq < b.distSq
		end)
		local keepScale = GUEST_PERF_MAX_VISIBLE_SCALE[guestPerfLevel + 1] or 0.3
		local keepMin = GUEST_PERF_MAX_VISIBLE_MIN[guestPerfLevel + 1] or 72
		local keepMax = GUEST_PERF_MAX_VISIBLE_MAX[guestPerfLevel + 1] or 170
		local keepCount = math.clamp(math.floor((guestCount * keepScale) + 0.5), keepMin, keepMax)
		visibleBudget = {}
		for i = 1, math.min(keepCount, #sortedGuests) do
			visibleBudget[sortedGuests[i].model] = true
		end
	end

	local animationActiveDistance = math.max(130, math.min(360, visualActiveDistance * 0.8))
	if guestPerfLevel == 1 then
		animationActiveDistance = math.min(animationActiveDistance, 260)
	elseif guestPerfLevel == 2 then
		animationActiveDistance = math.min(animationActiveDistance, 190)
	elseif guestPerfLevel >= 3 then
		animationActiveDistance = math.min(animationActiveDistance, 140)
	end
	local animationActiveDistanceSq = animationActiveDistance * animationActiveDistance

	for index, model in ipairs(guestModels) do
		if not model:IsA("Model") then continue end
		local root = model:FindFirstChild("HumanoidRootPart")
		if not root or not camPos then
			SetGuestModelProxyMode(model, false)
			continue
		end

		local toCamera = root.Position - camPos
		local distSq = toCamera:Dot(toCamera)

		if visibleBudget and not visibleBudget[model] then
			SetGuestModelProxyMode(model, false)
			if not model:GetAttribute("_Culled") then
				SetGuestModelLocalCulled(model, true)
			end
			DetachSkisVisual(model)
			RemoveSkiEffects(model)
			RemoveGuestProceduralController(model)
			StopGuestWalkAnim(model)
			local animState = GuestAnimTracks[model]
			if animState and animState.state ~= "idle" then
				StopAllGuestAnims(model)
			end
			continue
		end

		local crowdProxyMode = crowdSurvivalActive
			and distSq > crowdProxyDistanceSq
			and not model:GetAttribute("RidingLift")
			and not model:GetAttribute("InspectSelected")
		if crowdProxyMode then
			SetGuestModelProxyMode(model, true)
			SkiSmoothData[model] = nil
			WalkerSmoothData[model] = nil
			DetachSkisVisual(model)
			RemoveSkiEffects(model)
			RemoveGuestProceduralController(model)
			StopGuestWalkAnim(model)
			local animState = GuestAnimTracks[model]
			if animState and animState.state ~= "idle" then
				StopAllGuestAnims(model)
			end
			continue
		else
			SetGuestModelProxyMode(model, false)
		end

		if guestSliceDivisor > 1 and ((index - visualSliceCursor) % guestSliceDivisor ~= 0) then
			if model:GetAttribute("_Culled") and distSq <= forceUncullDistanceSq then
				SetGuestModelLocalCulled(model, false)
			end
			continue
		end
		local ridingLiftDistanceFloor = math.min(renderDistance + 220, 900)
		local currentRenderDist = model:GetAttribute("RidingLift") and math.max(renderDistance, ridingLiftDistanceFloor) or renderDistance
		local currentRenderDistSq = currentRenderDist * currentRenderDist

		-- DISTANCE-BASED MODEL RENDERING: hide models entirely beyond renderDistance.
		local forceCrowdCull = guestPerfLevel >= 1
		local lodEnabled = ((Player:GetAttribute("GuestModelDistanceCullEnabled") == true)
			and (Player:GetAttribute("GuestLODEnabled") ~= false))
			or forceCrowdCull
		if npcDistanceOff and not forceCrowdCull then
			lodEnabled = false
		end
		if lodEnabled and distSq > currentRenderDistSq then
			-- Full cull: hide locally while preserving server-driven transparency.
			if not model:GetAttribute("_Culled") then
				SetGuestModelLocalCulled(model, true)
			end
			DetachSkisVisual(model)
			RemoveSkiEffects(model)
			RemoveGuestProceduralController(model)
			StopGuestWalkAnim(model)
			local animState = GuestAnimTracks[model]
			if animState and animState.state ~= "idle" then
				StopAllGuestAnims(model)
			end
			continue
		elseif model:GetAttribute("_Culled") then
			SetGuestModelLocalCulled(model, false)
		end

		-- Visual LOD: skip effects/animations beyond visual distance (but model still visible)
		if distSq > visualActiveDistanceSq and not model:GetAttribute("RidingLift") then
			local hasSkisFar = model:GetAttribute("HasSkis") == true or IsGuestMarkedSkiing(model)
			if hasSkisFar and guestPerfLevel <= 2 then
				AttachSkisVisual(model)
			else
				DetachSkisVisual(model)
			end
			RemoveSkiEffects(model)
			RemoveGuestProceduralController(model)
			StopGuestWalkAnim(model)
			local animState = GuestAnimTracks[model]
			if animState and animState.state ~= "idle" then
				StopAllGuestAnims(model)
			end
			continue
		end

		if guestPerfLevel >= 1 and distSq > animationActiveDistanceSq and not model:GetAttribute("RidingLift") then
			local hasSkisFar = model:GetAttribute("HasSkis") == true or IsGuestMarkedSkiing(model)
			if hasSkisFar and guestPerfLevel <= 2 then
				AttachSkisVisual(model)
			else
				DetachSkisVisual(model)
			end
			RemoveSkiEffects(model)
			RemoveGuestProceduralController(model)
			StopGuestWalkAnim(model)
			local animState = GuestAnimTracks[model]
			if animState and animState.state ~= "idle" then
				StopAllGuestAnims(model)
			end
			continue
		end

		local isSkiing = IsGuestMarkedSkiing(model)
		local hasSkis = model:GetAttribute("HasSkis")
		local ridingLift = model:GetAttribute("RidingLift")
		local guestSkiState = BuildGuestProceduralState(model, root, isSkiing, hasSkis, ridingLift)

		local allowSkiVisuals = guestPerfLevel <= 2
		if allowSkiVisuals and (isSkiing or ridingLift or hasSkis) then
			AttachSkisVisual(model)
		else
			DetachSkisVisual(model)
		end

		local allowSkiEffects = guestPerfLevel <= 0
		if allowSkiEffects and isSkiing then
			CreateSkiEffects(model)
			UpdateSkiEffects(model, dt, guestSkiState)
		else
			RemoveSkiEffects(model)
		end

		-- Animation management: procedural skiing only while actively skiing.
		-- Walking guests (including guests carrying skis) use movement-driven walk animation.
		if isSkiing then
			if guestPerfLevel <= 1 then
				local controller = GetGuestProceduralController(model)
				if controller then
					controller:Step(dt, guestSkiState)
				end
			else
				RemoveGuestProceduralController(model)
			end
			local animState = GuestAnimTracks[model]
			if animState and animState.state ~= "idle" then
				StopAllGuestAnims(model)
			end
			StopGuestWalkAnim(model)
		elseif ridingLift and ridingLift ~= false then
			RemoveGuestProceduralController(model)
			if guestPerfLevel <= 2 then
				PlayGuestAnim(model, "sitting")
			else
				local animState = GuestAnimTracks[model]
				if animState and animState.state ~= "idle" then
					StopAllGuestAnims(model)
				end
			end
			StopGuestWalkAnim(model)
		else
			RemoveGuestProceduralController(model)
			local animState = GuestAnimTracks[model]
			if animState and animState.state ~= "idle" then
				StopAllGuestAnims(model)
			end
			if guestPerfLevel <= 1 then
				UpdateGuestWalkAnim(model, root)
			else
				StopGuestWalkAnim(model)
			end
		end
	end

	-- PERF: Run cleanup sweeps only every 5th visual tick to reduce iteration overhead
	cleanupCounter += 1
	if cleanupCounter >= 5 then
		cleanupCounter = 0

		-- Cleanup effects and animations for removed models
		for model in pairs(activeEffects) do
			if not model or not model.Parent then
				RemoveSkiEffects(model)
			end
		end
		for model in pairs(GuestProceduralControllers) do
			if not model or not model.Parent then
				RemoveGuestProceduralController(model)
			end
		end
		for model in pairs(GuestAnimTracks) do
			if not model or not model.Parent then
				StopAllGuestAnims(model)
				GuestAnimTracks[model] = nil
			end
		end
		for model, state in pairs(GuestWalkTracks) do
			if not model or not model.Parent then
				if state and state.track and state.track.IsPlaying then
					pcall(function()
						state.track:Stop(0.1)
					end)
				end
				GuestWalkTracks[model] = nil
			end
		end
		-- Clean up speech logs for despawned guests
		for model in pairs(GuestSpeechLogs) do
			if not model or not model.Parent then
				GuestSpeechLogs[model] = nil
			end
		end
		CleanupSkiSmoothing()
		CleanupWalkerSmoothing()
	end

	-- Update info panel
	if isInfoOpen then
		RefreshInfoPanel()
	end
end)


-- ============================================================================
-- TIP FLOAT LABELS — "+$XX 💰" bubble above guests when they pay
-- ============================================================================
local TipFloatEvent = Events and Events:FindFirstChild("TipFloat")
if TipFloatEvent then
	TipFloatEvent.OnClientEvent:Connect(function(guestModel, amount)
		if GetGuestPerformanceModeLevel() >= 2 then return end
		if not guestModel or not guestModel.Parent then return end
		local root = guestModel:FindFirstChild("HumanoidRootPart")
		if not root then return end

		-- Remove any existing tip float so they don't stack
		local existing = root:FindFirstChild("TipFloat")
		if existing then existing:Destroy() end

		local billboard = Instance.new("BillboardGui")
		billboard.Name = "TipFloat"
		billboard.Size = UDim2.new(0, 120, 0, 36)
		billboard.StudsOffset = Vector3.new(0, 6.5, 0)
		billboard.AlwaysOnTop = false
		billboard.MaxDistance = 80
		billboard.Parent = root

		local label = Instance.new("TextLabel", billboard)
		label.Size = UDim2.new(1, 0, 1, 0)
		label.BackgroundTransparency = 1
		label.Text = "+$" .. tostring(amount) .. " 💰"
		label.TextColor3 = Color3.fromRGB(255, 215, 0)       -- gold
		label.Font = Enum.Font.GothamBlack
		label.TextSize = 18
		label.TextStrokeTransparency = 0.4
		label.TextStrokeColor3 = Color3.fromRGB(60, 40, 0)

		-- Float up and fade out
		local startStuds = billboard.StudsOffset
		task.spawn(function()
			local elapsed = 0
			local DURATION = 2.0
			while elapsed < DURATION do
				local dt = task.wait()
				elapsed = elapsed + dt
				local t = math.clamp(elapsed / DURATION, 0, 1)
				billboard.StudsOffset = Vector3.new(0, 6.5 + t * 5, 0)
				label.TextTransparency = math.clamp(t * 1.5, 0, 1)
			end
			if billboard and billboard.Parent then
				billboard:Destroy()
			end
		end)
	end)
end

-- ============================================================================
-- RATING STARS HUD UPDATE
-- ============================================================================
task.spawn(function()
	local RatingEvent = Events and Events:WaitForChild("RatingUpdate", 10)
	if not RatingEvent then return end

	local sortedStars = {}
	local hasInitializedStars = false

	local function GetHUDStars()
		if hasInitializedStars and #sortedStars == 5 and sortedStars[1] and sortedStars[1].Parent then return sortedStars end
		local HUD = PlayerGui:WaitForChild("MainHUD", 5)
		if not HUD then return nil end
		local topFrame = HUD:WaitForChild("Top", 5)
		if not topFrame then return nil end
		local topBar = topFrame:WaitForChild("TopBar", 5)
		if not topBar then return nil end
		local ratingFrame = topBar:WaitForChild("Rating", 5)
		if not ratingFrame then return nil end

		for _, child in ipairs(ratingFrame:GetChildren()) do
			if child:IsA("ImageLabel") then child:Destroy() end
		end

		local layout = ratingFrame:FindFirstChildOfClass("UIListLayout")
		if layout then layout.SortOrder = Enum.SortOrder.LayoutOrder end

		sortedStars = {}
		for i = 1, 5 do
			local star = Instance.new("ImageLabel")
			star.Name = "Star" .. i
			star.LayoutOrder = i
			star.Size = UDim2.new(0.156, 0, 0.65, 0)
			star.BackgroundTransparency = 1
			star.ImageColor3 = Color3.fromRGB(248, 210, 72)

			local aspect = Instance.new("UIAspectRatioConstraint")
			aspect.Parent = star

			star.Parent = ratingFrame
			table.insert(sortedStars, star)
		end
		hasInitializedStars = true
		return sortedStars
	end

	local function applyRating(rating)
		-- Guard against non-numbers instantly
		rating = tonumber(rating)
		if not rating then return end

		local stars = GetHUDStars()
		if not stars then return end
		for i = 1, 5 do
			local starValue = rating - (i - 1)
			if starValue >= 0.75 then
				stars[i].Image = "rbxassetid://118035152077670" -- Fill
			elseif starValue >= 0.25 then
				stars[i].Image = "rbxassetid://117125350535058" -- Half
			else
				stars[i].Image = "rbxassetid://128997250034538" -- Empty
			end
		end
	end

	-- Initialize with leaderstats rating if available
	local initialRating = 0
	local ls = Player:WaitForChild("leaderstats", 5)
	if ls then
		local rVal = ls:WaitForChild("Rating", 5)
		if rVal then
			initialRating = rVal.Value
		end
	end
	applyRating(initialRating)

	-- Update on future events
	RatingEvent.OnClientEvent:Connect(function(rating)
		applyRating(rating)
	end)

	-- Fallback loop since UI might be hidden/rebuilt
	task.spawn(function()
		while task.wait(5) do
			if ls then
				local rVal = ls:FindFirstChild("Rating")
				if rVal then
					applyRating(rVal.Value)
				end
			end
		end
	end)
end)
