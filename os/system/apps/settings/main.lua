-- /apps/settings/main.lua
-- Compact Basalt 2.5 settings application.

local basalt = require("basalt")
local app = require("app")
local settings = app.settings
local auth = app.auth
local filesystem = app.filesystem
local registry = app.registry

if not settings then error("Settings API not available") end

local main = basalt.getMainFrame()

local function theme(key, fallback)
    return app.theme(key, fallback)
end

local COLORS = {
    "white", "orange", "magenta", "lightBlue",
    "yellow", "lime", "pink", "gray",
    "lightGray", "cyan", "purple", "blue",
    "brown", "green", "red", "black",
}

local CATEGORY_ORDER = {
    appearance = 1,
    desktop = 2,
    taskbar = 3,
    window = 4,
    startmenu = 5,
    filetypes = 6,
    users = 7,
    system = 8,
}

local background = theme("desktop_bg", colors.white)
local foreground = theme("desktop_fg", colors.black)
local muted = theme("desktop_muted", colors.gray)
local surface = theme("surface", colors.lightGray)
local accent = theme("primary", colors.blue)

main:setBackground(background)

local sidebar = main:addFrame({
    x=1, y=1, width=12, height="{parent.height}",
    background=surface,
})
sidebar:addLabel({
    x=2, y=1, width=10, height=1, text="Categories",
    foreground=foreground, background=surface, disabled=true,
})

local content = main:addFrame({
    x=13, y=1, width="{parent.width - 12}", height="{parent.height - 1}",
    background=background,
})

local status = main:addLabel({
    x=14, y="{parent.height}", width="{parent.width - 14}", height=1,
    text="Changes apply immediately", foreground=muted,
    background=background, disabled=true,
})

local category_buttons = {}
local page = nil
local current_category = nil

local function setStatus(text, color)
    status:setText(tostring(text or ""))
    status:setForeground(color or muted)
end

local function sortedKeys(values)
    local keys = {}
    for key in pairs(values or {}) do keys[#keys + 1] = key end
    table.sort(keys, function(a, b)
        local left = values[a].label or a
        local right = values[b].label or b
        return left:lower() < right:lower()
    end)
    return keys
end

local function save(path, value)
    local valid, err = settings.validate(path, value)
    if not valid then
        setStatus(err or "Invalid value", theme("danger", colors.red))
        return false
    end
    if settings.set(path, value) then
        setStatus("Saved " .. path, theme("success", colors.lime))
        return true
    end
    setStatus("Could not save " .. path, theme("danger", colors.red))
    return false
end

local function selectedIndex(values, current)
    for index, value in ipairs(values) do
        if value == current then return index end
    end
    return 1
end

local function addDropdown(parent, path, values, current, y, color_preview)
    local dropdown = parent:addDropdown({
        x=2, y=y, width="{parent.width - 4}",
        text="Select...", foreground=foreground, background=surface,
        dropBackground=background, dropHeight=6,
        selectionForeground=theme("text", colors.white),
        selectionBackground=accent,
    })
    for _, value in ipairs(values) do dropdown:addItem(value) end
    dropdown:selectItem(selectedIndex(values, current), false)

    local preview = nil
    if color_preview then
        preview = parent:addFrame({
            x="{parent.width - 1}", y=y, width=1, height=1,
            background=colors[current] or colors.black, disabled=true,
        })
    end

    dropdown:onChange(function(_, _, item)
        local value = item and item.text
        if value and save(path, value) and preview then
            preview:setBackground(colors[value] or colors.black)
        end
    end)
end

local function addSetting(parent, category, key, meta, y)
    local path = category .. "." .. key
    local current = settings.get(path)
    parent:addLabel({
        x=2, y=y, width="{parent.width - 3}", height=1,
        text=meta.label or key, foreground=foreground,
        background=background, disabled=true,
    })

    if meta.type == "boolean" then
        parent:addCheckbox({
            x=2, y=y + 1, text="Enabled", checked=current == true,
            foreground=foreground, background=background,
        }):onChange(function(_, checked)
            save(path, checked)
        end)
    elseif meta.type == "choice" then
        addDropdown(parent, path, meta.choices or {}, current, y + 1, false)
    elseif meta.type == "color" then
        addDropdown(parent, path, COLORS, current, y + 1, true)
    elseif meta.type == "number" then
        local input = parent:addInput({
            x=2, y=y + 1, width="{parent.width - 3}", height=1,
            text=tostring(current or ""), foreground=foreground, background=surface,
        })
        input:onEnter(function(self, value)
            local number = tonumber(value or self:getText())
            if not number or not save(path, number) then
                self:setBackground(theme("danger", colors.red))
            else
                self:setBackground(surface)
            end
        end)
    elseif meta.type == "string" or meta.type == "file" then
        local input = parent:addInput({
            x=2, y=y + 1, width="{parent.width - 3}", height=1,
            text=tostring(current or ""), foreground=foreground, background=surface,
        })
        input:onEnter(function(self, value)
            if save(path, value or self:getText()) then self:setBackground(surface) end
        end)
    else
        parent:addLabel({
            x=2, y=y + 1, text=tostring(current),
            foreground=muted, background=background, disabled=true,
        })
    end
end

local showCategory

local function renderFileTypesPage(parent, category)
    parent:addLabel({
        x=2, y=1, width="{parent.width - 11}", height=1,
        text="File Types", foreground=foreground,
        background=background, disabled=true,
    })
    if not filesystem or not registry then
        parent:addLabel({
            x=2, y=3, text="File association services unavailable",
            foreground=theme("danger", colors.red),
            background=background, disabled=true,
        })
        return
    end

    parent:addButton({
        x="{parent.width - 10}", y=1, width=10, height=1,
        text="Reset all", foreground=foreground, background=surface,
    }):setStateStyle("hover", {
        background=theme("warning", colors.orange), foreground=colors.black,
    }):onClick(function()
        local ok, err = filesystem.resetUserAssociations()
        setStatus(
            ok and "File associations reset" or err,
            ok and theme("success", colors.lime) or theme("danger", colors.red)
        )
        if ok then showCategory(category) end
    end)
    parent:addLabel({
        x=2, y=2, width="{parent.width - 3}", height=1,
        text="Choose per-user Open and Edit defaults.",
        foreground=muted, background=background, disabled=true,
    })

    local programs = registry.listPrograms()
    table.sort(programs, function(left, right)
        local left_name = tostring(left.name or left.id):lower()
        local right_name = tostring(right.name or right.id):lower()
        if left_name == right_name then return left.id < right.id end
        return left_name < right_name
    end)

    local function programName(program_id)
        local program = program_id and registry.getProgram(program_id) or nil
        return program and (program.name or program.id) or "None"
    end

    local function addAssociationDropdown(file_type, action, y)
        local system_id = action == "open"
            and file_type.system_app_id or file_type.system_editor_id
        local user_id = action == "open"
            and file_type.user_app_id or file_type.user_editor_id
        local dropdown = parent:addDropdown({
            x=8, y=y, width="{parent.width - 10}",
            text="System default",
            foreground=foreground, background=surface,
            dropBackground=background, dropHeight=7,
            selectionForeground=theme("text", colors.white),
            selectionBackground=accent,
        })
        dropdown:addItem("System default (" .. programName(system_id) .. ")")
        local selected = 1
        for index, program in ipairs(programs) do
            dropdown:addItem((program.name or program.id) .. " [" .. program.id .. "]")
            if program.id == user_id then selected = index + 1 end
        end
        dropdown:selectItem(selected, false)
        dropdown:onChange(function(_, index)
            local ok, err
            if index == 1 then
                ok, err = filesystem.resetUserAssociations(
                    file_type.extension, action
                )
            else
                local program = programs[index - 1]
                if program then
                    ok, err = filesystem.setUserAssociation(
                        file_type.extension, program.id, action
                    )
                end
            end
            setStatus(
                ok and ("Saved ." .. file_type.extension .. " " .. action .. " app")
                    or (err or "Could not save association"),
                ok and theme("success", colors.lime) or theme("danger", colors.red)
            )
        end)
    end

    local y = 4
    for _, file_type in ipairs(filesystem.getFileTypes()) do
        local current = file_type
        parent:addLabel({
            x=2, y=y, width="{parent.width - 3}", height=1,
            text="." .. current.extension,
            foreground=accent, background=background, disabled=true,
        })
        parent:addLabel({
            x=2, y=y + 1, width=5, height=1, text="Open",
            foreground=foreground, background=background, disabled=true,
        })
        addAssociationDropdown(current, "open", y + 1)
        parent:addLabel({
            x=2, y=y + 2, width=5, height=1, text="Edit",
            foreground=foreground, background=background, disabled=true,
        })
        addAssociationDropdown(current, "edit", y + 2)
        y = y + 4
    end
end

local function renderUsersPage(parent, category)
    parent:addLabel({
        x=2, y=1, width="{parent.width - 3}", height=1,
        text="Users", foreground=foreground, background=background, disabled=true,
    })
    if not auth then
        parent:addLabel({x=2, y=3, text="Authentication service unavailable", foreground=theme("danger", colors.red), background=background, disabled=true})
        return
    end

    local current = auth.getCurrentUserProfile()
    local is_admin = auth.isAdmin()
    parent:addLabel({
        x=2, y=2, width="{parent.width - 3}", height=1,
        text=current and ("Signed in as " .. current.display_name .. " [" .. current.role .. "]") or "No active account",
        foreground=muted, background=background, disabled=true,
    })

    local users = auth.listUsers()
    local y = 4
    parent:addLabel({x=2, y=y, text="Accounts", foreground=foreground, background=background, disabled=true})
    y = y + 1
    local pending_delete = nil
    for _, profile in ipairs(users) do
        local account = profile
        local suffix = account.username == (current and current.username) and " (you)" or ""
        parent:addLabel({
            x=2, y=y, width="{parent.width - 10}", height=1,
            text=account.display_name .. " [" .. account.role .. "]" .. suffix,
            foreground=foreground, background=surface, disabled=true,
        })
        if is_admin and current and account.username ~= current.username then
            parent:addButton({
                x="{parent.width - 7}", y=y, width=7, height=1,
                text="Delete", foreground=theme("danger", colors.red), background=surface,
            }):setStateStyle("hover", {
                foreground=theme("text", colors.white), background=theme("danger", colors.red),
            }):onClick(function(self)
                if pending_delete ~= account.username then
                    pending_delete = account.username
                    self:setText("Confirm")
                    setStatus("Delete " .. account.username .. "? Files will be kept.", theme("warning", colors.orange))
                    return
                end
                local ok, err = auth.deleteUser(account.username)
                if not ok then setStatus(err, theme("danger", colors.red)) return end
                setStatus("Deleted account " .. account.username .. "; files kept", theme("success", colors.lime))
                showCategory(category)
            end)
        end
        y = y + 1
    end

    y = y + 1
    parent:addLabel({x=2, y=y, text="Change my password", foreground=foreground, background=background, disabled=true})
    y = y + 1
    local old_password = parent:addInput({
        x=2, y=y, width="{parent.width - 3}", height=1, text="",
        foreground=foreground, background=surface, replaceChar="*",
    })
    y = y + 1
    local new_password = parent:addInput({
        x=2, y=y, width="{parent.width - 3}", height=1, text="",
        foreground=foreground, background=surface, replaceChar="*",
    })
    y = y + 1
    parent:addButton({
        x=2, y=y, width="{parent.width - 3}", height=1,
        text="Change password", foreground=theme("text", colors.white), background=accent,
    }):onClick(function()
        if not current then return end
        local ok, err = auth.changePassword(current.username, old_password:getText(), new_password:getText())
        old_password:setText("")
        new_password:setText("")
        setStatus(ok and "Password changed" or err, ok and theme("success", colors.lime) or theme("danger", colors.red))
    end)

    if not is_admin then return end
    y = y + 2
    parent:addLabel({x=2, y=y, text="Create account", foreground=foreground, background=background, disabled=true})
    y = y + 1
    local username = parent:addInput({
        x=2, y=y, width="{parent.width - 3}", height=1, text="",
        foreground=foreground, background=surface,
    })
    y = y + 1
    local password = parent:addInput({
        x=2, y=y, width="{parent.width - 3}", height=1, text="",
        foreground=foreground, background=surface, replaceChar="*",
    })
    y = y + 1
    local role = "user"
    local role_dropdown = parent:addDropdown({
        x=2, y=y, width="{parent.width - 3}", text="Role",
        foreground=foreground, background=surface,
        dropBackground=background, selectionForeground=theme("text", colors.white),
        selectionBackground=accent, dropHeight=2,
    })
    role_dropdown:addItem("user")
    role_dropdown:addItem("admin")
    role_dropdown:selectItem(1, false)
    role_dropdown:onChange(function(_, index)
        role = index == 2 and "admin" or "user"
    end)
    y = y + 1
    parent:addButton({
        x=2, y=y, width="{parent.width - 3}", height=1,
        text="Create user", foreground=theme("text", colors.white), background=accent,
    }):onClick(function()
        local ok, result = auth.createUser(username:getText(), password:getText(), {role=role})
        if not ok then setStatus(result, theme("danger", colors.red)) return end
        setStatus("Created " .. result.username, theme("success", colors.lime))
        showCategory(category)
    end)
end

showCategory = function(category)
    current_category = category.id
    if page then page:destroy() end

    for id, button in pairs(category_buttons) do
        button:setBackground(id == current_category and accent or surface)
        button:setForeground(id == current_category and theme("text", colors.white) or foreground)
    end

    page = content:addFrame({
        x=1, y=1, width="{parent.width}", height="{parent.height}",
        background=background, scrollable=true, scrollbar="auto",
        scrollbarColor=surface, scrollbarThumbColor=muted,
    })
    if category.id == "users" then
        renderUsersPage(page, category)
        return
    elseif category.id == "filetypes" then
        renderFileTypesPage(page, category)
        return
    end
    page:addLabel({
        x=2, y=1, width="{parent.width - 11}", height=1,
        text=category.label, foreground=foreground,
        background=background, disabled=true,
    })
    page:addButton({
        x="{parent.width - 7}", y=1, width=7, height=1,
        text="Reset", foreground=foreground, background=surface,
    }):setStateStyle("hover", {
        background=theme("warning", colors.orange), foreground=colors.black,
    }):onClick(function()
        if settings.resetCategory(category.id) then
            setStatus(category.label .. " reset", theme("success", colors.lime))
            showCategory(category)
        end
    end)

    local visible = settings.getVisibleSettings(category.id)
    local y = 3
    for _, key in ipairs(sortedKeys(visible)) do
        addSetting(page, category.id, key, visible[key], y)
        y = y + 3
    end
end

local categories = settings.getCategories(true)
if auth then categories[#categories + 1] = {id="users", label="Users"} end
table.sort(categories, function(a, b)
    local left = CATEGORY_ORDER[a.id] or 100
    local right = CATEGORY_ORDER[b.id] or 100
    if left == right then return a.label < b.label end
    return left < right
end)

for index, category in ipairs(categories) do
    local category_copy = category
    local button = sidebar:addButton({
        x=1, y=index + 2, width=12, height=1,
        text=category.label, foreground=foreground, background=surface,
    })
    button:setStateStyle("hover", {background=background, foreground=foreground})
    button:onClick(function() showCategory(category_copy) end)
    category_buttons[category.id] = button
end

if categories[1] then showCategory(categories[1]) end

basalt.run()
