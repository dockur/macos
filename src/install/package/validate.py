import sys
import xml.etree.ElementTree as ET

distribution, package_info, expected = sys.argv[1:]

droot = ET.parse(distribution).getroot()
products = droot.findall("product")
if len(products) != 1 or products[0].get("id") != expected:
    raise SystemExit("Distribution product id is missing or incorrect")

refs = [
    element for element in droot.findall("pkg-ref")
    if (element.text or "").strip() == "#component.pkg"
]
if len(refs) != 1 or refs[0].get("id") != expected:
    raise SystemExit("Distribution component reference is missing or incorrect")

metadata_refs = [
    element for element in droot.findall("pkg-ref")
    if element.find("bundle-version") is not None
]
if len(metadata_refs) != 1 or metadata_refs[0].get("id") != expected:
    raise SystemExit("Distribution bundle metadata reference is missing")

proot = ET.parse(package_info).getroot()
if proot.get("identifier") != expected:
    raise SystemExit("PackageInfo identifier is incorrect")

post = proot.find("./scripts/postinstall")
if post is None or post.get("file") != "./postinstall":
    raise SystemExit("PackageInfo postinstall entry is missing")
