# SPDX-License-Identifier: MIT
import importlib.util
from pathlib import Path
import unittest
from unittest.mock import patch, Mock
from types import SimpleNamespace
import struct

ROOT=Path(__file__).resolve().parents[2]
spec=importlib.util.spec_from_file_location('health',ROOT/'Resources/guest/health.py')
health=importlib.util.module_from_spec(spec);spec.loader.exec_module(health)
class HealthTests(unittest.TestCase):
    def sources(self,value='1'):
        return {'sentinel_guard':f'def read_config(): return {value!r}\ndef require_guard(v):\n if v != "1": raise ValueError("unsafe")\n',
                'key_info':'def read_keys(): return [{"typename":"fixture"}]',
                'alpine_ready':'def manager_ready(): return True'}
    def testUnsafeFirmwareSettingCannotBeReportedAsHealthy(self):
        self.assertEqual(health.observe(self.sources('0'))['status'],'unsafe')
    def testUnavailableFirmwareSettingCannotBeReportedAsHealthy(self):
        sources=self.sources();sources['sentinel_guard']='def read_config(): raise OSError()'
        self.assertEqual(health.observe(sources)['status'],'unsafe')
    def testAllIndependentReadinessEvidenceIsRequired(self):
        with patch.object(Path,'glob',return_value=[]),patch.object(Path,'exists',return_value=False):
            result=health.observe(self.sources())
        self.assertEqual(result['no_auto_fwup'],'1')
        self.assertTrue(result['managerReady'])
        self.assertFalse(result['services']);self.assertFalse(result['hotplug'])
    def testExistingModulesHaveNoImportSideEffects(self):
        for name in ('sentinel_guard','key_info','alpine_ready'):
            scope={'__name__':name}
            exec(compile((ROOT/f'Resources/guest/{name}.py').read_text(),name,'exec'),scope)
        self.assertTrue(callable(scope['manager_ready']))
    def process(self, name, pid):
        return SimpleNamespace(read_text=lambda: name, parent=SimpleNamespace(name=str(pid)))
    def testMissingRuntimeIsAServiceFailureWithoutReadingItsDeadAPI(self):
        sources=self.sources()
        sources['key_info']='def read_keys(): raise AssertionError("dead service must not be contacted")'
        with patch.object(Path,'glob',return_value=[]),patch.object(Path,'exists',return_value=False):
            result=health.observe(sources)
        self.assertEqual(result['status'],'ok')
        self.assertIn('hasplmd_x86_64',result['failedServices'])
        self.assertEqual(result['keys'],[])
    def testUnavailableRuntimeAPIIsDistinctFromUnsafeFirmware(self):
        sources=self.sources()
        sources['key_info']='def read_keys(): raise OSError("connection refused")'
        processes=[self.process(name,i) for i,name in enumerate(('aksusbd_x86_64','hasplmd_x86_64','rmlic'),1)]
        with patch.object(Path,'glob',side_effect=[processes,[]]),patch.object(Path,'exists',return_value=False):
            result=health.observe(sources)
        self.assertEqual(result['status'],'ok')
        self.assertEqual(result['failedServices'],['hasplmd_x86_64'])
    def testServiceExitSubscriptionBlocksOnceAndClosesEveryDescriptor(self):
        processes=[self.process(name,i) for i,name in enumerate(('aksusbd_x86_64','hasplmd_x86_64','rmlic'),1)]
        poller=Mock();poller.poll.return_value=[(11,1)]
        with patch.object(Path,'glob',return_value=processes), \
             patch.object(health.os,'pidfd_open',side_effect=[11,12,13],create=True) as opened, \
             patch.object(health.os,'close') as closed,patch.object(health.select,'poll',return_value=poller), \
             patch.object(health,'watch_protection',return_value=14), \
             patch('builtins.print') as output:
            health.watch_services()
        self.assertEqual(opened.call_count,3)
        self.assertEqual(poller.register.call_count,4)
        poller.poll.assert_called_once_with()
        self.assertEqual(closed.call_count,4)
        output.assert_called_once_with('{"watching": true}',flush=True)
    def testMissingServiceDoesNotPretendSubscriptionSucceeded(self):
        poller=Mock()
        with patch.object(Path,'glob',return_value=[]),patch.object(health.select,'poll',return_value=poller),patch('builtins.print') as output:
            health.watch_services()
        poller.poll.assert_not_called()
        self.assertIn('failedServices',output.call_args.args[0])
    def testProtectionReplacementAndDirectoryLossAreObservedButReadsAreNot(self):
        def event(mask,name=b''):
            name = name+b'\0' if name else b''
            return struct.pack('iIII',1,mask,0,len(name))+name
        self.assertTrue(health.protection_changed(event(0x80,b'hasplm.ini')))
        self.assertTrue(health.protection_changed(event(0x400)))
        self.assertTrue(health.protection_changed(event(0x4000)))
        self.assertFalse(health.protection_changed(event(0x8,b'unrelated.log')))
    def testProtectionSubscriptionWatchesDirectoryAndNeverAccessEvents(self):
        libc=Mock();libc.inotify_init1.return_value=41;libc.inotify_add_watch.return_value=1
        with patch.object(health.ctypes,'CDLL',return_value=libc):
            self.assertEqual(health.watch_protection(),41)
        fd,path,mask=libc.inotify_add_watch.call_args.args
        self.assertEqual((fd,path),(41,b'/etc/hasplm'))
        self.assertTrue(mask & 0x80)  # atomic replacement
        self.assertFalse(mask & 0x1)  # observing configuration never wakes itself
    def testConfigurationEventWakesOneBlockingSubscription(self):
        processes=[self.process(name,i) for i,name in enumerate(('aksusbd_x86_64','hasplmd_x86_64','rmlic'),1)]
        poller=Mock();poller.poll.return_value=[(14,1)]
        name=b'hasplm.ini\0'
        event=struct.pack('iIII',1,0x80,0,len(name))+name
        with patch.object(Path,'glob',return_value=processes), \
             patch.object(health.os,'pidfd_open',side_effect=[11,12,13],create=True), \
             patch.object(health.os,'close'),patch.object(health.select,'poll',return_value=poller), \
             patch.object(health,'watch_protection',return_value=14),patch.object(health.os,'read',return_value=event), \
             patch('builtins.print'):
            health.watch_services()
        poller.poll.assert_called_once_with()
if __name__=='__main__':unittest.main()
