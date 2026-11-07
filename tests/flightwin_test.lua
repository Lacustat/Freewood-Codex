-- Test Flugfenster: Zustand der Anzeige und Erfassung in CodexFlight.lua / CodexFlightUI.lua (texlua tests/flightwin_test.lua)
local clock, onTaxi = 0, false
_G.GetTime = function() return clock end
_G.time = function() return 1000 + clock end
_G.UnitOnTaxi = function() return onTaxi end
_G.GetMoney = function() return 5000 end
_G.hooksecurefunc = function() end
local function Proxy()
    return setmetatable({}, { __index = function() return function() return Proxy() end end })
end
_G.CreateFrame = function() return Proxy() end
_G.UIParent = Proxy()
_G.SlashCmdList = {}
local L = setmetatable({
    CODEX_TAXI_LEFT = "Noch %s", CODEX_TAXI_ARRIVING = "Gleich da...", CODEX_TAXI_UNKNOWN = "%s (erfasst)",
    CODEX_FLIGHT_SAVED = "saved %s %s %d %d",
}, { __index = function(_, k) return k end })
_G.Freewood = { L = L, UI = Proxy(), Print = function() end, Fire = function() end, RegisterEvent = function() end, UnregisterEvent = function() end, Util = {} }
local NS = { Codex = { db = { settings = { enabled = true }, flight = { routes = {}, known = {} } }, Trust = { SelfKey = function() return "me" end } } }
assert(loadfile("CodexFlight.lua"))("Freewood-Codex", NS)
assert(loadfile("CodexFlightUI.lua"))("Freewood-Codex", NS)
local F = NS.Flight
assert(F and F.WindowState and F.Duration)

assert(F.Duration(75) == "1:15")
assert(F.Duration(5) == "0:05")

-- Anzeige: bekannte Dauer, laeuft leer
local t, frac, col = F.WindowState({ exp = 100 }, 25, L)
assert(t == "Noch 1:15" and math.abs(frac - 0.75) < 1e-6 and col == "gold", t)
t, frac, col = F.WindowState({ exp = 100 }, 130, L)
assert(t == "Gleich da..." and frac == 0 and col == "success")
-- unbekannt: zaehlt hoch, Balken laeuft voll
t, frac, col = F.WindowState({}, 15, L)
assert(t == "0:15 (erfasst)" and math.abs(frac - 0.5) < 1e-6 and col == "bronze")

-- Erfassung: Flugpunkte kennen, Abflug, Fenster-Daten
local known = NS.Codex.db.flight.known.me
known = known or {}
NS.Codex.db.flight.known.me = known
known["1:100:100"] = { n = "Start", c = 1, tx = 100, ty = 100 }
known["1:900:900"] = { n = "Ziel", c = 1, tx = 900, ty = 900 }
F.state.cur = "1:100:100"
F.state.slot = { [3] = { id = "1:900:900", cost = 120, kind = "REACHABLE" } }
F.OnTake(3)
assert(F.state.pending and F.state.pending.to == "1:900:900")
clock = 1
F.Tick()                                  -- noch nicht abgehoben
assert(F.flight == nil)
onTaxi, clock = true, 2
F.Tick()
assert(F.flight and F.flight.name == "Ziel" and F.flight.exp == nil, "Fenster-Daten unbekannte Dauer")
clock = 40
F.Tick()
onTaxi, clock = false, 42
F.Tick()
assert(F.flight == nil, "Flug beendet")
local saved
for _, r in pairs(NS.Codex.db.flight.routes) do saved = r end
assert(saved and saved.t == 40, "Dauer gespeichert: " .. tostring(saved and saved.t))

-- zweiter Flug: Dauer jetzt bekannt
F.OnTake(3)
onTaxi, clock = true, 100
F.Tick()
assert(F.flight and F.flight.exp == 40, "bekannte Dauer: " .. tostring(F.flight and F.flight.exp))
onTaxi, clock = false, 140
F.Tick()
assert(F.flight == nil)

-- Rueckfall: Flug ohne OnTake (Hook greift nicht)
onTaxi, clock = true, 200
F.Tick()
assert(F.flight and F.flight.name == nil and F.flight.exp == nil, "Rueckfall zeigt Fenster ohne Namen")
onTaxi, clock = false, 230
F.Tick()
assert(F.flight == nil and F.state.pending == nil)
print("OK")
