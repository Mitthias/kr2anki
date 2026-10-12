--[[--
Zip writing. Uses KOReader's libarchive binding (ffi/archiver) when present;
otherwise a small pure-Lua writer that stores entries uncompressed, which
every unzip (and Anki) reads.

    Zip.write(path, { { name = "collection.anki2", data = bytes }, … })
--]]

local bit = require("bit")

local Zip = {}

local crc_table
local function crc32(s)
    if not crc_table then
        crc_table = {}
        for i = 0, 255 do
            local c = i
            for _ = 1, 8 do
                if bit.band(c, 1) == 1 then c = bit.bxor(bit.rshift(c, 1), 0xEDB88320)
                else c = bit.rshift(c, 1) end
            end
            crc_table[i] = c
        end
    end
    local crc = 0xFFFFFFFF
    for i = 1, #s do
        crc = bit.bxor(bit.rshift(crc, 8), crc_table[bit.band(bit.bxor(crc, s:byte(i)), 0xFF)])
    end
    crc = bit.bnot(crc)
    return crc % 0x100000000
end
Zip.crc32 = crc32

local function u16(n) return string.char(n % 256, math.floor(n / 256) % 256) end
local function u32(n)
    n = n % 0x100000000
    return string.char(n % 256, math.floor(n / 256) % 256, math.floor(n / 65536) % 256, math.floor(n / 16777216) % 256)
end

local function dosTime(t)
    local d = os.date("*t", t)
    local time = d.hour * 2048 + d.min * 32 + math.floor(d.sec / 2)
    local date = (math.max(d.year, 1980) - 1980) * 512 + d.month * 32 + d.day
    return time, date
end

-- Pure-Lua stored zip.
function Zip.writeStored(path, entries, mtime)
    local f, err = io.open(path, "wb")
    if not f then return nil, err end
    local time, date = dosTime(mtime or os.time())
    local central = {}
    local offset = 0
    for _, e in ipairs(entries) do
        local data = e.data
        local crc = crc32(data)
        local header = "PK\3\4" .. u16(20) .. u16(0x0800) .. u16(0) .. u16(time) .. u16(date) .. u32(crc)
            .. u32(#data) .. u32(#data) .. u16(#e.name) .. u16(0) .. e.name
        f:write(header, data)
        central[#central + 1] = "PK\1\2" .. u16(20) .. u16(20) .. u16(0x0800) .. u16(0) .. u16(time) .. u16(date)
            .. u32(crc) .. u32(#data) .. u32(#data) .. u16(#e.name) .. u16(0) .. u16(0) .. u16(0) .. u16(0)
            .. u32(0) .. u32(offset) .. e.name
        offset = offset + #header + #data
    end
    local cd = table.concat(central)
    f:write(cd, "PK\5\6", u16(0), u16(0), u16(#entries), u16(#entries), u32(#cd), u32(offset), u16(0))
    f:close()
    return true
end

-- libarchive through KOReader's ffi/archiver.
function Zip.writeArchiver(path, entries, mtime)
    local ok, Archiver = pcall(require, "ffi/archiver")
    if not ok or not Archiver or not Archiver.Writer then return nil, "ffi/archiver not available" end
    local w = Archiver.Writer:new{}
    if not w:open(path, "zip") then return nil, w.err or "cannot open zip" end
    w:setZipCompression("deflate")
    for _, e in ipairs(entries) do
        if not w:addFileFromMemory(e.name, e.data, mtime or os.time()) then
            local werr = w.err
            w:close()
            return nil, werr or "cannot add " .. e.name
        end
    end
    w:close()
    return true
end

-- Prefer libarchive; fall back to the pure-Lua writer.
function Zip.write(path, entries, mtime)
    local ok = Zip.writeArchiver(path, entries, mtime)
    if ok then return true, "archiver" end
    local err
    ok, err = Zip.writeStored(path, entries, mtime)
    if ok then return true, "stored" end
    return nil, err
end

return Zip
