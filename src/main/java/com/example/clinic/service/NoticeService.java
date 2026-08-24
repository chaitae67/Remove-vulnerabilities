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
    public Notice create(String title, String content, AppUser author) {
        Notice notice = new Notice();
        notice.setTitle(title);
        notice.setContent(content);
        notice.setAuthor(author);
        return noticeRepository.save(notice);
    }

    @Transactional
    public void update(Long id, String title, String content) {
        Notice notice = findById(id);
        notice.setTitle(title);
        notice.setContent(content);
    }

    @Transactional
    public void delete(Long id) {
        noticeRepository.deleteById(id);
    }
}
