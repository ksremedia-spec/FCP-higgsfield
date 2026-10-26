#!/usr/bin/env python3
"""Download Apple's FCPXML DTD (v1.10) from the Professional Video Applications
documentation and write it to the given path. Used by CI to validate the
FCPXML this project generates (`xmllint --dtdvalid`).

Usage: python3 tools/fetch_fcpxml_dtd.py out/fcpxml-1.10.dtd
"""
import json
import sys
import urllib.request

URL = ("https://developer.apple.com/tutorials/data/documentation/"
       "professional-video-applications/document-type-definition.json")


def main():
    out = sys.argv[1]
    with urllib.request.urlopen(URL, timeout=60) as r:
        doc = json.load(r)
    for section in doc.get("primaryContentSections", []):
        for block in section.get("content", []):
            if block.get("type") == "codeListing":
                code = "\n".join(block.get("code", []))
                if "<!ELEMENT fcpxml" in code:
                    with open(out, "w") as f:
                        f.write(code + "\n")
                    print(f"wrote {out} ({len(code)} bytes)")
                    return
    sys.exit("DTD code listing not found")


if __name__ == "__main__":
    main()
