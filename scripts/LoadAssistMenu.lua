-- =====================================================================================================================
-- LoadAssistMenu: het menu van LoadAssist in "liquid glass"-stijl (Ctrl + R in de cabine).
--
-- Per teller (Vrachtwagen en Opdracht): aan/uit, het geladen gewicht met een voortgangsbalk, het doelgewicht met - en +
-- (Shift = x10, ook met het muiswiel) of door op het doel te klikken en te typen, en RESET (teller op 0). Rechtsklik op
-- het doel zet het terug op de standaardwaarde. Onderin: geluid bij het halen van een doel aan/uit en een testknop.
--
-- Het menu tekent zichzelf met overlays (textures/*.dds) en dezelfde HandelGothic-letters als het scherm in de cabine
-- (LoadAssistScreen.getFont). Achter het paneel wordt het beeld wazig, zoals bij de dialogen van het spel. Het
-- lichtgevende scherm in de cabine tekent het menu eerst, zodat het menu er altijd boven ligt.
-- Zolang het menu open is, heeft het een eigen input-context: de machine reageert dan niet op toetsen en de muis is vrij.
-- =====================================================================================================================

LoadAssistMenu = {}
local Menu = LoadAssistMenu

Menu.MOD_DIR   = g_currentModDirectory or ""
Menu.CONTEXT   = "LOAD_ASSIST_MENU"
Menu.OPEN_TIME = 180 -- ms
Menu.INPUT_DELAY = 250 -- ms na openen waarin sluiten wordt genegeerd (dezelfde toetsdruk)

Menu.WHITE = { 1, 1, 1 }
Menu.BLACK = { 0, 0, 0 }
Menu.GREEN = { 0.30, 0.84, 0.48 }
Menu.RED   = { 1.00, 0.45, 0.40 }
Menu.TINT  = { 0.05, 0.07, 0.10 } -- kleur van het glas

-- 9-slice afbeeldingen: wit met alpha, corner = grootte van een hoek in pixels van de afbeelding
Menu.TEXTURES = {
    fill    = { file = "textures/glass_fill.dds",     size = 128, corner = 48 },
    rim     = { file = "textures/glass_rim.dds",      size = 128, corner = 48 },
    rimBold = { file = "textures/glass_rim_bold.dds", size = 128, corner = 48 },
    sheen   = { file = "textures/glass_sheen.dds",    size = 128, corner = 48 },
    shadow  = { file = "textures/glass_shadow.dds",   size = 256, corner = 88 }, -- vorm met straal 48, 40 px vervaging
    icons   = { file = "textures/menu_icons.dds" },
}
Menu.ICONS = { close = 0, plus = 1, minus = 2, reset = 3, check = 4, bell = 5, truck = 6, pile = 7 }
Menu.ICON_COUNT = 8

-- Maten in eenheden: 1 eenheid = 1 pixel bij 1080p en UI-schaal 100%
Menu.PANEL_W, Menu.PANEL_H, Menu.PAD, Menu.RADIUS = 880, 370, 26, 30
Menu.CARD_Y, Menu.CARD_H, Menu.CARD_GAP, Menu.CARD_RADIUS = 80, 206, 16, 20
Menu.FOOTER_Y = 324 -- midden van de onderste regel

Menu.state  = nil -- open menu
Menu.alpha  = 1   -- doorzichtigheid tijdens het openen
Menu.assets = nil

local function round(v)
    return math.floor(v + 0.5)
end

-- =====================================================================================================================
-- OPENEN EN SLUITEN
-- =====================================================================================================================
function Menu.toggle(vehicle)
    if Menu.state ~= nil then
        if Menu.state.time >= Menu.INPUT_DELAY then
            Menu.close()
        end
    else
        Menu.open(vehicle)
    end
end

function Menu.open(vehicle)
    if Menu.state ~= nil or vehicle == nil or vehicle.spec_loadAssist == nil or (g_gui ~= nil and g_gui:getIsGuiVisible()) then
        return
    end
    if not Menu.loadAssets() then
        Logging.warning("LoadAssist: afbeeldingen van het menu ontbreken (map textures); het menu gaat niet open.")
        return
    end
    local st = { vehicle = vehicle, time = 0, blink = 0, hits = {}, anims = {} }
    Menu.state = st

    st.cursorWasShown = g_inputBinding:getShowMouseCursor()
    g_inputBinding:setContext(Menu.CONTEXT, true, false)
    local function register(action, callback, text)
        if action == nil then
            return
        end
        local _, id = g_inputBinding:registerActionEvent(action, Menu, callback, false, true, false, true)
        if id ~= nil then
            g_inputBinding:setActionEventText(id, text)
            g_inputBinding:setActionEventTextVisibility(id, true)
        end
    end
    register(InputAction.MENU_BACK, Menu.onBack, "Sluiten")
    register(InputAction.MENU_ACCEPT, Menu.onAccept, "Toepassen")
    register(InputAction.LOAD_ASSIST_MENU, Menu.onMenuKey, "Load Assist: Menu sluiten")
    g_inputBinding:setShowMouseCursor(true)

    if g_depthOfFieldManager ~= nil then
        local x, y, w, h = Menu.getPanelRect()
        g_depthOfFieldManager:pushArea(x / g_screenWidth, y / g_screenHeight, w / g_screenWidth, h / g_screenHeight)
        st.blur = true
    end
    Menu.playUiSound("CLICK")
end

function Menu.close()
    local st = Menu.state
    if st == nil then
        return
    end
    Menu.commitEdit()
    Menu.state = nil
    g_inputBinding:removeActionEventsByTarget(Menu)
    if g_inputBinding:getContextName() == Menu.CONTEXT then
        g_inputBinding:revertContext(true)
    else
        Menu.revertPending = true -- er staat iets anders bovenop; terugzetten zodra onze context weer bovenaan is
    end
    g_inputBinding:setShowMouseCursor(st.cursorWasShown == true)
    if st.blur and g_depthOfFieldManager ~= nil then
        g_depthOfFieldManager:popArea()
    end
    Menu.playUiSound("BACK")
end

function Menu.onVehicleGone(vehicle)
    if Menu.state ~= nil and Menu.state.vehicle == vehicle then
        Menu.close()
    end
end

function Menu.onBack()
    local st = Menu.state
    if st == nil or st.time < Menu.INPUT_DELAY then
        return
    end
    if st.edit ~= nil then
        st.edit = nil -- typen afbreken
    else
        Menu.close()
    end
end

function Menu.onAccept()
    local st = Menu.state
    if st == nil or st.time < Menu.INPUT_DELAY then
        return
    end
    if st.edit ~= nil then
        Menu.commitEdit()
        Menu.playUiSound("CLICK")
    else
        Menu.close()
    end
end

function Menu.onMenuKey()
    if Menu.state ~= nil and Menu.state.time >= Menu.INPUT_DELAY then
        Menu.close()
    end
end

function Menu.playUiSound(name)
    if g_gui ~= nil and g_gui.guiSoundPlayer ~= nil and GuiSoundPlayer ~= nil and GuiSoundPlayer.SOUND_SAMPLES[name] ~= nil then
        g_gui.guiSoundPlayer:playSample(GuiSoundPlayer.SOUND_SAMPLES[name])
    end
end

-- =====================================================================================================================
-- AFBEELDINGEN EN LETTERS
-- =====================================================================================================================
function Menu.loadAssets()
    if Menu.assets ~= nil then
        return Menu.assets.ok
    end
    local assets = { ok = true }
    for key, tex in pairs(Menu.TEXTURES) do
        local path = Menu.MOD_DIR .. tex.file
        local id = fileExists(path) and createImageOverlay(path) or 0
        assets[key] = id or 0
        if assets[key] == 0 then
            assets.ok = false
        end
    end
    Menu.assets = assets
    Menu.font = LoadAssistScreen.getFont() -- nil: dan de gewone letters van het spel
    return assets.ok
end

function Menu.deleteAssets()
    for _, id in pairs(Menu.assets or {}) do
        if type(id) == "number" and id ~= 0 then
            delete(id)
        end
    end
    Menu.assets, Menu.font = nil, nil -- de letters zijn van LoadAssistScreen en worden daar opgeruimd
end

-- Tekens van links naar rechts, net zo groot en op dezelfde plek als CharacterLine ze zet (fontSize = 1)
function Menu.layoutText(str)
    local quads, x = {}, 0
    for _, ch in ipairs(LoadAssistScreen.utf8Chars(str)) do
        local c, w, advance, ox, oy = LoadAssistScreen.glyph(Menu.font, ch)
        if c ~= nil then
            quads[#quads + 1] = { c = c, x = x + advance * (0.5 + ox) - w * 0.5, y = oy, w = w }
        end
        x = x + advance
    end
    return quads, x
end

-- Tekst: (x, y) in pixels met y = onderkant van de hoofdletters, cap = hoogte van de hoofdletters in pixels,
-- align = "left", "center" of "right". Zonder overlay-letters de gewone letters van het spel. Geeft de breedte terug.
function Menu.text(str, x, y, cap, color, alpha, align, thickness)
    local W, H = g_screenWidth, g_screenHeight
    local width = Menu.textWidth(str, cap)
    local left = (align == "center" and x - width * 0.5) or (align == "right" and x - width) or x
    if Menu.font == nil then
        setTextBold(true)
        setTextAlignment(RenderText.ALIGN_LEFT)
        setTextColor(color[1], color[2], color[3], alpha * Menu.alpha)
        renderText(left / W, y / H, cap / 0.72 / H, str)
        setTextBold(false)
        setTextColor(1, 1, 1, 1)
        return width
    end
    local font = Menu.font
    local ovl = font.overlay
    local size = cap / (font.capTop - font.capBottom)
    local base = y - font.capBottom * size
    local block = LoadAssistScreen.thicknessBlock(font, thickness or 1.5)
    setOverlayColor(ovl, color[1], color[2], color[3], alpha * Menu.alpha)
    for _, q in ipairs((Menu.layoutText(str))) do
        local u0, v0, u1, v1, drop = LoadAssistScreen.glyphUV(font, q.c, block)
        setOverlayUVs(ovl, u0, v0, u0, v1, u1, v0, u1, v1)
        renderOverlay(ovl, (left + q.x * size) / W, (base + (q.y - drop) * size) / H, q.w * size / W, (1 + drop) * size / H)
    end
    return width
end

function Menu.textWidth(str, cap)
    if Menu.font == nil then
        setTextBold(true)
        local width = getTextWidth(cap / 0.72 / g_screenHeight, str) * g_screenWidth
        setTextBold(false)
        return width
    end
    local _, width = Menu.layoutText(str)
    return width * cap / (Menu.font.capTop - Menu.font.capBottom)
end

-- =====================================================================================================================
-- TEKENEN: glas (9-slice), schaduw, iconen, knoppen en schakelaars
-- =====================================================================================================================
function Menu.nine(key, x, y, w, h, corner, color, alpha)
    local ovl, tex = Menu.assets[key], Menu.TEXTURES[key]
    x, y, w, h = round(x), round(y), round(w), round(h)
    if alpha <= 0 or w < 1 or h < 1 then
        return
    end
    local c = math.max(math.min(round(corner), math.floor(w / 2), math.floor(h / 2)), 0)
    local i = tex.corner / tex.size
    local xs, ys, uv = { x, x + c, x + w - c, x + w }, { y, y + c, y + h - c, y + h }, { 0, i, 1 - i, 1 }
    local W, H = g_screenWidth, g_screenHeight
    setOverlayColor(ovl, color[1], color[2], color[3], alpha * Menu.alpha)
    for col = 1, 3 do
        local qw = xs[col + 1] - xs[col]
        for row = 1, 3 do
            local qh = ys[row + 1] - ys[row]
            if qw > 0 and qh > 0 then
                setOverlayUVs(ovl, uv[col], uv[row], uv[col], uv[row + 1], uv[col + 1], uv[row], uv[col + 1], uv[row + 1])
                renderOverlay(ovl, xs[col] / W, ys[row] / H, qw / W, qh / H)
            end
        end
    end
end

-- Zachte schaduw (of gloed) rond een vlak met hoekstraal radius
function Menu.shadow(x, y, w, h, radius, color, alpha)
    local k = radius / 48
    Menu.nine("shadow", x - 40 * k, y - 40 * k, w + 80 * k, h + 80 * k, 88 * k, color, alpha)
end

-- Een glasvlak: schaduw, getinte vulling, glans bovenin en een lichte rand (opts: tint, fill, rim, rimColor, sheen, shadow, bold)
function Menu.glass(x, y, w, h, radius, opts)
    if opts.shadow then
        Menu.shadow(x, y, w, h, radius, Menu.BLACK, opts.shadow)
    end
    Menu.nine("fill", x, y, w, h, radius, opts.tint or Menu.WHITE, opts.fill or 0.08)
    if opts.sheen then
        Menu.nine("sheen", x, y, w, h, radius, Menu.WHITE, opts.sheen)
    end
    Menu.nine(opts.bold and "rimBold" or "rim", x, y, w, h, radius, opts.rimColor or Menu.WHITE, opts.rim or 0.3)
end

function Menu.icon(name, cx, cy, size, color, alpha)
    local ovl, i = Menu.assets.icons, Menu.ICONS[name]
    local u0, u1 = i / Menu.ICON_COUNT, (i + 1) / Menu.ICON_COUNT
    local W, H = g_screenWidth, g_screenHeight
    size = round(size)
    setOverlayUVs(ovl, u0, 0, u0, 1, u1, 0, u1, 1)
    setOverlayColor(ovl, color[1], color[2], color[3], alpha * Menu.alpha)
    renderOverlay(ovl, round(cx - size / 2) / W, round(cy - size / 2) / H, size / W, size / H)
end

function Menu.addHit(x, y, w, h, id)
    table.insert(Menu.state.hits, { x = x, y = y, w = w, h = h, id = id })
end

function Menu.isHover(kind, index)
    local hover = Menu.state.hover
    return hover ~= nil and hover.kind == kind and hover.index == index
end

-- Waarde die zacht naar zijn doel loopt (schakelaars, balken)
function Menu.anim(key, target)
    local a = Menu.state.anims[key]
    if a == nil then
        a = { value = target }
        Menu.state.anims[key] = a
    end
    a.target = target
    return a.value
end

function Menu.roundButton(kind, index, icon, x, y, size)
    local hover = Menu.isHover(kind, index)
    Menu.glass(x, y, size, size, size / 2, { fill = hover and 0.22 or 0.10, rim = hover and 0.5 or 0.28, bold = true })
    Menu.icon(icon, x + size / 2, y + size / 2, size * 0.5, Menu.WHITE, 0.95)
    Menu.addHit(x, y, size, size, { kind = kind, index = index })
end

-- opts: icon, hover (kleur bij hover), cap (letterhoogte in pixels)
function Menu.pillButton(kind, index, label, opts, x, y, w, h)
    local hover = Menu.isHover(kind, index)
    local cap = opts.cap or 0.27 * h
    Menu.glass(x, y, w, h, h / 2, { tint = hover and (opts.hover or Menu.WHITE) or Menu.WHITE, fill = hover and 0.28 or 0.10,
        rim = hover and 0.5 or 0.24, bold = true })
    local iconSize = opts.icon ~= nil and 0.6 * h or 0
    local gap = opts.icon ~= nil and 0.08 * h or 0
    local left = x + (w - iconSize - gap - Menu.textWidth(label, cap)) / 2
    if opts.icon ~= nil then
        Menu.icon(opts.icon, left + iconSize / 2, y + h / 2, iconSize, Menu.WHITE, 0.95)
    end
    Menu.text(label, left + iconSize + gap, y + h / 2 - cap / 2, cap, Menu.WHITE, 0.95, "left", 2.0)
    Menu.addHit(x, y, w, h, { kind = kind, index = index })
end

function Menu.switch(kind, index, on, x, y, w, h)
    local t = Menu.anim(kind .. tostring(index), on and 1 or 0)
    local hover = Menu.isHover(kind, index)
    local color = { 1 + (Menu.GREEN[1] - 1) * t, 1 + (Menu.GREEN[2] - 1) * t, 1 + (Menu.GREEN[3] - 1) * t }
    Menu.glass(x, y, w, h, h / 2, { tint = color, fill = 0.16 + 0.72 * t + (hover and 0.08 or 0), rim = 0.25, bold = true })
    local inset = math.max(round(h * 0.11), 2)
    local knob = h - 2 * inset
    local kx = x + inset + (w - knob - 2 * inset) * t
    Menu.shadow(kx, y + inset, knob, knob, knob / 2, Menu.BLACK, 0.35)
    Menu.nine("fill", kx, y + inset, knob, knob, knob / 2, Menu.WHITE, 0.97)
    Menu.addHit(x, y, w, h, { kind = kind, index = index })
end

function Menu.getScale()
    local uiScale = 1
    if g_gameSettings ~= nil and GameSettings ~= nil and GameSettings.SETTING ~= nil and GameSettings.SETTING.UI_SCALE ~= nil then
        uiScale = g_gameSettings:getValue(GameSettings.SETTING.UI_SCALE) or 1
    end
    return math.min(uiScale * g_screenHeight / 1080, g_screenWidth * 0.94 / Menu.PANEL_W)
end

-- Plek van het paneel in pixels (x, y = linksonder)
function Menu.getPanelRect(slide)
    local s = Menu.getScale()
    local w, h = round(Menu.PANEL_W * s), round(Menu.PANEL_H * s)
    return round((g_screenWidth - w) / 2), round((g_screenHeight - h) / 2 - (slide or 0) * s), w, h
end

function Menu:draw()
    local st = Menu.state
    if st == nil or Menu.assets == nil or (g_gui ~= nil and g_gui:getIsGuiVisible()) then
        return
    end
    LoadAssistScreen.draw(st.vehicle) -- het scherm in de cabine onder het menu
    local spec = st.vehicle.spec_loadAssist
    local s = Menu.getScale()
    local e = 1 - (1 - math.min(st.time / Menu.OPEN_TIME, 1)) ^ 3
    Menu.alpha = e
    st.hits = {}

    local px, py, pw, ph = Menu.getPanelRect((1 - e) * 18)
    local top = py + ph
    -- Rechthoek in eenheden vanaf linksboven van het paneel -> pixels (x, y = linksonder)
    local function box(dx, dy, dw, dh)
        return px + dx * s, top - (dy + dh) * s, dw * s, dh * s
    end
    -- Tekst op (dx, dy) in eenheden, dy = onderkant van de hoofdletters vanaf de bovenkant van het paneel
    local function label(str, dx, dy, cap, color, alpha, align, thickness)
        return Menu.text(str, px + dx * s, top - dy * s, cap * s, color, alpha, align, thickness)
    end

    -- Paneel
    Menu.glass(px, py, pw, ph, Menu.RADIUS * s, { tint = Menu.TINT, fill = 0.58, sheen = 1, rim = 0.55, shadow = 0.5 })
    Menu.addHit(px, py, pw, ph, { kind = "panel" })

    -- Kop
    local titleWidth = label("LOAD ASSIST", Menu.PAD, 54, 22, Menu.WHITE, 1, "left", 2.0)
    Menu.text("DOELGEWICHT INSTELLEN", px + Menu.PAD * s + titleWidth + 16 * s, top - 54 * s, 11 * s, Menu.WHITE, 0.55, "left", 1.5)
    Menu.roundButton("close", nil, "close", box(Menu.PANEL_W - Menu.PAD - 36, 25, 36, 36))
    local lx, ly, lw, lh = box(Menu.PAD, 70, Menu.PANEL_W - 2 * Menu.PAD, 1)
    Menu.nine("fill", lx, ly, lw, math.max(lh, 1), 0, Menu.WHITE, 0.10)

    -- Kaarten
    local cardW = (Menu.PANEL_W - 2 * Menu.PAD - Menu.CARD_GAP) / 2
    for i, m in ipairs(spec.modeList) do
        Menu.drawCard(st, spec, m, i, Menu.PAD + (i - 1) * (cardW + Menu.CARD_GAP), Menu.CARD_Y, cardW, Menu.CARD_H, s, box, label)
    end

    -- Onderste regel: geluid aan/uit, testknop en uitleg
    local cy = top - Menu.FOOTER_Y * s
    Menu.icon("bell", px + (Menu.PAD + 11) * s, cy, 22 * s, Menu.WHITE, spec.soundEnabled and 0.9 or 0.4)
    local textWidth = Menu.text("GELUID BIJ DOEL", px + (Menu.PAD + 30) * s, cy - 5.5 * s, 11 * s, Menu.WHITE, 0.85, "left", 1.5)
    local sx = px + (Menu.PAD + 30 + 14) * s + textWidth
    Menu.switch("sound", nil, spec.soundEnabled, sx, cy - 13 * s, 46 * s, 26 * s)
    Menu.pillButton("test", nil, "TEST", { cap = 9.5 * s }, sx + 58 * s, cy - 14 * s, 72 * s, 28 * s)
    Menu.text("Klik op het doel om te typen   Shift: grote stap   Esc: sluiten", px + (Menu.PANEL_W - Menu.PAD) * s, cy - 5 * s,
        10 * s, Menu.WHITE, 0.45, "right", 1.5)
end

function Menu.drawCard(st, spec, m, i, cx, cy, cw, ch, s, box, label)
    local selected = spec.selectedMode == i
    local dim = m.enabled and 1 or 0.45
    local function cbox(dx, dy, dw, dh)
        return box(cx + dx, cy + dy, dw, dh)
    end
    local x, y, w, h = cbox(0, 0, cw, ch)
    Menu.glass(x, y, w, h, Menu.CARD_RADIUS * s, { fill = selected and 0.085 or 0.05, rim = selected and 0.6 or 0.28,
        rimColor = selected and Menu.GREEN or Menu.WHITE })
    Menu.addHit(x, y, w, h, { kind = "card", index = i })

    -- Naam en aan/uit
    local ix, iy = cbox(33, 32, 0, 0)
    Menu.icon(i == 1 and "truck" or "pile", ix, iy, 32 * s, Menu.WHITE, 0.9 * dim)
    label(string.upper(m.title), cx + 54, cy + 38.5, 13, Menu.WHITE, 0.95 * dim, "left", 2.0)
    Menu.switch("toggle", i, m.enabled, cbox(cw - 20 - 50, 18, 50, 28))

    -- Geladen gewicht (ook wat nu uit de bak gaat) en voortgang
    local loaded = LoadAssist.getShownLoaded(spec, m)
    local pct = math.min(loaded / m.target, 1)
    local valueWidth = label(string.format("%.1f", loaded), cx + 20, cy + 98, 32, Menu.WHITE, dim, "left", 2.0)
    label("t", cx + 20 + valueWidth / s + 7, cy + 98, 15, Menu.WHITE, 0.6 * dim, "left", 1.5)
    if not m.enabled then
        label("UIT", cx + cw - 20, cy + 98, 16, Menu.WHITE, 0.45, "right", 2.0)
    elseif m.targetReached then
        local width = label("DOEL GEHAALD", cx + cw - 20, cy + 96, 12, Menu.GREEN, 1, "right", 2.0)
        local rx, ry = cbox(cw - 20, 90, 0, 0)
        Menu.icon("check", rx - width - 14 * s, ry, 20 * s, Menu.GREEN, 1)
    else
        label(string.format("%d%%", math.floor(pct * 100)), cx + cw - 20, cy + 98, 18, Menu.WHITE, 0.8, "right", 1.5)
    end

    local bx, by, bw, bh = cbox(20, 112, cw - 40, 8)
    Menu.nine("fill", bx, by, bw, bh, bh / 2, Menu.WHITE, 0.10)
    local shown = Menu.anim("bar" .. i, m.enabled and pct or 0)
    if shown > 0.002 then
        local fw = math.max(bw * shown, bh)
        if m.targetReached then
            Menu.shadow(bx, by, fw, bh, 10 * s, Menu.GREEN, 0.45)
        end
        Menu.nine("fill", bx, by, fw, bh, bh / 2, Menu.GREEN, 0.95)
    end

    -- Doelgewicht: -  [ 25.0 t ]  +       RESET
    label("DOELGEWICHT", cx + 20, cy + 142, 9, Menu.WHITE, 0.5, "left", 1.5)
    label(string.format("STAP %g t", m.menuStep), cx + cw - 20, cy + 142, 9, Menu.WHITE, 0.4, "right", 1.5)
    Menu.roundButton("minus", i, "minus", cbox(20, 152, 40, 40))
    Menu.roundButton("plus", i, "plus", cbox(216, 152, 40, 40))

    local fx, fy, fw, fh = cbox(68, 152, 140, 40)
    local editing = st.edit ~= nil and st.edit.index == i
    local hover = Menu.isHover("field", i)
    Menu.glass(fx, fy, fw, fh, 12 * s, { tint = Menu.BLACK, fill = editing and 0.42 or (hover and 0.34 or 0.26),
        rim = editing and 0.95 or (hover and 0.45 or 0.22), rimColor = editing and Menu.GREEN or Menu.WHITE })
    local value = editing and st.edit.text or string.format("%.1f", m.target)
    local valueCap, unitCap = 16 * s, 11 * s
    local vw, uw = Menu.textWidth(value, valueCap), Menu.textWidth("t", unitCap)
    local caretGap = editing and 4 * s or 0
    local left = fx + (fw - vw - caretGap - 6 * s - uw) / 2
    local baseY = fy + fh / 2 - valueCap / 2
    Menu.text(value, left, baseY, valueCap, (editing and st.edit.fresh) and Menu.GREEN or Menu.WHITE, dim, "left", 2.0)
    if editing and st.blink < 530 then
        Menu.nine("fill", left + vw + 1.5 * s, baseY - 2 * s, math.max(round(2 * s), 1), valueCap + 4 * s, 0, Menu.GREEN, 1)
    end
    Menu.text("t", left + vw + caretGap + 6 * s, baseY, unitCap, Menu.WHITE, 0.6 * dim, "left", 1.5)
    Menu.addHit(fx, fy, fw, fh, { kind = "field", index = i })

    Menu.pillButton("reset", i, "RESET", { icon = "reset", hover = Menu.RED, cap = 11 * s }, cbox(cw - 20 - 112, 152, 112, 40))
end

-- =====================================================================================================================
-- MUIS EN TOETSEN
-- =====================================================================================================================
function Menu.isShiftDown()
    return Input.isKeyPressed(Input.KEY_lshift) or Input.isKeyPressed(Input.KEY_rshift)
end

-- Doel één stap omhoog of omlaag, naar het eerstvolgende veelvoud van de stap (Shift = 10 keer zo groot)
function Menu.step(index, direction)
    local st = Menu.state
    Menu.commitEdit()
    local m = st.vehicle.spec_loadAssist.modeList[index]
    local step = m.menuStep * (Menu.isShiftDown() and 10 or 1)
    local n = direction > 0 and math.floor(m.target / step + 1e-6) + 1 or math.ceil(m.target / step - 1e-6) - 1
    st.vehicle:setLoadAssistTarget(index, n * step)
end

-- Typen in het doelveld. Zonder firstChar staat de huidige waarde erin en vervangt de eerste toets die (fresh).
function Menu.startEdit(index, firstChar)
    local st = Menu.state
    local m = st.vehicle.spec_loadAssist.modeList[index]
    st.edit = { index = index, text = firstChar or string.format("%.1f", m.target), fresh = firstChar == nil }
    st.blink = 0
end

function Menu.commitEdit()
    local st = Menu.state
    local edit = st ~= nil and st.edit or nil
    if edit == nil then
        return
    end
    st.edit = nil
    local value = tonumber((string.gsub(edit.text, ",", ".")))
    if value ~= nil then
        st.vehicle:setLoadAssistTarget(edit.index, math.floor(value * 10 + 0.5) / 10)
    end
end

function Menu.select(index)
    local st = Menu.state
    st.vehicle.spec_loadAssist.selectedMode = index
    LoadAssist.updateActionTexts(st.vehicle)
end

function Menu.hitTest(x, y)
    local hits = Menu.state.hits
    for i = #hits, 1, -1 do
        local h = hits[i]
        if x >= h.x and x <= h.x + h.w and y >= h.y and y <= h.y + h.h then
            return h.id
        end
    end
    return nil
end

function Menu.click(id)
    local st = Menu.state
    local vehicle = st.vehicle
    local spec = vehicle.spec_loadAssist
    if id == nil then
        Menu.close() -- naast het paneel geklikt
        return
    end
    local kind, index = id.kind, id.index
    if st.edit ~= nil and not (kind == "field" and index == st.edit.index) then
        Menu.commitEdit()
    end
    if index ~= nil then
        Menu.select(index)
    end
    if kind == "close" then
        Menu.close()
        return
    elseif kind == "minus" or kind == "plus" then
        Menu.step(index, kind == "plus" and 1 or -1)
    elseif kind == "field" then
        Menu.startEdit(index)
    elseif kind == "reset" then
        vehicle:resetLoadAssistLoaded(index)
    elseif kind == "toggle" then
        vehicle:setLoadAssistModeEnabled(index, not spec.modeList[index].enabled)
    elseif kind == "sound" then
        vehicle:setLoadAssistSoundEnabled(not spec.soundEnabled)
    elseif kind == "test" then
        LoadAssist.playSound(spec.soundFile, spec.soundVolume)
        return
    else
        return -- paneel of kaart: alleen selecteren
    end
    Menu.playUiSound("CLICK")
end

function Menu:mouseEvent(posX, posY, isDown, isUp, button)
    local st = Menu.state
    if st == nil or (g_gui ~= nil and g_gui:getIsGuiVisible()) then
        return
    end
    local id = Menu.hitTest(posX * g_screenWidth, posY * g_screenHeight)
    st.hover = id
    if not isDown or st.time < Menu.INPUT_DELAY then
        return
    end
    if button == Input.MOUSE_BUTTON_LEFT then
        Menu.click(id)
    elseif button == Input.MOUSE_BUTTON_RIGHT and id ~= nil and id.kind == "field" then
        local m = st.vehicle.spec_loadAssist.modeList[id.index]
        st.edit = nil
        st.vehicle:setLoadAssistTarget(id.index, m.defaultTarget) -- terug naar de standaardwaarde
        Menu.playUiSound("CLICK")
    elseif (button == Input.MOUSE_BUTTON_WHEEL_UP or button == Input.MOUSE_BUTTON_WHEEL_DOWN) and id ~= nil and id.index ~= nil
        and id.kind ~= "toggle" and id.kind ~= "reset" then
        Menu.step(id.index, button == Input.MOUSE_BUTTON_WHEEL_UP and 1 or -1)
    end
end

function Menu:keyEvent(unicode, sym, modifier, isDown)
    local st = Menu.state
    if st == nil or not isDown or (g_gui ~= nil and g_gui:getIsGuiVisible()) then
        return
    end
    if Input.isKeyPressed(Input.KEY_lalt) or Input.isKeyPressed(Input.KEY_ralt) or Input.isKeyPressed(Input.KEY_lctrl)
        or Input.isKeyPressed(Input.KEY_rctrl) then
        return
    end
    local spec = st.vehicle.spec_loadAssist
    local char = (unicode ~= nil and unicode > 0) and unicodeToUtf8(unicode) or ""
    local isDigit, isSeparator = string.find(char, "^%d$") ~= nil, char == "." or char == ","
    local edit = st.edit

    if edit ~= nil then
        if isDigit or isSeparator then
            if edit.fresh then
                edit.text, edit.fresh = "", false
            end
            if not (isSeparator and string.find(edit.text, ".", 1, true)) and string.len(edit.text) < 7 then
                edit.text = edit.text .. (isSeparator and "." or char)
            end
        elseif sym == Input.KEY_backspace then
            edit.text = edit.fresh and "" or string.sub(edit.text, 1, -2)
            edit.fresh = false
        elseif sym == Input.KEY_tab then
            local nextIndex = edit.index % #spec.modeList + 1
            Menu.commitEdit()
            Menu.select(nextIndex)
            Menu.startEdit(nextIndex)
        end
        st.blink = 0
        return
    end

    if isDigit then
        Menu.startEdit(spec.selectedMode, char)
    elseif sym == Input.KEY_tab then
        Menu.startEdit(spec.selectedMode)
    elseif sym == Input.KEY_left or sym == Input.KEY_right then
        Menu.select(spec.selectedMode % #spec.modeList + 1)
    elseif sym == Input.KEY_up or sym == Input.KEY_down then
        Menu.step(spec.selectedMode, sym == Input.KEY_up and 1 or -1)
    end
end

-- =====================================================================================================================
-- MOD-LISTENER
-- =====================================================================================================================
function Menu:update(dt)
    if Menu.revertPending and g_inputBinding:getContextName() == Menu.CONTEXT then
        g_inputBinding:revertContext(true)
        Menu.revertPending = false
    end
    local st = Menu.state
    if st == nil then
        return
    end
    local vehicle = st.vehicle
    if vehicle.isDeleted or vehicle.spec_loadAssist == nil or not vehicle:getIsEntered() then
        Menu.close()
        return
    end
    st.time = st.time + dt
    st.blink = (st.blink + dt) % 1060
    local k = math.min(dt / 70, 1)
    for _, a in pairs(st.anims) do
        a.value = a.value + (a.target - a.value) * k
    end
end

function Menu:loadMap()
end

function Menu:deleteMap()
    if Menu.state ~= nil then
        Menu.close()
    end
    Menu.revertPending = false
    Menu.deleteAssets()
    LoadAssistScreen.deleteAssets()
    if LoadAssist ~= nil and LoadAssist.onMapUnloaded ~= nil then
        LoadAssist.onMapUnloaded()
    end
end

addModEventListener(Menu)
