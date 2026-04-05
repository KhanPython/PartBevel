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

local TOLERANCE = 0.001

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
	for _, prop in ipairs(RoundifyOperations.COPY_PROPERTIES) do
		newPart[prop] = source[prop]
	end
	newPart.TopSurface = Enum.SurfaceType.Smooth
	newPart.BottomSurface = Enum.SurfaceType.Smooth
	newPart.Parent = parent
end

-- Snaps a value to a grid for tolerance-based deduplication
local function snap(v: number): number
	return math.round(v / TOLERANCE)
end

function RoundifyOperations.getMaxRadius(sizeX: number, sizeY: number, sizeZ: number, mode: string?): number
	if mode == "X" then
		return math.min(sizeY, sizeZ) / 2
	elseif mode == "Y" then
		return math.min(sizeX, sizeZ) / 2
	elseif mode == "Z" then
		return math.min(sizeX, sizeY) / 2
	end
	return math.min(sizeX, sizeY, sizeZ) / 2
end

function RoundifyOperations.roundify(part: BasePart, radius: number, mode: string?): Model?
	local roundingMode = mode or "3D"
	local size = part.Size
	local X, Y, Z = size.X, size.Y, size.Z
	local maxRadius = RoundifyOperations.getMaxRadius(X, Y, Z, roundingMode)
	local r = math.clamp(radius, 0.01, maxRadius)
	local diameter = 2 * r
	local cf = part.CFrame

	local is2D = roundingMode ~= "3D"

	local model = Instance.new("Model")
	model.Name = part.Name .. "_Rounded"
	model:SetAttribute("RoundifyRadius", r)
	model:SetAttribute("RoundifyMode", roundingMode)
	model:SetAttribute("RoundifySourceSize", size)
	model:SetAttribute("RoundifySourceCFrame", cf)

	local primaryPart = nil
	local placed = {} -- dedup registry

	local function makeKey(...)
		local parts = {}
		for _, v in ipairs({ ... }) do
			table.insert(parts, tostring(snap(v)))
		end
		return table.concat(parts, "_")
	end

	local function isDuplicate(key: string): boolean
		if placed[key] then
			return true
		end
		placed[key] = true
		return false
	end

	-- Inner boxes
	-- 3D: 3 boxes, each with two axes inset by diameter
	-- 2D: 2 boxes, each with only one perpendicular axis inset (rounding axis stays full)
	local boxSizes = {}
	if is2D then
		if roundingMode == "X" then
			table.insert(boxSizes, Vector3.new(X, Y - diameter, Z))
			table.insert(boxSizes, Vector3.new(X, Y, Z - diameter))
		elseif roundingMode == "Y" then
			table.insert(boxSizes, Vector3.new(X - diameter, Y, Z))
			table.insert(boxSizes, Vector3.new(X, Y, Z - diameter))
		elseif roundingMode == "Z" then
			table.insert(boxSizes, Vector3.new(X - diameter, Y, Z))
			table.insert(boxSizes, Vector3.new(X, Y - diameter, Z))
		end
	else
		table.insert(boxSizes, Vector3.new(X, Y - diameter, Z - diameter))
		table.insert(boxSizes, Vector3.new(X - diameter, Y, Z - diameter))
		table.insert(boxSizes, Vector3.new(X - diameter, Y - diameter, Z))
	end

	for _, boxSize in ipairs(boxSizes) do
		if boxSize.X > 0 and boxSize.Y > 0 and boxSize.Z > 0 then
			local key = makeKey(boxSize.X, boxSize.Y, boxSize.Z) .. "_BOX"
			if not isDuplicate(key) then
				local box = Instance.new("Part")
				box.Shape = Enum.PartType.Block
				box.Size = boxSize
				box.CFrame = cf
				applyProperties(box, part, model)
				primaryPart = primaryPart or box
			end
		end
	end

	-- Edge offsets
	local ox, oy, oz = X / 2 - r, Y / 2 - r, Z / 2 - r

	-- Cylinder helper: places up to 4 cylinders along a given axis
	-- In 2D mode, only place cylinders along the rounding axis with full axis length
	local CYLINDER_CONFIGS = {}

	if not is2D or roundingMode == "X" then
		table.insert(CYLINDER_CONFIGS, {
			if is2D then X else X - diameter,
			function(s1, s2)
				return 0, s1 * oy, s2 * oz
			end,
			CFrame.new(),
			"CX",
		})
	end
	if not is2D or roundingMode == "Y" then
		table.insert(CYLINDER_CONFIGS, {
			if is2D then Y else Y - diameter,
			function(s1, s2)
				return s1 * ox, 0, s2 * oz
			end,
			CFrame.Angles(0, 0, math.rad(90)),
			"CY",
		})
	end
	if not is2D or roundingMode == "Z" then
		table.insert(CYLINDER_CONFIGS, {
			if is2D then Z else Z - diameter,
			function(s1, s2)
				return s1 * ox, s2 * oy, 0
			end,
			CFrame.Angles(0, math.rad(90), 0),
			"CZ",
		})
	end

	for _, config in ipairs(CYLINDER_CONFIGS) do
		local len, offsetFn, rot, suffix = config[1], config[2], config[3], config[4]
		if len > 0 then
			for _, signs in ipairs({ { 1, 1 }, { 1, -1 }, { -1, 1 }, { -1, -1 } }) do
				local px, py, pz = offsetFn(signs[1], signs[2])
				local key = makeKey(px, py, pz) .. "_" .. suffix
				if not isDuplicate(key) then
					local cyl = Instance.new("Part")
					cyl.Shape = Enum.PartType.Cylinder
					cyl.Size = Vector3.new(len, diameter, diameter)
					cyl.CFrame = cf * CFrame.new(px, py, pz) * rot
					applyProperties(cyl, part, model)
					primaryPart = primaryPart or cyl
				end
			end
		end
	end

	-- Corner spheres (3D mode only)
	if not is2D then
		for _, sx in ipairs({ 1, -1 }) do
			for _, sy in ipairs({ 1, -1 }) do
				for _, sz in ipairs({ 1, -1 }) do
					local px, py, pz = sx * ox, sy * oy, sz * oz
					local key = makeKey(px, py, pz) .. "_SPH"
					if not isDuplicate(key) then
						local sphere = Instance.new("Part")
						sphere.Shape = Enum.PartType.Ball
						sphere.Size = Vector3.new(diameter, diameter, diameter)
						sphere.CFrame = cf * CFrame.new(px, py, pz)
						applyProperties(sphere, part, model)
						primaryPart = primaryPart or sphere
					end
				end
			end
		end
	end

	if not primaryPart then
		primaryPart = model:FindFirstChildWhichIsA("BasePart")
	end
	if primaryPart then
		model.PrimaryPart = primaryPart
		model:SetAttribute("RoundifyPrimaryPartSize", primaryPart.Size)
	end

	model.Parent = part.Parent
	part.Parent = nil

	return model
end

return RoundifyOperations
