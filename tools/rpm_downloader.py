#!/usr/bin/env python3
"""RPM package downloader for Rocky Linux repositories."""

import argparse
import hashlib
import os
import sys
import urllib.request
import xml.etree.ElementTree as ET
from pathlib import Path
from urllib.parse import urljoin

# Rocky Linux 9 repository URLs
ROCKY_9_REPOS = {
    "baseos": "https://download.rockylinux.org/pub/rocky/9/BaseOS/x86_64/os/",
    "appstream": "https://download.rockylinux.org/pub/rocky/9/AppStream/x86_64/os/",
}

REPODATA_PATH = "repodata/repomd.xml"
DEFAULT_CACHE_DIR = Path.home() / ".cache" / "fedora-distroless" / "rpms"


def download_file(url, dest_path, expected_checksum=None, checksum_type="sha256"):
    """Download file with checksum verification."""
    dest_path.parent.mkdir(parents=True, exist_ok=True)
    
    if dest_path.exists() and expected_checksum:
        if verify_checksum(dest_path, expected_checksum, checksum_type):
            print(f"Using cached: {dest_path.name}")
            return dest_path
    
    print(f"Downloading: {url}")
    urllib.request.urlretrieve(url, dest_path)
    
    if expected_checksum and not verify_checksum(dest_path, expected_checksum, checksum_type):
        dest_path.unlink()
        raise ValueError(f"Checksum mismatch for {url}")
    
    return dest_path


def verify_checksum(file_path, expected, checksum_type="sha256"):
    """Verify file checksum."""
    h = hashlib.new(checksum_type)
    with open(file_path, "rb") as f:
        for chunk in iter(lambda: f.read(8192), b""):
            h.update(chunk)
    return h.hexdigest() == expected


def parse_repomd(repo_url, cache_dir):
    """Parse repomd.xml to find primary.xml location."""
    repomd_url = urljoin(repo_url, REPODATA_PATH)
    repomd_path = cache_dir / "repodata" / "repomd.xml"
    
    download_file(repomd_url, repomd_path)
    
    tree = ET.parse(repomd_path)
    root = tree.getroot()
    ns = {"repo": "http://linux.duke.edu/metadata/repo"}
    
    for data in root.findall("repo:data", ns):
        if data.get("type") == "primary":
            location = data.find("repo:location", ns).get("href")
            checksum = data.find("repo:checksum", ns).text
            checksum_type = data.find("repo:checksum", ns).get("type")
            return location, checksum, checksum_type
    
    raise ValueError("Primary metadata not found in repomd.xml")


def parse_primary_xml(xml_path, package_name):
    """Parse primary.xml to find package information."""
    import gzip
    
    # Handle compressed XML
    if xml_path.suffix == ".gz":
        with gzip.open(xml_path, "rt") as f:
            tree = ET.parse(f)
    else:
        tree = ET.parse(xml_path)
    
    root = tree.getroot()
    ns = {"": "http://linux.duke.edu/metadata/common"}
    
    packages = []
    for pkg in root.findall("package", ns):
        name_elem = pkg.find("name", ns)
        if name_elem is not None and name_elem.text == package_name:
            location = pkg.find("location", ns).get("href")
            checksum_elem = pkg.find("checksum", ns)
            checksum = checksum_elem.text
            checksum_type = checksum_elem.get("type")
            
            packages.append({
                "name": name_elem.text,
                "location": location,
                "checksum": checksum,
                "checksum_type": checksum_type,
            })
    
    return packages


def download_rpm(repo_url, package_name, output_dir=None):
    """Download an RPM package from repository."""
    if output_dir is None:
        cache_dir = DEFAULT_CACHE_DIR
        output_dir = cache_dir
    else:
        output_dir = Path(output_dir)
        cache_dir = output_dir
    
    # Get primary.xml metadata
    primary_location, primary_checksum, primary_checksum_type = parse_repomd(repo_url, cache_dir)
    primary_url = urljoin(repo_url, primary_location)
    primary_path = cache_dir / "repodata" / Path(primary_location).name
    
    download_file(primary_url, primary_path, primary_checksum, primary_checksum_type)
    
    # Find package in metadata
    packages = parse_primary_xml(primary_path, package_name)
    
    if not packages:
        raise ValueError(f"Package '{package_name}' not found in repository")
    
    # Download first match
    pkg = packages[0]
    rpm_url = urljoin(repo_url, pkg["location"])
    rpm_path = output_dir / Path(pkg["location"]).name
    
    download_file(rpm_url, rpm_path, pkg["checksum"], pkg["checksum_type"])
    
    return rpm_path


def main():
    parser = argparse.ArgumentParser(description="Download RPM packages from Rocky Linux")
    parser.add_argument("package", help="Package name to download")
    parser.add_argument("--repo", choices=ROCKY_9_REPOS.keys(), default="baseos",
                        help="Repository to search")
    parser.add_argument("--output", "-o", help="Output directory")
    
    args = parser.parse_args()
    
    try:
        repo_url = ROCKY_9_REPOS[args.repo]
        rpm_path = download_rpm(repo_url, args.package, args.output)
        print(f"\nSuccess: {rpm_path}")
        return 0
    except Exception as e:
        print(f"Error: {e}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())