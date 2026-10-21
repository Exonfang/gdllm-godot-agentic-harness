# gdllm-godot-agentic-harness

A Godot editor plugin: an in-editor agentic harness for LLMs. The driving philosophy behind this plugin is *narrow context* a.k.a. *progressive disclosure*. The main agent starts with almost nothing and pulls in deeper knowledge only as a task demands it, so the conversation stays thin and on-topic. The plugin lives under [addons/gdllm-godot-agentic-harness/](addons/gdllm-godot-agentic-harness/).

## Main goals

Every change should serve these goals. When they seem to conflict, honor both by separating *what the model sees* from *what the user sees* — the codebase already does this.

1. **Minimize context to only what's absolutely necessary.** The model's prompt should carry the least it needs and no more. Don't dump whole files, tools, or histories into the context when a summary, an excerpt, or a fresh-context subagent would do. Prefer pulling detail in on demand over front-loading it.
2. **Never hide anything from the user.** Everything the system does must be visible — every tool call and result, every reasoning trace, every redirect, and every subagent's *inner* run (its own tool calls, results, and thoughts). Nothing the plugin does on the user's behalf should be silent or opaque.
3. **Errors should guide to solutions.** Error messages should guide the agent to the solution.