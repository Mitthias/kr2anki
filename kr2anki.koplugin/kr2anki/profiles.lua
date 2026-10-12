--[[--
Dictionary profiles: data files that tell the parser how a dictionary lays
out its entries. Bundled profiles live in <plugin>/profiles; users can drop
more into <settings>/kr2anki_profiles without touching code.

Each file returns a plain table (see profiles/generic.lua for every field).
Files run in an empty environment, so they can only hold data.
Pure Lua (file access through io only).
--]]

local Parse = require("kr2anki/dictparse")
local Lang = require("kr2anki/lang")

local M = {}

local function loadFile(path)
    local f = io.open(path, "r")
    if not f then return nil, "cannot open " .. path end
    local src = f:read("*a")
    f:close()
    local chunk, err = loadstring(src, "=" .. path)
    if not chunk then return nil, err end
    setfenv(chunk, {})
    local ok, res = pcall(chunk)
    if not ok then return nil, res end
    if type(res) ~= "table" or type(res.id) ~= "string" then
        return nil, path .. ": a profile must return a table with an id"
    end
    return res
end
M.loadFile = loadFile

local function listLua(dir)
    local out = {}
    local ok, lfs = pcall(require, "libs/libkoreader-lfs")
    if not ok then ok, lfs = pcall(require, "lfs") end
    if ok and lfs and lfs.attributes(dir, "mode") == "directory" then
        for name in lfs.dir(dir) do
            if name:match("%.lua$") then out[#out + 1] = dir .. "/" .. name end
        end
    else
        local p = io.popen('ls "' .. dir .. '" 2>/dev/null')
        if p then
            for name in p:lines() do
                if name:match("%.lua$") then out[#out + 1] = dir .. "/" .. name end
            end
            p:close()
        end
    end
    table.sort(out)
    return out
end

-- Load every profile from the given directories; later ones replace
-- earlier ones with the same id. Returns list, errors.
function M.loadAll(dirs)
    local by_id, order, errors = {}, {}, {}
    for _, dir in ipairs(dirs) do
        for _, path in ipairs(listLua(dir)) do
            local p, err = loadFile(path)
            if p then
                if not by_id[p.id] then order[#order + 1] = p.id end
                by_id[p.id] = p
            else
                errors[#errors + 1] = err
            end
        end
    end
    if not by_id.generic then
        by_id.generic = Parse.GENERIC
        order[#order + 1] = "generic"
    end
    local list = {}
    for _, id in ipairs(order) do list[#list + 1] = by_id[id] end
    return list, errors
end

function M.byId(list, id)
    for _, p in ipairs(list) do
        if p.id == id then return p end
    end
end

local function contains(list, value)
    for _, v in ipairs(list or {}) do
        if v == value then return true end
    end
    return false
end

--[[--
Pick a profile for a dictionary.
@param list profiles
@param dict { name, lang_in, lang_out }
@param override profile id chosen by the user for this dictionary, or nil
@treturn table profile
@treturn string reason
--]]
function M.match(list, dict, override)
    if override then
        local p = M.byId(list, override)
        if p then return p, "chosen" end
    end
    local name = (dict.name or ""):lower()
    local lin, lout = Lang.normalize(dict.lang_in), Lang.normalize(dict.lang_out)
    local best, best_score = nil, 0
    for _, p in ipairs(list) do
        local m = p.match or {}
        local score = 0
        for _, sub in ipairs(m.names or {}) do
            if name:find(sub:lower(), 1, true) then score = math.max(score, 10 + #sub) end
        end
        if score == 0 and lin and contains(m.lang_in, lin) then
            score = 2
            if lout and contains(m.lang_out, lout) then score = 4 end
        elseif score > 0 and lin and m.lang_in and not contains(m.lang_in, lin) then
            score = score - 5
        end
        if score > best_score then best, best_score = p, score end
    end
    if best then return best, best_score >= 10 and "name" or "language" end
    return M.byId(list, "generic") or Parse.GENERIC, "fallback"
end

return M
