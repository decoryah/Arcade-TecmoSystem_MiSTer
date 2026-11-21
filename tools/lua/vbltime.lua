-- When, after the start of the vertical blank (the 68000's interrupt, MAME's vpos 240), does the game change what the picture is drawn
-- from?  The core draws its lines from the live tilemaps, scroll registers and palettes, line 0 during the last line of the blank, so a
-- change later than that shows on the core's top lines but not in MAME's picture (MAME draws the whole frame 3 ms after the interrupt:
-- VIDEO_UPDATE_AFTER_VBLANK with a 3000 us vblank).  Every write that changes a word is timed from the screen position
-- (MAME's vblank starts at line 240 of its 512 x 512 raster, 57.4458 Hz) and counted per region in bands of delay; the latest ones inside the blank are listed.
-- Plays like tools/lua/wrlog.lua (coin at 1500, start at 1600, random play from 1700, a coin and a start every 1800 frames).
--   VBLLOG=<file>  FRAMES=<n>  SEED=<n>  RAW=<file> (optional: "frame region address ms" for each changing write 1.4-3.0 ms in)
local mach = manager.machine
local cpu  = mach.devices[":maincpu"]
local sp   = cpu.spaces["program"]
local scr  = mach.screens[":screen"]
local OUT  = os.getenv("VBLLOG") or "vbltime.txt"
local LAST = tonumber(os.getenv("FRAMES") or "12000")
_G.KEEP = _G.KEEP or {}
local K = _G.KEEP

local PERIOD_S = 1 / 57.4458
local BANDS = { 0.5, 1.0, 1.5, 2.0, 3.0, 9.25, 99 }            -- ms; the last band is the active display (vpos 0-239)
local REG = {
  { "tx",    0x700000, 0x703fff }, { "bg1",   0x300000, 0x300fff }, { "bg2",   0x400000, 0x400fff }, { "bg3",   0x500000, 0x500fff },
  { "scr0",  0xc00000, 0xc00005 }, { "scr1",  0xc80000, 0xc80005 }, { "scr2",  0xa80000, 0xa80005 }, { "scr3",  0xb00000, 0xb00005 },
  { "tpal",  0x980000, 0x980fff }, { "spal",  0x900000, 0x907fff }, { "spr",   0x800000, 0x80ffff }, { "r88",   0x880000, 0x88002f },
}
local count, late = {}, {}
local raw = os.getenv("RAW") and assert(io.open(os.getenv("RAW"), "w"))     -- RAW=<file>: every changing write 1.4-3.0 ms after the interrupt
local function delay_ms()                                        -- (the Lua screen has no vpos / hpos; time_until_pos is in seconds)
  local t = scr:time_until_pos(240, 0)
  return (PERIOD_S - t) % PERIOD_S * 1000
end
for _, r in ipairs(REG) do
  local name = r[1]
  count[name] = {}
  for i = 1, #BANDS do count[name][i] = 0 end
  K["t" .. name] = sp:install_write_tap(r[2], r[3], "vt" .. name, function(o, d, m)
    if name == "r88" and o >= 0x880022 and o <= 0x880023 then return end          -- the watchdog
    local old = sp:read_u16(o & ~1)
    if (old & m) == (d & m) then return end
    local t = delay_ms()
    local i = 1
    while t >= BANDS[i] do i = i + 1 end
    count[name][i] = count[name][i] + 1
    if raw and t >= 1.4 and t < 3.0 then raw:write(string.format("%d %s %06x %.4f\n", scr:frame_number(), name, o, t)) end
    if t < 3.0 then
      late[#late + 1] = { t, scr:frame_number(), name, o, cpu.state["PC"].value }
      if #late > 400 then
        table.sort(late, function(a, b) return a[1] > b[1] end)
        for k = #late, 41, -1 do late[k] = nil end
      end
    end
  end)
end

local function field(pname, fname)
  local p = mach.ioport.ports[pname]
  if not p then return nil end
  for name, fld in pairs(p.fields) do if name == fname then return fld end end
  return nil
end
local coin, start = field(":P1", "Coin 1"), field(":P1", "1 Player Start")
local up, dn, lf, rt = field(":P1", "P1 Up"), field(":P1", "P1 Down"), field(":P1", "P1 Left"), field(":P1", "P1 Right")
local btn = { field(":P1", "P1 Button 1"), field(":P1", "P1 Button 2"), field(":P1", "P1 Button 3"), field(":P1", "P1 Button 4") }
local rng = tonumber(os.getenv("SEED") or "12345")
local function rnd(n) rng = (rng * 1103515245 + 12345) & 0x7fffffff; return (rng >> 8) % n end
local function setv(fld, on) if fld then fld:set_value(on and 1 or 0) end end
local dir = 0
local PERIOD = { 23, 37, 29, 41 }

local function report()
  local out = assert(io.open(OUT, "w"))
  local hdr = "region"
  local lo = 0
  for _, b in ipairs(BANDS) do
    hdr = hdr .. string.format("  %s", b == 99 and "active" or string.format("%.2g-%.3g", lo, b))
    lo = b
  end
  out:write(hdr .. "  (changing writes per band of ms after the vblank interrupt)\n")
  for _, r in ipairs(REG) do
    local line = string.format("%-6s", r[1])
    for i = 1, #BANDS do line = line .. string.format(" %9d", count[r[1]][i]) end
    out:write(line .. "\n")
  end
  table.sort(late, function(a, b) return a[1] > b[1] end)
  out:write("latest changing writes before MAME draws the frame (ms after the interrupt, frame, region, address, PC):\n")
  for k = 1, math.min(#late, 40) do
    local e = late[k]
    out:write(string.format("  %6.3f  %6d  %-5s %06x  pc %06x\n", e[1], e[2], e[3], e[4], e[5]))
  end
  out:close()
  if raw then raw:close() end
end

K.n = emu.add_machine_frame_notifier(function()
  local f = scr:frame_number()
  setv(coin, f >= 1500 and (f - 1500) % 1800 < 6)
  setv(start, f >= 1600 and (f - 1600) % 1800 < 6)
  if f >= 1700 then
    if f % 10 == 0 then dir = rnd(5) end
    setv(up, dir == 1); setv(dn, dir == 2); setv(lf, dir == 3); setv(rt, dir == 4)
    for i = 1, 4 do setv(btn[i], f % PERIOD[i] < 5) end
  end
  if f >= LAST then report(); mach:exit() end
end)
