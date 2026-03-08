-- QuestZombie (WoW 3.3.5)
-- Pure WoW API quest automation addon skeleton.

local ADDON_NAME = ...

QuestZombieDB = QuestZombieDB or {}

local defaults = {
    enabled = true,
    autoAccept = true,
    skipGreeting = true,
    autoEscort = false,
    autoComplete = true,
    allowInRaid = true,
    rewardKeys = false,

    smartRewards = true,
    rewardMode = "auto",          -- auto / manual / vendor
    classOverride = "auto",       -- auto / hunter / rogue / warrior / paladin / shaman / druid / priest / mage / warlock / deathknight
    specOverride = "auto",        -- auto / bm / mm / sv / ass / combat / sub / arms / fury / prot / holy / ret
    rewardDebug = false,          -- hidden from GUI, kept for development
    rewardRetryEnabled = true,    -- always enforced in code
    rewardRetryDelay = 0.2,
    rewardRetryMax = 8,

    guiX = nil,
    guiY = nil,
}

local function ApplyDefaults(dst, src)
    for k, v in pairs(src) do
        if type(v) == "table" then
            if type(dst[k]) ~= "table" then
                dst[k] = {}
            end
            ApplyDefaults(dst[k], v)
        elseif dst[k] == nil then
            dst[k] = v
        end
    end
end

ApplyDefaults(QuestZombieDB, defaults)

local DB = QuestZombieDB
DB.rewardRetryEnabled = true

local addon = CreateFrame("Frame", "QuestZombieFrame", UIParent)
local rewardListener = CreateFrame("Frame", "QuestZombieRewardListener", UIParent)
rewardListener:Hide()

local pendingRewardRetry = false
local pendingRewardRetryDelay = 0
local pendingRewardRetryCount = 0

local rewardKeyMap = {
    NUMPAD1 = 1, NUMPAD2 = 2, NUMPAD3 = 3, NUMPAD4 = 4, NUMPAD5 = 5,
    NUMPAD6 = 6, NUMPAD7 = 7, NUMPAD8 = 8, NUMPAD9 = 9, NUMPAD0 = 10,
    ["1"] = 1, ["2"] = 2, ["3"] = 3, ["4"] = 4, ["5"] = 5,
    ["6"] = 6, ["7"] = 7, ["8"] = 8, ["9"] = 9, ["0"] = 10,
}

local rewardButtons = {}
local DisableRewardListener
local EnableRewardListener
local EnsureGUI
local GetRewardScoreBreakdown

local GUIFrame = nil
local GUIRefresh = nil
local dropdownCounter = 0

local CLASS_OPTIONS = {
    { value = "auto", text = "Auto Detect" },
    { value = "hunter", text = "Hunter" },
    { value = "rogue", text = "Rogue" },
    { value = "warrior", text = "Warrior" },
    { value = "paladin", text = "Paladin" },
    { value = "shaman", text = "Shaman" },
    { value = "druid", text = "Druid" },
    { value = "priest", text = "Priest" },
    { value = "mage", text = "Mage" },
    { value = "warlock", text = "Warlock" },
    { value = "deathknight", text = "Death Knight" },
}

local HUNTER_SPEC_OPTIONS = {
    { value = "auto", text = "Auto Detect" },
    { value = "bm", text = "Beast Mastery" },
    { value = "mm", text = "Marksmanship" },
    { value = "sv", text = "Survival" },
}

local ROGUE_SPEC_OPTIONS = {
    { value = "auto", text = "Auto Detect" },
    { value = "ass", text = "Assassination" },
    { value = "combat", text = "Combat" },
    { value = "sub", text = "Subtlety" },
}

local WARRIOR_SPEC_OPTIONS = {
    { value = "auto", text = "Auto Detect" },
    { value = "arms", text = "Arms" },
    { value = "fury", text = "Fury" },
    { value = "prot", text = "Protection" },
}

local PALADIN_SPEC_OPTIONS = {
    { value = "auto", text = "Auto Detect" },
    { value = "holy", text = "Holy" },
    { value = "prot", text = "Protection" },
    { value = "ret", text = "Retribution" },
}

local MODE_OPTIONS = {
    { value = "auto", text = "Auto", tooltip = "Automatically selects rewards using smart class and spec logic." },
    { value = "manual", text = "Manual", tooltip = "Disables smart reward selection. QuestZombie will wait for manual reward hotkeys instead." },
    { value = "vendor", text = "Vendor", tooltip = "Chooses the reward with the highest vendor sell value." },
}

local function Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99QuestZombie:|r " .. tostring(msg))
end

local function DebugPrint(msg)
    if DB.rewardDebug then
        Print("[debug] " .. tostring(msg))
    end
end

local function NormalizeRewardOptionState()
    DB.rewardRetryEnabled = true

    if DB.smartRewards then
        DB.rewardKeys = false
    elseif DB.rewardKeys then
        DB.smartRewards = false
    else
        DB.smartRewards = true
        DB.rewardKeys = false
    end
end

NormalizeRewardOptionState()

local function CreateRewardButton(index)
    local button = CreateFrame("Button", "QuestZombieRewardButton" .. index, UIParent, "SecureActionButtonTemplate")
    button:SetWidth(1)
    button:SetHeight(1)
    button:SetPoint("TOPLEFT", UIParent, "TOPLEFT", -100, 100)
    button:Hide()

    button:SetScript("OnClick", function()
        if GetNumQuestChoices() >= index then
            GetQuestReward(index)
        end
        DisableRewardListener()
    end)

    rewardButtons[index] = button
end

local function EnsureRewardButtons()
    for i = 1, 10 do
        if not rewardButtons[i] then
            CreateRewardButton(i)
        end
    end
end

local function BindRewardKeys(numChoices)
    EnsureRewardButtons()
    ClearOverrideBindings(rewardListener)

    for i = 1, math.min(numChoices, 10) do
        local key = tostring(i % 10)
        SetOverrideBindingClick(rewardListener, true, key, "QuestZombieRewardButton" .. i)
        SetOverrideBindingClick(rewardListener, true, "NUMPAD" .. key, "QuestZombieRewardButton" .. i)
    end
end

SLASH_QUESTZOMBIE1 = "/qz"
SLASH_QUESTZOMBIE2 = "/questzombie"

SlashCmdList["QUESTZOMBIE"] = function(msg)
    msg = (msg or ""):lower()
    msg = msg:gsub("^%s+", ""):gsub("%s+$", "")

    local cmd, value = msg:match("^(%S+)%s*(.-)$")

    if not cmd or cmd == "" then
        Print("Commands: status, toggle, accept, greeting, escort, complete, raid, rewardkeys, smartrewards, mode, class, spec, debugreward, gui")
        return
    end

    local map = {
        toggle = "enabled",
        accept = "autoAccept",
        greeting = "skipGreeting",
        escort = "autoEscort",
        complete = "autoComplete",
        raid = "allowInRaid",
        rewardkeys = "rewardKeys",
        smartrewards = "smartRewards",
    }

    if cmd == "status" then
        Print("enabled=" .. tostring(DB.enabled)
            .. ", accept=" .. tostring(DB.autoAccept)
            .. ", greeting=" .. tostring(DB.skipGreeting)
            .. ", escort=" .. tostring(DB.autoEscort)
            .. ", complete=" .. tostring(DB.autoComplete)
            .. ", raid=" .. tostring(DB.allowInRaid)
            .. ", rewardkeys=" .. tostring(DB.rewardKeys)
            .. ", smartrewards=" .. tostring(DB.smartRewards)
            .. ", mode=" .. tostring(DB.rewardMode)
            .. ", class=" .. tostring(DB.classOverride)
            .. ", spec=" .. tostring(DB.specOverride)
            .. ", debugreward=" .. tostring(DB.rewardDebug)
            .. ", retrydelay=" .. tostring(DB.rewardRetryDelay)
            .. ", retrymax=" .. tostring(DB.rewardRetryMax))
        return
    end

    if cmd == "mode" then
        value = (value or ""):lower()
        if value == "auto" or value == "manual" or value == "vendor" then
            DB.rewardMode = value
            Print("mode=" .. DB.rewardMode)
            if GUIRefresh then GUIRefresh() end
        else
            Print("Usage: /qz mode auto|manual|vendor")
        end
        return
    end

    if cmd == "class" then
        value = (value or ""):lower()
        if value == "auto" or value == "hunter" or value == "rogue" or value == "warrior" or value == "paladin"
            or value == "shaman" or value == "druid" or value == "priest" or value == "mage"
            or value == "warlock" or value == "deathknight" then
            DB.classOverride = value
            Print("class=" .. DB.classOverride)
            if GUIRefresh then GUIRefresh() end
        else
            Print("Usage: /qz class auto|hunter|rogue|warrior|paladin|shaman|druid|priest|mage|warlock|deathknight")
        end
        return
    end

    if cmd == "spec" then
        value = (value or ""):lower()
        if value == "auto"
            or value == "bm" or value == "mm" or value == "sv"
            or value == "ass" or value == "combat" or value == "sub"
            or value == "arms" or value == "fury" or value == "prot"
            or value == "holy" or value == "ret" then
            DB.specOverride = value
            Print("spec=" .. DB.specOverride)
            if GUIRefresh then GUIRefresh() end
        else
            Print("Usage: /qz spec auto|bm|mm|sv|ass|combat|sub|arms|fury|prot|holy|ret")
        end
        return
    end

    if cmd == "debugreward" then
        value = (value or ""):lower()

        if value == "on" then
            DB.rewardDebug = true
        elseif value == "off" then
            DB.rewardDebug = false
        else
            DB.rewardDebug = not DB.rewardDebug
        end

        Print("debugreward=" .. tostring(DB.rewardDebug))
        return
    end

    if cmd == "gui" then
        EnsureGUI()
        if GUIFrame and GUIFrame:IsShown() then
            GUIFrame:Hide()
        else
            if GUIFrame then
                GUIFrame:Show()
                if GUIRefresh then GUIRefresh() end
            end
        end
        return
    end

    local key = map[cmd]
    if not key then
        Print("Unknown command: " .. cmd)
        return
    end

    if value == "on" then
        DB[key] = true
    elseif value == "off" then
        DB[key] = false
    else
        DB[key] = not DB[key]
    end

    NormalizeRewardOptionState()

    Print(cmd .. "=" .. tostring(DB[key]))
    if GUIRefresh then GUIRefresh() end
end

local function GetPlayerClassToken()
    local _, class = UnitClass("player")
    return class
end

local function GetPrimaryTalentTree()
    local bestTab = 1
    local bestPoints = -1

    for tab = 1, GetNumTalentTabs() do
        local _, _, pointsSpent = GetTalentTabInfo(tab)
        if pointsSpent and pointsSpent > bestPoints then
            bestPoints = pointsSpent
            bestTab = tab
        end
    end

    return bestTab, bestPoints
end

local function GetEffectiveClass()
    if DB.classOverride and DB.classOverride ~= "auto" then
        if DB.classOverride == "hunter" then return "HUNTER" end
        if DB.classOverride == "rogue" then return "ROGUE" end
        if DB.classOverride == "warrior" then return "WARRIOR" end
        if DB.classOverride == "paladin" then return "PALADIN" end
        if DB.classOverride == "shaman" then return "SHAMAN" end
        if DB.classOverride == "druid" then return "DRUID" end
        if DB.classOverride == "priest" then return "PRIEST" end
        if DB.classOverride == "mage" then return "MAGE" end
        if DB.classOverride == "warlock" then return "WARLOCK" end
        if DB.classOverride == "deathknight" then return "DEATHKNIGHT" end
    end

    return GetPlayerClassToken()
end

local function GetHunterSpecToken()
    if DB.specOverride and DB.specOverride ~= "auto" then
        return DB.specOverride
    end

    local tab = GetPrimaryTalentTree()

    if tab == 1 then
        return "bm"
    elseif tab == 2 then
        return "mm"
    elseif tab == 3 then
        return "sv"
    end

    return "bm"
end

local function GetRogueSpecToken()
    if DB.specOverride and DB.specOverride ~= "auto" then
        return DB.specOverride
    end

    local tab = GetPrimaryTalentTree()

    if tab == 1 then
        return "ass"
    elseif tab == 2 then
        return "combat"
    elseif tab == 3 then
        return "sub"
    end

    return "combat"
end

local function GetWarriorSpecToken()
    if DB.specOverride and DB.specOverride ~= "auto" then
        return DB.specOverride
    end

    local tab = GetPrimaryTalentTree()

    if tab == 1 then
        return "arms"
    elseif tab == 2 then
        return "fury"
    elseif tab == 3 then
        return "prot"
    end

    return "arms"
end

local function GetPaladinSpecToken()
    if DB.specOverride and DB.specOverride ~= "auto" then
        return DB.specOverride
    end

    local tab = GetPrimaryTalentTree()

    if tab == 1 then
        return "holy"
    elseif tab == 2 then
        return "prot"
    elseif tab == 3 then
        return "ret"
    end

    return "ret"
end

local function CanUseTitansGrip()
    local classToken = GetEffectiveClass()
    if classToken ~= "WARRIOR" then
        return false
    end

    local furyPoints = select(3, GetTalentTabInfo(2)) or 0
    return furyPoints >= 51
end

local function GetRewardProfile()
    if not DB.smartRewards then
        return nil
    end

    if DB.rewardMode == "manual" then
        return nil
    end

    if DB.rewardMode == "vendor" then
        return "vendor"
    end

    local classToken = GetEffectiveClass()

    if classToken == "HUNTER" then
        if UnitLevel("player") < 80 then
            return "hunter_leveling"
        end

        local spec = GetHunterSpecToken()
        if spec == "bm" then
            return "hunter_bm"
        elseif spec == "mm" then
            return "hunter_mm"
        elseif spec == "sv" then
            return "hunter_sv"
        end

    elseif classToken == "ROGUE" then
        if UnitLevel("player") < 80 then
            return "rogue_leveling"
        end

        local spec = GetRogueSpecToken()
        if spec == "ass" then
            return "rogue_ass"
        elseif spec == "combat" then
            return "rogue_combat"
        elseif spec == "sub" then
            return "rogue_sub"
        end

    elseif classToken == "WARRIOR" then
        if UnitLevel("player") < 80 then
            return "warrior_leveling"
        end

        local spec = GetWarriorSpecToken()
        if spec == "arms" then
            return "warrior_arms"
        elseif spec == "fury" then
            return "warrior_fury"
        elseif spec == "prot" then
            return "warrior_prot"
        end

    elseif classToken == "PALADIN" then
        if UnitLevel("player") < 80 then
            return "paladin_leveling"
        end

        local spec = GetPaladinSpecToken()
        if spec == "holy" then
            return "paladin_holy"
        elseif spec == "prot" then
            return "paladin_prot"
        elseif spec == "ret" then
            return "paladin_ret"
        end
    end

    return nil
end

local function IsAutomationAllowed()
    if not DB.enabled then
        return false
    end

    if IsControlKeyDown() then
        return false
    end

    if UnitInRaid("player") and not DB.allowInRaid then
        return false
    end

    return true
end

DisableRewardListener = function()
    ClearOverrideBindings(rewardListener)
    rewardListener:Hide()
end

local itemScanTip = CreateFrame("GameTooltip", "QuestZombieItemScanTooltip", nil, "GameTooltipTemplate")
itemScanTip:SetOwner(WorldFrame, "ANCHOR_NONE")

local function GetWeaponInfoFromLink(link)
    if not link then
        return nil, nil, nil
    end

    itemScanTip:ClearLines()
    itemScanTip:SetHyperlink(link)

    local speed, minDamage, maxDamage

    for i = 2, itemScanTip:NumLines() do
        local leftText = _G["QuestZombieItemScanTooltipTextLeft" .. i]
        if leftText then
            local text = leftText:GetText()
            if text and text ~= "" then
                local lower = string.lower(text)

                if not speed and string.find(lower, "speed") then
                    local s = string.match(lower, "([0-9]+%.?[0-9]*)")
                    if s then
                        speed = tonumber(s)
                    end
                end

                if not minDamage then
                    local a, b = string.match(lower, "(%d+)%s*%-%s*(%d+)%s+damage")
                    if a and b then
                        minDamage = tonumber(a)
                        maxDamage = tonumber(b)
                    end
                end
            end
        end
    end

    itemScanTip:Hide()
    return speed, minDamage, maxDamage
end

local function IsMainHandSlot(slotID)
    return slotID == 16
end

local function IsOffHandSlot(slotID)
    return slotID == 17
end

local function ScoreTowardsTargetSpeed(actualSpeed, targetSpeed, weight)
    if not actualSpeed or not targetSpeed or not weight or weight <= 0 then
        return 0
    end

    local diff = math.abs(actualSpeed - targetSpeed)
    return math.floor(weight - (diff * weight * 1.25))
end

local function GetQuestChoiceLink(index)
    local link = GetQuestItemLink("choice", index)
    if link then
        return link
    end
    return nil
end

local function GetRewardMeta(index)
    local link = GetQuestChoiceLink(index)
    local name, texture, numItems, quality, isUsable = GetQuestItemInfo("choice", index)

    local itemName, itemQuality, itemLevel, itemType, itemSubType, equipLoc, sellPrice
    local stats = nil
    local isCached = false
    local weaponSpeed, weaponMinDamage, weaponMaxDamage = nil, nil, nil

    if link then
        itemName, _, itemQuality, itemLevel, _, itemType, itemSubType, _, equipLoc, _, sellPrice = GetItemInfo(link)
        stats = GetItemStats(link)

        if itemName then
            isCached = true
            weaponSpeed, weaponMinDamage, weaponMaxDamage = GetWeaponInfoFromLink(link)
        end
    end

    return {
        index = index,
        link = link,
        name = itemName or name,
        quality = itemQuality or quality or 0,
        itemLevel = itemLevel or 0,
        itemType = itemType,
        itemSubType = itemSubType,
        equipLoc = equipLoc,
        sellPrice = sellPrice or 0,
        isUsable = isUsable and true or false,
        stats = stats,
        isCached = isCached,
        weaponSpeed = weaponSpeed,
        weaponMinDamage = weaponMinDamage,
        weaponMaxDamage = weaponMaxDamage,
    }
end

local function IsHunterRangedWeapon(meta)
    if not meta then return false end
    if meta.equipLoc == "INVTYPE_RANGED" or meta.equipLoc == "INVTYPE_RANGEDRIGHT" then
        return true
    end
    if meta.itemType == "Weapon" then
        if meta.itemSubType == "Bows" or meta.itemSubType == "Guns" or meta.itemSubType == "Crossbows" or meta.itemSubType == "Thrown" then
            return true
        end
    end
    return false
end

local function IsHunterTwoHandMelee(meta)
    if not meta then return false end
    if meta.itemType ~= "Weapon" then return false end
    if meta.itemSubType == "Polearms" or meta.itemSubType == "Staves" or meta.itemSubType == "Two-Handed Axes" or meta.itemSubType == "Two-Handed Swords" or meta.itemSubType == "Two-Handed Maces" then
        return true
    end
    return false
end

local function IsHunterOneHandMelee(meta)
    if not meta then return false end
    if meta.itemType ~= "Weapon" then return false end
    if meta.itemSubType == "Axes" or meta.itemSubType == "Swords" or meta.itemSubType == "Daggers" or meta.itemSubType == "Fist Weapons" or meta.itemSubType == "Maces" then
        return true
    end
    return false
end

local function GetArmorBonusForHunter(meta, profile)
    if not meta or meta.itemType ~= "Armor" then
        return 0
    end

    local level = UnitLevel("player")
    local sub = meta.itemSubType
    local equipLoc = meta.equipLoc or ""

    if equipLoc == "INVTYPE_CLOAK" then
        return 6000
    end

    if sub == "Mail" then
        if level >= 40 then
            return 14000
        end
        return 9000
    end

    if sub == "Leather" then
        if profile == "hunter_leveling" and level < 40 then
            return 11000
        end
        return 5000
    end

    if sub == "Cloth" then
        return 1000
    end

    if sub == "Shields" then
        return -50000
    end

    return 4000
end

local function IsRogueDagger(meta)
    return meta and meta.itemType == "Weapon" and meta.itemSubType == "Daggers"
end

local function GetHunterRangedWeaponDPS(meta)
    if not meta or not IsHunterRangedWeapon(meta) then
        return 0
    end

    if meta.weaponMinDamage and meta.weaponMaxDamage and meta.weaponSpeed and meta.weaponSpeed > 0 then
        local avgDamage = (meta.weaponMinDamage + meta.weaponMaxDamage) / 2
        return avgDamage / meta.weaponSpeed
    end

    return 0
end

local function GetHunterWeaponSpeedScore(meta, profile)
    if not meta or not IsHunterRangedWeapon(meta) then
        return 0
    end

    local speed = meta.weaponSpeed
    if not speed then
        return 0
    end

    local score = 0

    if profile == "hunter_leveling" then
        score = score + ScoreTowardsTargetSpeed(speed, 2.8, 1200)
    elseif profile == "hunter_bm" then
        score = score + ScoreTowardsTargetSpeed(speed, 2.8, 1400)
    elseif profile == "hunter_mm" then
        score = score + ScoreTowardsTargetSpeed(speed, 3.0, 1800)
    elseif profile == "hunter_sv" then
        score = score + ScoreTowardsTargetSpeed(speed, 2.9, 1600)
    end

    return score
end

local function IsRogueCombatWeapon(meta)
    if not meta or meta.itemType ~= "Weapon" then
        return false
    end

    return meta.itemSubType == "Swords"
        or meta.itemSubType == "Axes"
        or meta.itemSubType == "Maces"
        or meta.itemSubType == "Fist Weapons"
end

local function IsRogueRangedStatStick(meta)
    if not meta then return false end

    if meta.equipLoc == "INVTYPE_RANGED" or meta.equipLoc == "INVTYPE_RANGEDRIGHT" or meta.equipLoc == "INVTYPE_THROWN" then
        return true
    end

    if meta.itemType == "Weapon" then
        return meta.itemSubType == "Bows"
            or meta.itemSubType == "Crossbows"
            or meta.itemSubType == "Guns"
            or meta.itemSubType == "Thrown"
    end

    return false
end

local function GetArmorBonusForRogue(meta)
    if not meta or meta.itemType ~= "Armor" then
        return 0
    end

    local sub = meta.itemSubType
    local equipLoc = meta.equipLoc or ""

    if equipLoc == "INVTYPE_CLOAK" then
        return 6500
    end

    if sub == "Leather" then
        return 15000
    end

    if sub == "Cloth" then
        return 1500
    end

    if sub == "Mail" or sub == "Plate" or sub == "Shields" then
        return -50000
    end

    return 3000
end

local function IsWarriorShield(meta)
    if not meta then
        return false
    end

    if meta.equipLoc == "INVTYPE_SHIELD" then
        return true
    end

    if meta.itemType == "Armor" and meta.itemSubType == "Shields" then
        return true
    end

    return false
end

local function IsWarriorRangedStatStick(meta)
    if not meta then
        return false
    end

    return meta.equipLoc == "INVTYPE_RANGED"
        or meta.equipLoc == "INVTYPE_RANGEDRIGHT"
        or meta.equipLoc == "INVTYPE_THROWN"
        or meta.equipLoc == "INVTYPE_RELIC"
end

local function IsWarriorTwoHandWeapon(meta)
    if not meta or meta.itemType ~= "Weapon" then
        return false
    end

    return meta.equipLoc == "INVTYPE_2HWEAPON"
        or meta.itemSubType == "Two-Handed Axes"
        or meta.itemSubType == "Two-Handed Maces"
        or meta.itemSubType == "Two-Handed Swords"
        or meta.itemSubType == "Polearms"
        or meta.itemSubType == "Staves"
end

local function IsWarriorOneHandWeapon(meta)
    if not meta or meta.itemType ~= "Weapon" then
        return false
    end

    return meta.equipLoc == "INVTYPE_WEAPON"
        or meta.equipLoc == "INVTYPE_WEAPONMAINHAND"
        or meta.equipLoc == "INVTYPE_WEAPONOFFHAND"
        or meta.itemSubType == "Axes"
        or meta.itemSubType == "Maces"
        or meta.itemSubType == "Swords"
        or meta.itemSubType == "Daggers"
        or meta.itemSubType == "Fist Weapons"
end

local function IsWarriorMeleeWeapon(meta)
    return IsWarriorOneHandWeapon(meta) or IsWarriorTwoHandWeapon(meta)
end

local function GetArmorBonusForWarrior(meta, profile)
    if not meta or meta.itemType ~= "Armor" then
        return 0
    end

    local sub = meta.itemSubType
    local equipLoc = meta.equipLoc or ""
    local level = UnitLevel("player")

    if equipLoc == "INVTYPE_CLOAK" then
        return 6000
    end

    if IsWarriorShield(meta) then
        if profile == "warrior_prot" then
            return 32000
        end
        return -22000
    end

    if sub == "Plate" then
        if level >= 40 then
            return 15000
        end
        return 9000
    end

    if sub == "Mail" then
        if level < 40 then
            return 11000
        end
        if profile == "warrior_leveling" then
            return 4500
        end
        return 2500
    end

    if sub == "Leather" then
        if profile == "warrior_leveling" and level < 40 then
            return 5000
        end
        return 1000
    end

    if sub == "Cloth" then
        return 250
    end

    return 2500
end

local function IsPaladinShield(meta)
    if not meta then
        return false
    end

    if meta.equipLoc == "INVTYPE_SHIELD" then
        return true
    end

    if meta.itemType == "Armor" and meta.itemSubType == "Shields" then
        return true
    end

    return false
end

local function IsPaladinTwoHandWeapon(meta)
    if not meta or meta.itemType ~= "Weapon" then
        return false
    end

    return meta.equipLoc == "INVTYPE_2HWEAPON"
        or meta.itemSubType == "Two-Handed Axes"
        or meta.itemSubType == "Two-Handed Maces"
        or meta.itemSubType == "Two-Handed Swords"
        or meta.itemSubType == "Polearms"
        or meta.itemSubType == "Staves"
end

local function IsPaladinOneHandWeapon(meta)
    if not meta or meta.itemType ~= "Weapon" then
        return false
    end

    return meta.equipLoc == "INVTYPE_WEAPON"
        or meta.equipLoc == "INVTYPE_WEAPONMAINHAND"
        or meta.equipLoc == "INVTYPE_WEAPONOFFHAND"
        or meta.itemSubType == "Axes"
        or meta.itemSubType == "Maces"
        or meta.itemSubType == "Swords"
end

local function IsPaladinCasterWeapon(meta)
    if not IsPaladinOneHandWeapon(meta) then
        return false
    end

    if not meta.stats then
        return false
    end

    return (meta.stats.ITEM_MOD_INTELLECT_SHORT or 0) > 0
        or (meta.stats.ITEM_MOD_SPELL_POWER_SHORT or 0) > 0
        or (meta.stats.ITEM_MOD_MP5_SHORT or 0) > 0
        or (meta.stats.ITEM_MOD_MANA_REGENERATION_SHORT or 0) > 0
end

local function IsPaladinCasterShield(meta)
    if not IsPaladinShield(meta) then
        return false
    end

    if not meta.stats then
        return false
    end

    return (meta.stats.ITEM_MOD_INTELLECT_SHORT or 0) > 0
        or (meta.stats.ITEM_MOD_SPELL_POWER_SHORT or 0) > 0
        or (meta.stats.ITEM_MOD_MP5_SHORT or 0) > 0
        or (meta.stats.ITEM_MOD_MANA_REGENERATION_SHORT or 0) > 0
end

local function IsPaladinHolyCasterItem(meta)
    if not meta then
        return false
    end

    if meta.stats and (
        (meta.stats.ITEM_MOD_INTELLECT_SHORT or 0) > 0
        or (meta.stats.ITEM_MOD_SPELL_POWER_SHORT or 0) > 0
        or (meta.stats.ITEM_MOD_MP5_SHORT or 0) > 0
        or (meta.stats.ITEM_MOD_MANA_REGENERATION_SHORT or 0) > 0
    ) then
        return true
    end

    return false
end

local function IsPaladinRelic(meta)
    return meta and meta.equipLoc == "INVTYPE_RELIC"
end

local function GetArmorBonusForPaladin(meta, profile)
    if not meta or meta.itemType ~= "Armor" then
        return 0
    end

    local sub = meta.itemSubType
    local equipLoc = meta.equipLoc or ""
    local level = UnitLevel("player")

    if equipLoc == "INVTYPE_CLOAK" then
        return 6000
    end

    if IsPaladinShield(meta) then
        if profile == "paladin_prot" then
            return 32000
        elseif profile == "paladin_holy" then
            return 18000
        end
        return -20000
    end

    if sub == "Plate" then
        if level >= 40 then
            return 15000
        end
        return 9000
    end

    if sub == "Mail" then
        if level < 40 then
            return 11000
        end
        if profile == "paladin_holy" then
            return 4000
        end
        return 2500
    end

    if sub == "Leather" then
        if profile == "paladin_holy" then
            return 2500
        end
        if profile == "paladin_leveling" and level < 40 then
            return 4500
        end
        return 1000
    end

    if sub == "Cloth" then
        if profile == "paladin_holy" then
            return 1500
        end
        return 250
    end

    return 2500
end

local function GetStatWeights(profile)
    if profile == "hunter_bm" then
        return {
            ITEM_MOD_AGILITY_SHORT = 11,
            ITEM_MOD_RANGED_ATTACK_POWER_SHORT = 10,
            ITEM_MOD_ATTACK_POWER_SHORT = 9,
            ITEM_MOD_HIT_RATING_SHORT = 12,
            ITEM_MOD_CRIT_RATING_SHORT = 8,
            ITEM_MOD_ARMOR_PENETRATION_RATING_SHORT = 5,
            ITEM_MOD_HASTE_RATING_SHORT = 4,
            ITEM_MOD_STAMINA_SHORT = 1,
            ITEM_MOD_INTELLECT_SHORT = 2,
        }
    elseif profile == "hunter_mm" then
        return {
            ITEM_MOD_AGILITY_SHORT = 11,
            ITEM_MOD_RANGED_ATTACK_POWER_SHORT = 7,
            ITEM_MOD_ATTACK_POWER_SHORT = 7,
            ITEM_MOD_HIT_RATING_SHORT = 12,
            ITEM_MOD_CRIT_RATING_SHORT = 8,
            ITEM_MOD_ARMOR_PENETRATION_RATING_SHORT = 10,
            ITEM_MOD_HASTE_RATING_SHORT = 4,
            ITEM_MOD_STAMINA_SHORT = 1,
            ITEM_MOD_INTELLECT_SHORT = 1,
        }
    elseif profile == "hunter_sv" then
        return {
            ITEM_MOD_AGILITY_SHORT = 11,
            ITEM_MOD_RANGED_ATTACK_POWER_SHORT = 8,
            ITEM_MOD_ATTACK_POWER_SHORT = 8,
            ITEM_MOD_HIT_RATING_SHORT = 12,
            ITEM_MOD_CRIT_RATING_SHORT = 10,
            ITEM_MOD_ARMOR_PENETRATION_RATING_SHORT = 4,
            ITEM_MOD_HASTE_RATING_SHORT = 5,
            ITEM_MOD_STAMINA_SHORT = 2,
            ITEM_MOD_INTELLECT_SHORT = 1,
        }
    elseif profile == "hunter_leveling" then
        return {
            ITEM_MOD_AGILITY_SHORT = 10,
            ITEM_MOD_RANGED_ATTACK_POWER_SHORT = 8,
            ITEM_MOD_ATTACK_POWER_SHORT = 7,
            ITEM_MOD_HIT_RATING_SHORT = 5,
            ITEM_MOD_CRIT_RATING_SHORT = 6,
            ITEM_MOD_ARMOR_PENETRATION_RATING_SHORT = 1,
            ITEM_MOD_HASTE_RATING_SHORT = 2,
            ITEM_MOD_STAMINA_SHORT = 3,
            ITEM_MOD_INTELLECT_SHORT = 1,
        }
    elseif profile == "rogue_ass" then
        return {
            ITEM_MOD_HIT_RATING_SHORT = 12,
            ITEM_MOD_EXPERTISE_RATING_SHORT = 11,
            ITEM_MOD_AGILITY_SHORT = 10,
            ITEM_MOD_ATTACK_POWER_SHORT = 8,
            ITEM_MOD_STRENGTH_SHORT = 5,
            ITEM_MOD_HASTE_RATING_SHORT = 7,
            ITEM_MOD_CRIT_RATING_SHORT = 4,
            ITEM_MOD_ARMOR_PENETRATION_RATING_SHORT = 2,
            ITEM_MOD_STAMINA_SHORT = 1,
        }
    elseif profile == "rogue_combat" then
        return {
            ITEM_MOD_HIT_RATING_SHORT = 12,
            ITEM_MOD_EXPERTISE_RATING_SHORT = 11,
            ITEM_MOD_AGILITY_SHORT = 10,
            ITEM_MOD_ATTACK_POWER_SHORT = 8,
            ITEM_MOD_STRENGTH_SHORT = 5,
            ITEM_MOD_ARMOR_PENETRATION_RATING_SHORT = 7,
            ITEM_MOD_HASTE_RATING_SHORT = 5,
            ITEM_MOD_CRIT_RATING_SHORT = 4,
            ITEM_MOD_STAMINA_SHORT = 1,
        }
    elseif profile == "rogue_sub" then
        return {
            ITEM_MOD_HIT_RATING_SHORT = 12,
            ITEM_MOD_EXPERTISE_RATING_SHORT = 11,
            ITEM_MOD_AGILITY_SHORT = 10,
            ITEM_MOD_ATTACK_POWER_SHORT = 8,
            ITEM_MOD_STRENGTH_SHORT = 5,
            ITEM_MOD_ARMOR_PENETRATION_RATING_SHORT = 6,
            ITEM_MOD_HASTE_RATING_SHORT = 4,
            ITEM_MOD_CRIT_RATING_SHORT = 5,
            ITEM_MOD_STAMINA_SHORT = 1,
        }
    elseif profile == "rogue_leveling" then
        return {
            ITEM_MOD_AGILITY_SHORT = 10,
            ITEM_MOD_ATTACK_POWER_SHORT = 8,
            ITEM_MOD_STRENGTH_SHORT = 5,
            ITEM_MOD_HIT_RATING_SHORT = 4,
            ITEM_MOD_EXPERTISE_RATING_SHORT = 3,
            ITEM_MOD_CRIT_RATING_SHORT = 5,
            ITEM_MOD_HASTE_RATING_SHORT = 3,
            ITEM_MOD_ARMOR_PENETRATION_RATING_SHORT = 2,
            ITEM_MOD_STAMINA_SHORT = 3,
        }
    elseif profile == "warrior_arms" then
        return {
            ITEM_MOD_STRENGTH_SHORT = 12,
            ITEM_MOD_HIT_RATING_SHORT = 11,
            ITEM_MOD_ARMOR_PENETRATION_RATING_SHORT = 10,
            ITEM_MOD_CRIT_RATING_SHORT = 9,
            ITEM_MOD_EXPERTISE_RATING_SHORT = 8,
            ITEM_MOD_ATTACK_POWER_SHORT = 7,
            ITEM_MOD_HASTE_RATING_SHORT = 4,
            ITEM_MOD_AGILITY_SHORT = 3,
            ITEM_MOD_STAMINA_SHORT = 3,
        }
    elseif profile == "warrior_fury" then
        return {
            ITEM_MOD_STRENGTH_SHORT = 11,
            ITEM_MOD_HIT_RATING_SHORT = 12,
            ITEM_MOD_EXPERTISE_RATING_SHORT = 10,
            ITEM_MOD_CRIT_RATING_SHORT = 8,
            ITEM_MOD_ARMOR_PENETRATION_RATING_SHORT = 8,
            ITEM_MOD_HASTE_RATING_SHORT = 7,
            ITEM_MOD_ATTACK_POWER_SHORT = 7,
            ITEM_MOD_AGILITY_SHORT = 3,
            ITEM_MOD_STAMINA_SHORT = 3,
        }
    elseif profile == "warrior_prot" then
        return {
            ITEM_MOD_STAMINA_SHORT = 12,
            ITEM_MOD_DEFENSE_SKILL_RATING_SHORT = 12,
            ITEM_MOD_DODGE_RATING_SHORT = 10,
            ITEM_MOD_PARRY_RATING_SHORT = 10,
            ITEM_MOD_BLOCK_RATING_SHORT = 9,
            ITEM_MOD_BLOCK_VALUE_SHORT = 9,
            ITEM_MOD_STRENGTH_SHORT = 6,
            ITEM_MOD_EXPERTISE_RATING_SHORT = 5,
            ITEM_MOD_HIT_RATING_SHORT = 5,
            ITEM_MOD_AGILITY_SHORT = 4,
        }
    elseif profile == "warrior_leveling" then
        return {
            ITEM_MOD_STRENGTH_SHORT = 10,
            ITEM_MOD_ATTACK_POWER_SHORT = 8,
            ITEM_MOD_CRIT_RATING_SHORT = 7,
            ITEM_MOD_HIT_RATING_SHORT = 4,
            ITEM_MOD_HASTE_RATING_SHORT = 3,
            ITEM_MOD_AGILITY_SHORT = 2,
            ITEM_MOD_STAMINA_SHORT = 5,
        }
    elseif profile == "paladin_ret" then
        return {
            ITEM_MOD_STRENGTH_SHORT = 12,
            ITEM_MOD_HIT_RATING_SHORT = 11,
            ITEM_MOD_EXPERTISE_RATING_SHORT = 10,
            ITEM_MOD_CRIT_RATING_SHORT = 8,
            ITEM_MOD_ATTACK_POWER_SHORT = 7,
            ITEM_MOD_HASTE_RATING_SHORT = 6,
            ITEM_MOD_ARMOR_PENETRATION_RATING_SHORT = 5,
            ITEM_MOD_AGILITY_SHORT = 3,
            ITEM_MOD_STAMINA_SHORT = 3,
        }
    elseif profile == "paladin_prot" then
        return {
            ITEM_MOD_DEFENSE_SKILL_RATING_SHORT = 12,
            ITEM_MOD_STAMINA_SHORT = 12,
            ITEM_MOD_STRENGTH_SHORT = 8,
            ITEM_MOD_HIT_RATING_SHORT = 7,
            ITEM_MOD_EXPERTISE_RATING_SHORT = 7,
            ITEM_MOD_DODGE_RATING_SHORT = 10,
            ITEM_MOD_PARRY_RATING_SHORT = 9,
            ITEM_MOD_BLOCK_RATING_SHORT = 10,
            ITEM_MOD_BLOCK_VALUE_SHORT = 10,
            ITEM_MOD_AGILITY_SHORT = 4,
        }
    elseif profile == "paladin_holy" then
        return {
            ITEM_MOD_INTELLECT_SHORT = 12,
            ITEM_MOD_SPELL_POWER_SHORT = 11,
            ITEM_MOD_HASTE_RATING_SHORT = 10,
            ITEM_MOD_CRIT_RATING_SHORT = 7,
            ITEM_MOD_MANA_REGENERATION_SHORT = 8,
            ITEM_MOD_MP5_SHORT = 8,
            ITEM_MOD_STAMINA_SHORT = 2,
        }
    elseif profile == "paladin_leveling" then
        return {
            ITEM_MOD_STRENGTH_SHORT = 10,
            ITEM_MOD_ATTACK_POWER_SHORT = 8,
            ITEM_MOD_CRIT_RATING_SHORT = 7,
            ITEM_MOD_HIT_RATING_SHORT = 4,
            ITEM_MOD_HASTE_RATING_SHORT = 3,
            ITEM_MOD_AGILITY_SHORT = 2,
            ITEM_MOD_STAMINA_SHORT = 5,
        }
    end

    return nil
end

local function ScoreStats(meta, profile)
    if not meta or not meta.stats then
        return 0
    end

    local weights = GetStatWeights(profile)
    if not weights then
        return 0
    end

    local score = 0

    for statName, value in pairs(meta.stats) do
        local weight = weights[statName]
        if weight then
            score = score + (value * weight)
        end
    end

    return score
end

local function ScoreHunterReward(meta, profile)
    local score = 0

    if not meta then
        return -999999
    end

    if meta.isUsable then
        score = score + 25000
    else
        score = score - 25000
    end

    if IsHunterRangedWeapon(meta) then
        if profile == "hunter_leveling" then
            score = score + 100000
        else
            score = score + 70000
        end

        local rangedDPS = GetHunterRangedWeaponDPS(meta)
        if rangedDPS > 0 then
            score = score + math.floor(rangedDPS * 250)
        end

        score = score + GetHunterWeaponSpeedScore(meta, profile)

    elseif IsHunterTwoHandMelee(meta) then
        score = score + 10000
    elseif IsHunterOneHandMelee(meta) then
        score = score + 3000
    end

    score = score + GetArmorBonusForHunter(meta, profile)
    score = score + ScoreStats(meta, profile)
    score = score + (meta.itemLevel or 0) * 15
    score = score + math.floor((meta.sellPrice or 0) / 100)

    if not meta.link then
        score = score + (meta.quality or 0) * 250
    end

    return score
end

local function GetRogueWeaponSpeedScore(meta, profile, slotID)
    if not meta or meta.itemType ~= "Weapon" or not meta.weaponSpeed then
        return 0
    end

    local speed = meta.weaponSpeed

    if profile == "rogue_ass" then
        if not IsRogueDagger(meta) then
            return 0
        end

        if IsMainHandSlot(slotID) then
            return ScoreTowardsTargetSpeed(speed, 1.8, 2500)
        elseif IsOffHandSlot(slotID) then
            return ScoreTowardsTargetSpeed(speed, 1.4, 9000)
        end

    elseif profile == "rogue_combat" or profile == "rogue_leveling" then
        if IsMainHandSlot(slotID) then
            if meta.itemSubType == "Daggers" then
                return ScoreTowardsTargetSpeed(speed, 1.8, 1500)
            end
            return ScoreTowardsTargetSpeed(speed, 2.6, 11000)
        elseif IsOffHandSlot(slotID) then
            return ScoreTowardsTargetSpeed(speed, 1.4, 10000)
        end

    elseif profile == "rogue_sub" then
        if IsMainHandSlot(slotID) then
            if meta.itemSubType == "Daggers" then
                return ScoreTowardsTargetSpeed(speed, 1.8, 7000)
            end
            return ScoreTowardsTargetSpeed(speed, 2.6, 9000)
        elseif IsOffHandSlot(slotID) then
            return ScoreTowardsTargetSpeed(speed, 1.4, 10000)
        end
    end

    return 0
end

local function GetRogueMainHandDamageBonus(meta, profile, slotID)
    if not meta or meta.itemType ~= "Weapon" or not IsMainHandSlot(slotID) then
        return 0
    end

    local avgDamage = 0
    if meta.weaponMinDamage and meta.weaponMaxDamage then
        avgDamage = (meta.weaponMinDamage + meta.weaponMaxDamage) / 2
    end

    if avgDamage <= 0 then
        return 0
    end

    if profile == "rogue_combat" or profile == "rogue_leveling" then
        return math.floor(avgDamage * 18)
    elseif profile == "rogue_sub" then
        return math.floor(avgDamage * 15)
    elseif profile == "rogue_ass" then
        return math.floor(avgDamage * 8)
    end

    return 0
end

local function IsDualWieldWeaponMeta(meta)
    if not meta or meta.itemType ~= "Weapon" then
        return false
    end

    if meta.equipLoc == "INVTYPE_WEAPON" or meta.equipLoc == "INVTYPE_WEAPONMAINHAND" or meta.equipLoc == "INVTYPE_WEAPONOFFHAND" then
        return true
    end

    return IsRogueDagger(meta) or IsRogueCombatWeapon(meta)
end

local function GetOtherWeaponSlot(slotID)
    if slotID == 16 then
        return 17
    elseif slotID == 17 then
        return 16
    end
    return nil
end

local function IsTwoHandRewardMeta(meta)
    return meta and meta.equipLoc == "INVTYPE_2HWEAPON"
end

local function GetRoguePairingBonus(meta, pairedMeta, profile, slotID)
    if not meta or not pairedMeta then
        return 0
    end

    if not IsDualWieldWeaponMeta(meta) or not IsDualWieldWeaponMeta(pairedMeta) then
        return 0
    end

    local score = 0
    local mySpeed = meta.weaponSpeed
    local otherSpeed = pairedMeta.weaponSpeed

    if profile == "rogue_ass" then
        if not IsRogueDagger(meta) then
            score = score - 25000
        end
        if not IsRogueDagger(pairedMeta) then
            score = score - 25000
        end

        if IsMainHandSlot(slotID) then
            if IsRogueDagger(meta) and IsRogueDagger(pairedMeta) then
                score = score + 9000
            end

            if mySpeed and otherSpeed then
                if mySpeed >= otherSpeed then
                    score = score + 5000
                else
                    score = score - 4000
                end

                score = score + ScoreTowardsTargetSpeed(mySpeed, 1.8, 2500)
                score = score + ScoreTowardsTargetSpeed(otherSpeed, 1.4, 7000)
            end
        elseif IsOffHandSlot(slotID) then
            if IsRogueDagger(meta) and IsRogueDagger(pairedMeta) then
                score = score + 9000
            end

            if mySpeed and otherSpeed then
                if mySpeed <= otherSpeed then
                    score = score + 8000
                else
                    score = score - 7000
                end

                score = score + ScoreTowardsTargetSpeed(mySpeed, 1.4, 9000)
                score = score + ScoreTowardsTargetSpeed(otherSpeed, 1.8, 2500)
            end
        end

    elseif profile == "rogue_combat" or profile == "rogue_leveling" then
        if IsMainHandSlot(slotID) then
            if IsRogueCombatWeapon(meta) then
                score = score + 7000
            elseif IsRogueDagger(meta) then
                score = score - 8000
            end

            if mySpeed and otherSpeed then
                if mySpeed > otherSpeed then
                    score = score + 12000
                else
                    score = score - 9000
                end

                if mySpeed >= 2.4 then
                    score = score + 7000
                end
                if otherSpeed <= 1.6 then
                    score = score + 7000
                end
            end
        elseif IsOffHandSlot(slotID) then
            if IsRogueCombatWeapon(meta) then
                score = score + 5000
            elseif IsRogueDagger(meta) then
                score = score - 6000
            end

            if mySpeed and otherSpeed then
                if mySpeed < otherSpeed then
                    score = score + 12000
                else
                    score = score - 9000
                end

                if mySpeed <= 1.6 then
                    score = score + 9000
                end
                if otherSpeed >= 2.4 then
                    score = score + 7000
                end
            end
        end

    elseif profile == "rogue_sub" then
        if IsMainHandSlot(slotID) then
            if mySpeed and otherSpeed then
                if mySpeed > otherSpeed then
                    score = score + 10000
                else
                    score = score - 8000
                end

                if mySpeed >= 2.4 then
                    score = score + 6000
                end
                if otherSpeed <= 1.6 then
                    score = score + 7000
                end
            end
        elseif IsOffHandSlot(slotID) then
            if mySpeed and otherSpeed then
                if mySpeed < otherSpeed then
                    score = score + 10000
                else
                    score = score - 8000
                end

                if mySpeed <= 1.6 then
                    score = score + 8000
                end
                if otherSpeed >= 2.4 then
                    score = score + 6000
                end
            end
        end
    end

    return score
end

local function ScoreRogueReward(meta, profile, slotID)
    local score = 0

    if not meta then
        return -999999
    end

    if meta.isUsable then
        score = score + 25000
    else
        score = score - 25000
    end

    if profile == "rogue_ass" then
        if IsRogueDagger(meta) then
            score = score + 85000
        elseif IsRogueCombatWeapon(meta) then
            score = score + 12000
        elseif IsRogueRangedStatStick(meta) then
            score = score + 7000
        end

    elseif profile == "rogue_combat" then
        if meta.itemType == "Weapon" then
            if meta.itemSubType == "Swords" or meta.itemSubType == "Axes" then
                score = score + 85000
            elseif meta.itemSubType == "Fist Weapons" or meta.itemSubType == "Maces" then
                score = score + 72000
            elseif meta.itemSubType == "Daggers" then
                score = score + 18000
            end
        elseif IsRogueRangedStatStick(meta) then
            score = score + 7000
        end

    elseif profile == "rogue_sub" then
        if meta.itemType == "Weapon" then
            if meta.itemSubType == "Axes" or meta.itemSubType == "Fist Weapons" then
                score = score + 78000
            elseif meta.itemSubType == "Daggers" then
                score = score + 62000
            elseif meta.itemSubType == "Swords" or meta.itemSubType == "Maces" then
                score = score + 52000
            end
        elseif IsRogueRangedStatStick(meta) then
            score = score + 7000
        end

    elseif profile == "rogue_leveling" then
        if meta.itemType == "Weapon" then
            if IsRogueCombatWeapon(meta) then
                score = score + 90000
                if meta.itemSubType == "Swords" or meta.itemSubType == "Axes" then
                    score = score + 10000
                end
            elseif IsRogueDagger(meta) then
                score = score + 25000
            end
        elseif IsRogueRangedStatStick(meta) then
            score = score + 6000
        end
    end

    score = score + GetArmorBonusForRogue(meta)
    score = score + ScoreStats(meta, profile)
    score = score + (meta.itemLevel or 0) * 15
    score = score + math.floor((meta.sellPrice or 0) / 100)

    score = score + GetRogueWeaponSpeedScore(meta, profile, slotID)
    score = score + GetRogueMainHandDamageBonus(meta, profile, slotID)

    if not meta.link then
        score = score + (meta.quality or 0) * 250
    end

    return score
end

local function GetWarriorWeaponSpeedScore(meta, profile, slotID)
    if not meta or meta.itemType ~= "Weapon" or not meta.weaponSpeed then
        return 0
    end

    local speed = meta.weaponSpeed
    local canTG = CanUseTitansGrip()

    if profile == "warrior_arms" or profile == "warrior_leveling" then
        if IsWarriorTwoHandWeapon(meta) then
            return ScoreTowardsTargetSpeed(speed, 3.5, 12000)
        elseif IsWarriorOneHandWeapon(meta) and IsMainHandSlot(slotID) then
            return ScoreTowardsTargetSpeed(speed, 2.6, 2500)
        end

    elseif profile == "warrior_fury" then
        if canTG then
            if IsWarriorTwoHandWeapon(meta) then
                return ScoreTowardsTargetSpeed(speed, 3.4, 10000)
            elseif IsWarriorOneHandWeapon(meta) then
                return ScoreTowardsTargetSpeed(speed, 2.6, 6500)
            end
        else
            if IsWarriorOneHandWeapon(meta) then
                return ScoreTowardsTargetSpeed(speed, 2.6, 8500)
            elseif IsWarriorTwoHandWeapon(meta) then
                return ScoreTowardsTargetSpeed(speed, 3.5, 1500)
            end
        end

    elseif profile == "warrior_prot" then
        if IsWarriorOneHandWeapon(meta) and IsMainHandSlot(slotID) then
            return ScoreTowardsTargetSpeed(speed, 1.6, 3000)
        end
    end

    return 0
end

local function GetWarriorMainHandDamageBonus(meta, profile, slotID)
    if not meta or meta.itemType ~= "Weapon" then
        return 0
    end

    if not IsMainHandSlot(slotID) then
        return 0
    end

    if not meta.weaponMinDamage or not meta.weaponMaxDamage then
        return 0
    end

    local avgDamage = (meta.weaponMinDamage + meta.weaponMaxDamage) / 2
    if avgDamage <= 0 then
        return 0
    end

    if profile == "warrior_arms" or profile == "warrior_leveling" then
        if IsWarriorTwoHandWeapon(meta) then
            return math.floor(avgDamage * 22)
        elseif IsWarriorOneHandWeapon(meta) then
            return math.floor(avgDamage * 8)
        end

    elseif profile == "warrior_fury" then
        if CanUseTitansGrip() then
            if IsWarriorTwoHandWeapon(meta) then
                return math.floor(avgDamage * 16)
            elseif IsWarriorOneHandWeapon(meta) then
                return math.floor(avgDamage * 10)
            end
        else
            if IsWarriorOneHandWeapon(meta) then
                return math.floor(avgDamage * 12)
            elseif IsWarriorTwoHandWeapon(meta) then
                return math.floor(avgDamage * 4)
            end
        end

    elseif profile == "warrior_prot" then
        if IsWarriorOneHandWeapon(meta) then
            return math.floor(avgDamage * 6)
        end
    end

    return 0
end

local function GetWarriorPairingBonus(meta, pairedMeta, profile, slotID)
    if not meta then
        return 0
    end

    local score = 0

    if profile == "warrior_arms" or profile == "warrior_leveling" then
        if IsWarriorTwoHandWeapon(meta) then
            score = score + 12000
            if pairedMeta and IsWarriorShield(pairedMeta) then
                score = score + 1000
            end
        elseif IsWarriorOneHandWeapon(meta) then
            if pairedMeta and IsWarriorShield(pairedMeta) then
                score = score - 5000
            else
                score = score - 10000
            end
        elseif IsWarriorShield(meta) then
            score = score - 18000
        end

        return score
    end

    if profile == "warrior_fury" then
        local canTG = CanUseTitansGrip()

        if not pairedMeta then
            if canTG then
                if IsWarriorTwoHandWeapon(meta) then
                    return 5000
                elseif IsWarriorOneHandWeapon(meta) then
                    return 3000
                end
            else
                if IsWarriorOneHandWeapon(meta) then
                    return 5000
                elseif IsWarriorTwoHandWeapon(meta) then
                    return -12000
                end
            end
            return 0
        end

        local myIs1H = IsWarriorOneHandWeapon(meta)
        local myIs2H = IsWarriorTwoHandWeapon(meta)
        local otherIs1H = IsWarriorOneHandWeapon(pairedMeta)
        local otherIs2H = IsWarriorTwoHandWeapon(pairedMeta)

        if not (myIs1H or myIs2H) then
            return 0
        end
        if not (otherIs1H or otherIs2H) then
            return -25000
        end

        if canTG then
            if myIs2H and otherIs2H then
                score = score + 22000
            elseif myIs1H and otherIs1H then
                score = score + 15000
            else
                score = score - 18000
            end

            if meta.weaponSpeed and pairedMeta.weaponSpeed then
                if myIs2H and otherIs2H then
                    score = score + ScoreTowardsTargetSpeed(meta.weaponSpeed, 3.4, 4500)
                    score = score + ScoreTowardsTargetSpeed(pairedMeta.weaponSpeed, 3.4, 3000)
                elseif myIs1H and otherIs1H then
                    score = score + ScoreTowardsTargetSpeed(meta.weaponSpeed, 2.6, 4000)
                    score = score + ScoreTowardsTargetSpeed(pairedMeta.weaponSpeed, 2.6, 2500)
                end

                if IsMainHandSlot(slotID) then
                    if meta.weaponSpeed >= pairedMeta.weaponSpeed then
                        score = score + 2500
                    else
                        score = score - 1500
                    end
                elseif IsOffHandSlot(slotID) then
                    if meta.weaponSpeed <= pairedMeta.weaponSpeed + 0.3 then
                        score = score + 1500
                    end
                end
            end
        else
            if myIs1H and otherIs1H then
                score = score + 22000
            elseif myIs2H and otherIs2H then
                score = score - 26000
            elseif myIs2H or otherIs2H then
                score = score - 22000
            end

            if meta.weaponSpeed and pairedMeta.weaponSpeed and myIs1H and otherIs1H then
                score = score + ScoreTowardsTargetSpeed(meta.weaponSpeed, 2.6, 4000)
                score = score + ScoreTowardsTargetSpeed(pairedMeta.weaponSpeed, 2.6, 2500)

                if IsMainHandSlot(slotID) then
                    if meta.weaponSpeed >= pairedMeta.weaponSpeed then
                        score = score + 2500
                    else
                        score = score - 1500
                    end
                elseif IsOffHandSlot(slotID) then
                    if meta.weaponSpeed <= pairedMeta.weaponSpeed + 0.3 then
                        score = score + 1500
                    end
                end
            end
        end

        return score
    end

    if profile == "warrior_prot" then
        if IsWarriorShield(meta) then
            if pairedMeta and IsWarriorOneHandWeapon(pairedMeta) then
                score = score + 25000
            else
                score = score + 4000
            end
            return score
        end

        if IsWarriorOneHandWeapon(meta) then
            if pairedMeta and IsWarriorShield(pairedMeta) then
                score = score + 22000
            else
                score = score - 15000
            end
            return score
        end

        if IsWarriorTwoHandWeapon(meta) then
            return -40000
        end
    end

    return score
end

local function ScoreWarriorReward(meta, profile, slotID)
    local score = 0
    local canTG = CanUseTitansGrip()

    if not meta then
        return -999999
    end

    if meta.isUsable then
        score = score + 25000
    else
        score = score - 25000
    end

    if profile == "warrior_arms" or profile == "warrior_leveling" then
        if IsWarriorTwoHandWeapon(meta) then
            score = score + 95000
        elseif IsWarriorOneHandWeapon(meta) then
            score = score + 12000
        elseif IsWarriorShield(meta) then
            score = score - 20000
        elseif IsWarriorRangedStatStick(meta) then
            score = score + 6000
        end

    elseif profile == "warrior_fury" then
        if canTG then
            if IsWarriorTwoHandWeapon(meta) then
                score = score + 82000
            elseif IsWarriorOneHandWeapon(meta) then
                score = score + 70000
            elseif IsWarriorShield(meta) then
                score = score - 30000
            elseif IsWarriorRangedStatStick(meta) then
                score = score + 6000
            end
        else
            if IsWarriorOneHandWeapon(meta) then
                score = score + 82000
            elseif IsWarriorTwoHandWeapon(meta) then
                score = score + 14000
            elseif IsWarriorShield(meta) then
                score = score - 30000
            elseif IsWarriorRangedStatStick(meta) then
                score = score + 6000
            end
        end

    elseif profile == "warrior_prot" then
        if IsWarriorShield(meta) then
            score = score + 100000
        elseif IsWarriorOneHandWeapon(meta) then
            score = score + 50000
        elseif IsWarriorTwoHandWeapon(meta) then
            score = score - 30000
        elseif IsWarriorRangedStatStick(meta) then
            score = score + 5000
        end
    end

    score = score + GetArmorBonusForWarrior(meta, profile)
    score = score + ScoreStats(meta, profile)
    score = score + (meta.itemLevel or 0) * 15
    score = score + math.floor((meta.sellPrice or 0) / 100)
    score = score + GetWarriorWeaponSpeedScore(meta, profile, slotID)
    score = score + GetWarriorMainHandDamageBonus(meta, profile, slotID)

    if not meta.link then
        score = score + (meta.quality or 0) * 250
    end

    return score
end

local function GetPaladinWeaponSpeedScore(meta, profile, slotID)
    if not meta or meta.itemType ~= "Weapon" or not meta.weaponSpeed then
        return 0
    end

    local speed = meta.weaponSpeed

    if profile == "paladin_ret" or profile == "paladin_leveling" then
        if IsPaladinTwoHandWeapon(meta) then
            return ScoreTowardsTargetSpeed(speed, 3.5, 9000)
        elseif IsPaladinOneHandWeapon(meta) and IsMainHandSlot(slotID) then
            return ScoreTowardsTargetSpeed(speed, 2.6, 1500)
        end
    elseif profile == "paladin_prot" then
        if IsPaladinOneHandWeapon(meta) and IsMainHandSlot(slotID) then
            return ScoreTowardsTargetSpeed(speed, 1.8, 2500)
        end
    elseif profile == "paladin_holy" then
        if IsPaladinCasterWeapon(meta) and IsMainHandSlot(slotID) then
            return ScoreTowardsTargetSpeed(speed, 1.8, 1200)
        end
    end

    return 0
end

local function GetPaladinMainHandDamageBonus(meta, profile, slotID)
    if not meta or meta.itemType ~= "Weapon" then
        return 0
    end

    if not IsMainHandSlot(slotID) then
        return 0
    end

    if not meta.weaponMinDamage or not meta.weaponMaxDamage then
        return 0
    end

    local avgDamage = (meta.weaponMinDamage + meta.weaponMaxDamage) / 2
    if avgDamage <= 0 then
        return 0
    end

    if profile == "paladin_ret" or profile == "paladin_leveling" then
        if IsPaladinTwoHandWeapon(meta) then
            return math.floor(avgDamage * 18)
        elseif IsPaladinOneHandWeapon(meta) then
            return math.floor(avgDamage * 6)
        end
    elseif profile == "paladin_prot" then
        if IsPaladinOneHandWeapon(meta) then
            return math.floor(avgDamage * 5)
        end
    end

    return 0
end

local function GetPaladinPairingBonus(meta, pairedMeta, profile, slotID)
    if not meta then
        return 0
    end

    local score = 0

    if profile == "paladin_ret" or profile == "paladin_leveling" then
        if IsPaladinTwoHandWeapon(meta) then
            score = score + 11000
        elseif IsPaladinOneHandWeapon(meta) then
            if pairedMeta and IsPaladinShield(pairedMeta) then
                score = score - 4000
            else
                score = score - 9000
            end
        elseif IsPaladinShield(meta) then
            score = score - 18000
        end
        return score
    end

    if profile == "paladin_prot" then
        if IsPaladinShield(meta) then
            if pairedMeta and IsPaladinOneHandWeapon(pairedMeta) then
                score = score + 24000
            else
                score = score + 5000
            end
            return score
        end

        if IsPaladinOneHandWeapon(meta) then
            if pairedMeta and IsPaladinShield(pairedMeta) then
                score = score + 22000
            else
                score = score - 14000
            end
            return score
        end

        if IsPaladinTwoHandWeapon(meta) then
            return -35000
        end
    end

    if profile == "paladin_holy" then
        if IsPaladinCasterWeapon(meta) then
            if pairedMeta and IsPaladinCasterShield(pairedMeta) then
                score = score + 16000
            else
                score = score + 4000
            end
            return score
        end

        if IsPaladinCasterShield(meta) then
            if pairedMeta and IsPaladinCasterWeapon(pairedMeta) then
                score = score + 18000
            else
                score = score + 5000
            end
            return score
        end

        if IsPaladinShield(meta) and not IsPaladinCasterShield(meta) then
            return -8000
        end

        if IsPaladinTwoHandWeapon(meta) then
            return -22000
        end
    end

    return score
end

local function ScorePaladinReward(meta, profile, slotID)
    local score = 0

    if not meta then
        return -999999
    end

    if meta.isUsable then
        score = score + 25000
    else
        score = score - 25000
    end

    if profile == "paladin_ret" or profile == "paladin_leveling" then
        if IsPaladinTwoHandWeapon(meta) then
            score = score + 93000
        elseif IsPaladinOneHandWeapon(meta) then
            score = score + 15000
        elseif IsPaladinShield(meta) then
            score = score - 20000
        elseif IsPaladinRelic(meta) then
            score = score + 7000
        end

    elseif profile == "paladin_prot" then
        if IsPaladinShield(meta) then
            score = score + 98000
        elseif IsPaladinOneHandWeapon(meta) then
            score = score + 50000
        elseif IsPaladinTwoHandWeapon(meta) then
            score = score - 28000
        elseif IsPaladinRelic(meta) then
            score = score + 7000
        end

    elseif profile == "paladin_holy" then
        if IsPaladinCasterWeapon(meta) then
            score = score + 70000
        elseif IsPaladinCasterShield(meta) then
            score = score + 76000
        elseif IsPaladinTwoHandWeapon(meta) or IsPaladinOneHandWeapon(meta) then
            score = score - 18000
        elseif IsPaladinRelic(meta) then
            score = score + 6000
        end

        if IsPaladinHolyCasterItem(meta) then
            score = score + 22000
        end
    end

    score = score + GetArmorBonusForPaladin(meta, profile)
    score = score + ScoreStats(meta, profile)
    score = score + (meta.itemLevel or 0) * 15
    score = score + math.floor((meta.sellPrice or 0) / 100)
    score = score + GetPaladinWeaponSpeedScore(meta, profile, slotID)
    score = score + GetPaladinMainHandDamageBonus(meta, profile, slotID)

    if not meta.link then
        score = score + (meta.quality or 0) * 250
    end

    return score
end

local function ScoreVendorReward(meta)
    if not meta then
        return -999999
    end

    local score = 0
    score = score + (meta.sellPrice or 0) * 10
    score = score + (meta.quality or 0) * 1000

    if meta.isUsable then
        score = score + 10
    end

    return score
end

local SLOT_BY_EQUIPLOC = {
    INVTYPE_HEAD = 1,
    INVTYPE_NECK = 2,
    INVTYPE_SHOULDER = 3,
    INVTYPE_BODY = 4,
    INVTYPE_CHEST = 5,
    INVTYPE_ROBE = 5,
    INVTYPE_WAIST = 6,
    INVTYPE_LEGS = 7,
    INVTYPE_FEET = 8,
    INVTYPE_WRIST = 9,
    INVTYPE_HAND = 10,
    INVTYPE_CLOAK = 15,
    INVTYPE_SHIELD = 17,
    INVTYPE_2HWEAPON = 16,
    INVTYPE_WEAPONMAINHAND = 16,
    INVTYPE_WEAPONOFFHAND = 17,
    INVTYPE_HOLDABLE = 17,
    INVTYPE_RANGED = 18,
    INVTYPE_RANGEDRIGHT = 18,
    INVTYPE_THROWN = 18,
    INVTYPE_RELIC = 18,
    INVTYPE_TABARD = 19,
}

local MULTI_SLOTS_BY_EQUIPLOC = {
    INVTYPE_FINGER = {11, 12},
    INVTYPE_TRINKET = {13, 14},
    INVTYPE_WEAPON = {16, 17},
}

local function GetEquipSlotsForMeta(meta)
    if not meta or not meta.equipLoc then
        return nil
    end

    local multi = MULTI_SLOTS_BY_EQUIPLOC[meta.equipLoc]
    if multi then
        return multi
    end

    local single = SLOT_BY_EQUIPLOC[meta.equipLoc]
    if single then
        return {single}
    end

    return nil
end

local function GetEquippedMetaForSlot(slotID)
    if not slotID then
        return nil
    end

    local inventoryLink = GetInventoryItemLink("player", slotID)
    if not inventoryLink then
        return nil
    end

    local itemName, _, itemQuality, itemLevel, _, itemType, itemSubType, _, equipLoc, _, sellPrice = GetItemInfo(inventoryLink)
    local stats = GetItemStats(inventoryLink)
    local weaponSpeed, weaponMinDamage, weaponMaxDamage = GetWeaponInfoFromLink(inventoryLink)

    return {
        index = 0,
        link = inventoryLink,
        name = itemName,
        quality = itemQuality or 0,
        itemLevel = itemLevel or 0,
        itemType = itemType,
        itemSubType = itemSubType,
        equipLoc = equipLoc,
        sellPrice = sellPrice or 0,
        isUsable = true,
        stats = stats,
        weaponSpeed = weaponSpeed,
        weaponMinDamage = weaponMinDamage,
        weaponMaxDamage = weaponMaxDamage,
    }
end

local function ScoreMetaForProfile(meta, profile, slotID, pairedMeta)
    if profile == "vendor" then
        return ScoreVendorReward(meta)
    end

    if profile == "hunter_leveling" or profile == "hunter_bm" or profile == "hunter_mm" or profile == "hunter_sv" then
        return ScoreHunterReward(meta, profile)
    end

    if profile == "rogue_leveling" or profile == "rogue_ass" or profile == "rogue_combat" or profile == "rogue_sub" then
        local score = ScoreRogueReward(meta, profile, slotID)
        score = score + GetRoguePairingBonus(meta, pairedMeta, profile, slotID)
        return score
    end

    if profile == "warrior_leveling" or profile == "warrior_arms" or profile == "warrior_fury" or profile == "warrior_prot" then
        local score = ScoreWarriorReward(meta, profile, slotID)
        score = score + GetWarriorPairingBonus(meta, pairedMeta, profile, slotID)
        return score
    end

    if profile == "paladin_leveling" or profile == "paladin_ret" or profile == "paladin_prot" or profile == "paladin_holy" then
        local score = ScorePaladinReward(meta, profile, slotID)
        score = score + GetPaladinPairingBonus(meta, pairedMeta, profile, slotID)
        return score
    end

    return -999999
end

local function GetUpgradeDelta(meta, profile)
    if profile == "vendor" then
        local rewardBreakdown = GetRewardScoreBreakdown(meta, profile, nil, nil)
        local vendorScore = rewardBreakdown.total
        return vendorScore, vendorScore, 0, nil, rewardBreakdown, nil
    end

    local slotIDs = GetEquipSlotsForMeta(meta)
    if not slotIDs or #slotIDs == 0 then
        local rewardBreakdown = GetRewardScoreBreakdown(meta, profile, nil, nil)
        local rewardScore = rewardBreakdown.total
        return rewardScore, rewardScore, 0, nil, rewardBreakdown, nil
    end

    local bestDelta = nil
    local bestRewardScore = nil
    local bestEquippedScore = 0
    local bestSlotID = nil
    local bestRewardBreakdown = nil
    local bestEquippedBreakdown = nil

    for _, slotID in ipairs(slotIDs) do
        local otherSlotID = GetOtherWeaponSlot(slotID)

        local pairedEquippedMeta = nil
        if otherSlotID then
            pairedEquippedMeta = GetEquippedMetaForSlot(otherSlotID)
        end

        local rewardBreakdown = GetRewardScoreBreakdown(meta, profile, slotID, pairedEquippedMeta)
        local rewardScore = rewardBreakdown.total

        local equippedMeta = GetEquippedMetaForSlot(slotID)
        local equippedScore = 0
        local equippedBreakdown = nil

        if equippedMeta then
            equippedBreakdown = GetRewardScoreBreakdown(equippedMeta, profile, slotID, pairedEquippedMeta)
            equippedScore = equippedBreakdown.total
        end

        if IsTwoHandRewardMeta(meta) then
            local offhandMeta = GetEquippedMetaForSlot(17)

            if offhandMeta then
                local offhandBreakdown = GetRewardScoreBreakdown(offhandMeta, profile, 17, equippedMeta)
                equippedScore = equippedScore + offhandBreakdown.total

                if equippedBreakdown then
                    equippedBreakdown = {
                        total = equippedScore,
                        usable = (equippedBreakdown.usable or 0) + (offhandBreakdown.usable or 0),
                        typeBonus = (equippedBreakdown.typeBonus or 0) + (offhandBreakdown.typeBonus or 0),
                        armorBonus = (equippedBreakdown.armorBonus or 0) + (offhandBreakdown.armorBonus or 0),
                        statScore = (equippedBreakdown.statScore or 0) + (offhandBreakdown.statScore or 0),
                        itemLevelScore = (equippedBreakdown.itemLevelScore or 0) + (offhandBreakdown.itemLevelScore or 0),
                        vendorScore = (equippedBreakdown.vendorScore or 0) + (offhandBreakdown.vendorScore or 0),
                        uncachedQualityScore = (equippedBreakdown.uncachedQualityScore or 0) + (offhandBreakdown.uncachedQualityScore or 0),
                        speedScore = (equippedBreakdown.speedScore or 0) + (offhandBreakdown.speedScore or 0),
                        mainHandDamageBonus = (equippedBreakdown.mainHandDamageBonus or 0) + (offhandBreakdown.mainHandDamageBonus or 0),
                        pairingBonus = (equippedBreakdown.pairingBonus or 0) + (offhandBreakdown.pairingBonus or 0),
                    }
                else
                    equippedBreakdown = offhandBreakdown
                end
            end
        end

        local delta = rewardScore - equippedScore

        if bestDelta == nil or delta > bestDelta or (delta == bestDelta and rewardScore > (bestRewardScore or -999999)) then
            bestDelta = delta
            bestRewardScore = rewardScore
            bestEquippedScore = equippedScore
            bestSlotID = slotID
            bestRewardBreakdown = rewardBreakdown
            bestEquippedBreakdown = equippedBreakdown
        end
    end

    return bestDelta or 0, bestRewardScore or 0, bestEquippedScore or 0, bestSlotID, bestRewardBreakdown, bestEquippedBreakdown
end

GetRewardScoreBreakdown = function(meta, profile, slotID, pairedMeta)
    local result = {
        total = -999999,
        usable = 0,
        typeBonus = 0,
        armorBonus = 0,
        statScore = 0,
        itemLevelScore = 0,
        vendorScore = 0,
        uncachedQualityScore = 0,
        speedScore = 0,
        mainHandDamageBonus = 0,
        pairingBonus = 0,
    }

    if not meta then
        return result
    end

    if profile == "vendor" then
        result.total = ScoreVendorReward(meta)
        result.vendorScore = result.total
        return result
    end

    if profile == "hunter_leveling" or profile == "hunter_bm" or profile == "hunter_mm" or profile == "hunter_sv" then
        local total = 0

        if meta.isUsable then
            result.usable = 25000
        else
            result.usable = -25000
        end
        total = total + result.usable

        if IsHunterRangedWeapon(meta) then
            if profile == "hunter_leveling" then
                result.typeBonus = 100000
            else
                result.typeBonus = 70000
            end

            local rangedDPS = GetHunterRangedWeaponDPS(meta)
            if rangedDPS > 0 then
                result.typeBonus = result.typeBonus + math.floor(rangedDPS * 250)
            end

            result.speedScore = GetHunterWeaponSpeedScore(meta, profile)
        elseif IsHunterTwoHandMelee(meta) then
            result.typeBonus = 10000
        elseif IsHunterOneHandMelee(meta) then
            result.typeBonus = 3000
        end
        total = total + result.typeBonus
        total = total + result.speedScore

        result.armorBonus = GetArmorBonusForHunter(meta, profile)
        total = total + result.armorBonus

        result.statScore = ScoreStats(meta, profile)
        total = total + result.statScore

        result.itemLevelScore = (meta.itemLevel or 0) * 15
        total = total + result.itemLevelScore

        result.vendorScore = math.floor((meta.sellPrice or 0) / 100)
        total = total + result.vendorScore

        if not meta.link then
            result.uncachedQualityScore = (meta.quality or 0) * 250
            total = total + result.uncachedQualityScore
        end

        result.total = total
        return result
    end

    if profile == "rogue_leveling" or profile == "rogue_ass" or profile == "rogue_combat" or profile == "rogue_sub" then
        local total = 0

        if meta.isUsable then
            result.usable = 25000
        else
            result.usable = -25000
        end
        total = total + result.usable

        if profile == "rogue_ass" then
            if IsRogueDagger(meta) then
                result.typeBonus = 85000
            elseif IsRogueCombatWeapon(meta) then
                result.typeBonus = 12000
            elseif IsRogueRangedStatStick(meta) then
                result.typeBonus = 7000
            end

        elseif profile == "rogue_combat" then
            if meta.itemType == "Weapon" then
                if meta.itemSubType == "Swords" or meta.itemSubType == "Axes" then
                    result.typeBonus = 85000
                elseif meta.itemSubType == "Fist Weapons" or meta.itemSubType == "Maces" then
                    result.typeBonus = 72000
                elseif meta.itemSubType == "Daggers" then
                    result.typeBonus = 18000
                end
            elseif IsRogueRangedStatStick(meta) then
                result.typeBonus = 7000
            end

        elseif profile == "rogue_sub" then
            if meta.itemType == "Weapon" then
                if meta.itemSubType == "Axes" or meta.itemSubType == "Fist Weapons" then
                    result.typeBonus = 78000
                elseif meta.itemSubType == "Daggers" then
                    result.typeBonus = 62000
                elseif meta.itemSubType == "Swords" or meta.itemSubType == "Maces" then
                    result.typeBonus = 52000
                end
            elseif IsRogueRangedStatStick(meta) then
                result.typeBonus = 7000
            end

        elseif profile == "rogue_leveling" then
            if meta.itemType == "Weapon" then
                if IsRogueCombatWeapon(meta) then
                    result.typeBonus = 90000
                    if meta.itemSubType == "Swords" or meta.itemSubType == "Axes" then
                        result.typeBonus = result.typeBonus + 10000
                    end
                elseif IsRogueDagger(meta) then
                    result.typeBonus = 25000
                end
            elseif IsRogueRangedStatStick(meta) then
                result.typeBonus = 6000
            end
        end
        total = total + result.typeBonus

        result.armorBonus = GetArmorBonusForRogue(meta)
        total = total + result.armorBonus

        result.statScore = ScoreStats(meta, profile)
        total = total + result.statScore

        result.itemLevelScore = (meta.itemLevel or 0) * 15
        total = total + result.itemLevelScore

        result.vendorScore = math.floor((meta.sellPrice or 0) / 100)
        total = total + result.vendorScore

        result.speedScore = GetRogueWeaponSpeedScore(meta, profile, slotID)
        total = total + result.speedScore

        result.mainHandDamageBonus = GetRogueMainHandDamageBonus(meta, profile, slotID)
        total = total + result.mainHandDamageBonus

        result.pairingBonus = GetRoguePairingBonus(meta, pairedMeta, profile, slotID)
        total = total + result.pairingBonus

        if not meta.link then
            result.uncachedQualityScore = (meta.quality or 0) * 250
            total = total + result.uncachedQualityScore
        end

        result.total = total
        return result
    end

    if profile == "warrior_leveling" or profile == "warrior_arms" or profile == "warrior_fury" or profile == "warrior_prot" then
        local total = 0
        local canTG = CanUseTitansGrip()

        if meta.isUsable then
            result.usable = 25000
        else
            result.usable = -25000
        end
        total = total + result.usable

        if profile == "warrior_arms" or profile == "warrior_leveling" then
            if IsWarriorTwoHandWeapon(meta) then
                result.typeBonus = 95000
            elseif IsWarriorOneHandWeapon(meta) then
                result.typeBonus = 12000
            elseif IsWarriorShield(meta) then
                result.typeBonus = -20000
            elseif IsWarriorRangedStatStick(meta) then
                result.typeBonus = 6000
            end

        elseif profile == "warrior_fury" then
            if canTG then
                if IsWarriorTwoHandWeapon(meta) then
                    result.typeBonus = 82000
                elseif IsWarriorOneHandWeapon(meta) then
                    result.typeBonus = 70000
                elseif IsWarriorShield(meta) then
                    result.typeBonus = -30000
                elseif IsWarriorRangedStatStick(meta) then
                    result.typeBonus = 6000
                end
            else
                if IsWarriorOneHandWeapon(meta) then
                    result.typeBonus = 82000
                elseif IsWarriorTwoHandWeapon(meta) then
                    result.typeBonus = 14000
                elseif IsWarriorShield(meta) then
                    result.typeBonus = -30000
                elseif IsWarriorRangedStatStick(meta) then
                    result.typeBonus = 6000
                end
            end

        elseif profile == "warrior_prot" then
            if IsWarriorShield(meta) then
                result.typeBonus = 100000
            elseif IsWarriorOneHandWeapon(meta) then
                result.typeBonus = 50000
            elseif IsWarriorTwoHandWeapon(meta) then
                result.typeBonus = -30000
            elseif IsWarriorRangedStatStick(meta) then
                result.typeBonus = 5000
            end
        end
        total = total + result.typeBonus

        result.armorBonus = GetArmorBonusForWarrior(meta, profile)
        total = total + result.armorBonus

        result.statScore = ScoreStats(meta, profile)
        total = total + result.statScore

        result.itemLevelScore = (meta.itemLevel or 0) * 15
        total = total + result.itemLevelScore

        result.vendorScore = math.floor((meta.sellPrice or 0) / 100)
        total = total + result.vendorScore

        result.speedScore = GetWarriorWeaponSpeedScore(meta, profile, slotID)
        total = total + result.speedScore

        result.mainHandDamageBonus = GetWarriorMainHandDamageBonus(meta, profile, slotID)
        total = total + result.mainHandDamageBonus

        result.pairingBonus = GetWarriorPairingBonus(meta, pairedMeta, profile, slotID)
        total = total + result.pairingBonus

        if not meta.link then
            result.uncachedQualityScore = (meta.quality or 0) * 250
            total = total + result.uncachedQualityScore
        end

        result.total = total
        return result
    end

    if profile == "paladin_leveling" or profile == "paladin_ret" or profile == "paladin_prot" or profile == "paladin_holy" then
        local total = 0

        if meta.isUsable then
            result.usable = 25000
        else
            result.usable = -25000
        end
        total = total + result.usable

        if profile == "paladin_ret" or profile == "paladin_leveling" then
            if IsPaladinTwoHandWeapon(meta) then
                result.typeBonus = 93000
            elseif IsPaladinOneHandWeapon(meta) then
                result.typeBonus = 15000
            elseif IsPaladinShield(meta) then
                result.typeBonus = -20000
            elseif IsPaladinRelic(meta) then
                result.typeBonus = 7000
            end

        elseif profile == "paladin_prot" then
            if IsPaladinShield(meta) then
                result.typeBonus = 98000
            elseif IsPaladinOneHandWeapon(meta) then
                result.typeBonus = 50000
            elseif IsPaladinTwoHandWeapon(meta) then
                result.typeBonus = -28000
            elseif IsPaladinRelic(meta) then
                result.typeBonus = 7000
            end

        elseif profile == "paladin_holy" then
            if IsPaladinCasterWeapon(meta) then
                result.typeBonus = 70000
            elseif IsPaladinCasterShield(meta) then
                result.typeBonus = 76000
            elseif IsPaladinTwoHandWeapon(meta) or IsPaladinOneHandWeapon(meta) then
                result.typeBonus = -18000
            elseif IsPaladinRelic(meta) then
                result.typeBonus = 6000
            end

            if IsPaladinHolyCasterItem(meta) then
                result.typeBonus = result.typeBonus + 22000
            end
        end
        total = total + result.typeBonus

        result.armorBonus = GetArmorBonusForPaladin(meta, profile)
        total = total + result.armorBonus

        result.statScore = ScoreStats(meta, profile)
        total = total + result.statScore

        result.itemLevelScore = (meta.itemLevel or 0) * 15
        total = total + result.itemLevelScore

        result.vendorScore = math.floor((meta.sellPrice or 0) / 100)
        total = total + result.vendorScore

        result.speedScore = GetPaladinWeaponSpeedScore(meta, profile, slotID)
        total = total + result.speedScore

        result.mainHandDamageBonus = GetPaladinMainHandDamageBonus(meta, profile, slotID)
        total = total + result.mainHandDamageBonus

        result.pairingBonus = GetPaladinPairingBonus(meta, pairedMeta, profile, slotID)
        total = total + result.pairingBonus

        if not meta.link then
            result.uncachedQualityScore = (meta.quality or 0) * 250
            total = total + result.uncachedQualityScore
        end

        result.total = total
        return result
    end

    return result
end

local function ChooseSmartReward()
    local profile = GetRewardProfile()
    if not profile then
        return nil, "manual", false
    end

    local numChoices = GetNumQuestChoices()
    if not numChoices or numChoices < 1 then
        return nil, "no choices", false
    end

    local bestIndex = nil
    local bestDelta = nil
    local bestRawScore = nil
    local foundUncached = false

    for i = 1, math.min(numChoices, 10) do
        local meta = GetRewardMeta(i)

        if meta and meta.link and not meta.isCached then
            foundUncached = true
        end

        local delta, rewardScore, equippedScore, slotID, rewardBreakdown, equippedBreakdown = GetUpgradeDelta(meta, profile)

        if rewardBreakdown then
            DebugPrint(
                "choice=" .. i ..
                ", profile=" .. tostring(profile) ..
                ", slot=" .. tostring(slotID) ..
                ", cached=" .. tostring(meta and meta.isCached) ..
                ", item=" .. tostring(meta and meta.name) ..
                ", delta=" .. tostring(delta) ..
                ", rewardTotal=" .. tostring(rewardScore) ..
                ", equippedTotal=" .. tostring(equippedScore) ..
                ", reward[usable=" .. tostring(rewardBreakdown.usable) ..
                ", type=" .. tostring(rewardBreakdown.typeBonus) ..
                ", armor=" .. tostring(rewardBreakdown.armorBonus) ..
                ", stats=" .. tostring(rewardBreakdown.statScore) ..
                ", ilvl=" .. tostring(rewardBreakdown.itemLevelScore) ..
                ", vendor=" .. tostring(rewardBreakdown.vendorScore) ..
                ", speed=" .. tostring(rewardBreakdown.speedScore) ..
                ", mhdmg=" .. tostring(rewardBreakdown.mainHandDamageBonus) ..
                ", pair=" .. tostring(rewardBreakdown.pairingBonus) ..
                ", uncached=" .. tostring(rewardBreakdown.uncachedQualityScore) ..
                "]" ..
                (equippedBreakdown and
                    ", equipped[usable=" .. tostring(equippedBreakdown.usable) ..
                    ", type=" .. tostring(equippedBreakdown.typeBonus) ..
                    ", armor=" .. tostring(equippedBreakdown.armorBonus) ..
                    ", stats=" .. tostring(equippedBreakdown.statScore) ..
                    ", ilvl=" .. tostring(equippedBreakdown.itemLevelScore) ..
                    ", vendor=" .. tostring(equippedBreakdown.vendorScore) ..
                    ", speed=" .. tostring(equippedBreakdown.speedScore) ..
                    ", mhdmg=" .. tostring(equippedBreakdown.mainHandDamageBonus) ..
                    ", pair=" .. tostring(equippedBreakdown.pairingBonus) ..
                    ", uncached=" .. tostring(equippedBreakdown.uncachedQualityScore) ..
                    "]"
                    or ", equipped[none]"
                )
            )
        else
            DebugPrint(
                "choice=" .. i ..
                ", profile=" .. tostring(profile) ..
                ", delta=" .. tostring(delta) ..
                ", rewardScore=" .. tostring(rewardScore) ..
                ", equippedScore=" .. tostring(equippedScore) ..
                ", slot=" .. tostring(slotID) ..
                ", cached=" .. tostring(meta and meta.isCached) ..
                ", item=" .. tostring(meta and meta.name)
            )
        end

        if bestDelta == nil
            or delta > bestDelta
            or (delta == bestDelta and rewardScore > (bestRawScore or -999999)) then
            bestDelta = delta
            bestRawScore = rewardScore
            bestIndex = i
        end
    end

    return bestIndex, profile, foundUncached
end

local function HandleRewardKey(key)
    if not DB.rewardKeys or not IsAutomationAllowed() then
        return
    end

    local choice = rewardKeyMap[key]
    if not choice then
        return
    end

    if key:match("^NUMPAD") then
        -- allowed
    elseif not key:match("^[0-9]$") then
        return
    end

    local numChoices = GetNumQuestChoices()
    if numChoices < 1 then
        DisableRewardListener()
        return
    end

    if choice > numChoices then
        Print("No quest reward in slot " .. choice)
        return
    end

    GetQuestReward(choice)
    DisableRewardListener()
end

local function StartRewardRetry()
    DB.rewardRetryEnabled = true

    pendingRewardRetry = true
    pendingRewardRetryDelay = DB.rewardRetryDelay or 0.2
    pendingRewardRetryCount = 0
    DebugPrint("starting reward retry loop")
end

local function StopRewardRetry()
    pendingRewardRetry = false
    pendingRewardRetryDelay = 0
    pendingRewardRetryCount = 0
end

local function CreateQZCheckbox(parent, labelText, x, y, getValue, onClick)
    local cb = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
    cb:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)

    local fontString = cb:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    fontString:SetPoint("LEFT", cb, "RIGHT", 4, 0)
    fontString:SetText(labelText)
    cb.label = fontString

    cb.GetValue = getValue
    cb:SetScript("OnClick", function(self)
        onClick(self:GetChecked() and true or false)
        NormalizeRewardOptionState()
        if GUIRefresh then GUIRefresh() end
    end)

    return cb
end

local function CreateQZLabel(parent, text, x, y)
    local fs = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    fs:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
    fs:SetText(text)
    return fs
end

local function SetCheckboxVisualState(cb, enabled, checked)
    cb:SetChecked(checked and true or false)

    if enabled then
        cb:Enable()
        cb.label:SetTextColor(1, 0.82, 0)
    else
        cb:Disable()
        cb.label:SetTextColor(0.5, 0.5, 0.5)
    end
end

local function GetDisplayTextFromOptions(options, value)
    for _, entry in ipairs(options) do
        if entry.value == value then
            return entry.text
        end
    end
    return tostring(value)
end

local function GetSpecOptionsForClass(classToken)
    if classToken == "HUNTER" then
        return HUNTER_SPEC_OPTIONS
    elseif classToken == "ROGUE" then
        return ROGUE_SPEC_OPTIONS
    elseif classToken == "WARRIOR" then
        return WARRIOR_SPEC_OPTIONS
    elseif classToken == "PALADIN" then
        return PALADIN_SPEC_OPTIONS
    end
    return {
        { value = "auto", text = "Auto Detect" },
    }
end

local function CreateQZDropdown(parent, width, x, y, options, getValue, setValue)
    dropdownCounter = dropdownCounter + 1

    local frameName = "QuestZombieDropdown" .. dropdownCounter
    local frame = CreateFrame("Frame", frameName, parent, "UIDropDownMenuTemplate")
    frame:SetPoint("TOPLEFT", parent, "TOPLEFT", x - 16, y + 8)

    frame.options = options
    frame.getValue = getValue
    frame.setValue = setValue

    UIDropDownMenu_SetWidth(frame, width)
    UIDropDownMenu_JustifyText(frame, "LEFT")

    frame.InitializeDropdown = function(self, level)
        level = level or 1

        for _, entry in ipairs(self.options or {}) do
            local info = UIDropDownMenu_CreateInfo()
            info.text = entry.text
            info.value = entry.value
            info.checked = (self.getValue() == entry.value)
            info.func = function()
                self.setValue(entry.value)
                UIDropDownMenu_SetSelectedValue(self, entry.value)
                UIDropDownMenu_SetText(self, entry.text)
                if GUIRefresh then GUIRefresh() end
            end
            info.tooltipTitle = entry.text
            info.tooltipText = entry.tooltip
            info.notCheckable = false
            UIDropDownMenu_AddButton(info, level)
        end
    end

    UIDropDownMenu_Initialize(frame, function(self, level) self:InitializeDropdown(level) end)
    UIDropDownMenu_SetSelectedValue(frame, getValue())
    UIDropDownMenu_SetText(frame, GetDisplayTextFromOptions(options, getValue()))

    return frame
end

EnsureGUI = function()
    if GUIFrame then
        return
    end

    GUIFrame = CreateFrame("Frame", "QuestZombieConfigFrame", UIParent)
    GUIFrame:SetWidth(470)
    GUIFrame:SetHeight(390)
    GUIFrame:SetPoint("CENTER")
    GUIFrame:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true,
        tileSize = 32,
        edgeSize = 32,
        insets = { left = 11, right = 12, top = 12, bottom = 11 }
    })
    GUIFrame:SetMovable(true)
    GUIFrame:EnableMouse(true)
    GUIFrame:RegisterForDrag("LeftButton")
    GUIFrame:SetScript("OnDragStart", function(self) self:StartMoving() end)
    GUIFrame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local _, _, _, x, y = self:GetPoint()
        DB.guiX = x
        DB.guiY = y
    end)
    GUIFrame:Hide()

    table.insert(UISpecialFrames, "QuestZombieConfigFrame")

    local title = GUIFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
    title:SetPoint("TOP", GUIFrame, "TOP", 0, -16)
    title:SetText("QuestZombie")

    local close = CreateFrame("Button", nil, GUIFrame, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", GUIFrame, "TOPRIGHT", -6, -6)

    GUIFrame.statusText = GUIFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    GUIFrame.statusText:SetPoint("TOPLEFT", GUIFrame, "TOPLEFT", 20, -42)
    GUIFrame.statusText:SetWidth(420)
    GUIFrame.statusText:SetJustifyH("LEFT")

    CreateQZLabel(GUIFrame, "General", 20, -74)

    GUIFrame.cbEnabled = CreateQZCheckbox(GUIFrame, "Enable addon", 20, -96,
        function() return DB.enabled end,
        function(v) DB.enabled = v end)

    GUIFrame.cbAccept = CreateQZCheckbox(GUIFrame, "Auto accept quests", 20, -120,
        function() return DB.autoAccept end,
        function(v) DB.autoAccept = v end)

    GUIFrame.cbGreeting = CreateQZCheckbox(GUIFrame, "Skip greetings", 20, -144,
        function() return DB.skipGreeting end,
        function(v) DB.skipGreeting = v end)

    GUIFrame.cbEscort = CreateQZCheckbox(GUIFrame, "Auto escort confirm", 20, -168,
        function() return DB.autoEscort end,
        function(v) DB.autoEscort = v end)

    GUIFrame.cbComplete = CreateQZCheckbox(GUIFrame, "Auto complete quests", 20, -192,
        function() return DB.autoComplete end,
        function(v) DB.autoComplete = v end)

    GUIFrame.cbRaid = CreateQZCheckbox(GUIFrame, "Allow in raids", 20, -216,
        function() return DB.allowInRaid end,
        function(v) DB.allowInRaid = v end)

    CreateQZLabel(GUIFrame, "Reward Options", 245, -74)

    GUIFrame.cbSmartRewards = CreateQZCheckbox(GUIFrame, "Enable Smart Rewards", 245, -96,
        function() return DB.smartRewards end,
        function()
            DB.smartRewards = true
            DB.rewardKeys = false
        end)

    GUIFrame.cbRewardKeys = CreateQZCheckbox(GUIFrame, "Enable reward hotkeys", 245, -120,
        function() return DB.rewardKeys end,
        function()
            DB.rewardKeys = true
            DB.smartRewards = false
        end)

    GUIFrame.classLabel = CreateQZLabel(GUIFrame, "Class", 245, -158)
    GUIFrame.classDropdown = CreateQZDropdown(GUIFrame, 170, 245, -178, CLASS_OPTIONS,
        function() return DB.classOverride end,
        function(v) DB.classOverride = v end)

    GUIFrame.specLabel = CreateQZLabel(GUIFrame, "Spec", 245, -228)
    GUIFrame.specDropdown = CreateQZDropdown(GUIFrame, 170, 245, -248, HUNTER_SPEC_OPTIONS,
        function() return DB.specOverride end,
        function(v) DB.specOverride = v end)

    GUIFrame.modeLabel = CreateQZLabel(GUIFrame, "Reward Mode", 245, -298)
    GUIFrame.modeDropdown = CreateQZDropdown(GUIFrame, 170, 245, -318, MODE_OPTIONS,
        function() return DB.rewardMode end,
        function(v) DB.rewardMode = v end)

    GUIFrame.footer = GUIFrame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    GUIFrame.footer:SetPoint("BOTTOMLEFT", GUIFrame, "BOTTOMLEFT", 20, 18)
    GUIFrame.footer:SetText("/qz gui to reopen this window")

    GUIRefresh = function()
        if not GUIFrame then return end

        NormalizeRewardOptionState()

        GUIFrame.cbEnabled:SetChecked(DB.enabled)
        GUIFrame.cbAccept:SetChecked(DB.autoAccept)
        GUIFrame.cbGreeting:SetChecked(DB.skipGreeting)
        GUIFrame.cbEscort:SetChecked(DB.autoEscort)
        GUIFrame.cbComplete:SetChecked(DB.autoComplete)
        GUIFrame.cbRaid:SetChecked(DB.allowInRaid)

        if DB.smartRewards then
            SetCheckboxVisualState(GUIFrame.cbSmartRewards, true, true)
            SetCheckboxVisualState(GUIFrame.cbRewardKeys, true, false)
        elseif DB.rewardKeys then
            SetCheckboxVisualState(GUIFrame.cbSmartRewards, true, false)
            SetCheckboxVisualState(GUIFrame.cbRewardKeys, true, true)
        else
            DB.smartRewards = true
            DB.rewardKeys = false
            SetCheckboxVisualState(GUIFrame.cbSmartRewards, true, true)
            SetCheckboxVisualState(GUIFrame.cbRewardKeys, true, false)
        end

        UIDropDownMenu_SetSelectedValue(GUIFrame.classDropdown, DB.classOverride)
        UIDropDownMenu_SetText(GUIFrame.classDropdown, GetDisplayTextFromOptions(CLASS_OPTIONS, DB.classOverride))

        local effectiveClass = GetEffectiveClass()
        local specOptions = GetSpecOptionsForClass(effectiveClass)
        GUIFrame.specDropdown.options = specOptions
        UIDropDownMenu_Initialize(GUIFrame.specDropdown, function(self, level) self:InitializeDropdown(level) end)
        UIDropDownMenu_SetSelectedValue(GUIFrame.specDropdown, DB.specOverride)
        UIDropDownMenu_SetText(GUIFrame.specDropdown, GetDisplayTextFromOptions(specOptions, DB.specOverride))

        UIDropDownMenu_SetSelectedValue(GUIFrame.modeDropdown, DB.rewardMode)
        UIDropDownMenu_SetText(GUIFrame.modeDropdown, GetDisplayTextFromOptions(MODE_OPTIONS, DB.rewardMode))

        local profile = GetRewardProfile() or "manual"
        GUIFrame.statusText:SetText(
            "Active reward profile: " .. tostring(profile) ..
            " | mode=" .. tostring(DB.rewardMode) ..
            " | class=" .. tostring(DB.classOverride) ..
            " | spec=" .. tostring(DB.specOverride)
        )

        if effectiveClass == "HUNTER" or effectiveClass == "ROGUE" or effectiveClass == "WARRIOR" or effectiveClass == "PALADIN" then
            GUIFrame.specLabel:Show()
            GUIFrame.specDropdown:Show()
        else
            GUIFrame.specLabel:Hide()
            GUIFrame.specDropdown:Hide()
        end
    end

    if DB.guiX and DB.guiY then
        GUIFrame:ClearAllPoints()
        GUIFrame:SetPoint("CENTER", UIParent, "CENTER", DB.guiX, DB.guiY)
    end
end

EnsureGUI()

EnableRewardListener = function(numChoices)
    if not DB.rewardKeys then
        return
    end

    rewardListener:Show()
    BindRewardKeys(numChoices)

    if numChoices == 10 then
        Print("Select reward with 1-9, 0 for reward 10, or numpad 1-9, 0 for reward 10")
    else
        Print("Select reward with 1-" .. numChoices .. " or numpad 1-" .. numChoices)
    end
end

local function HandleQuestGreeting()
    if not IsAutomationAllowed() or not DB.skipGreeting then
        return
    end

    local numActive = GetNumActiveQuests()
    local numAvailable = GetNumAvailableQuests()

    if numAvailable > 0 then
        SelectAvailableQuest(1)
        return
    end

    if numActive > 0 then
        SelectActiveQuest(1)
    end
end

local function HandleGossipShow()
    if not IsAutomationAllowed() or not DB.skipGreeting then
        return
    end

    local available = GetGossipAvailableQuests()
    local active = GetGossipActiveQuests()

    if available then
        SelectGossipAvailableQuest(1)
        return
    end

    if active then
        SelectGossipActiveQuest(1)
    end
end

local function HandleQuestDetail()
    if not IsAutomationAllowed() or not DB.autoAccept then
        return
    end

    AcceptQuest()
end

local function HandleQuestAcceptConfirm()
    if not IsAutomationAllowed() or not DB.autoEscort then
        return
    end

    ConfirmAcceptQuest()
end

local function HandleQuestProgress()
    if not IsAutomationAllowed() or not DB.autoComplete then
        return
    end

    CompleteQuest()
end

local function HandleQuestComplete()
    if not IsAutomationAllowed() or not DB.autoComplete then
        return
    end

    StopRewardRetry()

    local numChoices = GetNumQuestChoices()
    if numChoices == 0 then
        GetQuestReward(1)
        DisableRewardListener()
        return
    end

    local choice, profile, foundUncached = ChooseSmartReward()

    if choice and choice >= 1 and choice <= numChoices and not foundUncached then
        DebugPrint("auto reward choice=" .. tostring(choice) .. ", profile=" .. tostring(profile) .. ", comparison=equipped-upgrade-dualslot")
        GetQuestReward(choice)
        DisableRewardListener()
        return
    end

    if foundUncached and DB.smartRewards and DB.rewardMode ~= "manual" then
        DebugPrint("uncached reward data detected; waiting for retry")
        DisableRewardListener()
        StartRewardRetry()
        return
    end

    EnableRewardListener(numChoices)
end

local function HandleQuestFinished()
    StopRewardRetry()
    DisableRewardListener()
end

local eventHandlers = {
    QUEST_GREETING = HandleQuestGreeting,
    GOSSIP_SHOW = HandleGossipShow,
    GOSSIP_CLOSED = HandleQuestFinished,
    QUEST_DETAIL = HandleQuestDetail,
    QUEST_ACCEPT_CONFIRM = HandleQuestAcceptConfirm,
    QUEST_PROGRESS = HandleQuestProgress,
    QUEST_COMPLETE = HandleQuestComplete,
    QUEST_FINISHED = HandleQuestFinished,
    QUEST_ITEM_UPDATE = function()
        if GetNumQuestChoices() == 0 then
            StopRewardRetry()
            DisableRewardListener()
        end
    end,
}

addon:SetScript("OnUpdate", function(_, elapsed)
    if not pendingRewardRetry then
        return
    end

    pendingRewardRetryDelay = pendingRewardRetryDelay - elapsed
    if pendingRewardRetryDelay > 0 then
        return
    end

    if not QuestFrame or not QuestFrame:IsVisible() then
        StopRewardRetry()
        return
    end

    local numChoices = GetNumQuestChoices()
    if not numChoices or numChoices < 1 then
        StopRewardRetry()
        return
    end

    local choice, profile, foundUncached = ChooseSmartReward()

    if choice and not foundUncached then
        DebugPrint("retry success choice=" .. tostring(choice) .. ", profile=" .. tostring(profile) .. ", attempt=" .. tostring(pendingRewardRetryCount + 1))
        GetQuestReward(choice)
        DisableRewardListener()
        StopRewardRetry()
        return
    end

    pendingRewardRetryCount = pendingRewardRetryCount + 1
    if pendingRewardRetryCount >= (DB.rewardRetryMax or 8) then
        DebugPrint("retry exhausted; falling back to manual reward selection")
        StopRewardRetry()
        EnableRewardListener(numChoices)
        return
    end

    pendingRewardRetryDelay = DB.rewardRetryDelay or 0.2
end)

addon:SetScript("OnEvent", function(_, event, ...)
    local handler = eventHandlers[event]
    if handler then
        handler(...)
    end
end)

addon:RegisterEvent("QUEST_GREETING")
addon:RegisterEvent("GOSSIP_SHOW")
addon:RegisterEvent("GOSSIP_CLOSED")
addon:RegisterEvent("QUEST_DETAIL")
addon:RegisterEvent("QUEST_ACCEPT_CONFIRM")
addon:RegisterEvent("QUEST_PROGRESS")
addon:RegisterEvent("QUEST_COMPLETE")
addon:RegisterEvent("QUEST_FINISHED")
addon:RegisterEvent("QUEST_ITEM_UPDATE")

Print("loaded")