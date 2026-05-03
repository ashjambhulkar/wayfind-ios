# Cursor Agent Chat Metrics (hooks + status bar extension)

Cursor does **not** expose real context-window percentage, per-turn billed tokens, or dollars to third-party extensions. The chat meter in Cursor’s UI is the authoritative context readout; billing is on [cursor.com/dashboard/usage](https://cursor.com/dashboard/usage).

This tool gives you:

1. **Turn counter** — counts each **user** prompt (`beforeSubmitPrompt`) per composer session (`sessionStart` resets).
2. **macOS notifications** — when prompt count is in your configured band (default 10–15), and once when you exceed it.
3. **Proxy “tokens”** — `(user chars + assistant chars) / chars_per_token`. This is **not** the model’s real token count (rules, files, and full history are missing).
4. **Heuristic cumulative $** — your configured $/1M × those proxies. **Not your invoice**; useful for relative comparison only.

## 1. Install hooks (required)

### Option A — Global (recommended)

1. Copy the `hooks` folder from this directory to `~/.cursor/hooks/` (same names: `track_agent_metrics.py`, `run_metric_hook.sh`).
2. Merge the contents of `hooks.json.example` into `~/.cursor/hooks.json`. If you already have hooks, **append** to each event array rather than replacing the whole file.
3. `chmod +x ~/.cursor/hooks/run_metric_hook.sh ~/.cursor/hooks/track_agent_metrics.py`
4. (Optional) Copy `config.example.json` to `~/.cursor/agent-chat-metrics/config.json` and edit prices to match the model you usually bill against.
5. Restart Cursor. Confirm in **Settings → Hooks** and the **Hooks** output channel.

### Option B — This repo only

Copy `hooks/` into `<repo>/.cursor/hooks/` and merge `hooks.project.json.example` into `<repo>/.cursor/hooks.json` (note: this repo’s `.gitignore` ignores `.cursor/` by default, so this is best for local experiments unless you adjust ignore rules).

## 2. Install the status bar extension (optional)

The extension only **reads** `~/.cursor/agent-chat-metrics/current.json` (written by the hook). It does not talk to Cursor’s billing API.

**Where stats appear**

- **Top menu bar:** **AgentMetrics** (extension v0.3+) — *Open live metrics tab*, *Pick chat session…*, *Refresh live metrics tab*. If the menu entry is hidden, use the Command Palette with the same titles.
- **Editor tab strip (“top tabs”):** command **“Cursor Agent Metrics: Open live metrics tab”** opens a virtual read-only document that auto-refreshes (~2s). The **editor title bar** shows a refresh action when that tab is active.
- **Status bar** (left) and **Activity Bar** “Agent metrics” webview — same data as `current.json`.

Cursor still does **not** allow extensions to paint *inside* the Agent chat webview.

**Per-chat switching:** Each chat has a stable `conversation_id`. Hooks update `state.json` per id; `current.json` reflects the **active** chat. When you focus another Agent tab, the next hook with that id updates the display. If focus alone does not fire a hook yet, use **Pick chat session…** to point `current.json` at a saved conversation. If **transcripts** are enabled, `sessionStart` can **resync** counts from `transcript_path` (JSONL under `.cursor/projects/.../agent-transcripts/`); parsing is best-effort.

**Which model:** Cursor’s hook **common schema** includes `model` (composer model for that session). The script records `last_model` and `models_seen`, picks **$/1M** from `model_price_overrides` (first substring match) or falls back to `price_per_million_*`. If a hook ever omits `model`, pricing uses the defaults until a model arrives.

```bash
cd tools/cursor-agent-chat-metrics/vscode-extension
npm install
npm run compile
```

Then in Cursor: **Extensions → … → Install from VSIX…** is not built by default; instead use **Run Extension** from a dev host, or package with `@vscode/vsce` if you install it globally:

```bash
npx @vscode/vsce package
code --install-extension cursor-agent-chat-metrics-0.1.0.vsix
```

Or run `F5` in a VS Code window opened on `vscode-extension/` to debug the extension in an Extension Development Host.

## 3. Optional: count reasoning blocks in cost

Set `"include_thinking_as_output": true` in `config.json` and add an `afterAgentThought` hook (same `run_metric_hook.sh afterAgentThought` pattern with matcher `AgentThought` per Cursor docs).

## Files written at runtime

| Path | Purpose |
|------|---------|
| `~/.cursor/agent-chat-metrics/state.json` | Full per-session history |
| `~/.cursor/agent-chat-metrics/current.json` | Last active session snapshot for the status bar |

## Privacy

Hooks receive prompt text and assistant text on your machine only; this script does not send data to the network.
