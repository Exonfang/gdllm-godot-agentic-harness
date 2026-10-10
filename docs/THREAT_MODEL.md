# Local agent threat model

GDLLM connects an untrusted model to a trusted local Godot editor. A project can
also contain untrusted or third-party source, scenes, resources, instructions,
skills, symlinks, and imported assets. The security boundary is therefore not
"local versus remote"; it is the user's explicit capabilities versus every
model- or project-controlled input.

## Protected assets

- Project source and configuration integrity.
- Files outside `res://` and `user://`.
- Git and Godot editor state, session transcripts, and provider credentials.
- OAuth access and refresh tokens, API keys, HTTP headers, logs, and tool
  results which may contain them.
- The editor process and any project code it can load or execute.

## Capability model

Every session receives an immutable capability snapshot. Absence is denial.
Capabilities are independent: reading project text, reading outside the two
local roots, executing project code, controlling the editor, mutating project
files, deleting files, and changing project settings. A stale or hallucinated
tool call is checked again at dispatch; hiding a schema is not an authorization
boundary.

Safe reads use `FileAccess` and text parsers only. They do not compile scripts,
load scenes/resources, start the project, or run automatic validation. Tools
which invoke `ResourceLoader`, the Godot compiler, a project run, an autoload,
project-defined property getters, or editor execution require the project-code
execution capability explicitly.

Project instruction files and skills are delimited and quoted as untrusted data.
They can provide project context, but cannot grant capabilities, enable tools,
override host instructions, request credentials, or authorize mutations.

## Filesystem containment

Paths are normalized and every existing component is inspected. Symbolic links,
Windows junctions, and other links are resolved before deciding whether the
destination is inside `res://`, `user://`, or an explicitly enabled external
tree. Internal links are allowed; links which escape the allowed roots are not.
Recursive walks skip links and hidden directories, and cycles fail closed.
Source, destination, sidecar, and deletion paths use the same policy.

Protected paths cannot enter model context even by an exact file-scoped read or
search. This includes the plugin session and credential stores, `.git`, `.godot`,
`.env` variants, common private-key files, and common credential files.

Godot's GDScript API does not expose atomic no-follow file handles. Resolution
is repeated immediately before operations, and canonical targets are used after
link resolution, but a hostile local process with concurrent filesystem access
can still race a path between validation and open. Hard links are likewise not
distinguishable through the portable GDScript API. Install the plugin only in
projects and accounts whose local filesystem peers are trusted.

## Credentials, sessions, and redaction

Credentials are removed from `EditorSettings` and stored separately in an
editor-wide file below the operating system's per-user configuration directory
(`Godot/gdllm/credentials.json`). This preserves the global scope of the legacy
settings instead of silently tying them to one project's `user://`. Migration
writes and verifies the new store before deleting legacy plaintext. On
Unix-like systems the file requests mode `0600`. Godot exposes no supported
cross-platform OS keychain or Windows ACL API to GDScript, so this backend is
explicitly reported as restricted plaintext, not as encrypted storage. The
Windows per-user directory reduces accidental exposure but does not protect
against another process running as the same user.

A central redactor scrubs registered secrets and conservative credential/token
patterns at HTTP, OAuth, console, tool-result, and persistence boundaries.
Redaction is defense in depth, not a reason to place secrets in prompts or logs.
Session histories remain plaintext local records, request mode `0600` on
Unix-like systems, and are redacted again at serialization. They may still
contain ordinary sensitive project data that is not a registered credential;
users should protect and delete them according to the project's sensitivity.

## Project settings and autoloads

Installing the plugin does not silently add an autoload. Project-setting changes
are opt-in, require the settings capability, record ownership, snapshot the old
state, save and verify the result, and roll back on failure. Removal only touches
state owned by this plugin; a name collision is refused rather than overwritten.

## Out of scope and residual risk

- A user who grants execution can run arbitrary project code with the editor's
  operating-system privileges.
- A user who grants external reads or mutations expands the filesystem boundary
  deliberately; protected credential/session stores remain denied.
- A provider receives the prompts and non-redacted project data the user elects
  to send. Provider-side retention and compromise are outside this plugin.
- Pattern redaction cannot prove that arbitrary high-entropy project text is or
  is not a secret. Exact credentials loaded by the store are registered for
  deterministic replacement.
- Compromise of the editor process or same-user account defeats local controls.
