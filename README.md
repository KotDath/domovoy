# Domovoy

Персональный ИИ-ассистент на Flutter с потоковыми ответами, сохраняемой историей
и подключением LLM через API. Эта ветка содержит результат отдельного учебного задания.

## Итог задания 6 — первый агент

Реализован отдельный агент: `AgentDefinition` задаёт модель и инструкции,
`AgentRuntime` создаёт агента и сессию, а адаптер провайдера инкапсулирует HTTP.
Пользователь отправляет запрос в интерфейсе и получает потоковый ответ модели.
Доступны 30 профилей API-key провайдеров и динамический каталог моделей.

### Результат проверки

13 сентября 2026 года выполнены реальные запросы DeepSeek через production
AgentRuntime. Flash вернул 41 input / 17 output / 58 overall токенов;
Pro — 133 / 3 / 136. Значения в учёте совпали с usage из SSE API.
В ручном браузерном прогоне ответ Flash показал 59 / 138 / 197,
включая 113 reasoning-токенов. Получение ответа и выбор модели работают.
Живые проверки выполнены для DeepSeek; другие провайдеры не объявляются
проверенными с настоящими ключами. Общий набор: 464 теста прошли.

### Запуск и видео

```sh
flutter run -d linux
```

Задайте `DEEPSEEK_API_KEY` в окружении или сохраните ключ в настройках.
Создайте чат, выберите DeepSeek Flash, отправьте запрос и покажите ответ и usage.
В коде покажите отдельные сущности агента и сессии.
[Подробный сценарий видео](docs/demos.md) · [Протокол проверок](docs/verification.md).
Видео не записано; подготовлены код и воспроизводимый сценарий.

## Linux development

The application stores an optional DeepSeek API-key override with Secret
Service. Install the `libsecret` runtime and development packages before
building the Linux desktop app. On Debian and Ubuntu:

```sh
sudo apt install libsecret-1-0 libsecret-1-dev
```

At runtime, Domovoy first uses the API key saved in its settings and otherwise
falls back to the `DEEPSEEK_API_KEY` process environment variable.
