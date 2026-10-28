@echo off
rem test_via_sandbox.bat - test the built Windows wheels in a fresh Windows
rem Sandbox.  Run from a command prompt on the host with no options after
rem sandbox_build.bat (the counterpart of test_via_docker.py and
rem macos/test_via_tart.sh); any options are passed on to
rem sandbox_run.ps1 test, which documents them.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0sandbox_run.ps1" test %*
rem (cmd /c exit, not exit /b: at an interactive prompt, && after a batch
rem file that ends with exit /b runs the next command regardless.)
cmd /c exit %ERRORLEVEL%
