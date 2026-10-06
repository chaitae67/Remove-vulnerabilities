# 인스턴스 user_data 메타 조회 (읽기 전용)
# 주의: user_data 에 평문 비밀번호가 들어 있다 -> 화면에는 sha256/길이만 출력,
#       원문은 gitignore 된 ../_work/userdata/ 에만 저장하고 템플릿 비교 후 삭제할 것.
import subprocess,json,base64,sys,hashlib,os
AWS=r"C:\Program Files\Amazon\AWSCLIV2\aws.exe"
def a(*x):
    r=subprocess.run([AWS,*x,"--profile","default","--region","ap-northeast-2","--output","json"],capture_output=True,text=True,encoding="utf-8",errors="replace")
    return json.loads(r.stdout) if r.returncode==0 and r.stdout.strip() else {"__error__":r.stderr[:200]}
I=json.load(open("inventory.json",encoding="utf-8"))
out={}
amis=set()
for r in I["instances"]["Reservations"]:
    for i in r["Instances"]:
        nm=next((t["Value"] for t in i.get("Tags",[]) if t["Key"]=="Name"),i["InstanceId"])
        ud=a("ec2","describe-instance-attribute","--instance-id",i["InstanceId"],"--attribute","userData").get("UserData",{}).get("Value")
        txt=base64.b64decode(ud).decode("utf-8","replace") if ud else ""
        os.makedirs("../_work/userdata",exist_ok=True)
        open("../_work/userdata/%s.txt"%nm,"w",encoding="utf-8").write(txt)
        meta={k:a("ec2","describe-instance-attribute","--instance-id",i["InstanceId"],"--attribute",k) for k in ("disableApiTermination","disableApiStop","instanceInitiatedShutdownBehavior")}
        out[nm]={"id":i["InstanceId"],"userdata_bytes":len(txt),"userdata_sha256":hashlib.sha256(txt.encode("utf-8")).hexdigest(),"ami":i["ImageId"],"meta":{k:list(v.values())[-1] for k,v in meta.items()}}
        amis.add(i["ImageId"])
im=a("ec2","describe-images","--image-ids",*sorted(amis))
for x in im.get("Images",[]):
    print("AMI",x["ImageId"],x.get("OwnerId"),x.get("Name"),x.get("Description","")[:60],x.get("CreationDate"))
missing=amis-set(x["ImageId"] for x in im.get("Images",[]))
print("AMI not describable (deregistered/shared?):",missing)
for k,v in out.items(): print(k,json.dumps(v,ensure_ascii=False)[:400])
