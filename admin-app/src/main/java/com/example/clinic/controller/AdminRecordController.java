package com.example.clinic.controller;

import java.io.IOException;
import java.io.InputStream;
import java.net.MalformedURLException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.security.Principal;
import java.security.SecureRandom;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.HexFormat;
import java.util.List;
import java.util.stream.Stream;
import javax.crypto.Mac;
import javax.crypto.spec.SecretKeySpec;
import com.example.clinic.security.SecureFileValidator;
import com.example.clinic.service.AdminReauthenticationService;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.core.io.Resource;
import org.springframework.core.io.UrlResource;
import org.springframework.http.ContentDisposition;
import org.springframework.http.HttpHeaders;
import org.springframework.http.MediaType;
import org.springframework.http.ResponseEntity;
import org.springframework.stereotype.Controller;
import org.springframework.ui.Model;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.multipart.MultipartFile;
import org.springframework.web.servlet.mvc.support.RedirectAttributes;

/**
 * 의무기록 / 동의서 업로드·다운로드.
 * FD-15/FU-14/XS-06: 파일명 정규화·격리 검사, 확장자 화이트리스트, 항상 첨부(attachment)
 * 다운로드를 적용하여 경로 순회·악성 파일 업로드·저장형 XSS를 차단한다.
 */
@Controller
public class AdminRecordController {

    // FU-14: 의무기록/동의서로 허용할 확장자.
    private final Path recordsPath;
    private final byte[] downloadKey;
    private final AdminReauthenticationService reauthenticationService;

    public AdminRecordController(@Value("${app.records-dir:records}") String recordsDir,
                                 @Value("${app.records-download-key:}") String configuredKey,
                                 AdminReauthenticationService reauthenticationService) {
        this.recordsPath = Path.of(recordsDir).toAbsolutePath().normalize();
        this.reauthenticationService = reauthenticationService;
        if (configuredKey == null || configuredKey.isBlank()) {
            this.downloadKey = new byte[32];
            new SecureRandom().nextBytes(this.downloadKey);
        } else {
            byte[] keyBytes = configuredKey.getBytes(StandardCharsets.UTF_8);
            if (keyBytes.length < 32) {
                throw new IllegalArgumentException("RECORD_DOWNLOAD_KEY는 32바이트 이상이어야 합니다.");
            }
            this.downloadKey = keyBytes;
        }
    }

    @GetMapping("/admin/records")
    public String list(Model model) throws IOException {
        Files.createDirectories(recordsPath);
        List<RecordFile> files = new ArrayList<>();
        try (Stream<Path> paths = Files.list(recordsPath)) {
            paths.filter(Files::isRegularFile)
                .map(path -> path.getFileName().toString())
                .sorted(Comparator.naturalOrder())
                .map(name -> new RecordFile(fileId(name), name))
                .forEach(files::add);
        }
        model.addAttribute("files", files);
        return "admin/records";
    }

    /**
     * 의무기록/동의서 업로드.
     * FU-14: 확장자 화이트리스트 + 파일명 정규화 + 업로드 디렉터리 격리 검사로
     * 경로 순회 및 실행 가능 파일 업로드를 차단한다.
     */
    @PostMapping("/admin/records/upload")
    public String upload(@RequestParam("file") MultipartFile file,
                         @RequestParam String adminPassword,
                         Principal principal,
                         RedirectAttributes redirectAttributes) {
        try {
            reauthenticationService.verify(principal, adminPassword);
            String original = org.springframework.util.StringUtils.cleanPath(
                file.getOriginalFilename() == null ? "" : file.getOriginalFilename());
            // 경로 구분자/상위 경로 차단
            if (original.isBlank() || original.contains("/") || original.contains("\\") || original.contains("..")) {
                redirectAttributes.addFlashAttribute("error", "올바르지 않은 파일명입니다.");
                return "redirect:/admin/records";
            }
            SecureFileValidator.validate(file, 10L * 1024 * 1024);
            Files.createDirectories(recordsPath);
            Path target = recordsPath.resolve(original).normalize();
            if (!target.startsWith(recordsPath)) {
                redirectAttributes.addFlashAttribute("error", "올바르지 않은 파일 경로입니다.");
                return "redirect:/admin/records";
            }
            if (Files.exists(target)) {
                redirectAttributes.addFlashAttribute("error", "같은 이름의 파일이 이미 존재합니다.");
                return "redirect:/admin/records";
            }
            try (InputStream in = file.getInputStream()) {
                Files.copy(in, target);
            }
            redirectAttributes.addFlashAttribute("message", "업로드되었습니다: " + original);
        } catch (Exception e) {
            redirectAttributes.addFlashAttribute("error", "업로드에 실패했습니다.");
        }
        return "redirect:/admin/records";
    }

    @GetMapping("/admin/records/download/{id}")
    public ResponseEntity<Resource> download(@PathVariable String id) {
        try {
            if (id == null || !id.matches("[0-9a-f]{64}")) {
                return ResponseEntity.badRequest().build();
            }
            Path filePath;
            try (Stream<Path> paths = Files.list(recordsPath)) {
                filePath = paths.filter(Files::isRegularFile)
                    .filter(path -> java.security.MessageDigest.isEqual(
                        fileId(path.getFileName().toString()).getBytes(StandardCharsets.US_ASCII),
                        id.getBytes(StandardCharsets.US_ASCII)))
                    .findFirst().orElse(null);
            }
            if (filePath == null || !filePath.normalize().startsWith(recordsPath)) return ResponseEntity.notFound().build();
            Resource resource = new UrlResource(filePath.toUri());
            if (!resource.exists() || !resource.isReadable()) {
                return ResponseEntity.notFound().build();
            }
            String name = filePath.getFileName().toString();
            // XS-06/FU-14: 항상 첨부(attachment)·octet-stream·nosniff로 내려 브라우저 실행을 방지한다.
            return ResponseEntity.ok()
                .contentType(MediaType.APPLICATION_OCTET_STREAM)
                .header("X-Content-Type-Options", "nosniff")
                .header(HttpHeaders.CONTENT_DISPOSITION,
                    ContentDisposition.attachment().filename(name, StandardCharsets.UTF_8).build().toString())
                .body(resource);
        } catch (MalformedURLException ex) {
            throw new IllegalArgumentException("파일을 불러올 수 없습니다.", ex);
        } catch (IOException ex) {
            throw new IllegalStateException("파일 목록을 확인할 수 없습니다.", ex);
        }
    }

    private String fileId(String filename) {
        try {
            Mac mac = Mac.getInstance("HmacSHA256");
            mac.init(new SecretKeySpec(downloadKey, "HmacSHA256"));
            return HexFormat.of().formatHex(mac.doFinal(filename.getBytes(StandardCharsets.UTF_8)));
        } catch (java.security.GeneralSecurityException exception) {
            throw new IllegalStateException("다운로드 식별자를 생성할 수 없습니다.", exception);
        }
    }

    public static final class RecordFile {
        private final String id;
        private final String name;

        private RecordFile(String id, String name) {
            this.id = id;
            this.name = name;
        }

        public String getId() { return id; }
        public String getName() { return name; }
    }
}
