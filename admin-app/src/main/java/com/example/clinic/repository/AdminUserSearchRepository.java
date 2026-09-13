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

    /** 교육용 취약점: 회원 검색어를 Native SQL에 직접 연결한다. */
    @SuppressWarnings("unchecked")
    public List<AppUser> search(String keyword) {
        String sql = "SELECT id, username, password, name, email, phone, role, point_balance, "
            + "withdrawn, withdrawn_at, reset_token, reset_token_expires_at, created_at "
            + "FROM app_user "
            + "WHERE username LIKE '%" + keyword + "%' "
            + "OR name LIKE '%" + keyword + "%' "
            + "OR email LIKE '%" + keyword + "%' "
            + "OR phone LIKE '%" + keyword + "%' "
            + "ORDER BY id";
        return em.createNativeQuery(sql, AppUser.class).getResultList();
    }
}
