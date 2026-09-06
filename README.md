# Domovoy

Personal AI assistant built with Flutter.

## Linux development

The application stores an optional DeepSeek API-key override with Secret
Service. Install the `libsecret` runtime and development packages before
building the Linux desktop app. On Debian and Ubuntu:

```sh
sudo apt install libsecret-1-0 libsecret-1-dev
```

At runtime, Domovoy first uses the API key saved in its settings and otherwise
falls back to the `DEEPSEEK_API_KEY` process environment variable.
