@echo off
rem test_via_sandbox.bat - test the built Windows wheels in a fresh Windows
rem Sandbox.  Run from a command prompt on the host with no options after
rem sandbox_build.bat (the counterpart of test_via_docker.py and
rem macos/test_via_tart.sh); any options are passed on to
rem test_via_sandbox.ps1, which documents them.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0test_via_sandbox.ps1" %*
exit /b %ERRORLEVEL%
