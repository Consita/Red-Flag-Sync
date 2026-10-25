local ADDON_NAME, ns = ...

-- Red Flag Sync: adds per-guild lists to Red Flag and shares them with guild members.
-- It only talks to Red Flag through RedFlagAPI (version 1), so Red Flag updates don't
-- require updates of this addon.
local API = RedFlagAPI
if type(API) ~= "table" or (API.version or 0) < 1 then
    print("|cffff4040[Red Flag Sync]|r needs Red Flag to be installed and enabled.")
    return
end

local RS = LibStub("AceAddon-3.0"):NewAddon(
    "RedFlagSync",
    "AceEvent-3.0",
    "AceConsole-3.0",
    "AceComm-3.0",
    "AceSerializer-3.0"
)
ns.RS = RS

local MAX_NOTE = API.MAX_NOTE or 500
local TOMBSTONE_TTL = 180 * 24 * 3600 -- removed entries are kept this long so removals sync

-- Guild-only sync.
--   U  single entry update            to members I share with
--   Q  request (digest + the lowest rank the requester accepts from)   GUILD
--   C  "I'm answering <requester>"    GUILD   (other members cancel their answer)
--   D  full dump                      WHISPER to the requester
--   B  batch of entries the requester had newer/extra after a dump   to members I share with
-- Conflicts: newest "mod" timestamp wins. Removals are tombstones so they propagate.
--
-- Security model
--   * Sender names are authenticated by the server; GUILD-channel messages only
--     reach and come from real guild members.
--   * Both ends check the other side, each with its own setting (per guild):
--       shareRank  - data is only SENT to members of this rank or higher
--       acceptRank - data is only ACCEPTED from members of this rank or higher
--     (rank index 0 = guild master; nil = all ranks). Every client applies its own.
--   * Every guild has its own list; a character only sends and receives the list of the
--     guild it is in. Every message carries that guild key; mismatches are rejected.
--   * Direct updates (U) must carry an editor stamp equal to the sender.
--   * Red Flag's personal list and personal notes are never touched by this addon.
local PREFIX = "RedFlagSync"
local PROTO = 2

local defaults = {
    global = {
        guildLists = {}, -- "GuildName-Realm" -> { players, guilds, shareRank, acceptRank, lastSync }
        characters = {}, -- "Name-Realm" -> guild key or false; which guild lists are still needed
        settings = { sync = true },
    },
}

local function Print(msg) API.Print(msg) end

------------------------------------------------------------------------
-- Helpers (same rules as Red Flag, kept here so only RedFlagAPI is needed)
------------------------------------------------------------------------

local function Now() return GetServerTime and GetServerTime() or time() end

local function MyRealm()
    local r = GetNormalizedRealmName and GetNormalizedRealmName()
    if not r or r == "" then r = (GetRealmName() or ""):gsub("[%s%-]", "") end
    return r
end

local function NormRealm(r)
    if not r or r == "" then return MyRealm() end
    return (r:gsub("%s", ""))
end

local function NameKey(name, realm) return "N:" .. (name .. "-" .. realm):lower() end
local function GuildKey(name, realm) return "G:" .. (name .. "-" .. realm):lower() end

local function IsValidGUID(guid)
    return type(guid) == "string" and guid:match("^Player%-%d+%-%x+$") ~= nil
end

local function active(e) return e and not e.del end

local function FullName(name, realm)
    if not realm or realm == MyRealm() then return name end
    return name .. "-" .. realm
end

function RS:CurrentGuildKey()
    if not IsInGuild() then return nil end
    local gName, _, _, gRealm = GetGuildInfo("player")
    if not gName then return nil end
    return gName .. "-" .. NormRealm(gRealm)
end

-- The list record of this character's guild (create = make it if missing).
function RS:GuildData(create)
    local key = self:CurrentGuildKey()
    if not key then return nil end
    local lists = self.db.global.guildLists
    if not lists[key] and lists["?"] then
        -- old data whose guild wasn't known: the first guild claims it
        lists[key], lists["?"] = lists["?"], nil
    end
    if not lists[key] and create then
        lists[key] = { players = {}, guilds = {} }
    end
    return lists[key], key
end

local function List(kind)
    local d = RS:GuildData(false)
    return d and d[kind]
end

------------------------------------------------------------------------
-- The list provider shown in Red Flag
------------------------------------------------------------------------

local NO_GUILD = "This character is not in a guild, so it has no guild list. Use your personal list instead."

local provider = {
    id = "guild",
    label = "Guild",
    tabs = { players = "Players", guilds = "Guilds" },
    noteName = "Community",
    noteLabel = "Community note |cff888888(shared with guild)|r",
    shareText = "Share with Guild",
    removeText = "This also removes it for your guild members.",
}

function provider:IsAvailable()
    if not RS:CurrentGuildKey() then return false, NO_GUILD end
    return true
end

function provider:StatusText()
    local key = RS:CurrentGuildKey()
    if not key then return "|cffff8040No guild - this character has no guild list|r" end
    return "|cff40ff40Guild list <" .. (strsplit("-", key)) .. ">|r |cff888888- synced with this guild|r"
end

function provider:Iterate(kind)
    local out = {}
    for _, e in pairs(List(kind) or {}) do
        if active(e) then out[#out + 1] = e end
    end
    return out
end

function provider:Get(kind, id)
    local t = List(kind)
    local e = t and id and t[id]
    if active(e) then return e end
end

-- with a GUID: that GUID, or an entry added by name only; without: any entry with that name
function provider:Find(kind, guid, name, realm)
    local t = List(kind)
    if not t then return nil end
    realm = NormRealm(realm)
    if kind == "guilds" then
        local e = name and t[GuildKey(name, realm)]
        return active(e) and e or nil
    end
    if guid and active(t[guid]) then return t[guid] end
    if not name then return nil end
    local byName = t[NameKey(name, realm)]
    if active(byName) then return byName end
    if guid then return nil end
    local ln, lr = name:lower(), realm:lower()
    for _, e in pairs(t) do
        if active(e) and e.name:lower() == ln and (e.realm or ""):lower() == lr then return e end
    end
end

function provider:Add(kind, e)
    if not RS:GuildData(true) then return nil end
    local now = Now()
    local entry = {
        id = e.id, guid = e.guid, name = e.name, realm = e.realm, class = e.class,
        note = (e.note or ""):sub(1, MAX_NOTE),
        by = e.by or UnitName("player"), added = e.added or now, mod = now,
    }
    RS:Commit(kind, entry)
    return entry
end

function provider:SetNote(kind, id, note)
    local old = self:Get(kind, id)
    if not old then return end
    local e = CopyTable(old)
    e.note = (note or ""):sub(1, MAX_NOTE)
    e.mod = math.max(Now(), (old.mod or 0) + 1)
    RS:Commit(kind, e)
end

function provider:Remove(kind, id)
    local old = self:Get(kind, id)
    if not old then return end
    local e = CopyTable(old)
    e.del, e.note = true, ""
    e.mod = math.max(Now(), (old.mod or 0) + 1)
    RS:Commit(kind, e)
end

function provider:PlayerSeen(info) RS:PlayerSeen(info) end
function provider:OpenSettings() RS:ToggleSettings() end

------------------------------------------------------------------------
-- Local changes (stamped with me as editor; receivers check that stamp)
------------------------------------------------------------------------

function RS:Commit(kind, entry)
    local d = self:GuildData(true)
    if not d then return false end
    entry.ed = UnitName("player")
    d[kind][entry.id] = entry
    self:BroadcastEntry(kind, entry)
    API.Refresh()
    return true
end

-- a player with a GUID was seen: fill in GUIDs of entries added by name, track renames
function RS:PlayerSeen(info)
    local players = List("players")
    if not players or not info.guid then return end
    local n, r = info.name, info.realm
    local byGuid = players[info.guid]
    local nameKey = NameKey(n, r)
    local byName = players[nameKey]

    if active(byName) then
        local now = math.max(Now(), (byName.mod or 0) + 1)
        if active(byGuid) then
            if byName.note ~= "" and byName.note ~= byGuid.note then
                local merged = CopyTable(byGuid)
                merged.note = ((byGuid.note ~= "" and (byGuid.note .. "\n") or "") .. byName.note):sub(1, MAX_NOTE)
                merged.mod = now
                self:Commit("players", merged)
            end
        else
            local e = CopyTable(byName)
            e.id, e.guid, e.class, e.mod = info.guid, info.guid, info.class or e.class, now
            self:Commit("players", e)
        end
        local tomb = CopyTable(byName)
        tomb.del, tomb.note, tomb.mod = true, "", now
        self:Commit("players", tomb)
        return
    end

    if active(byGuid) and (byGuid.name ~= n or byGuid.realm ~= r or (info.class and byGuid.class ~= info.class)) then
        local e = CopyTable(byGuid)
        if e.name ~= n then
            Print(("Blacklisted %s (guild list) is now named %s."):format(e.name, n))
        end
        e.name, e.realm, e.class = n, r, info.class or e.class
        e.mod = math.max(Now(), (byGuid.mod or 0) + 1)
        self:Commit("players", e)
    end
end

function RS:PurgeTombstones()
    local cutoff = Now() - TOMBSTONE_TTL
    for _, d in pairs(self.db.global.guildLists) do
        for _, kind in ipairs({ "players", "guilds" }) do
            local t = type(d) == "table" and d[kind]
            if type(t) == "table" then
                for id, e in pairs(t) do
                    if type(e) ~= "table" or (e.del and (e.mod or 0) < cutoff) then t[id] = nil end
                end
            end
        end
    end
end

------------------------------------------------------------------------
-- Leaving a guild: a guild list only exists while one of my characters is in that guild.
------------------------------------------------------------------------

local function CharKey() return UnitName("player") .. "-" .. MyRealm() end

function RS:DropGuildList(key)
    local lists = self.db.global.guildLists
    local d = lists[key]
    if not d then return end
    lists[key] = nil
    local count = 0
    for _, kind in ipairs({ "players", "guilds" }) do
        for _, e in pairs(type(d[kind]) == "table" and d[kind] or {}) do
            if type(e) == "table" then
                if active(e) then count = count + 1 end
                API.ForgetPersonalNote(kind, e) -- only if it is on no other list
            end
        end
    end
    Print(("You are no longer in <%s>, so its guild list (%d entr%s) was deleted. Your personal list is unchanged.")
        :format((strsplit("-", key)), count, count == 1 and "y" or "ies"))
    API.Refresh()
end

function RS:CheckGuildMembership()
    local key = self:CurrentGuildKey()
    if IsInGuild() and not key then return end -- guild info not loaded yet: decide later
    local chars = self.db.global.characters
    local me = CharKey()
    local prev = chars[me]
    chars[me] = key or false
    if not prev or prev == key then return end
    for _, g in pairs(chars) do
        if g == prev then return end -- another of my characters is still in that guild
    end
    self:DropGuildList(prev)
end

function RS:ScheduleGuildCheck(delay)
    C_Timer.After(delay, function() RS:CheckGuildMembership() end)
end

------------------------------------------------------------------------
-- Roster / trust
------------------------------------------------------------------------

local guildMembers = {}   -- lowercase "name" and "name-realm" -> rankIndex (0 = guild master)
local onlineMembers = {}  -- full names currently online
local pendingAnswers = {} -- requester -> true while we wait to answer
local lastRosterRequest = 0

local function RequestRoster()
    if GetTime() - lastRosterRequest < 10 then return end
    lastRosterRequest = GetTime()
    if C_GuildInfo and C_GuildInfo.GuildRoster then
        C_GuildInfo.GuildRoster()
    elseif GuildRoster then
        GuildRoster()
    end
end

function RS:SyncAllowed()
    if not self.db.global.settings.sync then return false, "Sync is disabled." end
    if not self:CurrentGuildKey() then return false, "Not in a guild (or guild info not loaded yet)." end
    return true
end

local function GuildSetting(key)
    local d = RS:GuildData(false)
    return d and d[key]
end

function RS:RebuildGuildMembers()
    wipe(guildMembers)
    wipe(onlineMembers)
    if IsInGuild() then
        local myRealm = MyRealm():lower()
        local me = UnitName("player"):lower()
        for i = 1, GetNumGuildMembers() do
            local full, _, rankIndex, _, _, _, _, _, online = GetGuildRosterInfo(i)
            if full then
                local lower = full:lower()
                if not lower:find("-", 1, true) then lower = lower .. "-" .. myRealm end
                guildMembers[lower] = rankIndex
                local short, realm = strsplit("-", lower, 2)
                if realm == myRealm then guildMembers[short] = rankIndex end
                if online and short ~= me then onlineMembers[#onlineMembers + 1] = full end
            end
        end
    end
    self:UpdateSettings()
end

local function MemberRank(name)
    local s = name:lower()
    if guildMembers[s] then return guildMembers[s] end
    if not s:find("-", 1, true) then
        return guildMembers[s .. "-" .. MyRealm():lower()]
    end
end

-- In our guild right now and at rank `limit` or higher (lower index = higher rank).
local function RankOK(name, limit)
    if not name then return false end
    local rank = MemberRank(name)
    if not rank then
        RequestRoster() -- maybe they just joined; next message will know
        return false
    end
    return limit == nil or rank <= limit
end

function RS:CanShareWith(name) return RankOK(name, GuildSetting("shareRank")) end
function RS:CanAcceptFrom(name) return RankOK(name, GuildSetting("acceptRank")) end

local function MyRank()
    local _, _, rankIndex = GetGuildInfo("player")
    return rankIndex
end

local function ShortName(name)
    return (strsplit("-", Ambiguate(name, "none"), 2))
end

local function IsMe(sender)
    return ShortName(sender) == UnitName("player")
end

------------------------------------------------------------------------
-- Validation / merge
------------------------------------------------------------------------

local function str(v, max)
    if type(v) ~= "string" then return nil end
    return v:sub(1, max)
end

local function Sanitize(kind, e)
    if type(e) ~= "table" or type(e.id) ~= "string" or type(e.mod) ~= "number" then return nil end
    -- reject timestamps from the future (more than a day): they could never be overwritten
    if e.mod > Now() + 86400 then return nil end
    local name, realm = str(e.name, 64), str(e.realm, 64)
    if not name or name == "" or not realm or realm == "" then return nil end
    local c = {
        id = e.id,
        name = name,
        realm = realm,
        note = str(e.note, MAX_NOTE) or "",
        by = str(e.by, 64),
        ed = str(e.ed, 64),
        added = type(e.added) == "number" and e.added or e.mod,
        mod = e.mod,
        del = e.del and true or nil,
    }
    if kind == "players" then
        if e.guid ~= nil then
            if not IsValidGUID(e.guid) or e.id ~= e.guid then return nil end
            c.guid = e.guid
        elseif e.id ~= NameKey(name, realm) then
            return nil
        end
        c.class = str(e.class, 20)
    elseif kind == "guilds" then
        if e.id ~= GuildKey(name, realm) then return nil end
    else
        return nil
    end
    return c
end

-- returns true if the incoming entry replaced ours
function RS:MergeEntry(kind, e)
    e = Sanitize(kind, e)
    if not e then return false end
    local d = self:GuildData(true)
    if not d then return false end
    local list = d[kind]
    local cur = list[e.id]
    if cur and (cur.mod or 0) >= e.mod then return false end
    -- someone else removed an entry I have a personal note on: keep it on my personal list
    if e.del and active(cur) and API.HasPersonalNote(kind, cur) then
        API.KeepAsPersonal(kind, cur, e.ed, "Guild")
    end
    list[e.id] = e
    return true
end

function RS:Digest()
    local count, sum = 0, 0
    local d = self:GuildData(false)
    for _, kind in ipairs({ "players", "guilds" }) do
        for _, e in pairs(d and d[kind] or {}) do
            count = count + 1
            sum = sum + (e.mod or 0)
        end
    end
    return ("%d:%d"):format(count, sum)
end

------------------------------------------------------------------------
-- Sending
------------------------------------------------------------------------

function RS:SendSync(msg, dist, target, prio)
    msg.v = PROTO
    msg.gk = self:CurrentGuildKey()
    self:SendCommMessage(PREFIX, self:Serialize(msg), dist, target, prio or "NORMAL")
end

-- Data-carrying messages: the whole guild channel when I share with every rank,
-- otherwise a whisper to each online member I share with.
function RS:SendToShared(msg, prio)
    if GuildSetting("shareRank") == nil then
        self:SendSync(msg, "GUILD", nil, prio)
        return
    end
    for _, name in ipairs(onlineMembers) do
        if self:CanShareWith(name) then
            self:SendSync(msg, "WHISPER", name, prio)
        end
    end
end

function RS:BroadcastEntry(kind, entry)
    if not self:SyncAllowed() then return end
    self:SendToShared({ t = "U", k = kind, e = entry })
end

function RS:RequestSync(manual)
    local ok, reason = self:SyncAllowed()
    if not ok then
        if manual then Print("Sync not possible: " .. reason) end
        return
    end
    self:SendSync({ t = "Q", d = self:Digest(), ar = GuildSetting("acceptRank") }, "GUILD")
    if manual then Print("Sync requested from online guild members.") end
end

local function FullDump()
    local d = RS:GuildData(false)
    return { t = "D", p = d and d.players or {}, g = d and d.guilds or {} }
end

------------------------------------------------------------------------
-- Receiving
------------------------------------------------------------------------

local function MergeTable(kind, t)
    local changed = 0
    if type(t) ~= "table" then return 0 end
    for _, e in pairs(t) do
        if RS:MergeEntry(kind, e) then changed = changed + 1 end
    end
    return changed
end

function RS:OnCommReceived(prefix, message, dist, sender)
    if prefix ~= PREFIX or not sender or IsMe(sender) then return end
    if dist ~= "GUILD" and dist ~= "WHISPER" then return end
    if not self:SyncAllowed() then return end
    -- whatever the message, the sender must be in our guild right now
    if not MemberRank(sender) then RequestRoster(); return end

    local ok, msg = self:Deserialize(message)
    if not ok or type(msg) ~= "table" or msg.v ~= PROTO then return end
    if not msg.gk or msg.gk ~= self:CurrentGuildKey() then return end

    -- receiver-side check: data is only taken from ranks I accept changes from
    if (msg.t == "U" or msg.t == "D" or msg.t == "B") and not self:CanAcceptFrom(sender) then return end

    if msg.t == "U" then
        if msg.k ~= "players" and msg.k ~= "guilds" then return end
        -- a direct update must be authored by the one sending it
        if type(msg.e) ~= "table" or type(msg.e.ed) ~= "string"
            or msg.e.ed:lower() ~= ShortName(sender):lower() then
            return
        end
        if self:MergeEntry(msg.k, msg.e) then API.Refresh() end

    elseif msg.t == "Q" then
        if dist ~= "GUILD" or msg.d == self:Digest() then return end
        -- only answer people I share with, and only if they'd accept data from my rank
        if not self:CanShareWith(sender) then return end
        if type(msg.ar) == "number" and (MyRank() or 99) > msg.ar then return end
        pendingAnswers[sender] = true
        C_Timer.After(1 + math.random() * 4, function()
            if not pendingAnswers[sender] then return end
            pendingAnswers[sender] = nil
            -- sender-side check, re-done right before data leaves this client
            if not RS:SyncAllowed() or not RS:CanShareWith(sender) then return end
            RS:SendSync({ t = "C", r = sender }, "GUILD")
            RS:SendSync(FullDump(), "WHISPER", sender, "BULK")
        end)

    elseif msg.t == "C" then
        if type(msg.r) == "string" then pendingAnswers[msg.r] = nil end

    elseif msg.t == "D" then
        if dist ~= "WHISPER" then return end
        local p, g = type(msg.p) == "table" and msg.p or {}, type(msg.g) == "table" and msg.g or {}
        local changed = MergeTable("players", p) + MergeTable("guilds", g)

        -- send back what we have that the dump lacked or had older
        local d = self:GuildData(true)
        local back, any = { t = "B", p = {}, g = {} }, false
        for kind, theirs in pairs({ players = p, guilds = g }) do
            local out = kind == "players" and back.p or back.g
            for id, e in pairs(d and d[kind] or {}) do
                local t = theirs[id]
                if type(t) ~= "table" or (t.mod or 0) < (e.mod or 0) then
                    out[id] = e
                    any = true
                end
            end
        end
        if any then self:SendToShared(back, "BULK") end

        if d then d.lastSync = Now() end
        if changed > 0 then
            Print(("Sync from %s: %d change(s)."):format(ShortName(sender), changed))
        end
        API.Refresh()
        self:UpdateSettings()

    elseif msg.t == "B" then
        local changed = MergeTable("players", msg.p) + MergeTable("guilds", msg.g)
        if changed > 0 then API.Refresh() end
    end
end

------------------------------------------------------------------------
-- Lifecycle
------------------------------------------------------------------------

-- First start: take over the guild lists older Red Flag versions kept in their own database.
function RS:ImportLegacy()
    local g = self.db.global
    if g.imported then return end
    local lists, chars = API.LegacyData()
    if type(lists) == "table" then
        for key, d in pairs(lists) do
            if type(d) == "table" then
                local mine = g.guildLists[key] or { players = {}, guilds = {} }
                for _, kind in ipairs({ "players", "guilds" }) do
                    mine[kind] = mine[kind] or {}
                    for id, e in pairs(type(d[kind]) == "table" and d[kind] or {}) do
                        if mine[kind][id] == nil and type(e) == "table" then mine[kind][id] = CopyTable(e) end
                    end
                end
                if mine.shareRank == nil then mine.shareRank = d.shareRank end
                if mine.acceptRank == nil then mine.acceptRank = d.acceptRank end
                mine.lastSync = mine.lastSync or d.lastSync
                g.guildLists[key] = mine
            end
        end
    end
    if type(chars) == "table" then
        for k, v in pairs(chars) do
            if g.characters[k] == nil then g.characters[k] = v end
        end
    end
    g.imported = true
end

function RS:OnInitialize()
    self.db = LibStub("AceDB-3.0"):New("RedFlagSyncDB", defaults, true)
    self:ImportLegacy()
    self:PurgeTombstones()
    API.RegisterListProvider(provider)
    self:RegisterChatCommand("rfs", "SlashCommand")
end

function RS:OnEnable()
    self:RegisterComm(PREFIX, "OnCommReceived")
    self:RegisterEvent("GUILD_ROSTER_UPDATE", "RebuildGuildMembers")
    self:RegisterEvent("PLAYER_GUILD_UPDATE", function()
        lastRosterRequest = 0
        RequestRoster()
        API.Refresh() -- joined/left a guild: a different guild list applies
        RS:UpdateSettings()
        RS:ScheduleGuildCheck(3) -- left for good? then that guild's list is deleted
    end)
    RequestRoster()
    self:ScheduleGuildCheck(15) -- left/kicked while logged out
    C_Timer.After(15, function() RS:RequestSync(false) end)
end

function RS:SlashCommand(input)
    local cmd = ((input or ""):match("^%s*(%S*)") or ""):lower()
    if cmd == "sync" then
        self:RequestSync(true)
    elseif cmd == "list" then
        API.ShowList("guild", "players")
    else
        self:ToggleSettings()
    end
end
