-- Freewood-Codex: Rollen (Haendler, Lehrer, Flugmeister ...)
-- Lernt beim Ansprechen von NPCs und Objekten:
--   units[id].ro[rolle]   = Anzahl Beobachtungen (vendor, repair, flight, innkeeper, stablemaster, spirithealer,
--                           auctioneer, battlemaster, banker, classtrainer, proftrainer); objects[id].ro: mailbox
--   units[id].ti          = Titelzeile ("Waffenschmied")
--   units[id].wa[itemID]  = { pr = { [preis] = Anzahl }, st = Stapel, lim = 1 (begrenzt), ec = 1 (Tauschkosten) }
--                           alle beobachteten Preise (Ruf und Talente senken Preise); Prozent = Preis / hoechster Preis
--   units[id].tr[schluessel] = { nm, rk, lv = Stufe, sn = Fertigkeit, sr = Fertigkeitswert, pr = { [kosten] = Anzahl } }
--   units[id].fl[ziel]    = { [preis] = Anzahl }     Flugziele, units[id].fn = eigener Flugpunkt
-- Der Ort (Spielerposition beim Ansprechen) landet wie bei allen Datensaetzen in cells.
-- Alles laeuft geschuetzt; unbekannte Ereignisse werden vom Spiel einfach nicht angeboten.

local ADDON, NS = ...

local FW = _G.Freewood
local Codex = NS and NS.Codex
if not FW or not Codex then
    return
end

local Util = FW.Util

local Roles = {}
NS.Roles = Roles
Codex.Roles = Roles

local MAX_WARES = 250
local MAX_PRICES = 6
local MAX_TRAIN = 160
local MAX_DEST = 60
local MAX_COUNT = 1000
local DEBOUNCE = 5

Roles.events = {}      -- Diagnose: wie oft kam welches Ereignis
Roles.gossip = {}      -- Diagnose: gesehene Gespraechs-Arten
Roles.last = nil       -- zuletzt erfasste Rolle (Diagnose)
Roles.trainerSources = {}  -- Diagnose: woher die Zauber-IDs der Lehrer kamen

local debounce = {}
local visit = {}       -- pro Besuch: bereits gezaehlte Preise

local function Now()
    return (GetTime and GetTime()) or 0
end

local function Str(v, max)
    return Codex.Str(v, max)
end

local function Num(v)
    if Util.IsSecret(v) or type(v) ~= "number" or v ~= v then
        return nil
    end
    return v
end

local function ItemIDFromLink(link)
    link = Util.Clean(link)
    if type(link) ~= "string" then
        return nil
    end
    return tonumber(link:match("item:(%d+)"))
end

------------------------------------------------------------------------
-- Wer wird gerade angesprochen
------------------------------------------------------------------------

-- Rueckgabe: Art ("npc"/"object"), ID, Name, Einheit
local function Resolve(allowObject, objectOnly)
    for _, unit in ipairs(objectOnly and {} or { "npc", "target" }) do
        local guid = UnitGUID and UnitGUID(unit)
        local kind, id = Codex.ParseGUID(guid)
        if kind then
            local name = UnitName and Str((UnitName(unit)), 60) or nil
            return kind, id, name, unit
        end
    end
    local o = Codex.lastObject
    if allowObject and o and Now() - (o.t or 0) < 10 then
        return "object", o.id, o.name, nil
    end
    return nil
end

local function Entity(kind, id)
    if kind == "npc" then
        return Codex:Unit(id, true)
    end
    return Codex:Object(id, true)
end

-- Titelzeile ("Waffenschmied") aus der zweiten Tooltip-Zeile; Stufen- und Fraktionszeilen zaehlen nicht
local function TitleFrom(text)
    text = Str(text, 60)
    if not text then
        return nil
    end
    text = text:gsub("^<", ""):gsub(">$", "")
    text = text:gsub("^%s+", ""):gsub("%s+$", "")
    if text == "" or text:find("%d") or text:find("%?%?") or #text > 40 then
        return nil
    end
    local level = _G.LEVEL
    if type(level) == "string" and text:sub(1, #level) == level then
        return nil
    end
    return text
end

local function ReadTitle(unit)
    if not unit or not (C_TooltipInfo and C_TooltipInfo.GetUnit) then
        return nil
    end
    local ok, data = pcall(C_TooltipInfo.GetUnit, unit)
    if not ok or type(data) ~= "table" or Util.IsSecret(data) then
        return nil
    end
    if TooltipUtil and TooltipUtil.SurfaceArgs then
        pcall(TooltipUtil.SurfaceArgs, data)
    end
    local line = type(data.lines) == "table" and data.lines[2] or nil
    if type(line) ~= "table" then
        return nil
    end
    return TitleFrom(line.leftText)
end

------------------------------------------------------------------------
-- Rolle vermerken
------------------------------------------------------------------------

-- Gibt die Einheit/das Objekt zurueck (oder nil), vermerkt Rolle, Namen, Titel und Ort (hoechstens alle 5 s je Rolle)
function Roles:Mark(role, allowObject)
    local kind, id, name, unit = Resolve(allowObject, role == "mailbox")
    if not kind then
        return nil
    end
    if kind == "object" and role ~= "mailbox" then
        return nil
    end
    if kind == "npc" and role == "mailbox" then
        return nil
    end
    local ent = Entity(kind, id)
    if name then
        ent.n = name
    end
    if kind == "npc" then
        local title = ReadTitle(unit)
        if title then
            ent.ti = title
        end
    end
    local key = kind .. id .. role
    local t = Now()
    if not debounce[key] or t - debounce[key] > DEBOUNCE then
        debounce[key] = t
        ent.ro = ent.ro or {}
        ent.ro[role] = math.min((ent.ro[role] or 0) + 1, MAX_COUNT)
        Codex.AddCell(ent)
        Roles.last = { role = role, kind = kind, id = id }
    end
    FW:Fire("CODEX_CHANGED", kind == "npc" and "unit" or "object", id)
    return ent, kind, id
end

------------------------------------------------------------------------
-- Haendler
------------------------------------------------------------------------

local function AddPrice(prices, price)
    if prices[price] then
        prices[price] = math.min(prices[price] + 1, MAX_COUNT)
        return
    end
    local n = 0
    for _ in pairs(prices) do
        n = n + 1
    end
    if n < MAX_PRICES then
        prices[price] = 1
    end
end

local function MerchantInfo(i)
    local name, price, stack, avail, ec
    if C_MerchantFrame and C_MerchantFrame.GetItemInfo then
        local ok, info = pcall(C_MerchantFrame.GetItemInfo, i)
        if ok and type(info) == "table" and not Util.IsSecret(info) then
            name, price, stack, avail = info.name, info.price, info.stackCount, info.numAvailable
            ec = info.hasExtendedCost
        end
    end
    if name == nil and GetMerchantItemInfo then
        local n, _, p, q, a = GetMerchantItemInfo(i)
        name, price, stack, avail = n, p, q, a
    end
    if ec == nil and GetMerchantItemCostInfo then
        local ok, count = pcall(GetMerchantItemCostInfo, i)
        ec = ok and type(count) == "number" and count > 0
    end
    return Str(name, 80), Num(price), Num(stack), Num(avail), ec == true
end

local function MerchantItemID(i)
    local link
    if GetMerchantItemLink then
        link = GetMerchantItemLink(i)
    end
    local id = ItemIDFromLink(link)
    if id then
        return id
    end
    if C_MerchantFrame and C_MerchantFrame.GetItemInfo then
        local ok, info = pcall(C_MerchantFrame.GetItemInfo, i)
        if ok and type(info) == "table" then
            return Num(info.itemID) or ItemIDFromLink(info.link)
        end
    end
    return nil
end

-- Ruf-Anforderung einer Ware aus dem Tooltip des Haendlerfensters ("Benoetigt Fraktion - Stufe").
-- Rueckgabe: Tabelle { f, s, ok } | false (kein Ruf noetig) | nil (Tooltip nicht lesbar)
local function ReqPattern()
    local fmt = _G.ITEM_REQ_REPUTATION
    if type(fmt) ~= "string" or not fmt:find("%%s") then return nil end
    local esc = fmt:gsub("[%^%$%(%)%.%[%]%*%+%-%?]", "%%%0"):gsub("%%s", "(.+)")
    return "^" .. esc .. "$"
end

local function StandingIndex(text)
    local low = tostring(text or ""):lower()
    for i = 1, 8 do
        for _, key in ipairs({ "FACTION_STANDING_LABEL" .. i, "FACTION_STANDING_LABEL" .. i .. "_FEMALE" }) do
            local label = _G[key]
            if type(label) == "string" and label:lower() == low then return i end
        end
    end
    return nil
end

local function IsRed(c)
    return type(c) == "table" and (c.r or c[1] or 0) > 0.8 and (c.g or c[2] or 1) < 0.3 and (c.b or c[3] or 1) < 0.3
end

function Codex.ReputationRequirement(data)
    if type(data) ~= "table" or type(data.lines) ~= "table" then return nil end
    local pat = ReqPattern() or "^Requires (.+) %- (.+)$"
    for _, line in ipairs(data.lines) do
        local text = type(line) == "table" and Str(line.leftText, 120)
        if text then
            local fac, stand = text:match(pat)
            if not fac then fac, stand = text:match("^Ben\195\182tigt (.+) %- (.+)$") end
            if not fac then
                -- Ersatz: "<Fraktion> - <Ruf-Stufe>" mit einer bekannten Ruf-Stufe am Ende
                local f2, s2 = text:match("^(.-)%s+[%-\226\128\147]+%s+(.+)$")
                if f2 and s2 and StandingIndex(s2) then fac, stand = f2, s2 end
            end
            if fac and stand then
                local idx = StandingIndex(stand)
                if idx then
                    return { f = fac:sub(1, 40), s = idx, ok = not IsRed(line.leftColor) }
                end
            end
        end
    end
    return false
end

local function MerchantTooltip(i)
    if not (C_TooltipInfo and C_TooltipInfo.GetMerchantItem) then return nil end
    local ok, data = pcall(C_TooltipInfo.GetMerchantItem, i)
    if not ok or type(data) ~= "table" or Util.IsSecret(data) then return nil end
    if TooltipUtil and TooltipUtil.SurfaceArgs then pcall(TooltipUtil.SurfaceArgs, data) end
    return data
end

-- /fwruf: zeigt fuer die ersten Waren des offenen Haendlers die Tooltip-Zeilen und was daraus gelesen wurde
function Roles.RepDiag()
    if not (GetMerchantNumItems and (GetMerchantNumItems() or 0) > 0) then
        FW:Print("Ruf: Bitte zuerst ein Haendlerfenster oeffnen.")
        return
    end
    if not (C_TooltipInfo and C_TooltipInfo.GetMerchantItem) then
        FW:Print("Ruf: C_TooltipInfo.GetMerchantItem gibt es hier nicht - Ruf-Zeilen koennen nicht gelesen werden.")
        return
    end
    FW:Print("Ruf: Muster = " .. tostring(_G.ITEM_REQ_REPUTATION) .. " | Stufen: " .. tostring(_G.FACTION_STANDING_LABEL5) .. ", " .. tostring(_G.FACTION_STANDING_LABEL6))
    local shown = 0
    for i = 1, math.min(GetMerchantNumItems(), MAX_WARES) do
        local tip = MerchantTooltip(i)
        local rq = tip and Codex.ReputationRequirement(tip)
        if rq or shown < 2 then
            shown = shown + 1
            local texts = {}
            for _, line in ipairs(tip and tip.lines or {}) do
                if type(line) == "table" and type(line.leftText) == "string" then texts[#texts + 1] = line.leftText end
            end
            FW:Print(string.format("Ruf: Ware %d: %s -> %s", i, #texts > 0 and table.concat(texts, " | "):sub(1, 160) or "(kein Tooltip)",
                rq and string.format("%s Stufe %d %s", rq.f, rq.s, rq.ok and "erfuellt" or "NICHT erfuellt") or (rq == false and "kein Ruf noetig" or "nicht lesbar")))
        end
        if shown >= 8 then break end
    end
end
SLASH_FREEWOODREPDIAG1 = "/fwruf"
SlashCmdList["FREEWOODREPDIAG"] = function() Roles.RepDiag() end

function Roles:ScanMerchant()
    local count = 0
    if GetMerchantNumItems then
        count = GetMerchantNumItems() or 0
    elseif C_MerchantFrame and C_MerchantFrame.GetNumItems then
        count = C_MerchantFrame.GetNumItems() or 0
    end
    if Util.IsSecret(count) or type(count) ~= "number" or count <= 0 then
        return
    end
    local ent, _, vid = self:Mark("vendor")
    if not ent then
        return
    end
    -- Fraktion des Haendlers (Horde / Allianz) merken
    if vid and UnitFactionGroup then
        local ok, group = pcall(UnitFactionGroup, "npc")
        if ok and not Util.IsSecret(group) and (group == "Alliance" or group == "Horde") then
            Codex.db.vfac = Codex.db.vfac or {}
            Codex.db.vfac[vid] = group == "Alliance" and "A" or "H"
        end
    end
    local wrq
    if vid then
        Codex.db.wrq = Codex.db.wrq or {}
        wrq = Codex.db.wrq[vid]
    end
    if CanMerchantRepair and CanMerchantRepair() then
        self:Mark("repair")
    end
    ent.wa = ent.wa or {}
    local seen = visit.wares or {}
    visit.wares = seen
    local changed = false
    for i = 1, math.min(count, MAX_WARES) do
        local id = MerchantItemID(i)
        local name, price, stack, avail, ec = MerchantInfo(i)
        if id and wrq ~= false and vid then
            local tip = MerchantTooltip(i)
            if tip then
                local rq = Codex.ReputationRequirement(tip)
                Codex.db.wrq[vid] = Codex.db.wrq[vid] or {}
                wrq = Codex.db.wrq[vid]
                wrq.v = 1
                wrq[id] = rq or nil
            end
        end
        if id and price then
            local ware = ent.wa[id]
            if not ware then
                local n = 0
                for _ in pairs(ent.wa) do
                    n = n + 1
                end
                if n < MAX_WARES then
                    ware = { pr = {} }
                    ent.wa[id] = ware
                end
            end
            if ware then
                Codex.NoteName(id, name)
                if stack and stack > 1 then
                    ware.st = math.min(math.floor(stack), 1000)
                end
                if avail and avail >= 0 then
                    ware.lim = 1
                end
                if ec then
                    ware.ec = 1
                end
                local token = id .. ":" .. math.floor(price)
                if not seen[token] then
                    seen[token] = true
                    AddPrice(ware.pr, math.floor(price))
                    changed = true
                end
            end
        end
    end
    if changed then
        FW:Fire("CODEX_CHANGED", "unit", Roles.last and Roles.last.id)
    end
end

------------------------------------------------------------------------
-- Flugmeister
------------------------------------------------------------------------

function Roles:ScanTaxi()
    if not NumTaxiNodes then
        return
    end
    local count = NumTaxiNodes()
    if Util.IsSecret(count) or type(count) ~= "number" or count <= 0 then
        return
    end
    local ent = self:Mark("flight")
    if not ent then
        return
    end
    ent.fl = ent.fl or {}
    local seen = visit.taxi or {}
    visit.taxi = seen
    local nDest = 0
    for _ in pairs(ent.fl) do
        nDest = nDest + 1
    end
    for i = 1, math.min(count, 120) do
        local name = TaxiNodeName and Str(TaxiNodeName(i), 60)
        local kind = TaxiNodeGetType and TaxiNodeGetType(i)
        if name and kind == "CURRENT" then
            ent.fn = name
        elseif name and (kind == "REACHABLE" or kind == nil) then
            local cost = Num(TaxiNodeCost and TaxiNodeCost(i)) or 0
            cost = math.floor(cost)
            local dest = ent.fl[name]
            if not dest and nDest < MAX_DEST then
                dest = {}
                ent.fl[name] = dest
                nDest = nDest + 1
            end
            if dest and not seen[name .. ":" .. cost] then
                seen[name .. ":" .. cost] = true
                AddPrice(dest, cost)
            end
        end
    end
end

------------------------------------------------------------------------
-- Lehrer
------------------------------------------------------------------------

-- Lehrer-Funktionen: erst die klassische Form, dann C_Trainer (Antworten als Liste oder als Tabelle)
local function TrainerCall(name, ...)
    local fn = _G[name]
    if type(fn) ~= "function" and C_Trainer and type(C_Trainer[name]) == "function" then
        fn = C_Trainer[name]
    end
    if type(fn) ~= "function" then
        return nil
    end
    local r = { pcall(fn, ...) }
    if not r[1] then
        return nil
    end
    table.remove(r, 1)
    return r
end

local function FirstNumber(r, field)
    local v = r and r[1]
    if type(v) == "table" then
        v = v[field] or v.cost or v.moneyCost
    end
    return Num(v)
end

local TRAINER_STATES = { available = true, used = true, unavailable = true, header = true, none = true }

-- Rang einer Lehrerzeile aus dem Tooltip (rechte Seite der ersten Zeile, zum Beispiel "Rang 2")
-- Zauber-ID einer Lehrerzeile: Link der Zeile, Tabellenfeld oder Tooltip-Daten. Rueckgabe: ID, Quelle
local function TrainerSpell(i, info)
    local r = TrainerCall("GetTrainerServiceItemLink", i)
    local link = r and Util.Clean(r[1])
    if type(link) == "string" then
        local id = tonumber(link:match("spell:(%d+)")) or tonumber(link:match("enchant:(%d+)"))
        if id then
            return id, "link"
        end
    end
    if type(info) == "table" then
        local id = Num(info.spellID) or Num(info.spellId)
        if id and id > 0 then
            return id, "info"
        end
    end
    for _, fname in ipairs({ "GetTrainerServiceSpellID", "GetTrainerServiceSpell" }) do
        local rr = TrainerCall(fname, i)
        local id = rr and Num(rr[1])
        if id and id > 0 then
            return id, fname
        end
    end
    if C_TooltipInfo and C_TooltipInfo.GetTrainerService then
        local ok, data = pcall(C_TooltipInfo.GetTrainerService, i)
        if ok and type(data) == "table" and not Util.IsSecret(data) then
            local id = Num(data.spellID) or Num(data.spellId)
            if not id and Enum and Enum.TooltipDataType and data.type == Enum.TooltipDataType.Spell then
                id = Num(data.id)
            end
            if id and id > 0 then
                return id, "tooltip"
            end
        end
    end
    return nil
end

local function SpellRank(id)
    local text
    if C_Spell and C_Spell.GetSpellSubtext then
        local ok, v = pcall(C_Spell.GetSpellSubtext, id)
        text = ok and v or nil
    elseif GetSpellSubtext then
        local ok, v = pcall(GetSpellSubtext, id)
        text = ok and v or nil
    end
    return Str(text, 30)
end

function Codex.SpellRank(id)
    return SpellRank(id)
end

function Codex.SpellIcon(id)
    if C_Spell and C_Spell.GetSpellInfo then
        local ok, info = pcall(C_Spell.GetSpellInfo, id)
        if ok and type(info) == "table" and info.iconID then
            return info.iconID
        end
    end
    if GetSpellTexture then
        local ok, v = pcall(GetSpellTexture, id)
        if ok then
            return v
        end
    end
    return nil
end

local function TrainerRank(i)
    if not (C_TooltipInfo and C_TooltipInfo.GetTrainerService) then
        return nil
    end
    local ok, data = pcall(C_TooltipInfo.GetTrainerService, i)
    if not ok or type(data) ~= "table" or Util.IsSecret(data) then
        return nil
    end
    if TooltipUtil and TooltipUtil.SurfaceArgs then
        pcall(TooltipUtil.SurfaceArgs, data)
    end
    for n = 1, 3 do
        local line = type(data.lines) == "table" and data.lines[n] or nil
        if type(line) == "table" then
            local text = Str(line.rightText, 30)
            if text and text:find("%d") and #text <= 20 then
                return (text:gsub("^%(", ""):gsub("%)$", ""))
            end
        end
    end
    return nil
end

function Roles:ScanTrainer()
    local trade = TrainerCall("IsTradeskillTrainer")
    local role = (trade and trade[1] == true) and "proftrainer" or "classtrainer"
    local ent = self:Mark(role)
    if not ent then
        return
    end
    local c = TrainerCall("GetNumTrainerServices")
    local count = FirstNumber(c)
    Roles.trainerDiag = string.format("%s: %s", tostring(role), tostring(count))
    if not count or count <= 0 then
        return
    end
    ent.tr = ent.tr or {}
    if Codex.LearnPlanReset then Codex.LearnPlanReset() end
    -- Klasse des Spielers merken: damit gehoert der Lehrer auch dann zu einer Klasse, wenn der Titel unbekannt ist
    if role == "classtrainer" and not ent.trc then
        local token
        if UnitClass then
            local _, t = UnitClass("player")
            token = t
        end
        if type(token) == "string" and not Util.IsSecret(token) and Codex.CLASS_TOKENS[token] then ent.trc = token end
    end
    for key, rec in pairs(ent.tr) do
        if rec.rk and TRAINER_STATES[rec.rk] then
            ent.tr[key] = nil -- aeltere Fehlerfassung: Zustand statt Rang
        end
    end
    local seen = visit.train or {}
    visit.train = seen
    local n = 0
    for _ in pairs(ent.tr) do
        n = n + 1
    end
    for i = 1, math.min(count, 400) do
        local r = TrainerCall("GetTrainerServiceInfo", i) or {}
        local name, rank, category = r[1], r[2], r[3]
        if type(name) == "table" then
            local t = name
            name, rank, category = t.name, t.subText or t.rank or t.subtext, t.category or t.state
        end
        -- Forever liefert (Name, Zustand) ohne Rang: Zustand erkennen, Rang woanders suchen
        if type(rank) == "string" and TRAINER_STATES[rank] then
            category, rank = rank, nil
        end
        name, rank = Str(name, 60), Str(rank, 30)
        local sp, source
        if name and category ~= "header" then
            sp, source = TrainerSpell(i, r[1])
            if sp then
                Roles.trainerSources[source] = (Roles.trainerSources[source] or 0) + 1
                rank = rank or SpellRank(sp)
            end
            if not rank then
                rank = TrainerRank(i)
            end
        end
        if name and category ~= "header" then
            local lv = FirstNumber(TrainerCall("GetTrainerServiceLevelReq", i), "level")
            lv = lv and lv > 0 and math.floor(lv) or nil
            -- Schluessel: Zauber-ID, sonst Name mit Rang, sonst Name mit Stufe
            local plain = name .. (rank and ("#" .. rank) or (lv and ("#L" .. lv)) or "")
            local key = sp and ("s" .. sp) or plain
            if sp then
                ent.tr[plain] = nil -- aeltere Eintraege ohne Zauber-ID
                ent.tr[name .. (lv and ("#L" .. lv) or "")] = nil
            end
            local rec = ent.tr[key]
            if not rec and n < MAX_TRAIN then
                rec = { nm = name, rk = rank, pr = {} }
                ent.tr[key] = rec
                n = n + 1
            end
            if rec and sp then
                rec.sp = sp
                rec.rk = rank or rec.rk
            end
            if rec then
                if lv then
                    rec.lv = lv
                end
                local sk = TrainerCall("GetTrainerServiceSkillReq", i)
                if sk then
                    local sn, sr = Str(sk[1], 40), Num(sk[2])
                    if sn then
                        rec.sn, rec.sr = sn, sr and math.floor(sr) or nil
                    end
                end
                local cost = FirstNumber(TrainerCall("GetTrainerServiceCost", i), "moneyCost")
                if cost and not seen[key .. ":" .. cost] then
                    seen[key .. ":" .. cost] = true
                    AddPrice(rec.pr, math.floor(cost))
                end
            end
        end
    end
end

------------------------------------------------------------------------
-- Gespraeche und allgemeine Fenster
------------------------------------------------------------------------

local GOSSIP_ROLE = {
    binder = "innkeeper", spiritguide = "spirithealer", battlemaster = "battlemaster", banker = "banker",
    auctioneer = "auctioneer", taxi = "flight", vendor = "vendor", stable = "stablemaster", stablemaster = "stablemaster",
}

local function GossipKinds()
    local kinds = {}
    if GetGossipOptions then
        local t = { GetGossipOptions() }
        for i = 2, #t, 2 do
            if type(t[i]) == "string" then
                kinds[#kinds + 1] = t[i]
            end
        end
    end
    if #kinds == 0 and C_GossipInfo and C_GossipInfo.GetOptions then
        local ok, list = pcall(C_GossipInfo.GetOptions)
        if ok and type(list) == "table" then
            local icons
            if Enum and Enum.GossipOptionIcon then
                icons = {}
                for name, value in pairs(Enum.GossipOptionIcon) do
                    icons[value] = tostring(name):lower()
                end
            end
            for _, opt in ipairs(list) do
                if type(opt) == "table" then
                    local kind = type(opt.type) == "string" and opt.type or (icons and icons[opt.icon]) or nil
                    if kind then
                        kinds[#kinds + 1] = kind:lower()
                    end
                end
            end
        end
    end
    return kinds
end

function Roles:OnGossip()
    local done = {}
    for _, kind in ipairs(GossipKinds()) do
        Roles.gossip[kind] = (Roles.gossip[kind] or 0) + 1
        local role = GOSSIP_ROLE[kind]
        if not role then
            for word, r in pairs(GOSSIP_ROLE) do
                if kind:find(word, 1, true) then
                    role = r
                end
            end
        end
        if role and not done[role] then
            done[role] = true
            self:Mark(role)
        end
    end
end

-- PLAYER_INTERACTION_MANAGER_FRAME_SHOW: Enum.PlayerInteractionType -> Rolle
local INTERACTION_ROLE = {
    Banker = "banker", Auctioneer = "auctioneer", TaxiNode = "flight", StableMaster = "stablemaster",
    SpiritHealer = "spirithealer", Binder = "innkeeper", BattleMaster = "battlemaster", MailInfo = "mailbox",
    Merchant = "vendor",
}

function Roles:OnInteraction(ty)
    local names = Roles.interactionNames
    if not names then
        names = {}
        if Enum and Enum.PlayerInteractionType then
            for name, value in pairs(Enum.PlayerInteractionType) do
                names[value] = name
            end
        end
        Roles.interactionNames = names
    end
    local name = names[ty]
    if name then
        Roles.gossip["frame:" .. name] = (Roles.gossip["frame:" .. name] or 0) + 1
    end
    if name == "Trainer" then
        Roles.trainerOpen = true
        visit.train = nil
        self:ScanTrainer()
        return
    end
    local role = name and INTERACTION_ROLE[name]
    if role and role ~= "vendor" and role ~= "flight" then
        self:Mark(role, role == "mailbox")
    end
end

------------------------------------------------------------------------
-- Start / Stopp
------------------------------------------------------------------------

local SIMPLE = {
    PET_STABLE_SHOW = "stablemaster",
    AUCTION_HOUSE_SHOW = "auctioneer",
    BANKFRAME_OPENED = "banker",
    BATTLEFIELDS_SHOW = "battlemaster",
    MAIL_SHOW = "mailbox",
}

local EVENTS = { "MERCHANT_SHOW", "MERCHANT_UPDATE", "MERCHANT_CLOSED", "TAXIMAP_OPENED", "TRAINER_SHOW", "TRAINER_UPDATE", "TRAINER_CLOSED",
    "GOSSIP_SHOW", "PLAYER_INTERACTION_MANAGER_FRAME_SHOW" }

local function Handler(event)
    return function(_, ...)
        Roles.events[event] = (Roles.events[event] or 0) + 1
        if not (Codex.db and Codex.db.settings and Codex.db.settings.enabled) then
            return
        end
        Codex.Safe(function(...)
            if event == "MERCHANT_SHOW" then
                visit.wares = nil
                Roles:ScanMerchant()
            elseif event == "MERCHANT_UPDATE" then
                Roles:ScanMerchant()
            elseif event == "MERCHANT_CLOSED" then
                visit.wares = nil
            elseif event == "TAXIMAP_OPENED" then
                visit.taxi = nil
                Roles:ScanTaxi()
            elseif event == "TRAINER_SHOW" then
                visit.train = nil
                Roles.trainerOpen = true
                Roles:ScanTrainer()
            elseif event == "TRAINER_UPDATE" then
                if Roles.trainerOpen then
                    Roles:ScanTrainer()
                end
            elseif event == "TRAINER_CLOSED" then
                Roles.trainerOpen = false
            elseif event == "GOSSIP_SHOW" then
                Roles:OnGossip()
            elseif event == "PLAYER_INTERACTION_MANAGER_FRAME_SHOW" then
                Roles:OnInteraction((...))
            elseif SIMPLE[event] then
                Roles:Mark(SIMPLE[event], event == "MAIL_SHOW")
            end
        end, ...)
    end
end

function Roles:Start()
    if self.started then
        return
    end
    self.started = true
    self.registered = {}
    local function reg(event)
        if FW:RegisterEvent(event, Handler(event), Roles) then
            self.registered[#self.registered + 1] = event
        end
    end
    for _, event in ipairs(EVENTS) do
        reg(event)
    end
    for event in pairs(SIMPLE) do
        reg(event)
    end
end

function Roles:Stop()
    for _, event in ipairs(self.registered or {}) do
        FW:UnregisterEvent(event, Roles)
    end
    self.registered = {}
    self.started = false
end

-- Ausgabe fuer /fwcodex roles
function Roles:Debug()
    local L = FW.L
    local list = {}
    for event, n in pairs(Roles.events) do
        list[#list + 1] = event .. " x" .. n
    end
    table.sort(list)
    FW:Print(string.format(L.CODEX_ROLES_EVENTS, #list > 0 and table.concat(list, ", ") or "-"))
    local g = {}
    for kind, n in pairs(Roles.gossip) do
        g[#g + 1] = kind .. " x" .. n
    end
    table.sort(g)
    FW:Print(string.format(L.CODEX_ROLES_GOSSIP, #g > 0 and table.concat(g, ", ") or "-"))
    local counts = {}
    for _, group in ipairs({ Codex.db.units, Codex.db.objects }) do
        for _, e in pairs(group) do
            for role in pairs(e.ro or {}) do
                counts[role] = (counts[role] or 0) + 1
            end
        end
    end
    local c = {}
    for role, n in pairs(counts) do
        c[#c + 1] = (L["CODEX_ROLE_" .. role] or role) .. " " .. n
    end
    table.sort(c)
    FW:Print(string.format(L.CODEX_ROLES_COUNTS, #c > 0 and table.concat(c, ", ") or "-"))
    if Roles.trainerDiag then
        local src = {}
        for k, v in pairs(Roles.trainerSources) do src[#src + 1] = k .. " x" .. v end
        table.sort(src)
        FW:Print("Trainer: " .. Roles.trainerDiag .. " | Zauber-IDs: " .. (#src > 0 and table.concat(src, ", ") or "keine"))
    end
    if Roles.last then
        FW:Print(string.format(L.CODEX_ROLES_LAST, tostring(Roles.last.role), tostring(Roles.last.kind), tostring(Roles.last.id)))
    end
end

------------------------------------------------------------------------
-- Lesen (fuer die Oberflaeche): eigene + geteilte Daten
------------------------------------------------------------------------

-- Dienste: wer so etwas anbietet, gilt ohne eigene Kampfdaten nicht als Kampfkreatur
local SERVICE = {
    vendor = true, repair = true, flight = true, innkeeper = true, stablemaster = true, spirithealer = true,
    auctioneer = true, battlemaster = true, banker = true, classtrainer = true, proftrainer = true,
}

-- Rollen einer Kreatur/eines Objekts aus Live-Daten und Vorlage: { rolle = true|Vorlagewert }
-- kind = "units" | "objects". Zusaetzlich fuer Kreaturen: combat (Kampfkreatur), elite, boss
function Codex.RolesOf(kind, id)
    local out = {}
    local seedReady = Codex.Seed and Codex.Seed.Ready and Codex.Seed.Ready()
    local seed = seedReady and Codex.Seed.Roles(kind, id) or nil
    for role, v in pairs(seed or {}) do
        out[role] = v
    end
    local e = Codex.V and Codex.V()[kind] and Codex.V()[kind][id]
    if e then
        for role in pairs(e.ro or {}) do
            out[role] = true
        end
    end
    if kind == "units" then
        local fought = e and ((e.k or 0) > 0 or e.tt ~= nil or e.xp ~= nil or e.xm ~= nil or e.d ~= nil)
        local class = e and e.c
        local rank
        local known = fought or class ~= nil
        if seedReady then
            local ent = Codex.Seed.Entity("units", id)
            if ent then
                rank = ent.rank
                known = known or ent.l1 ~= nil
            end
        end
        if class == "rare" or class == "rareelite" or rank == 4 then
            out.rares = true
        end
        if class == "elite" or class == "rareelite" or class == "worldboss" or rank == 1 or rank == 2 or rank == 3 then
            out.elite = true
        end
        if class == "worldboss" or rank == 3 then
            out.boss = true
        end
        local service = false
        for role in pairs(out) do
            if SERVICE[role] then service = true end
        end
        if fought or (known and not service) then
            out.combat = true
        end
    end
    return out
end

-- Rollen in fester Reihenfolge (Auswahlliste)
Roles.ORDER = {
    units = { "combat", "elite", "boss", "vendor", "repair", "flight", "innkeeper", "stablemaster", "spirithealer", "auctioneer",
        "battlemaster", "banker", "classtrainer", "proftrainer", "rares" },
    objects = { "mailbox", "meetingstone", "chests", "herbs", "mines", "fish" },
}
-- Nur Auswahl, nicht in Listenzeilen und Details (Rang steht dort schon)
local FILTER_ONLY = { combat = true, elite = true, boss = true }

function Codex.RoleList(kind, id)
    local have = Codex.RolesOf(kind, id)
    local list = {}
    for _, role in ipairs(Roles.ORDER[kind] or {}) do
        if have[role] and not FILTER_ONLY[role] then
            list[#list + 1] = role
        end
    end
    return list
end

------------------------------------------------------------------------
-- Lernplan: was lernt eine Klasse auf welcher Stufe (aus den Lehrer-Daten)
------------------------------------------------------------------------

-- Titelwoerter je Klasse (Fallback, falls die Klassennamen des Spiels nicht passen). Das laengste Wort gewinnt,
-- darum steht "teufelsjaeger" vor "jaeger" nicht im Weg.
local CLASS_WORDS = {
    WARRIOR = { "krieger", "warrior", "guerrier", "guerrero", "guerreiro", "guerriero" },
    PALADIN = { "paladin", "paladín" },
    HUNTER = { "jäger", "jaeger", "hunter", "chasseur", "cazador", "caçador", "cacciatore" },
    ROGUE = { "schurke", "schurken", "rogue", "voleur", "pícaro", "ladino", "ladro" },
    PRIEST = { "priester", "priest", "prêtre", "sacerdote" },
    SHAMAN = { "schamane", "schamanen", "shaman", "chaman", "chamán", "xamã", "sciamano" },
    MAGE = { "magier", "magie", "mage", "mago" },
    WARLOCK = { "hexenmeister", "warlock", "démoniste", "brujo", "bruxo", "stregone" },
    DRUID = { "druide", "druiden", "druid", "druide", "druida" },
    DEMONHUNTER = { "teufelsjäger", "dämonenjäger", "demon hunter", "chasseur de démons", "cazador de demonios" },
    DEATHKNIGHT = { "todesritter", "death knight", "chevalier de la mort", "caballero de la muerte" },
    MONK = { "mönch", "monk", "moine", "monje", "monge", "monaco" },
    EVOKER = { "rufer", "evoker", "évocateur", "evocador" },
}
Codex.CLASS_TOKENS = {}
for token in pairs(CLASS_WORDS) do Codex.CLASS_TOKENS[token] = true end

-- Klasse eines Lehrers aus der Titelzeile ("Hexenmeisterlehrer" -> WARLOCK)
function Codex.ClassOfTitle(title)
    if type(title) ~= "string" or title == "" then return nil end
    local low = title:lower()
    local best, bestLen
    for token, words in pairs(CLASS_WORDS) do
        for _, w in ipairs(words) do
            if #w >= 4 and low:find(w, 1, true) and (not bestLen or #w > bestLen) then
                best, bestLen = token, #w
            end
        end
    end
    for _, names in ipairs({ LOCALIZED_CLASS_NAMES_MALE or {}, LOCALIZED_CLASS_NAMES_FEMALE or {} }) do
        for token, name in pairs(names) do
            if type(name) == "string" and name ~= "" then
                -- auch verkuerzte Formen: "Magier" -> "Magie" (Magielehrer), "Magierin" -> "Magier"
                local full = name:lower()
                local stems = { full, (full:gsub("in$", "")), (full:gsub("er$", "e")) }
                for _, stem in ipairs(stems) do
                    if #stem >= 4 and low:find(stem, 1, true) and (not bestLen or #stem > bestLen) then
                        best, bestLen = token, #stem
                    end
                end
            end
        end
    end
    return best
end

-- Klasse eines Lehrers: aus dem Titel, sonst die Klasse des Spielers, der das Lehrerfenster geoeffnet hat
-- (Klassenlehrer anderer Klassen lassen sich im Spiel nicht oeffnen)
function Codex.ClassOfTrainer(u)
    if type(u) ~= "table" or not u.tr then return nil end
    local byTitle = Codex.ClassOfTitle(u.ti)
    if byTitle then return byTitle end
    if u.ro and (u.ro.classtrainer or 0) > 0 and Codex.CLASS_TOKENS[u.trc or ""] then return u.trc end
    return nil
end

function Codex.ModePrice(pr)
    local price, count
    for p, n in pairs(pr or {}) do
        if not count or n > count or (n == count and p > price) then price, count = p, n end
    end
    return price
end

local function ModePrice(pr)
    local price, count
    for p, n in pairs(pr or {}) do
        if not count or n > count or (n == count and p > price) then price, count = p, n end
    end
    return price
end

-- Lehrer fuer Begleiter-Fertigkeiten (Tierausbilder)
local function IsPetTrainer(u)
    local t = tostring(u and u.ti or ""):lower()
    return t:find("tierausbilder", 1, true) ~= nil or t:find("pet trainer", 1, true) ~= nil or t:find("tiertrainer", 1, true) ~= nil
end

-- Der Plan wird aus allen Lehrerdaten gebaut (ca. 10 ms) und aendert sich selten: Zwischenspeicher mit kurzer Lebensdauer.
-- Daten-Aenderungen (Scan, Teilen, Bearbeiten) rufen Codex.LearnPlanReset() auf.
local planCache = {}
local PLAN_TTL = 20
function Codex.LearnPlanReset() planCache = {} end

local BuildLearnPlan

-- Ergebnis: { levels = { [lv] = { lv, spells = {...}, cost, trainers = {id...} } }, order = { lv... } }
function Codex.LearnPlan(token)
    local now = _G.GetTime and _G.GetTime() or 0
    local c = planCache[token]
    if c and now >= c.t and now - c.t < PLAN_TTL then return c.plan end
    local plan = BuildLearnPlan(token)
    planCache[token] = { t = now, plan = plan }
    return plan
end

BuildLearnPlan = function(token)
    local levels, order = {}, {}
    local seen = {}
    -- Manche Lehrer-Eintraege haben keine Stufe (nicht gelesen). Die Stufe steht aber meist bei einem anderen Lehrer derselben
    -- Klasse: dieselbe Zauber-ID, sonst derselbe Name mit demselben Rang.
    local lvOf = {}
    for _, u in pairs(Codex.V().units) do
        if u.tr and Codex.ClassOfTrainer(u) == token then
            for _, r in pairs(u.tr) do
                if r.lv then
                    if r.sp then lvOf["s" .. r.sp] = r.lv end
                    if r.nm then lvOf[r.nm .. "|" .. (r.rk or "")] = r.lv end
                end
            end
        end
    end
    for id, u in pairs(Codex.V().units) do
        if Codex.ClassOfTrainer(u) == token then
            for key, r in pairs(u.tr) do
                local lv = r.lv or (r.sp and lvOf["s" .. r.sp]) or lvOf[(r.nm or "") .. "|" .. (r.rk or "")] or 0
                local skey = lv .. "\1" .. (r.sp and ("s" .. r.sp) or key)
                local sp = seen[skey]
                if not sp then
                    sp = { nm = r.nm, sp = r.sp, rk = r.rk, lv = lv, pr = {}, trainers = {} }
                    seen[skey] = sp
                    local g = levels[lv]
                    if not g then
                        g = { lv = lv, spells = {}, trainers = {}, trainerSet = {}, cost = 0 }
                        levels[lv] = g
                        order[#order + 1] = lv
                    end
                    g.spells[#g.spells + 1] = sp
                end
                sp.rk = sp.rk or r.rk
                sp.sp = sp.sp or r.sp
                for p, n in pairs(r.pr or {}) do sp.pr[p] = (sp.pr[p] or 0) + n end
                local g = levels[lv]
                if IsPetTrainer(u) then sp.pet = true end
                if not sp.trainers[id] then
                    sp.trainers[id] = true
                    if not g.trainerSet[id] then
                        g.trainerSet[id] = true
                        g.trainers[#g.trainers + 1] = id
                    end
                end
            end
        end
    end
    table.sort(order)
    for _, lv in ipairs(order) do
        local g = levels[lv]
        table.sort(g.spells, function(a, b)
            if (a.nm or "") ~= (b.nm or "") then return (a.nm or "") < (b.nm or "") end
            return (a.rk or "") < (b.rk or "")
        end)
        table.sort(g.trainers)
        for _, sp in ipairs(g.spells) do
            sp.cost = ModePrice(sp.pr)
            g.cost = g.cost + (sp.cost or 0)
        end
    end
    return { levels = levels, order = order }
end

-- Klassen, fuer die Lehrer-Daten vorliegen
function Codex.LearnClasses()
    local set, list = {}, {}
    for _, u in pairs(Codex.V().units) do
        local t = Codex.ClassOfTrainer(u)
        if t and not set[t] then set[t] = true; list[#list + 1] = t end
    end
    table.sort(list)
    return list
end

-- Gesamtkosten aller Stufen in (von, bis]
function Codex.LearnCost(plan, from, to)
    local sum = 0
    for _, lv in ipairs(plan.order) do
        if lv > from and lv <= to then sum = sum + plan.levels[lv].cost end
    end
    return sum
end

------------------------------------------------------------------------
-- Favoriten und Notizen (nur lokal, wird nicht geteilt)
------------------------------------------------------------------------

local FAV_PREFIX = { quests = "q", units = "u", objects = "o", items = "i" }
local MAX_NOTE = 200

local function FavKey(kind, id)
    local p = FAV_PREFIX[kind]
    return (p and id ~= nil) and (p .. tostring(id)) or nil
end

function Codex.FavSupported(kind) return FAV_PREFIX[kind] ~= nil end

function Codex.GetFav(kind, id)
    local key = FavKey(kind, id)
    return key and Codex.db.fav and Codex.db.fav[key] or nil
end

function Codex.IsFav(kind, id)
    return Codex.GetFav(kind, id) ~= nil
end

function Codex.SetFav(kind, id, on)
    local key = FavKey(kind, id)
    if not key then return false end
    Codex.db.fav = Codex.db.fav or {}
    if on then
        Codex.db.fav[key] = Codex.db.fav[key] or { t = time and time() or 0 }
    else
        Codex.db.fav[key] = nil
    end
    return true
end

function Codex.SetNote(kind, id, text)
    local key = FavKey(kind, id)
    if not key then return false end
    -- Zeichen, die Farbcodes oder das Austauschformat stoeren wuerden, ersetzen
    text = tostring(text or ""):gsub("[%c|]", " "):gsub("[;=]", ","):gsub("^%s+", ""):gsub("%s+$", "")
    if #text > MAX_NOTE then text = text:sub(1, MAX_NOTE) end
    Codex.db.fav = Codex.db.fav or {}
    local e = Codex.db.fav[key]
    if text == "" then
        if e then e.note = nil end
        return true
    end
    if not e then
        e = { t = time and time() or 0 }
        Codex.db.fav[key] = e
    end
    e.note = text
    return true
end

------------------------------------------------------------------------
-- Dev-Notizen: Notizen zu Eintraegen (Quest, Kreatur, Objekt, Item), nur mit dem Modul Freewood-Dev und
-- einer Rolle mit Bearbeitungsrecht. Sie liegen lokal beim Entwickler und werden nicht geteilt.
------------------------------------------------------------------------

local MAX_DEVNOTE = 500

function Codex.DevNoteSupported(kind) return FAV_PREFIX[kind] ~= nil end

-- Darf dieser Charakter Dev-Notizen sehen und schreiben?
function Codex.CanDevNote()
    return FW.Dev ~= nil and Codex.Trust ~= nil and Codex.Trust.CanEdit() and true or false
end

function Codex.GetDevNote(kind, id)
    local key = FavKey(kind, id)
    local e = key and Codex.db.dnotes and Codex.db.dnotes[key]
    return e and e.n or nil
end

function Codex.SetDevNote(kind, id, text)
    local key = FavKey(kind, id)
    if not key or not Codex.CanDevNote() then return false end
    text = tostring(text or ""):gsub("[%c|]", " "):gsub("^%s+", ""):gsub("%s+$", "")
    if #text > MAX_DEVNOTE then text = text:sub(1, MAX_DEVNOTE) end
    Codex.db.dnotes = Codex.db.dnotes or {}
    if text == "" then
        Codex.db.dnotes[key] = nil
    else
        Codex.db.dnotes[key] = { n = text, t = time and time() or 0 }
    end
    return true
end

function Codex.DevNoteCount()
    local n = 0
    for _ in pairs(Codex.db.dnotes or {}) do n = n + 1 end
    return n
end

-- Austausch: eine Zeile "FWFAV1;q123=Notiz;u55=;i12=Notiz" (Eintraege ohne Notiz haben nach = nichts)
function Codex.FavExport()
    local keys = {}
    for key in pairs(Codex.db.fav or {}) do keys[#keys + 1] = key end
    table.sort(keys)
    local parts = { "FWFAV1" }
    for _, key in ipairs(keys) do
        local e = Codex.db.fav[key]
        parts[#parts + 1] = key .. "=" .. (e.note or "")
    end
    return table.concat(parts, ";"), #keys
end

-- Ergaenzt vorhandene Favoriten; bestehende Notizen bleiben. Rueckgabe: neu hinzugekommen, Notizen uebernommen, ungueltig
function Codex.FavImport(text)
    text = tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if text:sub(1, 6) ~= "FWFAV1" then return nil end
    Codex.db.fav = Codex.db.fav or {}
    local added, notes, bad = 0, 0, 0
    for item in text:sub(8):gmatch("[^;]+") do
        local key, note = item:match("^([quio]%d+)=(.*)$")
        if key then
            local e = Codex.db.fav[key]
            if not e then
                e = { t = time and time() or 0 }
                Codex.db.fav[key] = e
                added = added + 1
            end
            if note ~= "" and not e.note then
                e.note = note:sub(1, 200)
                notes = notes + 1
            end
        else
            bad = bad + 1
        end
    end
    return added, notes, bad
end
