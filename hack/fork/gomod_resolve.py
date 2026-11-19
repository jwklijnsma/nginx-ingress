#!/usr/bin/env python3
"""Resolve git conflict markers in go.mod / go.sum.

go.sum: union of both sides (go.sum is additive; extra lines are harmless and
        `go mod tidy` in CI prunes them).
go.mod: per module, keep the higher version from either side.
"""
import re, sys

def vkey(v):
    # semver-ish key; pseudo-versions sort by their base + timestamp
    v = v.lstrip('v')
    main, _, pre = v.partition('-')
    nums = [int(x) if x.isdigit() else 0 for x in main.split('.')]
    return (nums, 0 if pre else 1, pre)

def resolve(path):
    text = open(path).read()
    pat = re.compile(r'<<<<<<< [^\n]*\n(.*?)=======\n(.*?)>>>>>>> [^\n]*\n', re.S)
    def fix(m):
        ours, theirs = m.group(1).splitlines(True), m.group(2).splitlines(True)
        if path.endswith('go.sum'):
            seen, out = set(), []
            for l in ours + theirs:
                if l not in seen:
                    seen.add(l); out.append(l)
            return ''.join(sorted(out))
        best, order = {}, []
        for l in ours + theirs:
            mm = re.match(r'(\s*)(\S+) (v\S+)(.*)', l)
            if not mm:
                if l not in order: order.append(l)
                continue
            mod = mm.group(2)
            if mod not in best:
                order.append(mod); best[mod] = l
            elif vkey(mm.group(3)) > vkey(re.match(r'\s*\S+ (v\S+)', best[mod]).group(1)):
                best[mod] = l
        return ''.join(best.get(x, x) for x in order)
    new, n = pat.subn(fix, text)
    open(path, 'w').write(new)
    return n

for p in sys.argv[1:]:
    print(p, resolve(p), 'hunks resolved')
