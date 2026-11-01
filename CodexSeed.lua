-- Freewood-Codex: Vorlage (Startdaten aus Freewood-CodexData, Vanilla)
-- Das Datenaddon ist "LoadOnDemand" und wird erst beim ersten Zugriff geladen. Alles hier ist nur eine Vorlage:
-- eigene und geteilte Live-Daten gehen immer vor. Die Daten liegen als kurze Zeichenketten vor und werden erst
-- beim Zugriff entpackt (und gemerkt).
--
-- Formate (siehe tools/pf2seed.lua):
--   Quest   "Stufe|Mindeststufe|Rassen|Klassen|Beruf|Vorquests|Start|Abgabe|Ziele"   (Refs: "U123.O55.I6497")
--   Kreatur "Stufe|Fraktion|Rang|Gebiet:Zelle,Zelle;Gebiet:Zelle"                      (Zelle = x*100+y in 1 %)
--   Item    "u<id>=<Chance %>,...;o<id>=<Chance>,...;v<haendlerID>,..."
--   Rollen  meta[rolle] = "id:wert,id:wert"  (negative IDs sind Objekte)

local ADDON, NS = ...

local FW = _G.Freewood
local Codex = NS.Codex
if not FW or not Codex then
    return
end

local Util = FW.Util
local GRID = Codex.GRID

local Seed = {}
Codex.Seed = Seed

local DATA_ADDON = "Freewood-CodexData"
local S            -- FreewoodCodexSeed, sobald geladen
local failed = false

local floor = math.floor

-- Rollen: Reihenfolge der Anzeige
Seed.ROLES = {
    units = { "vendor", "repair", "flight", "innkeeper", "stablemaster", "spirithealer", "auctioneer", "battlemaster", "banker", "rares" },
    objects = { "mailbox", "meetingstone", "chests", "herbs", "mines", "fish" },
}

------------------------------------------------------------------------
-- Laden
------------------------------------------------------------------------

function Seed.Load()
    if S then
        return true
    end
    if failed then
        return false
    end
    local g = _G.FreewoodCodexSeed
    if not (g and g.ready) then
        local load = (C_AddOns and C_AddOns.LoadAddOn) or LoadAddOn
        if type(load) == "function" then
            pcall(load, DATA_ADDON)
        end
        g = _G.FreewoodCodexSeed
    end
    if g and g.ready then
        S = g
        return true
    end
    failed = true
    return false
end

-- Laedt bei Bedarf (nur die Oberflaeche ruft das auf, damit der Ladevorgang beim Oeffnen des Tabs geschieht)
function Seed.Disabled()
    local db = Codex.db
    return db and db.settings and db.settings.noSeed == true or false
end

function Seed.Available()
    if Seed.Disabled() then return false end
    return Seed.Load()
end

-- Nur pruefen, ob schon geladen ist, ohne zu laden (fuer Code, der waehrend des Spielens laeuft)
function Seed.Ready()
    return S ~= nil and not Seed.Disabled()
end

-- fuer Tests: Zustand zuruecksetzen
local caches
function Seed.Reset()
    S, failed = nil, false
    caches = { quest = {}, unit = {}, object = {}, item = {}, lists = {}, hay = {} }
    Seed.nextIdx, Seed.rev, Seed.roleIdx, Seed.areaMap = nil, nil, nil, nil
end
Seed.Reset()

local function Lang()
    return Codex.Lang()
end

------------------------------------------------------------------------
-- Kleine Helfer
------------------------------------------------------------------------

local function Fields(s, n)
    local out, pos = {}, 1
    for i = 1, n do
        local e = s:find("|", pos, true)
        if e then
            out[i] = s:sub(pos, e - 1)
            pos = e + 1
        else
            out[i] = s:sub(pos)
            pos = #s + 2
        end
    end
    return out
end

local function Nums(s)
    local list = {}
    for n in (s or ""):gmatch("%d+") do
        list[#list + 1] = tonumber(n)
    end
    return list
end

local KIND_OF = { U = "units", O = "objects", I = "items" }

local function Refs(s)
    local list = {}
    for k, id in (s or ""):gmatch("(%a)(%d+)") do
        list[#list + 1] = { kind = KIND_OF[k], id = tonumber(id) }
    end
    return list
end

local function AreaMap()
    if Seed.areaMap then
        return Seed.areaMap
    end
    local map = {}
    for a, m in (S.areas or ""):gmatch("(%d+)=(%d+)") do
        map[tonumber(a)] = tonumber(m)
    end
    Seed.areaMap = map
    return map
end

local function Pick(de, en)
    if Lang() == "en" then
        return en or de
    end
    return de or en
end

------------------------------------------------------------------------
-- Quests
------------------------------------------------------------------------

function Seed.Quest(id)
    local c = caches.quest[id]
    if c ~= nil then
        return c or nil
    end
    if not Seed.Load() then
        return nil
    end
    local s = S.q[id]
    if not s then
        caches.quest[id] = false
        return nil
    end
    local f = Fields(s, 9)
    local q = {
        id = id, lvl = tonumber(f[1]), min = tonumber(f[2]), race = tonumber(f[3]), class = tonumber(f[4]),
        skill = tonumber(f[5]), pre = Nums(f[6]), start = Refs(f[7]), stop = Refs(f[8]), obj = Refs(f[9]),
    }
    caches.quest[id] = q
    return q
end

function Seed.QuestTitle(id)
    if not Seed.Load() then
        return nil
    end
    return Pick(S.qd[id], S.qe[id])
end

-- Folgequests: alle Quests, die diese als Vorquest haben
function Seed.NextQuests(id)
    if not Seed.Load() then
        return {}
    end
    if not Seed.nextIdx then
        local idx = {}
        for qid, s in pairs(S.q) do
            local pre = Fields(s, 6)[6]
            for p in pre:gmatch("%d+") do
                local n = tonumber(p)
                local l = idx[n]
                if not l then
                    l = {}
                    idx[n] = l
                end
                l[#l + 1] = qid
            end
        end
        for _, l in pairs(idx) do
            table.sort(l)
        end
        Seed.nextIdx = idx
    end
    return Seed.nextIdx[id] or {}
end

-- Position in der Questkette: pos, total (zum Beispiel 2, 4), nil ausserhalb einer Kette.
-- Bei Verzweigungen zaehlt der laengste Weg vor und nach der Quest.
local chainMemo = {}
local function ChainLen(id, dir, depth)
    local key = dir .. id
    local c = chainMemo[key]
    if c then
        return c
    end
    if depth > 40 then
        return 1
    end
    local best = 0
    local list
    if dir == "u" then
        local q = Seed.Quest(id)
        list = q and q.pre or {}
    else
        list = Seed.NextQuests(id)
    end
    for _, other in ipairs(list) do
        if other ~= id then
            best = math.max(best, ChainLen(other, dir, depth + 1))
        end
    end
    chainMemo[key] = best + 1
    return best + 1
end

function Seed.ChainPos(id)
    if not Seed.Quest(id) then
        return nil
    end
    local up, down = ChainLen(id, "u", 0), ChainLen(id, "d", 0)
    if up + down <= 2 then
        return nil
    end
    return up, up + down - 1
end

-- Stellung in einer Questkette: "start" (hat Folgequests, keine Vorquest), "mid", "end" (nur Vorquests)
-- oder nil (gehoert zu keiner Kette)
function Seed.ChainRole(id)
    local q = Seed.Quest(id)
    if not q then
        return nil
    end
    -- manche Quests nennen sich selbst als Vorquest: das zaehlt nicht als Kette
    local hasPre, hasNext = false, false
    for _, p in ipairs(q.pre or {}) do
        if p ~= id then hasPre = true break end
    end
    for _, n in ipairs(Seed.NextQuests(id)) do
        if n ~= id then hasNext = true break end
    end
    if hasPre and hasNext then return "mid" end
    if hasNext then return "start" end
    if hasPre then return "end" end
    return nil
end

------------------------------------------------------------------------
-- Kreaturen und Objekte
------------------------------------------------------------------------

local function EntityData(kind)
    return kind == "units" and S.u or S.o
end

-- Rueckgabe: { id, l1, l2, fac, rank, spots, cells }
function Seed.Entity(kind, id)
    local cache = kind == "units" and caches.unit or caches.object
    local c = cache[id]
    if c ~= nil then
        return c or nil
    end
    if not Seed.Load() then
        return nil
    end
    local s = EntityData(kind)[id]
    if not s then
        cache[id] = false
        return nil
    end
    local f = Fields(s, 4)
    local l1, l2 = f[1]:match("^(%d+)%-?(%d*)$")
    if l1 and l2 == "" then
        l2 = l1
    end
    local e = {
        id = id, l1 = tonumber(l1), l2 = tonumber(l2), fac = f[2] ~= "" and f[2] or nil,
        rank = tonumber(f[3]), spots = f[4],
    }
    cache[id] = e
    return e
end

function Seed.Name(kind, id)
    if not Seed.Load() then
        return nil
    end
    if kind == "units" then
        return Pick(S.ud[id], S.ue[id])
    elseif kind == "objects" then
        return Pick(S.od[id], S.oe[id])
    elseif kind == "items" then
        return Pick(S.id[id], S.ie[id])
    end
    return nil
end

-- Zellen wie im Codex: { [Karte*GRID^2 + y*GRID + x] = 1 }
function Seed.Cells(kind, id)
    local e = Seed.Entity(kind, id)
    if not e then
        return {}
    end
    if e.cells then
        return e.cells
    end
    local cells = {}
    local areas = AreaMap()
    for area, list in e.spots:gmatch("(%d+):([%d,]+)") do
        local m = areas[tonumber(area)]
        if m then
            for c in list:gmatch("%d+") do
                c = tonumber(c)
                local cx = math.min(GRID - 1, floor(c / 100) * 2 + 1)
                local cy = math.min(GRID - 1, (c % 100) * 2 + 1)
                cells[m * GRID * GRID + cy * GRID + cx] = 1
            end
        end
    end
    e.cells = cells
    return cells
end

-- Erste Fundstelle: Karte, x, y (Anteile 0..1)
function Seed.FirstSpot(kind, id)
    local e = Seed.Entity(kind, id)
    if not e then
        return nil
    end
    local area, list = e.spots:match("(%d+):([%d,]+)")
    local m = area and AreaMap()[tonumber(area)]
    local c = list and tonumber(list:match("%d+"))
    if not (m and c) then
        return nil
    end
    return m, (floor(c / 100) + 0.5) / 100, ((c % 100) + 0.5) / 100
end

-- Gebiet einer Kreatur / eines Objekts (Karten-ID der ersten Fundstelle)
function Seed.MapOf(kind, id)
    local m = Seed.FirstSpot(kind, id)
    return m
end

-- Kleinster Abstand (Kartenanteil) einer Zellenmenge zum Spieler auf der aktuellen Karte, sonst nil
function Seed.Distance(cells, loc)
    loc = loc or (Util.GetPlayerLocation and Util.GetPlayerLocation())
    if not (loc and loc.mapID and loc.x and loc.y) then
        return nil
    end
    local best
    local g2 = GRID * GRID
    for key in pairs(cells or {}) do
        if floor(key / g2) == loc.mapID then
            local idx = key % g2
            local dx = ((idx % GRID) + 0.5) / GRID - loc.x
            local dy = (floor(idx / GRID) + 0.5) / GRID - loc.y
            local d = dx * dx + dy * dy
            if not best or d < best then
                best = d
            end
        end
    end
    return best and math.sqrt(best) or nil
end

------------------------------------------------------------------------
-- Items: Quellen
------------------------------------------------------------------------

-- Rueckgabe: { u = { { id, chance } }, o = { { id, chance } }, v = { haendlerID } }
function Seed.Item(id)
    local c = caches.item[id]
    if c ~= nil then
        return c or nil
    end
    if not Seed.Load() then
        return nil
    end
    local s = S.i[id]
    if not s then
        caches.item[id] = false
        return nil
    end
    local it = { u = {}, o = {}, v = {} }
    for part in s:gmatch("[^;]+") do
        local tag, body = part:sub(1, 1), part:sub(2)
        if tag == "u" or tag == "o" then
            for k, v in body:gmatch("(%d+)=([%d%.]+)") do
                local t = it[tag]
                t[#t + 1] = { id = tonumber(k), chance = tonumber(v) }
            end
        elseif tag == "v" then
            it.v = Nums(body)
        end
    end
    caches.item[id] = it
    return it
end

function Seed.ItemHasVendor(id)
    if not Seed.Load() then
        return false
    end
    local s = S.i[id]
    return s ~= nil and (s:find(";v", 1, true) ~= nil or s:sub(1, 1) == "v")
end

local function Reverse()
    if Seed.rev then
        return Seed.rev
    end
    -- flache Listen { Item, Chance, Item, Chance ... } sparen Speicher
    local rev = { u = {}, o = {}, v = {} }
    for itemID, s in pairs(S.i) do
        for part in s:gmatch("[^;]+") do
            local tag, body = part:sub(1, 1), part:sub(2)
            if tag == "u" or tag == "o" then
                local t = rev[tag]
                for k, v in body:gmatch("(%d+)=([%d%.]+)") do
                    local key = tonumber(k)
                    local l = t[key]
                    if not l then
                        l = {}
                        t[key] = l
                    end
                    l[#l + 1] = itemID
                    l[#l + 1] = tonumber(v)
                end
            elseif tag == "v" then
                for n in body:gmatch("%d+") do
                    local key = tonumber(n)
                    local l = rev.v[key]
                    if not l then
                        l = {}
                        rev.v[key] = l
                    end
                    l[#l + 1] = itemID
                end
            end
        end
    end
    Seed.rev = rev
    return rev
end

-- Beute einer Kreatur / eines Objekts laut Vorlage: { { item, chance (Prozent) } }, nach Chance sortiert
function Seed.Drops(kind, id)
    if not Seed.Load() then
        return {}
    end
    local flat = Reverse()[kind == "units" and "u" or "o"][id]
    local list = {}
    for i = 1, #(flat or {}), 2 do
        list[#list + 1] = { item = flat[i], chance = flat[i + 1] }
    end
    table.sort(list, function(a, b)
        if a.chance ~= b.chance then return a.chance > b.chance end
        return a.item < b.item
    end)
    return list
end

-- Waren eines Haendlers: { itemID }
function Seed.VendorItems(id)
    if not Seed.Load() then
        return {}
    end
    local list = {}
    for i, itemID in ipairs(Reverse().v[id] or {}) do
        list[i] = itemID
    end
    table.sort(list)
    return list
end

------------------------------------------------------------------------
-- Quests je Kreatur / Objekt (Geber, Abgabe, Ziel)
------------------------------------------------------------------------

function Seed.QuestsOf(kind, id)
    if not Seed.Load() then
        return {}, {}, {}
    end
    if not Seed.questRev then
        local rev = { give = {}, turn = {}, target = {} }
        local function Add(t, key, qid)
            local l = t[key]
            if not l then
                l = {}
                t[key] = l
            end
            if l[#l] ~= qid then
                l[#l + 1] = qid
            end
        end
        for qid in pairs(S.q) do
            local q = Seed.Quest(qid)
            for _, r in ipairs(q.start) do
                if r.kind ~= "items" then Add(rev.give, r.kind .. r.id, qid) end
            end
            for _, r in ipairs(q.stop) do
                if r.kind ~= "items" then Add(rev.turn, r.kind .. r.id, qid) end
            end
            for _, r in ipairs(q.obj) do
                if r.kind ~= "items" then Add(rev.target, r.kind .. r.id, qid) end
            end
        end
        Seed.questRev = rev
    end
    local key = kind .. id
    local rev = Seed.questRev
    return rev.give[key] or {}, rev.turn[key] or {}, rev.target[key] or {}
end

------------------------------------------------------------------------
-- Rollen (Haendler, Flugmeister ...)
------------------------------------------------------------------------

local function RoleIndex()
    if Seed.roleIdx then
        return Seed.roleIdx
    end
    local idx = { units = {}, objects = {}, ids = {} }
    for _, group in ipairs({ Seed.ROLES.units, Seed.ROLES.objects }) do
        for _, role in ipairs(group) do
            local list = {}
            for k, v in (S.meta[role] or ""):gmatch("(%-?%d+):([^,]*)") do
                local n = tonumber(k)
                local kind = n > 0 and "units" or "objects"
                n = math.abs(n)
                local t = idx[kind][n]
                if not t then
                    t = {}
                    idx[kind][n] = t
                end
                t[role] = v ~= "" and v or true
                list[#list + 1] = { kind = kind, id = n }
            end
            idx.ids[role] = list
        end
    end
    Seed.roleIdx = idx
    return idx
end

-- Rollen einer Kreatur / eines Objekts: { vendor = "H", herbs = 280, ... } oder nil
function Seed.Roles(kind, id)
    if not Seed.Load() then
        return nil
    end
    return RoleIndex()[kind][id]
end

-- Rollen als Liste in fester Reihenfolge
function Seed.RoleList(kind, id)
    local roles = Seed.Roles(kind, id)
    if not roles then
        return {}
    end
    local list = {}
    for _, role in ipairs(Seed.ROLES[kind]) do
        if roles[role] then
            list[#list + 1] = role
        end
    end
    return list
end

function Seed.RoleIDs(role)
    if not Seed.Load() then
        return {}
    end
    return RoleIndex().ids[role] or {}
end

-- Naechste Kreaturen / Objekte mit einer Rolle auf der aktuellen Karte: { { kind, id, dist, m, x, y } }
function Seed.Nearest(role, limit, faction)
    local loc = Util.GetPlayerLocation and Util.GetPlayerLocation()
    local list = {}
    if not (loc and loc.mapID and loc.x and loc.y) or not Seed.Load() then
        return list
    end
    local side = faction or (UnitFactionGroup and select(1, UnitFactionGroup("player"))) or nil
    local letter = side == "Alliance" and "A" or side == "Horde" and "H" or nil
    for _, ref in ipairs(Seed.RoleIDs(role)) do
        local e = Seed.Entity(ref.kind, ref.id)
        local roles = Seed.Roles(ref.kind, ref.id)
        local value = roles and roles[role]
        local fac = (type(value) == "string" and value:match("^[AH]+$")) or (e and e.fac)
        if e and (not letter or not fac or fac:find(letter, 1, true)) then
            local d = Seed.Distance(Seed.Cells(ref.kind, ref.id))
            if d then
                local best, bm, bx, by
                local g2 = GRID * GRID
                for key in pairs(Seed.Cells(ref.kind, ref.id)) do
                    if floor(key / g2) == loc.mapID then
                        local idx = key % g2
                        local x, y = ((idx % GRID) + 0.5) / GRID, (floor(idx / GRID) + 0.5) / GRID
                        local dd = (x - loc.x) ^ 2 + (y - loc.y) ^ 2
                        if not best or dd < best then
                            best, bm, bx, by = dd, loc.mapID, x, y
                        end
                    end
                end
                list[#list + 1] = { kind = ref.kind, id = ref.id, dist = d, m = bm, x = bx, y = by }
            end
        end
    end
    table.sort(list, function(a, b)
        if a.dist ~= b.dist then return a.dist < b.dist end
        return a.id < b.id
    end)
    if limit then
        for i = #list, limit + 1, -1 do
            list[i] = nil
        end
    end
    return list
end

------------------------------------------------------------------------
-- Listen fuer die Oberflaeche
------------------------------------------------------------------------

-- Alle IDs einer Art (sortiert)
function Seed.IDs(kind)
    if not Seed.Load() then
        return {}
    end
    local c = caches.lists[kind]
    if c then
        return c
    end
    local src
    if kind == "quests" then src = S.q
    elseif kind == "units" then src = S.u
    elseif kind == "objects" then src = S.o
    elseif kind == "items" then src = S.ie end
    local list = {}
    for id in pairs(src or {}) do
        list[#list + 1] = id
    end
    if kind == "items" then
        for id in pairs(S.i) do
            if not S.ie[id] then list[#list + 1] = id end
        end
    end
    table.sort(list)
    caches.lists[kind] = list
    return list
end

-- Kleingeschriebene Namen (deutsch und englisch) zur Suche
function Seed.Haystack(kind, id)
    local c = caches.hay[kind]
    if not c then
        c = {}
        caches.hay[kind] = c
    end
    local h = c[id]
    if h then
        return h
    end
    local de, en
    if kind == "quests" then de, en = S.qd[id], S.qe[id]
    elseif kind == "units" then de, en = S.ud[id], S.ue[id]
    elseif kind == "objects" then de, en = S.od[id], S.oe[id]
    else de, en = S.id[id], S.ie[id] end
    h = ((de or "") .. "\n" .. (en or "")):lower()
    c[id] = h
    return h
end

function Seed.Count()
    if not Seed.Load() then
        return 0, 0, 0, 0
    end
    local function n(t)
        local c = 0
        for _ in pairs(t) do c = c + 1 end
        return c
    end
    return n(S.q), n(S.u), n(S.o), n(S.i)
end
