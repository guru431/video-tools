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
- **Upstream base commit:** `d32d5ce21c458696e860a7533943b1466d925be9` (2025-08-21)
- **SHA256 (vendored, patched artifact):** `45FDF8446FF7DE578B003FD62015B2CDFCE9EC56840249186396A26DCF856311`

The vendored file is the upstream base commit **plus a local patch** (escaping quotes in the
generated assembly metadata) — so its SHA256 does **not** match the raw upstream file; the hash
above is of the patched artifact actually shipped in this repo, while the commit identifies the
upstream base it was derived from.

The build scripts verify this SHA256 before dot-sourcing the file. It is vendored (not
downloaded at build time) to avoid executing a moving remote `master` script — a supply-chain
risk for a public repo.

The single source of truth for the pinned SHA256/commit and `BuildVersion` is
[`tools/_build_common.ps1`](_build_common.ps1) (`$script:Ps2ExeSha` / `$script:Ps2ExeCommit` /
`$script:BuildVersion`); `ffmpeg/build_exe.ps1`, `yt-dlp/build_exe.ps1` and `check_release.ps1`
dot-source it. The values quoted here **mirror** that file for documentation — keep them in sync.

### Updating

1. Download the new version from a specific commit/tag (not `master`).
2. Review the diff; re-apply the local metadata-quote patch if still needed.
3. Update the pin in `tools/_build_common.ps1` (`$script:Ps2ExeSha` / `$script:Ps2ExeCommit`) —
   the canonical source — then refresh the mirrored values in this README.
