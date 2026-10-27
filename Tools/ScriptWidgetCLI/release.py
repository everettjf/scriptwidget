#!/usr/bin/env python3
"""Build, test, sign and optionally notarize CLI release assets. Never reads credentials."""
import argparse
import hashlib
import json
import plistlib
from pathlib import Path
import shutil
import subprocess
import zipfile

ROOT=Path(__file__).resolve().parents[2]
VERSION='0.2.0'
IDENTITY='Developer ID Application: Feng Zhu (YPV49M8592)'

def run(*arguments,**kwargs):
    return subprocess.run([str(value) for value in arguments],check=True,**kwargs)

def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--output',type=Path,required=True)
    parser.add_argument('--derived-data',type=Path,default=Path('/tmp/scriptwidget-cli-build'))
    parser.add_argument('--notarize',action='store_true')
    parser.add_argument('--profile',default='ScriptWidgetCLI')
    args=parser.parse_args()
    commit=subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip()
    if args.notarize and subprocess.check_output(['git','status','--porcelain'],cwd=ROOT):
        raise SystemExit('Notarized releases require a clean, committed checkout.')
    out=args.output.resolve();out.mkdir(parents=True,exist_ok=True)
    run('node',ROOT/'Tools/ScriptWidgetCLI/prepare-resources.mjs',cwd=ROOT)
    run('xcodegen','generate','--spec',ROOT/'Tools/ScriptWidgetCLI/project.yml',cwd=ROOT)
    with (out/'build.log').open('w') as log:
        run('xcodebuild','-project',ROOT/'Tools/ScriptWidgetCLI/ScriptWidgetCLI.xcodeproj','-scheme','ScriptWidgetCLI','-configuration','Release','-derivedDataPath',args.derived_data,'ARCHS=arm64 x86_64','ONLY_ACTIVE_ARCH=NO',f'CLI_BUILD_COMMIT={commit}','build',stdout=log,stderr=subprocess.STDOUT)
    product=args.derived_data/'Build/Products/Release/ScriptWidgetCLI.app'
    assets=[]
    for arch in ['arm64','x86_64']:
        stage=out/f'stage-{arch}'
        if stage.exists(): raise SystemExit(f'Release staging directory already exists: {stage}')
        stage.mkdir()
        app=stage/'ScriptWidgetCLI.app'
        run('ditto',product,app)
        worker=app/'Contents/Helpers/ScriptWidgetValidationWorker.app'
        for bundle in [app,worker]:
            info=bundle/'Contents/Info.plist'
            with info.open('rb') as stream: metadata=plistlib.load(stream)
            metadata['ScriptWidgetBuildCommit']=commit
            with info.open('wb') as stream: plistlib.dump(metadata,stream)
        for executable in [app/'Contents/MacOS/scriptwidget',worker/'Contents/MacOS/ScriptWidgetValidationWorker']:
            thin=executable.with_suffix('.thin')
            run('lipo',executable,'-thin',arch,'-output',thin)
            thin.replace(executable)
        licenses=app/'Contents/Resources/licenses';licenses.mkdir(parents=True,exist_ok=True)
        for source,name in [
            (ROOT/'LICENSE','ScriptWidget-Apache-2.0.txt'),
            (ROOT/'NOTICE','ScriptWidget-NOTICE.txt'),
            (ROOT/'LICENSES/MIT-previous.txt','ScriptWidget-previous-MIT.txt'),
            (args.derived_data/'SourcePackages/checkouts/SwiftyJSON/LICENSE','SwiftyJSON-MIT.txt'),
            (args.derived_data/'SourcePackages/checkouts/ZipArchive/LICENSE.txt','ZipArchive.txt'),
            (args.derived_data/'SourcePackages/checkouts/ZipArchive/SSZipArchive/minizip/LICENSE','minizip.txt'),
            (ROOT/'Shared/ScriptWidgetRuntime/Widget/Component/Attributes/Animation/ClockHandKit-LICENSE.txt','ClockHandKit.txt')]:
            shutil.copyfile(source,licenses/name)
        run('codesign','--force','--options','runtime','--timestamp','--sign',IDENTITY,'--entitlements',ROOT/'Tools/ScriptWidgetCLI/Worker.entitlements',worker)
        run('codesign','--force','--options','runtime','--timestamp','--sign',IDENTITY,app)
        run('codesign','--verify','--strict','--deep',app)
        binary=app/'Contents/MacOS/scriptwidget'
        identity=json.loads(subprocess.check_output([str(binary),'--version','--format','json'],text=True))
        if identity.get('tool',{}).get('buildCommit')!=commit or identity.get('version')!=VERSION:
            raise SystemExit('Release binary identity does not match its source commit/version.')
        with (out/f'tests-{arch}.log').open('w') as log:
            run('python3',ROOT/'Tools/ScriptWidgetCLI/Tests/smoke.py',binary,stdout=log,stderr=subprocess.STDOUT)
        shutil.copyfile(ROOT/'LICENSE',stage/'LICENSE')
        (stage/'README.txt').write_text('ScriptWidget CLI '+VERSION+'\nInstall with Homebrew: brew install everettjf/tap/scriptwidget-cli\nMac App remains available separately through the Mac App Store.\nBuild commit: '+commit+'\n')
        archive=out/f'scriptwidget-cli-{VERSION}-macos-{arch}.zip'
        if args.notarize:
            submission=out/f'notary-{arch}.zip'
            run('ditto','-c','-k','--keepParent',app,submission)
            result=subprocess.check_output(['xcrun','notarytool','submit',str(submission),'--keychain-profile',args.profile,'--wait','--output-format','json'],text=True)
            receipt=json.loads(result);(out/f'notary-{arch}.json').write_text(json.dumps(receipt,indent=2)+'\n')
            if receipt.get('status')!='Accepted':raise SystemExit('Apple notarization did not accept this artifact; inspect its receipt.')
            for bundle in [worker,app]:
                run('xcrun','stapler','staple',bundle)
                run('xcrun','stapler','validate',bundle)
            submission.unlink()
        run('ditto','-c','-k',stage,archive)
        # Re-extract the exact bytes we will publish, then revalidate signatures/tickets.
        extracted=out/f'archive-check-{arch}';extracted.mkdir()
        run('ditto','-x','-k',archive,extracted)
        run('codesign','--verify','--strict','--deep',extracted/'ScriptWidgetCLI.app')
        if args.notarize:run('xcrun','stapler','validate',extracted/'ScriptWidgetCLI.app')
        assets.append(dict(file=archive.name,sha256=hashlib.sha256(archive.read_bytes()).hexdigest(),architecture=arch))
    skill=out/f'scriptwidget-creator-{VERSION}.zip'
    with zipfile.ZipFile(skill,'w',compression=zipfile.ZIP_DEFLATED) as archive:
        for source in sorted((ROOT/'Skills/scriptwidget-creator').rglob('*')):
            if source.is_file():archive.write(source,source.relative_to(ROOT/'Skills').as_posix())
    assets.append(dict(file=skill.name,sha256=hashlib.sha256(skill.read_bytes()).hexdigest()))
    (out/'release-manifest.json').write_text(json.dumps(dict(version=VERSION,commit=commit,notarized=args.notarize,assets=assets),indent=2)+'\n')
    (out/'SHA256SUMS').write_text(''.join(f"{asset['sha256']}  {asset['file']}\n" for asset in assets))
    print('Release assets verified:',out)

if __name__=='__main__':main()
