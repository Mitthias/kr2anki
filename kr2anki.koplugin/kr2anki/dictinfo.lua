--[[--
Installed StarDict dictionaries (.ifo files), their languages and parser
profiles, and turning dictionary results into stored lookups.
--]]

local Lang = require("kr2anki/lang")
local Parse = require("kr2anki/dictparse")
local Profiles = require("kr2anki/profiles")

local D = {}
D.__index = D

--[[--
@param opts { data_dir, profile_dirs = {…}, settings }
--]]
function D.new(opts)
    local o = setmetatable({}, D)
    o.data_dir = opts.data_dir
    o.settings = opts.settings
    o.profiles, o.profile_errors = Profiles.loadAll(opts.profile_dirs or {})
    o:scan()
    return o
end

local function readIfo(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local content = f:read("*a")
    f:close()
    local name = content:match("\nbookname=([^\r\n]*)")
    if not name then return nil end
    local lang_in, lang_out = content:match("\nlang=(%a+)%-?(%a*)")
    return {
        name = name, file = path,
        dir = path:match("^(.*)/[^/]+$"),
        is_html = content:find("sametypesequence=h", 1, true) ~= nil,
        lang_in = Lang.normalize(lang_in), lang_out = Lang.normalize(lang_out ~= "" and lang_out or nil),
    }
end

function D:scan()
    self.dicts, self.by_name = {}, {}
    local ok, lfs = pcall(require, "libs/libkoreader-lfs")
    if not ok or not self.data_dir then return end
    local function walk(dir, depth)
        if depth > 4 or lfs.attributes(dir, "mode") ~= "directory" then return end
        for name in lfs.dir(dir) do
            if name ~= "." and name ~= ".." then
                local path = dir .. "/" .. name
                local mode = lfs.attributes(path, "mode")
                if mode == "directory" then
                    walk(path, depth + 1)
                elseif mode == "file" and name:match("%.ifo$") then
                    local info = readIfo(path)
                    if info and not self.by_name[info.name] then
                        self.dicts[#self.dicts + 1] = info
                        self.by_name[info.name] = info
                    end
                end
            end
        end
    end
    walk(self.data_dir, 0)
    walk(self.data_dir .. "_ext", 0)
    table.sort(self.dicts, function(a, b) return a.name < b.name end)
end

function D:info(name)
    return self.by_name[name] or { name = name }
end

-- Source language of a dictionary: user setting, then .ifo "lang=".
function D:language(name, ifo_lang)
    local chosen = self.settings and self.settings:mapGet("dict_languages", name)
    if chosen then return chosen, "chosen" end
    if ifo_lang and ifo_lang.lang_in then return Lang.normalize(ifo_lang.lang_in), "ifo" end
    local info = self.by_name[name]
    if info and info.lang_in then return info.lang_in, "ifo" end
    return nil
end

function D:profileFor(name, ifo_lang)
    local info = self:info(name)
    local override = self.settings and self.settings:mapGet("dict_profiles", name)
    return Profiles.match(self.profiles, {
        name = name,
        lang_in = self:language(name, ifo_lang),
        lang_out = (ifo_lang and ifo_lang.lang_out) or info.lang_out,
    }, override)
end

function D:parse(result)
    local profile = self:profileFor(result.dict, result.ifo_lang)
    return Parse.parse(result.definition, profile, { headword = result.word }), profile
end

--[[--
Dictionary results (from the popup or a silent lookup) -> lookups to store.
@param results list of { dict, word, definition, is_html, ifo_lang, no_result }
@param first index of the result to put first (the one on screen)
--]]
function D:lookupsFromResults(results, first)
    local order = {}
    if first and results[first] then order[1] = results[first] end
    for i, r in ipairs(results or {}) do
        if i ~= first then order[#order + 1] = r end
    end
    local out = {}
    for _, r in ipairs(order) do
        if not r.no_result and not r.is_wiki and r.definition and r.dict and r.dict ~= "" then
            local ok, parsed = pcall(self.parse, self, r)
            if not ok then parsed = { senses = { { text = Parse.clean(r.definition) } }, full = Parse.clean(r.definition) } end
            out[#out + 1] = {
                dictionary = r.dict,
                headword = r.word,
                raw_definition = r.definition,
                is_html = r.is_html or Parse.looksLikeHtml(r.definition),
                dict_lang = self:language(r.dict, r.ifo_lang),
                parsed = parsed,
            }
        end
    end
    return out
end

-- Absolute path of a dictionary sound file, if it exists.
function D:audioPath(dict_name, file)
    if not file or file == "" then return nil end
    local info = self.by_name[dict_name]
    if not info or not info.dir then return nil end
    local ok, lfs = pcall(require, "libs/libkoreader-lfs")
    if not ok then return nil end
    for _, p in ipairs({ info.dir .. "/res/" .. file, info.dir .. "/" .. file }) do
        if lfs.attributes(p, "mode") == "file" then return p end
    end
end

return D
