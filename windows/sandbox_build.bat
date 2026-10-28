@echo off
rem sandbox_build.bat - build the Windows wheels in a fresh Windows Sandbox.
rem Run from a command prompt on the host with no options (the counterpart
rem of build.sh and macos/tart_build.sh); any options are passed on to
rem sandbox_build.ps1, which documents them.  Chain with the tests as
rem   windows\sandbox_build.bat && windows\test_via_sandbox.bat
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0sandbox_build.ps1" %*
exit /b %ERRORLEVEL%
