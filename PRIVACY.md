# Privacy

Earl runs on your Mac. Nobody else, including whoever made Earl, receives
your recordings, transcripts, notes or settings. There is no account,
analytics or crash reporting.

**What Earl stores, all on this Mac:**

- Each meeting in its own folder under `~/Meetings` (you can change it):
  audio, transcript, notes, and the voices found in it.
- Settings, models and remembered voices (only if you turn that on) in
  `~/Library/Application Support/Earl`.

**What goes over the network:**

- Your notes model, at the address in Settings → Notes (LM Studio on this Mac
  by default). If you point it at another computer, transcripts go there.
- Model downloads from Hugging Face, only when you click Download.
- Your calendar is read through Apple Calendar, which syncs with your accounts
  as usual. Earl doesn't add anything to it.

**Keep only the text.** Settings → This Mac → Privacy. Audio is deleted as
soon as a meeting is transcribed, no voice fingerprints are kept, and Earl
doesn't recognise voices across meetings. While a meeting is being recorded,
its audio is on this Mac until it's transcribed.

**Deleting.** Delete a meeting from its menu (it goes to the Trash), its
audio alone, or all old audio from Settings → Storage. Remembered voices can
be deleted one by one or all at once in Settings → Speakers.

**Your responsibility.** Earl records and transcribes other people. Whether
you may do that depends on where you are and who you're with: in many places,
including Germany, recording a private conversation needs everyone's consent,
and at work your employer's rules apply. Tell people when Earl is taking
notes.
