package com.example.clinic.repository;

import java.util.List;

import org.springframework.stereotype.Repository;

import jakarta.persistence.EntityManager;
import jakarta.persistence.PersistenceContext;

@Repository
public class ProcedureSearchRepository {

    @PersistenceContext
    private EntityManager em;

    @SuppressWarnings("unchecked")
    public List<Object[]> searchByName(String keyword) {
        String sql = "SELECT id, name, category, price, description FROM procedure_product " +
                     "WHERE name LIKE '%" + keyword + "%' AND active = 1";
        return em.createNativeQuery(sql).getResultList();
    }
}
