local utils = {}

function utils.loadBimg(path)
    local bimg = {}
    local file = fs.open(path, "r")
    if file then
        return textutils.unserialize(file.readAll())
    else
        error("Could not open file: " .. path)
    end
end

return utils