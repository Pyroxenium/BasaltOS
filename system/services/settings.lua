-- /services/settings.lua
-- Settings Service: User-based settings management with defaults

local api_factory = require("core.api")
local event = require("core.event")
local service = require("core.service")
local log = require("core.log")

local api = api_factory.new()

local current_user = nil
local user_settings = {}
local default_settings = {}

local SYSTEM_DEFAULTS = {
    desktop = {
        background_color = "cyan",
        wallpaper = nil,
        icon_size = "medium",
        show_desktop_icons = true
    },

    taskbar = {
        position = "bottom",  -- bottom, top, left, right
        auto_hide = false,
        show_clock = true,
        clock_format = "%H:%M:%S",
        button_width = 12
    },

    window = {
        default_width = 30,
        default_height = 15,
        enable_animations = false,
        snap_to_edges = true,
        snap_distance = 2
    },

    system = {
        log_level = "INFO",  -- DEBUG, INFO, WARN, ERROR, FATAL
        auto_save_interval = 300,  -- seconds
        language = "en"
    },

    startmenu = {
        show_recently_used = true,
        max_recent_items = 10,
        group_by_category = true
    }
}

-- Settings metadata for UI generation
-- Types: boolean, number, string, choice, color, file
-- visible: true/false - Show in settings UI (default: true)
-- internal: true - Internal setting, not shown to user
local SETTINGS_METADATA = {
    desktop = {
        label = "Desktop",
        icon = "desktop",
        visible = true,
        settings = {
            background_color = {
                label = "Background Color",
                type = "color",
                description = "Desktop background color",
                visible = true
            },
            wallpaper = {
                label = "Wallpaper",
                type = "file",
                description = "Desktop wallpaper image (.nfp)",
                filter = "*.nfp",
                visible = true
            },
            icon_size = {
                label = "Icon Size",
                type = "choice",
                description = "Size of desktop icons",
                choices = {"small", "medium", "large"},
                visible = true
            },
            show_desktop_icons = {
                label = "Show Desktop Icons",
                type = "boolean",
                description = "Display icons on desktop",
                visible = true
            }
        }
    },

    taskbar = {
        label = "Taskbar",
        icon = "taskbar",
        visible = true,
        settings = {
            position = {
                label = "Position",
                type = "choice",
                description = "Taskbar position on screen",
                choices = {"bottom", "top", "left", "right"},
                visible = true
            },
            auto_hide = {
                label = "Auto-hide",
                type = "boolean",
                description = "Automatically hide taskbar when not in use",
                visible = true
            },
            show_clock = {
                label = "Show Clock",
                type = "boolean",
                description = "Display clock in taskbar",
                visible = true
            },
            clock_format = {
                label = "Clock Format",
                type = "string",
                description = "Time format (Lua date format)",
                placeholder = "%H:%M:%S",
                visible = false  -- Advanced setting
            },
            button_width = {
                label = "Button Width",
                type = "number",
                description = "Width of window buttons",
                min = 8,
                max = 20,
                visible = false  -- Internal/advanced
            }
        }
    },

    window = {
        label = "Windows",
        icon = "window",
        visible = true,
        settings = {
            default_width = {
                label = "Default Width",
                type = "number",
                description = "Default window width",
                min = 10,
                max = 51,
                visible = true
            },
            default_height = {
                label = "Default Height",
                type = "number",
                description = "Default window height",
                min = 5,
                max = 19,
                visible = true
            },
            enable_animations = {
                label = "Enable Animations",
                type = "boolean",
                description = "Animate window open/close",
                visible = true
            },
            snap_to_edges = {
                label = "Snap to Edges",
                type = "boolean",
                description = "Snap windows to screen edges",
                visible = true
            },
            snap_distance = {
                label = "Snap Distance",
                type = "number",
                description = "Distance for edge snapping",
                min = 1,
                max = 5,
                visible = false  -- Advanced
            }
        }
    },

    system = {
        label = "System",
        icon = "system",
        visible = true,
        settings = {
            log_level = {
                label = "Log Level",
                type = "choice",
                description = "Minimum log level to record",
                choices = {"DEBUG", "INFO", "WARN", "ERROR", "FATAL"},
                visible = false  -- Advanced/developer setting
            },
            auto_save_interval = {
                label = "Auto-save Interval",
                type = "number",
                description = "Auto-save interval in seconds",
                min = 60,
                max = 600,
                visible = false  -- Advanced
            },
            language = {
                label = "Language",
                type = "choice",
                description = "System language",
                choices = {"en", "de"},
                visible = true
            }
        }
    },

    startmenu = {
        label = "Start Menu",
        icon = "menu",
        visible = true,
        settings = {
            show_recently_used = {
                label = "Show Recently Used",
                type = "boolean",
                description = "Show recently used apps in menu",
                visible = true
            },
            max_recent_items = {
                label = "Max Recent Items",
                type = "number",
                description = "Maximum recent items to show",
                min = 5,
                max = 20,
                visible = false  -- Advanced
            },
            group_by_category = {
                label = "Group by Category",
                type = "boolean",
                description = "Group apps by category in menu",
                visible = true
            }
        }
    }
}

function api.public.init()
    event.on("user.login", function(username)
        api.private.loadUserSettings(username)
    end)

    event.on("user.logout", function()
        api.private.saveUserSettings()
        current_user = nil
        user_settings = {}
    end)

    log.debug("SETTINGS", "Settings service initialized")
end

function api.private.loadUserSettings(username)
    current_user = username
    user_settings = {}

    local settings_file = fs.combine("users", username, "config", "settings.dat")

    if fs.exists(settings_file) then
        local file = fs.open(settings_file, "r")
        if file then
            local content = file.readAll()
            file.close()

            local ok, data = pcall(textutils.unserialize, content)
            if ok and type(data) == "table" then
                user_settings = data
                log.info("SETTINGS", "User settings loaded", {user = username, keys = #user_settings})
            else
                log.warn("SETTINGS", "Failed to parse user settings, using defaults", {user = username})
            end
        end
    else
        log.debug("SETTINGS", "No settings file found, using defaults", {user = username})
    end

    api.private.applyDefaults()
end

function api.private.applyDefaults()
    for category, settings in pairs(SYSTEM_DEFAULTS) do
        if not user_settings[category] then
            user_settings[category] = {}
        end

        for key, value in pairs(settings) do
            if user_settings[category][key] == nil then
                user_settings[category][key] = value
            end
        end
    end
end

function api.private.saveUserSettings()
    if not current_user then
        log.warn("SETTINGS", "Cannot save settings: no user logged in")
        return false
    end

    local user_dir = fs.combine("users", current_user, "config")
    if not fs.exists(user_dir) then
        fs.makeDir(user_dir)
    end

    local settings_file = fs.combine(user_dir, "settings.dat")
    local file = fs.open(settings_file, "w")

    if file then
        file.write(textutils.serialize(user_settings))
        file.close()
        log.debug("SETTINGS", "User settings saved", {user = current_user})
        return true
    else
        log.error("SETTINGS", "Failed to save user settings", {user = current_user})
        return false
    end
end

function api.public.get(path, default_value)
    if not current_user then
        log.warn("SETTINGS", "Cannot get setting: no user logged in", {path = path})
        return default_value
    end

    local parts = {}
    for part in string.gmatch(path, "[^.]+") do
        table.insert(parts, part)
    end

    local value = user_settings
    for _, part in ipairs(parts) do
        if type(value) ~= "table" then
            return default_value
        end
        value = value[part]
        if value == nil then
            return default_value
        end
    end

    return value
end

function api.public.set(path, value)
    if not current_user then
        log.warn("SETTINGS", "Cannot set setting: no user logged in", {path = path})
        return false
    end

    local parts = {}
    for part in string.gmatch(path, "[^.]+") do
        table.insert(parts, part)
    end

    if #parts < 2 then
        log.error("SETTINGS", "Invalid setting path (must be category.key)", {path = path})
        return false
    end

    local current = user_settings
    for i = 1, #parts - 1 do
        local part = parts[i]
        if not current[part] then
            current[part] = {}
        end
        current = current[part]
    end

    local key = parts[#parts]
    local old_value = current[key]
    current[key] = value

    api.private.saveUserSettings()

    event.dispatch("settings.changed", path, value, old_value)

    log.debug("SETTINGS", "Setting changed", {path = path, value = value, old = old_value})

    return true
end

function api.public.getCategory(category)
    if not current_user then
        log.warn("SETTINGS", "Cannot get category: no user logged in", {category = category})
        return {}
    end

    return user_settings[category] or {}
end

function api.public.setCategory(category, settings)
    if not current_user then
        log.warn("SETTINGS", "Cannot set category: no user logged in", {category = category})
        return false
    end

    if type(settings) ~= "table" then
        log.error("SETTINGS", "Invalid settings data (must be table)", {category = category})
        return false
    end

    user_settings[category] = user_settings[category] or {}

    for key, value in pairs(settings) do
        user_settings[category][key] = value
    end

    api.private.saveUserSettings()
    event.dispatch("settings.category_changed", category, settings)

    log.debug("SETTINGS", "Category updated", {category = category, keys = #settings})

    return true
end

function api.public.reset(path)
    if not current_user then
        log.warn("SETTINGS", "Cannot reset setting: no user logged in", {path = path})
        return false
    end

    local parts = {}
    for part in string.gmatch(path, "[^.]+") do
        table.insert(parts, part)
    end

    if #parts < 2 then
        return false
    end

    local category = parts[1]
    local key = parts[2]

    if SYSTEM_DEFAULTS[category] and SYSTEM_DEFAULTS[category][key] ~= nil then
        return api.public.set(path, SYSTEM_DEFAULTS[category][key])
    end

    return false
end

function api.public.resetCategory(category)
    if not current_user then
        log.warn("SETTINGS", "Cannot reset category: no user logged in", {category = category})
        return false
    end

    if SYSTEM_DEFAULTS[category] then
        user_settings[category] = {}
        for key, value in pairs(SYSTEM_DEFAULTS[category]) do
            user_settings[category][key] = value
        end

        api.private.saveUserSettings()
        event.dispatch("settings.category_reset", category)

        log.info("SETTINGS", "Category reset to defaults", {category = category})
        return true
    end

    return false
end

function api.public.getAll()
    if not current_user then
        return {}
    end

    return user_settings
end

function api.public.getDefaults()
    return SYSTEM_DEFAULTS
end

function api.public.getMetadata()
    return SETTINGS_METADATA
end

function api.public.getCategoryMetadata(category)
    return SETTINGS_METADATA[category]
end

function api.public.getSettingMetadata(category, key)
    if SETTINGS_METADATA[category] and SETTINGS_METADATA[category].settings then
        return SETTINGS_METADATA[category].settings[key]
    end
    return nil
end

function api.public.getCategories(visible_only)
    local categories = {}
    for category, meta in pairs(SETTINGS_METADATA) do
        if not visible_only or meta.visible ~= false then
            table.insert(categories, {
                id = category,
                label = meta.label,
                icon = meta.icon,
                visible = meta.visible ~= false
            })
        end
    end
    return categories
end

function api.public.getVisibleSettings(category)
    local meta = SETTINGS_METADATA[category]
    if not meta or not meta.settings then
        return {}
    end

    local visible_settings = {}
    for key, setting_meta in pairs(meta.settings) do
        if setting_meta.visible ~= false then
            visible_settings[key] = setting_meta
        end
    end

    return visible_settings
end

function api.public.validate(path, value)
    local parts = {}
    for part in string.gmatch(path, "[^.]+") do
        table.insert(parts, part)
    end

    if #parts < 2 then
        return false, "Invalid path"
    end

    local category = parts[1]
    local key = parts[2]

    local meta = api.public.getSettingMetadata(category, key)
    if not meta then
        return true
    end

    if meta.type == "boolean" then
        if type(value) ~= "boolean" then
            return false, "Must be boolean"
        end
    elseif meta.type == "number" then
        if type(value) ~= "number" then
            return false, "Must be number"
        end
        if meta.min and value < meta.min then
            return false, "Must be >= " .. meta.min
        end
        if meta.max and value > meta.max then
            return false, "Must be <= " .. meta.max
        end
    elseif meta.type == "string" then
        if type(value) ~= "string" then
            return false, "Must be string"
        end
    elseif meta.type == "choice" then
        if type(value) ~= "string" then
            return false, "Must be string"
        end
        local valid = false
        for _, choice in ipairs(meta.choices or {}) do
            if value == choice then
                valid = true
                break
            end
        end
        if not valid then
            return false, "Invalid choice"
        end
    elseif meta.type == "color" then
        if type(value) ~= "string" then
            return false, "Must be color name"
        end
    end

    return true
end

function api.public.hasUserSettings()
    if not current_user then
        return false
    end

    local settings_file = fs.combine("users", current_user, "config", "settings.dat")
    return fs.exists(settings_file)
end

function api.public.export(filepath)
    if not current_user then
        return false, "No user logged in"
    end

    local file = fs.open(filepath, "w")
    if file then
        file.write(textutils.serialize(user_settings))
        file.close()
        log.info("SETTINGS", "Settings exported", {file = filepath})
        return true
    end

    return false, "Failed to write file"
end

function api.public.import(filepath)
    if not current_user then
        return false, "No user logged in"
    end

    if not fs.exists(filepath) then
        return false, "File not found"
    end

    local file = fs.open(filepath, "r")
    if file then
        local content = file.readAll()
        file.close()

        local ok, data = pcall(textutils.unserialize, content)
        if ok and type(data) == "table" then
            user_settings = data
            api.private.applyDefaults()
            api.private.saveUserSettings()

            event.dispatch("settings.imported", filepath)
            log.info("SETTINGS", "Settings imported", {file = filepath})
            return true
        end
    end

    return false, "Failed to parse settings file"
end

return api
