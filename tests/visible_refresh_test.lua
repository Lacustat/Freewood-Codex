-- Test: Ereignis-Handler der Reiter bauen nur neu, wenn der Reiter wirklich sichtbar ist (IsVisible, 0.50.2)
-- texlua tests/visible_refresh_test.lua
local src = assert(io.open("CodexUI.lua")):read("*a")
assert(not src:find('FW:On%("CODEX_CHANGED".-if f:IsShown%(%)'), "CODEX_CHANGED nutzt nicht mehr IsShown")
assert(not src:find('CODEX_LISTLIMIT_CHANGED", function%(%) if f:IsShown%(%)'), "Listenlaenge nutzt nicht mehr IsShown")
assert(src:find('FW:On%("CODEX_CHANGED", function%(%)%s+dirty = true%s+dataVersion = dataVersion %+ 1%s+if f:IsVisible%(%) then%s+RefreshSoon%(%)'), "CODEX_CHANGED: sichtbar + gebuendelt")
assert(src:find('FW:On%("CODEX_ITEMS_LOADED", function%(%)%s+dataVersion = dataVersion %+ 1%s+if f:IsVisible%(%)'), "Items geladen: nur sichtbar")
-- Buendeln: mehrere Aenderungen = ein Neuaufbau
local body = src:match("local refreshPending = false(.-)f%.RefreshSoon = RefreshSoon")
assert(body, "RefreshSoon vorhanden")
local runs, timers, visible = 0, {}, true
local env = { C_Timer = { After = function(_, fn) timers[#timers + 1] = fn end } }
local f = { IsVisible = function() return visible end }
local chunk = assert(load("local f, RefreshList, C_Timer = ...\nlocal refreshPending = false" .. body .. "\nreturn RefreshSoon"))
local RefreshSoon = chunk(f, function() runs = runs + 1 end, env.C_Timer)
for _ = 1, 5 do RefreshSoon() end
assert(#timers == 1, "fuenf Aenderungen, ein Zeitgeber")
timers[1]()
assert(runs == 1, "ein Neuaufbau")
RefreshSoon(); visible = false; timers[2]()
assert(runs == 1, "Fenster inzwischen zu: kein Neuaufbau")
print("visible_refresh_test OK")
