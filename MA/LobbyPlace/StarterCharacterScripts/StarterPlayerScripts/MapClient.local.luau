--[=[ PATH: StarterPlayerScripts/MapClient | TYPE: LocalScript ]=]--
--[[
	🏔️ RESORT TRAIL MAP CLIENT V2.0

	Renders a REAL ski-resort-style trail map:
	• Painterly mountain terrain (warm tones like a real brochure)
	• Every slope drawn as a colored trail with name label + difficulty badge
	• Lifts as cable lines with gondola markers
	• Buildings as icons
	• "You Are Here" pulsing dot
	• Full legend + compass
	• Fits ALL placed runs on screen no matter how big the resort is

	Press M to open/close.
]]

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService        = game:GetService("RunService")
local TweenService      = game:GetService("TweenService")
local UserInputService  = game:GetService("UserInputService")

local Player = Players.LocalPlayer
local PGui   = Player:WaitForChild("PlayerGui")
local Events = ReplicatedStorage:WaitForChild("Events")

local MapRemote = Events:WaitForChild("GetResortMapData", 15)
if not MapRemote then warn("[MapClient] GetResortMapData remote not found") return end

-- ─────────────────────────────────────────────────────────────────────────────
-- CONFIG
-- ─────────────────────────────────────────────────────────────────────────────
local CANVAS_W = 820
local CANVAS_H = 680
local PAD      = 36

local DIFF = {
	Green        = { color = Color3.fromRGB(48, 168, 66),   width = 5, sym = "●", bg = Color3.fromRGB(48, 168, 66)   },
	Blue         = { color = Color3.fromRGB(38, 122, 220),  width = 6, sym = "■", bg = Color3.fromRGB(38, 122, 220)  },
	Black        = { color = Color3.fromRGB(18, 18, 18),    width = 6, sym = "◆", bg = Color3.fromRGB(18, 18, 18)    },
	["Double Black"] = { color = Color3.fromRGB(10,10,10),  width = 7, sym = "◆◆", bg = Color3.fromRGB(10, 10, 10)  },
}
local DIFF_DEFAULT = { color = Color3.fromRGB(100, 180, 255), width = 4, sym = "●", bg = Color3.fromRGB(80, 140, 220) }

local TERRAIN_PALETTE = {
	{ t = 0.00, r =  82, g = 120, b =  56 },
	{ t = 0.20, r = 122, g = 148, b =  88 },
	{ t = 0.38, r = 168, g = 156, b = 118 },
	{ t = 0.55, r = 210, g = 200, b = 182 },
	{ t = 0.72, r = 232, g = 230, b = 228 },
	{ t = 1.00, r = 250, g = 252, b = 255 },
}

local LIFT_COLOR   = Color3.fromRGB(200, 60, 50)
local BLDG_ICONS   = { Food="🍽️", Rental="🎿", Shop="🛍️", House="🏠", Lodge="🏠", Building="🏗️" }

local Bounds     = nil
local MapGui     = nil
local PlayerDot  = nil
local isOpen     = false
local isLoading  = false

local _scale, _offX, _offZ = 1, 0, 0

local function recalcProjection()
	if not Bounds then return end
	local bw = Bounds.MaxX - Bounds.MinX
	local bh = Bounds.MaxZ - Bounds.MinZ
	local drawW = CANVAS_W - PAD * 2
	local drawH = CANVAS_H - PAD * 2
	_scale = math.min(drawW / bw, drawH / bh)
	_offX  = PAD + (drawW - bw * _scale) / 2
	_offZ  = PAD + (drawH - bh * _scale) / 2
end

local function w2m(worldX, worldZ)
	local px = _offX + (worldX - Bounds.MinX) * _scale
	local pz = _offZ + (worldZ - Bounds.MinZ) * _scale
	return Vector2.new(px, pz)
end

local function corner(p, r) local c=Instance.new("UICorner") c.CornerRadius=UDim.new(0,r or 8) c.Parent=p return c end
local function stroke(p,col,t) local s=Instance.new("UIStroke") s.Color=col or Color3.new(1,1,1) s.Thickness=t or 1.5 s.Transparency=0.4 s.Parent=p return s end
local function pad(p,l,r,t,b) local ui=Instance.new("UIPadding") ui.PaddingLeft=UDim.new(0,l) ui.PaddingRight=UDim.new(0,r) ui.PaddingTop=UDim.new(0,t) ui.PaddingBottom=UDim.new(0,b) ui.Parent=p return ui end

local function box(parent, w, h, x, y, color, alpha, zi)
	local f = Instance.new("Frame")
	f.Size = UDim2.fromOffset(w, h)
	f.Position = UDim2.fromOffset(x, y)
	f.BackgroundColor3 = color or Color3.new(1,1,1)
	f.BackgroundTransparency = alpha or 0
	f.BorderSizePixel = 0
	if zi then f.ZIndex = zi end
	f.Parent = parent
	return f
end

local function text(parent, str, w, h, x, y, col, sz, bold, zi)
	local l = Instance.new("TextLabel")
	l.Size = UDim2.fromOffset(w, h)
	l.Position = UDim2.fromOffset(x, y)
	l.BackgroundTransparency = 1
	l.Text = str
	l.TextColor3 = col or Color3.new(1,1,1)
	l.Font = bold and Enum.Font.GothamBold or Enum.Font.Gotham
	l.TextSize = sz or 13
	l.BorderSizePixel = 0
	if zi then l.ZIndex = zi end
	l.Parent = parent
	return l
end

local function line(canvas, p1, p2, col, w, zi)
	local d = p2 - p1
	local len = d.Magnitude
	if len < 0.5 then return nil end
	local f = Instance.new("Frame")
	f.AnchorPoint = Vector2.new(0.5, 0.5)
	f.Size = UDim2.fromOffset(len, w or 3)
	f.Position = UDim2.fromOffset((p1.X + p2.X) / 2, (p1.Y + p2.Y) / 2)
	f.BackgroundColor3 = col or Color3.new(1,1,1)
	f.BorderSizePixel = 0
	f.Rotation = math.deg(math.atan2(d.Y, d.X))
	f.ZIndex = zi or 5
	f.Parent = canvas
	return f
end

local function lerpPalette(t)
	t = math.clamp(t, 0, 1)
	for i = 2, #TERRAIN_PALETTE do
		local lo = TERRAIN_PALETTE[i-1]
		local hi = TERRAIN_PALETTE[i]
		if t <= hi.t then
			local s = (t - lo.t) / (hi.t - lo.t)
			return Color3.fromRGB(
				math.floor(lo.r + s * (hi.r - lo.r)),
				math.floor(lo.g + s * (hi.g - lo.g)),
				math.floor(lo.b + s * (hi.b - lo.b))
			)
		end
	end
	local last = TERRAIN_PALETTE[#TERRAIN_PALETTE]
	return Color3.fromRGB(last.r, last.g, last.b)
end

local function renderTerrain(canvas, td)
	if not td or not td.Grid then
		canvas.BackgroundColor3 = Color3.fromRGB(120, 160, 110)
		return
	end
	local grid = td.Grid
	local res  = td.Resolution or 48
	local minH = td.MinHeight  or 0
	local maxH = td.MaxHeight  or 1
	local hR   = math.max(1, maxH - minH)
	local VIS  = math.min(res, 28)
	local step = res / VIS
	local cw   = (CANVAS_W - PAD * 2) / VIS
	local ch   = (CANVAS_H - PAD * 2) / VIS
	for row = 1, VIS do
		local sRow = math.min(res, math.ceil(row * step))
		if not grid[sRow] then continue end
		for col = 1, VIS do
			local sCol = math.min(res, math.ceil(col * step))
			local h    = grid[sRow][sCol] or 0
			local t    = (h - minH) / hR
			local cell = box(canvas,
				math.ceil(cw) + 2, math.ceil(ch) + 2,
				math.floor(PAD + (col - 1) * cw),
				math.floor(PAD + (row - 1) * ch),
				lerpPalette(t), 0, 2
			)
		end
		if row % 6 == 0 then task.wait() end
	end
	for _, side in ipairs({
		{ 0,         0,         CANVAS_W, PAD/2 },
		{ 0,         CANVAS_H - PAD/2, CANVAS_W, PAD/2 },
		{ 0,         0,         PAD/2, CANVAS_H },
		{ CANVAS_W - PAD/2, 0, PAD/2, CANVAS_H },
	}) do
		local b = box(canvas, side[3], side[4], side[1], side[2], Color3.fromRGB(0,0,0), 0.55, 3)
	end
end

local function renderSlopes(canvas, slopes)
	for _, slope in ipairs(slopes) do
		local pts  = slope.Points
		local diff = slope.Difficulty or "Green"
		local d    = DIFF[diff] or DIFF_DEFAULT
		if not pts or #pts < 2 then continue end
		for i = 2, #pts do
			local p1 = w2m(pts[i-1][1], pts[i-1][3])
			local p2 = w2m(pts[i][1],   pts[i][3])
			line(canvas, p1, p2, Color3.new(1,1,1), d.width + 3, 4)
		end
		for i = 2, #pts do
			local p1 = w2m(pts[i-1][1], pts[i-1][3])
			local p2 = w2m(pts[i][1],   pts[i][3])
			line(canvas, p1, p2, d.color, d.width, 5)
		end
		local top = w2m(pts[1][1], pts[1][3])
		local slabel = text(canvas, slope.Name, 90, 15, top.X - 45, top.Y - 18,
			Color3.fromRGB(20, 20, 20), 10, true, 9)
		slabel.TextXAlignment = Enum.TextXAlignment.Center
		local slabelBg = box(canvas, 90, 15, top.X - 45, top.Y - 18, Color3.new(1,1,1), 0.12, 8)
		corner(slabelBg, 4)
		local midI = math.ceil(#pts / 2)
		local mp   = w2m(pts[midI][1], pts[midI][3])
		local bSize = diff == "Double Black" and 22 or 18
		local badge = box(canvas, bSize, bSize, mp.X - bSize/2, mp.Y - bSize/2, d.bg, 0, 8)
		corner(badge, bSize / 2)
		local bText = text(badge, d.sym, bSize, bSize, 0, 0,
			(diff == "Green" or diff == "Blue") and Color3.new(1,1,1) or Color3.fromRGB(240,240,240),
			diff == "Double Black" and 7 or 10, true, 9)
		bText.TextXAlignment = Enum.TextXAlignment.Center
	end
end

local function renderLifts(canvas, lifts)
	for _, lift in ipairs(lifts) do
		local sp = w2m(lift.StartPos[1], lift.StartPos[3])
		local ep = w2m(lift.EndPos[1],   lift.EndPos[3])
		local delta  = ep - sp
		local len    = delta.Magnitude
		if len < 2 then continue end
		local numSegs = math.max(1, math.floor(len / 14))
		for i = 0, numSegs - 1 do
			local t1 = i / numSegs
			local t2 = (i + 0.55) / numSegs
			local a  = sp + delta * t1
			local b  = sp + delta * t2
			line(canvas, a, b, LIFT_COLOR, 2, 6)
		end
		line(canvas, sp, ep, Color3.fromRGB(80, 30, 30), 1, 5)
		for _, station in ipairs({ sp, ep }) do
			local dot = box(canvas, 12, 12, station.X - 6, station.Y - 6, LIFT_COLOR, 0, 7)
			corner(dot, 6)
			local dInner = box(dot, 6, 6, 3, 3, Color3.new(1,1,1), 0, 8)
			corner(dInner, 3)
		end
		local iconPos = sp + delta * 0.35
		local gondola = box(canvas, 20, 14, iconPos.X - 10, iconPos.Y - 16, Color3.fromRGB(30, 20, 20), 0.15, 8)
		corner(gondola, 4)
		local gIcon = text(gondola, "🚡", 20, 14, 0, 0, Color3.new(1,1,1), 11, false, 9)
		gIcon.TextXAlignment = Enum.TextXAlignment.Center
		local mid   = sp + delta * 0.55
		local nLabel = box(canvas, 110, 18, mid.X - 55, mid.Y - 22, Color3.fromRGB(25, 15, 15), 0.2, 8)
		corner(nLabel, 5)
		local nText = text(nLabel, lift.Name, 110, 18, 0, 0, Color3.fromRGB(255, 210, 190), 10, true, 9)
		nText.TextXAlignment = Enum.TextXAlignment.Center
	end
end

local function renderBuildings(canvas, buildings)
	for _, bldg in ipairs(buildings) do
		local mp   = w2m(bldg.Position[1], bldg.Position[3])
		local icon = BLDG_ICONS[bldg.Type] or "🏗️"
		local bg   = box(canvas, 26, 26, mp.X - 13, mp.Y - 13, Color3.fromRGB(255, 235, 100), 0, 7)
		corner(bg, 6)
		stroke(bg, Color3.fromRGB(180, 150, 40), 1.5)
		local ic = text(bg, icon, 26, 26, 0, 0, Color3.new(1,1,1), 14, false, 8)
		ic.TextXAlignment = Enum.TextXAlignment.Center
		local nm = text(canvas, bldg.Name, 80, 13, mp.X - 40, mp.Y + 14,
			Color3.fromRGB(240, 230, 180), 9, true, 7)
		nm.TextXAlignment = Enum.TextXAlignment.Center
	end
end

local function makePlayerDot(canvas)
	PlayerDot = box(canvas, 16, 16, -200, -200, Color3.fromRGB(255, 60, 60), 0, 12)
	corner(PlayerDot, 8)
	stroke(PlayerDot, Color3.fromRGB(255, 255, 255), 2)
	local ring = box(PlayerDot, 28, 28, -6, -6, Color3.fromRGB(255, 80, 80), 0.5, 11)
	corner(ring, 14)
	TweenService:Create(ring, TweenInfo.new(1.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out, -1, false), {
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(36, 36),
		Position = UDim2.fromOffset(-10, -10),
	}):Play()
	local youLabel = box(canvas, 40, 16, -200, -200, Color3.fromRGB(220, 40, 40), 0.1, 13)
	youLabel.Name = "YouLabel"
	corner(youLabel, 4)
	local youText = text(youLabel, "YOU", 40, 16, 0, 0, Color3.new(1,1,1), 9, true, 14)
	youText.TextXAlignment = Enum.TextXAlignment.Center
	return PlayerDot, youLabel
end

local youLabel = nil

local function updatePlayerDot()
	if not PlayerDot or not Bounds then return end
	local char = Player.Character
	if not char then return end
	local hrp = char:FindFirstChild("HumanoidRootPart")
	if not hrp then return end
	local mp = w2m(hrp.Position.X, hrp.Position.Z)
	PlayerDot.Position = UDim2.fromOffset(mp.X - 8, mp.Y - 8)
	if youLabel then youLabel.Position = UDim2.fromOffset(mp.X - 20, mp.Y - 26) end
end

local function buildLegend(canvas)
	local lw, lh = 168, 210
	local panel = box(canvas, lw, lh, CANVAS_W - lw - 8, CANVAS_H - lh - 8,
		Color3.fromRGB(250, 248, 242), 0, 10)
	corner(panel, 10)
	stroke(panel, Color3.fromRGB(80, 60, 40), 1.5)
	local titleBar = box(panel, lw, 26, 0, 0, Color3.fromRGB(20, 60, 28), 0, 11)
	corner(titleBar, 10)
	local tl = text(titleBar, "TRAIL DIFFICULTY", lw, 26, 0, 0, Color3.new(1,1,1), 11, true, 12)
	tl.TextXAlignment = Enum.TextXAlignment.Center
	local rows = {
		{ sym = "●",  label = "Green (Easy)",          col = DIFF.Green.color },
		{ sym = "■",  label = "Blue (Intermediate)",    col = DIFF.Blue.color  },
		{ sym = "◆",  label = "Black (Advanced)",       col = DIFF.Black.color },
		{ sym = "◆◆", label = "Double Black (Expert)",  col = DIFF["Double Black"].color },
		{ sep = true },
		{ sym = "—",  label = "Chairlift / Gondola",   col = LIFT_COLOR },
		{ sym = "🟡", label = "Facility / Lodge",       col = Color3.fromRGB(200, 170, 30) },
		{ sym = "🔴", label = "Your Location",          col = Color3.fromRGB(220, 40, 40) },
	}
	local y = 32
	for _, row in ipairs(rows) do
		if row.sep then
			local sep = box(panel, lw - 16, 1, 8, y, Color3.fromRGB(160, 140, 100), 0.5, 11)
			y = y + 8
			continue
		end
		local symBg = box(panel, 18, 18, 10, y, row.col or Color3.fromRGB(100,100,100), 0, 11)
		corner(symBg, row.sym == "●" and 9 or 4)
		local symTxt = text(symBg, row.sym, 18, 18, 0, 0, Color3.new(1,1,1), 9, true, 12)
		symTxt.TextXAlignment = Enum.TextXAlignment.Center
		local lbl = text(panel, row.label, lw - 36, 18, 32, y, Color3.fromRGB(20, 20, 20), 11, false, 11)
		y = y + 22
	end
end

local function buildCompass(canvas)
	local size = 52
	local bg = box(canvas, size, size, CANVAS_W - size - 8, 8,
		Color3.fromRGB(245, 240, 230), 0, 10)
	corner(bg, size / 2)
	stroke(bg, Color3.fromRGB(80, 60, 40), 1.5)
	local n = text(bg, "N", size, 18, 0, 2, Color3.fromRGB(200, 30, 30), 16, true, 11)
	n.TextXAlignment = Enum.TextXAlignment.Center
	local cardinals = { {0, size-20, "S"}, {-2, size/2-8, "W"}, {size-12, size/2-8, "E"} }
	for _, c in ipairs(cardinals) do
		local cl = text(bg, c[3], 16, 16, c[1], c[2], Color3.fromRGB(60, 60, 60), 10, false, 11)
		cl.TextXAlignment = Enum.TextXAlignment.Center
	end
	local cx = text(bg, "✦", size, size, 0, 0, Color3.fromRGB(100, 80, 50), 20, false, 11)
	cx.TextXAlignment = Enum.TextXAlignment.Center
end

local function buildStatsBar(parent, data)
	local slopes = data.Slopes or {}
	local lifts  = data.Lifts  or {}
	local green, blue, black, dblack = 0, 0, 0, 0
	for _, s in ipairs(slopes) do
		local d = s.Difficulty or "Green"
		if d == "Green" then green += 1
		elseif d == "Blue" then blue += 1
		elseif d == "Black" then black += 1
		else dblack += 1 end
	end
	local stats = {
		{ color = DIFF.Green.color,           icon = "●",  label = tostring(green)  .. " Green" },
		{ color = DIFF.Blue.color,            icon = "■",  label = tostring(blue)   .. " Blue"  },
		{ color = DIFF.Black.color,           icon = "◆",  label = tostring(black)  .. " Black" },
		{ color = DIFF["Double Black"].color, icon = "◆◆", label = tostring(dblack) .. " Dbl Black" },
		{ color = LIFT_COLOR,                 icon = "🚡", label = tostring(#lifts) .. " Lifts" },
	}
	local statBar = box(parent, CANVAS_W, 32, 0, 0, Color3.fromRGB(14, 18, 30), 0)
	corner(statBar, 10)
	local x = 12
	for _, s in ipairs(stats) do
		local chip = box(statBar, 120, 22, x, 5, s.color, 0.15)
		corner(chip, 6)
		local symB = box(chip, 20, 22, 0, 0, s.color, 0)
		corner(symB, 6)
		local symT = text(symB, s.icon, 20, 22, 0, 0, Color3.new(1,1,1), 10, true)
		symT.TextXAlignment = Enum.TextXAlignment.Center
		local labelT = text(chip, s.label, 96, 22, 22, 0, Color3.new(1,1,1), 11, true)
		labelT.TextXAlignment = Enum.TextXAlignment.Left
		x = x + 128
	end
	return statBar
end

local PANEL_W = CANVAS_W + 20
local PANEL_H = CANVAS_H + 110

local function buildMap(data)
	Bounds = data.Bounds or { MinX = -500, MinZ = -500, MaxX = 500, MaxZ = 500 }
	recalcProjection()
	if MapGui then MapGui:Destroy() end
	MapGui = Instance.new("ScreenGui")
	MapGui.Name             = "ResortMapGui"
	MapGui.ResetOnSpawn     = false
	MapGui.DisplayOrder     = 25
	MapGui.ZIndexBehavior   = Enum.ZIndexBehavior.Sibling
	MapGui.Enabled          = false
	MapGui.Parent           = PGui
	local overlay = box(MapGui, 6000, 6000, -3000, -3000, Color3.fromRGB(0, 5, 15), 0.55, 1)
	local panel = Instance.new("Frame")
	panel.Name            = "MapPanel"
	panel.Size            = UDim2.fromOffset(PANEL_W, PANEL_H)
	panel.AnchorPoint     = Vector2.new(0.5, 0.5)
	panel.Position        = UDim2.fromScale(0.5, 0.5)
	panel.BackgroundColor3 = Color3.fromRGB(12, 16, 28)
	panel.BorderSizePixel = 0
	panel.ZIndex          = 2
	panel.Parent          = MapGui
	corner(panel, 14)
	stroke(panel, Color3.fromRGB(80, 120, 200), 2)
	local header = box(panel, PANEL_W, 44, 0, 0, Color3.fromRGB(18, 25, 48), 0)
	corner(header, 14)
	local titleText = text(header, "🏔️  RESORT TRAIL MAP", PANEL_W - 60, 44, 14, 0, Color3.new(1,1,1), 20, true, 3)
	local bw = math.floor(Bounds.MaxX - Bounds.MinX)
	local bh = math.floor(Bounds.MaxZ - Bounds.MinZ)
	local subtitleStr = string.format(
		"%d Slopes  ·  %d Lifts  ·  %d Facilities  ·  [M] to close",
		#(data.Slopes or {}), #(data.Lifts or {}), #(data.Buildings or {})
	)
	local subtitle = text(header, subtitleStr, PANEL_W - 60, 18, 14, 26, Color3.fromRGB(140, 170, 230), 11, false, 3)
	local closeBtn = Instance.new("TextButton")
	closeBtn.Size               = UDim2.fromOffset(36, 36)
	closeBtn.Position           = UDim2.fromOffset(PANEL_W - 44, 4)
	closeBtn.BackgroundColor3   = Color3.fromRGB(180, 40, 40)
	closeBtn.BackgroundTransparency = 0.25
	closeBtn.Text               = "✕"
	closeBtn.TextColor3         = Color3.new(1,1,1)
	closeBtn.Font               = Enum.Font.GothamBold
	closeBtn.TextSize           = 16
	closeBtn.ZIndex             = 5
	closeBtn.Parent             = header
	corner(closeBtn, 8)
	closeBtn.MouseButton1Click:Connect(function() closeMap() end)
	local statsBar = buildStatsBar(panel, data)
	statsBar.Position = UDim2.fromOffset(10, 48)
	statsBar.Size = UDim2.fromOffset(PANEL_W - 20, 32)
	local canvas = box(panel, CANVAS_W, CANVAS_H, 10, 84, Color3.fromRGB(60, 100, 50), 0, 3)
	canvas.ClipsDescendants = true
	corner(canvas, 8)
	stroke(canvas, Color3.fromRGB(60, 80, 120), 1.5)
	task.spawn(function()
		renderTerrain(canvas, data.Terrain)
		if data.Slopes and #data.Slopes > 0 then
			renderSlopes(canvas, data.Slopes)
		else
			local hint = text(canvas,
				"No slopes placed yet.\nBuild some runs to see them here!",
				CANVAS_W, 60, 0, CANVAS_H / 2 - 30,
				Color3.fromRGB(220, 240, 255), 16, true, 8)
			hint.TextXAlignment = Enum.TextXAlignment.Center
		end
		if data.Lifts and #data.Lifts > 0 then renderLifts(canvas, data.Lifts) end
		if data.Buildings and #data.Buildings > 0 then renderBuildings(canvas, data.Buildings) end
		local dot, yLabel = makePlayerDot(canvas)
		youLabel = yLabel
		updatePlayerDot()
		buildLegend(canvas)
		buildCompass(canvas)
	end)
	local footer = box(panel, PANEL_W, 18, 0, PANEL_H - 18, Color3.fromRGB(10, 14, 26), 0)
	corner(footer, 14)
	local footerText = text(footer,
		string.format("World size: %d × %d studs", bw, bh),
		PANEL_W, 18, 0, 0, Color3.fromRGB(80, 100, 140), 10, false, 3)
	footerText.TextXAlignment = Enum.TextXAlignment.Center
end

local function openMap()
	if isOpen or isLoading then return end
	isLoading = true
	local loadGui = Instance.new("ScreenGui")
	loadGui.DisplayOrder = 24
	loadGui.Parent = PGui
	local loadBg = box(loadGui, 260, 64, 0, 0, Color3.fromRGB(10, 15, 30), 0.05)
	loadBg.AnchorPoint = Vector2.new(0.5, 0.5)
	loadBg.Position = UDim2.fromScale(0.5, 0.5)
	corner(loadBg, 12)
	stroke(loadBg, Color3.fromRGB(100, 150, 255), 1.5)
	local lt = text(loadBg, "🏔️  Loading Resort Map...", 260, 64, 0, 0, Color3.new(1,1,1), 15, true)
	lt.TextXAlignment = Enum.TextXAlignment.Center
	task.spawn(function()
		local ok, data = pcall(function() return MapRemote:InvokeServer() end)
		loadGui:Destroy()
		if not ok or not data then
			isLoading = false
			warn("[MapClient] Map data failed: " .. tostring(data))
			local eg = Instance.new("ScreenGui") eg.Parent = PGui
			local ef = box(eg, 320, 54, 0, 0, Color3.fromRGB(120, 20, 20), 0.05)
			ef.AnchorPoint = Vector2.new(0.5,0.5) ef.Position = UDim2.fromScale(0.5,0.5)
			corner(ef, 10)
			text(ef, "⚠️  Map data unavailable — place some runs first!", 320, 54, 0, 0, Color3.new(1,1,1), 13, true).TextXAlignment = Enum.TextXAlignment.Center
			task.delay(3.5, function() eg:Destroy() end)
			return
		end
		buildMap(data)
		MapGui.Enabled = true
		isOpen    = true
		isLoading = false
		local mp = MapGui.MapPanel
		mp.Position = UDim2.new(0.5, 0, 1.6, 0)
		TweenService:Create(mp,
			TweenInfo.new(0.45, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
			Position = UDim2.fromScale(0.5, 0.5)
		}):Play()
	end)
end

function closeMap()
	if not isOpen then return end
	isOpen = false
	if not MapGui then return end
	local mp = MapGui:FindFirstChild("MapPanel")
	if mp then
		TweenService:Create(mp, TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
			Position = UDim2.new(0.5, 0, 1.6, 0)
		}):Play()
	end
	task.delay(0.35, function() if MapGui then MapGui.Enabled = false end end)
end

UserInputService.InputBegan:Connect(function(input, processed)
	if processed then return end
	if input.KeyCode == Enum.KeyCode.M then
		if isOpen then closeMap() else openMap() end
	elseif input.KeyCode == Enum.KeyCode.Escape and isOpen then
		closeMap()
	end
end)

RunService.Heartbeat:Connect(function()
	if isOpen and PlayerDot then updatePlayerDot() end
end)

task.spawn(function()
	task.wait(4)
	for _, gui in ipairs(PGui:GetChildren()) do
		local btn = gui:FindFirstChild("MapButton", true)
		if btn and (btn:IsA("TextButton") or btn:IsA("ImageButton")) then
			btn.MouseButton1Click:Connect(function()
				if isOpen then closeMap() else openMap() end
			end)
		end
	end
end)

print("[MapClient] Online — Press M to open resort map.")
