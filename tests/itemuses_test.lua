-- Test: Codex.Uses (Material fuer, Quest-Item fuer, Haendler), Tooltip-Zeile, Strg+Alt+Klick   texlua tests/itemuses_test.lua
local clock = 10
_G.GetTime = function() return clock end
local hooks, itemLines, options = {}, {}, {}
_G.hooksecurefunc = function(name, fn) hooks[name] = fn end
_G.HandleModifiedItemClick = function() end
_G.SetItemRef = function() end
local ctrl, alt, shift = false, false, false
_G.IsControlKeyDown = function() return ctrl end
_G.IsAltKeyDown = function() return alt end
_G.IsShiftKeyDown = function() return shift end
local dressShown, dressHook = false, nil
_G.DressUpFrame = { IsShown = function() return dressShown end, Hide = function() dressShown = false end,
    HookScript = function(_, _, fn) dressHook = fn end }
_G.HideUIPanel = function(f) f:Hide() end
_G.C_Timer = { After = function(_, fn) fn() end }
local tipOn = false
local L = setmetatable({ CODEX_TIP_VENDORBUY = "Beim Händler:", CODEX_TIP_VENDORBUY_MORE = "+%d weitere" }, { __index = function(_, k) return k end })
local FW = { L = L, Tooltips = {
    Get = function(k) return k == "tipVendorBuy" and tipOn end,
    AddItemLine = function(fn) itemLines[#itemLines + 1] = fn end,
    RegisterOption = function(k, _, def) options[k] = def end,
    Money = function(v) return v .. "c" end } }
_G.Freewood = FW
local opened
local db = { settings = {}, recipes = {
    Schneiderei = { ["Seidenstoffballen"] = { it = 4305, rg = { [4306] = 4 } }, ["Seidenes Hemd"] = { it = 4330, rg = { [4306] = 2, [2321] = 1 } } },
    Kochkunst = { ["Brot"] = { it = 1, rg = { [2] = 1 } } } } }
local view = {
    quests = { [100] = { t = "Seide für Mama", lvl = 25, mn = 20, qi = { [4306] = 10 } }, [101] = { t = "Andere", lvl = 5 },
        [102] = { t = "Ziel-Item", lvl = 30, obj = { { item = 4306, req = 5 } } } },
    units = { [1] = { n = "Händler Teuer", wa = { [4306] = { pr = { [500] = 1 } } }, cells = { [1411 * 40000 + 1] = 1 } },
        [2] = { n = "Händler Billig", wa = { [4306] = { pr = { [200] = 1, [300] = 1 } } } },
        [3] = { n = "Händler A", wa = { [4306] = { pr = { [400] = 1 } } } },
        [4] = { n = "Händler B", wa = { [4306] = { pr = { [450] = 1 } } } },
        [5] = { n = "Kein Händler" } } }
local Codex = { db = db, V = function() return view end, ShowEntry = function(k, id) opened = k .. ":" .. id return true end,
    MainMap = function(c) return c and 1411 or nil end, MapName = function(m) return m == 1411 and "Durotar" or "?" end,
    NameOf = function(e) return e.n end, QuestTitle = function(q) return q.t end,
    Recipes = { ReqOf = function(prof, name) if name == "Seidenes Hemd" then return 100 end if name == "Seidenstoffballen" then return 125 end end } }
local NS = { Codex = Codex }
assert(loadfile("CodexItemUses.lua"))("Freewood-Codex", NS)
local U = Codex.Uses

local r = U.Recipes(4306, true)
assert(#r == 2 and r[1].name == "Seidenes Hemd" and r[1].skill == 100 and r[2].n == 4 and r[2].it == 4305, "Material für, nach Skill sortiert")
assert(#U.Recipes(2321) == 1 and #U.Recipes(9999) == 0)
local q = U.Quests(4306)
assert(#q == 2 and q[1].id == 100 and q[1].mn == 20 and q[2].id == 102, "Quest-Items (qi und Ziel)")
local v = U.Vendors(4306)
assert(#v == 4 and v[1].name == "Händler Billig" and v[1].price == 200 and v[4].price == 500 and v[4].zone == "Durotar", "Händler, günstigster zuerst")

-- Tooltip: standardmaessig aus, an = hoechstens 3 + Hinweis
assert(options.tipVendorBuy and options.tipVendorBuy.default == false, "Einstellung, Standard aus")
assert(#itemLines == 1)
local lines = {}
local tt = { AddLine = function(_, t) lines[#lines + 1] = t end, AddDoubleLine = function(_, a, b) lines[#lines + 1] = a .. "|" .. b end }
itemLines[1](tt, "|Hitem:4306::|h[Seidenstoff]|h")
assert(#lines == 0, "aus: nichts")
tipOn = true
itemLines[1](tt, "|Hitem:4306::|h[Seidenstoff]|h")
assert(lines[1] == "Beim Händler:" and lines[2]:find("Händler Billig", 1, true) and lines[2]:find("200c", 1, true), "Zeilen")
assert(#lines == 5 and lines[5]:find("+1 weitere", 1, true), "hoechstens 3 und Hinweis")

-- Klick: nur mit der eingestellten Kombination
assert(hooks.HandleModifiedItemClick and hooks.SetItemRef, "Haken gesetzt")
hooks.HandleModifiedItemClick("item:4306")
assert(opened == nil, "ohne Zusatztasten nichts")
ctrl, alt = true, true
dressShown = true; dressHook()   -- Strg hat die Anprobe geoeffnet
hooks.HandleModifiedItemClick("|cff1eff00|Hitem:4306::::|h[Seidenstoff]|h|r")
assert(opened == "items:4306", "Strg+Alt oeffnet den Codex")
assert(dressShown == false, "Anprobe wieder geschlossen")
opened = nil
hooks.SetItemRef("item:4306", "x", "LeftButton")
assert(opened == nil, "derselbe Klick nur einmal")
clock = clock + 1
shift = true
hooks.SetItemRef("item:4306", "x", "LeftButton")
assert(opened == nil, "Strg+Alt+Umschalt passt nicht")
shift = false
U.SetClickSetting("off")
hooks.SetItemRef("item:4306", "x", "LeftButton")
assert(opened == nil, "aus")
U.SetClickSetting("altshift")
ctrl, alt, shift = false, true, true
hooks.SetItemRef("item:2321", "x", "LeftButton")
assert(opened == "items:2321", "Alt+Umschalt einstellbar")
print("itemuses_test OK")
