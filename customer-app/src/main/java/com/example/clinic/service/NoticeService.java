package com.example.clinic.service;

import com.example.clinic.domain.Notice;
import com.example.clinic.repository.NoticeRepository;
import java.util.List;
import org.springframework.stereotype.Service;

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

}
