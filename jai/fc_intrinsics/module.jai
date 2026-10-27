cpu_relax :: inline () { #if CPU == .X64 { #asm { pause; } } }
