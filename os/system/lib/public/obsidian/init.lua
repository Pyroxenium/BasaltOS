local args = {...}
local obsidianPath = fs.getDir(args[2])

local defaultPath = package.path
local format = "path;/path/?.lua;/path/?/init.lua;"

local main = format:gsub("path", obsidianPath)
local shared = format:gsub("path", fs.getDir(obsidianPath))
package.path = main..shared.."rom/?;"..defaultPath

local function errorHandler(err)
    error("Obsidian Loading Error: " .. tostring(err))
end

local ok, result = pcall(require, "engine")
package.loaded.log = nil

package.path = defaultPath
if not ok then
    errorHandler(result)
else
    return result
end
