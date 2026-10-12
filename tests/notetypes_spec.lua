local N = require("kr2anki/notetypes")

describe("note fields", function()
    it("builds Word fields with ruby, bold target and cloze", function()
        local f, model = N.buildFields(N.sampleItem("word"))
        assert.equal("KR2Anki Word", model)
        assert.equal("打ち明ける", f.Word)
        assert.equal("打ち明けない", f.SurfaceForm)
        assert.equal("打[う]ち 明[あ]ける", f.Reading)
        assert.equal("だからここでもただ先生と書くだけで本名は<b>打ち明けない</b>。", f.Sentence)
        assert.equal('だからここでもただ先生と書くだけで本名は<span class="cloze">[…]</span>。', f.SentenceCloze)
        assert.equal("『こころ』 · 夏目漱石 · p. 3 · JMdict", f.Source)
        assert.equal("ja", f.Language)
        assert.equal("kr2anki-sample-word", f.UID)
        assert.equal("1", f.CardRecognition)
        assert.equal("1", f.CardCloze)
        assert.equal("1", f.CardCharReading)
        assert.equal("", f.Sound)
        assert.equal("1. to confide (a secret); to reveal; to disclose<br>2. to be frank<br>3. to empty out (a container) · archaic",
            f.FullDefinition)
        for _, name in ipairs(N.WORD_FIELDS) do assert.is_not_nil(f[name], name) end
    end)

    it("follows card settings and only sets Character → reading for kanji words", function()
        local item = N.sampleItem("word")
        local f = N.buildFields(item, { cards = { recognition = true, cloze = false, char_reading = false } })
        assert.equal("", f.CardCloze)
        assert.equal("", f.CardCharReading)
        item.lemma, item.reading = "なる", "なる"
        f = N.buildFields(item)
        assert.equal("", f.CardCharReading)
        item.language, item.lemma, item.reading = "en", "run", "/rʌn/"
        f = N.buildFields(item)
        assert.equal("", f.CardCharReading)
        assert.equal("/rʌn/", f.Reading)
    end)

    it("has no cloze when the sentence is missing", function()
        local item = N.sampleItem("word")
        item.sentence = { text = "打ち明けない", hl_start = 1, hl_end = 18, missing = true }
        local f = N.buildFields(item)
        assert.equal("", f.Sentence)
        assert.equal("", f.SentenceCloze)
        assert.equal("", f.CardCloze)
        assert.equal("1", f.CardRecognition, "recognition falls back to the word")
    end)

    it("formats readings per language", function()
        assert.equal("打[dǎ] 算[suàn]", N.readingField({ language = "zh", lemma = "打算", reading = "da3 suan4" }))
        assert.equal("/ræn/", N.readingField({ language = "en", lemma = "ran", reading = "[ræn]" }))
        assert.equal("", N.readingField({ language = "ko", lemma = "먹다", reading = "meokda" }))
        assert.equal("meokda", N.readingField({ language = "ko", lemma = "먹다", reading = "" }, { ko_romanize = true }))
        assert.equal("うちあける", N.readingField({ language = "ja", lemma = "打ち明ける", reading = "うちあける" }, { ja_furigana = false }))
        assert.equal("今日[きょう]", N.readingField({ language = "ja", lemma = "今日", reading = "きょう" }))
    end)

    it("escapes HTML in every text field", function()
        local item = N.sampleItem("word")
        item.definition = "a <b> & c"
        item.personal_note = 'x "y"\nz'
        item.sentence = { text = "1 < 2 & run", hl_start = 9, hl_end = 11 }
        local f = N.buildFields(item)
        assert.equal("a &lt;b&gt; &amp; c", f.Definition)
        assert.equal("x &quot;y&quot;<br>z", f.PersonalNote)
        assert.equal("1 &lt; 2 &amp; <b>run</b>", f.Sentence)
    end)

    it("builds Expression fields", function()
        local f, model = N.buildFields(N.sampleItem("expression"))
        assert.equal("KR2Anki Expression", model)
        assert.equal("〜なくてはならない", f.Pattern)
        assert.equal("must; have to; cannot avoid", f.Meaning)
        assert.truthy(f.Sentence:find("<b>なくてはならない</b>", 1, true))
        assert.equal("1", f.CardRecognition)
        assert.equal("", f.CardCloze, "expression cloze is off by default")
        assert.equal("『こころ』 · 夏目漱石 · p. 38", f.Source)
        for _, name in ipairs(N.EXPR_FIELDS) do assert.is_not_nil(f[name], name) end
        local empty = N.sampleItem("expression")
        empty.meaning = nil
        assert.equal("", N.buildFields(empty).Meaning)
    end)
end)

describe("tags", function()
    it("adds language, book, author, dictionary, type and source tags", function()
        local item = N.sampleItem("word")
        local tags = N.tags(item, { { title = "こころ", authors = "夏目漱石" }, { title = "The Great Gatsby", authors = "F. Scott Fitzgerald" } })
        assert.same({ "lang::Japanese", "book::こころ", "author::夏目漱石", "book::The_Great_Gatsby",
                      "author::F._Scott_Fitzgerald", "dict::JMdict", "type::word", "src::kr2anki" }, tags)
        local e = N.tags(N.sampleItem("expression"), {})
        assert.equal("type::expression", e[#e - 1])
    end)
end)

describe("templates", function()
    local function balanced(t)
        local stack = {}
        for kind, name in t:gmatch("{{([#^/])([^}]+)}}") do
            if kind == "/" then
                if stack[#stack] ~= name then return false, name end
                stack[#stack] = nil
            else
                stack[#stack + 1] = name
            end
        end
        return #stack == 0
    end

    it("wraps every front in its flag field", function()
        for kind, flags in pairs({ word = N.WORD_TEMPLATE_FLAGS, expression = N.EXPR_TEMPLATE_FLAGS }) do
            local m = N.model(kind)
            for i, t in ipairs(m.templates) do
                assert.truthy(t.front:find("^{{#" .. flags[i] .. "}}"), t.name)
                assert.truthy(t.front:find("{{/" .. flags[i] .. "}}$"), t.name)
                assert.is_true((balanced(t.front)), t.name .. " front")
                assert.is_true((balanced(t.back)), t.name .. " back")
            end
        end
    end)

    it("only references fields that exist", function()
        for _, kind in ipairs({ "word", "expression" }) do
            local m = N.model(kind)
            local have = {}
            for _, f in ipairs(m.fields) do have[f] = true end
            for _, t in ipairs(m.templates) do
                for ref in (t.front .. t.back):gmatch("{{[#^/]?([^}]+)}}") do
                    local name = ref:match(":(.+)$") or ref
                    assert.is_true(have[name] == true, kind .. "/" .. t.name .. " uses " .. name)
                end
            end
        end
    end)

    it("hides every optional section when its field is empty", function()
        local back = N.WORD_TEMPLATES[1].back
        for _, f in ipairs({ "Sound", "POS", "Definition", "UsageNotes", "DictExamples", "PersonalNote", "FullDefinition", "Source" }) do
            assert.truthy(back:find("{{#" .. f .. "}}", 1, true), f)
        end
    end)

    it("supports dark mode and uses no italics", function()
        assert.truthy(N.CSS:find(".night_mode", 1, true))
        assert.is_nil(N.CSS:find("italic"))
    end)

    it("provides createModel parameters", function()
        local p = N.createModelParams("word")
        assert.equal("KR2Anki Word", p.modelName)
        assert.equal(22, #p.inOrderFields)
        assert.equal(3, #p.cardTemplates)
        assert.equal("Recognition", p.cardTemplates[1].Name)
        assert.is_false(p.isCloze)
    end)
end)

describe("merging sentences", function()
    it("appends new sentences once", function()
        assert.equal("a<br><br>b", N.mergeSentence("a", "b"))
        assert.equal("a<br><br>b", N.mergeSentence("a<br><br>b", "b"))
        assert.equal("b", N.mergeSentence("", "b"))
    end)
end)
