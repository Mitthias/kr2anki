--[[--
UTF-8 helpers and script classification. Pure Lua, no KOReader imports.

All "char" positions are 1-based character indexes; byte offsets are named
explicitly where used.
--]]

local U = {}

U.CHAR_PATTERN = "[%z\1-\127\194-\244][\128-\191]*"

function U.chars(s)
    local out = {}
    for ch in tostring(s or ""):gmatch(U.CHAR_PATTERN) do
        out[#out + 1] = ch
    end
    return out
end

function U.len(s)
    local n = 0
    for _ in tostring(s or ""):gmatch(U.CHAR_PATTERN) do
        n = n + 1
    end
    return n
end

-- Character-indexed substring (like string.sub, but on characters).
function U.sub(s, i, j)
    local cs = U.chars(s)
    local n = #cs
    i = i or 1
    j = j or n
    if i < 0 then i = n + i + 1 end
    if j < 0 then j = n + j + 1 end
    if i < 1 then i = 1 end
    if j > n then j = n end
    if i > j then return "" end
    return table.concat(cs, "", i, j)
end

function U.codepoint(ch)
    local b1, b2, b3, b4 = ch:byte(1, 4)
    if not b1 then return nil end
    if b1 < 0x80 then return b1 end
    if b1 < 0xE0 then return (b1 - 0xC0) * 0x40 + (b2 - 0x80) end
    if b1 < 0xF0 then return (b1 - 0xE0) * 0x1000 + (b2 - 0x80) * 0x40 + (b3 - 0x80) end
    return (b1 - 0xF0) * 0x40000 + (b2 - 0x80) * 0x1000 + (b3 - 0x80) * 0x40 + (b4 - 0x80)
end

function U.char(cp)
    if cp < 0x80 then return string.char(cp) end
    if cp < 0x800 then
        return string.char(0xC0 + math.floor(cp / 0x40), 0x80 + cp % 0x40)
    end
    if cp < 0x10000 then
        return string.char(0xE0 + math.floor(cp / 0x1000), 0x80 + math.floor(cp / 0x40) % 0x40, 0x80 + cp % 0x40)
    end
    return string.char(0xF0 + math.floor(cp / 0x40000), 0x80 + math.floor(cp / 0x1000) % 0x40,
        0x80 + math.floor(cp / 0x40) % 0x40, 0x80 + cp % 0x40)
end

local function between(cp, a, b) return cp and cp >= a and cp <= b end

function U.isHiragana(cp) return between(cp, 0x3041, 0x309F) end
-- Katakana block plus the prolonged sound mark and half-width katakana.
function U.isKatakana(cp)
    return between(cp, 0x30A0, 0x30FF) or between(cp, 0x31F0, 0x31FF) or between(cp, 0xFF66, 0xFF9F)
end
function U.isKana(cp) return U.isHiragana(cp) or U.isKatakana(cp) end

-- CJK ideographs, including extension A, compatibility ideographs and the
-- iteration mark 々 (counts as kanji for furigana purposes).
function U.isHan(cp)
    return between(cp, 0x4E00, 0x9FFF) or between(cp, 0x3400, 0x4DBF) or between(cp, 0xF900, 0xFAFF)
        or between(cp, 0x20000, 0x2FA1F) or cp == 0x3005 or cp == 0x3006 or cp == 0x30F6
end

function U.isHangul(cp)
    return between(cp, 0xAC00, 0xD7A3) or between(cp, 0x1100, 0x11FF) or between(cp, 0x3130, 0x318F)
end

function U.isLatin(cp)
    return between(cp, 0x41, 0x5A) or between(cp, 0x61, 0x7A) or between(cp, 0xC0, 0x24F)
end

function U.isDigit(cp) return between(cp, 0x30, 0x39) or between(cp, 0xFF10, 0xFF19) end

-- Counts characters per script.
function U.scripts(s)
    local r = { han = 0, kana = 0, hangul = 0, latin = 0, other = 0, total = 0 }
    for ch in tostring(s or ""):gmatch(U.CHAR_PATTERN) do
        local cp = U.codepoint(ch)
        r.total = r.total + 1
        if U.isKana(cp) and cp ~= 0x30FB then r.kana = r.kana + 1 -- ・ is punctuation
        elseif U.isHan(cp) then r.han = r.han + 1
        elseif U.isHangul(cp) then r.hangul = r.hangul + 1
        elseif U.isLatin(cp) then r.latin = r.latin + 1
        else r.other = r.other + 1 end
    end
    return r
end

function U.hasHan(s) return U.scripts(s).han > 0 end

-- Katakana -> hiragana (ヴ and the long mark are left alone).
function U.toHiragana(s)
    local out = {}
    for ch in tostring(s or ""):gmatch(U.CHAR_PATTERN) do
        local cp = U.codepoint(ch)
        if cp >= 0x30A1 and cp <= 0x30F6 then
            out[#out + 1] = U.char(cp - 0x60)
        else
            out[#out + 1] = ch
        end
    end
    return table.concat(out)
end

-- Set of characters from a string: U.set("、。")["、"] == true
function U.set(str)
    local t = {}
    for ch in str:gmatch(U.CHAR_PATTERN) do t[ch] = true end
    return t
end

-- Remove characters in `set` (a table from U.set) from the start and/or end.
function U.stripSet(s, set, where)
    local cs = U.chars(s)
    local i, j = 1, #cs
    if where ~= "end" then
        while i <= j and set[cs[i]] do i = i + 1 end
    end
    if where ~= "start" then
        while j >= i and set[cs[j]] do j = j - 1 end
    end
    return table.concat(cs, "", i, j)
end

-- Remove every character in `set`.
function U.removeSet(s, set)
    local out = {}
    for ch in tostring(s or ""):gmatch(U.CHAR_PATTERN) do
        if not set[ch] then out[#out + 1] = ch end
    end
    return table.concat(out)
end

-- True when every character is in `set`.
function U.onlySet(s, set)
    for ch in tostring(s or ""):gmatch(U.CHAR_PATTERN) do
        if not set[ch] then return false end
    end
    return true
end

local SPACES = U.set(" \t\r\n\194\160\227\128\128")

function U.trim(s)
    return U.stripSet(tostring(s or ""), SPACES)
end

-- Collapse runs of whitespace (including newlines) into a single space.
function U.squash(s)
    return U.trim((tostring(s or ""):gsub("%s+", " ")))
end

-- Truncate to n characters, adding "…" when cut.
function U.ellipsize(s, n)
    if U.len(s) <= n then return s end
    return U.sub(s, 1, math.max(1, n - 1)) .. "…"
end

return U
