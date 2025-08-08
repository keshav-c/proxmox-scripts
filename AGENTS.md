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
