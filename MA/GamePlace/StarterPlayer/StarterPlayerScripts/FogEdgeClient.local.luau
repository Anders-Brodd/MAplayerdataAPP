local Lighting = game:GetService("Lighting")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Player = Players.LocalPlayer
local GraphicsProfile = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("GraphicsProfile"))

-- Smooth interpolation state
local currentFogEnd = Lighting.FogEnd
local currentFogStart = Lighting.FogStart
local LERP_SPEED = 2.5

RunService.RenderStepped:Connect(function(dt)
	-- Read the server-intended fog target from the BaseFogEnd attribute
	local baseFogEnd = tonumber(Lighting:GetAttribute("BaseFogEnd")) or Lighting.FogEnd
	if baseFogEnd <= 0 then
		return
	end

	if not GraphicsProfile.IsFogEdgeBlendEnabled(Player) then
		-- Fog blending off: let server values pass through, reset FogStart to 0
		currentFogEnd = baseFogEnd
		currentFogStart = 0
		Lighting.FogStart = 0
		return
	end

	-- Compute client-scaled fog values
	local endScale = GraphicsProfile.GetFogEndScale(Player)
	local startRatio = GraphicsProfile.GetFogStartRatio(Player)

	local targetFogEnd = baseFogEnd * endScale
	local targetFogStart = targetFogEnd * startRatio

	-- Smooth interpolation so fog transitions feel natural
	local alpha = math.clamp(dt * LERP_SPEED, 0, 1)
	currentFogEnd = currentFogEnd + (targetFogEnd - currentFogEnd) * alpha
	currentFogStart = currentFogStart + (targetFogStart - currentFogStart) * alpha

	Lighting.FogEnd = math.max(1, math.floor(currentFogEnd))
	Lighting.FogStart = math.max(0, math.min(currentFogEnd - 1, math.floor(currentFogStart)))
end)
