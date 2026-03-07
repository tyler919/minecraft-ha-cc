-- scanner.lua
-- Auto-discovers all connected peripherals, extracts data from each,
-- and reports everything to Home Assistant.
--
-- Setup: set HA_URL and COMPUTER_ID below, then run: scanner

-- ============================================================
-- CONFIG
-- ============================================================
local HA_URL       = "http://192.168.1.X:8123/api/webhook/YOUR_WEBHOOK_ID"
local COMPUTER_ID  = "scanner_1"
local POLL_INTERVAL = 15        -- seconds between scans
local MAX_ITEMS    = 25         -- max unique item types to list per inventory

-- ============================================================
-- PERIPHERAL HANDLERS
-- Each handler(periph, side) returns a flat key/value table.
-- Keys become sensor names in HA: <side>_<key>
-- Return nil to skip this peripheral entirely.
-- ============================================================
local handlers = {}

-- ── Inventory (chests, barrels, any block with an inventory) ──────────────
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

    -- top N items by count
    local sorted = {}
    for name, count in pairs(type_counts) do
        table.insert(sorted, { name = name, count = count })
    end
    table.sort(sorted, function(a, b) return a.count > b.count end)
    local top = {}
    for i = 1, math.min(MAX_ITEMS, #sorted) do
        table.insert(top, sorted[i].name .. "x" .. sorted[i].count)
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

-- ── Monitor ───────────────────────────────────────────────────────────────
handlers["monitor"] = function(p)
    local ok, w, h = pcall(p.getSize)
    if not ok then return nil end
    local _, color = pcall(p.isColor)
    return { width = w, height = h, is_color = color or false }
end

-- ── Disk Drive ────────────────────────────────────────────────────────────
handlers["drive"] = function(p)
    local _, present = pcall(p.isDiskPresent)
    local _, hasData  = pcall(p.hasData)
    local _, hasAudio = pcall(p.hasAudio)
    local label = "none"
    if present then
        local _, l = pcall(p.getDiskLabel)
        label = l or "unlabeled"
    end
    return {
        disk_present = present  or false,
        has_data     = hasData  or false,
        has_audio    = hasAudio or false,
        disk_label   = label,
    }
end

-- ── Printer ───────────────────────────────────────────────────────────────
handlers["printer"] = function(p)
    local _, ink   = pcall(p.getInkLevel)
    local _, paper = pcall(p.getPaperLevel)
    return { ink_level = ink or 0, paper_level = paper or 0 }
end

-- ── Modem ─────────────────────────────────────────────────────────────────
handlers["modem"] = function(p)
    local _, wireless = pcall(p.isWireless)
    return { is_wireless = wireless or false }
end

-- ── Another Computer ──────────────────────────────────────────────────────
handlers["computer"] = function(p)
    local _, id    = pcall(p.getID)
    local _, label = pcall(p.getLabel)
    local _, on    = pcall(p.isOn)
    return {
        id    = id    or 0,
        label = label or "unlabeled",
        is_on = on    or false,
    }
end

-- ── Advanced Peripherals: Environment Detector ────────────────────────────
handlers["environment_detector"] = function(p)
    local _, biome      = pcall(p.getBiome)
    local _, light      = pcall(p.getLightLevel)
    local _, sky        = pcall(p.getSkyLightLevel)
    local _, time       = pcall(p.getTime)
    local _, day        = pcall(p.getDay)
    local _, moon       = pcall(p.getMoonPhase)
    local _, raining    = pcall(p.isRaining)
    local _, thunder    = pcall(p.isThundering)
    return {
        biome          = biome   or "unknown",
        light_level    = light   or 0,
        sky_light      = sky     or 0,
        world_time     = time    or 0,
        day            = day     or 0,
        moon_phase     = moon    or 0,
        raining        = raining or false,
        thundering     = thunder or false,
    }
end

-- ── Advanced Peripherals: Energy Detector ─────────────────────────────────
handlers["energy_detector"] = function(p)
    local _, rate = pcall(p.getTransferRate)
    local _, max  = pcall(p.getMaxTransferRate)
    return { transfer_rate = rate or 0, max_transfer_rate = max or 0 }
end

-- ── Advanced Peripherals: Player Detector ─────────────────────────────────
handlers["player_detector"] = function(p)
    local _, list = pcall(p.getOnlinePlayers)
    local players = (type(list) == "table") and list or {}
    return { player_count = #players, players = players }
end

-- ── Advanced Peripherals: ME Bridge (AE2) ─────────────────────────────────
handlers["me_bridge"] = function(p)
    local _, items      = pcall(p.listItems)
    local _, energy     = pcall(p.getEnergyStorage)
    local _, maxEnergy  = pcall(p.getMaxEnergyStorage)
    local _, craftables = pcall(p.listCraftableItems)

    local item_count, type_count = 0, 0
    if type(items) == "table" then
        type_count = #items
        for _, item in ipairs(items) do
            item_count = item_count + (item.amount or 0)
        end
    end

    return {
        total_items      = item_count,
        unique_types     = type_count,
        craftable_types  = type(craftables) == "table" and #craftables or 0,
        energy           = energy    or 0,
        max_energy       = maxEnergy or 0,
    }
end

-- ── Advanced Peripherals: RS Bridge (Refined Storage) ─────────────────────
handlers["rs_bridge"] = function(p)
    local _, items    = pcall(p.listItems)
    local _, energy   = pcall(p.getEnergyUsage)
    local _, maxE     = pcall(p.getMaxEnergyStorage)
    local _, patterns = pcall(p.getPatternCount)

    local item_count, type_count = 0, 0
    if type(items) == "table" then
        type_count = #items
        for _, item in ipairs(items) do
            item_count = item_count + (item.amount or 0)
        end
    end

    return {
        total_items    = item_count,
        unique_types   = type_count,
        energy_usage   = energy   or 0,
        max_energy     = maxE     or 0,
        pattern_count  = patterns or 0,
    }
end

-- ── Generic Energy Storage (RF/FE, many mods) ─────────────────────────────
handlers["energy_storage"] = function(p)
    local _, e  = pcall(p.getEnergy)
    if not e then _, e = pcall(p.getEnergyStored) end
    local _, mx = pcall(p.getEnergyCapacity)
    if not mx then _, mx = pcall(p.getMaxEnergyStored) end
    e, mx = e or 0, mx or 0
    return {
        energy     = e,
        max_energy = mx,
        percent    = mx > 0 and math.floor((e / mx) * 100) or 0,
    }
end

-- ── Fluid Storage ─────────────────────────────────────────────────────────
handlers["fluid_storage"] = function(p)
    local _, tanks = pcall(p.tanks)
    if not tanks or type(tanks) ~= "table" then return nil end
    local names, total, capacity = {}, 0, 0
    for _, tank in ipairs(tanks) do
        if tank.name then
            table.insert(names, tank.name:match("[^:]+$") .. "x" .. (tank.amount or 0) .. "mb")
        end
        total    = total    + (tank.amount   or 0)
        capacity = capacity + (tank.capacity or 0)
    end
    return {
        tank_count = #tanks,
        total_mb   = total,
        capacity_mb = capacity,
        contents   = table.concat(names, ", "),
    }
end

-- ── Turtle self-report (if running on a turtle) ───────────────────────────
local function getTurtleData()
    if not turtle then return nil end
    local _, fuel    = pcall(turtle.getFuelLevel)
    local _, fuelMax = pcall(turtle.getFuelLimit)
    local _, sel     = pcall(turtle.getSelectedSlot)
    return {
        fuel      = fuel    or 0,
        fuel_max  = fuelMax or 0,
        fuel_pct  = (fuelMax and fuelMax > 0) and math.floor((fuel / fuelMax) * 100) or 0,
        selected_slot = sel or 1,
    }
end

-- ============================================================
-- SCAN
-- Wraps each peripheral, calls its handler, and builds a flat
-- payload where every key is prefixed with the sanitised side name.
-- ============================================================
local function sanitise(name)
    -- "minecraft:chest_0" → "minecraft_chest_0"
    return name:lower():gsub("[^a-z0-9]", "_")
end

local function scan()
    local payload = {
        computer_id  = COMPUTER_ID,
        online       = true,
        label        = os.getComputerLabel() or "unlabeled",
        uptime       = os.clock(),
        periph_count = 0,
    }

    -- Turtle data
    local tdata = getTurtleData()
    if tdata then
        for k, v in pairs(tdata) do
            payload["turtle_" .. k] = v
        end
    end

    -- Peripheral data
    local names = peripheral.getNames()
    payload.periph_count = #names

    for _, name in ipairs(names) do
        local ptype = peripheral.getType(name)
        local p     = peripheral.wrap(name)
        if not p or not ptype then goto continue end

        local prefix = sanitise(name) .. "_"
        -- always report the type
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

        ::continue::
    end

    return payload
end

-- ============================================================
-- SEND
-- ============================================================
local function send(payload)
    local body = textutils.serialiseJSON(payload)
    local res, err = http.post(
        HA_URL,
        body,
        { ["Content-Type"] = "application/json" }
    )
    if not res then return false, tostring(err) end
    local raw = res.readAll()
    res.close()
    local ok, result = pcall(textutils.unserialiseJSON, raw)
    return true, (ok and result or nil)
end

local function handleCommands(cmds)
    if not cmds or #cmds == 0 then return end
    for _, cmd in ipairs(cmds) do
        print("[CMD] " .. tostring(cmd.command))
        if cmd.command == "reboot" then
            os.reboot()
        elseif cmd.command == "scan_now" then
            -- handled by breaking the wait loop
            return true
        end
    end
end

-- ============================================================
-- MAIN LOOP
-- ============================================================
print("=== HA Peripheral Scanner ===")
print("Scanning every " .. POLL_INTERVAL .. "s  |  Q = quit")
print("")

while true do
    io.write("[SCAN] ")
    local payload = scan()
    io.write(payload.periph_count .. " peripheral(s)... ")

    local ok, result = send(payload)
    if ok then
        local cmds = result and result.commands or {}
        print("sent  (" .. #cmds .. " cmd(s))")
        local force = handleCommands(cmds)
        if force then goto scan_now end
    else
        print("FAIL: " .. tostring(result))
    end

    -- Wait POLL_INTERVAL seconds, but allow Q to quit or scan_now to skip wait
    local timer = os.startTimer(POLL_INTERVAL)
    while true do
        local ev, p1 = os.pullEvent()
        if ev == "timer" and p1 == timer then break
        elseif ev == "key" and p1 == keys.q then
            print("Quitting.")
            return
        end
    end

    ::scan_now::
end
