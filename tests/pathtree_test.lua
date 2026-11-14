-- Test: Wegsuche je Startpunkt in Path.Distance (texlua tests/pathtree_test.lua)
-- Freies Feld: die Strecke muss exakt der Achtnachbar-Distanz entsprechen. Mit Hindernis: der Baum findet
-- dieselbe oder eine kuerzere Strecke als die alte A*-Suche, und Ergebnisse werden zwischengespeichert.
_G.time = function() return 1000 end
_G.SlashCmdList = {}
local FW = { RequireAPI = function() return true end, On = function() end, RegisterEvent = function() end, Fire = function() end,
    L = setmetatable({}, { __index = function(_, k) return k end }) }
_G.Freewood = FW
local OFFSET, CELL, BLOCK = 30000, 10, 4
local function Load(cells)
    local Codex = { db = { path = { [1] = cells }, settings = {} } }
    assert(loadfile("CodexPath.lua"))("Freewood-Codex", { Codex = Codex })
    local P = Codex.Path
    P.syncGraph = true
    return P
end
local function Key(cx, cy) return (cx + OFFSET) * 65536 + (cy + OFFSET) end
local FULL = 255 + 65536

-- 1) freies Feld 200 x 200 Zellen (50 x 50 Bloecke), alle Richtungen
local cells = {}
for cx = 0, 199 do for cy = 0, 199 do cells[Key(cx, cy)] = FULL end end
local P = Load(cells)
local function Center(bx, by) return (bx + 0.5) * BLOCK * CELL, (by + 0.5) * BLOCK * CELL end
local function Octile(dx, dy)
    dx, dy = math.abs(dx), math.abs(dy)
    local lo, hi = math.min(dx, dy), math.max(dx, dy)
    return (hi - lo) * BLOCK * CELL + lo * BLOCK * CELL * 1.414
end
local sx, sy = Center(5, 5)
local targets = { { 40, 5 }, { 5, 40 }, { 30, 20 }, { 45, 45 }, { 12, 33 }, { 49, 0 }, { 0, 49 }, { 20, 21 } }
for _, t in ipairs(targets) do
    local tx, ty = Center(t[1], t[2])
    local d = P.Distance(1, sx, sy, tx, ty)
    assert(d, "Strecke vorhanden")
    local want = Octile(t[1] - 5, t[2] - 5)
    assert(math.abs(d - want) < 0.01, string.format("Feld %d,%d: %.2f statt %.2f", t[1], t[2], d, want))
end
-- nur die erste Anfrage dieses Startpunkts lief als A*, der Rest ueber den Baum
assert(P.treeStats.astar == 1 and P.treeStats.tree == #targets - 1, P.treeStats.astar .. "/" .. P.treeStats.tree)
-- zweite Runde: alles aus dem Zwischenspeicher (keine neue Suche)
local before = P.treeStats.tree + P.treeStats.astar
for _, t in ipairs(targets) do local tx, ty = Center(t[1], t[2]) assert(P.Distance(1, sx, sy, tx, ty)) end
assert(P.treeStats.tree + P.treeStats.astar == before, "Zwischenspeicher")

-- 2) Hindernis: Wand bei Zellspalte 100..103 (Block 25), Luecke nur unten (cy 0..11)
local cells2 = {}
for cx = 0, 199 do for cy = 0, 199 do
    if not (cx >= 100 and cx <= 103 and cy >= 12) then cells2[Key(cx, cy)] = FULL end
end end
-- Referenz alte Suche: neuer Graph, jede Anfrage von einem eigenen Startpunkt (immer erste Anfrage = A*)
local Pa = Load(cells2)
local Pt = Load(cells2)
local ax, ay = Center(10, 40)
local dummyX, dummyY = Center(11, 11)
Pt.Distance(1, ax, ay, dummyX, dummyY)          -- erste Anfrage: danach laeuft der Baum
for _, t in ipairs({ { 40, 40 }, { 45, 20 }, { 30, 45 }, { 49, 49 } }) do
    local tx, ty = Center(t[1], t[2])
    local old = Pa.Distance(1, ax, ay, tx, ty)
    Pa.ResetGraphs()
    local new = Pt.Distance(1, ax, ay, tx, ty)
    assert(old and new, "Strecke um die Wand")
    assert(new <= old + 0.01, string.format("Baum %.1f laenger als A* %.1f", new, old))
    assert(new >= Octile(t[1] - 10, t[2] - 40) - 0.01, "nicht kuerzer als die Luftlinie im Raster")
end

-- 3) hoechstens MAX_TREES Startpunkte bleiben, aeltester faellt heraus (keine Fehler bei vielen Startpunkten)
local P3 = Load(cells)
for i = 0, 9 do
    local fx, fy = Center(i * 4, 3)
    local tx, ty = Center(40, 40)
    P3.Distance(1, fx, fy, tx, ty)
    local ux, uy = Center(41, 40)
    assert(P3.Distance(1, fx, fy, ux, uy))
end
print("pathtree_test OK")
