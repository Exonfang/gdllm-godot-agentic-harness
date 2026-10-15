# GDLLM documentation

Guides for extending GDLLM with your own project-specific knowledge and abilities.

| Guide | What it adds |
| --- | --- |
| [Skills](skills.md) | Written instructions the agent reads when a task calls for them. |
| [Custom tools](custom-tools.md) | GDScript functions the agent can call directly. |

## Skills or a custom tool?

Both stay out of the agent's context until a task needs them. While idle, each costs one short line: a skill's name and description in the system prompt, a tool's name and summary in the `tool_search` catalog.

They differ when used:

- **A skill** loads its whole instruction text, and the agent then carries out the steps with its general tools. That's often several calls, each adding its output to the conversation.
- **A custom tool** is one call that returns only what you chose to return.

Use a **skill** for judgment, conventions and multi-step procedures that need the agent's reasoning: "how we structure a new enemy", "our naming rules for signals".

Use a **custom tool** for anything mechanical with a fixed answer: "list every spawn point in the open level", "rebuild the localization CSV". It's faster, cheaper in tokens, and gives the same result every time.

They work well together. A skill can tell the agent which custom tools to reach for and when.
