local basalt = require("libraries.public.basalt")

local osError = {}

osError.error = function(message)
    error(message)
end

osError.warning = function(message)
    print("Warning: " .. message)
end


return osError