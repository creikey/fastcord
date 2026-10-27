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
	ids: Map(string, s32);
}

xml_parse :: (src: string, doc: *Doc, allocator := context.allocator) -> bool {
	push_allocator(allocator);
	doc.nodes = make_dynamic(Node, 0, 0);
	doc.ids = Map(string, s32).{};
	append(*doc.nodes, Node.{parent = -1, first_child = -1, last_child = -1, next = -1});
	cur: s32 = 0;
	attrs := make_dynamic(Attr, 0, 0);
	i := 0;
	n := len(src);
	while i < n {
		lt := strings.index_byte(sub_from(src, i), #char "<");
		if lt < 0 { break; }
		i += lt;
		rest := sub_from(src, i);
		if strings.has_prefix(rest, "<!--") {
			e := strings.index(rest, "-->");
			if e < 0 { return false; }
			i += e + 3;
			continue;
		} else if strings.has_prefix(rest, "<![CDATA[") {
			e := strings.index(rest, "]]>");
			if e < 0 { return false; }
			i += e + 3;
			continue;
		} else if strings.has_prefix(rest, "<?") {
			e := strings.index(rest, "?>");
			if e < 0 { return false; }
			i += e + 2;
			continue;
		} else if strings.has_prefix(rest, "<!") {
			e := strings.index_byte(rest, #char ">");
			if e < 0 { return false; }
			i += e + 1;
			continue;
		} else if strings.has_prefix(rest, "</") {
			e := strings.index_byte(rest, #char ">");
			if e < 0 { return false; }
			i += e + 1;
			if cur == 0 { return false; }
			cur = doc.nodes[cur].parent;
			continue;
		}
		// Start tag.
		i += 1;
		ns := i;
		while i < n && !is_space(src[i]) && src[i] != #char "/" && src[i] != #char ">" { i += 1; }
		name := sub(src, ns, i);
		if len(name) == 0 { return false; }
		clear(*attrs);
		self_close := false;
		while true {
			while i < n && is_space(src[i]) { i += 1; }
			if i >= n { return false; }
			if src[i] == #char ">" {
				i += 1;
				break;
			}
			if src[i] == #char "/" {
				if i + 1 >= n || src[i + 1] != #char ">" { return false; }
				i += 2;
				self_close = true;
				break;
			}
			as := i;
			while i < n && !is_space(src[i]) && src[i] != #char "=" && src[i] != #char ">" && src[i] != #char "/" { i += 1; }
			aname := sub(src, as, i);
			while i < n && is_space(src[i]) { i += 1; }
			if i >= n || src[i] != #char "=" {
				append(*attrs, Attr.{aname, ""}); // valueless attribute
				continue;
			}
			i += 1;
			while i < n && is_space(src[i]) { i += 1; }
			if i >= n || (src[i] != 34 && src[i] != #char "'") { return false; }
			q := src[i];
			i += 1;
			vs := i;
			while i < n && src[i] != q { i += 1; }
			if i >= n { return false; }
			value := sub(src, vs, i);
			i += 1;
			if strings.index_byte(value, #char "&") >= 0 { value = decode_entities(value); }
			append(*attrs, Attr.{aname, value});
		}
		idx := cast(s32)(len(doc.nodes));
		node := Node.{
			name = name,
			attrs = make_slice(Attr, len(attrs)),
			parent = cur,
			first_child = -1,
			last_child = -1,
			next = -1
		};
		copy(node.attrs, view(attrs));
		append(*doc.nodes, node);
		parent := *doc.nodes[cur];
		if parent.last_child >= 0 {
			doc.nodes[parent.last_child].next = idx;
		} else {
			parent.first_child = idx;
		}
		parent.last_child = idx;
		for a: node.attrs {
			if a.name == "id" { at(*doc.ids, a.value).* = idx; }
		}
		if !self_close { cur = idx; }
	}
	return true;
}

attr :: (doc: *Doc, ni: s32, name: string) -> string, bool {
	for a: doc.nodes[ni].attrs {
		if a.name == name { return a.value, true; }
	}
	return "", false;
}

is_space :: inline (c: u8) -> bool {
	return c == #char " " || c == 9 || c == 10 || c == 13;
};

decode_entities :: (s: string) -> string {
	b := strings.builder_make();
	i := 0;
	while i < len(s) {
		if s[i] == #char "&" {
			e := strings.index_byte(sub_from(s, i), #char ";");
			if e > 0 {
				ent := sub(s, i + 1, i + e);
				r: u8 = 0;
				if ent == {
				case "amp";
					r = #char "&";
				case "lt";
					r = #char "<";
				case "gt";
					r = #char ">";
				case "quot";
					r = 34;
				case "apos";
					r = #char "'";
				}
				if r != 0 {
					strings.write_byte(*b, r);
					i += e + 1;
					continue;
				}
			}
		}
		strings.write_byte(*b, s[i]);
		i += 1;
	}
	return strings.to_string(b);
}
#scope_export

