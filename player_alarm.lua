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
ENEMY_LINES = {                   -- one of these is picked at random for each announcement
  "Lock the vaults. Man the cannons. Trust no one.",
  "Hide your shells and guard your ships.",
  "All hands to battle stations!",
  "Watch your back. The enemy is among us.",
  "Raise the shields and double the guards.",
}
MUTE_MINUTES = 5          -- how long the MUTE button silences the siren and speaker
UNLOCK_SECONDS = 60       -- right-click the detector to unlock MUTE on the monitor
UTC_OFFSET = 0            -- hours added to server time for the log (e.g. -5)

DISCORD_WEBHOOK = nil     -- paste a Discord webhook URL here (in quotes) to post alerts to a channel
RADAR_MODE = "auto"       -- radar view: "players", "threats" or "all"; "auto" = threats when a Create Radar is found
SHIP_WARN = false         -- toast the allowed list when a new ship shows up on the radar

MONITOR = nil             -- nil = the biggest monitor attached
TITLE = "BASE SECURITY"
AUTO_UPDATE = true        -- install new versions from GitHub automatically, keeping these settings


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

local function discord(title, text, color)
  if not DISCORD_WEBHOOK or DISCORD_WEBHOOK == "" or not http then return end
  table.insert(discordQueue, { title = title, text = text, color = color })
end

local function discordLoop()
  while true do
    local msg = table.remove(discordQueue, 1)
    if msg then
      local body = textutils.serializeJSON({
        username = TITLE,
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
  discord("Intruder detected", "**" .. v.name .. "** is " .. where .. " from base.", RED_C)
  event(v.name .. " arrived (" .. where .. ")", "alert")
  warnAllowed("Intruder " .. v.name .. " is " .. where .. " from base", "Intruder alert")
  alertFlash = now() + 6
  view = "radar"
end

local function onClose(v)
  local where = whereText(v.name, v.dist)
  discord("Intruder getting close", "**" .. v.name .. "** is " .. where .. " from base.", RED_C)
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
local shipNumbers, nextShipNumber = {}, 1
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
        event("Ship on radar, " .. where, "info")
        if SHIP_WARN then warnAllowed("Ship detected " .. where, "Radar") end
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
        shipNumbers[e.id] = nextShipNumber
        nextShipNumber = nextShipNumber + 1
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
  local ships, hostile, unknown, other = 0, 0, 0, 0
  for _, e in ipairs(tracks) do
    if isShip(e.category) then ships = ships + 1
    elseif e.category == "HOSTILE" then hostile = hostile + 1
    elseif e.category == "PLAYER" and not e.name then unknown = unknown + 1
    else other = other + 1 end
  end
  return ships, hostile, unknown, other
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
local watchedOnline = {}

-- Minecraft chat JSON for the enemy announcement.
local function enemyMessage(name, test)
  local line = ENEMY_LINES[math.random(1, #ENEMY_LINES)]
  local SWORDS = "\226\154\148"  -- U+2694 crossed swords, as UTF-8 bytes
  local parts = {
    { text = SWORDS .. " ENEMY DETECTED " .. SWORDS .. "\n", color = "dark_red", bold = true },
    { text = name, color = "red", bold = true, underlined = true },
    { text = " has entered the server.\n", color = "gray" },
    { text = line, color = "gold", italic = true },
  }
  if test then table.insert(parts, { text = "  (test, only the allowed list sees this)", color = "dark_gray", italic = true }) end
  -- unicode_strings turns the UTF-8 symbols into \u escapes Minecraft understands;
  -- older CC versions don't have it, so fall back to plain ASCII.
  local ok, json = pcall(textutils.serializeJSON, parts, { unicode_strings = true })
  if not ok then
    parts[1].text = "!! ENEMY DETECTED !!\n"
    json = textutils.serializeJSON(parts)
  end
  return json, "ENEMY DETECTED: " .. name .. " has entered the server. " .. line
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
local function announceEnemy(name, online)
  if not chat then return end
  local json, plain = enemyMessage(name)
  local pos = 1
  for _, p in ipairs(online) do
    if p:lower() ~= name:lower() then
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
  for key, name in pairs(now_) do
    if not watchedOnline[key] then
      event("ENEMY " .. name .. " is online", "alert")
      announceEnemy(name, online)
      discord("ENEMY DETECTED", "**" .. name .. "** has entered the server.", PURPLE_C)
    end
  end
  for key, name in pairs(watchedOnline) do
    if not now_[key] then
      event(name .. " went offline", "info")
      discord("Enemy offline", "**" .. name .. "** left the server.", AMBER_C)
    end
  end
  watchedOnline = now_
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

-- ============================================================ DirectGPU screen

local gpu, display, W, H
local gpuError = nil
local view = "radar"     -- "radar" or "log"
local viewAt = 0
local zoom = RANGE        -- radar scale in blocks (view only)
local selected = nil      -- player whose details are shown
local gpuButtons = {}
local function gpuButton(x, y, w, h, action)
  table.insert(gpuButtons, { x = x, y = y, w = w, h = h, action = action })
end

local FONT = "SansSerif"
local BG = { 12, 14, 18 }
local PANEL = { 24, 28, 35 }
local GRID = { 30, 70, 52 }
local GRID2 = { 22, 48, 38 }
local SWEEP = { 70, 230, 150 }
local MUTED = { 135, 144, 158 }
local WHITE = { 236, 239, 244 }
local GREEN = { 62, 200, 110 }
local RED = { 236, 74, 66 }
local DARKRED = { 120, 28, 26 }
local AMBER = { 240, 172, 52 }

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

local function findMonitor()
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

local function setupGpu()
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

-- Blip position: real direction when the detector is calibrated, otherwise a
-- steady angle per name at the measured distance.
local function blipAngle(e)
  if e.dx and e.dz then return math.atan2(e.dz, e.dx) end
  local h = 0
  for i = 1, #e.name do h = (h * 31 + e.name:byte(i)) % 3600 end
  return h / 3600 * 2 * math.pi
end

local function drawRadar(cx, cy, r, small)
  circle(cx, cy, r, { 10, 22, 17 }, true)
  for i = 1, 4 do
    circle(cx, cy, r * i / 4, (i == 4) and GRID or GRID2, false)
  end
  line(cx - r, cy, cx + r, cy, GRID2)
  line(cx, cy - r, cx, cy + r, GRID2)
  for i = 1, 3 do
    text(math.floor(zoom * i / 4) .. "m", cx + 3, cy - r * i / 4 + 1, GRID, small * 0.85)
  end
  if detectorPos then
    text("N", cx - textWidth("N", small, "bold") / 2, cy - r + 3, GRID, small, "bold")
  end

  -- Sweep with a fading trail
  local a0 = (now() * 1.6) % (2 * math.pi)
  for k = 14, 0, -1 do
    local a = a0 - k * 0.045
    local c = mix({ 10, 22, 17 }, SWEEP, (1 - k / 15) ^ 2)
    line(cx, cy, cx + math.cos(a) * r, cy + math.sin(a) * r, c)
  end

  -- Radar tracks
  local SHIP = { 90, 160, 245 }
  local HOST = { 245, 120, 50 }
  local PROJ = { 250, 220, 70 }
  local MOBC = { 120, 128, 140 }
  local UNKNOWN = { 240, 172, 52 }
  for _, t in ipairs(visibleTracks()) do
    if t.dist and t.dx then
      local a = math.atan2(t.dz, t.dx)
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
      if isShip(c) then
        -- drawn in their own pass below so they sit on top
      elseif c == "PROJECTILE" then
        circle(bx, by, 2, PROJ, true)
      elseif c == "HOSTILE" then
        rect(bx - 3, by - 3, 6, 6, HOST)
      elseif c == "PLAYER" then
        circle(bx, by, 4, UNKNOWN, true)
        text("?", bx + 7, by - small * 0.5, UNKNOWN, small * 0.9, "bold")
      else
        circle(bx, by, 2, MOBC, true)
      end
    end
  end

  -- Ships: a filled hull pointing where it's heading, a fading wake behind,
  -- a dashed line to where it'll be in 5 seconds, and a label.
  local SHIPC = { 70, 215, 255 }
  local SHIPDARK = { 20, 70, 95 }
  for _, t in ipairs(visibleTracks()) do
    if isShip(t.category) and t.dist and t.dx then
      local a = math.atan2(t.dz, t.dx)
      local d = math.min(1, t.dist / zoom) * (r - 6)
      local bx, by = cx + math.cos(a) * d, cy + math.sin(a) * d
      local moving = t.speed and t.speed >= 0.3
      local hd = moving and math.atan2(t.vz, t.vx) or -math.pi / 2
      local ch, sh = math.cos(hd), math.sin(hd)
      local function pt(fx, fy) return bx + fx * ch - fy * sh, by + fx * sh + fy * ch end
      local scale = 1.3
      if moving then
        local k = math.min(r, 5 * t.speed / zoom * (r - 6))
        for i = 1, 6 do
          local wx, wy = pt(-8 - i * 4, 0)
          circle(wx, wy, math.max(1, 3 - i * 0.4), mix({ 10, 22, 17 }, SHIPC, 0.6 - i * 0.08), true)
        end
        for i = 0, 7 do
          local f0, f1 = 12 + k * i / 8, 12 + k * (i + 0.5) / 8
          local x0, y0 = pt(f0, 0)
          local x1, y1 = pt(f1, 0)
          line(x0, y0, x1, y1, SHIPC)
        end
      end
      -- hull: nose, then the stern corners, filled with a fan of lines
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
      local label = "SHIP " .. (t.number or "?")
      text(label, bx + 14, by - small, SHIPC, small * 0.9, "bold")
      text(meters(t.dist) .. "  " .. shipSpeedText(t), bx + 14, by, SHIPC, small * 0.75)
    end
  end

  -- Blips: allowed players green, intruders red with a pulse ring
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
  for _, e in ipairs(nearbyList()) do
    if e.dist then
      local a = blipAngle(e)
      local outside = e.dist > zoom
      local d = math.min(1, e.dist / zoom) * (r - 6)
      local bx, by = cx + math.cos(a) * d, cy + math.sin(a) * d
      if e.name == selected then circle(bx, by, 9, WHITE, false) end
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

local function pill(x, y, w, h, label, bg, fg, size, action)
  rect(x, y, w, h, bg)
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

local function drawDetails(e, x, bottom, w, small, medium)
  local lines = detailLines(e)
  local rowH = small + 5
  local h = medium + 12 + #lines * rowH + 4
  local y = bottom - h
  rect(x, y, w, h, PANEL)
  rect(x, y, 4, h, e.allowed and GREEN or RED)
  text(fit(e.name, w - 44, medium, "bold"), x + 12, y + 6, WHITE, medium, "bold")
  pill(x + w - 30, y + 4, 26, medium + 4, "X", { 50, 56, 66 }, WHITE, small, function() selected = nil end)
  for i, l in ipairs(lines) do
    text(fit(l, w - 20, small), x + 12, y + medium + 12 + (i - 1) * rowH, MUTED, small)
  end
end

local function drawLogPage()
  local pad = math.max(8, math.floor(W * 0.03))
  local small = math.max(10, math.floor(W * 0.03))
  local medium = math.max(12, math.floor(W * 0.04))
  local big = math.max(16, math.floor(W * 0.06))

  gpu.clear(display, BG[1], BG[2], BG[3])
  local headH = big + pad * 2
  rect(0, 0, W, headH, PANEL)
  text("VISIT LOG", pad, pad - 1, WHITE, big, "bold")
  local bw = textWidth("BACK", small, "bold") + pad * 2
  pill(W - pad - bw, (headH - (small + pad)) / 2, bw, small + pad, "BACK", { 50, 56, 66 }, WHITE, small, function() view = "radar" end)
  textRight(todayCount() .. " today", W - pad * 2 - bw, (headH - medium) / 2, MUTED, medium)
  local y = headH + pad

  -- Repeat visitors
  local people = {}
  for _, st in pairs(stats) do table.insert(people, st) end
  table.sort(people, function(a, b)
    if a.visits ~= b.visits then return a.visits > b.visits end
    return (a.last or 0) > (b.last or 0)
  end)
  rect(pad, y, W - pad * 2, small + pad, PANEL)
  text("VISITORS", pad * 1.6, y + pad / 2, MUTED, small, "bold")
  textRight("visits   time   closest", W - pad * 1.6, y + pad / 2, MUTED, small)
  y = y + small + pad + 2
  local rowH = small + 7
  for i = 1, math.min(5, #people) do
    local st = people[i]
    text(fit(st.name, W * 0.4, small, "bold"), pad * 1.6, y + 2, WHITE, small, "bold")
    local right = st.visits .. "   " .. fmtDuration(st.seconds) .. "   " .. meters(st.closest)
    textRight(right, W - pad * 1.6, y + 2, AMBER, small)
    y = y + rowH
  end
  if #people == 0 then
    text("Nobody yet", pad * 1.6, y + 2, MUTED, small)
    y = y + rowH
  end
  y = y + pad / 2

  -- Every visit, newest first
  rect(pad, y, W - pad * 2, small + pad, PANEL)
  text("WHEN", pad * 1.6, y + pad / 2, MUTED, small, "bold")
  text("WHO", pad * 1.6 + textWidth("00/00 00:00  ", small), y + pad / 2, MUTED, small, "bold")
  textRight("STAYED  CLOSEST", W - pad * 1.6, y + pad / 2, MUTED, small, "bold")
  y = y + small + pad + 2
  local rows = math.floor((H - small - pad * 2 - y) / rowH)
  for i = 0, rows - 1 do
    local v = visits[#visits - i]
    if not v then break end
    local yy = y + i * rowH
    if i % 2 == 0 then rect(pad, yy - 1, W - pad * 2, rowH, { 18, 21, 27 }) end
    text(fmtWhen(v.first), pad * 1.6, yy + 2, MUTED, small)
    text(fit(v.name, W * 0.33, small, "bold"), pad * 1.6 + textWidth("00/00 00:00  ", small), yy + 2, WHITE, small, "bold")
    textRight(fmtDuration(v.last - v.first) .. "  " .. meters(v.closest), W - pad * 1.6, yy + 2, AMBER, small)
  end
  if #visits == 0 then text("No visits logged yet", pad * 1.6, y + 2, MUTED, small) end

  text("Tap BACK for the radar", pad, H - small - pad / 2, MUTED, small)
  gpu.updateDisplay(display)
end

local function drawGpu()
  gpuButtons = {}
  if view == "log" then return drawLogPage() end
  local pad = math.max(8, math.floor(W * 0.03))
  local small = math.max(10, math.floor(W * 0.03))
  local medium = math.max(12, math.floor(W * 0.04))
  local big = math.max(16, math.floor(W * 0.06))
  local intruders = intruderCount()

  gpu.clear(display, BG[1], BG[2], BG[3])

  -- Header
  local headH = big + pad * 2
  rect(0, 0, W, headH, PANEL)
  text(TITLE, pad, pad - 1, WHITE, big, "bold")
  textRight(clockText(), W - pad, (headH - medium) / 2, WHITE, medium, "bold")

  -- Status banner
  local y = headH + pad
  local bannerH = big + pad * 2
  if scanError then
    rect(pad, y, W - pad * 2, bannerH, AMBER)
    text(fit(scanError, W - pad * 4, medium, "bold"), pad * 2, y + (bannerH - medium) / 2, BG, medium, "bold")
  elseif intruders > 0 then
    local flash = (math.floor(now() * 2) % 2 == 0) and RED or DARKRED
    rect(pad, y, W - pad * 2, bannerH, flash)
    local msg = intruders == 1 and "INTRUDER ALERT" or (intruders .. " INTRUDERS")
    if muted() then msg = msg .. " (MUTED)" end
    local mw = textWidth(msg, big, "bold")
    text(msg, (W - mw) / 2, y + (bannerH - big) / 2 - 1, WHITE, big, "bold")
  else
    rect(pad, y, W - pad * 2, bannerH, { 22, 70, 44 })
    local msg = "SECURE"
    local mw = textWidth(msg, big, "bold")
    text(msg, (W - mw) / 2, y + (bannerH - big) / 2 - 1, GREEN, big, "bold")
  end
  y = y + bannerH + pad

  local watchNames = {}
  for _, name in pairs(watchedOnline) do table.insert(watchNames, name) end
  if #watchNames > 0 then
    table.sort(watchNames)
    local stripH = small + pad
    rect(pad, y, W - pad * 2, stripH, AMBER)
    local msg = "ENEMY ONLINE: " .. table.concat(watchNames, ", ")
    text(fit(msg, W - pad * 4, small, "bold"), pad * 2, y + (stripH - small) / 2 - 1, BG, small, "bold")
    y = y + stripH + pad / 2
  end

  -- Toolbar: zoom, log, mute
  local tbH = small + pad
  local bw = math.floor((W - pad * 2 - pad * 4) / 5)
  local x = pad
  local BTN = { 50, 56, 66 }
  pill(x, y, bw, tbH, "-", BTN, WHITE, medium, function() zoomStep(-1) end)
  x = x + bw + pad
  pill(x, y, bw, tbH, "+", BTN, WHITE, medium, function() zoomStep(1) end)
  x = x + bw + pad
  local m = currentMode()
  pill(x, y, bw, tbH, m:upper(), #radars > 0 and { 40, 70, 110 } or { 40, 44, 52 }, #radars > 0 and WHITE or MUTED, small * 0.85, function()
    if #radars == 0 then
      event("Add a Create Radar for THREATS and ALL modes", "info")
      return
    end
    local idx = 1
    for i, v in ipairs(MODES) do if v == m then idx = i end end
    mode = MODES[idx % #MODES + 1]
    writeFile(DIR .. "/mode", mode)
  end)
  x = x + bw + pad
  pill(x, y, bw, tbH, "LOG", BTN, WHITE, small, function() view = "log" viewAt = now() end)
  x = x + bw + pad
  if muted() then
    local left = math.ceil(muteUntil - now())
    pill(x, y, bw, tbH, string.format("%d:%02d", math.floor(left / 60), left % 60), AMBER, BG, small, function()
      if unlocked() then muteUntil = 0 event("Alarm unmuted", "info") end
    end)
  else
    local open = unlocked()
    pill(x, y, bw, tbH, "MUTE", open and { 120, 90, 30 } or { 40, 44, 52 }, open and WHITE or MUTED, small, function()
      if unlocked() then
        muteUntil = now() + MUTE_MINUTES * 60
        event("Alarm muted by " .. tostring(unlockedBy), "info")
      else
        event("Right-click the detector to unlock MUTE", "info")
      end
    end)
  end
  y = y + tbH + pad

  -- Radar, with the selected player's details over its lower half
  local r = math.min((W - pad * 2) / 2, H * 0.21)
  drawRadar(W / 2, y + r, r, small)
  if selected then
    local e = present[selected]
    if e then
      drawDetails(e, pad * 2, y + r * 2, W - pad * 4, small, medium)
    else
      selected = nil
    end
  end
  y = y + r * 2 + pad

  -- Nearby players
  rect(pad, y, W - pad * 2, small + pad, PANEL)
  text("NEARBY", pad * 1.6, y + pad / 2, MUTED, small, "bold")
  local hdr = "view " .. zoom .. "m"
  if #radars > 0 then
    local ships, hostile, unknown = radarSummary()
    hdr = ships .. " ships, " .. hostile .. " hostile" .. (unknown > 0 and (", " .. unknown .. " unknown") or "") .. "  |  " .. hdr
  end
  textRight(fit(hdr, W * 0.7, small), W - pad * 1.6, y + pad / 2, MUTED, small)
  y = y + small + pad + 2
  local list = nearbyList()
  local ships = shipList()
  local rowH = medium + 8
  local slots = (#ships > 0) and 3 or 4
  local maxNearby = math.max(1, math.min(slots, #list))
  if #list > slots then maxNearby = slots - 1 end
  if #list == 0 then
    text("Nobody in range", pad * 1.6, y + 4, MUTED, medium)
    y = y + rowH
  end
  for i = 1, maxNearby do
    local e = list[i]
    if not e then break end
    local c = e.allowed and GREEN or RED
    if e.name == selected then rect(pad, y - 2, W - pad * 2, rowH, { 32, 37, 46 }) end
    rect(pad, y, 4, rowH - 4, c)
    local name = e.name
    gpuButton(pad, y - 2, W - pad * 2, rowH, function() selected = (selected ~= name) and name or nil end)
    text(fit(e.name, W * 0.42, medium, "bold"), pad * 1.6, y + 2, WHITE, medium, "bold")
    local info = meters(e.dist)
    if e.dx then info = info .. " " .. compass(e.dx, e.dz) end
    local v = active[e.name]
    if v then info = info .. "  " .. fmtDuration(now() - v.first) end
    textRight(info, W - pad * 1.6, y + 2, c, medium, "bold")
    y = y + rowH
  end
  if #list > maxNearby then
    text("+" .. (#list - maxNearby) .. " more nearby", pad * 1.6, y + 2, MUTED, small)
    y = y + small + 6
  end
  local SHIPC = { 70, 215, 255 }
  for i = 1, math.min(2, #ships) do
    local e = ships[i]
    rect(pad, y, 4, rowH - 4, SHIPC)
    text("SHIP " .. (e.number or "?"), pad * 1.6, y + 2, SHIPC, medium, "bold")
    textRight(meters(e.dist) .. " " .. compass(e.dx, e.dz) .. "  " .. shipSpeedText(e), W - pad * 1.6, y + 2, SHIPC, medium, "bold")
    y = y + rowH
  end
  if #ships > 2 then
    text("+" .. (#ships - 2) .. " more ships", pad * 1.6, y + 2, MUTED, small)
    y = y + small + 6
  end
  y = y + pad / 2

  -- Visit log, only if there's room for the header and a row (LOG has the full list)
  local footH = small + pad
  local logRow = small + 7
  if y + small + pad + 2 + logRow <= H - footH then
    rect(pad, y, W - pad * 2, small + pad, PANEL)
    text("VISIT LOG", pad * 1.6, y + pad / 2, MUTED, small, "bold")
    textRight(todayCount() .. " today, " .. #visits .. " total", W - pad * 1.6, y + pad / 2, MUTED, small)
    y = y + small + pad + 2
    local rows = math.floor((H - footH - y) / logRow)
    if #visits == 0 then text("No visits logged yet", pad * 1.6, y + 2, MUTED, small) end
    for i = 0, rows - 1 do
      local v = visits[#visits - i]
      if not v then break end
      local yy = y + i * logRow
      if i % 2 == 0 then rect(pad, yy - 1, W - pad * 2, logRow, { 18, 21, 27 }) end
      text(fmtWhen(v.first), pad * 1.6, yy + 2, MUTED, small)
      text(fit(v.name, W * 0.33, small, "bold"), pad * 1.6 + textWidth("00/00 00:00  ", small), yy + 2, WHITE, small, "bold")
      textRight(fmtDuration(v.last - v.first) .. "  " .. meters(v.closest), W - pad * 1.6, yy + 2, AMBER, small)
    end
  end

  -- Footer: latest event
  local fy = H - footH
  rect(0, fy, W, footH, PANEL)
  local ev = log[1]
  if ev then
    text(fit(os.date("!%H:%M", math.floor(ev.t + UTC_OFFSET * 3600)) .. "  " .. ev.text, W - pad * 2, small), pad, fy + (footH - small) / 2 - 1, ev.kind == "alert" and RED or MUTED, small, ev.kind == "alert" and "bold" or "plain")
  else
    text("Tap a player for details", pad, fy + (footH - small) / 2 - 1, MUTED, small)
  end

  gpu.updateDisplay(display)
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
  y = y + 1
  dot(2, y, detectorPos ~= nil, "Direction", detectorPos and "calibrated" or "not calibrated")
  if #radars > 0 then
    local ships, hostile, unknown = radarSummary()
    dot(27, y, baseCenter() ~= nil, "Radar", currentMode())
    y = y + 1
    put(4, y, ("Radar x" .. #radars .. ": " .. ships .. " ship " .. hostile .. " hostile " .. unknown .. " unknown"):sub(1, TW - 4), colors.lightBlue)
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
    local on = watchedOnline[n:lower()] ~= nil
    table.insert(enemies, n .. (on and " (ONLINE)" or ""))
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
    if view == "log" and now() - viewAt > 30 then view = "radar" end
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
      b.action()
      return
    end
  end
end

local function touchLoop()
  while true do
    local timer = os.startTimer(0.2)
    local ev = { os.pullEvent() }
    if ev[1] == "monitor_touch" and useGpu and W then
      local ok, mw, mh = pcall(peripheral.call, ev[2], "getSize")
      if ok and mw then tap((ev[3] - 0.5) / mw * W, (ev[4] - 0.5) / mh * H) end
    end
    if useGpu and gpu and display then
      local ok, has = pcall(gpu.hasEvents, display)
      while ok and has do
        local e = gpu.pollEvent(display)
        if e and e.type == "mouse_click" then tap(e.x, e.y) end
        ok, has = pcall(gpu.hasEvents, display)
      end
    end
    if ev[1] ~= "timer" or ev[2] ~= timer then os.cancelTimer(timer) end
  end
end

local function readyToUpdate()
  return true
end

-- ============================================================ auto-update

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

local function checkForUpdate()
  if AUTO_UPDATE == false or not http then return end
  local sha = fetch("https://api.github.com/repos/" .. UPDATE_REPO .. "/commits/main",
    { ["Accept"] = "application/vnd.github.sha", ["User-Agent"] = "cc-auto-update" })
  if not sha then return end
  sha = sha:match("^%s*(%x+)%s*$")
  if not sha or #sha < 40 or readText(SHA_FILE) == sha then return end

  local newSrc = fetch("https://raw.githubusercontent.com/" .. UPDATE_REPO .. "/" .. sha .. "/" .. UPDATE_FILE)
  if not newSrc or not _G.load(newSrc, UPDATE_FILE) then return end
  local oldSrc = readText(PROGRAM_PATH)
  if not oldSrc then return end
  local merged = mergeSettings(oldSrc, newSrc)
  if not _G.load(merged, UPDATE_FILE) then return end
  if merged == oldSrc then
    writeText(SHA_FILE, sha)
    return
  end

  while not readyToUpdate() do sleep(5) end
  writeText(PROGRAM_PATH .. ".old", oldSrc)
  writeText(PROGRAM_PATH, merged)
  writeText(SHA_FILE, sha)
  term.setBackgroundColor(colors.black)
  term.clear()
  term.setCursorPos(1, 1)
  print("Updated to " .. sha:sub(1, 7) .. ", restarting...")
  sleep(1)
  os.reboot()
end

local function updateLoop()
  sleep(10)
  while true do
    pcall(checkForUpdate)
    sleep(UPDATE_CHECK_MINUTES * 60)
  end
end

parallel.waitForAny(scanLoop, chatLoop, discordLoop, eventLoop, watchLoop, displayLoop, terminalLoop, touchLoop, updateLoop)
