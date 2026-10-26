# DualScreenTV

Play your own games on Apple TV, with an optional iPad or Mac companion for the
second screen and touch input. The original, classic library is the public
interface. The experimental 3D interface is excluded from this release.

Supports Nintendo DS, experimental Nintendo 3DS, Game Boy, Game Boy Color,
Game Boy Advance and PSP. Compatibility and speed vary by game and Apple TV.
**No games, commercial BIOS files, firmware dumps, decryption keys, personal
libraries or saves are included.** Supply your own supported files that you
have permission to use. This project is not affiliated with the console makers.

## Before changing an existing installation

Keep your current installation and its identifiers if you already have games
and progress on a TV. A different bundle ID installs a separate app with an
empty library; it does not migrate the old app's data. Do not delete the old app
to make room for a new build.

**tvOS can reclaim local games and saves. Local history is not an off-device
backup.** Save in game, return to the library, and export important progress to
another device before changing signing, updating, or reinstalling. See the
backup steps below. Keep your original game files separately too.

## Download and build

This is a source release, not a pre-signed `.ipa`. Each user builds and signs
with their own Apple account. No developer certificate or account is supplied.

You need:

- A Mac with full Xcode and the tvOS and iOS platform SDKs installed. The release
  is checked with Xcode 27; its tests use Swift's default-isolation compiler flag.
- A physical Apple TV running tvOS 17 or later. Emulator libraries target ARM64
  devices, not the Apple TV Simulator.
- An optional iPad running iPadOS 16 or later, or a Mac for the companion.
- Git, Python 3, CMake, Ninja and Rust via rustup; internet access and several
  gigabytes of free disk space for emulator sources and build products.
- An Apple signing team that can provision App Groups for the full TV/Top Shelf
  configuration. Choose your own team in Xcode. Account capabilities differ;
  free Personal Team signing is not verified for this configuration. Apple
  documents its [account limits](https://developer.apple.com/help/account/basics/about-your-developer-account/).

1. On this GitHub repository, choose **Code → HTTPS** and copy the clone URL.
   In Terminal, type `git clone `, paste that URL, and press Return. Open the
   resulting directory with `cd`. Alternatively, use **Code → Download ZIP**,
   unzip it, and open Terminal in the extracted folder. No submodule checkout
   is required.
2. Launch Xcode once to install its components and accept its licence. In
   **Xcode → Settings → Locations**, select its Command Line Tools. Check:

   ```sh
   xcodebuild -version
   xcrun --sdk appletvos --show-sdk-path
   ```

3. Install the build tools. With [Homebrew](https://brew.sh/) already installed:

   ```sh
   brew install cmake ninja python rustup
   rustup toolchain install nightly-2025-12-18 --component rust-src
   ```

   If your rustup installer requests a shell/PATH setup, complete that before
   continuing. The pinned nightly toolchain and `rust-src` are used by Dust's
   tvOS standard-library build.
4. From the repository root, build the emulator libraries:

   ```sh
   bash Scripts/build-cores.sh
   ```

   This downloads pinned upstream sources, applies the included patches, and
   builds all seven libraries required by the Xcode project. Source/build
   caches stay under the ignored `build/` directory. Expect the first build to
   take time. Individual core scripts are in `Scripts/build-*-tvos.sh`.
   Keep the generated libraries local; they are deliberately excluded from Git.
5. Set a unique reverse-DNS identifier. Replace the example with one you control:

   ```sh
   python3 Scripts/configure-signing.py com.yourhandle.DualScreenTV
   open Apps/tvOS/DualScreenTV/DualScreenTV.xcodeproj
   ```

   The script keeps the TV, Top Shelf, companion and shared App Group identifiers
   consistent. Run it before configuring Xcode signing. Do not use somebody
   else's existing app identifiers.

## Sign and install on Apple TV

1. In **Xcode → Settings → Accounts**, add your Apple account.
2. Select the blue project in Xcode. For **DualScreenTV**,
   **DualScreenTVTopShelf**, and **DualScreenTVCompanion**, open
   **Signing & Capabilities**, enable **Automatically manage signing**, and
   choose your own team. Configure both Debug and Release if you use both.
3. For the TV and Top Shelf targets, enable the same App Group printed by the
   configuration script, for example `group.com.yourhandle.DualScreenTV`.
   Register it with your team through Xcode's App Groups capability. If Xcode
   reports a capability/account restriction, resolve that with your own team;
   the supplied template does not contain a usable provisioning profile.
4. Put Mac and Apple TV on the same network. On Apple TV, open
   **Settings → Remotes and Devices → Remote App and Devices**. On the Mac,
   open **Xcode → Window → Devices and Simulators**, select the TV and pair
   using the code shown on its screen. Enable Developer Mode if requested.
5. Choose the **DualScreenTV** scheme and your physical Apple TV as destination,
   then **Product → Run**. Xcode builds, signs and installs the app. A first
   installation opens with an empty classic library.

Apple's [signing workflow](https://help.apple.com/xcode/mac/current/en.lproj/dev60b6fbbc7.html),
[device installation steps](https://help.apple.com/xcode/mac/current/en.lproj/dev5a825a1ca.html)
and [App Groups setup](https://help.apple.com/xcode/mac/current/en.lproj/dev8dd3880fe.html)
explain account and provisioning configuration. Expired signing may require a
new build with the same identifiers; export saves first and keep the installed
app rather than uninstalling it as a troubleshooting step.

For the optional companion, select **DualScreenTVCompanion**, choose your iPad
or **My Mac (Mac Catalyst)**, and run it with your own signing team. Allow Local
Network access when asked. The companion's simulator can show its UI, but the
TV emulator libraries are device-only.

## Add games and play

1. Pair an extended Bluetooth controller in Apple TV Settings. A controller is
   recommended; the Siri Remote provides only a limited set of game buttons.
2. Open **Add/Edit Games** in the TV library. Scan its QR code or type the shown
   local address into a browser on the same network, then enter the TV's
   transfer code. You can also use the companion's **Games & Backups** tab.
3. Upload an unpacked supported game file. The app has no game downloader:

   | System | Files | Core |
   | --- | --- | --- |
   | Nintendo DS | `.nds` | melonDS; optional DeSmuME or Dust |
   | Nintendo 3DS | Decrypted `.3ds`, `.cci`, `.cxi`; `.3dsx` homebrew | Azahar (experimental) |
   | Game Boy / Color / Advance | `.gb`, `.gbc`, `.gba` | mGBA |
   | PSP | `.iso`, `.cso`, `.pbp` | PPSSPP |

   Encrypted 3DS files are not supported. ZIP archives must be unpacked first.
   Imported games can be renamed, favourited, and given your own artwork.
4. Select a game in the library and choose Play. **LB + RB + A** opens the
   game menu with default controller mappings. **LT + RT** switches the displayed
   DS screen by default. View or change mappings under **Controllers** or
   **Controller & Game Info**; console button labels differ between controllers.
5. For touch input and a second screen, open the companion's **Game Screen**
   tab, select the TV and enter its **iPad Companion** code. This is separate
   from the Add/Edit Games transfer code. Keep both devices on the same LAN.
6. Change display, graphics, speed and audio settings in the game menu or
   **Apple TV Settings → Apps → DualScreenTV**. Settings can be remembered per
   game. Higher internal resolution costs performance; lower it if play or
   audio stutters. Different DS cores keep separate saves.

Transfers use local, unencrypted HTTP with code pairing. Use a trusted local
network, keep the displayed codes private, and do not expose the service to the
internet. Game transfers and backups pause while emulation is running.

## Save, back up and restore

Use the game's own Save function for normal progress. After its save completes,
return to the library so the app can finish writing and make backups available.

- **Manual export:** Open **Add/Edit Games**, connect in the browser, and use
  **Save Explorer** or the save-backup controls. Select the correct game and
  core, download its saves/checkpoints, and retain the files on another device.
  Native 3DS and PSP saves may consist of multiple files; export every required
  file. A single file is not necessarily a complete game backup.
- **Automatic companion copies:** Open **Save Backups** on the Mac/iPad
  companion, select the TV, enter its current **Add/Edit Games** code, and choose
  **Pair for automatic backups**. Wait for a verified successful backup; pairing
  alone does not mean your saves were copied. Use **Back up now** to check.
  The companion must remain running (foreground on iPad; awake on Mac), and the
  TV must be in its library. Up to five versions are retained per save set/slot.
  Use **Export** to retain portable `.dstvbackup` files outside the companion.
- **Restore:** Import the exact original game on TV first. In the companion's
  Save Backups, choose the correct game/core/version and Restore, then confirm
  with the current Add/Edit Games code. Restoring replaces that save's data.
  For raw file imports in Save Explorer, play and save once with the chosen
  core to create a destination before importing a compatible save.
- **Save states:** Supported by the current melonDS, mGBA and PPSSPP integrations.
  Azahar, Dust and scaled DeSmuME use in-game saves. States depend on the exact
  core build; rebuilding cores can make old states incompatible. Keep ordinary
  in-game saves as well.

Local history and same-TV recovery copies can disappear with cache reclamation
or app deletion. Automatic copies cover only data successfully copied off the
TV; they do not include games or artwork. Keep original ROMs and exported saves
in your own backup system.

## Troubleshooting and checks

- **Missing library at build:** Complete `Scripts/build-cores.sh` first. Check
  that all seven `.dylib` files exist in `Apps/tvOS/DualScreenTV/Frameworks`.
- **Signing/App Group error:** Check your own unique identifiers, team on every
  target, and matching TV/Top Shelf group. Never import another developer's keys.
- **No TV discovered:** Check Local Network permission and that devices share
  a LAN without guest/client isolation. Use the shown transfer address manually.
- **Game missing after storage cleanup:** Re-import the identical original file;
  restore an off-device backup if the saves were also removed. Changing the
  filename does not change identity; different ROM contents do.
- **Poor performance:** Return to native/low resolution and default speed.
  3DS support and alternate DS renderers remain experimental.

Host checks, without connecting to or installing on any TV:

```sh
bash Tests/run-host-tests.sh
python3 Scripts/audit-distribution.py
```

## Licence and credits

Original DualScreenTV code is available under the [MIT licence](LICENSE).
Third-party code, upstream-derived patches and resources retain their own
licences; MIT does not replace those terms. See [THIRD_PARTY.md](THIRD_PARTY.md).

Created by **Aedan Pilkington**.

Thanks to the melonDS/melonDS DS, DeSmuME, Dust, Azahar, mGBA, PPSSPP,
libretro, MoltenVK and other upstream contributors. Source pins, patches and
licences are described in [THIRD_PARTY.md](THIRD_PARTY.md). Third-party copyright
notices and author credits are retained with their code and assets.
