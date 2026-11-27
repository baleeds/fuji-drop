import Foundation

/// Notices for third-party code in the app, shown in Settings › Acknowledgements.
///
/// LibRaw is used under CDDL 1.0, which asks for its notice and for saying where its source
/// is available; LibRaw's sources are unchanged (Sources/CLibRaw/VENDORED.md). Its DCB
/// demosaic code (compiled in) is BSD-licensed and its Adobe DNG SDK pieces MIT-licensed, and
/// both need their notices reproduced. (LibRaw's X3F code is compiled out.)
public enum Acknowledgements {
    public struct Notice: Identifiable, Sendable {
        public var id: String { title }
        public var title: String
        public var text: String
    }

    public static var notices: [Notice] {
        [
            Notice(title: "LibRaw", text: """
                Fuji Drop uses LibRaw \(XTransDecoder.libRawVersion) to decode RAW files for HDR \
                merges, under the Common Development and Distribution License (CDDL) version 1.0. \
                LibRaw is unmodified. Its source code is available from https://www.libraw.org and \
                https://github.com/LibRaw/LibRaw.

                LibRaw: Raw images processing library
                Copyright (C) 2008-2025 LibRaw LLC (http://www.libraw.org, info@libraw.org)

                LibRaw is free software; you can redistribute it and/or modify it under the terms \
                of the one of two licenses as you choose: 1. GNU LESSER GENERAL PUBLIC LICENSE \
                version 2.1; 2. COMMON DEVELOPMENT AND DISTRIBUTION LICENSE (CDDL) Version 1.0.

                LibRaw uses code from dcraw.c -- Dave Coffin's raw photo decoder, dcraw.c is \
                copyright 1997-2018 by Dave Coffin, dcoffin a cybercom o net. LibRaw do not use \
                RESTRICTED code from dcraw.c

                LibRaw uses DCB demosaic and FBDD denoise licensed under BSD-like 3-clause license. \
                DCB and FBDD are Copyright (C) 2010, Jacek Gozdz (cuniek@kft.umcs.lublin.pl)

                LibRaw uses pieces of code from Adobe DNG SDK 1.4, Copyright (c) 2005 Adobe Systems \
                Incorporated, licensed under MIT license
                """),
            Notice(title: "DCB demosaic and FBDD denoise (in LibRaw)", text: """
                Copyright (C) 2010, Jacek Gozdz (cuniek@kft.umcs.lublin.pl)
                FBDD denoising by Jacek Gozdz and Luis Sanz Rodríguez (luis.sanz.rodriguez@gmail.com)

                Redistribution and use in source and binary forms, with or without modification, \
                are permitted provided that the following conditions are met:

                * Redistributions of source code must retain the above copyright notice, this list \
                of conditions and the following disclaimer.
                * Redistributions in binary form must reproduce the above copyright notice, this \
                list of conditions and the following disclaimer in the documentation and/or other \
                materials provided with the distribution.
                * Neither the name of the author nor the names of its contributors may be used to \
                endorse or promote products derived from this software without specific prior \
                written permission.

                THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY \
                EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES \
                OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT \
                SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, \
                INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED \
                TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR \
                BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN \
                CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN \
                ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH \
                DAMAGE.
                """),
            Notice(title: "Adobe DNG SDK (parts used by LibRaw)", text: """
                Copyright (c) 2005 Adobe Systems Incorporated

                Permission is hereby granted, free of charge, to any person obtaining a copy of \
                this software and associated documentation files (the "Software"), to deal in the \
                Software without restriction, including without limitation the rights to use, copy, \
                modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, \
                and to permit persons to whom the Software is furnished to do so, subject to the \
                following conditions:

                The above copyright notice and this permission notice shall be included in all \
                copies or substantial portions of the Software.

                THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, \
                INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A \
                PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT \
                HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION \
                OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE \
                SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
                """),
        ]
    }
}
