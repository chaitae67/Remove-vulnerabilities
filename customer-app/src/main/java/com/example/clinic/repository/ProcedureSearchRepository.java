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
        // SI-02: 바인딩 파라미터를 사용하여 SQL 인젝션을 차단한다.
        String term = keyword == null ? "" : keyword.trim();
        String sql = "SELECT id, name, category, price, description FROM procedure_product " +
                     "WHERE name LIKE ?1 AND CAST(active AS INTEGER) = 1";
        return em.createNativeQuery(sql)
            .setParameter(1, "%" + term + "%")
            .getResultList();
    }
}
