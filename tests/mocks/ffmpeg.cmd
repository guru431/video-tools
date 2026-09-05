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
rem   MOCK_FFMPEG_BITRATE   — битрейт КОНТЕЙНЕРА в баннере (по умолчанию 2000)
rem   MOCK_FFMPEG_VIDEO_BITRATE — битрейт ВИДЕОПОТОКА в строке Stream (по умолчанию 4523)
rem   MOCK_FFMPEG_AUDIO_CODEC   — кодек в строке Stream ... Audio (по умолчанию aac)
rem   MOCK_FFMPEG_SILENCE       — пары silence_start/silence_end через запятую,
rem                               например "10:20,40:50" (для silencedetect)
rem ============================================================
setlocal enabledelayedexpansion

set "ARGS=%*"
if defined MOCK_FFMPEG_LOG echo %ARGS%>>"%MOCK_FFMPEG_LOG%"

if not defined MOCK_FFMPEG_DURATION set "MOCK_FFMPEG_DURATION=00:01:00.00"
if not defined MOCK_FFMPEG_BITRATE  set "MOCK_FFMPEG_BITRATE=2000"
if not defined MOCK_FFMPEG_VIDEO_BITRATE set "MOCK_FFMPEG_VIDEO_BITRATE=4523"
if not defined MOCK_FFMPEG_AUDIO_CODEC   set "MOCK_FFMPEG_AUDIO_CODEC=aac"

rem -version: воркер спрашивает его первым делом, чтобы понять, доступен ли ffmpeg.
rem Без ветки мок отвечал на -version полным баннером и созданием файла.
if not "!ARGS:-version=!"=="!ARGS!" (
    echo ffmpeg version 8.0-mock Copyright ^(c^) 2000-2026 the FFmpeg developers
    exit /b 0
)

rem -encoders: список кодировщиков (скрипт грепает nvenc/qsv для выбора GPU-пути).
rem Проверка подстрокой, а не `echo %ARGS% | find "-encoders"`: пайп порождает два
rem дочерних cmd на КАЖДЫЙ вызов мока, а моков за прогон тысячи. Та же причина, по
rem которой пайпы убраны из production-CMD (валидация URL, expand_env).
if not "!ARGS:-encoders=!"=="!ARGS!" (
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
rem Строка Stream у настоящего ffmpeg длинная (150-200 символов) и содержит битрейт
rem ПОТОКА. Короткая строка без "kb/s" делала путь F25 (потолок по битрейту видео)
rem недостижимым для тестов: скрипт всегда уходил в fallback на битрейт контейнера.
echo     Stream #0:0(und): Video: h264 ^(High^) ^(avc1 / 0x31637661^), yuv420p^(tv, bt709^), 1920x1080 [SAR 1:1 DAR 16:9], %MOCK_FFMPEG_VIDEO_BITRATE% kb/s, 30 fps, 30 tbr, 90k tbn ^(default^)>&2
echo     Stream #0:1(und): Audio: %MOCK_FFMPEG_AUDIO_CODEC% ^(LC^) ^(mp4a / 0x6134706D^), 48000 Hz, stereo, fltp, 128 kb/s ^(default^)>&2

rem silencedetect: пары «начало:конец» через запятую в MOCK_FFMPEG_SILENCE.
if defined MOCK_FFMPEG_SILENCE (
    if not "!ARGS:silencedetect=!"=="!ARGS!" (
        for %%P in (%MOCK_FFMPEG_SILENCE%) do (
            for /f "tokens=1,2 delims=:" %%a in ("%%P") do (
                echo [silencedetect @ 0000] silence_start: %%a>&2
                echo [silencedetect @ 0000] silence_end: %%b ^| silence_duration: 5>&2
            )
        )
    )
)

rem -progress: воркер читает out_time из этого файла. Без записи прогресс-бар
rem в тестах всегда показывал 0 %, и регрессия индикатора была бы невидимой.
call :write_progress %*

rem ВАЖЕН ПОРЯДОК: выход создаётся ДО провала. Настоящий ffmpeg, упавший на середине,
rem оставляет за собой недописанный файл, и контракт «на провале хвост .partial
rem убирается» проверяется только если этот файл есть. Bash-мок делает так же; здесь
rem выход выходил ДО создания файла, и на PS1-пути проверка была недостижима.

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
if "%MOCK_FFMPEG_FAIL%"=="1" exit /b 1
exit /b 0

:write_progress
if "%~1"=="" goto :eof
if /i "%~1"=="-progress" (
    if not "%~2"=="" (
        >"%~2" echo out_time=00:00:30.000000
        >>"%~2" echo progress=continue
    )
    goto :eof
)
shift
goto :write_progress

:find_out
if "%~1"=="" goto :eof
rem Воркер дописывает `-progress <файл>` ПОСЛЕ выходного пути (script.ps1). Значение
rem после -progress — не выход: пропускаем оба токена, иначе мок писал бы в progress-файл,
rem а настоящий выход (out_tmp) не создавался бы (тогда rename в воркере не находил цель).
if /i "%~1"=="-progress" (shift & shift & goto :find_out)
if /i not "%~1"=="-y" set "OUT=%~1"
shift
goto :find_out
