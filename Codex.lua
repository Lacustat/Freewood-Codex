-- Freewood-Codex: lernt Quests, Kreaturen und Beute beim Spielen.
--
-- Gespeichert (Account-weit) in Codex.db:
--   quests[questID] = {
--     t = Titel, lvl = Stufe, pl = niedrigste Spielerstufe bei Annahme, zone = Karte der Annahme,
--     give = Ref, turn = Ref,                       -- Ref = { k="npc"|"object"|"other", id, n, m, x, y }
--     xp, money, rep = { [Fraktion] = Wert },
--     fixed = { { id, c } }, choice = { { id, c } }, chosen = { [itemID] = Anzahl },
--     obj = { { ty, name, txt, req, ids = { [npcID] = Treffer } } },
--     qi = { [itemID] = { ["u<id>"|"o<id>"] = Anzahl } },   -- Quest-Items und ihre Quellen
--     seen, done, first, last, partial }
--   units[npcID]   = { n, l1, l2, c, cells = { [m*GRID^2+zelle] = n },
--                      k = gelootete Leichen, coin, coinN, d = { [itemID] = { n, q, qi } },
--                      alt = { k, d } }                 -- alt: zweites Beutefenster (Haeuten usw.)
--   objects[objID] = wie units (ohne Stufen)
--   names[itemID]  = Itemname (fuer die Suche)
--   xp[spielerstufe][gegnerstufe][klasse] = { n, sum, min, max }   Kill-Erfahrung ohne Zusaetze
--   xpb[...]                                gleiche Form, aber mit Ruhe-/Gruppen-/Raidzusatz
--   units[npcID].xp[spielerstufe] = { n, sum, min, max }
--   units[npcID].xm[spielerstufe][gegnerstufe] = { n, sum, min, max }
--   quests[id].obj[i].item = Item-ID, gelernt aus dem Beutefenster, wenn der Zaehler steigt
--   objEmpty = Ziele ohne lesbaren Namen (max. 5, fuer /fwcodex test)
--   objects[id].n = Name, vom Objekt-Tooltip gelernt
--   units[npcID].f = Tierfamilie (Text)
--   remote[absender] = { seen, n, cursor, hash, rec = { ["u123"] = bereinigter Datensatz } }   empfangene Daten (CodexShare.lua)
--   sync = { stamps = { ["u123"] = { sig, upd } }, sent, received }                       Aenderungsstaende eigener Daten
--   settings.share = ein Schalter fuer das gesamte Teilen
--
-- Geheime Werte (secret values) werden mit Util.Clean verworfen, jede Erfassung laeuft geschuetzt.
-- Kein Kampflog: Beute, Quest-Fenster und Ziele werden ausserhalb des Kampfes gelesen.

local ADDON, NS = ...

local FW = _G.Freewood
if not FW or not FW:RequireAPI(1, ADDON) then
    return
end

local Util = FW.Util
local L = FW.L

local GRID = 200
local MAX_CELLS = 600
local MAX_DROPS = 80
local MAX_OBJ = 12
local MAX_REWARDS = 12
local MAX_IDS = 12
local MAX_NAMES = 6000
local MAX_LOOTED_GUIDS = 300
local RECENT_SECS = 60 -- so lange passt ein gelootetes Quest-Item zu einem steigenden Zaehler

local function GetMeta(field)
    local fn = (C_AddOns and C_AddOns.GetAddOnMetadata) or GetAddOnMetadata
    if fn then
        local ok, value = pcall(fn, ADDON, field)
        if ok then
            return value
        end
    end
    return nil
end

local Codex = FW:NewModule("Codex", {
    version = GetMeta("Version") or "dev",
    title = L.CODEX_TITLE,
    description = L.CODEX_DESC,
    defaults = {
        quests = {},
        units = {},
        objects = {},
        names = {},
        ttk = {},      -- Kampfdauer { [Klasse] = { [Spielerstufe] = { [Stufenabstand] = { n, sum, min, max } } } }, Zehntelsekunden
        qtimer = {},   -- laufende Quest-Zeitnehmer (siehe CodexTime.lua)
        istats = {},   -- Itemwerte { [itemID] = { [Schluessel] = Zahl } }, vom Spiel gelesen (nur lokal)
        disp = {},     -- Creature-Display-IDs fuer 2D-Bilder { [npcID] = displayID } (nur lokal)
        cnames = {},   -- von Hand eingetragene Itemnamen { [itemID] = { de, en } }
        xp = {},
        xpb = {},
        xr = {},       -- Erfahrung je Kill MIT Ruhebonus (Gesamtwert), gleiche Form wie xp (nur lokal)
        xpUnparsed = {},
        objEmpty = {},
        remote = {},
        sync = { stamps = {}, sent = 0, received = 0 },
        settings = { enabled = true, share = true, shareDefaultOn = true },
        recipes = {},  -- Rezepte der Berufe { [Beruf] = { [Name] = { it, rg, ob } } } (siehe CodexRecipes.lua, nur lokal)
        wrq = {},      -- Ruf-Anforderungen der Waren { [haendlerID] = { v = 1, [itemID] = { f = Fraktion, s = Stufe 1-8, ok = erfuellt } } } (nur lokal)
        vfac = {},     -- Fraktion von Haendlern { [haendlerID] = "A" | "H" } (nur lokal)
        ied = {},      -- Eigenschaften von Items { [itemID] = { ed = { z, dg } } }, wird geteilt
        inames = {},   -- vom Spiel gelernte Instanznamen { [instanceID] = Name } (nur lokal)
        iicon = {},    -- gemerkte Symbole { [itemID] = Pfad }, vom Spiel gelesen (nur lokal)
        path = {},     -- Wegenetz { [welt] = { [zellKey] = Maske } }, siehe CodexPath.lua (nur lokal)
        fav = {},      -- Favoriten und Notizen { ["q123"] = { note, t } }, nur lokal
        dnotes = {},   -- Dev-Notizen { ["q123"] = { n = Text, t } }, nur lokal, nur mit Freewood-Dev und Bearbeitungsrecht
    },
})
NS.Codex = Codex
FW.Codex = Codex
Codex.GRID = GRID

local state = {
    pool = nil,          -- Ruhe-Vorrat (GetXPExhaustion) vor dem naechsten Kill
    xpOpen = 0,          -- Kills, deren Ruhebonus noch bestimmt wird
    xpJobs = {},
    detail = nil,        -- zuletzt geoeffnetes Annahme-Fenster
    turn = nil,          -- zuletzt geoeffnetes Abgabe-Fenster
    objState = {},       -- [questID] = { [i] = Anzahl }
    recentItems = {},    -- [itemID] = { t, quest, qid }: zuletzt gelootete Items
    requested = {},      -- [itemID] = true: Itemdaten schon angefordert
    pendingInfo = 0,     -- noch nicht angekommene Itemdaten
    objNames = {},       -- [objectID] = Name, vom Tooltip gelernt, bevor das Objekt gelootet wurde
    repBuf = {},         -- { t, name, amount }
    lootedGuids = {},    -- Leichen, die in dieser Sitzung schon ein Beutefenster hatten
    lootedItems = {},    -- [guid] = { [itemID] = true }: dort schon gezaehlte Items
    lootedCount = 0,
    noteAt = {},         -- Drosselung fuer NoteUnit
    stats = { quests = 0, loot = 0, errors = 0 },
}
Codex.runtime = state

------------------------------------------------------------------------
-- Kleine Pruefer
------------------------------------------------------------------------

local function Num(v)
    if Util.IsSecret(v) then
        return nil
    end
    if type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge then
        return v
    end
    return nil
end

local function Str(v, max)
    if Util.IsSecret(v) then
        return nil
    end
    if type(v) == "string" and v ~= "" then
        return v:sub(1, max or 80)
    end
    return nil
end

local function Strip(text)
    text = text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub("|T.-|t", "")
    return (text:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function Now()
    return time()
end

-- Fuehrt fn geschuetzt aus; Fehler (zum Beispiel durch geheime Werte) werden still gezaehlt
local function Safe(fn, ...)
    local ok, a, b, c = pcall(fn, ...)
    if not ok then
        state.stats.errors = state.stats.errors + 1
        if FW.settings and FW.settings.debug then
            FW:Debug("Codex: " .. tostring(a))
        end
        return nil
    end
    return a, b, c
end

------------------------------------------------------------------------
-- Orte und Raster
------------------------------------------------------------------------

local function PlayerPoint()
    local loc = Util.GetPlayerLocation()
    if loc and loc.mapID and loc.x and loc.y then
        return loc.mapID, loc.x, loc.y
    end
    return nil
end

local function CellKey(m, x, y)
    local cx = math.min(GRID - 1, math.max(0, math.floor(x * GRID)))
    local cy = math.min(GRID - 1, math.max(0, math.floor(y * GRID)))
    return m * GRID * GRID + cy * GRID + cx
end

local function NoteInstance(ent)
    local id = Codex.CurrentInstance and Codex.CurrentInstance()
    if not id then return end
    local iz = ent.iz
    if not iz then
        iz = {}
        ent.iz = iz
    end
    if iz[id] then
        iz[id] = iz[id] + 1
        return
    end
    local n = 0
    for _ in pairs(iz) do n = n + 1 end
    if n < 3 then iz[id] = 1 end
end

local function AddCell(ent)
    NoteInstance(ent)
    local m, x, y = PlayerPoint()
    if not m then
        return
    end
    ent.cells = ent.cells or {}
    local key = CellKey(m, x, y)
    if ent.cells[key] then
        ent.cells[key] = ent.cells[key] + 1
        return
    end
    local n = 0
    for _ in pairs(ent.cells) do
        n = n + 1
        if n >= MAX_CELLS then
            return
        end
    end
    ent.cells[key] = 1
end

-- Rueckgabe: Karten-ID und Zelle als Liste { { m, cx, cy, n } }
function Codex.DecodeCells(cells)
    local list = {}
    for key, n in pairs(cells or {}) do
        local m = math.floor(key / (GRID * GRID))
        local idx = key % (GRID * GRID)
        list[#list + 1] = { m = m, cx = idx % GRID, cy = math.floor(idx / GRID), n = n }
    end
    return list
end

------------------------------------------------------------------------
-- Instanzen: das Spiel nennt in Dungeons oft keinen Namen, aber die Instanz-ID (GetInstanceInfo, 8. Rueckgabe).
-- Die ID ist sprachunabhaengig. Als "Zone" wird sie negativ gespeichert (-389 = Flammenschlund).
------------------------------------------------------------------------

Codex.INSTANCES = {
    [30] = { "Alteractal", "Alterac Valley" }, [33] = { "Burg Schattenfang", "Shadowfang Keep" },
    [34] = { "Das Verlies", "The Stockade" }, [36] = { "Die Todesminen", "The Deadmines" },
    [43] = { "Die Höhlen des Wehklagens", "Wailing Caverns" }, [47] = { "Kral der Klingenhauer", "Razorfen Kraul" },
    [48] = { "Die Tiefschwarze Grotte", "Blackfathom Deeps" }, [70] = { "Uldaman", "Uldaman" },
    [90] = { "Gnomeregan", "Gnomeregan" }, [109] = { "Der Tempel von Atal'Hakkar", "The Temple of Atal'Hakkar" },
    [129] = { "Hügel der Klingenhauer", "Razorfen Downs" }, [189] = { "Das Scharlachrote Kloster", "Scarlet Monastery" },
    [209] = { "Zul'Farrak", "Zul'Farrak" }, [229] = { "Schwarzfelsspitze", "Blackrock Spire" },
    [230] = { "Die Schwarzfels-Tiefen", "Blackrock Depths" }, [249] = { "Onyxias Hort", "Onyxia's Lair" },
    [289] = { "Scholomance", "Scholomance" }, [309] = { "Zul'Gurub", "Zul'Gurub" },
    [329] = { "Stratholme", "Stratholme" }, [349] = { "Maraudon", "Maraudon" },
    [369] = { "Die Tiefenbahn", "The Deeprun Tram" }, [389] = { "Flammenschlund", "Ragefire Chasm" },
    [409] = { "Geschmolzener Kern", "Molten Core" }, [429] = { "Düsterbruch", "Dire Maul" },
    [469] = { "Pechschwingenhort", "Blackwing Lair" }, [489] = { "Kriegshymnenschlucht", "Warsong Gulch" },
    [509] = { "Ruinen von Ahn'Qiraj", "Ruins of Ahn'Qiraj" }, [529] = { "Arathibecken", "Arathi Basin" },
    [531] = { "Tempel von Ahn'Qiraj", "Temple of Ahn'Qiraj" }, [533] = { "Naxxramas", "Naxxramas" },
}

-- Name einer Instanz: eingebaute Liste (Deutsch / Englisch), sonst vom Spiel gelernt, sonst "Instanz #ID"
function Codex.InstanceName(id)
    local en = Codex.Lang() == "en"
    local b = Codex.INSTANCES[id]
    if b then return en and b[2] or b[1] end
    local learned = Codex.db and Codex.db.inames and Codex.db.inames[id]
    if learned then return learned end
    return string.format(FW.L.CODEX_INSTANCE_UNKNOWN or "Instance #%d", id)
end

-- Instanz-ID, in der wir gerade stehen (nil in der offenen Welt)
function Codex.CurrentInstance()
    if not (IsInInstance and GetInstanceInfo) then return nil end
    local ok, inside, itype = pcall(IsInInstance)
    if not ok or Util.IsSecret(inside) or not inside or Util.IsSecret(itype) or itype == "none" then return nil end
    local ok2, name, _, _, _, _, _, _, id = pcall(GetInstanceInfo)
    if not ok2 or Util.IsSecret(id) or type(id) ~= "number" or id < 1 or id > 100000 then return nil end
    -- lesbaren Namen fuer unbekannte Instanzen merken (nur lokal, in der aktuellen Sprache)
    if type(name) == "string" and name ~= "" and not Util.IsSecret(name) and not Codex.INSTANCES[id] and Codex.db then
        Codex.db.inames = Codex.db.inames or {}
        Codex.db.inames[id] = name:sub(1, 60)
    end
    return id
end

function Codex.MapName(mapID)
    if type(mapID) == "number" and mapID < 0 then
        return Codex.InstanceName(-mapID)
    end
    if C_Map and C_Map.GetMapInfo and mapID then
        local ok, info = pcall(C_Map.GetMapInfo, mapID)
        if ok and type(info) == "table" and type(info.name) == "string" then
            return info.name
        end
    end
    return mapID and ("#" .. mapID) or "?"
end

-- Hauptkarte einer Zellenmenge: Karte mit den meisten Treffern
function Codex.MainMap(cells)
    local per, best, bestN = {}, nil, 0
    for key, n in pairs(cells or {}) do
        local m = math.floor(key / (GRID * GRID))
        per[m] = (per[m] or 0) + n
        if per[m] > bestN then
            best, bestN = m, per[m]
        end
    end
    return best
end

------------------------------------------------------------------------
-- GUIDs, Einheiten, Objekte
------------------------------------------------------------------------

-- "Creature-0-4621-1-27730-4107-0000477262" -> "npc", 4107; GameObject -> "object", id
local function ParseGUID(guid)
    if Util.IsSecret(guid) or type(guid) ~= "string" then
        return nil
    end
    local kind, _, _, _, _, id = strsplit("-", guid)
    id = tonumber(id)
    if not id then
        return nil
    end
    if kind == "Creature" or kind == "Vehicle" then
        return "npc", id
    end
    if kind == "GameObject" then
        return "object", id
    end
    return nil
end
Codex.ParseGUID = ParseGUID

function Codex:Unit(id, create)
    local u = self.db.units[id]
    if not u and create then
        u = {}
        self.db.units[id] = u
    end
    return u
end

function Codex:Object(id, create)
    local o = self.db.objects[id]
    if not o and create then
        o = {}
        self.db.objects[id] = o
    end
    return o
end

function Codex:Quest(id, create)
    local q = self.db.quests[id]
    if not q and create then
        q = { seen = 0, done = 0, first = Now() }
        self.db.quests[id] = q
        state.stats.quests = state.stats.quests + 1
    end
    return q
end

local function NoteName(itemID, name)
    name = Str(name, 80)
    if not itemID or not name then
        return
    end
    local names = Codex.db.names
    if names[itemID] == name then
        return
    end
    if names[itemID] == nil then
        local n = 0
        for _ in pairs(names) do
            n = n + 1
            if n >= MAX_NAMES then
                return
            end
        end
    end
    names[itemID] = name
end

-- Qualitaet (Farbe) eines Items merken, damit Namen auch farbig sind, wenn das Spiel das Item gerade nicht kennt
function Codex.RememberQuality(itemID, quality)
    if type(itemID) ~= "number" or type(quality) ~= "number" or quality < 0 or quality > 8 then
        return
    end
    local iq = Codex.db.iq
    if not iq then
        iq = {}
        Codex.db.iq = iq
    end
    if iq[itemID] == quality then
        return
    end
    if iq[itemID] == nil then
        local n = 0
        for _ in pairs(iq) do
            n = n + 1
            if n >= 8000 then
                return
            end
        end
    end
    iq[itemID] = quality
end

function Codex.QualityOf(itemID)
    local info = Util.GetItem(itemID)
    if info and info.quality then
        Codex.RememberQuality(itemID, info.quality)
        return info.quality
    end
    return Codex.db.iq and Codex.db.iq[itemID] or nil
end

-- Itemdaten, die das Spiel liefert (Name, Qualitaet, Symbol), merken: nach einem Neustart sind sie sonst weg und die Listen
-- zeigen erst wieder "#1234" und Fragezeichen, bis alles neu abgefragt ist. Das Symbol steht in db.iicon (hoechstens 12000 Eintraege).
local MAX_ICONS = 12000
function Codex.RememberItem(itemID, info)
    if type(itemID) ~= "number" or type(info) ~= "table" or not Codex.db then return end
    if info.name then NoteName(itemID, info.name) end
    if info.quality then Codex.RememberQuality(itemID, info.quality) end
    local icon = info.icon
    if type(icon) == "string" and icon ~= "" and not Util.IsSecret(icon) then
        local ic = Codex.db.iicon
        if not ic then ic = {} Codex.db.iicon = ic end
        if ic[itemID] ~= icon and (ic[itemID] ~= nil or (Codex.db.iiconN or 0) < MAX_ICONS) then
            if ic[itemID] == nil then Codex.db.iiconN = (Codex.db.iiconN or 0) + 1 end
            ic[itemID] = icon:sub(1, 120)
        end
    end
end

-- Gemerktes Symbol (Pfad) eines Items oder nil
function Codex.IconOf(itemID)
    local ic = Codex.db and Codex.db.iicon
    return ic and ic[itemID] or nil
end

if Util.RequestItem and not Codex.itemHooked then
    Codex.itemHooked = true
    local baseRequest = Util.RequestItem
    Util.RequestItem = function(itemID, callback)
        return baseRequest(itemID, function(info)
            if info then pcall(Codex.RememberItem, itemID, info) end
            if callback then return callback(info) end
        end)
    end
end

Codex.AddCell = AddCell
Codex.NoteName = NoteName
Codex.Str = Str
Codex.Safe = Safe

-- Einheit am Unit-Token beobachten (Name, Stufe, Fundort). Nur angreifbare Kreaturen.
function Codex:NoteUnit(unit)
    if Util.IsSecret(unit) or not UnitExists(unit) then
        return
    end
    local isPlayer, controlled = UnitIsPlayer(unit), UnitPlayerControlled(unit)
    if Util.IsSecret(isPlayer) or Util.IsSecret(controlled) or isPlayer or controlled then
        return
    end
    local canAttack = UnitCanAttack and UnitCanAttack("player", unit)
    if Util.IsSecret(canAttack) or not canAttack then
        return
    end
    local kind, id = ParseGUID(UnitGUID(unit))
    if kind ~= "npc" then
        return
    end
    local now = GetTime and GetTime() or 0
    if state.noteAt[id] and now - state.noteAt[id] < 1.5 then
        return
    end
    state.noteAt[id] = now

    local u = self:Unit(id, true)
    local name = Str(UnitName(unit), 60)
    if name then
        u.n = name
    end
    local lvl = Num(UnitLevel and UnitLevel(unit))
    if lvl and lvl > 0 then
        u.l1 = u.l1 and math.min(u.l1, lvl) or lvl
        u.l2 = u.l2 and math.max(u.l2, lvl) or lvl
    end
    local class = UnitClassification and Str(UnitClassification(unit), 16)
    if class and class ~= "normal" and class ~= "trivial" and class ~= "minus" then
        u.c = class
    end
    local family = UnitCreatureFamily and Str(UnitCreatureFamily(unit), 40)
    if family then
        u.f = family
    end
    AddCell(u)
end

-- Objektnamen kommen vom Tooltip (Mouseover auf Truhe, Kraut usw.); data.id ist die Objekt-ID
function Codex:OnObjectTooltip(data)
    Safe(function()
        if type(data) ~= "table" or Util.IsSecret(data) or not self.db.settings.enabled then
            return
        end
        if TooltipUtil and TooltipUtil.SurfaceArgs then
            pcall(TooltipUtil.SurfaceArgs, data)
        end
        local id = Num(data.id)
        local line = type(data.lines) == "table" and data.lines[1] or nil
        local name = type(line) == "table" and Str(line.leftText, 60) or nil
        if not id or not name then
            return
        end
        Codex.lastObject = { id = id, name = name, t = (GetTime and GetTime()) or 0 }
        local o = self.db.objects[id]
        if o then
            o.n = name
        else
            local count = 0
            for _ in pairs(state.objNames) do count = count + 1 end
            if count >= 200 then
                state.objNames = {}
            end
            state.objNames[id] = name
        end
    end)
end

function Codex:OnTargetChanged()
    Safe(self.NoteUnit, self, "target")
    if self.Names then Safe(self.Names.Read, self.Names, "target", "target") end
end

function Codex:OnMouseover()
    Safe(self.NoteUnit, self, "mouseover")
    if self.Names then Safe(self.Names.Read, self.Names, "mouseover", "mouse") end
end

------------------------------------------------------------------------
-- Quest-Fenster lesen
------------------------------------------------------------------------

-- NPC oder Objekt, mit dem gerade gesprochen wird. nil bei Item-Quests.
local function ReadInteraction()
    local ref = { k = "other" }
    local guid = UnitGUID and UnitGUID("npc")
    local kind, id = ParseGUID(guid)
    if kind then
        ref.k = kind
        ref.id = id
        ref.n = Str(UnitName("npc"), 60)
        if kind == "npc" then
            local u = Codex:Unit(id, true)
            if ref.n then
                u.n = ref.n
            end
        else
            local o = Codex:Object(id, true)
            if ref.n then
                o.n = ref.n
            end
        end
    end
    local m, x, y = PlayerPoint()
    if m then
        ref.m, ref.x, ref.y = m, Util.Round(x, 3), Util.Round(y, 3)
    end
    return ref
end

local function ItemIDFromLink(link)
    link = Util.Clean(link)
    if type(link) ~= "string" then
        return nil
    end
    return tonumber(link:match("item:(%d+)"))
end

local function ReadRewardList(kind, count)
    local list = {}
    for i = 1, math.min(count or 0, MAX_REWARDS) do
        local link = GetQuestItemLink and GetQuestItemLink(kind, i)
        local id = ItemIDFromLink(link)
        local name, _, c
        if GetQuestItemInfo then
            name, _, c = GetQuestItemInfo(kind, i)
        end
        if id then
            list[#list + 1] = { id = id, c = Num(c) or 1 }
            NoteName(id, name)
        end
    end
    return list
end

local function ReadRewards()
    local r = {}
    r.xp = Num(GetRewardXP and GetRewardXP())
    r.money = Num(GetRewardMoney and GetRewardMoney())
    r.fixed = ReadRewardList("reward", Num(GetNumQuestRewards and GetNumQuestRewards()))
    r.choice = ReadRewardList("choice", Num(GetNumQuestChoices and GetNumQuestChoices()))
    return r
end

local function ApplyRewards(q, r, final)
    if not r then
        return
    end
    if r.xp and r.xp > 0 and (final or not q.xp) then
        q.xp = r.xp
    end
    if r.money and (final or not q.money) then
        q.money = r.money
    end
    if #r.fixed > 0 or final then
        q.fixed = #r.fixed > 0 and r.fixed or nil
    end
    if #r.choice > 0 or final then
        q.choice = #r.choice > 0 and r.choice or nil
    end
end

------------------------------------------------------------------------
-- Quest-Ziele
------------------------------------------------------------------------

-- Nur das Verb ("getötet") ist kein Name: so entstanden Ziele ohne Namen, wenn der Server den Kreaturnamen noch nicht kannte
local VERB_ONLY = { ["getötet"] = true, ["besiegt"] = true, ["erschlagen"] = true, ["slain"] = true, ["killed"] = true, ["defeated"] = true }
function Codex.IsBadObjName(name)
    return type(name) == "string" and VERB_ONLY[name:lower()] == true
end

local function ObjectiveName(text)
    text = Strip(text)
    local name = text:match("^(.-):%s*%d+%s*/%s*%d+") or text:match("^%d+%s*/%s*%d+%s+(.+)$") or text
    -- Kill-Ziele heissen "Wolf getoetet" / "Wolf slain": das Verb gehoert nicht zum Namen
    for _, suffix in ipairs({ " getötet", " besiegt", " erschlagen", " slain", " killed", " defeated" }) do
        if name:sub(-#suffix) == suffix then
            name = name:sub(1, #name - #suffix)
            break
        end
    end
    name = name:gsub("^[%s:]+", ""):gsub("[%s:]+$", "")
    -- Nur Zaehler ohne Namen ("0/3"): kein Name
    if name == "" or name:match("^%d+%s*/%s*%d+$") or Codex.IsBadObjName(name) then
        return nil
    end
    return name:sub(1, 60)
end

-- Ziele ohne lesbaren Namen merken (fuer /fwcodex test)
local function NoteEmptyObjective(ty, text)
    local list = Codex.db and Codex.db.objEmpty
    if not list or #list >= 5 then
        return
    end
    local entry = tostring(ty) .. " | " .. tostring(text):sub(1, 100)
    for _, e in ipairs(list) do
        if e == entry then
            return
        end
    end
    list[#list + 1] = entry
end

-- Liest die Ziele einer Quest: Liste { ty, text, name, have, req, done }
local function ReadObjectives(questID)
    local list = {}
    if C_QuestLog and C_QuestLog.GetQuestObjectives then
        local objs = C_QuestLog.GetQuestObjectives(questID)
        if type(objs) == "table" then
            for _, o in ipairs(objs) do
                if type(o) == "table" then
                    local text = Str(o.text, 120)
                    list[#list + 1] = {
                        ty = Str(o.type, 16) or "event",
                        text = text and Strip(text) or "",
                        have = Num(o.numFulfilled) or 0,
                        req = Num(o.numRequired) or 0,
                        done = o.finished and true or false,
                    }
                end
            end
        end
        return list
    end
    local index = GetQuestLogIndexByID and GetQuestLogIndexByID(questID)
    if index and GetNumQuestLeaderBoards then
        for i = 1, GetNumQuestLeaderBoards(index) do
            local text, ty, done = GetQuestLogLeaderBoard(i, index)
            text = Str(text, 120)
            local have, req = (text or ""):match("(%d+)%s*/%s*(%d+)")
            list[#list + 1] = {
                ty = Str(ty, 16) or "event",
                text = text and Strip(text) or "",
                have = tonumber(have) or 0,
                req = tonumber(req) or 0,
                done = done and true or false,
            }
        end
    end
    return list
end

local function StoreObjectives(q, list)
    local old = q.obj or {}
    local new = {}
    for i, o in ipairs(list) do
        if i > MAX_OBJ then
            break
        end
        local prev = old[i]
        local nm = o.text ~= "" and ObjectiveName(o.text) or nil
        if not nm and prev and prev.name and not Codex.IsBadObjName(prev.name) then
            nm = prev.name    -- ein schon bekannter Name geht nicht wieder verloren
        end
        new[i] = {
            ty = o.ty,
            txt = o.text ~= "" and o.text:sub(1, 100) or nil,
            name = nm,
            req = o.req > 0 and o.req or nil,
            ids = prev and prev.ids or nil,
            item = prev and prev.item or nil,
        }
        if not new[i].name and not new[i].item then
            NoteEmptyObjective(o.ty, o.text)
        end
    end
    if #new > 0 then
        q.obj = new
    end
end

local function QuestLogInfo(questID)
    if C_QuestLog and C_QuestLog.GetLogIndexForQuestID then
        local index = C_QuestLog.GetLogIndexForQuestID(questID)
        if index and C_QuestLog.GetInfo then
            local info = C_QuestLog.GetInfo(index)
            if type(info) == "table" then
                return Str(info.title, 100), Num(info.level)
            end
        end
    end
    if GetQuestLogIndexByID and GetQuestLogTitle then
        local index = GetQuestLogIndexByID(questID)
        if index and index > 0 then
            local title, level = GetQuestLogTitle(index)
            return Str(title, 100), Num(level)
        end
    end
    return nil
end

local function TrackObjectives(questID, list)
    local counts = {}
    for i, o in ipairs(list) do
        counts[i] = o.have
    end
    state.objState[questID] = counts
end

-- Ziele aller Quests im Log pruefen; steigt ein Kill-Zaehler, wird das anvisierte Ziel gelernt
function Codex:CheckObjectives()
    for questID, counts in pairs(state.objState) do
        local list = ReadObjectives(questID)
        local q = self:Quest(questID, false)
        if #list == 0 then
            state.objState[questID] = nil
        else
            for i, o in ipairs(list) do
                local before = counts[i]
                local entry = q and q.obj and q.obj[i]
                if entry then
                    -- fehlender Name: aus dem aktuellen Text nachtragen (Itemnamen sind oft erst spaeter geladen)
                    if (not entry.name or Codex.IsBadObjName(entry.name)) and o.text ~= "" then
                        local nm = ObjectiveName(o.text)
                        if nm then
                            entry.name = nm
                            entry.txt = o.text:sub(1, 100)
                            if self.LinkObjectives then self.LinkObjectives(q, questID) end
                        end
                    end
                    if before and o.have > before then
                        if o.ty == "monster" then
                            self:LearnKillTarget(entry, o)
                        elseif o.ty == "item" then
                            self:LearnObjectiveItem(questID, entry)
                        end
                    end
                end
                counts[i] = o.have
            end
            if #list ~= #(q and q.obj or {}) and q then
                StoreObjectives(q, list)
            end
        end
    end
end

-- Steigt der Zaehler eines Sammel-Ziels, war es meist das Quest-Item, das gerade gelootet wurde.
-- Genau ein Kandidat (oder ein Namenstreffer) wird dem Ziel zugeordnet.
function Codex:LearnObjectiveItem(questID, entry)
    if entry.item then
        return
    end
    local now = Now()
    local want = entry.name and entry.name:lower()
    local found, count, exact = nil, 0, nil
    for itemID, r in pairs(state.recentItems) do
        if now - r.t <= RECENT_SECS and r.quest and (not r.qid or r.qid == 0 or r.qid == questID) then
            count = count + 1
            found = itemID
            local nm = self.db.names[itemID]
            if want and nm and nm:lower() == want then
                exact = itemID
            end
        end
    end
    if exact then
        entry.item = exact
    elseif count == 1 then
        entry.item = found
    end
end

-- Items eines Ziels: gelernte Item-ID, Namenstreffer oder (bei genau einem Item-Ziel) die Quest-Items der Quest
function Codex.ObjectiveItems(q, o)
    local ids = {}
    if o.item then
        ids[1] = o.item
        return ids
    end
    local lname = o.name and o.name:lower()
    if lname then
        for itemID, name in pairs(Codex.db.names) do
            if name:lower() == lname then
                ids[#ids + 1] = itemID
            end
        end
    end
    if #ids == 0 and o.ty == "item" and q.qi then
        local itemObjs = 0
        for _, ob in ipairs(q.obj or {}) do
            if ob.ty == "item" then
                itemObjs = itemObjs + 1
            end
        end
        if itemObjs == 1 then
            for itemID in pairs(q.qi) do
                ids[#ids + 1] = itemID
            end
        end
    end
    table.sort(ids)
    return ids
end

-- Kill-Ziele einer Quest mit den Kreaturen der Vorlage verknuepfen (IDs eintragen, fehlende Namen auffuellen).
-- Erst nach Namen; Ziele ohne Namen nur der Reihe nach und nur, wenn genau so viele Kreaturen uebrig sind wie Ziele.
function Codex.LinkObjectives(q, qid)
    local Seed = Codex.Seed
    if not (q and q.obj and Seed and Seed.Ready and Seed.Ready()) then return false end
    local sq = Seed.Quest(qid)
    if not sq then return false end
    local units = {}
    for _, r in ipairs(sq.obj or {}) do
        if r.kind == "units" then units[#units + 1] = r.id end
    end
    if #units == 0 then return false end
    local mons = {}
    for _, o in ipairs(q.obj) do
        if o.ty == "monster" then mons[#mons + 1] = o end
    end
    if #mons == 0 then return false end
    local changed, used = false, {}
    for _, o in ipairs(mons) do
        if o.name and not Codex.IsBadObjName(o.name) then
            local l = o.name:lower()
            for _, uid in ipairs(units) do
                local nm = Seed.Name("units", uid)
                if nm and nm:lower() == l then
                    used[uid] = true
                    if not (o.ids and o.ids[uid]) then
                        o.ids = o.ids or {}
                        o.ids[uid] = 1
                        changed = true
                    end
                end
            end
        end
    end
    local open, free = {}, {}
    for _, o in ipairs(mons) do
        if (not o.name or Codex.IsBadObjName(o.name)) and not (o.ids and next(o.ids)) then open[#open + 1] = o end
    end
    for _, uid in ipairs(units) do
        if not used[uid] then free[#free + 1] = uid end
    end
    if #open > 0 and #open == #free then
        for i, o in ipairs(open) do
            local nm = Seed.Name("units", free[i])
            if nm then
                o.name = nm
                o.ids = { [free[i]] = 1 }
                changed = true
            end
        end
    end
    return changed
end

-- einmal je Sitzung: alle bekannten Quests nachtragen (sobald die Vorlage geladen ist)
function Codex.RepairObjectives()
    if Codex.objRepaired or not (Codex.db and Codex.db.quests) then return 0 end
    local Seed = Codex.Seed
    if not (Seed and Seed.Ready and Seed.Ready()) then return 0 end
    Codex.objRepaired = true
    local n = 0
    for qid, q in pairs(Codex.db.quests) do
        if type(q) == "table" and q.obj and Codex.LinkObjectives(q, qid) then n = n + 1 end
    end
    return n
end

function Codex:LearnKillTarget(objEntry, o)
    local guid = UnitGUID and UnitGUID("target")
    local kind, id = ParseGUID(guid)
    if kind ~= "npc" then
        return
    end
    local name = Str(UnitName("target"), 60)
    if not name then
        return
    end
    local want = (objEntry.name or o.text or ""):lower()
    local have = name:lower()
    if want == "" or not (want == have or want:find(have, 1, true) or have:find(want, 1, true)) then
        return
    end
    objEntry.ids = objEntry.ids or {}
    if objEntry.ids[id] == nil then
        local n = 0
        for _ in pairs(objEntry.ids) do
            n = n + 1
        end
        if n >= MAX_IDS then
            return
        end
    end
    objEntry.ids[id] = (objEntry.ids[id] or 0) + 1
    local u = self:Unit(id, true)
    u.n = u.n or name
end

------------------------------------------------------------------------
-- Ruf
------------------------------------------------------------------------

local function FormatToPattern(fmt)
    if type(fmt) ~= "string" then
        return nil
    end
    local order = {}
    local marked = fmt:gsub("%%(%d?)%$?([sd])", function(_, kind)
        order[#order + 1] = kind
        return "\1" .. kind .. "\2"
    end)
    marked = marked:gsub("([%^%$%(%)%.%[%]%*%+%-%?%%])", "%%%1")
    marked = marked:gsub("\1s\2", "(.-)"):gsub("\1d\2", "(%%d+)")
    return "^" .. marked .. "$", order
end

local repPatterns = {}
local function BuildRepPatterns()
    repPatterns = {}
    for _, def in ipairs({ { "FACTION_STANDING_INCREASED", 1 }, { "FACTION_STANDING_DECREASED", -1 } }) do
        local fmt = _G[def[1]]
        local pattern, order = FormatToPattern(fmt)
        if pattern then
            local nameIdx, amountIdx
            for i, kind in ipairs(order) do
                if kind == "s" and not nameIdx then nameIdx = i end
                if kind == "d" and not amountIdx then amountIdx = i end
            end
            repPatterns[#repPatterns + 1] = { pattern = pattern, name = nameIdx or 1, amount = amountIdx or 2, sign = def[2] }
        end
    end
end

function Codex:OnFactionMessage(text)
    Safe(function()
        text = Util.Clean(text)
        if type(text) ~= "string" then
            return
        end
        if #repPatterns == 0 then
            BuildRepPatterns()
        end
        for _, p in ipairs(repPatterns) do
            local caps = { text:match(p.pattern) }
            if #caps >= 2 then
                local amount = tonumber(caps[p.amount])
                local name = Str(caps[p.name], 60)
                if amount and name then
                    state.repBuf[#state.repBuf + 1] = { t = GetTime and GetTime() or 0, name = name, amount = amount * p.sign }
                    while #state.repBuf > 20 do
                        table.remove(state.repBuf, 1)
                    end
                end
                return
            end
        end
    end)
end

------------------------------------------------------------------------
-- Quest-Ereignisse
------------------------------------------------------------------------

-- Item aus der Tasche benutzt (Rechtsklick): merken, damit eine Quest ohne NPC dem Item zugeordnet werden kann
function Codex.NoteItemUse(bag, slot)
    Safe(function()
        local id
        local ci = _G.C_Container
        if ci and ci.GetContainerItemID then id = ci.GetContainerItemID(bag, slot)
        elseif _G.GetContainerItemID then id = _G.GetContainerItemID(bag, slot) end
        id = Num(id)
        if id then state.itemUse = { id = id, t = GetTime and GetTime() or 0 } end
    end)
end

function Codex:OnQuestDetail(startItem)
    Safe(function()
        local si = Num(startItem) and Num(startItem) > 0 and Num(startItem) or nil
        local nowT = GetTime and GetTime() or 0
        local giver0 = ReadInteraction()
        local learned
        if not si and giver0.k == "other" and state.itemUse and nowT - state.itemUse.t <= 20 then
            si, learned = state.itemUse.id, true       -- Quest ohne NPC kurz nach Item-Benutzung: das Item startet sie
        end
        Codex.lastStartItem = { id = si, learned = learned, giver = giver0.k, at = nowT, used = state.itemUse and state.itemUse.id }
        state.detail = {
            si = si,
            t = GetTime and GetTime() or 0,
            title = Str(GetTitleText and GetTitleText(), 100),
            qid = Num(GetQuestID and GetQuestID()),
            giver = giver0,
            rew = ReadRewards(),
        }
        Codex.LearnChainOffer(state.detail)
    end)
end

-- Folgequest lernen: Das Spiel bietet die naechste Quest einer Kette gleich nach der Abgabe beim selben NPC an.
-- Erkannt wird sie am Angebot (QUEST_DETAIL) in den ersten Sekunden nach der Abgabe; eine Quest, die man spaeter
-- von Hand beim selben NPC waehlt, zaehlt nicht. Es zaehlt der Zeitpunkt des Angebots, nicht der der Annahme, und
-- die Reihenfolge von Abgabe und Angebot ist egal (das Spiel meldet beides fast gleichzeitig).
Codex.CHAIN_WINDOW = 4
local function LinkChain(q, questID, t, giver)
    local last = state.lastTurnIn
    if not (last and q) or last.qid == questID then return false end
    if math.abs((t or 0) - (last.t or 0)) > Codex.CHAIN_WINDOW then return false end
    -- derselbe NPC (oder dasselbe Objekt)
    local g, tn = giver, last.npc
    if g and tn and g.id and tn.id and (g.id ~= tn.id or g.k ~= tn.k) then return false end
    q.pre = q.pre or {}
    for _, p in ipairs(q.pre) do
        if p == last.qid then return false end
    end
    if #q.pre >= 8 then return false end
    q.pre[#q.pre + 1] = last.qid
    Codex.chainRev = (Codex.chainRev or 0) + 1
    return true
end

function Codex.LearnChain(q, questID, detail)
    if not detail then return false end
    return LinkChain(q, questID, detail.t, detail.giver)
end

-- Wird diese Quest gerade als unmittelbare Folgequest der letzten Abgabe angeboten (selber NPC, wenige Sekunden)? Rueckgabe: Quest-ID der Abgabe
local function FollowUpOf(detail)
    local last = state.lastTurnIn
    if not (detail and detail.qid and last) or last.qid == detail.qid then return nil end
    if math.abs((detail.t or 0) - (last.t or 0)) > Codex.CHAIN_WINDOW then return nil end
    local g, tn = detail.giver, last.npc
    if g and tn and g.id and tn.id and (g.id ~= tn.id or g.k ~= tn.k) then return nil end
    return last.qid
end

-- Schon beim Angebot (ohne Annahme): die Quest wird nach der Abgabe vom selben NPC angeboten
local ChainOfferCore
function Codex.LearnChainOffer(detail)
    local from = FollowUpOf(detail)
    local learned = ChainOfferCore(detail)
    -- der Levelplaner nimmt spontane Folgequests in seinen Guide auf
    if from then FW:Fire("CODEX_FOLLOWUP_OFFER", detail.qid, from, detail) end
    return learned
end

ChainOfferCore = function(detail)
    if not (detail and detail.qid and state.lastTurnIn) then return false end
    local V = Codex.db.quests
    local q = V[detail.qid]
    if not q then
        if not detail.title then return false end
        -- Probelauf, ohne den Datensatz anzulegen, wenn es keine Kette waere
        local last = state.lastTurnIn
        if last.qid == detail.qid or math.abs((detail.t or 0) - (last.t or 0)) > Codex.CHAIN_WINDOW then return false end
        local g, tn = detail.giver, last.npc
        if g and tn and g.id and tn.id and (g.id ~= tn.id or g.k ~= tn.k) then return false end
        q = Codex:Quest(detail.qid, true)
        q.t = detail.title
        q.give = q.give or detail.giver
    end
    if LinkChain(q, detail.qid, detail.t, detail.giver) then
        FW:Fire("CODEX_CHANGED", "quest", detail.qid)
        return true
    end
    return false
end

-- Vorquests einer Quest: aus den Daten (gelernt oder mitgeliefert) und der Classic-Vorlage
-- Quest, die ein Gegenstand startet: Item-ID oder nil
function Codex.QuestStartItem(id)
    local q = Codex.V().quests[id]
    return q and q.si or nil
end

-- Ketten-Index: Folgequests je Quest (aus den Vorquests der Daten und den "Folgequests" der Devs) und
-- Vorquests, die Devs ueber die Folgequest-Liste der Elternquest nachtragen
local nextCache = { view = nil, rev = -1, idx = nil, devPre = nil }
Codex.chainRev = 0
local function ChainCache()
    local V = Codex.V()
    if nextCache.view ~= V or nextCache.rev ~= Codex.chainRev or not nextCache.idx then
        local idx, devPre = {}, {}
        local function Link(parent, child)
            idx[parent] = idx[parent] or {}
            for _, x in ipairs(idx[parent]) do if x == child then return end end
            table.insert(idx[parent], child)
        end
        for qid, q in pairs(V.quests) do
            for _, p in ipairs(q.pre or {}) do
                if p ~= qid then Link(p, qid) end
            end
            for _, n in ipairs(q.ed and q.ed.nx or {}) do
                if n ~= qid then
                    Link(qid, n)
                    devPre[n] = devPre[n] or {}
                    table.insert(devPre[n], qid)
                end
            end
        end
        for _, l in pairs(idx) do table.sort(l) end
        for _, l in pairs(devPre) do table.sort(l) end
        nextCache = { view = V, rev = Codex.chainRev, idx = idx, devPre = devPre }
    end
    return nextCache
end

-- Vorquests einer Quest: Dev-Eintrag ersetzt alles (Daten, Vorlage); sonst Daten, Vorlage und Beobachtungen
function Codex.QuestPre(id)
    local out, have = {}, {}
    local q = Codex.V().quests[id]
    local dev = q and q.ed and q.ed.pre
    if dev then
        for _, p in ipairs(dev) do
            if p ~= id and not have[p] then have[p] = true out[#out + 1] = p end
        end
    else
        for _, p in ipairs(q and q.pre or {}) do
            if p ~= id and not have[p] then have[p] = true out[#out + 1] = p end
        end
        local sq = Codex.Seed and Codex.Seed.Ready() and Codex.Seed.Quest(id) or nil
        for _, p in ipairs(sq and sq.pre or {}) do
            if p ~= id and not have[p] then have[p] = true out[#out + 1] = p end
        end
        -- Aus Beobachtungen abgeleitet (nur wenn nichts Sicheres bekannt ist)
        if #out == 0 and Codex.Avail and q then
            local own = Codex.db.quests[id]
            for _, p in ipairs(Codex.Avail.InferredPre(q, own ~= nil and (own.po or 0) >= 1)) do
                if p ~= id then out[#out + 1] = p end
            end
        end
    end
    -- Elternquests, die diese Quest als Folgequest eingetragen haben
    for _, p in ipairs(ChainCache().devPre[id] or {}) do
        if p ~= id and not have[p] then have[p] = true out[#out + 1] = p end
    end
    return out
end

-- Folgequests: Quests, die diese als Vorquest haben (Daten, Vorlage, Dev-Eintraege)
function Codex.QuestNext(id)
    local V = Codex.V()
    local out, have = {}, {}
    for _, n in ipairs(ChainCache().idx[id] or {}) do have[n] = true out[#out + 1] = n end
    if Codex.Seed and Codex.Seed.Ready() then
        for _, n in ipairs(Codex.Seed.NextQuests(id)) do
            local qn = V.quests[n]
            local devPre = qn and qn.ed and qn.ed.pre
            local overridden = false
            if devPre then
                overridden = true
                for _, p in ipairs(devPre) do if p == id then overridden = false end end
            end
            if not have[n] and n ~= id and not overridden then have[n] = true out[#out + 1] = n end
        end
    end
    table.sort(out)
    return out
end

-- Stellung in einer Kette: "start", "mid", "end" oder nil (keine Kette)
function Codex.ChainRole(id)
    local hasPre, hasNext = #Codex.QuestPre(id) > 0, #Codex.QuestNext(id) > 0
    if hasPre and hasNext then return "mid" end
    if hasNext then return "start" end
    if hasPre then return "end" end
    return nil
end

function Codex:OnQuestAccepted(a, b)
    Safe(function()
        local questID = Num(b) or Num(a)
        if not questID then
            return
        end
        local q = self:Quest(questID, true)
        q.seen = (q.seen or 0) + 1
        q.last = Now()
        q.partial = nil
        local d = state.detail
        local now = GetTime and GetTime() or 0
        if d and now - d.t < 300 and (not d.qid or d.qid == questID) then
            q.t = d.title or q.t
            if d.si then
                q.si = d.si
            else
                q.give = d.giver or q.give
            end
            ApplyRewards(q, d.rew, false)
            if d.giver and d.giver.m then
                q.zone = d.giver.m
            end
        end
        state.detail = nil
        Codex.LearnChain(q, questID, d)

        local title, level = QuestLogInfo(questID)
        q.t = q.t or title
        q.lvl = level or q.lvl
        local pl = Num(UnitLevel and UnitLevel("player"))
        if pl then
            q.pl = q.pl and math.min(q.pl, pl) or pl
        end
        local list = ReadObjectives(questID)
        StoreObjectives(q, list)
        TrackObjectives(questID, list)
        FW:Fire("CODEX_CHANGED", "quest", questID)
    end)
end

function Codex:OnQuestComplete()
    Safe(function()
        state.turn = {
            t = GetTime and GetTime() or 0,
            qid = Num(GetQuestID and GetQuestID()),
            npc = ReadInteraction(),
            rew = ReadRewards(),
        }
    end)
end

-- Merkt sich die gewaehlte Belohnung (Aufruf von GetQuestReward(index))
function Codex:OnChoice(index)
    Safe(function()
        local turn = state.turn
        index = Num(index)
        if turn and index and turn.rew and turn.rew.choice[index] then
            turn.chosen = turn.rew.choice[index].id
        end
    end)
end

function Codex:OnQuestTurnedIn(questID, xp, money)
    Safe(function()
        questID = Num(questID)
        if not questID then
            return
        end
        local q = self:Quest(questID, true)
        q.done = (q.done or 0) + 1
        q.last = Now()
        q.partial = nil
        xp, money = Num(xp), Num(money)
        if xp and xp > 0 then
            q.xp = xp
        end
        if money then
            q.money = money
        end
        local turn = state.turn
        local tnow = GetTime and GetTime() or 0
        if turn and tnow - turn.t < 300 and (not turn.qid or turn.qid == questID) then
            q.turn = turn.npc or q.turn
            ApplyRewards(q, turn.rew, true)
            if xp and xp > 0 then
                q.xp = xp
            end
            if money then
                q.money = money
            end
            if turn.chosen then
                q.chosen = q.chosen or {}
                q.chosen[turn.chosen] = (q.chosen[turn.chosen] or 0) + 1
            end
        end
        state.turn = nil
        state.objState[questID] = nil
        q.t = q.t or QuestLogInfo(questID)
        -- fuer das Lernen von Folgequests: diese Abgabe samt NPC und Zeit merken
        state.lastTurnIn = { qid = questID, t = tnow, npc = q.turn }

        -- Ruf: Meldungen kurz vor und nach der Abgabe einsammeln
        local t0 = tnow
        C_Timer.After(1.5, function()
            Safe(function()
                local rep
                for _, e in ipairs(state.repBuf) do
                    if e.t >= t0 - 1 and e.t <= t0 + 2 then
                        rep = rep or {}
                        rep[e.name] = (rep[e.name] or 0) + e.amount
                    end
                end
                if rep then
                    q.rep = rep
                    FW:Fire("CODEX_CHANGED", "quest", questID)
                end
            end)
        end)
        FW:Fire("CODEX_CHANGED", "quest", questID)
    end)
end

function Codex:OnQuestRemoved(questID)
    questID = Num(questID)
    if questID then
        state.objState[questID] = nil
    end
end

function Codex:OnQuestLogUpdate()
    if self.checkTimer then
        return
    end
    self.checkTimer = true
    C_Timer.After(0.4, function()
        Codex.checkTimer = nil
        Safe(Codex.CheckObjectives, Codex)
    end)
end

-- Bereits angenommene Quests im Log erfassen (ohne Geber)
function Codex:ScanLog()
    Safe(function()
        local count
        if C_QuestLog and C_QuestLog.GetNumQuestLogEntries then
            count = C_QuestLog.GetNumQuestLogEntries()
        elseif GetNumQuestLogEntries then
            count = GetNumQuestLogEntries()
        end
        for i = 1, Num(count) or 0 do
            local title, level, questID, isHeader
            if C_QuestLog and C_QuestLog.GetInfo then
                local info = C_QuestLog.GetInfo(i)
                if type(info) == "table" then
                    title, level, questID, isHeader = info.title, info.level, info.questID, info.isHeader
                end
            elseif GetQuestLogTitle then
                local t, l, _, h, _, _, _, id = GetQuestLogTitle(i)
                title, level, questID, isHeader = t, l, id, h
            end
            questID = Num(questID)
            if questID and questID > 0 and not isHeader then
                local q = self:Quest(questID, false)
                if not q then
                    q = self:Quest(questID, true)
                    q.seen = 0
                    q.partial = true
                    q.t = Str(title, 100)
                    q.lvl = Num(level)
                    local list = ReadObjectives(questID)
                    StoreObjectives(q, list)
                end
                TrackObjectives(questID, ReadObjectives(questID))
            end
        end
    end)
end

------------------------------------------------------------------------
-- Beute
------------------------------------------------------------------------

local function EntityFor(kind, id)
    if kind == "npc" then
        return Codex:Unit(id, true)
    elseif kind == "object" then
        return Codex:Object(id, true)
    end
    return nil
end

local function AddDrop(bucket, itemID, qty, isQuest)
    bucket.d = bucket.d or {}
    local d = bucket.d[itemID]
    if not d then
        local n = 0
        for _ in pairs(bucket.d) do
            n = n + 1
            if n >= MAX_DROPS then
                return
            end
        end
        d = { n = 0, q = 0 }
        bucket.d[itemID] = d
    end
    d.n = d.n + 1
    d.q = d.q + (qty or 1)
    if isQuest then
        d.qi = 1
    end
end

function Codex:OnLootOpened()
    Safe(function()
        if not self.db.settings.enabled or not GetNumLootItems then
            return
        end
        local windows, order = {}, {}
        for slot = 1, GetNumLootItems() do
            local sources = { GetLootSourceInfo(slot) }
            local stype = GetLootSlotType and Num(GetLootSlotType(slot))
            local link = GetLootSlotLink and Util.Clean(GetLootSlotLink(slot))
            local itemID = ItemIDFromLink(link)
            local _, lootName, lootQty, _, _, _, isQuest, questID
            if GetLootSlotInfo then
                _, lootName, lootQty, _, _, _, isQuest, questID = GetLootSlotInfo(slot)
            end
            if itemID then
                NoteName(itemID, lootName)
                if isQuest then
                    local recent = state.recentItems
                    recent[itemID] = { t = Now(), quest = true, qid = Num(questID) }
                    local n = 0
                    for _ in pairs(recent) do n = n + 1 end
                    if n > 30 then
                        local cutoff = Now() - RECENT_SECS
                        for id, r in pairs(recent) do
                            if r.t < cutoff then recent[id] = nil end
                        end
                    end
                end
            end
            for i = 1, #sources, 2 do
                local guid, qty = sources[i], Num(sources[i + 1]) or 1
                if type(guid) == "string" and not Util.IsSecret(guid) then
                    local w = windows[guid]
                    if not w then
                        w = { items = {}, coin = 0, hasCoin = false }
                        windows[guid] = w
                        order[#order + 1] = guid
                    end
                    if itemID then
                        local it = w.items[itemID]
                        if not it then
                            it = { q = 0, quest = (isQuest and true or false), qid = Num(questID) }
                            w.items[itemID] = it
                        end
                        it.q = it.q + qty
                    elseif stype == 2 then
                        w.coin = w.coin + (Num(lootQty) and #sources == 2 and Num(lootQty) or qty)
                        w.hasCoin = true
                    end
                end
            end
        end

        local targetGuid = UnitGUID and Util.Clean(UnitGUID("target"))
        for _, guid in ipairs(order) do
            local kind, id = ParseGUID(guid)
            local ent = kind and EntityFor(kind, id)
            if ent and kind == "object" and not ent.n then
                ent.n = state.objNames[id]
                if not ent.n and UnitGUID and UnitName and Util.Clean(UnitGUID("softinteract")) == guid then
                    ent.n = Str(UnitName("softinteract"), 60)
                end
            end
            if ent then
                local w = windows[guid]
                local again = state.lootedGuids[guid]
                if not again then
                    if state.lootedCount >= MAX_LOOTED_GUIDS then
                        state.lootedGuids, state.lootedItems, state.lootedCount = {}, {}, 0
                    end
                    state.lootedGuids[guid] = true
                    state.lootedCount = state.lootedCount + 1
                end
                -- zweites Beutefenster derselben Leiche: was schon gezaehlt ist (liegengelassen), nicht nochmal
                local seen = state.lootedItems[guid]
                if not seen then
                    seen = {}
                    state.lootedItems[guid] = seen
                end
                local fresh, freshCount = {}, 0
                for itemID, it in pairs(w.items) do
                    if not (again and seen[itemID]) then
                        fresh[itemID] = it
                        freshCount = freshCount + 1
                    end
                end
                local skip = again and freshCount == 0 and not (w.hasCoin and w.coin > 0)
                local bucket = ent
                if again and not skip then
                    ent.alt = ent.alt or { k = 0 }
                    bucket = ent.alt
                end
                if not skip then
                    bucket.k = (bucket.k or 0) + 1
                end
                if w.hasCoin and w.coin > 0 and not again then
                    ent.coin = (ent.coin or 0) + w.coin
                    ent.coinN = (ent.coinN or 0) + 1
                end
                local srcKey = (kind == "npc" and "u" or "o") .. id
                for itemID, it in pairs(fresh) do
                    seen[itemID] = true
                    AddDrop(bucket, itemID, it.q, it.quest)
                    if it.quest and it.qid and it.qid > 0 then
                        local q = self:Quest(it.qid, false)
                        if q then
                            q.qi = q.qi or {}
                            q.qi[itemID] = q.qi[itemID] or {}
                            q.qi[itemID][srcKey] = (q.qi[itemID][srcKey] or 0) + 1
                        end
                    end
                end
                if not again then
                    ent.lt = Now()
                    AddCell(ent)
                    if kind == "npc" and targetGuid == guid then
                        state.noteAt[id] = nil
                        self:NoteUnit("target")
                    end
                    if kind == "npc" and self.Names then
                        if ent.n then
                            self.Names:Consume(ent.n)
                        else
                            self.Names:Resolve(id, ent, guid)
                        end
                    end
                end
                state.stats.loot = state.stats.loot + 1
                FW:Fire("CODEX_CHANGED", kind == "npc" and "unit" or "object", id)
            end
        end
    end)
end


------------------------------------------------------------------------
-- Erfahrung pro Kill
------------------------------------------------------------------------

-- Klassifizierung auf wenige Schluessel vereinfachen
local function ClassKey(class)
    if class == "elite" or class == "rare" or class == "rareelite" or class == "worldboss" then
        return class
    end
    return "normal"
end

function Codex.GrayLevel(pl)
    if pl <= 5 then
        return 0
    elseif pl <= 39 then
        return pl - 5 - math.floor(pl / 10)
    elseif pl <= 59 then
        return pl - 1 - math.floor(pl / 5)
    end
    return pl - 9
end

function Codex.ZeroDiff(pl)
    if pl < 8 then return 5 end
    if pl <= 9 then return 6 end
    if pl <= 11 then return 7 end
    if pl <= 15 then return 8 end
    if pl <= 19 then return 9 end
    if pl <= 29 then return 11 end
    if pl <= 39 then return 12 end
    if pl <= 44 then return 13 end
    if pl <= 49 then return 14 end
    if pl <= 54 then return 15 end
    if pl <= 59 then return 16 end
    return 17
end

-- Farbe des Gegners (red, orange, yellow, green, gray)
function Codex.XPColor(pl, ml)
    if ml >= pl + 5 then return "red" end
    if ml >= pl + 3 then return "orange" end
    if ml >= pl - 2 then return "yellow" end
    if ml > Codex.GrayLevel(pl) then return "green" end
    return "gray"
end

-- Sicht fuer die Anzeige: eigene und empfangene Daten zusammen (ohne Fremddaten einfach die Datenbank)
function Codex.V()
    local share = Codex.Share
    if share then
        return share.View()
    end
    return Codex.db
end

-- Kill-Erfahrung nach der klassischen Formel (Classic 1-60), nur als Ersatz fuer fehlende Messwerte
-- Gegner gleich oder hoeher: Basis aus der Spielerstufe. Gegner niedriger: Basis aus der Gegnerstufe
-- (45 + 5 x Gegnerstufe), so gemessen in Forever (Stufe 3 gegen 2 = 44, Stufe 2 gegen 1 = 40).
function Codex.FormulaXP(pl, ml, class)
    local gain
    if ml >= pl then
        local base = pl * 5 + 45
        local d = math.min(ml - pl, 4)
        gain = math.floor((base * (20 + d) / 10 + 1) / 2)
    elseif ml > Codex.GrayLevel(pl) then
        local zd = Codex.ZeroDiff(pl)
        gain = math.floor((ml * 5 + 45) * (zd + ml - pl) / zd)
    else
        gain = 0
    end
    if class == "elite" or class == "rareelite" then
        gain = gain * 2
    end
    return gain, Codex.XPColor(pl, ml)
end

-- Erfahrung fuer einen Kill: gemessener Wert (eigene und empfangene Messreihen), sonst die Formel.
-- Rueckgabe: XP, Farbe, gemessen (true/false), Anzahl der Messwerte
function Codex.PredictXP(pl, ml, class)
    local gain, color = Codex.FormulaXP(pl, ml, class)
    local share = Codex.Share
    if share and gain > 0 then
        local measured, n = share.XPMeasured(pl, ml, ClassKey(class))
        if measured and measured > 0 then
            return measured, color, true, n
        end
    end
    return gain, color, false, 0
end

local function AddSample(s, xp)
    s.n = (s.n or 0) + 1
    s.sum = (s.sum or 0) + xp
    s.min = s.min and math.min(s.min, xp) or xp
    s.max = s.max and math.max(s.max, xp) or xp
end

local function Bucket(tbl, pl, ml, cls)
    tbl[pl] = tbl[pl] or {}
    tbl[pl][ml] = tbl[pl][ml] or {}
    tbl[pl][ml][cls] = tbl[pl][ml][cls] or {}
    return tbl[pl][ml][cls]
end

-- Alle Messreihen als Liste { pl, ml, cls, n, avg, min, max, pred, diff, bonus }
function Codex:XPRows(includeBonus)
    local rows = {}
    for _, def in ipairs({ { Codex.V().xp, false }, { self.db.xpb, true }, { self.db.xr or {}, true, true } }) do
        if includeBonus or not def[2] then
            for pl, byMob in pairs(def[1]) do
                for ml, byClass in pairs(byMob) do
                    for cls, s in pairs(byClass) do
                        if s.n and s.n > 0 then
                            local pred, color = Codex.FormulaXP(pl, ml, cls)
                            local avg = s.sum / s.n
                            rows[#rows + 1] = {
                                pl = pl, ml = ml, cls = cls, n = s.n, avg = avg, min = s.min, max = s.max,
                                pred = pred, color = color, diff = avg - pred, bonus = def[2], rested = def[3],
                            }
                        end
                    end
                end
            end
        end
    end
    table.sort(rows, function(a, b)
        if a.pl ~= b.pl then return a.pl > b.pl end
        if a.ml ~= b.ml then return a.ml < b.ml end
        return a.cls < b.cls
    end)
    return rows
end

-- Muster aus den Spiel-Texten (COMBATLOG_XPGAIN_FIRSTPERSON...) bauen
local xpPatterns, xpIgnore

local function BuildXPPatterns()
    xpPatterns, xpIgnore = {}, {}
    for key, fmt in pairs(_G) do
        if type(key) == "string" and key:find("^COMBATLOG_XPGAIN_FIRSTPERSON") and type(fmt) == "string" then
            local pattern, order = FormatToPattern(fmt)
            if pattern then
                if key:find("UNNAMED") then
                    xpIgnore[#xpIgnore + 1] = pattern
                else
                    local nameIdx, xpIdx
                    for i, kind in ipairs(order) do
                        if kind == "s" and not nameIdx then nameIdx = i end
                        if kind == "d" and not xpIdx then xpIdx = i end
                    end
                    local bonusKind
                    if #order > 2 then
                        bonusKind = key:find("RAID") and "raid" or key:find("GROUP") and "group" or "bonus"
                    end
                    xpPatterns[#xpPatterns + 1] = {
                        pattern = pattern, name = nameIdx or 1, xp = xpIdx or 2, bonus = bonusKind, len = #fmt,
                    }
                end
            end
        end
    end
    table.sort(xpPatterns, function(a, b) return a.len > b.len end)
end

function Codex:OnXPMessage(text)
    Safe(function()
        if self.Names then
            self.Names.xpSeen = self.Names.xpSeen + 1
            if Util.IsSecret(text) then
                self.Names.fail.xpSecret = self.Names.fail.xpSecret + 1
            end
        end
        text = Util.Clean(text)
        if type(text) ~= "string" or not self.db.settings.enabled then
            return
        end
        if not xpPatterns then
            BuildXPPatterns()
        end
        local matched
        for _, p in ipairs(xpPatterns) do
            local caps = { text:match(p.pattern) }
            if #caps >= 2 then
                matched = { name = Str(caps[p.name], 60), xp = tonumber(caps[p.xp]), bonus = p.bonus }
                break
            end
        end
        if not matched then
            for _, pattern in ipairs(xpIgnore) do
                if text:match(pattern) then
                    return
                end
            end
            local list = self.db.xpUnparsed
            if #list < 5 then
                list[#list + 1] = text:sub(1, 200)
            end
            return
        end
        if not matched.name or not matched.xp or matched.xp <= 0 then
            return
        end
        if matched.name and not matched.bonus then
            local tk0, tid0 = ParseGUID(UnitGUID and UnitGUID("target"))
            FW:Fire("CODEX_KILL", matched.name, tk0 == "npc" and tid0 or nil)
        end

        -- Name der getoeteten Kreatur lernen (Ziel passt) oder fuer das naechste Beutefenster merken
        if self.Names then
            local tk, tid = ParseGUID(UnitGUID and UnitGUID("target"))
            local tn = Str(UnitName and UnitName("target"), 60)
            if tk == "npc" and tn == matched.name then
                self.Names:Learn(tid, tn, "xp")
            else
                self.Names:NoteKill(matched.name)
            end
        end

        -- Gegner: anvisiert und gleicher Name, sonst eindeutiger Name in der Datenbank
        local ml, cls, id
        local tkind, tid = ParseGUID(UnitGUID and UnitGUID("target"))
        if tkind == "npc" and Str(UnitName("target"), 60) == matched.name then
            ml = Num(UnitLevel("target"))
            cls = Str(UnitClassification and UnitClassification("target"), 16)
            id = tid
        else
            for uid, u in pairs(self.db.units) do
                if u.n == matched.name and u.l1 and u.l1 == u.l2 then
                    if id then
                        id = nil
                        break
                    end
                    id, ml, cls = uid, u.l1, u.c
                end
            end
        end
        local pl = state.pl or Num(UnitLevel and UnitLevel("player"))
        -- Kill fuer die Kampfdauer melden, auch wenn die Gegnerstufe hier unbekannt ist
        -- (die Zeitmessung kennt die Stufe des anvisierten Gegners aus dem Kampf)
        if self.Time and not matched.bonus then
            self.Time:OnKill(pl, ml, id, ml and ClassKey(cls) or nil)
        end
        if not (pl and ml and ml > 0 and pl > 0) then
            return
        end
        cls = ClassKey(cls)

        if matched.bonus then
            AddSample(Bucket(self.db.xpb, pl, ml, cls), matched.xp)
            FW:Fire("CODEX_CHANGED", "xp", pl)
            return
        end

        -- Ruhebonus: steht in der Meldung nicht getrennt, also am Ruhe-Vorrat erkennen (er sinkt um den Bonus)
        local base = state.pool
        if base and base > 0 and C_Timer and C_Timer.After then
            local job = { pl = pl, ml = ml, cls = cls, id = id, xp = matched.xp, base = base }
            if state.xpOpen > 0 then
                -- mehrere Kills dicht hintereinander: der Bonus laesst sich nicht zuordnen
                job.unsure = true
                for _, j in ipairs(state.xpJobs) do j.unsure = true end
            end
            state.xpOpen = state.xpOpen + 1
            state.xpJobs[#state.xpJobs + 1] = job
            C_Timer.After(0.4, function()
                Safe(function() Codex:FinishXP(job) end)
            end)
            return
        end
        self:RecordXP(pl, ml, cls, id, matched.xp, nil)
    end)
end

-- Ruhe-Vorrat lesen (0 ohne Ruhebonus, nil wenn die Abfrage fehlt)
local function ReadPool()
    if type(_G.GetXPExhaustion) ~= "function" then
        return nil
    end
    local ok, v = pcall(_G.GetXPExhaustion)
    if not ok then
        return nil
    end
    return tonumber(v) or 0
end

-- normal: Erfahrung ohne Ruhebonus; total: mit Ruhebonus (nil, wenn keiner dabei war)
function Codex:RecordXP(pl, ml, cls, id, normal, total)
    self.db.xr = self.db.xr or {}
    AddSample(Bucket(self.db.xp, pl, ml, cls), normal)
    if total then
        AddSample(Bucket(self.db.xr, pl, ml, cls), total)
    end
    if id then
        local u = self:Unit(id, true)
        u.xp = u.xp or {}
        u.xp[pl] = u.xp[pl] or {}
        AddSample(u.xp[pl], normal)
        -- zusaetzlich nach Gegnerstufe getrennt (Kreaturen mit Stufe 1-2 usw.)
        u.xm = u.xm or {}
        u.xm[pl] = u.xm[pl] or {}
        u.xm[pl][ml] = u.xm[pl][ml] or {}
        AddSample(u.xm[pl][ml], normal)
        if total then
            u.xr = u.xr or {}
            u.xr[pl] = u.xr[pl] or {}
            u.xr[pl][ml] = u.xr[pl][ml] or {}
            AddSample(u.xr[pl][ml], total)
        end
    end
    FW:Fire("CODEX_CHANGED", "xp", pl)
    if id then
        FW:Fire("CODEX_CHANGED", "unit", id)
    end
end

function Codex:FinishXP(job)
    state.xpOpen = math.max(0, state.xpOpen - 1)
    for i, j in ipairs(state.xpJobs) do
        if j == job then table.remove(state.xpJobs, i) break end
    end
    local after = ReadPool()
    if after then
        state.pool = after
    end
    local bonus = after and (job.base - after) or 0
    if bonus <= 0 then
        self:RecordXP(job.pl, job.ml, job.cls, job.id, job.xp, nil)
    elseif job.unsure or bonus >= job.xp then
        self.xpDropped = (self.xpDropped or 0) + 1
    else
        self:RecordXP(job.pl, job.ml, job.cls, job.id, job.xp - bonus, job.xp)
    end
end

-- Ruhe-Vorrat merken: beim Kampfbeginn und ausserhalb des Kampfes (Ausruhen fuellt ihn)
function Codex:OnPoolEvent(event)
    if event == "PLAYER_REGEN_DISABLED" or event == "PLAYER_ENTERING_WORLD"
        or not (UnitAffectingCombat and UnitAffectingCombat("player")) then
        if state.xpOpen == 0 then
            state.pool = ReadPool()
        end
    end
end

function Codex:OnLevelUp(newLevel)
    newLevel = Num(newLevel)
    if newLevel then
        state.pl = newLevel
    end
end

------------------------------------------------------------------------
-- Abfragen fuer Oberflaeche und andere Addons
------------------------------------------------------------------------

-- Quest-Status des eingeloggten Charakters: "active" (im Questlog), "done" (abgegeben) oder nil.
-- Das Spiel kennt beides lokal, es wird nichts gespeichert.
-- Simulation (Guide-Berechnung im Levelplaner): Codex.sim = { done = {}, active = {}, memo = {}, level = n }.
-- Waehrend eine Teilstrecke gerechnet wird, gelten die simulierten Quests als erledigt oder angenommen; alles andere
-- liefert das Spiel (einmal je Quest gemerkt, damit die Rechnung keine Schnittstellenaufrufe wiederholt).
local realQuestStatus
function Codex.QuestStatus(id)
    local sim = Codex.sim
    if sim then
        if sim.done[id] then return "done" end
        if sim.active[id] then return "active" end
        local m = sim.memo[id]
        if m == nil then
            m = realQuestStatus(id) or false
            sim.memo[id] = m
        end
        return m or nil
    end
    return realQuestStatus(id)
end

-- Eigene Quests (Freewood-Creator): IDs ab LOCAL_BASE, Stand liefert das Creator-Modul (nie das Questlog des Spiels)
Codex.LOCAL_BASE = 9000000
function Codex.IsLocalQuest(id)
    return type(id) == "number" and id >= Codex.LOCAL_BASE and id < Codex.LOCAL_BASE + 1000000
end

realQuestStatus = function(id)
    if Codex.LocalStatus and Codex.IsLocalQuest(id) then
        return Codex.LocalStatus(id)
    end
    local QL = _G.C_QuestLog
    if QL and QL.GetLogIndexForQuestID then
        local ok, idx = pcall(QL.GetLogIndexForQuestID, id)
        if ok and type(idx) == "number" and idx > 0 then
            return "active"
        end
    end
    local fn = (QL and QL.IsQuestFlaggedCompleted) or _G.IsQuestFlaggedCompleted
    if type(fn) == "function" then
        local ok, done = pcall(fn, id)
        if ok and done then
            return "done"
        end
    end
    -- Ersatz: Liste aller erledigten Quests
    local list
    if QL and QL.GetAllCompletedQuestIDs then
        local ok, r = pcall(QL.GetAllCompletedQuestIDs)
        if ok and type(r) == "table" then
            for _, v in pairs(r) do if v == id then return "done" end end
        end
    elseif type(_G.GetQuestsCompleted) == "function" then
        local ok, r = pcall(_G.GetQuestsCompleted)
        if ok and type(r) == "table" and r[id] then return "done" end
    end
    return nil
end

function Codex:GetQuest(id)
    return Codex.V().quests[id]
end

-- Display-ID einer Kreatur (fuer das 2D-Bild in der Liste)
Codex.dispStats = { read = 0, fail = 0, shown = 0 }
function Codex:GetDisplayID(npcID)
    local d = self.db.disp and self.db.disp[npcID]
    return type(d) == "number" and d > 0 and d or nil
end

function Codex:SetDisplayID(npcID, displayID)
    if type(npcID) ~= "number" or type(displayID) ~= "number" or displayID <= 0 then
        return false
    end
    self.db.disp = self.db.disp or {}
    if self.db.disp[npcID] ~= displayID then
        self.db.disp[npcID] = displayID
        return true
    end
    return false
end

------------------------------------------------------------------------
-- Itemwerte (Staerke, Beweglichkeit, Ausdauer, Ruestung, Schaden pro Sekunde ...)
------------------------------------------------------------------------

-- Waffen: Schadensspanne und Tempo stehen nur im Tooltip (die Wertetabelle liefert nur den Schaden pro Sekunde).
-- Gespeichert als _dmin, _dmax, _spd und _s (= gelesen) neben den anderen Werten.
local scanTip
local scanTried = {}

local function ScanTooltip()
    if scanTip == nil then
        scanTip = false
        if CreateFrame and UIParent then
            local ok, tip = pcall(CreateFrame, "GameTooltip", "FreewoodCodexScanTip", nil, "GameTooltipTemplate")
            if ok and tip then
                scanTip = tip
            end
        end
    end
    return scanTip or nil
end

local function TemplatePattern(template)
    if type(template) ~= "string" or template == "" then
        return nil
    end
    local p = template:gsub("[%%%^%$%(%)%.%[%]%*%+%-%?]", "%%%0")
    p = p:gsub("%%%%[sd]", "(.-)")
    return "^" .. p .. "$"
end

local function LineText(name, i)
    local fs = _G[name .. i]
    local ok, text = pcall(function() return fs and fs.GetText and fs:GetText() end)
    if ok and type(text) == "string" and not Util.IsSecret(text) then
        return text
    end
    return nil
end

local function CleanLine(text)
    if type(text) ~= "string" or Util.IsSecret(text) then
        return nil
    end
    return (text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""))
end

-- Zeilen des Item-Tooltips { { links, rechts } }: erst die Tooltip-Daten (neue Clients), sonst ein versteckter Tooltip.
-- Zweiter Rueckgabewert: woher sie stammen (fuer /fwcodex weapon)
-- Tooltip noch nicht fertig? (nur "Frage Gegenstandsinformationen ab ..." oder gar keine Zeilen)
local function LinesReady(lines)
    if #lines < 2 then
        return false
    end
    local wait = _G.RETRIEVING_ITEM_INFO
    if type(wait) == "string" and lines[1][1] == wait then
        return false
    end
    return true
end

-- Rueckgabe: Zeilen, Quelle, fertig (false = Itemdaten noch nicht geladen, spaeter nochmal)
local function TooltipLines(itemID)
    local firstLines, firstSource
    if C_TooltipInfo and C_TooltipInfo.GetItemByID then
        local ok, data = pcall(C_TooltipInfo.GetItemByID, itemID)
        if ok and type(data) == "table" and type(data.lines) == "table" then
            local lines = {}
            for _, ln in ipairs(data.lines) do
                if type(ln) == "table" then
                    lines[#lines + 1] = { CleanLine(ln.leftText), CleanLine(ln.rightText) }
                end
            end
            if LinesReady(lines) then
                return lines, "C_TooltipInfo", true
            end
            if #lines > 0 then
                firstLines, firstSource = lines, "C_TooltipInfo"
            end
        end
    end
    local tip = ScanTooltip()
    if not tip then
        return firstLines or {}, firstSource or "kein Tooltip", false
    end
    local ok = pcall(function()
        tip:SetOwner(UIParent, "ANCHOR_NONE")
        tip:ClearLines()
        tip:SetHyperlink("item:" .. itemID)
    end)
    if not ok then
        return firstLines or {}, firstSource or "Tooltip-Fehler", false
    end
    local lines = {}
    for i = 1, (tip.NumLines and tip:NumLines() or 0) do
        lines[#lines + 1] = { CleanLine(LineText("FreewoodCodexScanTipTextLeft", i)), CleanLine(LineText("FreewoodCodexScanTipTextRight", i)) }
    end
    pcall(tip.Hide, tip)
    if not LinesReady(lines) and firstLines then
        return firstLines, firstSource, false
    end
    return lines, "versteckter Tooltip", LinesReady(lines)
end

local function Number(text)
    return tonumber((tostring(text):gsub(",", ".")))
end

-- Schaden und Tempo aus den Zeilen. Fehlt das Tempo im Text, wird es aus Schaden und DPS errechnet.
local function ParseWeapon(lines, dps)
    local patterns = {
        TemplatePattern(_G.DAMAGE_TEMPLATE_WITH_SCHOOL), TemplatePattern(_G.DAMAGE_TEMPLATE),
    }
    local speedWord = type(_G.WEAPON_SPEED) == "string" and _G.WEAPON_SPEED or "Speed"
    speedWord = speedWord:gsub("[%%%^%$%(%)%.%[%]%*%+%-%?]", "%%%0")
    local dmin, dmax, spd
    for _, ln in ipairs(lines) do
        local left, right = ln[1], ln[2]
        if left and not dmin then
            for _, pat in ipairs(patterns) do
                local a, b = left:match(pat)
                a, b = a and Number(a), b and Number(b)
                if a and b then
                    dmin, dmax = a, b
                    break
                end
            end
            if not dmin then
                -- allgemein: Zeile beginnt mit "min - max"
                local a, b = left:match("^(%d+[%.,]?%d*)%s*[%-\226\128\147\226\128\148]+%s*(%d+[%.,]?%d*)%s*%a")
                a, b = a and Number(a), b and Number(b)
                if a and b then
                    dmin, dmax = a, b
                end
            end
        end
        if not spd then
            for _, text in ipairs({ left or "", right or "" }) do
                local v = text:match(speedWord .. "%s+([%d%.,]+)")
                v = v and Number(v)
                if v and v > 0 then
                    spd = v
                    break
                end
            end
        end
    end
    if dmin and dmax and not spd and dps and dps > 0 then
        spd = math.floor(((dmin + dmax) / 2 / dps) * 100 + 0.5) / 100
    end
    if dmin and dmax and spd then
        return dmin, dmax, spd
    end
    return nil
end

local function DPSOf(stats)
    for key, value in pairs(stats) do
        if key:find("DAMAGE_PER_SECOND", 1, true) and type(value) == "number" then
            return value
        end
    end
    return nil
end

-- Rueckgabe: min, max, Tempo (oder nil, wenn der Tooltip noch leer ist oder keine Waffe zeigt)
local function ReadWeapon(itemID, dps)
    local lines, _, ready = TooltipLines(itemID)
    local dmin, dmax, spd = ParseWeapon(lines, dps)
    return dmin, dmax, spd, ready
end

-- Ausgabe fuer /fwcodex weapon <ID>: zeigt, was der Tooltip liefert
function Codex.WeaponDebug(itemID)
    if Util.RequestItem then Util.RequestItem(itemID, function() end) end   -- Itemdaten anfordern
    local lines, source, ready = TooltipLines(itemID)
    FW:Print(string.format("Waffe %d: Quelle %s, %d Zeilen%s", itemID, source, #lines,
        ready and "" or " (Itemdaten noch nicht geladen, in ein paar Sekunden noch einmal eingeben)"))
    for i, ln in ipairs(lines) do
        if i <= 14 then
            FW:Print(string.format("  %d: [%s] [%s]", i, tostring(ln[1]), tostring(ln[2])))
        end
    end
    local st = Codex.db.istats and Codex.db.istats[itemID]
    local dmin, dmax, spd = ParseWeapon(lines, st and DPSOf(st))
    FW:Print(string.format("Ergebnis: Schaden %s - %s, Tempo %s, DPS laut Werten %s", tostring(dmin), tostring(dmax), tostring(spd),
        tostring(st and DPSOf(st))))
end

local function HasDPS(stats)
    for key in pairs(stats) do
        if key:find("DAMAGE_PER_SECOND", 1, true) then
            return true
        end
    end
    return false
end

function Codex.ResetWeaponScan(itemID)
    scanTried[itemID] = nil
end

local function AddWeapon(itemID, out)
    if out._s or (scanTried[itemID] or 0) >= 6 or not HasDPS(out) then
        return
    end
    local dmin, dmax, spd, ready = ReadWeapon(itemID, DPSOf(out))
    if dmin then
        out._dmin, out._dmax, out._spd, out._s = dmin, dmax, spd, 1
        scanTried[itemID] = 6
    elseif ready then
        scanTried[itemID] = 6      -- Tooltip war fertig und enthaelt keine Waffenwerte
    else
        scanTried[itemID] = (scanTried[itemID] or 0) + 1   -- noch nicht geladen: spaeter erneut versuchen
    end
end

-- Gemeinsamer Zaubermacht-Wert ("Schaden und Heilung um bis zu 18") gilt fuer beide:
-- Zauberschaden und Zauberheilung bekommen ihn, damit Anzeige und Filter einheitlich sind.
-- Rueckgabe: true, wenn etwas geaendert wurde.
local SP_DAMAGE, SP_HEALING = "ITEM_MOD_SPELL_DAMAGE_DONE_SHORT", "ITEM_MOD_SPELL_HEALING_DONE_SHORT"
local function SplitSpellPower(t)
    local changed = false
    for _, key in ipairs({ "ITEM_MOD_SPELL_POWER_SHORT", "ITEM_MOD_SPELL_POWER" }) do
        local v = t[key]
        if type(v) == "number" and v ~= 0 then
            t[SP_DAMAGE] = math.max(t[SP_DAMAGE] or 0, v)
            t[SP_HEALING] = math.max(t[SP_HEALING] or 0, v)
        end
        if v ~= nil then
            t[key] = nil
            changed = true
        end
    end
    return changed
end
Codex.SplitSpellPower = SplitSpellPower

local function ReadStats(itemID)
    local link = "item:" .. itemID
    local fn = (C_Item and C_Item.GetItemStats) or GetItemStats
    if type(fn) ~= "function" then
        return nil
    end
    local ok, t = pcall(fn, link)
    if not ok or type(t) ~= "table" then
        return nil
    end
    local out, any = {}, false
    for key, value in pairs(t) do
        if type(key) == "string" and type(value) == "number" and value ~= 0
            and not key:find("^EMPTY_SOCKET") then
            out[key] = value
            any = true
        end
    end
    SplitSpellPower(out)
    if any then
        AddWeapon(itemID, out)
    end
    return out, any
end

local function HasAnyStat(st)
    for k, v in pairs(st) do
        if type(k) == "string" and k:sub(1, 1) ~= "_" and type(v) == "number" and v ~= 0 then return true end
    end
    return false
end

-- Rüstung und Waffen haben immer Werte: eine leere Antwort heisst dort "noch nicht geladen"
local function ShouldHaveStats(itemID)
    local info = Util.GetItem and Util.GetItem(itemID)
    if type(info) ~= "table" then return false end
    local loc = info.equipLoc
    if type(loc) == "string" and loc ~= "" and loc ~= "INVTYPE_BAG" and loc ~= "INVTYPE_TABARD" and loc ~= "INVTYPE_BODY" then return true end
    return info.classID == 2 or info.classID == 4
end

local emptyTries = {}   -- itemID -> Versuche in dieser Sitzung (leer gelesene Ruestung/Waffen werden hoechstens dreimal neu gelesen)

-- Werte eines Items (aus der Datenbank, sonst vom Spiel lesen und merken)
function Codex:GetStats(itemID)
    if type(itemID) ~= "number" then
        return nil
    end
    local store = self.db.istats
    if not store then
        store = {}
        self.db.istats = store
    end
    local st = store[itemID]
    if st and not HasAnyStat(st) and (emptyTries[itemID] or 0) < 3 and ShouldHaveStats(itemID) then
        -- aelterer leerer Eintrag zu Ruestung/Waffe: neu lesen
        emptyTries[itemID] = (emptyTries[itemID] or 0) + 1
        local again, any = ReadStats(itemID)
        if any then
            store[itemID] = again
            st = again
        end
    end
    if st then
        SplitSpellPower(st)   -- aeltere Eintraege mit gemeinsamem Zaubermacht-Wert
        if not st._s and Util.GetItem and Util.GetItem(itemID) then
            AddWeapon(itemID, st)   -- aeltere Eintraege: Schaden und Tempo nachtragen
        end
        return st
    end
    if not (Util.GetItem and Util.GetItem(itemID)) then
        return nil   -- Item noch nicht geladen: spaeter noch einmal versuchen
    end
    local out, any = ReadStats(itemID)
    if out then
        if not any and ShouldHaveStats(itemID) and (emptyTries[itemID] or 0) < 3 then
            -- Ruestung/Waffe ohne Werte gelesen: nicht merken, spaeter noch einmal versuchen
            emptyTries[itemID] = (emptyTries[itemID] or 0) + 1
            return out
        end
        store[itemID] = out   -- auch leer (Item ohne Werte), damit nicht erneut gelesen wird
        return out
    end
    return nil
end

function Codex:CaptureStats(ids)
    local n = 0
    for _, id in ipairs(ids or {}) do
        if self.db.istats == nil or self.db.istats[id] == nil then
            if self:GetStats(id) then n = n + 1 end
        end
    end
    return n
end

-- Anzeigename eines Wertes ("ITEM_MOD_AGILITY_SHORT" -> "Beweglichkeit")
function Codex.StatName(key)
    local g = _G[key]
    if type(g) == "string" and g ~= "" then
        return g
    end
    return (key:gsub("^ITEM_MOD_", ""):gsub("_SHORT$", ""):gsub("_", " "):lower())
end

function Codex.FormatStat(value)
    if math.abs(value - math.floor(value)) < 0.05 then
        return string.format("%d", math.floor(value + 0.5))
    end
    return string.format("%.1f", value)
end

-- Sortierte Liste der Werte-Schluessel, die in der Datenbank vorkommen
function Codex:StatKeys(ids)
    local seen, list = {}, {}
    for _, id in ipairs(ids or {}) do
        local st = self.db.istats and self.db.istats[id]
        if st then
            for key in pairs(st) do
                if not seen[key] and key:sub(1, 1) ~= "_" then
                    seen[key] = true
                    list[#list + 1] = key
                end
            end
        end
    end
    table.sort(list, function(a, b) return Codex.StatName(a) < Codex.StatName(b) end)
    return list
end

function Codex:GetUnit(id)
    return Codex.V().units[id]
end

function Codex:GetObject(id)
    return Codex.V().objects[id]
end

function Codex:ItemName(itemID)
    local c = self.db.cnames and self.db.cnames[itemID]
    local lang = Codex.Lang()
    if c and c[lang] then
        return c[lang]
    end
    local info = Util.GetItem and Util.GetItem(itemID)
    if info and info.name then
        return info.name
    end
    local seen = self.db.names[itemID] or (c and (c.de or c.en))
    if seen then
        return seen
    end
    -- zuletzt die Vorlage (Vanilla-Daten), nur fuer noch nie gesehene Items
    local seed = Codex.Seed and Codex.Seed.Ready() and Codex.Seed.Name("items", itemID)
    if seed then
        return seed
    end
    return Codex.ExtraItemName and Codex.ExtraItemName(itemID) or nil
end

------------------------------------------------------------------------
-- Namen von Hand eintragen (Deutsch / Englisch)
-- Kreaturen, Objekte und Quests: Felder cde / cen am Datensatz (werden geteilt, eigener Eintrag geht vor).
-- Items: db.cnames[itemID] = { de, en } (nur lokal, Itemnamen liefert das Spiel).
------------------------------------------------------------------------

function Codex.Lang()
    return (FW.activeLocale == "deDE") and "de" or "en"
end

local CUSTOM_MAX = 60

local function CleanCustom(v, max)
    if type(v) ~= "string" then
        return nil
    end
    v = v:gsub("[%c|]", ""):gsub("^%s+", ""):gsub("%s+$", "")
    if v == "" then
        return nil
    end
    return v:sub(1, max or CUSTOM_MAX)
end
Codex.CleanCustom = CleanCustom

-- Anzeigename einer Kreatur / eines Objekts: gewaehlte Sprache, sonst vom Spiel gelernt, sonst die andere Sprache
function Codex.NameOf(ent)
    if type(ent) ~= "table" then
        return nil
    end
    local mine, other = ent.cde, ent.cen
    if Codex.Lang() == "en" then
        mine, other = ent.cen, ent.cde
    end
    return mine or ent.n or other
end

function Codex.QuestTitle(q, id)
    -- Vorlage (Vanilla) nur als letzter Ausweg
    local function SeedTitle()
        return Codex.Seed and Codex.Seed.Ready() and Codex.Seed.QuestTitle(id) or nil
    end
    if type(q) ~= "table" then
        return SeedTitle() or ("Quest #" .. tostring(id))
    end
    local mine, other = q.cde, q.cen
    if Codex.Lang() == "en" then
        mine, other = q.cen, q.cde
    end
    return mine or q.t or other or SeedTitle() or ("Quest #" .. tostring(id))
end

local CUSTOM_TABLE = { units = "units", objects = "objects", quests = "quests" }
local CUSTOM_EVENT = { units = "unit", objects = "object", quests = "quest", items = "item", zones = "item" }

-- Eigene Namen (de, en) zu einer Kreatur, einem Objekt, einer Quest oder einem Item
function Codex:GetCustom(kind, id)
    -- vorgemerkte (noch nicht gesendete) Aenderungen eines Bearbeiters zuerst
    local hook = Codex.DevHook
    local staged = hook and hook.Staged and hook.Staged(kind, id)
    if staged then
        return staged.de, staged.en
    end
    if kind == "items" then
        local c = self.db.cnames and self.db.cnames[id]
        return c and c.de, c and c.en
    end
    local t = CUSTOM_TABLE[kind] and self.db[CUSTOM_TABLE[kind]]
    local e = t and t[id]
    return e and e.cde, e and e.cen
end

-- de / en setzen (leer oder nil loescht). Rueckgabe: true, wenn gespeichert
-- Namen aendern darf nur, wer berechtigt ist und das Modul Freewood-Dev hat; die Aenderung wird dort erst
-- vorgemerkt (Vorschau) und mit "Senden" uebernommen (direct = true).
function Codex:SetCustom(kind, id, de, en, direct)
    if type(id) ~= "number" or not CUSTOM_EVENT[kind] then
        return false
    end
    local max = kind == "quests" and 100 or CUSTOM_MAX
    de, en = CleanCustom(de, max), CleanCustom(en, max)
    if not direct then
        local hook = Codex.DevHook
        if not (Codex.Trust and Codex.Trust.CanEdit() and hook and hook.Stage) then
            return false, "denied"
        end
        return hook.Stage(kind, id, de, en)
    end
    if kind == "items" then
        self.db.cnames = self.db.cnames or {}
        if de or en then
            self.db.cnames[id] = { de = de, en = en }
        else
            self.db.cnames[id] = nil
        end
    else
        local t = self.db[CUSTOM_TABLE[kind]]
        local e = t[id]
        if not e then
            if not (de or en) then
                return true
            end
            if kind == "units" then
                e = self:Unit(id, true)
            elseif kind == "objects" then
                e = self:Object(id, true)
            else
                e = self:Quest(id, true)
            end
        end
        e.cde, e.cen = de, en
    end
    FW:Fire("CODEX_CHANGED", CUSTOM_EVENT[kind], id)
    return true
end

-- "fehlerhaft"-Markierung (true / false = aufgehoben / nil = keine Angabe); gleiche Regeln wie bei Namen
function Codex:SetBad(kind, id, value, direct)
    if type(id) ~= "number" or not CUSTOM_TABLE[kind] then
        return false
    end
    if not direct then
        local hook = Codex.DevHook
        local action = value == true and "bad" or "unbad"
        if not (Codex.Trust and Codex.Trust.Can(action) and hook and hook.StageBad) then
            return false, "denied"
        end
        return hook.StageBad(kind, id, value)
    end
    local t = self.db[CUSTOM_TABLE[kind]]
    local e = t[id]
    if not e then
        if value == nil then return true end
        if kind == "units" then e = self:Unit(id, true) elseif kind == "objects" then e = self:Object(id, true) else e = self:Quest(id, true) end
    end
    e.bad = value
    FW:Fire("CODEX_CHANGED", CUSTOM_EVENT[kind], id)
    return true
end

function Codex:IsBad(kind, id)
    local t = CUSTOM_TABLE[kind] and self.db[CUSTOM_TABLE[kind]]
    local e = t and t[id]
    local view = Codex.V()[CUSTOM_TABLE[kind] or ""]
    local v = view and view[id]
    return (v and v.bad == true) or (e and e.bad == true) or false
end

------------------------------------------------------------------------
-- Eigenschaften von Hand (Dev): Zone(n), Dungeon ja/nein, Klasse, Stufen
-- Kreaturen, Objekte, Quests: Feld ed am Datensatz (wird geteilt, eigener Eintrag geht vor).
-- Items: db.ied[itemID] = { ed } (eigener Datensatztyp "i"). Zonen: negative Zahl = Instanz-ID.
--   ed = { z = { mapID, ... }, dg = true/false, cl = "normal"|"elite"|"rare"|"rareelite"|"worldboss", l1, l2 }
------------------------------------------------------------------------

-- Gebiete: die von Hand gesetzte Stufenspanne liegt im Item-Datensatz "i" unter einer hohen ID
-- (50000000 + Karten-ID, Instanzen 50200000 + Instanz-ID), damit Teilen, Vormerken und Protokoll gleich laufen.
Codex.ZONE_BASE = 50000000
function Codex.ZoneEdID(key)
    if type(key) ~= "number" then return nil end
    if key < 0 then return Codex.ZONE_BASE + 200000 + (-key) end
    return Codex.ZONE_BASE + key
end
function Codex.ZoneFromEdID(id)
    if type(id) ~= "number" or id < Codex.ZONE_BASE then return nil end
    local r = id - Codex.ZONE_BASE
    if r >= 200000 then return -(r - 200000) end
    return r
end

local ED_CLASS = { normal = true, elite = true, rare = true, rareelite = true, worldboss = true }
local MAX_ED_ZONES = 6
Codex.ED_CLASSES = { "normal", "elite", "rare", "rareelite", "worldboss" }
Codex.MAX_ED_ZONES = MAX_ED_ZONES

local function EdInt(v, lo, hi)
    v = tonumber(v)
    if v and v == math.floor(v) and v >= lo and v <= hi then return v end
    return nil
end

-- Bereinigt eine Eigenschaften-Tabelle; Rueckgabe nil, wenn nichts uebrig bleibt
function Codex.CleanEd(ed, kind)
    if type(ed) ~= "table" then return nil end
    local out = {}
    if kind == "zones" then
        -- Gebiete: nur die Stufenspanne von Hand
        local l1, l2 = EdInt(ed.l1, 1, 130), EdInt(ed.l2, 1, 130)
        if l1 or l2 then
            l1, l2 = l1 or l2, l2 or l1
            if l1 > l2 then l1, l2 = l2, l1 end
            return { l1 = l1, l2 = l2 }
        end
        return nil
    end
    if type(ed.z) == "table" then
        local z, seen = {}, {}
        for i, m in ipairs(ed.z) do
            if i > 20 then break end
            m = EdInt(m, -100000, 100000)
            if m and m ~= 0 and not seen[m] and #z < MAX_ED_ZONES then
                z[#z + 1] = m
                seen[m] = true
            end
        end
        if #z > 0 then out.z = z end
    end
    if ed.dg == true or ed.dg == false then out.dg = ed.dg end
    if kind == "units" then
        if ED_CLASS[ed.cl] then out.cl = ed.cl end
        local l1, l2 = EdInt(ed.l1, 1, 130), EdInt(ed.l2, 1, 130)
        if l1 or l2 then
            l1, l2 = l1 or l2, l2 or l1
            if l1 > l2 then l1, l2 = l2, l1 end
            out.l1, out.l2 = l1, l2
        end
    end
    if kind == "items" then
        -- Schluessel von Hand: Item, das zum Oeffnen (Truhe) noetig ist, um dieses Item zu bekommen
        local key = EdInt(ed.key, 1, 100000000)
        if key then out.key = key end
    end
    if kind == "quests" then
        -- Vorquests von Hand (jede genuegt), Folgequests, davor/danach (Reihenfolge im Plan), Stufe, Questtext
        local function Ids(list, max)
            if type(list) ~= "table" then return nil end
            local ids, seen = {}, {}
            for i, p in ipairs(list) do
                if i > 20 then break end
                p = EdInt(p, 1, 100000000)
                if p and not seen[p] and #ids < (max or 8) then
                    ids[#ids + 1] = p
                    seen[p] = true
                end
            end
            return #ids > 0 and ids or nil
        end
        out.pre = Ids(ed.pre)
        out.nx = Ids(ed.nx)
        out.bf = Ids(ed.bf)
        out.af = Ids(ed.af)
        local ql = EdInt(ed.ql, 1, 130)
        if ql then out.ql = ql end
        local si = EdInt(ed.si, 1, 100000000)      -- Item, durch das die Quest startet
        if si then out.si = si end
        if type(ed.tx) == "string" then
            local t = ed.tx:gsub("[%c]", " "):gsub("^%s+", ""):gsub("%s+$", "")
            if t ~= "" then out.tx = t:sub(1, 600) end
        end
    end
    if next(out) == nil then return nil end
    return out
end

local function CopyEd(ed)
    if not ed then return nil end
    local out = { dg = ed.dg, cl = ed.cl, l1 = ed.l1, l2 = ed.l2, key = ed.key, ql = ed.ql, tx = ed.tx, si = ed.si }
    if ed.z then
        out.z = {}
        for i, m in ipairs(ed.z) do out.z[i] = m end
    end
    for _, f in ipairs({ "pre", "nx", "bf", "af" }) do
        if ed[f] then
            out[f] = {}
            for i, p in ipairs(ed[f]) do out[f][i] = p end
        end
    end
    return out
end
Codex.CopyEd = CopyEd

-- Gespeicherter Stand (ohne Vormerkung)
function Codex:GetEdStored(kind, id)
    local t = (kind == "items" or kind == "zones") and self.db.ied or (CUSTOM_TABLE[kind] and self.db[CUSTOM_TABLE[kind]])
    local e = t and t[id]
    return e and e.ed or nil
end

-- Eigenschaften zu einer Kreatur, einem Objekt, einer Quest oder einem Item (vorgemerkte Aenderungen zuerst)
function Codex:GetEd(kind, id)
    local hook = Codex.DevHook
    local st = hook and hook.StagedEd and hook.StagedEd(kind, id)
    if st then return CopyEd(st.ed) end
    return CopyEd(self:GetEdStored(kind, id))
end

-- ed = nil loescht. Wie bei Namen: erst vormerken (Freewood-Dev), mit "Senden" uebernehmen (direct = true)
function Codex:SetEd(kind, id, ed, direct)
    if type(id) ~= "number" or not CUSTOM_EVENT[kind] then
        return false
    end
    ed = Codex.CleanEd(ed, kind)
    if not direct then
        local hook = Codex.DevHook
        if not (Codex.Trust and Codex.Trust.CanEdit() and hook and hook.StageEd) then
            return false, "denied"
        end
        return hook.StageEd(kind, id, ed)
    end
    if kind == "items" or kind == "zones" then
        self.db.ied = self.db.ied or {}
        self.db.ied[id] = ed and { ed = CopyEd(ed) } or nil
        if Codex.Share and Codex.Share.NoteEd then Codex.Share.NoteEd(ed ~= nil) end
    else
        local t = self.db[CUSTOM_TABLE[kind]]
        local e = t[id]
        if not e then
            if not ed then return true end
            if kind == "units" then e = self:Unit(id, true) elseif kind == "objects" then e = self:Object(id, true) else e = self:Quest(id, true) end
        end
        e.ed = CopyEd(ed)
        if Codex.Share and Codex.Share.NoteEd then Codex.Share.NoteEd(ed ~= nil) end
    end
    Codex.chainRev = (Codex.chainRev or 0) + 1
    FW:Fire("CODEX_CHANGED", CUSTOM_EVENT[kind], id)
    return true
end

-- Verschlossene Truhen: Item, das ein anderes Item (aus einer Truhe) erst zugaenglich macht { [Item] = Schluessel-Item }.
-- Eingebaut: Vergilbter Umschlag (Truhe auf dem Gebaeude bei Lieutenant Benedict) braucht Benedicts Schluessel.
Codex.KEY_DEFAULT = { [4881] = 4882 }

function Codex.KeyOf(itemID)
    if not itemID then return nil end
    local ed = Codex:GetEd("items", itemID)
    if ed and ed.key then return ed.key end
    return Codex.KEY_DEFAULT[itemID]
end

-- Datensatz mit Eigenschaften: ueberschreibt Klasse (c), Stufen (l1, l2), Dungeon (dg) und Zonen (ez, bei Quests zone).
-- inplace = true: direkt in der (frisch gebauten) Tabelle e, sonst eine Ueberlagerung ueber dem Original.
function Codex.ApplyEd(e, kind, inplace)
    local ed = type(e) == "table" and e.ed
    if not ed then return e end
    local o = inplace and e or {}
    if ed.cl then
        if ed.cl == "normal" then o.c = false else o.c = ed.cl end
    end
    if ed.l1 then o.l1, o.l2 = ed.l1, ed.l2 or ed.l1 end
    if ed.dg ~= nil then o.dg = ed.dg end
    if ed.z then
        o.ez = ed.z
        if kind == "quests" then o.zone = ed.z[1] end
    end
    if ed.pre then o.pre = ed.pre end
    if ed.key then o.key = ed.key end
    if kind == "quests" then
        if ed.ql then o.lvl = ed.ql end
        if ed.si then o.si = ed.si end
        if ed.tx then o.dtx = ed.tx end
    end
    if inplace then return e end
    return setmetatable(o, { __index = e })
end

-- Karten eines Datensatzes: von Hand gesetzte zuerst, sonst die Hauptkarte der Fundorte
function Codex.ZonesOf(e)
    if type(e) ~= "table" then return {} end
    if e.ez and #e.ez > 0 then return e.ez end
    if type(e.iz) == "table" then
        local best, bestN
        for id, n in pairs(e.iz) do
            if not bestN or n > bestN then best, bestN = id, n end
        end
        if best then return { -best } end
    end
    local m = e.cells and Codex.MainMap(e.cells)
    return m and { m } or {}
end

function Codex:SetCustomLang(kind, id, lang, name)
    local de, en = self:GetCustom(kind, id)
    if lang == "de" then
        de = name
    else
        en = name
    end
    return self:SetCustom(kind, id, de, en)
end

-- Text mit Zeilen "ID Name" (auch "ID;Name", "ID=Name", "ID<Tab>Name") einlesen.
-- lang: "de" oder "en". Rueckgabe: gespeichert, uebersprungen
function Codex:ImportNames(kind, lang, text)
    local done, skipped = 0, 0
    if type(text) ~= "string" or not CUSTOM_EVENT[kind] or (lang ~= "de" and lang ~= "en") then
        return 0, 0
    end
    local lines = 0
    for line in (text .. "\n"):gmatch("([^\r\n]*)[\r\n]") do
        local id, name = line:match("^%s*#?(%d+)%s*[=;:,\t ]%s*(.-)%s*$")
        if id or line:find("%S") then
            lines = lines + 1
            if lines > 1000 then
                skipped = skipped + 1
            elseif id and CleanCustom(name) and tonumber(id) <= 100000000 then
                self:SetCustomLang(kind, tonumber(id), lang, name)
                done = done + 1
            else
                skipped = skipped + 1
            end
        end
    end
    return done, skipped
end

-- Drop-Chance: Anteil der gelooteten Leichen, in denen das Item lag. Rueckgabe: chance (0..1), n, k
function Codex.DropChance(ent, itemID, alt)
    local bucket = alt and ent.alt or ent
    if not bucket or not bucket.d or not bucket.d[itemID] or not bucket.k or bucket.k == 0 then
        return nil, 0, bucket and bucket.k or 0
    end
    local n = bucket.d[itemID].n
    return n / bucket.k, n, bucket.k
end

-- Sortierte Beuteliste { { id, chance, n, k, avg, qi } }
function Codex.DropList(ent, alt)
    local bucket = alt and ent.alt or ent
    local list = {}
    if bucket and bucket.d and bucket.k and bucket.k > 0 then
        for id, d in pairs(bucket.d) do
            list[#list + 1] = {
                id = id, chance = d.n / bucket.k, n = d.n, k = bucket.k,
                avg = d.n > 0 and d.q / d.n or 1, qi = d.qi and true or false,
            }
        end
    end
    table.sort(list, function(a, b)
        if a.chance ~= b.chance then
            return a.chance > b.chance
        end
        return a.id < b.id
    end)
    return list
end

-- Durchschnittliches Gold pro Leiche mit Gold (Kupfer)
function Codex.AverageCoin(ent)
    if ent.coin and ent.coinN and ent.coinN > 0 then
        return ent.coin / ent.coinN
    end
    return nil
end

-- Orte: Zellen zu Fundstellen zusammenfassen (je BIN x BIN Zellen eine Stelle).
-- Rueckgabe: { { m, x, y, n } } sortiert nach Treffern, x/y als Anteil 0..1
local SPOT_BIN = 5

function Codex.TopSpots(cells, limit)
    local bins = {}
    for key, n in pairs(cells or {}) do
        local m = math.floor(key / (GRID * GRID))
        local idx = key % (GRID * GRID)
        local cx, cy = idx % GRID, math.floor(idx / GRID)
        local bk = m * 1000000 + math.floor(cy / SPOT_BIN) * 1000 + math.floor(cx / SPOT_BIN)
        local b = bins[bk]
        if not b then
            b = { m = m, sx = 0, sy = 0, n = 0 }
            bins[bk] = b
        end
        b.sx, b.sy, b.n = b.sx + (cx + 0.5) * n, b.sy + (cy + 0.5) * n, b.n + n
    end
    local list = {}
    for _, b in pairs(bins) do
        list[#list + 1] = { m = b.m, x = b.sx / b.n / GRID, y = b.sy / b.n / GRID, n = b.n }
    end
    table.sort(list, function(a, b)
        if a.n ~= b.n then return a.n > b.n end
        if a.m ~= b.m then return a.m < b.m end
        if a.y ~= b.y then return a.y < b.y end
        return a.x < b.x
    end)
    if limit and #list > limit then
        for i = #list, limit + 1, -1 do list[i] = nil end
    end
    return list
end

function Codex.AddCells(dst, cells)
    for key, n in pairs(cells or {}) do
        dst[key] = (dst[key] or 0) + n
    end
    return dst
end

local MAX_POINTS = 4000

local function EntityName(ent, id, kind)
    return (ent and ent.n) or ((kind == "objects" and "#" or "#") .. tostring(id))
end

local function AddEntityPoints(points, ent, id, kind, label)
    if not ent or not ent.cells then
        return
    end
    for key, n in pairs(ent.cells) do
        if #points >= MAX_POINTS then
            return
        end
        local m = math.floor(key / (GRID * GRID))
        local idx = key % (GRID * GRID)
        points[#points + 1] = {
            m = m, x = ((idx % GRID) + 0.5) / GRID, y = (math.floor(idx / GRID) + 0.5) / GRID,
            n = n, name = label or EntityName(ent, id, kind), k = kind == "objects" and "o" or "u",
        }
    end
end

-- Fundstellen der Vorlage (Vanilla) als Punkte
local function AddSeedPoints(points, kind, id, label)
    local Seed = Codex.Seed
    if not (Seed and Seed.Ready()) then
        return
    end
    local cells = Seed.Cells(kind, id)
    if next(cells) then
        AddEntityPoints(points, { cells = cells, n = Seed.Name(kind, id) }, id, kind, label)
    end
end

local function HasCells(ent)
    return ent and ent.cells and next(ent.cells) ~= nil
end

local function AddSourceKey(points, key, label)
    local tk = key:sub(1, 1) == "u" and "units" or "objects"
    local id = tonumber(key:sub(2))
    local ent = id and (tk == "units" and Codex.V().units[id] or Codex.V().objects[id])
    if HasCells(ent) then
        AddEntityPoints(points, ent, id, tk, label)
    elseif id then
        AddSeedPoints(points, tk, id, label)
    end
end

-- Punkte fuer die Weltkarte. spec = { kind = "units"|"objects"|"items"|"quests", id = ... }
-- Punkt: { m, x, y, n, name, pin }  (pin: feste Stelle wie Quest-Geber)
function Codex.CollectPoints(spec)
    local points = {}
    local kind, id = spec.kind, spec.id
    if kind == "units" or kind == "objects" then
        local ent = kind == "units" and Codex.V().units[id] or Codex.V().objects[id]
        if HasCells(ent) then
            AddEntityPoints(points, ent, id, kind)
        else
            AddSeedPoints(points, kind, id)
        end
    elseif kind == "items" then
        for _, pair in ipairs({ { "units", Codex.V().units }, { "objects", Codex.V().objects } }) do
            for eid, ent in pairs(pair[2]) do
                local chance = Codex.DropChance(ent, id, false)
                if chance then
                    AddEntityPoints(points, ent, eid, pair[1],
                        string.format("%s (%d%%)", EntityName(ent, eid, pair[1]), math.floor(chance * 100 + 0.5)))
                end
            end
        end
        -- Vorlage: nur wenn es noch keine eigenen Fundstellen gibt (die besten Quellen)
        local Seed = Codex.Seed
        if #points == 0 and Seed and Seed.Ready() then
            local it = Seed.Item(id)
            for _, def in ipairs({ { "units", it and it.u or {}, 8 }, { "objects", it and it.o or {}, 3 } }) do
                for i, src in ipairs(def[2]) do
                    if i > def[3] then break end
                    AddSeedPoints(points, def[1], src.id,
                        string.format("%s (%d%%)", Seed.Name(def[1], src.id) or ("#" .. src.id), math.floor(src.chance + 0.5)))
                end
            end
        end
    elseif kind == "quests" then
        local q = Codex.V().quests[id]
        if q then
            for _, def in ipairs({ { q.give, L.CODEX_TAG_GIVE, "give" }, { q.turn, L.CODEX_TAG_TURN, "turn" } }) do
                local ref = def[1]
                if ref and ref.m and ref.x and ref.y then
                    points[#points + 1] = { m = ref.m, x = ref.x, y = ref.y, n = 4, pin = true, tag = def[3],
                        name = string.format(def[2], ref.n or "?") }
                end
            end
            for _, o in ipairs(q.obj or {}) do
                if o.ty == "monster" then
                    for uid in pairs(o.ids or {}) do
                        AddEntityPoints(points, Codex.V().units[uid], uid, "units")
                    end
                elseif o.ty == "item" then
                    for _, itemID in ipairs(Codex.ObjectiveItems(q, o)) do
                        local before = #points
                        for key in pairs(q.qi and q.qi[itemID] or {}) do
                            AddSourceKey(points, key)
                        end
                        -- eigene Quests (Creator) kennen keine Quest-Gegenstaende: dann die bekannten Quellen des Gegenstands zeigen
                        if q.loc and #points == before then
                            for _, p in ipairs(Codex.CollectPoints({ kind = "items", id = itemID })) do points[#points + 1] = p end
                        end
                    end
                end
            end
        end
        -- Vorlage: Geber, Abgabe und Ziele, soweit eigene Daten fehlen
        local Seed = Codex.Seed
        local sq = Seed and Seed.Ready() and Seed.Quest(id)
        if sq then
            local function Pin(refs, tag, have, tagName)
                if have then return end
                for _, r in ipairs(refs) do
                    if r.kind ~= "items" then
                        local m, x, y = Seed.FirstSpot(r.kind, r.id)
                        if m then
                            points[#points + 1] = { m = m, x = x, y = y, n = 4, pin = true, tag = tagName,
                                name = string.format(tag, Seed.Name(r.kind, r.id) or ("#" .. r.id)) }
                        end
                    end
                end
            end
            Pin(sq.start, L.CODEX_TAG_GIVE, q and q.give and q.give.m, "give")
            Pin(sq.stop, L.CODEX_TAG_TURN, q and q.turn and q.turn.m, "turn")
            if not (q and q.obj and #q.obj > 0) then
                for _, r in ipairs(sq.obj) do
                    if r.kind ~= "items" then
                        AddSeedPoints(points, r.kind, r.id)
                    end
                end
            end
        end
    end
    return points
end

-- Karte und uebergeordnete Karten (Stadt -> Gebiet -> Kontinent)
function Codex.MapChain(mapID)
    local list, seen = { mapID }, { [mapID] = true }
    local CM = _G.C_Map
    local id = mapID
    for _ = 1, 6 do
        local ok, info = pcall(function() return CM and CM.GetMapInfo and CM.GetMapInfo(id) end)
        local parent = ok and info and info.parentMapID or nil
        if not parent or parent == 0 or seen[parent] then break end
        list[#list + 1] = parent
        seen[parent] = true
        id = parent
    end
    return list
end

-- Position des Spielers auf der Karte mapID (auch auf einer uebergeordneten Karte)
function Codex.PlayerPosOn(mapID, loc)
    if not loc then return nil end
    if loc.mapID == mapID and loc.x and loc.y then return loc.x, loc.y end
    local CM = _G.C_Map
    if CM and CM.GetPlayerMapPosition then
        local ok, pos = pcall(CM.GetPlayerMapPosition, mapID, "player")
        if ok and pos and pos.GetXY then
            local x, y = pos:GetXY()
            if type(x) == "number" and type(y) == "number" and (x ~= 0 or y ~= 0) then return x, y end
        end
    end
    return nil
end

-- Kann der Spieler die Quest jetzt annehmen? Nicht angenommen, nicht abgeschlossen, Mindeststufe erreicht,
-- Volk und Klasse passen, und (laut Vorlage) wurde eine Vorquest abgeschlossen.
local function HasBit(mask, index)
    return math.floor(mask / 2 ^ (index - 1)) % 2 == 1
end
-- assume: Menge von Quest-IDs, die als abgegeben gelten (Plan: Folgequest nach der Abgabe)
function Codex.QuestAvailable(id, assume)
    if Codex.QuestStatus(id) ~= nil then return false end
    local sq = Codex.Seed and Codex.Seed.Ready() and Codex.Seed.Quest(id) or nil
    local live = Codex.V().quests[id]
    if not sq and not live then return true end
    -- Voraussetzungen: Vorlage, sonst die Angaben in den eigenen Daten
    local min = (sq and sq.min) or (live and live.mn)
    if (not min or min == 0) and live and Codex.Avail then
        local own = Codex.db.quests[id]
        min = Codex.Avail.InferredMin(live, own ~= nil and own.mi ~= nil) or min
    end
    local race = (sq and sq.race) or (live and live.rc)
    local class = (sq and sq.class) or (live and live.cl)
    local pl = Codex.sim and Codex.sim.level or (UnitLevel and UnitLevel("player")) or nil
    if min and min > 0 and pl and pl < min then return false end
    if race and race > 0 and UnitRace then
        local raceID = select(3, UnitRace("player"))
        if type(raceID) == "number" and raceID > 0 and not HasBit(race, raceID) then return false end
    end
    if class and class > 0 and UnitClass then
        local classID = select(3, UnitClass("player"))
        if type(classID) == "number" and classID > 0 and not HasBit(class, classID) then return false end
    end
    local pre = Codex.QuestPre(id)
    if #pre > 0 then
        local any = false
        for _, p in ipairs(pre) do
            if Codex.QuestStatus(p) == "done" or (assume and assume[p]) then any = true break end
        end
        if not any then return false end
    end
    return true
end

-- Quest-Route: eine Station (der Questgeber) je annehmbarer Quest.
-- Schritt 1 (aufwendig, einmal je Route): Kandidaten mit Position sammeln
-- opts (optional): { below = n, above = m } = nur Quests von Spielerstufe - n bis Spielerstufe + m
local function QuestLevel(id)
    local q = Codex.V().quests[id]
    local lv = q and tonumber(q.lvl)
    if not lv or lv <= 0 then
        local sq = Codex.Seed and Codex.Seed.Ready() and Codex.Seed.Quest(id) or nil
        lv = sq and tonumber(sq.lvl)
    end
    return lv and lv > 0 and lv or nil
end

function Codex.QuestRouteCandidates(ids, opts)
    local cands = {}
    local pl = UnitLevel and UnitLevel("player") or nil
    local lo, hi
    if opts and pl then
        if opts.below then lo = pl - opts.below end
        if opts.above then hi = pl + opts.above end
    end
    for _, id in ipairs(ids) do
        local inRange = true
        if lo or hi then
            local lv = QuestLevel(id)
            inRange = lv ~= nil and (not lo or lv >= lo) and (not hi or lv <= hi)
        end
        if inRange and Codex.QuestAvailable(id) then
            local pick, any
            for _, p in ipairs(Codex.CollectPoints({ kind = "quests", id = id })) do
                if p.pin then
                    any = any or p
                    if p.tag == "give" and not pick then pick = p end
                end
            end
            pick = pick or any
            if pick then
                local q = Codex.V().quests[id]
                cands[#cands + 1] = { id = id, m = pick.m, x = pick.x, y = pick.y, title = Codex.QuestTitle(q, id) }
            end
        end
    end
    return cands
end

-- Schritt 2 (billig, bei jeder Bewegung): Karte waehlen und nach naechstem Nachbarn ordnen.
-- Rueckgabe: Punkte (mit Nummer im Namen), Karten-ID, Weg (Spielerposition + Stationen)
local MAX_ROUTE = 40
function Codex.QuestRouteOrder(cands, loc)
    if #cands == 0 then return {}, nil, {} end
    -- Karte: die des Spielers, sonst (Stadt, Hoehle ...) die naechste uebergeordnete Karte mit Stationen.
    -- Ohne Spielerposition die Karte mit den meisten Stationen. Nie ein fernes Gebiet.
    local perMap, bestMap, bestN = {}, nil, 0
    for _, c in ipairs(cands) do
        perMap[c.m] = (perMap[c.m] or 0) + 1
        if perMap[c.m] > bestN or (perMap[c.m] == bestN and c.m < bestMap) then bestMap, bestN = c.m, perMap[c.m] end
    end
    local mapID
    if loc and loc.mapID then
        for _, m in ipairs(Codex.MapChain(loc.mapID)) do
            if perMap[m] then mapID = m break end
        end
        if not mapID then return {}, nil, {} end
    else
        mapID = bestMap
    end
    local pool = {}
    for _, c in ipairs(cands) do
        if c.m == mapID then pool[#pool + 1] = c end
    end
    table.sort(pool, function(a, b) return a.id < b.id end)
    local cx, cy = Codex.PlayerPosOn(mapID, loc)
    local path = {}
    if cx then path[1] = { m = mapID, x = cx, y = cy } end
    if not cx then cx, cy = pool[1].x, pool[1].y end
    local points = {}
    while #pool > 0 and #points < MAX_ROUTE do
        local bi, bd
        for i, c in ipairs(pool) do
            local d = (c.x - cx) ^ 2 + (c.y - cy) ^ 2
            if not bd or d < bd then bi, bd = i, d end
        end
        local c = table.remove(pool, bi)
        points[#points + 1] = { m = c.m, x = c.x, y = c.y, n = 4, pin = true, id = c.id,
            name = string.format("%d. %s", #points + 1, c.title) }
        cx, cy = c.x, c.y
        path[#path + 1] = { m = c.m, x = c.x, y = c.y }
    end
    return points, mapID, path
end

function Codex.QuestRoute(ids, loc)
    return Codex.QuestRouteOrder(Codex.QuestRouteCandidates(ids), loc)
end

-- Itemdaten (Qualitaet, Typ, Preis) nachladen; feuert CODEX_ITEMS_LOADED, wenn etwas angekommen ist.
-- Rueckgabe: Zahl neu angeforderter Items
function Codex:LoadItemInfo(ids)
    local started = 0
    for _, id in ipairs(ids) do
        if not state.requested[id] and not Util.GetItem(id) then
            state.requested[id] = true
            state.pendingInfo = state.pendingInfo + 1
            started = started + 1
            Util.RequestItem(id, function()
                state.pendingInfo = math.max(0, state.pendingInfo - 1)
                if not state.infoTimer then
                    state.infoTimer = true
                    C_Timer.After(0.5, function()
                        state.infoTimer = nil
                        FW:Fire("CODEX_ITEMS_LOADED")
                    end)
                end
            end)
        end
    end
    return started
end

-- Durchschnittlicher Wert einer gelooteten Leiche in Kupfer: tatsaechliches Gold plus Haendlerwert
-- der Items nach Drop-Chance und Durchschnittsmenge. Rueckgabe: gesamt, gold, items, Items ohne Preisdaten
function Codex.KillValue(ent, useAH)
    local k = ent.k or 0
    if k <= 0 then
        return nil
    end
    local coin = (ent.coin or 0) / k
    local items, missing = 0, 0
    for id, d in pairs(ent.d or {}) do
        local info = Util.GetItem(id)
        if info then
            local v = info.sellPrice or 0
            if useAH then
                local ah = Codex.AuctionPrice(id)
                if ah and ah > v then v = ah end
            end
            items = items + (d.q / k) * v
        else
            local ah = useAH and Codex.AuctionPrice(id)
            if ah then
                items = items + (d.q / k) * ah
            else
                missing = missing + 1
            end
        end
    end
    return coin + items, coin, items, missing
end

-- Auktionshauspreis in Kupfer. Ein spaeteres Auktionsmodul setzt Codex.AuctionProvider = function(itemID) return kupfer end;
-- ohne Anbieter bleibt der Wert leer (und die Sortierung "Auktionspreis" wird nicht angeboten).
function Codex.AuctionPrice(itemID)
    local fn = Codex.AuctionProvider
    if type(fn) ~= "function" then
        return nil
    end
    local ok, v = pcall(fn, itemID)
    if ok and type(v) == "number" and v == v and v >= 0 then
        return v
    end
    return nil
end

function Codex:Counts()
    local q, u, o, n = 0, 0, 0, 0
    for _ in pairs(Codex.V().quests) do q = q + 1 end
    for _ in pairs(Codex.V().units) do u = u + 1 end
    for _ in pairs(Codex.V().objects) do o = o + 1 end
    for _ in pairs(self.db.names) do n = n + 1 end
    return q, u, o, n
end

------------------------------------------------------------------------
-- Start
------------------------------------------------------------------------

function Codex:OnEnable()
    -- Teilen ist von Anfang an an: einmalig auch bei vorhandenen Daten einschalten (danach gilt, was der Spieler waehlt)
    if self.db and self.db.settings and not self.db.settings.shareDefaultOn then
        self.db.settings.shareDefaultOn = true
        self.db.settings.share = true
    end
    FW:RegisterEvent("QUEST_DETAIL", self.OnQuestDetail, self)
    FW:RegisterEvent("QUEST_ACCEPTED", self.OnQuestAccepted, self)
    FW:RegisterEvent("QUEST_COMPLETE", self.OnQuestComplete, self)
    FW:RegisterEvent("QUEST_TURNED_IN", self.OnQuestTurnedIn, self)
    FW:RegisterEvent("QUEST_REMOVED", self.OnQuestRemoved, self)
    FW:RegisterEvent("QUEST_LOG_UPDATE", self.OnQuestLogUpdate, self)
    FW:RegisterEvent("UNIT_QUEST_LOG_CHANGED", self.OnQuestLogUpdate, self)
    FW:RegisterEvent("LOOT_OPENED", self.OnLootOpened, self)
    FW:RegisterEvent("CHAT_MSG_COMBAT_FACTION_CHANGE", self.OnFactionMessage, self)
    FW:RegisterEvent("CHAT_MSG_COMBAT_XP_GAIN", self.OnXPMessage, self)
    FW:RegisterEvent("PLAYER_LEVEL_UP", self.OnLevelUp, self)
    for _, event in ipairs({ "PLAYER_REGEN_DISABLED", "PLAYER_ENTERING_WORLD", "UPDATE_EXHAUSTION" }) do
        FW:RegisterEvent(event, function() Codex:OnPoolEvent(event) end, self)
    end
    C_Timer.After(2, function() Codex:OnPoolEvent("PLAYER_ENTERING_WORLD") end)
    state.pl = Num(UnitLevel and UnitLevel("player"))
    FW:RegisterEvent("PLAYER_TARGET_CHANGED", self.OnTargetChanged, self)
    FW:RegisterEvent("UPDATE_MOUSEOVER_UNIT", self.OnMouseover, self)

    if not self.hooked and hooksecurefunc and type(_G.GetQuestReward) == "function" then
        hooksecurefunc("GetQuestReward", function(index)
            Codex:OnChoice(index)
        end)
        self.hooked = true
    end
    if not self.useHooked and hooksecurefunc then
        local ci = _G.C_Container
        if ci and type(ci.UseContainerItem) == "function" then
            hooksecurefunc(ci, "UseContainerItem", function(bag, slot) Codex.NoteItemUse(bag, slot) end)
            self.useHooked = true
        elseif type(_G.UseContainerItem) == "function" then
            hooksecurefunc("UseContainerItem", function(bag, slot) Codex.NoteItemUse(bag, slot) end)
            self.useHooked = true
        end
    end
    if not self.tipHooked and TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall
        and Enum and Enum.TooltipDataType and Enum.TooltipDataType.Object then
        local ok = pcall(TooltipDataProcessor.AddTooltipPostCall, Enum.TooltipDataType.Object, function(_, data)
            Codex:OnObjectTooltip(data)
        end)
        self.tipHooked = ok
    end
    C_Timer.After(3, function()
        Codex:ScanLog()
    end)
    C_Timer.After(4, function()
        if Codex.Forever then Codex.Forever.Load() end
    end)
    if self.Avail then
        self.Avail:Start()
    end
    if self.Names then
        self.Names:Start()
    end
    if self.Time then
        self.Time:Start()
    end
    if self.Roles then
        self.Roles:Start()
    end
    if self.Recipes then
        self.Recipes:Start()
    end
    if self.Flight then
        self.Flight:Start()
    end
    if self.Sync then
        self.Sync:Init()
    end
end

function Codex:OnDisable()
    for _, event in ipairs({ "QUEST_DETAIL", "QUEST_ACCEPTED", "QUEST_COMPLETE", "QUEST_TURNED_IN", "QUEST_REMOVED",
        "QUEST_LOG_UPDATE", "UNIT_QUEST_LOG_CHANGED", "LOOT_OPENED", "CHAT_MSG_COMBAT_FACTION_CHANGE", "CHAT_MSG_COMBAT_XP_GAIN", "PLAYER_LEVEL_UP",
        "PLAYER_TARGET_CHANGED", "UPDATE_MOUSEOVER_UNIT",
        "PLAYER_REGEN_DISABLED", "PLAYER_ENTERING_WORLD", "UPDATE_EXHAUSTION" }) do
        FW:UnregisterEvent(event, self)
    end
    if self.Names then
        self.Names:Stop()
    end
    if self.Time then
        self.Time:Stop()
    end
    if self.Roles then
        self.Roles:Stop()
    end
    if self.Recipes then
        self.Recipes:Stop()
    end
    if self.Flight then
        self.Flight:Stop()
    end
    if self.Sync then
        self.Sync:Stop()
    end
end

-- Test im Spiel: /fwcodex test
function Codex:RunTest()
    local Lc = FW.L
    local function yn(v)
        return v and Lc.CODEX_YES or Lc.CODEX_NO
    end
    FW:Print(string.format(Lc.CODEX_TEST_API,
        yn(GetLootSourceInfo), yn(C_QuestLog and C_QuestLog.GetQuestObjectives), yn(GetQuestReward), yn(self.hooked)))
    local q, u, o, n = self:Counts()
    FW:Print(string.format(Lc.CODEX_TEST_COUNTS, q, u, o, n))
    FW:Print(string.format(Lc.CODEX_TEST_STATS, state.stats.loot, state.stats.errors))
    local rows = self:XPRows(true)
    FW:Print(string.format(Lc.CODEX_TEST_XP, #rows, #self.db.xpUnparsed))
    for _, text in ipairs(self.db.xpUnparsed) do
        FW:Print("  ? " .. text)
    end
    if self.Share then
        local own = self.Share.Summary()
        local senders, records = self.Share.RemoteStats()
        FW:Print(string.format(Lc.CODEX_TEST_SHARE, self.db.settings.share and Lc.CODEX_ON or Lc.CODEX_OFF, own or 0, senders, records))
    end
    local empty = self.db.objEmpty or {}
    FW:Print(string.format(Lc.CODEX_TEST_OBJ, #empty))
    for _, text in ipairs(empty) do
        FW:Print("  ? " .. text)
    end
end
