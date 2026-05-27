@echo off
setlocal EnableExtensions
set NAME=demo
for %%F in (*.lua) do (
  if exist "%%F" echo %NAME%:%%F
)
goto :eof

:build
echo Building %1
exit /b 0
