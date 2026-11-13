-- Test Flugzeit: Umweg-Schutz der Schaetzung und Korrektur bei Abweichung (texlua tests/flightfix_test.lua)
local clock, onTaxi = 0, false
_G.GetTime = function() return clock end
_G.time = function() return 1000 + clock end
_G.UnitOnTaxi = function() return onTaxi end
_G.GetMoney = function() return 5000 end
_G.hooksecurefunc = function() end
_G.SlashCmdList = {}
local printed = {}
local L = setmetatable({ CODEX_FLIGHT_SAVED = "saved", CODEX_FLIGHT_FIXED = "fix %s %s %s %s" }, { __index = function(_, k) return k end })
_G.Freewood = { L = L, UI = {}, Print = function(_, t) printed[#printed + 1] = t end, Fire = function() end,
    RegisterEvent = function() end, UnregisterEvent = function() end, Util = {} }
local db = { settings = { enabled = true }, flight = { routes = {}, known = {} } }
local NS = { Codex = { db = db, Trust = { SelfKey = function() return "me" end } } }
assert(loadfile("CodexFlight.lua"))("Freewood-Codex", NS)
local F = NS.Flight
local function Node(tx, ty, n) return { n = n, c = 1, tx = tx, ty = ty } end
local Z, S, O = Node(100, 100, "Zoramgar"), Node(300, 150, "Splintertree"), Node(500, 700, "Orgrimmar")
local zid, sid, oid = F.NodeId(1, 100, 100), F.NodeId(1, 300, 150), F.NodeId(1, 500, 700)
-- gemessen: Zoramgar -> Orgrimmar 250 s, Orgrimmar -> Splintertree 270 s
db.flight.routes[1] = { a = Z, b = O, t = 250, c = 1, n = 1 }
db.flight.routes[2] = { a = O, b = S, t = 270, c = 1, n = 1 }
-- Zoramgar -> Splintertree liegt nicht ueber Orgrimmar: keine Schaetzung
assert(F.EstimateSecs(zid, sid) == nil, "Umweg ueber ferne Stadt ist keine Schaetzung: " .. tostring(F.EstimateSecs(zid, sid)))
-- direkt gemessen und rueckwaerts bleibt moeglich
assert(F.EstimateSecs(zid, oid) == 250 and F.EstimateSecs(oid, zid) == 250)
-- Zwischenstation auf dem Weg zaehlt: Zoramgar -> Splintertree 100 s, Splintertree -> Orgrimmar 150 s
db.flight.routes[1] = nil
db.flight.routes[2] = nil
local S2 = Node(300, 400, "Mitte")
db.flight.routes[3] = { a = Z, b = S2, t = 100, c = 1, n = 1 }
db.flight.routes[4] = { a = S2, b = O, t = 150, c = 1, n = 1 }
assert(F.EstimateSecs(zid, oid) == 250, "Zwischenstation auf dem Weg: " .. tostring(F.EstimateSecs(zid, oid)))

-- Korrektur bei Abweichung
db.flight.routes = {}
db.flight.known.me = { [zid] = Z, [oid] = O }
F.state.cur = zid
F.state.slot = { [1] = { id = oid, cost = 100, kind = "REACHABLE" } }
local function Fly(sec)
    F.OnTake(1)
    onTaxi = true; clock = clock + 2; F.Tick()
    clock = clock + sec; F.Tick()
    onTaxi = false; clock = clock + 1; F.Tick()
end
local function Route() for _, r in pairs(db.flight.routes) do return r end end
Fly(250)
assert(Route().t == 251 or Route().t == 250 or math.abs(Route().t - 250) <= 3, "erste Messung " .. tostring(Route().t))
local t1 = Route().t
Fly(255)                                   -- kleine Abweichung: gemittelt
assert(Route().n == 2 and math.abs(Route().t - t1) <= 6, "kleine Abweichung gemittelt: " .. tostring(Route().t))
printed = {}
Fly(100)                                   -- grosse Abweichung: ersetzt
assert(Route().n == 1 and math.abs(Route().t - 101) <= 3, "grosse Abweichung ersetzt: " .. tostring(Route().t) .. " n=" .. tostring(Route().n))
assert(#printed == 1 and printed[1]:find("fix", 1, true), "Korrektur gemeldet")
db.settings.flightFixMsg = false
printed = {}
Fly(250)
assert(Route().n == 1 and #printed == 0, "Meldung abschaltbar")
print("flightfix OK")
