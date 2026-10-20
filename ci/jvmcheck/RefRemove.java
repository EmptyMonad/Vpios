import java.util.*;
/** Ground truth for HashMap.remove on a hash-1 bin, and the table length after inserts into a pre-sized (cleared) set. */
public class RefRemove {
    static final class E { final int id; E(int i){id=i;} @Override public int hashCode(){return 1;} }
    public static void main(String[] a) throws Exception {
        StringBuilder sb = new StringBuilder();
        for (int n = 1; n <= 120; n++) for (int r : new int[]{0, 1, 2, 3, n / 2, n - 2, n - 1}) {
            if (r < 0 || r >= n) continue;
            HashSet<E> s = new HashSet<>(); E[] es = new E[n];
            for (int i = 0; i < n; i++) { es[i] = new E(i); s.add(es[i]); }
            s.remove(es[r]);
            sb.append("R ").append(n).append(' ').append(r).append(':');
            for (E e : s) sb.append(' ').append(e.id); sb.append('\n');
        }
        // table length: HashSet() then clear() and refill (MapRegions reuses the set), via reflection on HashMap.table
        java.lang.reflect.Field mf = HashSet.class.getDeclaredField("map"); mf.setAccessible(true);
        java.lang.reflect.Field tf = HashMap.class.getDeclaredField("table"); tf.setAccessible(true);
        for (int n1 : new int[]{0, 5, 12, 13, 40, 100}) for (int n2 = 0; n2 <= 70; n2 += 3) {
            HashSet<E> s = new HashSet<>();
            for (int i = 0; i < n1; i++) s.add(new E(i));
            Object[] t1 = (Object[]) tf.get(mf.get(s)); int len1 = t1 == null ? 0 : t1.length;
            s.clear();
            for (int i = 0; i < n2; i++) s.add(new E(i));
            Object[] t2 = (Object[]) tf.get(mf.get(s)); int len2 = t2 == null ? 0 : t2.length;
            sb.append("T ").append(n1).append(' ').append(len1).append(' ').append(n2).append(' ').append(len2).append(':');
            for (E e : s) sb.append(' ').append(e.id); sb.append('\n');
        }
        System.out.print(sb);
    }
}
