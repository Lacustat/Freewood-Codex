local timers = {}
C_Timer = { After = function(t, f) timers[#timers+1] = f end }
_G.GetTime = function() return 0 end
FW = { Print = print, Fire = function() end }
Freewood = FW
local Codex = { db = {} }
local NS = { Codex = Codex }
C_Spell = {
  GetSpellInfo = function(id) if id == 13376 then return { name = "Feuerschild", iconID = 135806 } end if id == 5 then return { name = "A|b", iconID = 1 } end end,
  GetSpellSubtext = function(id) return id == 13376 and "Rang 2" or "" end,
}
SlashCmdList = {}
local f = loadfile("CodexCatalog.lua")
f("Freewood-Codex", NS)
local Cat = NS.Catalog
assert(Cat.Start(1, 20000, false, "s"))
local guard = 0
while #timers > 0 and guard < 1000 do local t = table.remove(timers, 1); t(); guard = guard + 1 end
local n, r, i = Cat.GetSpell(13376)
assert(n == "Feuerschild" and r == "Rang 2" and i == 135806, tostring(n))
assert(Cat.GetSpell(5) == "A/b")
assert(Cat.GetSpell(6) == nil)
print("spell ok", Codex.db.cat.s[13376])
