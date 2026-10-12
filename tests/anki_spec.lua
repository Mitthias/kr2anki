local Anki = require("kr2anki/anki")
local json = require("json")
local FakeAnki = require("fakeanki")

local function clientWith(reply)
    return Anki.new{ json = json, transport = function() return reply end }
end

describe("AnkiConnect request building", function()
    it("uses API version 6 and omits empty params", function()
        assert.same({ action = "deckNames", version = 6 }, Anki.buildRequest("deckNames"))
        local r = Anki.buildRequest("createDeck", { deck = "Reading::Japanese" })
        assert.equal(6, r.version)
        assert.equal("Reading::Japanese", r.params.deck)
    end)

    it("encodes empty note lists as JSON arrays", function()
        local sent
        local c = Anki.new{ json = json, transport = function(url, body)
            sent = body
            return { status = 200, body = '{"result":[],"error":null}' }
        end }
        c:call("addNotes", { notes = c:array({}) })
        assert.equal('{"action":"addNotes","params":{"notes":[]},"version":6}', sent)
    end)

    it("posts to 127.0.0.1:8765 with a 5 second timeout", function()
        local got = {}
        local c = Anki.new{ json = json, transport = function(url, body, timeout)
            got.url, got.timeout = url, timeout
            return { status = 200, body = '{"result":6,"error":null}' }
        end }
        local v, err, kind = c:call("version")
        assert.equal(6, v)
        assert.is_nil(err)
        assert.equal("ok", kind)
        assert.equal("http://127.0.0.1:8765", got.url)
        assert.equal(5, got.timeout)
    end)

    it("builds notes and quotes search terms", function()
        local n = Anki.note("Reading::Japanese", "KR2Anki Word", { Word = "打ち明ける" }, { "src::kr2anki" })
        assert.equal("Reading::Japanese", n.deckName)
        assert.is_false(n.options.allowDuplicate)
        assert.equal('"Word:打ち明ける"', Anki.quote("Word", "打ち明ける"))
        assert.equal('"Word:say \\"hi\\" 100\\*"', Anki.quote("Word", 'say "hi" 100*'))
        assert.equal('"Word:a\\_b"', Anki.quote("Word", "a_b"))
    end)
end)

describe("AnkiConnect reply handling", function()
    it("returns result for a good reply", function()
        local r = clientWith({ status = 200, body = '{"result":["Default"],"error":null}' })
        local res, _, kind = r:call("deckNames")
        assert.same({ "Default" }, res)
        assert.equal("ok", kind)
    end)

    it("reports errors from Anki", function()
        local _, err, kind = clientWith({ status = 200, body = '{"result":null,"error":"deck was not found"}' }):call("addNote", {})
        assert.equal("error", kind)
        assert.equal("deck was not found", err)
    end)

    it("treats an 'unsupported action' error as unsupported", function()
        local _, _, kind = clientWith({ status = 200, body = '{"result":null,"error":"unsupported action"}' }):call("x")
        assert.equal("unsupported", kind)
    end)

    it("treats malformed replies as unsupported, never crashing", function()
        local cases = {
            { status = 404, body = "<html><body>Not Found</body></html>" },
            { status = 200, body = "OK" },
            { status = 200, body = "" },
            { status = 500, body = '{"message":"NullPointerException"}' },
            { status = 200, body = "[1,2,3]" },
            { status = 200, body = '{"result":5}' },
            { status = 200, body = '{"error":null}' },
            { status = 200, body = '{"result": [1, 2' },
            { status = 200, body = nil },
        }
        for i, reply in ipairs(cases) do
            local res, err, kind = clientWith(reply):call("canAddNotes", {})
            assert.equal("unsupported", kind, "case " .. i)
            assert.is_nil(res)
            assert.truthy(err)
        end
    end)

    it("reports unreachable when the transport fails or throws", function()
        local _, err, kind = Anki.new{ json = json, transport = function() return nil, "connection refused" end }:call("version")
        assert.equal("unreachable", kind)
        assert.equal("connection refused", err)
        _, err, kind = Anki.new{ json = json, transport = function() error("socket exploded") end }:call("version")
        assert.equal("unreachable", kind)
        assert.truthy(err:find("socket exploded"))
    end)
end)

describe("capability check", function()
    it("finds every command on a desktop-like server", function()
        local fake = FakeAnki.new()
        local caps = Anki.new{ json = json, transport = fake:transport() }:probe()
        assert.is_true(caps.reachable)
        assert.equal(6, caps.version)
        for _, a in ipairs({ "version", "deckNames", "modelNames", "createDeck", "createModel", "canAddNotes",
                             "addNotes", "addNote", "findNotes", "notesInfo", "updateNoteFields", "storeMediaFile" }) do
            assert.is_true(caps.actions[a], a)
        end
        local plan = Anki.plan(caps)
        assert.is_true(plan.create_models)
        assert.is_true(plan.merge)
        -- the probe must not change the collection
        assert.equal(0, (function() local n = 0 for _ in pairs(fake.notes) do n = n + 1 end return n end)())
        assert.same({ "Basic" }, (function() local t = {} for k in pairs(fake.models) do t[#t + 1] = k end return t end)())
    end)

    it("marks odd replies as unsupported (Android-like server)", function()
        local fake = FakeAnki.new{ unsupported = { createModel = "html", canAddNotes = "text", notesInfo = "500",
                                                   storeMediaFile = "empty", updateNoteFields = "error" } }
        local caps = Anki.new{ json = json, transport = fake:transport() }:probe()
        assert.is_true(caps.reachable)
        assert.is_false(caps.actions.createModel)
        assert.is_false(caps.actions.canAddNotes)
        assert.is_false(caps.actions.notesInfo)
        assert.is_false(caps.actions.storeMediaFile)
        assert.is_false(caps.actions.updateNoteFields)
        assert.is_true(caps.actions.addNotes)
        local plan = Anki.plan(caps)
        assert.is_false(plan.create_models)
        assert.is_false(plan.merge)
        assert.is_true(plan.can_export)
    end)

    it("sees through AnkiConnect Android's placeholder replies", function()
        local fake = FakeAnki.new{ android = true }
        local caps = Anki.new{ json = json, transport = fake:transport() }:probe()
        assert.is_true(caps.reachable)
        assert.equal(6, caps.version)
        for _, a in ipairs({ "createDeck", "createModel", "addNotes" }) do
            assert.is_false(caps.actions[a], a .. " answered with the version string")
        end
        for _, a in ipairs({ "deckNames", "modelNames", "canAddNotes", "addNote", "findNotes", "notesInfo",
                             "updateNoteFields", "storeMediaFile" }) do
            assert.is_true(caps.actions[a], a)
        end
        local plan = Anki.plan(caps)
        assert.is_false(plan.create_decks)
        assert.is_false(plan.batch_add)
        assert.is_true(plan.single_add)
    end)

    it("treats the version placeholder as unsupported for any action but version", function()
        local c = clientWith({ status = 200, body = '{"result":"AnkiConnect v.6","error":null}' })
        local _, _, kind = c:call("createDeck", { deck = "x" })
        assert.equal("unsupported", kind)
        local v, _, k2 = c:call("version")
        assert.equal("AnkiConnect v.6", v)
        assert.equal("ok", k2)
    end)

    it("strips Java stack traces from error messages", function()
        assert.equal("Couldn't get deck ID", Anki.cleanError(
            "Couldn't get deck IDjava.lang.Exception: Couldn't get deck ID\n\tat com.kamwithk.X(DeckAPI.java:50)"))
        assert.equal("deck was not found", Anki.cleanError("deck was not found"))
        local _, err = clientWith({ status = 200,
            body = '{"result":null,"error":"Couldn\'t get deck IDjava.lang.Exception: Couldn\'t get deck ID\\n\\tat x"}' })
            :call("addNote", {})
        assert.equal("Couldn't get deck ID", err)
    end)

    it("stops early when AnkiConnect is not running", function()
        local fake = FakeAnki.new{ down = true }
        local caps = Anki.new{ json = json, transport = fake:transport() }:probe()
        assert.is_false(caps.reachable)
        assert.equal(1, #fake.calls)
        assert.equal("connection refused", caps.error)
    end)
end)
