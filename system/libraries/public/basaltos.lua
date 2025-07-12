-- Public BasaltOS API for programs
local theme = require("libraries.private.configs").get("windows")

-- Import sub-modules
local dialog = require("libraries.private.os.dialog")
local contextMenu = require("libraries.private.os.contextMenu")
local notification = require("libraries.private.os.notification")
local frame = require("libraries.private.os.frame")
local drag = require("libraries.private.os.drag")

local desktop
local BasaltOS = {root="/"}

function BasaltOS.getRoot()
    return BasaltOS.root
end

function BasaltOS.setRoot(path)
    if type(path) == "string" then
        BasaltOS.root = path
    else
        error("Path must be a string")
    end
end

function BasaltOS.openApp(...)
    desktop:openApp(...)
end

function BasaltOS.openPath(path)
    return desktop:openPath(path)
end

function BasaltOS.editPath(path)
    return desktop:editPath(path)
end

function BasaltOS.getFileHandlers(path, action)
    local fileRegistry = require("libraries.private.fileRegistry")
    local extension = fileRegistry.getFileExtension(path)
    return fileRegistry.getAvailableHandlers(extension, action or "open")
end

function BasaltOS.getFileAssociations()
    local fileRegistry = require("libraries.private.fileRegistry")
    return fileRegistry.getAllAssociations()
end

function BasaltOS.getFileHandler(extension, action)
    local fileRegistry = require("libraries.private.fileRegistry")
    return fileRegistry.getHandler(extension, action)
end

function BasaltOS.getAvailableFileHandlers(extension, action)
    local fileRegistry = require("libraries.private.fileRegistry")
    return fileRegistry.getAvailableHandlers(extension, action)
end

function BasaltOS.setFileAssociation(extension, action, appName)
    local fileRegistry = require("libraries.private.fileRegistry")
    fileRegistry.setUserPreference(extension, action, appName)
end

function BasaltOS.clearFileAssociation(extension, action)
    local fileRegistry = require("libraries.private.fileRegistry")
    fileRegistry.clearUserPreference(extension, action)
end

function BasaltOS.getApps()
    return desktop:getApps()
end

function BasaltOS.registerApp(path)
    local appManager = require("libraries.private.appManager")
    if not path or type(path) ~= "string" then
        error("Path must be a string")
    end
    if not fs.exists(path) then
        error("Path does not exist: " .. path)
    end
    appManager.registerApp(path)
    return true
end

function BasaltOS.setup(_desktop)
    desktop = _desktop
    if not desktop then
        error("Desktop cannot be nil")
    end
end

function BasaltOS.getTheme(name)
    if not name then
        return theme
    end

    local t = theme[name]
    if not t then
        error("Theme '" .. name .. "' does not exist")
    end

    return t
end

function BasaltOS.showNotification(title, message, duration)
    return notification.show(title, message, duration)
end

function BasaltOS.notify(message, duration)
    return notification.notify(message, duration)
end

function BasaltOS.frame(x, y, width, height, options)
    return frame.create(x, y, width, height, options)
end

function BasaltOS.contextMenu(x, y, items, options)
    return contextMenu.create(x, y, items, options)
end

function BasaltOS.dialog(options)
    return dialog.create(options)
end

function BasaltOS.inputDialog(title, message, defaultValue, callback)
    return dialog.input(title, message, defaultValue, callback)
end

function BasaltOS.confirmDialog(title, message, callback)
    return dialog.confirm(title, message, callback)
end

function BasaltOS.errorDialog(message, callback)
    return dialog.error(message, callback)
end

function BasaltOS.fileDialog(title, filter, callback, initialPath)
    return dialog.file(title, filter, callback, initialPath)
end

function BasaltOS.appSelectionDialog(extension, actionType, callback)
    return dialog.showAppSelection(extension, actionType, callback)
end

function BasaltOS.installFileExtensions(extensions, appName)
    local fileRegistry = require("libraries.private.fileRegistry")
    return fileRegistry.installExtensions(extensions, appName)
end

function BasaltOS.uninstallFileExtensions(extensions)
    local fileRegistry = require("libraries.private.fileRegistry")
    return fileRegistry.uninstallExtensions(extensions)
end

function BasaltOS.getRemovableExtensions()
    local fileRegistry = require("libraries.private.fileRegistry")
    return fileRegistry.getRemovableExtensions()
end

function BasaltOS.removeFileExtension(extension)
    local fileRegistry = require("libraries.private.fileRegistry")
    return fileRegistry.removeExtension(extension)
end

function BasaltOS.cleanupDeletedApps()
    local fileRegistry = require("libraries.private.fileRegistry")
    return fileRegistry.cleanupDeletedApps()
end

function BasaltOS.removeApp(appName)
    local appManager = require("libraries.private.appManager")
    return appManager.removeApp(appName)
end

function BasaltOS.canRemoveApp(appName)
    local appManager = require("libraries.private.appManager")
    return appManager.canRemoveApp(appName)
end

function BasaltOS.addProtectedApp(appName)
    local appManager = require("libraries.private.appManager")
    return appManager.addProtectedApp(appName)
end

function BasaltOS.removeProtectedApp(appName)
    local appManager = require("libraries.private.appManager")
    return appManager.removeProtectedApp(appName)
end

function BasaltOS.isProtectedApp(appName)
    local appManager = require("libraries.private.appManager")
    return appManager.isProtected(appName)
end

function BasaltOS.getProtectedApps()
    local appManager = require("libraries.private.appManager")
    return appManager.getProtectedApps()
end

function BasaltOS.registerDraggableItem(filePath, fileName, sourceWindow, localX, localY)
    return drag.registerDraggableItem(filePath, fileName, sourceWindow, localX, localY)
end

return BasaltOS
