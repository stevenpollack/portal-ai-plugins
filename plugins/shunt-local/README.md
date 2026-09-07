# shunt-local

A Claude Code plugin that shunts I/O-heavy work to cheaper local subagents. Same idea as [shunt](../shunt/README.md), no Portal CLI or AiKA: the workers are Claude Code subagents on smaller models.

## How it works

1. **Hook** — `hooks/check-read` fires before every `Read` and `Bash` call on the main thread. A full read of a file over 350 lines is denied with a reason that tells Claude to delegate to the `bulk-reader` agent.
2. **Agents** — `bulk-reader` (haiku) reads the files in its own context and returns bullets. `code-writer` (sonnet) generates boilerplate from a spec plus reference files, writes it to disk, and returns only the path and line count.

A subagent's tool results never enter the parent context, so the file is read once by the cheap model and Claude sees only the answer. The hook detects the `agent_id` field that Claude Code adds inside subagents and lets their reads through, so the worker is never gated.

## Prerequisites

- [`jq`](https://jqlang.org) — `brew install jq`

```bash
claude plugin marketplace add spotify/portal-ai-plugins
claude plugin install shunt-local@portal
```

## Plugin structure

```
shunt-local/
├── .claude-plugin/plugin.json
├── hooks/
│   ├── hooks.json           # PreToolUse matcher Read|Bash
│   └── check-read           # Denies full reads of files > 350 lines on the main thread
├── agents/
│   ├── bulk-reader.md       # haiku: read files, answer one question in bullets
│   └── code-writer.md       # sonnet: generate boilerplate to disk from spec + reference
└── evals/
    ├── run.sh               # Hook evals (36 cases)
    ├── hook-evals.json      # Read cases
    └── bash-hook-evals.json # Bash cases
```

## Agents

Claude picks them from their descriptions, or you name them:

```text
@"shunt-local:bulk-reader (agent)" what does src/Service.java export, and which methods hit the database?
@"shunt-local:code-writer (agent)" write tests for UserService into tests/UserTest.java, matching tests/OrderTest.java
```

Each call stands alone: re-asking with the same paths costs the parent nothing, because the files go to the worker and never into the parent's context. Verify specific line numbers or exact values before using them in edits.

## Hook

Allows through:
- Targeted reads (`offset` or `limit` set)
- Piped commands (`cat file | grep`) and redirections (`cat file > out`)
- Files under the threshold, nonexistent files, non-read commands
- Any call made inside a subagent (`agent_id` present)

Allow is silence: the hook emits nothing and the normal permission flow decides. Only denials emit a `hookSpecificOutput.permissionDecision`.

## Configuration

| Variable | Default | Purpose |
|----------|---------|---------|
| `SHUNT_MIN_LINES` | `350` | Line count above which the hook denies a full read |

Set it in the `env` block of `.claude/settings.json`.

## What doesn't get delegated

- **Debugging** — requires Claude's reasoning, not a summary
- **Editing** — Claude needs exact content in context; use targeted reads (offset/limit)
- **Small files** — delegation overhead exceeds savings under 350 lines
- **Architectural decisions** — judgment calls stay on Claude

## Evals

```bash
bash plugins/shunt-local/evals/run.sh
```

## Known limitations

- **No enforcement for code-writer** — only large reads are gated. Code-writer relies on Claude recognizing when to use it from the agent description.
- **Any subagent bypasses the gate** — by design, since no subagent's reads reach the parent, but an expensive subagent reading a huge file is still an expensive read.
- **No token benchmark** — subagent savings can only be measured inside a Claude session, so shunt's `--benchmark` has no equivalent here.
