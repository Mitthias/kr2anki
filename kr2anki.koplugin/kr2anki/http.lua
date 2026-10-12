--[[--
HTTP POST transport for the AnkiConnect client (LuaSocket, through KOReader's
socketutil for timeouts). Returns { status, body } or nil, error.
--]]

local Http = {}

function Http.post(url, body, timeout)
    local http = require("socket.http")
    local ltn12 = require("ltn12")
    local socket = require("socket")
    local socketutil = require("socketutil")
    local sink = {}
    socketutil:set_timeout(timeout or 5, timeout or 5)
    local ok, code, _, status = pcall(function()
        return socket.skip(1, http.request{
            url = url,
            method = "POST",
            source = ltn12.source.string(body),
            sink = ltn12.sink.table(sink),
            headers = {
                ["Content-Type"] = "application/json",
                ["Content-Length"] = tostring(#body),
            },
        })
    end)
    socketutil:reset_timeout()
    if not ok then return nil, tostring(code) end
    if type(code) ~= "number" then
        -- LuaSocket returns the error string in place of the status code
        return nil, tostring(code or status or "no connection")
    end
    return { status = code, body = table.concat(sink) }
end

return Http
