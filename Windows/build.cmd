@echo off
rem Builds dist\Wiggle.exe using the C# compiler that ships with Windows
rem (.NET Framework 4.x). Nothing to install and no admin rights required.
setlocal
cd /d "%~dp0"

set "CSC=%WINDIR%\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
if not exist "%CSC%" set "CSC=%WINDIR%\Microsoft.NET\Framework\v4.0.30319\csc.exe"
if not exist "%CSC%" (
  echo Could not find csc.exe under %WINDIR%\Microsoft.NET.
  echo .NET Framework 4.x is part of Windows 10 and 11, so this is unexpected.
  pause
  exit /b 1
)

if not exist dist mkdir dist

set "ICON="
if exist "Resources\Wiggle.ico" set "ICON=/win32icon:Resources\Wiggle.ico"

"%CSC%" /nologo /target:winexe /optimize+ /platform:anycpu ^
  /r:System.dll /r:System.Drawing.dll /r:System.Windows.Forms.dll ^
  %ICON% /out:dist\Wiggle.exe Program.cs
if errorlevel 1 (
  echo.
  echo Build failed.
  pause
  exit /b 1
)

echo.
echo Done: %~dp0dist\Wiggle.exe
echo Double-click it to run. Look for the W icon next to the clock.
pause
