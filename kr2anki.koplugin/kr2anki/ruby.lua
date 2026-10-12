--[[--
Reading tools: furigana and pinyin alignment in Anki ruby syntax, pinyin tone
conversion, and Korean romanization. Pure Lua.

Anki's `furigana` filter reads `base[reading]`, where the base runs back to
the previous space. So consecutive ruby segments are separated by a space,
which the filter removes when rendering:

    furigana("打ち明ける", "うちあける") --> "打[う]ち 明[あ]ける"
    furigana("今日", "きょう")           --> "今日[きょう]"   (whole-word fallback)
    pinyin("打算", "da3 suan4")          --> "打[dǎ] 算[suàn]"
--]]

local U = require("kr2anki/u8")

local R = {}

-- Furigana ------------------------------------------------------------------

local function isKanjiLike(cp)
    -- ヵ ヶ behave like kanji in compounds (一ヶ月 = いっかげつ)
    return U.isHan(cp) or cp == 0x30F5 or cp == 0x30F6
end

local function segments(word)
    local segs = {}
    for _, ch in ipairs(U.chars(word)) do
        local kind = isKanjiLike(U.codepoint(ch)) and "kanji" or "kana"
        local last = segs[#segs]
        if last and last.kind == kind then
            last.chars[#last.chars + 1] = ch
        else
            segs[#segs + 1] = { kind = kind, chars = { ch } }
        end
    end
    return segs
end

-- Returns array of reading-char counts per segment, or nil if no alignment.
local function align(segs, rnorm)
    local n = #rnorm
    local result = {}
    local function go(si, pos)
        if si > #segs then return pos == n + 1 end
        local seg = segs[si]
        if seg.kind == "kana" then
            local len = #seg.chars
            for k = 1, len do
                local want = U.toHiragana(seg.chars[k])
                if rnorm[pos + k - 1] ~= want then return false end
            end
            result[si] = len
            return go(si + 1, pos + len)
        end
        -- kanji run: at least one reading char per kanji is typical, but
        -- allow fewer only when no other split works (e.g. 々 compounds)
        local remaining = n - pos + 1
        for len = 1, remaining do
            result[si] = len
            if go(si + 1, pos + len) then return true end
        end
        return false
    end
    if go(1, 1) then return result end
    return nil
end

--[[--
@param word string, e.g. "打ち明ける"
@param reading string in kana (hiragana or katakana)
@treturn string|nil ruby text, or nil when the word has no kanji or no reading
@treturn boolean true when the whole-word fallback was used
--]]
function R.furigana(word, reading)
    word = U.trim(word or "")
    reading = U.trim(reading or "")
    if word == "" or reading == "" then return nil end
    local segs = segments(word)
    local has_kanji = false
    for _, s in ipairs(segs) do
        if s.kind == "kanji" then has_kanji = true end
    end
    if not has_kanji then return nil end
    local rchars = U.chars(reading)
    local rnorm = U.chars(U.toHiragana(reading))
    local counts = align(segs, rnorm)
    if not counts then
        return word .. "[" .. reading .. "]", true
    end
    local out = {}
    local pos = 1
    for si, seg in ipairs(segs) do
        local len = counts[si]
        local text = table.concat(seg.chars)
        if seg.kind == "kanji" then
            if #out > 0 then out[#out + 1] = " " end
            out[#out + 1] = text .. "[" .. table.concat(rchars, "", pos, pos + len - 1) .. "]"
        else
            out[#out + 1] = text
        end
        pos = pos + len
    end
    return table.concat(out), false
end

-- Pinyin --------------------------------------------------------------------

local TONES = {
    a = { "ā", "á", "ǎ", "à" }, e = { "ē", "é", "ě", "è" }, i = { "ī", "í", "ǐ", "ì" },
    o = { "ō", "ó", "ǒ", "ò" }, u = { "ū", "ú", "ǔ", "ù" }, ["ü"] = { "ǖ", "ǘ", "ǚ", "ǜ" },
    A = { "Ā", "Á", "Ǎ", "À" }, E = { "Ē", "É", "Ě", "È" }, I = { "Ī", "Í", "Ǐ", "Ì" },
    O = { "Ō", "Ó", "Ǒ", "Ò" }, U = { "Ū", "Ú", "Ǔ", "Ù" }, ["Ü"] = { "Ǖ", "Ǘ", "Ǚ", "Ǜ" },
}
local UNMARK = {}
for base, marks in pairs(TONES) do
    for t, m in ipairs(marks) do UNMARK[m] = { base, t } end
end

local function markSyllable(syl, tone)
    syl = syl:gsub("u:", "ü"):gsub("U:", "Ü"):gsub("v", "ü"):gsub("V", "Ü")
    if not tone or tone < 1 or tone > 4 then return syl end
    local cs = U.chars(syl)
    local target
    local lower = {}
    for i, c in ipairs(cs) do lower[i] = c:lower() end
    for i, c in ipairs(lower) do
        if c == "a" or c == "e" then target = i break end
    end
    if not target then
        for i = 1, #lower - 1 do
            if lower[i] == "o" and lower[i + 1] == "u" then target = i break end
        end
    end
    if not target then
        for i = #cs, 1, -1 do
            if TONES[cs[i]] then target = i break end
        end
    end
    if not target then return syl end
    cs[target] = TONES[cs[target]][tone]
    return table.concat(cs)
end

-- "da3 suan4" -> "dǎ suàn"; text already in tone marks is returned as is.
function R.numberedToMarks(s)
    s = tostring(s or ""):gsub("ü", "v"):gsub("Ü", "V")
    return (s:gsub("([%a:]+)([0-5])", function(syl, tone)
        return markSyllable(syl, tonumber(tone))
    end))
end

-- Strip tone marks and numbers: "dǎsuàn" -> "dasuan".
function R.stripTones(s)
    local out = {}
    for _, ch in ipairs(U.chars(s)) do
        local u = UNMARK[ch]
        out[#out + 1] = u and u[1] or ch
    end
    return (table.concat(out):gsub("[0-5]", ""))
end

local INITIALS = { "zh", "ch", "sh", "b", "p", "m", "f", "d", "t", "n", "l", "g", "k", "h",
                   "j", "q", "x", "r", "z", "c", "s", "y", "w", "" }
local FINALS = { "iang", "iong", "uang", "ueng", "ang", "eng", "ing", "ong", "ian", "iao", "uai",
                 "uan", "üan", "van", "ai", "ei", "ao", "ou", "an", "en", "er", "in", "un", "ün", "vn",
                 "ia", "ie", "iu", "ua", "uo", "ue", "üe", "ve", "ui", "a", "o", "e", "i", "u", "ü", "v", "n", "ng", "m" }
local SYLLABLES = {}
for _, ini in ipairs(INITIALS) do
    for _, fin in ipairs(FINALS) do
        SYLLABLES[ini .. fin] = true
    end
end

-- Split a pinyin string into syllables (keeps tone marks).
-- "dǎ suàn" -> {"dǎ","suàn"}; "dǎsuàn" -> {"dǎ","suàn"}; "Xī'ān" -> {"Xī","ān"}
function R.splitPinyin(s)
    s = R.numberedToMarks(U.trim(s or "")):gsub("’", "'"):gsub("·", " ")
    local out = {}
    for chunk in s:gmatch("[^%s'%-,]+") do
        local cs = U.chars(chunk)
        local plain = {}
        for i, ch in ipairs(cs) do
            local u = UNMARK[ch]
            plain[i] = (u and u[1] or ch):lower()
        end
        -- longest-first segmentation with backtracking
        local n = #cs
        local parts = {}
        local function go(pos)
            if pos > n then return true end
            for len = math.min(6, n - pos + 1), 1, -1 do
                local cand = table.concat(plain, "", pos, pos + len - 1)
                if SYLLABLES[cand] then
                    parts[#parts + 1] = table.concat(cs, "", pos, pos + len - 1)
                    if go(pos + len) then return true end
                    parts[#parts] = nil
                end
            end
            return false
        end
        if go(1) then
            for _, p in ipairs(parts) do out[#out + 1] = p end
        else
            out[#out + 1] = chunk
        end
    end
    return out
end

--[[--
@param word string of Han characters, e.g. "打算"
@param reading pinyin, numbered or with tone marks
@treturn string|nil ruby text
@treturn boolean true when the whole-word fallback was used
--]]
function R.pinyin(word, reading)
    word = U.trim(word or "")
    reading = U.trim(reading or "")
    if word == "" or reading == "" then return nil end
    local marked = R.numberedToMarks(reading)
    local chars = U.chars(word)
    local all_han = true
    for _, ch in ipairs(chars) do
        if not U.isHan(U.codepoint(ch)) then all_han = false end
    end
    local syl = R.splitPinyin(marked)
    if all_han and #syl == #chars then
        local out = {}
        for i, ch in ipairs(chars) do
            out[#out + 1] = ch .. "[" .. syl[i] .. "]"
        end
        return table.concat(out, " "), false
    end
    return word .. "[" .. table.concat(syl, " ") .. "]", true
end

-- Korean romanization (Revised Romanization, letter by letter plus liaison).

local RR_INITIAL = { "g", "kk", "n", "d", "tt", "r", "m", "b", "pp", "s", "ss", "", "j", "jj", "ch", "k", "t", "p", "h" }
local RR_MEDIAL = { "a", "ae", "ya", "yae", "eo", "e", "yeo", "ye", "o", "wa", "wae", "oe", "yo", "u", "wo", "we",
                    "wi", "yu", "eu", "ui", "i" }
local RR_FINAL = { "", "k", "k", "k", "n", "n", "n", "t", "l", "k", "m", "l", "l", "l", "p", "l", "m", "p", "p", "t",
                   "t", "ng", "t", "t", "k", "t", "p", "t" }
-- Final consonant re-read as the next syllable's initial (liaison before ㅇ).
local LIAISON = { [1] = "g", [2] = "kk", [4] = "n", [7] = "d", [8] = "r", [16] = "m", [17] = "b",
                  [19] = "s", [20] = "ss", [22] = "j", [23] = "ch", [24] = "k", [25] = "t", [26] = "p" }

function R.romanizeKorean(s)
    local syl = {}
    for _, ch in ipairs(U.chars(s)) do
        local cp = U.codepoint(ch)
        if cp >= 0xAC00 and cp <= 0xD7A3 then
            local idx = cp - 0xAC00
            syl[#syl + 1] = { i = math.floor(idx / 588) + 1, m = math.floor(idx % 588 / 28) + 1, f = idx % 28 + 1 }
        else
            syl[#syl + 1] = { raw = ch }
        end
    end
    local out = {}
    for k, sy in ipairs(syl) do
        if sy.raw then
            out[#out + 1] = sy.raw
        else
            local ini = RR_INITIAL[sy.i]
            local prev = syl[k - 1]
            if ini == "r" and (not prev or prev.raw) then ini = "r" end
            if prev and not prev.raw and prev.f == 9 and sy.i == 6 then ini = "l" end -- ㄹㄹ -> ll
            if prev and prev.liaison then ini = prev.liaison end
            local fin = RR_FINAL[sy.f]
            local nxt = syl[k + 1]
            if nxt and not nxt.raw and nxt.i == 12 and LIAISON[sy.f - 1] then
                sy.liaison = LIAISON[sy.f - 1]
                fin = ""
            end
            out[#out + 1] = ini .. RR_MEDIAL[sy.m] .. fin
        end
    end
    return table.concat(out)
end

return R
