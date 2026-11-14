-- Test: Gebietsuebergaenge als Punkte (Path.Crossings) -- texlua tests/crossings_test.lua
_G.time = function() return 1000 end
_G.SlashCmdList = {}
local FW = { RequireAPI = function() return true end, On = function() end, RegisterEvent = function() end, Fire = function() end,
    L = setmetatable({}, { __index = function(_, k) return k end }) }
_G.Freewood = FW
local OFFSET = 30000
local function Key(cx, cy) return (cx + OFFSET) * 65536 + (cy + OFFSET) end
local Codex = { db = { settings = {}, zlink = {
    [10] = { [20] = { w = { n = 3, p = { { fw = 1, fk = Key(99, 50), tw = 1, tk = Key(100, 50) } } },
                      t = { n = 1, p = { { fw = 1, fk = Key(0, 0), tw = 1, tk = Key(500, 500) } } } },
             [-5] = { i = { n = 1, p = { { fw = 1, fk = Key(1, 1) } } } } },
    [20] = { [10] = { w = { n = 1, p = { { fw = 1, fk = Key(100, 60), tw = 2, tk = Key(99, 60) } } } } },   -- andere Welt: nicht
} } }
assert(loadfile("CodexPath.lua"))("Freewood-Codex", { Codex = Codex })
local X = Codex.Path.Crossings()
assert(#X.list == 1, "nur zu Fuss, echte Karten, gleiche Welt: " .. #X.list)
local n = X.list[1]
assert(n.a == 10 and n.b == 20 and n.w == 1 and n.fx == 995 and n.tx == 1005 and n.fy == 505, n.fx .. "/" .. n.tx .. "/" .. n.fy)
assert(X.byFrom[10][1] == n and X.byTo[20][1] == n and not X.byFrom[20])
assert(Codex.Path.Crossings() == X, "zwischengespeichert")
print("crossings_test OK")
