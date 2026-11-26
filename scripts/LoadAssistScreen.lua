-- =====================================================================================================================
-- LoadAssistScreen: het scherm in de cabine als lichtgevende laag, net als bij DigAssist.
--
-- Vanuit de binnencamera tekent LoadAssist het tabletscherm zelf, precies over het 3D-scherm heen en met perspectief:
-- de afbeelding van het opstart- of hoofdscherm, de bak, de voortgangsbalken van losse pixels en alle teksten. Het licht
-- in het spel heeft daar geen invloed op, dus het scherm licht op, ook 's nachts. Van buitenaf zie je het 3D-scherm.
-- Staat het menu open, dan tekent het menu het scherm eerst, zodat het menu erboven ligt.
--
-- Het schermvlak wordt bij het eerste tekenen bepaald: midden en maat uit de vorm van het hoofdscherm, de stand uit de
-- tekst-nodes (die liggen op het scherm). De uitkomst staat in log.txt. Met <screen> en <bars> in de xml van het voertuig
-- is alles bij te stellen; zie docs/LoadAssist-documentatie.html.
-- =====================================================================================================================

LoadAssistScreen = {}
local Screen = LoadAssistScreen

Screen.MOD_DIR    = g_currentModDirectory or ""
Screen.PIXEL_FILE = "textures/pixel.png" -- wit vlakje voor alle effen vlakken
Screen.images     = {}                   -- bestandsnaam -> overlay (of false)
Screen.i3dShapes  = {}                   -- i3d-bestand -> lijst met shapes en hun afbeelding (of false)

-- Overlay-letters: de letter-afbeelding van de 3D-letters met de drempel van de shader al toegepast, voor vier
-- letterdiktes onder elkaar (37 vakjes per rij, 2 rijen per dikte). De maten per teken komen uit fonts/customFonts.xml.
Screen.FONT = { name = "HANDELGOTHIC", file = "fonts/handelgothic_overlay.dds", columns = 37, rows = 2,
                thicknesses = { 1.0, 1.5, 2.0, 2.5 }, capBottom = 0.016, capTop = 0.797 }

-- Kleuren zoals setOverlayColor ze wil (lineair; het groen is #76c48a, hetzelfde als de geladen-teksten)
Screen.COLORS = {
    pixelOn    = { 0.184, 0.533, 0.238, 1 },
    pixelHead  = { 0.560, 0.900, 0.640, 1 }, -- licht op aan de kop van de balk zolang hij groeit
    pixelOff   = { 0.060, 0.058, 0.068, 1 }, -- net iets lichter dan de achtergrond
    frame      = { 0.209, 0.223, 0.227, 1 }, -- #7e8283, de rand van de balk in de schermafbeelding
    background = { 0.037, 0.035, 0.041, 1 }, -- #36353a, als er geen afbeelding is
    debug      = { 1, 0, 1, 1 },
}

-- Pixelbalk: maten in delen van de hoogte van de balk, tijden in ms
Screen.BAR = { pad = 0.09, gap = 0.10, frame = 0.12, headCells = 4, sweepTime = 3000 }
Screen.FULL_TEX = { 0, 0, 1, 1 }

local function exists(node)
    return node ~= nil and node ~= 0 and entityExists(node)
end

local function normalize(x, y, z)
    local len = math.sqrt(x * x + y * y + z * z)
    if len < 0.000001 then
        return 0, 0, 0, 0
    end
    return x / len, y / len, z / len, len
end

-- Kleur a -> b (t = 0..1) in een vaste tabel, zodat er per vlakje geen nieuwe tabel nodig is
local mixed = { 0, 0, 0, 1 }
local function mix(a, b, t)
    for i = 1, 4 do
        mixed[i] = a[i] + (b[i] - a[i]) * t
    end
    return mixed
end

-- =====================================================================================================================
-- LETTERS (ook gebruikt door het menu)
-- =====================================================================================================================
function Screen.utf8Chars(str)
    local list, i, n = {}, 1, string.len(str)
    while i <= n do
        local c = string.byte(str, i)
        local len = c >= 0xF0 and 4 or c >= 0xE0 and 3 or c >= 0xC0 and 2 or 1
        list[#list + 1] = string.sub(str, i, i + len - 1)
        i = i + len
    end
    return list
end

-- De overlay-letters met hun maten, één keer per kaart; nil als de afbeelding of de maten ontbreken
function Screen.getFont()
    if Screen.font == nil then
        local F, font = Screen.FONT, false
        local path = Screen.MOD_DIR .. F.file
        local metrics = (createImageOverlay ~= nil and fileExists(path)) and Screen.loadFontMetrics(F.name) or nil
        local overlay = metrics ~= nil and createImageOverlay(path) or 0
        if overlay ~= nil and overlay ~= 0 then
            font = metrics
            for k, v in pairs(F) do
                font[k] = v
            end
            font.overlay = overlay
        end
        Screen.font = font
    end
    return Screen.font or nil
end

-- Maten per teken uit fonts/customFonts.xml, zoals FontMaterial ze inleest
function Screen.loadFontMetrics(name)
    local path = Screen.MOD_DIR .. "fonts/customFonts.xml"
    local xmlId = fileExists(path) and loadXMLFile("loadAssistFont", path) or 0
    if xmlId == nil or xmlId == 0 then
        return nil
    end
    local font, i = nil, 0
    while font == nil do
        local key = string.format("fonts.font(%d)", i)
        if not hasXMLProperty(xmlId, key) then
            break
        end
        if string.upper(getXMLString(xmlId, key .. "#name") or "") == name then
            font = { chars = {},
                     spacingX = getXMLFloat(xmlId, key .. ".spacing#x") or 0,
                     spacingY = getXMLFloat(xmlId, key .. ".spacing#y") or 0,
                     charToChar = getXMLFloat(xmlId, key .. ".spacing#charToChar") or 0.05 }
            local j = 0
            while true do
                local ck = string.format("%s.character(%d)", key, j)
                if not hasXMLProperty(xmlId, ck) then
                    break
                end
                local value = getXMLString(xmlId, ck .. "#value")
                if value ~= nil then
                    local c = { uvIndex  = getXMLInt(xmlId, ck .. "#uvIndex") or 0,
                                spacingX = math.max(getXMLFloat(xmlId, ck .. "#spacingX") or font.spacingX, 0.0001),
                                spacingY = math.max(getXMLFloat(xmlId, ck .. "#spacingY") or font.spacingY, 0.0001),
                                offsetX  = getXMLFloat(xmlId, ck .. "#offsetX") or 0,
                                offsetY  = getXMLFloat(xmlId, ck .. "#offsetY") or 0 }
                    c.realSpacingX = math.max(getXMLFloat(xmlId, ck .. "#realSpacingX") or c.spacingX, 0.0001)
                    font.chars[value] = c
                    for _, variant in ipairs({ string.lower(value), string.upper(value) }) do
                        if font.chars[variant] == nil then
                            font.chars[variant] = c
                        end
                    end
                end
                j = j + 1
            end
        end
        i = i + 1
    end
    delete(xmlId)
    return font
end

-- Eén teken bij fontSize 1, zoals CharacterLine het zet: c (nil = onbekend teken, wordt niet getekend), breedte van het
-- vakje, afstand tot het volgende teken en de verschuiving (ox, oy)
function Screen.glyph(font, ch)
    local c = font.chars[ch]
    local sx, sy, rsx, ox, oy = font.spacingX, font.spacingY, font.spacingX, 0, 0
    if c ~= nil then
        sx, sy, rsx, ox, oy = c.spacingX, c.spacingY, c.realSpacingX, c.offsetX, c.offsetY
    end
    local w = (1 - 2 * sx) / (1 - 2 * sy)
    return c, w, w + font.charToChar * (sx / rsx), ox, oy
end

-- Deel van de letter-afbeelding voor teken c: s0, t0 (linksonder) en s1, t1 (rechtsboven)
function Screen.glyphUV(font, c, block)
    local numRows, pitch = font.rows * #font.thicknesses, font.columns - 0.01 -- zoals de shader: floor(fmod(index, 36.99)) / 36.99
    local col = math.floor(math.fmod(c.uvIndex, pitch))
    local row = block * font.rows + math.floor(c.uvIndex / font.columns)
    return c.spacingX / font.columns + col / pitch, 1 - (row + 1 - c.spacingY) / numRows,
           (1 - c.spacingX) / font.columns + col / pitch, 1 - (row + c.spacingY) / numRows
end

-- Het blok in de letter-afbeelding met de letterdikte die het dichtst bij thickness ligt
function Screen.thicknessBlock(font, thickness)
    local block, best = 0, math.huge
    for k, t in ipairs(font.thicknesses) do
        if math.abs(t - thickness) < best then
            block, best = k - 1, math.abs(t - thickness)
        end
    end
    return block
end

-- =====================================================================================================================
-- AFBEELDINGEN
-- =====================================================================================================================
-- Een afbeelding als overlay, één keer per bestand (gedeeld door alle voertuigen). Een .png mag ook als .dds bestaan.
function Screen.getImage(filename)
    if filename == nil or filename == "" or createImageOverlay == nil then
        return nil
    end
    local cached = Screen.images[filename]
    if cached == nil then
        local id = nil
        if fileExists(filename) or fileExists((string.gsub(filename, "%.%w+$", ".dds"))) then
            id = createImageOverlay(filename)
        else
            Logging.warning("LoadAssist: afbeelding '%s' niet gevonden.", filename)
        end
        cached = (id ~= nil and id ~= 0) and id or false
        Screen.images[filename] = cached
    end
    return cached or nil
end

function Screen.getPixel()
    return Screen.getImage(Screen.MOD_DIR .. Screen.PIXEL_FILE)
end

-- De afbeelding op een shape, gevraagd aan de engine (eerste materiaal); nil als dat niet lukt
function Screen.getRuntimeTexture(node)
    if getMaterial == nil or getMaterialDiffuseMapFilename == nil then
        return nil
    end
    local ok, material = pcall(getMaterial, node, 0)
    if not ok or material == nil or material == 0 then
        return nil
    end
    local ok2, file = pcall(getMaterialDiffuseMapFilename, material)
    if ok2 and type(file) == "string" and file ~= "" and (fileExists(file) or fileExists((string.gsub(file, "%.%w+$", ".dds")))) then
        return file
    end
    return nil
end

-- Alle shapes uit de i3d van het voertuig met hun afbeelding, naam, naam van de ouder en positie (één keer per i3d)
function Screen.getI3DShapes(vehicle)
    local i3dFile = vehicle.i3dFilename
    if i3dFile == nil and vehicle.xmlFile ~= nil then
        local rel = vehicle.xmlFile:getValue("vehicle.base.filename")
        if rel ~= nil then
            i3dFile = Utils.getFilename(rel, vehicle.baseDirectory)
        end
    end
    if i3dFile == nil then
        return nil
    end
    local cached = Screen.i3dShapes[i3dFile]
    if cached ~= nil then
        return cached or nil
    end
    Screen.i3dShapes[i3dFile] = false
    local xmlId = (loadXMLFile ~= nil and fileExists(i3dFile)) and loadXMLFile("loadAssistI3D", i3dFile) or 0
    if xmlId == nil or xmlId == 0 then
        return nil
    end
    local dir = string.match(i3dFile, "^(.*[/\\])") or ""
    local files, materials, shapes = {}, {}, {}
    local i = 0
    while hasXMLProperty(xmlId, string.format("i3D.Files.File(%d)", i)) do
        local key = string.format("i3D.Files.File(%d)", i)
        local id, name = getXMLInt(xmlId, key .. "#fileId"), getXMLString(xmlId, key .. "#filename")
        if id ~= nil and name ~= nil then
            files[id] = string.sub(name, 1, 1) == "$" and Utils.getFilename(name, dir) or dir .. name
        end
        i = i + 1
    end
    i = 0
    while hasXMLProperty(xmlId, string.format("i3D.Materials.Material(%d)", i)) do
        local key = string.format("i3D.Materials.Material(%d)", i)
        local id, tex = getXMLInt(xmlId, key .. "#materialId"), getXMLInt(xmlId, key .. ".Texture#fileId")
        if id ~= nil and tex ~= nil then
            materials[id] = files[tex]
        end
        i = i + 1
    end
    local function visit(path, parentName, depth)
        if depth > 32 then
            return
        end
        for _, kind in ipairs({ "TransformGroup", "Shape", "Light", "Camera" }) do
            local j = 0
            while hasXMLProperty(xmlId, string.format("%s.%s(%d)", path, kind, j)) do
                local key = string.format("%s.%s(%d)", path, kind, j)
                local name = getXMLString(xmlId, key .. "#name") or ""
                if kind == "Shape" then
                    local matId = tonumber(string.match(getXMLString(xmlId, key .. "#materialIds") or "", "^%s*(%d+)"))
                    local file = matId ~= nil and materials[matId] or nil
                    if file ~= nil then
                        local tx, ty, tz = string.match(getXMLString(xmlId, key .. "#translation") or "0 0 0", "(%S+)%s+(%S+)%s+(%S+)")
                        table.insert(shapes, { name = name, parent = parentName, file = file,
                                               tx = tonumber(tx) or 0, ty = tonumber(ty) or 0, tz = tonumber(tz) or 0 })
                    end
                end
                visit(key, name, depth + 1)
                j = j + 1
            end
        end
    end
    visit("i3D.Scene", "", 0)
    delete(xmlId)
    Screen.i3dShapes[i3dFile] = shapes
    return shapes
end

-- De afbeelding van een node volgens de i3d: herkend aan naam, naam van de ouder en positie
function Screen.findI3DTexture(vehicle, node)
    local shapes = Screen.getI3DShapes(vehicle)
    if shapes == nil or getName == nil then
        return nil
    end
    local parent = getParent(node)
    local name, parentName = getName(node), exists(parent) and getName(parent) or ""
    local tx, ty, tz = getTranslation(node)
    for _, s in ipairs(shapes) do
        if s.name == name and s.parent == parentName and math.abs(s.tx - tx) < 0.001 and math.abs(s.ty - ty) < 0.001
            and math.abs(s.tz - tz) < 0.001 then
            return s.file
        end
    end
    return nil
end

-- De afbeelding van een laag van het scherm (key = "main", "boot" of "miniBucket"): uit de xml (<screen mainImage=...>),
-- anders het materiaal van de node, anders de i3d. Eén keer per voertuig opgezocht.
function Screen.getNodeImage(vehicle, node, key)
    local cfg = vehicle.spec_loadAssist.screen
    local cached = cfg.nodeImages[key]
    if cached == nil then
        local file = cfg.images[key]
        if file == nil and exists(node) then
            file = Screen.getRuntimeTexture(node) or Screen.findI3DTexture(vehicle, node)
            if file == nil then
                Logging.warning("LoadAssist: geen afbeelding gevonden op '%s'; die laag van het scherm wordt overgeslagen.", tostring(getName(node)))
            end
        end
        cached = Screen.getImage(file) or false
        cfg.nodeImages[key] = cached
    end
    return cached or nil
end

-- Kaart dicht: alle overlays weg
function Screen.deleteAssets()
    for _, id in pairs(Screen.images) do
        if id then
            delete(id)
        end
    end
    if Screen.font then
        delete(Screen.font.overlay)
    end
    Screen.images, Screen.i3dShapes, Screen.font = {}, {}, nil
end

-- =====================================================================================================================
-- SCHERMVLAK
-- Alles in het assenstelsel van het hoofdscherm (mainScreenNode), zodat het meebeweegt met de cabine:
--   * midden en maat: de omsluitende bol van zijn vorm (straal = halve diagonaal) en de verhouding breedte/hoogte
--   * normaal (naar de bestuurder): het vlak door de tekst-nodes; bij de L90 zit de schuine stand in de vorm zelf, dus
--     geen as van de node ligt langs het scherm
--   * omhoog: omhoog van het voertuig, in het vlak gelegd; rechts = omhoog x normaal
-- =====================================================================================================================
function Screen.fitTextPlane(spec, node)
    local pts, mx, my, mz, zx, zy, zz = {}, 0, 0, 0, 0, 0, 0
    for _, t in ipairs(spec.texts) do
        if exists(t.node) then
            local x, y, z = worldToLocal(node, getWorldTranslation(t.node))
            pts[#pts + 1] = { x, y, z }
            mx, my, mz = mx + x, my + y, mz + z
            local dx, dy, dz = localDirectionToLocal(t.node, node, 0, 0, 1) -- Z van een tekst-node wijst naar de lezer
            zx, zy, zz = zx + dx, zy + dy, zz + dz
        end
    end
    local nx, ny, nz, len, source = 0, 0, 0, 0, "de Z-as van de tekst-nodes"
    if #pts >= 3 then
        -- kleinste kwadraten: de as met de grootste determinant als afhankelijke as
        mx, my, mz = mx / #pts, my / #pts, mz / #pts
        local xx, xy, xz, yy, yz, z2 = 0, 0, 0, 0, 0, 0
        for _, p in ipairs(pts) do
            local x, y, z = p[1] - mx, p[2] - my, p[3] - mz
            xx, xy, xz, yy, yz, z2 = xx + x * x, xy + x * y, xz + x * z, yy + y * y, yz + y * z, z2 + z * z
        end
        local detX, detY, detZ = yy * z2 - yz * yz, xx * z2 - xz * xz, xx * yy - xy * xy
        local best, trace = math.max(detX, detY, detZ), xx + yy + z2
        if best > 0.000001 * trace * trace then
            if best == detX then
                nx, ny, nz = detX, xz * yz - xy * z2, xy * yz - xz * yy
            elseif best == detY then
                nx, ny, nz = xz * yz - xy * z2, detY, xy * xz - yz * xx
            else
                nx, ny, nz = xy * yz - xz * yy, xy * xz - yz * xx, detZ
            end
            nx, ny, nz, len = normalize(nx, ny, nz)
            source = string.format("het vlak door %d tekst-nodes", #pts)
        end
    end
    if len == 0 then
        nx, ny, nz, len = normalize(zx, zy, zz)
    end
    if len == 0 then
        return nil
    end
    if nx * zx + ny * zy + nz * zz < 0 then
        nx, ny, nz = -nx, -ny, -nz
    end
    return nx, ny, nz, source
end

function Screen.computeFrame(vehicle)
    local spec = vehicle.spec_loadAssist
    local cfg = spec.screen
    cfg.frameDone, cfg.frame = true, nil
    local node = spec.mainScreenNode
    if not exists(node) or getShapeGeometryBoundingSphere == nil or localDirectionToLocal == nil then
        return
    end
    local ok, cx, cy, cz, radius = pcall(getShapeGeometryBoundingSphere, node)
    if not ok or radius == nil or radius <= 0 then
        Logging.warning("LoadAssist: het hoofdscherm heeft geen vorm; het scherm wordt niet als lichtgevende laag getekend.")
        return
    end

    -- Normaal: uit alignNode (Z), anders door de tekst-nodes
    local nx, ny, nz, source
    if exists(cfg.alignNode) then
        nx, ny, nz = normalize(localDirectionToLocal(cfg.alignNode, node, 0, 0, 1))
        source = "alignNode"
    else
        nx, ny, nz, source = Screen.fitTextPlane(spec, node)
    end
    if nx == nil or (nx == 0 and ny == 0 and nz == 0) then
        Logging.warning("LoadAssist: de stand van het scherm is niet te bepalen (geen tekst-nodes); zet <screen alignNode=...> in de xml.")
        return
    end
    -- De camera in de cabine zit altijd vóór het scherm
    local camera = getCamera ~= nil and getCamera() or 0
    if exists(camera) then
        local lx, ly, lz = worldToLocal(node, getWorldTranslation(camera))
        local dx, dy, dz = lx - cx, ly - cy, lz - cz
        if dx * dx + dy * dy + dz * dz < 9 and dx * nx + dy * ny + dz * nz < 0 then
            nx, ny, nz = -nx, -ny, -nz
        end
    end

    -- Omhoog: Y van alignNode, anders omhoog van het voertuig (ligt het scherm plat: vooruit), in het vlak gelegd
    local function inPlane(x, y, z)
        local d = x * nx + y * ny + z * nz
        return normalize(x - d * nx, y - d * ny, z - d * nz)
    end
    local ux, uy, uz, ulen = 0, 0, 0, 0
    if exists(cfg.alignNode) then
        ux, uy, uz, ulen = inPlane(localDirectionToLocal(cfg.alignNode, node, 0, 1, 0))
    end
    if ulen < 0.2 then
        ux, uy, uz, ulen = inPlane(localDirectionToLocal(vehicle.rootNode, node, 0, 1, 0))
    end
    if ulen < 0.2 then
        ux, uy, uz, ulen = inPlane(localDirectionToLocal(vehicle.rootNode, node, 0, 0, 1))
    end
    if ulen < 0.000001 then
        Logging.warning("LoadAssist: kan 'omhoog' van het scherm niet bepalen; het scherm wordt niet als lichtgevende laag getekend.")
        return
    end
    local rx, ry, rz = normalize(uy * nz - uz * ny, uz * nx - ux * nz, ux * ny - uy * nx)
    if cfg.roll ~= 0 then
        local c, s = math.cos(math.rad(cfg.roll)), math.sin(math.rad(cfg.roll))
        ux, uy, uz = ux * c - rx * s, uy * c - ry * s, uz * c - rz * s
        rx, ry, rz = normalize(uy * nz - uz * ny, uz * nx - ux * nz, ux * ny - uy * nx)
    end

    -- Maat: <screen size>, anders uit de straal (halve diagonaal) en de verhouding breedte/hoogte
    local w, h
    if cfg.size ~= nil then
        w, h = cfg.size[1], cfg.size[2]
    else
        local a = math.max(cfg.aspect, 0.01)
        w, h = 2 * radius * a / math.sqrt(1 + a * a), 2 * radius / math.sqrt(1 + a * a)
    end
    if cfg.offset ~= nil then
        cx, cy, cz = cx + cfg.offset[1] * rx + cfg.offset[2] * ux, cy + cfg.offset[1] * ry + cfg.offset[2] * uy,
                     cz + cfg.offset[1] * rz + cfg.offset[2] * uz
    end

    -- Wereld-meters per eenheid van het vlak (de node of zijn ouders kunnen geschaald zijn), voor de lettergrootte
    local function worldLength(dx, dy, dz)
        local ax, ay, az = localToWorld(node, cx, cy, cz)
        local bx, by, bz = localToWorld(node, cx + dx, cy + dy, cz + dz)
        local len = math.sqrt((bx - ax) ^ 2 + (by - ay) ^ 2 + (bz - az) ^ 2)
        return len > 0.000001 and len or 1
    end
    cfg.frame = { node = node, cx = cx, cy = cy, cz = cz, nx = nx, ny = ny, nz = nz, rx = rx, ry = ry, rz = rz,
                  ux = ux, uy = uy, uz = uz, meshW = w, meshH = h,
                  wpuU = worldLength(rx, ry, rz), wpuV = worldLength(ux, uy, uz) }
    Logging.info("LoadAssist: scherm %.4f x %.4f m (straal %.4f), midden %.4f %.4f %.4f, normaal %.3f %.3f %.3f (uit %s), omhoog %.3f %.3f %.3f",
        w, h, radius, cx, cy, cz, nx, ny, nz, source, ux, uy, uz)
end

-- =====================================================================================================================
-- TEKENVLAK
-- Punten op het schermvlak (u = rechts, v = omhoog, vanuit het midden) gaan via een homografie door de vier
-- geprojecteerde hoeken naar het beeld. Elk vlak wordt een paar gedraaide overlays (setOverlayRotation); grote vlakken
-- worden in tegels geknipt zodat elke tegel op minder dan 0,3 pixel na recht is. Afbeeldingen krijgen per hoek de
-- exacte texturecoördinaat. Overgenomen van DigAssist (createScreenCanvas). Geeft nil als het scherm niet in beeld is.
-- =====================================================================================================================
local CORNERS = { { 1, 1 }, { 1, -1 }, { -1, 1 }, { -1, -1 } }
local TOLERANCE = 0.3 -- pixels

function Screen.createCanvas(frame, brightness)
    local W, H = g_screenWidth, g_screenHeight
    local cw, ch = frame.meshW, frame.meshH

    local function projectPx(u, v)
        local wx, wy, wz = localToWorld(frame.node, frame.cx + u * frame.rx + v * frame.ux, frame.cy + u * frame.ry + v * frame.uy,
                                        frame.cz + u * frame.rz + v * frame.uz)
        local sx, sy, sz = project(wx, wy, wz)
        if sx == nil or sz == nil or sz <= 0 or sz >= 1 then
            return nil
        end
        return sx * W, sy * H
    end
    local x0, y0 = projectPx(-cw * 0.5, -ch * 0.5)
    local x1, y1 = projectPx(cw * 0.5, -ch * 0.5)
    local x2, y2 = projectPx(cw * 0.5, ch * 0.5)
    local x3, y3 = projectPx(-cw * 0.5, ch * 0.5)
    if x0 == nil or x1 == nil or x2 == nil or x3 == nil then
        return nil
    end
    local minX, maxX = math.min(x0, x1, x2, x3), math.max(x0, x1, x2, x3)
    local minY, maxY = math.min(y0, y1, y2, y3), math.max(y0, y1, y2, y3)
    if maxX < 0 or minX > W or maxY < 0 or minY > H or math.max(maxX - minX, maxY - minY) < 24 then
        return nil -- buiten beeld, of te klein om iets te lezen
    end

    -- Homografie van het eenheidsvierkant (s, t) naar de vier hoeken (Heckbert); s = (u + cw/2) / cw, t = (v + ch/2) / ch
    local sumX, sumY = x0 - x1 + x2 - x3, y0 - y1 + y2 - y3
    local dx1, dx2, dy1, dy2 = x1 - x2, x3 - x2, y1 - y2, y3 - y2
    local den = dx1 * dy2 - dx2 * dy1
    if math.abs(den) < 0.000001 then
        return nil
    end
    local hg = (sumX * dy2 - sumY * dx2) / den
    local hh = (dx1 * sumY - dy1 * sumX) / den
    local ha, hb, hc = x1 - x0 + hg * x1, x3 - x0 + hh * x3, x0
    local hd, he, hf = y1 - y0 + hg * y1, y3 - y0 + hh * y3, y0
    local invW, invH = 1 / cw, 1 / ch
    local function toPx(u, v)
        local s, t = (u + cw * 0.5) * invW, (v + ch * 0.5) * invH
        local q = hg * s + hh * t + 1
        return (ha * s + hb * t + hc) / q, (hd * s + he * t + hf) / q
    end

    local rotated = {}

    -- Texturecoördinaten van de huidige tegel: punt op het beeld -> (s, t) via de omgekeerde (affiene) afbeelding
    local tCx, tCy, tAx, tAy, tBx, tBy, tDet, tS0, tS1, tT0, tT1 = 0, 0, 1, 0, 0, 1, 1, 0, 1, 0, 1
    local hasTex = false
    local function texAt(px, py)
        local dx, dy = px - tCx, py - tCy
        local a = (dx * tBy - dy * tBx) / tDet
        local b = (tAx * dy - tAy * dx) / tDet
        return tS0 + (a + 0.5) * (tS1 - tS0), tT0 + (b + 0.5) * (tT1 - tT0)
    end

    -- Eén rechthoek op het beeld: midden (cx, cy), richting (ex, ey), lengte L langs die richting en dikte T (pixels).
    -- setOverlayRotation draait tegen de klok in om het opgegeven punt (hier het midden).
    local function rectPx(ovl, cx, cy, ex, ey, L, T)
        local pw, ph = L / W, T / H
        if hasTex then
            -- hoeken: linksonder, linksboven, rechtsonder, rechtsboven (na het draaien)
            local hx, hy = ex * L * 0.5, ey * L * 0.5
            local vx, vy = -ey * T * 0.5, ex * T * 0.5
            local s1, t1 = texAt(cx - hx - vx, cy - hy - vy)
            local s2, t2 = texAt(cx - hx + vx, cy - hy + vy)
            local s3, t3 = texAt(cx + hx - vx, cy + hy - vy)
            local s4, t4 = texAt(cx + hx + vx, cy + hy + vy)
            setOverlayUVs(ovl, s1, t1, s2, t2, s3, t3, s4, t4)
        end
        setOverlayRotation(ovl, math.atan2(ey, ex), pw * 0.5, ph * 0.5)
        rotated[ovl] = true
        renderOverlay(ovl, cx / W - pw * 0.5, cy / H - ph * 0.5, pw, ph)
    end

    -- Een parallellogram met midden C en zijden A en B (pixels), gedraaid langs de langste zijde. Loopt het scheef, dan
    -- in stroken: bij een echte rand (edgeA / edgeB) verspringen die hooguit 0,75 pixel; bij letters (texSafe) mag een
    -- strook hooguit dat deel van het lettervak buiten het vlak laten zien, anders komt er een stukje buurletter mee.
    -- Een dekkende tegel binnen een groot vlak wordt zoveel langer dat hij zijn schuine kanten helemaal dekt; de buurtegel
    -- tekent daar dezelfde inhoud, en zonder dat bleven er driehoekjes open naast de stroken van de randtegels.
    local function para(ovl, Cx, Cy, Ax, Ay, Bx, By, edgeA, edgeB, opaque, texSafe)
        local la2, lb2 = Ax * Ax + Ay * Ay, Bx * Bx + By * By
        if la2 < 0.09 or lb2 < 0.09 then
            return -- kleiner dan een derde pixel
        end
        local Lx, Ly, Sx, Sy, edge = Ax, Ay, Bx, By, edgeA
        if lb2 > la2 then
            Lx, Ly, Sx, Sy, edge = Bx, By, Ax, Ay, edgeB
        end
        local lenL = math.sqrt(Lx * Lx + Ly * Ly)
        local ex, ey = Lx / lenL, Ly / lenL
        local sPar = Sx * ex + Sy * ey            -- deel van S langs L (= scheefheid)
        local thick = math.abs(Sx * ey - Sy * ex) -- deel van S loodrecht op L (= echte dikte)
        if thick < 0.3 then
            return
        end
        local m = 1
        if texSafe ~= nil then
            m = math.ceil(math.abs(sPar) / (2 * texSafe * lenL))
        elseif edge then
            m = math.ceil(math.abs(sPar) / 0.75)
        end
        m = math.clamp(m, 1, 200)
        local T = thick / m + ((m > 1 and opaque) and 0.2 or 0)
        if m == 1 and opaque and not edge and texSafe == nil then
            lenL = lenL + math.abs(sPar)
        end
        for j = 0, m - 1 do
            local f = (j + 0.5) / m - 0.5
            rectPx(ovl, Cx + f * Sx, Cy + f * Sy, ex, ey, lenL, T)
        end
    end

    -- Een rechthoek op het schermvlak: midden (u, v), breedte w, hoogte h, gedraaid over rot. tex = {s0, t0, s1, t1}:
    -- de texture van linksonder tot rechtsboven (in de eigen stand van de rechthoek), of nil voor een effen vlak.
    -- soft = een letter (rond de letter is de afbeelding leeg en er liggen andere letters naast).
    local function item(ovl, u, v, w, h, rot, tex, soft, opaque)
        local c, s = math.cos(rot or 0), math.sin(rot or 0)
        local e1u, e1v = w * c, w * s
        local e2u, e2v = -h * s, h * c
        local n = 1
        local cx, cy = toPx(u, v)
        local ax1, ay1 = toPx(u + e1u * 0.5, v + e1v * 0.5)
        local ax0, ay0 = toPx(u - e1u * 0.5, v - e1v * 0.5)
        local bx1, by1 = toPx(u + e2u * 0.5, v + e2v * 0.5)
        local bx0, by0 = toPx(u - e2u * 0.5, v - e2v * 0.5)
        local Ax, Ay, Bx, By = (ax1 - ax0) * 0.5, (ay1 - ay0) * 0.5, (bx1 - bx0) * 0.5, (by1 - by0) * 0.5
        local err = 0
        for _, k in ipairs(CORNERS) do
            local qx, qy = toPx(u + (k[1] * e1u + k[2] * e2u) * 0.5, v + (k[1] * e1v + k[2] * e2v) * 0.5)
            local ex, ey = qx - (cx + k[1] * Ax + k[2] * Bx), qy - (cy + k[1] * Ay + k[2] * By)
            err = math.max(err, math.sqrt(ex * ex + ey * ey))
        end
        if err > TOLERANCE then
            n = math.min(10, math.ceil(math.sqrt(err / TOLERANCE)))
        end
        hasTex = tex ~= nil
        local texSafe = (soft and hasTex) and 0.04 * n or nil -- rond elk lettervak is minstens 4% leeg
        local grow = n > 1 and 0.35 or 0                     -- tegels een fractie laten overlappen tegen naadjes
        local h1u, h1v, h2u, h2v = e1u * 0.5 / n, e1v * 0.5 / n, e2u * 0.5 / n, e2v * 0.5 / n
        for i = 0, n - 1 do
            for j = 0, n - 1 do
                local fa, fb = (i + 0.5) / n - 0.5, (j + 0.5) / n - 0.5
                local tu, tv = u + fa * e1u + fb * e2u, v + fa * e1v + fb * e2v
                local Cx, Cy = toPx(tu, tv)
                local px1, py1 = toPx(tu + h1u, tv + h1v)
                local px0, py0 = toPx(tu - h1u, tv - h1v)
                local qx1, qy1 = toPx(tu + h2u, tv + h2v)
                local qx0, qy0 = toPx(tu - h2u, tv - h2v)
                local TAx, TAy, TBx, TBy = px1 - px0, py1 - py0, qx1 - qx0, qy1 - qy0
                local ok = true
                if hasTex then
                    tCx, tCy, tAx, tAy, tBx, tBy = Cx, Cy, TAx, TAy, TBx, TBy
                    tDet = TAx * TBy - TAy * TBx
                    ok = math.abs(tDet) > 0.000001
                    tS0 = tex[1] + (i / n) * (tex[3] - tex[1])
                    tS1 = tex[1] + ((i + 1) / n) * (tex[3] - tex[1])
                    tT0 = tex[2] + (j / n) * (tex[4] - tex[2])
                    tT1 = tex[2] + ((j + 1) / n) * (tex[4] - tex[2])
                end
                if ok then
                    if grow > 0 then
                        local la, lb = math.sqrt(TAx * TAx + TAy * TAy), math.sqrt(TBx * TBx + TBy * TBy)
                        if la > 0 and lb > 0 then
                            TAx, TAy = TAx * (1 + 2 * grow / la), TAy * (1 + 2 * grow / la)
                            TBx, TBy = TBx * (1 + 2 * grow / lb), TBy * (1 + 2 * grow / lb)
                        end
                    end
                    para(ovl, Cx, Cy, TAx, TAy, TBx, TBy, i == 0 or i == n - 1, j == 0 or j == n - 1, opaque, texSafe)
                end
            end
        end
        hasTex = false
    end

    -- Tekst precies zoals CharacterLine de 3D-letters zet: de tekens staan van rechts naar links, opts.numChars tekens
    -- (een langere tekst verliest vooraan tekens), met opts.pad rechts aangevuld met spaties zoals LoadAssist.padText,
    -- en het geheel gecentreerd op de node. Geeft de vlakjes (fontSize 1) en de breedte van de zichtbare tekst.
    local function textLayout(font, str, opts)
        local list = Screen.utf8Chars(str)
        local len = #list
        local total = opts.numChars or len
        if opts.pad and len > 0 and len < total then
            for _ = 1, math.floor((total - len) / 2) do
                list[#list + 1] = " "
            end
            len = #list
        end
        local block = Screen.thicknessBlock(font, opts.thickness or 1)
        local quads, xPos, realWidth = {}, 0, 0
        for i = 1, total do
            local chr = i <= len and list[len - i + 1] or " "
            local c, w, advance, ox, oy = Screen.glyph(font, chr)
            if c ~= nil and chr ~= " " then
                local s0, t0, s1, t1 = Screen.glyphUV(font, c, block)
                quads[#quads + 1] = { x = xPos - advance * 0.5 + advance * ox, y = 0.5 + oy, w = w, tex = { s0, t0, s1, t1 } }
            end
            xPos = xPos - advance
            if chr ~= " " and chr ~= "" then
                realWidth = xPos
            end
        end
        return quads, -realWidth
    end

    brightness = brightness or 1
    local function light(x)
        return math.min(x * brightness, 1)
    end
    local pixel = Screen.getPixel()
    local cv = { width = cw, height = ch }

    -- Effen vlak in een kleur {r, g, b, a}
    function cv.fill(color, u, v, w, h, alpha)
        local a = color[4] * (alpha or 1)
        if pixel == nil or a <= 0 then
            return
        end
        setOverlayColor(pixel, light(color[1]), light(color[2]), light(color[3]), a)
        item(pixel, u, v, w, h, 0, nil, false, a >= 1)
    end

    -- Afbeelding met texture-venster tex = {s0, t0, s1, t1} (linksonder, rechtsboven; v = 0 is onderaan)
    function cv.image(ovl, u, v, w, h, rot, tex, alpha)
        if alpha ~= nil and alpha <= 0 then
            return
        end
        setOverlayColor(ovl, light(1), light(1), light(1), alpha or 1)
        item(ovl, u, v, w, h, rot, tex, false, true)
    end

    -- Tekst op de plek van een tekst-node (u, v); sizeU / sizeV = fontSize in eenheden van het vlak
    function cv.text(font, str, u, v, sizeU, sizeV, color, opts)
        local quads, width = textLayout(font, str, opts or {})
        local rootX = width * 0.5
        setOverlayColor(font.overlay, light(color[1]), light(color[2]), light(color[3]), color[4] or 1)
        for _, q in ipairs(quads) do
            item(font.overlay, u + (q.x + rootX) * sizeU, v + q.y * sizeV, q.w * sizeU, sizeV, 0, q.tex, true, false)
        end
        return width * sizeU
    end

    -- Positie van een node op het schermvlak (loodrecht op het vlak)
    function cv.nodePoint(node)
        if not exists(node) then
            return nil
        end
        local lx, ly, lz = worldToLocal(frame.node, getWorldTranslation(node))
        local dx, dy, dz = lx - frame.cx, ly - frame.cy, lz - frame.cz
        return dx * frame.rx + dy * frame.ry + dz * frame.rz, dx * frame.ux + dy * frame.uy + dz * frame.uz
    end

    -- Punt op de schermafbeelding (s, t; linksboven = 0 0) naar het schermvlak
    function cv.texPoint(s, t)
        return (s - 0.5) * cw, (0.5 - t) * ch
    end

    -- Draaiing staat per overlay; terugzetten zodat een volgend gebruik (bijvoorbeeld het menu) weer recht begint
    function cv.finish()
        for ovl, _ in pairs(rotated) do
            setOverlayRotation(ovl, 0, 0, 0)
        end
    end

    return cv
end

-- =====================================================================================================================
-- TEKENEN
-- =====================================================================================================================
-- Tekent het scherm van dit voertuig; true als dat gelukt is (dan staan de teksten er ook al op)
function Screen.draw(vehicle)
    local spec = vehicle.spec_loadAssist
    local cfg = spec ~= nil and spec.screen or nil
    if cfg == nil or not cfg.enabled or (spec.screenState ~= "boot" and spec.screenState ~= "main") then
        return false -- een scherm dat uit staat, licht niet op
    end
    if project == nil or renderOverlay == nil or setOverlayRotation == nil or (g_gui ~= nil and g_gui:getIsGuiVisible()) then
        return false
    end
    local camera = vehicle.spec_enterable ~= nil and vehicle.spec_enterable.activeCamera or nil
    if camera ~= nil and camera.isInside == false then
        return false -- van buitenaf zou de laag over het beeld liggen; dan het 3D-scherm
    end
    if not cfg.frameDone then
        Screen.computeFrame(vehicle)
    end
    if cfg.frame == nil or not exists(cfg.frame.node) or Screen.getPixel() == nil then
        return false
    end
    local cv = Screen.createCanvas(cfg.frame, cfg.brightness)
    if cv == nil then
        return false
    end

    local alpha = cfg.debug and 0.5 or 1 -- bij debug half doorzichtig, zodat het 3D-scherm erdoor te zien is
    local fade = math.min(spec.screenTime / LoadAssist.FADE_TIME, 1)
    local boot = Screen.getNodeImage(vehicle, spec.bootScreenNode, "boot")
    if spec.screenState == "boot" then
        Screen.drawBackground(cv, boot, alpha * fade) -- het scherm licht langzaam op
    else
        Screen.drawBackground(cv, Screen.getNodeImage(vehicle, spec.mainScreenNode, "main"), alpha)
        Screen.drawMiniBucket(vehicle, cv)
        Screen.drawBars(vehicle, cv)
        Screen.drawTexts(vehicle, cv)
        if fade < 1 and boot ~= nil then
            cv.image(boot, 0, 0, cv.width, cv.height, 0, Screen.FULL_TEX, (1 - fade) * alpha) -- opstartscherm vervaagt
        end
    end
    if cfg.debug then
        Screen.drawDebug(vehicle, cv)
    end
    cv.finish()
    return true
end

function Screen.drawBackground(cv, image, alpha)
    if image ~= nil then
        cv.image(image, 0, 0, cv.width, cv.height, 0, Screen.FULL_TEX, alpha)
    else
        cv.fill(Screen.COLORS.background, 0, 0, cv.width, cv.height, alpha)
    end
end

-- De bak: het stuk van de bak-afbeelding rond de node (de afbeelding is zo groot als het scherm en de node staat op de
-- bak), gedraaid zoals de 3D-node nu ten opzichte van zijn ouder in het schermvlak gedraaid staat
function Screen.drawMiniBucket(vehicle, cv)
    local spec = vehicle.spec_loadAssist
    local node = spec.miniBucket
    local image = exists(node) and Screen.getNodeImage(vehicle, node, "miniBucket") or nil
    local u, v = cv.nodePoint(node)
    if image == nil or u == nil then
        return
    end
    local frame = spec.screen.frame
    local function planeAngle(n)
        local x, y, z = localDirectionToLocal(n, frame.node, 1, 0, 0)
        return math.atan2(x * frame.ux + y * frame.uy + z * frame.uz, x * frame.rx + y * frame.ry + z * frame.rz)
    end
    local parent = getParent(node)
    local rot = planeAngle(node) - (exists(parent) and planeAngle(parent) or 0)
    local size = spec.screen.miniBucketWindow
    local s, t = u / cv.width + 0.5, v / cv.height + 0.5 -- de node op de afbeelding (t vanaf onder)
    local ht = size * 0.5 * cv.width / cv.height
    cv.image(image, u, v, size * cv.width, size * cv.width, rot, { s - size * 0.5, t - ht, s + size * 0.5, t + ht })
end

-- De binnenkant van de balk van een teller op het schermvlak: midden (u, v), breedte, hoogte. Zonder eigen vak in de xml
-- ligt de balk net als die van Vrachtwagen, verschoven zoals de teksten van deze teller t.o.v. die van Vrachtwagen.
function Screen.getBarArea(vehicle, cv, m)
    local spec = vehicle.spec_loadAssist
    local box, du, dv = m.barArea, 0, 0
    if box == nil then
        local first = spec.modeList[1]
        box = first.barArea
        if box == nil or m == first then
            return nil
        end
        local ok = false
        for _, key in ipairs({ "Loaded", "Target" }) do
            local au, av = cv.nodePoint(LoadAssist.getTextNode(spec, m.name .. key))
            local bu, bv = cv.nodePoint(LoadAssist.getTextNode(spec, first.name .. key))
            if not ok and au ~= nil and bu ~= nil then
                du, dv, ok = au - bu, av - bv, true
            end
        end
        if not ok then
            return nil
        end
    end
    local u0, v0 = cv.texPoint(box[1], box[2])
    local u1, v1 = cv.texPoint(box[3], box[4])
    return (u0 + u1) * 0.5 + du, (v0 + v1) * 0.5 + dv, math.abs(u1 - u0), math.abs(v1 - v0)
end

function Screen.drawBars(vehicle, cv)
    local spec = vehicle.spec_loadAssist
    for _, m in ipairs(spec.modeList) do
        if m.enabled then
            local u, v, w, h = Screen.getBarArea(vehicle, cv, m)
            if u ~= nil and w > 0 and h > 0 then
                Screen.drawBar(spec.screen.bars, cv, m, u, v, w, h)
            end
        end
    end
end

-- Een balk van losse pixels: kolom voor kolom gevuld, de laatste kolom licht naar verhouding op. Zolang de balk groeit
-- (tijdens het lossen van de bak) lichten de pixels aan de kop op; is het doel gehaald, dan loopt er af en toe een
-- glans door de balk.
function Screen.drawBar(bars, cv, m, u, v, w, h)
    local C, B = Screen.COLORS, Screen.BAR
    if bars.frame then
        local stroke = h * B.frame
        cv.fill(C.frame, u, v + (h + stroke) * 0.5, w + 2 * stroke, stroke)
        cv.fill(C.frame, u, v - (h + stroke) * 0.5, w + 2 * stroke, stroke)
        cv.fill(C.frame, u - (w + stroke) * 0.5, v, stroke, h)
        cv.fill(C.frame, u + (w + stroke) * 0.5, v, stroke, h)
    end
    local rows = math.max(bars.rows, 1)
    local pad, gap = h * B.pad, h * B.gap
    local cell = (h - 2 * pad - (rows - 1) * gap) / rows
    if cell <= 0 then
        return
    end
    local cols = bars.columns
    if cols <= 0 then
        cols = math.max(math.floor((w - 2 * pad + gap) / (cell + gap)), 1) -- zo goed als vierkante pixels
    end
    local cellW = (w - 2 * pad - (cols - 1) * gap) / cols
    if cellW <= 0 then
        return
    end

    local value = math.clamp(m.barValue, 0, 1) * cols
    local full = math.floor(value)
    local sweep = nil
    if m.barValue >= 0.9999 then
        sweep = ((g_time or 0) % B.sweepTime) / B.sweepTime * (cols + 8) - 4
    end
    local left, bottom = u - w * 0.5 + pad + cellW * 0.5, v - h * 0.5 + pad + cell * 0.5
    for col = 0, cols - 1 do
        local lit = col < full and 1 or (col == full and value - full or 0)
        local color = C.pixelOff
        if lit > 0 then
            local glow = 0
            if m.barFlow > 0 then
                glow = math.max(0, 1 - (value - col - 1) / B.headCells) * m.barFlow
            end
            if sweep ~= nil then
                glow = math.max(glow, math.max(0, 1 - math.abs(col - sweep) / 3) * 0.6)
            end
            color = mix(C.pixelOn, C.pixelHead, math.min(glow, 1))
            if lit < 1 then
                color = mix(C.pixelOff, color, lit)
            end
        end
        local cu = left + col * (cellW + gap)
        for row = 0, rows - 1 do
            cv.fill(color, cu, bottom + row * (cell + gap), cellW, cell)
        end
    end
end

-- Alle teksten op de plek van hun tekst-node, met dezelfde letters, maat en dikte als de 3D-tekst
function Screen.drawTexts(vehicle, cv)
    local spec = vehicle.spec_loadAssist
    local font = Screen.getFont()
    if font == nil then
        return
    end
    local frame = spec.screen.frame
    local opts = { numChars = LoadAssist.NUM_CHARS, pad = true, thickness = math.max(spec.fontThickness or 1, LoadAssist.MIN_THICKNESS) }
    for _, t in ipairs(spec.texts) do
        local text, color = t.get(spec)
        if text ~= "" then
            local u, v = cv.nodePoint(t.node)
            if u ~= nil then
                cv.text(font, text, u, v, t.size / frame.wpuU, t.size / frame.wpuV, color, opts)
            end
        end
    end
end

-- Controle (<screen debug="true">): de rand van het schermvlak en een kruisje op elke tekst-node
function Screen.drawDebug(vehicle, cv)
    local C = Screen.COLORS.debug
    local w, h = cv.width, cv.height
    local t = math.max(w, h) * 0.006
    cv.fill(C, 0, h * 0.5, w + t, t)
    cv.fill(C, 0, -h * 0.5, w + t, t)
    cv.fill(C, -w * 0.5, 0, t, h + t)
    cv.fill(C, w * 0.5, 0, t, h + t)
    for _, text in ipairs(vehicle.spec_loadAssist.texts) do
        local u, v = cv.nodePoint(text.node)
        if u ~= nil then
            cv.fill(C, u, v, t * 4, t * 0.5)
            cv.fill(C, u, v, t * 0.5, t * 4)
        end
    end
end
