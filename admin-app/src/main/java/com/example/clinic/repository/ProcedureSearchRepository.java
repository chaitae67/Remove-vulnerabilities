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
        String term = normalizeKeyword(keyword);
        String sql = "SELECT id, name, category, price, description FROM procedure_product " +
                     "WHERE name LIKE '%" + term + "%' AND CAST(active AS INTEGER) = 1";
        return em.createNativeQuery(sql).getResultList();
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
