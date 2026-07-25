-- PineStore response normalization and filtering.
-- Kept independent from Basalt so the API mapping can be tested in CraftOS.

local catalog = {}

local GAME_TAGS = {
    action=true, fun=true, game=true, games=true, puzzle=true, quirky=true,
}
local LIBRARY_TAGS = {
    library=true, resource=true, ["resource pack"]=true, resourcep=true,
}
local SYSTEM_TAGS = {
    os=true, ["operating system"]=true,
}
local UTILITY_TAGS = {
    utility=true, turtle=true, mod=true, audio=true, saved=true,
}

local function clean(value)
    value = tostring(value or "")
    value = value:gsub("\r", "")
    value = value:gsub("<[^>]+>", " ")
    value = value:gsub("[#*_`]", "")
    value = value:gsub("%[([^%]]+)%]%([^%)]+%)", "%1")
    value = value:gsub("\n+", " ")
    value = value:gsub("%s+", " ")
    return value:match("^%s*(.-)%s*$") or ""
end

local function singleLine(value)
    value = tostring(value or ""):gsub("[\r\n]+", " ")
    value = value:gsub("%s+", " ")
    return value:match("^%s*(.-)%s*$") or ""
end

local function list(value)
    if type(value) == "table" then return value end
    if type(value) ~= "string" then return {} end
    local result = {}
    for item in value:gmatch("[^,]+") do
        item = clean(item):lower()
        if item ~= "" then result[#result + 1] = item end
    end
    return result
end

local function hasTag(tags, set)
    for _, tag in ipairs(tags) do
        if set[tostring(tag):lower()] then return true end
    end
    return false
end

local function classify(tags)
    if hasTag(tags, SYSTEM_TAGS) then return "systems" end
    if hasTag(tags, LIBRARY_TAGS) then return "libraries" end
    if hasTag(tags, GAME_TAGS) then return "games" end
    if hasTag(tags, UTILITY_TAGS) then return "utilities" end
    return "other"
end

local function unwrap(value)
    if type(value) ~= "table" then return nil end
    if type(value.project) == "table" then
        if value.success == false then return nil end
        return value.project
    end
    return value
end

local function normalize(value)
    local source = unwrap(value)
    if not source or source.visible == false then return nil end

    local name = clean(source.name)
    if name == "" then return nil end

    local tags = list(source.tags)
    local keywords = list(source.keywords)
    local description = clean(source.description_short)
    if description == "" then description = clean(source.description) end
    if description == "" then description = clean(source.description_markdown) end
    if description == "" then description = "No description available." end

    local full_description = clean(source.description)
    if full_description == "" then full_description = clean(source.description_markdown) end
    if full_description == "" then full_description = description end

    local project = {
        id=tonumber(source.id) or source.id,
        name=name,
        author=clean(source.owner_name) ~= "" and clean(source.owner_name) or "Unknown",
        description=description,
        full_description=full_description,
        install_command=singleLine(source.install_command),
        target_file=singleLine(source.target_file),
        repository=singleLine(source.repository),
        download_url=singleLine(source.download_url),
        tags=tags,
        keywords=keywords,
        downloads=math.max(0, tonumber(source.downloads) or 0),
        downloads_recent=math.max(0, tonumber(source.downloads_recent) or 0),
        likes=math.max(0, tonumber(source.likes) or 0),
        views=math.max(0, tonumber(source.views) or 0),
        date_updated=tonumber(source.date_updated) or 0,
        date_publish=tonumber(source.date_publish) or tonumber(source.date_added) or 0,
    }
    project.category = classify(tags)
    project.installable = project.install_command ~= ""
    project.score = project.downloads_recent * 20 + project.likes * 25 + project.downloads
    project.search_text = table.concat({
        project.name, project.author, project.description,
        table.concat(tags, " "), table.concat(keywords, " "),
    }, " "):lower()
    return project
end

function catalog.fromResponse(data)
    if type(data) ~= "table" then return nil, "Invalid PineStore response" end
    if data.success == false then
        return nil, clean(data.error) ~= "" and clean(data.error) or "PineStore returned an error"
    end
    if type(data.projects) ~= "table" then return nil, "Response contains no projects" end

    local projects = {}
    for _, value in ipairs(data.projects) do
        local project = normalize(value)
        if project then projects[#projects + 1] = project end
    end
    table.sort(projects, function(left, right)
        if left.score == right.score then return left.name:lower() < right.name:lower() end
        return left.score > right.score
    end)
    for index, project in ipairs(projects) do
        project.featured = index <= 24
    end
    return projects
end

function catalog.filter(projects, category, query)
    category = tostring(category or "featured")
    query = clean(query):lower()
    local result = {}
    for _, project in ipairs(projects or {}) do
        local category_match = category == "all"
            or (category == "featured" and project.featured)
            or project.category == category
        local search_match = query == "" or project.search_text:find(query, 1, true) ~= nil
        if category_match and search_match then result[#result + 1] = project end
    end
    return result
end

function catalog.cleanText(value)
    return clean(value)
end

return catalog
