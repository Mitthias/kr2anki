local util = {}
function util.trim(s) return (s:gsub("^%s*(.-)%s*$", "%1")) end
function util.cleanupSelectedText(t) return util.trim((t:gsub("%s+", " "))) end
function util.partialMD5(f) return "md5:" .. f end
function util.makePath(p) os.execute("mkdir -p '" .. p .. "'"); return true end
return util
