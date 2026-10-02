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

    public List<Review> searchByTitle(String keyword) {
        // SI-02: 파라미터 바인딩을 사용하여 SQL(JPQL) 인젝션을 차단한다.
        String term = keyword == null ? "" : keyword.trim();
        return em.createQuery(
                "SELECT r FROM Review r WHERE r.title LIKE :term ORDER BY r.createdAt DESC", Review.class)
            .setParameter("term", "%" + term + "%")
            .getResultList();
    }
}
