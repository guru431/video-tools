# tools/

## check_release.ps1

Release-хелпер: прогон тестов → сборка обоих EXE → генерация `release-manifest.json`
(провенанс: source commit, `BuildVersion`, ps2exe commit/SHA, SHA256 каждого артефакта) →
сверка `.sha256` sidecar'ов. `-ManifestOnly` — только (пере)генерация манифеста,
`-SkipTests` — без тестов.

## _build_common.ps1

Единый источник пинов сборки: `$script:Ps2ExeSha`, `$script:Ps2ExeCommit`,
`$script:BuildVersion`. Dot-source'ится из обоих `build_exe.ps1` и из `check_release.ps1`.

## ps2exe.ps1

Vendored copy of [MScholtes/PS2EXE](https://github.com/MScholtes/PS2EXE) (MIT License) —
used by `ffmpeg/build_exe.ps1` and `yt-dlp/build_exe.ps1` to compile the PS1 GUIs into EXEs.

- **Source:** `https://raw.githubusercontent.com/MScholtes/PS2EXE/<commit>/Module/ps2exe.ps1`
- **Pinned commit:** `d32d5ce21c458696e860a7533943b1466d925be9` (2025-08-21)
- **SHA256:** `FAEA495151AF69D2AE78783D0071186F98DC568D7B7478F639DA0E74ECF01763`

The build scripts verify this SHA256 before dot-sourcing the file. It is vendored (not
downloaded at build time) to avoid executing a moving remote `master` script — a supply-chain
risk for a public repo.

The pinned SHA256 and `BuildVersion` live once in [`tools/_build_common.ps1`](_build_common.ps1)
(`$script:Ps2ExeSha` / `$script:BuildVersion`); `ffmpeg/build_exe.ps1` and `yt-dlp/build_exe.ps1`
dot-source it, so there is a single source of truth (no per-file `$ps2exeSha` to keep in sync).

### Updating

1. Download the new version from a specific commit/tag (not `master`).
2. Review the diff.
3. Update the pinned commit + SHA256 here **and** in `tools/_build_common.ps1` (`$script:Ps2ExeSha`).
