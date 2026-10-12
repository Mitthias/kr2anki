--[[--
Base class for every full-screen view.

* Swipe west/east and the page-turn keys call onNextPage()/onPrevPage().
* Back (key, or "‹" in the header) calls onClose().
* Opening a screen does a full refresh (clears e-ink ghosting); updates
  inside a screen redraw with the cheaper "ui" refresh.
* Rotation rebuilds the layout from the new screen size.
--]]

local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local TopContainer = require("ui/widget/container/topcontainer")
local UIManager = require("ui/uimanager")
local Kit = require("kr2anki/ui/kit")
local Safe = require("kr2anki/safe")
local Screen = Device.screen

local BaseScreen = InputContainer:extend{
    covers_fullscreen = true,
    name = "kr2anki_screen",
    app = nil,
}

function BaseScreen:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    if Device:isTouchDevice() then
        self.ges_events = {
            Swipe = { GestureRange:new{ ges = "swipe", range = self.dimen } },
        }
    end
    if Device:hasKeys() then
        local Input = Device.input
        self.key_events = {
            Close = { { Input.group.Back } },
            NextPage = { { Input.group.PgFwd } },
            PrevPage = { { Input.group.PgBack } },
        }
    end
    if self.setup then Safe.run("open screen", self.setup, self) end
    self:rebuild()
end

-- Subclasses implement build(width, height) -> widget.
function BaseScreen:rebuild()
    local w, h = self.dimen.w, self.dimen.h
    local ok, content = xpcall(function() return self:build(w, h) end, debug.traceback)
    if not ok then
        require("logger").err("KR2Anki: screen build failed:", content)
        content = Kit.pad(Kit.textbox("KR2Anki could not draw this screen.\n\n" .. tostring(content):match("^[^\n]*"),
            Kit.ui(), w - 2 * Kit.PAD), Kit.PAD, Kit.PAD)
        content = require("ui/widget/verticalgroup"):new{
            align = "left",
            Kit.header{ width = w, title = "KR2Anki", on_back = function() self:onClose() end },
            content,
        }
    end
    self[1] = FrameContainer:new{
        bordersize = 0, padding = 0, margin = 0,
        background = Kit.WHITE,
        TopContainer:new{ dimen = Geom:new{ w = w, h = h }, content },
    }
end

function BaseScreen:refresh(full)
    self:rebuild()
    if self.app and self.app:topScreen() ~= self then return end
    UIManager:setDirty(self, function()
        return full and "flashui" or "ui", self.dimen
    end)
end

function BaseScreen:onScreenResize()
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    if self.ges_events and self.ges_events.Swipe then
        self.ges_events.Swipe[1].range = self.dimen
    end
    self:refresh(true)
end

function BaseScreen:onSwipe(_, ges)
    local BD = require("ui/bidi")
    local dir = BD.flipDirectionIfMirroredUILayout(ges.direction)
    if dir == "west" then
        self:onNextPage()
    elseif dir == "east" then
        self:onPrevPage()
    elseif dir ~= "north" and dir ~= "south" then
        UIManager:setDirty(nil, "full") -- diagonal swipe: manual full refresh
    end
    return true
end

-- Called when the screen above this one closes.
function BaseScreen:onRevealed()
    if self.onDataChanged then Safe.run("refresh", self.onDataChanged, self) end
    self:refresh()
end

-- Paging for list screens (they set self.page and self.pages).
function BaseScreen:goPage(p)
    if not self.pages then return end
    p = math.max(1, math.min(p, self.pages))
    if p ~= self.page then
        self.page = p
        self:refresh()
    end
end

function BaseScreen:onNextPage()
    if self.page then self:goPage(self.page + 1) end
    return true
end

function BaseScreen:onPrevPage()
    if self.page then self:goPage(self.page - 1) end
    return true
end

function BaseScreen:askPage()
    local InputDialog = require("ui/widget/inputdialog")
    local dialog
    dialog = InputDialog:new{
        title = string.format("Go to page (1–%d)", self.pages),
        input_type = "number",
        buttons = { {
            { text = "Cancel", id = "close", callback = function() UIManager:close(dialog) end },
            { text = "Go", is_enter_default = true, callback = function()
                local p = tonumber(dialog:getInputText())
                UIManager:close(dialog)
                if p then self:goPage(p) end
            end },
        } },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function BaseScreen:pagerWidget(width)
    return Kit.pager{
        width = width, page = self.page or 1, pages = self.pages or 1,
        on_prev = function() self:onPrevPage() end,
        on_next = function() self:onNextPage() end,
        on_goto = function() self:askPage() end,
    }
end

function BaseScreen:onClose()
    if self.app then
        self.app:closeScreen(self)
    else
        UIManager:close(self)
    end
    return true
end

return BaseScreen
