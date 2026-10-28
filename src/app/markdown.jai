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
	Link; // url, or text when url is ""
	User_Mention; // id
	Role_Mention;
	Channel_Mention;
	Everyone; // @everyone / @here
	Custom_Emoji; // name, id, animated
	Timestamp; // id = unix seconds, name = format letter
	Command; // name = "/name sub" for </name sub:id>, or a server page's label for <id:customize> etc.
}

Token :: struct {
	kind: Token_Kind;
	text: string; // display text (slice of source or literal)
	styles: Inline_Style;
	id: u64;
	name: string;
	animated: bool;
	url: string; // masked link target
}

Md_Block :: struct {
	kind: Block_Kind;
	tokens: []Token;
	lang: string; // code block language
	code: string; // code block body
	depth: int; // list nesting
	number: int; // ordered list item's number; 0 = bullet
	quoted: bool; // inside a "> " / ">>> " quote (its paragraphs are .Quote)
}

// Parses into temp. A quote's body is parsed again with quoted set, as the client's blockQuote rule
// does: headings, lists and code blocks work inside, nested quotes don't.
md_parse :: (src: string, quoted := false) -> []Md_Block {
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
	add_quote :: (text: string) #expand {
		flush();
		inner := md_parse(text, quoted = true);
		if !inner array_add(*`blocks, .{kind = .Quote, quoted = true});
		for inner {
			b := it;
			if b.kind == .Paragraph b.kind = .Quote;
			b.quoted = true;
			array_add(*`blocks, b);
		}
	}
	rest := src;
	while rest {
		// fenced code block
		if begins_with(rest, "```") {
			body := span(rest, 3, rest.count);
			end := find_index_from_left(body, "```");
			// the client's rule: ```(lang\n)?\n*(body)\n*``` with lang [a-z0-9_+\-.#]+ and a
			// body holding something besides newlines
			code := ifx end >= 0 then span(body, 0, end) else "";
			lang := "";
			nl := find_index_from_left(code, #char "\n");
			if nl > 0 && is_lang_name(span(code, 0, nl)) {
				lang = span(code, 0, nl);
				code = span(code, nl + 1, code.count);
			}
			while code && code[0] == #char "\n" advance(*code);
			while code && code[code.count - 1] == #char "\n" code.count -= 1;
			if code {
				flush();
				array_add(*blocks, .{kind = .Code_Block, code = code, lang = lang});
				rest = span(body, end + 3, body.count);
				if begins_with(rest, "\n") advance(*rest);
				continue;
			}
		}
		nl := find_index_from_left(rest, #char "\n");
		line := ifx nl < 0 then rest else span(rest, 0, nl);
		next := ifx nl < 0 then "" else span(rest, nl + 1, rest.count);
		if !quoted && begins_with(line, ">>> ") {
			// quotes the rest of the message
			add_quote(trim_right(span(rest, 4, rest.count), "\n"));
			break;
		} else if !quoted && is_quote_line(line) {
			// consecutive "> " lines are one blockquote (one bar), as in the client
			sb: String_Builder;
			while true {
				q := span(line, 1, line.count);
				if begins_with(q, " ") advance(*q);
				append(*sb, q);
				if !next break;
				nl = find_index_from_left(next, #char "\n");
				l2 := ifx nl < 0 then next else span(next, 0, nl);
				if !is_quote_line(l2) break;
				line = l2;
				next = ifx nl < 0 then "" else span(next, nl + 1, next.count);
				append(*sb, "\n");
			}
			add_quote(builder_to_string(*sb));
		} else if begins_with(line, "### ") {
			add(.Heading3, span(line, 4, line.count));
		} else if begins_with(line, "## ") {
			add(.Heading2, span(line, 3, line.count));
		} else if begins_with(line, "# ") {
			add(.Heading1, span(line, 2, line.count));
		} else if begins_with(line, "-# ") {
			add(.Subtext, span(line, 3, line.count));
		} else if is_list_line(line) {
			indent, body, number := list_marker(line);
			add(.List_Item, span(line, body, line.count), indent / 2);
			if number {
				// an ordered list counts up from its first item's number, as in the client
				prev := ifx blocks.count >= 2 then *blocks[blocks.count - 2] else null;
				same_list := prev && prev.kind == .List_Item && prev.number && prev.depth == indent / 2;
				blocks[blocks.count - 1].number = ifx same_list then prev.number + 1 else number;
			}
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

is_quote_line :: (line: string) -> bool { return begins_with(line, "> ") || line == ">"; }

// merge = false keeps every token a slice of src, in source order (the composer styles the
// gaps between them as markdown syntax), and leaves masked links as text, as the composer does.
md_inline :: (src: string, merge := true) -> []Token {
	p := Md_Parser.{masked_links = merge};
	inline_into(*p, src);
	if !merge return p.out;
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

// A line of composer text and its place in ``` blocks, tracked line by line like the official
// composer (withCodeBlocks): inside = a line in an open block with no ``` of its own (drawn as
// code); opens = it opens a block (odd ``` count once a closing one is taken off); lang = the
// block's language, the text after the opening line's last ```.
Code_Line :: struct {
	start, end: int; // byte range, without the newline
	inside: bool;
	opens: bool;
	ticks: int; // ``` runs on the line
	lang: string;
}

md_code_lines :: (text: string) -> []Code_Line {
	lines: [..]Code_Line;
	lines.allocator = temp;
	prev_in := false;
	lang := "";
	start := 0;
	while true {
		nl := find_index_from_left(text, #char "\n", start);
		end := ifx nl < 0 then text.count else nl;
		l := Code_Line.{start = start, end = end};
		line := span(text, start, end);
		// ``` runs (a backslash skips the byte after it) and where the last one ends
		last := 0;
		i := 0;
		while i < line.count {
			if line[i] == #char "\\" { i += 2; continue; }
			if begins_with(span(line, i, line.count), "```") { l.ticks += 1; i += 3; last = i; continue; }
			i += 1;
		}
		closes := prev_in && l.ticks > 0;
		l.inside = prev_in && l.ticks == 0;
		l.opens = (l.ticks - cast(int) closes) % 2 == 1;
		if l.opens {
			tail := span(line, last, line.count);
			lang = ifx is_lang_name(tail) then tail else "";
		} else if !l.inside {
			lang = "";
		}
		l.lang = lang;
		prev_in = l.inside || l.opens;
		array_add(*lines, l);
		if nl < 0 break;
		start = nl + 1;
	}
	return lines;
}

// True when the ``` count before pos is odd: Enter there adds a newline instead of sending.
md_in_code_block :: (text: string, pos: int) -> bool {
	n, i := 0, 0;
	while i + 3 <= pos {
		if begins_with(span(text, i, pos), "```") { n += 1; i += 3; }
		else i += 1;
	}
	return n % 2 == 1;
}

// [a-z0-9_+\-.#]+, any case: what the client takes as a code block language.
is_lang_name :: (s: string) -> bool {
	if !s return false;
	for cast([]u8) s if !is_alnum(it) && find_index_from_left("_+-.#", it) < 0 return false;
	return true;
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
	_, body := list_marker(line);
	return body > 0;
}

// "- ", "* " or "<digits>. " after leading spaces: the indent, where the item's text starts
// (0 = not a list line) and an ordered item's number (0 for bullets).
list_marker :: (line: string) -> indent: int, body: int, number: int {
	i := 0;
	while i < line.count && line[i] == #char " " i += 1;
	indent := i;
	if i + 1 < line.count && (line[i] == #char "-" || line[i] == #char "*") && line[i + 1] == #char " " return indent, i + 2, 0;
	number := 0;
	while i < line.count && i - indent < 9 && line[i] >= #char "0" && line[i] <= #char "9" {
		number = number * 10 + line[i] - #char "0";
		i += 1;
	}
	if i == indent || i + 1 >= line.count || line[i] != #char "." || line[i + 1] != #char " " return indent, 0, 0;
	return indent, i + 2, max(number, 1);
}

Md_Parser :: struct {
	out: [..]Token;
	styles: Inline_Style;
	masked_links: bool;
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
MD_SPECIAL :: #run -> [256]bool { t: [256]bool; for cast([]u8) "\\`<h@*_~|[" t[it] = true; return t; };

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
		// masked links: [text](url), text styled as usual and every piece of it a link
		if c == #char "[" && p.masked_links {
			n, url := masked_link(here);
			if n > 0 {
				emit(p, .Text, pending());
				first := p.out.count;
				inline_into(p, span(src, i + 1, i + find_close_bracket(here)));
				for * array_view(p.out, first, p.out.count - first) if it.kind == .Text || it.kind == .Link { it.kind = .Link; it.url = url; }
				take(i + n);
				continue;
			}
		}
		// bare links
		if c == #char "h" && (begins_with(here, "https://") || begins_with(here, "http://")) && (i == 0 || !is_alnum(src[i - 1])) {
			end := i;
			while end < src.count && src[end] != #char " " && src[end] != #char "\n" && src[end] != #char "<" end += 1;
			// trailing punctuation is not part of the URL, except a ")" closing a "(" inside it (Foo_(bar))
			while end > i {
				t := src[end - 1];
				if t == #char ")" {
					opens, closes := 0, 0;
					for k: i..end - 1 {
						if src[k] == #char "(" opens += 1;
						if src[k] == #char ")" closes += 1;
					}
					if closes <= opens break;
				} else if find_index_from_left(".,:;!?'\"", t) < 0 break;
				end -= 1;
			}
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
	} else if begins_with(inner, "/") {
		colon := find_index_from_right(inner, #char ":");
		if colon <= 1 return 0, false;
		id, ok := dc.parse_u64(span(inner, colon + 1, inner.count));
		if !ok return 0, false;
		tok = .{kind = .Command, id = id, name = span(inner, 0, colon), text = whole};
	} else if begins_with(inner, "https://") || begins_with(inner, "http://") {
		// <url> suppresses embeds but still links
		tok = .{kind = .Link, text = inner};
	} else {
		// <id:customize> and friends: the server's own pages
		found, gid, page := split_from_left(inner, #char ":");
		_, ok := dc.parse_u64(gid);
		label: string;
		if page == {
		case "customize"; label = "Channels & Roles";
		case "browse"; label = "Browse Channels";
		case "guide"; #through; case "home"; label = "Server Guide";
		case "linked-roles"; label = "Linked Roles";
		}
		if !found || !ok || label == "" return 0, false;
		tok = .{kind = .Command, name = label, text = whole};
	}
	emit(p, .Text, pending);
	tok.styles = p.styles;
	array_add(*p.out, tok);
	return n, true;
}

// The client's link rule: [text](url) with balanced brackets in text and an http(s) url,
// optionally in <> or followed by a "title". Returns the bytes taken and the url.
masked_link :: (s: string) -> int, string {
	close := find_close_bracket(s);
	if close <= 1 || close + 1 >= s.count || s[close + 1] != #char "(" return 0, "";
	depth := 0;
	j := close + 2;
	while j < s.count {
		if s[j] == #char "\\" { j += 2; continue; }
		if s[j] == #char "\n" return 0, "";
		if s[j] == #char "(" depth += 1;
		if s[j] == #char ")" { if depth == 0 break; depth -= 1; }
		j += 1;
	}
	if j >= s.count return 0, "";
	url := trim(span(s, close + 2, j), SPACES);
	sp := find_index_from_left(url, #char " ");
	if sp >= 0 url.count = sp; // a "title" after the url
	if begins_with(url, "<") && ends_with(url, ">") url = span(url, 1, url.count - 1);
	if !begins_with(url, "https://") && !begins_with(url, "http://") return 0, "";
	return j + 1, url;
}

// Index of the "]" closing s's leading "[", -1 if none on that line.
find_close_bracket :: (s: string) -> int {
	depth, i := 0, 0;
	while i < s.count {
		c := s[i];
		if c == #char "\\" { i += 2; continue; }
		if c == #char "\n" return -1;
		if c == #char "[" depth += 1;
		if c == #char "]" { depth -= 1; if depth == 0 return i; }
		i += 1;
	}
	return -1;
}

is_ascii_punct :: (c: u8) -> bool {
	return (c >= #char "!" && c <= #char "/") || (c >= #char ":" && c <= #char "@") || (c >= #char "[" && c <= #char "`") || (c >= #char "{" && c <= #char "~");
}
