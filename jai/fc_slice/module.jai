#import "Basic";
#import "fc";
Ordering :: enum { Less :: -1; Equal :: 0; Greater :: 1; }
clone :: (a: []$T, allocator := context.allocator) -> []T { push_allocator(allocator); r := NewArray(a.count, T, false); memcpy(r.data, a.data, a.count * size_of(T)); return r; }
contains :: (a: []$T, x: T) -> bool { for a if it == x return true; return false; }
linear_search :: (a: []$T, x: T) -> int, bool { for a if it == x return it_index, true; return -1, false; }
// Stable merge sort ordered by less(a, b).
sort_by :: (a: []$T, less: (T, T) -> bool) { stable_sort_by(a, less); }
stable_sort_by :: (a: []$T, less: (T, T) -> bool) {
    if a.count < 2 return;
    merge :: (a: []T, tmp: []T, less: (T, T) -> bool) {
        if a.count < 2 return;
        if a.count <= 16 {
            for i: 1..a.count-1 {
                x := a[i]; j := i;
                while j > 0 && less(x, a[j-1]) { a[j] = a[j-1]; j -= 1; }
                a[j] = x;
            }
            return;
        }
        m := a.count / 2;
        merge(sub(a, 0, m), tmp, less);
        merge(sub_from(a, m), tmp, less);
        i, j, k := 0, m, 0;
        while i < m && j < a.count { if less(a[j], a[i]) { tmp[k] = a[j]; j += 1; } else { tmp[k] = a[i]; i += 1; } k += 1; }
        while i < m { tmp[k] = a[i]; i += 1; k += 1; }
        while j < a.count { tmp[k] = a[j]; j += 1; k += 1; }
        memcpy(a.data, tmp.data, a.count * size_of(T));
    }
    tmp := NewArray(a.count, T, false,, temp);
    merge(a, tmp, less);
}
sort :: (a: []$T) { stable_sort_by(a, (x: T, y: T) -> bool { return x < y; }); }
binary_search_by :: (a: []$T, key: $K, cmp: (T, K) -> Ordering) -> int, bool {
    lo, hi := 0, a.count;
    while lo < hi {
        m := (lo + hi) / 2;
        c := cmp(a[m], key);
        if c == .Less lo = m + 1;
        else if c == .Greater hi = m;
        else return m, true;
    }
    return lo, false;
}
binary_search :: (a: []$T, key: T) -> int, bool {
    lo, hi := 0, a.count;
    while lo < hi { m := (lo + hi) / 2; if a[m] < key lo = m + 1; else if a[m] > key hi = m; else return m, true; }
    return lo, false;
}
