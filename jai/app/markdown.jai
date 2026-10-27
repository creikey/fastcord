// Discord-flavoured markdown, parsed into blocks of inline tokens. Rendering
// (fonts, colors) happens in the chat view; this file is pure and tested.

Block_Kind :: enum u8 {
	Paragraph;
	Code_Block;
	Quote;
	Heading1;
	Heading2;
	Heading3;
	Subtext; // "-# "
	List_Item;
}

Inline_Style :: enum_flags u8 {
	Bold;
	Italic;
	Underline;
	Strike;
	Code;
	Spoiler;
}

Token_Kind :: enum u8 {
	Text;
	Link; // url = text
	User_Mention; // id
	Role_Mention;
	Channel_Mention;
	Everyone; // @everyone / @here
	Custom_Emoji; // name, id, animated
	Timestamp; // id = unix seconds, name = format letter
}

Token :: struct {
	kind: Token_Kind;
	text: string; // display text (slice of source or literal)
	styles: Inline_Style;
	id: u64;
	name: string;
	animated: bool;
}

Md_Block :: struct {
	kind: Block_Kind;
	tokens: []Token;
	lang: string; // code block language
	code: string; // code block body
	depth: int; // list nesting
}

// Parses into temp.
md_parse :: (src: string) -> []Md_Block {
	push_allocator(temp);
	blocks: [..]Md_Block;
	array_reserve(*blocks, 4);
	// Paragraph lines are always consecutive in src (any other line flushes first), so a paragraph
	// is the slice src[para_lo:para_hi] and needs no copy.
	para_lo, para_hi := 0, 0;
	flush :: () #expand {
		if `para_hi <= `para_lo return;
		// a trailing newline belongs to the block separator, not the paragraph
		array_add(*`blocks, .{kind = .Paragraph, tokens = md_inline(trim_right(span(`src, `para_lo, `para_hi), "\n"))});
		`para_lo, `para_hi = 0, 0;
	}
	add :: (kind: Block_Kind, text: string, depth := 0) #expand {
		flush();
		array_add(*`blocks, .{kind = kind, tokens = md_inline(text), depth = depth});
	}
	rest := src;
	while rest {
		// fenced code block
		if begins_with(rest, "```") {
			body := span(rest, 3, rest.count);
			end := find_index_from_left(body, "```");
			if end >= 0 {
				flush();
				code := span(body, 0, end);
				lang := "";
				nl := find_index_from_left(code, #char "\n");
				if nl >= 0 {
					first := span(code, 0, nl);
					if first && find_index_of_any_from_left(first, " \t") < 0 {
						lang = first;
						code = span(code, nl + 1, code.count);
					}
				}
				if ends_with(code, "\n") code.count -= 1;
				array_add(*blocks, .{kind = .Code_Block, code = code, lang = lang});
				rest = span(body, end + 3, body.count);
				if begins_with(rest, "\n") advance(*rest);
				continue;
			}
		}
		nl := find_index_from_left(rest, #char "\n");
		line := ifx nl < 0 then rest else span(rest, 0, nl);
		next := ifx nl < 0 then "" else span(rest, nl + 1, rest.count);
		if begins_with(line, "> ") || line == ">" {
			q := span(line, 1, line.count);
			if begins_with(q, " ") advance(*q);
			add(.Quote, q);
		} else if begins_with(line, "### ") {
			add(.Heading3, span(line, 4, line.count));
		} else if begins_with(line, "## ") {
			add(.Heading2, span(line, 3, line.count));
		} else if begins_with(line, "# ") {
			add(.Heading1, span(line, 2, line.count));
		} else if begins_with(line, "-# ") {
			add(.Subtext, span(line, 3, line.count));
		} else if is_list_line(line) {
			indent := 0;
			while indent < line.count && line[indent] == #char " " indent += 1;
			add(.List_Item, span(line, indent + 2, line.count), indent / 2);
		} else {
			here := src.count - rest.count;
			if para_hi <= para_lo para_lo = here;
			para_hi = here + line.count + (ifx nl >= 0 then 1 else 0);
		}
		rest = next;
	}
	flush();
	return blocks;
}

md_inline :: (src: string) -> []Token {
	p: Md_Parser;
	inline_into(*p, src);
	// merge adjacent plain text with identical styles
	merged: [..]Token;
	array_reserve(*merged, p.out.count);
	for t: p.out {
		if merged && t.kind == .Text {
			prev := *merged[merged.count - 1];
			if prev.kind == .Text && prev.styles == t.styles {
				// tokens are slices of contiguous source only when adjacent; join otherwise
				if prev.text.data + prev.text.count == t.text.data prev.text.count += t.text.count;
				else prev.text = join(prev.text, t.text);
				continue;
			}
		}
		array_add(*merged, t);
	}
	return merged;
}

#scope_file

// s[lo:hi] as a view (String's slice() returns a literal "" past the end, which breaks the
// adjacency test in md_inline).
span :: (s: string, lo: int, hi: int) -> string {
	r := s;
	r.data += lo;
	r.count = hi - lo;
	return r;
}

is_list_line :: (line: string) -> bool {
	l := trim_left(line, " ");
	return begins_with(l, "- ") || begins_with(l, "* ");
}

Md_Parser :: struct {
	out: [..]Token;
	styles: Inline_Style;
}

emit :: (p: *Md_Parser, kind: Token_Kind, text: string) {
	if text == "" && kind == .Text return;
	array_add(*p.out, .{kind = kind, text = text, styles = p.styles});
}

// Delimited styles, checked longest-first like Discord's simple-markdown rules.
DELIMS :: struct {
	open: string;
	style: Inline_Style;
}.[.{"***", .Bold}, .{"**", .Bold}, .{"__", .Underline}, .{"~~", .Strike}, .{"||", .Spoiler}, .{"*", .Italic}, .{"_", .Italic}];

// Bytes that can start an inline rule in inline_into; every other byte is plain text.
MD_SPECIAL :: #run -> [256]bool { t: [256]bool; for cast([]u8) "\\`<h@*_~|" t[it] = true; return t; };

inline_into :: (p: *Md_Parser, src: string) {
	i := 0;
	text_start := 0;
	// pending(): the plain text before src[i]; take(to): continue after a rule ending at `to`
	take :: (to: int) #expand { `i = to; `text_start = to; }
	pending :: () -> string #expand { return span(`src, `text_start, `i); }
	while i < src.count {
		c := src[i];
		if !MD_SPECIAL[c] {
			i += 1;
			continue;
		}
		here := span(src, i, src.count);
		// a backslash escapes any ASCII punctuation (simple-markdown's escape rule)
		if c == #char "\\" && i + 1 < src.count && is_ascii_punct(src[i + 1]) {
			emit(p, .Text, pending());
			emit(p, .Text, span(src, i + 1, i + 2));
			take(i + 2);
			continue;
		}
		// inline code: `x` or ``x``
		if c == #char "`" {
			ticks := ifx begins_with(here, "``") then 2 else 1;
			end := find_index_from_left(src, span(src, i, i + ticks), i + ticks) - (i + ticks);
			if end > 0 {
				emit(p, .Text, pending());
				saved := p.styles;
				p.styles |= .Code;
				body := span(src, i + ticks, i + ticks + end);
				if ticks == 2 body = trim(body, SPACES);
				emit(p, .Text, body);
				p.styles = saved;
				take(i + ticks * 2 + end);
				continue;
			}
		}
		// <...> entities
		if c == #char "<" {
			n, ok := try_entity(p, here, pending());
			if ok {
				take(i + n);
				continue;
			}
		}
		// bare links
		if c == #char "h" && (begins_with(here, "https://") || begins_with(here, "http://")) && (i == 0 || !is_alnum(src[i - 1])) {
			end := i;
			while end < src.count && src[end] != #char " " && src[end] != #char "\n" && src[end] != #char "<" end += 1;
			// trailing punctuation is not part of the URL
			while end > i && find_index_from_left(".,:;!?)'\"", src[end - 1]) >= 0 end -= 1;
			emit(p, .Text, pending());
			emit(p, .Link, span(src, i, end));
			take(end);
			continue;
		}
		// @everyone / @here
		if c == #char "@" && (begins_with(here, "@everyone") || begins_with(here, "@here")) {
			n := ifx begins_with(here, "@everyone") then 9 else 5;
			emit(p, .Text, pending());
			emit(p, .Everyone, span(src, i, i + n));
			take(i + n);
			continue;
		}
		// style delimiters
		matched := false;
		for d: DELIMS {
			if !begins_with(here, d.open) continue;
			// underscores only work at word boundaries
			if d.open == "_" && i > 0 && is_alnum(src[i - 1]) continue;
			body_start := i + d.open.count;
			end := find_close(src, body_start, d.open);
			if end <= body_start continue;
			emit(p, .Text, pending());
			saved := p.styles;
			p.styles |= d.style;
			if d.open == "***" p.styles |= .Italic;
			inline_into(p, span(src, body_start, end));
			p.styles = saved;
			take(end + d.open.count);
			matched = true;
			break;
		}
		if !matched i += 1;
	}
	emit(p, .Text, span(src, text_start, src.count));
}

// Odin's strings.trim_space set.
SPACES :: " \t\n\r\x0b\x0c";

find_close :: (src: string, from: int, delim: string) -> int {
	j := from;
	while j < src.count {
		if src[j] == #char "\\" {
			j += 2;
			continue;
		}
		if src[j] == #char "`" {
			// skip code spans
			end := find_index_from_left(src, #char "`", j + 1);
			if end >= 0 {
				j = end + 1;
				continue;
			}
		}
		if begins_with(span(src, j, src.count), delim) {
			// "**" must not match the first half of "***" closing a bold+italic run
			if delim == "*" && j + 1 < src.count && src[j + 1] == #char "*" {
				j += 2;
				continue;
			}
			if delim == "_" && j + 1 < src.count && is_alnum(src[j + 1]) {
				j += 1;
				continue;
			}
			return j;
		}
		j += 1;
	}
	return -1;
}

is_alnum :: (c: u8) -> bool {
	return (c >= #char "a" && c <= #char "z") || (c >= #char "A" && c <= #char "Z") || (c >= #char "0" && c <= #char "9");
}

try_entity :: (p: *Md_Parser, s: string, pending: string) -> int, bool {
	end := find_index_from_left(s, #char ">");
	if end < 0 return 0, false;
	inner := span(s, 1, end);
	n := end + 1;
	whole := span(s, 0, n);
	after :: (k: int) -> string #expand { return span(`inner, k, `inner.count); }
	tok: Token;
	if begins_with(inner, "@&") {
		id, ok := dc.parse_u64(after(2));
		if !ok return 0, false;
		tok = .{kind = .Role_Mention, id = id, text = whole};
	} else if begins_with(inner, "@") {
		id, ok := dc.parse_u64(trim_left(after(1), "!"));
		if !ok return 0, false;
		tok = .{kind = .User_Mention, id = id, text = whole};
	} else if begins_with(inner, "#") {
		id, ok := dc.parse_u64(after(1));
		if !ok return 0, false;
		tok = .{kind = .Channel_Mention, id = id, text = whole};
	} else if begins_with(inner, ":") || begins_with(inner, "a:") {
		animated := inner[0] == #char "a";
		body := after(ifx animated then 2 else 1);
		colon := find_index_from_left(body, #char ":");
		if colon <= 0 return 0, false;
		id, ok := dc.parse_u64(span(body, colon + 1, body.count));
		if !ok return 0, false;
		tok = .{kind = .Custom_Emoji, id = id, name = span(body, 0, colon), animated = animated, text = whole};
	} else if begins_with(inner, "t:") {
		found, secs, style := split_from_left(after(2), #char ":");
		if !found secs = after(2);
		// the style is what sits between the first and a second colon
		colon2 := find_index_from_left(style, #char ":");
		if colon2 >= 0 style.count = colon2;
		v, ok := dc.parse_u64(secs);
		if !ok return 0, false;
		tok = .{kind = .Timestamp, id = v, name = ifx found then style else "f", text = whole};
	} else if begins_with(inner, "https://") || begins_with(inner, "http://") {
		// <url> suppresses embeds but still links
		tok = .{kind = .Link, text = inner};
	} else {
		return 0, false;
	}
	emit(p, .Text, pending);
	tok.styles = p.styles;
	array_add(*p.out, tok);
	return n, true;
}

is_ascii_punct :: (c: u8) -> bool {
	return (c >= #char "!" && c <= #char "/") || (c >= #char ":" && c <= #char "@") || (c >= #char "[" && c <= #char "`") || (c >= #char "{" && c <= #char "~");
}
