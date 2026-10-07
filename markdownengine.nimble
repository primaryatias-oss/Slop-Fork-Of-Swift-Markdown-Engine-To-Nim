# Package

version       = "0.14.0"
author        = "Ported to Nim from nodes-app/swift-markdown-engine"
description   = "A live-styling Markdown editor engine and SDL3 editor for Linux"
license       = "Apache-2.0"
srcDir        = "src"
installExt    = @["nim"]
bin           = @["mdedit"]

# Dependencies
#
# The engine and the UI layer use the Nim standard library only. The SDL3
# bindings from https://github.com/nim-lang/sdl3 are vendored in `vendor/`
# (MIT), so a checkout builds with no package fetch; SDL3 itself must be
# installed on the system (libSDL3.so is loaded dynamically).

requires "nim >= 2.2.0"

task test, "Run the engine test suite":
  exec "nim c -r --hints:off tests/test_all.nim"

task demo, "Build and run the SDL3 editor":
  exec "nim c -r -d:release --hints:off src/mdedit.nim"
