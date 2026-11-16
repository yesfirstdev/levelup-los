"""Disposable CI only. Verify source bytes; reproduce approved migration adaptations."""
import hashlib,json,pathlib,subprocess,sys
root=pathlib.Path(__file__).resolve().parents[2]
p=root/'supabase/migrations'
m=json.loads((pathlib.Path(__file__).with_name('batch-validation-manifest.json')).read_text())
mode=sys.argv[1]
assert mode in ('sequential','batch')
archive=root/'.batch-validation-originals'
if not archive.exists():
 archive.mkdir()
 for item in m['manifest']:
  b=(p/item['original']).read_bytes()
  assert hashlib.sha256(b).hexdigest()==item['sha256'],item['original']
  (archive/item['original']).write_bytes(b)
# Only remove verified repository migration paths or our prior generated test path.
for f in p.glob('*.sql'):
 assert f.name in {x['original'] for x in m['manifest']} | {x['target'] for x in m['applied']} or f.name.endswith('_validated_migration_tail.sql'),f
 f.unlink()
parts=[]
for i,item in enumerate(m['manifest']):
 b=(archive/item['original']).read_bytes()
 assert hashlib.sha256(b).hexdigest()==item['sha256']
 s=b.decode()
 if item['diff']:
  # The manifest's exact unified diff is retained for review. Only two precise
  # scheduler calls may change; no function bodies or other DML are removed.
  lines=s.splitlines(keepends=True)
  removed=[l[1:] for l in item['diff'].splitlines() if l.startswith('-') and not l.startswith('---')]
  added=[l[1:] for l in item['diff'].splitlines() if l.startswith('+') and not l.startswith('+++')]
  assert len(removed)==1 and 'perform cron.schedule(' in removed[0]
  old=removed[0]+'\n'; new='\n'.join(added)+'\n'
  assert s.count(old)==1
  s=s.replace(old,new)
 b=s.encode()
 assert hashlib.sha256(b).hexdigest()==item['applied_sha256'],item['original']
 if mode=='sequential': (p/item['original']).write_bytes(b)
 elif i<22: (p/m['applied'][i]['target']).write_bytes(b)
 else: parts.append(b'\n-- BEGIN ORIGINAL '+item['original'].encode()+b'\n'+b+b'\n-- END ORIGINAL '+item['original'].encode()+b'\n')
if mode=='batch':
 subprocess.run(['npx','supabase','migration','new','validated_migration_tail'],cwd=root,check=True)
 candidates=list(p.glob('*_validated_migration_tail.sql'));assert len(candidates)==1
 assert candidates[0].name[:14]>m['applied'][-1]['version']
 tail=b''.join(parts);candidates[0].write_bytes(tail)
 digest=hashlib.sha256(tail).hexdigest()
 (root/'batch-validation-tail.sql').write_bytes(tail)
 (root/'batch-validation-result.json').write_text(json.dumps({'tail_sha256':digest,'tail_bytes':len(tail),'test_filename':candidates[0].name,'original_migrations':[x['original'] for x in m['manifest'][22:]]},indent=2)+'\n')
 print('TAIL_SHA256='+digest)
 print('TAIL_BYTES='+str(len(tail)))
assert len(list(p.glob('*.sql')))==(44 if mode=='sequential' else 23)
