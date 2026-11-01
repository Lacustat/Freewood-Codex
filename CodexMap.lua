-- Freewood-Codex: Fundorte auf der Weltkarte
-- Zeichnet Punkte mit weissem Rand ueber Blizzards Kartenflaeche: schwarz fuer Kreaturen,
-- rot fuer Objekte, blau fuer Quest-Geber und -Abgabe. Fundorte werden gebuendelt (BIN Zellen je Punkt).
-- Quelle sind die Zellen, die Codex beim Spielen erfasst hat (Raster 200 x 200 je Karte).

local ADDON, NS = ...

local FW = _G.Freewood
local Codex = NS.Codex
if not FW or not Codex then
    return
end

local UI = FW.UI
local GRID = Codex.GRID
local MAX_DOTS = 600
local BIN = 3         -- Zellen je Punkt (3 Zellen = 1,5 % der Kartenbreite)
local DOT_MIN = 9     -- Punktgroesse in Bildschirm-Pixeln (kleinster / groesster Punkt)
local DOT_MAX = 14
local RIM = 1.5       -- weisser Rand in Pixeln
local LAYER_LEVEL = 1500 -- weit ueber Blizzards Kartensymbolen, damit nichts die Punkte verdeckt

local COLORS = {
    u = { 0, 0, 0 },
    o = { 0.9, 0.1, 0.1 },
    p = { 0.2, 0.55, 1 },
}
local ORDER = { u = 1, o = 2, p = 3 }
local MASK = "Interface\\CharacterFrame\\TempPortraitAlphaMask"

local Overlay = { points = nil, label = nil, hooked = false }
Codex.Map = Overlay

local layer, dots, infoButton, StartHover
local segDash = {}   -- [Abschnitt] = { sig, tex = {...}, n }: Striche je Abschnitt, damit nur der veraenderte neu gesetzt wird
local DASH_LEN, DASH_GAP, DASH_THICK = 8, 6, 3   -- Pixel
local MAX_DASHES = 900
local atan2 = math.atan2 or function(y, x) return math.atan(y, x) end

-- Runder Punkt: weisse Scheibe mit schwarzer/roter/blauer Scheibe darauf. Rund wird er durch eine
-- Maske aus dem Spiel; fehlt sie, bleiben es Quadrate.
local function MaskAvailable()
    if Codex.db and Codex.db.settings.squareDots then
        return false
    end
    if type(GetFileIDFromPath) == "function" then
        return GetFileIDFromPath(MASK) ~= nil
    end
    return true
end

local function NewDot(f)
    local dot = {}
    local useMask = MaskAvailable()
    for _, name in ipairs({ "rim", "fill" }) do
        local tex = f:CreateTexture(nil, "OVERLAY", nil, name == "rim" and 1 or 2)
        tex:SetColorTexture(1, 1, 1, 1)
        if useMask and f.CreateMaskTexture and tex.AddMaskTexture then
            local ok, mask = pcall(f.CreateMaskTexture, f)
            if ok and mask then
                mask:SetTexture(MASK, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
                mask:SetAllPoints(tex)
                tex:AddMaskTexture(mask)
                tex.mask = mask
            end
        end
        dot[name] = tex
    end
    return dot
end

local function HideDot(dot)
    dot.rim:Hide()
    dot.fill:Hide()
end

local function Canvas()
    local wm = _G.WorldMapFrame
    if not wm then
        return nil
    end
    if wm.GetCanvas then
        local ok, c = pcall(wm.GetCanvas, wm)
        if ok and c then
            return c
        end
    end
    return wm.ScrollContainer and wm.ScrollContainer.Child or nil
end

local function EnsureLayer()
    if layer then
        return layer
    end
    local canvas = Canvas()
    if not canvas then
        return nil
    end
    -- Die Ebene haengt am Kartenfenster selbst (nicht an der Kartenflaeche): dort ist sie sicher sichtbar.
    -- Die Punkte werden an die Kartenflaeche geheftet und folgen ihr beim Verschieben und Zoomen.
    local wm = _G.WorldMapFrame
    layer = CreateFrame("Frame", nil, wm)
    layer:SetAllPoints(wm.ScrollContainer or wm)
    layer:SetFrameLevel((wm:GetFrameLevel() or 1) + LAYER_LEVEL)
    if wm.GetFrameStrata then
        layer:SetFrameStrata(wm:GetFrameStrata())
    end
    if layer.SetClipsChildren then
        layer:SetClipsChildren(true)
    end
    layer:SetScript("OnSizeChanged", function(_, w)
        if w and w > 1 and Overlay.points then
            Overlay:Refresh()
        end
    end)
    dots = {}
    StartHover(layer)
    return layer
end

local function EnsureInfoButton()
    if infoButton then
        return infoButton
    end
    local wm = _G.WorldMapFrame
    if not wm then
        return nil
    end
    infoButton = UI.CreateButton(wm, "", 300, 22, function()
        Overlay:Clear()
    end, "default")
    infoButton:SetFrameStrata("HIGH")
    infoButton:SetFrameLevel((wm:GetFrameLevel() or 1) + LAYER_LEVEL + 100)
    local anchor = wm.ScrollContainer or wm
    infoButton:SetPoint("TOPLEFT", anchor, "TOPLEFT", 12, -42)
    infoButton:Hide()
    return infoButton
end

local function CurrentMapID()
    local wm = _G.WorldMapFrame
    if wm and wm.GetMapID then
        local ok, id = pcall(wm.GetMapID, wm)
        if ok then
            return id
        end
    end
    return nil
end

-- Faktor Kartenflaeche -> Bildschirm (aendert sich beim Zoomen)
function Overlay:CanvasScale()
    local canvas = Canvas()
    local s = 1
    if canvas and canvas.GetEffectiveScale and _G.UIParent then
        local a, b = canvas:GetEffectiveScale(), _G.UIParent:GetEffectiveScale()
        if type(a) == "number" and type(b) == "number" and b > 0 and a > 0 then
            s = a / b
        end
    end
    return s
end

-- Skalierung der Punkte-Ebene relativ zur Oberflaeche
local function LayerScale()
    local s = 1
    if layer and layer.GetEffectiveScale and _G.UIParent then
        local a, b = layer:GetEffectiveScale(), _G.UIParent:GetEffectiveScale()
        if type(a) == "number" and type(b) == "number" and b > 0 and a > 0 then
            s = a / b
        end
    end
    return s
end

-- Punkte einer Karte zusammenfassen: je Klasse (u, o, p) und BIN x BIN Zellen ein Punkt
function Overlay:Bins(mapID)
    local bins = {}
    for _, p in ipairs(self.points or {}) do
        if p.m == mapID then
            local cls = p.pin and "p" or (p.k == "o" and "o" or "u")
            local cx = math.min(GRID - 1, math.max(0, math.floor(p.x * GRID)))
            local cy = math.min(GRID - 1, math.max(0, math.floor(p.y * GRID)))
            local base = math.floor(cy / BIN) * 1000 + math.floor(cx / BIN)
            local key = base .. cls
            local b = bins[key]
            if not b then
                b = { sx = 0, sy = 0, n = 0, names = {}, cls = cls, base = base }
                bins[key] = b
            end
            local w = p.n or 1
            b.sx, b.sy, b.n = b.sx + p.x * w, b.sy + p.y * w, b.n + w
            if p.name then
                b.names[p.name] = (b.names[p.name] or 0) + w
            end
        end
    end
    local list, maxN, perBase = {}, 1, {}
    for _, b in pairs(bins) do
        b.x, b.y = b.sx / b.n, b.sy / b.n
        list[#list + 1] = b
        perBase[b.base] = (perBase[b.base] or 0) + 1
        if b.n > maxN then
            maxN = b.n
        end
    end
    for _, b in ipairs(list) do
        b.shared = perBase[b.base] > 1
    end
    -- Reihenfolge: Kreaturen zuerst, Quest-Punkte zuletzt (oben)
    table.sort(list, function(a, b)
        if ORDER[a.cls] ~= ORDER[b.cls] then return ORDER[a.cls] < ORDER[b.cls] end
        if a.y ~= b.y then return a.y < b.y end
        return a.x < b.x
    end)
    return list, maxN
end

-- Gestrichelte Linie durch die Wegpunkte (Luftlinie von Station zu Station).
-- Jeder Abschnitt merkt sich seine Lage: bleibt er gleich, werden die Striche nur wieder eingeblendet.
local function HideDashes(from)
    for i = from or 1, #segDash do
        local s = segDash[i]
        for k = 1, s.n do s.tex[k]:Hide() end
        s.n, s.sig = 0, nil
    end
end

local function DrawPath(f, canvas, path, width, height, ratio, layerScale)
    local total = 0
    local len = DASH_LEN / layerScale
    local step = (DASH_LEN + DASH_GAP) / layerScale
    for i = 2, #path do
        local s = segDash[i - 1]
        if not s then s = { tex = {}, n = 0 }; segDash[i - 1] = s end
        local x1, y1 = path[i - 1].x * width * ratio, -path[i - 1].y * height * ratio
        local x2, y2 = path[i].x * width * ratio, -path[i].y * height * ratio
        local sig = string.format("%.2f,%.2f,%.2f,%.2f,%.4f", x1, y1, x2, y2, layerScale)
        if s.sig == sig then
            for k = 1, s.n do s.tex[k]:Show() end
        else
            local dx, dy = x2 - x1, y2 - y1
            local dist = math.sqrt(dx * dx + dy * dy)
            local count = 0
            if dist > 0 then
                local ux, uy = dx / dist, dy / dist
                local angle = atan2(dy, dx)
                local t = len / 2
                while t <= dist and total + count < MAX_DASHES do
                    count = count + 1
                    local tex = s.tex[count]
                    if not tex then
                        tex = f:CreateTexture(nil, "OVERLAY", nil, 0)
                        tex:SetColorTexture(1, 0.85, 0.2, 0.95)
                        s.tex[count] = tex
                    end
                    tex:ClearAllPoints()
                    tex:SetSize(len, DASH_THICK / layerScale)
                    tex:SetPoint("CENTER", canvas, "TOPLEFT", x1 + ux * t, y1 + uy * t)
                    if tex.SetRotation then tex:SetRotation(angle) end
                    tex:Show()
                    t = t + step
                end
            end
            for k = count + 1, s.n do s.tex[k]:Hide() end
            s.n, s.sig = count, sig
        end
        total = total + s.n
    end
    HideDashes(#path)     -- Abschnitte, die es nicht mehr gibt
    return total
end

function Overlay:Refresh()
    local f = EnsureLayer()
    if not f then
        return
    end
    for _, d in ipairs(dots) do
        HideDot(d)
    end
    if not (self.path and #self.path > 1 and self.points) then
        HideDashes()
    end
    f:Show()
    local btn = EnsureInfoButton()
    if not self.points or #self.points == 0 then
        if btn then
            btn:Hide()
        end
        return
    end
    if btn then
        btn:SetLabel(string.format(FW.L.CODEX_MAP_LABEL, self.label or ""))
        btn:SetWidth(math.max(200, (btn.label:GetStringWidth() or 200) + 24))
        btn:Show()
    end

    local mapID = CurrentMapID()
    if not mapID then
        return
    end
    local canvas = Canvas() or f
    local width, height = canvas:GetWidth() or 1, canvas:GetHeight() or 1
    if width < 2 or height < 2 then
        if _G.C_Timer and not self.retrying then
            self.retrying = true
            _G.C_Timer.After(0.2, function()
                Overlay.retrying = false
                if Overlay.points then
                    Overlay:Refresh()
                end
            end)
        end
        return
    end

    local bins, maxN = self:Bins(mapID)
    self.bins = bins
    local scale = self:CanvasScale()
    local layerScale = LayerScale()
    local ratio = scale / layerScale -- Kartenflaeche-Einheiten -> Einheiten der Punkte-Ebene
    self.lastScale = scale
    self.drawnMap = mapID
    self.hoverR = (DOT_MAX / 2 + 3) / scale / width       -- Trefferradius als Anteil der Kartenbreite
    self.hoverRY = (DOT_MAX / 2 + 3) / scale / height
    self.lastDraw = { mapID = mapID, dots = #bins }
    if self.path and #self.path > 1 and self.pathMap == mapID then
        self.lastDraw.dashes = DrawPath(f, canvas, self.path, width, height, ratio, layerScale)
    else
        HideDashes()
    end

    for i, b in ipairs(bins) do
        if i > MAX_DOTS then
            break
        end
        local dot = dots[i]
        if not dot then
            dot = NewDot(f)
            dots[i] = dot
        end
        local px = DOT_MIN + (DOT_MAX - DOT_MIN) * math.min(1, b.n / maxN)
        local d = px / layerScale
        local rim = (px + RIM * 2) / layerScale
        local off, offY = 0, 0
        if b.shared then
            -- Kreatur links, Objekt rechts, Quest-Punkt darueber: nebeneinander statt uebereinander
            local step = (px * 0.7) / layerScale
            if b.cls == "u" then off = -step elseif b.cls == "o" then off = step else offY = step end
        end
        local x, y = b.x * width * ratio + off, -b.y * height * ratio + offY
        local c = COLORS[b.cls]
        dot.rim:ClearAllPoints()
        dot.rim:SetSize(rim, rim)
        dot.rim:SetPoint("CENTER", canvas, "TOPLEFT", x, y)
        dot.rim:SetVertexColor(1, 1, 1, 1)
        dot.rim:Show()
        dot.fill:ClearAllPoints()
        dot.fill:SetSize(d, d)
        dot.fill:SetPoint("CENTER", canvas, "TOPLEFT", x, y)
        dot.fill:SetVertexColor(c[1], c[2], c[3], 1)
        dot.fill:Show()
    end
end

-- Mouseover: Namen der Fundorte in der Naehe des Mauszeigers
local function MouseOverMap()
    local wm = _G.WorldMapFrame
    local sc = wm and wm.ScrollContainer
    if type(sc) ~= "table" or type(sc.GetNormalizedCursorPosition) ~= "function" then
        return nil
    end
    local focus
    if GetMouseFoci then
        focus = GetMouseFoci()
        focus = focus and focus[1]
    elseif GetMouseFocus then
        focus = GetMouseFocus()
    end
    local f, ok = focus, (focus == nil)
    local depth = 0
    while f and depth < 12 do
        if f == sc then
            ok = true
            break
        end
        f = f.GetParent and f:GetParent() or nil
        depth = depth + 1
    end
    if not ok then
        return nil
    end
    local x, y = sc:GetNormalizedCursorPosition()
    if not x or x < 0 or x > 1 or y < 0 or y > 1 then
        return nil
    end
    return x, y
end

function Overlay:HideHover()
    self.hoverKey = nil
    if self.hoverShown then
        self.hoverShown = nil
        local tip = _G.GameTooltip
        if tip:GetOwner() == _G.WorldMapFrame then
            tip:Hide()
        end
    end
end

function Overlay:UpdateHover()
    if not self.points or not self.bins or not self.drawnMap then
        return self:HideHover()
    end
    local x, y = MouseOverMap()
    if not x then
        return self:HideHover()
    end
    local key = math.floor(x * GRID) * 1000 + math.floor(y * GRID)
    if key == self.hoverKey and self.hoverShown ~= nil then
        return
    end
    self.hoverKey = key
    local r, ry = self.hoverR or 0.02, self.hoverRY or 0.03
    local names = {}
    local hit = false
    for i, b in ipairs(self.bins) do
        if i > MAX_DOTS then
            break
        end
        if math.abs(b.x - x) <= r and math.abs(b.y - y) <= ry then
            hit = true
            for name, n in pairs(b.names) do
                names[name] = (names[name] or 0) + n
            end
        end
    end
    if not hit then
        return self:HideHover()
    end
    local list = {}
    for name, n in pairs(names) do
        list[#list + 1] = { name = name, n = n }
    end
    table.sort(list, function(a, b)
        if a.n ~= b.n then return a.n > b.n end
        return a.name < b.name
    end)
    local tip = _G.GameTooltip
    tip:SetOwner(_G.WorldMapFrame, "ANCHOR_CURSOR")
    tip:AddLine(FW.L.CODEX_MAP_HOVER, 0.94, 0.75, 0.36)
    for i, e in ipairs(list) do
        if i > 10 then
            tip:AddLine(string.format(FW.L.CODEX_MAP_MORE, #list - 10), 0.8, 0.8, 0.8)
            break
        end
        tip:AddLine(e.name, 0.85, 0.85, 0.85)
    end
    tip:Show()
    self.hoverShown = true
end

local hoverElapsed = 0
StartHover = function(f)
    f:SetScript("OnUpdate", function(_, elapsed)
        hoverElapsed = hoverElapsed + elapsed
        if hoverElapsed < 0.08 then
            return
        end
        hoverElapsed = 0
        if Overlay.points then
            local sc = Overlay:CanvasScale()
            if Overlay.lastScale and math.abs(sc - Overlay.lastScale) > 0.01 then
                Overlay:Refresh()
            end
            Overlay:UpdateHover()
        end
    end)
end

function Overlay:Hook()
    if self.hooked then
        return true
    end
    local wm = _G.WorldMapFrame
    if not wm or not Canvas() then
        return false
    end
    self.hooked = true
    if wm.OnMapChanged then
        pcall(hooksecurefunc, wm, "OnMapChanged", function()
            Overlay:Refresh()
        end)
    end
    if wm.HookScript then
        wm:HookScript("OnShow", function()
            Overlay:Refresh()
        end)
    end
    return true
end

-- Karte mit dem meisten Gewicht, bevorzugt die aktuelle, wenn sie Punkte hat
function Overlay:BestMap()
    local weights = {}
    for _, p in ipairs(self.points or {}) do
        weights[p.m] = (weights[p.m] or 0) + (p.n or 1)
    end
    local current = CurrentMapID()
    if current and weights[current] then
        return current
    end
    local best, bestN
    for m, n in pairs(weights) do
        if not bestN or n > bestN or (n == bestN and m < best) then
            best, bestN = m, n
        end
    end
    return best
end

-- Weltkarte oeffnen und auf das passende Gebiet stellen
function Overlay:Focus()
    local wm = _G.WorldMapFrame
    if not wm or not self.points then
        return
    end
    local target = self:BestMap()
    if not wm:IsShown() then
        if type(ToggleWorldMap) == "function" then
            pcall(ToggleWorldMap)
        else
            pcall(wm.Show, wm)
        end
    end
    if target and wm.SetMapID and target ~= CurrentMapID() then
        pcall(wm.SetMapID, wm, target)
    end
    self:Refresh()
    return target
end

-- points: Liste { m, x, y, n, name, pin }, label: Text fuers Knoepfchen auf der Karte
function Overlay:Show(points, label, path, pathMap)
    if not points or #points == 0 then
        FW:Print(FW.L.CODEX_MAP_NONE)
        return false
    end
    self.route = nil      -- eine andere Anzeige beendet die laufende Quest-Route
    self.points = points
    self.label = label
    self.path = path
    self.pathMap = pathMap
    self:Hook()
    self:Refresh()
    self:Focus()
    return true
end

function Overlay:Clear()
    self.route = nil
    self:HideHover()
    self.points = nil
    self.label = nil
    self.path = nil
    self.pathMap = nil
    self.bins = nil
    self:Refresh()
end

------------------------------------------------------------------------
-- Laufende Quest-Route: folgt dir, solange die Karte offen ist
------------------------------------------------------------------------

local ROUTE_MOVE = 0.005     -- Bewegung (Anteil der Kartenbreite), ab der neu gerechnet wird
local ROUTE_ARRIVE = 0.015   -- so nah dran gilt die Station als erreicht
local ROUTE_TICK = 1         -- Sekunden zwischen zwei Pruefungen
local routeGen = 0

-- Status der Stationen der aktuellen Route; aendert er sich (Quest angenommen), wird neu gerechnet
local function RouteSignature(points)
    local t = {}
    for i, p in ipairs(points or {}) do
        t[i] = Codex.QuestStatus(p.id) and "x" or "o"
    end
    return table.concat(t)
end

local function PlayerLoc()
    local loc = FW.Util.GetPlayerLocation()
    if loc and loc.mapID and loc.x and loc.y then return loc end
    return nil
end

-- Reihenfolge und Linie neu rechnen (billig: die Positionen der Quests stehen schon in r.cands).
-- Rueckgabe: false, wenn keine Station mehr uebrig ist
function Overlay:RouteRecompute(first)
    local r = self.route
    if not r then return false end
    local loc = PlayerLoc()
    local ax, ay = Codex.PlayerPosOn(r.mapID, loc)
    if ax then
        for _, p in ipairs(r.points or {}) do
            if p.m == r.mapID and (p.x - ax) ^ 2 + (p.y - ay) ^ 2 < ROUTE_ARRIVE ^ 2 then
                r.skip[p.id] = true
            end
        end
    end
    -- nur Quests, die noch offen sind (nicht angenommen, nicht abgegeben) und nicht schon erreicht wurden
    local live = {}
    for _, c in ipairs(r.cands) do
        if not r.skip[c.id] and Codex.QuestStatus(c.id) == nil then live[#live + 1] = c end
    end
    r.cands = live
    local points, mapID, path = Codex.QuestRouteOrder(live, loc)
    if #points == 0 then
        -- nichts mehr uebrig: Ende; sonst nur nichts in der Naehe (anderes Gebiet): alte Anzeige behalten
        if #live == 0 then self:Clear() end
        r.last = loc and { m = loc.mapID, x = loc.x, y = loc.y } or nil
        return false
    end
    local mapChanged = r.mapID ~= mapID
    self.points, self.path, self.pathMap = points, path, mapID
    self.label = string.format(FW.L.CODEX_ROUTE_LABEL, #points)
    self.bins = nil
    r.points, r.mapID, r.sig = points, mapID, RouteSignature(points)
    r.last = loc and { m = loc.mapID, x = loc.x, y = loc.y } or nil
    local wm = _G.WorldMapFrame
    if mapChanged and not first and wm and wm.IsShown and wm:IsShown() and wm.SetMapID then
        pcall(wm.SetMapID, wm, mapID)
    end
    self:Refresh()
    return true
end

-- Eine Pruefung: neu rechnen, wenn du dich bewegt hast oder sich eine Quest geaendert hat
function Overlay:RouteStep()
    local r = self.route
    if not r then return false end
    local wm = _G.WorldMapFrame
    if wm and wm.IsShown and not wm:IsShown() then return false end
    local loc = PlayerLoc()
    local changed = RouteSignature(r.points) ~= r.sig
    if not changed and loc then
        local last = r.last
        changed = not last or last.m ~= loc.mapID or (loc.x - last.x) ^ 2 + (loc.y - last.y) ^ 2 > ROUTE_MOVE ^ 2
    end
    if changed then return self:RouteRecompute(false) end
    return false
end

local function RouteTick(gen)
    local r = Overlay.route
    if not r or r.gen ~= gen then return end
    Overlay:RouteStep()
    if Overlay.route and Overlay.route.gen == gen and _G.C_Timer then
        _G.C_Timer.After(ROUTE_TICK, function() RouteTick(gen) end)
    end
end

-- ids: Quest-IDs der Liste. Zeigt die Route und haelt sie danach aktuell.
function Overlay:StartRoute(ids, opts)
    local loc = PlayerLoc()
    local cands = Codex.QuestRouteCandidates(ids, opts)
    local points, mapID, path = Codex.QuestRouteOrder(cands, loc)
    if #points == 0 then
        FW:Print(FW.L.CODEX_ROUTE_NONE)
        return false
    end
    self:Show(points, string.format(FW.L.CODEX_ROUTE_LABEL, #points), path, mapID)
    routeGen = routeGen + 1
    self.route = { cands = cands, skip = {}, points = points, mapID = mapID, gen = routeGen,
        sig = RouteSignature(points), last = loc and { m = loc.mapID, x = loc.x, y = loc.y } or nil }
    if _G.C_Timer then
        _G.C_Timer.After(ROUTE_TICK, function() RouteTick(routeGen) end)
    end
    return true
end

FW:RegisterEvent("ADDON_LOADED", function(_, name)
    if name == "Blizzard_WorldMap" then
        Overlay:Hook()
        Overlay:Refresh()
    end
end, Overlay)

-- Diagnose: /fwcodex map
function Overlay:Debug()
    local canvas = Canvas()
    local d = self.lastDraw
    FW:Print("Karte: " .. tostring(CurrentMapID()) .. ", Flaeche " .. tostring(canvas and canvas:GetWidth()) .. " x "
        .. tostring(canvas and canvas:GetHeight()) .. ", Ebene " .. tostring(canvas and canvas:GetFrameLevel())
        .. ", Overlay-Ebene " .. tostring(layer and layer:GetFrameLevel()))
    FW:Print("Punkte geladen: " .. tostring(self.points and #self.points or 0) .. ", gezeichnet: " .. tostring(d and d.dots)
        .. ", Maske: " .. tostring(MaskAvailable()) .. ", Skalierung: " .. string.format("%.2f", self:CanvasScale()))
    local wm = _G.WorldMapFrame
    FW:Print("Kartenfenster sichtbar: " .. tostring(wm and wm:IsShown()) .. ", Kartenflaeche sichtbar: " .. tostring(canvas and canvas:IsVisible())
        .. ", Punkte-Ebene sichtbar: " .. tostring(layer and layer:IsVisible()) .. ", Ebenen-Skalierung: " .. string.format("%.2f", LayerScale()))
    local first = dots and dots[1]
    if first then
        FW:Print("Erster Punkt: sichtbar " .. tostring(first.fill:IsVisible()) .. ", Grösse " .. tostring(first.fill:GetWidth())
            .. ", Ebene der Ebene sichtbar " .. tostring(layer and layer:IsVisible()))
    end
end

-- Test: grosser roter Kasten in der Kartenmitte, zeigt ob ueberhaupt gezeichnet wird
function Overlay:Test()
    local f = EnsureLayer()
    if not f then
        FW:Print("Weltkarte nicht gefunden.")
        return
    end
    if not f.testTex then
        f.testTex = f:CreateTexture(nil, "OVERLAY")
        f.testTex:SetColorTexture(1, 0.1, 0.1, 0.6)
        f.testTex:SetSize(160, 160)
        f.testTex:SetPoint("CENTER", f, "CENTER", 0, 0)
    end
    if f.testTex:IsShown() then
        f.testTex:Hide()
    else
        f.testTex:Show()
    end
end

-- /fwcodex map square: Punkte als Quadrate (falls die runde Maske Probleme macht)
function Overlay:ToggleSquare()
    local st = Codex.db.settings
    st.squareDots = not st.squareDots
    for _, d in ipairs(dots or {}) do
        HideDot(d)
    end
    dots = {}
    FW:Print("Codex-Karte: " .. (st.squareDots and "Quadrate" or "runde Punkte"))
    self:Refresh()
end
