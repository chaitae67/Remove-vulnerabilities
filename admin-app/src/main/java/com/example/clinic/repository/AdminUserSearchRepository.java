package com.example.clinic.repository;

import com.example.clinic.domain.AppUser;
import jakarta.persistence.EntityManager;
import jakarta.persistence.PersistenceContext;
import java.util.List;
import org.springframework.stereotype.Repository;

@Repository
public class AdminUserSearchRepository {

    @PersistenceContext
    private EntityManager em;

    /** SI-02: 회원 검색어를 바인딩 파라미터로 처리하여 SQL 인젝션을 차단한다. */
    @SuppressWarnings("unchecked")
    public List<AppUser> search(String keyword) {
        String term = "%" + (keyword == null ? "" : keyword.trim()) + "%";
        String sql = "SELECT id, username, password, name, email, phone, role, point_balance, "
            + "withdrawn, withdrawn_at, reset_token, reset_token_expires_at, created_at "
            + "FROM app_user "
            + "WHERE username LIKE ?1 "
            + "OR name LIKE ?1 "
            + "OR email LIKE ?1 "
            + "OR phone LIKE ?1 "
            + "ORDER BY id";
        return em.createNativeQuery(sql, AppUser.class)
            .setParameter(1, term)
            .getResultList();
    }
}
