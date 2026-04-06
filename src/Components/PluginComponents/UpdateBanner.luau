local MarketplaceService = game:GetService("MarketplaceService")

local Plugin = script:FindFirstAncestorWhichIsA("Plugin")
local Fusion = require(Plugin:FindFirstChild("Fusion", true))

local New = Fusion.New
local Value = Fusion.Value
local Observer = Fusion.Observer
local Computed = Fusion.Computed
local Children = Fusion.Children

local function parseVersion(str: string): { number }?
	local major, minor, patch = str:match("(%d+)%.(%d+)%.(%d+)")
	if major then
		return { tonumber(major) :: number, tonumber(minor) :: number, tonumber(patch) :: number }
	end
	return nil
end

local function isNewerVersion(latest: string, current: string): boolean
	local a = parseVersion(latest)
	local b = parseVersion(current)
	if not a or not b then
		return false
	end
	for i = 1, 3 do
		if a[i] > b[i] then
			return true
		elseif a[i] < b[i] then
			return false
		end
	end
	return false
end

local POLL_INTERVAL = 30

local function checkForUpdate(assetId: number, currentVersion: string, updateAvailable)
	local ok, info = pcall(MarketplaceService.GetProductInfo, MarketplaceService, assetId)
	if ok and info and info.Description then
		local latestVersion = info.Description:match("(%d+%.%d+%.%d+)")
		if latestVersion and isNewerVersion(latestVersion, currentVersion) then
			updateAvailable:set(latestVersion)
		end
	end
end

return function(props: {
	AssetId: number,
	CurrentVersion: string,
	Enabled: typeof(Value(nil)),
	LayoutOrder: number?,
})
	local updateAvailable = Value(nil :: string?)
	local pollThread: thread? = nil

	local function startPolling()
		if pollThread then
			return
		end
		pollThread = task.spawn(function()
			while true do
				checkForUpdate(props.AssetId, props.CurrentVersion, updateAvailable)
				task.wait(POLL_INTERVAL)
			end
		end)
	end

	local function stopPolling()
		if pollThread then
			task.cancel(pollThread)
			pollThread = nil
		end
	end

	if props.Enabled:get() then
		startPolling()
	end

	Plugin.Unloading:Connect(Observer(props.Enabled):onChange(function()
		if props.Enabled:get() then
			startPolling()
		else
			stopPolling()
		end
	end))

	return Computed(function()
		local latestVersion = updateAvailable:get()
		if not latestVersion then
			return nil
		end
		return New("Frame")({
			Name = "UpdateBanner",
			Size = UDim2.new(1, 0, 0, 28),
			LayoutOrder = props.LayoutOrder or 0,
			BackgroundColor3 = Color3.fromRGB(255, 170, 0),
			BorderSizePixel = 0,
			[Children] = {
				New("UICorner")({ CornerRadius = UDim.new(0, 4) }),
				New("TextLabel")({
					Size = UDim2.fromScale(1, 1),
					BackgroundTransparency = 1,
					Text = "Update available: v" .. latestVersion,
					TextColor3 = Color3.fromRGB(0, 0, 0),
					TextSize = 14,
					Font = Enum.Font.GothamBold,
				}),
			},
		})
	end, Fusion.cleanup)
end
