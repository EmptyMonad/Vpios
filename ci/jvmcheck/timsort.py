"""java.util.TimSort (JDK 11+), transliterated; comparator call order must equal Java's."""
MIN_MERGE = 32; MIN_GALLOP = 7; INITIAL_TMP = 256

def sort(a, c):
    lo, hi = 0, len(a)
    n_rem = hi - lo
    if n_rem < 2: return
    if n_rem < MIN_MERGE:
        init = count_run_and_make_ascending(a, lo, hi, c)
        binary_sort(a, lo, hi, lo + init, c); return
    ts = TS(a, c)
    min_run = min_run_length(n_rem)
    while True:
        run_len = count_run_and_make_ascending(a, lo, hi, c)
        if run_len < min_run:
            force = n_rem if n_rem <= min_run else min_run
            binary_sort(a, lo, lo + force, lo + run_len, c); run_len = force
        ts.push_run(lo, run_len); ts.merge_collapse()
        lo += run_len; n_rem -= run_len
        if n_rem == 0: break
    ts.merge_force_collapse()

def binary_sort(a, lo, hi, start, c):
    if start == lo: start += 1
    while start < hi:
        pivot = a[start]; left, right = lo, start
        while left < right:
            mid = (left + right) >> 1
            if c(pivot, a[mid]) < 0: right = mid
            else: left = mid + 1
        n = start - left
        a[left + 1:left + 1 + n] = a[left:left + n]
        a[left] = pivot
        start += 1

def count_run_and_make_ascending(a, lo, hi, c):
    run_hi = lo + 1
    if run_hi == hi: return 1
    if c(a[run_hi], a[lo]) < 0:
        run_hi += 1
        while run_hi < hi and c(a[run_hi], a[run_hi - 1]) < 0: run_hi += 1
        a[lo:run_hi] = a[lo:run_hi][::-1]
    else:
        run_hi += 1
        while run_hi < hi and c(a[run_hi], a[run_hi - 1]) >= 0: run_hi += 1
    return run_hi - lo

def min_run_length(n):
    r = 0
    while n >= MIN_MERGE: r |= n & 1; n >>= 1
    return n + r

def gallop_left(key, a, base, length, hint, c):
    last_ofs, ofs = 0, 1
    if c(key, a[base + hint]) > 0:
        max_ofs = length - hint
        while ofs < max_ofs and c(key, a[base + hint + ofs]) > 0:
            last_ofs = ofs; ofs = (ofs << 1) + 1
            if ofs <= 0: ofs = max_ofs
        if ofs > max_ofs: ofs = max_ofs
        last_ofs += hint; ofs += hint
    else:
        max_ofs = hint + 1
        while ofs < max_ofs and c(key, a[base + hint - ofs]) <= 0:
            last_ofs = ofs; ofs = (ofs << 1) + 1
            if ofs <= 0: ofs = max_ofs
        if ofs > max_ofs: ofs = max_ofs
        tmp = last_ofs; last_ofs = hint - ofs; ofs = hint - tmp
    last_ofs += 1
    while last_ofs < ofs:
        m = last_ofs + ((ofs - last_ofs) >> 1)
        if c(key, a[base + m]) > 0: last_ofs = m + 1
        else: ofs = m
    return ofs

def gallop_right(key, a, base, length, hint, c):
    ofs, last_ofs = 1, 0
    if c(key, a[base + hint]) < 0:
        max_ofs = hint + 1
        while ofs < max_ofs and c(key, a[base + hint - ofs]) < 0:
            last_ofs = ofs; ofs = (ofs << 1) + 1
            if ofs <= 0: ofs = max_ofs
        if ofs > max_ofs: ofs = max_ofs
        tmp = last_ofs; last_ofs = hint - ofs; ofs = hint - tmp
    else:
        max_ofs = length - hint
        while ofs < max_ofs and c(key, a[base + hint + ofs]) >= 0:
            last_ofs = ofs; ofs = (ofs << 1) + 1
            if ofs <= 0: ofs = max_ofs
        if ofs > max_ofs: ofs = max_ofs
        last_ofs += hint; ofs += hint
    last_ofs += 1
    while last_ofs < ofs:
        m = last_ofs + ((ofs - last_ofs) >> 1)
        if c(key, a[base + m]) < 0: ofs = m
        else: last_ofs = m + 1
    return ofs

class TS:
    def __init__(s, a, c):
        s.a = a; s.c = c; s.min_gallop = MIN_GALLOP
        s.run_base = []; s.run_len = []
    def push_run(s, base, ln): s.run_base.append(base); s.run_len.append(ln)
    def merge_collapse(s):
        rl = s.run_len
        while len(rl) > 1:
            n = len(rl) - 2
            if (n > 0 and rl[n-1] <= rl[n] + rl[n+1]) or (n > 1 and rl[n-2] <= rl[n] + rl[n-1]):
                if rl[n-1] < rl[n+1]: n -= 1
            elif n < 0 or rl[n] > rl[n+1]:
                break
            s.merge_at(n)
    def merge_force_collapse(s):
        rl = s.run_len
        while len(rl) > 1:
            n = len(rl) - 2
            if n > 0 and rl[n-1] < rl[n+1]: n -= 1
            s.merge_at(n)
    def merge_at(s, i):
        a, c = s.a, s.c
        base1, len1 = s.run_base[i], s.run_len[i]
        base2, len2 = s.run_base[i+1], s.run_len[i+1]
        s.run_len[i] = len1 + len2
        del s.run_base[i+1]; del s.run_len[i+1]
        k = gallop_right(a[base2], a, base1, len1, 0, c)
        base1 += k; len1 -= k
        if len1 == 0: return
        len2 = gallop_left(a[base1 + len1 - 1], a, base2, len2, len2 - 1, c)
        if len2 == 0: return
        if len1 <= len2: s.merge_lo(base1, len1, base2, len2)
        else: s.merge_hi(base1, len1, base2, len2)
    def merge_lo(s, base1, len1, base2, len2):
        a, c = s.a, s.c
        tmp = a[base1:base1 + len1]
        cursor1 = 0; cursor2 = base2; dest = base1
        a[dest] = a[cursor2]; dest += 1; cursor2 += 1
        len2 -= 1
        if len2 == 0:
            a[dest:dest + len1] = tmp[cursor1:cursor1 + len1]; return
        if len1 == 1:
            a[dest:dest + len2] = a[cursor2:cursor2 + len2]
            a[dest + len2] = tmp[cursor1]; return
        min_gallop = s.min_gallop
        done = False
        while not done:
            count1 = count2 = 0
            while True:
                if c(a[cursor2], tmp[cursor1]) < 0:
                    a[dest] = a[cursor2]; dest += 1; cursor2 += 1; count2 += 1; count1 = 0
                    len2 -= 1
                    if len2 == 0: done = True; break
                else:
                    a[dest] = tmp[cursor1]; dest += 1; cursor1 += 1; count1 += 1; count2 = 0
                    len1 -= 1
                    if len1 == 1: done = True; break
                if (count1 | count2) >= min_gallop: break
            if done: break
            while True:
                count1 = gallop_right(a[cursor2], tmp, cursor1, len1, 0, c)
                if count1 != 0:
                    a[dest:dest + count1] = tmp[cursor1:cursor1 + count1]
                    dest += count1; cursor1 += count1; len1 -= count1
                    if len1 <= 1: done = True; break
                a[dest] = a[cursor2]; dest += 1; cursor2 += 1
                len2 -= 1
                if len2 == 0: done = True; break
                count2 = gallop_left(tmp[cursor1], a, cursor2, len2, 0, c)
                if count2 != 0:
                    a[dest:dest + count2] = a[cursor2:cursor2 + count2]
                    dest += count2; cursor2 += count2; len2 -= count2
                    if len2 == 0: done = True; break
                a[dest] = tmp[cursor1]; dest += 1; cursor1 += 1
                len1 -= 1
                if len1 == 1: done = True; break
                min_gallop -= 1
                if not (count1 >= MIN_GALLOP or count2 >= MIN_GALLOP): break
            if done: break
            if min_gallop < 0: min_gallop = 0
            min_gallop += 2
        s.min_gallop = 1 if min_gallop < 1 else min_gallop
        if len1 == 1:
            a[dest:dest + len2] = a[cursor2:cursor2 + len2]
            a[dest + len2] = tmp[cursor1]
        elif len1 == 0:
            raise ValueError("Comparison method violates its general contract!")
        else:
            a[dest:dest + len1] = tmp[cursor1:cursor1 + len1]
    def merge_hi(s, base1, len1, base2, len2):
        a, c = s.a, s.c
        tmp = a[base2:base2 + len2]
        cursor1 = base1 + len1 - 1; cursor2 = len2 - 1; dest = base2 + len2 - 1
        a[dest] = a[cursor1]; dest -= 1; cursor1 -= 1
        len1 -= 1
        if len1 == 0:
            a[dest - (len2 - 1):dest + 1] = tmp[0:len2]; return
        if len2 == 1:
            dest -= len1; cursor1 -= len1
            a[dest + 1:dest + 1 + len1] = a[cursor1 + 1:cursor1 + 1 + len1]
            a[dest] = tmp[cursor2]; return
        min_gallop = s.min_gallop
        done = False
        while not done:
            count1 = count2 = 0
            while True:
                if c(tmp[cursor2], a[cursor1]) < 0:
                    a[dest] = a[cursor1]; dest -= 1; cursor1 -= 1; count1 += 1; count2 = 0
                    len1 -= 1
                    if len1 == 0: done = True; break
                else:
                    a[dest] = tmp[cursor2]; dest -= 1; cursor2 -= 1; count2 += 1; count1 = 0
                    len2 -= 1
                    if len2 == 1: done = True; break
                if (count1 | count2) >= min_gallop: break
            if done: break
            while True:
                count1 = len1 - gallop_right(tmp[cursor2], a, base1, len1, len1 - 1, c)
                if count1 != 0:
                    dest -= count1; cursor1 -= count1; len1 -= count1
                    a[dest + 1:dest + 1 + count1] = a[cursor1 + 1:cursor1 + 1 + count1]
                    if len1 == 0: done = True; break
                a[dest] = tmp[cursor2]; dest -= 1; cursor2 -= 1
                len2 -= 1
                if len2 == 1: done = True; break
                count2 = len2 - gallop_left(a[cursor1], tmp, 0, len2, len2 - 1, c)
                if count2 != 0:
                    dest -= count2; cursor2 -= count2; len2 -= count2
                    a[dest + 1:dest + 1 + count2] = tmp[cursor2 + 1:cursor2 + 1 + count2]
                    if len2 <= 1: done = True; break
                a[dest] = a[cursor1]; dest -= 1; cursor1 -= 1
                len1 -= 1
                if len1 == 0: done = True; break
                min_gallop -= 1
                if not (count1 >= MIN_GALLOP or count2 >= MIN_GALLOP): break
            if done: break
            if min_gallop < 0: min_gallop = 0
            min_gallop += 2
        s.min_gallop = 1 if min_gallop < 1 else min_gallop
        if len2 == 1:
            dest -= len1; cursor1 -= len1
            a[dest + 1:dest + 1 + len1] = a[cursor1 + 1:cursor1 + 1 + len1]
            a[dest] = tmp[cursor2]
        elif len2 == 0:
            raise ValueError("Comparison method violates its general contract!")
        else:
            a[dest - (len2 - 1):dest + 1] = tmp[0:len2]

def jhash(s):
    h = 0
    for ch in s: h = (31 * h + ord(ch)) & 0xFFFFFFFF
    return h - (1 << 32) if h >= (1 << 31) else h

if __name__ == "__main__":
    ok = tot = 0
    for line in open("refsort.txt"):
        n, keys, sig, ids = line.strip().split("|")
        keys = [int(x) for x in keys.strip("[]").split(",") if x != ""]
        calls = []
        def cmp(x, y):
            calls.append(f"{x},{y};"); return (keys[x] > keys[y]) - (keys[x] < keys[y])
        arr = list(range(len(keys)))
        sort(arr, cmp)
        s = "".join(calls)
        mysig = f"{jhash(s)}:{len(calls)}" if calls else "0:0"
        tot += 1
        if mysig == sig and "[" + ",".join(map(str, arr)) + "]" == ids: ok += 1
        elif tot - ok <= 5: print("MISMATCH n", n, "want", sig, "got", mysig, "order ok:", "[" + ",".join(map(str, arr)) + "]" == ids)
    print(f"{ok}/{tot} identical comparator sequences and results")
