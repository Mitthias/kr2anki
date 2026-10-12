-- Base64 encoding (for AnkiConnect storeMediaFile). Pure Lua.
local chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
return function(data)
    local out = {}
    for i = 1, #data, 3 do
        local a, b, c = data:byte(i, i + 2)
        local n = a * 65536 + (b or 0) * 256 + (c or 0)
        local c1 = math.floor(n / 262144) % 64 + 1
        local c2 = math.floor(n / 4096) % 64 + 1
        local c3 = math.floor(n / 64) % 64 + 1
        local c4 = n % 64 + 1
        out[#out + 1] = chars:sub(c1, c1) .. chars:sub(c2, c2)
            .. (b and chars:sub(c3, c3) or "=") .. (c and chars:sub(c4, c4) or "=")
    end
    return table.concat(out)
end
