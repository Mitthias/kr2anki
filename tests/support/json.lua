-- Minimal rapidjson-compatible JSON codec for desktop tests:
-- encode/decode, json.null sentinel, json.array() marker for empty arrays.
local J = {}

J.null = setmetatable({}, { __tostring = function() return "null" end })

function J.array(t)
    t = t or {}
    return setmetatable(t, { __jsontype = "array" })
end

local function isArray(t)
    local mt = getmetatable(t)
    if mt and mt.__jsontype == "array" then return true end
    if next(t) == nil then return false end
    local n = 0
    for k in pairs(t) do
        if type(k) ~= "number" or k < 1 or k % 1 ~= 0 then return false end
        n = n + 1
    end
    return n == #t
end

local ESC = { ['"'] = '\\"', ["\\"] = "\\\\", ["\b"] = "\\b", ["\f"] = "\\f", ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t" }

local function encStr(s)
    return '"' .. s:gsub('[%c"\\]', function(c) return ESC[c] or string.format("\\u%04x", c:byte()) end) .. '"'
end

local function enc(v)
    local t = type(v)
    if v == nil or v == J.null then return "null" end
    if t == "boolean" then return tostring(v) end
    if t == "number" then
        if v % 1 == 0 and math.abs(v) < 2^53 then return string.format("%d", v) end
        return string.format("%.14g", v)
    end
    if t == "string" then return encStr(v) end
    if t == "table" then
        local parts = {}
        if isArray(v) then
            for i = 1, #v do parts[i] = enc(v[i]) end
            return "[" .. table.concat(parts, ",") .. "]"
        end
        local keys = {}
        for k in pairs(v) do keys[#keys + 1] = tostring(k) end
        table.sort(keys)
        for _, k in ipairs(keys) do
            local val = v[k]
            if val == nil then val = v[tonumber(k)] end
            parts[#parts + 1] = encStr(k) .. ":" .. enc(val)
        end
        return "{" .. table.concat(parts, ",") .. "}"
    end
    error("cannot encode " .. t)
end

function J.encode(v) return enc(v) end

local function utf8char(cp)
    if cp < 0x80 then return string.char(cp) end
    if cp < 0x800 then return string.char(0xC0 + math.floor(cp / 64), 0x80 + cp % 64) end
    if cp < 0x10000 then
        return string.char(0xE0 + math.floor(cp / 4096), 0x80 + math.floor(cp / 64) % 64, 0x80 + cp % 64)
    end
    return string.char(0xF0 + math.floor(cp / 262144), 0x80 + math.floor(cp / 4096) % 64,
        0x80 + math.floor(cp / 64) % 64, 0x80 + cp % 64)
end

function J.decode(s)
    local pos = 1
    local function ws() pos = s:find("[^ \t\r\n]", pos) or #s + 1 end
    local value
    local function str()
        pos = pos + 1
        local out = {}
        while true do
            local c = s:sub(pos, pos)
            if c == "" then error("unterminated string") end
            if c == '"' then pos = pos + 1 break end
            if c == "\\" then
                local e = s:sub(pos + 1, pos + 1)
                if e == "u" then
                    local cp = tonumber(s:sub(pos + 2, pos + 5), 16)
                    pos = pos + 6
                    if cp >= 0xD800 and cp <= 0xDBFF and s:sub(pos, pos + 1) == "\\u" then
                        local lo = tonumber(s:sub(pos + 2, pos + 5), 16)
                        cp = 0x10000 + (cp - 0xD800) * 0x400 + (lo - 0xDC00)
                        pos = pos + 6
                    end
                    out[#out + 1] = utf8char(cp)
                else
                    local map = { b = "\b", f = "\f", n = "\n", r = "\r", t = "\t" }
                    out[#out + 1] = map[e] or e
                    pos = pos + 2
                end
            else
                out[#out + 1] = c
                pos = pos + 1
            end
        end
        return table.concat(out)
    end
    function value()
        ws()
        local c = s:sub(pos, pos)
        if c == "{" then
            pos = pos + 1
            local t = {}
            ws()
            if s:sub(pos, pos) == "}" then pos = pos + 1 return t end
            while true do
                ws()
                if s:sub(pos, pos) ~= '"' then error("expected key at " .. pos) end
                local k = str()
                ws()
                if s:sub(pos, pos) ~= ":" then error("expected : at " .. pos) end
                pos = pos + 1
                t[k] = value()
                ws()
                local d = s:sub(pos, pos)
                pos = pos + 1
                if d == "}" then break end
                if d ~= "," then error("expected , at " .. pos) end
            end
            return t
        elseif c == "[" then
            pos = pos + 1
            local t = J.array({})
            ws()
            if s:sub(pos, pos) == "]" then pos = pos + 1 return t end
            while true do
                t[#t + 1] = value()
                ws()
                local d = s:sub(pos, pos)
                pos = pos + 1
                if d == "]" then break end
                if d ~= "," then error("expected , in array") end
            end
            return t
        elseif c == '"' then
            return str()
        elseif s:sub(pos, pos + 3) == "true" then pos = pos + 4 return true
        elseif s:sub(pos, pos + 4) == "false" then pos = pos + 5 return false
        elseif s:sub(pos, pos + 3) == "null" then pos = pos + 4 return J.null
        else
            local num = s:match("^-?%d+%.?%d*[eE]?[-+]?%d*", pos)
            if not num or num == "" then error("unexpected '" .. c .. "' at " .. pos) end
            pos = pos + #num
            return tonumber(num)
        end
    end
    local v = value()
    ws()
    if pos <= #s then error("trailing data at " .. pos) end
    return v
end

return J
