# Define the executable version and pass command-line arguments and the exit
# status between Nim and the compositor entry point.

const VERSION* = "0.9.0"
include nimzo_core

when isMainModule:
  proc nimzoMain() =
    let args = @[getAppFilename()] & commandLineParams()
    let cargs = allocCStringArray(args)
    let code = main(cint(args.len), cast[ptr cstring](cargs))
    deallocCStringArray(cargs)
    quit(int(code))
  nimzoMain()
