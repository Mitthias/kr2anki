--[[--
Tools ▸ KR2Anki: KOReader's standard menu items (no custom settings screen).
The manager's "Settings" row opens the same items in a stand-alone menu.
--]]

local Lang = require("kr2anki/lang")
local N = require("kr2anki/notetypes")
local Safe = require("kr2anki/safe")
local _ = require("gettext")
local T = require("ffi/util").template

local M = {}

local function UIManager() return require("ui/uimanager") end

local function info(text)
    local InfoMessage = require("ui/widget/infomessage")
    UIManager():show(InfoMessage:new{ text = text })
end

local function inputNumber(title, value, on_ok)
    local InputDialog = require("ui/widget/inputdialog")
    local dialog
    dialog = InputDialog:new{
        title = title,
        input = tostring(value),
        input_type = "number",
        buttons = { {
            { text = _("Cancel"), id = "close", callback = function() UIManager():close(dialog) end },
            { text = _("Save"), is_enter_default = true, callback = function()
                local v = tonumber(dialog:getInputText())
                UIManager():close(dialog)
                if v then on_ok(v) end
            end },
        } },
    }
    UIManager():show(dialog)
    dialog:onShowKeyboard()
end

local function inputText(title, value, on_ok, hint)
    local InputDialog = require("ui/widget/inputdialog")
    local dialog
    dialog = InputDialog:new{
        title = title,
        input = value or "",
        input_hint = hint,
        buttons = { {
            { text = _("Cancel"), id = "close", callback = function() UIManager():close(dialog) end },
            { text = _("Save"), is_enter_default = true, callback = function()
                local v = dialog:getInputText()
                UIManager():close(dialog)
                on_ok(v)
            end },
        } },
    }
    UIManager():show(dialog)
    dialog:onShowKeyboard()
end
M.inputText = inputText

-- Language choices: full support first, then "Other…"
local function languageItems(current_func, on_pick, with_auto)
    local items = {}
    if with_auto then
        items[#items + 1] = {
            text = _("Detect automatically"),
            radio = true,
            checked_func = function() return current_func() == nil end,
            callback = function() on_pick(nil) end,
            separator = true,
        }
    end
    for __, code in ipairs({ "en", "zh", "ja", "ko" }) do
        items[#items + 1] = {
            text = Lang.name(code),
            radio = true,
            checked_func = function() return current_func() == code end,
            callback = function() on_pick(code) end,
        }
    end
    items[#items + 1] = {
        text_func = function()
            local c = current_func()
            if c and not Lang.isFull(c) then return T(_("Other: %1"), Lang.name(c)) end
            return _("Other…")
        end,
        checked_func = function() local c = current_func() return c ~= nil and not Lang.isFull(c) end,
        callback = function(touchmenu)
            inputText(_("Language code (e.g. fr, de, es)"), current_func() or "", function(v)
                on_pick(Lang.normalize(v))
                if touchmenu then touchmenu:updateItems() end
            end)
        end,
    }
    return items
end

local function statusText(host)
    local caps = host.settings:get("caps")
    if not caps then return _("Status: not checked") end
    local when = caps.checked_at and os.date("%Y-%m-%d %H:%M", caps.checked_at) or "?"
    return T(_("Status: last checked %1"), when)
end

function M.connectionItems(host)
    local s = host.settings
    return {
        {
            text_func = function() return statusText(host) end,
            keep_menu_open = true,
            callback = function(touchmenu)
                Safe.run("connection", function()
                    local ok, version = host:ping()
                    info(ok and T(_("● Connected · AnkiConnect version %1"), tostring(version))
                        or _("○ Not reachable.\n\nOpen AnkiConnect Android on the phone app list once, then try again."))
                end)
                if touchmenu then touchmenu:updateItems() end
            end,
        },
        {
            text = _("Test connection"),
            keep_menu_open = true,
            callback = function() host:showDiagnostics(true) end,
        },
        {
            text = _("Setup wizard"),
            callback = function() host:openWizard() end,
        },
        {
            text = _("Diagnostics"),
            keep_menu_open = true,
            callback = function() host:showDiagnostics(false) end,
            separator = true,
        },
        {
            text_func = function() return T(_("Deck name pattern: %1"), s:get("deck_pattern")) end,
            keep_menu_open = true,
            help_text = _("{Language} becomes the language name, e.g. Reading::Japanese."),
            callback = function(touchmenu)
                inputText(_("Deck name pattern"), s:get("deck_pattern"), function(v)
                    v = v and v:gsub("^%s+", ""):gsub("%s+$", "") or ""
                    s:set("deck_pattern", v ~= "" and v or "Reading::{Language}")
                    if touchmenu then touchmenu:updateItems() end
                end, "Reading::{Language}")
            end,
        },
    }
end

function M.cardItems(host)
    local s = host.settings
    local items = {}
    for __, c in ipairs(N.CARD_SETTINGS) do
        items[#items + 1] = {
            text = _(c.text),
            help_text = _(c.sub) .. "\n\n" .. _("Applies to future exports only."),
            checked_func = function() return s:cards()[c.key] end,
            callback = function() s:setCard(c.key, not s:cards()[c.key]) end,
        }
    end
    items[#items].separator = true
    items[#items + 1] = {
        text_func = function()
            return T(_("Japanese readings: %1"), s:get("ja_readings") == "off" and _("Off") or _("Furigana"))
        end,
        sub_item_table = {
            { text = _("Furigana"), radio = true, checked_func = function() return s:get("ja_readings") ~= "off" end,
              callback = function() s:set("ja_readings", "furigana") end },
            { text = _("Off"), radio = true, checked_func = function() return s:get("ja_readings") == "off" end,
              callback = function() s:set("ja_readings", "off") end },
        },
    }
    items[#items + 1] = {
        text = _("Korean romanization in Reading"),
        checked_func = function() return s:get("ko_romanize") end,
        callback = function() s:toggle("ko_romanize") end,
    }
    return items
end

function M.captureItems(host)
    local s = host.settings
    return {
        {
            text = _("Close popup after saving"),
            checked_func = function() return s:get("close_popup_after_save") end,
            callback = function() s:toggle("close_popup_after_save") end,
        },
        {
            text = _("Require review before export"),
            help_text = _("Only Ready items are exported. Export still offers to send Inbox items as they are."),
            checked_func = function() return s:get("require_review") end,
            callback = function() s:toggle("require_review") end,
        },
        {
            text = _("Allow empty Meaning on expressions"),
            help_text = _("Expressions can be marked Ready and exported without a Meaning; fill it in AnkiDroid."),
            checked_func = function() return s:get("allow_empty_meaning") end,
            callback = function() s:toggle("allow_empty_meaning") end,
        },
        {
            text_func = function() return T(_("Inbox nudge threshold: %1"), s:get("nudge_threshold")) end,
            keep_menu_open = true,
            callback = function(touchmenu)
                inputNumber(_("Show the review banner when the Inbox holds"), s:get("nudge_threshold"), function(v)
                    s:set("nudge_threshold", math.max(1, math.floor(v)))
                    if touchmenu then touchmenu:updateItems() end
                end)
            end,
        },
        {
            text = _("Close-book prompt"),
            help_text = _("When you close a book after saving words, offer to review them."),
            checked_func = function() return s:get("close_book_prompt") end,
            callback = function() s:toggle("close_book_prompt") end,
        },
    }
end

function M.languageItems(host)
    local items = {}
    local Capture = require("kr2anki/capture")
    local book = host.ui and host.ui.document and Capture.bookInfo(host.ui)
    if book then
        items[#items + 1] = {
            text_func = function()
                local o = host:bookOverride(book)
                return T(_("This book: %1"), o and Lang.name(o) or T(_("detected (%1)"), Lang.name(book.language)))
            end,
            sub_item_table_func = function()
                return languageItems(function() return host:bookOverride(book) end,
                    function(code) host:setBookOverride(book, code) end, true)
            end,
            separator = true,
        }
    end
    items[#items + 1] = {
        text = _("Language per book"),
        sub_item_table_func = function()
            local store = host:getStore()
            local out = {}
            for __, b in ipairs(store and store:allBooks() or {}) do
                out[#out + 1] = {
                    text_func = function()
                        local row = store:book(b.id)
                        local o = row and row.language_override
                        return T("%1 · %2", b.title or "?", o and Lang.name(o) or T(_("detected (%1)"), Lang.name(b.language)))
                    end,
                    sub_item_table_func = function()
                        return languageItems(function()
                            local row = store:book(b.id)
                            return row and row.language_override
                        end, function(code)
                            store:setBookLanguageOverride(b.id, code)
                            host._overrides = nil
                        end, true)
                    end,
                }
            end
            if #out == 0 then out[1] = { text = _("No books yet"), enabled = false } end
            return out
        end,
    }
    items[#items + 1] = {
        text = _("Language per dictionary"),
        sub_item_table_func = function()
            local di = host:getDictInfo()
            local out = {}
            for __, d in ipairs(di.dicts) do
                out[#out + 1] = {
                    text_func = function()
                        local code, how = di:language(d.name)
                        return T("%1 · %2", d.name, code and (Lang.name(code) .. (how == "chosen" and "" or " (.ifo)")) or _("unknown"))
                    end,
                    sub_item_table_func = function()
                        return languageItems(function() return host.settings:mapGet("dict_languages", d.name) end,
                            function(code) host.settings:mapSet("dict_languages", d.name, code) end, true)
                    end,
                }
            end
            if #out == 0 then out[1] = { text = _("No StarDict dictionaries found"), enabled = false } end
            return out
        end,
    }
    return items
end

function M.profileItems(host)
    local items = {}
    items[#items + 1] = {
        text = _("Test on a word"),
        keep_menu_open = true,
        callback = function()
            inputText(_("Word to look up"), "", function(word)
                Safe.run("test profile", M.testProfile, host, word)
            end)
        end,
        separator = true,
    }
    local di = host:getDictInfo()
    for __, d in ipairs(di.dicts) do
        items[#items + 1] = {
            text_func = function()
                local p, how = di:profileFor(d.name)
                return T("%1 · %2%3", d.name, p.name, how == "chosen" and "" or _(" (auto)"))
            end,
            sub_item_table_func = function()
                local out = {
                    {
                        text = _("Match automatically"),
                        radio = true,
                        checked_func = function() return host.settings:mapGet("dict_profiles", d.name) == nil end,
                        callback = function() host.settings:mapSet("dict_profiles", d.name, nil) end,
                        separator = true,
                    },
                }
                for __, p in ipairs(di.profiles) do
                    out[#out + 1] = {
                        text = p.name,
                        help_text = p.description,
                        radio = true,
                        checked_func = function() return host.settings:mapGet("dict_profiles", d.name) == p.id end,
                        callback = function() host.settings:mapSet("dict_profiles", d.name, p.id) end,
                    }
                end
                return out
            end,
        }
    end
    if #di.dicts == 0 then items[#items + 1] = { text = _("No StarDict dictionaries found"), enabled = false } end
    if #di.profile_errors > 0 then
        items[#items + 1] = {
            text = T(_("%1 profile files failed to load"), #di.profile_errors),
            callback = function() info(table.concat(di.profile_errors, "\n\n")) end,
        }
    end
    return items
end

-- Look a word up in every dictionary and show what each profile extracts.
function M.testProfile(host, word)
    local Capture = require("kr2anki/capture")
    local results = Capture.silentLookup(host, word)
    local di = host:getDictInfo()
    local out = {}
    if #results == 0 then out[1] = T(_("No dictionary has %1."), word) end
    for __, r in ipairs(results) do
        local parsed, profile = di:parse(r)
        out[#out + 1] = T("━━ %1 · profile: %2", r.dict, profile.name)
        out[#out + 1] = T(_("Headword: %1"), r.word)
        out[#out + 1] = T(_("Reading: %1"), parsed.reading or "—")
        out[#out + 1] = T(_("Part of speech: %1"), parsed.pos or "—")
        for i, sense in ipairs(parsed.senses) do
            out[#out + 1] = T("%1. %2%3", i, sense.text, sense.pos and (" [" .. sense.pos .. "]") or "")
        end
        for __, e in ipairs(parsed.examples) do out[#out + 1] = T(_("Example: %1"), e) end
        for __, n in ipairs(parsed.notes) do out[#out + 1] = T(_("Note: %1"), n) end
        if parsed.audio then out[#out + 1] = T(_("Audio: %1"), parsed.audio) end
        out[#out + 1] = ""
    end
    local TextViewer = require("ui/widget/textviewer")
    UIManager():show(TextViewer:new{ title = T(_("Profiles · %1"), word), text = table.concat(out, "\n") })
end

function M.dataItems(host)
    return {
        {
            text = _("Import from Vocabulary Builder"),
            callback = function() Safe.run("import", require("kr2anki/vbimport").start, host) end,
        },
        {
            text = _("Save as Anki package (.apkg)"),
            callback = function() Safe.run("package", require("kr2anki/screens/export").packageFlow, host) end,
        },
        {
            text = _("Write note-type package"),
            help_text = _("kr2anki_notetypes.apkg installs both note types in AnkiDroid when AnkiConnect cannot create them."),
            callback = function() Safe.run("note types", require("kr2anki/screens/export").writeNotetypePackage, host, true) end,
            separator = true,
        },
        {
            text = _("Hide the built-in Vocabulary Builder button"),
            callback = function()
                info(_("KR2Anki and the built-in Vocabulary Builder both add a button to the dictionary popup. To keep only ★ Save:\n\n1. Look up any word.\n2. In the popup, open the menu (☰ or long-press the title) ▸ Dictionary settings ▸ Customize buttons.\n3. Untick \"Vocabulary builder\".\n\nKR2Anki never changes the Vocabulary Builder's settings or data. Its words can be imported here with \"Import from Vocabulary Builder\"."))
            end,
        },
    }
end

-- All settings groups (shared by the Tools menu and the manager's Settings row).
function M.settingsItems(host)
    return {
        { text = _("Anki connection"), sub_item_table_func = function() return M.connectionItems(host) end },
        { text = _("Cards"), sub_item_table_func = function() return M.cardItems(host) end },
        { text = _("Capture"), sub_item_table_func = function() return M.captureItems(host) end },
        { text = _("Languages"), sub_item_table_func = function() return M.languageItems(host) end },
        { text = _("Dictionary profiles"), sub_item_table_func = function() return M.profileItems(host) end },
        { text = _("Data"), sub_item_table_func = function() return M.dataItems(host) end },
    }
end

function M.build(host)
    local items = {
        { text = _("Open KR2Anki"), callback = function() Safe.run("open", host.openManager, host) end },
        { text = _("Start review"), callback = function() Safe.run("review", host.openReview, host) end },
        { text = _("Export to Anki"), callback = function() Safe.run("export", host.openExport, host) end, separator = true },
    }
    for __, it in ipairs(M.settingsItems(host)) do items[#items + 1] = it end
    return {
        text = _("KR2Anki"),
        sorting_hint = "tools",
        sub_item_table = items,
    }
end

-- Stand-alone menu with the settings groups (from the manager screen).
function M.showSettings(host, on_close)
    local CenterContainer = require("ui/widget/container/centercontainer")
    local TouchMenu = require("ui/widget/touchmenu")
    local Screen = require("device").screen
    local container = CenterContainer:new{
        covers_header = true,
        ignore = "height",
        dimen = Screen:getSize(),
    }
    local items = M.settingsItems(host)
    items.icon = "appbar.settings"
    local menu = TouchMenu:new{
        width = Screen:getWidth(),
        tab_item_table = { items },
        show_parent = container,
    }
    container[1] = menu
    menu.close_callback = function()
        UIManager():close(container)
        if on_close then on_close() end
    end
    UIManager():show(container)
end

return M
