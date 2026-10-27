#scope_module

// Minimal XML reader: elements + attributes into a flat tree. Text, comments,
// processing instructions, DOCTYPE and CDATA are skipped.

Attr :: struct {
	name, value: string;
}

Node :: struct {
	name: string;
	attrs: []Attr;
	parent: s32;
	first_child: s32;
	last_child: s32;
	next: s32;
}

Doc :: struct {
	nodes: [..]Node; // nodes[0] is the document root
	ids: Table(string, s32);
}

// Everything is allocated with context.allocator.
xml_parse :: (src: string, doc: *Doc) -> bool {
	array_add(*doc.nodes, Node.{parent = -1, first_child = -1, last_child = -1, next = -1});
	cur: s32 = 0;
	attrs: [..]Attr;
	i := 0;
	n := src.count;
	skip_past :: (i: *int, rest: string, end: string) -> bool {
		e := find_index_from_left(rest, end);
		if e < 0 return false;
		i.* += e + end.count;
		return true;
	}
	while i < n {
		lt := find_index_from_left(src, #char "<", i);
		if lt < 0 break;
		i = lt;
		rest := advance(src, i);
		if begins_with(rest, "<!--") {
			if !skip_past(*i, rest, "-->") return false;
			continue;
		} else if begins_with(rest, "<![CDATA[") {
			if !skip_past(*i, rest, "]]>") return false;
			continue;
		} else if begins_with(rest, "<?") {
			if !skip_past(*i, rest, "?>") return false;
			continue;
		} else if begins_with(rest, "<!") {
			if !skip_past(*i, rest, ">") return false;
			continue;
		} else if begins_with(rest, "</") {
			if !skip_past(*i, rest, ">") return false;
			if cur == 0 return false;
			cur = doc.nodes[cur].parent;
			continue;
		}
		// Start tag.
		i += 1;
		ns := i;
		while i < n && !is_space(src[i]) && src[i] != #char "/" && src[i] != #char ">"  i += 1;
		name := slice(src, ns, i - ns);
		if name.count == 0 return false;
		array_reset_keeping_memory(*attrs);
		self_close := false;
		while true {
			while i < n && is_space(src[i])  i += 1;
			if i >= n return false;
			if src[i] == #char ">" {
				i += 1;
				break;
			}
			if src[i] == #char "/" {
				if i + 1 >= n || src[i + 1] != #char ">" return false;
				i += 2;
				self_close = true;
				break;
			}
			as := i;
			while i < n && !is_space(src[i]) && src[i] != #char "=" && src[i] != #char ">" && src[i] != #char "/"  i += 1;
			aname := slice(src, as, i - as);
			while i < n && is_space(src[i])  i += 1;
			if i >= n || src[i] != #char "=" {
				array_add(*attrs, Attr.{aname, ""}); // valueless attribute
				continue;
			}
			i += 1;
			while i < n && is_space(src[i])  i += 1;
			if i >= n || (src[i] != #char "\"" && src[i] != #char "'") return false;
			q := src[i];
			i += 1;
			vs := i;
			while i < n && src[i] != q  i += 1;
			if i >= n return false;
			value := slice(src, vs, i - vs);
			i += 1;
			if contains(value, #char "&")  value = decode_entities(value);
			array_add(*attrs, Attr.{aname, value});
		}
		idx := cast(s32) doc.nodes.count;
		node := Node.{name = name, attrs = array_copy(attrs), parent = cur, first_child = -1, last_child = -1, next = -1};
		array_add(*doc.nodes, node);
		parent := *doc.nodes[cur];
		if parent.last_child >= 0  doc.nodes[parent.last_child].next = idx;
		else                       parent.first_child = idx;
		parent.last_child = idx;
		for node.attrs if it.name == "id"  table_set(*doc.ids, it.value, idx);
		if !self_close  cur = idx;
	}
	return true;
}

attr :: (doc: *Doc, ni: s32, name: string) -> string, bool {
	for doc.nodes[ni].attrs if it.name == name return it.value, true;
	return "", false;
}

is_space :: inline (c: u8) -> bool {
	return c == #char " " || c == #char "\t" || c == #char "\n" || c == #char "\r";
}

decode_entities :: (s: string) -> string {
	b: String_Builder;
	i := 0;
	while i < s.count {
		if s[i] == #char "&" {
			e := find_index_from_left(s, #char ";", i) - i;
			if e > 0 {
				r: u8;
				if slice(s, i + 1, e - 1) == {
					case "amp";  r = #char "&";
					case "lt";   r = #char "<";
					case "gt";   r = #char ">";
					case "quot"; r = #char "\"";
					case "apos"; r = #char "'";
				}
				if r {
					append(*b, r);
					i += e + 1;
					continue;
				}
			}
		}
		append(*b, s[i]);
		i += 1;
	}
	return builder_to_string(*b);
}
