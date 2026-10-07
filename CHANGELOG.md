# Changelog

## 2.0.0 (2026-10-07)

- **Renamed to `opaiva-code-widget`.** Claude Code 2.1.292 and later reserve plugin names that start with `claude-` for Anthropic's own plugins. Install with `claude plugin install opaiva-code-widget@claude-code-widget`; the marketplace keeps its name. If you have the old `claude-code-widget` plugin, follow [Renamed in 2.0.0](README.md#renamed-in-200) and uninstall it first. After the switch the widget starts in the default corner.

## 1.1.1 (2026-10-07)

- Internal: the hook and the widget now share their common code (`common.ps1`), and an automated test suite (Pester 5) runs on every push and pull request in GitHub Actions. No behavior change.

## 1.1.0 (2026-10-01)

- **Terminal sessions.** When you send a message, the widget remembers the window you typed in: VS Code, Windows Terminal, PowerShell or cmd. It checks the process tree to confirm the window belongs to that Claude Code session. The "finished" notice is skipped while that window is in front, and its button becomes **Go to terminal** and brings that exact window back. Before, both only knew about VS Code windows.
- Prompts sent from your phone (Remote Control) leave an unrelated window in front, so they don't change the remembered window.

## 1.0.0 (2026-10-01)

- First release: permission requests, multiple-choice questions and "finished" notices in an always-on-top widget that never takes focus. UI in English and Portuguese.
