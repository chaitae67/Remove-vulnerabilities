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

    /** 교육용 취약점: 상담 검색어를 Native SQL에 직접 연결한다. */
    @SuppressWarnings("unchecked")
    public List<QuickConsultation> search(String keyword) {
        String sql = "SELECT id, name, phone, area, preferred_contact, preferred_date, message, "
            + "admin_note, privacy_agreed, created_at "
            + "FROM quick_consultation "
            + "WHERE name LIKE '%" + keyword + "%' "
            + "OR phone LIKE '%" + keyword + "%' "
            + "OR area LIKE '%" + keyword + "%' "
            + "ORDER BY created_at DESC";
        return em.createNativeQuery(sql, QuickConsultation.class).getResultList();
    }
}
