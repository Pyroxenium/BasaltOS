






local EAGER={
"system/boot/system.bpk",
"system/boot/basalt.bpk",
}

local width,height=term.getSize()
local colored=term.isColor and term.isColor()
local bar_width=math.max(10,math.min(30,width-8))
local bar_x=math.floor((width-bar_width)/2)+1
local middle=math.floor(height/2)

local function centered(y,text,foreground)
term.setCursorPos(1,y)
term.setBackgroundColor(colors.black)
term.clearLine()
term.setTextColor(foreground or colors.white)
term.setCursorPos(math.max(1,math.floor((width-#text)/2)+1),y)
term.write(text)
end

local function drawBar(fraction)
if fraction<0 then fraction=0 elseif fraction>1 then fraction=1 end
local filled=math.floor(bar_width*fraction+0.5)
term.setCursorPos(bar_x,middle)
term.setBackgroundColor(colored and colors.blue or colors.white)
term.write((" "):rep(filled))
term.setBackgroundColor(colors.gray)
term.write((" "):rep(bar_width-filled))
term.setBackgroundColor(colors.black)
end

local function status(text)
centered(middle+2,text,colors.lightGray)
end

local function now()
return os.epoch and os.epoch("utc")or 0
end

local function boot()
local started=now()
local bpk=dofile("system/boot/bpk.lua")
bpk.install()
_G.bpk=bpk
local native=bpk.native

local function isFile(path)
return native.exists(path)and not native.isDir(path)
end

local eager,eager_paths,total={},{},0
for _,path in ipairs(EAGER)do
if isFile(path)then
local package=assert(bpk.mount(path,{eager=true}))
eager[#eager+1]=package
eager_paths[package.path]=true
total=total+package.original_length
end
end

if native.isDir("system/boot")then
for _,name in ipairs(native.list("system/boot"))do
local path=fs.combine("system/boot",name)
if name:match("%.bpk$")and isFile(path)and not eager_paths[path]then
assert(bpk.mount(path))
end
end
end



local function mountApps(apps_dir)
if not native.isDir(apps_dir)then return end
for _,app in ipairs(native.list(apps_dir))do
local path=fs.combine(fs.combine(apps_dir,app),"app.bpk")
if isFile(path)then bpk.mount(path)end
end
end

mountApps("system/apps")
mountApps("apps")

if#eager>0 then
term.setBackgroundColor(colors.black)
term.clear()
term.setCursorBlink(false)
centered(middle-2,"BasaltOS",colors.white)
drawBar(0)

local done=0
for _,package in ipairs(eager)do
status("Loading "..package.name)
local base=done
bpk.unpack(package,function(_,bytes)
drawBar((base+bytes)/total)

os.queueEvent("bpk_breath")
os.pullEvent("bpk_breath")
end)
done=base+package.original_length
end

drawBar(1)
status("Starting")
end
bpk.boot_ms=now()-started
end

local ok,message=pcall(boot)
if not ok then
term.setBackgroundColor(colors.black)
term.clear()
term.setCursorPos(1,1)
term.setTextColor(colors.red)
print("BasaltOS could not be loaded.")
term.setTextColor(colors.white)
print(tostring(message))
print("\nReinstall BasaltOS to repair the system files.")
return
end

shell.run("system/main.lua")