@echo off
rem Edit these two paths for your own machine: your BizHawk install's EmuHawk.exe, and your
rem own legally-obtained Emerald ROM (never shipped with this repo -- see
rem agent_docs/licensing.md). This is instance 2 -- pair with run-core2.bat.
set EMUHAWK_EXE=C:\path\to\BizHawk\EmuHawk.exe
set EMERALD_ROM=C:\path\to\roms\Pokemon - Emerald Version (USA, Europe).gba

set MESHGHOST_BRIDGE_PORT=7779
"%EMUHAWK_EXE%" "%EMERALD_ROM%"
