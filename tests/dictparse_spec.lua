local P = require("kr2anki/dictparse")
local H = require("profiles_helper")

local function texts(parsed)
    local out = {}
    for i, s in ipairs(parsed.senses) do out[i] = s.text end
    return out
end

describe("JMdict profile", function()
    local prof = H.get("jmdict")

    it("parses the Yomichan-style layout", function()
        local raw = "うちあける【打ち明ける】\n(v1,vt) 1. to confide (a secret); to reveal; to disclose\n"
            .. "2. to be frank; to speak one's mind; to open one's heart\n3. (arch) to empty out (a container)"
        local r = P.parse(raw, prof, { headword = "打ち明ける", lang = "ja" })
        assert.equal("うちあける", r.reading)
        assert.equal("Ichidan verb, transitive", r.pos)
        assert.same({
            "to confide (a secret); to reveal; to disclose",
            "to be frank; to speak one's mind; to open one's heart",
            "to empty out (a container) · archaic",
        }, texts(r))
    end)

    it("parses the EDICT one-line layout and drops (P)", function()
        local raw = "打ち明ける [うちあける] /(v1,vt) (1) to be frank/to speak one's mind/to open one's heart/"
            .. "(2) to confide (a secret)/to reveal/to disclose/(P)/"
        local r = P.parse(raw, prof, { headword = "打ち明ける" })
        assert.equal("うちあける", r.reading)
        assert.equal("Ichidan verb, transitive", r.pos)
        assert.same({
            "to be frank; to speak one's mind; to open one's heart",
            "to confide (a secret); to reveal; to disclose",
        }, texts(r))
    end)

    it("handles eight senses for 成る", function()
        local raw = "なる【成る】\n(v5r,vi) 1. to become; to get; to grow; to turn into\n2. to reach; to attain (an age, a time)\n"
            .. "3. to result in; to prove to be\n4. to consist of; to be composed of\n5. to be completed; to be finished\n"
            .. "6. to be promoted (shogi piece)\n7. to change into\n8. (hon) to do"
        local r = P.parse(raw, prof, { headword = "成る" })
        assert.equal("なる", r.reading)
        assert.equal("Godan verb, intransitive", r.pos)
        assert.equal(8, #r.senses)
        assert.equal("to do · honorific", r.senses[8].text)
    end)

    it("reads HTML entries", function()
        local raw = '<div class="hw">うちあける【打ち明ける】</div><div><i>(v1,vt)</i><ol><li>to confide (a secret); to reveal</li>'
            .. "<li>to be frank</li></ol></div>"
        local r = P.parse(raw, prof, { headword = "打ち明ける" })
        assert.equal("うちあける", r.reading)
        assert.same({ "to confide (a secret); to reveal", "to be frank" }, texts(r))
    end)
end)

describe("CC-CEDICT profile", function()
    local prof = H.get("cedict")

    it("splits glosses, converts pinyin and moves classifiers to notes", function()
        local raw = "打算 [da3 suan4]\n/to plan/to intend/to calculate/plan/intention/calculation/CL:個|个[ge4]/"
        local r = P.parse(raw, prof, { headword = "打算" })
        assert.equal("dǎ suàn", r.reading)
        assert.same({ "to plan", "to intend", "to calculate", "plan", "intention", "calculation" }, texts(r))
        assert.same({ "CL:個|个[gè]" }, r.notes)
    end)

    it("accepts tone-marked pinyin on its own line and traditional/simplified headers", function()
        local raw = "打算 打算\ndǎ suàn\n/to plan/to intend/"
        local r = P.parse(raw, prof, { headword = "打算" })
        assert.equal("dǎ suàn", r.reading)
        assert.same({ "to plan", "to intend" }, texts(r))
    end)
end)

describe("Korean–English profile", function()
    local prof = H.get("korean_english")
    it("reads romanization and numbered senses", function()
        local raw = "먹다 [meokda]\n동사\n1. eat, have, take\n2. (액체) drink\n3. earn (money)"
        local r = P.parse(raw, prof, { headword = "먹다" })
        assert.equal("meokda", r.reading)
        assert.same({ "eat, have, take", "(액체) drink", "earn (money)" }, texts(r))
        assert.equal("동사", r.pos)
    end)
    it("falls back to one sense per line", function()
        local r = P.parse("먹다\nto eat\nto drink", prof, { headword = "먹다" })
        assert.same({ "to eat", "to drink" }, texts(r))
    end)
end)

describe("English–English profile", function()
    local prof = H.get("english_english")

    it("parses a learner's dictionary layout", function()
        local raw = "run\n/rʌn/\nverb\n1. to move swiftly on foot\n2. to manage a business\n"
            .. "Example: She runs a small hotel.\nSynonyms: sprint, dash"
        local r = P.parse(raw, prof, { headword = "run" })
        assert.equal("/rʌn/", r.reading)
        assert.equal("verb", r.pos)
        assert.same({ "to move swiftly on foot", "to manage a business" }, texts(r))
        assert.same({ "She runs a small hotel." }, r.examples)
        assert.same({ "Synonyms: sprint, dash" }, r.notes)
    end)

    it("parses WordNet with POS letters, quoted examples and [syn:]", function()
        local raw = 'n 1: a score in baseball made by a runner touching all four bases; "the Yankees scored 3 runs" [syn: {tally}, {run}]\n'
            .. '2: the continuous period of time during which something lasts\n'
            .. 'v 1: move fast by using one\'s feet; "Don\'t run--you\'ll be out of breath"'
        local r = P.parse(raw, prof, { headword = "run" })
        assert.equal(3, #r.senses)
        assert.equal("a score in baseball made by a runner touching all four bases", r.senses[1].text)
        assert.equal("noun", r.senses[1].pos)
        assert.equal("verb", r.senses[3].pos)
        assert.same({ "the Yankees scored 3 runs", "Don't run--you'll be out of breath" }, r.examples)
        assert.same({ "tally, run" }, r.notes)
    end)

    it("drops a header line with the headword in another case", function()
        local r = P.parse("Ran\n[ræn]\npast tense of run", prof, { headword = "ran" })
        assert.equal("/ræn/", r.reading)
        assert.same({ "past tense of run" }, texts(r))
    end)
end)

describe("English–Chinese profile", function()
    local prof = H.get("english_chinese")
    it("parses the Langdao layout", function()
        local raw = "*[rʌn]\nvi. 跑, 奔跑, 逃跑\nvt. 经营, 管理\nn. 跑步, 运行\n相关词组:\nrun about\nrun across"
        local r = P.parse(raw, prof, { headword = "run" })
        assert.equal("/rʌn/", r.reading)
        assert.same({ "跑, 奔跑, 逃跑", "经营, 管理", "跑步, 运行" }, texts(r))
        assert.equal("intransitive verb", r.senses[1].pos)
        assert.equal("transitive verb", r.senses[2].pos)
        assert.same({ "run about", "run across" }, r.notes)
    end)
    it("collects bilingual example lines", function()
        local raw = "*[ɪnˈɛgzɔːstəbl]\nadj. 用不完的, 无穷无尽的\nThe supply is inexhaustible. 供应是无穷无尽的。"
        local r = P.parse(raw, prof, { headword = "inexhaustible" })
        assert.same({ "用不完的, 无穷无尽的" }, texts(r))
        assert.equal(1, #r.examples)
        assert.equal("adjective", r.pos)
    end)
end)

describe("generic fallback", function()
    local prof = H.get("generic")
    it("uses numbered senses", function()
        local r = P.parse("1. first meaning\n2. second meaning", prof, { headword = "x" })
        assert.same({ "first meaning", "second meaning" }, texts(r))
    end)
    it("uses one sense per line otherwise", function()
        local r = P.parse("maison\nhouse; home\nfamily", prof, { headword = "maison" })
        assert.same({ "house; home", "family" }, texts(r))
    end)
    it("keeps a single-line definition as one sense", function()
        local r = P.parse("a single definition", prof, { headword = "x" })
        assert.same({ "a single definition" }, texts(r))
    end)
    it("finds audio in HTML", function()
        local r = P.parse('<p>word</p><a href="sound://run_us.mp3">▶</a><p>to move</p>', prof, { headword = "word" })
        assert.equal("run_us.mp3", r.audio)
    end)
    it("cleans the full entry", function()
        assert.equal("a & b\nc", P.clean("<div>a &amp; b</div><br><p>c</p>"))
    end)
end)

describe("profile matching", function()
    local Profiles = require("kr2anki/profiles")
    local list = H.all()
    it("matches by dictionary name", function()
        assert.equal("jmdict", Profiles.match(list, { name = "JMdict (English)" }).id)
        assert.equal("cedict", Profiles.match(list, { name = "CC-CEDICT" }).id)
        assert.equal("english_chinese", Profiles.match(list, { name = "朗道英汉字典5.0" }).id)
        assert.equal("english_english", Profiles.match(list, { name = "WordNet 3.0" }).id)
    end)
    it("matches by language pair when the name is unknown", function()
        assert.equal("korean_english", Profiles.match(list, { name = "My dict", lang_in = "ko", lang_out = "en" }).id)
        assert.equal("english_chinese", Profiles.match(list, { name = "Foo", lang_in = "en", lang_out = "zh" }).id)
    end)
    it("falls back to generic, and honours a user choice", function()
        assert.equal("generic", Profiles.match(list, { name = "Unknown" }).id)
        assert.equal("cedict", Profiles.match(list, { name = "Unknown" }, "cedict").id)
    end)
    it("loads profiles only as data", function()
        local path = os.tmpname() .. ".lua"
        local f = io.open(path, "w")
        f:write("os.execute('echo hi') return { id = 'x' }")
        f:close()
        local p, err = Profiles.loadFile(path)
        assert.is_nil(p)
        assert.truthy(err)
        os.remove(path)
    end)
end)
