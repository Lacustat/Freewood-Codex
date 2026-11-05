-- Freewood-Codex: Favoriten und Notizen sichern / uebertragen (Export und Import als Text)

local ADDON, NS = ...

local FW = _G.Freewood
local Codex = NS.Codex
if not FW or not Codex or not FW.UI then
    return
end

local UI = FW.UI
local FavUI = {}
NS.FavUI = FavUI
Codex.FavUI = FavUI

local win

local function Build()
    local L = FW.L
    local w = UI.CreatePanel(UIParent, "bg", "gold")
    w:SetSize(520, 190)
    w:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    w:SetFrameStrata("DIALOG")
    w:EnableMouse(true)
    w:Hide()

    local title = UI.CreateLabel(w, L.CODEX_FAVX_TITLE, { font = "heading", size = 14, color = "goldLight" })
    title:SetPoint("TOPLEFT", w, "TOPLEFT", 16, -14)
    local note = UI.CreateLabel(w, L.CODEX_FAVX_NOTE, { size = 11, color = "textDim", justifyV = "TOP" })
    note:SetPoint("TOPLEFT", w, "TOPLEFT", 16, -40)
    note:SetPoint("TOPRIGHT", w, "TOPRIGHT", -16, -40)
    note:SetHeight(44)
    note:SetWordWrap(true)

    local box = UI.CreatePanel(w, "bgDeep", "bronze")
    box:SetHeight(26)
    box:SetPoint("TOPLEFT", w, "TOPLEFT", 16, -92)
    box:SetPoint("TOPRIGHT", w, "TOPRIGHT", -16, -92)
    local edit = CreateFrame("EditBox", nil, box)
    edit:SetAutoFocus(false)
    edit:SetPoint("TOPLEFT", box, "TOPLEFT", 8, -2)
    edit:SetPoint("BOTTOMRIGHT", box, "BOTTOMRIGHT", -8, 2)
    edit:SetMaxLetters(0)
    if not edit:SetFont(UI.GetFontPath("body"), 12, "") then
        edit:SetFont("Fonts\\FRIZQT__.TTF", 12, "")
    end
    edit:SetTextColor(UI.Color("text"))
    edit:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    w.edit = edit

    local status = UI.CreateLabel(w, "", { size = 11, color = "textDim" })
    status:SetPoint("TOPLEFT", w, "TOPLEFT", 16, -126)
    status:SetPoint("TOPRIGHT", w, "TOPRIGHT", -16, -126)
    w.status = status

    local export = UI.CreateButton(w, L.CODEX_FAVX_EXPORT, 150, 26, function()
        local text, n = Codex.FavExport()
        edit:SetText(text)
        edit:SetFocus()
        edit:HighlightText()
        status:SetText(string.format(L.CODEX_FAVX_EXPORTED, n))
    end, "default")
    export:SetPoint("BOTTOMLEFT", w, "BOTTOMLEFT", 16, 14)
    local import = UI.CreateButton(w, L.CODEX_FAVX_IMPORT, 150, 26, function()
        local added, notes, bad = Codex.FavImport(edit:GetText())
        if not added then
            status:SetText(L.CODEX_FAVX_BAD)
            return
        end
        status:SetText(string.format(L.CODEX_FAVX_IMPORTED, added, notes, bad))
        FW:Fire("CODEX_CHANGED", "import")
    end, "primary")
    import:SetPoint("LEFT", export, "RIGHT", 8, 0)
    local close = UI.CreateButton(w, L.CODEX_FAVX_CLOSE, 100, 26, function() w:Hide() end, "default")
    close:SetPoint("BOTTOMRIGHT", w, "BOTTOMRIGHT", -16, 14)
    w.exportButton, w.importButton = export, import
    return w
end

function FavUI.Open()
    win = win or Build()
    win.status:SetText("")
    win:Show()
    return win
end

if UI.RegisterSettingsSection then
    UI:RegisterSettingsSection("codex-fav", {
        category = "database",
        order = 107,
        height = 110,
        build = function(parent)
            local L = FW.L
            local f, stack = UI.CreateSection(parent, L.CODEX_FAVX_HEADER)
            local note = UI.CreateLabel(f, L.CODEX_FAVX_SECTION_NOTE, { size = 11, color = "textDim", justifyV = "TOP" })
            stack:Add(note, { fit = true, gap = 8 })
            local open = UI.CreateButton(f, L.CODEX_FAVX_OPEN, 240, 26, function() FavUI.Open() end, "default")
            stack:Add(open, { height = 26, gap = 10 })
            stack:Layout()
            return f
        end,
        refresh = function() end,
    })
end
