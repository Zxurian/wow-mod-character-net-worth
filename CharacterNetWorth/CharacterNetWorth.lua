-- Character Net Worth
-- Adds up the vendor (sell) value of every item the character has equipped,
-- in their bags, and in their bank, and shows the total on the character screen.
--
-- The bank can only be read while it is open, so its value is scanned each
-- time you visit a banker and saved per character between sessions.

local ADDON_NAME = ...

-- API compatibility (retail moved these into C_Item / C_Container)
local GetItemInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
local GetContainerNumSlots = (C_Container and C_Container.GetContainerNumSlots) or GetContainerNumSlots

local function GetContainerSlot(bag, slot)
    if C_Container and C_Container.GetContainerItemInfo then
        local info = C_Container.GetContainerItemInfo(bag, slot)
        if info then
            return info.hyperlink, info.stackCount or 1
        end
        return nil
    end
    -- Older clients return multiple values
    local _, count, _, _, _, _, link = GetContainerItemInfo(bag, slot)
    return link, count or 1
end

-- Equipment slots 1..19 (head through tabard)
local FIRST_EQUIP_SLOT = INVSLOT_FIRST_EQUIPPED or 1
local LAST_EQUIP_SLOT = INVSLOT_LAST_EQUIPPED or 19

-- Backpack (0) through the last equipped bag (includes the reagent bag on retail)
local FIRST_BAG = BACKPACK_CONTAINER or 0
local LAST_BAG = NUM_TOTAL_EQUIPPED_BAG_SLOTS or NUM_BAG_SLOTS or 4

local BAG_CONTAINERS = {}
for bag = FIRST_BAG, LAST_BAG do
    table.insert(BAG_CONTAINERS, bag)
end

-- Character bank containers. Retail 11.2+ uses bank tabs; older retail and
-- Classic use the main bank slots plus bank bags (and a reagent bank on some
-- retail versions). The account-wide Warband bank is deliberately excluded.
local BANK_CONTAINERS = {}
if Enum and Enum.BagIndex and Enum.BagIndex.CharacterBankTab_1 then
    for i = 1, 6 do
        local bag = Enum.BagIndex["CharacterBankTab_" .. i]
        if bag then
            table.insert(BANK_CONTAINERS, bag)
        end
    end
else
    table.insert(BANK_CONTAINERS, BANK_CONTAINER or -1)
    for i = 1, (NUM_BANKBAGSLOTS or 0) do
        table.insert(BANK_CONTAINERS, LAST_BAG + i)
    end
    if REAGENTBANK_CONTAINER then
        table.insert(BANK_CONTAINERS, REAGENTBANK_CONTAINER)
    end
end

-- Returns the per-unit sell price of an item link, or nil if the item
-- isn't in the client cache yet.
local function GetSellPrice(link)
    local name, _, _, _, _, _, _, _, _, _, sellPrice = GetItemInfo(link)
    if not name then
        return nil
    end
    return sellPrice or 0
end

-- Sums the value of every item in the given containers. `pending` is true if
-- some item info hadn't loaded yet; GET_ITEM_INFO_RECEIVED triggers a rescan.
local function SumContainers(containers)
    local total, pending = 0, false
    for _, bag in ipairs(containers) do
        local numSlots = GetContainerNumSlots(bag) or 0
        for slot = 1, numSlots do
            local link, count = GetContainerSlot(bag, slot)
            if link then
                local price = GetSellPrice(link)
                if price then
                    total = total + price * count
                else
                    pending = true
                end
            end
        end
    end
    return total, pending
end

local function SumEquipped()
    local total, pending = 0, false
    for slot = FIRST_EQUIP_SLOT, LAST_EQUIP_SLOT do
        local link = GetInventoryItemLink("player", slot)
        if link then
            local price = GetSellPrice(link)
            if price then
                total = total + price
            else
                pending = true
            end
        end
    end
    return total, pending
end

local function FormatMoney(copper)
    if GetMoneyString then
        return GetMoneyString(copper, true)
    end
    return GetCoinTextureString(copper)
end

---------------------------------------------------------------------------
-- Saved bank data (per character)
---------------------------------------------------------------------------

local db -- zx_cnw_DB once ADDON_LOADED fires
local bankOpen = false

local function BankValue()
    return (db and db.bank) or 0
end

---------------------------------------------------------------------------
-- UI: a small hoverable label on the character (paper doll) screen
---------------------------------------------------------------------------

local display = CreateFrame("Frame", "zx_cnw_Frame", PaperDollFrame)
display:SetSize(160, 32)
display:SetPoint("TOPLEFT", CharacterHeadSlot, "TOPRIGHT", 8, 0)
display:SetFrameStrata("HIGH")

local label = display:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
label:SetPoint("TOPLEFT")
label:SetText("Net Worth")

local value = display:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
value:SetPoint("TOPLEFT", label, "BOTTOMLEFT", 0, -2)

local lastEquipped, lastBags, lastPending = 0, 0, false
local needsUpdate = true

local function Refresh()
    if not PaperDollFrame:IsVisible() then
        needsUpdate = true
        return
    end
    needsUpdate = false

    local equipped, equippedPending = SumEquipped()
    local bags, bagsPending = SumContainers(BAG_CONTAINERS)
    lastEquipped, lastBags = equipped, bags
    lastPending = equippedPending or bagsPending or (db and db.bankPending) or false

    local text = FormatMoney(lastEquipped + lastBags + BankValue() + GetMoney())
    if lastPending then
        text = text .. " |cff888888(...)|r"
    end
    value:SetText(text)
end

local function ScanBank()
    if not bankOpen or not db then
        return
    end
    local total, pending = SumContainers(BANK_CONTAINERS)
    db.bank = total
    db.bankPending = pending
    db.bankScanned = time()
    Refresh()
end

display:EnableMouse(true)
display:SetScript("OnEnter", function(self)
    local bank = BankValue()
    local items = lastEquipped + lastBags + bank
    local white, gold = { 1, 1, 1 }, { 1, 0.82, 0 }

    GameTooltip:SetOwner(self, "ANCHOR_NONE")
    GameTooltip:ClearAllPoints()
    GameTooltip:SetPoint("TOPLEFT", self, "BOTTOMLEFT", 0, -2)
    GameTooltip:AddLine("Character Net Worth")
    GameTooltip:AddDoubleLine("Equipped items", FormatMoney(lastEquipped), white[1], white[2], white[3], 1, 1, 1)
    GameTooltip:AddDoubleLine("Bag items", FormatMoney(lastBags), white[1], white[2], white[3], 1, 1, 1)
    if db and db.bankScanned then
        GameTooltip:AddDoubleLine("Bank items", FormatMoney(bank), white[1], white[2], white[3], 1, 1, 1)
    else
        GameTooltip:AddDoubleLine("Bank items", "visit a banker", white[1], white[2], white[3], 0.6, 0.6, 0.6)
    end
    GameTooltip:AddDoubleLine("Items total", FormatMoney(items), gold[1], gold[2], gold[3], 1, 1, 1)
    GameTooltip:AddLine(" ")
    GameTooltip:AddDoubleLine("Gold on hand", FormatMoney(GetMoney()), white[1], white[2], white[3], 1, 1, 1)
    GameTooltip:AddDoubleLine("Grand total", FormatMoney(items + GetMoney()), gold[1], gold[2], gold[3], 1, 1, 1)

    GameTooltip:AddLine(" ")
    if lastPending then
        GameTooltip:AddLine("Some item data is still loading.", 0.6, 0.6, 0.6)
    end
    if db and db.bankScanned then
        GameTooltip:AddLine("Bank last scanned " .. date("%b %d, %H:%M", db.bankScanned) .. ".", 0.6, 0.6, 0.6)
    end
    GameTooltip:AddLine("Values are vendor sell prices.", 0.6, 0.6, 0.6)
    GameTooltip:Show()
end)
display:SetScript("OnLeave", GameTooltip_Hide)

PaperDollFrame:HookScript("OnShow", Refresh)

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------

local events = CreateFrame("Frame")

-- Some events only exist on certain clients; registering an unknown one errors.
local function TryRegister(event)
    pcall(events.RegisterEvent, events, event)
end

TryRegister("ADDON_LOADED")
TryRegister("PLAYER_EQUIPMENT_CHANGED")
TryRegister("BAG_UPDATE_DELAYED")
TryRegister("PLAYER_MONEY")
TryRegister("GET_ITEM_INFO_RECEIVED")
TryRegister("BANKFRAME_OPENED")
TryRegister("BANKFRAME_CLOSED")
TryRegister("PLAYERBANKSLOTS_CHANGED")
TryRegister("PLAYERREAGENTBANKSLOTS_CHANGED")
TryRegister("PLAYER_INTERACTION_MANAGER_FRAME_SHOW")
TryRegister("PLAYER_INTERACTION_MANAGER_FRAME_HIDE")

local BANKER_INTERACTION = Enum and Enum.PlayerInteractionType and Enum.PlayerInteractionType.Banker

events:SetScript("OnEvent", function(_, event, arg1)
    if event == "ADDON_LOADED" then
        if arg1 == ADDON_NAME then
            zx_cnw_DB = zx_cnw_DB or {}
            db = zx_cnw_DB
            needsUpdate = true
        end
        return
    end

    if event == "BANKFRAME_OPENED"
        or (event == "PLAYER_INTERACTION_MANAGER_FRAME_SHOW" and BANKER_INTERACTION and arg1 == BANKER_INTERACTION) then
        bankOpen = true
        ScanBank()
        return
    end

    if event == "BANKFRAME_CLOSED"
        or (event == "PLAYER_INTERACTION_MANAGER_FRAME_HIDE" and BANKER_INTERACTION and arg1 == BANKER_INTERACTION) then
        bankOpen = false
        return
    end

    if event == "PLAYERBANKSLOTS_CHANGED" or event == "PLAYERREAGENTBANKSLOTS_CHANGED" then
        ScanBank()
        return
    end

    if event == "GET_ITEM_INFO_RECEIVED" then
        if bankOpen and db and db.bankPending then
            ScanBank() -- also refreshes the display
        elseif lastPending or needsUpdate then
            Refresh()
        end
        return
    end

    -- PLAYER_EQUIPMENT_CHANGED / BAG_UPDATE_DELAYED / PLAYER_MONEY
    -- (BAG_UPDATE_DELAYED also fires for bank bags/tabs while the bank is open)
    if bankOpen then
        ScanBank()
    else
        Refresh()
    end
end)
