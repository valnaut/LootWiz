local addonName, ns = ...

-- ============================================================================
-- SavedVariables & Defaults
-- ============================================================================
LootWizDB = LootWizDB or {}
LootWizDB.threshold = LootWizDB.threshold or 2 -- Default: 2 (Uncommon)
if LootWizDB.ignoreBoP == nil then
    LootWizDB.ignoreBoP = false
end
LootWizDB.ignoreList = LootWizDB.ignoreList or {}
LootWizDB.alwaysLootList = LootWizDB.alwaysLootList or {}

local SERVER_MAX_ML_THRESHOLD = 2 -- Cap server threshold at 2 so greens+ remain ML-controlled
local LOOT_TICK_INTERVAL = 0.06   -- 60ms pacing between slot actions

local QUALITY_INFO = {
    [0] = { name = "Poor",      hex = "|cff9d9d9d", r = 0.62, g = 0.62, b = 0.62 },
    [1] = { name = "Common",    hex = "|cffffffff", r = 1.00, g = 1.00, b = 1.00 },
    [2] = { name = "Uncommon",  hex = "|cff1eff00", r = 0.12, g = 1.00, b = 0.00 },
    [3] = { name = "Rare",      hex = "|cff0070dd", r = 0.00, g = 0.44, b = 0.87 },
    [4] = { name = "Epic",      hex = "|cffa335ee", r = 0.64, g = 0.21, b = 0.93 },
    [5] = { name = "Legendary", hex = "|cffff8000", r = 1.00, g = 0.50, b = 0.00 },
}

local function Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cffffd100[LootWiz]|r " .. tostring(msg))
end

local function NormalizeKey(str)
    if not str then return nil end
    str = tostring(str)
    local bracketName = str:match("%[(.-)%]")
    if bracketName and bracketName ~= "" then
        str = bracketName
    end
    str = str:gsub("^%s+", ""):gsub("%s+$", "")
    if str == "" then return nil end
    return str:lower(), str
end

-- ============================================================================
-- Master Looter & Native Player-Frame Menu Integration
-- ============================================================================
local rawGetLootThreshold = GetLootThreshold
local rawSetLootThreshold = SetLootThreshold

local function IsInGroup()
    return (GetNumPartyMembers() > 0) or (GetNumRaidMembers() > 0)
end

local function IsGroupLeader()
    if GetNumRaidMembers() > 0 then
        return IsRaidLeader() == 1 or IsRaidLeader() == true
    elseif GetNumPartyMembers() > 0 then
        return IsPartyLeader() == 1 or IsPartyLeader() == true
    end
    return false
end

local function IsPlayerMasterLooter()
    local method, partyMaster, raidMaster = GetLootMethod()
    if method ~= "master" then
        return false
    end
    if partyMaster == 0 then
        return true
    end
    if raidMaster and UnitIsUnit("raid" .. raidMaster, "player") then
        return true
    end
    return false
end

local function EnsureServerThresholdCap()
    if IsInGroup() and IsGroupLeader() and GetLootMethod() == "master" then
        local currentServerThresh = rawGetLootThreshold()
        if currentServerThresh and currentServerThresh > SERVER_MAX_ML_THRESHOLD then
            rawSetLootThreshold(SERVER_MAX_ML_THRESHOLD)
        end
    end
end

local function SetLootWizThreshold(quality, silent)
    quality = tonumber(quality)
    if not quality or not QUALITY_INFO[quality] then return end

    LootWizDB.threshold = quality
    if not silent then
        local q = QUALITY_INFO[quality]
        Print("Auto-loot threshold set to " .. q.hex .. "[" .. q.name .. "]|r. Items below " .. q.hex .. q.name .. "|r will be auto-looted to you.")
    end

    EnsureServerThresholdCap()

    if ns.UpdateGUIThresholdButtons then
        ns.UpdateGUIThresholdButtons()
    end
end

-- Hook SetLootThreshold so the default Player Frame right-click menu configures LootWiz
function SetLootThreshold(threshold)
    SetLootWizThreshold(threshold, false)
    if IsInGroup() and IsGroupLeader() then
        if GetLootMethod() == "master" then
            if (tonumber(threshold) or 2) > SERVER_MAX_ML_THRESHOLD then
                rawSetLootThreshold(SERVER_MAX_ML_THRESHOLD)
            else
                rawSetLootThreshold(threshold)
            end
        else
            rawSetLootThreshold(threshold)
        end
    end
end

-- Hook GetLootThreshold so the Player Frame right-click dropdown shows LootWiz's threshold
function GetLootThreshold()
    if GetLootMethod() == "master" then
        return LootWizDB.threshold or 2
    end
    return rawGetLootThreshold()
end

-- ============================================================================
-- List Lookup & BoP Tooltip Scanner Helpers
-- ============================================================================
local scanTooltip = CreateFrame("GameTooltip", "LootWizScanTooltip", nil, "GameTooltipTemplate")
local BOP_TEXT = ITEM_BIND_ON_PICKUP or "Binds when picked up"

local function IsLootSlotBoP(slot)
    if not slot then return false end
    scanTooltip:SetOwner(WorldFrame, "ANCHOR_NONE")
    scanTooltip:ClearLines()
    scanTooltip:SetLootItem(slot)

    local numLines = scanTooltip:NumLines() or 0
    for i = 2, math.min(numLines, 6) do
        local line = _G["LootWizScanTooltipTextLeft" .. i]
        if line then
            local text = line:GetText()
            if text and (text == BOP_TEXT or text:find(BOP_TEXT, 1, true)) then
                return true
            end
        end
    end
    return false
end

local function ExtractItemID(link)
    if not link then return nil end
    local id = link:match("item:(%d+)")
    return id and tostring(id) or nil
end

local function IsItemInList(listTable, itemName, itemID)
    if itemName then
        local lowerName = itemName:lower()
        if listTable[lowerName] then
            return true
        end
    end
    if itemID and listTable[tostring(itemID)] then
        return true
    end
    return false
end

-- ============================================================================
-- Master Loot Prompt Suppression & Paced Auto-Looting Engine
-- ============================================================================
local activeTicker = nil
local isLootingSession = false
local isSuppressingMLPrompt = false
local masterLootPromptFired = false
local autoConfirmSlots = {}

-- Suppress GroupLootDropDown (used by both pfUI.loot and Blizzard UI) when auto-looting a slot
local origToggleDropDownMenu = ToggleDropDownMenu
function ToggleDropDownMenu(level, value, dropDownFrame, anchorName, xOffset, yOffset)
    if isSuppressingMLPrompt and dropDownFrame == GroupLootDropDown then
        return
    end
    if origToggleDropDownMenu then
        return origToggleDropDownMenu(level, value, dropDownFrame, anchorName, xOffset, yOffset)
    end
end

local origMasterLooterFrame_Show = MasterLooterFrame_Show
if origMasterLooterFrame_Show then
    function MasterLooterFrame_Show(...)
        if isSuppressingMLPrompt then
            if MasterLooterFrame then MasterLooterFrame:Hide() end
            return
        end
        return origMasterLooterFrame_Show(...)
    end
end

local function HideMasterLootMenus()
    if CloseDropDownMenus then
        CloseDropDownMenus()
    end
    if DropDownList1 and DropDownList1:IsShown() then
        DropDownList1:Hide()
    end
    if MasterLooterFrame and MasterLooterFrame:IsShown() then
        MasterLooterFrame:Hide()
    end
end

local function StopLootTicker()
    if activeTicker then
        activeTicker:Cancel()
        activeTicker = nil
    end
    isSuppressingMLPrompt = false
    wipe(autoConfirmSlots)
end

local function GetPlayerMLCandidateIndex(slot)
    local playerName = UnitName("player")
    for i = 1, 40 do
        local candidate = GetMasterLootCandidate(i)
        if candidate and candidate == playerName then
            return i
        end
    end
    if slot then
        for i = 1, 40 do
            local ok, candidate = pcall(GetMasterLootCandidate, slot, i)
            if ok and candidate and candidate == playerName then
                return i
            end
        end
    end
    return nil
end

local function HasAnyLootRemaining()
    local num = GetNumLootItems()
    if not num or num <= 0 then return false end
    for slot = 1, num do
        local texture = GetLootSlotInfo(slot)
        if texture then
            return true
        end
    end
    return false
end

local function EvaluateSlotAction(slot)
    if not LootSlotIsItem(slot) then
        return "SKIP"
    end

    local texture, itemName, quantity, quality, locked = GetLootSlotInfo(slot)
    if not texture or not itemName then
        return "SKIP"
    end

    local link = GetLootSlotLink(slot)
    local itemID = ExtractItemID(link)

    -- 1. Ignore List always takes priority: leave in loot window for manual assignment
    if IsItemInList(LootWizDB.ignoreList, itemName, itemID) then
        return "KEEP_MANUAL"
    end

    -- 2. Always Auto-Loot List overrides threshold and BoP settings
    if IsItemInList(LootWizDB.alwaysLootList, itemName, itemID) then
        return "AUTO_LOOT_ITEM"
    end

    -- 3. If "Leave BoP items" is enabled, keep BoP items in the loot window
    if LootWizDB.ignoreBoP and IsLootSlotBoP(slot) then
        return "KEEP_MANUAL"
    end

    -- 4. Quality strictly below threshold -> auto-loot to player
    local itemQuality = tonumber(quality) or 0
    if itemQuality < (LootWizDB.threshold or 2) then
        return "AUTO_LOOT_ITEM"
    end

    return "KEEP_MANUAL"
end

local function ProcessCurrentLootWindow()
    if not isLootingSession or not IsPlayerMasterLooter() then
        return
    end

    StopLootTicker()

    local numItems = GetNumLootItems()
    if not numItems or numItems <= 0 then
        return
    end

    local queue = {}
    local manualCount = 0

    -- Build slot queue from bottom to top so slot removal never shifts unprocessed indices
    for slot = numItems, 1, -1 do
        local action = EvaluateSlotAction(slot)
        if action == "AUTO_LOOT_ITEM" then
            table.insert(queue, { slot = slot, retries = 0 })
        elseif action == "KEEP_MANUAL" then
            manualCount = manualCount + 1
        end
    end

    if #queue == 0 then
        return
    end

    local idx = 1
    activeTicker = C_Timer.NewTicker(LOOT_TICK_INTERVAL, function()
        if not isLootingSession or idx > #queue then
            StopLootTicker()
            if isLootingSession and manualCount == 0 then
                C_Timer.After(0.08, function()
                    if isLootingSession and not HasAnyLootRemaining() then
                        CloseLoot()
                    end
                end)
            end
            return
        end

        local entry = queue[idx]
        local slot = entry.slot
        local texture = GetLootSlotInfo(slot)

        -- Slot already cleared
        if not texture then
            idx = idx + 1
            return
        end

        autoConfirmSlots[slot] = true
        masterLootPromptFired = false

        -- Prime the slot via LootSlot while suppressing the Master Loot dropdown UI.
        isSuppressingMLPrompt = true
        LootSlot(slot)
        isSuppressingMLPrompt = false
        HideMasterLootMenus()

        local mlIndex = GetPlayerMLCandidateIndex(slot)
        if mlIndex then
            GiveMasterLoot(slot, mlIndex)
            idx = idx + 1
        elseif not masterLootPromptFired then
            -- Slot did not trigger OPEN_MASTER_LOOT_LIST, so LootSlot(slot) handled it directly
            idx = idx + 1
        else
            -- Slot is ML-controlled, waiting for server's SMSG_LOOT_MASTER_LIST packet
            entry.retries = entry.retries + 1
            if entry.retries >= 8 then
                idx = idx + 1
            end
        end
    end)
end

-- ============================================================================
-- Party Formation & Core Event Handler
-- ============================================================================
local eventFrame = CreateFrame("Frame", "LootWizEventFrame")
local wasInGroup = false

local function CheckGroupTransition()
    local currentlyInGroup = IsInGroup()

    if not currentlyInGroup then
        wasInGroup = false
        return
    end

    if not wasInGroup then
        wasInGroup = true
        C_Timer.After(0.5, function()
            if IsInGroup() and IsGroupLeader() then
                local method = GetLootMethod()
                if method ~= "master" then
                    SetLootMethod("master", UnitName("player"))
                    Print("Party formed — automatically setting loot method to |cffffd100Master Looter|r.")
                end
                C_Timer.After(1.2, function()
                    EnsureServerThresholdCap()
                end)
            end
        end)
    else
        C_Timer.After(0.5, function()
            EnsureServerThresholdCap()
        end)
    end
end

eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
eventFrame:RegisterEvent("PARTY_MEMBERS_CHANGED")
eventFrame:RegisterEvent("RAID_ROSTER_UPDATE")
eventFrame:RegisterEvent("PARTY_LOOT_METHOD_CHANGED")
eventFrame:RegisterEvent("OPEN_MASTER_LOOT_LIST")
eventFrame:RegisterEvent("LOOT_OPENED")
eventFrame:RegisterEvent("LOOT_CLOSED")
eventFrame:RegisterEvent("LOOT_SLOT_CLEARED")
eventFrame:RegisterEvent("LOOT_BIND_CONFIRM")

eventFrame:SetScript("OnEvent", function(self, event, arg1)
    if event == "PLAYER_ENTERING_WORLD" then
        wasInGroup = IsInGroup()
        C_Timer.After(1.0, EnsureServerThresholdCap)

    elseif event == "PARTY_MEMBERS_CHANGED" or event == "RAID_ROSTER_UPDATE" then
        CheckGroupTransition()

    elseif event == "PARTY_LOOT_METHOD_CHANGED" then
        C_Timer.After(1.0, EnsureServerThresholdCap)
        if ns.UpdateGUIStatus then
            ns.UpdateGUIStatus()
        end

    elseif event == "OPEN_MASTER_LOOT_LIST" then
        masterLootPromptFired = true
        if isSuppressingMLPrompt then
            HideMasterLootMenus()
        end

    elseif event == "LOOT_OPENED" then
        isLootingSession = true
        if IsPlayerMasterLooter() then
            C_Timer.After(0.05, ProcessCurrentLootWindow)
        end

    elseif event == "LOOT_BIND_CONFIRM" then
        local slot = tonumber(arg1)
        if isLootingSession and slot and autoConfirmSlots[slot] then
            ConfirmLootSlot(slot)
            StaticPopup_Hide("LOOT_BIND")
        end

    elseif event == "LOOT_SLOT_CLEARED" then
        if isLootingSession and IsPlayerMasterLooter() then
            if not HasAnyLootRemaining() then
                C_Timer.After(0.05, function()
                    if isLootingSession and not HasAnyLootRemaining() then
                        CloseLoot()
                    end
                end)
            end
        end

    elseif event == "LOOT_CLOSED" then
        isLootingSession = false
        StopLootTicker()
    end
end)

-- ============================================================================
-- Configuration GUI (/lootwiz or /lw) - Stock Neutral Grey & Gold Styling
-- ============================================================================
local guiFrame = nil
local activeEditBox = nil

local function CreateStyledButton(parent, width, height, text)
    local btn = CreateFrame("Button", nil, parent)
    btn:SetWidth(width)
    btn:SetHeight(height)
    btn:SetBackdrop({
        bgFile = "Interface\\ChatFrame\\ChatFrameBackground",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 12,
        insets = { left = 3, right = 3, top = 3, bottom = 3 }
    })
    btn:SetBackdropColor(0.14, 0.14, 0.14, 0.95)
    btn:SetBackdropBorderColor(0.45, 0.45, 0.45, 1)

    local fs = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    fs:SetPoint("CENTER", 0, 0)
    fs:SetText(text)
    btn.text = fs

    btn:SetScript("OnEnter", function(self)
        if not self.isSelected then
            self:SetBackdropBorderColor(1.0, 0.82, 0.0, 1)
        end
    end)
    btn:SetScript("OnLeave", function(self)
        if not self.isSelected then
            self:SetBackdropBorderColor(0.45, 0.45, 0.45, 1)
        end
    end)

    return btn
end

local function CreateListPanel(parent, titleText, subtitleText, dbTableKey, xOffset)
    local panel = CreateFrame("Frame", nil, parent)
    panel:SetWidth(235)
    panel:SetHeight(290)
    panel:SetPoint("TOPLEFT", parent, "TOPLEFT", xOffset, -134)
    panel:SetBackdrop({
        bgFile = "Interface\\ChatFrame\\ChatFrameBackground",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 12,
        insets = { left = 3, right = 3, top = 3, bottom = 3 }
    })
    panel:SetBackdropColor(0.05, 0.05, 0.05, 0.92)
    panel:SetBackdropBorderColor(0.40, 0.40, 0.40, 1)

    local title = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOPLEFT", 10, -10)
    title:SetText(titleText)

    local sub = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    sub:SetPoint("TOPLEFT", 10, -26)
    sub:SetTextColor(0.70, 0.70, 0.70)
    sub:SetText(subtitleText)

    -- Input Box
    local editBox = CreateFrame("EditBox", nil, panel)
    editBox:SetPoint("TOPLEFT", 10, -45)
    editBox:SetWidth(160)
    editBox:SetHeight(24)
    editBox:SetAutoFocus(false)
    editBox:SetFontObject(ChatFontNormal)
    editBox:SetTextInsets(6, 6, 0, 0)
    editBox:SetBackdrop({
        bgFile = "Interface\\ChatFrame\\ChatFrameBackground",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 12,
        insets = { left = 3, right = 3, top = 3, bottom = 3 }
    })
    editBox:SetBackdropColor(0.0, 0.0, 0.0, 0.95)
    editBox:SetBackdropBorderColor(0.40, 0.40, 0.40, 1)

    editBox:SetScript("OnEditFocusGained", function(self)
        activeEditBox = self
        self:SetBackdropBorderColor(1.0, 0.82, 0.0, 1)
    end)
    editBox:SetScript("OnEditFocusLost", function(self)
        if activeEditBox == self then
            activeEditBox = nil
        end
        self:SetBackdropBorderColor(0.40, 0.40, 0.40, 1)
    end)
    editBox:SetScript("OnEscapePressed", function(self)
        self:ClearFocus()
    end)

    local addBtn = CreateStyledButton(panel, 50, 24, "Add")
    addBtn:SetPoint("LEFT", editBox, "RIGHT", 5, 0)

    -- Scrollable Row List (8 visible rows + mousewheel scrolling)
    local listContainer = CreateFrame("Frame", nil, panel)
    listContainer:SetPoint("TOPLEFT", 10, -76)
    listContainer:SetPoint("BOTTOMRIGHT", -10, 10)
    listContainer:EnableMouseWheel(true)

    local MAX_ROWS = 8
    local rows = {}
    local scrollOffset = 0
    local sortedKeys = {}

    local function RefreshList()
        wipe(sortedKeys)
        local dbList = LootWizDB[dbTableKey]
        for k, displayVal in pairs(dbList) do
            table.insert(sortedKeys, { key = k, display = type(displayVal) == "string" and displayVal or k })
        end
        table.sort(sortedKeys, function(a, b)
            return a.display:lower() < b.display:lower()
        end)

        local maxOffset = math.max(0, #sortedKeys - MAX_ROWS)
        if scrollOffset > maxOffset then
            scrollOffset = maxOffset
        end

        for i = 1, MAX_ROWS do
            local row = rows[i]
            local dataIndex = scrollOffset + i
            local entry = sortedKeys[dataIndex]
            if entry then
                row.label:SetText(entry.display)
                row.entryKey = entry.key
                row:Show()
            else
                row:Hide()
            end
        end
    end

    for i = 1, MAX_ROWS do
        local row = CreateFrame("Frame", nil, listContainer)
        row:SetWidth(215)
        row:SetHeight(23)
        row:SetPoint("TOPLEFT", 0, -((i - 1) * 24))
        row:SetBackdrop({
            bgFile = "Interface\\ChatFrame\\ChatFrameBackground",
        })
        row:SetBackdropColor(0.12, 0.12, 0.12, 0.80)

        local label = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        label:SetPoint("LEFT", 6, 0)
        label:SetWidth(180)
        label:SetJustifyH("LEFT")
        row.label = label

        local delBtn = CreateStyledButton(row, 22, 19, "|cffff5555X|r")
        delBtn:SetPoint("RIGHT", -2, 0)
        delBtn:SetScript("OnClick", function()
            if row.entryKey then
                LootWizDB[dbTableKey][row.entryKey] = nil
                RefreshList()
            end
        end)

        rows[i] = row
    end

    listContainer:SetScript("OnMouseWheel", function(self, delta)
        if delta > 0 then
            scrollOffset = math.max(0, scrollOffset - 1)
        else
            local maxOffset = math.max(0, #sortedKeys - MAX_ROWS)
            scrollOffset = math.min(maxOffset, scrollOffset + 1)
        end
        RefreshList()
    end)

    local function AddCurrentInput()
        local key, display = NormalizeKey(editBox:GetText())
        if key then
            LootWizDB[dbTableKey][key] = display
            editBox:SetText("")
            RefreshList()
        end
    end

    addBtn:SetScript("OnClick", AddCurrentInput)
    editBox:SetScript("OnEnterPressed", AddCurrentInput)

    panel.RefreshList = RefreshList
    RefreshList()
    return panel
end

local function BuildGUI()
    if guiFrame then return guiFrame end

    local f = CreateFrame("Frame", "LootWizGUIFrame", UIParent)
    f:SetWidth(500)
    f:SetHeight(452)
    f:SetPoint("CENTER", 0, 40)
    f:SetFrameStrata("DIALOG")
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function(self) self:StartMoving() end)
    f:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)
    f:SetBackdrop({
        bgFile = "Interface\\ChatFrame\\ChatFrameBackground",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 14,
        insets = { left = 4, right = 4, top = 4, bottom = 4 }
    })
    f:SetBackdropColor(0.08, 0.08, 0.08, 0.95)
    f:SetBackdropBorderColor(0.50, 0.50, 0.50, 1)

    tinsert(UISpecialFrames, "LootWizGUIFrame")

    -- Header (Stock WoW yellow/gold, no author text)
    local header = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    header:SetPoint("TOPLEFT", 16, -14)
    header:SetText("|cffffd100LootWiz|r")

    local closeBtn = CreateStyledButton(f, 24, 22, "X")
    closeBtn:SetPoint("TOPRIGHT", -12, -12)
    closeBtn:SetScript("OnClick", function() f:Hide() end)

    local statusText = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    statusText:SetPoint("TOPLEFT", 16, -36)
    f.statusText = statusText

    -- Threshold Selector Row
    local threshLabel = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    threshLabel:SetPoint("TOPLEFT", 16, -58)
    threshLabel:SetText("Master Loot Threshold (Items below this rarity are auto-looted to you):")

    local threshQualities = { 1, 2, 3, 4, 5 }
    local threshButtons = {}

    for i, qIndex in ipairs(threshQualities) do
        local qInfo = QUALITY_INFO[qIndex]
        local btn = CreateStyledButton(f, 88, 24, qInfo.hex .. qInfo.name .. "|r")
        btn:SetPoint("TOPLEFT", 16 + ((i - 1) * 93), -76)
        btn.qualityIndex = qIndex
        btn:SetScript("OnClick", function()
            SetLootWizThreshold(qIndex, false)
        end)
        threshButtons[qIndex] = btn
    end

    -- BoP Exclusion Checkbox
    local bopCheck = CreateFrame("CheckButton", "LootWizIgnoreBoPCheck", f, "UICheckButtonTemplate")
    bopCheck:SetWidth(24)
    bopCheck:SetHeight(24)
    bopCheck:SetPoint("TOPLEFT", 14, -104)
    bopCheck:SetChecked(LootWizDB.ignoreBoP and true or false)

    local bopLabel = bopCheck:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    bopLabel:SetPoint("LEFT", bopCheck, "RIGHT", 4, 1)
    bopLabel:SetText("Leave Bind on Pickup (BoP) items in loot window")

    bopCheck:SetScript("OnClick", function(self)
        LootWizDB.ignoreBoP = self:GetChecked() and true or false
        if LootWizDB.ignoreBoP then
            Print("Bind on Pickup (BoP) items will now be |cffff5555left in the loot window|r.")
        else
            Print("Bind on Pickup (BoP) items below threshold will now be |cff1eff00auto-looted|r.")
        end
    end)

    function ns.UpdateGUIBoPCheckbox()
        if bopCheck then
            bopCheck:SetChecked(LootWizDB.ignoreBoP and true or false)
        end
    end

    function ns.UpdateGUIThresholdButtons()
        local current = LootWizDB.threshold or 2
        for qIndex, btn in pairs(threshButtons) do
            if qIndex == current then
                btn.isSelected = true
                local q = QUALITY_INFO[qIndex]
                btn:SetBackdropBorderColor(q.r, q.g, q.b, 1)
                btn:SetBackdropColor(0.24, 0.24, 0.24, 1)
            else
                btn.isSelected = false
                btn:SetBackdropBorderColor(0.45, 0.45, 0.45, 1)
                btn:SetBackdropColor(0.14, 0.14, 0.14, 0.95)
            end
        end
    end

    function ns.UpdateGUIStatus()
        if not f.statusText then return end
        if IsPlayerMasterLooter() then
            f.statusText:SetText("Status: |cff1eff00Active (You are the Master Looter)|r")
        else
            f.statusText:SetText("Status: |cffffd100Standby (Activates automatically when Master Looter is set)|r")
        end
    end

    -- Always Loot & Ignore Panels
    f.alwaysPanel = CreateListPanel(
        f,
        "|cff1eff00Always Auto-Loot|r",
        "Name, ID, or Shift-click item:",
        "alwaysLootList",
        16
    )

    f.ignorePanel = CreateListPanel(
        f,
        "|cffff5555Ignore (Never Auto-Loot)|r",
        "Name, ID, or Shift-click item:",
        "ignoreList",
        250
    )

    local footer = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    footer:SetPoint("BOTTOMLEFT", 16, 10)
    footer:SetTextColor(0.60, 0.60, 0.60)
    footer:SetText("Tip: Right-clicking your Player Frame -> Loot Threshold also updates LootWiz.")

    f:SetScript("OnShow", function()
        ns.UpdateGUIThresholdButtons()
        ns.UpdateGUIBoPCheckbox()
        ns.UpdateGUIStatus()
        f.alwaysPanel.RefreshList()
        f.ignorePanel.RefreshList()
    end)

    ns.UpdateGUIThresholdButtons()
    ns.UpdateGUIBoPCheckbox()
    ns.UpdateGUIStatus()

    f:Hide()
    guiFrame = f
    return f
end

-- Allow Shift-clicking items from bags/chat/loot into an active LootWiz input box
local origChatEdit_InsertLink = ChatEdit_InsertLink
function ChatEdit_InsertLink(text)
    if activeEditBox and activeEditBox:IsVisible() and text then
        local _, display = NormalizeKey(text)
        if display then
            activeEditBox:SetText(display)
            return true
        end
    end
    if origChatEdit_InsertLink then
        return origChatEdit_InsertLink(text)
    end
end

-- ============================================================================
-- Slash Commands
-- ============================================================================
SLASH_LOOTWIZ1 = "/lootwiz"
SLASH_LOOTWIZ2 = "/lw"
SlashCmdList["LOOTWIZ"] = function(msg)
    local cmd = (msg or ""):gsub("^%s+", ""):gsub("%s+$", ""):lower()
    if cmd == "common" then
        SetLootWizThreshold(1, false)
    elseif cmd == "uncommon" then
        SetLootWizThreshold(2, false)
    elseif cmd == "rare" then
        SetLootWizThreshold(3, false)
    elseif cmd == "epic" then
        SetLootWizThreshold(4, false)
    elseif cmd == "bop" then
        LootWizDB.ignoreBoP = not LootWizDB.ignoreBoP
        if ns.UpdateGUIBoPCheckbox then
            ns.UpdateGUIBoPCheckbox()
        end
        if LootWizDB.ignoreBoP then
            Print("Bind on Pickup (BoP) items will now be |cffff5555left in the loot window|r.")
        else
            Print("Bind on Pickup (BoP) items below threshold will now be |cff1eff00auto-looted|r.")
        end
    else
        local f = BuildGUI()
        if f:IsShown() then
            f:Hide()
        else
            f:Show()
        end
    end
end