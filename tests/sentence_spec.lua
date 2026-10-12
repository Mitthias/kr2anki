local S = require("kr2anki/sentence")
local U = require("kr2anki/u8")

local function hl(r) return r.text:sub(r.hl_start, r.hl_end) end

describe("sentence extraction: English", function()
    it("cuts at sentence ends around the selection", function()
        local r = S.extract{
            prev = "He walked in. I was within and without, simultaneously enchanted and repelled by the ",
            selection = "inexhaustible",
            next = " variety of life. Then he left.",
            lang = "en",
        }
        assert.equal("I was within and without, simultaneously enchanted and repelled by the inexhaustible variety of life.", r.text)
        assert.equal("inexhaustible", hl(r))
        assert.is_false(r.missing)
        assert.is_false(r.trimmed)
    end)

    it("does not split after abbreviations, initials or decimals", function()
        local r = S.extract{
            prev = "It rained. Mr. Smith met Dr. J. R. Watson at 3.5 p.m. near St. Paul's and ",
            selection = "confided",
            next = " a secret, e.g. the plan. Nobody knew.",
            lang = "en",
        }
        assert.equal("Mr. Smith met Dr. J. R. Watson at 3.5 p.m. near St. Paul's and confided a secret, e.g. the plan.", r.text)
        assert.equal("confided", hl(r))
    end)

    it("keeps closing quotes and handles ! and ?", function()
        local r = S.extract{
            prev = "“Where are you going?” she asked. “I am ",
            selection = "leaving",
            next = "!” he said. Silence.",
            lang = "en",
        }
        assert.equal("“I am leaving!”", r.text)
    end)

    it("treats a line break as a sentence end", function()
        local r = S.extract{ prev = "Chapter One\nThe old ", selection = "mill", next = " stood still\nNext line", lang = "en" }
        assert.equal("The old mill stood still", r.text)
    end)

    it("trims long sentences to about 40 words centred on the target", function()
        local words = {}
        for i = 1, 60 do words[i] = "w" .. i end
        local prev = table.concat(words, " ", 1, 30) .. " "
        local nxt = " " .. table.concat(words, " ", 31, 60) .. "."
        local r = S.extract{ prev = prev, selection = "TARGET", next = nxt, lang = "en" }
        assert.is_true(r.trimmed)
        assert.equal("TARGET", hl(r))
        local count = select(2, r.text:gsub("%S+", ""))
        assert.is_true(count <= 42, "word count " .. count)
        assert.truthy(r.text:find("^…"))
        assert.truthy(r.text:find("…$"))
        -- centred: roughly as many words on each side
        local before = select(2, r.text:sub(1, r.hl_start - 1):gsub("%S+", "")) - 1
        local after = select(2, r.text:sub(r.hl_end + 1):gsub("%S+", "")) - 1
        assert.is_true(math.abs(before - after) <= 2, before .. " vs " .. after)
    end)

    it("flags missing context and stores the selection alone", function()
        local r = S.extract{ prev = nil, selection = "  run  ", next = nil, lang = "en" }
        assert.is_true(r.missing)
        assert.equal("run", r.text)
        assert.equal("run", hl(r))
    end)
end)

describe("sentence extraction: Chinese", function()
    it("cuts at 。！？", function()
        local r = S.extract{ prev = "天气很好。我们", selection = "打算", next = "明天去公园！你去吗？", lang = "zh" }
        assert.equal("我们打算明天去公园！", r.text)
        assert.equal("打算", hl(r))
    end)

    it("trims to about 80 characters centred on the target", function()
        local prev = string.rep("甲", 70)
        local nxt = string.rep("乙", 70) .. "。"
        local r = S.extract{ prev = prev, selection = "打算", next = nxt, lang = "zh" }
        assert.is_true(r.trimmed)
        assert.equal("打算", hl(r))
        local inner = r.text:gsub("…", "")
        assert.equal(80, U.len(inner))
        assert.equal(39, U.len(r.text:sub(1, r.hl_start - 1):gsub("…", "")))
    end)
end)

describe("sentence extraction: Japanese", function()
    it("cuts at 。 and highlights the selection", function()
        local r = S.extract{
            prev = "私はその人を常に先生と呼んでいた。だからここでもただ先生と書くだけで本名は",
            selection = "打ち明けない",
            next = "。これは世間を憚かる遠慮というよりも、",
            lang = "ja",
        }
        assert.equal("だからここでもただ先生と書くだけで本名は打ち明けない。", r.text)
        assert.equal("打ち明けない", hl(r))
    end)

    it("keeps 「」 quotes intact", function()
        local r = S.extract{
            prev = "先生は「私は淋しい。",
            selection = "けれども",
            next = "あなたは淋しくない」と言った。そして笑った。",
            lang = "ja",
        }
        assert.equal("先生は「私は淋しい。けれどもあなたは淋しくない」と言った。", r.text)
    end)

    it("falls back to the sentence inside a quote that is too long", function()
        local long = string.rep("あ", 60)
        local r = S.extract{
            prev = "「私は今より一層淋しい未来の私を我慢する代りに、淋しい今の私を我慢したいのです。" .. long .. "。自由と独立と己れとに充ちた現代に生れた我々は、その犠牲としてみんなこの淋しみを味わ",
            selection = "わなくてはならない",
            next = "でしょう」\n次の段落。",
            lang = "ja",
        }
        assert.equal("自由と独立と己れとに充ちた現代に生れた我々は、その犠牲としてみんなこの淋しみを味わわなくてはならないでしょう」", r.text)
        assert.equal("わなくてはならない", hl(r))
    end)
end)

describe("sentence extraction: Korean", function()
    it("cuts at . ! ? and trims by words", function()
        local r = S.extract{ prev = "날씨가 좋았다. 우리는 밥을 ", selection = "먹었다", next = ". 그리고 잤다.", lang = "ko" }
        assert.equal("우리는 밥을 먹었다.", r.text)
        assert.equal("먹었다", hl(r))
    end)
end)

describe("shorten and more context", function()
    local ctx = {
        prev = "One. Two three four five six seven eight nine ten eleven twelve ",
        selection = "target",
        next = " thirteen fourteen fifteen sixteen seventeen eighteen. Three.",
        lang = "en",
    }
    it("shortens around the target", function()
        local r = S.shorten(ctx)
        assert.equal("target", hl(r))
        local n = select(2, r.text:gsub("%S+", ""))
        assert.is_true(n <= 22)
        local o = S.extract(ctx)
        assert.is_true(#r.text <= #o.text)
    end)
    it("adds a sentence on each side", function()
        local r = S.moreContext(ctx)
        assert.truthy(r.text:find("^One%."))
        assert.truthy(r.text:find("Three%.$"))
        assert.equal("target", hl(r))
    end)
end)

describe("mark", function()
    it("wraps the highlight", function()
        local r = S.extract{ prev = "I ", selection = "ran", next = " home.", lang = "en" }
        assert.equal("I <b>ran</b> home.", S.mark(r.text, r.hl_start, r.hl_end, "<b>", "</b>"))
    end)
end)
