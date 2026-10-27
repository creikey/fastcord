#import "Basic";
#import "Math";
lib :: #system_library "libobjc";
Foundation :: #library,system,link_always "Foundation";
#load "doc.jai";
#if OS == .MACOS #load "objc.jai";
