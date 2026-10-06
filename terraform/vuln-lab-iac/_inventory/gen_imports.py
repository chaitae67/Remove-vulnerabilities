# inventory.json(+일부 read-only 조회) -> imports.tf (import 블록) + _work/address_map.json
import json, re, subprocess
from collections import Counter

AWS = r"C:\Program Files\Amazon\AWSCLIV2\aws.exe"


def a(*x, glob=False):
    r = subprocess.run([AWS, *x, "--profile", "default", "--output", "json"] + ([] if glob else ["--region", "ap-northeast-2"]),
                       capture_output=True, text=True, encoding="utf-8", errors="replace")
    return json.loads(r.stdout) if r.returncode == 0 and r.stdout.strip() else {}


I = json.load(open("_inventory/inventory.json", encoding="utf-8"))
VPC = "vpc-086bab7aac7afcbb4"


def nm(o):
    return next((t["Value"] for t in (o.get("Tags") or []) if t["Key"] == "Name"), "")


def slug(s):
    return re.sub(r"[^a-z0-9_]", "_", s.lower().replace("-", "_")).strip("_")


blocks = []
amap = {}


def imp(addr, iid, domain, note=""):
    assert addr not in amap, addr
    amap[addr] = {"id": iid, "domain": domain, "note": note}
    blocks.append((domain, addr, iid))


# ---------------- network
imp("aws_vpc.main", VPC, "network")
for s in I["subnets"]["Subnets"]:
    if s["VpcId"] == VPC:
        imp("aws_subnet.%s" % slug(nm(s)), s["SubnetId"], "network")
for g in I["igw"]["InternetGateways"]:
    if any(x["VpcId"] == VPC for x in g.get("Attachments", [])):
        imp("aws_internet_gateway.main", g["InternetGatewayId"], "network")
for n in I["nat"]["NatGateways"]:
    if n["State"] == "available":
        imp("aws_nat_gateway.main", n["NatGatewayId"], "network")
for e in I["eips"]["Addresses"]:
    t = nm(e)
    if t == "vuln-lab-nat-eip":
        imp("aws_eip.nat", e["AllocationId"], "network")
    elif t == "vuln-lab-bastion-eip":
        imp("aws_eip.bastion", e["AllocationId"], "compute")
subnet_by_id = {s["SubnetId"]: slug(nm(s)) for s in I["subnets"]["Subnets"]}
for r in I["route_tables"]["RouteTables"]:
    if r["VpcId"] != VPC:
        continue
    if any(x.get("Main") for x in r.get("Associations", [])):
        imp("aws_default_route_table.main", r["RouteTableId"], "network")
        continue
    rn = slug(nm(r))
    imp("aws_route_table.%s" % rn, r["RouteTableId"], "network")
    for x in r.get("Associations", []):
        if x.get("SubnetId"):
            imp("aws_route_table_association.%s" % subnet_by_id[x["SubnetId"]], "%s/%s" % (x["SubnetId"], r["RouteTableId"]), "network")
for e in I["vpc_endpoints"]["VpcEndpoints"]:
    if e["VpcId"] == VPC:
        imp("aws_vpc_endpoint.%s" % slug(e["ServiceName"].split(".")[-1]), e["VpcEndpointId"], "network")

# ---------------- security
for n in I["nacls"]["NetworkAcls"]:
    if n["VpcId"] != VPC:
        continue
    if n["IsDefault"]:
        imp("aws_default_network_acl.default", n["NetworkAclId"], "security")
    else:
        imp("aws_network_acl.%s" % slug(nm(n)), n["NetworkAclId"], "security")
for g in I["sgs"]["SecurityGroups"]:
    if g["VpcId"] != VPC:
        continue
    if g["GroupName"] == "default":
        imp("aws_default_security_group.default", g["GroupId"], "security")
    else:
        imp("aws_security_group.%s" % slug(g["GroupName"].replace("vuln-lab-", "")), g["GroupId"], "security")

# ---------------- compute
for r in I["instances"]["Reservations"]:
    for i in r["Instances"]:
        imp("aws_instance.%s" % slug(nm(i)), i["InstanceId"], "compute")
        for b in i.get("BlockDeviceMappings", []):
            if b["DeviceName"] == i.get("RootDeviceName"):
                continue
            vid = b["Ebs"]["VolumeId"]
            v = next(x for x in I["volumes"]["Volumes"] if x["VolumeId"] == vid)
            vn = slug(nm(v) or vid)
            imp("aws_ebs_volume.%s" % vn, vid, "compute")
            imp("aws_volume_attachment.%s" % vn, "%s:%s:%s" % (b["DeviceName"], vid, i["InstanceId"]), "compute")
for k in I["key_pairs"]["KeyPairs"]:
    imp("aws_key_pair.%s" % slug(k["KeyName"]), k["KeyName"], "compute")
imp("aws_ebs_encryption_by_default.this", "default", "compute", "account-level")
imp("aws_ebs_default_kms_key.this", I["ebs_default_kms"]["KmsKeyId"], "compute", "account-level")

# ---------------- load balancing / dns / acm
lbname = {}
for l in I["lbs"]["LoadBalancers"]:
    n = slug(l["LoadBalancerName"])
    lbname[l["LoadBalancerArn"]] = n
    imp("aws_lb.%s" % n, l["LoadBalancerArn"], "loadbalancing")
for t in I["tgs"]["TargetGroups"]:
    imp("aws_lb_target_group.%s" % slug(t["TargetGroupName"]), t["TargetGroupArn"], "loadbalancing")
for lbarn, ls in I["listeners"].items():
    for l in ls.get("Listeners", []):
        la = "%s_%s" % (lbname[lbarn], l["Port"])
        imp("aws_lb_listener.%s" % la, l["ListenerArn"], "loadbalancing")
        for ru in I["rules"][l["ListenerArn"]].get("Rules", []):
            if not ru["IsDefault"]:
                imp("aws_lb_listener_rule.%s_p%s" % (la, ru["Priority"]), ru["RuleArn"], "loadbalancing")
        for c in a("elbv2", "describe-listener-certificates", "--listener-arn", l["ListenerArn"]).get("Certificates", []):
            if not c.get("IsDefault"):
                imp("aws_lb_listener_certificate.%s_%s" % (la, slug(c["CertificateArn"].split("/")[-1][:8])),
                    "%s_%s" % (l["ListenerArn"], c["CertificateArn"]), "loadbalancing")
for c in I["acm"]["CertificateSummaryList"]:
    an = "wildcard" if c["DomainName"].startswith("*") else slug(c["DomainName"].split(".")[0])
    imp("aws_acm_certificate.%s" % an, c["CertificateArn"], "loadbalancing")
for z in I["r53_zones"]["HostedZones"]:
    zid = z["Id"].split("/")[-1]
    imp("aws_route53_zone.main", zid, "loadbalancing")
    zname = z["Name"].rstrip(".")
    for rr in I["r53_records"][z["Id"]]["ResourceRecordSets"]:
        if rr["Type"] in ("NS", "SOA"):
            continue
        name = rr["Name"].rstrip(".")
        label = name[: -len(zname)].rstrip(".") or "apex"
        if label.startswith("_"):
            label = "acmval_" + label.split(".")[-1]
        imp("aws_route53_record.%s_%s" % (slug(label), rr["Type"].lower()), "%s_%s_%s" % (zid, name, rr["Type"]), "loadbalancing")

# ---------------- storage
SUB = {
    "versioning": ("aws_s3_bucket_versioning", lambda d: d.get("Status")),
    "encryption": ("aws_s3_bucket_server_side_encryption_configuration", None),
    "pab": ("aws_s3_bucket_public_access_block", None),
    "policy": ("aws_s3_bucket_policy", None),
    "logging": ("aws_s3_bucket_logging", lambda d: d.get("LoggingEnabled")),
    "lifecycle": ("aws_s3_bucket_lifecycle_configuration", None),
    "ownership": ("aws_s3_bucket_ownership_controls", None),
    "cors": ("aws_s3_bucket_cors_configuration", None),
    "website": ("aws_s3_bucket_website_configuration", None),
    "notification": ("aws_s3_bucket_notification", lambda d: any(k.endswith("Configurations") for k in d)),
    "replication": ("aws_s3_bucket_replication_configuration", None),
}
for b, d in I["bucket_detail"].items():
    bn = slug(re.sub(r"^aws-cloudtrail-logs-\d{12}$", "cloudtrail_logs", re.sub(r"-[0-9a-f]{8}$", "", b)))
    imp("aws_s3_bucket.%s" % bn, b, "storage")
    for k, (rt, ok) in SUB.items():
        v = d.get(k, {})
        if not v or "__error__" in v:
            continue
        if ok and not ok(v):
            continue
        imp("%s.%s" % (rt, bn), b, "storage")

# ---------------- logging / security services
for f in I["flow_logs"]["FlowLogs"]:
    if f["ResourceId"] == VPC:
        imp("aws_flow_log.vpc", f["FlowLogId"], "logging")
for t in I["cloudtrail"]["trailList"]:
    if t.get("HomeRegion") == "ap-northeast-2":
        imp("aws_cloudtrail.%s" % slug(t["Name"]), t["TrailARN"], "logging")
for g in I["log_groups"]["logGroups"]:
    imp("aws_cloudwatch_log_group.%s" % slug(g["logGroupName"]), g["logGroupName"], "logging")
for kid, v in I["kms_customer"].items():
    al = [x["AliasName"] for x in v["aliases"].get("Aliases", [])]
    kn = slug(al[0].replace("alias/", "")) if al else kid[:8]
    imp("aws_kms_key.%s" % kn, kid, "logging")
    for x in al:
        imp("aws_kms_alias.%s" % slug(x.replace("alias/", "")), x, "logging")
for pid, p in I["backup_plan_detail"].items():
    pn = p["plan"].get("BackupPlan", {}).get("BackupPlanName", "")
    if pn.startswith("aws/"):
        continue
    imp("aws_backup_plan.%s" % slug(pn), pid, "logging")
    for s in p["selections"].get("BackupSelectionsList", []):
        imp("aws_backup_selection.%s" % slug(s["SelectionName"]), "%s|%s" % (pid, s["SelectionId"]), "logging")
for c in I["config_recorders"].get("ConfigurationRecorders", []):
    imp("aws_config_configuration_recorder.%s" % slug(c["name"]), c["name"], "logging", "account-level")
    imp("aws_config_configuration_recorder_status.%s" % slug(c["name"]), c["name"], "logging", "account-level")
for dc in a("configservice", "describe-delivery-channels").get("DeliveryChannels", []):
    imp("aws_config_delivery_channel.%s" % slug(dc["name"]), dc["name"], "logging", "account-level")
for d in I["ssm_docs_self"]["DocumentIdentifiers"]:
    if d["Name"].startswith("AutoDiag"):
        imp("aws_ssm_document.%s" % slug(d["Name"]), d["Name"], "logging")

# ---------------- IAM (vuln-lab 관련만)
ROLES = ["vuln-lab-ec2-app-role", "CloudTrail_CloudWatchLogs_Role", "AWSBackupDefaultServiceRole"]
for p in I["iam_instance_profiles"]["InstanceProfiles"]:
    if p["InstanceProfileName"] == "vuln-lab-ec2-app-profile":
        imp("aws_iam_instance_profile.ec2_app", p["InstanceProfileName"], "iam")
for rn in ROLES:
    s = slug(rn)
    imp("aws_iam_role.%s" % s, rn, "iam")
    for ap in a("iam", "list-attached-role-policies", "--role-name", rn, glob=True).get("AttachedPolicies", []):
        imp("aws_iam_role_policy_attachment.%s__%s" % (s, slug(ap["PolicyName"])[:40]), "%s/%s" % (rn, ap["PolicyArn"]), "iam")
        if ":aws:policy/" not in ap["PolicyArn"]:
            pa = "aws_iam_policy.%s" % slug(ap["PolicyName"])[:50]
            if pa not in amap:
                imp(pa, ap["PolicyArn"], "iam")
    for ip in a("iam", "list-role-policies", "--role-name", rn, glob=True).get("PolicyNames", []):
        imp("aws_iam_role_policy.%s__%s" % (s, slug(ip)[:40]), "%s:%s" % (rn, ip), "iam")

# ---------------- write
ORDER = ["network", "security", "compute", "loadbalancing", "storage", "logging", "iam"]
with open("imports.tf", "w", encoding="utf-8", newline="\n") as f:
    f.write("# 현재 AWS 리소스를 Terraform state 로 가져오는 import 블록 (자동 생성: _inventory/gen_imports.py)\n")
    f.write("# terraform plan 으로 '가져오기 N, 추가/변경/삭제 0' 을 확인한다. apply 는 사람이 검토 후 결정한다.\n")
    for dom in ORDER:
        f.write("\n# ---------------- %s ----------------\n" % dom)
        for d, addr, iid in blocks:
            if d == dom:
                f.write('import {\n  to = %s\n  id = "%s"\n}\n' % (addr, iid))
json.dump(amap, open("_work/address_map.json", "w", encoding="utf-8"), ensure_ascii=False, indent=1)
print(len(blocks), "imports", dict(Counter(d for d, _, _ in blocks)))
