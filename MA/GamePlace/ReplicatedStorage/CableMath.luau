--[[
	SCRIPT: CableMath (V10 - Planar Bullwheel)
	LOCATION: ReplicatedStorage
	
	WHAT IT DOES:
	Calculates exact paths for the lift.
	
	CHANGES (V10):
	- FIXED: Bullwheel Planar Lock. 
	  In `GetPointOnCircle`, it now calculates the average Y (height) of pStart, pMid, and pEnd.
	  It forces the entire arc to stay at this exact height. This guarantees 0 sag and 
	  0 vertical wobble, even if your station attachments are slightly uneven.
]]

local CableMath = {}

-- // MATH UTILITIES //
function CableMath.GetCircleCenter(p1, p2, p3)
	local ab = p2 - p1
	local ac = p3 - p1
	local abXac = ab:Cross(ac)

	if abXac.Magnitude < 0.001 then return (p1 + p3) / 2 end

	local toCenter = (abXac:Cross(ab)*ac.Magnitude^2 + ac:Cross(abXac)*ab.Magnitude^2) / (2 * abXac.Magnitude^2)
	return p1 + toCenter
end

-- Custom Slerp with Radius Blend
function CableMath.Slerp(center, pStart, pEnd, t)
	local vStart = pStart - center
	local vEnd   = pEnd - center

	local magStart = vStart.Magnitude
	local magEnd   = vEnd.Magnitude
	local currentMag = magStart + (magEnd - magStart) * t

	local dot = vStart:Dot(vEnd) / (magStart * magEnd)
	dot = math.clamp(dot, -1, 1)
	local theta = math.acos(dot) * t

	local relative = (vEnd - vStart * (dot * magEnd / magStart)).Unit
	if relative.Magnitude == 0 or relative.X ~= relative.X then relative = Vector3.zero end

	local rotated = (vStart.Unit * math.cos(theta)) + (relative * math.sin(theta))
	return center + (rotated * currentMag)
end

-- // PLANAR CONSTANT VELOCITY CIRCLE //
function CableMath.GetPointOnCircle(pStart, pMid, pEnd, t)
	-- [PLANAR FIX] Calculate the Average Y (Height) of the station points
	local avgY = (pStart.Y + pMid.Y + pEnd.Y) / 3

	-- Flatten the points to this average height for calculation
	local flatStart = Vector3.new(pStart.X, avgY, pStart.Z)
	local flatMid   = Vector3.new(pMid.X,   avgY, pMid.Z)
	local flatEnd   = Vector3.new(pEnd.X,   avgY, pEnd.Z)

	local center = CableMath.GetCircleCenter(flatStart, flatMid, flatEnd)

	-- Measure angles on the flat plane
	local vS = flatStart - center
	local vM = flatMid   - center
	local vE = flatEnd   - center

	local dot1 = vS:Dot(vM) / (vS.Magnitude * vM.Magnitude)
	local ang1 = math.acos(math.clamp(dot1, -1, 1))

	local dot2 = vM:Dot(vE) / (vM.Magnitude * vE.Magnitude)
	local ang2 = math.acos(math.clamp(dot2, -1, 1))

	local totalAng = ang1 + ang2
	if totalAng < 0.001 then return flatStart:Lerp(flatEnd, t) end

	local splitT = ang1 / totalAng

	local result
	if t <= splitT then
		local subT = t / splitT
		result = CableMath.Slerp(center, flatStart, flatMid, subT)
	else
		local subT = (t - splitT) / (1 - splitT)
		result = CableMath.Slerp(center, flatMid, flatEnd, subT)
	end

	return result
end

function CableMath.GetCircleTangent(pStart, pMid, pEnd, t)
	local avgY = (pStart.Y + pMid.Y + pEnd.Y) / 3
	local flatStart = Vector3.new(pStart.X, avgY, pStart.Z)
	local flatMid = Vector3.new(pMid.X, avgY, pMid.Z)
	local flatEnd = Vector3.new(pEnd.X, avgY, pEnd.Z)

	local center = CableMath.GetCircleCenter(flatStart, flatMid, flatEnd)
	local pointOnArc = CableMath.GetPointOnCircle(pStart, pMid, pEnd, t)
	local radial = pointOnArc - center
	local chord = flatEnd - flatStart
	if radial.Magnitude < 0.001 then
		if chord.Magnitude < 0.001 then return Vector3.zAxis end
		return chord.Unit
	end

	local planeNormal = (flatMid - flatStart):Cross(flatEnd - flatMid)
	if planeNormal.Magnitude < 0.001 then
		if chord.Magnitude < 0.001 then return Vector3.zAxis end
		return chord.Unit
	end

	local tangent = planeNormal.Unit:Cross(radial.Unit)
	local chordDir = chord
	if chordDir.Magnitude > 0.001 and tangent:Dot(chordDir.Unit) < 0 then
		tangent = -tangent
	end

	if tangent.Magnitude < 0.001 then
		if chord.Magnitude < 0.001 then return Vector3.zAxis end
		return chord.Unit
	end
	return tangent.Unit
end

-- // STANDARD SAG //
function CableMath.GetPointOnCurve(p0, p1, sag, t)
	if math.abs(sag) < 0.001 then return p0:Lerp(p1, t) end
	local mid = (p0 + p1) / 2
	local c = mid - Vector3.new(0, sag * 2, 0)
	return p0:Lerp(c, t):Lerp(c:Lerp(p1, t), t)
end

function CableMath.GetTangent(p0, p1, sag, t)
	if math.abs(sag) < 0.001 then return (p1 - p0).Unit end
	local mid = (p0 + p1) / 2
	local c = mid - Vector3.new(0, sag * 2, 0)
	local term1 = 2 * (1 - t) * (c - p0)
	local term2 = 2 * t * (p1 - c)
	return (term1 + term2).Unit
end

return CableMath