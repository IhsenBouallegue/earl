# Rules for this repo

## Examples are made up

Anything an example, test fixture, demo, comment or plan quotes must be
invented. Never copy it from a real invite, meeting, calendar, email or chat.

- People: made-up names only (Anna, Ben, Sarah Müller, Priya Raman …). A new
  full name goes into `tools/public-allow-names.txt` on purpose.
- Mail and web addresses: `example.com`, `example.org`, `example.net`,
  `example.de`, plus the placeholders in `tools/public-allow-domains.txt`.
- Organisations, teams, rooms, distribution lists: invented, or "Example AG".
- Never a real client, employer, colleague or project name, and no home paths.
- When a plan or request mentions a real situation, write the example from
  scratch; do not carry its details into code or tests.

## Public repo

Earl is also published as a separate, history-free repo built by
`tools/export-public.sh` from an allowlist of paths. `docs/plans/`,
`docs/design/`, `.impeccable/`, `PRODUCT.md` and `DESIGN.md` stay private.
`tools/check-public.sh` runs on every commit (hook in `.githooks/`) and on the
export; fix what it reports, never loosen its allowlists to get past it.
Optionally keep extra regexes for names you know in `~/.config/earl/private-patterns`.

New JSON fields are optional with defaults; never rename or retype a field.

## Settings and sandbox copies

Read and write settings through `Prefs.defaults` (and `@AppStorage(..., store: Prefs.defaults)`),
never `UserDefaults.standard`, and keep paths under `Prefs.supportDir` / `Prefs.expand`. That is
what lets `tools/sandbox.sh` run copies of Earl with data of their own beside the real one.
System-wide things (shortcut, call detection, notifications, updates) start only when
`Sandbox.isActive` is false.
