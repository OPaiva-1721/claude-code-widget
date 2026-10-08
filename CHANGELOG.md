# Changelog

## 2.1.0 (2026-10-08)

- **Session title on the cards.** Next to the project, the cards show the session's title: the name you gave it with `/rename`, or the one Claude Code picked. Two sessions in the same project are easy to tell apart.
- **"All done" sound.** When several sessions were working and the last one finishes, its notice plays a different sound (Windows' "tada").
- **Double-click to go back.** Double-click the widget (outside its buttons) to bring back the session's window: the finished session on a "finished" notice, otherwise the session you typed in last.

## 2.0.1 (2026-10-07)

- **Monitor changes.** If the widget's monitor is unplugged while the widget is open, the widget moves to the main screen's corner within a couple of seconds, and goes back to where you put it once that monitor is back. A saved position between monitors of different sizes no longer opens the widget off screen.
- **VS Code windows are matched by the whole project name.** A project called `widget` no longer matches the `claude-code-widget` window, or a `widget.ps1` file open in another project. The "finished" notice is no longer skipped by mistake, and **Go to VS Code** brings the right window.
- `widget.log` is capped like `hook.log`: past 256 KB it moves to `widget.log.old`.

## 2.0.0 (2026-10-07)

- **Renamed to `opaiva-code-widget`.** Claude Code 2.1.292 and later reserve plugin names that start with `claude-` for Anthropic's own plugins. Install with `claude plugin install opaiva-code-widget@claude-code-widget`. The marketplace keeps its name and maps the old name to the new one, so once it is updated the old plugin stops loading and Claude Code moves your settings to the new name. If you have the old `claude-code-widget` plugin, follow [Renamed in 2.0.0](README.md#renamed-in-200): uninstall it first, and reload any open sessions. After the switch the widget starts in the default corner.

## 1.1.1 (2026-10-07)

- Internal: the hook and the widget now share their common code (`common.ps1`), and an automated test suite (Pester 5) runs on every push and pull request in GitHub Actions. No behavior change.

## 1.1.0 (2026-10-01)

- **Terminal sessions.** When you send a message, the widget remembers the window you typed in: VS Code, Windows Terminal, PowerShell or cmd. It checks the process tree to confirm the window belongs to that Claude Code session. The "finished" notice is skipped while that window is in front, and its button becomes **Go to terminal** and brings that exact window back. Before, both only knew about VS Code windows.
- Prompts sent from your phone (Remote Control) leave an unrelated window in front, so they don't change the remembered window.

## 1.0.0 (2026-10-01)

- First release: permission requests, multiple-choice questions and "finished" notices in an always-on-top widget that never takes focus. UI in English and Portuguese.
