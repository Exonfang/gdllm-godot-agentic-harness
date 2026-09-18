# GDLLM - An in-editor Godot Agentic Harness

A fully transparent in-editor agentic harness for large language models inside the Godot Engine. Connect to any LLM provider via API (or use your ChatGPT Subscription) and provide your agents the tools, context management, and guidance to effectively complete most tasks in Godot. Every action the agent takes is fully surfaced and persists in session history.

Compared to Opencode, GDLLM completes the same tasks in roughly **half as many tokens**.

Designed around *progressive disclosure*, the main agent starts with almost nothing and pulls in deeper knowledge only as a task demands it, so the conversation stays token light and on-topic.

The plugin lives under [addons/gdllm-godot-agentic-harness/](addons/gdllm-godot-agentic-harness/).

[MarkdownLabel](https://github.com/daenvil/MarkdownLabel) v1.4.0 is a strongly encouraged enhancement for the plugin. If that addon is installed, MarkdownLabel is used to prettify model responses.

## Guiding Philosophy

1. **Context is minimized to only what is absolutely necessary to complete the task.**
2. **All actions the agents take are fully transparent to the user.**
3. **Errors guide agents and the user to solutions.**
4. **Every session generates and saves logs locally.**

By integrating this harness directly into the editor, GDLLM starts ahead of more general harnesses (or MCP servers) with lower initial context and first-class Godot tools.

## Harness Features

- Connects to any provider via API and/or connect your ChatGPT subscription directly.
- Adds a familiar "chat" panel to manage agent sessions.
- Give your agents full access to all Godot engine features.
- Every action an agent takes is fully surfaced and transparent. Optionally toggle to a condensed feed which folds each tool call and its result into expandable one-line summaries.
- Inspect complete model context at any turn.
- Edits, whenever possible, are automatically engine-validated after changes and errors are surfaced to agents.
- Integrated engine documentation, pulling from the same cached data the in-editor documentation browser uses.
- Respects `AGENTS.md`. `GDLLM.md` optionally overrides any `AGENTS.md` file if present.
- Supports user-defined `/skills/`, dynamically added for appropriate tasks, similar to most other harnesses.
- Contains tool calls within user and project directories for increased safety. (User configurable via editor setting in GDLLM > Agents)
- Anthropic-like cache boundary aware compaction. Cache TTL is configurable per model and provider, auto-retires idle tools and loudly emits the boundary so the user can choose to compact manually if they prefer.
- Supports agents spawning subagents.
- Session history management.
- Per-session permission gates (read only, make changes, make changes and delete files)
- Loop control breaks - notices when an agent is thrashing and stops them.
- Send-safety gates - notices regarding unsaved work before prompts are sent.
- Attachment support (selected nodes, scripts, and script selections)
- [MarkdownLabel](https://github.com/daenvil/MarkdownLabel) support for improved model output styling.
- Comprehensive editor settings. *(*It's strongly recommended to leave most of these at defaults unless you know what you're doing!)*
- Configurable colors.

## Tools

**Reading code and files**
`read_file`, `read_function`, `list_directory`, `search_files`, `list_dependencies`

**Writing files**
`edit_file`, `write_file`, `check_script`, `move_file`, `rename_file`, `copy_file`, `delete_file`

**Engine knowledge**
`describe_class`, `describe_member`, `describe_docs`, `search_docs`

**Project and Resources**
`describe_project`, `set_project_setting`, `set_import_setting`, `create_resource`, `edit_resource`

**Scenes and 2D Data**
`describe_scene`, `describe_scene_file`, `read_tilemap`, `describe_tileset`, `edit_tilemap`, `describe_animation`, `edit_animation`

**Running and Debugging**
`run_game`, `stop_game`, `run_script`, `suspend_game`, `reload_game_scripts`, `set_breakpoint`, `read_game_break`, `debug_game`, `read_output`, `read_errors`

**Live-game introspection and input driving**
`read_game_ui`, `inspect_game_node`, `send_game_input`, `call_game_method`, `read_performance`, `profile_game`, `read_video_ram`

**Delegation**
`run_subagent`

## First-time Setup

- Download and extract the release zip of your choice (GDLLM + MarkdownLabel recommended) directly into your Godot project directory.
- Using the **Connections** button in the session panel, link up your inference providers: pick the Kind (OpenAI-Compatible (Chat Completions), OpenAI Responses API, OpenAI ChatGPT Subscription, Anthropic, Google Gemini (BYOK), Google Gemini (Antigravity), or Ollama), paste the URL your provider hands you (the full endpoint or just the server address, either works) and add API keys where needed. Any OpenAI-compatible server (LM Studio, llama.cpp, vLLM, koboldcpp, most others...) uses the OpenAI-Compatible (Chat Completions) kind. OpenAI's own API (api.openai.com) works best as the **OpenAI Responses API** kind — its newest models (GPT-5.6 and up) require the Responses API to combine reasoning effort with tools.
- A ChatGPT Plus/Pro subscription can drive the harness without API billing: use the **OpenAI ChatGPT Subscription** kind and press its **Sign in with ChatGPT** button (a browser sign-in; no API key).
- **Google Gemini** ships as two distinct routes in separate source rows, so a per-token AI Studio key never gets used to drive a Cloud Code Assist session, and stale credentials from one route never answer a request meant for the other:
  - **Google Gemini (BYOK)** — `Kind: "gemini"`, base `https://generativelanguage.googleapis.com/v1beta`. Paste your AI Studio API key (`AIzaSy…`, free at [aistudio.google.com/apikey](https://aistudio.google.com/apikey)); it ships as `x-goog-api-key`. Paid on your GCP project, independent of any AI Studio Pro subscription.
  - **Google Gemini (Antigravity)** — `Kind: "gemini-oauth"`, base `https://cloudcode-pa.googleapis.com`. Sign in with Google (browser OAuth + PKCE); the harness refreshes the access token silently. Plan-covered against your Google AI plan, not per-token. Only available to accounts on a Cloud Code Assist whitelisted tenant.
- After the model list refreshes, use the **Effort Configuration** to specify the available thinking levels, cache TTL, and context windows. No provider has an API to retrieve model effort/thinking levels, so they need to be manually identified and added, or the default effort level for the model will be used.
  - Context window size and cache TTL are used to inform context compaction.
  - For providers that report it, context window size is automatically fetched via API.
  - For Anthropic models, setting the cache above 300s uses Anthropic's 1 hour cache declaration. *(Other providers don't currently publish cache times.)*
- In Editor Settings > GDLLM > Models, specify your preferred default chat model and tasks model. The tasks model powers summarization and title generation.
- Review Editor Settings > GDLLM and update to your preference. Some color-blind users may want to adjust their colors.

## Gemini integration notes

Two kinds, two routes, two distinct bases — picked automatically from each source row's `kind`:

| Kind            | Base                                               | Auth                                              | Surface                                                                   | Billing                                        |
| --------------- | -------------------------------------------------- | ------------------------------------------------- | ------------------------------------------------------------------------- | ---------------------------------------------- |
| `gemini` (BYOK) | `https://generativelanguage.googleapis.com/v1beta` | `x-goog-api-key: AIza…`                           | native `:streamGenerateContent?alt=sse`                                   | Per-token on your GCP project                  |
| `gemini-oauth`  | `https://cloudcode-pa.googleapis.com`              | `Authorization: Bearer ya29…/1//…` (Google OAuth) | Cloud Code Assist envelope at `/v1internal:streamGenerateContent?alt=sse` | Plan-covered (Google AI plan), whitelist-gated |

Both kinds share the **native Gemini wire shape** (`contents[]` + `parts[]`, `systemInstruction`, `functionCall` / `functionResponse`, `usageMetadata`). The OAuth route only diverges by wrapping the same body in the Cloud Code Assist envelope `{project, model, request, requestType, userAgent, requestId}`.

### Tool calling — `thought_signature`

`Gemini 3.x Flash` (and `Gemini 2.5+`) thinking models attach an opaque `thought_signature` to every `functionCall` / `functionResponse` part they emit, and reject the next tool-loop request with `400 Function call is missing a thought_signature` when the signature isn't echoed back. `GeminiAdapter` reads the signature from each functionCall part on response and replays it on the next turn's `parts[]` — `thoughtSignature` is a **sibling** of `functionCall`, never a child, per Google's REST reference.

### JSON-Schema tool definitions

Gemini's `OpenApi` schema dialect rejects 22 common JSON-Schema keywords (`$schema`, `$ref`, `additionalProperties`, `exclusiveMinimum` / `exclusiveMaximum`, `minimum` / `maximum`, `pattern`, `format`, `minLength` / `maxLength`, …) with `Unknown name "…" at …`. `GeminiAdapter._clean_json_schema` strips them recursively before send. Model clients (Kilo Code, Continue, the OpenAI SDK, gdllm itself) generate schemas with these keywords by default; without the scrubber tool calls silently 400.

### Currently shipping Gemini models (as of 2026-09)

The Google AI Studio catalogue currently lists (alongside their Gemini 2.5 predecessors):

- **`gemini-3.1-pro-preview`** — top-of-line reasoning, 1M context, vision, tool calling, 12k output. Replaces Gemini 2.5 Pro as the high-capability choice.
- **`gemini-3.8-flash`** / `3.7-flash` / `3.6-flash` — Flash generation, 1M context, vision, tool calling. The default coding/agentic workhorses.
- **`gemini-3.5-flash`** + `gemini-3.5-flash-lite` — preview generation, 1M context, lower cost.
- **`gemini-3.1-flash-lite`** + preview — fastest and cheapest, 1M context.
- **`gemini-2.5-pro`** / `gemini-2.5-flash` / `flash-lite` — still served; choose these when you need an extra-stable response shape.

OpenRouter (`https://openrouter.ai/api/v1`) exposes all of the above plus the dedicated image models (Gemini 3 Pro Image / Nano Banana Pro, Gemini 3.1 Flash Image / Nano Banana 2, Gemini 2.5 Flash Image / Nano Banana) under the `google/` prefix, behind a single OpenAI-compatible endpoint.

### Setting up Antigravity OAuth

1. Open the Connections dialog and enable the **Google Gemini (Antigravity)** source row. The kind is `gemini-oauth`; the base is prefilled to `cloudcode-pa.googleapis.com`.
2. Press **Sign in with Google**. A browser tab opens to Google's consent screen; the access token + refresh token are stored in Editor Settings; `loadCodeAssist` resolves the Cloud Code Assist project id at sign-in and persists it alongside the tokens.
3. Pick a model from `fetchAvailableModels` once the sign-in finishes.

The default client id / secret are the official Antigravity CLI public credentials (intentionally public, see `gdllm_gemini_oauth.gd`'s header comment). To use a private Google Cloud OAuth client, set `gdllm/connection/gemini_oauth_client_id` and `gdllm/connection/gemini_oauth_client_secret` in Editor Settings before signing in.

## Roadmap

While this harness is ready-to-use as is, there are a few additional features I'm still interested in adding.

- Support for vision-capable models. (The harness currently has no way to "see" beyond inspecting the game.)
- First-class tools supporting GridMap
- First-class tools supporting mesh/geometry authoring
- Session feedback and note system (e.g. flagging a session as good output, bad output, or adding session notes)
- First-class support for additional inference providers.

## Contributions

Contributions are welcome, including LLM generated or assisted contributions, however **all text communication must be human-authored.** Entirely autonomous issues or pull requests will be closed.

Changes should be supported by your own benchmarking/testing; It's expected that you have done the diligence to run the same prompt before and after changes 10-30x to ensure the changes are improving completion rate, reducing the average tokens per task, or reducing the average number of turns.
