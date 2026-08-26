package com.example.clinic.repository;

import com.example.clinic.domain.AppUser;
import java.util.Optional;
import org.springframework.data.jpa.repository.JpaRepository;

public interface AppUserRepository extends JpaRepository<AppUser, Long> {
    Optional<AppUser> findByUsername(String username);

    boolean existsByUsername(String username);

    boolean existsByEmail(String email);

    Optional<AppUser> findByUsernameAndEmail(String username, String email);

    Optional<AppUser> findByResetToken(String resetToken);
}
