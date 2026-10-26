package mls

import "core:mem"

// ---------------------------------------------------------------------------
// Tree math (RFC 9420 Appendix C). Node indices in the array representation;
// trees are always full (leaf count a power of two).

level :: proc(x: u32) -> u32 {
	if x & 1 == 0 do return 0
	k: u32 = 0
	for (x >> k) & 1 == 1 do k += 1
	return k
}

node_width :: proc(n_leaves: u32) -> u32 {return 0 if n_leaves == 0 else 2 * (n_leaves - 1) + 1}

log2_floor :: proc(x: u32) -> u32 {
	if x == 0 do return 0
	k: u32 = 0
	for (x >> k) > 1 do k += 1
	return k
}

root :: proc(n_leaves: u32) -> u32 {
	w := node_width(n_leaves)
	return (u32(1) << log2_floor(w)) - 1
}

left :: proc(x: u32) -> u32 {
	k := level(x)
	assert(k > 0)
	return x ~ (u32(1) << (k - 1))
}

right :: proc(x: u32) -> u32 {
	k := level(x)
	assert(k > 0)
	return x ~ (u32(3) << (k - 1))
}

parent_of :: proc(x: u32) -> u32 {
	k := level(x)
	b := (x >> (k + 1)) & 1
	return (x | (u32(1) << k)) ~ (b << (k + 1))
}

sibling_of :: proc(x: u32) -> u32 {
	p := parent_of(x)
	return right(p) if x < p else left(p)
}

direct_path :: proc(x: u32, n_leaves: u32, a := context.temp_allocator) -> []u32 {
	r := root(n_leaves)
	out := make([dynamic]u32, 0, 8, a)
	if x == r do return out[:]
	y := x
	for y != r {
		y = parent_of(y)
		append(&out, y)
	}
	return out[:]
}

copath :: proc(x: u32, n_leaves: u32, a := context.temp_allocator) -> []u32 {
	dp := direct_path(x, n_leaves)
	out := make([dynamic]u32, 0, 8, a)
	if len(dp) == 0 do return out[:]
	append(&out, sibling_of(x))
	for i in 0 ..< len(dp) - 1 do append(&out, sibling_of(dp[i]))
	return out[:]
}

is_ancestor :: proc(a, x: u32) -> bool {
	// a is an ancestor of x (or equal) iff x lies in a's span
	k := level(a)
	lo := a - ((u32(1) << k) - 1)
	hi := a + ((u32(1) << k) - 1)
	return x >= lo && x <= hi
}

common_ancestor :: proc(x, y: u32) -> u32 {
	// lowest common ancestor in a full tree
	lx, ly := level(x), level(y)
	if lx <= ly && is_ancestor(y, x) do return y
	if ly <= lx && is_ancestor(x, y) do return x
	xn, yn := x, y
	k: u32 = 0
	for xn != yn {
		xn >>= 1
		yn >>= 1
		k += 1
	}
	return (xn << k) + ((u32(1) << (k - 1)) - 1) if k > 0 else xn
}

// ---------------------------------------------------------------------------
// Ratchet tree

Node_Kind :: enum u8 {
	Blank,
	Leaf,
	Parent,
}

Node :: struct {
	kind:   Node_Kind,
	leaf:   Leaf_Node,
	parent: Parent_Node,
}

Tree :: struct {
	nodes: [dynamic]Node,
}

n_leaves :: proc(t: ^Tree) -> u32 {return u32(len(t.nodes) + 1) / 2}

node_encryption_key :: proc(n: ^Node) -> []byte {
	switch n.kind {
	case .Leaf:
		return n.leaf.encryption_key
	case .Parent:
		return n.parent.encryption_key
	case .Blank:
	}
	return nil
}

node_parent_hash :: proc(n: ^Node) -> []byte {
	switch n.kind {
	case .Leaf:
		return n.leaf.parent_hash
	case .Parent:
		return n.parent.parent_hash
	case .Blank:
	}
	return nil
}

leaf_at :: proc(t: ^Tree, leaf: u32) -> ^Node {
	i := int(leaf) * 2
	if i >= len(t.nodes) do return nil
	return &t.nodes[i]
}

resolution :: proc(t: ^Tree, x: u32, a := context.temp_allocator) -> []u32 {
	out := make([dynamic]u32, 0, 8, a)
	resolve_into(t, x, &out)
	return out[:]
}

@(private)
resolve_into :: proc(t: ^Tree, x: u32, out: ^[dynamic]u32) {
	n := &t.nodes[x]
	switch n.kind {
	case .Leaf:
		append(out, x)
	case .Parent:
		append(out, x)
		for l in n.parent.unmerged_leaves do append(out, l * 2)
	case .Blank:
		if level(x) == 0 do return
		resolve_into(t, left(x), out)
		resolve_into(t, right(x), out)
	}
}

// filtered_direct_path: direct path nodes whose copath child has a non-empty resolution.
filtered_direct_path :: proc(t: ^Tree, leaf: u32, a := context.temp_allocator) -> []u32 {
	x := leaf * 2
	nl := n_leaves(t)
	dp := direct_path(x, nl)
	cp := copath(x, nl)
	out := make([dynamic]u32, 0, len(dp), a)
	for i in 0 ..< len(dp) {
		if len(resolution(t, cp[i])) > 0 do append(&out, dp[i])
	}
	return out[:]
}

// child of p on the path toward x
child_toward :: proc(p, x: u32) -> u32 {
	return left(p) if x < p else right(p)
}

contains_u32 :: proc(l: []u32, v: u32) -> bool {
	for x in l do if x == v do return true
	return false
}

// tree_hash with optional excluded leaves (treated as blank; also removed from
// unmerged_leaves lists) for "original sibling tree hash" (RFC 9420 7.9.2).
tree_hash :: proc(t: ^Tree, x: u32, exclude: []u32 = nil) -> Secret {
	n := &t.nodes[x]
	w := writer_make()
	if level(x) == 0 {
		w_u8(&w, 1)
		w_u32(&w, x / 2)
		present := n.kind == .Leaf && !contains_u32(exclude, x / 2)
		w_optional(&w, present)
		if present do w_leaf_node(&w, n.leaf)
	} else {
		w_u8(&w, 2)
		w_optional(&w, n.kind == .Parent)
		if n.kind == .Parent {
			w_vec(&w, n.parent.encryption_key)
			w_vec(&w, n.parent.parent_hash)
			p := w_begin(&w)
			for l in n.parent.unmerged_leaves do if !contains_u32(exclude, l) do w_u32(&w, l)
			w_end(&w, p)
		}
		lh := tree_hash(t, left(x), exclude)
		rh := tree_hash(t, right(x), exclude)
		w_vec(&w, lh[:])
		w_vec(&w, rh[:])
	}
	return hash_bytes(w.buf[:])
}

root_tree_hash :: proc(t: ^Tree) -> Secret {return tree_hash(t, root(n_leaves(t)))}

parent_hash_of :: proc(encryption_key, parent_hash, sibling_hash: []byte) -> Secret {
	w := writer_make()
	w_vec(&w, encryption_key)
	w_vec(&w, parent_hash)
	w_vec(&w, sibling_hash)
	return hash_bytes(w.buf[:])
}

// original_parent_hash: parent hash of p as seen by its child on the side
// opposite `sibling`, excluding p's unmerged leaves from the sibling subtree.
original_parent_hash :: proc(t: ^Tree, p, sibling: u32) -> Secret {
	pn := &t.nodes[p].parent
	sh := tree_hash(t, sibling, pn.unmerged_leaves)
	return parent_hash_of(pn.encryption_key, pn.parent_hash, sh[:])
}

// parent_hash_valid: every non-blank parent is parent-hash valid w.r.t. one child (RFC 9420 7.9.2).
parent_hash_valid :: proc(t: ^Tree) -> bool {
	for x in 0 ..< u32(len(t.nodes)) {
		if level(x) == 0 || t.nodes[x].kind != .Parent do continue
		l, r := left(x), right(x)
		lh := original_parent_hash(t, x, r)
		rh := original_parent_hash(t, x, l)
		if !has_parent_hash(t, l, lh[:]) && !has_parent_hash(t, r, rh[:]) do return false
	}
	return true
}

@(private)
has_parent_hash :: proc(t: ^Tree, child: u32, target: []byte) -> bool {
	for nr in resolution(t, child) {
		if bytes_equal(node_parent_hash(&t.nodes[nr]), target) do return true
	}
	return false
}

// ---------------------------------------------------------------------------
// Ratchet tree extension encoding

w_ratchet_tree :: proc(w: ^Writer, t: ^Tree) {
	last := len(t.nodes) - 1
	for last >= 0 && t.nodes[last].kind == .Blank do last -= 1
	p := w_begin(w)
	for i in 0 ..= last {
		n := &t.nodes[i]
		w_optional(w, n.kind != .Blank)
		switch n.kind {
		case .Leaf:
			w_u8(w, 1)
			w_leaf_node(w, n.leaf)
		case .Parent:
			w_u8(w, 2)
			w_parent_node(w, n.parent)
		case .Blank:
		}
	}
	w_end(w, p)
}

ratchet_tree_bytes :: proc(t: ^Tree, a := context.temp_allocator) -> []byte {
	w := writer_make(a)
	w_ratchet_tree(&w, t)
	return w.buf[:]
}

parse_ratchet_tree :: proc(b: []byte, a: mem.Allocator) -> (t: Tree, err: Error) {
	r := reader_make(b)
	sub := r_sub(&r)
	if !r_done(&r) do return t, .Decode
	t.nodes = make([dynamic]Node, 0, 16, a)
	for r_ok(&sub) && r_left(&sub) > 0 {
		n: Node
		if r_optional(&sub) {
			idx := u32(len(t.nodes))
			switch r_u8(&sub) {
			case 1:
				if level(idx) != 0 do return t, .Decode
				n.kind = .Leaf
				n.leaf = r_leaf_node(&sub, a)
			case 2:
				if level(idx) == 0 do return t, .Decode
				n.kind = .Parent
				n.parent = r_parent_node(&sub, a)
			case:
				return t, .Decode
			}
		}
		append(&t.nodes, n)
	}
	if !r_ok(&sub) || len(t.nodes) == 0 do return t, .Decode
	if t.nodes[len(t.nodes) - 1].kind == .Blank do return t, .Decode
	if len(t.nodes) % 2 == 0 do return t, .Decode // must end on a leaf
	// extend to a full tree
	leaves := u32(len(t.nodes) + 1) / 2
	full: u32 = 1
	for full < leaves do full <<= 1
	for u32(len(t.nodes)) < node_width(full) do append(&t.nodes, Node{})
	return t, .None
}

// truncate: drop the right half while it is entirely blank.
tree_truncate :: proc(t: ^Tree) {
	for len(t.nodes) > 1 {
		nl := n_leaves(t)
		half := nl / 2
		all_blank := true
		for l in half ..< nl {
			if t.nodes[l * 2].kind != .Blank {
				all_blank = false
				break
			}
		}
		if !all_blank do break
		resize(&t.nodes, int(node_width(half)))
	}
}

tree_blank_path :: proc(t: ^Tree, leaf: u32) {
	for p in direct_path(leaf * 2, n_leaves(t)) do t.nodes[p] = Node{}
}

// tree_add_leaf: leftmost blank leaf or extend; marks unmerged on the direct path.
tree_add_leaf :: proc(t: ^Tree, ln: Leaf_Node, a: mem.Allocator) -> u32 {
	nl := n_leaves(t)
	idx := nl
	for l in 0 ..< nl {
		if t.nodes[l * 2].kind == .Blank {
			idx = l
			break
		}
	}
	if idx == nl {
		new_w := node_width(nl * 2 if nl > 0 else 1)
		for u32(len(t.nodes)) < new_w do append(&t.nodes, Node{})
	}
	t.nodes[idx * 2] = Node{kind = .Leaf, leaf = ln}
	for p in direct_path(idx * 2, n_leaves(t)) {
		n := &t.nodes[p]
		if n.kind == .Parent {
			ul := make([]u32, len(n.parent.unmerged_leaves) + 1, a)
			copy(ul, n.parent.unmerged_leaves)
			ul[len(ul) - 1] = idx
			n.parent.unmerged_leaves = ul
		}
	}
	return idx
}

// verify_leaf_signature: LeafNodeTBS signed with the leaf's own signature key.
verify_leaf_signature :: proc(ln: Leaf_Node, group_id: []byte, leaf_index: u32) -> bool {
	return verify_with_label(ln.signature_key, "LeafNodeTBS", leaf_node_tbs(ln, group_id, leaf_index), ln.signature)
}

// tree_validate: structural checks done when joining from a Welcome.
tree_validate :: proc(t: ^Tree, group_id: []byte, expected_hash: []byte) -> Error {
	h := root_tree_hash(t)
	if !bytes_equal(h[:], expected_hash) do return .Verify
	if !parent_hash_valid(t) do return .Verify
	nl := n_leaves(t)
	for l in 0 ..< nl {
		n := &t.nodes[l * 2]
		if n.kind != .Leaf do continue
		if !verify_leaf_signature(n.leaf, group_id, l) do return .Verify
		// unique signature / encryption keys
		for m in l + 1 ..< nl {
			o := &t.nodes[m * 2]
			if o.kind != .Leaf do continue
			if bytes_equal(o.leaf.signature_key, n.leaf.signature_key) do return .Verify
			if bytes_equal(o.leaf.encryption_key, n.leaf.encryption_key) do return .Verify
		}
	}
	// unmerged leaves must be descendants and appear in every ancestor below
	for x in 0 ..< u32(len(t.nodes)) {
		n := &t.nodes[x]
		if n.kind != .Parent do continue
		for l in n.parent.unmerged_leaves {
			if !is_ancestor(x, l * 2) do return .Verify
			if t.nodes[l * 2].kind != .Leaf do return .Verify
		}
	}
	return .None
}
