@echo off
rem Builds and stages the TEVI plugin from two clean clones of HEAD; dev-scripts\build-tevi.ps1 does the work.
rem CI cannot build it (it compiles against your own TEVI install's assemblies), so the staged DLL is committed.
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%~dp0build-tevi.ps1" %*
exit /b %errorlevel%
