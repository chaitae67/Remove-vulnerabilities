package com.example.clinic.repository;

import com.example.clinic.domain.QuickConsultation;
import java.util.List;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;

public interface QuickConsultationRepository extends JpaRepository<QuickConsultation, Long> {
    List<QuickConsultation> findTop10ByOrderByCreatedAtDesc();

    List<QuickConsultation> findAllByOrderByCreatedAtDesc();

    @Query("""
        select c from QuickConsultation c
        where lower(c.name) like lower(concat('%', :keyword, '%'))
           or c.phone like concat('%', :keyword, '%')
           or lower(c.area) like lower(concat('%', :keyword, '%'))
        order by c.createdAt desc
        """)
    List<QuickConsultation> searchByKeyword(@Param("keyword") String keyword);
}
