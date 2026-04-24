local SkiPhysicsModel = {}

local function inverseLerp(a, b, value)
	if b == a then
		return 0
	end
	return math.clamp((value - a) / (b - a), 0, 1)
end

local function lerp(a, b, t)
	return a + (b - a) * math.clamp(t, 0, 1)
end

function SkiPhysicsModel.GetPushImpulse(config, speed)
	local pushMaxSpeed = math.max(0.01, tonumber(config.PushMaxSpeed) or 25)
	local normalized = 1 - inverseLerp(0, pushMaxSpeed, speed or 0)
	local ramp = (0.30 + (normalized ^ 0.95) * 0.70)
	local lowSpeedPop = lerp(1.2, 1.0, inverseLerp(0, 8, speed or 0))
	local base = tonumber(config.PushForce) or 12
	local flatBoost = tonumber(config.PushFlatBoost) or 1
	return base * ramp * flatBoost * lowSpeedPop
end

function SkiPhysicsModel.GetFrictionProfile(config, speed, steer, braking)
	local absSteer = math.abs(steer or 0)
	local edgeAlpha = absSteer * inverseLerp(3, 55, speed or 0)
	edgeAlpha = math.clamp(edgeAlpha, 0, 1)

	local glide = tonumber(config.Friction_Glide) or 0.04
	local carve = tonumber(config.Friction_Carve) or 0.11
	local skid = tonumber(config.Friction_Skid) or 0.22
	local brake = tonumber(config.Friction_Brake) or 0.95
	local carveSide = tonumber(config.Friction_CarveSide) or skid

	local glideFriction = lerp(glide, carve, edgeAlpha)
	local sideFriction = lerp(skid, carveSide, edgeAlpha)

	if braking then
		glideFriction = lerp(glideFriction, brake, 0.9)
		sideFriction = lerp(sideFriction, brake, 0.92)
	else
		sideFriction *= (1 + (edgeAlpha * 0.18))
	end

	local flatAssist = lerp(0.62, 1.0, inverseLerp(0, 16, speed or 0))
	if not braking then
		glideFriction *= flatAssist
	end

	if (speed or 0) < 4 and not braking then
		sideFriction *= 0.85
	end

	return glideFriction, sideFriction, edgeAlpha
end

function SkiPhysicsModel.GetBrakeDeceleration(config, planarSpeed, brakeAlpha)
	local speed = math.max(planarSpeed or 0, 0)
	local alpha = math.clamp(brakeAlpha or 1, 0, 1)
	local base = tonumber(config.BrakeDeceleration) or 36
	local speedFactor = tonumber(config.BrakeSpeedFactor) or 0.18
	local lowSpeedBoost = tonumber(config.BrakeLowSpeedBoost) or 1.3
	local boost = lerp(lowSpeedBoost, 1.0, inverseLerp(0, 15, speed))
	return (base + (speed * speedFactor)) * boost * alpha
end

function SkiPhysicsModel.GetDragMultiplier(config, speed, braking, edgeAlpha)
	local terminal = tonumber(config.TerminalVelocity) or 170
	local highSpeedAlpha = inverseLerp(65, terminal, speed or 0)
	local mult = 1 + (math.clamp(edgeAlpha or 0, 0, 1) * 0.25) + (highSpeedAlpha * 0.2)
	if braking then
		mult += 0.3
	end
	return mult
end

function SkiPhysicsModel.GetTurnRate(config, speed, steer, gravity)
	local input = math.clamp(steer or 0, -1, 1)
	if math.abs(input) < 1e-3 then
		return 0
	end

	local v = math.max(speed or 0, 0)
	local highThreshold = tonumber(config.HighSpeedThreshold) or 80
	local uTurnAssistSpeed = tonumber(config.UTurnAssistSpeed) or 28
	local lowRate = tonumber(config.TurnSpeed_Base) or 3.5
	local highRate = tonumber(config.TurnSpeed_High) or 1.8
	local uTurnRate = tonumber(config.TurnSpeed_Uturn) or 7.0

	local speedBlend = inverseLerp(0, highThreshold, v)
	local rate = lerp(lowRate, highRate, speedBlend)
	if v < uTurnAssistSpeed then
		local uAssist = 1 - inverseLerp(0, uTurnAssistSpeed, v)
		rate = lerp(rate, uTurnRate, uAssist)
	end

	local gravityFactor = math.sqrt(math.max(gravity or workspace.Gravity or 196.2, 0.01) / 196.2)
	local inputCurve = 0.28 + (math.abs(input) ^ 0.95) * 0.72
	local signed = rate * gravityFactor * inputCurve * math.sign(input)
	return signed
end

function SkiPhysicsModel.GetStopHoldForce(config, planarSpeed, pushing, braking)
	if pushing then
		return 0
	end

	local speed = math.max(planarSpeed or 0, 0)
	local staticMax = tonumber(config.StaticHoldMaxSpeed) or 4.5
	local baseHold = tonumber(config.StaticHoldForce) or 12

	if speed >= staticMax then
		return 0
	end

	local holdAlpha = 1 - inverseLerp(0, staticMax, speed)
	local holdForce = baseHold * (holdAlpha ^ 1.5)
	if braking then
		holdForce *= 1.65
	end

	return holdForce
end

return SkiPhysicsModel
