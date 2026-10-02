package com.example.clinic.service;

import com.example.clinic.domain.AppUser;
import com.example.clinic.domain.Notice;
import com.example.clinic.repository.NoticeRepository;
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
        validate(title, content, imageUrl);
        if (author == null || author.getRole() != com.example.clinic.domain.Role.ADMIN) {
            throw new IllegalArgumentException("관리자만 공지사항을 등록할 수 있습니다.");
        }
        Notice notice = new Notice();
        notice.setTitle(title.trim());
        notice.setContent(content.trim());
        notice.setImageUrl(normalizeImageUrl(imageUrl));
        notice.setAuthor(author);
        return noticeRepository.save(notice);
    }

    @Transactional
    public void update(Long id, String title, String content, String imageUrl) {
        validate(title, content, imageUrl);
        Notice notice = findById(id);
        notice.setTitle(title.trim());
        notice.setContent(content.trim());
        notice.setImageUrl(normalizeImageUrl(imageUrl));
    }

    @Transactional
    public void delete(Long id) {
        if (!noticeRepository.existsById(id)) {
            throw new IllegalArgumentException("공지사항을 찾을 수 없습니다.");
        }
        noticeRepository.deleteById(id);
    }

    private void validate(String title, String content, String imageUrl) {
        if (title == null || title.isBlank() || title.trim().length() > 160) {
            throw new IllegalArgumentException("제목은 1자 이상 160자 이하로 입력해 주세요.");
        }
        if (content == null || content.isBlank() || content.trim().length() > 4000) {
            throw new IllegalArgumentException("내용은 1자 이상 4000자 이하로 입력해 주세요.");
        }
        normalizeImageUrl(imageUrl);
    }

    private String normalizeImageUrl(String imageUrl) {
        if (imageUrl == null || imageUrl.isBlank()) {
            return null;
        }
        String value = imageUrl.trim();
        if (value.length() > 500 || !value.startsWith("/images/") || value.contains("..")
                || value.contains("\\") || !value.matches("/[A-Za-z0-9._/-]+")) {
            throw new IllegalArgumentException("이미지 경로는 /images/ 아래의 안전한 상대 경로만 사용할 수 있습니다.");
        }
        return value;
    }
}
