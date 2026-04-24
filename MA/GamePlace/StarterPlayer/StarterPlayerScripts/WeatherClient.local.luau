--[[
	🌨️ WEATHER CLIENT V3.0 (No Trails + Realistic)
	StarterPlayerScripts/WeatherClient
]]

local Lighting = game:GetService("Lighting")
local Workspace = game:GetService("Workspace")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local SoundService = game:GetService("SoundService")

local Player = Players.LocalPlayer
local Camera = Workspace.CurrentCamera
local GraphicsProfile = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("GraphicsProfile"))

local CONFIG = {
	SnowTexture = "rbxassetid://301261210", 
	MaxSnowParticles = 5000, -- High count for density

	-- Sound IDs
	WindSoundId = "", 
	BlizzardSoundId = "rbxassetid://4175285709",

	FadeSpeed = 2.0,
}

-- Audio Setup (Same as before)
local AmbientGroup = Instance.new("SoundGroup", SoundService)
AmbientGroup.Name = "WeatherFX"
local WindSound = Instance.new("Sound", Workspace); WindSound.SoundId = CONFIG.WindSoundId; WindSound.Looped = true; WindSound.Volume = 0; WindSound.Parent = AmbientGroup; if WindSound.SoundId ~= "" then WindSound:Play() end
local BlizzardSound = Instance.new("Sound", Workspace); BlizzardSound.SoundId = CONFIG.BlizzardSoundId; BlizzardSound.Looped = true; BlizzardSound.Volume = 0; BlizzardSound.Parent = AmbientGroup; BlizzardSound:Play()

-- // ❄️ PARTICLE SETUP (FIXED) //
local SnowPart = Instance.new("Part")
SnowPart.Name = "ClientSnowBox"
SnowPart.Size = Vector3.new(250, 1, 250) -- Large area so snow covers the whole viewport
SnowPart.Transparency = 1
SnowPart.CanCollide = false
SnowPart.CanQuery = false
SnowPart.CanTouch = false
SnowPart.Anchored = true
SnowPart.Parent = Workspace

local Emitter = Instance.new("ParticleEmitter")
Emitter.Name = "Snow"
Emitter.Texture = CONFIG.SnowTexture
Emitter.Color = ColorSequence.new(Color3.new(1,1,1))
Emitter.Size = NumberSequence.new({NumberSequenceKeypoint.new(0, 0.4), NumberSequenceKeypoint.new(1, 0.2)})
Emitter.Transparency = NumberSequence.new({NumberSequenceKeypoint.new(0, 0.2), NumberSequenceKeypoint.new(1, 1)})
Emitter.Lifetime = NumberRange.new(3, 5)
Emitter.Speed = NumberRange.new(8, 16)
Emitter.EmissionDirection = Enum.NormalId.Bottom -- Emit downward so snow falls naturally
Emitter.SpreadAngle = Vector2.new(35, 35) -- Moderate spread for natural drift
Emitter.Rate = 0
Emitter.LockedToPart = true
Emitter.Parent = SnowPart

-- // LOGIC //
local currentRate = 0
local targetRate = 0
local currentWind = 0
local targetWind = 0
local smoothedFPS = 60
local targetTurbulence = 0.1
local currentTurbulence = 0.1
local targetWindGust = 0.1
local currentWindGust = 0.1

local function IsWeatherEnabled()
	return Player:GetAttribute("Settings_Weather") ~= false
end

local function AreWeatherVisualsEnabled()
	return IsWeatherEnabled() and Player:GetAttribute("Settings_Particles") ~= false
end

local function GetAdaptiveScale(dt)
	if not GraphicsProfile.IsAdaptiveParticlesEnabled(Player) then
		return 1
	end
	local frameFPS = (dt > 0) and (1 / dt) or 60
	smoothedFPS = smoothedFPS + (frameFPS - smoothedFPS) * 0.1
	if smoothedFPS >= 58 then return 1 end
	if smoothedFPS <= 28 then return 0.35 end
	return math.clamp((smoothedFPS - 28) / 30, 0.35, 1)
end

local function ApplyEmitterStyle()
	local realistic = GraphicsProfile.IsRealisticParticlesEnabled(Player)
	if realistic then
		Emitter.Size = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.25),
			NumberSequenceKeypoint.new(0.45, 0.42),
			NumberSequenceKeypoint.new(1, 0.12),
		})
		Emitter.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.12),
			NumberSequenceKeypoint.new(0.65, 0.42),
			NumberSequenceKeypoint.new(1, 1),
		})
		Emitter.Lifetime = NumberRange.new(3, 5)
		Emitter.Speed = NumberRange.new(6, 14)
		Emitter.Drag = 0.9
		Emitter.Rotation = NumberRange.new(0, 360)
		Emitter.RotSpeed = NumberRange.new(-45, 45)
		Emitter.LightInfluence = 0.2
		Emitter.ZOffset = 0.08
	else
		Emitter.Size = NumberSequence.new({NumberSequenceKeypoint.new(0, 0.4), NumberSequenceKeypoint.new(1, 0.2)})
		Emitter.Transparency = NumberSequence.new({NumberSequenceKeypoint.new(0, 0.2), NumberSequenceKeypoint.new(1, 1)})
		Emitter.Lifetime = NumberRange.new(3, 5)
		Emitter.Speed = NumberRange.new(8, 16)
		Emitter.Drag = 0
		Emitter.Rotation = NumberRange.new(0, 0)
		Emitter.RotSpeed = NumberRange.new(0, 0)
		Emitter.LightInfluence = 0
		Emitter.ZOffset = 0
	end
end

local function UpdateTargets()
	local weatherEnabled = IsWeatherEnabled()
	local visualsEnabled = AreWeatherVisualsEnabled()
	local qualityScale = GraphicsProfile.GetWeatherScale(Player)
	local particleScale = GraphicsProfile.GetParticleScale(Player) * GraphicsProfile.GetParticleDensityScale(Player)
	targetRate = visualsEnabled and ((Lighting:GetAttribute("SnowRate") or 0) * qualityScale * particleScale) or 0
	targetWind = weatherEnabled and (Lighting:GetAttribute("WindSpeed") or 5) or 0
	targetTurbulence = weatherEnabled and (tonumber(Lighting:GetAttribute("SnowTurbulence")) or 0.1) or 0
	targetWindGust = weatherEnabled and (tonumber(Lighting:GetAttribute("WindGust")) or 0.1) or 0
	ApplyEmitterStyle()
end

Lighting:GetAttributeChangedSignal("SnowRate"):Connect(UpdateTargets)
Lighting:GetAttributeChangedSignal("WindSpeed"):Connect(UpdateTargets)
Lighting:GetAttributeChangedSignal("SnowTurbulence"):Connect(UpdateTargets)
Lighting:GetAttributeChangedSignal("WindGust"):Connect(UpdateTargets)
Lighting:GetAttributeChangedSignal("Weather"):Connect(UpdateTargets)
UpdateTargets()

RunService.RenderStepped:Connect(function(dt)
	if not Camera then return end

	-- Check if camera is under a roof (magic carpet, building, etc.) and suppress snow
	local roofParams = RaycastParams.new()
	roofParams.FilterType = Enum.RaycastFilterType.Exclude
	roofParams.FilterDescendantsInstances = {Player.Character, SnowPart}
	local roofHit = Workspace:Raycast(Camera.CFrame.Position, Vector3.new(0, 50, 0), roofParams)
	local underRoof = roofHit ~= nil

	-- Position snow above the camera, but clamp below any detected roof
	local snowHeight = 40
	if underRoof then
		local roofY = roofHit.Position.Y
		local camY = Camera.CFrame.Position.Y
		local gap = roofY - camY
		if gap < snowHeight then
			snowHeight = math.max(2, gap - 2)
		end
	end
	SnowPart.CFrame = CFrame.new(Camera.CFrame.Position + Vector3.new(0, snowHeight, 0))

	-- Smooth Transitions
	local speed = dt * CONFIG.FadeSpeed
	currentRate = currentRate + (targetRate - currentRate) * speed
	currentWind = currentWind + (targetWind - currentWind) * speed
	currentTurbulence = currentTurbulence + (targetTurbulence - currentTurbulence) * speed
	currentWindGust = currentWindGust + (targetWindGust - currentWindGust) * speed

	local weatherEnabled = IsWeatherEnabled()
	local visualsEnabled = AreWeatherVisualsEnabled()
	local adaptiveScale = GetAdaptiveScale(dt)
	local effectiveRate = (visualsEnabled and not underRoof) and (currentRate * adaptiveScale) or 0
	Emitter.Rate = math.min(CONFIG.MaxSnowParticles, effectiveRate)

	-- Gravity pushes down, Wind pushes X/Z
	-- Since LockedToPart is true, this acceleration is relative to the world
	local weatherScale = weatherEnabled and GraphicsProfile.GetWeatherScale(Player) or 0
	local t = os.clock()
	local gustX = math.sin(t * 0.85) * currentWind * currentWindGust * 0.35
	local gustZ = math.cos(t * 0.62 + 1.9) * currentWind * currentWindGust * 0.25
	local turbulenceY = math.sin(t * 1.4 + 0.7) * (2.5 * currentTurbulence)
	Emitter.Acceleration = Vector3.new(
		(currentWind * weatherScale) + gustX,
		-25 + turbulenceY,
		(currentWind * 0.5 * weatherScale) + gustZ
	)

	local weatherState = tostring(Lighting:GetAttribute("Weather") or "Clear")
	if weatherState == "Blizzard" then
		Emitter.Color = ColorSequence.new(Color3.fromRGB(230, 238, 252), Color3.fromRGB(205, 218, 238))
	elseif weatherState == "HeavySnow" then
		Emitter.Color = ColorSequence.new(Color3.fromRGB(236, 243, 255), Color3.fromRGB(220, 232, 246))
	else
		Emitter.Color = ColorSequence.new(Color3.new(1, 1, 1))
	end

	-- Audio Volume
	local windVol = weatherEnabled and math.clamp(currentWind / 80, 0, 1.5) or 0
	WindSound.Volume = WindSound.Volume + (windVol - WindSound.Volume) * speed

	local blizVol = 0
	if weatherEnabled and currentRate > 1000 then blizVol = math.clamp(currentRate / 3000, 0, 1.2) end
	BlizzardSound.Volume = BlizzardSound.Volume + (blizVol - BlizzardSound.Volume) * speed
end)

Player:GetAttributeChangedSignal("Settings_Weather"):Connect(UpdateTargets)
Player:GetAttributeChangedSignal("Settings_Particles"):Connect(UpdateTargets)
Player:GetAttributeChangedSignal("Settings_RealisticParticles"):Connect(UpdateTargets)
Player:GetAttributeChangedSignal("Settings_AdaptiveParticles"):Connect(UpdateTargets)
Player:GetAttributeChangedSignal("Settings_ParticleDensity"):Connect(UpdateTargets)
print("WeatherClient Online")