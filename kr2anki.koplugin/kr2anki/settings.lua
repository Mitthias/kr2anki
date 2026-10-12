--[[--
Plugin settings (KOReader's settings/kr2anki.lua) with defaults.
Per-book language overrides live in the database (books.language_override).
--]]

local N = require("kr2anki/notetypes")

local Settings = {}
Settings.__index = Settings

Settings.DEFAULTS = {
    deck_pattern = "Reading::{Language}",
    ja_readings = "furigana",          -- "furigana" | "off"
    ko_romanize = false,
    close_popup_after_save = false,
    require_review = true,             -- only Ready items export; "send as-is" in Export
    allow_empty_meaning = true,
    nudge_threshold = 20,
    close_book_prompt = false,
    check_other_notetypes = true,
    browse_sort = "newest",            -- "newest" | "az"
}

-- store: anything with readSetting/saveSetting/flush (LuaSettings)
function Settings.new(store)
    return setmetatable({ store = store }, Settings)
end

function Settings:get(key)
    local v = self.store:readSetting(key)
    if v == nil then return Settings.DEFAULTS[key] end
    return v
end

function Settings:set(key, value)
    self.store:saveSetting(key, value)
    self.store:flush()
end

function Settings:toggle(key)
    self:set(key, not self:get(key))
end

function Settings:cards()
    local saved = self.store:readSetting("cards") or {}
    local out = N.defaultCards()
    for k, v in pairs(saved) do out[k] = v end
    return out
end

function Settings:setCard(key, on)
    local cards = self:cards()
    cards[key] = on
    self:set("cards", cards)
end

-- Per-dictionary maps: dict_languages[name] = code, dict_profiles[name] = id
function Settings:mapGet(map, key)
    local t = self.store:readSetting(map) or {}
    return t[key]
end

function Settings:mapSet(map, key, value)
    local t = self.store:readSetting(map) or {}
    t[key] = value
    self:set(map, t)
end

-- Options for building notes.
function Settings:exportOptions()
    return {
        deck_pattern = self:get("deck_pattern"),
        cards = self:cards(),
        ja_furigana = self:get("ja_readings") ~= "off",
        ko_romanize = self:get("ko_romanize"),
        check_other_notetypes = self:get("check_other_notetypes"),
    }
end

return Settings
