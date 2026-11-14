-- Test: Sync-Antworten ohne Voll-Scan (texlua tests/sharescan_test.lua)
-- Prueft CodexShare.lua: Der Scan-Zwischenspeicher bleibt bei Datenaenderungen stehen (SCAN_REUSE),
-- OwnRecord stempelt fehlende Datensaetze einzeln statt die ganze Datenbank zu durchlaufen,
-- und Wegenetz-Datensaetze (p/z) holen ihren Stand aus der kleinen Liste von Codex.Path.
local now = 1000
_G.time = function() return now end
local FW = { On = function() end, RegisterEvent = function() end,
    L = setmetatable({}, { __index = function(_, k) return k end }) }
_G.Freewood = FW
local Codex = { GRID = 200, db = { units = {}, objects = {}, quests = {}, ied = {}, names = {},
    transport = {}, flight = { routes = {} }, spots = {}, settings = {} } }
assert(loadfile("CodexShare.lua"))("Freewood-Codex", { Codex = Codex })
local Share = Codex.Share
assert(Share and Share.Scan and Share.OwnRecord, "geladen")

-- 1) Erster Scan sieht den einen Datensatz
Codex.db.units[1] = { k = 3 }
local _, count = Share.Scan(true)
assert(count == 1, "erster Scan: " .. tostring(count))

-- 2) Aenderung + InvalidateScan: ein weicher Scan rechnet NICHT neu (Zwischenspeicher bleibt)
Codex.db.units[2] = { k = 5 }
Share.InvalidateScan()
now = now + 60   -- frueher verfiel der Zwischenspeicher nach 30 s
local _, c2 = Share.Scan(false)
assert(c2 == 1, "weicher Scan nutzt den Zwischenspeicher: " .. tostring(c2))

-- 3) Erzwungener Scan sieht beide
local _, c3 = Share.Scan(true)
assert(c3 == 2, "erzwungener Scan: " .. tostring(c3))

-- 4) Nach Ablauf von SCAN_REUSE rechnet auch der weiche Scan neu
Codex.db.units[3] = { k = 1 }
now = now + 400
local _, c4 = Share.Scan(false)
assert(c4 == 3, "weicher Scan nach Ablauf: " .. tostring(c4))

-- 5) OwnRecord fuer einen bekannten Datensatz: Stand aus dem Stempel, kein Scan
local rec, upd = Share.OwnRecord("u1")
assert(rec and rec.y == "u" and rec.id == 1 and upd, "OwnRecord bekannt")

-- 6) OwnRecord fuer einen frisch angelegten Datensatz: einzeln gestempelt, der Zwischenspeicher bleibt unveraendert
Codex.db.units[9] = { k = 7 }
local rec9, upd9 = Share.OwnRecord("u9")
assert(rec9 and upd9, "OwnRecord stempelt einzeln")
local _, c5 = Share.Scan(false)
assert(c5 == 3, "kein Voll-Scan durch OwnRecord: " .. tostring(c5))

-- 7) Wegenetz: Stand aus Codex.Path.SyncList, nicht aus dem Scan
Codex.Path = {
    SyncList = function() return { { key = "p7", upd = 123 } } end,
    ChunkRecord = function(id) return { c = "roh" } end,
    ParseChunk = function(c) return { 2 } end,
    ChunkText = function(cells) return "roh" end,
}
local recP, updP = Share.OwnRecord("p7")
assert(recP and updP == 123, "Wegenetz-Datensatz: " .. tostring(updP))
assert(Share.OwnRecord("p8") == nil, "unbekannter Wegenetz-Datensatz")

-- 8) x0 ohne Stempel: nil, kein Fehler, kein Scan
Codex.db.units[10] = { k = 2 }
assert(Share.OwnRecord("x0") == nil, "x0 ohne Stempel")
local _, c6 = Share.Scan(false)
assert(c6 == 3, "kein Voll-Scan durch x0: " .. tostring(c6))

print("sharescan_test OK")
