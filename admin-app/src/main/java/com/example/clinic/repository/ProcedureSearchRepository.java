package com.example.clinic.repository;

import com.example.clinic.domain.ProcedureProduct;
import jakarta.persistence.EntityManager;
import jakarta.persistence.PersistenceContext;
import java.util.List;
import org.springframework.stereotype.Repository;

@Repository
public class ProcedureSearchRepository {

    @PersistenceContext
    private EntityManager em;

    /** SI-02: 시술 검색어를 바인딩 파라미터로 처리하여 SQL 인젝션을 차단한다. */
    @SuppressWarnings("unchecked")
    public List<ProcedureProduct> searchByName(String keyword) {
        String term = "%" + (keyword == null ? "" : keyword.trim()) + "%";
        String sql = "SELECT id, name, category, summary, description, price, active "
            + "FROM procedure_product "
            + "WHERE name LIKE ?1 "
            + "ORDER BY id";
        return em.createNativeQuery(sql, ProcedureProduct.class)
            .setParameter(1, term)
            .getResultList();
    }
}
