-- Generic fallback profile. Used when no other profile matches a dictionary.
-- This file also documents every field a profile can use.
return {
    id = "generic",                     -- unique id (file name does not matter)
    name = "Generic",                   -- shown in Settings > Dictionary profiles
    description = "Numbered senses if present, otherwise one sense per line.",

    -- How a dictionary is matched automatically (a user choice in Settings
    -- always wins). names: lower-case substrings of the dictionary name;
    -- lang_in / lang_out: language codes from the dictionary's .ifo "lang=".
    match = { names = {}, lang_in = {}, lang_out = {} },

    -- Reading rules, tried in order on the first `lines` lines (default 2;
    -- where = "any" searches every line). The first capture is the reading.
    -- script: kana | pinyin | ipa | hangul | latin | any (the capture must
    -- look like that script). The match is removed from the text unless
    -- remove = false.
    reading = {
        { pattern = "/([^/]+)/", script = "ipa" },
        { pattern = "%[([^%]]+)%]", script = "ipa" },
        { pattern = "【(.-)】", script = "kana" },
        { pattern = "%[([^%]]+)%]", script = "kana" },
        { pattern = "%[([^%]]+)%]", script = "pinyin" },
    },

    -- Sense strategies in order: numbered | slash | lines.
    senses = { "numbered", "lines" },
    -- Number styles for "numbered": paren (1) | dot 1. | rparen 1) | colon 1: |
    -- circled ① | bracket [1] | bare "1 " at line start. First style found wins.
    markers = { "paren", "circled", "dot", "rparen", "colon", "bracket" },
    -- Split glosses inside one sense on this string and rejoin with "; ".
    gloss_separator = nil,

    pos = {
        -- codes = { v1 = "Ichidan verb", P = false }  -- "(v1,vt)" groups
        -- words = { "动词" }                          -- extra POS words at line start
        -- map = { ["vt."] = "transitive verb" }       -- rename POS words
    },
    -- Labels in parentheses inside senses: (arch) -> "· archaic"; false drops it.
    tags = {},

    examples = {
        prefixes = { "e.g.", "eg:", "example:", "例:", "例：", "例句", "▸" },
        quoted = false,     -- text in "double quotes" inside a sense is an example
        bilingual = true,   -- a line mixing a CJK sentence and a translation
    },
    notes = {
        prefixes = { "syn:", "synonyms:", "see also", "usage:", "note:", "antonym", "ant:" },
        headers = {},       -- a line starting with one of these, and every line after it
        inline = { "%[syn:%s*(.-)%]" }, -- patterns removed from senses into notes
        sense_prefixes = {},            -- senses starting with these become notes
    },
    -- pitch = { pattern = "%[(%d)%]" },  -- pitch accent number, Japanese only
}
