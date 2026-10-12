--[[--
Every KOReader hook and network call goes through here: a failure is logged
with KOReader's logger and shown as a message, never a crash.
--]]

local Safe = {}

local function logger()
    local ok, l = pcall(require, "logger")
    return ok and l or { err = function(...) print(...) end, warn = function(...) print(...) end }
end

function Safe.message(text)
    local ok, UIManager = pcall(require, "ui/uimanager")
    if not ok then return end
    local InfoMessage = require("ui/widget/infomessage")
    UIManager:show(InfoMessage:new{ text = text })
end

-- Run fn(...) protected. On error: log, tell the user, return nil.
function Safe.run(what, fn, ...)
    local ok, a, b, c = xpcall(fn, debug.traceback, ...)
    if ok then return a, b, c end
    logger().err("KR2Anki:", what, "failed:", a)
    local msg = tostring(a):match("^[^\n]*") or tostring(a)
    msg = msg:gsub("^.-%.lua:%d+: ", "")
    Safe.message("KR2Anki: " .. what .. " failed.\n\n" .. msg)
    return nil
end

-- Wrap a callback so it is always protected.
function Safe.wrap(what, fn)
    return function(...)
        return Safe.run(what, fn, ...)
    end
end

function Safe.log(...)
    logger().warn("KR2Anki:", ...)
end

return Safe
