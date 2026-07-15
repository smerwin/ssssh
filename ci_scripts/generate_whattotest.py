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
]


def generate() -> str:
    return "\n".join([random.choice(OPENING), random.choice(MIDDLE), random.choice(CLOSING)])


if __name__ == "__main__":
    print(generate())
