#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""클라우드(AWS/Azure/GCP) 취약점 진단 — CSP별 파일로 분리.

SK Shieldus 2024 클라우드 보안가이드 체크리스트 기준.
GUI(kisa_gui.py)는 run(provider, creds) 하나만 호출하면 되고,
반환값은 서버 진단(kisa_unix_check.sh 등)과 동일한 JSON 계약을 따른다:

    {
      "host":   "<계정/구독/프로젝트 식별자>",
      "os":     "AWS" | "Azure" | "GCP",
      "family": "cloud",
      "results": [
        {"code","importance","title","status","evidence":[...],"resources":[...]},
        ...
      ]
    }

status : 양호 / 취약 / N/A / 수동확인   (서버 진단과 동일, REPORT_STATUS 로 매핑)
"""

PROVIDERS = ("aws", "azure", "gcp")

# CSP → (모듈경로, 사람이 읽는 이름, 설치 안내 pip 패키지, import 로 존재확인할 모듈명)
_IMPL = {
    "aws":   (".aws",   "AWS",   "boto3",                     "boto3"),
    "azure": (".azure", "Azure", "azure-identity azure-mgmt-resource", "azure.identity"),
    "gcp":   (".gcp",   "GCP",   "google-api-python-client google-auth", "googleapiclient"),
}


def available(provider):
    """해당 CSP 점검에 필요한 SDK가 설치돼 있는지."""
    import importlib
    probe = _IMPL[provider][3]
    try:
        importlib.import_module(probe)
        return True
    except Exception:
        return False


def missing_package(provider):
    return _IMPL[provider][2]


def label(provider):
    return _IMPL[provider][1]


def run(provider, creds):
    """provider 진단을 실행하고 표준 결과 dict 를 돌려준다.

    creds : GUI 에서 받은 자격증명 dict (CSP마다 키가 다름)
            aws   → {mode, access_key, secret_key, session_token, region, profile}
            azure → {tenant_id, client_id, client_secret, subscription_id}
            gcp   → {sa_key_path, project_id}
    """
    provider = (provider or "").lower()
    if provider not in _IMPL:
        raise ValueError(f"알 수 없는 CSP: {provider}")
    import importlib
    mod = importlib.import_module(_IMPL[provider][0], __name__)
    return mod.run(creds or {})
