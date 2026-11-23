#!/usr/bin/env python3
"""Assert the upstream contracts tools/ci/offline-port.patch depends on.

The offline layer is a source patch, not a fork: every night we re-apply it onto
whatever upstream published. That keeps working only while a handful of upstream
signatures stay as they are. When one of them moves, `git apply` either fails with
a wall of context mismatch, or (worse) succeeds and leaves a build that compiles
but has lost the offline behaviour. This script names the contract that moved.

Run it against a **patched** source tree, after `git apply`; it checks both that
the patch is still in place and that the upstream shape under it is unchanged.

    python3 tools/ci/check-port-invariants.py <source-root>

Exit code 0: every contract holds. 1: at least one moved (each is printed with a
`::error::` line so it surfaces in the Actions log).
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

FAILURES: list[str] = []
CHECKS = 0


def read(root: Path, rel: str) -> str:
    path = root / rel
    if not path.is_file():
        fail(f"{rel}: missing (upstream moved or renamed this file)")
        return ""
    return path.read_text(encoding="utf-8", errors="replace")


def ok(label: str) -> None:
    global CHECKS
    CHECKS += 1
    print(f"  ok   {label}")


def fail(label: str, why: str) -> None:
    global CHECKS
    CHECKS += 1
    FAILURES.append(f"{label}: {why}")
    print(f"  FAIL {label}: {why}")


def need(label: str, text: str, pattern: str, why: str, flags: int = re.MULTILINE) -> None:
    """Require `pattern` to match somewhere in `text`."""
    if re.search(pattern, text, flags):
        ok(label)
    else:
        fail(label, why)


def need_block(label: str, text: str, start: str, required: list[str], why: str) -> None:
    """Require `start` to open a block that then contains every string in `required`.

    Upstream keeps its own doc comments between the braces, so the fields are
    matched loosely: what matters is that they are still in there.
    """
    body = between(text, start, "\n}\n")
    if not body:
        fail(label, f"`{start}` is gone; {why}")
        return
    missing = [r for r in required if not re.search(r, body, re.MULTILINE)]
    if missing:
        fail(label, f"{len(missing)} of {len(required)} parts gone ({', '.join(missing)}); {why}")
    else:
        ok(label)


def need_absent(label: str, text: str, pattern: str, why: str) -> None:
    if re.search(pattern, text, re.MULTILINE):
        fail(label, why)
    else:
        ok(label)


def between(text: str, start: str, end: str) -> str:
    """The slice from `start` up to (not including) the next `end`."""
    i = text.find(start)
    if i < 0:
        return ""
    j = text.find(end, i + len(start))
    return text[i:] if j < 0 else text[i:j]


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: check-port-invariants.py <source-root>", file=sys.stderr)
        return 2
    root = Path(sys.argv[1])
    if not (root / "launcher").is_dir():
        print(f"::error::{root} does not look like a Horizon checkout", file=sys.stderr)
        return 2

    print("== 1. the offline gate (`GATE_OPEN`) is still the pass through the owner check ==")
    account = read(root, "launcher/src/account.rs")
    if account:
        need(
            "GATE_OPEN is declared true",
            account,
            r"^pub const GATE_OPEN: bool = true;",
            "the patch turns the owner gate off here; if upstream added a second gate, the "
            "offline build now needs a pass for it too",
        )
        need(
            "GATE_OPEN still consulted in launch_for_game",
            account,
            r"if GATE_OPEN \{\s*\n\s*return Ok\(pass\);",
            "launch_for_game no longer short-circuits on GATE_OPEN, so a build without an "
            "account that owns the game would refuse to start",
        )
        need(
            "GATE_OPEN still swallows the NoOwner error",
            account,
            r"Err\(_\) if GATE_OPEN => Launch::default\(\)",
            "the NoOwner fallback is gone: launch returns Err before reaching the GATE_OPEN return",
        )
        need(
            "launch_for_game keeps its signature",
            account,
            r"pub fn launch_for_game\(\s*\n\s*ep: &Endpoints,\s*\n\s*client_id: Option<&str>,\s*\n"
            r"\s*store: &dyn SecretStore,\s*\n\s*accounts: &mut Accounts,\s*\n\) -> Result<Launch, NoOwner>",
            "the patch edits the body of launch_for_game by context; a new parameter or return "
            "type means regenerating the patch, not just resolving a conflict",
        )
        need(
            "launch_for_game honours an offline name instead of overwriting it",
            account,
            r"if accounts\.selected\(\)\.is_none\(\) && accounts\.offline_selected\.is_none\(\)",
            "without this the launcher picks a Microsoft account over the offline name on every "
            "start, and the offline name is silently ignored",
        )
        need_block(
            "Player has the three-way shape (Microsoft / Offline / GameName)",
            account,
            "pub enum Player {",
            [r"Microsoft\(String\)", r"Offline\(String\)", r"^\s*GameName,"],
            "switch_page::who_plays and the account chip match exhaustively on it; a new variant "
            "breaks the match, a removed one breaks the offline path",
        )
        need(
            "Accounts still keeps `offline` and `offline_selected`",
            account,
            r"pub offline_selected: Option<String>,",
            "the saved offline name lives here; renaming it loses every player's chosen name",
        )
        need(
            "accounts.player() reads both fields",
            account,
            r"pub fn player\(&self\) -> Player \{\s*\n\s*match \(self\.selected\(\), &self\.offline_selected\)",
            "player() is what the chip, the version list and session_for_game agree on",
        )

    print("== 2. `GameSession` still carries the offline name through to the game ==")
    if account:
        session = between(account, "pub struct GameSession {", "\n}\n")
        for field, why in (
            ("file", "the Microsoft session file handed to the game (`--session-file`)"),
            ("offline", "why the account plays offline this time"),
            ("name", "the offline name handed to the game (`--name`); the patch adds this"),
            ("env", "the other accounts' sessions, for splitscreen"),
        ):
            if re.search(rf"^\s*pub {field}: ", session, re.MULTILINE):
                ok(f"GameSession.{field} is present ({why})" if field == "name"
                   else f"GameSession.{field} is present")
            else:
                fail(
                    f"GameSession.{field} is present",
                    f"missing; {why} — every `GameSession {{ … }}` literal and `let GameSession "
                    f"{{ … }} = …` destructuring in developer_play.rs needs updating",
                )
        need(
            "GameSession still derives Default",
            account,
            r"#\[derive\(Debug, Default\)\]\s*\npub struct GameSession",
            "GATE_OPEN returns Launch::default(), and an offline launch fills the rest from "
            "the defaults",
        )

    print("== 3. the bundled-build installer's assumptions (`horizon_bundle.rs`) ==")
    backend = read(root, "launcher/src/backend.rs")
    if backend:
        # Upstream split `Settings` out of backend.rs into backend/settings.rs (2026-11-22,
        # launcher@0.2.107) and re-exports it as `backend::Settings`, so the struct itself is no
        # longer in this file. Search both, so the contract holds whether or not the split stays.
        settings_rs = root / "launcher/src/backend/settings.rs"
        settings_text = (
            backend + "\n" + settings_rs.read_text(encoding="utf-8", errors="replace")
            if settings_rs.is_file()
            else backend
        )
        need(
            "backend::COMPLETE is still \".installed\"",
            backend,
            r'const COMPLETE: &str = "\.installed";',
            "horizon_bundle::ensure writes that marker to make the bundled version 'installed'; "
            "if the name changes, the version copy is treated as incomplete and the game never "
            "appears in the list",
        )
        need(
            "backend::data_dir reads HORIZON_LAUNCHER_HOME first",
            backend,
            r'pub fn data_dir\(\) -> PathBuf \{\s*\n\s*if let Some\(home\) = std::env::var_os\("HORIZON_LAUNCHER_HOME"\)',
            "the CI smoke test and the offline package both steer the data folder with it",
        )
        need(
            "installed() still keys on the marker file",
            backend,
            r"\.filter\(\|e\| e\.path\(\)\.join\(COMPLETE\)\.exists\(\)\)",
            "a version counts as installed only by this file; horizon_bundle writes exactly it",
        )
        need(
            "Settings still has `selected` and `install_new_versions`",
            settings_text,
            r"pub struct Settings \{\s*\n\s*pub selected: Option<String>,",
            "horizon_bundle sets both on first start",
        )
        need(
            "Settings.install_new_versions is Option<bool>",
            settings_text,
            r"pub install_new_versions: Option<bool>,",
            "the package writes Some(false); a plain bool would need a different write",
        )
        need(
            "self_update_allowed() is still the switch the patch pins to false",
            backend,
            r"pub fn self_update_allowed\(\) -> bool \{",
            "updating from upstream would replace the patched binary with a gated one",
        )

    print("== 4. version-tag naming (`nightly-YYYY-MM-DD-xxxxxxx`) ==")
    nightly = read(root, "launcher/src/nightly.rs")
    if nightly:
        need(
            "nightly::date_of still parses `nightly-<date>`",
            nightly,
            r'let date = version\.strip_prefix\("nightly-"\)\?\.get\(\.\.10\)\?;',
            "the package tag must stay readable as a nightly date, or the version sorts as "
            "a launcher semver and the bundled build shows up in the wrong order",
        )
    if backend:
        need(
            "release_order asks nightly::date_of first",
            backend,
            r"if let Some\(date\) = crate::nightly::date_of\(tag\)",
            "same as above, from the ordering side",
        )

    print("== 5. the bundle installer is still wired into main() ==")
    main_rs = read(root, "launcher/src/main.rs")
    if main_rs:
        need(
            "main() calls horizon_bundle::ensure()",
            main_rs,
            r"horizon_bundle::ensure\(\);",
            "without this the bundled data/versions is never copied into the launcher data "
            "folder, and a fresh unzip starts with an empty version list",
        )
        need(
            "the horizon_bundle module is declared",
            main_rs,
            r"^mod horizon_bundle;|^\s*mod horizon_bundle;",
            "the file exists but is not compiled in",
        )

    print("== 6. the version the patch pins ==")
    cargo = read(root, "launcher/Cargo.toml")
    lock = read(root, "launcher/Cargo.lock")
    if cargo:
        m = re.search(r'^version = "([0-9][^"]*)"', cargo, re.MULTILINE)
        if not m:
            fail("launcher/Cargo.toml has a version", "no top-level `version = \"…\"`")
            toml_version = None
        else:
            toml_version = m.group(1)
            ok(f"launcher/Cargo.toml version = {toml_version}")
    else:
        toml_version = None
    if lock:
        m = re.search(r'^name = "horizon-launcher"\s*\nversion = "([^"]+)"', lock, re.MULTILINE)
        if not m:
            fail(
                "launcher/Cargo.lock agrees with Cargo.toml",
                "no horizon-launcher entry; `cargo build --locked` will fail on a version mismatch",
            )
        elif toml_version and m.group(1) != toml_version:
            fail(
                "launcher/Cargo.lock agrees with Cargo.toml",
                f"Cargo.toml says {toml_version}, Cargo.lock says {m.group(1)}; both must move "
                f"together or `cargo build --locked` fails",
            )
        else:
            ok(f"launcher/Cargo.lock agrees with Cargo.toml ({m.group(1)})")

    print()
    if FAILURES:
        for line in FAILURES:
            print(f"::error title=Offline port invariant moved::{line}")
        print(f"{len(FAILURES)} of {CHECKS} contracts moved — regenerate "
              f"tools/ci/offline-port.patch against the new upstream commit")
        return 1
    print(f"all {CHECKS} contracts hold")
    return 0


if __name__ == "__main__":
    sys.exit(main())
