local basalt = require("system.libraries.private.basalt")

local main = basalt.createFrame()

local prog = main:addProgram()
prog:execute("rom/programs/shell.lua")

basalt.run()