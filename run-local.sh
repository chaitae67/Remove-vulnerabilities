#!/usr/bin/env bash

set -euo pipefail

case "${1:-}" in
    admin|admin-app)
        module="admin-app"
        ;;
    customer|customer-app)
        module="customer-app"
        ;;
    *)
        echo "사용법: $0 {admin|customer}"
        exit 1
        ;;
esac

if ! command -v mvn >/dev/null 2>&1; then
    echo "Maven을 찾을 수 없습니다. Maven 3.9 이상을 설치하고 PATH에 추가하세요."
    exit 1
fi

repo_root="$(cd "$(dirname "$0")" && pwd)"
cd "$repo_root"

exec mvn -pl "$module" -Dspring-boot.run.profiles=local spring-boot:run
