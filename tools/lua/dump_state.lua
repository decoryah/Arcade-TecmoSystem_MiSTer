-- Dumps frames of a Tecmo System game from MAME 0.289: the pixels MAME drew and the video state they were drawn from (for the reference
-- renderer and the frozen-state benches).  (After the owner's supduck-mister / silvmil-mister tools/lua/dump_state.lua.)
--
--   DUMPFRAMES=<f,f,f...>  machine frames to capture (also ranges "a-b/s")
--   DUMPDIR=<dir>          output directory
--   SCHEDULE=play|none     scripted inputs: coin at COIN_FRAME, start at START_FRAME, random joystick / buttons from PLAY_FRAME
--   HOLD="Field@first-last,..." hold MAME input fields (":P1" / ":P2" names) over frame ranges
--   SEED=<n>, COIN_FRAME, START_FRAME, PLAY_FRAME (defaults 300, 400, 480), TEST=1 (hold the test switch from reset)
--   POKE=<addr>:<byte>:<frame>   write the byte to the 68000's space every frame from that frame on (e.g. tkdensho's screen-invert flag
--                                2005b3: POKE=2005b3:1:2000; docs/status.md, "MAME's flaws" 1)
--
-- For every captured frame <N>: the state at the frame notifier of N, and the picture MAME draws FROM it (the frame notifier runs before the
-- screen is updated, so screen:pixels() at notifier N still holds the previous picture: it is taken at notifier N + 1, as the owner's
-- supduck-mister capture does).  MAME's picture of state N: the tilemaps / palettes of state N and the sprite bitmap of state N - 1.
--   f<N>.rgb     the 320 x 240 picture (R, G, B bytes)
--   f<N>.tx      700000-703fff (8192 words, hex, one per line)      f<N>.bg1 / .bg2 / .bg3   300000 / 400000 / 500000 (2048 words)
--   f<N>.spr     800000-80ffff (32768 words)                         f<N>.pal  900000-907fff (16384)    f<N>.tpal  980000-980fff (2048)
--   f<N>.regs    the scroll shares (scroll_0..3: 3 words each) and 880000regs (24 words), hex on one line each
local mach = manager.machine
local sp   = mach.devices[":maincpu"].spaces["program"]
local scr  = mach.screens[":screen"]
local DIR  = os.getenv("DUMPDIR") or "."
_G.KEEP = _G.KEEP or {}
local KEEP = _G.KEEP

local want = {}
for part in string.gmatch(os.getenv("DUMPFRAMES") or "", "[^,]+") do
  local a, b, s = string.match(part, "^(%d+)-(%d+)/(%d+)$")
  if a then for i = tonumber(a), tonumber(b), tonumber(s) do want[i] = true end
  else want[tonumber(part)] = true end
end
local last = 0
for k in pairs(want) do if k > last then last = k end end

local function words(addr, n)
  local t = {}
  for i = 0, n - 1 do t[i + 1] = string.format("%04x", sp:read_u16(addr + 2 * i)) end
  return t
end
local function write_lines(t, path)
  local o = assert(io.open(path, "w")); o:write(table.concat(t, "\n")); o:write("\n"); o:close()
end
local function share_words(tag, n)
  local s = mach.memory.shares[tag]
  local t = {}
  for i = 0, n - 1 do t[i + 1] = s and string.format("%04x", s:read_u16(2 * i)) or "----" end
  return table.concat(t, " ")
end

local function dump_pixels(path)
  local px, pw, ph = scr:pixels()
  if not _G.SIZE_SHOWN then print(string.format("PIXELS %dx%d", pw or -1, ph or -1)); _G.SIZE_SHOWN = true end
  local out = {}
  for i = 0, #px // 4 - 1 do
    local b, g, r = px:byte(i * 4 + 1, i * 4 + 3)
    out[i + 1] = string.char(r, g, b)
  end
  local o = assert(io.open(path, "wb")); o:write(table.concat(out)); o:close()
end

local pending
local function dump(f)
  local pre = string.format("%s/f%05d", DIR, f)
  pending = pre
  write_lines(words(0x700000, 8192), pre .. ".tx")
  write_lines(words(0x300000, 2048), pre .. ".bg1")
  write_lines(words(0x400000, 2048), pre .. ".bg2")
  write_lines(words(0x500000, 2048), pre .. ".bg3")
  write_lines(words(0x800000, 32768), pre .. ".spr")
  write_lines(words(0x900000, 16384), pre .. ".pal")
  write_lines(words(0x980000, 2048), pre .. ".tpal")
  local o = assert(io.open(pre .. ".regs", "w"))
  for _, tag in ipairs({ ":scroll_0", ":scroll_1", ":scroll_2", ":scroll_3" }) do o:write(share_words(tag, 3) .. "\n") end
  o:write(share_words(":880000regs", 24) .. "\n")
  o:close()
  print("DUMPED frame " .. tostring(f)); io.stdout:flush()
end

-- inputs
local function field(pname, fname)
  local p = mach.ioport.ports[pname]
  if not p then return nil end
  for name, fld in pairs(p.fields) do if name == fname then return fld end end
  return nil
end
local coin, start = field(":P1", "Coin 1"), field(":P1", "1 Player Start")
local test = field(":P1", "Service")
local up, dn, lf, rt = field(":P1", "P1 Up"), field(":P1", "P1 Down"), field(":P1", "P1 Left"), field(":P1", "P1 Right")
local btn = { field(":P1", "P1 Button 1"), field(":P1", "P1 Button 2"), field(":P1", "P1 Button 3"), field(":P1", "P1 Button 4") }
local SCHED = os.getenv("SCHEDULE") or "none"
local COIN_FRAME  = tonumber(os.getenv("COIN_FRAME") or "300")
local START_FRAME = tonumber(os.getenv("START_FRAME") or "400")
local PLAY_FRAME  = tonumber(os.getenv("PLAY_FRAME") or "480")
local rng = tonumber(os.getenv("SEED") or "12345")
local function rnd(n) rng = (rng * 1103515245 + 12345) & 0x7fffffff; return (rng >> 8) % n end
local function setv(fld, on) if fld then fld:set_value(on and 1 or 0) end end
local dir = 0
local PERIOD = { 23, 37, 29, 41 }

-- HOLD="Field Name@first-last,Field Name@first-last,...": hold those P1 / P2 fields over those frames (e.g. "Service@600-700")
local HOLDS = {}
for name, a, b in string.gmatch(os.getenv("HOLD") or "", "([^,@]+)@(%d+)-(%d+)") do
  local fld = field(":P1", name) or field(":P2", name)
  assert(fld, "no input field " .. name)
  HOLDS[#HOLDS + 1] = { fld, tonumber(a), tonumber(b), name }
end

local POKE_A, POKE_V, POKE_F
do
  local a, v, f = string.match(os.getenv("POKE") or "", "^(%x+):(%x+):(%d+)$")
  if a then POKE_A, POKE_V, POKE_F = tonumber(a, 16), tonumber(v, 16), tonumber(f) end
end

KEEP.notif = emu.add_machine_frame_notifier(function()
  local f = scr:frame_number()
  if POKE_A and f >= POKE_F then sp:write_u8(POKE_A, POKE_V) end
  if pending then dump_pixels(pending .. ".rgb"); pending = nil end
  if os.getenv("TEST") == "1" then setv(test, f < 120) end
  if SCHED == "play" then
    setv(coin, f >= COIN_FRAME and (f - COIN_FRAME) % 1800 < 6)
    setv(start, f >= START_FRAME and (f - START_FRAME) % 1800 < 6)
    if f >= PLAY_FRAME then
      if f % 10 == 0 then dir = rnd(5) end
      setv(up, dir == 1); setv(dn, dir == 2); setv(lf, dir == 3); setv(rt, dir == 4)
      for i = 1, 4 do setv(btn[i], f % PERIOD[i] < 5) end
    end
  end
  if #HOLDS > 0 then
    local on, fl = {}, {}             -- (by name: each field() lookup returns a new userdata)
    for _, h in ipairs(HOLDS) do on[h[4]] = on[h[4]] or (f >= h[2] and f <= h[3]); fl[h[4]] = h[1] end
    for n, v in pairs(on) do setv(fl[n], v) end
  end
  if want[f] then dump(f) end
  if f > last then mach:exit() end
end)
