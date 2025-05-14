local errorManager = {}

errorManager.error = function(message)
    error(message)
end

return errorManager