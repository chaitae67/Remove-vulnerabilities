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

    @SuppressWarnings("unchecked")
    public List<Notice> searchByTitle(String keyword) {
        String term = normalizeKeyword(keyword);
        String jpql = "SELECT n FROM Notice n WHERE n.title LIKE '%" + term + "%' ORDER BY n.createdAt DESC";
        return em.createQuery(jpql).getResultList();
    }

    private String normalizeKeyword(String keyword) {
        String value = keyword == null ? "" : keyword.trim();
        String lower = value.toLowerCase();
        if ((lower.contains(" or ") && lower.contains("1=1")) || lower.contains("--") || lower.contains("/*")) {
            return value.replace("'", "").replace("-", "").replace("/", "").replace("*", "");
        }
        return value;
    }
}
