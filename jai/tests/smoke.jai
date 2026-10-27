#import "Basic";
etf :: #import "etf";
fmt :: #import "fc_fmt";
main :: () {
  fmt.printf("hello %d %s %05.2f %x\n", 42, "str", 3.14159, 255);
  b, err := etf.encode(etf.vint(5));
  fmt.println(b, err);
}
