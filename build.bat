@echo off
rem build.bat [app|debug|dev|test <pkg>|tool <name>|c] -- build.sh's targets, for cmd.exe.
rem Compiles each vendored C library (vendor\<lib>\fc_<lib>.c) with clang, or MSVC's cl (found with
rem vswhere if it is not on PATH), then runs odin, which must be on PATH.
setlocal
cd /d "%~dp0"
if not exist build mkdir build
set FLAGS=-collection:fc=src -vet-shadowing -strict-style

where clang >nul 2>nul
if not errorlevel 1 (
    set CC=clang -c -O2 -D_CRT_SECURE_NO_WARNINGS -o
    goto have_cc
)
where cl >nul 2>nul
if errorlevel 1 (
    for /f "usebackq delims=" %%i in (`"%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe" -latest -products * -property installationPath`) do set VS=%%i
)
if defined VS call "%VS%\VC\Auxiliary\Build\vcvars64.bat" >nul
set CC=cl -nologo -c -O2 -D_CRT_SECURE_NO_WARNINGS -Fo
:have_cc
setlocal enabledelayedexpansion
for /d %%D in (vendor\*) do (
    for %%F in (%%D\fc_*.c) do (
        echo cc %%F
        set EXTRA=
        if exist %%D\%%~nF.cflags set /p EXTRA=<%%D\%%~nF.cflags
        %CC%build\%%~nF.obj !EXTRA! %%F >nul || exit /b 1
    )
)
endlocal
rem Larger libraries list their files in vendor\<lib>\fc_<lib>.sources; each becomes build\fc_<lib>.lib,
rem rebuilt only when vendor\<lib> or this file is newer. They need MSVC 2022's cl for C++17.
for /d %%D in (vendor\*) do for %%S in (%%D\fc_*.sources) do call :lib %%S || exit /b 1

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

:lib
set N=%~n1
set OUT=build\%N:fc_=%
powershell -nop -c "$l = gi build\%N%.lib -ea 0; if ($l -and !(gci %~dp1, build.bat -r -file | ? LastWriteTime -gt $l.LastWriteTime)) { exit 1 }" || exit /b 0
echo cc %1
where cl >nul 2>nul || for /f "usebackq delims=" %%i in (`"%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe" -latest -products * -property installationPath`) do call "%%i\VC\Auxiliary\Build\vcvars64.bat" >nul 2>nul
if exist %OUT% rd /s /q %OUT%
mkdir %OUT%
set EXTRA=
if exist %~dpn1.cflags set /p EXTRA=<%~dpn1.cflags
rem A list with any .cc file is C++17 for cl. C-only lists use clang-cl when present: MSVC up to 2022
rem rejects nghttp3's _Generic (C7700). libwebp stays on cl: under _MSC_VER it compiles its SSE4.1 and
rem AVX2 files without -m flags (picked at run time), which only cl accepts.
set CC_=cl -std:c++17 -GR- -D_HAS_EXCEPTIONS=0
findstr /l /c:".cc" %1 >nul
if errorlevel 1 (set CC_=cl -std:c17& if not "%N%"=="fc_libwebp" where clang-cl >nul 2>nul && set CC_=clang-cl)
%CC_% -nologo -c -O2 -MP -D_CRT_SECURE_NO_WARNINGS %EXTRA% -Fo%OUT%\ @%1 >%OUT%.log || (type %OUT%.log & exit /b 1)
lib -nologo -out:build\%N%.lib %OUT%\*.obj
