-- Freewood-Codex: Datenschicht fuers Teilen
--
--   * Eigene Datensaetze (Kreatur, Objekt, Quest, Erfahrungstabelle) werden bereinigt und mit einem
--     Aenderungsstand (upd) versehen. Der Stand liegt in db.sync.stamps und wird aus dem Inhalt
--     berechnet, so muss die Erfassung selbst nichts davon wissen.
--   * Empfangene Datensaetze liegen getrennt je Absender in db.remote und werden nie in die
--     eigenen Daten geschrieben. Ein neuer Stand desselben Absenders ersetzt den alten (idempotent).
--   * Share.View() liefert die Sicht fuer die Anzeige: eigene und fremde Daten zusammengerechnet.
--     Ohne fremde Daten ist das einfach Codex.db.
--
-- Schluessel eines Datensatzes: "u123" Kreatur, "o45" Objekt, "q678" Quest, "x0" Erfahrung, "t0" Kampfdauer.

local ADDON, NS = ...

local FW = _G.Freewood
local Codex = NS and NS.Codex
if not FW or not Codex then
    return
end

local Share = {}
Codex.Share = Share
NS.Share = Share

local GRID = Codex.GRID or 200
local MAX_SENDERS = 12
local MAX_RECORDS = 2500        -- je Absender
local MAX_PATH_RECORDS = 60000   -- Wegenetz-Bloecke je Absender (nur der Stand wird gemerkt)
local MAX_CELLS_SHARED = 120
local MAX_DROPS = 80
local MAX_NAMES = 6000
local SELF_IMPORT = "~import"

local KIND_OF = { u = "units", o = "objects", q = "quests", i = "ied" }
local LETTER_OF = { unit = "u", object = "o", quest = "q", item = "i" }
local CLASSES = { elite = true, rare = true, rareelite = true, worldboss = true }
local XP_CLASSES = { normal = true, elite = true, rare = true, rareelite = true, worldboss = true }

------------------------------------------------------------------------
-- Pruefer (alles, was von aussen kommt, geht hier durch)
------------------------------------------------------------------------

local function Text(v, max)
    if type(v) ~= "string" then
        return nil
    end
    v = v:gsub("|[cC]%x%x%x%x%x%x%x%x", ""):gsub("|[rR]", ""):gsub("|T.-|t", ""):gsub("|H.-|h", "")
    v = v:gsub("|", ""):gsub("%c", " ")
    v = v:gsub("^%s+", ""):gsub("%s+$", "")
    if v == "" then
        return nil
    end
    if #v > max then
        v = v:sub(1, max)
    end
    return v
end

local function Int(v, lo, hi)
    if type(v) ~= "number" or v ~= v or v == math.huge or v == -math.huge then
        return nil
    end
    v = math.floor(v)
    if v < lo or v > hi then
        return nil
    end
    return v
end

local function Frac(v)
    if type(v) ~= "number" or v ~= v or v < 0 or v > 1 then
        return nil
    end
    return math.floor(v * 10000 + 0.5) / 10000
end

local function Sample(s)
    if type(s) ~= "table" then
        return nil
    end
    local n, sum = Int(s.n, 1, 1000000), Int(s.sum, 0, 10000000000)
    local lo, hi = Int(s.min, 0, 10000000), Int(s.max, 0, 10000000)
    if not (n and sum and lo and hi) or lo > hi then
        return nil
    end
    if sum < lo * n - 1 or sum > hi * n + 1 then
        return nil
    end
    return { n = n, sum = sum, min = lo, max = hi }
end

-- Tabelle { [schluessel] = zahl } mit Obergrenze; die groessten Werte bleiben
local function TopCounts(src, keyFn, valLo, valHi, limit)
    local list = {}
    local seen = 0
    for k, v in pairs(src) do
        seen = seen + 1
        if seen > 20000 then
            break
        end
        local key, val = keyFn(k), Int(v, valLo, valHi)
        if key and val then
            list[#list + 1] = { key, val }
        end
    end
    table.sort(list, function(a, b)
        if a[2] ~= b[2] then
            return a[2] > b[2]
        end
        return a[1] < b[1]
    end)
    local out, count = {}, 0
    for _, e in ipairs(list) do
        if count >= limit then
            break
        end
        out[e[1]] = e[2]
        count = count + 1
    end
    return out, count
end

local function DropTable(src, k)
    if type(src) ~= "table" or not k then
        return nil
    end
    local list = {}
    local seen = 0
    for id, d in pairs(src) do
        seen = seen + 1
        if seen > 2000 then
            break
        end
        local iid = Int(id, 1, 10000000)
        if iid and type(d) == "table" then
            local n = Int(d.n, 1, 1000000)
            if n and n <= k then
                local q = Int(d.q, n, 100000000) or n
                list[#list + 1] = { id = iid, n = n, q = q, qi = d.qi and 1 or nil }
            end
        end
    end
    table.sort(list, function(a, b)
        if a.n ~= b.n then
            return a.n > b.n
        end
        return a.id < b.id
    end)
    local out, count = {}, 0
    for _, e in ipairs(list) do
        if count >= MAX_DROPS then
            break
        end
        out[e.id] = { n = e.n, q = e.q, qi = e.qi }
        count = count + 1
    end
    if count == 0 then
        return nil
    end
    return out
end

local function Ref(r)
    if type(r) ~= "table" then
        return nil
    end
    local k = r.k
    if k ~= "npc" and k ~= "object" and k ~= "other" then
        return nil
    end
    return {
        k = k, id = Int(r.id, 0, 100000000), n = Text(r.n, 60), m = Int(r.m, 0, 100000),
        x = Frac(r.x), y = Frac(r.y),
    }
end

local function RewardList(list)
    if type(list) ~= "table" then
        return nil
    end
    local out = {}
    for i = 1, math.min(#list, 12) do
        local e = list[i]
        local id = type(e) == "table" and Int(e.id, 1, 10000000)
        if id then
            out[#out + 1] = { id = id, c = Int(e.c, 1, 1000) or 1 }
        end
    end
    return #out > 0 and out or nil
end

local function SrcKey(k)
    if type(k) == "string" and k:match("^[uo]%d+$") and #k <= 12 then
        return k
    end
    return nil
end

local function ObjectiveList(list)
    if type(list) ~= "table" then
        return nil
    end
    local out = {}
    for i = 1, math.min(#list, 12) do
        local o = list[i]
        if type(o) == "table" then
            local ty = Text(o.ty, 16)
            local e = {
                ty = ty and ty:lower():gsub("[^a-z]", "") or nil,
                name = Text(o.name, 80), txt = Text(o.txt, 100),
                req = Int(o.req, 0, 100000), item = Int(o.item, 1, 10000000),
            }
            if e.ty == "" then e.ty = nil end
            if type(o.ids) == "table" then
                e.ids = TopCounts(o.ids, function(k) return Int(k, 1, 100000000) end, 1, 1000000, 12)
                if next(e.ids) == nil then e.ids = nil end
            end
            out[i] = e
        else
            out[i] = {}
        end
    end
    return #out > 0 and out or nil
end

local function QuestItems(src)
    if type(src) ~= "table" then
        return nil
    end
    local out, count = {}, 0
    for item, sources in pairs(src) do
        local iid = Int(item, 1, 10000000)
        if iid and type(sources) == "table" and count < 12 then
            local s = TopCounts(sources, SrcKey, 1, 1000000, 12)
            if next(s) ~= nil then
                out[iid] = s
                count = count + 1
            end
        end
    end
    return count > 0 and out or nil
end

local function XPTable(src)
    if type(src) ~= "table" then
        return nil
    end
    local out, count = {}, 0
    for pl, byMl in pairs(src) do
        local p = Int(pl, 1, 80)
        if p and type(byMl) == "table" then
            for ml, byCls in pairs(byMl) do
                local m = Int(ml, 1, 130)
                if m and type(byCls) == "table" then
                    for cls, s in pairs(byCls) do
                        if XP_CLASSES[cls] and count < 400 then
                            local sm = Sample(s)
                            if sm then
                                out[p] = out[p] or {}
                                out[p][m] = out[p][m] or {}
                                out[p][m][cls] = sm
                                count = count + 1
                            end
                        end
                    end
                end
            end
        end
    end
    return count > 0 and out or nil
end

-- Kampfdauer: ttk[Klasse][Spielerstufe][Gegnerstufe - Spielerstufe] = { n, sum, min, max } (Zehntelsekunden)
local function TTKTable(src)
    if type(src) ~= "table" then
        return nil
    end
    local out, count = {}, 0
    for cls, byPl in pairs(src) do
        if type(cls) == "string" and cls:match("^%u+$") and #cls <= 16 and type(byPl) == "table" then
            for pl, byDelta in pairs(byPl) do
                local p = Int(pl, 1, 80)
                if p and type(byDelta) == "table" then
                    for delta, s in pairs(byDelta) do
                        local d = Int(delta, -5, 5)
                        local sm = d and count < 1200 and Sample(s)
                        if sm then
                            out[cls] = out[cls] or {}
                            out[cls][p] = out[cls][p] or {}
                            out[cls][p][d] = sm
                            count = count + 1
                        end
                    end
                end
            end
        end
    end
    return count > 0 and out or nil
end

-- Kampfdauer einer Kreatur: tt[Klasse][Spielerstufe] = { n, sum, min, max } (Zehntelsekunden)
local function UnitTTK(src)
    if type(src) ~= "table" then
        return nil
    end
    local out, count = {}, 0
    for cls, byPl in pairs(src) do
        if type(cls) == "string" and cls:match("^%u+$") and #cls <= 16 and type(byPl) == "table" then
            for pl, s in pairs(byPl) do
                local p = Int(pl, 1, 80)
                local sm = p and count < 60 and Sample(s)
                if sm then
                    out[cls] = out[cls] or {}
                    out[cls][p] = sm
                    count = count + 1
                end
            end
        end
    end
    return count > 0 and out or nil
end

-- Rollen: nur bekannte Namen, Zaehler begrenzt
local ROLE_KEYS = {
    vendor = true, repair = true, flight = true, innkeeper = true, stablemaster = true, spirithealer = true,
    auctioneer = true, battlemaster = true, banker = true, classtrainer = true, proftrainer = true, mailbox = true,
}
local MAX_WARES_SHARED = 90
local MAX_TRAIN_SHARED = 100
local MAX_DEST_SHARED = 40
local MAX_PRICES_SHARED = 4

local function RoleTable(src)
    if type(src) ~= "table" then
        return nil
    end
    local out, count = {}, 0
    for role, n in pairs(src) do
        local v = type(role) == "string" and ROLE_KEYS[role] and Int(n, 1, 100000)
        if v then
            out[role] = v
            count = count + 1
        end
    end
    return count > 0 and out or nil
end

-- { [preis in Kupfer] = Anzahl }, hoechstens MAX_PRICES_SHARED (haeufigste)
local function PriceMap(src)
    if type(src) ~= "table" then
        return nil
    end
    local out, count = TopCounts(src, function(k)
        return Int(k, 0, 2000000000)
    end, 1, 100000, MAX_PRICES_SHARED)
    return count > 0 and out or nil
end

local function SortedKeys(src, keyFn)
    local list = {}
    local seen = 0
    for k, v in pairs(src) do
        seen = seen + 1
        if seen > 5000 then
            break
        end
        local key = keyFn(k)
        if key ~= nil and type(v) == "table" then
            list[#list + 1] = { key, v }
        end
    end
    table.sort(list, function(a, b)
        return a[1] < b[1]
    end)
    return list
end

local function WareTable(src)
    if type(src) ~= "table" then
        return nil
    end
    local out, count = {}, 0
    for _, e in ipairs(SortedKeys(src, function(k)
        return Int(k, 1, 10000000)
    end)) do
        if count >= MAX_WARES_SHARED then
            break
        end
        local pr = PriceMap(e[2].pr)
        if pr then
            out[e[1]] = { pr = pr, st = Int(e[2].st, 2, 1000), lim = e[2].lim and 1 or nil, ec = e[2].ec and 1 or nil }
            count = count + 1
        end
    end
    return count > 0 and out or nil
end

local function TrainTable(src)
    if type(src) ~= "table" then
        return nil
    end
    local out, count = {}, 0
    for _, e in ipairs(SortedKeys(src, function(k)
        return Text(k, 100)
    end)) do
        if count >= MAX_TRAIN_SHARED then
            break
        end
        local r = e[2]
        local nm = Text(r.nm, 60)
        local pr = PriceMap(r.pr)
        if nm and pr then
            out[e[1]] = { nm = nm, sp = Int(r.sp, 1, 10000000), rk = Text(r.rk, 30), lv = Int(r.lv, 1, 130), sn = Text(r.sn, 40), sr = Int(r.sr, 1, 1000), pr = pr }
            count = count + 1
        end
    end
    return count > 0 and out or nil
end

local function FlightTable(src)
    if type(src) ~= "table" then
        return nil
    end
    local out, count = {}, 0
    for _, e in ipairs(SortedKeys(src, function(k)
        return Text(k, 60)
    end)) do
        if count >= MAX_DEST_SHARED then
            break
        end
        local pr = PriceMap(e[2])
        if pr then
            out[e[1]] = pr
            count = count + 1
        end
    end
    return count > 0 and out or nil
end

local function PerLevel(src, depth)
    -- xm[spielerstufe][gegnerstufe] bzw. xp[spielerstufe]
    if type(src) ~= "table" then
        return nil
    end
    local out, count = {}, 0
    for pl, v in pairs(src) do
        local p = Int(pl, 1, 80)
        if p and type(v) == "table" then
            if depth == 1 then
                local sm = Sample(v)
                if sm and count < 40 then
                    out[p] = sm
                    count = count + 1
                end
            else
                for ml, s in pairs(v) do
                    local m = Int(ml, 1, 130)
                    local sm = m and Sample(s)
                    if sm and count < 40 then
                        out[p] = out[p] or {}
                        out[p][m] = sm
                        count = count + 1
                    end
                end
            end
        end
    end
    return count > 0 and out or nil
end

-- DEV-Funktionen: Namen und "fehlerhaft"-Markierung (bad: 1 = fehlerhaft, 0 = Markierung aufgehoben)
local function BadFlag(v)
    if v == true or v == 1 then return 1 end
    if v == false or v == 0 then return 0 end
    return nil
end

local function CanEditNames()
    return Codex.Trust ~= nil and Codex.Trust.CanEdit()
end

local BUILTIN = "~forever"   -- die mitgelieferten Startdaten (Freewood-ForeverData): wie ein Berechtigter, aber ganz unten

local function IsDevSender(name)
    if name == BUILTIN then return true end
    return Codex.Trust ~= nil and Codex.Trust.IsDev(name)
end

-- Eigenschaften (Zonen, Dungeon, Klasse, Stufen) von Berechtigten; auf der Leitung ist dg 1 / 0
local function WireBool(v)
    if v == true or v == 1 then return true end
    if v == false or v == 0 then return false end
    return nil
end

local function SanitizeEd(src, kind)
    if type(src) ~= "table" then return nil end
    local probe = { z = src.z, dg = WireBool(src.dg), cl = src.cl, l1 = src.l1, l2 = src.l2, pre = src.pre,
        key = src.key, nx = src.nx, bf = src.bf, af = src.af, ql = src.ql, tx = src.tx, si = src.si }
    local ed = Codex.CleanEd(probe, kind)
    if not ed then return nil end
    if ed.dg ~= nil then ed.dg = ed.dg and 1 or 0 end
    return ed
end

-- Aus dem Datensatz eines anderen Spielers in die eigene Form (dg als Wahrheitswert)
local function EdFromWire(ed)
    if type(ed) ~= "table" then return nil end
    local out = Codex.CopyEd(ed)
    out.dg = WireBool(ed.dg)
    return out
end

-- Texte je Teilfeld fuer das Protokoll
local function EdFields(ed)
    local f = {}
    if type(ed) ~= "table" then return f end
    if ed.z then f.ez = table.concat(ed.z, ",") end
    local dg = WireBool(ed.dg)
    if dg ~= nil then f.edg = dg and "1" or "0" end
    f.ecl = ed.cl
    if ed.l1 then f.el = ed.l1 .. "-" .. (ed.l2 or ed.l1) end
    if ed.pre then f.epre = table.concat(ed.pre, ",") end
    if ed.key then f.ekey = tostring(ed.key) end
    if ed.nx then f.enx = table.concat(ed.nx, ",") end
    if ed.bf then f.ebf = table.concat(ed.bf, ",") end
    if ed.af then f.eaf = table.concat(ed.af, ",") end
    if ed.ql then f.eql = tostring(ed.ql) end
    if ed.tx then f.etx = ed.tx end
    if ed.si then f.esi = tostring(ed.si) end
    return f
end
Share.EdFields = EdFields
-- alle Teilfelder der Eigenschaften (fuer Vorschau und Protokoll)
Share.ED_FIELDS = { "ez", "edg", "ecl", "el", "epre", "ekey", "enx", "ebf", "eaf", "eql", "etx", "esi" }

-- Instanzen, in denen eine Kreatur / ein Objekt gesehen wurde: { [instanceID] = Anzahl }, hoechstens 3
local function SanitizeIz(src)
    if type(src) ~= "table" then return nil end
    local out, count = {}, 0
    for id, n in pairs(src) do
        local iid, cnt = Int(id, 1, 100000), Int(n, 1, 1000000)
        if iid and cnt and count < 3 then
            out[iid] = cnt
            count = count + 1
        end
    end
    return count > 0 and out or nil
end

local function SanitizeEntity(rec, isObject)
    local out = {}
    out.n = Text(rec.n, 60)
    out.cde, out.cen = Text(rec.cde, 60), Text(rec.cen, 60)
    out.bad = BadFlag(rec.bad)
    out.ed = SanitizeEd(rec.ed, isObject and "objects" or "units")
    out.iz = SanitizeIz(rec.iz)
    if not isObject then
        out.l1, out.l2 = Int(rec.l1, 1, 130), Int(rec.l2, 1, 130)
        if out.l1 and out.l2 and out.l1 > out.l2 then
            out.l1, out.l2 = out.l2, out.l1
        end
        out.c = CLASSES[rec.c] and rec.c or nil
        out.f = Text(rec.f, 40)
    end
    out.k = Int(rec.k, 0, 1000000)
    local k = out.k or 0
    if k > 0 then
        out.coinN = Int(rec.coinN, 0, k)
        out.coin = out.coinN and out.coinN > 0 and Int(rec.coin, 0, 1000000000000) or nil
        if not out.coin then
            out.coinN = nil
        end
    end
    if type(rec.cells) == "table" then
        local cells, count = TopCounts(rec.cells, function(key)
            return Int(key, 0, 1000000000)
        end, 1, 1000000, MAX_CELLS_SHARED)
        if count > 0 then
            out.cells = cells
        end
    end
    out.d = DropTable(rec.d, k)
    if type(rec.alt) == "table" then
        local ak = Int(rec.alt.k, 1, 1000000)
        if ak then
            out.alt = { k = ak, d = DropTable(rec.alt.d, ak) }
        end
    end
    out.ro = RoleTable(rec.ro)
    if not isObject then
        out.xm = PerLevel(rec.xm, 2)
        out.tt = UnitTTK(rec.tt)
        out.ti = Text(rec.ti, 40)
        out.wa = WareTable(rec.wa)
        out.tr = TrainTable(rec.tr)
        if type(rec.trc) == "string" and Codex.CLASS_TOKENS and Codex.CLASS_TOKENS[rec.trc] then out.trc = rec.trc end
        out.fl = FlightTable(rec.fl)
        out.fn = Text(rec.fn, 60)
    end
    if type(rec.nm) == "table" then
        local nm, count = {}, 0
        local function Wanted(id)
            return (out.d and out.d[id]) or (out.alt and out.alt.d and out.alt.d[id])
        end
        for id, name in pairs(rec.nm) do
            local iid = Int(id, 1, 10000000)
            local t = iid and Wanted(iid) and Text(name, 80)
            if t and count < MAX_DROPS then
                nm[iid] = t
                count = count + 1
            end
        end
        if count > 0 then
            out.nm = nm
        end
    end
    if not (out.n or (out.k and out.k > 0) or out.cells or out.iz or out.cde or out.cen or out.bad or out.ed or out.tt or out.xm or out.ro or out.wa or out.tr or out.fl) then
        return nil
    end
    return out
end

-- Items: nur die Eigenschaften von Berechtigten
local function SanitizeItem(rec, id)
    local out = { ed = SanitizeEd(rec.ed, (id and id >= Codex.ZONE_BASE) and "zones" or "items") }
    if not out.ed then return nil end
    return out
end

local function SanitizeQuest(rec)
    local out = {}
    out.t = Text(rec.t, 100)
    if not out.t then
        return nil
    end
    out.cde, out.cen = Text(rec.cde, 100), Text(rec.cen, 100)
    out.bad = BadFlag(rec.bad)
    out.ed = SanitizeEd(rec.ed, "quests")
    out.lvl, out.pl = Int(rec.lvl, 0, 130), Int(rec.pl, 0, 130)
    out.zone = Int(rec.zone, 0, 100000)
    out.give, out.turn = Ref(rec.give), Ref(rec.turn)
    out.si = Int(rec.si, 1, 100000000)
    -- Kette und Voraussetzungen: Vorquests (jede genuegt), Mindeststufe, Volks- und Klassenmaske
    if type(rec.pre) == "table" then
        local pre = {}
        for i = 1, math.min(#rec.pre, 8) do
            local v = Int(rec.pre[i], 1, 100000000)
            if v then pre[#pre + 1] = v end
        end
        if #pre > 0 then out.pre = pre end
    end
    out.mn, out.rc, out.cl = Int(rec.mn, 1, 130), Int(rec.rc, 1, 4294967295), Int(rec.cl, 1, 4294967295)
    -- Beobachtungen zur Verfuegbarkeit: pi (Kandidat -> Anzahl), po (Beobachtungen), mi (Stufenbereich)
    if type(rec.pi) == "table" then
        local pi, count = {}, 0
        for k, v in pairs(rec.pi) do
            local id, n = Int(k, 1, 100000000), Int(v, 1, 100000)
            if id and n and count < 8 then pi[id] = n count = count + 1 end
        end
        local po = Int(rec.po, 1, 100000)
        if count > 0 and po then out.pi, out.po = pi, po end
    end
    if type(rec.mi) == "table" then
        local lo, hi, n = Int(rec.mi.lo, 0, 130), Int(rec.mi.hi, 1, 130), Int(rec.mi.n, 1, 100000)
        if lo and hi and n and hi > lo then out.mi = { lo = lo, hi = hi, n = n } end
    end
    out.xp, out.money = Int(rec.xp, 0, 10000000), Int(rec.money, 0, 1000000000)
    if type(rec.rep) == "table" then
        local rep, count = {}, 0
        for name, v in pairs(rec.rep) do
            local nm, val = Text(name, 60), Int(v, -100000, 100000)
            if nm and val and count < 8 then
                rep[nm] = val
                count = count + 1
            end
        end
        if count > 0 then
            out.rep = rep
        end
    end
    out.fixed, out.choice = RewardList(rec.fixed), RewardList(rec.choice)
    out.tm, out.tr, out.ta = Sample(rec.tm), Sample(rec.tr), Sample(rec.ta)
    out.obj = ObjectiveList(rec.obj)
    out.qi = QuestItems(rec.qi)
    return out
end

local function SanitizeXPRecord(rec)
    local xp = XPTable(rec.xp)
    if not xp then
        return nil
    end
    return { xp = xp }
end

local function SanitizeTTKRecord(rec)
    local tk = TTKTable(rec.tk)
    if not tk then
        return nil
    end
    return { tk = tk }
end

-- Verkehrsverbindung (Schiff, Zeppelin, ...): von Berechtigten erfasst
local function SanitizeTransportRecord(rec)
    local T = Codex.Transport
    local kindOk = false
    for _, k in ipairs(T and T.KINDS or {}) do
        if rec.k == k then kindOk = true end
    end
    if not kindOk then return nil end
    local function Spot(p)
        if type(p) ~= "table" then return nil end
        local m, x, y = Int(p.m, -1000000, 1000000), Frac(p.x), Frac(p.y)
        if not (m and x and y) then return nil end
        return { m = m, x = x, y = y }
    end
    local a, b = Spot(rec.a), Spot(rec.b)
    local t = Int(rec.t, 1, 7200)
    if not (a and b and t) then return nil end
    local out = { k = rec.k, t = t, a = a, b = b, two = rec.two ~= false and true or false }
    if rec.f == "A" or rec.f == "H" then out.f = rec.f end
    out.n = Text(rec.n, 40)
    if rec.del == true then out.del = true end
    return out
end

-- Flug (Flugmeister): von jedem Spieler gemessen
local function SanitizeFlightRecord(rec)
    local function Node(p)
        if type(p) ~= "table" then return nil end
        local c, tx, ty = Int(p.c, 0, 1000000), Int(p.tx, 0, 1000), Int(p.ty, 0, 1000)
        if not (c and tx and ty) then return nil end
        local out = { c = c, tx = tx, ty = ty, n = Text(p.n, 40) }
        local m, x, y = Int(p.m, -1000000, 1000000), Frac(p.x), Frac(p.y)
        if m and x and y then out.m, out.x, out.y = m, x, y end
        return out
    end
    local a, b = Node(rec.a), Node(rec.b)
    local t = Int(rec.t, 5, 3600)
    if not (a and b and t) then return nil end
    if a.c == b.c and a.tx == b.tx and a.ty == b.ty then return nil end
    local out = { a = a, b = b, t = t, c = Int(rec.c, 0, 10000000) or 0, n = Int(rec.n, 1, 100000) or 1 }
    if rec.f == "A" or rec.f == "H" then out.f = rec.f end
    return out
end

-- Ortspunkt (Instanz-Eingang, Berg-Aufstieg, ...): von Berechtigten erfasst
local function SanitizeSpotRecord(rec)
    local S = Codex.Spots
    local kindOk = false
    for _, k in ipairs(S and S.KINDS or {}) do
        if rec.k == k then kindOk = true end
    end
    if not kindOk or type(rec.p) ~= "table" then return nil end
    local m, x, y = Int(rec.p.m, -1000000, 1000000), Frac(rec.p.x), Frac(rec.p.y)
    if not (m and x and y) then return nil end
    local out = { k = rec.k, p = { m = m, x = x, y = y }, q = {} }
    if type(rec.q) == "table" then
        local seen = {}
        for _, v in ipairs(rec.q) do
            local id = Int(v, 1, 1000000)
            if id and not seen[id] and #out.q < (S and S.MAX_QUESTS or 20) then
                seen[id] = true
                out.q[#out.q + 1] = id
            end
        end
        table.sort(out.q)
    end
    out.am = Int(rec.am, -1000000, 1000000)
    if rec.f == "A" or rec.f == "H" then out.f = rec.f end
    out.n = Text(rec.n, 40)
    if rec.del == true then out.del = true end
    if not out.am and #out.q == 0 and not out.del then return nil end
    return out
end

-- Wegenetz-Block: Text "Zelle.Maske,..." wird geprueft und in Normalform gebracht
local function SanitizePathRecord(rec)
    local P = Codex.Path
    local cells = P and P.ParseChunk(rec.c)
    if not cells then
        return nil
    end
    return { c = P.ChunkText(cells) }
end

local function SanitizeLinkRecord(rec)
    local P = Codex.Path
    local list = P and P.ParseLinks(rec.l)
    if not list then
        return nil
    end
    return { l = list }
end

-- key: "u123"; rec: unbekannte Eingabe. Rueckgabe: bereinigter Datensatz { y, id, upd, ... } oder nil
function Share.Sanitize(key, rec, upd)
    if type(key) ~= "string" or type(rec) ~= "table" then
        return nil
    end
    local letter, num = key:match("^([uoqixtpzghf])(%d+)$")
    local id = num and Int(tonumber(num), 0, (letter == "p") and 65536000000 or 100000000)
    if not letter or not id then
        return nil
    end
    upd = Int(upd, 1, 4000000000)
    if not upd then
        return nil
    end
    local out
    if letter == "u" then
        out = SanitizeEntity(rec, false)
    elseif letter == "o" then
        out = SanitizeEntity(rec, true)
    elseif letter == "q" then
        out = SanitizeQuest(rec)
    elseif letter == "i" then
        out = SanitizeItem(rec, id)
    elseif letter == "t" then
        out = SanitizeTTKRecord(rec)
    elseif letter == "p" then
        out = SanitizePathRecord(rec)
    elseif letter == "z" then
        out = SanitizeLinkRecord(rec)
    elseif letter == "g" then
        out = SanitizeTransportRecord(rec)
    elseif letter == "h" then
        out = SanitizeSpotRecord(rec)
    elseif letter == "f" then
        out = SanitizeFlightRecord(rec)
    else
        out = SanitizeXPRecord(rec)
    end
    if not out then
        return nil
    end
    out.y, out.id, out.upd = letter, id, upd
    return out
end

------------------------------------------------------------------------
-- Eigene Datensaetze und ihr Stand
------------------------------------------------------------------------

local function Store()
    local db = Codex.db
    db.sync = db.sync or {}
    db.sync.stamps = db.sync.stamps or {}
    db.sync.sent = db.sync.sent or 0
    db.sync.received = db.sync.received or 0
    return db.sync
end
Share.Store = Store

local function Sum(t)
    local s = 0
    for _, v in pairs(t) do
        s = s + (type(v) == "table" and (v.n or 0) or v)
    end
    return s
end

local function BucketSig(b)
    local s = (b.k or 0) * 17
    for _, d in pairs(b.d or {}) do
        s = s + (d.n or 0) * 13 + 1
    end
    return s
end

local function StrSig(str)
    if type(str) ~= "string" then
        return 0
    end
    local h = #str
    for i = 1, math.min(#str, 100) do
        h = (h * 31 + str:byte(i)) % 1000003
    end
    return h
end

local function EdSig(ed)
    if type(ed) ~= "table" then return 0 end
    local h = 0
    for k, v in pairs(EdFields(ed)) do
        h = h + StrSig(k) * 3 + StrSig(tostring(v)) * 59
    end
    return h
end

local function Signature(letter, e)
    local s
    if letter == "i" then
        return (1 + EdSig(e.ed)) % 2147483647
    elseif letter == "q" then
        s = (e.seen or 0) * 3 + (e.done or 0) * 5 + #(e.t or "") * 7 + (e.xp or 0) + (e.money or 0)
        s = s + #(e.fixed or {}) * 11 + #(e.choice or {}) * 13 + (e.partial and 1 or 0)
        s = s + (e.tm and e.tm.n or 0) * 23 + (e.tr and e.tr.n or 0) * 29 + (e.ta and e.ta.n or 0) * 31
        for i, o in ipairs(e.obj or {}) do
            s = s + #(o.name or "") * (i + 1) + (o.item or 0) + Sum(o.ids or {}) * 3 + 1
        end
        for item, srcs in pairs(e.qi or {}) do
            s = s + item % 997 + Sum(srcs)
        end
        if e.give then s = s + (e.give.id or 0) end
        if e.turn then s = s + (e.turn.id or 0) end
        s = s + (e.si or 0) % 1019
        for _, p in ipairs(e.pre or {}) do s = s + p % 997 * 3 + 1 end
        s = s + (e.mn or 0) * 5 + (e.rc or 0) % 1009 + (e.cl or 0) % 1013
        for p2, n2 in pairs(e.pi or {}) do s = s + p2 % 991 * n2 end
        s = s + (e.po or 0) * 3 + (e.mi and (e.mi.lo * 7 + e.mi.hi * 11 + (e.mi.n or 0)) or 0)
        if CanEditNames() then s = s + StrSig(e.cde) * 17 + StrSig(e.cen) * 19 + (BadFlag(e.bad) or 7) * 53 + EdSig(e.ed) end
    else
        s = BucketSig(e) + Sum(e.coinN and { e.coinN } or {}) * 5 + #(e.n or "") * 7 + (e.l1 or 0) + (e.l2 or 0) * 11
        if CanEditNames() then s = s + StrSig(e.cde) * 17 + StrSig(e.cen) * 19 + (BadFlag(e.bad) or 7) * 53 + EdSig(e.ed) end
        s = s + Sum(e.iz or {}) * 61
        for _ in pairs(e.cells or {}) do
            s = s + 1
        end
        s = s + Sum(e.cells or {})
        if e.alt then
            s = s + BucketSig(e.alt) * 3
        end
        for _, byMl in pairs(e.xm or {}) do
            s = s + Sum(byMl) * 19
        end
        for _, byPl in pairs(e.tt or {}) do
            for _, st in pairs(byPl) do
                s = s + (st.n or 0) * 37 + (st.sum or 0) % 101
            end
        end
        s = s + Sum(e.ro or {}) * 41 + StrSig(e.ti) * 43 + StrSig(e.fn) * 47 + StrSig(e.trc) * 53
        for id, w in pairs(e.wa or {}) do
            s = s + id % 991 + Sum(w.pr or {}) * 3 + (w.st or 0)
            for price in pairs(w.pr or {}) do
                s = s + price % 997
            end
        end
        for key, r in pairs(e.tr or {}) do
            s = s + #key + (r.sp or 0) % 997 + (r.lv or 0) * 5 + (r.sr or 0) + Sum(r.pr or {}) * 3
            for price in pairs(r.pr or {}) do
                s = s + price % 997
            end
        end
        for dest, pr in pairs(e.fl or {}) do
            s = s + #dest * 7 + Sum(pr) * 3
            for price in pairs(pr) do
                s = s + price % 997
            end
        end
    end
    return s % 2147483647
end

local function IsShareable(letter, e)
    if type(e) ~= "table" then
        return false
    end
    if letter == "q" then
        return type(e.t) == "string" and not e.loc      -- eigene Quests des Creators bleiben bei dir
    end
    if letter == "i" then
        return CanEditNames() and e.ed ~= nil
    end
    -- auch ohne Namen (zum Beispiel in Instanzen gelootete Kreaturen); Namen kommen von anderen Spielern
    -- auch mit nur einem von Hand eingetragenen Namen
    -- (auch Kreaturen, bei denen nur Kampfdauer oder Erfahrung gemessen wurde)
    local named = CanEditNames() and (e.cde ~= nil or e.cen ~= nil or e.bad ~= nil or e.ed ~= nil)
    return ((e.k or 0) > 0) or e.cells ~= nil or e.iz ~= nil or named or e.tt ~= nil or e.xm ~= nil
        or e.ro ~= nil or e.wa ~= nil or e.tr ~= nil or e.fl ~= nil
end

Share.IsShareable = IsShareable

local function XPSignature()
    local s, any = 0, false
    for _, byMl in pairs(Codex.db.xp or {}) do
        for _, byCls in pairs(byMl) do
            for _, sm in pairs(byCls) do
                s = s + (sm.n or 0) * 7 + 1
                any = true
            end
        end
    end
    return any and s % 2147483647 or nil
end

local function TTKSignature()
    local s, any = 0, false
    for _, byPl in pairs(Codex.db.ttk or {}) do
        for _, byDelta in pairs(byPl) do
            for _, sm in pairs(byDelta) do
                s = s + (sm.n or 0) * 7 + 1
                any = true
            end
        end
    end
    return any and s % 2147483647 or nil
end

local scanCache, scanAt = nil, 0
local firstScanDone = false

local function Touch(stamps, key, sig, now)
    local s = stamps[key]
    if not s then
        stamps[key] = { sig = sig, upd = now }
        return true
    elseif s.sig ~= sig then
        s.sig = sig
        s.upd = math.max(now, (s.upd or 0) + 1)
        return true
    end
    return false
end

-- Alle eigenen Datensaetze durchgehen. Rueckgabe: Liste { key, upd }, Anzahl, Pruefwert, geaenderte Schluessel
function Share.Scan(force)
    local now = time()
    if scanCache and not force and now - scanAt < 30 then
        return scanCache.list, scanCache.count, scanCache.hash, {}
    end
    local store = Store()
    local stamps = store.stamps
    local list, changed, hash = {}, {}, 0
    for letter, field in pairs(KIND_OF) do
        for id, e in pairs(Codex.db[field]) do
            if type(id) == "number" and IsShareable(letter, e) then
                local key = letter .. id
                if Touch(stamps, key, Signature(letter, e), now) then
                    changed[#changed + 1] = key
                end
                local upd = stamps[key].upd
                list[#list + 1] = { key = key, upd = upd }
                hash = (hash + (id % 100003) * 31 + upd % 1000003 + (letter:byte() * 7)) % 2147483647
            end
        end
    end
    local xs = XPSignature()
    if xs then
        if Touch(stamps, "x0", xs, now) then
            changed[#changed + 1] = "x0"
        end
        list[#list + 1] = { key = "x0", upd = stamps.x0.upd }
        hash = (hash + stamps.x0.upd % 1000003 + 5) % 2147483647
    end
    local ts = TTKSignature()
    if ts then
        if Touch(stamps, "t0", ts, now) then
            changed[#changed + 1] = "t0"
        end
        list[#list + 1] = { key = "t0", upd = stamps.t0.upd }
        hash = (hash + stamps.t0.upd % 1000003 + 11) % 2147483647
    end
    for id, rec in pairs(Codex.db.transport or {}) do
        if type(id) == "number" and type(rec) == "table" and rec.upd then
            list[#list + 1] = { key = "g" .. id, upd = rec.upd }
            hash = (hash + id % 100003 * 17 + rec.upd % 1000003 + 103) % 2147483647
        end
    end
    for id, rec in pairs(Codex.db.flight and Codex.db.flight.routes or {}) do
        if type(id) == "number" and type(rec) == "table" and rec.upd and rec.a and rec.b then
            list[#list + 1] = { key = "f" .. id, upd = rec.upd }
            hash = (hash + id % 100003 * 23 + rec.upd % 1000003 + 109) % 2147483647
        end
    end
    for id, rec in pairs(Codex.db.spots or {}) do
        if type(id) == "number" and type(rec) == "table" and rec.upd then
            list[#list + 1] = { key = "h" .. id, upd = rec.upd }
            hash = (hash + id % 100003 * 19 + rec.upd % 1000003 + 107) % 2147483647
        end
    end
    if Codex.Path and Codex.Path.SyncList then
        for _, e in ipairs(Codex.Path.SyncList()) do
            list[#list + 1] = e
            hash = (hash + (tonumber(e.key:sub(2)) or 0) % 100003 * 13 + e.upd % 1000003 + e.key:byte() * 3) % 2147483647
        end
    end
    scanCache = { list = list, count = #list, hash = hash }
    scanAt = now
    if not firstScanDone then
        firstScanDone = true
        changed = {}
    end
    return list, #list, hash, changed
end

function Share.Summary()
    local _, count, hash = Share.Scan(false)
    return count, hash
end

function Share.InvalidateScan()
    scanCache = nil
end

-- Stand eines einzelnen eigenen Datensatzes neu berechnen. Rueckgabe: key, upd, geaendert
function Share.StampOne(kind, id)
    local letter = LETTER_OF[kind]
    if not letter or type(id) ~= "number" then
        return nil
    end
    local e = Codex.db[KIND_OF[letter]][id]
    if not IsShareable(letter, e) then
        return nil
    end
    local key = letter .. id
    local stamps = Store().stamps
    local changed = Touch(stamps, key, Signature(letter, e), time())
    scanCache = nil
    return key, stamps[key].upd, changed
end

function Share.OwnUpd(key)
    local s = Store().stamps[key]
    return s and s.upd or nil
end

-- Verzeichnis: eigene Datensaetze mit Stand > since, aelteste zuerst
function Share.Directory(since, limit)
    local list = Share.Scan(false)
    local out = {}
    for _, e in ipairs(list) do
        if e.upd > (since or 0) then
            out[#out + 1] = e
        end
    end
    table.sort(out, function(a, b)
        if a.upd ~= b.upd then
            return a.upd < b.upd
        end
        return a.key < b.key
    end)
    while #out > (limit or 400) do
        out[#out] = nil
    end
    return out
end

-- Eigener Datensatz zum Senden (bereinigt). Rueckgabe: record, upd
function Share.OwnRecord(key)
    local letter, num = tostring(key):match("^([uoqixtpzghf])(%d+)$")
    if not letter then
        return nil
    end
    local id = tonumber(num)
    if letter == "g" then
        local rec = Codex.db.transport and Codex.db.transport[id]
        if type(rec) ~= "table" or not rec.upd then return nil end
        local out = Share.Sanitize(key, rec, rec.upd)
        return out, rec.upd
    end
    if letter == "f" then
        local rec = Codex.db.flight and Codex.db.flight.routes and Codex.db.flight.routes[id]
        if type(rec) ~= "table" or not rec.upd then return nil end
        local out = Share.Sanitize(key, rec, rec.upd)
        return out, rec.upd
    end
    if letter == "h" then
        local rec = Codex.db.spots and Codex.db.spots[id]
        if type(rec) ~= "table" or not rec.upd then return nil end
        local out = Share.Sanitize(key, rec, rec.upd)
        return out, rec.upd
    end
    if letter == "p" or letter == "z" then
        local P = Codex.Path
        if not P then return nil end
        local list = Share.Scan(false)
        local upd
        for _, e in ipairs(list) do
            if e.key == key then upd = e.upd break end
        end
        if not upd then return nil end
        local raw = letter == "p" and P.ChunkRecord(id) or P.LinkRecord()
        if not raw then return nil end
        local rec = Share.Sanitize(key, raw, upd)
        return rec, upd
    end
    local upd = Share.OwnUpd(key)
    if not upd then
        Share.Scan(true)
        upd = Share.OwnUpd(key)
    end
    if not upd then
        return nil
    end
    local raw
    if letter == "x" then
        raw = { xp = Codex.db.xp }
    elseif letter == "t" then
        raw = { tk = Codex.db.ttk }
    else
        local e = Codex.db[KIND_OF[letter]][id]
        if not IsShareable(letter, e) then
            return nil
        end
        raw = e
        if letter == "u" or letter == "o" then
            local nm = {}
            for _, bucket in ipairs({ e, e.alt or {} }) do
                for itemID in pairs(bucket.d or {}) do
                    local name = Codex.db.names[itemID]
                    if name then
                        nm[itemID] = name
                    end
                end
            end
            raw = setmetatable({ nm = nm }, { __index = e })
        end
    end
    local rec = Share.Sanitize(key, raw, upd)
    -- Namen und Markierungen verschicken nur Berechtigte (mit Modul Freewood-Dev)
    if rec and (letter == "u" or letter == "o" or letter == "q" or letter == "i") and not CanEditNames() then
        rec.cde, rec.cen, rec.bad, rec.ed = nil, nil, nil, nil
    end
    return rec, upd
end

-- Zu grosse Datensaetze verkleinern (Waren, Lehrstoff, Flugziele halbieren, kleinste Schluessel bleiben)
function Share.Shrink(rec)
    if type(rec) ~= "table" then
        return nil
    end
    local out, cut = {}, false
    for k, v in pairs(rec) do
        out[k] = v
    end
    for _, field in ipairs({ "wa", "tr", "fl" }) do
        local src = rec[field]
        if type(src) == "table" then
            local keys = {}
            for key in pairs(src) do
                keys[#keys + 1] = key
            end
            table.sort(keys, function(a, b)
                if type(a) == type(b) then return a < b end
                return type(a) == "number"
            end)
            if #keys > 8 then
                local kept = {}
                for i = 1, math.floor(#keys / 2) do
                    kept[keys[i]] = src[keys[i]]
                end
                out[field] = kept
                cut = true
            end
        end
    end
    if not cut then
        return nil
    end
    return out
end

------------------------------------------------------------------------
-- Fremde Daten
------------------------------------------------------------------------

local view, index, allDirty, dirtyIds, xpRecs, xpDirty = nil, nil, true, {}, {}, false
local xpListDirty = false     -- neue Erfahrungs-/Kampfdauer-Saetze: nur deren Listen neu sammeln (kein voller Neuaufbau)
local ttkRecs = {}
local nameCount

local function Remote()
    local db = Codex.db
    db.remote = db.remote or {}
    return db.remote
end

function Share.RemoteStats()
    local senders, records = 0, 0
    for _, s in pairs(Remote()) do
        senders = senders + 1
        records = records + (s.n or 0)
    end
    return senders, records
end

-- Mitgelieferte Startdaten (nur im Speicher, nie gespeichert und nie gesendet): Schluessel -> Datensatz
local builtin = { rec = {}, n = 0 }

function Share.HasBuiltin()
    return builtin.n > 0
end

function Share.BuiltinCount()
    return builtin.n
end

function Share.HasRemote()
    return next(Remote()) ~= nil or builtin.n > 0
end

function Share.Sender(name, create)
    local R = Remote()
    local s = R[name]
    if not s and create then
        local count, oldest, oldestT = 0, nil, math.huge
        for key, v in pairs(R) do
            count = count + 1
            if key ~= SELF_IMPORT and (v.seen or 0) < oldestT then
                oldest, oldestT = key, v.seen or 0
            end
        end
        if count >= MAX_SENDERS and oldest then
            R[oldest] = nil
            allDirty = true
        end
        s = { seen = time(), rec = {}, n = 0, cursor = 0 }
        R[name] = s
    end
    return s
end

local function NoteItemNames(nm)
    if type(nm) ~= "table" then
        return
    end
    local names = Codex.db.names
    if not nameCount then
        nameCount = 0
        for _ in pairs(names) do
            nameCount = nameCount + 1
        end
    end
    for id, name in pairs(nm) do
        if names[id] == nil and nameCount < MAX_NAMES then
            names[id] = name
            nameCount = nameCount + 1
        end
    end
end

-- Bereinigten Datensatz eines Absenders speichern. Rueckgabe: true, wenn neu oder neuer
function Share.StoreRecord(name, rec)
    if type(name) ~= "string" or type(rec) ~= "table" or not rec.y then
        return false
    end
    local s = Share.Sender(name, true)
    local key = rec.y .. rec.id
    local old = s.rec[key]
    if old and old.upd >= rec.upd then
        return false
    end
    if rec.y == "g" then
        -- Verkehrsverbindungen nur von Berechtigten (oder aus dem eigenen Import)
        if name ~= SELF_IMPORT and not IsDevSender(name) then return false end
        if not old then
            if (s.np or 0) >= MAX_PATH_RECORDS then return false end
            s.np = (s.np or 0) + 1
        end
        s.rec[key] = rec
        s.seen = time()
        if Codex.Transport then Codex.Transport.rev = (Codex.Transport.rev or 0) + 1 end
        FW:Fire("CODEX_TRANSPORT_CHANGED", rec.id)
        return true
    end
    if rec.y == "f" then
        -- Fluege: von jedem Spieler, je Absender begrenzt
        if not old then
            if (s.nf or 0) >= 600 then return false end
            s.nf = (s.nf or 0) + 1
        end
        s.rec[key] = rec
        s.seen = time()
        if Codex.Flight then Codex.Flight.rev = (Codex.Flight.rev or 0) + 1 end
        FW:Fire("CODEX_FLIGHT_CHANGED", rec.id)
        return true
    end
    if rec.y == "h" then
        -- Ortspunkte nur von Berechtigten (oder aus dem eigenen Import)
        if name ~= SELF_IMPORT and not IsDevSender(name) then return false end
        if not old then
            if (s.np or 0) >= MAX_PATH_RECORDS then return false end
            s.np = (s.np or 0) + 1
        end
        s.rec[key] = rec
        s.seen = time()
        if Codex.Spots then Codex.Spots.Bump(rec.id) end
        return true
    end
    if rec.y == "p" or rec.y == "z" then
        -- Wegenetz: sofort in die gemeinsamen Daten einmischen, vom Absender bleibt nur der Stand
        local P = Codex.Path
        if not P then return false end
        if not old then
            if (s.np or 0) >= MAX_PATH_RECORDS then return false end
            s.np = (s.np or 0) + 1
        end
        if rec.y == "p" then
            local cells = P.ParseChunk(rec.c)
            if not cells then return false end
            P.MergeChunk(rec.id, cells)
        else
            P.MergeLinks(rec.l)
        end
        s.rec[key] = { y = rec.y, id = rec.id, upd = rec.upd }
        s.seen = time()
        return true
    end
    if not old then
        if (s.n or 0) >= MAX_RECORDS then
            return false
        end
        s.n = (s.n or 0) + 1
    end
    -- Aenderungen von Berechtigten melden (das Modul Freewood-Dev schreibt sie ins Protokoll)
    if Codex.DevLog and (rec.cde or rec.cen or rec.bad ~= nil or rec.ed or (old and (old.cde or old.cen or old.bad ~= nil or old.ed))) and IsDevSender(name) then
        local o = old or {}
        for _, f in ipairs({ "cde", "cen", "bad" }) do
            if rec[f] ~= o[f] then
                pcall(Codex.DevLog, { who = name, kind = rec.y, id = rec.id, field = f, old = o[f], new = rec[f], remote = true })
            end
        end
        local nf, of = EdFields(rec.ed), EdFields(o.ed)
        for _, f in ipairs(Share.ED_FIELDS) do
            if nf[f] ~= of[f] then
                pcall(Codex.DevLog, { who = name, kind = rec.y, id = rec.id, field = f, old = of[f], new = nf[f], remote = true })
            end
        end
    end
    NoteItemNames(rec.nm)
    rec.nm = nil
    s.rec[key] = rec
    s.seen = time()
    if rec.y == "x" or rec.y == "t" then
        if view and not allDirty then xpListDirty, xpDirty = true, true else allDirty = true end
    else
        dirtyIds[key] = true
    end
    return true
end

-- Startdaten laden: list = Liste roher Datensaetze { y, id, upd, ... }; jeder geht durch Sanitize
-- (Wegenetz fliesst in die gemeinsamen Daten, alles andere liegt als unterste Schicht im Speicher).
-- Rueckgabe: Anzahl angenommener Datensaetze
function Share.SetBuiltin(list)
    builtin = { rec = {}, n = 0 }
    local accepted = 0
    local P = Codex.Path
    for _, raw in ipairs(list or {}) do
        local key = type(raw) == "table" and type(raw.y) == "string" and type(raw.id) == "number"
            and (raw.y .. math.floor(raw.id)) or nil
        local rec = key and Share.Sanitize(key, raw, raw.upd)
        if rec then
            if rec.y == "p" then
                local cells = P and P.ParseChunk(rec.c)
                if cells then P.MergeChunk(rec.id, cells) accepted = accepted + 1 end
            elseif rec.y == "z" then
                if P and P.MergeLinks(rec.l) then accepted = accepted + 1 end
            else
                builtin.rec[key] = rec
                builtin.n = builtin.n + 1
                accepted = accepted + 1
                if rec.y == "u" or rec.y == "o" then NoteItemNames(rec.nm) end
            end
        end
    end
    view, allDirty = nil, true
    if Codex.Transport then Codex.Transport.rev = (Codex.Transport.rev or 0) + 1 end
    if Codex.Spots then Codex.Spots.Bump() end
    return accepted
end

-- Empfangene Datensaetze einer Art (nur von aktuell berechtigten Absendern, fuer "g")
function Share.RemoteRecords(letter)
    local out = {}
    for _, rec in pairs(builtin.rec) do
        if rec.y == letter and (letter == "g" or letter == "h") then out[#out + 1] = rec end
    end
    for name, s in pairs(Remote()) do
        if (letter ~= "g" and letter ~= "h") or name == SELF_IMPORT or IsDevSender(name) then
            for _, rec in pairs(s.rec) do
                if rec.y == letter then out[#out + 1] = rec end
            end
        end
    end
    return out
end

function Share.HaveRemote(name, key)
    local s = Remote()[name]
    local r = s and s.rec[key]
    return r and r.upd or nil
end

function Share.ClearRemote()
    local R = Remote()
    local count = 0
    for name, s in pairs(R) do
        count = count + (s.n or 0)
        R[name] = nil
    end
    allDirty = true
    view = nil
    if Codex.Path and Codex.Path.ClearRemote then Codex.Path.ClearRemote() end
    if Codex.Transport then Codex.Transport.rev = (Codex.Transport.rev or 0) + 1 end
    if Codex.Spots then Codex.Spots.Bump() end
    return count
end

------------------------------------------------------------------------
-- Zusammenfuehren
------------------------------------------------------------------------

local function AddSample(dst, s)
    dst.n = (dst.n or 0) + s.n
    dst.sum = (dst.sum or 0) + s.sum
    dst.min = dst.min and math.min(dst.min, s.min) or s.min
    dst.max = dst.max and math.max(dst.max, s.max) or s.max
end

local function CopySample(s)
    return { n = s.n, sum = s.sum, min = s.min, max = s.max }
end

local function MergeLevels(dst, src, depth)
    for pl, v in pairs(src or {}) do
        if depth == 1 then
            dst[pl] = dst[pl] or {}
            AddSample(dst[pl], v)
        else
            dst[pl] = dst[pl] or {}
            for ml, s in pairs(v) do
                dst[pl][ml] = dst[pl][ml] or {}
                AddSample(dst[pl][ml], s)
            end
        end
    end
end

local function MergeBucket(dst, src)
    dst.k = (dst.k or 0) + (src.k or 0)
    if src.d then
        dst.d = dst.d or {}
        for id, d in pairs(src.d) do
            local t = dst.d[id]
            if not t then
                t = { n = 0, q = 0 }
                dst.d[id] = t
            end
            t.n = t.n + (d.n or 0)
            t.q = t.q + (d.q or 0)
            if d.qi then
                t.qi = 1
            end
        end
    end
end

local function MergeUnitTTK(dst, src)
    for cls, byPl in pairs(src or {}) do
        dst[cls] = dst[cls] or {}
        for pl, st in pairs(byPl) do
            dst[cls][pl] = dst[cls][pl] or {}
            AddSample(dst[cls][pl], st)
        end
    end
end

local function MergePrices(dst, src)
    for price, n in pairs(src or {}) do
        dst[price] = (dst[price] or 0) + n
    end
end

local function MergeRoles(dst, src)
    for role, n in pairs(src or {}) do
        dst[role] = (dst[role] or 0) + n
    end
end

local function MergeWares(dst, src)
    for id, w in pairs(src or {}) do
        local d = dst[id]
        if not d then
            d = { pr = {} }
            dst[id] = d
        end
        MergePrices(d.pr, w.pr)
        d.st = d.st or w.st
        d.lim = d.lim or w.lim
        d.ec = d.ec or w.ec
    end
end

local function MergeTrain(dst, src)
    for key, r in pairs(src or {}) do
        local d = dst[key]
        if not d then
            d = { pr = {} }
            dst[key] = d
        end
        MergePrices(d.pr, r.pr)
        d.nm = d.nm or r.nm
        d.sp = d.sp or r.sp
        d.rk = d.rk or r.rk
        d.lv = d.lv or r.lv
        d.sn = d.sn or r.sn
        d.sr = d.sr or r.sr
    end
end

local function MergeFlights(dst, src)
    for dest, pr in pairs(src or {}) do
        dst[dest] = dst[dest] or {}
        MergePrices(dst[dest], pr)
    end
end

-- Namen und Markierung kommen nur von berechtigten Absendern; bei mehreren gilt der neueste Stand,
-- eigene Werte gehen vor. Die Absender-Datensaetze bleiben unveraendert (ein gesperrter Absender wird so wieder wirksam).
local function MergeEditorFields(m, e)
    if m._init == nil then
        m._init = true
        local editor = CanEditNames()
        m._ownName = editor and (m.cde ~= nil or m.cen ~= nil)
        if not editor then m.bad = nil end
        m._ownBad = editor and m.bad ~= nil
        if not editor then m.ed = nil end
        m._ownEd = editor and m.ed ~= nil
    end
    local r = e.rec
    if not IsDevSender(e.s) then return end
    if r.ed and not m._ownEd and (not m._edUpd or r.upd > m._edUpd) then
        m.ed, m._edUpd = EdFromWire(r.ed), r.upd
    end
    if (r.cde or r.cen) and not m._ownName and (not m._nameUpd or r.upd > m._nameUpd) then
        m.cde, m.cen, m._nameUpd = r.cde, r.cen, r.upd
    end
    if r.bad ~= nil and not m._ownBad and (not m._badUpd or r.upd > m._badUpd) then
        m.bad, m._badUpd = r.bad == 1, r.upd
    end
end

local function MergeEntity(own, list)
    local m = {}
    local remoteK = 0
    if own then
        m.n, m.l1, m.l2, m.c, m.f = own.n, own.l1, own.l2, own.c, own.f
        m.cde, m.cen = own.cde, own.cen
        m.bad = own.bad
        m.ed = own.ed
        if own.iz then
            m.iz = {}
            for id, n in pairs(own.iz) do m.iz[id] = n end
        end
        m.coin, m.coinN = own.coin, own.coinN
        m.cells = {}
        for key, n in pairs(own.cells or {}) do
            m.cells[key] = n
        end
        MergeBucket(m, own)
        if own.alt then
            m.alt = {}
            MergeBucket(m.alt, own.alt)
        end
        m.xm, m.xp = {}, {}
        MergeLevels(m.xm, own.xm, 2)
        MergeLevels(m.xp, own.xp, 1)
        m.tt = {}
        MergeUnitTTK(m.tt, own.tt)
        m.ro, m.wa, m.tr, m.fl = {}, {}, {}, {}
        MergeRoles(m.ro, own.ro)
        MergeWares(m.wa, own.wa)
        MergeTrain(m.tr, own.tr)
        MergeFlights(m.fl, own.fl)
        m.ti, m.fn, m.trc = own.ti, own.fn, own.trc
    else
        m.cells, m.xm, m.xp, m.tt = {}, {}, {}, {}
        m.ro, m.wa, m.tr, m.fl = {}, {}, {}, {}
    end
    for _, e in ipairs(list) do
        local r = e.rec
        m.n = m.n or r.n
        MergeEditorFields(m, e)
        m.f = m.f or r.f
        m.c = m.c or r.c
        if r.iz then
            m.iz = m.iz or {}
            local cnt = 0
            for _ in pairs(m.iz) do cnt = cnt + 1 end
            for id, n in pairs(r.iz) do
                if m.iz[id] or cnt < 3 then
                    if not m.iz[id] then cnt = cnt + 1 end
                    m.iz[id] = (m.iz[id] or 0) + n
                end
            end
        end
        if r.l1 then m.l1 = m.l1 and math.min(m.l1, r.l1) or r.l1 end
        if r.l2 then m.l2 = m.l2 and math.max(m.l2, r.l2) or r.l2 end
        if r.coinN and r.coinN > 0 then
            m.coin = (m.coin or 0) + (r.coin or 0)
            m.coinN = (m.coinN or 0) + r.coinN
        end
        for key, n in pairs(r.cells or {}) do
            m.cells[key] = (m.cells[key] or 0) + n
        end
        MergeBucket(m, r)
        remoteK = remoteK + (r.k or 0)
        if r.alt then
            m.alt = m.alt or {}
            MergeBucket(m.alt, r.alt)
        end
        MergeLevels(m.xm, r.xm, 2)
        MergeUnitTTK(m.tt, r.tt)
        MergeRoles(m.ro, r.ro)
        MergeWares(m.wa, r.wa)
        MergeTrain(m.tr, r.tr)
        MergeFlights(m.fl, r.fl)
        m.ti = m.ti or r.ti
        m.trc = m.trc or r.trc
        m.fn = m.fn or r.fn
    end
    if next(m.ro) == nil then m.ro = nil end
    if next(m.wa) == nil then m.wa = nil end
    if next(m.tr) == nil then m.tr = nil end
    if Codex.LearnPlanReset then Codex.LearnPlanReset() end
    if next(m.fl) == nil then m.fl = nil end
    if next(m.tt) == nil then m.tt = nil end
    if next(m.cells) == nil then m.cells = nil end
    if next(m.xm) == nil then m.xm = nil end
    if next(m.xp) == nil then m.xp = nil end
    m.rk = remoteK > 0 and remoteK or nil
    m.remote = #list
    m.k = m.k or nil
    return m
end

local function PlusSample(a, b)
    if not b then return a end
    if not a then return CopySample(b) end
    local out = CopySample(a)
    AddSample(out, b)
    return out
end

local function MergeQuest(own, list)
    local m = {}
    if own then
        for k, v in pairs(own) do
            m[k] = v
        end
    end
    local objCopied = false
    for _, e in ipairs(list) do
        local r = e.rec
        MergeEditorFields(m, e)
        for _, f in ipairs({ "t", "lvl", "pl", "zone", "give", "turn", "si", "xp", "money", "rep", "fixed", "choice", "mn", "rc", "cl" }) do
            if m[f] == nil then
                m[f] = r[f]
            end
        end
        if r.pi and r.po then
            -- Beobachtungen zusammenzaehlen (neue Tabelle, die eigene bleibt unveraendert)
            local pi = {}
            for k, v in pairs(m.pi or {}) do pi[k] = v end
            local count = 0
            for _ in pairs(pi) do count = count + 1 end
            for k, v in pairs(r.pi) do
                if pi[k] or count < 8 then
                    if not pi[k] then count = count + 1 end
                    pi[k] = (pi[k] or 0) + v
                end
            end
            m.pi, m.po = pi, (m.po or 0) + r.po
        end
        if r.mi then
            local mi = m.mi
            if mi then
                local lo, hi = math.max(mi.lo, r.mi.lo), math.min(mi.hi, r.mi.hi)
                if hi > lo then m.mi = { lo = lo, hi = hi, n = (mi.n or 1) + (r.mi.n or 1) } end
            else
                m.mi = r.mi
            end
        end
        if r.pre then
            -- Vorquests vereinen
            local have, merged = {}, {}
            for _, p in ipairs(m.pre or {}) do have[p] = true merged[#merged + 1] = p end
            for _, p in ipairs(r.pre) do
                if not have[p] and #merged < 8 then have[p] = true merged[#merged + 1] = p end
            end
            m.pre = merged
        end
        for _, f in ipairs({ "tm", "tr", "ta" }) do
            if r[f] then m[f] = PlusSample(m[f], r[f]) end
        end
        if r.obj then
            if not m.obj then
                m.obj = r.obj
                objCopied = false
            else
                for i, ro in ipairs(r.obj) do
                    local mo = m.obj[i]
                    if mo and (not mo.ty or not ro.ty or mo.ty == ro.ty) and
                        ((not mo.name and ro.name) or (not mo.item and ro.item) or (not mo.ids and ro.ids)) then
                        if not objCopied then
                            local copy = {}
                            for j, o in ipairs(m.obj) do
                                local c = {}
                                for k, v in pairs(o) do c[k] = v end
                                copy[j] = c
                            end
                            m.obj = copy
                            objCopied = true
                        end
                        mo = m.obj[i]
                        mo.ty = mo.ty or ro.ty
                        mo.name = mo.name or ro.name
                        mo.txt = mo.txt or ro.txt
                        mo.req = mo.req or ro.req
                        mo.item = mo.item or ro.item
                        mo.ids = mo.ids or ro.ids
                    end
                end
            end
        end
        if r.qi then
            local copy = {}
            for item, srcs in pairs(m.qi or {}) do
                copy[item] = {}
                for k, v in pairs(srcs) do copy[item][k] = v end
            end
            for item, srcs in pairs(r.qi) do
                copy[item] = copy[item] or {}
                for k, v in pairs(srcs) do
                    copy[item][k] = math.max(copy[item][k] or 0, v)
                end
            end
            m.qi = copy
        end
    end
    if not own then
        m.seen, m.done, m.first, m.last = 0, 0, nil, nil
        m.rem = true
    end
    return m
end

local function BuildXP()
    local db = Codex.db
    local xp = {}
    if #xpRecs > 0 then
        for pl, byMl in pairs(db.xp or {}) do
            for ml, byCls in pairs(byMl) do
                for cls, s in pairs(byCls) do
                    xp[pl] = xp[pl] or {}
                    xp[pl][ml] = xp[pl][ml] or {}
                    xp[pl][ml][cls] = CopySample(s)
                end
            end
        end
        for _, rec in ipairs(xpRecs) do
            for pl, byMl in pairs(rec.xp or {}) do
                for ml, byCls in pairs(byMl) do
                    for cls, s in pairs(byCls) do
                        xp[pl] = xp[pl] or {}
                        xp[pl][ml] = xp[pl][ml] or {}
                        xp[pl][ml][cls] = xp[pl][ml][cls] or {}
                        AddSample(xp[pl][ml][cls], s)
                    end
                end
            end
        end
        view.xp = xp
    else
        view.xp = db.xp
    end
    xpDirty = false
end

local function BuildTTK()
    local db = Codex.db
    if #ttkRecs == 0 then
        view.ttk = db.ttk
        return
    end
    local tk = {}
    local function Add(src)
        for cls, byPl in pairs(src or {}) do
            for pl, byDelta in pairs(byPl) do
                for d, sm in pairs(byDelta) do
                    tk[cls] = tk[cls] or {}
                    tk[cls][pl] = tk[cls][pl] or {}
                    tk[cls][pl][d] = PlusSample(tk[cls][pl][d], sm)
                end
            end
        end
    end
    Add(db.ttk)
    for _, rec in ipairs(ttkRecs) do
        Add(rec.tk)
    end
    view.ttk = tk
end

-- Nur die Listen der Erfahrungs- und Kampfdauer-Saetze neu sammeln (ohne Zusammenfuehren aller Kreaturen, Objekte, Quests)
local function CollectXP()
    xpRecs, ttkRecs = {}, {}
    local names = {}
    for name in pairs(Remote()) do names[#names + 1] = name end
    table.sort(names)
    for _, name in ipairs(names) do
        for _, rec in pairs(Remote()[name].rec) do
            if rec.y == "x" then xpRecs[#xpRecs + 1] = rec elseif rec.y == "t" then ttkRecs[#ttkRecs + 1] = rec end
        end
    end
    local bkeys = {}
    for key, rec in pairs(builtin.rec) do
        if rec.y == "x" or rec.y == "t" then bkeys[#bkeys + 1] = key end
    end
    table.sort(bkeys)
    for _, key in ipairs(bkeys) do
        local rec = builtin.rec[key]
        if rec.y == "x" then xpRecs[#xpRecs + 1] = rec else ttkRecs[#ttkRecs + 1] = rec end
    end
    xpListDirty = false
end

local function Rebuild()
    local db = Codex.db
    index = { u = {}, o = {}, q = {}, i = {} }
    xpRecs = {}
    ttkRecs = {}
    local names = {}
    for name in pairs(Remote()) do
        names[#names + 1] = name
    end
    table.sort(names)
    for _, name in ipairs(names) do
        local s = Remote()[name]
        for _, rec in pairs(s.rec) do
            if rec.y == "x" then
                xpRecs[#xpRecs + 1] = rec
            elseif rec.y == "t" then
                ttkRecs[#ttkRecs + 1] = rec
            elseif rec.y == "p" or rec.y == "z" or rec.y == "g" or rec.y == "h" or rec.y == "f" then
                -- Wegenetz liegt schon in den gemeinsamen Daten (Codex.Path), Verkehrsverbindungen liest Codex.Transport
            else
                local bucket = index[rec.y]
                bucket[rec.id] = bucket[rec.id] or {}
                local list = bucket[rec.id]
                list[#list + 1] = { s = name, rec = rec }
            end
        end
    end
    -- Startdaten ganz unten (nach allen Absendern)
    local bkeys = {}
    for key in pairs(builtin.rec) do bkeys[#bkeys + 1] = key end
    table.sort(bkeys)
    for _, key in ipairs(bkeys) do
        local rec = builtin.rec[key]
        if rec.y == "x" then
            xpRecs[#xpRecs + 1] = rec
        elseif rec.y == "t" then
            ttkRecs[#ttkRecs + 1] = rec
        elseif index[rec.y] then
            local bucket = index[rec.y]
            bucket[rec.id] = bucket[rec.id] or {}
            table.insert(bucket[rec.id], { s = BUILTIN, rec = rec })
        end
    end
    view = { quests = {}, units = {}, objects = {}, ied = {}, xpb = db.xpb, names = db.names }
    for letter, field in pairs(KIND_OF) do
        local out = view[field]
        for id, e in pairs(db[field]) do
            out[id] = e.ed and Codex.ApplyEd(e, field) or e
        end
        for id, list in pairs(index[letter]) do
            local merged
            if letter == "q" then
                merged = MergeQuest(db[field][id], list)
            else
                merged = MergeEntity(db[field][id], list)
            end
            if merged.bad == true and not CanEditNames() then merged = nil end
            if merged then merged = Codex.ApplyEd(merged, field, true) end
            out[id] = merged
        end
    end
    BuildXP()
    BuildTTK()
    allDirty = false
    xpListDirty = false
    dirtyIds = {}
end

local function Refresh(key)
    local letter, num = key:match("^([uoqi])(%d+)$")
    if not letter then
        return
    end
    local id = tonumber(num)
    local field = KIND_OF[letter]
    local list = index[letter][id]
    -- neue Fremd-Eintraege in den Index aufnehmen
    list = nil
    for name, s in pairs(Remote()) do
        local rec = s.rec[key]
        if rec then
            list = list or {}
            list[#list + 1] = { s = name, rec = rec }
        end
    end
    if list then
        table.sort(list, function(a, b) return a.s < b.s end)
    end
    if builtin.rec[key] then
        list = list or {}
        list[#list + 1] = { s = BUILTIN, rec = builtin.rec[key] }
    end
    index[letter][id] = list
    local own = Codex.db[field][id]
    if list then
        local merged = letter == "q" and MergeQuest(own, list) or MergeEntity(own, list)
        if merged.bad == true and not CanEditNames() then merged = nil end
        if merged then merged = Codex.ApplyEd(merged, field, true) end
        view[field][id] = merged
    else
        view[field][id] = own and own.ed and Codex.ApplyEd(own, field) or own
    end
end

-- Sicht fuer die Anzeige: Felder quests, units, objects, xp, xpb, names
-- Berechtigungen haben sich geaendert: Sicht neu aufbauen
function Share.TrustChanged()
    allDirty = true
end

-- Eigene Eigenschaften (ed) muessen auch ohne fremde Daten in die Sicht
local hasEd
function Share.HasEd()
    if hasEd == nil then
        hasEd = false
        -- aeltere Form der Item-Eigenschaften (ohne Huelle ed) umwandeln
        for id, e in pairs(Codex.db.ied or {}) do
            if e.ed == nil and (e.z or e.dg ~= nil) then Codex.db.ied[id] = { ed = e } end
        end
        for _, field in ipairs({ "units", "objects", "quests", "ied" }) do
            for _, e in pairs(Codex.db[field] or {}) do
                if e.ed then hasEd = true break end
            end
            if hasEd then break end
        end
    end
    return hasEd
end

function Share.NoteEd(present)
    if present then hasEd = true else hasEd = nil end   -- nil: beim naechsten Mal neu pruefen
    view, allDirty = nil, true
end

function Share.View()
    if not Share.HasRemote() and not Share.HasEd() then
        view, allDirty = nil, true
        return Codex.db
    end
    if not view or allDirty then
        Rebuild()
    elseif xpDirty then
        if xpListDirty then CollectXP() end
        BuildXP()
        BuildTTK()
    end
    if next(dirtyIds) then
        local ids = dirtyIds
        dirtyIds = {}
        for key in pairs(ids) do
            Refresh(key)
        end
    end
    return view
end

-- Eigene Aenderung: nur noetig, wenn es zu diesem Datensatz fremde Daten gibt oder er in der Sicht fehlt
function Share.OnChanged(kind, id)
    if not view then
        return
    end
    if kind == "xp" or kind == "ttk" then
        if #xpRecs > 0 or #ttkRecs > 0 then
            xpDirty = true
        end
        return
    end
    local letter = LETTER_OF[kind]
    if letter and type(id) == "number" then
        local field = KIND_OF[letter]
        if view[field][id] == nil or index[letter][id] then
            dirtyIds[letter .. id] = true
        end
    end
end

FW:On("CODEX_CHANGED", function(_, kind, id)
    Share.OnChanged(kind, id)
end, Share)

-- Gemessene Kampfdauer in Sekunden und Anzahl fuer (Klasse, Spielerstufe, Stufenabstand)
function Share.TTKMeasured(cls, pl, delta)
    local tk = Share.View().ttk
    local s = tk and tk[cls] and tk[cls][pl] and tk[cls][pl][delta]
    if not s or not s.n or s.n < 1 then
        return nil
    end
    return s.sum / s.n / 10, s.n
end

-- Kampfdauer aller Klassen bei (Spielerstufe, Stufenabstand): Liste { cls, secs, n } nach Dauer sortiert
function Share.TTKClasses(pl, delta)
    local list = {}
    local tk = Share.View().ttk
    for cls, byPl in pairs(tk or {}) do
        local s = byPl[pl] and byPl[pl][delta]
        if s and s.n and s.n > 0 then
            list[#list + 1] = { cls = cls, secs = s.sum / s.n / 10, n = s.n }
        end
    end
    table.sort(list, function(a, b)
        if a.secs ~= b.secs then return a.secs < b.secs end
        return a.cls < b.cls
    end)
    return list
end

-- Gemessene Erfahrung fuer (Spielerstufe, Gegnerstufe, Klasse): Mittelwert und Anzahl,
-- nur wenn die Messwerte zusammenpassen
function Share.XPMeasured(pl, ml, cls)
    local xp = Share.View().xp
    local s = xp and xp[pl] and xp[pl][ml] and xp[pl][ml][cls]
    if not s or not s.n or s.n < 1 then
        return nil
    end
    local avg = s.sum / s.n
    if (s.max - s.min) > math.max(2, avg * 0.1) then
        return nil
    end
    return math.floor(avg + 0.5), s.n
end

------------------------------------------------------------------------
-- Export und Import als Code
------------------------------------------------------------------------

-- Empfangene Datensaetze aller Absender (je Schluessel der neueste), fuer berechtigte Bearbeiter
local function ReceivedRecords(limit, skip)
    local best = {}
    for _, s in pairs(Remote()) do
        for key, rec in pairs(s.rec) do
            if rec.y ~= "p" and rec.y ~= "z" and not skip[key] and (not best[key] or rec.upd > best[key].upd) then
                best[key] = rec
            end
        end
    end
    local list = {}
    for _, rec in pairs(best) do list[#list + 1] = rec end
    table.sort(list, function(a, b)
        if a.upd ~= b.upd then return a.upd > b.upd end
        return (a.y .. a.id) < (b.y .. b.id)
    end)
    local out = {}
    for i = 1, math.min(#list, limit) do out[i] = list[i] end
    return out
end

local function ExportList(limit, withReceived)
    local list = Share.Scan(true)
    table.sort(list, function(a, b)
        if a.upd ~= b.upd then
            return a.upd > b.upd
        end
        return a.key < b.key
    end)
    local out, have = {}, {}
    for i = 1, math.min(#list, limit) do
        local rec = Share.OwnRecord(list[i].key)
        if rec then
            out[#out + 1] = rec
            have[list[i].key] = true
        end
    end
    if withReceived and #out < limit then
        for _, rec in ipairs(ReceivedRecords(limit - #out, have)) do
            out[#out + 1] = rec
        end
    end
    return out
end

-- withReceived: auch empfangene Daten anderer Spieler (nur fuer Berechtigte mit Modul Freewood-Dev)
function Share.ExportData(withReceived)
    if withReceived and not (Codex.Trust and Codex.Trust.Can("export")) then
        return {}
    end
    local limit = 1500
    local data
    repeat
        data = { list = ExportList(limit, withReceived) }
        local ok = true
        if FW.Export and FW.Export.Encode then
            local text = FW.Export.Encode("codex", data)
            ok = text ~= nil
        end
        if ok or limit <= 25 or #data.list == 0 then
            break
        end
        limit = math.floor(limit / 2)
    until false
    if #data.list == 0 then
        return {}
    end
    return data
end

function Share.ValidateImport(data)
    return type(data) == "table" and type(data.list) == "table" and #data.list > 0 and #data.list <= 5000
end

function Share.ImportData(data)
    local L = FW.L
    local added, skipped = 0, 0
    for _, raw in ipairs(data.list or {}) do
        local key = type(raw) == "table" and type(raw.y) == "string" and type(raw.id) == "number"
            and (raw.y .. math.floor(raw.id)) or nil
        local rec = key and Share.Sanitize(key, raw, raw.upd)
        if rec and Share.StoreRecord(SELF_IMPORT, rec) then
            added = added + 1
        else
            skipped = skipped + 1
        end
    end
    FW:Fire("CODEX_CHANGED", "import")
    return string.format(L.CODEX_IMPORT_STATS, added, skipped)
end

if FW.Export and FW.Export.RegisterHandler then
    FW.Export.RegisterHandler("codex", {
        label = function()
            return FW.L.CODEX_EXPORT_LABEL
        end,
        export = function()
            return Share.ExportData()
        end,
        validate = function(data)
            return Share.ValidateImport(data)
        end,
        import = function(data)
            return Share.ImportData(data)
        end,
    })
end
