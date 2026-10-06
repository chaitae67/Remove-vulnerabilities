# [템플릿] nssm 서비스 clinic-customer 의 AppParameters (REG_EXPAND_SZ)
# 위치: HKLM\SYSTEM\CurrentControlSet\Services\clinic-customer\Parameters\AppParameters
# '#' 로 시작하는 줄은 baseline.ps1 이 버린다. 마지막 비주석 한 줄이 값이다.
# ${db_password} 는 baseline.ps1 이 환경변수 DB_PASSWORD 또는 SSM SecureString 값으로 바꾼다(파일에 비밀번호를 쓰지 말 것).
#
# 근거(운영 값 자체는 확보하지 못했고 아래 조각으로 맞췄다):
#  - '-jar C:\Remove-vulnerabilities\customer-app\target\clinic-customer-app-0.0.1-SNAPSHOT.jar' 와 java 명령행이 같다
#      results/apply/was1/20261002-105606_precheck4.log ("process cmdline ends with registry AppParameters: True")
#  - --spring.datasource.url=jdbc:oracle:thin:@10.0.20.184:1521/XEPDB1, --spring.datasource.username=oraadmin,
#    --spring.datasource.password=(평문 비밀번호)                      wf_result_v2.json was1 WEB-13
#  - 맨 끝 --server.port=8080                                          wf_result_v2.json was1 WEB-01·WEB-10
#  - 따옴표 없음, 렌더링 후 전체 길이가 운영 값 길이와 같은지 확인함    results/apply/was1/20261002-105525_precheck3.log
#  - TODO(확인필요): 가운데 세 --spring.datasource.* 인자의 순서는 진단 근거에 적힌 순서다. 실제 순서는 미확인.
#  - 보안 주의: DB 비밀번호가 명령행·레지스트리에 평문으로 남는다(운영과 같은 방식). 10/2 WEB-13 은 키 ACL 만 좁혔다.
-jar C:\Remove-vulnerabilities\customer-app\target\clinic-customer-app-0.0.1-SNAPSHOT.jar --spring.datasource.url=jdbc:oracle:thin:@10.0.20.184:1521/XEPDB1 --spring.datasource.username=oraadmin --spring.datasource.password=${db_password} --server.port=8080
