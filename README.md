# Snake Express

Play the browser version by opening `index.html` in a modern browser. No installation or build is required.

Choose up to four players in the lobby: one keyboard player, gamepad players, or bots. Steer with WASD or the arrow keys, a connected gamepad's D-pad, or the on-screen D-pad on a phone or tablet. Gamepads are assigned to gamepad slots in connection order; use the D-pad and A to navigate, and press Start to begin from the lobby. Touch controls steer the keyboard player. Human wins and color unlocks are saved in the browser's local storage.

The browser game includes Survival, First To, Classic 1P, and Rush, along with food and the six power-ups from the PowerShell game. Classic 1P requires exactly one active player.

To install on iPhone or iPad, host the files over HTTPS, open the site in Safari, tap Share, then **Add to Home Screen**. Launch it from the home screen for a standalone app experience. After the first online visit, the installed game can also run offline. Offline installation requires HTTPS (or localhost for development); opening `index.html` directly still works but does not enable the service worker.