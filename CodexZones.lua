-- Freewood-Codex: Gebiete mit Stufenspanne, berechnet aus den gesammelten Kreaturen.
--
-- Jede Kreatur zaehlt mit ihren Sichtungen (Zellen) in den Karten, in denen sie gesehen wurde, Instanzen mit ihrer
-- Instanz-ID (negative Zone). Pro Gebiet:
--   lo, hi  typische Spanne: alle Stufen, die mindestens 5 % des Gewichts normaler Kreaturen haben
--   avg     gewichteter Durchschnitt innerhalb der Spanne
--   out     Ausreisser: normale Kreaturen ausserhalb der Spanne
--   special Elite / Selten / Boss usw. (fliessen nicht in die Spanne ein)
--   few     zu wenig Daten (weniger als MIN_UNITS normale Kreaturen): Spanne nur grob
--   manual  Spanne von Berechtigten von Hand gesetzt (db.ied, siehe Codex.ZoneEdID)
-- Wird mit den geteilten Kreaturdaten berechnet, daher sehen alle dasselbe.

local ADDON, NS = ...

local FW = _G.Freewood
if not FW or not FW:RequireAPI(1, ADDON) then
    return
end

local Codex = NS and NS.Codex
if not Codex then
    return
end

local Zones = {}
Codex.Zones = Zones

local GRID = Codex.GRID or 200
local MIN_UNITS = 3          -- weniger normale Kreaturen: "zu wenig Daten"
local LEVEL_SHARE = 0.05     -- Mindestanteil einer Stufe am Gewicht, damit sie zur typischen Spanne gehoert
local WEIGHT_CAP = 30        -- eine haeufig gesehene Kreatur zaehlt hoechstens so viel
local MAP_SHARE = 0.10       -- Karte zaehlt fuer eine Kreatur erst ab diesem Anteil ihrer Sichtungen
local CACHE_SECS = 5

local cache, cacheAt, dirty = nil, 0, true

function Zones.Invalidate()
    dirty = true
end

FW:On("CODEX_CHANGED", function() dirty = true end, Zones)

local function Now()
    return GetTime and GetTime() or 0
end

-- Gewichte einer Kreatur je Gebiet: { [zoneKey] = Gewicht }
local function Spread(u)
    local out = {}
    if type(u.ez) == "table" and #u.ez > 0 then
        local each = 1 / #u.ez
        local total = 0
        for _, n in pairs(u.cells or {}) do total = total + n end
        total = math.max(1, total)
        for _, m in ipairs(u.ez) do out[m] = total * each end
        return out
    end
    if type(u.iz) == "table" and next(u.iz) and u.dg ~= false then
        for id, n in pairs(u.iz) do out[-id] = n end
        return out
    end
    local per, total = {}, 0
    for key, n in pairs(u.cells or {}) do
        local m = math.floor(key / (GRID * GRID))
        per[m] = (per[m] or 0) + n
        total = total + n
    end
    for m, n in pairs(per) do
        if total > 0 and n / total >= MAP_SHARE then out[m] = n end
    end
    return out
end

local function ManualRange(ied, key)
    local rec = ied and ied[Codex.ZoneEdID(key)]
    if not rec then return nil end
    local l1 = rec.l1 or (rec.ed and rec.ed.l1)
    local l2 = rec.l2 or (rec.ed and rec.ed.l2)
    if l1 then return l1, l2 or l1 end
    return nil
end

local function Compute()
    local V = Codex.V()
    local zones = {}
    local function Zone(key)
        local z = zones[key]
        if not z then
            z = { id = key, normal = {}, special = {}, out = {} }
            zones[key] = z
        end
        return z
    end
    for id, u in pairs(V.units or {}) do
        if u.l1 and u.bad ~= true then
            local special = u.c ~= nil and u.c ~= false
            local l2 = u.l2 or u.l1
            for key, n in pairs(Spread(u)) do
                local w = math.max(1, math.min(WEIGHT_CAP, n))
                local entry = { id = id, l1 = u.l1, l2 = l2, w = w, c = special and u.c or nil, mid = (u.l1 + l2) / 2 }
                local z = Zone(key)
                if special then
                    z.special[#z.special + 1] = entry
                else
                    z.normal[#z.normal + 1] = entry
                end
            end
        end
    end
    for key, z in pairs(zones) do
        local byLevel, total = {}, 0
        local minL, maxL
        for _, e in ipairs(z.normal) do
            -- eine Kreatur mit Spanne (Stufe 3-4) zaehlt je zur Haelfte fuer beide Stufen
            local a, b = e.l1, e.l2
            local half = e.w / ((b > a) and 2 or 1)
            byLevel[a] = (byLevel[a] or 0) + half
            if b > a then byLevel[b] = (byLevel[b] or 0) + half end
            total = total + e.w
            minL = minL and math.min(minL, a) or a
            maxL = maxL and math.max(maxL, b) or b
        end
        z.units = #z.normal
        z.few = z.units < MIN_UNITS
        local lo, hi
        if total > 0 then
            for lv, w in pairs(byLevel) do
                if w / total >= LEVEL_SHARE then
                    lo = lo and math.min(lo, lv) or lv
                    hi = hi and math.max(hi, lv) or lv
                end
            end
            lo, hi = lo or minL, hi or maxL
        elseif #z.special > 0 then
            for _, e in ipairs(z.special) do
                minL = minL and math.min(minL, e.l1) or e.l1
                maxL = maxL and math.max(maxL, e.l2) or e.l2
            end
            lo, hi = minL, maxL
            z.few = true
        end
        local ml, mh = ManualRange(V.ied, key)
        if ml then
            lo, hi = ml, mh
            z.manual = true
            z.few = false
        end
        z.lo, z.hi = lo, hi
        local sum, wsum = 0, 0
        for _, e in ipairs(z.normal) do
            if lo and e.mid >= lo and e.mid <= hi then
                sum, wsum = sum + e.mid * e.w, wsum + e.w
            end
        end
        z.avg = wsum > 0 and sum / wsum or ((lo and hi) and (lo + hi) / 2 or nil)
        for _, e in ipairs(z.normal) do
            if lo and (e.l2 < lo or e.l1 > hi) then z.out[#z.out + 1] = e end
        end
        z.dungeon = key < 0
        z.minL, z.maxL = minL, maxL
    end
    -- von Hand gesetzte Spannen auch fuer Gebiete ohne Kreaturdaten
    for edID, rec in pairs(V.ied or {}) do
        local key = Codex.ZoneFromEdID(edID)
        if key and not zones[key] then
            local l1, l2 = ManualRange(V.ied, key)
            if l1 then
                zones[key] = { id = key, normal = {}, special = {}, out = {}, units = 0, lo = l1, hi = l2, avg = (l1 + l2) / 2,
                    manual = true, dungeon = key < 0 }
            end
        end
    end
    return zones
end

-- Alle Gebiete: { [zoneKey] = Daten }. Kurz zwischengespeichert.
function Zones.All()
    local t = Now()
    if not cache or (dirty and t - cacheAt >= CACHE_SECS) or t < cacheAt then
        local ok, res = pcall(Compute)
        cache = ok and res or cache or {}
        cacheAt, dirty = t, false
    end
    return cache
end

-- Sofort neu berechnen (zum Beispiel nach einer Aenderung im Fenster oder in Tests)
function Zones.Refresh()
    dirty = true
    cacheAt = -1e9
    return Zones.All()
end

function Zones.Get(key)
    return Zones.All()[key]
end

-- Eine Kreatur gehoert zu einem Gebiet: Liste fuer die Detailansicht, nach Stufe sortiert
function Zones.Members(key)
    local z = Zones.Get(key)
    if not z then return {} end
    local list = {}
    local outSet = {}
    for _, e in ipairs(z.out) do outSet[e] = true end
    for _, e in ipairs(z.normal) do
        list[#list + 1] = { id = e.id, l1 = e.l1, l2 = e.l2, w = e.w, out = outSet[e] or nil }
    end
    for _, e in ipairs(z.special) do
        list[#list + 1] = { id = e.id, l1 = e.l1, l2 = e.l2, w = e.w, c = e.c }
    end
    table.sort(list, function(a, b)
        if a.l1 ~= b.l1 then return a.l1 < b.l1 end
        if a.l2 ~= b.l2 then return a.l2 < b.l2 end
        return a.id < b.id
    end)
    return list
end

-- Passt die Stufe zum Gebiet? Rueckgabe: "in" (Stufe liegt in der Spanne), "below" (Spanne ist niedriger),
-- "above" (Spanne ist hoeher), nil (keine Daten). tol = Toleranz in Stufen.
function Zones.Compare(key, level, tol)
    local z = Zones.Get(key)
    if not z or not z.lo or z.few and not z.manual then return nil end
    tol = tol or 0
    if level < z.lo - tol then return "above" end
    if level > z.hi + tol then return "below" end
    return "in"
end

-- Gebiete, deren typische Spanne die Stufe enthaelt (mit Toleranz), mit genug Daten
function Zones.ForLevel(level, tol)
    local out = {}
    for key, z in pairs(Zones.All()) do
        if Zones.Compare(key, level, tol) == "in" then out[#out + 1] = z end
    end
    return out
end
