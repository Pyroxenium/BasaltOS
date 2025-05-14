local utils = {}

function utils.loadBimg(path)
    local file = fs.open(path, "r")
    if file then
        return textutils.unserialize(file.readAll())
    else
        error("Could not open file: " .. path)
    end
end

utils.tHex = {}
for i = 0, 15 do
    utils.tHex[2^i] = ("%x"):format(i)
    utils.tHex[("%x"):format(i)] = 2^i
end

return utils