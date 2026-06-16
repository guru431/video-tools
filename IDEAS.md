# Ideas — video
Предложения фич от project-analysis. Статусы: proposed | accepted | rejected | done.

## 2026-06-15 · audio_only mode hardcodes mp3/libmp3lame, ignores [audio] codec/bitrate/sampling_rate, and e...
**Боль:** User picks 'audio only' expecting their configured AAC/m4a (or any non-mp3) audio and bitrate, but always gets a re-encoded mp3 at libmp3lame defaults — wrong format for Apple/podcast workflows with no override.
**Предложение:** In the audio_only branch honor the existing `[audio] codec` (aac->.m4a, libmp3lame->.mp3) and keep applying set_audio_bitrate/set_audio_sampling_rate (audio_settings is currently unused here); pick the extension from the codec. Also gate the video-bitrate computation with `[ "$audio_only" != yes ]` (or clear set_video_bitrate_final) so no -b:v is emitted. Apply to all three platforms for parity.
**Что:** All three platforms force `format_files_out=mp3` and `set_audio_codec=-c:a libmp3lame` whenever audio_only=yes, overriding the user's `[audio] codec = +aac` (and bitrate / sampling_rate). A user setting codec=+aac with audio_only=yes (the obvious 'extract clean AAC/m4a' intent) silently gets mp3; there is no way to extract to m4a/aac/opus/flac except extract_audio_copy (which only copies, cannot transcode). Additionally (SH) set_video_bitrate_final is still computed when video_bitrate is enabled, so convert_settings becomes '-vn -b:v 3000k ...' — a stray/contradictory -b:v alongside -vn (harmless but produces confusing ffmpeg warnings).
**Контекст:** project-analysis r2 · ffmpeg/FFmpeg_Converter_script.sh · ffmpeg/FFmpeg_Converter_script.sh:128-131 (codec/container force) and :391-398 (ungated video-bitrate). Parity: FFmpeg_Converter_script.ps1:137-140 & :411-418; FFmpeg_Converter_script.cmd:137-140 & :362-375. Convert assembly: sh:404, ps1:426, cmd:380. · platforms=sh/cmd/ps1 · conf=0.55 · id=F06
**Статус:** proposed

## 2026-06-15 · Batch (channels.txt) download is SH-only; CMD and PS1 have no equivalent
**Боль:** The SH script has a full `--batch` mode reading channels.txt (`category|handle|mode` lines), applying per-channel sleep/archive/date-range settings and downloading each channel's videos/playlists. Neither the CMD nor PS1 script has any batch path. README.md line 87 advertises 'Batch: загрузка канало
**Предложение:** Either (a) document in README that batch is SH-only, or (b) add a batch entry point to the PS1 GUI (it already has a URL queue — feed channel URLs https://www.youtube.com/@handle/videos plus --dateafter/--sleep-* through the existing download loop). Pick one explicitly.
**Что:** The SH script has a full `--batch` mode reading channels.txt (`category|handle|mode` lines), applying per-channel sleep/archive/date-range settings and downloading each channel's videos/playlists. Neither the CMD nor PS1 script has any batch path. README.md line 87 advertises 'Batch: загрузка каналов из channels.txt' without noting it is Linux/Git-Bash only, so Windows GUI/CMD users cannot reach it — violating the 'all 3 platforms produce identical behavior' invariant for a headline feature.
**Контекст:** project-analysis r2 · yt-dlp/Downloading_from_YouTube_v14.cmd · yt-dlp/Downloading_from_YouTube_v14.sh:476-570 (download_batch); CMD/PS1 have no equivalent; README.md:87; config.ini.example:44-51 [batch] · platforms=cmd/ps1 · conf=0.78 · id=F32
**Статус:** proposed

## 2026-06-15 · No channels.txt or channels.txt.example ships, and the line format is undocumented
**Боль:** A user following the README's batch feature hits an immediate hard error with no example to copy, and must reverse-engineer the pipe-delimited format from the source.
**Предложение:** Ship yt-dlp/channels.txt.example with 2-3 commented sample lines documenting `category|handle|mode` (e.g. `# music|SomeChannelHandle|videos`) and a header comment, mirroring config.ini.example; add it to README.
**Что:** `--batch` requires ${SCRIPT_DIR}/channels.txt but neither channels.txt nor channels.txt.example exists in the repo. On first --batch run the script errors and exits 1. The expected `category|handle|mode` syntax (mode = videos/playlists) is only discoverable from the parser; there is no template, unlike config.ini.example.
**Контекст:** project-analysis r2 · yt-dlp/Downloading_from_YouTube_v14.sh · yt-dlp/Downloading_from_YouTube_v14.sh:26 (CHANNELS_FILE) and :479-482 (hard exit 1 if missing) · platforms=sh · conf=0.78 · id=F33
**Статус:** proposed

## 2026-06-15 · 'Audio only' downloads raw opus/m4a stream — no MP3/extraction option in any platform
**Боль:** 'Audio only' gives an unplayable opus/m4a stream instead of a portable MP3; the user must manually re-run ffmpeg afterward.
**Предложение:** Add an `[download] audio_format = mp3|m4a|opus|best` (default best=current). When set to a transcoding target and audio-only quality is chosen, append `--extract-audio --audio-format <fmt> --audio-quality 0` (uses the bundled ffmpeg). Surface as a GUI dropdown next to 'audio' and a CMD sub-prompt; wire into all three platforms.
**Что:** Selecting the 'audio' quality (CMD option 0, GUI 'audio', SH --quality audio) only sets a `-f bestaudio...` selector; yt-dlp saves whatever container YouTube serves (typically webm/opus or m4a) with no `--extract-audio`/`-x --audio-format mp3`. A user wanting 'just give me an mp3' gets an .opus/.m4a they often cannot play, and there is no config knob for mp3/m4a extraction in any of the three platforms.
**Контекст:** project-analysis r2 · yt-dlp/Downloading_from_YouTube_v14.sh · yt-dlp/Downloading_from_YouTube_v14.sh:207 (auto bestaudio/best) and :224 (avc1_best bestaudio[ext!=webm]/bestaudio); PS1 Downloading_from_YouTube_v14.ps1:92 qualityMap audio=0 and :794/:918 bestaudio selectors; config.ini has no audio_format key · platforms=sh/cmd/ps1 · conf=0.55 · id=F34
**Статус:** proposed

## 2026-06-15 · No SponsorBlock support — sponsor/intro/outro segments cannot be skipped or removed
**Боль:** Users must manually scrub sponsor/intro segments after every download; the tool offers no auto-skip despite yt-dlp supporting it out of the box.
**Предложение:** Add a `[download] sponsorblock = off|mark|remove` key (default off). `remove` -> append `--sponsorblock-remove all`; `mark` -> `--sponsorblock-mark all` (embeds chapters). Add a GUI checkbox/combo and a CMD prompt; wire into all three command arrays and document the categories override.
**Что:** A common power-user wish is removing sponsor/self-promo/intro segments. yt-dlp ships `--sponsorblock-remove`/`--sponsorblock-mark` natively, but the tool exposes no config key, CLI flag, or GUI control in any platform. The tool already bundles ffmpeg (needed by SponsorBlock-remove for cutting), making this a near-free high-value add.
**Контекст:** project-analysis r2 · yt-dlp/config.ini.example · C:\AI\projects\video\yt-dlp\config.ini.example:25 ([download] section — no sponsorblock key); builder gap at C:\AI\projects\video\yt-dlp\Downloading_from_YouTube_v14.sh:323-371 (cmd array, no --sponsorblock-* flag) · platforms=sh/cmd/ps1 · conf=0.62 · id=F35
**Статус:** proposed

## 2026-06-15 · Subtitles can only be downloaded standalone (--skip-download); cannot be embedded or saved a...
**Боль:** Getting a video with embedded/selectable subtitles requires two separate runs plus a manual ffmpeg mux; the tool cannot produce one self-contained subtitled file.
**Предложение:** Add a `[subtitles] download_with_video = off|sidecar|embed` key (default off). `sidecar` -> add `--write-subs --write-auto-subs --sub-langs <lang>` to the normal download (no --skip-download); `embed` -> additionally `--embed-subs --merge-output-format mkv` (or mp4 with mov_text). Add a GUI checkbox and CMD prompt; wire into all three platforms.
**Что:** The only subtitle path is the 'subs only' mode which always passes `--skip-download`. There is no way to download a video AND its subtitles together, and no way to embed subs into mp4/mkv. A user wanting a single playable file with selectable subtitles must run the tool twice then manually mux. The downloader already merges streams via ffmpeg, so `--embed-subs`/`--write-subs` would slot in naturally.
**Контекст:** project-analysis r2 · yt-dlp/Downloading_from_YouTube_v14.sh · yt-dlp/Downloading_from_YouTube_v14.sh:353-354 · platforms=sh/cmd/ps1 · conf=0.62 · id=F36
**Статус:** proposed

## 2026-06-09 · Поддержка env-переменных в config.ini для credentials. Сейча...
**Боль:** INTENT явно требует: «публичный репозиторий — не допускать утечек, секреты только через env-переменные». Credentials в config.ini — прямой путь к утечке при каждом коммите.
**Предложение:** Добавить синтаксис подстановки ${ENV_VAR} в read_config всех трёх платформ: если значение содержит ${...}, подставлять из окружения. Пример: url = ${PROXY_URL} вместо url = https://user:pass@host:port. Реализовать в SH (read_config), CMD (:assign_var), PS1 (Read-Config) с паритетом.
**Что:** Поддержка env-переменных в config.ini для credentials. Сейчас proxy URL с логином/паролем хранится в config.ini в открытом виде — при коммите в публичный репозиторий это прямая утечка. Формат +value/-value не позволяет отделить секреты от конфигурации.
**Статус:** done
**Resolved:** 2026-06-11 — Task 13: подстановка `${ENV_VAR}` реализована в SH (`read_config`) и PS1 (`Read-Config`); не заданная переменная → пустая строка + WARN; несколько вхождений. CMD yt-dlp интерактивный (без config.ini) — неприменимо. Документировано в `config.ini.example`, покрыто тестами в test_01.
