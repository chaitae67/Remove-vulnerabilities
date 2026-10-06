# READ-ONLY inventory of vuln-lab AWS resources -> inventory.json
import subprocess,json,sys,os
AWS=r"C:\Program Files\Amazon\AWSCLIV2\aws.exe"
def a(*x,glob=False):
    c=[AWS,*x,"--profile","default","--output","json"]+([] if glob else ["--region","ap-northeast-2"])
    r=subprocess.run(c,capture_output=True,text=True,encoding="utf-8",errors="replace")
    if r.returncode!=0: return {"__error__":r.stderr.strip()[:300]}
    return json.loads(r.stdout) if r.stdout.strip() else {}
inv={}
inv["vpcs"]=a("ec2","describe-vpcs")
inv["subnets"]=a("ec2","describe-subnets")
inv["igw"]=a("ec2","describe-internet-gateways")
inv["nat"]=a("ec2","describe-nat-gateways")
inv["eips"]=a("ec2","describe-addresses")
inv["route_tables"]=a("ec2","describe-route-tables")
inv["nacls"]=a("ec2","describe-network-acls")
inv["sgs"]=a("ec2","describe-security-groups")
inv["vpc_endpoints"]=a("ec2","describe-vpc-endpoints")
inv["flow_logs"]=a("ec2","describe-flow-logs")
inv["dhcp"]=a("ec2","describe-dhcp-options")
inv["instances"]=a("ec2","describe-instances")
inv["volumes"]=a("ec2","describe-volumes")
inv["key_pairs"]=a("ec2","describe-key-pairs")
inv["ebs_default_enc"]=a("ec2","get-ebs-encryption-by-default")
inv["ebs_default_kms"]=a("ec2","get-ebs-default-kms-key-id")
inv["lbs"]=a("elbv2","describe-load-balancers")
inv["tgs"]=a("elbv2","describe-target-groups")
lbattrs={};listeners={};rules={};tgh={};tgattrs={}
for lb in inv["lbs"].get("LoadBalancers",[]):
    arn=lb["LoadBalancerArn"]
    lbattrs[arn]=a("elbv2","describe-load-balancer-attributes","--load-balancer-arn",arn)
    ls=a("elbv2","describe-listeners","--load-balancer-arn",arn); listeners[arn]=ls
    for l in ls.get("Listeners",[]):
        rules[l["ListenerArn"]]=a("elbv2","describe-rules","--listener-arn",l["ListenerArn"])
for tg in inv["tgs"].get("TargetGroups",[]):
    tgh[tg["TargetGroupArn"]]=a("elbv2","describe-target-health","--target-group-arn",tg["TargetGroupArn"])
    tgattrs[tg["TargetGroupArn"]]=a("elbv2","describe-target-group-attributes","--target-group-arn",tg["TargetGroupArn"])
inv.update(lb_attrs=lbattrs,listeners=listeners,rules=rules,tg_health=tgh,tg_attrs=tgattrs)
inv["acm"]=a("acm","list-certificates","--includes","keyTypes=RSA_2048,RSA_1024,RSA_4096,EC_prime256v1,EC_secp384r1")
inv["acm_detail"]={c["CertificateArn"]:a("acm","describe-certificate","--certificate-arn",c["CertificateArn"]) for c in inv["acm"].get("CertificateSummaryList",[])}
inv["r53_zones"]=a("route53","list-hosted-zones",glob=True)
inv["r53_records"]={z["Id"]:a("route53","list-resource-record-sets","--hosted-zone-id",z["Id"],glob=True) for z in inv["r53_zones"].get("HostedZones",[])}
inv["buckets"]=a("s3api","list-buckets",glob=True)
bk={}
for b in inv["buckets"].get("Buckets",[]):
    n=b["Name"]; d={}
    for k,cmd in [("location","get-bucket-location"),("versioning","get-bucket-versioning"),("encryption","get-bucket-encryption"),
                  ("pab","get-public-access-block"),("policy","get-bucket-policy"),("logging","get-bucket-logging"),
                  ("lifecycle","get-bucket-lifecycle-configuration"),("ownership","get-bucket-ownership-controls"),
                  ("acl","get-bucket-acl"),("tagging","get-bucket-tagging"),("website","get-bucket-website"),
                  ("notification","get-bucket-notification-configuration"),("object_lock","get-object-lock-configuration"),
                  ("cors","get-bucket-cors"),("replication","get-bucket-replication")]:
        d[k]=a("s3api",cmd,"--bucket",n,glob=True)
    bk[n]=d
inv["bucket_detail"]=bk
inv["cloudtrail"]=a("cloudtrail","describe-trails","--include-shadow-trails")
inv["cloudtrail_status"]={t["TrailARN"]:a("cloudtrail","get-trail-status","--name",t["TrailARN"]) for t in inv["cloudtrail"].get("trailList",[])}
inv["cloudtrail_selectors"]={t["TrailARN"]:a("cloudtrail","get-event-selectors","--trail-name",t["TrailARN"]) for t in inv["cloudtrail"].get("trailList",[])}
inv["log_groups"]=a("logs","describe-log-groups")
inv["metric_filters"]=a("logs","describe-metric-filters")
inv["alarms"]=a("cloudwatch","describe-alarms")
inv["sns_topics"]=a("sns","list-topics")
inv["kms_keys"]=a("kms","list-keys")
kd={}
for k in inv["kms_keys"].get("Keys",[]):
    kid=k["KeyId"]; m=a("kms","describe-key","--key-id",kid)
    if m.get("KeyMetadata",{}).get("KeyManager")!="CUSTOMER": continue
    kd[kid]={"meta":m,"aliases":a("kms","list-aliases","--key-id",kid),"rotation":a("kms","get-key-rotation-status","--key-id",kid),
             "policy":a("kms","get-key-policy","--key-id",kid,"--policy-name","default"),"tags":a("kms","list-resource-tags","--key-id",kid)}
inv["kms_customer"]=kd
inv["backup_plans"]=a("backup","list-backup-plans")
inv["backup_vaults"]=a("backup","list-backup-vaults")
bp={}
for p in inv["backup_plans"].get("BackupPlansList",[]):
    bp[p["BackupPlanId"]]={"plan":a("backup","get-backup-plan","--backup-plan-id",p["BackupPlanId"]),
                           "selections":a("backup","list-backup-selections","--backup-plan-id",p["BackupPlanId"])}
    for s in bp[p["BackupPlanId"]]["selections"].get("BackupSelectionsList",[]):
        bp[p["BackupPlanId"]].setdefault("selection_detail",{})[s["SelectionId"]]=a("backup","get-backup-selection","--backup-plan-id",p["BackupPlanId"],"--selection-id",s["SelectionId"])
inv["backup_plan_detail"]=bp
inv["dlm"]=a("dlm","get-lifecycle-policies")
inv["guardduty"]=a("guardduty","list-detectors")
inv["config_recorders"]=a("configservice","describe-configuration-recorders")
inv["ssm_instances"]=a("ssm","describe-instance-information")
inv["ssm_params"]=a("ssm","describe-parameters")
inv["ssm_docs_self"]=a("ssm","list-documents","--filters","Key=Owner,Values=Self")
inv["iam_instance_profiles"]=a("iam","list-instance-profiles",glob=True)
inv["iam_roles"]=a("iam","list-roles",glob=True)
inv["iam_policies_local"]=a("iam","list-policies","--scope","Local",glob=True)
inv["wafv2"]=a("wafv2","list-web-acls","--scope","REGIONAL")
inv["s3_account_pab"]=a("s3control","get-public-access-block","--account-id",os.environ["AWS_ACCOUNT_ID"])
inv["access_analyzer"]=a("accessanalyzer","list-analyzers")
inv["iam_password_policy"]=a("iam","get-account-password-policy",glob=True)
inv["eventbridge_rules"]=a("events","list-rules")
inv["lambda"]=a("lambda","list-functions")
inv["secrets"]=a("secretsmanager","list-secrets")
inv["sessmgr_prefs"]=a("ssm","get-document","--name","SSM-SessionManagerRunShell")
json.dump(inv,open(sys.argv[1],"w",encoding="utf-8"),ensure_ascii=False,indent=1,default=str)
errs={k:v["__error__"] for k,v in inv.items() if isinstance(v,dict) and "__error__" in v}
print("saved; top-level errors:",json.dumps(errs,ensure_ascii=False)[:1500])
