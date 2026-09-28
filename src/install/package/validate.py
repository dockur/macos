import sys
import xml.etree.ElementTree as ET


distribution, package_info, expected = sys.argv[1:]

droot = ET.parse(distribution).getroot()
if droot.tag != "installer-gui-script":
    raise SystemExit("Distribution root element is incorrect")

products = droot.findall("product")
if (
    len(products) != 1
    or products[0].get("id") != expected
    or products[0].get("version") != "1.0"
):
    raise SystemExit("Distribution product metadata is missing or incorrect")

options = droot.findall("options")
if (
    len(options) != 1
    or options[0].get("customize") != "never"
    or options[0].get("require-scripts") != "false"
):
    raise SystemExit("Distribution options are missing or incorrect")

refs = [
    element
    for element in droot.findall("pkg-ref")
    if (element.text or "").strip() == "#component.pkg"
]
if len(refs) != 1 or refs[0].get("id") != expected:
    raise SystemExit("Distribution component reference is missing or incorrect")

ref = refs[0]
if (
    ref.get("version") != "1.0"
    or ref.get("installKBytes") != "0"
    or ref.get("onConclusion") != "none"
):
    raise SystemExit("Distribution component metadata is missing or incorrect")

metadata_refs = [
    element
    for element in droot.findall("pkg-ref")
    if element.find("bundle-version") is not None
]
if len(metadata_refs) != 1 or metadata_refs[0].get("id") != expected:
    raise SystemExit("Distribution bundle metadata reference is missing")

choices = [
    element
    for element in droot.findall("choice")
    if element.get("id") == expected
]
if len(choices) != 1 or choices[0].get("visible") != "false":
    raise SystemExit("Distribution package choice is missing or incorrect")

choice_refs = choices[0].findall("pkg-ref")
if len(choice_refs) != 1 or choice_refs[0].get("id") != expected:
    raise SystemExit("Distribution package choice reference is missing or incorrect")

proot = ET.parse(package_info).getroot()
if proot.tag != "pkg-info":
    raise SystemExit("PackageInfo root element is incorrect")

if (
    proot.get("identifier") != expected
    or proot.get("version") != "1.0"
    or proot.get("format-version") != "2"
    or proot.get("install-location") != "/"
    or proot.get("auth") != "root"
):
    raise SystemExit("PackageInfo metadata is missing or incorrect")

payloads = proot.findall("payload")
if (
    len(payloads) != 1
    or payloads[0].get("installKBytes") != "0"
    or payloads[0].get("numberOfFiles") != "0"
):
    raise SystemExit("PackageInfo no-payload metadata is missing or incorrect")

scripts = proot.findall("scripts")
if len(scripts) != 1:
    raise SystemExit("PackageInfo scripts metadata is missing or duplicated")

post = scripts[0].findall("postinstall")
if len(post) != 1 or post[0].get("file") != "./postinstall":
    raise SystemExit("PackageInfo postinstall entry is missing or incorrect")
