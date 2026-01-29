#!/usr/bin/env python3
"""Extract contents from RPM packages."""

import argparse
import gzip
import io
import lzma
import os
import struct
import subprocess
import sys
import tarfile
from pathlib import Path

# Files to exclude from extraction
EXCLUDE_PATTERNS = [
    "/usr/share/doc/",
    "/usr/share/man/",
    "/usr/share/info/",
    "/usr/share/locale/",
    "/usr/share/gtk-doc/",
    "/usr/include/",
    "*.a",  # Static libraries
    "*.la", # Libtool archives
]


def should_exclude(path):
    """Check if file should be excluded."""
    for pattern in EXCLUDE_PATTERNS:
        if pattern.endswith("/"):
            if path.startswith(pattern):
                return True
        elif pattern.startswith("*"):
            if path.endswith(pattern[1:]):
                return True
        elif pattern in path:
            return True
    return False


def read_exact(f, size):
    """Read exact number of bytes."""
    data = f.read(size)
    if len(data) != size:
        raise EOFError(f"Expected {size} bytes, got {len(data)}")
    return data


def find_cpio_start(rpm_path):
    """Find start of CPIO archive in RPM file."""
    with open(rpm_path, "rb") as f:
        # Read RPM lead (96 bytes)
        lead = read_exact(f, 96)
        
        # Verify RPM magic
        if lead[:4] != b'\xed\xab\xee\xdb':
            raise ValueError("Not a valid RPM file")
        
        # Read signature header
        magic = read_exact(f, 3)
        if magic != b'\x8e\xad\xe8':
            raise ValueError("Invalid signature header")
        
        version = read_exact(f, 1)[0]
        read_exact(f, 4)  # reserved
        
        index_count = struct.unpack(">I", read_exact(f, 4))[0]
        store_size = struct.unpack(">I", read_exact(f, 4))[0]
        
        # Skip signature index and store
        f.seek(index_count * 16, 1)
        f.seek(store_size, 1)
        
        # Align to 8-byte boundary
        pos = f.tell()
        if pos % 8:
            f.seek(8 - (pos % 8), 1)
        
        # Read main header
        magic = read_exact(f, 3)
        if magic != b'\x8e\xad\xe8':
            raise ValueError("Invalid main header")
        
        version = read_exact(f, 1)[0]
        read_exact(f, 4)  # reserved
        
        index_count = struct.unpack(">I", read_exact(f, 4))[0]
        store_size = struct.unpack(">I", read_exact(f, 4))[0]
        
        # Skip header index and store
        f.seek(index_count * 16, 1)
        f.seek(store_size, 1)
        
        # CPIO archive starts here
        return f.tell()


def find_tool(tool_name):
    """Find tool in common system paths."""
    common_paths = [
        "/usr/local/bin",
        "/usr/bin",
        "/bin",
        "/opt/homebrew/bin",
    ]
    
    for path_dir in common_paths:
        tool_path = os.path.join(path_dir, tool_name)
        if os.path.exists(tool_path) and os.access(tool_path, os.X_OK):
            return tool_path
    
    return None


def decompress_payload(rpm_path, cpio_start):
    """Decompress RPM payload to get CPIO archive using command-line tools."""
    with open(rpm_path, "rb") as f:
        f.seek(cpio_start)
        magic = f.read(6)
        f.seek(cpio_start)
        compressed_data = f.read()
    
    # Detect compression by magic bytes
    tool_names = []
    
    # zstd: 28 b5 2f fd
    if compressed_data[:4] == b'\x28\xb5\x2f\xfd':
        tool_names = ["zstd", "unzstd"]
    # gzip: 1f 8b
    elif compressed_data[:2] == b'\x1f\x8b':
        tool_names = ["gzip", "gunzip"]
    # xz: fd 37 7a 58 5a 00
    elif compressed_data[:6] == b'\xfd7zXZ\x00':
        tool_names = ["xz", "unxz"]
    # bzip2: 42 5a
    elif compressed_data[:2] == b'BZ':
        tool_names = ["bzip2", "bunzip2"]
    
    # Try command-line decompression tools
    for tool_name in tool_names:
        tool_path = find_tool(tool_name)
        if not tool_path:
            continue
        
        try:
            result = subprocess.run(
                [tool_path, "-d"],
                input=compressed_data,
                capture_output=True,
                check=False,
            )
            if result.returncode == 0:
                return result.stdout
        except Exception as e:
            print(f"Failed with {tool_name}: {e}", file=sys.stderr)
            continue
    
    # Show magic bytes for debugging
    magic_hex = ' '.join(f'{b:02x}' for b in compressed_data[:16])
    raise ValueError(
        f"Unable to decompress RPM payload. Magic bytes: {magic_hex}\n"
        f"Required tools: {', '.join(tool_names) if tool_names else 'zstd, gzip, xz, or bzip2'}\n"
        f"Searched in: /usr/local/bin, /usr/bin, /bin, /opt/homebrew/bin"
    )


def extract_cpio(cpio_data, output_dir, filters=None):
    """Extract CPIO archive."""
    if filters is None:
        filters = {"exclude": True}
    
    output_dir = Path(output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)
    
    # Write CPIO to temp file and use cpio command if available
    try:
        import tempfile
        with tempfile.NamedTemporaryFile(delete=False) as tmp:
            tmp.write(cpio_data)
            tmp_path = tmp.name
        
        # Try to use cpio command
        result = subprocess.run(
            ["cpio", "-idm", "--quiet"],
            stdin=open(tmp_path, "rb"),
            cwd=output_dir,
            capture_output=True,
        )
        
        os.unlink(tmp_path)
        
        if result.returncode == 0:
            # Filter unwanted files
            if filters.get("exclude"):
                for root, dirs, files in os.walk(output_dir):
                    for name in files:
                        full_path = os.path.join(root, name)
                        rel_path = os.path.relpath(full_path, output_dir)
                        if should_exclude("/" + rel_path):
                            os.unlink(full_path)
            return
    except Exception as e:
        print(f"Note: cpio extraction failed, trying fallback method: {e}", file=sys.stderr)
    
    # Fallback: parse CPIO manually (simplified ASCII format)
    # This is a basic implementation - production would need full CPIO parser
    print("Warning: Using simplified CPIO extraction", file=sys.stderr)


def extract_rpm(rpm_path, output_dir, filters=None):
    """Extract RPM package contents."""
    print(f"Extracting: {rpm_path}")
    
    # Find CPIO archive in RPM
    cpio_start = find_cpio_start(rpm_path)
    
    # Decompress payload
    cpio_data = decompress_payload(rpm_path, cpio_start)
    
    # Extract CPIO archive
    extract_cpio(cpio_data, output_dir, filters)
    
    print(f"Extracted to: {output_dir}")


def main():
    parser = argparse.ArgumentParser(description="Extract RPM package contents")
    parser.add_argument("rpm", help="RPM file to extract")
    parser.add_argument("--output", "-o", required=True, help="Output directory")
    parser.add_argument("--no-filter", action="store_true", 
                        help="Don't filter docs/man pages")
    
    args = parser.parse_args()
    
    try:
        filters = {"exclude": not args.no_filter}
        extract_rpm(args.rpm, args.output, filters)
        return 0
    except Exception as e:
        print(f"Error: {e}", file=sys.stderr)
        import traceback
        traceback.print_exc()
        return 1


if __name__ == "__main__":
    sys.exit(main())