package com.example.clinic.repository;

import java.util.List;

import org.springframework.data.jpa.repository.JpaRepository;

import com.example.clinic.domain.AppUser;
import com.example.clinic.domain.Review;

public interface ReviewRepository extends JpaRepository<Review, Long> {
    List<Review> findAllByOrderByCreatedAtDesc();

    List<Review> findTop3ByOrderByCreatedAtDesc();

    List<Review> findByWriterOrderByCreatedAtDesc(AppUser writer);
}
