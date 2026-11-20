<p align="center"><img src="assets/icon.png" width="80" alt="Netlane"></p>

# Netlane для macOS

VPN-клиент на базе [TrustTunnel](https://github.com/TrustTunnel/TrustTunnelClient): подписки, наборы правил для сайтов и программ, Kill Switch. macOS 13+, одна сборка для Intel и Apple Silicon. Версия для Windows — [netlane-windows](https://github.com/divezh/netlane-windows).

<p align="center">
  <img src="assets/screenshots/home.png" width="49%" alt="Главный экран: подключено, локации с пингом, графики скорости">
  <img src="assets/screenshots/rules.png" width="49%" alt="Правила: сайты и программы, которые идут через VPN">
</p>

## Установка

Скачайте **[Netlane-macos.pkg](https://github.com/divezh/netlane-macos/releases/latest/download/Netlane-macos.pkg)** и откройте. Приложение не подписано Apple, поэтому при первом запуске: «Системные настройки» → «Конфиденциальность и безопасность» → «Всё равно открыть».

Или одной командой, без предупреждения macOS:

```sh
curl -fsSL https://github.com/divezh/netlane-macos/releases/latest/download/install.sh | sh
```

Затем «Добавить сервер» → вставьте ссылку подписки от администратора.

Архивы подписаны ключом владельца ([`netlane-release.pub`](netlane-release.pub)); приложение и помощник ставят обновления только с этой подписью. Проверка вручную: `openssl dgst -sha256 -verify netlane-release.pub -signature Netlane-macos.pkg.sig Netlane-macos.pkg`.

## Полезное

```sh
tail -f ~/Library/Logs/Netlane/engine.log          # журнал VPN
cat ~/Library/Logs/Netlane/update.log              # журнал обновлений
open ~/Library/Application\ Support/Netlane         # настройки и подписки (state.json)
sudo launchctl print system/io.github.divezh.netlane.helper | head   # помощник VPN

# удалить Netlane полностью
curl -fsSL https://raw.githubusercontent.com/divezh/netlane-macos/main/uninstall.sh | sh
```

Правило программы — имя процесса из «Мониторинга системы», например `Google Chrome`. Вспомогательные процессы (`Google Chrome Helper (GPU)` и т. п.) входят в правило сами. В панели правило пишется с `.exe` (`Google Chrome.exe`); на Windows у Chrome другое имя файла — `chrome.exe`, добавьте и его.

## Сборка

Нужны Xcode Command Line Tools и rustup. Скрипт сам устанавливает закреплённую upstream версию Rust и targets для Intel и Apple Silicon. Сборка включает тесты и линтеры; LLVM 21 ниже используется только для линтеров, компилятором остаётся Apple Clang.

```sh
brew install cmake ninja llvm@21 markdownlint-cli
lint_tools="$PWD/.build/lint-tools"
mkdir -p "$lint_tools"
for tool in clang-format clangd clang-tidy run-clang-tidy; do
  ln -sf "$(brew --prefix llvm@21)/bin/$tool" "$lint_tools/$tool"
done
PATH="$lint_tools:$HOME/.cargo/bin:$PATH" scripts/build-app.sh
# → dist/Netlane-macos.pkg и .zip
```

Релиз: поднять версию в `Sources/NetlaneCore/Support.swift` и CHANGELOG, опубликовать релиз `vX.Y.Z` — Actions соберёт его; установленные клиенты увидят его как обновление.

[MIT](LICENSE) · [сторонние компоненты](THIRD_PARTY_NOTICES.md) · об уязвимостях пишите приватно через [Security advisories](https://github.com/divezh/netlane-macos/security/advisories/new)
