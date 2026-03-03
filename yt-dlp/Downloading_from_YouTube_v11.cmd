@echo off
chcp 65001 >nul 2>&1
setlocal EnableDelayedExpansion

:: ============================================================================
:: download.cmd — Интерактивный загрузчик YouTube видео (Windows)
:: Поддержка: выбор качества, cookies, прокси, AI-перевод аудиодорожки
:: ============================================================================

set "folder=_video_"
set "dlp=yt-dlp"
set "proxy="
set "cookie_arg="
set "translate_arg="

echo.
echo =========================================
echo    YouTube Downloader (Windows CLI)
echo =========================================
echo.

:: ── URL ──────────────────────────────────────────────────────────────────
set /p "url=URL видео/плейлиста: "
if "%url%"=="" (
    color 04
    echo.
    echo ОШИБКА: URL обязателен!
    echo.
    pause
    exit /b 1
)

:: ── Качество ─────────────────────────────────────────────────────────────
echo.
echo Качество (по умолчанию: 3):
echo   0  - Только аудио
echo   1  - Низкое (360p)
echo   2  - Среднее (480p)
echo   3  - Высокое (720p)
echo   4  - Очень высокое (1080p)
echo   5  - 2K (1440p)
echo   6  - 4K (2160p)
echo   91 - Только субтитры (RU)
echo   92 - Только субтитры (EN)
echo.
set /p "quality=Выберите номер: "
if "%quality%"=="" set quality=3

:: ── Cookies ──────────────────────────────────────────────────────────────
echo.
echo Cookies (по умолчанию: 0):
echo   0 - Без cookies
echo   1 - Из браузера (Chrome)
echo   2 - Из браузера (Firefox)
echo   3 - Из браузера (Edge)
echo   4 - Из файла
echo.
set /p "cookie_choice=Выберите номер: "
if "%cookie_choice%"=="" set cookie_choice=0

if %cookie_choice%==1 set "cookie_arg=--cookies-from-browser chrome"
if %cookie_choice%==2 set "cookie_arg=--cookies-from-browser firefox"
if %cookie_choice%==3 set "cookie_arg=--cookies-from-browser edge"
if %cookie_choice%==4 (
    set /p "cookie_path=Путь к файлу cookies: "
    if not "!cookie_path!"=="" (
        if exist "!cookie_path!" (
            set "cookie_arg=--cookies "!cookie_path!""
        ) else (
            echo ПРЕДУПРЕЖДЕНИЕ: файл не найден, продолжаю без cookies
            set "cookie_arg="
        )
    )
)

:: ── Прокси ───────────────────────────────────────────────────────────────
echo.
set /p "proxy=Прокси (Enter для пропуска): "

:: ── AI-перевод ───────────────────────────────────────────────────────────
echo.
echo AI-перевод аудио (по умолчанию: 0):
echo   0 - Без перевода
echo   1 - Перевод RU (2 дорожки)
echo   2 - Перевод RU (смешанный)
echo   3 - Перевод RU (заменить оригинал)
echo   4 - Перевод EN (2 дорожки)
echo.
set /p "translate_choice=Выберите номер: "
if "%translate_choice%"=="" set translate_choice=0

set "translate_lang="
set "translate_mode="
if %translate_choice%==1 (set "translate_lang=ru" & set "translate_mode=dual_track")
if %translate_choice%==2 (set "translate_lang=ru" & set "translate_mode=mix")
if %translate_choice%==3 (set "translate_lang=ru" & set "translate_mode=replace")
if %translate_choice%==4 (set "translate_lang=en" & set "translate_mode=dual_track")

:: ── Пресет формата ───────────────────────────────────────────────────────
echo.
echo Формат (по умолчанию: 0):
echo   0  - avc1_best (авто лучший AVC1)
echo   1  - avc1_https (HTTPS, 30fps)
echo   2  - avc1_m3u8 (HLS, 30fps)
echo   3  - avc1_https_60fps (HTTPS, 60fps)
echo   4  - avc1_m3u8_60fps (HLS, 60fps)
echo   5  - avc1_https_60fps_hdr (HTTPS, 60fps, HDR)
echo   6  - old_combo (классические ID)
echo.
set /p "fmt=Выберите номер: "
if "%fmt%"=="" set fmt=0

:: ── Формат + Качество ───────────────────────────────────────────────────
set "save_settings="

:: Субтитры — не зависят от пресета
if %quality%==91 (
    set "save_settings=--sub-lang ru --write-auto-sub --sub-format vtt --skip-download"
    goto :format_done
)
if %quality%==92 (
    set "save_settings=--sub-lang en --write-auto-sub --sub-format vtt --skip-download"
    goto :format_done
)

:: avc1_best (по умолчанию)
:: Примечание: избегаем ext!=webm — символ ! съедается delayed expansion.
:: Используем ext=m4a с fallback на bestaudio (эквивалентно для YouTube).
if %fmt%==0 (
    if %quality%==0 set "save_settings=-f bestaudio[ext=m4a]/bestaudio"
    if %quality%==1 set "save_settings=-f "bestaudio[ext=m4a]+bestvideo[height<=360][vcodec^=avc1]/bestaudio+bestvideo[height<=360][vcodec^=avc1]""
    if %quality%==2 set "save_settings=-f "bestaudio[ext=m4a]+bestvideo[height<=480][vcodec^=avc1]/bestaudio+bestvideo[height<=480][vcodec^=avc1]""
    if %quality%==3 set "save_settings=-f "bestaudio[ext=m4a]+bestvideo[height<=720][vcodec^=avc1]/bestaudio+bestvideo[height<=720][vcodec^=avc1]""
    if %quality%==4 set "save_settings=-f "bestaudio[ext=m4a]+bestvideo[height<=1080][vcodec^=avc1]/bestaudio+bestvideo[height<=1080][vcodec^=avc1]""
    if %quality%==5 set "save_settings=-f "bestaudio[ext=m4a]+bestvideo[height<=1440][vcodec^=avc1]/bestaudio+bestvideo[height<=1440][vcodec^=avc1]""
    if %quality%==6 set "save_settings=-f "bestaudio[ext=m4a]+bestvideo[height<=2160][vcodec^=avc1]/bestaudio+bestvideo[height<=2160][vcodec^=avc1]""
)
:: avc1_https
if %fmt%==1 (
    if %quality%==0 set "save_settings=-f 140"
    if %quality%==1 set "save_settings=-f 140+134"
    if %quality%==2 set "save_settings=-f 140+135/134"
    if %quality%==3 set "save_settings=-f 140+136/135/134"
    if %quality%==4 set "save_settings=-f 140+137/136/135/134"
    if %quality%==5 set "save_settings=-f 140+138/137/136/135/134"
    if %quality%==6 set "save_settings=-f 140+139/138/137/136/135/134"
)
:: avc1_m3u8
if %fmt%==2 (
    if %quality%==0 set "save_settings=-f 234"
    if %quality%==1 set "save_settings=-f 234+230"
    if %quality%==2 set "save_settings=-f 234+231/230"
    if %quality%==3 set "save_settings=-f 234+232/231/230"
    if %quality%==4 set "save_settings=-f 234+233/232/231/230"
    if %quality%==5 set "save_settings=-f 234+234/233/232/231/230"
    if %quality%==6 set "save_settings=-f 234+235/234/233/232/231/230"
)
:: avc1_https_60fps
if %fmt%==3 (
    if %quality%==0 set "save_settings=-f 234"
    if %quality%==1 set "save_settings=-f 234+296"
    if %quality%==2 set "save_settings=-f 234+297/296"
    if %quality%==3 set "save_settings=-f 234+298/297/296"
    if %quality%==4 set "save_settings=-f 234+299/298/297/296"
    if %quality%==5 set "save_settings=-f 234+300/299/298/297/296"
    if %quality%==6 set "save_settings=-f 234+301/300/299/298/297/296"
)
:: avc1_m3u8_60fps
if %fmt%==4 (
    if %quality%==0 set "save_settings=-f 234"
    if %quality%==1 set "save_settings=-f 234+309"
    if %quality%==2 set "save_settings=-f 234+310/309"
    if %quality%==3 set "save_settings=-f 234+311/310/309"
    if %quality%==4 set "save_settings=-f 234+312/311/310/309"
    if %quality%==5 set "save_settings=-f 234+313/312/311/310/309"
    if %quality%==6 set "save_settings=-f 234+314/313/312/311/310/309"
)
:: avc1_https_60fps_hdr
if %fmt%==5 (
    if %quality%==0 set "save_settings=-f 234"
    if %quality%==1 set "save_settings=-f 234+696"
    if %quality%==2 set "save_settings=-f 234+697/696"
    if %quality%==3 set "save_settings=-f 234+698/697/696"
    if %quality%==4 set "save_settings=-f 234+699/698/697/696"
    if %quality%==5 set "save_settings=-f 234+700/699/698/697/696"
    if %quality%==6 set "save_settings=-f 234+701/700/699/698/697/696"
)
:: old_combo
if %fmt%==6 (
    if %quality%==0 set "save_settings=-f 140"
    if %quality%==1 set "save_settings=-f 18"
    if %quality%==2 set "save_settings=-f 20/18"
    if %quality%==3 set "save_settings=-f 22/20/18"
    if %quality%==4 set "save_settings=-f 24/22/20/18"
    if %quality%==5 set "save_settings=-f 26/24/22/20/18"
    if %quality%==6 set "save_settings=-f 28/26/24/22/20/18"
)
:format_done

:: ── Шаблон пути ──────────────────────────────────────────────────────────
set "subfolder=%%(uploader)s"
echo "%url%" | findstr /C:"playlist" >nul && set "subfolder=%%(uploader)s\%%(playlist)s"

:: ── Прокси-аргумент ──────────────────────────────────────────────────────
set "proxy_arg="
if not "%proxy%"=="" set "proxy_arg=--proxy %proxy%"

:: ── Получение названия видео ─────────────────────────────────────────────
echo.
echo ─────────────────────────────────────────
echo Получение информации о видео...
%dlp% --no-check-certificate %proxy_arg% %cookie_arg% --get-title "%url%" 2>nul
echo ─────────────────────────────────────────
echo.

:: ── Запуск загрузки ──────────────────────────────────────────────────────
echo Начало загрузки...
echo.

set "deno_arg="
if exist "%~dp0deno.exe" set "deno_arg=--js-runtimes deno:%~dp0deno.exe"

%dlp% --no-check-certificate %proxy_arg% %cookie_arg% %deno_arg% -c -i -w --windows-filenames --compat-options filename-sanitization -o "%folder%\%subfolder%\%%(title)s.%%(ext)s" %save_settings% "%url%"

set "dl_errorlevel=%errorlevel%"
if %dl_errorlevel%==0 (
    set "final_message=Загрузка завершена успешно!"
    set "col=02"
) else (
    set "final_message=Ошибка при загрузке!"
    set "col=04"
)

:: ── AI-перевод (если выбран) ─────────────────────────────────────────────
if not "%translate_lang%"=="" (
    if %dl_errorlevel%==0 (
        echo.
        echo ─────────────────────────────────────────
        echo Получение AI-перевода ^(%translate_lang%^)...
        echo ─────────────────────────────────────────

        :: Проверка зависимостей — ищем vot-cli-live рядом со скриптом, потом в PATH
        set "vot_cmd=vot-cli-live"
        if exist "%~dp0vot-cli-live.exe" (
            set "vot_cmd=%~dp0vot-cli-live.exe"
        ) else (
            where vot-cli-live >nul 2>&1
            if errorlevel 1 (
                echo ОШИБКА: vot-cli-live не найден
                echo Положите vot-cli-live.exe рядом со скриптом или установите: npm install -g vot-cli-live
                goto :skip_translate
            )
        )
        where ffmpeg >nul 2>&1
        if errorlevel 1 (
            echo ОШИБКА: ffmpeg не найден
            echo Установите: https://ffmpeg.org/download.html
            goto :skip_translate
        )

        :: Скачать перевод
        set "temp_dir=%TEMP%\yt-dlp-translate"
        mkdir "!temp_dir!" 2>nul
        set "NODE_TLS_REJECT_UNAUTHORIZED=0"
        "!vot_cmd!" --output="!temp_dir!" --voice-style=live --reslang=%translate_lang% "%url%"
        set "NODE_TLS_REJECT_UNAUTHORIZED="

        if errorlevel 1 (
            echo ПРЕДУПРЕЖДЕНИЕ: не удалось получить перевод
            goto :skip_translate
        )

        :: Найти скачанный mp3 и последний mp4
        for %%f in ("!temp_dir!\*.mp3") do set "trans_file=%%f"
        for /r "%folder%" %%f in (*.mp4) do set "video_file=%%f"

        if defined trans_file if defined video_file (
            echo Объединение аудиодорожек ^(режим: %translate_mode%^)...
            set "output_file=!video_file:.mp4=_translated.mp4!"

            if "%translate_mode%"=="dual_track" (
                ffmpeg -y -i "!video_file!" -i "!trans_file!" -map 0:v -map 0:a -map 1:a -c:v copy -c:a:0 copy -c:a:1 aac -b:a:1 192k -metadata:s:a:0 language=eng -metadata:s:a:0 title="Original" -metadata:s:a:1 language=%translate_lang% -metadata:s:a:1 title="AI Translation" -disposition:a:0 default "!output_file!" 2>nul
            )
            if "%translate_mode%"=="replace" (
                ffmpeg -y -i "!video_file!" -i "!trans_file!" -map 0:v -map 1:a -c:v copy -c:a aac -b:a 192k -metadata:s:a:0 language=%translate_lang% -metadata:s:a:0 title="AI Translation" "!output_file!" 2>nul
            )
            if "%translate_mode%"=="mix" (
                ffmpeg -y -i "!video_file!" -i "!trans_file!" -filter_complex "[0:a]volume=0.3[a0];[1:a]volume=1.0[a1];[a0][a1]amix=inputs=2:duration=longest[aout]" -map 0:v -map "[aout]" -c:v copy -c:a aac -b:a 192k "!output_file!" 2>nul
            )

            if exist "!output_file!" (
                move /y "!output_file!" "!video_file!" >nul
                echo Перевод добавлен успешно!
            ) else (
                echo ОШИБКА: не удалось объединить аудиодорожки
            )
        )

        :: Очистка
        rmdir /s /q "!temp_dir!" 2>nul
    )
)
:skip_translate

:: ── Результат ────────────────────────────────────────────────────────────
echo.
echo =========================================
color %col%
echo   %final_message%
echo =========================================
echo.
pause
