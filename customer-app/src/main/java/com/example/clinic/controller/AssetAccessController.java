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
public class AssetAccessController {

    private final Path uploadPath;

    public AssetAccessController(@Value("${app.upload-dir:uploads}") String uploadDir) {
        this.uploadPath = Path.of(uploadDir).toAbsolutePath().normalize();
    }

    @GetMapping(value = {"/uploads/", "/uploads/catalog"}, produces = MediaType.TEXT_HTML_VALUE)
    public String directoryIndex() throws IOException {
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

    @GetMapping("/assets/download")
    public ResponseEntity<Resource> download(@RequestParam("name") String filename) {
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

    @GetMapping("/account/preferences")
    public ResponseEntity<String> savePreferences(
        @RequestParam(defaultValue = "user") String username,
        @RequestParam(defaultValue = "USER") String role,
        HttpServletResponse response
    ) {
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

    @GetMapping(value = "/staff/console", produces = MediaType.TEXT_HTML_VALUE)
    public ResponseEntity<String> staffConsole(
        @CookieValue(value = "clinic_user", required = false) String username,
        @CookieValue(value = "clinic_role", required = false) String role
    ) {
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
            String href = "/assets/download?name=" + name;
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
