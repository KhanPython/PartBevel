--[[
	BevelOperations - Creates a rounded box from primitives:
	- Up to 3 inner boxes (covering flat faces)
	- Up to 12 cylinders (covering edges)
	- Up to 8 spheres (covering corners)

	Stores BevelRadius and BevelSourceSize/CFrame attributes on the model
	so re-beveling can reconstruct the original part parameters.
]]

local TOLERANCE = 0.001

local BevelOperations = {}

BevelOperations.COPY_PROPERTIES = {
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
	for _, prop in ipairs(BevelOperations.COPY_PROPERTIES) do
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

function BevelOperations.getMaxRadius(sizeX: number, sizeY: number, sizeZ: number): number
	return math.min(sizeX, sizeY, sizeZ) / 2
end

function BevelOperations.bevel(part: BasePart, radius: number): Model?
	local size = part.Size
	local X, Y, Z = size.X, size.Y, size.Z
	local maxRadius = BevelOperations.getMaxRadius(X, Y, Z)
	local r = math.clamp(radius, 0.01, maxRadius)
	local diameter = 2 * r
	local cf = part.CFrame

	local model = Instance.new("Model")
	model.Name = part.Name .. "_Bevelled"
	model:SetAttribute("BevelRadius", r)
	model:SetAttribute("BevelSourceSize", size)
	model:SetAttribute("BevelSourceCFrame", cf)

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
	local boxSizes = {
		Vector3.new(X, Y - diameter, Z - diameter),
		Vector3.new(X - diameter, Y, Z - diameter),
		Vector3.new(X - diameter, Y - diameter, Z),
	}

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
	local CYLINDER_CONFIGS = {
		-- {length, sizeVec, offsetFn, rotCFrame, suffix}
		{
			X - diameter,
			function(s1, s2)
				return 0, s1 * oy, s2 * oz
			end,
			CFrame.new(),
			"CX",
		},
		{
			Y - diameter,
			function(s1, s2)
				return s1 * ox, 0, s2 * oz
			end,
			CFrame.Angles(0, 0, math.rad(90)),
			"CY",
		},
		{
			Z - diameter,
			function(s1, s2)
				return s1 * ox, s2 * oy, 0
			end,
			CFrame.Angles(0, math.rad(90), 0),
			"CZ",
		},
	}

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

	-- Corner spheres
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

	if not primaryPart then
		primaryPart = model:FindFirstChildWhichIsA("BasePart")
	end
	if primaryPart then
		model.PrimaryPart = primaryPart
	end

	model.Parent = part.Parent
	part.Parent = nil

	return model
end

return BevelOperations
