include "tools/build_support.nims"

switch("define", "release")
switch("mm", "arc")
if getEnv("NIMZO_XWAYLAND", "1") != "0":
  switch("define", "XWAYLAND")
let flags = nativeFlags()
switch("passC", flags.cflags)
switch("passL", flags.libs)
generateProtocols()
