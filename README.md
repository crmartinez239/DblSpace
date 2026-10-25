# DblSpace

Double-tap the Space bar to type a period, like on a Mac or phone.

Type `Hello` and tap Space twice quickly, and you get `Hello. ` ready for the next sentence. It works in any Windows app and with any keyboard layout.

Website: https://crmartinez239.github.io/DblSpace/

## Install

Download `DblSpace-Setup-<version>.exe` from the [latest release](https://github.com/crmartinez239/DblSpace/releases/latest) and run it. It installs for your user account only, so it doesn't need admin rights. Windows 10 or 11 (64-bit) is required.

Windows may show a "Windows protected your PC" warning because the installer isn't code-signed. Click **More info → Run anyway**.

## Use

DblSpace runs in the system tray (the area near the clock). The icon is blue when it's on and gray when it's off. Click the icon for **Settings** and **Exit**.

In Settings you can:

- Turn it on or off, and choose whether it starts with Windows.
- Change how quickly the two taps must happen (150 ms to 1 second).
- Choose where it works: in every app except the ones you list, or only in the apps you list.
- Skip code editors, terminals, and fullscreen apps and games. All three are skipped by default.

It never types a period in password fields or in apps running as administrator.

Uninstall it from **Settings → Apps** in Windows. This removes the app and all of its settings.

## Your keystrokes and privacy

To know when you've double-tapped Space, DblSpace has to see each key you press. Here is exactly what it does with them:

- **It doesn't record what you type.** For each key it keeps only a category (letter or digit, space, closing bracket or quote, or something else) for the last few keys. That's enough to tell whether a double space follows a word.
- **It saves nothing about your typing.** Nothing goes to disk except your settings, which are stored in the Windows registry under `HKEY_CURRENT_USER\Software\DblSpace`.
- **It sends nothing anywhere.** DblSpace has no network code at all.

This program will not transfer any information to other networked systems unless specifically requested by the user or the person installing or operating it.

The full source code is in [`src/dblspace.bas`](src/dblspace.bas), so you can check all of this yourself.

## Build from source

Requirements:

- [FreeBASIC](https://www.freebasic.net/) 1.10, 64-bit
- [Inno Setup](https://jrsoftware.org/isinfo.php) 6, for the installer

Run `build.bat`. It builds `dist\dblspace.exe`, then the installer, also in `dist`. If FreeBASIC or Inno Setup is installed somewhere else, set `FBC` or `ISCC` to the full path of `fbc64.exe` or `ISCC.exe` before running it.

Official releases are built by [GitHub Actions](.github/workflows/build.yml) from this repository, not on anyone's PC. Pushing a version tag such as `v1.0.0` builds the installer and attaches it to a draft release.

To build only the program, run this from the `src` folder:

```
fbc64 -s gui -mt dblspace.bas dblspace.rc
```

| Path | What it is |
|---|---|
| `src/dblspace.bas` | The whole program |
| `src/dblspace.rc` | Icons, manifest and version info compiled into the .exe |
| `src/dblspace.manifest` | Display scaling support and modern controls |
| `src/dblspace.ico`, `src/dblspace_off.ico` | Tray icons for on and off |
| `installer/dblspace.iss` | Inno Setup installer script |
| `build.bat` | Builds the program and the installer |
| `.github/workflows/build.yml` | The GitHub Actions build used for releases |
| `dist/` | Build output (not in git) |

## Code signing policy

Releases are not code-signed yet. Free signing from the [SignPath Foundation](https://signpath.org/) has been requested.

Team roles:

- Committers and reviewers: [Christopher Martinez](https://github.com/crmartinez239)
- Approvers: [Christopher Martinez](https://github.com/crmartinez239)

Privacy: see [Your keystrokes and privacy](#your-keystrokes-and-privacy).

## License

MIT. See [LICENSE.txt](LICENSE.txt).
