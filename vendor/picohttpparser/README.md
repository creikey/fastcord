# picohttpparser

HTTP/1.1 response-head parser and chunked-body decoder (`src/http/h1.odin` binds it).
`picohttpparser.c` and `picohttpparser.h`, unmodified.

- Source: https://github.com/h2o/picohttpparser at commit 465a7ff09fbd3432fe56c673451f5460154d1f07
  (2026-09-29), GitHub's tarball of that commit
- sha256 of the tarball: d65d80b362fcb11f6e982ebc4515442d93b937b166558120031c38a8b6c173cd
- Licence: MIT or Perl, at our choice; we take MIT (stated in the head of both files).

Why: it is the parser of the H2O web server and Perl's HTTP::Parser::XS, fuzzed through H2O's OSS-Fuzz targets, and its
chunked decoder rejects chunk-size overflow and excessive chunk overhead. It replaced a hand-written
parser.

`fc_picohttpparser.c` is ours: it includes `picohttpparser.c`.

To update: replace both files with the new commit's, record the commit and sha256 here, then run
`odin test src/http -collection:fc=src`.
