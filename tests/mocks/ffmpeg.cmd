@echo off
rem ============================================================
rem Mock ffmpeg для PowerShell-тестов.
rem Bash-мок (tests/mocks/ffmpeg) имеет shebang и не запускается из PowerShell —
rem поэтому PS1-тесты были вынуждены проверять инлайн-копии логики вместо реального
rem скрипта. Этот мок позволяет прогонять НАСТОЯЩИЙ FFmpeg_Converter_script.ps1.
rem
rem Переменные окружения (совместимы с bash-моком):
rem   MOCK_FFMPEG_ENCODERS  — что вернуть на -encoders (nvenc/qsv/пусто)
rem   MOCK_FFMPEG_FAIL=1    — вернуть exit code 1 (эмуляция провала кодирования)
rem   MOCK_FFMPEG_LOG       — файл лога argv
rem   MOCK_FFMPEG_DURATION  — длительность в баннере (по умолчанию 00:01:00.00)
rem   MOCK_FFMPEG_BITRATE   — битрейт в баннере (по умолчанию 2000)
rem ============================================================
setlocal enabledelayedexpansion

set "ARGS=%*"
if defined MOCK_FFMPEG_LOG echo %ARGS%>>"%MOCK_FFMPEG_LOG%"

if not defined MOCK_FFMPEG_DURATION set "MOCK_FFMPEG_DURATION=00:01:00.00"
if not defined MOCK_FFMPEG_BITRATE  set "MOCK_FFMPEG_BITRATE=2000"

rem -encoders: список кодировщиков (скрипт грепает nvenc/qsv для выбора GPU-пути).
echo %ARGS% | find "-encoders" >nul
if not errorlevel 1 (
    echo Encoders:
    if /i "%MOCK_FFMPEG_ENCODERS%"=="nvenc" (
        echo  V....D h264_nvenc            NVIDIA NVENC H.264 encoder
        echo  V....D hevc_nvenc            NVIDIA NVENC hevc encoder
    )
    if /i "%MOCK_FFMPEG_ENCODERS%"=="qsv" (
        echo  V....D h264_qsv              H.264 QSV encoder
        echo  V....D hevc_qsv              HEVC QSV encoder
    )
    exit /b 0
)

rem Баннер с метаданными: реальный ffmpeg пишет его в stderr.
echo Input #0, mov,mp4,m4a, from 'mock':>&2
echo   Duration: %MOCK_FFMPEG_DURATION%, start: 0.000000, bitrate: %MOCK_FFMPEG_BITRATE% kb/s>&2
echo     Stream #0:0: Video: h264, yuv420p, 1920x1080, 30 fps>&2
echo     Stream #0:1: Audio: aac, 48000 Hz, stereo>&2

if "%MOCK_FFMPEG_FAIL%"=="1" exit /b 1

rem Создаём выходной файл: последний аргумент — путь выхода (перед возможным -y).
set "OUT="
for %%a in (%ARGS%) do (
    set "_tok=%%~a"
    if not "!_tok!"=="-y" set "OUT=%%~a"
)
if defined OUT (
    echo %OUT% | find ":" >nul
    if not errorlevel 1 if not "!OUT:~0,1!"=="-" type nul >"!OUT!" 2>nul
)
exit /b 0
