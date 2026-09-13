#!/usr/bin/env python3
"""Download and process programming language documentation into text files for Qstar corpus."""

import os
import re
import shutil
import html
import subprocess

BASE = "/home/admpaul/CascadeProjects/basic/qstar-llm/datasets/programming"

def strip_html(html_text):
    """Minimal HTML to text conversion."""
    # Remove script and style blocks
    html_text = re.sub(r'<script[^>]*>.*?</script>', '', html_text, flags=re.DOTALL | re.IGNORECASE)
    html_text = re.sub(r'<style[^>]*>.*?</style>', '', html_text, flags=re.DOTALL | re.IGNORECASE)
    html_text = re.sub(r'<nav[^>]*>.*?</nav>', '', html_text, flags=re.DOTALL | re.IGNORECASE)
    html_text = re.sub(r'<footer[^>]*>.*?</footer>', '', html_text, flags=re.DOTALL | re.IGNORECASE)
    # Replace common block elements with newlines
    html_text = re.sub(r'<br\s*/?>', '\n', html_text, flags=re.IGNORECASE)
    html_text = re.sub(r'</(p|div|h[1-6]|li|tr|blockquote|pre)>', '\n', html_text, flags=re.IGNORECASE)
    html_text = re.sub(r'<(p|div|h[1-6]|li|tr|blockquote|pre)[^>]*>', '\n', html_text, flags=re.IGNORECASE)
    # Remove all remaining tags
    html_text = re.sub(r'<[^>]+>', '', html_text)
    # Decode HTML entities
    html_text = html.unescape(html_text)
    # Clean up whitespace
    html_text = re.sub(r'\n{3,}', '\n\n', html_text)
    html_text = re.sub(r'[ \t]+', ' ', html_text)
    html_text = re.sub(r' *\n *', '\n', html_text)
    return html_text.strip()

def process_zig_langref():
    """Convert Zig language reference HTML to text."""
    src = "/tmp/zig_langref.html"
    dst = os.path.join(BASE, "zig", "zig_langref.txt")
    if not os.path.isfile(src):
        print("Zig langref: source not found")
        return
    with open(src, 'r', encoding='utf-8') as f:
        html_text = f.read()
    text = strip_html(html_text)
    with open(dst, 'w', encoding='utf-8') as f:
        f.write(text)
    size = os.path.getsize(dst)
    print(f"Zig langref: {size / 1024:.0f} KB -> {dst}")

def process_zig_book():
    """Copy zig-book chapters (.qmd files) as text."""
    src_dir = "/tmp/zig_book/Chapters"
    dst_dir = os.path.join(BASE, "zig", "zig_book")
    os.makedirs(dst_dir, exist_ok=True)
    count = 0
    if not os.path.isdir(src_dir):
        # Try alternate locations
        for alt in ["/tmp/zig_book", "/tmp/zig_book/docs"]:
            if os.path.isdir(alt):
                src_dir = alt
                break
    for fname in os.listdir(src_dir):
        if fname.endswith('.qmd') or fname.endswith('.md'):
            src = os.path.join(src_dir, fname)
            dst = os.path.join(dst_dir, fname.replace('.qmd', '.txt'))
            shutil.copy2(src, dst)
            count += 1
    print(f"Zig book: {count} chapters -> {dst_dir}")

def process_rust_book():
    """Copy Rust book markdown chapters."""
    src_dir = "/tmp/rust_book/src"
    dst_dir = os.path.join(BASE, "rust", "rust_book")
    os.makedirs(dst_dir, exist_ok=True)
    count = 0
    for fname in sorted(os.listdir(src_dir)):
        if fname.endswith('.md'):
            src = os.path.join(src_dir, fname)
            dst = os.path.join(dst_dir, fname.replace('.md', '.txt'))
            shutil.copy2(src, dst)
            count += 1
    print(f"Rust book: {count} chapters -> {dst_dir}")

def process_python_docs():
    """Extract Python docs text archive."""
    src_dir = "/tmp/python_docs_extracted/python-3.14-docs-text"
    dst_dir = os.path.join(BASE, "python", "python_docs")
    os.makedirs(dst_dir, exist_ok=True)
    count = 0
    if not os.path.isdir(src_dir):
        print(f"Python docs: source not found at {src_dir}")
        return
    for root, dirs, files in os.walk(src_dir):
        for fname in files:
            if fname.endswith('.txt'):
                src = os.path.join(root, fname)
                rel = os.path.relpath(src, src_dir)
                dst = os.path.join(dst_dir, rel)
                os.makedirs(os.path.dirname(dst), exist_ok=True)
                shutil.copy2(src, dst)
                count += 1
    print(f"Python docs: {count} text files -> {dst_dir}")

def process_c_docs():
    """Convert Beej's C Guide HTML to text."""
    src = "/tmp/beej_c_guide.html"
    dst = os.path.join(BASE, "c", "beej_c_guide.txt")
    if not os.path.isfile(src):
        print("Beej's C guide: source not found")
        return
    with open(src, 'r', encoding='utf-8') as f:
        html_text = f.read()
    text = strip_html(html_text)
    with open(dst, 'w', encoding='utf-8') as f:
        f.write(text)
    size = os.path.getsize(dst)
    print(f"Beej's C guide: {size / 1024:.0f} KB -> {dst}")

def process_qsharp_docs():
    """Copy Q# documentation markdown files."""
    src_repo = "/tmp/qsharp_repo"
    dst_dir = os.path.join(BASE, "qsharp", "quantum_docs")
    os.makedirs(dst_dir, exist_ok=True)
    count = 0
    # Copy relevant .md files (exclude test/node_modules/.github)
    for root, dirs, files in os.walk(src_repo):
        # Skip irrelevant directories
        if '/.github' in root or '/node_modules' in root or '/test' in root:
            continue
        for fname in files:
            if fname.endswith('.md'):
                src = os.path.join(root, fname)
                rel = os.path.relpath(src, src_repo)
                dst = os.path.join(dst_dir, rel.replace('/', '_'))
                shutil.copy2(src, dst)
                count += 1
            elif fname.endswith('.qs'):
                src = os.path.join(root, fname)
                rel = os.path.relpath(src, src_repo)
                dst = os.path.join(dst_dir, rel.replace('/', '_').replace('.qs', '.txt'))
                shutil.copy2(src, dst)
                count += 1
    print(f"Q# docs: {count} files -> {dst_dir}")

def process_csharp_docs():
    """Download and convert key C# documentation pages from Microsoft Learn."""
    pages = [
        ("https://learn.microsoft.com/en-us/dotnet/csharp/fundamentals/tutorials/hello-world", "csharp_hello_world.html"),
        ("https://learn.microsoft.com/en-us/dotnet/csharp/fundamentals/tutorials/numbers-in-csharp", "csharp_numbers.html"),
        ("https://learn.microsoft.com/en-us/dotnet/csharp/fundamentals/tutorials/branches-and-loops", "csharp_branches.html"),
        ("https://learn.microsoft.com/en-us/dotnet/csharp/fundamentals/tutorials/list-collections", "csharp_collections.html"),
        ("https://learn.microsoft.com/en-us/dotnet/csharp/fundamentals/tutorials/classes-objects", "csharp_classes.html"),
        ("https://learn.microsoft.com/en-us/dotnet/csharp/tour-of-csharp/", "csharp_tour.html"),
        ("https://learn.microsoft.com/en-us/dotnet/csharp/language-reference/language-version-history/", "csharp_version_history.html"),
        ("https://learn.microsoft.com/en-us/dotnet/csharp/programming-guide/", "csharp_programming_guide.html"),
        ("https://learn.microsoft.com/en-us/dotnet/csharp/programming-guide/classes-and-structs/classes", "csharp_classes_structs.html"),
        ("https://learn.microsoft.com/en-us/dotnet/csharp/programming-guide/classes-and-structs/using-objects", "csharp_objects.html"),
        ("https://learn.microsoft.com/en-us/dotnet/csharp/programming-guide/arrays/", "csharp_arrays.html"),
        ("https://learn.microsoft.com/en-us/dotnet/csharp/programming-guide/strings/", "csharp_strings.html"),
        ("https://learn.microsoft.com/en-us/dotnet/csharp/language-reference/keywords/", "csharp_keywords.html"),
        ("https://learn.microsoft.com/en-us/dotnet/csharp/language-reference/operators/", "csharp_operators.html"),
        ("https://learn.microsoft.com/en-us/dotnet/csharp/language-reference/statements/declarations", "csharp_declarations.html"),
        ("https://learn.microsoft.com/en-us/dotnet/csharp/miscellaneous/", "csharp_misc.html"),
        ("https://learn.microsoft.com/en-us/dotnet/csharp/fundamentals/program-structure/", "csharp_program_structure.html"),
        ("https://learn.microsoft.com/en-us/dotnet/csharp/fundamentals/types/", "csharp_types.html"),
        ("https://learn.microsoft.com/en-us/dotnet/csharp/fundamentals/functional-techniques/", "csharp_functional.html"),
        ("https://learn.microsoft.com/en-us/dotnet/csharp/fundamentals/object-oriented/", "csharp_oop.html"),
    ]
    dst_dir = os.path.join(BASE, "csharp")
    os.makedirs(dst_dir, exist_ok=True)
    combined = os.path.join(dst_dir, "csharp_docs.txt")
    count = 0
    with open(combined, 'w', encoding='utf-8') as out:
        for url, fname in pages:
            html_path = f"/tmp/{fname}"
            try:
                subprocess.run(["curl", "-sL", "-o", html_path, url], timeout=30, check=True)
                with open(html_path, 'r', encoding='utf-8') as f:
                    html_text = f.read()
                text = strip_html(html_text)
                if len(text) > 100:
                    out.write(f"\n\n=== {url} ===\n\n")
                    out.write(text)
                    out.write("\n")
                    count += 1
            except Exception as e:
                print(f"  C# page failed: {url}: {e}")
    size = os.path.getsize(combined)
    print(f"C# docs: {count} pages, {size / 1024:.0f} KB -> {combined}")

def main():
    os.makedirs(BASE, exist_ok=True)
    process_zig_langref()
    process_zig_book()
    process_rust_book()
    process_python_docs()
    process_c_docs()
    process_qsharp_docs()
    process_csharp_docs()

    # Print total sizes
    print("\n--- Total sizes ---")
    for lang in ["zig", "rust", "python", "csharp", "c", "qsharp"]:
        lang_dir = os.path.join(BASE, lang)
        if os.path.isdir(lang_dir):
            total = 0
            for root, dirs, files in os.walk(lang_dir):
                for f in files:
                    total += os.path.getsize(os.path.join(root, f))
            print(f"  {lang}: {total / 1024 / 1024:.1f} MB")

if __name__ == "__main__":
    main()
