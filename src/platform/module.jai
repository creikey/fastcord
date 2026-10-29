#import "Basic";
#import "Math";
#import "String";
#import "Atomics";
#import "Thread";
#import "Flat_Pool";
#import "Unicode";
locks :: #import "locks";

#load "platform.jai";
#load "instance.jai";
#if OS == .MACOS {
    objc :: #import "platform_objc";
    #load "ns_darwin.jai";
    #load "notify_darwin.jai";
    #load "platform_darwin.jai";
}
#if OS == .WINDOWS #load "platform_windows.jai";
#if OS == .LINUX {
    #load "platform_linux.jai";
    #load "wayland_linux.jai";
}
