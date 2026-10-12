-- Korean–English dictionaries (kengdic and similar):
--   먹다 [meokda]
--   1. eat, have, take
--   2. (액체) drink
return {
    id = "korean_english",
    name = "Korean–English",
    description = "Optional romanization in [], numbered or one sense per line.",
    match = { names = { "korean", "kengdic", "한영", "krdict", "ko-en", "korean-english" },
              lang_in = { "ko" }, lang_out = { "en" } },
    reading = {
        { pattern = "%[([^%]]+)%]", script = "latin" },
        { pattern = "%[([^%]]+)%]", script = "hangul" },
    },
    senses = { "numbered", "lines" },
    markers = { "dot", "circled", "paren", "rparen" },
    pos = { words = { "동사", "명사", "형용사", "부사", "대명사", "조사", "감탄사", "관형사", "수사", "보조 동사", "의존 명사" } },
    examples = { prefixes = { "예:", "예：", "예문", "e.g.", "▸" }, bilingual = true },
    notes = { prefixes = { "참고", "유의어", "반의어", "see also", "syn:" } },
}
