#!/usr/bin/env python3
################################################################################
# Script: package_check.py
# Description: Validates Salesforce package.xml files for compliance with
#              deployment standards and automatically determines required Apex
#              test classes. Performs multiple validation checks including:
#              - Schema compliance and namespace validation
#              - Wildcard detection (not allowed in deployments)
#              - Apex test class extraction using @tests annotation
#              - ConnectedApp consumer key removal for security
#              - Workflow parent type blocking (must use children types)
#              - Default test class execution for destructive deployments
#              - Optional CMT-driven tests: see package_check_cmt_tests.json
#                When an ApexClass/ApexTrigger in the package matches a rule,
#                Turn_on__c (or configured field) is read from the CMT file if
#                that record is in the package, else from the default org (sf).
# Usage:
#   python package_check.py -x manifest/package.xml -s deploy -e production
# Arguments:
#   -x, --manifest: Path to package.xml file (default: manifest/package.xml)
#   -s, --stage: Pipeline stage (deploy/destroy)
#   -e, --environment: Target environment (production/sandbox)
#   -c, --cmt-tests-config: JSON rules file (default: alongside this script)
# Dependencies: Python 3.x, xml.etree.ElementTree
# Output: Space-separated list of test classes or "not a test"
################################################################################
import argparse
import json
import logging
import os
import re
import shutil
import subprocess
import sys
import xml.etree.ElementTree as ET
from concurrent.futures import ThreadPoolExecutor, as_completed
from typing import Any, Dict, List, Optional, Tuple

APEX_TYPES = ["apexclass", "apextrigger"]
PARENT_WORKFLOW = "workflow"
CHILDREN_WORKFLOW = [
    "WorkflowAlert",
    "WorkflowFieldUpdate",
    "WorkflowKnowledgePublish",
    "WorkflowOutboundMessage",
    "WorkflowRule",
    "WorkflowSend",
    "WorkflowTask",
    "WorkflowFlowAction",
]

logging.basicConfig(level=logging.DEBUG, format="%(message)s")
ns = {"sforce": "http://soap.sforce.com/2006/04/metadata"}
ET.register_namespace("", "http://soap.sforce.com/2006/04/metadata")


def parse_args():
    """
    Build the argument parser and return parsed CLI values.

    Returns:
        Namespace with ``manifest``, ``stage``, ``environment``, ``cmt_tests_config``.
    """
    parser = argparse.ArgumentParser(
        description="A script to determine required Apex tests."
    )
    parser.add_argument("-x", "--manifest", default="manifest/package.xml")
    parser.add_argument("-s", "--stage", default="deploy")
    parser.add_argument("-e", "--environment", default=None)
    parser.add_argument(
        "-c",
        "--cmt-tests-config",
        default="package_check_cmt_tests.json",
        help="JSON file listing Apex members, CMT records, and tests when switch on/off",
    )
    args = parser.parse_args()
    return args


def parse_package(package_path: str) -> tuple:
    """
    Load and parse a Salesforce ``package.xml`` manifest.

    Args:
        package_path: Filesystem path to the manifest.

    Returns:
        Tuple of (root element, local root tag name e.g. ``Package``, XML namespace URI).

    Exits:
        On malformed XML or root tag/namespace that cannot be parsed.
    """
    try:
        root = ET.parse(package_path).getroot()
        try:
            namespace, local_name = root.tag.rsplit("}", 1)
            namespace = namespace[1:]
        except ValueError:
            logging.info(
                "ERROR: Unable to parse root and namespace details,Please correct them..!!!"
            )
            sys.exit(1)
    except ET.ParseError:
        logging.info(
            "ERROR: Unable to parse %s. Push a new commit to fix the package formatting.",
            package_path,
        )
        sys.exit(1)
    return root, local_name, namespace


def validate_metadata_attributes(root: ET.Element) -> None:
    """
    Ensure the package root only contains allowed direct children.

    Only ``<types>`` and ``<version>`` are permitted at the top level under ``<Package>``.
    Any other element fails validation (catches typos or non-standard wrappers).

    Args:
        root: Parsed ``<Package>`` element.

    Exits:
        If an unexpected child tag is found.
    """

    traditional_tags = ("types", "version")
    for child in root:
        parsed_label = child.tag.rsplit("}", 1)[1]
        if parsed_label not in traditional_tags:
            logging.info(
                "ERROR: Unable to parse : <%s> tag, Expected tags are : %s. "
                "Please review and update them..!!!",
                parsed_label,
                traditional_tags,
            )
            sys.exit(1)


def validate_root(local_name: str) -> None:
    """
    Confirm the document root element is named ``Package`` (Salesforce manifest contract).

    Args:
        local_name: Local name portion of the root XML tag (after namespace).

    Exits:
        If the root is not ``Package``.
    """
    if "Package" != local_name:
        logging.info(
            "ERROR: Root name is '%s' whereas It should be 'Package', "
            "Please correct Root details..!!!",
            local_name,
        )
        sys.exit(1)


def validate_namespace(namespace: str) -> None:
    """
    Require the package to use the standard Salesforce Metadata API namespace URI.

    Args:
        namespace: Namespace string parsed from the root element tag.

    Exits:
        If it does not match ``http://soap.sforce.com/2006/04/metadata``.
    """

    if namespace != ns["sforce"]:
        logging.info(
            "ERROR: Either Namespace is missing or defined incorrectly in package. "
            "It should be '%s', Please correct it..!!!",
            ns["sforce"],
        )
        sys.exit(1)


def validate_nametag(metadata_name: list) -> str:
    """
    Validate the ``<name>`` child inside a single ``<types>`` block.

    Each ``<types>`` section must have exactly one ``<name>`` (metadata type such as
    ApexClass or CustomObject).

    Args:
        metadata_name: List of text values from all ``<name>`` elements in that block.

    Returns:
        The single metadata type name string.

    Exits:
        If there are zero or multiple ``<name>`` tags.
    """

    if len(metadata_name) > 1:
        logging.info(
            "ERROR: Multiple <name> tags %s present in single type, "
            "Please double check and remove the additional ones..!!!",
            metadata_name,
        )
        sys.exit(1)
    if len(metadata_name) == 0:
        logging.info(
            "ERROR: <name> tag is missing, Please double check and update..!!!"
        )
        sys.exit(1)
    return metadata_name[0]


def validate_memberdata(metadata_name: str, metadata_member_list: list) -> None:
    """
    Validate ``<members>`` entries for a metadata type.

    Wildcards (``*``) are rejected so deploys list explicit components. At least one
    member is required per type block.

    Args:
        metadata_name: Type name (for error messages).
        metadata_member_list: All ``<members>`` text values in that block.

    Exits:
        If the list is empty or contains ``*``.
    """

    if len(metadata_member_list) == 0:
        logging.info(
            "ERROR: Members list is missing for %s,"
            " Please double check package details..!!!",
            metadata_name,
        )
        sys.exit(1)
    if "*" in metadata_member_list:
        logging.info(
            "ERROR: Wildcards are not allowed in the package.xml.\n"
            "You should declare specific metadata to deploy.\n"
            "Remove the wildcard and push a new commit."
        )
        sys.exit(1)


def validate_emptyness(metadata_values: list) -> None:
    """
    Ensure the package declares at least one metadata type.

    Args:
        metadata_values: Collected type names from each ``<types>`` block.

    Exits:
        If no types were found (blank or invalid package).
    """

    if not metadata_values:
        logging.info("ERROR: No Metadata captured, Package seems blank..!!!")
        sys.exit(1)


def validate_version_details(root: ET.Element) -> None:
    """
    Ensure at most one ``<version>`` element exists under ``<Package>``.

    Args:
        root: Parsed package root.

    Exits:
        If more than one ``<version>`` tag is present.
    """

    version_details = root.findall("sforce:version", ns)
    if len(version_details) > 1:
        logging.info(
            "ERROR: Multiple versions : %s are available,"
            "Please remove the duplicate one!!!",
            [ver.text for ver in version_details],
        )
        sys.exit(1)


def get_metadata_members_by_type(root: ET.Element, type_name: str) -> list:
    """
    Collect every <members> value for a metadata type across all <types> blocks.

    package.xml may repeat the same type in multiple blocks; results are merged in order.

    Args:
        root: Parsed <Package> element.
        type_name: Metadata type API name (e.g. ApexClass, ApexTrigger, CustomMetadata);
            matched case-insensitively against <name>.

    Returns:
        List of member strings (empty if the type is not present).
    """
    want = type_name.lower()
    out = []
    for metadata_type in root.findall("sforce:types", ns):
        names = [m.text for m in metadata_type.findall("sforce:name", ns)]
        if len(names) != 1:
            continue
        if (names[0] or "").lower() != want:
            continue
        out.extend(
            m.text for m in metadata_type.findall("sforce:members", ns) if m.text
        )
    return out


def cmt_record_in_package(root: ET.Element, qualified_name: str) -> bool:
    """
    Return True if the given Custom Metadata record is listed under <types><name>CustomMetadata</name>.

    Args:
        root: Parsed package root.
        qualified_name: Full CMT name as in package.xml, e.g. SwitchForAutomation.MyRecord.

    Returns:
        Whether that member appears in the deploy manifest.
    """
    return qualified_name in get_metadata_members_by_type(root, "CustomMetadata")


def cmt_qualified_name_to_paths(
    qualified_name: str,
) -> Tuple[str, str, str]:
    """
    Map a package CustomMetadata qualified name to SOQL object, DeveloperName, and source path.

    Example:
        ``SwitchForAutomation.Foo`` →
        (``SwitchForAutomation__mdt``, ``Foo``,
        ``force-app/main/default/customMetadata/SwitchForAutomation.Foo.md-meta.xml``)

    Raises:
        ValueError: If qualified_name has no dot (Type.DeveloperName).
    """
    if "." not in qualified_name:
        raise ValueError(
            f"Invalid cmt_record_qualified_name: {qualified_name!r} (expected Type.Name)"
        )
    type_label, developer_name = qualified_name.split(".", 1)
    object_api = f"{type_label}__mdt"
    rel_path = f"force-app/main/default/customMetadata/{type_label}.{developer_name}.md-meta.xml"
    return object_api, developer_name, rel_path


def parse_switch_field_from_cmt_file(file_path: str, field_api: str) -> bool:
    """
    Read a checkbox (or boolean-like) field from a Custom Metadata *.md-meta.xml file.

    Args:
        file_path: Path to the CMT record XML under force-app/.../customMetadata/.
        field_api: Field API name (e.g. Turn_on__c).

    Returns:
        True if the field value is true/1; False if false, missing, or field not found.
    """
    tree = ET.parse(file_path)
    root = tree.getroot()
    for elem in root.iter():
        if not elem.tag.endswith("values"):
            continue
        field_text = None
        value_text = None
        for sub in elem:
            tag = sub.tag.split("}")[-1]
            if tag == "field" and sub.text:
                field_text = sub.text.strip()
            elif tag == "value" and sub.text is not None:
                value_text = sub.text.strip().lower()
        if field_text == field_api:
            return value_text in ("true", "1")
    logging.warning(
        "%s not found in %s; treating switch as off (false).", field_api, file_path
    )
    return False


def soql_string_literal(value: str) -> str:
    """
    Escape a value for use inside single-quoted SOQL string literals.

    SOQL requires doubling internal apostrophes (e.g. O''Brien).
    """
    return value.replace("'", "''")


def resolve_sf_executable() -> Optional[str]:
    """
    Locate the Salesforce CLI executable on PATH.

    Tries ``sf``, then ``sf.cmd``, then ``sf.exe`` so Windows shells resolve the shim correctly.

    Returns:
        Absolute path to the executable, or None if not found.
    """
    for name in ("sf", "sf.cmd", "sf.exe"):
        path = shutil.which(name)
        if path:
            return path
    return None


def query_org_cmt_switch_field(
    object_api: str,
    developer_name: str,
    field_api: str,
) -> bool:
    """
    Run ``sf data query`` against the default org to read a CMT switch field.

    Exits the process if the CLI is missing or the query fails. If no row matches
    DeveloperName, returns False (treat as switch off).

    Args:
        object_api: Custom metadata type API name (e.g. SwitchForAutomation__mdt).
        developer_name: CMT DeveloperName (record suffix).
        field_api: Field to SELECT (e.g. Turn_on__c).

    Returns:
        Interpreted boolean: True for truthy checkbox/string values, False otherwise.
    """
    sf_exe = resolve_sf_executable()
    if not sf_exe:
        logging.error(
            "ERROR: Salesforce CLI (sf) not found on PATH. Install sf CLI or include "
            "the CMT record in package.xml so the switch can be read from source."
        )
        sys.exit(1)
    dev_esc = soql_string_literal(developer_name)
    soql = f"SELECT {field_api} FROM {object_api} WHERE DeveloperName = '{dev_esc}'"
    # SOQL must be passed with -q / --query (positional SOQL is rejected by current sf CLI).
    cmd = [sf_exe, "data", "query", "-q", soql, "--json"]
    try:
        proc = subprocess.run(
            cmd, capture_output=True, text=True, timeout=120, check=False
        )
    except FileNotFoundError:
        logging.error(
            "ERROR: Salesforce CLI (sf) not found. Install sf CLI or include the CMT "
            "record in package.xml so the switch can be read from source."
        )
        sys.exit(1)
    except subprocess.TimeoutExpired:
        logging.error(
            "ERROR: sf data query timed out for %s.%s.", object_api, developer_name
        )
        sys.exit(1)
    try:
        data = json.loads(proc.stdout or "{}")
    except json.JSONDecodeError:
        logging.error(
            "ERROR: Invalid JSON from sf data query: %s", (proc.stdout or "")[:500]
        )
        sys.exit(1)
    if proc.returncode != 0 or data.get("status") != 0:
        err = (data.get("message") or proc.stderr or proc.stdout or "unknown error")[
            :800
        ]
        logging.error("ERROR: sf data query failed: %s", err)
        sys.exit(1)
    records = (data.get("result") or {}).get("records") or []
    if not records:
        logging.info(
            "No %s row for DeveloperName=%s in org; treating switch as off.",
            object_api,
            developer_name,
        )
        return False
    val = records[0].get(field_api)
    if isinstance(val, bool):
        return val
    if val is None:
        return False
    return str(val).lower() in ("true", "1", "yes")


def resolve_cmt_switch_enabled(root: ET.Element, rule: Dict[str, Any]) -> bool:
    """
    Decide whether the CMT "switch" is on for a config rule.

    If the CMT record is in package.xml and the source file exists on disk, reads the
    field from XML. Otherwise queries the default org. Optional rule keys
    ``cmt_object_api_name`` and ``cmt_developer_name`` override API name / DeveloperName.

    Args:
        root: Parsed package.xml root.
        rule: One entry from package_check_cmt_tests.json (must include
            cmt_record_qualified_name; switch_field defaults to Turn_on__c).

    Returns:
        True if the switch field is enabled in the chosen source (file or org).
    """
    qname = rule["cmt_record_qualified_name"]
    field_api = rule.get("switch_field") or "Turn_on__c"
    object_api, developer_name, rel_path = cmt_qualified_name_to_paths(qname)

    if rule.get("cmt_object_api_name"):
        object_api = rule["cmt_object_api_name"]
    if rule.get("cmt_developer_name"):
        developer_name = rule["cmt_developer_name"]

    if cmt_record_in_package(root, qname):
        if os.path.isfile(rel_path):
            logging.info(
                "CMT %s is in package.xml; reading %s from %s",
                qname,
                field_api,
                rel_path,
            )
            return parse_switch_field_from_cmt_file(rel_path, field_api)
        logging.info(
            "CMT %s in package but file missing at %s; querying default org.",
            qname,
            rel_path,
        )
        return query_org_cmt_switch_field(object_api, developer_name, field_api)

    logging.info(
        "CMT %s not in package.xml; querying default org for %s.%s",
        qname,
        object_api,
        developer_name,
    )
    return query_org_cmt_switch_field(object_api, developer_name, field_api)


def load_cmt_rules(config_path: str) -> List[Dict[str, Any]]:
    """
    Load and validate CMT-driven test rules from JSON.

    Expects a top-level ``rules`` (or legacy ``cmt_switch_rules``) array. Each rule
    must include apex_type, apex_name, cmt_record_qualified_name, tests_when_enabled,
    and tests_when_disabled. Sets ``_apex_type_norm`` on each rule for internal use.

    Args:
        config_path: Path to package_check_cmt_tests.json (or equivalent).

    Returns:
        List of rule dicts, or empty list if the file is missing (with a warning).

    Exits:
        On invalid JSON, missing required keys, or invalid apex_type.
    """
    if not config_path or not os.path.isfile(config_path):
        logging.warning("WARNING: CMT tests config not found: %s", config_path)
        return []
    try:
        with open(config_path, "r", encoding="utf-8") as f:
            data = json.load(f)
    except json.JSONDecodeError as e:
        logging.error("ERROR: Invalid JSON in %s: %s", config_path, e)
        sys.exit(1)
    rules = data.get("rules") or data.get("cmt_switch_rules")
    if rules is None:
        logging.warning('WARNING: %s has no "rules" array; ignoring.', config_path)
        return []
    out = []
    for i, rule in enumerate(rules):
        req = (
            "apex_type",
            "apex_name",
            "cmt_record_qualified_name",
            "tests_when_enabled",
            "tests_when_disabled",
        )
        missing = [k for k in req if k not in rule or rule[k] in (None, "")]
        if missing:
            logging.error(
                "ERROR: CMT rule #%s in %s missing keys: %s", i, config_path, missing
            )
            sys.exit(1)
        t = (rule["apex_type"] or "").strip().lower()
        if t not in ("apexclass", "apextrigger"):
            logging.error(
                "ERROR: rule #%s apex_type must be ApexClass or ApexTrigger, got %r",
                i,
                rule.get("apex_type"),
            )
            sys.exit(1)
        rule["_apex_type_norm"] = t
        out.append(rule)
    return out


def tests_value_to_string(val: Any) -> str:
    """
    Normalize JSON test list config to a single space-separated string.

    Args:
        val: Either a list of class name strings or one string (possibly space/comma separated).

    Returns:
        Stripped string suitable for clean_test_class_names.
    """
    if isinstance(val, list):
        return " ".join(str(x) for x in val)
    return str(val).strip()


def clean_test_class_names(test_line: str, context: str) -> str:
    """
    Normalize a line of Apex test class names (whitespace/comma, strip .cls suffix).

    Args:
        test_line: Raw annotation or config value listing test classes.
        context: Label for log messages (file path or apex member name).

    Returns:
        Space-separated class names without .cls extensions.
    """
    cleaned_tests = re.sub(r"[\s,]+", " ", test_line.strip())
    out = []
    for test_name in cleaned_tests.split():
        if test_name.lower().endswith(".cls"):
            logging.warning(
                "WARNING: Auto-removing .cls extension from test name '%s' -> '%s' (%s)",
                test_name,
                test_name[:-4],
                context,
            )
            test_name = test_name[:-4]
        out.append(test_name)
    return " ".join(out)


def build_cmt_test_overrides(
    root: ET.Element,
    stage: str,
    rules: List[Dict[str, Any]],
) -> Tuple[Dict[str, str], Dict[str, str]]:
    """
    Build per-member test class strings from CMT rules for the current package.

    For each rule whose apex_name is in the package (as ApexClass or ApexTrigger),
    resolves the CMT switch and maps that member to either tests_when_enabled or
    tests_when_disabled. Destroy stage and empty rules yield empty dicts.

    Args:
        root: Parsed package.xml.
        stage: deploy or destroy (rules skipped when destroy).
        rules: Validated list from load_cmt_rules.

    Returns:
        (overrides_for_apex_class_members, overrides_for_apex_trigger_members):
        each maps API name → space-separated test class names to use instead of @tests.
    """
    ov_class: Dict[str, str] = {}
    ov_trigger: Dict[str, str] = {}
    if stage == "destroy" or not rules:
        return ov_class, ov_trigger

    apex_classes = set(get_metadata_members_by_type(root, "ApexClass"))
    apex_triggers = set(get_metadata_members_by_type(root, "ApexTrigger"))

    for rule in rules:
        aname = rule["apex_name"]
        atype = rule["_apex_type_norm"]
        if atype == "apexclass" and aname not in apex_classes:
            continue
        if atype == "apextrigger" and aname not in apex_triggers:
            continue

        enabled = resolve_cmt_switch_enabled(root, rule)
        raw = rule["tests_when_enabled"] if enabled else rule["tests_when_disabled"]
        tests_str = clean_test_class_names(tests_value_to_string(raw), aname)
        logging.info(
            "CMT rule for %s %s: switch enabled=%s -> tests: %s",
            atype,
            aname,
            enabled,
            tests_str,
        )
        if atype == "apexclass":
            ov_class[aname] = tests_str
        else:
            ov_trigger[aname] = tests_str

    return ov_class, ov_trigger


def process_metadata_type(
    root: ET.Element,
    stage: str,
    cmt_rules: List[Dict[str, Any]],
) -> tuple:
    """
    Iterate and process through metadata, extract details such as metadata_values
    and whether APEX is required or not.

    Applies ``cmt_rules`` so matching ApexClass/ApexTrigger members get test lists
    from Custom Metadata switches before falling back to source annotations.
    """

    metadata_values = []
    apex_required = False
    logging.info("Deployment package contents:")
    test_classes_set = set()

    ov_class, ov_trigger = build_cmt_test_overrides(root, stage, cmt_rules)

    for metadata_type in root.findall("sforce:types", ns):
        try:
            metadata_name = [
                member.text for member in metadata_type.findall("sforce:name", ns)
            ]
            metadata_member_list = [
                member.text for member in metadata_type.findall("sforce:members", ns)
            ]
            metadata_name = validate_nametag(metadata_name)
            validate_memberdata(metadata_name, metadata_member_list)
            logging.info(
                "%s: %s", metadata_name, ", ".join(map(str, metadata_member_list))
            )
        except AttributeError:
            logging.info(
                "ERROR: <name> tag is missing, Please double check package details..!!!"
            )
            sys.exit(1)

        if metadata_name.lower() == PARENT_WORKFLOW:
            logging.error(
                "ERROR: The parent metadata type Workflow is banned in our CI/CD pipeline."
            )
            logging.error(
                "Please update the package.xml to use one of the children Workflow types:"
            )
            logging.error("%s", ", ".join(map(str, CHILDREN_WORKFLOW)))
            sys.exit(1)
        if metadata_name.lower() == "connectedapp" and stage != "destroy":
            process_connected_app(metadata_member_list)
        elif metadata_name.lower() in APEX_TYPES:
            if stage != "destroy":
                overrides = (
                    ov_class if metadata_name.lower() == "apexclass" else ov_trigger
                )
                test_classes_set = process_apex_parallel(
                    metadata_member_list,
                    metadata_name.lower(),
                    test_classes_set,
                    overrides,
                )
            apex_required = True
        metadata_values.append(metadata_name)

    return metadata_values, apex_required, test_classes_set


def process_connected_app(metadata_member_list: list) -> None:
    """
    Strip consumer keys from Connected App metadata before deploy (secrets hygiene).

    For each package member, loads
    ``force-app/.../connectedApps/<name>.connectedApp-meta.xml`` and removes the
    ``consumerKey`` element if present.

    Args:
        metadata_member_list: ConnectedApp API names from the manifest.

    Exits:
        If a listed ConnectedApp file is missing on disk.
    """

    for member in metadata_member_list:
        file_path = (
            f"force-app/main/default/connectedApps/{member}.connectedApp-meta.xml"
        )
        if os.path.exists(file_path):
            logging.info("Processing ConnectedApp to remove consumer key: %s", member)
            remove_consumer_key(file_path)
        else:
            logging.info("ERROR: ConnectedApp file not found: %s", file_path)
            sys.exit(1)


def remove_consumer_key(file_path: str) -> None:
    """
    Remove the ``<consumerKey>`` node from a Connected App meta XML file and save.

    Args:
        file_path: Path to ``*.connectedApp-meta.xml``.

    Exits:
        If the file cannot be parsed as XML.
    """

    try:
        tree = ET.parse(file_path)
        root = tree.getroot()
        consumer_key_element = root.find(".//sforce:consumerKey", ns)
        if consumer_key_element is not None:
            for parent in root.iter():
                for child in list(parent):
                    if child == consumer_key_element:
                        parent.remove(child)
                        break
            xml_str = ET.tostring(root, encoding="utf-8", method="xml").decode("utf-8")
            header = '<?xml version="1.0" encoding="UTF-8"?>\n'
            with open(file_path, "w", encoding="utf-8") as file:
                file.write(header + xml_str)
            logging.info("Successfully removed consumer key from %s", file_path)
        else:
            logging.info("No consumer key found in %s", file_path)
    except ET.ParseError:
        logging.info(
            "ERROR: Unable to parse %s. Please check the file format.", file_path
        )
        sys.exit(1)


def process_apex_parallel(
    metadata_member_list: list,
    metadata_name: str,
    test_classes_set: set,
    cmt_overrides: Dict[str, str],
) -> set:
    """
    Process Apex classes or triggers in parallel and collect test class names.

    Members present in ``cmt_overrides`` use the configured test list directly;
    others are scanned with find_apex_tests (@tests / @isTest).

    Args:
        metadata_member_list: Package member API names for this type block.
        metadata_name: apexclass or apextrigger.
        test_classes_set: Accumulator of test class names (updated in place logically).
        cmt_overrides: Member name → space-separated tests from CMT rules.

    Returns:
        Updated test_classes_set (same set instance).
    """

    if metadata_name == "apexclass":
        directory = "classes"
        extension = ".cls"
    else:
        directory = "triggers"
        extension = ".trigger"

    max_workers = (os.cpu_count() or 4) * 2

    with ThreadPoolExecutor(max_workers=max_workers) as executor:
        future_to_file = {}
        for member in metadata_member_list:
            fpath = f"force-app/main/default/{directory}/{member}{extension}"
            if member in cmt_overrides:
                tests = cmt_overrides[member]

                def _static_tests(_t: str = tests) -> str:
                    """Return CMT-configured tests (default arg binds per-loop value)."""
                    return _t

                fut = executor.submit(_static_tests)
            else:
                fut = executor.submit(find_apex_tests, fpath)
            future_to_file[fut] = member

        for future in as_completed(future_to_file):
            member = future_to_file[future]
            try:
                found_tests = future.result()
                if found_tests:
                    test_classes_set.update(found_tests.split())
            except FileNotFoundError:
                logging.error("ERROR: Apex file not found: %s", member)
                sys.exit(1)
            except Exception as exc:
                logging.error(
                    "ERROR: Exception occurred while processing %s: %s", member, exc
                )
                sys.exit(1)

    return test_classes_set


def find_apex_tests(file_path: str) -> str:
    """
    Discover Apex test classes referenced by an Apex class or trigger source file.

    Looks for ``@isTest`` on the file (treats the file as a test class) and for
    ``@tests:`` comment lines listing test classes. Results are space-separated.

    Args:
        file_path: Path to ``.cls`` or ``.trigger`` under force-app.

    Returns:
        Space-separated test class names (may be empty; caller may warn).

    Exits:
        If the file cannot be read.
    """

    try:
        with open(file_path, "r", encoding="utf-8") as file:
            apex_file_contents = file.read()
        test_classes = []
        if "@istest" in apex_file_contents.lower():
            class_name = os.path.splitext(os.path.basename(file_path))[0]
            test_classes.append(class_name)
        matches = re.findall(
            r"@tests\s*:\s*([^\r\n]+)", apex_file_contents, re.IGNORECASE
        )
        for test_list in matches:
            test_classes.append(clean_test_class_names(test_list, file_path))
        if not test_classes:
            logging.warning(
                "WARNING: Test annotations not found in %s. Please add @tests: annotation.",
                file_path,
            )
    except FileNotFoundError:
        logging.error("ERROR: File not found %s", file_path)
        sys.exit(1)
    return " ".join(test_classes)


def validate_tests(test_classes_set: set) -> str:
    """
    Keep only test class names that exist as ``.cls`` files in the project.

    Args:
        test_classes_set: Candidate names from annotations and CMT rules.

    Returns:
        Space-separated list of valid test classes.

    Exits:
        If every candidate was missing (nothing left to run).
    """

    valid_test_classes = []
    for test_class in test_classes_set:
        class_file_path = f"force-app/main/default/classes/{test_class}.cls"
        if os.path.isfile(class_file_path):
            valid_test_classes.append(test_class)
        else:
            logging.warning(
                "WARNING: %s is not a valid test class in the current directory.",
                test_class,
            )
    if not valid_test_classes:
        logging.error(
            "ERROR: None of the test annotations provided are valid test classes."
        )
        logging.error("Confirm test class annotations and try again.")
        sys.exit(1)
    return " ".join(valid_test_classes)


def determine_destructive_tests() -> str:
    """
    Return the fixed Apex test suite used for destructive Apex deploys in production.

    Used when ``stage`` is destroy and ``environment`` is production so the pipeline
    still runs a minimal known-good test set.

    Returns:
        Space-separated default test class names.
    """

    test_classes = {"AccountTriggerHandlerTest", "CaseTriggerHandlerTest"}
    return " ".join(test_classes)


def scan_package(
    package_path: str,
    stage: str,
    env: str,
    cmt_config_path: str,
) -> str:
    """
    Validate package.xml, apply CMT test rules, and return required Apex test classes.

    Args:
        package_path: Path to manifest/package.xml.
        stage: deploy or destroy.
        env: production/sandbox (affects destructive deploy default tests).
        cmt_config_path: JSON path for optional CMT-driven test overrides.

    Returns:
        Space-separated test class names, or the string ``not a test`` when none required.
    """

    root, local_name, namespace = parse_package(package_path)
    validate_metadata_attributes(root)
    validate_root(local_name)
    validate_namespace(namespace)
    cmt_rules = load_cmt_rules(cmt_config_path)
    metadata_values, apex_required, test_classes = process_metadata_type(
        root, stage, cmt_rules
    )
    validate_version_details(root)
    validate_emptyness(metadata_values)

    if apex_required and stage != "destroy":
        logging.info("Apex Tests are Required for this package")
        test_classes = validate_tests(test_classes)
    elif apex_required and stage == "destroy" and env == "production":
        logging.info("Apex Tests are Required for this package")
        test_classes = determine_destructive_tests()
    else:
        logging.info("Apex Tests are Not Required for this package")
        test_classes = "not a test"
    return test_classes


def main(manifest, stage, environment, cmt_config_path):
    """
    Entry point: resolve tests for the manifest and emit them for shell/CI capture.

    Logs the result and prints a single line to stdout (space-separated classes or
    ``not a test``).

    Args:
        manifest: package.xml path.
        stage: deploy or destroy.
        environment: e.g. production or sandbox.
        cmt_config_path: JSON path for CMT-driven test rules.
    """

    test_classes = scan_package(manifest, stage, environment, cmt_config_path)
    logging.info(test_classes)
    print(test_classes)


if __name__ == "__main__":
    inputs = parse_args()
    main(
        inputs.manifest,
        inputs.stage,
        inputs.environment,
        inputs.cmt_tests_config,
    )
