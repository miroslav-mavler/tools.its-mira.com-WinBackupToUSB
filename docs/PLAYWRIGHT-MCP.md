## Playwright MCP in VS Code (Windows)

This repo uses Playwright MCP to give Copilot a deterministic browser automation tool. Below is a known-good config for Windows + VS Code/Copilot.

### 1) Add MCP server config

Add this JSON to your MCP client config. In VS Code with Copilot Pro, open Settings (JSON) or the MCP config UI and add an entry named "playwright".

Recommended (explicit npx path + auto-confirm):

{
  "mcpServers": {
    "playwright": {
      "command": "C:\\Program Files\\nodejs\\npx.cmd",
      "args": ["-y", "@playwright/mcp@latest"],
      "env": {
        "PLAYWRIGHT_BROWSERS_PATH": "0"
      }
    }
  }
}

Notes:
- -y skips the first-time prompt so the server starts reliably.
- PLAYWRIGHT_BROWSERS_PATH=0 lets Playwright manage browser binaries per-user.
- If Node was installed for the current user, npx may be in %UserProfile%\\AppData\\Roaming\\npm\\npx.cmd. Use that full path instead.

Alternative (PATH-resolved npx):

{
  "mcpServers": {
    "playwright": {
      "command": "npx",
      "args": ["-y", "@playwright/mcp@latest"]
    }
  }
}

Optional flags:
- "--shared-browser-context": share one browser across tasks (reduces sign-ins)
- "--headless": run without a visible browser window
- "--user-data-dir=C:\\Users\\<YOU>\\AppData\\Local\\ms-playwright\\mcp-profile": persistent profile
- "--isolated": ephemeral profiles per session

Example with extras:

{
  "mcpServers": {
    "playwright": {
      "command": "C:\\Program Files\\nodejs\\npx.cmd",
      "args": [
        "-y","@playwright/mcp@latest",
        "--shared-browser-context",
        "--headless"
      ]
    }
  }
}

### 2) Restart MCP

- VS Code: Command Palette → Copilot: Restart MCP Servers
- If that’s missing, reload window (Developer: Reload Window) or restart VS Code.
- Verify: Copilot should list a "playwright" tool (e.g., navigate, click, type) when asked to browse.

### 3) Troubleshooting

- npx not found: Ensure Node is installed and PATH includes:
  - C:\\Program Files\\nodejs\\
  - %UserProfile%\\AppData\\Roaming\\npm
- First run slow: npx downloads the package. "-y" avoids prompts.
- Corporate proxy: configure npm proxy (npm config set proxy/https-proxy) or run the MCP server via a standalone port and point the client at the url.

### 4) Standalone (optional)

You can run Playwright MCP as a standalone HTTP server and point the client at it.

Terminal 1:
  npx -y @playwright/mcp@latest --port 8931

MCP client config:
{
  "mcpServers": {
    "playwright": { "url": "http://localhost:8931/mcp" }
  }
}

### 5) Why this setup

- Mirrors the official @playwright/mcp guidance.
- Explicit Windows npx path + -y makes startup reliable in VS Code.
- Optional shared context reduces re-auth friction when Copilot runs multiple steps.
