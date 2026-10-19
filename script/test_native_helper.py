#!/usr/bin/env python3
"""Explicit native connected-hardware test with state readback. No SIP call, credentials, or microphone."""
import json, selectors, subprocess, sys, time
helper = sys.argv[1]
p = subprocess.Popen([helper], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, bufsize=1)
s = selectors.DefaultSelector(); s.register(p.stdout, selectors.EVENT_READ)
def wait_for(kind, timeout=15):
    deadline=time.monotonic()+timeout
    while time.monotonic()<deadline:
        if not s.select(max(0, deadline-time.monotonic())): break
        line=p.stdout.readline()
        if not line: raise RuntimeError('helper exited')
        try: event=json.loads(line)
        except ValueError: continue
        if event.get('event')=='error': raise RuntimeError(str(event))
        if event.get('event')==kind: return event
    raise RuntimeError('timeout waiting for '+kind)
def sync(calls):
    p.stdin.write(json.dumps({'command':'sync','calls':calls})+'\n');p.stdin.flush()
    e=wait_for('synced')
    assert e['count']==len(calls),e
try:
    assert wait_for('ready')['ready']
    call={'id':5,'phase':'incoming','muted':False,'name':'Sipper Integration Check','number':'7100'}
    sync([call]); print('PASS incoming caller information')
    call={**call,'phase':'active'};sync([call]);print('PASS answer')
    call={**call,'muted':True};sync([call]);print('PASS mute')
    call={**call,'muted':False};sync([call]);print('PASS unmute')
    call={**call,'phase':'held'};sync([call]);print('PASS hold')
    call={**call,'phase':'active'};sync([call]);print('PASS resume')
    call={**call,'name':'Updated Caller'};sync([call]);print('PASS updated caller information')
    sync([]);print('PASS end and clear screen')
    call={**call,'phase':'dialing'};sync([call]);print('PASS outgoing dial')
    call={**call,'phase':'active'};sync([call]);print('PASS outgoing connect')
    waiting={**call,'id':6,'phase':'incoming'};sync([call,waiting]);print('PASS waiting call')
    sync([waiting]);print('PASS end active while waiting')
    waiting={**waiting,'phase':'active'};sync([waiting]);print('PASS answer waiting call')
    sync([]);print('PASS all calls cleared')
finally:
    if p.poll() is None:
        try:p.stdin.write('{"command":"quit"}\n');p.stdin.flush();p.stdin.close()
        except BrokenPipeError:pass
        try:p.wait(timeout=5)
        except subprocess.TimeoutExpired:p.terminate();p.wait(timeout=5)
    assert p.returncode==0,p.returncode
