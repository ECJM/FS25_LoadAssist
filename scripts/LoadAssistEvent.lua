-- =====================================================================================================================
-- LoadAssistEvent: de instellingen van LoadAssist in multiplayer (doelgewicht, reset, teller aan/uit, geluid aan/uit).
--
-- Wie iets verandert met de toetsen of in het menu, voert het meteen zelf uit en stuurt dit event: een speler naar de
-- server, de server naar alle andere spelers. Zo heeft iedereen dezelfde waarden en bewaart de server ze in de
-- savegame. De tellers zelf telt de server; die gaan met de update-stream mee (LoadAssist:onWriteUpdateStream).
-- =====================================================================================================================

LoadAssistEvent = {}
local LoadAssistEvent_mt = Class(LoadAssistEvent, Event)
InitEventClass(LoadAssistEvent, "LoadAssistEvent")

LoadAssistEvent.TARGET  = 1 -- doelgewicht van een teller (ton)
LoadAssistEvent.RESET   = 2 -- teller op 0
LoadAssistEvent.ENABLED = 3 -- teller aan of uit
LoadAssistEvent.SOUND   = 4 -- geluid bij doel aan of uit
LoadAssistEvent.SEND_NUM_BITS = 3 -- voor het soort en het nummer van de teller

function LoadAssistEvent.emptyNew()
    return Event.new(LoadAssistEvent_mt)
end

-- kind = een van de soorten hierboven, index = nummer van de teller (0 bij het geluid), value = ton of aan/uit
function LoadAssistEvent.new(vehicle, kind, index, value)
    local self = LoadAssistEvent.emptyNew()
    self.vehicle, self.kind, self.index, self.value = vehicle, kind, index or 0, value
    return self
end

function LoadAssistEvent:writeStream(streamId, connection)
    NetworkUtil.writeNodeObject(streamId, self.vehicle)
    streamWriteUIntN(streamId, self.kind, LoadAssistEvent.SEND_NUM_BITS)
    streamWriteUIntN(streamId, self.index, LoadAssistEvent.SEND_NUM_BITS)
    if self.kind == LoadAssistEvent.TARGET then
        LoadAssist.writeTons(streamId, self.value)
    elseif self.kind == LoadAssistEvent.ENABLED or self.kind == LoadAssistEvent.SOUND then
        streamWriteBool(streamId, self.value == true)
    end
end

function LoadAssistEvent:readStream(streamId, connection)
    self.vehicle = NetworkUtil.readNodeObject(streamId)
    self.kind = streamReadUIntN(streamId, LoadAssistEvent.SEND_NUM_BITS)
    self.index = streamReadUIntN(streamId, LoadAssistEvent.SEND_NUM_BITS)
    if self.kind == LoadAssistEvent.TARGET then
        self.value = LoadAssist.readTons(streamId)
    elseif self.kind == LoadAssistEvent.ENABLED or self.kind == LoadAssistEvent.SOUND then
        self.value = streamReadBool(streamId)
    end
    self:run(connection)
end

function LoadAssistEvent:run(connection)
    local vehicle = self.vehicle
    if vehicle == nil or vehicle.spec_loadAssist == nil then
        return
    end
    if not connection:getIsServer() then
        g_server:broadcastEvent(self, false, connection, vehicle) -- van een speler: door naar de andere spelers
    end
    if vehicle:getIsSynchronized() then
        LoadAssistEvent.apply(vehicle, self.kind, self.index, self.value)
    end
end

-- Uitvoeren zonder het event opnieuw te sturen
function LoadAssistEvent.apply(vehicle, kind, index, value)
    if kind == LoadAssistEvent.SOUND then
        vehicle:setLoadAssistSoundEnabled(value, true)
    elseif vehicle.spec_loadAssist.modeList[index] == nil then
        return
    elseif kind == LoadAssistEvent.TARGET then
        vehicle:setLoadAssistTarget(index, value, true)
    elseif kind == LoadAssistEvent.RESET then
        vehicle:resetLoadAssistLoaded(index, true)
    elseif kind == LoadAssistEvent.ENABLED then
        vehicle:setLoadAssistModeEnabled(index, value, true)
    end
end

-- Op de server (en in singleplayer) naar alle spelers, bij een speler naar de server
function LoadAssistEvent.sendEvent(vehicle, kind, index, value, noEventSend)
    if noEventSend == true then
        return
    end
    if g_server ~= nil then
        g_server:broadcastEvent(LoadAssistEvent.new(vehicle, kind, index, value), nil, nil, vehicle)
    elseif g_client ~= nil then
        g_client:getServerConnection():sendEvent(LoadAssistEvent.new(vehicle, kind, index, value))
    end
end
