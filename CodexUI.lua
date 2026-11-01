-- Freewood-Codex: Tab "Datenbank"
-- Oben die Arten (Quests, Kreaturen, Objekte, Items), links Suche und Liste, rechts das Detail.
-- Das Detail ist eine Folge von Zeilen; Zeilen mit Verweis fuehren zum passenden Eintrag.

local ADDON, NS = ...

local FW = _G.Freewood
local Codex = NS.Codex
if not FW or not Codex then
    return
end

local UI = FW.UI
local Util = FW.Util

local LIST_W = 540
local ROW_H, ROW_GAP = 44, 4
local MAX_ROWS = 300
local LINE_H = 24

local KINDS = {
    { id = "quests", label = "CODEX_KIND_QUESTS" },
    { id = "units", label = "CODEX_KIND_UNITS" },
    { id = "objects", label = "CODEX_KIND_OBJECTS" },
    { id = "items", label = "CODEX_KIND_ITEMS" },
    { id = "zones", label = "CODEX_KIND_ZONES" },
    { id = "xp", label = "CODEX_KIND_XP" },
    { id = "learn", label = "CODEX_KIND_LEARN" },
}

local SORTS = {
    quests = { "name", "zone", "recent", "lvl", "xp", "money", "qtime", "dist" },
    units = { "name", "recent", "gold", "ttk", "gpm", "ahkill", "gpmah", "lvl", "xpm", "data", "dist" },
    objects = { "name", "recent", "gold", "data", "dist" },
    items = { "name", "price", "buy", "ah", "flip", "ilvl", "quality", "chance", "gph" },
    zones = { "name", "zlvl", "cnt", "recent" },
    xp = { "name", "recent", "xpm" },
    learn = { "step" },
}
-- Standardrichtung: true = aufsteigend (kleinster Wert zuerst)
local SORT_ASC = { zlvl = true, zone = true, step = true, name = true, ttk = true, qtime = true, buy = true, dist = true, data = true }
-- Anzeige des Sortierwerts in der Zeile: "money" (Kupfer), "secs", "num"
local SORT_FORMAT = {
    gold = "money", gpm = "money", ahkill = "money", gpmah = "money", price = "money", buy = "money", ah = "money", flip = "money", gph = "money", money = "money",
    ttk = "secs", qtime = "secs", lvl = "num", xp = "num", xpm = "num", data = "num", cnt = "num",
}
local SORT_METRIC = {
    step = "step", price = "price", ilvl = "ilvl", quality = "quality", chance = "chance", gold = "gold", ttk = "ttk", gpm = "gpm", ahkill = "ahkill", gpmah = "gpmah",
    lvl = "lvl", xpm = "xpm", xp = "xp", money = "money", qtime = "qtime", buy = "buy", ah = "ah", flip = "flip", gph = "gph", data = "data",
    zlvl = "zlvl", cnt = "cnt",
}

local XPTitle, XPKey
local ICON = {
    quests = "Interface\\GossipFrame\\AvailableQuestIcon",
    units = "Interface\\Icons\\INV_Misc_Bone_HumanSkull_01",
    objects = "Interface\\Icons\\INV_Misc_Bag_10",
    items = "Interface\\Icons\\INV_Misc_QuestionMark",
    zones = "Interface\\Icons\\INV_Misc_Map_01",
    xp = "Interface\\Icons\\INV_Misc_Book_09",
    learn = "Interface\\Icons\\INV_Misc_Note_01",
    plus = "Interface\\Buttons\\UI-PlusButton-Up",
    minus = "Interface\\Buttons\\UI-MinusButton-Up",
}

-- Symbol einer Kreatur: Familien-Symbol (wenn das Pet-Addon die Familie kennt), sonst Totenkopf
local function UnitIcon(u)
    local Pet = FW.Pet
    if u and u.f and Pet and Pet.GetFamilyID and Pet.FamilyIcon and Pet.GetFamilyID(u.f) then
        return Pet.FamilyIcon(u.f)
    end
    return ICON.units
end

------------------------------------------------------------------------
-- Formate
------------------------------------------------------------------------

local function FormatMoney(copper)
    copper = math.floor(tonumber(copper) or 0)
    local g = math.floor(copper / 10000)
    local s = math.floor((copper % 10000) / 100)
    local c = copper % 100
    local parts = {}
    if g > 0 then parts[#parts + 1] = "|cffffd100" .. g .. "g|r" end
    if s > 0 or g > 0 then parts[#parts + 1] = "|cffc7c7cf" .. s .. "s|r" end
    parts[#parts + 1] = "|cffeda55f" .. c .. "c|r"
    return table.concat(parts, " ")
end

Codex.FormatMoney = FormatMoney

-- Preise eines Artikels beim Haendler: hoechster Preis = 100 %, billigere mit Prozent (Ruf, Talente)
local function PriceText(prices, ec)
    local list = {}
    for price, n in pairs(prices or {}) do list[#list + 1] = { price = price, n = n } end
    if #list == 0 then return nil end
    table.sort(list, function(a, b) return a.price > b.price end)
    local top = list[1].price
    local parts = {}
    for i, e in ipairs(list) do
        if i > 3 then break end
        local text = e.price > 0 and FormatMoney(e.price) or "-"
        if i > 1 and top > 0 then
            text = text .. string.format(" (%d %%)", math.floor(e.price / top * 100 + 0.5))
        end
        parts[#parts + 1] = text
    end
    local out = table.concat(parts, "  ")
    if ec then out = out .. "  +" .. FW.L.CODEX_WARE_TOKEN end
    return out
end

local function FormatDuration(seconds)
    seconds = math.floor((tonumber(seconds) or 0) + 0.5)
    if seconds >= 3600 then
        return string.format("%d:%02d:%02d", math.floor(seconds / 3600), math.floor((seconds % 3600) / 60), seconds % 60)
    end
    return string.format("%d:%02d", math.floor(seconds / 60), seconds % 60)
end

-- Kampfdauer fuer die eigene Klasse: Sekunden, Anzahl (Erfahrung-Zeilen und Details)
local function OwnTTK(pl, ml)
    local token = Codex.Time and Codex.Time.PlayerToken()
    if not (token and Codex.Share and Codex.Share.TTKMeasured) then
        return nil
    end
    return Codex.Share.TTKMeasured(token, pl, ml - pl)
end

local function FormatChance(chance)
    local p = chance * 100
    if p >= 10 then
        return string.format("%.0f%%", p)
    end
    return string.format("%.1f%%", p)
end

local function Colored(text, quality)
    return "|cff" .. UI.RarityHex(quality or 1) .. text .. "|r"
end

local function SeedOK()
    return Codex.Seed ~= nil and Codex.Seed.Available()
end

-- Name einer Kreatur / eines Objekts: eigener Eintrag, sonst die Vorlage (nur wenn die Art bekannt ist)
local function UnitTitle(u, id, kind)
    local name = Codex.NameOf(u)
    if not name and kind and SeedOK() then
        name = Codex.Seed.Name(kind, id)
    end
    return name or ("#" .. tostring(id))
end

local function SeedTag()
    return "|cff8a8a96[" .. FW.L.CODEX_SEED_TAG .. "]|r"
end

local function SeedPct(chance)
    if chance >= 10 then
        return string.format(FW.L.CODEX_SEED_CHANCE, string.format("%.0f", chance))
    end
    return string.format(FW.L.CODEX_SEED_CHANCE, string.format("%.1f", chance))
end

local function RoleNames(kind, id)
    local list = {}
    for _, role in ipairs(Codex.RoleList(kind, id)) do
        list[#list + 1] = FW.L["CODEX_ROLE_" .. role] or role
    end
    return list
end


local function LevelText(u)
    local L = FW.L
    if u.l1 and u.l2 then
        if u.l1 == u.l2 then
            return string.format(L.CODEX_LEVEL, u.l1)
        end
        return string.format(L.CODEX_LEVEL_RANGE, u.l1, u.l2)
    end
    return nil
end

------------------------------------------------------------------------
-- Verzeichnisse (Rueckwaerts-Suche), bei Aenderung neu aufgebaut
------------------------------------------------------------------------

local dirty = true
local itemIndex, itemIds

-- Rueckgabe: index[itemID] = { u, o, r, qi, zones = { [mapID] = true }, best = hoechste Drop-Chance }, Liste der IDs
local function ItemIndex()
    if itemIndex and not dirty then
        return itemIndex, itemIds
    end
    local index, ids = {}, {}
    local grid2 = Codex.GRID * Codex.GRID
    local function Facts(id)
        local f = index[id]
        if not f then
            f = { zones = {}, best = 0 }
            index[id] = f
            ids[#ids + 1] = id
        end
        return f
    end
    local function FromEntities(tbl, flag)
        for _, ent in pairs(tbl) do
            local maps = {}
            for key in pairs(ent.cells or {}) do
                maps[math.floor(key / grid2)] = true
            end
            for _, m in ipairs(ent.ez or {}) do maps[m] = true end
            for iid in pairs(ent.iz or {}) do maps[-iid] = true end
            for id in pairs(ent.wa or {}) do
                local f = Facts(id)
                f.v = true
                for m in pairs(maps) do f.zones[m] = true end
            end
            for bi, bucket in ipairs({ ent, ent.alt or {} }) do
                for id, d in pairs(bucket.d or {}) do
                    local f = Facts(id)
                    f[flag] = true
                    if d.qi then f.qi = true end
                    if bi == 1 and (bucket.k or 0) > 0 and d.n then
                        local chance = d.n / bucket.k
                        if chance > f.best then f.best = chance end
                    end
                    for m in pairs(maps) do f.zones[m] = true end
                end
            end
        end
    end
    FromEntities(Codex.V().units, "u")
    FromEntities(Codex.V().objects, "o")
    -- im Auktionshaus gescannte Items (nicht in ids: sonst Flut von Item-Anfragen)
    if Codex.ExtraItems then
        local ok, extra = pcall(Codex.ExtraItems)
        if ok and type(extra) == "table" then
            for id in pairs(extra) do
                if not index[id] then index[id] = { zones = {}, best = 0, ah = true } end
            end
        end
    end
    for _, q in pairs(Codex.V().quests) do
        for _, list in ipairs({ q.fixed or {}, q.choice or {} }) do
            for _, r in ipairs(list) do
                local f = Facts(r.id)
                f.r = true
                if q.zone then f.zones[q.zone] = true end
            end
        end
        for id in pairs(q.qi or {}) do
            local f = Facts(id)
            f.qi = true
            if q.zone then f.zones[q.zone] = true end
        end
    end
    -- von Hand gesetzte Zonen der Items (nur lokal)
    for id, rec in pairs(Codex.V().ied or Codex.db.ied or {}) do
        local z = rec.ez or (rec.ed and rec.ed.z)
        if z and index[id] then
            for _, m in ipairs(z) do index[id].zones[m] = true end
        end
    end
    itemIndex, itemIds = index, ids
    dirty = false
    return index, ids
end

-- Wert-Filter: flt.stats = { { key, min, max }, ... } (bis zu 3 Zeilen), flt.ops[i] = "and" | "or" zwischen
-- Zeile i und der naechsten. UND bindet staerker als ODER. Aeltere Form: flt.stat / statMin / statMax (eine Zeile).
local MAX_STAT_ROWS = 3

local function StatRows(flt)
    local rows = {}
    if flt.stats then
        for i = 1, MAX_STAT_ROWS do
            local r = flt.stats[i]
            if r and r.key then
                rows[#rows + 1] = { key = r.key, min = r.min, max = r.max, op = flt.ops and flt.ops[i] or "and" }
            end
        end
    elseif flt.stat then
        rows[1] = { key = flt.stat, min = flt.statMin, max = flt.statMax, op = "and" }
    end
    return rows
end

local function StatRowPass(st, r)
    local v = st[r.key] or 0
    if r.min then
        if v < r.min then return false end
    elseif v <= 0 then
        return false
    end
    if r.max and v > r.max then return false end
    return true
end

-- Gruppen: ODER trennt, UND verbindet. Das Operatorfeld einer Zeile gilt zur naechsten aktiven Zeile.
local function StatGroups(rows)
    local groups = {}
    for i, r in ipairs(rows) do
        if i == 1 or rows[i - 1].op == "or" then
            groups[#groups + 1] = { r }
        else
            local g = groups[#groups]
            g[#g + 1] = r
        end
    end
    return groups
end

local function StatsPass(st, flt)
    local rows = StatRows(flt)
    if #rows == 0 then return true end
    if not st then return false end
    for _, g in ipairs(StatGroups(rows)) do
        local all = true
        for _, r in ipairs(g) do
            if not StatRowPass(st, r) then all = false break end
        end
        if all then return true end
    end
    return false
end

local function StatRowText(r)
    local name = Codex.StatName(r.key)
    if r.min and r.max then
        return string.format("%s %s-%s", name, Codex.FormatStat(r.min), Codex.FormatStat(r.max))
    elseif r.min then
        return string.format("%s >= %s", name, Codex.FormatStat(r.min))
    elseif r.max then
        return string.format("%s <= %s", name, Codex.FormatStat(r.max))
    end
    return name
end

-- Klartext des Wert-Filters, zum Beispiel "(Beweglichkeit 8-10 UND Intelligenz 5-7) ODER Schwimmtempo"
local function StatPreview(flt)
    local rows = StatRows(flt)
    if #rows < 2 then return "" end
    local L = FW.L
    local groups = StatGroups(rows)
    local parts = {}
    for _, g in ipairs(groups) do
        local texts = {}
        for _, r in ipairs(g) do texts[#texts + 1] = StatRowText(r) end
        local text = table.concat(texts, " " .. L.CODEX_OP_AND .. " ")
        if #g > 1 and #groups > 1 then text = "(" .. text .. ")" end
        parts[#parts + 1] = text
    end
    return table.concat(parts, " " .. L.CODEX_OP_OR .. " ")
end

-- Filter fuer Items. Filter, die Itemdaten brauchen, schliessen noch nicht geladene Items aus.
local function FilterActive(flt)
    local n = 0
    if next(flt.q) then n = n + 1 end
    for _, k in ipairs({ "type", "sub", "slot", "src", "zone", "ilMin", "ilMax", "rlMin", "rlMax", "pMin", "pMax", "aMin", "aMax", "stat", "statMin", "statMax" }) do
        if flt[k] ~= nil then n = n + 1 end
    end
    for i = 1, MAX_STAT_ROWS do
        local r = flt.stats and flt.stats[i]
        if r and r.key then n = n + 1 end
    end
    return n
end

local function PassFilter(flt, facts, info, id)
    if flt.src == "vendor" and not (facts.v or (id and SeedOK() and Codex.Seed.ItemHasVendor(id))) then return false end
    if flt.src == "unit" and not facts.u then return false end
    if flt.src == "object" and not facts.o then return false end
    if flt.src == "reward" and not facts.r then return false end
    if flt.src == "quest" and not facts.qi then return false end
    if flt.zone and not facts.zones[flt.zone] then return false end
    local hasStats = #StatRows(flt) > 0
    local needInfo = next(flt.q) or flt.type or flt.sub or flt.slot or flt.ilMin or flt.ilMax
        or flt.rlMin or flt.rlMax or flt.pMin or flt.pMax or flt.aMin or flt.aMax or hasStats or flt.statMin or flt.statMax
    if not needInfo then
        return true
    end
    if not info then return false end
    if next(flt.q) and not flt.q[info.light and (info.quality or -1) or (info.quality or 1)] then return false end
    if flt.type and info.type ~= flt.type then return false end
    if flt.sub and info.subType ~= flt.sub then return false end
    if flt.slot and info.equipLoc ~= flt.slot then return false end
    local il, rl, price = info.itemLevel or 0, info.minLevel or 0, (info.sellPrice or 0) / 10000
    if flt.ilMin and il < flt.ilMin then return false end
    if flt.ilMax and il > flt.ilMax then return false end
    if flt.rlMin and rl < flt.rlMin then return false end
    if flt.rlMax and rl > flt.rlMax then return false end
    if flt.pMin and price < flt.pMin then return false end
    if flt.pMax and price > flt.pMax then return false end
    if flt.aMin or flt.aMax then
        local ah = info.id and Codex.AuctionProvider and Codex.AuctionPrice(info.id)
        ah = (ah or 0) / 10000
        if not (ah > 0) then return false end
        if flt.aMin and ah < flt.aMin then return false end
        if flt.aMax and ah > flt.aMax then return false end
    end
    if hasStats then
        local st = info.id and Codex.db.istats and Codex.db.istats[info.id]
        if not StatsPass(st, flt) then return false end
    elseif flt.statMin or flt.statMax then
        if not (info.id and Codex.db.istats and Codex.db.istats[info.id]) then return false end
    end
    return true
end

------------------------------------------------------------------------
-- Eintraege fuer die Liste
------------------------------------------------------------------------

local function Match(text, haystack)
    return haystack and haystack:lower():find(text, 1, true) ~= nil
end

-- Suchtext passt auf einen der Namen (Spiel, Deutsch, Englisch)?
local function MatchNames(text, e)
    return e and (Match(text, e.n) or Match(text, e.cde) or Match(text, e.cen))
end

local function MapOfCells(cells)
    local m = Codex.MainMap(cells)
    return m and Codex.MapName(m) or nil
end

-- Zone eines Datensatzes: von Hand gesetzte zuerst, sonst die Hauptkarte der Fundorte
-- "Level 1-4" / "Level 3" fuer eine Gebietsspanne
local function RangeText(lo, hi)
    if not lo then return nil end
    if not hi or hi == lo then return string.format(FW.L.CODEX_LEVEL, lo) end
    return string.format(FW.L.CODEX_LEVEL, lo .. "-" .. hi)
end

local function ZoneOf(ent)
    local z = Codex.ZonesOf(ent)[1]
    return z and Codex.MapName(z) or nil
end

local function ClassLabel(cls)
    local L = FW.L
    if cls == "elite" or cls == "rareelite" then return L.CODEX_XP_ELITE end
    if cls == "rare" then return L.CODEX_XP_RARE end
    if cls == "worldboss" then return L.CODEX_XP_BOSS end
    return nil
end

XPTitle = function(r)
    local text = string.format(FW.L.CODEX_XP_TITLE, r.pl, r.ml)
    local label = ClassLabel(r.cls)
    if label then text = text .. "  (" .. label .. ")" end
    if r.rested then
        text = text .. "  [" .. FW.L.CODEX_XP_RESTED_TAG .. "]"
    elseif r.bonus then
        text = text .. "  [" .. FW.L.CODEX_XP_BONUS_TAG .. "]"
    end
    return text
end

XPKey = function(r)
    return r.pl .. ":" .. r.ml .. ":" .. r.cls .. ":" .. (r.rested and "r" or r.bonus and "b" or "a")
end

-- Vorlage: Eintraege fuer Quests, Kreaturen und Objekte, die es nur in der Vorlage gibt (einmal gebaut und gemerkt)
local seedEntries = {}
local mapNames = {}

local function CachedMapName(m)
    local n = mapNames[m]
    if not n then
        n = Codex.MapName(m)
        mapNames[m] = n
    end
    return n
end

local function RankLabel(rank)
    local L = FW.L
    if rank == 1 or rank == 2 then return L.CODEX_XP_ELITE end
    if rank == 3 then return L.CODEX_XP_BOSS end
    if rank == 4 then return L.CODEX_XP_RARE end
    return nil
end

local ChainText
local function SeedList(kind)
    local key = kind .. ":" .. Codex.Lang()
    local cached = seedEntries[key]
    if cached then
        return cached
    end
    local L = FW.L
    local Seed = Codex.Seed
    local list = {}
    for _, id in ipairs(Seed.IDs(kind)) do
        local e
        if kind == "quests" then
            local q = Seed.Quest(id)
            local title = Seed.QuestTitle(id) or ("Quest #" .. id)
            local sub = {}
            if q.lvl and q.lvl > 0 then sub[#sub + 1] = string.format(L.CODEX_LEVEL, q.lvl) end
            local ref = q.start[1] or q.stop[1]
            local zone
            if ref and ref.kind ~= "items" then
                local m = Seed.MapOf(ref.kind, ref.id)
                zone = m and CachedMapName(m) or nil
            end
            if zone then sub[#sub + 1] = zone end
            local chainText = ChainText(id)
            if chainText then sub[#sub + 1] = chainText end
            sub[#sub + 1] = SeedTag()
            e = { id = id, title = title, sub = table.concat(sub, "  |  "), icon = ICON.quests, name = title:lower(),
                  recent = 0, seed = true, zone = zone and zone:lower() or "", zoneName = zone, l1 = q.lvl, l2 = q.lvl }
        else
            local ent = Seed.Entity(kind, id)
            local title = Seed.Name(kind, id) or ("#" .. id)
            local sub = {}
            if kind == "units" and ent.l1 then
                sub[#sub + 1] = ent.l1 == ent.l2 and string.format(L.CODEX_LEVEL, ent.l1) or string.format(L.CODEX_LEVEL_RANGE, ent.l1, ent.l2)
            end
            local m = Seed.MapOf(kind, id)
            local zone = m and CachedMapName(m) or nil
            if zone then sub[#sub + 1] = zone end
            local rank = kind == "units" and RankLabel(ent.rank) or nil
            if rank then sub[#sub + 1] = rank end
            local roles = RoleNames(kind, id)
            if #roles > 0 then sub[#sub + 1] = table.concat(roles, ", ") end
            sub[#sub + 1] = SeedTag()
            e = { id = id, title = title, sub = table.concat(sub, "  |  "), icon = ICON[kind], name = title:lower(), recent = 0,
                  seed = true, gold = -1, unitID = kind == "units" and id or nil, zone = zone and zone:lower() or "",
                  l1 = ent.l1, l2 = ent.l2 }
        end
        list[#list + 1] = e
    end
    seedEntries[key] = list
    return list
end

-- Katalog: Quests, von denen nur Titel und Stufe bekannt sind (gebaut je Stand des Katalogs)
local catEntries, catRev, catLang
local function CatList()
    local C = Codex.Catalog
    if not C then return {} end
    local rev = C.Rev()
    if catEntries and catRev == rev then return catEntries end
    local L = FW.L
    local list = {}
    for _, id in ipairs(C.IDs()) do
        local title, lv = C.Get(id)
        if title then
            local sub = {}
            if lv then sub[#sub + 1] = string.format(L.CODEX_LEVEL, lv) end
            sub[#sub + 1] = "|cff8a8a96[" .. L.CODEX_CAT_TAG .. "]|r"
            list[#list + 1] = { id = id, title = title, sub = table.concat(sub, "  |  "), icon = ICON.quests, name = title:lower(),
                recent = 0, cat = true, zone = "", l1 = lv, l2 = lv }
        end
    end
    catEntries, catRev = list, rev
    return list
end

local function SeedHit(text, kind, e)
    if Codex.Seed.Haystack(kind, e.id):find(text, 1, true) then
        return true
    end
    return e.zone ~= nil and e.zone ~= "" and e.zone:find(text, 1, true) ~= nil
end

local function RolePass(kind, id, role)
    if not role then return true end
    return Codex.RolesOf(kind, id)[role] ~= nil
end

local CHAIN_STEPS = { "in", "start", "mid", "end", "none" }

-- Questkette (nur mit Vorlage bekannt): chain = nil/"in"/"start"/"mid"/"end"/"none"
local function ChainPass(id, chain)
    if not chain then return true end
    local role = Codex.ChainRole(id)
    if chain == "in" then return role ~= nil end
    if chain == "none" then return role == nil end
    return role == chain
end

local STATUS_STEPS = { "done", "active", "open" }
local STATUS_MARK = {
    done = "Interface\\RaidFrame\\ReadyCheck-Ready",
    active = "Interface\\Icons\\Ability_Rogue_Sprint",
}

local function StatusPass(id, status)
    if not status then return true end
    local st = Codex.QuestStatus(id)
    if status == "open" then return st == nil end
    return st == status
end

-- "Kette 2/4" fuer die Zeile, wenn die Vorlage die Quest in einer Kette kennt
ChainText = function(id)
    if not SeedOK() then return nil end
    local pos, total = Codex.Seed.ChainPos(id)
    if pos then return string.format(FW.L.CODEX_CHAIN_POS, pos, total) end
    return nil
end

-- Kampfdauer einer Kreatur: eigene Klasse, sonst Durchschnitt aller Klassen
local function UnitTTK(u)
    if not (Codex.Time and u) then return nil end
    local own = Codex.Time.UnitAverage(u)
    if own and own > 0 then return own end
    local list = Codex.Time.UnitClasses(u)
    if #list == 0 then return nil end
    local sum = 0
    for _, c in ipairs(list) do sum = sum + c.secs end
    local avg = sum / #list
    return avg > 0 and avg or nil
end

-- Erfahrung je Kill der eigenen Stufe (sonst der hoechsten bekannten)
local function UnitXPAvg(u)
    if not (u and u.xp) then return nil end
    local pl = UnitLevel and UnitLevel("player") or nil
    local s = pl and u.xp[pl]
    if not s then
        local best
        for lv, st in pairs(u.xp) do
            if not best or lv > best then best, s = lv, st end
        end
    end
    return s and s.n and s.n > 0 and (s.sum / s.n) or nil
end

-- niedrigster beobachteter Einkaufspreis bei Haendlern (Kupfer) je Item
local function LowestBuyPrices()
    local lowest = {}
    for _, u in pairs(Codex.V().units) do
        for id, w in pairs(u.wa or {}) do
            for price in pairs(w.pr or {}) do
                if price > 0 and (not lowest[id] or price < lowest[id]) then lowest[id] = price end
            end
        end
    end
    return lowest
end

local function ItemValueOf(id)
    local ah = Codex.AuctionProvider and Codex.AuctionPrice(id)
    if ah and ah > 0 then return ah end
    local info = Util.GetItem(id)
    return info and info.sellPrice or nil
end


-- Suchkuerzel: stufe:20-25, zone:Durotar, haendler:Ruestung (werden aus dem Suchtext herausgenommen)
local OP_KEYS = {
    stufe = "lvl", level = "lvl", lvl = "lvl", lv = "lvl",
    zone = "zone", gebiet = "zone",
    ["händler"] = "vendor", haendler = "vendor", vendor = "vendor", ["verkäufer"] = "vendor",
}

local function ParseSearch(text)
    local ops
    local rest = text:gsub("(%S-):(%S+)", function(key, value)
        local op = OP_KEYS[key]
        if not op then
            return nil
        end
        ops = ops or {}
        if op == "lvl" then
            local a, b = value:match("^(%d+)%-(%d+)$")
            if not a then a = value:match("^(%d+)$"); b = a end
            if not a then return nil end
            ops.lvl = { tonumber(a), tonumber(b) }
        else
            ops[op] = value:gsub("_", " ")
        end
        return ""
    end)
    rest = rest:gsub("^%s+", ""):gsub("%s+$", ""):gsub("%s+", " ")
    return rest, ops
end

-- Nachfilter fuer die Kuerzel; e = Listeneintrag (mit l1/l2/zone)
local function OpsPass(kind, e, ops)
    if not ops then return true end
    if ops.lvl then
        local lo, hi = e.l1, e.l2 or e.l1
        if kind == "items" then
            local info = Util.GetItem(e.id)
            lo = info and info.minLevel or nil
            hi = lo
        end
        if not lo or hi < ops.lvl[1] or lo > ops.lvl[2] then return false end
    end
    if ops.zone then
        if not (e.zone and e.zone:find(ops.zone, 1, true)) then return false end
    end
    if ops.vendor then
        if kind ~= "units" then return false end
        local want = ops.vendor
        local found = false
        local live = Codex.V().units[e.id]
        for itemID in pairs(live and live.wa or {}) do
            local name = Codex:ItemName(itemID)
            if name and name:lower():find(want, 1, true) then found = true break end
        end
        if not found and SeedOK() then
            local roles = Codex.Seed.Roles("units", e.id)
            if roles and roles.vendor then
                for _, itemID in ipairs(Codex.Seed.VendorItems(e.id)) do
                    local name = Codex:ItemName(itemID) or Codex.Seed.Name("items", itemID)
                    if name and name:lower():find(want, 1, true) then found = true break end
                end
            end
        end
        if not found then return false end
    end
    return true
end

-- opts: seed = Vorlage anzeigen, role = nur Kreaturen/Objekte mit dieser Rolle, chain = Questkette
local function BuildEntries(kind, text, flt, opts)
    local L = FW.L
    local db = Codex.V()
    opts = opts or {}
    text = (text or ""):lower()
    local ops
    text, ops = ParseSearch(text)
    local list = {}
    local useSeed = opts.seed and SeedOK()
    local role = opts.role
    local chain = SeedOK() and opts.chain or nil
    local status = opts.status

    if kind == "quests" then
        for id, q in pairs(db.quests) do
            local zone = q.zone and Codex.MapName(q.zone) or nil
            local ok = text == ""
                or MatchNames(text, q) or Match(text, q.t) or Match(text, zone)
                or (q.give and Match(text, q.give.n)) or (q.turn and Match(text, q.turn.n))
                or tostring(id) == text
            if ok and ChainPass(id, chain) and StatusPass(id, status) then
                local sub = {}
                local title = Codex.QuestTitle(q, id)
                if q.lvl then sub[#sub + 1] = string.format(L.CODEX_LEVEL, q.lvl) end
                if zone then sub[#sub + 1] = zone end
                local chainText = ChainText(id)
                if chainText then sub[#sub + 1] = chainText end
                if (q.done or 0) > 0 then sub[#sub + 1] = string.format(L.CODEX_DONE, q.done) end
                list[#list + 1] = {
                    id = id, title = title, sub = table.concat(sub, "  |  "),
                    icon = ICON.quests, name = title:lower(), recent = q.last or 0,
                    l1 = q.lvl, l2 = q.lvl, zone = zone and zone:lower() or "", zoneName = zone,
                }
            end
        end
        if useSeed then
            for _, e in ipairs(SeedList("quests")) do
                if not db.quests[e.id] and (text == "" or SeedHit(text, "quests", e) or tostring(e.id) == text)
                    and ChainPass(e.id, chain) and StatusPass(e.id, status) then
                    list[#list + 1] = e
                end
            end
        end
        -- Katalog: nur Titel und Stufe (nicht, wenn es schon einen Datensatz oder die Vorlage gibt)
        if not chain then
            local seedOn = SeedOK()
            for _, e in ipairs(CatList()) do
                if not db.quests[e.id] and not (seedOn and Codex.Seed.Quest(e.id))
                    and (text == "" or e.name:find(text, 1, true) or tostring(e.id) == text)
                    and StatusPass(e.id, status) then
                    list[#list + 1] = e
                end
            end
        end
    elseif kind == "units" or kind == "objects" then
        local src = kind == "units" and db.units or db.objects
        for id, u in pairs(src) do
            local zone = ZoneOf(u)
            if (text == "" or MatchNames(text, u) or Match(text, zone) or Match(text, u.ti) or tostring(id) == text)
                and RolePass(kind, id, role) then
                local sub = {}
                local lvl = LevelText(u)
                if lvl then sub[#sub + 1] = lvl end
                if zone then sub[#sub + 1] = zone end
                if (u.k or 0) > 0 then sub[#sub + 1] = string.format(L.CODEX_KILLS, u.k) end
                local value = Codex.KillValue(u)
                if value and value >= 1 then sub[#sub + 1] = string.format(L.CODEX_VALUE_SHORT, FormatMoney(value)) end
                local roles = RoleNames(kind, id)
                if #roles > 0 then sub[#sub + 1] = table.concat(roles, ", ") end
                if u.ti then sub[#sub + 1] = u.ti end
                list[#list + 1] = {
                    id = id, title = UnitTitle(u, id, kind), sub = table.concat(sub, "  |  "),
                    icon = kind == "units" and UnitIcon(u) or ICON[kind], name = (UnitTitle(u, id, kind)):lower(), recent = u.lt or 0,
                    unitID = kind == "units" and id or nil,
                    gold = value or -1,
                    l1 = u.l1, l2 = u.l2, zone = zone and zone:lower() or "",
                }
            end
        end
        if useSeed then
            for _, e in ipairs(SeedList(kind)) do
                if not src[e.id] and (text == "" or SeedHit(text, kind, e) or tostring(e.id) == text)
                    and RolePass(kind, e.id, role) then
                    list[#list + 1] = e
                end
            end
        end
    elseif kind == "zones" then
        local pl = UnitLevel and UnitLevel("player") or 1
        for key, z in pairs(Codex.Zones.All()) do
            local name = Codex.MapName(key)
            local pass = true
            if opts.zoneSel == "world" then pass = not z.dungeon
            elseif opts.zoneSel == "dungeon" then pass = z.dungeon
            elseif opts.zoneSel == "fit" then pass = Codex.Zones.Compare(key, pl, 2) == "in"
            elseif opts.zoneSel == "data" then pass = not z.few end
            if pass and (text == "" or Match(text, name) or tostring(math.abs(key)) == text) then
                local sub = {}
                local range = RangeText(z.lo, z.hi)
                if range then
                    sub[#sub + 1] = range .. ((z.avg and not z.manual) and string.format("  (%s %.1f)", L.CODEX_ZONE_AVG, z.avg) or "")
                end
                if z.manual then sub[#sub + 1] = L.CODEX_ZONE_MANUAL end
                if z.few and not z.manual then sub[#sub + 1] = L.CODEX_ZONE_FEW end
                sub[#sub + 1] = string.format(L.CODEX_ZONE_UNITS, z.units)
                if #z.out > 0 then sub[#sub + 1] = string.format(L.CODEX_ZONE_OUTLIERS, #z.out) end
                if #z.special > 0 then sub[#sub + 1] = string.format(L.CODEX_ZONE_SPECIAL, #z.special) end
                if z.dungeon then sub[#sub + 1] = L.CODEX_PROPS_DG_YES end
                list[#list + 1] = {
                    id = key, title = name, sub = table.concat(sub, "  |  "), icon = ICON.zones, name = name:lower(),
                    recent = z.units, l1 = z.lo, l2 = z.hi, zone = name:lower(),
                    zlvl = z.lo and (z.lo * 1000 + (z.hi or z.lo)) or -1, cnt = z.units,
                }
            end
        end
    elseif kind == "learn" then
        local plan = opts.class and Codex.LearnPlan(opts.class)
        if plan then
            local pl = UnitLevel and UnitLevel("player") or 1
            for _, lv in ipairs(plan.order) do
                local g = plan.levels[lv]
                local hit = text == "" or tostring(lv) == text
                if not hit then
                    for _, sp in ipairs(g.spells) do
                        if Match(text, sp.nm) then hit = true break end
                    end
                end
                if hit then
                    local sub = string.format(L.CODEX_LEARN_SUB, #g.spells, FormatMoney(g.cost))
                    if lv > pl then
                        sub = sub .. "  |  " .. string.format(L.CODEX_LEARN_SUMSHORT, FormatMoney(Codex.LearnCost(plan, pl, lv)))
                    end
                    list[#list + 1] = {
                        id = lv, title = lv > 0 and string.format(L.CODEX_LEARN_TITLE, lv) or L.CODEX_LEARN_LVUNKNOWN,
                        sub = sub, icon = ICON.learn, name = string.format("%03d", lv), recent = lv,
                        step = lv > 0 and lv or 1e9,
                    }
                end
            end
        end
    elseif kind == "xp" then
        for _, r in ipairs(Codex:XPRows(true)) do
            local title = XPTitle(r)
            if text == "" or Match(text, title) or tostring(r.pl) == text or tostring(r.ml) == text then
                local secs = (not r.bonus and r.cls == "normal") and OwnTTK(r.pl, r.ml) or nil
                list[#list + 1] = {
                    id = XPKey(r), title = title,
                    sub = string.format(L.CODEX_XP_ROW, r.avg, r.pred, r.diff, r.n)
                        .. ((secs and secs > 0) and ("  |  " .. string.format(L.CODEX_TTK_ROW, secs, r.avg / secs * 60)) or ""),
                    xpm = (secs and secs > 0) and (r.avg / secs * 60) or nil,
                    icon = ICON.xp, name = string.format("%03d%03d%s%s", 999 - r.pl, r.ml, r.cls, r.bonus and "b" or "a"),
                    recent = r.n,
                }
            end
        end
    else
        local index = ItemIndex()
        local function ItemEntry(id, facts, name, seed)
            local info = Util.GetItem(id)
            -- Das Spiel kennt viele Items noch nicht (nicht im Zwischenspeicher). Dann reichen gemerkte Werte:
            -- Qualitaet aus dem Merker, Stufe/Mindeststufe/Preis aus dem Katalog. So filtern Qualitaet, Stufe und Preis
            -- auch fuer Items, die noch nicht geladen sind (Typ, Platz und Werte brauchen weiter echte Itemdaten).
            local light
            if not info then
                local nm, cq, il, ml, sp = nil, nil, nil, nil, nil
                local Cat = Codex.Catalog
                if Cat and Cat.GetItem then nm, cq, il, ml, sp = Cat.GetItem(id) end
                local q = (Codex.db.iq and Codex.db.iq[id]) or cq
                if q or il then
                    light = { id = id, name = nm, quality = q, itemLevel = il, minLevel = ml, sellPrice = sp, light = true }
                end
            end
            if not PassFilter(flt, facts, info or light, id) then
                return
            end
            if not info then info = light end
            local sub = {}
            if info then
                if (info.itemLevel or 0) > 1 then sub[#sub + 1] = string.format(L.CODEX_ILVL_SHORT, info.itemLevel) end
                if info.type then
                    sub[#sub + 1] = info.type .. ((info.subType and info.subType ~= "" and info.subType ~= info.type) and (" · " .. info.subType) or "")
                end
                if (info.sellPrice or 0) > 0 then sub[#sub + 1] = FormatMoney(info.sellPrice) end
                if info.light then sub[#sub + 1] = "#" .. id end
            else
                sub[#sub + 1] = "#" .. id
            end
            if seed then sub[#sub + 1] = SeedTag() end
            list[#list + 1] = {
                id = id, title = name or ("#" .. id), sub = table.concat(sub, "  |  "), itemID = id,
                name = (name or ""):lower(), recent = seed and 0 or id,
                price = info and (info.sellPrice or 0) or -1, ilvl = info and (info.itemLevel or 0) or -1,
                quality = info and (info.quality or (info.light and -1 or 1)) or -1, chance = facts.best or 0, seed = seed or nil,
            }
        end
        for id, facts in pairs(index) do
            local name = Codex:ItemName(id)
            if text == "" or Match(text, name) or tostring(id) == text then
                ItemEntry(id, facts, name, false)
            end
        end
        -- Items, die es nur in der Vorlage gibt
        if useSeed then
            local Seed = Codex.Seed
            for _, id in ipairs(Seed.IDs("items")) do
                if not index[id] and (text == "" or Seed.Haystack("items", id):find(text, 1, true) or tostring(id) == text) then
                    local it = Seed.Item(id)
                    local facts = { zones = {}, best = it and it.u[1] and it.u[1].chance / 100 or 0,
                                    u = it and #it.u > 0 or nil, o = it and #it.o > 0 or nil }
                    ItemEntry(id, facts, Seed.Name("items", id), true)
                end
            end
        end
    end
    if opts.fav and Codex.FavSupported(kind) then
        local kept = {}
        for _, e in ipairs(list) do
            if Codex.IsFav(kind, e.id) then kept[#kept + 1] = e end
        end
        list = kept
    end
    if ops then
        local kept = {}
        for _, e in ipairs(list) do
            if OpsPass(kind, e, ops) then kept[#kept + 1] = e end
        end
        list = kept
    end
    return list
end

------------------------------------------------------------------------
-- Tab
------------------------------------------------------------------------

local function Build(content)
    local L = FW.L
    local f = CreateFrame("Frame", nil, content)

    local kind, selected, search = "quests", nil, ""
    local sortBy, sortRev, flt, filterOpen = {}, {}, { q = {} }, false
    local farmOn = false     -- Farm-Ranking (Kreaturen)
    local history = {}       -- Verlauf fuer "Zurueck"
    local listRows, detailRows = {}, {}
    local Refresh, RefreshList, ShowDetail, Go, UpdateFilterUI, Layout
    local nameCtl
    local roleSel = {}       -- gewaehlte Rolle je Art (Kreaturen, Objekte)
    local chainSel = nil     -- gewaehlte Questkette (nur Quests)
    local statusSel = nil    -- gewaehlter Quest-Status (nur Quests)
    local zoneSel = nil      -- gewaehlte Gebietsart (nur Gebiete)
    local learnSel = nil     -- gewaehlte Klasse (Lernplan)
    local favOnly = {}       -- nur Favoriten je Art
    local collapsed = {}     -- eingeklappte Gebiete (Quests nach Gebiet)
    local dataVersion = 0    -- zaehlt jede Datenaenderung; merkt sich die sortierte Liste dazwischen
    local memo = {}

    local function SeedOn()
        return SeedOK() and Codex.db.settings.showSeed ~= false
    end

    ---------------- Kopf: Arten ----------------
    local kindButtons = {}
    local KIND_GAP = 4
    for i, k in ipairs(KINDS) do
        local b = UI.CreateButton(f, L[k.label], 60, 28, function()
            kind, selected = k.id, nil
            Refresh()
        end, "default")
        kindButtons[k.id] = b
    end
    -- "Erfahrung" ist ein Werkzeug fuer Entwickler: der Knopf erscheint nur mit dem Modul Freewood-Dev
    local function KindVisible(id)
        return id ~= "xp" or FW.Dev ~= nil
    end
    local function LayoutKinds()
        local shown = {}
        for _, k in ipairs(KINDS) do
            if KindVisible(k.id) then shown[#shown + 1] = k end
        end
        local w = math.floor((LIST_W - KIND_GAP * (#shown - 1)) / #shown)
        for _, k in ipairs(KINDS) do
            local b = kindButtons[k.id]
            if KindVisible(k.id) then
                local idx
                for i, s in ipairs(shown) do if s == k then idx = i end end
                b:SetWidth(w)
                b:ClearAllPoints()
                b:SetPoint("TOPLEFT", f, "TOPLEFT", (idx - 1) * (w + KIND_GAP), 0)
                b:Show()
            else
                b:Hide()
            end
        end
        if not KindVisible(kind) then kind, selected = "quests", nil end
    end
    LayoutKinds()

    ---------------- links: Suche und Liste ----------------
    local box = UI.CreatePanel(f, "bgDeep", "bronze")
    box:SetHeight(26)
    box:SetPoint("TOPLEFT", f, "TOPLEFT", 0, -38)
    box:SetWidth(LIST_W - 188 - 30)
    local edit = CreateFrame("EditBox", nil, box)
    edit:SetAutoFocus(false)
    edit:SetPoint("TOPLEFT", box, "TOPLEFT", 8, -2)
    edit:SetPoint("BOTTOMRIGHT", box, "BOTTOMRIGHT", -8, 2)
    edit:SetMaxLetters(60)
    if not edit:SetFont(UI.GetFontPath("body"), 12, "") then
        edit:SetFont("Fonts\\FRIZQT__.TTF", 12, "")
    end
    edit:SetTextColor(UI.Color("text"))
    edit:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    local hint = UI.CreateLabel(box, L.CODEX_SEARCH, { size = 12, color = "textDim" })
    hint:SetPoint("LEFT", box, "LEFT", 10, 0)
    edit:SetScript("OnTextChanged", function(self)
        search = self:GetText() or ""
        if search == "" then hint:Show() else hint:Hide() end
        Refresh()
    end)

    local function CurrentSort()
        return sortBy[kind] or SORTS[kind][1]
    end
    local function SortModes()
        local list = {}
        for _, m in ipairs(SORTS[kind]) do
            if (m ~= "ah" and m ~= "ahkill" and m ~= "gpmah" and m ~= "flip") or Codex.AuctionProvider then
                list[#list + 1] = { value = m, text = L["CODEX_SORTBY_" .. m] or m }
            end
        end
        return list
    end
    local sortDD = UI.CreateDropdown(f, 150, 26, {
        getOptions = SortModes,
        textOf = function(v) return L["CODEX_SORTBY_" .. v] or v end,
        onChange = function(v)
            sortBy[kind] = v
            sortRev[kind] = false
            Refresh()
        end,
    })
    sortDD:SetPoint("TOPLEFT", f, "TOPLEFT", LIST_W - 150, -38)
    local dirButton = UI.CreateButton(f, "", 26, 26, function()
        sortRev[kind] = not sortRev[kind]
        Refresh()
    end, "default")
    dirButton:SetPoint("TOPLEFT", f, "TOPLEFT", LIST_W - 180, -38)
    local dirTip = function(self)
        if GameTooltip then
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText(L.CODEX_SORT_DIR_TIP)
            GameTooltip:Show()
        end
    end
    if dirButton.HookScript then
        dirButton:HookScript("OnEnter", dirTip)
        dirButton:HookScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
    end
    -- Pfeil als Textur: haengt davon ab, ob aktuell aufsteigend sortiert wird
    dirButton.arrow = dirButton:CreateTexture(nil, "OVERLAY")
    dirButton.arrow:SetTexture("Interface\\Buttons\\Arrow-Down-Up")
    dirButton.arrow:SetSize(14, 14)
    dirButton.arrow:SetPoint("CENTER", dirButton, "CENTER", 0, 0)

    -- nur Favoriten (Stern neben der Suche)
    local favToggle = UI.CreateButton(f, "", 26, 26, function()
        favOnly[kind] = not favOnly[kind]
        dataVersion = dataVersion + 1
        Refresh()
    end, "default")
    favToggle:SetPoint("TOPLEFT", f, "TOPLEFT", LIST_W - 188 - 26, -38)
    favToggle.star = favToggle:CreateTexture(nil, "OVERLAY")
    favToggle.star:SetTexture("Interface\\TargetingFrame\\UI-RaidTargetingIcon_1")
    favToggle.star:SetSize(16, 16)
    favToggle.star:SetPoint("CENTER", favToggle, "CENTER", 0, 0)
    if favToggle.HookScript then
        favToggle:HookScript("OnEnter", function(self)
            if GameTooltip then
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                GameTooltip:SetText(L.CODEX_FAV_ONLY)
                GameTooltip:Show()
            end
        end)
        favToggle:HookScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
    end

    local countLabel = UI.CreateLabel(f, "", { size = 11, color = "textDim" })
    countLabel:SetPoint("TOPLEFT", f, "TOPLEFT", 0, -72)
    countLabel:SetWidth(LIST_W)
    countLabel:SetWordWrap(false)

    ---------------- Filter (nur Items) ----------------
    local ROW, PAD = 26, 4
    local function FilterH()
        return (Codex.AuctionProvider and 9 or 8) * (ROW + PAD) - PAD
    end
    local FILTER_H = FilterH()
    local fp = CreateFrame("Frame", nil, f)
    fp:SetPoint("TOPLEFT", f, "TOPLEFT", 0, -92)
    fp:SetSize(LIST_W, FILTER_H)
    fp:Hide()
    local syncing = false
    local qualityButtons, dropdowns, numBoxes, opButtons = {}, {}, {}, {}
    local previewLabel, ahFilter

    local function RowY(row) return -(row * (ROW + PAD)) end

    local qw = math.floor((LIST_W - 5 * PAD) / 6)
    for q = 0, 5 do
        local b = UI.CreateButton(fp, Colored(L["CODEX_QUAL_" .. q], q), qw, ROW - 2, function()
            if flt.q[q] then flt.q[q] = nil else flt.q[q] = true end
            UpdateFilterUI()
            RefreshList()
        end, "default")
        b:SetPoint("TOPLEFT", fp, "TOPLEFT", q * (qw + PAD), RowY(0))
        qualityButtons[q] = b
    end

    local function InfoValues(getter, pred)
        local seen, list = {}, {}
        for id in pairs((ItemIndex())) do
            local info = Util.GetItem(id)
            if info and (not pred or pred(info)) then
                local v = getter(info)
                if v and v ~= "" and not seen[v] then
                    seen[v] = true
                    list[#list + 1] = v
                end
            end
        end
        table.sort(list, function(a, b) return tostring(a) < tostring(b) end)
        return list
    end

    local SRC_KEYS = { "unit", "object", "reward", "quest", "vendor" }
    local function SrcLabel(v) return L["CODEX_SRC_" .. v:upper()] or v end
    local function Zones()
        local seen, list = {}, {}
        for _, facts in pairs((ItemIndex())) do
            for m in pairs(facts.zones) do
                if not seen[m] then seen[m] = true; list[#list + 1] = m end
            end
        end
        table.sort(list, function(a, b) return Codex.MapName(a) < Codex.MapName(b) end)
        return list
    end

    -- Liste von Werten in Dropdown-Eintraege umwandeln
    local function AsOptions(values, display)
        local list = {}
        for _, v in ipairs(values) do
            list[#list + 1] = { value = v, text = display and display(v) or tostring(v) }
        end
        return list
    end
    local function Prefix(key) return (L[key]:gsub(":%s*%%s%s*$", "")) end

    local third = math.floor((LIST_W - 2 * PAD) / 3)
    local function MakeDrop(x, row, w, prefix, getValue, setValue, optionsFn, display)
        local dd = UI.CreateDropdown(fp, w, ROW - 2, {
            prefix = prefix, allText = L.CODEX_FILTER_ALL,
            getOptions = function() return AsOptions(optionsFn(), display) end,
            textOf = function(v) return display and display(v) or tostring(v) end,
            onChange = function(v)
                setValue(v)
                UpdateFilterUI()
                RefreshList()
            end,
        })
        dd:SetPoint("TOPLEFT", fp, "TOPLEFT", x, RowY(row))
        dropdowns[#dropdowns + 1] = { dd = dd, get = getValue }
        return dd
    end
    local function FieldDrop(col, row, labelKey, field, optionsFn, display, onSet)
        return MakeDrop(col * (third + PAD), row, third, Prefix(labelKey),
            function() return flt[field] end,
            function(v) flt[field] = v; if onSet then onSet() end end, optionsFn, display)
    end
    FieldDrop(0, 1, "CODEX_FILTER_TYPE", "type", function() return InfoValues(function(i) return i.type end) end, tostring,
        function() flt.sub = nil end)
    FieldDrop(1, 1, "CODEX_FILTER_SUB", "sub", function()
        return InfoValues(function(i) return i.subType end, function(i) return not flt.type or i.type == flt.type end)
    end, tostring)
    FieldDrop(2, 1, "CODEX_FILTER_SLOT", "slot", function() return InfoValues(function(i) return i.equipLoc end) end,
        function(v) return _G[v] or v end)
    FieldDrop(0, 2, "CODEX_FILTER_SRC", "src", function() return SRC_KEYS end, SrcLabel)
    FieldDrop(1, 2, "CODEX_FILTER_ZONE", "zone", Zones, Codex.MapName)

    local resetButton = UI.CreateButton(fp, L.CODEX_FILTER_RESET, third, ROW - 2, function()
        flt = { q = {} }
        UpdateFilterUI()
        RefreshList()
    end, "default")
    resetButton:SetPoint("TOPLEFT", fp, "TOPLEFT", 2 * (third + PAD), RowY(2))

    local NUM_W = 38
    local function MakeNum(x, row, getValue, setValue)
        local box = UI.CreatePanel(fp, "bgDeep", "bronze")
        box:SetSize(NUM_W, ROW - 2)
        box:SetPoint("TOPLEFT", fp, "TOPLEFT", x, RowY(row))
        local e = CreateFrame("EditBox", nil, box)
        e:SetAutoFocus(false)
        e:SetPoint("TOPLEFT", box, "TOPLEFT", 5, -2)
        e:SetPoint("BOTTOMRIGHT", box, "BOTTOMRIGHT", -5, 2)
        e:SetMaxLetters(7)
        if not e:SetFont(UI.GetFontPath("body"), 11, "") then
            e:SetFont("Fonts\\FRIZQT__.TTF", 11, "")
        end
        e:SetTextColor(UI.Color("text"))
        e:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
        e:SetScript("OnTextChanged", function(self)
            if syncing then return end
            setValue(tonumber(((self:GetText() or ""):gsub(",", "."))))
            UpdateFilterUI()
            RefreshList()
        end)
        numBoxes[#numBoxes + 1] = { e = e, box = box, get = getValue }
    end
    local function FieldNum(x, row, field)
        MakeNum(x, row, function() return flt[field] end, function(v) flt[field] = v end)
    end
    local function NumLabel(x, row, text, w)
        local l = UI.CreateLabel(fp, text, { size = 10, color = "textDim" })
        l:SetPoint("TOPLEFT", fp, "TOPLEFT", x, RowY(row) - 7)
        l:SetWidth(w)
        l:SetWordWrap(false)
    end
    -- Zeile 3: Itemstufe, Benoetigt, Preis, je mit Min und Max
    local LBL_W = math.max(44, math.min(92, third - 2 * NUM_W - 8))   -- Beschriftung bekommt den Platz, der neben den zwei Feldern bleibt
    local groupsDef = { { "CODEX_FILTER_ILVL", "ilMin", "ilMax" }, { "CODEX_FILTER_RLVL", "rlMin", "rlMax" },
        { "CODEX_FILTER_PRICE", "pMin", "pMax" } }
    for i, g in ipairs(groupsDef) do
        local x0 = (i - 1) * (third + PAD)
        NumLabel(x0, 3, L[g[1]], LBL_W)
        FieldNum(x0 + LBL_W, 3, g[2])
        FieldNum(x0 + LBL_W + NUM_W + 2, 3, g[3])
    end

    -- Zeilen 4 bis 6: bis zu drei Werte, dahinter UND/ODER fuer die naechste Zeile
    local OP_W = 62
    local statDropW = LIST_W - 2 * NUM_W - OP_W - 3 * PAD
    local function StatRow(i)
        flt.stats = flt.stats or {}
        flt.stats[i] = flt.stats[i] or {}
        return flt.stats[i]
    end
    local function StatOptions()
        local _, ids = ItemIndex()
        Codex:CaptureStats(ids)
        return Codex:StatKeys(ids)
    end
    for i = 1, MAX_STAT_ROWS do
        local row = 3 + i
        MakeDrop(0, row, statDropW, Prefix("CODEX_FILTER_STAT") .. " " .. i,
            function() return flt.stats and flt.stats[i] and flt.stats[i].key end,
            function(v)
                local r = StatRow(i)
                r.key = v
                if v == nil then r.min, r.max = nil, nil end
            end, StatOptions, Codex.StatName)
        MakeNum(statDropW + PAD, row,
            function() return flt.stats and flt.stats[i] and flt.stats[i].min end,
            function(v) StatRow(i).min = v end)
        MakeNum(statDropW + PAD + NUM_W + PAD, row,
            function() return flt.stats and flt.stats[i] and flt.stats[i].max end,
            function(v) StatRow(i).max = v end)
        if i < MAX_STAT_ROWS then
            local b = UI.CreateButton(fp, "", OP_W, ROW - 2, function()
                flt.ops = flt.ops or {}
                flt.ops[i] = (flt.ops[i] == "or") and "and" or "or"
                UpdateFilterUI()
                RefreshList()
            end, "default")
            b:SetPoint("TOPLEFT", fp, "TOPLEFT", statDropW + 2 * PAD + 2 * NUM_W + PAD, RowY(row))
            opButtons[i] = b
        end
    end
    previewLabel = UI.CreateLabel(fp, "", { size = 10, color = "textDim" })
    previewLabel:SetPoint("TOPLEFT", fp, "TOPLEFT", 2, RowY(7) - 4)
    -- Zeile 8: Auktionspreis (nur mit Auktions-Modul)
    ahFilter = {}
    ahFilter.label = UI.CreateLabel(fp, L.CODEX_FILTER_AH, { size = 10, color = "textDim" })
    ahFilter.label:SetPoint("TOPLEFT", fp, "TOPLEFT", 0, RowY(8) - 7)
    ahFilter.label:SetWidth(LBL_W + 20)
    ahFilter.label:SetWordWrap(false)
    MakeNum(LBL_W + 24, 8, function() return flt.aMin end, function(v) flt.aMin = v end)
    MakeNum(LBL_W + 24 + NUM_W + 2, 8, function() return flt.aMax end, function(v) flt.aMax = v end)
    numBoxes[#numBoxes].ah, numBoxes[#numBoxes - 1].ah = true, true
    previewLabel:SetWidth(LIST_W - 4)
    previewLabel:SetWordWrap(false)

    local filterButton = UI.CreateButton(f, L.CODEX_FILTER, 96, 20, function()
        filterOpen = not filterOpen
        Layout()
    end, "default")
    filterButton:SetPoint("TOPLEFT", f, "TOPLEFT", LIST_W - 96, -68)
    filterButton:Hide()

    -- Vorlage (Vanilla-Startdaten) ein/aus und Rolle (Haendler, Flugmeister ...)
    local seedButton = UI.CreateButton(f, "", 100, 20, function()
        Codex.db.settings.showSeed = not SeedOn()
        dataVersion = dataVersion + 1
        Refresh()
    end, "default")
    seedButton:Hide()
    -- Auswahl-Listen unter der Zaehlzeile: Rolle (Kreaturen, Objekte), Kette und Status (Quests)
    local function BumpAndRefresh()
        dataVersion = dataVersion + 1
        Refresh()
    end
    local roleDD = UI.CreateDropdown(f, 186, 20, {
        prefix = Prefix("CODEX_FILTER_ROLE"), allText = L.CODEX_FILTER_ALL,
        getOptions = function()
            local list = {}
            for _, r in ipairs(Codex.Roles.ORDER[kind] or {}) do
                list[#list + 1] = { value = r, text = L["CODEX_ROLE_" .. r] or r }
            end
            return list
        end,
        textOf = function(v) return L["CODEX_ROLE_" .. v] or v end,
        onChange = function(v) roleSel[kind] = v; Refresh() end,
    })
    roleDD:Hide()
    local chainDD = UI.CreateDropdown(f, 186, 20, {
        prefix = Prefix("CODEX_FILTER_CHAIN"), allText = L.CODEX_FILTER_ALL,
        getOptions = function()
            local list = {}
            for _, c in ipairs(CHAIN_STEPS) do list[#list + 1] = { value = c, text = L["CODEX_CHAIN_" .. c:upper()] } end
            return list
        end,
        textOf = function(v) return L["CODEX_CHAIN_" .. v:upper()] end,
        onChange = function(v) chainSel = v; BumpAndRefresh() end,
    })
    chainDD:Hide()
    local statusDD = UI.CreateDropdown(f, 186, 20, {
        prefix = Prefix("CODEX_FILTER_STATUS"), allText = L.CODEX_FILTER_ALL,
        getOptions = function()
            local list = {}
            for _, c in ipairs(STATUS_STEPS) do list[#list + 1] = { value = c, text = L["CODEX_STATUS_" .. c:upper()] } end
            return list
        end,
        textOf = function(v) return L["CODEX_STATUS_" .. v:upper()] end,
        onChange = function(v) statusSel = v; BumpAndRefresh() end,
    })
    statusDD:Hide()
    local ZONE_STEPS = { "world", "dungeon", "fit", "data" }
    local zoneDD = UI.CreateDropdown(f, 186, 20, {
        prefix = Prefix("CODEX_FILTER_ZONE"), allText = L.CODEX_FILTER_ALL,
        getOptions = function()
            local list = {}
            for _, c in ipairs(ZONE_STEPS) do list[#list + 1] = { value = c, text = L["CODEX_ZONEF_" .. c:upper()] } end
            return list
        end,
        textOf = function(v) return L["CODEX_ZONEF_" .. v:upper()] end,
        onChange = function(v) zoneSel = v; BumpAndRefresh() end,
    })
    zoneDD:Hide()
    -- Klasse des Lernplans: die eigene, sonst die erste mit Daten
    local function EnsureLearnSel()
        local classes = Codex.LearnClasses()
        local have = {}
        for _, t in ipairs(classes) do have[t] = true end
        if not (learnSel and have[learnSel]) then
            local mine = Codex.Time and Codex.Time.PlayerToken()
            learnSel = (mine and have[mine]) and mine or classes[1]
        end
        return learnSel
    end
    local learnDD = UI.CreateDropdown(f, 186, 20, {
        prefix = Prefix("CODEX_LEARN_CLASS"),
        getOptions = function()
            local list = {}
            for _, t in ipairs(Codex.LearnClasses()) do
                list[#list + 1] = { value = t, text = Codex.Time.ClassLabel(t) }
            end
            return list
        end,
        textOf = function(v) return Codex.Time.ClassLabel(v) end,
        onChange = function(v) learnSel = v; selected = nil; BumpAndRefresh() end,
    })
    learnDD:Hide()
    -- Routen-Planer: Stufenbereich (leer = keine Grenze), Haken = +/- 3 Stufen
    local routeOpen, routeSyncing = false, false
    local routeLvl = {}
    local ROUTE_H = 62
    local rp = CreateFrame("Frame", nil, f)
    rp:SetSize(LIST_W, ROUTE_H)
    rp:Hide()
    local routeBoxes = {}
    local routeCheck
    local function RouteBox(x, getValue, setValue)
        local box = UI.CreatePanel(rp, "bgDeep", "bronze")
        box:SetSize(38, 22)
        box:SetPoint("TOPLEFT", rp, "TOPLEFT", x, -34)
        local e = CreateFrame("EditBox", nil, box)
        e:SetAutoFocus(false)
        e:SetPoint("TOPLEFT", box, "TOPLEFT", 5, -2)
        e:SetPoint("BOTTOMRIGHT", box, "BOTTOMRIGHT", -5, 2)
        e:SetMaxLetters(3)
        if not e:SetFont(UI.GetFontPath("body"), 11, "") then e:SetFont("Fonts\\FRIZQT__.TTF", 11, "") end
        e:SetTextColor(UI.Color("text"))
        e:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
        e:SetScript("OnTextChanged", function(self)
            if routeSyncing then return end
            local v = tonumber(self:GetText() or "")
            setValue(v and math.max(0, math.floor(v)) or nil)
            if routeCheck then routeCheck:Refresh() end
        end)
        routeBoxes[#routeBoxes + 1] = { e = e, get = getValue }
    end
    local function RouteSync()
        routeSyncing = true
        for _, b in ipairs(routeBoxes) do
            local v = b.get()
            local text = v ~= nil and tostring(v) or ""
            if b.e:GetText() ~= text and not b.e:HasFocus() then b.e:SetText(text) end
        end
        routeSyncing = false
        if routeCheck then routeCheck:Refresh() end
    end
    routeCheck = UI.CreateCheckbox(rp, L.CODEX_ROUTE_RANGE, function()
        return routeLvl.below == 3 and routeLvl.above == 3
    end, function(on)
        if on then routeLvl.below, routeLvl.above = 3, 3 else routeLvl.below, routeLvl.above = nil, nil end
        RouteSync()
    end)
    routeCheck:SetPoint("TOPLEFT", rp, "TOPLEFT", 0, -2)
    local lblBelow = UI.CreateLabel(rp, L.CODEX_ROUTE_BELOW, { size = 10, color = "textDim" })
    lblBelow:SetPoint("TOPLEFT", rp, "TOPLEFT", 0, -41)
    lblBelow:SetWidth(86)
    lblBelow:SetWordWrap(false)
    RouteBox(88, function() return routeLvl.below end, function(v) routeLvl.below = v end)
    local lblAbove = UI.CreateLabel(rp, L.CODEX_ROUTE_ABOVE, { size = 10, color = "textDim" })
    lblAbove:SetPoint("TOPLEFT", rp, "TOPLEFT", 140, -41)
    lblAbove:SetWidth(86)
    lblAbove:SetWordWrap(false)
    RouteBox(228, function() return routeLvl.above end, function(v) routeLvl.above = v end)
    local routeGo = UI.CreateButton(rp, L.CODEX_ROUTE_GO, 140, 22, function()
        local ids = {}
        for _, e in ipairs(f.Entries()) do ids[#ids + 1] = e.id end
        Codex.Map:StartRoute(ids, (routeLvl.below or routeLvl.above) and { below = routeLvl.below, above = routeLvl.above } or nil)
    end, "primary")
    routeGo:SetPoint("TOPLEFT", rp, "TOPLEFT", 280, -33)
    local routeButton = UI.CreateButton(f, L.CODEX_ROUTE, 96, 20, function()
        routeOpen = not routeOpen
        RouteSync()
        Layout()
    end, "default")
    if routeButton.HookScript then
        routeButton:HookScript("OnEnter", function(self)
            if GameTooltip then
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                GameTooltip:SetText(L.CODEX_ROUTE_TIP, nil, nil, nil, nil, true)
                GameTooltip:Show()
            end
        end)
        routeButton:HookScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
    end
    routeButton:Hide()

    function UpdateFilterUI()
        for q, b in pairs(qualityButtons) do
            b:SetStyle(flt.q[q] and "primary" or "default")
        end
        for _, d in ipairs(dropdowns) do
            d.dd:SetValue(d.get())
        end
        syncing = true
        for _, n in ipairs(numBoxes) do
            local v = n.get()
            local text = v ~= nil and tostring(v) or ""
            if n.e:GetText() ~= text and not n.e:HasFocus() then
                n.e:SetText(text)
            end
        end
        syncing = false
        for i, b in pairs(opButtons) do
            local isOr = flt.ops and flt.ops[i] == "or"
            b:SetLabel(isOr and L.CODEX_OP_OR or L.CODEX_OP_AND)
            b:SetStyle(isOr and "primary" or "default")
        end
        previewLabel:SetText(StatPreview(flt))
        local n = FilterActive(flt)
        filterButton:SetLabel(n > 0 and string.format(L.CODEX_FILTER_N, n) or L.CODEX_FILTER)
        filterButton:SetStyle(n > 0 and "primary" or "default")
    end

    local farmButton = UI.CreateButton(f, L.CODEX_FARM, 120, 20, function()
        farmOn = not farmOn
        if farmOn then
            roleSel.units = "combat"
            sortBy.units = "gpm"
            sortRev.units = false
        else
            roleSel.units = nil
            sortBy.units = nil
        end
        Refresh()
    end, "default")
    farmButton:Hide()
    local backButton = UI.CreateButton(f, L.CODEX_BACK, 100, 26, function()
        local prev = table.remove(history)
        if prev then
            kind, selected = prev.kind, prev.id
            edit:SetText("")
            edit:ClearFocus()
            Refresh()
        end
    end, "default")
    backButton:SetPoint("TOPLEFT", f, "TOPLEFT", LIST_W + 22, 0)
    backButton:Hide()

    local listScroll = UI.CreateScrollFrame(f)
    listScroll:SetPoint("TOPLEFT", f, "TOPLEFT", 0, -92)
    listScroll:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 0, 0)
    listScroll:SetWidth(LIST_W)

    function Layout()
        local isItems = kind == "items"
        local open = isItems and filterOpen
        if isItems then filterButton:Show() else filterButton:Hide() end
        if open then fp:Show() else fp:Hide() end
        -- rechts neben dem Zaehler: [Vorlage] [Filter]
        local right = LIST_W - (isItems and 100 or 0)
        local hasSeed = SeedOK() and kind ~= "xp" and kind ~= "learn"
        if hasSeed then
            right = right - 100
            seedButton:ClearAllPoints()
            seedButton:SetPoint("TOPLEFT", f, "TOPLEFT", right, -68)
            seedButton:SetLabel(SeedOn() and L.CODEX_SEED_ON or L.CODEX_SEED_OFF)
            seedButton:SetStyle(SeedOn() and "primary" or "default")
            seedButton:Show()
        else
            seedButton:Hide()
        end
        countLabel:SetWidth(math.max(60, right - 6))
        -- eigene Zeile fuer die Auswahl-Listen: Rolle, Kette, Status
        local extra = false
        local hasRole = Codex.Roles.ORDER[kind] ~= nil
        if hasRole then
            roleDD:ClearAllPoints()
            roleDD:SetPoint("TOPLEFT", f, "TOPLEFT", 0, -94)
            roleDD:SetValue(roleSel[kind])
            roleDD:Show()
            extra = true
        else
            roleDD:Hide()
        end
        if kind == "units" then
            farmButton:ClearAllPoints()
            farmButton:SetPoint("TOPLEFT", f, "TOPLEFT", 192, -94)
            farmButton:SetStyle(farmOn and "primary" or "default")
            farmButton:Show()
        else
            farmButton:Hide()
        end
        local isQuests = kind == "quests"
        local x = 0
        if isQuests and hasSeed then
            chainDD:ClearAllPoints()
            chainDD:SetPoint("TOPLEFT", f, "TOPLEFT", x, -94)
            chainDD:SetValue(chainSel)
            chainDD:Show()
            x = x + 190
            extra = true
        else
            chainDD:Hide()
        end
        if isQuests then
            statusDD:ClearAllPoints()
            statusDD:SetPoint("TOPLEFT", f, "TOPLEFT", x, -94)
            statusDD:SetValue(statusSel)
            statusDD:Show()
            routeButton:ClearAllPoints()
            routeButton:SetPoint("TOPLEFT", f, "TOPLEFT", x + 190, -94)
            routeButton:Show()
            extra = true
        else
            statusDD:Hide()
            routeButton:Hide()
        end
        if kind == "zones" then
            zoneDD:ClearAllPoints()
            zoneDD:SetPoint("TOPLEFT", f, "TOPLEFT", 0, -94)
            zoneDD:SetValue(zoneSel)
            zoneDD:Show()
            extra = true
        else
            zoneDD:Hide()
        end
        if Codex.FavSupported(kind) then
            favToggle:Show()
            favToggle:SetStyle(favOnly[kind] and "primary" or "default")
        else
            favToggle:Hide()
        end
        if kind == "learn" and EnsureLearnSel() then
            learnDD:ClearAllPoints()
            learnDD:SetPoint("TOPLEFT", f, "TOPLEFT", 0, -94)
            learnDD:SetValue(learnSel)
            learnDD:Show()
            extra = true
        else
            learnDD:Hide()
        end
        local top = 92 + (extra and 28 or 0)
        local showRoute = kind == "quests" and routeOpen
        if showRoute then
            rp:ClearAllPoints()
            rp:SetPoint("TOPLEFT", f, "TOPLEFT", 0, -top)
            rp:Show()
        else
            rp:Hide()
        end
        routeButton:SetStyle(showRoute and "primary" or "default")
        if showRoute then top = top + ROUTE_H + 6 end
        listScroll:ClearAllPoints()
        FILTER_H = FilterH()
        fp:SetHeight(FILTER_H)
        if ahFilter then ahFilter.label:SetShown(Codex.AuctionProvider ~= nil) end
        for _, nb in ipairs(numBoxes) do
            if nb.ah then nb.box:SetShown(Codex.AuctionProvider ~= nil) end
        end
        listScroll:SetPoint("TOPLEFT", f, "TOPLEFT", 0, -(top + (open and (FILTER_H + 6) or 0)))
        listScroll:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 0, 0)
        listScroll:SetWidth(LIST_W)
    end
    local listEmpty = UI.CreateLabel(listScroll.child, "", { size = 12, color = "textDim", justifyV = "TOP" })
    listEmpty:SetPoint("TOPLEFT", listScroll.child, "TOPLEFT", 4, -6)
    listEmpty:SetPoint("TOPRIGHT", listScroll.child, "TOPRIGHT", -4, -6)
    listEmpty:SetWordWrap(true)

    local separator = f:CreateTexture(nil, "ARTWORK")
    separator:SetColorTexture(UI.Color("bronze", 0.5))
    separator:SetWidth(1)
    separator:SetPoint("TOPLEFT", f, "TOPLEFT", LIST_W + 10, 0)
    separator:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", LIST_W + 10, 0)

    ---------------- rechts: Detail ----------------
    local detail = UI.CreateScrollFrame(f)
    detail:SetPoint("TOPLEFT", f, "TOPLEFT", LIST_W + 22, -34)
    detail:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", 0, 0)
    local detailEmpty = UI.CreateLabel(detail.child, L.CODEX_SELECT, { size = 12, color = "textDim" })
    detailEmpty:SetPoint("TOPLEFT", detail.child, "TOPLEFT", 4, -6)

    -- Namen von Hand eintragen (Deutsch / Englisch)
    local UpdateFavUIRef
    if Codex.NameUI then
        nameCtl = Codex.NameUI.Attach(f, function() return kind, selected end, function()
            dataVersion = dataVersion + 1
            Refresh()
        end, { x = LIST_W + 22, y = 34, relayout = function() if UpdateFavUIRef then UpdateFavUIRef() end end })
    end

    ---------------- Favorit und Notiz ----------------
    local favButton = UI.CreateButton(f, L.CODEX_FAV_ADD, 140, 26, function()
        if selected ~= nil and Codex.FavSupported(kind) then
            Codex.SetFav(kind, selected, not Codex.IsFav(kind, selected))
            dataVersion = dataVersion + 1
            Refresh()
        end
    end, "default")
    favButton:SetPoint("TOPLEFT", f, "TOPLEFT", LIST_W + 22 + 108, 0)
    favButton:Hide()
    local noteBox = UI.CreatePanel(f, "bgDeep", "bronze")
    noteBox:SetHeight(24)
    noteBox:SetPoint("TOPLEFT", f, "TOPLEFT", LIST_W + 22, -34)
    noteBox:SetPoint("TOPRIGHT", f, "TOPRIGHT", 0, -34)
    noteBox:Hide()
    local noteEdit = CreateFrame("EditBox", nil, noteBox)
    noteEdit:SetAutoFocus(false)
    noteEdit:SetPoint("TOPLEFT", noteBox, "TOPLEFT", 8, -2)
    noteEdit:SetPoint("BOTTOMRIGHT", noteBox, "BOTTOMRIGHT", -8, 2)
    noteEdit:SetMaxLetters(200)
    if not noteEdit:SetFont(UI.GetFontPath("body"), 12, "") then
        noteEdit:SetFont("Fonts\\FRIZQT__.TTF", 12, "")
    end
    noteEdit:SetTextColor(UI.Color("text"))
    local noteHint = UI.CreateLabel(noteBox, L.CODEX_NOTE_HINT, { size = 11, color = "textDim" })
    noteHint:SetPoint("LEFT", noteBox, "LEFT", 10, 0)
    local noteTarget = nil
    local function SaveNote()
        if noteTarget then Codex.SetNote(noteTarget.kind, noteTarget.id, noteEdit:GetText()) end
    end
    noteEdit:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    noteEdit:SetScript("OnEnterPressed", function(self) SaveNote(); self:ClearFocus() end)
    noteEdit:SetScript("OnEditFocusLost", function() SaveNote() end)
    noteEdit:SetScript("OnTextChanged", function(self)
        if (self:GetText() or "") == "" then noteHint:Show() else noteHint:Hide() end
    end)

    -- Dev-Notiz (nur mit dem Modul Freewood-Dev und Bearbeitungsrecht): lokal, wird nicht geteilt
    local devNoteBox = UI.CreatePanel(f, "bgDeep", "gold")
    devNoteBox:SetHeight(24)
    devNoteBox:Hide()
    local devNoteEdit = CreateFrame("EditBox", nil, devNoteBox)
    devNoteEdit:SetAutoFocus(false)
    devNoteEdit:SetPoint("TOPLEFT", devNoteBox, "TOPLEFT", 8, -2)
    devNoteEdit:SetPoint("BOTTOMRIGHT", devNoteBox, "BOTTOMRIGHT", -8, 2)
    devNoteEdit:SetMaxLetters(500)
    if not devNoteEdit:SetFont(UI.GetFontPath("body"), 12, "") then
        devNoteEdit:SetFont("Fonts\\FRIZQT__.TTF", 12, "")
    end
    devNoteEdit:SetTextColor(UI.Color("text"))
    local devNoteHint = UI.CreateLabel(devNoteBox, L.CODEX_DEVNOTE_HINT, { size = 11, color = "textDim" })
    devNoteHint:SetPoint("LEFT", devNoteBox, "LEFT", 10, 0)
    local devNoteTarget = nil
    local function SaveDevNote()
        if devNoteTarget then Codex.SetDevNote(devNoteTarget.kind, devNoteTarget.id, devNoteEdit:GetText()) end
    end
    devNoteEdit:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    devNoteEdit:SetScript("OnEnterPressed", function(self) SaveDevNote(); self:ClearFocus() end)
    devNoteEdit:SetScript("OnEditFocusLost", function() SaveDevNote() end)
    devNoteEdit:SetScript("OnTextChanged", function(self)
        if (self:GetText() or "") == "" then devNoteHint:Show() else devNoteHint:Hide() end
    end)

    local function UpdateFavUI()
        local ok = selected ~= nil and Codex.FavSupported(kind)
        local same = noteTarget and noteTarget.kind == kind and noteTarget.id == selected
        if noteEdit:HasFocus() then
            if same and ok and Codex.IsFav(kind, selected) then return end
            SaveNote()
            noteEdit:ClearFocus()
        end
        noteTarget = nil
        local devH = nameCtl and nameCtl.height or 0   -- Reihe mit den Bearbeiten-Knoepfen (nur fuer Berechtigte)
        local top = 34 + devH
        noteBox:ClearAllPoints()
        noteBox:SetPoint("TOPLEFT", f, "TOPLEFT", LIST_W + 22, -top)
        noteBox:SetPoint("TOPRIGHT", f, "TOPRIGHT", 0, -top)
        if ok then
            local fav = Codex.IsFav(kind, selected)
            favButton:Show()
            favButton:SetLabel(fav and L.CODEX_FAV_REMOVE or L.CODEX_FAV_ADD)
            favButton:SetStyle(fav and "primary" or "default")
            if fav then
                noteTarget = { kind = kind, id = selected }
                local e = Codex.GetFav(kind, selected)
                noteEdit:SetText(e and e.note or "")
                noteBox:Show()
                top = top + 30
            else
                noteBox:Hide()
            end
        else
            favButton:Hide()
            noteBox:Hide()
        end
        -- Dev-Notiz
        if devNoteEdit:HasFocus() then SaveDevNote() devNoteEdit:ClearFocus() end
        devNoteTarget = nil
        if selected ~= nil and Codex.DevNoteSupported(kind) and Codex.CanDevNote() then
            devNoteTarget = { kind = kind, id = selected }
            devNoteBox:ClearAllPoints()
            devNoteBox:SetPoint("TOPLEFT", f, "TOPLEFT", LIST_W + 22, -top)
            devNoteBox:SetPoint("TOPRIGHT", f, "TOPRIGHT", 0, -top)
            devNoteEdit:SetText(Codex.GetDevNote(kind, selected) or "")
            devNoteBox:Show()
            top = top + 30
        else
            devNoteBox:Hide()
        end
        detail:ClearAllPoints()
        detail:SetPoint("TOPLEFT", f, "TOPLEFT", LIST_W + 22, -top)
        detail:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", 0, 0)
    end
    UpdateFavUIRef = UpdateFavUI

    -- Bild (Kreatur: 3D-Modell mit Symbol als Rueckfall, Objekt: Symbol)
    local portrait = UI.CreatePanel(detail.child, "bgDeep", "bronze")
    portrait:SetSize(64, 64)
    portrait:SetPoint("TOPLEFT", detail.child, "TOPLEFT", 0, 0)
    portrait:Hide()
    local portraitIcon = portrait:CreateTexture(nil, "ARTWORK")
    portraitIcon:SetPoint("TOPLEFT", portrait, "TOPLEFT", 6, -6)
    portraitIcon:SetPoint("BOTTOMRIGHT", portrait, "BOTTOMRIGHT", -6, 6)
    portraitIcon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    local model = CreateFrame("PlayerModel", nil, portrait)
    model:SetPoint("TOPLEFT", portrait, "TOPLEFT", 2, -2)
    model:SetPoint("BOTTOMRIGHT", portrait, "BOTTOMRIGHT", -2, 2)
    model:SetAlpha(0)
    model:SetScript("OnModelLoaded", function(self)
        self:SetAlpha(1)
        portraitIcon:Hide()
        if self.fwNPC then
            local ok, d = pcall(function() return self.GetDisplayInfo and self:GetDisplayInfo() end)
            if ok and type(d) == "number" and Codex:SetDisplayID(self.fwNPC, d) then
                if f.UpdateRowModels then f.UpdateRowModels() end
            end
        end
    end)

    local function ShowPortrait(iconPath, npcID)
        portrait:Show()
        portraitIcon:SetTexture(iconPath)
        portraitIcon:Show()
        model:SetAlpha(0)
        model.fwNPC = npcID
        if npcID then
            pcall(function()
                model:ClearModel()
                model:SetCreature(npcID)
                if model.SetPortraitZoom then
                    model:SetPortraitZoom(1)
                end
            end)
            local fileID = model.GetModelFileID and model:GetModelFileID()
            if type(fileID) == "number" and fileID > 0 then
                model:SetAlpha(1)
                portraitIcon:Hide()
                local ok, d = pcall(function() return model.GetDisplayInfo and model:GetDisplayInfo() end)
                if ok and type(d) == "number" and Codex:SetDisplayID(npcID, d) and f.UpdateRowModels then
                    f.UpdateRowModels()
                end
            end
        end
    end

    local D = { y = 0, used = 0 }

    local function NewDetailRow()
        local row = CreateFrame("Button", nil, detail.child)
        row.bg = row:CreateTexture(nil, "BACKGROUND")
        row.bg:SetAllPoints()
        row.bg:SetColorTexture(UI.Color("hover", 0))
        row.icon = row:CreateTexture(nil, "ARTWORK")
        row.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        row.left = UI.CreateLabel(row, "", { size = 12 })
        row.right = UI.CreateLabel(row, "", { size = 11, color = "textDim", justify = "RIGHT" })
        row.line = row:CreateTexture(nil, "ARTWORK")
        row.line:SetColorTexture(UI.Color("bronze", 0.6))
        row.line:SetHeight(1)
        row:SetScript("OnEnter", function(self)
            if self.clickable then
                self.bg:SetColorTexture(UI.Color("hover", 0.8))
            end
            if self.itemID and GameTooltip then
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                pcall(GameTooltip.SetItemByID, GameTooltip, self.itemID)
                GameTooltip:Show()
            elseif self.spellID and GameTooltip then
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                local ok = pcall(GameTooltip.SetSpellByID, GameTooltip, self.spellID)
                if not ok then pcall(GameTooltip.SetHyperlink, GameTooltip, "spell:" .. self.spellID) end
                GameTooltip:Show()
            end
        end)
        row:SetScript("OnLeave", function(self)
            self.bg:SetColorTexture(UI.Color("hover", 0))
            if GameTooltip then GameTooltip:Hide() end
        end)
        row:SetScript("OnClick", function(self)
            if self.onClick then
                self.onClick()
            end
        end)
        return row
    end

    -- Verlaufsdiagramm: history = Liste { day, avg, min }, neuester zuerst
    local chart
    local CHART_H = 84
    function D:Chart(history)
        if not history or #history < 2 then
            if chart then chart:Hide() end
            return
        end
        if not chart then
            chart = CreateFrame("Frame", nil, detail.child)
            chart.segs, chart.dots = {}, {}
            chart.bg = chart:CreateTexture(nil, "BACKGROUND")
            chart.bg:SetAllPoints()
            chart.bg:SetColorTexture(UI.Color("bgDeep", 0.6))
            chart.hi = UI.CreateLabel(chart, "", { size = 10, color = "textDim", justify = "RIGHT" })
            chart.lo = UI.CreateLabel(chart, "", { size = 10, color = "textDim", justify = "RIGHT" })
            chart.from = UI.CreateLabel(chart, "", { size = 10, color = "textDim" })
            chart.to = UI.CreateLabel(chart, "", { size = 10, color = "textDim", justify = "RIGHT" })
        end
        local w = detail.child:GetWidth()
        if not w or w < 120 then w = 320 end
        local LABEL_W, PADX, PADY = 78, 6, 8
        local pw, ph = w - LABEL_W - PADX * 2, CHART_H - PADY * 2 - 12
        local pts = {}
        local lo, hi = math.huge, 0
        for i = #history, 1, -1 do
            local v = history[i].avg or history[i].min or 0
            pts[#pts + 1] = { day = history[i].day, v = v }
            if v < lo then lo = v end
            if v > hi then hi = v end
        end
        if hi == lo then lo = lo * 0.9; hi = hi * 1.1 + 1 end
        local n = #pts
        local firstDay, lastDay = pts[1].day, pts[n].day
        local span = math.max(1, lastDay - firstDay)
        for i, p in ipairs(pts) do
            p.x = PADX + (p.day - firstDay) / span * pw
            p.y = PADY + (1 - (p.v - lo) / (hi - lo)) * ph
        end
        chart:ClearAllPoints()
        chart:SetPoint("TOPLEFT", detail.child, "TOPLEFT", 0, -(self.y + 6))
        chart:SetSize(w, CHART_H)
        local function Tex(list, k)
            local t = list[k]
            if not t then
                t = chart:CreateTexture(nil, "ARTWORK")
                list[k] = t
            end
            return t
        end
        for i = 1, n - 1 do
            local a, b = pts[i], pts[i + 1]
            local dx, dy = b.x - a.x, b.y - a.y
            local t = Tex(chart.segs, i)
            t:SetColorTexture(1, 0.82, 0, 0.9)
            t:ClearAllPoints()
            t:SetSize(math.max(1, math.sqrt(dx * dx + dy * dy)), 2)
            t:SetPoint("CENTER", chart, "TOPLEFT", (a.x + b.x) / 2, -(a.y + b.y) / 2)
            if t.SetRotation then t:SetRotation(math.atan2 and math.atan2(-dy, dx) or math.atan(-dy, dx)) end
            t:Show()
        end
        for i = n, #chart.segs do if chart.segs[i] then chart.segs[i]:Hide() end end
        for i, p in ipairs(pts) do
            local t = Tex(chart.dots, i)
            t:SetColorTexture(1, 0.92, 0.4, 1)
            t:SetSize(5, 5)
            t:ClearAllPoints()
            t:SetPoint("CENTER", chart, "TOPLEFT", p.x, -p.y)
            t:Show()
        end
        for i = n + 1, #chart.dots do chart.dots[i]:Hide() end
        chart.hi:ClearAllPoints(); chart.hi:SetPoint("TOPRIGHT", chart, "TOPRIGHT", -4, -4); chart.hi:SetWidth(LABEL_W)
        chart.lo:ClearAllPoints(); chart.lo:SetPoint("BOTTOMRIGHT", chart, "BOTTOMRIGHT", -4, 16); chart.lo:SetWidth(LABEL_W)
        chart.hi:SetText(FormatMoney(hi)); chart.lo:SetText(FormatMoney(lo))
        chart.from:ClearAllPoints(); chart.from:SetPoint("BOTTOMLEFT", chart, "BOTTOMLEFT", PADX, 2)
        chart.to:ClearAllPoints(); chart.to:SetPoint("BOTTOMRIGHT", chart, "BOTTOMRIGHT", -LABEL_W - PADX, 2)
        chart.from:SetText(string.format(L.CODEX_AH_DAYS, lastDay - firstDay))
        chart.to:SetText(L.CODEX_AH_TODAY)
        chart:Show()
        self.y = self.y + 6 + CHART_H + 4
    end

    function D:Reset()
        if chart then chart:Hide() end
        portrait:Hide()
        for _, row in ipairs(detailRows) do
            row:Hide()
        end
        self.y, self.used = 0, 0
    end

    -- opts: style ("title","sub","heading","line","item","link"), text, right, icon, itemID, onClick, indent
    function D:Add(opts)
        self.used = self.used + 1
        local row = detailRows[self.used]
        if not row then
            row = NewDetailRow()
            detailRows[self.used] = row
        end
        local style = opts.style or "line"
        local h = LINE_H
        local top = 0
        if style == "title" then h = 32 elseif style == "sub" then h = 22
        elseif style == "heading" then h = 28; top = 12
        elseif style == "item" or style == "link" then h = 26 end
        if opts.spellID then h = 26 end
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", detail.child, "TOPLEFT", 0, -(self.y + top))
        row:SetPoint("TOPRIGHT", detail.child, "TOPRIGHT", 0, -(self.y + top))
        row:SetHeight(h)
        self.y = self.y + top + h

        local indent = opts.indent or 0
        row.left:ClearAllPoints()
        row.right:ClearAllPoints()
        row.icon:Hide()
        row.line:Hide()
        row.clickable = opts.onClick ~= nil
        row.onClick = opts.onClick
        row.itemID = opts.itemID
        row.spellID = opts.spellID
        row:EnableMouse(row.clickable or opts.itemID ~= nil or opts.spellID ~= nil)

        local leftX = 4 + indent
        if opts.icon then
            row.icon:SetSize(h - 4, h - 4)
            row.icon:ClearAllPoints()
            row.icon:SetPoint("LEFT", row, "LEFT", leftX, 0)
            row.icon:SetTexture(opts.icon)
            row.icon:Show()
            leftX = leftX + h
        end
        row.left:SetPoint("LEFT", row, "LEFT", leftX, 0)
        row.right:SetPoint("RIGHT", row, "RIGHT", -6, 0)
        row.left:SetPoint("RIGHT", row, "RIGHT", opts.right and -(opts.rightWidth or 150) or -6, 0)
        row.left:SetWordWrap(false)

        if style == "title" then
            UI.SetFont(row.left, "heading", 20)
            row.left:SetTextColor(UI.Color("goldLight"))
        elseif style == "sub" then
            UI.SetFont(row.left, "body", 12)
            row.left:SetTextColor(UI.Color("textDim"))
        elseif style == "heading" then
            UI.SetFont(row.left, "heading", 14)
            row.left:SetTextColor(UI.Color("goldLight"))
            row.line:ClearAllPoints()
            row.line:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", 0, 0)
            row.line:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", 0, 0)
            row.line:Show()
        else
            UI.SetFont(row.left, "body", 12)
            row.left:SetTextColor(UI.Color(row.clickable and "goldLight" or "text"))
        end
        row.left:SetText(opts.text or "")
        row.right:SetText(opts.right or "")
        row:Show()
        return row
    end

    function D:Finish()
        detail:SetContentHeight(self.y + 16)
        detailEmpty:SetShown(self.used == 0)
    end

    -- Zeile fuer ein Item (Symbol und Name asynchron)
    local function ItemRow(itemID, right, indent, extraText)
        local row = D:Add({ style = "item", text = "#" .. itemID, right = right, itemID = itemID, indent = indent,
            icon = "Interface\\Icons\\INV_Misc_QuestionMark",
            onClick = function() Go("items", itemID) end })
        local resolved = false
        Util.RequestItem(itemID, function(info)
            if row.itemID ~= itemID or not info then
                return
            end
            resolved = true
            Codex.RememberQuality(itemID, info.quality)
            row.icon:SetTexture(info.icon)
            row.left:SetText(Colored(info.name, info.quality) .. (extraText or ""))
        end)
        local cached = Codex.db.names[itemID]
        if cached and not resolved then
            row.left:SetText(Colored(cached, Codex.QualityOf(itemID) or 1) .. (extraText or ""))
        end
        return row
    end

    local function RefRow(ref, labelKind)
        if not ref then
            D:Add({ text = "-" })
            return
        end
        local tkind = ref.k == "npc" and "units" or ref.k == "object" and "objects" or nil
        local refEnt = tkind and ref.id and Codex.V()[tkind][ref.id]
        local text = (refEnt and Codex.NameOf(refEnt)) or ref.n or (ref.id and ("#" .. ref.id)) or "-"
        D:Add({ style = tkind and ref.id and "link" or "line", text = text,
            onClick = tkind and ref.id and function() Go(tkind, ref.id) end or nil,
            right = ref.m and ref.x and string.format(FW.L.CODEX_POS, Codex.MapName(ref.m), (ref.x or 0) * 100, (ref.y or 0) * 100) or nil })
    end

    local function QuestLink(id, q, right)
        local lvl = q and q.lvl
        if not q and SeedOK() then
            local sq = Codex.Seed.Quest(id)
            lvl = sq and sq.lvl ~= 0 and sq.lvl or nil
            right = right or SeedTag()
        end
        D:Add({ style = "link", text = Codex.QuestTitle(q, id) .. (lvl and ("  (" .. string.format(FW.L.CODEX_LEVEL, lvl) .. ")") or ""),
            right = right, onClick = function() Go("quests", id) end, icon = ICON.quests })
    end

    local function EntityLink(tkind, id, ent, right)
        local lvl = ent and LevelText(ent)
        if not lvl and tkind == "units" and SeedOK() then
            lvl = LevelText(Codex.Seed.Entity(tkind, id) or {})
        end
        D:Add({ style = "link", text = UnitTitle(ent, id, tkind) .. (lvl and ("  (" .. lvl .. ")") or ""),
            right = right, onClick = function() Go(tkind, id) end, icon = ICON[tkind] })
    end

    -- Verweis auf eine Kreatur / ein Objekt / ein Item aus der Vorlage
    local function SeedRef(ref)
        if ref.kind == "items" then
            ItemRow(ref.id, SeedTag(), 0)
            return
        end
        local m, x, y = Codex.Seed.FirstSpot(ref.kind, ref.id)
        local live = Codex.V()[ref.kind][ref.id]
        local lvl = ref.kind == "units" and LevelText(Codex.Seed.Entity(ref.kind, ref.id) or {}) or nil
        D:Add({ style = "link", text = UnitTitle(live, ref.id, ref.kind) .. (lvl and ("  (" .. lvl .. ")") or "") .. "  " .. SeedTag(),
            icon = ICON[ref.kind], onClick = function() Go(ref.kind, ref.id) end,
            right = m and string.format(FW.L.CODEX_POS, Codex.MapName(m), x * 100, y * 100) or nil })
    end

    ---------------- Details je Art ----------------
    local function LootSection(ent, alt)
        local list = Codex.DropList(ent, alt)
        if #list == 0 then
            return
        end
        D:Add({ style = "heading", text = alt and L.CODEX_SEC_ALT or L.CODEX_SEC_LOOT })
        local k = list[1].k
        D:Add({ style = "sub", text = string.format(L.CODEX_KILLS, k) .. ((k < 10) and ("  |  " .. L.CODEX_LOW_SAMPLE) or "") })
        for _, e in ipairs(list) do
            local extra = e.qi and ("  |cff9d9d9d[" .. L.CODEX_QUEST_ITEM .. "]|r") or ""
            local ahp = Codex.AuctionProvider and Codex.AuctionPrice(e.id)
            if ahp and ahp > 0 then
                extra = extra .. "  |cffffd100" .. L.CODEX_AH_SHORT .. " " .. FormatMoney(ahp) .. "|r"
            end
            local right = string.format(L.CODEX_DROP_CHANCE, FormatChance(e.chance), e.n, e.k)
            if e.k < 10 then right = "|cff9d9d9d~ " .. right .. "|r" end
            ItemRow(e.id, right, 0, extra)
        end
    end

    local detailMissing = false
    local function ValueSection(ent)
        local total, coin, items, missing = Codex.KillValue(ent)
        detailMissing = false
        if not total then
            return
        end
        D:Add({ style = "heading", text = L.CODEX_VALUE_HEAD })
        D:Add({ text = L.CODEX_VALUE_COIN, right = FormatMoney(coin) })
        D:Add({ text = L.CODEX_VALUE_ITEMS, right = FormatMoney(items) })
        D:Add({ text = L.CODEX_VALUE_TOTAL, right = FormatMoney(total) })
        if Codex.AuctionProvider then
            local ahTotal, _, ahItems, ahMissing = Codex.KillValue(ent, true)
            if ahTotal then
                D:Add({ text = L.CODEX_VALUE_ITEMS_AH, right = FormatMoney(ahItems) })
                D:Add({ text = L.CODEX_VALUE_TOTAL_AH, right = FormatMoney(ahTotal) })
                if ahMissing > 0 then
                    D:Add({ style = "sub", text = string.format(L.CODEX_VALUE_MISSING, ahMissing) })
                end
            end
        end
        if missing > 0 then
            detailMissing = true
            D:Add({ style = "sub", text = string.format(L.CODEX_VALUE_MISSING, missing) })
        end
    end

    local function QuestsOfUnit(tkind, id, uname)
        local gives, turns, targets = {}, {}, {}
        local refKind = tkind == "units" and "npc" or "object"
        if SeedOK() and Codex.RepairObjectives then Codex.RepairObjectives() end
        local lname = uname and uname:lower() or nil
        for qid, q in pairs(Codex.V().quests) do
            if q.give and q.give.k == refKind and q.give.id == id then gives[#gives + 1] = qid end
            if q.turn and q.turn.k == refKind and q.turn.id == id then turns[#turns + 1] = qid end
            if tkind == "units" then
                for _, o in ipairs(q.obj or {}) do
                    if (o.ids and o.ids[id]) or (lname and o.ty == "monster" and o.name and o.name:lower() == lname) then
                        targets[#targets + 1] = qid
                        break
                    end
                end
            end
        end
        if SeedOK() then
            -- Vorlage: Quests, die wir noch nicht mit diesem Geber / Abgabeort / Ziel kennen
            local sg, st, sx = Codex.Seed.QuestsOf(tkind, id)
            for _, def in ipairs({ { gives, sg }, { turns, st }, { targets, sx } }) do
                local have = {}
                for _, qid in ipairs(def[1]) do have[qid] = true end
                for _, qid in ipairs(def[2]) do
                    if not have[qid] then
                        have[qid] = true
                        def[1][#def[1] + 1] = qid
                    end
                end
            end
        end
        local function QInfo(qid)
            local q = Codex.V().quests[qid]
            local lvl = q and q.lvl
            if not lvl and SeedOK() then
                local sq = Codex.Seed.Quest(qid)
                lvl = sq and sq.lvl
            end
            return lvl or 0, Codex.QuestTitle(q, qid)
        end
        local function Sorted(list)
            table.sort(list, function(a, b)
                local la, ta = QInfo(a)
                local lb, tb = QInfo(b)
                if la ~= lb then return la < lb end
                if ta ~= tb then return ta < tb end
                return a < b
            end)
            return list
        end
        for _, def in ipairs({ { gives, L.CODEX_SEC_GIVES }, { turns, L.CODEX_SEC_TURNS }, { targets, L.CODEX_SEC_TARGET } }) do
            if #def[1] > 0 then
                D:Add({ style = "heading", text = def[2] })
                for i, qid in ipairs(Sorted(def[1])) do
                    if i > 30 then break end
                    QuestLink(qid, Codex.V().quests[qid])
                end
            end
        end
    end

    local MAP_ICON = "Interface\\Icons\\INV_Misc_Map_01"

    local function MapLink(spec, label)
        D:Add({ style = "link", text = L.CODEX_MAP_SHOW, icon = MAP_ICON,
            onClick = function()
                Codex.Map:Show(Codex.CollectPoints(spec), label)
            end })
    end

    local function SpotRows(cells, limit, noHits)
        for _, s in ipairs(Codex.TopSpots(cells, limit or 8)) do
            D:Add({ text = string.format(L.CODEX_POS, Codex.MapName(s.m), s.x * 100, s.y * 100),
                right = (not noHits) and string.format(L.CODEX_SPOT_HITS, s.n) or nil })
        end
    end

    -- Fundorte: eigene Beobachtungen, sonst die Vorlage
    local function PlacesSection(ent, spec, label, seedCells)
        if ent and ent.cells and next(ent.cells) ~= nil then
            D:Add({ style = "heading", text = L.CODEX_SEC_SPOTS })
            SpotRows(ent.cells, 8)
        elseif seedCells and next(seedCells) ~= nil then
            D:Add({ style = "heading", text = L.CODEX_SEC_SPOTS .. "  " .. SeedTag() })
            SpotRows(seedCells, 8, true)
        else
            return
        end
        if spec then
            MapLink(spec, label)
        end
    end

    local function ShowQuest(id)
        local live = Codex.V().quests[id]
        local sq = SeedOK() and Codex.Seed.Quest(id) or nil
        local catTitle, catLvl
        if not live and not sq and Codex.Catalog then catTitle, catLvl = Codex.Catalog.Get(id) end
        if not live and not sq and not catTitle then return end
        local q = live or {}
        D:Add({ style = "title", text = catTitle or Codex.QuestTitle(live, id) })
        local sub = {}
        local lvl = q.lvl or (sq and sq.lvl and sq.lvl > 0 and sq.lvl) or catLvl or nil
        if lvl then sub[#sub + 1] = string.format(L.CODEX_LEVEL, lvl) end
        if sq and sq.min and sq.min > 0 then sub[#sub + 1] = string.format(L.CODEX_MINLEVEL, sq.min) end
        if q.zone then
            sub[#sub + 1] = Codex.MapName(q.zone)
        elseif sq then
            local ref = sq.start[1] or sq.stop[1]
            local m = ref and ref.kind ~= "items" and Codex.Seed.MapOf(ref.kind, ref.id)
            if m then sub[#sub + 1] = Codex.MapName(m) end
        end
        if q.dg ~= nil then sub[#sub + 1] = q.dg and L.CODEX_PROPS_DG_YES or L.CODEX_PROPS_DG_NO end
        if (q.seen or 0) > 0 then sub[#sub + 1] = string.format(L.CODEX_SEEN, q.seen) end
        if (q.done or 0) > 0 then sub[#sub + 1] = string.format(L.CODEX_DONE, q.done) end
        sub[#sub + 1] = "ID " .. id
        if not live then sub[#sub + 1] = catTitle and ("|cff8a8a96[" .. L.CODEX_CAT_TAG .. "]|r") or SeedTag() end
        D:Add({ style = "sub", text = table.concat(sub, "  |  ") })
        if not live then
            D:Add({ style = "sub", text = catTitle and L.CODEX_CAT_NOTE or L.CODEX_SEED_NOTE })
        end
        local status = Codex.QuestStatus(id)
        D:Add({ style = "sub", text = string.format(L.CODEX_STATUS_LINE,
            status == "done" and L.CODEX_STATUS_DONE or status == "active" and L.CODEX_STATUS_ACTIVE or L.CODEX_STATUS_OPEN) })
        if q.rem then
            D:Add({ style = "sub", text = L.CODEX_REMOTE_ONLY })
        end
        if q.partial then
            D:Add({ style = "sub", text = L.CODEX_PARTIAL })
        end

        if q.tm and q.tm.n and q.tm.n > 0 then
            D:Add({ style = "heading", text = L.CODEX_SEC_TIME })
            D:Add({ text = L.CODEX_QT_EFF, right = FormatDuration(q.tm.sum / q.tm.n / 10) })
            if q.tr and q.tr.n and q.tr.n > 0 then
                D:Add({ text = L.CODEX_QT_RAW, right = FormatDuration(q.tr.sum / q.tr.n / 10) })
            end
            if q.ta and q.ta.n and q.ta.n > 0 then
                D:Add({ text = L.CODEX_QT_ALL, right = FormatDuration(q.ta.sum / q.ta.n / 10) })
            end
            D:Add({ text = L.CODEX_QT_N, right = tostring(q.tm.n) })
        end

        D:Add({ style = "heading", text = L.CODEX_SEC_GIVE })
        if q.si then
            -- Quest startet durch ein Item: das Item (mit seinen Fundorten im Item-Eintrag) statt einer Spielerposition
            D:Add({ style = "sub", text = L.CODEX_GIVE_BY_ITEM })
            ItemRow(q.si, nil, 0, "  |cff9d9d9d[" .. L.CODEX_START_ITEM .. "]|r")
        elseif q.give or not (sq and #sq.start > 0) then
            RefRow(q.give)
        else
            for _, r in ipairs(sq.start) do SeedRef(r) end
        end
        D:Add({ style = "heading", text = L.CODEX_SEC_TURN })
        if q.turn or not (sq and #sq.stop > 0) then
            RefRow(q.turn)
        else
            for _, r in ipairs(sq.stop) do SeedRef(r) end
        end
        if #Codex.CollectPoints({ kind = "quests", id = id }) > 0 then
            MapLink({ kind = "quests", id = id }, Codex.QuestTitle(q, id))
        end

        if q.si then
            D:Add({ style = "sub", text = L.CODEX_PROPS_STARTITEM .. " " .. tostring(q.si) .. " " .. tostring(Codex.ItemName and Codex:ItemName(q.si) or "") })
        end
        if q.dtx then
            D:Add({ style = "heading", text = L.CODEX_SEC_QTEXT })
            D:Add({ style = "sub", text = q.dtx })
        end

        local hasReward = q.xp or q.money or q.rep or q.fixed or q.choice
        if hasReward then
            D:Add({ style = "heading", text = L.CODEX_SEC_REWARD })
            if q.xp then D:Add({ text = L.CODEX_XP, right = tostring(q.xp) }) end
            if q.money then
                D:Add({ text = L.CODEX_MONEY, right = FormatMoney(q.money) })
            end
            if q.rep then
                local names = {}
                for name in pairs(q.rep) do names[#names + 1] = name end
                table.sort(names)
                for _, name in ipairs(names) do
                    local v = q.rep[name]
                    D:Add({ text = L.CODEX_REP .. ": " .. name, right = (v > 0 and "+" or "") .. v })
                end
            end
            for _, r in ipairs(q.fixed or {}) do
                ItemRow(r.id, r.c and r.c > 1 and ("x" .. r.c) or nil, 0, "  |cff9d9d9d[" .. L.CODEX_FIXED .. "]|r")
            end
            for _, r in ipairs(q.choice or {}) do
                local chosen = q.chosen and q.chosen[r.id]
                ItemRow(r.id, chosen and string.format(L.CODEX_CHOSEN, chosen) or (r.c and r.c > 1 and ("x" .. r.c) or nil), 0,
                    "  |cff9d9d9d[" .. L.CODEX_CHOICE .. "]|r")
            end
        end

        if q.obj and #q.obj > 0 then
            D:Add({ style = "heading", text = L.CODEX_SEC_OBJ })
            for _, o in ipairs(q.obj) do
                local label = L["CODEX_TYPE_" .. tostring(o.ty)] or L.CODEX_TYPE_other
                local itemIDs = o.ty == "item" and Codex.ObjectiveItems(q, o) or nil
                local shownName = o.name
                if not shownName and itemIDs and itemIDs[1] then
                    shownName = Codex:ItemName(itemIDs[1])
                end
                D:Add({ text = label .. ": " .. (shownName or o.txt or "?"), right = o.req and ("x" .. o.req) or nil })
                local lname = o.name and o.name:lower() or nil
                if o.ty == "monster" then
                    local shown = {}
                    local ids = {}
                    for uid, hits in pairs(o.ids or {}) do ids[#ids + 1] = { id = uid, n = hits } end
                    table.sort(ids, function(a, b) return a.n > b.n end)
                    for _, e in ipairs(ids) do
                        shown[e.id] = true
                        EntityLink("units", e.id, Codex.V().units[e.id], nil)
                    end
                    if lname then
                        local count = 0
                        for uid, u in pairs(Codex.V().units) do
                            if not shown[uid] and ((u.n and u.n:lower() == lname) or (u.cde and u.cde:lower() == lname) or (u.cen and u.cen:lower() == lname)) then
                                count = count + 1
                                if count > 4 then break end
                                EntityLink("units", uid, u, nil)
                            end
                        end
                    end
                elseif itemIDs then
                    for _, itemID in ipairs(itemIDs) do
                        local srcs = q.qi and q.qi[itemID]
                        if srcs then
                            local list = {}
                            for key, n in pairs(srcs) do list[#list + 1] = { key = key, n = n } end
                            table.sort(list, function(a, b) return a.n > b.n end)
                            for i, e in ipairs(list) do
                                if i > 6 then break end
                                local tk = e.key:sub(1, 1) == "u" and "units" or "objects"
                                local sid = tonumber(e.key:sub(2))
                                local ent = tk == "units" and Codex.V().units[sid] or Codex.V().objects[sid]
                                EntityLink(tk, sid, ent, tostring(e.n) .. "x")
                            end
                        end
                    end
                end
            end
        elseif sq and #sq.obj > 0 then
            D:Add({ style = "heading", text = L.CODEX_SEC_OBJ .. "  " .. SeedTag() })
            for _, r in ipairs(sq.obj) do SeedRef(r) end
        end

        -- Questkette: Vorquests und Folgequests (Daten und Vorlage)
        do
            local function Chain(heading, ids)
                if #ids == 0 then return end
                D:Add({ style = "heading", text = heading })
                for i, qid in ipairs(ids) do
                    if i > 30 then break end
                    local lq = Codex.V().quests[qid]
                    QuestLink(qid, lq, lq and (lq.done or 0) > 0 and string.format(L.CODEX_DONE, lq.done) or nil)
                end
            end
            Chain(L.CODEX_SEC_PRE, Codex.QuestPre(id))
            Chain(L.CODEX_SEC_NEXT, Codex.QuestNext(id))
        end
    end

    local function XPSection(ent)
        if not ent.xp or next(ent.xp) == nil then
            return
        end
        D:Add({ style = "heading", text = L.CODEX_SEC_XP })
        local levels = {}
        for pl in pairs(ent.xp) do levels[#levels + 1] = pl end
        table.sort(levels, function(a, b) return a > b end)
        local rows = 0
        for _, pl in ipairs(levels) do
            local xm = ent.xm and ent.xm[pl]
            if xm and next(xm) then
                -- nach Gegnerstufe getrennt: zu jeder Zeile gehoert ein Formelwert
                local mls = {}
                for ml in pairs(xm) do mls[#mls + 1] = ml end
                table.sort(mls, function(a, b) return a > b end)
                for _, ml in ipairs(mls) do
                    if rows >= 12 then break end
                    rows = rows + 1
                    local s = xm[ml]
                    local pred = Codex.PredictXP(pl, ml, ent.c)
                    D:Add({
                        text = string.format(L.CODEX_XP_UNIT_ROW2, pl, ml),
                        right = string.format("Ø %.1f  (n=%d)", s.sum / s.n, s.n) .. "  |  " .. pred,
                    })
                    local rs = ent.xr and ent.xr[pl] and ent.xr[pl][ml]
                    if rs and rs.n and rs.n > 0 and rows < 12 then
                        rows = rows + 1
                        D:Add({
                            style = "sub",
                            text = "   " .. L.CODEX_XP_WITH_RESTED,
                            right = string.format("Ø %.1f  (n=%d)", rs.sum / rs.n, rs.n),
                        })
                    end
                end
            elseif rows < 12 then
                rows = rows + 1
                local s = ent.xp[pl]
                local right = string.format("Ø %.1f  (n=%d)", s.sum / s.n, s.n)
                if ent.l1 and ent.l1 == ent.l2 then
                    right = right .. "  |  " .. Codex.PredictXP(pl, ent.l1, ent.c)
                end
                D:Add({ text = string.format(L.CODEX_XP_UNIT_ROW, pl), right = right })
            end
        end
    end

    -- Beute und Waren laut Vorlage; was wir selbst gesehen haben, steht schon oben und wird hier uebersprungen
    local function SeedLootSection(tkind, id, ent)
        local shown = {}
        for _, e in ipairs(Codex.Seed.Drops(tkind, id)) do
            local seen = (ent and ent.d and ent.d[e.item]) or (ent and ent.alt and ent.alt.d and ent.alt.d[e.item])
            if not seen then shown[#shown + 1] = e end
        end
        if #shown > 0 then
            D:Add({ style = "heading", text = L.CODEX_SEC_LOOT_SEED })
            for i, e in ipairs(shown) do
                if i > 40 then break end
                ItemRow(e.item, SeedPct(e.chance), 0)
            end
        end
        local roles = Codex.Seed.Roles(tkind, id)
        if tkind == "units" and roles and roles.vendor then
            local goods = Codex.Seed.VendorItems(id)
            if #goods > 0 then
                D:Add({ style = "heading", text = L.CODEX_SEC_SELLS })
                local shownWares = 0
                for _, itemID in ipairs(goods) do
                    if not (ent and ent.wa and ent.wa[itemID]) then
                        shownWares = shownWares + 1
                        if shownWares > 60 then break end
                        ItemRow(itemID, nil, 0)
                    end
                end
            end
        end
    end

    -- Rollen laut eigenen und geteilten Beobachtungen: Waren mit allen Preisen, Lehrstoff, Flugziele
    local function RolesSection(tkind, ent)
        if tkind ~= "units" then return end
        if ent.ti then
            D:Add({ style = "sub", text = string.format(L.CODEX_TITLE_LINE, ent.ti) })
        end
        if ent.wa and next(ent.wa) then
            local goods = {}
            for itemID, w in pairs(ent.wa) do goods[#goods + 1] = { id = itemID, w = w } end
            table.sort(goods, function(a, b) return a.id < b.id end)
            D:Add({ style = "heading", text = string.format(L.CODEX_SEC_WARES, #goods) })
            for i, g in ipairs(goods) do
                if i > 120 then break end
                local extra = {}
                if g.w.st and g.w.st > 1 then extra[#extra + 1] = "x" .. g.w.st end
                if g.w.lim then extra[#extra + 1] = L.CODEX_WARE_LIMITED end
                ItemRow(g.id, PriceText(g.w.pr, g.w.ec), 0, #extra > 0 and ("  |cff9a9aa3" .. table.concat(extra, " ") .. "|r") or nil)
            end
        end
        if ent.tr and next(ent.tr) then
            local list = {}
            for _, r in pairs(ent.tr) do list[#list + 1] = r end
            table.sort(list, function(a, b)
                if (a.lv or 0) ~= (b.lv or 0) then return (a.lv or 0) < (b.lv or 0) end
                return (a.nm or "") < (b.nm or "")
            end)
            D:Add({ style = "heading", text = string.format(L.CODEX_SEC_TRAINS, #list) })
            for i, r in ipairs(list) do
                if i > 150 then break end
                local right = {}
                if r.lv then right[#right + 1] = string.format(L.CODEX_TRAIN_LEVEL, r.lv) end
                if r.sn then right[#right + 1] = r.sr and string.format("%s %d", r.sn, r.sr) or r.sn end
                local price = PriceText(r.pr)
                if price then right[#right + 1] = price end
                local rank = r.rk or (r.sp and Codex.SpellRank(r.sp)) or nil
                local icon = r.sp and Codex.SpellIcon(r.sp) or nil
                D:Add({ text = (r.nm or "?") .. (rank and ("  |cff9a9aa3(" .. rank .. ")|r") or ""),
                    right = table.concat(right, "  |  "), rightWidth = 330,
                    spellID = r.sp, icon = icon or (r.sp and "Interface\\Icons\\INV_Misc_QuestionMark") or nil })
            end
        end
        if ent.fl and next(ent.fl) then
            local list = {}
            for dest, pr in pairs(ent.fl) do list[#list + 1] = { dest = dest, pr = pr } end
            table.sort(list, function(a, b) return a.dest < b.dest end)
            D:Add({ style = "heading", text = string.format(L.CODEX_SEC_FLIGHTS, #list) })
            if ent.fn then D:Add({ style = "sub", text = string.format(L.CODEX_FLIGHT_FROM, ent.fn) }) end
            for _, e in ipairs(list) do
                D:Add({ text = e.dest, right = PriceText(e.pr) })
            end
        end
    end

    local function ShowEntity(tkind, id)
        local live = tkind == "units" and Codex.V().units[id] or Codex.V().objects[id]
        local seedEnt = SeedOK() and Codex.Seed.Entity(tkind, id) or nil
        if not live and not seedEnt then return end
        local ent = live or {}
        ShowPortrait(tkind == "units" and UnitIcon(ent) or ICON.objects, tkind == "units" and id or nil)
        D:Add({ style = "title", text = UnitTitle(ent, id, tkind), indent = 76 })
        local sub = {}
        local lvl = LevelText(ent) or (seedEnt and tkind == "units" and LevelText(seedEnt)) or nil
        if lvl then sub[#sub + 1] = lvl end
        if ent.c then
            sub[#sub + 1] = (ent.ed and ent.ed.cl and L["CODEX_PROPS_CLASS_" .. ent.ed.cl]) or ent.c
        elseif ent.c == false then
            sub[#sub + 1] = L.CODEX_PROPS_CLASS_normal
        elseif seedEnt and tkind == "units" and RankLabel(seedEnt.rank) then
            sub[#sub + 1] = RankLabel(seedEnt.rank)
        end
        if ent.dg ~= nil then
            sub[#sub + 1] = ent.dg and L.CODEX_PROPS_DG_YES or L.CODEX_PROPS_DG_NO
        elseif ent.iz and next(ent.iz) then
            sub[#sub + 1] = L.CODEX_PROPS_DG_YES
        end
        if not (ent.ez and #ent.ez > 0) and ent.iz and next(ent.iz) then
            local names = {}
            for iid in pairs(ent.iz) do names[#names + 1] = Codex.InstanceName(iid) end
            table.sort(names)
            sub[#sub + 1] = string.format(L.CODEX_PROPS_ZONES_LINE, table.concat(names, ", "))
        end
        if ent.ez and #ent.ez > 0 then
            local names = {}
            for _, m in ipairs(ent.ez) do names[#names + 1] = Codex.MapName(m) end
            sub[#sub + 1] = string.format(L.CODEX_PROPS_ZONES_LINE, table.concat(names, ", "))
        end
        if ent.f then sub[#sub + 1] = string.format(L.CODEX_FAMILY, ent.f) end
        if seedEnt and (seedEnt.fac == "A" or seedEnt.fac == "H") then
            sub[#sub + 1] = seedEnt.fac == "A" and L.CODEX_FAC_A or L.CODEX_FAC_H
        end
        local roleNames = RoleNames(tkind, id)
        if #roleNames > 0 then sub[#sub + 1] = table.concat(roleNames, ", ") end
        sub[#sub + 1] = "ID " .. id
        if not live then sub[#sub + 1] = SeedTag() end
        D:Add({ style = "sub", text = table.concat(sub, "  |  "), indent = 76 })
        D.y = math.max(D.y, 72)
        if not live then
            D:Add({ style = "sub", text = L.CODEX_SEED_NOTE })
        end
        -- Gebiet mit Stufenspanne (Verweis in die Gebietsansicht)
        for i, zkey in ipairs(Codex.ZonesOf(ent)) do
            if i > 3 then break end
            local zd = Codex.Zones and Codex.Zones.Get(zkey)
            D:Add({ style = "link", text = Codex.MapName(zkey), icon = ICON.zones,
                right = zd and RangeText(zd.lo, zd.hi) or nil, onClick = function() Go("zones", zkey) end })
        end
        local ttkClasses = Codex.Time and Codex.Time.UnitClasses(ent) or {}
        if #ttkClasses > 0 then
            D:Add({ style = "heading", text = L.CODEX_SEC_TTK_CLASSES })
            for _, c in ipairs(ttkClasses) do
                D:Add({
                    text = Codex.Time.ClassLabel(c.cls) .. (c.own and ("  " .. L.CODEX_TTK_YOU) or ""),
                    right = string.format("%.1f s  (n=%d)", c.secs, c.n),
                })
            end
        end
        if ent.rk and ent.rk > 0 then
            D:Add({ style = "sub", text = string.format(L.CODEX_REMOTE_HINT, ent.rk, ent.k or 0) })
        elseif ent.remote and ent.remote > 0 then
            D:Add({ style = "sub", text = L.CODEX_REMOTE_ONLY })
        end
        local avg = Codex.AverageCoin(ent)
        if avg then
            D:Add({ text = string.format(L.CODEX_COIN_AVG, ""), right = FormatMoney(avg) })
        end
        PlacesSection(ent, { kind = tkind, id = id }, UnitTitle(ent, id, tkind), seedEnt and Codex.Seed.Cells(tkind, id) or nil)
        RolesSection(tkind, ent)
        XPSection(ent)
        ValueSection(ent)
        QuestsOfUnit(tkind, id, UnitTitle(ent, id, tkind))
        LootSection(ent, false)
        if ent.alt then LootSection(ent, true) end
        if seedEnt then SeedLootSection(tkind, id, live) end
    end

    local function ShowZone(key)
        local zd = Codex.Zones.Get(key)
        if not zd then return end
        ShowPortrait(ICON.zones, nil)
        D:Add({ style = "title", text = Codex.MapName(key), indent = 76 })
        local sub = { zd.dungeon and L.CODEX_ZONE_DUNGEON or L.CODEX_ZONE_WORLD, (key < 0 and "Instanz " or "Karte ") .. math.abs(key) }
        D:Add({ style = "sub", text = table.concat(sub, "  |  "), indent = 76 })
        D.y = math.max(D.y, 72)
        D:Add({ style = "heading", text = L.CODEX_SEC_ZONE_LEVELS })
        D:Add({ text = L.CODEX_ZONE_TYPICAL, right = RangeText(zd.lo, zd.hi) or "-" })
        if zd.avg then D:Add({ text = L.CODEX_ZONE_AVG, right = string.format("%.1f", zd.avg) }) end
        D:Add({ text = L.CODEX_ZONE_COUNT, right = tostring(zd.units) })
        if zd.manual then D:Add({ style = "sub", text = L.CODEX_ZONE_MANUAL_NOTE }) end
        if zd.few and not zd.manual then D:Add({ style = "sub", text = L.CODEX_ZONE_FEW_NOTE }) end
        if #zd.out > 0 then
            local parts = {}
            for _, e in ipairs(zd.out) do
                local ent = Codex.V().units[e.id]
                parts[#parts + 1] = string.format("%s (%s)", UnitTitle(ent, e.id, "units"), RangeText(e.l1, e.l2) or "?")
                if #parts >= 6 then break end
            end
            D:Add({ style = "sub", text = L.CODEX_ZONE_OUTLIER_LIST .. ": " .. table.concat(parts, ", ") })
        end
        -- eigene Messung (Modul Quest): Erfahrung pro Stunde in diesem Gebiet, nur fuer die aktuellen Einstellungen
        local rates = Codex.ZoneRateProvider and Codex.ZoneRateProvider(key) or {}
        if #rates > 0 then
            D:Add({ style = "heading", text = L.CODEX_SEC_ZONE_RATE })
            D:Add({ style = "sub", text = L.CODEX_ZONE_RATE_NOTE })
            for _, r in ipairs(rates) do
                local mins = r.hours and (r.hours * 60) or nil
                D:Add({ text = string.format(L.CODEX_ZONE_RATE_LINE, r.pl), right = string.format("%d XP/h%s  (%d min)",
                    r.rate, mins and string.format(L.CODEX_ZONE_RATE_LEVEL, mins) or "", r.secs / 60) })
            end
        end
        -- Kreaturen des Gebiets, nach Stufe
        local members = Codex.Zones.Members(key)
        D:Add({ style = "heading", text = string.format(L.CODEX_SEC_ZONE_UNITS, #members) })
        for i, m in ipairs(members) do
            if i > 150 then break end
            local ent = Codex.V().units[m.id]
            local tags = {}
            if m.c then tags[#tags + 1] = (L["CODEX_PROPS_CLASS_" .. tostring(m.c)] or tostring(m.c)) end
            if m.out then tags[#tags + 1] = L.CODEX_ZONE_OUTLIER end
            D:Add({ style = "link", text = UnitTitle(ent, m.id, "units") .. "  (" .. (RangeText(m.l1, m.l2) or "?") .. ")",
                right = #tags > 0 and table.concat(tags, ", ") or nil, onClick = function() Go("units", m.id) end, icon = ICON.units })
        end
        -- Spanne von Hand setzen (nur Berechtigte)
        if Codex.Trust and Codex.Trust.CanEdit() and Codex.NameUI and Codex.NameUI.OpenZone then
            D:Add({ style = "heading", text = L.CODEX_SEC_ZONE_EDIT })
            D:Add({ style = "link", text = L.CODEX_ZONE_EDIT, onClick = function() Codex.NameUI.OpenZone(key) end })
        end
    end

    local function ShowLearn(lv)
        local plan = learnSel and Codex.LearnPlan(learnSel)
        local g = plan and plan.levels[lv]
        if not g then return end
        local pl = UnitLevel and UnitLevel("player") or 1
        ShowPortrait(ICON.learn, nil)
        local head = lv > 0 and string.format(L.CODEX_LEARN_TITLE, lv) or L.CODEX_LEARN_LVUNKNOWN
        D:Add({ style = "title", text = head .. "  -  " .. Codex.Time.ClassLabel(learnSel), indent = 76 })
        D:Add({ style = "sub", text = string.format(L.CODEX_LEARN_SUB, #g.spells, FormatMoney(g.cost)), indent = 76 })
        D.y = math.max(D.y, 72)
        if lv > pl then
            D:Add({ text = string.format(L.CODEX_LEARN_CUM, pl + 1, FormatMoney(Codex.LearnCost(plan, pl, lv))) })
        end
        D:Add({ style = "sub", text = L.CODEX_LEARN_NOTE })
        D:Add({ style = "heading", text = string.format(L.CODEX_SEC_LEARN_SPELLS, #g.spells) })
        for _, sp in ipairs(g.spells) do
            local rank = sp.rk or (sp.sp and Codex.SpellRank(sp.sp)) or nil
            local icon = sp.sp and Codex.SpellIcon(sp.sp) or nil
            D:Add({ text = (sp.nm or "?") .. (rank and ("  |cff9a9aa3(" .. rank .. ")|r") or ""),
                right = (sp.cost and sp.cost > 0) and FormatMoney(sp.cost) or "-", rightWidth = 150,
                spellID = sp.sp, icon = icon or (sp.sp and "Interface\\Icons\\INV_Misc_QuestionMark") or nil })
        end
        D:Add({ style = "heading", text = string.format(L.CODEX_SEC_LEARN_TRAINERS, #g.trainers) })
        for i, id in ipairs(g.trainers) do
            if i > 20 then break end
            local ent = Codex.V().units[id]
            local spot = ent and ZoneOf(ent)
            EntityLink("units", id, ent, spot)
        end
    end

    local function ShowXP(key)
        local pl, ml, cls, kindFlag = key:match("^(%d+):(%d+):(%a+):(%a)$")
        pl, ml = tonumber(pl), tonumber(ml)
        if not pl then return end
        local rows = Codex:XPRows(true)
        local r
        for _, row in ipairs(rows) do
            if XPKey(row) == key then r = row break end
        end
        if not r then return end
        ShowPortrait(ICON.xp, nil)
        D:Add({ style = "title", text = string.format(L.CODEX_XP_TITLE, pl, ml), indent = 76 })
        local sub = {}
        local label = ClassLabel(cls)
        if label then sub[#sub + 1] = label end
        if r.rested then
            sub[#sub + 1] = L.CODEX_XP_RESTED_TAG
        elseif r.bonus then
            sub[#sub + 1] = L.CODEX_XP_BONUS_TAG
        end
        D:Add({ style = "sub", text = table.concat(sub, "  |  "), indent = 76 })
        D.y = math.max(D.y, 72)

        D:Add({ style = "heading", text = L.CODEX_SEC_XPMEAS })
        D:Add({ text = L.CODEX_XP_SAMPLES, right = tostring(r.n) })
        D:Add({ text = L.CODEX_XP_AVG, right = string.format("%.2f", r.avg) })
        D:Add({ text = L.CODEX_XP_MINMAX, right = string.format("%d / %d", r.min, r.max) })

        local secs, nTTK
        if not r.bonus and cls == "normal" then
            secs, nTTK = OwnTTK(pl, ml)
        end
        if secs and secs > 0 then
            D:Add({ style = "heading", text = L.CODEX_SEC_TIME })
            D:Add({ text = string.format(L.CODEX_TTK_AVG, Codex.Time.ClassName()), right = string.format("%.1f s  (n=%d)", secs, nTTK) })
            D:Add({ text = L.CODEX_TTK_XPM, right = string.format("%d", r.avg / secs * 60) })
        end

        if not r.bonus and cls == "normal" and Codex.Share and Codex.Share.TTKClasses then
            local classes = Codex.Share.TTKClasses(pl, ml - pl)
            if #classes > 0 then
                D:Add({ style = "heading", text = L.CODEX_SEC_TTK_CLASSES })
                local mine = Codex.Time and Codex.Time.PlayerToken()
                for _, c in ipairs(classes) do
                    D:Add({
                        text = Codex.Time.ClassLabel(c.cls) .. (c.cls == mine and ("  " .. L.CODEX_TTK_YOU) or ""),
                        right = string.format("%.1f s  (n=%d)  |  %d XP/min", c.secs, c.n, r.avg / c.secs * 60),
                    })
                end
            end
        end

        D:Add({ style = "heading", text = L.CODEX_SEC_XPCALC })
        D:Add({ text = L.CODEX_XP_BASE, right = tostring((ml >= pl and pl or ml) * 5 + 45) })
        D:Add({ text = L.CODEX_XP_COLOR, right = L["CODEX_COLOR_" .. r.color] or r.color })
        D:Add({ text = L.CODEX_XP_ZD, right = tostring(Codex.ZeroDiff(pl)) })
        D:Add({ text = L.CODEX_XP_GRAY, right = tostring(Codex.GrayLevel(pl)) })
        D:Add({ text = L.CODEX_XP_PRED, right = tostring(r.pred) })
        D:Add({ text = L.CODEX_XP_DIFF, right = string.format("%+.2f", r.diff) })
        D:Add({ style = "sub", text = L.CODEX_XP_NOTE })
    end

    local function ShowItem(itemID)
        local row = D:Add({ style = "title", text = Codex:ItemName(itemID) or ("#" .. itemID), icon = "Interface\\Icons\\INV_Misc_QuestionMark" })
        row.itemID = itemID
        row:EnableMouse(true)
        local q0 = Codex.QualityOf(itemID)
        if q0 then row.left:SetText(Colored(Codex:ItemName(itemID) or ("#" .. itemID), q0)) end
        Util.RequestItem(itemID, function(info)
            if info then
                Codex.RememberQuality(itemID, info.quality)
                row.icon:SetTexture(info.icon)
                row.left:SetText(Colored(Codex:ItemName(itemID) or info.name, info.quality))
            end
        end)
        D:Add({ style = "sub", text = "ID " .. itemID })
        local ied = (Codex.V().ied or {})[itemID]
        local iz = ied and (ied.ez or (ied.ed and ied.ed.z))
        local idg = ied and (ied.dg ~= nil and ied.dg or (ied.ed and ied.ed.dg))
        if iz or idg ~= nil then
            local bits = {}
            if iz and #iz > 0 then
                local names = {}
                for _, m in ipairs(iz) do names[#names + 1] = Codex.MapName(m) end
                bits[#bits + 1] = string.format(L.CODEX_PROPS_ZONES_LINE, table.concat(names, ", "))
            end
            if idg ~= nil then bits[#bits + 1] = idg and L.CODEX_PROPS_DG_YES or L.CODEX_PROPS_DG_NO end
            D:Add({ style = "sub", text = table.concat(bits, "  |  ") })
        end

        -- Auktionshaus (nur mit Auktions-Modul)
        local ai = Codex.AuctionInfo and Codex.AuctionInfo(itemID)
        if ai then
            D:Add({ style = "heading", text = L.CODEX_SEC_AH })
            local thin = ai.thin and "  |cffff8000~|r" or ""
            if ai.price then D:Add({ text = L.CODEX_AH_PRICE, right = FormatMoney(ai.price) .. thin }) end
            if ai.min then D:Add({ text = L.CODEX_AH_MIN, right = FormatMoney(ai.min) }) end
            if ai.avg then D:Add({ text = L.CODEX_AH_AVG, right = FormatMoney(ai.avg) }) end
            if ai.qty then D:Add({ text = L.CODEX_AH_QTY, right = tostring(ai.qty) .. thin }) end
            if ai.age then
                local when = ai.age == 0 and L.CODEX_AH_TODAY or string.format(L.CODEX_AH_DAYS, ai.age)
                if ai.stale then when = "|cff9d9d9d" .. when .. " (" .. L.CODEX_AH_OLD .. ")|r" end
                D:Add({ text = L.CODEX_AH_AGE, right = when })
            end
            if ai.thin then D:Add({ style = "sub", text = L.CODEX_AH_THIN }) end
            local function Pct(v)
                local color = v > 0.005 and "|cff1eff00" or (v < -0.005 and "|cffff4040" or "|cff9d9d9d")
                return string.format("%s%+.0f %%|r", color, v * 100)
            end
            if ai.trend then D:Add({ text = L.CODEX_AH_TREND_DAY, right = Pct(ai.trend) }) end
            if ai.trendAll then D:Add({ text = L.CODEX_AH_TREND_ALL, right = Pct(ai.trendAll) }) end
            if ai.net then D:Add({ text = L.CODEX_AH_NET, right = FormatMoney(ai.net) }) end
            local info = Util.GetItem(itemID)
            local vendor = info and info.sellPrice or 0
            if vendor > 0 and ai.net then
                D:Add({ text = L.CODEX_AH_VENDOR_SELL, right = FormatMoney(vendor) })
                local diff = ai.net - vendor
                if diff > 0 then
                    D:Add({ text = L.CODEX_AH_SELL_AH, right = "|cff1eff00+" .. FormatMoney(diff) .. "|r" })
                else
                    D:Add({ text = L.CODEX_AH_SELL_VENDOR, right = "|cff9d9d9d+" .. FormatMoney(-diff) .. "|r" })
                end
            end
            local buy = LowestBuyPrices()[itemID]
            if buy and ai.net then
                D:Add({ text = L.CODEX_AH_VENDOR_BUY, right = FormatMoney(buy) })
                local margin = ai.net - buy
                if margin > 0 then
                    D:Add({ text = L.CODEX_AH_FLIP, right = "|cff1eff00+" .. FormatMoney(margin) .. " (" .. string.format("%+.0f %%", margin / buy * 100) .. ")|r" })
                else
                    D:Add({ text = L.CODEX_AH_FLIP, right = "|cffff4040-" .. FormatMoney(-margin) .. "|r" })
                end
            end
            D:Chart(ai.history)
        end

        -- Werte (Staerke, Beweglichkeit ...), vom Spiel gelesen
        local stats = Codex:GetStats(itemID)
        if stats and next(stats) then
            local keys = Codex:StatKeys({ itemID })
            D:Add({ style = "heading", text = L.CODEX_SEC_STATS })
            if stats._dmin and stats._dmax and stats._spd then
                D:Add({ style = "line", text = L.CODEX_WEAPON_DAMAGE,
                    right = string.format("%s - %s", Codex.FormatStat(stats._dmin), Codex.FormatStat(stats._dmax)) })
                D:Add({ style = "line", text = L.CODEX_WEAPON_SPEED, right = string.format("%.2f", stats._spd) })
            end
            for _, key in ipairs(keys) do
                D:Add({ style = "line", text = Codex.StatName(key), right = Codex.FormatStat(stats[key]) })
            end
        end

        local sources = {}
        for _, pair in ipairs({ { "units", Codex.V().units }, { "objects", Codex.V().objects } }) do
            for id, ent in pairs(pair[2]) do
                local chance, n, k = Codex.DropChance(ent, itemID, false)
                if chance then
                    sources[#sources + 1] = { kind = pair[1], id = id, ent = ent, chance = chance, n = n, k = k }
                end
            end
        end
        table.sort(sources, function(a, b)
            if a.chance ~= b.chance then return a.chance > b.chance end
            return a.k > b.k
        end)
        local value = ItemValueOf(itemID)
        if value and value > 0 then
            local ranked = {}
            for _, src in ipairs(sources) do
                local ttk = src.kind == "units" and UnitTTK(src.ent) or nil
                if ttk then
                    ranked[#ranked + 1] = { src = src, ttk = ttk, gph = src.chance * value / ttk * 3600 }
                end
            end
            table.sort(ranked, function(a, b) return a.gph > b.gph end)
            if #ranked > 0 then
                D:Add({ style = "heading", text = L.CODEX_SEC_BESTSRC })
                for i = 1, math.min(3, #ranked) do
                    local r = ranked[i]
                    EntityLink(r.src.kind, r.src.id, r.src.ent, string.format(L.CODEX_BESTSRC_ROW, FormatMoney(r.gph), r.ttk))
                end
                local top = ranked[1].src
                D:Add({ style = "link", text = L.CODEX_MAP_SHOW, icon = MAP_ICON,
                    onClick = function() Codex.Map:Show(Codex.CollectPoints({ kind = top.kind, id = top.id }), UnitTitle(top.ent, top.id, top.kind)) end })
            end
        end
        if #sources > 0 then
            D:Add({ style = "heading", text = L.CODEX_SEC_DROPS })
            for i, s in ipairs(sources) do
                if i > 40 then break end
                EntityLink(s.kind, s.id, s.ent, string.format(L.CODEX_DROP_CHANCE, FormatChance(s.chance), s.n, s.k))
            end
            local merged = {}
            for _, s in ipairs(sources) do
                Codex.AddCells(merged, s.ent.cells)
            end
            if next(merged) then
                D:Add({ style = "heading", text = L.CODEX_SEC_SPOTS })
                SpotRows(merged, 6)
                MapLink({ kind = "items", id = itemID }, Codex:ItemName(itemID) or ("#" .. itemID))
            end
        end

        -- Haendler laut eigenen und geteilten Beobachtungen (mit allen Preisen)
        local liveVendors = {}
        for vid, vent in pairs(Codex.V().units) do
            local w = vent.wa and vent.wa[itemID]
            if w then liveVendors[#liveVendors + 1] = { id = vid, ent = vent, w = w } end
        end
        for _, v in ipairs(liveVendors) do
            local low
            for price in pairs(v.w.pr or {}) do
                if not low or price < low then low = price end
            end
            v.low = low or 0
        end
        table.sort(liveVendors, function(a, b)
            if a.low ~= b.low then return a.low < b.low end
            return a.id < b.id
        end)
        local liveVendorSet = {}
        if #liveVendors > 0 then
            D:Add({ style = "heading", text = L.CODEX_SEC_SOLDBY_LIVE })
            for i, v in ipairs(liveVendors) do
                liveVendorSet[v.id] = true
                if i <= 30 then
                    local text = PriceText(v.w.pr, v.w.ec)
                    if i == 1 and #liveVendors > 1 then text = "|cff6fd66f" .. L.CODEX_CHEAPEST .. "|r  " .. (text or "") end
                    EntityLink("units", v.id, v.ent, text)
                end
            end
        end

        -- Quellen laut Vorlage (Vanilla): nur das, was wir selbst noch nicht gesehen haben
        local it = SeedOK() and Codex.Seed.Item(itemID) or nil
        if it then
            local liveSet = {}
            for _, src in ipairs(sources) do liveSet[src.kind .. src.id] = true end
            local rows = {}
            for _, def in ipairs({ { "units", it.u, 25 }, { "objects", it.o, 8 } }) do
                local n = 0
                for _, src in ipairs(def[2]) do
                    if not liveSet[def[1] .. src.id] and n < def[3] then
                        n = n + 1
                        rows[#rows + 1] = { kind = def[1], id = src.id, chance = src.chance }
                    end
                end
            end
            if #rows > 0 then
                D:Add({ style = "heading", text = L.CODEX_SEC_SRC_SEED })
                for _, r in ipairs(rows) do
                    EntityLink(r.kind, r.id, Codex.V()[r.kind][r.id], SeedPct(r.chance))
                end
            end
            if #it.v > 0 then
                D:Add({ style = "heading", text = L.CODEX_SEC_SOLDBY })
                local shownV = 0
                for _, vid in ipairs(it.v) do
                    if not liveVendorSet[vid] then
                        shownV = shownV + 1
                        if shownV > 20 then break end
                        EntityLink("units", vid, Codex.V().units[vid], nil)
                    end
                end
            end
            if #sources == 0 and #Codex.CollectPoints({ kind = "items", id = itemID }) > 0 then
                MapLink({ kind = "items", id = itemID }, Codex:ItemName(itemID) or ("#" .. itemID))
            end
        end

        local rewardOf, itemFor = {}, {}
        for qid, q in pairs(Codex.V().quests) do
            local found = false
            for _, r in ipairs(q.fixed or {}) do if r.id == itemID then found = true end end
            for _, r in ipairs(q.choice or {}) do if r.id == itemID then found = true end end
            if found then rewardOf[#rewardOf + 1] = qid end
            if q.qi and q.qi[itemID] then itemFor[#itemFor + 1] = qid end
        end
        for _, def in ipairs({ { rewardOf, L.CODEX_SEC_REWARDOF }, { itemFor, L.CODEX_SEC_QUESTITEM } }) do
            if #def[1] > 0 then
                D:Add({ style = "heading", text = def[2] })
                for i, qid in ipairs(def[1]) do
                    if i > 30 then break end
                    QuestLink(qid, Codex.V().quests[qid])
                end
            end
        end
    end

    function ShowDetail()
        UpdateFavUI()
        D:Reset()
        if selected then
            if kind == "quests" then ShowQuest(selected)
            elseif kind == "items" then ShowItem(selected)
            elseif kind == "xp" then ShowXP(selected)
            elseif kind == "learn" then ShowLearn(selected)
            elseif kind == "zones" then ShowZone(selected)
            else ShowEntity(kind, selected) end
        end
        D:Finish()
        detail:ScrollToTop()
    end

    ---------------- Liste ----------------
    local function FilterKey()
        local parts = {}
        for q in pairs(flt.q) do parts[#parts + 1] = "q" .. q end
        table.sort(parts)
        for _, k in ipairs({ "type", "sub", "slot", "src", "zone", "ilMin", "ilMax", "rlMin", "rlMax", "pMin", "pMax", "aMin", "aMax", "stat", "statMin", "statMax" }) do
            if flt[k] ~= nil then parts[#parts + 1] = k .. "=" .. tostring(flt[k]) end
        end
        for i = 1, MAX_STAT_ROWS do
            local r = flt.stats and flt.stats[i]
            if r and r.key then
                parts[#parts + 1] = string.format("s%d=%s:%s:%s:%s", i, r.key, tostring(r.min), tostring(r.max),
                    flt.ops and flt.ops[i] or "and")
            end
        end
        return table.concat(parts, ",")
    end

    -- Sortierwerte erst berechnen, wenn danach sortiert wird; fehlende Werte bleiben nil und stehen am Ende
    local function Enrich(entries, mode)
        local V = Codex.V()
        if kind == "units" or kind == "objects" then
            for _, e in ipairs(entries) do
                local u = V[kind][e.id]
                if mode == "ahkill" and kind == "units" then
                    local value = u and Codex.KillValue(u, true)
                    e.ahkill = value and value >= 0 and value or nil
                elseif mode == "ttk" or mode == "gpm" or mode == "gpmah" or mode == "xpm" then
                    local ttk = kind == "units" and UnitTTK(u) or nil
                    e.ttk = ttk
                    if ttk then
                        if mode == "gpm" or mode == "gpmah" then
                            local value = Codex.KillValue(u, mode == "gpmah")
                            e[mode] = value and value >= 0 and (value / ttk * 60) or nil
                        elseif mode == "xpm" then
                            local xp = UnitXPAvg(u)
                            e.xpm = xp and (xp / ttk * 60) or nil
                        end
                    end
                elseif mode == "data" then
                    e.data = u and ((u.k or 0) + (u.tt and 1 or 0)) or 0
                elseif mode == "lvl" then
                    local lv = u and u.l1
                    if not lv and SeedOK() then
                        local ent = Codex.Seed.Entity(kind, e.id)
                        lv = ent and ent.l1
                    end
                    e.lvl = lv
                end
            end
        elseif kind == "quests" then
            for _, e in ipairs(entries) do
                local q = V.quests[e.id]
                if mode == "lvl" then
                    e.lvl = q and q.lvl or nil
                elseif mode == "xp" then
                    e.xp = q and q.xp or nil
                elseif mode == "money" then
                    e.money = q and q.money or nil
                elseif mode == "qtime" then
                    e.qtime = q and q.tm and q.tm.n and q.tm.n > 0 and (q.tm.sum / q.tm.n / 10) or nil
                end
            end
        elseif kind == "items" then
            if mode == "buy" then
                local lowest = LowestBuyPrices()
                for _, e in ipairs(entries) do e.buy = lowest[e.id] end
            elseif mode == "flip" then
                -- Gewinn je Stueck: Auktion (netto nach Gebuehr) minus Einkauf beim Haendler
                local lowest = LowestBuyPrices()
                for _, e in ipairs(entries) do
                    local info = Codex.AuctionInfo and Codex.AuctionInfo(e.id)
                    local buy = lowest[e.id]
                    e.flip = info and info.net and buy and (info.net - buy) or nil
                end
            elseif mode == "ah" then
                for _, e in ipairs(entries) do
                    local v = Codex.AuctionProvider and Codex.AuctionPrice(e.id)
                    e.ah = v and v > 0 and v or nil
                end
            elseif mode == "gph" then
                local best = {}
                for _, u in pairs(V.units) do
                    local k = u.k or 0
                    local ttk = k > 0 and UnitTTK(u) or nil
                    if ttk then
                        for id, d in pairs(u.d or {}) do
                            local p = ItemValueOf(id)
                            if p and p > 0 then
                                local g = (d.q or d.n or 0) / k * p / ttk * 3600
                                if g > (best[id] or 0) then best[id] = g end
                            end
                        end
                    end
                end
                for _, e in ipairs(entries) do e.gph = best[e.id] end
            end
        end
        -- Sortierwert in der Zeile anzeigen
        local fmt = SORT_FORMAT[mode]
        local metric = SORT_METRIC[mode]
        for _, e in ipairs(entries) do
            e.baseSub = e.baseSub or e.sub
            local v = metric and e[metric]
            if fmt and v and v >= 0 and not (mode == "gold" or mode == "price") then
                local text
                if fmt == "money" then text = FormatMoney(v)
                elseif fmt == "secs" then text = string.format("%.1f s", v)
                else text = string.format("%.0f", v) end
                e.sub = (e.baseSub ~= "" and (e.baseSub .. "  |  ") or "") .. (L["CODEX_SORTBY_" .. mode] or mode) .. ": " .. text
            else
                e.sub = e.baseSub
            end
        end
    end

    local function Missing(v)
        return v == nil or v < 0 or v >= 1e9
    end

    local function SortedBase()
        local mode = CurrentSort()
        local seed = SeedOn()
        local role = roleSel[kind]
        local reverse = sortRev[kind] == true
        -- unveraendert (zum Beispiel beim Anklicken einer Zeile): die gemerkte Liste wiederverwenden
        local key = table.concat({ kind, search, mode, tostring(reverse), tostring(farmOn and kind == "units"), tostring(seed), tostring(role), tostring(chainSel), tostring(statusSel), tostring(zoneSel), tostring(learnSel), tostring(favOnly[kind]), FilterKey(), dataVersion }, "\1")
        -- Quest-Status aendert sich im Spiel laufend: mit Statusfilter immer neu aufbauen
        if memo.key == key and mode ~= "dist" and not statusSel then
            return memo.list
        end
        local entries = BuildEntries(kind, search, flt, { seed = seed, role = role, chain = chainSel, status = statusSel, zoneSel = zoneSel,
            class = kind == "learn" and EnsureLearnSel() or nil, fav = favOnly[kind] })
        local metric = SORT_METRIC[mode]
        if mode == "dist" then
            local Seed = Codex.Seed
            local loc = Util.GetPlayerLocation()   -- einmal lesen, nicht je Eintrag
            for _, e in ipairs(entries) do
                if kind == "quests" then
                    local q = Codex.V().quests[e.id]
                    local g = q and q.give
                    local d
                    if g and g.m and g.x and g.y and loc and loc.mapID == g.m and loc.x and loc.y then
                        d = math.sqrt((g.x - loc.x) ^ 2 + (g.y - loc.y) ^ 2)
                    end
                    e.dist = d or 1e9
                else
                    local live = Codex.V()[kind][e.id]
                    local d1 = live and live.cells and Seed.Distance(live.cells, loc)
                    local d2 = SeedOK() and Seed.Distance(Seed.Cells(kind, e.id), loc)
                    e.dist = math.min(d1 or 1e9, d2 or 1e9)
                end
            end
        end
        if farmOn and kind == "units" then
            local loc = Util.GetPlayerLocation()
            local zone = loc and loc.mapID and CachedMapName(loc.mapID)
            zone = zone and zone:lower() or nil
            local pl = UnitLevel and UnitLevel("player") or 1
            Enrich(entries, "gpm")
            local kept = {}
            for _, e in ipairs(entries) do
                if e.gpm and e.l1 and (e.l2 or e.l1) >= pl - 5 and e.l1 <= pl + 3 and (not zone or e.zone == zone) then
                    kept[#kept + 1] = e
                end
            end
            entries = kept
        end
        Enrich(entries, mode)
        local asc = SORT_ASC[mode] == true
        if reverse then asc = not asc end
        table.sort(entries, function(a, b)
            local va, vb
            if mode == "zone" then
                local za, zb = a.zone ~= "" and a.zone or "\255", b.zone ~= "" and b.zone or "\255"
                if za ~= zb then
                    if asc then return za < zb end
                    return za > zb
                end
                if a.name ~= b.name then return a.name < b.name end
                return a.id < b.id
            end
            if mode == "recent" then
                va, vb = a.recent, b.recent
            elseif mode == "dist" then
                va, vb = a.dist, b.dist
                local ma, mb = Missing(va), Missing(vb)
                if ma ~= mb then return mb end
                if ma then va, vb = 0, 0 end
            elseif metric then
                va, vb = a[metric], b[metric]
                local ma, mb = Missing(va), Missing(vb)
                if ma ~= mb then return mb end      -- fehlende Werte immer ans Ende
                if ma then va, vb = 0, 0 end
            end
            if va ~= nil and va ~= vb then
                if asc then return va < vb end
                return va > vb
            end
            if a.name ~= b.name then
                if mode == "name" then
                    if asc then return a.name < b.name end
                    return a.name > b.name
                end
                return a.name < b.name
            end
            return a.id < b.id
        end)
        memo.key, memo.list = key, entries
        return entries
    end

    -- Sortierung nach Gebiet: Kopfzeilen mit Zaehlern, einklappbar. Zaehler immer frisch (Questlog aendert sich).
    local function SortedEntries()
        local entries = SortedBase()
        if kind ~= "quests" or CurrentSort() ~= "zone" then return entries end
        local L = FW.L
        local out, i = {}, 1
        while i <= #entries do
            local zone = entries[i].zone or ""
            local j, open, active, done = i, 0, 0, 0
            while j <= #entries and (entries[j].zone or "") == zone do
                local st = Codex.QuestStatus(entries[j].id)
                if st == "done" then done = done + 1 elseif st == "active" then active = active + 1 else open = open + 1 end
                j = j + 1
            end
            local count = j - i
            local name = entries[i].zoneName or L.CODEX_ZONE_UNKNOWN
            local closed = collapsed[zone] == true
            out[#out + 1] = { header = zone, id = "zone:" .. zone, title = string.format("%s (%d)", name, count),
                sub = string.format(L.CODEX_GROUP_ROW, open, active, done), icon = closed and ICON.plus or ICON.minus,
                name = "", zone = zone }
            if not closed then
                for k = i, j - 1 do out[#out + 1] = entries[k] end
            end
            i = j
        end
        return out
    end

    -- Kreatur-Bilder in der Liste: 2D-Portrait aus der gespeicherten Display-ID.
    -- Kreaturen ohne ID zeigen das Symbol; ein einziges unsichtbares Modell holt die IDs
    -- der sichtbaren Zeilen nach und zwar eine nach der anderen.
    local resolver = CreateFrame("PlayerModel", nil, f)
    resolver:SetSize(8, 8)
    resolver:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 0, 0)
    resolver:SetAlpha(0)
    local resolverBusy, resolverTries = false, {}
    local UpdateRowIcons

    local function ReadDisplayID(model)
        local ok, id = pcall(function() return model.GetDisplayInfo and model:GetDisplayInfo() end)
        if ok and type(id) == "number" and id > 0 then return id end
        return nil
    end

    local function ResolveNext()
        if resolverBusy then return end
        local sf = listScroll.scroll
        local top = sf:GetVerticalScroll() or 0
        local bottom = top + (sf:GetHeight() or 0)
        local pick
        for i, row in ipairs(listRows) do
            local npc = row.unitID
            if npc and row:IsShown() and not Codex:GetDisplayID(npc) and not resolverTries[npc] then
                local y = (i - 1) * (ROW_H + ROW_GAP)
                if y + ROW_H >= top and y <= bottom then pick = npc break end
            end
        end
        if not pick then return end
        resolverTries[pick] = true
        resolverBusy = true
        pcall(function()
            resolver:ClearModel()
            resolver:SetCreature(pick)
        end)
        local function Finish()
            local d = ReadDisplayID(resolver)
            if d then
                Codex.dispStats.read = Codex.dispStats.read + 1
                if Codex:SetDisplayID(pick, d) then UpdateRowIcons() end
            else
                Codex.dispStats.fail = Codex.dispStats.fail + 1
            end
            resolverBusy = false
            C_Timer.After(0.05, ResolveNext)
        end
        C_Timer.After(0.35, Finish)
    end

    function UpdateRowIcons()
        for _, row in ipairs(listRows) do
            if row:IsShown() and row.unitID then
                local d = Codex:GetDisplayID(row.unitID)
                if d and row.dispShown ~= d then
                    local ok = pcall(SetPortraitTextureFromCreatureDisplayID, row.icon, d)
                    if ok then
                        row.icon:SetTexCoord(0, 1, 0, 1)
                        row.dispShown = d
                        Codex.dispStats.shown = Codex.dispStats.shown + 1
                    end
                end
            end
        end
    end

    local function UpdateRowModels()
        UpdateRowIcons()
        ResolveNext()
    end
    f.UpdateRowModels = UpdateRowModels
    if listScroll.scroll.HookScript then
        listScroll.scroll:HookScript("OnVerticalScroll", function() UpdateRowModels() end)
    end

    function RefreshList()
        if kind == "items" or kind == "units" or kind == "objects" then
            local _, ids = ItemIndex()
            Codex:LoadItemInfo(ids)
            if kind == "items" then Codex:CaptureStats(ids) end
        end
        local entries = SortedEntries()
        local total = #entries
        local headers = 0
        if kind == "quests" and CurrentSort() == "zone" then
            for _, e in ipairs(entries) do
                if e.header then headers = headers + 1 end
            end
        end
        local shown = math.min(total, MAX_ROWS)
        for i = 1, shown do
            local e = entries[i]
            local row = listRows[i]
            if not row then
                row = UI.CreatePanel(listScroll.child, "card", "bronze")
                row:SetHeight(ROW_H)
                row:EnableMouse(true)
                row.icon = row:CreateTexture(nil, "ARTWORK")
                row.icon:SetSize(30, 30)
                row.icon:SetPoint("LEFT", row, "LEFT", 7, 0)
                row.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
                row.title = UI.CreateLabel(row, "", { size = 12 })
                row.title:SetPoint("TOPLEFT", row, "TOPLEFT", 46, -7)
                row.title:SetPoint("TOPRIGHT", row, "TOPRIGHT", -8, -7)
                row.title:SetWordWrap(false)
                row.sub = UI.CreateLabel(row, "", { size = 10, color = "textDim" })
                row.sub:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", 46, 7)
                row.sub:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", -8, 7)
                row.sub:SetWordWrap(false)
                -- Quest-Status rechts: Haken (erledigt) oder Sprint-Symbol (in Arbeit)
                row.mark = row:CreateTexture(nil, "OVERLAY")
                row.mark:SetSize(18, 18)
                row.mark:SetPoint("RIGHT", row, "RIGHT", -8, 0)
                row.mark:Hide()
                row.fav = row:CreateTexture(nil, "OVERLAY")
                row.fav:SetTexture("Interface\\TargetingFrame\\UI-RaidTargetingIcon_1")
                row.fav:SetSize(14, 14)
                row.fav:Hide()
                row:SetScript("OnMouseUp", function(self)
                    if self.headerKey then
                        collapsed[self.headerKey] = not collapsed[self.headerKey]
                        RefreshList()
                        return
                    end
                    selected = self.entryID
                    RefreshList()
                    ShowDetail()
                    if nameCtl then nameCtl.Update() end
                end)
                row:SetScript("OnEnter", function(self)
                    UI.SetBorderColor(self, "gold")
                    if self.itemID and GameTooltip then
                        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                        local ok = pcall(GameTooltip.SetItemByID, GameTooltip, self.itemID)
                        if not ok then pcall(GameTooltip.SetHyperlink, GameTooltip, "item:" .. self.itemID) end
                        GameTooltip:Show()
                    end
                end)
                row:SetScript("OnLeave", function(self)
                    UI.SetBorderColor(self, (self.entryID == selected or self.headerKey) and "gold" or "bronze")
                    if GameTooltip then GameTooltip:Hide() end
                end)
                listRows[i] = row
            end
            row.entryID = e.id
            row.headerKey = e.header
            row.itemID = e.itemID
            row.unitID = e.unitID
            row.dispShown = nil
            row:ClearAllPoints()
            local y = (i - 1) * (ROW_H + ROW_GAP)
            row:SetPoint("TOPLEFT", listScroll.child, "TOPLEFT", 0, -y)
            row:SetPoint("TOPRIGHT", listScroll.child, "TOPRIGHT", 0, -y)
            row.title:SetText(e.header and ("|cffffd100" .. e.title .. "|r") or e.title)
            row.sub:SetText(e.sub or "")
            local mark = (kind == "quests" and not e.header) and STATUS_MARK[Codex.QuestStatus(e.id) or ""] or nil
            row.markState = mark
            local isFav = (not e.header) and Codex.FavSupported(kind) and Codex.IsFav(kind, e.id)
            row.fav:ClearAllPoints()
            row.fav:SetPoint("RIGHT", row, "RIGHT", mark and -30 or -8, 0)
            row.fav:SetShown(isFav and true or false)
            local rightGap = (mark and 32 or 8) + (isFav and 18 or 0)
            row.title:ClearAllPoints()
            row.title:SetPoint("TOPLEFT", row, "TOPLEFT", 46, -7)
            row.title:SetPoint("TOPRIGHT", row, "TOPRIGHT", -rightGap, -7)
            row.sub:ClearAllPoints()
            row.sub:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", 46, 7)
            row.sub:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", -rightGap, 7)
            if mark then
                row.mark:SetTexture(mark)
                row.mark:SetTexCoord(0.08, 0.92, 0.08, 0.92)
                row.mark:Show()
            else
                row.mark:Hide()
            end
            row.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
            if e.itemID then
                row.icon:SetTexture(ICON.items)
                local q = Codex.QualityOf(e.itemID)
                if q then row.title:SetText(Colored(e.title, q)) end
                Util.RequestItem(e.itemID, function(info)
                    if row.entryID == e.itemID and info then
                        Codex.RememberQuality(e.itemID, info.quality)
                        row.icon:SetTexture(info.icon)
                        row.title:SetText(Colored(info.name, info.quality))
                    end
                end)
            else
                row.icon:SetTexture(e.icon)
                row.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
            end
            UI.SetBorderColor(row, (e.id == selected or e.header) and "gold" or "bronze")
            if e.header then row.icon:SetTexCoord(0, 1, 0, 1) end
            row:Show()
        end
        for i = shown + 1, #listRows do
            listRows[i]:Hide()
        end
        listScroll:SetContentHeight(shown * (ROW_H + ROW_GAP))
        UpdateRowModels()

        local q, u, o = Codex:Counts()
        if total == 0 then
            listEmpty:SetText(kind == "learn" and #Codex.LearnClasses() == 0 and L.CODEX_LEARN_EMPTY
                or (q + u + o) == 0 and L.CODEX_EMPTY or L.CODEX_NO_MATCH)
            listEmpty:Show()
            countLabel:SetText("")
        else
            listEmpty:Hide()
            local text = total > shown and string.format(L.CODEX_COUNT_MORE, total - headers, shown - headers) or string.format(L.CODEX_COUNT, total - headers)
            local pending = Codex.runtime.pendingInfo or 0
            if pending > 0 and kind == "items" then
                text = text .. "  |  " .. string.format(L.CODEX_LOADING_ITEMS, pending)
            end
            countLabel:SetText(text)
        end
    end

    function Refresh()
        LayoutKinds()
        for id, b in pairs(kindButtons) do
            b:SetStyle(id == kind and "primary" or "default")
        end
        if #history > 0 then backButton:Show() else backButton:Hide() end
        sortDD:SetValue(CurrentSort())
        local asc = SORT_ASC[CurrentSort()] == true
        if sortRev[kind] then asc = not asc end
        dirButton.arrow:SetTexCoord(0, 1, asc and 1 or 0, asc and 0 or 1)
        Layout()
        UpdateFilterUI()
        RefreshList()
        ShowDetail()
        if nameCtl then nameCtl.Update() end
    end

    function Go(newKind, id)
        if selected ~= nil and (kind ~= newKind or selected ~= id) then
            history[#history + 1] = { kind = kind, id = selected }
            if #history > 30 then table.remove(history, 1) end
        end
        kind, selected = newKind, id
        edit:SetText("")
        edit:ClearFocus()
        Refresh()
    end

    f.Refresh = function()
        dirty = true
        dataVersion = dataVersion + 1
        Refresh()
    end
    f.Go = Go
    -- fuer Tests
    f.Entries = SortedEntries
    f.SetFilter = function(t)
        flt = t or {}
        flt.q = flt.q or {}
        Refresh()
    end
    f.SetSort = function(mode, reverse)
        sortBy[kind] = mode
        sortRev[kind] = reverse == true
        Refresh()
    end
    f.ToggleZone = function(zone) collapsed[zone] = not collapsed[zone]; Refresh() end
    f.ToggleRoute = function() routeOpen = not routeOpen; RouteSync(); Layout(); return routeOpen end
    f.RouteLevels = function() return routeLvl, routeOpen end
    f.SetRouteRange = function(on)
        if on then routeLvl.below, routeLvl.above = 3, 3 else routeLvl.below, routeLvl.above = nil, nil end
        RouteSync()
    end
    f.SetFarm = function(on)
        farmOn = on and true or false
        if farmOn then roleSel.units, sortBy.units, sortRev.units = "combat", "gpm", false end
        Refresh()
    end
    f.Back = function()
        local prev = table.remove(history)
        if prev then
            kind, selected = prev.kind, prev.id
            Refresh()
        end
        return prev ~= nil
    end
    f.HistoryCount = function() return #history end
    f.SetLearnClass = function(token) learnSel = token; selected = nil; dataVersion = dataVersion + 1; Refresh() end
    f.SetFavOnly = function(on) favOnly[kind] = on and true or false; dataVersion = dataVersion + 1; Refresh() end
    f.Kind = function() return kind end
    f.SetRole = function(role)
        roleSel[kind] = role
        Refresh()
    end
    f.FilterText = function() return StatPreview(flt) end
    f.SetStatus = function(status)
        statusSel = status
        Refresh()
    end
    f.SetChain = function(chain)
        chainSel = chain
        Refresh()
    end
    f.SetSearch = function(text)
        search = text or ""
        Refresh()
    end
    -- Text der angezeigten Detail-Zeilen (links | rechts), fuer Tests
    f.DetailText = function()
        local t = {}
        for i = 1, D.used do
            t[#t + 1] = (detailRows[i].left:GetText() or "") .. "|" .. (detailRows[i].right:GetText() or "")
        end
        return table.concat(t, "\n")
    end

    FW:On("CODEX_CHANGED", function()
        dirty = true
        dataVersion = dataVersion + 1
        if f:IsShown() then
            RefreshList()
        end
    end, f)
    FW:On("CODEX_ITEMS_LOADED", function()
        dataVersion = dataVersion + 1
        if f:IsShown() and (kind == "items" or kind == "units" or kind == "objects") then
            RefreshList()
            if (kind == "units" or kind == "objects") and selected and detailMissing then
                ShowDetail()
            end
        end
    end, f)

    return f
end

local built
UI:RegisterTab("codex", {
    label = function()
        return FW.L.CODEX_TAB
    end,
    order = 60,
    build = function(content)
        built = Build(content)
        Codex.ui = built
        return built
    end,
    onShow = function(f)
        f.Refresh()
    end,
})

------------------------------------------------------------------------
-- /fwcodex near <rolle>: naechste Haendler, Flugmeister ... auf dieser Karte (Vorlage)
------------------------------------------------------------------------

local NEAR_WORDS = {
    { "vendor", "haendler", "händler", "vendor", "shop" }, { "repair", "repair", "reparatur", "rep" },
    { "flight", "flug", "flight", "fm" }, { "innkeeper", "gast", "inn", "wirt" },
    { "stablemaster", "stall", "stable" }, { "banker", "bank" }, { "auctioneer", "auktion", "auction", "ah" },
    { "mailbox", "post", "mail", "brief" }, { "spirithealer", "geist", "spirit", "heiler" },
}

function Codex.Near(word)
    local L = FW.L
    word = (word or ""):lower()
    local role
    for _, def in ipairs(NEAR_WORDS) do
        for i = 2, #def do
            if word == def[i] then role = def[1] end
        end
    end
    if not role then
        FW:Print(L.CODEX_NEAR_HELP)
        return
    end
    local list = Codex.Seed.Available() and Codex.Seed.Nearest(role, 5) or {}
    if #list == 0 then
        FW:Print(L.CODEX_NEAR_NONE)
        return
    end
    FW:Print(string.format(L.CODEX_NEAR_HEAD, L["CODEX_ROLE_" .. role] or role))
    local points = {}
    for _, e in ipairs(list) do
        local name = (Codex.NameOf(Codex.V()[e.kind][e.id])) or Codex.Seed.Name(e.kind, e.id) or ("#" .. e.id)
        FW:Print(string.format(L.CODEX_NEAR_ROW, name, e.x * 100, e.y * 100))
        points[#points + 1] = { m = e.m, x = e.x, y = e.y, n = 4, pin = true, name = name }
    end
    if Codex.Map and Codex.Map.Show then
        Codex.Map:Show(points, L["CODEX_ROLE_" .. role] or role)
    end
end

------------------------------------------------------------------------
-- Befehl
------------------------------------------------------------------------

SLASH_FREEWOODCODEX1 = "/fwcodex"
SlashCmdList["FREEWOODCODEX"] = function(msg)
    msg = (msg or ""):lower():match("^%s*(.-)%s*$")
    if msg == "test" then
        Codex:RunTest()
    elseif msg == "share log" then
        if Codex.Sync then Codex.Sync:SetLog(not Codex.Sync.state.log) end
    elseif msg == "share on" or msg == "share off" then
        if Codex.Sync then
            Codex.Sync:SetEnabled(msg == "share on")
            Codex.Sync:Debug()
        end
    elseif msg == "share" then
        if Codex.Sync then Codex.Sync:Debug() end
    elseif msg == "time" then
        if Codex.Time then Codex.Time:Debug() end
    elseif msg == "icons" then
        local st = Codex.dispStats
        local n = 0
        for _ in pairs(Codex.db.disp or {}) do n = n + 1 end
        FW:Print(string.format("Kreatur-Bilder: %d Display-IDs gespeichert, gelesen %d, nicht lesbar %d, in der Liste gesetzt %d", n, st.read, st.fail, st.shown))
    elseif msg == "seed" then
        if Codex.Seed and Codex.Seed.Available() then
            FW:Print(string.format(FW.L.CODEX_SEED_STATUS, Codex.Seed.Count()))
        else
            FW:Print(FW.L.CODEX_SEED_MISSING)
        end
    elseif msg == "roles" then
        Codex.Roles:Debug()
    elseif msg == "trainers" then
        -- Diagnose Lernplan: alle erfassten Lehrer mit Titel, Klasse und Anzahl Zauber
        local n = 0
        for id, u in pairs(Codex.V().units) do
            if u.ro and ((u.ro.classtrainer or 0) > 0 or (u.ro.proftrainer or 0) > 0) then
                n = n + 1
                local cnt = 0
                for _ in pairs(u.tr or {}) do cnt = cnt + 1 end
                FW:Print(string.format("#%d %s | Titel: %s | Klasse: %s (Titel: %s, Spieler: %s) | Zauber: %d | Rolle: %s", id, tostring(u.n), tostring(u.ti),
                    tostring(Codex.ClassOfTrainer(u)), tostring(Codex.ClassOfTitle(u.ti)), tostring(u.trc), cnt, (u.ro.classtrainer or 0) > 0 and "Klasse" or "Beruf"))
            end
        end
        FW:Print(n .. " Lehrer erfasst.")
    elseif msg:find("^weapon") then
        local id = tonumber(msg:match("item:(%d+)")) or tonumber(msg:match("(%d+)"))
        if id then Codex.WeaponDebug(id) else FW:Print("/fwcodex weapon <Item-ID oder Link>") end
    elseif msg:find("^near") then
        Codex.Near(msg:match("^near%s*(.-)$"))
    elseif msg == "names" then
        if Codex.Names then Codex.Names:Debug() end
    elseif msg == "map" then
        Codex.Map:Debug()
    elseif msg == "map test" then
        Codex.Map:Test()
    elseif msg == "map square" then
        Codex.Map:ToggleSquare()
    else
        UI:Toggle("codex")
    end
end
