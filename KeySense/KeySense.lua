--[[
    KeySense
    ---------------------------------------------------------------------------
    Mythic+ applicant impact and group confidence helper.

    Version:
        0.1.1

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


local function BoolIcon(v)
    if v then
        return GREEN .. "yes" .. RESET
    end

    return GRAY .. "no" .. RESET
end


local function NormalizeRealmName(name)
    name = tostring(name or "")
    name = name:gsub("%s+", "")
    return name
end


local function PlayerKey(name)
    name = tostring(name or "")

    if name == "" then
        return nil
    end

    if name:find("-", 1, true) then
        return name
    end

    local realm = GetRealmName and GetRealmName() or nil

    if realm and realm ~= "" then
        return name .. "-" .. NormalizeRealmName(realm)
    end

    return name
end


local function UtilityListForClass(classFile)
    local utility = CLASS_UTILITY[classFile or ""]
    local parts = {}

    if not utility then
        return parts
    end

    if utility.lust then
        table.insert(parts, "lust")
    end

    if utility.brez then
        table.insert(parts, "brez")
    end

    if utility.purge then
        table.insert(parts, "purge")
    end

    if utility.soothe then
        table.insert(parts, "soothe")
    end

    if utility.curse then
        table.insert(parts, "curse")
    end

    if utility.poison then
        table.insert(parts, "poison")
    end

    if utility.disease then
        table.insert(parts, "disease")
    end

    if utility.magic then
        table.insert(parts, "magic")
    end

    if utility.massDispel then
        table.insert(parts, "mass dispel")
    end

    if utility.shroud then
        table.insert(parts, "shroud")
    end

    if utility.magicDebuff then
        table.insert(parts, "magic debuff")
    end

    if utility.battleShout then
        table.insert(parts, "battle shout")
    end

    return parts
end


local function UtilityScoreForClass(classFile)
    local utility = CLASS_UTILITY[classFile or ""]
    local score = 0

    if not utility then
        return 0
    end

    if utility.lust then
        score = score + 8
    end

    if utility.brez then
        score = score + 7
    end

    if utility.purge then
        score = score + 3
    end

    if utility.soothe then
        score = score + 3
    end

    if utility.massDispel then
        score = score + 4
    end

    if utility.shroud then
        score = score + 3
    end

    if utility.magicDebuff then
        score = score + 3
    end

    if utility.battleShout then
        score = score + 2
    end

    if utility.curse or utility.poison or utility.disease or utility.magic then
        score = score + 2
    end

    return Clamp(score, 0, 14)
end


local function FirstNumberFromTable(t, keys)
    if type(t) ~= "table" then
        return nil
    end

    for _, key in ipairs(keys) do
        local value = t[key]

        if type(value) == "number" then
            return value
        end
    end

    return nil
end


local function ScanStatsForNumber(t, wantedKeys)
    if type(t) ~= "table" then
        return nil
    end

    local direct = FirstNumberFromTable(t, wantedKeys)

    if direct then
        return direct
    end

    for _, value in pairs(t) do
        if type(value) == "table" then
            local nested = ScanStatsForNumber(value, wantedKeys)

            if nested then
                return nested
            end
        end
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

        if okMap and type(resultMap) == "number" and resultMap > 0 then
            challengeMapID = resultMap
        end
    end

    return {
        level = level,
        challengeMapID = challengeMapID,
    }
end


function KS:GetTargetContext()
    local owned = self:GetOwnedKeyContext()
    local target = self.db and self.db.target or {}
    local settings = self.db and self.db.settings or DEFAULT_DB.settings

    return {
        level = target.level or owned.level or settings.defaultKeyLevel,
        challengeMapID = target.challengeMapID or owned.challengeMapID,
        activityID = target.activityID,
        source = target.level and "manual" or (owned.level and "owned key" or "default"),
    }
end


function KS:SetTargetLevel(level)
    level = tonumber(level)

    if not level or level < 2 or level > 40 then
        self:Print("Usage: /ks level 10")
        return
    end

    self.db.target.level = Round(level)
    self:Print("Target key level set to +" .. tostring(self.db.target.level) .. ".")
    self:Refresh()
end


function KS:ClearTarget()
    self.db.target.level = nil
    self.db.target.challengeMapID = nil
    self.db.target.activityID = nil

    self:Print("Manual target cleared.")
    self:Refresh()
end


-- ==========================================================================
-- Applicant Data
-- ==========================================================================

function KS:GetApplicantIDs()
    if not C_LFGList or type(C_LFGList.GetApplicants) ~= "function" then
        return {}
    end

    local ok, applicants = pcall(C_LFGList.GetApplicants)

    if ok and type(applicants) == "table" then
        return applicants
    end

    return {}
end


function KS:GetApplicantInfo(applicantID)
    local info = {
        applicantID = applicantID,
        status = nil,
        numMembers = 1,
        isNew = false,
    }

    if C_LFGList and type(C_LFGList.GetApplicantInfo) == "function" then
        local ok, a, status, pendingStatus, numMembers, isNew, comment, displayOrderID = pcall(C_LFGList.GetApplicantInfo, applicantID)

        if ok then
            if type(a) == "table" then
                info.status = a.applicationStatus or a.status
                info.pendingStatus = a.pendingApplicationStatus or a.pendingStatus
                info.numMembers = a.numMembers or a.memberCount or 1
                info.isNew = a.isNew or false
                info.comment = a.comment
                info.displayOrderID = a.displayOrderID
            else
                info.status = status
                info.pendingStatus = pendingStatus
                info.numMembers = numMembers or 1
                info.isNew = isNew or false
                info.comment = comment
                info.displayOrderID = displayOrderID
            end
        end
    end

    info.numMembers = tonumber(info.numMembers) or 1

    if info.numMembers < 1 then
        info.numMembers = 1
    end

    return info
end


function KS:GetApplicantMemberInfo(applicantID, memberIndex)
    local member = {
        applicantID = applicantID,
        memberIndex = memberIndex,
        name = "Unknown",
        classFile = nil,
        localizedClass = nil,
        level = nil,
        itemLevel = nil,
        role = nil,
        specID = nil,
        specName = nil,
        score = nil,
        bestRunLevel = nil,
    }

    if not C_LFGList or type(C_LFGList.GetApplicantMemberInfo) ~= "function" then
        return member
    end

    local ok, name, classFile, localizedClass, level, itemLevel, honorLevel, tank, healer, damage, assignedRole, relationship, friends, bnetFriends, factionGroup, raceID, specID = pcall(C_LFGList.GetApplicantMemberInfo, applicantID, memberIndex)

    if ok then
        if type(name) == "table" then
            local data = name
            member.name = data.name or data.playerName or member.name
            member.classFile = data.classFilename or data.classFileName or data.classFile or data.class
            member.localizedClass = data.localizedClass or data.className
            member.level = data.level
            member.itemLevel = data.itemLevel or data.ilvl
            member.role = data.assignedRole or data.role
            member.specID = data.specID or data.specId
        else
            member.name = name or member.name
            member.classFile = classFile
            member.localizedClass = localizedClass
            member.level = level
            member.itemLevel = itemLevel
            member.role = assignedRole
            member.specID = specID

            if not member.role then
                if tank then
                    member.role = "TANK"
                elseif healer then
                    member.role = "HEALER"
                elseif damage then
                    member.role = "DAMAGER"
                end
            end
        end
    end

    member.itemLevel = tonumber(member.itemLevel)
    member.level = tonumber(member.level)
    member.specID = tonumber(member.specID)
    member.specName = GetSpecName(member.specID)

    self:AddApplicantStats(member)

    return member
end


function KS:AddApplicantStats(member)
    if not C_LFGList or type(C_LFGList.GetApplicantMemberStats) ~= "function" then
        return
    end

    local ok, stats = pcall(C_LFGList.GetApplicantMemberStats, member.applicantID, member.memberIndex)

    if not ok or type(stats) ~= "table" then
        return
    end

    member.rawStats = stats

    member.score = ScanStatsForNumber(stats, {
        "dungeonScore",
        "mythicPlusScore",
        "mPlusScore",
        "score",
        "currentSeasonScore",
        "seasonScore",
    })

    member.bestRunLevel = ScanStatsForNumber(stats, {
        "bestRunLevel",
        "bestDungeonLevel",
        "level",
        "mythicLevel",
        "keystoneLevel",
    })
end


function KS:GetApplicants()
    local result = {}
    local applicantIDs = self:GetApplicantIDs()

    for _, applicantID in ipairs(applicantIDs) do
        local info = self:GetApplicantInfo(applicantID)

        if info.status == "applied" or info.status == "invited" or info.status == nil then
            local members = {}

            for memberIndex = 1, info.numMembers do
                table.insert(members, self:GetApplicantMemberInfo(applicantID, memberIndex))
            end

            local summary = self:EvaluateApplicant(info, members)

            table.insert(result, summary)
        end
    end

    if self.db.settings.sortByImpact then
        table.sort(result, function(a, b)
            if a.impact == b.impact then
                return a.fit > b.fit
            end

            return a.impact > b.impact
        end)
    else
        table.sort(result, function(a, b)
            if a.fit == b.fit then
                return a.impact > b.impact
            end

            return a.fit > b.fit
        end)
    end

    return result
end


-- ==========================================================================
-- Scoring
-- ==========================================================================

function KS:EvaluateApplicant(info, members)
    local target = self:GetTargetContext()
    local settings = self.db.settings
    local targetLevel = tonumber(target.level) or settings.defaultKeyLevel
    local expectedScore = targetLevel * settings.scorePerKey
    local expectedIlvl = settings.baseExpectedIlvl + (targetLevel * settings.ilvlPerKey)

    local best = nil
    local utilityScore = 0
    local utilityTags = {}
    local avgIlvl = 0
    local ilvlCount = 0
    local bestScore = nil
    local bestRunLevel = nil
    local confidence = 20
    local noteBonus = 0
    local noteText = nil
    local specBonus = 0

    for _, member in ipairs(members) do
        if not best then
            best = member
        end

        local classUtilityScore = UtilityScoreForClass(member.classFile)
        utilityScore = utilityScore + classUtilityScore

        local classUtilityTags = UtilityListForClass(member.classFile)

        for _, tag in ipairs(classUtilityTags) do
            utilityTags[tag] = true
        end

        if member.itemLevel then
            avgIlvl = avgIlvl + member.itemLevel
            ilvlCount = ilvlCount + 1
        end

        if member.score and (not bestScore or member.score > bestScore) then
            bestScore = member.score
        end

        if member.bestRunLevel and (not bestRunLevel or member.bestRunLevel > bestRunLevel) then
            bestRunLevel = member.bestRunLevel
        end

        if member.specID and self.db.specMeta[member.specID] then
            specBonus = specBonus + (tonumber(self.db.specMeta[member.specID]) or 0)
        end

        local key = PlayerKey(member.name)
        local note = key and self.db.playerNotes[key] or nil

        if type(note) == "table" then
            noteBonus = noteBonus + (tonumber(note.bonus) or 0)
            noteText = note.note or noteText
        end
    end

    if ilvlCount > 0 then
        avgIlvl = avgIlvl / ilvlCount
        confidence = confidence + 25
    else
        avgIlvl = nil
    end

    if bestScore then
        confidence = confidence + 35
    end

    if bestRunLevel then
        confidence = confidence + 15
    end

    if best and best.role then
        confidence = confidence + 10
    end

    if #members > 1 then
        confidence = confidence - 10
    end

    confidence = Clamp(confidence, 10, 95)

    local ilvlScore = 0

    if avgIlvl then
        ilvlScore = Clamp((avgIlvl - expectedIlvl) * 1.5, -18, 18)
    end

    local ratingScore = 0

    if bestScore then
        ratingScore = Clamp((bestScore - expectedScore) / 45, -24, 24)
    end

    local completionScore = 0

    if bestRunLevel then
        completionScore = Clamp((bestRunLevel - targetLevel) * 3, -12, 12)
    end

    utilityScore = Clamp(utilityScore, 0, 20)
    specBonus = Clamp(specBonus, -12, 12)
    noteBonus = Clamp(noteBonus, -15, 15)

    local fit = 55 + ilvlScore + ratingScore + completionScore + specBonus + noteBonus
    fit = Clamp(Round(fit), 0, 100)

    local impact = (fit - 55) + utilityScore + specBonus + noteBonus

    local tags = {}

    for tag in pairs(utilityTags) do
        table.insert(tags, tag)
    end

    table.sort(tags)

    return {
        applicantID = info.applicantID,
        members = members,
        primary = best or members[1],
        memberCount = #members,
        fit = fit,
        impact = Round(impact),
        confidence = Round(confidence),
        fitLabel = FitLabel(fit, confidence),
        confidenceLabel = ConfidenceLabel(confidence),
        utilityScore = utilityScore,
        utilityTags = tags,
        avgIlvl = avgIlvl and Round(avgIlvl) or nil,
        score = bestScore,
        bestRunLevel = bestRunLevel,
        note = noteText,
        targetLevel = targetLevel,
        targetSource = target.source,
    }
end


-- ==========================================================================
-- UI
-- ==========================================================================

function KS:CreateUI()
    if self.frame then
        return
    end

    local frame = CreateFrame("Frame", "KeySenseFrame", UIParent, "BackdropTemplate")
    frame:SetSize(760, 430)
    frame:SetPoint("CENTER")
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
    frame:Hide()

    if frame.SetBackdrop then
        frame:SetBackdrop({
            bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
            edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
            tile = true,
            tileSize = 32,
            edgeSize = 32,
            insets = {
                left = 8,
                right = 8,
                top = 8,
                bottom = 8,
            },
        })

        frame:SetBackdropColor(0, 0, 0, 0.9)
    end

    frame.title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    frame.title:SetPoint("TOPLEFT", 18, -16)
    frame.title:SetText(BLUE .. "KeySense" .. RESET)

    frame.subtitle = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    frame.subtitle:SetPoint("TOPLEFT", frame.title, "BOTTOMLEFT", 0, -6)
    frame.subtitle:SetText(GRAY .. "Mythic+ applicant impact helper" .. RESET)

    frame.context = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    frame.context:SetPoint("TOPRIGHT", -52, -20)
    frame.context:SetJustifyH("RIGHT")

    frame.close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
    frame.close:SetPoint("TOPRIGHT", -5, -5)

    frame.refresh = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    frame.refresh:SetSize(86, 22)
    frame.refresh:SetPoint("TOPRIGHT", -55, -48)
    frame.refresh:SetText("Refresh")
    frame.refresh:SetScript("OnClick", function()
        KS:Refresh()
    end)

    frame.header = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    frame.header:SetPoint("TOPLEFT", 24, -86)
    frame.header:SetText(WHITE .. "Applicant                         Role    Ilvl   Score   Best   Fit        Impact   Conf    Utility" .. RESET)

    frame.rows = {}

    for i = 1, MAX_ROWS do
        local row = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row:SetPoint("TOPLEFT", 24, -88 - (i * 22))
        row:SetWidth(710)
        row:SetJustifyH("LEFT")
        row:SetText("")

        frame.rows[i] = row
    end

    frame.footer = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    frame.footer:SetPoint("BOTTOMLEFT", 22, 18)
    frame.footer:SetWidth(710)
    frame.footer:SetJustifyH("LEFT")
    frame.footer:SetText("Commands: /ks, /ks scan, /ks level 10, /ks clear, /ks reset")

    self.frame = frame
end


function KS:Show()
    self:CreateUI()
    self.frame:Show()
    self:Refresh()
end


function KS:Hide()
    if self.frame then
        self.frame:Hide()
    end
end


function KS:Toggle()
    self:CreateUI()

    if self.frame:IsShown() then
        self.frame:Hide()
    else
        self.frame:Show()
        self:Refresh()
    end
end


local function PadRight(text, length)
    text = tostring(text or "")

    if #text >= length then
        return text:sub(1, length)
    end

    return text .. string.rep(" ", length - #text)
end


function KS:ApplicantRowText(applicant)
    local primary = applicant.primary or {}
    local name = primary.name or "Unknown"
    local role = RoleText(primary.role)
    local ilvl = applicant.avgIlvl and tostring(applicant.avgIlvl) or "-"
    local score = applicant.score and tostring(Round(applicant.score)) or "-"
    local best = applicant.bestRunLevel and ("+" .. tostring(Round(applicant.bestRunLevel))) or "-"
    local fit = applicant.fitLabel .. " " .. tostring(applicant.fit)
    local impactColor = ColorByImpact(applicant.impact)
    local impact = impactColor .. string.format("%+d", applicant.impact) .. RESET
    local conf = applicant.confidenceLabel
    local utility = "-"

    if applicant.utilityTags and #applicant.utilityTags > 0 then
        utility = table.concat(applicant.utilityTags, ", ")
    end

    if applicant.memberCount and applicant.memberCount > 1 then
        name = name .. " +" .. tostring(applicant.memberCount - 1)
    end

    local line = PadRight(name, 34)
        .. PadRight(role, 8)
        .. PadRight(ilvl, 7)
        .. PadRight(score, 8)
        .. PadRight(best, 7)
        .. PadRight(fit, 13)
        .. PadRight(impact, 11)
        .. PadRight(conf, 8)
        .. utility

    if applicant.note then
        line = line .. GRAY .. "  note: " .. applicant.note .. RESET
    end

    return line
end


function KS:Refresh()
    self:CreateUI()

    local context = self:GetTargetContext()
    self.frame.context:SetText(
        WHITE .. "Target: +" .. tostring(context.level) .. RESET
        .. GRAY .. " (" .. tostring(context.source) .. ")" .. RESET
    )

    local applicants = self:GetApplicants()

    for i = 1, MAX_ROWS do
        local row = self.frame.rows[i]
        local applicant = applicants[i]

        if applicant then
            row:SetText(self:ApplicantRowText(applicant))
        else
            row:SetText("")
        end
    end

    if #applicants == 0 then
        self.frame.rows[1]:SetText(GRAY .. "No active LFG applicants found. Open your Group Finder listing and click Refresh." .. RESET)
    elseif #applicants > MAX_ROWS then
        self.frame.rows[MAX_ROWS]:SetText(GRAY .. "... plus " .. tostring(#applicants - MAX_ROWS + 1) .. " more applicants. Use Blizzard LFG list for the full set." .. RESET)
    end
end


-- ==========================================================================
-- Slash Commands
-- ==========================================================================

function KS:PrintHelp()
    self:Print("/ks - show or hide KeySense")
    self:Print("/ks scan - refresh applicant list")
    self:Print("/ks level <number> - set manual target key level")
    self:Print("/ks clear - clear manual target key")
    self:Print("/ks reset - reset KeySense settings")
end


function KS:ResetDB()
    KeySenseDB = CopyDefaults(DEFAULT_DB, {})
    KeySenseExternalDB = KeySenseExternalDB or {}
    self.db = KeySenseDB

    self:Print("Settings reset.")
    self:Refresh()
end


function KS:HandleSlash(msg)
    msg = Trim(msg)
    local command, rest = msg:match("^(%S*)%s*(.-)$")
    command = string.lower(command or "")
    rest = Trim(rest)

    if command == "" then
        self:Toggle()
    elseif command == "show" or command == "open" then
        self:Show()
    elseif command == "hide" or command == "close" then
        self:Hide()
    elseif command == "scan" or command == "refresh" then
        self:Show()
        self:Refresh()
    elseif command == "level" or command == "key" then
        self:SetTargetLevel(rest)
    elseif command == "clear" then
        self:ClearTarget()
    elseif command == "reset" then
        self:ResetDB()
    elseif command == "help" then
        self:PrintHelp()
    else
        self:Print("Unknown command: " .. command)
        self:PrintHelp()
    end
end


-- ==========================================================================
-- Events
-- ==========================================================================

function KS:RegisterGameEvent(eventName)
    local ok = pcall(self.RegisterEvent, self, eventName)

    return ok
end


function KS:OnAddonLoaded(addonName)
    if addonName ~= ADDON_NAME then
        return
    end

    self:InitDB()
    self:CreateUI()

    SLASH_KEYSENSE1 = "/keysense"
    SLASH_KEYSENSE2 = "/ks"
    SlashCmdList.KEYSENSE = function(msg)
        KS:HandleSlash(msg)
    end

    self:Print("loaded. Type /ks to open.")
end


function KS:OnEvent(eventName, ...)
    if eventName == "ADDON_LOADED" then
        self:OnAddonLoaded(...)
        return
    end

    if not self.db then
        return
    end

    if eventName == "PLAYER_LOGIN" then
        self:CreateUI()
        return
    end

    if eventName == "LFG_LIST_APPLICANT_UPDATED"
        or eventName == "LFG_LIST_APPLICANT_LIST_UPDATED"
        or eventName == "LFG_LIST_ACTIVE_ENTRY_UPDATE" then

        if self.db.settings.autoShowOnApplicant then
            self:Show()
        elseif self.frame and self.frame:IsShown() then
            self:Refresh()
        end
    end
end


KS:SetScript("OnEvent", function(_, eventName, ...)
    KS:OnEvent(eventName, ...)
end)

KS:RegisterGameEvent("ADDON_LOADED")
KS:RegisterGameEvent("PLAYER_LOGIN")
KS:RegisterGameEvent("LFG_LIST_APPLICANT_UPDATED")
KS:RegisterGameEvent("LFG_LIST_APPLICANT_LIST_UPDATED")
KS:RegisterGameEvent("LFG_LIST_ACTIVE_ENTRY_UPDATE")
