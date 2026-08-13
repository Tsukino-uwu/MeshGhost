@echo off
rem MeshGhost server -- run this if YOU are hosting the session (only one
rem person in the group needs to). All settings live in config.json's
rem "server" section (same folder) -- edit that, not this file. You also
rem still need to run run-client.bat yourself if you want to play too.
rem
rem meshghost-server.exe also writes everything it prints here to
rem meshghost-server.log in this same folder -- if something goes wrong,
rem that file has the same information even after this window closes.
meshghost-server.exe
pause
