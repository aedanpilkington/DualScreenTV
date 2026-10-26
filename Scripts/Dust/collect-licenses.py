"""Collect source-package notices for the statically linked experimental core."""
import json, pathlib, subprocess, sys
manifest, destination, toolchain = sys.argv[1:]
metadata=json.loads(subprocess.check_output(['cargo','+'+toolchain,'metadata','--format-version','1','--manifest-path',manifest]))
parts=['Dust GPU core third-party notices\n\nDust is GPL-3.0-or-later. Its license is bundled separately as Dust-LICENSE.txt.\nSource: https://github.com/kelpsyberry/dust\nRevision: 76d79f25e4ea3ce355c4ac868f5ac9a233e64b89\n\nLocal adapter and platform patches: Scripts/Dust and Scripts/Patches/dust-gpu-benchmark.patch.\n']
for package in sorted(metadata['packages'],key=lambda p:(p['name'],p['version'])):
 root=pathlib.Path(package['manifest_path']).parent
 files={p for p in root.iterdir() if p.is_file() and p.name.upper().startswith(('LICENSE','COPYING','NOTICE','UNLICENSE','COPYRIGHT'))}
 if package.get('license_file'): files.add(root/package['license_file'])
 for sub in ('LICENSES','licenses'):
  folder=root/sub
  if folder.is_dir(): files.update(p for p in folder.rglob('*') if p.is_file())
 parts.append(f"\n{'='*72}\n{package['name']} {package['version']}\nLicense: {package.get('license')}\nRepository: {package.get('repository')}\n")
 for p in sorted(files):
  if p.exists():parts.append(f'\n--- {p.name} ---\n'+p.read_text(errors='replace'))
sysroot=pathlib.Path(subprocess.check_output(['rustc','+'+toolchain,'--print','sysroot'],text=True).strip())
licenses=sysroot/'share/doc/rust/licenses'
parts.append('\nRust standard library and compiler builtins: https://github.com/rust-lang/rust\n')
for name in ('MIT.txt','Apache-2.0.txt','LLVM-exception.txt'):
 p=licenses/name
 if p.exists():parts.append(f'\n--- Rust {name} ---\n'+p.read_text())
pathlib.Path(destination).write_text('\n'.join(parts))
