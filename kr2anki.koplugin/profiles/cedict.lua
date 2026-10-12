-- CC-CEDICT style Chinese–English dictionaries:
--   打算 [da3 suan4]
--   /to plan/to intend/to calculate/plan/intention/calculation/CL:個|个[ge4]/
return {
    id = "cedict",
    name = "CC-CEDICT-style (Chinese–English)",
    description = "Pinyin in [] (numbers or tone marks), glosses separated by /.",
    match = { names = { "cedict", "cc-cedict", "handedict", "chinese-english", "chinese english", "汉英", "mdbg" },
              lang_in = { "zh" }, lang_out = { "en" } },
    reading = {
        { pattern = "%[([^%]]+)%]", script = "pinyin" },
        { pattern = "^(.+)$", script = "pinyin" },
    },
    senses = { "numbered", "slash", "lines" },
    markers = { "paren", "circled", "dot" },
    pinyin_in_text = true,
    examples = { prefixes = { "例:", "例：", "e.g." }, bilingual = true },
    notes = {
        prefixes = { "see also", "also written", "also pr." },
        sense_prefixes = { "CL:", "see also", "also written", "also pr.", "old variant of", "Taiwan pr." },
    },
}
