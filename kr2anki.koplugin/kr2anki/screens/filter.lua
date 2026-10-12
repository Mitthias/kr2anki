--[[--
Filter: status, type and date range for an item list.
--]]

local HorizontalGroup = require("ui/widget/horizontalgroup")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local BaseScreen = require("kr2anki/ui/screen")
local Kit = require("kr2anki/ui/kit")
local _ = require("gettext")

local Filter = BaseScreen:extend{
    name = "kr2anki_filter",
    state = nil,     -- { statuses = set|nil, type = nil|"word"|"expression", date = "any"|… }
    on_apply = nil,
}

local TYPES = { { nil, "Words and expressions" }, { "word", "Words" }, { "expression", "◆ Expressions" } }

function Filter:setup()
    local s = self.state or {}
    local statuses = {}
    for k, v in pairs(s.statuses or {}) do statuses[k] = v end
    self.work = { statuses = statuses, type = s.type, date = s.date or "any" }
end

function Filter:ranges()
    return require("kr2anki/screens/items").DATE_RANGES
end

function Filter:chooseDate()
    local ButtonDialog = require("ui/widget/buttondialog")
    local dialog
    local buttons = {}
    for __, d in ipairs(self:ranges()) do
        buttons[#buttons + 1] = { { text = (self.work.date == d.id and "● " or "") .. _(d.text), callback = function()
            UIManager:close(dialog)
            self.work.date = d.id
            self:refresh()
        end } }
    end
    dialog = ButtonDialog:new{ title = _("Saved"), buttons = buttons }
    UIManager:show(dialog)
end

-- Status checkboxes, in `cols` columns.
function Filter:statusGroup(cw, cols)
    cols = cols or 1
    local gap = Kit.dp(12)
    local col_w = math.floor((cw - (cols - 1) * gap) / cols)
    local cells = {}
    for __, st in ipairs({ "inbox", "ready", "anki", "known", "discarded" }) do
        cells[#cells + 1] = Kit.markRow{ width = col_w, mark = Kit.checkbox(self.work.statuses[st] == true),
            text = Kit.SYMBOL[st] .. "  " .. Kit.STATUS_NAME[st], max_lines = 1,
            callback = function()
                self.work.statuses[st] = not self.work.statuses[st] or nil
                self:refresh()
            end }
    end
    local rows = {}
    for i = 1, #cells, cols do
        local r = HorizontalGroup:new{ align = "center" }
        for j = i, math.min(#cells, i + cols - 1) do
            if j > i then table.insert(r, Kit.hspan(gap)) end
            table.insert(r, cells[j])
        end
        rows[#rows + 1] = r
    end
    return VerticalGroup:new{ align = "left", Kit.sectionLabel(_("Status"), cw), Kit.rows(cw, rows) }
end

function Filter:typeGroup(cw)
    local rows = {}
    for __, t in ipairs(TYPES) do
        rows[#rows + 1] = Kit.markRow{ width = cw, mark = Kit.radio(self.work.type == t[1]), text = _(t[2]), max_lines = 1,
            callback = function() self.work.type = t[1]; self:refresh() end }
    end
    return VerticalGroup:new{ align = "left", Kit.sectionLabel(_("Type"), cw), Kit.rows(cw, rows) }
end

function Filter:dateGroup(cw)
    local current = "Any time"
    for __, d in ipairs(self:ranges()) do
        if d.id == self.work.date then current = d.text end
    end
    return VerticalGroup:new{ align = "left",
        Kit.sectionLabel(_("Saved"), cw),
        Kit.row{ width = cw, text = _(current), callback = function() self:chooseDate() end },
    }
end

function Filter:build(w, h)
    local header = Kit.header{ width = w, title = _("Filter"), on_back = function() self:onClose() end }
    local cw = w - 2 * Kit.PAD
    local bottom = Kit.bottomBar(w, {
        { text = _("Clear"), callback = function()
            self.work = { statuses = {}, type = nil, date = "any" }
            self:refresh()
        end },
        { text = _("Apply"), primary = true, callback = function()
            local st = next(self.work.statuses) and self.work.statuses or nil
            if self.on_apply then self.on_apply({ statuses = st, type = self.work.type, date = self.work.date }) end
            self:onClose()
        end },
    })
    local avail = h - header:getSize().h - bottom:getSize().h
    local body
    if w > h then
        -- three columns: status | type | saved
        local col = math.floor((cw - 2 * Kit.PAD) / 3)
        local status = self:statusGroup(col)
        if status:getSize().h > avail then status = self:statusGroup(col, 2) end
        body = HorizontalGroup:new{ align = "top", status, Kit.hspan(Kit.PAD), self:typeGroup(col),
            Kit.hspan(Kit.PAD), self:dateGroup(col) }
    else
        local rest = VerticalGroup:new{ align = "left", self:typeGroup(cw), self:dateGroup(cw) }
        local status = self:statusGroup(cw)
        if status:getSize().h + rest:getSize().h > avail then status = self:statusGroup(cw, 2) end
        body = VerticalGroup:new{ align = "left", status, rest }
    end
    return VerticalGroup:new{
        align = "left", header,
        Kit.box(w, avail, Kit.pad(body, Kit.PAD, 0), "top"),
        bottom,
    }
end

return Filter
