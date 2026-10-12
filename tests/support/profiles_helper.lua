local Profiles = require("kr2anki/profiles")
local H = {}
function H.all()
    local list, errors = Profiles.loadAll({ "kr2anki.koplugin/profiles" })
    assert(#errors == 0, table.concat(errors, "\n"))
    return list
end
function H.get(id) return Profiles.byId(H.all(), id) end
return H
