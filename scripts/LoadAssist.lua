-- =====================================================================================================================
-- LoadAssist (FS25): weegsysteem voor wielladers en graafmachines.
--
-- Op het scherm in de cabine staan het gewicht in de bak, de bakhoek, de helling (voor/achter en links/rechts) en twee
-- tellers met een voortgangsbalk: Vrachtwagen en Opdracht. Elke keer dat de bak leeg gaat, telt het hoogste gewicht van
-- die lading mee bij de tellers die aan staan. Haalt een teller zijn doelgewicht, dan klinkt er een geluid.
-- Met Num / opent een menu (scripts/LoadAssistMenu.lua) om de doelgewichten in te stellen en de tellers te resetten.
--
-- Alle XML-attributen staan in docs/LoadAssist-documentatie.html.
-- =====================================================================================================================

LoadAssist = {}
LoadAssist.MOD_NAME = g_currentModName or "FS25_0_LoadAssist"
LoadAssist.MOD_DIR  = g_currentModDirectory or ""
LoadAssist.SPEC_KEY = string.format("spec_%s.loadAssist", LoadAssist.MOD_NAME)

LoadAssist.BOOT_TIME     = 3000  -- ms opstartscherm
LoadAssist.TARGET_MIN    = 0.5   -- t
LoadAssist.TARGET_MAX    = 9999  -- t
LoadAssist.KEY_STEP      = 2.5   -- t per toetsdruk (Alt+= / Alt+-)
LoadAssist.EMPTY_TONS    = 0.02  -- onder dit gewicht is de bak leeg
LoadAssist.MIN_LOAD_TONS = 0.05  -- lichtere ladingen tellen niet mee
LoadAssist.NUM_CHARS     = 10    -- tekens per 3D-tekstregel
LoadAssist.DEFAULT_MASS_PER_LITER = 0.0015
LoadAssist.IGNORED_FILLTYPES = { "DIESEL", "DEF", "AIR", "ELECTRICCHARGE", "METHANE" } -- eigen tanks van de machine
LoadAssist.DEFAULT_SOUND = "$data/sounds/ui/uiSuccess.ogg"

LoadAssist.GREY  = { 0.564, 0.564, 0.564, 1 }
LoadAssist.WHITE = { 1, 1, 1, 1 }
LoadAssist.GREEN = { 0.184, 0.533, 0.238, 1 }

-- De twee tellers. defaultTarget = doelgewicht als de xml niets zegt, menuStep = stap van - en + in het menu (t)
LoadAssist.MODES = {
    { name = "truck", title = "Vrachtwagen", defaultTarget = 25,  menuStep = 0.5 },
    { name = "job",   title = "Opdracht",    defaultTarget = 150, menuStep = 5 },
}

-- Draaiing van de bak op het scherm (graden "x y z") bij minAngle, 0 graden en maxAngle
LoadAssist.MINI_ROT = { min = "9.939 13.842 -7.729", zero = "0 0 0", max = "-15.584 3.224 54.053" }

local function exists(node)
    return node ~= nil and node ~= 0 and entityExists(node)
end

local function setVis(node, visible)
    if exists(node) then
        setVisibility(node, visible == true)
    end
end

-- "x y z" in graden -> { x, y, z } in radialen
local function parseRotation(str, fallback)
    local values = {}
    for s in string.gmatch(str or "", "%S+") do
        values[#values + 1] = math.rad(tonumber(s) or 0)
    end
    if #values == 3 then
        return values
    end
    return fallback ~= nil and parseRotation(fallback) or { 0, 0, 0 }
end

local function slopeText(value)
    return string.format("%s%.1f%%", value > 0.05 and "+" or "", value)
end

-- De teksten op het scherm: één lijst voor de 3D-letters en voor de reserve met renderText.
-- key = texts#<key>Node, size = deel van texts#fontSize (fixed = vaste grootte), get(spec) = tekst en kleur.
LoadAssist.TEXTS = {
    { key = "bucketWeight", desc = "gewicht in de bak", size = 0.015, fixed = true,
      get = function(spec) return string.format("%.2ft", spec.currentBucketTons), LoadAssist.GREY end },
    { key = "bucketAngle", desc = "bakhoek in graden", size = 0.01, fixed = true,
      get = function(spec) return string.format("%.0f", spec.bucketAngleDeg), LoadAssist.GREY end },
    { key = "frontBack", desc = "helling voor/achter in %", size = 0.75,
      get = function(spec) return slopeText(spec.slopeFrontBack), LoadAssist.WHITE end },
    { key = "leftRight", desc = "helling links/rechts in %", size = 0.75,
      get = function(spec) return slopeText(spec.slopeLeftRight), LoadAssist.WHITE end },
}
for _, def in ipairs(LoadAssist.MODES) do
    local name = def.name
    table.insert(LoadAssist.TEXTS, { key = name .. "Loaded", desc = "geladen " .. def.title, size = 0.85,
        get = function(spec)
            local m = spec.modes[name]
            return m.enabled and string.format("%.1ft", m.loaded) or "", LoadAssist.GREEN
        end })
    table.insert(LoadAssist.TEXTS, { key = name .. "Target", desc = "doelgewicht " .. def.title, size = 0.85,
        get = function(spec)
            local m = spec.modes[name]
            return m.enabled and string.format("-%.1ft", m.target) or "UIT", LoadAssist.WHITE
        end })
end

-- XML onder vehicle.loadAssist: pad, type, beschrijving, standaardwaarde. De oude plekken blijven werken.
LoadAssist.XML_PATHS = {
    { "#offScreenNode",                "NODE_INDEX", "Scherm uit" },
    { "#bootScreenNode",               "NODE_INDEX", "Opstartscherm" },
    { "#mainScreenNode",               "NODE_INDEX", "Hoofdscherm" },
    { "#slopeRefNode",                 "NODE_INDEX", "Referentie voor de helling (oude plek)" },
    { ".nodes#groundReferenceNode",    "NODE_INDEX", "Referentiepunt onderaan de machine" },
    { ".nodes#slopeReferenceNode",     "NODE_INDEX", "Referentie voor de helling" },
    { ".nodes#slopeRefNode",           "NODE_INDEX", "Referentie voor de helling (korte naam)" },
    { ".realParts#bucketNode",         "NODE_INDEX", "Echte bak of snelwissel" },
    { ".realParts#angleOffset",        "FLOAT",      "Correctie op de bakhoek in graden" },
    { ".parts#realBucketNode",         "NODE_INDEX", "Echte bak (oude plek)" },
    { ".parts#angleOffset",            "FLOAT",      "Correctie op de bakhoek (oude plek)" },
    { ".parts#miniBucketNode",         "NODE_INDEX", "Bak op het scherm (oude plek)" },
    { ".screenParts#miniBucketNode",   "NODE_INDEX", "Bak op het scherm" },
    { ".screenParts#miniBucketInvert", "BOOL",       "Draairichting van de schermbak omkeren", false },
    { ".screenParts#minAngle",         "FLOAT",      "Bakhoek in graden waarbij minRot bereikt is", -45 },
    { ".screenParts#maxAngle",         "FLOAT",      "Bakhoek in graden waarbij maxRot bereikt is", 55 },
    { ".screenParts#minRot",           "STRING",     "Draaiing van de schermbak bij minAngle (graden x y z)", LoadAssist.MINI_ROT.min },
    { ".screenParts#zeroRot",          "STRING",     "Draaiing van de schermbak bij 0 graden", LoadAssist.MINI_ROT.zero },
    { ".screenParts#maxRot",           "STRING",     "Draaiing van de schermbak bij maxAngle", LoadAssist.MINI_ROT.max },
    { ".texts#fontName",               "STRING",     "Lettertype, bijvoorbeeld HANDELGOTHIC" },
    { ".texts#fontSize",               "FLOAT",      "Tekstgrootte", 0.012 },
    { ".texts#fontThickness",          "FLOAT",      "Letterdikte", 1 },
    { ".sound#file",                   "STRING",     "Geluid als een doelgewicht gehaald is", LoadAssist.DEFAULT_SOUND },
    { ".sound#volume",                 "FLOAT",      "Volume van dat geluid", 1 },
}

function LoadAssist.prerequisitesPresent(specializations)
    return SpecializationUtil.hasSpecialization(Motorized, specializations)
       and SpecializationUtil.hasSpecialization(Enterable, specializations)
end

function LoadAssist.initSpecialization()
    local schema, base = Vehicle.xmlSchema, "vehicle.loadAssist"
    schema:setXMLSpecializationType("LoadAssist")
    for _, p in ipairs(LoadAssist.XML_PATHS) do
        schema:register(XMLValueType[p[2]], base .. p[1], p[3], p[4])
    end
    for _, t in ipairs(LoadAssist.TEXTS) do
        schema:register(XMLValueType.NODE_INDEX, base .. ".texts#" .. t.key .. "Node", "3D-tekst: " .. t.desc)
    end
    for _, m in ipairs(LoadAssist.MODES) do
        schema:register(XMLValueType.NODE_INDEX, base .. ".bars#" .. m.name .. "BarNode", "Voortgangsbalk " .. m.title)
        schema:register(XMLValueType.NODE_INDEX, base .. ".bars#" .. m.name .. "GroupNode", "Groep achter de balk " .. m.title)
        schema:register(XMLValueType.FLOAT, base .. ".bars#" .. m.name .. "Target", "Doelgewicht " .. m.title .. " in ton", m.defaultTarget)
    end
    schema:setXMLSpecializationType()

    local save = Vehicle.xmlSchemaSavegame
    local key = string.format("vehicles.vehicle(?).%s.loadAssist", LoadAssist.MOD_NAME)
    for _, m in ipairs(LoadAssist.MODES) do
        save:register(XMLValueType.FLOAT, key .. "#" .. m.name .. "Target", "Doelgewicht " .. m.title)
        save:register(XMLValueType.FLOAT, key .. "#" .. m.name .. "Loaded", "Geladen " .. m.title)
        save:register(XMLValueType.BOOL, key .. "#" .. m.name .. "Enabled", m.title .. " aan")
    end
    save:register(XMLValueType.BOOL, key .. "#sound", "Geluid als een doel gehaald is")
end

function LoadAssist.registerFunctions(vehicleType)
    -- Voor het menu en andere scripts; de rest wordt intern aangeroepen als LoadAssist.functie(self)
    for _, name in ipairs({ "setLoadAssistTarget", "resetLoadAssistLoaded", "setLoadAssistModeEnabled", "setLoadAssistSoundEnabled" }) do
        SpecializationUtil.registerFunction(vehicleType, name, LoadAssist[name])
    end
end

function LoadAssist.registerEventListeners(vehicleType)
    for _, name in ipairs({ "onLoad", "onDelete", "onUpdate", "onDraw", "onStartMotor", "onStopMotor", "onLeaveVehicle", "onRegisterActionEvents" }) do
        SpecializationUtil.registerEventListener(vehicleType, name, LoadAssist)
    end
end

function LoadAssist:onLoad(savegame)
    if self[LoadAssist.SPEC_KEY] == nil then
        self[LoadAssist.SPEC_KEY] = {}
    end
    self.spec_loadAssist = self[LoadAssist.SPEC_KEY]
    local spec = self.spec_loadAssist
    local xmlFile, base = self.xmlFile, "vehicle.loadAssist"
    local function node(path)
        return xmlFile:getValue(base .. path, nil, self.components, self.i3dMappings)
    end
    local function value(path, default)
        return xmlFile:getValue(base .. path, default)
    end

    spec.actionEvents, spec.actionEventIds = {}, {}
    spec.offScreenNode  = node("#offScreenNode")
    spec.bootScreenNode = node("#bootScreenNode")
    spec.mainScreenNode = node("#mainScreenNode")
    spec.groundRefNode  = node(".nodes#groundReferenceNode")
    spec.slopeRefNode   = node(".nodes#slopeRefNode") or node(".nodes#slopeReferenceNode") or node("#slopeRefNode")
                          or spec.groundRefNode or self.rootNode

    -- Bak + bak op het scherm
    spec.realBucket        = node(".realParts#bucketNode") or node(".parts#realBucketNode")
    spec.bucketAngleOffset = value(".realParts#angleOffset") or value(".parts#angleOffset") or 0
    spec.miniBucket        = node(".screenParts#miniBucketNode") or node(".parts#miniBucketNode")
    spec.miniBucketDir     = value(".screenParts#miniBucketInvert", false) and -1 or 1
    spec.miniMinAngle      = value(".screenParts#minAngle", -45)
    spec.miniMaxAngle      = value(".screenParts#maxAngle", 55)
    spec.miniRot = {}
    for k, default in pairs(LoadAssist.MINI_ROT) do
        spec.miniRot[k] = parseRotation(value(".screenParts#" .. k .. "Rot", default), default)
    end
    spec.bucketTrackAxis    = nil
    spec.bucketBasePitchRad = LoadAssist.getRawBucketPitchRad(self) -- beginstand van de bak = 0 graden

    -- Tellers
    spec.modes, spec.modeList, spec.selectedMode = {}, {}, 1
    for i, def in ipairs(LoadAssist.MODES) do
        local m = {
            index = i, name = def.name, title = def.title, menuStep = def.menuStep,
            barNode = node(".bars#" .. def.name .. "BarNode"), groupNode = node(".bars#" .. def.name .. "GroupNode"),
            target = math.clamp(value(".bars#" .. def.name .. "Target", def.defaultTarget), LoadAssist.TARGET_MIN, LoadAssist.TARGET_MAX),
            loaded = 0, enabled = true, targetReached = false,
        }
        m.defaultTarget = m.target
        m.barScale = exists(m.barNode) and { getScale(m.barNode) } or { 1, 1, 1 }
        spec.modes[def.name], spec.modeList[i] = m, m
    end

    -- Teksten
    spec.texts = {}
    local fontSize = value(".texts#fontSize", 0.012)
    for _, def in ipairs(LoadAssist.TEXTS) do
        local textNode = node(".texts#" .. def.key .. "Node")
        if exists(textNode) then
            table.insert(spec.texts, { node = textNode, get = def.get, size = def.fixed and def.size or fontSize * def.size })
        end
    end
    spec.fontName      = value(".texts#fontName")
    spec.fontThickness = value(".texts#fontThickness", 1)
    spec.useCustomFont = false

    -- Geluid als een doel gehaald is
    spec.soundFile    = Utils.getFilename(value(".sound#file", LoadAssist.DEFAULT_SOUND), self.baseDirectory)
    spec.soundVolume  = value(".sound#volume", 1)
    spec.soundEnabled = true

    spec.currentBucketTons, spec.peakBucketTons = 0, 0
    spec.bucketAngleDeg, spec.slopeFrontBack, spec.slopeLeftRight = 0, 0, 0

    if savegame ~= nil and not savegame.resetVehicles then
        local key = savegame.key .. "." .. LoadAssist.MOD_NAME .. ".loadAssist"
        local saved = savegame.xmlFile
        for _, m in ipairs(spec.modeList) do
            m.target  = math.clamp(saved:getValue(key .. "#" .. m.name .. "Target", m.target), LoadAssist.TARGET_MIN, LoadAssist.TARGET_MAX)
            m.loaded  = math.max(saved:getValue(key .. "#" .. m.name .. "Loaded", 0), 0)
            m.enabled = saved:getValue(key .. "#" .. m.name .. "Enabled", true)
        end
        spec.soundEnabled = saved:getValue(key .. "#sound", true)
    end
    LoadAssist.checkTargets(self, false)

    if self.isClient and spec.fontName ~= nil and spec.fontName ~= "" and #spec.texts > 0 then
        LoadAssist.loadFonts()
        LoadAssist.setupFontLines(self, 0)
    end
    LoadAssist.setScreenState(self, "off")
end

function LoadAssist:onDelete()
    if LoadAssistMenu ~= nil then
        LoadAssistMenu.onVehicleGone(self)
    end
end

function LoadAssist:saveToXMLFile(xmlFile, key)
    local spec = self.spec_loadAssist
    if spec == nil or spec.modeList == nil then
        return
    end
    for _, m in ipairs(spec.modeList) do
        xmlFile:setValue(key .. "#" .. m.name .. "Target", m.target)
        xmlFile:setValue(key .. "#" .. m.name .. "Loaded", m.loaded)
        xmlFile:setValue(key .. "#" .. m.name .. "Enabled", m.enabled)
    end
    xmlFile:setValue(key .. "#sound", spec.soundEnabled)
end

-- =====================================================================================================================
-- LETTERTYPEN: fonts/customFonts.xml één keer per kaart laden. Ze heten daarna "<modnaam>.<naam>", bijvoorbeeld
-- FS25_0_LoadAssist.HANDELGOTHIC. De MaterialManager ruimt ze op als de kaart sluit (LoadAssist.onMapUnloaded).
-- =====================================================================================================================
function LoadAssist.loadFonts()
    if LoadAssist.fontState ~= nil then
        return
    end
    LoadAssist.fontState = "done"
    local path = LoadAssist.MOD_DIR .. "fonts/customFonts.xml"
    if g_materialManager == nil or FontMaterial == nil or MaterialManager.fontMaterialXMLSchema == nil or not fileExists(path) then
        return
    end
    local xmlFile = XMLFile.load("loadAssistFonts", path, MaterialManager.fontMaterialXMLSchema)
    if xmlFile == nil then
        return
    end
    local generation, pending = LoadAssist.fontGeneration or 0, 1 -- 1 = het bestand zelf, tot alle fonts gestart zijn
    local function finished()
        pending = pending - 1
        if pending == 0 then
            xmlFile:delete()
            if generation == (LoadAssist.fontGeneration or 0) then
                LoadAssist.fontState = "done"
            end
        end
    end
    LoadAssist.fontState = "loading"
    xmlFile:iterate("fonts.font", function(_, key)
        pending = pending + 1
        local font = FontMaterial.new()
        font:loadFromXML(xmlFile, key, LoadAssist.MOD_NAME, LoadAssist.MOD_DIR, function(success)
            if success and generation == (LoadAssist.fontGeneration or 0) then
                table.insert(g_materialManager.fontMaterials, font)
                g_materialManager.fontMaterialsByName[font.name] = font
            end
            finished()
        end)
    end)
    finished()
end

local function isUsableFont(font)
    return font ~= nil and font.characterShape ~= nil and font.characters ~= nil and #font.characters > 0
end

-- Eerst het lettertype van deze mod, dan dat van de voertuigmod of het spel (bijvoorbeeld GENERIC_BOLD)
function LoadAssist.findFont(self)
    local name, mm = self.spec_loadAssist.fontName, g_materialManager
    local byName = mm.fontMaterialsByName or {}
    local candidates = {
        byName[LoadAssist.MOD_NAME .. "." .. name], byName[LoadAssist.MOD_NAME .. "." .. string.upper(name)],
        mm:getFontMaterial(name, self.customEnvironment), byName[string.upper(name)],
    }
    for i = 1, 4 do
        if isUsableFont(candidates[i]) then
            return candidates[i]
        end
    end
    Logging.xmlWarning(self.xmlFile, "LoadAssist: lettertype '%s' niet gevonden, valt terug op GENERIC.", name)
    local generic = mm:getFontMaterial("GENERIC", self.customEnvironment)
    return isUsableFont(generic) and generic or nil
end

function LoadAssist.setupFontLines(self, dt)
    local spec = self.spec_loadAssist
    spec.fontPending = false
    if LoadAssist.fontState == "loading" then
        spec.fontWait = (spec.fontWait or 0) + dt
        if spec.fontWait < 10000 then
            spec.fontPending = true -- opnieuw proberen in onUpdate
            return
        end
    end
    local font = LoadAssist.findFont(self)
    if font == nil then
        return
    end
    for _, t in ipairs(spec.texts) do
        t.line = CharacterLine.new(t.node, font, LoadAssist.NUM_CHARS)
        t.line:setSizeAndScale(t.size, 1, 1)
        t.line:setTextAlignment(RenderText.ALIGN_CENTER)
        t.line:setFontThickness(spec.fontThickness)
        t.shownText, t.shownColor = nil, nil
        setVis(t.node, spec.screenState == "main")
    end
    spec.useCustomFont = true
end

-- Rechts aanvullen met spaties (de helft van de lege plekken), zodat de teksten op hun vertrouwde plek staan
function LoadAssist.padText(text)
    local len = utf8Strlen(text)
    if len > 0 and len < LoadAssist.NUM_CHARS then
        text = text .. string.rep(" ", math.floor((LoadAssist.NUM_CHARS - len) / 2))
    end
    return text
end

function LoadAssist.updateTexts(self)
    local spec = self.spec_loadAssist
    if not spec.useCustomFont then
        return
    end
    for _, t in ipairs(spec.texts) do
        local text, color = t.get(spec)
        if color ~= t.shownColor then
            t.shownColor = color
            t.line:setColor(color, nil, 0)
        end
        if text ~= t.shownText then
            t.shownText = text
            t.line:setText(LoadAssist.padText(text))
        end
    end
end

-- =====================================================================================================================
-- SCHERM: "off", "boot" (3 s) of "main"
-- =====================================================================================================================
function LoadAssist.setScreenState(self, state)
    local spec = self.spec_loadAssist
    local main = state == "main"
    spec.screenState, spec.bootTimer = state, LoadAssist.BOOT_TIME
    setVis(spec.offScreenNode, state == "off")
    setVis(spec.bootScreenNode, state == "boot")
    setVis(spec.mainScreenNode, main)
    setVis(spec.miniBucket, main)
    if spec.useCustomFont then
        for _, t in ipairs(spec.texts) do
            setVis(t.node, main)
        end
    end
    LoadAssist.updateProgressBars(self)
end

function LoadAssist.updateProgressBars(self)
    local spec = self.spec_loadAssist
    local main = spec.screenState == "main"
    for _, m in ipairs(spec.modeList) do
        setVis(m.groupNode, main and m.enabled)
        if exists(m.barNode) then
            local pct = (main and m.enabled) and math.clamp(m.loaded / m.target, 0, 1) or 0
            setVisibility(m.barNode, pct > 0.001)
            if pct > 0.001 then
                setScale(m.barNode, math.max(m.barScale[1] * pct, 0.0001), m.barScale[2], m.barScale[3])
            end
        end
    end
end

function LoadAssist:onStartMotor()
    LoadAssist.setScreenState(self, "boot")
end

function LoadAssist:onStopMotor()
    LoadAssist.setScreenState(self, "off")
end

function LoadAssist:onLeaveVehicle()
    if not self:getIsMotorStarted() then
        LoadAssist.setScreenState(self, "off")
    end
    if LoadAssistMenu ~= nil then
        LoadAssistMenu.onVehicleGone(self)
    end
end

function LoadAssist:onUpdate(dt)
    if not self.isClient then
        return
    end
    local spec = self.spec_loadAssist
    if spec.fontPending then
        LoadAssist.setupFontLines(self, dt)
    end

    local motorOn = self:getIsMotorStarted()
    if spec.screenState == "off" then
        if not motorOn then
            return
        end
        LoadAssist.setScreenState(self, "boot")
    end
    if spec.screenState == "boot" then
        spec.bootTimer = spec.bootTimer - dt
        if spec.bootTimer > 0 then
            return
        end
        LoadAssist.setScreenState(self, "main")
    elseif not motorOn then
        LoadAssist.setScreenState(self, "off")
        return
    end

    LoadAssist.updateSlope(self)
    LoadAssist.updateBucketAngle(self)
    LoadAssist.updateBucketWeightAndTotals(self)
    LoadAssist.updateProgressBars(self)
    LoadAssist.updateTexts(self)
end

-- =====================================================================================================================
-- METEN
-- =====================================================================================================================
local function slopePercent(node, dx, dz)
    local x, y, z = localDirectionToWorld(node, dx, 0, dz)
    local horizontal = math.sqrt(x * x + z * z)
    local pct = horizontal > 0.0001 and (y / horizontal) * 100 or 0
    return math.abs(pct) < 0.05 and 0 or math.clamp(pct, -99.9, 99.9)
end

function LoadAssist.updateSlope(self)
    local spec = self.spec_loadAssist
    local ref = exists(spec.slopeRefNode) and spec.slopeRefNode or self.rootNode
    if exists(ref) then
        spec.slopeFrontBack = slopePercent(ref, 0, 1)
        spec.slopeLeftRight = slopePercent(ref, 1, 0)
    end
end

-- Kanteling van de bak ten opzichte van het voorframe (component 2 van een knikmachine), in radialen. De as van de
-- bak die het meest in het vlak van kantelen ligt, wordt één keer gekozen.
local BUCKET_AXES = { { 0, 1, 0 }, { 0, 0, 1 }, { 1, 0, 0 } }
function LoadAssist.getRawBucketPitchRad(self)
    local spec = self.spec_loadAssist
    local bucket = spec.realBucket
    local ref = self.components ~= nil and self.components[2] ~= nil and self.components[2].node or self.rootNode
    if not exists(ref) then
        ref = spec.groundRefNode or spec.slopeRefNode
    end
    if not exists(bucket) or not exists(ref) then
        return 0
    end
    local function project(axis)
        local wx, wy, wz = localDirectionToWorld(bucket, axis[1], axis[2], axis[3])
        local _, ly, lz = worldDirectionToLocal(ref, wx, wy, wz)
        return ly, lz
    end
    if spec.bucketTrackAxis == nil then
        local best = -1
        for i, axis in ipairs(BUCKET_AXES) do
            local ly, lz = project(axis)
            if ly * ly + lz * lz > best then
                best, spec.bucketTrackAxis = ly * ly + lz * lz, i
            end
        end
    end
    local ly, lz = project(BUCKET_AXES[spec.bucketTrackAxis])
    if math.abs(ly) < 0.0001 and math.abs(lz) < 0.0001 then
        return 0
    end
    return math.atan2(lz, ly)
end

-- Bakhoek in graden (met angleOffset) en de bak op het scherm: tussen zeroRot en minRot/maxRot over alle drie de assen
function LoadAssist.updateBucketAngle(self)
    local spec = self.spec_loadAssist
    if not exists(spec.realBucket) then
        return
    end
    local delta = (LoadAssist.getRawBucketPitchRad(self) - spec.bucketBasePitchRad) * spec.miniBucketDir
    delta = (delta + math.pi) % (2 * math.pi) - math.pi
    local angle = math.deg(delta) + spec.bucketAngleOffset
    if math.abs(angle) < 0.5 then
        angle = 0
    end
    spec.bucketAngleDeg = math.clamp(angle, -180, 180)

    if exists(spec.miniBucket) then
        local zero, limit, to = spec.miniRot.zero, spec.miniMaxAngle, spec.miniRot.max
        if spec.bucketAngleDeg < 0 then
            limit, to = spec.miniMinAngle, spec.miniRot.min
        end
        local t = math.clamp(math.abs(spec.bucketAngleDeg) / math.max(math.abs(limit), 1), 0, 1)
        setRotation(spec.miniBucket, zero[1] + (to[1] - zero[1]) * t, zero[2] + (to[2] - zero[2]) * t, zero[3] + (to[3] - zero[3]) * t)
    end
end

function LoadAssist.getIgnoredFillTypes()
    if LoadAssist.ignoredFillTypes == nil then
        LoadAssist.ignoredFillTypes = {}
        for _, name in ipairs(LoadAssist.IGNORED_FILLTYPES) do
            if FillType[name] ~= nil then
                LoadAssist.ignoredFillTypes[FillType[name]] = true
            end
        end
    end
    return LoadAssist.ignoredFillTypes
end

-- Gewicht (t) in de machine zelf (zonder diesel, AdBlue, lucht, stroom en methaan) en in alles wat eraan hangt (de bak)
function LoadAssist.getCurrentBucketMassTons(self)
    local ignored = LoadAssist.getIgnoredFillTypes()
    local function massOf(vehicle, skipOwnTanks)
        local tons, fillUnits = 0, vehicle.spec_fillUnit ~= nil and vehicle.spec_fillUnit.fillUnits or {}
        for _, unit in ipairs(fillUnits) do
            if (unit.fillLevel or 0) > 0 and unit.fillType ~= nil and not (skipOwnTanks and ignored[unit.fillType]) then
                local fillType = g_fillTypeManager:getFillTypeByIndex(unit.fillType)
                local massPerLiter = fillType ~= nil and fillType.massPerLiter or 0
                tons = tons + unit.fillLevel * (massPerLiter > 0 and massPerLiter or LoadAssist.DEFAULT_MASS_PER_LITER)
            end
        end
        return tons
    end
    local total = massOf(self, true)
    for _, child in ipairs(self.getChildVehicles ~= nil and self:getChildVehicles() or {}) do
        if child ~= self then
            total = total + massOf(child, false)
        end
    end
    return total
end

-- Het hoogste gewicht van een lading telt mee zodra de bak weer leeg is
function LoadAssist.updateBucketWeightAndTotals(self)
    local spec = self.spec_loadAssist
    local tons = LoadAssist.getCurrentBucketMassTons(self)
    spec.currentBucketTons = tons
    if tons > spec.peakBucketTons then
        spec.peakBucketTons = tons
    elseif tons <= LoadAssist.EMPTY_TONS and spec.peakBucketTons >= LoadAssist.MIN_LOAD_TONS then
        for _, m in ipairs(spec.modeList) do
            if m.enabled then
                m.loaded = m.loaded + spec.peakBucketTons
            end
        end
        spec.peakBucketTons = 0
        LoadAssist.checkTargets(self, true)
    end
end

-- =====================================================================================================================
-- DOELGEWICHT GEHAALD: één keer geluid (en een melding) per keer dat een teller over zijn doel gaat
-- =====================================================================================================================
function LoadAssist.checkTargets(self, announce)
    local spec = self.spec_loadAssist
    for _, m in ipairs(spec.modeList) do
        local reached = m.enabled and m.loaded >= m.target - 0.001
        if reached and not m.targetReached and announce then
            LoadAssist.announceTarget(self, m)
        end
        m.targetReached = reached
    end
end

function LoadAssist.announceTarget(self, m)
    local spec = self.spec_loadAssist
    if not self:getIsEntered() then
        return
    end
    if spec.soundEnabled then
        LoadAssist.playSound(spec.soundFile, spec.soundVolume)
    end
    if g_currentMission ~= nil and g_currentMission.addIngameNotification ~= nil then
        g_currentMission:addIngameNotification(FSBaseMission.INGAME_NOTIFICATION_OK,
            string.format("Load Assist: %s doel gehaald (%.1f t)", m.title, m.loaded))
    end
end

function LoadAssist.playSound(file, volume)
    LoadAssist.samples = LoadAssist.samples or {}
    local sample = LoadAssist.samples[file]
    if sample == nil then
        sample = createSample("loadAssistTarget")
        if sample ~= 0 and loadSample(sample, file, false) then
            setSampleGroup(sample, AudioGroup.GUI)
        else
            Logging.warning("LoadAssist: geluid '%s' kon niet worden geladen.", tostring(file))
            if sample ~= 0 then
                delete(sample)
            end
            sample = false
        end
        LoadAssist.samples[file] = sample
    end
    if sample then
        playSample(sample, 1, volume or 1, 0, 0, 0)
    end
end

-- Kaart dicht: lettertypen zijn door de MaterialManager opgeruimd, geluiden en vultype-nummers opnieuw ophalen
function LoadAssist.onMapUnloaded()
    for _, sample in pairs(LoadAssist.samples or {}) do
        if sample then
            delete(sample)
        end
    end
    LoadAssist.samples = nil
    LoadAssist.fontState = nil
    LoadAssist.fontGeneration = (LoadAssist.fontGeneration or 0) + 1
    LoadAssist.ignoredFillTypes = nil
end

-- =====================================================================================================================
-- INSTELLEN (toetsen en menu gebruiken dezelfde functies)
-- =====================================================================================================================
function LoadAssist:setLoadAssistTarget(index, tons)
    local m = self.spec_loadAssist.modeList[index]
    m.target = math.clamp(tons, LoadAssist.TARGET_MIN, LoadAssist.TARGET_MAX)
    LoadAssist.refresh(self)
end

function LoadAssist:resetLoadAssistLoaded(index)
    self.spec_loadAssist.modeList[index].loaded = 0
    LoadAssist.refresh(self)
end

function LoadAssist:setLoadAssistModeEnabled(index, enabled)
    self.spec_loadAssist.modeList[index].enabled = enabled
    LoadAssist.refresh(self)
end

function LoadAssist:setLoadAssistSoundEnabled(enabled)
    self.spec_loadAssist.soundEnabled = enabled
end

function LoadAssist.refresh(self)
    LoadAssist.checkTargets(self, false)
    LoadAssist.updateProgressBars(self)
    LoadAssist.updateActionTexts(self)
    if self.spec_loadAssist.screenState == "main" then
        LoadAssist.updateTexts(self)
    end
end

-- =====================================================================================================================
-- TOETSEN
-- =====================================================================================================================
LoadAssist.ACTIONS = {
    { action = "LOAD_ASSIST_MENU",   callback = "actionEventMenu",         top = true },
    { action = "LOAD_ASSIST_SELECT", callback = "actionEventSelectMode",   top = true },
    { action = "LOAD_ASSIST_TOGGLE", callback = "actionEventToggleMode" },
    { action = "LOAD_ASSIST_ADD",    callback = "actionEventChangeTarget", state = 1 },
    { action = "LOAD_ASSIST_REMOVE", callback = "actionEventChangeTarget", state = -1 },
    { action = "LOAD_ASSIST_RESET",  callback = "actionEventResetLoaded" },
}

function LoadAssist:onRegisterActionEvents(isActiveForInput, isActiveForInputIgnoreSelection)
    if not self.isClient then
        return
    end
    local spec = self.spec_loadAssist
    self:clearActionEventsTable(spec.actionEvents)
    spec.actionEventIds = {}
    if not isActiveForInputIgnoreSelection then
        return
    end
    for _, a in ipairs(LoadAssist.ACTIONS) do
        if InputAction[a.action] ~= nil then
            local _, id = self:addActionEvent(spec.actionEvents, InputAction[a.action], self, LoadAssist[a.callback], false, true, false, true, a.state)
            if id ~= nil then
                spec.actionEventIds[a.action] = id
                g_inputBinding:setActionEventTextPriority(id, a.top and GS_PRIO_VERY_HIGH or GS_PRIO_HIGH)
                g_inputBinding:setActionEventTextVisibility(id, true)
            end
        end
    end
    LoadAssist.updateActionTexts(self)
end

function LoadAssist.updateActionTexts(self)
    local spec = self.spec_loadAssist
    local m = spec.modeList[spec.selectedMode]
    local texts = {
        LOAD_ASSIST_MENU   = "Load Assist: Doelgewicht instellen",
        LOAD_ASSIST_SELECT = string.format("Load Assist: Geselecteerd [%s]", m.title),
        LOAD_ASSIST_TOGGLE = string.format("Load Assist: %s [%s]", m.title, m.enabled and "AAN" or "UIT"),
        LOAD_ASSIST_ADD    = string.format("Load Assist: %s doel +%.1ft", m.title, LoadAssist.KEY_STEP),
        LOAD_ASSIST_REMOVE = string.format("Load Assist: %s doel -%.1ft", m.title, LoadAssist.KEY_STEP),
        LOAD_ASSIST_RESET  = string.format("Load Assist: Reset %s (0.0t)", m.title),
    }
    for action, id in pairs(spec.actionEventIds) do
        g_inputBinding:setActionEventText(id, texts[action])
    end
end

function LoadAssist.actionEventMenu(self)
    if LoadAssistMenu ~= nil then
        LoadAssistMenu.toggle(self)
    end
end

function LoadAssist.actionEventSelectMode(self)
    local spec = self.spec_loadAssist
    spec.selectedMode = spec.selectedMode % #spec.modeList + 1
    LoadAssist.updateActionTexts(self)
end

function LoadAssist.actionEventToggleMode(self)
    local spec = self.spec_loadAssist
    self:setLoadAssistModeEnabled(spec.selectedMode, not spec.modeList[spec.selectedMode].enabled)
end

function LoadAssist.actionEventChangeTarget(self, actionName, inputValue, direction)
    local spec = self.spec_loadAssist
    self:setLoadAssistTarget(spec.selectedMode, spec.modeList[spec.selectedMode].target + (direction or 0) * LoadAssist.KEY_STEP)
end

function LoadAssist.actionEventResetLoaded(self)
    self:resetLoadAssistLoaded(self.spec_loadAssist.selectedMode)
end

-- =====================================================================================================================
-- RESERVE ZONDER LETTERTYPE: de teksten met renderText op de plek van de tekst-nodes
-- =====================================================================================================================
function LoadAssist:onDraw()
    local spec = self.spec_loadAssist
    if spec.useCustomFont or spec.screenState ~= "main" or #spec.texts == 0 or not self:getIsEntered() then
        return
    end
    for _, t in ipairs(spec.texts) do
        local text, color = t.get(spec)
        LoadAssist.drawSharpScreenText(t.node, text, t.size, color)
    end
    setTextAlignment(RenderText.ALIGN_LEFT)
    setTextVerticalAlignment(RenderText.VERTICAL_ALIGN_BASELINE)
    setTextBold(false)
    setTextColor(1, 1, 1, 1)
end

function LoadAssist.drawSharpScreenText(node, text, size3D, color)
    if text == "" or not exists(node) then
        return
    end
    local x, y, z = getWorldTranslation(node)
    setTextAlignment(RenderText.ALIGN_CENTER)
    setTextVerticalAlignment(RenderText.VERTICAL_ALIGN_MIDDLE)
    setTextBold(true)
    setTextColor(color[1], color[2], color[3], 1)
    local sx, sy, sz = project(x, y, z)
    if sx ~= nil and sz > 0 and sz < 1 and sx > 0.01 and sx < 0.99 and sy > 0.01 and sy < 0.99 then
        local dist, camera = 0.7, getCamera()
        if exists(camera) then
            local cx, cy, cz = getWorldTranslation(camera)
            dist = math.max(math.sqrt((x - cx) ^ 2 + (y - cy) ^ 2 + (z - cz) ^ 2), 0.2)
        end
        renderText(sx, sy, math.clamp(size3D / dist * 1.15, 0.008, 0.045), text)
    else
        local rx, ry, rz = getWorldRotation(node)
        renderText3D(x, y, z, rx, ry, rz, size3D, text)
    end
end

ExcavatorLoadAssist = LoadAssist
