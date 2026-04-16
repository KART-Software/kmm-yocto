# Disable gprofng - fails to cross-compile for aarch64 (libcollector has no 'all' target)
EXTRA_OECONF:append = " --disable-gprofng"
