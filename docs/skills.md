# Skills

A skill is a Markdown file of instructions for one kind of task in your project. The agent sees only each skill's name and a one-line description. When a task matches one, it reads the full instructions with the `use_skill` tool before starting the work.

Skills are a good fit for project knowledge the agent couldn't infer: your conventions, your folder layout, the steps your team follows for a recurring job.

## Where skills live

Put skills in `res://skills/`, at the top level, in either layout:

```
res://skills/
├── new-enemy/
│   └── SKILL.md          # directory layout: the folder name is the fallback skill name
└── signal-naming.md      # flat layout: the file name is the fallback skill name
```

- In the directory layout, the file must be named `SKILL.md`. Any capitalization is found, but if a folder holds more than one spelling, only `SKILL.md` is read and you're warned about the others.
- Only the top level is scanned. A skill nested deeper than `res://skills/<folder>/SKILL.md` isn't found.

## Writing a skill

A skill file can start with an optional frontmatter block giving its name and description:

```markdown
---
name: new-enemy
description: How to add a new enemy type — scene layout, required scripts, and registration in the spawn table.
---

# Adding an enemy

1. Duplicate `res://enemies/_template/enemy_template.tscn` into `res://enemies/<name>/`.
2. ...
```

- **`name`** is what the agent calls the skill by. Without it, the folder name (directory layout) or file name (flat layout) is used.
- **`description`** is the one line the agent sees while deciding whether the skill applies, so it's the most important line in the file. Say what task it covers, specifically enough that the agent recognizes the match.
- Without a description, the first non-empty line of the body is used, trimmed to a length set by the **Skill Fallback Description Chars** editor setting (GDLLM > Tool Output, default 120).
- Other frontmatter keys are allowed and ignored.

Everything after the frontmatter is the body, which the agent receives in full when it calls `use_skill`.

## What the agent sees

The system prompt gets one section listing every skill:

```
## Skills

This project defines skills — its own instructions for specific kinds of task, stored under res://skills. When a skill's description matches the task at hand, read its full instructions with the use_skill tool before doing that work.
- new-enemy: How to add a new enemy type — scene layout, required scripts, and registration in the spawn table.
- signal-naming: ...
```

`use_skill` accepts the skill's name exactly, any capitalization of it, or its file or folder name. A name that matches nothing returns the list of real names, so the agent can correct itself in one step.

## Updating skills

Skills are re-checked before each message you send, and only re-read when a file actually changed, so edits take effect on your next message. The chat log notes when the skills list changes, so you can see what the agent is now told.

## Name conflicts

If two skills end up with the same name, the chat shows a warning naming both files:

- A directory-layout skill wins over a flat file with the same name. The flat file isn't listed.
- Two flat files with the same name are both kept. The first answers to the shared name, and the other stays reachable by its file name.

Rename one of the files to clear the warning.

## Tips

- Keep each skill focused on one kind of task. The agent picks skills by description, and a vague catch-all one is hard to match.
- Write steps the agent can verify. "Run `check_script` on the new script" works better than "make sure it's correct".
- If a step is purely mechanical, consider a [custom tool](custom-tools.md) instead, and have the skill tell the agent when to call it.
