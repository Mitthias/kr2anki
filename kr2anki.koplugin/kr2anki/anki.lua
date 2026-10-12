--[[--
AnkiConnect client (API version 6) with a pluggable transport and JSON codec,
so request building and reply handling can be tested without a network.

    local Anki = require("kr2anki/anki")
    local client = Anki.new{ transport = Http.post, json = rapidjson }
    local result, err, kind = client:call("deckNames")
    -- kind: "ok" | "error" | "unsupported" | "unreachable"

AnkiConnect Android reimplements only part of the desktop add-on and may
answer an unknown action with something other than {result, error} JSON
(an HTML page, plain text, an empty body). Any such reply means
"unsupported", never a crash.
Pure Lua.
--]]

local A = {}
A.__index = A

A.URL = "http://127.0.0.1:8765"
A.API_VERSION = 6
A.TIMEOUT = 5

--[[--
@param opts table
  transport: function(url, body_string, timeout) -> { status = number, body = string } or nil, err
  json: { encode, decode, null, array } (rapidjson-compatible)
  url, timeout: optional overrides
--]]
function A.new(opts)
    local o = setmetatable({}, A)
    o.transport = assert(opts.transport, "transport required")
    o.json = assert(opts.json, "json codec required")
    o.url = opts.url or A.URL
    o.timeout = opts.timeout or A.TIMEOUT
    o.log = opts.log
    return o
end

-- Empty JSON array (a plain {} would encode as an object).
function A:array(t)
    if self.json.array then return self.json.array(t or {}) end
    return t or {}
end

function A:isNull(v)
    return v == nil or (self.json.null ~= nil and v == self.json.null)
end

-- The request table for an action (params omitted when nil).
function A.buildRequest(action, params)
    local req = { action = action, version = A.API_VERSION }
    if params ~= nil then req.params = params end
    return req
end

local UNSUPPORTED_ERRORS = { "unsupported action", "unknown action", "not supported", "not implemented",
                             "unsupported", "no such action", "invalid action" }

local function errorMeansUnsupported(msg)
    local m = tostring(msg):lower()
    for _, pat in ipairs(UNSUPPORTED_ERRORS) do
        if m:find(pat, 1, true) then return true end
    end
    return false
end

-- AnkiConnect Android answers any action it doesn't know with a normal
-- success reply carrying its version string (AnkiAPIRouting.default_version).
local function isVersionPlaceholder(result)
    return type(result) == "string" and result:find("^AnkiConnect v%.") ~= nil
end
A.isVersionPlaceholder = isVersionPlaceholder

-- AnkiConnect Android appends the Java stack trace to error messages:
-- "Couldn't get deck IDjava.lang.Exception: Couldn't get deck ID\n\tat …"
function A.cleanError(msg)
    msg = tostring(msg or "")
    local head = msg:match("^(.-)java%.[%w%.]*Exception") or msg:match("^(.-)android%.[%w%.]*Exception")
    if head and head:match("%S") then msg = head end
    msg = msg:match("^[^\r\n]*") or msg
    return (msg:gsub("%s+$", ""))
end

--[[--
Interpret an HTTP reply.
@param action optional; replies to anything but "version" that only carry
  AnkiConnect Android's version string mean the action is unsupported
@treturn table { kind = "ok"|"error"|"unsupported", result = any, error = string }
--]]
function A:parseReply(status, body, action)
    if type(body) ~= "string" or body == "" then
        return { kind = "unsupported", error = "empty reply (HTTP " .. tostring(status) .. ")" }
    end
    local ok, data = pcall(self.json.decode, body)
    if not ok or type(data) ~= "table" then
        local snippet = body:sub(1, 60):gsub("%s+", " ")
        return { kind = "unsupported", error = "reply is not JSON: " .. snippet }
    end
    -- must be exactly the {result, error} envelope
    local has_result, has_error = false, false
    for k in pairs(data) do
        if k == "result" then has_result = true
        elseif k == "error" then has_error = true end
    end
    if not (has_result and has_error) then
        return { kind = "unsupported", error = "reply has no {result, error}" }
    end
    if not self:isNull(data.error) then
        local msg = A.cleanError(data.error)
        if errorMeansUnsupported(msg) then
            return { kind = "unsupported", error = msg }
        end
        return { kind = "error", error = msg }
    end
    local result = data.result
    if self:isNull(result) then result = nil end
    if action ~= "version" and isVersionPlaceholder(result) then
        return { kind = "unsupported", error = "not implemented by this AnkiConnect (it answered with its version)" }
    end
    return { kind = "ok", result = result }
end

--[[--
Call an action.
@treturn any result (nil unless kind == "ok")
@treturn string|nil error message
@treturn string kind
--]]
function A:call(action, params)
    local req = A.buildRequest(action, params)
    local ok, body = pcall(self.json.encode, req)
    if not ok or not body then
        return nil, "cannot encode request: " .. tostring(body), "error"
    end
    local tok, reply, terr = pcall(self.transport, self.url, body, self.timeout)
    if not tok then
        return nil, tostring(reply), "unreachable"
    end
    if not reply then
        return nil, tostring(terr or "no connection"), "unreachable"
    end
    if self.log then self.log(action, reply.status, reply.body) end
    local r = self:parseReply(reply.status, reply.body, action)
    return r.result, r.error, r.kind
end

-- Capability check ---------------------------------------------------------------

-- Each probe is side-effect free: missing or empty params make a supported
-- action answer with a proper error or an empty result.
function A:probes()
    return {
        { action = "version" },
        { action = "deckNames" },
        { action = "modelNames" },
        { action = "createDeck", params = {} },
        { action = "createModel", params = {} },
        { action = "canAddNotes", params = { notes = self:array() } },
        { action = "addNotes", params = { notes = self:array() } },
        { action = "addNote", params = {} },
        { action = "findNotes", params = { query = "UID:kr2anki-capability-probe" } },
        { action = "notesInfo", params = { notes = self:array() } },
        { action = "updateNoteFields", params = { note = { id = 1, fields = { UID = "" } } } },
        { action = "storeMediaFile", params = {} },
    }
end

A.PROBE_VERSION = 2 -- bump to re-probe cached capabilities

-- Actions where a proper error reply still proves the action exists.
local ERROR_MEANS_SUPPORTED = {
    createDeck = true, createModel = true, addNote = true, updateNoteFields = true, storeMediaFile = true,
}

-- Result types a working action returns to the probe; anything else (e.g. a
-- placeholder string) means the server does not really implement it.
local EXPECTED = {
    version = "number", deckNames = "table", modelNames = "table", canAddNotes = "table",
    addNotes = "table", findNotes = "table", notesInfo = "table",
    createDeck = "number", createModel = "table", addNote = "number",
}

--[[--
Ask AnkiConnect which commands work.
@treturn table caps { reachable, version, actions = { name = true|false }, details = { {action, status, error} } }
--]]
function A:probe()
    local caps = { reachable = false, actions = {}, details = {}, checked_at = os.time(), probe_version = A.PROBE_VERSION }
    for i, p in ipairs(self:probes()) do
        local result, err, kind = self:call(p.action, p.params)
        if kind == "unreachable" then
            if i == 1 then
                caps.error = err
                return caps
            end
            caps.details[#caps.details + 1] = { action = p.action, status = "unreachable", error = err }
            caps.actions[p.action] = false
        else
            caps.reachable = true
            local works
            if kind == "ok" then
                local want = EXPECTED[p.action]
                -- AnkiConnect Android returns the version as a string
                local got = type(result)
                if want == "number" and got == "string" and tonumber(result) then got = "number" end
                works = want == nil or got == want
                if not works then
                    kind = "unsupported"
                    err = "unexpected reply: " .. tostring(result):sub(1, 40)
                end
            elseif kind == "error" then
                works = ERROR_MEANS_SUPPORTED[p.action] == true
            else
                works = false
            end
            if p.action == "version" and kind == "ok" then caps.version = result end
            caps.actions[p.action] = works
            caps.details[#caps.details + 1] = {
                action = p.action,
                status = works and "works" or (kind == "unsupported" and "unsupported" or "error"),
                error = err,
            }
        end
    end
    return caps
end

-- Which path export takes, from the capability results.
function A.plan(caps)
    local a = caps and caps.actions or {}
    return {
        can_export = a.addNotes == true or a.addNote == true,
        batch_add = a.addNotes == true,
        single_add = a.addNote == true,
        create_decks = a.createDeck == true,
        create_models = a.createModel == true,
        check_duplicates = a.canAddNotes == true,
        find = a.findNotes == true,
        merge = a.updateNoteFields == true and a.findNotes == true,
        read_notes = a.notesInfo == true,
        media = a.storeMediaFile == true,
        list_models = a.modelNames == true,
        list_decks = a.deckNames == true,
    }
end

-- Search-query quoting for findNotes: "Word:打ち明ける" with Anki escapes.
function A.quote(field, value)
    value = tostring(value or ""):gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("%*", "\\*"):gsub("_", "\\_")
    if field then return '"' .. field .. ":" .. value .. '"' end
    return '"' .. value .. '"'
end

-- Note payload for addNote(s)/canAddNotes.
function A.note(deck, model, fields, tags)
    return {
        deckName = deck,
        modelName = model,
        fields = fields,
        tags = tags,
        options = { allowDuplicate = false, duplicateScope = "collection" },
    }
end

return A
