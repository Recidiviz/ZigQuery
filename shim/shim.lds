/* ELF export list for libgooglesql_shim.so.
 *
 * The Mach-O build spells this as a series of `-Wl,-exported_symbol,_Name`
 * linkopts; ld.bfd/lld want a version script instead. Note the missing
 * leading underscore: Mach-O prefixes C symbols with `_`, ELF does not.
 *
 * Hiding everything else is what lets --gc-sections discard the unreachable
 * bulk of the analyzer, the same way -dead_strip does on macOS. Without it
 * every absl/protobuf/ICU symbol stays live and the library is enormous.
 */
{
    global:
        GoogleSQL_*;
    local:
        *;
};
