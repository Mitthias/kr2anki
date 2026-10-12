--[[--
Manager home: where every item stands, and the way to review, browse and export.
--]]

local FrameContainer = require("ui/widget/container/framecontainer")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local BaseScreen = require("kr2anki/ui/screen")
local Kit = require("kr2anki/ui/kit")
local Lang = require("kr2anki/lang")
local Safe = require("kr2anki/safe")
local U = require("kr2anki/u8")
local _ = require("gettext")
local T = require("ffi/util").template

local Home = BaseScreen:extend{ name = "kr2anki_home" }

function Home:setup()
    self.anki = "checking"
    self:loadData()
    UIManager:scheduleIn(0.3, function() self:checkAnki() end)
end

function Home:loadData()
    local store = self.host:getStore()
    self.counts = store:counts()
    self.by_lang = store:inboxByLanguage()
    self.last = store:lastSaved()
end

function Home:onDataChanged()
    self:loadData()
end

function Home:checkAnki()
    local ok = Safe.run("connection check", function() return self.host:ping() end)
    self.anki = ok and "connected" or "unreachable"
    if self.app and self.app:topScreen() == self then self:refresh() end
end

function Home:ankiStatusWidget()
    local text
    if self.anki == "connected" then text = _("● Anki: Connected")
    elseif self.anki == "unreachable" then text = _("○ Anki: Not reachable")
    else text = _("Anki: checking…") end
    return Kit.tap(Kit.box(Kit.text(text, Kit.uiBold(Kit.SIZE.small)):getSize().w + Kit.dp(8), Kit.TAP,
        Kit.text(text, Kit.uiBold(Kit.SIZE.small)), "right"), function()
        self.anki = "checking"
        self:refresh()
        UIManager:scheduleIn(0.2, function() self:checkAnki() end)
    end)
end

local function badge(code)
    local label = Lang.BADGES[code] or (code or "?"):sub(1, 2):upper()
    local size = Kit.dp(34)
    return FrameContainer:new{
        bordersize = Kit.dp(1.5), radius = Kit.dp(4), padding = 0, margin = 0,
        Kit.box(size, size, Kit.text(label, Kit.uiBold(Kit.SIZE.small), {})),
    }
end

function Home:browse(filter, title)
    self.app:open("kr2anki/screens/items", { filter = filter, title = title })
end

function Home:statusSection(width)
    local c = self.counts
    local rows = {
        Kit.row{ width = width, symbol = Kit.SYMBOL.inbox, text = _("Inbox"), value = c.inbox,
                 callback = function() self:browse({ statuses = { inbox = true } }, "○ " .. _("Inbox")) end },
        Kit.row{ width = width, symbol = Kit.SYMBOL.ready, text = _("Ready"), value = c.ready,
                 callback = function() self:browse({ statuses = { ready = true } }, "● " .. _("Ready")) end },
        Kit.row{ width = width, symbol = Kit.SYMBOL.anki, text = _("In Anki"), value = c.anki,
                 sub = c.updates > 0 and T(_("%1 with a new sentence to send"), c.updates) or nil,
                 callback = function() self:browse({ statuses = { anki = true } }, "✓ " .. _("In Anki")) end },
        Kit.row{ width = width, symbol = Kit.SYMBOL.known, text = _("Known / × Discarded"), value = c.known + c.discarded,
                 callback = function() self:browse({ statuses = { known = true, discarded = true } }, _("— Known / × Discarded")) end },
    }
    return VerticalGroup:new{
        align = "left",
        Kit.sectionLabel(_("Status"), width),
        Kit.rows(width, rows),
        Kit.hline(width, Kit.dp(2)),
    }
end

function Home:languageSection(width, max_rows)
    local g = VerticalGroup:new{ align = "left", Kit.sectionLabel(_("By language · in Inbox"), width) }
    if #self.by_lang == 0 then
        table.insert(g, Kit.box(width, Kit.TAP, Kit.text(_("Nothing in the Inbox."), Kit.ui(Kit.SIZE.small),
            { fgcolor = Kit.GREY_DARK }), "left"))
        return g
    end
    local rows = {}
    max_rows = math.max(1, max_rows)
    local shown = math.min(#self.by_lang, max_rows)
    -- keep one row for "N more languages" when they don't all fit
    if shown < #self.by_lang then shown = shown - 1 end
    for i = 1, shown do
        local r = self.by_lang[i]
        local sub = T(_("%1 words"), r.words or 0)
        if (r.expressions or 0) > 0 then sub = sub .. T(_(" · ◆ %1 expressions"), r.expressions) end
        local label_w = width - Kit.dp(34) - Kit.dp(14) - Kit.dp(40)
        local text = VerticalGroup:new{
            align = "left",
            Kit.text(Lang.name(r.language), Kit.ui(), { max_width = label_w }),
            Kit.text(sub, Kit.ui(Kit.SIZE.tiny), { fgcolor = Kit.GREY_DARK, max_width = label_w }),
        }
        local left = HorizontalGroup:new{ align = "center", badge(r.language), Kit.hspan(Kit.dp(14)), text }
        local code = r.language
        rows[#rows + 1] = Kit.tap(Kit.spread(width, Kit.TAP, left, Kit.text("›", Kit.ui(Kit.SIZE.title))), function()
            self:browse({ language = code, statuses = { inbox = true } }, T("%1 · ○ %2", Lang.name(code), _("Inbox")))
        end)
    end
    if shown < #self.by_lang then
        rows[#rows + 1] = Kit.row{ width = width,
            text = shown == 0 and T(_("%1 languages"), #self.by_lang) or T(_("%1 more languages"), #self.by_lang - shown),
            callback = function() self.app:open("kr2anki/screens/browse", { level = "languages", filter = { statuses = { inbox = true } } }) end }
    end
    table.insert(g, Kit.rows(width, rows))
    return g
end

function Home:lastSavedSection(width)
    local g = VerticalGroup:new{ align = "left", Kit.sectionLabel(_("Last saved"), width) }
    local it = self.last
    if not it then
        table.insert(g, Kit.textbox(_("Nothing yet. In a book: tap a word, then ★ Save."), Kit.ui(Kit.SIZE.small), width,
            { fgcolor = Kit.GREY_DARK }))
        return g
    end
    local word = it.type == "expression" and ("◆ " .. (it.pattern or it.lemma)) or it.lemma
    local parts = { Kit.bookTitle(it.book_title, it.language), Kit.relativeTime(it.saved_at) }
    local rest = {}
    for __, p in ipairs(parts) do if p and p ~= "" then rest[#rest + 1] = p end end
    local line = HorizontalGroup:new{ align = "center",
        Kit.text(U.ellipsize(word or "", 18), Kit.uiBold(Kit.SIZE.small), {}),
        Kit.text(" · " .. table.concat(rest, " · "), Kit.ui(Kit.SIZE.small), { fgcolor = Kit.GREY_DARK,
            max_width = math.max(Kit.dp(40), width - Kit.text(U.ellipsize(word or "", 18), Kit.uiBold(Kit.SIZE.small)):getSize().w) }),
    }
    local id = it.id
    table.insert(g, Kit.tap(Kit.box(width, Kit.TAP, line, "left"), function()
        self.app:open("kr2anki/screens/review", { ids = { id }, single = true })
    end))
    return g
end

function Home:actionsRow(width)
    return Kit.buttonRow(width + 2 * Kit.PAD, {
        { text = _("⌕ Search"), callback = function() self:search() end },
        { text = _("Browse"), callback = function() self.app:open("kr2anki/screens/browse", { level = "languages" }) end },
        { text = _("Settings"), callback = function()
            require("kr2anki/menu").showSettings(self.host, function() self:onRevealed() end)
        end },
    }, { size = Kit.SIZE.small })
end

function Home:search()
    require("kr2anki/screens/items").askSearch(self.app, {})
end

function Home:banner(width)
    local threshold = self.host.settings:get("nudge_threshold")
    if self.counts.inbox < threshold then return nil end
    local text = Kit.text(T(_("○  %1 items waiting for review."), self.counts.inbox), Kit.uiBold(Kit.SIZE.body), {})
    local inner_w = width - 2 * (Kit.dp(1.5) + Kit.dp(12))
    return Kit.tap(Kit.bordered(Kit.spread(inner_w, Kit.TAP - 2 * Kit.dp(13.5), text,
        Kit.text("›", Kit.ui(Kit.SIZE.title))), { padding = Kit.dp(12) }), function() self.host:openReview() end)
end

function Home:build(w, h)
    local header = Kit.header{ width = w, title = _("KR2Anki"), on_back = function() self:onClose() end,
                               right = self:ankiStatusWidget() }
    local review_n = self.counts.inbox
    local export_n = self.counts.ready + self.counts.updates
    local bottom = Kit.bottomBar(w, {
        { text = T(_("Start review (%1)"), review_n), callback = function() self.host:openReview() end },
        { text = T(_("Export (%1)"), export_n), primary = true, callback = function() self.host:openExport() end },
    })
    local avail = h - Kit.headerHeight() - Kit.bottomBarHeight()
    local cw = w - 2 * Kit.PAD
    local landscape = w > h

    if landscape then
        local col_w = math.floor((cw - Kit.PAD) / 2)
        local left = VerticalGroup:new{ align = "left", self:statusSection(col_w) }
        -- right column by priority: actions, banner, languages (as many rows as
        -- fit), last saved. Pieces are measured individually: a group caches its
        -- size on first getSize().
        local actions = Kit.buttonRow(col_w + 2 * Kit.PAD, {
            { text = _("⌕ Search"), callback = function() self:search() end },
            { text = _("Browse"), callback = function() self.app:open("kr2anki/screens/browse", { level = "languages" }) end },
            { text = _("Settings"), callback = function()
                require("kr2anki/menu").showSettings(self.host, function() self:onRevealed() end)
            end },
        }, { size = Kit.SIZE.tiny })
        local room = avail - actions:getSize().h - Kit.dp(8)
        local banner = self:banner(col_w)
        if banner and banner:getSize().h + Kit.dp(8) <= room then
            room = room - banner:getSize().h - Kit.dp(8)
        else
            banner = nil
        end
        local last = self:lastSavedSection(col_w)
        local row_h = Kit.TAP + Kit.dp(1)
        local lang
        if room >= Kit.dp(34) + row_h then
            local rows = math.floor((room - Kit.dp(34)) / row_h)
            local rows_with_last = math.floor((room - last:getSize().h - Kit.dp(34)) / row_h)
            if rows_with_last >= math.min(#self.by_lang, 2) and rows_with_last >= 1 then
                lang = self:languageSection(col_w, rows_with_last)
            else
                lang = self:languageSection(col_w, rows)
                last = nil
            end
        elseif last:getSize().h > room then
            last = nil
        end
        local right = VerticalGroup:new{ align = "left" }
        if banner then table.insert(right, Kit.vspan(Kit.dp(8))); table.insert(right, banner) end
        if lang then table.insert(right, lang) end
        if last then table.insert(right, last) end
        table.insert(right, Kit.vspan(Kit.dp(8)))
        table.insert(right, actions)
        local body = HorizontalGroup:new{ align = "top", left, Kit.hspan(Kit.PAD), right }
        return VerticalGroup:new{
            align = "left", header,
            Kit.box(w, avail, Kit.pad(body, Kit.PAD, 0), "top"),
            bottom,
        }
    end

    -- Sections by priority: status and actions always; then the banner, the
    -- languages (as many rows as fit) and the last saved item while they fit.
    local status = self:statusSection(cw)
    local actions = VerticalGroup:new{ align = "left", Kit.vspan(Kit.dp(8)), self:actionsRow(cw), Kit.vspan(Kit.dp(10)) }
    local left = avail - status:getSize().h - actions:getSize().h
    local banner = self:banner(cw)
    if banner then
        banner = VerticalGroup:new{ align = "left", Kit.vspan(Kit.dp(10)), banner }
        if banner:getSize().h <= left then left = left - banner:getSize().h else banner = nil end
    end
    local last = self:lastSavedSection(cw)
    local lang
    local lang_label = Kit.dp(34)
    local row = Kit.TAP + Kit.dp(1)
    if left >= lang_label + row then
        local with_last = left - last:getSize().h
        local rows = math.floor((with_last - lang_label) / row)
        if rows >= math.min(1, #self.by_lang) and with_last >= lang_label + row then
            lang = self:languageSection(cw, rows)
        else
            lang = self:languageSection(cw, math.floor((left - lang_label) / row))
            last = nil
        end
    elseif left >= last:getSize().h then
        lang = nil
    else
        last = nil
    end
    local body = VerticalGroup:new{ align = "left" }
    if banner then table.insert(body, banner) end
    table.insert(body, status)
    if lang then table.insert(body, lang) end
    if last then table.insert(body, last) end
    table.insert(body, actions)
    return VerticalGroup:new{
        align = "left",
        header,
        Kit.box(w, avail, Kit.pad(body, Kit.PAD, 0), "top"),
        bottom,
    }
end

return Home
