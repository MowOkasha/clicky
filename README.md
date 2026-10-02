Update: April 27, 2026.

Hi there! I'm Farza, the guy that made Clicky.

The existing codebase remains open source. Tinker with it, make it yours, start a company out of it, do whatever you want I don't mind. But, for all the new stuff I'm hacking on, gonna keep it private. To get the latest Clicky, you can go [here](https://www.heyclicky.com/).

I also tweeted about this [here](https://x.com/FarzaTV/status/2043402737828962489).

Go crazy with this repo!! It's an MIT license.

# Hi, this is Clicky.
It's an AI teacher that lives as a buddy next to your cursor. It can see your screen, talk to you, and even point at stuff. Kinda like having a real teacher next to you.

Download it [here](https://www.clicky.so/) for free.

Here's the [original tweet](https://x.com/FarzaTV/status/2041314633978659092) that kinda blew up for a demo for more context.

![Clicky — an ai buddy that lives on your mac](clicky-demo.gif)

This is the open-source version of Clicky for those that want to hack on it, build their own features, or just see how it works under the hood.

## Get started with Claude Code

The fastest way to get this running is with [Claude Code](https://docs.anthropic.com/en/docs/claude-code).

Once you get Claude running, paste this:

```
Hi Claude.

Clone https://github.com/farzaa/clicky.git into my current directory.

Then read the CLAUDE.md. I want to get Clicky running locally on my Mac.

Help me set up everything — the Cloudflare Worker with my own API keys, the proxy URLs, and getting it building in Xcode. Walk me through it.
```

That's it. It'll clone the repo, read the docs, and walk you through the whole setup. Once you're running you can just keep talking to it — build features, fix bugs, whatever. Go crazy.

## Manual setup

If you want to do it yourself, here's the deal.

### Prerequisites

- macOS 14.2+ (for ScreenCaptureKit)
- Xcode 15+
- Node.js 18+ (for the Cloudflare Worker)
- A [Cloudflare](https://cloudflare.com) account (free tier works)
- API keys for: [Anthropic](https://console.anthropic.com), [AssemblyAI](https://www.assemblyai.com), [ElevenLabs](https://elevenlabs.io)

### 1. Set up the Cloudflare Worker

The Worker is a tiny proxy that holds your API keys. The app talks to the Worker, the Worker talks to the APIs. This way your keys never ship in the app binary.

```bash
cd worker
npm install
```

Now add your secrets. Wrangler will prompt you to paste each one:

```bash
npx wrangler secret put ANTHROPIC_API_KEY
npx wrangler secret put ASSEMBLYAI_API_KEY
npx wrangler secret put ELEVENLABS_API_KEY
```

For the ElevenLabs voice ID, open `wrangler.toml` and set it there (it's not sensitive):

```toml
[vars]
ELEVENLABS_VOICE_ID = "your-voice-id-here"
```

Deploy it:

```bash
npx wrangler deploy
```

It'll give you a URL like `https://your-worker-name.your-subdomain.workers.dev`. Copy that.

### 2. Run the Worker locally (for development)

If you want to test changes to the Worker without deploying:

```bash
cd worker
npx wrangler dev
```

This starts a local server (usually `http://localhost:8787`) that behaves exactly like the deployed Worker. You'll need to create a `.dev.vars` file in the `worker/` directory with your keys:

```
ANTHROPIC_API_KEY=sk-ant-...
ASSEMBLYAI_API_KEY=...
ELEVENLABS_API_KEY=...
ELEVENLABS_VOICE_ID=...
```

Then update the proxy URLs in the Swift code to point to `http://localhost:8787` instead of the deployed Worker URL while developing. Grep for `clicky-proxy` to find them all.

### 3. Update the proxy URLs in the app

The app has the Worker URL hardcoded in a few places. Search for `your-worker-name.your-subdomain.workers.dev` and replace it with your Worker URL:

```bash
grep -r "clicky-proxy" leanring-buddy/
```

You'll find it in:
- `CompanionManager.swift` — Claude chat + ElevenLabs TTS
- `AssemblyAIStreamingTranscriptionProvider.swift` — AssemblyAI token endpoint

### 4. Open in Xcode and run

```bash
open leanring-buddy.xcodeproj
```

In Xcode:
1. Select the `leanring-buddy` scheme (yes, the typo is intentional, long story)
2. Set your signing team under Signing & Capabilities
3. Hit **Cmd + R** to build and run

The app will appear in your menu bar (not the dock). Click the icon to open the panel, grant the permissions it asks for, and you're good.

### Permissions the app needs

- **Microphone** — for push-to-talk voice capture
- **Accessibility** — for the global keyboard shortcut (Control + Option)
- **Screen Recording** — for taking screenshots when you use the hotkey
- **Screen Content** — for ScreenCaptureKit access

## Architecture

If you want the full technical breakdown, read `AGENTS.md` (or `CLAUDE.md`). Here's the short version:

- **Menu bar app** (`LSUIElement=true`, no dock icon) with custom `NSPanel` floating windows.
- **Local Multi-Model Agent Architecture** served by **oMLX** (`http://localhost:8000/v1`):
  - `qwen3.5-4b`: Pinned, resident actor/grounding model handling tool execution
  - `qwen3.5-9b`: On-demand planner decomposing goals into verifiable subgoals and replanning on escalation
  - `qwen3-embedding-0.6b`: Pinned, resident embedder for RAG retrieval
- **Perception**: macOS Accessibility API (`AXUIElement`) inspection first; ScreenCaptureKit screenshot fallback only when the accessibility tree is insufficient.
- **State Lives Outside the Model**: Task state, planned subgoals, compressed action history, and failure counters live in `AgentStateManager` in Clicky's own app layer. Prompts are reconstructed fresh on every turn.
- **Pure Swift In-Process RAG**: Built-in SQLite vector store (`LocalVectorStore.swift`) with Apple Accelerate `vDSP` cosine similarity for past trajectories and per-app UI maps. No external sidecars needed.
- **Top-Right Task Dock**: When executing a task, Clicky relocates to a floating badge below the menu bar clock, expanding on hover to reveal tool-by-tool progress.
- **Speech**: On-device Apple `SFSpeechRecognizer` for push-to-talk (Control + Option) and `AVSpeechSynthesizer` for voice output.

## Project structure

```
leanring-buddy/              # Swift source
  CompanionManager.swift        # Central state machine & pipeline coordinator
  CompanionPanelView.swift      # Menu bar panel UI
  OMLXClient.swift              # OpenAI-compatible oMLX client (localhost:8000/v1)
  PerceptionManager.swift       # AXUIElement hierarchy inspection + screenshot fallback
  AgentStateManager.swift       # External task state manager
  AgentPlanner.swift            # Goal decomposition & replanning (qwen3.5-9b)
  AgentActorLoop.swift          # Step-by-step tool execution loop (qwen3.5-4b)
  AgentToolExecutor.swift       # Tool execution (click, type, scroll, point, etc.)
  LocalVectorStore.swift        # In-process SQLite + Accelerate RAG store
  OverlayWindow.swift           # Blue cursor overlay & flight animations
  AgentTaskDockWindow.swift     # Top-right task progress dock
  BuddyDictationManager.swift   # Push-to-talk voice pipeline
AGENTS.md                     # Full architecture doc & conventions (CLAUDE.md symlink)
```

## Contributing

PRs welcome. If you're using Claude Code or an AI agent, it already knows the codebase — point it at `AGENTS.md` (or `CLAUDE.md`).

Got feedback? DM me on X [@farzatv](https://x.com/farzatv).

## How to Run

### 1. Start the oMLX Model Server
Make sure [oMLX](https://github.com/the-omlx/omlx) is installed and serving your models:

```bash
source vlm-env/bin/activate
omlx serve --model-dir ~/models
```

In the oMLX admin dashboard (`http://localhost:8000/admin`):
- Pin `qwen3.5-4b` (resident actor/grounding)
- Pin `qwen3-embedding-0.6b` (resident embedder)
- Leave `qwen3.5-9b` unpinned with a ~90s idle TTL (on-demand planner)

### 2. Launch Clicky in Xcode
```bash
open leanring-buddy.xcodeproj
```

In Xcode:
1. Select the `leanring-buddy` scheme.
2. Under Signing & Capabilities, select your development signing team.
3. Press **Cmd + R** to build and run.

> **Note**: Do **NOT** run `xcodebuild` from the terminal — it invalidates macOS TCC (Transparency, Consent, and Control) permissions for screen recording and accessibility.

### 3. Permissions & Usage
On first launch:
1. Click the Clicky icon in your menu bar.
2. Grant the required permissions (**Microphone**, **Accessibility**, **Screen Recording**).
3. Hold **Control + Option** and speak your request.
