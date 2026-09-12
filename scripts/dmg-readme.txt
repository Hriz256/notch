Notch — остров для шторки MacBook (личная сборка, без нотаризации Apple)

Требования: Mac на Apple Silicon или Intel, macOS 26 и новее, экран со шторкой.

1. Перетащите Notch.app в папку Applications.
2. Откройте Notch. macOS скажет, что не может проверить разработчика — это ожидаемо:
   приложение подписано без Apple Developer ID.
   Откройте System Settings → Privacy & Security, прокрутите вниз и нажмите
   «Open Anyway» рядом с Notch, затем подтвердите. Это нужно один раз.
   Альтернатива в Терминале:  xattr -dr com.apple.quarantine /Applications/Notch.app
3. При первом запуске macOS может спросить доступ к записи «Claude Code-credentials»
   в Keychain — это для статистики использования Claude Code. Можно нажать
   «Always Allow» или отказать, остров работает и без этого.
4. Иконка Notch появляется в строке меню: там включаются функции (Music, Coding agents,
   Drop Zones) и настройки.

Что умеет
- Music: текущий трек (Spotify, Apple Music и другие через MediaRemote), play/pause, перемотка.
- Coding agents: стадии Claude Code / Codex / Cursor в реальном времени и лимиты использования.
  При включении агента Notch добавляет свои хуки в ~/.claude/settings.json, ~/.codex/config.toml,
  ~/.cursor/hooks.json (с резервной копией *.notch.bak) и убирает их при выключении.
- Drop Zones: тяните файл к шторке — AirDrop или полка (стэш на 24 часа), из полки файлы
  вытягиваются обратно в любое приложение.
- Страницы листаются двумя пальцами над островом, правый клик — меню.
