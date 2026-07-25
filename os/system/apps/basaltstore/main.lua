-- Basalt Store: official BasaltOS application catalog and installer.

local basalt = require("basalt")
local app = require("app")
local store = assert(app.basaltstore, "Basalt Store service not available")
local registry = assert(app.registry, "Registry service not available")
local dialog = app.dialog

local function theme(key, fallback)
    return app.theme(key, fallback)
end

local C = {
    background=theme("menu_bg", colors.white),
    foreground=theme("menu_fg", colors.black),
    muted=theme("menu_muted", colors.gray),
    surface=theme("surface", colors.lightGray),
    primary=theme("primary", colors.blue),
    text=theme("text", colors.white),
    text_dim=theme("text_dim", colors.lightGray),
    pressed=theme("btn_clicked", colors.cyan),
    border=theme("border", colors.gray),
    success=theme("success", colors.lime),
    warning=theme("warning", colors.orange),
    danger=theme("danger", colors.red),
}

local SIDEBAR_WIDTH = 13
local PAGE_SIZE = 40
local CATEGORY_ORDER = {
    "featured", "all", "development", "games", "graphics",
    "internet", "utilities", "system", "other",
}
local CATEGORY_LABEL = {
    featured="Featured", all="All Apps", development="Development",
    games="Games", graphics="Graphics", internet="Internet",
    utilities="Utilities", system="System", other="Other",
}
local CATEGORY_MARKER = {
    development="D", games="G", graphics="A", internet="N",
    utilities="U", system="S", other="O",
}
local CATEGORY_COLOR = {
    development=colors.purple, games=colors.red, graphics=colors.magenta,
    internet=colors.cyan, utilities=colors.lime,
    system=colors.orange, other=colors.gray,
}

local function fit(value, width)
    local text = tostring(value or "")
    width = math.max(0, math.floor(tonumber(width) or 0))
    if #text <= width then return text end
    if width <= 2 then return (".."):sub(1, width) end
    return text:sub(1, width - 2) .. ".."
end

local function wrap(value, width)
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

local function notify(message, kind)
    if app.notification and app.notification.show then
        app.notification.show("Basalt Store", tostring(message or ""), kind or "info")
    end
end

local function isInstalled(app_id)
    return registry.hasProgram and registry.hasProgram(app_id) == true
end

local function isSystemApp(app_id)
    if registry.isSystemProgram then
        return registry.isSystemProgram(app_id) == true
    end
    local program = registry.getProgram and registry.getProgram(app_id) or nil
    return program ~= nil and program.system == true
end

local main = basalt.getMainFrame()
main:setBackground(C.background)

local selected_category = "featured"
local search_query = ""
local catalog_apps = {}
local selected_app
local loading = false
local visible_limit = PAGE_SIZE
local content_elements = {}
local detail_elements = {}
local category_buttons = {}
local installer_layer

local renderCatalog
local renderDetail
local refreshCatalog

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
    text="Basalt", foreground=C.primary, background=false, disabled=true,
})
sidebar:addLabel({
    x=3, y=3, width=SIDEBAR_WIDTH - 3, height=1,
    text="Store", foreground=C.foreground, background=false, disabled=true,
})
local count_label = sidebar:addLabel({
    x=3, y="{parent.height}", width=SIDEBAR_WIDTH - 3, height=1,
    text="", foreground=C.muted, background=false, disabled=true,
})

local toolbar = main:addFrame({
    x=SIDEBAR_WIDTH + 1, y=1,
    width="{parent.width - " .. SIDEBAR_WIDTH .. "}", height=3,
    background=C.background,
})
toolbar:addLabel({
    x=2, y=1, width=9, height=1, text="Discover",
    foreground=C.primary, background=C.background, disabled=true,
})
local status_label = toolbar:addLabel({
    x=11, y=1, width="{parent.width - 19}", height=1,
    text="", foreground=C.muted, background=C.background, disabled=true,
})
local refresh_button = toolbar:addButton({
    x="{parent.width - 7}", y=1, width=7, height=1, text="Refresh",
    foreground=C.foreground, background=C.surface,
})
refresh_button:setStateStyle("hover", {
    foreground=C.text, background=C.primary,
})
toolbar:addLabel({
    x=2, y=2, width=1, height=1, text=">",
    foreground=C.primary, background=C.background, disabled=true,
})
local search_input = toolbar:addInput({
    x=4, y=2, width="{parent.width - 5}", height=1,
    placeholder="Search apps and authors...",
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

local function clearElements(elements)
    for _, element in ipairs(elements) do element:destroy() end
    for index=#elements, 1, -1 do elements[index] = nil end
end

local function addContent(element)
    content_elements[#content_elements + 1] = element
    return element
end

local function addDetail(element)
    detail_elements[#detail_elements + 1] = element
    return element
end

local function updateCategoryButtons()
    for category, button in pairs(category_buttons) do
        local active = category == selected_category
        button:setBackground(active and C.primary or C.surface)
        button:setForeground(active and C.text or C.foreground)
    end
end

local function showMessage(title, message, action_text, action)
    clearElements(content_elements)
    local width = math.max(18, math.min(32, content:getWidth() - 4))
    local panel = addContent(content:addFrame({
        x=math.max(2, math.floor((content:getWidth() - width) / 2) + 1),
        y=2, width=width, height=action and 7 or 6,
        background=C.surface,
    }))
    panel:addFrame({
        x=1, y=1, width=1, height="{parent.height}",
        background=C.primary, disabled=true,
    })
    panel:addLabel({
        x=3, y=2, width=width - 4, height=1,
        text=fit(title, width - 4),
        foreground=C.foreground, background=false, disabled=true,
    })
    local lines = wrap(message, width - 4)
    for index=1, math.min(2, #lines) do
        panel:addLabel({
            x=3, y=2 + index, width=width - 4, height=1,
            text=fit(lines[index], width - 4),
            foreground=C.muted, background=false, disabled=true,
        })
    end
    if action then
        panel:addButton({
            x=3, y=6, width=math.min(width - 4, math.max(8, #action_text + 2)),
            height=1, text=action_text,
            foreground=C.text, background=C.primary,
        }):onClickUp(function(_, button)
            if button == 1 then action() end
        end)
    end
end

local function selectCategory(category)
    selected_category = category
    selected_app = nil
    visible_limit = PAGE_SIZE
    detail:setVisible(false)
    updateCategoryButtons()
    content:scrollTo(0, 0)
    renderCatalog()
end

for index, category in ipairs(CATEGORY_ORDER) do
    local captured = category
    local button = sidebar:addButton({
        x=3, y=4 + index, width=SIDEBAR_WIDTH - 3, height=1,
        text=fit(CATEGORY_LABEL[category], SIDEBAR_WIDTH - 3),
        foreground=C.foreground, background=C.surface,
    })
    button:setStateStyle("hover", {
        foreground=C.foreground, background=C.background,
    })
    button:onClickUp(function(_, mouse_button)
        if mouse_button == 1 then selectCategory(captured) end
    end)
    category_buttons[category] = button
end

local function showApp(app_record)
    selected_app = app_record
    renderDetail()
    detail:scrollTo(0, 0)
    detail:setVisible(true)
end

renderCatalog = function()
    if loading then
        count_label:setText("")
        status_label:setText("Connecting...")
        showMessage("Loading catalog", "Fetching applications from BasaltOSStore.")
        return
    end

    local filtered = store.filter(selected_category, search_query)
    local total = #filtered
    local shown = math.min(total, visible_limit)
    count_label:setText(tostring(total) .. (total == 1 and " app" or " apps"))

    local store_status = store.getStatus()
    local source_text = store_status.source == "cache" and "Cached"
        or store_status.source == "network" and "Online" or "No catalog"
    status_label:setText(total == 0 and source_text
        or source_text .. " - " .. tostring(total) .. " available")

    if total == 0 then
        showMessage(
            #catalog_apps == 0 and "No catalog" or "Nothing found",
            #catalog_apps == 0
                and "Connect to the internet and refresh the catalog."
                or "Try another category or a shorter search.",
            #catalog_apps == 0 and "Refresh" or nil,
            #catalog_apps == 0 and function() refreshCatalog(true) end or nil
        )
        return
    end

    clearElements(content_elements)
    local available_width = math.max(1, content:getWidth() - 2)
    local columns = available_width >= 36 and 2 or 1
    local gap, card_height = 1, 5
    local card_width = math.floor((available_width - (columns - 1) * gap) / columns)

    for index=1, shown do
        local app_record = filtered[index]
        local captured = app_record
        local column = (index - 1) % columns
        local row = math.floor((index - 1) / columns)
        local marker_color = CATEGORY_COLOR[app_record.category] or C.primary
        local installed = isInstalled(app_record.id)
        local system_app = installed and isSystemApp(app_record.id)
        local card = addContent(content:addFrame({
            x=2 + column * (card_width + gap),
            y=1 + row * (card_height + gap),
            width=card_width, height=card_height,
            background=C.surface,
        }))
        card:setStateStyle("hover", {background=C.primary})
        card:setStateStyle("pressed", {background=C.pressed})
        card:addFrame({
            x=1, y=1, width=1, height=card_height,
            background=installed and C.success or marker_color, disabled=true,
        })
        local marker = card:addLabel({
            x=3, y=1, width=1, height=1,
            text=CATEGORY_MARKER[app_record.category] or "O",
            foreground=installed and C.success or marker_color,
            background=false, disabled=true,
        })
        local name = card:addLabel({
            x=5, y=1, width=math.max(1, card_width - 6), height=1,
            text=fit(app_record.name, math.max(1, card_width - 6)),
            foreground=C.foreground, background=false, disabled=true,
        })
        local author = card:addLabel({
            x=3, y=2, width=card_width - 4, height=1,
            text=fit("by " .. app_record.author .. "  v" .. app_record.version,
                card_width - 4),
            foreground=C.muted, background=false, disabled=true,
        })
        local description = card:addLabel({
            x=3, y=3, width=card_width - 4, height=1,
            text=fit(app_record.description, card_width - 4),
            foreground=C.muted, background=false, disabled=true,
        })
        local category_label = card:addLabel({
            x=3, y=4, width=card_width - 4, height=1,
            text=fit(CATEGORY_LABEL[app_record.category] or "Other", card_width - 4),
            foreground=C.muted, background=false, disabled=true,
        })
        local state_label = card:addLabel({
            x=3, y=5, width=card_width - 4, height=1,
            text=system_app and "System app"
                or installed and "Installed"
                or (app_record.featured and "Featured" or "Available"),
            foreground=installed and C.success or marker_color,
            background=false, disabled=true,
        })
        local labels = {marker, name, author, description, category_label, state_label}
        card:onMouseEnter(function()
            for _, label in ipairs(labels) do label:setForeground(C.text) end
        end)
        card:onMouseLeave(function()
            marker:setForeground(installed and C.success or marker_color)
            name:setForeground(C.foreground)
            author:setForeground(C.muted)
            description:setForeground(C.muted)
            category_label:setForeground(C.muted)
            state_label:setForeground(installed and C.success or marker_color)
        end)
        card:onClickUp(function(_, button)
            if button == 1 then showApp(captured) end
        end)
    end

    if shown < total then
        local rows = math.ceil(shown / columns)
        local more = addContent(content:addButton({
            x=2, y=1 + rows * (card_height + gap),
            width=available_width, height=1,
            text="Load more (" .. tostring(total - shown) .. ")",
            foreground=C.foreground, background=C.surface,
        }))
        more:onClickUp(function(_, button)
            if button == 1 then
                visible_limit = visible_limit + PAGE_SIZE
                renderCatalog()
            end
        end)
    end
end

local function closeInstaller()
    if not installer_layer then return end
    installer_layer.frame:destroy()
    installer_layer = nil
end

local function updateInstaller(snapshot)
    local layer = installer_layer
    if not layer or layer.app_id ~= snapshot.app_id then return end
    local percent = snapshot.total_files > 0
        and math.floor(snapshot.completed_files / snapshot.total_files * 100) or 0
    layer.progress:setProgress(percent)
    layer.file:setText(fit(
        snapshot.current_file
            and ("Downloading " .. snapshot.current_file)
            or snapshot.stage == "validating" and "Validating app.json"
            or snapshot.stage == "installing" and "Registering application"
            or snapshot.stage == "completed" and "Installation complete"
            or snapshot.stage == "cancelled" and "Installation cancelled"
            or snapshot.stage == "failed" and tostring(snapshot.error or "Installation failed")
            or "Preparing installation",
        math.max(1, layer.file:getWidth())
    ))
    layer.count:setText(string.format(
        "%d / %d files", snapshot.completed_files, snapshot.total_files))
    if snapshot.cancel_requested and snapshot.active then
        layer.action:setText("Stopping")
        layer.action:setDisabled(true)
    elseif snapshot.active then
        layer.action:setText("Cancel")
        layer.action:setDisabled(false)
    else
        layer.action:setText("Done")
        layer.action:setDisabled(false)
        layer.action:setBackground(snapshot.stage == "completed" and C.success or C.surface)
        layer.action:setForeground(snapshot.stage == "completed" and colors.black or C.foreground)
    end
end

local function openInstaller(app_record)
    if installer_layer then return end
    local frame = main:addFrame({
        x=1, y=1, z=60, width="{parent.width}", height="{parent.height}",
        background=C.background,
    })
    local panel_width = math.max(26, math.min(40, main:getWidth() - 6))
    local panel = frame:addFrame({
        x=math.max(2, math.floor((main:getWidth() - panel_width) / 2) + 1),
        y=math.max(2, math.floor((main:getHeight() - 9) / 2) + 1),
        width=panel_width, height=9, background=C.surface,
    })
    panel:addFrame({
        x=1, y=1, width=1, height="{parent.height}",
        background=C.primary, disabled=true,
    })
    panel:addLabel({
        x=3, y=2, width=panel_width - 4, height=1,
        text=fit("Installing " .. app_record.name, panel_width - 4),
        foreground=C.foreground, background=false, disabled=true,
    })
    local file_label = panel:addLabel({
        x=3, y=4, width=panel_width - 4, height=1,
        text="Preparing installation",
        foreground=C.muted, background=false, disabled=true,
    })
    local progress = panel:addProgressBar({
        x=3, y=5, width=panel_width - 4, height=1,
        progress=0, background=C.border, barColor=C.primary,
        showPercentage=true, foreground=C.text,
    })
    local count = panel:addLabel({
        x=3, y=6, width=panel_width - 4, height=1,
        text="0 / 0 files", foreground=C.muted, background=false, disabled=true,
    })
    local action = panel:addButton({
        x=3, y=8, width=10, height=1, text="Cancel",
        foreground=C.text, background=C.danger,
    })
    installer_layer = {
        frame=frame, panel=panel, file=file_label, progress=progress,
        count=count, action=action, app_id=app_record.id,
    }
    action:onClickUp(function(_, button)
        if button ~= 1 or not installer_layer then return end
        local snapshot = store.getInstallStatus()
        if snapshot.active then
            store.cancelInstall()
        else
            closeInstaller()
        end
    end)

    basalt.schedule(function()
        local ok, err = store.installApp(app_record.id, updateInstaller)
        if not ok and installer_layer then
            local snapshot = store.getInstallStatus()
            if snapshot.app_id ~= app_record.id or snapshot.stage == "idle" then
                updateInstaller({
                    app_id=app_record.id, active=false, stage="failed",
                    error=err, completed_files=0,
                    total_files=#app_record.source.files,
                })
            end
        end
        catalog_apps = store.getApps()
        renderCatalog()
        if selected_app and selected_app.id == app_record.id then renderDetail() end
        notify(ok and (app_record.name .. " installed")
            or tostring(err or "Installation failed"), ok and "success" or "error")
    end)
end

local function requestInstall(app_record)
    if isInstalled(app_record.id) then return end
    openInstaller(app_record)
end

local function requestUninstall(app_record)
    if isSystemApp(app_record.id) then return end
    local function uninstall(confirmed)
        if not confirmed then return end
        local ok, err = registry.uninstallProgram(app_record.id)
        catalog_apps = store.getApps()
        renderCatalog()
        renderDetail()
        notify(ok and (app_record.name .. " uninstalled")
            or tostring(err or "Could not uninstall app"),
            ok and "success" or "error")
    end
    if dialog and dialog.confirm then
        dialog.confirm(
            "Uninstall " .. app_record.name,
            "Remove this app for the current user?",
            uninstall
        )
    else
        uninstall(true)
    end
end

renderDetail = function()
    local app_record = selected_app
    if not app_record then detail:setVisible(false) return end
    clearElements(detail_elements)
    local width = math.max(18, detail:getWidth() - 3)
    local marker_color = CATEGORY_COLOR[app_record.category] or C.primary
    local installed = isInstalled(app_record.id)
    local system_app = installed and isSystemApp(app_record.id)

    addDetail(detail:addFrame({
        x=1, y=1, width="{parent.width}", height=4, background=C.surface,
    }))
    addDetail(detail:addFrame({
        x=1, y=1, width=1, height=4,
        background=installed and C.success or marker_color, disabled=true,
    }))
    local back = addDetail(detail:addButton({
        x=3, y=1, width=7, height=1, text="< Back",
        foreground=C.foreground, background=C.surface,
    }))
    back:onClickUp(function(_, button)
        if button == 1 then
            detail:setVisible(false)
            selected_app = nil
        end
    end)
    if system_app then
        addDetail(detail:addLabel({
            x="{parent.width - 12}", y=1, width=11, height=1,
            text="System app", foreground=C.success,
            background=false, disabled=true,
        }))
    else
        local action_text = installed and "Uninstall" or "Install"
        local action_width = installed and 11 or 9
        local action = addDetail(detail:addButton({
            x="{parent.width - " .. tostring(action_width) .. "}",
            y=1, width=action_width - 1, height=1,
            text=action_text,
            foreground=installed and C.text or colors.black,
            background=installed and C.danger or C.success,
        }))
        action:onClickUp(function(_, button)
            if button ~= 1 then return end
            if installed then requestUninstall(app_record)
            else requestInstall(app_record) end
        end)
    end
    addDetail(detail:addLabel({
        x=3, y=2, width=width - 2, height=1,
        text=fit(app_record.name, width - 2),
        foreground=C.foreground, background=false, disabled=true,
    }))
    addDetail(detail:addLabel({
        x=3, y=3, width=width - 2, height=1,
        text=fit("by " .. app_record.author .. "  |  v" .. app_record.version,
            width - 2),
        foreground=C.muted, background=false, disabled=true,
    }))
    addDetail(detail:addLabel({
        x=3, y=4, width=width - 2, height=1,
        text=system_app and "Included with BasaltOS"
            or installed and "Installed for this user"
            or (CATEGORY_LABEL[app_record.category] or "Other"),
        foreground=installed and C.success or marker_color,
        background=false, disabled=true,
    }))

    addDetail(detail:addLabel({
        x=3, y=6, width=width - 2, height=1,
        text="About", foreground=C.primary, background=C.background, disabled=true,
    }))
    local y = 7
    for _, line in ipairs(wrap(app_record.description, width - 2)) do
        addDetail(detail:addLabel({
            x=3, y=y, width=width - 2, height=1,
            text=line, foreground=C.foreground,
            background=C.background, disabled=true,
        }))
        y = y + 1
    end
    y = y + 1
    local compatibility = app_record.minimum_os_version ~= ""
        and ("Requires BasaltOS " .. app_record.minimum_os_version .. " or newer")
        or "No minimum BasaltOS version declared"
    addDetail(detail:addLabel({
        x=3, y=y, width=width - 2, height=1,
        text=fit(compatibility, width - 2),
        foreground=C.muted, background=C.background, disabled=true,
    }))
    y = y + 1
    addDetail(detail:addLabel({
        x=3, y=y, width=width - 2, height=1,
        text=fit(tostring(#app_record.source.files)
            .. " files  |  Ref " .. app_record.source.ref, width - 2),
        foreground=C.muted, background=C.background, disabled=true,
    }))
    y = y + 2
    addDetail(detail:addLabel({
        x=3, y=y, width=width - 2, height=1,
        text="Source", foreground=C.primary, background=C.background, disabled=true,
    }))
    y = y + 1
    addDetail(detail:addLabel({
        x=3, y=y, width=width - 2, height=1,
        text=fit(app_record.repository, width - 2),
        foreground=C.muted, background=C.surface, disabled=true,
    }))
end

refreshCatalog = function(force)
    if loading then return end
    loading = true
    renderCatalog()
    basalt.schedule(function()
        local ok, result = store.refresh(force == true)
        loading = false
        catalog_apps = store.getApps()
        if not ok then
            local message = tostring(result or "Could not refresh catalog")
            if #catalog_apps > 0 then
                notify("Offline - showing cached catalog", "warning")
                status_label:setText("Offline - cached")
            else
                notify(message, "error")
            end
        end
        renderCatalog()
        if selected_app then
            selected_app = store.getApp(selected_app.id)
            renderDetail()
        end
    end)
end

search_input:onChange(function(_, value)
    search_query = tostring(value or "")
    visible_limit = PAGE_SIZE
    content:scrollTo(0, 0)
    renderCatalog()
end)

refresh_button:onClickUp(function(_, button)
    if button == 1 then refreshCatalog(true) end
end)

main:onKey(function(_, key)
    if key == keys.f5 and not installer_layer then
        refreshCatalog(true)
    elseif key == keys.escape then
        if installer_layer and not store.getInstallStatus().active then
            closeInstaller()
        elseif detail:getVisible() then
            detail:setVisible(false)
            selected_app = nil
        elseif search_query ~= "" then
            search_input:setText("")
        end
    end
end)

local content_width, content_height = content:getSize()
content:onLayout(function(_, width, height)
    if width == content_width and height == content_height then return end
    content_width, content_height = width, height
    if not loading and not detail:getVisible() then renderCatalog() end
end)

local detail_width, detail_height = detail:getSize()
detail:onLayout(function(_, width, height)
    if width == detail_width and height == detail_height then return end
    detail_width, detail_height = width, height
    if detail:getVisible() and selected_app then renderDetail() end
end)

updateCategoryButtons()
catalog_apps = store.getApps()
renderCatalog()
refreshCatalog(false)
basalt.run()
