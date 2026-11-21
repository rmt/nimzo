# Keep POSIX spawn headers separate from the generated compositor ABI.
import std/[os, posix]

proc waylandSocketPair*(fds: var array[2, cint]): cint =
  socketpair(AF_UNIX, SOCK_STREAM or SOCK_CLOEXEC, 0, fds)

proc spawnWaylandProcess*(arguments: openArray[string]; fd: cint): cint =
  var actions: Tposix_spawn_file_actions
  result = posix_spawn_file_actions_init(actions)
  if result != 0: return
  defer: discard posix_spawn_file_actions_destroy(actions)

  # A spawn dup2 action to the same FD clears CLOEXEC in the child only.
  let childFd = max(fd, 3)
  result = posix_spawn_file_actions_adddup2(actions, fd, childFd)
  if result != 0: return

  var environment: seq[string]
  for name, value in envPairs():
    if name != "WAYLAND_SOCKET": environment.add name & "=" & value
  environment.add "WAYLAND_SOCKET=" & $childFd
  let envp = allocCStringArray(environment)
  defer: deallocCStringArray(envp)
  let argv = allocCStringArray(arguments)
  defer: deallocCStringArray(argv)

  var pid: Pid
  var attr: Tposix_spawnattr
  result = posix_spawnattr_init(attr)
  if result != 0: return
  defer: discard posix_spawnattr_destroy(attr)
  result = posix_spawn(pid, argv[0], actions, attr, argv, envp)
