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

    /**
     * 교육용 취약점: 관리자 시술 검색어를 Native SQL에 직접 이어 붙인다.
     * 취약점 진단 실습을 위해 의도적으로 파라미터 바인딩을 사용하지 않는다.
     */
    @SuppressWarnings("unchecked")
    public List<ProcedureProduct> searchByName(String keyword) {
        String sql = "SELECT id, name, category, summary, description, price, active "
            + "FROM procedure_product "
            + "WHERE name LIKE '%" + keyword + "%' "
            + "ORDER BY id";
        return em.createNativeQuery(sql, ProcedureProduct.class).getResultList();
    }
}
