local ffi = require("ffi")
-- Minimal: ljsqlite3 only needs ffi.loadlib from KOReader's ffi extensions.
if not ffi.loadlib then
  ffi.loadlib = function(name)
    for _, p in ipairs({ "/opt/homebrew/opt/sqlite/lib/libsqlite3.dylib", "/usr/lib/libsqlite3.dylib", "sqlite3" }) do
      local ok, lib = pcall(ffi.load, p)
      if ok then return lib end
    end
    error("no sqlite3")
  end
end
ffi.cdef[[void free(void *ptr);]]
return true
