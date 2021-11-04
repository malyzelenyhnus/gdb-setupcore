Helper utility to enable seamless application core debugging using gdb-10.1 and debuginfod.

Most of current linux distributions ship binaries stripped from debug information to make them much smaller. When something breaks the debug information must be installed in separate packages so debugger can show function and variable names instead of hexadecimal addresses.

[Debuginfod](https://sourceware.org/elfutils/Debuginfod.html) project introduces dedicated server that provides all required resources for debugging on demand over HTTP without need of root privileges and without limitation to your current system and architecture you are working on. This would allow to debug cores from crashed applications on developer's desktop regardless whether the cores are from OpenSUSE on s390x, Debian on arm64 or any other source as long as the debuginfod server will have required debug information.

However current GDB integration (gdb-10.1) of debuginfod is not yet perfect and gdb is unable to get binaries and libraries required for core debugging from debuginfod server.
So before running gdb this script has to prepare sysroot directory where are all these objects downloaded and symlinked under various SONAMES. Then gdb will be able to find them here by paths as it did before debuginfod was used.
Script also prepares init file with configuration to instruct gdb to search for resouces in that directory instead of system root.

## Requirements:
```
  >=elfutils-0.183
  >=debuginfod-client-0.183 (OpenSUSE Tumbleweed) or >=elfutils-debuginfod-client-0.183 (Fedora)
  >=gdb-10.1 with debuginfod support enabled
```

## Usage:
```
  # Prepare environment before first run
  $ export DEBUGINFOD_URLS=debuginfod-server.example.org
  $ gdb-setupcore.sh helloworld.core
  # run gdb
  $ gdb --command helloworld.core.ini
```
