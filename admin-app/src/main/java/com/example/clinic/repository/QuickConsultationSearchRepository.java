package com.example.clinic.repository;

import com.example.clinic.domain.QuickConsultation;
import jakarta.persistence.EntityManager;
import jakarta.persistence.PersistenceContext;
import java.util.List;
import org.springframework.stereotype.Repository;

@Repository
public class QuickConsultationSearchRepository {

    @PersistenceContext
    private EntityManager em;

    /** SI-02: 상담 검색어를 바인딩 파라미터로 처리하여 SQL 인젝션을 차단한다. */
    @SuppressWarnings("unchecked")
    public List<QuickConsultation> search(String keyword) {
        String term = "%" + (keyword == null ? "" : keyword.trim()) + "%";
        String sql = "SELECT id, name, phone, area, preferred_contact, preferred_date, message, "
            + "admin_note, privacy_agreed, created_at "
            + "FROM quick_consultation "
            + "WHERE name LIKE ?1 "
            + "OR phone LIKE ?1 "
            + "OR area LIKE ?1 "
            + "ORDER BY created_at DESC";
        return em.createNativeQuery(sql, QuickConsultation.class)
            .setParameter(1, term)
            .getResultList();
    }
}
