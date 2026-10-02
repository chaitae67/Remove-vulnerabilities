package com.example.clinic.repository;

import java.util.List;

import org.springframework.stereotype.Repository;

import com.example.clinic.domain.Notice;

import jakarta.persistence.EntityManager;
import jakarta.persistence.PersistenceContext;

@Repository
public class NoticeSearchRepository {

    @PersistenceContext
    private EntityManager em;

    public List<Notice> searchByTitle(String keyword) {
        // SI-02: 파라미터 바인딩을 사용하여 SQL(JPQL) 인젝션을 차단한다.
        String term = keyword == null ? "" : keyword.trim();
        return em.createQuery(
                "SELECT n FROM Notice n WHERE n.title LIKE :term ORDER BY n.createdAt DESC", Notice.class)
            .setParameter("term", "%" + term + "%")
            .getResultList();
    }
}
