--[[--
Item list: paged rows (headword, reading, short meaning, status symbol),
filter, A–Z sort, search, and selection mode with bulk actions.
--]]

local HorizontalGroup = require("ui/widget/horizontalgroup")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local BaseScreen = require("kr2anki/ui/screen")
local Kit = require("kr2anki/ui/kit")
local Lang = require("kr2anki/lang")
local Parse = require("kr2anki/dictparse")
local Safe = require("kr2anki/safe")
local _ = require("gettext")
local T = require("ffi/util").template

local Items = BaseScreen:extend{
    name = "kr2anki_items",
    filter = nil,   -- base scope: language, book_id, statuses, search …
    title = nil,
}

local DATE_RANGES = {
    { id = "any", text = "Any time" },
    { id = "today", text = "Today" },
    { id = "week", text = "Last 7 days" },
    { id = "month", text = "Last 30 days" },
    { id = "year", text = "Last 12 months" },
}
Items.DATE_RANGES = DATE_RANGES

function Items:setup()
    self.base = self.filter or {}
    -- the user's filter on top of the scope
    self.user = { statuses = nil, type = nil, date = "any" }
    if self.base.statuses then
        self.user.statuses = self.base.statuses
    end
    self.sort = self.host.settings:get("browse_sort")
    self.page = 1
    self.selecting = false
    self.selected = {}
    self:loadData()
end

local function copy(t)
    local o = {}
    for k, v in pairs(t or {}) do o[k] = v end
    return o
end

function Items:effectiveFilter()
    local f = copy(self.base)
    f.statuses = self.user.statuses
    f.type = self.user.type
    local now = os.time()
    local d = self.user.date
    if d == "today" then
        local t = os.date("*t", now)
        t.hour, t.min, t.sec = 0, 0, 0
        f.since = os.time(t)
    elseif d == "week" then f.since = now - 7 * 86400
    elseif d == "month" then f.since = now - 30 * 86400
    elseif d == "year" then f.since = now - 365 * 86400 end
    return f
end

-- Number of filter conditions beyond the screen's own scope.
function Items:activeFilterCount()
    local n = 0
    local base_st = self.base.statuses
    local st = self.user.statuses
    local same = true
    if (base_st == nil) ~= (st == nil) then same = false
    elseif st then
        for k in pairs(st) do if not base_st[k] then same = false end end
        for k in pairs(base_st) do if not st[k] then same = false end end
    end
    if not same then n = n + 1 end
    if self.user.type then n = n + 1 end
    if self.user.date and self.user.date ~= "any" then n = n + 1 end
    return n
end

function Items:loadData()
    local store = self.host:getStore()
    local f = self:effectiveFilter()
    self.total = store:count(f)
    self.inbox_in_scope = 0
    local scope = copy(self.base)
    scope.statuses = { inbox = true }
    self.inbox_in_scope = store:count(scope)
    self.ready_total = store:counts().ready
end

function Items:onDataChanged()
    self:loadData()
end

function Items:clearFilter()
    self.user = { statuses = self.base.statuses, type = nil, date = "any" }
    self.page = 1
    self:loadData()
    self:refresh()
end

function Items:statusSummary()
    local st = self.user.statuses
    if not st or not next(st) then return _("all statuses") end
    local parts = {}
    for __, s in ipairs({ "inbox", "ready", "anki", "known", "discarded" }) do
        if st[s] then parts[#parts + 1] = Kit.SYMBOL[s] .. " " .. Kit.STATUS_NAME[s] end
    end
    return T(_("status: %1"), table.concat(parts, ", "))
end

-- Row ---------------------------------------------------------------------------

function Items:rowWidget(r, width)
    local check_w = self.selecting and Kit.dp(44) or 0
    local sym_w = Kit.dp(36)
    local word_w = math.floor((width - check_w - sym_w) * 0.45)
    local mean_w = width - check_w - sym_w - word_w - Kit.dp(8)
    local is_expr = r.type == "expression"
    local head = is_expr and ("◆ " .. (r.pattern or r.lemma or "")) or (r.lemma or "")
    local sub = is_expr and _("expression") or (r.reading and r.reading ~= r.lemma and r.reading or nil)
    if r.language == "zh" and sub then sub = require("kr2anki/ruby").numberedToMarks(sub) end
    local word = VerticalGroup:new{ align = "left",
        Kit.text(head, Kit.uiBold(Kit.SIZE.body), { max_width = word_w }) }
    if sub and sub ~= "" then
        table.insert(word, Kit.text(sub, Kit.ui(Kit.SIZE.tiny), { fgcolor = Kit.GREY_DARK, max_width = word_w }))
    end
    local meaning = is_expr and r.meaning or r.definition
    local mean_text = (meaning and meaning ~= "") and Parse.shortMeaning(meaning, 60) or "—"
    local mean = Kit.textbox(mean_text, Kit.ui(Kit.SIZE.small), mean_w, { max_lines = 2,
        fgcolor = (meaning and meaning ~= "") and Kit.BLACK or Kit.GREY_DARK })
    local h = self.row_h
    local row = HorizontalGroup:new{ align = "center" }
    if self.selecting then
        table.insert(row, Kit.box(check_w, h, Kit.checkbox(self.selected[r.id] == true), "left"))
    end
    local symbol = Kit.SYMBOL[r.status] or "?"
    if r.status == "anki" and r.needs_update == 1 then symbol = "✓+" end
    table.insert(row, Kit.box(word_w, h, word, "left"))
    table.insert(row, Kit.hspan(Kit.dp(8)))
    table.insert(row, Kit.box(mean_w, h, mean, "left"))
    table.insert(row, Kit.box(sym_w, h, Kit.text(symbol, Kit.ui(Kit.SIZE.title), {}), "right"))
    local id = r.id
    return Kit.tap(row, function()
        if self.selecting then
            self.selected[id] = not self.selected[id] or nil
            self:refresh()
        else
            self.app:open("kr2anki/screens/review", { ids = { id }, single = true })
        end
    end, function()
        if not self.selecting then
            self.selecting = true
            self.selected = { [id] = true }
            self:refresh()
        end
    end), h
end

-- Selection -----------------------------------------------------------------------

function Items:selectedIds()
    local ids = {}
    for id in pairs(self.selected) do ids[#ids + 1] = id end
    table.sort(ids)
    return ids
end

function Items:selectedCount()
    local n = 0
    for _ in pairs(self.selected) do n = n + 1 end
    return n
end

function Items:endSelection()
    self.selecting = false
    self.selected = {}
    self:loadData()
    self:refresh()
end

function Items:selectPage()
    for __, r in ipairs(self.page_rows or {}) do self.selected[r.id] = true end
    self:refresh()
end

function Items:selectAll()
    for __, id in ipairs(self.host:getStore():queryIds(self:effectiveFilter(), self.sort)) do self.selected[id] = true end
    self:refresh()
end

local function message(text)
    local InfoMessage = require("ui/widget/infomessage")
    UIManager:show(InfoMessage:new{ text = text, timeout = 3 })
end

function Items:bulkStatus(status)
    local ids = self:selectedIds()
    if #ids == 0 then return end
    local store = self.host:getStore()
    local allow = self.host.settings:get("allow_empty_meaning")
    local r = store:setStatus(ids, status, { allow_empty_meaning = allow })
    local parts = { T(_("%1 marked %2"), r.changed, Kit.STATUS_NAME[status]) }
    if r.skipped_meaning > 0 then
        parts[#parts + 1] = T(r.skipped_meaning == 1 and _("%1 expression needs a meaning") or _("%1 expressions need a meaning"),
            r.skipped_meaning)
    end
    if r.skipped_invalid > 0 then
        parts[#parts + 1] = T(_("%1 skipped (not allowed from their status)"), r.skipped_invalid)
    end
    message(table.concat(parts, ", ") .. ".")
    self:endSelection()
end

function Items:bulkDelete()
    local ids = self:selectedIds()
    if #ids == 0 then return end
    local store = self.host:getStore()
    local text = T(_("Delete %1 items?"), #ids)
    if store:anyInAnki(ids) then
        text = text .. "\n\n" .. _("This won't remove the card from Anki.")
    end
    local ConfirmBox = require("ui/widget/confirmbox")
    UIManager:show(ConfirmBox:new{
        text = text,
        ok_text = _("Delete"),
        ok_callback = Safe.wrap("delete", function()
            store:delete(ids)
            self:endSelection()
        end),
    })
end

function Items:bulkLanguage()
    local ids = self:selectedIds()
    if #ids == 0 then return end
    local ButtonDialog = require("ui/widget/buttondialog")
    local dialog
    local function pick(code)
        UIManager:close(dialog)
        if not code then return end
        self.host:getStore():setLanguage(ids, code)
        message(T(_("%1 items moved to %2."), #ids, Lang.name(code)))
        self:endSelection()
    end
    local rows = {}
    for __, code in ipairs({ "en", "zh", "ja", "ko" }) do
        rows[#rows + 1] = { { text = Lang.name(code), callback = function() pick(code) end } }
    end
    rows[#rows + 1] = { { text = _("Other…"), callback = function()
        UIManager:close(dialog)
        require("kr2anki/menu").inputText(_("Language code (e.g. fr, de, es)"), "", function(v)
            local code = Lang.normalize(v)
            if code then
                self.host:getStore():setLanguage(ids, code)
                self:endSelection()
            end
        end)
    end } }
    rows[#rows + 1] = { { text = _("Cancel"), callback = function() pick(nil) end } }
    dialog = ButtonDialog:new{ title = _("Change language"), buttons = rows }
    UIManager:show(dialog)
end

function Items:moreActions()
    local ButtonDialog = require("ui/widget/buttondialog")
    local dialog
    local function act(fn) return function() UIManager:close(dialog); Safe.run("bulk action", fn) end end
    dialog = ButtonDialog:new{
        title = T(_("%1 selected"), self:selectedCount()),
        buttons = {
            { { text = _("× Discard"), callback = act(function() self:bulkStatus("discarded") end) } },
            { { text = _("○ Move to Inbox"), callback = act(function() self:bulkStatus("inbox") end) } },
            { { text = _("Change language"), callback = act(function() self:bulkLanguage() end) } },
            { { text = _("Cancel"), callback = function() UIManager:close(dialog) end } },
        },
    }
    UIManager:show(dialog)
end

-- Header pieces --------------------------------------------------------------------

function Items:openFilter()
    self.app:open("kr2anki/screens/filter", {
        state = self.user,
        on_apply = function(state)
            self.user = state
            self.page = 1
            self:loadData()
        end,
    })
end

function Items:toggleSort()
    self.sort = self.sort == "az" and "newest" or "az"
    self.host.settings:set("browse_sort", self.sort)
    self.page = 1
    self:refresh()
end

function Items:headerRight()
    local g = HorizontalGroup:new{ align = "center" }
    table.insert(g, Kit.textButton("⌕", function() Items.askSearch(self.app, self.base) end, { size = Kit.SIZE.title }))
    local n = self:activeFilterCount()
    table.insert(g, Kit.button{
        text = n > 0 and T(_("Filter · %1"), n) or _("Filter"),
        primary = n > 0, size = Kit.SIZE.small, height = Kit.TAP,
        callback = function() self:openFilter() end,
    })
    return g
end

function Items:selectionHeader(w)
    local right = HorizontalGroup:new{ align = "center",
        Kit.button{ text = _("Select page"), size = Kit.SIZE.small, callback = function() self:selectPage() end } }
    return Kit.header{ width = w, title = T(_("%1 selected"), self:selectedCount()), back_symbol = "✕",
                       on_back = function() self:endSelection() end, right = right }
end

-- Build -----------------------------------------------------------------------------

function Items:subheader(w)
    local h = Kit.TAP
    local left_text = T(_("%1 items · %2"), self.total, self:statusSummary())
    if self.selecting then
        local right = Kit.link(T(_("Select all (%1)"), self.total), function() self:selectAll() end, { size = Kit.SIZE.small })
        return Kit.pad(Kit.spread(w - 2 * Kit.PAD, h, Kit.text(left_text, Kit.ui(Kit.SIZE.small), { fgcolor = Kit.GREY_DARK,
            max_width = w - 2 * Kit.PAD - right:getSize().w - Kit.dp(8) }), right), Kit.PAD, 0)
    end
    local right
    if self:activeFilterCount() > 0 then
        right = Kit.link(_("Clear filter"), function() self:clearFilter() end, { size = Kit.SIZE.small })
    else
        right = Kit.textButton(self.sort == "az" and _("A–Z ⇅") or _("Newest ⇅"), function() self:toggleSort() end,
            { size = Kit.SIZE.small })
    end
    return Kit.pad(Kit.spread(w - 2 * Kit.PAD, h, Kit.text(left_text, Kit.ui(Kit.SIZE.small), { fgcolor = Kit.GREY_DARK,
        max_width = w - 2 * Kit.PAD - right:getSize().w - Kit.dp(8) }), right), Kit.PAD, 0)
end

function Items:emptyBody(w, h)
    local Kitw = w
    if self:activeFilterCount() > 0 or self.base.search then
        local text = self.inbox_in_scope > 0 and _("Words here are still in the Inbox. Review them to mark them Ready.")
            or _("Try another filter.")
        local g = VerticalGroup:new{ align = "center",
            Kit.emptyState(Kitw, "●", _("No words match this filter."), text) }
        if self:activeFilterCount() > 0 then
            table.insert(g, Kit.vspan(Kit.dp(12)))
            table.insert(g, Kit.link(_("Clear filter"), function() self:clearFilter() end))
        end
        return Kit.box(w, h, g)
    end
    if self.inbox_view then
        return Kit.box(w, h, Kit.emptyState(Kitw, "○", _("Nothing to review."),
            _("Words you save while reading appear here."), _("In a book: tap a word, then ★ Save.")))
    end
    return Kit.box(w, h, Kit.emptyState(Kitw, "○", _("Nothing here yet."), _("Words you save while reading appear here.")))
end

function Items:bottom(w)
    if self.selecting then
        local any = self:selectedCount() > 0
        return Kit.bottomBar(w, {
            { text = _("⋯"), weight = 0.55, enabled = any, callback = function() self:moreActions() end },
            { text = _("× Delete"), enabled = any, callback = function() self:bulkDelete() end },
            { text = _("— Known"), enabled = any, callback = function() self:bulkStatus("known") end },
            { text = _("● Mark Ready"), weight = 1.45, primary = true, enabled = any, callback = function() self:bulkStatus("ready") end },
        }, { size = Kit.SIZE.small })
    end
    if self.total == 0 then
        if self:activeFilterCount() > 0 then
            return Kit.bottomBar(w, {
                { text = _("Show all"), callback = function() self:clearFilter() end },
                { text = T(_("Review (%1)"), self.inbox_in_scope), primary = true, enabled = self.inbox_in_scope > 0,
                  callback = function() self.host:openReview(self.base) end },
            })
        end
        return Kit.bottomBar(w, {
            { text = _("Browse all"), callback = function() self.app:open("kr2anki/screens/browse", { level = "languages" }) end },
            { text = T(_("Export (%1)"), self.ready_total), primary = true, enabled = self.ready_total > 0,
              callback = function() self.host:openExport() end },
        })
    end
    return nil
end

function Items:build(w, h)
    local header = self.selecting and self:selectionHeader(w)
        or Kit.header{ width = w, title = self.title or _("Items"), on_back = function() self:onClose() end,
                       right = self:headerRight(), title_size = Kit.SIZE.body + 2 }
    local sub = self:subheader(w)
    local bottom = self:bottom(w)
    local legend = Kit.box(w, Kit.dp(30), Kit.text(_("○ Inbox · ● Ready · ✓ In Anki · — Known · × Discarded · ◆ Expr"),
        Kit.ui(Kit.SIZE.tiny), { fgcolor = Kit.GREY_DARK, max_width = w - 2 * Kit.PAD }))
    local fixed = header:getSize().h + sub:getSize().h + Kit.dp(1)
    if bottom then fixed = fixed + bottom:getSize().h end

    if self.total == 0 then
        return VerticalGroup:new{
            align = "left", header, sub, Kit.hline(w, Kit.dp(1)),
            self:emptyBody(w, h - fixed),
            bottom,
        }
    end

    -- fixed-height rows (two lines of meaning fit), so pages are exact
    fixed = fixed + legend:getSize().h + Kit.PAGER_H
    local avail = h - fixed
    local cw = w - 2 * Kit.PAD
    local store = self.host:getStore()
    local f = self:effectiveFilter()
    self.row_h = math.max(Kit.TAP,
        2 * Kit.lineHeight(Kit.ui(Kit.SIZE.small)) + Kit.dp(14),
        Kit.text("Ag", Kit.uiBold(Kit.SIZE.body)):getSize().h + Kit.text("Ag", Kit.ui(Kit.SIZE.tiny)):getSize().h + Kit.dp(12))
    local per_page = math.max(1, math.floor(avail / (self.row_h + Kit.dp(1))))
    self.per_page = per_page
    self.pages = math.max(1, math.ceil(self.total / per_page))
    self.page = math.max(1, math.min(self.page or 1, self.pages))
    local rows = store:query(f, self.sort, (self.page - 1) * per_page, per_page)
    self.page_rows = rows
    local list = VerticalGroup:new{ align = "left" }
    for __, r in ipairs(rows) do
        table.insert(list, (self:rowWidget(r, cw)))
        table.insert(list, Kit.hline(cw, Kit.dp(1), Kit.GREY_LIGHT))
    end
    local parts = VerticalGroup:new{
        align = "left", header, sub, Kit.hline(w, Kit.dp(1)),
        Kit.box(w, avail, Kit.pad(list, Kit.PAD, 0), "top"),
        legend,
        self:pagerWidget(w),
    }
    if bottom then table.insert(parts, bottom) end
    return parts
end

-- Search (from home and every browse screen) ---------------------------------------------

function Items.askSearch(app, scope)
    local InputDialog = require("ui/widget/inputdialog")
    local dialog
    dialog = InputDialog:new{
        title = _("Search words, readings and meanings"),
        buttons = { {
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
            { text = _("Search"), is_enter_default = true, callback = function()
                local q = dialog:getInputText()
                UIManager:close(dialog)
                if q and q:match("%S") then
                    local f = copy(scope)
                    f.search = q
                    app:open("kr2anki/screens/items", { filter = f, title = T(_("Search: %1"), q) })
                end
            end },
        } },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

return Items
