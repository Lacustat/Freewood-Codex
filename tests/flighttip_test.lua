-- Test Flugzeit im Tooltip der Flugkarte (texlua tests/flighttip_test.lua)
_G.GetTime = function() return 0 end
_G.time = function() return 1000 end
_G.hooksecurefunc = function() end
_G.SlashCmdList = {}
local L = setmetatable({ CODEX_TAXI_TIP = "Flugzeit: %s", CODEX_TAXI_TIP_UNKNOWN = "Flugzeit: unbekannt" }, { __index = function(_, k) return k end })
_G.Freewood = { L = L, UI = {}, Print = function() end, Fire = function() end, RegisterEvent = function() end, UnregisterEvent = function() end, Util = {} }
local NS = { Codex = { db = { settings = { enabled = true }, flight = { routes = {}, known = {} } }, Trust = { SelfKey = function() return "me" end } } }
assert(loadfile("CodexFlight.lua"))("Freewood-Codex", NS)
local F = NS.Flight
local A, B, C = F.NodeId(1, 100, 100), F.NodeId(1, 200, 200), F.NodeId(1, 300, 300)
NS.Codex.db.flight.routes[1] = { a = { c = 1, tx = 100, ty = 100 }, b = { c = 1, tx = 200, ty = 200 }, t = 75 }
F.state.cur = A
F.state.slot = { [1] = { id = A, kind = "CURRENT", name = "Hier" }, [2] = { id = B, kind = "REACHABLE", name = "Tarrens Muehle" }, [3] = { id = C, kind = "REACHABLE", name = "Fern" } }
assert(F.TipLine("Tarrens Muehle") == nil, "Karte nicht offen")
F.state.open = true
assert(F.TipLine("Tarrens Muehle") == "Flugzeit: 1:15", F.TipLine("Tarrens Muehle"))
assert(F.TipLine("Fern") == "Flugzeit: unbekannt")
assert(F.TipLine("Hier") == nil and F.TipLine("Nirgends") == nil and F.TipLine(nil) == nil)
print("flighttip OK")
