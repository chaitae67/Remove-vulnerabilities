package com.example.clinic.repository;

import com.example.clinic.domain.AppUser;
import java.util.List;
import java.util.Optional;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;

public interface AppUserRepository extends JpaRepository<AppUser, Long> {
    Optional<AppUser> findByUsername(String username);

    boolean existsByUsername(String username);

    boolean existsByEmail(String email);

    Optional<AppUser> findByUsernameAndEmail(String username, String email);

    Optional<AppUser> findByResetToken(String resetToken);

    Optional<AppUser> findByEmail(String email);

    /**
     * {@code pattern} 은 이미 소문자로 변환하고 LIKE 와일드카드를 '!' 로 이스케이프한
     * {@code %키워드%} 형태여야 한다. ({@code UserService#searchUsers} 참고)
     */
    @Query("""
        select u from AppUser u
        where lower(u.username) like :pattern escape '!'
           or lower(u.name) like :pattern escape '!'
           or lower(u.email) like :pattern escape '!'
           or lower(u.phone) like :pattern escape '!'
        order by u.id asc
        """)
    List<AppUser> searchByKeywordPattern(@Param("pattern") String pattern);
}
