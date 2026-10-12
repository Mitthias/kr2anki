-- Render the painted fake-widget tree of the top window to SVG (approximate:
-- fonts are substituted, glyph metrics estimated like the layout stubs).
local ICONS = os.getenv("ICONS_DIR") -- KOReader resources/icons/mdlight

local function esc(s)
    return (tostring(s):gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub('"', "&quot;"))
end

local function color(c, inv)
    local v = c and c.v or 0
    if inv then v = 255 - v end
    return string.format("#%02x%02x%02x", v, v, v)
end

local function readIcon(w)
    local f = w.file
    if not f and w.icon then f = ICONS .. "/" .. w.icon .. ".svg" end
    if not f then return nil end
    local h = io.open(f)
    if not h then return nil end
    local s = h:read("*a"); h:close()
    return s
end

local function render(top, W, H)
    local out = { string.format('<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d" viewBox="0 0 %d %d" style="background:#fff">', W, H, W, H) }
    local function family(face)
        local n = face and face.name or ""
        if n:find("Serif") then return n:find("Italic") and "Georgia, serif;font-style:italic" or "Georgia, serif" end
        return "Helvetica, Arial, sans-serif" .. ((n:find("bold") or n:find("Bold")) and ";font-weight:600" or "")
    end
    local function walk(w, inv)
        if type(w) ~= "table" then return end
        local mt = getmetatable(w)
        local d = w.dimen
        if w.invert and d then inv = not inv end
        if mt and mt.__render then mt.__render(w, out, inv, family) end
        if w.background and d and w.bordersize ~= nil then
            local bg = color(w.background, inv)
            table.insert(out, string.format('<rect x="%d" y="%d" width="%d" height="%d" rx="%d" fill="%s"/>', d.x, d.y, d.w, d.h, w.radius or 0, bg))
        end
        if w.bordersize and w.bordersize > 0 and d then
            local b = w.bordersize
            table.insert(out, string.format('<rect x="%.1f" y="%.1f" width="%.1f" height="%.1f" rx="%d" fill="none" stroke="%s" stroke-width="%d"/>',
                d.x + b / 2, d.y + b / 2, d.w - b, d.h - b, w.radius or 0, color(w.color, inv), b))
        end
        for _, c in ipairs(w) do walk(c, inv) end
    end
    walk(top, false)
    table.insert(out, "</svg>")
    return table.concat(out, "\n")
end

-- Hook per-type renderers onto the stub classes.
local function install()
    local TextWidget = require("ui/widget/textwidget")
    local TextBoxWidget = require("ui/widget/textboxwidget")
    local LineWidget = require("ui/widget/linewidget")
    local IconWidget = require("ui/widget/iconwidget")
    TextWidget.__render = function(w, out, inv, family)
        if not w.dimen then return end
        local size = w.face.size
        local text = tostring(w.text)
        if w._truncated then
            -- crude ellipsis
            local maxc = math.floor(w._w / (size * 0.55)) - 1
            local acc, n = {}, 0
            for ch in text:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
                n = n + (#ch >= 3 and 1.8 or 1)
                if n > maxc then break end
                acc[#acc + 1] = ch
            end
            text = table.concat(acc) .. "…"
        end
        table.insert(out, string.format('<text x="%d" y="%d" style="font-family:%s;font-size:%dpx" fill="%s">%s</text>',
            w.dimen.x, w.dimen.y + math.floor(w._h / 2 + size * 0.36), family(w.face), size,
            color(w.fgcolor, inv), esc(text)))
    end
    TextBoxWidget.__render = function(w, out, inv, family)
        if not w.dimen then return end
        local size = w.face.size
        local lh = w.line_height_px
        local maxl = math.floor(w._h / lh)
        local lines = {}
        for para in (tostring(w.text) .. "\n"):gmatch("(.-)\n") do
            local line, lw = {}, 0
            for word in para:gmatch("%S+") do
                local ww = textWidth(word .. " ", size)
                if lw + ww > w.width and #line > 0 then
                    lines[#lines + 1] = table.concat(line, " "); line, lw = {}, 0
                end
                -- CJK: break by chars
                if ww > w.width then
                    for ch in word:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
                        local cw = textWidth(ch, size)
                        if lw + cw > w.width then lines[#lines + 1] = table.concat(line, ""); line, lw = {}, 0 end
                        line[#line + 1] = ch; lw = lw + cw
                    end
                else
                    line[#line + 1] = word; lw = lw + ww
                end
            end
            lines[#lines + 1] = table.concat(line, " ")
        end
        if #lines > maxl and maxl > 0 then
            lines = { unpack(lines, 1, maxl) }; lines[maxl] = lines[maxl] .. "…"
        end
        local anchor = w.alignment == "center" and "middle" or "start"
        local x = w.alignment == "center" and (w.dimen.x + w.width / 2) or w.dimen.x
        for i, l in ipairs(lines) do
            table.insert(out, string.format('<text x="%d" y="%d" text-anchor="%s" style="font-family:%s;font-size:%dpx" fill="%s">%s</text>',
                x, w.dimen.y + (i - 1) * lh + math.floor(lh * 0.72), anchor, family(w.face), size, color(w.fgcolor, inv), esc(l)))
        end
    end
    LineWidget.__render = function(w, out, inv)
        local d = w.dimen
        if d and d.x then
            table.insert(out, string.format('<rect x="%d" y="%d" width="%d" height="%d" fill="%s"/>', d.x, d.y, d.w, d.h, color(w.background, inv)))
        end
    end
    IconWidget.__render = function(w, out, inv)
        local d = w.dimen
        if not (d and d.x) then return end
        local svg = readIcon(w)
        local flip = inv ~= (w.invert or false)
        if svg then
            svg = svg:gsub("<%?xml.-%?>", ""):gsub("<!DOCTYPE.->", "")
            local open_tag = svg:match("<svg[^>]*>")
            local cleaned = open_tag:gsub('%s+width="[^"]*"', ""):gsub('%s+height="[^"]*"', ""):gsub('%s+x="[^"]*"', ""):gsub('%s+y="[^"]*"', "")
            cleaned = cleaned:gsub("<svg", string.format('<svg x="%d" y="%d" width="%d" height="%d"', d.x, d.y, d.w, d.h), 1)
            local a, b = svg:find(open_tag, 1, true)
            svg = svg:sub(1, a - 1) .. cleaned .. svg:sub(b + 1)
            if flip then svg = svg:gsub("#000000", "#ffffff"):gsub('"#000"', '"#fff"'):gsub("fill:#000", "fill:#fff") end
            if w.dim then svg = '<g opacity="0.35">' .. svg .. "</g>" end
            table.insert(out, svg)
        else
            table.insert(out, string.format('<rect x="%d" y="%d" width="%d" height="%d" fill="none" stroke="red"/>', d.x, d.y, d.w, d.h))
        end
    end
end

return { render = render, install = install }
