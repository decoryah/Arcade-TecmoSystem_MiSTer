-- Logs the Z80's writes to the sound chips (tecmosys.cpp io_map: 00-03 YMF262, 10 OKI, 20 OKI banks, 30 Z80 bank, 50 NMI enable,
-- 60-61 YMZ280B) as "frame port data" lines, to compare with the bench's +SNDLOG= (tools/cmp_sndlog.py).
--   SNDLOG=<file>  FRAMES=<last frame>
local mach = manager.machine
local scr  = mach.screens[":screen"]
local zio  = mach.devices[":audiocpu"].spaces["io"]
local out  = assert(io.open(os.getenv("SNDLOG") or "sndlog.txt", "w"))
local LAST = tonumber(os.getenv("FRAMES") or "1200")
_G.KEEP = _G.KEEP or {}
_G.KEEP.t = zio:install_write_tap(0x00, 0xff, "snd", function(off, data, mask)
  local p = off & 0xff
  if p <= 0x03 or p == 0x10 or p == 0x20 or p == 0x30 or p == 0x50 or p == 0x60 or p == 0x61 then
    out:write(string.format("%d %02x %02x\n", scr:frame_number(), p, data & 0xff))
  end
end)
_G.KEEP.n = emu.add_machine_frame_notifier(function()
  if scr:frame_number() >= LAST then out:close(); mach:exit() end
end)
