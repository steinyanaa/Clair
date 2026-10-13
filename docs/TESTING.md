# Testing and measured results

All numbers below were measured during development on one machine (Apple M5, 24 GB,
macOS 26.7) with public, synthetic French speech. They describe that environment only.
The full log in Chinese is in [TESTING.zh-CN.md](TESTING.zh-CN.md).

## How to run

| Command | What it checks | Needs |
|---|---|---|
| `scripts/test.sh` | Unit tests: transcript rules, sentence merging, filler cleanup, uncertain-word rules, storage (autosave, project move, soft delete, permanent delete), Markdown parsing, study-context limits | nothing |
| `scripts/test.sh --bench` | Library save / load timings on 200 one-hour classes | nothing |
| `scripts/test.sh --recognize <audio>` | Recognition output with per-word confidence | French speech assets |
| `scripts/test.sh --pipeline <audio> [--realtime]` | Recognition → translation → save → reload | running model service |
| `scripts/test-captions.sh` | Caption layout in a hidden window: drafts, settled lines, width changes, unchanged row height while a line is re-translated | nothing |
| `scripts/test.sh --model` / `--study` | Translation samples / assistant minutes and cited answers | models |

`scripts/make-sample-audio.sh` synthesises the public test lecture from `Tests/french-sample.txt`.

Timing diagnostics for live captions: launch a separate dev build with `-ClairClassDataRoot <temporary-directory> -ClairClassSpeechDiagnostics` (also accepted by `scripts/test.sh --recognize/--pipeline`). One timing-only JSONL file per run is written into that directory; it contains no audio or transcript text. The 0.5.2 measurements are in the [changelog](../CHANGELOG.md).

## Recognition under interference

Word error rate (WER) of Apple's on-device recogniser on the public lecture:

| Condition | WER |
|---|---|
| Clean, music at 0 dB SNR | 0.00 |
| White noise 10 dB / 0 dB | 0.00 / 0.03 |
| Background voices 5 dB / 0 dB / −5 dB | 0.00 / 0.33 / 0.94 |
| Reverberant far field + voices | 0.59 |

Background voices and echo are the real weak points. Tried and **not** adopted because
they gave no measurable gain or made things worse: Apple's speech detector module
(identical WER), contextual vocabulary (identical WER) and Apple's voice isolation as a
pre-filter (white 0 dB 0.03 → 0.20, voices 0 dB 0.33 → 0.86, far field 0.59 → 0.95).

## Translation

- Pauses split sentences: on a 37.8 s lecture with seven mid-sentence pauses, the
  previous pipeline produced 7 lines (4 sentence fragments); the current one produces
  4 lines (1 fragment, where the recogniser missed a full stop), translated as whole
  sentences.
- In older data 14.5 % of lines had used the system fallback; those lines are now
  re-translated with Gemma when the queue is idle. The model service restarted within
  3 s after being killed.

## Class presets and context

16 lecture sentences whose correct translation depends on the field (fonction, corps, base, titres, cour, vers, moment…) or on the previous sentence (pronouns, «La seconde, non.», «Deux.»), scored automatically (required sense present, wrong sense and leaked context absent):

| Prompt | Correct | Context cases | Median time |
|---|---|---|---|
| Original | 10/16 | 3/6 | 0.29 s |
| + subject | 10/16 | 3/6 | 0.27 s |
| + subject + previous sentences (inline) | 12/16 | 5/6 | 0.36 s |
| + subject + previous sentences (separate blocks, shipped) | 13/16 | 6/6 | 0.33 s |

The remaining misses were field terms the 4B model does not know (corps → 域, base → 碱, moment → 力矩); with a term list all three were translated as given, and unrelated sentences were unaffected. `scripts/test.sh --context` re-runs the key cases against the local model.

## Uncertain-word marks

Calibrated on 928 words from 16 recordings (3 voices, 8 interference conditions),
aligned to the reference text:

| Rule | Marks per 100 words | Marks that were real errors | Errors marked |
|---|---|---|---|
| Any word, confidence < 0.6 | 11.7 | 47 % | 59 % |
| Content words, confidence < 0.5 (current) | 2.7 | 68 % | 20 % |

Some recognition errors carry high confidence and cannot be marked.

## Not verified

Real classroom recordings (accents, students speaking, room noise), the 12B models in
real time, VoiceOver end to end, multiple displays.
