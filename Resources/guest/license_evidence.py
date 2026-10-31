#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Return aggregate proof counters, never license IDs, users, or raw LIC text.

These counters are diagnostic event observations, NOT current seat usage.
"""
import json,re,hashlib,os
from pathlib import Path
def collect_logs(root):
    result={'seize':0,'reuse':0,'error':0,'hardwareLocal':0,'files':0,'available':True}
    result['sources']=[]
    if not root.is_dir():result['available']=False
    for path in root.rglob('*.log'):
        result['files']+=1
        with path.open('rb') as stream:
            stat=os.fstat(stream.fileno())
            raw=stream.read()
        name=hashlib.sha256(str(path.relative_to(root)).encode()).hexdigest()
        previous=next((x for x in globals().get('BASELINE',{}).get('sources',[]) if x.get('name')==name),{})
        size=previous.get('bytes')
        baseline_digest=hashlib.sha256(raw[:size]).hexdigest() if isinstance(size,int) and 0<=size<=len(raw) else None
        result['sources'].append({'name':name,'inode':stat.st_ino,'bytes':len(raw),'digest':hashlib.sha256(raw).hexdigest(),'baselineDigest':baseline_digest})
        text=raw.decode('utf-8-sig',errors='replace')
        for event in re.split(r'(?m)(?=^\d\d:\d\d\.\d+-\d+,)',text):
            if ',LIC,' not in event[:100] or 'Func=getLicenses,' not in event:continue
            match=re.search(r'(?:^|,)res=(seize|reuse|error)(?:,|\r?\n|$)',event)
            if not match:continue
            result[match.group(1)]+=1
            if match.group(1)!='error' and 'hard, local, client' in event:result['hardwareLocal']+=1
            if match.group(1)!='reuse' and ', reuse,' in event:result['reuse']+=1
    return result


if __name__ == "__main__":
    result=collect_logs(Path("/var/log/keybridge-lic"))
    try:
        services={}
        for entry in Path('/proc').iterdir():
            if not entry.name.isdigit():continue
            try:
                command=(entry/'comm').read_text().strip()
                if command in ('rmlic','hasplmd_x86_64','aksusbd_x86_64'):
                    fields=(entry/'stat').read_text().rsplit(')',1)[1].split()
                    services[command]={'pid':int(entry.name),'start':fields[19]}
            except (OSError,IndexError):continue
        result['context']={'boot':Path('/proc/sys/kernel/random/boot_id').read_text().strip(),'services':services}
        if len(services)!=3:result['available']=False
    except OSError:result['available']=False
    print(json.dumps(result,separators=(',',':')))
