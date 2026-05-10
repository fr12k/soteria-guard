import re, sys, os

# Fix StringHashMap.empty -> StringHashMap.init(a) in all source files
root = "/Users/frankittermann/github/soteria-guard/src"
files = ["git_log.zig", "churn.zig", "main.zig", "trend.zig"]

for fname in files:
    path = os.path.join(root, fname)
    with open(path, 'r') as f:
        content = f.read()
    
    # Fix StringHashMap back to .init(a)
    content = re.sub(r'StringHashMap\((\w+)\)\.empty', r'StringHashMap(\1).init(a)', content)
    
    with open(path, 'w') as f:
        f.write(content)

print("Fixed StringHashMap.empty -> StringHashMap.init(a)")
