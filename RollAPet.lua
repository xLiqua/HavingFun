-- Wait until the game is fully loaded
repeat task.wait() until game:IsLoaded()

-- Only run in the correct place
if game.PlaceId ~= 128557089580754 then return end

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local lp = Players.LocalPlayer
local guiParent = gethui and gethui() or lp:WaitForChild("PlayerGui")

-- Cleanup previous instance (cancel old threads too)
local existingGui = guiParent:FindFirstChild("PeanutCustomUI")
if existingGui then
    existingGui:Destroy()
end

-- Thread registry for cleanup
local activeThreads = {}

local function spawnTracked(fn)
    local t = task.spawn(fn)
    table.insert(activeThreads, t)
    return t
end

local function cleanupThreads()
    for _, t in ipairs(activeThreads) do
        task.cancel(t)
    end
    table.clear(activeThreads)
end

local CustomUI = loadstring(game:HttpGet("https://raw.githubusercontent.com/xLiqua/CustomUI/refs/heads/main/CustomUI.lua"))()()
local DataClient = require(ReplicatedStorage.Packages.dataservice).client

local Settings = {
    AutoRoll = true,
    AutoRebirth = false,
    AutoBuyZones = true,
    AutoCollect = false
}

local Zones = {
    "Ice", "Desert", "Lava", "Sakura", "Mushroom",
    "Heaven", "Candy", "Swamp", "Tech"
}

local ZonePrices = {
    Ice = 500,
    Desert = 4000,
    Lava = 36000,
    Sakura = 360000,
    Mushroom = 2880000,
    Heaven = 25920000,
    Candy = 259200000,
    Swamp = 2073600000,
    Tech = 18662400000
}

local ZoneCFrames = {
    Spawn = CFrame.new(8.83907223, 6.08495235, 592.977173),
    Ice = CFrame.new(6.92034864, 6.39787769, 335.32962),
    Desert = CFrame.new(7.72411156, 6.33407784, -3.81444812),
    Lava = CFrame.new(6.01895857, 6.10962105, -255.684387),
    Sakura = CFrame.new(-9.20067883, 6.08495235, -497.096954),
    Mushroom = CFrame.new(-261.987915, 6.01867104, -523.158264),
    Heaven = CFrame.new(-535.032104, 6.01866817, -523.112915),
    Candy = CFrame.new(-805.52124, 6.01867104, -522.864258),
    Swamp = CFrame.new(-1028.66223, 6.01867104, -525.780945),
    Tech = CFrame.new(-1270.89697, 6.02929974, -533.768372)
}

local BASE_GEMS_NEEDED = 100
local MAX_REBIRTHS = 500

local function findRemote(logicalName)
    for _, v in ipairs(ReplicatedStorage:GetDescendants()) do
        if (v:IsA("RemoteEvent") or v:IsA("RemoteFunction")) and v:GetAttribute("LogicalName") == logicalName then
            return v
        end
    end
end

local function getData()
    return DataClient:get()
end

local function getGemsNeeded(rebirths)
    rebirths = math.clamp(math.floor(tonumber(rebirths) or 0), 0, MAX_REBIRTHS)
    return BASE_GEMS_NEEDED * (2 ^ rebirths)
end

local function getPlayerStats()
    local data = getData()
    if not data then
        return 0, 0, 0
    end
    return
        tonumber(data.Coins) or 0,
        tonumber(data.Gems) or 0,
        tonumber(data.Rebirths) or 0
end

local function canRebirth()
    local _, gems, rebirths = getPlayerStats()
    return gems >= getGemsNeeded(rebirths)
end

local function isAreaUnlocked(areaName, data)
    if areaName == "Spawn" then return true end
    return data and data.OwnedAreas and data.OwnedAreas[areaName] == true
end

-- Safe HRP getter: only yields if character is truly absent
local function getHRP()
    local char = lp.Character
    if not char then
        char = lp.CharacterAdded:Wait()
    end
    return char:WaitForChild("HumanoidRootPart", 5)
end

local function tpToZone(areaName)
    local cf = ZoneCFrames[areaName]
    if not cf then return end
    local hrp = getHRP()
    if hrp then
        hrp.CFrame = cf
    end
end

-- Returns the highest-tier unlocked zone (last in the Zones list),
-- falling back to Spawn only if nothing is unlocked yet.
local function getBestUnlockedZone(data)
    for i = #Zones, 1, -1 do
        if isAreaUnlocked(Zones[i], data) then
            return Zones[i]
        end
    end
    return "Spawn"
end

-- TP threshold: how far from the target CFrame before we re-teleport (studs)
local TP_THRESHOLD = 20

local RollRemote        = findRemote("Roll_Request")
local RebirthRemote     = findRemote("Rebirth_Request")
local BuyZoneRemote     = findRemote("Areas_RequestBuy")
local CollectCoinRemote = findRemote("Enemies_CollectCoin")

local Popups = workspace:WaitForChild("_RNGClientWorldPopups"):WaitForChild("Popups")

-- Anti-AFK: fires the Roll button connection every 60s to prevent kick
spawnTracked(function()
    while task.wait(60) do
        pcall(function()
            local button = lp.PlayerGui.MainGui.Middle.Roll
            for _, conn in ipairs(getconnections(button.MouseButton1Click)) do
                conn:Fire()
            end
        end)
    end
end)

-- Auto Roll
spawnTracked(function()
    while task.wait(0.15) do
        if Settings.AutoRoll and RollRemote then
            pcall(function()
                RollRemote:InvokeServer()
            end)
        end
    end
end)

-- Auto Rebirth
spawnTracked(function()
    while task.wait(0.5) do
        if Settings.AutoRebirth and RebirthRemote and canRebirth() then
            pcall(function()
                RebirthRemote:FireServer()
            end)
        end
    end
end)

-- Auto Buy Zones + Smart TP
-- Tracks the last zone we teleported to so we only TP again when
-- either a new zone is bought or we've drifted too far from the target.
local lastTpZone = nil

spawnTracked(function()
    while task.wait(1) do
        if Settings.AutoBuyZones and BuyZoneRemote then
            local data = getData()
            local coins = tonumber(data and data.Coins) or 0

            local boughtZone = nil

            for _, areaName in ipairs(Zones) do
                if not Settings.AutoBuyZones then break end

                if not isAreaUnlocked(areaName, data) then
                    local price = ZonePrices[areaName]

                    if price and coins >= price then
                        pcall(function()
                            BuyZoneRemote:FireServer({ areaName = areaName })
                        end)

                        boughtZone = areaName
                        task.wait(0.6)

                        data = getData()
                        coins = tonumber(data and data.Coins) or 0
                    else
                        break
                    end
                end
            end

            -- Determine where we should be standing
            local targetZone = boughtZone or getBestUnlockedZone(data)

            -- Only TP if the zone changed, or we've drifted away from it
            local shouldTp = (targetZone ~= lastTpZone)

            if not shouldTp then
                local hrp = getHRP()
                local targetCF = ZoneCFrames[targetZone]
                if hrp and targetCF then
                    local dist = (hrp.Position - targetCF.Position).Magnitude
                    shouldTp = dist > TP_THRESHOLD
                end
            end

            if shouldTp then
                if boughtZone then task.wait(0.4) end
                tpToZone(targetZone)
                lastTpZone = targetZone
            end
        else
            -- Reset so next enable re-TPs correctly
            lastTpZone = nil
        end
    end
end)

-- Auto Collect
spawnTracked(function()
    while task.wait(0.15) do
        if Settings.AutoCollect and CollectCoinRemote then
            local children = Popups:GetChildren()
            for _, popup in ipairs(children) do
                local uid = popup:GetAttribute("CoinDropUID")
                if uid then
                    pcall(function()
                        CollectCoinRemote:FireServer(uid)
                    end)
                end
            end
        end
    end
end)

-- UI
local Window = CustomUI:CreateWindow({
    Name = "PeanutHub",
    Subtitle = "Auto Roll / Rebirth / Zones / Collect"
})

Window:SetTheme("Crimson")

local Main = Window:CreateTab("Main")

Main:CreateToggle({
    Name = "Auto Roll",
    CurrentValue = true,
    Callback = function(v)
        Settings.AutoRoll = v
    end
})

Main:CreateToggle({
    Name = "Auto Rebirth",
    CurrentValue = false,
    Callback = function(v)
        Settings.AutoRebirth = v
    end
})

Main:CreateToggle({
    Name = "Auto Buy Zones + Smart TP",
    CurrentValue = true,
    Callback = function(v)
        Settings.AutoBuyZones = v
    end
})

Main:CreateToggle({
    Name = "Auto Collect",
    CurrentValue = false,
    Callback = function(v)
        Settings.AutoCollect = v
    end
})