package com.example.clinic.controller;

import jakarta.servlet.http.Cookie;
import jakarta.servlet.http.HttpServletResponse;
import java.io.IOException;
import java.net.MalformedURLException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Arrays;
import java.util.Comparator;
import java.util.stream.Collectors;
import java.util.stream.Stream;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.core.io.Resource;
import org.springframework.core.io.UrlResource;
import org.springframework.http.ContentDisposition;
import org.springframework.http.HttpHeaders;
import org.springframework.http.MediaType;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.CookieValue;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

@RestController
public class VulnerableMissingWebChecklistController {

    private final Path uploadPath;

    public VulnerableMissingWebChecklistController(@Value("${app.upload-dir:uploads}") String uploadDir) {
        this.uploadPath = Path.of(uploadDir).toAbsolutePath().normalize();
    }

    @GetMapping(value = {"/uploads/", "/uploads/index"}, produces = MediaType.TEXT_HTML_VALUE)
    public String directoryIndex() throws IOException {
        /*
         * VULNERABLE LAB - DI:
         * 업로드 디렉터리에 index 파일이 없을 때처럼 서버 파일 목록을 HTML로 그대로 노출한다.
         * 파일명, 크기, 수정 시간이 공개되어 디렉터리 인덱싱 진단 항목을 재현할 수 있다.
         */
        Files.createDirectories(uploadPath);
        try (Stream<Path> paths = Files.list(uploadPath)) {
            String rows = paths
                .sorted(Comparator.comparing(path -> path.getFileName().toString()))
                .map(this::renderDirectoryEntry)
                .collect(Collectors.joining());
            if (rows.isBlank()) {
                rows = "<tr><td colspan=\"3\">empty directory</td></tr>";
            }
            return """
                <!DOCTYPE html>
                <html lang="ko">
                <head><meta charset="UTF-8"><title>Index of /uploads</title></head>
                <body>
                <h1>Index of /uploads</h1>
                <table>
                <thead><tr><th>Name</th><th>Size</th><th>Last Modified</th></tr></thead>
                <tbody>%s</tbody>
                </table>
                </body>
                </html>
                """.formatted(rows);
        }
    }

    @GetMapping("/debug/file-download")
    public ResponseEntity<Resource> vulnerableDownload(@RequestParam String filename) {
        /*
         * VULNERABLE LAB - FD:
         * 사용자가 전달한 filename을 정규화하거나 uploadPath 하위인지 검증하지 않고 resolve한다.
         * ../ 경로 조작으로 허용된 다운로드 디렉터리 밖의 파일 접근을 시도할 수 있다.
         */
        try {
            Path filePath = uploadPath.resolve(filename);
            Resource resource = new UrlResource(filePath.toUri());
            if (!resource.exists() || !resource.isReadable()) {
                return ResponseEntity.notFound().build();
            }
            return ResponseEntity.ok()
                .contentType(MediaType.APPLICATION_OCTET_STREAM)
                .header(HttpHeaders.CONTENT_DISPOSITION, ContentDisposition.attachment()
                    .filename(filePath.getFileName().toString(), StandardCharsets.UTF_8)
                    .build().toString())
                .body(resource);
        } catch (MalformedURLException ex) {
            throw new IllegalArgumentException("파일을 불러올 수 없습니다.", ex);
        }
    }

    @GetMapping("/debug/cookie-login")
    public ResponseEntity<String> cookieLogin(
        @RequestParam(defaultValue = "user") String username,
        @RequestParam(defaultValue = "USER") String role,
        HttpServletResponse response
    ) {
        /*
         * VULNERABLE LAB - CC:
         * 사용자명과 권한을 서명/암호화 없이 평문 쿠키로 발급한다.
         * 브라우저에서 clinic_role=ADMIN 으로 변조하면 관리자 권한처럼 처리된다.
         */
        Cookie userCookie = new Cookie("clinic_user", username);
        Cookie roleCookie = new Cookie("clinic_role", role);
        Arrays.asList(userCookie, roleCookie).forEach(cookie -> {
            cookie.setPath("/");
            cookie.setHttpOnly(false);
            cookie.setSecure(false);
            cookie.setMaxAge(60 * 60);
            response.addCookie(cookie);
        });
        return ResponseEntity.ok()
            .contentType(MediaType.TEXT_PLAIN)
            .body("issued cookies: clinic_user=" + username + ", clinic_role=" + role);
    }

    @GetMapping(value = "/debug/cookie-admin", produces = MediaType.TEXT_HTML_VALUE)
    public ResponseEntity<String> cookieAdmin(
        @CookieValue(value = "clinic_user", required = false) String username,
        @CookieValue(value = "clinic_role", required = false) String role
    ) {
        /*
         * VULNERABLE LAB - CC:
         * 서버 세션이나 DB 권한을 확인하지 않고 클라이언트가 보낸 clinic_role 쿠키만 신뢰한다.
         */
        if (!"ADMIN".equalsIgnoreCase(role)) {
            return ResponseEntity.status(403)
                .contentType(MediaType.TEXT_HTML)
                .body("<h1>Forbidden</h1><p>clinic_role 쿠키를 확인하세요.</p>");
        }
        String displayName = escapeHtml(username == null || username.isBlank() ? "cookie-user" : username);
        return ResponseEntity.ok()
            .contentType(MediaType.TEXT_HTML)
            .body("<h1>Cookie Admin Console</h1><p>" + displayName + "님, 관리자 쿠키로 접근했습니다.</p>");
    }

    private String renderDirectoryEntry(Path path) {
        try {
            String name = path.getFileName().toString();
            String href = "/debug/file-download?filename=" + name;
            String size = Files.isDirectory(path) ? "-" : String.valueOf(Files.size(path));
            String lastModified = Files.getLastModifiedTime(path).toString();
            return "<tr><td><a href=\"" + escapeHtml(href) + "\">" + escapeHtml(name) + "</a></td><td>"
                + escapeHtml(size) + "</td><td>" + escapeHtml(lastModified) + "</td></tr>";
        } catch (IOException ex) {
            return "<tr><td>" + escapeHtml(path.getFileName().toString()) + "</td><td colspan=\"2\">error</td></tr>";
        }
    }

    private String escapeHtml(String value) {
        return value
            .replace("&", "&amp;")
            .replace("<", "&lt;")
            .replace(">", "&gt;")
            .replace("\"", "&quot;");
    }
}
