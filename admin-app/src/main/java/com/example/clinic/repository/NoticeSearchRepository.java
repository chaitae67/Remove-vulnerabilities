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
        String jpql = "SELECT n FROM Notice n WHERE n.title LIKE '%" + keyword + "%' ORDER BY n.createdAt DESC";
        return em.createQuery(jpql).getResultList();
    }
}
