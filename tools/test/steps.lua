-- Scripted input for boottest.lua, one list of steps per suite of
-- tools/test.ps1. Coordinates refer to the 51x19 test screen.

-- The first account of a fresh computer. It only ever exists on the
-- throwaway computers the tests create.
local NAME, SECRET = "tester", "bpk-test-1"

local function with(...)
    local steps = {}
    for _, list in ipairs({...}) do
        for _, step in ipairs(list) do steps[#steps + 1] = step end
    end
    return steps
end

local create_account = {
    {await="Create the first administrator", timeout=20},
    {wait=0.5},
    {click={12, 6}}, {text=NAME},
    {click={12, 9}}, {text=SECRET},
    {click={12, 12}}, {text=SECRET},
    {click={22, 16}},
    {await="Filely", timeout=15},
    {wait=1},
    {snapshot="desktop after creating the administrator"},
}

local open_launcher = {
    {double={3, 2}},
    {await="Search apps", timeout=10},
    {wait=0.5},
}

return {
    -- The unpacked source tree: no system packages, so no loading screen.
    source = with(
        {{absent="Loading BasaltOS"}},
        create_account
    ),

    -- The packed image: system code, Basalt and every app come from packages.
    apps = with(
        {{await="Loading BasaltOS", timeout=5}},
        create_account,
        open_launcher,
        {
            -- Calculator consists of two files; main.lua requires the other.
            {click={20, 10}},
            {await="Enter = calculate", timeout=10},
            {snapshot="Calculator opened from the launcher"},
        }
    ),

    -- A packed Obsidian game, preinstalled from the packed store: 67 packaged
    -- files including sprites, and Obsidian itself is unpacked on demand.
    game = with(
        create_account,
        open_launcher,
        {
            {click={7, 8}},
            {await="Space In", timeout=5},
            {wait=0.5},
            {click={20, 6}},
            {await="S P A C E  I N V A D E R S", timeout=20},
            {await="START GAME", timeout=5},
            {snapshot="game started"},
        }
    ),

    -- Installing a packed app through the store service (see storetest.lua).
    store = with(
        create_account,
        {
            {event={"storetest_install", "nullbreach"}},
            {await="BREACH NETWORK", timeout=15},
            {report_file="storetest-install.txt"},
            {snapshot="app installed from the store"},
        }
    ),

    -- Second boot of the same computer: the installed package is still there.
    store_reboot = {
        {await="Sign in", timeout=20},
        {wait=0.5},
        {click={12, 10}}, {text=SECRET},
        {click={22, 14}},
        {await="Filely", timeout=15},
        {wait=1},
        {event={"storetest_start", "nullbreach"}},
        {await="BREACH NETWORK", timeout=15},
        {report_file="storetest-start.txt"},
        {snapshot="app started after the reboot"},
    },
}
