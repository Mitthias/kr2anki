local G = setmetatable({}, { __call = function(_, s) return s end })
function G.ngettext(a, b, n) return n == 1 and a or b end
return G
