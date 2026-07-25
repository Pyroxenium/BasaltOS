-- Validation and normalization for the Basalt Store catalog format.

local catalog = {}

local FORMAT_VERSION = 1
local VALID_CATEGORIES = {
    development=true, games=true, graphics=true, internet=true,
    system=true, utilities=true, other=true,
}

local function clean(value)
    value = tostring(value or ""):gsub("\r", "")
    value = value:gsub("[\n\t]+", " "):gsub("%s+", " ")
    return value:match("^%s*(.-)%s*$") or ""
end

local function validAppId(value)
    return type(value) == "string"
        and value:match("^[%w][%w._-]*$") ~= nil
end

local function validRelativePath(value)
    if type(value) ~= "string" or value == "" then return false end
    if value:sub(1, 1) == "/" or value:sub(1, 1) == "\\" then return false end
    if value:find("\\", 1, true) or value:find("//", 1, true) then return false end
    for part in value:gmatch("[^/]+") do
        if part == "." or part == ".." or part == "" then return false end
    end
    return true
end

local function validRef(value)
    if type(value) ~= "string" or value == "" then return false end
    if value:sub(1, 1) == "/" or value:sub(-1) == "/"
        or value:find("//", 1, true) or value:find("..", 1, true) then
        return false
    end
    return value:match("^[%w._/-]+$") ~= nil
end

local function trimSlashes(value)
    return tostring(value or ""):gsub("^/+", ""):gsub("/+$", "")
end

local function githubRepository(value)
    value = clean(value)
    local owner, repository = value:match(
        "^https://github%.com/([%w_.-]+)/([%w_.-]+)/?$")
    if not owner then return nil end
    repository = repository:gsub("%.git$", "")
    if repository == "" then return nil end
    return owner, repository,
        "https://github.com/" .. owner .. "/" .. repository
end

local function normalizeFiles(files)
    if type(files) ~= "table" or #files == 0 then
        return nil, "source.files must contain at least one file"
    end
    local result, seen, has_manifest = {}, {}, false
    for index, value in ipairs(files) do
        if not validRelativePath(value) then
            return nil, "source.files[" .. tostring(index) .. "] is not a safe relative path"
        end
        if seen[value] then return nil, "source.files contains duplicate path " .. value end
        seen[value] = true
        has_manifest = has_manifest or value == "app.json"
        result[#result + 1] = value
    end
    if not has_manifest then return nil, "source.files must include app.json" end
    return result
end

local function normalizeApp(source, index)
    if type(source) ~= "table" then
        return nil, "apps[" .. tostring(index) .. "] must be an object"
    end

    local app_id = clean(source.id)
    if not validAppId(app_id) then
        return nil, "apps[" .. tostring(index) .. "].id is invalid"
    end
    local name = clean(source.name)
    if name == "" then return nil, app_id .. ": name is required" end
    local version = clean(source.version)
    if version == "" then return nil, app_id .. ": version is required" end

    local owner, repository_name, repository = githubRepository(source.repository)
    if not owner then return nil, app_id .. ": repository must be a GitHub repository URL" end

    local source_data = source.source
    if type(source_data) ~= "table" then
        return nil, app_id .. ": source is required"
    end
    local ref = clean(source_data.ref)
    if not validRef(ref) then return nil, app_id .. ": source.ref is invalid" end
    local source_path = trimSlashes(source_data.path)
    if source_path ~= "" and not validRelativePath(source_path) then
        return nil, app_id .. ": source.path is invalid"
    end
    local files, files_error = normalizeFiles(source_data.files)
    if not files then return nil, app_id .. ": " .. files_error end

    local category = clean(source.category):lower()
    if not VALID_CATEGORIES[category] then category = "other" end
    local author = clean(source.author)
    if author == "" then author = owner end
    local description = clean(source.description)
    if description == "" then description = "No description available." end
    local icon, declared_files = clean(source.icon), {}
    for _, filename in ipairs(files) do declared_files[filename] = true end
    if icon == "" and declared_files["icon.bimg"] then
        icon = "icon.bimg"
    end
    if icon ~= "" and not validRelativePath(icon) then
        return nil, app_id .. ": icon is invalid"
    end
    if icon ~= "" and not declared_files[icon] then
        return nil, app_id .. ": icon must be listed in source.files"
    end

    local raw_base = table.concat({
        "https://raw.githubusercontent.com", owner, repository_name, ref,
    }, "/")
    if source_path ~= "" then raw_base = raw_base .. "/" .. source_path end

    local app = {
        id=app_id,
        name=name,
        version=version,
        author=author,
        description=description,
        category=category,
        repository=repository,
        featured=source.featured == true,
        minimum_os_version=clean(source.minimum_os_version),
        source={
            ref=ref,
            path=source_path,
            files=files,
            raw_base=raw_base,
        },
        icon=icon ~= "" and icon or nil,
    }
    app.search_text = table.concat({
        app.id, app.name, app.author, app.description, app.category,
    }, " "):lower()
    return app
end

function catalog.parse(data)
    if type(data) ~= "table" then return nil, "Catalog must be an object" end
    local format_version = tonumber(data.format_version)
    if format_version ~= FORMAT_VERSION then
        return nil, "Unsupported catalog format version: "
            .. tostring(data.format_version)
    end
    if type(data.apps) ~= "table" then return nil, "Catalog contains no apps list" end

    local apps, by_id = {}, {}
    for index, source in ipairs(data.apps) do
        local app, err = normalizeApp(source, index)
        if not app then return nil, err end
        if by_id[app.id] then return nil, "Duplicate app ID: " .. app.id end
        apps[#apps + 1] = app
        by_id[app.id] = app
    end
    return {
        format_version=FORMAT_VERSION,
        apps=apps,
        by_id=by_id,
    }
end

function catalog.filter(apps, category, query)
    category = clean(category):lower()
    if category == "" then category = "all" end
    query = clean(query):lower()
    local result = {}
    for _, app in ipairs(apps or {}) do
        local category_match = category == "all"
            or (category == "featured" and app.featured)
            or app.category == category
        local search_match = query == ""
            or app.search_text:find(query, 1, true) ~= nil
        if category_match and search_match then result[#result + 1] = app end
    end
    return result
end

function catalog.fileUrl(app, filename)
    if type(app) ~= "table" or type(app.source) ~= "table" then
        return nil, "Invalid app"
    end
    if not validRelativePath(filename) then return nil, "Invalid file path" end
    local allowed = false
    for _, path in ipairs(app.source.files or {}) do
        if path == filename then allowed = true break end
    end
    if not allowed then return nil, "File is not declared by the app" end
    return app.source.raw_base .. "/" .. filename
end

catalog.FORMAT_VERSION = FORMAT_VERSION

return catalog
