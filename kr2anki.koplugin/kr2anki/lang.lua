--[[--
Language codes, names and detection. Pure Lua.

Detection order (see DECISIONS.md):
  1. Kana in the word means Japanese, Hangul means Korean: these scripts are
     unambiguous, so they win over metadata that says otherwise.
  2. Han-only words: the book's language (per-book override first, then the
     book metadata) decides between Chinese and Japanese; then the language
     assigned to the dictionary; Chinese if nothing says otherwise.
  3. Latin and other scripts: the book's language when it is not a CJK
     language, then the dictionary's language, then English for Latin text.
--]]

local U = require("kr2anki/u8")

local L = {}

L.FULL = { en = true, zh = true, ja = true, ko = true }

L.NAMES = {
    en = "English", zh = "Chinese", ja = "Japanese", ko = "Korean",
    fr = "French", de = "German", es = "Spanish", it = "Italian", pt = "Portuguese",
    ru = "Russian", nl = "Dutch", sv = "Swedish", pl = "Polish", tr = "Turkish",
    ar = "Arabic", he = "Hebrew", el = "Greek", vi = "Vietnamese", th = "Thai",
    id = "Indonesian", uk = "Ukrainian", cs = "Czech", da = "Danish", fi = "Finnish",
    no = "Norwegian", nb = "Norwegian", hu = "Hungarian", ro = "Romanian", la = "Latin",
    eo = "Esperanto", fa = "Persian", hi = "Hindi",
}

-- Short badge text for the home screen ("日", "En" ...).
L.BADGES = { en = "En", zh = "中", ja = "日", ko = "한" }

local ALIASES = {
    eng = "en", english = "en",
    zho = "zh", chi = "zh", cmn = "zh", chinese = "zh", yue = "zh", ["zh-hans"] = "zh", ["zh-hant"] = "zh",
    jpn = "ja", japanese = "ja", jp = "ja",
    kor = "ko", korean = "ko", kr = "ko",
    fre = "fr", fra = "fr", ger = "de", deu = "de", spa = "es", ita = "it", por = "pt",
    rus = "ru", dut = "nl", nld = "nl", swe = "sv", pol = "pl", tur = "tr", ara = "ar",
    heb = "he", gre = "el", ell = "el", vie = "vi", tha = "th", ind = "id", ukr = "uk",
    cze = "cs", ces = "cs", dan = "da", fin = "fi", nor = "no", nob = "nb", hun = "hu",
    rum = "ro", ron = "ro", lat = "la", epo = "eo", per = "fa", fas = "fa", hin = "hi",
}

-- "ja-JP", "jpn", "Japanese", "zh_CN" -> "ja", "ja", "ja", "zh". nil for empty.
function L.normalize(code)
    if type(code) ~= "string" then return nil end
    local c = U.trim(code):lower():gsub("_", "-")
    if c == "" or c == "und" or c == "unknown" then return nil end
    if ALIASES[c] then return ALIASES[c] end
    local primary = c:match("^([a-z]+)")
    if not primary then return nil end
    if ALIASES[primary] then return ALIASES[primary] end
    if #primary == 2 then return primary end
    return primary
end

function L.name(code)
    code = L.normalize(code)
    if not code then return "Unknown" end
    return L.NAMES[code] or code:upper()
end

-- Inverse of name(): "Japanese" -> "ja".
function L.fromName(name)
    for code, n in pairs(L.NAMES) do
        if n == name then return code end
    end
    return L.normalize(name)
end

function L.isCJK(code)
    return code == "zh" or code == "ja" or code == "ko"
end

function L.isFull(code)
    return L.FULL[code] == true
end

-- Uses whole-character sentence trimming rather than word trimming.
function L.isCharBased(code)
    return code == "zh" or code == "ja"
end

--[[--
Detect the language of a looked-up word.
@param opts { word, book_override, book_lang, dict_lang, default_latin = "en" }
@treturn string language code
@treturn string reason (for diagnostics)
--]]
function L.detect(opts)
    local s = U.scripts(opts.word or "")
    local book = L.normalize(opts.book_override) or L.normalize(opts.book_lang)
    local dict = L.normalize(opts.dict_lang)
    if s.kana > 0 then return "ja", "kana" end
    if s.hangul > 0 then return "ko", "hangul" end
    if s.han > 0 then
        if book == "zh" or book == "ja" then return book, "book" end
        if dict == "zh" or dict == "ja" then return dict, "dictionary" end
        return "zh", "han-default"
    end
    if book and not L.isCJK(book) then return book, "book" end
    if dict and not L.isCJK(dict) then return dict, "dictionary" end
    if s.latin > 0 then return opts.default_latin or "en", "latin" end
    return book or dict or "en", "fallback"
end

-- "Reading::{Language}" -> "Reading::Japanese"
function L.deckName(pattern, code)
    pattern = (pattern and pattern ~= "") and pattern or "Reading::{Language}"
    local name = pattern:gsub("{Language}", function() return L.name(code) end)
        :gsub("{lang}", function() return code or "xx" end)
    return name
end

return L
