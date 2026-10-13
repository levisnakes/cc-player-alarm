-- Player Alarm: warns when someone who isn't on the allowed list comes near.
-- Uses an Advanced Peripherals Player Detector. Shows a radar and visit log
-- on a monitor (full color with DirectGPU), logs every visit with time,
-- duration and closest distance, and can sound a redstone alarm, ring a
-- speaker and message allowed players through a Chat Box.

ALLOWED = { "YourName" }  -- players who never trigger the alarm (case doesn't matter)
RANGE = 64                -- detection radius in blocks (server max is 512)
SCAN_SECONDS = 1          -- how often to check
LEAVE_GRACE = 15          -- seconds out of range before a visit counts as over
CLOSE_WARNING = 16        -- warn again if an intruder gets this close

ALARM_SIDE = "bottom"     -- redstone on while an intruder is near; nil = off
CHAT_WARN = true          -- toast online allowed players through a Chat Box
WATCH_JOINS = { "Mechanoo" }  -- enemies: announced in chat to everyone else when they come online
MUTE_MINUTES = 5          -- how long the MUTE button silences the siren and speaker
UNLOCK_SECONDS = 60       -- right-click the detector to unlock MUTE on the monitor
UTC_OFFSET = 0            -- hours added to server time for the log (e.g. -5)

DISCORD_WEBHOOK = nil     -- paste a Discord webhook URL here (in quotes) to post alerts to a channel
DISCORD_MENTION = nil     -- who to ping, e.g. "<@&ROLE_ID>" for a role, "<@USER_ID>" or "@everyone"
DISCORD_BOT_TOKEN = nil   -- your bot's token, for !commands in Discord (keep it secret)
DISCORD_CHANNEL_ID = nil  -- the channel ID the bot reads commands from and answers in (in quotes)
DISCORD_PREFIX = "!"      -- commands start with this
DISCORD_ADMINS = {}       -- Discord user IDs (in quotes) allowed to !mute and !unmute
DISCORD_SAY_ANYONE = true -- false = only admins can !say into Minecraft chat
RADAR_UP = "east"         -- which direction is at the top of the radar: "north", "east", "south" or "west"
RADAR_MODE = "auto"       -- radar view: "players", "threats" or "all"; "auto" = threats when a Create Radar is found
SHIP_WARN = false         -- toast the allowed list when a new ship shows up on the radar

MONITOR = nil             -- nil = the biggest monitor attached
TITLE = "BASE SECURITY"
AUTO_UPDATE = true        -- install new versions from GitHub automatically, keeping these settings

-- Settings in /config.lua override the ones above. Use it for anything you
-- don't want to retype: it survives reinstalls and updates, and one file can
-- be shared by every computer (each program ignores settings it doesn't use).
do
  local path = "/config.lua"
  if fs.exists(path) then
    local fn, err = loadfile(path, "t", _ENV)
    if fn then
      local ok, runErr = pcall(fn)
      if not ok then printError("config.lua: " .. tostring(runErr)) sleep(3) end
    else
      printError("config.lua: " .. tostring(err))
      sleep(3)
    end
  end
end


-- ============================================================ basics

local DIR = "/pwarn"
local function now() return os.epoch("utc") / 1000 end

local function readFile(path, default)
  if not fs.exists(path) then return default end
  local f = fs.open(path, "r")
  local data = textutils.unserialize(f.readAll())
  f.close()
  if data == nil then return default end
  return data
end

local function writeFile(path, data)
  local tmp = path .. ".tmp"
  local f = fs.open(tmp, "w")
  f.write(textutils.serialize(data))
  f.close()
  if fs.exists(path) then fs.delete(path) end
  fs.move(tmp, path)
end

local function fmtDuration(s)
  s = math.max(0, math.floor(s))
  if s >= 3600 then return string.format("%dh %02dm", math.floor(s / 3600), math.floor(s / 60) % 60) end
  if s >= 60 then return string.format("%dm %02ds", math.floor(s / 60), s % 60) end
  return s .. "s"
end

local function fmtWhen(t)
  return os.date("!%m/%d %H:%M", math.floor(t + UTC_OFFSET * 3600))
end

local function clockText()
  return os.date("!%H:%M", math.floor(now() + UTC_OFFSET * 3600))
end

local DIRS = { "N", "NE", "E", "SE", "S", "SW", "W", "NW" }
local function meters(d) return d and (math.floor(d + 0.5) .. "m") or "?" end

local function compass(dx, dz)
  local a = math.deg(math.atan2(dx, -dz)) % 360
  return DIRS[math.floor((a + 22.5) / 45) % 8 + 1]
end

-- ============================================================ saved data

if not fs.exists(DIR) then fs.makeDir(DIR) end

-- Saved list (changed from the computer) plus everything in ALLOWED above.
local allowed = readFile(DIR .. "/allowed", nil) or {}
for _, n in ipairs(ALLOWED) do allowed[n:lower()] = n end
local function saveAllowed() writeFile(DIR .. "/allowed", allowed) end
local function isAllowed(name) return allowed[name:lower()] ~= nil end

local visits = readFile(DIR .. "/visits", {})      -- finished visits, newest last
local active = readFile(DIR .. "/active", {})      -- [name] = visit in progress
local stats = readFile(DIR .. "/stats", {})        -- [name] = { visits, seconds, closest, last }
local detectorPos = readFile(DIR .. "/detector", nil)

local function saveVisits() writeFile(DIR .. "/visits", visits) end
local function saveActive() writeFile(DIR .. "/active", active) end
local function saveStats() writeFile(DIR .. "/stats", stats) end

-- ============================================================ peripherals

local detector, chat, speaker
-- Create Radar: any radar bearing, plane radar or radar monitor on the
-- computer or its cable. Found again whenever peripherals change.
local radars = {}
local updateNow = { want = false, busy = false }  -- UPDATE button -> updater
local radarRange = 0

local radarHasPosition = {}

-- A radar is anything with Create Radar's getTracks command: radar bearings
-- ("create_radar:radar_bearing"), plane radars and radar monitors.
local function findRadars()
  radars = {}
  radarRange = 0
  radarHasPosition = {}
  for _, name in ipairs(peripheral.getNames()) do
    local isRadar = false
    local ok, methods = pcall(peripheral.getMethods, name)
    if ok and type(methods) == "table" then
      for _, m in ipairs(methods) do
        if m == "getTracks" then isRadar = true end
        if m == "getPosition" then radarHasPosition[name] = true end
      end
    end
    if isRadar then
      table.insert(radars, name)
      local ok, range = pcall(peripheral.call, name, "getRange")
      if ok and type(range) == "number" then radarRange = math.max(radarRange, range) end
    end
  end
end

local function findPeripherals()
  findRadars()
  detector = peripheral.find("player_detector") or peripheral.find("playerDetector")
  chat = peripheral.find("chat_box") or peripheral.find("chatBox")
  speaker = peripheral.find("speaker")
end

local function dcall(method, ...)
  if not detector then return false, "no detector" end
  return pcall(detector[method], ...)
end

-- ============================================================ scanning

local present = {}      -- [name] = { name, allowed, dist, dx, dz, y, dim }
local page = "radar"    -- monitor page: radar, people, log or stats
local lastInput = 0     -- last time someone touched the monitor
local scanError = nil
local lastScan = 0

-- Exact distance without knowing where the detector is: binary search on range.
local function measureDistance(name)
  local ok, inside = dcall("isPlayerInRange", RANGE, name)
  if not ok or not inside then return nil end
  local lo, hi = 0, RANGE
  while hi - lo > 1 do
    local mid = math.floor((lo + hi) / 2)
    local okM, r = dcall("isPlayerInRange", mid, name)
    if okM and r then hi = mid else lo = mid end
  end
  return hi
end

local function playerInfo(name)
  local ok, p = dcall("getPlayer", name)
  if not ok or type(p) ~= "table" then ok, p = dcall("getPlayerPos", name) end
  if ok and type(p) == "table" and p.x then return p end
  return nil
end

local function locate(name)
  local info = playerInfo(name)
  local e = { name = name, allowed = isAllowed(name) }
  if info then e.dim = info.dimension end
  if info and detectorPos then
    e.dx = info.x - detectorPos.x
    e.dy = info.y - detectorPos.y
    e.dz = info.z - detectorPos.z
    e.dist = math.sqrt(e.dx * e.dx + e.dy * e.dy + e.dz * e.dz)
  else
    e.dist = measureDistance(name)
  end
  return e
end

-- ============================================================ alerts

local chatQueue = {}
local alertFlash = 0
local muteUntil = 0
local unlockUntil, unlockedBy = 0, nil
local function muted() return now() < muteUntil end
local function unlocked() return now() < unlockUntil end

local function warnAllowed(text, title, skip)
  if not CHAT_WARN or not chat then return end
  local ok, online = dcall("getOnlinePlayers")
  if not ok or type(online) ~= "table" then return end
  for _, p in ipairs(online) do
    if isAllowed(p) and (not skip or p:lower() ~= skip:lower()) then
      table.insert(chatQueue, { player = p, text = text, title = title })
    end
  end
end

-- Discord: posts to a channel webhook. No bot or server needed.
local discordQueue = {}
local discordError = nil

-- ping = true adds DISCORD_MENTION; only used when someone is at the base.
local function discord(title, text, color, ping)
  if not DISCORD_WEBHOOK or DISCORD_WEBHOOK == "" or not http then return end
  table.insert(discordQueue, { title = title, text = text, color = color, ping = ping })
end

local function discordLoop()
  while true do
    local msg = table.remove(discordQueue, 1)
    if msg then
      local body = textutils.serializeJSON({
        username = TITLE,
        content = (msg.ping and DISCORD_MENTION) or "",
        allowed_mentions = { parse = { "roles", "users", "everyone" } },
        embeds = { {
          title = msg.title,
          description = msg.text,
          color = msg.color or 15158332,
          footer = { text = os.date("!%Y-%m-%d %H:%M UTC") },
        } },
      })
      local ok, res, err = pcall(http.post, DISCORD_WEBHOOK, body, { ["Content-Type"] = "application/json" })
      if ok and res then
        res.close()
        discordError = nil
      else
        discordError = tostring(err or res)
      end
      sleep(2)  -- stay well under Discord's webhook rate limit
    else
      sleep(0.5)
    end
  end
end

local RED_C, GREEN_C, AMBER_C, PURPLE_C = 15158332, 3066993, 15844367, 10181046

local function ring()
  if not speaker or muted() then return end
  for i = 1, 3 do
    pcall(speaker.playNote, "bell", 3, 18)
    sleep(0.15)
  end
end

local log = {}  -- recent events for the screen
local function event(text, kind)
  table.insert(log, 1, { t = now(), text = text, kind = kind })
  while #log > 8 do table.remove(log) end
end

local function whereText(name, dist)
  local e = present[name]
  if not dist then return "in range" end
  if e and e.dx then return meters(dist) .. " " .. compass(e.dx, e.dz) end
  return meters(dist)
end

local function onArrive(v)
  local where = whereText(v.name, v.dist)
  discord("Intruder detected", "**" .. v.name .. "** is " .. where .. " from base.", RED_C, true)
  event(v.name .. " arrived (" .. where .. ")", "alert")
  warnAllowed("Intruder " .. v.name .. " is " .. where .. " from base", "Intruder alert")
  alertFlash = now() + 6
  page = "radar"
end

local function onClose(v)
  local where = whereText(v.name, v.dist)
  discord("Intruder getting close", "**" .. v.name .. "** is " .. where .. " from base.", RED_C, true)
  event(v.name .. " is " .. where .. " away", "alert")
  warnAllowed(v.name .. " is getting close: " .. where, "Intruder close")
  alertFlash = now() + 6
end

local function onLeave(v)
  local dur = v.last - v.first
  local closest = meters(v.closest)
  event(v.name .. " left after " .. fmtDuration(dur) .. ", closest " .. closest, "info")
  discord("Intruder left", "**" .. v.name .. "** left after " .. fmtDuration(dur) .. ". Closest: " .. closest .. ".", GREEN_C)
  warnAllowed(v.name .. " left after " .. fmtDuration(dur) .. " (closest " .. closest .. ")", "Intruder left")
  table.insert(visits, { name = v.name, first = v.first, last = v.last, closest = v.closest })
  while #visits > 500 do table.remove(visits, 1) end
  local s = stats[v.name:lower()] or { name = v.name, visits = 0, seconds = 0 }
  s.visits = s.visits + 1
  s.seconds = s.seconds + dur
  s.last = v.last
  if v.closest and (not s.closest or v.closest < s.closest) then s.closest = v.closest end
  stats[v.name:lower()] = s
  saveVisits()
  saveStats()
end

local tracks = {}       -- radar tracks, positioned relative to the base
local seenShips = {}
local shipHistory = {}  -- [id] = { x, z, t, vx, vz } for measuring speed and heading
local shipNumbers, nextNumber = {}, {}  -- numbered per kind: SHIP 1, SHIP 2, TRAIN 1
local MODES = { "players", "threats", "all" }
local mode = readFile(DIR .. "/mode", nil)

local function currentMode()
  if #radars == 0 then return "players" end
  if mode then return mode end
  if RADAR_MODE ~= "auto" then return RADAR_MODE end
  return "threats"
end

-- Where radar tracks are measured from: the calibrated detector, or a plane
-- radar's own position.
local function baseCenter()
  if detectorPos then return detectorPos end
  for _, name in ipairs(radars) do
    if radarHasPosition[name] then
      local ok, pos = pcall(peripheral.call, name, "getPosition")
      if ok and type(pos) == "table" and pos.x then return pos end
    end
  end
end

local function isShip(cat) return cat == "SABLE" or cat == "CONTRAPTION" end

local SHIP_COLOR = { 70, 230, 255 }      -- Sable ships
local CONTRAPTION_COLOR = { 255, 110, 230 }  -- Create contraptions and trains

local function prettyType(id)
  if not id or id == "" then return "Unknown" end
  local name = id:gsub("^[^:]+:", ""):gsub("_", " ")
  return (name:gsub("(%a)(%w*)", function(a, b) return a:upper() .. b end))
end

-- Short label and color for a moving structure: Sable ship vs Create contraption.
local function vesselKind(e)
  if e.category == "SABLE" then return "SHIP", SHIP_COLOR end
  local t = (e.entityType or ""):lower()
  if t:find("carriage") or t:find("train") then return "TRAIN", CONTRAPTION_COLOR end
  if t:find("gantry") then return "GANTRY", CONTRAPTION_COLOR end
  return "CONTRAPTION", CONTRAPTION_COLOR
end

local function scanRadars()
  if #radars == 0 then
    tracks = {}
    return
  end
  local center = baseCenter()
  local byId = {}
  for _, name in ipairs(radars) do
    local ok, list = pcall(peripheral.call, name, "getTracks")
    if ok and type(list) == "table" then
      for _, t in pairs(list) do
        if type(t) == "table" and t.id and type(t.position) == "table" then byId[t.id] = t end
      end
    end
  end

  local out = {}
  for id, t in pairs(byId) do
    local cat = t.category or "MISC"
    if cat ~= "ITEM" then
      local e = { id = id, category = cat, entityType = t.entityType, vel = t.velocity }
      if center then
        e.dx = t.position.x - center.x
        e.dy = t.position.y - center.y
        e.dz = t.position.z - center.z
        e.dist = math.sqrt(e.dx * e.dx + e.dy * e.dy + e.dz * e.dz)
      end
      -- A radar player standing where the detector sees someone gets their name.
      if cat == "PLAYER" and e.dx then
        for name, p in pairs(present) do
          if p.dx and (p.dx - e.dx) ^ 2 + (p.dy - e.dy) ^ 2 + (p.dz - e.dz) ^ 2 < 16 then
            e.name, e.allowed = name, p.allowed
          end
        end
      end
      table.insert(out, e)
    end
  end

  local t = now()
  for _, e in ipairs(out) do
    if isShip(e.category) then
      if not seenShips[e.id] then
        local where = e.dist and (meters(e.dist) .. " " .. compass(e.dx, e.dz)) or "in range"
        local kind = vesselKind(e)
        local word = kind:sub(1, 1) .. kind:sub(2):lower()
        event(word .. " on radar, " .. where, "info")
        if SHIP_WARN then warnAllowed(word .. " detected " .. where, "Radar") end
      end
      seenShips[e.id] = t
    end
  end
  for id, at in pairs(seenShips) do
    if t - at > 60 then seenShips[id] = nil end
  end

  -- Speed and heading from how far each ship moved since the last scan
  -- (blocks per second), smoothed so it doesn't jitter.
  for _, e in ipairs(out) do
    if isShip(e.category) and e.dx then
      if not shipNumbers[e.id] then
        local kind = vesselKind(e)
        nextNumber[kind] = (nextNumber[kind] or 0) + 1
        shipNumbers[e.id] = nextNumber[kind]
      end
      e.number = shipNumbers[e.id]
      local h = shipHistory[e.id]
      if h and t - h.t >= 0.5 then
        local dt = t - h.t
        local vx, vz = (e.dx - h.x) / dt, (e.dz - h.z) / dt
        h.vx = h.vx and (h.vx * 0.5 + vx * 0.5) or vx
        h.vz = h.vz and (h.vz * 0.5 + vz * 0.5) or vz
        h.x, h.z, h.t = e.dx, e.dz, t
      elseif not h then
        h = { x = e.dx, z = e.dz, t = t }
        shipHistory[e.id] = h
      end
      e.vx, e.vz = h.vx or 0, h.vz or 0
      e.speed = math.sqrt(e.vx * e.vx + e.vz * e.vz)
    end
  end
  for id, h in pairs(shipHistory) do
    if t - h.t > 60 then shipHistory[id] = nil end
  end
  tracks = out
end

-- Tracks shown in the current mode. Named players are already drawn from the detector.
local function visibleTracks()
  local m = currentMode()
  local out = {}
  for _, e in ipairs(tracks) do
    local c = e.category
    local show
    if isShip(c) then
      show = true  -- ships are always worth seeing
    elseif m == "players" then
      show = false
    elseif c == "PLAYER" then
      show = e.name == nil
    elseif m == "threats" then
      show = c == "HOSTILE" or c == "PROJECTILE" or isShip(c)
    else
      show = true
    end
    if show then table.insert(out, e) end
  end
  return out
end

local function shipList()
  local list = {}
  for _, e in ipairs(tracks) do
    if isShip(e.category) and e.dist then table.insert(list, e) end
  end
  table.sort(list, function(a, b) return a.dist < b.dist end)
  return list
end

local function shipSpeedText(e)
  if not e.speed or e.speed < 0.3 then return "parked" end
  return math.floor(e.speed + 0.5) .. " m/s"
end

local function radarSummary()
  local ships, hostile, unknown, other, contraptions = 0, 0, 0, 0, 0
  for _, e in ipairs(tracks) do
    if e.category == "SABLE" then ships = ships + 1
    elseif e.category == "CONTRAPTION" then contraptions = contraptions + 1
    elseif e.category == "HOSTILE" then hostile = hostile + 1
    elseif e.category == "PLAYER" and not e.name then unknown = unknown + 1
    else other = other + 1 end
  end
  return ships, hostile, unknown, other, contraptions
end

local function scan()
  if not detector then
    scanError = "No Player Detector found"
    present = {}
    scanRadars()
    return
  end
  local ok, names = dcall("getPlayersInRange", RANGE)
  if not ok or type(names) ~= "table" then
    scanError = "Detector error: " .. tostring(names)
    return
  end
  scanError = nil

  -- Locate everyone in range at once so the checks land in the same ticks.
  local found = {}
  local tasks = {}
  for _, name in ipairs(names) do
    tasks[#tasks + 1] = function() found[name] = locate(name) end
  end
  if #tasks > 0 then parallel.waitForAll(table.unpack(tasks)) end
  present = found

  local t = now()
  local changed = false
  for name, e in pairs(found) do
    if not e.allowed then
      local v = active[name]
      if not v then
        v = { name = name, first = t, last = t, closest = e.dist, warnedClose = false }
        active[name] = v
        v.dist = e.dist
        onArrive(v)
      end
      v.last = t
      v.dist = e.dist
      if e.dist and (not v.closest or e.dist < v.closest) then v.closest = e.dist end
      if e.dist and e.dist <= CLOSE_WARNING and not v.warnedClose then
        v.warnedClose = true
        onClose(v)
      end
      changed = true
    end
  end
  for name, v in pairs(active) do
    if not found[name] and t - v.last > LEAVE_GRACE then
      active[name] = nil
      onLeave(v)
      changed = true
    elseif found[name] and found[name].allowed then
      -- added to the allowed list mid-visit
      active[name] = nil
      changed = true
    end
  end
  if changed then saveActive() end
  lastScan = t
  scanRadars()

  if ALARM_SIDE then rs.setOutput(ALARM_SIDE, next(active) ~= nil and not muted()) end
end

local function scanLoop()
  findPeripherals()
  local rang = {}
  while true do
    local ok, err = pcall(scan)
    if not ok then scanError = tostring(err) end
    for name, v in pairs(active) do
      if not rang[name] then
        rang[name] = true
        ring()
      end
    end
    for name in pairs(rang) do if not active[name] then rang[name] = nil end end
    sleep(SCAN_SECONDS)
  end
end

local function chatLoop()
  while true do
    local msg = table.remove(chatQueue, 1)
    if msg and chat and msg.json then
      local opts = { player = msg.player, prefix = "BASE DEFENSE", brackets = "[]", bracketsColor = "&4" }
      local ok = pcall(chat.sendFormattedMessage, msg.json, opts)
      if not ok then pcall(chat.sendMessage, msg.text, { player = msg.player, prefix = "DEFENSE" }) end
      sleep(1.1)
    elseif msg and chat then
      local okT = pcall(chat.sendToast, { message = msg.text, title = msg.title, player = msg.player, prefix = "Security" })
      if not okT then
        pcall(chat.sendMessage, msg.text, { player = msg.player, prefix = "Security" })
      end
      sleep(1.1)  -- the chat box has a 1 second cooldown
    else
      sleep(0.5)
    end
  end
end

local watched = {}
for _, n in ipairs(WATCH_JOINS) do watched[n:lower()] = true end

-- Watched players currently online, by lower-case name -> display name.
-- Enemy sessions are saved, so a reboot or chunk reload while an enemy is
-- online continues the same session instead of announcing them again.
local enemy = {
  sessions = readFile(DIR .. "/enemies", {}),   -- [lower name] = { name, since, seen }
  log = readFile(DIR .. "/enemylog", {}),       -- { name, kind = "join"/"leave", t, since }
  savedAt = 0,
}
local watchedOnline = {}
for key, sess in pairs(enemy.sessions) do watchedOnline[key] = sess.name end

-- Minecraft chat JSON for the enemy announcement.
local function enemyMessage(name, test)
  local SWORDS = "\226\154\148"  -- U+2694 crossed swords, as UTF-8 bytes
  local parts = {
    { text = SWORDS .. " ENEMY DETECTED " .. SWORDS .. "\n", color = "dark_red", bold = true },
    { text = name, color = "red", bold = true, underlined = true },
    { text = " has entered the server.", color = "gray" },
  }
  if test then table.insert(parts, { text = "  (test, only the allowed list sees this)", color = "dark_gray", italic = true }) end
  -- unicode_strings turns the UTF-8 symbols into \u escapes Minecraft understands;
  -- older CC versions don't have it, so fall back to plain ASCII.
  local ok, json = pcall(textutils.serializeJSON, parts, { unicode_strings = true })
  if not ok then
    parts[1].text = "!! ENEMY DETECTED !!\n"
    json = textutils.serializeJSON(parts)
  end
  return json, "ENEMY DETECTED: " .. name .. " has entered the server."
end

-- Send the enemy announcement only to allowed players who are online, as a test.
local function testEnemyMessage()
  if not chat then return "No Chat Box found" end
  local ok, online = dcall("getOnlinePlayers")
  if not ok or type(online) ~= "table" then return "Couldn't read the online list" end
  local name = WATCH_JOINS[1] or "Mechanoo"
  local json, plain = enemyMessage(name, true)
  local sent = 0
  for _, p in ipairs(online) do
    if isAllowed(p) then
      table.insert(chatQueue, sent + 1, { player = p, json = json, text = plain })
      sent = sent + 1
    end
  end
  if sent == 0 then return "No allowed players online to send it to" end
  return "Test sent to " .. sent .. " allowed player" .. (sent == 1 and "" or "s")
end

-- Everyone online except the enemy hears about it, enemy alerts first in line.
-- In-game warning goes to the allowed list only.
local function announceEnemy(name, online)
  if not chat then return end
  local json, plain = enemyMessage(name)
  local pos = 1
  for _, p in ipairs(online) do
    if isAllowed(p) and p:lower() ~= name:lower() then
      table.insert(chatQueue, pos, { player = p, json = json, text = plain })
      pos = pos + 1
    end
  end
end

local function checkWatched()
  local ok, online = dcall("getOnlinePlayers")
  if not ok or type(online) ~= "table" then return end
  local now_ = {}
  for _, p in ipairs(online) do
    if watched[p:lower()] then now_[p:lower()] = p end
  end
  local t = now()
  local changed = false
  for key, name in pairs(now_) do
    local sess = enemy.sessions[key]
    if not sess then
      -- a new session: announce once
      enemy.sessions[key] = { name = name, since = t, seen = t }
      table.insert(enemy.log, { name = name, kind = "join", t = t })
      event("ENEMY " .. name .. " is online", "alert")
      announceEnemy(name, online)
      discord("Enemy online", "**" .. name .. "** joined the server.", PURPLE_C)
      changed = true
    else
      sess.seen = t
    end
  end
  for key, sess in pairs(enemy.sessions) do
    if not now_[key] then
      local dur = sess.seen - sess.since
      table.insert(enemy.log, { name = sess.name, kind = "leave", t = sess.seen, since = sess.since })
      event(sess.name .. " went offline after " .. fmtDuration(dur), "info")
      discord("Enemy offline", "**" .. sess.name .. "** left the server after " .. fmtDuration(dur) .. ".", AMBER_C)
      enemy.sessions[key] = nil
      changed = true
    end
  end
  while #enemy.log > 300 do table.remove(enemy.log, 1) end
  if changed then writeFile(DIR .. "/enemylog", enemy.log) end
  -- "last seen" is saved at most once a minute so a reboot knows the session is still going
  if changed or t - enemy.savedAt > 60 then
    writeFile(DIR .. "/enemies", enemy.sessions)
    enemy.savedAt = t
  end
  watchedOnline = {}
  for key, sess in pairs(enemy.sessions) do watchedOnline[key] = sess.name end
end

local function watchLoop()
  while true do
    pcall(checkWatched)
    local timer = os.startTimer(5)
    repeat
      local ev, id = os.pullEvent()
    until ev == "watch_check" or (ev == "timer" and id == timer)
  end
end

local function eventLoop()
  while true do
    local ev, a = os.pullEvent()
    if ev == "peripheral" or ev == "peripheral_detach" then
      findPeripherals()
    elseif (ev == "player_join" or ev == "player_leave") and type(a) == "string" and watched[a:lower()] then
      os.queueEvent("watch_check")
    elseif ev == "player_click" and type(a) == "string" then
      if isAllowed(a) then
        unlockUntil, unlockedBy = now() + UNLOCK_SECONDS, a
        event("Controls unlocked by " .. a, "info")
      else
        event(a .. " tried to unlock the controls", "alert")
        warnAllowed(a .. " right-clicked the player detector", "Intruder at the base", a)
      end
    end
  end
end

-- ============================================================ shared view data

local function nearbyList()
  local list = {}
  for _, e in pairs(present) do table.insert(list, e) end
  table.sort(list, function(a, b)
    if a.allowed ~= b.allowed then return not a.allowed end
    return (a.dist or 1e9) < (b.dist or 1e9)
  end)
  return list
end

local function intruderCount()
  local n = 0
  for _ in pairs(active) do n = n + 1 end
  return n
end

local function todayCount()
  local dayStart = math.floor((now() + UTC_OFFSET * 3600) / 86400) * 86400 - UTC_OFFSET * 3600
  local n = 0
  for _, v in ipairs(visits) do if v.first >= dayStart then n = n + 1 end end
  for _, v in pairs(active) do if v.first >= dayStart then n = n + 1 end end
  return n
end

-- ============================================================ Discord bot commands
-- Kept in a block so its many helpers don't count against Lua's limit on
-- top-level locals; only these three names are visible outside.
local botState = { status = nil }   -- last problem talking to Discord, shown on the computer
local botEnabled, botLoop
do

-- Reads the command channel with your bot's token and answers commands like
-- !whoonline. Polls the Discord API every few seconds, so nothing else has
-- to run anywhere.
local E = {
  green = "\240\159\159\162", red = "\240\159\148\180", white = "\226\154\170",
  shield = "\240\159\155\161\239\184\143", swords = "\226\154\148\239\184\143", ship = "\240\159\154\162",
  check = "\226\156\133", cross = "\226\157\140", mute = "\240\159\148\135", clock = "\240\159\149\146",
  pin = "\240\159\147\141", scroll = "\240\159\147\156", chat = "\240\159\146\172", warn = "\226\154\160\239\184\143",
}
local API = "https://discord.com/api/v10"
local sayCooldown = {}        -- [user id] = time of their last !say

function botEnabled()
  return http and DISCORD_BOT_TOKEN and DISCORD_BOT_TOKEN ~= "" and DISCORD_CHANNEL_ID and DISCORD_CHANNEL_ID ~= ""
end

local function api(method, path, body)
  local headers = {
    ["Authorization"] = "Bot " .. DISCORD_BOT_TOKEN,
    ["User-Agent"] = "DiscordBot (https://github.com/levisnakes/cc-player-alarm, 1.0)",
  }
  local ok, res, err, errRes
  if method == "GET" then
    ok, res, err, errRes = pcall(http.get, API .. path, headers)
  else
    headers["Content-Type"] = "application/json"
    ok, res, err, errRes = pcall(http.post, API .. path, body, headers)
  end
  if not ok then return nil, tostring(res) end
  if not res then
    local code = errRes and errRes.getResponseCode and errRes.getResponseCode()
    if errRes then errRes.close() end
    if code == 401 then return nil, "bot token rejected (401)" end
    if code == 403 then return nil, "bot can't see that channel (403)" end
    if code == 404 then return nil, "channel not found (404), check DISCORD_CHANNEL_ID" end
    return nil, code and ("Discord HTTP " .. code) or tostring(err)
  end
  local text = res.readAll()
  res.close()
  return textutils.unserializeJSON(text) or {}, nil
end

local function json(t)
  local ok, out = pcall(textutils.serializeJSON, t, { unicode_strings = true })
  if ok then return out end
  return textutils.serializeJSON(t)
end

-- Snowflake IDs are numbers too big for Lua, so compare them as strings.
local function newer(a, b)
  if #a ~= #b then return #a > #b end
  return a > b
end

local function reply(m, embed)
  local body = json({
    embeds = { embed },
    message_reference = { message_id = m.id },
    allowed_mentions = { parse = textutils.empty_json_array },
  })
  local _, err = api("POST", "/channels/" .. DISCORD_CHANNEL_ID .. "/messages", body)
  if err then botState.status = "reply failed: " .. err end
end

local function isAdmin(m)
  for _, id in ipairs(DISCORD_ADMINS) do
    if tostring(id) == m.author.id then return true end
  end
  return false
end

local function displayName(m)
  return m.author.global_name ~= textutils.json_null and m.author.global_name or m.author.username or "someone"
end

local COMMANDS = {}

COMMANDS.help = function(m)
  local p = DISCORD_PREFIX
  reply(m, {
    title = E.shield .. " " .. TITLE .. " commands",
    color = 5793266,
    description = table.concat({
      "`" .. p .. "whoonline` who's on the server and who's near the base",
      "`" .. p .. "status` alarm status, intruders and enemies",
      "`" .. p .. "visits [n]` the last visits to the base",
      "`" .. p .. "enemylog [n]` when enemies joined and left",
      "`" .. p .. "where <player>` how far a player is from the base",
      "`" .. p .. "say <message>` post a message in Minecraft chat",
      "`" .. p .. "mute [minutes]` / `" .. p .. "unmute` silence the alarm (admins)",
    }, "\n"),
  })
end

COMMANDS.whoonline = function(m)
  local ok, online = dcall("getOnlinePlayers")
  if not ok or type(online) ~= "table" then
    reply(m, { title = E.cross .. " Can't read the online list", color = 15158332 })
    return
  end
  table.sort(online, function(a, b) return a:lower() < b:lower() end)
  local lines = {}
  for _, p in ipairs(online) do
    if watched[p:lower()] then
      table.insert(lines, E.red .. " **" .. p .. "** - ENEMY")
    elseif isAllowed(p) then
      table.insert(lines, E.green .. " " .. p)
    else
      table.insert(lines, E.white .. " " .. p)
    end
  end
  local near = {}
  for _, e in ipairs(nearbyList()) do
    table.insert(near, (e.allowed and E.green or E.red) .. " " .. e.name .. ": " .. meters(e.dist) .. (e.dx and (" " .. compass(e.dx, e.dz)) or ""))
  end
  reply(m, {
    title = "Online now (" .. #online .. ")",
    color = 3447003,
    description = #lines > 0 and table.concat(lines, "\n") or "nobody",
    fields = { { name = E.pin .. " Near the base", value = #near > 0 and table.concat(near, "\n") or "nobody in range" } },
    footer = { text = E.green .. " allowed  " .. E.red .. " enemy  " .. E.white .. " other" },
  })
end

COMMANDS.status = function(m)
  local n = intruderCount()
  local enemies = {}
  for _, sess in pairs(enemy.sessions) do table.insert(enemies, sess.name .. " (since " .. fmtWhen(sess.since) .. ")") end
  local intruderNames = {}
  for name in pairs(active) do table.insert(intruderNames, name) end
  local fields = {
    { name = "Intruders", value = n > 0 and table.concat(intruderNames, ", ") or "none", inline = true },
    { name = "Enemies online", value = #enemies > 0 and table.concat(enemies, ", ") or "none", inline = true },
    { name = "Alarm", value = muted() and (E.mute .. " muted for " .. fmtDuration(muteUntil - now())) or "armed", inline = true },
    { name = "Visits today", value = tostring(todayCount()), inline = true },
  }
  if #radars > 0 then
    local ships, hostile, unknown, _, contraptions = radarSummary()
    table.insert(fields, { name = "Radar", value = ships .. " ships, " .. contraptions .. " contraptions, " .. hostile .. " hostile, " .. unknown .. " unknown players", inline = false })
  end
  reply(m, {
    title = n > 0 and (E.warn .. " " .. n .. " INTRUDER" .. (n > 1 and "S" or "")) or (E.shield .. " Base secure"),
    color = n > 0 and 15158332 or 3066993,
    fields = fields,
  })
end

COMMANDS.visits = function(m, args)
  local count = math.max(1, math.min(15, tonumber(args[1]) or 5))
  local lines = {}
  for i = #visits, math.max(1, #visits - count + 1), -1 do
    local v = visits[i]
    table.insert(lines, "`" .. fmtWhen(v.first) .. "` **" .. v.name .. "** stayed " .. fmtDuration(v.last - v.first) .. ", closest " .. meters(v.closest))
  end
  reply(m, {
    title = E.scroll .. " Last " .. #lines .. " visit" .. (#lines == 1 and "" or "s"),
    color = 15844367,
    description = #lines > 0 and table.concat(lines, "\n") or "no visits logged yet",
  })
end

COMMANDS.where = function(m, args)
  local who = args[1]
  if not who then reply(m, { title = "Usage: " .. DISCORD_PREFIX .. "where <player>", color = 9807270 }) return end
  for name, e in pairs(present) do
    if name:lower() == who:lower() then
      local c = baseCenter()
      local desc = meters(e.dist) .. " from the base" .. (e.dx and (", " .. compass(e.dx, e.dz)) or "")
      if c and e.dx then desc = desc .. "\nat " .. math.floor(c.x + e.dx) .. ", " .. math.floor(c.y + e.dy) .. ", " .. math.floor(c.z + e.dz) end
      reply(m, { title = E.pin .. " " .. name, color = e.allowed and 3066993 or 15158332, description = desc })
      return
    end
  end
  reply(m, { title = E.pin .. " " .. who .. " isn't near the base", color = 9807270 })
end

COMMANDS.say = function(m, args, rest)
  if not DISCORD_SAY_ANYONE and not isAdmin(m) then
    reply(m, { title = E.cross .. " Only admins can use " .. DISCORD_PREFIX .. "say", color = 15158332 })
    return
  end
  if not chat then reply(m, { title = E.cross .. " No Chat Box on the computer", color = 15158332 }) return end
  if rest == "" then reply(m, { title = "Usage: " .. DISCORD_PREFIX .. "say <message>", color = 9807270 }) return end
  local last = sayCooldown[m.author.id]
  if last and now() - last < 10 then
    reply(m, { title = E.clock .. " Slow down, one message every 10 seconds", color = 15844367 })
    return
  end
  sayCooldown[m.author.id] = now()
  local ok, online = dcall("getOnlinePlayers")
  if not ok or type(online) ~= "table" or #online == 0 then
    reply(m, { title = "Nobody is online to see it", color = 9807270 })
    return
  end
  local text = rest:sub(1, 200):gsub("[%c]", " ")
  local parts = {
    { text = "Discord ", color = "blue", bold = true },
    { text = displayName(m), color = "aqua", bold = true },
    { text = ": ", color = "dark_gray" },
    { text = text, color = "white" },
  }
  local okJ, msgJson = pcall(textutils.serializeJSON, parts, { unicode_strings = true })
  if not okJ then msgJson = textutils.serializeJSON(parts) end
  for _, p in ipairs(online) do
    table.insert(chatQueue, { player = p, json = msgJson, text = displayName(m) .. ": " .. text })
  end
  reply(m, { title = E.chat .. " Sent to " .. #online .. " player" .. (#online == 1 and "" or "s"), color = 3066993, description = text })
end

COMMANDS.enemylog = function(m, args)
  local count = math.max(1, math.min(20, tonumber(args[1]) or 10))
  local lines = {}
  for i = #enemy.log, math.max(1, #enemy.log - count + 1), -1 do
    local e = enemy.log[i]
    if e.kind == "join" then
      table.insert(lines, "`" .. fmtWhen(e.t) .. "` " .. E.red .. " **" .. e.name .. "** joined")
    else
      table.insert(lines, "`" .. fmtWhen(e.t) .. "` " .. E.white .. " **" .. e.name .. "** left after " .. fmtDuration(e.t - (e.since or e.t)))
    end
  end
  reply(m, {
    title = E.swords .. " Enemy log",
    color = 10181046,
    description = #lines > 0 and table.concat(lines, "\n") or "no enemy joins logged yet",
  })
end

COMMANDS.mute = function(m, args)
  if not isAdmin(m) then reply(m, { title = E.cross .. " Only admins can mute the alarm", color = 15158332 }) return end
  local minutes = math.max(1, math.min(120, tonumber(args[1]) or MUTE_MINUTES))
  muteUntil = now() + minutes * 60
  event("Alarm muted from Discord by " .. displayName(m), "info")
  reply(m, { title = E.mute .. " Alarm muted for " .. minutes .. " minutes", color = 15844367 })
end

COMMANDS.unmute = function(m)
  if not isAdmin(m) then reply(m, { title = E.cross .. " Only admins can unmute the alarm", color = 15158332 }) return end
  muteUntil = 0
  event("Alarm unmuted from Discord by " .. displayName(m), "info")
  reply(m, { title = E.check .. " Alarm armed again", color = 3066993 })
end
COMMANDS.online = COMMANDS.whoonline
COMMANDS.who = COMMANDS.whoonline

local function handleMessage(m)
  if type(m) ~= "table" or type(m.author) ~= "table" or m.author.bot == true then return end
  local content = m.content
  if type(content) ~= "string" then return end
  if content == "" and (not m.attachments or #m.attachments == 0) and (not m.embeds or #m.embeds == 0) then
    botState.status = "turn on Message Content Intent"
    return
  end
  if content:sub(1, #DISCORD_PREFIX) ~= DISCORD_PREFIX then return end
  local body = content:sub(#DISCORD_PREFIX + 1)
  local cmd, rest = body:match("^(%S+)%s*(.*)$")
  if not cmd then return end
  local fn = COMMANDS[cmd:lower()]
  if not fn then return end
  local args = {}
  for a in rest:gmatch("%S+") do table.insert(args, a) end
  local ok, err = pcall(fn, m, args, rest)
  if not ok then
    botState.status = "command error: " .. tostring(err)
    reply(m, { title = E.cross .. " Something went wrong", color = 15158332, description = tostring(err):sub(1, 200) })
  end
end

function botLoop()
  local lastId = nil
  while true do
    if botEnabled() then
      local path = "/channels/" .. DISCORD_CHANNEL_ID .. "/messages?limit=" .. (lastId and ("20&after=" .. lastId) or "1")
      local msgs, err = api("GET", path)
      if not msgs then
        botState.status = err
        sleep(10)
      else
        if botState.status and not botState.status:find("Intent") then botState.status = nil end
        if not lastId then
          -- start from the newest message, so old commands aren't replayed
          lastId = (msgs[1] and msgs[1].id) or "0"
        else
          table.sort(msgs, function(a, b) return newer(b.id, a.id) end)
          for _, m in ipairs(msgs) do
            if type(m.id) == "string" and newer(m.id, lastId) then lastId = m.id end
            handleMessage(m)
          end
        end
        sleep(3)
      end
    else
      sleep(10)
    end
  end
end
end

-- ============================================================ DirectGPU screen

local gpu, display, W, H
local gpuError = nil
local zoom = RANGE        -- radar scale in blocks (view only)
local selected = nil      -- player name, or "track:<id>" for a radar track
local radarHits = {}      -- { x, y, key } for everything drawn on the radar this frame
local gpuButtons = {}
local function gpuButton(x, y, w, h, action)
  table.insert(gpuButtons, { x = x, y = y, w = w, h = h, action = action })
end

-- Where the viewer is looking on the screen (DirectGPU hover events).
local hover = { x = -1, y = -1, at = 0 }
local function hovered(x, y, w, h)
  return now() - hover.at < 1.5 and hover.x >= x and hover.x <= x + w and hover.y >= y and hover.y <= y + h
end

local scroll = { people = 0, log = 0, stats = 0 }
local drawGpu, findMonitor, setupGpu
do

-- Phosphor screen: green on near-black, amber for warnings, red for alarms.
local FONT = "Monospaced"
local BG = { 3, 9, 5 }
local PANEL = { 7, 18, 10 }       -- faint fill
local LINE = { 22, 64, 34 }       -- frames and dividers
local GRID = { 34, 104, 56 }
local GRID2 = { 15, 44, 24 }
local SWEEP = { 140, 255, 160 }
local MUTED = { 64, 160, 92 }     -- dim phosphor
local WHITE = { 180, 255, 196 }   -- bright phosphor, main text
local GREEN = { 90, 255, 120 }
local RED = { 255, 64, 44 }
local DARKRED = { 96, 18, 12 }
local AMBER = { 255, 176, 32 }
local HOVER = { 12, 38, 20 }
local SCOPE = { 4, 16, 8 }        -- radar background

local function I(v) return math.floor(v + 0.5) end
local function rect(x, y, w, h, c)
  if w <= 0 or h <= 0 then return end
  gpu.fillRect(display, I(x), I(y), I(w), I(h), c[1], c[2], c[3])
end
local function text(s, x, y, c, size, style)
  gpu.drawText(display, s, I(x), I(y), c[1], c[2], c[3], FONT, I(size), style or "plain")
end
local widthCache = {}
local function textWidth(s, size, style)
  local key = s .. "|" .. I(size) .. "|" .. (style or "")
  if not widthCache[key] then
    local m = gpu.measureText(s, FONT, I(size), style or "plain")
    widthCache[key] = (m and m.width) or #s * size * 0.55
  end
  return widthCache[key]
end
local function fit(s, maxW, size, style)
  if textWidth(s, size, style) <= maxW then return s end
  while #s > 1 and textWidth(s .. "..", size, style) > maxW do s = s:sub(1, -2) end
  return s .. ".."
end
local function textRight(s, right, y, c, size, style) text(s, right - textWidth(s, size, style), y, c, size, style) end
local function line(x1, y1, x2, y2, c) gpu.drawLine(display, I(x1), I(y1), I(x2), I(y2), c[1], c[2], c[3]) end
local function circle(cx, cy, r, c, filled) gpu.drawCircle(display, I(cx), I(cy), I(r), c[1], c[2], c[3], filled) end
local function mix(a, b, t)
  return { I(a[1] + (b[1] - a[1]) * t), I(a[2] + (b[2] - a[2]) * t), I(a[3] + (b[3] - a[3]) * t) }
end

function findMonitor()
  if MONITOR then return MONITOR end
  local best, area = nil, 0
  for _, name in ipairs(peripheral.getNames()) do
    if peripheral.hasType(name, "monitor") then
      local ok, w, h = pcall(peripheral.call, name, "getSize")
      if ok and w * h > area then best, area = name, w * h end
    end
  end
  return best
end

function setupGpu()
  gpu = peripheral.find("directgpu")
  local mon = findMonitor()
  if not gpu then gpuError = "no DirectGPU block found" return false end
  if not mon then gpuError = "no monitor found" return false end
  local ok, id = pcall(gpu.autoDetectAndCreateDisplay, mon, 1)
  if not ok then
    gpuError = "couldn't use monitor " .. mon .. ": " .. tostring(id):gsub("^.-:%d+: ", "")
    return false
  end
  display = id
  local info = gpu.getDisplayInfo(display)
  if info.pixelWidth < 400 then
    local res = math.min(4, math.ceil(400 / info.pixelWidth))
    local ok2, id2 = pcall(gpu.autoDetectAndCreateDisplay, mon, res)
    if ok2 then display = id2 info = gpu.getDisplayInfo(display) end
  end
  W, H = info.pixelWidth, info.pixelHeight
  pcall(gpu.setDisplayPersistent, display, true)
  return true
end

-- World direction (dx east, dz south) to a screen angle, turned so RADAR_UP
-- points at the top of the radar.
local UP_TURN = { north = 0, east = math.pi / 2, south = math.pi, west = -math.pi / 2 }
local function screenAngle(dx, dz)
  return math.atan2(dz, dx) - (UP_TURN[RADAR_UP] or 0)
end

-- Blip position: real direction when the detector is calibrated, otherwise a
-- steady angle per name at the measured distance.
local function blipAngle(e)
  if e.dx and e.dz then return screenAngle(e.dx, e.dz) end
  local h = 0
  for i = 1, #e.name do h = (h * 31 + e.name:byte(i)) % 3600 end
  return h / 3600 * 2 * math.pi
end

local function drawRadar(cx, cy, r, small)
  radarHits = {}
  -- Everything except players shrinks as you zoom out and grows as you zoom in.
  local iconScale = math.max(0.35, math.min(1.6, 64 / zoom))
  circle(cx, cy, r, SCOPE, true)
  for i = 1, 4 do
    circle(cx, cy, r * i / 4, (i == 4) and GRID or GRID2, false)
  end
  circle(cx, cy, r - 1, GRID, false)
  line(cx - r, cy, cx + r, cy, GRID2)
  line(cx, cy - r, cx, cy + r, GRID2)
  -- bearing scale: a tick every 10 degrees, longer every 30
  for deg = 0, 350, 10 do
    local a = math.rad(deg)
    local len = (deg % 30 == 0) and 9 or 4
    line(cx + math.cos(a) * (r - len), cy + math.sin(a) * (r - len), cx + math.cos(a) * r, cy + math.sin(a) * r, GRID)
  end
  -- centre crosshair
  line(cx - 7, cy, cx + 7, cy, GRID)
  line(cx, cy - 7, cx, cy + 7, GRID)
  if detectorPos then
    -- compass letters just inside the rim, turned with the radar
    for _, d in ipairs({ { "N", 0, -1 }, { "E", 1, 0 }, { "S", 0, 1 }, { "W", -1, 0 } }) do
      local a = screenAngle(d[2], d[3])
      local lw = textWidth(d[1], small, "bold")
      local lx = cx + math.cos(a) * (r - small - 8) - lw / 2
      local ly = cy + math.sin(a) * (r - small - 8) - small / 2
      text(d[1], lx, ly, d[1] == "N" and AMBER or GRID, small, "bold")
    end
  end

  -- Sweep with a fading trail
  local a0 = (now() * 1.6) % (2 * math.pi)
  for k = 14, 0, -1 do
    local a = a0 - k * 0.045
    local c = mix(SCOPE, SWEEP, (1 - k / 15) ^ 2)
    line(cx, cy, cx + math.cos(a) * r, cy + math.sin(a) * r, c)
  end

  -- Radar tracks
  local SHIP = { 90, 160, 245 }
  local HOST = { 245, 120, 50 }
  local PROJ = { 250, 220, 70 }
  local MOBC = { 70, 130, 90 }
  local UNKNOWN = { 240, 172, 52 }
  for _, t in ipairs(visibleTracks()) do
    if t.dist and t.dx then
      local a = screenAngle(t.dx, t.dz)
      local d = math.min(1, t.dist / zoom) * (r - 6)
      local bx, by = cx + math.cos(a) * d, cy + math.sin(a) * d
      local c = t.category
      if c == "PROJECTILE" then
        local v = t.vel
        if type(v) == "table" and v.x then
          local k = 100 / zoom * (r - 6)
          line(bx, by, bx + v.x * k, by + v.z * k, PROJ)
        end
      end
      local key = "track:" .. t.id
      if not isShip(c) then table.insert(radarHits, { x = bx, y = by, key = key }) end
      if key == selected then circle(bx, by, math.max(5, 8 * iconScale), WHITE, false) end
      if isShip(c) then
        -- drawn in their own pass below so they sit on top
      elseif c == "PROJECTILE" then
        circle(bx, by, math.max(1, 2 * iconScale), PROJ, true)
      elseif c == "HOSTILE" then
        local hs = math.max(1, 3 * iconScale)
        rect(bx - hs, by - hs, hs * 2, hs * 2, HOST)
      elseif c == "PLAYER" then
        circle(bx, by, math.max(2, 4 * iconScale), UNKNOWN, true)
      else
        circle(bx, by, math.max(1, 2 * iconScale), MOBC, true)
      end
    end
  end

  local placed = {}
  local function freeY(lx, ly, lw, lh)
    for _ = 1, 6 do
      local hit = false
      for _, b in ipairs(placed) do
        if lx < b.x + b.w and lx + lw > b.x and ly < b.y + b.h and ly + lh > b.y then hit = true break end
      end
      if not hit then break end
      ly = ly + lh
    end
    table.insert(placed, { x = lx, y = ly, w = lw, h = lh })
    return ly
  end
  -- Ships: a filled hull pointing where it's heading, a fading wake behind,
  -- a dashed line to where it'll be in 5 seconds, and a label.
  for _, t in ipairs(visibleTracks()) do
    if isShip(t.category) and t.dist and t.dx then
      local kind, SHIPC = vesselKind(t)
      local SHIPDARK = mix({ 0, 0, 0 }, SHIPC, 0.35)
      local isSable = t.category == "SABLE"
      local a = screenAngle(t.dx, t.dz)
      local d = math.min(1, t.dist / zoom) * (r - 6)
      local bx, by = cx + math.cos(a) * d, cy + math.sin(a) * d
      local moving = t.speed and t.speed >= 0.3
      local hd = moving and screenAngle(t.vx, t.vz) or -math.pi / 2
      local ch, sh = math.cos(hd), math.sin(hd)
      local function pt(fx, fy) return bx + fx * ch - fy * sh, by + fx * sh + fy * ch end
      local scale = 1.3 * iconScale
      if moving then
        local k = math.min(r, 5 * t.speed / zoom * (r - 6))
        for i = 1, 6 do
          local wx, wy = pt((-8 - i * 4) * scale / 1.3, 0)
          circle(wx, wy, math.max(1, (3 - i * 0.4) * scale / 1.3), mix(SCOPE, SHIPC, 0.6 - i * 0.08), true)
        end
        for i = 0, 7 do
          local f0, f1 = 12 * scale / 1.3 + k * i / 8, 12 * scale / 1.3 + k * (i + 0.5) / 8
          local x0, y0 = pt(f0, 0)
          local x1, y1 = pt(f1, 0)
          line(x0, y0, x1, y1, SHIPC)
        end
      end
      if isSable then
        -- Sable ship: pointed hull, filled with a fan of lines
        local nx, ny = pt(11 * scale, 0)
        local stern = { { -7, -6 }, { -9, -3 }, { -9, 3 }, { -7, 6 } }
        for i = 1, #stern - 1 do
          local ax, ay = stern[i][1] * scale, stern[i][2] * scale
          local bx2, by2 = stern[i + 1][1] * scale, stern[i + 1][2] * scale
          for s2 = 0, 8 do
            local fx = ax + (bx2 - ax) * s2 / 8
            local fy = ay + (by2 - ay) * s2 / 8
            local px, py = pt(fx, fy)
            line(nx, ny, px, py, SHIPDARK)
          end
        end
        local prevx, prevy = nx, ny
        for _, sp in ipairs(stern) do
          local px, py = pt(sp[1] * scale, sp[2] * scale)
          line(prevx, prevy, px, py, SHIPC)
          prevx, prevy = px, py
        end
        line(prevx, prevy, nx, ny, SHIPC)
      else
        -- Create contraption: a square frame with a cross, like a crate, turned with its heading
        local hs = 7 * scale
        for i = -hs, hs, math.max(0.5, hs / 8) do
          local x0, y0 = pt(-hs, i)
          local x1, y1 = pt(hs, i)
          line(x0, y0, x1, y1, SHIPDARK)
        end
        local c1x, c1y = pt(-hs, -hs)
        local c2x, c2y = pt(hs, -hs)
        local c3x, c3y = pt(hs, hs)
        local c4x, c4y = pt(-hs, hs)
        line(c1x, c1y, c2x, c2y, SHIPC) line(c2x, c2y, c3x, c3y, SHIPC)
        line(c3x, c3y, c4x, c4y, SHIPC) line(c4x, c4y, c1x, c1y, SHIPC)
        line(c1x, c1y, c3x, c3y, SHIPC) line(c2x, c2y, c4x, c4y, SHIPC)
        if moving then
          local fx, fy = pt(hs + 4, 0)
          circle(fx, fy, 2, SHIPC, true)
        end
      end
      local key = "track:" .. t.id
      table.insert(radarHits, { x = bx, y = by, key = key })
      if key == selected then circle(bx, by, math.max(8, 16 * iconScale), WHITE, false) end
    end
  end

  -- Blips: allowed players green, intruders red with a pulse ring
  for _, e in ipairs(nearbyList()) do
    if e.dist then
      local a = blipAngle(e)
      local outside = e.dist > zoom
      local d = math.min(1, e.dist / zoom) * (r - 6)
      local bx, by = cx + math.cos(a) * d, cy + math.sin(a) * d
      if e.name == selected then circle(bx, by, 9, WHITE, false) end
      table.insert(radarHits, { x = bx, y = by, key = e.name })
      if outside then
        circle(bx, by, 4, e.allowed and GREEN or RED, false)
      elseif e.allowed then
        circle(bx, by, 3, GREEN, true)
      else
        local pulse = 5 + (now() * 8) % 8
        circle(bx, by, pulse, DARKRED, false)
        circle(bx, by, 4, RED, true)
      end
      -- Allowed players label to the left, intruders to the right, so close blips don't overlap.
      local label = e.name
      local lw = textWidth(label, small * 0.9)
      local lx = e.allowed and (bx - 7 - lw) or (bx + 7)
      if lx + lw > cx + r then lx = bx - 7 - lw end
      if lx < cx - r then lx = bx + 7 end
      local ly = freeY(lx, by - small * 0.5, lw, small)
      text(label, lx, ly, e.allowed and GREEN or RED, small * 0.9, e.allowed and "plain" or "bold")
    end
  end
  circle(cx, cy, 3, WHITE, true)
end

local function frame(x, y, w, h, c)
  rect(x, y, w, 1, c)
  rect(x, y + h - 1, w, 1, c)
  rect(x, y, 1, h, c)
  rect(x + w - 1, y, 1, h, c)
end

-- Corner brackets, like a targeting box.
local function brackets(x, y, w, h, c, len)
  len = len or 8
  rect(x, y, len, 2, c) rect(x, y, 2, len, c)
  rect(x + w - len, y, len, 2, c) rect(x + w - 2, y, 2, len, c)
  rect(x, y + h - 2, len, 2, c) rect(x, y + h - len, 2, len, c)
  rect(x + w - len, y + h - 2, len, 2, c) rect(x + w - 2, y + h - len, 2, len, c)
end

-- Buttons are outlined; "on" buttons (ON, AMBER, RED) and hovered ones are
-- filled solid with dark text, like an inverted terminal cell.
local ON = { 90, 255, 120 }
local function pill(x, y, w, h, label, bg, fg, size, action)
  local solid = bg == ON or bg == AMBER or bg == RED
  if solid then
    rect(x, y, w, h, bg)
    fg = BG
  elseif action and hovered(x, y, w, h) then
    rect(x, y, w, h, MUTED)
    fg = BG
  else
    frame(x, y, w, h, action and MUTED or LINE)
    if not action then fg = MUTED end
  end
  local lw = textWidth(label, size, "bold")
  text(label, x + (w - lw) / 2, y + (h - size) / 2 - 1, fg, size, "bold")
  if action then gpuButton(x, y, w, h, action) end
end

local ZOOMS = { 16, 32, 64, 128, 256, 512, 1024, 2048 }
local function zoomStep(dir)
  local levels = {}
  local maxRange = math.max(RANGE, radarRange)
  for _, z in ipairs(ZOOMS) do if z < maxRange then table.insert(levels, z) end end
  table.insert(levels, maxRange)
  local idx = #levels
  for i, z in ipairs(levels) do if z == zoom then idx = i end end
  zoom = levels[math.max(1, math.min(#levels, idx + dir))]
end

local function detailLines(e)
  local v = active[e.name]
  local st = stats[e.name:lower()]
  local lines = {}
  table.insert(lines, (e.dist and (meters(e.dist) .. " away") or "distance unknown") .. (e.dx and (", " .. compass(e.dx, e.dz)) or ""))
  if e.dx and detectorPos then
    table.insert(lines, "at " .. math.floor(detectorPos.x + e.dx) .. ", " .. math.floor(detectorPos.y + e.dy) .. ", " .. math.floor(detectorPos.z + e.dz))
  end
  if v then
    table.insert(lines, "here " .. fmtDuration(now() - v.first) .. ", closest " .. meters(v.closest))
  end
  if st then table.insert(lines, st.visits .. " past visits, " .. fmtDuration(st.seconds) .. " total") end
  if e.allowed then table.insert(lines, "on the allowed list") end
  return lines
end

local function trackDetails(t)
  local lines = {}
  local title, color
  if isShip(t.category) then
    local kind, c = vesselKind(t)
    title, color = kind .. " " .. (t.number or "?"), c
    local what = t.category == "SABLE" and "Sable ship" or "Create contraption"
    local typeName = prettyType(t.entityType)
    if typeName ~= "Ship" and typeName ~= "Unknown" then what = what .. " (" .. typeName .. ")" end
    table.insert(lines, what)
  elseif t.category == "PLAYER" then
    title, color = "Unknown player", AMBER
    table.insert(lines, "beyond the detector, name unknown")
  else
    title = prettyType(t.entityType)
    color = (t.category == "HOSTILE" and { 245, 120, 50 }) or (t.category == "PROJECTILE" and { 250, 220, 70 }) or MUTED
    table.insert(lines, prettyType(t.category):lower())
  end
  if t.dist then
    table.insert(lines, meters(t.dist) .. " away, " .. compass(t.dx, t.dz))
    local c = baseCenter()
    if c then
      table.insert(lines, "at " .. math.floor(c.x + t.dx) .. ", " .. math.floor(c.y + t.dy) .. ", " .. math.floor(c.z + t.dz))
    end
  end
  if isShip(t.category) then
    if t.speed and t.speed >= 0.3 then
      table.insert(lines, "moving " .. shipSpeedText(t) .. " toward " .. compass(t.vx, t.vz))
    else
      table.insert(lines, "parked")
    end
  end
  return title, color, lines
end

local function drawDetails(e, x, bottom, w, small, medium)
  local lines, title, color
  if e.track then
    title, color, lines = trackDetails(e.track)
  else
    lines, title, color = detailLines(e), e.name, e.allowed and GREEN or RED
  end
  local rowH = small + 5
  local h = medium + 12 + #lines * rowH + 4
  local y = bottom - h
  rect(x, y, w, h, BG)
  frame(x, y, w, h, LINE)
  brackets(x, y, w, h, color, 10)
  text(fit(title:upper(), w - 44, medium, "bold"), x + 12, y + 6, color, medium, "bold")
  pill(x + w - 30, y + 5, 24, medium + 2, "X", nil, WHITE, small, function() selected = nil end)
  for i, l in ipairs(lines) do
    text(fit(l, w - 20, small), x + 12, y + medium + 12 + (i - 1) * rowH, MUTED, small)
  end
end

-- Pages live in a block so their helpers stay out of the top-level local count.
-- ---------------------------------------------------------------- pages, scrolling, hover

local PAGES = { { "radar", "RADAR" }, { "people", "PEOPLE" }, { "log", "LOG" }, { "stats", "STATS" } }
local expanded = {}          -- [row key] = true while a row is opened up
local logFilter = "all"      -- "all", "today" or "week"

local function dayStart(t)
  local local_ = t + UTC_OFFSET * 3600
  return math.floor(local_ / 86400) * 86400 - UTC_OFFSET * 3600
end

local function dayLabel(t)
  local today = dayStart(now())
  local d = dayStart(t)
  if d == today then return "Today" end
  if d == today - 86400 then return "Yesterday" end
  return os.date("!%a %m/%d", math.floor(t + UTC_OFFSET * 3600))
end

local function timeOfDay(t)
  return os.date("!%H:%M", math.floor(t + UTC_OFFSET * 3600))
end

-- Draws a list of { h, draw(y), onTap, key } items inside [top, bottom],
-- scrolled by scroll[name], with a scrollbar. Items that don't fully fit
-- in view are skipped, which keeps everything inside the area.
local function scrollList(name, x, top, w, bottom, items)
  local total = 0
  for _, it in ipairs(items) do total = total + it.h end
  local viewH = bottom - top
  local maxScroll = math.max(0, total - viewH)
  scroll[name] = math.max(0, math.min(scroll[name] or 0, maxScroll))
  local y = top - scroll[name]
  for _, it in ipairs(items) do
    if y >= top - 0.5 and y + it.h <= bottom + 0.5 then
      if it.onTap and hovered(x, y, w, it.h) then rect(x, y, w, it.h, HOVER) end
      it.draw(y)
      if it.onTap then gpuButton(x, y, w, it.h, it.onTap) end
    end
    y = y + it.h
  end
  if maxScroll > 0 then
    local trackX = x + w + 3
    rect(trackX + 1, top, 2, viewH, LINE)
    local thumbH = math.max(24, viewH * viewH / total)
    local thumbY = top + (viewH - thumbH) * scroll[name] / maxScroll
    rect(trackX, thumbY, 4, thumbH, MUTED)
    -- small arrow when there's more above
    if scroll[name] > 0 then
      for i = 0, 3 do rect(trackX + 2 - i, top - 6 + i, 1 + i * 2, 1, MUTED) end
    end
  end
  return maxScroll
end

-- ---------------------------------------------------------------- radar page

local function drawRadarPage(top, bottom, pad, small, medium)
  local y = top
  local tbH = small + pad
  local gap = pad * 0.6
  local bw = math.floor((W - pad * 2 - gap * 4) / 5)
  local x = pad
  local BTN = nil
  pill(x, y, bw, tbH, "-", BTN, WHITE, medium, function() zoomStep(-1) end)
  x = x + bw + gap
  pill(x, y, bw, tbH, "+", BTN, WHITE, medium, function() zoomStep(1) end)
  x = x + bw + gap
  local m = currentMode()
  pill(x, y, bw, tbH, m:upper(), nil, #radars > 0 and WHITE or MUTED, small * 0.85, function()
    if #radars == 0 then
      event("Add a Create Radar for THREATS and ALL modes", "info")
      return
    end
    local idx = 1
    for i, v in ipairs(MODES) do if v == m then idx = i end end
    mode = MODES[idx % #MODES + 1]
    writeFile(DIR .. "/mode", mode)
  end)
  x = x + bw + gap
  if muted() then
    local left = math.ceil(muteUntil - now())
    pill(x, y, bw, tbH, string.format("%d:%02d", math.floor(left / 60), left % 60), AMBER, BG, small, function()
      if unlocked() then muteUntil = 0 event("Alarm unmuted", "info") end
    end)
  else
    local open = unlocked()
    pill(x, y, bw, tbH, "MUTE", nil, open and AMBER or MUTED, small, function()
      if unlocked() then
        muteUntil = now() + MUTE_MINUTES * 60
        event("Alarm muted by " .. tostring(unlockedBy), "info")
      else
        event("Right-click the detector to unlock MUTE", "info")
      end
    end)
  end
  x = x + bw + gap
  pill(x, y, bw, tbH, updateNow.busy and "..." or "UPDATE", nil, WHITE, small * 0.85, function()
    if updateNow.busy or updateNow.want then return end
    updateNow.want = true
    event("Checking for updates...", "info")
  end)
  y = y + tbH + pad

  -- summary line under the radar
  local list = nearbyList()
  local parts = { #list .. (#list == 1 and " player" or " players") }
  if #radars > 0 then
    local ships, hostile, unknown, _, contraptions = radarSummary()
    if ships > 0 then table.insert(parts, ships .. (ships == 1 and " ship" or " ships")) end
    if contraptions > 0 then table.insert(parts, contraptions .. " contr.") end
    if hostile > 0 then table.insert(parts, hostile .. " hostile") end
    if unknown > 0 then table.insert(parts, unknown .. " unknown") end
  end
  table.insert(parts, "view " .. zoom .. "m")
  local summary = table.concat(parts, "  |  ")
  local sumH = small + pad

  local r = math.min((W - pad * 2) / 2, (bottom - y - sumH - pad) / 2)
  local rcx, rcy = W / 2, y + r
  drawRadar(rcx, rcy, r, small)
  gpuButton(rcx - r, rcy - r, r * 2, r * 2, function(px, py)
    local best, bestD = nil, 18
    for _, h in ipairs(radarHits) do
      local d = math.sqrt((h.x - px) ^ 2 + (h.y - py) ^ 2)
      if d < bestD then best, bestD = h.key, d end
    end
    selected = (best and best ~= selected) and best or nil
  end)
  if selected then
    local e
    if selected:sub(1, 6) == "track:" then
      local id = selected:sub(7)
      for _, t in ipairs(tracks) do if t.id == id then e = { track = t } end end
    else
      e = present[selected]
    end
    if e then drawDetails(e, pad * 2, y + r * 2, W - pad * 4, small, medium) else selected = nil end
  end
  y = y + r * 2 + pad / 2

  local sw = textWidth(summary, small)
  local sx = (W - sw) / 2
  if hovered(pad, y, W - pad * 2, sumH) then rect(pad, y, W - pad * 2, sumH, HOVER) end
  text(fit(summary, W - pad * 2, small), math.max(pad, sx), y + (sumH - small) / 2 - 1, MUTED, small)
  gpuButton(pad, y, W - pad * 2, sumH, function() page = "people" end)
end

-- ---------------------------------------------------------------- people page

-- "-- ALLOWED (2) ---------------------" style headers
local function sectionItem(label, color, small, pad)
  return { h = small + pad + 4, draw = function(y)
    local ty = y + pad / 2 + 2
    rect(pad, ty + small / 2, 10, 1, LINE)
    text(label, pad + 16, ty, color, small, "bold")
    local lx = pad + 22 + textWidth(label, small, "bold")
    rect(lx, ty + small / 2, W - pad - 8 - lx, 1, LINE)
  end }
end

local function personRowItems(items, key, title, right, color, details, pad, small, medium)
  local open = expanded[key]
  local rowH = medium + 14
  local lineH = small + 5
  local h = rowH + (open and (#details * lineH + small + pad + 8) or 0)
  table.insert(items, { h = h + 4, key = key, onTap = function()
    expanded[key] = not expanded[key] or nil
  end, draw = function(y)
    rect(pad, y + 3, 3, h - 6, color)
    text(fit(title, W * 0.48, medium, "bold"), pad * 1.8, y + 7, WHITE, medium, "bold")
    if open then frame(pad, y, W - pad * 2 - 8, h, LINE) end
    textRight(fit(right, W * 0.42, small, "bold"), W - pad * 2 - 8, y + 9, color, small, "bold")
    if open then
      local yy = y + rowH
      for _, l in ipairs(details) do
        text(fit(l, W - pad * 5, small), pad * 1.8, yy, MUTED, small)
        yy = yy + lineH
      end
      -- jump to it on the radar
      local bw = textWidth("SHOW ON RADAR", small * 0.85, "bold") + pad * 2
      pill(pad * 1.8, yy + 4, bw, small + 8, "SHOW ON RADAR", nil, WHITE, small * 0.85, function()
        selected = key
        page = "radar"
      end)
    end
  end })
end

local function drawPeoplePage(top, bottom, pad, small, medium)
  local items = {}
  local intruders, friends = {}, {}
  for _, e in ipairs(nearbyList()) do
    if e.allowed then table.insert(friends, e) else table.insert(intruders, e) end
  end
  local function playerRow(e)
    local info = meters(e.dist) .. (e.dx and (" " .. compass(e.dx, e.dz)) or "")
    local v = active[e.name]
    if v then info = info .. "  " .. fmtDuration(now() - v.first) end
    personRowItems(items, e.name, e.name, info, e.allowed and GREEN or RED, detailLines(e), pad, small, medium)
  end
  if #intruders > 0 then
    table.insert(items, sectionItem("INTRUDERS (" .. #intruders .. ")", RED, small, pad))
    for _, e in ipairs(intruders) do playerRow(e) end
  end
  table.insert(items, sectionItem("ALLOWED (" .. #friends .. ")", GREEN, small, pad))
  if #friends == 0 then
    table.insert(items, { h = small + pad, draw = function(y) text("nobody from the allowed list nearby", pad * 1.8, y + 4, MUTED, small) end })
  end
  for _, e in ipairs(friends) do playerRow(e) end

  local vessels = shipList()
  if #radars > 0 then
    table.insert(items, sectionItem("VESSELS (" .. #vessels .. ")", SHIP_COLOR, small, pad))
    if #vessels == 0 then
      table.insert(items, { h = small + pad, draw = function(y) text("no ships or contraptions on the radar", pad * 1.8, y + 4, MUTED, small) end })
    end
    for _, t in ipairs(vessels) do
      local kind, c = vesselKind(t)
      local title, _, lines = trackDetails(t)
      personRowItems(items, "track:" .. t.id, title, meters(t.dist) .. " " .. compass(t.dx, t.dz) .. "  " .. shipSpeedText(t), c, lines, pad, small, medium)
    end
    local unknown = {}
    for _, t in ipairs(tracks) do
      if t.category == "PLAYER" and not t.name and t.dist then table.insert(unknown, t) end
    end
    if #unknown > 0 then
      table.insert(items, sectionItem("UNKNOWN PLAYERS (" .. #unknown .. ")", AMBER, small, pad))
      for i, t in ipairs(unknown) do
        local _, _, lines = trackDetails(t)
        personRowItems(items, "track:" .. t.id, "Unknown player " .. i, meters(t.dist) .. " " .. compass(t.dx, t.dz), AMBER, lines, pad, small, medium)
      end
    end
  end
  scrollList("people", pad, top, W - pad * 2 - 8, bottom, items)
end

-- ---------------------------------------------------------------- log page

local function drawLogPageNew(top, bottom, pad, small, medium)
  -- filter chips
  local chips = { { "all", "ALL" }, { "today", "TODAY" }, { "week", "7 DAYS" }, { "enemy", "ENEMY" } }
  local x = pad
  local chipH = small + 10
  for _, c in ipairs(chips) do
    local on = logFilter == c[1]
    local cw = textWidth(c[2], small * 0.9, "bold") + pad * 2
    pill(x, top, cw, chipH, c[2], on and ON or nil, on and WHITE or MUTED, small * 0.9, function()
      logFilter = c[1]
      scroll.log = 0
    end)
    x = x + cw + pad / 2
  end
  textRight(logFilter == "enemy" and (#enemy.log .. " entries") or (#visits .. " visits"), W - pad, top + (chipH - small) / 2, MUTED, small)
  local listTop = top + chipH + pad / 2

  local cutoff = 0
  if logFilter == "today" then cutoff = dayStart(now())
  elseif logFilter == "week" then cutoff = dayStart(now()) - 6 * 86400 end

  local items = {}
  local lastDay = nil
  if logFilter == "enemy" then
    for i = #enemy.log, 1, -1 do
      local e = enemy.log[i]
      local d = dayLabel(e.t)
      if d ~= lastDay then
        table.insert(items, sectionItem(d:upper(), MUTED, small, pad))
        lastDay = d
      end
      table.insert(items, { h = small + 14, draw = function(y)
        if i % 2 == 0 then rect(pad, y, W - pad * 2 - 8, small + 12, PANEL) end
        text(timeOfDay(e.t), pad * 1.4, y + 6, MUTED, small)
        text(fit(e.name, W * 0.36, small, "bold"), pad * 1.4 + textWidth("00:00  ", small), y + 6, WHITE, small, "bold")
        if e.kind == "join" then
          textRight("joined", W - pad * 2 - 8, y + 6, RED, small, "bold")
        else
          textRight("left after " .. fmtDuration(e.t - (e.since or e.t)), W - pad * 2 - 8, y + 6, AMBER, small)
        end
      end })
    end
    for _, sess in pairs(enemy.sessions) do
      table.insert(items, 1, { h = small + 14, draw = function(y)
        rect(pad, y, W - pad * 2 - 8, small + 12, DARKRED)
        text(fit(sess.name .. " ONLINE NOW", W * 0.6, small, "bold"), pad * 1.4, y + 6, WHITE, small, "bold")
        textRight("for " .. fmtDuration(now() - sess.since), W - pad * 2 - 8, y + 6, AMBER, small, "bold")
      end })
    end
    if #items == 0 then
      table.insert(items, { h = medium + pad, draw = function(y) text("No enemy joins logged yet", pad * 1.4, y + 6, MUTED, medium) end })
    end
    scrollList("log", pad, listTop, W - pad * 2 - 8, bottom, items)
    return
  end
  for i = #visits, 1, -1 do
    local v = visits[i]
    if v.first >= cutoff then
      local d = dayLabel(v.first)
      if d ~= lastDay then
        table.insert(items, sectionItem(d:upper(), MUTED, small, pad))
        lastDay = d
      end
      local key = "visit:" .. i
      local open = expanded[key]
      local rowH = small + 12
      local lineH = small + 5
      local h = rowH + (open and (3 * lineH + 6) or 0)
      table.insert(items, { h = h + 2, onTap = function() expanded[key] = not expanded[key] or nil end, draw = function(y)
        if i % 2 == 0 then rect(pad, y, W - pad * 2 - 8, h, PANEL) end
        text(timeOfDay(v.first), pad * 1.4, y + 6, MUTED, small)
        text(fit(v.name, W * 0.36, small, "bold"), pad * 1.4 + textWidth("00:00  ", small), y + 6, WHITE, small, "bold")
        textRight(fmtDuration(v.last - v.first) .. "   " .. meters(v.closest), W - pad * 2 - 8, y + 6, AMBER, small)
        if open then
          local st = stats[v.name:lower()]
          local yy = y + rowH
          text("from " .. timeOfDay(v.first) .. " to " .. timeOfDay(v.last), pad * 2.4, yy, MUTED, small) yy = yy + lineH
          text("closest " .. meters(v.closest) .. " to the base", pad * 2.4, yy, MUTED, small) yy = yy + lineH
          if st then text(st.visits .. " visits from this player, " .. fmtDuration(st.seconds) .. " total", pad * 2.4, yy, MUTED, small) end
        end
      end })
    end
  end
  if #items == 0 then
    table.insert(items, { h = medium + pad, draw = function(y) text("No visits in this range", pad * 1.4, y + 6, MUTED, medium) end })
  end
  scrollList("log", pad, listTop, W - pad * 2 - 8, bottom, items)
end

-- ---------------------------------------------------------------- stats page

local function drawStatsPage(top, bottom, pad, small, medium, big)
  local items = {}
  local today = dayStart(now())
  local perDay = {}
  local hours = {}
  for h = 0, 23 do hours[h] = 0 end
  local week, todayN = 0, 0
  for _, v in ipairs(visits) do
    local d = math.floor((today - dayStart(v.first)) / 86400)
    if d >= 0 and d < 7 then
      perDay[d] = (perDay[d] or 0) + 1
      week = week + 1
    end
    if d == 0 then todayN = todayN + 1 end
    local hr = tonumber(os.date("!%H", math.floor(v.first + UTC_OFFSET * 3600)))
    if hr then hours[hr] = hours[hr] + 1 end
  end

  -- KPI cards
  local cardH = small + big + 18
  table.insert(items, { h = cardH + pad, draw = function(y)
    local cw = (W - pad * 2 - 8 - pad * 2) / 3
    local cards = { { "TODAY", todayN, AMBER }, { "7 DAYS", week, GREEN }, { "ALL TIME", #visits, WHITE } }
    for i, c in ipairs(cards) do
      local cx = pad + (i - 1) * (cw + pad)
      frame(cx, y, cw, cardH, LINE)
      brackets(cx, y, cw, cardH, c[3], 6)
      text(c[1], cx + 10, y + 8, MUTED, small)
      text(tostring(c[2]), cx + 10, y + 10 + small, c[3], big, "bold")
    end
  end })

  -- visits per day, last 7 days
  local chartH = 110
  table.insert(items, sectionItem("VISITS PER DAY", MUTED, small, pad))
  table.insert(items, { h = chartH + small + pad, draw = function(y)
    local maxV = 1
    for d = 0, 6 do maxV = math.max(maxV, perDay[d] or 0) end
    local cw = (W - pad * 2 - 8) / 7
    for i = 0, 6 do
      local d = 6 - i
      local n = perDay[d] or 0
      local bh = (chartH - small - 6) * n / maxV
      local bx = pad + i * cw + cw * 0.18
      rect(bx, y + chartH - small - bh, cw * 0.64, math.max(1, bh), d == 0 and AMBER or GREEN)
      if n > 0 then
        local nw = textWidth(tostring(n), small * 0.85, "bold")
        text(tostring(n), bx + cw * 0.32 - nw / 2, y + chartH - small - bh - small, WHITE, small * 0.85, "bold")
      end
      local lbl = (d == 0) and "Tdy" or os.date("!%a", math.floor(today - d * 86400 + UTC_OFFSET * 3600 + 43200)):sub(1, 3)
      local lw = textWidth(lbl, small * 0.85)
      text(lbl, bx + cw * 0.32 - lw / 2, y + chartH - small + 4, MUTED, small * 0.85)
    end
  end })

  -- top visitors
  local people = {}
  for _, st in pairs(stats) do table.insert(people, st) end
  table.sort(people, function(a, b)
    if a.visits ~= b.visits then return a.visits > b.visits end
    return (a.last or 0) > (b.last or 0)
  end)
  table.insert(items, sectionItem("TOP VISITORS", MUTED, small, pad))
  if #people == 0 then
    table.insert(items, { h = small + pad, draw = function(y) text("nobody yet", pad * 1.4, y + 4, MUTED, small) end })
  end
  local maxVisits = people[1] and people[1].visits or 1
  for i = 1, math.min(10, #people) do
    local st = people[i]
    table.insert(items, { h = small + 16, draw = function(y)
      local barW = (W - pad * 2 - 8) * 0.5 * st.visits / maxVisits
      text(fit(st.name, W * 0.3, small, "bold"), pad * 1.4, y + 4, WHITE, small, "bold")
      rect(pad + W * 0.32, y + 4, math.max(2, barW), small, RED)
      textRight(st.visits .. "x  " .. fmtDuration(st.seconds), W - pad * 2 - 8, y + 4, MUTED, small)
    end })
  end

  -- busiest hours
  table.insert(items, sectionItem("BUSIEST HOURS", MUTED, small, pad))
  table.insert(items, { h = 80 + small + pad, draw = function(y)
    local maxH = 1
    for h = 0, 23 do maxH = math.max(maxH, hours[h]) end
    local cw = (W - pad * 2 - 8) / 24
    for h = 0, 23 do
      local bh = 70 * hours[h] / maxH
      rect(pad + h * cw + 1, y + 72 - bh, cw - 2, math.max(1, bh), MUTED)
      if h % 6 == 0 then text(string.format("%02d", h), pad + h * cw, y + 76, MUTED, small * 0.85) end
    end
  end })

  scrollList("stats", pad, top, W - pad * 2 - 8, bottom, items)
end

-- ---------------------------------------------------------------- the frame

function drawGpu()
  gpuButtons = {}
  local pad = math.max(8, math.floor(W * 0.03))
  local small = math.max(10, math.floor(W * 0.03))
  local medium = math.max(12, math.floor(W * 0.04))
  local big = math.max(16, math.floor(W * 0.06))
  local intruders = intruderCount()

  gpu.clear(display, BG[1], BG[2], BG[3])

  -- Header
  local headH = big + pad * 2
  text(TITLE:upper(), pad, pad - 1, WHITE, big, "bold")
  textRight(os.date("!%H:%M:%S", math.floor(now() + UTC_OFFSET * 3600)), W - pad, pad - 1, GREEN, medium, "bold")
  textRight("DET " .. RANGE .. "M  RDR " .. (#radars > 0 and "ON" or "--"), W - pad, pad + medium + 1, MUTED, small * 0.85)
  rect(pad, headH - 4, W - pad * 2, 1, LINE)

  -- Navigation tabs
  local navY, navH = headH, medium + pad
  local tw = (W - pad * 2) / #PAGES
  for i, p in ipairs(PAGES) do
    local tx = pad + (i - 1) * tw
    local on = page == p[1]
    local label = p[2]
    if p[1] == "people" and intruders > 0 then label = label .. "(" .. intruders .. ")" end
    if on then
      rect(tx + 2, navY + 3, tw - 4, navH - 6, GREEN)
    elseif hovered(tx, navY, tw, navH) then
      rect(tx + 2, navY + 3, tw - 4, navH - 6, HOVER)
    end
    local lw = textWidth(label, small, "bold")
    text(label, tx + (tw - lw) / 2, navY + (navH - small) / 2 - 1, on and BG or MUTED, small, "bold")
    local key = p[1]
    gpuButton(tx, navY, tw, navH, function() page = key end)
  end

  -- Status bar
  local y = navY + navH + pad / 2
  local barH = medium + pad
  local enemies = {}
  for _, name in pairs(watchedOnline) do table.insert(enemies, name) end
  table.sort(enemies)
  local statusW = #enemies > 0 and (W - pad * 2) * 0.55 or (W - pad * 2)
  if scanError then
    rect(pad, y, W - pad * 2, barH, AMBER)
    text(fit("FAULT: " .. scanError:upper(), W - pad * 4, small, "bold"), pad * 2, y + (barH - small) / 2 - 1, BG, small, "bold")
  else
    local msg, bg, fg
    if intruders > 0 then
      local blink = math.floor(now() * 2) % 2 == 0
      bg = blink and RED or DARKRED
      msg = "!! " .. (intruders == 1 and "INTRUDER" or (intruders .. " INTRUDERS")) .. (muted() and " / MUTED" or "") .. " !!"
      fg = blink and BG or RED
      rect(pad, y, statusW, barH, bg)
    else
      bg, msg, fg = nil, "STATUS: SECURE", GREEN
      frame(pad, y, statusW, barH, LINE)
      brackets(pad, y, statusW, barH, GREEN, 8)
    end
    local mw = textWidth(msg, medium, "bold")
    text(fit(msg, statusW - pad, medium, "bold"), pad + math.max(pad / 2, (statusW - mw) / 2), y + (barH - medium) / 2 - 1, fg, medium, "bold")
    if #enemies > 0 then
      local ex = pad + statusW + pad / 2
      local ew = W - pad - ex
      rect(ex, y, ew, barH, AMBER)
      text(fit("HOSTILE ONLINE: " .. table.concat(enemies, ", "):upper(), ew - pad, small, "bold"), ex + pad / 2, y + (barH - small) / 2 - 1, BG, small, "bold")
    end
  end
  y = y + barH + pad / 2

  -- Footer: latest event
  local footH = small + pad
  local fy = H - footH
  local bottom = fy - pad / 2

  if page == "people" then drawPeoplePage(y, bottom, pad, small, medium)
  elseif page == "log" then drawLogPageNew(y, bottom, pad, small, medium)
  elseif page == "stats" then drawStatsPage(y, bottom, pad, small, medium, big)
  else drawRadarPage(y, bottom, pad, small, medium) end

  rect(pad, fy, W - pad * 2, 1, LINE)
  local ev = log[1]
  local cursor = (math.floor(now() * 2) % 2 == 0) and "_" or " "
  if ev then
    text(fit("> " .. timeOfDay(ev.t) .. " " .. ev.text:upper() .. cursor, W - pad * 2, small), pad, fy + (footH - small) / 2, ev.kind == "alert" and RED or MUTED, small, ev.kind == "alert" and "bold" or "plain")
  else
    text("> READY" .. cursor, pad, fy + (footH - small) / 2, MUTED, small)
  end

  gpu.updateDisplay(display)
end
end

-- ============================================================ plain monitor fallback

local function drawPlain()
  local name = findMonitor()
  local mon = name and peripheral.wrap(name)
  if not mon then return end
  mon.setTextScale(0.5)
  local w, h = mon.getSize()
  mon.setBackgroundColour(colours.black)
  mon.clear()
  local function at(x, y, s, c, bg)
    mon.setCursorPos(x, y)
    mon.setBackgroundColour(bg or colours.black)
    mon.setTextColour(c or colours.white)
    mon.write(s)
  end
  at(1, 1, TITLE, colours.white)
  at(w - 4, 1, clockText(), colours.lightGrey)
  local intruders = intruderCount()
  local banner = scanError or ((intruders > 0) and (intruders .. " INTRUDER" .. (intruders > 1 and "S" or "")) or "SECURE")
  local bg = scanError and colours.orange or ((intruders > 0) and colours.red or colours.green)
  local wn = {}
  for _, name in pairs(watchedOnline) do table.insert(wn, name) end
  if #wn > 0 then at(1, 2, ("! " .. table.concat(wn, ", ") .. " online"):sub(1, w), colours.black, colours.orange) end
  at(1, 3, string.rep(" ", w), colours.white, bg)
  at(math.max(1, math.floor((w - #banner) / 2) + 1), 3, banner:sub(1, w), colours.white, bg)
  local y = 5
  at(1, y, "NEARBY", colours.grey)
  y = y + 1
  for _, e in ipairs(nearbyList()) do
    if y > 12 then break end
    local info = meters(e.dist) .. (e.dx and (" " .. compass(e.dx, e.dz)) or "")
    at(1, y, e.name:sub(1, w - #info - 2), e.allowed and colours.lime or colours.red)
    at(w - #info + 1, y, info, e.allowed and colours.lime or colours.red)
    y = y + 1
  end
  y = y + 1
  at(1, y, "VISIT LOG (" .. todayCount() .. " today)", colours.grey)
  y = y + 1
  for i = 0, h - y do
    local v = visits[#visits - i]
    if not v then break end
    local right = fmtDuration(v.last - v.first) .. " " .. meters(v.closest)
    at(1, y, (fmtWhen(v.first) .. " " .. v.name):sub(1, w - #right - 1), colours.white)
    at(w - #right + 1, y, right, colours.orange)
    y = y + 1
  end
end

-- ============================================================ computer screen

local TW, TH = term.getSize()
local buttons = {}
local message, messageAt = nil, 0
local tab = "status"
local confirmClear = 0

local function say(text)
  message, messageAt = text, now()
end

local function put(x, y, s, fg, bg)
  term.setCursorPos(x, y)
  term.setBackgroundColor(bg or colors.black)
  term.setTextColor(fg or colors.white)
  term.write(s)
end
local function button(x, y, label, bg, action, fg)
  label = " " .. label .. " "
  put(x, y, label, fg or colors.white, bg)
  table.insert(buttons, { x = x, y = y, w = #label, action = action })
  return x + #label + 1
end
local function dot(x, y, ok, label, value)
  put(x, y, "\7", ok and colors.lime or colors.red)
  put(x + 2, y, label, colors.lightGray)
  put(x + 2 + #label + 1, y, value, ok and colors.white or colors.red)
end

local function calibrate()
  local ok, names = dcall("getPlayersInRange", 2)
  if not ok or type(names) ~= "table" or #names ~= 1 then
    say("Stand on the detector alone, then press Calibrate")
    return
  end
  local info = playerInfo(names[1])
  if not info then
    say("Couldn't read your position (getPlayer disabled?)")
    return
  end
  detectorPos = { x = math.floor(info.x) + 0.5, y = math.floor(info.y) - 0.5, z = math.floor(info.z) + 0.5 }
  writeFile(DIR .. "/detector", detectorPos)
  say("Calibrated: detector at " .. math.floor(detectorPos.x) .. ", " .. math.floor(detectorPos.y) .. ", " .. math.floor(detectorPos.z))
end

local function allowName(name)
  allowed[name:lower()] = name
  saveAllowed()
  event(name .. " added to the allowed list", "info")
  say(name .. " is now allowed")
end

local function drawStatusTab(y)
  dot(2, y, detector ~= nil, "Detector", detector and ("range " .. RANGE .. "m") or "missing")
  dot(27, y, chat ~= nil, "Chat Box", chat and "ok" or "none")
  y = y + 1
  dot(2, y, useGpu, "Monitor", useGpu and "DirectGPU" or "plain")
  dot(27, y, speaker ~= nil, "Speaker", speaker and "ok" or "none")
  y = y + 1
  dot(2, y, DISCORD_WEBHOOK ~= nil and discordError == nil, "Discord", DISCORD_WEBHOOK and (discordError and "error" or "on") or "off")
  dot(27, y, botEnabled() and botState.status == nil, "Bot", botEnabled() and (botState.status and "error" or (DISCORD_PREFIX .. "commands on")) or "off")
  y = y + 1
  dot(2, y, detectorPos ~= nil, "Direction", detectorPos and "calibrated" or "not calibrated")
  if #radars > 0 then
    local ships, hostile, unknown = radarSummary()
    dot(27, y, baseCenter() ~= nil, "Radar", currentMode())
    y = y + 1
    local _, _, _, _, contraptions = radarSummary()
    put(4, y, ("Radar x" .. #radars .. ": " .. ships .. " ship " .. contraptions .. " contr " .. hostile .. " hostile " .. unknown .. " unknown"):sub(1, TW - 4), colors.lightBlue)
  else
    dot(27, y, false, "Radar", "none")
  end
  y = y + 1
  if scanError then
    put(2, y, scanError:sub(1, TW - 2), colors.red)
    y = y + 1
  end
  if gpuError then
    local msg = "GPU: " .. gpuError
    put(2, y, msg:sub(1, TW - 2), colors.orange)
    y = y + 1
    if #msg > TW - 2 then
      put(2, y, msg:sub(TW - 1, 2 * (TW - 2)), colors.orange)
      y = y + 1
    end
  end
  if DISCORD_WEBHOOK and discordError then
    put(2, y, ("Discord: " .. discordError):sub(1, TW - 2), colors.orange)
    y = y + 1
  end
  if botEnabled() and botState.status then
    put(2, y, ("Bot: " .. botState.status):sub(1, TW - 2), colors.orange)
    y = y + 1
  end

  y = y + 1
  put(2, y, "Nearby", colors.yellow)
  y = y + 1
  local list = nearbyList()
  if #list == 0 then put(4, y, "nobody in range", colors.gray) end
  local shown = 0
  for _, e in ipairs(list) do
    if y > TH - 2 then
      put(4, y - 1, "+" .. (#list - shown) .. " more", colors.gray)
      break
    end
    put(2, y, e.allowed and "\7" or "!", e.allowed and colors.lime or colors.red)
    put(4, y, e.name:sub(1, 17), e.allowed and colors.lime or colors.red)
    local info = meters(e.dist) .. (e.dx and (" " .. compass(e.dx, e.dz)) or "")
    put(22, y, info, colors.white)
    local v = active[e.name]
    if v then put(31, y, fmtDuration(now() - v.first), colors.gray) end
    if not e.allowed then
      local name = e.name
      button(TW - 8, y, "Allow", colors.green, function() allowName(name) end)
    end
    shown = shown + 1
    y = y + 1
  end
end

local function drawPeopleTab(y)
  put(2, y, "Allowed (never trigger the alarm)", colors.yellow)
  y = y + 1
  local names = {}
  for _, n in pairs(allowed) do table.insert(names, n) end
  table.sort(names, function(a, b) return a:lower() < b:lower() end)
  local fromConfig = {}
  for _, n in ipairs(ALLOWED) do fromConfig[n:lower()] = true end
  local col, row = 0, 0
  for _, n in ipairs(names) do
    local x = 2 + col * 25
    if y + row > TH - 6 then break end
    put(x, y + row, n:sub(1, 16), colors.lime)
    if fromConfig[n:lower()] then
      put(x + 18, y + row, "file", colors.gray)
    else
      button(x + 18, y + row, "x", colors.red, function()
        allowed[n:lower()] = nil
        saveAllowed()
        say(n .. " removed")
      end)
    end
    col = col + 1
    if col == 2 then col, row = 0, row + 1 end
  end
  y = y + row + (col > 0 and 1 or 0) + 1
  button(2, y, "Add name", colors.blue, function()
    put(1, TH, string.rep(" ", TW), colors.white, colors.blue)
    put(1, TH, "Name to allow: ", colors.white, colors.blue)
    local name = read()
    if name and name:match("^[%w_]+$") then allowName(name) elseif name ~= "" then say("Names are letters, numbers and _") end
  end)
  y = y + 2
  put(2, y, "Enemies (WATCH_JOINS)", colors.yellow)
  y = y + 1
  local enemies = {}
  for _, n in ipairs(WATCH_JOINS) do
    local sess = enemy.sessions[n:lower()]
    table.insert(enemies, n .. (sess and (" (ONLINE since " .. os.date("!%H:%M", math.floor(sess.since + UTC_OFFSET * 3600)) .. ")") or ""))
  end
  put(2, y, (#enemies > 0 and table.concat(enemies, ", ") or "none"):sub(1, TW - 2), #enemies > 0 and colors.red or colors.gray)
end

local function drawToolsTab(y)
  button(2, y, "Calibrate", colors.blue, calibrate)
  put(15, y, "stand on the detector alone first", colors.gray)
  y = y + 2
  if muted() then
    button(2, y, "Unmute", colors.orange, function() muteUntil = 0 say("Alarm unmuted") end)
    put(15, y, "muted for " .. fmtDuration(muteUntil - now()), colors.orange)
  else
    button(2, y, "Mute " .. MUTE_MINUTES .. "m", colors.gray, function()
      muteUntil = now() + MUTE_MINUTES * 60
      say("Siren and speaker muted for " .. MUTE_MINUTES .. " minutes")
    end)
    put(15, y, "silence the siren and speaker", colors.gray)
  end
  y = y + 2
  button(2, y, "Test enemy msg", colors.purple, function() say(testEnemyMessage()) end)
  put(20, y, "chat, allowed list only", colors.gray)
  y = y + 2
  button(2, y, "Test alert", colors.purple, function()
    if not chat then say("No Chat Box found") return end
    warnAllowed("This is a test of the intruder alert", "Test alert")
    say("Test toast sent to the allowed list")
  end)
  put(20, y, "toast, allowed list only", colors.gray)
  y = y + 2
  button(2, y, "Test Discord", colors.purple, function()
    if not DISCORD_WEBHOOK then say("Set DISCORD_WEBHOOK at the top of the file first") return end
    discord("Test", "Base security is connected to this channel.", GREEN_C)
    say("Test sent to Discord")
  end)
  put(20, y, "post a test to the webhook", colors.gray)
  y = y + 2
  local armed = now() - confirmClear < 5
  button(2, y, armed and "Really clear?" or "Clear log", colors.red, function()
    if now() - confirmClear < 5 then
      visits, stats = {}, {}
      saveVisits()
      saveStats()
      confirmClear = 0
      say("Visit log cleared")
    else
      confirmClear = now()
    end
  end)
  put(20, y, #visits .. " visits logged", colors.gray)
end

local function drawTerminal(useGpu)
  buttons = {}
  term.setBackgroundColor(colors.black)
  term.clear()

  local n = intruderCount()
  local badge, badgeBg
  if n > 0 then
    badge, badgeBg = " " .. n .. " INTRUDER" .. (n > 1 and "S" or "") .. (muted() and " (muted)" or "") .. " ", colors.red
  else
    badge, badgeBg = " SECURE ", colors.green
  end
  put(1, 1, string.rep(" ", TW), colors.white, colors.gray)
  put(2, 1, TITLE, colors.white, colors.gray)
  put(TW - #badge + 1, 1, badge, colors.white, badgeBg)

  local enemies = {}
  for _, name in pairs(watchedOnline) do table.insert(enemies, name) end
  local y = 2
  if #enemies > 0 then
    table.sort(enemies)
    put(1, y, string.rep(" ", TW), colors.black, colors.orange)
    put(2, y, ("ENEMY ONLINE: " .. table.concat(enemies, ", ")):sub(1, TW - 2), colors.black, colors.orange)
  end
  y = 3

  local x = 2
  for _, t in ipairs({ { "status", "Status" }, { "people", "People" }, { "tools", "Tools" } }) do
    local on = tab == t[1]
    x = button(x, y, t[2], on and colors.lightBlue or colors.gray, function() tab = t[1] end, on and colors.black or colors.white)
  end
  y = y + 2

  if tab == "status" then drawStatusTab(y)
  elseif tab == "people" then drawPeopleTab(y)
  else drawToolsTab(y) end

  if message and now() - messageAt < 8 then
    put(1, TH, string.rep(" ", TW), colors.white, colors.black)
    put(2, TH, message:sub(1, TW - 2), colors.orange)
  end
end

local useGpu = false

local function displayLoop()
  local ok, err = pcall(setupGpu)
  useGpu = ok and err == true
  if not useGpu then gpuError = ok and (gpuError or "no DirectGPU block or monitor found") or tostring(err) end
  local retryAt = now() + 10
  local failures = 0
  while true do
    if page ~= "radar" and now() - lastInput > 60 then page = "radar" end
    if useGpu then
      local okD, errD = pcall(drawGpu)
      if okD then
        failures = 0
        gpuError = nil
      else
        failures = failures + 1
        gpuError = tostring(errD)
        -- one bad frame isn't a reason to give up on the color screen
        if failures >= 3 then useGpu = false retryAt = now() + 10 end
      end
    end
    if not useGpu then
      pcall(drawPlain)
      if now() >= retryAt then
        local okS, res = pcall(setupGpu)
        useGpu = okS and res == true
        if not useGpu then gpuError = okS and (gpuError or "no DirectGPU block or monitor found") or tostring(res) end
        retryAt = now() + 10
      end
    end
    sleep(0.3)
  end
end

local function terminalLoop()
  local timer = os.startTimer(0.5)
  while true do
    drawTerminal(useGpu)
    local ev, a, b, c = os.pullEvent()
    if ev == "mouse_click" then
      for _, btn in ipairs(buttons) do
        if c == btn.y and b >= btn.x and b < btn.x + btn.w then
          btn.action()
          break
        end
      end
    elseif ev == "timer" and a == timer then
      timer = os.startTimer(0.5)
    end
  end
end

local lastTap = 0

local function tap(px, py)
  -- One click can arrive as both a monitor_touch and a DirectGPU click.
  if now() - lastTap < 0.3 then return end
  lastTap = now()
  for i = #gpuButtons, 1, -1 do
    local b = gpuButtons[i]
    if px >= b.x and px <= b.x + b.w and py >= b.y and py <= b.y + b.h then
      b.action(px, py)
      return
    end
  end
end

local pendingTap = nil   -- { x, y, t } waiting to see if it turns into a drag
local drag = nil         -- { y, scroll, page } while dragging a list

local function scrollBy(dy)
  if scroll[page] then scroll[page] = scroll[page] + dy end
end

local function handleGpuEvent(e)
  if type(e) ~= "table" then return end
  if e.type == "mouse_hover" then
    hover.x, hover.y, hover.at = e.x, e.y, now()
    return
  end
  lastInput = now()
  hover.x, hover.y, hover.at = e.x, e.y, now()
  if e.type == "mouse_click" then
    pendingTap = { x = e.x, y = e.y, t = now() }
    drag = { y = e.y, scroll = scroll[page] or 0, page = page, t = now() }
  elseif e.type == "mouse_drag" then
    if drag and drag.page == page and scroll[page] then
      local dy = e.y - drag.y
      if math.abs(dy) > 6 then pendingTap = nil end
      scroll[page] = drag.scroll - dy
    end
  elseif e.type == "mouse_scroll" then
    local delta = tonumber(e.button) or 0
    scrollBy(-delta * 48)
  end
end

local function touchLoop()
  while true do
    local timer = os.startTimer(0.05)
    local ev = { os.pullEvent() }
    if ev[1] == "monitor_touch" and useGpu and W then
      local ok, mw, mh = pcall(peripheral.call, ev[2], "getSize")
      if ok and mw then
        lastInput = now()
        tap((ev[3] - 0.5) / mw * W, (ev[4] - 0.5) / mh * H)
      end
    end
    if useGpu and gpu and display then
      local ok, has = pcall(gpu.hasEvents, display)
      local guard = 0
      while ok and has and guard < 200 do
        guard = guard + 1
        handleGpuEvent(gpu.pollEvent(display))
        ok, has = pcall(gpu.hasEvents, display)
      end
    end
    -- a press that didn't turn into a drag is a tap
    if pendingTap and now() - pendingTap.t > 0.2 then
      local t = pendingTap
      pendingTap = nil
      tap(t.x, t.y)
    end
    if drag and now() - drag.t > 3 then drag = nil end
    if ev[1] ~= "timer" or ev[2] ~= timer then os.cancelTimer(timer) end
  end
end

local function readyToUpdate()
  return true
end

-- ============================================================ auto-update
-- In a block so its helpers stay out of the top-level local count.
local updateLoop, bootUpdate
do

-- Every UPDATE_CHECK_MINUTES this checks GitHub for a newer version. A new
-- version is downloaded, checked that it loads, given your current settings
-- (the UPPERCASE lines at the top of this file), saved, and the computer
-- reboots into it. Set AUTO_UPDATE = false at the top to turn this off.
local UPDATE_REPO = "levisnakes/cc-player-alarm"
local UPDATE_FILE = "player_alarm.lua"
local UPDATE_CHECK_MINUTES = 15
local PROGRAM_PATH = (shell and shell.getRunningProgram()) or "startup.lua"
local SHA_FILE = "/.version_" .. UPDATE_FILE

-- Settings are the top-of-file assignments to UPPERCASE names, before the
-- first "local" line or "-- ====" section. Tables can span several lines.
local function splitSettings(src)
  local settings, rest = {}, {}
  local inSettings = true
  for line in (src .. "\n"):gmatch("(.-)\n") do
    if inSettings and (line:match("^local ") or line:match("^%-%- ====")) then inSettings = false end
    table.insert(inSettings and settings or rest, line)
  end
  return settings, rest
end

local function braceDelta(line)
  local code = line:gsub('"[^"]*"', ""):gsub("%-%-.*$", "")
  local _, opens = code:gsub("{", "")
  local _, closes = code:gsub("}", "")
  return opens - closes
end

-- [NAME] = the full statement text, possibly several lines
local function statements(lines)
  local out = {}
  local i = 1
  while i <= #lines do
    local name = lines[i]:match("^([%u_][%u%d_]*)%s*=")
    if name then
      local block = { lines[i] }
      local depth = braceDelta(lines[i])
      while depth > 0 and i < #lines do
        i = i + 1
        table.insert(block, lines[i])
        depth = depth + braceDelta(lines[i])
      end
      out[name] = table.concat(block, "\n")
    end
    i = i + 1
  end
  return out
end

-- New file, with each setting that already exists replaced by your value.
local function mergeSettings(oldSrc, newSrc)
  local oldSettings = statements((splitSettings(oldSrc)))
  local newSettings, rest = splitSettings(newSrc)
  local out = {}
  local i = 1
  while i <= #newSettings do
    local line = newSettings[i]
    local name = line:match("^([%u_][%u%d_]*)%s*=")
    if name and oldSettings[name] then
      table.insert(out, oldSettings[name])
      local depth = braceDelta(line)
      while depth > 0 and i < #newSettings do
        i = i + 1
        depth = depth + braceDelta(newSettings[i])
      end
    else
      table.insert(out, line)
    end
    i = i + 1
  end
  for _, line in ipairs(rest) do table.insert(out, line) end
  local merged = table.concat(out, "\n")
  -- splitting added one trailing newline's worth of empty line; match the source
  if newSrc:sub(-1) == "\n" and merged:sub(-1) ~= "\n" then merged = merged .. "\n" end
  return (merged:gsub("\n\n$", "\n"))
end

local function fetch(url, headers)
  local ok, h = pcall(http.get, url, headers)
  if not ok or not h then return nil end
  local body = h.readAll()
  h.close()
  return body
end

local function readText(path)
  if not fs.exists(path) then return nil end
  local f = fs.open(path, "r")
  local t = f.readAll()
  f.close()
  return t
end

local function writeText(path, text)
  local f = fs.open(path, "w")
  f.write(text)
  f.close()
end

-- Returns why nothing was installed; on success the computer reboots.
local function checkForUpdate(atBoot, manual)
  if not http then return "HTTP is off" end
  if AUTO_UPDATE == false and not manual then return "off" end
  local sha = fetch("https://api.github.com/repos/" .. UPDATE_REPO .. "/commits/main",
    { ["Accept"] = "application/vnd.github.sha", ["User-Agent"] = "cc-auto-update" })
  if not sha then return "GitHub unreachable (try again in a bit)" end
  sha = sha:match("^%s*(%x+)%s*$")
  if not sha or #sha < 40 then return "GitHub gave a bad answer" end
  if readText(SHA_FILE) == sha then return "already up to date" end

  local newSrc = fetch("https://raw.githubusercontent.com/" .. UPDATE_REPO .. "/" .. sha .. "/" .. UPDATE_FILE)
  if not newSrc or not _G.load(newSrc, UPDATE_FILE) then return "download failed" end
  local oldSrc = readText(PROGRAM_PATH)
  if not oldSrc then return "can't read " .. PROGRAM_PATH end
  local merged = mergeSettings(oldSrc, newSrc)
  if not _G.load(merged, UPDATE_FILE) then return "new version failed to load" end
  if merged == oldSrc then
    writeText(SHA_FILE, sha)
    return "already up to date"
  end

  -- at boot nothing is running yet, so there is nothing to wait for
  while not atBoot and not readyToUpdate() do sleep(5) end
  writeText(PROGRAM_PATH .. ".old", oldSrc)
  writeText(PROGRAM_PATH, merged)
  writeText(SHA_FILE, sha)
  term.setBackgroundColor(colors.black)
  term.clear()
  term.setCursorPos(1, 1)
  print("Updated to " .. sha:sub(1, 7) .. ", restarting...")
  if not atBoot then sleep(1) end
  os.reboot()
end

function updateLoop()
  local waited = 0
  while true do
    sleep(1)
    waited = waited + 1
    if updateNow.want then
      updateNow.want, updateNow.busy = false, true
      local ok, why = pcall(checkForUpdate, false, true)
      updateNow.busy = false
      event("Update: " .. tostring(ok and why or "error, " .. tostring(why)), "info")
      waited = 0
    elseif waited >= UPDATE_CHECK_MINUTES * 60 then
      pcall(checkForUpdate)
      waited = 0
    end
  end
end

-- Check for a new version as soon as the computer starts, before the
-- program runs, so a restart always picks up the latest version.
function bootUpdate()
  if AUTO_UPDATE == false or not http then return end
  term.setBackgroundColor(colors.black)
  term.clear()
  term.setCursorPos(1, 1)
  print("Checking for updates...")
  pcall(checkForUpdate, true)
end
end

bootUpdate()
parallel.waitForAny(scanLoop, chatLoop, discordLoop, botLoop, eventLoop, watchLoop, displayLoop, terminalLoop, touchLoop, updateLoop)
