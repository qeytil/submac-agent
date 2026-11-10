import sys, pathlib

def patch(path, old, new):
    p = Path(path) if False else pathlib.Path(path)
    s = p.read_text(); n = s.count(old)
    if n != 1:
        print("::error file=%s::pattern found %d times" % (path, n)); sys.exit(1)
    p.write_text(s.replace(old, new)); print("patched", path)

 = None