# Changelog

## 2.4.1 (2026-10-08)

- **An old session no longer downgrades the widget.** After a plugin update, a Claude Code session still running the previous version used to replace the new widget with its own old one (at its next "finished" notice). The hook now replaces a running widget only when that widget is older than the hook's own version.

## 2.4.0 (2026-10-08)

- **Look and sound from the right-click menu.** Theme (dark, light, or automatic like Windows), opacity (100-60%), volume (mute to 100%), size (100/125/150%) and a minimal idle pill (only the colored dot; the status becomes a tooltip). Each choice applies at once and is saved in `prefs.json`.
- The volume applies to the request, finished and all-done sounds. If Windows cannot play a sound file, the widget uses the system sound, which ignores the volume (Mute still silences it).

## 2.3.0 (2026-10-08)

- **Diff on the card.** The permission card of an `Edit`, `MultiEdit` or `Write` shows what changes: removed lines in red, added lines in green (up to 14 lines).
- **Always allow.** The permission card offers buttons that approve and also save one of the rules Claude Code itself suggests, showing the rule and where it is saved (this session, this project, all projects...). Only rules that allow, the modes below "bypass permissions" and folders are offered; the widget never saves anything Claude Code did not suggest.
- **Global hotkeys (off by default).** Set `CLAUDE_WIDGET_HOTKEYS=1` to approve (`Ctrl+Alt+Y`), deny (`Ctrl+Alt+N`) and toggle "do not disturb" (`Ctrl+Alt+D`) from any window. Change the keys with `CLAUDE_WIDGET_KEY_APPROVE`, `CLAUDE_WIDGET_KEY_DENY` and `CLAUDE_WIDGET_KEY_DND`.

## 2.2.1 (2026-10-08)

- **No ghost tray icons after an update.** When a plugin update replaces the running widget, the hook now asks the old one to close itself (it removes its own tray icon) and only kills it if it has not left after 4 seconds. Before, every update left a dead icon in the tray until you hovered over it.
- Internal: setting `CLAUDE_WIDGET_NO_TRAY=1` starts the widget without a tray icon; the test suite uses it so that running the tests no longer fills the tray with ghost icons.

## 2.2.0 (2026-10-08)

- **Tray icon and "do not disturb".** A tray icon (orange while active, grey in "do not disturb") toggles the mode with a left click; its menu has **Do not disturb** and **Close widget**. In the mode, permission requests and questions go straight to VS Code, the widget hides, and "finished" notices wait silently until you turn the mode off. The mode stays on until you turn it off, even after a restart. If the icon is in the hidden-icons area, drag it onto the taskbar once.
- **Sessions list.** The idle pill says how many sessions are working. Click it to see each one: project, session title and how long it has been working (orange when a request from that project is waiting).
- Long session titles are cut without splitting an emoji.

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
