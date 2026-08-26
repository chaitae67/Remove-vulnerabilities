#!/usr/bin/env bash

set -e

MAVEN_CMD="/c/Users/EZ/AppData/Local/Temp/apache-maven-3.9.16/bin/mvn.cmd"
MAVEN_REPOSITORY="C:/Users/EZ/AppData/Local/Temp/codex-m2-repository"

if [[ ! -f "$MAVEN_CMD" ]]; then
    echo "Maven을 찾을 수 없습니다: $MAVEN_CMD"
    exit 1
fi

cd "$(dirname "$0")"

"$MAVEN_CMD" \
    "-Dmaven.repo.local=$MAVEN_REPOSITORY" \
    "-Dspring-boot.run.profiles=local" \
    spring-boot:run
