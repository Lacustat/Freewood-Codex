-- Freewood-Codex: Wegenetz. Zeichnet auf, wo Spieler zu Fuss gegangen sind, als Raster aus Zellen mit Richtungen.
--
-- Eine Zelle (CELL Yards Kantenlaenge) ist begehbar, sobald jemand zu Fuss darauf stand. Die Kanten (Schritte zu den
-- 8 Nachbarzellen) sagen, wie man von dort weitergekommen ist. Faelle werden als Einbahn-Kanten gespeichert.
-- Daraus kann der Plan spaeter Wege suchen (Hindernisse sind automatisch bekannt, weil niemand durch sie geht).
--
-- Gespeichert wird nur bei Bewegung zu Fuss. Ausgeschlossen: Instanzen, Reittier, Flug, Taxi, freier Fall und
-- Auren, die Boden oder Wasser vortaeuschen (Levitieren, Leichter Fall, Wasserwandeln, Gleiter ...), ausserdem
-- unplausible Spruenge (Teleport, Ladebildschirm) und zu hohes Lauftempo.
--
-- Datenform: db.path[welt][zellKey] = Maske
--   Bit 0-7   Richtungen, in die man aus der Zelle gegangen ist (O, NO, N, NW, W, SW, S, SO)
--   Bit 8-15  davon Faelle (nur in diese Richtung)
--   Bit 16    Zelle besucht
-- Zellkey = (cx + OFFSET) * 65536 + (cy + OFFSET). welt = Instanz-/Kontinent-ID aus UnitPosition.
-- db.pathz[welt][zellKey] = Hoehe in 4-Yard-Schritten, nur wenn das Spiel eine Hoehe liefert (sonst 0).
-- Gebietsuebergaenge: db.zlink[von][nach][art] = { n = Anzahl, p = { { fw, fk, tw, tk }, ... } } (bis 4 Punkte)
--   art "w" zu Fuss/Reittier ueber die Grenze (Nachbargebiete), "t" Sprung (Zeppelin, Schiff, Portal), "f" Flugpunkt,
--   "i" Instanz (nach = negative Instanz-ID; Eingang mit Startpunkt, Ausgang mit Zielpunkt).
--   von/nach sind Karten-IDs wie in den Gebieten des Codex. fw/fk = Welt und Zellkey des Startpunkts, tw/tk des Ziels.
-- Nur lokal (wird noch nicht geteilt).

local ADDON, NS = ...

local FW = _G.Freewood
if not FW or not FW:RequireAPI(1, ADDON) then
    return
end

local Codex = NS and NS.Codex
if not Codex then
    return
end

local Util = FW.Util
local Path = {}
Codex.Path = Path

local CELL = 10              -- Yards je Zelle
local OFFSET = 30000
local TICK = 1               -- Sekunden zwischen zwei Messungen
local MAX_STEP_CELLS = 3     -- weiter auseinander liegende Messungen gelten als Sprung (Teleport)
local MAX_SPEED = 18         -- Yards pro Sekunde (Reittier mit +150 % = 17,5); schneller = Effekt oder Teleport, nicht aufzeichnen
local MIN_FALL = 1.2         -- Sekunden Fall, ab denen es ein Fall ist (kein Sprung)
local MAX_CELLS = 300000

-- Richtungen als (dx, dy) in der Reihenfolge der Bits
local DIRS = { { 1, 0 }, { 1, 1 }, { 0, 1 }, { -1, 1 }, { -1, 0 }, { -1, -1 }, { 0, -1 }, { 1, -1 } }
local DIR_OF = {}
for i, d in ipairs(DIRS) do DIR_OF[d[1] .. ":" .. d[2]] = i - 1 end
Path.DIRS = DIRS
Path.CELL = CELL

-- Auren, bei denen keine Daten aufgezeichnet werden (Zauber-IDs, Klassik) ...
Path.SKIP_AURAS = {
    [130] = true,     -- Leichter Fall
    [1706] = true,    -- Levitieren
    [546] = true,     -- Wasserwandeln
    [3714] = true,    -- Pfad des Frosts
    [13141] = true,   -- Gnomen-Raketenstiefel
    [11359] = true,   -- Fallschirm
}
-- ... und nach Namen (fuer Aurenen, deren ID wir nicht kennen, zum Beispiel das Gleiten einer neuen Rasse)
local SKIP_WORDS = { "levit", "leichter fall", "slow fall", "wasserwand", "water walk", "gleit", "glide", "gliding", "fallschirm", "parachute", "schweb", "hover" }

local LINK_POINTS = 4
local WALK_CELLS = 12        -- Wechsel mit hoechstens so vielen Zellen Abstand (120 Yards) gelten als Grenzuebergang

local state = { acc = 0, last = nil, fallT = 0, fallFrom = nil, reasons = {}, added = 0, samples = 0 }
Path.state = state

local function DB()
    local db = Codex.db
    if not db then return nil end
    db.path = db.path or {}
    return db
end

local function Reject(reason)
    state.reasons[reason] = (state.reasons[reason] or 0) + 1
end

function Path.Enabled()
    local db = Codex.db
    return db and db.settings and db.settings.path ~= false
end

function Path.SetEnabled(v)
    local db = Codex.db
    if db and db.settings then db.settings.path = v and true or false end
end

local function CellOf(x, y)
    return math.floor(x / CELL), math.floor(y / CELL)
end

local function Key(cx, cy)
    return (cx + OFFSET) * 65536 + (cy + OFFSET)
end

function Path.KeyToCell(key)
    return math.floor(key / 65536) - OFFSET, key % 65536 - OFFSET
end

------------------------------------------------------------------------
-- Teilen: Wegenetz in Bloecken von 16 x 16 Zellen (160 Yards), Gebietsuebergaenge als ein Datensatz
------------------------------------------------------------------------

local CHUNK = 16
local MAX_REMOTE_CELLS = 400000
local MAX_LINKS_SHARED = 600
local mergedCells, linkCache = {}, nil

local function ChunkId(world, cx, cy)
    if type(world) ~= "number" or world < 0 or world >= 1000000 then return nil end
    local gx, gy = math.floor(cx / CHUNK) + 128, math.floor(cy / CHUNK) + 128
    if gx < 0 or gx > 255 or gy < 0 or gy > 255 then return nil end
    return world * 65536 + gx * 256 + gy
end

local function ChunkParts(id)
    local world = math.floor(id / 65536)
    local r = id % 65536
    return world, math.floor(r / 256), r % 256
end

-- Bitweises Oder fuer 17-Bit-Masken (ohne bit-Bibliothek)
local function Or17(a, b)
    if a == b or b == 0 then return a end
    if a == 0 then return b end
    local r, p = 0, 1
    for _ = 0, 16 do
        local x, y = a % 2, b % 2
        if x == 1 or y == 1 then r = r + p end
        a, b, p = (a - x) / 2, (b - y) / 2, p * 2
    end
    return r
end

local function Dirty(db, world, cx, cy)
    local id = ChunkId(world, cx, cy)
    if not id then return end
    db.pathsync = db.pathsync or {}
    local now = _G.time and _G.time() or 0
    db.pathsync[id] = math.max(now, (db.pathsync[id] or 0) + 1)
    mergedCells[world] = nil
    Path.rev = (Path.rev or 0) + 1
end

local function Count(db)
    if db.pathCount then return db.pathCount end
    local n = 0
    for _, w in pairs(db.path) do
        for _ in pairs(w) do n = n + 1 end
    end
    db.pathCount = n
    return n
end

-- Zelle markieren; dirIndex = Richtung, in die es weiterging (optional), drop = Fall
local function Mark(world, cx, cy, dirIndex, drop, z)
    local db = DB()
    if not db then return end
    local w = db.path[world]
    if not w then w = {}; db.path[world] = w end
    local k = Key(cx, cy)
    local m = w[k]
    if not m then
        if Count(db) >= MAX_CELLS then Reject("voll") return end
        m = 0
        db.pathCount = Count(db) + 1
        state.added = state.added + 1
    end
    local newm = m
    if newm < 65536 then newm = newm + 65536 end   -- besucht
    if dirIndex then
        local bit = 2 ^ dirIndex
        if math.floor(newm / bit) % 2 == 0 then newm = newm + bit end
        if drop then
            local dbit = 2 ^ (dirIndex + 8)
            if math.floor(newm / dbit) % 2 == 0 then newm = newm + dbit end
        end
    end
    w[k] = newm
    if newm ~= m then Dirty(db, world, cx, cy) end
    if z and z ~= 0 then
        db.pathz = db.pathz or {}
        db.pathz[world] = db.pathz[world] or {}
        db.pathz[world][k] = math.floor(z / 4 + 0.5)
    end
end

-- Zellen entlang der Strecke von (ax,ay) nach (bx,by) (einschliesslich beider), je Schritt hoechstens ein Nachbar
local function Line(ax, ay, bx, by)
    local cells = { { ax, ay } }
    local x, y = ax, ay
    local n = 0
    while (x ~= bx or y ~= by) and n < 10 do
        x = x + (bx > x and 1 or (bx < x and -1 or 0))
        y = y + (by > y and 1 or (by < y and -1 or 0))
        cells[#cells + 1] = { x, y }
        n = n + 1
    end
    return cells
end

-- Strecke zwischen zwei Messungen eintragen
local function Connect(world, a, b, drop, z)
    local cells = Line(a.cx, a.cy, b.cx, b.cy)
    for i = 1, #cells do
        local c = cells[i]
        local nxt = cells[i + 1]
        local di
        local isDrop = false
        if nxt then
            di = DIR_OF[(nxt[1] - c[1]) .. ":" .. (nxt[2] - c[2])]
            isDrop = drop and i == 1
        end
        Mark(world, c[1], c[2], di, isDrop, (i == #cells) and z or nil)
    end
end

-- Hat der Spieler eine Aura, die Boden oder Wasser vortaeuscht?
local function SkipAura()
    local CU = _G.C_UnitAuras
    local function Check(name, id)
        if id and Path.SKIP_AURAS[id] then return true end
        if type(name) == "string" and not (Util and Util.IsSecret and Util.IsSecret(name)) then
            local low = name:lower()
            for _, w in ipairs(SKIP_WORDS) do
                if low:find(w, 1, true) then return true end
            end
        end
        return false
    end
    if CU and CU.GetAuraDataByIndex then
        for i = 1, 40 do
            local ok, a = pcall(CU.GetAuraDataByIndex, "player", i, "HELPFUL")
            if not ok or type(a) ~= "table" then break end
            if Check(a.name, a.spellId) then return true end
        end
        return false
    end
    if _G.UnitBuff then
        for i = 1, 40 do
            local ok, name, _, _, _, _, _, _, _, _, id = pcall(_G.UnitBuff, "player", i)
            if not ok or not name then break end
            if Check(name, id) then return true end
        end
    end
    return false
end

------------------------------------------------------------------------
-- Gebietsuebergaenge
------------------------------------------------------------------------

local function Flag(fn, ...)
    if type(fn) ~= "function" then return false end
    local ok, v = pcall(fn, ...)
    return ok and v and true or false
end


local function Here(pos)
    if not pos then return nil end
    local cx, cy = CellOf(pos.x, pos.y)
    return { world = pos.world, key = Key(cx, cy) }
end

local function CurrentMap()
    local CM = _G.C_Map
    if not (CM and CM.GetBestMapForUnit) then return nil end
    local ok, m = pcall(CM.GetBestMapForUnit, "player")
    if not ok or type(m) ~= "number" or (Util and Util.IsSecret and Util.IsSecret(m)) then return nil end
    return m
end

local function Link(a, b, kind, from, to)
    local db = DB()
    if not db or a == b then return end
    db.zlink = db.zlink or {}
    local la = db.zlink[a]
    if not la then la = {}; db.zlink[a] = la end
    local lb = la[b]
    if not lb then lb = {}; la[b] = lb end
    local e = lb[kind]
    if not e then e = { n = 0, p = {} }; lb[kind] = e end
    linkCache = nil
    e.n = e.n + 1
    local p = { fw = from and from.world, fk = from and from.key, tw = to and to.world, tk = to and to.key }
    if #e.p < LINK_POINTS then
        for _, q in ipairs(e.p) do
            if q.fk == p.fk and q.tk == p.tk then return end
        end
        e.p[#e.p + 1] = p
    end
end

-- Benachbarte Gebiete: Liste { map, n, kinds = { w, t, f, i } } (beide Richtungen zusammen)
function Path.Neighbors(map)
    local db = Codex.db
    local out, idx = {}, {}
    local function Add(other, kinds)
        local e = idx[other]
        if not e then e = { map = other, n = 0, kinds = {} }; idx[other] = e; out[#out + 1] = e end
        for kind, v in pairs(kinds) do
            e.kinds[kind] = (e.kinds[kind] or 0) + v.n
            e.n = e.n + v.n
        end
    end
    for a, row in pairs(Path.Links()) do
        for b, kinds in pairs(row) do
            if a == map then Add(b, kinds) elseif b == map then Add(a, kinds) end
        end
    end
    table.sort(out, function(x, y) return x.n > y.n end)
    return out
end

-- Uebergangspunkte von a nach b: Liste { fw, fk, tw, tk } je Art, oder nil
function Path.Crossings(a, b, kind)
    local db = Codex.db
    local L = Path.Links()
    local e = L[a] and L[a][b] and L[a][b][kind or "w"]
    return e and e.p or nil
end

function Path.ClearRemote()
    local db = Codex.db
    if not db then return end
    db.pathr, db.pathrCount, db.zlinkr = nil, nil, nil
    mergedCells, linkCache = {}, nil
    Path.rev = (Path.rev or 0) + 1
end

-- Eigene und empfangene Zellen einer Welt (Maske = Oder beider). Ohne Fremddaten ist das die eigene Tabelle.
function Path.Cells(world)
    local db = Codex.db
    if not db then return nil end
    local own = db.path and db.path[world]
    local rem = db.pathr and db.pathr[world]
    if not rem then return own end
    if not own then return rem end
    local m = mergedCells[world]
    if m then return m end
    m = {}
    for k, v in pairs(rem) do m[k] = v end
    for k, v in pairs(own) do m[k] = m[k] and Or17(m[k], v) or v end
    mergedCells[world] = m
    return m
end

local function MergeLinkInto(out, a, b, kind, n, pts, cap)
    out[a] = out[a] or {}
    out[a][b] = out[a][b] or {}
    local t = out[a][b][kind]
    if not t then
        t = { n = n, p = {} }
        out[a][b][kind] = t
    else
        t.n = math.max(t.n, n)
    end
    for _, p in ipairs(pts or {}) do
        local dup = false
        for _, q in ipairs(t.p) do
            if q.fk == p.fk and q.tk == p.tk then dup = true break end
        end
        if not dup and #t.p < cap then t.p[#t.p + 1] = p end
    end
end

-- Eigene und empfangene Gebietsuebergaenge zusammen
function Path.Links()
    local db = Codex.db
    if not db then return {} end
    if not (db.zlinkr and next(db.zlinkr)) then return db.zlink or {} end
    if linkCache then return linkCache end
    local out = {}
    for _, src in ipairs({ db.zlink or {}, db.zlinkr }) do
        for a, row in pairs(src) do
            for b, kinds in pairs(row) do
                for kind, e in pairs(kinds) do MergeLinkInto(out, a, b, kind, e.n, e.p, 8) end
            end
        end
    end
    linkCache = out
    return out
end

------------------------------------------------------------------------
-- Teilen: eigene Bloecke, Pruefen und Einmischen
------------------------------------------------------------------------

-- Staende der eigenen Bloecke einmalig anlegen (Daten, die vor dem Teilen aufgezeichnet wurden)
function Path.EnsureStamps()
    local db = Codex.db
    if not db or db.pathStamped then return end
    db.pathsync = db.pathsync or {}
    local now = _G.time and _G.time() or 0
    for world, w in pairs(db.path or {}) do
        for key in pairs(w) do
            local cx, cy = Path.KeyToCell(key)
            local id = ChunkId(world, cx, cy)
            if id and not db.pathsync[id] then db.pathsync[id] = now end
        end
    end
    db.pathStamped = true
end

local function OwnLinkSig()
    local db = Codex.db
    local s, any = 0, false
    for a, row in pairs(db and db.zlink or {}) do
        for b, kinds in pairs(row) do
            for _, e in pairs(kinds) do
                s = s + e.n * 7 + #(e.p or {}) + 1
                any = true
            end
        end
    end
    return any and s % 2147483647 or nil
end

-- Verzeichnis der eigenen Bloecke: Liste { key, upd }
function Path.SyncList()
    local db = Codex.db
    local out = {}
    if not db or not Path.Enabled() and not db.pathsync then return out end
    Path.EnsureStamps()
    for id, upd in pairs(db.pathsync or {}) do out[#out + 1] = { key = "p" .. id, upd = upd } end
    local sig = OwnLinkSig()
    if sig then
        local zs = db.zsync
        if not zs then zs = {}; db.zsync = zs end
        if zs.sig ~= sig then
            zs.sig = sig
            zs.upd = math.max(_G.time and _G.time() or 0, (zs.upd or 0) + 1)
        end
        out[#out + 1] = { key = "z0", upd = zs.upd }
    end
    return out
end

-- Eigener Block als Text "Zelle.Maske,..." (Zelle = 0..255 im Block, beides hexadezimal)
function Path.ChunkRecord(id)
    local db = Codex.db
    if not db or type(id) ~= "number" then return nil end
    local world, gx, gy = ChunkParts(id)
    local w = db.path and db.path[world]
    if not w then return nil end
    local bx, by = (gx - 128) * CHUNK, (gy - 128) * CHUNK
    local parts = {}
    for dx = 0, CHUNK - 1 do
        for dy = 0, CHUNK - 1 do
            local m = w[Key(bx + dx, by + dy)]
            if m then parts[#parts + 1] = string.format("%x.%x", dx * CHUNK + dy, m) end
        end
    end
    if #parts == 0 then return nil end
    return { c = table.concat(parts, ",") }
end

-- Text pruefen. Rueckgabe: Tabelle { [zelle] = maske } oder nil
function Path.ParseChunk(str)
    if type(str) ~= "string" or #str > 6000 then return nil end
    local out, n = {}, 0
    for idx, mask in str:gmatch("(%x+)%.(%x+)") do
        local i, m = tonumber(idx, 16), tonumber(mask, 16)
        if not i or not m or i > 255 or m > 131071 or m < 0 then return nil end
        if not out[i] then n = n + 1 end
        out[i] = m
        if n > 256 then return nil end
    end
    if n == 0 then return nil end
    return out
end

function Path.ChunkText(cells)
    local keys = {}
    for i in pairs(cells) do keys[#keys + 1] = i end
    table.sort(keys)
    local parts = {}
    for _, i in ipairs(keys) do parts[#parts + 1] = string.format("%x.%x", i, cells[i]) end
    return table.concat(parts, ",")
end

-- Empfangenen Block einmischen (Oder der Masken; mehrfach einspielen aendert nichts)
function Path.MergeChunk(id, cells)
    local db = Codex.db
    if not db or type(id) ~= "number" or type(cells) ~= "table" then return false end
    local world, gx, gy = ChunkParts(id)
    db.pathr = db.pathr or {}
    local w = db.pathr[world]
    if not w then w = {}; db.pathr[world] = w end
    db.pathrCount = db.pathrCount or 0
    local bx, by = (gx - 128) * CHUNK, (gy - 128) * CHUNK
    local changed = false
    for idx, mask in pairs(cells) do
        local k = Key(bx + math.floor(idx / CHUNK), by + idx % CHUNK)
        local old = w[k]
        if not old then
            if db.pathrCount >= MAX_REMOTE_CELLS then return changed end
            db.pathrCount = db.pathrCount + 1
            w[k] = mask
            changed = true
        else
            local nm = Or17(old, mask)
            if nm ~= old then w[k] = nm; changed = true end
        end
    end
    if changed then mergedCells[world] = nil; Path.rev = (Path.rev or 0) + 1 end
    return changed
end

local KINDS = { w = true, t = true, f = true, i = true }

local function OptInt(v, hi)
    if v == nil then return nil, true end
    if type(v) ~= "number" or v ~= v or v < 0 or v > hi then return nil, false end
    return math.floor(v), true
end

-- Eigene Gebietsuebergaenge als Liste { a, b, k, n, p = { { fw, fk, tw, tk } } }
function Path.LinkRecord()
    local db = Codex.db
    local list = {}
    local keys = {}
    for a, row in pairs(db and db.zlink or {}) do
        for b, kinds in pairs(row) do
            for kind, e in pairs(kinds) do keys[#keys + 1] = { a = a, b = b, k = kind, e = e } end
        end
    end
    table.sort(keys, function(x, y)
        if x.a ~= y.a then return x.a < y.a end
        if x.b ~= y.b then return x.b < y.b end
        return x.k < y.k
    end)
    for _, r in ipairs(keys) do
        if #list >= MAX_LINKS_SHARED then break end
        local pts = {}
        for _, p in ipairs(r.e.p or {}) do
            pts[#pts + 1] = { fw = p.fw, fk = p.fk, tw = p.tw, tk = p.tk }
        end
        list[#list + 1] = { a = r.a, b = r.b, k = r.k, n = r.e.n, p = pts }
    end
    if #list == 0 then return nil end
    return { l = list }
end

-- Liste pruefen. Rueckgabe: bereinigte Liste oder nil
function Path.ParseLinks(list)
    if type(list) ~= "table" or #list == 0 or #list > MAX_LINKS_SHARED then return nil end
    local out = {}
    for _, r in ipairs(list) do
        if type(r) ~= "table" then return nil end
        local a, b, n = r.a, r.b, r.n
        if type(a) ~= "number" or type(b) ~= "number" or a ~= a or b ~= b or math.abs(a) > 1000000 or math.abs(b) > 1000000 or a == b then return nil end
        if type(r.k) ~= "string" or not KINDS[r.k] then return nil end
        if type(n) ~= "number" or n ~= n or n < 1 or n > 1000000 then return nil end
        local pts = {}
        for _, p in ipairs(type(r.p) == "table" and r.p or {}) do
            if #pts >= LINK_POINTS then break end
            if type(p) ~= "table" then return nil end
            local fw, ok1 = OptInt(p.fw, 1000000)
            local tw, ok2 = OptInt(p.tw, 1000000)
            local fk, ok3 = OptInt(p.fk, 2 ^ 40)
            local tk, ok4 = OptInt(p.tk, 2 ^ 40)
            if not (ok1 and ok2 and ok3 and ok4) then return nil end
            pts[#pts + 1] = { fw = fw, fk = fk, tw = tw, tk = tk }
        end
        out[#out + 1] = { a = math.floor(a), b = math.floor(b), k = r.k, n = math.floor(n), p = pts }
    end
    return out
end

function Path.MergeLinks(list)
    local db = Codex.db
    if not db or type(list) ~= "table" then return false end
    db.zlinkr = db.zlinkr or {}
    for _, r in ipairs(list) do MergeLinkInto(db.zlinkr, r.a, r.b, r.k, r.n, r.p, LINK_POINTS) end
    linkCache = nil
    return true
end

------------------------------------------------------------------------
-- Wegberechnung ueber das Wegenetz (fuer den Levelplan)
------------------------------------------------------------------------
-- Das Netz wird zu Bloecken von 4 x 4 Zellen (40 Yards) vergroebert; Kanten gibt es dort, wo Zellen in
-- verschiedene Bloecke fuehren (Richtungen) oder aneinander grenzen. Faelle gelten nur in Fallrichtung.
-- Distance liefert die Strecke in Yards laengs des Netzes (inklusive der Strecke von und zu den naechsten
-- Netzpunkten), oder nil, wenn dort kein zusammenhaengender Weg bekannt ist (dann rechnet der Plan in Luftlinie).

local BLOCK = 4
local SNAP_BLOCKS = 3        -- so weit (in Bloecken) darf ein Ort vom Netz entfernt sein
local MAX_EXPAND = 20000
local GRAPH_STALE = 120      -- Sekunden, die ein vorhandener Graph trotz neuer Daten weiterverwendet wird
local graphs = {}

local function BKey(bx, by)
    return (bx + 8000) * 65536 + (by + 8000)
end

local function Now()
    return _G.time and _G.time() or 0
end

-- Fuer jede Richtungsmaske (8 Bit) die Liste der gesetzten Richtungen (Index 1..8)
local DIRLIST = {}
for m = 0, 255 do
    local l = {}
    for i = 0, 7 do
        if math.floor(m / 2 ^ i) % 2 == 1 then l[#l + 1] = i + 1 end
    end
    DIRLIST[m] = l
end

local jobs = {}                 -- [welt] = laufender Aufbau
local GRAPH_PER_FRAME = 500      -- Zellen je Bild beim Aufbau im Hintergrund

local function StartJob(world)
    local cells = Path.Cells(world)
    if not cells or not next(cells) then graphs[world] = false return nil end
    local keys = {}
    for k in pairs(cells) do keys[#keys + 1] = k end
    local job = { world = world, cells = cells, keys = keys, i = 1, nodes = {}, built = Now(), rev = Path.rev or 0 }
    jobs[world] = job
    return job
end

-- bis zu n Zellen verarbeiten; true, wenn alle durch sind
local function Step(job, n)
    local cells, nodes, keys = job.cells, job.nodes, job.keys
    local floor = math.floor
    local function Node(bx, by)
        local k = (bx + 8000) * 65536 + (by + 8000)
        local nd = nodes[k]
        if not nd then nd = { bx = bx, by = by, adj = {} }; nodes[k] = nd end
        return nd, k
    end
    local function Edge(a, bk, cost)
        local old = a.adj[bk]
        if not old or cost < old then a.adj[bk] = cost end
    end
    local STRAIGHT, DIAG = BLOCK * CELL, BLOCK * CELL * 1.414
    local last = math.min(#keys, job.i + n - 1)
    for idx = job.i, last do
        local key = keys[idx]
        local mask = cells[key]
        if mask then
            local cx, cy = floor(key / 65536) - OFFSET, key % 65536 - OFFSET
            local bx, by = floor(cx / BLOCK), floor(cy / BLOCK)
            local a, ak
            local dirs = mask % 256
            local drops = floor(mask / 256) % 256
            if dirs > 0 then
                for _, di in ipairs(DIRLIST[dirs]) do
                    local d = DIRS[di]
                    local nbx, nby = floor((cx + d[1]) / BLOCK), floor((cy + d[2]) / BLOCK)
                    if nbx ~= bx or nby ~= by then
                        if not a then a, ak = Node(bx, by) end
                        local b, bk = Node(nbx, nby)
                        local cost = (nbx ~= bx and nby ~= by) and DIAG or STRAIGHT
                        Edge(a, bk, cost)
                        if floor(drops / 2 ^ (di - 1)) % 2 == 0 then Edge(b, ak, cost) end
                    end
                end
            end
            if drops == 0 then
                -- Nachbarzelle aus einem anderen Weg: verbunden
                for i = 1, 4 do
                    local d = DIRS[i]
                    local nm = cells[key + d[1] * 65536 + d[2]]
                    if nm and floor(nm / 256) % 256 == 0 then
                        local nbx, nby = floor((cx + d[1]) / BLOCK), floor((cy + d[2]) / BLOCK)
                        if nbx ~= bx or nby ~= by then
                            if not a then a, ak = Node(bx, by) end
                            local b, bk = Node(nbx, nby)
                            local cost = (nbx ~= bx and nby ~= by) and DIAG or STRAIGHT
                            Edge(a, bk, cost)
                            Edge(b, ak, cost)
                        end
                    end
                end
            end
        end
    end
    job.i = last + 1
    return job.i > #keys
end

-- Zusammenhangskomponenten (Kanten als ungerichtet), damit unerreichbare Ziele sofort auffallen
local function Finish(job)
    local nodes = job.nodes
    local parent = {}
    local function Find(k)
        local r = k
        while parent[r] ~= r do r = parent[r] end
        while parent[k] ~= r do local nx = parent[k]; parent[k] = r; k = nx end
        return r
    end
    for k in pairs(nodes) do parent[k] = k end
    for k, nd in pairs(nodes) do
        for nk in pairs(nd.adj) do
            local a, b = Find(k), Find(nk)
            if a ~= b then parent[a] = b end
        end
    end
    local comp = {}
    for k in pairs(nodes) do comp[k] = Find(k) end
    return { nodes = nodes, comp = comp, built = job.built, rev = job.rev, cache = {}, snaps = {} }
end

local function BuildGraph(world)
    local job = StartJob(world)
    if not job then return nil end
    Step(job, #job.keys + 1)
    jobs[world] = nil
    return Finish(job)
end

local function Graph(world)
    local g = graphs[world]
    local rev = Path.rev or 0
    if g and (g.rev == rev or Now() - g.built < GRAPH_STALE) then return g end
    if Path.syncGraph then
        g = BuildGraph(world)
        graphs[world] = g or false
        return g
    end
    if not jobs[world] then StartJob(world) end
    return g or nil
end

-- Aufbau im Hintergrund voranbringen (je Bild); true, wenn ein Graph fertig wurde
function Path.StepJobs(n)
    local world, job = next(jobs)
    if not job then return false end
    if Step(job, n or GRAPH_PER_FRAME) then
        jobs[world] = nil
        graphs[world] = Finish(job)
        FW:Fire("CODEX_PATH_GRAPH", world)
        return true
    end
    return false
end

local graphFrame = _G.CreateFrame and _G.CreateFrame("Frame")
if graphFrame then
    graphFrame:SetScript("OnUpdate", function() Path.StepJobs() end)
end

-- Naechster Netzpunkt zu (x, y) in Yards. Rueckgabe: Knotenschluessel, Entfernung in Yards
local function Snap(g, x, y)
    local sk = math.floor(x / 10) * 100000 + math.floor(y / 10)
    local c = g.snaps[sk]
    if c ~= nil then
        if c == false then return nil end
        return c[1], c[2]
    end
    local bx, by = math.floor(x / (BLOCK * CELL)), math.floor(y / (BLOCK * CELL))
    local best, bestD
    for dx = -SNAP_BLOCKS, SNAP_BLOCKS do
        for dy = -SNAP_BLOCKS, SNAP_BLOCKS do
            local k = BKey(bx + dx, by + dy)
            if g.nodes[k] then
                local cxm, cym = (bx + dx + 0.5) * BLOCK * CELL, (by + dy + 0.5) * BLOCK * CELL
                local d = math.sqrt((cxm - x) ^ 2 + (cym - y) ^ 2)
                if not bestD or d < bestD then best, bestD = k, d end
            end
        end
    end
    if bestD and bestD > SNAP_BLOCKS * BLOCK * CELL then best = nil end
    g.snaps[sk] = best and { best, bestD } or false
    return best, bestD
end

-- A* ueber die Bloecke. Rueckgabe: Strecke in Yards oder nil
local function Search(g, from, to)
    local nodes = g.nodes
    local goal = nodes[to]
    if not goal then return nil end
    local gx, gy = (goal.bx + 0.5) * BLOCK * CELL, (goal.by + 0.5) * BLOCK * CELL
    local function H(n)
        return 1.2 * math.sqrt(((n.bx + 0.5) * BLOCK * CELL - gx) ^ 2 + ((n.by + 0.5) * BLOCK * CELL - gy) ^ 2)
    end
    local dist, heap, size, done = { [from] = 0 }, {}, 0, {}
    local function Push(k, pr)
        size = size + 1
        local i = size
        heap[i] = { k, pr }
        while i > 1 do
            local p = math.floor(i / 2)
            if heap[p][2] <= heap[i][2] then break end
            heap[p], heap[i] = heap[i], heap[p]
            i = p
        end
    end
    local function Pop()
        local top = heap[1]
        heap[1] = heap[size]
        heap[size] = nil
        size = size - 1
        local i = 1
        while true do
            local l, r, m = i * 2, i * 2 + 1, i
            if l <= size and heap[l][2] < heap[m][2] then m = l end
            if r <= size and heap[r][2] < heap[m][2] then m = r end
            if m == i then break end
            heap[m], heap[i] = heap[i], heap[m]
            i = m
        end
        return top[1]
    end
    Push(from, H(nodes[from]))
    local expanded = 0
    while size > 0 do
        local k = Pop()
        if k == to then return dist[k] end
        if not done[k] then
            done[k] = true
            expanded = expanded + 1
            if expanded > MAX_EXPAND then return nil end
            for nk, cost in pairs(nodes[k].adj) do
                local nd = dist[k] + cost
                if not dist[nk] or nd < dist[nk] then
                    dist[nk] = nd
                    Push(nk, nd + H(nodes[nk]))
                end
            end
        end
    end
    return nil
end

-- Reihenfolge der Weltkoordinaten der Kartenschnittstelle: false = (erster, zweiter) wie UnitPosition, true = (zweiter, erster).
-- Gespeichert in settings.pathSwap (dieselbe Erkennung wie in der Kartenanzeige).
function Path.Swap()
    local db = Codex.db
    if not db or not db.settings then return nil end
    if type(db.settings.pathSwap) == "boolean" then return db.settings.pathSwap end
    local CM = _G.C_Map
    if not (CM and CM.GetBestMapForUnit and CM.GetPlayerMapPosition and CM.GetWorldPosFromMapPos and _G.CreateVector2D) then return nil end
    local pos = Path.Read()
    if not pos then return nil end
    local ok, mapID = pcall(CM.GetBestMapForUnit, "player")
    if not ok or type(mapID) ~= "number" then return nil end
    local ok2, mp = pcall(CM.GetPlayerMapPosition, mapID, "player")
    if not ok2 or not mp or not mp.GetXY then return nil end
    local px, py = mp:GetXY()
    if type(px) ~= "number" or type(py) ~= "number" then return nil end
    local ok3, _, wp = pcall(CM.GetWorldPosFromMapPos, mapID, _G.CreateVector2D(px, py))
    if not ok3 or not wp or not wp.GetXY then return nil end
    local vx, vy = wp:GetXY()
    if type(vx) ~= "number" or type(vy) ~= "number" then return nil end
    -- pos.y = erster Wert von UnitPosition, pos.x = zweiter
    local errNormal = math.abs(vx - pos.y) + math.abs(vy - pos.x)
    local errSwap = math.abs(vx - pos.x) + math.abs(vy - pos.y)
    if math.abs(errNormal - errSwap) < 50 then return nil end   -- zu nah beieinander, nicht eindeutig
    db.settings.pathSwap = errSwap < errNormal
    return db.settings.pathSwap
end

-- Weltkoordinaten der Kartenschnittstelle (Vektor x, y in Yards) -> Zellraum (x, y in Yards)
function Path.FromWorldVec(vx, vy)
    local swap = Path.Swap()
    if swap == nil then return nil end
    if swap then return vx, vy end
    return vy, vx
end

-- Strecke in Yards laengs des Wegenetzes zwischen zwei Orten (Zellraum, Yards); nil = unbekannt, Luftlinie benutzen
function Path.Distance(world, ax, ay, bx, by)
    if type(world) ~= "number" then return nil end
    local straight = math.sqrt((ax - bx) ^ 2 + (ay - by) ^ 2)
    if straight < 2 * BLOCK * CELL then return nil end
    local g = Graph(world)
    if not g then return nil end
    local sa, da = Snap(g, ax, ay)
    local sb, db_ = Snap(g, bx, by)
    if not sa or not sb or sa == sb then return nil end
    if g.comp[sa] ~= g.comp[sb] then return nil end
    local ck = sa .. ":" .. sb
    local cost = g.cache[ck]
    if cost == nil then
        cost = Search(g, sa, sb) or false
        g.cache[ck] = cost
    end
    if not cost then return nil end
    return da + cost + db_
end

function Path.ResetGraphs()
    graphs = {}
end

-- Wird bei jeder Messung aufgerufen, auch beim Reiten und Fliegen (Grenzen gelten fuer alle)
function Path.TrackZone(pos)
    local z = state.zone
    if Flag(_G.IsInInstance) then
        if not state.inInst then
            local id = Codex.CurrentInstance and Codex.CurrentInstance()
            state.inInst = id and -id or true
            if z and z.map and id then Link(z.map, -id, "i", z.here, nil) end
            state.leftFrom = id and -id or nil
        end
        state.pend = nil
        return
    end
    if state.inInst then
        state.inInst = nil
        state.zone, z = nil, nil
    end
    if Flag(_G.UnitOnTaxi, "player") then
        if not state.taxi and z then state.taxi = { map = z.map, here = z.here } end
        return
    end
    local m = CurrentMap()
    if not m then return end
    local here = Here(pos)
    if state.leftFrom then
        Link(state.leftFrom, m, "i", nil, here)
        state.leftFrom = nil
    end
    if state.taxi then
        local t = state.taxi
        state.taxi = nil
        if t.map and t.map ~= m then Link(t.map, m, "f", t.here, here) end
        state.zone, state.pend = { map = m, here = here }, nil
        return
    end
    if not z then
        state.zone = { map = m, here = here }
        return
    end
    if m == z.map then
        state.pend = nil
        z.here = here or z.here
        return
    end
    -- anderes Gebiet: erst nach zwei Messungen in Folge werten (an der Grenze hin und her tritt oft doppelt)
    if not state.pend or state.pend.map ~= m then
        state.pend = { map = m, n = 1 }
        return
    end
    state.pend.n = state.pend.n + 1
    if state.pend.n < 2 then return end
    local kind = "t"
    if z.here and here and z.here.world == here.world then
        local fx, fy = Path.KeyToCell(z.here.key)
        local tx, ty = Path.KeyToCell(here.key)
        if math.max(math.abs(fx - tx), math.abs(fy - ty)) <= WALK_CELLS then kind = "w" end
    end
    Link(z.map, m, kind, z.here, here)
    state.zone, state.pend = { map = m, here = here }, nil
end

-- Aktuelle Messung: { x, y, z, world } oder nil, wenn nicht lesbar
function Path.Read()
    if not _G.UnitPosition then return nil end
    local ok, a, b, c, d = pcall(_G.UnitPosition, "player")
    if not ok then return nil end
    for _, v in ipairs({ a or 0, b or 0, c or 0, d or 0 }) do
        if Util and Util.IsSecret and Util.IsSecret(v) then return nil end
    end
    if type(a) ~= "number" or type(b) ~= "number" then return nil end
    -- UnitPosition liefert (Y, X, Z, Welt)
    return { x = b, y = a, z = type(c) == "number" and c or 0, world = d }
end

-- Eine Messung verarbeiten. now = Zeit in Sekunden. Rueckgabe: true, wenn aufgezeichnet.
function Path.Tick(now)
    state.samples = state.samples + 1
    if not Path.Enabled() or not DB() then return false end
    local reset = function(reason)
        if reason then Reject(reason) end
        state.last = nil
        state.fallT, state.fallFrom = 0, nil
        return false
    end
    local pos0 = Path.Read()
    pcall(Path.TrackZone, pos0)
    if Flag(_G.IsInInstance) then return reset("instanz") end
    local pos = pos0
    if not pos or not pos.world then return reset("keine Position") end
    local dead = _G.UnitIsDeadOrGhost and Flag(_G.UnitIsDeadOrGhost, "player")
    if dead then return reset("tot") end
    -- Reiten zaehlt mit (Bodenreittiere folgen dem Boden); Flug, Taxi und Fahrzeuge nicht
    if Flag(_G.IsFlying) or Flag(_G.UnitOnTaxi, "player") or (_G.UnitInVehicle and Flag(_G.UnitInVehicle, "player")) then
        return reset("Flug/Fahrzeug")
    end
    -- Fahrt wird als Verbindung erfasst (Start hier ... Ziel hier): Deck und Fahrweg gehoeren nicht ins Wegenetz
    local T = Codex.Transport
    if T and T.Recording and T.Recording() then return reset("Verbindung") end
    local speed = _G.GetUnitSpeed and select(1, _G.GetUnitSpeed("player")) or 0
    if type(speed) == "number" and speed > MAX_SPEED then return reset("zu schnell") end
    if SkipAura() then return reset("Aura") end
    local cx, cy = CellOf(pos.x, pos.y)
    local cur = { cx = cx, cy = cy, world = pos.world }
    if Flag(_G.IsFalling) then
        -- Fall: nichts eintragen, aber den Startpunkt merken
        if not state.fallFrom and state.last and state.last.world == pos.world then state.fallFrom = state.last end
        state.fallT = state.fallT + TICK
        return false
    end
    if state.fallFrom then
        -- gelandet: war es ein richtiger Fall (kein Sprung), Einbahn-Kante vom Start zur Landung
        local from, long = state.fallFrom, state.fallT >= MIN_FALL
        state.fallFrom, state.fallT = nil, 0
        if long and from.world == pos.world and math.max(math.abs(cx - from.cx), math.abs(cy - from.cy)) <= 8 then
            local cells = Line(from.cx, from.cy, cx, cy)
            local nxt = cells[2]
            if nxt then
                local di = DIR_OF[(nxt[1] - from.cx) .. ":" .. (nxt[2] - from.cy)]
                Mark(pos.world, from.cx, from.cy, di, true)
            end
            Mark(pos.world, cx, cy, nil, false, pos.z)
            state.last = cur
            return true
        end
    end
    local last = state.last
    if last and last.world == pos.world then
        local d = math.max(math.abs(cx - last.cx), math.abs(cy - last.cy))
        if d == 0 then return false end          -- steht still: keine neuen Daten
        if d > MAX_STEP_CELLS then
            state.last = cur                      -- Teleport oder Ladebildschirm: neu ansetzen, nichts verbinden
            Reject("Sprung")
            Mark(pos.world, cx, cy, nil, false, pos.z)
            return false
        end
        Connect(pos.world, last, cur, false, pos.z)
    else
        Mark(pos.world, cx, cy, nil, false, pos.z)
    end
    state.last = cur
    return true
end

-- Ist an dieser Stelle (Weltkoordinaten in Yards) schon etwas bekannt? Rueckgabe: Maske oder nil
function Path.At(world, x, y)
    local db = Codex.db
    if not db then return nil end
    local w = Path.Cells(world)
    if not w then return nil end
    local cx, cy = CellOf(x, y)
    return w[Key(cx, cy)]
end

-- Kennzahlen fuer die Diagnose
function Path.Stats()
    local db = Codex.db
    local cells, drops, edges, worlds, links, crossings = 0, 0, 0, 0, 0, 0
    for _, w in pairs(db and db.path or {}) do
        worlds = worlds + 1
        for _, m in pairs(w) do
            cells = cells + 1
            for i = 0, 7 do
                if math.floor(m / 2 ^ i) % 2 == 1 then edges = edges + 1 end
                if math.floor(m / 2 ^ (i + 8)) % 2 == 1 then drops = drops + 1 end
            end
        end
    end
    for _, row in pairs(Path.Links()) do
        for _, kinds in pairs(row) do
            links = links + 1
            for _, e in pairs(kinds) do crossings = crossings + e.n end
        end
    end
    local shared = 0
    for _, w in pairs(db and db.pathr or {}) do
        for _ in pairs(w) do shared = shared + 1 end
    end
    return { cells = cells, edges = edges, drops = drops, worlds = worlds, links = links, crossings = crossings, shared = shared }
end

------------------------------------------------------------------------
-- Messen: alle TICK Sekunden
------------------------------------------------------------------------

local frame = _G.CreateFrame and _G.CreateFrame("Frame")
if frame then
    frame:SetScript("OnUpdate", function(_, elapsed)
        state.acc = state.acc + (elapsed or 0)
        if state.acc < TICK then return end
        state.acc = 0
        local ok = pcall(Path.Tick, _G.GetTime and _G.GetTime() or 0)
        if not ok then Reject("Fehler") end
    end)
end

------------------------------------------------------------------------
-- /fwpos: Diagnose (Position, Hoehe, Zustand, Auren) und Ein/Aus
------------------------------------------------------------------------

function Path.Diag()
    local pos = Path.Read()
    if not pos then
        FW:Print("Pos: keine Position lesbar (UnitPosition fehlt, Instanz oder gesperrt).")
    else
        FW:Print(string.format("Pos: x=%.1f y=%.1f z=%s Welt=%s -> Zelle %d/%d%s", pos.x, pos.y, tostring(pos.z), tostring(pos.world),
            (CellOf(pos.x, pos.y)), select(2, CellOf(pos.x, pos.y)), pos.z == 0 and " (Hoehe liefert das Spiel nicht: z ist 0)" or " (Hoehe wird gespeichert)"))
    end
    local speed = _G.GetUnitSpeed and select(1, _G.GetUnitSpeed("player")) or "?"
    FW:Print(string.format("Pos: Tempo=%s | Reittier=%s Flug=%s Fall=%s Schwimmen=%s Instanz=%s", tostring(speed), tostring(Flag(_G.IsMounted)),
        tostring(Flag(_G.IsFlying)), tostring(Flag(_G.IsFalling)), tostring(Flag(_G.IsSwimming)), tostring(Flag(_G.IsInInstance))))
    local names = {}
    local CU = _G.C_UnitAuras
    if CU and CU.GetAuraDataByIndex then
        for i = 1, 40 do
            local ok, a = pcall(CU.GetAuraDataByIndex, "player", i, "HELPFUL")
            if not ok or type(a) ~= "table" then break end
            names[#names + 1] = tostring(a.name) .. "(" .. tostring(a.spellId) .. ")"
        end
    elseif _G.UnitBuff then
        for i = 1, 40 do
            local ok, name, _, _, _, _, _, _, _, _, id = pcall(_G.UnitBuff, "player", i)
            if not ok or not name then break end
            names[#names + 1] = tostring(name) .. "(" .. tostring(id) .. ")"
        end
    end
    FW:Print("Pos: Auren: " .. (#names > 0 and table.concat(names, ", ") or "keine") .. " | wird uebersprungen: " .. tostring(SkipAura()))
    local st = Path.Stats()
    FW:Print(string.format("Pos: Aufzeichnung %s | %d Zellen, %d Kanten, %d Faelle, %d Welten | neu in dieser Sitzung: %d", Path.Enabled() and "an" or "aus",
        st.cells, st.edges, st.drops, st.worlds, state.added))
    FW:Print(string.format("Pos: %d Gebietsverbindungen (%d Uebergaenge)", st.links, st.crossings))
    local r = {}
    for reason, n in pairs(state.reasons) do r[#r + 1] = reason .. " x" .. n end
    table.sort(r)
    if #r > 0 then FW:Print("Pos: verworfen: " .. table.concat(r, ", ")) end
end

-- Einstellungen: Ein/Aus (standardmaessig an) und Kennzahlen
local UI = FW.UI
if UI and UI.RegisterSettingsSection then
    UI:RegisterSettingsSection("codex-path", {
        order = 107,
        height = 200,
        build = function(parent)
            local L = FW.L
            local f, stack = UI.CreateSection(parent, L.CODEX_PATH_HEADER)
            local note = UI.CreateLabel(f, L.CODEX_PATH_NOTE, { size = 11, color = "textDim", justifyV = "TOP" })
            stack:Add(note, { fit = true, gap = 8 })
            local box = UI.CreateCheckbox(f, L.CODEX_PATH_SWITCH, function() return Path.Enabled() end,
                function(on) Path.SetEnabled(on) end)
            stack:Add(box, { fit = true, gap = 10 })
            local stats = UI.CreateLabel(f, "", { size = 11, color = "textDim", justifyV = "TOP" })
            stack:Add(stats, { fit = true, gap = 6, minHeight = 14 })
            f.box, f.stats = box, stats
            return f
        end,
        refresh = function(frame)
            frame.box:Refresh()
            local st = Path.Stats()
            frame.stats:SetText(string.format(FW.L.CODEX_PATH_STATS, st.cells, st.edges, st.drops, st.links))
            frame.stack:Layout()
        end,
    })
end

SLASH_FREEWOODPOS1 = "/fwpos"
SlashCmdList["FREEWOODPOS"] = function(msg)
    msg = tostring(msg or ""):lower()
    if msg == "aus" or msg == "off" then
        Path.SetEnabled(false)
        FW:Print("Pos: Aufzeichnung aus.")
    elseif msg == "an" or msg == "on" then
        Path.SetEnabled(true)
        FW:Print("Pos: Aufzeichnung an.")
    else
        Path.Diag()
    end
end
