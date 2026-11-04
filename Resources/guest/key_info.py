#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Read only non-identifying hardware attributes; never infer 1C seat usage."""
import json,sys,urllib.request,xml.etree.ElementTree as ET
def read_keys():
    fields=['typename','configuration','firmware','islocal']
    body='<admin><hasp>'+''.join('<element name="'+x+'"/>' for x in fields)+'</hasp></admin>'
    request=urllib.request.Request('http://127.0.0.1:1947/_int_/adminapi/get',data=body.encode(),headers={'Content-Type':'text/plain'})
    response=urllib.request.build_opener(urllib.request.ProxyHandler({})).open(request,timeout=5)
    root=ET.fromstring(response.read(2*1024*1024))
    if root.findtext('admin_status/code')!='0': raise SystemExit('Sentinel status unavailable')
    keys=[]
    for node in root.findall('.//hasp'):
        key={field:node.findtext(field) for field in fields}
        keys.append(key)
    return keys

if __name__ == "__main__":
    print(json.dumps({"keys": read_keys()}))
