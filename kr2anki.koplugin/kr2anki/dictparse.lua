--[[--
Dictionary entry parser driven by data profiles (see profiles/*.lua).

    local P = require("kr2anki/dictparse")
    local parsed = P.parse(raw_definition, profile, { headword = "打ち明ける", lang = "ja" })
    -- parsed = { reading, pos, senses = { {text, pos}, ... }, examples = {...},
    --            notes = {...}, audio, pitch, full }

The engine knows a fixed set of strategies; a profile only chooses and tunes
them, so a new dictionary layout needs a new data file, not new code.
Pure Lua.
--]]

local U = require("kr2anki/u8")
local Ruby = require("kr2anki/ruby")

local P = {}

-- HTML ----------------------------------------------------------------------

local BLOCK_TAGS = {
    div = true, p = true, br = true, li = true, tr = true, dd = true, dt = true, dl = true,
    h1 = true, h2 = true, h3 = true, h4 = true, h5 = true, h6 = true, ul = true, ol = true,
    blockquote = true, table = true, section = true, article = true, hr = true,
}

local ENTITIES = {
    amp = "&", lt = "<", gt = ">", quot = '"', apos = "'", nbsp = " ", ndash = "–", mdash = "—",
    hellip = "…", lsquo = "‘", rsquo = "’", ldquo = "“", rdquo = "”", middot = "·", bull = "•",
    rarr = "→", larr = "←", times = "×", deg = "°", copy = "©", reg = "®",
}

function P.decodeEntities(s)
    s = s:gsub("&#[xX](%x+);", function(h) local cp = tonumber(h, 16); return cp and U.char(cp) or "" end)
    s = s:gsub("&#(%d+);", function(d) local cp = tonumber(d); return cp and U.char(cp) or "" end)
    s = s:gsub("&(%a+);", function(name) return ENTITIES[name:lower()] or ("&" .. name .. ";") end)
    return s
end

function P.looksLikeHtml(s)
    return s:find("<%a[%w]*[%s>/]") ~= nil or s:find("</%a") ~= nil
end

-- Sound file referenced by the entry, if any.
function P.findAudio(s)
    return s:match("<audio[^>]-src%s*=%s*[\"']([^\"']+)[\"']")
        or s:match("<source[^>]-src%s*=%s*[\"']([^\"']+)[\"']")
        or s:match("href%s*=%s*[\"']sound://([^\"']+)[\"']")
        or s:match("%[sound:([^%]]+)%]")
end

function P.htmlToText(s)
    s = s:gsub("\r", "")
    s = s:gsub("<!%-%-.-%-%->", "")
    s = s:gsub("<![%[]CDATA%[(.-)%]%]>", "%1")
    for _, tag in ipairs({ "style", "script", "head" }) do
        local pat = "<" .. tag:gsub("%a", function(c) return "[" .. c:lower() .. c:upper() .. "]" end)
        s = s:gsub(pat .. "[^>]*>.-</" .. tag:gsub("%a", function(c) return "[" .. c:lower() .. c:upper() .. "]" end) .. ">", "")
    end
    -- number the items of ordered lists
    s = s:gsub("<[oO][lL][^>]*>(.-)</[oO][lL]>", function(inner)
        local n = 0
        inner = inner:gsub("<[lL][iI][^>]*>", function()
            n = n + 1
            return "\n" .. n .. ". "
        end)
        return "\n" .. inner .. "\n"
    end)
    s = s:gsub("<(/?)([%a][%w]*)[^>]*>", function(_, tag)
        if BLOCK_TAGS[tag:lower()] then return "\n" end
        return ""
    end)
    s = s:gsub("<[^>]*>", "")
    s = P.decodeEntities(s)
    return s
end

-- Plain text, one paragraph per line, without HTML and blank lines.
function P.clean(raw)
    raw = tostring(raw or "")
    local text = P.looksLikeHtml(raw) and P.htmlToText(raw) or P.decodeEntities(raw:gsub("<[bB][rR]%s*/?>", "\n"))
    local lines = {}
    for line in (text .. "\n"):gmatch("(.-)\n") do
        line = line:gsub("\194\160", " "):gsub("[ \t]+", " ")
        line = U.trim(line)
        if line ~= "" then lines[#lines + 1] = line end
    end
    return table.concat(lines, "\n")
end

-- Script checks ---------------------------------------------------------------

local KANA_EXTRA = U.set(" ・ー･")

local function isKanaText(s)
    local sc = U.scripts(U.removeSet(s, KANA_EXTRA))
    return sc.total > 0 and sc.kana == sc.total
end

local function isPinyinText(s)
    if s:find("[^%a%d%s:'’%-·,\128-\255]") then return false end
    local plain = Ruby.stripTones(s):lower()
    if plain:find("[^a-z%s:'’%-·,ü\128-\255]") then return false end
    return #Ruby.splitPinyin(s) > 0 and U.scripts(s).han == 0
end

local IPA_CHARS = U.set("ɑæɐəɚɛɜɪɔʊʌθðʃʒŋˈˌːɹɾʔɡɒɝɫɘɵʉɨʏøœɤɯʍɥʝçχʁħʕɬɮʎɲɳɴʀʂʐʈɖɟɢʋⁿ")
local function isIpaText(s)
    if U.scripts(s).han > 0 or U.scripts(s).kana > 0 then return false end
    for ch in s:gmatch(U.CHAR_PATTERN) do
        if IPA_CHARS[ch] then return true end
    end
    -- plain ASCII pronunciation like [ran] is accepted too, but not long phrases
    return U.len(s) <= 30 and not s:find("%d") and s:find("^[%a%s%.'ˈˌ:%-]+$") ~= nil
end

local function isHangulText(s)
    local sc = U.scripts((s:gsub("%s", "")))
    return sc.total > 0 and sc.hangul == sc.total
end

local SCRIPT_CHECK = {
    kana = isKanaText, pinyin = isPinyinText, ipa = isIpaText, hangul = isHangulText,
    latin = function(s) return U.scripts(s).latin > 0 and U.scripts(s).han == 0 end,
    any = function(s) return U.trim(s) ~= "" end,
}

-- Helpers ---------------------------------------------------------------------

local function escapePattern(s)
    return (s:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%1"))
end

local function startsWithAny(line, prefixes)
    local lower = line:lower()
    for _, p in ipairs(prefixes or {}) do
        if lower:sub(1, #p) == p:lower() then return p end
    end
end

local SEPARATORS = U.set("/;,；，、 \t")

local function stripTrailing(s)
    return U.trim(U.stripSet(U.trim(s), SEPARATORS))
end

-- Sense markers ------------------------------------------------------------------

local CIRCLED = {}
for i, c in ipairs({ "①", "②", "③", "④", "⑤", "⑥", "⑦", "⑧", "⑨", "⑩", "⑪", "⑫", "⑬", "⑭", "⑮",
                     "⑯", "⑰", "⑱", "⑲", "⑳" }) do CIRCLED[c] = i end
for i, c in ipairs({ "❶", "❷", "❸", "❹", "❺", "❻", "❼", "❽", "❾", "❿" }) do CIRCLED[c] = i end

-- Marker styles: paren "(1)", dot "1.", rparen "1)", colon "1:", circled "①",
-- bare "1 " (line start only), bracket "[1]".
local MARKER_PATTERNS = {
    paren = { "%((%d+)%)" },
    bracket = { "%[(%d+)%]" },
    dot = { "^(%d+)%.%s", "%s(%d+)%.%s" },
    rparen = { "^(%d+)%)%s", "%s(%d+)%)%s" },
    colon = { "^(%d+):%s", "%s(%d+):%s" },
    bare = { "^(%d+)%s+%f[%a\128-\255]" },
}

-- Finds sense markers in `text`; returns list of {s = start, e = end, n = number}
-- in order, keeping only a run that counts 1, 2, 3 … (restarting at 1 is
-- allowed for a new part of speech).
local function findMarkers(text, styles)
    local found = {}
    for _, style in ipairs(styles) do
        if style == "circled" then
            for pos, ch in text:gmatch("()(" .. U.CHAR_PATTERN .. ")") do
                if CIRCLED[ch] then
                    found[#found + 1] = { s = pos, e = pos + #ch - 1, n = CIRCLED[ch] }
                end
            end
        else
            for _, pat in ipairs(MARKER_PATTERNS[style] or {}) do
                -- scan line by line so "^" anchors at each line
                local offset = 0
                for line in (text .. "\n"):gmatch("(.-)\n") do
                    local init = 1
                    while true do
                        local s, e, num = line:find(pat, init)
                        if not s then break end
                        -- leading space belongs to the text before
                        local ms = s
                        if line:sub(s, s) == " " then ms = s + 1 end
                        found[#found + 1] = { s = offset + ms, e = offset + e, n = tonumber(num) }
                        init = e + 1
                        if pat:sub(1, 1) == "^" then break end
                    end
                    offset = offset + #line + 1
                end
            end
        end
        if #found > 0 then break end -- first style that matches wins
    end
    table.sort(found, function(a, b) return a.s < b.s end)
    -- keep a coherent numbering run
    local run, expect = {}, 1
    for _, m in ipairs(found) do
        if m.n == expect then
            run[#run + 1] = m
            expect = expect + 1
        elseif m.n == 1 and #run > 0 then
            run[#run + 1] = m
            expect = 2
        end
    end
    if #run < 2 and not (#run == 1 and run[1].n == 1) then return {} end
    return run
end

-- POS -----------------------------------------------------------------------------

local GENERIC_POS = {
    ["n"] = "noun", ["n."] = "noun", noun = "noun", ["v"] = "verb", ["v."] = "verb", verb = "verb",
    ["vt."] = "transitive verb", ["vi."] = "intransitive verb", ["vt"] = "transitive verb", ["vi"] = "intransitive verb",
    ["v. t."] = "transitive verb", ["v. i."] = "intransitive verb",
    ["adj"] = "adjective", ["adj."] = "adjective", ["a."] = "adjective", adjective = "adjective", ["s"] = "adjective",
    ["adv"] = "adverb", ["adv."] = "adverb", ["r"] = "adverb", adverb = "adverb",
    ["prep."] = "preposition", preposition = "preposition", ["conj."] = "conjunction", conjunction = "conjunction",
    ["pron."] = "pronoun", pronoun = "pronoun", ["int."] = "interjection", ["interj."] = "interjection",
    interjection = "interjection", ["art."] = "article", ["num."] = "numeral", ["aux."] = "auxiliary verb",
    ["abbr."] = "abbreviation", ["pl."] = "plural", ["phr."] = "phrase", ["phrasal verb"] = "phrasal verb",
    ["modal verb"] = "modal verb", ["det."] = "determiner", determiner = "determiner",
    ["名"] = "名词", ["名词"] = "名词", ["动"] = "动词", ["动词"] = "动词", ["形"] = "形容词", ["形容词"] = "形容词",
    ["副"] = "副词", ["副词"] = "副词", ["量"] = "量词",
}

local candidate_cache = setmetatable({}, { __mode = "k" })

local function posCandidates(profile)
    local c = candidate_cache[profile]
    if c then return c end
    c = {}
    if not (profile.pos and profile.pos.generic == false) then
        for w in pairs(GENERIC_POS) do c[#c + 1] = w end
    end
    for _, w in ipairs(profile.pos and profile.pos.words or {}) do c[#c + 1] = w end
    -- longest first so "v. t." beats "v."
    table.sort(c, function(a, b) return #a > #b or (#a == #b and a < b) end)
    candidate_cache[profile] = c
    return c
end

-- A part-of-speech word at the start of `line` ("vt. 跑", "n 1: …", "noun").
local function posWordAtStart(line, profile)
    local map = profile.pos and profile.pos.map or {}
    local lower = line:lower()
    for _, w in ipairs(posCandidates(profile)) do
        local lw = w:lower()
        if lower:sub(1, #lw) == lw then
            local rest = line:sub(#lw + 1)
            local nextch = rest:sub(1, 1)
            local spaced = nextch == "" or nextch == " " or nextch == "\t"
            -- "vt.1." is fine; a bare word like "n" needs a space after it
            local ok = spaced or (w:sub(-1) == "." and nextch:find("[%d%(%[]") ~= nil)
            if ok then
                return map[w] or map[lw] or GENERIC_POS[lw] or w, U.trim(rest)
            end
        end
    end
end

-- "(v1,vt)" codes at the start of text, using profile.pos.codes.
local function posCodesAtStart(text, profile)
    local codes = profile.pos and profile.pos.codes
    if not codes then return nil, text end
    local inner, rest = text:match("^%s*%(([^%)]+)%)%s*(.*)$")
    if not inner then return nil, text end
    local names = {}
    for code in inner:gmatch("[^,]+") do
        code = U.trim(code)
        local name = codes[code]
        if name == nil then return nil, text end -- not a POS group
        if name ~= false and name ~= "" then names[#names + 1] = name end
    end
    return table.concat(names, ", "), rest
end

-- Tags such as "(arch)", "(P)" inside a sense.
local function applyTags(text, profile)
    local tags = profile.tags
    local labels = {}
    if tags then
        text = text:gsub("%s*%(([%w%-]+)%)", function(code)
            local t = tags[code]
            if t == false then return "" end
            if t then
                labels[#labels + 1] = t
                return ""
            end
            return nil
        end)
        text = text:gsub("%s*{([%w%-]+)}", function(code)
            local t = tags[code]
            if t == false then return "" end
            if t then labels[#labels + 1] = t; return "" end
            return nil
        end)
    end
    text = stripTrailing(text)
    if #labels > 0 then
        text = text .. " · " .. table.concat(labels, ", ")
    end
    return text
end

-- Main --------------------------------------------------------------------------

local function newResult(full)
    return { reading = nil, pos = nil, senses = {}, examples = {}, notes = {}, audio = nil, pitch = nil, full = full }
end

local function extractReading(lines, profile, headword)
    for _, rule in ipairs(profile.reading or {}) do
        local limit = rule.where == "any" and #lines or math.min(#lines, rule.lines or 2)
        for i = 1, limit do
            local line = lines[i]
            local s, e, cap = line:find(rule.pattern)
            if s and cap then
                cap = U.trim(cap)
                local check = SCRIPT_CHECK[rule.script or "any"] or SCRIPT_CHECK.any
                if cap ~= "" and check(cap) and cap ~= headword then
                    if rule.remove ~= false then
                        lines[i] = U.trim(line:sub(1, s - 1) .. " " .. line:sub(e + 1))
                    end
                    if rule.script == "pinyin" then cap = Ruby.numberedToMarks(cap) end
                    if rule.script == "ipa" and not cap:find("^/") then cap = "/" .. cap .. "/" end
                    return cap
                end
            end
        end
    end
end

local HEADER_PUNCT = U.set(" \t,・、【】[]*:()")

-- Drop a first line that only repeats the headword (with brackets etc).
local function dropHeader(lines, profile, headword)
    if #lines == 0 or not headword or headword == "" then return end
    local first = lines[1]
    local hw = escapePattern(headword)
    -- remove the headword at the very start of the line (ASCII case-insensitive)
    local rest
    if first:lower():sub(1, #headword) == headword:lower() then
        rest = first:sub(#headword + 1)
    end
    if not rest then
        -- 【打ち明ける】 or "打ち明ける・打明ける"
        rest = first:match("^【" .. hw .. "[^】]*】(.*)$")
    end
    if not rest and profile.header and profile.header.strip_prefix then
        rest = first:match(profile.header.strip_prefix)
    end
    if rest then
        rest = U.stripSet(rest, HEADER_PUNCT, "start")
        -- traditional/simplified pair "打算 打算"
        if rest:lower():sub(1, #headword) == headword:lower() then rest = rest:sub(#headword + 1) end
        if rest:find("^[%s%p]*$") or U.trim(rest) == "" then
            table.remove(lines, 1)
        else
            lines[1] = U.trim(rest)
        end
    elseif U.trim(first:gsub("[【】%[%]%(%)%s%p]", "")) == "" then
        table.remove(lines, 1)
    end
end

local NOTE_HEADER_PUNCT = U.set(":： -")

local function takeQuotedExamples(text, out)
    -- WordNet style: ; "he hit a run"
    text = text:gsub(';?%s*"([^"]+)"', function(ex)
        out[#out + 1] = U.trim(ex)
        return ""
    end)
    text = text:gsub(';?%s*“([^”]+)”', function(ex)
        out[#out + 1] = U.trim(ex)
        return ""
    end)
    return text
end

local function takeInlineNotes(text, profile, out)
    for _, pat in ipairs(profile.notes and profile.notes.inline or {}) do
        text = text:gsub(pat, function(note)
            note = note:gsub("[{}]", "")
            out[#out + 1] = U.trim(note)
            return ""
        end)
    end
    return text
end

-- Bilingual example sentence in a CJK dictionary: CJK sentence + translation.
local function isBilingualExample(line)
    local sc = U.scripts(line)
    return (sc.han + sc.kana + sc.hangul) >= 4 and sc.latin >= 4
        and (line:find("。") or line:find("！") or line:find("？") or line:find("[%.!?]%s*$"))
end

local function convertPinyin(text)
    return (text:gsub("%[([%a%d%s:]+)%]", function(p)
        if p:find("%d") then return "[" .. Ruby.numberedToMarks(p) .. "]" end
    end))
end

local function addSense(result, text, pos, profile)
    if profile.pinyin_in_text then text = convertPinyin(text) end
    if profile.gloss_separator then
        local parts = {}
        for part in (text .. profile.gloss_separator):gmatch("(.-)" .. escapePattern(profile.gloss_separator)) do
            part = U.trim(part)
            if part ~= "" then parts[#parts + 1] = part end
        end
        text = table.concat(parts, "; ")
    end
    text = takeInlineNotes(text, profile, result.notes)
    if profile.examples and profile.examples.quoted then
        text = takeQuotedExamples(text, result.examples)
    end
    local spos
    if profile.pos and profile.pos.codes then
        spos, text = posCodesAtStart(text, profile)
    end
    local wpos, rest = posWordAtStart(text, profile)
    if wpos and rest ~= "" and (profile.pos == nil or profile.pos.inline_words ~= false) then
        spos, text = spos or wpos, rest
    end
    text = applyTags(text, profile)
    -- classifier / see-also items become notes (CC-CEDICT)
    for _, p in ipairs(profile.notes and profile.notes.sense_prefixes or {}) do
        if text:sub(1, #p) == p then
            result.notes[#result.notes + 1] = text
            return
        end
    end
    if text ~= "" and not text:find("^[%p%s]*$") then
        result.senses[#result.senses + 1] = { text = text, pos = spos or pos }
        if not result.pos and (spos or pos) then result.pos = spos or pos end
    end
end

--[[--
Parse one dictionary result.
@param raw string definition (plain text or HTML)
@param profile table (see profiles/*.lua)
@param opts { headword, lang }
--]]
function P.parse(raw, profile, opts)
    opts = opts or {}
    profile = profile or P.GENERIC
    raw = tostring(raw or "")
    local audio = P.findAudio(raw)
    local full = P.clean(raw)
    local result = newResult(full)
    result.audio = audio
    result.headword = opts.headword

    local lines = {}
    for line in (full .. "\n"):gmatch("(.-)\n") do
        if line ~= "" then lines[#lines + 1] = line end
    end

    result.reading = extractReading(lines, profile, opts.headword)
    if profile.pitch and profile.pitch.pattern then
        for i, line in ipairs(lines) do
            local s, e, cap = line:find(profile.pitch.pattern)
            if s then
                result.pitch = cap
                lines[i] = U.trim(line:sub(1, s - 1) .. line:sub(e + 1))
                break
            end
        end
    end
    dropHeader(lines, profile, opts.headword)
    if not result.reading then
        -- the reading may sit at the start of the remaining first line
        result.reading = extractReading(lines, profile, opts.headword)
    end

    -- Pull out example and note lines; after a note header line, every
    -- following line is a note (e.g. 相关词组:).
    local body = {}
    local in_notes = false
    local ex_prefixes = profile.examples and profile.examples.prefixes or {}
    local note_prefixes = profile.notes and profile.notes.prefixes or {}
    local note_headers = profile.notes and profile.notes.headers or {}
    for _, line in ipairs(lines) do
        local header = startsWithAny(line, note_headers)
        if header then
            in_notes = true
            local rest = stripTrailing(U.stripSet(line:sub(#header + 1), NOTE_HEADER_PUNCT, "start"))
            if rest ~= "" then result.notes[#result.notes + 1] = rest end
        elseif in_notes then
            result.notes[#result.notes + 1] = line
        else
            local exp = startsWithAny(line, ex_prefixes)
            local notep = startsWithAny(line, note_prefixes)
            if exp then
                result.examples[#result.examples + 1] = U.trim(line:sub(#exp + 1))
            elseif notep then
                result.notes[#result.notes + 1] = U.trim(line)
            elseif profile.examples and profile.examples.bilingual and isBilingualExample(line) then
                result.examples[#result.examples + 1] = line
            else
                body[#body + 1] = line
            end
        end
    end

    local text = table.concat(body, "\n")
    local strategies = profile.senses or { "numbered", "lines" }
    local done = false
    for _, strat in ipairs(strategies) do
        if done then break end
        if strat == "numbered" then
            local markers = findMarkers(text, profile.markers or { "paren", "circled", "dot", "rparen", "colon", "bracket" })
            if #markers > 0 then
                -- text before the first marker: a POS or a whole-entry label
                local lead = stripTrailing(text:sub(1, markers[1].s - 1))
                local lead_pos
                if lead ~= "" then
                    local codes_pos, rest = posCodesAtStart(lead, profile)
                    local word_pos, rest2 = posWordAtStart(rest, profile)
                    lead_pos = codes_pos or word_pos
                    local leftover = stripTrailing(word_pos and rest2 or rest)
                    if leftover ~= "" and not leftover:find("^[%p%s]*$") then
                        result.notes[#result.notes + 1] = leftover
                    end
                end
                local current_pos = lead_pos
                for k, m in ipairs(markers) do
                    local stop = markers[k + 1] and (markers[k + 1].s - 1) or #text
                    local chunk = text:sub(m.e + 1, stop)
                    -- a POS word right before the next marker belongs to the next sense
                    local nextpos
                    local lines_in = {}
                    for l in (chunk .. "\n"):gmatch("(.-)\n") do lines_in[#lines_in + 1] = l end
                    if #lines_in > 1 then
                        local lastline = U.trim(lines_in[#lines_in])
                        if lastline == "" then
                            table.remove(lines_in)
                            lastline = U.trim(lines_in[#lines_in] or "")
                        end
                        local wp, rest = posWordAtStart(lastline, profile)
                        if wp and U.trim(rest) == "" then
                            nextpos = wp
                            table.remove(lines_in)
                        end
                    end
                    chunk = table.concat(lines_in, " ")
                    addSense(result, chunk, current_pos, profile)
                    if nextpos then current_pos = nextpos end
                end
                done = true
            end
        elseif strat == "slash" then
            local t = U.trim(text:gsub("\n", " "))
            if t:find("^/") or select(2, t:gsub("/", "")) >= 2 then
                for part in t:gmatch("[^/]+") do
                    part = U.trim(part)
                    if part ~= "" then addSense(result, part, nil, profile) end
                end
                done = #result.senses > 0
            end
        elseif strat == "lines" then
            local current_pos
            for _, line in ipairs(body) do
                local wp, rest = posWordAtStart(line, profile)
                if wp and U.trim(rest) == "" then
                    current_pos = wp
                else
                    addSense(result, line, current_pos, profile)
                end
            end
            done = #result.senses > 0
        end
    end

    if #result.senses == 0 and text ~= "" then
        result.senses[1] = { text = stripTrailing(U.squash(text)) }
    end
    if result.audio then
        result.audio = result.audio:gsub("^sound://", "")
    end
    return result
end

-- Short meaning for list rows: first sense without labels, cut to n chars.
function P.shortMeaning(text, n)
    text = tostring(text or ""):gsub(" · .*$", "")
    return U.ellipsize(U.squash(text), n or 40)
end

P.GENERIC = {
    id = "generic",
    name = "Generic",
    senses = { "numbered", "lines" },
    reading = {
        { pattern = "/([^/]+)/", script = "ipa" },
        { pattern = "%[([^%]]+)%]", script = "ipa" },
        { pattern = "【(.-)】", script = "kana" },
        { pattern = "%[([^%]]+)%]", script = "kana" },
        { pattern = "%[([^%]]+)%]", script = "pinyin" },
    },
    examples = { prefixes = { "e.g.", "eg:", "example:", "例:", "例：", "例句", "▸" }, quoted = false, bilingual = true },
    notes = { prefixes = { "syn:", "synonyms:", "see also", "usage:", "note:", "antonym", "ant:" },
              inline = { "%[syn:%s*(.-)%]" } },
}

return P
