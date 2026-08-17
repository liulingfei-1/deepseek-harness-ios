# Third-Party Notices

The current app target may not yet link every generated dependency described
below. The repository builds an iSH XCFramework and Alpine rootfs for the
on-device command sandbox, so the applicable source and license notices are
retained with the integration code and must accompany any distributed build.

## OpenMinis

Source: https://github.com/OpenMinis/OpenMinis  
Revision used: `9cf3a855fecd27bb5735b84cacbd56852a3ab8dd`  
License: GNU General Public License, version 3

The iOS kernel and shell-executor compatibility behavior is adapted from the
OpenMinis sources at the revision above. The complete GPLv3 text is the locked
upstream `LICENSE` file and is also available at:

https://github.com/OpenMinis/OpenMinis/blob/9cf3a855fecd27bb5735b84cacbd56852a3ab8dd/LICENSE

Local modifications are replayable patches under
`Vendor/OpenMinisISH/patches/` and the build procedure is
`Scripts/build-ish-sandbox.sh`.

## iSH ARM64

Source: https://github.com/OpenMinis/ish-arm64  
Revision used: `de124dd66124a15239cea1465164f74980ada245`  
Primary license: GNU General Public License, version 3  
Additional licensing: GPLv2 availability for qualifying contributions and the
iOS distribution terms stated by the iSH copyright holders

The authoritative notices are:

- `LICENSE.md`: https://github.com/OpenMinis/ish-arm64/blob/de124dd66124a15239cea1465164f74980ada245/LICENSE.md
- `LICENSE.IOS`: https://github.com/OpenMinis/ish-arm64/blob/de124dd66124a15239cea1465164f74980ada245/LICENSE.IOS

`LICENSE.IOS` states that the iSH developers will not pursue a violation that
results solely from a conflict between the GPL and Apple App Store terms, as
long as the distributor complies with the GPL in every other respect,
including providing source code and the license text. This project is intended
for personal Xcode sideloading, but sharing a build with another person still
requires a GPL-compliant source offer and these notices.

## DeepSeek Harness

Source: https://github.com/deepseek-ai/deepseek-harness  
Revision reviewed: `47f943859bef60e4160492346772ded9b24f765a`

MIT License

Copyright (c) 2026 DeepSeek

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

## SwiftAgentCore

Source: https://github.com/herrkaefer/SwiftAgentCore  
Revision reviewed: `6bdd505ac196d15ab9b4bd184eba8b23bb8c2ff8`

MIT License

Copyright (c) 2026 herrkaefer

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
