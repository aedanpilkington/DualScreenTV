# Third-party components

This repository contains frontend source, integration patches, build scripts and
supporting assets. It does not contain prebuilt emulator libraries, commercial
games, proprietary console firmware dumps, or console keys. Build scripts fetch
upstream code at these pins; their transitive dependencies are selected by the
upstream build files and included lockfiles.

| Component | Source / revision | Licence information |
| --- | --- | --- |
| melonDS DS | https://github.com/JesseTG/melonds-ds — `a3c57f066870c18d3104895f52a1fe08794e2cdc` | GPL-3.0; generated combined notice copied to CoreLicenses during build |
| DeSmuME | https://github.com/libretro/desmume — `95b4d798731caa809125b6c3c11d17cc332ff6ef` | Bundled DeSmuME-LICENSE.txt |
| Dust | https://github.com/kelpsyberry/dust — `76d79f25e4ea3ce355c4ac868f5ac9a233e64b89` | Bundled Dust-LICENSE.txt and Dust-THIRD-PARTY-LICENSES.txt |
| mGBA | https://github.com/mgba-emu/mgba — `26b7884bc25a5933960f3cdcd98bac1ae14d42e2` | CoreLicenses/mGBA-MPL-2.0.txt |
| PPSSPP | https://github.com/hrydgard/ppsspp — `dd6bd1a53d38773c1d07985fcb7d2f56fcaa872c` | CoreLicenses/PPSSPP-GPL-2.0.txt and PPSSPPThirdParty.txt |
| Azahar | https://github.com/azahar-emu/azahar — `219d743a1e698101fe1ab8bef43e6563126c3c27` (2126.2) | CoreLicenses/Azahar.txt and AzaharThirdParty.txt |
| MoltenVK | https://github.com/KhronosGroup/MoltenVK — 1.4.1 | CoreLicenses/MoltenVK.txt; archive SHA-256 checked in scripts |
| SPIRV-Cross | https://github.com/KhronosGroup/SPIRV-Cross — `ebe2aa0cd80f5eb5cd8a605da604cacf72205f3b` | CoreLicenses/SPIRV-Cross-Apache-2.0.txt |
| sse2neon | https://github.com/DLTcollab/sse2neon — `60fc9391e378b58c60899791c0e9ee9cdaf43c08` | Bundled SSE2NEON-LICENSE.txt |
| FFmpeg (PPSSPP dependency) | PPSSPP's pinned FFmpeg dependency | CoreLicenses/FFmpeg-LGPL-2.1.txt and upstream notices |

Notices are in `Apps/tvOS/DualScreenTV/DualScreenTV/` and its `CoreLicenses/`
folder. Source patches and integration adapters are under `Scripts/`. PPSSPP
resources include upstream replacement fonts, shaders, language files and
compatibility data; preserve their embedded notices. They are not game ROMs.
The unverified experimental 3D model assets are excluded from this source release.

Original DualScreenTV code is licensed under [MIT](LICENSE). Each third-party
component, upstream-derived patch and resource retains its own licence. MIT
does not relicense those materials. The [GNU licence list](https://www.gnu.org/licenses/license-list.html#Expat)
identifies MIT/Expat as GPL-compatible; each component still has its own terms.
If you redistribute compiled cores, preserve all applicable notices and meet
their source-distribution requirements; this source-only repository does not
supply a compiled-core release.
