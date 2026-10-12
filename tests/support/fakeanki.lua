-- In-memory AnkiConnect for tests. Speaks the real wire format through the
-- client's transport hook.
--   local fake = FakeAnki.new{ unsupported = { createModel = "html" } }
--   local client = Anki.new{ transport = fake:transport(), json = json }
local json = require("json")

local F = {}
F.__index = F

function F.new(opts)
    opts = opts or {}
    local o = setmetatable({
        decks = { Default = 1 },
        models = { Basic = { fields = { "Front", "Back" } } },
        notes = {},
        next_id = 1700000000000,
        unsupported = opts.unsupported or {}, -- action -> "html" | "text" | "error" | "empty" | "500"
        down = opts.down or false,
        fail_after = opts.fail_after,           -- go down after N calls
        reject = opts.reject or {},             -- note first-field values addNotes refuses
        calls = {},
        media = {},
        -- mimic AnkiConnect Android (KamWithK, commit 93ee1a1): unknown actions
        -- get {"result":"AnkiConnect v.6"}, errors carry a Java stack trace
        android = opts.android or false,
    }, F)
    return o
end

function F:addExisting(model, fields, deck)
    self.next_id = self.next_id + 1
    self.notes[self.next_id] = { id = self.next_id, model = model, fields = fields, deck = deck or "Default", tags = {} }
    return self.next_id
end

-- Actions AnkiConnect Android routes (routing/AnkiAPIRouting.java:44-86).
F.ANDROID_ACTIONS = {
    version = true, deckNames = true, deckNamesAndIds = true, modelNames = true, modelNamesAndIds = true,
    modelFieldNames = true, findNotes = true, guiBrowse = true, canAddNotes = true, canAddNotesWithErrorDetail = true,
    addNote = true, updateNoteFields = true, storeMediaFile = true, notesInfo = true, multi = true,
}

local function firstField(self, model, fields)
    local m = self.models[model]
    if not m then return nil end
    return fields[m.fields[1]]
end

function F:isDuplicate(note)
    local first = firstField(self, note.modelName, note.fields)
    for _, n in pairs(self.notes) do
        if n.model == note.modelName and firstField(self, n.model, n.fields) == first then return true end
    end
    return false
end

-- Very small subset of Anki search: "note:X", "Field:value", "deck:X", -"note:KR2Anki*", (a OR b)
function F:search(query)
    local out = {}
    local model = query:match('^"note:([^"]+)"')
    local field, value = query:match('"note:[^"]+" "([^:"]+):([^"]*)"')
    if model and field then
        value = value:gsub("\\(.)", "%1")
        for id, n in pairs(self.notes) do
            if n.model == model and n.fields[field] == value then out[#out + 1] = id end
        end
        table.sort(out)
        return out
    end
    local deck = query:match('^"deck:([^"]+)"')
    if deck and query:find('-"note:KR2Anki%*"') then
        local alts = {}
        for f, v in query:gmatch('"([%a]+):([^"]*)"') do
            if f ~= "deck" and f ~= "note" then alts[#alts + 1] = { f, (v:gsub("\\(.)", "%1")) } end
        end
        for id, n in pairs(self.notes) do
            if n.deck == deck and not n.model:find("^KR2Anki") then
                for _, a in ipairs(alts) do
                    if n.fields[a[1]] == a[2] then out[#out + 1] = id break end
                end
            end
        end
        return out
    end
    return out
end

function F:handle(req)
    local a, p = req.action, req.params or {}
    if a == "version" then return 6 end
    if a == "deckNames" then
        local t = {}
        for name in pairs(self.decks) do t[#t + 1] = name end
        table.sort(t)
        return t
    end
    if a == "modelNames" then
        local t = {}
        for name in pairs(self.models) do t[#t + 1] = name end
        table.sort(t)
        return t
    end
    if a == "createDeck" then
        if not p.deck then error("missing deck") end
        self.decks[p.deck] = self.decks[p.deck] or (#self.calls + 100)
        return self.decks[p.deck]
    end
    if a == "createModel" then
        if not p.modelName then error("missing modelName") end
        self.models[p.modelName] = { fields = p.inOrderFields, css = p.css, templates = p.cardTemplates }
        return { name = p.modelName }
    end
    if a == "canAddNotes" then
        local out = json.array({})
        for i, n in ipairs(p.notes or {}) do
            if self.android then
                -- IntegratedAPI.canAddNotes: first-field checksum only
                out[i] = not self:isDuplicate(n)
            else
                out[i] = self.models[n.modelName] ~= nil and self.decks[n.deckName] ~= nil and not self:isDuplicate(n)
            end
        end
        return out
    end
    if a == "addNotes" or a == "addNote" then
        local list = a == "addNotes" and (p.notes or {}) or { p.note }
        if a == "addNote" and not p.note then error("missing note") end
        local out = json.array({})
        for i, n in ipairs(list) do
            local first = n.modelName and firstField(self, n.modelName, n.fields)
            local reason
            if not self.models[n.modelName] then reason = "model was not found: " .. tostring(n.modelName)
            elseif not self.decks[n.deckName] then reason = "deck was not found: " .. tostring(n.deckName)
            elseif self.reject[first] then reason = "cannot create note because it is empty"
            elseif not (n.options and n.options.allowDuplicate) and self:isDuplicate(n) then
                reason = "cannot create note because it is a duplicate"
            end
            if reason then
                if a == "addNote" then error(reason) end
                out[i] = json.null
            else
                self.next_id = self.next_id + 1
                self.notes[self.next_id] = { id = self.next_id, model = n.modelName, fields = n.fields,
                                             deck = n.deckName, tags = n.tags }
                out[i] = self.next_id
            end
        end
        if a == "addNote" then return out[1] end
        return out
    end
    if a == "findNotes" then return json.array(self:search(p.query or "")) end
    if a == "notesInfo" then
        local out = json.array({})
        for i, id in ipairs(p.notes or {}) do
            local n = self.notes[id]
            if n then
                local fields = {}
                for k, v in pairs(n.fields) do fields[k] = { value = v, order = 0 } end
                out[i] = { noteId = id, modelName = n.model, tags = n.tags, fields = fields }
            else
                out[i] = {}
            end
        end
        return out
    end
    if a == "updateNoteFields" then
        local note = p.note or {}
        local n = self.notes[note.id]
        if not n then error("note was not found: " .. tostring(note.id)) end
        for k, v in pairs(note.fields or {}) do n.fields[k] = v end
        return json.null
    end
    if a == "storeMediaFile" then
        if not p.filename then error("missing filename") end
        self.media[p.filename] = p.data
        return p.filename
    end
    return nil, "unsupported action"
end

function F:transport()
    return function(url, body, timeout)
        self.calls[#self.calls + 1] = body
        if self.fail_after and #self.calls > self.fail_after then self.down = true end
        if self.down then return nil, "connection refused" end
        local req = json.decode(body)
        if self.android and not F.ANDROID_ACTIONS[req.action] then
            return { status = 200, body = '{"result":"AnkiConnect v.6","error":null}' }
        end
        if self.android and req.action == "addNote" and req.params and req.params.note
                and not self.decks[req.params.note.deckName] then
            return { status = 200, body = json.encode({ result = json.null, error = "Couldn't get deck ID"
                .. "java.lang.Exception: Couldn't get deck ID\n\tat com.kamwithk.ankiconnectandroid.ankidroid_api.DeckAPI.getDeckID(DeckAPI.java:50)" }) }
        end
        local mode = self.unsupported[req.action]
        if mode == "html" then return { status = 404, body = "<html><body>Not Found</body></html>" } end
        if mode == "text" then return { status = 200, body = "OK" } end
        if mode == "empty" then return { status = 200, body = "" } end
        if mode == "500" then return { status = 500, body = '{"message":"java.lang.NullPointerException"}' } end
        if mode == "error" then return { status = 200, body = json.encode({ result = json.null, error = "unsupported action" }) } end
        local ok, res, err = pcall(self.handle, self, req)
        if not ok then
            return { status = 200, body = json.encode({ result = json.null, error = tostring(res):gsub("^.-:%d+: ", "") }) }
        end
        if err then return { status = 200, body = json.encode({ result = json.null, error = err }) } end
        return { status = 200, body = json.encode({ result = res == nil and json.null or res, error = json.null }) }
    end
end

function F:actionsCalled()
    local out = {}
    for _, body in ipairs(self.calls) do out[#out + 1] = json.decode(body).action end
    return out
end

return F
