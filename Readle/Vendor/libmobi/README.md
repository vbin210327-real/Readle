# libmobi in Readle

Upstream: https://github.com/bfabiszewski/libmobi
Pinned revision: 906274205c11944b628da1c553b255acb1af7c55
Copyright (c) 2014-2022 Bartek Fabiszewski and contributors.
License: LGPL version 3 or later; see COPYING and COPYING.GPL.

Only the required C library sources and headers are included, unchanged.
Encryption, conversion tools, OPF generation and third-party compression
runtimes are excluded. The system zlib and libxml2 are used.
Readle/Core/MOBIBridge.c is the Readle integration, separate from this library.
No downloaded ebooks or build products belong in this directory.
