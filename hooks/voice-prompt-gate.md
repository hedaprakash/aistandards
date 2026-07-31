# Voice-Dictation Prompt Gate Hook

A portable `UserPromptSubmit` hook for Claude Code that catches speech-to-text
transcription errors before Claude starts work on long prompts.

## Why this exists

The user on this project dictates prompts by voice. Speech-to-text
introduces misheard words, merged phrases, and missing punctuation — often
in ways that change the meaning of the request. Acting on a mis-transcribed
prompt wastes turns and, worse, can produce the wrong outcome silently.

A blanket "always confirm before acting" rule is too noisy: short commands
like *"commit it"*, *"run the tests"*, *"show git status"* don't benefit from
a confirmation step and just add friction.

This hook splits the difference:

- **Short prompts (<= 15 words)** pass through untouched. Zero friction.
- **Long prompts (> 15 words)** trigger a restate-and-confirm flow. Claude
  must restate what it understood, flag likely mis-transcribed phrases, and
  present a native selection-box confirmation (Yes / No + clarify) via the
  `AskUserQuestion` tool before making any other tool call.

The 15-word threshold is a proxy for "complex enough that a transcription
error could change the intent." It's a heuristic, not a guarantee — see
*Caveats* below.

## How it works

1. Claude Code fires the `UserPromptSubmit` hook on every user prompt and
   pipes a JSON payload to the hook command on stdin. The payload contains
   the `prompt` field.
2. The hook script (`voice-prompt-gate.py`) reads stdin, counts words in
   `prompt`, and:
   - If word count <= 15: exits 0 silently, no context injected. The prompt
     proceeds as normal.
   - If word count > 15: prints a JSON payload with
     `hookSpecificOutput.additionalContext` containing instructions that
     tell Claude to restate its understanding and confirm via
     `AskUserQuestion` before doing any work.
3. Claude sees the injected context and runs the restate-confirm flow. The
   `AskUserQuestion` tool presents a native selection box:
   - **Yes, proceed** -> Claude starts the work.
   - **No, let me clarify** -> Claude waits for the user's correction,
     incorporates it, and re-confirms before proceeding.

The hook is advisory, not enforcing. It tells Claude what to do; Claude
chooses to follow. In practice that works because the instructions are
specific and the `AskUserQuestion` tool provides a clean UI the user wants
to use.

## Files

Two files live in the project:

```
.claude/hooks/voice-prompt-gate.py    # the hook script
.claude/settings.json                  # wires the hook into UserPromptSubmit
```

### `.claude/hooks/voice-prompt-gate.py`

```python
#!/usr/bin/env python3
"""
UserPromptSubmit hook — voice-dictation confirmation gate.

Prompts here come from voice-to-text and often contain transcription errors.
For any prompt longer than THRESHOLD words, this hook injects a reminder
telling Claude to restate its understanding and confirm via AskUserQuestion
before doing any work. Shorter prompts pass through untouched.

Installed at .claude/hooks/voice-prompt-gate.py, wired into
.claude/settings.json as a UserPromptSubmit command hook.
"""
import json
import sys

THRESHOLD = 15

try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)

prompt = (data.get("prompt") or "").strip()
word_count = len(prompt.split())

if word_count <= THRESHOLD:
    sys.exit(0)

reminder = (
    "VOICE-DICTATED PROMPT (>{n} words). Before any tool calls or work:\n"
    "1. Restate in 1-2 short paragraphs what you understood. Flag any phrases "
    "that look mis-transcribed and show your best-guess interpretation.\n"
    "2. Confirm via the AskUserQuestion tool. If its schema is not yet loaded, "
    "first call ToolSearch with query 'select:AskUserQuestion' to load it.\n"
    "3. Ask ONE question: 'Is this what you are asking?' with options:\n"
    "   - 'Yes, proceed'  -> start the work\n"
    "   - 'No, let me clarify'  -> wait for the user's correction, incorporate it, re-confirm\n"
    "4. Do NOT make any other tool calls until the user picks 'Yes, proceed'."
).format(n=THRESHOLD)

sys.stdout.write(json.dumps({
    "hookSpecificOutput": {
        "hookEventName": "UserPromptSubmit",
        "additionalContext": reminder,
    }
}))
```

### `.claude/settings.json` snippet

Merge this into the project's `settings.json`. If the file doesn't exist
yet, create it with this content as the whole file. If it already has
other keys, add only the `hooks.UserPromptSubmit` block — do not replace
existing settings.

```json
{
  "hooks": {
    "UserPromptSubmit": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "python <PROJECT_ROOT>/.claude/hooks/voice-prompt-gate.py"
          }
        ]
      }
    ]
  }
}
```

Replace `<PROJECT_ROOT>` with the absolute path to the target project.
Forward slashes work on Windows inside JSON strings.

## Install steps (portable, any project)

1. **Copy the script.** Drop `voice-prompt-gate.py` into the target
   project's `.claude/hooks/` directory. Create the directory if needed.
2. **Verify Python is available.** The hook shells out to `python`. On
   Windows, make sure `python` resolves on PATH, or change the command to
   the full interpreter path (e.g. `C:/Python315/python.exe`).
3. **Wire the hook into `settings.json`.** Use the snippet above. Choose
   the right settings file based on scope:
   - `.claude/settings.json` — committed, team-wide
   - `.claude/settings.local.json` — personal, gitignored
   - `~/.claude/settings.json` — global across all projects
4. **Pipe-test the script directly** before trusting the hook:

   ```bash
   # Short prompt -> silent, exit 0
   echo '{"prompt":"commit it"}' | python .claude/hooks/voice-prompt-gate.py
   echo $?   # 0, no stdout

   # Long prompt -> JSON payload
   echo '{"prompt":"this is a deliberately long voice-dictated prompt with more than fifteen words to trip the gate"}' | python .claude/hooks/voice-prompt-gate.py
   ```

   The second command should print a JSON object with
   `hookSpecificOutput.additionalContext`. Pipe it through
   `python -m json.tool` to confirm valid JSON.
5. **Reload the settings watcher.** A brand-new hooks block in a
   `settings.json` that was previously empty (`{}`) or had no `hooks` key
   may not be picked up by the running session's file watcher. Open the
   `/hooks` menu in Claude Code once to force a reload, or restart the
   session. Subsequent edits to an existing `hooks` block are picked up
   automatically.
6. **Verify end-to-end.** Submit a long prompt (>15 words). Claude should
   restate what it understood and present the `AskUserQuestion` selection
   box before doing any work. Submit a short prompt. It should proceed
   immediately with no restate step.

## Tuning

- **Threshold.** Change `THRESHOLD = 15` in the script. Lower = more
  prompts gated, more friction. Higher = fewer prompts gated, more risk
  of acting on a mis-transcribed long prompt. 15 was chosen because
  typical short commands are 2-8 words and genuinely complex asks tend to
  land above 15 words.
- **Reminder text.** The `reminder` string is what Claude sees. Edit it
  to change behavior — e.g. require flagging specific kinds of homophones,
  ask for a 3-paragraph restate, skip the `AskUserQuestion` step and use
  plain text, etc.
- **Different gate condition.** Word count is a proxy for complexity, not
  a perfect signal. If you want to gate on something else — presence of
  destructive keywords, mention of specific systems, prompts containing
  numbers or paths — replace the `word_count > THRESHOLD` check with
  your own predicate. The script's contract is simple: if you want to
  gate, print the JSON payload to stdout. If you want to pass through,
  exit 0 with no output.

## Caveats

- **Word count is not complexity.** A 6-word prompt like *"delete all
  files in project"* is short but dangerous and will not trigger the
  gate. Word count catches *misheard* long prompts, not *risky short*
  ones. If you want safety confirmation on destructive actions
  regardless of length, add a second rule — keyword-based, not
  word-count.
- **The hook is advisory.** It injects instructions into Claude's
  context. Claude follows them because they are specific and the
  `AskUserQuestion` UX is low-friction, but nothing physically blocks
  Claude from ignoring the reminder. If you need a hard block, use a
  `PreToolUse` hook with `decision: "block"` — but that only fires on
  tool calls, not on prompt submission, so it is a different shape.
- **Brand-new hooks may need a watcher reload.** As noted in step 5, the
  first install into a previously-empty `settings.json` may require
  opening `/hooks` once or restarting the session. This is a Claude Code
  file-watcher behavior, not a bug in the hook.
- **`AskUserQuestion` must be loaded.** In sessions where
  `AskUserQuestion` is a deferred tool, Claude needs to call
  `ToolSearch` with `select:AskUserQuestion` first to load its schema.
  The injected reminder tells Claude to do this. If a future session
  has `AskUserQuestion` always loaded, that extra step is a no-op.

## Origin

Built 2026-04-14 for the `homeassistant` project after a conversation
where the user explained they dictate by voice and wanted a
transcription-repair step gated to prompts likely to need it, with a
native selection-box confirmation instead of typed "yes". The initial
version fired on every prompt; this version adds the word-count gate
and the `AskUserQuestion` confirmation after user feedback.
