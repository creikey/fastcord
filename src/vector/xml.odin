package vector

import "core:strings"

// Minimal XML reader: elements + attributes into a flat tree. Text, comments,
// processing instructions, DOCTYPE and CDATA are skipped.

@(private)
Attr :: struct {
	name, value: string,
}

@(private)
Node :: struct {
	name:        string,
	attrs:       []Attr,
	parent:      i32,
	first_child: i32,
	last_child:  i32,
	next:        i32,
}

@(private)
Doc :: struct {
	nodes: [dynamic]Node, // nodes[0] is the document root
	ids:   map[string]i32,
}

@(private)
xml_parse :: proc(src: string, doc: ^Doc, allocator := context.allocator) -> bool {
	context.allocator = allocator
	doc.nodes = make([dynamic]Node)
	doc.ids = make(map[string]i32)
	append(&doc.nodes, Node{parent = -1, first_child = -1, last_child = -1, next = -1})
	cur: i32 = 0
	attrs := make([dynamic]Attr)
	i := 0
	n := len(src)
	for i < n {
		lt := strings.index_byte(src[i:], '<')
		if lt < 0 do break
		i += lt
		rest := src[i:]
		switch {
		case strings.has_prefix(rest, "<!--"):
			e := strings.index(rest, "-->")
			if e < 0 do return false
			i += e + 3
			continue
		case strings.has_prefix(rest, "<![CDATA["):
			e := strings.index(rest, "]]>")
			if e < 0 do return false
			i += e + 3
			continue
		case strings.has_prefix(rest, "<?"):
			e := strings.index(rest, "?>")
			if e < 0 do return false
			i += e + 2
			continue
		case strings.has_prefix(rest, "<!"):
			e := strings.index_byte(rest, '>')
			if e < 0 do return false
			i += e + 1
			continue
		case strings.has_prefix(rest, "</"):
			e := strings.index_byte(rest, '>')
			if e < 0 do return false
			i += e + 1
			if cur == 0 do return false
			cur = doc.nodes[cur].parent
			continue
		}
		// Start tag.
		i += 1
		ns := i
		for i < n && !is_space(src[i]) && src[i] != '/' && src[i] != '>' do i += 1
		name := src[ns:i]
		if len(name) == 0 do return false
		clear(&attrs)
		self_close := false
		for {
			for i < n && is_space(src[i]) do i += 1
			if i >= n do return false
			if src[i] == '>' {
				i += 1
				break
			}
			if src[i] == '/' {
				if i + 1 >= n || src[i + 1] != '>' do return false
				i += 2
				self_close = true
				break
			}
			as := i
			for i < n && !is_space(src[i]) && src[i] != '=' && src[i] != '>' && src[i] != '/' do i += 1
			aname := src[as:i]
			for i < n && is_space(src[i]) do i += 1
			if i >= n || src[i] != '=' {
				append(&attrs, Attr{aname, ""}) // valueless attribute
				continue
			}
			i += 1
			for i < n && is_space(src[i]) do i += 1
			if i >= n || (src[i] != '"' && src[i] != '\'') do return false
			q := src[i]
			i += 1
			vs := i
			for i < n && src[i] != q do i += 1
			if i >= n do return false
			value := src[vs:i]
			i += 1
			if strings.index_byte(value, '&') >= 0 do value = decode_entities(value)
			append(&attrs, Attr{aname, value})
		}
		idx := i32(len(doc.nodes))
		node := Node {
			name        = name,
			attrs       = make([]Attr, len(attrs)),
			parent      = cur,
			first_child = -1,
			last_child  = -1,
			next        = -1,
		}
		copy(node.attrs, attrs[:])
		append(&doc.nodes, node)
		parent := &doc.nodes[cur]
		if parent.last_child >= 0 {
			doc.nodes[parent.last_child].next = idx
		} else {
			parent.first_child = idx
		}
		parent.last_child = idx
		for a in node.attrs {
			if a.name == "id" do doc.ids[a.value] = idx
		}
		if !self_close do cur = idx
	}
	return true
}

@(private)
attr :: proc(doc: ^Doc, ni: i32, name: string) -> (string, bool) {
	for a in doc.nodes[ni].attrs {
		if a.name == name do return a.value, true
	}
	return "", false
}

@(private)
is_space :: #force_inline proc(c: u8) -> bool {
	return c == ' ' || c == '\t' || c == '\n' || c == '\r'
}

@(private)
decode_entities :: proc(s: string) -> string {
	b := strings.builder_make()
	i := 0
	for i < len(s) {
		if s[i] == '&' {
			e := strings.index_byte(s[i:], ';')
			if e > 0 {
				ent := s[i + 1:i + e]
				r: u8 = 0
				switch ent {
				case "amp":
					r = '&'
				case "lt":
					r = '<'
				case "gt":
					r = '>'
				case "quot":
					r = '"'
				case "apos":
					r = '\''
				}
				if r != 0 {
					strings.write_byte(&b, r)
					i += e + 1
					continue
				}
			}
		}
		strings.write_byte(&b, s[i])
		i += 1
	}
	return strings.to_string(b)
}
