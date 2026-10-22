# Benchmarks

Measured on the dev Mac (Apple silicon, M3 Max), September 2026. These runs took
hours of machine time, so rerun them only when a change could move the numbers.
Synthetic meetings come from T-1 (`tools/make-test-meeting.sh`). Real-meeting
figures are numbers only; the meetings themselves are confidential.

## Transcription (Whisper large-v3-turbo + VAD), T-1 baseline

Words lost against the script, seed 1, 5 min:

| Preset | Lost overall | In crosstalk | In overlaps | Elsewhere |
|---|---|---|---|---|
| clean | 0.8 % | – | – | 0.8 % |
| realistic | 4.7 % | – | 29.7 % | 1.8 % |
| hard | 6.3 % | 51 % | 17.7 % | 2.5 % |
| german | 20.5 % | – | 26.3 % | 20.2 % |

- In mixed German/English meetings Whisper translates the English lines, which
  is most of the German loss.
- Crosstalk and "mhm" interjections are lost at the Whisper stage, not by
  speaker separation.

**Vocabulary (R1-3):**
- "Skyfeld / Carnet / Asan" became "Skyfield / Carnot / Ahsan" with the
  prompt.
- `--carry-initial-prompt` repeated about 18 % of the text with VAD, so it's
  off.

## Parakeet TDT v3 against Whisper (V-1), October 2026

Parakeet TDT 0.6B v3 ships with FluidAudio 0.17.1: 25 European languages,
language found on its own (no prompt, no language setting; an optional
`Language` hint only filters the script), word timings from its tokens, on
the Neural Engine. 476 MB download (int8 encoder), against 1.6 GB for Whisper
large-v3-turbo. Measured with `ASREngineEvalTests` (`EARL_EVAL_ASR=1`): both
tracks, the call track diarized, Whisper as Earl runs it (auto language,
names as the prompt).

| Preset, seed | Engine | Words lost | In overlaps | Right speaker | Time, both tracks + voices |
|---|---|---|---|---|---|
| clean, 1 | Whisper | 1.2 % | – | 93.3 % | 48 s |
| | Parakeet | 1.6 % | – | 94.2 % | 8 s |
| realistic, 1 | Whisper | 3.2 % | 14.9 % | 91.2 % | 45 s |
| | Parakeet | 4.6 % | 29.7 % | 96.8 % | 11 s |
| realistic, 2 | Whisper | 2.6 % | 12.5 % | 93.0 % | 15 s |
| | Parakeet | 4.6 % | 33.0 % | 93.0 % | 9 s |
| german, 1 | Whisper | 23.7 % | 42.1 % | 94.5 % | 18 s |
| | Parakeet | 19.5 % | 34.2 % | 92.9 % | 16 s |
| mixed, 1 | Whisper | 22.7 % | 24.7 % | 88.7 % | 34 s |
| | Parakeet | 15.3 % | 26.0 % | 96.0 % | 20 s |
| mixed, 2 | Whisper | 12.6 % | 20.6 % | 97.1 % | 15 s |
| | Parakeet | 15.8 % | 39.7 % | 96.0 % | 7 s |

- `mixed` (new in V-1) is a German meeting where one person speaks only
  English. Their own words: Whisper lost 6.6 % and 4.4 %, Parakeet 4.9 % and
  5.6 %. Whisper didn't translate them here; most German-preset loss is the
  German `say` voices reading the pool's English lines, which both engines
  mangle.
- Parakeet loses twice as many words in overlaps (interjections over
  someone else).
- The first Parakeet load (compiling for the Neural Engine) took 45 s, later
  loads 0.1 s. Its own transcription is 30–60× real time, so with Parakeet
  the speaker model sets the pace.

**Real meetings** (numbers only), the same diarization for both:

| Meeting | Engine | Words | Turns | Under 3 words | Over 90 s | English sentences | Time |
|---|---|---|---|---|---|---|---|
| German, 15 min | Whisper | 1690 | 78 | 14 | 0 | 0 | 43 s |
| | Parakeet | 1806 | 85 | 14 | 0 | 1 | 23 s |
| Mixed, 46 min | Whisper | 5671 | 160 | 28 | 7 | 8 | 105 s |
| | Parakeet | 5683 | 293 | 88 | 0 | 13 | 63 s |

- Parakeet on the call track alone of four German meetings (122 min, 59 s in
  all): 1, 1, 0 and 9 English sentences where Whisper had 1, 0, 0 and 3. One
  English passage was confirmed translated into German by Whisper. Translation
  is real but rare in these meetings.
- Parakeet writes German "mhm" on the mic as "Mm-hmm" or "Uh-huh", and
  transcribes more of the quiet mic, which splits the other side's turns
  (88 short turns against 28).

**Decision: keep Whisper.** Parakeet is 2–5× faster and runs cool on the
Neural Engine, but it lost more words on English in both `realistic` seeds,
won only one of two `mixed` seeds, takes no vocabulary prompt (FluidAudio's
vocabulary boosting needs a separate English CTC model for v3), and turns
German backchannels into English fillers. No FluidAudio update is needed for
any of this.

## Real meetings audit (V-1), 34 meetings, 680 min

Read-only over the transcripts, speakers and logs. The 19 meetings recorded
since the Q-1 to Q-3 changes are counted apart where it matters.

| Problem | Measured | Fixed in V-1 |
|---|---|---|
| Voices left unnamed | 29 % of call words (median, recent meetings) | no (two names on one person: yes) |
| Words stretched over pauses VAD cut out | 151 words over 3 s, 2,505 s in all, on one 46-min call; 79 turns over 90 s, 31 % of meeting time | yes: 7 turns over 90 s → 0 on that call |
| Two speakers with the same name | 2 meetings | yes |
| English translated into German | 0–9 English sentences per German meeting (Parakeet screen) | no |
| Echo left on "Me" | about 9 lines in the 2 meetings on speakers | no |
| Call audio never captured | 1 meeting (8 min of digital silence) | the note now says so |
| Hallucinated lines, repeats | 2 lines; 13 repeated sentences, all before Q-1 | – |

- **Stretched words:** with `--vad`, whisper's one-word segments tile the
  timeline, so the word next to a cut-out pause gets the whole pause (one
  "Mhm." ran 71 s). On synthetic meetings 19 of 20 such words were really said
  at the end of their span, except a lowercase word ending a sentence, said at
  the start. `StretchedWords` moves them there. Synthetic scores barely move
  (words lost +0.2 and +0.5 points, right speaker ±0 and +0.7).
- **Voice memory scores** on real meetings: 20 matches, 0.74–0.96, median 0.91.
- **Short turns:** 194 under 3 words (10 %); 17 of 84 short call turns sit
  between two turns of the same other voice within 1 s.

## Speaker separation (R2-2, FluidAudio 0.17.1)

Words attributed to the right speaker, 9 seeds × 5 min:

| Preset | Right speaker |
|---|---|
| clean | 91 % |
| realistic | 94 % |
| german | 92 % |
| hard | 81 % |

**Overlaps (0.3–1 s):**
- 34 % of words inside overlaps are lost, against 1 % outside.
- Of the words kept, 89 % are attributed correctly.

**Speed:** a 60-min meeting takes 81 s for diarization and 119 s for Whisper;
run side by side, 136 s in total.

**Failure modes:**
- Similar voices (Samantha/Karen) merge, which is the main loss on `hard`.
  Lowering the AHC threshold to 0.5 fixed `hard` (+5.7 points) but
  over-splits clean meetings, so it was rejected.
- A real call split a quiet participant into 3 tiny voices (voice-print
  cosine 0.13–0.40 to the main voice, 0.52–0.63 to each other). Small-voice
  consolidation (`SpeakerConsolidation`) merges them.
- Same person across halves of a meeting: cosine ≥ 0.90. Different people:
  ≤ 0.59.

## Voice memory (R3-3)

Voice prints only (diarization, no Whisper, no LLM): 12 `realistic` meetings
of 4 min (3 seeds × enroll / later / shifted / strangers), 43 s of
diarization, about 4 min in total with `say`. `VoiceMemoryEvalTests`.

Cosine to a stored print, voices of 10 s and more:

| Pair | Range |
|---|---|
| Same voice, later meeting | 0.95–0.99 |
| Same voice, pitch ±6 % or speed ±15 % | 0.65–0.97 |
| Other people | ≤ 0.62 |
| Karen against Samantha (the pair R2-2 merges) | 0.59–0.67 |

Thresholds 0.75 (strict) and 0.70 (name or email among the attendees),
maximum over a voice's samples, greedy one to one:

| Attendees | Known people named right | Wrong names |
|---|---|---|
| none | 85 % (100 % unshifted, 73 % shifted) | 0 |
| the people there | 92 % | 0 |
| everyone in the library, present or not | 92 % | 0 |

- 0.65 for attendees named Karen "Sarah" 3 times out of 44 when Sarah was
  invited but absent.
- The mean of the samples scored like the maximum (hardest match 0.69 vs 0.71).

## Live speaker stage (R2-5, streaming Sortformer)

Right face while exactly one remote person talks:

| Preset | Right face |
|---|---|
| clean | ~92 % |
| realistic | 67–80 % |
| hard | 74–87 % |

- A new voice gets its own face after about 1.5 s of talk.
- The active face switches about 0.4–0.5 s after the speaker changes.
- Processing takes about 0.1 s per second of audio.
- Rolling voice prints were rejected (26–53 % right).
- Sortformer tracks at most 4 voices.

## Echo cleanup (R2-4), `speakers` preset, 3 seeds, 726 own words

| Method | Echo words on "Me" | Own words lost |
|---|---|---|
| Raw mic | 1714 | 14 |
| Old text filter | 25 | 40 |
| Gate + text (shipped) | 7* | 21 (2.9 %) |

\* All 7 were the user's own words, counted by the scorer's alignment. None
were call audio.

- The gate mutes 97–98 % of echo-only time and 0 % of own speech.
- It costs about 1.7 s per hour of audio.

## Meeting notes (R2-7, LM Studio)

**Synthetic.** 12 meetings (English, German, and "send me X" cases), new
prompt, thinking off:

| Model | Owners right | Right language | 30-min meeting |
|---|---|---|---|
| qwen3.8-27b (Q4_K_M) | 100 % | 12/12 | 112 s |
| bonsai-27b (ternary MLX) | 97 % | 12/12 | 83 s |
| gemma-4-e4b | 99 % | 12/12 | 40 s |

- With thinking on, owners were never better, and runs took 3.5–7× longer
  (bonsai: 292 s; qwen: 551 s on a real meeting).
- The old prompt, with the language rule only in the system prompt, gave notes
  in the right language 6–8 times out of 12.
- `reasoning_effort: "none"` is the only switch that disables thinking in LM
  Studio.

**Real 30-min German meeting**, old prompt:
- gemma wrote English and reversed who owed a chat link;
- qwen with thinking on got it right, but took 9 minutes, with the fans at
  full.

**LM Studio loading:** models loaded on demand get an 8k context. That caused
an empty summary, and it's why Earl now loads the model itself.

**Name guessing** (R2-3):
- With attendees, 100 % precision and 83 % coverage (thinking on).
- With thinking off, it takes 16 s instead of 3–5 min, with no wrong names but
  1–2 of 4 voices named.
- A guess is only kept when the name is said right next to that speaker's
  turn. Without that check, 2 of 12 guesses were wrong.

**Notes that remember** (S-1, `SeriesNotesEvalTests`): 3 hand-written
series meetings (an English daily, a weekly, a German daily). The earlier
meetings name items that today's transcript never mentions. gemma-4-e4b, thinking off,
about 20–25 s per meeting:
- Earlier items copied into today's Decisions or Action items: 0 in 4 runs.
- "Since last time" with the spec's wording alone: left out 2 of 3 times, and
  never marked "done". With an extra line naming the section and the
  `- Done: <to-do>` form: present in 2 of 3, with done right in 2 of 3.
- With or without context, gemma often writes action items without `[ ]`
  on these short transcripts (3 of 3 without context), so they aren't tickable.

## Built-in notes models (D-3), 2026-10-14

For Macs with no LM Studio or Ollama models: one GGUF per memory tier, run by
the bundled llama-server (b11613, `-c 32768 -ngl 999 -fa on --jinja -np 1`),
thinking off (`reasoning_effort: "none"`, checked per model: no reasoning in
the answer). `NotesEvalTests`, new prompt, presets realistic + german, seeds
1–6 (6-minute meetings, 12 per model; the 27B seeds 1–3). Q4_K_M from
lmstudio-community; Apache-2.0 throughout.

| Model | File | Owners right | German meetings: owners, language | s/meeting | Notes |
|---|---|---|---|---|---|
| **Qwen3.5 4B** (8 GB tier) | 2.7 GB | 85/86 (98.8 %) | 35/35, 6/6 | 11 | "Send me X" cases: 7/10 owners |
| gemma-4 E4B | 5.3 GB | 83/85 (97.6 %) | 35/36, 6/6 | 13 | |
| **Qwen3.5 9B** (16 GB tier) | 5.6 GB | 86/87 (98.9 %) | 34/35, 6/6 | 15 | "Send me X": 6/6 owners, 2 of 4 items missed |
| **gemma-4 12B** (32 GB tier) | 7.4 GB | 86/87 (98.9 %) | 36/36, 6/6 | 24 | "Send me X": 10/10 |
| Qwen3 14B | 9.0 GB | 83/86 (96.5 %) | 32/34, 6/6 | 37 | |
| **Qwen3.8 27B** (64 GB tier) | 16.8 GB | 43/43 (100 %) | 18/18, 3/3 | 49 | |

- No model under 27B reached 100 % owners: each one swapped one to three of
  about 86 owners: a task Me agreed to, written down for the person who asked,
  or a task swapped between two other people. The plan's fallback (the next smaller model that
  does) has nothing to fall back to, so each tier keeps its best.
- 16 GB tier: Qwen3.5 4B and 9B made one mistake each; the 4B led on German,
  but on the `requests` presets (built from a real meeting where a 4B gave
  "send me the link" to the person who asked) it reversed 3 of 10 owners, the
  9B none. 9B chosen.
- 8 GB tier (Macs under 16 GB): Qwen3.5 4B, the only candidate small enough;
  same owners as the 9B on these presets, but weaker on "send me X".
- 32 GB tier: gemma-4 12B ties the 9B on owners and is perfect on German
  meetings and the requests cases; Qwen3 14B was worse and slower.
- Speeds were measured with LM Studio's own 27B loaded alongside, on the M3
  Max; gemma-4 E4B ran 16 s on seeds 1–3 and 10 s on seeds 4–6, so treat
  small differences as noise.
- Qwen3 *Thinking*-2507 models were left out: they always think, and the
  reasoning ends up in the notes.

## Notes that remember (S-1), real weekly, qwen3.8-27b, thinking off

Notes-only replay (`EARL_REPROCESS_NOTES_ONLY=1`) of a 46-min German weekly
with 3 earlier meetings (1,378 characters of series context): about 150 s,
the same as without context.

- First prompt: 4 of 5 "Since last time" lines said "Done", one of them
  inferred ("implicitly done, nobody raised it as a blocker"), with
  explanations in brackets.
- Rule added (done must be said today, never inferred; leave out items nobody
  mentioned; one short line, no brackets): 3 lines, none marked done without
  being said, each saying what moved.

## K-1 · Notes that fit the meeting (real library, counts only)

26 meetings with notes. Before K-1 every one had Decisions (2–7) and Action
items (1–10), including the 11 where the author said ≤ 5 % of the words.

Kinds without the model: 6 stand-ups, 3 talks (a 95-invite webinar, a
46-minute "daily" that was a product demo, a guild weekly), 2 one-to-ones;
5 left to the model. qwen3.8-27b (thinking off) on those 5, ~25 s each: 5 of 5
as judged by hand (two all-hands → town hall, three coordination calls →
working). The first prompt, with the opening only, called one all-hands a
talk; start + middle + end and the voice counts fixed it.

Notes replays (notes only, temporary copies, qwen3.8-27b):

| meeting | before | after |
|---|---|---|
| webinar, author silent | 4 decisions, 3 action items (the presenter's) | talk: 10 key points, 2 Q&A, 1 for you; 172 s |
| demo "daily", author silent | 4 decisions, 3 action items | talk: 8 key points, 8 Q&A, 0 for you after the invitation filter; 84 s |
| all-hands, author silent | 3 decisions, 3 action items | town hall: 5 announcements, 2 for you (vote, try the new agent), no empty Q&A; 27 s |
| coordination call, author 1 % | 6 decisions, 6 action items | working: 4 decisions, 6 action items |

The rule "advice and 'reach out if…' aren't to-dos" was ignored above the
template and followed inside it; one German "bei Bedarf … wenden" still
slipped through, now dropped by `NotesTidy`.

## Ask Earl: tasks, not only lookups (real meeting copy, qwen3.8-27b)

Before: a ticket summary and a "what did I learn" recap of a 46-minute call
both came back "The notes don't say." (the prompt demanded a cited line per
sentence and [[none]] when unsure). After, same meeting and questions:

| question | records | answer |
|---|---|---|
| short summary for a ticket (German) | 23,100 chars | answered, 1,529 chars, 73 s |
| recap: what I learned, how they use it, where we help | 25,598 chars | answered, 3,420 chars, 9 citations, 122 s |
| a fact the meeting doesn't contain | 9,480 chars | "not found", 23 s |
| who brought up a topic | 6,483 chars | answered, 1 citation, 18 s |
