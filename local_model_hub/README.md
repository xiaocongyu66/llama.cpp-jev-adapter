# Local Model Hub

Flutter Material 3 Expressive UI scaffold for managing local models and an OpenAI-compatible API gateway.

## Current scope

- Responsive Material 3 Expressive overview, model library, API keys, request activity, and settings screens.
- GGUF model path import and persistence; desktop launch/stop of a configured `llama-server` executable.
- Local API gateway bound to `127.0.0.1:8080`, forwarding OpenAI-compatible requests to the engine on `127.0.0.1:8081`.
- Bearer key authentication, per-key requests-per-minute limits, secure key storage, request logs, and upstream token usage accounting.
- GPU selection is passed as llama.cpp startup flags (for example `--n-gpu-layers auto`) and displayed as configured flags. Actual GPU use depends on the selected `llama-server` binary and backend build.

The current process-launch integration targets desktop platforms. On Android/iOS/Web, model-process launch reports an explicit unsupported-platform error until a packaged native llama.cpp/JNI engine is added. The project still needs `flutter create .` to generate platform runner directories before desktop/mobile builds.

## Run

Requires Flutter SDK 3.6 or newer.

```sh
flutter pub get
flutter run -d <device>
```
