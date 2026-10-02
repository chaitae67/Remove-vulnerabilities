package com.example.clinic.config;

import jakarta.annotation.PostConstruct;
import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.attribute.PosixFilePermission;
import java.nio.file.attribute.PosixFilePermissions;
import java.util.Set;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Component;

/**
 * WEB-24: 업로드 저장 경로를 애플리케이션과 분리된 전용 디렉터리로 생성하고,
 * 일반 사용자가 접근하지 못하도록 기동 시 소유자 전용 권한으로 설정한다.
 * POSIX(리눅스)에서는 rwx------(700)로 제한하며, POSIX를 지원하지 않는 환경(Windows)에서는
 * 파일시스템 ACL 설정이 배포 단계에서 필요함을 로그로 안내한다.
 */
@Component
public class StorageInitializer {

    private static final Logger log = LoggerFactory.getLogger(StorageInitializer.class);

    private final String uploadDir;

    public StorageInitializer(@Value("${app.upload-dir:uploads}") String uploadDir) {
        this.uploadDir = uploadDir;
    }

    @PostConstruct
    public void init() throws IOException {
        Path base = Path.of(uploadDir).toAbsolutePath().normalize();
        secureCreateDirectory(base);
        secureCreateDirectory(base.resolve("qna"));
        secureCreateDirectory(base.resolve("reviews"));
    }

    static void secureCreateDirectory(Path dir) throws IOException {
        Files.createDirectories(dir);
        try {
            Set<PosixFilePermission> ownerOnly = PosixFilePermissions.fromString("rwx------");
            Files.setPosixFilePermissions(dir, ownerOnly);
        } catch (UnsupportedOperationException ex) {
            // Windows 등 POSIX 미지원 파일시스템: ACL 기반 권한은 배포 단계에서 설정해야 한다.
            log.warn("업로드 디렉터리 {} 의 POSIX 권한 설정을 지원하지 않는 환경입니다. "
                + "배포 시 서비스 계정만 접근 가능하도록 ACL을 설정하세요.", dir);
        }
    }
}
