# Local MCP access

Start the stdio server with the project whose reviewed profiles and capture files the assistant may use:

```sh
runalong mcp --project /absolute/path/to/flutter/project
```

Configure a stdio-capable MCP client with executable `runalong` and arguments:

```json
{
  "command": "runalong",
  "args": ["mcp", "--project", "/absolute/path/to/flutter/project"]
}
```

The surrounding settings key depends on your MCP client. Ensure the executable is available to the client's environment, or use its absolute installed path.

## Tools

| Tool | Purpose |
| --- | --- |
| `list_profiles` | List saved project profiles |
| `start_run` | Start a named profile and return a run ID promptly |
| `get_run` | Read the state of a run |
| `cancel_run` | Cancel one active run and finalize available evidence |
| `get_report` | Read compact metadata/metrics and up to 20 slowest measured frames |
| `list_journey` | Page through recorded tests, screen visits and operations (up to 100 per page) |
| `get_finding_evidence` | Read bounded evidence for an `itemId` from the journey or frame findings |
| `compare_runs` | Compare two finalized runs without changing either baseline |

Only reviewed configuration profiles can start commands. The tool accepts a profile name, not arbitrary shell text. One run is active at a time. Full JSON/HTML artifacts remain on disk; the compact report keeps large frame arrays out of an assistant's context.

Run states distinguish `completed` (exit 0), `cancelled` (130), `timed_out` (124), and `failed` (other nonzero exits), including after a server restart. MCP artifacts are saved under the server project’s `.runalong/runs`, even when a profile runs its command from a different working directory.

End-of-input disconnect cancels the active run and preserves available evidence. A disconnected or cancelled run is not a successful complete capture.

## Useful assistant requests

- “Run the existing smoke profile and report automation, capture, and budget status separately.”
- “Compare these two run IDs. Explain whether the environment makes this comparison valid.”
- “Identify the worst measured rendering window and suggest a specific follow-up experiment.”
- “List the recorded login operations, inspect the slowest one's evidence, and distinguish observed runtime locations from source candidates.”

The optional [skill](../skills/runalong/SKILL.md) reinforces these interpretation rules. It does not authorize changing thresholds, replacing a baseline, or running unrequested experiments.

## Protocol check

The adapter uses the experimental `dart_mcp` SDK (`^0.5.2`) for protocol handling. Cross-language interoperability is verified with negotiated protocol version `2025-11-25`; other client/version combinations remain unverified. Runalong uses ordinary MCP tools, without optional task extensions.

The repository includes `tool/mcp_smoke.py`, a Python standard-library client exercising the actual CLI over stdio. Run it after `dart pub get`. This checks the tool interface without requiring a device.
