#!/usr/bin/env python3
"""Exercises the installed native CLI; no app, account, network or third-party Python packages."""
import base64
import hashlib
import json
import os
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import unittest
import zipfile

CLI = Path(sys.argv.pop(1)).resolve()

class NativeCLITests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='scriptwidget-cli-test-')
        self.root = Path(self.temp.name)
        self.package = self.root / '组件 with spaces'
        self.package.mkdir()
        self.manifest = dict(formatVersion=2, id='com.example.cli-test', name='CLI Test', version='1.0.0', runtimeVersion='1.0', entry='main.jsx', supportedFamilies=['systemSmall','systemMedium','systemLarge'], permissions=[], networkDomains=[])
        self.save_manifest()
        self.source('$render(<text font="title">Native test</text>);')
    def tearDown(self): self.temp.cleanup()
    def save_manifest(self): (self.package/'widget.json').write_text(json.dumps(self.manifest))
    def source(self, text): (self.package/'main.jsx').write_text(text)
    def run_cli(self, command, *arguments, code=0):
        result=subprocess.run([str(CLI),command,*([str(self.package)] if command not in ['doctor','--version'] else []),*map(str,arguments),'--format','json'],capture_output=True,text=True,timeout=75)
        self.assertEqual(result.returncode,code,(result.stdout,result.stderr))
        report=json.loads(result.stdout)
        self.assertEqual(report['reportVersion'],1)
        return report
    def test_preview_link_has_validated_snapshot_and_no_script_execution(self):
        self.source('throw new Error("preview must not execute locally");')
        report=self.run_cli('preview','--no-open')
        self.assertFalse(report['browserLaunchRequested'])
        self.assertEqual(report['checks']['execute'],'notRun')
        self.assertEqual(report['checks']['render'],'notRun')
        self.assertEqual(report['backend'],'web-handoff')
        prefix='https://xnu.app/scriptwidget/studio/#sw-preview=v1.'
        self.assertTrue(report['previewURL'].startswith(prefix))
        payload=report['previewURL'][len(prefix):]
        import io
        with zipfile.ZipFile(io.BytesIO(base64.urlsafe_b64decode(payload+'='*((4-len(payload)%4)%4)))) as archive:
            self.assertEqual(archive.read('main.jsx').decode(),(self.package/'main.jsx').read_text())
        self.source('$render(<text>wrong</vstack>);')
        self.assertNotIn('previewURL',self.run_cli('preview','--no-open',code=1))
    def test_preview_link_limit_is_explicit_and_other_commands_reject_no_open(self):
        (self.package/'random.bin').write_bytes(os.urandom(46000))
        report=self.run_cli('preview','--no-open',code=1)
        self.assertEqual(report['diagnostics'][0]['code'],'preview.link_limit')
        self.run_cli('check','--no-open',code=2)
    def test_static_check_and_archive_do_not_execute(self):
        self.source('throw new Error("must not execute in check or pack");')
        report=self.run_cli('check')
        self.assertEqual(report['checks']['execute'],'notRun')
        archive=self.root/'Widget.swt'
        self.run_cli('pack','--output',archive)
        with zipfile.ZipFile(archive) as package:
            self.assertEqual(package.read('main.jsx').decode(),(self.package/'main.jsx').read_text())
            self.assertIn('widget.json',package.namelist())
        self.run_cli('pack','--output',archive,code=2)
    def test_native_png_and_binary_content_fingerprint(self):
        report=self.run_cli('render','--output',self.root/'out')
        self.assertEqual(len(report['artifacts']),2)
        for artifact in report['artifacts']:
            png=Path(report['reportPath']).parent/artifact['path']
            data=png.read_bytes()
            self.assertEqual(data[:8],b'\x89PNG\r\n\x1a\n')
            self.assertEqual(struct.unpack('>II',data[16:24]),(720,338))
            self.assertEqual(hashlib.sha256(data).hexdigest(),artifact['sha256'])
        first=report['sourceHash']
        self.assertEqual(self.run_cli('check')['sourceHash'],first)
        (self.package/'asset.bin').write_bytes(bytes([0,255,3]))
        self.assertNotEqual(self.run_cli('check')['sourceHash'],first)
    def test_bad_manifest_and_bad_js_fail_closed(self):
        (self.package/'widget.json').write_text('{"formatVersion":99}')
        self.run_cli('check',code=1)
        self.save_manifest(); self.source('$render(<text>broken</vstack>);')
        self.run_cli('check',code=1)
    def test_symlink_and_hardlink_are_rejected(self):
        outside=self.root/'secret.txt';outside.write_text('must stay outside')
        (self.package/'escape').symlink_to(outside)
        self.run_cli('check',code=1)
        (self.package/'escape').unlink();os.link(outside,self.package/'escape')
        self.run_cli('check',code=1)
    def test_symlink_output_parent_and_source_output_are_rejected(self):
        self.run_cli('render','--output',self.package/'out',code=2)
        real=self.root/'real';real.mkdir();link=self.root/'link';link.symlink_to(real,target_is_directory=True)
        self.run_cli('render','--output',link/'out',code=2)
        self.assertEqual(list(real.iterdir()),[])
    def test_failed_render_does_not_reuse_old_png(self):
        first=self.run_cli('render','--output',self.root/'out')
        self.source('throw new Error("new edit failed");')
        failed=self.run_cli('render','--output',self.root/'out',code=1)
        self.assertEqual(failed['artifacts'],[])
        self.assertNotEqual(first['sourceHash'],failed['sourceHash'])
        self.assertNotEqual(first['reportPath'],failed['reportPath'])
    def test_mock_cannot_bypass_manifest_or_replace_permission_callback(self):
        self.source('Array.prototype.includes=()=>true; __validationPermit=()=>true; const p=await $location.current(); $render(<text>{p.latitude}</text>);')
        fixture=self.root/'fixtures.json';fixture.write_text(json.dumps({'api':{'$location.current':{'value':{'latitude':10,'longitude':20}}}}))
        self.run_cli('render','--fixtures',fixture,'--output',self.root/'out',code=1)
        self.manifest['permissions']=['location'];self.save_manifest()
        self.run_cli('render','--fixtures',fixture,'--output',self.root/'out')
    def test_unknown_mock_is_not_silently_ignored(self):
        fixture=self.root/'bad.json';fixture.write_text('{"dataSource":[]}')
        self.run_cli('render','--fixtures',fixture,'--output',self.root/'out',code=1)
    def test_storage_is_ephemeral_and_imported_code_uses_mock_host(self):
        self.manifest['permissions']=['storage'];self.save_manifest()
        (self.package/'helper.jsx').write_text('function incrementCounter() { $storage.setString("count",String(Number($storage.getString("count")||0)+1)); return $storage.getString("count"); }')
        self.source('$import("helper.jsx"); $render(<text>{incrementCounter()}</text>);')
        first=self.run_cli('render','--output',self.root/'out')
        second=self.run_cli('render','--output',self.root/'out')
        self.assertEqual([a['sha256'] for a in first['artifacts']],[a['sha256'] for a in second['artifacts']])
    def test_sandbox_denies_private_external_files(self):
        private=self.root/'private.txt';private.write_text('private sentinel')
        worker=CLI.parent.parent/'Helpers/ScriptWidgetValidationWorker.app/Contents/MacOS/ScriptWidgetValidationWorker'
        request=dict(command='probe',files=[],family='medium',appearance='light',parameter='',fixtures=base64.b64encode(b'{}').decode(),scale=2,probePath=str(private))
        result=subprocess.run([str(worker)],input=json.dumps(request),capture_output=True,text=True,timeout=15)
        report=json.loads(result.stdout)
        self.assertFalse(report['outsideRead']);self.assertFalse(report['outsideWrite'])
        self.assertFalse(Path(str(private)+'.worker-write').exists())
    def test_missing_images_are_visible_diagnostics(self):
        self.source('$render(<image name="missing.png" />);')
        report=self.run_cli('render','--output',self.root/'out')
        self.assertTrue(any(issue['code']=='image.resource_missing' for issue in report['diagnostics']))
        self.run_cli('render','--output',self.root/'out','--fail-on-warning',code=1)
    def test_mock_data_query_budget_is_not_removed(self):
        self.manifest['permissions']=['location'];self.save_manifest()
        self.source('for(let n=0;n<9;n++) await $location.current(); $render(<text>Too many queries</text>);')
        self.run_cli('render','--output',self.root/'out',code=1)
    def test_missing_render_and_unknown_native_tag_are_failures(self):
        self.source('const noWidget=42;')
        self.run_cli('render','--output',self.root/'out',code=1)
        self.source('$render(<madeuptag>Hello</madeuptag>);')
        self.run_cli('render','--output',self.root/'out',code=1)
    def test_runtime_16_system_fixtures_remain_offline_and_writes_are_denied(self):
        self.manifest.update(minimumRuntimeVersion='1.6', permissions=['notifications'])
        self.save_manifest()
        self.source('const status=await $notifications.status(); if(status.authorization!=="authorized")throw new Error("mock status"); let denied=false; try{await $notifications.schedule({key:"test",title:"Test",body:"Body",daily:{hour:20,minute:0}});}catch(e){denied=String(e).includes("read_only");} if(!denied)throw new Error("write allowed"); $render(<text>Offline only</text>);')
        self.run_cli('render','--output',self.root/'out')
        self.manifest.pop('minimumRuntimeVersion'); self.save_manifest()
        self.source('await $notifications.status(); $render(<text>unexpected</text>);')
        self.run_cli('render','--output',self.root/'version-denied',code=1)
        self.manifest.update(minimumRuntimeVersion='1.6',permissions=[]); self.save_manifest()
        self.run_cli('render','--output',self.root/'permission-denied',code=1)

    def test_execution_deadline_and_current_environment(self):
        self.run_cli('doctor')
        self.source('while(true) {}')
        report=self.run_cli('render','--output',self.root/'out','--timeout','1',code=124)
        self.assertEqual(report['status'],'error')

if __name__=='__main__': unittest.main(verbosity=2)
