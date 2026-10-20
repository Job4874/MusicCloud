MusicCloud portable runtime

Node.js v22.23.2, Windows x64. No installation or npm packages are needed.
This executable and the complete adjacent LICENSE were copied together from
the installed Node.js v22.23.2 distribution on the build computer. SHA-256
hashes were verified to match the source files after copying.

Node.js and its bundled components retain their own copyright notices and
licenses. The complete official distribution license is in runtime/LICENSE.

Double-click START-MUSICCLOUD.cmd in the parent folder. The launcher starts
the local server hidden, waits until it is ready, then opens your browser.
Use STOP-MUSICCLOUD.cmd to stop only the server started by this copy.
There is no scheduled task, service registration or automatic Windows startup.

Logs and persistent music data are in desktop/data by default. A random
shutdown token in desktop/data/.musiccloud-server.json only controls that
specific launched instance. No process is force-killed by the stop command.

For a visible development server, run from the MusicCloud folder:
  runtime\node.exe desktop\server.mjs
Then open http://127.0.0.1:4783 and press Ctrl+C in the terminal to stop it.

For all automated tests, run from the MusicCloud folder:
  runtime\node.exe --test desktop\tests\server.test.mjs desktop\tests\launcher.test.mjs

Optional environment variables: PORT, MUSICCLOUD_DATA_DIR (or DATA_DIR),
and MUSICCLOUD_NO_BROWSER=1 to test the launcher without opening a browser.

Official Node.js project: https://nodejs.org/
