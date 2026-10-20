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
