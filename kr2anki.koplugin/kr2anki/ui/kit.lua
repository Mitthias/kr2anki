--[[--
Small UI kit shared by every KR2Anki screen, built only from KOReader widgets.

* Sizes go through Screen:scaleBySize(), so layouts follow the panel's DPI.
  Kit.TAP is the minimum tap target: about 9 mm (110 px at 300 ppi).
* Black, dark gray, light gray, white. The main action is inverted (white on
  black). Every state carries a symbol or a word, never tone alone.
* No animations; progress is text.
--]]

local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InputContainer = require("ui/widget/container/inputcontainer")
local LeftContainer = require("ui/widget/container/leftcontainer")
local LineWidget = require("ui/widget/linewidget")
local OverlapGroup = require("ui/widget/overlapgroup")
local RightContainer = require("ui/widget/container/rightcontainer")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local TopContainer = require("ui/widget/container/topcontainer")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Screen = Device.screen

local Kit = {}

Kit.WHITE = Blitbuffer.COLOR_WHITE
Kit.BLACK = Blitbuffer.COLOR_BLACK
Kit.GREY_DARK = Blitbuffer.COLOR_GRAY_4  -- secondary text
Kit.GREY_LIGHT = Blitbuffer.COLOR_GRAY_9 -- hairlines, disabled
Kit.GREY_BG = Blitbuffer.COLOR_GRAY_E or Blitbuffer.COLOR_LIGHT_GRAY or Blitbuffer.COLOR_WHITE

function Kit.dp(n)
    return Screen:scaleBySize(n)
end

Kit.TAP = Screen:scaleBySize(59)
Kit.PAD = Screen:scaleBySize(16)
Kit.GAP = Screen:scaleBySize(8)

-- Status symbols (brief: Interface rules).
Kit.SYMBOL = {
    inbox = "○", ready = "●", anki = "✓", known = "—", discarded = "×", expression = "◆",
}
Kit.STATUS_NAME = {
    inbox = "Inbox", ready = "Ready", anki = "In Anki", known = "Known", discarded = "Discarded",
}

-- Fonts ---------------------------------------------------------------------
-- Interface: KOReader's UI font (with Noto Sans CJK fallbacks).
-- Book sentences: Noto Serif, falling back to the CJK fonts for CJK text.

Kit.SIZE = { title = 22, body = 18, small = 15, tiny = 13, word = 30, sentence = 19, big = 46 }

local face_cache = {}
local function face(name, size)
    local key = name .. "@" .. tostring(size)
    local f = face_cache[key]
    if f == nil then
        f = Font:getFace(name, size) or Font:getFace("cfont", size)
        face_cache[key] = f
    end
    return f
end

function Kit.ui(size) return face("cfont", size or Kit.SIZE.body) end
function Kit.uiBold(size) return face("smallinfofontbold", size or Kit.SIZE.body) end
function Kit.serif(size) return face("NotoSerif-Regular.ttf", size or Kit.SIZE.sentence) end

function Kit.lineHeight(f, line_height_em)
    return math.floor((1 + (line_height_em or 0.3)) * f.size + 0.5)
end

-- Primitives ----------------------------------------------------------------

function Kit.text(text, f, opts)
    opts = opts or {}
    return TextWidget:new{
        text = text,
        face = f or Kit.ui(),
        fgcolor = opts.fgcolor or Kit.BLACK,
        bold = opts.bold,
        max_width = opts.max_width,
        padding = opts.padding,
    }
end

function Kit.countLines(text, f, width, line_height)
    local tb = TextBoxWidget:new{ text = text, face = f, width = width, line_height = line_height or 0.3,
                                  for_measurement_only = true }
    local n = tb:getAllLineCount()
    tb:free()
    return n
end

-- Multi-line text clamped to max_lines (ellipsis on the last line).
function Kit.textbox(text, f, width, opts)
    opts = opts or {}
    local line_height = opts.line_height or 0.3
    local height
    if opts.max_lines then
        local lines = math.min(opts.max_lines, Kit.countLines(text, f, width, line_height))
        height = Kit.lineHeight(f, line_height) * math.max(1, lines)
    end
    return TextBoxWidget:new{
        text = text,
        face = f,
        width = width,
        height = height,
        height_adjust = height ~= nil,
        height_overflow_show_ellipsis = height ~= nil,
        line_height = line_height,
        alignment = opts.alignment or "left",
        fgcolor = opts.fgcolor or Kit.BLACK,
        bold = opts.bold,
        lang = opts.lang,
    }
end

-- Text with one bold range (KOReader's PTF markup in TextBoxWidget).
function Kit.boldRange(text, hs, he)
    if not hs or not he or he < hs then return text end
    return TextBoxWidget.PTF_HEADER .. text:sub(1, hs - 1) .. TextBoxWidget.PTF_BOLD_START
        .. text:sub(hs, he) .. TextBoxWidget.PTF_BOLD_END .. text:sub(he + 1)
end

function Kit.vspan(h) return VerticalSpan:new{ width = h } end
function Kit.hspan(w) return HorizontalSpan:new{ width = w } end

function Kit.hline(width, thickness, color)
    return LineWidget:new{
        dimen = Geom:new{ w = width, h = thickness or Kit.dp(1) },
        background = color or Kit.BLACK,
    }
end

function Kit.vline(height, thickness, color)
    return LineWidget:new{
        dimen = Geom:new{ w = thickness or Kit.dp(1), h = height },
        background = color or Kit.BLACK,
    }
end

-- Fixed-size box; align = "left" | "center" | "right" (vertically centred)
-- or "top" (top-left).
function Kit.box(w, h, child, align)
    local dimen = Geom:new{ w = w, h = h }
    if align == "top" then return TopContainer:new{ dimen = dimen, child } end
    if align == "left" then return LeftContainer:new{ dimen = dimen, child } end
    if align == "right" then return RightContainer:new{ dimen = dimen, child } end
    return CenterContainer:new{ dimen = dimen, child }
end

-- `left` aligned left and `right` aligned right inside `width`.
function Kit.spread(width, h, left, right)
    local group = OverlapGroup:new{
        dimen = Geom:new{ w = width, h = h },
        allow_mirroring = false,
        Kit.box(left:getSize().w, h, left, "left"),
    }
    if right then
        local r = Kit.box(right:getSize().w, h, right, "right")
        r.overlap_align = "right"
        table.insert(group, r)
    end
    return group
end

-- Padding around a widget.
function Kit.pad(child, h, v)
    return FrameContainer:new{
        bordersize = 0, margin = 0, padding = 0,
        padding_left = h or Kit.PAD, padding_right = h or Kit.PAD,
        padding_top = v or 0, padding_bottom = v or 0,
        child,
    }
end

-- Tap -----------------------------------------------------------------------

local Tap = InputContainer:extend{
    callback = nil,
    hold_callback = nil,
    enabled = true,
    no_feedback = false,
}

function Tap:init()
    local size = self[1]:getSize()
    self.dimen = Geom:new{ x = 0, y = 0, w = size.w, h = size.h }
    -- matched in onGesture: named ges_events would be re-dispatched to children
    self._tap = GestureRange:new{ ges = "tap", range = self.dimen }
    self._hold = GestureRange:new{ ges = "hold", range = self.dimen }
    self._hold_release = GestureRange:new{ ges = "hold_release", range = self.dimen }
end

function Tap:onGesture(ev)
    if self._tap:match(ev) then return self:onTapKit() end
    if self._hold:match(ev) then return self:onHoldKit() end
    if self._hold_release:match(ev) then return self:onHoldReleaseKit() end
end

function Tap:onTapKit()
    if not self.enabled or not self.callback then
        return self.enabled == false or nil
    end
    if not self.no_feedback and G_reader_settings:nilOrTrue("flash_ui") then
        local d = self.dimen
        UIManager:widgetInvert(self, d.x, d.y, d.w, d.h)
        UIManager:setDirty(nil, "fast", d)
        UIManager:forceRePaint()
        UIManager:yieldToEPDC()
        UIManager:widgetInvert(self, d.x, d.y, d.w, d.h)
        UIManager:setDirty(nil, "ui", d)
    end
    self.callback()
    return true
end

function Tap:onHoldKit()
    if self.enabled and self.hold_callback then
        self._hold_handled = true
        self.hold_callback()
        return true
    end
    self._hold_handled = nil
end

function Tap:onHoldReleaseKit()
    if self._hold_handled then
        self._hold_handled = nil
        return true
    end
end

function Kit.tap(child, callback, hold_callback, opts)
    opts = opts or {}
    return Tap:new{
        callback = callback,
        hold_callback = hold_callback,
        enabled = opts.enabled ~= false,
        no_feedback = opts.no_feedback,
        child,
    }
end

-- Buttons ---------------------------------------------------------------------
-- primary = inverted (white on black). Always at least Kit.TAP tall.

function Kit.button(opts)
    local h = math.max(opts.height or Kit.TAP, Kit.TAP)
    local w = opts.width
    local border = opts.primary and 0 or Kit.dp(1.5)
    local fg = opts.primary and Kit.WHITE or Kit.BLACK
    if opts.enabled == false then fg = Kit.GREY_LIGHT end
    local f = opts.bold == false and Kit.ui(opts.size or Kit.SIZE.body) or Kit.uiBold(opts.size or Kit.SIZE.body)
    local label = Kit.text(opts.text, f, {
        fgcolor = fg,
        max_width = w and (w - 2 * Kit.dp(8)) or nil,
    })
    w = w or (label:getSize().w + 2 * Kit.dp(18))
    local frame = FrameContainer:new{
        bordersize = border,
        radius = Kit.dp(6),
        padding = 0,
        margin = 0,
        background = (opts.primary and opts.enabled ~= false) and Kit.BLACK or Kit.WHITE,
        color = opts.enabled == false and Kit.GREY_LIGHT or Kit.BLACK,
        Kit.box(w - 2 * border, h - 2 * border, label),
    }
    return Kit.tap(frame, opts.callback, opts.hold_callback, { enabled = opts.enabled })
end

-- Underlined text link, Kit.TAP tall.
function Kit.link(text, callback, opts)
    opts = opts or {}
    local label = Kit.text(text, Kit.ui(opts.size or Kit.SIZE.small), {
        fgcolor = opts.enabled == false and Kit.GREY_LIGHT or Kit.BLACK,
        max_width = opts.max_width,
    })
    local lw = label:getSize().w
    local group = VerticalGroup:new{
        align = "left",
        label,
        Kit.hline(lw, Kit.dp(1), opts.enabled == false and Kit.GREY_LIGHT or Kit.BLACK),
    }
    return Kit.tap(Kit.box(lw + Kit.dp(4), opts.height or Kit.TAP, group, "left"), callback, nil,
        { enabled = opts.enabled })
end

-- Text-only tap target (e.g. "‹" back), Kit.TAP square at least.
function Kit.textButton(text, callback, opts)
    opts = opts or {}
    local label = Kit.text(text, opts.bold and Kit.uiBold(opts.size or Kit.SIZE.title) or Kit.ui(opts.size or Kit.SIZE.title),
        { fgcolor = opts.enabled == false and Kit.GREY_LIGHT or (opts.fgcolor or Kit.BLACK), max_width = opts.max_width })
    local w = math.max(Kit.TAP, label:getSize().w + 2 * Kit.dp(8))
    return Kit.tap(Kit.box(w, opts.height or Kit.TAP, label), callback, opts.hold_callback, { enabled = opts.enabled })
end

-- One full-width row of buttons, main action rightmost (bottom bar).
-- buttons = { {text, callback, primary, enabled}, … }
-- A button may carry `weight` (default 1) for a wider or narrower share.
function Kit.buttonRow(width, buttons, opts)
    opts = opts or {}
    local gap = Kit.dp(8)
    local n = #buttons
    local inner = width - 2 * Kit.PAD
    local total_weight = 0
    for _, b in ipairs(buttons) do total_weight = total_weight + (b.weight or 1) end
    local free = inner - (n - 1) * gap
    local used = 0
    local row = HorizontalGroup:new{ align = "center" }
    for i, b in ipairs(buttons) do
        local w = (i == n) and (free - used) or math.floor(free * (b.weight or 1) / total_weight)
        used = used + w
        table.insert(row, Kit.button{
            text = b.text, callback = b.callback, primary = b.primary, enabled = b.enabled,
            width = w, size = opts.size or (n >= 4 and Kit.SIZE.small or Kit.SIZE.body),
        })
        if i < n then table.insert(row, Kit.hspan(gap)) end
    end
    return row
end

-- Bottom bar: rule above, padded row of buttons.
function Kit.bottomBar(width, buttons, opts)
    local row = Kit.buttonRow(width, buttons, opts)
    local v = Kit.dp(12)
    return VerticalGroup:new{
        align = "left",
        Kit.hline(width, Kit.dp(2)),
        Kit.vspan(v),
        Kit.pad(row, Kit.PAD, 0),
        Kit.vspan(v),
    }
end

function Kit.bottomBarHeight()
    return Kit.dp(2) + 2 * Kit.dp(12) + Kit.TAP
end

-- Header ------------------------------------------------------------------------
-- [‹] Title ………… [right], 2dp black rule below.

Kit.HEADER_H = Screen:scaleBySize(56)

function Kit.header(opts)
    local width = opts.width
    local h = math.max(Kit.HEADER_H, Kit.TAP)
    local left = HorizontalGroup:new{ align = "center" }
    if opts.on_back then
        table.insert(left, Kit.textButton(opts.back_symbol or "‹", opts.on_back, { size = Kit.SIZE.title + 6 }))
    else
        table.insert(left, Kit.hspan(Kit.PAD))
    end
    local right = opts.right
    local right_w = right and right:getSize().w or 0
    local title_max = width - left:getSize().w - right_w - Kit.PAD
    local title = Kit.text(opts.title, Kit.uiBold(opts.title_size or Kit.SIZE.title), { max_width = title_max })
    local lg = HorizontalGroup:new{ align = "center", left, title }
    local row = Kit.spread(width, h, lg, right and HorizontalGroup:new{ align = "center", right, Kit.hspan(Kit.dp(10)) })
    return VerticalGroup:new{
        align = "left",
        row,
        Kit.hline(width, Kit.dp(2)),
    }
end

function Kit.headerHeight()
    return math.max(Kit.HEADER_H, Kit.TAP) + Kit.dp(2)
end

-- Rows ---------------------------------------------------------------------------

-- Small caps-like section label: "STATUS"
function Kit.sectionLabel(text, width, right)
    local label = Kit.text(text:upper(), Kit.uiBold(Kit.SIZE.tiny), { fgcolor = Kit.BLACK })
    local h = math.max(Kit.dp(34), right and right:getSize().h or 0)
    return Kit.spread(width, h, label, right)
end

--[[--
Full-width tappable row:  [symbol] label / sub ……… value ›
opts = { width, symbol, text, sub, value, chevron, callback, hold_callback, face, height, bold }
--]]
function Kit.row(opts)
    local width = opts.width
    local tappable = opts.callback or opts.hold_callback
    -- tap targets are at least Kit.TAP; plain information rows can be compact
    local h = tappable and math.max(opts.height or Kit.TAP, Kit.TAP) or (opts.height or Kit.dp(44))
    local left = HorizontalGroup:new{ align = "center" }
    local used = 0
    if opts.symbol then
        local sym = Kit.box(Kit.dp(34), h, Kit.text(opts.symbol, Kit.ui(Kit.SIZE.title), {}), "left")
        table.insert(left, sym)
        used = used + Kit.dp(34)
    end
    local right = HorizontalGroup:new{ align = "center" }
    if opts.value then
        table.insert(right, Kit.text(tostring(opts.value), Kit.uiBold(Kit.SIZE.body), {}))
    end
    if opts.chevron ~= false and opts.callback then
        table.insert(right, Kit.hspan(Kit.dp(12)))
        table.insert(right, Kit.text("›", Kit.ui(Kit.SIZE.title), {}))
    end
    local right_w = right:getSize().w
    local label_w = width - used - right_w - Kit.dp(12)
    local label
    if opts.sub then
        label = VerticalGroup:new{
            align = "left",
            Kit.text(opts.text, opts.face or (opts.bold and Kit.uiBold() or Kit.ui()), { max_width = label_w }),
            Kit.text(opts.sub, Kit.ui(Kit.SIZE.tiny), { fgcolor = Kit.GREY_DARK, max_width = label_w }),
        }
    else
        label = Kit.text(opts.text, opts.face or (opts.bold and Kit.uiBold() or Kit.ui()), { max_width = label_w })
    end
    table.insert(left, label)
    local content = Kit.spread(width, h, left, right_w > 0 and right or nil)
    if not opts.callback and not opts.hold_callback then return content end
    return Kit.tap(content, opts.callback, opts.hold_callback)
end

-- Rows separated by light hairlines.
function Kit.rows(width, list)
    local g = VerticalGroup:new{ align = "left" }
    for i, w in ipairs(list) do
        table.insert(g, w)
        if i < #list then table.insert(g, Kit.hline(width, Kit.dp(1), Kit.GREY_LIGHT)) end
    end
    return g
end

-- Radio and check marks --------------------------------------------------------

function Kit.radio(checked, size)
    size = size or Kit.dp(24)
    local b = Kit.dp(2)
    local inner = Kit.vspan(0)
    if checked then
        local dot = size - 2 * b - 2 * Kit.dp(4)
        inner = FrameContainer:new{
            bordersize = 0, padding = 0, margin = 0,
            radius = math.floor(dot / 2),
            background = Kit.BLACK,
            Kit.box(dot, dot, Kit.vspan(0)),
        }
    end
    return FrameContainer:new{
        bordersize = b, padding = 0, margin = 0,
        radius = math.floor(size / 2),
        background = Kit.WHITE,
        Kit.box(size - 2 * b, size - 2 * b, inner),
    }
end

function Kit.checkbox(checked, size)
    size = size or Kit.dp(24)
    local mark = checked and Kit.text("✓", Kit.uiBold(Kit.SIZE.small), { fgcolor = Kit.WHITE, padding = 0 }) or Kit.vspan(0)
    return FrameContainer:new{
        bordersize = Kit.dp(2), padding = 0, margin = 0,
        radius = Kit.dp(3),
        background = checked and Kit.BLACK or Kit.WHITE,
        Kit.box(size - 2 * Kit.dp(2), size - 2 * Kit.dp(2), mark),
    }
end

-- [mark] text (up to max_lines lines), full width, at least Kit.TAP tall.
function Kit.markRow(opts)
    local width = opts.width
    local mark_w = opts.mark:getSize().w + Kit.dp(14)
    local text_w = width - mark_w
    local tb = Kit.textbox(opts.text, opts.bold and Kit.uiBold(opts.size or Kit.SIZE.body) or Kit.ui(opts.size or Kit.SIZE.body),
        text_w, { max_lines = opts.max_lines or 2 })
    local h = math.max(Kit.TAP, tb:getSize().h + 2 * Kit.dp(10))
    local row = HorizontalGroup:new{
        align = "center",
        Kit.box(mark_w, h, opts.mark, "left"),
        Kit.box(text_w, h, tb, "left"),
    }
    return Kit.tap(row, opts.callback, opts.hold_callback)
end

-- Bordered box -------------------------------------------------------------------

function Kit.bordered(child, opts)
    opts = opts or {}
    return FrameContainer:new{
        bordersize = opts.border or Kit.dp(1.5),
        radius = Kit.dp(6),
        padding = opts.padding or Kit.dp(12),
        margin = 0,
        background = opts.background or Kit.WHITE,
        color = opts.color or Kit.BLACK,
        child,
    }
end

-- Field box: label above, content in a bordered box (tap to edit).
function Kit.field(opts)
    local width = opts.width
    local inner_w = width - 2 * (Kit.dp(1.5) + Kit.dp(12))
    local empty = opts.value == nil or opts.value == ""
    local content = Kit.textbox(empty and (opts.placeholder or "Tap to add") or opts.value,
        opts.big and Kit.uiBold(Kit.SIZE.title + 2) or Kit.ui(Kit.SIZE.body), inner_w,
        { max_lines = opts.max_lines or 2, fgcolor = empty and Kit.GREY_DARK or Kit.BLACK })
    local box = Kit.bordered(Kit.box(inner_w, math.max(content:getSize().h, Kit.TAP - 2 * (Kit.dp(1.5) + Kit.dp(12))), content, "left"))
    local label = HorizontalGroup:new{ align = "center",
        Kit.text(opts.label:upper(), Kit.uiBold(Kit.SIZE.tiny), {}) }
    if opts.label_note then
        table.insert(label, Kit.hspan(Kit.dp(6)))
        table.insert(label, Kit.text("· " .. opts.label_note, Kit.ui(Kit.SIZE.tiny), { fgcolor = Kit.GREY_DARK }))
    end
    return VerticalGroup:new{
        align = "left",
        Kit.box(width, Kit.dp(30), label, "left"),
        Kit.tap(box, opts.callback),
    }
end

-- Empty state: big symbol in a circle, title, text.
function Kit.emptyState(width, symbol, title, text, extra)
    local circle_size = Kit.dp(76)
    local circle = FrameContainer:new{
        bordersize = Kit.dp(2), padding = 0, margin = 0,
        radius = math.floor(circle_size / 2),
        background = Kit.WHITE,
        Kit.box(circle_size - 2 * Kit.dp(2), circle_size - 2 * Kit.dp(2), Kit.text(symbol, Kit.ui(Kit.SIZE.big - 10), {})),
    }
    local g = VerticalGroup:new{
        align = "center",
        circle,
        Kit.vspan(Kit.dp(18)),
        Kit.textbox(title, Kit.uiBold(Kit.SIZE.title), width - 2 * Kit.PAD, { alignment = "center" }),
        Kit.vspan(Kit.dp(10)),
        Kit.textbox(text, Kit.ui(Kit.SIZE.body), width - 2 * Kit.PAD, { alignment = "center", fgcolor = Kit.GREY_DARK }),
    }
    if extra then
        table.insert(g, Kit.vspan(Kit.dp(16)))
        table.insert(g, Kit.textbox(extra, Kit.ui(Kit.SIZE.small), width - 2 * Kit.PAD, { alignment = "center" }))
    end
    return g
end

-- Pager: ‹  2 / 9  ›  (tap the label to type a page)
Kit.PAGER_H = Screen:scaleBySize(59) + Screen:scaleBySize(1)

function Kit.pager(opts)
    local width = opts.width
    local h = Kit.TAP
    local page, pages = opts.page, math.max(opts.pages or 1, 1)
    local back = Kit.textButton("‹", opts.on_prev, { enabled = page > 1, size = Kit.SIZE.title + 6 })
    local fwd = Kit.textButton("›", opts.on_next, { enabled = page < pages, size = Kit.SIZE.title + 6 })
    local label = Kit.text(string.format("%d / %d", page, pages), Kit.ui(Kit.SIZE.body))
    local label_tap = Kit.tap(Kit.box(label:getSize().w + Kit.dp(40), h, label), pages > 1 and opts.on_goto or nil,
        nil, { no_feedback = pages <= 1 })
    local bw = Kit.box(back:getSize().w + Kit.PAD, h, back, "right")
    local fw = Kit.box(fwd:getSize().w + Kit.PAD, h, fwd, "left")
    fw.overlap_align = "right"
    local mid = Kit.box(width, h, label_tap)
    return VerticalGroup:new{
        align = "left",
        Kit.hline(width, Kit.dp(1)),
        OverlapGroup:new{
            dimen = Geom:new{ w = width, h = h },
            allow_mirroring = false,
            mid, bw, fw,
        },
    }
end

-- Columns --------------------------------------------------------------------------
-- build(col_width) returns a list of blocks. One column when they fit in
-- `avail`, otherwise they flow into two columns (landscape, small screens).
function Kit.flowColumns(width, avail, build)
    local blocks = build(width)
    local total = 0
    for _, b in ipairs(blocks) do total = total + b:getSize().h end
    if total <= avail then
        local g = VerticalGroup:new{ align = "left" }
        for _, b in ipairs(blocks) do table.insert(g, b) end
        return g
    end
    local col = math.floor((width - Kit.PAD) / 2)
    blocks = build(col)
    local left = VerticalGroup:new{ align = "left" }
    local right = VerticalGroup:new{ align = "left" }
    local used, target = 0, left
    for _, b in ipairs(blocks) do
        local bh = b:getSize().h
        if target == left and used + bh > avail and #left > 0 then target = right end
        table.insert(target, b)
        used = used + bh
    end
    return HorizontalGroup:new{ align = "top", left, Kit.hspan(Kit.PAD), right }
end

-- Formatting ----------------------------------------------------------------------

function Kit.relativeTime(ts)
    if not ts or ts == 0 then return "" end
    local now = os.time()
    local t, n = os.date("*t", ts), os.date("*t", now)
    local hm = string.format("%02d:%02d", t.hour, t.min)
    if t.year == n.year and t.yday == n.yday then return "today, " .. hm end
    if now - ts < 2 * 86400 and (n.yday - t.yday == 1 or (n.yday == 1 and t.month == 12 and t.day == 31)) then
        return "yesterday, " .. hm
    end
    if t.year == n.year then return os.date("%b %d", ts) end
    return os.date("%Y-%m-%d", ts)
end

-- Book title in the style of its language: 『こころ』, 《活着》, The Great Gatsby
function Kit.bookTitle(title, lang)
    if not title or title == "" then return nil end
    if lang == "ja" then return "『" .. title .. "』" end
    if lang == "zh" then return "《" .. title .. "》" end
    return title
end

return Kit
