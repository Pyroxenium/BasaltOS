-- Clipboard API for BasaltOS
-- Supports text and files/folders

local clipboard = {}

local clipboardData = {
    type = nil,
    content = nil,
    timestamp = nil
}

--- Copies text to clipboard
--- @param text string The text to copy
function clipboard.copyText(text)
    if type(text) ~= "string" then
        error("Text must be a string")
    end

    clipboardData = {
        type = "text",
        content = text,
        timestamp = os.epoch("utc")
    }
end

--- Copies a file/folder to clipboard
--- @param filePath string Path to the file/folder
--- @param fileName string? Optional: The filename (if not provided, extracted from path)
function clipboard.copyFile(filePath, fileName)
    if type(filePath) ~= "string" then
        error("File path must be a string")
    end

    if not fs.exists(filePath) then
        error("File does not exist: " .. filePath)
    end

    local name = fileName or fs.getName(filePath)

    clipboardData = {
        type = "file",
        content = {
            path = filePath,
            name = name,
            isDirectory = fs.isDir(filePath)
        },
        timestamp = os.epoch("utc")
    }
end

--- Returns the type of current clipboard content
--- @return string|nil type "text", "file" or nil if empty
function clipboard.getType()
    return clipboardData.type
end

--- Returns text content (only if type is "text")
--- @return string|nil text The text or nil
function clipboard.getText()
    if clipboardData.type == "text" then
        return clipboardData.content
    end
    return nil
end

--- Returns file information (only if type is "file")
--- @return table|nil fileInfo {path, name, isDirectory} or nil
function clipboard.getFile()
    if clipboardData.type == "file" then
        return clipboardData.content
    end
    return nil
end

--- Checks if clipboard is empty
--- @return boolean empty True if empty
function clipboard.isEmpty()
    return clipboardData.type == nil
end

--- Checks if text is in clipboard
--- @return boolean hasText True if text is present
function clipboard.hasText()
    return clipboardData.type == "text"
end

--- Checks if file is in clipboard
--- @return boolean hasFile True if file is present
function clipboard.hasFile()
    return clipboardData.type == "file"
end

--- Clears the clipboard
function clipboard.clear()
    clipboardData = {
        type = nil,
        content = nil,
        timestamp = nil
    }
end

--- Returns information about clipboard content
--- @return table info {type, hasContent, timestamp, contentPreview}
function clipboard.getInfo()
    local info = {
        type = clipboardData.type,
        hasContent = clipboardData.type ~= nil,
        timestamp = clipboardData.timestamp
    }
    
    if clipboardData.type == "text" then
        local preview = clipboardData.content
        if #preview > 50 then
            preview = preview:sub(1, 47) .. "..."
        end
        info.contentPreview = preview
    elseif clipboardData.type == "file" then
        local fileType = clipboardData.content.isDirectory and "Folder" or "File"
        info.contentPreview = fileType .. ": " .. clipboardData.content.name
    end
    
    return info
end

--- Pastes a file from clipboard to target folder (copies the file)
--- @param targetDir string The target folder
--- @param newName string? Optional: New name (if not provided, original name is used)
--- @return boolean success True if successful
--- @return string|nil error Error message on failure
function clipboard.pasteFile(targetDir, newName)
    if clipboardData.type ~= "file" then
        return false, "No file in clipboard"
    end

    if not fs.exists(targetDir) or not fs.isDir(targetDir) then
        return false, "Target directory does not exist"
    end

    local fileInfo = clipboardData.content
    local fileName = newName or fileInfo.name
    local targetPath = fs.combine(targetDir, fileName)

    if fs.exists(targetPath) then
        return false, "Target already exists"
    end

    local success, error = pcall(function()
        clipboard._copyRecursive(fileInfo.path, targetPath)
    end)

    if success then
        return true, nil
    else
        return false, tostring(error)
    end
end

--- Helper function for recursive copying
--- @param source string Source path
--- @param destination string Destination path
function clipboard._copyRecursive(source, destination)
    if fs.isDir(source) then
        if not fs.exists(destination) then
            fs.makeDir(destination)
        end

        local files = fs.list(source)
        for _, file in ipairs(files) do
            local sourcePath = fs.combine(source, file)
            local destPath = fs.combine(destination, file)
            clipboard._copyRecursive(sourcePath, destPath)
        end
    else
        fs.copy(source, destination)
    end
end

return clipboard
