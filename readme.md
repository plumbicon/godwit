# Godwit

__❗НАМ НУЖНЫ ДЕНЬГИ НА ПУБЛИКАЦИЮ В TESTFLIGHT❗__
__ETH20 (USDT, USDC, ETH, etc): 0xb0292E226b140F3CC14B83777a09dF6d33Bc8613__
__BTC: bc1qxj5cxnkeqj3rmhaydj8cfnz7frstl3p6dac7zw__
__❗НАМ НУЖНЫ ДЕНЬГИ НА ПУБЛИКАЦИЮ В TESTFLIGHT❗__

<img height="640" alt="Image" src="https://github.com/user-attachments/assets/3535120e-48e1-4b34-9344-a61282bfe6f1" />

<img height="640" alt="Image" src="https://github.com/user-attachments/assets/a32de5b6-3921-4c59-a68d-b9f0f0dcdd7b" />

macOS/iOS-клиент Godwit для olcRTC.

## Требования

- macOS 13 или новее.
- Go.
- Xcode или Command Line Tools для macOS/SwiftPM-сборок.
- Полный Xcode с iOS SDK для iOS-сборок.
- `gomobile`.
- `xcodegen`, если нужно пересоздавать `apple/Godwit.xcodeproj`.
- Sideloadly, если нужно установить неподписанный local-SOCKS IPA на iPhone.

Если Xcode только что установлен:

```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
sudo xcodebuild -license accept
```

## Сборка

Кодовая база OlcRTC поставляется отдельно и не хранится внутри этого
репозитория. Для скриптов, которые собирают Go CLI или `Mobile.xcframework`,
передайте путь к внешнему checkout:

```bash
./apple/Scripts/build-xcframework.sh --olcrtc-root /path/to/olcrtc
```

То же можно задавать через переменную окружения:

```bash
OLCRTC_REPO_ROOT=/path/to/olcrtc ./apple/Scripts/build-xcframework.sh
```

Если запускается цепочка команд через `&&`, переменную нужно экспортировать
заранее или передавать флаг каждому скрипту:

```bash
export OLCRTC_REPO_ROOT=/path/to/olcrtc
./apple/Scripts/build-macos-app.sh && ./apple/Scripts/build-ios-unsigned-local-ipa.sh
```

### Сборка неподписанного iOS-клиента

Неподписанная сборка предназначена для local SOCKS режима на реальном iPhone
без Network Extension entitlement:

```bash
./apple/Scripts/build-ios-unsigned-local-ipa.sh --olcrtc-root /path/to/olcrtc
```

Результат:

```text
apple/.build/ios-unsigned-local/Godwit-unsigned-local.ipa
```

Этот IPA собирается с `LOCAL_SOCKS_ONLY`: в нем остается local SOCKS proxy, но
удаляется Packet Tunnel extension. Поэтому приложение не поднимает системный VPN
и не маршрутизирует весь iOS-трафик само. Системный трафик нужно направлять в
локальный прокси через стороннее приложение, например Happ, указав SOCKS5
`127.0.0.1:<port>`.

При старте local SOCKS на iOS в Events должно появиться:

```text
iOS background runtime is active for local SOCKS.
```

#### Установка через Sideloadly:

1. Установить Sideloadly с официального сайта: `https://sideloadly.io/`.
2. Подключить iPhone к Mac по USB и нажать Trust/Доверять на телефоне, если iOS
   спросит.
3. Собрать IPA:

   ```bash
   ./apple/Scripts/build-ios-unsigned-local-ipa.sh
   ```

4. Открыть Sideloadly.
5. Перетащить файл
   `apple/.build/ios-unsigned-local/Godwit-unsigned-local.ipa` в окно
   Sideloadly или выбрать его через кнопку IPA.
6. Выбрать подключенный iPhone в списке устройств.
7. Ввести Apple ID. Для local-SOCKS IPA подходит обычный бесплатный Apple ID.
   Лучше использовать отдельный Apple ID для sideloading, а не основной.
8. Нажать Start и дождаться завершения установки.
9. На iPhone открыть Settings -> General -> VPN & Device Management и доверить
   developer profile, связанный с использованным Apple ID.
10. На iOS 16 и новее включить Developer Mode: Settings -> Privacy & Security
    -> Developer Mode, затем перезагрузить устройство, если iOS попросит.
11. Запустить Godwit на iPhone, выбрать профиль и нажать Start.
12. В Happ или другом приложении для маршрутизации трафика указать SOCKS5 proxy
    `127.0.0.1:<port>`.

Важно:

- Бесплатный Apple ID обычно требует периодической переустановки/обновления
  sideloaded app.
- Неподписанный local-SOCKS IPA не содержит Packet Tunnel extension.
- Если нужен системный VPN/Packet Tunnel без стороннего маршрутизатора, нужна
  подписанная сборка с правильными Apple Developer entitlements.

### Сборка macOS-клиента

Из корня репозитория:

```bash
./apple/Scripts/build-macos-app.sh --olcrtc-root /path/to/olcrtc
open ./apple/.build/Godwit.app
```

Скрипт собирает:

- `apple/.build/olcrtc-macos`: Go CLI helper.
- `apple/.build/Godwit.app`: запускаемый macOS app bundle.

При успешном старте в Events должно появиться:

```text
SOCKS proxy is ready at 127.0.0.1:<port>.
System SOCKS proxy enabled for <service> on 127.0.0.1:<port>.
```

Если приложение было принудительно закрыто, пока системный SOCKS-прокси macOS
включен:

```bash
networksetup -setsocksfirewallproxystate "Wi-Fi" off
```

### Сборка подписанного iOS-клиента

Подписанная сборка нужна для полной VPN/Packet Tunnel версии. Для нее нужен
Apple Developer Team и provisioning profiles с Network Extension
`packet-tunnel-provider` entitlement для обоих iOS targets:

- `OlcRTCClient iOS`
- `OlcRTCPacketTunnel`

IPA для разработки:

```bash
DEVELOPMENT_TEAM=ABCDE12345 \
EXPORT_METHOD=development \
./apple/Scripts/build-ios-ipa.sh --olcrtc-root /path/to/olcrtc
```

Ad-hoc IPA:

```bash
DEVELOPMENT_TEAM=ABCDE12345 \
EXPORT_METHOD=ad-hoc \
./apple/Scripts/build-ios-ipa.sh --olcrtc-root /path/to/olcrtc
```

Поддерживаемые значения `EXPORT_METHOD`:

- `development`
- `ad-hoc`
- `app-store`
- `enterprise`

Скрипт пишет архив и экспортированный IPA сюда:

```text
apple/.build/ios-archive/
apple/.build/ios-ipa/
```

Для тестирования с реального iPhone через Xcode:

```bash
open ./apple/Godwit.xcodeproj
```

В Xcode нужно настроить signing для обоих targets:

- `OlcRTCClient iOS`
- `OlcRTCPacketTunnel`

Используемые bundle IDs:

```text
community.openlibre.olcrtc.ios
community.openlibre.olcrtc.ios.PacketTunnel
```

Если bundle IDs меняются, extension bundle ID должен начинаться с bundle ID
основного приложения.

## Дополнительно

- Детали структуры проекта, XcodeGen и ограничения: [docs/dev.md](docs/dev.md).
- Формат профилей и подписок описан в `docs/sub.md` и `docs/uri.md` внешнего
  репозитория OlcRTC.
