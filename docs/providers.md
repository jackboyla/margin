# Model providers

Open **Settings → Models**, choose **Answer with**, and save. New threads use those settings. Existing threads keep their backend and API model settings.

## Codex

Install and sign in to [Codex CLI](https://github.com/openai/codex), then select its executable and a working folder. Margin starts Codex with read-only tools and keeps a separate agent session for each thread. Available window images accompany captured text. Codex manages its own sign-in and session files.

## OpenAI-compatible APIs

Choose **OpenAI-compatible API**, then a preset. Enter the exact model identifier available from that provider or local server and any required API key. Presets leave the model blank and disable image uploads.

| Preset | API base URL | Output token field |
| --- | --- | --- |
| OpenAI | `https://api.openai.com/v1` | `max_completion_tokens` |
| [Claude compatibility](https://platform.claude.com/docs/en/cli-sdks-libraries/libraries/openai-sdk) | `https://api.anthropic.com/v1` | `max_tokens` |
| [Ollama on this Mac](https://docs.ollama.com/api/openai-compatibility) | `http://localhost:11434/v1` | `max_tokens` |
| [LM Studio on this Mac](https://lmstudio.ai/docs/developer/openai-compat) | `http://localhost:1234/v1` | `max_tokens` |

For a local model, start the server and load or download the model through that server first. Leave the key empty if the server requires none. A custom base URL must use HTTP or HTTPS without embedded credentials, a query, or a fragment. Margin appends `/chat/completions` unless the URL already ends with that path.

The endpoint must support streaming Chat Completions and a model that returns text. Margin sends the thread's completed messages with each follow-up. It does not offer agent tools through this API path.

Enable **Include window images** only when the endpoint and model accept images. Margin sends available captures as PNG data URLs, alongside selected and visible text. Shared conversations may reference images that exist only on another Mac; those questions use saved text when the image is unavailable. Text recognition, image support, and a model's ability to read equations are separate limits.

**Advanced** selects the output token field and limit, which defaults to 4096. Match the field to the server's requirements. Claude uses Anthropic's compatibility API; use an Anthropic API key and, when required by your key, set the **Anthropic workspace ID** there. Review the provider's compatibility limits before enabling images or selecting a model.

API keys stay in macOS Keychain, scoped to the completion endpoint. Model settings and library records do not contain the key. Captured text, saved highlights, and enabled images go to the chosen endpoint when you ask a question.
