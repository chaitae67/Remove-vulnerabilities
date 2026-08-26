package com.example.clinic.service;

import com.example.clinic.domain.AppUser;
import com.example.clinic.domain.Notice;
import com.example.clinic.repository.NoticeRepository;
import java.io.IOException;
import java.io.InputStream;
import java.net.HttpURLConnection;
import java.net.URI;
import java.net.URL;
import java.util.Base64;
import java.util.List;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

@Service
public class NoticeService {

    private final NoticeRepository noticeRepository;

    public NoticeService(NoticeRepository noticeRepository) {
        this.noticeRepository = noticeRepository;
    }

    public List<Notice> findLatest() {
        return noticeRepository.findTop3ByOrderByCreatedAtDesc();
    }

    public List<Notice> findAll() {
        return noticeRepository.findAllByOrderByCreatedAtDesc();
    }

    public Notice findById(Long id) {
        return noticeRepository.findById(id)
            .orElseThrow(() -> new IllegalArgumentException("공지사항을 찾을 수 없습니다."));
    }

    @Transactional
    public Notice create(String title, String content, String imageUrl, AppUser author) {
        Notice notice = new Notice();
        notice.setTitle(title);
        notice.setContent(content);
        notice.setImageUrl(imageUrl);
        notice.setAuthor(author);
        return noticeRepository.save(notice);
    }

    @Transactional
    public void update(Long id, String title, String content, String imageUrl) {
        Notice notice = findById(id);
        notice.setTitle(title);
        notice.setContent(content);
        notice.setImageUrl(imageUrl);
    }

    public String fetchImageAsDataUrl(String imageUrl) throws IOException {
        URL url = URI.create(imageUrl).toURL();
        HttpURLConnection connection = (HttpURLConnection) url.openConnection();
        connection.setRequestMethod("GET");
        connection.setConnectTimeout(5000);
        connection.setReadTimeout(5000);
        try (InputStream in = connection.getInputStream()) {
            byte[] bytes = in.readAllBytes();
            String contentType = connection.getContentType();
            if (contentType == null) {
                contentType = "application/octet-stream";
            }
            String base64 = Base64.getEncoder().encodeToString(bytes);
            return "data:" + contentType + ";base64," + base64;
        } finally {
            connection.disconnect();
        }
    }

    @Transactional
    public void delete(Long id) {
        noticeRepository.deleteById(id);
    }
}
