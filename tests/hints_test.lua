-- Test 0.55.0: Gratulation bei Stufenaufstieg (nur gerade Stufen) und Berufen, Blizzard-Stil, Icons, Sound
-- texlua tests/hints_test.lua
local timers = {}
_G.C_Timer = { After = function(_, fn) fn() end }
_G.InCombatLockdown = function() return false end
_G.UnitAffectingCombat = function() return false end
_G.UnitLevel = function() return 24 end
_G.GetMoney = function() return 5000 end
local played = {}
_G.PlaySound = function(n, ch) played[#played + 1] = { n = n, ch = ch } end
_G.SOUNDKIT = { IG_QUEST_LIST_COMPLETE = 878, READY_CHECK = 8960 }

local function noop() end
local M = {}
M.__index = function(t, k) if M[k] then return M[k] end if type(k) == "string" and k:match("^%u") then return noop end end
function M.SetSize(f, w, h) f.w, f.h = w, h end
function M.SetHeight(f, h) f.h = h end
function M.SetWidth(f, w) f.w = w end
function M.Show(f) f.shown = true end
function M.Hide(f) f.shown = false end
function M.IsShown(f) return f.shown == true end
function M.SetShown(f, v) f.shown = v and true or false end
function M.SetAlpha(f, a) f.alpha = a end
function M.SetScript(f, k, fn) f.scripts = f.scripts or {} f.scripts[k] = fn end
function M.SetText(f, t) f.text = t end
function M.SetTexture(f, t) f.tex = t end
function M.GetFrameLevel() return 5 end
function M.GetStringHeight(f) return (f.text and #f.text > 60) and 28 or 14 end
function M.CreateTexture() return setmetatable({}, M) end
function M.CreateFontString(_, _, _, obj) return setmetatable({ font = obj }, M) end
local templates = {}
function M.SetBackdrop(f, b) f.backdrop = b end
_G.CreateFrame = function(kind, name, parent, tmpl)
    if tmpl then templates[tmpl] = true end
    return setmetatable({ kind = kind, tmpl = tmpl }, M)
end
_G.UIParent = setmetatable({}, M)
_G.FreewoodDesign = {
    ClassTex = function(t) return "Pinky\\class\\pf_class_" .. t:lower() end,
    CraftTex = function(k) return "Pinky\\craft\\pf_craft_" .. k end,
}

local events, shown = {}, {}
local FW = { L = setmetatable({}, { __index = function(_, k) return k end }), Util = {} }
function FW:RegisterEvent(ev, fn) events[ev] = fn end
function FW:On() end
function FW:Fire() end
FW.UI = {
    Show = function(_, id) shown[#shown + 1] = id end,
    RegisterSettingsSection = function(_, id, def) FW.section = def end,
}
_G.Freewood = FW
-- Texte wie im Spiel (deutsch)
local chunk = assert(loadfile("Locales.lua"))
local NS = { }
local Codex = { db = { settings = { enabled = true } }, Time = { PlayerToken = function() return "HUNTER" end } }
NS.Codex = Codex
pcall(chunk, "Freewood-Codex", NS)
FW.L = setmetatable({}, { __index = function(_, k) return k end })
for k, v in pairs({ CODEX_HINT_CONGRATS = "Gratulation!", CODEX_HINT_LEVEL = "Du hast Level %d erreicht",
    CODEX_HINT_SKILL = "%s %d erreicht", CODEX_HINT_CLASS_LEAD = "Du kannst jetzt beim Klassenlehrer lernen:",
    CODEX_HINT_PROF_LEAD = "Du kannst jetzt beim Berufslehrer lernen:", CODEX_HINT_RANK_3 = "Experte",
    CODEX_HINT_RANK_LEAD = "Dein Lehrer bringt dir jetzt die nächste Stufe bei: %s (ab Stufe %d)",
    CODEX_HINT_NODATA_CLASS = "Besuch deinen Klassenlehrer einmal", CODEX_HINT_MORE = "... und %d weitere",
    CODEX_HINT_COST = "Kosten %s", CODEX_HINT_MISSING = "%s fehlt noch", CODEX_HINT_CLICK = "Klick" }) do rawset(FW.L, k, v) end

-- Lehrer-Daten
local plan = { levels = { [24] = { spells = { { nm = "Mal des Jägers", sp = 1, rk = "Rang 3", cost = 3000 },
    { nm = "Biss", sp = 2, rk = "Rang 4", cost = 4000 } } } } }
Codex.LearnPlan = function() return plan end
Codex.SpellRank = function() return nil end
Codex.SpellIcon = function(id) return "icon" .. id end
Codex.FormatMoney = function(c) return c .. "k" end
Codex.ModePrice = function(p) return p and p[1] end
Codex.V = function() return { units = {
    { ro = { proftrainer = 1 }, tr = { a = { nm = "Elixier der Stärke", sn = "Alchemie", sr = 125, pr = { 900 } } } },
} } end

assert(loadfile("CodexHints.lua"))("Freewood-Codex", NS)
local H = Codex.Hints
assert(H, "geladen")

-- ungerade Stufe: nichts
assert(H.OnLevelUp(23) == false and not H.showing, "ungerade Stufe still")
-- gerade Stufe: Gratulation mit Klassen-Icon und Liste
assert(H.OnLevelUp(24) == true and H.showing, "gerade Stufe zeigt")
local h = H.last
assert(h.icon == "Pinky\\class\\pf_class_hunter", "Klassen-Icon groß: " .. tostring(h.icon))
assert(h.title == "Gratulation!" and h.sub == "Du hast Level 24 erreicht", "Texte")
assert(h.lead == "Du kannst jetzt beim Klassenlehrer lernen:" and #h.entries == 2, "Liste")
assert(templates.BackdropTemplate, "Blizzard-Dialograhmen")
assert(#played == 1 and played[1].n == 878 and played[1].ch == "Master", "Sound Quest abgeschlossen")
H.Dismiss()

-- gerade Stufe ohne Daten: trotzdem Gratulation mit Hinweis
assert(H.OnLevelUp(26) == true, "ohne Daten trotzdem")
assert(H.last.note == "Besuch deinen Klassenlehrer einmal" and #H.last.entries == 0 and H.last.lead == nil, "Hinweis statt Liste")
H.Dismiss()


-- Berufe: neue Rezepte
H.Dismiss()
assert(H.CraftKey("Alchemie") == "alchemy" and H.CraftKey("Kräuterkunde") == "herbalism" and H.CraftKey("Schwerter") == nil, "Berufsnamen")
assert(H.OnSkill("Alchemie", 124) == false, "nichts Neues bei 124")
assert(H.OnSkill("Alchemie", 125) == true, "Rezept bei 125")
assert(H.last.icon == "Pinky\\craft\\pf_craft_alchemy" and H.last.sub == "Alchemie 125 erreicht", "Berufs-Icon und Text")
assert(H.last.lead == "Du kannst jetzt beim Berufslehrer lernen:" and #H.last.entries == 1, "Rezept-Liste")
H.Dismiss()
-- Stufengrenze 150 bei einem Sammelberuf
H.OnSkill("Kräuterkunde", 149)
assert(H.OnSkill("Kräuterkunde", 150) == true, "Stufengrenze 150")
assert(H.last.lead == "Dein Lehrer bringt dir jetzt die nächste Stufe bei: Experte (ab Stufe 20)", tostring(H.last.lead))
assert(H.last.icon == "Pinky\\craft\\pf_craft_herbalism", "Kräuterkunde-Icon")
H.Dismiss()
-- Waffenfertigkeit: still
assert(H.OnSkill("Schwerter", 75) == false, "Waffenfertigkeit still")
assert(H.CapReached(74, 75).at == 75 and H.CapReached(75, 76) == nil, "Grenze nur beim Überschreiten")

-- Sound-Auswahl
Codex.db.settings.hintSound = "ready"
played = {}
H.PlaySound()
assert(played[1].n == 8960, "Bereitschaftscheck aus SOUNDKIT")
Codex.db.settings.hintSound = "warning"
played = {}
H.PlaySound()
assert(played[1].n == 8959, "Nummer, wenn SOUNDKIT den Namen nicht kennt")
Codex.db.settings.hintSound = "none"
played = {}
H.PlaySound()
assert(#played == 0, "kein Sound")
Codex.db.settings.hintSound = "gibtsnicht"
assert(H.SoundId() == "quest", "unbekannt -> Standard")
_G.PlaySound = function() error("kein Sound in diesem Client") end
assert(H.PlaySound("quest") == false, "Fehler beim Abspielen bleibt still")

-- Kampf: wartet
_G.InCombatLockdown = function() return true end
assert(H.OnLevelUp(28) == true and not H.showing, "im Kampf wartet die Gratulation")
_G.InCombatLockdown = function() return false end
events.PLAYER_REGEN_ENABLED()
assert(H.showing and H.last.sub == "Du hast Level 28 erreicht", "nach dem Kampf gezeigt")
H.Dismiss()

-- Ereignis: PLAYER_LEVEL_UP mit Stufe
events.PLAYER_LEVEL_UP(nil, 30)
assert(H.showing and H.last.sub == "Du hast Level 30 erreicht", "Ereignis")
H.Dismiss()

-- Test-Knopf
H.Demo()
assert(H.showing and #H.last.entries > 0, "Test zeigt eine Liste")
H.Dismiss()

-- Einstellungen mit Sound-Auswahl
assert(FW.section and FW.section.height >= 400, "Abschnitt größer")
io.write("hints_test: ok\n")
