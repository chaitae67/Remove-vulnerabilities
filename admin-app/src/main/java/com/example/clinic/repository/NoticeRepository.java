package com.example.clinic.repository;

import com.example.clinic.domain.Notice;
import java.util.List;
import org.springframework.data.jpa.repository.JpaRepository;

public interface NoticeRepository extends JpaRepository<Notice, Long> {
    List<Notice> findTop3ByOrderByCreatedAtDesc();

    List<Notice> findAllByOrderByCreatedAtDesc();
}
