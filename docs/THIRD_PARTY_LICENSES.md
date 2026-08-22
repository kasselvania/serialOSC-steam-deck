# Third-party license notice

The SerialOSC CMake build incorporates these pinned dependencies:

- liblo, LGPL-2.1-or-later
- libmonome, ISC-style license
- libuv, MIT-style license with additional notices
- confuse, ISC license
- optparse, public-domain dedication

The generated package includes the upstream license files and a complete source archive with all submodules populated. The source archive and included `build.sh` provide the material needed to rebuild and relink the executables, including with a modified liblo.

The vendored confuse sources carry this notice:

> Copyright (c) 2002-2017 Martin Hedenfalk. Permission to use, copy, modify, and/or distribute this software for any purpose with or without fee is hereby granted, provided that the copyright notice and permission notice appear in all copies. The software is provided as-is, without warranty.
