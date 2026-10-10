# Clash for Apple Platforms

English · [简体中文](README.zh-CN.md)

[![Website](https://img.shields.io/badge/Website-Official-2563EB)](https://clash.md/)
[![App Store Download](https://img.shields.io/badge/App_Store-Download-black?logo=apple&logoColor=white)](https://apps.apple.com/app/id6794257189)
[![Telegram Channel](https://img.shields.io/badge/Telegram-Channel-26A5E4?logo=telegram&logoColor=white)](https://t.me/clashbyclash)
[![Telegram Group](https://img.shields.io/badge/Telegram-Group-26A5E4?logo=telegram&logoColor=white)](https://t.me/+t__WNRvjUbk3M2Nl)

A native, rule-based proxy client for iPhone, iPad, Mac and Apple TV, powered by the Clash kernel.

Use the App Store link to install the official app. The instructions below are for building from source.

## About this repository

This repository contains the Apple applications, their extensions, shared libraries and resources needed to build them. The [Clash kernel](https://github.com/ProjectClash/Clash) and [Adapter components](https://github.com/ProjectClash/Clash-Adapter) are maintained in separate repositories; their source revisions are pinned in [`Dependencies.lock.json`](Dependencies.lock.json).

| Directory | Contents |
| --- | --- |
| `apple/ClashClient` | Platform applications, extensions and XcodeGen project specification |
| `apple/ClashClientKit` | Shared configuration and profile models |
| `apple/ClashClientUI` | Shared interface components |
| `apple/ClashMacClient` | macOS components |
| `cli` | Terminal helper bundled with the Mac app, including its embedded usage guide |

The source distribution is pre-release. The App Store app version and a checkout of this repository are separate artifacts; pin a source revision when reproducing a build.

The iOS and macOS projects wrap the static Core in a shared framework, with the required header-copy build step included in project generation. Available features depend on the pinned Kernel and Adapter revisions; the iOS/tvOS SDK does not include EasyTier.

## Build from source

### Requirements

- macOS with Xcode 27.0 or later and the iOS, macOS and tvOS SDKs.
- XcodeGen and Git available on your command path.
- Go with automatic toolchain selection enabled, or the Go 1.26.9 toolchain selected by the pinned kernel's binding module.
- Python 3 with PyYAML.

### Prepare the project

```sh
git clone https://github.com/ProjectClash/Clash-Client.git
cd Clash-Client
python3 -m venv .build/python-env
source .build/python-env/bin/activate
python3 -m pip install PyYAML
python3 scripts/bootstrap.py
python3 scripts/configure.py
```

The first bootstrap fetches the pinned public Kernel and Adapter sources, installs the pinned gomobile tools and builds the five-slice SDK. It requires network access and can take several minutes. The configure step generates the Xcode project and builds the universal macOS terminal helper. Run it again after changing your bundle identifiers.

Open `apple/ClashClient/ClashClient.xcodeproj` and choose a scheme:

| Platform | Scheme |
| --- | --- |
| iPhone / iPad | `ClashiOS` |
| Apple TV | `ClashtvOS` |
| Mac | `ClashmacOS` |

For an unsigned iOS Simulator build:

```sh
xcodebuild -project apple/ClashClient/ClashClient.xcodeproj \
  -scheme ClashiOS -configuration Release \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

### Sign your own build

Set your own bundle identifier family and Apple Developer Team ID:

```sh
python3 scripts/configure.py --bundle-base org.yourname.clash --team YOURTEAMID
```

Configure signing and capabilities for the app and its extensions in Xcode, including Network Extensions, App Groups and any iCloud capabilities you use. Certificates and provisioning profiles are not included. An unsigned build checks compilation; installing on a device requires your own signing setup.

## Feedback

Report app problems in [Issues](https://github.com/ProjectClash/Clash-Client/issues). Include the platform and OS version, app version or source revision, reproduction steps, and expected versus actual behavior. Share only the configuration and logs needed to reproduce the problem, with credentials and subscription links removed.

Kernel issues can be reported in [Clash](https://github.com/ProjectClash/Clash/issues); packet bridge and provider lifecycle issues belong in [Clash-Adapter](https://github.com/ProjectClash/Clash-Adapter/issues).

## License

[GPL-3.0](LICENSE). Third-party resource licenses remain with their resources.
