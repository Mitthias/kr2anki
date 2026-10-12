-- English–English dictionaries (WordNet, Webster's 1913, learner's dictionaries):
--   /rʌn/ verb 1. to move swiftly on foot …
--   n 1: a score in baseball …; "the Yankees scored 3 runs" [syn: {tally}]
return {
    id = "english_english",
    name = "English–English",
    description = "IPA in // or [], POS words, numbered senses, quoted examples.",
    match = { names = { "wordnet", "webster", "oxford advanced", "oald", "collins", "longman", "merriam",
                        "cambridge", "macmillan", "english-english", "english english", "en-en", "gcide" },
              lang_in = { "en" }, lang_out = { "en" } },
    reading = {
        { pattern = "/([^/]+)/", script = "ipa" },
        { pattern = "%[([^%]]+)%]", script = "ipa" },
    },
    senses = { "numbered", "lines" },
    markers = { "dot", "colon", "paren", "rparen", "circled", "bare" },
    examples = { prefixes = { "e.g.", "example:", "examples:", "▸", "•" }, quoted = true, bilingual = false },
    notes = {
        prefixes = { "syn:", "synonyms", "see also", "usage", "note:", "antonym", "origin", "etymology", "derived" },
        headers = { "Derived forms:", "Phrases:", "Idioms:", "Phrasal verbs:", "Origin:", "Word origin" },
        inline = { "%[syn:%s*(.-)%]", "%[ant:%s*(.-)%]", "%[also:%s*(.-)%]" },
    },
}
