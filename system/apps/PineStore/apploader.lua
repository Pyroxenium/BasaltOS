local path = require("path")
local BasaltOS = require("basaltos")
local colorHex = require("utils").tHex

local appInstaller = {}

local function downloadApp(main, app)
    local programFrame = main:addFrame({
        x = 1,
        y = 1,
        z = 100,
        width = main.width,
        height = main.height,
        background = colors.black,
    })
    local execProgram = programFrame:addProgram({
        x = 1,
        y = 2,
        width = programFrame.width,
        height = programFrame.height - 1,
        background = colors.black,
    })
    local cmdPath = path.resolve(BasaltOS.getAppPath() .. "/installCmd.lua")
    execProgram:execute(cmdPath, nil, nil, app.pineStore.install_command)
    execProgram:onDone(function(self, ok, result)
        BasaltOS.notify("Successfully installed " .. app.manifest.name)
        programFrame:destroy()
    end)
    execProgram:onError(function(result, err)
        BasaltOS.errorDialog(err)
    end)
    programFrame:addButton({
        x = 2,
        y = 1,
        width = 8,
        height = 1,
        text = "< Back",
        background = colors.gray,
        foreground = colors.white
    }):onClick(function()
        programFrame:destroy()
    end)
end

function appInstaller.install(main, app)
    downloadApp(main, app)
end

return appInstaller