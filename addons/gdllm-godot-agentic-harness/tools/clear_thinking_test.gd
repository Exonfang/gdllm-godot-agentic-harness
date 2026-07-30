extends SceneTree
## Headless regression tests for "Clear Thinking": clearing must strip reasoning from every place it is stored — the display fields (thinking/thinking_seconds) and the thinking/redacted_thinking blocks inside a provider echo (assistant_blocks) — while leaving the echo's text and tool_use blocks intact, so a cleared session neither shows traces nor re-sends them (see GDLLMSessionStore.strip_echo_thinking).
## Run from the project root:
##   godot --headless --path . --script res://addons/gdllm-godot-agentic-harness/tools/clear_thinking_test.gd
## Exits nonzero on any failure. The real user://gdllm/sessions.json is backed up before the store is touched and restored afterward, so running this against a live project loses nothing.

const STORE_PATH := "user://gdllm/sessions.json"

var _checks := 0
var _failures := 0


func _init() -> void:
	var backup := _read_store()
	_run_tests()
	_restore_store(backup)
	print("%s: %d checks, %d failures" % ["FAIL" if _failures > 0 else "OK", _checks, _failures])
	quit(1 if _failures > 0 else 0)


func _check(cond: bool, label: String) -> void:
	_checks += 1
	if not cond:
		_failures += 1
		print("FAIL: %s" % label)


func _run_tests() -> void:
	var history: Array = [
		{"role": "user", "content": "hi", "attachments": [], "text": "hi"},
		{"role": "assistant", "content": "", "model": "m", "thinking": "SECRET_TRACE_A", "thinking_seconds": 1.5, "tool_calls": [
			{"function": {"name": "read_file", "arguments": {"path": "a.gd"}}},
		], "assistant_blocks": [
			{"type": "thinking", "thinking": "SECRET_TRACE_A", "signature": "sig_a"},
			{"type": "redacted_thinking", "data": "SECRET_REDACTED"},
			{"type": "text", "text": "Reading the file."},
			{"type": "tool_use", "id": "toolu_1", "name": "read_file", "input": {"path": "a.gd"}},
		]},
		{"role": "tool", "tool_name": "read_file", "content": "config_version=5..."},
		{"role": "assistant", "content": "Done.", "model": "m", "thinking": "SECRET_TRACE_B", "thinking_seconds": 2.0},
	]
	var record := {"id": "s_think_1", "title": "Traces", "model": "m", "created": 1, "updated": 2, "is_open": false, "history": history}
	_write_store(JSON.stringify({"active": "s_think_1", "make_changes": false, "sessions": [record]}))

	var store := GDLLMSessionStore.new()
	store.load()
	_check(store.clear_thinking("s_think_1"), "clearing a session with traces reports a change")
	var cleared: Array = store.sessions[0]["history"]
	for msg in cleared:
		_check(not msg.has("thinking") and not msg.has("thinking_seconds"), "no display trace survives on any message")
	var blocks: Array = cleared[1].get("assistant_blocks", [])
	_check(blocks.size() == 2, "only the echo's thinking blocks are removed")
	_check(String(blocks[0].get("type", "")) == "text" and String(blocks[1].get("type", "")) == "tool_use", "the echo keeps its text and tool_use blocks in order")
	_check(String(blocks[1].get("id", "")) == "toolu_1", "the surviving tool_use keeps its real id for result pairing")
	_check(int(store.sessions[0]["updated"]) == 2, "clearing traces does not bump the last-message timestamp")
	_check(not store.clear_thinking("s_think_1"), "a second clear is a no-op")

	store.flush()
	_check(not FileAccess.get_file_as_string(STORE_PATH).contains("SECRET"), "no trace text survives on disk after the flush")

	# An echo that was nothing but reasoning loses the field entirely, so the adapter falls back to rebuilding the turn.
	var only_thinking := {"assistant_blocks": [{"type": "thinking", "thinking": "x", "signature": "s"}]}
	_check(GDLLMSessionStore.strip_echo_thinking(only_thinking), "an all-thinking echo reports a change")
	_check(not only_thinking.has("assistant_blocks"), "an all-thinking echo is dropped, not left empty")
	_check(not GDLLMSessionStore.strip_echo_thinking({"role": "assistant", "content": "hi"}), "a message without an echo is untouched")


## The store file's current text, or null when none exists — the distinction _restore_store needs to put things back exactly.
func _read_store() -> Variant:
	if not FileAccess.file_exists(STORE_PATH):
		return null
	return FileAccess.get_file_as_string(STORE_PATH)


func _write_store(text: String) -> void:
	DirAccess.make_dir_recursive_absolute(STORE_PATH.get_base_dir())
	var file := FileAccess.open(STORE_PATH, FileAccess.WRITE)
	file.store_string(text)
	file.close()


func _restore_store(backup: Variant) -> void:
	if backup == null:
		DirAccess.remove_absolute(STORE_PATH)
		return
	_write_store(String(backup))
