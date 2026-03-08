# minecraft-ha-cc

CC: Tweaked Lua scripts for the [minecraft-ha](https://github.com/tyler919/minecraft-ha) Home Assistant integration.

These scripts run directly on **CC: Tweaked** computers inside Minecraft. They scan all connected peripherals, collect their data, and POST it to your Home Assistant instance automatically — turning your in-game machines into live HA sensors.

---

## How it fits together

This repo is one half of a two-part system:

| Repo | What it is |
|---|---|
| [`minecraft-ha`](https://github.com/tyler919/minecraft-ha) | Home Assistant custom integration — receives data and creates sensors |
| [`minecraft-ha-cc`](https://github.com/tyler919/minecraft-ha-cc) | This repo — Lua scripts that run on CC: Tweaked computers in-game |

```
In-game CC: Tweaked Computer
  ├─ Wired Modem
  ├─ Energy Cell        ──┐
  ├─ ME Bridge          ──┤  scanner.lua scans all of these
  ├─ Chest / Barrel     ──┤  and sends the data via HTTP POST
  ├─ Environment Sensor ──┘
        │
        │  JSON payload every N seconds
        ▼
  Home Assistant Webhook
        │
        ▼
  Auto-created Sensors & Binary Sensors
```

The integration and these scripts were designed to work together. That said, the HA integration accepts any JSON over HTTP — so if you want to write your own client in a different mod or language, you can.

---

## Requirements

- **Minecraft** 1.20.1 (Forge)
- **CC: Tweaked** 1.117.x
- **Advanced Peripherals** (recommended — adds energy, ME, environment, player detection support)
- A running **Home Assistant** instance reachable from your Minecraft machine over HTTP
- The [`minecraft-ha`](https://github.com/tyler919/minecraft-ha) integration installed in HA

---

## Installation

On a CC: Tweaked computer in-game, run:

```
wget https://raw.githubusercontent.com/tyler919/minecraft-ha-cc/main/scanner.lua scanner
```

Then run the scanner:
```
scanner
```

The first time it runs (or any time no config file exists), the setup wizard launches automatically.

---

## Setup Wizard

The wizard runs on first launch and whenever you run `scanner setup`.

### Step 1 — Keep existing settings?
If a config file already exists, the wizard shows the current webhook URL, computer name, and scan interval and asks if you want to keep them. Say **yes** to skip re-entering the basics; say **no** to change them.

### Step 2 — Basic settings (if not kept)
- **Webhook URL** — paste the URL from your HA integration setup (Settings → Devices & Services → Minecraft Webhook → Configure)
- **Computer name** — a label for this computer in HA (e.g. `base_scanner`, `reactor_room`)
- **Scan interval** — how often to send data, in seconds (default: 15)

### Step 3 — Module selection
Choose which peripheral types to scan:

```
Select modules:
  Up/Down = move   Space = toggle   A = all   N = none   Enter = done

 > [X] Power & Energy        -- Energy storage, RF/FE meters
   [X] Storage & Inventories -- Chests, barrels, any inventory block
   [ ] ME System             -- Item counts, energy, craftables
   [X] Refined Storage       -- Item counts, energy, patterns
   [X] Environment           -- Weather, time, light level, biome
   [X] Player Detection      -- Online players list and count
   [X] Fluids & Tanks        -- Tank contents, capacity
   [X] Computers & Devices   -- Monitors, modems, printers, other CCs
```

Press **1** for Quick setup (all modules enabled, skip selection) or **2** for Custom.

---

## Commands

| Command | What it does |
|---|---|
| `scanner` | Normal run — checks for updates silently, loads config, starts scanning |
| `scanner setup` | Re-run the setup wizard (carries over existing settings by default) |
| `scanner update` | Force download the latest version, then auto-launch setup |
| `scanner log` | Print the in-memory log to a connected printer |

### Keys while running

| Key | Action |
|---|---|
| `Q` | Quit the scanner |
| `P` | Print the current log to a connected printer |

---

## Supported Peripherals

All peripherals must be connected via a **Wired Modem** and cable, or placed directly adjacent to the computer.

| Module | Peripheral types | Data reported |
|---|---|---|
| Power & Energy | `energy_storage`, `energyStorage` | Stored FE, max FE, percent, FE/s rate |
| Power & Energy | `energy_detector`, `energyDetector` | Transfer rate, max transfer rate |
| Storage | `inventory` | Slots used/free, total items, unique types, top items list |
| Storage | `drive` | Disk present, has data, has audio, disk label |
| ME System | `me_bridge`, `meBridge` | Total items, unique types, craftable types, energy |
| Refined Storage | `rs_bridge`, `rsBridge` | Total items, unique types, energy usage, pattern count |
| Environment | `environment_detector`, `environmentDetector` | Biome, light level, sky light, world time, day, moon phase, raining, thundering |
| Player Detection | `player_detector`, `playerDetector` | Player count, player list |
| Fluids | `fluid_storage`, `fluidStorage` | Tank count, total mB, capacity mB, contents |
| Computers & Devices | `monitor` | Width, height, is color |
| Computers & Devices | `modem` | Is wireless |
| Computers & Devices | `printer` | Ink level, paper level |
| Computers & Devices | `computer` | ID, label, is on |

If the computer itself is a **turtle**, it also reports fuel level, max fuel, and fuel percentage.

---

## Data Format

Each scan POSTs a flat JSON object to the webhook. Peripheral data is prefixed with the sanitised side/network name:

```json
{
  "computer_id": "base_scanner",
  "online": true,
  "label": "Base Scanner",
  "uptime": 3620.5,
  "periph_count": 3,
  "left_type": "energy_storage",
  "left_energy": 750000,
  "left_max_energy": 1000000,
  "left_percent": 75,
  "left_energy_rate": 1200,
  "top_type": "inventory",
  "top_slots_total": 54,
  "top_slots_used": 31,
  "top_total_items": 4820
}
```

HA creates a sensor for every key automatically.

---

## Auto-Update

On every startup, the scanner silently checks `version.json` on GitHub. If a newer version is available, it downloads the new script, writes a `scanner_setup_pending` flag, and reboots. After the reboot, the setup wizard launches automatically so you can review or adjust settings before scanning resumes.

To force an update manually:
```
scanner update
```

To skip the auto-update on a broken internet connection, the scanner will still start normally if the version check fails.

---

## Pause / Ready Handshake

When the HA integration is reloaded or restarted, it sends a `pause` command to all known computers. The scanner stops sending data and polls HA with a lightweight GET request every 30 seconds until it receives a `ready` signal. This prevents missed data and duplicate sensor creation during HA restarts.

---

## Logging & Printer Support

The scanner keeps the last 100 log entries in memory. Each entry records what peripherals were found, any handler errors, send success/failure, and commands received.

To print the log on paper inside Minecraft, connect a CC: Tweaked **Printer** to the computer (with paper and ink loaded) and press **P** while the scanner is running, or run `scanner log` from the shell.

---

## Configuration File

Settings are saved to `scanner_config.json` in the computer's root directory:

```json
{
  "url": "http://192.168.1.100:8123/api/webhook/minecraft_abc123",
  "id": "base_scanner",
  "interval": 15,
  "modules": {
    "power": true,
    "storage": true,
    "me": false,
    "rs": false,
    "environment": true,
    "players": true,
    "fluids": false,
    "devices": false
  }
}
```

---

## Other Files

### `ha_test.lua`
A minimal test script included for development and debugging. It sends a basic payload (computer ID, label, uptime) to the webhook and prints whatever commands HA returns. It is not part of the scanner and not needed for normal use — it is just useful for verifying that your HA webhook URL is working before running the full scanner.

To use it, open it in the editor (`edit ha_test`) and set `WEBHOOK_URL` at the top, then run it with `ha_test`.

---

## Related

- **[minecraft-ha](https://github.com/tyler919/minecraft-ha)** — the Home Assistant integration this pairs with
- **[CC: Tweaked](https://modrinth.com/mod/cc-tweaked)** — the Minecraft mod these scripts run on
- **[Advanced Peripherals](https://modrinth.com/mod/advanced-peripherals)** — adds the energy, ME, environment, and player detection peripherals

---

## License

MIT — see [LICENSE](LICENSE) for details.
