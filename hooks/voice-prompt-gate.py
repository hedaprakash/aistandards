#!/usr/bin/env python3
"""
UserPromptSubmit hook — voice-dictation confirmation gate.

Prompts here come from voice-to-text and often contain transcription errors.
For any prompt longer than THRESHOLD words, this hook injects a reminder
telling Claude to restate its understanding and confirm via AskUserQuestion
before doing any work. Shorter prompts pass through untouched.
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
