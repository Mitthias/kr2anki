--[[--
Review: one item per screen, Inbox → Ready in one tap when the first sense
is right. Also the single-item editor opened from a list (single = true).

Navigation: page-forward / swipe left = Skip; page-back / swipe right = the
previous item, with its decision still editable (the undo for mis-taps).
--]]

local HorizontalGroup = require("ui/widget/horizontalgroup")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local BaseScreen = require("kr2anki/ui/screen")
local Kit = require("kr2anki/ui/kit")
local Lang = require("kr2anki/lang")
local Ruby = require("kr2anki/ruby")
local S = require("kr2anki/sentence")
local Safe = require("kr2anki/safe")
local U = require("kr2anki/u8")
local _ = require("gettext")
local T = require("ffi/util").template

local Review = BaseScreen:extend{
    name = "kr2anki_review",
    ids = nil,
    single = false,
    index = 1,
}

local MAX_SENSES = 5

function Review:setup()
    self.ids = self.ids or {}
    self.index = self.index or 1
    self.decisions = {} -- id -> { orig, now }
    self.skipped = {}
    self.lookup_pos = {} -- id -> index of the dictionary result shown
    self:load()
end

function Review:store() return self.host:getStore() end

function Review:load()
    self.item = nil
    while self.index <= #self.ids do
        local it = self:store():getItem(self.ids[self.index])
        if it then
            self.item = it
            break
        end
        table.remove(self.ids, self.index)
    end
end

function Review:onDataChanged()
    self:load()
end

function Review:reload()
    self:load()
    self:refresh()
end

-- Current lookup and its senses ------------------------------------------------------

function Review:currentLookup()
    local it = self.item
    if not it or #it.lookups == 0 then return nil, 0 end
    local pos = self.lookup_pos[it.id]
    if not pos then
        pos = 1
        for i, l in ipairs(it.lookups) do
            if l.id == it.chosen_lookup_id then pos = i end
        end
        self.lookup_pos[it.id] = pos
    end
    pos = math.max(1, math.min(pos, #it.lookups))
    return it.lookups[pos], pos
end

function Review:switchLookup(delta)
    local __, pos = self:currentLookup()
    local n = #self.item.lookups
    self.lookup_pos[self.item.id] = ((pos - 1 + delta) % n) + 1
    self:refresh()
end

function Review:chooseSense(lookup, i)
    Safe.run("choose sense", function()
        self:store():chooseSense(self.item.id, lookup.id, i)
    end)
    self:reload()
end

-- Decisions ---------------------------------------------------------------------------

function Review:counts()
    local c = { ready = 0, known = 0, discarded = 0, inbox = 0, skipped = 0 }
    for __, id in ipairs(self.ids) do
        local d = self.decisions[id]
        if d then
            c[d.now] = (c[d.now] or 0) + 1
        elseif self.skipped[id] then
            c.skipped = c.skipped + 1
        end
    end
    return c
end

function Review:decide(status)
    local it = self.item
    if not it then return end
    local allow_empty = self.host.settings:get("allow_empty_meaning")
    if status == "ready" and it.type == "expression" and not allow_empty and U.trim(it.meaning or "") == "" then
        local InfoMessage = require("ui/widget/infomessage")
        UIManager:show(InfoMessage:new{ text = _("Add a meaning first.\n\n(Or turn on Settings ▸ Capture ▸ Allow empty Meaning on expressions.)") })
        return
    end
    local orig = self.decisions[it.id] and self.decisions[it.id].orig or it.status
    Safe.run("set status", function()
        self:store():setStatus({ it.id }, status, { force = true, allow_empty_meaning = true })
    end)
    self.decisions[it.id] = { orig = orig, now = status }
    self.skipped[it.id] = nil
    if self.single then
        self:onClose()
        return
    end
    self:advance()
end

function Review:advance()
    self.index = self.index + 1
    self:load()
    self:refresh(true)
end

function Review:onNextPage()
    if self.single then return true end
    if self.index > #self.ids then return true end
    local it = self.item
    if it and not self.decisions[it.id] then self.skipped[it.id] = true end
    self:advance()
    return true
end

function Review:onPrevPage()
    if self.single then return true end
    if self.index > 1 then
        self.index = self.index - 1
        self:load()
        self:refresh(true)
    end
    return true
end

-- Dialogs --------------------------------------------------------------------------------

local function input(title, value, on_ok, opts)
    opts = opts or {}
    local InputDialog = require("ui/widget/inputdialog")
    local dialog
    dialog = InputDialog:new{
        title = title,
        input = value or "",
        input_hint = opts.hint,
        allow_newline = opts.multiline,
        buttons = { {
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
            { text = _("Save"), is_enter_default = not opts.multiline, callback = function()
                local v = dialog:getInputText()
                UIManager:close(dialog)
                Safe.run("save", on_ok, v)
            end },
        } },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function Review:editField(field, title, multiline)
    local it = self.item
    input(title, it[field], function(v)
        v = U.trim(v or "")
        self:store():update(it.id, { [field] = v ~= "" and v or false })
        self:reload()
    end, { multiline = multiline })
end

function Review:languageMenu()
    local ButtonDialog = require("ui/widget/buttondialog")
    local it = self.item
    local dialog
    local function setLang(code)
        UIManager:close(dialog)
        if code then
            self:store():setLanguage({ it.id }, code)
            self:reload()
        end
    end
    local rows = {}
    local row = {}
    for __, code in ipairs({ "en", "zh", "ja", "ko" }) do
        row[#row + 1] = { text = (it.language == code and "● " or "") .. Lang.name(code), callback = function() setLang(code) end }
        if #row == 2 then rows[#rows + 1] = row; row = {} end
    end
    rows[#rows + 1] = { { text = _("Other language…"), callback = function()
        UIManager:close(dialog)
        input(_("Language code (e.g. fr, de, es)"), "", function(v)
            local code = Lang.normalize(v)
            if code then self:store():setLanguage({ it.id }, code); self:reload() end
        end)
    end } }
    rows[#rows + 1] = { {
        text = it.type == "expression" and _("Convert to word") or _("◆ Convert to expression"),
        callback = function()
            UIManager:close(dialog)
            self:store():setType(it.id, it.type == "expression" and "word" or "expression")
            self:reload()
        end,
    } }
    rows[#rows + 1] = { { text = _("Cancel"), callback = function() UIManager:close(dialog) end } }
    dialog = ButtonDialog:new{ title = T(_("%1 · %2"), it.lemma or "", Lang.name(it.language)), buttons = rows }
    UIManager:show(dialog)
end

-- ✎ Base-form picker: every headword the dictionaries returned, or type another.
function Review:baseFormPicker()
    local ButtonDialog = require("ui/widget/buttondialog")
    local it = self.item
    local dialog
    local seen, rows = {}, {}
    for __, l in ipairs(it.lookups) do
        local hw = l.headword or ""
        if hw ~= "" and not seen[hw] then
            seen[hw] = { l }
            local lookup = l
            rows[#rows + 1] = { {
                text = (hw == it.lemma and "● " or "") .. hw .. "  ·  " .. (l.dictionary or ""),
                callback = function()
                    UIManager:close(dialog)
                    self.lookup_pos[it.id] = nil
                    self:chooseSense(lookup, 1)
                end,
            } }
        end
    end
    rows[#rows + 1] = { { text = _("Type another…"), callback = function()
        UIManager:close(dialog)
        self:typeBaseForm()
    end } }
    rows[#rows + 1] = { { text = _("Cancel"), callback = function() UIManager:close(dialog) end } }
    dialog = ButtonDialog:new{ title = _("Base form"), buttons = rows }
    UIManager:show(dialog)
end

function Review:typeBaseForm()
    local it = self.item
    input(_("Base form to look up"), it.lemma or it.surface, function(word)
        word = U.trim(word or "")
        if word == "" then return end
        local Capture = require("kr2anki/capture")
        local results = Capture.silentLookup(self.host, word)
        local lookups = self.host:getDictInfo():lookupsFromResults(results, 1)
        if #lookups == 0 then
            local ConfirmBox = require("ui/widget/confirmbox")
            UIManager:show(ConfirmBox:new{
                text = T(_("No dictionary has %1.\n\nUse it as the base form anyway?"), word),
                ok_text = _("Use it"),
                ok_callback = function()
                    self:store():update(it.id, { lemma = word })
                    self:reload()
                end,
            })
            return
        end
        local ids = self:store():addLookups(it.id, lookups)
        self:store():chooseSense(it.id, ids[1], 1)
        self.lookup_pos[it.id] = nil
        self:reload()
    end)
end

function Review:sentenceActions()
    local ButtonDialog = require("ui/widget/buttondialog")
    local it = self.item
    local sent = it.sentence
    if not sent then return end
    local dialog
    local has_context = (sent.context_before and sent.context_before ~= "") or (sent.context_after and sent.context_after ~= "")
    local ctx = { prev = sent.context_before, next = sent.context_after, selection = sent.selection or it.surface,
                  lang = it.language }
    local function apply(fn)
        return function()
            UIManager:close(dialog)
            Safe.run("sentence", function()
                local r = fn(ctx)
                self:store():updateSentence(sent.id, r)
                self:reload()
            end)
        end
    end
    local rows = {}
    if has_context then
        rows[#rows + 1] = { { text = _("Shorten"), callback = apply(S.shorten) } }
        rows[#rows + 1] = { { text = _("Show more context"), callback = apply(S.moreContext) } }
        rows[#rows + 1] = { { text = _("Original sentence"), callback = apply(S.extract) } }
    end
    if #it.sentences > 1 then
        rows[#rows + 1] = { { text = T(_("Choose another sentence (%1)"), #it.sentences), callback = function()
            UIManager:close(dialog)
            self:chooseSentence()
        end } }
    end
    if #rows == 0 then
        rows[#rows + 1] = { { text = _("No context was saved for this sentence."), enabled = false } }
    end
    rows[#rows + 1] = { { text = _("Cancel"), callback = function() UIManager:close(dialog) end } }
    dialog = ButtonDialog:new{ buttons = rows }
    UIManager:show(dialog)
end

function Review:chooseSentence()
    local ButtonDialog = require("ui/widget/buttondialog")
    local it = self.item
    local dialog
    local rows = {}
    for __, s in ipairs(it.sentences) do
        local book = s.book and (Kit.bookTitle(s.book.title, it.language) or "") or ""
        rows[#rows + 1] = { {
            text = (s.is_primary == 1 and "● " or "") .. U.ellipsize(s.text or "", 36) .. (book ~= "" and ("  " .. book) or ""),
            callback = function()
                UIManager:close(dialog)
                self:store():setPrimarySentence(it.id, s.id)
                self:reload()
            end,
        } }
    end
    rows[#rows + 1] = { { text = _("Cancel"), callback = function() UIManager:close(dialog) end } }
    dialog = ButtonDialog:new{ title = _("Sentence for the card"), buttons = rows }
    UIManager:show(dialog)
end

function Review:showFullEntry(lookup)
    local TextViewer = require("ui/widget/textviewer")
    UIManager:show(TextViewer:new{
        title = T("%1 · %2", lookup.headword or self.item.lemma, lookup.dictionary or ""),
        text = (lookup.parsed and lookup.parsed.full) or lookup.raw_definition or "",
    })
end

-- Building blocks ----------------------------------------------------------------------------

function Review:headerWidget(w)
    local it = self.item
    local title
    if self.single then
        title = _("Edit")
    elseif it then
        title = T(_("Review %1 / %2"), self.index, #self.ids)
        local d = self.decisions[it.id]
        if d then title = title .. "  " .. (Kit.SYMBOL[d.now] or "") end
    else
        title = _("Review")
    end
    local right
    if it then
        local kind = it.type == "expression" and _("◆ Expr") or _("Word")
        local label = Kit.text(T("%1 · %2 ›", Lang.name(it.language), kind), Kit.ui(Kit.SIZE.small), { fgcolor = Kit.GREY_DARK })
        right = Kit.tap(Kit.box(label:getSize().w + Kit.dp(12), Kit.TAP, label, "right"), function() self:languageMenu() end)
    end
    return Kit.header{ width = w, title = title, on_back = function() self:onClose() end, right = right }
end

function Review:wordBlock(cw)
    local it = self.item
    local lemma = it.lemma or it.surface or ""
    local word_face = Kit.uiBold(Kit.SIZE.word)
    local edit = Kit.tap(Kit.bordered(Kit.box(Kit.TAP - 2 * Kit.dp(13.5), Kit.TAP - 2 * Kit.dp(13.5),
        Kit.text("✎", Kit.ui(Kit.SIZE.title), {})), { padding = Kit.dp(12) }), function() self:baseFormPicker() end)
    local line = HorizontalGroup:new{ align = "center" }
    local avail = cw - edit:getSize().w - Kit.dp(12)
    if it.surface and it.surface ~= "" and it.surface ~= lemma then
        local surf = Kit.text(it.surface .. " → ", Kit.ui(Kit.SIZE.body), { fgcolor = Kit.GREY_DARK,
            max_width = math.floor(avail * 0.45) })
        table.insert(line, surf)
        avail = avail - surf:getSize().w
    end
    table.insert(line, Kit.text(lemma, word_face, { max_width = avail }))
    table.insert(line, Kit.hspan(Kit.dp(12)))
    table.insert(line, edit)
    local g = VerticalGroup:new{ align = "left", line }
    local parts = {}
    local reading = it.reading
    if reading and reading ~= "" and reading ~= lemma then
        if it.language == "zh" then reading = Ruby.numberedToMarks(reading) end
        parts[#parts + 1] = reading
    end
    if it.pos and it.pos ~= "" then parts[#parts + 1] = it.pos end
    if #parts > 0 then
        table.insert(g, Kit.text(table.concat(parts, " · "), Kit.ui(Kit.SIZE.body), { fgcolor = Kit.GREY_DARK, max_width = cw }))
    end
    return g
end

function Review:sentenceBlock(cw, max_lines)
    local it = self.item
    local sent = it.sentence
    local inner_w = cw - 2 * (Kit.dp(1.5) + Kit.dp(14))
    local text, missing
    if sent and sent.text and sent.text ~= "" then
        text = sent.missing and sent.text or Kit.boldRange(sent.text, sent.hl_start, sent.hl_end)
        missing = sent.missing
    else
        text = it.surface or it.lemma or ""
        missing = true
    end
    local tb = Kit.textbox(text, Kit.serif(Kit.SIZE.sentence), inner_w, { max_lines = max_lines, line_height = 0.45,
        lang = it.language })
    local box = Kit.tap(Kit.bordered(Kit.box(inner_w, tb:getSize().h, tb, "left"), { padding = Kit.dp(14) }),
        function() self:sentenceActions() end)
    local meta = {}
    local book = sent and sent.book
    if book then
        meta[#meta + 1] = Kit.bookTitle(book.title, it.language)
        if book.authors and book.authors ~= "" then meta[#meta + 1] = book.authors end
    end
    if sent and sent.page then meta[#meta + 1] = "p. " .. sent.page end
    if missing then meta[#meta + 1] = _("no sentence (context unavailable)") end
    if #it.sentences > 1 then meta[#meta + 1] = T(_("%1 sentences"), #it.sentences) end
    return VerticalGroup:new{
        align = "left",
        box,
        Kit.vspan(Kit.dp(4)),
        Kit.text(table.concat(meta, " · "), Kit.ui(Kit.SIZE.tiny), { fgcolor = Kit.GREY_DARK, max_width = cw }),
    }
end

function Review:noteBlock(cw)
    return Kit.field{ width = cw, label = _("Note"), value = self.item.personal_note, max_lines = 2,
        callback = function() self:editField("personal_note", _("Note"), true) end }
end

-- Senses: as many radio rows as fit (max 5), the rest behind "More senses".
function Review:sensesBlock(cw, avail)
    local it = self.item
    local lookup = self:currentLookup()
    local g = VerticalGroup:new{ align = "left" }
    local right
    if lookup and #it.lookups > 1 then
        right = HorizontalGroup:new{ align = "center",
            Kit.textButton("‹", function() self:switchLookup(-1) end, { size = Kit.SIZE.body }),
            Kit.text(U.ellipsize(lookup.dictionary or "", 14), Kit.ui(Kit.SIZE.tiny), {}),
            Kit.textButton("›", function() self:switchLookup(1) end, { size = Kit.SIZE.body }) }
    elseif lookup then
        local n = #lookup.parsed.senses
        right = Kit.text(n > MAX_SENSES and T(_("%1 senses"), n) or (lookup.dictionary or ""), Kit.ui(Kit.SIZE.tiny),
            { fgcolor = Kit.GREY_DARK })
    end
    local label = Kit.sectionLabel(_("Choose the sense that fits"), cw, right)
    table.insert(g, label)
    if not lookup then
        table.insert(g, Kit.textbox(_("No definition saved."), Kit.ui(Kit.SIZE.body), cw, { fgcolor = Kit.GREY_DARK }))
        table.insert(g, Kit.link(_("Look up a different form"), function() self:typeBaseForm() end))
        return g
    end
    local senses = lookup.parsed.senses
    local used = label:getSize().h
    -- "Show full entry" and "More senses" share one footer row
    local foot_h = Kit.TAP + Kit.dp(4)
    local rows = {}
    for i, sense in ipairs(senses) do
        if i > MAX_SENSES then break end
        local checked = lookup.id == it.chosen_lookup_id and i == it.chosen_sense
        local text = i .. ". " .. sense.text
        local row = Kit.markRow{ width = cw, mark = Kit.radio(checked), text = text, bold = checked, max_lines = 2,
            callback = function() self:chooseSense(lookup, i) end }
        local rh = row:getSize().h + Kit.dp(1)
        if used + rh + foot_h > avail and #rows >= 1 then break end
        rows[#rows + 1] = row
        used = used + rh
    end
    table.insert(g, Kit.rows(cw, rows))
    local hidden = #senses - #rows
    local foot = HorizontalGroup:new{ align = "center" }
    table.insert(foot, Kit.link(_("Show full entry"), function() self:showFullEntry(lookup) end))
    if hidden > 0 then
        table.insert(foot, Kit.hspan(Kit.dp(16)))
        table.insert(foot, Kit.button{ text = T(_("More senses (%1)"), hidden), size = Kit.SIZE.small,
            callback = function()
                self.app:open("kr2anki/screens/senses", { item_id = it.id, lookup = lookup, chosen = it.chosen_sense,
                    chosen_lookup_id = it.chosen_lookup_id, on_pick = function(i) self:chooseSense(lookup, i) end })
            end })
    end
    table.insert(g, Kit.vspan(Kit.dp(4)))
    table.insert(g, foot)
    return g
end

-- Pattern, Meaning, Formation, Nuance (each opens KOReader's input dialog).
function Review:expressionFields(cw)
    local it = self.item
    local allow_empty = self.host.settings:get("allow_empty_meaning")
    return {
        Kit.field{ width = cw, label = _("Pattern"), value = it.pattern or it.surface, big = true, max_lines = 2,
            callback = function() self:editField("pattern", _("Pattern")) end },
        Kit.field{ width = cw, label = allow_empty and _("Meaning") or _("Meaning *"), value = it.meaning, max_lines = 2,
            callback = function() self:editField("meaning", _("Meaning"), true) end },
        Kit.field{ width = cw, label = _("Formation"), label_note = _("optional"), value = it.formation, max_lines = 2,
            callback = function() self:editField("formation", _("Formation"), true) end },
        Kit.field{ width = cw, label = _("Nuance"), label_note = _("optional"), value = it.nuance, max_lines = 2,
            callback = function() self:editField("nuance", _("Nuance"), true) end },
    }
end

function Review:expressionBlock(cw, from, to)
    local fields = self:expressionFields(cw)
    local g = VerticalGroup:new{ align = "left" }
    for i = from or 1, to or #fields do
        if #g > 0 then table.insert(g, Kit.vspan(Kit.dp(6))) end
        table.insert(g, fields[i])
    end
    return g
end

function Review:bottomButtons()
    local it = self.item
    if not self.single then
        return {
            { text = _("Skip"), callback = function() self:onNextPage() end },
            { text = _("— Known"), callback = function() self:decide("known") end },
            { text = _("× Discard"), callback = function() self:decide("discarded") end },
            { text = _("✓ Ready"), primary = true, callback = function() self:decide("ready") end },
        }
    end
    local b = { { text = _("Close"), callback = function() self:onClose() end } }
    local st = it.status
    if st == "inbox" then
        b[#b + 1] = { text = _("— Known"), callback = function() self:decide("known") end }
        b[#b + 1] = { text = _("× Discard"), callback = function() self:decide("discarded") end }
        b[#b + 1] = { text = _("✓ Ready"), primary = true, callback = function() self:decide("ready") end }
    elseif st == "ready" then
        b[#b + 1] = { text = _("○ Inbox"), callback = function() self:decide("inbox") end }
        b[#b + 1] = { text = _("— Known"), callback = function() self:decide("known") end }
        b[#b + 1] = { text = _("× Discard"), callback = function() self:decide("discarded") end }
    elseif st == "anki" then
        b[#b + 1] = { text = _("— Known"), callback = function() self:decide("known") end }
    else
        b[#b + 1] = { text = _("○ Move to Inbox"), primary = true, callback = function() self:decide("inbox") end }
    end
    return b
end

-- End of session ----------------------------------------------------------------------------

function Review:summary(w, h)
    local c = self:counts()
    local header = Kit.header{ width = w, title = _("Review done"), on_back = function() self:onClose() end }
    local line = T(_("%1 Ready · %2 Known · %3 Discarded · %4 skipped"), c.ready, c.known, c.discarded, c.skipped)
    local ready_total = self:store():counts().ready
    local bottom = Kit.bottomBar(w, {
        { text = _("Done"), callback = function() self:onClose() end },
        { text = T(_("Export (%1)"), ready_total), primary = true, enabled = ready_total > 0, callback = function()
            self:onClose()
            self.host:openExport()
        end },
    })
    local body = VerticalGroup:new{ align = "center",
        Kit.text("✓", Kit.uiBold(Kit.SIZE.big), {}),
        Kit.vspan(Kit.dp(12)),
        Kit.textbox(line, Kit.uiBold(Kit.SIZE.title), w - 2 * Kit.PAD, { alignment = "center" }),
        Kit.vspan(Kit.dp(16)),
        Kit.textbox(_("Swipe right to go back and change a decision."), Kit.ui(Kit.SIZE.small), w - 2 * Kit.PAD,
            { alignment = "center", fgcolor = Kit.GREY_DARK }),
    }
    return VerticalGroup:new{ align = "left", header,
        Kit.box(w, h - header:getSize().h - bottom:getSize().h, body), bottom }
end

function Review:build(w, h)
    if not self.item then
        if self.single then
            local header = Kit.header{ width = w, title = _("Edit"), on_back = function() self:onClose() end }
            return VerticalGroup:new{ align = "left", header,
                Kit.box(w, h - header:getSize().h, Kit.text(_("This item no longer exists."), Kit.ui(), {})) }
        end
        return self:summary(w, h)
    end
    local it = self.item
    local header = self:headerWidget(w)
    local bottom = Kit.bottomBar(w, self:bottomButtons(), { size = Kit.SIZE.small })
    local cw = w - 2 * Kit.PAD
    local avail = h - header:getSize().h - bottom:getSize().h
    local gap = Kit.dp(14)
    local landscape = w > h
    local body

    if it.type == "expression" then
        local req = (not self.host.settings:get("allow_empty_meaning"))
            and Kit.text(_("* Required before marking Ready."), Kit.ui(Kit.SIZE.tiny), { fgcolor = Kit.GREY_DARK }) or nil
        if landscape then
            -- Pattern, Meaning, Formation left; Nuance and the sentence right
            local col = math.floor((cw - Kit.PAD) / 2)
            local left = VerticalGroup:new{ align = "left", Kit.vspan(Kit.dp(6)), self:expressionBlock(col, 1, 3) }
            local nuance = self:expressionBlock(col, 4, 4)
            local lines = 5
            local sentence = self:sentenceBlock(col, lines)
            while lines > 2 and nuance:getSize().h + sentence:getSize().h + gap + Kit.dp(40) > avail do
                lines = lines - 1
                sentence = self:sentenceBlock(col, lines)
            end
            local right = VerticalGroup:new{ align = "left", Kit.vspan(Kit.dp(6)), nuance, Kit.vspan(gap), sentence }
            if req then table.insert(right, req) end
            body = HorizontalGroup:new{ align = "top", left, Kit.hspan(Kit.PAD), right }
        else
            local fields = self:expressionBlock(cw)
            local sentence = self:sentenceBlock(cw, 4)
            body = VerticalGroup:new{ align = "left", Kit.vspan(gap), fields, Kit.vspan(gap), sentence }
            if req then table.insert(body, Kit.vspan(Kit.dp(8))); table.insert(body, req) end
        end
    elseif landscape then
        -- word and sentence on the left; senses and note on the right
        local col = math.floor((cw - Kit.PAD) / 2)
        local word = self:wordBlock(col)
        local lines = 6
        local sentence = self:sentenceBlock(col, lines)
        while lines > 2 and word:getSize().h + sentence:getSize().h + gap + Kit.dp(8) > avail do
            lines = lines - 1
            sentence = self:sentenceBlock(col, lines)
        end
        local note = self:noteBlock(col)
        local left_h = Kit.dp(8) + word:getSize().h + gap + sentence:getSize().h
        local left = VerticalGroup:new{ align = "left", Kit.vspan(Kit.dp(8)), word, Kit.vspan(gap), sentence }
        local right
        if left_h + gap + note:getSize().h <= avail then
            -- the note fits under the sentence: senses get the whole right column
            table.insert(left, Kit.vspan(gap))
            table.insert(left, note)
            right = self:sensesBlock(col, avail)
        else
            right = VerticalGroup:new{ align = "left",
                self:sensesBlock(col, avail - note:getSize().h - gap), Kit.vspan(gap), note }
        end
        body = HorizontalGroup:new{ align = "top", left, Kit.hspan(Kit.PAD), right }
    else
        local top = VerticalGroup:new{ align = "left", Kit.vspan(Kit.dp(10)), self:wordBlock(cw), Kit.vspan(gap),
            self:sentenceBlock(cw, 4), Kit.vspan(gap) }
        local note = self:noteBlock(cw)
        local senses_h = avail - top:getSize().h - note:getSize().h - gap
        body = VerticalGroup:new{ align = "left", top, self:sensesBlock(cw, senses_h), Kit.vspan(gap), note }
    end
    return VerticalGroup:new{
        align = "left",
        header,
        Kit.box(w, avail, Kit.pad(body, Kit.PAD, 0), "top"),
        bottom,
    }
end

return Review
