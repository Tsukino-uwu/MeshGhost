@echo off
rem Pairs with run-bizhawk-emerald-loopback-trail.local.bat (MESHGHOST_LOOPBACK_TRAIL=1): with no render offset the
rem ghost sits on the player, and only a real interp delay makes it visible as a trail.
..\meshghost.exe -game=emerald -bridge=127.0.0.1:7778 -name=player1 -interp=200ms
pause
