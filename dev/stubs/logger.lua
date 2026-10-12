local L = {}
_G.LOGGED = {}
for _, lvl in ipairs({ "err", "warn", "info", "dbg" }) do
    L[lvl] = function(...)
        local parts = {}
        for i = 1, select("#", ...) do parts[#parts + 1] = tostring(select(i, ...)) end
        table.insert(_G.LOGGED, lvl .. ": " .. table.concat(parts, " "))
        if lvl == "err" and os.getenv("VERBOSE") then print("LOG " .. lvl, ...) end
    end
end
return L
