local SkiMistVFX = {}
SkiMistVFX.__index = SkiMistVFX

local function safeUnit(vector, fallback)
	if typeof(vector) == "Vector3" and vector.Magnitude > 1e-4 then
		return vector.Unit
	end
	return fallback or Vector3.new(0, 1, 0)
end

local function clamp01(value)
	return math.clamp(value or 0, 0, 1)
end

local function newMistEmitter(parent)
	local emitter = Instance.new("ParticleEmitter")
	emitter.Name = "SkiMist"
	emitter.Texture = "rbxasset://textures/particles/smoke_main.dds"
	emitter.Lifetime = NumberRange.new(0.28, 0.85)
	emitter.Speed = NumberRange.new(5, 13)
	emitter.Rate = 0
	emitter.Drag = 2.6
	emitter.SpreadAngle = Vector2.new(10, 18)
	emitter.Rotation = NumberRange.new(0, 360)
	emitter.RotSpeed = NumberRange.new(-110, 110)
	emitter.Acceleration = Vector3.new(0, -5, 0)
	emitter.EmissionDirection = Enum.NormalId.Back
	emitter.Parent = parent
	return emitter
end

local function newBrakeEmitter(parent)
	local emitter = Instance.new("ParticleEmitter")
	emitter.Name = "SkiBrakeMist"
	emitter.Texture = "rbxasset://textures/particles/smoke_main.dds"
	emitter.Lifetime = NumberRange.new(0.2, 0.55)
	emitter.Speed = NumberRange.new(8, 17)
	emitter.Rate = 0
	emitter.Drag = 2.2
	emitter.SpreadAngle = Vector2.new(20, 26)
	emitter.Rotation = NumberRange.new(0, 360)
	emitter.RotSpeed = NumberRange.new(-180, 180)
	emitter.Acceleration = Vector3.new(0, -7, 0)
	emitter.EmissionDirection = Enum.NormalId.Back
	emitter.Parent = parent
	return emitter
end

function SkiMistVFX.new(rootPart, player, graphicsProfile)
	if not rootPart then
		return nil
	end

	local self = setmetatable({}, SkiMistVFX)
	self.RootPart = rootPart
	self.Player = player
	self.GraphicsProfile = graphicsProfile
	self.Emitters = {}
	self.Side = {}

	local function makeSide(name, x)
		local mistAtt = Instance.new("Attachment")
		mistAtt.Name = "SkiMistAtt_" .. name
		mistAtt.Position = Vector3.new(x, -2.55, 0.12)
		mistAtt.Parent = rootPart

		local brakeAtt = Instance.new("Attachment")
		brakeAtt.Name = "SkiBrakeAtt_" .. name
		brakeAtt.Position = Vector3.new(x * 1.05, -2.58, -0.2)
		brakeAtt.Parent = rootPart

		local mist = newMistEmitter(mistAtt)
		local brake = newBrakeEmitter(brakeAtt)
		table.insert(self.Emitters, mist)
		table.insert(self.Emitters, brake)

		self.Side[name] = {
			Sign = math.sign(x),
			MistAttachment = mistAtt,
			BrakeAttachment = brakeAtt,
			Mist = mist,
			Brake = brake,
		}
	end

	makeSide("Left", -0.95)
	makeSide("Right", 0.95)
	self:RefreshStyle()
	return self
end

function SkiMistVFX:RefreshStyle()
	local realistic = true
	if self.GraphicsProfile and self.Player then
		realistic = self.GraphicsProfile.IsRealisticParticlesEnabled(self.Player)
	end

	for _, side in pairs(self.Side) do
		if realistic then
			side.Mist.Size = NumberSequence.new({
				NumberSequenceKeypoint.new(0, 0.24),
				NumberSequenceKeypoint.new(0.35, 0.85),
				NumberSequenceKeypoint.new(1, 0.12),
			})
			side.Mist.Transparency = NumberSequence.new({
				NumberSequenceKeypoint.new(0, 0.12),
				NumberSequenceKeypoint.new(0.55, 0.52),
				NumberSequenceKeypoint.new(1, 1),
			})
			side.Brake.Size = NumberSequence.new({
				NumberSequenceKeypoint.new(0, 0.32),
				NumberSequenceKeypoint.new(0.4, 0.95),
				NumberSequenceKeypoint.new(1, 0.12),
			})
			side.Brake.Transparency = NumberSequence.new({
				NumberSequenceKeypoint.new(0, 0.18),
				NumberSequenceKeypoint.new(0.45, 0.6),
				NumberSequenceKeypoint.new(1, 1),
			})
		else
			side.Mist.Size = NumberSequence.new({
				NumberSequenceKeypoint.new(0, 0.45),
				NumberSequenceKeypoint.new(1, 1.55),
			})
			side.Mist.Transparency = NumberSequence.new({
				NumberSequenceKeypoint.new(0, 0.45),
				NumberSequenceKeypoint.new(1, 1),
			})
			side.Brake.Size = NumberSequence.new({
				NumberSequenceKeypoint.new(0, 0.5),
				NumberSequenceKeypoint.new(1, 1.75),
			})
			side.Brake.Transparency = NumberSequence.new({
				NumberSequenceKeypoint.new(0, 0.42),
				NumberSequenceKeypoint.new(1, 1),
			})
		end
	end
end

local function setAttachmentDirection(rootPart, attachment, worldDirection, worldUp)
	if not rootPart or not attachment then
		return
	end
	local worldPos = attachment.WorldPosition
	local desired = CFrame.lookAt(worldPos, worldPos + worldDirection, worldUp)
	attachment.CFrame = rootPart.CFrame:ToObjectSpace(desired)
end

function SkiMistVFX:Update(state, dt, densityScale, adaptiveScale)
	if not self.RootPart or not self.RootPart.Parent then
		return
	end

	state = state or {}
	local speed = math.max(state.speed or 0, 0)
	local groundedAlpha = clamp01(state.groundedAlpha)
	if state.airborne == true then
		groundedAlpha *= 0.2
	end
	local steer = math.clamp(state.steer or 0, -1, 1)
	local turnSign = state.turnSign or math.sign(steer)
	local turnAlpha = clamp01(state.turnAlpha or state.carveAlpha or 0)
	local brakeAlpha = clamp01(state.brakeAlpha)
	local lowSpeedBrakeAlpha = clamp01(state.lowSpeedBrakeAlpha or brakeAlpha)
	local highSpeedSlideAlpha = clamp01(state.highSpeedSlideAlpha)
	local stopAlpha = clamp01(state.stopAlpha)
	local pushAlpha = clamp01(state.pushAlpha)

	local normal = safeUnit(state.normal, self.RootPart.CFrame.UpVector)
	local planarVelocity = state.planarVelocity
	if typeof(planarVelocity) ~= "Vector3" then
		planarVelocity = Vector3.new(self.RootPart.AssemblyLinearVelocity.X, 0, self.RootPart.AssemblyLinearVelocity.Z)
	end
	local forward = safeUnit(state.forward, safeUnit(planarVelocity, self.RootPart.CFrame.LookVector))
	local right = safeUnit(forward:Cross(normal), self.RootPart.CFrame.RightVector)
	forward = safeUnit(normal:Cross(right), forward)

	local density = math.max(0, densityScale or 1)
	local adaptive = math.max(0, adaptiveScale or 1)
	local styleScale = density * adaptive

	for _, side in pairs(self.Side) do
		local isOuterEdge = (turnSign ~= 0) and (side.Sign == turnSign)
		local edgeBias = isOuterEdge and 1.32 or 0.78
		local heavySpray = highSpeedSlideAlpha
		local mistRate = speed * (0.2 + (turnAlpha * 0.95 * edgeBias)) * groundedAlpha
		mistRate += speed * 0.14 * groundedAlpha * (1 - turnAlpha) * (1 - brakeAlpha)
		mistRate += speed * 0.08 * pushAlpha * groundedAlpha
		mistRate += speed * 0.10 * heavySpray * groundedAlpha

		local brakeRate = speed * (0.75 + (stopAlpha * 1.1)) * math.max(lowSpeedBrakeAlpha, stopAlpha * 0.45) * groundedAlpha
		brakeRate += speed * (1.8 + (stopAlpha * 1.3)) * heavySpray * groundedAlpha
		if isOuterEdge then
			brakeRate *= (1.12 + (heavySpray * 0.2))
		end

		side.Mist.Rate = math.clamp(mistRate * styleScale, 0, 220)
		side.Brake.Rate = math.clamp(brakeRate * styleScale, 0, 360)
		side.Brake.Speed = NumberRange.new(8 + (heavySpray * 16), 17 + (heavySpray * 24))
		side.Brake.SpreadAngle = Vector2.new(20 + (heavySpray * 24), 26 + (heavySpray * 40))

		local outward = right * side.Sign
		local mistDirection = safeUnit(
			(forward * -(0.22 + (brakeAlpha * 0.2)))
				+ (outward * ((turnAlpha * 0.72) + (brakeAlpha * 0.2)))
				+ (normal * (0.34 + (heavySpray * 0.26))),
			normal
		)
		local brakeDirection = safeUnit(
			(forward * -((0.95 + (stopAlpha * 0.35)) - (heavySpray * 0.35)))
				+ (outward * (0.45 + (lowSpeedBrakeAlpha * 0.45) + (heavySpray * 0.7)))
				+ (normal * (0.24 + (heavySpray * 1.15))),
			-forward
		)

		setAttachmentDirection(self.RootPart, side.MistAttachment, mistDirection, normal)
		setAttachmentDirection(self.RootPart, side.BrakeAttachment, brakeDirection, normal)
	end
end

function SkiMistVFX:Destroy()
	for _, emitter in ipairs(self.Emitters) do
		if emitter then
			emitter:Destroy()
		end
	end
	for _, side in pairs(self.Side) do
		if side.MistAttachment then
			side.MistAttachment:Destroy()
		end
		if side.BrakeAttachment then
			side.BrakeAttachment:Destroy()
		end
	end
	self.Emitters = {}
	self.Side = {}
end

return SkiMistVFX
