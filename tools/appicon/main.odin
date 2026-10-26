// appicon: renders assets/app/icon.svg into the PNG sizes an .icns needs.
//   odin run tools/appicon -collection:fc=src -- <out.iconset dir>
package appicon

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "fc:gfx"
import "fc:vector"

main :: proc() {
	if len(os.args) < 2 {
		fmt.eprintln("usage: appicon <out.iconset>")
		os.exit(2)
	}
	out := os.args[1]
	os.make_directory(out)
	src, err := os.read_entire_file("assets/app/icon.svg", context.allocator)
	if err != nil {
		fmt.eprintln("cannot read assets/app/icon.svg")
		os.exit(1)
	}
	icon, ok := vector.parse_svg(string(src))
	if !ok {
		fmt.eprintln("bad svg")
		os.exit(1)
	}
	sizes := [?]struct {
		px:   int,
		name: string,
	}{{16, "icon_16x16"}, {32, "icon_16x16@2x"}, {32, "icon_32x32"}, {64, "icon_32x32@2x"}, {128, "icon_128x128"}, {256, "icon_128x128@2x"}, {256, "icon_256x256"}, {512, "icon_256x256@2x"}, {512, "icon_512x512"}, {1024, "icon_512x512@2x"}}
	for s in sizes {
		rgba := vector.rasterize_rgba(&icon, s.px, s.px)
		path, _ := filepath.join({out, fmt.tprintf("%s.png", s.name)})
		if !gfx.write_png(path, rgba, s.px, s.px) {
			fmt.eprintln("write failed", path)
			os.exit(1)
		}
	}
}
