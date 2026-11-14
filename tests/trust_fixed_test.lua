-- Test: feste Eigentuemer und Moderatoren (CodexOwners.lua, CodexTrust.lua)   texlua tests/trust_fixed_test.lua
_G.Freewood = setmetatable({ L = setmetatable({}, { __index = function(_, k) return k end }) },
    { __index = function() return function() end end })
_G.GetRealmName = function() return "ClassicBetaPvP2" end
_G.GetNormalizedRealmName = function() return "ClassicBetaPvP2" end
_G.SlashCmdList = {}
_G.CreateFrame = function() return setmetatable({}, { __index = function() return function() end end }) end
local Codex = { db = { trust = { rev = 1, list = {} } }, DevModule = true }
local NS = { Codex = Codex }
assert(loadfile("CodexOwners.lua"))("Freewood-Codex", NS)
assert(loadfile("CodexTrust.lua"))("Freewood-Codex", NS)
local Trust = Codex.Trust
assert(Trust.RoleOf("Aroki Silberrücken") == "owner", "Aroki Silberrücken ist Owner")
assert(Trust.RoleOf("Aroki Silberrücken-ClassicBetaPvP2") == "owner", "mit Realm")
assert(Trust.RoleOf("Aroki Steel") == "owner", "bisherige Owner bleiben")
assert(Trust.RoleOf("Jinxer Darktide") == "moderator", "Jinxer Darktide fester Moderator")
assert(Trust.RoleOf("jinxer darktide") == "moderator", "Gross-/Kleinschreibung egal")
assert(Trust.IsFixedModerator("Jinxer Darktide"))
assert(Trust.IsDev("Jinxer Darktide"))
assert(Trust.RoleOf("Jinxer Fremd") == nil, "andere nicht")
-- ausdruecklich gesperrt schlaegt fest eingetragen
Codex.db.trust.list[Trust.EntryKey("Jinxer Darktide")] = { role = "blocked" }
assert(Trust.RoleOf("Jinxer Darktide") == "blocked", "Sperre gilt")
print("trust_fixed_test OK")
