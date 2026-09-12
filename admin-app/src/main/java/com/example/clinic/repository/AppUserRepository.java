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

    @Query("""
        select u from AppUser u
        where lower(u.username) like lower(concat('%', :keyword, '%'))
           or lower(u.name) like lower(concat('%', :keyword, '%'))
           or lower(u.email) like lower(concat('%', :keyword, '%'))
           or u.phone like concat('%', :keyword, '%')
        order by u.id asc
        """)
    List<AppUser> searchByKeyword(@Param("keyword") String keyword);
}
