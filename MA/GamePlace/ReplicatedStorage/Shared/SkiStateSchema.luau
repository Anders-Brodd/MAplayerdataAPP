local SkiStateSchema = {}

local DEFAULT_FORWARD = Vector3.new(0, 0, -1)

local function clamp01(value)
	return math.clamp(value or 0, 0, 1)
end

local function inverseLerp(a, b, value)
	if b == a then
		return 0
	end
	return math.clamp((value - a) / (b - a), 0, 1)
end

local function safeUnit(vector, fallback)
	if typeof(vector) == "Vector3" and vector.Magnitude > 1e-4 then
		return vector.Unit
	end
	return fallback or DEFAULT_FORWARD
end

local function signedTurn(steer, turnRate)
	if math.abs(turnRate) > 1e-3 then
		return turnRate
	end
	return steer
end

local function resolveState(data, metrics)
	if data.current == "crashed" then
		return "Crash"
	end
	if data.current == "recovering" then
		return "Recovering"
	end
	if data.ridingLift then
		return "RidingLift"
	end
	if metrics.airborne then
		return "Airborne"
	end
	if data.pushing and metrics.groundedAlpha > 0.45 and metrics.speed < 30 then
		return "PolePush"
	end
	if data.wantsBootWalk then
		if metrics.speed < 1.2 then
			return "SkiIdle"
		end
		if metrics.speed < 6 then
			return "BootWalk"
		end
		if metrics.speed < 16 then
			return "BootRun"
		end
	end
	if metrics.brakeAlpha > 0.2 or (metrics.stopAlpha > 0.72 and metrics.speed < 14) then
		return "BrakeStop"
	end
	if metrics.carveAlpha > 0.25 then
		return "Carve"
	end
	if metrics.speed > 0.9 and metrics.groundedAlpha > 0.2 then
		return "SkiGlide"
	end
	if data.wantsBootWalk then
		return "BootWalk"
	end
	if data.current == "off" then
		return "Off"
	end
	return "SkiIdle"
end

function SkiStateSchema.Build(input)
	local data = input or {}
	local normal = safeUnit(data.normal, Vector3.yAxis)
	local forward = safeUnit(data.forward, DEFAULT_FORWARD)
	local planarVelocity = data.planarVelocity
	if typeof(planarVelocity) ~= "Vector3" then
		local rawVelocity = (typeof(data.velocity) == "Vector3") and data.velocity or Vector3.zero
		planarVelocity = rawVelocity - normal * rawVelocity:Dot(normal)
	end
	local planarSpeed = (typeof(data.speed) == "number") and math.max(data.speed, 0) or planarVelocity.Magnitude
	local velocity = (typeof(data.velocity) == "Vector3") and data.velocity or planarVelocity

	local groundedAlpha = clamp01(data.groundedAlpha)
	local grounded = (data.grounded ~= false) and groundedAlpha > 0.18
	local airborne = (data.airborne == true) or (not grounded and groundedAlpha < 0.32)

	local steer = math.clamp(data.steer or 0, -1, 1)
	local turnRate = data.turnRate or 0
	local turnSign = math.sign(signedTurn(steer, turnRate))

	local turnAlpha = clamp01(math.max(
		math.abs(steer) * inverseLerp(3.5, 55, planarSpeed),
		inverseLerp(0.4, 6, math.abs(turnRate))
	))
	local slipAmount = clamp01(data.slipAmount)
	local carveAlpha = clamp01(math.max(turnAlpha * inverseLerp(6, 90, planarSpeed), slipAmount * 0.7))
	local brakeAlpha = clamp01(data.brakeAlpha)
	local lowSpeedBrakeAlpha = clamp01(data.lowSpeedBrakeAlpha or brakeAlpha)
	local highSpeedSlideAlpha = clamp01(data.highSpeedSlideAlpha)
	local pushAlpha = clamp01(data.pushAlpha)
	local pushCyclePhase = clamp01(data.pushCyclePhase)
	local pushCycleDuration = tonumber(data.pushCycleDuration) or 0
	local stopAlpha = clamp01(data.stopAlpha)

	local right = safeUnit(forward:Cross(normal), Vector3.xAxis)
	forward = safeUnit(normal:Cross(right), forward)

	local metrics = {
		speed = planarSpeed,
		groundedAlpha = groundedAlpha,
		airborne = airborne,
		turnAlpha = turnAlpha,
		carveAlpha = carveAlpha,
		brakeAlpha = brakeAlpha,
		lowSpeedBrakeAlpha = lowSpeedBrakeAlpha,
		highSpeedSlideAlpha = highSpeedSlideAlpha,
		pushAlpha = pushAlpha,
		pushCyclePhase = pushCyclePhase,
		pushCycleDuration = pushCycleDuration,
		stopAlpha = stopAlpha,
	}

	local stateName = resolveState(data, metrics)
	local leanSign = (turnSign == 0) and math.sign(steer) or turnSign
	local leanAmount = clamp01(math.max(carveAlpha, brakeAlpha * 0.6) * groundedAlpha)
	local leanAngle = math.rad(40) * leanAmount * leanSign

	return {
		state = stateName,
		debugLabel = stateName,
		current = data.current or "off",
		velocity = velocity,
		planarVelocity = planarVelocity,
		speed = planarSpeed,
		normal = normal,
		up = normal,
		forward = forward,
		right = right,
		grounded = grounded,
		groundedAlpha = groundedAlpha,
		airborne = airborne,
		steer = steer,
		turnRate = turnRate,
		turnSign = turnSign,
		turnAlpha = turnAlpha,
		carveAlpha = carveAlpha,
		slipAmount = slipAmount,
		brakeAlpha = brakeAlpha,
		lowSpeedBrakeAlpha = lowSpeedBrakeAlpha,
		highSpeedSlideAlpha = highSpeedSlideAlpha,
		pushAlpha = pushAlpha,
		stopAlpha = stopAlpha,
		pushing = data.pushing == true,
		stopSlideSign = (data.stopSlideSign == -1 and -1) or 1,
		leanAngle = leanAngle,
		leanAmount = leanAmount,
		ridingLift = data.ridingLift == true,
		wantsBootWalk = data.wantsBootWalk == true,
	}
end

return SkiStateSchema
