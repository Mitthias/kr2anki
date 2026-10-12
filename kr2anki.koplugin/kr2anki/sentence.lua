--[[--
Cut the context KOReader gives around a selection down to one sentence.

    local S = require("kr2anki/sentence")
    local r = S.extract{ prev = "…", selection = "打ち明けない", next = "…", lang = "ja" }
    -- r.text, r.hl_start, r.hl_end (byte offsets, 1-based, inclusive),
    -- r.missing (no context available), r.trimmed (cut with "…")

Rules
* English and other Latin-script languages: . ! ? end a sentence, except after
  known abbreviations, single-letter initials, inside decimals, or when the
  next word starts in lower case. Trimmed to about 40 words.
* Chinese: 。！？ end a sentence. Japanese: the same, but a terminator inside
  「」 or 『』 does not end the sentence, so quotes stay intact; if a whole quote
  is longer than the trim limit, the inner sentence is used instead. Both are
  trimmed to about 80 characters.
* Korean: . ! ? (and 。！？). Trimmed by words, like English.
* A line break always ends a sentence.
* Closing quotes and brackets after a terminator belong to the sentence.
Pure Lua.
--]]

local U = require("kr2anki/u8")

local S = {}

S.MAX_CJK = 80
S.MAX_WORDS = 40

local CJK_TERMINATORS = { ["。"] = true, ["！"] = true, ["？"] = true, ["｡"] = true }
local LATIN_TERMINATORS = { ["."] = true, ["!"] = true, ["?"] = true }
local CLOSERS = {
    ["”"] = true, ["’"] = true, ['"'] = true, ["'"] = true, [")"] = true, ["]"] = true,
    ["」"] = true, ["』"] = true, ["）"] = true, ["】"] = true, ["》"] = true, ["〉"] = true,
    ["»"] = true, ["›"] = true,
}
local QUOTE_OPEN = { ["「"] = true, ["『"] = true }
local QUOTE_CLOSE = { ["」"] = true, ["』"] = true }

-- Lower-case, without the trailing dot.
local ABBREVIATIONS = {}
for a in ([[mr mrs ms dr prof sr jr st mt vs etc e.g i.e eg ie a.m p.m am pm u.s u.k
          inc ltd co corp no nos fig figs vol vols pp p cf approx capt col gen lt sgt rev hon
          gov sen rep messrs mme mlle jan feb mar apr jun jul aug sep sept oct nov dec
          ave blvd rd dept univ est ed eds al ch chap sec op ca viz]]):gmatch("%S+") do
    ABBREVIATIONS[a] = true
end

local function isSpace(ch) return ch == " " or ch == "\t" or ch == "\194\160" or ch == "\227\128\128" end

-- Split into characters, collapsing whitespace runs: spaces -> " ",
-- anything containing a newline -> "\n".
local function normChars(s)
    local out = {}
    local pending -- nil, " " or "\n"
    for ch in tostring(s or ""):gmatch(U.CHAR_PATTERN) do
        if ch == "\r" or ch == "\n" then
            pending = "\n"
        elseif isSpace(ch) then
            if pending ~= "\n" then pending = " " end
        else
            if pending then
                out[#out + 1] = pending
                pending = nil
            end
            out[#out + 1] = ch
        end
    end
    if pending then out[#out + 1] = pending end
    return out
end

local function isLower(ch)
    local cp = U.codepoint(ch)
    return cp and ((cp >= 0x61 and cp <= 0x7A) or (cp >= 0xDF and cp <= 0xFF))
end

local function isUpper(ch)
    local cp = U.codepoint(ch)
    return cp and ((cp >= 0x41 and cp <= 0x5A) or (cp >= 0xC0 and cp <= 0xDE))
end

-- The word (letters and inner dots) that ends right before index i.
local function wordBefore(cs, i)
    local j = i - 1
    local parts = {}
    while j >= 1 and cs[j] ~= " " and cs[j] ~= "\n" and not CLOSERS[cs[j]] and cs[j] ~= "(" and cs[j] ~= '"' do
        table.insert(parts, 1, cs[j])
        j = j - 1
    end
    return table.concat(parts)
end

-- Is the "." at index i the end of a sentence?
local function periodEnds(cs, i)
    local n = #cs
    -- Decimal number or a dot inside a token (e.g. "3.14", "U.S.A", "example.com").
    local nxt = cs[i + 1]
    if nxt and nxt ~= " " and nxt ~= "\n" and not CLOSERS[nxt] and not LATIN_TERMINATORS[nxt] then
        return false
    end
    -- Ellipsis: a run of dots only ends a sentence if a capital follows.
    local word = wordBefore(cs, i)
    local bare = word:lower():gsub("^[%(%[\"'“‘]+", "")
    if bare ~= "" then
        if ABBREVIATIONS[bare] then return false end
        -- single-letter initial ("J. R. R. Tolkien")
        if U.len(bare) == 1 and isUpper(word:sub(-1)) then return false end
    end
    -- Next visible character after closers/spaces: lower case means the
    -- sentence goes on ("e.g. the", "approx. ten").
    local j = i + 1
    while j <= n and (CLOSERS[cs[j]] or LATIN_TERMINATORS[cs[j]]) do j = j + 1 end
    if j <= n and cs[j] == "\n" then return true end
    while j <= n and cs[j] == " " do j = j + 1 end
    if j <= n and isLower(cs[j]) then return false end
    return true
end

-- Sentence end indexes (inclusive, after closers) over the whole text.
-- respect_quotes: terminators inside 「」『』 are ignored.
local function boundaries(cs, lang, respect_quotes)
    local ends = {}
    local depth = 0
    local n = #cs
    local cjk_only = lang == "ja" or lang == "zh"
    local i = 1
    while i <= n do
        local ch = cs[i]
        if ch == "\n" then
            -- a line break ends the sentence before it
            depth = 0
            ends[#ends + 1] = i - 1
            i = i + 1
        else
            if respect_quotes then
                if QUOTE_OPEN[ch] then depth = depth + 1
                elseif QUOTE_CLOSE[ch] and depth > 0 then depth = depth - 1 end
            end
            local is_term = false
            if depth == 0 then
                if CJK_TERMINATORS[ch] then
                    is_term = true
                elseif not cjk_only and (ch == "!" or ch == "?") then
                    is_term = true
                elseif not cjk_only and ch == "." then
                    is_term = periodEnds(cs, i)
                end
            end
            if is_term then
                local j = i
                -- absorb repeated terminators ("?!", "……。") and closing quotes
                while j < n and (CJK_TERMINATORS[cs[j + 1]] or (not cjk_only and LATIN_TERMINATORS[cs[j + 1]])
                        or cs[j + 1] == "…") do
                    j = j + 1
                end
                while j < n and CLOSERS[cs[j + 1]] do
                    if respect_quotes and QUOTE_CLOSE[cs[j + 1]] and depth > 0 then depth = depth - 1 end
                    j = j + 1
                end
                ends[#ends + 1] = j
                i = j + 1
            else
                i = i + 1
            end
        end
    end
    return ends
end

-- Sentence span [s, e] that contains chars a..b, widened by `extra`
-- sentences on each side.
local function spanFor(cs, ends, a, b, extra)
    local before = {}
    for _, e in ipairs(ends) do
        if e < a then before[#before + 1] = e end
    end
    local after_list = {}
    for _, e in ipairs(ends) do
        if e >= b then after_list[#after_list + 1] = e end
    end
    local s = 1
    local k = #before - (extra or 0)
    if k >= 1 then s = before[k] + 1 end
    local after = after_list[1 + (extra or 0)] or after_list[#after_list]
    local e = after or #cs
    -- trim whitespace at both ends
    while s < a and (cs[s] == " " or cs[s] == "\n") do s = s + 1 end
    while e > b and (cs[e] == " " or cs[e] == "\n") do e = e - 1 end
    return s, e
end

-- Keep at most `max` characters around a..b inside s..e.
local function trimChars(s, e, a, b, max)
    if e - s + 1 <= max then return s, e end
    local sel = b - a + 1
    if sel >= max then return a, b end
    local room = max - sel
    local left = math.floor(room / 2)
    local right = room - left
    local avail_left, avail_right = a - s, e - b
    if avail_left < left then right = right + (left - avail_left); left = avail_left end
    if avail_right < right then left = math.min(avail_left, left + (right - avail_right)); right = avail_right end
    return a - left, b + right
end

-- Keep at most `max` words around a..b inside s..e (word = run without spaces).
local function trimWords(cs, s, e, a, b, max)
    local words = {} -- { first, last }
    local i = s
    while i <= e do
        while i <= e and (cs[i] == " " or cs[i] == "\n") do i = i + 1 end
        if i > e then break end
        local j = i
        while j + 1 <= e and cs[j + 1] ~= " " and cs[j + 1] ~= "\n" do j = j + 1 end
        words[#words + 1] = { i, j }
        i = j + 1
    end
    if #words <= max then return s, e end
    local wa, wb
    for k, w in ipairs(words) do
        if not wa and w[2] >= a then wa = k end
        if w[1] <= b then wb = k end
    end
    wa, wb = wa or 1, wb or #words
    local sel = wb - wa + 1
    if sel >= max then return math.min(words[wa][1], a), math.max(words[wb][2], b) end
    local room = max - sel
    local left = math.floor(room / 2)
    local right = room - left
    local avail_left, avail_right = wa - 1, #words - wb
    if avail_left < left then right = right + (left - avail_left); left = avail_left end
    if avail_right < right then left = math.min(avail_left, left + (right - avail_right)); right = avail_right end
    return math.min(words[wa - left][1], a), math.max(words[wb + right][2], b)
end

local function assemble(cs, s, e, a, b, cut_start, cut_end)
    local parts = {}
    local bytes = 0
    local hl_start, hl_end
    if cut_start then
        parts[#parts + 1] = "…"
        bytes = bytes + #"…"
    end
    for i = s, e do
        local ch = cs[i] == "\n" and " " or cs[i]
        if i == a then hl_start = bytes + 1 end
        parts[#parts + 1] = ch
        bytes = bytes + #ch
        if i == b then hl_end = bytes end
    end
    if cut_end then parts[#parts + 1] = "…" end
    return table.concat(parts), hl_start, hl_end
end

--[[--
@param opts table
  prev, selection, next: strings (prev/next may be nil when unavailable)
  lang: language code
  max_cjk, max_words: trim limits (defaults 80 / 40)
  extra: number of extra sentences to include on each side (default 0)
@treturn table { text, hl_start, hl_end, missing, trimmed }
--]]
function S.extract(opts)
    local sel_raw = U.squash(opts.selection or "")
    local prev, nxt = opts.prev, opts.next
    if (prev == nil or prev == "") and (nxt == nil or nxt == "") then
        return { text = sel_raw, hl_start = 1, hl_end = #sel_raw, missing = true, trimmed = false }
    end
    local lang = opts.lang or "en"
    local pcs, scs, ncs = normChars(prev), normChars(sel_raw), normChars(nxt)
    -- keep a separating space when the context had one around the selection
    local cs = {}
    for _, c in ipairs(pcs) do cs[#cs + 1] = c end
    local a = #cs + 1
    for _, c in ipairs(scs) do cs[#cs + 1] = c end
    local b = #cs
    for _, c in ipairs(ncs) do cs[#cs + 1] = c end
    if b < a then -- empty selection
        return { text = "", hl_start = 1, hl_end = 0, missing = true, trimmed = false }
    end

    local char_based = lang == "zh" or lang == "ja"
    local max_cjk = opts.max_cjk or S.MAX_CJK
    local max_words = opts.max_words or S.MAX_WORDS
    local extra = opts.extra or 0

    local s, e = spanFor(cs, boundaries(cs, lang, lang == "ja"), a, b, extra)
    if lang == "ja" and e - s + 1 > max_cjk then
        -- A long quote: fall back to the sentence inside it.
        local s2, e2 = spanFor(cs, boundaries(cs, lang, false), a, b, extra)
        if s2 <= a and e2 >= b then s, e = s2, e2 end
    end

    local ts, te
    if char_based then
        ts, te = trimChars(s, e, a, b, max_cjk)
    else
        ts, te = trimWords(cs, s, e, a, b, max_words)
    end
    local cut_start, cut_end = ts > s, te < e
    local text, hs, he = assemble(cs, ts, te, a, b, cut_start, cut_end)
    return {
        text = text, hl_start = hs, hl_end = he,
        missing = false, trimmed = cut_start or cut_end,
    }
end

-- Shorter version of the same sentence (half the usual limit).
function S.shorten(opts)
    local o = {}
    for k, v in pairs(opts) do o[k] = v end
    o.max_cjk = math.floor((opts.max_cjk or S.MAX_CJK) / 2)
    o.max_words = math.floor((opts.max_words or S.MAX_WORDS) / 2)
    return S.extract(o)
end

-- The sentence plus one sentence before and after, with a looser limit.
function S.moreContext(opts)
    local o = {}
    for k, v in pairs(opts) do o[k] = v end
    o.extra = (opts.extra or 0) + 1
    o.max_cjk = (opts.max_cjk or S.MAX_CJK) * 2
    o.max_words = (opts.max_words or S.MAX_WORDS) * 2
    return S.extract(o)
end

-- Sentence with the highlighted range wrapped: S.mark(text, s, e, "<b>", "</b>")
function S.mark(text, hs, he, open, close)
    if not hs or not he or he < hs then return text end
    return text:sub(1, hs - 1) .. open .. text:sub(hs, he) .. close .. text:sub(he + 1)
end

return S
