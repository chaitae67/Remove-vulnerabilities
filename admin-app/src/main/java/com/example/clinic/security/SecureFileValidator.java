package com.example.clinic.security;

import java.io.IOException;
import java.io.InputStream;
import java.util.Locale;
import java.util.Set;
import org.springframework.web.multipart.MultipartFile;

/** FU-14: 확장자·크기·실제 파일 시그니처를 함께 검증한다. */
public final class SecureFileValidator {
    private static final Set<String> ALLOWED = Set.of("jpg", "jpeg", "png", "gif", "webp", "pdf", "txt");
    private SecureFileValidator() {}

    public static String validate(MultipartFile file, long maxBytes) throws IOException {
        if (file == null || file.isEmpty() || file.getSize() > maxBytes) throw new IllegalArgumentException("빈 파일이거나 허용 크기를 초과했습니다.");
        String name = file.getOriginalFilename() == null ? "" : file.getOriginalFilename();
        int dot = name.lastIndexOf('.');
        String extension = dot < 0 ? "" : name.substring(dot + 1).toLowerCase(Locale.ROOT);
        if (!ALLOWED.contains(extension)) throw new IllegalArgumentException("이미지, PDF, 일반 텍스트 파일만 업로드할 수 있습니다.");
        byte[] header = new byte[16];
        int length;
        try (InputStream in = file.getInputStream()) { length = in.read(header); }
        boolean valid = switch (extension) {
            case "jpg", "jpeg" -> length >= 3 && u(header[0]) == 0xff && u(header[1]) == 0xd8 && u(header[2]) == 0xff;
            case "png" -> length >= 8 && u(header[0]) == 0x89 && header[1] == 'P' && header[2] == 'N' && header[3] == 'G';
            case "gif" -> length >= 6 && header[0] == 'G' && header[1] == 'I' && header[2] == 'F' && header[3] == '8';
            case "webp" -> length >= 12 && header[0] == 'R' && header[1] == 'I' && header[2] == 'F' && header[3] == 'F' && header[8] == 'W' && header[9] == 'E' && header[10] == 'B' && header[11] == 'P';
            case "pdf" -> length >= 5 && header[0] == '%' && header[1] == 'P' && header[2] == 'D' && header[3] == 'F' && header[4] == '-';
            case "txt" -> length >= 0 && !containsNul(header, Math.max(length, 0));
            default -> false;
        };
        if (!valid) throw new IllegalArgumentException("파일 내용과 확장자가 일치하지 않습니다.");
        return extension;
    }
    private static int u(byte value) { return value & 0xff; }
    private static boolean containsNul(byte[] bytes, int length) { for (int i = 0; i < length; i++) if (bytes[i] == 0) return true; return false; }
}
