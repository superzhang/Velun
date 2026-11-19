#!/usr/bin/env python3
"""Copy recursive Homebrew dylibs into the app and remove absolute dependencies."""
from pathlib import Path
import subprocess, shutil, sys, json, plistlib
app = Path(sys.argv[1]).resolve()
frameworks = app / 'Contents/Frameworks'
frameworks.mkdir(parents=True, exist_ok=True)
with (app / 'Contents/Info.plist').open('rb') as info:
    main = app / 'Contents/MacOS' / plistlib.load(info)['CFBundleExecutable']
seen = {}
inventory = []
def run(*args): return subprocess.check_output(args, text=True)
def dependencies(file):
    return [line.strip().split(' (')[0] for line in run('otool', '-L', str(file)).splitlines()[1:]]
def copy_library(path):
    source = Path(path)
    name = source.name
    if name in seen:
        if seen[name] != source.resolve(): raise RuntimeError(f'Conflicting library: {name}')
        return frameworks / name
    seen[name] = source.resolve()
    target = frameworks / name
    shutil.copy2(source, target)
    target.chmod(0o755)
    inventory.append({'file': name, 'source': str(source.resolve())})
    # Preserve license files. Installation receipts can contain local user paths.
    parts = source.resolve().parts
    if 'Cellar' in parts:
        index = parts.index('Cellar')
        root = Path(*parts[:index+3])
        license_dir = app / 'Contents/Resources/ThirdParty' / root.parent.name
        license_dir.mkdir(parents=True, exist_ok=True)
        for candidate in root.rglob('*'):
            if candidate.is_file() and candidate.name.lower().startswith(('copying', 'license', 'copyright')):
                relative = candidate.relative_to(root)
                destination = license_dir / relative
                destination.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(candidate, destination)
    subprocess.run(['install_name_tool','-id','@rpath/'+name,str(target)],check=True)
    rewrite(target, False)
    return target
def rewrite(file, executable):
    for dep in dependencies(file):
        if dep.startswith('/opt/homebrew/'):
            copy_library(dep)
            replacement = ('@executable_path/../Frameworks/' if executable else '@loader_path/') + Path(dep).name
            subprocess.run(['install_name_tool','-change',dep,replacement,str(file)],check=True,stderr=subprocess.DEVNULL)
rewrite(main, True)
helpers = [app / "Contents/Helpers" / name for name in ("ffmpeg", "ffprobe")]
for helper in helpers:
    rewrite(helper, True)
# No absolute Homebrew paths are allowed in load commands.
for file in [main, *helpers, *frameworks.glob('*.dylib')]:
    assert not any(dep.startswith('/opt/homebrew/') for dep in dependencies(file)), file
(app / 'Contents/Resources/ThirdParty-libraries.json').write_text(json.dumps(inventory,indent=2))
print(f'Bundled {len(seen)} dynamic libraries')
