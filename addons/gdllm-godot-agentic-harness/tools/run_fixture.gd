extends SceneTree
## Fixture for run_tools_test.gd's end-to-end run_script check: prints a sentinel carrying its user args and exits cleanly, proving execution, argument passing, and exit-code relay in one run.


func _init() -> void:
	print("GDLLM_RUN_FIXTURE %s" % " ".join(OS.get_cmdline_user_args()))
	quit(0)
