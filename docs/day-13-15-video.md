# Days 13–15: Android demo runbook

`docs/day-13-15.md` defines the product contract. This runbook defines the
repeatable Android recording procedure and the evidence expected in each video.

## Known-good Android setup

- AVD: `Domovoy_API_35`, Android 15 / API 35, x86_64 Google APIs image.
- Emulator: 37.1.11. The older 36.5.10 binary crashed in RenderThread with the
  available software renderer; the current setup uses `-gpu host`.
- App ID: `ru.kotdath.domovoy`.
- Mobile bridge: the global binary at
  `/home/kotdath/.npm-packages/bin/claude-in-mobile`, version 4.4.1;
  `claude-in-mobile doctor` reports the Android section as ready.
- Provider/model: DeepSeek / `deepseek-flash`, with reasoning enabled.
- The DeepSeek key is entered before recording through the Providers screen and
  stored by `flutter_secure_storage`. Never show or paste the key in a video,
  shell transcript, screenshot, or committed file.

Start the emulator, build, install, and launch:

```sh
$ANDROID_HOME/emulator/emulator -avd Domovoy_API_35 -no-window -no-audio \
  -no-boot-anim -gpu host -no-snapshot-load -no-snapshot-save
flutter build apk --debug
adb install -r build/app/outputs/flutter-apk/app-debug.apk
adb shell monkey -p ru.kotdath.domovoy \
  -c android.intent.category.LAUNCHER 1
```

The debug build intentionally preserves secure storage across `adb install -r`.
For a clean scenario, create a new chat instead of clearing application data.

For automated QA through `claude-in-mobile`, use the ASCII equivalents below
when Android's `input text` bridge rejects Cyrillic:

- Day 13: `Write a short memo with exactly three sections: preparation,
  verification, and publication. Put exactly two bullets in each section. Do
  not create files or run commands.`
- Day 14 allowed: `Write a brief technical proposal for a Flutter landing
  page. Do not create files or run commands.`
- Day 14 conflict: `Write a brief technical proposal for a React landing page.
  Do not create files or run commands.`
- Day 15: `Write and verify a short release-notes preparation memo. Do not
  create files or run commands.`

Record one scenario at a time. Android's built-in recorder can be used as
follows; stop it with `Ctrl+C`, then pull the file:

```sh
mkdir -p artifacts
adb shell screenrecord --bit-rate 8000000 --time-limit 180 \
  /sdcard/day-13.mp4
adb pull /sdcard/day-13.mp4 artifacts/day-13.mp4
```

Repeat with `day-14.mp4` and `day-15.mp4`. Keep secrets off-camera.
`screenrecord` stops after 180 seconds; if a provider response takes longer,
record the scenario as numbered clips and concatenate them after capture.

## Day 13 — persisted task state and resume

Use a new chat.

1. Send `/plan`. The task card must say that plan mode is enabled and asks for
   the next message.
2. Send: `Напиши краткую памятку из трёх разделов: подготовка, проверка и
   публикация. В каждом разделе ровно два пункта. Не создавай файлы и не
   запускай команды.`
3. Wait for a proposed plan. Expand `План`, show its nodes, the `планирование`
   phase, and `Ожидается: утверждение плана`.
4. Tap `Утвердить план`, then tap `Пауза` while execution is active.
5. Show `Ожидается: продолжение пользователем`. Force-stop and reopen Domovoy
   without clearing its data.
6. Show that the same goal, plan, revision, node progress, and paused checkpoint
   are restored. Do not restate the goal.
7. Tap `Продолжить`. Do not confirm individual nodes: the scheduler must route
   worker → verifier → next node → final composition → final verifier on its
   own.
8. Finish on `Задача · готово`, `Ожидается: нет`, full node progress, and the
   expanded `Результат` section.

Pass condition: pause/restart/resume loses no task context, and the task advances
automatically after the single plan approval.

## Day 14 — separately stored invariant and conflict refusal

Use a new chat.

1. Send `/plan`, then: `Напиши краткое техническое предложение для лендинга на
   Flutter. Не создавай файлы и не запускай команды.`
2. When the draft appears, open `Инварианты`.
3. Description: `Использовать только Flutter`; forbidden words:
   `React, Redux`. Tap `Добавить`, then `Сохранить`.
4. Tap `Новый план`, replace the goal with
   `Напиши краткое техническое предложение для лендинга на React. Не создавай
   файлы и не запускай команды.`, then tap `Перестроить`.
5. Show the refusal `[INVARIANT_VIOLATION]`, its rule ID, and the explanation
   `Обнаружены запрещённые элементы: React.` No planner call should occur.
6. Tap `Новый план` again, replace the goal with
   `Напиши краткое техническое предложение для лендинга на Flutter. Не создавай
   файлы и не запускай команды.`, and rebuild it.
7. Reopen `Инварианты` and show that the rule is still present independently of
   chat history. Approve the allowed plan and let it complete.

Pass condition: the conflicting goal is rejected deterministically and the
allowed goal continues under the persisted rule.

## Day 15 — guarded transitions and automatic routing

Use a new chat.

1. Send `/plan`, then: `Напиши и проверь короткую памятку по подготовке
   релиз-нотов. Не создавай файлы и не запускай команды.`
2. Before approval, tap `Проверить execution`. Show
   `[PLAN_APPROVAL_REQUIRED]`: execution was not entered.
3. Tap `Утвердить план`. During execution, tap `Проверить done`. Show
   `[VALIDATION_REQUIRED]`: the task did not jump to done.
   Keep recording through at least one later revision or node-progress update:
   the diagnostic remains visible while routing advances inside `execution` and
   clears when the workflow enters validation.
4. If needed, use `Пауза` and `Продолжить`; do not provide per-node approval.
5. Show automatic transition through `выполнение` and `валидация` to `готово`.
6. At `готово`, show full progress and `Ожидается: нет`.

If a live verifier exhausts its single repair on camera, keep that clip as a
valid bounded-failure demonstration, cancel the task, create a new chat, and
repeat with the exact short text-only prompt above. Do not switch to a goal that
requires filesystem, shell, build, or device tools: task agents are intentionally
tool-free in version 1.

Pass condition: both forbidden transitions produce stable codes, neither mutates
the task into the requested illegal phase, and normal routing reaches done only
after final-validation evidence.

## Evidence checklist

For every scenario retain:

- the MP4 path;
- a screenshot of the key error/state and the terminal `готово` state;
- the tested APK build result;
- the device/API/emulator versions;
- the final `flutter analyze` and `flutter test` result.

The coordinator records concrete QA artifact paths in `docs/day-13-15.md` after
the independent Android run has completed.

The ignored `artifacts/day-13-15-qa/` directory contains pre-recording Android
PNG evidence. It is not a substitute for the assignment MP4; it is the reference
set for matching the intended states while recording.
