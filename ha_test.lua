-- ha_test.lua
-- Simple test script for the Minecraft HA webhook integration
-- Place this on any CC: Tweaked computer and run it
--
-- Usage: edit ha_test.lua
--   Set HA_URL to your Home Assistant webhook URL
--   Set COMPUTER_ID to something unique per computer (optional)
--   Run: ha_test

-- ============================================================
-- CONFIG - edit these
-- ============================================================
local HA_URL = "http://192.168.1.X:8123/api/webhook/YOUR_WEBHOOK_ID"
local COMPUTER_ID = "computer_1"
local POLL_INTERVAL = 5  -- seconds between updates
-- ============================================================

local function sendData(data)
    data["computer_id"] = COMPUTER_ID

    local body = textutils.serialiseJSON(data)
    local response, err = http.post(
        HA_URL,
        body,
        { ["Content-Type"] = "application/json" }
    )

    if not response then
        print("[HA] POST failed: " .. tostring(err))
        return nil
    end

    local raw = response.readAll()
    response.close()

    local ok, result = pcall(textutils.unserialiseJSON, raw)
    if not ok or type(result) ~= "table" then
        print("[HA] Bad response: " .. tostring(raw))
        return nil
    end

    return result
end

local function handleCommands(commands)
    if not commands or #commands == 0 then return end

    for _, cmd in ipairs(commands) do
        print("[CMD] " .. tostring(cmd.command))

        -- Add your command handling here
        if cmd.command == "reboot" then
            print("[CMD] Rebooting...")
            os.reboot()

        elseif cmd.command == "say" then
            local msg = cmd.data and cmd.data.message or "Hello from HA!"
            print("[CMD] Say: " .. msg)

        elseif cmd.command == "print_info" then
            print("[CMD] ID=" .. os.getComputerID() .. " Label=" .. tostring(os.getComputerLabel()))

        else
            print("[CMD] Unknown command: " .. tostring(cmd.command))
        end
    end
end

local function buildPayload()
    return {
        online      = true,
        computer_id_num = os.getComputerID(),
        label       = tostring(os.getComputerLabel()),
        uptime      = os.clock(),
        fuel        = turtle and turtle.getFuelLevel() or 0,
        fuel_max    = turtle and turtle.getFuelLimit() or 0,
    }
end

-- Main loop
print("=== HA Webhook Test ===")
print("URL: " .. HA_URL)
print("ID:  " .. COMPUTER_ID)
print("Press Q to quit")
print("")

while true do
    -- Check for quit key (non-blocking)
    local event, key = os.pullEvent("key")
    -- (we check in the timer path below instead)
    _ = event

    local payload = buildPayload()
    io.write("[HA] Sending... ")

    local result = sendData(payload)
    if result then
        print("OK (commands: " .. #(result.commands or {}) .. ")")
        handleCommands(result.commands)
    end

    -- Wait for next poll or keypress
    local timer = os.startTimer(POLL_INTERVAL)
    while true do
        local ev, p1 = os.pullEvent()
        if ev == "timer" and p1 == timer then
            break
        elseif ev == "key" and p1 == keys.q then
            print("Quitting.")
            return
        end
    end
end
