// build.jai compiles this file as the program root; the app itself is the `app` module (module.jai, app_main.jai).
app :: #import "app";
main :: () { app.main(); }
