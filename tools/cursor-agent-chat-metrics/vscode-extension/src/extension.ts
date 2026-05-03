import * as fs from "fs";
import * as os from "os";
import * as path from "path";
import * as vscode from "vscode";

const METRICS_DIR = path.join(os.homedir(), ".cursor", "agent-chat-metrics");
const CURRENT_FILE = path.join(METRICS_DIR, "current.json");
const STATE_FILE = path.join(METRICS_DIR, "state.json");
const CONFIG_FILE = path.join(METRICS_DIR, "config.json");
const VIEW_ID = "cursorAgentMetrics.panel";
const LIVE_URI = vscode.Uri.parse("cursor-agent-metrics://panel/live-metrics");
const WARN_MIN = 10;
const WARN_MAX = 15;

interface CurrentPayload {
  session_id?: string;
  user_prompts?: number;
  agent_messages?: number;
  cumulative_user_chars?: number;
  cumulative_agent_chars?: number;
  cumulative_thinking_chars?: number;
  proxy_tokens_cumulative?: number;
  estimated_cumulative_cost_usd?: number;
  last_updated?: string;
  last_model?: string | null;
  models_seen?: string[];
  transcript_path_last?: string | null;
  composer_mode?: string;
  pricing_note?: string;
  context_window_note?: string;
}

interface AppConfig {
  chars_per_token?: number;
  price_per_million_input_usd?: number;
  price_per_million_output_usd?: number;
  model_price_overrides?: Array<{
    substring: string;
    input_per_million: number;
    output_per_million: number;
  }>;
}

function readJsonFile<T>(file: string): T | null {
  try {
    return JSON.parse(fs.readFileSync(file, "utf8")) as T;
  } catch {
    return null;
  }
}

function readCurrent(): CurrentPayload | null {
  return readJsonFile<CurrentPayload>(CURRENT_FILE);
}

function readConfig(): AppConfig {
  return readJsonFile<AppConfig>(CONFIG_FILE) ?? {};
}

function resolvePrices(
  model: string | null | undefined,
  cfg: AppConfig,
): { input: number; output: number } {
  const defIn = cfg.price_per_million_input_usd ?? 1.25;
  const defOut = cfg.price_per_million_output_usd ?? 6.0;
  if (!model) {
    return { input: defIn, output: defOut };
  }
  const ml = model.toLowerCase();
  const overrides = cfg.model_price_overrides ?? [];
  for (const row of overrides) {
    const sub = (row.substring ?? "").toLowerCase();
    if (sub && ml.includes(sub)) {
      return {
        input: row.input_per_million ?? defIn,
        output: row.output_per_million ?? defOut,
      };
    }
  }
  return { input: defIn, output: defOut };
}

function buildCurrentPayload(
  convId: string,
  conv: Record<string, unknown>,
  cfg: AppConfig,
): CurrentPayload {
  const charsPerTok = cfg.chars_per_token ?? 4;
  const uc = Number(conv.cumulative_user_chars ?? 0);
  const ac = Number(conv.cumulative_agent_chars ?? 0);
  const proxy = Math.floor((uc + ac) / Math.max(charsPerTok, 0.1));
  const lastModel = (conv.last_model as string | null | undefined) ?? null;
  const prices = resolvePrices(lastModel, cfg);
  const est = recomputeCost(uc, ac, lastModel, cfg);
  return {
    session_id: convId,
    user_prompts: Number(conv.user_prompts ?? 0),
    agent_messages: Number(conv.agent_messages ?? 0),
    cumulative_user_chars: uc,
    cumulative_agent_chars: ac,
    cumulative_thinking_chars: Number(conv.cumulative_thinking_chars ?? 0),
    proxy_tokens_cumulative: proxy,
    estimated_cumulative_cost_usd: Math.round(est * 1_000_000) / 1_000_000,
    last_model: lastModel,
    models_seen: (conv.models_seen as string[]) ?? [],
    transcript_path_last: (conv.transcript_path_last as string) ?? null,
    composer_mode: conv.composer_mode as string | undefined,
    last_updated: (conv.last_updated as string) ?? new Date().toISOString(),
    pricing_note: `Heuristic $ using last_model=${JSON.stringify(lastModel)} → $${prices.input}/M in, $${prices.output}/M out.`,
    context_window_note:
      "Real context % only in Cursor chat. This tab cannot read Cursor’s internal meter.",
  };
}

function recomputeCost(
  userChars: number,
  agentChars: number,
  model: string | null,
  cfg: AppConfig,
): number {
  const charsPerTok = cfg.chars_per_token ?? 4;
  const denom = Math.max(charsPerTok, 0.1);
  const { input, output } = resolvePrices(model, cfg);
  const inTok = userChars / denom;
  const outTok = agentChars / denom;
  return inTok * (input / 1_000_000) + outTok * (output / 1_000_000);
}

function persistActiveSession(convId: string): void {
  const state = readJsonFile<{
    conversations?: Record<string, Record<string, unknown>>;
    active_session_id?: string;
  }>(STATE_FILE);
  if (!state?.conversations?.[convId]) {
    void vscode.window.showErrorMessage(
      `No saved metrics for session ${convId.slice(0, 8)}…`,
    );
    return;
  }
  const cfg = readConfig();
  const conv = state.conversations[convId];
  const next = {
    ...state,
    active_session_id: convId,
  };
  fs.writeFileSync(STATE_FILE, JSON.stringify(next, null, 2), "utf8");
  const payload = buildCurrentPayload(convId, conv, cfg);
  fs.writeFileSync(CURRENT_FILE, JSON.stringify(payload, null, 2), "utf8");
  void vscode.window.showInformationMessage(
    `Metrics panel now follows chat ${convId.slice(0, 8)}…`,
  );
}

function formatStatus(data: CurrentPayload | null): { text: string; tooltip: string } {
  if (!data) {
    return {
      text: "$(graph) Agent: —",
      tooltip: "No current.json yet. Use Agent once after hooks install.",
    };
  }
  const n = data.user_prompts ?? 0;
  const cost = data.estimated_cumulative_cost_usd ?? 0;
  const proxy = data.proxy_tokens_cumulative ?? 0;
  const m = data.last_model ? data.last_model.slice(0, 18) : "?";
  let flag = "";
  if (n >= WARN_MIN && n <= WARN_MAX) {
    flag = " $(warning)";
  } else if (n > WARN_MAX) {
    flag = " $(error)";
  }
  const text = `$(graph) ${n}↑ ~$${cost.toFixed(3)}* · ${m}${flag}`;
  const tooltip = [
    `Model (last hook): ${data.last_model ?? "unknown"}`,
    `Prompts: ${n} · Agent msgs: ${data.agent_messages ?? 0}`,
    `Heuristic ~$${cost.toFixed(4)} · proxy tok ~${proxy}`,
    `Updated: ${data.last_updated ?? "—"}`,
    "",
    "Click: open live metrics tab. Command Palette: “Pick agent chat session”.",
    "True spend: cursor.com/dashboard/usage",
  ].join("\n");
  return { text, tooltip };
}

function liveDocumentBody(): string {
  const data = readCurrent();
  const cfg = readConfig();
  if (!data) {
    return [
      "Cursor Agent metrics (live)",
      "================================",
      "",
      "(No current.json — send a prompt in Agent.)",
      "",
      `Hooks write: ${CURRENT_FILE}`,
    ].join("\n");
  }
  const prices = resolvePrices(data.last_model, cfg);
  return [
    "Cursor Agent metrics (live)",
    "================================",
    "",
    `Session id:     ${data.session_id ?? "—"}`,
    `Last model:     ${data.last_model ?? "(not reported by hook yet)"}`,
    `Models seen:    ${(data.models_seen ?? []).join(", ") || "—"}`,
    `Pricing used:   $${prices.input}/M input  $${prices.output}/M output (substring overrides in config.json)`,
    "",
    `User prompts:   ${data.user_prompts ?? 0}`,
    `Agent replies:  ${data.agent_messages ?? 0}`,
    `User chars:     ${data.cumulative_user_chars ?? 0}`,
    `Agent chars:    ${data.cumulative_agent_chars ?? 0}`,
    `Proxy tokens ~: ${data.proxy_tokens_cumulative ?? 0}`,
    `Heuristic $ ~:  ${(data.estimated_cumulative_cost_usd ?? 0).toFixed(6)}`,
    "",
    `Transcript:     ${data.transcript_path_last ?? "—"}`,
    `Updated:        ${data.last_updated ?? "—"}`,
    "",
    "---",
    data.pricing_note ?? "",
    data.context_window_note ?? "",
    "",
    "How we know the model: Cursor includes a `model` field on hook payloads",
    "(common schema). If it is missing, set defaults in config.json.",
    "",
    "Switching chats: hooks use conversation_id; sessionStart may resync",
    "from transcript_path when you focus a tab (if transcripts enabled).",
    "",
    "This file refreshes every ~2s while open.",
  ].join("\n");
}

class LiveMetricsDocumentProvider implements vscode.TextDocumentContentProvider {
  private readonly emitter = new vscode.EventEmitter<vscode.Uri>();
  readonly onDidChange = this.emitter.event;

  provideTextDocumentContent(_uri: vscode.Uri): string {
    return liveDocumentBody();
  }

  fireRefresh(): void {
    this.emitter.fire(LIVE_URI);
  }

  dispose(): void {
    this.emitter.dispose();
  }
}

function webviewHtml(cspSource: string): string {
  return `<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8" />
  <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src ${cspSource} 'unsafe-inline'; script-src ${cspSource} 'unsafe-inline';" />
  <style>
    body { font-family: var(--vscode-font-family); font-size: 13px; padding: 12px; color: var(--vscode-foreground); }
    h1 { font-size: 11px; font-weight: 600; text-transform: uppercase; letter-spacing: 0.06em; opacity: 0.85; margin: 0 0 10px 0; }
    .row { display: flex; justify-content: space-between; margin: 8px 0; gap: 12px; }
    .label { opacity: 0.85; }
    .value { font-weight: 600; font-variant-numeric: tabular-nums; text-align: right; }
    .warn { color: var(--vscode-editorWarning-foreground); }
    .bad { color: var(--vscode-errorForeground); }
    .mono { font-family: var(--vscode-editor-font-family); font-size: 11px; opacity: 0.9; word-break: break-all; }
    .note { font-size: 11px; opacity: 0.75; margin-top: 16px; line-height: 1.45; }
    .empty { opacity: 0.7; }
  </style>
</head>
<body>
  <h1>This chat (hooks)</h1>
  <div id="root"><p class="empty">Loading…</p></div>
  <p class="note" id="note"></p>
  <script>
    window.addEventListener('message', function(e) {
      if (!e.data || e.data.type !== 'update') return;
      const d = e.data.payload;
      const root = document.getElementById('root');
      const note = document.getElementById('note');
      if (!d) {
        root.innerHTML = '<p class="empty">No metrics yet.</p>';
        note.textContent = '';
        return;
      }
      const n = d.user_prompts ?? 0;
      const cost = d.estimated_cumulative_cost_usd ?? 0;
      const proxy = d.proxy_tokens_cumulative ?? 0;
      const msgs = d.agent_messages ?? 0;
      const model = d.last_model || '—';
      let cls = '';
      if (n >= ${WARN_MIN} && n <= ${WARN_MAX}) cls = 'warn';
      if (n > ${WARN_MAX}) cls = 'bad';
      root.innerHTML =
        '<div class="row"><span class="label">Model (last hook)</span><span class="value mono">' + model + '</span></div>' +
        '<div class="row"><span class="label">User prompts</span><span class="value ' + cls + '">' + n + '</span></div>' +
        '<div class="row"><span class="label">Agent replies</span><span class="value">' + msgs + '</span></div>' +
        '<div class="row"><span class="label">Proxy tokens ~</span><span class="value">' + proxy + '</span></div>' +
        '<div class="row"><span class="label">Heuristic cost ~</span><span class="value">$' + cost.toFixed(4) + '</span></div>' +
        '<div class="row"><span class="label">Updated</span><span class="value" style="font-weight:400;font-size:11px">' + (d.last_updated || '—') + '</span></div>';
      note.textContent = (d.context_window_note || '') + ' · cursor.com/dashboard/usage';
    });
  </script>
</body>
</html>`;
}

class MetricsWebviewProvider implements vscode.WebviewViewProvider {
  private interval: ReturnType<typeof setInterval> | undefined;

  resolveWebviewView(webviewView: vscode.WebviewView): void {
    webviewView.webview.options = { enableScripts: true };
    webviewView.webview.html = webviewHtml(webviewView.webview.cspSource);
    const push = (): void => {
      webviewView.webview.postMessage({
        type: "update",
        payload: readCurrent(),
      });
    };
    push();
    this.interval = setInterval(push, 1000);
    webviewView.onDidDispose(() => {
      if (this.interval) {
        clearInterval(this.interval);
        this.interval = undefined;
      }
    });
  }
}

async function openLiveMetricsTab(
  docProvider: LiveMetricsDocumentProvider,
): Promise<void> {
  const doc = await vscode.workspace.openTextDocument(LIVE_URI);
  await vscode.window.showTextDocument(doc, {
    preview: false,
    preserveFocus: false,
  });
  docProvider.fireRefresh();
}

async function pickSessionInteraction(): Promise<void> {
  const state = readJsonFile<{
    conversations?: Record<string, Record<string, unknown>>;
  }>(STATE_FILE);
  const convs = state?.conversations;
  if (!convs || Object.keys(convs).length === 0) {
    void vscode.window.showInformationMessage(
      "No conversations in state.json yet — use Agent in a few chats first.",
    );
    return;
  }
  const items: vscode.QuickPickItem[] = Object.keys(convs).map((id) => {
    const c = convs[id];
    const n = Number(c.user_prompts ?? 0);
    const cost = Number(c.estimated_cumulative_cost_usd ?? 0);
    const m = (c.last_model as string) || "?";
    return {
      label: `${id.slice(0, 8)}…  ${n} prompts  ~$${cost.toFixed(3)}  ${m.slice(0, 24)}`,
      description: id,
    };
  });
  const picked = await vscode.window.showQuickPick(items, {
    placeHolder: "Choose a chat session to show in metrics / live tab",
  });
  if (!picked?.description) {
    return;
  }
  persistActiveSession(picked.description);
}

export function activate(context: vscode.ExtensionContext): void {
  const docProvider = new LiveMetricsDocumentProvider();
  context.subscriptions.push(
    vscode.workspace.registerTextDocumentContentProvider(
      "cursor-agent-metrics",
      docProvider,
    ),
  );

  const item = vscode.window.createStatusBarItem(
    vscode.StatusBarAlignment.Left,
    100,
  );
  item.name = "cursorAgentMetrics";

  const refreshStatus = (): void => {
    const data = readCurrent();
    const { text, tooltip } = formatStatus(data);
    item.text = text;
    item.tooltip = tooltip;
    item.command = "cursorAgentMetrics.openLiveTab";
    item.show();
  };

  refreshStatus();
  const statusInterval = setInterval(refreshStatus, 2000);
  const liveRefreshInterval = setInterval(() => {
    docProvider.fireRefresh();
  }, 2000);

  context.subscriptions.push(
    vscode.window.registerWebviewViewProvider(VIEW_ID, new MetricsWebviewProvider(), {
      webviewOptions: { retainContextWhenHidden: true },
    }),
  );

  context.subscriptions.push(
    vscode.commands.registerCommand("cursorAgentMetrics.openState", async () => {
      await vscode.env.openExternal(vscode.Uri.file(METRICS_DIR));
    }),
  );
  context.subscriptions.push(
    vscode.commands.registerCommand("cursorAgentMetrics.showJson", async () => {
      const doc = await vscode.workspace.openTextDocument(
        vscode.Uri.file(CURRENT_FILE),
      );
      await vscode.window.showTextDocument(doc, { preview: true, preserveFocus: true });
    }),
  );
  context.subscriptions.push(
    vscode.commands.registerCommand("cursorAgentMetrics.openLiveTab", async () => {
      await openLiveMetricsTab(docProvider);
    }),
  );
  context.subscriptions.push(
    vscode.commands.registerCommand("cursorAgentMetrics.refreshLiveTab", () => {
      docProvider.fireRefresh();
    }),
  );
  context.subscriptions.push(
    vscode.commands.registerCommand("cursorAgentMetrics.pickSession", () =>
      pickSessionInteraction(),
    ),
  );
  context.subscriptions.push(
    vscode.commands.registerCommand("cursorAgentMetrics.focusPanel", async () => {
      try {
        await vscode.commands.executeCommand(
          "workbench.view.extension.cursor-agent-metrics",
        );
      } catch {
        await vscode.window.showInformationMessage(
          "Use the chart icon “Agent metrics” in the Activity Bar.",
        );
      }
    }),
  );
  context.subscriptions.push(item);
  context.subscriptions.push({
    dispose: () => {
      clearInterval(statusInterval);
      clearInterval(liveRefreshInterval);
      docProvider.dispose();
    },
  });
}

export function deactivate(): void {}
