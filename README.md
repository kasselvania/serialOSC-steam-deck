This is a build of SerialOSC and an install script for use of monome devices natively on the Steam Deck.

Any monome device should be discoverable when plugged in if this package works correctly.

Also included is a monome device built for use in PlugData, which can run as a CLAP or VST3 plugin in Bitwig (installed via Flatpak on SteamOS).

**How to Use It (for yourself later, or someone else):**

1.  Copy `monome_serialosc_steamdeck_installer.tar.gz` to the target Steam Deck (e.g., into `~/Downloads`).
2.  Open Konsole, navigate to where the file is: `cd ~/Downloads`
3.  Extract it: `tar -xzf monome_serialosc_steamdeck_installer.tar.gz`
4.  Navigate into the extracted folder: `cd monome_setup_package`
5.  Run the setup script: `./setup.sh`
6.  Enter the `sudo` password when prompted.
7.  Follow any final instructions (like logging out/rebooting if added to the `uucp` group).

Congratulations, you've installed your setup!
