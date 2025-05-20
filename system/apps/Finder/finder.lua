local BasaltOS = require("basaltos")
local basalt = require("basalt")
basalt.LOGGER.setEnabled(true)
basalt.LOGGER.setLogToFile(true)
local theme = BasaltOS.getTheme()

local main = basalt.getMainFrame()
local path = "/"
local backHistory = {}
local nextHistory = {}
main:setBackground(theme.primaryColor)
BasaltOS.setAppFrameColor(theme.primaryColor)
BasaltOS.setMenu({["File"] = function() end})

local topbar = main:addFrame({
    x = 1,
    y = 2,
    width = "{parent.width}",
    height = 1,
    background = colors.black
})

local backButton = topbar:addLabel({
    text = "<",
    height = 1,
    foreground = theme.primaryTextColor
})

local nextButton = topbar:addLabel({
    text = ">",
    height = 1,
    x = 3,
    foreground = theme.primaryTextColor
})

local fList = main:addTable({
    x = 1,
    y = 4,
    width = "{parent.width-1}",
    height = "{parent.height-4}",
})
local scrollbar = main:addScrollbar({
    x = "{parent.width}",
    y = 4,
    width = 1,
    height = "{parent.height-4}",
})

fList:setColumns({{name="Name",width=12}, {name="Type",width=10}, {name="Size",width=7}})
scrollbar:attach(fList, {property = "scrollOffset", min=0, max=function()
    return math.max(0, #fList:getData() - fList:getHeight() + 1)
end})


local function updateList()
    local files = fs.list(path)
    local data = {}
    for _, file in ipairs(files) do
        local filePath = path .. "/" .. file
        local fileType = fs.isDir(filePath) and "Folder" or "File"
        local fileSize = fs.isDir(filePath) and "-" or fs.getSize(filePath)
        table.insert(data, {file, fileType, fileSize})
    end
    fList:setData(data)
end
updateList()

fList:onClickUp(function(self, btn, x, y)
    local selected = self:getData()[y-1+self.scrollOffset]
    if selected then
        local fileName = selected[1]
        local filePath = path .. "/" .. fileName
        if fs.isDir(filePath) then
            table.insert(backHistory, path)
            path = filePath
            updateList()
        else
            --shell.run("edit", filePath)
            BasaltOS.openApp("Edit", filePath)
        end
    end
end)

backButton:onClickUp(function()
    if #backHistory > 0 then
        table.insert(nextHistory, path)
        path = table.remove(backHistory)
        updateList()
    end
end)

nextButton:onClickUp(function()
    if #nextHistory > 0 then
        table.insert(backHistory, path)
        path = table.remove(nextHistory)
        updateList()
    end
end)

basalt.run()