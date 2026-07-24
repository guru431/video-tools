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

rem Создаём выходной файл: путь выхода — последний токен, не равный -y (перед ним ffmpeg
rem пишет результат). Настоящий ffmpeg при rc=0 НИКОГДА не оставляет отсутствующий/нулевой
rem файл, а воркер справедливо проверяет публикацию (наличие цели после rename). Поэтому
rem пишем непустой контент, а не создаём 0-байтовый «успех». Разбор идёт через :find_out —
rem SHIFT-цикл надёжнее `for %%a in (%ARGS%)`, который глобит токены и терял выход.
set "OUT="
call :find_out %*
rem Проверки — на delayed-expansion (enabledelayedexpansion включён выше), БЕЗ пайпа
rem `echo !OUT! | find`: пайп порождает дочерний cmd без delayed-expansion, там !OUT! не
rem раскрывается — проверка молча срабатывала «мимо», и выход не создавался. Спецвыходы
rem (`-`, `null`, `pipe:N`, любой флаг) реальный ffmpeg файлом не делает — их не пишем.
if defined OUT (
    set "_skip="
    if "!OUT:~0,1!"=="-" set "_skip=1"
    if /i "!OUT!"=="null" set "_skip=1"
    if not "!OUT!"=="!OUT:pipe:=!" set "_skip=1"
    if not defined _skip >"!OUT!" echo MOCK-FFMPEG-OUTPUT
)
exit /b 0

:find_out
if "%~1"=="" goto :eof
rem Воркер дописывает `-progress <файл>` ПОСЛЕ выходного пути (script.ps1). Значение
rem после -progress — не выход: пропускаем оба токена, иначе мок писал бы в progress-файл,
rem а настоящий выход (out_tmp) не создавался бы (тогда rename в воркере не находил цель).
if /i "%~1"=="-progress" (shift & shift & goto :find_out)
if /i not "%~1"=="-y" set "OUT=%~1"
shift
goto :find_out
