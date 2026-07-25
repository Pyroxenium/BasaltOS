-- PineStore for BasaltOS
-- Community project browser and visible, confirmed command installer.

local basalt = require("basalt")
local app = require("app")
local catalog = require("catalog")
local project_store = require("projects")

local API_URL = "https://pinestore.cc/api/projects"
local DOWNLOAD_LOG_URL = "https://pinestore.cc/api/log/download"
local CACHE_SECONDS = 300
local PAGE_SIZE = 40
local SIDEBAR_WIDTH = 13

local function theme(key, fallback)
    return app.theme(key, fallback)
end

local C = {
    background=theme("menu_bg", colors.white),
    foreground=theme("menu_fg", colors.black),
    muted=theme("menu_muted", colors.gray),
    surface=theme("surface", colors.lightGray),
    primary=theme("primary", colors.blue),
    accent_text=theme("text", colors.white),
    accent_muted=theme("text_dim", colors.lightGray),
    pressed=theme("btn_clicked", colors.cyan),
    border=theme("border", colors.gray),
    success=theme("success", colors.lime),
    danger=theme("danger", colors.red),
    warning=theme("warning", colors.orange),
}

local CATEGORY_ORDER = {
    "featured", "all", "games", "utilities", "libraries", "systems", "other",
}
local CATEGORY_LABEL = {
    featured="Featured", all="All Projects", games="Games",
    utilities="Utilities", libraries="Libraries", systems="Systems", other="Other",
}
local CATEGORY_MARKER = {
    games="G", utilities="U", libraries="L", systems="S", other="P",
}
local CATEGORY_COLOR = {
    games=colors.red, utilities=colors.cyan, libraries=colors.purple,
    systems=colors.orange, other=colors.green,
}

local main = basalt.getMainFrame()
main:setBackground(C.background)

local selected_category = "featured"
local search_query = ""
local projects = {}
local filtered_projects = {}
local cache_time = nil
local loading = false
local visible_limit = PAGE_SIZE
local selected_project = nil
local content_elements = {}
local category_buttons = {}
local installer_layer = nil

local renderCatalog
local renderDetail
local refreshCatalog

local function fitText(value, width)
    value = tostring(value or "")
    width = math.max(0, math.floor(tonumber(width) or 0))
    if #value <= width then return value end
    if width <= 2 then return (".."):sub(1, width) end
    return value:sub(1, width - 2) .. ".."
end

local function compactNumber(value)
    value = math.max(0, tonumber(value) or 0)
    if value >= 1000000 then return string.format("%.1fm", value / 1000000) end
    if value >= 1000 then return string.format("%.1fk", value / 1000) end
    return tostring(math.floor(value))
end

local function formatDate(epoch)
    epoch = tonumber(epoch) or 0
    if epoch <= 0 or not os.date then return "Unknown" end
    if epoch > 100000000000 then epoch = math.floor(epoch / 1000) end
    local ok, result = pcall(os.date, "%Y-%m-%d", epoch)
    return ok and result or "Unknown"
end

local function wrapText(value, width)
    width = math.max(1, math.floor(tonumber(width) or 1))
    local result, line = {}, ""
    for word in tostring(value or ""):gmatch("%S+") do
        if #word > width then
            if line ~= "" then result[#result + 1], line = line, "" end
            while #word > width do
                result[#result + 1] = word:sub(1, width)
                word = word:sub(width + 1)
            end
        end
        if word ~= "" then
            if line == "" then line = word
            elseif #line + #word + 1 <= width then line = line .. " " .. word
            else result[#result + 1], line = line, word end
        end
    end
    if line ~= "" then result[#result + 1] = line end
    if #result == 0 then result[1] = "" end
    return result
end

local function notify(title, message, kind)
    if app.notification and app.notification.show then
        app.notification.show(title, tostring(message or ""), kind or "info")
    end
end

local function getReceipt(project)
    return project_store.load(app.userfs, project)
end

local function receiptAppInstalled(receipt)
    return receipt and app.registry and app.registry.hasProgram
        and app.registry.hasProgram(receipt.app_id) == true
end

local function appCategory(category)
    if category == "games" then return "games" end
    if category == "utilities" then return "utilities" end
    return "other"
end

local function getLibrary(project)
    return app.libraries and app.libraries.get
        and app.libraries.get(project.id) or nil
end

local function defaultModuleName(path, project)
    local name = fs.getName(tostring(path or ""))
    name = name:gsub("%.[Ll][Uu][Aa]$", "")
    name = name:gsub("[^%w_]", "_")
    if name == "" then
        name = tostring(project.name or "library"):lower():gsub("[^%w_]", "_")
    end
    if name:match("^[%d]") then name = "_" .. name end
    return name
end

local function clearContent()
    for _, element in ipairs(content_elements) do
        element:destroy()
    end
    content_elements = {}
end

local sidebar = main:addFrame({
    x=1, y=1, width=SIDEBAR_WIDTH, height="{parent.height}",
    background=C.surface,
})
sidebar:addFrame({
    x=1, y=1, width=1, height="{parent.height}",
    background=C.primary, disabled=true,
})
sidebar:addLabel({
    x=3, y=2, width=SIDEBAR_WIDTH - 3, height=1,
    text="PineStore", foreground=C.foreground,
    background=false, disabled=true,
})
sidebar:addLabel({
    x=3, y=3, width=SIDEBAR_WIDTH - 3, height=1,
    text="CC:T projects", foreground=C.muted,
    background=false, disabled=true,
})
local count_label = sidebar:addLabel({
    x=3, y="{parent.height - 1}", width=SIDEBAR_WIDTH - 3, height=1,
    text="", foreground=C.muted, background=false, disabled=true,
})

local toolbar = main:addFrame({
    x=SIDEBAR_WIDTH + 1, y=1,
    width="{parent.width - " .. SIDEBAR_WIDTH .. "}", height=3,
    background=C.background,
})
toolbar:addLabel({
    x=2, y=1, width=8, height=1, text="Discover",
    foreground=C.primary, background=C.background, disabled=true,
})
local status_label = toolbar:addLabel({
    x=11, y=1, width="{parent.width - 16}", height=1, text="",
    foreground=C.muted, background=C.background, disabled=true,
})
local refresh_button = toolbar:addButton({
    x="{parent.width - 3}", y=1, width=3, height=1, text="F5",
    foreground=C.foreground, background=C.surface,
})
refresh_button:setStateStyle("hover", {background=C.primary, foreground=C.accent_text})
refresh_button:setStateStyle("pressed", {background=C.pressed, foreground=C.accent_text})

toolbar:addLabel({
    x=2, y=2, width=1, height=1, text=">",
    foreground=C.primary, background=C.background, disabled=true,
})
local search_input = toolbar:addInput({
    x=4, y=2, width="{parent.width - 5}", height=1,
    placeholder="Search projects, authors, tags...",
    foreground=C.foreground, background=C.surface,
})
toolbar:addFrame({
    x=1, y=3, width="{parent.width}", height=1,
    background=C.border, disabled=true,
})

local content = main:addFrame({
    x=SIDEBAR_WIDTH + 1, y=4,
    width="{parent.width - " .. SIDEBAR_WIDTH .. "}",
    height="{parent.height - 3}",
    background=C.background, scrollable=true, scrollbar="auto",
})

local detail = main:addFrame({
    x=SIDEBAR_WIDTH + 1, y=1, z=20,
    width="{parent.width - " .. SIDEBAR_WIDTH .. "}",
    height="{parent.height}",
    background=C.background, scrollable=true, scrollbar="auto", visible=false,
})
local detail_elements = {}

local function updateCategoryButtons()
    for id, button in pairs(category_buttons) do
        local active = id == selected_category
        button:setBackground(active and C.primary or C.surface)
        button:setForeground(active and C.accent_text or C.foreground)
    end
end

local function selectCategory(category)
    selected_category = category
    visible_limit = PAGE_SIZE
    detail:setVisible(false)
    selected_project = nil
    updateCategoryButtons()
    content:scrollTo(0, 0)
    renderCatalog()
end

for index, category in ipairs(CATEGORY_ORDER) do
    local captured = category
    local button = sidebar:addButton({
        x=3, y=4 + index,
        width=SIDEBAR_WIDTH - 3, height=1,
        text=fitText(CATEGORY_LABEL[category], SIDEBAR_WIDTH - 3),
        foreground=C.foreground, background=C.surface,
    })
    button:setStateStyle("hover", {background=C.background, foreground=C.foreground})
    button:setStateStyle("pressed", {background=C.pressed, foreground=C.accent_text})
    button:onClick(function(_, mouse_button)
        if mouse_button == 1 then selectCategory(captured) end
    end)
    category_buttons[category] = button
end

local function addMessage(title, message, action_text, action)
    clearContent()
    local width = math.max(18, math.min(34, content:getWidth() - 4))
    local panel = content:addFrame({
        x=math.max(2, math.floor((content:getWidth() - width) / 2) + 1),
        y=2, width=width, height=action and 7 or 6,
        background=C.surface,
    })
    panel:addFrame({
        x=1, y=1, width=1, height="{parent.height}",
        background=C.primary, disabled=true,
    })
    panel:addLabel({
        x=3, y=2, width=width - 4, height=1,
        text=fitText(title, width - 4), foreground=C.foreground,
        background=false, disabled=true,
    })
    local lines = wrapText(message, width - 4)
    for index=1, math.min(2, #lines) do
        panel:addLabel({
            x=3, y=2 + index, width=width - 4, height=1,
            text=fitText(lines[index], width - 4), foreground=C.muted,
            background=false, disabled=true,
        })
    end
    if action then
        panel:addButton({
            x=3, y=6, width=math.min(width - 4, math.max(8, #action_text + 2)),
            height=1, text=action_text,
            background=C.primary, foreground=C.accent_text,
        }):onClick(function(_, button) if button == 1 then action() end end)
    end
    content_elements[#content_elements + 1] = panel
end

local function bindCardHover(card, labels, marker_color)
    local function update(hovered)
        card:setState("hover", hovered)
        for index, label in ipairs(labels) do
            if index == 1 then
                label:setForeground(hovered and C.accent_text or C.foreground)
            else
                label:setForeground(hovered and C.accent_muted or C.muted)
            end
        end
        labels[#labels]:setForeground(hovered and C.accent_text or marker_color)
    end
    card:onMouseEnter(function() update(true) end)
    card:onMouseLeave(function() update(false) end)
end

local function showProject(project)
    selected_project = project
    renderDetail()
    detail:scrollTo(0, 0)
    detail:setVisible(true)
end

renderCatalog = function()
    if loading then
        count_label:setText("")
        status_label:setText("Connecting...")
        addMessage("Loading PineStore", "Fetching the latest community projects.")
        return
    end

    filtered_projects = catalog.filter(projects, selected_category, search_query)
    local total = #filtered_projects
    local shown = math.min(total, visible_limit)
    count_label:setText(tostring(total) .. (total == 1 and " project" or " projects"))
    status_label:setText(total > shown
        and ("Showing " .. shown .. " / " .. total)
        or (total == 0 and "No results" or (tostring(total) .. " available")))

    if total == 0 then
        local message = #projects == 0
            and "No catalog data is available."
            or "Try another category or a shorter search."
        addMessage("Nothing found", message, #projects == 0 and "Retry" or nil,
            #projects == 0 and function() refreshCatalog(true) end or nil)
        return
    end

    clearContent()
    local available_width = math.max(1, content:getWidth() - 2)
    local columns = available_width >= 36 and 2 or 1
    local gap = 1
    local card_width = math.floor((available_width - (columns - 1) * gap) / columns)
    local card_height = 5

    for index=1, shown do
        local project = filtered_projects[index]
        local captured = project
        local column = (index - 1) % columns
        local row = math.floor((index - 1) / columns)
        local x = 2 + column * (card_width + gap)
        local y = 1 + row * (card_height + gap)
        local marker_color = CATEGORY_COLOR[project.category] or C.primary
        local installed = getReceipt(project) ~= nil

        local card = content:addFrame({
            x=x, y=y, width=card_width, height=card_height,
            background=C.surface,
        })
        card:setStateStyle("hover", {background=C.primary})
        card:setStateStyle("pressed", {background=C.pressed})
        card:addFrame({
            x=1, y=1, width=1, height=card_height,
            background=marker_color, disabled=true,
        })

        local marker = card:addLabel({
            x=3, y=1, width=1, height=1,
            text=CATEGORY_MARKER[project.category] or "P",
            foreground=marker_color, background=false, disabled=true,
        })
        local text_width = math.max(1, card_width - 6)
        local name = card:addLabel({
            x=5, y=1, width=text_width, height=1,
            text=fitText(project.name, text_width),
            foreground=C.foreground, background=false, disabled=true,
        })
        local author = card:addLabel({
            x=3, y=2, width=card_width - 4, height=1,
            text=fitText("by " .. project.author, card_width - 4),
            foreground=C.muted, background=false, disabled=true,
        })
        local description = card:addLabel({
            x=3, y=3, width=card_width - 4, height=1,
            text=fitText(project.description, card_width - 4),
            foreground=C.muted, background=false, disabled=true,
        })
        local tags = card:addLabel({
            x=3, y=4, width=card_width - 4, height=1,
            text=fitText(table.concat(project.tags, "  "), card_width - 4),
            foreground=C.muted, background=false, disabled=true,
        })
        local stats = card:addLabel({
            x=3, y=5, width=card_width - 4, height=1,
            text=installed and "Installed" or fitText(
                compactNumber(project.downloads) .. " downloads  +"
                    .. compactNumber(project.likes) .. " likes",
                card_width - 4),
            foreground=installed and C.success or marker_color,
            background=false, disabled=true,
        })

        bindCardHover(card, {name, author, description, tags, stats},
            installed and C.success or marker_color)
        card:onClickUp(function(_, button)
            if button == 1 then showProject(captured) end
        end)
        content_elements[#content_elements + 1] = card
    end

    if shown < total then
        local rows = math.ceil(shown / columns)
        local more = content:addButton({
            x=2, y=1 + rows * (card_height + gap),
            width=math.max(10, available_width), height=1,
            text="Load more (" .. tostring(total - shown) .. ")",
            foreground=C.foreground, background=C.surface,
        })
        more:setStateStyle("hover", {background=C.primary, foreground=C.accent_text})
        more:onClick(function(_, button)
            if button == 1 then
                visible_limit = visible_limit + PAGE_SIZE
                renderCatalog()
            end
        end)
        content_elements[#content_elements + 1] = more
    end
end

local function clearDetail()
    for _, element in ipairs(detail_elements) do element:destroy() end
    detail_elements = {}
end

local function addDetail(element)
    detail_elements[#detail_elements + 1] = element
    return element
end

local function reportDownload(project)
    if not http or not http.post or not project.id then return end
    basalt.schedule(function()
        local body = textutils.serializeJSON({projectId=project.id})
        local ok, response = pcall(http.post, DOWNLOAD_LOG_URL, body, {
            ["Content-Type"]="application/json",
        })
        if ok and response then response.close() end
    end)
end

local function finishInstaller(project, success, message)
    if not installer_layer then return end
    local record = installer_layer
    if success then
        local receipt, receipt_error = project_store.record(
            app.userfs, project, record.install_mode)
        if receipt then
            record.receipt = receipt
        else
            success = false
            message = receipt_error or "Could not save installation receipt"
        end
    end
    record.running = false
    record.status:setText(success and "Installation complete" or fitText(message, main:getWidth() - 12))
    record.status:setForeground(success and C.success or C.danger)
    record.action:setText("Back")
    record.action:setBackground(success and C.success or C.surface)
    record.action:setForeground(success and colors.black or C.foreground)

    if success then
        project.downloads = project.downloads + 1
        reportDownload(project)
        renderCatalog()
        notify("PineStore", project.name .. " installed", "success")
    else
        local failure = tostring(message or "Installation failed")
        notify("PineStore", failure, "error")
        if app.dialog and app.dialog.alert then
            app.dialog.alert("PineStore Installation Failed", failure)
        end
    end
end

local function closeInstaller()
    if not installer_layer then return end
    local frame = installer_layer.frame
    installer_layer = nil
    frame:destroy()
    if selected_project then renderDetail() end
end

local function openInstaller(project, install_mode)
    if installer_layer then return end
    install_mode = install_mode == "legacy" and "legacy" or "managed"
    local paths, paths_error = project_store.prepare(
        app.userfs, project, install_mode)
    if not paths then error(paths_error or "Could not prepare project folder") end
    local layer = main:addFrame({
        x=1, y=1, z=60, width="{parent.width}", height="{parent.height}",
        background=C.background,
    })
    local header = layer:addFrame({
        x=1, y=1, width="{parent.width}", height=2, background=C.primary,
    })
    header:addLabel({
        x=2, y=1, width="{parent.width - 12}", height=1,
        text=fitText("Installing " .. project.name, math.max(1, main:getWidth() - 13)),
        foreground=C.accent_text, background=C.primary, disabled=true,
    })
    local status = header:addLabel({
        x=2, y=2, width="{parent.width - 12}", height=1,
        text=install_mode == "legacy"
            and "Running legacy root installer..."
            or "Installing into your project folder...",
        foreground=C.accent_muted, background=C.primary, disabled=true,
    })
    local action = header:addButton({
        x="{parent.width - 8}", y=1, width=7, height=1,
        text="Stop", background=C.danger, foreground=C.accent_text,
    })
    local runner = layer:addProgram({
        x=1, y=3, width="{parent.width}", height="{parent.height - 2}",
        background=colors.black,
    })

    installer_layer = {
        frame=layer, header=header, status=status, action=action,
        runner=runner, running=true, install_mode=install_mode, paths=paths,
    }

    action:onClick(function(_, button)
        if button ~= 1 or not installer_layer then return end
        if installer_layer.running then
            if app.dialog and app.dialog.confirm then
                app.dialog.confirm(
                    "Stop Installation",
                    "Stopping may leave partially installed files. Stop anyway?",
                    function(confirmed)
                        if confirmed and installer_layer and installer_layer.running then
                            finishInstaller(project, false, "Installation stopped; files may be incomplete.")
                            runner:terminate()
                        end
                    end
                )
            end
        else
            closeInstaller()
        end
    end)

    runner:onDone(function(_, ok, result)
        if not installer_layer or not installer_layer.running then return end
        local success = ok == true and result == true
        finishInstaller(project, success,
            success and nil or "The install command did not complete successfully.")
    end)
    runner:onError(function(_, err)
        if installer_layer and installer_layer.running then
            finishInstaller(project, false, tostring(err or "Installer crashed"))
        end
    end)

    local installer_path = fs.combine(basaltOS.appDir, "install.lua")
    local ok, err = pcall(function()
        runner:execute(installer_path, project.install_command,
            paths.root, install_mode)
        runner:focus()
    end)
    if not ok then finishInstaller(project, false, tostring(err)) end
end

local function openInstallerSafely(project, install_mode)
    local ok, err = pcall(openInstaller, project, install_mode)
    if ok then return end

    local message = tostring(err or "Could not create the installer console")
    if installer_layer then
        finishInstaller(project, false, message)
    else
        notify("PineStore", message, "error")
        if app.dialog and app.dialog.alert then
            app.dialog.alert("PineStore Installation Failed", message)
        end
    end
end

local function requestInstall(project, install_mode)
    if not project.installable then
        if app.dialog and app.dialog.alert then
            app.dialog.alert("PineStore", "This project does not provide an install command.")
        end
        return
    end

    install_mode = install_mode == "legacy" and "legacy" or "managed"
    local warning
    if install_mode == "legacy" then
        warning = "Legacy installers may write anywhere on this computer. "
            .. "BasaltOS cannot safely remove those files later:\n"
            .. project.install_command
    else
        warning = "This runs a community-provided command from a per-user "
            .. "project folder:\n" .. project.install_command
    end
    if app.dialog and app.dialog.confirm then
        app.dialog.confirm(
            (install_mode == "legacy" and "Legacy Install " or "Install ")
                .. project.name,
            warning,
            function(confirmed)
            if confirmed then openInstallerSafely(project, install_mode) end
        end)
    else
        openInstallerSafely(project, install_mode)
    end
end

local function addProjectToApps(project)
    local receipt = getReceipt(project)
    if not receipt then
        notify("PineStore", "Install the project first", "warning")
        return
    end
    if not receipt.target_path or not fs.exists(receipt.target_path)
        or fs.isDir(receipt.target_path) then
        notify("PineStore",
            receipt.target_error or "The declared target file was not installed",
            "error")
        return
    end
    if not app.registry or not app.registry.registerExternalProgram then
        notify("PineStore", "External app registration is unavailable", "error")
        return
    end
    local ok, err = app.registry.registerExternalProgram(
        receipt.app_id,
        {
            name=project.name,
            version="1.0.0",
            author=project.author,
            description=project.description,
            category=appCategory(project.category),
            window={
                fullscreen=false,
                resizable=true,
                default_width=51,
                default_height=18,
                min_width=30,
                min_height=10,
            },
        },
        receipt.target_path,
        {
            kind="pinestore",
            project_id=project.id,
            repository=project.repository,
            install_mode=receipt.install_mode,
        }
    )
    notify("PineStore",
        ok and (project.name .. " added to Apps")
            or tostring(err or "Could not add project to Apps"),
        ok and "success" or "error")
    renderCatalog()
    renderDetail()
end

local function removeProjectFromApps(project)
    local receipt = getReceipt(project)
    if not receipt or not receiptAppInstalled(receipt) then return true end
    local ok, err = app.registry.uninstallProgram(receipt.app_id)
    notify("PineStore",
        ok and (project.name .. " removed from Apps")
            or tostring(err or "Could not remove app shortcut"),
        ok and "success" or "error")
    renderCatalog()
    renderDetail()
    return ok
end

local function registerLibraryFile(project, path)
    if not app.libraries or not app.libraries.register then
        notify("PineStore",
            "Library service unavailable; restart BasaltOS after updating",
            "error")
        return
    end
    local suggested = defaultModuleName(path, project)
    local function register(module_name)
        if module_name == nil then return end
        module_name = tostring(module_name):match("^%s*(.-)%s*$") or ""
        local ok, err = app.libraries.register(
            project.id, module_name, path, {
                name=project.name,
                author=project.author,
                source={
                    kind="pinestore",
                    project_id=project.id,
                    repository=project.repository,
                },
            })
        notify("PineStore",
            ok and (project.name .. " added as require(\""
                .. module_name .. "\")")
                or tostring(err or "Could not register library"),
            ok and "success" or "error")
        renderDetail()
    end
    if app.dialog and app.dialog.prompt then
        app.dialog.prompt(
            "Add to Libraries",
            "Module name used by require():",
            suggested,
            register)
    else
        register(suggested)
    end
end

local function addProjectToLibraries(project)
    local receipt = getReceipt(project)
    if not receipt then
        notify("PineStore", "Install the project first", "warning")
        return
    end
    local preferred = receipt.target_path
    if preferred and fs.exists(preferred) and not fs.isDir(preferred)
        and preferred:lower():sub(-4) == ".lua" then
        registerLibraryFile(project, preferred)
        return
    end
    if not app.dialog or not app.dialog.openFile then
        notify("PineStore", "Choose a Lua library file after restarting BasaltOS",
            "error")
        return
    end
    local start_path = receipt.install_mode == "managed"
        and receipt.install_root or "/"
    app.dialog.openFile({
        title="Choose Library Entry",
        startPath=start_path,
        extensions={"lua"},
        actionLabel="Choose",
    }, function(path)
        if path then registerLibraryFile(project, path) end
    end)
end

local function removeProjectFromLibraries(project, quiet)
    local record = getLibrary(project)
    if not record then return true end
    local ok, err = app.libraries.unregister(project.id)
    if not quiet then
        notify("PineStore",
            ok and (project.name .. " removed from Libraries")
                or tostring(err or "Could not remove library"),
            ok and "success" or "error")
        renderDetail()
    end
    return ok
end

local function uninstallProject(project)
    local receipt = getReceipt(project)
    if not receipt then return end
    local function remove(confirmed)
        if not confirmed then return end
        if receiptAppInstalled(receipt) and not removeProjectFromApps(project) then
            return
        end
        if getLibrary(project) and not removeProjectFromLibraries(project, true) then
            notify("PineStore", "Could not remove library registration", "error")
            return
        end
        local ok, legacy_or_error = project_store.remove(app.userfs, project)
        if ok then
            local legacy = legacy_or_error == true
            notify("PineStore",
                legacy
                    and "Legacy receipt removed; installed files were left untouched"
                    or (project.name .. " uninstalled"),
                legacy and "warning" or "success")
        else
            notify("PineStore", tostring(legacy_or_error), "error")
        end
        renderCatalog()
        renderDetail()
    end
    local message = receipt.install_mode == "legacy"
        and "Forget this legacy installation? Its files cannot be removed safely."
        or "Remove this project and its managed files?"
    if app.dialog and app.dialog.confirm then
        app.dialog.confirm("Uninstall " .. project.name, message, remove)
    else
        remove(true)
    end
end

renderDetail = function()
    local project = selected_project
    if not project then detail:setVisible(false) return end
    clearDetail()

    local width = math.max(18, detail:getWidth() - 3)
    local marker_color = CATEGORY_COLOR[project.category] or C.primary
    local receipt = getReceipt(project)
    local installed = receipt ~= nil
    local linked_app = receiptAppInstalled(receipt)
    local registered_library = getLibrary(project)
    local target_available = receipt and receipt.target_path
        and fs.exists(receipt.target_path) and not fs.isDir(receipt.target_path)
    addDetail(detail:addFrame({
        x=1, y=1, width="{parent.width}", height=3, background=C.surface,
    }))
    addDetail(detail:addFrame({
        x=1, y=1, width=1, height=3, background=marker_color, disabled=true,
    }))
    local back = addDetail(detail:addButton({
        x=3, y=1, width=7, height=1, text="< Back",
        foreground=C.foreground, background=C.surface,
    }))
    back:setStateStyle("hover", {background=C.primary, foreground=C.accent_text})
    back:onClick(function(_, button)
        if button == 1 then detail:setVisible(false); selected_project = nil end
    end)

    local action_text = not project.installable and "Unavailable"
        or installed and "Reinstall" or "Install"
    local install_width = action_text == "Unavailable" and 13
        or action_text == "Reinstall" and 11 or 9
    local install = addDetail(detail:addButton({
        x="{parent.width - " .. tostring(install_width) .. "}", y=1,
        width=install_width - 1, height=1,
        text=action_text,
        foreground=project.installable and colors.black or C.muted,
        background=project.installable and C.success or C.surface,
    }))
    install:onClick(function(_, button)
        if button == 1 and project.installable then
            requestInstall(project, "managed")
        end
    end)

    addDetail(detail:addLabel({
        x=3, y=2, width=width - 2, height=1,
        text=fitText(project.name, width - 2),
        foreground=C.foreground, background=false, disabled=true,
    }))
    addDetail(detail:addLabel({
        x=3, y=3, width=width - 2, height=1,
        text=fitText("by " .. project.author .. "  |  " .. CATEGORY_LABEL[project.category],
            width - 2),
        foreground=C.muted, background=false, disabled=true,
    }))

    addDetail(detail:addLabel({
        x=3, y=5, width=width - 2, height=1,
        text=fitText(
            compactNumber(project.downloads) .. " downloads   "
                .. compactNumber(project.downloads_recent) .. " recent   +"
                .. compactNumber(project.likes) .. " likes",
            width - 2),
        foreground=marker_color, background=C.background, disabled=true,
    }))
    local updated = project.date_updated > 0 and project.date_updated or project.date_publish
    addDetail(detail:addLabel({
        x=3, y=6, width=width - 2, height=1,
        text=fitText("Updated " .. formatDate(updated)
            .. (#project.tags > 0 and ("   " .. table.concat(project.tags, "  ")) or ""),
            width - 2),
        foreground=C.muted, background=C.background, disabled=true,
    }))

    if installed then
        local remove = addDetail(detail:addButton({
            x=3, y=7, width=10, height=1,
            text=receipt.install_mode == "legacy" and "Forget" or "Uninstall",
            foreground=C.foreground, background=C.danger,
        }))
        remove:onClick(function(_, button)
            if button == 1 then uninstallProject(project) end
        end)
    end
    if project.installable then
        local legacy = addDetail(detail:addButton({
            x=installed and 14 or 3, y=7, width=14, height=1,
            text="Legacy install",
            foreground=C.foreground, background=C.warning,
        }))
        legacy:onClick(function(_, button)
            if button == 1 then requestInstall(project, "legacy") end
        end)
    end
    if target_available then
        local app_action = addDetail(detail:addButton({
            x=3, y=8, width=14, height=1,
            text=linked_app and "Remove App" or "Add to Apps",
            foreground=C.foreground,
            background=linked_app and C.surface or C.primary,
        }))
        app_action:onClick(function(_, button)
            if button ~= 1 then return end
            if linked_app then removeProjectFromApps(project)
            else addProjectToApps(project) end
        end)
    end
    if installed and project.category == "libraries" then
        local library_action = addDetail(detail:addButton({
            x=target_available and 18 or 3, y=8, width=12, height=1,
            text=registered_library and "Remove Lib" or "Add Library",
            foreground=C.foreground,
            background=registered_library and C.surface or C.primary,
        }))
        library_action:onClick(function(_, button)
            if button ~= 1 then return end
            if registered_library then removeProjectFromLibraries(project)
            else addProjectToLibraries(project) end
        end)
    end
    if installed then
        addDetail(detail:addLabel({
            x=3, y=9, width=width - 2, height=1,
            text=receipt.install_mode == "legacy"
                and "Legacy files untracked" or "Managed per-user install",
            foreground=receipt.install_mode == "legacy" and C.warning or C.success,
            background=false, disabled=true,
        }))
    end

    addDetail(detail:addLabel({
        x=3, y=11, width=width - 2, height=1,
        text="About", foreground=C.primary, background=C.background, disabled=true,
    }))
    local y = 12
    for _, line in ipairs(wrapText(project.full_description, width - 2)) do
        addDetail(detail:addLabel({
            x=3, y=y, width=width - 2, height=1,
            text=line, foreground=C.foreground, background=C.background, disabled=true,
        }))
        y = y + 1
    end

    y = y + 1
    if project.target_file ~= "" then
        addDetail(detail:addLabel({
            x=3, y=y, width=width - 2, height=1,
            text=fitText("Target: " .. project.target_file, width - 2),
            foreground=C.muted, background=C.background, disabled=true,
        }))
        y = y + 1
    end
    if project.repository ~= "" then
        addDetail(detail:addLabel({
            x=3, y=y, width=width - 2, height=1,
            text=fitText("Source: " .. project.repository, width - 2),
            foreground=C.primary, background=C.background, disabled=true,
        }))
        y = y + 1
    end
    if project.installable then
        y = y + 1
        addDetail(detail:addLabel({
            x=3, y=y, width=width - 2, height=1,
            text="Install command", foreground=C.primary,
            background=C.background, disabled=true,
        }))
        y = y + 1
        for _, line in ipairs(wrapText(project.install_command, width - 2)) do
            addDetail(detail:addLabel({
                x=3, y=y, width=width - 2, height=1,
                text=line, foreground=C.muted, background=C.surface, disabled=true,
            }))
            y = y + 1
        end
    end
end

local function httpGetJson(url)
    if not http or not http.get then
        return nil, "HTTP is disabled in the ComputerCraft configuration."
    end
    if http.checkURL then
        local checked, allowed, reason = pcall(http.checkURL, url)
        if checked and not allowed then return nil, "URL blocked: " .. tostring(reason or url) end
    end

    local handle, request_error = http.get(url, nil, false)
    if not handle then return nil, "Connection failed: " .. tostring(request_error or "unknown error") end
    local code = handle.getResponseCode and handle.getResponseCode() or 200
    local body = handle.readAll()
    handle.close()
    if code < 200 or code >= 300 then return nil, "PineStore returned HTTP " .. tostring(code) end
    if not body or body == "" then return nil, "PineStore returned an empty response" end

    local ok, decoded = pcall(textutils.unserializeJSON, body)
    if not ok or type(decoded) ~= "table" then return nil, "Could not read PineStore JSON" end
    return decoded
end

refreshCatalog = function(force)
    if loading then return end
    local now = os.epoch("utc") / 1000
    if not force and cache_time and #projects > 0 and now - cache_time < CACHE_SECONDS then
        renderCatalog()
        return
    end

    loading = true
    renderCatalog()
    basalt.schedule(function()
        local response, fetch_error = httpGetJson(API_URL)
        local loaded, parse_error
        if response then loaded, parse_error = catalog.fromResponse(response) end
        loading = false

        if loaded then
            projects = loaded
            cache_time = os.epoch("utc") / 1000
            visible_limit = PAGE_SIZE
            status_label:setText(tostring(#projects) .. " projects")
            renderCatalog()
        else
            local message = fetch_error or parse_error or "Unknown PineStore error"
            if #projects > 0 then
                notify("PineStore", "Refresh failed; showing cached projects. " .. message, "warning")
                renderCatalog()
            else
                status_label:setText("Offline")
                addMessage("Could not reach PineStore", message, "Retry", function()
                    refreshCatalog(true)
                end)
            end
        end
    end)
end

search_input:onChange(function(_, value)
    search_query = tostring(value or "")
    visible_limit = PAGE_SIZE
    content:scrollTo(0, 0)
    renderCatalog()
end)
search_input:onKey(function(_, key)
    if key == keys.enter and filtered_projects[1] then showProject(filtered_projects[1]) end
end)
refresh_button:onClick(function(_, button)
    if button == 1 then refreshCatalog(true) end
end)

main:onKey(function(_, key)
    if key == keys.f5 and not installer_layer then
        refreshCatalog(true)
    elseif key == keys.escape and not installer_layer then
        if detail:getVisible() then
            detail:setVisible(false)
            selected_project = nil
        elseif search_query ~= "" then
            search_input:setText("")
        end
    end
end)

-- Basalt 2.5 emits layout after reactive dimensions have been resolved.
-- Rebuild only when the effective viewport size actually changed: catalog
-- rendering itself invalidates layout, so an unconditional handler would loop.
local catalog_width, catalog_height = content:getSize()
content:onLayout(function(_, width, height)
    if width == catalog_width and height == catalog_height then return end
    catalog_width, catalog_height = width, height
    if not installer_layer and not detail:getVisible() then renderCatalog() end
end)

local detail_width, detail_height = detail:getSize()
detail:onLayout(function(_, width, height)
    if width == detail_width and height == detail_height then return end
    detail_width, detail_height = width, height
    if not installer_layer and detail:getVisible() and selected_project then renderDetail() end
end)

updateCategoryButtons()
refreshCatalog(false)
basalt.run()
