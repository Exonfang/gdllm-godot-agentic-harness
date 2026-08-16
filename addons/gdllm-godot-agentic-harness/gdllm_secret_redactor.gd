@tool
class_name GDLLMSecretRedactor extends RefCounted
## Central, fail-safe scrubbing for text that can leave a local trust boundary through
## tool output, the editor console, HTTP diagnostics, or OAuth errors.
##
## Exact credentials are registered when loaded. Conservative structural patterns
## cover common bearer/API-key/JWT shapes in provider replies without attempting to
## "detect" arbitrary high-entropy user text.

const REDACTED := "[REDACTED]"
static var _exact: Dictionary = {}
static var _compiled_patterns: Array[RegEx] = []


## Remember one explicit credential for exact replacement. This is not a
## heuristic: even a short real key must not survive a persistence/log boundary.
static func register_secret(secret: String) -> void:
	if not secret.is_empty():
		_exact[secret] = true


## Register every string below a token/key-shaped field in a nested value.
static func register_variant(value: Variant, key_hint: String = "") -> void:
	if value is Dictionary:
		for key in value:
			register_variant(value[key], String(key))
	elif value is Array:
		for item in value:
			register_variant(item, key_hint)
	elif value is String and _sensitive_key(key_hint):
		register_secret(String(value))


static func clear_registered() -> void:
	_exact.clear()


## Scrub registered values first, then credential-bearing header/JSON assignments
## and well-known standalone token shapes. The result is safe to relay or log.
static func redact(text: String) -> String:
	var out := text
	var secrets: Array = _exact.keys()
	secrets.sort_custom(func(a: Variant, b: Variant) -> bool: return String(a).length() > String(b).length())
	for secret in secrets:
		out = out.replace(String(secret), REDACTED)
	for pattern in _patterns():
		out = _replace_group(out, pattern)
	return out


## Deep-copy a structured value while scrubbing every string leaf. Useful for
## diagnostic dictionaries which should retain their shape.
static func redact_variant(value: Variant) -> Variant:
	if value is Dictionary:
		var clean := {}
		for key in value:
			clean[key] = redact_variant(value[key])
		return clean
	if value is Array:
		var clean: Array = []
		for item in value:
			clean.append(redact_variant(item))
		return clean
	if value is String:
		return redact(String(value))
	return value


static func _sensitive_key(key: String) -> bool:
	var normalized := key.to_lower().replace("-", "_")
	return normalized in ["api_key", "apikey", "access_token", "refresh_token", "id_token", "authorization", "password", "secret"]


static func _patterns() -> Array[RegEx]:
	# Compiled on demand instead of at script parse time so this utility remains
	# loadable in headless tests before the editor class cache exists.
	if not _compiled_patterns.is_empty():
		return _compiled_patterns
	var expressions := [
		# Prefix/capture/suffix. Only capture group 2 is replaced.
		"(?i)(authorization\\s*:\\s*(?:bearer|basic)\\s+)([^\\s,;]+)",
		"(?i)((?:x-api-key|api-key)\\s*:\\s*)([^\\s,;]+)",
		"(?i)([\\\"']?(?:api[_-]?key|access[_-]?token|refresh[_-]?token|id[_-]?token|password|client[_-]?secret)[\\\"']?\\s*[:=]\\s*[\\\"']?)([^\\\"'\\s,}]+)",
		# Standalone OpenAI-style keys and JWTs. Group 1 is deliberately empty.
		"()((?:sk|sess)-[A-Za-z0-9_-]{16,})",
		"()([A-Za-z0-9_-]{12,}\\.[A-Za-z0-9_-]{12,}\\.[A-Za-z0-9_-]{8,})",
	]
	for expression in expressions:
		var regex := RegEx.new()
		if regex.compile(expression) == OK:
			_compiled_patterns.append(regex)
	return _compiled_patterns


static func _replace_group(text: String, regex: RegEx) -> String:
	var out := text
	var offset := 0
	while true:
		var hit := regex.search(out, offset)
		if hit == null:
			break
		var start := hit.get_start(2)
		var end := hit.get_end(2)
		if start < 0 or end <= start:
			break
		out = out.substr(0, start) + REDACTED + out.substr(end)
		offset = start + REDACTED.length()
	return out
