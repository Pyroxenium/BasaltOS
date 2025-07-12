local store = require("store")

local fileRegistry = {
    initialized = false,
    defaultAssociations = {
        [".lua"] = {
            open = "Shell",
            edit = "Edit"
        },
        [".txt"] = {
            open = "Edit",
            edit = "Edit"
        },
        [".json"] = {
            open = "Edit",
            edit = "Edit"
        },
        [".bimg"] = {
            open = "Edit",
            edit = "Edit"
        },
        [".nfp"] = {
            open = "Paint",
            edit = "Paint"
        },
        ["__directory"] = {
            open = "Finder",
            edit = "Finder"
        }
    }
}

function fileRegistry.init()
    if fileRegistry.initialized then
        return
    end

    local existingRegistry = store.getCategory("fileAssociations")
    if not existingRegistry then
        store.set("fileAssociations", "associations", fileRegistry.defaultAssociations)
        store.set("fileAssociations", "userOverrides", {})
    end

    fileRegistry.initialized = true
end

function fileRegistry.registerAppHandlers(appName, fileAssociations)
    if not fileAssociations then
        return
    end

    local associations = store.get("fileAssociations", "associations") or {}

    if fileAssociations.open then
        for _, extension in ipairs(fileAssociations.open) do
            if not associations[extension] then
                associations[extension] = {}
            end
            if not associations[extension].open then
                associations[extension].open = appName
            end
        end
    end

    if fileAssociations.edit then
        for _, extension in ipairs(fileAssociations.edit) do
            if not associations[extension] then
                associations[extension] = {}
            end
            if not associations[extension].edit then
                associations[extension].edit = appName
            end
        end
    end

    store.set("fileAssociations", "associations", associations)
end

function fileRegistry.getHandler(extension, action)
    if not fileRegistry.initialized then
        fileRegistry.init()
    end

    local userOverrides = store.get("fileAssociations", "userOverrides") or {}
    if userOverrides[extension] and userOverrides[extension][action] then
        return userOverrides[extension][action]
    end

    local associations = store.get("fileAssociations", "associations") or {}
    if associations[extension] and associations[extension][action] then
        return associations[extension][action]
    end    if fileRegistry.defaultAssociations[extension] and fileRegistry.defaultAssociations[extension][action] then
        return fileRegistry.defaultAssociations[extension][action]
    end

    return "Edit"
end

function fileRegistry.setUserPreference(extension, action, appName)
    if not fileRegistry.initialized then
        fileRegistry.init()
    end

    local userOverrides = store.get("fileAssociations", "userOverrides") or {}
    if not userOverrides[extension] then
        userOverrides[extension] = {}
    end
    userOverrides[extension][action] = appName

    store.set("fileAssociations", "userOverrides", userOverrides)
end


function fileRegistry.clearUserPreference(extension, action)
    if not fileRegistry.initialized then
        fileRegistry.init()
    end

    local userOverrides = store.get("fileAssociations", "userOverrides") or {}
    if userOverrides[extension] then
        userOverrides[extension][action] = nil

        local hasOverrides = false
        for _ in pairs(userOverrides[extension]) do
            hasOverrides = true
            break
        end
        if not hasOverrides then
            userOverrides[extension] = nil
        end
    end

    store.set("fileAssociations", "userOverrides", userOverrides)
end


function fileRegistry.getAvailableHandlers(extension, action)
    if not fileRegistry.initialized then
        fileRegistry.init()
    end


    local handlers = {}
    local associations = store.get("fileAssociations", "associations") or {}

    for ext, actions in pairs(associations) do
        if ext == extension and actions[action] then
            table.insert(handlers, actions[action])
        end
    end

    local standardApps = {"Edit", "Shell", "Finder"}
    for _, app in ipairs(standardApps) do
        local found = false
        for _, handler in ipairs(handlers) do
            if handler == app then
                found = true
                break
            end
        end
        if not found then
            table.insert(handlers, app)
        end
    end

    return handlers
end

function fileRegistry.getAllAssociations()
    if not fileRegistry.initialized then
        fileRegistry.init()
    end

    return {
        associations = store.get("fileAssociations", "associations") or {},
        userOverrides = store.get("fileAssociations", "userOverrides") or {},
        defaults = fileRegistry.defaultAssociations
    }
end


function fileRegistry.getFileExtension(filePath)
    if not filePath or filePath == "" then
        return nil
    end

    -- Check if it's a directory
    if fs.exists(filePath) and fs.isDir(filePath) then
        return "__directory"
    end

    local extension = filePath:match("%.([^%.]+)$")
    if extension then
        return "." .. extension:lower()
    end
    return nil
end

function fileRegistry.supportsDirectories(appName, action)
    if not fileRegistry.initialized then
        fileRegistry.init()
    end
    
    local associations = store.get("fileAssociations", "associations") or {}
    for extension, actions in pairs(associations) do
        if extension == "__directory" and actions[action] == appName then
            return true
        end
    end
    
    return false
end

-- Install new file extensions with default associations
function fileRegistry.installExtensions(extensions, appName)
    if not fileRegistry.initialized then
        fileRegistry.init()
    end
    
    if not extensions or type(extensions) ~= "table" then
        return false
    end
    
    local associations = store.get("fileAssociations", "associations") or {}
    local modified = false
    
    for _, extData in ipairs(extensions) do
        if type(extData) == "table" and extData.extension then
            local ext = extData.extension
            if not ext:match("^%.") then
                ext = "." .. ext
            end
            ext = ext:lower()
            
            -- Only install if extension doesn't exist yet
            if not associations[ext] then
                associations[ext] = {}
                modified = true
                
                -- Set app as default for open action if specified
                if extData.canOpen or (not extData.canOpen and not extData.canEdit) then
                    associations[ext].open = appName
                end
                
                -- Set app as default for edit action if specified  
                if extData.canEdit or (not extData.canOpen and not extData.canEdit) then
                    associations[ext].edit = appName
                end
            end
        elseif type(extData) == "string" then
            -- Simple string format - app handles both open and edit
            local ext = extData
            if not ext:match("^%.") then
                ext = "." .. ext
            end
            ext = ext:lower()
            
            if not associations[ext] then
                associations[ext] = {
                    open = appName,
                    edit = appName
                }
                modified = true
            end
        end
    end
    
    if modified then
        store.set("fileAssociations", "associations", associations)
        return true
    end
    return false
end

-- Remove extensions when an app is uninstalled
function fileRegistry.uninstallExtensions(extensions)
    if not fileRegistry.initialized then
        fileRegistry.init()
    end
    
    if not extensions or type(extensions) ~= "table" then
        return false
    end
    
    local associations = store.get("fileAssociations", "associations") or {}
    local userOverrides = store.get("fileAssociations", "userOverrides") or {}
    local modified = false
    
    for _, ext in ipairs(extensions) do
        if type(ext) == "string" then
            if not ext:match("^%.") then
                ext = "." .. ext
            end
            ext = ext:lower()
            
            -- Remove from associations if it exists
            if associations[ext] then
                associations[ext] = nil
                modified = true
            end
            
            -- Remove from user overrides if it exists
            if userOverrides[ext] then
                userOverrides[ext] = nil
                modified = true
            end
        end
    end
    
    if modified then
        store.set("fileAssociations", "associations", associations)
        store.set("fileAssociations", "userOverrides", userOverrides)
        return true
    end
    return false
end

-- Check if an app exists in the system
function fileRegistry.appExists(appName)
    local appManager = require("libraries.private.appManager")
    return appManager.isInstalled(appName)
end

-- Clean up associations for deleted apps
function fileRegistry.cleanupDeletedApps()
    if not fileRegistry.initialized then
        fileRegistry.init()
    end
    
    local associations = store.get("fileAssociations", "associations") or {}
    local userOverrides = store.get("fileAssociations", "userOverrides") or {}
    local modified = false
    
    -- Check associations
    for extension, actions in pairs(associations) do
        for action, appName in pairs(actions) do
            if appName and not fileRegistry.appExists(appName) then
                -- Reset to default if available, otherwise remove
                if fileRegistry.defaultAssociations[extension] and 
                   fileRegistry.defaultAssociations[extension][action] then
                    associations[extension][action] = fileRegistry.defaultAssociations[extension][action]
                else
                    associations[extension][action] = "Edit" -- Fallback to Edit
                end
                modified = true
            end
        end
    end
    
    -- Check user overrides
    for extension, actions in pairs(userOverrides) do
        for action, appName in pairs(actions) do
            if appName and not fileRegistry.appExists(appName) then
                userOverrides[extension][action] = nil
                modified = true
                
                -- Clean up empty override entries
                local hasOverrides = false
                for _ in pairs(userOverrides[extension]) do
                    hasOverrides = true
                    break
                end
                if not hasOverrides then
                    userOverrides[extension] = nil
                end
            end
        end
    end
    
    if modified then
        store.set("fileAssociations", "associations", associations)
        store.set("fileAssociations", "userOverrides", userOverrides)
        return true
    end
    return false
end

-- Get list of extensions that can be safely removed (not system defaults)
function fileRegistry.getRemovableExtensions()
    if not fileRegistry.initialized then
        fileRegistry.init()
    end
    
    local associations = store.get("fileAssociations", "associations") or {}
    local removable = {}
    
    for extension, _ in pairs(associations) do
        -- Skip system default extensions and directory handler
        if not fileRegistry.defaultAssociations[extension] and extension ~= "__directory" then
            table.insert(removable, extension)
        end
    end
    
    table.sort(removable)
    return removable
end

-- Remove an extension completely from the system
function fileRegistry.removeExtension(extension)
    if not fileRegistry.initialized then
        fileRegistry.init()
    end
    
    -- Don't allow removing system defaults
    if fileRegistry.defaultAssociations[extension] or extension == "__directory" then
        return false
    end
    
    local associations = store.get("fileAssociations", "associations") or {}
    local userOverrides = store.get("fileAssociations", "userOverrides") or {}
    
    local removed = false
    
    if associations[extension] then
        associations[extension] = nil
        removed = true
    end
    
    if userOverrides[extension] then
        userOverrides[extension] = nil
        removed = true
    end
    
    if removed then
        store.set("fileAssociations", "associations", associations)
        store.set("fileAssociations", "userOverrides", userOverrides)
        return true
    end
    
    return false
end

return fileRegistry
