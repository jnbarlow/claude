# Claude Code Plugins — John's Personal Marketplace

[![License: AGPL-3.0](https://img.shields.io/badge/License-AGPL%20v3-blue.svg)](LICENSE) Licensed under [AGPL v3](./LICENSE). For commercial use (code integrated directoy into a produt), contact <jnbarlow@gmail.com>.

A self-hosted plugin marketplace for [Claude Code](https://claude.ai/code). Add this repo as a marketplace, then install whichever plugins you want. No central registry required.

## How to Install

### Step 1: Add This Repo as a Marketplace

In any Claude Code session:

```
/plugin marketplace add jnbarlow/claude
/reload-plugins
```

This registers the catalog — no plugins are installed yet, just discoverable.

### Step 2: Install Plugins You Want

Browse what's available with `/plugin` → **Discover** tab, or install directly:

| Plugin | Description | Command |
|--------|-------------|---------|
| [long-term-memory](./long-term-memory/) | Human-like memory for Claude Code. Notices patterns, forms opinions about you and your work, revises them over time — not just a fact ledger but growing understanding across sessions. Backed by PostgreSQL with tag-based recall, full-text search, supersession chains to track how knowledge evolves, and automatic session preload so Claude knows who you are from the first turn. | `/plugin install long-term-memory@jnbarlow-claude` |

After installing any plugin:

```
/reload-plugins
```

## Adding New Plugins

As new plugins land here, just add them to `.claude-plugin/marketplace.json`. Run `/plugin marketplace update jnbarlow-claude` in Claude Code and they'll appear in the Discover tab.
