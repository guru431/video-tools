@echo off
rem Bootstrap local protection for this PUBLIC repo after a fresh clone (Windows):
rem   1) activate the pre-commit secret guard (core.hooksPath)
rem   2) seed the local .sanitize-patterns denylist from the tracked example
rem Safe to re-run (idempotent).
cd /d "%~dp0.."

echo ==^> git config core.hooksPath .githooks
git config core.hooksPath .githooks

if not exist ".sanitize-patterns" (
    echo ==^> creating .sanitize-patterns from .sanitize-patterns.example
    echo     Edit it and add your REAL private values ^(file is gitignored^).
    copy /y ".sanitize-patterns.example" ".sanitize-patterns" >nul
) else (
    echo ==^> .sanitize-patterns already present
)

echo ==^> done. Commits now run through .githooks/pre-commit.
