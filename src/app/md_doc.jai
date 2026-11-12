// The pretty view of a markdown file (a .md attachment's "Pretty" tab): GitHub-flavoured markdown on top of
// md_parse. md_parse covers headings, lists, quotes, code and inline styles; this adds tables, horizontal
// rules and the h4-h6 headings (drawn as h3), and lays the blocks out as a document. Everything it builds
// lives in the temp allocator, one frame.

Doc_Seg_Kind :: enum u8 { Text; Table; Rule; }

Doc_Seg :: struct {
	kind: Doc_Seg_Kind;
	text: string; // .Text: markdown for md_parse
	head: []string; // .Table
	align: []ui.Text_Align;
	rows: [][]string;
}

doc_msg: dc.Message; // tokens_to_spans wants a message for mention lookups: an empty one resolves nothing
doc_sub: u32; // selection order of the document's boxes

// One table line's cells: the outer pipes dropped, "\|" kept as a pipe, each trimmed.
doc_cells :: (line: string) -> []string {
	cells: [..]string;
	cells.allocator = temp;
	t := trim(line);
	if begins_with(t, "|") t = slice(t, 1, t.count - 1);
	start := 0;
	i := 0;
	while i <= t.count {
		if i == t.count || (t[i] == #char "|" && (i == 0 || t[i - 1] != #char "\\")) {
			if i < t.count || start < t.count array_add(*cells, replace(trim(slice(t, start, i - start)), "\\|", "|"));
			start = i + 1;
		}
		i += 1;
	}
	return cells;
}

// "---", ":--", "--:" or ":-:" in every one of n cells.
doc_is_delim :: (line: string, n: int) -> bool {
	if find_index_from_left(line, #char "-") < 0 return false;
	cells := doc_cells(line);
	if cells.count != n return false;
	for cells {
		c := it;
		if begins_with(c, ":") c = slice(c, 1, c.count - 1);
		if ends_with(c, ":") c = slice(c, 0, c.count - 1);
		if !c return false;
		for cast([]u8) c if it != #char "-" return false;
	}
	return true;
}

doc_is_rule :: (t: string) -> bool {
	if t.count < 3 return false;
	ch := t[0];
	if ch != #char "-" && ch != #char "*" && ch != #char "_" return false;
	n := 0;
	for cast([]u8) t {
		if it == ch n += 1;
		else if it != #char " " return false;
	}
	return n >= 3;
}

doc_segments :: (src: string) -> []Doc_Seg {
	segs: [..]Doc_Seg;
	segs.allocator = temp;
	pending: [..]string;
	pending.allocator = temp;
	flush :: (segs: *[..]Doc_Seg, pending: *[..]string) {
		if pending.count {
			text := join(..pending.*, separator = "\n",, temp);
			if trim(text) array_add(segs, .{kind = .Text, text = text});
			pending.count = 0;
		}
	}
	lines := split(src, "\n",, temp);
	fence := false;
	i := 0;
	while i < lines.count {
		line := trim_right(lines[i], "\r");
		t := trim(line);
		if begins_with(t, "```") || begins_with(t, "~~~") {
			fence = !fence;
			array_add(*pending, line);
			i += 1;
			continue;
		}
		if fence {
			array_add(*pending, line);
			i += 1;
			continue;
		}
		if find_index_from_left(line, #char "|") >= 0 && i + 1 < lines.count {
			head := doc_cells(line);
			if head.count > 0 && doc_is_delim(lines[i + 1], head.count) {
				flush(*segs, *pending);
				seg := Doc_Seg.{kind = .Table, head = head};
				align := NewArray(head.count, ui.Text_Align,, temp);
				for doc_cells(lines[i + 1]) {
					if begins_with(it, ":") && ends_with(it, ":") align[it_index] = .Center;
					else if ends_with(it, ":") align[it_index] = .Right;
				}
				seg.align = align;
				rows: [..][]string;
				rows.allocator = temp;
				i += 2;
				while i < lines.count && trim(lines[i]) && find_index_from_left(lines[i], #char "|") >= 0 {
					array_add(*rows, doc_cells(lines[i]));
					i += 1;
				}
				seg.rows = rows;
				array_add(*segs, seg);
				continue;
			}
		}
		if doc_is_rule(t) {
			flush(*segs, *pending);
			array_add(*segs, .{kind = .Rule});
			i += 1;
			continue;
		}
		if begins_with(t, "####") {
			hashes := 0;
			while hashes < t.count && t[hashes] == #char "#" hashes += 1;
			if hashes <= 6 && hashes < t.count && t[hashes] == #char " " line = tprint("### %", slice(t, hashes + 1, t.count - hashes - 1));
		}
		array_add(*pending, line);
		i += 1;
	}
	flush(*segs, *pending);
	return segs;
}

doc_tokens :: (text: string) -> []Token {
	out: [..]Token;
	out.allocator = temp;
	for blk: md_cached(text) for t: blk.tokens array_add(*out, t);
	return out;
}

// The file as a column of blocks in width w.
doc_view :: (id: string, src: string, w: float32) {
	doc_sub = 0;
	for seg, si: doc_segments(src) {
		if si > 0 spacer(.Y, 8);
		sid := tprint("%s%", id, si);
		if seg.kind == {
		case .Rule;
			r := ui.box(tprint("%r", sid), .Draw_Background);
			r.semantic_size = .[ui.pct(1), ui.px(1)];
			r.style.bg = T("--border-strong");
		case .Text;
			doc_text(sid, seg.text);
		case .Table;
			doc_table(sid, seg, w);
		}
	}
}

doc_text :: (id: string, text: string) {
	first := true;
	for blk, bi: md_cached(text) {
		if blk.kind != .Code_Block && !blk.tokens.count continue; // a blank line
		if !first spacer(.Y, 4);
		first = false;
		bid := tprint("%b%", id, bi);
		if blk.kind == .Code_Block {
			cb := ui.box(tprint("%c", bid), .Draw_Background | .Draw_Border | .Draw_Text | .Selectable_Text | .Wrap_Text);
			ui.set_spans(cb, code_spans(blk.code, blk.lang, F(.Mono), 13));
			cb.semantic_size = .[ui.pct(1), ui.text_size()];
			cb.style.bg = T("--background-mod-subtle");
			cb.style.border_color = T("--border-subtle");
			cb.style.border = 1;
			cb.style.radius = all4(4);
			cb.style.font = F(.Mono);
			cb.style.font_size = 13;
			cb.style.line_height = 18;
			cb.style.padding = .{8, 8};
			cb.style.text_color = T("--text-code");
			doc_sub += 1;
			cb.sel_order = 0xd0c0000 + doc_sub;
			cb.sel_sub = doc_sub;
			continue;
		}
		size: float32 = 14;
		font := Font_Id.Normal;
		line_h: float32 = 20;
		color := T("--text-default");
		if blk.kind == {
		case .Heading1; size, font, line_h = 22, Font_Id.Bold, 30;
		case .Heading2; size, font, line_h = 19, Font_Id.Bold, 26;
		case .Heading3; size, font, line_h = 16, Font_Id.Bold, 22;
		case .Subtext;  size, line_h, color = 12, 16, T("--text-muted");
		}
		wrap := row(tprint("%w", bid));
		wrap.semantic_size = .[ui.pct(1), ui.children()];
		wrap.cross_align = .Start;
		ui.parent(wrap); defer ui.pop_parent();
		if blk.quoted {
			wrap.custom_draw = quote_bar_draw;
			spacer(.X, 12);
		}
		if blk.kind == .List_Item {
			spacer(.X, 4 + cast(float32) blk.depth * 18);
			marker := ifx blk.number then tprint("%.", blk.number) else ifx blk.depth == 0 then "•" else "◦";
			label(marker, .Normal, size, color, line_h);
			spacer(.X, 8);
		}
		b := ui.box(tprint("%p", bid), .Selectable_Text | .Wrap_Text);
		b.semantic_size = .[ui.fill(), ui.text_size()];
		b.style.text_color = color;
		b.style.line_height = line_h;
		doc_sub += 1;
		b.sel_order = 0xd0c0000 + doc_sub;
		b.sel_sub = doc_sub;
		ui.set_spans(b, tokens_to_spans(blk.tokens, font, size, *doc_msg));
		handle_span_clicks(b, blk.tokens);
	}
}

// Columns sized by their longest cell (clamped), rows banded and ruled, the header bold.
doc_table :: (id: string, seg: Doc_Seg, w: float32) {
	n := seg.head.count;
	weights := NewArray(n, float32,, temp);
	for 0..n - 1 weights[it] = 4;
	measure :: (weights: []float32, cells: []string) {
		for cells if it_index < weights.count weights[it_index] = max(weights[it_index], min(cast(float32) it.count, 40));
	}
	measure(weights, seg.head);
	for seg.rows measure(weights, it);
	total: float32;
	for weights total += it;
	for -1..seg.rows.count - 1 {
		cells := ifx it < 0 then seg.head else seg.rows[it];
		rid := tprint("%r%", id, it);
		r := row(rid, .Draw_Background);
		r.semantic_size = .[ui.px(w), ui.children()];
		r.cross_align = .Start;
		r.style.bg = ifx it < 0 then T("--background-mod-strong") else ifx it % 2 == 1 then T("--background-mod-subtle") else T("--background-base-lowest");
		{ ui.parent(r); defer ui.pop_parent();
			for 0..n - 1 {
				text := ifx it < cells.count then cells[it] else "";
				toks := doc_tokens(text);
				cell := ui.box(tprint("%c%", rid, it), .Selectable_Text | .Wrap_Text);
				cell.semantic_size = .[ui.px(floor(w * weights[it] / total)), ui.text_size()];
				cell.style.padding = .{8, 5};
				cell.style.line_height = 20;
				cell.style.text_color = T("--text-default");
				cell.style.text_align = seg.align[it];
				doc_sub += 1;
				cell.sel_order = 0xd0c0000 + doc_sub;
				cell.sel_sub = doc_sub;
				ui.set_spans(cell, tokens_to_spans(toks, ifx cells.data == seg.head.data then Font_Id.Bold else Font_Id.Normal, 14, *doc_msg));
				handle_span_clicks(cell, toks);
			}
		}
		line := ui.box(tprint("%l", rid), .Draw_Background);
		line.semantic_size = .[ui.px(w), ui.px(1)];
		line.style.bg = T("--border-subtle");
	}
}
