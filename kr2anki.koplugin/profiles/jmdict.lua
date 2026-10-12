-- JMdict / EDICT style Japanese–English dictionaries.
-- Handles both layouts seen in StarDict conversions:
--   うちあける【打ち明ける】            打ち明ける [うちあける] /(v1,vt) (1) to be frank/…/(2) to confide/…/(P)/
--   (v1,vt) 1. to confide (a secret); …
return {
    id = "jmdict",
    name = "JMdict-style (Japanese–English)",
    description = "Kana reading in 【】 or [], POS codes like (v1,vt), senses (1) or 1.",
    match = { names = { "jmdict", "jmdic", "edict", "japanese-english", "japanese english", "和英" },
              lang_in = { "ja" }, lang_out = { "en" } },
    reading = {
        { pattern = "^(.-)【", script = "kana" },
        { pattern = "【(.-)】", script = "kana" },
        { pattern = "%[([^%]]+)%]", script = "kana" },
        { pattern = "^([^%s]+)$", script = "kana" },
    },
    senses = { "numbered", "slash", "lines" },
    markers = { "paren", "circled", "dot" },
    gloss_separator = "/",
    pos = {
        codes = {
            v1 = "Ichidan verb", ["v1-s"] = "Ichidan verb", vt = "transitive", vi = "intransitive",
            v5k = "Godan verb", v5s = "Godan verb", v5t = "Godan verb", v5n = "Godan verb", v5b = "Godan verb",
            v5m = "Godan verb", v5r = "Godan verb", v5g = "Godan verb", v5u = "Godan verb", ["v5k-s"] = "Godan verb",
            ["v5r-i"] = "Godan verb", ["v5u-s"] = "Godan verb", v5aru = "Godan verb", vk = "kuru verb",
            vs = "suru verb", ["vs-i"] = "suru verb", ["vs-s"] = "suru verb", vz = "zuru verb", ["vs-c"] = "su verb",
            n = "noun", ["n-adv"] = "adverbial noun", ["n-t"] = "temporal noun", ["n-suf"] = "noun suffix",
            ["n-pref"] = "noun prefix", ["n-pr"] = "proper noun",
            ["adj-i"] = "i-adjective", ["adj-ix"] = "i-adjective", ["adj-na"] = "na-adjective",
            ["adj-no"] = "no-adjective", ["adj-pn"] = "pre-noun adjectival", ["adj-t"] = "taru adjective",
            ["adj-f"] = "pre-noun", adv = "adverb", ["adv-to"] = "adverb (to)", ["aux-v"] = "auxiliary verb",
            aux = "auxiliary", ["aux-adj"] = "auxiliary adjective", exp = "expression", int = "interjection",
            pn = "pronoun", prt = "particle", conj = "conjunction", ctr = "counter", suf = "suffix",
            pref = "prefix", num = "numeric", cop = "copula", unc = "unclassified",
            P = false,
        },
    },
    tags = {
        arch = "archaic", obs = "obsolete", dated = "dated", rare = "rare", col = "colloquial",
        hon = "honorific", hum = "humble", pol = "polite", sl = "slang", vulg = "vulgar", uk = "usually kana",
        id = "idiom", ["on-mim"] = "onomatopoeia", abbr = "abbreviation", fam = "familiar", fem = "female",
        male = "male", derog = "derogatory", joc = "jocular", poet = "poetic", euph = "euphemistic",
        form = "formal", lit = "literary", chn = "children's", sens = "sensitive", X = "rude",
        P = false, ateji = false, ik = false, io = false, oK = false, ok = false, iK = false,
    },
    examples = { prefixes = { "例:", "例：", "e.g.", "Ex:", "▸" }, quoted = false, bilingual = true },
    notes = { prefixes = { "see also", "see:", "ant:", "note:" }, inline = { "%(See ([^%)]+)%)" } },
}
