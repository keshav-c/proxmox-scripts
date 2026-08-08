# AGENTS.md - Development Guidelines

## Build/Test Commands

- No specific build system detected yet
- For shell scripts: `shellcheck *.sh` (if shellcheck available)

## Code Style Guidelines

### Shell Scripts

- Use `#!/bin/bash` shebang
- Use `set -euo pipefail` for error handling
- Quote variables: `"$variable"` not `$variable`
- Use `[[ ]]` instead of `[ ]` for conditionals
- Functions: `function_name() { ... }`

### General

- Use descriptive variable and function names
- Add error handling for all external commands
- Log important operations and errors
- Use consistent indentation (4 spaces for Python, 2 for shell)
- No hardcoded credentials or sensitive data

## About

In this project we will create scripts and other artifacts in order to work with proxmox

## Web Tasks - Playwright CLI

For any web browsing, scraping, screenshots, or DOM interaction needs, use **`playwright-cli`** (already installed globally). Run `playwright-cli --help` to discover available commands for the task at hand. If browser is required, you can open a chrome debug browser on port 9222 using the `chrome-debug` command.

### Rules

- **Already installed.** Do not ask to install Playwright or browsers unnecessarily.
- **Clean up is mandatory.** If you spawn multiple processes, you must remember to kill them when done.
  - `playwright-cli close` — close current session
  - `playwright-cli close-all` — close all sessions
  - `playwright-cli kill-all` — force kill zombie processes
  - Shut all the tabs in the `chrome-debug` instance and terminate the process.
- **`curl`/`wget`**: Only for simple API endpoints returning raw JSON/XML without rendering.

