-- Logs the 68000's writes to the registers / RAMs MAME does not use or does not understand (docs/status.md, "MAME's flaws" 2 and 7):
-- the BG line RAMs 301000-3013ff / 401000-4013ff / 501000-5013ff (non-zero writes only), the 880000-88002f registers (every write except
-- 880022, the watchdog), and the scroll registers' third word (flip) of the four tilemaps.  Plays like tools/lua/dump_state.lua's SCHEDULE=play.
--   WRLOG=<file>  FRAMES=<n>  SEED=<n>
local mach = manager.machine
local sp   = mach.devices[":maincpu"].spaces["program"]
local scr  = mach.screens[":screen"]
local out  = assert(io.open(os.getenv("WRLOG") or "wrlog.txt", "w"))
local LAST = tonumber(os.getenv("FRAMES") or "7200")
_G.KEEP = _G.KEEP or {}
local K = _G.KEEP
local seen = {}
local function log(kind, a, d, m)
  local key = string.format("%s %06x %04x", kind, a, d)
  if not seen[key] then
    seen[key] = true
    out:write(string.format("%6d %s %06x %04x mask %04x\n", scr:frame_number(), kind, a, d, m)); out:flush()
  end
end
K.t1 = sp:install_write_tap(0x301000, 0x3013ff, "l1", function(o, d, m) if d & m ~= 0 then log("line1", o, d, m) end end)
K.t2 = sp:install_write_tap(0x401000, 0x4013ff, "l2", function(o, d, m) if d & m ~= 0 then log("line2", o, d, m) end end)
K.t3 = sp:install_write_tap(0x501000, 0x5013ff, "l3", function(o, d, m) if d & m ~= 0 then log("line3", o, d, m) end end)
K.t4 = sp:install_write_tap(0x880000, 0x88002f, "r88", function(o, d, m) if o ~= 0x880022 and o ~= 0x880000 and o ~= 0x880002 then log("r88", o, d, m) end end)
for _, a in ipairs({ 0xc00004, 0xc80004, 0xa80004, 0xb00004 }) do
  K["f" .. a] = sp:install_write_tap(a, a + 1, "fl" .. a, function(o, d, m) log("flip", o, d, m) end)
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
K.n = emu.add_machine_frame_notifier(function()
  local f = scr:frame_number()
  setv(coin, f >= 1500 and (f - 1500) % 1800 < 6)
  setv(start, f >= 1600 and (f - 1600) % 1800 < 6)
  if f >= 1700 then
    if f % 10 == 0 then dir = rnd(5) end
    setv(up, dir == 1); setv(dn, dir == 2); setv(lf, dir == 3); setv(rt, dir == 4)
    for i = 1, 4 do setv(btn[i], f % PERIOD[i] < 5) end
  end
  if f >= LAST then out:close(); mach:exit() end
end)
