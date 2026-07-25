-- Basalt Store catalog service: validated network catalog with per-user cache.

local api_factory = require("core.api")
local event = require("core.event")
local service = require("core.service")
local config = require("core.config")
local log = require("core.log")
local catalog_model = require("core.store_catalog")

local api = api_factory.new()

local DEFAULT_CATALOG_URL =
    "https://raw.githubusercontent.com/Pyroxenium/BasaltOSStore/main/catalog.json"
local DEFAULT_CACHE_SECONDS = 300

local current_catalog
local current_user
local install_serial = 0
local install_state = {
    active=false,
    cancel_requested=false,
    app_id=nil,
    stage="idle",
    current_file=nil,
    completed_files=0,
    total_files=0,
    error=nil,
}
local status = {
    source="none",
    loading=false,
    fetched_at=nil,
    error=nil,
}

local function nowSeconds()
    if os.epoch then return math.floor(os.epoch("utc") / 1000) end
    return os.time and math.floor(os.time()) or 0
end

local function catalogUrl()
    return config.get("services.basaltstore.catalog_url", DEFAULT_CATALOG_URL)
end

local function cacheSeconds()
    return math.max(0, math.floor(tonumber(
        config.get("services.basaltstore.cache_seconds", DEFAULT_CACHE_SECONDS)
    ) or DEFAULT_CACHE_SECONDS))
end

local function cachePaths()
    local userfs = service.getService("userfs")
    local root = userfs and userfs.getPath
        and userfs.getPath("cache/basaltstore") or nil
    if not root then return nil end
    return {
        root=root,
        catalog=fs.combine(root, "catalog.json"),
        metadata=fs.combine(root, "metadata.dat"),
    }
end

local function decodeCatalog(body)
    local ok, decoded = pcall(textutils.unserializeJSON, body)
    if not ok or type(decoded) ~= "table" then
        return nil, "Catalog is not valid JSON"
    end
    return catalog_model.parse(decoded)
end

local function readFile(path)
    if not path or not fs.exists(path) or fs.isDir(path) then return nil end
    local file = fs.open(path, "r")
    if not file then return nil end
    local content = file.readAll()
    file.close()
    return content
end

local function writeFile(path, content)
    local parent = fs.getDir(path)
    if parent ~= "" and not fs.exists(parent) then fs.makeDir(parent) end
    local file = fs.open(path, "w")
    if not file then return false end
    file.write(content)
    file.close()
    return true
end

local function writeBinaryFile(path, content)
    local parent = fs.getDir(path)
    if parent ~= "" and not fs.exists(parent) then fs.makeDir(parent) end
    local file = fs.open(path, "wb")
    if not file then return false, "Could not write " .. path end
    file.write(content)
    file.close()
    return true
end

local function installSnapshot(state)
    state = state or install_state
    return {
        active=state.active == true,
        cancel_requested=state.cancel_requested == true,
        app_id=state.app_id,
        stage=state.stage,
        current_file=state.current_file,
        completed_files=state.completed_files or 0,
        total_files=state.total_files or 0,
        error=state.error,
    }
end

local function publishInstall(state)
    if install_state ~= state then return end
    local snapshot = installSnapshot(state)
    if state.progress_callback then
        local ok, err = pcall(state.progress_callback, snapshot)
        if not ok then
            log.warn("BASALTSTORE", "Install progress callback failed", {error=err})
            state.progress_callback = nil
        end
    end
    event.dispatch("basaltstore.install_progress", snapshot)
end

local function cleanupPath(path)
    if path and fs.exists(path) then
        local ok, err = pcall(fs.delete, path)
        if not ok then
            log.warn("BASALTSTORE", "Could not clean installer staging path", {
                path=path, error=err,
            })
            return false
        end
    end
    return true
end

local function stagingRoot()
    local paths = cachePaths()
    return paths and fs.combine(paths.root, "install") or nil
end

local function resetInstallState()
    install_state = {
        active=false,
        cancel_requested=false,
        app_id=nil,
        stage="idle",
        current_file=nil,
        completed_files=0,
        total_files=0,
        error=nil,
    }
end

local function finishInstall(state, success, err)
    cleanupPath(state.staging_path)
    if install_state == state then
        state.active = false
        state.current_file = nil
        state.error = err
        state.stage = success and "completed"
            or state.cancel_requested and "cancelled" or "failed"
        publishInstall(state)
        event.dispatch(
            success and "basaltstore.install_completed"
                or "basaltstore.install_failed",
            state.app_id,
            err,
            installSnapshot(state)
        )
        state.progress_callback = nil
    end
    if success then return true end
    return false, err
end

function api.private.loadCache()
    local paths = cachePaths()
    if not paths then return false, "No user cache available" end
    local body = readFile(paths.catalog)
    if not body then return false, "No cached catalog" end
    local parsed, err = decodeCatalog(body)
    if not parsed then return false, err end

    local metadata_body = readFile(paths.metadata)
    local metadata
    if metadata_body then
        local ok, value = pcall(textutils.unserialize, metadata_body)
        if ok and type(value) == "table" then metadata = value end
    end

    current_catalog = parsed
    status.source = "cache"
    status.fetched_at = metadata and tonumber(metadata.fetched_at) or nil
    status.error = nil
    event.dispatch("basaltstore.catalog_updated", "cache", #parsed.apps)
    return true, parsed.apps
end

function api.private.saveCache(body, fetched_at)
    local paths = cachePaths()
    if not paths then return false, "No user cache available" end
    if not fs.exists(paths.root) then fs.makeDir(paths.root) end
    if not writeFile(paths.catalog, body) then
        return false, "Could not write catalog cache"
    end
    local metadata = textutils.serialize({
        fetched_at=fetched_at,
        catalog_url=catalogUrl(),
    })
    if not writeFile(paths.metadata, metadata) then
        return false, "Could not write catalog metadata"
    end
    return true
end

local function requestCatalog(url)
    if not http or not http.get then
        return nil, "HTTP is disabled in the ComputerCraft configuration"
    end
    if http.checkURL then
        local checked, allowed, reason = pcall(http.checkURL, url)
        if checked and not allowed then
            return nil, "Catalog URL is blocked: " .. tostring(reason or url)
        end
    end
    local handle, request_error = http.get({
        url=url,
        headers={["User-Agent"]="BasaltOS BasaltStore"},
        binary=false,
        redirect=true,
    })
    if not handle then
        return nil, "Catalog request failed: "
            .. tostring(request_error or "unknown error")
    end
    local code = handle.getResponseCode and handle.getResponseCode() or 200
    local body = handle.readAll()
    handle.close()
    if code < 200 or code >= 300 then
        return nil, "Catalog returned HTTP " .. tostring(code)
    end
    if not body or body == "" then return nil, "Catalog response was empty" end
    return body
end

local function requestAppFile(url)
    if not http or not http.get then
        return nil, "HTTP is disabled in the ComputerCraft configuration"
    end
    if http.checkURL then
        local checked, allowed, reason = pcall(http.checkURL, url)
        if checked and not allowed then
            return nil, "App file URL is blocked: " .. tostring(reason or url)
        end
    end
    local handle, request_error = http.get({
        url=url,
        headers={["User-Agent"]="BasaltOS BasaltStore"},
        binary=true,
        redirect=true,
    })
    if not handle then
        return nil, "Download failed: " .. tostring(request_error or "unknown error")
    end
    local code = handle.getResponseCode and handle.getResponseCode() or 200
    local body = handle.readAll()
    handle.close()
    if code < 200 or code >= 300 then
        return nil, "Download returned HTTP " .. tostring(code)
    end
    if body == nil then return nil, "Download returned no data" end
    return body
end

local function validateStagedManifest(app, staging_path)
    local manifest_path = fs.combine(staging_path, "app.json")
    local body = readFile(manifest_path)
    if not body then return nil, "Downloaded app.json is missing" end
    local ok, manifest = pcall(textutils.unserializeJSON, body)
    if not ok or type(manifest) ~= "table" then
        return nil, "Downloaded app.json is invalid"
    end
    if tostring(manifest.id or "") ~= app.id then
        return nil, "app.json ID does not match the catalog"
    end
    if tostring(manifest.version or "") ~= app.version then
        return nil, "app.json version does not match the catalog"
    end
    local executable = tostring(manifest.executable or "")
    if executable == "" then return nil, "app.json declares no executable" end
    if executable:sub(1, 5) ~= "/rom/" then
        local _, declared_error = catalog_model.fileUrl(app, executable)
        if declared_error then
            return nil, "Executable is not declared in source.files"
        end
        local executable_path = fs.combine(staging_path, executable)
        if not fs.exists(executable_path) or fs.isDir(executable_path) then
            return nil, "Downloaded executable is missing"
        end
    end
    return manifest
end

function api.public.init()
    event.on("user.login", function(username)
        current_user = username
        current_catalog = nil
        local old_staging = stagingRoot()
        if old_staging then cleanupPath(old_staging) end
        resetInstallState()
        status = {source="none", loading=false, fetched_at=nil, error=nil}
        api.private.loadCache()
    end)
    event.on("user.logout", function()
        if install_state.active then install_state.cancel_requested = true end
        current_user = nil
        current_catalog = nil
        status = {source="none", loading=false, fetched_at=nil, error=nil}
    end)
end

function api.public.refresh(force)
    if status.loading then return false, "Catalog refresh is already running" end
    if not current_user then return false, "No user logged in" end
    local now = nowSeconds()
    if not force and current_catalog and status.fetched_at
        and now - status.fetched_at < cacheSeconds() then
        return true, current_catalog.apps, "cache"
    end

    status.loading = true
    local body, request_error = requestCatalog(catalogUrl())
    if not body then
        status.loading = false
        status.error = request_error
        log.warn("BASALTSTORE", "Catalog refresh failed", {error=request_error})
        event.dispatch("basaltstore.catalog_failed", request_error)
        return false, request_error
    end

    local parsed, parse_error = decodeCatalog(body)
    if not parsed then
        status.loading = false
        status.error = parse_error
        log.warn("BASALTSTORE", "Catalog validation failed", {error=parse_error})
        event.dispatch("basaltstore.catalog_failed", parse_error)
        return false, parse_error
    end

    current_catalog = parsed
    status.loading = false
    status.source = "network"
    status.fetched_at = now
    status.error = nil
    local cached, cache_error = api.private.saveCache(body, now)
    if not cached then
        log.warn("BASALTSTORE", "Could not cache catalog", {error=cache_error})
    end
    event.dispatch("basaltstore.catalog_updated", "network", #parsed.apps)
    return true, parsed.apps, "network"
end

function api.public.getApps()
    return current_catalog and current_catalog.apps or {}
end

function api.public.getApp(app_id)
    return current_catalog and current_catalog.by_id[tostring(app_id)] or nil
end

function api.public.filter(category, query)
    return catalog_model.filter(api.public.getApps(), category, query)
end

function api.public.getFileUrl(app_id, filename)
    local app = api.public.getApp(app_id)
    if not app then return nil, "App not found" end
    return catalog_model.fileUrl(app, filename)
end

function api.public.getStatus()
    return {
        source=status.source,
        loading=status.loading,
        fetched_at=status.fetched_at,
        error=status.error,
        catalog_url=catalogUrl(),
        app_count=current_catalog and #current_catalog.apps or 0,
    }
end

-- Download and install one catalog app. This method yields during HTTP
-- requests, so UI callers should invoke it from basalt.schedule().
function api.public.installApp(app_id, progress_callback)
    if install_state.active then return false, "Another installation is running" end
    if not current_user then return false, "No user logged in" end
    if progress_callback ~= nil and type(progress_callback) ~= "function" then
        return false, "Progress callback must be a function or nil"
    end
    local app = api.public.getApp(app_id)
    if not app then return false, "App not found in the catalog" end

    local registry = service.getService("registry")
    if not registry or not registry.installProgram then
        return false, "Registry service is unavailable"
    end
    if registry.hasProgram and registry.hasProgram(app.id) then
        return false, "App is already installed"
    end

    local root = stagingRoot()
    if not root then return false, "No user cache available" end
    if not fs.exists(root) then fs.makeDir(root) end
    install_serial = install_serial + 1
    local staging_path = fs.combine(root,
        app.id .. "-" .. tostring(nowSeconds()) .. "-" .. tostring(install_serial))
    cleanupPath(staging_path)
    fs.makeDir(staging_path)

    local installing_user = current_user
    local state = {
        active=true,
        cancel_requested=false,
        app_id=app.id,
        stage="downloading",
        current_file=nil,
        completed_files=0,
        total_files=#app.source.files,
        error=nil,
        staging_path=staging_path,
        progress_callback=progress_callback,
    }
    install_state = state
    publishInstall(state)

    for _, filename in ipairs(app.source.files) do
        if state.cancel_requested or current_user ~= installing_user then
            state.cancel_requested = true
            return finishInstall(state, false, "Installation cancelled")
        end
        state.current_file = filename
        publishInstall(state)

        local url, url_error = catalog_model.fileUrl(app, filename)
        if not url then return finishInstall(state, false, url_error) end
        local body, download_error = requestAppFile(url)
        if not body then return finishInstall(state, false, download_error) end
        if state.cancel_requested or current_user ~= installing_user then
            state.cancel_requested = true
            return finishInstall(state, false, "Installation cancelled")
        end

        local destination = fs.combine(staging_path, filename)
        local written, write_error = writeBinaryFile(destination, body)
        if not written then return finishInstall(state, false, write_error) end
        state.completed_files = state.completed_files + 1
        publishInstall(state)
    end

    state.current_file = nil
    state.stage = "validating"
    publishInstall(state)
    local manifest, manifest_error = validateStagedManifest(app, staging_path)
    if not manifest then return finishInstall(state, false, manifest_error) end

    if state.cancel_requested or current_user ~= installing_user then
        state.cancel_requested = true
        return finishInstall(state, false, "Installation cancelled")
    end
    state.stage = "installing"
    publishInstall(state)
    local source = {
        kind="basaltstore",
        catalog_url=catalogUrl(),
        repository=app.repository,
        ref=app.source.ref,
    }
    local installed, install_error = registry.installProgram(
        app.id, manifest, staging_path, false, source)
    if not installed then return finishInstall(state, false, install_error) end
    return finishInstall(state, true)
end

function api.public.cancelInstall()
    if not install_state.active then return false, "No installation is running" end
    install_state.cancel_requested = true
    publishInstall(install_state)
    return true
end

function api.public.getInstallStatus()
    return installSnapshot()
end

return api
