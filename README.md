Helper utility to enable seamless application core debugging using gdb10.1 and debuginfod.

GDB integration of debuginfod is not yet perfect and gdb is unable to use all available resources from debuginfod server.
Known issues fixed by this script:
  * gdb is unable to determine executable binary's name and get it from debuginfod.
    I'd like to use just "gdb --core <core>" and let gdb to download the binary.
    Instead we have to download it in advance and pass it's path on commandline (or as "file" config option)
  * gdb is unable to obtain libraries. Even it they are available in sysroot, gdb tries to find them under various sonames different from the names in core.
