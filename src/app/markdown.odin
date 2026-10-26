package app

import "core:strconv"
import "core:strings"

// Discord-flavoured markdown, parsed into blocks of inline tokens. Rendering
// (fonts, colors) happens in the chat view; this file is pure and tested.

Block_Kind :: enum u8 {
	Paragraph,
	Code_Block,
	Quote,
	Heading1,
	Heading2,
	Heading3,
	Subtext, // "-# "
	List_Item,
}

Inline_Style :: enum u8 {
	Bold,
	Italic,
	Underline,
	Strike,
	Code,
	Spoiler,
}
Inline_Styles :: bit_set[Inline_Style;u8]

Token_Kind :: enum u8 {
	Text,
	Link, // url = text
	User_Mention, // id
	Role_Mention,
	Channel_Mention,
	Everyone, // @everyone / @here
	Custom_Emoji, // name, id, animated
	Timestamp, // id = unix seconds, name = format letter
}

Token :: struct {
	kind:     Token_Kind,
	text:     string, // display text (slice of source or literal)
	styles:   Inline_Styles,
	id:       u64,
	name:     string,
	animated: bool,
}

Md_Block :: struct {
	kind:   Block_Kind,
	tokens: []Token,
	lang:   string, // code block language
	code:   string, // code block body
	depth:  int, // list nesting
}

md_parse :: proc(src: string, allocator := context.temp_allocator) -> []Md_Block {
	context.allocator = allocator
	blocks := make([dynamic]Md_Block, 0, 4)
	// Paragraph lines are always consecutive in src (any other line flushes first), so a paragraph
	// is the slice src[para_lo:para_hi] and needs no copy.
	Para :: struct {
		src:    string,
		lo, hi: int,
	}
	para := Para{src = src}
	flush :: proc(blocks: ^[dynamic]Md_Block, para: ^Para, kind: Block_Kind, depth := 0) {
		if para.hi <= para.lo do return
		// a trailing newline belongs to the block separator, not the paragraph
		txt := strings.trim_right(para.src[para.lo:para.hi], "\n")
		append(blocks, Md_Block{kind = kind, tokens = md_inline(txt), depth = depth})
		para.lo, para.hi = 0, 0
	}
	rest := src
	for len(rest) > 0 {
		// fenced code block
		if strings.has_prefix(rest, "```") {
			body := rest[3:]
			if end := strings.index(body, "```"); end >= 0 {
				flush(&blocks, &para, .Paragraph)
				code := body[:end]
				lang := ""
				if nl := strings.index_byte(code, '\n'); nl >= 0 {
					first := code[:nl]
					if len(first) > 0 && !strings.contains_any(first, " \t") {
						lang = first
						code = code[nl + 1:]
					}
				}
				code = strings.trim_suffix(code, "\n")
				append(&blocks, Md_Block{kind = .Code_Block, code = code, lang = lang})
				rest = body[end + 3:]
				if strings.has_prefix(rest, "\n") do rest = rest[1:]
				continue
			}
		}
		nl := strings.index_byte(rest, '\n')
		line := nl < 0 ? rest : rest[:nl]
		next := nl < 0 ? "" : rest[nl + 1:]
		switch {
		case strings.has_prefix(line, "> "), line == ">":
			flush(&blocks, &para, .Paragraph)
			append(&blocks, Md_Block{kind = .Quote, tokens = md_inline(strings.trim_prefix(strings.trim_prefix(line, ">"), " "))})
		case strings.has_prefix(line, "### "):
			flush(&blocks, &para, .Paragraph)
			append(&blocks, Md_Block{kind = .Heading3, tokens = md_inline(line[4:])})
		case strings.has_prefix(line, "## "):
			flush(&blocks, &para, .Paragraph)
			append(&blocks, Md_Block{kind = .Heading2, tokens = md_inline(line[3:])})
		case strings.has_prefix(line, "# "):
			flush(&blocks, &para, .Paragraph)
			append(&blocks, Md_Block{kind = .Heading1, tokens = md_inline(line[2:])})
		case strings.has_prefix(line, "-# "):
			flush(&blocks, &para, .Paragraph)
			append(&blocks, Md_Block{kind = .Subtext, tokens = md_inline(line[3:])})
		case is_list_line(line):
			flush(&blocks, &para, .Paragraph)
			indent := 0
			for indent < len(line) && line[indent] == ' ' do indent += 1
			append(&blocks, Md_Block{kind = .List_Item, tokens = md_inline(line[indent + 2:]), depth = indent / 2})
		case:
			at := len(src) - len(rest)
			if para.hi <= para.lo do para.lo = at
			para.hi = at + len(line) + (nl >= 0 ? 1 : 0)
		}
		rest = next
	}
	flush(&blocks, &para, .Paragraph)
	return blocks[:]
}

@(private = "file")
is_list_line :: proc(line: string) -> bool {
	l := strings.trim_left(line, " ")
	return strings.has_prefix(l, "- ") || strings.has_prefix(l, "* ")
}

@(private = "file")
Md_Parser :: struct {
	out:    [dynamic]Token,
	styles: Inline_Styles,
}

md_inline :: proc(src: string) -> []Token {
	p := Md_Parser{out = make([dynamic]Token)}
	inline_into(&p, src)
	// merge adjacent plain text with identical styles
	merged := make([dynamic]Token, 0, len(p.out))
	for t in p.out {
		if n := len(merged); n > 0 && t.kind == .Text && merged[n - 1].kind == .Text && merged[n - 1].styles == t.styles {
			prev := &merged[n - 1]
			// tokens are slices of contiguous source only when adjacent; join otherwise
			if raw_data(prev.text)[len(prev.text):] == raw_data(t.text) {
				prev.text = string(raw_data(prev.text)[:len(prev.text) + len(t.text)])
			} else {
				prev.text = strings.concatenate({prev.text, t.text})
			}
			continue
		}
		append(&merged, t)
	}
	return merged[:]
}

@(private = "file")
emit :: proc(p: ^Md_Parser, kind: Token_Kind, text: string) {
	if text == "" && kind == .Text do return
	append(&p.out, Token{kind = kind, text = text, styles = p.styles})
}

// Delimited styles, checked longest-first like Discord's simple-markdown rules.
@(private = "file")
DELIMS := [?]struct {
	open:  string,
	style: Inline_Style,
}{{"***", .Bold}, {"**", .Bold}, {"__", .Underline}, {"~~", .Strike}, {"||", .Spoiler}, {"*", .Italic}, {"_", .Italic}}

// Bytes that can start an inline rule in inline_into; every other byte is plain text.
@(private = "file")
MD_SPECIAL := [256]bool {
	'\\' = true,
	'`'  = true,
	'<'  = true,
	'h'  = true,
	'@'  = true,
	'*'  = true,
	'_'  = true,
	'~'  = true,
	'|'  = true,
}

@(private = "file")
inline_into :: proc(p: ^Md_Parser, src: string) {
	i := 0
	text_start := 0
	for i < len(src) {
		c := src[i]
		if !MD_SPECIAL[c] {
			i += 1
			continue
		}
		// escapes
		// a backslash escapes any ASCII punctuation (simple-markdown's escape rule)
		if c == '\\' && i + 1 < len(src) && is_ascii_punct(src[i + 1]) {
			emit(p, .Text, src[text_start:i])
			emit(p, .Text, src[i + 1:i + 2])
			i += 2
			text_start = i
			continue
		}
		// inline code: `x` or ``x``
		if c == '`' {
			ticks := 1
			if strings.has_prefix(src[i:], "``") do ticks = 2
			delim := src[i:i + ticks]
			if end := strings.index(src[i + ticks:], delim); end > 0 {
				emit(p, .Text, src[text_start:i])
				saved := p.styles
				p.styles += {.Code}
				body := src[i + ticks:i + ticks + end]
				if ticks == 2 do body = strings.trim_space(body)
				emit(p, .Text, body)
				p.styles = saved
				i += ticks * 2 + end
				text_start = i
				continue
			}
		}
		// <...> entities
		if c == '<' {
			if n, ok := try_entity(p, src[i:], src[text_start:i]); ok {
				i += n
				text_start = i
				continue
			}
		}
		// bare links
		if c == 'h' && (strings.has_prefix(src[i:], "https://") || strings.has_prefix(src[i:], "http://")) && (i == 0 || !is_alnum(src[i - 1])) {
			end := i
			for end < len(src) && src[end] != ' ' && src[end] != '\n' && src[end] != '<' do end += 1
			// trailing punctuation is not part of the URL
			for end > i && strings.contains_rune(".,:;!?)'\"", rune(src[end - 1])) do end -= 1
			emit(p, .Text, src[text_start:i])
			emit(p, .Link, src[i:end])
			i = end
			text_start = i
			continue
		}
		// @everyone / @here
		if c == '@' && (strings.has_prefix(src[i:], "@everyone") || strings.has_prefix(src[i:], "@here")) {
			n := strings.has_prefix(src[i:], "@everyone") ? 9 : 5
			emit(p, .Text, src[text_start:i])
			emit(p, .Everyone, src[i:i + n])
			i += n
			text_start = i
			continue
		}
		// style delimiters
		matched := false
		for d in DELIMS {
			if !strings.has_prefix(src[i:], d.open) do continue
			// underscores only work at word boundaries
			if d.open == "_" && i > 0 && is_alnum(src[i - 1]) do continue
			body_start := i + len(d.open)
			end := find_close(src, body_start, d.open)
			if end <= body_start do continue
			emit(p, .Text, src[text_start:i])
			saved := p.styles
			p.styles += {d.style}
			if d.open == "***" do p.styles += {.Italic}
			inline_into(p, src[body_start:end])
			p.styles = saved
			i = end + len(d.open)
			text_start = i
			matched = true
			break
		}
		if matched do continue
		i += 1
	}
	emit(p, .Text, src[text_start:])
}

@(private = "file")
find_close :: proc(src: string, from: int, delim: string) -> int {
	j := from
	for j < len(src) {
		if src[j] == '\\' {
			j += 2
			continue
		}
		if src[j] == '`' {
			// skip code spans
			if end := strings.index_byte(src[j + 1:], '`'); end >= 0 {
				j += end + 2
				continue
			}
		}
		if strings.has_prefix(src[j:], delim) {
			// "**" must not match the first half of "***" closing a bold+italic run
			if delim == "*" && j + 1 < len(src) && src[j + 1] == '*' {
				j += 2
				continue
			}
			if delim == "_" && j + 1 < len(src) && is_alnum(src[j + 1]) {
				j += 1
				continue
			}
			return j
		}
		j += 1
	}
	return -1
}

@(private = "file")
is_alnum :: proc(c: byte) -> bool {
	return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')
}

@(private = "file")
try_entity :: proc(p: ^Md_Parser, s: string, pending: string) -> (int, bool) {
	end := strings.index_byte(s, '>')
	if end < 0 do return 0, false
	inner := s[1:end]
	n := end + 1
	tok: Token
	switch {
	case strings.has_prefix(inner, "@&"):
		id, ok := strconv.parse_u64(inner[2:])
		if !ok do return 0, false
		tok = {kind = .Role_Mention, id = id, text = s[:n]}
	case strings.has_prefix(inner, "@!"), strings.has_prefix(inner, "@"):
		digits := strings.trim_left(inner[1:], "!")
		id, ok := strconv.parse_u64(digits)
		if !ok do return 0, false
		tok = {kind = .User_Mention, id = id, text = s[:n]}
	case strings.has_prefix(inner, "#"):
		id, ok := strconv.parse_u64(inner[1:])
		if !ok do return 0, false
		tok = {kind = .Channel_Mention, id = id, text = s[:n]}
	case strings.has_prefix(inner, ":"), strings.has_prefix(inner, "a:"):
		animated := inner[0] == 'a'
		body := animated ? inner[2:] : inner[1:]
		colon := strings.index_byte(body, ':')
		if colon <= 0 do return 0, false
		id, ok := strconv.parse_u64(body[colon + 1:])
		if !ok do return 0, false
		tok = {kind = .Custom_Emoji, id = id, name = body[:colon], animated = animated, text = s[:n]}
	case strings.has_prefix(inner, "t:"):
		parts := strings.split(inner[2:], ":")
		v, ok := strconv.parse_u64(parts[0])
		if !ok do return 0, false
		tok = {kind = .Timestamp, id = v, name = len(parts) > 1 ? parts[1] : "f", text = s[:n]}
	case strings.has_prefix(inner, "https://"), strings.has_prefix(inner, "http://"):
		// <url> suppresses embeds but still links
		tok = {kind = .Link, text = inner}
	case:
		return 0, false
	}
	emit(p, .Text, pending)
	tok.styles = p.styles
	append(&p.out, tok)
	return n, true
}

@(private = "file")
is_ascii_punct :: proc(c: byte) -> bool {
	return (c >= '!' && c <= '/') || (c >= ':' && c <= '@') || (c >= '[' && c <= '`') || (c >= '{' && c <= '~')
}
