# Custom tools

A custom tool is a GDScript file that becomes a tool the agent can call, alongside GDLLM's built-in tools. Use one when your project has a mechanical job with a fixed answer that the agent would otherwise piece together over several calls.

Custom tools run **inside the editor**, so they can use `EditorInterface`, the scene open in the editor, and anything else editor code can reach.

## Where tools live

Put each tool in `res://gdllm-tools/` as `<name>.gd`, at the top level:

```
res://gdllm-tools/
├── list_group.gd        # the tool is named "list_group"
└── rebuild_locale.gd
```

The file name is the tool name. It may contain letters, digits, `_` and `-`, up to 64 characters, and can't reuse a built-in tool's name.

## Writing a tool

```gdscript
@tool
extends RefCounted

const DESCRIPTION := "Lists the nodes in a group in the scene open in the editor, one line each with its path and type. Use it to find the spawn points, pickups, or other grouped nodes in a level."
const SUMMARY := "List the open scene's nodes in a group, with paths and types."
const PARAMETERS := {
	"type": "object",
	"properties": {
		"group": {"type": "string", "description": "The group name, e.g. \"enemies\"."},
	},
	"required": ["group"],
}
const READ_ONLY := true


func execute(args: Dictionary) -> String:
	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		return "Error: no scene is open in the editor. Ask the user to open the level first."
	var group := String(args.get("group", ""))
	if group == "":
		return "Error: no group was given. Pass it as {\"group\": \"enemies\"}."
	var lines := PackedStringArray()
	for node in root.find_children("*", "", true, false):
		if node.is_in_group(group):
			lines.append("%s (%s)" % [root.get_path_to(node), node.get_class()])
	if lines.is_empty():
		return "No nodes in group \"%s\" in %s." % [group, root.scene_file_path]
	return "\n".join(lines)
```

| Part | Required | Meaning |
| --- | --- | --- |
| `@tool` on the first line | Yes | Without it the editor can't run the script. |
| `extends RefCounted` | Yes | A fresh instance is created for every call. |
| `const DESCRIPTION` | Yes | The full explanation the agent gets once it looks the tool up: what it does, what it returns, when to use it. |
| `const SUMMARY` | No | The one line shown in the tool catalog. Defaults to the first line of `DESCRIPTION`. |
| `const PARAMETERS` | No | A [JSON Schema](https://json-schema.org/understanding-json-schema/reference/object) object describing the arguments. Defaults to no arguments. |
| `const READ_ONLY := true` | No | Declares that the tool only reads. Without it, the tool is treated as one that changes the project (see [Permissions](#permissions)). |
| `const DESTRUCTIVE := true` | No | Declares that the tool deletes files. |
| `func execute(args: Dictionary) -> String` | Yes | Runs the tool. `args` holds what the agent passed. It may `await`. |

### What `execute` should return

- Return a `String`. A `Dictionary` or `Array` is sent as JSON, and anything else is converted with `str()`.
- Return only what the agent needs. The result goes into the conversation, and keeping it small is the main advantage of a tool over a skill.
- The arguments come from a model and may be missing or the wrong type. Check them, and when something's wrong, return an error that says how to fix it, like the example does. The agent reads that and retries.
- If `execute` hits a runtime error, the agent is told the tool returned nothing and pointed to `read_errors`, which shows the error.

## How the agent finds tools

Custom tools work exactly like built-in ones. The `tool_search` tool's catalog lists every tool by name, arguments and summary:

```
- list_group(group): List the open scene's nodes in a group, with paths and types.
```

The full description and parameter schema are only sent once the agent searches for the tool, so an idle tool costs one catalog line.

## Permissions

Custom tools follow the same per-session toggles as the built-in tools:

| Tool declares | Available when |
| --- | --- |
| `READ_ONLY := true` | Always |
| neither | **Make changes** is on |
| `DESTRUCTIVE := true` | **Make changes** and **Delete files** are both on |

While a toggle is off, the tools it gates are hidden from the agent. If the agent calls one anyway, it's told which toggle to ask you for.

## Approval for tools the agent writes

Because tools run inside the editor, GDLLM won't load a tool the agent wrote until you've reviewed it:

- **Files you write** load on their own.
- **Files the agent creates or changes** wait for your approval. A change counts as the agent's if it happens while any tool call is running, which covers files written through `run_script` or another custom tool, or while a game is running.
- When a call leaves a tool waiting, its result says so, and the agent is asked to tell you.
- Approval covers the exact content you reviewed. If the agent changes an approved tool, it needs approval again.
- Pending tools stay pending across editor restarts.

Approvals and enable choices are stored in `user://gdllm/custom_tools.json`, in Godot's per-project user data folder, not your project. If that file becomes unreadable, every tool not already approved waits for approval instead of loading.

> [!NOTE]
> If you edit a tool yourself while the agent is in the middle of a call, or while a game is running, your edit is treated as the agent's and needs approval. Approve it in the Custom Tools dialog.

## The Custom Tools dialog

Open it with the **🔧** button beside the model picker. It lists every file in `res://gdllm-tools/`:

| Status | Meaning |
| --- | --- |
| **Loaded** | Offered to the agent. |
| **Disabled** | You unchecked it, so it's hidden from the agent. |
| **Needs approval** | The agent created or changed it. Use **Review & approve…**. |
| **Load error** | It couldn't load. Hover the status for the reason and how to fix it. |

- The checkbox turns a tool on or off for every session.
- **Review & approve…** shows the tool's source as plain text and doesn't run any of it. **Approve** loads exactly what you read; if the file changed while you were reading, the review reopens on the new version.
- **View source** shows any tool's source.

## Load errors

A tool that fails to load stays out of the catalog. The agent is told the tool exists and why it failed, so it asks you rather than assuming the tool is missing. Common causes:

| Error | Fix |
| --- | --- |
| Missing `@tool` | Add `@tool` as the first line. |
| Doesn't compile | Ask the agent to run `check_script` on the file, or open it in the script editor. |
| No `DESCRIPTION` | Add `const DESCRIPTION := "..."`. |
| Must extend `RefCounted` | Change the `extends` line. |
| No `execute` function | Add `func execute(args: Dictionary) -> String`. |
| Built-in tool's name | Rename the file. Built-in tools always win. |
| Invalid tool name | Rename the file using letters, digits, `_` or `-`. |

## Updating tools

Tools are re-checked whenever the agent's tool list is built, so a change to a file you wrote takes effect on your next message. Adding, removing or changing a tool alters the catalog, which makes the provider's prompt cache miss once.

> [!WARNING]
> A tool runs in the editor process. A tool stuck in an infinite loop freezes the editor, and one that changes the open scene changes it for real. Keep tools small, and declare `READ_ONLY` only on tools that truly don't change anything.
