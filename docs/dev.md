# Разработка

## Структура

- `apple/Package.swift`: SwiftPM-пакет с общим кодом приложения.
- `apple/project.yml`: основной файл XcodeGen для app/extension targets.
- `apple/Godwit.xcodeproj`: сгенерированный Xcode-проект.
- `apple/Sources/OlcRTCClientKit`: общие SwiftUI views, models, stores,
  parsers и runtime managers.
- `apple/Sources/OlcRTCClientMac`: точка входа macOS-приложения.
- `apple/Sources/OlcRTCClientiOS`: точка входа iOS-приложения и entitlements.
- `apple/Sources/OlcRTCPacketTunnel`: iOS Packet Tunnel extension.
- `apple/Scripts`: скрипты сборки.

Кодовая база OlcRTC не хранится в этом репозитории. Для сборок, которым нужен
Go CLI или gomobile XCFramework, передайте путь к внешнему checkout OlcRTC:

```bash
./apple/Scripts/build-xcframework.sh --olcrtc-root /path/to/olcrtc
```

Вместо флага можно использовать переменную окружения:

```bash
OLCRTC_REPO_ROOT=/path/to/olcrtc ./apple/Scripts/build-xcframework.sh
```

Для нескольких команд подряд экспортируйте переменную один раз:

```bash
export OLCRTC_REPO_ROOT=/path/to/olcrtc
./apple/Scripts/build-macos-app.sh && ./apple/Scripts/build-ios-unsigned-local-ipa.sh
```

Локальные результаты сборки не коммитятся:

- `apple/.build/`
- `apple/.derived-data/`
- `apple/.swiftpm/`
- `apple/Frameworks/Mobile.xcframework`
- `olcrtc/`, если локальный checkout OlcRTC временно положен рядом с этим
  проектом.

## Проект Xcode

После изменений targets, dependencies, entitlements или bundle IDs:

```bash
cd apple
xcodegen generate
```

`project.yml` считается единственным источником правды. Xcode-проект
генерируется из него.

Для быстрой проверки доступных targets и schemes:

```bash
xcodebuild -list -project apple/Godwit.xcodeproj
```

## Ограничения

- iOS Packet Tunnel сейчас сфокусирован на TCP и DNS-over-tunnel поведении.
  Произвольный UDP forwarding можно включить в настройках профиля через UDP
  Mode, но режим по умолчанию остается TCP relay для совместимости с текущими
  стабильными olcRTC-сборками. UDP relay рассчитан на olcRTC builds, где SOCKS5
  UDP/datagram path уже поддерживается.
- iOS local SOCKS mode использует background audio mode, чтобы процесс
  продолжал работать после сворачивания приложения. Это удобно для sideloaded
  local testing; для системного iOS-трафика нужен сторонний маршрутизатор
  трафика или подписанная Packet Tunnel сборка.
- Для реального iPhone с Packet Tunnel нужен платный Apple Developer Program и
  provisioning profiles с Network Extension capability для обоих iOS targets.
