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

Inline_Style :: enum u8 {
	Bold;
	Italic;
	Underline;
	Strike;
	Code;
	Spoiler;
}
Inline_Styles :: __BITSET__(Inline_Style;u8);

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
	styles: Inline_Styles;
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

md_parse :: (src: string, allocator := temp) -> []Md_Block {
	context.allocator = allocator;
	blocks := make_dynamic(Md_Block, 0, 4);
	// Paragraph lines are always consecutive in src (any other line flushes first), so a paragraph
	// is the slice src[para_lo:para_hi] and needs no copy.
	Para :: struct {
		src: string;
		lo, hi: int;
	}
	para := Para.{src = src};
	flush :: (blocks: *[..]Md_Block, para: *Para, kind: Block_Kind, depth := 0) {
		if para.hi <= para.lo { return; }
		// a trailing newline belongs to the block separator, not the paragraph
		txt := strings.trim_right(sub(para.src, para.lo, para.hi), "\n");
		append(blocks, Md_Block.{kind = kind, tokens = md_inline(txt), depth = depth});
		para.lo, para.hi = 0, 0;
	}
	rest := src;
	while len(rest) > 0 {
		// fenced code block
		if strings.has_prefix(rest, "```") {
			body := sub_from(rest, 3);
			{ end := strings.index(body, "```");
			if end >= 0 {
				flush(*blocks, *para, .Paragraph);
				code := sub(body, 0, end);
				lang := "";
				{ nl := strings.index_byte(code, 10);
				if nl >= 0 {
					first := sub(code, 0, nl);
					if len(first) > 0 && !strings.contains_any(first, " \t") {
						lang = first;
						code = sub_from(code, nl + 1);
					}
				} }
				code = strings.trim_suffix(code, "\n");
				append(*blocks, Md_Block.{kind = .Code_Block, code = code, lang = lang});
				rest = sub_from(body, end + 3);
				if strings.has_prefix(rest, "\n") { rest = sub_from(rest, 1); }
				continue;
			} }
		}
		nl := strings.index_byte(rest, 10);
		line := ifx nl < 0 then rest else sub(rest, 0, nl);
		next := ifx nl < 0 then "" else sub_from(rest, nl + 1);
		if (strings.has_prefix(line, "> ")) || (line == ">") {
			flush(*blocks, *para, .Paragraph);
			append(*blocks, Md_Block.{kind = .Quote, tokens = md_inline(strings.trim_prefix(strings.trim_prefix(line, ">"), " "))});
		} else if strings.has_prefix(line, "### ") {
			flush(*blocks, *para, .Paragraph);
			append(*blocks, Md_Block.{kind = .Heading3, tokens = md_inline(sub_from(line, 4))});
		} else if strings.has_prefix(line, "## ") {
			flush(*blocks, *para, .Paragraph);
			append(*blocks, Md_Block.{kind = .Heading2, tokens = md_inline(sub_from(line, 3))});
		} else if strings.has_prefix(line, "# ") {
			flush(*blocks, *para, .Paragraph);
			append(*blocks, Md_Block.{kind = .Heading1, tokens = md_inline(sub_from(line, 2))});
		} else if strings.has_prefix(line, "-# ") {
			flush(*blocks, *para, .Paragraph);
			append(*blocks, Md_Block.{kind = .Subtext, tokens = md_inline(sub_from(line, 3))});
		} else if is_list_line(line) {
			flush(*blocks, *para, .Paragraph);
			indent := 0;
			while indent < len(line) && line[indent] == #char " " { indent += 1; }
			append(*blocks, Md_Block.{kind = .List_Item, tokens = md_inline(sub_from(line, indent + 2)), depth = indent / 2});
		} else {
			at := len(src) - len(rest);
			if para.hi <= para.lo { para.lo = at; }
			para.hi = at + len(line) + (ifx nl >= 0 then 1 else 0);
		}
		rest = next;
	}
	flush(*blocks, *para, .Paragraph);
	return view(blocks);
}
#scope_file

is_list_line :: (line: string) -> bool {
	l := strings.trim_left(line, " ");
	return strings.has_prefix(l, "- ") || strings.has_prefix(l, "* ");
}

Md_Parser :: struct {
	out: [..]Token;
	styles: Inline_Styles;
}
#scope_export

md_inline :: (src: string) -> []Token {
	p := Md_Parser.{out = make_dynamic(Token, 0, 0)};
	inline_into(*p, src);
	// merge adjacent plain text with identical styles
	merged := make_dynamic(Token, 0, len(p.out));
	for t: p.out {
		{ n := len(merged);
		if n > 0 && t.kind == .Text && merged[n - 1].kind == .Text && merged[n - 1].styles == t.styles {
			prev := *merged[n - 1];
			// tokens are slices of contiguous source only when adjacent; join otherwise
			if sub_from(raw_data(prev.text), len(prev.text)) == raw_data(t.text) {
				prev.text = as_string(sub(raw_data(prev.text), 0, len(prev.text) + len(t.text)));
			} else {
				prev.text = strings.concatenate(.{prev.text, t.text});
			}
			continue;
		} }
		append(*merged, t);
	}
	return view(merged);
}
#scope_file

emit :: (p: *Md_Parser, kind: Token_Kind, text: string) {
	if text == "" && kind == .Text { return; }
	append(*p.out, Token.{kind = kind, text = text, styles = p.styles});
}

// Delimited styles, checked longest-first like Discord's simple-markdown rules.
// Delimited styles, checked longest-first like Discord's simple-markdown rules.
DELIMS := struct {
	open: string;
	style: Inline_Style;
}.[.{"***", .Bold}, .{"**", .Bold}, .{"__", .Underline}, .{"~~", .Strike}, .{"||", .Spoiler}, .{"*", .Italic}, .{"_", .Italic}];

// Bytes that can start an inline rule in inline_into; every other byte is plain text.
// Bytes that can start an inline rule in inline_into; every other byte is plain text.
MD_SPECIAL := bool.[
	__IDX__92 = true,
	__IDX__#char "`" = true,
	__IDX__#char "<" = true,
	__IDX__#char "h" = true,
	__IDX__#char "@" = true,
	__IDX__#char "*" = true,
	__IDX__#char "_" = true,
	__IDX__#char "~" = true,
	__IDX__#char "|" = true
];

inline_into :: (p: *Md_Parser, src: string) {
	i := 0;
	text_start := 0;
	while i < len(src) {
		c := src[i];
		if !MD_SPECIAL[c] {
			i += 1;
			continue;
		}
		// escapes
		// a backslash escapes any ASCII punctuation (simple-markdown's escape rule)
		if c == 92 && i + 1 < len(src) && is_ascii_punct(src[i + 1]) {
			emit(p, .Text, sub(src, text_start, i));
			emit(p, .Text, sub(src, i + 1, i + 2));
			i += 2;
			text_start = i;
			continue;
		}
		// inline code: `x` or ``x``
		if c == #char "`" {
			ticks := 1;
			if strings.has_prefix(sub_from(src, i), "``") { ticks = 2; }
			delim := sub(src, i, i + ticks);
			{ end := strings.index(sub_from(src, i + ticks), delim);
			if end > 0 {
				emit(p, .Text, sub(src, text_start, i));
				saved := p.styles;
				p.styles += .{.Code_};
				body := sub(src, i + ticks, i + ticks + end);
				if ticks == 2 { body = strings.trim_space(body); }
				emit(p, .Text, body);
				p.styles = saved;
				i += ticks * 2 + end;
				text_start = i;
				continue;
			} }
		}
		// <...> entities
		if c == #char "<" {
			{ n, ok := try_entity(p, sub_from(src, i), sub(src, text_start, i));
			if ok {
				i += n;
				text_start = i;
				continue;
			} }
		}
		// bare links
		if c == #char "h" && (strings.has_prefix(sub_from(src, i), "https://") || strings.has_prefix(sub_from(src, i), "http://")) && (i == 0 || !is_alnum(src[i - 1])) {
			end := i;
			while end < len(src) && src[end] != #char " " && src[end] != 10 && src[end] != #char "<" { end += 1; }
			// trailing punctuation is not part of the URL
			while end > i && strings.contains_rune(".,:;!?)'\"", cast(u32)(src[end - 1])) { end -= 1; }
			emit(p, .Text, sub(src, text_start, i));
			emit(p, .Link, sub(src, i, end));
			i = end;
			text_start = i;
			continue;
		}
		// @everyone / @here
		if c == #char "@" && (strings.has_prefix(sub_from(src, i), "@everyone") || strings.has_prefix(sub_from(src, i), "@here")) {
			n := ifx strings.has_prefix(sub_from(src, i), "@everyone") then 9 else 5;
			emit(p, .Text, sub(src, text_start, i));
			emit(p, .Everyone, sub(src, i, i + n));
			i += n;
			text_start = i;
			continue;
		}
		// style delimiters
		matched := false;
		for d: DELIMS {
			if !strings.has_prefix(sub_from(src, i), d.open) { continue; }
			// underscores only work at word boundaries
			if d.open == "_" && i > 0 && is_alnum(src[i - 1]) { continue; }
			body_start := i + len(d.open);
			end := find_close(src, body_start, d.open);
			if end <= body_start { continue; }
			emit(p, .Text, sub(src, text_start, i));
			saved := p.styles;
			p.styles += .{d.style};
			if d.open == "***" { p.styles += .{.Italic}; }
			inline_into(p, sub(src, body_start, end));
			p.styles = saved;
			i = end + len(d.open);
			text_start = i;
			matched = true;
			break;
		}
		if matched { continue; }
		i += 1;
	}
	emit(p, .Text, sub_from(src, text_start));
}

find_close :: (src: string, from: int, delim: string) -> int {
	j := from;
	while j < len(src) {
		if src[j] == 92 {
			j += 2;
			continue;
		}
		if src[j] == #char "`" {
			// skip code spans
			{ end := strings.index_byte(sub_from(src, j + 1), #char "`");
			if end >= 0 {
				j += end + 2;
				continue;
			} }
		}
		if strings.has_prefix(sub_from(src, j), delim) {
			// "**" must not match the first half of "***" closing a bold+italic run
			if delim == "*" && j + 1 < len(src) && src[j + 1] == #char "*" {
				j += 2;
				continue;
			}
			if delim == "_" && j + 1 < len(src) && is_alnum(src[j + 1]) {
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
	end := strings.index_byte(s, #char ">");
	if end < 0 { return 0, false; }
	inner := sub(s, 1, end);
	n := end + 1;
	tok: Token;
	if strings.has_prefix(inner, "@&") {
		id, ok := strconv.parse_u64(sub_from(inner, 2));
		if !ok { return 0, false; }
		tok = .{kind = .Role_Mention, id = id, text = sub(s, 0, n)};
	} else if (strings.has_prefix(inner, "@!")) || (strings.has_prefix(inner, "@")) {
		digits := strings.trim_left(sub_from(inner, 1), "!");
		id, ok := strconv.parse_u64(digits);
		if !ok { return 0, false; }
		tok = .{kind = .User_Mention, id = id, text = sub(s, 0, n)};
	} else if strings.has_prefix(inner, "#") {
		id, ok := strconv.parse_u64(sub_from(inner, 1));
		if !ok { return 0, false; }
		tok = .{kind = .Channel_Mention, id = id, text = sub(s, 0, n)};
	} else if (strings.has_prefix(inner, ":")) || (strings.has_prefix(inner, "a:")) {
		animated := inner[0] == #char "a";
		body := ifx animated then sub_from(inner, 2) else sub_from(inner, 1);
		colon := strings.index_byte(body, #char ":");
		if colon <= 0 { return 0, false; }
		id, ok := strconv.parse_u64(sub_from(body, colon + 1));
		if !ok { return 0, false; }
		tok = .{kind = .Custom_Emoji, id = id, name = sub(body, 0, colon), animated = animated, text = sub(s, 0, n)};
	} else if strings.has_prefix(inner, "t:") {
		parts := strings.split(sub_from(inner, 2), ":");
		v, ok := strconv.parse_u64(parts[0]);
		if !ok { return 0, false; }
		tok = .{kind = .Timestamp, id = v, name = ifx len(parts) > 1 then parts[1] else "f", text = sub(s, 0, n)};
	} else if (strings.has_prefix(inner, "https://")) || (strings.has_prefix(inner, "http://")) {
		// <url> suppresses embeds but still links
		tok = .{kind = .Link, text = inner};
	} else {
		return 0, false;
	}
	emit(p, .Text, pending);
	tok.styles = p.styles;
	append(*p.out, tok);
	return n, true;
}

is_ascii_punct :: (c: u8) -> bool {
	return (c >= #char "!" && c <= #char "/") || (c >= #char ":" && c <= #char "@") || (c >= #char "[" && c <= #char "`") || (c >= #char "{" && c <= #char "~");
}
#scope_export

