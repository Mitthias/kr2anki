--[[--
Export to Anki: pre-check → sending (one batch per screen update) → result.
Also the .apkg fallback and the note-type package.

Nothing leaves Ready until Anki confirms it; every failure keeps its reason.
--]]

local DataStorage = require("datastorage")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local BaseScreen = require("kr2anki/ui/screen")
local Kit = require("kr2anki/ui/kit")
local N = require("kr2anki/notetypes")
local Safe = require("kr2anki/safe")
local U = require("kr2anki/u8")
local _ = require("gettext")
local T = require("ffi/util").template

local Export = BaseScreen:extend{
    name = "kr2anki_export",
    mode = "anki",       -- "anki" | "package"
    items = nil,         -- retry: only these items
}

-- Package helpers ------------------------------------------------------------------------

local function ensureDir(dir)
    local ok, util = pcall(require, "util")
    if ok and util.makePath then util.makePath(dir) else os.execute("mkdir -p '" .. dir .. "'") end
end

local function readFile(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local d = f:read("*a")
    f:close()
    return d
end

local function sha1()
    local ok, sha2 = pcall(require, "ffi/sha2")
    if ok and sha2 and sha2.sha1 then return sha2.sha1 end
    return require("kr2anki/sha1")
end

function Export.mediaFor(host)
    return function(item)
        local path = host:getDictInfo():audioPath(item.dictionary, item.audio)
        if not path then return nil end
        local data = readFile(path)
        if not data then return nil end
        return { name = path:match("([^/]+)$"), data = data }
    end
end

-- Write an .apkg (or a TSV when zip writing fails). Returns info table.
function Export.writePackage(host, items, opts)
    opts = opts or {}
    local Apkg = require("kr2anki/apkg")
    local dir = host:exportDir()
    ensureDir(dir)
    local stamp = os.date("%Y-%m-%d-%H%M")
    local name = opts.name or ("kr2anki-" .. stamp .. ".apkg")
    local path = dir .. "/" .. name
    local settings = host.settings:exportOptions()
    settings.sound_for = Export.mediaFor(host)
    local notes, media = Apkg.notesFor(items, settings)
    local ok, err = Apkg.write{
        path = path, notes = notes, media = media,
        sqlite = require("lua-ljsqlite3/init"), json = host:jsonCodec(), sha1 = sha1(),
        tmpdir = DataStorage:getSettingsDir(),
    }
    if ok then return { path = path, count = #items } end
    require("logger").warn("KR2Anki: .apkg failed, writing TSV:", err)
    return Export.writeTsv(host, notes, dir, stamp, err)
end

-- Fallback: one TSV per note type (fields in note-type order, HTML kept).
function Export.writeTsv(host, notes, dir, stamp, reason)
    local files = {}
    for __, kind in ipairs({ "word", "expression" }) do
        local m = N.model(kind)
        local lines = { "#separator:tab", "#html:true", "#notetype:" .. m.name, "#deck column:" .. (#m.fields + 1),
                        "#tags column:" .. (#m.fields + 2), "#guid column:" .. (#m.fields + 3) }
        local n = 0
        for __, note in ipairs(notes) do
            if note.kind == kind then
                local cols = {}
                for i, f in ipairs(m.fields) do
                    cols[i] = (note.fields[f] or ""):gsub("[\t\r\n]", " ")
                end
                cols[#cols + 1] = note.deck
                cols[#cols + 1] = table.concat(note.tags, " ")
                cols[#cols + 1] = note.guid
                lines[#lines + 1] = table.concat(cols, "\t")
                n = n + 1
            end
        end
        if n > 0 then
            local path = dir .. "/kr2anki-" .. stamp .. "-" .. kind .. ".txt"
            local f = io.open(path, "w")
            if f then
                f:write(table.concat(lines, "\n"), "\n")
                f:close()
                files[#files + 1] = path
            end
        end
    end
    return { tsv = files, count = #notes, reason = reason }
end

-- kr2anki_notetypes.apkg: both note types plus one sample note each.
function Export.writeNotetypePackage(host, show)
    local dir = host:exportDir()
    ensureDir(dir)
    local path = dir .. "/kr2anki_notetypes.apkg"
    local Apkg = require("kr2anki/apkg")
    local items = { N.sampleItem("word"), N.sampleItem("expression") }
    for __, it in ipairs(items) do it.books = {} end
    local notes = Apkg.notesFor(items, { cards = N.defaultCards(), deck_pattern = "KR2Anki::Setup" })
    for __, n in ipairs(notes) do
        n.deck = "KR2Anki::Setup"
        n.tags[#n.tags + 1] = "kr2anki::sample"
    end
    local ok, err = Apkg.write{ path = path, notes = notes, sqlite = require("lua-ljsqlite3/init"),
        json = host:jsonCodec(), sha1 = sha1(), tmpdir = DataStorage:getSettingsDir() }
    if not ok then
        -- fall back to the copy bundled with the plugin
        local data = readFile(host.path .. "/assets/kr2anki_notetypes.apkg")
        local f = data and io.open(path, "wb")
        if f then
            f:write(data)
            f:close()
        else
            Safe.message(T(_("Could not write the note-type package:\n%1"), tostring(err)))
            return nil
        end
    end
    if show then
        local InfoMessage = require("ui/widget/infomessage")
        UIManager:show(InfoMessage:new{ text = T(_("Saved:\n%1\n\nIn AnkiDroid: ⋮ ▸ Import ▸ choose this file. It adds the two KR2Anki note types and one sample card each (deck KR2Anki::Setup), which you can delete."), path) })
    end
    return path
end

-- Data ▸ Save as Anki package
function Export.packageFlow(host)
    host:getApp():open("kr2anki/screens/export", { mode = "package" })
end

-- Screen ----------------------------------------------------------------------------------

function Export:setup()
    self.store = self.host:getStore()
    self.choices = { kr_dupes = "merge", other_dupes = "skip" }
    self.send_as_is = false
    self:loadCounts()
    if self.mode == "package" then
        self.state = "package_confirm"
        return
    end
    self.state = "checking"
    UIManager:scheduleIn(0.2, function() Safe.run("export check", self.check, self) end)
end

function Export:loadCounts()
    self.counts = self.store:counts()
end

function Export:readyCount()
    if self.items then return #self.items end
    local n = self.counts.ready
    if self.send_as_is then n = n + self.counts.inbox end
    return n
end

function Export:settingsForJob()
    local s = self.host.settings:exportOptions()
    s.send_as_is = self.send_as_is
    return s
end

function Export:check()
    self.state = "checking"
    self:refresh()
    local caps = self.host:getCaps()
    self.caps = caps
    if not caps.reachable then
        self.state = "unreachable"
        self:refresh()
        return
    end
    local Exporter = require("kr2anki/exporter")
    self.job = Exporter.new{
        client = self.host:client(), store = self.store, caps = caps,
        settings = self:settingsForJob(), media_for = Export.mediaFor(self.host), items = self.items,
    }
    self.summary = self.job:prepare()
    if self.summary.unreachable then
        self.state = "unreachable"
    elseif not require("kr2anki/anki").plan(caps).can_export then
        self.state = "cannot_add"
    elseif self.summary.need_notetypes then
        self.state = "need_notetypes"
    elseif self.summary.missing_decks then
        self.state = "need_decks"
    else
        self.state = "precheck"
    end
    self:refresh()
end

function Export:start()
    self.state = "sending"
    self.progress = { done = 0, total = 0 }
    self.job:start(self.choices)
    self.progress.total = self.job.total
    self:refresh(true)
    local function tick()
        local ok, p = pcall(self.job.step, self.job)
        if not ok then
            require("logger").err("KR2Anki: export step failed", p)
            self.job.unreachable = true
            self.job.result.error = tostring(p)
            p = self.job:finish()
        end
        self.progress = p
        if p.finished then
            self:loadCounts()
            self.state = "result"
            self:refresh(true)
        else
            self:refresh()
            UIManager:scheduleIn(0.05, tick)
        end
    end
    UIManager:scheduleIn(0.1, tick)
end

function Export:retry()
    local items = self.job:failedItems()
    local fresh = {}
    for __, it in ipairs(items) do
        local f = self.store:getItem(it.id)
        if f then fresh[#fresh + 1] = f end
    end
    self.items = fresh
    self:check()
end

function Export:howToFix()
    local TextViewer = require("ui/widget/textviewer")
    UIManager:show(TextViewer:new{
        title = _("How to fix"),
        text = _([[1. Open AnkiConnect Android once from the app list. Its notification shows it is running.

2. If Android keeps closing it: Settings ▸ Apps ▸ AnkiConnect Android ▸ Battery ▸ Unrestricted. Do the same for AnkiDroid.

3. AnkiDroid must have been opened at least once, and AnkiConnect Android needs AnkiDroid's permission ("Access AnkiDroid database") — open AnkiConnect Android and grant it if asked.

4. Come back and tap Retry.

KR2Anki connects to http://127.0.0.1:8765 on this device.]]),
    })
end

function Export:savePackageInstead()
    self.mode = "package"
    self.state = "package_confirm"
    self:refresh(true)
end

function Export:doPackage()
    local items = self.items or self.store:exportItems({ send_as_is = self.send_as_is, include_updates = false })
    local ready = {}
    for __, it in ipairs(items) do
        if it.status ~= "anki" then ready[#ready + 1] = it end
    end
    self.package_items = ready
    self.package = Export.writePackage(self.host, ready)
    self.state = "package_result"
    self:refresh(true)
end

function Export:markPackageExported()
    local ids = {}
    for __, it in ipairs(self.package_items or {}) do ids[#ids + 1] = it.id end
    self.store:setStatus(ids, "anki")
    self.marked = true
    self:loadCounts()
    self:refresh()
end

function Export:cardsDialog()
    local ButtonDialog = require("ui/widget/buttondialog")
    local dialog
    local function rebuild()
        local cards = self.host.settings:cards()
        local rows = {}
        for __, c in ipairs(N.CARD_SETTINGS) do
            rows[#rows + 1] = { { text = (cards[c.key] and "☑ " or "☐ ") .. _(c.text), callback = function()
                self.host.settings:setCard(c.key, not cards[c.key])
                UIManager:close(dialog)
                rebuild()
            end } }
        end
        rows[#rows + 1] = { { text = _("Done"), callback = function()
            UIManager:close(dialog)
            if self.job then self.job.settings = self:settingsForJob() end
            self:refresh()
        end } }
        dialog = ButtonDialog:new{ title = _("Cards for future exports"), buttons = rows }
        UIManager:show(dialog)
    end
    rebuild()
end

-- Build helpers -------------------------------------------------------------------------------

function Export:statusRight()
    local text
    if self.state == "unreachable" then text = _("○ Not reachable")
    elseif self.state == "checking" then text = _("checking…")
    elseif self.mode == "package" then text = ""
    else text = _("● Connected") end
    return Kit.text(text, Kit.uiBold(Kit.SIZE.small), {})
end

function Export:bigCount(cw, n, label)
    return HorizontalGroup:new{ align = "center",
        Kit.text(tostring(n), Kit.uiBold(Kit.SIZE.big), {}),
        Kit.hspan(Kit.dp(14)),
        Kit.text(label, Kit.ui(Kit.SIZE.title), { max_width = cw - Kit.dp(120) }),
    }
end

function Export:cardsLine(cw)
    local cards = self.host.settings:cards()
    local on = {}
    local short = { recognition = _("Recognition"), cloze = _("Cloze"), char_reading = _("Kanji → Reading"),
                    expr_recognition = _("Expression"), expr_cloze = _("Expression cloze") }
    for __, c in ipairs(N.CARD_SETTINGS) do
        if cards[c.key] then on[#on + 1] = short[c.key] end
    end
    local text = Kit.text(T(_("Cards: %1"), table.concat(on, ", ")), Kit.ui(Kit.SIZE.tiny), { fgcolor = Kit.GREY_DARK,
        max_width = cw - Kit.dp(90) })
    return Kit.spread(cw, Kit.TAP, text, Kit.link(_("Change"), function() self:cardsDialog() end, { size = Kit.SIZE.tiny }))
end

local function radioRow(cw, checked, text, cb)
    return Kit.markRow{ width = cw, mark = Kit.radio(checked), text = text, bold = checked, max_lines = 1, callback = cb }
end

local function names(items, n)
    local out = {}
    for i, it in ipairs(items) do
        if i > (n or 4) then
            out[#out + 1] = T(_("+%1 more"), #items - (n or 4))
            break
        end
        out[#out + 1] = it.type == "expression" and (it.pattern or it.lemma) or it.lemma
    end
    return table.concat(out, ", ")
end

function Export:precheckBody(cw, avail)
    return Kit.flowColumns(cw, avail, function(w) return self:precheckBlocks(w) end)
end

function Export:precheckBlocks(cw)
    local s = self.summary
    local g = { Kit.vspan(Kit.dp(8)) }
    table.insert(g, self:bigCount(cw, s.total, _("● ready to export")))
    if #s.updates > 0 then
        table.insert(g, Kit.text(T(_("+ %1 new sentences for cards already in Anki"), #s.updates), Kit.ui(Kit.SIZE.small), {}))
    end
    table.insert(g, Kit.hline(cw, Kit.dp(1)))
    if #s.by_deck > 0 then
        table.insert(g, Kit.sectionLabel(_("By deck"), cw))
        local rows = {}
        for __, d in ipairs(s.by_deck) do
            rows[#rows + 1] = Kit.spread(cw, Kit.dp(44), Kit.text(d.deck, Kit.ui(), { max_width = cw - Kit.dp(70) }),
                Kit.text(tostring(d.n), Kit.uiBold(), {}))
        end
        table.insert(g, Kit.rows(cw, rows))
    end
    table.insert(g, self:cardsLine(cw))
    if self.host.settings:get("require_review") and self.counts.inbox > 0 and not self.items then
        table.insert(g, Kit.markRow{ width = cw, mark = Kit.checkbox(self.send_as_is),
            text = T(_("Also send %1 Inbox items as they are"), self.counts.inbox), max_lines = 2,
            callback = function()
                self.send_as_is = not self.send_as_is
                Safe.run("export check", self.check, self)
            end })
    end
    table.insert(g, Kit.hline(cw, Kit.dp(1)))
    if #s.kr_dupes > 0 then
        table.insert(g, Kit.sectionLabel(T(_("Duplicates found: %1"), #s.kr_dupes), cw))
        table.insert(g, Kit.textbox(T(_("%1 already in Anki."), names(s.kr_dupes)), Kit.ui(Kit.SIZE.small), cw,
            { fgcolor = Kit.GREY_DARK, max_lines = 2 }))
        local can_merge = require("kr2anki/anki").plan(self.caps).merge
        if can_merge then
            table.insert(g, radioRow(cw, self.choices.kr_dupes == "merge", _("Add sentence to existing card"),
                function() self.choices.kr_dupes = "merge"; self:refresh() end))
        end
        table.insert(g, radioRow(cw, self.choices.kr_dupes == "skip" or not can_merge, _("Skip"),
            function() self.choices.kr_dupes = "skip"; self:refresh() end))
    end
    if #s.other_dupes > 0 then
        table.insert(g, Kit.sectionLabel(T(_("In another note type: %1"), #s.other_dupes), cw))
        table.insert(g, Kit.textbox(T(_("%1 already exist in this deck as other cards."), names(s.other_dupes)),
            Kit.ui(Kit.SIZE.small), cw, { fgcolor = Kit.GREY_DARK, max_lines = 2 }))
        table.insert(g, radioRow(cw, self.choices.other_dupes ~= "add", _("Skip"),
            function() self.choices.other_dupes = "skip"; self:refresh() end))
        table.insert(g, radioRow(cw, self.choices.other_dupes == "add", _("Add anyway"),
            function() self.choices.other_dupes = "add"; self:refresh() end))
    end
    return g
end

function Export:messageCard(cw, title, lines, buttons)
    local landscape = self.dimen.w > self.dimen.h
    local pad = landscape and Kit.dp(12) or Kit.dp(16)
    local inner = cw - 2 * (Kit.dp(1.5) + pad)
    local g = VerticalGroup:new{ align = "left", Kit.textbox(title, Kit.uiBold(Kit.SIZE.title), inner), Kit.vspan(Kit.dp(8)) }
    for __, l in ipairs(lines) do
        local size = (l[2] or landscape) and Kit.SIZE.small or Kit.SIZE.body
        table.insert(g, Kit.textbox(l[1], Kit.ui(size), inner, { fgcolor = l[2] and Kit.BLACK or Kit.GREY_DARK }))
        table.insert(g, Kit.vspan(Kit.dp(landscape and 4 or 8)))
    end
    if self.dimen.w > self.dimen.h then
        -- landscape: one row of buttons, main action rightmost
        local row = {}
        for i = #buttons, 1, -1 do row[#row + 1] = buttons[i] end
        table.insert(g, Kit.vspan(Kit.dp(6)))
        table.insert(g, Kit.buttonRow(inner + 2 * Kit.PAD, row, { size = Kit.SIZE.small }))
    else
        for __, b in ipairs(buttons) do
            table.insert(g, Kit.vspan(Kit.dp(6)))
            table.insert(g, Kit.button{ text = b.text, primary = b.primary, width = inner, callback = b.callback })
        end
    end
    return Kit.bordered(g, { padding = pad })
end

function Export:resultBody(cw, avail)
    return Kit.flowColumns(cw, avail, function(w) return self:resultBlocks(w) end)
end

function Export:resultBlocks(cw)
    local r = self.job.result
    local failed = #r.failed
    local title
    if r.unreachable then title = _("Stopped: Anki not reachable")
    elseif r.stopped then title = _("Stopped")
    elseif failed > 0 then title = _("Done, with failures")
    else title = _("✓ Done") end
    local g = { Kit.vspan(Kit.dp(10)),
        Kit.text(title, Kit.uiBold(Kit.SIZE.big - 10), { max_width = cw }),
        Kit.text(T(_("%1 added · %2 merged · %3 failed"), r.added, r.merged, failed), Kit.ui(Kit.SIZE.title), { max_width = cw }),
        Kit.vspan(Kit.dp(10)), Kit.hline(cw, Kit.dp(1)) }
    local rows = {
        Kit.row{ width = cw, symbol = "✓", text = _("Added as new notes"), value = r.added },
        Kit.row{ width = cw, symbol = "+", text = _("Sentence added to existing card"), value = r.merged },
        Kit.row{ width = cw, symbol = "×", text = _("Failed"), value = failed },
    }
    if r.skipped > 0 then rows[#rows + 1] = Kit.row{ width = cw, symbol = "—", text = _("Skipped (still Ready)"), value = r.skipped } end
    if r.not_sent then rows[#rows + 1] = Kit.row{ width = cw, symbol = "○", text = _("Not sent (still Ready)"), value = r.not_sent } end
    table.insert(g, Kit.rows(cw, rows))
    table.insert(g, Kit.vspan(Kit.dp(10)))
    if failed > 0 then
        local shown = 0
        for __, f in ipairs(r.failed) do
            shown = shown + 1
            if shown > 4 then
                table.insert(g, Kit.text(T(_("+%1 more"), failed - 4), Kit.ui(Kit.SIZE.small), { fgcolor = Kit.GREY_DARK }))
                break
            end
            local word = f.item.type == "expression" and (f.item.pattern or f.item.lemma) or f.item.lemma
            table.insert(g, Kit.textbox(T("× %1 — %2", word, f.reason), Kit.ui(Kit.SIZE.small), cw, { max_lines = 2 }))
        end
        table.insert(g, Kit.vspan(Kit.dp(8)))
        table.insert(g, Kit.textbox(_("Failed items stay Ready with their reason. Nothing was lost."),
            Kit.ui(Kit.SIZE.small), cw, { fgcolor = Kit.GREY_DARK }))
    elseif not r.stopped and not r.unreachable then
        table.insert(g, Kit.textbox(T(_("All %1 items moved to ✓ In Anki (now %2). Sync from AnkiDroid to send them to your other devices."),
            r.added + r.merged, self.counts.anki), Kit.ui(Kit.SIZE.small), cw, { fgcolor = Kit.GREY_DARK }))
    end
    if r.error then
        table.insert(g, Kit.textbox(r.error:match("^[^\n]*"), Kit.ui(Kit.SIZE.tiny), cw, { fgcolor = Kit.GREY_DARK, max_lines = 3 }))
    end
    return g
end

function Export:packageBody(cw)
    if self.state == "package_confirm" then
        local n = self:readyCount()
        return VerticalGroup:new{ align = "left", Kit.vspan(Kit.dp(8)),
            self:bigCount(cw, n, _("● ready to save")),
            Kit.vspan(Kit.dp(10)),
            Kit.textbox(_("Writes an Anki package (.apkg) to koreader/kr2anki-export/. Each item keeps its own ID, so importing it again updates the cards instead of duplicating them."),
                Kit.ui(Kit.SIZE.body), cw, { fgcolor = Kit.GREY_DARK }),
            Kit.vspan(Kit.dp(6)),
            self:cardsLine(cw),
        }
    end
    local p = self.package or {}
    local g = VerticalGroup:new{ align = "left", Kit.vspan(Kit.dp(10)) }
    if p.path then
        table.insert(g, Kit.text(_("✓ Package saved"), Kit.uiBold(Kit.SIZE.big - 12), {}))
        table.insert(g, Kit.vspan(Kit.dp(10)))
        table.insert(g, Kit.textbox(p.path, Kit.ui(Kit.SIZE.small), cw))
        table.insert(g, Kit.vspan(Kit.dp(10)))
        table.insert(g, Kit.textbox(_("In AnkiDroid: ⋮ ▸ Import ▸ choose this file."), Kit.uiBold(Kit.SIZE.body), cw))
    else
        table.insert(g, Kit.text(_("Saved as text files"), Kit.uiBold(Kit.SIZE.big - 12), {}))
        table.insert(g, Kit.vspan(Kit.dp(10)))
        table.insert(g, Kit.textbox(table.concat(p.tsv or {}, "\n"), Kit.ui(Kit.SIZE.small), cw))
        table.insert(g, Kit.vspan(Kit.dp(10)))
        table.insert(g, Kit.textbox(_("Zip writing is not available, so the items were saved as text. First import kr2anki_notetypes.apkg (Settings ▸ Data ▸ Write note-type package), then in AnkiDroid: ⋮ ▸ Import ▸ choose each .txt file."),
            Kit.ui(Kit.SIZE.body), cw))
    end
    table.insert(g, Kit.vspan(Kit.dp(14)))
    if self.marked then
        table.insert(g, Kit.textbox(T(_("%1 items marked ✓ In Anki."), #(self.package_items or {})), Kit.ui(Kit.SIZE.small), cw))
    else
        table.insert(g, Kit.textbox(_("Items stay Ready, because KR2Anki can't confirm the import. After importing, tap Mark as exported."),
            Kit.ui(Kit.SIZE.small), cw, { fgcolor = Kit.GREY_DARK }))
    end
    return g
end

function Export:bottomFor()
    local st = self.state
    if st == "checking" then
        return { { text = _("Cancel"), callback = function() self:onClose() end } }
    elseif st == "precheck" then
        local n = self.summary.total + #self.summary.updates
        return {
            { text = _("Cancel"), callback = function() self:onClose() end },
            { text = _("Export"), primary = true, enabled = n > 0, callback = function() self:start() end },
        }
    elseif st == "sending" then
        local stopping = self.job and self.job.stop_requested
        return { { text = stopping and _("Stopping after this batch…") or _("Stop after this batch"), enabled = not stopping,
                   callback = function() self.job:requestStop(); self:refresh() end } }
    elseif st == "result" then
        local failed = self.job and #self.job.result.failed or 0
        if failed > 0 then
            return {
                { text = _("Done"), callback = function() self:onClose() end },
                { text = T(_("Retry (%1)"), failed), primary = true, callback = function() Safe.run("retry", self.retry, self) end },
            }
        end
        return { { text = _("Done"), primary = true, callback = function() self:onClose() end } }
    elseif st == "package_confirm" then
        return {
            { text = _("Cancel"), callback = function() self:onClose() end },
            { text = _("Save package"), primary = true, enabled = self:readyCount() > 0,
              callback = function() Safe.run("package", self.doPackage, self) end },
        }
    elseif st == "package_result" then
        return {
            { text = _("Mark as exported"), enabled = not self.marked and #(self.package_items or {}) > 0,
              callback = function() Safe.run("mark exported", self.markPackageExported, self) end },
            { text = _("Done"), primary = true, callback = function() self:onClose() end },
        }
    end
    return { { text = _("Cancel"), callback = function() self:onClose() end } }
end

function Export:build(w, h)
    local title = self.mode == "package" and _("Save as Anki package") or _("Export to Anki")
    local header = Kit.header{ width = w, title = title, title_size = Kit.SIZE.title,
        on_back = self.state ~= "sending" and function() self:onClose() end or nil, right = self:statusRight() }
    local bottom = Kit.bottomBar(w, self:bottomFor())
    local cw = w - 2 * Kit.PAD
    local avail = h - header:getSize().h - bottom:getSize().h
    local body
    local st = self.state
    if st == "checking" then
        body = VerticalGroup:new{ align = "left", Kit.vspan(Kit.dp(8)),
            self:bigCount(cw, self:readyCount(), _("● ready to export")),
            Kit.vspan(Kit.dp(16)),
            Kit.text(_("Checking Anki for duplicates…"), Kit.ui(Kit.SIZE.body), { fgcolor = Kit.GREY_DARK }) }
    elseif st == "unreachable" then
        body = Kit.flowColumns(cw, avail, function(col) return { Kit.vspan(Kit.dp(6)),
            self:bigCount(col, self:readyCount(), _("● ready to export")), Kit.vspan(Kit.dp(10)),
            self:messageCard(col, _("Can't reach AnkiConnect Android."), {
                { _("This usually happens when Android closes the app in the background to save battery. Opening it once is normally enough.") },
                { T(_("Your %1 words stay Ready. Nothing was lost."), self:readyCount()), true },
            }, {
                { text = _("Retry"), primary = true, callback = function()
                    self.host.settings:set("caps", nil)
                    Safe.run("export check", self.check, self)
                end },
                { text = _("How to fix"), callback = function() self:howToFix() end },
                { text = _("Save as Anki package (.apkg) instead"), callback = function() self:savePackageInstead() end },
            }) } end)
    elseif st == "need_notetypes" then
        body = VerticalGroup:new{ align = "left", Kit.vspan(Kit.dp(8)),
            self:messageCard(cw, _("Anki needs the KR2Anki note types."), {
                { _("AnkiConnect Android can't create note types on this phone, so they are installed once from a package:") },
                { _("1. Tap Write note-type package.\n2. In AnkiDroid: ⋮ ▸ Import ▸ koreader/kr2anki-export/kr2anki_notetypes.apkg.\n3. Come back and tap Check again."), true },
            }, {
                { text = _("Write note-type package"), primary = true, callback = function()
                    Export.writeNotetypePackage(self.host, true)
                end },
                { text = _("Check again"), callback = function() Safe.run("export check", self.check, self) end },
                { text = _("Save as Anki package (.apkg) instead"), callback = function() self:savePackageInstead() end },
            }) }
    elseif st == "need_decks" then
        local list = table.concat(self.summary.missing_decks, "\n")
        body = VerticalGroup:new{ align = "left", Kit.vspan(Kit.dp(8)),
            self:messageCard(cw, _("Create these decks in AnkiDroid first."), {
                { _("AnkiConnect Android can't create decks, and adds notes only to decks that exist:") },
                { list, true },
                { _("In AnkiDroid: tap + ▸ Create deck, and type each name exactly (:: makes a subdeck). Then come back and tap Check again."), true },
            }, {
                { text = _("Check again"), primary = true, callback = function() Safe.run("export check", self.check, self) end },
                { text = _("Save as Anki package (.apkg) instead"), callback = function() self:savePackageInstead() end },
            }) }
    elseif st == "cannot_add" then
        body = VerticalGroup:new{ align = "left", Kit.vspan(Kit.dp(8)),
            self:messageCard(cw, _("This AnkiConnect can't add notes."), {
                { _("Neither addNotes nor addNote works here (see Settings ▸ Anki connection ▸ Diagnostics). Save an Anki package instead.") },
            }, {
                { text = _("Save as Anki package (.apkg) instead"), primary = true, callback = function() self:savePackageInstead() end },
            }) }
    elseif st == "precheck" then
        body = self:precheckBody(cw, avail)
    elseif st == "sending" then
        local p = self.progress or {}
        body = VerticalGroup:new{ align = "left", Kit.vspan(math.floor(avail * 0.25)),
            Kit.text(_("Exporting…"), Kit.ui(Kit.SIZE.title), {}),
            Kit.text(T("%1 / %2", p.done or 0, p.total or 0), Kit.uiBold(Kit.SIZE.big + 14), {}),
            Kit.vspan(Kit.dp(8)),
            Kit.text(p.deck or "", Kit.ui(Kit.SIZE.body), { fgcolor = Kit.GREY_DARK, max_width = cw }),
            Kit.text(p.word and T(_("Now: %1"), U.ellipsize(p.word, 24)) or "", Kit.ui(Kit.SIZE.body), { max_width = cw }),
            Kit.vspan(Kit.dp(24)),
            Kit.textbox(_("Keep AnkiConnect running."), Kit.ui(Kit.SIZE.small), cw, { fgcolor = Kit.GREY_DARK }) }
    elseif st == "result" then
        body = self:resultBody(cw, avail)
    else
        body = self:packageBody(cw)
    end
    return VerticalGroup:new{
        align = "left",
        header,
        Kit.box(w, avail, Kit.pad(body, Kit.PAD, 0), "top"),
        bottom,
    }
end

function Export:onClose()
    if self.state == "sending" then
        if self.job then self.job:requestStop() end
        return true
    end
    return BaseScreen.onClose(self)
end

return Export
