-- Freewood-Codex: Abschnitt "Datenbank teilen" in den Einstellungen

local ADDON, NS = ...

local FW = _G.Freewood
local Codex = NS and NS.Codex
local Sync = NS and NS.Sync
local Share = NS and NS.Share
if not FW or not Codex or not Sync or not Share or not FW.UI or not FW.UI.RegisterSettingsSection then
    return
end

local UI = FW.UI

local function Build(parent)
    local L = FW.L
    local f, stack = UI.CreateSection(parent, L.CODEX_SHARE_HEADER)

    local note = UI.CreateLabel(f, L.CODEX_SHARE_NOTE, { size = 11, color = "textDim", justifyV = "TOP" })
    stack:Add(note, { fit = true, gap = 8 })

    local box = UI.CreateCheckbox(f, L.CODEX_SHARE_SWITCH, function()
        return Sync:IsEnabled()
    end, function(on)
        Sync:SetEnabled(on)
    end)
    stack:Add(box, { fit = true, gap = 10 })
    UI.AttachTooltip(box, function() return L.CODEX_SHARE_SWITCH end, function() return L.CODEX_SHARE_SWITCH_TIP end)

    local callButton = UI.CreateButton(f, L.CODEX_SHARE_NOW, 200, 26, function()
        if Sync:IsEnabled() then
            Share.Scan(true)
            Sync:SendHello()
        end
    end, "default")
    stack:Add(callButton, { height = 26, gap = 12 })

    local clearButton
    local armed = false
    clearButton = UI.CreateButton(f, L.CODEX_SHARE_CLEAR, 240, 26, function()
        if not armed then
            armed = true
            clearButton:SetLabel(L.CODEX_SHARE_CLEAR_SURE)
            C_Timer.After(5, function()
                armed = false
                clearButton:SetLabel(L.CODEX_SHARE_CLEAR)
            end)
            return
        end
        armed = false
        clearButton:SetLabel(L.CODEX_SHARE_CLEAR)
        local n = Share.ClearRemote()
        FW:Print(string.format(L.CODEX_SHARE_CLEARED, n))
        FW:Fire("CODEX_CHANGED", "import")
        FW:Fire("CODEX_SYNC_CHANGED")
    end, "default")
    stack:Add(clearButton, { height = 26, gap = 8 })

    local status = UI.CreateLabel(f, "", { size = 11, color = "textDim", justifyV = "TOP" })
    stack:Add(status, { fit = true, gap = 10 })

    function f.Refresh()
        box:Refresh()
        local st = Sync:Stats()
        local text = string.format(L.CODEX_SHARE_STATS, st.sent, st.received)
        text = text .. "\n" .. string.format(L.CODEX_SHARE_SOURCES, st.senders, st.records)
        text = text .. "\n" .. string.format(L.CODEX_SHARE_HEARD, st.heard or 0)
        if Sync:IsEnabled() then
            local key = "CODEX_SHARE_GLOBAL_" .. string.upper(st.global or "off")
            text = text .. "\n" .. (L[key] or L.CODEX_SHARE_GLOBAL_OFF)
        end
        status:SetText(text)
        stack:Layout()
    end

    FW:On("CODEX_SYNC_CHANGED", function()
        if f:IsVisible() then
            f.Refresh()
        end
    end, f)

    stack:Layout()
    return f
end

UI:RegisterSettingsSection("codex-share", {
    category = "database",
    order = 105,
    height = 360,
    build = Build,
    refresh = function(frame)
        frame.Refresh()
    end,
})
