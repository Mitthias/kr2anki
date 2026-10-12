--[[--
KR2Anki: save dictionary lookups while reading, review them, export them to
AnkiDroid through AnkiConnect Android (or as an .apkg file).

Entry points
* Dictionary popup: "★ Save" row
* Text-selection menu: "★ Save word", "◆ Save as expression"
* Tools ▸ KR2Anki, and gesture actions "KR2Anki: Open manager / Start review / Export"

Every KOReader interface used is checked at startup; a missing one is logged
and listed under Settings ▸ Anki connection ▸ Diagnostics instead of crashing.

@module koplugin.kr2anki
--]]

local DataStorage = require("datastorage")
local Dispatcher = require("dispatcher")
local LuaSettings = require("luasettings")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local _ = require("gettext")
local T = require("ffi/util").template

local Safe = require("kr2anki/safe")
local Settings = require("kr2anki/settings")

local KR2Anki = WidgetContainer:extend{
    name = "kr2anki",
    is_doc_only = false,
}

function KR2Anki:init()
    self.settings = Settings.new(LuaSettings:open(DataStorage:getSettingsDir() .. "/kr2anki.lua"))
    self.session = { word = 0, expression = 0 }
    self:checkHooks()
    if self.ui and self.ui.menu then
        Safe.run("menu", function() self.ui.menu:registerToMainMenu(self) end)
    end
    local Capture = require("kr2anki/capture")
    if self.ui and self.ui.dictionary then
        Safe.run("dictionary button", Capture.registerDictButton, self)
    end
    if self.ui and self.ui.highlight then
        Safe.run("selection menu", Capture.registerHighlightButtons, self)
    end
    Safe.run("gesture actions", self.onDispatcherRegisterActions, self)
end

-- Interface check ---------------------------------------------------------------

local function has(t, key)
    return type(t) == "table" and type(t[key]) == "function"
end

function KR2Anki:checkHooks()
    local ui = self.ui or {}
    local checks = {
        { "ReaderMenu:registerToMainMenu", has(ui.menu, "registerToMainMenu") },
        { "Dispatcher:registerAction", has(Dispatcher, "registerAction") },
    }
    if ui.document then
        -- reader only
        checks[#checks + 1] = { "ReaderDictionary:addToDictButtons", has(ui.dictionary, "addToDictButtons") }
        checks[#checks + 1] = { "ReaderDictionary:startSdcv", has(ui.dictionary, "startSdcv") }
        checks[#checks + 1] = { "ReaderHighlight:addToHighlightDialog", has(ui.highlight, "addToHighlightDialog") }
        checks[#checks + 1] = { "ReaderHighlight:getSelectedWordContext", has(ui.highlight, "getSelectedWordContext") }
    end
    checks[#checks + 1] = { "lua-ljsqlite3", (pcall(require, "lua-ljsqlite3/init")) }
    checks[#checks + 1] = { "rapidjson", (pcall(require, "rapidjson")) }
    checks[#checks + 1] = { "socket.http", (pcall(require, "socket.http")) }
    checks[#checks + 1] = { "ffi/archiver (zip)", (function()
        local ok, A = pcall(require, "ffi/archiver")
        return ok and type(A) == "table" and A.Writer ~= nil
    end)() }
    self.hook_status = checks
    for __, c in ipairs(checks) do
        if not c[2] then logger.warn("KR2Anki: KOReader interface missing:", c[1]) end
    end
end

-- Shared services -----------------------------------------------------------------

function KR2Anki:jsonCodec()
    if not self._json then
        local ok, rapidjson = pcall(require, "rapidjson")
        if ok then
            self._json = rapidjson
        else
            -- luajson as a fallback (null sentinel, no array marker)
            local JSON = require("json")
            self._json = { encode = JSON.encode, decode = JSON.decode, null = JSON.util and JSON.util.null,
                           array = function(t) return t end }
        end
    end
    return self._json
end

-- Opened lazily, so a database problem never blocks KOReader from starting.
function KR2Anki:getStore()
    if not self.store then
        local ok, res = pcall(function()
            return require("kr2anki/db").new(DataStorage:getSettingsDir() .. "/kr2anki.sqlite3", { json = self:jsonCodec() })
        end)
        if not ok then
            logger.err("KR2Anki: cannot open database", res)
            Safe.message(T(_("KR2Anki could not open its database:\n%1"), tostring(res)))
            return nil
        end
        self.store = res
    end
    return self.store
end

function KR2Anki:getDictInfo()
    if not self.dictinfo then
        local dict = self.ui and self.ui.dictionary
        self.dictinfo = require("kr2anki/dictinfo").new{
            data_dir = (dict and dict.data_dir) or (DataStorage:getDataDir() .. "/data/dict"),
            profile_dirs = { self.path .. "/profiles", DataStorage:getSettingsDir() .. "/kr2anki_profiles" },
            settings = self.settings,
        }
    end
    return self.dictinfo
end

function KR2Anki:client(timeout)
    local Anki = require("kr2anki/anki")
    return Anki.new{
        transport = require("kr2anki/http").post,
        json = self:jsonCodec(),
        timeout = timeout,
        log = function(action, status) logger.dbg("KR2Anki: AnkiConnect", action, status) end,
    }
end

-- Capabilities: probed on first connection, cached, re-run from Diagnostics.
function KR2Anki:getCaps(force)
    local caps = self.settings:get("caps")
    local current = caps and caps.probe_version == require("kr2anki/anki").PROBE_VERSION
    if caps and caps.reachable and current and not force then return caps end
    caps = self:client():probe()
    if caps.reachable then
        self.settings:set("caps", caps)
    end
    return caps
end

-- Quick reachability check (home screen status).
function KR2Anki:ping()
    local v, _, kind = self:client(2):call("version")
    return kind == "ok", v
end

function KR2Anki:exportDir()
    return DataStorage:getDataDir() .. "/kr2anki-export"
end

-- Per-book language override (cached per file hash).
function KR2Anki:bookOverride(book)
    if not book or not book.file_hash then return nil end
    self._overrides = self._overrides or {}
    local v = self._overrides[book.file_hash]
    if v == nil then
        local store = self:getStore()
        local row = store and store:bookByHash(book.file_hash)
        v = row and row.language_override or false
        self._overrides[book.file_hash] = v
    end
    return v or nil
end

function KR2Anki:setBookOverride(book, code)
    local store = self:getStore()
    if not (store and book) then return end
    local id = store:upsertBook(book)
    store:setBookLanguageOverride(id, code)
    self._overrides = nil
end

function KR2Anki:noteSessionSave(kind, result)
    if result and result.created then
        self.session[kind] = (self.session[kind] or 0) + 1
    end
end

function KR2Anki:noteSessionUndo(kind, result)
    if result and result.created then
        self.session[kind] = math.max(0, (self.session[kind] or 0) - 1)
    end
end

-- Screens ---------------------------------------------------------------------------

function KR2Anki:getApp()
    if not self.app then
        self.app = require("kr2anki/app").new(self)
    end
    return self.app
end

function KR2Anki:onAppClosed(app)
    if self.app == app then self.app = nil end
end

function KR2Anki:openManager()
    if not self:getStore() then return end
    self:getApp():open("kr2anki/screens/home", {})
end

function KR2Anki:openReview(filter)
    local store = self:getStore()
    if not store then return end
    local ids = store:reviewQueue(filter)
    if #ids == 0 then
        self:getApp():open("kr2anki/screens/items", { filter = { statuses = { inbox = true } }, title = "○ Inbox",
                                                      inbox_view = true })
        return
    end
    self:getApp():open("kr2anki/screens/review", { ids = ids })
end

function KR2Anki:openExport()
    if not self:getStore() then return end
    if not self.settings:get("wizard_seen") then
        self.settings:set("wizard_seen", true)
        self:getApp():open("kr2anki/screens/wizard", { then_export = true })
        return
    end
    self:getApp():open("kr2anki/screens/export", {})
end

function KR2Anki:openWizard()
    if not self:getStore() then return end
    self:getApp():open("kr2anki/screens/wizard", {})
end

function KR2Anki:showDiagnostics(force)
    require("kr2anki/diagnostics").show(self, force)
end

-- Gesture actions -----------------------------------------------------------------

function KR2Anki:onDispatcherRegisterActions()
    Dispatcher:registerAction("kr2anki_open", {
        category = "none", event = "KR2AnkiOpen", title = _("KR2Anki: Open manager"), general = true,
    })
    Dispatcher:registerAction("kr2anki_review", {
        category = "none", event = "KR2AnkiReview", title = _("KR2Anki: Start review"), general = true,
    })
    Dispatcher:registerAction("kr2anki_export", {
        category = "none", event = "KR2AnkiExport", title = _("KR2Anki: Export"), general = true, separator = true,
    })
end

function KR2Anki:onKR2AnkiOpen()
    Safe.run("open", self.openManager, self)
    return true
end

function KR2Anki:onKR2AnkiReview()
    Safe.run("review", self.openReview, self)
    return true
end

function KR2Anki:onKR2AnkiExport()
    Safe.run("export", self.openExport, self)
    return true
end

-- Close-book prompt (off by default) ----------------------------------------------

function KR2Anki:onCloseDocument()
    if not self.settings:get("close_book_prompt") then return end
    local words, exprs = self.session.word or 0, self.session.expression or 0
    if words + exprs == 0 then return end
    local Capture = require("kr2anki/capture")
    local book = Capture.bookInfo(self.ui)
    local title = book and book.title or _("this book")
    local store = self:getStore()
    local inbox = store and store:inboxCount() or 0
    UIManager:scheduleIn(0.5, function()
        local ConfirmBox = require("ui/widget/confirmbox")
        UIManager:show(ConfirmBox:new{
            text = T(_("You saved %1 words and %2 expressions from %3.\n\nInbox now holds %4 items."),
                words, exprs, title, inbox),
            ok_text = _("Review now"),
            cancel_text = _("Later"),
            ok_callback = function()
                local FileManager = require("apps/filemanager/filemanager")
                local fm = FileManager.instance
                local host = fm and fm.kr2anki
                if host then Safe.run("review", host.openReview, host) end
            end,
        })
    end)
end

function KR2Anki:onCloseWidget()
    if self.app then self.app:closeAll() end
end

-- Menu ------------------------------------------------------------------------------

function KR2Anki:addToMainMenu(menu_items)
    local ok, item = pcall(function() return require("kr2anki/menu").build(self) end)
    if ok then
        menu_items.kr2anki = item
    else
        logger.err("KR2Anki: menu failed", item)
        menu_items.kr2anki = { text = _("KR2Anki"), sorting_hint = "tools", callback = function()
            Safe.message(_("KR2Anki menu failed to load:\n") .. tostring(item))
        end }
    end
end

return KR2Anki
