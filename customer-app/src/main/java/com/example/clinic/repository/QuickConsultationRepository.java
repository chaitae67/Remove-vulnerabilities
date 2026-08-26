package com.example.clinic.repository;

import com.example.clinic.domain.QuickConsultation;
import java.util.List;
import org.springframework.data.jpa.repository.JpaRepository;

public interface QuickConsultationRepository extends JpaRepository<QuickConsultation, Long> {
    List<QuickConsultation> findTop10ByOrderByCreatedAtDesc();
}
