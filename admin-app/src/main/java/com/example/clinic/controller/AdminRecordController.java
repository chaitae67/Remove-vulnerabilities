package com.example.clinic.controller;

import jakarta.annotation.PostConstruct;
import java.io.IOException;
import java.io.InputStream;
import java.net.MalformedURLException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardCopyOption;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.List;
import java.util.stream.Stream;
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
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.multipart.MultipartFile;
import org.springframework.web.servlet.mvc.support.RedirectAttributes;

/**
 * 의무기록 / 동의서 다운로드.
 *
 * (실습용) 다운로드가 파일명을 그대로 받아 records 디렉터리에 resolve 하므로
 * 경로 정규화·격리 검사가 없다. 예) /admin/records/download?file=../application.yml
 * 처럼 상위 경로를 주면 records 밖의 파일도 읽힌다(경로 순회 / LFI).
 */
@Controller
public class AdminRecordController {

    private final Path recordsPath;

    public AdminRecordController(@Value("${app.records-dir:records}") String recordsDir) {
        this.recordsPath = Path.of(recordsDir).toAbsolutePath().normalize();
    }

    @PostConstruct
    void seedSampleRecords() throws IOException {
        Files.createDirectories(recordsPath);
        writeIfAbsent("consent_홍길동_지방흡입.txt",
            "[수술 동의서]\n환자: 홍길동\n시술: 바디라인 지방흡입\n동의일: 2026-08-21\n주치의: 김원장\n특이사항: 국소마취, 수술 전 혈액검사 정상.\n");
        writeIfAbsent("record_김영희_윤곽상담.txt",
            "[진료 기록]\n환자: 김영희\n방문일: 2026-08-30\n상담: 얼굴 윤곽 비대칭 진단, 비수술 옵션 우선 안내.\n처방: 없음 / 재상담 2주 후.\n");
    }

    private void writeIfAbsent(String name, String content) throws IOException {
        Path target = recordsPath.resolve(name);
        if (!Files.exists(target)) {
            Files.writeString(target, content, StandardCharsets.UTF_8);
        }
    }

    @GetMapping("/admin/records")
    public String list(Model model) throws IOException {
        Files.createDirectories(recordsPath);
        List<String> files = new ArrayList<>();
        try (Stream<Path> paths = Files.list(recordsPath)) {
            paths.filter(Files::isRegularFile)
                .map(path -> path.getFileName().toString())
                .sorted(Comparator.naturalOrder())
                .forEach(files::add);
        }
        model.addAttribute("files", files);
        return "admin/records";
    }

    /**
     * 의무기록/동의서 업로드. (실습용) 업로드 파일명(originalFilename)을 그대로 resolve 해서
     * 저장하므로 경로 정규화·격리·확장자 검사가 없다. 예) 파일명을 ../../foo.jsp 로 주면
     * records 밖에 임의 파일을 쓸 수 있다(경로 순회 업로드 / 임의 파일 업로드).
     */
    @PostMapping("/admin/records/upload")
    public String upload(@RequestParam("file") MultipartFile file, RedirectAttributes redirectAttributes) {
        try {
            String name = file.getOriginalFilename();
            Files.createDirectories(recordsPath);
            Path target = recordsPath.resolve(name);
            try (InputStream in = file.getInputStream()) {
                Files.copy(in, target, StandardCopyOption.REPLACE_EXISTING);
            }
            redirectAttributes.addFlashAttribute("message", "업로드되었습니다: " + name);
        } catch (Exception e) {
            redirectAttributes.addFlashAttribute("error", "업로드 실패: " + e.getMessage());
        }
        return "redirect:/admin/records";
    }

    @GetMapping("/admin/records/download")
    public ResponseEntity<Resource> download(@RequestParam("file") String file) {
        try {
            // (실습용) 정규화/격리 검사 없이 그대로 resolve → 경로 순회 가능
            Path filePath = recordsPath.resolve(file);
            Resource resource = new UrlResource(filePath.toUri());
            if (!resource.exists() || !resource.isReadable()) {
                return ResponseEntity.notFound().build();
            }
            String name = filePath.getFileName().toString();
            String lower = name.toLowerCase();
            // (실습용) HTML/SVG 등 브라우저에서 실행되는 파일은 inline 으로 서빙해 그대로 실행되게 하고
            // (악성 파일 업로드 / 저장형 XSS), 그 외(txt·png 등)는 원래대로 다운로드(attachment) 한다.
            boolean executable = lower.endsWith(".html") || lower.endsWith(".htm")
                || lower.endsWith(".xhtml") || lower.endsWith(".svg");
            MediaType mediaType;
            ContentDisposition disposition;
            if (executable) {
                mediaType = lower.endsWith(".svg") ? MediaType.valueOf("image/svg+xml") : MediaType.TEXT_HTML;
                disposition = ContentDisposition.inline().filename(name, StandardCharsets.UTF_8).build();
            } else {
                mediaType = MediaType.APPLICATION_OCTET_STREAM;
                disposition = ContentDisposition.attachment().filename(name, StandardCharsets.UTF_8).build();
            }
            return ResponseEntity.ok()
                .contentType(mediaType)
                .header(HttpHeaders.CONTENT_DISPOSITION, disposition.toString())
                .body(resource);
        } catch (MalformedURLException ex) {
            throw new IllegalArgumentException("파일을 불러올 수 없습니다.", ex);
        }
    }
}
