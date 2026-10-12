--[[--
Screen stack for the manager: Home → browse → items → review / export.
Screens are shown full screen; closing one reveals the one below, which
reloads its data.
--]]

local UIManager = require("ui/uimanager")
local Safe = require("kr2anki/safe")

local App = {}
App.__index = App

function App.new(host)
    return setmetatable({ host = host, stack = {} }, App)
end

function App:push(screen)
    screen.app = self
    table.insert(self.stack, screen)
    UIManager:show(screen, "flashui")
    return screen
end

-- Construct and push: app:open("kr2anki/screens/home", { … })
function App:open(module, opts)
    return Safe.run("open screen", function()
        local Screen = require(module)
        local o = opts or {}
        o.app = self
        o.host = self.host
        return self:push(Screen:new(o))
    end)
end

function App:topScreen()
    return self.stack[#self.stack]
end

function App:closeScreen(screen)
    for i = #self.stack, 1, -1 do
        if self.stack[i] == screen then
            table.remove(self.stack, i)
            break
        end
    end
    UIManager:close(screen, "flashui")
    local top = self:topScreen()
    if top then
        top:onRevealed()
    elseif self.host and self.host.onAppClosed then
        self.host:onAppClosed(self)
    end
end

-- Close every screen above `screen` (or all when nil).
function App:closeAbove(screen)
    while #self.stack > 0 and self:topScreen() ~= screen do
        local s = table.remove(self.stack)
        UIManager:close(s)
    end
    local top = self:topScreen()
    if top then top:onRevealed() end
end

function App:closeAll()
    while #self.stack > 0 do
        UIManager:close(table.remove(self.stack))
    end
    if self.host and self.host.onAppClosed then self.host:onAppClosed(self) end
end

return App
