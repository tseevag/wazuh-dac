import subprocess
import xml.etree.ElementTree as ET
from pathlib import Path
import sys
from collections import defaultdict, Counter

def run_git_command(args):
    result = subprocess.run(args, capture_output=True, text=True, check=True)
    return result.stdout

def get_changed_rule_files():
    try:
        output = run_git_command(["git", "diff", "--name-status", "origin/main...HEAD"])
        changed_files = []
        for line in output.strip().splitlines():
            parts = line.strip().split(maxsplit=1)
            if len(parts) != 2:
                continue
            status, file_path = parts
            if file_path.startswith("rules/") and file_path.endswith(".xml"):
                changed_files.append((status, Path(file_path)))
        return changed_files
    except subprocess.CalledProcessError as e:
        print("❌ Failed to get changed files:", e)
        sys.exit(1)

def extract_rule_ids_from_xml(content):
    ids = []
    try:
        # Wrap multiple root elements in a fake <root> tag to avoid parse errors
        wrapped = f"<root>{content}</root>"
        root = ET.fromstring(wrapped)
        for rule in root.findall(".//rule"):
            rule_id = rule.get("id")
            if rule_id and rule_id.isdigit():
                ids.append(int(rule_id))
    except ET.ParseError as e:
        print(f"⚠️ XML Parse Error: {e}")
    return ids


def get_rule_ids_per_file_in_main():
    run_git_command(["git", "fetch", "origin", "main"])
    files_output = run_git_command(["git", "ls-tree", "-r", "origin/main", "--name-only"])
    xml_files = [f for f in files_output.splitlines() if f.startswith("rules/") and f.endswith(".xml")]

    rule_id_to_files = defaultdict(set)
    for file in xml_files:
        try:
            content = run_git_command(["git", "show", f"origin/main:{file}"])
            rule_ids = extract_rule_ids_from_xml(content)
            for rule_id in rule_ids:
                rule_id_to_files[rule_id].add(file)
        except subprocess.CalledProcessError:
            continue
    return rule_id_to_files

def get_rule_ids_from_main_version(file_path: Path):
    try:
        content = run_git_command(["git", "show", f"origin/main:{file_path.as_posix()}"])
        return extract_rule_ids_from_xml(content)
    except subprocess.CalledProcessError:
        return []

def detect_duplicates(rule_ids):
    counter = Counter(rule_ids)
    return [rule_id for rule_id, count in counter.items() if count > 1]

def print_conflicts(conflicting_ids, rule_id_to_files):
    print("❌ Conflicts detected:")
    for rule_id in sorted(conflicting_ids):
        files = rule_id_to_files.get(rule_id, [])
        print(f"  - Rule ID {rule_id} found in:")
        for f in files:
            print(f"    • {f}")

def main():
    changed_files = get_changed_rule_files()
    if not changed_files:
        print("✅ No rule files were changed in this PR.")
        return

    rule_id_to_files_main = get_rule_ids_per_file_in_main()

    print(f"🔍 Checking rule ID conflicts for files: {[f.name for _, f in changed_files]}")

    for status, path in changed_files:
        print(f"\n🔎 Checking file: {path.name}")

        try:
            dev_content = path.read_text()
            dev_ids = extract_rule_ids_from_xml(dev_content)
        except Exception as e:
            print(f"⚠️ Could not read {path.name}: {e}")
            continue

        # Check for internal duplicates
        duplicates = detect_duplicates(dev_ids)
        if duplicates:
            print(f"❌ Duplicate rule IDs detected in {path.name}: {sorted(duplicates)}")
            sys.exit(1)

        if status == "A":
            # New file
            conflicting_ids = set(dev_ids) & set(rule_id_to_files_main.keys())
            if conflicting_ids:
                print_conflicts(conflicting_ids, rule_id_to_files_main)
                sys.exit(1)
            else:
                print(f"✅ No conflict in new file {path.name}")

        elif status == "M":
            # Modified file
            main_ids = get_rule_ids_from_main_version(path)
            if set(dev_ids) == set(main_ids):
                print(f"ℹ️ {path.name} modified but rule IDs unchanged.")
                continue

            new_or_changed_ids = set(dev_ids) - set(main_ids)
            conflicting_ids = new_or_changed_ids & set(rule_id_to_files_main.keys())

            if conflicting_ids:
                print_conflicts(conflicting_ids, rule_id_to_files_main)
                sys.exit(1)
            else:
                print(f"✅ Modified file {path.name} has no conflicting rule IDs.")

    print("\n✅ All rule file changes passed conflict checks.")

if __name__ == "__main__":
    main()
