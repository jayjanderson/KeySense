--[[
    KeySense
    ---------------------------------------------------------------------------
    Mythic+ applicant impact and group confidence helper.

    Version:
        0.1.0

    Purpose:
        KeySense helps a Mythic+ group leader quickly evaluate LFG applicants.

        It estimates:
            - Applicant Fit
            - Applicant Impact
            - Confidence level
            - Group utility contribution
            - Visible risk/watch items

    Important:
        This addon is guidance only.

        It does NOT:
            - Automatically invite players
            - Automatically decline players
            - Call Raider.IO, Warcraft Logs, Murlok, Wipefest, or WoWAnalyzer live
            - Pull live web data
            - Replace player judgment

    Current MVP:
        Uses Blizzard LFG applicant APIs and available in-game data.

    External Data:
        KeySenseExternalDB is supported as a placeholder for future companion-app
        imports, but no live external data is fetched by this addon.
--]]


-- ==========================================================================
-- Addon Namespace
-- ==========================================================================

local ADDON_NAME, ns = ...
local KS = CreateFrame("Frame")

ns.KeySense = KS


-- ==========================================================================
-- Constants
-- ==========================================================================

local MAX_ROWS = 14


-- ==========================================================================
-- Color Constants
-- ==========================================================================

local GREEN  = "|cff55ff55"
local YELLOW = "|cffffff55"
local ORANGE = "|cffffaa33"
local RED    = "|cffff5555"
local BLUE   = "|cff66ccff"
local GRAY   = "|cffaaaaaa"
local WHITE  = "|cffffffff"
local RESET  = "|r"


-- ==========================================================================
-- Default Saved Variables
-- ==========================================================================

local DEFAULT_DB = {
    target = {
        level = nil,
        challengeMapID = nil,
        activityID = nil,
    },

    settings = {
        -- Used when no owned keystone or manual target is detected.
        defaultKeyLevel = 10,

        -- Rough first-pass score expectation.
        -- Example: +10 expects roughly 2200 score if scorePerKey = 220.
        -- This should eventually become season-aware.
        scorePerKey = 220,

        -- Rough first-pass item level expectation.
        -- This should eventually become season-aware.
        baseExpectedIlvl = 680,
        ilvlPerKey = 3.5,

        -- Automatically show the KeySense panel when applicants update.
        autoShowOnApplicant = true,

        -- Sort applicants by impact instead of raw fit.
        sortByImpact = true,
    },

    specMeta = {
        -- Optional manual per-spec modifiers.
        --
        -- Example:
        -- [70] = 4,  -- Retribution Paladin
        --
        -- Recommended range:
        -- -8 to +8
    },

    playerNotes = {
        -- Optional local notes by exact "Name-Realm".
        --
        -- Example:
        -- ["Player-Area52"] = {
        --     bonus = 5,
        --     note = "Timed +10 with me."
        -- }
    },
}


-- ==========================================================================
-- Basic Class Utility Map
-- ==========================================================================

-- This is intentionally simple for the MVP.
-- It is not meant to be a perfect Mythic+ utility model yet.

local CLASS_UTILITY = {
    MAGE = {
        lust = true,
        curse = true,
    },

    SHAMAN = {
        lust = true,
        purge = true,
    },

    HUNTER = {
        lust = true,
        soothe = true,
    },

    EVOKER = {
        lust = true,
        soothe = true,
        poison = true,
    },

    DRUID = {
        brez = true,
        soothe = true,
        curse = true,
        poison = true,
    },

    WARLOCK = {
        brez = true,
    },

    DEATHKNIGHT = {
        brez = true,
    },

    PALADIN = {
        brez = true,
        poison = true,
        disease = true,
    },

    PRIEST = {
        magic = true,
        massDispel = true,
        disease = true,
    },

    MONK = {
        poison = true,
        disease = true,
    },

    ROGUE = {
        soothe = true,
        shroud = true,
    },

    DEMONHUNTER = {
        magicDebuff = true,
    },

    WARRIOR = {
        battleShout = true,
    },
}


-- ==========================================================================
-- Utility Functions
-- ==========================================================================

local function CopyDefaults(src, dst)
    if type(dst) ~= "table" then
        dst = {}
    end

    for k, v in pairs(src) do
        if type(v) == "table" then
            dst[k] = CopyDefaults(v, dst[k])
        elseif dst[k] == nil then
            dst[k] = v
        end
    end

    return dst
end


local function Clamp(v, minValue, maxValue)
    v = tonumber(v) or 0

    if v < minValue then
        return minValue
    end

    if v > maxValue then
        return maxValue
    end

    return v
end


local function Round(v)
    v = tonumber(v) or 0
    return math.floor(v + 0.5)
end


local function Trim(s)
    return (s or ""):match("^%s*(.-)%s*$")
end


local function SafeCall(fn, ...)
    if type(fn) ~= "function" then
        return false
    end

    return pcall(fn, ...)
end


local function ColorByImpact(v)
    v = tonumber(v) or 0

    if v >= 15 then
        return GREEN
    elseif v >= 5 then
        return BLUE
    elseif v >= -3 then
        return YELLOW
    else
        return RED
    end
end


local function FitLabel(score, confidence)
    score = tonumber(score) or 0
    confidence = tonumber(confidence) or 0

    if confidence < 35 then
        return "Unknown"
    end

    if score >= 88 then
        return "Elite"
    elseif score >= 76 then
        return "Strong"
    elseif score >= 64 then
        return "Good"
    elseif score >= 52 then
        return "Playable"
    elseif score >= 40 then
        return "High variance"
    else
        return "Risky"
    end
end


local function ConfidenceLabel(conf)
    conf = tonumber(conf) or 0

    if conf >= 80 then
        return "High"
    elseif conf >= 55 then
        return "Medium"
    elseif conf >= 35 then
        return "Low"
    else
        return "Very low"
    end
end


local function RoleText(role)
    if role == "TANK" then
        return "Tank"
    elseif role == "HEALER" then
        return "Healer"
    elseif role == "DAMAGER" then
        return "DPS"
    end

    return "?"
end


local function GetSpecName(specID)
    if not specID or specID == 0 or not GetSpecializationInfoByID then
        return nil
    end

    local ok, id, name = pcall(GetSpecializationInfoByID, specID)

    if ok then
        return name
    end

    return nil
end


-- ==========================================================================
-- Basic Addon Methods
-- ==========================================================================

function KS:Print(msg)
    print(BLUE .. "KeySense:" .. RESET .. " " .. tostring(msg))
end


function KS:InitDB()
    KeySenseDB = CopyDefaults(DEFAULT_DB, KeySenseDB or {})
    KeySenseExternalDB = KeySenseExternalDB or {}

    self.db = KeySenseDB
end


-- ==========================================================================
-- Keystone / Target Context
-- ==========================================================================

function KS:GetOwnedKeyContext()
    local level
    local challengeMapID

    if C_MythicPlus then
        local okLevel, resultLevel = SafeCall(C_MythicPlus.GetOwnedKeystoneLevel)

        if okLevel and type(resultLevel) == "number" and resultLevel > 0 then
            level = resultLevel
        end

        local okMap, resultMap = SafeCall(C_MythicPlus.GetOwnedKeystoneChallengeMapID)

        if okMap and type(resultMap) == "number"
