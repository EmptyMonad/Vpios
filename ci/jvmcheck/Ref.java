import java.util.*;
/** Ground truth: Java HashSet iteration order for elements whose hashCode is 1 and that aren't Comparable,
 *  with System.identityHashCode also constant (run with -XX:+UnlockExperimentalVMOptions -XX:hashCode=2). */
public class Ref {
    static final class E { final int id; E(int i){id=i;} @Override public int hashCode(){return 1;} }
    public static void main(String[] a) {
        StringBuilder sb = new StringBuilder();
        int[] caps = {-1, 0, 1, 2, 5, 16, 17, 64, 100};
        for (int cap : caps) for (int n = 0; n <= 140; n++) {
            HashSet<E> s = cap < 0 ? new HashSet<>() : new HashSet<>(cap);
            E[] es = new E[n]; for (int i = 0; i < n; i++) { es[i] = new E(i); s.add(es[i]); }
            // re-adding is a no-op (identity equals)
            for (int i = 0; i < n; i += 7) s.add(es[i]);
            sb.append(cap).append(' ').append(n).append(':');
            for (E e : s) sb.append(' ').append(e.id);
            sb.append('\n');
        }
        System.out.print(sb);
        System.err.println("identityHashCode sample: " + System.identityHashCode(new Object()) + " " + System.identityHashCode(new Object()));
    }
}
