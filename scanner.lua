-- scanner.lua
-- First run (or `scanner setup`): interactive setup wizard
-- Subsequent runs: loads config and scans peripherals

local CONFIG_FILE   = "scanner_config.json"
local POLL_INTERVAL = 15
local MAX_ITEMS     = 25

-- ============================================================
-- MODULE DEFINITIONS
-- Each module owns a set of peripheral types.
-- Only enabled modules have their handlers run.
-- ============================================================
local MODULES = {
    { id = "power",       label = "Power & Energy",                  desc = "Energy storage, RF/FE meters",            types = {"energy_storage", "energy_detector"} },
    { id = "storage",     label = "Storage & Inventories",           desc = "Chests, barrels, any inventory block",     types = {"inventory", "drive"} },
    { id = "me",          label = "ME System  (Applied Energistics)", desc = "Item counts, energy, craftables",         types = {"me_bridge"} },
    { id = "rs",          label = "Refined Storage",                  desc = "Item counts, energy, patterns",           types = {"rs_bridge"} },
    { id = "environment", label = "Environment",                      desc = "Weather, time, light level, biome",       types = {"environment_detector"} },
    { id = "players",     label = "Player Detection",                 desc = "Online players list and count",           types = {"player_detector"} },
    { id = "fluids",      label = "Fluids & Tanks",                   desc = "Tank contents, capacity",                 types = {"fluid_storage"} },
    { id = "devices",     label = "Computers & Devices",              desc = "Monitors, modems, printers, other CCs",   types = {"computer", "monitor", "modem", "printer"} },
}

-- ============================================================
-- TERMINAL HELPERS
-- ============================================================
local USE_COLOR = term.isColor and term.isColor()

local function color(c)
    if USE_COLOR then term.setTextColor(c) end
end

local function resetColor()
    if USE_COLOR then term.setTextColor(colors.white) end
end

local function header(title)
    term.clear()
    term.setCursorPos(1, 1)
    color(colors.yellow)
    print("=== " .. title .. " ===")
    resetColor()
    print("")
end

local function ask(prompt, default)
    color(colors.cyan)
    io.write(prompt)
    if default then
        color(colors.gray)
        io.write(" [" .. default .. "]")
    end
    io.write(": ")
    resetColor()
    local val = read()
    if val == "" and default then return default end
    return val
end

local function confirm(prompt)
    color(colors.cyan)
    io.write(prompt .. " [y/n]: ")
    resetColor()
    local ans = read()
    return ans:lower():sub(1,1) == "y"
end

-- ============================================================
-- SETUP WIZARD
-- ============================================================
local function runSetup()
    header("HA Scanner — First Time Setup")

    print("This wizard will configure what to scan and report.")
    print("You can re-run it any time with:  scanner setup")
    print("")

    -- Webhook URL
    local url = ask("Home Assistant webhook URL", "http://192.168.1.X:8123/api/webhook/YOUR_ID")
    while url == "" or url:find("YOUR_ID") do
        color(colors.red)
        print("Please enter a valid URL.")
        resetColor()
        url = ask("Webhook URL")
    end

    -- Computer ID
    local default_id = "scanner_" .. os.getComputerID()
    local comp_id = ask("Name for this computer", default_id)
    if comp_id == "" then comp_id = default_id end

    -- Poll interval
    local interval_str = ask("Scan interval in seconds", tostring(POLL_INTERVAL))
    local interval = tonumber(interval_str) or POLL_INTERVAL

    -- Module selection
    print("")
    color(colors.yellow)
    print("Select modules to enable:")
    resetColor()
    print("Press a number key to toggle. Press Enter when done.")
    print("")

    local enabled = {}
    for i, mod in ipairs(MODULES) do
        enabled[i] = true  -- all on by default
    end

    local function drawModules()
        local _, startY = term.getCursorPos()
        -- Move up to redraw (estimate 1 line per module + 1 header)
        local drawY = startY
        for i, mod in ipairs(MODULES) do
            term.setCursorPos(1, drawY + i - 1)
            term.clearLine()
            if enabled[i] then
                color(colors.green)
                io.write("[X] ")
            else
                color(colors.gray)
                io.write("[ ] ")
            end
            resetColor()
            color(colors.white)
            io.write(i .. ". " .. mod.label)
            color(colors.gray)
            print("  — " .. mod.desc)
            resetColor()
        end
        term.setCursorPos(1, drawY + #MODULES)
        print("")
        color(colors.cyan)
        io.write("> ")
        resetColor()
    end

    -- Initial draw
    local _, startRow = term.getCursorPos()
    drawModules()

    while true do
        local ev, key = os.pullEvent("key")
        local num = tonumber(keys.getName(key))
        if num and num >= 1 and num <= #MODULES then
            enabled[num] = not enabled[num]
            term.setCursorPos(1, startRow)
            drawModules()
        elseif key == keys.enter then
            break
        end
    end

    print("")

    -- Build config
    local cfg = {
        url      = url,
        id       = comp_id,
        interval = interval,
        modules  = {},
    }
    for i, mod in ipairs(MODULES) do
        cfg.modules[mod.id] = enabled[i]
    end

    -- Save
    local f = fs.open(CONFIG_FILE, "w")
    f.write(textutils.serialiseJSON(cfg))
    f.close()

    color(colors.green)
    print("Config saved to " .. CONFIG_FILE)
    resetColor()
    print("")

    return cfg
end

-- ============================================================
-- CONFIG LOAD
-- ============================================================
local function loadConfig()
    if not fs.exists(CONFIG_FILE) then return nil end
    local f = fs.open(CONFIG_FILE, "r")
    local raw = f.readAll()
    f.close()
    local ok, cfg = pcall(textutils.unserialiseJSON, raw)
    if not ok or type(cfg) ~= "table" then return nil end
    return cfg
end

-- ============================================================
-- PERIPHERAL HANDLERS
-- ============================================================
local handlers = {}

handlers["inventory"] = function(p)
    local ok, size = pcall(p.size)
    if not ok then return nil end
    local filled, total = 0, 0
    local type_counts = {}
    local ok2, list = pcall(p.list)
    if ok2 and list then
        for _, item in pairs(list) do
            filled = filled + 1
            total  = total + item.count
            type_counts[item.name] = (type_counts[item.name] or 0) + item.count
        end
    end
    local sorted = {}
    for name, count in pairs(type_counts) do
        table.insert(sorted, { name = name, count = count })
    end
    table.sort(sorted, function(a, b) return a.count > b.count end)
    local top = {}
    for i = 1, math.min(MAX_ITEMS, #sorted) do
        table.insert(top, sorted[i].name:match("[^:]+$") .. "x" .. sorted[i].count)
    end
    return {
        slots_total  = size,
        slots_used   = filled,
        slots_free   = size - filled,
        total_items  = total,
        unique_types = #sorted,
        top_items    = table.concat(top, ", "),
    }
end

handlers["drive"] = function(p)
    local _, present  = pcall(p.isDiskPresent)
    local _, hasData  = pcall(p.hasData)
    local _, hasAudio = pcall(p.hasAudio)
    local label = "none"
    if present then local _, l = pcall(p.getDiskLabel); label = l or "unlabeled" end
    return { disk_present = present or false, has_data = hasData or false, has_audio = hasAudio or false, disk_label = label }
end

handlers["energy_storage"] = function(p)
    local _, e  = pcall(p.getEnergy)
    if not e then _, e = pcall(p.getEnergyStored) end
    local _, mx = pcall(p.getEnergyCapacity)
    if not mx then _, mx = pcall(p.getMaxEnergyStored) end
    e, mx = e or 0, mx or 0
    return { energy = e, max_energy = mx, percent = mx > 0 and math.floor((e/mx)*100) or 0 }
end

handlers["energy_detector"] = function(p)
    local _, rate = pcall(p.getTransferRate)
    local _, max  = pcall(p.getMaxTransferRate)
    return { transfer_rate = rate or 0, max_transfer_rate = max or 0 }
end

handlers["me_bridge"] = function(p)
    local _, items     = pcall(p.listItems)
    local _, energy    = pcall(p.getEnergyStorage)
    local _, maxE      = pcall(p.getMaxEnergyStorage)
    local _, craftable = pcall(p.listCraftableItems)
    local ic, tc = 0, 0
    if type(items) == "table" then
        tc = #items
        for _, item in ipairs(items) do ic = ic + (item.amount or 0) end
    end
    return {
        total_items     = ic,
        unique_types    = tc,
        craftable_types = type(craftable) == "table" and #craftable or 0,
        energy          = energy or 0,
        max_energy      = maxE   or 0,
    }
end

handlers["rs_bridge"] = function(p)
    local _, items    = pcall(p.listItems)
    local _, energy   = pcall(p.getEnergyUsage)
    local _, maxE     = pcall(p.getMaxEnergyStorage)
    local _, patterns = pcall(p.getPatternCount)
    local ic, tc = 0, 0
    if type(items) == "table" then
        tc = #items
        for _, item in ipairs(items) do ic = ic + (item.amount or 0) end
    end
    return { total_items = ic, unique_types = tc, energy_usage = energy or 0, max_energy = maxE or 0, pattern_count = patterns or 0 }
end

handlers["environment_detector"] = function(p)
    local _, biome   = pcall(p.getBiome)
    local _, light   = pcall(p.getLightLevel)
    local _, sky     = pcall(p.getSkyLightLevel)
    local _, time    = pcall(p.getTime)
    local _, day     = pcall(p.getDay)
    local _, moon    = pcall(p.getMoonPhase)
    local _, rain    = pcall(p.isRaining)
    local _, thunder = pcall(p.isThundering)
    return { biome = biome or "unknown", light_level = light or 0, sky_light = sky or 0,
             world_time = time or 0, day = day or 0, moon_phase = moon or 0,
             raining = rain or false, thundering = thunder or false }
end

handlers["player_detector"] = function(p)
    local _, list = pcall(p.getOnlinePlayers)
    local players = type(list) == "table" and list or {}
    return { player_count = #players, players = players }
end

handlers["fluid_storage"] = function(p)
    local _, tanks = pcall(p.tanks)
    if not tanks or type(tanks) ~= "table" then return nil end
    local names, total, cap = {}, 0, 0
    for _, t in ipairs(tanks) do
        if t.name then table.insert(names, t.name:match("[^:]+$") .. "x" .. (t.amount or 0) .. "mb") end
        total = total + (t.amount   or 0)
        cap   = cap   + (t.capacity or 0)
    end
    return { tank_count = #tanks, total_mb = total, capacity_mb = cap, contents = table.concat(names, ", ") }
end

handlers["monitor"] = function(p)
    local ok, w, h = pcall(p.getSize)
    if not ok then return nil end
    local _, col = pcall(p.isColor)
    return { width = w, height = h, is_color = col or false }
end

handlers["modem"]    = function(p) local _, w = pcall(p.isWireless); return { is_wireless = w or false } end
handlers["printer"]  = function(p) local _, ink = pcall(p.getInkLevel); local _, paper = pcall(p.getPaperLevel); return { ink_level = ink or 0, paper_level = paper or 0 } end
handlers["computer"] = function(p)
    local _, id = pcall(p.getID); local _, lbl = pcall(p.getLabel); local _, on = pcall(p.isOn)
    return { id = id or 0, label = lbl or "unlabeled", is_on = on or false }
end

-- ============================================================
-- BUILD TYPE → MODULE MAP  (used to filter by enabled modules)
-- ============================================================
local function buildTypeFilter(cfg)
    local allowed = {}
    for _, mod in ipairs(MODULES) do
        if cfg.modules[mod.id] then
            for _, t in ipairs(mod.types) do
                allowed[t] = true
            end
        end
    end
    return allowed
end

-- ============================================================
-- SCAN
-- ============================================================
local function sanitise(s)
    return s:lower():gsub("[^a-z0-9]", "_")
end

local function scan(cfg, allowed)
    local payload = {
        computer_id  = cfg.id,
        online       = true,
        label        = os.getComputerLabel() or "unlabeled",
        uptime       = os.clock(),
        periph_count = 0,
    }

    if turtle then
        local _, fuel    = pcall(turtle.getFuelLevel)
        local _, fuelMax = pcall(turtle.getFuelLimit)
        fuel, fuelMax = fuel or 0, fuelMax or 0
        payload.turtle_fuel     = fuel
        payload.turtle_fuel_max = fuelMax
        payload.turtle_fuel_pct = fuelMax > 0 and math.floor((fuel/fuelMax)*100) or 0
    end

    local names = peripheral.getNames()
    local active = 0

    for _, name in ipairs(names) do
        local ptype = peripheral.getType(name)
        if ptype and allowed[ptype] then
            local p = peripheral.wrap(name)
            if p then
                active = active + 1
                local prefix = sanitise(name) .. "_"
                payload[sanitise(name) .. "_type"] = ptype
                local handler = handlers[ptype]
                if handler then
                    local ok, data = pcall(handler, p)
                    if ok and type(data) == "table" then
                        for k, v in pairs(data) do
                            payload[prefix .. k] = v
                        end
                    end
                end
            end
        end
    end

    payload.periph_count = active
    return payload
end

-- ============================================================
-- SEND
-- ============================================================
local function send(url, payload)
    local res, err = http.post(url, textutils.serialiseJSON(payload), { ["Content-Type"] = "application/json" })
    if not res then return false, tostring(err) end
    local raw = res.readAll(); res.close()
    local ok, result = pcall(textutils.unserialiseJSON, raw)
    return true, (ok and result or nil)
end

local function handleCommands(cmds)
    if not cmds or #cmds == 0 then return false end
    for _, cmd in ipairs(cmds) do
        print("[CMD] " .. tostring(cmd.command))
        if cmd.command == "reboot"    then os.reboot() end
        if cmd.command == "setup"     then return "setup" end
        if cmd.command == "scan_now"  then return "scan_now" end
    end
    return false
end

-- ============================================================
-- MAIN
-- ============================================================
local args = { ... }

-- Load or run setup
local cfg = loadConfig()
if not cfg or args[1] == "setup" then
    cfg = runSetup()
end

local allowed = buildTypeFilter(cfg)

-- Summary of what's active
header("HA Peripheral Scanner")
color(colors.white);  print("Computer : " .. cfg.id)
color(colors.white);  print("Interval : " .. cfg.interval .. "s")
print("")
color(colors.yellow); print("Active modules:")
resetColor()
for _, mod in ipairs(MODULES) do
    if cfg.modules[mod.id] then
        color(colors.green); io.write("  [X] ")
        resetColor(); print(mod.label)
    end
end
print("")
color(colors.gray); print("Press Q to quit | run 'scanner setup' to reconfigure")
resetColor(); print("")

-- Main scan loop
while true do
    io.write("[SCAN] ")
    local payload = scan(cfg, allowed)

    color(colors.cyan)
    io.write(payload.periph_count .. " active peripheral(s)... ")
    resetColor()

    local ok, result = send(cfg.url, payload)
    if ok then
        local cmds = result and result.commands or {}
        color(colors.green); print("OK  (" .. #cmds .. " cmd(s))")
        resetColor()
        local action = handleCommands(cmds)
        if action == "setup" then cfg = runSetup(); allowed = buildTypeFilter(cfg) end
    else
        color(colors.red); print("FAIL: " .. tostring(result))
        resetColor()
    end

    local timer = os.startTimer(cfg.interval)
    while true do
        local ev, p1 = os.pullEvent()
        if ev == "timer" and p1 == timer then break
        elseif ev == "key" and p1 == keys.q then print("Quitting."); return
        end
    end
end
