import java.util.*;
public class RefCap {
    static final class E { final int id; E(int i){id=i;} @Override public int hashCode(){return 1;} }
    public static void main(String[] a) {
        StringBuilder sb = new StringBuilder();
        for (int n = 0; n <= 140; n++) {
            List<E> l = new ArrayList<>(); for (int i = 0; i < n; i++) l.add(new E(i));
            HashSet<E> s = new HashSet<>(l);
            sb.append(n).append(':'); for (E e : s) sb.append(' ').append(e.id); sb.append('\n');
        }
        System.out.print(sb);
    }
}
