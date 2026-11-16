-- Freewood-Codex: Wofuer ein Item gebraucht wird und wo man es kaufen kann (seit 0.50.0)
--   Codex.Uses.Recipes(itemID)  Rezepte, die das Item als Material brauchen { prof, name, it, n, skill }
--   Codex.Uses.Quests(itemID)   Quests, die das Item brauchen (Quest-Items) { id, t, lvl, mn, zone }
--   Codex.Uses.Vendors(itemID)  Haendler, die es verkaufen { id, name, zone, price }, guenstigster zuerst
-- Dazu:
--   * Tooltip-Zeile "Beim Haendler: Name (Gebiet) Preis" (Einstellung tipVendorBuy, Standard aus, hoechstens 3)
--   * Klick mit Zusatztasten (Standard Strg+Alt+Linksklick) auf ein Item oder einen Item-Link oeffnet den Codex beim
--     Item (Einstellung Codex.db.settings.openClick: ctrlalt, ctrlshift, altshift, off). Echte Tastenbelegungen des
--     Spiels koennen keine Klicks belegen, deshalb eine Einstellung.
-- Grundlage: Rezepte aus db.recipes (eigene Berufsfenster + Forever-Startdaten), Quests und Haendler aus Codex.V().
-- Im Spiel ungeprueft.

local ADDON, NS = ...

local FW = _G.Freewood
local Codex = NS and NS.Codex
if not FW or not Codex then
    return
end

local G = _G
local U = {}
Codex.Uses = U

U.MAX_TIP = 3
U.CACHE_SECS = 20

local function Now() return (G.GetTime and G.GetTime()) or 0 end

------------------------------------------------------------------------
-- Rezepte: Rueckverweis Material -> Rezepte (neu gebaut, wenn sich die Zahl der Rezepte aendert)
------------------------------------------------------------------------

local recIndex, recCount
local function RecipeIndex()
    local store = Codex.db and Codex.db.recipes or {}
    local n = 0
    for _, list in pairs(store) do
        if type(list) == "table" then for _ in pairs(list) do n = n + 1 end end
    end
    if recIndex and n == recCount then return recIndex end
    recIndex, recCount = {}, n
    for prof, list in pairs(store) do
        if type(list) == "table" then
            for name, r in pairs(list) do
                if type(r) == "table" and type(r.rg) == "table" then
                    for mat, cnt in pairs(r.rg) do
                        mat = tonumber(mat)
                        if mat then
                            local t = recIndex[mat]
                            if not t then t = {} recIndex[mat] = t end
                            t[#t + 1] = { prof = prof, name = name, it = tonumber(r.it), n = tonumber(cnt) or 1 }
                        end
                    end
                end
            end
        end
    end
    return recIndex
end
U.RecipeIndex = RecipeIndex

function U.Recipes(itemID, withSkill)
    local out = {}
    for _, r in ipairs(RecipeIndex()[itemID] or {}) do
        local e = { prof = r.prof, name = r.name, it = r.it, n = r.n }
        if withSkill and Codex.Recipes and Codex.Recipes.ReqOf then
            local ok, sk = pcall(Codex.Recipes.ReqOf, r.prof, r.name)
            if ok then e.skill = sk end
        end
        out[#out + 1] = e
    end
    table.sort(out, function(a, b)
        if (a.skill or 0) ~= (b.skill or 0) then return (a.skill or 0) < (b.skill or 0) end
        if a.prof ~= b.prof then return a.prof < b.prof end
        return a.name < b.name
    end)
    return out
end

------------------------------------------------------------------------
-- Quests, die das Item brauchen
------------------------------------------------------------------------

function U.Quests(itemID)
    local out = {}
    local V = Codex.V and Codex.V() or Codex.db
    for qid, q in pairs(V.quests or {}) do
        local need = type(q.qi) == "table" and q.qi[itemID] ~= nil
        if not need and type(q.obj) == "table" then
            for _, o in ipairs(q.obj) do
                if type(o) == "table" and tonumber(o.item) == itemID then need = true break end
            end
        end
        if need then
            out[#out + 1] = { id = qid, t = (Codex.QuestTitle and Codex.QuestTitle(q, qid)) or q.t or ("#" .. qid),
                lvl = tonumber(q.lvl), mn = tonumber(q.mn) or tonumber(q.pl), zone = q.zone }
        end
    end
    table.sort(out, function(a, b)
        if (a.lvl or 0) ~= (b.lvl or 0) then return (a.lvl or 0) < (b.lvl or 0) end
        return a.id < b.id
    end)
    return out
end

------------------------------------------------------------------------
-- Haendler, die das Item verkaufen (guenstigster zuerst)
------------------------------------------------------------------------

local vendorCache = {}
function U.Vendors(itemID)
    local c = vendorCache[itemID]
    if c and Now() - c.t < U.CACHE_SECS then return c.list end
    local out = {}
    local V = Codex.V and Codex.V() or Codex.db
    for vid, ent in pairs(V.units or {}) do
        local w = type(ent.wa) == "table" and ent.wa[itemID]
        if w then
            local low
            for price in pairs(type(w) == "table" and w.pr or {}) do
                price = tonumber(price)
                if price and (not low or price < low) then low = price end
            end
            local m = Codex.MainMap and Codex.MainMap(ent.cells)
            out[#out + 1] = { id = vid, name = (Codex.NameOf and Codex.NameOf(ent)) or ent.n or ("#" .. vid),
                zone = m and Codex.MapName and Codex.MapName(m) or nil, price = low }
        end
    end
    table.sort(out, function(a, b)
        if (a.price or math.huge) ~= (b.price or math.huge) then return (a.price or math.huge) < (b.price or math.huge) end
        return a.id < b.id
    end)
    vendorCache[itemID] = { t = Now(), list = out }
    return out
end
function U.ClearCache() vendorCache = {} recIndex = nil end

function U.Get(itemID)
    return { recipes = U.Recipes(itemID, true), quests = U.Quests(itemID), vendors = U.Vendors(itemID) }
end

------------------------------------------------------------------------
-- Tooltip: "Beim Haendler"
------------------------------------------------------------------------

local function ItemIDFromLink(link)
    if type(link) ~= "string" then return nil end
    return tonumber(link:match("item:(%d+)"))
end
U.ItemIDFromLink = ItemIDFromLink

local T = FW.Tooltips
function U.AddTooltipLines(tt, link)
    if not (T and T.Get and T.Get("tipVendorBuy") == true) then return 0 end
    local id = ItemIDFromLink(link)
    if not id then return 0 end
    local list = U.Vendors(id)
    if #list == 0 then return 0 end
    local L = FW.L
    local money = (T.Money) or function(v) return tostring(v) end
    tt:AddLine(L.CODEX_TIP_VENDORBUY, 1, 0.82, 0)
    local n = 0
    for _, v in ipairs(list) do
        n = n + 1
        if n > U.MAX_TIP then break end
        local left = v.name .. (v.zone and (" (" .. v.zone .. ")") or "")
        if tt.AddDoubleLine then
            tt:AddDoubleLine("  " .. left, v.price and money(v.price) or "?", 0.9, 0.9, 0.9, 1, 1, 1)
        else
            tt:AddLine("  " .. left .. "  " .. (v.price and money(v.price) or "?"), 0.9, 0.9, 0.9)
        end
    end
    if #list > U.MAX_TIP then tt:AddLine("  " .. string.format(L.CODEX_TIP_VENDORBUY_MORE, #list - U.MAX_TIP), 0.6, 0.6, 0.6) end
    return n
end
if T and T.AddItemLine then T.AddItemLine(function(tt, link) U.AddTooltipLines(tt, link) end) end
if T and T.RegisterOption then T.RegisterOption("tipVendorBuy", "CODEX_OPT_TIPVENDORBUY", { order = 90, default = false }) end

------------------------------------------------------------------------
-- Klick mit Zusatztasten oeffnet den Codex beim Item
------------------------------------------------------------------------

U.MODS = {
    ctrlalt = { ctrl = true, alt = true },
    ctrlshift = { ctrl = true, shift = true },
    altshift = { alt = true, shift = true },
}
U.MOD_ORDER = { "ctrlalt", "ctrlshift", "altshift", "off" }

function U.ClickSetting()
    local s = Codex.db and Codex.db.settings
    local v = s and s.openClick
    if v == nil then return "ctrlalt" end
    return v
end
function U.SetClickSetting(v)
    if Codex.db and Codex.db.settings then Codex.db.settings.openClick = v end
end

local function Down(fn) return (type(fn) == "function" and fn()) and true or false end
function U.ModsMatch()
    local m = U.MODS[U.ClickSetting()]
    if not m then return false end
    return Down(G.IsControlKeyDown) == (m.ctrl == true) and Down(G.IsAltKeyDown) == (m.alt == true)
        and Down(G.IsShiftKeyDown) == (m.shift == true)
end

local lastOpen, dressShownAt = -1, -1
function U.TryOpen(link)
    if not U.ModsMatch() then return false end
    local id = ItemIDFromLink(link)
    if not id then return false end
    local t = Now()
    if t - lastOpen < 0.25 then return true end    -- mehrere Haken fuer denselben Klick
    lastOpen = t
    if Codex.ShowEntry then Codex.ShowEntry("items", id) end
    -- Strg oeffnet im Spiel die Anprobe: hat sie dieser Klick geoeffnet, gleich wieder schliessen
    local function CloseDress()
        local f = G.DressUpFrame
        if f and f:IsShown() and math.abs(dressShownAt - t) < 0.3 then
            if G.HideUIPanel then pcall(G.HideUIPanel, f) else f:Hide() end
        end
    end
    CloseDress()
    if G.C_Timer and G.C_Timer.After then G.C_Timer.After(0, CloseDress) end
    return true
end

if G.hooksecurefunc then
    if type(G.HandleModifiedItemClick) == "function" then
        pcall(G.hooksecurefunc, "HandleModifiedItemClick", function(link) U.TryOpen(link) end)
    end
    if type(G.SetItemRef) == "function" then
        pcall(G.hooksecurefunc, "SetItemRef", function(link, _, button)
            if button == nil or button == "LeftButton" then U.TryOpen(link) end
        end)
    end
end
if G.DressUpFrame and G.DressUpFrame.HookScript then
    G.DressUpFrame:HookScript("OnShow", function() dressShownAt = Now() end)
end

-- Text fuer Hinweise: aktuelle Belegung
function U.ClickText()
    local L = FW.L
    local v = U.ClickSetting()
    return L["CODEX_OPENCLICK_" .. string.upper(v)] or v
end

------------------------------------------------------------------------
-- Einstellungen, Datenbank: "Codex beim Item oeffnen"
------------------------------------------------------------------------

local UI = FW.UI
if UI and UI.RegisterSettingsSection then
    UI:RegisterSettingsSection("codex-openclick", {
        category = "database",
        order = 106,
        height = 120,
        build = function(parent)
            local L = FW.L
            local f, stack = UI.CreateSection(parent, L.CODEX_OPENCLICK_HEADER)
            local dd = UI.CreateDropdown(f, 240, 22, {
                getOptions = function()
                    local o = {}
                    for _, k in ipairs(U.MOD_ORDER) do o[#o + 1] = { value = k, text = L["CODEX_OPENCLICK_" .. string.upper(k)] } end
                    return o
                end,
                onChange = function(v) U.SetClickSetting(v) end,
            })
            stack:Add(dd, { height = 22, gap = 6 })
            stack:Add(UI.CreateLabel(f, L.CODEX_OPENCLICK_NOTE, { size = 11, color = "textDim", justifyV = "TOP" }), { fit = true, gap = 8 })
            stack:Layout()
            f.dd = dd
            if dd.SetValue then dd:SetValue(U.ClickSetting()) end
            return f
        end,
        refresh = function(frame) if frame and frame.dd and frame.dd.SetValue then frame.dd:SetValue(U.ClickSetting()) end end,
    })
end
