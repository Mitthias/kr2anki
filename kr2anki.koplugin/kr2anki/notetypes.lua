--[[--
"KR2Anki Word" and "KR2Anki Expression" note types: fields, card templates,
styling, and how an item becomes note fields and tags. Pure Lua.

Optional cards: Anki generates every template for every note, so each front
is wrapped in a flag field ({{#CardCloze}}…{{/CardCloze}}); an empty flag
means an empty front, which means no card.
--]]

local Lang = require("kr2anki/lang")
local Ruby = require("kr2anki/ruby")
local U = require("kr2anki/u8")

local N = {}

N.WORD_MODEL = "KR2Anki Word"
N.EXPR_MODEL = "KR2Anki Expression"

-- Stable ids used in .apkg files, so re-importing updates the same note types.
N.WORD_MODEL_ID = 1760000000101
N.EXPR_MODEL_ID = 1760000000102

N.WORD_FIELDS = {
    "Word", "SurfaceForm", "Reading", "PitchAccent", "Sound", "POS", "Definition", "FullDefinition",
    "Sentence", "SentenceCloze", "SentenceTranslation", "DictExamples", "UsageNotes", "PersonalNote",
    "Source", "Language", "LookupDate", "LookupCount", "UID", "CardRecognition", "CardCloze", "CardCharReading",
}

N.EXPR_FIELDS = {
    "Pattern", "Meaning", "Formation", "Nuance", "Sentence", "SentenceCloze", "PersonalNote", "Source",
    "Language", "UID", "CardRecognition", "CardCloze",
}

-- Card settings keys, in menu order.
N.CARD_SETTINGS = {
    { key = "recognition", text = "Word recognition", sub = "sentence → meaning", default = true },
    { key = "cloze", text = "Word cloze", sub = "sentence with a blank", default = true },
    { key = "char_reading", text = "Character → reading", sub = "Japanese and Chinese words with kanji/hanzi", default = true },
    { key = "expr_recognition", text = "Expression recognition", sub = "pattern → meaning", default = true },
    { key = "expr_cloze", text = "Expression cloze", sub = "sentence with the pattern blanked", default = false },
}

function N.defaultCards()
    local t = {}
    for _, c in ipairs(N.CARD_SETTINGS) do t[c.key] = c.default end
    return t
end

-- Styling --------------------------------------------------------------------

local function night(selectors)
    local out = {}
    for sel in selectors:gmatch("[^,]+") do
        sel = U.trim(sel)
        out[#out + 1] = ".night_mode " .. sel
        out[#out + 1] = ".nightMode " .. sel
    end
    return table.concat(out, ", ")
end

N.CSS = table.concat({
    ".card { font-family: system-ui, -apple-system, Roboto, 'Noto Sans', 'Noto Sans CJK JP', 'Noto Sans CJK SC',"
        .. " 'Noto Sans CJK KR', 'Hiragino Sans', 'PingFang SC', sans-serif; font-size: 18px; line-height: 1.5;"
        .. " text-align: left; color: #1b1b1b; background: #faf9f6; margin: 0; }",
    ".card.night_mode, .card.nightMode, " .. night(".card") .. " { color: #e8e8e8; background: #1c1c1e; }",
    ".kr { max-width: 34em; margin: 0 auto; padding: 1.4em 1.1em 1em; }",
    ".kr-front { min-height: 80vh; display: flex; flex-direction: column; justify-content: center; text-align: center; }",
    ".sentence { font-family: 'Noto Serif', 'Noto Serif CJK JP', 'Noto Serif CJK SC', 'Noto Serif CJK KR',"
        .. " 'Source Han Serif', 'Hiragino Mincho ProN', 'Songti SC', Georgia, serif; font-size: 1.35em; line-height: 1.75; }",
    ".sentence b, .accent { color: #1f5fbf; font-weight: 700; }",
    night(".sentence b, .accent") .. " { color: #8ab4f8; }",
    ".cloze { display: inline-block; min-width: 4em; border-bottom: 2px solid #1f5fbf; color: #1f5fbf; font-weight: 700;"
        .. " text-align: center; font-family: system-ui, sans-serif; font-size: .8em; }",
    night(".cloze") .. " { color: #8ab4f8; border-color: #8ab4f8; }",
    ".meta, .source, .pos, .sub { color: #77736c; font-size: .8em; }",
    night(".meta, .source, .pos, .sub") .. " { color: #9a9a9e; }",
    ".meta { margin-top: 1.2em; }",
    ".label { display: block; font-size: .68em; font-weight: 700; letter-spacing: .1em; text-transform: uppercase;"
        .. " color: #77736c; margin: 1em 0 .2em; }",
    night(".label") .. " { color: #9a9a9e; }",
    ".head { display: flex; align-items: flex-start; justify-content: space-between; gap: .6em; }",
    ".hw { display: flex; flex-direction: column; }",
    ".hw .word-line { order: 1; font-size: 2em; font-weight: 700; line-height: 1.25; }",
    ".hw .ruby-line { order: 2; color: #77736c; font-size: .95em; }",
    ".hw:has(ruby) .word-line { display: none; }",
    ".hw:has(ruby) .ruby-line { order: 1; font-size: 2em; font-weight: 700; color: inherit; line-height: 1.6; }",
    night(".hw .ruby-line") .. " { color: #9a9a9e; }",
    night(".hw:has(ruby) .ruby-line") .. " { color: inherit; }",
    "ruby rt { font-size: .45em; font-weight: 400; }",
    ".definition { font-size: 1.3em; font-weight: 600; margin: .6em 0 .4em; line-height: 1.35; }",
    ".rule { border: 0; border-top: 1px solid #d9d6cf; margin: .9em 0; }",
    night(".rule") .. " { border-color: #3a3a3c; }",
    ".small-sentence { font-size: 1.05em; }",
    ".examples div { margin-bottom: .3em; }",
    ".note { background: #efede8; border-radius: 6px; padding: .6em .8em; margin-top: 1em; }",
    night(".note") .. " { background: #2a2a2c; }",
    ".note .label { display: inline; margin: 0; }",
    "details.full { margin-top: 1em; }",
    "details.full summary { cursor: pointer; }",
    "details.full div { margin-top: .4em; font-size: .9em; }",
    ".source { border-top: 1px solid #d9d6cf; margin-top: 1.6em; padding-top: .6em; }",
    night(".source") .. " { border-color: #3a3a3c; }",
    -- shrinks with the screen so long words fit a phone (390 px) on one line
    ".huge { font-size: min(4.2em, 15vw); font-weight: 700; line-height: 1.3; word-break: keep-all; }",
    ".huge ruby rt { font-size: .3em; }",
    ".prompt { margin-top: .6em; letter-spacing: .12em; font-size: .8em; color: #77736c; text-transform: uppercase; }",
    ".pattern { font-size: 1.7em; font-weight: 700; margin: .1em 0 .3em; }",
    ".expr-tag { font-size: .7em; letter-spacing: .1em; text-transform: uppercase; color: #77736c; }",
    ".meaning { font-size: 1.45em; font-weight: 700; margin: .2em 0 .6em; }",
    ".hint { margin-top: 1.2em; }",
    ".hint .label { margin-bottom: .1em; }",
    ".quote { background: #efede8; border-radius: 6px; padding: .8em 1em; margin-top: 1em; }",
    night(".quote") .. " { background: #2a2a2c; }",
}, "\n")

-- Templates ------------------------------------------------------------------

local HEADWORD = '<div class="hw">{{#Reading}}<div class="ruby-line">{{furigana:Reading}}</div>{{/Reading}}'
    .. '<div class="word-line">{{Word}}</div></div>'

local SOURCE = '{{#Source}}<div class="source">{{Source}}</div>{{/Source}}'

N.WORD_TEMPLATES = {
    {
        name = "Recognition",
        front = '{{#CardRecognition}}<div class="kr kr-front lang-{{Language}}">'
            .. '{{#Sentence}}<div class="sentence">{{Sentence}}</div>{{/Sentence}}'
            .. '{{^Sentence}}<div class="hw"><div class="word-line">{{Word}}</div></div>{{/Sentence}}'
            .. '{{#Source}}<div class="meta">{{Source}}</div>{{/Source}}</div>{{/CardRecognition}}',
        back = '<div class="kr kr-back lang-{{Language}}">'
            .. '{{#Sentence}}<div class="sentence small-sentence">{{Sentence}}</div><hr class="rule">{{/Sentence}}'
            .. '<div class="head">' .. HEADWORD .. '{{#Sound}}<div class="sound">{{Sound}}</div>{{/Sound}}</div>'
            .. '{{#POS}}<div class="pos">{{POS}}{{#PitchAccent}} · [{{PitchAccent}}]{{/PitchAccent}}</div>{{/POS}}'
            .. '{{#Definition}}<div class="definition">{{Definition}}</div>{{/Definition}}'
            .. '{{#UsageNotes}}<span class="label">Usage</span><div>{{UsageNotes}}</div>{{/UsageNotes}}'
            .. '{{#DictExamples}}<span class="label">Examples</span><div class="examples">{{DictExamples}}</div>{{/DictExamples}}'
            .. '{{#SentenceTranslation}}<span class="label">Translation</span><div>{{SentenceTranslation}}</div>{{/SentenceTranslation}}'
            .. '{{#PersonalNote}}<div class="note"><span class="label">Note · </span>{{PersonalNote}}</div>{{/PersonalNote}}'
            .. '{{#FullDefinition}}<details class="full"><summary>Full entry</summary><div>{{FullDefinition}}</div></details>{{/FullDefinition}}'
            .. SOURCE .. '</div>',
    },
    {
        name = "Cloze",
        front = '{{#CardCloze}}{{#SentenceCloze}}<div class="kr kr-front lang-{{Language}}">'
            .. '<div class="sentence">{{SentenceCloze}}</div>'
            .. '{{#Definition}}<div class="hint"><span class="label">Hint{{#POS}} · {{POS}}{{/POS}}</span>'
            .. '<div>{{Definition}}</div></div>{{/Definition}}'
            .. '{{#Source}}<div class="meta">{{Source}}</div>{{/Source}}</div>{{/SentenceCloze}}{{/CardCloze}}',
        back = '<div class="kr kr-back lang-{{Language}}">'
            .. '<div class="sentence">{{Sentence}}</div><hr class="rule">'
            .. '<div class="head">' .. HEADWORD .. '{{#Sound}}<div class="sound">{{Sound}}</div>{{/Sound}}</div>'
            .. '{{#Definition}}<div class="definition">{{Definition}}</div>{{/Definition}}'
            .. SOURCE .. '</div>',
    },
    {
        name = "Reading",
        front = '{{#CardCharReading}}<div class="kr kr-front"><div class="huge">{{Word}}</div>'
            .. '<div class="prompt">Reading?</div></div>{{/CardCharReading}}',
        back = '<div class="kr kr-front"><div class="huge">{{furigana:Reading}}</div>'
            .. '{{#Sound}}<div class="sound">{{Sound}}</div>{{/Sound}}'
            .. '{{#Definition}}<div class="definition">{{Definition}}</div>{{/Definition}}'
            .. '{{#Sentence}}<div class="quote sentence small-sentence">{{Sentence}}</div>{{/Sentence}}</div>',
    },
}

N.EXPR_TEMPLATES = {
    {
        name = "Recognition",
        front = '{{#CardRecognition}}<div class="kr kr-front lang-{{Language}}">'
            .. '<div class="expr-tag">◆ Expression</div><div class="pattern">{{Pattern}}</div>'
            .. '{{#Sentence}}<div class="sentence">{{Sentence}}</div>{{/Sentence}}'
            .. '{{#Source}}<div class="meta">{{Source}}</div>{{/Source}}</div>{{/CardRecognition}}',
        back = '<div class="kr kr-back lang-{{Language}}">'
            .. '<div class="expr-tag">◆ Expression</div><div class="pattern">{{Pattern}}</div>'
            .. '{{#Meaning}}<div class="meaning">{{Meaning}}</div>{{/Meaning}}<hr class="rule">'
            .. '{{#Formation}}<span class="label">Formation</span><div>{{Formation}}</div>{{/Formation}}'
            .. '{{#Nuance}}<span class="label">Nuance</span><div>{{Nuance}}</div>{{/Nuance}}'
            .. '{{#Sentence}}<div class="quote sentence small-sentence">{{Sentence}}</div>{{/Sentence}}'
            .. '{{#PersonalNote}}<div class="note"><span class="label">Note · </span>{{PersonalNote}}</div>{{/PersonalNote}}'
            .. SOURCE .. '</div>',
    },
    {
        name = "Cloze",
        front = '{{#CardCloze}}{{#SentenceCloze}}<div class="kr kr-front lang-{{Language}}">'
            .. '<div class="sentence">{{SentenceCloze}}</div>'
            .. '{{#Meaning}}<div class="hint"><span class="label">Hint</span><div>{{Meaning}}</div></div>{{/Meaning}}'
            .. '{{#Source}}<div class="meta">{{Source}}</div>{{/Source}}</div>{{/SentenceCloze}}{{/CardCloze}}',
        back = '<div class="kr kr-back lang-{{Language}}">'
            .. '<div class="sentence">{{Sentence}}</div><hr class="rule">'
            .. '<div class="pattern">{{Pattern}}</div>'
            .. '{{#Meaning}}<div class="meaning">{{Meaning}}</div>{{/Meaning}}'
            .. '{{#Formation}}<span class="label">Formation</span><div>{{Formation}}</div>{{/Formation}}'
            .. SOURCE .. '</div>',
    },
}

-- Which flag field gates each template (used to create .apkg card rows).
N.WORD_TEMPLATE_FLAGS = { "CardRecognition", "CardCloze", "CardCharReading" }
N.EXPR_TEMPLATE_FLAGS = { "CardRecognition", "CardCloze" }
-- Extra fields a template front needs besides its flag.
N.TEMPLATE_REQUIRES = { Cloze = "SentenceCloze" }

function N.model(kind)
    if kind == "expression" then
        return { name = N.EXPR_MODEL, id = N.EXPR_MODEL_ID, fields = N.EXPR_FIELDS, templates = N.EXPR_TEMPLATES,
                 flags = N.EXPR_TEMPLATE_FLAGS }
    end
    return { name = N.WORD_MODEL, id = N.WORD_MODEL_ID, fields = N.WORD_FIELDS, templates = N.WORD_TEMPLATES,
             flags = N.WORD_TEMPLATE_FLAGS }
end

-- Parameters for AnkiConnect "createModel".
function N.createModelParams(kind)
    local m = N.model(kind)
    local tmpls = {}
    for _, t in ipairs(m.templates) do
        tmpls[#tmpls + 1] = { Name = t.name, Front = t.front, Back = t.back }
    end
    return {
        modelName = m.name,
        inOrderFields = m.fields,
        css = N.CSS,
        isCloze = false,
        cardTemplates = tmpls,
    }
end

-- Field values ---------------------------------------------------------------

function N.escape(s)
    s = tostring(s or "")
    return (s:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub('"', "&quot;"))
end

-- Escaped text with line breaks as <br>.
function N.multiline(s)
    s = U.trim(tostring(s or ""))
    if s == "" then return "" end
    return (N.escape(s):gsub("\r?\n", "<br>"))
end

-- Sentence with the highlight in <b>, and the cloze version.
function N.sentenceFields(sent)
    if not sent or sent.missing or not sent.text or sent.text == "" then return "", "" end
    local text, hs, he = sent.text, sent.hl_start, sent.hl_end
    if not hs or not he or he < hs or he > #text then
        return N.escape(text), ""
    end
    local pre, mid, post = text:sub(1, hs - 1), text:sub(hs, he), text:sub(he + 1)
    return N.escape(pre) .. "<b>" .. N.escape(mid) .. "</b>" .. N.escape(post),
        N.escape(pre) .. '<span class="cloze">[…]</span>' .. N.escape(post)
end

-- Reading field in Anki ruby syntax (or IPA / romanization).
function N.readingField(item, opts)
    opts = opts or {}
    local lang = item.language
    local reading = U.trim(item.reading or "")
    local word = item.lemma or ""
    if lang == "ja" then
        if reading == "" then return "" end
        if opts.ja_furigana == false then
            return reading ~= word and N.escape(reading) or ""
        end
        local ruby = Ruby.furigana(word, reading)
        if ruby then return N.escape(ruby) end
        return reading ~= word and N.escape(reading) or ""
    elseif lang == "zh" then
        if reading == "" then return "" end
        local ruby = Ruby.pinyin(word, reading)
        return N.escape(ruby or Ruby.numberedToMarks(reading))
    elseif lang == "ko" then
        if not opts.ko_romanize then return "" end
        if reading ~= "" and U.scripts(reading).latin > 0 then return N.escape(reading) end
        return N.escape(Ruby.romanizeKorean(word))
    end
    if reading == "" then return "" end
    -- IPA in [] would be read as ruby by the furigana filter
    local ipa = reading:match("^%[(.*)%]$")
    if ipa then reading = "/" .. ipa .. "/" end
    return N.escape(reading)
end

local function bookTitle(book, lang)
    if not book or not book.title or book.title == "" then return nil end
    if lang == "ja" then return "『" .. book.title .. "』" end
    if lang == "zh" then return "《" .. book.title .. "》" end
    return book.title
end

-- "『こころ』 · 夏目漱石 · p. 3 · JMdict"
function N.source(item, sent)
    local parts = {}
    local book = sent and sent.book
    local title = bookTitle(book, item.language)
    if title then parts[#parts + 1] = title end
    if book and book.authors and book.authors ~= "" then parts[#parts + 1] = book.authors end
    if sent and sent.page and tostring(sent.page) ~= "" then parts[#parts + 1] = "p. " .. tostring(sent.page) end
    if item.dictionary and item.dictionary ~= "" and item.type ~= "expression" then
        parts[#parts + 1] = item.dictionary
    end
    return N.escape(table.concat(parts, " · "))
end

local function lines(list_or_text)
    if type(list_or_text) == "table" then return table.concat(list_or_text, "\n") end
    return list_or_text
end

--[[--
Note fields for an item.
@param item table from the database (with item.sentence = primary sentence)
@param opts { cards = {recognition=…}, ja_furigana = bool, ko_romanize = bool, sound = "[sound:x.mp3]" }
@treturn table fields, string model name
--]]
function N.buildFields(item, opts)
    opts = opts or {}
    local cards = opts.cards or N.defaultCards()
    local sent = item.sentence
    local sentence, cloze = N.sentenceFields(sent)
    local f = {}
    if item.type == "expression" then
        f.Pattern = N.escape(item.pattern ~= nil and item.pattern ~= "" and item.pattern or item.surface)
        f.Meaning = N.multiline(item.meaning)
        f.Formation = N.multiline(item.formation)
        f.Nuance = N.multiline(item.nuance)
        f.Sentence = sentence
        f.SentenceCloze = cloze
        f.PersonalNote = N.multiline(item.personal_note)
        f.Source = N.source(item, sent)
        f.Language = item.language or ""
        f.UID = item.uid
        f.CardRecognition = cards.expr_recognition and "1" or ""
        f.CardCloze = (cards.expr_cloze and cloze ~= "") and "1" or ""
        return f, N.EXPR_MODEL
    end
    local reading = N.readingField(item, opts)
    f.Word = N.escape(item.lemma)
    f.SurfaceForm = N.escape(item.surface)
    f.Reading = reading
    f.PitchAccent = N.escape(item.pitch_accent)
    f.Sound = opts.sound or ""
    f.POS = N.escape(item.pos)
    f.Definition = N.multiline(item.definition)
    f.FullDefinition = N.multiline(item.full_definition)
    f.Sentence = sentence
    f.SentenceCloze = cloze
    f.SentenceTranslation = ""
    f.DictExamples = N.multiline(lines(item.dict_examples))
    f.UsageNotes = N.multiline(lines(item.usage_notes))
    f.PersonalNote = N.multiline(item.personal_note)
    f.Source = N.source(item, sent)
    f.Language = item.language or ""
    f.LookupDate = item.created_at and os.date("%Y-%m-%d", item.created_at) or ""
    f.LookupCount = tostring(item.lookup_count or 1)
    f.UID = item.uid
    f.CardRecognition = cards.recognition and "1" or ""
    f.CardCloze = (cards.cloze and cloze ~= "") and "1" or ""
    local cjk = item.language == "ja" or item.language == "zh"
    f.CardCharReading = (cards.char_reading and cjk and U.hasHan(item.lemma) and reading ~= "") and "1" or ""
    return f, N.WORD_MODEL
end

-- Anki tags cannot contain spaces.
function N.tagValue(s)
    s = U.trim(tostring(s or ""))
    s = s:gsub("%s+", "_"):gsub('"', "")
    return s
end

--[[--
Tags for an item.
@param item table
@param books list of { title, authors } the item was saved from
--]]
function N.tags(item, books)
    local tags = { "lang::" .. N.tagValue(Lang.name(item.language)) }
    local seen = {}
    for _, b in ipairs(books or {}) do
        if b.title and b.title ~= "" and not seen["b" .. b.title] then
            seen["b" .. b.title] = true
            tags[#tags + 1] = "book::" .. N.tagValue(b.title)
        end
        if b.authors and b.authors ~= "" then
            for author in tostring(b.authors):gmatch("[^\n]+") do
                if not seen["a" .. author] then
                    seen["a" .. author] = true
                    tags[#tags + 1] = "author::" .. N.tagValue(author)
                end
            end
        end
    end
    if item.dictionary and item.dictionary ~= "" then
        tags[#tags + 1] = "dict::" .. N.tagValue(item.dictionary)
    end
    tags[#tags + 1] = item.type == "expression" and "type::expression" or "type::word"
    tags[#tags + 1] = "src::kr2anki"
    return tags
end

-- Appends a sentence to an existing note's Sentence field (merge).
function N.mergeSentence(existing, new_sentence)
    existing = U.trim(existing or "")
    if new_sentence == "" or existing:find(new_sentence, 1, true) then return existing end
    if existing == "" then return new_sentence end
    return existing .. "<br><br>" .. new_sentence
end

local function sampleSentence(text, target, book, page)
    local hs, he = text:find(target, 1, true)
    return { text = text, hl_start = hs, hl_end = he, book = book, page = page }
end

-- Stand-in note used by the bundled note-type package and template tests.
function N.sampleItem(kind)
    local book = { title = "こころ", authors = "夏目漱石" }
    if kind == "expression" then
        return {
            type = "expression", language = "ja", uid = "kr2anki-sample-expression",
            surface = "なくてはならない", pattern = "〜なくてはならない", meaning = "must; have to; cannot avoid",
            formation = "V-ない stem + なくてはならない", nuance = "Firmer and more written than 〜なきゃ.",
            sentence = sampleSentence("その犠牲としてみんなこの淋しみを味わわなくてはならないでしょう", "なくてはならない", book, 38),
        }
    end
    return {
        type = "word", language = "ja", uid = "kr2anki-sample-word", lemma = "打ち明ける", surface = "打ち明けない",
        reading = "うちあける", pos = "Ichidan verb, transitive", definition = "to confide (a secret); to reveal; to disclose",
        full_definition = "1. to confide (a secret); to reveal; to disclose\n2. to be frank\n3. to empty out (a container) · archaic",
        dictionary = "JMdict", lookup_count = 1, created_at = 0,
        sentence = sampleSentence("だからここでもただ先生と書くだけで本名は打ち明けない。", "打ち明けない", book, 3),
    }
end

return N
