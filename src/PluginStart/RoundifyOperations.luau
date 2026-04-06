--[[
	RoundifyOperations - Creates a rounded box from primitives.

	3D mode (default):
	- Up to 3 inner boxes (covering flat faces)
	- Up to 12 cylinders (covering edges)
	- Up to 8 spheres (covering corners)

	2D mode (X / Y / Z axis):
	- 2 inner boxes (spanning the full rounding axis)
	- 4 cylinders along the rounding axis (corner edges)
	- No spheres

	Stores RoundifyRadius, RoundifyMode, and RoundifySourceSize/CFrame attributes
	on the model so re-rounding can reconstruct the original part parameters.
]]

local Constants = require(script.Parent.Constants)

local TOLERANCE = 0.001
local MIN_RADIUS = Constants.MinRadius

-- Axis configs for data-driven geometry
local UNIT = { X = Vector3.xAxis, Y = Vector3.yAxis, Z = Vector3.zAxis }

local AXIS_CONFIG = {
	X = { rot = CFrame.new(), perps = { "Y", "Z" } },
	Y = { rot = CFrame.Angles(0, 0, math.rad(90)), perps = { "X", "Z" } },
	Z = { rot = CFrame.Angles(0, math.rad(90), 0), perps = { "X", "Y" } },
}

local ALL_AXES = { "X", "Y", "Z" }
local SIGN_PAIRS = { { 1, 1 }, { 1, -1 }, { -1, 1 }, { -1, -1 } }

local RoundifyOperations = {}

RoundifyOperations.COPY_PROPERTIES = {
	"Color",
	"Material",
	"MaterialVariant",
	"Transparency",
	"Reflectance",
	"Anchored",
	"CanCollide",
	"CanQuery",
	"CanTouch",
	"CastShadow",
	"CollisionGroup",
}

local function applyProperties(newPart: BasePart, source: BasePart, parent: Instance)
	for _, prop in RoundifyOperations.COPY_PROPERTIES do
		newPart[prop] = source[prop]
	end
	newPart.TopSurface = Enum.SurfaceType.Smooth
	newPart.BottomSurface = Enum.SurfaceType.Smooth
	newPart.Parent = parent
end

local function snap(v: number): number
	return math.round(v / TOLERANCE)
end

local function makeKey(x: number, y: number, z: number): string
	return `{snap(x)}_{snap(y)}_{snap(z)}`
end

local function snapOffset(v: number, threshold: number): number
	return if v < threshold then 0 else v
end

local function finalizeModel(model: Model, part: BasePart, cf: CFrame, r: number, primaryPart: BasePart?)
	model:SetAttribute("RoundifyRadius", r)
	if primaryPart then
		-- Compensate for rotated cylinders / offset parts so Model:GetPivot() returns
		-- the original CFrame (cf) instead of the PrimaryPart's rotated CFrame.
		primaryPart.PivotOffset = primaryPart.CFrame:ToObjectSpace(cf)
		model.PrimaryPart = primaryPart
		model:SetAttribute("RoundifyPrimaryPartSize", primaryPart.Size)
	end
	model.WorldPivot = cf
	model.Parent = part.Parent
	part.Parent = nil
end

function RoundifyOperations.getMaxRadius(sizeX: number, sizeY: number, sizeZ: number, mode: string?): number
	local cfg = mode and AXIS_CONFIG[mode]
	if cfg then
		local sizeVec = Vector3.new(sizeX, sizeY, sizeZ)
		return math.min(sizeVec[cfg.perps[1]], sizeVec[cfg.perps[2]]) / 2
	end
	return math.min(sizeX, sizeY, sizeZ) / 2
end

function RoundifyOperations.roundify(part: BasePart, radius: number, mode: string?): Model?
	local roundingMode = mode or "3D"
	local size = part.Size
	local X, Y, Z = size.X, size.Y, size.Z
	local maxRadius = RoundifyOperations.getMaxRadius(X, Y, Z, roundingMode)
	local r = math.clamp(radius, MIN_RADIUS, maxRadius)
	local diameter = 2 * r
	local cf = part.CFrame

	local is2D = roundingMode ~= "3D"

	local model = Instance.new("Model")
	model.Name = part.Name .. "_Rounded"
	model:SetAttribute("RoundifyMode", roundingMode)
	model:SetAttribute("RoundifySourceSize", size)
	model:SetAttribute("RoundifySourceCFrame", cf)

	-- Fully-rounded shortcut: single primitive when all perpendicular axes fit within diameter
	if r >= maxRadius - TOLERANCE then
		r = maxRadius
		diameter = 2 * r

		if is2D then
			local cfg = AXIS_CONFIG[roundingMode]
			local bothPerpFit = size[cfg.perps[1]] <= diameter + TOLERANCE
				and size[cfg.perps[2]] <= diameter + TOLERANCE
			if bothPerpFit then
				local cyl = Instance.new("Part")
				cyl.Shape = Enum.PartType.Cylinder
				cyl.Size = Vector3.new(size[roundingMode], diameter, diameter)
				cyl.CFrame = cf * cfg.rot
				applyProperties(cyl, part, model)
				finalizeModel(model, part, cf, r, cyl)
				return model
			end
		elseif X <= diameter + TOLERANCE and Y <= diameter + TOLERANCE and Z <= diameter + TOLERANCE then
			local ball = Instance.new("Part")
			ball.Shape = Enum.PartType.Ball
			ball.Size = Vector3.new(diameter, diameter, diameter)
			ball.CFrame = cf
			applyProperties(ball, part, model)
			finalizeModel(model, part, cf, r, ball)
			return model
		end
	end

	local primaryPart = nil
	local centerBox = nil
	local placed = {}
	local MERGE_THRESHOLD = r * 0.1
	local MIN_DIM = 2 * MERGE_THRESHOLD

	local function isDuplicate(key: string): boolean
		if placed[key] then
			return true
		end
		placed[key] = true
		return false
	end

	-- Edge offsets (snapped to 0 when negligible to avoid redundant coincident parts)
	-- Computed before boxes so the snapped spans can clamp box dimensions.
	local ox = snapOffset(X / 2 - r, MERGE_THRESHOLD)
	local oy = snapOffset(Y / 2 - r, MERGE_THRESHOLD)
	local oz = snapOffset(Z / 2 - r, MERGE_THRESHOLD)
	local offsets = { X = ox, Y = oy, Z = oz }

	-- Effective span per axis: diameter + 2*offset. When an offset is snapped to 0
	-- the span equals diameter, preventing boxes from protruding past the rounding.
	local span = {
		X = diameter + 2 * ox,
		Y = diameter + 2 * oy,
		Z = diameter + 2 * oz,
	}

	-- Inner boxes
	-- 3D: 3 boxes, each keeping one axis at its effective span and insetting the others
	-- 2D: 2 boxes, each insetting one perpendicular axis by diameter
	local boxSizes = {}
	if is2D then
		local cfg = AXIS_CONFIG[roundingMode]
		for _, perpAxis in cfg.perps do
			table.insert(boxSizes, size - UNIT[perpAxis] * diameter)
		end
	else
		for _, axis in ALL_AXES do
			local kept = UNIT[axis] * span[axis]
			local inset = (Vector3.one - UNIT[axis]) * diameter
			table.insert(boxSizes, kept + (size - inset) * (Vector3.one - UNIT[axis]))
		end
	end

	for _, boxSize in boxSizes do
		if boxSize.X > MIN_DIM and boxSize.Y > MIN_DIM and boxSize.Z > MIN_DIM then
			local key = makeKey(boxSize.X, boxSize.Y, boxSize.Z) .. "_BOX"
			if not isDuplicate(key) then
				local box = Instance.new("Part")
				box.Shape = Enum.PartType.Block
				box.Size = boxSize
				box.CFrame = cf
				applyProperties(box, part, model)
				centerBox = centerBox or box
				primaryPart = primaryPart or box
			end
		end
	end

	-- Edge cylinders
	local cylAxes = if is2D then { roundingMode } else ALL_AXES
	for _, axis in cylAxes do
		local cfg = AXIS_CONFIG[axis]
		local len = if is2D then size[axis] else size[axis] - diameter
		if len > MIN_DIM then
			local p1, p2 = cfg.perps[1], cfg.perps[2]
			for _, signs in SIGN_PAIRS do
				local offset = UNIT[p1] * signs[1] * offsets[p1] + UNIT[p2] * signs[2] * offsets[p2]
				local key = makeKey(offset.X, offset.Y, offset.Z) .. "_C" .. axis
				if not isDuplicate(key) then
					local cyl = Instance.new("Part")
					cyl.Shape = Enum.PartType.Cylinder
					cyl.Size = Vector3.new(len, diameter, diameter)
					cyl.CFrame = cf * CFrame.new(offset) * cfg.rot
					applyProperties(cyl, part, model)
					primaryPart = primaryPart or cyl
				end
			end
		end
	end

	-- Corner spheres (3D only)
	if not is2D then
		for _, sx in { 1, -1 } do
			for _, sy in { 1, -1 } do
				for _, sz in { 1, -1 } do
					local pos = Vector3.new(sx * ox, sy * oy, sz * oz)
					local key = makeKey(pos.X, pos.Y, pos.Z) .. "_SPH"
					if not isDuplicate(key) then
						local sphere = Instance.new("Part")
						sphere.Shape = Enum.PartType.Ball
						sphere.Size = Vector3.new(diameter, diameter, diameter)
						sphere.CFrame = cf * CFrame.new(pos)
						applyProperties(sphere, part, model)
						primaryPart = primaryPart or sphere
					end
				end
			end
		end
	end

	primaryPart = centerBox or primaryPart or model:FindFirstChildWhichIsA("BasePart")
	finalizeModel(model, part, cf, r, primaryPart)

	return model
end

return RoundifyOperations
