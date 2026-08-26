package com.example.clinic.repository;

import java.util.List;

import org.springframework.stereotype.Repository;

import com.example.clinic.domain.Review;

import jakarta.persistence.EntityManager;
import jakarta.persistence.PersistenceContext;

@Repository
public class ReviewSearchRepository {

    @PersistenceContext
    private EntityManager em;

    @SuppressWarnings("unchecked")
    public List<Review> searchByTitle(String keyword) {
        String term = normalizeKeyword(keyword);
        String jpql = "SELECT r FROM Review r WHERE r.title LIKE '%" + term + "%' ORDER BY r.createdAt DESC";
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
