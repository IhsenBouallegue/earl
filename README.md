# Earl

A local meeting notetaker for macOS. Earl lives in the menu bar and records
the call audio and your mic, with no bot joining the call. It transcribes with
whisper.cpp, works out who said what, and writes notes with a local model in
LM Studio. Everything runs on your Mac.

## Install

Needs a Mac with Apple silicon and macOS 26. Open **Terminal** and paste:

```sh
curl -fsSL https://github.com/IhsenBouallegue/earl/releases/latest/download/install.sh | bash
```

That puts Earl in `~/Applications` and opens it; the setup window does the rest
(about 1.7 GB of listening models). Earl then updates itself. The same command
updates a copy by hand. Other ways, and why Terminal: [docs/INSTALL.md](docs/INSTALL.md).

## Build from source

Developers use `./setup.sh`:

```sh
./setup.sh      # whisper.cpp, models (~1.6 GB), signing certificate, builds ~/Applications/Earl.app
```

Open **Earl** from `~/Applications`. macOS asks for these permissions when
they're first needed:

- **Microphone**, for your voice.
- **Screen & System Audio Recording**, for the other participants. After
  allowing it, quit and reopen Earl.
- **Calendar** (optional), for meeting titles and attendees.
- **Reminders** (optional), only when you send to-dos there.

**Notes** need a model in LM Studio. Earl starts the server and loads the
model itself, with a context large enough for the meeting. On an M-series Mac
with 64 GB or more, `qwen/qwen3.8-27b` with thinking off gives the best notes
(about 2 min per 30-minute meeting). `google/gemma-4-e4b` is the fast
fallback. See `docs/benchmarks.md`.

**Speaker models** are downloaded from Under the Hood → Speakers: speaker
separation (22 MB), and optionally the live stage (106 MB). Earl never
downloads anything without showing it.

If Earl's icon is missing from the menu bar, the notch is hiding it: remove
some menu bar items, or open Earl from Spotlight.

## Recording

- **⌃⌥⌘R** starts and stops recording from any app. You can change the
  shortcut in Settings.
- **Call detection:** when Teams, Zoom, Meet (in a browser), Webex, Slack or
  FaceTime starts using the mic, Earl offers to record. It also asks when the
  call ends. The offer appears as a notification, as a dot on the menu bar
  icon, and as a small floating panel. The panel stays visible while you share
  your screen, and the people watching don't see it.
- **Next meeting:** the sidebar and the menu bar show your next meeting from
  the calendar. **Record at 14:00** arms a recording, which starts on time or
  as soon as the call begins. Recordings take the event's title and attendees.
- **Paste Invite…** (in a meeting's More menu) adds the title and attendees
  from an invite that isn't in any calendar the Mac can see, for example one
  inside Citrix.
- **Live stage:** while recording, each voice gets a face whose mouth moves
  when that person talks.

## After the meeting

- **Transcript:** your voice is **Me**. The call audio is split into
  **Speaker 1, 2, …**
  - Click a speaker to name, confirm or merge them.
  - Earl guesses names from the conversation and the attendees, and marks
    them "Sarah?" until you confirm.
  - **Remember voices** (opt-in) recognises people you've named before in
    later meetings.
- **Click a timestamp** to hear that moment. Space plays and pauses.
- **Notes:** summary, decisions, action items with owners, and open
  questions. They're written in the meeting's language, or the one you set.
- **To-dos:** every action item from every meeting in one list (Mine /
  Everyone / Done). Ticks are saved to the notes, and items can be sent to
  Reminders.
- **Vocabulary** (Settings): names and terms Whisper should spell right.
- **Echo cleanup:** on laptop speakers, Earl removes the other side's voice
  from your mic track. Headphones are still cleanest.

## Earl remembers

- **Series:** meetings with the same calendar title (a daily, a weekly, a jour
  fixe) belong together. The sidebar lists them under **Series**; a series
  page shows what's still open and every earlier meeting.
- **Notes that remember:** a meeting's notes know what was decided, asked and
  promised last time, and say what moved in **Since last time**. Stand-ups get
  **Round the table**, one line per person.
- **Notes that fit the meeting:** not every meeting decides things. At a town
  hall Earl keeps the announcements, what's asked of you and the Q&A; at a
  talk or demo, the points worth remembering. Earl tells from the calendar and
  from who did the talking (when you barely spoke and it can't tell, it asks
  the notes model once). The kind shows under the headline; choose another and
  the notes are rewritten, and the series' next meetings follow it.
- **Earl's brief:** before the next meeting of a series, the sidebar card and
  the menu bar offer a brief: your open to-dos, what others owe you, the open
  questions and who's coming. Ten minutes before, Earl sends it as a
  notification when something's still open (Settings → Calls → Briefs). The
  brief is put together from your notes, without the model, so it's instant.
- **Ask Earl** (⌘J on a meeting, or type a question in ⌘K): ask about a
  meeting, its series or everything. Answers come from your transcripts and
  notes through LM Studio, with clickable moments. "Write a recap email" works
  too.
- **Edits are instant:** naming, confirming or merging a speaker changes the
  notes in place, without writing them again. Double-click any line of the
  notes (or use the pencil) to correct it; change a to-do's owner from its
  menu.

## Files

Each meeting is a plain folder in `~/Meetings/` (the location can be changed):

| File | Contents |
|---|---|
| `transcript.md` | Title, notes and transcript, readable anywhere |
| `summary.md` | The notes; ticks on action items are saved here |
| `meeting.json`, `transcript.json`, `speakers.json` | Used by the app |
| `system-16k.wav`, `mic-16k.wav` | Audio. Turn off *Keep audio* in Settings to delete it after transcribing |
| `whisper.log` | Processing log, useful when something fails |
| `questions.json` | Questions you asked Earl about this meeting |

Remembered voices are stored in `~/Library/Application Support/Earl/voices.json`
(only you can read it). Delete them any time in Settings.

## Development

```sh
./build.sh                      # build, sign and install ~/Applications/Earl.app
./test.sh                       # unit tests (works with only the Command Line Tools)
tools/make-test-meeting.sh hard /tmp/call --seed 1   # synthetic meeting with a known answer
tools/eval-diarization.sh       # speaker separation evaluation (slow)
tools/eval-echo.sh              # echo cleanup evaluation (slow)
```

- `CLAUDE.md` has the rules for examples and what goes in the public repo.
- `docs/benchmarks.md` has the measured results. Rerun an evaluation only
  when a change could move its numbers.
- The app is signed with a local "Earl Local Signing" certificate
  (`tools/make-signing-cert.sh`), so macOS permissions survive rebuilds.
- Data formats: new JSON fields are optional with defaults. Never rename or
  retype a field; add a new one. Each release that changes a format adds a
  `Tests/EarlTests/Fixtures/compat-<version>` fixture, and `CompatTests` must
  keep reading the older ones.

### One-time setup for updates

Earl updates itself through Sparkle once a feed is configured. Do this once:

1. `swift build -c release`, then `.build/artifacts/sparkle/Sparkle/bin/generate_keys`.
   It stores the private key in your login keychain and prints the public key.
2. Put the public key in `release.env` as `EARL_SPARKLE_PUBLIC_KEY=`.
3. Back the private key up: `tools/backup-signing-cert.sh export-sparkle`, store
   the file in a password manager, delete it. (`restore-sparkle <file>` brings it back.)
4. Choose where the files are hosted and set `EARL_FEED_URL` (the appcast.xml
   address) and `EARL_DOWNLOAD_BASE` (the folder holding the zip) in `release.env`.

Then `tools/release.sh` also writes a signed `dist/appcast.xml`; upload it with the
zip. Environment variables of the same names override `release.env` for one run.
