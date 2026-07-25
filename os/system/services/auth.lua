-- /services/auth.lua
-- Authentication, local user profiles and login/setup UI.

local api_factory = require("core.api")
local config = require("core.config")
local event = require("core.event")
local service = require("core.service")
local path = require("core.path")
local ui_helpers = require("core.ui_helpers")

local api = api_factory.new()

local current_user = nil
local is_logged_in = false
local HASH_VERSION = 2

local function theme(key, fallback)
    return config.get("theme." .. key, fallback)
end

local function trim(value)
    return tostring(value or ""):match("^%s*(.-)%s*$")
end

local function normalizeUsername(username)
    return trim(username):lower()
end

local function validateUsername(username)
    if #username < 3 or #username > 20 then
        return false, "Username must be 3-20 characters"
    end
    if not username:match("^[a-z0-9][a-z0-9_-]*$") then
        return false, "Use letters, numbers, _ or -"
    end
    return true
end

local function validatePassword(password)
    if type(password) ~= "string" or #password < 4 then
        return false, "Password must be at least 4 characters"
    end
    if #password > 128 then return false, "Password is too long" end
    return true
end

-- Compatibility with accounts created by the old auth service.
local function legacyHash(password)
    local hash = 0
    for i = 1, #password do
        hash = (hash * 31 + string.byte(password, i)) % 2147483647
    end
    return tostring(hash)
end

-- Salted local password hash. CC:Tweaked does not ship a password KDF, so the
-- rounds mainly prevent storing/reusing the old unsalted value verbatim.
local function passwordHash(password, salt)
    local hash = 104729
    local source = tostring(salt) .. "\0" .. tostring(password)
    for round = 1, 384 do
        for i = 1, #source do
            hash = (hash * 131 + string.byte(source, i) + round + i) % 2147483647
        end
        hash = (hash * 65599 + round) % 2147483647
    end
    return tostring(hash)
end

local function makeSalt(username)
    local computer_id = os.getComputerID and os.getComputerID() or 0
    local epoch = os.epoch and os.epoch("utc") or math.floor(os.clock() * 1000)
    return table.concat({tostring(computer_id), tostring(epoch), username}, ":")
end

local function getUsers()
    local users = config.getSystem and config.getSystem("auth.users", {})
        or config.get("auth.users", {})
    return type(users) == "table" and users or {}
end

local function saveUsers(users)
    config.set("auth.users", users)
    return config.save()
end

local function publicProfile(username, profile)
    return {
        username = username,
        display_name = tostring(profile.display_name or username),
        role = profile.role == "admin" and "admin" or "user",
        created = profile.created,
        last_login = profile.last_login,
    }
end

local function countAdmins(users)
    local count = 0
    for _, profile in pairs(users) do
        if type(profile) == "table" and profile.role == "admin" then count = count + 1 end
    end
    return count
end

local function normalizeProfiles()
    local source = getUsers()
    local normalized = {}
    local changed = false

    for stored_name, stored_profile in pairs(source) do
        local username = normalizeUsername(stored_name)
        local valid = validateUsername(username)
        if valid and type(stored_profile) == "table" and not normalized[username] then
            local profile = stored_profile
            if stored_name ~= username then changed = true end
            profile.username = username
            profile.display_name = trim(profile.display_name) ~= ""
                and trim(profile.display_name) or stored_name
            if profile.role ~= "admin" and profile.role ~= "user" then
                profile.role = username == "admin" and "admin" or "user"
                changed = true
            end
            normalized[username] = profile
        else
            changed = true
        end
    end

    if next(normalized) and countAdmins(normalized) == 0 then
        local names = {}
        for username in pairs(normalized) do names[#names + 1] = username end
        table.sort(names)
        normalized[names[1]].role = "admin"
        changed = true
    end

    if changed then saveUsers(normalized) end
    return normalized
end

local function setPassword(profile, username, password)
    profile.salt = makeSalt(username)
    profile.password_hash = passwordHash(password, profile.salt)
    profile.hash_version = HASH_VERSION
    profile.password = nil
end

local function verifyProfile(profile, password)
    if tonumber(profile.hash_version) == HASH_VERSION
        and type(profile.salt) == "string" and type(profile.password_hash) == "string" then
        return profile.password_hash == passwordHash(password, profile.salt)
    end
    return type(profile.password) == "string" and profile.password == legacyHash(password)
end

local function verifyCredentials(username, password)
    username = normalizeUsername(username)
    local users = getUsers()
    local profile = users[username]
    if not profile or not verifyProfile(profile, password) then
        return false, "Wrong username or password"
    end
    return true, nil, username, profile, users
end

local function initializeUserHome(username)
    local userfs = service.getService("userfs")
    if userfs and userfs.initializeUser then
        return userfs.initializeUser(username)
    end
    return false, "User filesystem service unavailable"
end

local function deferDesktop(username)
    local ui = service.getService("ui")
    if ui and ui.deferDispatch then
        ui.deferDispatch("auth.login_complete", username)
    else
        event.dispatch("auth.login_complete", username)
    end
end

function api.public.init()
    local users = normalizeProfiles()
    for username in pairs(users) do initializeUserHome(username) end

    local ui = service.getService("ui")
    if not ui then error("Auth requires the UI service") end
    local registered, err = ui.registerScreen("login", api.private.buildLoginScreen)
    if not registered and err ~= "Screen already registered" then error(err) end

    event.on("system.boot_complete", function()
        ui.switchScreen("login")
    end)
    event.on("auth.login_complete", function(username)
        if is_logged_in and current_user == username then
            ui.switchScreen("desktop", username)
        end
    end)
    event.on("auth.show_login", function()
        ui.switchScreen("login")
    end)
end

function api.public.setupRequired()
    return next(getUsers()) == nil
end

function api.public.listUsers()
    local result = {}
    for username, profile in pairs(getUsers()) do
        if type(profile) == "table" then result[#result + 1] = publicProfile(username, profile) end
    end
    table.sort(result, function(left, right)
        return left.display_name:lower() < right.display_name:lower()
    end)
    return result
end

function api.public.getUser(username)
    username = normalizeUsername(username)
    local profile = getUsers()[username]
    return profile and publicProfile(username, profile) or nil
end

function api.public.getCurrentUser()
    return current_user
end

function api.public.getCurrentUserProfile()
    return current_user and api.public.getUser(current_user) or nil
end

function api.public.isLoggedIn()
    return is_logged_in
end

function api.public.isAdmin()
    local profile = current_user and getUsers()[current_user]
    return profile and profile.role == "admin" or false
end

function api.public.login(username, password)
    if is_logged_in then return false, "A user is already logged in" end
    local success, err, canonical, profile, users = verifyCredentials(username, password)
    if not success then return false, err end

    -- Upgrade the old admin/admin-era hash only after successful verification.
    if tonumber(profile.hash_version) ~= HASH_VERSION then setPassword(profile, canonical, password) end
    profile.last_login = os.epoch and os.epoch("utc") or 0
    saveUsers(users)

    initializeUserHome(canonical)
    current_user = canonical
    is_logged_in = true
    config.setCurrentUser(canonical)
    path.setCurrentUser(canonical)
    event.dispatch("user.login", canonical, publicProfile(canonical, profile))
    return true, publicProfile(canonical, profile)
end

function api.public.logout()
    if not is_logged_in then return false, "No user logged in" end
    local username = current_user
    current_user = nil
    is_logged_in = false
    config.setCurrentUser(nil)
    path.setCurrentUser(nil)
    event.dispatch("user.logout", username)
    return true
end

function api.public.createUser(username, password, options)
    username = normalizeUsername(username)
    local valid, err = validateUsername(username)
    if not valid then return false, err end
    valid, err = validatePassword(password)
    if not valid then return false, err end

    local users = getUsers()
    local first_user = next(users) == nil
    if not first_user and not api.public.isAdmin() then
        return false, "Administrator permission required"
    end
    if users[username] then return false, "User already exists" end

    options = type(options) == "table" and options or {}
    local role = first_user and "admin" or (options.role == "admin" and "admin" or "user")
    local profile = {
        username = username,
        display_name = trim(options.display_name) ~= "" and trim(options.display_name) or username,
        role = role,
        created = os.epoch and os.epoch("utc") or 0,
    }
    setPassword(profile, username, password)
    users[username] = profile
    if not saveUsers(users) then return false, "Could not save user database" end

    local home_ok, home_err = initializeUserHome(username)
    if not home_ok then
        users[username] = nil
        saveUsers(users)
        return false, home_err or "Could not create user home"
    end
    local public = publicProfile(username, profile)
    event.dispatch("user.created", username, public)
    return true, public
end

function api.public.changePassword(username, current_password, new_password)
    username = normalizeUsername(username)
    local valid, err = validatePassword(new_password)
    if not valid then return false, err end
    if not is_logged_in then return false, "No user logged in" end

    local users = getUsers()
    local profile = users[username]
    if not profile then return false, "User not found" end

    if username == current_user then
        if not verifyProfile(profile, current_password or "") then
            return false, "Current password is incorrect"
        end
    elseif not api.public.isAdmin() then
        return false, "Administrator permission required"
    end

    setPassword(profile, username, new_password)
    if not saveUsers(users) then return false, "Could not save user database" end
    event.dispatch("user.password_changed", username)
    return true
end

function api.public.deleteUser(username)
    username = normalizeUsername(username)
    if not api.public.isAdmin() then return false, "Administrator permission required" end
    if username == current_user then return false, "You cannot delete the active account" end

    local users = getUsers()
    local profile = users[username]
    if not profile then return false, "User not found" end
    if profile.role == "admin" and countAdmins(users) <= 1 then
        return false, "The last administrator cannot be deleted"
    end

    users[username] = nil
    if not saveUsers(users) then return false, "Could not save user database" end
    -- Account deletion deliberately preserves users/<name> so files can be recovered.
    event.dispatch("user.deleted", username)
    return true
end

local function makePanel(frame, height)
    local screen_width, screen_height = frame:getSize()
    local width = math.max(24, math.min(34, screen_width - 4))
    height = math.max(12, math.min(height, screen_height - 2))
    frame:setBackground(theme("desktop_bg", colors.white))
    local panel = frame:addFrame({
        x=math.max(1, math.floor((screen_width - width) / 2) + 1),
        y=math.max(1, math.floor((screen_height - height) / 2) + 1),
        width=width, height=height,
        background=theme("surface", colors.lightGray),
    })
    panel:addFrame({
        x=1, y=1, width="{parent.width}", height=2,
        background=theme("primary", colors.blue), disabled=true,
    })
    panel:addLabel({
        x=2, y=1, text="BasaltOS", foreground=theme("text", colors.white),
        background=theme("primary", colors.blue), disabled=true,
    })
    ui_helpers.addBorder(panel, theme("primary", colors.blue), {
        innerColor=theme("surface", colors.lightGray),
        topStyle="solid", name="login_panel_border",
    })
    return panel
end

function api.private.buildSetupScreen(frame)
    local panel = makePanel(frame, 17)
    panel:addLabel({x=2, y=2, text="Create the first administrator", foreground=theme("text", colors.white), background=theme("primary", colors.blue), disabled=true})
    panel:addLabel({x=2, y=4, text="Username", foreground=theme("desktop_fg", colors.black), background=theme("surface", colors.lightGray), disabled=true})
    local username = panel:addInput({x=2, y=5, width="{parent.width - 3}", height=1, background=colors.white, foreground=colors.black})
    panel:addLabel({x=2, y=7, text="Password", foreground=theme("desktop_fg", colors.black), background=theme("surface", colors.lightGray), disabled=true})
    local password = panel:addInput({x=2, y=8, width="{parent.width - 3}", height=1, background=colors.white, foreground=colors.black, replaceChar="*"})
    panel:addLabel({x=2, y=10, text="Confirm password", foreground=theme("desktop_fg", colors.black), background=theme("surface", colors.lightGray), disabled=true})
    local confirmation = panel:addInput({x=2, y=11, width="{parent.width - 3}", height=1, background=colors.white, foreground=colors.black, replaceChar="*"})
    local status = panel:addLabel({x=2, y=13, width="{parent.width - 3}", height=1, text="No default password will be created.", foreground=theme("desktop_muted", colors.gray), background=theme("surface", colors.lightGray), disabled=true})
    local create = panel:addButton({x=2, y=15, width="{parent.width - 3}", height=1, text="Create administrator", background=theme("primary", colors.blue), foreground=theme("text", colors.white)})

    local function submit()
        local name, secret, repeated = username:getText(), password:getText(), confirmation:getText()
        if secret ~= repeated then
            status:setForeground(theme("danger", colors.red)):setText("Passwords do not match")
            confirmation:setText("")
            return
        end
        local created, result = api.public.createUser(name, secret, {role="admin"})
        if not created then
            status:setForeground(theme("danger", colors.red)):setText(tostring(result))
            return
        end
        local logged_in, login_err = api.public.login(result.username, secret)
        if not logged_in then
            status:setForeground(theme("danger", colors.red)):setText(tostring(login_err))
            return
        end
        status:setForeground(theme("success", colors.lime)):setText("Account created")
        deferDesktop(result.username)
    end
    create:onClick(submit)
    confirmation:onKey(function(_, key) if key == keys.enter then submit() end end)
    username:focus()
    return frame
end

function api.private.buildLoginScreen(frame)
    if api.public.setupRequired() then return api.private.buildSetupScreen(frame) end

    local accounts = api.public.listUsers()
    local panel = makePanel(frame, 14)
    panel:addLabel({x=2, y=2, text="Sign in", foreground=theme("text", colors.white), background=theme("primary", colors.blue), disabled=true})
    panel:addLabel({x=2, y=4, text="Account", foreground=theme("desktop_fg", colors.black), background=theme("surface", colors.lightGray), disabled=true})
    local account = panel:addDropdown({
        x=2, y=5, width="{parent.width - 3}", text="Select account",
        background=colors.white, foreground=colors.black,
        dropBackground=theme("menu_bg", colors.white),
        selectionBackground=theme("primary", colors.blue),
        selectionForeground=theme("text", colors.white),
        dropHeight=math.min(5, #accounts),
    })
    for _, profile in ipairs(accounts) do
        account:addItem({text=profile.display_name .. "  @" .. profile.username})
    end
    account:selectItem(1, false)

    panel:addLabel({x=2, y=7, text="Password", foreground=theme("desktop_fg", colors.black), background=theme("surface", colors.lightGray), disabled=true})
    local password = panel:addInput({x=2, y=8, width="{parent.width - 3}", height=1, background=colors.white, foreground=colors.black, replaceChar="*"})
    local status = panel:addLabel({x=2, y=10, width="{parent.width - 3}", height=1, text="", foreground=theme("danger", colors.red), background=theme("surface", colors.lightGray), disabled=true})
    local login = panel:addButton({x=2, y=12, width="{parent.width - 3}", height=1, text="Sign in", background=theme("primary", colors.blue), foreground=theme("text", colors.white)})
    local busy = false

    local function submit()
        if busy then return end
        local selected = account:getSelectedIndex() or 1
        local profile = accounts[selected]
        if not profile then status:setText("Select an account") return end
        if password:getText() == "" then status:setText("Enter your password") return end
        busy = true
        local success, result = api.public.login(profile.username, password:getText())
        if not success then
            busy = false
            password:setText("")
            status:setForeground(theme("danger", colors.red)):setText(tostring(result))
            password:focus()
            return
        end
        status:setForeground(theme("success", colors.lime)):setText("Welcome, " .. result.display_name)
        deferDesktop(result.username)
    end
    login:onClick(submit)
    password:onKey(function(_, key) if key == keys.enter then submit() end end)
    password:focus()
    return frame
end

return api
