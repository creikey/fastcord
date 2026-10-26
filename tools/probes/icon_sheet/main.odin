// icon_sheet: rasterizes every assets/icons/*.svg with fc:vector into a contact
// sheet PNG (black on white, 48px = 24px@2x per icon, alphabetical, row-major).
//   odin run tools/probes/icon_sheet -collection:fc=src -- [out.png] [px] [filter]
package icon_sheet

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "fc:vector"

main :: proc() {
	out_path := len(os.args) > 1 ? os.args[1] : "build/icon_sheet.png"
	px := 48
	if len(os.args) > 2 do px, _ = strconv.parse_int(os.args[2])
	filter := len(os.args) > 3 ? os.args[3] : ""
	dir := "assets/icons"
	fd, err := os.open(dir)
	if err != nil {
		fmt.eprintln("open", dir, err)
		os.exit(1)
	}
	infos, _ := os.read_dir(fd, -1, context.allocator)
	names: [dynamic]string
	for fi in infos {
		if strings.has_suffix(fi.name, ".svg") && strings.contains(fi.name, filter) do append(&names, fi.name)
	}
	slice.sort(names[:])
	cols := 24
	pad := px / 6
	cell := px + pad
	rows := (len(names) + cols - 1) / cols
	W := cols * cell + pad
	H := rows * cell + pad
	sheet := make([]u8, W * H)
	slice.fill(sheet, 255)
	failed := 0
	for name, i in names {
		data, rerr := os.read_entire_file(strings.concatenate({dir, "/", name}), context.allocator)
		if rerr != nil do continue
		icon, ok := vector.parse_svg(string(data))
		if !ok {
			fmt.eprintln("parse failed:", name)
			failed += 1
			continue
		}
		cov := vector.rasterize(&icon, px, px)
		total := 0
		for c in cov do total += int(c)
		if total < px * px * 255 / 50 do fmt.eprintfln("nearly empty: %s (%.1f%%)", name, f64(total) / f64(px * px * 255) * 100)
		ox := pad + (i % cols) * cell
		oy := pad + (i / cols) * cell
		for y in 0 ..< px do for x in 0 ..< px do sheet[(oy + y) * W + ox + x] = 255 - cov[y * px + x]
		vector.destroy(&icon)
		delete(cov)
	}
	png := encode_png_gray(sheet, W, H)
	if werr := os.write_entire_file(out_path, png); werr != nil {
		fmt.eprintln("write", out_path, werr)
		os.exit(1)
	}
	fmt.printfln("%d icons (%d failed), %dx%d grid of %d -> %s", len(names), failed, cols, rows, px, out_path)
	for name, i in names do if i % cols == 0 do fmt.printfln("row %d: %s", i / cols, name)
}
