local ADDON_NAME, ns = ...
local RS = ns.RS
if not RS then return end -- Red Flag missing (Sync.lua already told the user)

local frame

local function Text(parent, font, ...)
    local fs = parent:CreateFontString(nil, "OVERLAY", font or "GameFontHighlight")
    if ... then fs:SetPoint(...) end
    fs:SetJustifyH("LEFT")
    return fs
end

local function Button(parent, label, width, ...)
    local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    b:SetSize(width, 22)
    b:SetText(label)
    if ... then b:SetPoint(...) end
    return b
end

local function FormatDate(t)
    return t and date("%Y-%m-%d %H:%M", t) or "never"
end

local function RankText(limit)
    if limit == nil then return "All ranks" end
    if limit == 0 then
        local gm = GuildControlGetRankName and GuildControlGetRankName(1)
        return ((gm and gm ~= "") and gm or "Guild Master") .. " only"
    end
    local rankName = GuildControlGetRankName and GuildControlGetRankName(limit + 1)
    return ((rankName and rankName ~= "") and rankName or ("Rank " .. limit)) .. " & above"
end

local function Create()
    local f = CreateFrame("Frame", "RedFlagSyncSettings", UIParent, "BasicFrameTemplateWithInset")
    f:SetSize(380, 440)
    f:SetPoint("CENTER", 380, 0)
    f:SetFrameStrata("HIGH")
    f:SetToplevel(true)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:SetClampedToScreen(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f:Hide()
    tinsert(UISpecialFrames, "RedFlagSyncSettings")

    if f.TitleText then
        f.TitleText:SetText("Red Flag Sync")
    else
        Text(f, "GameFontHighlight", "TOP", 0, -5):SetText("Red Flag Sync")
    end

    local x = 18
    f.guild = Text(f, "GameFontNormalLarge", "TOPLEFT", x, -36)
    f.guild:SetWidth(340)

    local cb = CreateFrame("CheckButton", nil, f, "UICheckButtonTemplate")
    cb:SetSize(26, 26)
    cb:SetPoint("TOPLEFT", x - 4, -62)
    Text(cb, "GameFontHighlight", "LEFT", cb, "RIGHT", 2, 1):SetText("Sync with guild members")
    cb:SetScript("OnClick", function(self)
        RS.db.global.settings.sync = self:GetChecked() and true or false
        RS:UpdateSettings()
    end)
    f.syncCheck = cb

    local syncNow = Button(f, "Sync Now", 100, "TOPLEFT", x, -94)
    syncNow:SetScript("OnClick", function() RS:RequestSync(true) end)
    local open = Button(f, "Open Guild List", 130, "LEFT", syncNow, "RIGHT", 6, 0)
    open:SetScript("OnClick", function() RedFlagAPI.ShowList("guild", "players") end)

    f.status = Text(f, "GameFontHighlightSmall", "TOPLEFT", x, -126)
    f.status:SetWidth(340)

    -- rank pickers cycle: All ranks -> Guild Master -> next rank & above -> ... -> All ranks
    local function RankPicker(key, label, y)
        Text(f, "GameFontHighlight", "TOPLEFT", x, y):SetText(label)
        local btn = Button(f, "", 170, "TOPLEFT", x + 160, y + 4)
        btn:SetScript("OnClick", function()
            local d = RS:GuildData(true) -- ranks are stored per guild
            local num = GuildControlGetNumRanks and GuildControlGetNumRanks() or 0
            if not d or num == 0 then return end
            if d[key] == nil then
                d[key] = 0
            elseif d[key] + 1 >= num - 1 then
                d[key] = nil -- "lowest rank & above" would equal all ranks
            else
                d[key] = d[key] + 1
            end
            RS:UpdateSettings()
        end)
        btn.key = key
        return btn
    end
    f.shareBtn = RankPicker("shareRank", "Share my list with:", -168)
    f.acceptBtn = RankPicker("acceptRank", "Accept changes from:", -196)

    local info = Text(f, "GameFontDisableSmall", "TOPLEFT", x, -228)
    info:SetWidth(340)
    info:SetSpacing(2)
    info:SetText(
        "Each guild has its own guild list. These settings apply to the guild of this character.\n\n" ..
        "Share my list with: who your client sends guild-list entries and community notes to.\n" ..
        "Accept changes from: whose additions, edits and removals your client takes in.\n\n" ..
        "These apply to your client only. Every player sets their own, so to keep the list " ..
        "among officers, every officer needs the same settings.\n\n" ..
        "Only members of this guild who run Red Flag Sync take part, and nothing is ever posted " ..
        "in chat. Personal lists and personal notes are never sent. When none of your characters " ..
        "is in a guild anymore, its guild list is deleted.")
    -- grow the window to fit the text (font sizes differ between UI setups)
    f:SetHeight(228 + info:GetStringHeight() + 24)

    frame = f
end

function RS:UpdateSettings()
    if not frame or not frame:IsShown() then return end
    local key = self:CurrentGuildKey()
    frame.guild:SetText(key and ("Guild list <" .. (strsplit("-", key)) .. ">") or "|cffff8040No guild|r")
    frame.syncCheck:SetChecked(self.db.global.settings.sync and true or false)

    local d = self:GuildData(false)
    for _, btn in ipairs({ frame.shareBtn, frame.acceptBtn }) do
        btn:SetText(RankText(d and d[btn.key]))
        btn:SetEnabled(IsInGuild())
    end

    local ok, reason = self:SyncAllowed()
    frame.status:SetText((ok and "|cff40ff40Sync active.|r" or ("|cffff8040" .. reason .. "|r"))
        .. "\nLast full sync: " .. FormatDate(d and d.lastSync))
end

function RS:ToggleSettings()
    if not frame then Create() end
    if frame:IsShown() then
        frame:Hide()
    else
        frame:Show()
        self:UpdateSettings()
    end
end
