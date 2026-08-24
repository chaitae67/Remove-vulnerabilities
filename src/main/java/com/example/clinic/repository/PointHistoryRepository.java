package com.example.clinic.repository;

import com.example.clinic.domain.AppUser;
import com.example.clinic.domain.PointHistory;
import java.util.List;
import org.springframework.data.jpa.repository.JpaRepository;

public interface PointHistoryRepository extends JpaRepository<PointHistory, Long> {
    List<PointHistory> findByUserOrderByCreatedAtDesc(AppUser user);
}
