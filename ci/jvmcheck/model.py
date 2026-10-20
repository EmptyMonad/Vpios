"""Model of java.util.HashMap insertion with every key hashing to 1 and identity tie-breaks all equal:
one bin, linked list until treeified, then a red-black tree whose `next` order is the iteration order."""
class N:
    __slots__ = ("k", "next", "prev", "parent", "left", "right", "red")
    def __init__(s, k, nxt=None):
        s.k = k; s.next = nxt; s.prev = None; s.parent = s.left = s.right = None; s.red = False

def table_size_for(c):
    n = 1
    while n < c: n <<= 1
    return n

def rotate_left(root, p):
    r = p.right if p else None
    if p is not None and r is not None:
        rl = p.right = r.left
        if rl is not None: rl.parent = p
        pp = r.parent = p.parent
        if pp is None: root = r; r.red = False
        elif pp.left is p: pp.left = r
        else: pp.right = r
        r.left = p; p.parent = r
    return root

def rotate_right(root, p):
    l = p.left if p else None
    if p is not None and l is not None:
        lr = p.left = l.right
        if lr is not None: lr.parent = p
        pp = l.parent = p.parent
        if pp is None: root = l; l.red = False
        elif pp.right is p: pp.right = l
        else: pp.left = l
        l.right = p; p.parent = l
    return root

def balance_insertion(root, x):
    x.red = True
    while True:
        xp = x.parent
        if xp is None: x.red = False; return x
        if not xp.red or xp.parent is None: return root
        xpp = xp.parent
        xppl = xpp.left
        if xp is xppl:
            xppr = xpp.right
            if xppr is not None and xppr.red:
                xppr.red = False; xp.red = False; xpp.red = True; x = xpp
            else:
                if x is xp.right:
                    x = xp; root = rotate_left(root, x)
                    xp = x.parent; xpp = None if xp is None else xp.parent
                if xp is not None:
                    xp.red = False
                    if xpp is not None: xpp.red = True; root = rotate_right(root, xpp)
        else:
            if xppl is not None and xppl.red:
                xppl.red = False; xp.red = False; xpp.red = True; x = xpp
            else:
                if x is xp.left:
                    x = xp; root = rotate_right(root, x)
                    xp = x.parent; xpp = None if xp is None else xp.parent
                if xp is not None:
                    xp.red = False
                    if xpp is not None: xpp.red = True; root = rotate_left(root, xpp)

class Bin:
    def __init__(s): s.first = None; s.tree = False
    def move_root_to_front(s, root):
        first = s.first
        if root is not first:
            rn, rp = root.next, root.prev
            if rn is not None: rn.prev = rp
            if rp is not None: rp.next = rn
            if first is not None: first.prev = root
            root.next = first; root.prev = None
            s.first = root
    def root(s):
        r = s.first
        while r.parent is not None: r = r.parent
        return r
    def treeify(s):
        root = None
        x = s.first
        while x is not None:
            nxt = x.next
            x.left = x.right = None
            if root is None: x.parent = None; x.red = False; root = x
            else:
                p = root
                while True:
                    xp = p; p = p.left          # tieBreakOrder == -1: always left
                    if p is None:
                        x.parent = xp; xp.left = x; root = balance_insertion(root, x); break
            x = nxt
        s.move_root_to_front(root); s.tree = True
    def put_tree(s, k):
        root = s.root(); p = root
        while True:
            xp = p; p = p.left
            if p is None:
                xpn = xp.next
                x = N(k, xpn); xp.left = x; xp.next = x; x.parent = x.prev = xp
                if xpn is not None: xpn.prev = x
                s.move_root_to_front(balance_insertion(root, x)); return
    def keys(s):
        out = []; e = s.first
        while e is not None: out.append(e.k); e = e.next
        return out
    def untreeify(s):
        ks = s.keys(); s.first = None; s.tree = False; prev = None
        for k in ks:
            n = N(k)
            if prev is None: s.first = n
            else: prev.next = n; n.prev = prev
            prev = n

def iteration_order(inserts, initial_capacity=None):
    seen = set(); b = Bin(); size = 0
    cap = 0; thr = 16 if initial_capacity is None else table_size_for(max(initial_capacity, 0))
    default = initial_capacity is None
    def resize():
        nonlocal cap, thr
        if cap > 0:
            new_cap = cap << 1
            new_thr = thr << 1 if cap >= 16 else int(new_cap * 0.75)
        elif thr > 0 and not default_first[0]:
            new_cap = thr; new_thr = int(new_cap * 0.75)
        else:
            new_cap = 16; new_thr = 12
        default_first[0] = False
        # all keys in one bin (hash 1); a tree bin stays a tree unless split leaves <= 6 (never: no hi part)
        if b.tree and size <= 6 and False: b.untreeify()
        cap, thr = new_cap, new_thr
    default_first = [default]
    for k in inserts:
        if k in seen: continue
        if cap == 0: resize()
        if b.first is None:
            b.first = N(k)
        elif b.tree:
            b.put_tree(k)
        else:
            e = b.first; count = 1
            while e.next is not None: e = e.next; count += 1
            n = N(k); e.next = n; n.prev = e
            if count >= 8:             # binCount >= TREEIFY_THRESHOLD - 1 after appending the 9th
                if cap < 64: resize()
                else: b.treeify()
        seen.add(k); size += 1
        if size > thr: resize()
    return b.keys()

if __name__ == "__main__":
    import sys
    bad = 0; total = 0
    for line in open(sys.argv[1]):
        head, _, rest = line.partition(":")
        cap, n = map(int, head.split())
        want = [int(x) for x in rest.split()]
        ins = list(range(n)) + list(range(0, n, 7))
        got = iteration_order(ins, None if cap < 0 else cap)
        total += 1
        if got != want:
            bad += 1
            if bad <= 5: print("MISMATCH cap", cap, "n", n, "\n want", want[:30], "\n got ", got[:30])
    print(f"{total - bad}/{total} match")

# ---- removal (HashMap.removeNode / TreeNode.removeTreeNode + balanceDeletion) and table length ----
def balance_deletion(root, x):
    while True:
        if x is None or x is root: return root
        xp = x.parent
        if xp is None: x.red = False; return x
        if x.red: x.red = False; return root
        xpl = xp.left
        if xpl is x:
            xpr = xp.right
            if xpr is not None and xpr.red:
                xpr.red = False; xp.red = True; root = rotate_left(root, xp)
                xp = x.parent; xpr = None if xp is None else xp.right
            if xpr is None: x = xp
            else:
                sl, sr = xpr.left, xpr.right
                if (sr is None or not sr.red) and (sl is None or not sl.red):
                    xpr.red = True; x = xp
                else:
                    if sr is None or not sr.red:
                        if sl is not None: sl.red = False
                        xpr.red = True; root = rotate_right(root, xpr)
                        xp = x.parent; xpr = None if xp is None else xp.right
                    if xpr is not None:
                        xpr.red = False if xp is None else xp.red
                        sr = xpr.right
                        if sr is not None: sr.red = False
                    if xp is not None: xp.red = False; root = rotate_left(root, xp)
                    x = root
        else:
            if xpl is not None and xpl.red:
                xpl.red = False; xp.red = True; root = rotate_right(root, xp)
                xp = x.parent; xpl = None if xp is None else xp.left
            if xpl is None: x = xp
            else:
                sl, sr = xpl.left, xpl.right
                if (sl is None or not sl.red) and (sr is None or not sr.red):
                    xpl.red = True; x = xp
                else:
                    if sl is None or not sl.red:
                        if sr is not None: sr.red = False
                        xpl.red = True; root = rotate_left(root, xpl)
                        xp = x.parent; xpl = None if xp is None else xp.left
                    if xpl is not None:
                        xpl.red = False if xp is None else xp.red
                        sl = xpl.left
                        if sl is not None: sl.red = False
                    if xp is not None: xp.red = False; root = rotate_right(root, xp)
                    x = root

def remove(b, key):
    e = b.first
    while e is not None and e.k != key: e = e.next
    if e is None: return
    if not b.tree:
        if e.prev is None: b.first = e.next
        else: e.prev.next = e.next
        if e.next is not None: e.next.prev = e.prev
        return
    p = e
    first = b.first; root = first
    succ, pred = p.next, p.prev
    if pred is None: b.first = first = succ
    else: pred.next = succ
    if succ is not None: succ.prev = pred
    if first is None: b.tree = False; return
    if root.parent is not None:
        while root.parent is not None: root = root.parent
    rl = root.left
    if root.right is None or rl is None or rl.left is None:
        b.untreeify(); return
    pl, pr = p.left, p.right
    if pl is not None and pr is not None:
        s = pr
        while s.left is not None: s = s.left
        s.red, p.red = p.red, s.red
        sr = s.right; pp = p.parent
        if s is pr: p.parent = s; s.right = p
        else:
            sp = s.parent
            p.parent = sp
            if sp is not None:
                if s is sp.left: sp.left = p
                else: sp.right = p
            s.right = pr
            if pr is not None: pr.parent = s
        p.left = None
        p.right = sr
        if sr is not None: sr.parent = p
        s.left = pl
        if pl is not None: pl.parent = s
        s.parent = pp
        if pp is None: root = s
        elif p is pp.left: pp.left = s
        else: pp.right = s
        replacement = sr if sr is not None else p
    elif pl is not None: replacement = pl
    elif pr is not None: replacement = pr
    else: replacement = p
    if replacement is not p:
        pp = replacement.parent = p.parent
        if pp is None: root = replacement; replacement.red = False
        elif p is pp.left: pp.left = replacement
        else: pp.right = replacement
        p.left = p.right = p.parent = None
    r = root if p.red else balance_deletion(root, replacement)
    if replacement is p:
        pp = p.parent; p.parent = None
        if pp is not None:
            if p is pp.left: pp.left = None
            elif p is pp.right: pp.right = None
    b.move_root_to_front(r)

def build(inserts, initial_capacity=None):
    """iteration_order's machinery, returning the bin and the table length."""
    seen = set(); b = Bin(); size = 0
    st = {"cap": 0, "thr": 16 if initial_capacity is None else table_size_for(max(initial_capacity, 0)), "dflt": initial_capacity is None}
    def resize():
        cap, thr = st["cap"], st["thr"]
        if cap > 0:
            nc = cap << 1; nt = thr << 1 if cap >= 16 else int(nc * 0.75)
        elif thr > 0 and not st["dflt"]: nc = thr; nt = int(nc * 0.75)
        else: nc = 16; nt = 12
        st["dflt"] = False; st["cap"], st["thr"] = nc, nt
    for k in inserts:
        if k in seen: continue
        if st["cap"] == 0: resize()
        if b.first is None: b.first = N(k)
        elif b.tree: b.put_tree(k)
        else:
            e = b.first; count = 1
            while e.next is not None: e = e.next; count += 1
            n = N(k); e.next = n; n.prev = e
            if count >= 8:
                if st["cap"] < 64: resize()
                else: b.treeify()
        seen.add(k); size += 1
        if size > st["thr"]: resize()
    return b, st["cap"]

def check_remove(path):
    ok = tot = 0
    for line in open(path):
        head, _, rest = line.partition(":"); h = head.split(); want = [int(x) for x in rest.split()]
        if h[0] == "R":
            n, r = int(h[1]), int(h[2])
            b, _ = build(range(n)); remove(b, r); got = b.keys(); good = got == want
        else:
            n1, len1, n2, len2 = map(int, h[1:])
            _, l1 = build(range(n1))
            b, l2 = build(range(n2), l1 if l1 > 0 else None)
            got = b.keys(); good = got == want and (l2 if n2 > 0 else l1) == len2 and l1 == len1
        tot += 1; ok += good
        if not good and tot - ok <= 5: print("MISMATCH", line.strip()[:120], "got", got[:20])
    print(f"{ok}/{tot} remove / table-length cases match")
