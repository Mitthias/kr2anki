--[[--
Browse: Language → Book → items. Paged lists, never infinite scrolling.
An item saved from two books appears under both.
--]]

local VerticalGroup = require("ui/widget/verticalgroup")
local BaseScreen = require("kr2anki/ui/screen")
local Kit = require("kr2anki/ui/kit")
local Lang = require("kr2anki/lang")
local _ = require("gettext")

local Browse = BaseScreen:extend{
    name = "kr2anki_browse",
    level = "languages", -- "languages" | "books"
    language = nil,
    filter = nil,        -- extra scope (e.g. statuses)
}

local function copy(t)
    local o = {}
    for k, v in pairs(t or {}) do o[k] = v end
    return o
end

function Browse:setup()
    self.page = 1
    self:loadData()
end

function Browse:onDataChanged()
    self:loadData()
end

function Browse:scope()
    local f = copy(self.filter)
    if self.level == "books" then f.language = self.language end
    return f
end

function Browse:loadData()
    local store = self.host:getStore()
    local rows = {}
    if self.level == "languages" then
        local total = store:count(self:scope())
        rows[#rows + 1] = { text = _("All languages"), n = total, open = function()
            self.app:open("kr2anki/screens/items", { filter = self:scope(), title = _("All languages") })
        end }
        for __, r in ipairs(store:languages(self:scope())) do
            local code = r.language
            rows[#rows + 1] = { text = Lang.name(code), n = r.n, open = function()
                self.app:open("kr2anki/screens/browse", { level = "books", language = code, filter = self.filter })
            end }
        end
    else
        local scope = self:scope()
        rows[#rows + 1] = { text = _("All books"), n = store:count(scope), open = function()
            self.app:open("kr2anki/screens/items", { filter = scope, title = Lang.name(self.language) })
        end }
        for __, b in ipairs(store:booksFor(scope)) do
            local f = copy(scope)
            f.book_id = b.book_id
            local title = b.book_id == "none" and _("No book") or (Kit.bookTitle(b.title, self.language) or "?")
            rows[#rows + 1] = { text = title, sub = b.authors, n = b.n, open = function()
                self.app:open("kr2anki/screens/items", { filter = f, title = Lang.name(self.language) .. " › " .. title })
            end }
        end
    end
    self.rows = rows
end

function Browse:build(w, h)
    local title = self.level == "languages" and _("Browse") or Lang.name(self.language)
    local header = Kit.header{ width = w, title = title, on_back = function() self:onClose() end,
        right = Kit.textButton("⌕", function()
            require("kr2anki/screens/items").askSearch(self.app, self:scope())
        end, { size = Kit.SIZE.title }) }
    local cw = w - 2 * Kit.PAD
    local avail = h - header:getSize().h - Kit.PAGER_H
    local per = math.max(1, math.floor(avail / (Kit.TAP + Kit.dp(1))))
    self.pages = math.max(1, math.ceil(#self.rows / per))
    self.page = math.max(1, math.min(self.page or 1, self.pages))
    local list = {}
    for i = (self.page - 1) * per + 1, math.min(#self.rows, self.page * per) do
        local r = self.rows[i]
        list[#list + 1] = Kit.row{ width = cw, text = r.text, sub = r.sub, value = r.n, callback = r.open, bold = i == 1 }
    end
    return VerticalGroup:new{
        align = "left", header,
        Kit.box(w, avail, Kit.pad(Kit.rows(cw, list), Kit.PAD, 0), "top"),
        self:pagerWidget(w),
    }
end

return Browse
