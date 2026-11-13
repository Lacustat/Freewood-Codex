-- Test: lokale Vorquest-Ueberlagerung Codex.ExtPre (texlua tests/extpre_test.lua)
-- Laedt nur den Abschnitt Ketten-Index / QuestPre / QuestNext aus Codex.lua.
local src = assert(io.open("Codex.lua")):read("*a")
local a = assert(src:find("-- Ketten-Index: Folgequests je Quest", 1, true))
local b = assert(src:find("-- Stellung in einer Kette", 1, true))
local seg = src:sub(a, b - 1)
local quests = {
    [10] = { pre = { 5 } },
    [20] = { pre = { 10 } },
    [30] = { pre = { 10 }, ed = { pre = { 99 } } },
}
local Codex = { V = function() return { quests = quests } end }
local chunk = assert(load("local Codex = ...\n" .. seg))
chunk(Codex)

local function eq(t, ...)
    local e = { ... }
    assert(#t == #e, table.concat(t, ",") .. " vs " .. table.concat(e, ","))
    for i, v in ipairs(e) do assert(t[i] == v, table.concat(t, ",")) end
end

-- ohne Ueberlagerung: wie bisher
eq(Codex.QuestPre(20), 10)
eq(Codex.QuestNext(10), 20, 30)

-- Ueberlagerung ersetzt die Vorquests von Quest 20
Codex.ExtPre[20] = { 7, 8 }
Codex.chainRev = Codex.chainRev + 1
eq(Codex.QuestPre(20), 7, 8)
eq(Codex.QuestNext(10), 30)          -- 20 haengt nicht mehr an 10
eq(Codex.QuestNext(7), 20)
eq(Codex.QuestNext(8), 20)

-- Dev-Eintrag (ed.pre) gewinnt immer
Codex.ExtPre[30] = { 1 }
Codex.chainRev = Codex.chainRev + 1
eq(Codex.QuestPre(30), 99)

-- Quest, die nur in der Ueberlagerung steht
Codex.ExtPre[40] = { 20 }
Codex.chainRev = Codex.chainRev + 1
eq(Codex.QuestPre(40), 20)
eq(Codex.QuestNext(20), 40)

-- entfernen: alles wieder wie vorher
Codex.ExtPre = {}
Codex.chainRev = Codex.chainRev + 1
eq(Codex.QuestPre(20), 10)
eq(Codex.QuestNext(10), 20, 30)
print("extpre OK")
