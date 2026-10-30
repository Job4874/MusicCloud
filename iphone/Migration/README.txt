Read-only migration groundwork; not connected to app startup or restore.

The original export bytes are retained unchanged. Ordered projections keep missing/unavailable entries, source metadata and unknown JSON fields. Exact relative paths are checked against an inventory; filenames are never guessed.

Run bash iphone/Migration/run-checks.sh to compile and execute synthetic checks on macOS. These checks do not validate a current phone library, implement a migration, or authorize replacing the installed app.
