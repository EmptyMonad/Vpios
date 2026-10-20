import java.util.*;
/** Ground truth: the exact comparator-call sequence of Kotlin sortedWith -> Arrays.sort(T[], Comparator) (TimSort). */
public class RefSort {
    public static void main(String[] a) {
        Random r = new Random(42); StringBuilder sb = new StringBuilder();
        int[] sizes = {0,1,2,3,5,8,13,31,32,33,40,64,65,100,127,128,129,200,257,400,1000,2048};
        for (int n : sizes) for (int dist = 0; dist < 4; dist++) for (int rep = 0; rep < 3; rep++) {
            Integer[] keys = new Integer[n];
            for (int i = 0; i < n; i++) keys[i] = switch (dist) { case 0 -> r.nextInt(5); case 1 -> r.nextInt(1000);
                case 2 -> (i % 50) + (r.nextInt(10) == 0 ? r.nextInt(30) : 0); default -> n - i + r.nextInt(3); };
            Integer[] ids = new Integer[n]; for (int i = 0; i < n; i++) ids[i] = i;
            final Integer[] k = keys; StringBuilder calls = new StringBuilder();
            Arrays.sort(ids, (x, y) -> { calls.append(x).append(',').append(y).append(';'); return Integer.compare(k[x], k[y]); });
            sb.append(n).append('|').append(Arrays.toString(keys).replace(" ", "")).append('|').append(calls.length() > 0 ? calls.toString().hashCode() + ":" + calls.toString().split(";").length : "0:0")
              .append('|').append(Arrays.toString(ids).replace(" ", "")).append('\n');
        }
        System.out.print(sb);
    }
}
