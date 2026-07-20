#!/usr/bin/env python3
# A tiny 3-state automaton for "What to Test" release notes: each state
# (opening line / middle line / closing line) draws one phrase from its
# own hand-counted 5-7-5 syllable bank, themed to ssh/terminal life.
# Deliberately templated rather than free-generated -- counting English
# syllables programmatically is unreliable, so correctness comes from
# every phrase below being counted by hand instead.
import random

OPENING = [  # 5 syllables
    "keys unlock the shell",
    "packets cross the void",
    "cursor blinks and waits",
    "terminal breathes light",
    "handshake in the dark",
    "prompt glows, waiting still",
    "scrollback holds your past",
    "one tap, session wakes",
    "amber glow at dusk",
    "green phosphor awakes",
    "touch wakes the keychain",
    "mosh survives the drop",
    "root prompt, green and calm",
    "wifi drops, shell stays",
    "signal fades to grey",
    "one key, many hosts",
]

MIDDLE = [  # 7 syllables
    "no clipboard leaves this glass pane",
    "bytes travel through the still night",
    "a fingerprint you must trust",
    "small server hums in the cloud",
    "output scrolls like falling rain",
    "each keystroke a small heartbeat",
    "trust one key, forget the rest",
    "quiet root shell, far from home",
    "roaming packets find the way",
    "a dropped signal finds its way",
    "the cursor waits for your move",
    "a whisper travels the wire",
    "one secret, shared by two hosts",
    "the amber prompt waits for you",
    "predictions vanish like smoke",
    "your glance unlocks the still vault",
]

CLOSING = [  # 5 syllables
    "go, test, and be well",
    "ship it, breathe, repeat",
    "no clipboard, no fear",
    "connect and be still",
    "try it, then tell us",
    "close the lid in peace",
    "shells await your touch",
    "sleep well, terminal",
    "trust once, rest at ease",
    "roam free, stay online",
    "whisper, then goodnight",
    "amber fades to black",
    "keys kept, worries none",
    "test well, rest easy",
    "green light, go in peace",
    "one tap, then be free",
]


def generate() -> str:
    return "\n".join([random.choice(OPENING), random.choice(MIDDLE), random.choice(CLOSING)])


if __name__ == "__main__":
    print(generate())
