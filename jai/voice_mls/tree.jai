// ---------------------------------------------------------------------------
// Tree math (RFC 9420 Appendix C). Node indices in the array representation;
// trees are always full (leaf count a power of two).

level :: (x: u32) -> u32 {
	if x & 1 == 0 { return 0; }
	k: u32 = 0;
	while (x >> k) & 1 == 1 { k += 1; }
	return k;
}

node_width :: (n_leaves: u32) -> u32 {return ifx n_leaves == 0 then 0 else 2 * (n_leaves - 1) + 1;}

log2_floor :: (x: u32) -> u32 {
	if x == 0 { return 0; }
	k: u32 = 0;
	while (x >> k) > 1 { k += 1; }
	return k;
}

root :: (n_leaves: u32) -> u32 {
	w := node_width(n_leaves);
	return (cast(u32)(1) << log2_floor(w)) - 1;
}

left :: (x: u32) -> u32 {
	k := level(x);
	assert(k > 0);
	return x ^ (cast(u32)(1) << (k - 1));
}

right :: (x: u32) -> u32 {
	k := level(x);
	assert(k > 0);
	return x ^ (cast(u32)(3) << (k - 1));
}

parent_of :: (x: u32) -> u32 {
	k := level(x);
	b := (x >> (k + 1)) & 1;
	return (x | (cast(u32)(1) << k)) ^ (b << (k + 1));
}

sibling_of :: (x: u32) -> u32 {
	p := parent_of(x);
	return ifx x < p then right(p) else left(p);
}

direct_path :: (x: u32, n_leaves: u32, a := temp) -> []u32 {
	r := root(n_leaves);
	out := make_dynamic(u32, 0, 8);
	if x == r { return view(out); }
	y := x;
	while y != r {
		y = parent_of(y);
		append(*out, y);
	}
	return view(out);
}

copath :: (x: u32, n_leaves: u32, a := temp) -> []u32 {
	dp := direct_path(x, n_leaves);
	out := make_dynamic(u32, 0, 8);
	if len(dp) == 0 { return view(out); }
	append(*out, sibling_of(x));
	for i: 0..(len(dp) - 1)-1 { append(*out, sibling_of(dp[i])); }
	return view(out);
}

is_ancestor :: (a: u32, x: u32) -> bool {
	// a is an ancestor of x (or equal) iff x lies in a's span
	k := level(a);
	lo := a - ((cast(u32)(1) << k) - 1);
	hi := a + ((cast(u32)(1) << k) - 1);
	return x >= lo && x <= hi;
}

common_ancestor :: (x: u32, y: u32) -> u32 {
	// lowest common ancestor in a full tree
	lx, ly := level(x), level(y);
	if lx <= ly && is_ancestor(y, x) { return y; }
	if ly <= lx && is_ancestor(x, y) { return x; }
	xn, yn := x, y;
	k: u32 = 0;
	while xn != yn {
		xn >>= 1;
		yn >>= 1;
		k += 1;
	}
	return ifx k > 0 then (xn << k) + ((cast(u32)(1) << (k - 1)) - 1) else xn;
}

// ---------------------------------------------------------------------------
// Ratchet tree

Node_Kind :: enum u8 {
	Blank;
	Leaf;
	Parent;
}

Node :: struct {
	kind: Node_Kind;
	leaf: Leaf_Node;
	parent: Parent_Node;
}

Tree :: struct {
	nodes: [..]Node;
}

n_leaves :: (t: *Tree) -> u32 {return cast(u32)(len(t.nodes) + 1) / 2;}

node_encryption_key :: (n: *Node) -> []u8 {
	if n.kind == {
	case .Leaf;
		return n.leaf.encryption_key;
	case .Parent;
		return n.parent.encryption_key;
	case .Blank;
	}
	return .{};
}

node_parent_hash :: (n: *Node) -> []u8 {
	if n.kind == {
	case .Leaf;
		return n.leaf.parent_hash;
	case .Parent;
		return n.parent.parent_hash;
	case .Blank;
	}
	return .{};
}

leaf_at :: (t: *Tree, leaf: u32) -> *Node {
	i := cast(int)(leaf) * 2;
	if i >= len(t.nodes) { return null; }
	return *t.nodes[i];
}

resolution :: (t: *Tree, x: u32, a := temp) -> []u32 {
	out := make_dynamic(u32, 0, 8);
	resolve_into(t, x, *out);
	return view(out);
}
#scope_module

resolve_into :: (t: *Tree, x: u32, out: *[..]u32) {
	n := *t.nodes[x];
	if n.kind == {
	case .Leaf;
		append(out, x);
	case .Parent;
		append(out, x);
		for l: n.parent.unmerged_leaves { append(out, l * 2); }
	case .Blank;
		if level(x) == 0 { return; }
		resolve_into(t, left(x), out);
		resolve_into(t, right(x), out);
	}
}
#scope_export

// filtered_direct_path: direct path nodes whose copath child has a non-empty resolution.
filtered_direct_path :: (t: *Tree, leaf: u32, a := temp) -> []u32 {
	x := leaf * 2;
	nl := n_leaves(t);
	dp := direct_path(x, nl);
	cp := copath(x, nl);
	out := make_dynamic(u32, 0, len(dp));
	for i: 0..len(dp)-1 {
		if len(resolution(t, cp[i])) > 0 { append(*out, dp[i]); }
	}
	return view(out);
}

// child of p on the path toward x
child_toward :: (p: u32, x: u32) -> u32 {
	return ifx x < p then left(p) else right(p);
}

contains_u32 :: (l: []u32, v: u32) -> bool {
	for x: l { if x == v { return true; } }
	return false;
}

// tree_hash with optional excluded leaves (treated as blank; also removed from
// unmerged_leaves lists) for "original sibling tree hash" (RFC 9420 7.9.2).
tree_hash :: (t: *Tree, x: u32, exclude: []u32 = .{}) -> Secret {
	n := *t.nodes[x];
	w := writer_make();
	if level(x) == 0 {
		w_u8(*w, 1);
		w_u32(*w, x / 2);
		present := n.kind == .Leaf && !contains_u32(exclude, x / 2);
		w_optional(*w, present);
		if present { w_leaf_node(*w, n.leaf); }
	} else {
		w_u8(*w, 2);
		w_optional(*w, n.kind == .Parent);
		if n.kind == .Parent {
			w_vec(*w, n.parent.encryption_key);
			w_vec(*w, n.parent.parent_hash);
			p := w_begin(*w);
			for l: n.parent.unmerged_leaves { if !contains_u32(exclude, l) { w_u32(*w, l); } }
			w_end(*w, p);
		}
		lh := tree_hash(t, left(x), exclude);
		rh := tree_hash(t, right(x), exclude);
		w_vec(*w, view(lh));
		w_vec(*w, view(rh));
	}
	return hash_bytes(view(w.buf));
}

root_tree_hash :: (t: *Tree) -> Secret {return tree_hash(t, root(n_leaves(t)));}

parent_hash_of :: (encryption_key: []u8, parent_hash: []u8, sibling_hash: []u8) -> Secret {
	w := writer_make();
	w_vec(*w, encryption_key);
	w_vec(*w, parent_hash);
	w_vec(*w, sibling_hash);
	return hash_bytes(view(w.buf));
}

// original_parent_hash: parent hash of p as seen by its child on the side
// opposite `sibling`, excluding p's unmerged leaves from the sibling subtree.
original_parent_hash :: (t: *Tree, p: u32, sibling: u32) -> Secret {
	pn := *t.nodes[p].parent;
	sh := tree_hash(t, sibling, pn.unmerged_leaves);
	return parent_hash_of(pn.encryption_key, pn.parent_hash, view(sh));
}

// parent_hash_valid: every non-blank parent is parent-hash valid w.r.t. one child (RFC 9420 7.9.2).
parent_hash_valid :: (t: *Tree) -> bool {
	for x: 0..cast(u32)(len(t.nodes))-1 {
		if level(x) == 0 || t.nodes[x].kind != .Parent { continue; }
		l, r := left(x), right(x);
		lh := original_parent_hash(t, x, r);
		rh := original_parent_hash(t, x, l);
		if !has_parent_hash(t, l, view(lh)) && !has_parent_hash(t, r, view(rh)) { return false; }
	}
	return true;
}
#scope_module

has_parent_hash :: (t: *Tree, child: u32, target: []u8) -> bool {
	for nr: resolution(t, child) {
		if bytes_equal(node_parent_hash(*t.nodes[nr]), target) { return true; }
	}
	return false;
}
#scope_export

// ---------------------------------------------------------------------------
// Ratchet tree extension encoding

w_ratchet_tree :: (w: *Writer, t: *Tree) {
	last := len(t.nodes) - 1;
	while last >= 0 && t.nodes[last].kind == .Blank { last -= 1; }
	p := w_begin(w);
	for i: 0..last {
		n := *t.nodes[i];
		w_optional(w, n.kind != .Blank);
		if n.kind == {
		case .Leaf;
			w_u8(w, 1);
			w_leaf_node(w, n.leaf);
		case .Parent;
			w_u8(w, 2);
			w_parent_node(w, n.parent);
		case .Blank;
		}
	}
	w_end(w, p);
}

ratchet_tree_bytes :: (t: *Tree, a := temp) -> []u8 {
	w := writer_make(a);
	w_ratchet_tree(*w, t);
	return view(w.buf);
}

parse_ratchet_tree :: (b: []u8, a: Allocator) -> Tree, Error {
	t: Tree;
	err: Error;
	r := reader_make(b);
	sub := r_sub(*r);
	if !r_done(*r) { return t, .Decode; }
	t.nodes = make_dynamic(Node, 0, 16);
	while r_ok(*sub) && r_left(*sub) > 0 {
		n: Node;
		if r_optional(*sub) {
			idx := cast(u32)(len(t.nodes));
			if r_u8(*sub) == {
			case 1;
				if level(idx) != 0 { return t, .Decode; }
				n.kind = .Leaf;
				n.leaf = r_leaf_node(*sub, a);
			case 2;
				if level(idx) == 0 { return t, .Decode; }
				n.kind = .Parent;
				n.parent = r_parent_node(*sub, a);
			case;
				return t, .Decode;
			}
		}
		append(*t.nodes, n);
	}
	if !r_ok(*sub) || len(t.nodes) == 0 { return t, .Decode; }
	if t.nodes[len(t.nodes) - 1].kind == .Blank { return t, .Decode; }
	if len(t.nodes) % 2 == 0 { return t, .Decode; } // must end on a leaf
	// extend to a full tree
	leaves := cast(u32)(len(t.nodes) + 1) / 2;
	full: u32 = 1;
	while full < leaves { full <<= 1; }
	while cast(u32)(len(t.nodes)) < node_width(full) { append(*t.nodes, Node.{}); }
	return t, .None;
}

// truncate: drop the right half while it is entirely blank.
tree_truncate :: (t: *Tree) {
	while len(t.nodes) > 1 {
		nl := n_leaves(t);
		half := nl / 2;
		all_blank := true;
		for l: half..nl-1 {
			if t.nodes[l * 2].kind != .Blank {
				all_blank = false;
				break;
			}
		}
		if !all_blank { break; }
		resize(*t.nodes, cast(int)(node_width(half)));
	}
}

tree_blank_path :: (t: *Tree, leaf: u32) {
	for p: direct_path(leaf * 2, n_leaves(t)) { t.nodes[p] = Node.{}; }
}

// tree_add_leaf: leftmost blank leaf or extend; marks unmerged on the direct path.
tree_add_leaf :: (t: *Tree, ln: Leaf_Node, a: Allocator) -> u32 {
	nl := n_leaves(t);
	idx := nl;
	for l: 0..nl-1 {
		if t.nodes[l * 2].kind == .Blank {
			idx = l;
			break;
		}
	}
	if idx == nl {
		new_w := node_width(ifx nl > 0 then nl * 2 else 1);
		while cast(u32)(len(t.nodes)) < new_w { append(*t.nodes, Node.{}); }
	}
	t.nodes[idx * 2] = Node.{kind = .Leaf, leaf = ln};
	for p: direct_path(idx * 2, n_leaves(t)) {
		n := *t.nodes[p];
		if n.kind == .Parent {
			ul := make_slice(u32, len(n.parent.unmerged_leaves) + 1);
			copy(ul, n.parent.unmerged_leaves);
			ul[len(ul) - 1] = idx;
			n.parent.unmerged_leaves = ul;
		}
	}
	return idx;
}

// verify_leaf_signature: LeafNodeTBS signed with the leaf's own signature key.
verify_leaf_signature :: (ln: Leaf_Node, group_id: []u8, leaf_index: u32) -> bool {
	return verify_with_label(ln.signature_key, "LeafNodeTBS", leaf_node_tbs(ln, group_id, leaf_index), ln.signature);
}

// tree_validate: structural checks done when joining from a Welcome.
tree_validate :: (t: *Tree, group_id: []u8, expected_hash: []u8) -> Error {
	h := root_tree_hash(t);
	if !bytes_equal(view(h), expected_hash) { return .Verify; }
	if !parent_hash_valid(t) { return .Verify; }
	nl := n_leaves(t);
	for l: 0..nl-1 {
		n := *t.nodes[l * 2];
		if n.kind != .Leaf { continue; }
		if !verify_leaf_signature(n.leaf, group_id, l) { return .Verify; }
		// unique signature / encryption keys
		for m: l + 1..nl-1 {
			o := *t.nodes[m * 2];
			if o.kind != .Leaf { continue; }
			if bytes_equal(o.leaf.signature_key, n.leaf.signature_key) { return .Verify; }
			if bytes_equal(o.leaf.encryption_key, n.leaf.encryption_key) { return .Verify; }
		}
	}
	// unmerged leaves must be descendants and appear in every ancestor below
	for x: 0..cast(u32)(len(t.nodes))-1 {
		n := *t.nodes[x];
		if n.kind != .Parent { continue; }
		for l: n.parent.unmerged_leaves {
			if !is_ancestor(x, l * 2) { return .Verify; }
			if t.nodes[l * 2].kind != .Leaf { return .Verify; }
		}
	}
	return .None;
}

