-- English–Chinese dictionaries (朗道英汉, 牛津高阶英汉双解, 简明英汉 …):
--   *[rʌn]
--   vi. 跑, 奔跑, 逃跑
--   vt. 经营, 管理
--   相关词组:
--     run about
return {
    id = "english_chinese",
    name = "English–Chinese",
    description = "IPA in [] or *[], one POS line per sense group, 相关词组 as notes.",
    match = { names = { "langdao", "朗道", "英汉", "牛津", "简明", "21世纪", "english-chinese", "en-zh", "oxford ec" },
              lang_in = { "en" }, lang_out = { "zh" } },
    reading = {
        { pattern = "%*%[([^%]]+)%]", script = "ipa" },
        { pattern = "%[([^%]]+)%]", script = "ipa" },
        { pattern = "/([^/]+)/", script = "ipa" },
    },
    senses = { "numbered", "lines" },
    markers = { "dot", "circled", "paren", "rparen" },
    examples = { prefixes = { "例:", "例：", "例句", "e.g." }, bilingual = true },
    notes = {
        prefixes = { "同义词", "反义词", "参考", "【参考】" },
        headers = { "相关词组", "词组", "派生词", "习惯用语", "参考词汇", "词形变化", "常用词组" },
    },
}
