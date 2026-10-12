--[[--
SHA-1 (hex digest), used for Anki's note checksum (csum). Pure LuaJIT.
KOReader also ships ffi/sha2, which main.lua prefers when available.
--]]

local bit = require("bit")
local band, bor, bxor, bnot, rol, tobit = bit.band, bit.bor, bit.bxor, bit.bnot, bit.rol, bit.tobit

local function u32be(s, i)
    local a, b, c, d = s:byte(i, i + 3)
    return tobit(a * 0x1000000 + b * 0x10000 + c * 0x100 + d)
end

local function hex32(x)
    return string.format("%08x", x % 0x100000000)
end

return function(msg)
    local h0, h1, h2, h3, h4 = tobit(0x67452301), tobit(0xEFCDAB89), tobit(0x98BADCFE), tobit(0x10325476), tobit(0xC3D2E1F0)
    local ml = #msg
    msg = msg .. "\128" .. string.rep("\0", (55 - ml) % 64)
    local bits = ml * 8
    local hi = math.floor(bits / 0x100000000)
    local lo = bits % 0x100000000
    msg = msg .. string.char(
        math.floor(hi / 0x1000000) % 256, math.floor(hi / 0x10000) % 256, math.floor(hi / 0x100) % 256, hi % 256,
        math.floor(lo / 0x1000000) % 256, math.floor(lo / 0x10000) % 256, math.floor(lo / 0x100) % 256, lo % 256)
    local w = {}
    for chunk = 1, #msg, 64 do
        for i = 0, 15 do w[i] = u32be(msg, chunk + i * 4) end
        for i = 16, 79 do w[i] = rol(bxor(w[i - 3], w[i - 8], w[i - 14], w[i - 16]), 1) end
        local a, b, c, d, e = h0, h1, h2, h3, h4
        for i = 0, 79 do
            local f, k
            if i < 20 then f, k = bor(band(b, c), band(bnot(b), d)), 0x5A827999
            elseif i < 40 then f, k = bxor(b, c, d), 0x6ED9EBA1
            elseif i < 60 then f, k = bor(band(b, c), band(b, d), band(c, d)), 0x8F1BBCDC
            else f, k = bxor(b, c, d), 0xCA62C1D6 end
            local temp = tobit(rol(a, 5) + f + e + k + w[i])
            e, d, c, b, a = d, c, rol(b, 30), a, temp
        end
        h0, h1, h2, h3, h4 = tobit(h0 + a), tobit(h1 + b), tobit(h2 + c), tobit(h3 + d), tobit(h4 + e)
    end
    return hex32(h0) .. hex32(h1) .. hex32(h2) .. hex32(h3) .. hex32(h4)
end
