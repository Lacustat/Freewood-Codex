-- Test 0.57.0: weltweiter Abgleich per Fluestern (Kanalliste aus Core Net.lua, Hallo an zufaellige Partner, Antworten per Fluestern)
-- texlua tests/worldsync_test.lua
local fails, n = 0, 0
local function eq(a, b, msg) n = n + 1; if a ~= b then fails = fails + 1; print("FEHLER: " .. msg .. " (" .. tostring(a) .. " ~= " .. tostring(b) .. ")") end end

local clock, timers = 1000, {}
_G.GetTime = function() return clock end
_G.C_Timer = { After = function(sec, fn) timers[#timers + 1] = { t = clock + sec, fn = fn } end }
local me = "Alice Test"
_G.UnitName = function() return me end
_G.InCombatLockdown = function() return false end
local inInstance = false
_G.IsInInstance = function() return inInstance end
local sent = {}
_G.C_ChatInfo = { RegisterAddonMessagePrefix = function() end,
    SendAddonMessage = function(prefix, text, dist, target) sent[#sent + 1] = { dist = dist, target = target, text = text } return 0 end }

local admins = { ["pinky freewood"] = true, ["reddy freewood"] = true }
local netOn, roster = true, { "Bob Test", "Carl Test", "Dora Test", "Emil Test", "Fritz Test" }
local FW = { Print = function() end }
function FW:RegisterEvent() end
function FW:UnregisterEvent() end
function FW:On() end
function FW:Off() end
function FW:Fire() end
FW.Net = {
    Enabled = function() return netOn end,
    SelfIsAdmin = function() return admins[me:lower()] == true end,
    Peers = function() return roster end,
    Admins = function() return { "Pinky Freewood", "Reddy Freewood" } end,
}
_G.Freewood = FW

local Share = {
    Summary = function() return 5, 12345 end,
    Sender = function() return nil end,
    Store = function() return {} end,
}
local Codex = { db = { settings = { share = true } } }
local NS = { Codex = Codex, Share = Share }
assert(loadfile("CodexSync.lua"))("Freewood-Codex", NS)
local Sync = NS.Sync

local function Run(sec)
    local stop = clock + sec
    while clock < stop do
        clock = clock + 0.25
        for i = #timers, 1, -1 do
            if timers[i].t <= clock then local t = table.remove(timers, i); t.fn() end
        end
        Sync:Pump()
    end
end

eq(Sync.KindOf("WHISPER"), "whisper", "Fluestern hat eine eigene Art")
eq(Sync:WorldEnabled(), true, "weltweit an")

-- Runde: 3 zufaellige Partner, per WHISPER-Hallo
eq(Sync:Gossip(), 3, "drei Partner gerufen")
Run(30)
local hellos, targets = 0, {}
for _, m in ipairs(sent) do
    if m.dist == "WHISPER" and m.text == "H|12345|5" then hellos = hellos + 1; targets[m.target] = true end
end
eq(hellos, 3, "drei Hallos per Fluestern")
-- naechste Runde: nur die zwei uebrigen (dieselben erst nach einer Stunde)
eq(Sync:Gossip(), 2, "nur noch zwei neue Partner")
eq(Sync:Gossip(), 0, "alle schon gerufen")
clock = clock + 3601
eq(Sync:Gossip(), 3, "nach einer Stunde wieder")

-- nicht in Instanzen
clock = clock + 7300
inInstance = true
eq(Sync:Gossip(), 0, "nicht in Instanzen")
inInstance = false

-- Hallo per Fluestern von einem Fremden: Anfrage Q geht per Fluestern zurueck, dazu einmal ein Hallo
sent = {}
eq(Sync:HandleMessage("WHISPER", "Gustav Test", "H|999|4"), true, "Hallo angenommen")
Run(30)
local q, h = nil, nil
for _, m in ipairs(sent) do
    if m.text:sub(1, 2) == "Q|" then q = m end
    if m.text:sub(1, 2) == "H|" and m.target == "Gustav Test" then h = m end
end
eq(q and q.dist, "WHISPER", "Anfrage per Fluestern")
eq(q and q.target, "Gustav Test", "an den Absender")
eq(q and q.text:sub(1, 14), "Q|Gustav Test|", "Empfaengername in der Nachricht")
eq(h and h.dist, "WHISPER", "Hallo zurueck per Fluestern")
-- zweites Hallo: kein weiteres Hallo zurueck (keine Endlosschleife)
sent = {}
clock = clock + 700
Sync:HandleMessage("WHISPER", "Gustav Test", "H|999|4")
Run(30)
local again = 0
for _, m in ipairs(sent) do if m.text:sub(1, 2) == "H|" then again = again + 1 end end
eq(again, 0, "kein zweites Hallo innerhalb einer Stunde")

-- per Fluestern nur H, Q, V, R, B
eq(Sync:HandleMessage("WHISPER", "Gustav Test", "T|irgendwas"), false, "Berechtigungsliste nicht per Fluestern")
eq(Sync:HandleMessage("WHISPER", "Gustav Test", "N|irgendwas"), false, "Ankuendigung nicht per Fluestern")

-- ausgeschaltet: nichts
netOn = false
eq(Sync:WorldEnabled(), false, "aus")
eq(Sync:Gossip(), 0, "aus: keine Runde")
eq(Sync:HandleMessage("WHISPER", "Hans Test", "H|1|1"), false, "aus: Fluestern ignoriert")
netOn = true

-- Admin-Charakter nimmt nicht teil
me = "Pinky Freewood"
eq(Sync:WorldEnabled(), false, "Admin: weltweit aus (Daten kommen in den Posteingang)")
eq(Sync:HandleMessage("WHISPER", "Hans Test", "H|1|1"), false, "Admin ignoriert Fluester-Hallo")
me = "Alice Test"

-- Eigentuemer = Admin-Liste + Zusatznamen
local NS2 = {}
assert(loadfile("CodexOwners.lua"))("Freewood-Codex", NS2)
eq(NS2.Owners[1], "Pinky Freewood", "Eigentuemer aus der Admin-Liste")
eq(NS2.Owners[3], "Aroki Silberrücken", "Zusatzname bleibt")
FW.Net = nil
NS2 = {}
assert(loadfile("CodexOwners.lua"))("Freewood-Codex", NS2)
eq(#NS2.Owners, 9, "Rueckfall ohne Net: 8 Admins + Zusatz")

print(string.format("worldsync_test: %d Pruefungen, %d Fehler", n, fails))
os.exit(fails == 0 and 0 or 1)
