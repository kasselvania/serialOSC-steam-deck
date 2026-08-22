# Legacy package — do not install

`monome_setup_package-v1.4.5-broken.zip` is retained only as historical evidence.

Its archive contains an old SerialOSC 1.4.5 `serialoscd` binary but omits the required `serialosc-detector` and `serialosc-device` helpers. Its setup script also disables SteamOS read-only mode, performs host package operations, writes to `/usr/local` and `/etc`, and installs an incorrect per-device service model.

The archive must not be executed or presented as a working installer.
