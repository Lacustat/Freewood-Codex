-- Freewood-Codex: Rezepte der Berufe
-- Lernt beim Oeffnen eines Berufsfensters jedes Rezept: Ergebnis-Item, Material mit Mengen und die Schwierigkeit
-- (orange/gelb/gruen/grau) bei deinem damaligen Skill. Zusammen mit den Lehrer-Daten (Skill-Anforderung, Preis)
-- weiss der Plan so, was ein Rezept braucht und was es bringt, auch bevor du es gelernt hast.
--   db.recipes[Beruf][Rezeptname] = { it = Ergebnis-Item, rg = { [Materialitem] = Anzahl },
--                                     ob = { optimal|medium|easy|trivial = { kleinster, groesster Skill } }, t = Zeit }
-- Nur lokal; das Teilen mit anderen Spielern kommt spaeter.

local ADDON, NS = ...

local FW = _G.Freewood
local Codex = NS and NS.Codex
if not FW or not Codex then
    return
end

local R = {}
NS.Recipes = R
Codex.Recipes = R

local DIFFS = { optimal = true, medium = true, easy = true, trivial = true }
local MAX_RECIPES = 600

local function Store()
    local db = Codex.db
    if not db then return nil end
    db.recipes = db.recipes or {}
    return db.recipes
end

local function ItemIDOf(link)
    return type(link) == "string" and tonumber(link:match("item:(%d+)")) or nil
end

-- Schwierigkeit aus Zahl (Enum: 0 optimal, 1 mittel, 2 leicht, 3 trivial) oder Text
local DIFF_NUM = { [0] = "optimal", [1] = "medium", [2] = "easy", [3] = "trivial" }
local function DiffOf(v)
    if type(v) == "number" then return DIFF_NUM[v] end
    if type(v) == "string" then
        v = v:lower()
        if DIFFS[v] then return v end
    end
    return nil
end

local function Try(fn, ...)
    if type(fn) ~= "function" then return nil end
    local ok, a, b, c, d = pcall(fn, ...)
    if ok then return a, b, c, d end
    return nil
end

-- Neue Berufsoberflaeche (C_TradeSkillUI): { profession, skill, max, list = { { name, item, diff, reag, learned } } }
local function SnapshotNew()
    local T = _G.C_TradeSkillUI
    if type(T) ~= "table" then return nil end
    local base = Try(T.GetBaseProfessionInfo)
    local name = type(base) == "table" and (base.professionName or base.parentProfessionName) or nil
    local skill = type(base) == "table" and tonumber(base.skillLevel) or nil
    local max = type(base) == "table" and tonumber(base.maxSkillLevel) or nil
    if not name or name == "" then return nil end
    local ids = Try(T.GetAllRecipeIDs)
    if type(ids) ~= "table" or #ids == 0 then return nil end
    local list = {}
    for _, id in ipairs(ids) do
        local info = Try(T.GetRecipeInfo, id)
        if type(info) == "table" and type(info.name) == "string" then
            local diff = DiffOf(info.relativeDifficulty) or DiffOf(info.difficulty)
            local item
            local link = Try(T.GetRecipeItemLink, id)
            item = ItemIDOf(link)
            local reag = {}
            local schem = Try(T.GetRecipeSchematic, id, false)
            if type(schem) == "table" then
                item = item or tonumber(schem.outputItemID)
                for _, slot in ipairs(schem.reagentSlotSchematics or {}) do
                    local first = slot.reagents and slot.reagents[1]
                    local rid = first and tonumber(first.itemID)
                    if rid and tonumber(slot.quantityRequired) then reag[rid] = tonumber(slot.quantityRequired) end
                end
            end
            if not next(reag) then
                local n = Try(T.GetRecipeNumReagents, id) or 0
                for j = 1, n do
                    local _, _, need = Try(T.GetRecipeReagentInfo, id, j)
                    local rid = ItemIDOf(Try(T.GetRecipeReagentItemLink, id, j))
                    if rid and tonumber(need) then reag[rid] = tonumber(need) end
                end
            end
            list[#list + 1] = { name = info.name, item = item, diff = diff or "optimal", reag = reag,
                learned = info.learned ~= false, hasDiff = diff ~= nil, trivial = tonumber(info.maxTrivialLevel) }
        end
    end
    return { profession = name, skill = skill or 0, max = max or 0, list = list }
end

-- Alte Handwerks-Schnittstelle (GetTradeSkill...)
local function SnapshotOld()
    if not (GetTradeSkillLine and GetNumTradeSkills and GetTradeSkillInfo) then return nil end
    local ok, name, rank, maxRank = pcall(GetTradeSkillLine)
    if not ok or type(name) ~= "string" or name == "" or name == "UNKNOWN" then return nil end
    local list = {}
    for i = 1, math.min(GetNumTradeSkills() or 0, MAX_RECIPES) do
        local rname, rtype = GetTradeSkillInfo(i)
        if type(rname) == "string" and DIFFS[rtype] then
            local item = GetTradeSkillItemLink and ItemIDOf(GetTradeSkillItemLink(i)) or nil
            local reag = {}
            local nr = GetTradeSkillNumReagents and GetTradeSkillNumReagents(i) or 0
            for j = 1, nr do
                local _, _, need = GetTradeSkillReagentInfo(i, j)
                local rid = GetTradeSkillReagentItemLink and ItemIDOf(GetTradeSkillReagentItemLink(i, j)) or nil
                if rid and tonumber(need) then reag[rid] = tonumber(need) end
            end
            list[#list + 1] = { name = rname, item = item, diff = rtype, reag = reag, learned = true, hasDiff = true }
        end
    end
    return { profession = name, skill = tonumber(rank) or 0, max = tonumber(maxRank) or 0, list = list }
end

-- Offenes Berufsfenster lesen: neue Oberflaeche zuerst, sonst die alte
function R.Snapshot()
    return SnapshotNew() or SnapshotOld()
end

function R.ReadOpenWindow()
    local store = Store()
    if not store then return false end
    local snap = R.Snapshot()
    if not snap then return false end
    R.last = snap
    local prof = store[snap.profession]
    if not prof then prof = {}; store[snap.profession] = prof end
    local n = 0
    for _ in pairs(prof) do n = n + 1 end
    for _, r in ipairs(snap.list) do
        local rec = prof[r.name]
        if not rec then
            if n >= MAX_RECIPES then break end
            rec = { rg = {}, ob = {} }
            prof[r.name] = rec
            n = n + 1
        end
        if r.item then rec.it = r.item end
        if r.trivial and r.trivial > 0 then rec.tv = r.trivial end   -- ab diesem Skill grau
        for rid, need in pairs(r.reag) do rec.rg[rid] = need end
        if r.learned and r.hasDiff then
            local range = rec.ob[r.diff]
            if range then
                range[1], range[2] = math.min(range[1], snap.skill), math.max(range[2], snap.skill)
            else
                rec.ob[r.diff] = { snap.skill, snap.skill }
            end
        end
        rec.t = time and time() or 0
    end
    FW:Fire("CODEX_RECIPES_CHANGED", snap.profession)
    return true, #snap.list
end

local reading = false
local function OnTradeSkill()
    if reading then return end
    reading = true
    local function Run()
        reading = false
        Codex.Safe(R.ReadOpenWindow)
    end
    if C_Timer and C_Timer.After then
        C_Timer.After(0.5, Run)
    else
        Run()
    end
end

-- Diagnose fuer /fwberufdump: zeigt, was das Spiel zurueckgibt
function R.Dump()
    local function Say(msg) print("|cffe0b84dFreewood Beruf:|r " .. tostring(msg)) end
    local T = _G.C_TradeSkillUI
    Say("C_TradeSkillUI: " .. tostring(type(T) == "table") .. ", alte Schnittstelle (GetTradeSkillLine): " .. tostring(type(GetTradeSkillLine) == "function"))
    if type(T) == "table" then
        local base = Try(T.GetBaseProfessionInfo)
        if type(base) == "table" then
            local keys = {}
            for k, v in pairs(base) do keys[#keys + 1] = k .. "=" .. tostring(v) end
            table.sort(keys)
            Say("GetBaseProfessionInfo: " .. table.concat(keys, ", "))
        else
            Say("GetBaseProfessionInfo: nichts (Berufsfenster offen?)")
        end
        local ids = Try(T.GetAllRecipeIDs)
        Say("GetAllRecipeIDs: " .. (type(ids) == "table" and (#ids .. " Rezepte") or "nichts"))
        local id = type(ids) == "table" and ids[1]
        if id then
            local info = Try(T.GetRecipeInfo, id)
            if type(info) == "table" then
                local keys = {}
                for k, v in pairs(info) do
                    if type(v) ~= "table" then keys[#keys + 1] = k .. "=" .. tostring(v) end
                end
                table.sort(keys)
                Say("GetRecipeInfo(" .. id .. "): " .. table.concat(keys, ", "))
            else
                Say("GetRecipeInfo(" .. id .. "): nichts")
            end
            local schem = Try(T.GetRecipeSchematic, id, false)
            if type(schem) == "table" then
                local keys = {}
                for k, v in pairs(schem) do keys[#keys + 1] = k .. "=" .. (type(v) == "table" and ("#" .. #v) or tostring(v)) end
                table.sort(keys)
                Say("GetRecipeSchematic: " .. table.concat(keys, ", "))
            else
                Say("GetRecipeSchematic: nichts; NumReagents=" .. tostring(Try(T.GetRecipeNumReagents, id)) .. ", ItemLink=" .. tostring(Try(T.GetRecipeItemLink, id)))
            end
        end
    end
    local snap = R.Snapshot()
    if snap then
        local learned = 0
        for _, r in ipairs(snap.list) do if r.learned then learned = learned + 1 end end
        Say(string.format("Auslesen: %s %d/%d, %d Rezepte (%d gelernt)", snap.profession, snap.skill, snap.max, #snap.list, learned))
        local r = snap.list[1]
        if r then
            local mats = {}
            for rid, n in pairs(r.reag) do mats[#mats + 1] = rid .. "x" .. n end
            Say(string.format("Beispiel: %s, Ergebnis-Item %s, Farbe %s, Material %s", r.name, tostring(r.item), tostring(r.diff), table.concat(mats, " ")))
        end
    else
        Say("Auslesen: nichts. Bitte das Berufsfenster oeffnen und den Befehl erneut eingeben.")
    end
    local pn, rn = R.Count()
    Say("In der Datenbank: " .. pn .. " Berufe, " .. rn .. " Rezepte")
end

SLASH_FREEWOODRECIPEDUMP1 = "/fwberufdump"
SlashCmdList["FREEWOODRECIPEDUMP"] = function() R.Dump() end

function R:Start()
    if self.started then return end
    self.started = true
    for _, event in ipairs({ "TRADE_SKILL_SHOW", "TRADE_SKILL_UPDATE", "TRADE_SKILL_LIST_UPDATE", "TRADE_SKILL_DATA_SOURCE_CHANGED" }) do
        FW:RegisterEvent(event, OnTradeSkill, R)
    end
end

function R:Stop()
    for _, event in ipairs({ "TRADE_SKILL_SHOW", "TRADE_SKILL_UPDATE", "TRADE_SKILL_LIST_UPDATE", "TRADE_SKILL_DATA_SOURCE_CHANGED" }) do
        FW:UnregisterEvent(event, R)
    end
    self.started = false
end

function R.Get(profession)
    local store = Store()
    return store and store[profession] or {}
end

function R.Count()
    local store = Store()
    local professions, recipes = 0, 0
    for _, prof in pairs(store or {}) do
        professions = professions + 1
        for _ in pairs(prof) do recipes = recipes + 1 end
    end
    return professions, recipes
end

-- Skill-Anforderung eines Rezepts: vom Lehrer (kleinster Wert), sonst kleinster Skill, bei dem es orange war
function R.ReqOf(profession, name)
    local best
    for _, u in pairs(Codex.V().units) do
        if u.tr and u.ro and (u.ro.proftrainer or 0) > 0 then
            for _, r in pairs(u.tr) do
                if r.nm == name and r.sn == profession and tonumber(r.sr) and (not best or r.sr < best) then best = r.sr end
            end
        end
    end
    if best then return best, true end
    local rec = R.Get(profession)[name]
    local o = rec and rec.ob and rec.ob.optimal
    if o then return o[1], false end
    return nil
end

-- Schwierigkeit bei gegebenem Skill: aus Beobachtungen, sonst geschaetzt (je 10 Skill pro Farbe).
-- Rueckgabe: "optimal" | "medium" | "easy" | "trivial" | "locked", und ob geschaetzt (true) oder beobachtet (false)
function R.DiffAt(profession, name, skill)
    local rec = R.Get(profession)[name]
    local ob = rec and rec.ob or {}
    for diff, range in pairs(ob) do
        if skill >= range[1] and skill <= range[2] then return diff, false end
    end
    local req = R.ReqOf(profession, name)
    if not req and not next(ob) and not (rec and rec.tv) then return nil end
    -- Schwellen: gelb, gruen, grau beginnen bei
    local base = req or (ob.optimal and ob.optimal[1]) or 0
    local tv = rec and rec.tv
    -- Ist die graue Schwelle (maxTrivialLevel) bekannt, liegen gruen und gelb je 10 Skill darunter
    local gray = ob.trivial and ob.trivial[1] or tv or math.max(base + 30, ob.easy and ob.easy[2] + 1 or 0)
    local green = ob.easy and ob.easy[1] or (tv and math.max(gray - 10, ob.medium and ob.medium[2] + 1 or 0)) or math.max(gray - 10, ob.medium and ob.medium[2] + 1 or 0)
    local yellow = ob.medium and ob.medium[1] or math.max(green - 10, ob.optimal and ob.optimal[2] + 1 or 0)
    if not req and not ob.optimal and tv then base = math.max(0, yellow - 10) end
    local first = req or (ob.optimal and ob.optimal[1]) or 0
    if skill < first then return "locked", true end
    if skill < yellow then return "optimal", true end
    if skill < green then return "medium", true end
    if skill < gray then return "easy", true end
    return "trivial", true
end

-- Rezepte beim Lehrer: Liste { name, profession, req, price, trainerID, rec = Rezept oder nil }
function R.TrainerRows()
    local out, seen = {}, {}
    for uid, u in pairs(Codex.V().units) do
        if u.tr and u.ro and (u.ro.proftrainer or 0) > 0 then
            for _, r in pairs(u.tr) do
                if r.nm and r.sn then
                    local key = r.sn .. "\1" .. r.nm
                    local e = seen[key]
                    local price = Codex.ModePrice and Codex.ModePrice(r.pr) or nil
                    if not e then
                        e = { name = r.nm, profession = r.sn, req = tonumber(r.sr), price = price, trainerID = uid,
                            rec = R.Get(r.sn)[r.nm] }
                        seen[key] = e
                        out[#out + 1] = e
                    elseif price and (not e.price or price < e.price) then
                        e.price, e.trainerID = price, uid
                    end
                end
            end
        end
    end
    return out
end
