import AppKit

// Each group shares a small source sample. Keep ambiguous extensions such as .m as separate files.
private let sourceExamples = [
    ("Hello.swift", "import Foundation\nprint(\"你好，Swift\")"),
    ("hello.c hello.h", "int folio_value(void) { return 42; }"),
    ("hello.cc hello.cpp hello.cxx hello.hpp hello.hh hello.hxx", "constexpr int folio_value = 42;"),
    ("objc.m objc.mm", "int main(void) { @autoreleasepool { return 0; } }"),
    ("matlab.m", "disp('Hello, MATLAB');"),
    ("Hello.cs", "class Hello { static void Main() { } }"),
    ("Hello.java", "class Hello { public static void main(String[] args) {} }"),
    ("hello.kt hello.kts", "fun hello() = println(\"Kotlin\")"),
    ("hello.scala hello.sc", "object Hello { val message = \"Scala\" }"),
    ("hello.groovy", "println 'Hello, Groovy'"),
    ("hello.clj hello.cljs hello.cljc", "(defn hello [] (println \"Hello\"))"),
    ("hello.go", "package main\nfunc main() { println(\"Go\") }"),
    ("hello.rs", "fn main() { println!(\"Rust\"); }"),
    ("hello.zig", "pub fn main() void {}"),
    ("hello.d", "void main() { int value = 42; }"),
    ("hello.nim", "echo \"Hello, Nim\""),
    ("hello.py hello.pyw hello.pyi", "def hello() -> str: return 'Python'"),
    ("hello.rb hello.cr", "puts \"Hello, world\""),
    ("hello.php hello.phtml", "<?php echo 'Hello'; ?>"),
    ("hello.pl hello.pm", "use strict;\nprint \"Hello\\n\";"),
    ("hello.lua", "print('Hello, Lua')"),
    ("hello.js hello.mjs hello.cjs", "const message = 'JavaScript';"),
    ("hello.jsx", "const Hello = () => <main>Hello</main>;"),
    ("hello.ts hello.mts hello.cts", "const message: string = 'TypeScript';"),
    ("hello.tsx", "import React from 'react';\nconst Hello = () => <span>" + String(repeating:"Hello ",count:40) + "</span>;"),
    ("hello.vue", "<template><p>Hello</p></template>"),
    ("hello.svelte hello.astro", "<main>Hello, world</main>"),
    ("hello.dart", "void main() => print('Dart');"),
    ("hello.html hello.htm hello.xhtml", "<html><body>Hello</body></html>"),
    ("hello.css hello.less hello.scss", "body { color: #123456; }"),
    ("hello.sass", "body\n  color: navy"),
    ("hello.sh hello.bash hello.zsh", "#!/bin/sh\nprintf 'Hello\\n'"),
    ("hello.fish", "echo 'Hello, fish'"),
    ("hello.ps1 hello.psm1", "Write-Output 'Hello, PowerShell'"),
    ("hello.bat hello.cmd", "@echo Hello, Windows"),
    ("hello.sql", "SELECT 'Hello' AS message;"),
    ("hello.R", "message <- 'Hello, R'"),
    ("hello.jl", "println(\"Hello, Julia\")"),
    ("Hello.hs", "main = putStrLn \"Haskell\""),
    ("hello.fs hello.fsx", "let message = \"F sharp\""),
    ("hello.ml hello.mli", "type message = string"),
    ("Hello.elm", "module Hello exposing (hello)\nhello = \"Elm\""),
    ("hello.ex hello.exs", "IO.puts(\"Hello, Elixir\")"),
    ("hello.erl hello.hrl", "-define(MESSAGE, \"Hello\")."),
    ("hello.lisp hello.lsp", "(print \"Hello, world\")"),
    ("hello.scm hello.rkt", "(display \"Hello, world\")"),
    ("hello.s hello.asm", "folio_value:\n    nop"),
    ("hello.f90 hello.f95", "program hello\nprint *, 'Hello'\nend program hello"),
    ("hello.f hello.for", "      PROGRAM HELLO\n      END"),
    ("hello.cob hello.cbl", "       IDENTIFICATION DIVISION.\n       PROGRAM-ID. HELLO."),
    ("hello.v hello.sv", "module hello; endmodule"),
    ("hello.vhd hello.vhdl", "entity hello is end entity hello;"),
    ("hello.sol", "contract Hello { uint value = 42; }"),
    ("hello.vb", "Dim message As String"),
    ("hello.vbs", "WScript.Echo \"Hello\""),
    ("hello.pas hello.pp", "program Hello; begin writeln('Hello'); end."),
    ("hello.ino", "void setup() {}\nvoid loop() {}"),
    ("hello.cu hello.cuh", "__global__ void hello() {}"),
    ("build.gradle", "plugins { id 'java' }"),
    ("hello.gd", "extends Node\nfunc _ready(): print('Hello')"),
    ("hello.raku", "say 'Hello, Raku';"),
    ("hello.tcl", "puts \"Hello, Tcl\""),
    ("hello.awk", "BEGIN { print \"Hello\" }"),
    ("hello.proto", "syntax = \"proto3\";\nmessage Hello {}"),
    ("hello.graphql hello.gql", "type Query { hello: String }"),
    ("hello.json hello.ipynb", "{\"message\": \"Hello\"}"),
    ("hello.yml hello.yaml", "message: Hello"),
    ("hello.toml hello.ini", "message = \"Hello\""),
    ("hello.xml", "<message>Hello</message>"),
    ("hello.tf", "variable \"message\" { type = string }"),
    ("Dockerfile", "FROM scratch\nLABEL message=Hello"),
    ("Makefile hello.mk", "hello:\n\t@echo Hello"),
    ("CMakeLists.txt hello.cmake", "message(STATUS \"Hello\")")
]

// Check the composited window. Reading the text storage or drawing just the text view
// would pass even if a sibling (such as the ruler) painted over every glyph.
private func visibleFirstLine(_ buffer:Buffer,in window:NSWindow) -> Bool {
    let source = buffer.source
    guard let root = window.contentView, source.window === window, !source.isHiddenOrHasHiddenAncestor,
          let layout = source.layoutManager, let container = source.textContainer else { return false }
    root.layoutSubtreeIfNeeded()
    window.displayIfNeeded()
    guard let bitmap = root.bitmapImageRepForCachingDisplay(in:root.bounds) else { return false }
    root.cacheDisplay(in:root.bounds,to:bitmap)
    guard let frame = bitmap.cgImage else { return false }
    var end = 0
    (source.string as NSString).getLineStart(nil,end:nil,contentsEnd:&end,for:NSRange(location:0,length:0))
    let first = NSRange(location:0,length:min(end,40))
    let glyphs = layout.glyphRange(forCharacterRange:first,actualCharacterRange:nil)
    var rect = layout.boundingRect(forGlyphRange:glyphs,in:container)
    rect = rect.offsetBy(dx:source.textContainerOrigin.x,dy:source.textContainerOrigin.y)
    let gutterEdge = source.convert(buffer.gutter.bounds,from:buffer.gutter).maxX
    guard rect.minX >= max(gutterEdge,source.visibleRect.minX) else { return false }
    rect = rect.insetBy(dx:3,dy:1).intersection(source.visibleRect)
    guard rect.width >= 8, rect.height >= 5 else { return false }
    rect = root.convert(rect,from:source)
    let sx = CGFloat(frame.width)/root.bounds.width, sy = CGFloat(frame.height)/root.bounds.height
    let y = root.isFlipped ? rect.minY : root.bounds.height-rect.maxY
    guard let crop = frame.cropping(to:CGRect(x:rect.minX*sx,y:y*sy,width:rect.width*sx,height:rect.height*sy).integral) else { return false }
    var pixels = [UInt8](repeating:0,count:crop.width*crop.height)
    return pixels.withUnsafeMutableBytes { bytes in
        guard let context = CGContext(data:bytes.baseAddress,width:crop.width,height:crop.height,bitsPerComponent:8,
            bytesPerRow:crop.width,space:CGColorSpaceCreateDeviceGray(),bitmapInfo:CGImageAlphaInfo.none.rawValue) else { return false }
        context.draw(crop,in:CGRect(x:0,y:0,width:crop.width,height:crop.height))
        guard let minimum = bytes.min(), let maximum = bytes.max() else { return false }
        return Int(maximum)-Int(minimum) > 40
    }
}

func runSourceFileTests(_ e:Workspace,at directory:URL) {
    let dir = directory.standardizedFileURL.resolvingSymlinksInPath()
    func verify(_ url:URL,_ expected:String,_ stage:String) {
        guard let b = e.active as? Buffer, b.url?.path == url.path, b.source.string == expected,
              visibleFirstLine(b,in:e.window) else {
            print("active",e.active?.url?.path as Any,"expected",url.path,"string correct",(e.active as? Buffer)?.source.string == expected)
            FileHandle.standardError.write(Data("FAIL source text or rendering: \(stage) \(url.lastPathComponent)\n".utf8))
            exit(1)
        }
    }
    do {
        let launch = dir.appendingPathComponent("Start.swift")
        let first = try String(contentsOf:launch,encoding:.utf8)
        capture(e.window,dir.appendingPathComponent("swift-window.png"))
        verify(launch,first,"Finder launch")
        let project = dir.appendingPathComponent("Languages",isDirectory:true)
        try FileManager.default.createDirectory(at:project,withIntermediateDirectories:true)
        var files = [(URL,String)]()
        for (names,example) in sourceExamples {
            for name in names.split(separator:" ") {
                let url = project.appendingPathComponent(String(name))
                let code = example+"\n"
                try code.write(to:url,atomically:true,encoding:.utf8)
                files.append((url,code))
            }
        }
        let utf16 = project.appendingPathComponent("Unicode.swift")
        let code = "let greeting = \"你好 🦕\"\nprint(greeting)\n"
        let bytes = Data([0xff,0xfe])+code.replacingOccurrences(of:"\n",with:"\r\n").data(using:.utf16LittleEndian)!
        try bytes.write(to:utf16)
        let large = project.appendingPathComponent("Large.swift")
        let largeCode = String(repeating:"let sourceValue = 12345 // large Swift fixture\n",count:18000)
        try largeCode.write(to:large,atomically:true,encoding:.utf8)
        files.append((large,largeCode))
        files.append((utf16,code))
        e.open([project])
        for appearance in [NSAppearance.Name.aqua,.darkAqua] {
            e.window.appearance = NSAppearance(named:appearance)
            for (url,expected) in files {
                guard let row = e.items.firstIndex(where:{ $0.0.path == url.path }) else { exit(1) }
                e.selectTree(row)
                verify(url,expected,appearance.rawValue)
            }
        }
        e.closeBuffer(e.active!)
        e.open([utf16])
        verify(utf16,code,"close and reopen")
        e.open([launch])
        verify(launch,first,"return to original tab")
        print("Verified \(files.count) source files in light and dark appearances, Finder launch and reopen")
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("FAIL source files: \(error)\n".utf8))
        exit(1)
    }
}
