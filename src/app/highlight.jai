// Syntax highlighting for ```lang code blocks. The official client parses them with
// tree-sitter grammars (arborium) and colours the capture classes with --text-code-* tokens;
// this is a small table-driven lexer per language (words, comments, strings, numbers) giving
// the same colour classes. Languages and aliases are the client's (traffic/CLIENT_RULES.md);
// any other language is plain text, as there.

// Spans for a code block body, in font/size; plain text when lang isn't highlighted.
code_spans :: (code: string, lang: string, font: ui.Font, size: float32) -> []ui.Span {
	spans: [..]ui.Span;
	spans.allocator = temp;
	o: Hl_Out;
	hl_begin(*o, code, *spans, .{font = font, size = size});
	hl_range(*o, hl_lang(lang), 0, code.count);
	return spans;
}

HL_NONE :: -1;
HL_ANSI :: -2;

// The client's language for a code block tag: lower-cased, [a-z0-9_+\-.#]+, a grammar name,
// "ansi", or an alias of a grammar. HL_NONE otherwise.
hl_lang :: (name: string) -> int {
	if !name || name.count > 32 || !is_lang_name(name) return HL_NONE;
	buf: [32]u8;
	for cast([]u8) name buf[it_index] = to_lower(it);
	l := string.{name.count, buf.data};
	if l == "ansi" return HL_ANSI;
	for i: 0..HL_ALIASES.count / 2 - 1 if HL_ALIASES[i * 2] == l { l = HL_ALIASES[i * 2 + 1]; break; }
	for LANGS if it.name == l return it_index;
	return HL_NONE;
}

Hl_Out :: struct {
	src: string;
	spans: *[..]ui.Span;
	proto: ui.Span;
	colors: [#run enum_highest_value(Hl) + 1]ui.Color;
	last := -1; // index of the span put() may extend
	last_kind: Hl;
	keep_escapes: bool; // ANSI: keep the control sequences as visible text (the composer)
}

hl_begin :: (o: *Hl_Out, src: string, spans: *[..]ui.Span, proto: ui.Span) {
	o.src = src;
	o.spans = spans;
	o.proto = proto;
	for HL_TOKENS if it o.colors[it_index] = T(it);
}

// Highlights src[lo:hi] as language li (an index into LANGS, HL_ANSI or HL_NONE).
hl_range :: (o: *Hl_Out, li: int, lo: int, hi: int) {
	// the client skips highlighting when any line is over 1000 characters
	n := 0;
	for i: lo..hi - 1 {
		n = ifx o.src[i] == #char "\n" then 0 else n + 1;
		if n > 1000 { li = HL_NONE; break; }
	}
	if li == HL_ANSI { hl_ansi(o, lo, hi); return; }
	if li < 0 { put(o, .Plain, lo, hi); return; }
	if LANGS[li].mode == {
	case .Code;     hl_code(o, li, lo, hi);
	case .Markup;   hl_markup(o, li, lo, hi);
	case .Css;      hl_css(o, li, lo, hi);
	case .Markdown; hl_doc(o, li, lo, hi);
	case .Diff;     hl_diff(o, lo, hi);
	}
}

#scope_file

// Colour classes of the client's code CSS: arborium's capture elements (a-k keyword, a-s string,
// a-c comment, a-n / a-cn number and constants, a-f / a-t / a-pr / a-tg title, a-fb / a-vb
// builtin, a-o operator, a-at attribute, a-m / a-ns namespace, a-se escape, a-rx regexp),
// and in diffs a-s / a-k as added / removed lines.
Hl :: enum u8 {
	Plain;
	Keyword;
	String;
	Comment;
	Number;
	Title;
	Builtin;
	Operator;
	Attr;
	Namespace;
	Escape;
	Regex;
	Addition;
	Deletion;
}

// --text-code-decorator (a-at) isn't in the resolved theme; it uses the same palette steps
// as --text-code-builtin in every theme.
HL_TOKENS :: string.["", "--text-code-keyword", "--text-code-string", "--text-code-comment", "--text-code-number",
	"--text-code-title", "--text-code-builtin", "--text-code-operator", "--text-code-builtin", "--text-code-namespace",
	"--text-code-escape", "--text-code-regexp", "--text-code-addition", "--text-code-deletion"];

put :: (o: *Hl_Out, kind: Hl, lo: int, hi: int) {
	if hi <= lo return;
	if o.last >= 0 && o.last == o.spans.count - 1 {
		sp := *(o.spans.*)[o.last];
		if o.last_kind == kind && kind != .Addition && kind != .Deletion && sp.text.data + sp.text.count == o.src.data + lo {
			sp.text.count += hi - lo;
			return;
		}
	}
	sp := o.proto;
	sp.text = .{hi - lo, o.src.data + lo};
	sp.color = o.colors[kind];
	if kind == .Addition sp.bg = T("--background-code-addition");
	if kind == .Deletion sp.bg = T("--background-code-deletion");
	if kind == .Addition || kind == .Deletion sp.bg_radius = 0;
	array_add(o.spans, sp);
	o.last = o.spans.count - 1;
	o.last_kind = kind;
}

Lang_Mode :: enum u8 { Code; Markup; Css; Markdown; Diff; }

Lang_Flags :: enum_flags u32 {
	No_Case;     // case-insensitive words
	Triple;      // """ / ''' strings
	Preproc;     // # directives at a line start
	Decorators;  // @name
	Caps_Types;  // Capitalised names are types
	Calls;       // name( is a function
	Command;     // shells: the first word of a command is a function
	Char_Quote;  // ' only quotes a one-character literal (else a prime, lifetime or tick)
	Lifetimes;   // 'a is a label
	Macros;      // name! is a macro
	Hash_Attr;   // #[...] attributes
	Lisp;        // s-expressions: the head of a list is a function, :key a constant
	Keys_Colon;  // key: at a line start is a property
	Keys_Equals; // key = at a line start is a property
	Sections;    // [section] at a line start
	Atoms;       // :atom symbols
	Regex;       // /.../ literals
	Bol_Comment; // line comments only at a line start
	Dash_Words;  // words may contain '-'
	No_Ops;
	Template;    // markup with {% %} / {{ }} / {# #}
}

Lang :: struct {
	name: string;
	mode: Lang_Mode;
	flags: Lang_Flags;
	lc: string; // line comment starters, space separated
	bc: string; // block comment "open close"
	quotes: string;
	base: string; // a language whose words this one has too
	kw: string;
	types: string;
	builtins: string;
	literals: string;
}

C_FAMILY :: Lang_Flags.Calls | .Caps_Types;

// The client's grammars (arborium's grammar table), one entry each.
LANGS := Lang.[
	.{name = "ada", flags = .No_Case, lc = "--", quotes = "\"",
		kw = "abort abs abstract accept access aliased all and array at begin body case constant declare delay delta digits do else elsif end entry exception exit for function generic goto if in interface is limited loop mod new not null of or others out overriding package pragma private procedure protected raise range record rem renames requeue return reverse select separate some subtype synchronized tagged task terminate then type until use when while with xor",
		types = "integer natural positive float boolean character string duration", literals = "true false"},
	.{name = "agda", flags = .Caps_Types | .Char_Quote, lc = "--", bc = "{- -}", quotes = "\"'",
		kw = "abstract codata coinductive constructor data do eta-equality field forall hiding import in inductive infix infixl infixr instance let macro module mutual open overlap pattern postulate primitive private public quote record renaming rewrite syntax tactic to unquote using variable where with"},
	.{name = "asciidoc", mode = .Markdown, lc = "//"},
	.{name = "asm", flags = .No_Case, lc = "; # //", quotes = "\"'",
		kw = "mov movzx movsx lea push pop call ret jmp je jne jz jnz jg jge jl jle ja jae jb jbe cmp test add sub mul imul div idiv inc dec neg and or xor not shl shr sar rol ror nop int syscall leave enter ldr str ldp stp b bl bx blr br cbz cbnz adr adrp li la lw sw lb sb beq bne addi jal jr",
		builtins = "rax rbx rcx rdx rsi rdi rbp rsp r8 r9 r10 r11 r12 r13 r14 r15 eax ebx ecx edx esi edi ebp esp ax bx cx dx al bl cl dl ah bh ch dh sp fp lr pc x0 x1 x2 x3 x8 x29 x30 w0 w1 r0 r1 r2 r3 zero ra a0 a1 t0 t1 s0"},
	.{name = "awk", flags = .Calls, lc = "#", quotes = "\"",
		kw = "BEGIN END if else while for do break continue function func return next nextfile exit delete in getline print printf",
		builtins = "length substr index split sub gsub match sprintf tolower toupper int sqrt exp log sin cos atan2 rand srand system close fflush NR NF FS OFS RS ORS FILENAME FNR"},
	.{name = "bash", flags = .Command | .No_Ops, lc = "#", quotes = "\"'`",
		kw = "if then else elif fi case esac for select while until do done in function time coproc return break continue local export readonly declare typeset unset shift exit"},
	.{name = "batch", flags = .No_Case | .Bol_Comment, lc = "rem :: @rem", quotes = "\"",
		kw = "if else for in do goto call set echo exit not exist defined errorlevel setlocal endlocal shift pause cls start cd pushd popd equ neq lss leq gtr geq"},
	.{name = "c", flags = C_FAMILY | .Preproc, lc = "//", bc = "/* */", quotes = "\"'",
		kw = "auto break case const continue default do else enum extern for goto if inline register restrict return sizeof static struct switch typedef union volatile while _Alignas _Alignof _Atomic _Bool _Complex _Generic _Noreturn _Static_assert _Thread_local",
		types = "char double float int long short signed unsigned void bool size_t ssize_t int8_t int16_t int32_t int64_t uint8_t uint16_t uint32_t uint64_t uintptr_t intptr_t ptrdiff_t FILE",
		literals = "NULL true false nullptr"},
	.{name = "c-sharp", flags = C_FAMILY | .Preproc, lc = "//", bc = "/* */", quotes = "\"'",
		kw = "abstract as async await base break case catch checked class const continue default delegate do else enum event explicit extern finally fixed for foreach goto if implicit in interface internal is lock namespace new operator out override params private protected public readonly record ref return sealed sizeof stackalloc static struct switch throw try typeof unchecked unsafe using var virtual volatile when where while yield get set init",
		types = "bool byte char decimal double float int long object sbyte short string uint ulong ushort void dynamic nint nuint",
		builtins = "this", literals = "true false null"},
	.{name = "caddy", lc = "#", quotes = "\"`",
		kw = "reverse_proxy file_server root encode tls header redir rewrite handle handle_path route respond log import php_fastcgi basicauth basic_auth try_files uri bind abort error"},
	.{name = "capnp", flags = .Caps_Types | .Decorators, lc = "#", quotes = "\"",
		kw = "struct enum interface union group using import const annotation extends in of on as with from fixed",
		types = "Void Bool Int8 Int16 Int32 Int64 UInt8 UInt16 UInt32 UInt64 Float32 Float64 Text Data List AnyPointer",
		literals = "true false void inf"},
	.{name = "cedar", flags = .Calls, lc = "//", quotes = "\"",
		kw = "permit forbid when unless in has like is if then else", builtins = "principal action resource context", literals = "true false"},
	.{name = "cedarschema", flags = .Caps_Types, lc = "//", quotes = "\"",
		kw = "namespace entity action type in appliesTo principal resource context tags enum", types = "String Long Boolean Set Record"},
	.{name = "clojure", flags = .Lisp | .No_Ops, lc = ";", quotes = "\"",
		kw = "def defn defn- defmacro defmulti defmethod defprotocol defrecord deftype fn fn* if do let loop recur when when-not cond case and or not ns require import try catch finally throw quote var letfn doseq dotimes for",
		literals = "nil true false"},
	.{name = "cmake", flags = .No_Case | .Calls, lc = "#", quotes = "\"",
		kw = "if else elseif endif foreach endforeach while endwhile function endfunction macro endmacro return break continue"},
	.{name = "commonlisp", flags = .Lisp | .No_Ops, lc = ";", bc = "#| |#", quotes = "\"",
		kw = "defun defmacro defvar defparameter defconstant defclass defmethod defgeneric defstruct lambda let let* flet labels if when unless cond case and or not progn prog1 loop do dolist dotimes return return-from block setf setq quote function in-package declare",
		literals = "nil t"},
	.{name = "cpp", base = "c", flags = C_FAMILY | .Preproc, lc = "//", bc = "/* */", quotes = "\"'",
		kw = "alignas alignof and asm catch class co_await co_return co_yield concept consteval constexpr constinit decltype delete explicit export friend mutable namespace new noexcept not operator or private protected public requires static_assert static_cast dynamic_cast reinterpret_cast const_cast template thread_local throw try typeid typename using virtual xor override final",
		types = "wchar_t char8_t char16_t char32_t auto", builtins = "this std"},
	.{name = "css", mode = .Css, bc = "/* */", quotes = "\"'"},
	.{name = "d", flags = C_FAMILY, lc = "//", bc = "/* */", quotes = "\"'`",
		kw = "abstract alias align asm assert auto body break case cast catch class const continue debug default delegate delete deprecated do else enum export extern final finally for foreach foreach_reverse function goto if immutable import in inout interface invariant is lazy mixin module new nothrow out override package pragma private protected public pure ref return scope shared static struct super switch synchronized template throw try typeid typeof union unittest version while with",
		types = "bool byte ubyte short ushort int uint long ulong float double real char wchar dchar string void size_t",
		builtins = "this", literals = "true false null"},
	.{name = "dart", flags = C_FAMILY | .Decorators | .Triple, lc = "//", bc = "/* */", quotes = "\"'",
		kw = "abstract as assert async await base break case catch class const continue covariant default deferred do else enum export extends extension external factory final finally for get hide if implements import in interface is late library mixin new on operator part required rethrow return sealed set show static super switch sync throw try typedef var when while with yield",
		types = "int double num bool String List Map Set void Future Stream Object dynamic", builtins = "this", literals = "true false null"},
	.{name = "devicetree", flags = .Preproc | .Keys_Equals, lc = "//", bc = "/* */", quotes = "\"'", kw = "/dts-v1/ /include/ /delete-node/ /delete-property/"},
	.{name = "diff", mode = .Diff},
	.{name = "dockerfile", flags = .No_Case, lc = "#", quotes = "\"'",
		kw = "from run cmd label maintainer expose env add copy entrypoint volume user workdir arg onbuild stopsignal healthcheck shell as"},
	.{name = "dot", flags = .No_Case, lc = "// #", bc = "/* */", quotes = "\"", kw = "graph digraph subgraph node edge strict"},
	.{name = "elisp", flags = .Lisp | .No_Ops, lc = ";", quotes = "\"",
		kw = "defun defmacro defvar defcustom defconst lambda let let* if when unless cond and or not progn while dolist setq setf quote require provide interactive save-excursion",
		literals = "nil t"},
	.{name = "elixir", flags = .Caps_Types | .Calls | .Atoms | .Triple, lc = "#", quotes = "\"'",
		kw = "def defp defmodule defmacro defmacrop defstruct defprotocol defimpl defdelegate defguard defexception do end fn if else unless case cond with for receive try catch rescue after raise when and or not in import require alias use quote unquote",
		literals = "true false nil"},
	.{name = "elm", flags = .Caps_Types | .Char_Quote | .Triple, lc = "--", bc = "{- -}", quotes = "\"'",
		kw = "module exposing import as type alias port if then else case of let in"},
	.{name = "erlang", flags = .Calls, lc = "%", quotes = "\"'",
		kw = "after and andalso band begin bnot bor bsl bsr bxor case catch cond div end fun if let not of or orelse receive rem try when xor maybe else"},
	.{name = "fish", base = "bash", flags = .Command | .No_Ops, lc = "#", quotes = "\"'", kw = "end begin and or not set switch"},
	.{name = "fsharp", flags = .Caps_Types | .Char_Quote | .Triple, lc = "//", bc = "(* *)", quotes = "\"'",
		kw = "abstract and as assert base begin class default delegate do done downcast downto elif else end exception extern finally fixed for fun function global if in inherit inline interface internal lazy let match member module mutable namespace new not of open or override private public rec return select sig static struct then to try type upcast use val void when while with yield",
		types = "int float string bool unit char byte decimal list option seq array", literals = "true false null"},
	.{name = "gleam", flags = .Caps_Types | .Calls, lc = "//", quotes = "\"",
		kw = "as assert case const external fn if import let opaque panic pub todo type use echo", literals = "True False Nil"},
	.{name = "glsl", base = "c", flags = C_FAMILY | .Preproc, lc = "//", bc = "/* */", quotes = "\"",
		kw = "attribute uniform varying in out inout layout precision highp mediump lowp discard",
		types = "vec2 vec3 vec4 ivec2 ivec3 ivec4 uvec2 uvec3 uvec4 bvec2 bvec3 bvec4 mat2 mat3 mat4 sampler2D sampler3D samplerCube",
		builtins = "gl_Position gl_FragColor gl_FragCoord gl_VertexID"},
	.{name = "go", flags = .Calls, lc = "//", bc = "/* */", quotes = "\"'`",
		kw = "break case chan const continue default defer else fallthrough for func go goto if import interface map package range return select struct switch type var",
		types = "bool byte complex64 complex128 error float32 float64 int int8 int16 int32 int64 rune string uint uint8 uint16 uint32 uint64 uintptr any",
		builtins = "append cap clear close complex copy delete imag len make max min new panic print println real recover",
		literals = "true false nil iota"},
	.{name = "graphql", flags = .Caps_Types | .Decorators | .Triple, lc = "#", quotes = "\"",
		kw = "query mutation subscription fragment on type interface union enum input scalar schema extend directive implements repeatable",
		literals = "true false null"},
	.{name = "groovy", base = "java", flags = C_FAMILY | .Decorators | .Triple, lc = "//", bc = "/* */", quotes = "\"'", kw = "def as in trait"},
	.{name = "haskell", flags = .Caps_Types | .Char_Quote, lc = "--", bc = "{- -}", quotes = "\"'",
		kw = "case class data default deriving do else foreign if import in infix infixl infixr instance let module newtype of then type where forall qualified as hiding"},
	.{name = "hcl", flags = .Keys_Equals, lc = "# //", bc = "/* */", quotes = "\"",
		kw = "for in if else endif endfor resource data variable output locals module provider terraform", literals = "true false null"},
	.{name = "hlsl", base = "c", flags = C_FAMILY | .Preproc, lc = "//", bc = "/* */", quotes = "\"",
		kw = "cbuffer register uniform in out inout groupshared",
		types = "float2 float3 float4 float3x3 float4x4 half half2 half3 half4 int2 int3 int4 uint uint2 uint3 uint4 Texture2D SamplerState"},
	.{name = "html", mode = .Markup},
	.{name = "idris", flags = .Caps_Types | .Char_Quote, lc = "--", bc = "{- -}", quotes = "\"'",
		kw = "module import namespace data record interface implementation where let in do case of if then else total partial covering public export private mutual parameters using auto impossible"},
	.{name = "ini", flags = .Keys_Equals | .Sections, lc = "; #", quotes = "\""},
	.{name = "java", flags = C_FAMILY | .Decorators | .Triple, lc = "//", bc = "/* */", quotes = "\"'",
		kw = "abstract assert break case catch class const continue default do else enum exports extends final finally for goto if implements import instanceof interface module native new non-sealed open opens package permits private protected provides public record requires return sealed static strictfp super switch synchronized throw throws to transient transitive try uses var volatile while with yield",
		types = "boolean byte char double float int long short void", builtins = "this", literals = "true false null"},
	.{name = "javascript", flags = C_FAMILY | .Regex, lc = "//", bc = "/* */", quotes = "\"'`",
		kw = "as async await break case catch class const continue debugger default delete do else export extends finally for from function get if import in instanceof let new of return set static super switch throw try typeof var void while with yield",
		builtins = "this arguments console window document globalThis require module exports", literals = "true false null undefined NaN Infinity"},
	.{name = "jinja2", mode = .Markup, flags = .Template, quotes = "\"'",
		kw = "if elif else endif for endfor in block endblock extends include import from macro endmacro call endcall set endset filter endfilter with endwith raw endraw not and or is as recursive",
		literals = "true false none True False None"},
	.{name = "jq", flags = .Calls, lc = "#", quotes = "\"",
		kw = "def as if then elif else end reduce foreach try catch label import include and or not",
		builtins = "map select empty error length keys values has in to_entries from_entries add any all flatten range floor sqrt tostring tonumber type sort sort_by group_by unique min max reverse contains split join test match capture sub gsub",
		literals = "true false null"},
	.{name = "json", lc = "//", bc = "/* */", quotes = "\"", literals = "true false null"},
	.{name = "julia", flags = .Calls | .Caps_Types | .Char_Quote | .Decorators | .Triple, lc = "#", bc = "#= =#", quotes = "\"'`",
		kw = "abstract baremodule begin break catch const continue do else elseif end export finally for function global if import let local macro module mutable primitive quote return struct try type using while where in isa",
		literals = "true false nothing missing NaN Inf"},
	.{name = "kotlin", flags = C_FAMILY | .Decorators | .Triple, lc = "//", bc = "/* */", quotes = "\"'",
		kw = "as break class continue do else for fun if in interface is object package return super throw try typealias typeof val var when while by catch constructor delegate dynamic field file finally get import init param property receiver set setparam where actual abstract annotation companion const crossinline data enum expect external final infix inline inner internal lateinit noinline open operator out override private protected public reified sealed suspend tailrec vararg",
		builtins = "this", literals = "true false null"},
	.{name = "lean", flags = .Caps_Types, lc = "--", bc = "/- -/", quotes = "\"",
		kw = "def theorem lemma example structure class instance inductive where with match fun let in if then else do have show from by namespace end section open import variable universe axiom abbrev deriving mutual private protected noncomputable partial unsafe calc",
		literals = "true false"},
	.{name = "lua", flags = .Calls, lc = "--", bc = "--[[ ]]", quotes = "\"'",
		kw = "and break do else elseif end for function goto if in local not or repeat return then until while",
		builtins = "self print pairs ipairs require type tostring tonumber setmetatable getmetatable error assert pcall select next", literals = "true false nil"},
	.{name = "markdown", mode = .Markdown},
	.{name = "matlab", flags = .Calls, lc = "%", bc = "%{ %}", quotes = "\"'",
		kw = "break case catch classdef continue else elseif end for function global if otherwise parfor persistent return spmd switch try while properties methods events",
		literals = "true false pi inf nan"},
	.{name = "meson", flags = .Calls | .Triple, lc = "#", quotes = "'",
		kw = "if elif else endif foreach endforeach break continue and or not in", literals = "true false"},
	.{name = "ninja", flags = .Keys_Equals, lc = "#", kw = "build rule pool default include subninja"},
	.{name = "nix", flags = .Keys_Equals, lc = "#", bc = "/* */", quotes = "\"",
		kw = "let in with rec inherit if then else assert or", builtins = "builtins import", literals = "true false null"},
	.{name = "objc", base = "c", flags = C_FAMILY | .Preproc | .Decorators, lc = "//", bc = "/* */", quotes = "\"'",
		kw = "@interface @implementation @end @property @synthesize @protocol @class @selector @autoreleasepool @try @catch @finally @import @optional @required nonatomic atomic strong weak copy assign readonly readwrite",
		types = "id instancetype BOOL NSInteger NSUInteger", builtins = "self super", literals = "nil Nil YES NO"},
	.{name = "ocaml", flags = .Caps_Types | .Char_Quote, bc = "(* *)", quotes = "\"'",
		kw = "and as assert begin class constraint do done downto else end exception external for fun function functor if in include inherit initializer lazy let match method module mutable new nonrec object of open or private rec sig struct then to try type val virtual when while with",
		types = "int float string bool unit char list option array", literals = "true false"},
	.{name = "perl", flags = .Calls, lc = "#", quotes = "\"'",
		kw = "my our local sub if elsif else unless while until for foreach do last next redo return use no require package BEGIN END eq ne lt gt le ge cmp and or not xor qw",
		builtins = "print printf say die warn open close push pop shift unshift split join keys values defined ref scalar exists delete"},
	.{name = "php", flags = C_FAMILY, lc = "// #", bc = "/* */", quotes = "\"'",
		kw = "abstract and array as break callable case catch class clone const continue declare default do echo else elseif empty enddeclare endfor endforeach endif endswitch endwhile enum extends final finally fn for foreach function global goto if implements include include_once instanceof insteadof interface isset list match namespace new or print private protected public readonly require require_once return static switch throw trait try unset use var while xor yield",
		builtins = "$this self parent", literals = "true false null TRUE FALSE NULL"},
	.{name = "postscript", lc = "%",
		kw = "def begin end dict if ifelse for repeat loop exit moveto lineto curveto closepath stroke fill showpage setlinewidth setrgbcolor setgray newpath gsave grestore translate rotate scale findfont scalefont setfont show"},
	.{name = "powershell", flags = .No_Case | .Command | .Dash_Words, lc = "#", bc = "<# #>", quotes = "\"'",
		kw = "begin break catch class continue data define do dynamicparam else elseif end enum exit filter finally for foreach from function if in param process return switch throw trap try until using var while workflow",
		literals = "$true $false $null"},
	.{name = "prolog", flags = .Calls, lc = "%", bc = "/* */", quotes = "\"'", kw = "is mod rem not"},
	.{name = "python", flags = C_FAMILY | .Decorators | .Triple, lc = "#", quotes = "\"'",
		kw = "and as assert async await break class continue def del elif else except finally for from global if import in is lambda nonlocal not or pass raise return try while with yield match case",
		builtins = "self cls print len range int str float list dict set tuple bool type object super isinstance enumerate zip map filter open sorted min max sum abs any all repr iter next hasattr getattr setattr",
		literals = "True False None"},
	.{name = "query", flags = .Decorators | .Lisp | .No_Ops, lc = ";", quotes = "\""},
	.{name = "r", flags = .Calls, lc = "#", quotes = "\"'`",
		kw = "if else repeat while function for in next break return switch",
		builtins = "c list library require print paste vector matrix length", literals = "TRUE FALSE NULL NA NaN Inf T F"},
	.{name = "rego", flags = .Calls, lc = "#", quotes = "\"`",
		kw = "package import default not with as some every in if contains else", builtins = "input data", literals = "true false null"},
	.{name = "rescript", flags = .Caps_Types | .Char_Quote | .Decorators, lc = "//", bc = "/* */", quotes = "\"'`",
		kw = "and as assert async await catch constraint downto else exception external for if in include lazy let module mutable of open private rec switch to try type when while with",
		literals = "true false"},
	.{name = "ron", flags = .Caps_Types, lc = "//", bc = "/* */", quotes = "\"'", literals = "true false Some None"},
	.{name = "ruby", flags = .Caps_Types | .Atoms, lc = "#", bc = "=begin =end", quotes = "\"'`",
		kw = "BEGIN END alias and begin break case class def defined? do else elsif end ensure for if in module next not or redo rescue retry return super then undef unless until when while yield lambda proc require require_relative include extend attr_accessor attr_reader attr_writer private protected public raise loop puts",
		builtins = "self", literals = "true false nil"},
	.{name = "rust", flags = C_FAMILY | .Char_Quote | .Lifetimes | .Macros | .Hash_Attr, lc = "//", bc = "/* */", quotes = "\"'",
		kw = "as async await break const continue crate dyn else enum extern fn for if impl in let loop match mod move mut pub ref return static struct super trait type union unsafe use where while yield",
		types = "bool char str u8 u16 u32 u64 u128 usize i8 i16 i32 i64 i128 isize f32 f64 Self",
		builtins = "self", literals = "true false None Some Ok Err"},
	.{name = "scala", flags = C_FAMILY | .Decorators | .Triple, lc = "//", bc = "/* */", quotes = "\"'",
		kw = "abstract case catch class def do else enum export extends final finally for forSome given if implicit import lazy match new object override package private protected return sealed super then throw trait try type using val var while with yield",
		builtins = "this", literals = "true false null"},
	.{name = "scheme", flags = .Lisp | .No_Ops, lc = ";", bc = "#| |#", quotes = "\"",
		kw = "define define-syntax define-record-type lambda let let* letrec if cond case and or not begin do quote set! else when unless syntax-rules",
		literals = "#t #f"},
	.{name = "scss", mode = .Css, lc = "//", bc = "/* */", quotes = "\"'"},
	.{name = "solidity", flags = C_FAMILY, lc = "//", bc = "/* */", quotes = "\"'",
		kw = "pragma solidity contract interface library is function modifier event emit struct enum mapping public private internal external pure view payable constant immutable returns return if else for while do break continue new delete using import memory storage calldata require revert assert constructor fallback receive override virtual abstract unchecked try catch",
		types = "address bool string bytes uint int uint8 uint256 int256 bytes32", builtins = "msg block tx this", literals = "true false wei ether gwei"},
	.{name = "sparql", flags = .No_Case, lc = "#", quotes = "\"'",
		kw = "select construct describe ask where from named prefix base optional union filter graph service bind values minus order by asc desc limit offset distinct reduced group having as not exists in",
		literals = "true false a"},
	.{name = "sql", flags = .No_Case | .Calls, lc = "--", bc = "/* */", quotes = "'\"`",
		kw = "select from where and or not insert into values update set delete create table drop alter add column primary key foreign references index view join inner left right outer full cross on as group by order having limit offset union all distinct case when then else end exists in between like is default unique constraint check if begin commit rollback transaction with returning asc desc database schema grant revoke trigger procedure function return returns declare",
		types = "int integer bigint smallint tinyint decimal numeric float real double precision char varchar text date time timestamp boolean blob serial uuid json jsonb",
		literals = "true false null"},
	.{name = "ssh-config", flags = .No_Case, lc = "#", quotes = "\"",
		kw = "host match hostname user port identityfile identitiesonly proxyjump proxycommand forwardagent localforward remoteforward serveraliveinterval stricthostkeychecking userknownhostsfile include compression controlmaster controlpath controlpersist addkeystoagent usekeychain loglevel",
		literals = "yes no"},
	.{name = "starlark", base = "python", flags = C_FAMILY | .Triple, lc = "#", quotes = "\"'",
		builtins = "load rule attr struct depset select glob native provider"},
	.{name = "styx", flags = .Keys_Colon, lc = "//", quotes = "\""},
	.{name = "svelte", mode = .Markup},
	.{name = "swift", flags = C_FAMILY | .Decorators | .Triple | .Preproc, lc = "//", bc = "/* */", quotes = "\"",
		kw = "associatedtype class deinit enum extension fileprivate func import init inout internal let open operator private precedencegroup protocol public rethrows static struct subscript typealias var break case catch continue default defer do else fallthrough for guard if in repeat return throw switch where while as is try throws async await some any actor nonisolated mutating override final convenience required lazy weak unowned",
		builtins = "self Self super", literals = "true false nil"},
	.{name = "textproto", flags = .Keys_Colon, lc = "#", quotes = "\"'", literals = "true false"},
	.{name = "thrift", flags = .Caps_Types, lc = "// #", bc = "/* */", quotes = "\"'",
		kw = "namespace include cpp_include typedef enum struct union exception service extends oneway throws const required optional void",
		types = "bool byte i8 i16 i32 i64 double string binary map list set", literals = "true false"},
	.{name = "tlaplus", lc = "\\*", bc = "(* *)", quotes = "\"",
		kw = "MODULE EXTENDS CONSTANT CONSTANTS VARIABLE VARIABLES ASSUME THEOREM LET IN IF THEN ELSE CASE OTHER CHOOSE ENABLED UNCHANGED EXCEPT DOMAIN SUBSET UNION LOCAL INSTANCE WITH LAMBDA",
		builtins = "Nat Int Seq Len Append Head Tail", literals = "TRUE FALSE"},
	.{name = "toml", flags = .Keys_Equals | .Sections | .Triple, lc = "#", quotes = "\"'", literals = "true false"},
	.{name = "tsx", base = "typescript", flags = C_FAMILY | .Regex | .Decorators, lc = "//", bc = "/* */", quotes = "\"'`"},
	.{name = "typescript", base = "javascript", flags = C_FAMILY | .Regex | .Decorators, lc = "//", bc = "/* */", quotes = "\"'`",
		kw = "abstract declare enum implements interface keyof namespace private protected public readonly type satisfies infer is asserts override module unique",
		types = "any boolean never number object string symbol unknown bigint void"},
	.{name = "typst", flags = .Calls, lc = "//", bc = "/* */", quotes = "\"",
		kw = "let set show if else for in while break continue return import include as context", literals = "true false none auto"},
	.{name = "verilog", lc = "//", bc = "/* */", quotes = "\"",
		kw = "module endmodule input output inout wire reg logic integer real parameter localparam assign always always_ff always_comb always_latch initial begin end if else case casez casex endcase default for while repeat forever function endfunction task endtask posedge negedge or and not generate endgenerate genvar typedef enum struct packed signed unsigned interface endinterface package endpackage import"},
	.{name = "vhdl", flags = .No_Case, lc = "--", quotes = "\"",
		kw = "abs access after alias all and architecture array assert attribute begin block body buffer bus case component configuration constant downto else elsif end entity exit file for function generate generic group if impure in inertial inout is label library linkage literal loop map mod nand new next nor not null of on open or others out package port procedure process pure range record register reject rem report return rol ror select severity signal shared sla sll sra srl subtype then to transport type until use variable wait when while with xnor xor",
		types = "std_logic std_logic_vector integer natural positive boolean bit bit_vector signed unsigned string time real", literals = "true false"},
	.{name = "vim", flags = .Calls | .Bol_Comment, lc = "\"", quotes = "'",
		kw = "if else elseif endif for endfor while endwhile function endfunction fun endfun return let unlet set setlocal call execute exe echo echom autocmd augroup command nnoremap noremap vnoremap inoremap map nmap imap vmap syntax highlight hi source silent normal try catch finally endtry"},
	.{name = "vue", mode = .Markup},
	.{name = "wit", lc = "//", bc = "/* */", quotes = "\"",
		kw = "package world interface import export use type record enum variant flags resource func static constructor include with as",
		types = "u8 u16 u32 u64 s8 s16 s32 s64 f32 f64 char bool string list option result tuple borrow own"},
	.{name = "x86asm", base = "asm", flags = .No_Case, lc = "; #", quotes = "\"'"},
	.{name = "xml", mode = .Markup},
	.{name = "yaml", flags = .Keys_Colon, lc = "#", quotes = "\"'", literals = "true false null yes no on off ~"},
	.{name = "yuri", flags = C_FAMILY, lc = "//", bc = "/* */", quotes = "\""},
	.{name = "zig", flags = C_FAMILY | .Decorators, lc = "//", quotes = "\"'",
		kw = "addrspace align allowzero and anyframe anytype asm async await break callconv catch comptime const continue defer else enum errdefer error export extern fn for if inline linksection noalias noinline nosuspend opaque or orelse packed pub resume return struct suspend switch test threadlocal try union unreachable usingnamespace var volatile while",
		types = "i8 u8 i16 u16 i32 u32 i64 u64 i128 u128 isize usize f16 f32 f64 f128 bool void noreturn type anyerror comptime_int comptime_float c_int",
		literals = "true false null undefined"},
	.{name = "zsh", base = "bash", flags = .Command | .No_Ops, lc = "#", quotes = "\"'`"},
];

// The client's alias table (alias, grammar).
HL_ALIASES :: string.[
	"h", "cpp", "hpp", "cpp", "cc", "cpp", "cxx", "cpp", "c++", "cpp", "hxx", "cpp", "h++", "cpp", "hh", "cpp", "arduino", "cpp",
	"js", "javascript", "node", "javascript", "mjs", "javascript", "cjs", "javascript", "jsx", "javascript",
	"ts", "typescript", "mts", "typescript", "cts", "typescript", "rs", "rust", "cs", "c-sharp", "csharp", "c-sharp", "c#", "c-sharp",
	"yml", "yaml", "docker", "dockerfile", "gql", "graphql",
	"hbs", "html", "htm", "html", "xhtml", "html", "handlebars", "html", "html.hbs", "html", "html.handlebars", "html", "htmlbars", "html",
	"erb", "html", "twig", "html", "craftcms", "html",
	"xsl", "xml", "rss", "xml", "atom", "xml", "xsd", "xml", "plist", "xml", "svg", "xml", "mathml", "xml", "xjb", "xml", "wsf", "xml",
	"less", "css", "kt", "kotlin", "kts", "kotlin", "pl", "perl", "pm", "perl",
	"ps", "powershell", "ps1", "powershell", "psm1", "powershell", "psd1", "powershell", "pwsh", "powershell",
	"tf", "hcl", "tfvars", "hcl", "sh", "bash", "shell", "bash", "console", "bash", "shellsession", "bash",
	"ex", "elixir", "exs", "elixir", "erl", "erlang", "hs", "haskell", "fs", "fsharp", "f#", "fsharp",
	"ml", "ocaml", "mli", "ocaml", "sml", "ocaml", "re", "rescript", "reasonml", "rescript", "scm", "scheme", "rkt", "scheme",
	"clj", "clojure", "edn", "clojure", "rb", "ruby", "cr", "ruby", "crystal", "ruby", "gemspec", "ruby", "podspec", "ruby", "irb", "ruby", "thor", "ruby",
	"v", "verilog", "sv", "verilog", "svh", "verilog",
	"objectivec", "objc", "mm", "objc", "obj-c", "objc", "obj-c++", "objc", "objective-c++", "objc",
	"dos", "batch", "bat", "batch", "cmd", "batch", "lisp", "commonlisp", "capnproto", "capnp", "dts", "devicetree", "adoc", "asciidoc",
	"patch", "diff", "golang", "go", "jinja", "jinja2", "django", "jinja2", "jsp", "java", "nixos", "nix",
	"arm", "asm", "mips", "asm", "armasm", "asm", "mipsasm", "asm", "avrasm", "asm",
	"pgsql", "sql", "postgres", "sql", "postgresql", "sql", "n1ql", "sql", "gradle", "groovy", "php-template", "php", "cmake.in", "cmake",
	"md", "markdown", "mkdown", "markdown", "mkd", "markdown", "py", "python", "gyp", "python", "ipython", "python", "jsonc", "json",
	"python-repl", "python", "pycon", "python", "node-repl", "javascript", "clojure-repl", "clojure", "erlang-repl", "erlang",
	"julia-repl", "julia", "jldoctest", "julia",
];

// Word tables, built the first time a language is shown (kept for the run).
hl_tables: [..]*Table(string, Hl);

words_of :: (li: int) -> *Table(string, Hl) {
	if hl_tables.count < LANGS.count {
		n := hl_tables.count;
		array_resize(*hl_tables, LANGS.count);
		for n..LANGS.count - 1 hl_tables[it] = null;
	}
	if hl_tables[li] return hl_tables[li];
	t := New(Table(string, Hl));
	add_words :: (t: *Table(string, Hl), li: int, depth := 0) {
		assert(depth < 8); // LANGS' base chains are short
		L := LANGS[li];
		if L.base for LANGS if it.name == L.base add_words(t, it_index, depth + 1);
		for w: split(L.kw, " ",, temp) if w table_set(t, w, .Keyword);
		for w: split(L.types, " ",, temp) if w table_set(t, w, .Title);
		for w: split(L.builtins, " ",, temp) if w table_set(t, w, .Builtin);
		for w: split(L.literals, " ",, temp) if w table_set(t, w, .Number);
	}
	add_words(t, li);
	hl_tables[li] = t;
	return t;
}

is_digit :: (c: u8) -> bool { return c >= #char "0" && c <= #char "9"; }
is_alpha :: (c: u8) -> bool { return (c >= #char "a" && c <= #char "z") || (c >= #char "A" && c <= #char "Z"); }
is_word :: (c: u8) -> bool { return is_alpha(c) || is_digit(c) || c == #char "_" || c == #char "$" || c >= 0x80; }
is_blank :: (c: u8) -> bool { return c == #char " " || c == #char "\t" || c == #char "\r"; }
is_hex :: (c: u8) -> bool { return is_digit(c) || (c >= #char "a" && c <= #char "f") || (c >= #char "A" && c <= #char "F"); }

OPS :: "+-*/%=<>!&|^~?:";
LISP_WORD :: "-+*/<>=!?:&%.#";

Lexer :: struct {
	o: *Hl_Out;
	L: *Lang;
	words: *Table(string, Hl);
	s: string;
	hi: int;
	lcs: [3]string;
	bc_open, bc_close: string;
	bol := true; // only blanks since the line start
	cmd := true; // shells: the next word is a command
	angle: bool; // after #include: <...> is a string
	prev: u8; // last non-blank byte
}

starts :: (x: *Lexer, i: int, w: string) -> bool {
	if !w || i + w.count > x.hi return false;
	for cast([]u8) w {
		c := x.s[i + it_index];
		if (x.L.flags & .No_Case) c = to_lower(c);
		if c != it return false;
	}
	return true;
}

// The whole code lexer: one token per step, put as it goes.
hl_code :: (o: *Hl_Out, li: int, lo: int, hi: int) {
	x := Lexer.{o = o, L = *LANGS[li], words = words_of(li), s = o.src, hi = hi};
	k := 0;
	for w: split(x.L.lc, " ",, temp) if w && k < 3 { x.lcs[k] = w; k += 1; }
	if x.L.bc {
		_, a, b := split_from_left(x.L.bc, #char " ");
		x.bc_open, x.bc_close = a, b;
	}
	i := lo;
	while i < hi {
		c := x.s[i];
		if c == #char "\n" || is_blank(c) {
			if c == #char "\n" { x.bol = true; x.cmd = true; x.angle = false; }
			put(o, .Plain, i, i + 1);
			i += 1;
			continue;
		}
		keep_bol := false;
		j := token(*x, i, *keep_bol);
		if j <= i j = i + 1;
		x.prev = x.s[j - 1];
		if !keep_bol x.bol = false;
		i = j;
	}
}

// Lexes and puts one token at i; returns where it ends.
token :: (x: *Lexer, i: int, keep_bol: *bool) -> int {
	o, L, s, hi := x.o, x.L, x.s, x.hi;
	c := s[i];
	tok :: (kind: Hl, end: int) -> int #expand { put(`o, kind, `i, end); return end; }
	line_end :: (from: int) -> int #expand {
		e := find_index_from_left(`s, #char "\n", from);
		return ifx e < 0 || e > `hi then `hi else e;
	}
	// comments (block first: lua's --[[ starts like its line comment)
	if starts(x, i, x.bc_open) {
		e := find_index_from_left(s, x.bc_close, i + x.bc_open.count);
		return tok(.Comment, ifx e < 0 || e + x.bc_close.count > hi then hi else e + x.bc_close.count);
	}
	if !(L.flags & .Bol_Comment) || x.bol {
		for w: x.lcs {
			if !starts(x, i, w) continue;
			if is_alpha(w[0]) && i + w.count < hi && !is_blank(s[i + w.count]) && s[i + w.count] != #char "\n" continue; // "rem" as a word
			if w == "#" && (L.flags & .Command) && i > 0 && !is_blank(s[i - 1]) && s[i - 1] != #char "\n" continue; // ${#x}, a#b
			return tok(.Comment, line_end(i));
		}
	}
	// line-start structure
	if x.bol {
		if (L.flags & .Preproc) && c == #char "#" {
			j := i + 1;
			while j < hi && is_blank(s[j]) j += 1;
			w0 := j;
			while j < hi && is_word(s[j]) j += 1;
			w := slice(s, w0, j - w0);
			x.angle = w == "include" || w == "import";
			return tok(.Keyword, j);
		}
		if (L.flags & .Sections) && c == #char "[" {
			e := find_index_from_left(s, #char "]", i);
			if e >= 0 && e < line_end(i) return tok(.Title, e + 1);
		}
		if (L.flags & .Keys_Colon) && c == #char "-" && i + 1 < hi && s[i + 1] == #char " " {
			keep_bol.* = true; // "- key: value"
			return tok(.Operator, i + 1);
		}
		if L.flags & (.Keys_Colon | .Keys_Equals) {
			j := i;
			if c == #char "\"" || c == #char "'" {
				e := find_index_from_left(s, c, i + 1);
				j = ifx e >= 0 && e < line_end(i) then e + 1 else i;
			} else {
				while j < hi && !is_blank(s[j]) && find_index_from_left(":=#\n\"'[{}", s[j]) < 0 j += 1;
			}
			k := j;
			while k < hi && is_blank(s[k]) k += 1;
			if j > i && k < hi {
				if (L.flags & .Keys_Colon) && s[k] == #char ":" && (k + 1 >= hi || is_blank(s[k + 1]) || s[k + 1] == #char "\n") return tok(.Title, j);
				if (L.flags & .Keys_Equals) && s[k] == #char "=" && (k + 1 >= hi || s[k + 1] != #char "=") return tok(.Title, j);
			}
		}
	}
	if x.angle && c == #char "<" {
		e := find_index_from_left(s, #char ">", i);
		if e >= 0 && e < line_end(i) return tok(.String, e + 1);
	}
	if (L.flags & .Hash_Attr) && c == #char "#" && i + 1 < hi && (s[i + 1] == #char "[" || s[i + 1] == #char "!") {
		j, depth := i + 1, 0;
		while j < hi && s[j] != #char "\n" {
			if s[j] == #char "[" depth += 1;
			if s[j] == #char "]" { depth -= 1; if depth == 0 { j += 1; break; } }
			j += 1;
		}
		return tok(.Attr, j);
	}
	// strings
	if find_index_from_left(L.quotes, c) >= 0 {
		is_char := i + 2 < hi && (s[i + 2] == #char "'" || s[i + 1] == #char "\\");
		if c == #char "'" && (L.flags & .Char_Quote) && !is_char {
			if (L.flags & .Lifetimes) && i + 1 < hi && is_word(s[i + 1]) {
				j := i + 1;
				while j < hi && is_word(s[j]) j += 1;
				return tok(.Number, j);
			}
			return tok(.Plain, i + 1);
		}
		return string_at(x, i);
	}
	// numbers
	if is_digit(c) || (c == #char "." && i + 1 < hi && is_digit(s[i + 1]) && !is_word(x.prev)) {
		j := i + 1;
		while j < hi {
			ch := s[j];
			if is_word(ch) && ch != #char "$" { j += 1; continue; }
			if ch == #char "." && j + 1 < hi && is_digit(s[j + 1]) { j += 1; continue; }
			if (ch == #char "+" || ch == #char "-") && (s[j - 1] == #char "e" || s[j - 1] == #char "E") && !(i + 1 < hi && (s[i + 1] == #char "x" || s[i + 1] == #char "X")) { j += 1; continue; }
			break;
		}
		return tok(.Number, j);
	}
	// @decorators, :atoms
	if c == #char "@" && (L.flags & .Decorators) && i + 1 < hi && is_word(s[i + 1]) {
		j := i + 1;
		while j < hi && (is_word(s[j]) || s[j] == #char ".") j += 1;
		found, kind := table_find(x.words, slice(s, i, j - i));
		return tok(ifx found then kind else .Attr, j);
	}
	if c == #char ":" && (L.flags & (.Atoms | .Lisp)) && x.prev != #char ":" && i + 1 < hi && (is_alpha(s[i + 1]) || s[i + 1] == #char "_") {
		j := i + 1;
		while j < hi && (is_word(s[j]) || ((L.flags & .Lisp) && find_index_from_left(LISP_WORD, s[j]) >= 0)) j += 1;
		return tok(ifx (L.flags & .Lisp) != 0 then Hl.Number else .String, j);
	}
	if c == #char "/" && (L.flags & .Regex) && i + 1 < hi && s[i + 1] != #char "/" && s[i + 1] != #char "*" && (x.prev == 0 || find_index_from_left("(,=:[!&|?{};", x.prev) >= 0) {
		j, in_class := i + 1, false;
		while j < hi && s[j] != #char "\n" {
			if s[j] == #char "\\" { j += 2; continue; }
			if s[j] == #char "[" in_class = true;
			if s[j] == #char "]" in_class = false;
			if s[j] == #char "/" && !in_class break;
			j += 1;
		}
		if j < hi && s[j] == #char "/" {
			j += 1;
			while j < hi && is_alpha(s[j]) j += 1;
			return tok(.Regex, j);
		}
	}
	// words
	lisp := (L.flags & .Lisp) != 0;
	if is_alpha(c) || c == #char "_" || c == #char "$" || c >= 0x80 || (lisp && find_index_from_left(LISP_WORD, c) >= 0) {
		j := i + 1;
		while j < hi {
			ch := s[j];
			if is_word(ch) || (lisp && find_index_from_left(LISP_WORD, ch) >= 0) { j += 1; continue; }
			if ch == #char "-" && (L.flags & .Dash_Words) && j + 1 < hi && is_alpha(s[j + 1]) { j += 1; continue; }
			if ch == #char "?" && L.name == "ruby" { j += 1; break; }
			break;
		}
		w := slice(s, i, j - i);
		buf: [64]u8;
		if (L.flags & .No_Case) && w.count <= 64 {
			for cast([]u8) w buf[it_index] = to_lower(it);
			w = .{w.count, buf.data};
		}
		found, kind := table_find(x.words, w);
		at_cmd := x.cmd;
		x.cmd = found && kind == .Keyword; // `if`, `then`, `do` ... are followed by a command
		if !found {
			k := j;
			while k < hi && is_blank(s[k]) k += 1;
			if (L.flags & .Macros) && j < hi && s[j] == #char "!" && (j + 1 >= hi || s[j + 1] != #char "=") { j += 1; kind = .Namespace; }
			else if lisp && x.prev == #char "(" kind = .Title;
			else if (L.flags & .Command) && at_cmd kind = .Title;
			else if (L.flags & .Calls) && k < hi && s[k] == #char "(" kind = .Title;
			else if (L.flags & .Caps_Types) && c >= #char "A" && c <= #char "Z" && has_lower(w) kind = .Title;
			else kind = .Plain;
		}
		return tok(kind, j);
	}
	if find_index_from_left(";|&(`", c) >= 0 x.cmd = true;
	if !(L.flags & .No_Ops) && find_index_from_left(OPS, c) >= 0 {
		j := i + 1;
		while j < hi && find_index_from_left(OPS, s[j]) >= 0 j += 1;
		return tok(.Operator, j);
	}
	return tok(.Plain, i + 1);
}

has_lower :: (w: string) -> bool {
	for cast([]u8) w if it >= #char "a" && it <= #char "z" return true;
	return false;
}

// A quoted string from i, with escape sequences coloured apart. Backtick and triple-quoted
// strings may span lines.
string_at :: (x: *Lexer, i: int) -> int {
	o, s, hi := x.o, x.s, x.hi;
	q := s[i];
	triple := (x.L.flags & .Triple) && i + 2 < hi && s[i + 1] == q && s[i + 2] == q;
	open := ifx triple then 3 else 1;
	multi := triple || q == #char "`";
	j := i + open;
	seg := i;
	while j < hi {
		ch := s[j];
		if ch == #char "\\" && j + 1 < hi && s[j + 1] != #char "\n" {
			put(o, .String, seg, j);
			e := j + 2;
			if s[j + 1] == #char "x" || s[j + 1] == #char "u" {
				if e < hi && s[e] == #char "{" { while e < hi && s[e] != #char "}" && s[e] != #char "\n" e += 1; if e < hi && s[e] == #char "}" e += 1; }
				else while e < hi && e < j + 6 && is_hex(s[e]) e += 1;
			}
			put(o, .Escape, j, e);
			j, seg = e, e;
			continue;
		}
		if ch == #char "\n" && !multi break;
		if ch == q && (!triple || (j + 2 < hi && s[j + 1] == q && s[j + 2] == q)) { j += open; break; }
		j += 1;
	}
	put(o, .String, seg, j);
	return j;
}

// HTML, XML, Svelte, Vue, Jinja: tags, attributes, comments, entities; <script> and <style>
// bodies as JavaScript and CSS.
hl_markup :: (o: *Hl_Out, li: int, lo: int, hi: int) {
	s := o.src;
	template := (LANGS[li].flags & .Template) != 0;
	i := lo;
	at :: (w: string) -> bool #expand { return `i + w.count <= `hi && slice(`s, `i, w.count) == w; }
	while i < hi {
		c := s[i];
		if at("<!--") {
			e := find_index_from_left(s, "-->", i + 4);
			j := ifx e < 0 || e + 3 > hi then hi else e + 3;
			put(o, .Comment, i, j);
			i = j;
		} else if template && (at("{%") || at("{{") || at("{#")) {
			close := ifx s[i + 1] == #char "%" then "%}" else ifx s[i + 1] == #char "{" then "}}" else "#}";
			e := find_index_from_left(s, close, i + 2);
			j := ifx e < 0 || e + 2 > hi then hi else e + 2;
			if s[i + 1] == #char "#" {
				put(o, .Comment, i, j);
			} else {
				put(o, .Keyword, i, i + 2);
				hl_code(o, li, i + 2, max(i + 2, j - 2));
				put(o, .Keyword, max(i + 2, j - 2), j);
			}
			i = j;
		} else if c == #char "<" && i + 1 < hi && (is_alpha(s[i + 1]) || s[i + 1] == #char "/" || s[i + 1] == #char "!" || s[i + 1] == #char "?") {
			j := i + 1;
			closing := s[j] == #char "/";
			while j < hi && find_index_from_left("/!?", s[j]) >= 0 j += 1;
			put(o, .Plain, i, j);
			n := j;
			while j < hi && (is_word(s[j]) || s[j] == #char "-" || s[j] == #char ":" || s[j] == #char ".") j += 1;
			name := to_lower_copy(slice(s, n, j - n),, temp);
			put(o, .Title, n, j);
			// attributes up to '>'
			while j < hi && s[j] != #char ">" {
				ch := s[j];
				if ch == #char "\"" || ch == #char "'" {
					e := find_index_from_left(s, ch, j + 1);
					k := ifx e < 0 || e >= hi then hi else e + 1;
					put(o, .String, j, k);
					j = k;
				} else if is_blank(ch) || ch == #char "\n" || ch == #char "=" || ch == #char "/" || ch == #char "?" {
					put(o, .Plain, j, j + 1);
					j += 1;
				} else {
					k := j;
					while k < hi && !is_blank(s[k]) && find_index_from_left("\n=>/\"'", s[k]) < 0 k += 1;
					put(o, ifx j > 0 && s[j - 1] == #char "=" then Hl.String else .Attr, j, k);
					j = k;
				}
			}
			if j < hi j += 1;
			put(o, .Plain, j - 1, j);
			i = j;
			if !closing && (name == "script" || name == "style") {
				e := i;
				end_tag := ifx name == "script" then "</script" else "</style";
				while e < hi && !(e + end_tag.count <= hi && to_lower_copy(slice(s, e, end_tag.count),, temp) == end_tag) e += 1;
				hl_range(o, hl_lang(ifx name == "script" then "javascript" else "css"), i, e);
				i = e;
			}
		} else if c == #char "&" {
			j := i + 1;
			while j < hi && j < i + 12 && (is_word(s[j]) || s[j] == #char "#") j += 1;
			if j < hi && s[j] == #char ";" { put(o, .Escape, i, j + 1); i = j + 1; }
			else { put(o, .Plain, i, i + 1); i += 1; }
		} else {
			j := i + 1;
			while j < hi && s[j] != #char "<" && s[j] != #char "&" && !(template && s[j] == #char "{") j += 1;
			put(o, .Plain, i, j);
			i = j;
		}
	}
}

// CSS and SCSS: at-rules, selectors, properties, values, numbers with units, colours.
hl_css :: (o: *Hl_Out, li: int, lo: int, hi: int) {
	s := o.src;
	L := *LANGS[li];
	depth := 0;
	in_value := false;
	i := lo;
	word_end :: (from: int) -> int #expand {
		j := from;
		while j < `hi && (is_word(`s[j]) || `s[j] == #char "-") j += 1;
		return j;
	}
	while i < hi {
		c := s[i];
		j := i + 1;
		kind := Hl.Plain;
		if c == #char "/" && i + 1 < hi && s[i + 1] == #char "*" {
			e := find_index_from_left(s, "*/", i + 2);
			kind = .Comment;
			j = ifx e < 0 || e + 2 > hi then hi else e + 2;
		} else if L.lc && c == #char "/" && i + 1 < hi && s[i + 1] == #char "/" && (i == 0 || s[i - 1] != #char ":") {
			e := find_index_from_left(s, #char "\n", i);
			kind = .Comment;
			j = ifx e < 0 || e > hi then hi else e;
		} else if c == #char "\"" || c == #char "'" {
			e := find_index_from_left(s, c, i + 1);
			kind = .String;
			j = ifx e < 0 || e >= hi then hi else e + 1;
		} else if c == #char "{" {
			depth += 1;
			in_value = false;
		} else if c == #char "}" {
			depth = max(0, depth - 1);
			in_value = false;
		} else if c == #char ";" {
			in_value = false;
		} else if c == #char "@" || c == #char "!" {
			j, kind = word_end(i + 1), Hl.Keyword;
		} else if c == #char "#" && in_value {
			j, kind = word_end(i + 1), Hl.Number;
		} else if c == #char ":" && depth > 0 && !in_value {
			in_value = true;
		} else if c == #char ":" {
			j, kind = word_end(i + 1), Hl.Attr; // :hover, ::before
			while j < hi && s[j] == #char ":" j = word_end(j + 1);
		} else if in_value && (is_digit(c) || ((c == #char "." || c == #char "-") && i + 1 < hi && is_digit(s[i + 1]))) {
			while j < hi && (is_word(s[j]) || s[j] == #char "." || s[j] == #char "%") j += 1;
			kind = .Number;
		} else if is_word(c) || c == #char "-" {
			j = word_end(i);
			if j == i j = i + 1;
			k := j;
			while k < hi && is_blank(s[k]) k += 1;
			if in_value kind = ifx k < hi && s[k] == #char "(" then Hl.Title else .Plain;
			else if c == #char "$" kind = .Plain;
			else kind = .Title; // property names, tag / class / id selectors
		}
		put(o, kind, i, j);
		i = j;
	}
}

// Markdown and AsciiDoc: headings, quotes, list markers, `code`, comments.
hl_doc :: (o: *Hl_Out, li: int, lo: int, hi: int) {
	s := o.src;
	lc := LANGS[li].lc;
	i := lo;
	while i < hi {
		e := find_index_from_left(s, #char "\n", i);
		end := ifx e < 0 || e >= hi then hi else e;
		line := slice(s, i, end - i);
		t := trim_left(line, " ");
		lead := i + line.count - t.count;
		h := 0;
		while h < t.count && (t[h] == #char "#" || t[h] == #char "=") h += 1;
		if h > 0 && h < t.count && t[h] == #char " " {
			put(o, .Title, i, end);
		} else if lc && begins_with(t, lc) {
			put(o, .Comment, i, end);
		} else if begins_with(t, ">") {
			put(o, .Comment, i, end);
		} else {
			put(o, .Plain, i, lead);
			j := lead;
			if begins_with(t, "- ") || begins_with(t, "* ") || begins_with(t, "+ ") { put(o, .Operator, j, j + 1); j += 1; }
			while j < end {
				if s[j] == #char "`" {
					k := find_index_from_left(s, #char "`", j + 1);
					if k > 0 && k < end { put(o, .String, j, k + 1); j = k + 1; continue; }
				}
				put(o, .Plain, j, j + 1);
				j += 1;
			}
		}
		if end < hi put(o, .Plain, end, end + 1);
		i = end + 1;
	}
}

// Unified diffs: added and removed lines, hunk headers, file names.
hl_diff :: (o: *Hl_Out, lo: int, hi: int) {
	s := o.src;
	i := lo;
	while i < hi {
		e := find_index_from_left(s, #char "\n", i);
		end := ifx e < 0 || e >= hi then hi else e;
		line := slice(s, i, end - i);
		kind := Hl.Plain;
		if begins_with(line, "+++") || begins_with(line, "---") || begins_with(line, "diff ") || begins_with(line, "index ") kind = .Title;
		else if begins_with(line, "@@") kind = .Namespace;
		else if begins_with(line, "+") || begins_with(line, ">") kind = .Addition;
		else if begins_with(line, "-") || begins_with(line, "<") kind = .Deletion;
		put(o, kind, i, end);
		if end < hi put(o, .Plain, end, end + 1);
		i = end + 1;
	}
}

// ```ansi: SGR escape sequences set colours, underline and strikethrough, as the
// client's ANSI parser does; the sequences themselves are hidden (kept, dimmed, in the composer).
ANSI_TOKENS :: string.["--ansi-black", "--ansi-red", "--ansi-green", "--ansi-yellow", "--ansi-blue", "--ansi-magenta", "--ansi-cyan", "--ansi-white",
	"--ansi-bright-black", "--ansi-bright-red", "--ansi-bright-green", "--ansi-bright-yellow", "--ansi-bright-blue", "--ansi-bright-magenta", "--ansi-bright-cyan", "--ansi-bright-white"];

hl_ansi :: (o: *Hl_Out, lo: int, hi: int) {
	s := o.src;
	fg, bg: ui.Color;
	underline, strike: bool; // bold (1) is dropped: there is no bold code face, and a sans one breaks the columns
	i, text_start := lo, lo;
	flush :: (to: int) #expand {
		if to <= `text_start return;
		sp := `o.proto;
		sp.text = .{to - `text_start, `s.data + `text_start};
		sp.color = `fg;
		sp.bg = `bg;
		sp.underline = `underline;
		sp.strike = `strike;
		array_add(`o.spans, sp);
		`o.last = -1;
	}
	while i < hi {
		if s[i] != 0x1b || i + 1 >= hi || s[i + 1] != #char "[" { i += 1; continue; }
		// ESC [ params intermediates final
		j := i + 2;
		while j < hi && s[j] >= 0x30 && s[j] <= 0x3f j += 1;
		p_end := j;
		while j < hi && s[j] >= 0x20 && s[j] <= 0x2f j += 1;
		if j >= hi || s[j] < 0x40 || s[j] > 0x7e { i += 1; continue; }
		flush(i);
		params := slice(s, i + 2, p_end - i - 2);
		if s[j] == #char "m" && p_end == j && !(params && find_index_from_left("<=>?", params[0]) >= 0) {
			codes := split(params, ";",, temp);
			k := 0;
			while k < codes.count {
				n, ok := string_to_int(codes[k]);
				k += 1;
				if !ok continue;
				if n == 0 { fg, bg = .{}, .{}; underline, strike = false, false; }
				else if n == 4 underline = true;
				else if n == 9 strike = true;
				else if n == 24 underline = false;
				else if n == 29 strike = false;
				else if n >= 30 && n <= 37 fg = T(ANSI_TOKENS[n - 30]);
				else if n == 39 fg = .{};
				else if n >= 40 && n <= 47 bg = T(ANSI_TOKENS[n - 40]);
				else if n == 49 bg = .{};
				else if n >= 90 && n <= 97 fg = T(ANSI_TOKENS[n - 90 + 8]);
				else if n >= 100 && n <= 107 bg = T(ANSI_TOKENS[n - 100 + 8]);
				else if (n == 38 || n == 48) && k < codes.count {
					c: ui.Color;
					m, _ := string_to_int(codes[k]);
					if m == 5 && k + 1 < codes.count {
						idx, _ := string_to_int(codes[k + 1]);
						if idx >= 0 && idx < 16 c = T(ANSI_TOKENS[idx]);
						k += 2;
					} else if m == 2 && k + 3 < codes.count {
						r, _ := string_to_int(codes[k + 1]);
						g, _ := string_to_int(codes[k + 2]);
						b, _ := string_to_int(codes[k + 3]);
						c = .{cast(float32) r / 255, cast(float32) g / 255, cast(float32) b / 255, 1};
						k += 4;
					}
					if c.w > 0 { if n == 38 fg = c; else bg = c; }
				}
			}
		}
		if o.keep_escapes {
			sp := o.proto;
			sp.text = .{j + 1 - i, s.data + i};
			sp.color = T("--textbox-markdown-syntax");
			sp.size *= 0.7;
			array_add(o.spans, sp);
		}
		i = j + 1;
		text_start = i;
	}
	flush(hi);
}
