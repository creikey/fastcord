@echo off
rem build.bat [app|debug|dev|test <pkg>|tool <name>|c] -- build.sh's targets, for cmd.exe.
rem Compiles the vendored C (vendor\wuffs) with clang, or MSVC's cl (found with vswhere if it is not
rem on PATH), then runs odin, which must be on PATH.
setlocal
cd /d "%~dp0"
if not exist build mkdir build
set FLAGS=-collection:fc=src -vet-shadowing -strict-style

where clang >nul 2>nul
if not errorlevel 1 (
    clang -c -O2 -std=c99 -DWUFFS_CONFIG__AVOID_CPU_ARCH -o build\fc_wuffs.obj vendor\wuffs\fc_wuffs.c || exit /b 1
    goto c_done
)
where cl >nul 2>nul
if errorlevel 1 (
    for /f "usebackq delims=" %%i in (`"%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe" -latest -products * -property installationPath`) do set VS=%%i
)
if defined VS call "%VS%\VC\Auxiliary\Build\vcvars64.bat" >nul
cl -nologo -c -O2 -DWUFFS_CONFIG__DISABLE_MSVC_CPU_ARCH__X86_64_FAMILY -Fobuild\fc_wuffs.obj vendor\wuffs\fc_wuffs.c >nul || exit /b 1
:c_done

set T=%1
if "%T%"=="" set T=app
if "%T%"=="app" odin build src\app -out:build\fastcord.exe %FLAGS% -o:speed & exit /b
if "%T%"=="debug" odin build src\app -out:build\fastcord-debug.exe %FLAGS% -debug & exit /b
if "%T%"=="dev" odin build src\app -out:build\fastcord-dev.exe %FLAGS% -debug -o:speed & exit /b
if "%T%"=="c" exit /b 0
set P=%2
if "%T%"=="test" odin test src\%P% %FLAGS% -out:build\test-%P:/=_%.exe & exit /b
if "%T%"=="tool" odin build tools\%P% -out:build\%P%.exe %FLAGS% & exit /b
echo usage: %0 [app^|debug^|dev^|test ^<pkg^>^|tool ^<name^>^|c]
exit /b 2
