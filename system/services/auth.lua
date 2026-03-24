-- /services/auth.lua
-- Authentication service: User management and login system

local api_factory = require("core.api")
local config = require("core.config")
local event = require("core.event")
local service = require("core.service")
local path = require("core.path")

local api = api_factory.new()

local current_user = nil
local is_logged_in = false

local function hashPassword(password)
    local hash = 0
    for i = 1, #password do
        hash = (hash * 31 + string.byte(password, i)) % 2147483647
    end
    return tostring(hash)
end

local function ensureDefaultUser()
    local users = config.get("auth.users", {})

    if not next(users) then
        users["admin"] = {
            password = hashPassword("admin"),
            created = os.epoch("utc")
        }
        config.set("auth.users", users)
        config.save()

        print("  [AUTH] Default user 'admin' created (password: admin)")
    end
end

function api.public.init()
    ensureDefaultUser()

    -- Register login screen with UI manager
    local ui = service.getService("ui")
    if ui then
        ui.registerScreen("login", api.private.buildLoginScreen)
    end

    event.on("system.boot_complete", function()
        local ui = service.getService("ui")
        if ui then
            ui.switchScreen("login")
        end
    end)
end

local function verifyCredentials(username, password)
    local users = config.get("auth.users", {})
    local user = users[username]

    if not user then
        return false, "User not found"
    end

    local hashed = hashPassword(password)
    if user.password ~= hashed then
        return false, "Invalid password"
    end

    return true
end

function api.public.login(username, password)
    local success, err = verifyCredentials(username, password)

    if success then
        current_user = username
        is_logged_in = true

        local users = config.get("auth.users", {})
        users[username].last_login = os.epoch("utc")
        config.set("auth.users", users)
        config.save()

        config.setCurrentUser(username)
        path.setCurrentUser(username)

        event.dispatch("user.login", username)

        return true
    else
        return false, err
    end
end

function api.public.logout()
    if is_logged_in then
        local username = current_user
        current_user = nil
        is_logged_in = false

        config.setCurrentUser(nil)

        path.setCurrentUser(nil)

        event.dispatch("user.logout", username)

        return true
    end
    return false
end

function api.public.getCurrentUser()
    return current_user
end

function api.public.isLoggedIn()
    return is_logged_in
end

function api.public.createUser(username, password)
    if not username or not password then
        return false, "Username and password required"
    end

    if #username < 3 then
        return false, "Username must be at least 3 characters"
    end

    if #password < 4 then
        return false, "Password must be at least 4 characters"
    end

    local users = config.get("auth.users", {})

    if users[username] then
        return false, "User already exists"
    end

    users[username] = {
        password = hashPassword(password),
        created = os.epoch("utc")
    }

    config.set("auth.users", users)
    config.save()

    return true
end

function api.private.buildLoginScreen(frame)
    frame:setBackground(colors.lightGray)

    frame:addLabel()
        :setText("BasaltOS Login")
        :setPosition(2, 2)
        :setForeground(colors.gray)

    frame:addLabel()
        :setText("Username:")
        :setPosition(2, 5)
        :setForeground(colors.gray)

    local usernameInput = frame:addInput()
        :setPosition(2, 6)
        :setSize(20, 1)
        :setBackground(colors.white)
        :setForeground(colors.black)
        :setText("admin") -- DEV: prefill

    frame:addLabel()
        :setText("Password:")
        :setPosition(2, 8)
        :setForeground(colors.gray)

    local passwordInput = frame:addInput()
        :setPosition(2, 9)
        :setSize(20, 1)
        :setBackground(colors.white)
        :setForeground(colors.black)
        :setText("admin") -- DEV: prefill

    local errorLabel = frame:addLabel()
        :setPosition(2, 11)
        :setForeground(colors.red)
        :setText("")

    local loginButton = frame:addButton()
        :setText("Login")
        :setPosition(2, 13)
        :setSize(10, 1)
        :setBackground(colors.blue)
        :setForeground(colors.white)

    local function attemptLogin()
        local username = usernameInput:getText()
        local password = passwordInput:getText()

        if username == "" or password == "" then
            errorLabel:setText("Please enter username and password")
            return
        end

        local success, err = api.public.login(username, password)

        if success then
            errorLabel:setForeground(colors.green)
            errorLabel:setText("Login successful!")
            os.sleep(0.5)
            local ui = service.getService("ui")
            if ui then
                ui.switchScreen("desktop", username)
            end
        else
            errorLabel:setForeground(colors.red)
            errorLabel:setText("Error: " .. (err or "Login failed"))
            passwordInput:setText("")
        end
    end

    loginButton:onClick(function()
        attemptLogin()
    end)

    passwordInput:onKey(function(self, key)
        if key == keys.enter then
            attemptLogin()
        end
    end)

    return frame
end

return api