-- Fresh database in a temp file for each test.
local Store = require("kr2anki/db")
local json = require("json")
local T = {}
function T.new(opts)
    local path = os.tmpname() .. ".sqlite3"
    os.remove(path)
    local clock = { t = 1760000000 }
    local store = Store.new(path, { json = json, now = function() clock.t = clock.t + 1; return clock.t end })
    store._test_path = path
    store._clock = clock
    return store
end
function T.capture(over)
    local c = {
        type = "word", language = "ja", surface = "打ち明けない", lemma = "打ち明ける",
        lookups = {
            { dictionary = "JMdict", headword = "打ち明ける", raw_definition = "…", dict_lang = "ja",
              parsed = { reading = "うちあける", pos = "Ichidan verb, transitive", full = "1. to confide\n2. to be frank",
                         senses = { { text = "to confide (a secret); to reveal" }, { text = "to be frank" } },
                         examples = { "友達に悩みを打ち明けた。" }, notes = { "Usually with 秘密" } } },
            { dictionary = "大辞林", headword = "打ち明ける", raw_definition = "…",
              parsed = { reading = "うちあける", senses = { { text = "隠さずにすべて話す。" } } } },
        },
        sentence = { text = "本名は打ち明けない。", hl_start = 10, hl_end = 27, selection = "打ち明けない",
                     context_before = "本名は", context_after = "。", page = 3 },
        book = { title = "こころ", authors = "夏目漱石", language = "ja", file_hash = "abc123" },
    }
    for k, v in pairs(over or {}) do c[k] = v end
    return c
end
return T
