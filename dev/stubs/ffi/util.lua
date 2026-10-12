local M = {}
function M.template(s, ...)
    local args = { ... }
    return (tostring(s):gsub("%%(%d)", function(i) return tostring(args[tonumber(i)]) end))
end
return M
