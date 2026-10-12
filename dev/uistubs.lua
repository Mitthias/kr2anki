-- Fake KOReader UI layer: enough layout + event semantics to render the
-- plugin's screens, find widgets by text, and dispatch taps/swipes.
-- Mirrors KOReader's real behaviour where it matters:
--   * WidgetContainer:handleEvent propagates to children first
--   * Horizontal/VerticalGroup cache their size on first getSize()
--   * LeftContainer centres vertically; TopContainer does not
--   * FrameContainer:getSize ignores width/height fields

local W, H = tonumber(os.getenv("SCREEN_W") or 824), tonumber(os.getenv("SCREEN_H") or 1648)
local DPI_SCALE = tonumber(os.getenv("DPI_SCALE") or 1.85) -- ~296 dpi / 160

local P = package.preload
local log = {}
_G.UI_LOG = log

-- Geometry ----------------------------------------------------------------
local Geom = {}
Geom.__index = Geom
function Geom:new(o) o = o or {}; o.x = o.x or 0; o.y = o.y or 0; o.w = o.w or 0; o.h = o.h or 0; return setmetatable(o, Geom) end
function Geom:contains(p)
    return p.x >= self.x and p.y >= self.y and p.x < self.x + self.w and p.y < self.y + self.h
end
function Geom:copy() return Geom:new{ x = self.x, y = self.y, w = self.w, h = self.h } end
P["ui/geometry"] = function() return Geom end

P["ui/gesturerange"] = function()
    local GR = {}
    GR.__index = GR
    function GR:new(o) return setmetatable(o or {}, GR) end
    function GR:match(ev)
        if ev.ges ~= self.ges then return false end
        local r = type(self.range) == "function" and self.range() or self.range
        if r and not r:contains(ev.pos) then return false end
        return true
    end
    return GR
end

P["ui/event"] = function()
    local E = {}
    function E:new(name, ...) return { handler = "on" .. name, args = { ... }, name = name } end
    return E
end

P["ui/bidi"] = function()
    return { flipDirectionIfMirroredUILayout = function(d) return d end, mirroredUILayout = function() return false end }
end

-- Settings ----------------------------------------------------------------
local function mkSettings(data)
    local S = { data = data or {} }
    function S:readSetting(k, default) local v = self.data[k]; if v == nil then if default ~= nil then self.data[k] = default end; return default end; return v end
    function S:saveSetting(k, v) self.data[k] = v; return self end
    function S:isTrue(k) return self.data[k] == true end
    function S:nilOrTrue(k) return self.data[k] == nil or self.data[k] == true end
    function S:isFalse(k) return self.data[k] == false end
    function S:has(k) return self.data[k] ~= nil end
    function S:makeTrue(k) self.data[k] = true end
    function S:flush() end
    return S
end
_G.G_reader_settings = mkSettings({ flash_ui = true })
P["luasettings"] = function() return { open = function(_, path) return mkSettings() end } end

-- Device / screen -----------------------------------------------------------
local Screen = {
    getWidth = function() return W end,
    getHeight = function() return H end,
    scaleBySize = function(_, n) return math.floor(n * DPI_SCALE + 0.5) end,
    getDPI = function() return 296 end,
    getSize = function() return { w = W, h = H } end,
}
local clipboard = {}
_G.CLIPBOARD = clipboard
P["device"] = function()
    return {
        screen = Screen,
        isTouchDevice = function() return true end,
        hasKeys = function() return true end,
        canShareText = function() return true end,
        doShareText = function(_, text) log[#log + 1] = "share:" .. text end,
        input = {
            group = { Back = { "Back" }, PgFwd = { "RPgFwd" }, PgBack = { "RPgBack" } },
            setClipboardText = function(t) clipboard.text = t end,
        },
    }
end

P["ffi/blitbuffer"] = function()
    local c = function(v) return { v = v, invert = function(self) return self end } end
    return { COLOR_WHITE = c(255), COLOR_BLACK = c(0), COLOR_GRAY_4 = c(0x44), COLOR_GRAY_9 = c(0x99), COLOR_GRAY_E = c(0xEE) }
end

P["ui/font"] = function()
    return { getFace = function(_, name, size) return { name = name, size = Screen:scaleBySize(size or 20) } end }
end

-- Widget base ----------------------------------------------------------------
local Widget = {}
Widget.__index = Widget
function Widget:extend(sub)
    sub = sub or {}
    sub.__index = sub
    return setmetatable(sub, self)
end
function Widget:new(o)
    o = o or {}
    setmetatable(o, self)
    if o._init then o:_init() end
    if o.init then o:init() end
    return o
end
function Widget:getSize() return self.dimen or Geom:new() end
function Widget:paintTo(bb, x, y)
    local s = self:getSize()
    self.dimen = Geom:new{ x = x, y = y, w = s.w, h = s.h }
    self._painted = true
end
function Widget:handleEvent(ev)
    if self[ev.handler] then return self[ev.handler](self, unpack(ev.args)) end
end
function Widget:free() end

local WidgetContainer = Widget:extend{}
function WidgetContainer:getSize()
    if self.dimen then return self.dimen end
    if self[1] then return self[1]:getSize() end
    return Geom:new()
end
function WidgetContainer:paintTo(bb, x, y)
    if self.dimen then self.dimen.x, self.dimen.y = x, y end
    self._painted = true
    if self[1] then self[1]:paintTo(bb, x, y) end
end
function WidgetContainer:propagateEvent(ev)
    for _, w in ipairs(self) do
        if w:handleEvent(ev) then return true end
    end
    return false
end
function WidgetContainer:handleEvent(ev)
    if self:propagateEvent(ev) then return true end
    return Widget.handleEvent(self, ev)
end
P["ui/widget/widget"] = function() return Widget end
P["ui/widget/container/widgetcontainer"] = function() return WidgetContainer end

local InputContainer = WidgetContainer:extend{}
function InputContainer:_init()
    self.key_events = self.key_events or {}
    self.ges_events = self.ges_events or {}
end
function InputContainer:paintTo(bb, x, y)
    if not self.dimen then
        local s = self[1]:getSize()
        self.dimen = Geom:new{ x = x, y = y, w = s.w, h = s.h }
    else
        self.dimen.x, self.dimen.y = x, y
    end
    self._painted = true
    self[1]:paintTo(bb, x, y)
end
function InputContainer:onGesture(ev)
    local Event = require("ui/event")
    for name, seq in pairs(self.ges_events or {}) do
        for _, r in ipairs(seq) do
            if r:match(ev) then
                if self:handleEvent(Event:new(name, seq.args, ev)) then return true end
            end
        end
    end
end
P["ui/widget/container/inputcontainer"] = function() return InputContainer end

local function boxContainer(kind)
    local C = WidgetContainer:extend{}
    function C:paintTo(bb, x, y)
        local cs = self[1]:getSize()
        self.dimen.x, self.dimen.y = x, y
        self._painted = true
        local cx, cy = x, y
        if kind == "center" then
            cx = x + math.floor((self.dimen.w - cs.w) / 2); cy = y + math.floor((self.dimen.h - cs.h) / 2)
        elseif kind == "left" then
            cy = y + math.floor((self.dimen.h - cs.h) / 2)
        elseif kind == "right" then
            cx = x + self.dimen.w - cs.w; cy = y + math.floor((self.dimen.h - cs.h) / 2)
        end
        self[1]:paintTo(bb, cx, cy)
        if cs.w > self.dimen.w + 1 or cs.h > self.dimen.h + 1 then
            _G.OVERFLOWS = _G.OVERFLOWS or {}
            table.insert(_G.OVERFLOWS, string.format("%s box %dx%d < content %dx%d", kind, self.dimen.w, self.dimen.h, cs.w, cs.h))
        end
    end
    return C
end
P["ui/widget/container/centercontainer"] = function() return boxContainer("center") end
P["ui/widget/container/leftcontainer"] = function() return boxContainer("left") end
P["ui/widget/container/rightcontainer"] = function() return boxContainer("right") end
P["ui/widget/container/topcontainer"] = function() return boxContainer("top") end

local FrameContainer = WidgetContainer:extend{ margin = 0, bordersize = 2, padding = 5 }
function FrameContainer:getSize()
    local cs = self[1]:getSize()
    local pl = self.padding_left or self.padding
    local pr = self.padding_right or self.padding
    local pt = self.padding_top or self.padding
    local pb = self.padding_bottom or self.padding
    return Geom:new{ w = cs.w + 2 * (self.margin + self.bordersize) + pl + pr, h = cs.h + 2 * (self.margin + self.bordersize) + pt + pb }
end
function FrameContainer:paintTo(bb, x, y)
    local s = self:getSize()
    self.dimen = Geom:new{ x = x, y = y, w = s.w, h = s.h }
    self._painted = true
    self[1]:paintTo(bb, x + self.margin + self.bordersize + (self.padding_left or self.padding),
        y + self.margin + self.bordersize + (self.padding_top or self.padding))
end
P["ui/widget/container/framecontainer"] = function() return FrameContainer end

local HorizontalGroup = WidgetContainer:extend{ align = "center" }
function HorizontalGroup:getSize()
    if not self._size then
        local w, h = 0, 0
        for _, c in ipairs(self) do local s = c:getSize(); w = w + s.w; if s.h > h then h = s.h end end
        self._size = Geom:new{ w = w, h = h }
    end
    return self._size
end
function HorizontalGroup:paintTo(bb, x, y)
    local s = self:getSize()
    self.dimen = Geom:new{ x = x, y = y, w = s.w, h = s.h }
    self._painted = true
    local cx = x
    for _, c in ipairs(self) do
        local cs = c:getSize()
        local cy = y
        if self.align == "center" then cy = y + math.floor((s.h - cs.h) / 2) elseif self.align == "bottom" then cy = y + s.h - cs.h end
        c:paintTo(bb, cx, cy)
        cx = cx + cs.w
    end
end
P["ui/widget/horizontalgroup"] = function() return HorizontalGroup end

local VerticalGroup = WidgetContainer:extend{ align = "center" }
function VerticalGroup:getSize()
    if not self._size then
        local w, h = 0, 0
        for _, c in ipairs(self) do local s = c:getSize(); h = h + s.h; if s.w > w then w = s.w end end
        self._size = Geom:new{ w = w, h = h }
    end
    return self._size
end
function VerticalGroup:paintTo(bb, x, y)
    local s = self:getSize()
    self.dimen = Geom:new{ x = x, y = y, w = s.w, h = s.h }
    self._painted = true
    local cy = y
    for _, c in ipairs(self) do
        local cs = c:getSize()
        local cx = x
        if self.align == "center" then cx = x + math.floor((s.w - cs.w) / 2) elseif self.align == "right" then cx = x + s.w - cs.w end
        c:paintTo(bb, cx, cy)
        cy = cy + cs.h
    end
end
P["ui/widget/verticalgroup"] = function() return VerticalGroup end

local OverlapGroup = WidgetContainer:extend{}
function OverlapGroup:init()
    local w, h = 0, 0
    for _, c in ipairs(self) do local s = c:getSize(); if s.w > w then w = s.w end; if s.h > h then h = s.h end end
    if self.dimen then w = self.dimen.w or w; h = self.dimen.h or h end
    self.dimen = Geom:new{ w = w, h = h }
end
function OverlapGroup:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    self._painted = true
    for _, c in ipairs(self) do
        local cs = c:getSize()
        if c.overlap_align == "right" then c:paintTo(bb, x + self.dimen.w - cs.w, y)
        elseif c.overlap_align == "center" then c:paintTo(bb, x + math.floor((self.dimen.w - cs.w) / 2), y)
        else c:paintTo(bb, x, y) end
    end
end
P["ui/widget/overlapgroup"] = function() return OverlapGroup end

local function span(field)
    local S = Widget:extend{}
    function S:getSize() return field == "w" and Geom:new{ w = self.width or 0, h = 0 } or Geom:new{ w = 0, h = self.width or 0 } end
    return S
end
P["ui/widget/horizontalspan"] = function() return span("w") end
P["ui/widget/verticalspan"] = function() return span("h") end

local LineWidget = Widget:extend{}
function LineWidget:getSize() return Geom:new{ w = self.dimen.w, h = self.dimen.h } end
function LineWidget:paintTo(bb, x, y) self.dimen.x, self.dimen.y = x, y end
P["ui/widget/linewidget"] = function() return LineWidget end

-- Text: ~0.55em per char (CJK 1em), height 1.3em.
local function textWidth(text, size)
    local w = 0
    for ch in tostring(text):gmatch("[%z\1-\127\194-\244][\128-\191]*") do
        w = w + (#ch >= 3 and size or size * 0.55)
    end
    return math.floor(w + 0.5)
end
_G.textWidth = textWidth

local TextWidget = Widget:extend{}
function TextWidget:init()
    local size = self.face.size
    local pad = self.padding or math.floor(2 * DPI_SCALE)
    local w = textWidth(self.text, size)
    self._truncated = false
    if self.max_width and w > self.max_width then w = self.max_width; self._truncated = true end
    if w < 0 then error("negative width for text " .. tostring(self.text)) end
    self._w, self._h = w, math.floor(size * 1.3) + 2 * pad
end
function TextWidget:getSize() return Geom:new{ w = self._w, h = self._h } end
function TextWidget:isTruncated() return self._truncated end
P["ui/widget/textwidget"] = function() return TextWidget end

local TextBoxWidget = InputContainer:extend{
    PTF_HEADER = "\u{FFF1}", PTF_BOLD_START = "\u{FFF2}", PTF_BOLD_END = "\u{FFF3}",
}
function TextBoxWidget:init()
    if type(self.text) == "string" and self.text:sub(1, 3) == self.PTF_HEADER then
        local raw = self.text:sub(4)
        local bs = raw:find(self.PTF_BOLD_START, 1, true)
        local be = raw:find(self.PTF_BOLD_END, 1, true)
        self.text = raw:gsub(self.PTF_BOLD_START, ""):gsub(self.PTF_BOLD_END, "")
        if bs and be then
            self._bold_text = raw:sub(bs + 3, be - 1)
        end
    end
    if self.text:find("\239\191[\177-\179]") then error("PTF marker left in text") end
    if not self.width or self.width <= 0 then error("TextBoxWidget needs a positive width, got " .. tostring(self.width)) end
    local size = self.face.size
    self.line_height_px = math.floor((1 + (self.line_height or 0.3)) * size + 0.5)
    -- naive wrap by paragraph
    local lines = 0
    for para in (tostring(self.text) .. "\n"):gmatch("(.-)\n") do
        lines = lines + math.max(1, math.ceil(textWidth(para, size) / self.width))
    end
    self._lines = lines
    local h = lines * self.line_height_px
    if self.height then
        h = self.height_adjust and math.floor(self.height / self.line_height_px) * self.line_height_px or self.height
        if h <= 0 then error("TextBoxWidget height too small: " .. tostring(self.height)) end
    end
    self._h = h
end
function TextBoxWidget:getSize() return Geom:new{ w = self.width, h = self._h } end
function TextBoxWidget:getAllLineCount() return self._lines end
function TextBoxWidget:free() end
function TextBoxWidget:paintTo(bb, x, y) self.dimen = Geom:new{ x = x, y = y, w = self.width, h = self._h }; self._painted = true end
P["ui/widget/textboxwidget"] = function() return TextBoxWidget end

local IconWidget = Widget:extend{}
function IconWidget:getSize() return Geom:new{ w = self.width, h = self.height } end
P["ui/widget/iconwidget"] = function() return IconWidget end

-- UIManager -------------------------------------------------------------------
local UIManager = { stack = {}, ticks = {} }
_G.UIM = UIManager
function UIManager:show(w, refresh)
    table.insert(self.stack, w)
    if w.handleEvent then w:handleEvent(require("ui/event"):new("Show")) end
    log[#log + 1] = "show:" .. tostring(w.name or w.__kind or "?") .. ":" .. tostring(refresh)
end
function UIManager:close(w, refresh)
    for i = #self.stack, 1, -1 do
        if self.stack[i] == w then table.remove(self.stack, i); break end
    end
    log[#log + 1] = "close:" .. tostring(w.name or w.__kind or "?")
end
function UIManager:setDirty(w, t) self.dirty = (self.dirty or 0) + 1 end
function UIManager:nextTick(f) table.insert(self.ticks, f) end
function UIManager:scheduleIn(_, f) table.insert(self.ticks, f) end
function UIManager:runTicks() while #self.ticks > 0 do table.remove(self.ticks, 1)() end end
function UIManager:forceRePaint() end
function UIManager:yieldToEPDC() end
function UIManager:widgetInvert() end
function UIManager:top() return self.stack[#self.stack] end
P["ui/uimanager"] = function() return UIManager end

-- Dialog stubs: record and expose buttons ---------------------------------------
local function dialog(kind)
    local D = Widget:extend{ __kind = kind }
    function D:init() _G["LAST_" .. kind] = self end
    function D:getInputText() return self._input or self.input end
    function D:onShowKeyboard() end
    function D:addTextToInput() end
    return D
end
for _, k in ipairs({ "buttondialog", "confirmbox", "infomessage", "inputdialog", "textviewer",
                     "datetimewidget", "pathchooser", "button" }) do
    P["ui/widget/" .. k] = function() return dialog(k) end
end
P["ui/widget/notification"] = function()
    return { SOURCE_ALWAYS_SHOW = 0x8000, notify = function(_, t) log[#log + 1] = "notify:" .. t; _G.LAST_NOTIFY = t end }
end
P["ui/widget/touchmenu"] = function()
    local TM = Widget:extend{ __kind = "touchmenu" }
    function TM:init() _G.LAST_touchmenu = self end
    return TM
end
P["ui/trapper"] = function()
    return {
        wrap = function(_, f) f() end,
        info = function(_, t) log[#log + 1] = "trapper:" .. t; return true end,
        clear = function() end,
    }
end
P["version"] = function() return { getCurrentRevision = function() return "v2026.07.1-harness" end } end

-- press OK on a ConfirmBox
function _G.confirm(d)
    d = d or _G.LAST_confirmbox
    if not d then error("no confirm box") end
    _G.LAST_confirmbox = nil
    UIManager:close(d) -- ConfirmBox closes itself before ok_callback
    d.ok_callback()
    UIManager:runTicks()
end

-- button texts of a dialog
function _G.dialogButtons(d)
    local out = {}
    for _, row in ipairs(d.buttons or {}) do
        for _, b in ipairs(row) do out[#out + 1] = b.text end
    end
    return out
end

-- find & press a button in a ButtonDialog/InputDialog by text
function _G.pressDialogButton(d, text)
    for _, row in ipairs(d.buttons or {}) do
        for _, b in ipairs(row) do
            if b.text == text or (type(text) == "string" and tostring(b.text):find(text, 1, true)) then
                if b.enabled == false then error("button disabled: " .. text) end
                b.callback(); UIManager:runTicks(); return true
            end
        end
    end
    error("no dialog button " .. text)
end

-- Misc modules
_G.DISPATCHER_ACTIONS = {}
P["dispatcher"] = function() return { registerAction = function(_, name, v) _G.DISPATCHER_ACTIONS[name] = v end } end
P["readhistory"] = function() return { hist = {} } end
P["apps/filemanager/filemanagerbookinfo"] = function()
    return { extendProps = function(p, f) p = p or {}; p.display_title = p.title or f; return p end }
end
P["ui/widget/booklist"] = function() return { setBookInfoCacheProperty = function() end } end

-- Tree helpers ------------------------------------------------------------------
local function walk(w, fn, depth)
    depth = depth or 0
    if type(w) ~= "table" then return end
    if fn(w, depth) then return true end
    for _, c in ipairs(w) do
        if walk(c, fn, depth + 1) then return true end
    end
end
_G.walk = walk

-- Paint the top window at 0,0.
function _G.paintTop()
    local top = UIManager:top()
    top:paintTo(nil, 0, 0)
    return top
end

-- All painted TextWidget texts on the top window.
function _G.texts()
    local out = {}
    if not UIManager:top() then return out end
    paintTop()
    walk(UIManager:top(), function(w)
        local mt = getmetatable(w)
        if (mt == TextWidget or mt == TextBoxWidget) and w.dimen then table.insert(out, w.text) end
    end)
    return out
end

-- Tap the centre of the first painted TextWidget whose text matches.
function _G.tapText(pattern, nth)
    local top = paintTop()
    local found, count = nil, 0
    walk(top, function(w)
        local mt = getmetatable(w)
        if (mt == TextWidget or mt == TextBoxWidget) and w.dimen and tostring(w.text):find(pattern) then
            count = count + 1
            if count == (nth or 1) then found = w; return true end
        end
    end)
    if not found then error("text not found on screen: " .. pattern .. "\n  have: " .. table.concat(texts(), " | ")) end
    local d = found.dimen
    local pos = Geom:new{ x = d.x + math.floor(d.w / 2), y = d.y + math.floor(d.h / 2) }
    local Event = require("ui/event")
    local handled = top:handleEvent(Event:new("Gesture", { ges = "tap", pos = pos }))
    UIManager:runTicks()
    return handled
end

function _G.tapAt(x, y, ges)
    local top = paintTop()
    local Event = require("ui/event")
    local handled = top:handleEvent(Event:new("Gesture", { ges = ges or "tap", pos = Geom:new{ x = x, y = y } }))
    UIManager:runTicks()
    return handled
end

function _G.swipe(dir)
    local top = paintTop()
    local Event = require("ui/event")
    top:handleEvent(Event:new("Gesture", { ges = "swipe", direction = dir, pos = Geom:new{ x = W / 2, y = H / 2 } }))
    UIManager:runTicks()
end

-- Check that every painted widget lies inside the screen.
function _G.offscreen()
    local bad = {}
    walk(paintTop(), function(w)
        if w.dimen and w._painted and (w.dimen.x < 0 or w.dimen.y < 0 or w.dimen.x + w.dimen.w > W + 1 or w.dimen.y + w.dimen.h > H + 1) then
            if getmetatable(w) == TextWidget then
                table.insert(bad, string.format("%q at %d,%d %dx%d", tostring(w.text), w.dimen.x, w.dimen.y, w.dimen.w, w.dimen.h))
            end
        end
    end)
    return bad
end

return { W = W, H = H }
