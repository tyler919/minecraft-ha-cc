-- scanner.lua
-- First run (or `scanner setup`): interactive setup wizard
-- Subsequent runs: loads config and scans peripherals
-- Usage:
--   scanner          normal run (auto-updates on startup)
--   scanner setup    re-run setup wizard
--   scanner update   force update even if version matches
--   scanner log      print the in-memory log to a connected printer

local VERSION        = 10
local CONFIG_FILE    = "scanner_config.json"
local POLL_INTERVAL  = 15
local MAX_ITEMS      = 25
local PAUSE_INTERVAL = 30   -- seconds between checks while paused

local VERSION_URL  = "https://raw.githubusercontent.com/tyler919/minecraft-ha-cc/main/version.json"
local SCRIPT_URL   = "https://raw.githubusercontent.com/tyler919/minecraft-ha-cc/main/scanner.lua"
local SCRIPT_PATH  = shell.getRunningProgram()
local SETUP_FLAG   = "scanner_setup_pending"   -- written before update reboot

-- Energy rate tracking (persists across scans within a session)
local prevEnergy = {}  -- [peripheral_name] = { energy = N, time = N }

-- Log buffer
local LOG_MAX        = 100   -- entries kept in memory
local PRINTER_WIDTH  = 25    -- CC printer page width (chars)
local PRINTER_HEIGHT = 21    -- CC printer page height (lines)
local logBuffer = {}

-- ============================================================
-- MODULE DEFINITIONS
-- Each module owns a set of peripheral types.
-- Only enabled modules have their handlers run.
-- ============================================================
local MODULES = {
    -- types lists both snake_case (vanilla/some mods) and camelCase (Advanced Peripherals)
    { id = "power",       label = "Power & Energy",                  desc = "Energy storage, RF/FE meters",            types = {"energy_storage", "energyStorage", "energy_detector", "energyDetector"} },
    { id = "storage",     label = "Storage & Inventories",           desc = "Chests, barrels, any inventory block",     types = {"inventory", "drive"} },
    { id = "me",          label = "ME System  (Applied Energistics)", desc = "Item counts, energy, craftables",         types = {"me_bridge", "meBridge"} },
    { id = "rs",          label = "Refined Storage",                  desc = "Item counts, energy, patterns",           types = {"rs_bridge", "rsBridge"} },
    { id = "environment", label = "Environment",                      desc = "Weather, time, light level, biome",       types = {"environment_detector", "environmentDetector"} },
    { id = "players",     label = "Player Detection",                 desc = "Online players list and count",           types = {"player_detector", "playerDetector"} },
    { id = "fluids",      label = "Fluids & Tanks",                   desc = "Tank contents, capacity",                 types = {"fluid_storage", "fluidStorage"} },
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
-- LOGGING
-- ============================================================
local function logAdd(level, msg)
    table.insert(logBuffer, { t = os.clock(), level = level, msg = msg })
    if #logBuffer > LOG_MAX then table.remove(logBuffer, 1) end
end

-- Print the log buffer to a connected printer.
local function printLog()
    -- Find a printer peripheral
    local printerName = nil
    for _, name in ipairs(peripheral.getNames()) do
        local ptypes = { peripheral.getType(name) }
        for _, t in ipairs(ptypes) do
            if t == "printer" then printerName = name; break end
        end
        if printerName then break end
    end

    if not printerName then
        color(colors.red)
        print("[LOG] No printer found. Connect a printer to this computer.")
        resetColor()
        return
    end

    local p = peripheral.wrap(printerName)

    if p.getPaperLevel() == 0 then
        color(colors.red); print("[LOG] Printer is out of paper."); resetColor()
        return
    end
    if p.getInkLevel() == 0 then
        color(colors.red); print("[LOG] Printer is out of ink."); resetColor()
        return
    end

    if #logBuffer == 0 then
        print("[LOG] Log is empty — nothing to print.")
        return
    end

    local pageNum  = 1
    local lineNum  = 1

    local function newPage()
        p.newPage()
        p.setPageTitle("ScannerLog p" .. pageNum)
        lineNum = 1
    end

    local function writeLine(text)
        -- Hard-wrap at PRINTER_WIDTH
        while #text > 0 do
            if p.getPaperLevel() == 0 then return false end
            p.setCursorPos(1, lineNum)
            p.write(text:sub(1, PRINTER_WIDTH))
            text = text:sub(PRINTER_WIDTH + 1)
            lineNum = lineNum + 1
            if lineNum > PRINTER_HEIGHT and #text > 0 then
                p.endPage()
                pageNum = pageNum + 1
                newPage()
            end
        end
        return true
    end

    newPage()
    for _, entry in ipairs(logBuffer) do
        local line = string.format("%5ds %s %s", math.floor(entry.t), entry.level, entry.msg)
        if not writeLine(line) then break end
        if lineNum > PRINTER_HEIGHT then
            p.endPage()
            if p.getPaperLevel() == 0 then break end
            pageNum = pageNum + 1
            newPage()
        end
    end
    p.endPage()

    color(colors.green)
    print("[LOG] Printed " .. #logBuffer .. " entries across " .. pageNum .. " page(s).")
    resetColor()
end

-- ============================================================
-- AUTO-UPDATE
-- ============================================================

-- Checks GitHub for a newer version.
-- force = true  → download even if version matches (manual override)
-- silent = true → only print if something happens
local function checkForUpdates(force, silent)
    if not silent then
        color(colors.cyan)
        io.write("[UPDATE] Checking for updates (current v" .. VERSION .. ")... ")
        resetColor()
    end

    -- Fetch version.json
    local res, err = http.get(VERSION_URL)
    if not res then
        if not silent then
            color(colors.red)
            print("FAILED")
            print("  Could not reach update server: " .. tostring(err))
            print("  Check your internet connection or try again later.")
            resetColor()
        end
        return false
    end

    local raw = res.readAll()
    res.close()

    local ok, data = pcall(textutils.unserialiseJSON, raw)
    if not ok or type(data) ~= "table" or not data.scanner then
        if not silent then
            color(colors.red)
            print("FAILED")
            print("  Invalid version data received.")
            resetColor()
        end
        return false
    end

    local remote = data.scanner

    if not force and remote <= VERSION then
        if not silent then
            color(colors.green)
            print("Up to date  (v" .. VERSION .. ")")
            resetColor()
        end
        return false
    end

    if force and remote <= VERSION then
        color(colors.yellow)
        print("Force re-installing v" .. VERSION .. "...")
        resetColor()
    else
        color(colors.yellow)
        print("Update found!  v" .. VERSION .. " → v" .. remote)
        if data.changelog then
            color(colors.gray)
            print("  " .. data.changelog)
        end
        resetColor()
    end

    -- Download new script
    io.write("[UPDATE] Downloading... ")
    local dl, dl_err = http.get(SCRIPT_URL)
    if not dl then
        color(colors.red)
        print("FAILED")
        print("  Download error: " .. tostring(dl_err))
        print("  Manual fix: wget " .. SCRIPT_URL .. " " .. SCRIPT_PATH)
        resetColor()
        return false
    end

    local new_code = dl.readAll()
    dl.close()

    -- Basic sanity check — a valid Lua script will be much larger than this
    if not new_code or #new_code < 200 then
        color(colors.red)
        print("FAILED")
        print("  Downloaded file looks empty or corrupt.")
        print("  Manual fix: wget " .. SCRIPT_URL .. " " .. SCRIPT_PATH)
        resetColor()
        return false
    end

    -- Write to disk
    local f = fs.open(SCRIPT_PATH, "w")
    if not f then
        color(colors.red)
        print("FAILED")
        print("  Cannot write to " .. SCRIPT_PATH .. " — is the file read-only?")
        print("  Manual fix: delete " .. SCRIPT_PATH .. " then run:")
        print("    wget " .. SCRIPT_URL .. " " .. SCRIPT_PATH)
        resetColor()
        return false
    end
    f.write(new_code)
    f.close()

    color(colors.green)
    print("Done!  Rebooting in 2s...")
    resetColor()

    -- Flag setup to run automatically after the reboot
    local fl = fs.open(SETUP_FLAG, "w")
    if fl then fl.write("1"); fl.close() end

    sleep(2)
    os.reboot()
    return true  -- unreachable after reboot, but just in case
end

-- ============================================================
-- SETUP WIZARD
-- ============================================================
-- oldCfg: existing config table (may be nil on first run)
local function runSetup(oldCfg)
    header("HA Scanner — Setup")

    print("You can re-run this any time with:  scanner setup")
    print("")

    -- ── Keep existing basics? ────────────────────────────────────────────

    local url, comp_id, interval

    if oldCfg and oldCfg.url and oldCfg.id and oldCfg.interval then
        color(colors.yellow)
        print("Existing configuration found:")
        resetColor()
        color(colors.gray)
        print("  Webhook  : " .. oldCfg.url)
        print("  Name     : " .. oldCfg.id)
        print("  Interval : " .. oldCfg.interval .. "s")
        resetColor()
        print("")

        if confirm("Keep these basic settings?") then
            url      = oldCfg.url
            comp_id  = oldCfg.id
            interval = oldCfg.interval
            color(colors.green)
            print("Basic settings carried over.")
            resetColor()
        end
        print("")
    end

    -- ── Ask for basics only if not carried over ──────────────────────────

    if not url then
        url = ask("Home Assistant webhook URL", "http://192.168.1.X:8123/api/webhook/YOUR_ID")
        while url == "" or url:find("YOUR_ID") do
            color(colors.red)
            print("Please enter a valid URL.")
            resetColor()
            url = ask("Webhook URL")
        end

        local default_id = "scanner_" .. os.getComputerID()
        comp_id = ask("Name for this computer", default_id)
        if comp_id == "" then comp_id = default_id end

        local interval_str = ask("Scan interval in seconds", tostring(POLL_INTERVAL))
        interval = tonumber(interval_str) or POLL_INTERVAL
    end

    -- ── Module selection ─────────────────────────────────────────────────

    color(colors.yellow)
    print("Module setup:")
    resetColor()
    print("  1. Quick  — enable all modules")
    print("  2. Custom — choose which modules to enable")
    print("")
    color(colors.cyan)
    io.write("Press 1 or 2: ")
    resetColor()

    local quickMode = false
    while true do
        local _, key = os.pullEvent("key")
        if key == keys.one then
            quickMode = true
            print("1")
            break
        elseif key == keys.two then
            print("2")
            break
        end
    end
    print("")

    -- ── Module selection (full setup only) ───────────────────────────────

    local enabled = {}
    for i = 1, #MODULES do
        enabled[i] = true  -- default: all on
    end

    if not quickMode then
        print("")
        color(colors.yellow)
        print("Select modules:")
        resetColor()
        color(colors.gray)
        print("  Up/Down=move  Space=toggle  A=all  N=none  Enter=done")
        resetColor()
        print("")

        -- Figure out how many rows we can use for the list
        local W, H = term.getSize()
        local _, listY = term.getCursorPos()
        local visRows = H - listY  -- rows left on screen
        if visRows < 1 then visRows = 1 end

        local cursor = 1
        local offset = 0  -- index of first visible module (0-based)

        local function clamp()
            if cursor - 1 < offset then offset = cursor - 1 end
            if cursor - 1 >= offset + visRows then offset = cursor - 1 - visRows + 1 end
            if offset < 0 then offset = 0 end
        end

        local function drawList()
            for row = 1, visRows do
                local idx = offset + row
                term.setCursorPos(1, listY + row - 1)

                if idx > #MODULES then
                    -- Clear any leftover line from a previous draw
                    if USE_COLOR then term.setBackgroundColor(colors.black) end
                    term.clearLine()
                else
                    local mod    = MODULES[idx]
                    local isCur  = (idx == cursor)

                    -- Highlight current row with a gray background
                    if USE_COLOR then
                        term.setBackgroundColor(isCur and colors.gray or colors.black)
                    end
                    term.clearLine()

                    -- Cursor arrow
                    if USE_COLOR then term.setTextColor(colors.yellow) end
                    io.write(isCur and " > " or "   ")

                    -- Checkbox
                    if enabled[idx] then
                        if USE_COLOR then term.setTextColor(colors.green) end
                        io.write("[X] ")
                    else
                        if USE_COLOR then term.setTextColor(colors.lightGray) end
                        io.write("[ ] ")
                    end

                    -- Module label
                    if USE_COLOR then term.setTextColor(colors.white) end
                    io.write(mod.label)

                    -- Description, truncated to fit remaining width
                    local used  = 3 + 4 + #mod.label  -- " > " + "[X] " + label
                    local avail = W - used - 4          -- " -- " separator (4 chars)
                    if avail > 4 then
                        local desc = mod.desc
                        if #desc > avail then desc = desc:sub(1, avail - 2) .. ".." end
                        if USE_COLOR then term.setTextColor(colors.gray) end
                        io.write(" -- " .. desc)
                    end

                    -- Always reset colours after each row
                    if USE_COLOR then
                        term.setBackgroundColor(colors.black)
                        term.setTextColor(colors.white)
                    end
                end
            end

            -- Scroll indicators on the right edge
            if offset > 0 then
                term.setCursorPos(W, listY)
                if USE_COLOR then term.setTextColor(colors.yellow) end
                io.write("^")
                if USE_COLOR then term.setTextColor(colors.white) end
            end
            if offset + visRows < #MODULES then
                term.setCursorPos(W, listY + visRows - 1)
                if USE_COLOR then term.setTextColor(colors.yellow) end
                io.write("v")
                if USE_COLOR then term.setTextColor(colors.white) end
            end
        end

        clamp()
        drawList()

        while true do
            local _, key = os.pullEvent("key")
            if key == keys.up then
                if cursor > 1 then cursor = cursor - 1; clamp(); drawList() end
            elseif key == keys.down then
                if cursor < #MODULES then cursor = cursor + 1; clamp(); drawList() end
            elseif key == keys.space then
                enabled[cursor] = not enabled[cursor]; drawList()
            elseif key == keys.a then
                for i = 1, #MODULES do enabled[i] = true  end; drawList()
            elseif key == keys.n then
                for i = 1, #MODULES do enabled[i] = false end; drawList()
            elseif key == keys.enter then
                break
            end
        end

        -- Move the cursor below the list before continuing
        term.setCursorPos(1, listY + visRows)
        if USE_COLOR then term.setBackgroundColor(colors.black) end
        print("")
    else
        color(colors.gray)
        print("(All modules enabled — run 'scanner setup' to customise)")
        resetColor()
        print("")
    end

    -- ── Build and save config ─────────────────────────────────────────────

    local cfg = {
        url      = url,
        id       = comp_id,
        interval = interval,
        modules  = {},
    }
    for i, mod in ipairs(MODULES) do
        cfg.modules[mod.id] = enabled[i]
    end

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

-- camelCase aliases for Advanced Peripherals (which uses camelCase type names)
handlers["meBridge"]            = handlers["me_bridge"]
handlers["rsBridge"]            = handlers["rs_bridge"]
handlers["energyDetector"]      = handlers["energy_detector"]
handlers["energyStorage"]       = handlers["energy_storage"]
handlers["environmentDetector"] = handlers["environment_detector"]
handlers["playerDetector"]      = handlers["player_detector"]
handlers["fluidStorage"]        = handlers["fluid_storage"]

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
        -- peripheral.getType() returns multiple values in CC:T 1.20+
        -- (e.g. "minecraft:chest", "inventory") — check all of them
        local ptypes = { peripheral.getType(name) }
        local ptype = nil
        for _, t in ipairs(ptypes) do
            if allowed[t] then
                ptype = t
                break
            end
        end

        if ptype then
            local p = peripheral.wrap(name)
            if p then
                active = active + 1
                local prefix = sanitise(name) .. "_"
                payload[sanitise(name) .. "_type"] = ptype
                local handler = handlers[ptype]
                if handler then
                    local ok, data = pcall(handler, p)
                    if ok and type(data) == "table" then
                        logAdd("INFO", "periph " .. name .. " (" .. ptype .. "): OK")

                        -- Energy rate: FE/s (positive = charging, negative = draining)
                        if (ptype == "energy_storage" or ptype == "energyStorage")
                                and type(data.energy) == "number" then
                            local now  = os.clock()
                            local prev = prevEnergy[name]
                            if prev and (now - prev.time) > 0 then
                                data.energy_rate = math.floor(
                                    (data.energy - prev.energy) / (now - prev.time)
                                )
                            end
                            prevEnergy[name] = { energy = data.energy, time = now }
                        end

                        for k, v in pairs(data) do
                            payload[prefix .. k] = v
                        end
                    else
                        logAdd("WARN", "periph " .. name .. " (" .. ptype .. "): handler error")
                    end
                else
                    logAdd("INFO", "periph " .. name .. " (" .. ptype .. "): no handler")
                end
            end
        else
            -- Peripheral exists but no module covers it — log raw types
            logAdd("INFO", "skip " .. name .. " types=" .. table.concat(ptypes, ","))
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
        if cmd.command == "reboot"       then os.reboot() end
        if cmd.command == "setup"        then return "setup" end
        if cmd.command == "scan_now"     then return "scan_now" end
        if cmd.command == "pause"        then return "pause" end
        if cmd.command == "ready"        then return "ready" end
        if cmd.command == "update"       then checkForUpdates(false, false) end
        if cmd.command == "force_update" then checkForUpdates(true,  false) end
    end
    return false
end

-- Polls HA with a GET (no data sent) while waiting for "ready".
-- Returns true once "ready" is received.
local function waitForReady(url, comp_id)
    while true do
        color(colors.yellow)
        io.write("[PAUSED] Waiting for HA... ")
        resetColor()

        local res, err = http.get(url .. "?computer_id=" .. comp_id)
        if not res then
            color(colors.red)
            print("offline  (" .. tostring(err) .. ")")
            resetColor()
        else
            local raw = res.readAll()
            res.close()
            local ok, result = pcall(textutils.unserialiseJSON, raw)
            if ok and type(result) == "table" then
                local action = handleCommands(result.commands or {})
                if action == "ready" then
                    color(colors.green)
                    print("HA is ready! Resuming scanner.")
                    resetColor()
                    return true
                end
            end
            color(colors.gray)
            print("still waiting...")
            resetColor()
        end

        -- Wait PAUSE_INTERVAL seconds or Q to quit
        local t = os.startTimer(PAUSE_INTERVAL)
        while true do
            local ev, p1 = os.pullEvent()
            if ev == "timer" and p1 == t then break
            elseif ev == "key" and p1 == keys.q then
                print("Quitting.")
                return false
            end
        end
    end
end

-- ============================================================
-- MAIN
-- ============================================================
local args = { ... }

-- ── Handle CLI arguments ──────────────────────────────────────────────────
if args[1] == "update" then
    -- Manual update override — force download even if already up to date
    header("HA Scanner — Manual Update")
    checkForUpdates(true, false)
    -- If update failed (no reboot happened), exit cleanly
    print("No update applied. Script is unchanged.")
    return
end

if args[1] == "log" then
    -- Print the current log buffer to a connected printer
    -- (log will be empty on a fresh start since scanning hasn't run yet)
    header("HA Scanner — Print Log")
    printLog()
    return
end

-- ── Auto-update check on startup (silent unless update found) ────────────
checkForUpdates(false, true)

-- ── Load or run setup ─────────────────────────────────────────────────────
local cfg = loadConfig()

-- Check for post-update setup flag (written by checkForUpdates before reboot)
local postUpdateSetup = fs.exists(SETUP_FLAG)
if postUpdateSetup then
    fs.delete(SETUP_FLAG)
    color(colors.yellow)
    print("[UPDATE] Update applied. Launching setup...")
    resetColor()
    print("")
end

if not cfg or args[1] == "setup" or postUpdateSetup then
    cfg = runSetup(cfg)
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
color(colors.gray); print("Press Q to quit | P to print log | run 'scanner setup' to reconfigure")
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
        logAdd("INFO", "send OK cmds=" .. #cmds .. " periph=" .. payload.periph_count)
        local action = handleCommands(cmds)
        if action == "setup" then
            cfg = runSetup(cfg); allowed = buildTypeFilter(cfg)
        elseif action == "pause" then
            color(colors.yellow)
            print("[PAUSED] Integration updating. Waiting for HA...")
            resetColor()
            local resumed = waitForReady(cfg.url, cfg.id)
            if not resumed then return end
            goto scan_now
        end
    else
        -- Connection failed — assume HA is restarting, enter wait mode
        logAdd("ERR", "send FAIL: " .. tostring(result))
        color(colors.red); print("FAIL: " .. tostring(result))
        color(colors.yellow)
        print("[PAUSED] Connection lost. Waiting for HA to come back...")
        resetColor()
        local resumed = waitForReady(cfg.url, cfg.id)
        if not resumed then return end
        goto scan_now
    end

    local timer = os.startTimer(cfg.interval)
    while true do
        local ev, p1 = os.pullEvent()
        if ev == "timer" and p1 == timer then break
        elseif ev == "key" and p1 == keys.q then print("Quitting."); return
        elseif ev == "key" and p1 == keys.p then printLog()
        end
    end

    ::scan_now::
end
