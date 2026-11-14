-- Test: Codex.ShowEntry und Codex.SearchEntries (Abschnitt aus CodexUI.lua) -- texlua tests/showentry_test.lua
local src = assert(io.open("CodexUI.lua")):read("*a")
local a = assert(src:find("local SHOW_KINDS = {", 1, true))
local b = assert(src:find("-- /fwcodex near <rolle>", 1, true))
local seg = src:sub(a, b - 1)
local shownTab, went
local UI = { Show = function(_, tab) shownTab = tab end }
local built = { Go = function(kind, id) went = kind .. ":" .. id end }
local V = { quests = { [748] = { t = "Vergiftetes Wasser" } }, units = { [3067] = { n = "Pyall Silentstride" } }, objects = {} }
local Codex = { V = function() return V end, db = { names = { [2589] = "Leinenstoff" } },
    QuestTitle = function(q, id) return q.t end, NameOf = function(e) return e.n end,
    ItemName = function(self, id) return self.db.names[id] end,
    Seed = { Ready = function() return true end, IDs = function(k) return k == "units" and { 3068, 3067 } or {} end,
        Name = function(k, id) return id == 3068 and "Pyall der Zweite" or nil end, QuestTitle = function() return nil end } }
local chunk = assert(load("local Codex, UI, built = ...\n" .. seg))
chunk(Codex, UI, built)
assert(Codex.ShowEntry("quests", 748) and shownTab == "codex" and went == "quests:748")
assert(not Codex.ShowEntry("zones", 1), "unbekannte Art")
local r = Codex.SearchEntries("pyall", 8)
assert(#r == 2 and r[1].kind == "units", "eigene und Vorlage: " .. #r)
r = Codex.SearchEntries("wasser")
assert(#r == 1 and r[1].kind == "quests" and r[1].id == 748)
r = Codex.SearchEntries("leinen")
assert(#r == 1 and r[1].kind == "items" and r[1].id == 2589)
assert(#Codex.SearchEntries("p") == 0, "zu kurz")
print("showentry_test OK")
