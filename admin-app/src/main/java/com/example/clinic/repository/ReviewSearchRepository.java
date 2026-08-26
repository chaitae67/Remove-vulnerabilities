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
        String jpql = "SELECT r FROM Review r WHERE r.title LIKE '%" + keyword + "%' ORDER BY r.createdAt DESC";
        return em.createQuery(jpql).getResultList();
    }
}
