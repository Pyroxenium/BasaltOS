-- Obsidian Audio Module
-- Handles music playback, sound effects, and speaker management

local logger = require("core.logger")
local thread = require("core.thread")

---@diagnostic disable: undefined-global

-- ============================================================================
-- Module State
-- ============================================================================

---@class AudioModule
---@field _speakers table[] Speaker peripheral proxies
---@field _initialized boolean
---@field _currentSong table|nil
---@field _songThread ThreadHandle|nil
---@field _sfxLibrary table<string, table[]>
---@field _muted boolean
---@field _masterVolume number
local AudioModule = {
    _speakers = {},
    _initialized = false,
    _currentSong = nil,
    _songThread = nil,
    _sfxLibrary = {},
    _muted = false,
    _masterVolume = 1.0, -- 0.0 - 1.0
}

-- ============================================================================
-- Initialization
-- ============================================================================

--- Scan for speaker peripherals
--- Called automatically on first playback or explicitly from engine boot
function AudioModule.refresh()
    AudioModule._speakers = { peripheral.find("speaker") }
    AudioModule._initialized = true

    if #AudioModule._speakers == 0 then
        logger.warn("Audio: No speakers found. Audio disabled.")
    else
        logger.info(string.format("Audio: %d speaker(s) detected.", #AudioModule._speakers))
    end
end

--- Check if audio system is ready
---@return boolean
function AudioModule.isReady()
    return AudioModule._initialized and #AudioModule._speakers > 0
end

--- Get number of connected speakers
---@return number
function AudioModule.getSpeakerCount()
    return #AudioModule._speakers
end

-- ============================================================================
-- Volume & Mute
-- ============================================================================

--- Set master mute state
---@param muted boolean
function AudioModule.setMuted(muted)
    AudioModule._muted = muted == true
end

--- Get master mute state
---@return boolean
function AudioModule.isMuted()
    return AudioModule._muted
end

--- Set master volume (0.0 - 1.0)
---@param volume number
function AudioModule.setVolume(volume)
    AudioModule._masterVolume = math.max(0, math.min(1, volume))
end

--- Get master volume
---@return number
function AudioModule.getVolume()
    return AudioModule._masterVolume
end

-- ============================================================================
-- Note Playback
-- ============================================================================

--- Play a single note on all speakers
---@param instrument string|nil Instrument name (default: "harp")
---@param pitch number|nil Pitch value (default: 12)
---@param volume number|nil Volume 0-3 (default: 1, scaled by master volume)
function AudioModule.playNote(instrument, pitch, volume)
    if AudioModule._muted then return end
    if not AudioModule._initialized then AudioModule.refresh() end
    if #AudioModule._speakers == 0 then return end

    local finalVolume = math.max(0, math.min(3, (volume or 1) * AudioModule._masterVolume))
    local instr = instrument or "harp"
    local p = pitch or 12

    for _, speaker in ipairs(AudioModule._speakers) do
        pcall(function()
            speaker.playNote(instr, finalVolume, p)
        end)
    end
end

-- ============================================================================
-- Sound Effects
-- ============================================================================

--- Register a sound effect sequence
---@param name string SFX identifier
---@param sequence table[] Array of note events {instrument, pitch, volume, delay}
function AudioModule.registerSfx(name, sequence)
    if not name or type(sequence) ~= "table" then
        logger.error("Audio: Invalid SFX registration")
        return
    end

    AudioModule._sfxLibrary[name] = sequence
end

--- Play a registered sound effect
---@param name string SFX identifier
function AudioModule.playSfx(name)
    local sequence = AudioModule._sfxLibrary[name]

    if not sequence then
        logger.error("Audio: Unknown SFX '" .. tostring(name) .. "'")
        return
    end

    thread.start(function()
        for _, note in ipairs(sequence) do
            if note.delay then
                os.sleep(note.delay)
            end
            AudioModule.playNote(note.instrument, note.pitch, note.volume)
        end
    end)
end

--- Check if SFX is registered
---@param name string SFX identifier
---@return boolean
function AudioModule.hasSfx(name)
    return AudioModule._sfxLibrary[name] ~= nil
end

--- Remove a registered SFX
---@param name string SFX identifier
function AudioModule.unregisterSfx(name)
    AudioModule._sfxLibrary[name] = nil
end

--- Get all registered SFX names
---@return string[]
function AudioModule.getSfxList()
    local names = {}
    for name in pairs(AudioModule._sfxLibrary) do
        table.insert(names, name)
    end
    return names
end

-- ============================================================================
-- Music Playback
-- ============================================================================

--- Play a song (background music)
---@param songData table Song data with {tempo, length, ticks}
---@param loop boolean|nil Whether to loop (default: false)
function AudioModule.playSong(songData, loop)
    -- Validation
    if not songData then
        logger.error("Audio: playSong called with nil songData")
        return
    end
    if not songData.tempo or songData.tempo <= 0 then
        logger.error("Audio: Invalid or missing tempo in songData")
        return
    end

    AudioModule.stopSong()
    AudioModule._currentSong = songData

    AudioModule._songThread = thread.start(function()
        local tickTime = 1 / songData.tempo
        local playing = true

        while playing do
            for tick = 0, songData.length do
                if AudioModule._currentSong ~= songData then
                    return
                end

                local notes = songData.ticks[tick]
                if notes then
                    for _, note in ipairs(notes) do
                        AudioModule.playNote(note.instrument, note.pitch, note.volume)
                    end
                end

                os.sleep(tickTime)
            end

            if not loop then
                playing = false
            end
        end
    end)
end

--- Stop currently playing song
function AudioModule.stopSong()
    if AudioModule._songThread then
        thread.stop(AudioModule._songThread)
        AudioModule._songThread = nil
    end
    AudioModule._currentSong = nil
end

--- Check if a song is currently playing
---@return boolean
function AudioModule.isSongPlaying()
    return AudioModule._currentSong ~= nil
end

--- Get currently playing song data
---@return table|nil
function AudioModule.getCurrentSong()
    return AudioModule._currentSong
end

-- ============================================================================
-- Cleanup
-- ============================================================================

--- Stop all audio (SFX threads will complete, song stops immediately)
function AudioModule.stopAll()
    AudioModule.stopSong()
end

return AudioModule