#!/usr/bin/env python3
"""Deterministic ballast for scripts/e2e/context_window_live.sh (bead foreman-gppjx).

  python3 make_ballast.py --out DIR --last 14 [--first 1] [--bytes 80000] [--seed 20261101]

Writes DIR/part-FF.txt .. DIR/part-LL.txt (two-digit numbers): plain ASCII lines of 10-14 common English words, each line numbered
(`L00001 ...`), about --bytes bytes per file (so a file is about 17k tokens, about 21k once the Read tool has numbered its lines),
and as the LAST line of file XX `CHECKSUM part-XX <12 hex>`: the first 12 hex digits of the SHA-256 of every byte above that line.
The checksum lines are the only thing in a file an agent cannot know without having read it, so they are what the live run asks
the agent to report. A part that already exists is left alone, so the script can add parts to a directory an agent is reading.

Same arguments, same bytes: a part is a function of (--seed, --bytes, its number) only.
"""
import argparse
import hashlib
import os
import random
import sys

WORDS = """
able about above across act add after again age ago air all also always among amount and animal another answer any
appear area around ask at away back bad base be because become before begin behind best better between big black
blue body book both bring build but buy call can car care carry case cause center certain change child city clear
close cold color come common complete consider could country course cover create cut dark day dead deep did different
do does door down draw dry during each early earth east easy eat edge end enough even every example eye face fact fall
family far fast father feel few field figure fill find fine fire first fish five follow food for form found four free
friend from front full game gave general get girl give go gold good government great green ground group grow had hand
happen hard has have he head hear heart heavy help her here high hill him his hold home horse hot hour house how
however hundred idea if important in inch include interest into iron island it just keep kind king know land large
last late laugh lay lead learn least leave left length less let letter life light like line list little live long look
lot low machine made main make man many map mark may me mean measure meet might mile mind minute miss money moon more
morning most mother mountain move much music must my name near need never new next night no noise north not note
nothing notice now number object ocean of off often oil old on once one only open or order other our out over own page
paper part pass pattern people perhaps person picture piece place plain plan plant play point port possible power
press problem produce product pull put question quick quiet rain reach read ready real reason red remember rest right
river road rock room round rule run said same sand saw say school science sea second see seem sentence serve set seven
several shape she ship short should show side simple since sing size sky sleep slow small snow so some song soon sound
south space speak special spell stand star start state stay step still stone stop story straight strange street strong
study such sun sure surface system table take talk tall tell ten than that the their them then there these they thing
think this those though thought three through time to together told too took top toward town tree try turn two under
until up us use usual very voice vowel wait walk want warm was watch water way we weather week well went were west what
wheel when where which while white who whole why wide will wind winter with within without woman wonder wood word work
world would write year yellow yes you young your
""".split()


def part_text(seed, number, target_bytes):
    rng = random.Random("%s-%d" % (seed, number))
    lines = []
    size = 0
    n = 0
    while True:
        n += 1
        line = "L%05d %s" % (n, " ".join(rng.choice(WORDS) for _ in range(rng.randint(10, 14))))
        # leave room for the checksum line (about 30 bytes)
        if size + len(line) + 1 + 32 > target_bytes:
            break
        lines.append(line)
        size += len(line) + 1
    body = "\n".join(lines) + "\n"
    digest = hashlib.sha256(body.encode("ascii")).hexdigest()[:12]
    return body + "CHECKSUM part-%02d %s\n" % (number, digest)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", required=True)
    parser.add_argument("--first", type=int, default=1)
    parser.add_argument("--last", type=int, required=True)
    parser.add_argument("--bytes", type=int, default=80000)
    parser.add_argument("--seed", default="20261101")
    args = parser.parse_args()
    if args.first < 1 or args.last > 99 or args.first > args.last or args.bytes < 1000:
        print("make_ballast: need 1 <= --first <= --last <= 99 and --bytes of at least 1000", file=sys.stderr)
        return 2
    os.makedirs(args.out, exist_ok=True)
    for number in range(args.first, args.last + 1):
        path = os.path.join(args.out, "part-%02d.txt" % number)
        if os.path.exists(path):
            continue
        text = part_text(args.seed, number, args.bytes)
        # written under another name and renamed: a reader never sees half a part
        temporary = path + ".partial"
        with open(temporary, "w", newline="\n") as handle:
            handle.write(text)
        os.rename(temporary, path)
    return 0


if __name__ == "__main__":
    sys.exit(main())
