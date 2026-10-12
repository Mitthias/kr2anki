--[[--
Full-screen paged sense picker, for entries with more senses than fit on the
review screen.
--]]

local VerticalGroup = require("ui/widget/verticalgroup")
local BaseScreen = require("kr2anki/ui/screen")
local Kit = require("kr2anki/ui/kit")
local _ = require("gettext")
local T = require("ffi/util").template

local Senses = BaseScreen:extend{
    name = "kr2anki_senses",
    lookup = nil,
    chosen = nil,
    chosen_lookup_id = nil,
    on_pick = nil,
}

function Senses:setup()
    self.page = 1
    -- start on the page holding the chosen sense
    self.start_on_chosen = true
end

function Senses:build(w, h)
    local lookup = self.lookup
    local senses = lookup.parsed.senses
    local header = Kit.header{ width = w, title = T(_("Choose a sense · %1"), lookup.dictionary or ""),
                               on_back = function() self:onClose() end, title_size = Kit.SIZE.body + 2 }
    local cw = w - 2 * Kit.PAD
    local avail = h - header:getSize().h - Kit.PAGER_H
    -- fixed rows of up to 3 lines so pages are exact
    local row_h = math.max(Kit.TAP, 3 * Kit.lineHeight(Kit.ui(Kit.SIZE.body)) + Kit.dp(20))
    local per = math.max(1, math.floor(avail / (row_h + Kit.dp(1))))
    self.pages = math.max(1, math.ceil(#senses / per))
    if self.start_on_chosen then
        self.start_on_chosen = nil
        if self.chosen and lookup.id == self.chosen_lookup_id then
            self.page = math.floor((self.chosen - 1) / per) + 1
        end
    end
    self.page = math.max(1, math.min(self.page, self.pages))
    local rows = {}
    for i = (self.page - 1) * per + 1, math.min(#senses, self.page * per) do
        local checked = lookup.id == self.chosen_lookup_id and i == self.chosen
        local s = senses[i]
        local text = i .. ". " .. s.text .. (s.pos and ("  [" .. s.pos .. "]") or "")
        local row = Kit.markRow{ width = cw, mark = Kit.radio(checked), text = text, bold = checked, max_lines = 3,
            callback = function()
                self:onClose()
                if self.on_pick then self.on_pick(i) end
            end }
        rows[#rows + 1] = Kit.box(cw, row_h, row, "left")
    end
    return VerticalGroup:new{
        align = "left", header,
        Kit.box(w, avail, Kit.pad(Kit.rows(cw, rows), Kit.PAD, 0), "top"),
        self:pagerWidget(w),
    }
end

return Senses
