# Engines/Ollama — the user's own Ollama server as an engine

Opt-in, never the default, no model names in code. Read root `AGENTS.md` and
`Engines/AGENTS.md` first. Measured 2026-10-08 against Ollama 0.13.0 and 0.40.1.

## Why `/api/chat`, not `/v1/chat/completions`
The field shows `http://localhost:11434/v1`, as other tools do; `OllamaServer`
drops one `/v1` for the native API. With `truncate` unset, 0.13's runners kept
an over-long prompt's first `num_keep` tokens and dropped the next ones, where
the frame and instruction sit, and `/v1` cannot unset it. `truncate: false`
refuses instead; `shift: false` ends a full window as `"length"`. 0.40.1's MLX
runner never cuts and `/api/ps` gives a soft limit (32,768); runners word the
refusal apart, so an error naming "context length" or "size" is `inputTooLong`.
`think: false` never errors, even on a model that cannot think: 7.5 s → 0.8 s.
`keep_alive: "24h"` on every chat: Ollama unloads after 5 idle minutes (`gemma4:26b` then took 6.7 to 11.4 s to reload), the Mac app's own setting (`launchctl setenv OLLAMA_KEEP_ALIVE`) is read only at launch and gone on reboot, and the request's value wins over it (0.40.2, 2026-10-09: `expires_at` 86,400 s after the last request). `-1` would hold a user's RAM until stopped.

## What reaches the server, and what does not
- The dropdown is `/api/tags` minus entries with `remote_host` (cloud models run
  on ollama.com). Every rewrite re-reads it and refuses a saved name that is no
  longer local there, before any POST: a switched server, a removed model.
- The window is `/api/ps`'s `context_length` for the loaded model, else 4,096.
- An ephemeral `URLSession`, stores off (`PRIVACY.md`: nothing reaches disk), no
  logging, and no redirects: a 307 or 308 would re-send the text elsewhere.
- ATS, probed 2026-10-08: loopback always passes; internet http is -1022, `needsHTTPS`.

## Splitting (`TextSplitter`)
A prompt is at most window / 2.4 tokens, so a 1.4× answer fits beside it; a
window that cannot hold the prompt alone refuses before sending. Tokens are
UTF-8 bytes ÷ 3, a sizing guess: live, prose ran 5 bytes a token, but dense code
2 and emoji 1.8 to 2.6 (`qwen3:14b`, `qwen3.5:9b`), so those are undercounted;
the 1.4× room covers most of it, and past that Ollama refuses: nothing replaced.

Boundaries, best first: blank line, sentence end, line break, space. The best
kind in reach wins, then the one nearest an even split. Never inside a word: an
oversized word refuses the rewrite rather than cut a link or a number.
- A sentence end from `NLTokenizer` counts only with whitespace after it, or
  after 。！？ and closing quotes (ASCII " counted by parity, as `EmDashes` does):
  it broke `…/Q3.Report?Region=…` and `../Reports.Q3/Overview` mid-word, and
  hands the next sentence its opening 「 or ", cut before. Not before a digit
  ("Oct. 12." came back as two). Lowercase starts stay: casual writing.
- Code (`EmDashes`'s backtick rule) and links (the space-free run around `://`:
  a `。` in a path reads as a sentence end) stay whole when they fit a piece.
- Bytes between pieces stay the user's; the model's edge whitespace is dropped.
- Pieces get `OutputValidator.checked`; typography runs once on the joined text
  (the coordinator's `validate`): per piece, `EmDashes`'s backtick count started
  over and turned `b = 2 -- c` inside code into `b = 2, c`.
- A fixed "part N of M" note; pieces never see each other (Concise is per piece).

## Stopping
`done_reason` must be `"stop"`: `"length"` is `GenerationError.truncated`,
anything else or none is `interrupted`; nothing after it is read (a later
"stop" could hide a "length"), and a blank piece stops the rest.
Cancelling runs through `TransactionBox`, the chat stream and the transport's
`onTermination`, which cancels `bytes.task`; it is re-checked after discovery,
before every POST and after every answer, in one task (a nested stream hid it).

## Seam
| Seam | Production type | Tested with |
|---|---|---|
| `HTTPTransport` | `URLSessionTransport` | `ScriptedTransport` (replies copied from a real server); `OllamaLiveTests` against the real one with `EVEREST_OLLAMA_LIVE=1` |
