-- /system/core/config.lua
-- Configuration management: Persistent system configuration

local config = {}

local CONFIG_FILE = "system/config.dat"
local config_data = {}
local user_config_data = {}
local current_user = nil

local defaults = {
    system = {
        name = "BasaltOS",
        version = "0.1.0",
        debug = false
    },
    display = {
        width = 51,
        height = 19
    },
    theme = {
        design_version = 2,

        -- Core palette
        primary        = colors.blue,
        secondary      = colors.gray,
        surface        = colors.lightGray,
        danger         = colors.red,        -- Destructive actions (close btn, logout/shutdown hover)
        warning        = colors.orange,     -- Minimize button
        success        = colors.lime,       -- OK button in dialogs

        -- Text
        text           = colors.white,      -- Default text on dark surfaces
        text_dim       = colors.lightGray,  -- Dim text (clock, dividers)
        text_on_light  = colors.black,      -- Text on light surfaces (dialog ok btn)

        -- Light shell surfaces
        desktop_bg     = colors.white,
        desktop_fg     = colors.black,
        desktop_muted  = colors.gray,
        taskbar_bg     = colors.lightGray,
        taskbar_fg     = colors.black,
        taskbar_muted  = colors.gray,
        menu_bg        = colors.white,
        menu_fg        = colors.black,
        menu_muted     = colors.gray,

        -- Monochrome icon ink. The active taskbar window injects icon_active.
        icon_fg        = colors.black,
        icon_active    = colors.blue,

        -- Border
        border         = colors.gray,       -- Window/dialog border color
        dialog_border  = colors.cyan,       -- Dialog accent border
        window_focused = colors.blue,        -- Titlebar color of the focused window
        btn_clicked    = colors.cyan,        -- Button background when clicked
    },
    filetypes = {
        default_app = "notepad",
        associations = {
            txt  = "notepad",
            lua  = "exec",
            json = "notepad",
            md   = "notepad",
            log  = "notepad",
            nfp  = "paint",
            flimg = "flimgviewer",
            bimg = "flimgviewer",
            arch = "architect",
        },
        editors = {
            lua = "edit",
            txt = "edit",
            json = "edit",
            md = "edit",
            log = "edit",
            nfp = "paint",
            flimg = "flimgstudio",
            bimg = "iconstudio",
            arch = "edit",
        },
    },
    services = {
        basaltstore = {
            catalog_url =
                "https://raw.githubusercontent.com/Pyroxenium/BasaltOSStore/main/catalog.json",
            cache_seconds = 300,
        },
    }
}

local function deepCopy(original)
    local copy
    if type(original) == 'table' then
        copy = {}
        for k, v in pairs(original) do
            copy[k] = deepCopy(v)
        end
    else
        copy = original
    end
    return copy
end

local function deepMerge(base, override)
    local result = deepCopy(base)
    if type(override) == "table" then
        for k, v in pairs(override) do
            if type(v) == "table" and type(result[k]) == "table" then
                result[k] = deepMerge(result[k], v)
            else
                result[k] = v
            end
        end
    end
    return result
end

function config.load()
    if fs.exists(CONFIG_FILE) then
        local file = fs.open(CONFIG_FILE, "r")
        if file then
            local content = file.readAll()
            file.close()

            local ok, data = pcall(textutils.unserialize, content)
            if ok and type(data) == "table" then
                -- Merge loaded data on top of defaults so new default keys are always present
                config_data = deepMerge(defaults, data)
                -- Theme v2 intentionally replaces the old green/black shell once.
                -- User appearance overrides are stored separately in user.dat.
                local loaded_theme = type(data.theme) == "table" and data.theme or {}
                if tonumber(loaded_theme.design_version) ~= defaults.theme.design_version then
                    config_data.theme = deepCopy(defaults.theme)
                end
                return true
            end
        end
    end

    config_data = deepCopy(defaults)
    return false
end

function config.save()
    local file = fs.open(CONFIG_FILE, "w")
    if file then
        file.write(textutils.serialize(config_data))
        file.close()
        return true
    end
    return false
end

function config.get(path, default_value)
    local keys = {}
    for key in string.gmatch(path, "[^.]+") do
        table.insert(keys, key)
    end

    local value = user_config_data
    local found_user_value = current_user ~= nil
    for _, key in ipairs(keys) do
        if type(value) ~= "table" or value[key] == nil then
            found_user_value = false
            break
        end
        value = value[key]
    end
    if found_user_value then return value end

    value = config_data
    for _, key in ipairs(keys) do
        if type(value) ~= "table" or value[key] == nil then
            return default_value
        end
        value = value[key]
    end

    return value
end

-- Reads only the machine-wide configuration. Authentication and other system
-- databases must never be shadowed by the active user's user.dat overrides.
function config.getSystem(path, default_value)
    local value = config_data
    for key in string.gmatch(path, "[^.]+") do
        if type(value) ~= "table" or value[key] == nil then return default_value end
        value = value[key]
    end
    return value
end

function config.set(path, value)
    local keys = {}
    for key in string.gmatch(path, "[^.]+") do
        table.insert(keys, key)
    end

    local current = config_data
    for i = 1, #keys - 1 do
        local key = keys[i]
        if type(current[key]) ~= "table" then
            current[key] = {}
        end
        current = current[key]
    end

    current[keys[#keys]] = value
end

function config.getAll()
    return deepCopy(config_data)
end

function config.reset()
    config_data = deepCopy(defaults)
    config.save()
end

function config.setCurrentUser(username)
    current_user = username

    if username then
        local user_config_file = fs.combine("users", username, "config", "user.dat")

        if fs.exists(user_config_file) then
            local file = fs.open(user_config_file, "r")
            if file then
                local content = file.readAll()
                file.close()
                local ok, data = pcall(textutils.unserialize, content)
                if ok and type(data) == "table" then
                    user_config_data = data
                else
                    user_config_data = {}
                end
            end
        else
            user_config_data = {}
        end
    else
        user_config_data = {}
    end
end

function config.saveUserConfig()
    if not current_user then
        return false
    end

    local user_config_dir = fs.combine("users", current_user, "config")
    if not fs.exists(user_config_dir) then
        fs.makeDir(user_config_dir)
    end

    local user_config_file = fs.combine(user_config_dir, "user.dat")
    local file = fs.open(user_config_file, "w")
    if file then
        file.write(textutils.serialize(user_config_data))
        file.close()
        return true
    end
    return false
end

function config.getUserConfig(path, default_value)
    if not current_user then
        return default_value
    end

    local keys = {}
    for key in string.gmatch(path, "[^.]+") do
        table.insert(keys, key)
    end

    local value = user_config_data
    for _, key in ipairs(keys) do
        if type(value) ~= "table" or value[key] == nil then
            return default_value
        end
        value = value[key]
    end
    return value
end

function config.setUserConfig(path, value, save_immediately)
    if not current_user then
        return false
    end

    local keys = {}
    for key in string.gmatch(path, "[^.]+") do
        table.insert(keys, key)
    end

    local current = user_config_data
    for i = 1, #keys - 1 do
        local key = keys[i]
        if type(current[key]) ~= "table" then
            current[key] = {}
        end
        current = current[key]
    end

    current[keys[#keys]] = value
    if save_immediately ~= false then config.saveUserConfig() end
    return true
end

function config.getCurrentUser()
    return current_user
end

return config
