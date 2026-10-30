The legacy export adapter is compiled into the iPhone app from MusicCloud/LegacyExportAdapter.swift.

Migration/ProductionTests exercises the production read-only startup migration: original export and sidecar bytes are archived, rich entries including missing/unavailable songs and duplicates are retained, current favorites/order are applied, and the app commits to a separate v3 state file. Original Documents data is not rewritten by migration.

The standalone adapter checks here test rich/unknown JSON fields and exact path projection. Run bash iphone/Migration/run-checks.sh and bash iphone/Migration/ProductionTests/run-checks.sh on macOS. Fixtures are synthetic. A successful test run is not a real-device signing, playback or Wi-Fi test.
